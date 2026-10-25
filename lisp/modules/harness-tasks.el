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
;; one by default: `harness-tasks-context-limit' (384k tokens) caps the
;; session's context window, so the harness compacts a task sooner and
;; hands it a smaller transcript to carry on from.  Set it to nil to
;; give task sessions the whole window, like any other session, or to
;; another number of tokens to choose how often they compact.  A task
;; session created with the cap is told about it in a hint naming the
;; setting (`harness-tasks--context-limit-hint'), so the cap is never
;; silent.
;;
;; In a git project a task owns the whole life of its change: it starts
;; in a fresh worktree on a branch of its own (the `worktree' module),
;; named after its title and its id (`harness-tasks--branch-name': the
;; short title the cheap naming model gave it, see Titles, else the
;; first words of its prompt),
;; its session is told to commit there, and when the agent finishes the
;; branch goes through the merge queue (the `merge' module) into the
;; branch checked out at the project root -- a main checkout, which the
;; queue takes as a target in its own right, with no session behind it.
;; It is the same queue, the same conflict resolution and the same
;; events as a sub-agent merging into the session that started it, which
;; a task's own session may have started: its branch waits in the queue
;; while those merges into its worktree are still to come, and it may
;; not hand in until they are through.  A task is complete only once its
;; changes are merged.  Conflicts are handed back to the task's own
;; session by the merge queue; any other failure puts the task in front
;; of the user.
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
;; (`harness-tasks--missing-report').  Sending work back is held to
;; `harness-tasks-max-running' like a start: it works at once with a slot
;; free, pre-empts a task at work it outranks when none is, and waits in
;; the queue, its feedback kept, when every task at work outranks it
;; (see Scheduling).
;;
;; Backlog refinement (once called grooming): a task submitted with
;; `:refine' is jotted down for later, not started.  An agent writes it
;; up first -- briefly, read-only, at the project's root, told so by
;; `harness-tasks--refine-prompt' -- and its final reply becomes the
;; task's prompt; the original words stay in `:note'.  The task then
;; waits in the backlog -- its own column, apart from the queued
;; pending tasks the scheduler starts -- as a backlog task
;; (`:backlog'): the scheduler never starts it, only `task/start' does,
;; so the backlog survives restarts until someone picks a task.  Its
;; session is the one that refined it: starting moves that session into
;; the task's worktree and tells it to do the work.  A message the user
;; writes in that session while the task waits in the backlog starts
;; it, as a message to a returned task does, and one written while its
;; write-up runs stops the write-up and starts it all the same.
;; Feedback on the write-up goes through `task/refine' or `task/prompt'
;; (the board's [Refine] and its reply box) instead, and a message
;; queued while a write-up ran stays feedback.  `task/start' (the
;; board's [Start now]) also supersedes a write-up still running: it
;; stops that turn and starts the task with the write-up it has when the
;; turn has ended, so the stopped write-up never finishes the task or
;; takes it to review.
;; `task/queue' (the board's [Queue it]) puts a backlog task
;; back in the pending queue, where the scheduler starts it like any
;; queued task -- as soon as its project has a free slot -- the write-up
;; kept for the start.
;;
;; Backlog mode: that is a project's backlog in manual mode, the
;; default, where every written-up task waits for someone to queue or
;; start it.  In auto mode (`task/set-backlog-mode',
;; `task/toggle-backlog-mode', the board's [Manual queue] / [Auto queue]
;; on its Backlog heading, task_control's auto-queue and manual-queue)
;; a write-up that finishes queues its task itself, as `task/queue'
;; would (`harness-tasks--auto-queue'): the task leaves the backlog for
;; the pending queue, where the scheduler starts it by priority, within
;; the limit, and not while the queue is suspended.  Every write-up that
;; ends cleanly does, the first and one done again -- after feedback,
;; after an error, or all the same after a refusal as a duplicate -- so
;; in auto mode a finished write-up never waits in the backlog.  A
;; write-up that stops (an error, a cancel, a refusal) still waits for
;; the user, and a prompt edited by hand (`task/update') stays where it
;; is.  Switching to auto queues none of the tasks already in the
;; backlog, which were written up to wait there, and switching back to
;; manual takes none out of the queue.  The mode is per project, like
;; the queue's suspension, and outlives a restart: the projects in auto
;; mode are named in `harness-tasks--auto-queue-name'.
;;
;; Main tree: a task submitted with `:main-tree' (the `task_submit'
;; tool's `main_tree', or the board's worktree switch) gets no worktree
;; and no branch.  Its session works in the project's main checkout, so
;; the task can touch the checkout itself -- cleaning up uncommitted
;; changes, say -- and nothing merges when its turn ends.  A refined
;; task keeps the declaration for when it starts.
;;
;; Priority: every task has one of `harness-priority-levels', low,
;; medium (the default) or high, given at submission (`:priority') and
;; changed at any time.  It orders the queue: when
;; `harness-tasks-max-running' holds a project's tasks back, a free slot
;; goes to the highest priority waiting, the oldest of those first.  It
;; stops a task at work only for work the user sent back from review
;; (pre-emption, see Scheduling below), and backlog tasks still wait for
;; someone to start them.  A priority is the session's, and a task's is its
;; session's: every task has its session from submission (`Sessions'
;; below), so the board shows and orders by what the task's work is
;; queued by.  The level is given to the session (`priority/set',
;; `harness-priority-set-session'), read through the plugin
;; (`harness-priority-of-task' for a task), and nothing here stores one:
;; a task's record has no priority field.
;;
;; Queue: a project's pending queue can be suspended
;; (`task/suspend-queue', the board's P, task_control's suspend-queue):
;; the scheduler then starts none of its waiting tasks on its own, so
;; the board is clear for one urgent task, which an explicit
;; `task/start' still starts (as it starts a task whatever the limit).
;; `task/resume-queue' lets the waiting tasks start again at once.  The
;; suspension is per project, like the concurrency limit, kept across
;; restarts in `harness-tasks--queue-name', and shown on the board.
;;
;; Holds: a queued task can be held back for reasons of its own
;; (`harness-tasks--hold', the view's `:hold'; see Holds below).  A task
;; whose turn ended because every model it could run on is out of
;; quota or money, or because a hard budget stopped it before or
;; between two steps, is no failure: it goes back to pending
;; (`harness-tasks--park') with the reason on its card -- which quota or
;; budget, and when it resets -- and the scheduler holds it, and any task
;; whose session would stop the same way, until the quota is back
;; (a mark ends or is cleared, the fallback list gains an entry that
;; works) or the budget has room (raised, removed, a new period).  Then
;; the queue starts it like any waiting task and its session carries on
;; where it stopped.
;;
;; Pausing: `task/pause' (the board's Pause) is a return to pending that
;; sticks -- the task is marked `:paused', a hold the scheduler keeps,
;; until `task/resume', `task/start' or a turn the user starts in its
;; session -- and the mark is kept with the record, so a restart leaves
;; the task paused.  `task/pause-all' and `task/resume-all' do it for
;; every task of a project or of every project; `task/queues' lists
;; every project's queue and its state, and `task/suspend-all-queues'
;; and `task/resume-all-queues' switch them all, which the task slots
;; page offers in one place (see Queues, all of them below).
;;
;; Waiting for a slot: a queued task knows since when it waits
;; (`:queued-at', stamped whenever a task joins the queue: submitted,
;; taken out of the backlog by `task/queue', or put back by a return to
;; pending, a pre-emption or work held back after review;
;; `harness-tasks--queued-since'), and every start of a task that waited
;; there records how long it did and at which priority in its `:waits'
;; (the last 20, newest first; `harness-tasks--waits-after').
;; `task/slots' hands a UI a project's slots as plain data -- who holds
;; them, the queue in the order it will start, the recent waits
;; (`harness-tasks-slot-wait-days') -- read from what the scheduler goes
;; by, so the sub-agents and the merge queue that take no slot are not
;; in it.  `task/queue-order' gives each waiting task its place in its
;; project's line, in that same order, for the lists that show it (the
;; task_list tool).
;;
;; Return to pending: `task/return-to-pending' (the board's u,
;; task_control's return-to-pending) stops the turn of a task at work
;; and puts it back in the pending queue, keeping its session, branch
;; and worktree: when it starts again its own session carries on where
;; it stopped, told so by the harness.  The work its session left
;; running outside its turn -- a supervisor's workers, sub-agents --
;; stops too, once no turn of the session runs
;; (`harness-tasks--stop-outstanding'): what that work was on is
;; reported to the session, where it waits for the task to carry on and
;; retry it or plan it again.  It goes to the front of its priority's
;; queue, ahead of the tasks that never started, the ones returned
;; first starting first; a higher priority still goes first.  Returning
;; it frees its slot for the other waiting tasks (one waiting on work
;; its session left running, `:waiting', holds one too), and starts
;; nothing itself, so the task waits -- also while the queue is
;; suspended -- for the next task the queue starts, for
;; `task/resume-queue', or for an explicit `task/start'.  A message to
;; a returned task (`task/prompt') starts it the same way when its
;; queue runs, and is kept and delivered with the start while it is
;; suspended.  A task pre-empted for work sent back from review
;; (Scheduling below) is returned the same way, and told why when it
;; starts again (`harness-tasks--preempted-message'), as one sent back
;; while no slot could take it waits with its feedback; so is one that
;; worked in the slot of a task blocked on the user, which took it back
;; once answered (`harness-tasks--reclaimed-message').  While a returned
;; task waits, its session takes no turn of its own -- another session's
;; message, a sub-agent reporting back -- and keeps the message for the
;; start (`harness-tasks--before-turn'); the user's own message to it
;; starts it, as `task/start' does.
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
;;             in start order: higher priority first, then among equals
;;             work sent back from review, then tasks returned to
;;             pending, then the oldest), or a backlog task waiting for
;;             someone to start it
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
;;             verify it or send it back with feedback.  A round that
;;             handed in work needing no merge (`:no-merge') also waits
;;             here, and verifying it completes the task without the
;;             merge queue.
;;   done      merged (or finished, outside git), and verified with
;;             review; a follow-up message moves the task back to active
;;
;; A round can also hand in that it cannot continue (`hand_in' with
;; `:cannot-continue'): the task then waits for the user with the
;; outcome `cannot-continue' and nothing merges, its report saying what
;; blocks it.
;;
;; Every task a method returns or an event carries also has a derived
;; `:column', the kanban column it belongs in:
;;
;;   pending       waiting for a slot, which the queue starts on its own
;;                 while the project has one free
;;   backlog       a backlog task, or its write-up; only the user starts
;;                 one (`task/start'), so its column says it is not
;;                 queued: `:state' stays pending with `:backlog' t
;;   needs-input   requires user input: its session is blocked on a
;;                 permission or a question -- also while the task is
;;                 starting or resumed and the turn has not begun, held
;;                 by the question a cold prompt cache asks first
;;                 (harness-cowboy.el) --, or it (or its refinement)
;;                 stopped part way
;;   review        finished, waiting for the user to verify it
;;   merging       its branch holds a place in the merge queue: queued,
;;                 merging, or its session resolving the conflicts
;;                 (unless that session waits on the user: needs-input)
;;   active        in progress
;;   done          completed
;;   cancelled     done after the user cancelled it: its turn was stopped
;;                 (`:outcome' cancelled) and the task marked done by hand,
;;                 its branch never merged; finished work stays in done
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
;;
;; Redaction: what a task keeps -- its prompt, the report it handed in
;; (whose evidence can copy the output of a tool call), the rounds of
;; feedback, its errors and recap -- can hold a secret that got into the
;; session's transcript.  `task/redact' (see Redaction below) takes it
;; out of every record and of the files that keep the records, for the
;; redaction engine (harness-redact.el), which hands it the secrets it
;; resolved from a reference: they exist in memory only, and nothing
;; here logs, emits or returns one.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'parse-time)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)
(require 'harness-redaction)
(require 'harness-priority)
(require 'harness-slots)
(require 'harness-readonly)

(defcustom harness-tasks-max-running nil
  "Tasks of each project that may work at once; the rest wait as pending.
The limit is per project: every project has this many slots of its
own, and its pending tasks wait only for its own working ones, never
for another project's.  With 2, two projects may run four tasks
between them.  A task's project is the main checkout it was submitted
for, also when it works in a worktree.

Only top-level sessions are limited: a task takes a slot while its own
session works on it, running or waiting on the user mid-turn, and
while it waits on work its session left running outside its turn,
such as a supervisor's workers.  The sessions working for it never
take one -- its sub-agents and forks, and the merge queue's conflict
resolvers -- and neither does the merge queue's work: a task whose
branch is queued, merging or having its conflicts resolved holds no
slot, even while its own session commits or resolves them.
`task/start' starts a task whatever the limit.
nil (the default) means no limit, and 0 that no task starts by itself.
Waiting tasks start by priority (see `harness-priority-levels'); among
equals, work sent back from review goes first, then the tasks returned
to pending -- paused, pre-empted, or their borrowed slot taken back --
and then the others, oldest first (`harness-tasks--start-order').

Work the user sends back from review is held to the limit too: with no
slot free it pre-empts a task at work it outranks -- of a lower
priority, or of its own that was not sent back from review itself --
which goes back to the queue to carry on later, its turn stopped and
the work its session left running outside it stopped too; when it
outranks none it waits in the queue (`harness-tasks--make-room').

A task waiting on the user for long enough lends its slot to the queue
until it is answered (`harness-tasks-lend-blocked-slot-after').

The task board's \"N at a time\" button sets it (through `config/set',
saved for every project).  A limit raised that way, or on the settings
page, starts the tasks it lets through at once; one lowered stops no
task at work, and fewer start after (`harness-tasks--on-config-changed')."
  :type '(choice (const :tag "No limit" nil) (natnum :tag "Tasks at once")) :group 'harness)

(defcustom harness-tasks-slot-wait-days 7
  "Days back the slot page's queue wait figures look.
Every start of a task that waited in its project's queue records how
long it waited, and at which priority, on the task (`:waits', see
`harness-tasks--start').  `task/slots' reports the waits of the last
this many days, which the UI's slot page sums up per priority; older
ones stay on their tasks but are left out of it."
  :type '(number :tag "Days") :group 'harness)
(defcustom harness-tasks-lend-blocked-slot-after 300
  "Seconds a task waits on the user before it lends its slot, or nil.
A task whose own session is blocked on you -- a permission request, an
ask_user question, the harness's question about a cold prompt cache --
keeps its slot while it waits, as its turn goes on once you answer.
After this many seconds of waiting it lends that slot to the queue: the
next pending task starts in it, by priority as usual, and works there
until you answer.  Your answer takes the slot back at once: the task
that borrowed it goes back to the front of the queue, its turn stopped
and its session, branch and worktree kept, and carries on later where
it stopped, told why by the harness.  The wait keeps a task you answer
quickly from starting another one only to stop it a moment later.

A task that waits on work it left running -- a supervisor's workers,
sub-agents -- keeps its slot however long it is blocked, and so does a
task working in a borrowed slot.  Only `harness-tasks-max-running'
makes slots, so without a limit nothing is lent.  nil never lends: a
blocked task keeps its slot for as long as it waits."
  :type '(choice (const :tag "Never" nil) (number :tag "Seconds")) :group 'harness)

(defcustom harness-tasks-require-verification t
  "When non-nil, finished work waits for the user to review it.
A task whose turn ends cleanly goes to review instead of done, in a git
project with its branch not merged yet.  Verifying it (`task/verify')
merges the branch and completes the task; sending it back with
feedback (`task/reject') has its session work on it again.  With nil a
task is done once its branch merges, or outside git once its turn ends.

The settings page has it under Task board, and the task board's V key
turns it off and on again, for every project.  Turning it off leaves
the tasks that already wait for review where they are, for the user to
verify."
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

(defcustom harness-tasks-context-limit 384000
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

;;;; Plan mode
;;
;; A task submitted to be planned (`task/submit' with `:plan', the
;; board's Plan mode) is a backlog task whose write-up is a plan: a
;; session on a strong model (the hard tier of the task model's
;; provider, `harness-tasks--plan-tier') reads the code and the board,
;; makes the decisions, and hands in a plan (`submit_task_plan',
;; `task/hand-in-plan') that a cheaper model carries out once the task
;; starts (the medium tier, `harness-tasks--plan-work-tier').  It is
;; supervisor mode's idea -- the strong model decides, a cheaper one
;; works -- without its workers: one plan, one session doing it.  It
;; sits beside supervisor mode, which leaves a planned task's work
;; hands-on, its plan being made (`harness-supervisor--task-value').
;;
;; Both models are the task's to choose: `:refine-model' and
;; `:refine-thinking' plan it, `:model' and `:thinking' do the work, as
;; the board's lines above its compose box set them.  The tiers are only
;; the defaults, and no option: a model per task is the parameter (see
;; docs/configuration-audit.md).
;;
;; Like every write-up the planning session only reads: the readonly
;; module (harness-readonly.el) holds it to the reading tools and
;; read-only, offline bash (`harness-tasks--readonly-policy'), and the
;; write-up gate denies whatever would ask.  Its turn is held to a soft
;; budget of `harness-tasks--plan-tool-calls', steered to hand the plan
;; in at that many calls and every half budget after, and a turn that
;; stops without handing in a plan (or refusing the task as a duplicate)
;; is sent back to do so, twice at most (`harness-tasks--plan-stop').

(defconst harness-tasks--plan-tier 'hard
  "The tier of the task model's provider that plans a task by default.
Claude's is Opus (see `harness-model-tiers').  A provider without a
model for it plans on the task's own model, and a task submitted with
a write-up model of its own (`:refine-model') plans on that.")

(defconst harness-tasks--plan-work-tier 'medium
  "The tier of the task model's provider a planned task works on by default.
The plan is written for it: Claude's is Sonnet.  A provider without a
model for it works on the task model, and a task submitted with a model
of its own (`:model') keeps it.")

(defconst harness-tasks--plan-tool-calls 40
  "Tool calls a plan may make before the agent is told to hand it in.
A soft budget: at this many calls the session that plans a task is
steered to hand its plan in with what it knows, and again every half
budget after that (at 40, 60, 80 and so on).  It is a nudge and never a
stop; nil never tells it.  Supervisor plans took 61 tool calls at the
median before their plan, gathering everything for their workers; since
those workers read the code they change, a supervisor is nudged at 30
\(`harness-supervisor-step-budget').  A plan reads for the same reason
only what its decisions need, but it settles the whole approach for one
medium session rather than splitting the work, so it gets a little more.")

(defconst harness-tasks--plan-prompt
  "## Task planning
This session plans a task for the backlog: the engineer described it, and another agent -- on a cheaper, medium model, which will not see this conversation -- will carry the plan out later.  Do not do the task: plan it, so that the other agent does not have to make the hard decisions again.  Your tokens are the expensive ones: every call you make reads this whole conversation again on the strong model, so spend them on the decisions, not on details the other agent finds for itself when it reads the code it changes.
- First, a quick search for related tasks: call task_list once with include_archived true and limit 50, the project's most recent tasks (the line of this one says \"(this task)\").  Read a task's session with session_read only when its line leaves you unsure what it changes.
- If a task there already asks for exactly the same feature or fix -- the same change, not merely a related one -- refuse this one instead of planning it: your final message is then a first line \"Duplicate of ID\", ID being that task's id, and after a blank line a short message for the engineer saying which task it is (its title and where it stands) and what makes it the same.  Once the engineer asks for the plan anyway, plan it.  A related task is no reason to refuse: the ones that work in the same code area go in the plan, with how to coordinate with them (check where each stands, message its session while it is at work, build on its commits rather than redo them).
- Then read what the decisions need -- where the work goes, the code it changes and what calls it, the tests and the project's conventions -- and no more.  You only read: your tools change nothing, bash (when you have it) runs read-only and offline, and nobody answers questions, so put what you cannot settle in the plan as an open question or an assumption.
- Make the decisions yourself: the approach, the data and control flow, the edge cases, what to test.  Name the files and functions to change and say how each changes; sketch the shape of new code only where a decision depends on it, never the whole change.
- Keep the reading to what the plan needs: about 40 tool calls is plenty, and you are told when you have made that many.
- Hand the plan in with submit_task_plan: a short imperative title, and the plan in concise markdown, a ticket a medium model can carry out on its own -- the goal and why; the decisions you made and the constraints; the context it needs (key files, functions, conventions, related tasks); the steps, in order, each concrete enough to do without planning again; how to verify the work (the tests to add or update, the checks to run, what to show); and open questions or assumptions, if any.  Write it at the length the work needs, no longer and no shorter.  The plan becomes the task's prompt, and the task waits in the backlog until the engineer starts it.
- When the engineer replies, take it as feedback on the plan and hand in the complete updated plan with submit_task_plan."
  "System prompt section of a session that plans a backlog task (Plan mode).
The plan it hands in with `submit_task_plan' becomes the task's
prompt, so it asks for one complete, self-contained plan, written for
a medium model.  Like the write-up's (`harness-tasks--refine-prompt')
it has the agent look for related tasks first, and refuse a task the
board has already with a reply whose first line is \"Duplicate of
ID\" (see `harness-tasks--refusal').")

(defconst harness-tasks--plan-tool "submit_task_plan"
  "The tool a planning session hands its plan in with.
See `task/hand-in-plan', and harness-tools-sessions.el for the tool.")

(defconst harness-tasks--plan-hint
  "Planning is read-only: put the change in the plan and hand it in with submit_task_plan."
  "Hint of a call denied because the session that plans a task only reads.")

(defconst harness-tasks--plan-reminder
  "Hand the plan in with submit_task_plan (a short title and the plan, in markdown). If the board has this task already, reply with a first line \"Duplicate of ID\" and a short note instead."
  "What a planning session that stopped without handing a plan in is told.")

(defconst harness-tasks--plan-max-reminders 2
  "Most times a planning turn is sent back to hand its plan in.")

(defconst harness-tasks--plan-start-message
  "Plan done; start the work now, following the plan below. You can edit files and run commands. Keep to its decisions; where the code proves it wrong, do what it intends and say what you changed when you hand in. Check on any related tasks it lists before touching the same code."
  "Opening of the message that starts a planned task's work.
The plan follows it, then the request it was written from.")

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
`auto' asks the session's provider for its simple tier, falling back
to the session's own model; nil uses the session's own model."
  :type '(choice (const :tag "Provider's simple tier" auto)
                 (const :tag "The task's model" nil)
                 (string :tag "Model" :names model))
  :group 'harness)

(defcustom harness-tasks-recap-thinking nil
  "Thinking level of a recap request, or nil to ask for no thinking.
A recap is one short line and its budget is small
\(`harness-tasks-recap-max-tokens'), so thinking is off by default: a
model whose thinking is on by default would spend the budget on the
reasoning and write no line.  A level here asks for thinking anyway,
which needs a larger budget to fit."
  :type `(choice (const :tag "No thinking" nil) ,@harness-tasks--thinking-levels)
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

(defcustom harness-tasks-recap-chats t
  "When non-nil, a session that is no task's gets recaps as its turn runs.
The chat of a running turn shows the newest above the line saying what
the turn does, and the last `harness-tasks-recap-history' of them when
the recap is opened: a turn of many tool calls is easy to lose track
of.  They are made as a task card's are, a short call to the simple
tier, with the same thresholds -- `harness-tasks-recap-seconds' and
`harness-tasks-recap-tool-calls', counted from the start of the turn
or from the last recap -- and only while a turn runs; the recaps of one
turn are dropped when the next begins.  Nil makes none (a task still
has its card's).  `harness-tasks-recap' off turns every recap off."
  :type 'boolean :group 'harness)

(defcustom harness-tasks-recap-history 5
  "How many recaps of a session are kept, and shown when a chat opens its recap.
The newest ones: a chat that runs a turn shows the latest above the
line saying what the turn does, and this many with the recap opened,
oldest first, so the turn's course can be read at a glance.  They are
kept in the session's `ext' as `:recaps'.  A task's card shows the
latest alone.  1 keeps the latest only."
  :type '(integer :tag "Recaps") :group 'harness)

(defconst harness-tasks--start-message
  "Write-up done; start the work now. You can edit files and run commands. Check on any related tasks it lists before touching the same code."
  "Opening of the message that starts a backlog task's work.
The task's write-up follows it, then the request it was written from.
A write-up names the related tasks working on the same code, which the
work coordinates with (see `harness-tasks--refine-prompt').")

(defconst harness-tasks--reject-message
  "Sent back from review. Address the feedback below, then finish as before."
  "Opening of the message that sends a task back to its session after review.
The user's feedback follows it (`task/reject'), as it opens any message
the user sends the session while its task waits for review
\(`harness-tasks--on-message').  Only the user's: a message from another
session's agent is no review, and `harness-tasks--aside-message' opens it.")

(defconst harness-tasks--aside-message
  "Message from another session while this task waits for review; not review feedback. If you change the work, finish as before and hand in again; otherwise your report stands."
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

(defcustom harness-tasks-resume-interrupted t
  "When non-nil, tasks a stopped harness interrupted carry on by themselves.
A task that was working when the harness stopped (Emacs quit,
`harness-restart', a crash) is sent `harness-tasks--resume-prompt' when the
harness starts again.  With nil it waits in needs-input instead, with
the outcome `interrupted', until you reply.  The same goes for a backlog
task's write-up: it is written again, or with nil waits for a retry."
  :type 'boolean :group 'harness)

(defconst harness-tasks--resume-prompt
  "The harness restarted and cut your last turn short; running tool calls did not finish. Check where you left off and carry on."
  "Message that resumes a task's session after a restart interrupted it.")

(defconst harness-tasks--retry-prompt
  "Your last turn stopped early: %s. Check where you left off and carry on."
  "Message that has a task's session work again after its turn stopped.
`task/retry' sends it; %s says how the turn stopped.")

(defconst harness-tasks--paused-message
  "Resumed after a pause. Your last turn was cut short and any workers or sub-agents were stopped (see above). Your changes are still there: check where you left off and carry on."
  "Message that starts a task returned to pending again.
`task/return-to-pending' puts a working task back in the queue, its
turn stopped and the work its session left running outside its turn
stopped too (`harness-tasks--stop-outstanding'), which reports to the
session what it was on; when the queue starts the task again its own
session carries on (see `harness-tasks--start-paused'), told so by
this message.")

(defconst harness-tasks--preempted-message
  "Resumed after being pre-empted by a task sent back from review. Your last turn was cut short and any workers or sub-agents were stopped (see above). Your changes are still there: check where you left off and carry on."
  "Message that starts a task again after it was pre-empted.
A task the user sends back from review while every slot of its project
is taken takes the slot of a task at work it outranks
\(`harness-tasks--victim'); that task goes back to the queue, its turn
stopped, as a restart stops one, and the work its session left running
outside its turn stopped too (`harness-tasks--stop-outstanding'), which
reports to the session what it was on.  When the queue starts it again
its own session carries on, told so by this message, as
`harness-tasks--resume-prompt' tells it after a restart.")

(defconst harness-tasks--reclaimed-message
  "Resumed after the task that lent you its slot took it back. Your last turn was cut short and any workers or sub-agents were stopped (see above). Your changes are still there: check where you left off and carry on."
  "Message that starts a task again after its lender took its slot back.
A task blocked on the user long enough lends its slot
\(`harness-tasks-lend-blocked-slot-after'), and the queue starts a task
in it; when the user answers, that borrower goes back to the queue, its
turn stopped and the work its session left running stopped too
\(`harness-tasks--reclaim').  When the queue starts it again its own
session carries on, told so by this message.")

(defconst harness-tasks--quota-message
  "Resumed: the quota that ran out is back, or another provider can carry you. Your last turn stopped when it ran out and any workers or sub-agents were stopped (see above). Your changes are still there: check where you left off and carry on."
  "Message that starts a task again after it waited for quota.
A task whose turn failed because every provider it could run on was out
of quota or money goes back to the queue (`harness-tasks--park') and
waits until one of them works again (`harness-tasks--hold'); when the
queue starts it, its own session carries on, told so by this message.")

(defconst harness-tasks--budget-message
  "Resumed: the budget that stopped you has room again. Your last turn was stopped by it and any workers or sub-agents were stopped (see above). Your changes are still there: check where you left off and carry on."
  "Message that starts a task again after it waited for a budget.
A task a hard budget stopped, between two steps of a turn or before it
began, goes back to the queue (`harness-tasks--park') and waits until
the budget has room (`harness-tasks--hold'): its period ended, or it was
raised or removed.  When the queue starts it, its own session carries
on, told so by this message.")

(defconst harness-tasks--sent-back-message
  "Sent back from review; it waited for a slot until now. Address the feedback, then finish as before."
  "Message that starts a task sent back from review once it gets a slot.
When no slot can take a task the user sends back, it waits in the
queue with their feedback (`harness-tasks--hold-back'), and this message
starts it when the queue does (`harness-tasks--start-paused').  The
feedback reaches the agent with it: the user's message to the session,
which stays in its transcript, its turn refused
\(`harness-tasks--before-turn'), or the feedback of `task/reject', kept
on the task and delivered right after it, opened by
`harness-tasks--reject-message'.")

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

(defconst harness-tasks--queue-name "task-queues.json"
  "File in the state directory naming the projects whose queue is suspended.
The suspension is a property of this harness's board, not of the tasks
themselves, so it is kept out of the task stores, whose format stays as
it was for harnesses without the feature.")

(defconst harness-tasks--auto-queue-name "task-auto-queue.json"
  "File in the state directory naming the projects whose backlog queues itself.
Those are the projects in auto backlog mode (`harness-tasks--backlog-mode'),
where a write-up that finishes queues its task.  Like the suspended
queues, it is the board's and not the tasks', so it is a file of its
own: neither `harness-tasks--queue-name' nor the task stores change
format.")

(defconst harness-tasks--symbol-keys '(:state :outcome :merge-status :return-reason)
  "Keys whose values are symbols in memory and strings on disk.
A priority is not one of them: it lives on the task's session, which
the priority plugin reads (`harness-priority-of-task').")

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

(defvar harness-tasks--waking (make-hash-table :test 'equal)
  "Task ids a user's message is on its way to, before a turn starts.
A message that restarts a stopped task may be held up first -- a
compaction, say -- and starts no turn yet, so the board shows the task
at work meanwhile (`harness-tasks--column').  Cleared when its turn
starts or ends, when the message fails, and when the task goes back to
pending.")

(defvar harness-tasks--queues (make-hash-table :test 'equal)
  "Project root -> t while that project's pending queue is suspended.
A suspended queue starts nothing on its own: `task/suspend-queue' stops
it, `task/resume-queue' starts it again, and an explicit `task/start'
always starts its task (see `harness-tasks--schedule').")

(defvar harness-tasks--queues-loaded nil
  "Non-nil once `harness-tasks--queue-name' was read.
Reading is lazy, so a test run or a reload reads the file of its own
state directory the first time it looks at a queue.")

(defvar harness-tasks--auto-queues (make-hash-table :test 'equal)
  "Project root -> t while that project's backlog queues its write-ups itself.
That is auto backlog mode (`harness-tasks--backlog-mode'); a project not
in it is in manual mode, the default.")

(defvar harness-tasks--auto-queues-loaded nil
  "Non-nil once `harness-tasks--auto-queue-name' was read.
Read lazily, as the suspended queues are (`harness-tasks--queues-loaded').")

(defvar harness-tasks--joining (make-hash-table :test 'equal)
  "Task ids just written up that join the queue in a moment.
In auto backlog mode the end of a write-up puts its task in the backlog,
and `task/queue' takes it on to the pending queue soon after
\(`harness-tasks--auto-queue').  Meanwhile its view says so
\(`:joining-queue'), so that nothing takes it for a task the backlog
keeps until someone starts it: a wait on it, say.")

(defvar harness-tasks--returning (make-hash-table :test 'equal)
  "Task ids whose turn is being stopped by a return to pending.
The turn ends soon after (`agent/cancel' waits out its grace), and
`harness-tasks--on-turn-ended' must not take the cut-short turn for the
task's own end: the task is waiting in the queue, not at work.  Once
that turn has ended, the work its session left running outside it
stops (`harness-tasks--stop-outstanding').  A task pre-empted
\(`harness-tasks--preempt') is returned to pending this way too.")

(defvar harness-tasks--superseding (make-hash-table :test 'equal)
  "Task ids whose write-up is being stopped so the task can start.
A start (`task/start', or the [Start now] of a session's backlog
banner), or a message the user writes in the session while the write-up
runs (`harness-tasks--supersede-on-message'), clears the task's
`:backlog' and stops the turn writing it up; `harness-tasks--on-turn-ended'
then starts the task (`harness-tasks--start'), so neither the write-up's
end nor the turn it was stopped into can finish the write-up or drive
the task to review.  The same mark makes a turn a user's message to a
waiting backlog task would start wait (`harness-tasks--message-starts'):
`harness-tasks--before-turn' refuses that turn, and the task starts once
it is over.")

(defvar harness-tasks--message-starts (make-hash-table :test 'equal)
  "Task ids a user's message to a backlog session is about to start.
`harness-tasks--on-message' marks the task when the message reaches a
backlog task that has not started; `harness-tasks--before-turn' then
refuses the turn the message would start, and the task starts in a turn
of its own, with its start message (`harness-tasks--superseding').  A
message that steers a running write-up stops it instead
\(`harness-tasks--supersede-on-message'); only what `task/refine' or
`task/prompt' sends (`harness-tasks--refine-turn') and a message the
session queued while the write-up ran are feedback on it.")

(defvar harness-tasks--write-up-messages (make-hash-table :test 'equal)
  "Session id -> t while `harness-tasks--refine-turn' sends a message.
The `agent/message' filters run in that call: `harness-tasks--on-message'
takes the mark out, so the message is the write-up feedback it is,
while a message the user sends the session directly starts the task.")

(defvar harness-tasks--worktrees-made (make-hash-table :test 'equal)
  "Task id -> promise of the worktree being made for it.
A task pre-empted while its worktree was being made can start again
before it is ready; that start waits for the same worktree rather than
make another one on the branch the first is taking
\(`harness-tasks--worktree-promise').")

(defvar harness-tasks--blocked-at (make-hash-table :test 'equal)
  "Session id -> when it last became blocked on the user, a float time.
Kept from `session/status' while the session stays blocked, so a task
knows how long it has waited (`harness-tasks--blocked-since').")

(defvar harness-tasks--lend-timers (make-hash-table :test 'equal)
  "Task id -> timer that runs the scheduler once the task lends its slot.
Armed while the task's session is blocked on the user
\(`harness-tasks--arm-lend-timer'), for when it has waited
`harness-tasks-lend-blocked-slot-after'.")

(defvar harness-tasks--holds (make-hash-table :test 'equal)
  "Task id -> the quota or budget hold that keeps a queued task from starting.
Each is (:kind quota|budget :reason TEXT :until TIME :guess BOOL :items
\(...)), as `harness-tasks--compute-hold' works it out; the scheduler
refreshes them at the start of each pass (`harness-tasks--refresh-holds'),
so a hold ends when the quota or budget it waits for does.  A task
paused by hand has no entry here: its `:paused' is its hold
\(`harness-tasks--hold').")

(defvar harness-tasks--hold-timer nil
  "Timer that runs the scheduler when the earliest hold ends.
Armed by `harness-tasks--refresh-holds' for the soonest `:until' of the
holds there are.")

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
  "Merge PLIST into task ID and store it.  Return its view.
A change that names `:state' ends what the task waits for (`:waiting',
see `harness-tasks--on-turn-ended'), unless it sets a wait itself.
Nothing of a task's own is read here: a priority, above all, is the
task's session's, and is set on the session (see the priority plugin)
without the task's record being touched."
  (let ((task (apply #'harness-plist-merge (harness-tasks--get id) (list plist))))
    (harness-tasks--put (if (and (plist-member plist :state)
                                 (not (plist-member plist :waiting))
                                 (plist-member task :waiting))
                            (harness-plist-remove task :waiting)
                          task))))

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

(defun harness-tasks--start-order (tasks)
  "Return TASKS in the order they get slots (destructively).
That is the highest priority first (`harness-priority-above-p', which
the priority plugin owns, as it owns what a task's priority is); among
equals a task sent back from review (`harness-tasks--sent-back-p')
comes first, as it outranks the work of its priority that was not
\(`harness-tasks--outranks-p'), then a task returned to pending
\(`task/return-to-pending', or pre-empted) before one that never
started, the returned ones in the order they were returned, the others
oldest first.  A returned task waits only behind tasks of a higher
priority, whose turn outranks its place in line, and behind work sent
back from review."
  (sort tasks (lambda (a b)
                (let ((pa (harness-priority-of-task a))
                      (pb (harness-priority-of-task b)))
                  (cond
                   ((not (eq pa pb)) (harness-priority-above-p pa pb))
                   ((not (eq (harness-tasks--sent-back-p a) (harness-tasks--sent-back-p b)))
                    (harness-tasks--sent-back-p a))
                   ((harness-tasks--returned-p a)
                    (if (harness-tasks--returned-p b)
                        (< (plist-get a :returned) (plist-get b :returned))
                      t))
                   ((harness-tasks--returned-p b) nil)
                   (t (< (plist-get a :created) (plist-get b :created))))))))

(defun harness-tasks--returned-p (task)
  "Non-nil when TASK was returned to pending, so it leads its priority's queue.
`:returned' is when it was returned; it is cleared when the task starts
again.  `:return-reason' says why (`harness-tasks--return-reason')."
  (and (plist-get task :returned) t))

(defun harness-tasks--return-reason (task)
  "Return why TASK was returned to pending, a symbol.
That is `returned' when it was returned by hand (`task/return-to-pending',
and a record from before the reasons), `preempted' when a task sent
back from review took its slot (`harness-tasks--preempt'; `:preempted-by'
names that task), `reclaimed' when it worked in the slot of a task
blocked on the user, which took it back once answered
\(`harness-tasks--reclaim'; `:preempted-by' names the lender), or
`sent-back' when the user sent it back from review while no slot could
take it, so it waits for one with their feedback
\(`harness-tasks--hold-back'), or `quota' or `budget' when its turn
stopped because every provider it could run on was out of quota or
money, or a hard budget was spent (`harness-tasks--park').  The reason
outlives `:returned' until the task's next turn begins: its start tells
the session why it stopped (`harness-tasks--start-paused')."
  (or (plist-get task :return-reason) 'returned))

(defun harness-tasks--sent-back-p (task)
  "Non-nil when TASK's work is feedback that sent it back from review.
`:sent-back' is when the user last sent it back -- `task/reject', or
their message to its session while it waited for review -- and stays
while the task works on that feedback, also while it waits for a slot
or was pre-empted, until the task next waits for review or is done.
Such work goes before work of its priority that was not sent back: it
leads the queue (`harness-tasks--start-order') and may take that work's
slot (`harness-tasks--outranks-p')."
  (and (plist-get task :sent-back) t))

(defun harness-tasks--refinement-p (task)
  "Non-nil when a turn of TASK's session refines it rather than does it.
That is while it is refining, and while it waits in the backlog with
the session that wrote it up -- never a task returned to pending, whose
session has the work and whose next turn carries on with it.  Every
task has a session from submission, so the backlog is what tells a
write-up from work waiting for a slot: `harness-tasks--to-pending'
clears it."
  (or (eq (plist-get task :state) 'refining)
      (and (eq (plist-get task :state) 'pending) (harness-tasks--backlog-p task))))

(defun harness-tasks--plan-p (task)
  "Non-nil when TASK's write-up is a plan (Plan mode, `task/submit' with `:plan').
Its session plans it on a strong model, and its work runs on the model
the plan is written for (see Plan mode above)."
  (harness-json-true-p (plist-get task :plan)))

(defun harness-tasks--written-up-p (task)
  "Non-nil when TASK's prompt is a write-up of the request in `:note'.
That is a backlog task, and one the user queued from the backlog
\(`task/queue'): it waits for a slot like any other queued task, but
its work still opens with the write-up and the request it came from
\(`harness-tasks--start-text')."
  (or (harness-tasks--backlog-p task)
      (not (harness-string-blank-p (plist-get task :note)))))

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

(defun harness-tasks--cancelled-p (task)
  "Non-nil when TASK is done after the user cancelled it, its work unmerged.
That is a task whose turn was stopped (`task/cancel': its `:outcome' is
`cancelled') and that was then marked done (`task/complete', which keeps
the outcome): the cancelled column holds it, apart from the finished
work of the done column.  A task whose branch merged is finished work
whatever its last turn did -- a follow-up the user stopped after the
merge leaves the merge in place -- so it stays done."
  (and (eq (plist-get task :state) 'done)
       (equal (format "%s" (plist-get task :outcome)) "cancelled")
       (not (harness-tasks--merged-p task))))

(defun harness-tasks--cannot-continue-p (task)
  "Non-nil when TASK's round said it cannot continue (hand_in).
Its session recorded the report with `:cannot-continue', and the task
waits for the user rather than for review."
  (and (or (harness-json-true-p (plist-get task :cannot-continue))
           (harness-json-true-p (plist-get (plist-get task :report) :cannot-continue)))
       t))

(defun harness-tasks--no-merge-p (task)
  "Non-nil when TASK's round handed in work that needs no merge.
Its session recorded the report with `:no-merge': informational work,
or work that changed nothing, so nothing joins the merge queue when its
turn ends and verifying it completes the task without merging."
  (and (or (harness-json-true-p (plist-get task :no-merge))
           (harness-json-true-p (plist-get (plist-get task :report) :no-merge)))
       t))

(defun harness-tasks--to-review (id &rest plist)
  "Put task ID in review with PLIST merged in; emit `task/review'.
The feedback it was sent back with, if any, is answered: it is no
longer work sent back from review (`harness-tasks--sent-back-p').
Return the task's view."
  (let ((view (apply #'harness-tasks--set id :state 'review :merge-status nil :conflicts nil
                     :sent-back nil plist)))
    (harness-emit 'task/review view)
    view))

(defun harness-tasks--to-done (id how &rest plist)
  "Complete task ID with PLIST merged in; emit `task/done' if it was not done.
HOW says what completed it: `merged' (the merge queue merged its
branch), `finished' (its turn ended with nothing to merge or review),
`verified' (the user accepted its work, with nothing left to merge) or
`completed' (marked done by hand).  Work on it after this is a
follow-up, not feedback sent back from review
\(`harness-tasks--sent-back-p').  Return the task's view."
  (let* ((was (plist-get (harness-tasks--get id) :state))
         (view (apply #'harness-tasks--set id :state 'done :sent-back nil plist)))
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
  "Forget what this process read and wrote of the stores and of the queues.
The queues' backlog modes too (`harness-tasks--auto-queues')."
  (clrhash harness-tasks--stores)
  (clrhash harness-tasks--written)
  (clrhash harness-tasks--queues)
  (clrhash harness-tasks--auto-queues)
  (setq harness-tasks--backup-checked nil
        harness-tasks--queues-loaded nil
        harness-tasks--auto-queues-loaded nil))

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
That is pending, backlog, needs-input, review, merging, active, done or
cancelled.  A done task the user cancelled (`harness-tasks--cancelled-p')
is cancelled, not done: the done column holds finished work only.
A backlog task (`harness-tasks--backlog-p'), and the write-up an agent
does for it, show in the backlog: only the user starts one, so it is no
queued pending task (`harness-tasks--queued-p').  A task whose branch
holds a place in the merge queue shows in merging however it holds it:
queued, merging, or its session resolving the conflicts; unless that
session waits on the user, whose answer the queue then waits for too.
A task a user's message is on its way to (`harness-tasks--waking') shows
active before the turn it starts actually begins.

A session that waits for the user (`harness-session-waiting-on-user-p')
puts its task in needs-input before anything else: before it starts or
is woken, and whatever state it is in, as the session list's blocked
filter says the same of the session.  A turn that has not begun waits
for the user too: a restarted harness resumes the tasks it was working
on with a message that meets a prompt cache gone cold, and the question
that asks what goes first (harness-cowboy.el) blocks the session before
the turn starts -- the task is starting, or woken, and needs the
user."
  (pcase (plist-get task :state)
    ('pending (if (harness-tasks--backlog-p task) 'backlog 'pending))
    ('done (cond ((harness-session-waiting-on-user-p (harness-tasks--session task)) 'needs-input)
                 ((harness-tasks--waking-p task) 'active)
                 ((harness-tasks--cancelled-p task) 'cancelled)
                 (t 'done)))
    ('review 'review)
    ('refining (let ((session (harness-tasks--session task)))
                 (cond ((harness-session-waiting-on-user-p session) 'needs-input)
                       ((harness-tasks--turn-p task) 'backlog)
                       ((plist-get task :outcome) 'needs-input)
                       (t 'backlog))))
    (_ (let ((session (harness-tasks--session task)))
         (cond ((harness-session-waiting-on-user-p session) 'needs-input)
               ((gethash (plist-get task :id) harness-tasks--starting) 'active)
               ((plist-get task :merge-status) 'merging)
               ((harness-tasks--waking-p task) 'active)
               ((eq (plist-get session :status) 'running) 'active)
               ((plist-get task :outcome) 'needs-input)
               (t 'active))))))

(defun harness-tasks--waking-p (task)
  "Non-nil when a message of the user's is on its way to TASK."
  (and (gethash (plist-get task :id) harness-tasks--waking) t))

(defun harness-tasks--wake-worthy-p (task)
  "Non-nil when a user's message to TASK should show it at work at once.
That is a task stopped part way (active with an outcome) or one
completed and reopened by the message: never one in review (the message
sends it back, `harness-tasks--send-back'), nor a pending, refining or
merging one, whose column the message does not move."
  (and (memq (plist-get task :state) '(active done))
       (not (plist-get task :archived))
       (not (plist-get task :merge-status))
       (not (eq (harness-tasks--column task) 'active))))

(defun harness-tasks--wake (id)
  "Show task ID at work while the user's message to it is on its way.
Called before the message starts a turn: the turn may be held up first
-- the cold-cache compaction, say -- and until it starts the task would
still show as it stopped.  Return the task's view."
  (puthash id t harness-tasks--waking)
  (harness-tasks--set id))

(defun harness-tasks--view (task)
  "Return TASK as methods and events show it: with its `:column'.
Its `:priority' is always there: the priority plugin's
`harness-priority-of-task', which defaults a record from before
priorities to medium (`harness-priority-default').  `:queue-suspended'
is there, true, while the task's project's pending queue is suspended,
and `:auto-queue', true, while its project's backlog queues its
write-ups itself (`harness-tasks--backlog-mode'); `:joining-queue',
true, from the end of a write-up there until the task is in the queue
\(`harness-tasks--joining').  `:hold' is there while something holds a
queued task back (`harness-tasks--hold'): paused by hand, out of quota
or over a hard budget, with the reason and when it ends."
  ;; `append' copies TASK, so `plist-put' changes only the view.
  (let ((view (plist-put (append task (list :column (harness-tasks--column task)))
                         :priority (harness-priority-of-task task))))
    (when (harness-tasks--task-suspended-p task)
      (setq view (append view (list :queue-suspended t))))
    (when (harness-tasks--auto-queue-p (harness-tasks--slot-project task))
      (setq view (append view (list :auto-queue t))))
    (when (gethash (plist-get task :id) harness-tasks--joining)
      (setq view (append view (list :joining-queue t))))
    (when-let* ((hold (harness-tasks--hold task)))
      (setq view (append view (list :hold hold))))
    view))

;;;; Git

(defun harness-tasks--git-p (root)
  "Non-nil when tasks at project ROOT get worktrees and merge back."
  (and harness-tasks-worktrees
       (harness-method-exists-p 'worktree/create)
       (harness-method-exists-p 'merge/enqueue)
       (not (file-remote-p root))
       (locate-dominating-file root ".git")
       t))

(defconst harness-tasks--branch-slug-max 40
  "Most characters of a branch's slug, before the task's id.
A title's slug stops at the last whole word that fits.")

(defun harness-tasks--branch-title (task)
  "Return the title TASK's branch is named after, or nil when it has none yet.
That is the title the naming model gave the task (`:name', see Titles),
else the name its session took -- the same title, or a name the user
gave it."
  (let ((name (plist-get task :name))
        (session-name (plist-get (harness-tasks--session task) :name)))
    (cond ((not (harness-string-blank-p name)) name)
          ((not (harness-string-blank-p session-name)) session-name))))

(defun harness-tasks--title-slug (title)
  "Return TITLE as a branch slug: its words in lower case, joined by dashes.
It stops at the last whole word that fits `harness-tasks--branch-slug-max'
characters, and cuts a first word that is longer than that.  Only letters
and digits survive, so \"Fix login redirect loop (#42)\" is
\"fix-login-redirect-loop-42\".  Empty for a title with none."
  (let ((words (split-string (downcase title) "[^a-z0-9]+" t))
        (slug ""))
    (catch 'full
      (dolist (word words)
        (let ((next (if (string-empty-p slug) word (concat slug "-" word))))
          (when (> (length next) harness-tasks--branch-slug-max) (throw 'full nil))
          (setq slug next))))
    (if (and (string-empty-p slug) words)
        (substring (car words) 0 harness-tasks--branch-slug-max)
      slug)))

(defun harness-tasks--branch-name (task)
  "Return a branch name for TASK: the prefix, a slug of its title, its id.
The title is the short one the naming model gave the task as it was
submitted (`harness-tasks--branch-title'), so the branch reads like the
ticket: \"task/fix-login-redirect-loop-ab12cd34\".  A task with no title
yet -- or none that has a letter or a digit in it -- is named from the
first five words of its prompt instead, as it always was.  The id keeps
the branch unique.  The record the table holds now is read, not TASK,
which a start took before its title came."
  (let* ((task (or (gethash (plist-get task :id) harness-tasks--table) task))
         (title (harness-tasks--branch-title task))
         (slug (if title (harness-tasks--title-slug title) "")))
    (if (string-empty-p slug)
        (let ((words (split-string (downcase (harness-first-line (plist-get task :prompt)))
                                   "[^a-z0-9]+" t)))
          (setq slug (string-join (take 5 words) "-")
                slug (if (string-empty-p slug) "" (concat (harness-truncate-end slug 40) "-"))))
      (setq slug (concat slug "-")))
    (concat harness-tasks-branch-prefix slug
            ;; A record from an older store may name an id without the prefix.
            (string-remove-prefix "t-" (plist-get task :id)))))

(defun harness-tasks--make-worktree (task)
  "Return a promise of TASK's worktree plist, with `:base' the root's branch.
The branch is named after the task's title.  A title that is on its way
\(`harness-tasks--title-wait') is waited for a moment before the branch
is made, so a task that starts as it is submitted gets it too."
  (let ((root (plist-get task :project)))
    (harness-then
     (harness-call-async 'worktree/branch root)
     (lambda (base)
       (harness-then
        (harness-tasks--title-wait (plist-get task :id))
        (lambda (_)
          (harness-then
           (harness-call-async 'worktree/create root :branch (harness-tasks--branch-name task))
           (lambda (wt) (append (list :base base) wt)))))))))

(defun harness-tasks--enqueue-merge (id)
  "Queue task ID's branch for the merge queue, or put the task before the user.
The target is the project root: the main checkout, which the merge
queue takes as a target of its own.  `:merge-queued' records when the
branch joined the queue."
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
          (let ((target (plist-get task :project)))
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
  "Remove merged TASK's worktree and delete its branch; return a promise.
The branch goes with `-D`: the merge queue lands a branch as one squash
commit, so its tip is not an ancestor of the target, and `-d' would
refuse a branch whose work is in all the same.  This runs only for a
task the merge queue reported merged."
  (let ((root (plist-get task :project))
        (branch (plist-get task :branch)))
    (harness-then
     (harness-call-async 'worktree/remove root (plist-get task :worktree))
     (lambda (_)
       (harness-tasks--set (plist-get task :id) :worktree-removed t)
       (when branch
         (harness-run-command (list "git" "-C" (directory-file-name root) "branch" "-D" branch)
                              :cwd root :name "harness-tasks-git")))
     (lambda (err)
       (harness-log 'warn "task %s: keeping its worktree: %s" (plist-get task :id) (harness-error-message err))
       nil))))

;;;; The task prompts

(defconst harness-tasks-hand-in-prompt
  "Finish with the hand_in tool rather than a plain reply: it hands your summary and your evidence to the user and ends the turn, so the task waits for their review.  The problem statement is required: a short summary of what must be fixed and how to see it, which the review shows at the top, so the user remembers what the task was about from its name.  The reproduction note is optional: how to see the problem, or the steps to check the fix.  The evidence is required, and shows the work rather than describing it -- an image or a video of what you built whenever there is anything to see (take the screenshot first), and the tool call that proves a claim about a command (the tests pass, the command's output) quoted by its call id, by the tool's name (its newest call) or by the `#N` a previous hand_in error listed, so a run whose log you kept can be quoted without running it again.  A file, a code block or a note is evidence for what cannot be shown.  If you cannot finish the task, hand it in with cannot_continue true and say in the summary what blocks it: the task goes to the user's input instead of review, and nothing merges.  If the work needs no merge -- an informational task, or one that changed nothing -- pass no_merge true: the user's verification then completes it without merging.  Then stop; do not start more work."
  "What a task's session is told about handing its finished work in.")

(defun harness-tasks--system-prompt (prompt session)
  "Tell a task's SESSION what its turns are for (PROMPT filter).
Before the task starts they write it up (`harness-tasks--refine-prompt')
or plan it (`harness-tasks--plan-prompt'), a section that takes the
place of the Planning one, about tools a read-only session does not
have (`harness-readonly-system-prompt'); afterwards they learn how to
hand the finished work in, and, in a worktree, how it reaches the main
branch -- or, in the main tree \(`harness-tasks--main-tree-p'), that the
work takes effect there."
  (let ((task (harness-tasks--by-session (plist-get session :id))))
    (cond
     ((and task (harness-tasks--refinement-p task) (harness-tasks--plan-p task)
           (not (harness-string-blank-p harness-tasks--plan-prompt)))
      (harness-readonly-system-prompt prompt harness-tasks--plan-prompt))
     ((and task (harness-tasks--refinement-p task)
           (not (harness-string-blank-p harness-tasks--refine-prompt)))
      (harness-readonly-system-prompt prompt harness-tasks--refine-prompt))
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
              "Do the whole task there. Run the checks that cover what you changed while you work, and the project's own full check once before handing in, rather than the whole suite after every edit. "
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
;; naming of its first turn off meanwhile.  Nothing waits for a title: a
;; task starts with one or without, and when the request fails its
;; session is named the usual way, from the same message.  The one
;; exception is the making of the task's branch, which is named after
;; the title (`harness-tasks--branch-name'): a task that starts as it
;; is submitted would otherwise always have its branch named from its
;; prompt, the title being a second or two behind.  That wait is
;; bounded (`harness-tasks--title-wait') and only for a title already
;; requested; with none, or past it, the branch is named from the
;; prompt.  A backlog task is named the same way, from the words it was
;; written up from, and so is every task of a board found without a
;; title when the harness starts or reloads.
;;
;; The request is a model call of the harness's own, an internal job:
;; it goes straight to the provider (`provider/complete'), under an id
;; of its own that is no session and no task.  So it takes none of the
;; project's slots (`harness-tasks-max-running'), waits for none and
;; counts against none: it goes out whatever the limit, a full board or
;; a limit of 0 included, and the task it titles stays in the queue.
;; The same goes for the harness's other calls of the kind -- recaps, the
;; permission judges, compaction's summaries.  The only thing that holds
;; a request back is the throttle below, which is no part of the limit.
;;
;; The throttle is a pool of the slots library (`harness-slots'), so
;; that a burst of submissions, or a board of nameless tasks found at
;; start-up, does not send a request for each at once: at most
;; `harness-tasks--naming-concurrency' are out, and the others wait for
;; one to settle.  They go by their task's priority, the highest first
;; and the oldest first among equals, as the board orders tasks
;; (`harness-tasks--naming-rank').
;;
;; Task mode never asks for a title again.  The request is an ordinary
;; `provider/complete' request, so the layers below retry it as they do
;; any model call: the HTTP layer for the providers that speak HTTP
;; (`harness-http-request', asked to repeat a connection that was lost
;; before the answer began) and the Claude Code CLI for its own API
;; calls.  A title that still fails leaves the task untitled until its
;; turn names its session, or until the harness starts or reloads
;; (`harness-tasks--name-untitled'); no timer of this module waits to
;; ask again.

(defvar harness-naming-auto)

(defconst harness-tasks--naming-concurrency 2
  "Naming requests of tasks that may be out at once; the others wait their turn.
A burst of submissions, or a board of nameless tasks found at start-up,
would otherwise send them all at once: a process each, with Claude Code.
This throttle is the title requests' own and has nothing to do with the
project's slots (`harness-tasks-max-running'): a request takes none and
waits for none.  The waiting ones go by their task's priority
\(`harness-tasks--naming-rank'), the oldest first among equals.")

(defvar harness-tasks--naming (make-hash-table :test 'equal)
  "Task id -> the text its naming request asks a title for, while it is out.")

(defun harness-tasks--naming-rank (id)
  "Return the rank of the title request of task ID, while it waits to go out.
That is the place of its task's priority among the levels
\(`harness-priority-of-task'), as it is now, so a priority changed while
the request waits moves it, and the default for a task that is gone.
The rank function of `harness-tasks--naming-pool': the highest goes
first, and among equals the request that asked first."
  (harness-priority-rank
   (if-let* ((task (gethash id harness-tasks--table)))
       (harness-priority-of-task task)
     harness-priority-default)))

(defun harness-tasks--naming-pool-new ()
  "Return a new throttle of the title requests, with no request out or waiting.
A pool of the slots library that allows `harness-tasks--naming-concurrency'
requests at once and serves the waiting ones by `harness-tasks--naming-rank'."
  (harness-slots-create :limit (lambda () harness-tasks--naming-concurrency)
                        :rank #'harness-tasks--naming-rank))

(defvar harness-tasks--naming-pool (harness-tasks--naming-pool-new)
  "The throttle of the title requests: a pool of the slots library.
A request holds a slot from the moment it goes out until its answer, or
its failure, is taken (`harness-tasks--ask-name'); the ids of the tasks
whose request waits for one are what `harness-slots-waiters' lists.")

(defun harness-tasks--naming-p ()
  "Non-nil when tasks are named as they are submitted.
That is when sessions are named automatically (`harness-naming-auto'),
and the naming module titles a message on its own (`naming/title')."
  (and (bound-and-true-p harness-naming-auto)
       (harness-method-exists-p 'naming/title)))

(defconst harness-tasks--title-wait 8
  "Seconds the making of a task's branch waits for the title on its way.
Only the branch waits, and only for a title already requested
\(`harness-tasks--title-on-its-way-p'): a start that finds none on its
way, or one that came, goes straight on.  Past this a start goes on
without it, and the branch is named from the prompt, as it was before
branches had titles.")

(defvar harness-tasks--title-waiters (make-hash-table :test 'equal)
  "Task id -> the promises of the starts that wait for its title.
Resolved when the request that names the task settles
\(`harness-tasks--title-settled'), or when the wait is over
\(`harness-tasks--title-wait').")

(defun harness-tasks--title-on-its-way-p (task)
  "Non-nil when TASK has no title yet but its request for one is out or waits.
That is a naming request in flight (`harness-tasks--naming') or one
waiting for a slot of the throttle (`harness-tasks--naming-pool')."
  (let ((id (plist-get task :id)))
    (and (not (harness-tasks--titled-p task))
         (or (gethash id harness-tasks--naming)
             (member id (harness-slots-waiters harness-tasks--naming-pool)))
         t)))

(defun harness-tasks--title-wait (id)
  "Return a promise that settles when task ID's title is not worth waiting for.
It is resolved at once when the task has a title or none is on its way;
else when the title comes, or the request fails
\(`harness-tasks--title-settled'), or `harness-tasks--title-wait'
seconds have passed.  The value means nothing: the caller names the
branch from the task as it is then."
  (let ((task (gethash id harness-tasks--table)))
    (if (not (and task (harness-tasks--title-on-its-way-p task)))
        (harness-resolved nil)
      (let ((promise (harness-make-promise)))
        (push promise (gethash id harness-tasks--title-waiters))
        (run-at-time harness-tasks--title-wait nil (lambda () (harness-resolve promise nil)))
        promise))))

(defun harness-tasks--title-settled (id)
  "Let the starts that wait for task ID's title go on: it came, or will not."
  (let ((promises (gethash id harness-tasks--title-waiters)))
    (remhash id harness-tasks--title-waiters)
    (dolist (promise promises)
      (harness-resolve promise nil))))

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
The request waits for a slot of the throttle (`harness-tasks--naming-pool'),
where the tasks of a higher priority go first.  This never signals and
nothing waits for it: a task does not wait for, nor fail with, its
title."
  (condition-case err
      (when (and (harness-tasks--naming-p)
                 (not (member id (harness-slots-waiters harness-tasks--naming-pool)))
                 (not (gethash id harness-tasks--naming)))
        (harness-then (harness-slots-acquire harness-tasks--naming-pool id)
                      (lambda (ticket) (harness-tasks--naming-granted id ticket) nil)))
    (error (harness-log 'warn "naming task %s failed: %s" id (harness-error-message err)))))

(defun harness-tasks--naming-granted (id ticket)
  "Send the request naming task ID, for which the throttle gave a slot.
TICKET gives the slot back.  The request goes out when the task still
wants a title (`harness-tasks--wants-name-p') and none of its requests
is out; it gives the slot back when it is answered.  Otherwise the slot
goes back at once: a task that started while its request waited has its
session named as the turn starts.  This never signals."
  (condition-case err
      (let ((task (gethash id harness-tasks--table)))
        (if (and task
                 (not (gethash id harness-tasks--naming))
                 (harness-tasks--wants-name-p task))
            (harness-tasks--ask-name task ticket)
          (funcall ticket)))
    (error
     (remhash id harness-tasks--naming)
     (funcall ticket)
     (harness-log 'warn "naming task %s failed: %s" id (harness-error-message err)))))

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

(defun harness-tasks--ask-name (task ticket)
  "Send the request naming TASK, which holds the slot TICKET gives back.
`harness-tasks--named' takes its answer, or its failure, and then the
slot goes back, so the next request that waits for one can go out."
  (let ((id (plist-get task :id))
        (text (harness-tasks--naming-text task)))
    (puthash id text harness-tasks--naming)
    (harness-then (condition-case err
                      (harness-call 'naming/title text
                                    (list :task id :model (harness-tasks--naming-model task)
                                          :cwd (plist-get task :cwd)))
                    (error (harness-rejected err)))
                  (lambda (name)
                    (unwind-protect (harness-tasks--named id text name nil)
                      (funcall ticket))
                    nil)
                  (lambda (err)
                    (unwind-protect (harness-tasks--named id text nil err)
                      (funcall ticket))
                    nil))))

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
the start of that turn left it to this request.  A request that failed
is not made again here: the layers below retried it already (see
Titles), and the task stays untitled until its turn names its session,
or the harness starts or reloads (`harness-tasks--name-untitled')."
  (remhash id harness-tasks--naming)
  (unwind-protect
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
        (error (harness-log 'warn "naming task %s failed: %s" id (harness-error-message problem))))
    ;; Whichever way it went, the branch of a task that waits for its
    ;; title is named from what there is.
    (harness-tasks--title-settled id)))

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

;;;; Queue suspension
;;
;; A project's pending queue can be suspended: the scheduler then starts
;; none of its waiting tasks on its own, so the board is clear for one
;; urgent task, which `task/start' still starts (as it starts a task
;; whatever the limit).  The suspension is per project, like
;; `harness-tasks-max-running', and outlives a restart: the projects
;; whose queue is suspended are named in `harness-tasks--queue-name' in
;; the state directory.  `task/suspend-queue', `task/resume-queue' and
;; `task/toggle-queue' (the board's P, task_control's suspend-queue and
;; resume-queue) are the only ways it changes; resuming schedules at
;; once, so the waiting tasks start again up to the limit.

(defun harness-tasks--queue-file ()
  "Return the path of the file naming the projects with a suspended queue."
  (expand-file-name harness-tasks--queue-name (harness-tasks--state-directory)))

(defun harness-tasks--queue-key (project)
  "Return PROJECT as the key suspended queues are kept under, or nil."
  (and project (file-name-as-directory (expand-file-name project))))

(defun harness-tasks--load-queues ()
  "Read the suspended queues once from this harness's state directory."
  (unless harness-tasks--queues-loaded
    (setq harness-tasks--queues-loaded t)
    (clrhash harness-tasks--queues)
    (dolist (project (harness-json-parse (harness-read-file (harness-tasks--queue-file))))
      (when (stringp project)
        (puthash (harness-tasks--queue-key project) t harness-tasks--queues)))))

(defun harness-tasks--save-queues ()
  "Write the suspended queues now; an empty set deletes the file."
  (let ((projects (sort (hash-table-keys harness-tasks--queues) #'string<))
        (path (harness-tasks--queue-file)))
    (if projects
        (harness-tasks--write-json path (harness-json-array projects))
      (harness-tasks--delete-json path))))

(defun harness-tasks--suspended-p (project)
  "Non-nil when PROJECT's pending queue is suspended."
  (harness-tasks--load-queues)
  (and (harness-tasks--queue-key project)
       (gethash (harness-tasks--queue-key project) harness-tasks--queues)
       t))

(defun harness-tasks--task-suspended-p (task)
  "Non-nil when TASK's project's pending queue is suspended."
  (harness-tasks--suspended-p (harness-tasks--slot-project task)))

(defun harness-tasks--set-suspended (project suspended)
  "Suspend PROJECT's queue when SUSPENDED, else resume it; return the state.
The change is written at once and emitted as `task/queue' (PROJECT
SUSPENDED), which the boards follow."
  (harness-tasks--load-queues)
  (let* ((key (harness-tasks--queue-key project))
         (now (and suspended t))
         (was (and key (gethash key harness-tasks--queues) t)))
    (when (and key (not (eq now was)))
      (if now
          (puthash key t harness-tasks--queues)
        (remhash key harness-tasks--queues))
      (harness-tasks--save-queues)
      (harness-emit 'task/queue key now))
    now))

;;;; Holds
;;
;; A queued task can be held: the scheduler leaves it in the queue, with
;; the reason on its card, until what holds it is over.  A hold is one of
;;
;;   paused  the user paused the task (`task/pause'): `:paused' on its
;;           record says since when, and nothing but `task/resume' (or an
;;           explicit `task/start', or a turn the user starts in its
;;           session) ends it.  It is kept with the record, so it
;;           outlives a restart: the scheduler that starts the waiting
;;           tasks as the harness comes up leaves it alone.
;;   quota   everything the task's session could run on has run out of
;;           quota or money (`fallback/blocked'): its own model, and every
;;           entry of `harness-fallback-models' it may carry on with.
;;           `:until' is when the first of them is tried again.
;;   budget  a hard budget that covers the task's session is spent
;;           (`usage/budget-hold'); `:until' is when its period ends, nil
;;           when only changing or deleting the budget lets the task go on.
;;
;; Quota and budget holds are worked out, not stored: the scheduler asks
;; the fallback and the usage module at every pass
;; (`harness-tasks--refresh-holds'), for tasks that never started as much
;; as for tasks parked by a stopped turn, so a task is never started
;; into an outage only to fail at once, and one a restart finds waiting
;; needs nothing kept to know why.  What makes a hold end is told by
;; events -- `fallback/changed' (a mark ended or was cleared, a quota
;; report came), `usage/budgets-changed', `config/changed' for the
;; fallback list and the Budget setting -- and by a timer at the
;; earliest `:until' there is (`harness-tasks--arm-hold-timer'), each of
;; which runs the scheduler.  A hold that ended starts the task like any
;; queued task: by priority, within the limit, unless its queue is
;; suspended.
;;
;; Parking: a turn that ends `error' or `blocked' while its task is held
;; for quota or a budget -- every provider ran out, or a hard budget
;; stopped the turn between two steps or before it began -- is no
;; failure of the task.  It goes back to pending (`harness-tasks--park')
;; as a task returned to pending does, keeping its session, branch and
;; worktree, with `:return-reason' `quota' or `budget'; when the hold
;; ends it carries on where it stopped, told why by
;; `harness-tasks--quota-message' or `harness-tasks--budget-message'.

(defun harness-tasks--paused-p (task)
  "Non-nil when the user paused TASK, which waits to be resumed.
`:paused' is the time it was paused."
  (and (plist-get task :paused) t))

(defun harness-tasks--quota-hold (session-id)
  "Return the quota hold of the session SESSION-ID, or nil when a model works.
The answer of `fallback/blocked', as a hold: (:kind quota :reason TEXT
:until TIME :guess BOOL :items MARKS)."
  (when (harness-method-exists-p 'fallback/blocked)
    (condition-case err
        (when-let* ((blocked (harness-call 'fallback/blocked session-id)))
          (list :kind 'quota
                :reason (plist-get blocked :reason)
                :until (plist-get blocked :until)
                :guess (if (plist-get blocked :guess) t :false)
                :items (plist-get blocked :marks)))
      (error (harness-log 'warn "tasks: asking whether %s is out of quota failed: %s"
                          session-id (harness-error-message err))
             nil))))

(defun harness-tasks--budget-hold (session-id)
  "Return the budget hold of the session SESSION-ID, or nil.
Nil while no hard budget that covers it is spent.  The answer of
`usage/budget-hold', as a hold: (:kind budget :reason TEXT :until TIME
:guess :false :items BUDGETS)."
  (when (harness-method-exists-p 'usage/budget-hold)
    (condition-case err
        (when-let* ((hold (harness-call 'usage/budget-hold session-id)))
          (list :kind 'budget
                :reason (plist-get hold :reason)
                :until (plist-get hold :until)
                :guess :false
                :items (plist-get hold :budgets)))
      (error (harness-log 'warn "tasks: asking whether %s is over its budget failed: %s"
                          session-id (harness-error-message err))
             nil))))

(defun harness-tasks--compute-hold (task)
  "Return the quota or budget hold on TASK's work as it is now, or nil.
Quota first: a task out of both is shown the quota, and its budget once
that is back.  Nil for a task with no session.  This asks; the
scheduler's table (`harness-tasks--holds') is what the rest reads."
  (when-let* ((sid (plist-get task :session)))
    (or (harness-tasks--quota-hold sid)
        (harness-tasks--budget-hold sid))))

(defun harness-tasks--hold (task)
  "Return why queued TASK is held back from starting, a plist, or nil.
`:kind' is `paused' (the user paused it, `:since' when), `quota' or
`budget' (`harness-tasks--compute-hold', as the scheduler found it at
its last pass); `:reason' says what for, `:until' when it ends (nil: not
by itself), `:guess' whether that is a retry time rather than a reset,
`:items' the marks or budgets behind it.  Nil for a task that is not in
the queue (`harness-tasks--queued-p') and for one nothing holds."
  (when (harness-tasks--queued-p task)
    (if (harness-tasks--paused-p task)
        (let ((since (plist-get task :paused)))
          (list :kind 'paused :since (and (numberp since) since)))
      (gethash (plist-get task :id) harness-tasks--holds))))

(defun harness-tasks--hold-signature (hold)
  "Return what makes HOLD the hold it is: its kind, its end and what is behind it.
The reason's text and a budget's figures change as others spend, which
makes it no other hold: `harness-tasks--refresh-holds' announces a hold
when this changes."
  (and hold
       (list (plist-get hold :kind)
             (plist-get hold :until)
             (mapcar (lambda (item) (or (plist-get item :key) (plist-get item :id)))
                     (plist-get hold :items)))))

(defun harness-tasks--refresh-holds ()
  "Work out the holds of the queued tasks again and time the first to end.
A task whose hold began, changed or ended is announced (`task/changed'),
so its card says why it waits, or starts.  A paused task needs no
asking.  Return the ids announced."
  (let (changed)
    (dolist (id (hash-table-keys harness-tasks--holds))
      (let ((task (gethash id harness-tasks--table)))
        (unless (and task (harness-tasks--queued-p task) (not (harness-tasks--paused-p task)))
          (remhash id harness-tasks--holds))))
    (dolist (task (harness-tasks--sorted #'harness-tasks--queued-p))
      (unless (harness-tasks--paused-p task)
        (let* ((id (plist-get task :id))
               (old (gethash id harness-tasks--holds))
               (new (harness-tasks--compute-hold task)))
          (unless (equal (harness-tasks--hold-signature old) (harness-tasks--hold-signature new))
            (if new
                (puthash id new harness-tasks--holds)
              (remhash id harness-tasks--holds))
            (push id changed)))))
    (dolist (id (nreverse changed))
      (when-let* ((task (gethash id harness-tasks--table)))
        (harness-emit 'task/changed (harness-tasks--view task))))
    (harness-tasks--arm-hold-timer)
    changed))

(defun harness-tasks--arm-hold-timer ()
  "Have the scheduler run once the earliest hold ends, if one has an end.
Re-armed at every pass, so it follows holds that begin, change or go.
It fires a second late, when a mark or a period has surely ended, and
never sooner than two seconds on: a hold whose end passed without
lifting is looked at again then, not in a loop."
  (when (timerp harness-tasks--hold-timer) (cancel-timer harness-tasks--hold-timer))
  (setq harness-tasks--hold-timer nil)
  (let (soonest)
    (maphash (lambda (_ hold)
               (let ((until (plist-get hold :until)))
                 (when (numberp until)
                   (setq soonest (if soonest (min soonest until) until)))))
             harness-tasks--holds)
    (when soonest
      (setq harness-tasks--hold-timer
            (run-at-time (max 2 (- (+ soonest 1) (float-time))) nil #'harness-tasks--hold-due)))))

(defun harness-tasks--hold-due ()
  "Run the scheduler: the earliest hold ended, or may have."
  (setq harness-tasks--hold-timer nil)
  (harness-tasks--schedule))

(defun harness-tasks--on-hold-event (&rest _)
  "Look at the holds again soon: quota or a budget changed.
On `fallback/changed' (a mark ended or was cleared, a quota report
came, a session moved) and `usage/budgets-changed'.  The scheduler
starts the tasks whose hold is over.  Once for a burst of events."
  (harness-debounce 'harness-tasks-holds 0.1 #'harness-tasks--schedule))

(defun harness-tasks--park-hint (hold)
  "Return the hint saying in a task's session that HOLD sent it back to the queue."
  (format "Back in the queue until it can go on: %s" (plist-get hold :reason)))

(defun harness-tasks--park (id hold)
  "Put task ID back in the queue: its work cannot go on, for HOLD.
HOLD is a quota or budget hold (`harness-tasks--compute-hold') found as
the task's turn ended.  The task is returned to pending as
`task/return-to-pending' returns one -- its session, branch and
worktree kept, first in line of its priority -- with `:return-reason'
`quota' or `budget', and the hold is its own at once, so the card that
announces the change says why it waits.  The turn is over already; what
its session left running outside it stops (`harness-tasks--stop-outstanding'),
and the session says why the task waits.  Return the task's view."
  (let ((sid (plist-get (harness-tasks--get id) :session)))
    (harness-log 'info "task %s: its work cannot go on, so it waits in the queue: %s"
                 id (plist-get hold :reason))
    (puthash id hold harness-tasks--holds)
    (prog1 (harness-tasks--to-pending id :return-reason (plist-get hold :kind))
      (when (and sid (harness-call 'session/exists-p sid))
        (harness-call 'session/hint sid (harness-tasks--park-hint hold)))
      (harness-tasks--stop-outstanding id)
      (harness-tasks--arm-hold-timer))))

;;;; Pausing
;;
;; `task/pause' is what the board's Pause does, and sticks: a task at
;; work goes back to pending as `task/return-to-pending' sends it, its
;; turn stopped and the work it left running with it, and is marked
;; paused (`:paused'), a hold the scheduler keeps (above).  A task
;; waiting in the queue is paused where it is.  `task/resume' ends the
;; hold, and the queue starts the task by priority within the limit as it
;; starts any, unless its queue is suspended too: pausing tasks and
;; suspending queues are independent, and each is kept across a restart
;; -- the paused tasks in their records, the suspended queues in
;; `harness-tasks--queue-name'.  `task/pause-all' and `task/resume-all'
;; do it for every task of a project, or of every project.  Pausing
;; every task includes the waiting ones: the slots the paused tasks free
;; would otherwise start them.

(defun harness-tasks--at-work-p (task)
  "Non-nil when TASK is at work: in progress, or waiting on the user mid-work.
That is an active task that is starting, or not stopped part way (no
`:outcome') and not in the merge queue: what `task/pause-all' stops."
  (and (eq (plist-get task :state) 'active)
       (not (plist-get task :archived))
       (not (plist-get task :merge-status))
       (or (gethash (plist-get task :id) harness-tasks--starting)
           (null (plist-get task :outcome)))))

(defun harness-tasks--pause (id)
  "Pause task ID: back in the queue, and held there until it is resumed.
A task at work is returned to pending as `task/return-to-pending' does
-- its turn stopped, then the work its session left running; one still
starting gives its slot up as a pre-empted one does -- and marked
`:paused'.  One that waits for a slot is marked where it is.  A task
already paused stays as it was.  Return the task's view."
  (let ((task (harness-tasks--get id)))
    (cond
     ((harness-tasks--paused-p task) (harness-tasks--put task))
     ((harness-tasks--queued-p task)
      (harness-log 'info "task %s: paused in the queue" id)
      (harness-tasks--set id :paused (float-time)))
     ((and (eq (plist-get task :state) 'active) (not (plist-get task :archived)))
      (harness-log 'info "task %s: paused" id)
      (remhash id harness-tasks--starting)
      ;; The queue first, then the turn (see `task/return-to-pending').
      (prog1 (harness-tasks--to-pending id :paused (float-time))
        (unless (harness-tasks--stop-turn id)
          (harness-tasks--stop-outstanding id))
        (harness-tasks--schedule id)))
     (t (error "Task %s is %s; only a task at work or waiting for a slot can be paused"
               id (harness-tasks--column task))))))

(defun harness-tasks--unpause (id)
  "End the pause of task ID; the queue starts it when its turn comes.
A task that is not paused stays as it was.  Return the task's view."
  (let ((task (harness-tasks--get id)))
    (if (not (harness-tasks--paused-p task))
        (harness-tasks--put task)
      (harness-log 'info "task %s: resumed" id)
      (prog1 (harness-tasks--set id :paused nil)
        (harness-tasks--schedule)))))

;;;; Backlog mode
;;
;; Whether a project's written-up tasks wait in its backlog for someone
;; to queue them (`manual', the default) or queue themselves as their
;; write-up finishes (`auto').  It is kept as the suspended queues are:
;; the projects in auto mode are named in `harness-tasks--auto-queue-name'
;; in the state directory, read the first time a mode is asked for.
;; `task/set-backlog-mode' and `task/toggle-backlog-mode' (the board's
;; toggle on its Backlog heading, task_control's auto-queue and
;; manual-queue) change it and emit `task/backlog-mode' (PROJECT MODE);
;; the end of a write-up reads it (`harness-tasks--auto-queue').

(defconst harness-tasks-backlog-modes '(manual auto)
  "The modes a project's backlog can be in, the default first.
In `manual' a written-up task waits in the backlog until someone queues
it (`task/queue') or starts it (`task/start'); in `auto' its write-up's
end queues it (`harness-tasks--auto-queue').")

(defun harness-tasks--auto-queue-file ()
  "Return the path of the file naming the projects whose backlog queues itself."
  (expand-file-name harness-tasks--auto-queue-name (harness-tasks--state-directory)))

(defun harness-tasks--load-auto-queues ()
  "Read the projects in auto backlog mode once from this harness's state directory."
  (unless harness-tasks--auto-queues-loaded
    (setq harness-tasks--auto-queues-loaded t)
    (clrhash harness-tasks--auto-queues)
    (dolist (project (harness-json-parse (harness-read-file (harness-tasks--auto-queue-file))))
      (when (stringp project)
        (puthash (harness-tasks--queue-key project) t harness-tasks--auto-queues)))))

(defun harness-tasks--save-auto-queues ()
  "Write the projects in auto backlog mode now; none left deletes the file."
  (let ((projects (sort (hash-table-keys harness-tasks--auto-queues) #'string<))
        (path (harness-tasks--auto-queue-file)))
    (if projects
        (harness-tasks--write-json path (harness-json-array projects))
      (harness-tasks--delete-json path))))

(defun harness-tasks--auto-queue-p (project)
  "Non-nil when PROJECT's backlog queues its write-ups itself (auto mode)."
  (harness-tasks--load-auto-queues)
  (let ((key (harness-tasks--queue-key project)))
    (and key (gethash key harness-tasks--auto-queues) t)))

(defun harness-tasks--backlog-mode (project)
  "Return PROJECT's backlog mode, `manual' or `auto'.
See `harness-tasks-backlog-modes'."
  (if (harness-tasks--auto-queue-p project) 'auto 'manual))

(defun harness-tasks--read-backlog-mode (mode)
  "Return MODE, a symbol or its name, as one of `harness-tasks-backlog-modes'.
Signal an error for anything else."
  (let ((symbol (cond ((stringp mode) (intern-soft (downcase (string-trim mode))))
                      ((symbolp mode) mode))))
    (or (car (memq symbol harness-tasks-backlog-modes))
        (signal 'harness-error (list (format "Unknown backlog mode %S: it is manual or auto" mode))))))

(defun harness-tasks--set-backlog-mode (project mode)
  "Put PROJECT's backlog in MODE, `manual' or `auto'; return the mode.
The change is written at once and emitted as `task/backlog-mode'
\(PROJECT MODE), which the boards follow.  It moves no task: auto mode
queues each task as its write-up finishes, not the ones already
waiting in the backlog, and manual mode takes none out of the queue."
  (harness-tasks--load-auto-queues)
  (let* ((key (harness-tasks--queue-key project))
         (auto (eq mode 'auto))
         (was (and key (gethash key harness-tasks--auto-queues) t)))
    (when (and key (not (eq auto was)))
      (if auto
          (puthash key t harness-tasks--auto-queues)
        (remhash key harness-tasks--auto-queues))
      (harness-tasks--save-auto-queues)
      (harness-emit 'task/backlog-mode key (if auto 'auto 'manual)))
    (if auto 'auto 'manual)))

(defun harness-tasks--auto-queue (id)
  "Queue task ID, just written up, when its project's backlog queues itself.
In auto backlog mode (`harness-tasks--backlog-mode') the end of a
write-up hands the task to `task/queue', which takes it out of the
backlog to the pending queue: the scheduler starts it there like any
queued task, by priority, within the limit and not while the queue is
suspended.  That happens soon after, out of the end of the turn
\(`harness-run-soon'), as `task/queue' may start the task, and only
while the task is still as the write-up left it: in the backlog, no
turn of its session running and no message queued in its session --
feedback the user queued for the write-up starts another one, whose
end queues the task instead.  A write-up done again after feedback
queues the task the same way: in auto mode a finished write-up does
not wait in the backlog.

It is called as the write-up ends, before the task goes to the backlog,
so that the view announcing that already says the task joins the queue
\(`harness-tasks--joining'): a wait on the task does not settle on it
there.  A task left in the backlog after all is announced again,
without it."
  (when-let* ((task (gethash id harness-tasks--table))
              ((harness-tasks--auto-queue-p (harness-tasks--slot-project task))))
    (puthash id t harness-tasks--joining)
    (harness-run-soon
     (lambda ()
       (remhash id harness-tasks--joining)
       (let ((queued nil))
         (when-let* ((task (gethash id harness-tasks--table))
                     ((eq (plist-get task :state) 'pending))
                     ((harness-tasks--backlog-p task))
                     ((not (plist-get task :archived)))
                     ((harness-tasks--auto-queue-p (harness-tasks--slot-project task)))
                     ((not (harness-tasks--turn-p task))))
           (if (plist-get (harness-tasks--session task) :queue)
               (harness-log 'info "task %s: written up, but more for its write-up is queued: it stays in the backlog for now" id)
             (harness-log 'info "task %s: written up in auto backlog mode, so it joins the queue" id)
             (condition-case err
                 (progn (harness-call 'task/queue id)
                        (setq queued t))
               (error (harness-log 'warn "task %s: queueing it after its write-up failed: %s"
                                   id (harness-error-message err))))))
         ;; Where it is, it no longer joins the queue: its views say so.
         (unless queued
           (when-let* ((task (gethash id harness-tasks--table)))
             (harness-emit 'task/changed (harness-tasks--view task)))))))))

;;;; Scheduling
;;
;; `harness-tasks-max-running' limits each project on its own: every
;; project has that many slots, and its queued tasks wait only for its
;; own working tasks, so a busy board never holds up another project's.
;; Queued tasks take free slots in start order
;; (`harness-tasks--start-order'): by priority; among equals, work sent
;; back from review first, then the tasks returned to pending, then the
;; oldest.  What lists waiting tasks lists them so: the board's Pending,
;; `task/slots' and `task/queue-order'.
;;
;; Only top-level sessions take slots (`harness-tasks--holds-slot-p'): a
;; task holds one while its own session, which no other session started,
;; works on the task.  The sessions working for a task never take one of
;; their own: its sub-agents and forks are part of its work, the merge
;; queue's conflict resolvers part of the merge.  Nor does the merge
;; queue, which the limit does not hold up (`task/verify' queues a
;; branch at once): a task in it (merging) holds no slot, even while
;; its own session commits or resolves the conflicts.
;;
;; The harness's own model calls -- the title of a task (see Titles), a
;; recap, a permission or emacs_eval judge, a compaction's summary -- are
;; internal jobs: none is a turn, and none makes a session or a task, so
;; the limit is blind to them.  They go straight to `provider/complete',
;; take no slot, wait for none and are not counted; the gate that holds
;; the turns of a waiting task's session (`harness-tasks--before-turn')
;; never sees them.  Nor do they wait for a tool slot (see the
;; tool-slots module): a judge decides before its call asks for one.
;; They cannot ask the user anything, so non-interactive mode has
;; nothing to say to them.
;;
;; The limit changes while tasks wait: the board's "N at a time" button
;; sets it through `config/set', and its `config/changed' runs the
;; scheduler, so a higher limit starts waiting tasks at once.  A lower
;; one stops no task at work; fewer start after.
;;
;; Pre-emption: the one thing that stops a task at work for another is
;; work the user sent back from review.  A task in review holds no slot,
;; and while it waits, the slot it had goes to the next task in line; so
;; sending it back (`task/reject', or the user's message to its session,
;; `harness-tasks--on-message') is held to the limit like any start
;; (`harness-tasks--make-room').  With a slot free it works at once.
;; With none it takes the slot of a task at work it outranks
;; (`harness-tasks--outranks-p'): one of a lower priority, or of its own
;; priority unless that one was sent back from review too -- feedback on
;; reviewed work goes before work that just started.  The task giving
;; its slot up (`harness-tasks--victim') is the one of the lowest
;; priority, one that only started before one sent back, the one that
;; started last of those; it is pre-empted (`harness-tasks--preempt'):
;; back in the queue, its turn stopped, and when the queue starts it
;; again its session carries on, told so by
;; `harness-tasks--preempted-message' as a restart's resume tells it.
;; A task still starting can give its slot up too: its start launches
;; nothing once its worktree is ready (`harness-tasks--start-current-p').
;; So can one waiting on work its session left running (`:waiting'),
;; such as a supervisor's workers: that work stops with it, as the work
;; left running by any task pre-empted or returned to pending does,
;; once no turn of its session runs (`harness-tasks--stop-outstanding'),
;; and what it was on is reported to the session for when the task
;; carries on.  When every task at work outranks it -- or the project's
;; queue is suspended, or the limit is 0 -- the sent-back task waits in
;; the queue instead (`harness-tasks--hold-back'), ahead of the rest of
;; its priority, with its feedback, and its session takes no turn until
;; it starts (`harness-tasks--before-turn'); the scheduler lets it
;; pre-empt as soon as it outranks a task at work (a priority changed,
;; say: `harness-tasks--on-priority-changed').  Nothing else pre-empts but
;; a lender taking its slot back (below): a new task, a returned or
;; pre-empted one and a follow-up only take free slots, and a priority
;; changed otherwise only reorders the queue.
;;
;; Lending: a task whose own session waits on the user keeps its slot,
;; its turn going on once answered -- until it has waited
;; `harness-tasks-lend-blocked-slot-after'.  Then it lends the slot
;; (`harness-tasks--lending-p'): it holds none, so the scheduler fills
;; it like any free slot, by priority.  How long it has waited is how
;; long its session has been blocked (`harness-tasks--blocked-since'),
;; and a timer per blocked task runs the scheduler when the wait is up
;; (`harness-tasks--arm-lend-timer'), as nothing else happens then.  A
;; task that waits on work its session left running (`:waiting', or
;; work `agent/outstanding' reports mid-turn) lends nothing, as that
;; work goes on, and neither does a task working in a borrowed slot,
;; whose slot is the lender's.  The task the queue starts in a lent
;; slot -- the slot free only because a task lends it -- is its
;; borrower, and says whose slot it took (`:borrowed-from',
;; `harness-tasks--note-borrow'); so is work sent back from review that
;; takes one (`harness-tasks--make-room').  An explicit `task/start'
;; ignores the limit and borrows nothing.  The loan ends when the
;; lender's session is answered (`harness-tasks--on-session-status'):
;; the lender is at work again, and when its project is over its limit
;; for it, its borrower is pre-empted -- `:return-reason' `reclaimed',
;; back at the front of the queue, its turn and the work it left
;; running stopped, its session, branch and worktree kept
;; (`harness-tasks--reclaim').  A borrower that gave its slot up
;; already, or a lender that stopped some other way, ends the loan with
;; nothing to stop (`harness-tasks--tidy-loans'); a project with a slot
;; free for the lender stops nothing either.

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
its turn goes on once answered -- until it has waited long enough to
lend it (`harness-tasks--lending-p'), when it holds none.  So does one
that waits on work its session left running (`:waiting', see
`agent/outstanding'), such as the workers of a supervisor's plan.  Only
that session counts, and only when it is top-level
\(`harness-tasks--top-level-p'): the sub-agents, forks and conflict
resolvers working for a task take no slot of their own, and neither
does a sub-agent made a task (`task/adopt'), which works for the
session that started it.  A task in the merge queue (merging) holds
none, even while its own session commits or resolves the conflicts,
and nor does writing a backlog task up (refining)."
  (let ((session nil))
    (and (or (gethash (plist-get task :id) harness-tasks--starting)
             (and (eq (plist-get task :state) 'active)
                  (setq session (harness-tasks--session task))
                  (harness-tasks--top-level-p session)
                  (or (plist-get task :waiting)
                      (memq (plist-get session :status) '(running blocked)))))
         (not (harness-tasks--lending-p task session)))))

(defun harness-tasks--lending-on-p ()
  "Non-nil when a task blocked on the user may lend its slot.
That takes slots, `harness-tasks-max-running' above 0, and a wait,
`harness-tasks-lend-blocked-slot-after' a number of seconds."
  (and (numberp harness-tasks-max-running) (> harness-tasks-max-running 0)
       (numberp harness-tasks-lend-blocked-slot-after)))

(defun harness-tasks--blocked-since (session)
  "Return since when SESSION has been blocked on the user, a float time, or nil.
That is when its status last became `blocked' (`harness-tasks--blocked-at'),
else when its oldest pending request was made (`session/pending-add'
stamps `:created'): a permission request, an ask_user question, the
harness's own question about a cold prompt cache.  Nil when SESSION is
not blocked (`harness-session-waiting-on-user-p')."
  (when (harness-session-waiting-on-user-p session)
    (or (gethash (plist-get session :id) harness-tasks--blocked-at)
        (let ((times (delq nil (mapcar (lambda (item)
                                         (let ((at (plist-get item :created)))
                                           (and (numberp at) at)))
                                       (plist-get session :pending)))))
          (and times (apply #'min times))))))

(defun harness-tasks--blocked-p (task &optional session)
  "Non-nil when active TASK's own top-level session is blocked on the user.
SESSION is TASK's session plist when the caller has it.  It is blocked
when it waits for the user (`harness-session-waiting-on-user-p'): the
same question the board's needs-input column and the session list's
blocked filter ask."
  (and (eq (plist-get task :state) 'active)
       (let ((session (or session (harness-tasks--session task))))
         (and (harness-tasks--top-level-p session)
              (harness-session-waiting-on-user-p session)))))

(defun harness-tasks--lend-due-at (task &optional session)
  "Return when TASK, blocked on the user, has waited long enough to lend its slot.
A float time, or nil when TASK is not blocked (`harness-tasks--blocked-p')
or nothing is lent (`harness-tasks--lending-on-p').  SESSION is TASK's
session plist when the caller has it."
  (when (and (harness-tasks--lending-on-p) (eq (plist-get task :state) 'active))
    (let ((session (or session (harness-tasks--session task))))
      (when (harness-tasks--blocked-p task session)
        (when-let* ((since (harness-tasks--blocked-since session)))
          (+ since harness-tasks-lend-blocked-slot-after))))))

(defun harness-tasks--lending-p (task &optional session)
  "Non-nil when TASK lends its slot, as it has waited on the user long enough.
That is a task at work whose own top-level session has been blocked on
the user (`harness-tasks--blocked-since') for at least
`harness-tasks-lend-blocked-slot-after', while slots limit its project
\(`harness-tasks--lending-on-p').  It holds no slot then
\(`harness-tasks--holds-slot-p'), and the queue may start a task in it,
whose turn stops when the user answers (`harness-tasks--reclaim').  A
task that waits on work its session left running lends nothing, as that
work goes on: `:waiting', once its turn ended, or work `agent/outstanding'
reports mid-turn, such as sub-agents.  Nor does a task working in a
borrowed slot (`:borrowed-from'): the slot is the lender's.  SESSION is
TASK's session plist when the caller has it."
  (and (not (plist-get task :waiting))
       (not (plist-get task :borrowed-from))
       (when-let* ((due (harness-tasks--lend-due-at task session)))
         (>= (float-time) due))
       (not (harness-tasks--outstanding task))))

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

(defun harness-tasks--queued-since (task)
  "Return when queued TASK began waiting for a slot, a float time.
That is its `:queued-at', stamped whenever a task joins the queue: at
submission, when `task/queue' takes it out of the backlog, and when it
is put back (`harness-tasks--to-pending': returned by hand, pre-empted,
sent back from review while no slot could take it).  A record from
before that has none and says when it was returned, else when it was
created."
  (or (plist-get task :queued-at) (plist-get task :returned) (plist-get task :created)
      (float-time)))

(defconst harness-tasks--waits-kept 20
  "Most waits a task keeps in `:waits', the newest first.")

(defun harness-tasks--waits-after (task started)
  "Return TASK's `:waits' with the wait that ends as it starts at STARTED.
TASK is queued (`harness-tasks--queued-p'), so it has waited since
`harness-tasks--queued-since'.  The wait is a plist of `:at' (STARTED),
`:seconds' (how long it waited) and `:priority' (the level's name, at
which it waited, as its start finds it), first in the list; no more
than `harness-tasks--waits-kept' are kept.  The slot view sums them up
per priority (`task/slots')."
  (cons (list :at started
              :seconds (max 0.0 (- started (harness-tasks--queued-since task)))
              :priority (symbol-name (harness-priority-of-task task)))
        (take (1- harness-tasks--waits-kept) (plist-get task :waits))))

(defun harness-tasks--outranks-p (task other)
  "Non-nil when TASK, sent back from review, may take the slot of OTHER.
OTHER is a task at work.  TASK outranks it when its priority is above
OTHER's, or the same while OTHER is not itself work sent back from
review (`harness-tasks--sent-back-p'): feedback on work the user
reviewed goes before work of its priority that just started, never
before other feedback of its priority."
  (let ((mine (harness-priority-of-task task))
        (theirs (harness-priority-of-task other)))
    (or (harness-priority-above-p mine theirs)
        (and (eq mine theirs) (not (harness-tasks--sent-back-p other))))))

(defun harness-tasks--preemptible-p (task)
  "Non-nil when TASK holds a slot that work sent back from review may take.
That is every task holding one (`harness-tasks--holds-slot-p'): its
session running or waiting on the user mid-turn, the task still
starting, or waiting on work its session left running outside its
turn (`:waiting'), such as a supervisor's workers.  Pre-empting it
stops that work too (`harness-tasks--stop-outstanding'), so the slot
it held is free.  A task that lends its slot while it waits on the user
\(`harness-tasks--lending-p') holds none, so it is not one."
  (harness-tasks--holds-slot-p task))

(defun harness-tasks--working-since (task)
  "Return when TASK's current work began, a float time.
That is when it started, or when it was sent back from review after
that (`:sent-back')."
  (max (or (plist-get task :started) 0) (or (plist-get task :sent-back) 0)))

(defun harness-tasks--preempt-first-p (a b)
  "Non-nil when task A, at work, gives its slot up before task B.
The lower priority goes first; among equals a task that only started
goes before one sent back from review, and the one whose work began
last before the others: it has the least to lose."
  (let ((pa (harness-priority-of-task a))
        (pb (harness-priority-of-task b)))
    (cond ((not (eq pa pb)) (harness-priority-above-p pb pa))
          ((not (eq (harness-tasks--sent-back-p a) (harness-tasks--sent-back-p b)))
           (not (harness-tasks--sent-back-p a)))
          (t (> (harness-tasks--working-since a) (harness-tasks--working-since b))))))

(defun harness-tasks--victim (task)
  "Return the task at work whose slot TASK, sent back from review, takes, or nil.
Only a task of TASK's project that holds a slot
\(`harness-tasks--preemptible-p'), one waiting on work its session left
running included, and that TASK outranks
\(`harness-tasks--outranks-p') gives one up: of those, the first by
`harness-tasks--preempt-first-p' -- the lowest priority, then work that
only started, then the work that began last.  Nil when TASK outranks
no task at work, and always while `harness-tasks-max-running' is 0: no
task starts by itself then, nor takes another's slot."
  (unless (eql harness-tasks-max-running 0)
    (let ((project (harness-tasks--slot-project task))
          (id (plist-get task :id))
          (candidates nil))
      (maphash (lambda (_ other)
                 (when (and (not (equal (plist-get other :id) id))
                            (equal (harness-tasks--slot-project other) project)
                            (harness-tasks--preemptible-p other)
                            (harness-tasks--outranks-p task other))
                   (push other candidates)))
               harness-tasks--table)
      (car (sort candidates #'harness-tasks--preempt-first-p)))))

(defun harness-tasks--label (id)
  "Return task ID as a message names it: its id, and its title when it has one."
  (let* ((task (gethash id harness-tasks--table))
         (name (and task (plist-get task :name))))
    (if (harness-string-blank-p name)
        (format "%s" id)
      (format "%s (%s)" id (string-trim name)))))

(defun harness-tasks--preempted-why (task)
  "Return who took the slot of TASK, pre-empted, and why, a short text.
TASK's `:preempted-by' was sent back from review and outranks it
\(`:return-reason' `preempted'): \"pre-empted by task ID (TITLE), sent
back from review\".  Or it lent TASK the slot while it waited on the
user and took it back once answered (`reclaimed'): \"slot taken back
by task ID (TITLE)\"."
  (let ((by (harness-tasks--label (plist-get task :preempted-by))))
    (if (eq (harness-tasks--return-reason task) 'reclaimed)
        (format "slot taken back by task %s" by)
      (format "pre-empted by task %s, sent back from review" by))))

(defun harness-tasks--preempted-hint (id)
  "Say in task ID's session that it was pre-empted, as a hint.
It is added once no turn of the session runs, so it does not land in
the middle of one: at once for a task stopped before its turn began,
else when the stopped turn ends (`harness-tasks--on-turn-ended').  It
says who took its slot, and why (`harness-tasks--preempted-why')."
  (let* ((task (harness-tasks--get id))
         (sid (plist-get task :session))
         (why (harness-tasks--preempted-why task)))
    (when (and sid (harness-call 'session/exists-p sid))
      (harness-call 'session/hint sid
                    (concat (upcase (substring why 0 1)) (substring why 1) "; waiting for a slot")))))

(defun harness-tasks--pre-empted-p (task)
  "Non-nil when TASK waits in the queue because another task took its slot.
That is a task pre-empted for work sent back from review, or one whose
lender took back the slot it borrowed (`harness-tasks--preempt')."
  (memq (harness-tasks--return-reason task) '(preempted reclaimed)))

(defun harness-tasks--stop-reason (task)
  "Return why the work TASK's session left running is stopped, a short text.
TASK waits in the queue: pre-empted (`harness-tasks--preempt') or
returned to pending."
  (let ((by (harness-tasks--label (plist-get task :preempted-by))))
    (pcase (harness-tasks--return-reason task)
      ('preempted (format "its task was pre-empted by task %s, sent back from review" by))
      ('reclaimed (format "task %s took back the slot its task borrowed" by))
      ('sent-back "its task waits for a slot")
      ('quota "its task waits for quota")
      ('budget "its task waits for its budget")
      (_ "its task was paused"))))

(defun harness-tasks--stop-outstanding (id)
  "Stop the work task ID's session left running outside its turn.
That is while ID waits in the queue after its work began
\(`harness-tasks--returned-p'): pre-empted (`harness-tasks--preempt') or
returned to pending (`task/return-to-pending').  A task waiting in the
queue has nothing at work, so what its session started that goes on
without its turn -- a supervisor's workers, sub-agents -- stops too,
through `agent/stop-outstanding', told why (`harness-tasks--stop-reason').
It is called once no turn of the session runs: at once when none ran,
else when the stopped turn ends (`harness-tasks--on-turn-ended').  The
reports the stopped work sends then reach a session with no turn to
steer, whose turn the waiting task refuses and whose message waits in
the transcript for the task's start (`harness-tasks--before-turn'),
rather than steering a turn being cancelled and getting lost.  What was
stopped is said in the session, as a hint.  Return that text, or nil
when nothing was stopped, the task no longer waits, or there is no
agent module."
  (let* ((task (gethash id harness-tasks--table))
         (sid (plist-get task :session)))
    (when (and task sid
               (harness-tasks--queued-p task)
               (harness-tasks--returned-p task)
               (harness-method-exists-p 'agent/stop-outstanding)
               (harness-call 'session/exists-p sid))
      (let ((text (condition-case err
                      (harness-call 'agent/stop-outstanding sid (harness-tasks--stop-reason task))
                    (error (harness-log 'warn "task %s: stopping what its session left running failed: %s"
                                        id (harness-error-message err))
                           nil))))
        (when text
          (harness-log 'info "task %s: stopped while it waits in the queue: %s" id text)
          (harness-call 'session/hint sid (format "Stopped while the task waits for a slot: %s" text)))
        text))))

(defun harness-tasks--preempt (id by &optional reason)
  "Stop task ID's work and put it back in the queue: task BY takes its slot.
REASON says why, `preempted' when nil: BY was sent back from review and
outranks it (`harness-tasks--victim').  It is `reclaimed' when BY lent
ID the slot while it waited on the user, and takes it back now that it
was answered (`harness-tasks--reclaim').  ID is returned to pending as
`task/return-to-pending' returns a task -- it keeps its session, branch
and worktree and leads its priority's queue -- with REASON as its
`:return-reason' and `:preempted-by' BY, no longer borrowing a slot,
and its turn is stopped.  Once no turn of its session runs -- at once
when none did, else when the stopped turn ends
\(`harness-tasks--on-turn-ended') -- its session says it was pre-empted
\(`harness-tasks--preempted-hint'), and the work its session left running
outside its turn, a supervisor's workers say, stops
\(`harness-tasks--stop-outstanding'): a task that only waits on such
work (`:waiting') gives its slot up this way.  When it starts again its
session carries on, told so by `harness-tasks--preempted-message' (or
`harness-tasks--reclaimed-message').  A task still starting gives its
slot up too: one whose worktree is still being made launches nothing
once it is ready (`harness-tasks--start-current-p'), and a first turn
held before it began is cancelled.  Return ID's view."
  (let ((reason (or reason 'preempted)))
    (if (eq reason 'reclaimed)
        (harness-log 'info "task %s: pre-empted; task %s, answered, takes back the slot it lent it" id by)
      (harness-log 'info "task %s: pre-empted; task %s, sent back from review, takes its slot" id by))
    (remhash id harness-tasks--starting)
    ;; The queue first, then the turn (see `task/return-to-pending').
    (prog1 (harness-tasks--to-pending id :return-reason reason :preempted-by by :borrowed-from nil)
      (unless (harness-tasks--stop-turn id)
        (harness-tasks--preempted-hint id)
        (harness-tasks--stop-outstanding id)))))

;;;;; Lending a blocked task's slot

(defun harness-tasks--borrowers (id)
  "Return the tasks that say they work in the slot task ID lent, oldest first.
Normally one at most, and only while it holds a slot; a stale one waits
for `harness-tasks--tidy-loans'."
  (harness-tasks--sorted (lambda (task) (equal (plist-get task :borrowed-from) id))))

(defun harness-tasks--lender-for (task)
  "Return the task whose lent slot TASK starts in now, or nil.
TASK, of a project with slots, is about to take a free slot of its
project.  The slot is a lent one when the project would have none free
were every lender (`harness-tasks--lending-p') holding its own: its
tasks at work in slots of their own and its lenders fill its
`harness-tasks-max-running'.  A task working in a lent slot
\(`:borrowed-from' a lender) shares its lender's, so it is not counted
apart.  Of the lenders whose slot no task works in, the one blocked
longest lends it.  Nil when a slot of the project's own is free, or no
lent slot is."
  (when (harness-tasks--lending-on-p)
    (let ((project (harness-tasks--slot-project task))
          (id (plist-get task :id))
          (lenders nil)
          (holders nil))
      (maphash (lambda (_ other)
                 (when (and (equal (harness-tasks--slot-project other) project)
                            (not (equal (plist-get other :id) id)))
                   (cond ((harness-tasks--lending-p other) (push other lenders))
                         ((harness-tasks--holds-slot-p other) (push other holders)))))
               harness-tasks--table)
      (when lenders
        (let* ((ids (mapcar (lambda (lender) (plist-get lender :id)) lenders))
               (lent (delete-dups (cl-loop for holder in holders
                                           for from = (plist-get holder :borrowed-from)
                                           when (member from ids) collect from)))
               (own (- (length holders) (length lent))))
          (when (<= (- harness-tasks-max-running own (length lenders)) 0)
            (car (sort (cl-remove-if (lambda (lender) (member (plist-get lender :id) lent)) lenders)
                       (lambda (a b)
                         (< (or (harness-tasks--blocked-since (harness-tasks--session a)) 0)
                            (or (harness-tasks--blocked-since (harness-tasks--session b)) 0)))))))))))

(defun harness-tasks--note-borrow (task)
  "Record whose lent slot TASK starts in, when it starts in one.
Called as the harness itself gives TASK a free slot: the queue starting
it (`harness-tasks--schedule'), work sent back from review taking one
\(`harness-tasks--make-room').  TASK says so in `:borrowed-from', the
lender's id (`harness-tasks--lender-for'): it is that task's borrower,
which gives the slot back when the lender is answered
\(`harness-tasks--reclaim').  Return the lender's id, or nil."
  (when-let* ((lender (harness-tasks--lender-for task)))
    (let ((id (plist-get task :id))
          (from (plist-get lender :id)))
      (harness-log 'info "task %s: starts in the slot task %s lends while it waits on the user" id from)
      (harness-tasks--set id :borrowed-from from)
      from)))

(defun harness-tasks--back-p (lender)
  "Non-nil when LENDER, which lent its slot, is answered and works again.
Its session is no longer blocked on the user and a turn of it runs, or
the task starts, so it holds its slot (`harness-tasks--holds-slot-p').
A turn stopped while the session waited still leaves it blocked, and an
answer after that runs nothing: neither is back."
  (let ((session (harness-tasks--session lender)))
    (and session
         (not (eq (plist-get session :status) 'blocked))
         (harness-tasks--holds-slot-p lender)
         (or (gethash (plist-get lender :id) harness-tasks--starting)
             (harness-tasks--turn-p lender))
         t)))

(defun harness-tasks--reclaim (id)
  "End the loan of the slot task ID lent, taking it back if ID works again.
Nothing happens while ID still lends it (`harness-tasks--lending-p').
Once its session was answered and works again (`harness-tasks--back-p'),
and its project is over its limit for it, its borrower -- the task
whose `:borrowed-from' is ID, holding a slot -- is pre-empted
\(`harness-tasks--preempt', `:return-reason' `reclaimed'): back at the
front of the queue, its turn and the work it left running stopped, its
session, branch and worktree kept, told why.  A borrower that gave the
slot up already, a project with a slot free for ID, and a lender that
stopped lending some other way -- its turn stopped, the limit or the
wait changed, gone -- stop nothing: the loan just ends, and a borrower
still at work keeps its slot as one of its own.  Run soon after ID's
session stops being blocked (`harness-tasks--on-session-status'), and
for a loan the scheduler finds over (`harness-tasks--tidy-loans').
Return the id of the task pre-empted, or nil."
  (let ((borrowers (harness-tasks--borrowers id))
        (lender (gethash id harness-tasks--table)))
    (when (and borrowers (not (and lender (harness-tasks--lending-p lender))))
      (let* ((victim (and lender
                          (harness-tasks--back-p lender)
                          (< (harness-tasks--free-slots (harness-tasks--slot-project lender)) 0)
                          (cl-find-if #'harness-tasks--holds-slot-p borrowers)))
             (victim-id (and victim (plist-get victim :id))))
        (dolist (borrower borrowers)
          (unless (equal (plist-get borrower :id) victim-id)
            (harness-tasks--set (plist-get borrower :id) :borrowed-from nil)))
        (if victim
            (harness-tasks--preempt victim-id id 'reclaimed)
          (harness-log 'info "task %s: no longer lends its slot; nothing to take back" id))
        ;; A borrower that keeps its slot as its own may lend it now.
        (harness-run-soon #'harness-tasks--schedule victim-id)
        victim-id))))

(defun harness-tasks--tidy-loans ()
  "End the loans whose borrower or lender moved on, at a scheduling pass.
A borrower (`:borrowed-from') that no longer holds a slot -- done, in
review, returned to pending -- forgets the loan, and so does one whose
lender is gone, or stopped lending without coming back to work
\(returned to pending, say).  A lender back at work takes its slot back
through `harness-tasks--reclaim', run soon, as its session's answer
does."
  (let ((ended nil))
    (maphash (lambda (id task)
               (when-let* ((from (plist-get task :borrowed-from)))
                 (let ((lender (gethash from harness-tasks--table)))
                   (cond ((not (harness-tasks--holds-slot-p task)) (push id ended))
                         ((null lender) (push id ended))
                         ((harness-tasks--lending-p lender) nil)
                         ((harness-tasks--back-p lender) (harness-run-soon #'harness-tasks--reclaim from))
                         (t (push id ended))))))
             harness-tasks--table)
    (dolist (id ended)
      (harness-tasks--set id :borrowed-from nil))))

(defconst harness-tasks--lend-recheck 60
  "Seconds between looks at a blocked task that may not lend its slot yet.
One that waits on work its session left running, or works in a borrowed
slot, may lend once that is over, with no event to say so.")

(defun harness-tasks--arm-lend-timer (task)
  "Have the scheduler run when TASK, blocked on the user, lends its slot.
The timer fires once TASK has waited `harness-tasks-lend-blocked-slot-after'
\(`harness-tasks--lend-due-at'), and `harness-tasks--lend-due' runs the
scheduler, which then finds the slot free.  A task no longer blocked has
its timer cancelled."
  (let* ((id (plist-get task :id))
         (old (gethash id harness-tasks--lend-timers))
         (due (harness-tasks--lend-due-at task)))
    (when old
      (cancel-timer old)
      (remhash id harness-tasks--lend-timers))
    (when due
      (puthash id (run-at-time (max 0 (- due (float-time))) nil #'harness-tasks--lend-due id)
               harness-tasks--lend-timers))))

(defun harness-tasks--arm-lend-timers ()
  "Arm or cancel the lend timer of every task at work.
After the wait or the limit changed, and after a reload."
  (maphash (lambda (_ task)
             (when (or (eq (plist-get task :state) 'active)
                       (gethash (plist-get task :id) harness-tasks--lend-timers))
               (harness-tasks--arm-lend-timer task)))
           harness-tasks--table))

(defun harness-tasks--lend-due (id)
  "Run the scheduler now that task ID, blocked on the user, lends its slot.
A timer of `harness-tasks--arm-lend-timer' calls this.  A task that may
not lend yet, though blocked long enough (`harness-tasks--lending-p':
work still running for it, a borrowed slot), is looked at again after
`harness-tasks--lend-recheck'; one that fired early waits the rest."
  (remhash id harness-tasks--lend-timers)
  (when-let* ((task (gethash id harness-tasks--table)))
    (if (harness-tasks--lending-p task)
        (progn
          (harness-log 'info "task %s: blocked on the user for %ss; it lends its slot meanwhile"
                       id harness-tasks-lend-blocked-slot-after)
          (harness-tasks--schedule))
      (when-let* ((due (harness-tasks--lend-due-at task)))
        (puthash id (run-at-time (max 0.05 (if (> due (float-time))
                                                (- due (float-time))
                                              harness-tasks--lend-recheck))
                                 nil #'harness-tasks--lend-due id)
                 harness-tasks--lend-timers)))))

(defun harness-tasks--on-session-status (session-id status &rest _)
  "Follow SESSION-ID becoming STATUS: when it blocks, lends, and is answered.
On `session/status'.  When it becomes blocked on the user its time is
kept (`harness-tasks--blocked-at'), and for its task a timer has the
scheduler run once the task has waited long enough to lend its slot
\(`harness-tasks--arm-lend-timer').  When it stops being blocked --
answered -- the timer goes, and its task, if it lent its slot, takes it
back soon (`harness-tasks--reclaim'): soon rather than now, so a turn
being cancelled as its question goes is over first."
  (let ((blocked (eq status 'blocked))
        (was (gethash session-id harness-tasks--blocked-at)))
    (cond (blocked (unless was (puthash session-id (float-time) harness-tasks--blocked-at)))
          (was (remhash session-id harness-tasks--blocked-at)))
    ;; Running and idle come and go with every turn: only a block that
    ;; begins or ends concerns a loan.
    (when (or blocked was)
      (when-let* ((task (harness-tasks--by-session session-id)))
        (harness-tasks--arm-lend-timer task)
        (unless blocked
          (harness-run-soon #'harness-tasks--reclaim (plist-get task :id)))))))

(defun harness-tasks--make-room (task)
  "Find TASK, which the user sends back from review, a slot to work in now.
Return non-nil when it may work at once: without a limit, with a slot
of its project free, or by taking the slot of a task at work it
outranks, which is pre-empted (`harness-tasks--victim',
`harness-tasks--preempt'); a task that only waits on work its session
left running is one too, and that work stops with it.  A slot free
because a task blocked on the user lends it is free for it too, which
it then borrows (`harness-tasks--note-borrow').  Nil means it waits in
the queue: every task at work outranks it, the limit is 0, or its
project's queue is suspended, which holds work sent back from review
back as it holds back any start the harness makes by itself, or its
session is out of quota or over a hard budget
\(`harness-tasks--compute-hold'): a turn started now would stop at once,
so the feedback waits in the queue until the hold ends."
  (cond ((harness-tasks--task-suspended-p task) nil)
        ((harness-tasks--compute-hold task) nil)
        ((> (harness-tasks--free-slots (harness-tasks--slot-project task)) 0)
         (harness-tasks--note-borrow task)
         t)
        (t (when-let* ((victim (harness-tasks--victim task)))
             (harness-tasks--preempt (plist-get victim :id) (plist-get task :id))
             (harness-tasks--note-borrow task)
             t))))

(defun harness-tasks--schedule (&optional skip)
  "Start the queued tasks of every project while it has slots free.
They go in start order (`harness-tasks--start-order'): highest priority
first; among equals, work sent back from review, then the tasks
returned to pending, then the oldest.  Projects have slots of their own
\(`harness-tasks--free-slots'): the walk keeps what is left of each
one's, so a project at its limit holds up only its own tasks.  Backlog
tasks wait for `task/start' instead, and so do the tasks of a project
whose queue is suspended (`task/suspend-queue'): the suspension holds
back the starts the scheduler makes on its own, never an explicit
`task/start'.  SKIP, a task id, is left out of this pass: returning a
task to pending starts it again with the next pass, not with the one
that stops it, nor with one that follows a turn its session was
refused while it waits (`harness-tasks--on-turn-ended').

A task waiting because it was sent back from review while no slot could
take it (`:return-reason' `sent-back') does not wait for a free slot
alone: once it outranks a task at work -- its priority raised, or that
task just starting when it was sent back -- it takes that task's slot
\(`harness-tasks--victim', `harness-tasks--preempt'), as it would have
when it was sent back.  No other waiting task pre-empts.

A slot a task blocked on the user lends (`harness-tasks--lending-p') is
free like any other, and the task started in it says whose it borrowed
\(`harness-tasks--note-borrow').  Loans whose borrower or lender moved on
end first (`harness-tasks--tidy-loans').

A task that is held (`harness-tasks--hold') -- paused by hand, out of
quota or over a hard budget -- is left in the queue and takes no slot
from the tasks behind it: the pass works out the holds first
\(`harness-tasks--refresh-holds'), so what began or ended since the last
one is seen, and a task whose hold is over starts with the rest."
  (harness-tasks--load-queues)
  (harness-tasks--tidy-loans)
  (harness-tasks--refresh-holds)
  (let ((free (make-hash-table :test 'equal)))
    (dolist (task (harness-tasks--start-order (harness-tasks--sorted #'harness-tasks--queued-p)))
      (unless (or (equal (plist-get task :id) skip)
                  (harness-tasks--task-suspended-p task)
                  (harness-tasks--hold task))
        (let* ((project (harness-tasks--slot-project task))
               (left (or (gethash project free) (harness-tasks--free-slots project))))
          (cond
           ((> left 0)
            (cl-decf left)
            (harness-tasks--note-borrow task)
            (harness-tasks--start task))
           ((eq (harness-tasks--return-reason task) 'sent-back)
            (when-let* ((victim (harness-tasks--victim task)))
              (harness-tasks--preempt (plist-get victim :id) (plist-get task :id))
              (harness-tasks--note-borrow task)
              (harness-tasks--start task))))
          (puthash project left free))))))

(defun harness-tasks--on-config-changed (key &rest _)
  "Start the tasks a new limit lets through, when KEY is the limit.
On `config/changed': the board's \"N at a time\" button and the
settings page change `harness-tasks-max-running' through `config/set'
\(or `config/unset').  A higher limit frees slots, which waiting tasks
take at once rather than at the next task's end; a lower one stops no
task at work, and the scheduler then finds no slot free.  The same goes
for `harness-tasks-lend-blocked-slot-after', how long a task blocked on
the user waits before it lends its slot: the timers that wait for that
follow the new value (`harness-tasks--arm-lend-timers'), and a loan the
new value ends stops no task at work.  The list of fallbacks
\(`harness-fallback-models') and the Budget setting (`harness-budget')
decide whether a queued task is held for quota or a budget
\(`harness-tasks--hold'): an entry that works, or a budget raised,
starts the tasks that waited for them, so the holds are looked at
again."
  (let ((key (if (stringp key) (intern-soft key) key)))
    (when (memq key '(harness-tasks-max-running harness-tasks-lend-blocked-slot-after))
      (harness-run-soon #'harness-tasks--arm-lend-timers)
      (harness-run-soon #'harness-tasks--schedule))
    (when (memq key '(harness-fallback-models harness-budget))
      (harness-tasks--on-hold-event))))

(defun harness-tasks--on-priority-changed (_session-id key &rest _)
  "Let a task waiting with feedback take a slot when a priority changes.
On `session/ext-changed' (ID KEY VALUE) for KEY `harness-priority-ext-key':
a session's priority, which is its task's (`harness-priority-of-task').
A task sent back from review that waits for a slot pre-empts a task at
work as soon as it outranks one (`harness-tasks--schedule'): its own
priority raised, or that task's lowered."
  (when (and (eq key harness-priority-ext-key)
             (cl-loop for task being the hash-values of harness-tasks--table
                      thereis (and (harness-tasks--queued-p task)
                                   (eq (harness-tasks--return-reason task) 'sent-back))))
    (harness-run-soon #'harness-tasks--schedule)))

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
  (remhash id harness-tasks--waking)
  (harness-log 'warn "task %s failed: %s" id (harness-error-message err))
  (when (gethash id harness-tasks--table)
    (harness-tasks--set id :state 'active :outcome 'error :error (harness-error-message err)))
  (harness-run-soon #'harness-tasks--schedule))

(defun harness-tasks--start (task)
  "Start TASK: make its worktree in a git project, then its session.
Its session is the one it has had since submission (`task/submit'), or
the write-up's for a record from before that; a backlog task's session
is the one that wrote it up.  That session moves into the worktree and
does the work.  A task returned to pending has a session that already
worked on it: that session stays where it is and carries on
\(`harness-tasks--start-paused'), no new worktree made.  A task started
again after a restart cut its start short keeps the worktree it got.  A
task that declared `:main-tree' gets no worktree: its session works in
the project's main checkout, where it was submitted from
\(`task/submit').

A start given up before its session got the work -- the task
pre-empted while its worktree was being made
\(`harness-tasks--preempt') -- launches nothing once the worktree is
ready (`harness-tasks--start-current-p'): the worktree is kept for the
task's next start, which waits for that same one when it is not ready
yet (`harness-tasks--worktree-promise').  A task pre-empted before its
session got the work starts it afresh, as it never began.

A task that was waiting in the queue (`harness-tasks--queued-p') records
how long it waited and at which priority in its `:waits'
\(`harness-tasks--waits-after'), and its `:queued-at' goes; a backlog
task started by hand was not waiting for a slot and records nothing."
  (let* ((id (plist-get task :id))
         (worktree (plist-get task :worktree))
         (launch (cond ((and (harness-tasks--returned-p task) (harness-tasks--session task)
                             (harness-tasks--work-begun-p task))
                        #'harness-tasks--start-paused)
                       ((harness-tasks--session task)
                        #'harness-tasks--continue-session)
                       (t #'harness-tasks--open-session)))
         (started (float-time))
         ;; A task that waited in the queue records how long it did, in
         ;; the same change that takes it out of it; a backlog task
         ;; started by hand waited for no slot and records nothing.
         (waits (and (harness-tasks--queued-p task)
                     (harness-tasks--waits-after task started))))
    (puthash id t harness-tasks--starting)
    (remhash id harness-tasks--message-starts)
    (remhash id harness-tasks--superseding)
    (apply #'harness-tasks--set id :state 'active :backlog nil :outcome nil :error nil
           :duplicate-of nil :returned nil :paused nil :started started :finished nil :queued-at nil
           (and waits (list :waits waits)))
    (cond
     ((harness-tasks--main-tree-p task)
      ;; No worktree even where the project has them: the main checkout.
      (funcall launch id (plist-get task :project) nil))
     ((not (harness-tasks--git-p (plist-get task :project)))
      (funcall launch id (plist-get task :cwd) nil))
     ((and worktree (not (plist-get task :worktree-removed)) (file-directory-p worktree))
      (funcall launch id worktree worktree))
     (t
      (harness-then (harness-tasks--worktree-promise task)
                    (lambda (wt)
                      (let ((path (file-name-as-directory (plist-get wt :path))))
                        (when (gethash id harness-tasks--table)
                          (harness-tasks--set id :worktree path :branch (plist-get wt :branch)
                                              :base (plist-get wt :base)))
                        (if (harness-tasks--start-current-p id started)
                            (funcall launch id path path)
                          (harness-log 'info "task %s: its worktree is ready, but the start it was made for was given up" id))))
                    (lambda (err)
                      (if (harness-tasks--start-current-p id started)
                          (harness-tasks--fail id err)
                        (harness-log 'warn "task %s: making its worktree failed after its start was given up: %s"
                                     id (harness-error-message err)))))))))

(defun harness-tasks--start-current-p (id started)
  "Non-nil when the start of task ID made at STARTED still stands.
STARTED is the `:started' that start gave it.  The start stands while
the task is active with that same `:started': a task pre-empted while
it was starting (`harness-tasks--preempt') is pending, and one started
again has another, so a start given up launches nothing."
  (let ((task (gethash id harness-tasks--table)))
    (and task
         (eq (plist-get task :state) 'active)
         (eql (plist-get task :started) started))))

(defun harness-tasks--worktree-promise (task)
  "Return a promise of TASK's worktree, made once however many starts wait.
The first start of TASK makes it (`harness-tasks--make-worktree'); a
start made while that is still under way -- the task pre-empted, then
started again -- waits for the same worktree instead of asking git for a
second one on the branch the first is taking
\(`harness-tasks--worktrees-made')."
  (let ((id (plist-get task :id)))
    (or (gethash id harness-tasks--worktrees-made)
        (let ((promise (harness-tasks--make-worktree task)))
          (puthash id promise harness-tasks--worktrees-made)
          (harness-then promise
                        (lambda (_) (remhash id harness-tasks--worktrees-made))
                        (lambda (_) (remhash id harness-tasks--worktrees-made)))
          promise))))

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

(defun harness-tasks--context-limit-hint (limit)
  "Return the hint saying a task session's context window is capped at LIMIT.
Nil when LIMIT is nil or is not `harness-tasks-context-limit': nothing
is said without the cap that setting makes.  The hint names the
setting, so that a task session's shorter window is never silent, as a
sub-agent's is not (see `harness-tools-agent-context-limit-hint')."
  (when (and (numberp limit)
             (numberp harness-tasks-context-limit)
             (equal limit harness-tasks-context-limit))
    (format "Context window capped at %s tokens (harness-tasks-context-limit)"
            (harness-format-tokens-compact limit))))

(defun harness-tasks--say-context-limit (sid limit)
  "Say in session SID's transcript that a task's cap holds it at LIMIT.
Nothing is said when LIMIT is not the task setting's own cap, and a
hint that cannot be added fails nothing: the task goes on without it."
  (when-let* ((hint (harness-tasks--context-limit-hint limit)))
    (condition-case err
        (harness-call 'session/hint sid hint)
      (error (harness-log 'warn "tasks: no context cap hint for %s: %s" sid
                          (harness-error-short-message err))))))

(defconst harness-tasks-bulk-columns '(active pending backlog needs-input)
  "Task columns a bulk update reaches by default.
They are the current work: running, pending, backlog and blocked
tasks.  Review, done and archived tasks are history and are left
alone.")

(defconst harness-tasks-pref-keys '(:model :thinking :permission-mode :non-interactive :supervisor)
  "Session settings a task carries until its next start.
`:supervisor' is the session `:ext' key of the supervisor module, t or
`:false'; a harness without that module keeps the setting on the task
and does nothing with it (see `harness-tasks--apply-supervisor').")

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
start non-interactive all the same.  A `:priority' is not a setting
here: the priority plugin gives it to the task (`task/set-all' asks it
to), and a nil one changes nothing."
  (cl-some (lambda (k)
             (let ((want (plist-get settings k)) (have (plist-get task k)))
               (pcase k
                 (:non-interactive
                  (not (eq (and (harness-json-true-p want) t)
                           (and (harness-tasks--non-interactive-p task) t))))
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
changes (see `harness-session-check-policy').  A `:priority' is not a
setting here: `task/set-all' takes it out and gives it to the task's
session (`harness-priority-set-session'), where the board and the
queues the task's work waits in read it.  `:supervisor' is the
session's `:ext' switch, not a `session/update' setting, so it is
applied by `harness-tasks--apply-supervisor'.  Return TASK's view."
  (let* ((id (plist-get task :id))
         (prefs (cl-loop for k in harness-tasks-pref-keys
                         when (plist-member settings k)
                         append (list k (plist-get settings k)))))
    (when (and prefs (fboundp 'harness-session-check-policy))
      (harness-session-check-policy prefs))
    (when prefs
      (apply #'harness-tasks--set id prefs))
    (when prefs
      (let* ((session (harness-tasks--session task))
             (changes (and session
                           (cl-loop for (k v) on prefs by #'cddr
                                    unless (or (eq k :supervisor)
                                               (harness-setting-equal-p k v (plist-get session k)))
                                    append (list k v)))))
        (when (and changes (harness-method-exists-p 'session/update))
          (apply #'harness-call 'session/update (plist-get session :id) changes)))
      (harness-tasks--apply-supervisor task settings))
    (harness-call 'task/get id)))

(defun harness-tasks--make-session (task &optional priority cwd worktree)
  "Make TASK's session and return it, in CWD (TASK's own) and WORKTREE.
Every task has its session from submission: it is where the task's
priority lives -- the board shows and orders by the session's, which
the rest of the harness queues its work by -- and the work goes on in
it when a slot is free or the user starts it (`harness-tasks--start').
A backlog task's session is the one that writes it up, with the
write-up's own settings (`harness-tasks--refine-settings'); any other
starts with the settings its work runs with
\(`harness-tasks--work-settings').  PRIORITY, a level or a name of one,
is what the submitter gave, or nil to take what the task has (a record
from before priorities lived on sessions says it in its own record).
The session is named with the task's title when it has one by now, so
it is not named again; else the title still on its way names it
\(`harness-tasks--named').  A context limit the settings carry is the
task setting's cap, and the session's transcript says so
\(`harness-tasks--say-context-limit')."
  (let* ((settings (if (harness-tasks--backlog-p task)
                       (harness-tasks--refine-settings task)
                     (harness-tasks--work-settings task)))
         (session (apply #'harness-call 'session/create
                         :cwd (or cwd (plist-get task :cwd))
                         (append (and worktree (list :worktree worktree))
                                 (list :ext (harness-priority-ext
                                             (or priority (harness-priority-of-task task))))
                                 (harness-tasks--name-option task)
                                 settings))))
    (harness-tasks--set (plist-get task :id) :session (plist-get session :id))
    ;; The task's context limit applies from the start, and says so.
    (harness-tasks--say-context-limit (plist-get session :id)
                                      (plist-get settings :context-window-limit))
    session))

(defun harness-tasks--apply-supervisor (task settings)
  "Turn the supervisor mode of TASK's session to what SETTINGS names.
Supervisor mode is per session, in its `:ext' plist, and the module
that governs sessions is what sets it (`supervisor/set'); without that
module the task keeps the setting for when a harness that has it starts
it, and a write-up's session is left alone, as it only reads: the
setting means how the work runs, not how it is written up."
  (when (and (plist-member settings :supervisor)
             (plist-get task :session)
             (not (harness-tasks--refinement-p task))
             (harness-method-exists-p 'supervisor/set))
    (harness-call 'supervisor/set (plist-get task :session)
                  (if (harness-json-true-p (plist-get settings :supervisor)) t :false))))

(defun harness-tasks--open-session (id cwd worktree)
  "Create task ID's session in CWD (in WORKTREE, when non-nil) and prompt it.
A task from before every task had a session gets one here, and starts
in it; the others have theirs from submission
\(`harness-tasks--make-session'), which the work goes on in."
  (condition-case err
      (let* ((task (harness-tasks--get id))
             (session (harness-tasks--make-session task nil cwd worktree))
             (sid (plist-get session :id)))
        (harness-catch (harness-call-async 'agent/prompt sid (harness-tasks--blocks task))
                       (lambda (e) (harness-tasks--fail id e))))
    (error (harness-tasks--fail id err))))

(defun harness-tasks--drop-session (task)
  "Delete the session of TASK, which never started its work.
A task waiting for a slot or in the backlog has a session from
submission, holding its priority; a task dropped before it did
anything (`task/cancel' of a pending one) takes that session with it,
so no idle session is left behind."
  (when-let* ((sid (plist-get task :session))
              ((harness-method-exists-p 'session/delete)))
    (condition-case err
        (harness-call 'session/delete sid)
      (error (harness-log 'warn "task %s: could not delete its session: %s"
                          (plist-get task :id) (harness-error-message err))))))

(defun harness-tasks--quote (text)
  "Return TEXT as a markdown quote."
  (mapconcat (lambda (line) (if (string-empty-p line) ">" (concat "> " line)))
             (split-string (string-trim text) "\n") "\n"))

(defun harness-tasks--start-text (task)
  "Return the message that starts the work of backlog TASK.
A planned task's opens with `harness-tasks--plan-start-message', any
other's with `harness-tasks--start-message'.
It carries the write-up in full, as edited since, so the work never
depends on the provider remembering the refinement (after moving into a
worktree it does not), and the request it was written from, quoted."
  (let ((prompt (plist-get task :prompt))
        (note (plist-get task :note)))
    (concat (if (harness-tasks--plan-p task) harness-tasks--plan-start-message harness-tasks--start-message)
            "\n\n" prompt
            (if (and note (not (equal (string-trim note) (string-trim prompt))))
                (concat "\n\n---\nOriginal request (the write-up above takes precedence):\n\n"
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
     ;; A reply in a thread is not the words the opening goes before: it
     ;; keeps its own text, which its data is drawn with.
     ((and (harness-tasks--text-block-p (car blocks)) (not (harness-thread-block-p (car blocks))))
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

(defvar harness-tasks-feedback-additions-functions nil
  "Functions that add to the feedback that sends a task back from review.
Each is called with the TASK, which waits for review, and the WORDS the
user sends it back with, a string, empty when there are none; it returns
nil or (TEXT . DONE).  TEXT, a string or nil, goes after the words of the
feedback, as its own paragraphs -- the review module puts the user's
draft comments there -- and DONE, a function of no arguments, is called
once the task is sent back, or kept for a slot (`task/reject',
`harness-tasks--on-message'): the review module marks the drafts sent
and keeps the words.  A function must not change anything before DONE:
its text may never be sent, when the message turns out to be refused.")

(defun harness-tasks--feedback-additions (task &optional words)
  "Return what the functions of `harness-tasks-feedback-additions-functions' add.
\(TEXT . DONES) for TASK, which is sent back with WORDS: the texts they
returned, trimmed and joined by a blank line, nil when there are none,
and the functions to call once the task is sent back.  Nil when none
added anything; a function that fails adds nothing."
  (let (texts dones)
    (dolist (fn (ensure-list harness-tasks-feedback-additions-functions))
      (when-let* ((added (condition-case err
                             (funcall fn task (or words ""))
                           (error (harness-log 'warn "task feedback: %S failed: %s" fn
                                               (harness-error-message err))
                                  nil))))
        (when (and (stringp (car added)) (not (harness-string-blank-p (car added))))
          (push (string-trim (car added)) texts))
        (when (functionp (cdr added)) (push (cdr added) dones))))
    (and (or texts dones)
         (cons (and texts (string-join (nreverse texts) "\n\n")) (nreverse dones)))))

(defun harness-tasks--commit-additions (additions)
  "Call the functions of ADDITIONS, from `harness-tasks--feedback-additions'."
  (dolist (done (cdr additions))
    (condition-case err
        (funcall done)
      (error (harness-log 'warn "task feedback: %S failed: %s" done (harness-error-message err))))))

(defun harness-tasks--add-to-feedback (feedback additions)
  "Return the text FEEDBACK with ADDITIONS after it.
ADDITIONS are those `harness-tasks--feedback-additions' returned."
  (if (car additions)
      (string-join (delq nil (list (and (not (harness-string-blank-p feedback)) (string-trim feedback))
                                   (car additions)))
                   "\n\n")
    feedback))

(defun harness-tasks--add-to-blocks (blocks additions)
  "Return the message BLOCKS with a text block of ADDITIONS after them."
  (if (car additions)
      (append blocks (list (list :type "text" :text (car additions))))
    blocks))

(defun harness-tasks--words (blocks)
  "Return the words of the message BLOCKS: its text blocks, trimmed and joined.
A reply in a thread the review has made a comment of already
\(`harness-thread-block-p' with an `:id') is no words: the review keeps it
as the thread it is, and keeps it once."
  (string-join (cl-loop for b in blocks
                        when (and (harness-tasks--text-block-p b)
                                  (not (and (harness-thread-block-p b)
                                            (plist-get (plist-get b :thread) :id))))
                        collect (string-trim (plist-get b :text)))
               "\n\n"))

(defun harness-tasks--register-threads (task attachments)
  "Return ATTACHMENTS, a task's feedback's, with its replies in threads registered.
A reply in a thread (an attachment with `:thread') is a comment in a
thread of TASK's review, which the module that keeps the review makes: it
is a filter on `task/feedback-attachments' (value ATTACHMENTS, arg TASK)
and returns the attachments with the id of the thread in each reply's
data.  That is done before the round of feedback is kept, so that the
text the round keeps ends with the marker of each thread
\(`harness-thread-marker'), and before a message waits for a slot, so that
it goes out as the threads it is made of and no more of them.  Without
such a filter, or when it fails, ATTACHMENTS are as they were."
  (if (cl-some (lambda (a) (and (consp a) (plist-get a :thread))) attachments)
      (or (harness-run-filter 'task/feedback-attachments attachments task) attachments)
    attachments))

(defun harness-tasks--feedback-round (task feedback)
  "Return TASK's rounds of feedback with a new one, FEEDBACK, at the end."
  (append (plist-get task :feedback) (list (list :text feedback :at (float-time)))))

(defun harness-tasks--send-back (id feedback)
  "Put task ID, which waits for review, back to work on FEEDBACK.
The task is active again and its verification gone; FEEDBACK, what the
message that sends it back says, is kept as a new round of its
`:feedback', and `:sent-back' says the work is feedback on reviewed
work (`harness-tasks--sent-back-p').  The caller found it a slot
\(`harness-tasks--make-room') and delivers the message: `task/reject'
prompts the session, `harness-tasks--on-message' lets the message
through.  Return the task's view."
  (let ((task (harness-tasks--get id)))
    (harness-tasks--set id :state 'active :outcome nil :error nil :finished nil :archived nil
                        :verified nil :verified-at nil :merge-attempts 0
                        :recap nil :recap-at nil :recap-turns nil :recap-tools nil
                        :sent-back (float-time)
                        :feedback (harness-tasks--feedback-round task feedback))))

(defun harness-tasks--hold-back (id feedback &optional text attachments)
  "Keep task ID, which the user sends back from review with FEEDBACK, in the queue.
That is when no slot can take it (`harness-tasks--make-room'): every
task at work outranks it, the limit is 0, or its project's queue is
suspended.  It goes back to pending as a task returned to pending does,
keeping its session, branch and worktree, with `:return-reason'
`sent-back' and `:sent-back' now, so it leads its priority's queue
\(`harness-tasks--start-order'), takes a slot as soon as it outranks a
task at work (`harness-tasks--schedule'), and its session takes no turn
until it starts (`harness-tasks--before-turn').  FEEDBACK is kept as a
new round of its `:feedback'.  TEXT, with ATTACHMENTS, is the message
to give the session when it starts (`harness-tasks--queue-message'):
`task/reject' gives one, while the user's message to the session stays
in its transcript instead.  Return the task's view."
  (let* ((task (harness-tasks--get id))
         (view (harness-tasks--to-pending id :return-reason 'sent-back :sent-back (float-time)
                                          :archived nil
                                          :feedback (harness-tasks--feedback-round task feedback))))
    ;; A task that waits for quota or a budget says so as it joins the queue.
    (harness-tasks--refresh-holds)
    (if text
        (harness-tasks--queue-message id text attachments)
      view)))

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
`task/reject' does: the round of feedback is kept, the message the
agent gets opens with `harness-tasks--reject-message', and the task is
active at once when it gets a slot (`harness-tasks--make-room'), which
it holds from now (`harness-tasks--starting'), pre-empting a task at
work it outranks when none is free.  When no slot can take it, it waits
in the queue instead (`harness-tasks--hold-back'): the message is
recorded all the same, but the turn it would start does not begin
\(`harness-tasks--before-turn'), and the message reaches the agent with
the task's start.  A message that steers a turn already running finds
the session at work, and sends the task back as one that got a slot.

A message from another session's agent (FROM a session sender, as
`session_send' and task_control's message send it) is no review: no
round of feedback, no reject text.  The task is active while its
session deals with it (`harness-tasks--aside') and the message, its
sender kept, opens with `harness-tasks--aside-message' instead.  The
harness's own messages (FROM a system sender) are left alone, and so
is a task whose worktree was removed: a turn they start makes the task
active all the same (`harness-tasks--on-turn-started').

A message from the user to a backlog task that has not started starts
the task, as one to a returned task does, rather than rewriting its
write-up: `harness-tasks--before-turn' refuses the turn the message
would start, and the task starts in a turn of its own
\(`harness-tasks--superseding').  A message written while the write-up
runs starts it too, stopping the write-up first
\(`harness-tasks--supersede-on-message').  Feedback on the write-up is
what `task/refine' and `task/prompt' send (marked by
`harness-tasks--refine-turn'), and what waited in the session's queue
while a write-up ran.  Return the blocks to deliver."
  ;; A message of the user's that restarts a stopped task shows it at
  ;; work at once, before the turn it starts actually begins.
  (let ((waking (and (null (harness-sender-kind (plist-get info :from)))
                     (harness-tasks--by-session session-id))))
    (when (and waking (harness-tasks--wake-worthy-p waking))
      (harness-tasks--wake (plist-get waking :id))))
  (let* ((task (harness-tasks--by-session session-id))
         (id (plist-get task :id))
         (from (plist-get info :from))
         (kind (harness-sender-kind from))
         ;; `task/refine' and `task/prompt' mark the message they send:
         ;; it is feedback on a write-up, not the start a message to a
         ;; backlog task is.
         (write-up-message (prog1 (and id (gethash session-id harness-tasks--write-up-messages))
                             (remhash session-id harness-tasks--write-up-messages))))
    (cond
     ;; A message the user queued while the task waited or was written
     ;; up stays the queue's: it is feedback on the write-up it was
     ;; queued under (`agent/send-queue').
     ((and task (null kind) (harness-tasks--refinement-p task)
           (not write-up-message) (plist-get info :queued))
      blocks)
     ;; A message the user writes in the session starts the task, as one
     ;; to a returned task does, also while its write-up runs: it is no
     ;; feedback on the write-up unless the board's Refine sends it
     ;; (`write-up-message').
     ((and task (null kind) (harness-tasks--refinement-p task)
           (not write-up-message) (plist-get info :steering))
      (harness-tasks--supersede-on-message task)
      blocks)
     ((and task (null kind) (harness-tasks--refinement-p task)
           (not write-up-message))
      (harness-log 'info "task %s: a message to its session starts it, not more of its write-up" id)
      (puthash id t harness-tasks--message-starts)
      blocks)
     ((not (and task
                (eq (plist-get task :state) 'review)
                (not (plist-get task :worktree-removed))))
      blocks)
     ((eq kind 'system) blocks)
     ((null kind)
      (let* ((additions (harness-tasks--feedback-additions task (harness-tasks--words blocks)))
             (blocks (harness-tasks--add-to-blocks blocks additions))
             (steering (plist-get info :steering))
             (feedback (harness-tasks--feedback-text blocks)))
        (cond
         ((or steering (harness-tasks--make-room task))
          (harness-log 'info "task %s: a message to its session sends it back from review" id)
          ;; Its slot is held until the turn the message starts begins.
          (unless steering (puthash id t harness-tasks--starting))
          (harness-tasks--send-back id feedback))
         (t
          (harness-log 'info "task %s: a message to its session sends it back from review; it waits for a slot" id)
          (harness-tasks--hold-back id feedback)))
        (harness-tasks--commit-additions additions)
        (harness-tasks--reject-blocks blocks)))
     (t
      (harness-log 'info "task %s: a message from %s reaches it in review; not a review, it is not sent back"
                   id (harness-sender-description from))
      (harness-tasks--aside id)
      (harness-tasks--aside-blocks blocks)))))

(defun harness-tasks--continue-session (id cwd worktree)
  "Start task ID's work in its session, moved to CWD.
WORKTREE, when non-nil, is the task's worktree.  The session takes the
task's settings instead of the refinement's read-only ones.  When the
directory changes, the provider's conversation is dropped: the Claude
CLI keeps conversations per directory.  A backlog task's session wrote
the task up, so it is given the start message -- the write-up in full,
then the request it came from, as the harness's words -- and the new
conversation gets the transcript, which keeps the refinement, as text
\(`harness-provider-history-text').  Any other task's session has never
seen the task, so it is given the task itself, as the user's words.  A
session that has no name yet takes the task's title."
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
        ;; Its priority is the task's, the session being the task's own.
        (harness-call 'session/hint sid
                      (cond
                       (worktree (format "Task started in %s on branch %s"
                                         (abbreviate-file-name worktree) (plist-get task :branch)))
                       ((harness-tasks--main-tree-p task)
                        (format "Task started in the main tree %s" (abbreviate-file-name cwd)))
                       (t "Task started")))
        ;; A session that did not carry the task's cap already is told
        ;; about it now; one that did said so when it was made.
        (unless (equal (plist-get settings :context-window-limit)
                       (plist-get session :context-window-limit))
          (harness-tasks--say-context-limit sid (plist-get settings :context-window-limit)))
        (harness-catch (harness-call-async 'agent/prompt sid
                                           (if (harness-tasks--written-up-p task)
                                               (harness-tasks--blocks
                                                (list :prompt (harness-tasks--start-text task)
                                                      :attachments (plist-get task :attachments)))
                                             (harness-tasks--blocks task))
                                           (and (harness-tasks--written-up-p task)
                                                (harness-tasks--from-harness)))
                       (lambda (e) (harness-tasks--fail id e))))
    (error (harness-tasks--fail id err))))

(defun harness-tasks--opening (task)
  "Return the harness's message that starts TASK again after it waited.
It says why it waited (`harness-tasks--return-reason'):
`harness-tasks--preempted-message' for a task pre-empted,
`harness-tasks--reclaimed-message' for one whose lender took back the
slot it borrowed, `harness-tasks--sent-back-message' for one sent back
from review while no slot could take it, `harness-tasks--quota-message'
and `harness-tasks--budget-message' for one that waited for quota or a
budget, `harness-tasks--paused-message' for one returned to pending by
hand or paused."
  (pcase (harness-tasks--return-reason task)
    ('preempted harness-tasks--preempted-message)
    ('reclaimed harness-tasks--reclaimed-message)
    ('sent-back harness-tasks--sent-back-message)
    ('quota harness-tasks--quota-message)
    ('budget harness-tasks--budget-message)
    (_ harness-tasks--paused-message)))

(defun harness-tasks--start-paused (id cwd worktree)
  "Start task ID again in the session that already worked on it.
That is a task returned to pending (`task/return-to-pending'), pre-empted
\(`harness-tasks--preempt') or sent back from review while no slot could
take it (`harness-tasks--hold-back'): its session stays in CWD, its
worktree when it has one, with everything it changed, and the harness
tells it why it waited and to carry on (`harness-tasks--opening').  No
session and no worktree is made: the task keeps the ones it has, and
they keep their settings.  Messages kept while the task waited
\(`harness-tasks--queue-message') go to the session with the start, so
nothing sent it is lost; so do the ones its session was sent meanwhile,
which wait in its transcript (`harness-tasks--before-turn').  WORKTREE is
the task's worktree, if any, for the hint."
  (condition-case err
      (let* ((task (harness-tasks--get id))
             (sid (plist-get task :session)))
        (when (eq (plist-get (harness-call 'session/get sid) :status) 'inactive)
          (harness-call 'session/resume sid))
        (harness-call 'session/hint sid
                      (cond
                       (worktree (format "Task started again in %s on branch %s"
                                         (abbreviate-file-name worktree) (plist-get task :branch)))
                       ((harness-tasks--main-tree-p task)
                        (format "Task started again in the main tree %s" (abbreviate-file-name cwd)))
                       (t "Task started again")))
        (harness-catch (harness-call-async 'agent/prompt sid
                                           (list (list :type "text" :text (harness-tasks--opening task)))
                                           (harness-tasks--from-harness))
                       (lambda (e) (harness-tasks--fail id e)))
        (harness-tasks--deliver-queued id sid))
    (error (harness-tasks--fail id err))))

(defun harness-tasks--queue-message (id text &optional attachments from)
  "Keep a message for task ID, to deliver when it starts again.
A message to a task returned to pending while its queue is suspended
\(`harness-tasks--task-suspended-p'), or to one that waits for a slot
with the user's feedback (`harness-tasks--hold-back'), is kept this way
instead of starting the task: TEXT, ATTACHMENTS and who FROM it was
\(`harness-sender-session' or nil for the user) go to the session with
the task's next start.  Return the task's view."
  (let ((task (harness-tasks--get id)))
    (harness-tasks--set id :queued (append (plist-get task :queued)
                                           (list (list :text text :attachments attachments :from from))))))

(defun harness-tasks--deliver-queued (id session-id)
  "Send the messages kept for task ID to SESSION-ID, in order, and forget them.
Each goes as a message of its own, with the sender it was sent with: a
message from another session's agent keeps saying so, the user's is the
user's."
  (let ((queued (plist-get (harness-tasks--get id) :queued)))
    (when queued (harness-tasks--set id :queued nil))
    (dolist (item queued)
      (harness-catch (harness-call-async 'agent/prompt session-id
                                         (harness-tasks--blocks
                                          (list :prompt (plist-get item :text)
                                                :attachments (plist-get item :attachments)))
                                         (let ((from (plist-get item :from)))
                                           (and from (list :from from))))
                     (lambda (e) (harness-tasks--fail id e))))))

(defun harness-tasks--to-pending (id &rest plist)
  "Put task ID back in the pending queue, with PLIST merged in.
Its session, branch and worktree stay; `:returned' is now, so it leads
its priority's queue (see `harness-tasks--start-order'), and its state
before is forgotten: no outcome, no round of feedback pending, no
verification.  `:return-reason' is `returned', the return by hand,
unless PLIST says why (`harness-tasks--return-reason').  `:queued-at' is
now too: it waits for a slot from here (`harness-tasks--queued-since').
Return the task's view."
  (remhash id harness-tasks--waking)
  (let ((now (float-time)))
    (apply #'harness-tasks--set id
           :state 'pending :returned now :queued-at now :backlog nil
           :return-reason 'returned :preempted-by nil
           :outcome nil :error nil :waiting nil :finished nil
           :merge-status nil :merge-attempts 0
           :verified nil :verified-at nil
           :recap nil :recap-at nil :recap-turns nil :recap-tools nil
           plist)))

(defun harness-tasks--stop-turn (id)
  "Stop the turn of task ID's session, if one runs, for a return to pending.
`harness-tasks--returning' says so until the turn ends, and the turn
stops as `task/cancel' stops a working task: without waiting for it.
Return non-nil when a turn was running, so it is being stopped.  The
work the session left running outside its turn is not stopped here:
that waits until no turn of the session runs
\(`harness-tasks--stop-outstanding') -- now when this returns nil, which
is for the caller to do, else when the stopped turn ends
\(`harness-tasks--on-turn-ended')."
  (let ((sid (plist-get (harness-tasks--get id) :session)))
    (when (and sid (harness-tasks--turn-p (harness-tasks--get id)))
      (puthash id t harness-tasks--returning)
      (when (harness-method-exists-p 'agent/cancel)
        (harness-call 'agent/cancel sid))
      t)))

(defun harness-tasks--waiting-message (task)
  "Return why TASK's session takes no turn now, for a turn it refused.
TASK waits in the queue (`harness-tasks--before-turn')."
  (format "task %s is waiting for a slot (%s); the message is delivered when it starts"
          (plist-get task :id)
          (pcase (harness-tasks--return-reason task)
            ('sent-back "sent back from review")
            ('preempted (format "pre-empted by task %s" (plist-get task :preempted-by)))
            ('reclaimed (format "slot taken back by task %s" (plist-get task :preempted-by)))
            ('quota "waiting for quota")
            ('budget "waiting for its budget")
            (_ "paused"))))

(defun harness-tasks--holds-turns-p (task from)
  "Non-nil when TASK's session takes no turn started by a message from FROM.
FROM is who sent the message: nil for the user, else
`harness-sender-system' or `harness-sender-session'.  TASK is one that
waits in the queue (`harness-tasks--queued-p') after its work began
somewhere: returned to pending, pre-empted, or sent back from review
while no slot could take it.  Its session works again when the task
starts, so a turn something else would start -- another session's
message, the harness's own, a sub-agent reporting back -- does not
begin, and its message waits for that start.  The user's own message
starts the task, as `task/start' does, unless it waits with their
feedback (`sent-back'): then it is more of that feedback, and waits
too."
  (and (harness-tasks--queued-p task)
       (harness-tasks--returned-p task)
       (or (eq (harness-tasks--return-reason task) 'sent-back)
           (harness-sender-kind from))
       t))

(defun harness-tasks--before-turn (value next session)
  "Hold back a turn of SESSION while its task waits, or to start it.
An `agent/before-turn' stage: VALUE is the gate so far, (:proceed t
:message (:text TEXT :from FROM)), NEXT continues the chain.  A task
waiting for a slot does not work around the limit through its session
\(`harness-tasks--holds-turns-p'): the turn is refused, with a hint
saying why (`harness-tasks--waiting-message').  The message stays in the
transcript, so it reaches the agent with the turn that starts the task
\(`harness-tasks--start-paused'), and the refused turn says nothing
about the task (`harness-tasks--on-turn-ended').

A user's message to a waiting backlog task (`harness-tasks--message-starts')
is the same: the turn it would start is refused, the task leaves the
backlog as it is (`harness-tasks--abandon-write-up'), and the start
this refusal ends with runs the task and carries its start message,
not the message itself (`harness-tasks--on-turn-ended')."
  (let ((task (and (plist-get value :proceed)
                   (harness-tasks--by-session (plist-get session :id)))))
    (funcall next
             (cond
              ((and task (gethash (plist-get task :id) harness-tasks--superseding))
               ;; A start is waiting for the write-up's turn to end: no
               ;; message starts a turn in it now.
               (harness-log 'info "task %s: it is starting; the turn the message would run is refused"
                            (plist-get task :id))
               (list :proceed nil :reason "the task is starting"))
              ((and task (gethash (plist-get task :id) harness-tasks--message-starts))
               (harness-log 'info "task %s: the user's message starts it; the turn it would run is refused"
                            (plist-get task :id))
               (harness-tasks--abandon-write-up task)
               (list :proceed nil :reason "the task is starting"))
              ((and task (harness-tasks--holds-turns-p
                          task (plist-get (plist-get value :message) :from)))
               (harness-log 'info "task %s: its session takes no turn while it waits in the queue"
                            (plist-get task :id))
               (list :proceed nil :reason (harness-tasks--waiting-message task)))
              (t value))))
  nil)

;;;; Refinement

(defconst harness-tasks--refine-again-text
  "Write the task up now. Your final message is the complete write-up."
  "Message that asks a backlog task's session for its write-up again.")

(defconst harness-tasks--refine-anyway-text
  "Write it up anyway, listing the task it seemed to duplicate as related. Your final message is the complete write-up."
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
  "Enough reading: finish now with what you know. Your final message is the write-up, or the refusal if the board has this task already."
  "Steering message for a write-up that looked around long enough.
That is once it made `harness-tasks--refine-tool-calls' tool calls.")

(defvar harness-tasks--refine-calls (make-hash-table :test 'equal)
  "Session id -> tool calls of the write-up turn running in it.")

(defun harness-tasks--plan-enough-text (n)
  "Return the message that tells a planning turn of N tool calls to hand in."
  (format "%d tool calls: hand the plan in now with submit_task_plan. List what you could not settle as open questions." n))

(defun harness-tasks--on-tool-call (session-id &optional node &rest _)
  "Count the tool calls of a write-up in SESSION-ID; tell it to finish in time.
NODE is the call's transcript node.  A brief write-up is steered once,
at `harness-tasks--refine-tool-calls' calls, to write up now.  A plan is
steered to hand itself in at `harness-tasks--plan-tool-calls' calls and
every half budget after that (`harness-readonly-budget-point-p'): a
nudge, never a stop -- and none on the call that hands the plan in."
  (when-let* ((task (harness-tasks--by-session session-id))
              ((eq (plist-get task :state) 'refining)))
    (let ((n (1+ (gethash session-id harness-tasks--refine-calls 0))))
      (puthash session-id n harness-tasks--refine-calls)
      (when-let* ((text (if (harness-tasks--plan-p task)
                            (and (not (equal (plist-get node :tool) harness-tasks--plan-tool))
                                 (harness-readonly-budget-point-p n harness-tasks--plan-tool-calls)
                                 (harness-tasks--plan-enough-text n))
                          (and harness-tasks--refine-tool-calls (= n harness-tasks--refine-tool-calls)
                               harness-tasks--refine-enough-text))))
        (harness-catch (harness-call-async 'agent/prompt session-id text (harness-tasks--from-harness))
                       #'ignore)))))

(defun harness-tasks--base-model (task)
  "Return the model TASK's work would run on without a plan.
That is TASK's `:model', else `harness-tasks-model', else what its
directory configures; nil when none says."
  (or (plist-get task :model) harness-tasks-model
      (harness-tasks--config 'harness-model (plist-get task :cwd))))

(defun harness-tasks--tier-model (tier model)
  "Return the model of TIER of MODEL's provider, or nil.
TIER is `simple', `medium', `hard' or `frontier' (`provider/tier-model')
and MODEL, a task's model, names the provider.  Nil when that provider
has no model for TIER, or there is no MODEL to ask about."
  (when (and tier (stringp model) (not (harness-string-blank-p model))
             (harness-method-exists-p 'provider/tier-model))
    (let ((found (condition-case err
                     (harness-call 'provider/tier-model model tier)
                   (error (harness-log 'warn "tasks: no %s model for %s: %s" tier model
                                       (harness-error-message err))
                          nil))))
      (and (stringp found) (not (harness-string-blank-p found)) found))))

(defun harness-tasks--tier-thinking (tier model)
  "Return the thinking level MODEL's provider runs its TIER model at, or nil.
Only a provider that says names one (`provider/tier-thinking'), as
DeepSeek runs its one model at a level per tier; Claude does not."
  (and tier (stringp model) (harness-method-exists-p 'provider/tier-thinking)
       (let ((level (ignore-errors (harness-call 'provider/tier-thinking model tier))))
         (and (stringp level) (not (harness-string-blank-p level)) level))))

(defun harness-tasks--plan-model (task)
  "Return the model that plans TASK by default: the plan tier of its model.
That is `harness-tasks--plan-tier' of the provider of TASK's model
\(`harness-tasks--base-model'), else that model itself."
  (let ((base (harness-tasks--base-model task)))
    (or (harness-tasks--tier-model harness-tasks--plan-tier base) base)))

(defun harness-tasks--plan-thinking (task)
  "Return the thinking level TASK is planned at by default, or nil.
That is the level the provider runs the plan's tier at, else TASK's
own, else `harness-tasks-thinking'."
  (or (harness-tasks--tier-thinking harness-tasks--plan-tier (harness-tasks--base-model task))
      (plist-get task :thinking) harness-tasks-thinking))

(defun harness-tasks--plan-work (task)
  "Return (MODEL . THINKING), what a planned TASK's work runs on by default.
The model is `harness-tasks--plan-work-tier' of the provider of the task
model, nil when it has none (the task model then stands); the thinking
level is the one that provider runs the tier at, else nil."
  (let ((base (harness-tasks--base-model task)))
    (cons (harness-tasks--tier-model harness-tasks--plan-work-tier base)
          (harness-tasks--tier-thinking harness-tasks--plan-work-tier base))))

(defun harness-tasks--refine-settings (task)
  "Return the `session/create' settings of the session refining TASK.
Ask mode allows reads, and non-interactive the session never waits for
the user; whatever would ask `harness-tasks--write-up-gate' denies with
a hint, which keeps a write-up a write-up.  The task context limit
rides along, so a write-up that reads a lot compacts sooner too.  The
model and thinking level are the task's own for its write-up
\(`:refine-model', `:refine-thinking'), else, for a plan, those of
`harness-tasks--plan-model' and `harness-tasks--plan-thinking', and for
a brief write-up `harness-tasks-refine-model' and
`harness-tasks-refine-thinking', else the task's."
  (let* ((plan (harness-tasks--plan-p task))
         (model (or (plist-get task :refine-model)
                    (if plan
                        (harness-tasks--plan-model task)
                      (or harness-tasks-refine-model (plist-get task :model) harness-tasks-model))))
         (thinking (or (plist-get task :refine-thinking)
                       (if plan
                           (harness-tasks--plan-thinking task)
                         (or harness-tasks-refine-thinking (plist-get task :thinking) harness-tasks-thinking)))))
    (append (list :permission-mode 'ask :non-interactive t)
            (and model (list :model model))
            (and thinking (list :thinking thinking))
            (and harness-tasks-context-limit
                 (list :context-window-limit harness-tasks-context-limit)))))

(defconst harness-tasks--write-up-hint
  "A write-up is read-only: write the task up from what you can read, and list what you could not check as open questions."
  "Hint of a call denied because a backlog write-up only reads.")

(defun harness-tasks--write-up-allows (task request)
  "Return the decision that lets REQUEST, a call of TASK's write-up, run, or nil.
Two calls that would ask are the write-up's own: the plan a planning
session hands in (`harness-tasks--plan-tool'), and bash while the
readonly module holds the session (`harness-tasks--readonly-policy')
and the sandbox confines the command, which then runs read-only and
offline (harness-readonly.el)."
  (let ((tool (plist-get request :tool))
        (session (plist-get request :session)))
    (cond
     ((and (equal tool harness-tasks--plan-tool) (harness-tasks--plan-p task))
      (list :behavior 'allow :reason "handing the plan in is what this session is for"))
     ((and (equal tool "bash") (harness-module-ready-p 'readonly)
           (harness-readonly-session-p session)
           (harness-readonly-confined-p (or (car (plist-get request :paths)) (harness-readonly-dir session))))
      (list :behavior 'allow :reason "a write-up's commands run read-only and offline in the sandbox")))))

(defun harness-tasks--write-up-gate (decision next request)
  "Keep the turns that write a backlog task up read-only.
A `permission/decide' stage at 25, after the mode and its rules and
before the auto-mode judge: a call of such a turn (see
`harness-tasks--refinement-p') still undecided there would ask the
user, or, the session being non-interactive, go to the judge.  It is
denied instead, for good -- unless it is the write-up's own
\(`harness-tasks--write-up-allows'): a plan handed in, or a command the
sandbox holds read-only.  DECISION is the current value and NEXT
continues the chain with REQUEST's decision."
  (let ((task (and (eq (plist-get decision :behavior) 'ask)
                   (harness-tasks--by-session (plist-get (plist-get request :session) :id)))))
    (funcall next (cond
                   ((not (and task (harness-tasks--refinement-p task))) decision)
                   ((harness-tasks--write-up-allows task request))
                   (t (list :behavior 'deny :final t
                            :reason (if (harness-tasks--plan-p task)
                                        "planning is read-only"
                                      "a write-up is read-only")
                            :hint (if (harness-tasks--plan-p task)
                                      harness-tasks--plan-hint
                                    harness-tasks--write-up-hint)))))))

;;;; Read-only write-ups

(defun harness-tasks--readonly-policy (session)
  "Return the read-only policy of SESSION when it writes a task up or plans it.
The readonly module (harness-readonly.el) then offers it only the
reading tools -- and `submit_task_plan' and `todo_write' when it plans --
and bash only read-only and offline where the sandbox confines it, and
denies anything else for good.  `web_fetch' is left out: in the
write-up's ask mode it would only be refused (`web_search' never asks).
Nil for any other session."
  (when-let* ((task (harness-tasks--by-session (plist-get session :id)))
              ((harness-tasks--refinement-p task)))
    (if (harness-tasks--plan-p task)
        (list :tools (list harness-tasks--plan-tool "todo_write") :except '("web_fetch")
              :label "plan mode" :doing "plans the task for another agent to carry out"
              :hint harness-tasks--plan-hint)
      (list :except '("web_fetch")
            :label "write-up" :doing "writes the task up for the backlog"
            :hint harness-tasks--write-up-hint))))

(defun harness-tasks--tools (names session)
  "Offer `submit_task_plan' among NAMES only to a SESSION that plans a task.
An `agent/tools' filter.  The catalogue (SESSION nil) keeps every tool."
  (if (and session (member harness-tasks--plan-tool names)
           (not (when-let* ((task (harness-tasks--by-session (plist-get session :id))))
                  (and (harness-tasks--refinement-p task) (harness-tasks--plan-p task)))))
      (remove harness-tasks--plan-tool names)
    names))

;;;; Handing a plan in

(defvar harness-tasks--plans-submitted (make-hash-table :test 'equal)
  "Session id -> t once its running turn handed a plan in (`task/hand-in-plan').
The end of that turn then leaves the task as the plan made it, in the
backlog, rather than taking its last reply for a write-up.")

(defvar harness-tasks--plan-reminders (make-hash-table :test 'equal)
  "Session id -> times its running planning turn was sent back to hand its plan in.")

(defun harness-tasks--plan-stop-answer (value session)
  "Return what the `agent/stop' chain goes on with for the stop VALUE of SESSION.
A session planning a task whose turn stopped without handing a plan in
\(`task/hand-in-plan') or refusing the task as a duplicate is sent back
with `harness-tasks--plan-reminder', at most
`harness-tasks--plan-max-reminders' times a turn; after that its last
reply is taken for the plan, as a write-up's is.  Any other value goes
through unchanged."
  (let* ((sid (plist-get session :id))
         (task (and sid (harness-tasks--by-session sid))))
    (cond
     ((not (and (harness-json-true-p (plist-get value :stop))
                task (eq (plist-get task :state) 'refining) (harness-tasks--plan-p task)
                (not (gethash sid harness-tasks--plans-submitted))
                (not (harness-tasks--refusal (harness-tasks--last-reply sid)))))
      value)
     ((< (gethash sid harness-tasks--plan-reminders 0) harness-tasks--plan-max-reminders)
      (cl-incf (gethash sid harness-tasks--plan-reminders 0))
      (list :stop nil :message harness-tasks--plan-reminder
            :from (plist-get (harness-tasks--from-harness) :from)))
     (t value))))

(defun harness-tasks--plan-stop (value next session)
  "Send a planning model that stopped without a plan back (`agent/stop').
VALUE and SESSION are the filter's, and NEXT continues the chain with
the answer of `harness-tasks--plan-stop-answer'.  A failure here lets
the model stop: the reminder only nudges."
  (funcall next (condition-case err
                    (harness-tasks--plan-stop-answer value session)
                  (error (harness-log 'error "tasks: the plan's stop rule failed: %S" err)
                         value))))

(defun harness-tasks--refine-failed (id err)
  "Record ERR as the reason task ID's refinement stopped."
  (harness-log 'warn "refining task %s failed: %s" id (harness-error-message err))
  (when (gethash id harness-tasks--table)
    (harness-tasks--set id :state 'refining :outcome 'error :error (harness-error-message err)
                        :duplicate-of nil)))

(defun harness-tasks--abandon-write-up (task)
  "Take TASK, a backlog one, out of the backlog for a start.
`:backlog' goes and the task is active from now, though its work begins
only when the turn writing it up has ended
\(`harness-tasks--superseding'): `harness-tasks--on-turn-ended' starts it
then.  Marking it keeps that turn's end from finishing the write-up.
Return the task's view."
  (let ((id (plist-get task :id)))
    (puthash id t harness-tasks--superseding)
    (remhash id harness-tasks--message-starts)
    (harness-tasks--set id :state 'active :backlog nil :queued-at nil
                        :outcome nil :error nil :duplicate-of nil :finished nil
                        :waiting "starting the task")))

(defun harness-tasks--supersede (task)
  "Stop TASK's write-up turn and start TASK once it has ended.
TASK is a backlog task whose write-up runs.  Its backlog goes at once
\(`harness-tasks--abandon-write-up'), and `agent/cancel' stops the turn;
its end then starts the task (`harness-tasks--on-turn-ended') rather
than finishing a write-up the start has superseded.  Return the task's
view."
  (let ((id (plist-get task :id))
        (sid (plist-get task :session)))
    (harness-tasks--abandon-write-up task)
    (harness-log 'info "task %s: its write-up is being stopped so the task can start" id)
    (when (and sid (harness-method-exists-p 'agent/cancel))
      (harness-call 'agent/cancel sid))
    (harness-call 'task/get id)))

(defun harness-tasks--supersede-on-message (task)
  "Stop TASK's write-up for the user's message that is steering it.
TASK is a backlog task a turn writes up.  The task leaves the backlog
as the message starts it (`harness-tasks--abandon-write-up'); the write-up
turn is stopped once the message has been recorded on it, which the
`agent/message' filter this runs in cannot do itself, and its end then
starts the task (`harness-tasks--on-turn-ended')."
  (let ((id (plist-get task :id)))
    (harness-tasks--abandon-write-up task)
    (harness-log 'info "task %s: the user's message stops its write-up; starting it" id)
    (harness-run-soon
     (lambda ()
       ;; A write-up that ended by itself before this started the task
       ;; already, having cleared the mark; cancel no turn of the work.
       (when (and (gethash id harness-tasks--superseding)
                  (let ((current (gethash id harness-tasks--table)))
                    (and current (harness-tasks--turn-p current))))
         (when-let* ((current (gethash id harness-tasks--table))
                     (sid (plist-get current :session)))
           (when (harness-method-exists-p 'agent/cancel)
             (harness-call 'agent/cancel sid))))))))

(defun harness-tasks--refine-turn (id sid blocks &optional opts)
  "Prompt task ID's session SID with BLOCKS for a write-up.
OPTS are the `agent/prompt' options, such as who sends the message.
The turn's end finishes the refinement (`harness-tasks--on-turn-ended');
this only adds the error a failed turn reports.  The message is marked
as the write-up's (`harness-tasks--write-up-messages'), so a user's
message `task/refine' or `task/prompt' sends is feedback on the
write-up even while a backlog task otherwise starts on a message."
  (puthash sid t harness-tasks--write-up-messages)
  (let ((promise (condition-case err
                     (harness-call-async 'agent/prompt sid blocks opts)
                   (error (remhash sid harness-tasks--write-up-messages)
                          (signal (car err) (cdr err))))))
    ;; The message filters ran in the call above; the mark is not needed.
    (remhash sid harness-tasks--write-up-messages)
    (harness-then promise
                  (lambda (result)
                    (let ((task (gethash id harness-tasks--table)))
                      (when (and task (eq (plist-get task :state) 'refining)
                                 (plist-get task :outcome) (not (plist-get task :error))
                                 (plist-get result :error))
                        (harness-tasks--set id :error (format "%s" (plist-get result :error))))))
                  (lambda (e) (harness-tasks--refine-failed id e)))))

(defun harness-tasks--refine-blocks (task text)
  "Return the message that gives TASK to its write-up: the task, then TEXT."
  (harness-tasks--blocks (list :prompt (if (harness-string-blank-p text)
                                           (plist-get task :prompt)
                                         (concat (plist-get task :prompt) "\n\n" text))
                               :attachments (plist-get task :attachments))))

(defun harness-tasks--refine (id &optional text)
  "Have an agent write task ID up for the backlog.
The task's session writes it up, the one it has had since submission,
or one made here for a record from before that; TEXT, feedback on the
write-up, goes to that session (without it, a request to write it up
again, or after the agent refused it as a duplicate, to write it up
all the same).  A session that never received the task, cut short by a
restart, gets the task itself."
  (condition-case err
      (let* ((task (harness-tasks--get id))
             (session (harness-tasks--session task)))
        ;; Out of the queue, if it was in it: it waits for the user now.
        (harness-tasks--set id :state 'refining :backlog t :outcome nil :error nil :duplicate-of nil
                            :queued-at nil
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
          (let ((sid (plist-get (harness-tasks--make-session task) :id)))
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
A plan handed in during the turn (`task/hand-in-plan') put the task in
the backlog already, and stands.  Otherwise a complete turn puts the
task in the backlog, unless its reply refuses
the task as a duplicate (`harness-tasks--refusal').  That, like any
other end, leaves it refining with an outcome, in front of the user: a
refusal is `duplicate', with `:duplicate-of' the task it names (nil
when it names none) and its message as `:error'.  Only a reply naming a
task of this harness, or what looks like one of its ids, refuses: a
write-up that merely opens \"Duplicate of a task …\" is a write-up.
In auto backlog mode the task goes on from the backlog to the pending
queue (`harness-tasks--auto-queue').  A turn that ended after a start
superseded the write-up finishes nothing: the task is no backlog task
then, and this leaves it to the start."
  (let ((current (harness-tasks--get id)))
    (if (not (harness-tasks--refinement-p current))
        (harness-log 'info "task %s: the end of its write-up turn came after it started; no write-up" id)
      (let* ((task current)
             (sid (plist-get task :session))
             (handed-in (and sid (gethash sid harness-tasks--plans-submitted)))
             (reply (and (not handed-in) (eq reason 'end-turn) sid
                         (harness-tasks--last-reply sid)))
             (refusal (and reply (harness-tasks--refusal reply)))
             (of (and refusal (harness-tasks--duplicate-of task (car refusal))))
             (refuse (and refusal (or of (string-match-p "\\`t-[A-Za-z0-9]+\\'" (car refusal))))))
        (when sid (remhash sid harness-tasks--plans-submitted))
        (cond
         ;; The plan was handed in during the turn (`task/hand-in-plan'): the
         ;; task is in the backlog with it, whatever the turn did after.
         (handed-in nil)
         ((harness-string-blank-p reply)
          (harness-tasks--set id :state 'refining :duplicate-of nil
                              :outcome (if (eq reason 'end-turn) 'error reason)
                              :error (and (eq reason 'end-turn) "the agent wrote no task description")))
         (refuse
          (harness-log 'info "task %s: its write-up refused it as a duplicate of %s" id (car refusal))
          (harness-tasks--set id :state 'refining :outcome 'duplicate
                              :duplicate-of of :error (cdr refusal)))
         (t
          ;; First, so that the backlog task's views say it joins the queue.
          (harness-tasks--auto-queue id)
          (harness-tasks--set id :state 'pending :backlog t :prompt (string-trim reply)
                              :refined (float-time) :outcome nil :error nil :duplicate-of nil)))))))

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
task's worktree is locked again for the new work.  A task that waited
in the queue is no longer waiting: why it did (`:return-reason') is
forgotten, and so is a pause (`:paused'): a turn the user starts in a
paused task's session resumes it, as `task/start' does."
  (remhash session-id harness-tasks--refine-calls)
  (remhash session-id harness-tasks--plans-submitted)
  (remhash session-id harness-tasks--plan-reminders)
  (when-let* ((task (harness-tasks--by-session session-id)))
    (remhash (plist-get task :id) harness-tasks--starting)
    (remhash (plist-get task :id) harness-tasks--waking)
    (cond
     ((harness-tasks--refinement-p task)
      (harness-tasks--set (plist-get task :id) :state 'refining :outcome nil :error nil :duplicate-of nil
                          :archived nil))
     ((and (eq (plist-get task :state) 'merging) (plist-get task :merge-status)) nil)
     (t (harness-tasks--relock-worktree task)
        (apply #'harness-tasks--set (plist-get task :id) :state 'active :outcome nil :error nil :finished nil
               :merged nil :archived nil :returned nil :return-reason nil :preempted-by nil :paused nil
               (append
                (unless (eq (plist-get task :state) 'merging) (list :verified nil :verified-at nil))
                (when (memq (plist-get task :state) '(review done)) (list :reopened (float-time)))))))))

(defun harness-tasks--outstanding (task)
  "Return what runs for TASK's session outside its own turn, or nil.
That is the text of `agent/outstanding': work a module started for the
session that goes on without its turn, a supervisor plan's workers say.
Nil when no module reports any, and without the agent module."
  (let ((sid (plist-get task :session)))
    (when (and sid (harness-method-exists-p 'agent/outstanding))
      (condition-case err
          (harness-call 'agent/outstanding sid)
        (error (harness-log 'warn "task %s: asking what its session has outstanding failed: %s"
                            (plist-get task :id) (harness-error-message err))
               nil)))))

(defun harness-tasks--on-turn-ended (session-id reason)
  "Advance SESSION-ID's task when its turn ended with REASON.
`end-turn' puts the work in review (`harness-tasks-require-verification')
until the user verified it; after that, or without review, it completes
the task outside git -- in the main tree too, which has nothing to
merge -- and queues its merge inside.  A round that ended saying it
cannot continue (`hand_in' with `:cannot-continue') instead puts the
task before the user, active with the outcome `cannot-continue' and
nothing merged; a round that handed in work needing no merge (`hand_in'
with `:no-merge') completes without joining the merge queue.  A round
that ends without a report handed in gets one saying so
(`harness-tasks--missing-report').
A refinement turn puts its write-up in the backlog.  The turn a start
superseded (`harness-tasks--superseding') is no refinement either: the
start stopped it, so its end starts the task with its start message
and never finishes the write-up or takes the task to review.  A clean
end of a turn is not the end of the work while something the session started
still runs outside it (`harness-tasks--outstanding'): the task then
neither goes to review nor merges, but stays active, with the text of
what runs as its `:waiting' until its state next changes.  The turn the
session takes when that work is done, or once nothing runs any more,
ends the task as usual.

The turn a return to pending stopped is the exception: the task waits
in the queue, and this turn says nothing about it.  It is left out of
the scheduling pass that follows, so the return never starts the task
again (see `harness-tasks--schedule'); a start the task got while that
turn was still stopping did steer the turn being cancelled and so went
nowhere, and is made here, once the turn is gone.  A task pre-empted
says so in its session now that the stopped turn is over
\(`harness-tasks--preempted-hint'), and the work its session left
running outside its turn -- of a task pre-empted or returned to
pending alike -- stops now (`harness-tasks--stop-outstanding'), so that
what it reports reaches a session with no turn to steer; not for a task
started again meanwhile, whose work goes on.  Nor does a turn of a task
waiting in the queue say anything about it: one its session was
refused while the task waits (`harness-tasks--before-turn').  A
returned task is left out of the scheduling pass after such a turn
too, so that the reports of the work stopped with its return, refused
while it waits, do not start it again: the return starts nothing.

A turn that ends `error' or `blocked' while its task cannot go on for
lack of quota or money, or because a hard budget is spent
\(`harness-tasks--compute-hold'), is no failure of the task: that is
every provider it could run on being out, and the budget gate stopping
the turn between two steps or before it began.  The task goes back to
the queue, with the reason on its card (`harness-tasks--park'), instead
of waiting for the user with the outcome `error' or `blocked', and
starts again when the hold ends (`harness-tasks--refresh-holds')."
  (remhash session-id harness-tasks--refine-calls)
  (remhash session-id harness-tasks--plan-reminders)
  (when-let* ((task (harness-tasks--by-session session-id)))
    (let ((id (plist-get task :id))
          (waiting nil)
          (parked nil)
          (skip nil))
      (remhash id harness-tasks--starting)
      (remhash id harness-tasks--waking)
      (cond
       ((gethash id harness-tasks--returning)
        (remhash id harness-tasks--returning)
        (setq skip t)
        (cond
         ((eq (plist-get task :state) 'active)
          (harness-log 'info "task %s: the turn it was returned from ended after it started again; starting it once more" id)
          (harness-tasks--start-paused id (plist-get task :worktree) (plist-get task :worktree)))
         (t
          (when (harness-tasks--pre-empted-p task)
            (harness-tasks--preempted-hint id))
          (harness-tasks--stop-outstanding id))))
       ((gethash id harness-tasks--superseding)
        ;; A start stopped the write-up: this turn is the write-up's
        ;; abrupt end, never the task's work, and the task starts now.
        (remhash id harness-tasks--superseding)
        (harness-log 'info "task %s: the write-up it superseded ended; starting it" id)
        (harness-tasks--start (harness-tasks--get id)))
       ((harness-tasks--refinement-p task) (harness-tasks--finish-refinement id reason))
       ((harness-tasks--queued-p task)
        (setq skip (harness-tasks--returned-p task)))
       ;; Every provider out of quota, or a hard budget spent: no failure
       ;; of the task's, which waits in the queue for it to end.
       ((and (memq reason '(error blocked))
             (eq (plist-get task :state) 'active)
             (not (plist-get task :merge-status))
             (setq parked (harness-tasks--compute-hold task)))
        (harness-tasks--park id parked)
        (setq skip t))
       ((not (eq reason 'end-turn))
        (unless (plist-get task :merge-status)
          (harness-tasks--set id :state 'active :outcome reason)))
       ((plist-get task :merge-status) nil) ; a conflict turn; merge/finished decides
       ;; Merged mid-turn: done, or in review when that merge needs one.
       ((and (memq (plist-get task :state) '(done review)) (harness-tasks--merged-p task)) nil)
       ((setq waiting (harness-tasks--outstanding task))
        (harness-tasks--set id :state 'active :waiting waiting))
       ((harness-tasks--cannot-continue-p task)
        ;; The session said it cannot finish: the task waits for the user
        ;; instead of review, and nothing joins the merge queue.
        (harness-tasks--set id :state 'active :outcome 'cannot-continue
                            :error (harness-first-line (plist-get (plist-get task :report) :summary) 300)
                            :finished nil :merge-status nil))
       ((harness-tasks--needs-review-p task)
        (apply #'harness-tasks--to-review id :outcome reason :error nil :finished (float-time)
               (harness-tasks--missing-report task)))
       ((harness-tasks--no-merge-p task)
        ;; Informational work: nothing to merge, so nothing joins the queue.
        (apply #'harness-tasks--to-done id 'finished :outcome reason :finished (float-time)
               (harness-tasks--missing-report task)))
       ((and (plist-get task :worktree) (not (plist-get task :worktree-removed)))
        (when-let* ((missing (harness-tasks--missing-report task)))
          (apply #'harness-tasks--set id missing))
        (harness-tasks--enqueue-merge id))
       (t (apply #'harness-tasks--to-done id 'finished :outcome reason :finished (float-time)
                 (harness-tasks--missing-report task))))
      (if skip
          (harness-run-soon #'harness-tasks--schedule id)
        (harness-run-soon #'harness-tasks--schedule)))))

(defun harness-tasks--on-pending-changed (session-id &rest _)
  "Re-announce SESSION-ID's task: requests coming and going move its column."
  (when-let* ((task (harness-tasks--by-session session-id)))
    (harness-emit 'task/changed (harness-tasks--view task))))

(defun harness-tasks--on-session-deleted (session-id &rest _)
  "Forget the task of deleted SESSION-ID, and since when it was blocked."
  (remhash session-id harness-tasks--blocked-at)
  (when-let* ((task (harness-tasks--by-session session-id)))
    (harness-tasks--forget-attachments (plist-get task :id))
    (harness-tasks--remove (plist-get task :id))))

(defun harness-tasks--remove (id)
  "Drop task ID, write the stores and emit `task/deleted'."
  (remhash id harness-tasks--table)
  (remhash id harness-tasks--starting)
  (remhash id harness-tasks--waking)
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
    ;; A write-up cut short is written up again, not started: its message
    ;; is the write-up's, even when it is the task itself the session
    ;; never got (`harness-tasks--write-up-messages').
    (when (harness-tasks--refinement-p task)
      (puthash sid t harness-tasks--write-up-messages))
    (let ((promise (harness-call-async 'agent/prompt sid
                                       (if begun
                                           (list (list :type "text" :text harness-tasks--resume-prompt))
                                         (harness-tasks--blocks task))
                                       ;; Carrying on after a restart is the
                                       ;; harness's doing; the task itself is
                                       ;; the user's.
                                       (and begun (harness-tasks--from-harness)))))
      (remhash sid harness-tasks--write-up-messages)
      (harness-catch promise (lambda (e) (harness-tasks--fail id e))))))

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
            (harness-tasks--set id :state 'pending :started nil :queued-at (float-time))))
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

;;;; Attachments sent as data
;;
;; A task's attachments are files of this machine (`:path'), as the
;; compose box of the Emacs the harness runs in attaches them.  A client
;; on another device -- the phone app -- has no such file to name: it
;; sends the bytes, an attachment with its `:data' in base64 and no
;; `:path'.  `task/submit' and `task/update' keep each as a file under
;; the state directory, one directory to a task, and the task holds the
;; ordinary file attachment that names it, so what reads a task's
;; attachments -- the session's opening message, a board's edit box --
;; takes no notice, and the bytes never ride in the record or in every
;; `task/changed'.  Only pictures, of the types a provider takes, and
;; the bytes must be what the type says: a client is not trusted with a
;; file name or a path, only with a picture.  The files stay while the
;; task's session does, whose transcript names them; they go with it
;; (`harness-tasks--forget-attachments').

(defconst harness-tasks--inline-types
  '(("image/png" . "png") ("image/jpeg" . "jpg") ("image/gif" . "gif") ("image/webp" . "webp"))
  "The media types of the files a client may attach to a task as data.
Each comes with the extension its file gets.  They are the pictures a
provider takes (`harness-agent--image-mimes').")

(defconst harness-tasks--inline-max-bytes (* 10 1024 1024)
  "Largest file, in bytes, a client may attach to a task as data.")

(defconst harness-tasks--inline-max-count 8
  "Most files a client may attach to a task as data, in one request.")

(defun harness-tasks--inline-p (attachment)
  "Non-nil when ATTACHMENT carries its file as data: a plist with a `:data'."
  (and (consp attachment) (keywordp (car attachment))
       (plist-get attachment :data) t))

(defun harness-tasks--sniff-type (bytes)
  "Return the media type of the picture the unibyte string BYTES holds, or nil.
Only the types of `harness-tasks--inline-types' are known, by the
signature that starts each."
  (cond ((string-prefix-p (unibyte-string #x89 ?P ?N ?G ?\r ?\n #x1a ?\n) bytes) "image/png")
        ((string-prefix-p (unibyte-string #xff #xd8 #xff) bytes) "image/jpeg")
        ((or (string-prefix-p "GIF87a" bytes) (string-prefix-p "GIF89a" bytes)) "image/gif")
        ((and (>= (length bytes) 12) (string-prefix-p "RIFF" bytes)
              (equal (substring bytes 8 12) "WEBP"))
         "image/webp")))

(defun harness-tasks--attachment-directory (id)
  "Return the directory that keeps the pictures task ID was sent as data."
  (expand-file-name (concat "attachments/" id "/") (harness-tasks--state-directory)))

(defun harness-tasks--file-name (name mime)
  "Return a file name for the picture called NAME, of the media type MIME.
Only plain characters, and the extension MIME's type has: what a client
calls a file says nothing about where it goes."
  (let* ((base (file-name-sans-extension (file-name-nondirectory (if (stringp name) name ""))))
         (base (string-trim (replace-regexp-in-string "[^A-Za-z0-9_-]+" "-" base) "-+" "-+")))
    (concat (if (string-empty-p base) "image" (truncate-string-to-width base 60))
            "." (cdr (assoc mime harness-tasks--inline-types)))))

(defun harness-tasks--inline-picture (attachment)
  "Return (BYTES MIME NAME) of ATTACHMENT, a picture sent as data.
NAME is what the client called it, or nil.  Signal an error naming it
when its data are no base64, it is too large, or its bytes are no
picture of a type a task takes, or not the type it says."
  (let* ((name (let ((n (plist-get attachment :name)))
                 (and (stringp n) (not (string-empty-p n)) n)))
         (shown (if name (format "Attachment %s" name) "An attachment sent as data"))
         (data (plist-get attachment :data))
         (bytes (and (stringp data)
                     (condition-case nil (base64-decode-string data) (error nil))))
         (mime (let ((m (or (plist-get attachment :mime) (plist-get attachment :mimeType))))
                 (and (stringp m) m)))
         (sniffed (and bytes (harness-tasks--sniff-type bytes))))
    (cond ((null bytes) (error "%s is not base64 data" shown))
          ((> (length bytes) harness-tasks--inline-max-bytes)
           (error "%s is larger than %s" shown (file-size-human-readable harness-tasks--inline-max-bytes)))
          ((null sniffed)
           (error "%s is no picture a task takes (%s)" shown
                  (mapconcat #'car harness-tasks--inline-types ", ")))
          ((and mime (not (equal mime sniffed)))
           (error "%s says it is %s but holds %s" shown mime sniffed))
          (t (list bytes sniffed name)))))

(defun harness-tasks--unique-file-name (dir name)
  "Return NAME, or NAME with a number before its extension, as no file of DIR has."
  (let ((base (file-name-sans-extension name))
        (extension (file-name-extension name t))
        (n 1)
        (candidate name))
    (while (file-exists-p (expand-file-name candidate dir))
      (setq n (1+ n)
            candidate (format "%s-%d%s" base n extension)))
    candidate))

(defun harness-tasks--keep-inline-attachments (id attachments)
  "Return ATTACHMENTS, task ID's, with each picture sent as data kept as a file.
The picture is written under the task's attachment directory, and its
attachment becomes that of the file: `:path', `:mime', `:name' and
`:size', with the `:label' the client gave it.  Any other attachment is
left as it is.  Every picture is checked before one is written
\(`harness-tasks--inline-picture'), so a request refused leaves nothing
behind."
  (let ((attachments (if (vectorp attachments) (append attachments nil) attachments)))
    (if (not (and (proper-list-p attachments) (cl-some #'harness-tasks--inline-p attachments)))
        attachments
      (let ((pictures (mapcar (lambda (a) (and (harness-tasks--inline-p a) (harness-tasks--inline-picture a)))
                              attachments))
            (dir (harness-tasks--attachment-directory id))
            (written nil))
        (when (> (length (delq nil pictures)) harness-tasks--inline-max-count)
          (error "A task takes at most %d pictures sent as data" harness-tasks--inline-max-count))
        (condition-case err
            (cl-mapcar
             (lambda (attachment picture)
               (if (null picture)
                   attachment
                 (pcase-let* ((`(,bytes ,mime ,name) picture)
                              (file (harness-tasks--unique-file-name
                                     dir (harness-tasks--file-name name mime)))
                              (path (expand-file-name file dir))
                              (label (plist-get attachment :label))
                              (coding-system-for-write 'no-conversion))
                   (harness-ensure-directory dir)
                   (write-region bytes nil path nil 'silent)
                   (push path written)
                   (append (list :path path :mime mime :name file :size (length bytes))
                           (and (stringp label) (not (string-empty-p label)) (list :label label))))))
             attachments pictures)
          (error (dolist (path written) (ignore-errors (delete-file path)))
                 (signal (car err) (cdr err))))))))

(defun harness-tasks--forget-attachments (id)
  "Delete the files task ID's attachments sent as data were kept in.
For a task that goes with its session: while the session stays, its
transcript names them."
  (let ((dir (harness-tasks--attachment-directory id)))
    (when (file-directory-p dir)
      (condition-case err (delete-directory dir t)
        (error (harness-log 'warn "task %s: keeping its attachments: %s"
                            id (error-message-string err)))))))

;;;; Methods

(harness-defmethod task/submit (cwd prompt &optional opts)
  "Submit PROMPT as a new task in directory CWD; return the task.
It starts at once when its project has a slot free, otherwise it waits
as pending: `harness-tasks-max-running' limits each project on its own.
OPTS: `:attachments' (ATTACHMENT list: files of this machine, `:path'
with `:mime', `:name' and `:size', or pictures sent as data, `:data' in
base64 with `:mime' and `:name', which are kept as files: see
Attachments sent as data), `:model', `:permission-mode',
`:thinking', `:non-interactive' (an explicit false turns it off),
`:supervisor' (t to plan and delegate, an explicit false to work
hands-on; without it the task takes `harness-supervisor-tasks' when it
starts, and without that module nothing), `:priority' (low, medium or
high, as a symbol or a string; medium by default: waiting tasks start
by priority, see `harness-priority-levels') and `:main-tree' (work in
the project's main checkout, with no worktree, no branch and nothing
to merge; for work that has to touch the checkout itself, such as
cleaning up uncommitted changes); missing ones come from the
`harness-tasks-' defaults, else from what the directory configures: a
task is interactive unless `harness-tasks-non-interactive' or the
directory's `harness-non-interactive' is on.  With `:refine'
the task goes to the backlog instead: an agent writes it up (state
refining), then it waits in the backlog until `task/start', or in auto
backlog mode goes on to the pending queue (`task/set-backlog-mode') --
unless the agent finds the board has it already, and refuses it as a
duplicate.
With `:plan' (which implies `:refine') the write-up is a plan: an agent
on a strong model (the hard tier of the task model's provider) reads
the code and hands in a plan for a cheaper model, which the task's work
then runs on -- `:model' and `:thinking' when given, else the medium
tier (see Plan mode above).  `:refine-model' and `:refine-thinking' set
the model and thinking level of the write-up or plan itself.
A refined task keeps `:main-tree' for when it finally starts.
Either way the task is named from PROMPT at once, beside everything
else (see Titles above): its `:name' comes while it waits, and its
session takes it."
  (when (harness-string-blank-p prompt) (error "A task needs a prompt"))
  (harness-tasks--load)
  (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
         (plan (harness-json-true-p (plist-get opts :plan)))
         (refine (or plan (harness-json-true-p (plist-get opts :refine))))
         (main-tree (and (harness-json-true-p (plist-get opts :main-tree)) t))
         ;; The priority is the session's, which the task gets now: the
         ;; priority plugin reads the name (and refuses one no level
         ;; has before any task is made) and puts it there.
         (priority (plist-get opts :priority))
         (created (float-time))
         (task (list :id (concat "t-" (harness-short-id 8))
                     :project (harness-tasks--project cwd) :cwd cwd
                     :prompt (string-trim prompt)
                     :attachments (plist-get opts :attachments)
                     :model (plist-get opts :model)
                     :permission-mode (let ((m (plist-get opts :permission-mode)))
                                        (if (stringp m) (intern m) m))
                     :thinking (plist-get opts :thinking)
                     :state 'pending :created created)))
    (when priority
      (harness-priority-read priority))
    ;; Pictures sent as data become files, now that nothing else can
    ;; refuse the task: one refused leaves no file behind.
    (setq task (plist-put task :attachments
                          (harness-tasks--keep-inline-attachments
                           (plist-get task :id) (plist-get task :attachments))))
    (when (plist-member opts :non-interactive)
      (setq task (plist-put task :non-interactive
                            (if (harness-json-true-p (plist-get opts :non-interactive)) t :false))))
    (when (plist-member opts :supervisor)
      (setq task (plist-put task :supervisor
                            (if (harness-json-true-p (plist-get opts :supervisor)) t :false))))
    (when main-tree
      (setq task (append task (list :main-tree t))))
    ;; A task that waits for a slot joins the queue as it is submitted
    ;; (`harness-tasks--queued-since'); one written up for the backlog
    ;; waits for the user instead, and joins it with `task/queue'.
    (if refine
        (setq task (append task (list :backlog t :note (string-trim prompt))))
      (setq task (append task (list :queued-at created))))
    (dolist (key '(:refine-model :refine-thinking))
      (let ((value (plist-get opts key)))
        (when (and (stringp value) (not (harness-string-blank-p value)))
          (setq task (plist-put task key (string-trim value))))))
    (when plan
      (setq task (plist-put task :plan t))
      ;; The work runs on the model the plan is written for, unless the
      ;; submitter named one.
      (pcase-let ((`(,model . ,thinking) (harness-tasks--plan-work task)))
        (when (and model (not (plist-get task :model)))
          (setq task (plist-put task :model model)))
        (when (and thinking (not (plist-get task :thinking)))
          (setq task (plist-put task :thinking thinking)))))
    (harness-tasks--put task)
    ;; Its session from the start, holding the task's priority; before
    ;; the naming request goes out, so the session leaves its naming to
    ;; it (`harness-tasks--auto-name-p').
    (harness-tasks--make-session task priority)
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
waits in the backlog until `task/start', or in auto backlog mode goes
on to the pending queue (`harness-tasks--auto-queue')."
  (let ((task (harness-tasks--get id)))
    (unless (memq (plist-get task :state) '(pending refining))
      (error "Task %s has started; only a task that has not can be refined" id))
    (when (harness-tasks--turn-p task) (error "Task %s is being refined already" id))
    (harness-tasks--refine id text)
    (harness-call 'task/get id)))

(defun harness-tasks--adoptable-p (session)
  "Non-nil when SESSION may become a task.
It must be open, not a task already and not a conversation about the board."
  (and (not (eq (plist-get session :status) 'inactive))
       (not (harness-tasks--by-session (plist-get session :id)))
       (not (harness-tasks--btw-p session))))

(harness-defmethod task/hand-in-plan (session-id title plan)
  "Hand in PLAN, titled TITLE, for the task SESSION-ID plans; return the task.
SESSION-ID is the session planning a backlog task (Plan mode, see
`harness-tasks--plan-p').  The plan, opened by its title, becomes the
task's prompt, and the task waits in the backlog until `task/start', as
a written-up one does; the end of the running turn leaves it so.  The
plan shows in the session's transcript as the `plan' tool shows one.
Signals when the session plans no task, or TITLE or PLAN is blank.
The `submit_task_plan' tool calls this (harness-tools-sessions.el)."
  (let ((task (harness-tasks--by-session session-id)))
    (unless (and task (harness-tasks--refinement-p task) (harness-tasks--plan-p task))
      (error "This session plans no task: submit_task_plan is for the session that plans a backlog task"))
    (when (harness-string-blank-p plan)
      (error "The plan is empty: write it, in markdown"))
    (when (harness-string-blank-p title)
      (error "The title is empty: give the task a short imperative title"))
    (let ((title (harness-first-line (string-trim title)))
          (plan (string-trim plan))
          (id (plist-get task :id)))
      (harness-tasks--set id :state 'pending :backlog t :prompt (concat title "\n\n" plan)
                          :refined (float-time) :outcome nil :error nil :duplicate-of nil)
      (puthash session-id t harness-tasks--plans-submitted)
      (harness-call 'session/set-plan session-id plan)
      (harness-call 'session/append session-id (list :kind 'plan :content plan :title title))
      (harness-call 'session/hint session-id "Plan handed in")
      (harness-call 'task/get id))))

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
task context limit applies from now on when there is one, and the
session's transcript says so."
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
      ;; Nothing to copy about its priority: a task's priority is its
      ;; session's, and this session is the task's now.
      ;; The task's shorter context applies from its next turn on; a
      ;; session adopted after long work may compact on it right away,
      ;; and nil (turned off) clears a limit the session carried.
      (harness-call 'session/update session-id
                    :context-window-limit harness-tasks-context-limit :silent t)
      (unless (equal harness-tasks-context-limit (plist-get session :context-window-limit))
        (harness-tasks--say-context-limit session-id harness-tasks-context-limit))
      (when (and worktree (harness-method-exists-p 'worktree/branch))
        (let ((id (plist-get task :id)))
          (harness-then (harness-call-async 'worktree/branch worktree)
                        (lambda (branch) (when (gethash id harness-tasks--table)
                                           (harness-tasks--set id :branch branch)))
                        #'ignore)))
      (harness-tasks--view task))))

(harness-defmethod task/btw (cwd &optional name model)
  "Start a BTW conversation about the task board of CWD's project.
Return its session, where the user asks how the tasks are going: a new
`btw' session named NAME at the project root on every call, sharing
nothing with earlier ones, and without a parent (a BTW over a session is
listed under it instead, see `session/btw'), which
`harness-tasks--btw-prompt' tells to answer with the task and session
tools.  Like every BTW it runs on `harness-btw-model' -- by default the
simple tier of the provider of `harness-model' there -- and thinks at
`harness-btw-thinking' fitted to the levels that model offers: that
level, else the nearest it offers below it, else its weakest
\(`harness-session--btw-thinking', see `session/create').  MODEL, a
PROVIDER:NAME, picks another model for this one BTW instead; blank is
none, and a model the policy does not allow signals an error (see
`session/btw').  The caller sends the first question."
  (let ((asked (and (stringp model) (not (string-blank-p model)) (string-trim model))))
    (when (and asked (fboundp 'harness-session-check-policy))
      (harness-session-check-policy (list :model asked) 'btw))
    (apply #'harness-call 'session/create
           :cwd (harness-tasks--project cwd) :kind 'btw :name name
           (and asked (list :model asked)))))

(harness-defmethod task/list (&optional cwd)
  "Return the tasks of CWD's project, oldest first; every task without CWD.
Each is a view with its `:column' (`harness-tasks--column').  Without
CWD it is every project's tasks, which the board of every project
\(`harness-tasks-all') shows and the mode line counts the ones in review
of.  The order the waiting ones start in is `task/queue-order''s."
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
`:max-running' is how many of a project's tasks work at once, nil for
no limit (`harness-tasks-max-running'; a board shows it as \"N at a
time\").  Model, thinking and non-interactive are the values a new task would
really get: the task defaults, else what the project configures.  So
non-interactive is on only when `harness-tasks-non-interactive' is, or
`harness-non-interactive' for the project.  `:supervisor' is there
only when the supervisor module is loaded, and is what a task without
a setting of its own would get, `harness-supervisor-tasks';
`:require-verification' is t while finished work waits for the user's
review, else false (not nil, which JSON could not tell from a harness
that does not say): `harness-tasks-require-verification'.
`:queue-suspended' is t while the project's pending queue is suspended
\(`task/suspend-queue'), `:backlog-mode' the mode of its backlog, `auto'
while a write-up that finishes queues its task, else `manual'
\(`task/set-backlog-mode').  The models and thinking levels a new task's
write-up would get are there too, resolved for the project's task
model: `:refine-model' and `:refine-thinking' for a brief write-up
\(Refine), `:plan-model' and `:plan-thinking' for a plan (Plan), and
`:plan-work-model' and `:plan-work-thinking' for the work after a
plan.  That work runs hands-on, whatever `:supervisor' says, unless the
task was given a setting of its own (the supervisor module's
`harness-supervisor--task-value').  `:inline-attachments' lists the
media types of the files a client that cannot name a file of this
machine may attach to a task as data (`task/submit'); a harness that
does not say takes none, and a client must not offer them."
  (let* ((root (and cwd (harness-tasks--project cwd)))
         (model (or harness-tasks-model (harness-tasks--config 'harness-model root)))
         (thinking (or harness-tasks-thinking (harness-tasks--config 'harness-thinking root)))
         (proto (list :model model :thinking thinking :cwd root))
         (work (harness-tasks--plan-work proto)))
    (append
     (list :max-running harness-tasks-max-running
           :queue-suspended (if (harness-tasks--suspended-p root) t :false)
           :backlog-mode (harness-tasks--backlog-mode root)
           :permission-mode harness-tasks-permission-mode
           :non-interactive (and (or harness-tasks-non-interactive
                                     (harness-json-true-p (harness-tasks--config 'harness-non-interactive root)))
                                 t)
           :require-verification (if harness-tasks-require-verification t :false)
           :model model
           :thinking thinking
           :worktrees (and root (harness-tasks--git-p root) t)
           :inline-attachments (mapcar #'car harness-tasks--inline-types)
           :refine-model (or harness-tasks-refine-model model)
           :refine-thinking (or harness-tasks-refine-thinking thinking)
           :plan-model (harness-tasks--plan-model proto)
           :plan-thinking (harness-tasks--plan-thinking proto)
           :plan-work-model (or (car work) model)
           :plan-work-thinking (or (cdr work) thinking))
     ;; A harness without the supervisor module has no such setting to
     ;; report, and its tasks work as they always did.
     (and (boundp 'harness-supervisor-tasks)
          (list :supervisor (if harness-supervisor-tasks t :false))))))

;;;; The slots, as a page shows them
;;
;; `task/slots' reads what the scheduler goes by -- who holds a slot
;; (`harness-tasks--holds-slot-p'), who waits for one, in what order
;; (`harness-tasks--queued-p', `harness-tasks--start-order') -- and the
;; waits the starts recorded (`harness-tasks--waits-after'), and hands
;; them to a UI as plain data.  It counts nothing of its own: a task's
;; sub-agents, forks and the merge queue's resolvers take no slot, so
;; they are in none of it.

(defconst harness-tasks--slot-waits-max 500
  "Most waits `task/slots' reports.")

(defun harness-tasks--slot-title (task)
  "Return how the slot view names TASK, 80 characters at most.
That is the title the board shows: its session's name, else its own
`:name', else the first line of its prompt."
  (let ((name (plist-get (harness-tasks--session task) :name)))
    (harness-first-line (cond ((not (harness-string-blank-p name)) name)
                              ((not (harness-string-blank-p (plist-get task :name))) (plist-get task :name))
                              (t (plist-get task :prompt)))
                        80)))

(defun harness-tasks--slot-holder (task)
  "Return the entry of TASK, which holds a slot, in `task/slots' :holders."
  (let ((id (plist-get task :id))
        (session (harness-tasks--session task)))
    (list :id id
          :title (harness-tasks--slot-title task)
          :session (plist-get task :session)
          :priority (symbol-name (harness-priority-of-task task))
          ;; Waiting for the user is that before it is anything else, as it
          ;; is on the board (`harness-tasks--column'): a task resumed after
          ;; a restart is starting and may sit on a question already.
          :state (cond ((harness-session-waiting-on-user-p session) "blocked")
                       ((gethash id harness-tasks--starting) "starting")
                       ((plist-get task :waiting) "waiting")
                       (t (format "%s" (plist-get session :status))))
          :since (harness-tasks--working-since task)
          :sent-back (if (harness-tasks--sent-back-p task) t :false))))

(defun harness-tasks--slot-queued (task)
  "Return the entry of TASK, which waits for a slot, in `task/slots' :queue."
  (append (list :id (plist-get task :id)
                :title (harness-tasks--slot-title task)
                :priority (symbol-name (harness-priority-of-task task))
                :since (harness-tasks--queued-since task)
                :reason (and (harness-tasks--returned-p task)
                             (symbol-name (harness-tasks--return-reason task))))
          (when-let* ((hold (harness-tasks--hold task)))
            (list :hold hold))))

(defun harness-tasks--slot-waits (project)
  "Return the recent waits of PROJECT's tasks, newest first, for `task/slots'.
Those recorded in the last `harness-tasks-slot-wait-days' days by any
task of PROJECT, archived and done ones included, as (:id :priority
:seconds :at) plists, at most `harness-tasks--slot-waits-max'."
  (let ((since (- (float-time)
                  (* 86400.0 (max 0 (if (numberp harness-tasks-slot-wait-days)
                                        harness-tasks-slot-wait-days
                                      7)))))
        waits)
    (maphash (lambda (_ task)
               (when (equal (harness-tasks--slot-project task) project)
                 (dolist (wait (plist-get task :waits))
                   (let ((at (plist-get wait :at))
                         (seconds (plist-get wait :seconds)))
                     (when (and (numberp at) (numberp seconds) (>= at since))
                       (push (list :id (plist-get task :id) :priority (plist-get wait :priority)
                                   :seconds seconds :at at)
                             waits))))))
             harness-tasks--table)
    (take harness-tasks--slot-waits-max
          (sort waits (lambda (a b) (> (plist-get a :at) (plist-get b :at)))))))

(harness-defmethod task/slots (&optional cwd)
  "Return how the task slots of CWD's project are used, for a slot page.
A plist, all of it plain data:
  :project   the project's root, as `task/list' files its tasks under
  :limit     its slots, `harness-tasks-max-running': a number, 0 when
             no task starts by itself, nil without a limit
  :suspended t while its pending queue is suspended (`task/suspend-queue'),
             else :false
  :days      `harness-tasks-slot-wait-days', how far back :waits go
  :holders   the tasks holding a slot (`harness-tasks--holds-slot-p'),
             the longest at work first, each a plist of :id, :title (its
             name, else its prompt's first line), :session, :priority
             (\"low\", \"medium\" or \"high\"), :state (\"blocked\", its
             session waits for the user -- a task starting or resumed
             after a restart, held by the question a cold prompt cache
             asks, is blocked, as the board says it needs input;
             \"starting\"; \"waiting\", its session ended its turn but
             left work running; or its session's status, \"running\"
             or \"blocked\"), :since (when its work began or was last sent
             back, a float time) and :sent-back (t when its work is
             feedback that sent it back from review, else :false)
  :queue     the tasks waiting for a slot (`harness-tasks--queued-p'),
             in the order they will start (`harness-tasks--start-order'),
             each a plist of :id, :title, :priority, :since (when it
             began waiting, `harness-tasks--queued-since'), :reason
             (why it was put back in the queue after it worked --
             \"returned\", \"preempted\", \"sent-back\", \"quota\" or
             \"budget\" -- else nil) and :hold, when something holds it
             back (`harness-tasks--hold'): a plist of :kind (\"paused\",
             \"quota\" or \"budget\"), :reason, :until, :guess and :items
  :queues    every project's queue and :totals over them, as `task/queues'
             lists them, for the page's section on queues
  :waits     how long tasks of the project waited for a slot before
             they started, newest first, the last :days days only, at
             most 500: plists of :id, :priority (the level it waited
             at), :seconds and :at (when it started, a float time)
No sub-agent, fork or merge-queue work holds a slot, so none is listed."
  (harness-tasks--load)
  (let* ((project (harness-tasks--project (or cwd default-directory)))
         (mine (lambda (task) (equal (harness-tasks--slot-project task) project)))
         (report (progn (harness-tasks--open-project project)
                        (harness-tasks--queues-report))))
    (list :project project
          :limit harness-tasks-max-running
          :suspended (if (harness-tasks--suspended-p project) t :false)
          :days harness-tasks-slot-wait-days
          :holders (mapcar #'harness-tasks--slot-holder
                           (sort (harness-tasks--sorted
                                  (lambda (task) (and (funcall mine task)
                                                      (harness-tasks--holds-slot-p task))))
                                 (lambda (a b) (< (harness-tasks--working-since a)
                                                  (harness-tasks--working-since b)))))
          :queue (mapcar #'harness-tasks--slot-queued
                         (harness-tasks--start-order
                          (harness-tasks--sorted
                           (lambda (task) (and (funcall mine task) (harness-tasks--queued-p task))))))
          :waits (harness-tasks--slot-waits project)
          :queues (plist-get report :queues)
          :totals (plist-get report :totals))))

(harness-defmethod task/queue-order (&optional cwd)
  "Return the tasks waiting for a slot, in the order they will start.
CWD's project's, every project's without CWD: the tasks
`harness-tasks--queued-p' says wait -- pending, not in the backlog, not
archived -- in the order the scheduler hands them slots
\(`harness-tasks--start-order'): by priority; among equals, work sent
back from review first, then the tasks returned to pending (paused,
pre-empted, or their borrowed slot taken back), the first returned
first, then the others, oldest first.  The board's Pending lists a
project's waiting tasks in that order too.  Each is a plist of :id,
:project, the project whose slots it takes
\(`harness-tasks--slot-project'), and :place, its place in that
project's line: 1 is the next of the project's tasks to start.  The
projects have slots of their own, so the places count per project.  A
suspended queue keeps its order, which its tasks start in once it
resumes."
  (harness-tasks--load)
  (let ((project (and cwd (harness-tasks--project cwd)))
        (places (make-hash-table :test 'equal)))
    (when project (harness-tasks--open-project project))
    (mapcar (lambda (task)
              (let ((home (harness-tasks--slot-project task)))
                (list :id (plist-get task :id)
                      :project home
                      :place (puthash home (1+ (gethash home places 0)) places))))
            (harness-tasks--start-order
             (harness-tasks--sorted
              (lambda (task)
                (and (harness-tasks--queued-p task)
                     (or (null project) (equal project (harness-tasks--slot-project task))))))))))

(harness-defmethod task/set-all (settings &optional filter)
  "Apply SETTINGS to every current task FILTER selects; return the ids changed.
SETTINGS is a plist of `:model', `:thinking', `:permission-mode',
`:non-interactive' (an explicit false turns it off), `:supervisor' (t
supervises, an explicit false works hands-on) and `:priority' (low,
medium or high, as the priority plugin reads it).  Only the settings
given change: without `:priority' (or with nil) every task keeps its
own, so a bulk edit sets priorities only when asked to.  A started
task's session gets the session settings too, so its next turn uses
them; a pending task keeps them for when it starts, and the session of
a backlog write-up keeps them until the task starts.  A priority is
given to the task's session (`harness-priority-set-session'), where the
board's queue and the queues the task's work waits in read it
\(`harness-priority-of-task'), and starts nothing.  FILTER:
`:columns' (default `harness-tasks-bulk-columns', the running, pending,
backlog and blocked tasks), `:ids' to name tasks outright, `:except' ids to
leave alone, and `:cwd' to stay inside one project; without it the
tasks of every project are selected.  Review, done and archived tasks
are history and are never touched.  A task already set so is left
alone (non-interactive counts as what the task would start with, see
`harness-tasks--prefs-differ-p'), and a session already holding a value
is not sent it again, so a session `session/set-all' changed first gets
no second hint.  Return the ids that changed, oldest first."
  ;; A bad priority is refused before any task changes.
  (let ((priority (and (plist-get settings :priority)
                       (harness-priority-read (plist-get settings :priority))))
        (settings (harness-plist-remove settings :priority))
        changed)
    (dolist (task (harness-tasks--bulk-selected filter))
      (let ((id (plist-get task :id))
            (differ (harness-tasks--prefs-differ-p task settings))
            (prior (and priority (plist-get task :session)
                        (not (eq priority (harness-priority-of-task task))))))
        (cond ((or differ prior)
               (when differ (harness-tasks--apply-prefs task settings))
               ;; The priority is the session's, where the board and the
               ;; queues read it (see the priority plugin).
               (when prior (harness-priority-set-session (plist-get task :session)
                                                         (symbol-name priority)))
               (push id changed)))))
    (nreverse changed)))

(harness-defmethod task/session-ids (&optional filter)
  "Return the ids of the sessions of the current tasks FILTER selects.
FILTER is the one of `task/set-all'; by default the running, pending,
backlog and blocked tasks of every project.  A task without a session yet adds
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

(harness-defmethod task/suspend-queue (&optional cwd)
  "Suspend the pending queue of CWD's project (the current one by default).
No waiting task of that project then starts on its own: the board is
clear for one urgent task, which `task/start' starts as it always does,
whatever the limit.  A task already waiting waits on, and one at work
goes on.  The suspension is per project and kept, so it outlives a
restart.  Return (:project PROJECT :suspended t)."
  (let ((project (harness-tasks--project (or cwd default-directory))))
    (harness-tasks--set-suspended project t)
    (list :project project :suspended t)))

(harness-defmethod task/resume-queue (&optional cwd)
  "Start starting the pending tasks of CWD's project again, at once.
They start in start order (`harness-tasks--start-order') -- by priority;
of a priority, work sent back from review first, then a task returned
to pending, then the oldest -- up to `harness-tasks-max-running'.
Return (:project PROJECT :suspended :false)."
  (let ((project (harness-tasks--project (or cwd default-directory))))
    (harness-tasks--set-suspended project nil)
    (harness-tasks--schedule)
    (list :project project :suspended :false)))

(harness-defmethod task/toggle-queue (&optional cwd)
  "Suspend the pending queue of CWD's project if it is running, else resume it.
Return (:project PROJECT :suspended STATE), the new state: t while the
queue is suspended, :false once it runs again."
  (let* ((project (harness-tasks--project (or cwd default-directory)))
         (suspended (not (harness-tasks--suspended-p project))))
    (harness-tasks--set-suspended project suspended)
    (when (not suspended) (harness-tasks--schedule))
    (list :project project :suspended (if suspended t :false))))

;;;; Queues, all of them
;;
;; The slots page lists every project's queue in one place: its state,
;; who works, who waits, and what holds the waiting tasks back.  The
;; summary is data (`task/queues'), as `task/slots' is for a project's
;; slots, and so are the two switches that pause or resume every queue
;; at once; the queues are paused one by one with `task/suspend-queue'.

(defun harness-tasks--queue-projects ()
  "Return the projects whose queue is worth listing, sorted.
Those with a task that works or waits -- active, pending (in the queue
or the backlog), being written up, in the merge queue -- not archived,
and those whose queue is suspended, whether a task waits in them or not."
  (harness-tasks--load-queues)
  (let ((projects (make-hash-table :test 'equal)))
    (maphash (lambda (_ task)
               (when (and (memq (plist-get task :state) '(active pending refining merging))
                          (not (plist-get task :archived))
                          (stringp (harness-tasks--slot-project task)))
                 (puthash (harness-tasks--slot-project task) t projects)))
             harness-tasks--table)
    (maphash (lambda (project _) (puthash project t projects)) harness-tasks--queues)
    (sort (hash-table-keys projects) #'string<)))

(defun harness-tasks--project-name (project)
  "Return how PROJECT, a root, is named on a page.
That is the project module's name for it, else its directory's."
  (or (and (harness-method-exists-p 'project/name)
           (ignore-errors (harness-call 'project/name project)))
      (file-name-nondirectory (directory-file-name project))))

(defun harness-tasks--queue-summary (project)
  "Return the queue of PROJECT as `task/queues' lists it, a plist.
`:state' is \"paused\" while the queue is suspended, \"held\" while tasks
wait and none of them can start for quota or a budget (or because the
user paused it), else \"running\".  `:working' counts the tasks holding a
slot, `:waiting' those in the queue, `:paused' those of them paused by
hand and `:held' those waiting for quota or a budget, whose reasons
`:holds' lists once each, with the number of tasks it holds back and the
marks or budgets behind it (`:items', as a task's `:hold' has them)."
  (let ((queued (harness-tasks--sorted
                 (lambda (task) (and (equal (harness-tasks--slot-project task) project)
                                     (harness-tasks--queued-p task)))))
        (working 0) (paused 0) (held 0) holds)
    (maphash (lambda (_ task)
               (when (and (equal (harness-tasks--slot-project task) project)
                          (harness-tasks--holds-slot-p task))
                 (cl-incf working)))
             harness-tasks--table)
    (dolist (task queued)
      (let* ((hold (harness-tasks--hold task))
             (kind (plist-get hold :kind)))
        (cond
         ((eq kind 'paused) (cl-incf paused))
         (kind
          (cl-incf held)
          (let ((cell (cl-find-if (lambda (h) (and (eq (plist-get h :kind) kind)
                                                   (equal (plist-get h :reason) (plist-get hold :reason))))
                                  holds)))
            (if cell
                (plist-put cell :count (1+ (plist-get cell :count)))
              (push (list :kind kind :reason (plist-get hold :reason) :until (plist-get hold :until)
                          :guess (plist-get hold :guess) :items (plist-get hold :items) :count 1)
                    holds)))))))
    (let ((suspended (harness-tasks--suspended-p project))
          (waiting (length queued)))
      (list :project project
            :name (harness-tasks--project-name project)
            :state (cond (suspended "paused")
                         ((and (> held 0) (= (+ held paused) waiting)) "held")
                         (t "running"))
            :suspended (if suspended t :false)
            :limit harness-tasks-max-running
            :working working :waiting waiting :paused paused :held held
            :holds (nreverse holds)))))

(defun harness-tasks--queues-report ()
  "Return every listed queue and the totals, as `task/queues' answers."
  (let* ((queues (mapcar #'harness-tasks--queue-summary (harness-tasks--queue-projects)))
         (sum (lambda (key) (apply #'+ (mapcar (lambda (queue) (plist-get queue key)) queues)))))
    (list :queues queues
          :totals (list :queues (length queues)
                        :suspended (cl-count-if (lambda (queue) (eq (plist-get queue :suspended) t)) queues)
                        :working (funcall sum :working) :waiting (funcall sum :waiting)
                        :paused (funcall sum :paused) :held (funcall sum :held)))))

(harness-defmethod task/queues ()
  "Return every project's queue, and the totals over them, for a page.
A plist of `:queues', one for each project with a task that works or
waits and for each project whose queue is suspended, by project, each a
plist of `:project' (its root), `:name', `:state' (\"running\",
\"paused\" -- the queue is suspended --, or \"held\" -- tasks wait and
none can start, for quota, a budget or a pause), `:suspended', `:limit'
\(`harness-tasks-max-running'), `:working' (tasks holding a slot),
`:waiting' (tasks in the queue), `:paused' (of those, paused by hand),
`:held' (of those, waiting for quota or a budget) and `:holds' (the
reasons of those, each as `:kind' quota or budget, `:reason', `:until',
`:guess', `:items' and `:count'), and of `:totals', the same counts over every
queue, with `:queues' and `:suspended', how many queues are suspended."
  (harness-tasks--load)
  (harness-tasks--queues-report))

(harness-defmethod task/suspend-all-queues ()
  "Suspend the pending queue of every project that has one worth listing.
`task/queues' lists them: those with a task that works or waits.  Each is
suspended as `task/suspend-queue' suspends it; a queue made after this is
not.  Tasks at work go on; none waiting starts on its own.  Return
\(:projects PROJECTS :suspended t)."
  (harness-tasks--load)
  (let ((projects (harness-tasks--queue-projects)))
    (dolist (project projects)
      (harness-tasks--set-suspended project t))
    (list :projects projects :suspended t)))

(harness-defmethod task/resume-all-queues ()
  "Resume every suspended queue, and start the waiting tasks, by priority.
Each project's queue is resumed as `task/resume-queue' resumes it.
Return (:projects PROJECTS :suspended :false), PROJECTS being the ones
that were suspended."
  (harness-tasks--load)
  (harness-tasks--load-queues)
  (let ((projects (sort (hash-table-keys harness-tasks--queues) #'string<)))
    (dolist (project projects)
      (harness-tasks--set-suspended project nil))
    (harness-tasks--schedule)
    (list :projects projects :suspended :false)))

(harness-defmethod task/backlog-mode (&optional cwd)
  "Return the backlog mode of CWD's project (the current one by default).
That is (:project PROJECT :mode MODE).  MODE is `manual', the default --
a written-up task waits in the backlog until someone queues it
\(`task/queue') or starts it -- or `auto': a write-up that finishes
queues its task, which the scheduler then starts like any queued task."
  (let ((project (harness-tasks--project (or cwd default-directory))))
    (list :project project :mode (harness-tasks--backlog-mode project))))

(harness-defmethod task/set-backlog-mode (mode &optional cwd)
  "Put the backlog of CWD's project in MODE, `manual' or `auto' (or its name).
In auto mode each write-up that finishes from now on queues its task,
as `task/queue' would (`harness-tasks--auto-queue'): by priority, within
the limit, and held while the queue is suspended.  The tasks already
waiting in the backlog stay there, and going back to manual takes no
task out of the queue.  The mode is per project and kept across
restarts.  Return (:project PROJECT :mode MODE)."
  (let ((project (harness-tasks--project (or cwd default-directory)))
        (mode (harness-tasks--read-backlog-mode mode)))
    (list :project project :mode (harness-tasks--set-backlog-mode project mode))))

(harness-defmethod task/toggle-backlog-mode (&optional cwd)
  "Switch the backlog of CWD's project between manual and auto queueing.
See `task/set-backlog-mode'.  Return (:project PROJECT :mode MODE), the
new mode."
  (let* ((project (harness-tasks--project (or cwd default-directory)))
         (mode (if (harness-tasks--auto-queue-p project) 'manual 'auto)))
    (list :project project :mode (harness-tasks--set-backlog-mode project mode))))

(harness-defmethod task/start (id)
  "Start pending task ID now, even when every slot of its project is taken.
A backlog task starts too (or `task/queue' leaves it to the queue), and
so does one whose write-up stopped (with the prompt it has).  A start
supersedes a write-up that is still running: its turn is stopped
\(`harness-tasks--supersede'), its write-up is never finished, and the
task starts with the write-up it has once that turn has ended.  A
task returned to pending starts in the session that already worked on
it, which carries on where it stopped (`harness-tasks--start-paused').
Its project's queue being suspended (task/suspend-queue) does not hold
this up: an explicit start always starts the task."
  (let ((task (harness-tasks--get id)))
    (unless (memq (plist-get task :state) '(pending refining)) (error "Task %s already started" id))
    (cond
     ((harness-tasks--turn-p task)
      (unless (harness-tasks--refinement-p task)
        (error "Task %s is working already" id))
      (harness-tasks--supersede task))
     (t (harness-tasks--start task)))
    (harness-call 'task/get id)))

(harness-defmethod task/queue (id)
  "Put backlog task ID back in the pending queue, where it starts by itself.
The scheduler starts it as soon as its project has a free slot, by
priority, as it starts any queued task; while the project's queue is
suspended (`task/suspend-queue') it waits in pending until the queue is
resumed or it is started by hand.  The write-up is kept: the work opens
with the write-up and the request it came from
\(`harness-tasks--start-text').  It waits for a slot from now
\(`:queued-at', see `harness-tasks--queued-since').  Return the task's
view."
  (let ((task (harness-tasks--get id)))
    (unless (and (eq (plist-get task :state) 'pending) (harness-tasks--backlog-p task))
      (error "Task %s is not waiting in the backlog (%s)" id (or (plist-get task :state) "?")))
    (when (harness-tasks--turn-p task)
      (error "Task %s is still being written up; wait for it or stop it" id))
    (prog1 (harness-tasks--set id :backlog nil :queued-at (float-time))
      (harness-tasks--schedule))))

(harness-defmethod task/return-to-pending (id)
  "Stop the turn of active task ID and put it back in the pending queue.
The task keeps its session, branch and worktree, so it carries on where
it stopped when it starts again (`harness-tasks--start-paused'), and it
goes to the front of its priority's queue: ahead of the tasks that
never started, behind only tasks of a higher priority, and among the
returned ones the first returned starts first.  The work its session
left running outside its turn -- a supervisor's workers, sub-agents --
stops too, once no turn of the session runs: at once for a task that
only waited on it (`:waiting'), else when the stopped turn ends
\(`harness-tasks--stop-outstanding').  Returning it frees its slot for
the other waiting tasks; the return itself starts nothing, suspended
or not, so the task waits for the next task the queue starts, for
`task/resume-queue', or for an explicit `task/start'.  Return the
task's view."
  (let ((task (harness-tasks--get id)))
    (unless (eq (plist-get task :state) 'active)
      (error "Task %s is not at work (%s); only a task at work can be returned to pending"
             id (plist-get task :state)))
    (when (gethash id harness-tasks--starting)
      (error "Task %s is still starting; wait for it or stop it" id))
    ;; The queue first, then the turn: a cancel that ends the turn at once
    ;; then finds the task waiting, not at work (`harness-tasks--returning').
    ;; The work left running outside the turn stops once no turn runs:
    ;; now, or when the stopped turn ends (`harness-tasks--on-turn-ended').
    (prog1 (harness-tasks--to-pending id)
      (unless (harness-tasks--stop-turn id)
        (harness-tasks--stop-outstanding id))
      (harness-tasks--schedule id))))

(harness-defmethod task/pause (id)
  "Pause task ID: back in the pending queue, and held there until resumed.
A task at work is returned to pending as `task/return-to-pending'
returns it -- its turn stopped, and the work its session left running
outside it, its session, branch and worktree kept -- and unlike that
return it stays: the queue does not start a paused task, however many
slots are free, until `task/resume', an explicit `task/start' or a turn
the user starts in its session (`:paused' is when; the view's `:hold'
says `paused').  A task waiting for a slot is paused where it is, and
one stopped part way (waiting for the user) is paused like one at work.
The pause is kept with the task, so it outlives a restart: the
scheduler that starts the waiting tasks as the harness comes up leaves
a paused task alone.  Pausing is independent of suspending the queue
\(`task/suspend-queue'); each holds a task back by itself.  A task
already paused stays so.  Signals for a task that is in review,
merging, done or in the backlog.  Return the task."
  (harness-tasks--pause id)
  ;; Written now, not in a moment: a pause is a decision, and a crash
  ;; before the save would let the restart carry the task on.
  (harness-tasks-flush)
  (harness-call 'task/get id))

(harness-defmethod task/resume (id)
  "End the pause of task ID, which then waits for its turn in the queue.
The queue starts it by priority within the limit, unless its project's
queue is suspended or it is held for quota or a budget meanwhile
\(`harness-tasks--hold'); it carries on where it stopped, told by the
harness it was paused.  `task/start' starts it at once instead.  A task
that is not paused stays as it was.  Return the task."
  (harness-tasks--unpause id)
  (harness-call 'task/get id))

(defun harness-tasks--in-project-p (task project)
  "Non-nil when TASK takes the slots of PROJECT, or PROJECT is nil (any project)."
  (or (null project) (equal project (harness-tasks--slot-project task))))

(harness-defmethod task/pause-all (&optional cwd)
  "Pause every task of CWD's project, of every project without CWD.
Every task at work (`harness-tasks--at-work-p') is paused as `task/pause'
pauses it, and so is every task waiting for a slot: the slots the first
free would otherwise start the second.  The waiting ones are paused
first, so nothing starts into a slot a paused task frees.  Tasks stopped
part way, in the backlog, in review, in the merge queue and done are
left alone, and so are those paused already.  Queues are not touched:
suspending them is `task/suspend-queue' and `task/suspend-all-queues'.
Return (:ids IDS), the tasks paused."
  (harness-tasks--load)
  (let* ((project (and cwd (harness-tasks--project cwd)))
         (waiting (harness-tasks--sorted
                   (lambda (task) (and (harness-tasks--in-project-p task project)
                                       (harness-tasks--queued-p task)
                                       (not (harness-tasks--paused-p task))))))
         (working (harness-tasks--sorted
                   (lambda (task) (and (harness-tasks--in-project-p task project)
                                       (harness-tasks--at-work-p task)))))
         (ids nil))
    (dolist (task (append waiting working))
      (let ((id (plist-get task :id)))
        (condition-case err
            (progn (harness-tasks--pause id)
                   (push id ids))
          (error (harness-log 'warn "task %s: pausing it failed: %s" id (harness-error-message err))))))
    ;; Written now, as `task/pause' does.
    (harness-tasks-flush)
    (list :ids (nreverse ids))))

(harness-defmethod task/resume-all (&optional cwd)
  "End the pause of every paused task of CWD's project (every project without).
The queue then starts them as slots are free, by priority, as it starts
any waiting task, and not while their project's queue is suspended.  One
scheduling pass follows, after every pause is ended.  Return (:ids IDS),
the tasks resumed."
  (harness-tasks--load)
  (let* ((project (and cwd (harness-tasks--project cwd)))
         (ids nil))
    (dolist (task (harness-tasks--sorted
                   (lambda (task) (and (harness-tasks--in-project-p task project)
                                       (harness-tasks--paused-p task)))))
      (harness-tasks--set (plist-get task :id) :paused nil)
      (push (plist-get task :id) ids))
    (when ids
      (harness-log 'info "tasks: resumed %d paused task%s" (length ids) (if (cdr ids) "s" ""))
      (harness-tasks--schedule))
    (list :ids (nreverse ids))))

(harness-defmethod task/update (id prompt &optional attachments)
  "Replace the prompt of pending task ID with PROMPT and its ATTACHMENTS.
ATTACHMENTS are as `task/submit' takes them, pictures sent as data
included.  A task whose write-up stopped can be written by hand this
way; it then waits in the backlog like a refined one.  A task named
from its prompt (not a backlog task, named from the words it was
written up from) is named again from the new one, and its session
drops the title it took so it takes the new one too."
  (let ((task (harness-tasks--get id)))
    (unless (memq (plist-get task :state) '(pending refining))
      (error "Only tasks that have not started can be edited"))
    (when (harness-tasks--turn-p task)
      (error "Task %s is being written up; wait for it or stop it" id))
    (when (harness-string-blank-p prompt) (error "A task needs a prompt"))
    (let* ((before (harness-tasks--naming-text task))
           (view (harness-tasks--set id :prompt (string-trim prompt)
                                     :attachments (harness-tasks--keep-inline-attachments id attachments)
                                     :state 'pending :outcome nil :error nil :duplicate-of nil)))
      (if (equal before (harness-tasks--naming-text view))
          view
        (prog1 (harness-tasks--set id :name nil)
          ;; The session took the title the task is losing; drop it there too.
          (let ((session (harness-tasks--session task)))
            (when (and session (not (harness-string-blank-p (plist-get session :name))))
              (harness-call 'session/update (plist-get session :id) :silent t :name nil)))
          (harness-tasks--name id))))))

(harness-defmethod task/prompt (id text &optional attachments opts)
  "Send TEXT and ATTACHMENTS to the session of task ID: a follow-up, or steering.
OPTS `:from' says who sent the message when the user did not, as
`agent/prompt' takes it: another session's agent
\(`harness-sender-session'), as task_control's message sends it.
Before a backlog task starts, TEXT is feedback on its write-up, which
this sends as such even while the task waits to be started: the
board's [Refine] and its reply box send this way, while a message the
user writes in the task's own session starts the task, stopping a
write-up that is still running (`harness-tasks--on-message').  While
the task waits for review, the user's TEXT sends it back as the
feedback, as `task/reject' does; another session's is no review and
does not (`harness-tasks--on-message').

A task returned to pending is the message's when it starts: while its
queue is suspended, while it waits for a slot with the user's
feedback from review (`harness-tasks--hold-back'), or while something
holds it back -- it is paused, out of quota or over a hard budget
\(`harness-tasks--hold') --, the message is kept on the task and
delivered with the start (`harness-tasks--queue-message'), so it does
not get around the suspension, the limit or the hold; otherwise it
starts the task now, as an explicit `task/start' would, and the message
follows the start's own carry-on."
  (let ((task (harness-tasks--get id))
        (from (let ((f (plist-get opts :from))) (and (harness-sender-kind f) f))))
    ;; Every task has its session from submission; one still waiting for a
    ;; slot has not been given the work, and a message would start it.  A
    ;; task returned to pending is the message's, and is handled below.
    (when (and (eq (plist-get task :state) 'pending)
               (not (harness-tasks--refinement-p task))
               (not (harness-tasks--returned-p task)))
      (error "Task %s is waiting for a slot; task/start starts it" id))
    (when (plist-get task :worktree-removed)
      (error "Task %s was archived and its worktree removed; submit a new task" id))
    (cond
     ((and (harness-tasks--returned-p task)
           (or (harness-tasks--task-suspended-p task)
               (eq (harness-tasks--return-reason task) 'sent-back)
               (harness-tasks--hold task)))
      (harness-log 'info "task %s: keeping the message until it starts again" id)
      (harness-tasks--queue-message id text attachments from))
     ((harness-tasks--returned-p task)
      (harness-tasks--start task)
      (harness-catch (harness-call-async 'agent/prompt
                                         (plist-get task :session)
                                         (harness-tasks--blocks (list :prompt text :attachments attachments))
                                         (and from (list :from from)))
                     (lambda (e) (harness-tasks--fail id e))))
     (t
      (let ((sid (plist-get task :session))
            (blocks (harness-tasks--blocks (list :prompt text :attachments attachments)))
            (opts (and from (list :from from))))
        (when (eq (plist-get (harness-call 'session/get sid) :status) 'inactive)
          (harness-call 'session/resume sid))
        (when (plist-get task :archived) (harness-tasks--set id :archived nil))
        (harness-tasks--set id :merge-attempts 0
                            :recap nil :recap-at nil :recap-turns nil :recap-tools nil)
        (if (harness-tasks--refinement-p task)
            (progn
              ;; A message the board sends a backlog task is feedback on
              ;; its write-up whatever the task waits for
              ;; (`harness-tasks--refine-turn' marks it), and the task is
              ;; writing it up from now.
              (when (and (eq (plist-get task :state) 'pending)
                         (harness-tasks--backlog-p task))
                (harness-tasks--set id :state 'refining :outcome nil :error nil
                                    :duplicate-of nil
                                    :note (or (plist-get task :note) (plist-get task :prompt))))
              (harness-tasks--refine-turn id sid blocks opts))
          (harness-catch (harness-call-async 'agent/prompt sid blocks opts)
                         (lambda (e) (harness-tasks--fail id e)))))))
    t))

(harness-defmethod task/merge (id)
  "Queue task ID's branch for the merge queue again (after a failed merge).
A task in review merges when the user verifies it (`task/verify')."
  (let ((task (harness-tasks--get id)))
    (when (harness-tasks--no-merge-p task)
      (error "Task %s handed in with nothing to merge" id))
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
             (not (harness-tasks--no-merge-p task))
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
may be ATTACHMENTS alone, a screenshot say, but not nothing.  A reply
in a thread among ATTACHMENTS (an attachment with `:thread') is a
comment in a thread of the task's review before the round is kept
\(`harness-tasks--register-threads').  Any message the user sends the
session meanwhile does the same; one from another session's agent does
not (`harness-tasks--on-message').

Sending it back is held to `harness-tasks-max-running' like any start
\(`harness-tasks--make-room'): the task works at once with a slot of its
project free, and with none it takes the slot of a task at work it
outranks -- one of a lower priority, or of its own priority that was
not itself sent back from review -- which is pre-empted
\(`harness-tasks--preempt'): back in the queue, to carry on when the
queue starts it again.  When every task at work outranks it, the limit
is 0 or its project's queue is suspended, the task goes back to the
front of its priority's queue instead, with the feedback kept, and its
session gets it when it starts (`harness-tasks--hold-back'): when a
slot frees, when it comes to outrank a task at work, at
`task/resume-queue', or at an explicit `task/start'.  Return the task."
  (let* ((task (harness-tasks--get id))
         (additions (harness-tasks--feedback-additions task (string-trim (or feedback "")))))
    (unless (eq (plist-get task :state) 'review)
      (error "Task %s is not waiting for review" id))
    (when (and (harness-string-blank-p feedback) (null attachments) (null (car additions)))
      (error "Sending a task back needs feedback"))
    (unless (harness-tasks--session task) (error "Task %s has no session to send the feedback to" id))
    (when (plist-get task :worktree-removed)
      (error "Task %s was archived and its worktree removed; submit a new task" id))
    (let* ((sid (plist-get task :session))
           (feedback (harness-tasks--add-to-feedback feedback additions))
           ;; The replies in threads are comments of the review before the
           ;; round keeps their text.
           (attachments (harness-tasks--register-threads task attachments))
           (blocks (harness-tasks--blocks (list :prompt (string-trim (or feedback ""))
                                                :attachments attachments))))
      (if (not (harness-tasks--make-room task))
          (progn
            (harness-log 'info "task %s: keeping the feedback until it gets a slot" id)
            (harness-tasks--hold-back id (harness-tasks--feedback-text blocks)
                                      (harness-tasks--reject-text (string-trim (or feedback "")))
                                      attachments))
        (when (eq (plist-get (harness-call 'session/get sid) :status) 'inactive)
          (harness-call 'session/resume sid))
        ;; It holds its slot until the turn begins.
        (puthash id t harness-tasks--starting)
        ;; Active before the prompt goes out, so the message is not taken
        ;; for one more sending the task back (`harness-tasks--on-message').
        (harness-tasks--send-back id (harness-tasks--feedback-text blocks))
        (harness-catch (harness-call-async 'agent/prompt sid (harness-tasks--reject-blocks blocks))
                       (lambda (e) (harness-tasks--fail id e))))
      (harness-tasks--commit-additions additions)
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
`:evidence', and, when the session said it cannot finish or the work
needs no merge, `:cannot-continue' or `:no-merge'.  The record is
written and `task/changed' says so; the turn that handed it in then
ends cleanly, which the review step picks up as usual
(`harness-tasks--on-turn-ended')."
  (harness-tasks--get id)               ; signals for an unknown task
  ;; `harness-tasks--set' writes it soon and says `task/changed'.
  (harness-tasks--set id :report report :report-at (float-time) :archived nil
                      :cannot-continue (if (harness-json-true-p (plist-get report :cannot-continue)) t :false)
                      :no-merge (if (harness-json-true-p (plist-get report :no-merge)) t :false)))

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

(harness-defmethod task/archive-done (&optional cwd column)
  "Archive every done task of CWD's project (every project without CWD).
COLUMN, `done' or `cancelled', keeps to that column of the board: the
completed tasks, or the cancelled ones (`harness-tasks--cancelled-p');
without it both are archived.  Return how many were archived."
  (let ((n 0)
        (column (and column (intern (format "%s" column)))))
    (dolist (task (harness-call 'task/list cwd) n)
      (when (and (eq (plist-get task :state) 'done) (not (plist-get task :archived))
                 (or (null column)
                     (eq (eq column 'cancelled) (harness-tasks--cancelled-p task))))
        (harness-call 'task/archive (plist-get task :id))
        (cl-incf n)))))

(harness-defmethod task/cancel (id)
  "Cancel task ID: a pending task is dropped, a working one stops its turn.
A task being written up stops; once it has stopped, cancelling drops it.
A task that never started -- waiting for a slot, or in the backlog --
takes its session with it: it holds the task's priority and nothing
else, and a write-up's transcript goes with the task it was written
up for."
  (let* ((task (harness-tasks--get id))
         (state (plist-get task :state)))
    (if (or (eq state 'pending) (and (eq state 'refining) (not (harness-tasks--turn-p task))))
        (let ((sid (plist-get task :session)))
          (harness-tasks--remove id)
          (harness-tasks--forget-attachments id)
          (when (and sid (harness-call 'session/exists-p sid))
            (harness-call 'session/delete sid))
          nil)
      (when (and (plist-get task :session) (harness-method-exists-p 'agent/cancel))
        (harness-call 'agent/cancel (plist-get task :session)))
      t)))

(harness-defmethod task/delete (id &optional delete-session)
  "Forget task ID; with DELETE-SESSION also cancel and delete its session.
Its worktree, if any, is kept: it may hold work nobody merged.  A task
that never started takes its session with it either way: it holds the
task's priority and nothing else."
  (let* ((task (harness-tasks--get id))
         (sid (plist-get task :session))
         ;; A task waiting for a slot has only its session's priority to lose.
         (delete-session (or delete-session
                             (and (eq (plist-get task :state) 'pending) t
                                  (not (harness-tasks--backlog-p task))))))
    (when (and sid (harness-method-exists-p 'merge/cancel)) (harness-call 'merge/cancel sid))
    (harness-tasks--remove id)
    ;; The session's transcript names the files of a task's attachments:
    ;; they stay unless it goes too.
    (when delete-session (harness-tasks--forget-attachments id))
    (when (and delete-session sid (harness-call 'session/exists-p sid))
      (when (harness-method-exists-p 'agent/cancel) (harness-call 'agent/cancel sid))
      (harness-call 'session/delete sid))
    t))

;;;; Redaction
;;
;; The records are redacted in the table and written again at once: a
;; store is a function of the records, so none keeps a copy of what was
;; taken out of them.  What no save writes again is redacted as a file,
;; which is the one copy of the global store kept from before records
;; moved into their repositories (`harness-tasks--backup-suffix').

(defun harness-tasks--redaction-fields (old new)
  "Return the keys of the record NEW whose values are not those of OLD.
NEW is OLD as `harness-redaction-value' returned it, which shares with
OLD what it did not change: the values that are not `eq' are the ones it
replaced."
  (cl-loop for (key value) on new by #'cddr
           unless (eq value (plist-get old key))
           collect key))

(defun harness-tasks--redact-records (secrets root)
  "Return what redacting SECRETS in the task records of project ROOT would change.
Every project's records when ROOT is nil.  The value lists, for each task
that holds a secret, oldest first, a plist of `:id', `:count' (how many
occurrences), `:fields' (the keys of the record that hold them) and
`:record' (the record redacted).  Nothing is changed here."
  (let (found)
    (dolist (task (harness-tasks--sorted
                   (lambda (task) (or (null root) (equal root (plist-get task :project))))))
      (let* ((id (plist-get task :id))
             ;; The error of a failed walk could print the record, secret and all.
             (result (condition-case err
                         (harness-redaction-value task secrets)
                       (error (signal 'harness-error
                                      (list (format "Task %s could not be searched for the secret (%s)"
                                                    id (car err))))))))
        (when (> (cdr result) 0)
          (push (list :id id :count (cdr result)
                      :fields (harness-tasks--redaction-fields task (car result))
                      :record (car result))
                found))))
    (nreverse found)))

(defun harness-tasks--redact-backup (secrets dry-run)
  "Redact SECRETS in the copy of the global store kept from before the move.
That is tasks.json.bak (`harness-tasks--backup-global'), a file no save
writes again, redacted whole as JSON, with DRY-RUN only counted.  Return
its (:file FILE :count N) when it held a secret, else nil."
  (let ((backup (concat (harness-tasks--global-store) harness-tasks--backup-suffix)))
    (when (file-regular-p backup)
      (let ((result (harness-redaction-file backup secrets :style 'json :dry-run dry-run)))
        (when (> (plist-get result :count) 0)
          (list :file backup :count (plist-get result :count)))))))

(defun harness-tasks--store-counts (secrets)
  "Return how many times SECRETS occur in each task store file.
These are the global store and the repository stores this process has
opened, as plists of `:file' and `:count' (nil when the file cannot be
read); a store of another harness, which this one may not write, is
marked `:foreign' t.  The needles are looked for as bytes in the file,
the JSON escapes of a secret included."
  (let ((stores nil))
    (maphash (lambda (path state) (push (cons path (eq state 'mine)) stores))
             harness-tasks--stores)
    (cl-loop for (path . mine) in (cons (cons (harness-tasks--global-store) t)
                                        (sort stores (lambda (a b) (string< (car a) (car b)))))
             when (file-regular-p path)
             collect (append (list :file path
                                   :count (condition-case nil
                                              (harness-redaction-file-count path secrets)
                                            (error nil)))
                             (and (not mine) (list :foreign t))))))

(harness-defmethod task/redact (secrets &optional project dry-run)
  "Take SECRETS out of the task records and the files that keep them.
SECRETS are secrets as harness-redaction.el has them, plists of `:value',
`:label' and `:fingerprint', held in memory only: nothing here logs,
emits or returns a value, and an error says nothing of one.  Every
string of every task record is searched, whichever field holds it --
the prompt, the title, the report handed in with its evidence, the
rounds of feedback, errors, recaps.  PROJECT, a directory taken as
`task/list' takes its CWD, limits it to the tasks of that project;
nil (or false) is every task.  No task is stopped, restarted or
deleted, and no session is touched.

Unless DRY-RUN the changed records are put back, every store is written
again from them at once (not the write a change schedules for later),
and `task/changed' is emitted for each task that held a secret.  The
copy of the global store kept from before records moved into their
repositories, tasks.json.bak, is a file nothing writes again: it is
redacted whole, as JSON, whichever project is asked for.  With DRY-RUN
it only counts, and nothing changes.

Return (:count N :tasks TASKS :files FILES :stores STORES).  TASKS holds
a plist (:id ID :count N :fields KEYS) for each task that held a secret,
oldest first: N occurrences, in the fields KEYS (keywords) of its
record.  FILES holds (:file FILE :count N) for the backup copy when it
held one.  N, the COUNT, is the total of the counts of TASKS and FILES:
the occurrences redacted, or in a dry run found.  STORES says what is
left: for each store file the tasks are kept in -- the global store and
the repository stores this harness has opened -- (:file FILE :count N),
the occurrences it holds when the call returns, which is 0 after a
redaction but for the tasks of other projects when PROJECT limited it.
A store of another harness, which this one may not write, is counted
too and marked `:foreign' t.  Values, snippets and the names of tasks
are never returned."
  ;; Before anything touches them: an error that names a malformed
  ;; secret would print it.
  (unless (and (proper-list-p secrets)
               (cl-every (lambda (secret)
                           (and (proper-list-p secret) (stringp (plist-get secret :value))))
                         secrets))
    (signal 'harness-error (list "SECRETS must be a list of secrets, each a plist with a :value string")))
  (harness-tasks--load)
  (let* ((root (cond ((memq project '(nil :false :null)) nil)
                     ((and (stringp project) (not (string-blank-p project)))
                      (harness-tasks--project project))
                     (t (signal 'harness-error (list "PROJECT must be the name of a directory")))))
         (dry-run (harness-json-true-p dry-run))
         (found (progn (when root (harness-tasks--open-project root))
                       (harness-tasks--redact-records secrets root)))
         (files nil))
    (unless dry-run
      ;; Put back, then written at once: nothing keeps the old text.
      (dolist (entry found)
        (let ((id (plist-get entry :id)))
          (puthash id (plist-get entry :record) harness-tasks--table)
          ;; The text a title request is out for is a copy of the prompt.
          ;; Its answer is dropped, and the task named again, as for any
          ;; prompt that changed meanwhile (`harness-tasks--named').
          (when-let* ((text (gethash id harness-tasks--naming))
                      ((stringp text)))
            (puthash id (car (harness-redaction-string text secrets)) harness-tasks--naming))))
      ;; So a save that fails is tried again, the records being changed.
      (harness-tasks--save-soon)
      (unwind-protect (harness-tasks--save)
        (dolist (entry found)
          (when-let* ((task (gethash (plist-get entry :id) harness-tasks--table)))
            (harness-emit 'task/changed (harness-tasks--view task))))))
    ;; After the save, which may have copied the global store aside.
    (when-let* ((backup (harness-tasks--redact-backup secrets dry-run)))
      (push backup files))
    (let ((tasks (mapcar (lambda (entry) (harness-plist-remove entry :record)) found)))
      (when (and (not dry-run) (or tasks files))
        (harness-log 'info "tasks: took a secret out of %d task record%s and %d file%s"
                     (length tasks) (if (cdr tasks) "s" "") (length files) (if (cdr files) "s" "")))
      (list :count (+ (apply #'+ (mapcar (lambda (entry) (plist-get entry :count)) tasks))
                      (apply #'+ (mapcar (lambda (entry) (plist-get entry :count)) files)))
            :tasks tasks
            :files files
            :stores (harness-tasks--store-counts secrets)))))

;;;; Module

(defun harness-tasks--init ()
  "Load the records, follow sessions and merges, then get work going.
Once every module is up, work a stopped harness interrupted is picked
up again, merges in flight are queued again and waiting tasks start.
A reload follows what the new code follows and names the tasks without
a title, but picks nothing up: the work under way then is this
process's own, and goes on."
  (harness-tasks--load)
  (add-hook 'kill-emacs-hook #'harness-tasks-flush)
  (harness-on 'agent/turn-started #'harness-tasks--on-turn-started)
  (harness-on 'agent/turn-ended #'harness-tasks--on-turn-ended)
  (harness-on 'agent/tool-call #'harness-tasks--on-tool-call)
  (harness-on 'session/deleted #'harness-tasks--on-session-deleted)
  (harness-on 'session/pending-changed #'harness-tasks--on-pending-changed)
  (harness-on 'session/status #'harness-tasks--on-session-status)
  (harness-on 'merge/started #'harness-tasks--on-merge-started)
  (harness-on 'merge/conflict #'harness-tasks--on-merge-conflict)
  (harness-on 'merge/finished #'harness-tasks--on-merge-finished)
  (harness-on 'config/changed #'harness-tasks--on-config-changed)
  (harness-on 'session/ext-changed #'harness-tasks--on-priority-changed)
  ;; What ends a hold for quota or a budget: a mark that ended or was
  ;; cleared, a quota report, a budget raised, removed or made soft.
  (harness-on 'fallback/changed #'harness-tasks--on-hold-event)
  (harness-on 'usage/budgets-changed #'harness-tasks--on-hold-event)
  (harness-add-filter 'worktree/lock-existing-p #'harness-tasks--lock-existing-p)
  (harness-add-filter 'agent/system-prompt #'harness-tasks--system-prompt 60)
  (harness-add-filter 'agent/system-prompt #'harness-tasks--btw-system-prompt 60)
  (harness-add-filter 'naming/system-prompt #'harness-tasks--naming-prompt 60)
  (harness-add-filter 'naming/auto-p #'harness-tasks--auto-name-p)
  (harness-add-filter 'permission/decide #'harness-tasks--write-up-gate 25)
  (harness-tasks--hook-write-ups)
  (harness-add-filter 'agent/message #'harness-tasks--on-message)
  ;; First of the gates: a turn it refuses needs no compaction or fallback.
  (harness-add-filter 'agent/before-turn #'harness-tasks--before-turn 2)
  (harness-add-filter 'session/before-move #'harness-tasks--before-move)
  (harness-run-soon #'harness-tasks--arm-lend-timers)
  (if (harness-module-ready-p 'tasks)
      (harness-run-soon #'harness-tasks--name-untitled)
    (harness-tasks--pick-up)))

(defun harness-tasks--hook-write-ups ()
  "Hold write-ups and plans read-only, and plans to handing themselves in.
The read-only policy goes to the readonly module
\(`harness-tasks--readonly-policy'), the tool filter offers the plan's
own tool to planning sessions alone, and the stop rule sends a planning
turn that stopped without a plan back (`harness-tasks--plan-stop')."
  (harness-readonly-register 'tasks #'harness-tasks--readonly-policy)
  (harness-add-filter 'agent/tools #'harness-tasks--tools 50)
  (harness-add-filter 'agent/stop #'harness-tasks--plan-stop))

(defun harness-tasks--shutdown ()
  "Write what waits to be written, stop holding write-ups read-only, and drop the timers of blocked tasks."
  (harness-readonly-unregister 'tasks)
  (harness-remove-filter 'agent/tools #'harness-tasks--tools)
  (harness-remove-filter 'agent/stop #'harness-tasks--plan-stop)
  (maphash (lambda (_ timer) (cancel-timer timer)) harness-tasks--lend-timers)
  (clrhash harness-tasks--lend-timers)
  (when (timerp harness-tasks--hold-timer) (cancel-timer harness-tasks--hold-timer))
  (setq harness-tasks--hold-timer nil)
  (harness-tasks-flush))

(harness-declare-event 'task/changed "(TASK) after a task is submitted or changes state or column.")
(harness-declare-event 'task/deleted "(ID) after a task is removed.")
(harness-declare-event 'task/review "(TASK) when a task's finished work starts waiting for the user's review.")
(harness-declare-event 'task/done "(TASK HOW) when a task becomes done; HOW is merged, finished, verified or completed.")
(harness-declare-event 'task/backlog-mode "(PROJECT MODE) when a project's backlog mode changes: manual or auto.")
(harness-declare-event 'task/queue "(PROJECT SUSPENDED) when a project's pending queue is suspended or resumed.")

(harness-define-module 'tasks
  :doc "Task mode: one session per task, through review and the merge queue, with a limit of tasks at once per project, started by priority."
  :requires '(store project session agent)
  :init #'harness-tasks--init
  :shutdown #'harness-tasks--shutdown)

(provide 'harness-tasks)
;;; harness-tasks.el ends here
