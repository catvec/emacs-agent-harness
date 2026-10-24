;;; harness-ui-tasks.el --- Task mode: a kanban of one-session tasks  -*- lexical-binding: t; -*-

;;; Commentary:

;; Task mode manages sessions by the task each one completes (see the
;; `tasks' module).  Its buffer is a small kanban for the current
;; project, one section per column, most urgent first:
;;
;;   Requires your input   blocked on a permission or question, stopped,
;;                         or refused by its write-up as a duplicate:
;;                         drop it, or have it written up all the same
;;   Ready for review      finished, waiting for you: verify it (v), which
;;                         merges it, or send it back with feedback (R)
;;   Merging               in the merge queue, in the order it takes them:
;;                         queued, merging, or resolving the conflicts
;;   In progress           working, with its current todo and progress
;;   Pending               waiting for a slot, so it starts on its own
;;                         while the project has one free; editable,
;;                         startable; in the order they start: by
;;                         priority, and within one, work sent back
;;                         from review, then tasks returned to pending
;;                         (paused or pre-empted), then the oldest.
;;                         Beside its count, [Queue: running] (P)
;;                         suspends the queue, so none starts on its own
;;                         until resumed.  A card says what holds its
;;                         task back: paused (u), out of quota or over a
;;                         hard budget, and when that ends
;;   Backlog               jotted down or written up for later: the queue
;;                         never starts one by itself; Q queues it, so it
;;                         drains like any pending task, and s starts it
;;                         now; editable, refinable; where a write-up
;;                         runs too.  Beside its count, [Manual queue] /
;;                         [Auto queue] (W) says whether a finished
;;                         write-up waits here or joins the queue itself
;;   Completed             finished and verified; reply to reopen,
;;                         archive to hide
;;
;; and a compose box at the bottom: describe a task, C-c C-c submits it
;; and it gets a session of its own.  A toggle above the box (C-c C-t)
;; cycles through three modes.  Submit starts the task.  Refine (backlog
;; refinement, once called grooming) has an agent write the task up and
;; leaves it in the Backlog until you start it: jot things down now,
;; pick them up later, even after a restart.  With the Backlog's auto
;; queue (W, or a click on its heading's [Manual queue]) a finished
;; write-up joins the queue by itself instead, which starts it as slots
;; free; the project keeps the choice across restarts.  Plan has a strong model
;; (the hard tier of the task model's provider: Opus for Claude) read the
;; code and plan the task, read-only, for a cheaper one (the medium
;; tier, Sonnet) to carry out once you start it.  The lines above the
;; box are the current mode's alone.  A step of a task has a model and a
;; thinking level of its own and nothing else: in Refine and Plan a line
;; per step -- the write-up or the plan, then the work, which in Plan
;; runs on the model the plan is for -- holds those two, each a button
;; that changes it.  What the whole task works with -- its permission
;; mode, whether it is interactive, supervisor mode, where it works --
;; is on one line below them, in every mode; in Submit, where the work is
;; the whole task, that line starts with the work's model and thinking
;; level.  Plan has no supervisor switch: a planned task works hands-on,
;; its plan made already, while the work of Submit and Refine may
;; supervise.  The same box edits a
;; pending task (e), replies to a task's session (m) -- for a backlog
;; task that is feedback on its write-up (r) -- without leaving the
;; board, answers a task's question (m or [Answer]) and takes the
;; feedback that sends a task back from review (R, or m: any message you
;; send a task in review sends it back); C-g leaves such a box for a new task
;; again, the question still waiting.
;; RET or a click on a task opens its session in full.  F gives the board
;; the fullscreen layout: the board stays on the left of the frame and
;; the sessions it opens show beside it, until q on the board ends it
;; (`harness-fullscreen').  The board's letters type in the box, so
;; C-c . and a letter (C-c . F) presses a board key from there
;; (`harness-compose-panel-key'; the keys for a task act on a card, which
;; the box has none of).  @ on a card attaches its task to the box: the
;; message tells the model what the task is, and @task:ID goes into the
;; text (`harness-compose-attach-task').
;; b or [BTW] asks about the tasks in a BTW side conversation over the
;; board, whose agent answers with the task and
;; session tools (`task/btw').  / or [Search] turns the compose box into
;; a search box, in colours of its own: a line in words there, which a
;; cheap model reads with the board, finds tasks, sessions and commands,
;; or acts on tasks; the board then shows only the tasks it is about,
;; and the sessions and commands it found above them
;; (harness-ui-tasks-search.el, through `harness-ui-tasks-filter').
;;
;; A backlog task's own session shows a banner above its compose box:
;; that it waits in the Backlog, or is being written up, with the card's
;; [Start now] and, while it waits, [Queue it].  A message typed in that
;; session starts the task, whether it waits or its write-up still runs,
;; which the message stops; feedback on the write-up is the board's
;; [Refine].  [Start now] supersedes a write-up that runs the same way:
;; it stops it and starts the task with the write-up it has when the
;; turn has ended.
;;
;; Priority: a task is low, medium (the default) or high priority, and
;; that priority is its session's -- every task has its session from
;; submission, holding the level, so the board and the queues the
;; task's work waits in serve it by the same thing.  While the project's
;; slots are full (`harness-tasks-max-running'), a higher priority starts
;; first; among equals, work sent back from review, then a task returned
;; to pending, then the oldest.  A card's arrow -- the priority
;; UI's, clickable like the chat header's
;; (`harness-ui-priority-arrow') -- says what it is: up for high, down
;; for low, none for medium, and no words repeat it among the card's
;; facts.  + and - on a card raise and lower it (the change goes to the
;; task's session), and the button beside the Submit / Refine / Plan toggle
;; sets the next task's.  To give many tasks a priority, or any other
;; setting, at once, mark their sessions in the session list
;; (`harness-sessions'): its keys and the harness's setting commands act
;; on every marked session, and on the tasks they work on.
;;
;; Pausing: u, or a card's [Pause], pauses the task at point.  A task at
;; work has its turn stopped and goes back to Pending, a task waiting
;; there stays; either is held, however many slots are free, until U, or
;; [Resume], lets the queue have it, and s starts it at once.  A pause
;; is kept across a restart, and is not the queue's: P suspends every
;; waiting task of the project, a pause one.  A task whose turn stopped
;; because every provider it could run on was out of quota, or a hard
;; budget was spent, waits in Pending too, its card saying which and
;; when it ends (the hold, `harness-ui-tasks--hold-text'); the queue
;; starts it again once that is over, with nothing for you to do.
;; Pausing every task, and every queue, is the task slots page's (S).
;;
;; Review can be turned off (V, or `harness-tasks-require-verification'
;; on the settings page): finished tasks then merge and complete by
;; themselves, and Ready for review shows only while tasks from before
;; still wait there.  It is a harness option, so it holds for every
;; board and across restarts.
;;
;; The mode line notifier (harness-ui-notify.el) counts the tasks ready
;; for your review, of every project, beside the sessions it counts:
;; Ready for review's flag and how many wait there, open board or not.
;; Hovering says how many each project has.  A click
;; (`harness-tasks-review') opens the board of the current project when
;; it has some, else of the project whose task came to review last, with
;; point on the card of the last to come.
;;
;; How many of a project's tasks work at once ends the settings line
;; under New task: "3 at a time", or "all at once" without a limit, in
;; every mode -- a write-up or a plan takes no slot, but the work it
;; leads to does once it starts.  A
;; click on it asks for another limit (`harness-ui-tasks-set-max-running'):
;; the harness option `harness-tasks-max-running', saved like the Review
;; switch, so every project has that many slots.  A higher limit starts
;; waiting tasks at once; a lower one stops none at work.  S opens the
;; project's task slots page (`harness-ui-tasks-slots', which runs
;; `harness-slots' of harness-ui-slots.el): the tasks at work, listed as
;; the session list lists sessions, the queue by priority and how long
;; tasks waited for a slot.
;;
;; The header line holds what the board does not show -- each column's
;; heading counts its own tasks.  As a chat's header does for its
;; session, it says what the tasks cost and who pays: their summed cost,
;; or the plan that pays for them with its quota windows, then the
;; fullest budget that applies to the project.  A click there opens the
;; usage dashboard.  Its buttons follow: [Search], [BTW], [Add session],
;; [Archived] and [Refresh].
;;
;; What a card says: its title first.  The line states little besides --
;; the arrow of a high or low priority, state worth a flag (archived,
;; main tree, a borrowed slot, a merge in conflict), when (how long a task
;; waited or has worked) and how many of its todos are done -- and the
;; title is never cut to make room for any of it unless it is longer than
;; the window.  A card short of room gives up the todo count first, then
;; the time; failing that its facts and buttons go together to a second
;; line under the title, in the same columns
;; (`harness-ui-tasks--plan').  What its session has to say -- the
;; context in use, the tokens written, how fast and what they cost --
;; is in the tooltip of the title, made when you hover
;; (`harness-ui-tasks--title-help'), so the board is not drawn again for
;; figures that change with every model call.
;;
;; Looking at a task's files.  Its worktree is a directory below the
;; project, and a project's commands -- `project-find-file',
;; `project-dired', projectile's -- work on the project, not on that.  w on
;; a card, or Assume worktree in its menu, assumes the task's worktree as
;; the project (the worktree-assume library, lisp/vendor/worktree-assume):
;; from any buffer of the project those commands then work on the
;; worktree, until w again, or Reset to main worktree, makes the project its main
;; checkout again.  The board, the session list and the rest of the
;; harness go on finding the project itself, so the task stays there to be
;; answered.  The mode line says while a worktree is assumed.
;;
;; Everything comes over ACP (`_harness/task/…', `_harness/config/set'
;; for turning review off and the limit, `_harness/usage/project-budgets' for the
;; header's budgets, plus the session cache), so the board works
;; against a remote harness too.  The list region is
;; redrawn as a whole when anything changes -- a board holds tens of
;; tasks, not a transcript -- while the compose box is never touched.
;; A board taller than its window holds its least urgent cards back, a
;; fitting found by measuring the cards once and then kept while only
;; what the cards read changes, so a busy board of many tasks redraws
;; the cards its window shows, not all of them.  A section that
;; [Show all] opened keeps its [Show fewer] only while folding it would
;; hold cards back: once its list shrinks to fit the window, the
;; expansion is forgotten and the line goes.  Point and every window
;; showing the board stay where they were through it all: on the same
;; line of the same card, on the same button.  A click on a button
;; pushes it, however long the click takes.
;;
;; A button of the board that was pushed is held down at once -- dim and
;; sunk (`harness-task-button-pressed-face') -- and stays so until the
;; harness has answered what its command asked for, or failed to: the
;; command goes over ACP, and the card only changes when the event it
;; causes comes back.  No sooner than 0.3 seconds after the push, so a
;; command that asks for nothing is acknowledged too, and no later than
;; 15, so an answer that never comes cannot leave it stuck; a second push
;; meanwhile does nothing but say so.  The key of a command typed on a
;; card holds that card's button for it down the same way
;; (`harness-ui-tasks--press').  The lines above the compose box have
;; none of this: they open prompts or flip a setting at once.  Nor has
;; the chevron that folds a card's recap, which only draws the card again.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'text-property-search)
(require 'button)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)
(require 'harness-ui)
(require 'harness-ui-compose)
(require 'harness-ui-pending)
(require 'harness-ui-priority)

;; worktree-assume is in lisp/vendor/worktree-assume, which the harness
;; puts on `load-path' (`harness--setup-load-path').  A harness older than
;; that directory, reloading after an update, first checks that this file
;; compiles with the `load-path' it has, before it loads the harness.el
;; that adds the directory.  So when the library is not found, look for it
;; beside the file being compiled or loaded.
(defvar byte-compile-current-file)
(eval-and-compile
  (unless (or (featurep 'worktree-assume) (locate-library "worktree-assume"))
    (when-let* ((file (or (and (boundp 'byte-compile-current-file)
                               (stringp byte-compile-current-file)
                               byte-compile-current-file)
                          load-file-name
                          buffer-file-name))
                (dir (expand-file-name "../vendor/worktree-assume/" (file-name-directory file)))
                ((file-directory-p dir)))
      (add-to-list 'load-path dir))))
(require 'worktree-assume)

(defgroup harness-ui-tasks nil
  "Task mode." :group 'harness-ui)


(defconst harness-ui-tasks--tick-interval 15
  "Seconds between refreshes of the elapsed times on visible boards.")

(defcustom harness-ui-tasks-refine-by-default nil
  "The mode new boards open in: Submit, Refine or Plan.
Nil submits new tasks, which start at once; t refines them, an agent
writing each one up for the Backlog; `plan' has a strong model plan
each one for the Backlog, for a cheaper model to carry out.  Whichever
it is, the toggle above the compose box switches it per board."
  :type '(choice (const :tag "Submit" nil) (const :tag "Refine" t) (const :tag "Plan" plan))
  :group 'harness-ui-tasks)

(defconst harness-ui-tasks--notify-review t
  "When non-nil, say in the echo area when a task waits for your review.")

(defface harness-task-title-face '((t :inherit bold))
  "Task titles." :group 'harness-ui-tasks)
(defface harness-task-section-face '((t :inherit (harness-label-face) :height 1.05))
  "Column headings." :group 'harness-ui-tasks)
(defface harness-task-attention-face '((t :inherit harness-status-blocked-face))
  "Why a task needs the user." :group 'harness-ui-tasks)
(defface harness-task-done-face '((t :inherit success))
  "The completed mark." :group 'harness-ui-tasks)
(defface harness-task-review-face '((t :inherit success :weight bold))
  "Tasks waiting for your review: their mark, heading and count." :group 'harness-ui-tasks)
(defface harness-chat-backlog-face
  '((((background light)) :background "#eef1f8" :extend t)
    (((background dark)) :background "#202534" :extend t))
  "Background of a backlog task's banner in its session: the board's Backlog."
  :group 'harness-ui-tasks)
(defface harness-task-merging-face '((t :inherit harness-dim-face))
  "The mark of a task waiting in the merge queue." :group 'harness-ui-tasks)
(defface harness-task-choice-face '((t :inherit bold))
  "The Submit / Refine / Plan toggle, which shows the current mode." :group 'harness-ui-tasks)
(defface harness-task-priority-high-face '((t :inherit warning))
  "A button that says high priority: the compose box's."
  :group 'harness-ui-tasks)
(defface harness-task-priority-low-face '((t :inherit harness-dim-face :slant italic))
  "A button that says low priority: the compose box's."
  :group 'harness-ui-tasks)
(defface harness-task-button-pressed-face
  '((((type graphic) (background light))
     :foreground "grey35" :background "grey85"
     :box (:line-width (-1 . -1) :style pressed-button))
    (((type graphic) (background dark))
     :foreground "grey75" :background "grey30"
     :box (:line-width (-1 . -1) :style pressed-button))
    (t :inherit shadow :inverse-video t))
  "A button of the board that was pushed and waits for the harness's answer.
It reads as held down: dim grey text in a slot of its own, sunk, in a
graphic frame -- no underline, as it takes no click.  The box is drawn
inside the glyphs (a negative line width), so the button keeps its width
and its line its height.  The colours are greys that show on a light and
on a dark theme alike."
  :group 'harness-ui-tasks)
(defface harness-task-search-box-face
  '((((background light)) :background "#e6effb" :extend t)
    (((background dark)) :background "#1f2a3b" :extend t))
  "The compose box while it takes the board's search.
A colour of its own, as a message's box has, so a search cannot be
taken for a new task." :group 'harness-ui-tasks)
(defface harness-task-search-box-accent-face '((t :inherit link :underline nil))
  "The prompt, bar and icon of the compose box while it takes the board's search.
The blue of links, without their underline." :group 'harness-ui-tasks)

(define-icon harness-icon-task-pending nil
  '((symbol "◌") (text "wait"))
  "Pending task." :version "29.1")
(define-icon harness-icon-task-backlog nil
  '((symbol "▤") (text "backlog"))
  "Backlog task: waiting for you to start it." :version "29.1")
(define-icon harness-icon-task-done nil
  '((symbol "✓") (text "done"))
  "Completed task." :version "29.1")
(define-icon harness-icon-task-stopped nil
  '((symbol "■") (text "stop"))
  "Stopped task." :version "29.1")
(define-icon harness-icon-task-paused nil
  `((symbol ,(string #x23f8)) (text "pause"))
  "Task waiting while its project's queue is suspended: a pause bar." :version "29.1")
(define-icon harness-icon-task-review nil
  `((symbol ,(string #x2691)) (text "review"))
  "Task waiting for your review: a flag." :version "29.1")
(define-icon harness-icon-task-merging nil
  `((symbol ,(string #x21a3)) (text "merge"))
  "Task in the merge queue: an arrow feeding into a line." :version "29.1")
(harness-ui-define-icon harness-icon-message "message" "→" "msg"
  "A message to the session of an existing task.")
(harness-ui-define-icon harness-icon-task-plan "plan" "≡" "plan"
  "Plan mode: a strong model plans the task for a cheaper one.")
;; A priority's arrows are the priority UI's (`harness-ui-priority-arrow'),
;; so a card, a header line and a list row show the same one.

(defconst harness-ui-tasks--columns
  '((needs-input "Requires your input" t) (review "Ready for review") (merging "Merging")
    (active "In progress") (pending "Pending") (backlog "Backlog") (done "Completed"))
  "Columns in display order: (COLUMN HEADING &optional SUBTITLE-SHOWN).
SUBTITLE-SHOWN is non-nil when the cards of the column show their
recap subtitle by default; elsewhere a card is one line until you
show it (see `harness-ui-tasks-toggle-subtitle').")

;;;; Buffer state

(defvar harness-ui-tasks-board-map)
(defvar harness-ui-btw-start-function)
(defvar harness-ui-btw-about)
(defvar harness-chat-panel-functions)
(defvar harness-chat-placeholder)

(declare-function harness-btw "harness-ui-btw")
(declare-function harness-ui-popout-at-point "harness-ui-popout")
(declare-function harness-ui-popout-try-at-point "harness-ui-popout")
(declare-function harness-toggle-supervisor "harness-ui-supervisor")
;; The task slots page, which requires this file: S on a board opens it
;; (`harness-ui-tasks-slots').
(declare-function harness-slots "harness-ui-slots" (&optional dir))
(declare-function harness-ui-tasks-search-submit "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search-leave "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search-end "harness-ui-tasks-search")
(declare-function harness-ui-tasks-search-proposal-text "harness-ui-tasks-search")

(defmacro harness-ui-tasks--with-task (id &rest body)
  "Run BODY with point on task ID's card.
Point already on the card stays where it is: on the button pushed, say,
rather than going up to the card's first line."
  (declare (indent 1))
  (let ((key (make-symbol "id")))
    `(let ((,key ,id))
       (unless (equal (get-text-property (point) 'harness-task-id) ,key)
         (let ((match (save-excursion (goto-char (point-min))
                                      (text-property-search-forward 'harness-task-id ,key #'equal))))
           (when match (goto-char (prop-match-beginning match)))))
       ,@body)))


(defvar-local harness-ui-tasks--dir nil "Directory the board was opened for.")
(defvar-local harness-ui-tasks--project nil "Project root reported by the harness.")
(defvar-local harness-ui-tasks--tasks nil "Task plists (wire shape).")
(defvar-local harness-ui-tasks--settings nil "What `task/settings' returned.")
(defvar-local harness-ui-tasks--new nil
  "Settings the next submitted task starts with.
A plist of `:model', `:thinking', `:permission-mode', `:non-interactive'
and, when the harness has the supervisor module, `:supervisor', seeded
from the harness's task defaults and changed with the usual session
commands.  The model and thinking level of the other steps are there
too, seeded the same way: `:refine-model' and `:refine-thinking' write
a task up in Refine, `:plan-model' and `:plan-thinking' plan it in
Plan, and `:plan-work-model' and `:plan-work-thinking' do a planned
task's work (see `harness-ui-tasks--step-keys').")
(defvar-local harness-ui-tasks--loading t)
(defvar-local harness-ui-tasks--error nil "Last failure, shown above the compose box.")
(defvar-local harness-ui-tasks--show-archived nil)
(defvar-local harness-ui-tasks--folded nil "Columns whose section is folded.")
(defvar-local harness-ui-tasks--subtitles nil
  "Alist of task id -> whether your choice shows its recap subtitle.
Only cards you toggled are in it; the rest follow their column
\(see `harness-ui-tasks--columns').")
(defvar-local harness-ui-tasks--expanded nil
  "Columns whose section shows every task, whatever the window holds.
The board fits its window by capping the least urgent sections; a
section opened with its \"… N more  [Show all]\" line is left whole,
and has a [Show fewer] line to fold it back.  It stays open only as
long as the window would hold some of its cards back otherwise: when
its list shrinks to fit, the expansion is forgotten, and its
[Show fewer] with it (`harness-ui-tasks--moot-expansions').")
(defvar-local harness-ui-tasks--submitting nil "Prompts sent but not yet acknowledged.")
(defvar-local harness-ui-tasks--target nil
  "What the compose box does: nil for a new task, else (KIND . ID).
KIND is edit, reply, answer, refine (feedback on a backlog task's
write-up) or reject (feedback that sends a task back from review).
\(search), with no ID, is the board's search: the box takes a line to
find tasks, sessions and commands with, or to act on tasks
\(`harness-tasks-search').")
(defvar-local harness-ui-tasks--mode 'submit
  "What the compose box does with a new task: `submit', `refine' or `plan'.
Submit starts it.  Refine has an agent write it up, and Plan has a
strong model plan it for a cheaper one; either way it then waits in
the Backlog until you start it.  See `harness-ui-tasks--modes'.")
(defvar harness-ui-tasks--step nil
  "The step of a new task whose settings the setting commands change.
Nil is the work's (`harness-ui-tasks--work-step' then says which);
`refine' or `plan' the step before it, which the buttons of its line
bind while their command runs.  See `harness-ui-tasks--step-keys'.")
(defvar-local harness-ui-tasks--main-tree-mode nil
  "How the main-tree choice holds: nil, `once' or `sticky'.")
(defvar-local harness-ui-tasks--priority-mode nil
  "How the priority choice holds: nil, `once' or `sticky'.")
(defvar-local harness-ui-tasks--list-end nil "Marker: end of the board, start of the tail.")
(defvar-local harness-ui-tasks--budgets nil
  "Status of every budget that applies to the project, for the header.
What `_harness/usage/project-budgets' returned; nil without the usage module.")

(defvar-local harness-ui-tasks-filter nil
  "When non-nil, the board shows some of its tasks only, and says so.
A plist: `:show', a function of a task, non-nil for those shown --
archived ones too, whatever [Archived] says; `:banner', a function
returning the text drawn above the columns, whole lines; `:clear', a
function that drops the filter, which \\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-compose-quit] on the board calls (see
`harness-ui-tasks-compose-quit').  The columns without a task to show
are left out.  The board's search sets it (`harness-ui-tasks-search').")

(defvar harness-ui-tasks-header-functions nil
  "Functions returning a segment of a board's header line, or nil.
Each is called in the board's buffer as the header line is drawn; the
segments show before [BTW], in order, the board putting the separator
in front.  A string joins the others into one segment, which makes room
in a narrow window after the counts and before [BTW]; (TEXT PRIORITY
MIN), as `harness-ui-fit-header' takes it, is a segment of its own with
that priority.  The search shows its [Search] the first way, the
companion pet its face the second.")

(defvar harness-ui-tasks-corner-functions nil
  "Functions drawing something at the right of the lines above the compose box.
The lines between the board and the box -- the error, the compose
label and the settings -- narrow for it, as Claude Code's prompt
narrows for its companion, rather than the board giving it lines of
its own.  Each function is called in the board's buffer
whenever those lines are drawn -- with the box, and as a window showing
the board changes size -- with ROOM, the columns the lines have, and
WIDTHS, the columns each of them takes whole, top first; the first to
return non-nil draws, and it returns a plist:

- `:beside', the strings ending the first lines, top first, each
  starting with the space that aligns it to the window's edge;
- `:reserve', the columns the lines `:beside' ends leave free for it;
- `:above', whole lines, a string ending in a newline, going above all
  the lines: what does not fit beside them.

The lines stay together, above the box they are about.  The board fits
its cards to the room they leave, and
`harness-ui-tasks-redraw-tail-lines' draws them again when a function
would draw something else.  The companion pet sits there this way.")

(defun harness-ui-tasks--board-p (buffer)
  "Non-nil when BUFFER is a live task board.
Window hooks and timers hand over whatever buffer a window shows by the
time they run -- a session that replaced the board, say -- so every way
into the board's drawing and loading checks this first."
  (and (buffer-live-p buffer) (eq (buffer-local-value 'major-mode buffer) 'harness-ui-tasks-mode)))

(defun harness-ui-tasks--buffers ()
  "Return every live board buffer."
  (cl-remove-if-not #'harness-ui-tasks--board-p (buffer-list)))

(defun harness-ui-tasks--find (id)
  "Return task ID of this board."
  (cl-find id harness-ui-tasks--tasks :key (lambda (task) (plist-get task :id)) :test #'equal))

(defun harness-ui-tasks--merge-queue-p (task)
  "Non-nil when TASK holds a place in the merge queue.
That is queued, merging, or its session resolving the merge's conflicts;
the task record says so through `:merge-status' as soon as it changes."
  (and (plist-get task :merge-status) t))

(defun harness-ui-tasks--merge-queued (task)
  "When TASK joined the merge queue, else 0."
  (or (plist-get task :merge-queued) 0))

(defun harness-ui-tasks--column (task)
  "Return TASK's column as a symbol.
A backlog task has a column of its own (`harness-tasks--column'), so
the board never shows one among the queued pending tasks."
  (intern (or (plist-get task :column)
              (cond ((harness-ui-tasks--merge-queue-p task) "merging")
                    ((and (equal (plist-get task :state) "pending")
                          (harness-ui-tasks--backlog-p task))
                     "backlog")
                    (t (pcase (plist-get task :state)
                         ("pending" "pending") ("review" "review") ("merging" "merging") ("done" "done")
                         (_ "active")))))))

(defun harness-ui-tasks--archived-p (task)
  "Non-nil when TASK is archived."
  (harness-json-true-p (plist-get task :archived)))

(defun harness-ui-tasks--backlog-p (task)
  "Non-nil when TASK is in the backlog: it starts only when you start it."
  (harness-json-true-p (plist-get task :backlog)))

(defun harness-ui-tasks--no-merge-p (task)
  "Non-nil when TASK handed in work that needs no merge (`hand_in')."
  (harness-json-true-p (plist-get task :no-merge)))

(defun harness-ui-tasks--refining-p (task)
  "Non-nil while an agent writes TASK up, or after its write-up stopped."
  (equal (plist-get task :state) "refining"))

(defun harness-ui-tasks--planned-p (task)
  "Non-nil when TASK's write-up is a plan for a cheaper model (Plan mode)."
  (harness-json-true-p (plist-get task :plan)))

(defun harness-ui-tasks--unstarted-p (task)
  "Non-nil when TASK has not started: queued, in the backlog or being written up."
  (member (plist-get task :state) '("pending" "refining")))

(defun harness-ui-tasks--writing-p (task)
  "Non-nil while an agent writes TASK up: refining and not stopped.
The task record says so as soon as it changes, unlike the session cache."
  (and (harness-ui-tasks--refining-p task) (null (plist-get task :outcome))))

(defun harness-ui-tasks--review-p ()
  "Non-nil when finished tasks wait for your review before they merge.
That is the harness's `task/settings' as last fetched: review is on, as
it is by default, until they say it is off."
  (not (eq (plist-get harness-ui-tasks--settings :require-verification) :false)))

(defun harness-ui-tasks--duplicate-p (task)
  "Non-nil when TASK's write-up refused it as a duplicate of another task."
  (and (harness-ui-tasks--refining-p task) (equal (plist-get task :outcome) "duplicate")))

(defun harness-ui-tasks--started (task)
  "When TASK started, else when it was submitted, else 0."
  (or (plist-get task :started) (plist-get task :created) 0))

(defun harness-ui-tasks--completed (task)
  "When TASK was completed: verified, else finished, else 0."
  (or (plist-get task :verified-at) (plist-get task :finished) 0))

(defun harness-ui-tasks--finished-later-p (a b)
  "Non-nil when task A finished after task B.
Ready for review lists its tasks so, the last to come to review first."
  (> (or (plist-get a :finished) 0) (or (plist-get b :finished) 0)))

(defun harness-ui-tasks--priority (task)
  "TASK's priority: \"low\", \"medium\" or \"high\"; medium when it has none.
TASK is a view, whose `:priority' the harness computes from the task's
session (`harness-priority-of-task')."
  (let* ((value (plist-get task :priority))
         (name (if (and value (symbolp value)) (symbol-name value) value)))
    (if (member name harness-ui-priority-levels) name "medium")))

(defun harness-ui-tasks--priority-rank (task)
  "The place of TASK's priority in `harness-ui-priority-levels': 0 is low."
  (cl-position (harness-ui-tasks--priority task) harness-ui-priority-levels :test #'equal))

(defun harness-ui-tasks--ranks-before-p (a b)
  "Non-nil when task A goes before B by priority: a higher one, else the older.
The backlog, which the queue never starts, and Requires your input list
their tasks so; Pending goes by the order its tasks start in, which
puts the tasks returned to the queue first of their priority
\(`harness-ui-tasks--starts-before-p')."
  (let ((ra (harness-ui-tasks--priority-rank a))
        (rb (harness-ui-tasks--priority-rank b)))
    (if (= ra rb)
        (< (or (plist-get a :created) 0) (or (plist-get b :created) 0))
      (> ra rb))))

(defun harness-ui-tasks--returned (task)
  "When TASK was put back in the queue after it worked, a float time, or nil.
That is its `:returned': paused (returned to pending), pre-empted by
work sent back from review, its borrowed slot taken back, or sent back
while no slot could take it.  The harness clears it once the task
starts.  One that says so without a time counts as returned at 0, as
its card says it was returned all the same."
  (let ((returned (plist-get task :returned)))
    (and (harness-json-true-p returned) (if (numberp returned) returned 0))))

(defun harness-ui-tasks--starts-before-p (a b)
  "Non-nil when waiting task A gets a slot before B, as the harness hands them.
That is the harness's start order (`harness-tasks--start-order'), read
from the views: a higher priority first; among equals, work sent back
from review (`:sent-back') first, then a task returned to the queue
after it worked (`harness-ui-tasks--returned') -- paused, pre-empted or
its slot taken back -- before one that never started, the first
returned first, and the others oldest first.  So a pre-empted task is
next in line once the higher priorities are served."
  (let ((ra (harness-ui-tasks--priority-rank a))
        (rb (harness-ui-tasks--priority-rank b))
        (sa (and (harness-json-true-p (plist-get a :sent-back)) t))
        (sb (and (harness-json-true-p (plist-get b :sent-back)) t))
        (qa (harness-ui-tasks--returned a))
        (qb (harness-ui-tasks--returned b)))
    (cond ((/= ra rb) (> ra rb))
          ((not (eq sa sb)) sa)
          ((and qa qb) (< qa qb))
          ((or qa qb) (and qa t))
          (t (< (or (plist-get a :created) 0) (or (plist-get b :created) 0))))))

(defun harness-ui-tasks--visible (&optional filtered)
  "Return the tasks shown, as an alist COLUMN -> tasks in display order.
In progress is newest first by when each task started, review by when
it finished and completed by when it was completed, so a task arriving
in any of them shows at the top; merging is the queue's own order, from
when each branch joined it; pending is in the order its tasks start
\(`harness-ui-tasks--starts-before-p'): by priority, and within one,
work sent back from review, then the tasks returned to the queue, then
the oldest.  The backlog (which the queue never starts) and Requires
your input go by priority, then oldest first
\(`harness-ui-tasks--ranks-before-p'); the other columns are oldest
first.  With FILTERED, only the tasks `harness-ui-tasks-filter' shows,
when there is one, archived or not."
  (let ((groups (mapcar (lambda (c) (list (car c))) harness-ui-tasks--columns))
        (show (and filtered (plist-get harness-ui-tasks-filter :show))))
    (dolist (task harness-ui-tasks--tasks)
      (when (if show
                (funcall show task)
              (not (and (harness-ui-tasks--archived-p task) (not harness-ui-tasks--show-archived))))
        (push task (cdr (assq (harness-ui-tasks--column task) groups)))))
    (dolist (g groups groups)
      (setcdr g (sort (cdr g)
                      (pcase (car g)
                        ('active (lambda (a b) (> (harness-ui-tasks--started a) (harness-ui-tasks--started b))))
                        ('review #'harness-ui-tasks--finished-later-p)
                        ('merging (lambda (a b) (< (harness-ui-tasks--merge-queued a)
                                                   (harness-ui-tasks--merge-queued b))))
                        ('done (lambda (a b) (> (harness-ui-tasks--completed a) (harness-ui-tasks--completed b))))
                        ('pending #'harness-ui-tasks--starts-before-p)
                        ('backlog #'harness-ui-tasks--ranks-before-p)
                        ('needs-input #'harness-ui-tasks--ranks-before-p)
                        (_ (lambda (a b) (< (or (plist-get a :created) 0) (or (plist-get b :created) 0))))))))))

;;;; What a card says

(defun harness-ui-tasks--session (task)
  "Return the cached plist of TASK's session, or nil."
  (and (plist-get task :session) (harness-ui-session (plist-get task :session))))

(defun harness-ui-tasks--title (task)
  "TASK's name, its session's or its own, else its prompt's first line.
A task is named as soon as it is submitted, so a task waiting for a slot
shows its title too.  The session list names a task's session the same
way."
  (harness-ui-task-title task))

(defun harness-ui-tasks--todos (session)
  "Return (DONE TOTAL CURRENT-TEXT) for SESSION's todo list, or nil."
  (let ((todos (plist-get session :todos)))
    (when todos
      (list (cl-count "done" todos :key (lambda (td) (plist-get td :status)) :test #'equal)
            (length todos)
            (plist-get (cl-find "in-progress" todos :key (lambda (td) (plist-get td :status)) :test #'equal)
                       :text)))))

(defun harness-ui-tasks--request (session)
  "Say what kind of input the first pending request of SESSION needs.
Only the kind: the full request is shown by `harness-ui-tasks-requests',
or read in the session."
  (harness-ui-pending-summary session))

(defun harness-ui-tasks--wide-icon-p (icon)
  "Non-nil when ICON is drawn as an image, which is about two columns wide.
Terminals fall back to a one-column symbol, which needs no extra room."
  (and (> (length icon) 0)
       (eq 'image (car-safe (get-text-property 0 'display icon)))))

(defun harness-ui-tasks--mark-nudge (icon)
  "Pixels to move a wide ICON left so it centres on the one-column grid.
The icon is an image with its ink centred, about a column wider than the
stopped square it stands next to; half that extra width puts the two
marks on the same centre."
  (let ((nudge (/ (- (string-pixel-width icon) (frame-char-width)) 2)))
    (and (> nudge 0) nudge)))

(defun harness-ui-tasks--pad (pixels)
  "A space PIXELS pixels wide, an absolute pixel specification."
  (propertize " " 'display (list 'space :width (list pixels))))

(defun harness-ui-tasks--merge-status (task)
  "TASK's merge status as a string: \"queued\", \"merging\" or \"conflict\"."
  (let ((status (plist-get task :merge-status)))
    (and status (format "%s" status))))

(defun harness-ui-tasks--icon (task column session)
  "Return the icon of TASK's card in COLUMN.
SESSION is TASK's session plist, or nil; in the needs-input column the
icon says whether SESSION waits on a request."
  (pcase column
    ('pending (propertize (harness-ui-icon 'harness-icon-task-pending) 'face 'harness-dim-face))
    ('backlog (cond ((harness-ui-tasks--refining-p task) (harness-ui-status-icon "running"))
                    (t (propertize (harness-ui-icon 'harness-icon-task-backlog) 'face 'harness-dim-face))))
    ('done (propertize (harness-ui-icon 'harness-icon-task-done) 'face 'harness-task-done-face))
    ('review (propertize (harness-ui-icon 'harness-icon-task-review) 'face 'harness-task-review-face))
    ('merging (if (equal (harness-ui-tasks--merge-status task) "queued")
                  (propertize (harness-ui-icon 'harness-icon-task-merging) 'face 'harness-task-merging-face)
                (harness-ui-status-icon "running")))
    ('needs-input (if (harness-session-waiting-on-user-p session)
                      (harness-ui-status-icon "blocked")
                    (propertize (harness-ui-icon 'harness-icon-task-stopped) 'face 'harness-task-attention-face)))
    (_ (if (plist-get task :session) (harness-ui-status-icon "running")
         (harness-ui-status-icon "idle")))))

(defun harness-ui-tasks--detail (task column session position)
  "The second line of TASK's card in COLUMN.
Once the task has a name, which is then the card's title, the line says
what its prompt asks.  SESSION is TASK's session plist, or nil;
POSITION is its place in line among queued tasks."
  (let ((todos (harness-ui-tasks--todos session))
        (named (and (harness-ui-task-name task session) t)))
    (pcase column
      ('needs-input
       (propertize (or (harness-ui-tasks--request session)
                       (pcase (plist-get task :outcome)
                         ("merge-failed" (format "could not merge into %s: %s" (harness-ui-tasks--base task)
                                                 (or (plist-get task :error) "?")))
                         ("adopted" "waiting for your next message")
                         ("cannot-continue" (format "cannot continue — %s"
                                                    (or (plist-get task :error) "it said it cannot finish")))
                         ((and "interrupted" (guard (harness-ui-tasks--refining-p task)))
                          (format "%s interrupted by a restart"
                                  (if (harness-ui-tasks--planned-p task) "plan" "write-up")))
                         ((guard (harness-ui-tasks--duplicate-p task)) (harness-ui-tasks--duplicate-detail task))
                         (outcome (format "%s: %s%s"
                                          (cond ((not (harness-ui-tasks--refining-p task)) "stopped")
                                                ((harness-ui-tasks--planned-p task) "plan stopped")
                                                (t "write-up stopped"))
                                          (or outcome "?")
                                          (if (plist-get task :error) (concat " — " (plist-get task :error)) "")))))
                   'face 'harness-task-attention-face))
      ('merging
       (propertize (pcase (harness-ui-tasks--merge-status task)
                     ("merging" (format "merging into %s…" (harness-ui-tasks--base task)))
                     ("conflict" (let ((files (take 3 (plist-get task :conflicts))))
                                  (if files
                                      (format "resolving merge conflicts in %s" (string-join files ", "))
                                    "resolving merge conflicts")))
                     (_ (format "queued to merge into %s" (harness-ui-tasks--base task))))
                   'face 'harness-dim-face))
      ('active (propertize (or (nth 2 todos)
                               (cond (named (harness-first-line (plist-get task :prompt) 90))
                                     ((equal (plist-get session :status) "running") "working…")
                                     (t "starting…")))
                           'face 'harness-dim-face))
      ('pending (propertize (harness-ui-tasks--pending-detail task position todos named)
                            'face 'harness-dim-face))
      ('backlog (propertize (harness-ui-tasks--pending-detail task position todos named)
                            'face 'harness-dim-face))
      ('review (propertize (harness-ui-tasks--review-detail task named) 'face 'harness-dim-face))
      ('done (propertize (let ((took (and (plist-get task :started) (plist-get task :finished)
                                          (format "took %s" (harness-ui-tasks--elapsed
                                                             (- (plist-get task :finished) (plist-get task :started)))))))
                           (string-join
                            (delq nil (list (and named (harness-first-line (plist-get task :prompt) 70))
                                            (and (harness-json-true-p (plist-get task :merged))
                                                 (format "merged into %s" (harness-ui-tasks--base task)))
                                            (and (harness-ui-tasks--no-merge-p task) "nothing to merge")
                                            took))
                            " · "))
                         'face 'harness-dim-face)))))

(defun harness-ui-tasks--duplicate-detail (task)
  "The second line of TASK's card once its write-up refused it as a duplicate.
It names the task TASK duplicates, by its title when it is on the board,
then says why, in the words of the agent that refused it."
  (let* ((of (plist-get task :duplicate-of))
         (original (and of (harness-ui-tasks--find of)))
         (why (plist-get task :error)))
    (concat (cond (original (concat "duplicate of " (harness-ui-tasks--quote (harness-ui-tasks--title original))))
                  (of (format "duplicate of %s" of))
                  (t "refused as a duplicate"))
            (if (harness-string-blank-p why)
                ""
              (concat " — " (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " why)))))))

(defun harness-ui-tasks--body-line (task)
  "The first line of TASK's prompt after its first, shortened; nil if none.
For a write-up that is the start of its body, under the title, read as
plain text: no list, heading or emphasis markers."
  (when-let* ((line (cadr (split-string (or (plist-get task :prompt) "") "\n" t "[ \t]+")))
              (plain (string-trim
                      (replace-regexp-in-string
                       "\\*\\*\\|__\\|`" ""
                       (replace-regexp-in-string "\\`\\(?:#+\\|[-*+]\\|[0-9]+[.)]\\)[ \t]+" "" line))))
              ((not (string-empty-p plain))))
    (harness-first-line plain 70)))

(defconst harness-ui-tasks--dot (string #xb7)
  "The middle dot that separates the facts on a card.")

(defconst harness-ui-tasks--ellipsis (string #x2026)
  "The ellipsis of a hint or a pending state.")

(defun harness-ui-tasks--quote (text)
  "TEXT between curly double quotes, as the compose labels name a task."
  (concat (string #x201c) text (string #x201d)))

;;;; The subtitle

;; A card's second line is its subtitle: the recap a short model call
;; wrote (`harness-tasks-recap').  It is folded away on most cards -- you
;; see one line per task -- except where it matters most, on a task that
;; needs your input, and on the cards you show it on yourself.  A branch
;; in the merge queue is one line too: its section says what it is
;; doing, and its facts say when the merge is under way or in conflict
;; (`harness-ui-tasks--facts').

(defun harness-ui-tasks--subtitle-shown-p (task)
  "Non-nil when TASK's card shows its subtitle now.
Your own choice for the task wins over its column's default."
  (let ((choice (assoc (plist-get task :id) harness-ui-tasks--subtitles)))
    (if choice (cdr choice)
      (nth 2 (assq (harness-ui-tasks--column task) harness-ui-tasks--columns)))))

(defun harness-ui-tasks--set-subtitle (id shown)
  "Show or hide the subtitle of task ID from now on, whatever its column.
It shows when SHOWN is non-nil."
  (setq harness-ui-tasks--subtitles
        (cons (cons id shown) (assoc-delete-all id harness-ui-tasks--subtitles))))

(defun harness-ui-tasks--subtitle (task column session position room)
  "The text under TASK's title, at most ROOM columns wide.
That is its recap, else the old detail line, which COLUMN, SESSION and
POSITION make as for `harness-ui-tasks--detail'.  In the needs-input
and merging columns the detail stays after the recap, which must not
hide what the task waits for, or where its branch stands: a needs-input
card shows its subtitle by default, a merging card when you show it."
  (let* ((recap (plist-get task :recap))
         (recap (and (stringp recap) (not (harness-string-blank-p recap)) (string-trim recap)))
         (detail (harness-ui-tasks--detail task column session position))
         (sep (concat " " harness-ui-tasks--dot " ")))
    (cond
     ((null recap) (harness-ui-tasks--fit (or detail "") room))
     ((and (memq column '(needs-input merging)) detail)
      (harness-ui-tasks--fit
       (concat (harness-ui-tasks--fit (propertize recap 'face 'harness-dim-face)
                                      (- room (string-width detail) (string-width sep)))
               sep detail)
       room))
     (t (harness-ui-tasks--fit (propertize recap 'face 'harness-dim-face) room)))))

(defun harness-ui-tasks--pending-detail (task position todos &optional named)
  "The second line of a pending or backlog TASK's card: what it waits for.
POSITION is its place in line among queued tasks, nil in the backlog,
which the queue never starts.  TODOS its session's.  A queued task
NAMED (its name is the card's title) has the first line of its prompt
after its place in line, else the line after it, as a backlog task's
write-up has, its first line being a title.  A task held back says
what holds it, in full (`harness-ui-tasks--hold-text'): paused, out of
quota or over a budget; one returned to pending says why it waits
\(`harness-ui-tasks--returned-why')."
  (let ((body (harness-ui-tasks--body-line task))
        (sep (concat " " harness-ui-tasks--dot " ")))
    (cond
     ((harness-ui-tasks--refining-p task)
      (or (nth 2 todos)
          (concat (if (harness-ui-tasks--planned-p task) "planning" "writing it up")
                  harness-ui-tasks--ellipsis)))
     ((harness-ui-tasks--backlog-p task)
      (concat (cond ((harness-json-true-p (plist-get task :joining-queue)) "joining the queue")
                    ((not (plist-get task :refined)) "on hold")
                    ((harness-ui-tasks--planned-p task) "planned")
                    (t "written up"))
              (if body (concat sep body) "")))
     ((plist-get task :hold)
      (format "#%d in line%s" (or position 1)
              (concat sep (harness-ui-tasks--hold-text (plist-get task :hold)))))
     ((plist-get task :returned)
      (format "#%d in line%s" (or position 1)
              (concat sep (harness-ui-tasks--returned-why task))))
     (t (let ((line (if named (harness-first-line (plist-get task :prompt) 70) body)))
          (format "#%d in line%s" (or position 1) (if line (concat sep line) "")))))))

(defun harness-ui-tasks--named (id fallback)
  "Name task ID for a card: its title in quotes when the board has it.
Else ID itself, else FALLBACK when there is no ID."
  (let ((task (and id (harness-ui-tasks--find id))))
    (cond (task (format "\"%s\"" (harness-truncate-end (harness-ui-tasks--title task) 40)))
          (id (format "%s" id))
          (t fallback))))

(defun harness-ui-tasks--returned-why (task)
  "Why TASK, returned to pending, waits in the queue, for its card.
\"paused\" for a task returned by hand; \"pre-empted by\" the task sent
back from review that took its slot (`:return-reason' preempted), named
by its title when the board has it; \"slot taken back by\" the task
waiting on you whose slot it worked in, once you answered (reclaimed);
\"sent back from review\" for one the user sent back while no slot
could take it; \"quota\" or \"budget\" for one whose turn stopped for
lack of either.  Each carries on where it stopped when it starts again."
  (pcase (format "%s" (or (plist-get task :return-reason) "returned"))
    ("preempted"
     (format "pre-empted by %s"
             (harness-ui-tasks--named (plist-get task :preempted-by) "a task sent back")))
    ("reclaimed"
     (format "slot taken back by %s"
             (harness-ui-tasks--named (plist-get task :preempted-by) "the task that lent it")))
    ("sent-back" "sent back from review")
    ("quota" "quota")
    ("budget" "budget")
    (_ "paused")))

;;;; What holds a task back

;; A queued task the scheduler leaves in the queue carries its hold
;; (`:hold' on the view): paused by hand, out of quota, or over a hard
;; budget.  The card says it on its first line, short, in a column of its
;; own; the line under the title and the tooltip say it in full, and the
;; task slots page words it the same way.

(defun harness-ui-tasks--clock (time)
  "Describe TIME, a float time, the way a reset reads: 19:00, or a date.
A time within the next 20 hours is the hour alone, a later one has its
day, as the harness words it (`harness-fallback--clock')."
  (if (< (- time (float-time)) 72000)
      (format-time-string "%H:%M" time)
    (format-time-string "%a %b %-d, %H:%M" time)))

(defun harness-ui-tasks--hold-names (hold)
  "Return the names of what HOLD waits for, as one string, or nil.
The labels of its items -- the providers or models out of quota, the
budgets spent -- without repeats, in order."
  (let (names)
    (dolist (item (append (plist-get hold :items) nil))
      (let ((name (or (plist-get item :label) (plist-get item :key) (plist-get item :id))))
        (when (and (stringp name) (not (string-empty-p name)))
          (cl-pushnew name names :test #'equal))))
    (and names (string-join (nreverse names) ", "))))

(defun harness-ui-tasks--hold-text (hold &optional short)
  "Say what HOLD holds a queued task back for: nouns, then when it ends.
HOLD is a task's `:hold'.  \"paused\"; \"quota · Claude Code · resets
19:00\" and \"budget · daily · resets Sat Oct 24, 00:00\", the names of
the providers or budgets between the kind and the end.  A time the
provider did not give but the harness guessed reads \"retry\" instead
of \"resets\", and a hold that ends only when you change a budget has no
end, \"budget · session\".  SHORT leaves the names out, for the first
line of a card.  See `harness-ui-tasks--clock'."
  (let ((kind (format "%s" (plist-get hold :kind)))
        (until (plist-get hold :until)))
    (if (equal kind "paused")
        "paused"
      (string-join
       (delq nil (list kind
                       (and (not short) (harness-ui-tasks--hold-names hold))
                       (and (numberp until)
                            (format "%s %s"
                                    (if (harness-json-true-p (plist-get hold :guess)) "retry" "resets")
                                    (harness-ui-tasks--clock until)))))
       (concat " " harness-ui-tasks--dot " ")))))

(defun harness-ui-tasks--paused-p (task)
  "Non-nil when TASK is held in the queue because you paused it."
  (equal (format "%s" (plist-get (plist-get task :hold) :kind)) "paused"))

(defun harness-ui-tasks--hold-fact (task column)
  "The fact on TASK's card in COLUMN that says what holds it back, or nil.
Only a queued task in Pending has one: its hold, short
\(`harness-ui-tasks--hold-text'), in the held face while it waits for
quota or a budget, dim while it is only paused."
  (when-let* (((eq column 'pending))
              (hold (plist-get task :hold)))
    (propertize (harness-ui-tasks--hold-text hold t)
                'face (if (harness-ui-tasks--paused-p task) 'harness-dim-face 'harness-task-held-face))))

(defun harness-ui-tasks--loan-fact (task column)
  "The fact on TASK's card in COLUMN about a slot lent to the queue, or nil.
A task blocked on you long enough lends its slot, and the queue starts
another task in it (the harness's `harness-tasks-lend-blocked-slot-after'):
that task says \"borrowed slot\" (`:borrowed-from'), and the lender
\"slot lent\", each naming the other in its tooltip.  Only while both
are at work or wait on you: a loan ends with either."
  (when (memq column '(active needs-input))
    (let* ((id (plist-get task :id))
           (from (plist-get task :borrowed-from))
           (borrower (and (not from)
                          (cl-find-if (lambda (other)
                                        (and (equal (plist-get other :borrowed-from) id)
                                             (memq (harness-ui-tasks--column other) '(active needs-input))))
                                      harness-ui-tasks--tasks))))
      (cond
       (from
        (let ((lender (harness-ui-tasks--named from "a task waiting on you")))
          (propertize "borrowed slot"
                      'help-echo (format "Borrowed from %s until you answer it" lender))))
       (borrower
        (propertize "slot lent"
                    'help-echo (format "Lent to %s until you answer"
                                       (harness-ui-tasks--named (plist-get borrower :id) "another task"))))))))

(defun harness-ui-tasks--sent-back-message (task)
  "Say where TASK went once `task/reject' sent it back, as a message.
TASK is the task the harness returned: at work on the feedback, or
waiting in the queue with it when no slot could take it -- every slot
taken by work that goes first, or the queue suspended."
  (cond
   ((not (equal (format "%s" (plist-get task :state)) "pending"))
    "Sent back")
   ((harness-json-true-p (plist-get task :queue-suspended))
    "Sent back; waiting for a slot (queue suspended)")
   (t "Sent back; waiting for a slot")))

(defun harness-ui-tasks--say-sent-back (task)
  "Show where TASK went once `task/reject' sent it back."
  (message "%s" (harness-ui-tasks--sent-back-message task)))

(defun harness-ui-tasks--took (task)
  "How long TASK worked until it finished, as \"took 12m\"; nil if unknown."
  (let ((started (plist-get task :started))
        (finished (plist-get task :finished)))
    (and started finished (format "took %s" (harness-ui-tasks--elapsed (- finished started))))))

(defun harness-ui-tasks--times (n)
  "N as a number of times: once, twice, 3 times."
  (pcase n (1 "once") (2 "twice") (_ (format "%d times" n))))

(defun harness-ui-tasks--review-detail (task named)
  "The second line of TASK's card in review: what verifying it does.
NAMED is non-nil when it has a name, its session's or its own, which
then is the card's title, so the prompt shows here."
  (let ((rounds (length (plist-get task :feedback))))
    (string-join
     (delq nil (list (and named (harness-first-line (plist-get task :prompt) 70))
                     (cond ((harness-json-true-p (plist-get task :merged))
                            (format "merged into %s" (harness-ui-tasks--base task)))
                           ((harness-ui-tasks--no-merge-p task)
                            "nothing to merge")
                           ((plist-get task :worktree)
                            (format "merges into %s once verified" (harness-ui-tasks--base task))))
                     (harness-ui-tasks--took task)
                     (and (> rounds 0) (format "sent back %s" (harness-ui-tasks--times rounds)))))
     (concat " " harness-ui-tasks--dot " "))))

(defun harness-ui-tasks--base (task)
  "The branch TASK merges into."
  (or (plist-get task :base) "main"))

(defun harness-ui-tasks--queued-since (task)
  "When TASK joined the queue it waits in: a float time.
That is when the harness last put it there (`:queued-at'), else when
it was returned to pending (`:returned'), else when it was submitted:
a task kicked back into the queue waits from then, not from the day it
was written."
  (or (plist-get task :queued-at) (plist-get task :returned) (plist-get task :created)))

(defconst harness-ui-tasks--fact-kinds '(archived main-tree loan merge hold todos time)
  "The kinds of fact a card states, in the order of the columns they make.
`harness-ui-tasks--facts' makes a cell of each kind a task has a fact of,
and the cards of a section lay their cells out in one column for each
kind (`harness-ui-tasks--layout'), so a kind reads in the same place on
every card.")

(defun harness-ui-tasks--facts (task column session)
  "The facts on TASK's card in COLUMN, as cells: an alist (KIND . TEXT).
SESSION is TASK's session plist, or nil.  KIND is one of
`harness-ui-tasks--fact-kinds' and the cells come in their order; a
kind TASK has no fact of has no cell.  The kinds:

  archived  \"archived\", on a task shown with [Archived] or found by a search
  main-tree \"main tree\", on a task working in the project's main checkout
  loan      \"borrowed slot\" or \"slot lent\" (`harness-ui-tasks--loan-fact')
  merge     where a branch in the merge queue stands past waiting for its
            turn: \"merging now\", or \"conflict\"
  hold      what holds a waiting task back: \"paused\", \"quota · resets
            19:00\", \"budget\" (`harness-ui-tasks--hold-fact')
  todos     how many of its todos are done: \"3/7\"
  time      what the column says of when: queued, added, refined, ready,
            done, or for work in progress how long it has run

That is all a row says: the title comes first.  What its session has to
say -- the context in use, the tokens written, how fast and what they
cost -- is in the tooltip of the title instead
\(`harness-ui-tasks--figures').  Its priority is not among them: the
arrow before the title says that (`harness-ui-tasks--priority-mark').
A cell is dimmed (`harness-dim-face'), the hold's apart: it stands out
while a task waits for quota or a budget."
  (let* ((todos (harness-ui-tasks--todos session))
         (started (plist-get task :started))
         (cells
          (list
           (cons 'archived (and (harness-ui-tasks--archived-p task) "archived"))
           (cons 'main-tree (and (harness-json-true-p (plist-get task :main-tree)) "main tree"))
           ;; Where a branch in the queue stands, past waiting for its
           ;; turn: the card is one line, and the same working mark shows
           ;; a merge under way and a conflict being resolved.
           (cons 'loan (harness-ui-tasks--loan-fact task column))
           (cons 'merge (and (eq column 'merging)
                             (pcase (harness-ui-tasks--merge-status task)
                               ("merging" "merging now")
                               ("conflict" "conflict"))))
           ;; Why a waiting task does not start: state, so it stays on the
           ;; line while a card gives up the todos and the time for its title.
           (cons 'hold (harness-ui-tasks--hold-fact task column))
           (cons 'todos (and todos (not (memq column '(done review merging)))
                             (format "%d/%d" (nth 0 todos) (nth 1 todos))))
           (cons 'time
                 (pcase column
                   ('pending
                    (let ((queued (format "queued %s" (harness-relative-time
                                                       (harness-ui-tasks--queued-since task)))))
                      ;; The queue being suspended holds it back, which the
                      ;; card says.
                      (if (harness-json-true-p (plist-get task :queue-suspended))
                          (concat queued " " harness-ui-tasks--dot " queue suspended")
                        queued)))
                   ;; A backlog task waits for the user, never for the
                   ;; queue, so it says when it was written up or added.
                   ('backlog (cond ((harness-ui-tasks--refining-p task) nil)
                                   ((plist-get task :refined)
                                    (format "%s %s" (if (harness-ui-tasks--planned-p task) "planned" "refined")
                                            (harness-relative-time (plist-get task :refined))))
                                   (t (format "added %s" (harness-relative-time (plist-get task :created))))))
                   ('review (and (plist-get task :finished)
                                 (format "ready %s" (harness-relative-time (plist-get task :finished)))))
                   ('merging (let ((queued (harness-ui-tasks--merge-queued task)))
                               (and (> queued 0)
                                    (format "queued %s" (harness-relative-time queued)))))
                   ('done (let ((completed (harness-ui-tasks--completed task)))
                            (and (> completed 0) (format "done %s" (harness-relative-time completed)))))
                   (_ (and started (harness-ui-tasks--elapsed (- (float-time) started)))))))))
    (cl-loop for (kind . text) in cells
             when (and text (not (string-empty-p text)))
             ;; The hold has its face already: a task waiting for quota
             ;; stands out from one that only waits for a slot.
             collect (cons kind (if (eq kind 'hold) text (propertize text 'face 'harness-dim-face))))))

(defun harness-ui-tasks--session-figures (session)
  "What SESSION says of its work that no row of the board does, as strings.
The size of its conversation against its context window, the tokens it
wrote, how fast it wrote them on average, and what they cost -- \"cost
$1.20\" when it is billed per token, else the plan that pays for it,
\"Max plan\" (`harness-ui-format-spend').  A figure there is nothing to
say of is left out."
  (let ((tokens (harness-ui-session-tokens session)))
    (mapcar #'substring-no-properties
            (delq nil
                  (list (and (> (+ (plist-get tokens :context) (plist-get tokens :output)) 0)
                             (concat "context " (harness-ui-format-context session)))
                        (harness-ui-format-output session)
                        (harness-ui-format-average-rate session)
                        (and (> (harness-usage-list-cost (plist-get session :usage)) 0)
                             (let ((spend (substring-no-properties (harness-ui-format-spend session))))
                               (if (string-match-p "\\`\\$[0-9.]*\\'" spend)
                                   (concat "cost " spend)
                                 (concat spend " plan")))))))))

(defun harness-ui-tasks--figures (task)
  "Everything TASK's card has to say, as short strings, in words.
Its facts first (`harness-ui-tasks--facts'), whether or not its row has
the room for them, then its session's figures
\(`harness-ui-tasks--session-figures').  The facts are worded to read
without a column to say what they are: \"3/7 todos done\", and \"started
12m ago\" for the time a task has worked; what holds a task back is said
in full, with the names of the providers or budgets
\(`harness-ui-tasks--hold-text')."
  (let* ((column (harness-ui-tasks--column task))
         (session (harness-ui-tasks--session task)))
    (append
     (cl-loop for (kind . text) in (harness-ui-tasks--facts task column session)
              collect (substring-no-properties
                       (pcase kind
                         ('todos (format "%s todos done" text))
                         ('time (if (memq column '(active needs-input)) (format "started %s ago" text) text))
                         ('hold (harness-ui-tasks--hold-text (plist-get task :hold)))
                         (_ text))))
     (and session (harness-ui-tasks--session-figures session)))))

(defun harness-ui-tasks--title-help (_window object pos)
  "The tooltip of a card's title: what a click does, then its figures.
It is made when it is asked for, a `help-echo' function of the board
\(OBJECT) and the title's POS, so the session's figures, which change
while it works, are never older than the hover and the board need not be
drawn again for them (`harness-ui-tasks--board-key').  One line, as
hover text is (`harness-ui-one-line')."
  (let ((figures (and (bufferp object) (buffer-live-p object)
                      (harness-ignore-errors-logged "making the tooltip of a card"
                        (with-current-buffer object
                          (when-let* ((id (get-text-property pos 'harness-task-id object))
                                      (task (harness-ui-tasks--find id)))
                            (harness-ui-tasks--figures task)))))))
    (harness-ui-one-line
     (string-join (cons "Open the session" figures) (concat " " harness-ui-tasks--dot " ")))))

(defun harness-ui-tasks--shown-priority (task column)
  "TASK's priority as its card in COLUMN shows it: \"high\", \"low\" or nil.
Medium, the default, goes without saying, and so does any priority once
the task is completed: it only ever ordered the queue."
  (let ((priority (harness-ui-tasks--priority task)))
    (and (not (eq column 'done)) (not (equal priority "medium")) priority)))

(defun harness-ui-tasks--priority-face (priority)
  "The face that shows PRIORITY, \"high\" or \"low\"."
  (if (equal priority "high") 'harness-task-priority-high-face 'harness-task-priority-low-face))

(defun harness-ui-tasks--priority-mark (task column)
  "The mark before the title of TASK's card in COLUMN, with its space, or \"\".
An arrow up for high priority, down for low, the one
`harness-ui-priority-arrow' makes for the task's session.  It is all
a card says of its priority -- no words repeat it among the facts --
so it stays on a narrow board, and a click on it asks for that
session's priority.  See `harness-ui-tasks--shown-priority'."
  (if-let* ((priority (harness-ui-tasks--shown-priority task column)))
      (concat (harness-ui-priority-arrow priority (plist-get task :session)) " ")
    ""))

(defun harness-ui-tasks--elapsed (seconds)
  "Format SECONDS of work coarsely: 40s, 12m, 2h05m."
  (cond ((< seconds 60) (format "%ds" (truncate seconds)))
        ((< seconds 3600) (format "%dm" (truncate (/ seconds 60))))
        (t (format "%dh%02dm" (truncate (/ seconds 3600)) (truncate (/ (mod seconds 3600) 60))))))

;;;; Assuming a task's worktree

(defun harness-ui-tasks--assumable-worktree (task)
  "Return TASK's worktree when it can be assumed as a project, else nil.
That is a worktree of this Emacs's machine that is still there: one a
merged task's was removed from, or a task in the main tree has none.
The library checks the rest, that it is a worktree of the project."
  (let ((worktree (plist-get task :worktree)))
    (and (stringp worktree)
         (not (string-empty-p worktree))
         (not (file-remote-p worktree))
         (file-directory-p worktree)
         worktree)))

(defun harness-ui-tasks--assume-actions (task)
  "Return the action that assumes TASK's worktree as the project, or resets it.
Reset when it is the worktree assumed already; nothing when TASK has no
worktree to assume.  Both are the command `harness-ui-tasks-assume-worktree'."
  (when-let* ((worktree (harness-ui-tasks--assumable-worktree task)))
    (if (worktree-assume-parent worktree)
        '(("Reset to main worktree" harness-ui-tasks-assume-worktree))
      '(("Assume worktree" harness-ui-tasks-assume-worktree)))))

;;;; Actions (shared by keys, buttons and the context menu)

(defvar harness-ui-tasks-action-functions nil
  "Functions adding actions of their own to the menu of a task's card.
Each is called with TASK, a task as the board has it (a plist), and
returns a list of (LABEL COMMAND), empty when it has none for TASK.
COMMAND is an interactive command, run as the board's own actions are,
with point on TASK's card: `harness-ui-tasks-task-at-point' returns
TASK there, and `harness-ui-tasks-request' calls the harness with a
failure shown on the board.  The actions come after those of TASK's
column, and are never one of a card's buttons.  A module of your own
or a project's plugin adds a function here as it loads, as the
harness's own repository's plugin adds Open harness to a task in
review whose worktree is a checkout of the harness.")

(defun harness-ui-tasks--extra-actions (task)
  "Return the actions `harness-ui-tasks-action-functions' add to TASK.
A function that fails adds none, and the log says why."
  (cl-loop for fn in harness-ui-tasks-action-functions
           when (functionp fn)
           append (condition-case err
                      (copy-sequence (funcall fn task))
                    (error (harness-log 'warn "task board: actions of %s failed: %s"
                                        fn (error-message-string err))
                           nil))))

(defun harness-ui-tasks--pause-actions (task actions)
  "Return ACTIONS, those of the pending TASK, with what pausing adds.
A paused task (`harness-ui-tasks--paused-p') gets Resume before them
all, so it is the first button of its card and Start now the second;
one that waits for a slot gets Pause after them, in its menu, where it
pushes none of the two buttons its card shows out."
  (if (harness-ui-tasks--paused-p task)
      (cons '("Resume" harness-ui-tasks-resume) actions)
    (append actions '(("Pause" harness-ui-tasks-pause)))))

(defun harness-ui-tasks--actions (task &optional own)
  "Return (LABEL COMMAND) for the actions that apply to TASK, primary first.
Those of `harness-ui-tasks-action-functions' follow the actions of
TASK's column, unless OWN is non-nil: then the board's own actions
come alone, as for the card's buttons."
  (let ((column (harness-ui-tasks--column task)))
    (append
     (pcase column
       ('pending
        (cond
         ((harness-ui-tasks--refining-p task)
          '(("Open" harness-ui-tasks-open) ("Steer" harness-ui-tasks-reply)
            ("Stop" harness-ui-tasks-cancel)))
         ;; A paused task is resumed first; a waiting one can be paused,
         ;; last, so the two buttons its card shows stay what they were.
         ;; Returned to pending: it has a session with the work in it, so
         ;; starting it carries on rather than opens it.
         ((plist-get task :returned)
          (harness-ui-tasks--pause-actions
           task '(("Start now" harness-ui-tasks-start) ("Open" harness-ui-tasks-open)
                  ("Reply" harness-ui-tasks-reply) ("Drop" harness-ui-tasks-cancel))))
         ((plist-get task :session)
          (harness-ui-tasks--pause-actions
           task '(("Start now" harness-ui-tasks-start) ("Edit" harness-ui-tasks-edit)
                  ("Open" harness-ui-tasks-open) ("Refine" harness-ui-tasks-refine)
                  ("Drop" harness-ui-tasks-cancel))))
         (t (harness-ui-tasks--pause-actions
             task '(("Start now" harness-ui-tasks-start) ("Edit" harness-ui-tasks-edit)
                    ("Refine" harness-ui-tasks-refine) ("Drop" harness-ui-tasks-cancel))))))
       ;; A backlog task waits for you; one being written up is steered
       ;; or stopped, like a refining task in the pending column was.
       ('backlog
        (if (harness-ui-tasks--refining-p task)
            '(("Open" harness-ui-tasks-open) ("Steer" harness-ui-tasks-reply)
              ("Stop" harness-ui-tasks-cancel))
          ;; Queued first: the backlog's usual way out is the queue, which
          ;; starts it as a slot frees; Start now ignores the limit.
          '(("Queue it" harness-ui-tasks-queue) ("Start now" harness-ui-tasks-start)
            ("Edit" harness-ui-tasks-edit) ("Open" harness-ui-tasks-open)
            ("Refine" harness-ui-tasks-refine) ("Drop" harness-ui-tasks-cancel))))
       ('needs-input
        (pcase (plist-get (harness-ui-tasks--pending task) :kind)
          ("permission" '(("Allow" harness-ui-tasks-allow) ("Deny" harness-ui-tasks-deny)
                          ("Request…" harness-ui-tasks-requests)
                          ("Open" harness-ui-tasks-open) ("Stop" harness-ui-tasks-cancel)))
          ("question" '(("Answer…" harness-ui-tasks-requests) ("Reply" harness-ui-tasks-reply)
                        ("Open" harness-ui-tasks-open)
                        ("Stop" harness-ui-tasks-cancel)))
          ;; The agent found the board has it already: you decide.
          ((guard (harness-ui-tasks--duplicate-p task))
           '(("Drop" harness-ui-tasks-cancel) ("Write it up" harness-ui-tasks-refine)
             ("Reply" harness-ui-tasks-reply) ("Edit" harness-ui-tasks-edit)
             ("Start now" harness-ui-tasks-start) ("Open" harness-ui-tasks-open)))
          ((guard (harness-ui-tasks--refining-p task))
           '(("Retry" harness-ui-tasks-refine) ("Edit" harness-ui-tasks-edit)
             ("Start now" harness-ui-tasks-start) ("Open" harness-ui-tasks-open)
             ("Drop" harness-ui-tasks-cancel)))
          (_ (cond
              ((equal (plist-get task :outcome) "merge-failed")
               '(("Retry merge" harness-ui-tasks-merge) ("Pause" harness-ui-tasks-pause)
                 ("Reply" harness-ui-tasks-reply) ("Open" harness-ui-tasks-open)
                 ("Mark done" harness-ui-tasks-complete)))
              ((equal (plist-get task :outcome) "cannot-continue")
               '(("Reply" harness-ui-tasks-reply) ("Pause" harness-ui-tasks-pause)
                 ("Mark done" harness-ui-tasks-complete) ("Open" harness-ui-tasks-open)))
              ((member (plist-get task :outcome) '("error" "cancelled" "interrupted" "max-tokens"))
               '(("Retry" harness-ui-tasks-retry) ("Pause" harness-ui-tasks-pause)
                 ("Reply" harness-ui-tasks-reply) ("Open" harness-ui-tasks-open)
                 ("Mark done" harness-ui-tasks-complete)))
              (t '(("Open" harness-ui-tasks-open) ("Pause" harness-ui-tasks-pause)
                   ("Reply" harness-ui-tasks-reply) ("Mark done" harness-ui-tasks-complete)))))))
       ('active '(("Open" harness-ui-tasks-open) ("Steer" harness-ui-tasks-reply)
                  ("Pause" harness-ui-tasks-pause) ("Stop" harness-ui-tasks-cancel)))
       ;; In the queue there is nothing to do but watch; a conflict is
       ;; resolved by its own session, which can be stopped, and a task
       ;; waiting for the queue's turn can be steered like a working one.
       ('merging (if (equal (plist-get (harness-ui-tasks--session task) :status) "running")
                     '(("Open" harness-ui-tasks-open) ("Stop" harness-ui-tasks-cancel))
                   '(("Open" harness-ui-tasks-open) ("Reply" harness-ui-tasks-reply)
                     ("Stop" harness-ui-tasks-cancel))))
       ('review (if (harness-ui-tasks--archived-p task)
                    '(("Unarchive" harness-ui-tasks-archive) ("Verify" harness-ui-tasks-verify)
                      ("Open" harness-ui-tasks-open))
                  ;; No Reply: a message to a task in review sends it back.
                  '(("Verify" harness-ui-tasks-verify) ("Send back" harness-ui-tasks-reject)
                    ("Open" harness-ui-tasks-open) ("Archive" harness-ui-tasks-archive))))
       ('done (if (harness-ui-tasks--archived-p task)
                  '(("Unarchive" harness-ui-tasks-archive) ("Open" harness-ui-tasks-open))
                '(("Archive" harness-ui-tasks-archive) ("Reply" harness-ui-tasks-reply)
                  ("Open" harness-ui-tasks-open)))))
     ;; In the menu only, never among the card's buttons (OWN).
     (unless own (harness-ui-tasks--extra-actions task))
     (unless own (harness-ui-tasks--assume-actions task))
     ;; Before it starts a task runs with the settings it was submitted
     ;; with, not its write-up session's, so those are not offered.
     (when (and (plist-get task :session) (not (harness-ui-tasks--unstarted-p task)))
       '(("Model…" harness-set-model) ("Permission mode…" harness-set-permission-mode)
         ("Thinking…" harness-set-thinking) ("Non-interactive" harness-toggle-non-interactive)))
     ;; Priority orders the tasks still to start.
     (when (harness-ui-tasks--unstarted-p task)
       (harness-ui-tasks--priority-actions task))
     '(("Delete…" harness-ui-tasks-delete)))))

(defun harness-ui-tasks--priority-actions (task)
  "The actions that move TASK's priority a step up or down, as they apply."
  (let ((rank (harness-ui-tasks--priority-rank task))
        (top (1- (length harness-ui-priority-levels))))
    (append (and (< rank top)
                 (list (list (format "Raise priority to %s" (nth (1+ rank) harness-ui-priority-levels))
                             'harness-ui-tasks-raise-priority)))
            (and (> rank 0)
                 (list (list (format "Lower priority to %s" (nth (1- rank) harness-ui-priority-levels))
                             'harness-ui-tasks-lower-priority))))))

(defvar harness-ui-tasks-button-map (make-sparse-keymap)
  "Keys on the buttons of a task board.")

;; Filled at top level, not in the `defvar', so a reload updates the map.
(let ((map harness-ui-tasks-button-map))
  (set-keymap-parent map button-map)
  ;; Any click pushes a button.  A quick one would anyway: with
  ;; `mouse-1-click-follows-link', `mouse-1' turns into `mouse-2' when
  ;; Emacs reads the release soon enough after the press -- by the clock,
  ;; so a busy Emacs makes a quick click slow.  On the board a slow one
  ;; would reach the board's own `mouse-1' and open the task's session.
  (define-key map [mouse-1] #'push-button)
  ;; A double click pushes it once.  The second click would otherwise
  ;; run as a single one, a `mouse-1' on the board: open the session.
  (define-key map [double-mouse-1] #'ignore)
  (define-key map [triple-mouse-1] #'ignore))

;;;; A button that was pushed

;; A push runs a command that asks the harness for something, and the
;; board only changes when the event it causes comes back: with a busy
;; harness long enough for the click to feel as if it never happened.  So
;; a button pushed is held down at once, and stays so until everything its
;; command asked for has been answered.
;;
;; The buttons held down are kept by KEY, (OWNER . ID): ID is what the
;; button is called (`harness-task-button'), OWNER what it belongs to --
;; the id of the task whose card it is on, the column of a section's own
;; line, nil elsewhere -- so the [Start now] of one card is held down
;; without the others'.  A redraw draws a button whose key is held down in
;; `harness-task-button-pressed-face'; the key outlives the redraws, not
;; the button, which may be gone from the board by the time the harness
;; answers.
;;
;; Only the buttons of the board region are held down.  The lines above
;; the compose box open prompts and flip settings at once, and keep
;; working as they did (`harness-ui-tasks--pressable').

(defconst harness-ui-tasks--pressed-min-seconds 0.3
  "Least seconds a button that was pushed stays held down.
A command that asks the harness for nothing -- a prompt, the compose
box, a popout -- or whose answer comes at once would hold it down for
a blink; it is held down this long all the same, so the push shows.")

(defconst harness-ui-tasks--pressed-max-seconds 15
  "Most seconds a button that was pushed stays held down.
An answer that is lost must not leave it stuck: it is let go on the
next redraw or tick after this.")

(defvar-local harness-ui-tasks--pressed nil
  "The buttons of this board held down, a hash table made when first needed.
It maps their KEY, as `harness-ui-tasks--button' makes it, to
\(:at TIME :requests N): when the button was pushed, and how many of the
requests its command made are still waiting for an answer.")

(defvar harness-ui-tasks--card-id nil
  "What the buttons now being drawn belong to, for their key.
The id of the task, while its card is drawn (`harness-ui-tasks--insert-card'
binds it); the column, while the line of a section is
\(`harness-ui-tasks--more-line'); nil elsewhere.")

(defvar harness-ui-tasks--pressable nil
  "Non-nil while the board region is drawn: its buttons can be held down.
`harness-ui-tasks--draw-board' binds it, so the buttons above the compose
box, drawn on their own, are not.")

(defvar harness-ui-tasks--pressing nil
  "The key of the button whose push is running, or nil.
`harness-ui-tasks--press' binds it while the button's action runs, and
the callbacks of its requests run with it too: a request made meanwhile
is one the button waits for (`harness-ui-tasks--request-then').")

(defun harness-ui-tasks--pressed-p (key)
  "Non-nil when the button KEY names is held down on this board."
  (and harness-ui-tasks--pressed (gethash key harness-ui-tasks--pressed) t))

(defun harness-ui-tasks--pressed-keys ()
  "The keys of the buttons held down, in a fixed order, or nil.
The board's drawing depends on them (`harness-ui-tasks--board-key')."
  (when (and harness-ui-tasks--pressed (> (hash-table-count harness-ui-tasks--pressed) 0))
    (sort (hash-table-keys harness-ui-tasks--pressed)
          (lambda (a b) (string< (prin1-to-string a) (prin1-to-string b))))))

(defun harness-ui-tasks--release-stale ()
  "Let go of the buttons held down for more than the longest they may be.
That is `harness-ui-tasks--pressed-max-seconds': an answer that never came
must not leave a button stuck.  This does not redraw; it changes the
keys the next redraw sees (`harness-ui-tasks--pressed-keys'), and the
board's tick, a click and a command all come by here."
  (when (and harness-ui-tasks--pressed (> (hash-table-count harness-ui-tasks--pressed) 0))
    (let ((now (float-time))
          stale)
      (maphash (lambda (key state)
                 (when (> (- now (plist-get state :at)) harness-ui-tasks--pressed-max-seconds)
                   (push key stale)))
               harness-ui-tasks--pressed)
      (dolist (key stale) (remhash key harness-ui-tasks--pressed)))))

(defun harness-ui-tasks--hold-down (key)
  "Hold the button KEY down: the board is drawn again, and shown, at once.
So it shows while the command it runs prompts or works."
  (unless harness-ui-tasks--pressed
    (setq harness-ui-tasks--pressed (make-hash-table :test #'equal)))
  (puthash key (list :at (float-time) :requests 0) harness-ui-tasks--pressed)
  (when (harness-ui-tasks--board-p (current-buffer))
    (harness-ui-tasks--render t)
    (redisplay)))

(defun harness-ui-tasks--let-go (key)
  "Let the button KEY go: it is drawn up again."
  (when (harness-ui-tasks--pressed-p key)
    (remhash key harness-ui-tasks--pressed)
    (when (harness-ui-tasks--board-p (current-buffer))
      (harness-ui-tasks--render t))))

(defun harness-ui-tasks--let-go-later (buffer key at)
  "Let the button KEY of BUFFER go, if it is still held down from the push at AT.
A timer calls it; a button pushed again meanwhile has another AT, and a
request it made since keeps it down."
  (when (harness-ui-tasks--board-p buffer)
    (with-current-buffer buffer
      (let ((state (and harness-ui-tasks--pressed (gethash key harness-ui-tasks--pressed))))
        (when (and state (eql (plist-get state :at) at) (<= (plist-get state :requests) 0))
          (harness-ui-tasks--let-go key))))))

(defun harness-ui-tasks--settle (key)
  "Let the button KEY go once nothing it asked for is left to wait for.
No sooner than `harness-ui-tasks--pressed-min-seconds' after it was
pushed: what is left of them, a timer lets it go."
  (let ((state (and harness-ui-tasks--pressed (gethash key harness-ui-tasks--pressed))))
    (when (and state (<= (plist-get state :requests) 0))
      (let* ((at (plist-get state :at))
             (left (- (+ at harness-ui-tasks--pressed-min-seconds) (float-time))))
        (if (> left 0)
            (run-at-time left nil #'harness-ui-tasks--let-go-later (current-buffer) key at)
          (harness-ui-tasks--let-go key))))))

(defun harness-ui-tasks--press (key action)
  "Push the button KEY: hold it down, then run ACTION, a function of no arguments.
It stays down until the requests ACTION makes through
`harness-ui-tasks--request-then' have been answered, or failed; when it
makes none, `harness-ui-tasks--pressed-min-seconds' after the push.  A
button already down is not pushed again: a second click would run ACTION
twice -- a task started or verified twice is an error -- so it says that
it is still working instead."
  (harness-ui-tasks--release-stale)
  (if (harness-ui-tasks--pressed-p key)
      (message "Still working on that")
    (harness-ui-tasks--hold-down key)
    (let ((buffer (current-buffer)))
      (unwind-protect
          (let ((harness-ui-tasks--pressing key))
            (funcall action))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (harness-ui-tasks--settle key)))))))

(defun harness-ui-tasks--command-key ()
  "The key of the card's button for `this-command', or nil.
The card is the one at point.  The keys of the board run the commands its
buttons run: `s' the one of [Start now], `v' that of [Verify].  An action
button is named by its command (`harness-ui-tasks--action-buttons'), so
this finds the button of the command being run when the card offers one."
  (when-let* (((symbolp this-command))
              (command this-command)
              (id (get-text-property (point) 'harness-task-id))
              (start (or (previous-single-property-change (1+ (point)) 'harness-task-id) (point-min)))
              (end (or (next-single-property-change (point) 'harness-task-id) (point-max)))
              ((harness-ui-tasks--find-button command start end)))
    (cons id command)))

(defun harness-ui-tasks--request-key ()
  "The key of the button the request now being made is for, or nil.
That is the button whose push is running (`harness-ui-tasks--pressing').
A command typed on a card has none, and is held to the button of the
same command that the card shows (`harness-ui-tasks--command-key'): it
is held down now, as a click on it would have, when it is not yet."
  (harness-ui-tasks--release-stale)
  (or harness-ui-tasks--pressing
      (when-let* ((key (harness-ui-tasks--command-key)))
        (unless (harness-ui-tasks--pressed-p key)
          (harness-ui-tasks--hold-down key))
        key)))

(defun harness-ui-tasks--count-request (key)
  "Count a request the button KEY waits for.
Return a function to call on its answer, or nil when KEY is not held
down on this board.  The function lets the count down, once however
often it is called, and settles the button (`harness-ui-tasks--settle')
when it was the last request."
  (let ((buffer (current-buffer))
        (state (and key harness-ui-tasks--pressed (gethash key harness-ui-tasks--pressed))))
    (when state
      (let ((at (plist-get state :at))
            (answered nil))
        (puthash key (plist-put state :requests (1+ (plist-get state :requests))) harness-ui-tasks--pressed)
        (lambda ()
          (unless answered
            (setq answered t)
            (when (harness-ui-tasks--board-p buffer)
              (with-current-buffer buffer
                (let ((state (and harness-ui-tasks--pressed (gethash key harness-ui-tasks--pressed))))
                  ;; Not a later push of the same button, if this one was let go.
                  (when (and state (eql (plist-get state :at) at))
                    (puthash key (plist-put state :requests (max 0 (1- (plist-get state :requests))))
                             harness-ui-tasks--pressed)
                    (harness-ui-tasks--settle key)))))))))))

(defun harness-ui-tasks--answering (key answered function)
  "FUNCTION, which handles the answer to a request, then ANSWERED.
ANSWERED is what `harness-ui-tasks--count-request' returned for the
button KEY, or nil: FUNCTION is then returned as it is.  It runs with KEY
pushed (`harness-ui-tasks--pressing'), so a request it makes is waited
for too, and the button is only settled once it has returned."
  (if (null answered)
      function
    (lambda (&rest args)
      (unwind-protect
          (let ((harness-ui-tasks--pressing key))
            (apply function args))
        (funcall answered)))))

(defun harness-ui-tasks--pressed-help (help)
  "The tooltip of a button held down: that it works, then its usual HELP."
  (if (and (stringp help) (not (string-empty-p help)))
      (concat "Working on it… " help)
    "Working on it…"))

(defun harness-ui-tasks--button (label action help &optional id)
  "Return a button string LABEL running ACTION (no arguments).
HELP is its tooltip.  ID names it for redraws, which keep point on the
same button (see `harness-ui-tasks--anchor'); it defaults to LABEL, so
a button whose label changes, a setting's value say, needs one.

On the board region a push holds the button down until the harness has
answered what the command asked for (`harness-ui-tasks--press'), and a
button held down is drawn so, in `harness-task-button-pressed-face', with
the same label.  The lines above the compose box are not drawn that way:
their buttons just run ACTION."
  (let* ((id (or id label))
         (key (and harness-ui-tasks--pressable (cons harness-ui-tasks--card-id id)))
         (down (and key (harness-ui-tasks--pressed-p key)))
         (button (propertize (buttonize label
                                        (if key
                                            (lambda (_) (harness-ui-tasks--press key action))
                                          (lambda (_) (funcall action)))
                                        nil
                                        (if down (harness-ui-tasks--pressed-help help) help))
                             'keymap harness-ui-tasks-button-map
                             'harness-task-button id)))
    (if down
        ;; The same label and the same width: only the look changes, and
        ;; the highlight under the mouse goes, as a button that is down
        ;; takes no click.
        (propertize button
                    'face 'harness-task-button-pressed-face
                    'font-lock-face 'harness-task-button-pressed-face
                    'mouse-face nil)
      button)))

(defun harness-ui-tasks--pending (task)
  "Return the request TASK's session waits on first, as a record, or nil.
See `harness-ui-pending-first'."
  (when-let* ((sid (plist-get task :session)))
    (harness-ui-pending-first sid)))

(defun harness-ui-tasks--action-buttons (task)
  "Buttons for TASK's two most useful actions besides opening it.
A task whose session waits on a request gets the buttons every view
offers for it, the session list too (`harness-ui-pending-view-actions'):
[Allow] and [Deny], or [Answer…], here followed by the board's own
\[Reply], an answer typed in the compose box."
  (let* ((id (plist-get task :id))
         (sid (plist-get task :session))
         (button (lambda (a)
                   (harness-ui-tasks--button
                    (format "[%s]" (car a))
                    (lambda () (harness-ui-tasks--with-task id (call-interactively (nth 1 a))))
                    (car a) (nth 1 a))))
         (request (and sid (eq (harness-ui-tasks--column task) 'needs-input)
                       (harness-ui-pending-view-actions
                        sid (harness-ui-tasks--on-error "Answering the permission request")))))
    (string-join
     (if request
         (append (mapcar (lambda (a) (harness-ui-tasks--button (nth 0 a) (nth 1 a) (nth 2 a))) request)
                 (and (equal (plist-get (harness-ui-pending-first sid) :kind) "question")
                      (list (funcall button '("Reply" harness-ui-tasks-reply))))
                 (and (harness-ui-tasks--pausable-p task)
                      (list (funcall button '("Pause" harness-ui-tasks-pause)))))
       (mapcar button (take 2 (cl-remove 'harness-ui-tasks-open (harness-ui-tasks--actions task t)
                                         :key #'cadr))))
     " ")))

(defun harness-ui-tasks--card-buttons (task)
  "Buttons for TASK's two most useful actions besides opening it.
A task waiting for your review that handed a report in (`hand_in') gets
a [Review Changes] button too: the changes, the final message and the
evidence, in a popout.  One whose turn ended without it gets [No report]
there instead, which pops out what the harness recorded for it: that
nothing was handed in, and the session's last message
\(`harness-tasks--missing-report').  The third button is for the work
that waits to be reviewed: on a card in any other column it was the
widest thing on the row, and the report is a SPC away
\(`harness-ui-tasks-requests') or shows in the task's own session.

A card has no button for opening its session: a click on its title
does that.  Nor for an action of `harness-ui-tasks-action-functions',
which stays in the card's menu (`mouse-3')."
  (let ((missing (harness-json-true-p (plist-get (plist-get task :report) :missing))))
    (concat
     (harness-ui-tasks--action-buttons task)
     (when (and (plist-get task :report) (eq (harness-ui-tasks--column task) 'review)
                (fboundp 'harness-ui-report-popout))
       ;; [Review Changes] rather than [Report], which reads as
       ;; reporting the agent for something bad: the button opens the
       ;; changes and the work it handed in, to look them over.
       (concat " " (harness-ui-tasks--button
                     (if missing "[No report]" "[Review Changes]")
                     (lambda () (harness-ui-report-popout task))
                     (if missing
                         "No report handed in"
                       "The changes, the summary and the evidence")
                     "report"))))))

(defun harness-ui-tasks--subtitle-button (task shown)
  "The chevron that shows or hides TASK's recap subtitle.
SHOWN is whether the subtitle shows now.  It only draws the card again,
at once: it is a disclosure triangle, not held down when pushed
\(`harness-ui-tasks--pressable'), so it can be pushed again right away."
  (let ((id (plist-get task :id))
        (harness-ui-tasks--pressable nil))
    (harness-ui-tasks--button
     (propertize (harness-ui-icon (if shown 'harness-icon-expanded 'harness-icon-collapsed))
                 'face 'harness-dim-face)
     (lambda () (harness-ui-tasks--with-task id (harness-ui-tasks-toggle-subtitle)))
     (if shown "Hide the recap" "Show the recap")
     (concat "subtitle:" id))))

;;;; Rendering

(defun harness-ui-tasks--width ()
  "Width the board is drawn for: its widest window, or 100 when hidden."
  (let ((windows (get-buffer-window-list nil nil t)))
    (if windows (apply #'max (mapcar #'window-body-width windows)) 100)))

;;; Fitting the board to the window

;; The board sits above the compose box, which stays at the bottom of
;; the window.  A board taller than the room it has would push the box
;; off the bottom, where the box's padding and scrolling would then
;; fight over the window (see `harness-compose--follow').  So the board
;; is drawn to fit: the least urgent sections cap their lists first,
;; each saying how many tasks it holds back, and a section you expanded
;; keeps its whole list until folded again.
;;
;; What fits is measured, not drawn again and again: one drawing of the
;; whole board answers how tall each card is, and the cards are then
;; held back in order until the box fits (`harness-ui-tasks--caps-that-fit').
;; The fitting is kept (`harness-ui-tasks--fitting') and drawn again as it is
;; while the board's shape -- tasks, folding, window -- is unchanged, so
;; what changes while many tasks work -- their todos, names, the clock --
;; costs a drawing of the cards the window shows, not of the whole board.

(defun harness-ui-tasks--window ()
  "Return the window the board should be drawn for.
The selected one while it shows the board, else its first visible
window, if any."
  (or (and (eq (window-buffer (selected-window)) (current-buffer)) (selected-window))
      (car (get-buffer-window-list nil nil t))))

(defun harness-ui-tasks--tail-key (window)
  "Return what the lines below the board say in WINDOW.
Their height is what the board must leave room for, and the caps depend
on it: a box that grew a line or a new attachment changes what fits."
  (when (and window harness-ui-tasks--list-end
             (< (marker-position harness-ui-tasks--list-end) (point-max)))
    ;; Without the padding: it fills the room that is left, and counting
    ;; it would make the caps depend on the board they were sized for, a
    ;; loop.  The next redisplay sizes it again.
    (harness-compose-repad window)
    (list (harness-ui-text-height window (marker-position harness-ui-tasks--list-end)
                                  (point-max) (window-body-height window t))
          (buffer-substring-no-properties (marker-position harness-ui-tasks--list-end) (point-max)))))

(defun harness-ui-tasks--fit (string room)
  "STRING shortened to ROOM columns (at least 12), keeping its properties."
  (let ((room (max 12 room)))
    (if (<= (string-width string) room)
        string
      (concat (truncate-string-to-width string (1- room)) "…"))))

(defconst harness-ui-tasks--collapse-min-width 48
  "Board width below which cards keep their second line.
A one-line card shares its line with its buttons, and below this width
the title would be left with nothing; there cards stay two lines,
whatever the columns or your own toggles say.")

(defun harness-ui-tasks--more-line (n column)
  "The line saying a section holds back N more tasks of COLUMN.
It takes the place of the cards it hides; its [Show all] button opens
them, and a section already open gets [Show fewer] instead -- but only
a section that needs to be open: see `harness-ui-tasks--moot-expansions'.
Its buttons belong to COLUMN (`harness-ui-tasks--card-id'): pushing the
[Show all] of one section holds down that one, not another's."
  (let ((start (point))
        (harness-ui-tasks--card-id column))
    (insert (if (> n 0)
                (concat (propertize (format "    %s %d more" harness-ui-tasks--ellipsis n)
                                    'face 'harness-dim-face)
                        "  ")
              "    ")
            (if (memq column harness-ui-tasks--expanded)
                (harness-ui-tasks--button "[Show fewer]" #'harness-ui-tasks-show-fewer
                                          "Fit the section to the window")
              (harness-ui-tasks--button "[Show all]" #'harness-ui-tasks-show-all
                                        "Show every task in this section"))
            "\n")
    ;; The line belongs to its column, so its buttons know which one they open.
    (put-text-property start (point) 'harness-task-more column)))

(defun harness-ui-tasks-show-all ()
  "Show every task of the section at point, however tall it makes the board."
  (interactive)
  (when-let* ((column (or (get-text-property (point) 'harness-task-section)
                          (get-text-property (point) 'harness-task-more))))
    (setq harness-ui-tasks--expanded (cons column harness-ui-tasks--expanded))
    (harness-ui-tasks--render t)
    (message "Showing all")))

(defun harness-ui-tasks-show-fewer ()
  "Let the section at point fit the window again."
  (interactive)
  (when-let* ((column (or (get-text-property (point) 'harness-task-section)
                          (get-text-property (point) 'harness-task-more))))
    (setq harness-ui-tasks--expanded (delq column harness-ui-tasks--expanded))
    (harness-ui-tasks--render t)))

(defconst harness-ui-tasks--cap-min-lines 24
  "Fewest lines of room a window must have before sections are capped.
Below that, a board of headings and notes alone helps nobody: the board
is drawn whole, scrolls under the reader, and the compose box keeps its
place at the bottom of the window (`harness-compose--follow').")

(defconst harness-ui-tasks--cap-order '(done backlog pending active review needs-input)
  "Columns the board caps, least urgent first.
The backlog waits for you, so it goes before pending, which drains by
itself; a cap hides part of a column's list, so the ones that need you
are capped last, and only ever after everything below them.")

(defun harness-ui-tasks--capping-p (line body)
  "Non-nil when a window of BODY pixels, a line being LINE, has room to cap.
Below `harness-ui-tasks--cap-min-lines' lines nothing is capped, and a
window of none (BODY or LINE nil) has nothing to cap for."
  (and line body (>= body (* line harness-ui-tasks--cap-min-lines))))

(defun harness-ui-tasks--cappable-p (groups)
  "Non-nil when some section of GROUPS may have its list capped."
  (cl-some (lambda (c)
             (and (not (memq (car c) harness-ui-tasks--folded))
                  (not (memq (car c) harness-ui-tasks--expanded))
                  (cdr (assq (car c) groups))))
           harness-ui-tasks--columns))

(defun harness-ui-tasks--empty-caps ()
  "Return every column's cap with nothing held back: (COLUMN SHOW . MORE)."
  (mapcar (lambda (c) (cons (car c) (cons nil 0))) harness-ui-tasks--columns))

(defun harness-ui-tasks--cap-cards (caps groups n)
  "Hold back N more cards in CAPS, least urgent section first.
CAPS is the alist of (COLUMN SHOW . MORE) from
`harness-ui-tasks--empty-caps'; GROUPS the tasks shown.  A section that
is folded keeps its cap; one you expanded is left whole.  Return CAPS,
and non-nil when it held a card back."
  (let ((left n) (dropped nil))
    (dolist (column harness-ui-tasks--cap-order caps)
      (when (> left 0)
        (let* ((cap (cdr (assq column caps)))
               (total (length (cdr (assq column groups))))
               (show (if (null (car cap)) total (car cap))))
          (unless (or (memq column harness-ui-tasks--folded)
                      (memq column harness-ui-tasks--expanded))
            (let ((drop (min left show)))
              (when (> drop 0)
                (setcdr (assq column caps) (cons (- show drop) (+ (cdr cap) drop)))
                (setq dropped t)
                (cl-decf left drop)))))))
    dropped))

(defun harness-ui-tasks--fits-p (window)
  "Non-nil when the whole buffer fits WINDOW, board and compose box both.
Measuring to the end of the buffer counts the box and the lines above
it exactly, wrapping and all, and `harness-ui-text-height' is exact at
the limit, so this answers \"would the box stay in the window?\" without
needing the height of text that overflows."
  (let ((body (window-body-height window t)))
    (<= (harness-ui-text-height window (point-min) (point-max) body) body)))

(defun harness-ui-tasks--draw-board (caps)
  "Draw the board region with CAPS, from the start of the buffer.
CAPS is the alist `harness-ui-tasks--cap-cards' makes, or nil for
everything.  Point is left at the end of the board.  Its buttons can be
held down (`harness-ui-tasks--pressable'), unlike those under it."
  (delete-region (point-min) harness-ui-tasks--list-end)
  (goto-char (point-min))
  (let ((harness-ui-tasks--pressable t))
    (harness-ui-tasks--insert-board caps)))

(defun harness-ui-tasks--runs (property)
  "Return (VALUE START END) for every run of PROPERTY in the board region.
In the order they show, top first; the board region ends at
`harness-ui-tasks--list-end', so the compose box is not part of it."
  (let ((pos (point-min))
        (end (marker-position harness-ui-tasks--list-end))
        out)
    (while (< pos end)
      (let ((next (next-single-property-change pos property nil end)))
        (when-let* ((value (get-text-property pos property)))
          (push (list value pos next) out))
        (setq pos next)))
    (nreverse out)))

(defun harness-ui-tasks--pixel-height (window from to)
  "Return how many pixels the text FROM and TO take in WINDOW.
An empty range takes no room."
  (if (>= from to) 0 (cdr (window-text-pixel-size window from to))))

(defun harness-ui-tasks--sections ()
  "Return (COLUMN START END) for every section drawn, in display order."
  (let ((heads (harness-ui-tasks--runs 'harness-task-section))
        (end (marker-position harness-ui-tasks--list-end))
        out)
    (while heads
      (push (list (nth 0 (car heads)) (nth 1 (car heads))
                  (or (nth 1 (cadr heads)) end))
            out)
      (setq heads (cdr heads)))
    (nreverse out)))

(defun harness-ui-tasks--caps-that-fit (window groups body)
  "Return the caps that fit WINDOW's BODY pixels, measured, not drawn.
The board region is drawn whole now; this measures it -- every card,
and everything around them -- to find the fewest cards to hold back, in
the order `harness-ui-tasks--cap-cards' holds them back.  A card takes
a line or two depending on the wrapping in WINDOW, so a measurement is
what answers; the bisection this replaces drew the whole board again
for every trial, 1 + log2(cards) of them.  GROUPS is the tasks shown,
as `harness-ui-tasks--visible' returns them."
  (let* ((line (frame-char-height (window-frame window)))
         (cards (harness-ui-tasks--runs 'harness-task-id))
         (sections (harness-ui-tasks--sections))
         (tail (marker-position harness-ui-tasks--list-end))
         (height 0)
         (shapes nil))
    ;; The board's own lines before the first heading, and below the box.
    (when sections
      (cl-incf height (harness-ui-tasks--pixel-height window (point-min) (nth 1 (car sections)))))
    (cl-incf height (harness-ui-tasks--pixel-height window tail (point-max)))
    ;; Each section: the cards it shows, top first, and the room its
    ;; heading and notes take around them.
    (while sections
      (let ((end (nth 2 (car sections)))
            (pos (nth 1 (car sections)))
            (heights nil))
        (while (and cards (< (nth 1 (car cards)) end))
          (let ((card (pop cards)))
            (cl-incf height (harness-ui-tasks--pixel-height window pos (nth 1 card)))
            (let ((card-height (harness-ui-tasks--pixel-height window (nth 1 card) (nth 2 card))))
              (push card-height heights)
              (cl-incf height card-height))
            (setq pos (nth 2 card))))
        (cl-incf height (harness-ui-tasks--pixel-height window pos end))
        (push (cons (nth 0 (car sections)) (nreverse heights)) shapes))
      (setq sections (cdr sections)))
    (setq shapes (nreverse shapes))
    ;; What holding each card back saves, in the order the caps take
    ;; them: the least urgent section first, its last card first, and the
    ;; first card of a section costs the line saying how many it holds.
    (let ((needed (- height body))
          (savings nil))
      (dolist (column harness-ui-tasks--cap-order)
        (unless (or (memq column harness-ui-tasks--folded)
                    (memq column harness-ui-tasks--expanded))
          (let ((heights (cdr (assq column shapes))))
            (when heights
              (push (- (car (last heights)) line) savings)
              (dolist (card-height (butlast heights))
                (push card-height savings))))))
      (setq savings (nreverse savings))
      (let ((saved 0)
            (held 0)
            (n (length savings)))
        (while (and (< saved needed) (< held n))
          (cl-incf saved (nth held savings))
          (cl-incf held))
        (let ((caps (harness-ui-tasks--empty-caps)))
          (when (> held 0) (harness-ui-tasks--cap-cards caps groups held))
          caps)))))

(defun harness-ui-tasks--held (caps)
  "Return how many cards CAPS hold back."
  (cl-loop for cap in caps sum (cdr (cdr cap))))

(defun harness-ui-tasks--cappable (groups)
  "Return how many cards of GROUPS the caps may hold back, at most.
That is every card in a section `harness-ui-tasks--cap-cards' takes
from: the board can hold back no more, whatever the window."
  (cl-loop for column in harness-ui-tasks--cap-order
           unless (or (memq column harness-ui-tasks--folded)
                      (memq column harness-ui-tasks--expanded))
           sum (length (cdr (assq column groups)))))

;;; Sections opened with [Show all]

;; A section you open with [Show all] shows every task and ends in a
;; [Show fewer] line.  The line is only worth having while folding the
;; section back would change something: while the window would hold
;; some of its cards back.  A list that has shrunk since -- tasks
;; archived, completed, moved on -- fits whole, and the line would do
;; nothing; so the expansion is forgotten, the line goes with it, and a
;; list that grows past the window again is capped again, with its
;; [Show all].
;;
;; The fitting says it without measuring anything more.  It caps the
;; sections least urgent first (`harness-ui-tasks--cap-order') until the
;; box fits and leaves the open ones whole.  Were a section not open, it
;; would be capped as soon as the fitting reached it: when the board
;; still overflows with everything else capped, or when the fitting had
;; to cap a section after it in that order, a more urgent one, to make
;; room.  Otherwise folding it changes nothing
;; (`harness-ui-tasks--needs-open-p').  That is asked once for each
;; shape the board is fitted to (`harness-ui-tasks--expansions-checked'),
;; not on every redraw.

(defvar-local harness-ui-tasks--expansions-checked nil
  "The fit shape for which the board last checked its expansions.
While the shape (`harness-ui-tasks--fit-shape') is the same, the
sections in `harness-ui-tasks--expanded' are known to need it:
`harness-ui-tasks--fit-board' asks again only when it changes.")

(defun harness-ui-tasks--needs-open-p (column caps groups overflow)
  "Non-nil when COLUMN's section needs to be open for the board to fit as CAPS.
CAPS is the fitting made with the open sections left whole, as
`harness-ui-tasks--fit-board' makes it; GROUPS the tasks shown, as
`harness-ui-tasks--visible' returns them with the filter; OVERFLOW is
non-nil when the board still does not fit its window drawn that way.

Were the section not open, the fitting would cap it when it reached it,
in `harness-ui-tasks--cap-order': so it needs to be when the board
overflows even with everything else capped, or when the fitting capped
a section after it, a more urgent one.  A section with nothing to hold
back, or that is never capped, needs nothing."
  (let ((rank (cl-position column harness-ui-tasks--cap-order)))
    (and rank
         (cdr (assq column groups))
         (or overflow
             (cl-loop for later in (nthcdr (1+ rank) harness-ui-tasks--cap-order)
                      thereis (> (or (cddr (assq later caps)) 0) 0))))))

(defun harness-ui-tasks--moot-expansions (caps)
  "Return the sections you opened that the board, fitted as CAPS, did not need.
Their [Show fewer] would change nothing (`harness-ui-tasks--needs-open-p').
Call it once the board is drawn and fitted: it asks whether the board
as drawn still overflows its window.  Every open section is moot in a
window too small to cap anything (`harness-ui-tasks--capping-p').

Nil, which leaves them be, without a window to judge by -- a board
nobody sees keeps what you opened -- for a folded section, of which
nothing shows, and while the board's shape is the one last checked."
  (let ((open (cl-remove-duplicates
               (cl-remove-if (lambda (c) (memq c harness-ui-tasks--folded))
                             harness-ui-tasks--expanded)))
        (window (harness-ui-tasks--window)))
    (when (and open window)
      (let ((shape (harness-ui-tasks--fit-shape window)))
        (unless (equal shape harness-ui-tasks--expansions-checked)
          (let ((moot (if (harness-ui-tasks--capping-p (frame-char-height (window-frame window))
                                                       (window-body-height window t))
                          (let ((groups (harness-ui-tasks--visible t))
                                (overflow (not (harness-ui-tasks--fits-p window))))
                            (cl-remove-if (lambda (c)
                                            (harness-ui-tasks--needs-open-p c caps groups overflow))
                                          open))
                        open)))
            (unless moot (setq harness-ui-tasks--expansions-checked shape))
            moot))))))

(defvar-local harness-ui-tasks--fitting nil
  "The board's last fitting: (SHAPE . CAPS).
SHAPE, from `harness-ui-tasks--fit-shape', is what the fitting depends
on.  While it is unchanged, `harness-ui-tasks--fit-board' draws with
CAPS again without measuring: what changes while a task works -- its
todos, its name, the clock -- only changes what the cards read, so a
board that many tasks are updating draws its window's cards only.")

(defun harness-ui-tasks--fit-shape (window)
  "Return what fitting the board to WINDOW depends on.
The tasks and their order, the folding and the subsections shown, the
room the window has and the lines the board must leave for the compose
box: everything that decides which cards show and how tall they are.
Not what only changes what a card reads -- a session's todos, status or
name, the clock -- so the caps of a board many tasks are updating stay
good while their cards change."
  (list window
        (window-body-width window t)
        (window-body-height window t)
        (car (harness-ui-tasks--tail-key window))
        harness-ui-tasks--tasks
        harness-ui-tasks--folded
        harness-ui-tasks--expanded
        harness-ui-tasks--subtitles
        harness-ui-tasks--submitting
        harness-ui-tasks--show-archived
        harness-ui-tasks--loading
        harness-ui-tasks-filter))

(defun harness-ui-tasks--fit-board ()
  "Draw the board, holding back the least urgent cards until the box fits.
The board region is drawn whole and measured: when the compose box
would not stay in the window, the fewest cards that must be held back
are found by measuring what each holds -- its own lines, and the line a
capped section costs -- in the order `harness-ui-tasks--cap-cards'
holds them back (`harness-ui-tasks--caps-that-fit'), where a bisection
would draw the whole board again for every trial.  Each capped section
gets the line that says how many it holds and its [Show all].

A fitting is kept for the next redraw of the same shape in the same
window (`harness-ui-tasks--fitting'), so what changes while tasks work
-- todos, names, elapsed times -- costs one drawing of the cards the
window shows, not a measurement and a drawing of every card.

Nothing is capped without a window, when the window has no room to
speak of, or when everything is folded away or expanded: the board then
scrolls, and the box keeps its place at the bottom of the window.

Last, the sections you opened with [Show all] that the fitting did not
need open are closed, and the board is fitted again without them, so
their [Show fewer] goes (`harness-ui-tasks--moot-expansions').  That is
asked when the shape changes, not on every redraw."
  (let* ((window (harness-ui-tasks--window))
         (line (and window (frame-char-height (window-frame window))))
         (body (and window (window-body-height window t)))
         (groups (harness-ui-tasks--visible))
         (empty (harness-ui-tasks--empty-caps))
         (shape (and window (harness-ui-tasks--fit-shape window)))
         (caps
          (cond
           ((or (not (harness-ui-tasks--capping-p line body))
                (not (harness-ui-tasks--cappable-p groups)))
            (setq harness-ui-tasks--fitting nil)
            (harness-ui-tasks--draw-board nil)
            nil)
           ;; The same shape, drawn the same way: the caps still fit it (the
           ;; check is for a card that grew where the shape said it would not),
           ;; and drawing them covers what changed.
           ((and (equal shape (car-safe harness-ui-tasks--fitting))
                 (progn (harness-ui-tasks--draw-board (cdr harness-ui-tasks--fitting))
                        (harness-ui-tasks--fits-p window)))
            (cdr harness-ui-tasks--fitting))
           (t
            (harness-ui-tasks--draw-board empty)
            (let ((caps (if (harness-ui-tasks--fits-p window)
                            empty
                          (harness-ui-tasks--caps-that-fit window groups body))))
              (harness-ui-tasks--draw-board caps)
              ;; A "N more" line that wraps, or a card taller than the shape
              ;; said, can leave the drawing taller than it measured: hold back
              ;; one card at a time until the box fits, as the measurement
              ;; promised it would.
              (let ((held (harness-ui-tasks--held caps))
                    (total (harness-ui-tasks--cappable groups)))
                (while (and (< held total) (not (harness-ui-tasks--fits-p window)))
                  (cl-incf held)
                  (setq caps (harness-ui-tasks--empty-caps))
                  (harness-ui-tasks--cap-cards caps groups held)
                  (harness-ui-tasks--draw-board caps)))
              (setq harness-ui-tasks--fitting (cons shape caps))
              caps))))
         (moot (harness-ui-tasks--moot-expansions caps)))
    (if (null moot)
        caps
      ;; They change the shape: noted as checked before the board is
      ;; fitted again, which then asks nothing, so this cannot go round.
      (setq harness-ui-tasks--expanded
            (cl-remove-if (lambda (c) (memq c moot)) harness-ui-tasks--expanded)
            harness-ui-tasks--expansions-checked
            (harness-ui-tasks--fit-shape (harness-ui-tasks--window)))
      (harness-ui-tasks--fit-board))))

;;; A section's cards, in columns

;; The cards of a section are laid out together, so that what they say
;; reads in the same place on every one: the facts in a column for each
;; kind (`harness-ui-tasks--fact-kinds'), the buttons in a zone of their
;; own, the titles from one column.  Each is a column of its own, wide
;; as the widest thing in it, which every card of the section keeps,
;; whether it has something to put there or not; and each starts with
;; a space aligned to it (`harness-ui-tasks--align'), so what a card has
;; to its left, an icon or an arrow drawn wider or narrower than the
;; characters that stand for it, cannot move what follows.
;;
;;   TITLE START                          FACTS (right-aligned)   BUTTONS
;;   v ● ↑ Fix stuck model response in the dispatcher   1/4  12m  [Steer] [Pause]
;;   v ●   Write the OpenAPI schema for the endpoints        4m  [Steer] [Pause]
;;
;; The title comes first.  A row states little -- state flags, how far
;; along a task is, when -- and says what is left to say about the
;; session, its context, tokens, rate and cost, in the tooltip of the
;; title.  What a row does state gives way to its title, a card at a
;; time (`harness-ui-tasks--plan'): the todo count first, then the time.
;; A title that still would not fit beside its buttons has the line to
;; itself: the facts and the buttons, together, go to a second line under
;; it, in the same columns.  A title is cut only when it is longer than
;; the window.
;;
;; A card is taken apart first (`harness-ui-tasks--card-parts'), the
;; section's layout found from all its cards (`harness-ui-tasks--layout'),
;; and then each card is drawn in it (`harness-ui-tasks--insert-part').
;; A card computes its facts once, whatever room there turns out to be.

(defun harness-ui-tasks--align (spec kind)
  "A space reaching SPEC, an `:align-to' column or expression, where KIND starts.
KIND, `title', `zone' or a kind of fact, is its `harness-task-column'."
  (propertize " " 'display (list 'space :align-to spec) 'harness-task-column kind))

(defun harness-ui-tasks--align-right (distance kind)
  "A space reaching DISTANCE columns left of the window's right edge.
KIND is what starts there, as for `harness-ui-tasks--align'."
  (harness-ui-tasks--align (list '- 'right distance) kind))

(defun harness-ui-tasks--string-pixels (string)
  "How many pixels wide STRING is drawn on the selected frame.
`string-width' counts an image, and a space of a width in pixels, as
the one character that stands for it; here an image is as wide as it
is (`image-size') and a space as wide as it says, and text takes the
columns it takes.  Where images cannot be measured (a terminal) it is
the columns."
  (let ((char (frame-char-width))
        (length (length string))
        (pos 0)
        (pixels 0))
    (while (< pos length)
      (let* ((end (or (next-single-property-change pos 'display string) length))
             (spec (get-text-property pos 'display string))
             (width (pcase (car-safe spec)
                      ('image (ignore-errors (car (image-size spec t))))
                      ('space (let ((pad (plist-get (cdr spec) :width)))
                                (and (consp pad) (numberp (car pad)) (car pad)))))))
        (cl-incf pixels (or width (* char (string-width string pos end))))
        (setq pos end)))
    pixels))

(defun harness-ui-tasks--card-parts (task column position narrow)
  "TASK's card in COLUMN, taken apart for the section's layout: a plist.
POSITION is TASK's place in line among queued tasks; NARROW is non-nil
on a board too narrow for one-line cards
\(`harness-ui-tasks--collapse-min-width').  It has `:task', `:column',
`:session' and `:position' as given, and:

`:left'     what comes before the title: the chevron that shows the
           recap, and the icon, padded to line up with the others
`:mark'     the arrow of a high or low priority, with its space, else \"\"
`:title'    the title, whole: the room it needs
`:cells'    the facts, as `harness-ui-tasks--facts' makes them
`:buttons'  its buttons, made with TASK's id in `harness-ui-tasks--card-id',
           which they are held down by
`:shown'    non-nil when the card has its recap line, so is two lines: the
           facts stay on the first and the buttons go to the second"
  (let* ((harness-ui-tasks--card-id (plist-get task :id))
         (session (harness-ui-tasks--session task))
         (buttons (harness-ui-tasks--card-buttons task))
         (shown (or (harness-ui-tasks--subtitle-shown-p task) narrow))
         (chevron (if narrow "" (harness-ui-tasks--subtitle-button task shown)))
         (icon (harness-ui-tasks--icon task column session))
         ;; The blocked mark is an image about a column wider than the
         ;; one-column stopped square, with its ink centred in it: move
         ;; it half that extra width left, so the two marks share a
         ;; centre.  The section's layout starts the titles at one column
         ;; whatever the marks to their left take.  A terminal's
         ;; one-column pause symbol needs none of this.
         (pause (and (eq column 'needs-input)
                     (harness-session-waiting-on-user-p session)
                     (harness-ui-tasks--wide-icon-p icon)))
         (nudge (and pause (harness-ui-tasks--mark-nudge icon)))
         (left (concat (cond ((not nudge)
                              (concat "  " (if (string-empty-p chevron) "" (concat chevron " "))))
                             ((string-empty-p chevron)
                              (concat " " (harness-ui-tasks--pad (- (frame-char-width) nudge))))
                             (t (concat "  " chevron
                                        (harness-ui-tasks--pad (- (frame-char-width) nudge)))))
                       icon
                       (if nudge (harness-ui-tasks--pad (+ (frame-char-width) nudge)) " "))))
    (list :task task :column column :session session :position position
          :left left
          ;; High or low priority, before the title: the only thing on
          ;; the card that says it, so it stays whatever else makes way
          ;; for the title.
          :mark (harness-ui-tasks--priority-mark task column)
          :title (harness-ui-tasks--title task)
          :cells (harness-ui-tasks--facts task column session)
          :buttons buttons
          :shown shown)))

(defun harness-ui-tasks--geometry (cell-lists kinds title-col zone reserve width)
  "The layout of the cards drawing CELL-LISTS in WIDTH columns.
CELL-LISTS has one alist (KIND . TEXT) for each card, the facts it
draws, and KINDS the kinds of fact there can be, in order.  TITLE-COL,
ZONE and RESERVE are as `harness-ui-tasks--layout' finds them.  The
columns of the facts come right to left: the buttons zone first, when
RESERVE says that some card has its buttons beside its facts or under
them (it takes one column's room off the window's right edge, as a card
has always left one), then each kind's column, two apart, wide as its
widest cell.  A kind no card draws has no column.  `:ends' says how
far from the window's right edge each ends."
  (let* ((columns (cl-loop for kind in kinds
                           for wide = (cl-loop for cells in cell-lists
                                               maximize (if-let* ((cell (cdr (assq kind cells))))
                                                            (string-width cell)
                                                          0))
                           when (> wide 0) collect (cons kind wide)))
         (edge (+ 1 reserve (if (and columns (> reserve 0)) 2 0)))
         (ends nil))
    (dolist (column (reverse columns))
      (push (cons (car column) edge) ends)
      (setq edge (+ edge (cdr column) 2)))
    (list :title-col title-col :zone zone :reserve reserve :ends ends :width width
          ;; Under a title there is room for its recap up to the zone.
          :sub-room (- width zone 8))))

(defun harness-ui-tasks--line-start (cells beside layout)
  "How far left of the window's right edge a card's first line reaches in LAYOUT.
That is where the leftmost of what comes after its title starts: one of
its facts, CELLS, or its buttons when BESIDE says they share the line.  A
column of the layout it has no fact for takes none of its room, so a
title may run on until its own facts."
  (let ((start 1)
        (ends (plist-get layout :ends)))
    (dolist (cell cells)
      (when-let* ((end (cdr (assq (car cell) ends))))
        (setq start (max start (+ end (string-width (cdr cell)))))))
    (when beside
      (setq start (max start (1+ (plist-get layout :zone)))))
    start))

(defun harness-ui-tasks--beside-p (part plan)
  "Non-nil when the buttons of card PART are beside its title, as PLAN has it.
They share the first line with the title and the facts.  A card with the
recap line, or that PLAN stacked, has them under its title."
  (and (> (string-width (plist-get part :buttons)) 0)
       (not (plist-get part :shown))
       (not (plist-get plan :stack))))

(defconst harness-ui-tasks--fact-give-up '(nil (todos) (todos time))
  "What a card leaves out of its facts, a little at a time, for its title.
Each entry is a list of kinds (`harness-ui-tasks--fact-kinds') to leave
out: none; the todo count; that and the time, which is all a row says of
how a task is doing, so informational.  The rest is state -- archived,
main tree, a borrowed slot, a merge in conflict -- which a card keeps
until its title has no other way to fit (`harness-ui-tasks--plan').")

(defun harness-ui-tasks--stackable-p (part)
  "Non-nil when the buttons of card PART can go to a second line under its title.
That is when it has buttons and no recap line, which has the second line."
  (and (> (string-width (plist-get part :buttons)) 0)
       (not (plist-get part :shown))))

(defun harness-ui-tasks--plan (part step)
  "What card PART draws when it has given up STEP times for its title: a plist.
`:cells' are the facts it draws, `:stack' non-nil when the facts and the
buttons go to a second line under the title, which then has the first to
itself.  The title is the point of the card and comes first, so a card
that has not the room for it gives up what it says a little at a time
\(`harness-ui-tasks--layout'): step 0 is everything, beside its buttons;
1 leaves out the todo count; 2 the time too, which are informational
\(`harness-ui-tasks--fact-give-up'); and 3, the last, stacks the card,
keeping all its facts -- nothing is left out for a title that has the
line to itself.  A card that cannot stack (`harness-ui-tasks--stackable-p':
it shows its recap, or has no buttons) leaves out its state too, last of
all."
  (let ((cells (plist-get part :cells)))
    (cond ((< step 3)
           (list :cells (cl-remove-if (lambda (cell) (memq (car cell) (nth step harness-ui-tasks--fact-give-up)))
                                      cells)))
          ((harness-ui-tasks--stackable-p part) (list :cells cells :stack t))
          (t (list :cells nil)))))

(defun harness-ui-tasks--room (part plan layout)
  "The room the title of card PART has in LAYOUT, drawn as PLAN has it.
That is what is left of its first line past where its title starts, less
the column the window's edge keeps and the two a title leaves before
what follows it."
  (- (plist-get layout :width)
     (harness-ui-tasks--line-start (unless (plist-get plan :stack) (plist-get plan :cells))
                                   (harness-ui-tasks--beside-p part plan) layout)
     (plist-get layout :title-col) 2))

(defun harness-ui-tasks--layout (parts width)
  "How the cards PARTS of a section, taken apart, are laid out in WIDTH columns.
A plist, from `harness-ui-tasks--geometry':

`:title-col'  the column every title starts at: right of the widest left
              part and of the room for the arrow of a priority, if
              any card has one, whichever card has it
`:zone'       how wide the buttons zone is, wide as the widest buttons;
              the buttons of every card start at its left edge
`:reserve'    the room the facts leave the zone: its width while some
              card has its buttons on a line with its facts or under
              them, else none
`:ends'       ((KIND . END)...) the columns of the facts, left to right
`:sub-room'   the room left for the recap line, up to the zone
`:plans'      what each card draws, in the order of PARTS
              (`harness-ui-tasks--plan')

The title of a card is whole wherever a line has room for it.  Every
card starts by drawing everything; the cards whose title has no room in
the layout that makes give up one step more (`harness-ui-tasks--plan'),
and the facts are laid out again, in the columns of what is drawn, so
that a column no card draws takes no room.  That goes on until every
title fits or its card has nothing left to give up.  The columns are the
section's, and what a card gives up its own: the rest stay in line."
  (let* ((char (frame-char-width))
         (title-col (ceiling (+ (cl-loop for part in parts
                                         maximize (harness-ui-tasks--string-pixels (plist-get part :left)))
                                (cl-loop for part in parts
                                         maximize (harness-ui-tasks--string-pixels (plist-get part :mark))))
                             char))
         (zone (cl-loop for part in parts maximize (string-width (plist-get part :buttons))))
         ;; The facts stop short of the zone unless every card has its
         ;; recap line: the buttons of a card with it are on the second
         ;; line, with nothing of the facts, which stay on the first.
         (reserve (if (cl-some (lambda (part) (not (plist-get part :shown))) parts) zone 0))
         (kinds (cl-remove-if-not (lambda (kind)
                                    (cl-some (lambda (part) (assq kind (plist-get part :cells))) parts))
                                  harness-ui-tasks--fact-kinds))
         (steps (make-list (length parts) 0))
         layout plans changed)
    (setq changed t)
    (while changed
      (setq plans (cl-mapcar #'harness-ui-tasks--plan parts steps)
            layout (harness-ui-tasks--geometry (mapcar (lambda (plan) (plist-get plan :cells)) plans)
                                               kinds title-col zone reserve width)
            changed nil
            steps (cl-mapcar (lambda (part plan step)
                               (if (and (< step 3)
                                        (< (harness-ui-tasks--room part plan layout)
                                           (string-width (plist-get part :title))))
                                   (progn (setq changed t) (1+ step))
                                 step))
                             parts plans steps)))
    (plist-put layout :plans plans)))

(defun harness-ui-tasks--insert-cells (cells ends)
  "Insert CELLS, the facts of a card, in the columns ENDS says."
  ;; A cell ends where its column does, and so starts further left the
  ;; wider it is.
  (dolist (cell cells)
    (when-let* ((end (cdr (assq (car cell) ends))))
      (insert (harness-ui-tasks--align-right (+ end (string-width (cdr cell))) (car cell))
              (cdr cell)))))

(defun harness-ui-tasks--insert-part (part layout plan)
  "Insert the card PART in LAYOUT, as PLAN has it, at point.
PART is `harness-ui-tasks--card-parts', LAYOUT `harness-ui-tasks--layout'
and PLAN one of its `:plans' (`harness-ui-tasks--plan').
The card is one line, two when its recap shows or PLAN stacked it; its
text has the task's id as its `harness-task-id' property.  The title
gets what is left of its line, and the facts, right-aligned in their
columns, come after it, then the buttons, which start at the zone's left
edge.  With the recap, the buttons are on the second line, after the
recap and the facts stay on the first.  Stacked, the title is alone on
the first and the second has the facts and the buttons."
  (let* ((task (plist-get part :task))
         (column (plist-get part :column))
         (buttons (plist-get part :buttons))
         (cells (plist-get plan :cells))
         (stack (plist-get plan :stack))
         (beside (harness-ui-tasks--beside-p part plan))
         (zone-at (1+ (plist-get layout :zone)))
         (ends (plist-get layout :ends))
         (start (point))
         (room (- (plist-get layout :width)
                  (harness-ui-tasks--line-start (unless stack cells) beside layout)
                  (plist-get layout :title-col) 2)))
    (insert (plist-get part :left) (plist-get part :mark)
            (harness-ui-tasks--align (plist-get layout :title-col) 'title)
            (propertize (harness-ui-tasks--fit (plist-get part :title) room)
                        'face (if (eq column 'done) 'default 'harness-task-title-face)
                        'mouse-face 'highlight
                        'help-echo #'harness-ui-tasks--title-help))
    (unless stack
      (harness-ui-tasks--insert-cells cells ends))
    (when beside
      (insert (harness-ui-tasks--align-right zone-at 'zone) buttons))
    (insert "\n")
    (when (or (plist-get part :shown) stack)
      (insert "      ")
      (cond ((plist-get part :shown)
             (insert (harness-ui-tasks--subtitle task column (plist-get part :session) (plist-get part :position)
                                                 (plist-get layout :sub-room))))
            (stack (harness-ui-tasks--insert-cells cells ends)))
      (when (> (string-width buttons) 0)
        (insert (harness-ui-tasks--align-right zone-at 'zone) buttons))
      (insert "\n"))
    (put-text-property start (point) 'harness-task-id (plist-get task :id))))

(defun harness-ui-tasks--insert-cards (column entries)
  "Insert the cards of COLUMN at point, laid out together.
ENTRIES are (TASK . POSITION) for the tasks to draw, in order, POSITION
being TASK's place in line among queued tasks."
  (when entries
    (let* ((width (harness-ui-tasks--width))
           (narrow (< width harness-ui-tasks--collapse-min-width))
           (parts (mapcar (lambda (entry)
                            (harness-ui-tasks--card-parts (car entry) column (cdr entry) narrow))
                          entries))
           (layout (harness-ui-tasks--layout parts width)))
      (cl-mapc (lambda (part plan) (harness-ui-tasks--insert-part part layout plan))
               parts (plist-get layout :plans)))))

(defun harness-ui-tasks--insert-card (task column position)
  "Insert the card of TASK in COLUMN at point, laid out as a section of one.
POSITION is TASK's place in line among queued tasks.  The cards of a
section are drawn together: see `harness-ui-tasks--insert-cards'."
  (harness-ui-tasks--insert-cards column (list (cons task position))))

(defun harness-ui-tasks--insert-section (column heading tasks &optional cap)
  "Draw COLUMN: HEADING, its TASKS and, with CAP (SHOW . MORE), the cap.
SHOW of the tasks are drawn, in order, and its line says how many MORE
the window is too small for.  The headings of Pending and Backlog have
their column's switch right after the count, folded or not: whether the
queue starts its tasks on its own (`harness-ui-tasks--queue-button'),
and whether written-up tasks are queued by hand or by themselves
\(`harness-ui-tasks--backlog-mode-button')."
  (let* ((folded (memq column harness-ui-tasks--folded))
         (start (point))
         (head (concat
                (propertize (harness-ui-icon (if folded 'harness-icon-collapsed 'harness-icon-expanded))
                            'face 'harness-dim-face)
                " " (propertize heading 'face (pcase (and tasks column)
                                                ('needs-input '(harness-task-attention-face harness-task-section-face))
                                                ('review '(harness-task-review-face harness-task-section-face))
                                                (_ 'harness-task-section-face)))
                (propertize (format "  %d" (length tasks)) 'face 'harness-dim-face)))
         ;; Beside the count, not at the far right: the switch is the
         ;; column's, and reads with its name.
         (switch (pcase column
                   ('pending (harness-ui-tasks--queue-button))
                   ('backlog (harness-ui-tasks--backlog-mode-button))))
         (archive (and (eq column 'done) tasks (not folded)
                       (harness-ui-tasks--button "[Archive all]" #'harness-ui-tasks-archive-done
                                                 "Archive every completed task" 'harness-ui-tasks-archive-done))))
    (insert head (if switch (concat "  " switch) ""))
    (when archive
      (insert (propertize " " 'display `(space :align-to (- right ,(1+ (string-width archive))))) archive))
    (insert "\n")
    (put-text-property start (point) 'harness-task-section column)
    (unless folded
      (when (eq column 'pending)
        (dolist (text (reverse harness-ui-tasks--submitting))
          (insert (propertize (format "  %s %s  submitting…\n"
                                      (harness-ui-icon 'harness-icon-task-pending)
                                      ;; Fitted, like the cards: the buffer wraps.
                                      (harness-ui-tasks--fit
                                       (harness-first-line text 60)
                                       (- (harness-ui-tasks--width) 17
                                          (string-width (harness-ui-icon 'harness-icon-task-pending)))))
                              'face 'harness-dim-face))))
      (let ((shown (if cap (car cap) nil))
            (more (if cap (cdr cap) 0)))
        (cond
         ((and (null tasks) (not (and (eq column 'pending) harness-ui-tasks--submitting)))
          (insert (propertize (pcase column
                                ('needs-input "    nothing needs you\n")
                                ('review "    nothing to review\n")
                                ('merging "    the merge queue is empty\n")
                                ('active "    nothing working\n")
                                ('pending "    no tasks waiting\n")
                                ('backlog "    nothing in the backlog\n")
                                (_ "    none yet\n"))
                              'face 'harness-dim-face)))
         (t
          ;; Only queued tasks have a place in line; a backlog card
          ;; starts only when you start it.  The cards are laid out as
          ;; one: what they say lines up from card to card.
          (let ((queued 0))
            (harness-ui-tasks--insert-cards
             column
             (mapcar (lambda (task) (cons task (and (eq column 'pending) (cl-incf queued))))
                     (if shown (seq-take tasks shown) tasks))))))
        ;; The line for a section the window is too small for, or one open
        ;; past the room the window has, which folds it back.
        (when (or (> more 0) (memq column harness-ui-tasks--expanded))
          (harness-ui-tasks--more-line more column)))
      (insert "\n"))))

(defun harness-ui-tasks--insert-board (&optional caps)
  "Draw the board region, with CAPS from `harness-ui-tasks--fit-board'.
CAPS is the alist of (COLUMN SHOW . MORE), or nil to draw everything."
  (cond
   ((and harness-ui-tasks--loading (null harness-ui-tasks--tasks))
    (insert (propertize "\n  loading tasks…\n" 'face 'harness-dim-face)))
   (t
    (insert "\n")
    (let* ((filter harness-ui-tasks-filter)
           (groups (harness-ui-tasks--visible t)))
      ;; A filter says what it shows, above the columns that hold it.
      (when filter
        (insert (or (ignore-errors (funcall (plist-get filter :banner))) "")))
      (if (and (null harness-ui-tasks--tasks) (null harness-ui-tasks--submitting) (null filter))
          (insert (propertize "  No tasks yet.\n\n" 'face 'harness-dim-face))
        (dolist (c harness-ui-tasks--columns)
          (let ((tasks (cdr (assq (car c) groups))))
            ;; With review off nothing comes to review: the column shows
            ;; only while tasks from before still wait there.
            (unless (or (and (eq (car c) 'review) (null tasks) (not (harness-ui-tasks--review-p)))
                        (and filter (null tasks)))
              (harness-ui-tasks--insert-section (car c) (cadr c) tasks
                                                (cdr (assq (car c) caps)))))))))))
;;;; Point across redraws

;; The board is drawn again whenever a task or a session changes and on
;; every tick of the clock, the lines above the box on every reload.
;; Point and the windows showing the board stay where they were all the
;; same: on the same line of the same card -- its buttons are on the
;; second -- and on the same button, or a key pressed there would land
;; somewhere else.

(defconst harness-ui-tasks--line-keys '(harness-task-id harness-task-section harness-task-tail)
  "Text properties naming what the lines of a board belong to.
A task's card, a column's heading, or one of the lines above the box.")

(defun harness-ui-tasks--line-key (pos)
  "Return (PROPERTY . VALUE) naming what the text at POS belongs to, or nil."
  (cl-loop for prop in harness-ui-tasks--line-keys
           for value = (get-text-property pos prop)
           when value return (cons prop value)))

(defun harness-ui-tasks--key-start (key)
  "Return where the text KEY names starts, or nil when there is none.
KEY is a (PROPERTY . VALUE) from `harness-ui-tasks--line-key'."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward (car key) (cdr key) #'equal)))
      (prop-match-beginning match))))

(defun harness-ui-tasks--box-start ()
  "Where the compose box's line starts, prompt included; nil before it is drawn."
  (and (harness-compose-live-p) harness-compose-overlay
       (eq (overlay-buffer harness-compose-overlay) (current-buffer))
       (overlay-start harness-compose-overlay)))

(defun harness-ui-tasks--button-at (pos)
  "Return (ID START END) of the button at POS, or nil.
ID is what `harness-ui-tasks--button' named it, else its label."
  (when (get-text-property pos 'button)
    (let* ((id (get-text-property pos 'harness-task-button))
           (prop (if id 'harness-task-button 'button))
           (start (or (previous-single-property-change (1+ pos) prop) (point-min)))
           (end (or (next-single-property-change pos prop) (point-max))))
      (list (or id (buffer-substring-no-properties start end)) start end))))

(defun harness-ui-tasks--find-button (id from to)
  "Return (ID START END) of the button named ID between FROM and TO, or nil."
  (let ((pos from) found)
    (while (and (not found) (< pos to))
      (let ((button (harness-ui-tasks--button-at pos)))
        (if (and button (equal (car button) id))
            (setq found button)
          (setq pos (if button (nth 2 button) (or (next-single-property-change pos 'button nil to) to))))))
    found))

(defun harness-ui-tasks--aligned-p (pos)
  "Non-nil when POS is right of a space aligned to the right edge on its line.
What is there is aligned to the window's right edge: a card's facts or
buttons (`harness-ui-tasks--align-right').  The space that starts a
card's title is aligned to a column, not the edge, and a pad of a width
in pixels aligns nothing: a position in the title stays as many
characters in from the start of the line."
  (let ((bol (save-excursion (goto-char pos) (line-beginning-position))))
    (cl-loop for p from (1- pos) downto bol
             thereis (let ((display (get-text-property p 'display)))
                       (and (eq (car-safe display) 'space)
                            (consp (plist-get (cdr display) :align-to)))))))

(defun harness-ui-tasks--anchor (pos)
  "Return where POS is on the board in terms a redraw keeps; nil before one.
In the compose box, its prompt included, that is (box . OFFSET) from the
box's start, and after the box (eob).  Anywhere else it is
\(KEY LINE COLUMN BUTTON POS):

KEY names the card, heading or line above the box POS is on, else the
nearest one above it (nil above them all), as `harness-ui-tasks--line-key'
does, and LINE counts the lines from KEY's first one down to POS's: a
card has two, its buttons on the second.

COLUMN is POS's place on its line: (start . N) characters in, or
\(end . N) from the end right of an :align-to space, where the text
aligned to the right edge stays when the text on its left changes length.

BUTTON is (ID . OFFSET) when POS is on a button: ID as
`harness-ui-tasks--button-at' returns it, OFFSET into the button.

POS itself places what KEY no longer finds: a task gone."
  (when harness-ui-tasks--list-end
    (let ((box (harness-ui-tasks--box-start)))
      (cond
       ((and box (> pos harness-compose-end)) (list 'eob))
       ((and box (>= pos box)) (cons 'box (- pos harness-compose-start)))
       (t
        (save-excursion
          (goto-char pos)
          (let* ((bol (line-beginning-position))
                 (column (if (harness-ui-tasks--aligned-p pos)
                             (cons 'end (- (line-end-position) pos))
                           (cons 'start (- pos bol))))
                 (button (when-let* ((b (harness-ui-tasks--button-at pos)))
                           (cons (car b) (- pos (nth 1 b)))))
                 (line 0)
                 key)
            (goto-char bol)
            ;; Up to the nearest line that belongs to something...
            (while (and (null (setq key (harness-ui-tasks--line-key (point)))) (not (bobp)))
              (forward-line -1)
              (cl-incf line))
            ;; ...and up to its first line.
            (while (and key (not (bobp)) (equal key (harness-ui-tasks--line-key (1- (point)))))
              (forward-line -1)
              (cl-incf line))
            (list key line column button pos))))))))

(defun harness-ui-tasks--key-end (start key)
  "Where the text KEY names, which starts at START, ends."
  (or (next-single-property-change start (car key) nil (point-max)) (point-max)))

(defun harness-ui-tasks--anchor-position (anchor)
  "Return the position ANCHOR, from `harness-ui-tasks--anchor', is at now.
On the line ANCHOR names, at its column, or on its button wherever that
moved on the line -- or, a card having stacked its buttons under its
title or lifted them back, on another line of the card; never on another
button, where a key would do something else, but at the start of the
line instead."
  (let ((board-end (max (point-min) (1- harness-ui-tasks--list-end)))
        (box (harness-ui-tasks--box-start)))
    (pcase anchor
      ('(eob) (point-max))
      (`(box . ,offset)
       (if box (max box (min (+ harness-compose-start offset) harness-compose-end)) (point-max)))
      (`(,key ,line ,column ,button ,pos)
       (let ((start (if key (harness-ui-tasks--key-start key) (point-min))))
         (cond
          ;; A line above the box gone, the error say: the first one left.
          ((and (null start) (eq (car key) 'harness-task-tail))
           (marker-position harness-ui-tasks--list-end))
          ;; A task gone: about where it was, on the board.
          ((null start) (min pos board-end))
          (t
           (save-excursion
             (goto-char start)
             (forward-line line)
             ;; A card that shrank: back to the last line that is still its
             ;; own.  A line just past KEY -- the blank after a column -- is
             ;; where point was and stays.
             (let ((mine (lambda ()
                           (let ((k (harness-ui-tasks--line-key (line-beginning-position))))
                             (or (null k) (equal k key))))))
               (while (and (> (point) start) (not (funcall mine)))
                 (forward-line -1)))
             ;; A line counted from the board stays on the board.
             (when (and (< start harness-ui-tasks--list-end) (>= (point) harness-ui-tasks--list-end))
               (goto-char board-end)
               (forward-line 0))
             (let* ((bol (point))
                    (eol (line-end-position))
                    (at (pcase column
                          (`(end . ,n) (max bol (- eol n)))
                          (`(,_ . ,n) (min eol (+ bol n)))))
                    (same (and button
                               (or (harness-ui-tasks--find-button (car button) bol eol)
                                   (and key (harness-ui-tasks--find-button
                                             (car button) start (harness-ui-tasks--key-end start key)))))))
               (cond
                (same (min (+ (nth 1 same) (cdr button)) (1- (nth 2 same))))
                ((harness-ui-tasks--button-at at) bol)
                (t at)))))))))))

(defun harness-ui-tasks--places ()
  "Return where point and each window showing the board are, as anchors.
`harness-ui-tasks--restore' puts them back there after a redraw."
  (cons (harness-ui-tasks--anchor (point))
        (mapcar (lambda (w) (list w (harness-ui-tasks--anchor (window-start w))
                                  (harness-ui-tasks--anchor (window-point w))))
                (get-buffer-window-list nil nil t))))

(defun harness-ui-tasks--restore (places)
  "Put point and the windows back at PLACES, from `harness-ui-tasks--places'."
  (when (car places) (goto-char (harness-ui-tasks--anchor-position (car places))))
  (pcase-dolist (`(,w ,start ,pt) (cdr places))
    (when (and (window-live-p w) (eq (window-buffer w) (current-buffer)))
      (when pt (set-window-point w (harness-ui-tasks--anchor-position pt)))
      (when start (set-window-start w (harness-ui-tasks--anchor-position start) t)))))

(defvar-local harness-ui-tasks--drawn-key nil
  "What the board region was last drawn as, for `harness-ui-tasks--render'.")

(defun harness-ui-tasks--render (&optional force)
  "Redraw the board region, leaving the compose box alone.
Point and every window showing the board stay where they were: on the
same line of the same task, on the same button (`harness-ui-tasks--anchor').
A redraw that would draw the same board is skipped -- the tick runs
every `harness-ui-tasks-tick' seconds -- unless FORCE, which expansion,
folding and the like pass: the caps depend on the window, not the
board, so what was skipped is only skipped while both are unchanged."
  (when (and (harness-ui-tasks--board-p (current-buffer))
             (or force
                 (not (equal (harness-ui-tasks--board-key)
                             (buffer-local-value 'harness-ui-tasks--drawn-key (current-buffer))))))
    (setq harness-ui-tasks--drawn-key (harness-ui-tasks--board-key))
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (places (harness-ui-tasks--places)))
      (unless harness-ui-tasks--list-end
        (setq harness-ui-tasks--list-end (copy-marker (point-min) t)))
      (save-excursion
        (let ((expanded harness-ui-tasks--expanded))
          (harness-ui-tasks--fit-board)
          ;; Closing a section that needs no [Show fewer] any more changes
          ;; what the drawing depends on: this is the board as drawn now.
          (unless (equal expanded harness-ui-tasks--expanded)
            (setq harness-ui-tasks--drawn-key (harness-ui-tasks--board-key))))
        (put-text-property (point-min) (point) 'read-only t)
        (put-text-property (point-min) (point) 'keymap harness-ui-tasks-board-map)
        ;; The board is a panel of the compose box: its C-c . presses the
        ;; board's keys from there (`harness-compose-panel-key').
        (put-text-property (point-min) (point) 'harness-compose-panel 'board)
        (harness-ui-tasks--compose-buttons-keymap (point-min) (point)))
      (harness-ui-tasks--restore places)
      (harness-ui-tasks--focus-card)
      (set-buffer-modified-p nil)
      (force-mode-line-update))))

(defun harness-ui-tasks--board-key ()
  "Return what the board region's drawing depends on.
The tasks and their sessions (their name, status, todos and what they
wait on feed the cards; a session's tokens, rate and cost, which change
with every model call, do not: no row shows them, and the tooltip of a
title reads them when it is asked for, `harness-ui-tasks--title-help';
the internal sessions, which no card reads and which change with every
model call the harness makes on its own, are left out too), the
clock, the caps the window allows, and the state a card cannot show:
which column is folded, which is expanded, which tasks are submitting,
which cards you folded their recap on, whether finished work waits
for your review, and which buttons are held down.  A button held down
for longer than it may be is let go first
\(`harness-ui-tasks--release-stale'): the next redraw, the tick's
included, then finds the key changed.  They are not part of the
fitting's shape (`harness-ui-tasks--fit-shape'): a button held down is
as wide as it was."
  (harness-ui-tasks--release-stale)
  (list harness-ui-tasks--tasks
        ;; In the cache's own order: sorted by when each changed last, as
        ;; `harness-ui-user-sessions' has them, the key would differ after
        ;; every change of any session (it moves up), and the board would be
        ;; drawn again for changes that none of its cards show; and sorting
        ;; a thousand sessions costs more than the rest of the key.
        (let (figures)
          (maphash (lambda (id session)
                     (unless (harness-ui-internal-session-p session)
                       (push (list id (plist-get session :name) (plist-get session :status)
                                   (plist-get session :todos) (plist-get session :pending))
                             figures)))
                   harness-ui--sessions)
          figures)
        (truncate (float-time) 5)
        (harness-ui-tasks--window)
        (and (harness-ui-tasks--window) (window-body-height (harness-ui-tasks--window) t))
        (harness-ui-tasks--tail-key (harness-ui-tasks--window))
        harness-ui-tasks--folded
        harness-ui-tasks--expanded
        harness-ui-tasks--submitting
        harness-ui-tasks--subtitles
        harness-ui-tasks--settings
        harness-ui-tasks--show-archived
        harness-ui-tasks--loading
        (harness-ui-tasks--pressed-keys)))

(defvar-local harness-ui-tasks--focus nil
  "(ID . TIME): the task whose card point goes to once the board shows it.
A clicked notification asks for it, maybe before the board has loaded;
the request lapses after `harness-ui-tasks--focus-timeout' seconds.")

(defconst harness-ui-tasks--focus-timeout 10
  "Seconds a board waits to show the card a notification asked for.")

(defun harness-ui-tasks--focus-card ()
  "Put point on the card `harness-ui-tasks--focus' asks for, once it shows."
  (when harness-ui-tasks--focus
    (if (> (- (float-time) (cdr harness-ui-tasks--focus)) harness-ui-tasks--focus-timeout)
        (setq harness-ui-tasks--focus nil)
      (when-let* ((match (save-excursion
                           (goto-char (point-min))
                           (text-property-search-forward 'harness-task-id (car harness-ui-tasks--focus)
                                                         #'equal))))
        (setq harness-ui-tasks--focus nil)
        (goto-char (prop-match-beginning match))
        (dolist (w (get-buffer-window-list (current-buffer) nil t))
          (set-window-point w (point)))))))

(defun harness-ui-tasks-show-task (id project)
  "Show the task board of PROJECT, point on the card of task ID.
The board may still be loading: point goes to the card once it shows
\(`harness-ui-tasks--focus').  Return the board."
  (let ((board (harness-tasks project)))
    (when (buffer-live-p board)
      (with-current-buffer board
        (setq harness-ui-tasks--focus (cons id (float-time)))
        (harness-ui-tasks--focus-card)))
    board))

(defun harness-ui-tasks--task-root (session-id project)
  "Return the main checkout of the project of a task, or nil.
The task works in session SESSION-ID, and PROJECT is its `:project'.
The session, when the harness still has it, says the project for sure
\(`harness-ui-session-project'); otherwise PROJECT does, and that may be
a task's worktree, which belongs to the main checkout around it
\(`harness-files-owning-checkout')."
  (or (when-let* (((stringp session-id))
                  (session (harness-ui-session session-id)))
        (harness-ui-session-project session))
      (when (and (stringp project) (not (string-empty-p project)))
        (harness-files-owning-checkout project))))

(defun harness-ui-tasks-visit-task (id project &optional session-id)
  "Show task ID on the board of PROJECT, in the task's project.
The task's project becomes current first, as visiting a session makes
it (`harness-ui-switch-to-project'): the project of its session
SESSION-ID, else PROJECT's main checkout (`harness-ui-tasks--task-root').
So the board opens in the project the task belongs to rather than the
one that happened to be current.  The switch is a courtesy: whatever it
does, the board opens, point going to the card once it shows
\(`harness-ui-tasks-show-task').  Return the board."
  (when harness-ui-switch-project-function
    (harness-ignore-errors-logged "switching to the project of a task"
      (harness-ui-switch-to-project (harness-ui-tasks--task-root session-id project))))
  (harness-ui-tasks-show-task id project))

(defun harness-ui-tasks--on-notification (notification)
  "Open the board on the task NOTIFICATION, a clicked notification, is about.
The click switches to the task's project first
\(`harness-ui-tasks-visit-task'), the project of the session the
notification names when the harness still has it.  On
`harness-ui-notification-functions': non-nil when it was a task's."
  (let ((id (plist-get notification :task))
        (project (plist-get notification :project)))
    (when (and (stringp id) (stringp project) (not (string-empty-p project)))
      (harness-ui-tasks-visit-task id project (plist-get notification :session))
      t)))

(add-hook 'harness-ui-notification-functions #'harness-ui-tasks--on-notification)

(defun harness-ui-tasks--compose-buttons-keymap (start end)
  "Let buttons between START and END keep their own keymap over the board's."
  (let ((pos start))
    (while (< pos end)
      (let ((next (or (next-single-property-change pos 'button nil end) end)))
        (when (get-text-property pos 'button)
          (put-text-property pos next 'keymap (make-composed-keymap (list harness-ui-tasks-button-map
                                                                          harness-ui-tasks-board-map))))
        (setq pos next)))))

(defun harness-ui-tasks--messaging-p ()
  "Non-nil when the compose box sends to the session of an existing task.
That is a message, an answer, feedback on a write-up or feedback that
sends a task back from review: anything but composing a task, new or
edited."
  (memq (car harness-ui-tasks--target) '(reply answer refine reject)))

(defun harness-ui-tasks--searching-p ()
  "Non-nil when the compose box takes the board's search (`harness-tasks-search')."
  (eq (car harness-ui-tasks--target) 'search))

(defun harness-ui-tasks--compose-label ()
  "Return the compose box's label, which says what the box does.
That depends on `harness-ui-tasks--target': a new task by default."
  (pcase harness-ui-tasks--target
    (`(edit . ,id) (format "Edit pending task “%s”"
                           (harness-first-line (plist-get (harness-ui-tasks--find id) :prompt) 50)))
    (`(reply . ,id) (format "Message to session “%s”"
                            (let ((task (harness-ui-tasks--find id))) (if task (harness-ui-tasks--title task) id))))
    (`(answer . ,id) (format "Answer “%s”"
                             (harness-first-line
                              (or (plist-get (harness-ui-tasks--pending (harness-ui-tasks--find id)) :question)
                                  "the question")
                              60)))
    (`(refine . ,id) (concat "Refine "
                             (harness-ui-tasks--quote
                              (let ((task (harness-ui-tasks--find id))) (if task (harness-ui-tasks--title task) id)))
                             " with feedback"))
    (`(reject . ,id) (concat "Send back "
                             (harness-ui-tasks--quote
                              (let ((task (harness-ui-tasks--find id))) (if task (harness-ui-tasks--title task) id)))
                             " with feedback"))
    (`(search . ,_) "Search tasks, sessions and commands")
    (_ "New task")))

(defun harness-ui-tasks--setting-button (label command help &optional step)
  "A button LABEL running the session setting COMMAND on the board's target.
The target is the new-task settings or the task at point (see
`harness-ui-tasks--setting-target').  HELP is its tooltip.  With STEP, a step of a new task before its work (see
`harness-ui-tasks--step-keys'), the command sets that step's model or
thinking level instead."
  (propertize (harness-ui-tasks--button label
                                        (lambda ()
                                          (let ((harness-ui-tasks--step step))
                                            (call-interactively command)))
                                        help
                                        (if step (intern (format "%s@%s" command step)) command))
              'face 'harness-dim-face))

;;;; The steps of a new task: write-up or plan, then the work

;; In Submit a new task is its work, and the settings line under New
;; task starts with the work's model and thinking level, then the
;; task's other settings.  In Refine and Plan a step comes first -- an
;; agent writes the task up, or a strong model plans it -- and each
;; step, the work too, has a line of its own holding its model and
;; thinking level alone: that is all a step has of its own.  The rest
;; -- permission mode, interactive, supervisor mode, where the task
;; works -- is the task's, whatever step it is in, on the settings line
;; below the steps'.  A planned task's work has a model of its own: by
;; default the medium tier of the task model's provider, which the
;; plan is written for, where Submit and Refine work on the task model.
;; The harness says what each step gets by default (`task/settings'),
;; and the board keeps the choices in `harness-ui-tasks--new'.

(defconst harness-ui-tasks--step-keys
  '((refine :refine-model :refine-thinking)
    (plan :plan-model :plan-thinking)
    (plan-work :plan-work-model :plan-work-thinking))
  "Where `harness-ui-tasks--new' keeps the model and thinking of a step.
Each entry is (STEP MODEL-KEY THINKING-KEY): Refine's write-up, Plan's
plan, and the work of a planned task.  Any other work has `:model' and
`:thinking'.")

(defconst harness-ui-tasks--modes
  '((submit "Submit" harness-icon-running
            "Submit: start the task now")
    (refine "Refine" harness-icon-agent
            "Refine: an agent writes it up first")
    (plan "Plan" harness-icon-task-plan
          "Plan: an agent plans it first"))
  "The modes of the compose box for a new task, in the order they cycle.
Each entry is (MODE LABEL ICON HELP): the label and icon of the toggle
above the box, and its tooltip.")

(defun harness-ui-tasks--first-step ()
  "The step before a new task's work in the board's mode, or nil in Submit.
That is `refine' in Refine, where an agent writes the task up, and
`plan' in Plan, where a strong model plans it."
  (car (memq harness-ui-tasks--mode '(refine plan))))

(defun harness-ui-tasks--work-step ()
  "The step a new task's work is in the board's mode.
`plan-work' in Plan, where it runs on a model of its own, else nil:
the work's settings are then `:model' and `:thinking'."
  (and (eq harness-ui-tasks--mode 'plan) 'plan-work))

(defun harness-ui-tasks--step-values (step)
  "The new-task settings as the setting commands read them for STEP.
STEP's model and thinking level are `:model' and `:thinking' there;
without STEP they are the settings themselves."
  (let ((keys (cdr (assq step harness-ui-tasks--step-keys)))
        (new harness-ui-tasks--new))
    (if keys
        (plist-put (plist-put (copy-sequence new) :model (plist-get new (car keys)))
                   :thinking (plist-get new (cadr keys)))
      new)))

(defun harness-ui-tasks--step-setter (step)
  "Return the function that sets KEY to VALUE in this board's STEP.
For STEP's model and thinking level that is its own keys of
`harness-ui-tasks--new' (`harness-ui-tasks--step-keys'); the rest are
the task's.  It sets them in this board whatever buffer it is called
in: a setting command may answer later, from a request.  Supervisor
mode it refuses for a step that never supervises: a write-up or a plan
only reads, and a planned task's work runs hands-on
\(`harness-ui-tasks--work-supervisor-p'), so `harness-toggle-supervisor'
says so in Plan rather than change what Plan does not send."
  (let ((buffer (current-buffer))
        (keys (cdr (assq step harness-ui-tasks--step-keys))))
    (lambda (key value)
      (when (and step (eq key :supervisor))
        (user-error "No supervisor mode for %s"
                    (if (eq step 'plan-work)
                        "a planned task's work"
                      "a write-up or a plan")))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (harness-ui-tasks--set-new (pcase key
                                       (:model (or (car keys) key))
                                       (:thinking (or (cadr keys) key))
                                       (_ key))
                                     value))))))

(defun harness-ui-tasks--step-context (step)
  "Who a change of STEP's model or thinking level applies to, for the message.
STEP nil is the work: the whole task in Submit, the work after the
write-up in Refine.  Any other setting is the task's, whatever the step
\(`harness-ui-tasks--step-target')."
  (pcase step
    ('refine "for the write-up of new tasks")
    ('plan "for the plan of new tasks")
    ('plan-work "for the work of new planned tasks")
    (_ (if (harness-ui-tasks--first-step) "for the work of new tasks" "for new tasks"))))

(defun harness-ui-tasks--step-buttons (values scope &optional step)
  "The model and thinking-level buttons of a step, as VALUES has them.
They are all a step has of its own.  SCOPE names the step for their
tooltips, as \"the plan of new tasks\".  STEP is the step whose
settings they set, as `harness-ui-tasks--setting-button' takes it: nil
for the work."
  (concat (harness-ui-tasks--setting-button
           (harness-ui-model-label (plist-get values :model))
           #'harness-set-model (concat "Model of " scope) step)
          (propertize " · " 'face 'harness-dim-face)
          (harness-ui-tasks--setting-button
           (harness-ui-thinking-label (plist-get values :thinking))
           #'harness-set-thinking (concat "Thinking level of " scope) step)))

(defun harness-ui-tasks--step-label (name)
  "NAME, the step a line above the compose box is about, as it leads the line.
The labels of the mode's two lines take the same width, so the settings
after them line up."
  (let ((width (if (eq harness-ui-tasks--mode 'refine) (length "refine") (length "plan"))))
    (concat (propertize (string-pad name width) 'face 'harness-label-face) "  ")))

(defun harness-ui-tasks--step-line (&optional room)
  "The line of the step before a new task's work, fitted to ROOM columns.
In Refine it is the write-up's, in Plan the plan's: the model and the
thinking level, as buttons that set them -- all a step has of its own
\(`harness-ui-tasks--step-buttons') -- and nothing else: what the mode
does is the mode toggle's tooltip.  Empty in Submit and
until the settings came."
  (let ((step (harness-ui-tasks--first-step)))
    (if (or (null step) (null harness-ui-tasks--settings))
        ""
      (harness-ui-tasks--fit-settings
       (concat " " (harness-ui-tasks--step-label (symbol-name step))
               (harness-ui-tasks--step-buttons
                (harness-ui-tasks--step-values step)
                (if (eq step 'plan) "the plan of new tasks" "the write-up of new tasks")
                step))
       "" nil room))))

(defun harness-ui-tasks--work-line (&optional room)
  "The line of a new task's work in Refine and Plan, fitted to ROOM columns.
Like the line of the step before it (`harness-ui-tasks--step-line'), it
holds the step's model and thinking level alone, as buttons that set
them: in Plan the planned work's (`harness-ui-tasks--work-step'), in
Refine the task's own.  Whatever else the work runs with is the whole
task's, on the settings line below (`harness-ui-tasks--new-settings-line').
Empty in Submit, whose settings line starts with the work's model and
thinking level, and until the settings came."
  (if (or (null (harness-ui-tasks--first-step))
          (null harness-ui-tasks--settings))
      ""
    ;; Its buttons bind no step: the setting commands' target is the
    ;; work's (`harness-ui-tasks--setting-target'), as when typed in the box.
    (let ((step (harness-ui-tasks--work-step)))
      (harness-ui-tasks--fit-settings
       (concat " " (harness-ui-tasks--step-label "work")
               (harness-ui-tasks--step-buttons
                (harness-ui-tasks--step-values step)
                (if step "the work of new planned tasks" "the work of new tasks")))
       "" nil room))))

(defconst harness-ui-tasks--min-settings-room 24
  "Columns the settings keep before the limit's button is cut off too.
On a narrow board the settings line shrinks its settings first, so the
button that says how many tasks work at once stays whole.")

(defun harness-ui-tasks--supervisor-p ()
  "Non-nil when this board offers the supervisor setting.
The harness then has the supervisor module, so `task/settings' carries
`:supervisor' (a harness without it has no such setting to offer), and
the UI its toggle command (`harness-toggle-supervisor'); otherwise
there is nothing to show and nothing to run."
  (and (plist-member harness-ui-tasks--settings :supervisor)
       (fboundp 'harness-toggle-supervisor)))

(defun harness-ui-tasks--work-supervisor-p (step)
  "Non-nil when the work of STEP, a new task's, takes a supervisor setting.
STEP is as `harness-ui-tasks--work-step' returns it.  The work of a
planned task (`plan-work') does not: it works hands-on, since its plan
is made already (the supervisor module's `harness-supervisor--task-value'),
so in Plan the settings line has no supervisor switch and the task is
sent without one.  Other work does where the board offers the setting
\(`harness-ui-tasks--supervisor-p')."
  (and (not (eq step 'plan-work)) (harness-ui-tasks--supervisor-p)))

(defun harness-ui-tasks--supervisor-label (value)
  "Return the label of a supervisor setting VALUE.
t reads \"supervisor\", and `:false' \"hands-on\" (the user turned it
off), as does anything else that is not true."
  (if (harness-json-true-p value) "supervisor" "hands-on"))

(defun harness-ui-tasks--new-settings-line (&optional room)
  "The settings line of a new task: each setting a button, fitted to ROOM columns.
They are the whole task's, whatever step it is in: its permission
mode, whether it is interactive, supervisor mode where the harness has
it and the work takes it (`harness-ui-tasks--work-supervisor-p'), and,
in a git project, where it works.  A step has a model and a thinking
level of its own and nothing else, which Refine and Plan show on a
line per step above this one (`harness-ui-tasks--step-line',
`harness-ui-tasks--work-line'); in Submit, where the work is the whole
task, this line starts with them.  It ends with how many tasks work at
once (`harness-ui-tasks--max-running-button'), which Refine and Plan
show too: their write-ups take no slot, but the work does once it
starts.  When ROOM is too narrow for it all, the settings shorten
first, down to `harness-ui-tasks--min-settings-room' columns, so that
button stays whole; the line shortens as a whole after that.  Without
ROOM it is not fitted."
  (let* ((step (harness-ui-tasks--work-step))
         (values harness-ui-tasks--new)
         (s harness-ui-tasks--settings)
         (main-tree (harness-json-true-p (plist-get values :main-tree)))
         ;; How many tasks work at once is the harness's, for every
         ;; project, not the next task's: apart from its settings.
         (limit t))
    (if (null s)
        ""
      (harness-ui-tasks--fit-settings
       (concat
        " "
        (mapconcat
         #'identity
         (delq nil
               (list ;; The steps of Refine and Plan have their model and
                     ;; thinking level on lines of their own; Submit's one
                     ;; step has them here.
                     (and (null (harness-ui-tasks--first-step))
                          (harness-ui-tasks--step-buttons values "new tasks"))
                     (harness-ui-tasks--setting-button
                      (if-let* ((m (plist-get values :permission-mode))) (harness-ui-permission-mode-label m) "default mode")
                      #'harness-set-permission-mode "Permission mode of new tasks")
                     (harness-ui-tasks--setting-button
                      (harness-ui-non-interactive-label (plist-get values :non-interactive))
                      #'harness-toggle-non-interactive "Non-interactive mode of new tasks")
                     ;; Supervisor mode is the supervisor module's; a
                     ;; harness without it has no setting to offer, and
                     ;; a planned task's work none to take.
                     (and (harness-ui-tasks--work-supervisor-p step)
                          (harness-ui-tasks--setting-button
                           (harness-ui-tasks--supervisor-label (plist-get values :supervisor))
                           #'harness-toggle-supervisor
                           "Supervisor mode of new tasks"))
                     ;; The next task's priority is beside Submit.  A task
                     ;; that starts cannot change where it works, so this
                     ;; one is only about the next task.
                     (and (harness-json-true-p (plist-get s :worktrees))
                          (harness-ui-tasks--setting-button
                           (if main-tree "main tree" "own worktree")
                           #'harness-ui-tasks-toggle-main-tree
                           "Where the next task works: its own worktree, or the main tree"))))
         (propertize " · " 'face 'harness-dim-face)))
       (concat "   "
               (and (harness-ui-tasks--queue-suspended-p)
                    (concat (propertize "queue suspended" 'face 'harness-dim-face)
                            (propertize " · " 'face 'harness-dim-face)))
               (harness-ui-tasks--max-running-button))
       limit room))))

(defun harness-ui-tasks--fit-settings (settings note keep room)
  "SETTINGS then NOTE, fitted to ROOM columns; not fitted without ROOM.
With KEEP, NOTE stays whole while SETTINGS can shorten to
`harness-ui-tasks--min-settings-room' columns; otherwise, or narrower
still, the whole line shortens from its end."
  (let ((line (concat settings note)))
    (cond ((or (null room) (<= (string-width line) room)) line)
          ((and keep (>= (- room (string-width note)) harness-ui-tasks--min-settings-room))
           (concat (harness-ui-tasks--fit settings (- room (string-width note))) note))
          (t (harness-ui-tasks--fit line room)))))

;;;; How many tasks work at once

;; The settings line ends with how many of a project's tasks may work at
;; once: "3 at a time", or "all at once" without a limit.  It is the
;; harness option `harness-tasks-max-running', the same for every
;; project, and a click on it sets it as the Review switch sets its
;; own: saved through `config/set', so it holds for every board and
;; across restarts.  The harness starts the tasks a higher limit lets
;; through at once; a lower one stops none at work.

(defface harness-task-held-face '((t :inherit warning))
  "The limit button while no task starts by itself: 0 at a time."
  :group 'harness-ui-tasks)

(defun harness-ui-tasks--max-running ()
  "How many of a project's tasks may work at once: a number, nil for no limit.
That is the harness's `task/settings' as last fetched."
  (let ((n (plist-get harness-ui-tasks--settings :max-running)))
    (and (integerp n) n)))

(defun harness-ui-tasks--held-p (n)
  "Non-nil when a limit of N tasks lets none start by itself: 0 (or less)."
  (and n (<= n 0)))

(defun harness-ui-tasks--max-running-label (n)
  "What the limit button says for a limit of N tasks: \"3 at a time\".
Without a limit, N nil, it is \"all at once\"."
  (if n (format "%d at a time" n) "all at once"))

(defun harness-ui-tasks--max-running-help (n)
  "The tooltip of the limit button for a limit of N tasks, nil for none."
  (concat
   (cond ((null n) "No limit on tasks at once")
         ((harness-ui-tasks--held-p n) (format "%d at a time: nothing starts by itself" n))
         (t (format "At most %d tasks at once per project" n)))
   " (click to change; S shows the slots)"))

(defun harness-ui-tasks--max-running-button ()
  "The button saying how many of a project's tasks work at once.
It ends the settings line of a new task, though it is no setting of
the task: a click asks for another limit, for every project
\(`harness-ui-tasks-set-max-running').  Like the rest of that line it
shows once the harness has said what the limit is, so it never shows
a wrong one.  It stands out at 0, when no task starts by itself."
  (let ((n (harness-ui-tasks--max-running)))
    (propertize
     (harness-ui-tasks--button (harness-ui-tasks--max-running-label n)
                               (lambda () (call-interactively #'harness-ui-tasks-set-max-running))
                               (harness-ui-tasks--max-running-help n)
                               'harness-ui-tasks-set-max-running)
     'face (if (harness-ui-tasks--held-p n) 'harness-task-held-face 'harness-dim-face))))

(defconst harness-ui-tasks--max-running-choices
  '("1" "2" "3" "4" "5" "6" "8" "10" "no limit" "0")
  "The limits the minibuffer offers, in this order; any other number does too.")

(defun harness-ui-tasks--parse-max-running (answer)
  "The limit ANSWER names: a number of tasks, or nil for no limit.
A number may come with the button's words (\"4 at a time\"), and no
limit as \"no limit\", \"none\", \"unlimited\", \"all\" or \"all at
once\".  Signal a `user-error' for anything else."
  (let ((answer (downcase (string-trim answer))))
    (cond ((member answer '("no limit" "none" "nil" "unlimited" "all" "all at once")) nil)
          ((string-match "\\`\\([0-9]+\\)\\(?: *at a time\\)?\\'" answer)
           (string-to-number (match-string 1 answer)))
          (t (user-error "Not a number of tasks: %s (a number, or no limit)" answer)))))

(defun harness-ui-tasks--read-max-running (current)
  "Read how many of a project's tasks may work at once, CURRENT now.
Return a number, or nil for no limit; an empty answer keeps CURRENT."
  (let* ((default (if current (number-to-string current) "no limit"))
         (annotations '(("0" . "  nothing starts by itself")
                        ("no limit" . "  every task starts at once")))
         (answer (completing-read
                  (format-prompt "Tasks of a project working at once" default)
                  (lambda (string pred action)
                    (if (eq action 'metadata)
                        `(metadata (display-sort-function . identity)
                                   (cycle-sort-function . identity)
                                   (annotation-function
                                    . ,(lambda (choice) (cdr (assoc choice annotations)))))
                      (complete-with-action action harness-ui-tasks--max-running-choices string pred)))
                  nil nil nil nil default)))
    (if (string-empty-p (string-trim answer))
        current
      (harness-ui-tasks--parse-max-running answer))))

(defun harness-ui-tasks--show-max-running (n)
  "Show the limit of N tasks, nil for none, as the harness has it now.
Its `config/changed' brings every board the settings again shortly;
this one does not wait for them."
  (when harness-ui-tasks--settings
    (setq harness-ui-tasks--settings
          (plist-put (copy-sequence harness-ui-tasks--settings) :max-running n))
    (harness-ui-tasks--refit-tail)))

(defun harness-ui-tasks-set-max-running (n)
  "Let N of each project's tasks work at once; N nil means no limit.
The others wait in Pending and start in its order, by priority first, as
slots free up.  Raising the limit starts the tasks it lets through at
once; lowering it stops no task at work, and only fewer start after.
With 0 no task starts by itself: each waits until you start it
\(\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-start]).

The limit is the harness option `harness-tasks-max-running', saved as
the settings page saves it: for every project, each with that many
slots of its own, and across restarts.  Interactively it is read in the
minibuffer, the limit now being the default; the button that says
\"N at a time\" (or \"all at once\") above the compose box runs it."
  (interactive (list (harness-ui-tasks--read-max-running (harness-ui-tasks--max-running))))
  (unless (or (null n) (natnump n))
    (user-error "Not a number of tasks: %s" n))
  (let ((buffer (current-buffer))
        (says (lambda (n)
                (cond ((null n) "No limit on tasks at once")
                      ((zerop n) "0 at a time: nothing starts by itself")
                      (t (format "%d at a time" n))))))
    (if (and harness-ui-tasks--settings (eql n (harness-ui-tasks--max-running)))
        (message "%s" (funcall says n))
      (harness-ui-tasks--request-then
       "_harness/config/set"
       (list :key "harness-tasks-max-running" :value (prin1-to-string n) :printed t
             :scope "global" :cwd harness-ui-tasks--dir)
       "Setting how many tasks work at once"
       (lambda (_)
         (when (harness-ui-tasks--board-p buffer)
           (with-current-buffer buffer (harness-ui-tasks--show-max-running n)))
         (message "%s" (funcall says n)))))))

(defun harness-ui-tasks--set-new (key value)
  "Set the new-task setting KEY to VALUE and show it."
  (setq harness-ui-tasks--new (plist-put (copy-sequence harness-ui-tasks--new) key value))
  (harness-ui-tasks--render-tail))

(defun harness-ui-tasks--set-all (key value)
  "Give KEY VALUE in the new-task settings of every open board.
This is the boards' part of `harness-ui-set-all-functions': a command
that changes every current session and task changes what each board's
next task starts with too, as the board's own buttons would.  A board
whose settings have not come yet gets them, the new default included,
from the harness when they do.  Return the boards' directories."
  (let ((dirs nil))
    (dolist (buffer (harness-ui-tasks--buffers))
      (with-current-buffer buffer
        (when harness-ui-tasks--new
          (setq harness-ui-tasks--new (plist-put (copy-sequence harness-ui-tasks--new) key value))
          (when (harness-compose-live-p)
            (harness-ui-tasks--render-tail)))
        (when harness-ui-tasks--dir
          (push harness-ui-tasks--dir dirs))))
    (nreverse dirs)))

;; At top level, so a reload adds it in a running Emacs too.
(add-hook 'harness-ui-set-all-functions #'harness-ui-tasks--set-all)

(defun harness-ui-tasks--setting-target ()
  "Where the session setting commands apply on the board.
The session of the started task at point, else the new-task settings.  A backlog task's session only
writes it up, with settings of its own, so it counts as not started.
The new-task settings are those of the work (in Plan, the planned
work's model and thinking level: `harness-ui-tasks--work-step'), or
of the step before it whose line's button was pushed
\(`harness-ui-tasks--step')."
  (cond
   (harness-ui-tasks--step (harness-ui-tasks--step-target harness-ui-tasks--step))
   (t
    (let ((task (and (not (harness-compose-in-p)) (harness-ui-tasks--task t))))
      (if (and task (plist-get task :session) (not (harness-ui-tasks--unstarted-p task)))
          (plist-get task :session)
        (harness-ui-tasks--step-target (harness-ui-tasks--work-step)))))))

(defun harness-ui-tasks--step-target (step)
  "What the setting commands change for STEP of a new task, nil the work.
That is (VALUES SET CONTEXT), as `harness-ui-setting-target-function'
returns it: STEP's settings, the function that sets one, and who the
change is for, a function of the setting's key: STEP's own for its
model and thinking level, the task's for the rest, which every step
shares.  It is worked out now, as a setting command may answer later,
from another buffer."
  (let ((own (harness-ui-tasks--step-context step)))
    (list (harness-ui-tasks--step-values step) (harness-ui-tasks--step-setter step)
          (lambda (key) (if (memq key '(:model :thinking)) own "for new tasks")))))

(defun harness-ui-tasks--label-line (room messaging bar)
  "The compose label, fitted to ROOM columns: what the box does, and the
Submit / Refine / Plan toggle or [cancel].  MESSAGING is non-nil when
the box sends to a session, BAR what starts the line.  A message and
the board's search each lead with their icon, in their accent."
  (let* ((searching (harness-ui-tasks--searching-p))
         (cancel (if harness-ui-tasks--target
                     (concat "  " (harness-ui-tasks--button
                                   "[cancel]" #'harness-ui-tasks-compose-reset
                                   (if (eq (car harness-ui-tasks--target) 'search)
                                       "Close the search (C-g)"
                                     "Back to a new task (C-g)")
                                   'harness-ui-tasks-compose-reset))
                   ""))
         (toggle (if harness-ui-tasks--target ""
                   (concat "   " (harness-ui-tasks--mode-toggle)
                           "   " (harness-ui-tasks--priority-toggle))))
         (accent (cond (messaging 'harness-compose-message-accent-face)
                       (searching 'harness-task-search-box-accent-face)))
         (icon (cond (messaging (concat (harness-ui-icon 'harness-icon-message) " "))
                     ;; The search's icon is defined with it (harness-ui-tasks-search.el).
                     (searching (let ((icon (ignore-errors (harness-ui-icon 'harness-icon-search))))
                                  (if (and icon (not (string-empty-p icon))) (concat icon " ") "")))
                     (t "")))
         (body (concat icon (harness-ui-tasks--compose-label)))
         (label (harness-ui-tasks--fit (concat bar body)
                                       (- room (string-width cancel) (string-width toggle)))))
    ;; The bar, the icon and the label each keep their own look: the
    ;; band behind them all, the accent on bar and icon, the label face
    ;; on the text.
    (let ((head (if accent (+ (length bar) (length icon)) 0)))
      (add-face-text-property head (length label) 'harness-label-face t label)
      (when accent
        (add-face-text-property (length bar) (length label) accent t label)))
    ;; Fitted again as a whole: the label shrinks to a minimum, the toggle not.
    (harness-ui-tasks--fit (concat label toggle cancel) room)))

(defun harness-ui-tasks--mode-notice (text face)
  "The coloured line above the compose box: TEXT in FACE."
  (propertize (concat "  " text) 'face face))

(defun harness-ui-tasks--mode-notice-button (label action id)
  "A button LABEL in a notice line, running ACTION, named ID for redraws."
  (harness-ui-tasks--button label action label id))

(defun harness-ui-tasks--mode-notice-fit (text button room)
  "The notice line TEXT with BUTTON fitted to ROOM columns.
BUTTON, a string or nil, stays whole; TEXT shortens when the two do not
fit together."
  (if (null button)
      (harness-ui-tasks--fit text room)
    (let ((room (- room (string-width button) 2)))
      (concat (harness-ui-tasks--fit text (max 0 room))
              (and (>= room 0) (concat "  " button))))))

(defun harness-ui-tasks--mode-notices ()
  "The (KEY TEXT BUTTON) lines warning which submit modes are armed.
TEXT is the coloured notice: the main tree in `harness-task-attention-face',
a non-default priority in its priority face.  A mode armed for one task
only gets a [keep on] BUTTON; a sticky one an [off] button."
  (let* ((priority (harness-ui-tasks--priority harness-ui-tasks--new))
         (lines nil)
         (keep-main (lambda ()
                      (setq harness-ui-tasks--main-tree-mode 'sticky)
                      (harness-ui-tasks--render-tail)
                      (message "Main tree for every task")))
         (off-main (lambda () (harness-ui-tasks--set-main-tree nil)))
         (keep-priority (lambda ()
                          (setq harness-ui-tasks--priority-mode 'sticky)
                          (harness-ui-tasks--render-tail)
                          (message "%s priority for every task" (capitalize priority))))
         (off-priority (lambda ()
                         (setq harness-ui-tasks--priority-mode nil)
                         (harness-ui-tasks--set-new :priority "medium")
                         (message "Medium priority"))))
    (when harness-ui-tasks--main-tree-mode
      (push (if (eq harness-ui-tasks--main-tree-mode 'once)
                (list 'main-tree-once
                      (harness-ui-tasks--mode-notice
                       "Main tree for the next task"
                       'harness-task-attention-face)
                      (harness-ui-tasks--mode-notice-button
                       "[keep on]" keep-main 'harness-ui-tasks-main-tree-keep))
              (list 'main-tree-sticky
                    (harness-ui-tasks--mode-notice
                     "Main tree for every task"
                     'harness-task-attention-face)
                    (harness-ui-tasks--mode-notice-button
                     "[off]" off-main 'harness-ui-tasks-main-tree-off)))
            lines))
    (when harness-ui-tasks--priority-mode
      (push (if (eq harness-ui-tasks--priority-mode 'once)
                (list 'priority-once
                      (harness-ui-tasks--mode-notice
                       (format "%s priority for the next task"
                               (capitalize priority))
                       (harness-ui-tasks--priority-face priority))
                      (harness-ui-tasks--mode-notice-button
                       "[keep on]" keep-priority 'harness-ui-tasks-priority-keep))
              (list 'priority-sticky
                    (harness-ui-tasks--mode-notice
                     (format "%s priority for every task"
                             (capitalize priority))
                     (harness-ui-tasks--priority-face priority))
                    (harness-ui-tasks--mode-notice-button
                     "[off]" off-priority 'harness-ui-tasks-priority-off)))
            lines))
    (nreverse lines)))

(defun harness-ui-tasks--tail-lines (messaging band bar)
  "The lines between the board and the compose box: (KEY FIT BAND) each.
Top first: the error, the compose label, in Refine and
Plan a line per step -- the one before the work (`harness-ui-tasks--step-line'),
then the work's (`harness-ui-tasks--work-line') -- the task's settings
and, nearest the box, the armed submit-mode notices, those there are.
KEY names the line for redraws, FIT returns it fitted to the columns
it is called with, BAND is the face behind it or nil.  MESSAGING and
BAR are as `harness-ui-tasks--label-line' takes them."
  (let ((lines nil))
    (when harness-ui-tasks--error
      (let ((text (propertize (concat "  " harness-ui-tasks--error) 'face 'harness-tool-error-face)))
        (push (list 'error (lambda (room) (harness-ui-tasks--fit text room)) band) lines)))
    (push (list 'label (lambda (room) (harness-ui-tasks--label-line room messaging bar)) band) lines)
    (unless harness-ui-tasks--target
      ;; In Refine and Plan, the step before the work, then the work: a
      ;; model and a thinking level each, above what the task works with.
      (unless (string-empty-p (harness-ui-tasks--step-line))
        (push (list 'step (lambda (room) (harness-ui-tasks--step-line room)) nil) lines))
      (unless (string-empty-p (harness-ui-tasks--work-line))
        (push (list 'work (lambda (room) (harness-ui-tasks--work-line room)) nil) lines))
      (unless (string-empty-p (harness-ui-tasks--new-settings-line))
        (push (list 'settings (lambda (room) (harness-ui-tasks--new-settings-line room)) nil) lines))
      (dolist (notice (harness-ui-tasks--mode-notices))
        (let ((text (nth 1 notice))
              (button (nth 2 notice)))
          (push (list (car notice)
                      (lambda (room) (harness-ui-tasks--mode-notice-fit text button room))
                      nil)
                lines))))
    (nreverse lines)))

(defun harness-ui-tasks--corner (room lines)
  "What `harness-ui-tasks-corner-functions' draw beside LINES, or nil.
LINES are as `harness-ui-tasks--tail-lines' returns them, ROOM the
columns they have.  The functions cannot move point, where the lines
go: they may measure text in a window, which takes the window's point."
  (let ((widths (mapcar (lambda (line) (string-width (funcall (nth 1 line) most-positive-fixnum)))
                        lines)))
    (run-hook-wrapped 'harness-ui-tasks-corner-functions
                      (lambda (fn) (ignore-errors (save-excursion (funcall fn room widths)))))))

(defun harness-ui-tasks--insert-corner (text)
  "Insert TEXT, whole lines of `harness-ui-tasks-corner-functions'.
They are named for redraws, as the lines below them are."
  (when (and (stringp text) (not (string-empty-p text)))
    (let ((start (point)))
      (insert text)
      (unless (bolp) (insert "\n"))
      (put-text-property start (point) 'harness-task-tail 'corner))))

(defun harness-ui-tasks--insert-tail-head ()
  "Insert the error line, the compose label, the settings and the attachments.
Each line is fitted to the window, like the board's: the buffer wraps
for the compose box, so a longer line would take two.  A new task's
label carries the Submit / Refine / Plan toggle, which the label makes
room for.  A box that sends to a session wears its message colours here too,
the label, bar and band around it, so what submitting will do is plain
before a key is pressed; the board's search wears colours of its own.
What `harness-ui-tasks-corner-functions' draw sits at the right of the
lines, which narrow for it, and above them."
  (let* ((room (1- (harness-ui-tasks--width)))
         (messaging (harness-ui-tasks--messaging-p))
         (searching (harness-ui-tasks--searching-p))
         (band (cond (messaging 'harness-compose-message-face)
                     (searching 'harness-task-search-box-face)))
         (bar (cond (messaging
                     (harness-compose-bar 'harness-compose-message-accent-face 'harness-compose-message-face))
                    (searching
                     (harness-compose-bar 'harness-task-search-box-accent-face 'harness-task-search-box-face))
                    (t " ")))
         (lines (harness-ui-tasks--tail-lines messaging band bar))
         (corner (harness-ui-tasks--corner room lines))
         (beside (plist-get corner :beside))
         (reserve (or (plist-get corner :reserve) 0)))
    (harness-ui-tasks--insert-corner (plist-get corner :above))
    (cl-loop for (key fit band) in lines
             for i from 0
             for right = (nth i beside)
             do (harness-ui-tasks--insert-tail-line
                 key (if right (concat (funcall fit (- room reserve)) right) (funcall fit room)) band))
    (let ((start (point)))
      ;; The bar down every attachment's line.
      (harness-compose-insert-attachments (and band bar))
      (put-text-property start (point) 'harness-task-tail 'attachments)
      (when band (add-face-text-property start (point) band t)))))

(defun harness-ui-tasks--insert-tail-line (key text &optional band)
  "Insert TEXT as a line above the compose box, named KEY for redraws.
A redraw keeps point on the line of the same KEY (`harness-ui-tasks--anchor').
BAND, when given, is a face put behind the whole line, its final newline
included, so the line's background reaches the window's edge like the
compose box's."
  (let ((start (point)))
    (insert text "\n")
    (put-text-property start (point) 'harness-task-tail key)
    (when band (add-face-text-property start (point) band t))))

(defun harness-ui-tasks--refit-tail ()
  "Fit the lines between the board and the compose box to the window again.
The box itself is left alone, so typing or completing in it carries on,
and point on those lines stays there."
  (when (and (harness-ui-tasks--board-p (current-buffer)) harness-ui-tasks--list-end
             harness-compose-overlay (eq (overlay-buffer harness-compose-overlay) (current-buffer)))
    (let ((inhibit-read-only t)
          (buffer-undo-list t)
          (list-end (marker-position harness-ui-tasks--list-end))
          (places (harness-ui-tasks--places)))
      (save-excursion
        (delete-region list-end (overlay-start harness-compose-overlay))
        (goto-char list-end)
        (harness-ui-tasks--insert-tail-head)
        (put-text-property list-end (point) 'read-only t))
      (set-marker harness-ui-tasks--list-end list-end)
      (harness-ui-tasks--restore places)
      (set-buffer-modified-p nil))))

(defun harness-ui-tasks-redraw-tail-lines (&optional buffers)
  "Draw the lines above the compose box of BUFFERS again, the box left alone.
BUFFERS are boards, every board by default.  For a module whose
`harness-ui-tasks-corner-functions' would draw something else now: each
board then fits its cards to the room the lines leave."
  (dolist (buffer (or buffers (harness-ui-tasks--buffers)))
    (when (harness-ui-tasks--board-p buffer)
      (with-current-buffer buffer
        (harness-ui-tasks--refit-tail)
        (harness-ui-tasks--schedule-render buffer)))))

(defun harness-ui-tasks--next-mode ()
  "The mode after the board's in `harness-ui-tasks--modes', round to the first."
  (car (or (cadr (memq (assq harness-ui-tasks--mode harness-ui-tasks--modes) harness-ui-tasks--modes))
           (car harness-ui-tasks--modes))))

(defun harness-ui-tasks--mode-toggle ()
  "The Submit / Refine / Plan toggle above the compose box: the current mode.
One button, showing only the mode new tasks get, with its icon: running
for Submit, the agent's for Refine, a plan's for Plan.  A click
switches to the next mode, as `harness-ui-tasks-cycle-mode' does."
  (let ((keys (substitute-command-keys "\\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-cycle-mode]"))
        (next (assq (harness-ui-tasks--next-mode) harness-ui-tasks--modes)))
    (pcase-let ((`(,_ ,label ,icon ,help) (or (assq harness-ui-tasks--mode harness-ui-tasks--modes)
                                              (car harness-ui-tasks--modes))))
      (propertize
       (harness-ui-tasks--button
        (concat (harness-ui-icon icon) " " label)
        (lambda () (harness-ui-tasks--set-mode (harness-ui-tasks--next-mode)))
        (format "%s (click or %s to switch to %s)" help keys (nth 1 next))
        'harness-ui-tasks-cycle-mode)
       'face 'harness-task-choice-face))))

(defun harness-ui-tasks--priority-button-face (priority)
  "The face of a button showing PRIORITY: the priority faces for high and low.
Medium, or nil for none in particular, is dim like the other settings."
  (if (member priority '("high" "low")) (harness-ui-tasks--priority-face priority) 'harness-dim-face))

(defun harness-ui-tasks--priority-toggle ()
  "The button beside the Submit / Refine / Plan toggle: the next task's priority.
It wears the face a card's priority fact has, and a click moves it on,
as `harness-ui-tasks-cycle-new-priority' does."
  (let ((priority (harness-ui-tasks--priority harness-ui-tasks--new)))
    (propertize
     (harness-ui-tasks--button
      (concat priority " priority")
      #'harness-ui-tasks-cycle-new-priority
      "Priority of the next task (click to change)"
      'harness-ui-tasks-cycle-new-priority)
     'face (harness-ui-tasks--priority-button-face priority))))

(defun harness-ui-tasks--set-mode (mode)
  "Have the compose box submit, refine or plan new tasks, as MODE says.
MODE is `submit', `refine' or `plan' (see `harness-ui-tasks--modes').
The toggle above the box then names it, and the lines under it are
its own; what it does is the toggle's tooltip, not a message."
  (unless (assq mode harness-ui-tasks--modes)
    (error "Unknown mode %s: submit, refine or plan" mode))
  (setq harness-ui-tasks--mode mode)
  (harness-ui-tasks--render-tail))

(defun harness-ui-tasks--read-mode ()
  "Read a mode of the compose box in the minibuffer: `submit', `refine' or `plan'."
  (let* ((choices (mapcar (lambda (m) (cons (nth 1 m) (car m))) harness-ui-tasks--modes))
         (completion-extra-properties
          (list :annotation-function
                (lambda (choice)
                  (concat "  " (cadr (split-string (nth 3 (assq (cdr (assoc choice choices))
                                                                harness-ui-tasks--modes))
                                                   ": ")))))))
    (cdr (assoc (completing-read "New tasks: "
                                 (lambda (string pred action)
                                   ;; Keep Submit, Refine, Plan in their order.
                                   (if (eq action 'metadata)
                                       '(metadata (display-sort-function . identity)
                                                  (cycle-sort-function . identity))
                                     (complete-with-action action choices string pred)))
                                 nil t)
                choices))))

(defun harness-ui-tasks-cycle-mode (&optional mode)
  "Switch the compose box to its next mode: Submit, Refine, Plan, and round.
Submit starts a new task at once.  Refine (backlog refinement, once
called grooming) has an agent write it up first -- briefly, reading the
code but changing nothing.  Plan has a strong model -- the hard tier of
the task model's provider, Opus for Claude -- read the code, make the
decisions and plan the work for a cheaper model, the medium tier
\(Sonnet), which then does it.  Either way the task then waits in the
Backlog, across restarts, until you start it
\(\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-start]).  In Refine and Plan a
line per step -- the write-up or the plan, then the work -- shows the
step's model and thinking level, a click on either changing it; what
the whole task works with is on the line below them.  With a prefix
argument the mode is read; from Lisp, MODE (`submit', `refine' or
`plan') sets it."
  (interactive (list (and current-prefix-arg (harness-ui-tasks--read-mode))))
  (harness-ui-tasks--set-mode (or mode (harness-ui-tasks--next-mode))))

(define-obsolete-function-alias 'harness-ui-tasks-toggle-refine #'harness-ui-tasks-cycle-mode "3.1")

(defun harness-ui-tasks--set-main-tree (main-tree &optional mode)
  "Make new tasks work in the main tree when MAIN-TREE, else in a worktree.
MODE is how the choice holds: nil (off), `once' (the next task only) or
`sticky' (every task until turned off).  A task that needs the main
tree works in the project's checkout itself: no worktree, no branch,
and nothing merges -- for work that has to touch the checkout, such as
cleaning up uncommitted changes."
  (setq harness-ui-tasks--main-tree-mode (and main-tree (or mode 'once)))
  (harness-ui-tasks--set-new :main-tree (if main-tree t :false))
  (message (cond
            ((eq harness-ui-tasks--main-tree-mode 'once)
             "Main tree for the next task")
            ((eq harness-ui-tasks--main-tree-mode 'sticky)
             "Main tree for every task")
            (t "Own worktree for the next task"))))

(defun harness-ui-tasks-toggle-main-tree (&optional arg)
  "Switch the next task between its own worktree and the main tree.
In the main tree (see `harness-ui-tasks--set-main-tree') the task works
in the project's own checkout, so it can touch it directly; a backlog
task (Refine) keeps the choice for when it starts.  A click arms the
main tree for the next task only, another keeps it on until you click
it off.  With a prefix ARG, the main tree when it is positive (kept on)
and a worktree otherwise."
  (interactive "P")
  (if arg
      (harness-ui-tasks--set-main-tree (> (prefix-numeric-value arg) 0) 'sticky)
    (pcase harness-ui-tasks--main-tree-mode
      ('once (harness-ui-tasks--set-main-tree t 'sticky))
      ('sticky (harness-ui-tasks--set-main-tree nil))
      (_ (harness-ui-tasks--set-main-tree t 'once)))))

(defun harness-ui-tasks-cycle-new-priority (&optional priority)
  "Change the priority the next task is submitted with.
Each call moves it on from medium to high, then low, then medium again,
arming the choice for the next task only; the [keep on] button in the
notice above the compose box keeps the level on, and while a level is
kept on a click turns it off.  Called from Lisp, PRIORITY (\"low\",
\"medium\" or \"high\") sets it.  While the project's slots are full, a
waiting task of higher priority starts first, and Pending lists them
so; the priority of a task on the board is changed on its card
\(\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-raise-priority] and \\[harness-ui-tasks-lower-priority])."
  (interactive)
  (let* ((current (harness-ui-tasks--priority harness-ui-tasks--new))
         (next (or priority
                   (pcase current ("medium" "high") ("high" "low") (_ "medium"))))
         (sticky (and (null priority) (eq harness-ui-tasks--priority-mode 'sticky))))
    (unless (member next harness-ui-priority-levels)
      (error "Unknown priority %s" next))
    (setq harness-ui-tasks--priority-mode
          (cond
           (sticky nil)
           (priority (and (not (equal next "medium")) 'once))
           ((equal next "medium") nil)
           (t 'once)))
    (harness-ui-tasks--set-new :priority (if sticky "medium" next))
    (message (cond
              (sticky "Medium priority")
              ((eq harness-ui-tasks--priority-mode 'once)
               (format "%s priority for the next task" (capitalize next)))
              (t "Medium priority")))))

(defun harness-ui-tasks--render-tail (&optional text)
  "Draw the error line, the compose label, the attachments and the compose box.
TEXT replaces the compose contents; without it they are kept.  Point and
the windows showing the board stay where they were: at the same spot of
the box, or on the same line above it (`harness-ui-tasks--anchor')."
  (when (harness-ui-tasks--board-p (current-buffer))
    (harness-compose-capture)
    (let* ((inhibit-read-only t)
           (buffer-undo-list t)
           (list-end (marker-position harness-ui-tasks--list-end))
           (places (harness-ui-tasks--places)))
      (save-excursion
        (delete-region list-end (point-max))
        (goto-char list-end)
        (harness-ui-tasks--insert-tail-head)
        (put-text-property list-end (point) 'read-only t)
        (cond
         ((harness-ui-tasks--messaging-p)
          ;; A message to a session, not a task being composed: the box's
          ;; own colours say so, with the band and bar around it.
          (harness-compose-insert text (harness-ui-tasks--box-help)
                                  :face 'harness-compose-message-face
                                  :accent 'harness-compose-message-accent-face))
         ;; A search, not a task either: colours of its own.
         ((harness-ui-tasks--searching-p)
          (harness-compose-insert text (harness-ui-tasks--box-help)
                                  :face 'harness-task-search-box-face
                                  :accent 'harness-task-search-box-accent-face))
         (t (harness-compose-insert text (harness-ui-tasks--box-help)))))
      (set-marker harness-ui-tasks--list-end list-end)
      (harness-ui-tasks--restore places)
      (set-buffer-modified-p nil))))

(defun harness-ui-tasks--box-key-hint ()
  "Say how to press a board key from the compose box.
The board's keys type in the box, so the box's key for a panel's keys
\(`harness-compose-panel-key') is the way; F, the fullscreen layout, is
the example, as it acts anywhere on the board."
  (format "%s F: a board key from the box" (harness-compose-panel-keys)))

(defun harness-ui-tasks--box-help ()
  "Return the tooltip of the compose box's prompt: its keys, and the board's."
  (format "C-c C-c submits, RET newline, C-c C-a attaches a file or task, %s" (harness-ui-tasks--box-key-hint)))

(defun harness-ui-tasks--placeholder ()
  "Return the hint for the empty compose box.
The box that composes a task says how to press a board key too, which
types in the box otherwise (`harness-ui-tasks--box-key-hint')."
  (pcase harness-ui-tasks--target
    (`(refine . ,id) (concat (if (harness-ui-tasks--duplicate-p (harness-ui-tasks--find id))
                                 "Why it is not a duplicate"
                               "Feedback on the write-up")
                             harness-ui-tasks--ellipsis))
    (`(reject . ,_) (concat "Feedback" harness-ui-tasks--ellipsis))
    (`(search . ,_)
     (concat "Search, or say what to do" harness-ui-tasks--ellipsis
             ;; RET on the empty box does what the search proposes: say so.
             (if-let* ((does (and (fboundp 'harness-ui-tasks-search-proposal-text)
                                  (harness-ui-tasks-search-proposal-text))))
                 (format "  (RET: %s)" does)
               "")))
    (`(edit . ,_) "New prompt…")
    (`(reply . ,_) "Message…")
    (`(answer . ,_) "Answer…")
    (_ (concat "Describe a task…   " (harness-ui-tasks--box-key-hint)))))

(defun harness-ui-tasks--set-compose (text target)
  "Put TEXT in the compose box for TARGET and move there.
Another TARGET ends the search the box took, keys and all
\(`harness-ui-tasks-search-end')."
  (when (and (harness-ui-tasks--searching-p) (not (eq (car target) 'search))
             (fboundp 'harness-ui-tasks-search-end))
    (harness-ui-tasks-search-end))
  (setq harness-ui-tasks--target target)
  (harness-ui-tasks--render-tail text)
  (goto-char harness-compose-end)
  (dolist (w (get-buffer-window-list nil nil t)) (set-window-point w (point))))

;;;; Header line

(defun harness-ui-tasks--segment (text command help)
  "Return the header-line segment TEXT; a click on it runs COMMAND.
HELP is its tooltip."
  (propertize text 'mouse-face 'mode-line-highlight 'help-echo help
              'keymap (harness-ui-mouse-keymap command)))

(defun harness-ui-tasks--queue-suspended-p ()
  "Non-nil when the board's project has its pending queue suspended.
That is the harness's `task/settings' as last fetched: the queue is
running until they say otherwise."
  (harness-json-true-p (plist-get harness-ui-tasks--settings :queue-suspended)))

(defun harness-ui-tasks--queue-help (window _object _pos)
  "The tooltip of the queue switch on the Pending heading of the board in WINDOW.
It says what the switch does now and how to turn it.  A `help-echo'
function, so the keymaps are searched on hover, not on every redraw of
the board."
  (with-current-buffer (if (window-live-p window) (window-buffer window) (current-buffer))
    (let ((keys (substitute-command-keys
                 "\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-toggle-queue]" t)))
      (if (harness-ui-tasks--queue-suspended-p)
          (format "Queue suspended: waiting tasks start only by hand (s).  Click or %s to resume." keys)
        (format "Queue running: waiting tasks start as slots free, by priority.  Click or %s to suspend." keys)))))

(defun harness-ui-tasks--queue-button ()
  "The switch on the Pending heading: [Queue: running] or [Queue: suspended].
It shows whether waiting tasks start on their own, and a click suspends
or resumes the board's project queue (`harness-ui-tasks-toggle-queue').
Suspended, it stands out: the board then waits for you."
  (harness-ui-tasks--button (if (harness-ui-tasks--queue-suspended-p)
                                (propertize "[Queue: suspended]" 'face 'harness-task-attention-face)
                              "[Queue: running]")
                            #'harness-ui-tasks-toggle-queue
                            #'harness-ui-tasks--queue-help
                            'harness-ui-tasks-toggle-queue))

(defun harness-ui-tasks--auto-queue-p ()
  "Non-nil when the board's project queues its written-up tasks itself.
That is its backlog in auto mode, as the harness's `task/settings' said
last (`:backlog-mode'): in manual mode, the default, a written-up task
waits in the Backlog until you queue or start it."
  (equal (format "%s" (or (plist-get harness-ui-tasks--settings :backlog-mode) "manual")) "auto"))

(defun harness-ui-tasks--backlog-mode-help (window _object _pos)
  "The tooltip of the backlog's switch on the board in WINDOW.
It says what the backlog does with a task once it is written up, and
how to switch.  A `help-echo' function, so the keymaps are searched on
hover, not on every redraw of the board."
  (with-current-buffer (if (window-live-p window) (window-buffer window) (current-buffer))
    (let ((keys (substitute-command-keys
                 "\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-toggle-backlog-mode]" t)))
      (if (harness-ui-tasks--auto-queue-p)
          (format "Auto queue: written-up tasks join the queue.  Click or %s for manual." keys)
        (format "Manual queue: written-up tasks wait here until queued (Q) or started (s).  Click or %s for auto." keys)))))

(defun harness-ui-tasks--backlog-mode-button ()
  "The switch on the Backlog's heading: [Manual queue] or [Auto queue].
It shows how written-up tasks leave the backlog, and a click switches
the board's project to the other way (`harness-ui-tasks-toggle-backlog-mode')."
  (harness-ui-tasks--button (if (harness-ui-tasks--auto-queue-p) "[Auto queue]" "[Manual queue]")
                            #'harness-ui-tasks-toggle-backlog-mode
                            #'harness-ui-tasks--backlog-mode-help
                            'harness-ui-tasks-toggle-backlog-mode))

(defun harness-ui-tasks--spend (groups)
  "Return what the tasks of GROUPS cost and who pays, for the header.
GROUPS is what `harness-ui-tasks--visible' returns.  As a chat's header
does for its session, it shows their summed cost, or the plan that pays
for them with its quota windows; the model of new tasks names the
provider whose account stands for them all."
  (harness-ui-format-spend
   (harness-ui-sessions-total
    (delq nil (mapcar #'harness-ui-tasks--session (apply #'append (mapcar #'cdr groups))))
    (plist-get harness-ui-tasks--new :model))
   t "These tasks"))

(defun harness-ui-tasks--spend-segment (groups sep)
  "Return the header's (TEXT PRIORITY MIN) of what the tasks of GROUPS cost.
TEXT, after SEP, is `harness-ui-tasks--spend' and the fullest budget
that applies to the project; MIN leaves the budget out.  A click on
either opens the usage dashboard.  It stays longer than most buttons:
the board says nowhere else how much of the plan is left."
  (let ((spend (harness-ui-tasks--spend groups))
        (budgets (harness-ui-format-budgets harness-ui-tasks--budgets)))
    (list (concat sep (harness-ui-spend-segment
                       (if budgets (concat spend " " harness-ui-tasks--dot " " budgets) spend)))
          75
          (and budgets (concat sep (harness-ui-spend-segment spend))))))

(defun harness-ui-tasks--header (&optional width)
  "Return the header line, fitted to WIDTH, its window's by default.
It holds what the board below does not show: the project, what its
tasks cost and the board's buttons.  How many tasks each column holds
is on the column's heading, and whether finished work waits for review
is a setting (`harness-tasks-require-verification', on the settings
page; \\<harness-ui-tasks-board-map>\\[harness-ui-tasks-toggle-review] here).

In a window too narrow for all of it, [Add session] goes first; the
project's name shortens after it, then [Archived], [BTW] and the other
modules' segments (`harness-ui-tasks-header-functions', the search's
\[Search]) go.  Another module's segment with a priority of its own
goes when that says: the companion pet's face before anything else.
What the tasks cost and the plan's quota stay longer, the budget going
first (`harness-ui-tasks--spend-segment'); [Refresh] and a board still
loading stay longest.  The queue's switch is not here but on the
Pending heading, and the backlog's on its own
\(`harness-ui-tasks--insert-section').  WIDTH is as
`harness-ui-fit-header' takes it."
  (let* ((groups (harness-ui-tasks--visible))
         ;; Other modules' segments: strings join into one, lists stand
         ;; on their own.
         (extra (delq nil (mapcar (lambda (fn) (ignore-errors (funcall fn)))
                                  harness-ui-tasks-header-functions)))
         (joined (cl-remove-if-not #'stringp extra))
         (own (cl-remove-if-not #'consp extra))
         (name (if harness-ui-tasks--project
                   (file-name-nondirectory (directory-file-name harness-ui-tasks--project))
                 (abbreviate-file-name (or harness-ui-tasks--dir ""))))
         (sep "   ")
         (gap (lambda () (prog1 sep (setq sep "  ")))))
    (harness-ui-fit-header
     (append
      (list
       (concat " " (propertize "Tasks" 'face 'bold))
       (list (concat " " (propertize name 'face 'harness-dim-face))
             50 (concat " " (propertize (harness-truncate-end name 6) 'face 'harness-dim-face)))
       (harness-ui-tasks--spend-segment groups (funcall gap))
       ;; Other modules' segments, the search's say.
       (and joined (list (concat (funcall gap) (mapconcat #'identity joined " ")) 65)))
      ;; Those with a priority of their own, the companion pet's say.
      (mapcar (lambda (segment)
                (let ((sep (funcall gap)))
                  (list (concat sep (car segment)) (nth 1 segment)
                        (and (nth 2 segment) (concat sep (nth 2 segment))))))
              own)
      (list
       (list (concat (funcall gap) (harness-ui-tasks--segment "[BTW]" #'harness-ui-tasks-btw
                                                               "Ask about the tasks in a side conversation"))
             60)
       (list (concat " " (harness-ui-tasks--segment "[Add session]" #'harness-ui-tasks-adopt
                                                    "Make an ongoing session of this project a task"))
             20)
       ;; Showing archived tasks is not the usual board: that stays longer.
       (list (concat " " (harness-ui-tasks--segment (if harness-ui-tasks--show-archived "[Hide archived]" "[Archived]")
                                                    #'harness-ui-tasks-toggle-archived "Show or hide archived tasks"))
             (if harness-ui-tasks--show-archived 75 55))
       (list (concat " " (harness-ui-tasks--segment "[Refresh]" #'harness-ui-tasks-refresh "Reload the board")) 80)
       (and harness-ui-tasks--loading (list (propertize "  loading…" 'face 'harness-dim-face) 85))))
     width)))

;;;; Data

(defun harness-ui-tasks--fail (buffer what err)
  "Show on the board BUFFER that WHAT failed with the error ERR.
The board stops loading, and the failure shows above its compose box."
  (when (harness-ui-tasks--board-p buffer)
    (with-current-buffer buffer
      (setq harness-ui-tasks--loading nil
            harness-ui-tasks--error (format "%s failed: %s" what (harness-error-message err)))
      (harness-ui-tasks--render)
      (harness-ui-tasks--render-tail))))

(defun harness-ui-tasks--fetch-budgets (buffer root)
  "Load the status of the budgets that apply to ROOT, BUFFER's project.
The header shows them; without the usage module there are none."
  (harness-ui-call "_harness/usage/project-budgets" (list :project root)
                   (lambda (statuses)
                     (when (harness-ui-tasks--board-p buffer)
                       (with-current-buffer buffer
                         (setq harness-ui-tasks--budgets statuses)
                         (force-mode-line-update))))
                   #'ignore))

(defun harness-ui-tasks--fetch (buffer &optional quiet)
  "Load BUFFER's project root, tasks and settings from the harness.
QUIET refreshes in the background, without the loading indicator."
  (when (harness-ui-tasks--board-p buffer)
    (with-current-buffer buffer
      (unless quiet (setq harness-ui-tasks--loading t))
      (let ((dir harness-ui-tasks--dir))
        (harness-ui-call "_harness/task/settings" (list :cwd dir)
                         (lambda (s) (when (buffer-live-p buffer)
                                       (with-current-buffer buffer
                                         (let ((review (harness-ui-tasks--review-p)))
                                           (setq harness-ui-tasks--settings s)
                                           ;; Review decides whether the board shows
                                           ;; Ready for review when it is empty.
                                           (unless (eq review (harness-ui-tasks--review-p))
                                             (harness-ui-tasks--render)))
                                         (unless harness-ui-tasks--new
                                           (setq harness-ui-tasks--new
                                                 (list :model (plist-get s :model)
                                                       :thinking (plist-get s :thinking)
                                                       :permission-mode (plist-get s :permission-mode)
                                                       :non-interactive (harness-json-true-p
                                                                         (plist-get s :non-interactive)))))
                                         ;; The supervisor setting appears with
                                         ;; its module, without overriding a
                                         ;; choice already made on the board.
                                         (when (and (plist-member s :supervisor)
                                                    (not (plist-member harness-ui-tasks--new :supervisor)))
                                           (setq harness-ui-tasks--new
                                                 (plist-put (copy-sequence harness-ui-tasks--new) :supervisor
                                                            (if (harness-json-true-p (plist-get s :supervisor))
                                                                t :false))))
                                         ;; So do the models of the write-up, the
                                         ;; plan and the planned work, once the
                                         ;; harness says what they are.
                                         (dolist (step harness-ui-tasks--step-keys)
                                           (dolist (key (cdr step))
                                             (when (and (plist-member s key)
                                                        (not (plist-member harness-ui-tasks--new key)))
                                               (setq harness-ui-tasks--new
                                                     (plist-put (copy-sequence harness-ui-tasks--new) key
                                                                (plist-get s key))))))
                                         ;; The header's spend goes by the new tasks' model.
                                         (force-mode-line-update)
                                         (when (and (harness-compose-live-p) (null harness-ui-tasks--target))
                                           (harness-ui-tasks--render-tail)))))
                         #'ignore)
        (harness-ui-call
         "_harness/project/root" (list :cwd dir)
         (lambda (root)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer (setq harness-ui-tasks--project root)))
           (harness-ui-tasks--fetch-budgets buffer root)
           (harness-ui-call
            "_harness/task/list" (list :cwd dir)
            (lambda (tasks)
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (setq harness-ui-tasks--tasks tasks
                        harness-ui-tasks--loading nil)
                  (harness-ui-tasks--render))))
            (lambda (e) (harness-ui-tasks--fail buffer "Loading tasks" e))))
         (lambda (e) (harness-ui-tasks--fail buffer "Finding the project" e)))))))

(defun harness-ui-tasks--schedule-render (buffer)
  "Redraw the board BUFFER soon, once a burst of calls for it settles.
It is drawn 0.1 seconds after the last call, if it is still a board.  A
board no window shows is not drawn for them: the session cache changes
many times a second while agents work, and a window that shows the
board again loads it anew (`harness-ui-tasks--catch-up')."
  (when (harness-ui-view-follow-p buffer)
    (harness-debounce (list 'harness-ui-tasks buffer) 0.1
                      (lambda () (when (harness-ui-tasks--board-p buffer)
                                   (with-current-buffer buffer (harness-ui-tasks--render)))))))

(defconst harness-ui-tasks--refresh-events
  '("merge/queued" "merge/started" "merge/conflict" "merge/finished"
    "agent/turn-started" "agent/turn-ended" "session/status" "session/pending-changed"
    "session/created" "session/deleted" "worktree/created" "worktree/removed"
    "harness/reloaded" "config/changed" "task/queue" "task/backlog-mode"
    "usage/budgets-changed" "usage/budget-warning")
  "Events after which every board quietly reloads its tasks and budgets.
`task/changed' and `task/deleted' update a board directly; these catch
anything that moves a task without one, so a board never drifts.  A
turn's end and the budget events also change what its budgets show,
`task/queue' changes the queue switch's state in the settings, and
`task/backlog-mode' the backlog's switch between a manual and an auto
queue.  The
creation, status change and deletion of an internal session reload no
board (`harness-ui-internal-event-p'): the harness makes one for every
model call of its own, and none moves a task.")

(defun harness-ui-tasks--refresh-soon (buffer)
  "Reload BUFFER's tasks in the background, once a burst of events settles.
Not a board no window shows, which asks the harness for its tasks anew
when a window shows it again (`harness-ui-tasks--catch-up'): until then
it would ask, and draw what it got, for every burst of events of any
project."
  (when (harness-ui-view-follow-p buffer)
    (harness-debounce (list 'harness-ui-tasks-refresh buffer) 0.3
                      (lambda () (when (harness-ui-tasks--board-p buffer) (harness-ui-tasks--fetch buffer t))))))

(defun harness-ui-tasks--catch-up ()
  "Reload this board, which missed changes while no window showed it.
Called when a window shows it again, or when it is woken
\(`harness-ui-view-install')."
  (harness-ui-tasks--refresh-soon (current-buffer)))

(defun harness-ui-tasks--on-window-change (window)
  "Reload the board shown in WINDOW, which may have missed events while hidden."
  (when (harness-ui-tasks--board-p (window-buffer window))
    (harness-ui-tasks--refresh-soon (window-buffer window))))

(defun harness-ui-tasks--on-resize (window)
  "Redraw the board in WINDOW so its cards and tail fit the new width."
  (let ((buffer (window-buffer window)))
    (when (harness-ui-tasks--board-p buffer)
      (harness-ui-tasks--schedule-render buffer)
      (harness-debounce (list 'harness-ui-tasks-refit buffer) 0.1
                        (lambda () (when (harness-ui-tasks--board-p buffer)
                                     (with-current-buffer buffer (harness-ui-tasks--refit-tail))))))))

(defun harness-ui-tasks--on-event (event args)
  "Follow EVENT with ARGS on every board; reload them after related events.
A task event updates the boards it concerns, and a task ready for
review is announced when `harness-ui-tasks--notify-review' is non-nil.
A task's priority is its session's, so a board with a card of the
session whose `:ext' changed reloads: the task's view, which carries
the level the card shows, is asked for again.  Those of an internal
session (see `harness-ui-tasks--refresh-events') reload none."
  (when (and (member event harness-ui-tasks--refresh-events)
             (not (harness-ui-internal-event-p event args)))
    (mapc #'harness-ui-tasks--refresh-soon (harness-ui-tasks--buffers)))
  (pcase event
    ("session/ext-changed"
     (when (member (format "%s" (cadr args)) '(":priority" "priority"))
       (dolist (b (harness-ui-tasks--buffers))
         (when (cl-some (lambda (task) (equal (plist-get task :session) (car args)))
                        (buffer-local-value 'harness-ui-tasks--tasks b))
           (harness-ui-tasks--refresh-soon b)))))
    ("task/changed"
     (let ((task (car args)))
       (dolist (b (harness-ui-tasks--buffers))
         (with-current-buffer b
           (when (equal (plist-get task :project) harness-ui-tasks--project)
             (setq harness-ui-tasks--tasks
                   (cons task (cl-remove (plist-get task :id) harness-ui-tasks--tasks
                                         :key (lambda (x) (plist-get x :id)) :test #'equal)))
             (harness-ui-tasks--schedule-render b))))))
    ("task/review"
     (when harness-ui-tasks--notify-review
       (message "Task %s is ready for your review"
                (harness-ui-tasks--quote (harness-ui-tasks--title (car args))))))
    ("task/deleted"
     (let ((id (car args)))
       (dolist (b (harness-ui-tasks--buffers))
         (with-current-buffer b
           (when (harness-ui-tasks--find id)
             (setq harness-ui-tasks--tasks
                   (cl-remove id harness-ui-tasks--tasks :key (lambda (x) (plist-get x :id)) :test #'equal))
             (when (equal (cdr harness-ui-tasks--target) id) (harness-ui-tasks-compose-reset))
             (harness-ui-tasks--schedule-render b))))))))

(defun harness-ui-tasks--on-sessions-changed ()
  "Session names, statuses, todos and costs feed the cards."
  (dolist (b (harness-ui-tasks--buffers))
    (when (buffer-local-value 'harness-ui-tasks--tasks b)
      (harness-ui-tasks--schedule-render b))))

(defun harness-ui-tasks--on-redraw ()
  "Reload every board after a reload or reconnect."
  (mapc #'harness-ui-tasks--fetch (harness-ui-tasks--buffers)))

(defun harness-ui-tasks--on-quota (_provider _quota)
  "Redraw the boards' header lines, which show the plan's quota."
  (dolist (b (harness-ui-tasks--buffers))
    (with-current-buffer b (force-mode-line-update))))

(defvar harness-ui-tasks--timer nil "Refreshes elapsed times on visible boards.")

(defvar harness-ui-tasks-tick-hook nil
  "Hook run, with no arguments, each time the boards' clock ticks.
That is every `harness-ui-tasks--tick-interval' seconds, after every
board a window shows was drawn again for its elapsed times.  A view
whose times run as the board's do -- the task slots page -- hangs its
redraw here instead of keeping a timer of its own.")

(defun harness-ui-tasks--tick ()
  "Redraw every board a window shows, so its elapsed times run.
Then run `harness-ui-tasks-tick-hook', for the views that keep time
with the boards."
  (dolist (b (harness-ui-tasks--buffers))
    (when (get-buffer-window b t)
      (with-current-buffer b (harness-ui-tasks--render))))
  (run-hooks 'harness-ui-tasks-tick-hook))

;;;; Mode

(defvar harness-ui-tasks-board-map (make-sparse-keymap)
  "Keys on the board (outside the compose box).
The keys that act on the task at point act on the card point is on:
off a card they type, into the compose box, as every letter the board
does not bind does (`harness-ui-tasks--on-card-p').")

(defun harness-ui-tasks--on-card-p ()
  "Nil when point is on a task board but not on a card.
The board's keys for the task at point have nothing to act on there,
so they type, into the compose box (`harness-compose-acts-p')."
  (or (not (harness-ui-tasks--board-p (current-buffer)))
      (get-text-property (point) 'harness-task-id)))

;; Typing off a card, the board's keys for the task at point (see above).
(dolist (command '(harness-ui-tasks-open-other harness-ui-tasks-start harness-ui-tasks-queue
                   harness-ui-tasks-edit harness-ui-tasks-retry
                   harness-ui-tasks-reply harness-ui-tasks-requests harness-ui-tasks-refine
                   harness-ui-tasks-allow harness-ui-tasks-deny harness-ui-tasks-cancel
                   harness-ui-tasks-complete harness-ui-tasks-verify harness-ui-tasks-reject
                   harness-ui-tasks-merge harness-ui-tasks-archive harness-ui-tasks-delete
                   harness-ui-tasks-raise-priority harness-ui-tasks-lower-priority
                   harness-ui-tasks-attach harness-ui-tasks-assume-worktree))
  (put command 'harness-compose-acts-p #'harness-ui-tasks--on-card-p))

;; Filled at top level, not in the `defvar', so a reload updates the map.
(let ((map harness-ui-tasks-board-map))
  (define-key map (kbd "RET") #'harness-ui-tasks-open)
  (define-key map (kbd "o") #'harness-ui-tasks-open-other)
  (define-key map [mouse-1] #'harness-ui-tasks-mouse-open)
  (define-key map [mouse-3] #'harness-ui-tasks-context-menu)
  (define-key map (kbd "TAB") #'harness-ui-tasks-tab)
  (define-key map (kbd "<backtab>") #'harness-ui-tasks-previous)
  (define-key map (kbd "a") #'harness-ui-tasks-compose)
  (define-key map (kbd "s") #'harness-ui-tasks-start)
  (define-key map (kbd "t") #'harness-ui-tasks-retry)
  (define-key map (kbd "Q") #'harness-ui-tasks-queue)
  ;; The Backlog heading's switch: write-ups queued by hand or by
  ;; themselves.  Not B, which once edited many tasks at once.
  (define-key map (kbd "W") #'harness-ui-tasks-toggle-backlog-mode)
  (define-key map (kbd "e") #'harness-ui-tasks-edit)
  (define-key map (kbd "m") #'harness-ui-tasks-reply)
  (define-key map (kbd "SPC") #'harness-ui-tasks-requests)
  (define-key map (kbd "r") #'harness-ui-tasks-refine)
  (define-key map (kbd "y") #'harness-ui-tasks-allow)
  (define-key map (kbd "n") #'harness-ui-tasks-deny)
  (define-key map (kbd "+") #'harness-ui-tasks-raise-priority)
  (define-key map (kbd "-") #'harness-ui-tasks-lower-priority)
  (define-key map (kbd "@") #'harness-ui-tasks-attach)
  ;; The task's worktree as the project, to look at its files (worktree-assume).
  (define-key map (kbd "w") #'harness-ui-tasks-assume-worktree)
  (define-key map (kbd "u") #'harness-ui-tasks-pause)
  (define-key map (kbd "U") #'harness-ui-tasks-resume)
  (define-key map (kbd "P") #'harness-ui-tasks-toggle-queue)
  ;; The project's slots: who holds them, who waits (harness-ui-slots.el).
  (define-key map (kbd "S") #'harness-ui-tasks-slots)
  (define-key map (kbd "k") #'harness-ui-tasks-cancel)
  (define-key map (kbd "d") #'harness-ui-tasks-complete)
  (define-key map (kbd "v") #'harness-ui-tasks-verify)
  (define-key map (kbd "R") #'harness-ui-tasks-reject)
  (define-key map (kbd "M") #'harness-ui-tasks-merge)
  (define-key map (kbd "x") #'harness-ui-tasks-archive)
  (define-key map (kbd "X") #'harness-ui-tasks-archive-done)
  (define-key map (kbd "D") #'harness-ui-tasks-delete)
  (define-key map (kbd "A") #'harness-ui-tasks-toggle-archived)
  (define-key map (kbd "V") #'harness-ui-tasks-toggle-review)
  (define-key map (kbd "I") #'harness-ui-tasks-adopt)
  (define-key map (kbd "b") #'harness-ui-tasks-btw)
  (define-key map (kbd "/") #'harness-ui-tasks-search)
  (define-key map (kbd "g") #'harness-ui-tasks-refresh)
  (define-key map (kbd "F") #'harness-fullscreen)
  (define-key map (kbd "q") #'harness-ui-quit-view)
  (define-key map (kbd "?") #'harness-menu))

(defvar harness-ui-tasks-mode-map
  ;; No `special-mode-map' parent: its letters would eat typing in the compose box.
  (let ((map (make-sparse-keymap))) (set-keymap-parent map (make-sparse-keymap)) map)
  "Keymap of `harness-ui-tasks-mode'.")

(let ((map harness-ui-tasks-mode-map))
  ;; The compose box's keys (RET newline, C-c C-a, C-y pasting images).
  (set-keymap-parent map harness-compose-map)
  (define-key map (kbd "C-c C-c") #'harness-ui-tasks-submit)
  (define-key map (kbd "C-c C-k") #'harness-ui-tasks-compose-reset)
  (define-key map (kbd "C-c C-t") #'harness-ui-tasks-cycle-mode)
  ;; C-g, as a remapping: completion popups (corfu, company) keep their
  ;; C-g, and with no box to leave it falls back to the global one.
  (define-key map [remap keyboard-quit] #'harness-ui-tasks-compose-quit)
  (define-key map (kbd "C-c C-n") #'harness-ui-tasks-next)
  (define-key map (kbd "C-c C-p") #'harness-ui-tasks-previous)
  ;; q's job from the compose box too, where q is typing.
  (define-key map (kbd "C-c C-z") #'harness-ui-bury))

(define-derived-mode harness-ui-tasks-mode special-mode "Tasks"
  "Major mode of the task board: a kanban of tasks above a compose box.
On the board the keys below act on the board, or on the task whose card
point is on.  Any other letter goes into the compose box, and so does a
task's key typed off a card.

In the box, \\<harness-compose-map>\\[harness-compose-panel-key] and then a key presses that key of the board: F, the
fullscreen layout, say.  The keys for the task at point have no task to
act on from there.

\\{harness-ui-tasks-board-map}"
  (setq buffer-read-only nil)
  ;; Lines wrap, for the compose box (`harness-compose-setup'): the board
  ;; fits its lines to the window instead of relying on truncation.
  (setq-local header-line-format '(:eval (harness-ui-tasks--header)))
  (add-hook 'window-buffer-change-functions #'harness-ui-tasks--on-window-change nil t)
  (add-hook 'window-size-change-functions #'harness-ui-tasks--on-resize nil t)
  ;; Not drawn or reloaded while no window shows it (`harness-ui-tasks--schedule-render'),
  ;; so it says it is suspended if a window shows it before it catches up.
  (harness-ui-view-install #'harness-ui-tasks--catch-up)
  (setq harness-ui-setting-target-function #'harness-ui-tasks--setting-target)
  ;; What the session at point waits on (the popout), from the card at point.
  (setq-local harness-ui-session-at-point-function
              (lambda ()
                (and (harness-ui-tasks--board-p (current-buffer))
                     (plist-get (harness-ui-tasks--task t) :session))))
  ;; An overview: the board can take the fullscreen layout (F).
  (setq-local harness-ui-overview-function #'harness-ui-tasks--overview-session)
  ;; A BTW over the board (b, [BTW], or the usual BTW command) asks about its tasks.
  (setq-local harness-ui-btw-start-function #'harness-ui-tasks--start-btw
              harness-ui-btw-about "the tasks")
  (harness-compose-setup :project (lambda () harness-ui-tasks--dir)
                         :placeholder #'harness-ui-tasks--placeholder
                         :redraw #'harness-ui-tasks--render-tail
                         ;; The board stays at the top; the gap opens between it and the box.
                         :bottom (lambda () (marker-position harness-ui-tasks--list-end))))

;; The board's keys in the harness menu: its letters behind `.', the
;; compose box's chords as they are.
(put 'harness-ui-tasks-mode 'harness-menu-group
     '("Task board"
       ["Task at point"
        (". RET" "Open its session" harness-ui-tasks-open)
        (". o" "Open in position" harness-ui-tasks-open-other)
        (". TAB" "Fold the section or the recap" harness-ui-tasks-tab)
        (". s" "Start now" harness-ui-tasks-start)
        (". Q" "Queue it (start it when a slot frees)" harness-ui-tasks-queue)
        (". e" "Edit prompt" harness-ui-tasks-edit)
        (". m" "Message session" harness-ui-tasks-reply)
        (". t" "Retry a task that stopped" harness-ui-tasks-retry)
        (". SPC" "View what point needs" harness-ui-tasks-requests)
        (". r" "Refine" harness-ui-tasks-refine)
        (". +" "Raise priority" harness-ui-tasks-raise-priority)
        (". -" "Lower priority" harness-ui-tasks-lower-priority)
        (". @" "Attach to the box" harness-ui-tasks-attach)
        (". w" "Assume its worktree as the project, or reset" harness-ui-tasks-assume-worktree)
        (". y" "Allow request" harness-ui-tasks-allow)
        (". n" "Deny request" harness-ui-tasks-deny)]
       ["Finish"
        (". k" "Stop or drop" harness-ui-tasks-cancel)
        (". u" "Pause (hold in the queue)" harness-ui-tasks-pause)
        (". U" "Resume a paused task" harness-ui-tasks-resume)
        (". v" "Verify (accept)" harness-ui-tasks-verify)
        (". R" "Send back with feedback" harness-ui-tasks-reject)
        (". d" "Mark completed" harness-ui-tasks-complete)
        (". M" "Merge again" harness-ui-tasks-merge)
        (". x" "Archive or restore" harness-ui-tasks-archive)
        (". D" "Delete" harness-ui-tasks-delete)]
       ["Board"
        (". a" "New task" harness-ui-tasks-compose)
        (". /" "Search: tasks, sessions, commands" harness-ui-tasks-search)
        (". I" "Adopt a session" harness-ui-tasks-adopt)
        (". X" "Archive completed" harness-ui-tasks-archive-done)
        (". A" "Show archived" harness-ui-tasks-toggle-archived)
        (". W" "Backlog: manual or auto queue" harness-ui-tasks-toggle-backlog-mode)
        (". P" "Suspend or resume the queue" harness-ui-tasks-toggle-queue)
        (". S" "Task slots: who holds them, who waits" harness-ui-tasks-slots)
        (". V" "Review on or off" harness-ui-tasks-toggle-review)
        (". F" "Fullscreen layout" harness-fullscreen)
        (". g" "Refresh" harness-ui-tasks-refresh)
        ("C-c C-z" "Bury (q)" harness-ui-bury)]
       ["Compose box"
        ("C-c C-c" "Submit" harness-ui-tasks-submit)
        ("C-c C-t" "Submit, Refine or Plan" harness-ui-tasks-cycle-mode)
        ("C-c C-k" "Clear" harness-ui-tasks-compose-reset)
        ("C-c C-a" "Attach file or task" harness-compose-add-attachment)
        ("C-c ." "A board key, from the box" harness-compose-panel-key)
        ("C-y" "Paste; an image attaches" harness-compose-yank)]))

(defun harness-ui-tasks--buffer-name (dir)
  "Return the name of the board buffer for the project directory DIR."
  (format "*harness tasks: %s*" (file-name-nondirectory (directory-file-name dir))))

(defun harness-ui-tasks--local-root (dir)
  "Guess DIR's project root in this Emacs, for naming the buffer only.
From a task's worktree it is the main checkout, so the board opened
there is the project's."
  (harness-files-main-root dir))

(defun harness-ui-tasks--overview-session ()
  "Return the session to show beside the board in the fullscreen layout.
That is the session of the task at point, else the most recently
updated session of the board's tasks, archived ones aside."
  (or (and (harness-ui-tasks--board-p (current-buffer))
           (plist-get (harness-ui-tasks--task t) :session))
      (let (best newest)
        (dolist (task harness-ui-tasks--tasks best)
          (when-let* ((sid (plist-get task :session))
                      ((not (harness-ui-tasks--archived-p task))))
            (let ((updated (or (plist-get (harness-ui-session sid) :updated) 0)))
              (when (or (null best) (> updated newest))
                (setq best sid newest updated))))))))

(defun harness-ui-tasks--board-of-session (session-id)
  "Return the open board listing the task SESSION-ID works on, or nil."
  (and session-id
       (cl-find-if (lambda (board)
                     (cl-find session-id (buffer-local-value 'harness-ui-tasks--tasks board)
                              :key (lambda (task) (plist-get task :session)) :test #'equal))
                   (harness-ui-tasks--buffers))))

(declare-function project-root "project")

;;;###autoload
(defun harness-tasks (&optional directory position)
  "Show the task board of DIRECTORY's project (the current one by default).
Task mode runs one session per task: submit tasks from the compose box
at the bottom and follow them from pending to completed.

Without DIRECTORY, in the buffer of a task's session it is the open
board that lists the task, whatever directory the session works in:
from a session opened on a board, the board's key leads back to it.

The board takes a position like a session does (`harness-ui-positions')
and replaces whatever is shown there; opening a task's session from it
puts the session in the same position.  POSITION defaults to the one the
board had last, then to `harness-ui-default-position'; with a prefix
argument it is read.  In the `fullscreen' position the board stays on
the left of the frame and the sessions open beside it (see
`harness-fullscreen'): F on the board starts or ends that layout."
  (interactive (list nil (and current-prefix-arg (harness-ui-read-position))))
  (let* ((own (and (null directory) (harness-ui-tasks--board-of-session harness-ui-session-id)))
         (root (unless own
                 (file-name-as-directory
                  (expand-file-name (harness-ui-tasks--local-root
                                     (file-name-as-directory
                                      (expand-file-name (or directory default-directory))))))))
         (buf (or own (get-buffer-create (harness-ui-tasks--buffer-name root)))))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-tasks-mode)
        (harness-ui-tasks-mode)
        (setq default-directory root
              harness-ui-tasks--dir root
              harness-ui-tasks--mode (pcase harness-ui-tasks-refine-by-default
                                       ('nil 'submit)
                                       ('plan 'plan)
                                       (_ 'refine)))
        (harness-ui-tasks--render)
        (harness-ui-tasks--render-tail "")
        (goto-char harness-compose-end)
        (harness-compose-fetch-completions))
      (harness-ui-tasks--fetch buf))
    (harness-ui-refresh-sessions)
    (harness-ui-display-view buf position)))

;;;; Commands

(defun harness-ui-tasks--task (&optional noerror)
  "Return the task at point.
Without one, return nil if NOERROR is non-nil, else signal a user error."
  (or (let ((id (get-text-property (point) 'harness-task-id)))
        (and id (harness-ui-tasks--find id)))
      (unless noerror (user-error "No task here"))))

(defun harness-ui-tasks-attach ()
  "Attach the task at point to the board's compose box.
The message the box sends tells the model what the task is, and its
reference, @task:ID, goes into the box (`harness-compose-attach-task').
Off a card, @ types into the box, as the board's other keys for a task
do."
  (interactive)
  (harness-compose-attach-task (harness-ui-tasks--task)))

(defun harness-ui-tasks-assume-worktree ()
  "Assume the worktree of the task at point as the project, or reset it.
The task's worktree stands in for its project (`worktree-assume'):
until it is reset, `project-find-file', `project-dired', projectile and
the rest work on the worktree from any buffer of the project, as if it
were the project, to look at the files of a task under review.  On the
task whose worktree is assumed already, reset: the project is its main
checkout again.  The harness itself keeps finding the project, so this
board, and the task on it, stay as they are."
  (interactive)
  (let* ((task (harness-ui-tasks--task))
         (worktree (or (harness-ui-tasks--assumable-worktree task)
                       (user-error "This task has no worktree to assume%s"
                                   (if (plist-get task :worktree) ": its directory is gone" "")))))
    (if (worktree-assume-parent worktree)
        (let ((reset (worktree-assume-reset worktree)))
          (message "%s is its own worktree again"
                   (abbreviate-file-name (or (caar reset) worktree))))
      (worktree-assume worktree
                       (or (plist-get task :project) harness-ui-tasks--project harness-ui-tasks--dir)))))

(defun harness-ui-tasks--on-error (what)
  "Return a handler of a failed request that shows on this board WHAT failed."
  (let ((buffer (current-buffer)))
    (lambda (e) (harness-ui-tasks--fail buffer what e))))

(defun harness-ui-tasks--request-then (method params what &optional callback)
  "Call METHOD with PARAMS; failures show in the buffer as WHAT failing.
CALLBACK, when non-nil, is called with the result.

The button the request is for, one pushed or the card's button of the
command typed (`harness-ui-tasks--request-key'), stays held down until
the request is answered, or fails, and then no sooner than
`harness-ui-tasks--pressed-min-seconds' after it was pushed."
  (setq harness-ui-tasks--error nil)
  (let* ((key (harness-ui-tasks--request-key))
         (answered (harness-ui-tasks--count-request key))
         (sent nil))
    (unwind-protect
        (prog1 (harness-ui-call method params
                                (harness-ui-tasks--answering key answered (or callback #'ignore))
                                (harness-ui-tasks--answering key answered (harness-ui-tasks--on-error what)))
          (setq sent t))
      ;; A request that never left has no answer to wait for.
      (when (and answered (not sent)) (funcall answered)))))

(defun harness-ui-tasks-task-at-point (&optional noerror)
  "Return the task at point on a task board, a plist as the board has it.
Without one, return nil if NOERROR is non-nil, else signal a user
error.  For the commands of `harness-ui-tasks-action-functions'."
  (harness-ui-tasks--task noerror))

(defun harness-ui-tasks-request (method params what &optional callback)
  "Call the harness's METHOD with PARAMS from a task board.
METHOD is an ACP method, \"_harness/NAME\" for the bus method NAME.  A
failure shows on the board, as WHAT failing, as one of the board's own
requests would; CALLBACK, when non-nil, is called with the result.
For the commands of `harness-ui-tasks-action-functions', which run in
the board's buffer."
  (harness-ui-tasks--request-then method params what callback))

(defun harness-ui-tasks-open (&optional position)
  "Open the session of the task at point in POSITION.
By default it takes the board's own position, replacing the board."
  (interactive)
  (let* ((task (harness-ui-tasks--task))
         (sid (plist-get task :session))
         (open (harness-ui-session-opener position)))
    (unless sid (user-error "This task has not started yet; s starts it now"))
    (funcall open sid)))

(defun harness-ui-tasks-open-other ()
  "Open the session of the task at point in a position read from the user."
  (interactive)
  (harness-ui-tasks-open (harness-ui-read-position)))

(defun harness-ui-tasks-mouse-open (event)
  "Open the task clicked in EVENT, or toggle the clicked section."
  (interactive "e")
  (mouse-set-point event)
  (if (get-text-property (point) 'harness-task-section)
      (harness-ui-tasks-tab)
    (when (harness-ui-tasks--task t) (harness-ui-tasks-open))))

(defun harness-ui-tasks-context-menu (event)
  "Pop up the actions of the task clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (when-let* ((task (harness-ui-tasks--task t)))
    (popup-menu
     (cons (harness-ui-tasks--title task)
           (mapcar (lambda (a) (vector (car a) (nth 1 a) t))
                   (harness-ui-tasks--actions task)))
     event)))

(defun harness-ui-tasks-toggle-subtitle ()
  "Show or hide the recap subtitle of the task card at point.
A card's column decides by default -- shown when a task requires your
input, folded everywhere else -- and your choice for a card stays with
it, whatever column it moves to."
  (interactive)
  (let ((id (get-text-property (point) 'harness-task-id)))
    (unless id (user-error "Point is not on a task card"))
    (let ((task (harness-ui-tasks--find id)))
      (harness-ui-tasks--set-subtitle id (not (harness-ui-tasks--subtitle-shown-p task)))
      (harness-ui-tasks--render)
      ;; A card that shrank keeps point on itself, not on the line below.
      (when-let* ((start (harness-ui-tasks--key-start (cons 'harness-task-id id))))
        (goto-char start)
        (skip-chars-forward " ")))))

(defun harness-ui-tasks-tab ()
  "Fold the section or card at point, or move to the next task.
A heading folds its column; a card shows or hides its recap subtitle."
  (interactive)
  (cond
   ((get-text-property (point) 'harness-task-section)
    (let ((column (get-text-property (point) 'harness-task-section)))
      (setq harness-ui-tasks--folded
            (if (memq column harness-ui-tasks--folded)
                (delq column harness-ui-tasks--folded)
              (cons column harness-ui-tasks--folded)))
      (harness-ui-tasks--render)))
   ((get-text-property (point) 'harness-task-id)
    (harness-ui-tasks-toggle-subtitle))
   (t (harness-ui-tasks-next))))

(defun harness-ui-tasks--move (forward)
  "Move point to the next card when FORWARD is non-nil, else the previous.
Point goes to the card's first non-blank character; with no card that
way, it stays and a message says so."
  (let ((here (get-text-property (point) 'harness-task-id))
        (pos (point)))
    (while (and (if forward (< pos (point-max)) (> pos (point-min)))
                (let ((id (get-text-property pos 'harness-task-id)))
                  (or (null id) (equal id here))))
      (setq pos (if forward (1+ pos) (1- pos))))
    (let ((id (get-text-property pos 'harness-task-id)))
      (if (null id)
          (message "No more tasks")
        (unless forward
          (while (and (> pos (point-min)) (equal (get-text-property (1- pos) 'harness-task-id) id))
            (setq pos (1- pos))))
        (goto-char pos)
        (skip-chars-forward " ")))))

(defun harness-ui-tasks-next ()
  "Move to the next task."
  (interactive)
  (harness-ui-tasks--move t))

(defun harness-ui-tasks-previous ()
  "Move to the previous task."
  (interactive)
  (harness-ui-tasks--move nil))

(defun harness-ui-tasks-compose ()
  "Move to the compose box to describe a new task."
  (interactive)
  (cond
   ;; The search closes, and the task being described comes back.
   ((harness-ui-tasks--searching-p) (harness-ui-tasks-compose-reset))
   (harness-ui-tasks--target (harness-ui-tasks--set-compose "" nil))
   (t (goto-char harness-compose-end))))

(defun harness-ui-tasks-compose-reset ()
  "Empty the compose box and make it describe a new task again.
The board's search box closes instead, and the box gets back what it
held before (`harness-ui-tasks-search-leave')."
  (interactive)
  (if (and (harness-ui-tasks--searching-p) (fboundp 'harness-ui-tasks-search-leave))
      (harness-ui-tasks-search-leave)
    (setq harness-compose-attachments nil)
    (harness-ui-tasks--set-compose "" nil)))

(defun harness-ui-tasks-compose-quit ()
  "Leave the answer, message, edit or search box, or show every task again.
On the board \\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-compose-quit] runs this.  Leaving is what
`harness-ui-tasks-compose-reset' does: the box describes a new task
again, or, leaving the search box, gets back what it held before.  A
question it was answering is not cancelled: it stays waiting on its
task, whose card's [Answer] comes back to it.  With no such box
to leave, a board showing some tasks only (`harness-ui-tasks-filter',
a search's) shows them all again.  With an active region, completion in
progress, an open minibuffer or nothing of the sort, this quits the
usual way instead."
  (interactive)
  (cond
   ((or (region-active-p) completion-in-region-mode (active-minibuffer-window))
    (harness-ui-tasks--keyboard-quit))
   ((harness-ui-tasks--searching-p)
    (harness-ui-tasks-compose-reset)
    (message "Search closed"))
   (harness-ui-tasks--target
    (let ((answering (eq (car harness-ui-tasks--target) 'answer)))
      (harness-ui-tasks-compose-reset)
      (message (if answering "The question is still waiting" "Back to a new task"))))
   ((plist-get harness-ui-tasks-filter :clear)
    (funcall (plist-get harness-ui-tasks-filter :clear))
    (message "Showing every task"))
   (t (harness-ui-tasks--keyboard-quit))))

(defun harness-ui-tasks--keyboard-quit ()
  "Quit the usual way, which the board's own remapping hides.
That is `keyboard-quit', or what the global map remaps it to (Doom's
`doom/escape', say)."
  (let ((command (or (command-remapping 'keyboard-quit nil (current-global-map)) #'keyboard-quit)))
    (setq this-command command)
    (call-interactively command)))

(defun harness-ui-tasks-submit ()
  "Submit the compose box: a new task, an edited prompt, a message or an answer.
A new task starts, or with the toggle on Refine or Plan goes to the
backlog (see `harness-ui-tasks-cycle-mode').  /skill references are expanded
and attachments go along, as in a chat.  The board's search box sends
its line to the search instead (`harness-ui-tasks-search-submit')."
  (interactive)
  (if (harness-ui-tasks--searching-p)
      ;; Before `harness-compose-take', which refuses an empty box: an
      ;; empty search line does what the search proposes.
      (harness-ui-tasks-search-submit (harness-compose-text))
    (harness-ui-tasks--submit-compose)))

(defun harness-ui-tasks--submit-compose ()
  "Submit what the compose box holds for a task (see `harness-ui-tasks-submit').
A harness that does not plan tasks yet, which its settings say by
naming no plan model, is not sent one to plan: it would start it."
  (when (and (null harness-ui-tasks--target) (eq harness-ui-tasks--mode 'plan)
             harness-ui-tasks--settings (not (plist-member harness-ui-tasks--settings :plan-model)))
    (user-error "This harness does not plan tasks: update it, or switch to Submit or Refine (%s)"
                (substitute-command-keys "\\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-cycle-mode]")))
  (pcase-let* ((`(,text . ,atts) (harness-compose-take))
               (target harness-ui-tasks--target)
               (mode harness-ui-tasks--mode)
               (buffer (current-buffer))
               ;; The box's own attachments, not the files its @ references
               ;; name: an answer mentioning a file goes as the text it is.
               (own (harness-compose-without-references harness-compose-attachments text)))
    (setq harness-ui-tasks--error nil
          harness-compose-attachments nil)
    (harness-ui-tasks--set-compose "" nil)
    (if (eq (car target) 'answer)
        (harness-ui-tasks--answer (harness-ui-tasks--find (cdr target)) text own)
      (unless target
        (push text harness-ui-tasks--submitting)
        (harness-ui-tasks--render))
      (harness-compose-with-expanded-text
       text
       (lambda (expanded)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (harness-ui-tasks--send target text expanded atts mode))))))))

(defun harness-ui-tasks--new-opts (&optional mode)
  "The new-task settings as `task/submit' options (unset ones are left out).
MODE is the compose box's mode for the task, `submit' by default.
Refine sends `:refine' and the write-up's model and thinking level as
`:refine-model' and `:refine-thinking'; Plan sends `:plan', the plan's
model and thinking level as those, and the planned work's as `:model'
and `:thinking' (see `harness-ui-tasks--step-keys').  Supervisor mode is
sent only when the harness has its module, which `task/settings' says
by carrying the setting, and never in Plan: a planned task works
hands-on, its plan made already (`harness-ui-tasks--work-supervisor-p')."
  (let* ((new harness-ui-tasks--new)
         (work (harness-ui-tasks--step-values (and (eq mode 'plan) 'plan-work)))
         (first (and (memq mode '(refine plan)) (harness-ui-tasks--step-values mode))))
    (append (pcase mode ('refine (list :refine t)) ('plan (list :plan t)))
            (and (plist-get first :model) (list :refine-model (plist-get first :model)))
            (and (plist-get first :thinking) (list :refine-thinking (plist-get first :thinking)))
            (cl-loop for k in '(:model :thinking :permission-mode)
                     when (plist-get work k) append (list k (plist-get work k)))
            (and new (list :non-interactive (if (harness-json-true-p (plist-get new :non-interactive)) t :false)))
            (and (plist-member harness-ui-tasks--settings :supervisor) (not (eq mode 'plan))
                 (list :supervisor (if (harness-json-true-p (plist-get new :supervisor)) t :false)))
            (and (harness-json-true-p (plist-get new :main-tree)) (list :main-tree t))
            (and (plist-get new :priority) (list :priority (harness-ui-tasks--priority new))))))

(defun harness-ui-tasks--reset-once-modes ()
  "Drop the choices armed for one task only, after a submission.
A sticky main-tree or priority choice stays; a `once' one resets to the
worktree and medium priority, and the tail is redrawn."
  (let ((main (eq harness-ui-tasks--main-tree-mode 'once))
        (priority (eq harness-ui-tasks--priority-mode 'once)))
    (when main
      (setq harness-ui-tasks--main-tree-mode nil)
      (harness-ui-tasks--set-new :main-tree :false))
    (when priority
      (setq harness-ui-tasks--priority-mode nil)
      (harness-ui-tasks--set-new :priority "medium"))))

(defun harness-ui-tasks--send (target text expanded atts &optional mode)
  "Send EXPANDED (typed as TEXT) with attachments ATTS for compose TARGET.
A new task goes as MODE says, the compose box's mode when it was
submitted: `submit' (the default) starts it, `refine' and `plan' have it
written up or planned for the backlog (`harness-ui-tasks--new-opts')."
  (let ((buffer (current-buffer)))
    (pcase target
      (`(edit . ,id)
       (harness-ui-tasks--request-then "_harness/task/update" (list :id id :prompt expanded :attachments atts)
                                       "Editing the task")
       (message "Task updated"))
      (`(reply . ,id)
       (let* ((task (harness-ui-tasks--find id))
              (returned (plist-get task :returned)))
         (harness-ui-tasks--request-then "_harness/task/prompt" (list :id id :text expanded :attachments atts)
                                         "Sending the message")
         (message "%s" (cond
                        ((and returned (harness-ui-tasks--queue-suspended-p))
                         "Kept for when the task starts (queue suspended)")
                        ((and returned (equal (format "%s" (plist-get task :return-reason)) "sent-back"))
                         "Kept for when the task starts")
                        ;; Paused, or waiting for quota or a budget: the
                        ;; harness keeps the message for the start too.
                        ((and returned (plist-get task :hold))
                         "Kept for when the task starts")
                        (t "Sent")))))
      (`(refine . ,id)
       (harness-ui-tasks--request-then "_harness/task/prompt" (list :id id :text expanded :attachments atts)
                                       "Sending the feedback")
       (message "Sent"))
      (`(reject . ,id)
       (harness-ui-tasks--request-then "_harness/task/reject" (list :id id :feedback expanded :attachments atts)
                                       "Sending the task back" #'harness-ui-tasks--say-sent-back))
      (_
       (harness-ui-call
        "_harness/task/submit" (list :cwd harness-ui-tasks--dir :prompt expanded
                                     :opts (append (list :attachments atts)
                                                   (harness-ui-tasks--new-opts mode)))
        (lambda (task)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (setq harness-ui-tasks--submitting (delete text harness-ui-tasks--submitting))
              (harness-ui-tasks--reset-once-modes)
              (unless (harness-ui-tasks--find (plist-get task :id))
                (push task harness-ui-tasks--tasks))
              (harness-ui-tasks--render))))
        (lambda (e)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (setq harness-ui-tasks--submitting (delete text harness-ui-tasks--submitting))
              (harness-ui-tasks--render)
              ;; Give the text back unless something new was typed meanwhile.
              (when (and (string-empty-p (string-trim (harness-compose-text))) (null harness-compose-attachments))
                (setq harness-compose-attachments atts)
                (harness-ui-tasks--render-tail text))
              (harness-ui-tasks--fail buffer "Submitting the task" e)))))))))

(defun harness-ui-tasks-start ()
  "Start the pending or backlog task at point now, even when every slot is busy.
A task returned to pending carries on in the session that already
worked on it, where it stopped; a backlog task starts with its
write-up.  \<harness-ui-tasks-board-map>\[harness-ui-tasks-queue] leaves it to the queue instead."
  (interactive)
  (harness-ui-tasks--request-then "_harness/task/start" (list :id (plist-get (harness-ui-tasks--task) :id))
                                  "Starting the task"))

(defun harness-ui-tasks-retry ()
  "Have the task at point, which stopped part way, work on it again.
A task whose turn ended with an error, was cancelled, was interrupted
by a restart, or ran out of output tokens has its session carry on,
with what went wrong as the harness's message (`task/retry'); a merge
that failed is queued again.  \\<harness-ui-tasks-board-map>\\[harness-ui-tasks-start] starts a task that has not started."
  (interactive)
  (harness-ui-tasks--request-then "_harness/task/retry" (list :id (plist-get (harness-ui-tasks--task) :id))
                                  "Retrying the task")
  (message "Retried"))

(defun harness-ui-tasks-queue ()
  "Put the backlog task at point back in the pending queue.
It then starts on its own as soon as its project has a free slot, by
priority, as any queued task does; while the queue is suspended
\(\<harness-ui-tasks-board-map>\[harness-ui-tasks-toggle-queue]) it waits in Pending until the queue is
resumed.  \<harness-ui-tasks-board-map>\[harness-ui-tasks-start] starts it at once instead, whatever the limit."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (unless (and (harness-ui-tasks--backlog-p task) (not (harness-ui-tasks--refining-p task)))
      (user-error "Only a task waiting in the backlog can be queued"))
    (harness-ui-tasks--request-then "_harness/task/queue" (list :id (plist-get task :id))
                                    "Queueing the task")
    (message "%s" (if (harness-ui-tasks--queue-suspended-p)
                      "Queued (queue suspended)"
                    "Queued"))))

(defun harness-ui-tasks--pausable-p (task)
  "Non-nil when TASK can be paused: held in the pending queue until resumed.
That is a task at work, or one stopped part way waiting on you, which
goes back to the queue (`task/pause' on the harness side); or one that
already waits in the queue for a slot and is not paused yet.  A task in
review, merging, refining, in the backlog or done cannot be paused."
  (and (not (harness-ui-tasks--archived-p task))
       (or (equal (plist-get task :state) "active")
           (and (eq (harness-ui-tasks--column task) 'pending)
                (not (harness-ui-tasks--backlog-p task))
                (not (harness-ui-tasks--paused-p task))))))

(defun harness-ui-tasks-pause ()
  "Pause the task at point: back in the pending queue, held there until resumed.
The card calls this Pause.  A task at work has its turn stopped, and the
work its session left running outside its turn -- a supervisor's
workers, sub-agents -- stops too, and is reported to it for when it
carries on.  A task waiting for a slot is paused where it is.  The task
keeps its session, branch and worktree, so when it starts again it
carries on where it stopped, and unlike a task returned to pending it
stays where it is: no free slot starts it.  \\<harness-ui-tasks-board-map>\\[harness-ui-tasks-resume] lets the queue have it again,
\\[harness-ui-tasks-start] starts it at once.  Pausing frees its slot for the
other waiting tasks, and is not suspending the queue
\(\\[harness-ui-tasks-toggle-queue]): the queue goes on with the tasks
that are not paused.  A pause is kept across a restart."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (unless (harness-ui-tasks--pausable-p task)
      (user-error "Only a task at work or waiting for a slot can be paused; this one is %s"
                  (if (harness-ui-tasks--paused-p task) "paused" (harness-ui-tasks--column task))))
    (harness-ui-tasks--request-then "_harness/task/pause" (list :id (plist-get task :id))
                                    "Pausing the task")
    (message "Paused")))

;; What the board's Pause was called when it returned a task to pending.
(defalias 'harness-ui-tasks-return-to-pending #'harness-ui-tasks-pause)

(defun harness-ui-tasks-resume ()
  "Resume the paused task at point: the queue starts it when its turn comes.
It goes by priority within the limit, as any waiting task does, and not
while the queue is suspended (\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-toggle-queue]) or the task waits for quota or a
budget; it carries on where it stopped.  \\[harness-ui-tasks-start] starts it at once instead."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (unless (harness-ui-tasks--paused-p task)
      (user-error "Only a paused task can be resumed; this one is %s" (harness-ui-tasks--column task)))
    (harness-ui-tasks--request-then "_harness/task/resume" (list :id (plist-get task :id))
                                    "Resuming the task")
    (message "Resumed")))

(defun harness-ui-tasks--priority-shown (id priority)
  "Show task ID at PRIORITY at once, the reload behind it confirming.
A priority is the task's session's, and the harness announces the
change as the session's (`session/ext-changed'), which reloads the
board; until that lands, the card would still read the old level and a
second `+' would send it again.  The task's view in the board is
changed here, so the card moves as it used to."
  (when (harness-ui-tasks--find id)
    (setq harness-ui-tasks--tasks
          (mapcar (lambda (other)
                    (if (equal id (plist-get other :id))
                        (plist-put (copy-sequence other) :priority priority)
                      other))
                  harness-ui-tasks--tasks))
    (harness-ui-tasks--render)))

(defun harness-ui-tasks--set-priority (task priority)
  "Give TASK's session PRIORITY, showing it on TASK's card at once.
A task's priority is its session's (`harness-priority-of-task'): the
change goes to that session, where the board's queue and the queues the
task's work waits in read it.  A task with no session -- a record from
before every task had one -- is refused: there is nothing to hold a
priority."
  (let ((id (plist-get task :id))
        (sid (plist-get task :session))
        (buffer (current-buffer)))
    (unless sid
      (user-error "Task %s has no session to hold its priority" id))
    (harness-ui-tasks--request-then "_harness/priority/set"
                                    (list :sessionId sid :priority priority)
                                    "Changing the priority"
                                    (lambda (_result)
                                      (when (buffer-live-p buffer)
                                        (with-current-buffer buffer
                                          (harness-ui-tasks--priority-shown id priority)))))
    (message "%s is %s priority now" (harness-ui-tasks--quote (harness-ui-tasks--title task)) priority)))

(defun harness-ui-tasks--shift-priority (step)
  "Move the priority of the task at point STEP places: 1 up, -1 down.
Priorities are low, medium and high (`harness-ui-priority-levels'),
and a task's priority is its session's (`harness-priority-of-task').
The harness starts waiting tasks by priority first, and Pending shows
them in the order they start, the backlog by priority too, so the card
moves with it."
  (let* ((task (harness-ui-tasks--task))
         (rank (harness-ui-tasks--priority-rank task))
         (priority (nth (+ rank step) harness-ui-priority-levels)))
    (when (eq (harness-ui-tasks--column task) 'done)
      (user-error "A completed task has no priority"))
    (unless (and priority (>= (+ rank step) 0))
      (user-error "It is %s priority already" (harness-ui-tasks--priority task)))
    (harness-ui-tasks--set-priority task priority)))

(defun harness-ui-tasks-raise-priority ()
  "Raise the priority of the task at point: low to medium, medium to high.
While its project's slots are full, a waiting task of higher priority
starts first; among equals, work sent back from review, then a task
returned to pending, then the oldest."
  (interactive)
  (harness-ui-tasks--shift-priority 1))

(defun harness-ui-tasks-lower-priority ()
  "Lower the priority of the task at point: high to medium, medium to low.
While its project's slots are full, waiting tasks of higher priority
start before it."
  (interactive)
  (harness-ui-tasks--shift-priority -1))

(defun harness-ui-tasks-edit ()
  "Edit the prompt of the pending task at point in the compose box.
That is a backlog task's write-up too; one whose write-up stopped can
be written by hand this way."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (unless (harness-ui-tasks--unstarted-p task) (user-error "Only tasks that have not started can be edited"))
    (when (harness-ui-tasks--writing-p task) (user-error "Still being written up; wait, or stop it (k)"))
    (setq harness-compose-attachments (plist-get task :attachments))
    (harness-ui-tasks--set-compose (plist-get task :prompt) (cons 'edit (plist-get task :id)))))

(defun harness-ui-tasks-reply ()
  "Write a message to the session of the task at point.
For a backlog task, or one whose write-up stopped or refused it as a
duplicate, that is feedback on its write-up, which is written again (see
`harness-ui-tasks-refine').  For a task waiting for your review it is
the feedback that sends it back, as any message you send its session is
\(see `harness-ui-tasks-reject').  For a task returned to pending the
message starts it again, as an explicit start would -- or is kept for
its next start while the queue is suspended."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (unless (plist-get task :session) (user-error "This task has not started yet"))
    (harness-ui-tasks--set-compose
     "" (cons (cond ((equal (plist-get (harness-ui-tasks--pending task) :kind) "question") 'answer)
                    ((equal (plist-get task :state) "review") 'reject)
                    ((plist-get task :returned) 'reply)
                    ((or (equal (plist-get task :state) "pending")
                         (and (harness-ui-tasks--refining-p task) (not (harness-ui-tasks--writing-p task))))
                     'refine)
                    (t 'reply))
              (plist-get task :id)))))

(defun harness-ui-tasks-refine ()
  "Have an agent write the task at point up for the backlog.
A queued task is written up and then waits for you to start it.  For a
backlog task the compose box takes your feedback, and the write-up is
done again with it.  A write-up that stopped is retried, and a task
whose write-up refused it as a duplicate is written up all the same."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (cond
     ((not (harness-ui-tasks--unstarted-p task))
      (user-error "Only tasks that have not started can be refined"))
     ((harness-ui-tasks--writing-p task) (user-error "Already being written up"))
     ((and (equal (plist-get task :state) "pending") (plist-get task :session))
      (harness-ui-tasks--set-compose "" (cons 'refine (plist-get task :id))))
     (t (harness-ui-tasks--request-then "_harness/task/refine" (list :id (plist-get task :id))
                                        "Refining the task")
        (message "Writing it up…")))))

(defun harness-ui-tasks-requests ()
  "Pop out what the task at point needs, to read and act on it.
That is the permission prompt or question its session waits on, shown in
full -- buttons, keys and diagrams -- and answered there; the board's
compose box takes a typed answer too (m).  A task that handed work in
shows its report instead, through the shared
`harness-ui-popout-at-point-functions'.  The card offers the request as
[Answer…] / [Request…]; SPC does this."
  (interactive)
  (let* ((task (harness-ui-tasks--task))
         (sid (plist-get task :session)))
    (unless sid (user-error "This task has not started yet"))
    (unless (fboundp 'harness-ui-popout-at-point)
      (user-error "The popout module is not loaded"))
    ;; The request is the pending module's and a report the review module's;
    ;; both register with the shared hook, which knows the task at point.
    (unless (harness-ui-popout-try-at-point)
      (user-error "This task is not waiting on anything"))))

(defun harness-ui-tasks--answer (task answer &optional attachments)
  "Answer the question TASK's session is waiting on with ANSWER.
As every view answers it (`harness-ui-pending-answer-first-question'),
but a failure shows on the board.  ATTACHMENTS, the files attached to
the answer, go with it to the model."
  (unless (plist-get task :session) (user-error "No question is waiting"))
  (setq harness-ui-tasks--error nil)
  (harness-ui-pending-answer-first-question (plist-get task :session) answer
                                            (harness-ui-tasks--on-error "Answering")
                                            attachments))

(defun harness-ui-tasks--permission (option)
  "Answer the permission request of the task at point with OPTION.
As every view answers it (`harness-ui-pending-answer-first-permission'),
but a failure shows on the board."
  (let ((task (harness-ui-tasks--task)))
    (unless (plist-get task :session) (user-error "No permission request is waiting"))
    (setq harness-ui-tasks--error nil)
    (harness-ui-pending-answer-first-permission (plist-get task :session) option
                                                (harness-ui-tasks--on-error "Answering the permission request"))))

(defun harness-ui-tasks-allow ()
  "Answer the permission request the task at point waits on with Allow.
That is the [Allow] of the request's panel and of the session list, and
their y; its tooltip says what it covers (`harness-ui-pending-answer-help')."
  (interactive)
  (harness-ui-tasks--permission "allow-once"))

(defun harness-ui-tasks-deny ()
  "Answer the permission request the task at point waits on with Deny.
That is the [Deny] of the request's panel and of the session list, and
their n."
  (interactive)
  (harness-ui-tasks--permission "deny-once"))

(defun harness-ui-tasks-cancel ()
  "Stop the task at point, or drop it when it is still pending.
An agent writing a task up stops; once stopped, the task is dropped,
and with a backlog task the session that wrote it up."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (when (or (not (or (equal (plist-get task :state) "pending")
                       (and (harness-ui-tasks--refining-p task) (not (harness-ui-tasks--writing-p task)))))
              (y-or-n-p (format "Drop pending task “%s”? " (harness-ui-tasks--title task))))
      (harness-ui-tasks--request-then "_harness/task/cancel" (list :id (plist-get task :id)) "Stopping the task"))))

(defun harness-ui-tasks-merge ()
  "Send the branch of the task at point through the merge queue again."
  (interactive)
  (harness-ui-tasks--request-then "_harness/task/merge" (list :id (plist-get (harness-ui-tasks--task) :id))
                                  "Queueing the merge"))

(defun harness-ui-tasks-complete ()
  "Mark the task at point completed."
  (interactive)
  (harness-ui-tasks--request-then "_harness/task/complete" (list :id (plist-get (harness-ui-tasks--task) :id))
                                  "Completing the task"))

(defun harness-ui-tasks--review-task ()
  "Return the task at point, which has to wait for your review."
  (let ((task (harness-ui-tasks--task)))
    (unless (equal (plist-get task :state) "review")
      (user-error "This task is not waiting for your review"))
    task))

(defun harness-ui-tasks-verify ()
  "Accept the work of the task at point, which waits for your review.
In a git project its branch then goes through the merge queue, and the
task is completed once merged; otherwise it is completed at once."
  (interactive)
  (let ((task (harness-ui-tasks--review-task)))
    (harness-ui-tasks--request-then "_harness/task/verify" (list :id (plist-get task :id))
                                    "Verifying the task")
    (message (if (and (plist-get task :worktree) (not (harness-json-true-p (plist-get task :merged))))
                 "Verified: merging it"
               "Verified"))))

(defun harness-ui-tasks-reject (&optional feedback)
  "Send the task at point back from review with feedback.
The compose box takes the feedback, which \\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-submit] sends to the task's
session: it works on the task again, in its own worktree, and the task
comes back for your review once that is done.  Sending it back keeps
to the limit of tasks at once: with no slot free it takes the slot of
a task at work it outranks, which goes back to the queue, or waits in
the queue with your feedback when every task at work goes first.  With
a prefix argument the feedback is read in the minibuffer instead; from
Lisp, FEEDBACK is sent at once."
  (interactive (list (and current-prefix-arg
                          (progn (harness-ui-tasks--review-task) (read-string "Feedback: ")))))
  (let ((task (harness-ui-tasks--review-task)))
    (cond
     ((null feedback) (harness-ui-tasks--set-compose "" (cons 'reject (plist-get task :id))))
     ((harness-string-blank-p feedback) (user-error "Sending a task back needs feedback"))
     (t (harness-ui-tasks--request-then "_harness/task/reject" (list :id (plist-get task :id) :feedback feedback)
                                        "Sending the task back" #'harness-ui-tasks--say-sent-back)))))

(defun harness-ui-tasks--count-tasks (n)
  "N tasks in words: \"task\" for one, \"3 tasks\" for more."
  (if (= n 1) "task" (format "%d tasks" n)))

(defun harness-ui-tasks--show-review (on)
  "Show review as ON (non-nil) or off on this board, as the harness has it now.
Its `config/changed' brings every board the settings again shortly;
this one does not wait for them."
  (when harness-ui-tasks--settings
    (setq harness-ui-tasks--settings
          (plist-put (copy-sequence harness-ui-tasks--settings) :require-verification (if on t :false)))
    (harness-ui-tasks--render)
    (harness-ui-tasks--refit-tail)))

(defun harness-ui-tasks--show-queue (suspended)
  "Show SUSPENDED (non-nil) or running on this board, as the harness has it now.
Its `task/queue' event brings every board the settings again shortly;
this one does not wait for them."
  (when harness-ui-tasks--settings
    (setq harness-ui-tasks--settings
          (plist-put (copy-sequence harness-ui-tasks--settings) :queue-suspended (if suspended t :false)))
    (harness-ui-tasks--render)
    (harness-ui-tasks--refit-tail)))

(defun harness-ui-tasks-toggle-queue (&optional arg)
  "Suspend the pending queue of the board's project, or resume it.
While the queue is suspended, no waiting task of the project starts on
its own: the board is clear for one urgent task, which [Start now]
\(\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-start]) still starts, as task_control start
does.  A task at work goes on; pausing one
\(\\[harness-ui-tasks-pause]) frees its slot, and no waiting task takes it
while the queue is suspended.  Resuming lets the waiting tasks start
again at once, by priority, the tasks returned to pending first.

The suspension is per project, like the concurrency limit, and kept
across restarts.  The Pending heading shows it as [Queue: running] or
\[Queue: suspended], which a click switches too.  With a prefix ARG,
suspend when ARG is positive and resume otherwise."
  (interactive "P")
  (let* ((buffer (current-buffer))
         (suspend (if arg (> (prefix-numeric-value arg) 0)
                    (not (harness-ui-tasks--queue-suspended-p))))
         (what (if suspend "Suspending the queue" "Resuming the queue")))
    (harness-ui-tasks--show-queue suspend)
    (harness-ui-tasks--request-then
     "_harness/task/toggle-queue" (list :cwd harness-ui-tasks--dir) what
     (lambda (state)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (harness-ui-tasks--show-queue (harness-json-true-p (plist-get state :suspended)))))))
    (message "%s" (if suspend
                       "Queue suspended"
                     "Queue resumed"))))

(defun harness-ui-tasks--show-backlog-mode (mode)
  "Show MODE, \"auto\" or \"manual\", as the board's backlog mode now.
Its `task/backlog-mode' event brings every board the settings again
shortly; this one does not wait for them."
  (when harness-ui-tasks--settings
    (setq harness-ui-tasks--settings
          (plist-put (copy-sequence harness-ui-tasks--settings) :backlog-mode (format "%s" mode)))
    (harness-ui-tasks--render)
    (harness-ui-tasks--refit-tail)))

(defun harness-ui-tasks-toggle-backlog-mode (&optional arg)
  "Switch the board's backlog between a manual and an auto queue.
With a manual queue, the default, a task written up for the backlog
waits there until you queue it (\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-queue], [Queue it]) or start it
\(\\[harness-ui-tasks-start]).  With an auto queue it joins the queue by itself as soon as
its write-up is done, a write-up done again after your feedback too,
and the queue starts it like any waiting task: by priority, as slots
free, and not while the queue is suspended (\\[harness-ui-tasks-toggle-queue]).  A write-up
that stops or refuses the task as a duplicate still waits for you, and
switching queues none of the tasks already in the Backlog.

The mode is the project's, kept across restarts, and the Backlog's
heading shows it as [Manual queue] or [Auto queue], which a click
switches too.  With a prefix ARG, switch to the auto queue when ARG is
positive and to the manual one otherwise."
  (interactive "P")
  (let* ((buffer (current-buffer))
         (auto (if arg (> (prefix-numeric-value arg) 0) (not (harness-ui-tasks--auto-queue-p))))
         (mode (if auto "auto" "manual")))
    (harness-ui-tasks--show-backlog-mode mode)
    (harness-ui-tasks--request-then
     "_harness/task/set-backlog-mode" (list :mode mode :cwd harness-ui-tasks--dir)
     (if auto "Switching to auto queue" "Switching to manual queue")
     (lambda (state)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (harness-ui-tasks--show-backlog-mode (plist-get state :mode))))))
    (message "%s" (if auto
                      "Auto queue"
                    "Manual queue"))))

(defun harness-ui-tasks-toggle-review (&optional arg)
  "Turn the review of finished tasks off, or back on.
With review on, a task whose work is finished waits in Ready for review
until you verify it (\\<harness-ui-tasks-board-map>\\[harness-ui-tasks-verify]), which merges it, or send it back
\(\\[harness-ui-tasks-reject]).  With review off it needs nobody: its branch merges as soon
as it is finished, and the task is done.  The board then shows no Ready
for review column, unless tasks still wait there.  Turning review off
while tasks of this board wait for it offers to verify them too.

It sets the harness option `harness-tasks-require-verification', which
the settings page has under Task board, and saves it as that page does:
for every project, and across restarts.  With a prefix ARG, turn review
on when ARG is positive and off otherwise."
  (interactive "P")
  (let* ((buffer (current-buffer))
         (on (if arg (> (prefix-numeric-value arg) 0) (not (harness-ui-tasks--review-p))))
         (waiting (and (not on)
                       (cl-remove-if-not (lambda (task) (and (equal (plist-get task :state) "review")
                                                             (not (harness-ui-tasks--archived-p task))))
                                         harness-ui-tasks--tasks)))
         (verify (and waiting
                      (y-or-n-p (format "Verify the %s waiting for your review too? "
                                        (harness-ui-tasks--count-tasks (length waiting)))))))
    (harness-ui-tasks--request-then
     "_harness/config/set"
     (list :key "harness-tasks-require-verification" :value (if on "t" "nil") :printed t
           :scope "global" :cwd harness-ui-tasks--dir)
     (if on "Turning review on" "Turning review off")
     (lambda (_)
       (when (harness-ui-tasks--board-p buffer)
         (with-current-buffer buffer
           (harness-ui-tasks--show-review on)
           (when verify
             (dolist (task waiting)
               (harness-ui-tasks--request-then "_harness/task/verify" (list :id (plist-get task :id))
                                               "Verifying the task")))))
       (message "%s"
                (cond (on "Review on")
                      (verify (format "Review off; verifying the %s that waited"
                                      (harness-ui-tasks--count-tasks (length waiting))))
                      (t "Review off")))))))

(defun harness-ui-tasks-archive ()
  "Archive the task at point, completed or in review, or restore it when archived."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (harness-ui-tasks--request-then "_harness/task/archive"
                                    (list :id (plist-get task :id) :restore (harness-ui-tasks--archived-p task))
                                    "Archiving the task")))

(defun harness-ui-tasks-archive-done ()
  "Archive every completed task of this project."
  (interactive)
  (harness-ui-tasks--request-then "_harness/task/archive-done" (list :cwd harness-ui-tasks--dir)
                                  "Archiving completed tasks"
                                  (lambda (n) (message "Archived %s task%s" n (if (eql n 1) "" "s")))))

(defun harness-ui-tasks-delete ()
  "Delete the task at point, and its session when confirmed."
  (interactive)
  (let ((task (harness-ui-tasks--task)))
    (when (y-or-n-p (format "Delete task “%s”? " (harness-ui-tasks--title task)))
      (harness-ui-tasks--request-then
       "_harness/task/delete"
       (list :id (plist-get task :id)
             :delete-session (and (plist-get task :session) (y-or-n-p "Delete its session too? ")))
       "Deleting the task"))))

(defun harness-ui-tasks-adopt ()
  "Make an ongoing session of this project a task, chosen with completion."
  (interactive)
  (let ((buffer (current-buffer)))
    (harness-ui-call
     "_harness/task/adoptable" (list :cwd harness-ui-tasks--dir)
     (lambda (sessions)
       (if (null sessions)
           (message "Every ongoing session of this project is already a task")
         (dolist (s sessions) (harness-ui-cache-session s))
         (let* ((ids (mapcar (lambda (s) (plist-get s :id)) sessions))
                (session (harness-ui-read-session "Make a task of: "
                                                  (lambda (s) (member (plist-get s :id) ids)))))
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (harness-ui-tasks--request-then "_harness/task/adopt" (list :session-id (plist-get session :id))
                                               "Adding the session"))))))
     (lambda (e) (harness-ui-tasks--fail buffer "Listing sessions" e)))))

(defun harness-ui-tasks-btw ()
  "Ask about the tasks in a BTW side conversation over the board.
It opens blank, for a question written in its compose box.  Its agent
answers with the task and session tools: what a task is doing, how far
along it is, what it changed, why it is stuck.  Like any BTW it runs on
a cheap model (`harness-btw-model'); with a prefix argument it asks
which model to run this one on."
  (interactive)
  (unless (fboundp 'harness-btw) (user-error "The BTW module is not loaded"))
  (harness-btw nil nil (and current-prefix-arg 'choose)))

(defun harness-ui-tasks-slots ()
  "Show who holds the board's project's task slots, and who waits for one.
The task slots page (`harness-slots') lists the tasks at work as the
session list lists sessions, then the queue by priority and how long
tasks waited for a slot."
  (interactive)
  (unless (fboundp 'harness-slots)
    (user-error "The task slots module (ui-slots) is not loaded"))
  (harness-slots harness-ui-tasks--dir))

(declare-function harness-tasks-search "harness-ui-tasks-search")

(defun harness-ui-tasks-search ()
  "Find tasks, sessions and commands from the board, or act on tasks, in words.
The compose box turns into a search box, what it held kept aside: a
line typed there -- a question (\"did I have a task about the question
button?\"), an order (\"restart the errored tasks\"), or a session or
command to find -- goes with the board to a quick, cheap model, and the
board then shows the tasks it is about, the sessions and commands it
found, and what was done.  \\<harness-ui-tasks-mode-map>\\[harness-ui-tasks-compose-quit] closes the search box.  See
`harness-tasks-search'."
  (interactive)
  (unless (fboundp 'harness-tasks-search)
    (user-error "The task search module (ui-tasks-search) is not loaded"))
  (call-interactively #'harness-tasks-search))

(defun harness-ui-tasks--start-btw (name &optional model)
  "Start a conversation NAME about the board's tasks; return a promise of it.
Every call starts a new session (`task/btw'), never an earlier one.
MODEL, a PROVIDER:NAME, is the model to run it on; without one it runs
on `harness-btw-model', and no model goes over the wire.  The BTW
module calls this (`harness-ui-btw-start-function') to open a BTW over
the board; a failure shows on the board too."
  (setq harness-ui-tasks--error nil)
  (let ((buffer (current-buffer))
        (promise (harness-ui-request "_harness/task/btw"
                                     (append (list :cwd harness-ui-tasks--dir :name name)
                                             (and model (list :model model))))))
    (harness-then promise #'ignore (lambda (e) (harness-ui-tasks--fail buffer "Starting a BTW" e)))
    promise))

(defun harness-ui-tasks-toggle-archived ()
  "Show or hide archived tasks."
  (interactive)
  (setq harness-ui-tasks--show-archived (not harness-ui-tasks--show-archived))
  (harness-ui-tasks--render))

(defun harness-ui-tasks-refresh ()
  "Reload the board from the harness."
  (interactive)
  (setq harness-ui-tasks--error nil)
  (harness-ui-tasks--render-tail)
  (harness-ui-tasks--fetch (current-buffer))
  (harness-ui-refresh-sessions))

;;;; The backlog in a session
;;
;; A backlog task's session is where the task was written up, and the
;; chat there is where the user looks at it.  Nothing said which task it
;; was or how to start it: the board was the only place with [Start
;; now].  So a session whose task waits in the backlog, or is being
;; written up, gets a banner above its compose box saying so, with the
;; same [Start now] and [Queue it] as the card.  The box says what a
;; message does there: it starts the task (harness-tasks.el), whether
;; the write-up waits in the backlog or still runs, in which case the
;; message stops it first; feedback on the write-up is the board's
;; [Refine].

(defvar harness-ui-tasks--session-tasks (make-hash-table :test 'equal)
  "Session id -> the task record of that session, as last heard.")

(defvar harness-ui-tasks--session-tasks-asked (make-hash-table :test 'equal)
  "Session ids whose task was looked up once.")

(defconst harness-ui-tasks--backlog-hints
  '("Message…  sending stops the write-up and starts the task"
    "Message…  sending starts the task")
  "What this session's compose box asks for while its task is in the backlog.
The first while a write-up runs, which the message stops and starts the
task; the second while the task waits, when the message starts it.")

(defun harness-ui-tasks--chat-buffer (sid)
  "Return the live chat buffer showing session SID, or nil.
Another view of the session, such as its access view, is no chat
\(`harness-ui-chat-of-p')."
  (cl-find-if (lambda (buffer) (harness-ui-chat-of-p buffer sid)) (buffer-list)))

(defun harness-ui-tasks--redraw-session (sid)
  "Draw the tail of SID's chat buffer again, when it shows."
  (when-let* ((buffer (harness-ui-tasks--chat-buffer sid)))
    (with-current-buffer buffer
      (when (functionp harness-compose-redraw-function)
        (funcall harness-compose-redraw-function)))))

(defun harness-ui-tasks--fetch-session-task (sid)
  "Look up SID's task and redraw the banner of its chat.
A session that is no task's is remembered as such, so the lookup
happens once per session."
  (harness-ui-call
   "_harness/task/for-session" (list :session-id sid)
   (lambda (task)
     (if (and task (plist-get task :id))
         (puthash sid task harness-ui-tasks--session-tasks)
       (remhash sid harness-ui-tasks--session-tasks))
     (harness-ui-tasks--redraw-session sid))
   #'ignore))

(defun harness-ui-tasks--session-task (sid)
  "Return SID's task record when it is a task's, else nil."
  (when (and (stringp sid) (not (string-empty-p sid)))
    (unless (gethash sid harness-ui-tasks--session-tasks-asked)
      (puthash sid t harness-ui-tasks--session-tasks-asked)
      (harness-ui-tasks--fetch-session-task sid))
    (gethash sid harness-ui-tasks--session-tasks)))

(defun harness-ui-tasks--on-session-task-event (event args)
  "Keep the session task records in step with EVENT and its ARGS.
The banner of an open session follows its task, and a session that
becomes a task's, or stops being one, is looked up again."
  (pcase event
    ((or "task/changed" "task/review" "task/done")
     (let ((task (car args)))
       (when-let* ((sid (plist-get task :session)))
         (if (and task (plist-get task :id))
             (puthash sid task harness-ui-tasks--session-tasks)
           (remhash sid harness-ui-tasks--session-tasks))
         (harness-ui-tasks--redraw-session sid))))
    ("task/deleted"
     (let ((id (car args)))
       (maphash (lambda (sid task)
                  (when (equal id (plist-get task :id))
                    (remhash sid harness-ui-tasks--session-tasks)
                    (harness-ui-tasks--redraw-session sid)))
                (copy-hash-table harness-ui-tasks--session-tasks))))))

(defun harness-ui-tasks--backlog-session-p (task)
  "Non-nil when TASK is a session's task that has not started.
That is one waiting in the backlog, or being written up for it."
  (and task
       (not (harness-ui-tasks--archived-p task))
       (or (and (equal (plist-get task :state) "pending")
                (harness-ui-tasks--backlog-p task))
           (harness-ui-tasks--refining-p task))))

(defun harness-ui-tasks--with-face (string face)
  "Return STRING on FACE, under the faces it has already."
  (if (fboundp 'harness-chat--face)
      (harness-chat--face string face)
    (let ((s (copy-sequence string)))
      (add-face-text-property 0 (length s) face t s)
      s)))

(defun harness-ui-tasks--chat-button (label action help)
  "Return a button string LABEL running ACTION, with HELP."
  (propertize (buttonize label (lambda (_) (funcall action)) nil help)
              "mouse-face" 'highlight))

(defun harness-ui-tasks--backlog-banner (task)
  "Return the banner of TASK, a session's backlog task.
It says whether the task waits for the user or is being written up,
and offers the card's [Start now] and, while it waits, [Queue it]."
  (let* ((writing (harness-ui-tasks--writing-p task))
         (stopped (and (harness-ui-tasks--refining-p task) (not writing)))
         (title (harness-ui-tasks--title task))
         (start (harness-ui-tasks--chat-button
                 "[Start now]" #'harness-ui-tasks-session-start
                 "Start the task now with its write-up, even while it is being written up"))
         (queue (when (and (not writing)
                           (equal (plist-get task :state) "pending")
                           (harness-ui-tasks--backlog-p task))
                  (concat " "
                          (harness-ui-tasks--chat-button
                           "[Queue it]" #'harness-ui-tasks-session-queue
                           "Put it in the pending queue, to start when a slot frees"))))
         (line (cond
                (writing "An agent is writing it up: a message stops it and starts the task.")
                (stopped (format "Its write-up stopped (%s): start it with what it has."
                                 (or (plist-get task :outcome) "stopped")))
                (t "Waiting for you to start it: a message starts the task."))))
    (concat
     " " (propertize (concat (harness-ui-icon 'harness-icon-task-backlog)
                             " Waiting in the Backlog")
                     'face 'harness-task-attention-face)
     "\n"
     "   " (propertize title 'face 'bold 'wrap-prefix "   ") "\n"
     "   " (propertize line 'face 'harness-hint-face 'wrap-prefix "   ") "\n"
     "   " start queue "\n"
     "   " (propertize (if writing
                         "C-c C-c stops it and starts the task; Refine on the board sends feedback"
                       "C-c C-c sends a message, which starts the task")
                     'face 'harness-hint-face)
     "\n ")))

(defun harness-ui-tasks--backlog-placeholder (task shown)
  "Say in the compose box what a message does for TASK, shown when SHOWN.
The message starts the task, and stops a write-up still running, which
is what the box says.  A box another module gave a hint is left alone."
  (cond
   ((not shown)
    (when (member harness-chat-placeholder harness-ui-tasks--backlog-hints)
      (kill-local-variable 'harness-chat-placeholder)))
   ((and (stringp harness-chat-placeholder)
         (not (member harness-chat-placeholder harness-ui-tasks--backlog-hints)))
    nil)
   ((harness-ui-tasks--writing-p task)
    (setq-local harness-chat-placeholder (nth 0 harness-ui-tasks--backlog-hints)))
   (t (setq-local harness-chat-placeholder (nth 1 harness-ui-tasks--backlog-hints)))))

(defun harness-ui-tasks--backlog-panel ()
  "Return the banner when this session's task waits in the backlog.
On `harness-chat-panel-functions': nil for a session that is no task's,
or whose task has started, and until the task is known."
  (when (bound-and-true-p harness-ui-session-id)
    (let* ((sid harness-ui-session-id)
           (task (harness-ui-tasks--session-task sid))
           (shown (harness-ui-tasks--backlog-session-p task)))
      (harness-ui-tasks--backlog-placeholder task shown)
      (when shown
        (harness-ui-tasks--with-face (harness-ui-tasks--backlog-banner task)
                                     'harness-chat-backlog-face)))))

(defun harness-ui-tasks--session-backlog-task ()
  "Return this session's task, which has to wait in the backlog."
  (let ((task (harness-ui-tasks--session-task harness-ui-session-id)))
    (unless (harness-ui-tasks--backlog-session-p task)
      (user-error "This session's task is not waiting in the backlog"))
    task))

(defun harness-ui-tasks-session-start ()
  "Start the backlog task of this session now, even with every slot busy.
The task starts with its write-up; a write-up still running is stopped
first, and the task starts once it has ended.  This is the [Start now]
of the banner above the session's compose box, as the card's."
  (interactive)
  (let* ((task (harness-ui-tasks--session-backlog-task))
         (id (plist-get task :id))
         (sid (or (plist-get task :session) harness-ui-session-id)))
    (harness-ui-call
     "_harness/task/start" (list :id id)
     (lambda (view)
       (when (and view (plist-get view :id))
         (puthash sid view harness-ui-tasks--session-tasks))
       (harness-ui-tasks--redraw-session sid)
       (message "Starting the task"))
     (lambda (e) (message "Could not start the task: %s" (harness-error-message e))))))

(defun harness-ui-tasks-session-queue ()
  "Put this session's backlog task in the pending queue.
It starts on its own as soon as its project has a free slot; the
banner's [Start now] starts it at once instead."
  (interactive)
  (let* ((task (harness-ui-tasks--session-backlog-task))
         (id (plist-get task :id))
         (sid (or (plist-get task :session) harness-ui-session-id)))
    (unless (and (equal (plist-get task :state) "pending")
                 (harness-ui-tasks--backlog-p task))
      (user-error "Only a task waiting in the backlog can be queued; start this one now instead"))
    (harness-ui-call
     "_harness/task/queue" (list :id id)
     (lambda (view)
       (when (and view (plist-get view :id))
         (puthash sid view harness-ui-tasks--session-tasks))
       (harness-ui-tasks--redraw-session sid)
       (message "Queued"))
     (lambda (e) (message "Could not queue the task: %s" (harness-error-message e))))))

;;;; Ready for review, in the mode line

;; The mode line notifier (harness-ui-notify.el) counts the tasks ready
;; for your review, of every project, as it counts the sessions that
;; wait for you: the flag of the board's Ready for review and the count,
;; in its colour (`harness-notify-review-face'), after the notifier's
;; "harness" (`harness-ui-notify-segment-functions'), so it shows while
;; no session works too -- a task in review has an idle session.  The UI
;; asks for every project's tasks once it connects (`_harness/task/list'
;; without a directory), and `task/changed' and `task/deleted' keep the
;; count from then on, so it needs no board open.  Hovering says how
;; many each project has, and a click opens the board on them
;; (`harness-tasks-review').

(defvar harness-notify-mode)
(declare-function harness-ui-notify-refresh "harness-ui-notify")

(defface harness-notify-review-face '((t :inherit harness-task-review-face))
  "The count of tasks ready for your review, in the mode line notifier."
  :group 'harness-ui-tasks)

(defvar harness-ui-tasks--in-review (make-hash-table :test 'equal)
  "Task id -> view of every task ready for your review, of every project.
That is a task in Ready for review, but for an archived one, which no
board shows.  The mode line notifier counts them
\(`harness-ui-tasks--notify-segment').")

(defun harness-ui-tasks--awaits-review-p (task)
  "Non-nil when TASK, a view, waits in Ready for review and is not archived."
  (and (eq (harness-ui-tasks--column task) 'review)
       (not (harness-ui-tasks--archived-p task))))

(defun harness-ui-tasks--note-review (task)
  "Count TASK, a view, among the tasks in review while it waits there.
A task that does not wait there is not counted.  Return non-nil when
that changed the count."
  (when-let* ((id (plist-get task :id)))
    (let ((was (and (gethash id harness-ui-tasks--in-review) t)))
      (if (harness-ui-tasks--awaits-review-p task)
          (puthash id task harness-ui-tasks--in-review)
        (remhash id harness-ui-tasks--in-review))
      (not (eq was (and (gethash id harness-ui-tasks--in-review) t))))))

(defun harness-ui-tasks--review-changed ()
  "Draw the mode line notifier again, for another count of tasks in review."
  (when (and (bound-and-true-p harness-notify-mode) (fboundp 'harness-ui-notify-refresh))
    (harness-ui-notify-refresh)))

(defun harness-ui-tasks--fetch-review ()
  "Ask the harness for every project's tasks, and count those in review.
A harness without tasks fails the request, and has none to count."
  (cl-flet ((count (tasks)
              (clrhash harness-ui-tasks--in-review)
              (dolist (task tasks) (harness-ui-tasks--note-review task))
              (harness-ui-tasks--review-changed)))
    (harness-ui-call "_harness/task/list" nil
                     (lambda (tasks) (count (and (listp tasks) tasks)))
                     (lambda (_) (count nil)))))

(defun harness-ui-tasks--on-review-event (event args)
  "Keep the count of tasks in review: `task/changed' (TASK), `task/deleted' (ID).
EVENT names a harness event and ARGS are its arguments, as
`harness-ui-event-functions' hands them.  The notifier is drawn again
only when the count changed."
  (when (pcase event
          ("task/changed" (harness-ui-tasks--note-review (car args)))
          ("task/deleted" (let ((id (car args)))
                            (when (and id (gethash id harness-ui-tasks--in-review))
                              (remhash id harness-ui-tasks--in-review)
                              t))))
    (harness-ui-tasks--review-changed)))

(defun harness-ui-tasks--review-projects ()
  "Return the projects with tasks ready for your review, each (ROOT TASK...).
ROOT is a project's root as the harness files its tasks under, and its
tasks go in the order its board lists them, the last to come to review
first; so do the projects, by the last of their tasks."
  (let ((projects nil))
    (maphash (lambda (_ task)
               (let* ((root (plist-get task :project))
                      (entry (assoc root projects)))
                 (if entry
                     (push task (cdr entry))
                   (push (list root task) projects))))
             harness-ui-tasks--in-review)
    (dolist (entry projects)
      (setcdr entry (sort (cdr entry) #'harness-ui-tasks--finished-later-p)))
    (sort projects (lambda (a b) (harness-ui-tasks--finished-later-p (cadr a) (cadr b))))))

(defun harness-ui-tasks--project-name (root)
  "Return a short name of project ROOT: its directory's."
  (if (and (stringp root) (not (string-empty-p root)))
      (let ((name (file-name-nondirectory (directory-file-name root))))
        (if (string-empty-p name) (abbreviate-file-name root) name))
    "no project"))

(defun harness-ui-tasks--review-help (projects)
  "Return the tooltip of the notifier's count of tasks in review.
PROJECTS is what `harness-ui-tasks--review-projects' returns."
  (let ((n (apply #'+ (mapcar (lambda (entry) (length (cdr entry))) projects))))
    (format "Tasks ready for your review: %s (mouse-1: open the task board on %s)"
            (mapconcat (lambda (entry)
                         (format "%d in %s" (length (cdr entry))
                                 (harness-ui-tasks--project-name (car entry))))
                       projects ", ")
            (if (= n 1) "it" "them"))))

(defun harness-ui-tasks--notify-segment ()
  "Return the mode line notifier's count of tasks ready for your review, or nil.
The board's flag and the count; hovering says how many each project
has, and a click runs `harness-tasks-review'.  On
`harness-ui-notify-segment-functions'."
  (let ((n (hash-table-count harness-ui-tasks--in-review)))
    (when (> n 0)
      (propertize (format " %s%d" (harness-ui-icon 'harness-icon-task-review) n)
                  'face 'harness-notify-review-face
                  'help-echo (harness-ui-tasks--review-help (harness-ui-tasks--review-projects))
                  'mouse-face 'mode-line-highlight
                  'local-map (harness-ui-mouse-keymap #'harness-tasks-review)))))

(defun harness-ui-tasks--same-root-p (a b)
  "Non-nil when A and B name the same directory."
  (and (stringp a) (stringp b)
       (equal (file-name-as-directory (expand-file-name a))
              (file-name-as-directory (expand-file-name b)))))

(defun harness-ui-tasks--current-project ()
  "Return the main checkout of the current buffer's project, or nil.
On a board that is the project the board shows; elsewhere the project
of the buffer's directory, a task's worktree belonging to its main
checkout.  A remote directory is not looked at, and gives nil."
  (if (harness-ui-tasks--board-p (current-buffer))
      (or harness-ui-tasks--project harness-ui-tasks--dir)
    (and (stringp default-directory)
         (not (file-remote-p default-directory))
         (ignore-errors (harness-files-main-root default-directory)))))

;;;###autoload
(defun harness-tasks-review ()
  "Show the tasks ready for your review on their project's task board.
The board is the current project's when that project has tasks waiting
for review, else the board of the project whose task came to review
last; point goes to the card of its task that came to review last, at
the top of Ready for review.  The board's project becomes current
first, as a click on a task's notification makes it
\(`harness-ui-tasks-visit-task').  A click on the count of tasks in
review, in the mode line notifier, runs this."
  (interactive)
  (let ((projects (harness-ui-tasks--review-projects)))
    (unless projects
      (user-error "No task is ready for your review"))
    (let* ((here (harness-ui-tasks--current-project))
           (entry (or (and here (cl-find-if (lambda (entry) (harness-ui-tasks--same-root-p (car entry) here))
                                            projects))
                      (car projects)))
           (task (cadr entry)))
      (harness-ui-tasks-visit-task (plist-get task :id) (car entry) (plist-get task :session)))))

;;;; Module

(defun harness-ui-tasks--init ()
  "Keep the boards up to date and bind `harness-tasks' in `harness-ui-map'.
They follow the harness's events, sessions and quotas, and a timer
redraws the visible ones so their elapsed times run; the figures that
change with every model call -- tokens, output rates, costs -- redraw
none (`harness-ui-tasks--board-key').  The mode line notifier counts
the tasks ready for review, every project's, which the UI asks for as
it connects and, started while connected, at once
\(`harness-ui-tasks--fetch-review'); the count comes after the
notifier's other segments, such as the version page's nag."
  (add-hook 'harness-ui-event-functions #'harness-ui-tasks--on-event)
  (add-hook 'harness-ui-event-functions #'harness-ui-tasks--on-session-task-event)
  (add-hook 'harness-ui-event-functions #'harness-ui-tasks--on-review-event)
  (add-hook 'harness-chat-panel-functions #'harness-ui-tasks--backlog-panel)
  (add-hook 'harness-ui-sessions-changed-hook #'harness-ui-tasks--on-sessions-changed)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-tasks--on-redraw)
  (add-hook 'harness-ui-quota-functions #'harness-ui-tasks--on-quota)
  (add-hook 'harness-ui-connected-hook #'harness-ui-tasks--fetch-review)
  (add-hook 'harness-ui-notify-segment-functions #'harness-ui-tasks--notify-segment 50)
  (when (timerp harness-ui-tasks--timer) (cancel-timer harness-ui-tasks--timer))
  (setq harness-ui-tasks--timer (run-with-timer harness-ui-tasks--tick-interval harness-ui-tasks--tick-interval #'harness-ui-tasks--tick))
  (define-key harness-ui-map (kbd "a") #'harness-tasks)
  ;; The boards that exist already, when the harness reloads, were started
  ;; by a mode function that did not know to catch up when shown.
  (dolist (board (harness-ui-tasks--buffers))
    (with-current-buffer board
      (harness-ui-view-install #'harness-ui-tasks--catch-up)))
  (when (harness-ui-connected-p)
    (harness-ui-tasks--fetch-review)))

(defun harness-ui-tasks--shutdown ()
  "Stop the timer that redraws the boards' elapsed times.
The mode line notifier stops counting the tasks ready for review."
  (when (timerp harness-ui-tasks--timer) (cancel-timer harness-ui-tasks--timer))
  (setq harness-ui-tasks--timer nil)
  (remove-hook 'harness-ui-event-functions #'harness-ui-tasks--on-review-event)
  (remove-hook 'harness-ui-connected-hook #'harness-ui-tasks--fetch-review)
  (remove-hook 'harness-ui-notify-segment-functions #'harness-ui-tasks--notify-segment)
  (clrhash harness-ui-tasks--in-review)
  (harness-ui-tasks--review-changed))

(harness-define-module 'ui-tasks
  :doc "Task mode: a kanban of one-session tasks with a compose box."
  :requires '(ui)
  :init #'harness-ui-tasks--init
  :shutdown #'harness-ui-tasks--shutdown)

(provide 'harness-ui-tasks)
;;; harness-ui-tasks.el ends here
