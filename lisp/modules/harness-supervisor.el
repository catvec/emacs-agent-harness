;;; harness-supervisor.el --- Supervisor mode: sessions that plan and delegate  -*- lexical-binding: t; -*-

;;; Commentary:

;; Supervisor mode makes a top-level session on an expensive model plan
;; and coordinate while cheaper models do the work.  A prompt that says
;; "delegate, don't do" is ignored often enough that the harness
;; enforces the rule itself.  A session that supervises has
;;
;; - no write tools: `agent/tools' offers it only an allowlist (reading,
;;   the web, coordination, and the supervisor's own tools), and the
;;   `permission/decide' stage at 8 denies, for good, a call to anything
;;   else.  The stage is what holds when the model still has an old tool
;;   list, right after the user switched the mode on;
;; - only read-only, offline bash, and only when the sandbox can confine
;;   commands (`sandbox/confined-p'): `tools/sandbox-options' makes every
;;   command run with every directory read-only and no network;
;; - a turn that may end only on a decision.  The `agent/stop' filter
;;   sends a model that stopped without one back, twice at most, with a
;;   reminder; after that it lets the turn end and leaves a hint.
;;
;; A plan is approved by the user alone, and only in ask mode.  It
;; changes nothing by itself: every call of its workers goes through the
;; whole permission chain in the worker's own session, and that
;; session's mode and judge decide it as usual.  So `submit_plan' and
;; `retry_step' ask the user only in ask mode, with the user present
;; (the session not non-interactive).  In accept-edits, auto and yolo
;; mode, and in any non-interactive session whatever its mode, the
;; `permission/decide' stage at 28 allows them, after the mode and the
;; rules (20) and before the judge (30), so that the auto-mode judge never
;; rules on a plan.  What an earlier stage denied stays denied: the
;; refusals of the stage at 8, a standing deny rule.  `no_plan_needed'
;; only records a decision, and is allowed in every mode.
;;
;; Whether a session supervises is its `:ext' `:supervisor': t, `:false'
;; for hands-on, or nothing for a session this module does not govern
;; (a sub-agent, a side conversation, a session older than the module).
;; It is set when the session is created, so the chat header shows it
;; from the start (`session/created'): a top-level session takes the
;; setting `harness-supervisor' has for its directory, a task's session
;; `harness-supervisor-tasks' (`task/changed'; the session that writes a
;; backlog task up only reads, and takes the setting when the task
;; starts), and a fork its parent's value.  Only the user changes it
;; later, with `supervisor/set': there is no tool for it.  A change
;; takes effect at the next tool call, since the permission stage reads
;; the live session, and at the next step for the tool list.
;;
;; A supervising turn is also watched for length.  A turn that makes
;; `harness-supervisor-step-budget' tool calls is steered to submit its
;; plan with what it knows, and again every half budget after that.  It
;; is a nudge, never a stop.
;;
;; The system prompt of a supervising session says how the mode works,
;; in place of the Planning section.
;;
;; The plan engine is what the supervisor decides with.  Its tools are named
;; in `harness-supervisor-tools' and `harness-supervisor-decision-tools',
;; so the gates above apply to them.  `submit_plan' takes a list of steps,
;; each a self-contained job with a tier (mundane, standard or hard), a
;; context (fork or fresh) and the steps it waits for.  It refuses a plan
;; with problems, naming each, and otherwise records the plan, shows it as
;; the `plan' tool shows one, starts the steps that are ready and ends the
;; turn.  A step runs in a worker, a session of its own with the full tool
;; set, on the model of its tier: `harness-supervisor-tiers', else the one
;; of the supervisor's provider that ranks alike (`provider/tier-model':
;; cheap, balanced, frontier), else the supervisor's own, with a hint.  A
;; fork step forks the supervisor at the call that submitted the plan, a
;; node every step of the plan shares; when a plan has two or more fork
;; steps on one model they all fork through one seed (`seed/fork'), so
;; that the context is written to that model's prompt cache once.  A fresh
;; step is a new session in the supervisor's directory.  The window of both
;; is capped as `harness-tools-agent-context-limit' says, and never
;; silently: a hint in the worker's transcript says so
;; (`harness-supervisor--limit-hint').  The worker's reply is the step's
;; result, which the steps that wait for it are given.  A worker shows
;; in the supervisor's transcript as the `spawn_agent' call that would
;; have started it -- the call when it starts, its result when the step
;; ends -- recorded by the harness (`harness-outside-node-p'), so the
;; supervisor's model never sees it and nothing waits for it.
;;
;; A step that starts again -- `retry_step', perhaps on a higher tier, or an
;; interrupted step after a restart -- decides its context by the cache.  A
;; fork never shares its parent's cache (its system prompt names its own
;; directories, its tool list differs), and a retry on a higher tier runs
;; on a model that has never read the plan's conversation, so forking the
;; supervisor would send all of it uncached at that model's price, and the
;; cowboy's gate (harness-cowboy.el) never sees a new fork as cold.  So
;; with a warm seed for the plan's node on the step's model (`seed/warm-p')
;; the worker forks through it, as above, and reads the shared context from
;; the cache.  Without one it forks the supervisor directly and the fork is
;; compacted before its first turn, as the cowboy would for a session
;; nobody is asked about (`cowboy/compact', its default, a brief summary
;; unless the user chose otherwise; with no cowboy, a brief summary from
;; `compaction/compact'; with no compaction, the whole conversation).  A
;; compaction that fails fails nothing.  Either way the supervisor gets a
;; hint saying which, and the worker's message says its conversation was
;; compacted.  The step keeps the attempt before as `:previous' (`:attempt
;; :session :model :error'), which the worker's message points at: it can
;; read what was tried with session_read, and should not repeat what
;; failed.  First attempts, and fresh steps, decide as before.
;;
;; The plans of a session are its `:ext' `:supervisor-plans', so they
;; survive a restart and the UI shows them: each change of a step is a
;; `session/ext-changed'.  A plan has `:id :title :summary :node :call-id
;; :created :steps', a step `:id :title :prompt :tier :reason :context
;; :after :model :state :session :attempts :result :error', and, once it
;; ran, `:worker-model' (the model of its worker) and, once it started
;; again, `:previous'.  A step is pending, running, done, failed,
;; interrupted, cancelled or superseded: a new plan supersedes the steps
;; of the earlier ones that have not started, and their running steps
;; finish as usual.
;;
;; What the supervisor hears.  A step that is done is a hint, and starts
;; the steps that waited for it.  A step that did not get done -- its
;; worker could not be made or its turn failed, was cancelled or blocked
;; (it is failed), or its worker session was deleted (cancelled) -- is a
;; message of its own, from the harness: the step, its tier and
;; model, why, the steps held on it, and the ways on (`retry_step',
;; perhaps on a higher tier; a new plan; the user).  When the last step of
;; a plan is done the message lists each step with its result and asks the
;; supervisor to check the work and decide.  An idle session starts a turn
;; on a message and a running turn is steered; one that arrives while the
;; turn that submitted the plan is ending would be lost with it, so it
;; waits for the turn's end.  `retry_step' runs a step again on a new
;; worker, and does not end the turn.
;;
;; Work that runs outside the turn is `agent/outstanding' for the tasks
;; module, which keeps the task of the session working, with a line of what
;; it waits for, instead of ending it in review: steps running, and pending
;; steps that can still start.  A step held behind one that did not get
;; done is not counted: the supervisor was told and has to decide.
;;
;; When the harness restarts its workers die.  Once every module is up,
;; the steps still stored as running are interrupted and reported as a
;; failure is: to the session of a task as a message, so that the task
;; carries on, and to any other session queued, to go with the user's next
;; message rather than start an expensive turn unasked.  Deleting a
;; supervisor cancels its workers, and turning the mode off lets them
;; carry on.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defvar harness-tools-agent-planning-section)
(defvar harness-perms-dir-tool)
(defvar harness-supervisor--ending)

;; The permission module is optional here, as this module is a plugin to
;; it: the approval stage asks for the mode and the user's presence only
;; when it is loaded (`harness-supervisor--approval').
(declare-function harness-perms--mode-of "harness-perms" (session))
(declare-function harness-perms--non-interactive-p "harness-perms" (session))

;;;; Settings

(defcustom harness-supervisor t
  "Whether new top-level sessions supervise.
A supervising session plans and coordinates: workers on cheaper models
make the changes, while the session itself cannot change a file, runs
only read-only, offline shell commands and ends every turn on a
decision.  The setting is read per project, as the other settings of
new sessions are, so a .dir-locals.el can override it.  It applies when
a session is created; from then on each session has its own switch,
which its header line shows and the V key flips, so changing
the setting leaves the sessions that exist as they are.  Sub-agents and
side conversations never supervise, and a fork starts as its parent is.
It is on the settings page, under Supervisor mode."
  :type 'boolean :safe #'booleanp :group 'harness)

(defcustom harness-supervisor-tasks t
  "Whether the sessions of tasks supervise.
Like `harness-supervisor', for the sessions the task board starts.  With
nil they work hands-on, as task sessions always did.  The session that
writes a task up for the backlog only reads, so it does not supervise;
it takes this setting when the task starts.  It is on the settings
page, under Supervisor mode."
  :type 'boolean :safe #'booleanp :group 'harness)

(defcustom harness-supervisor-tiers nil
  "Models the workers of a supervisor's plan run on, by tier of the step.
An alist from a tier -- mundane, standard or hard -- to a model id.  A
tier it leaves out runs on the tier of the supervising session's
provider that ranks alike: mundane on its cheap model, standard on its
balanced one, hard on its frontier one (see `harness-model-tiers').
With nil, the default, all three do.  It is on the settings page, under
Supervisor mode."
  :type '(alist :key-type (choice (const :tag "Mundane" mundane)
                                  (const :tag "Standard" standard)
                                  (const :tag "Hard" hard))
                :value-type (string :tag "Model id"))
  :safe (lambda (v) (and (listp v)
                         (cl-every (lambda (cell) (and (consp cell)
                                                       (memq (car cell) '(mundane standard hard))
                                                       (stringp (cdr cell))))
                                   v)))
  :group 'harness)

(defcustom harness-supervisor-step-budget 80
  "Tool calls a supervising turn makes before it is told to submit its plan.
A soft budget: when a turn reaches it the session is steered, once, to
stop investigating and submit the plan with what it knows, and again
every half budget after that (at 80, 120, 160 and so on by default).  It
is a nudge and never a stop.  The default comes from 164 real sessions:
the median turn made 61 tool calls before its plan, the 75th percentile
80 and the 90th percentile 103.  It is on the settings page, under
Supervisor mode."
  :type 'integer :safe (lambda (v) (and (integerp v) (> v 0))) :group 'harness)

(defvar harness-supervisor-tools '("no_plan_needed" "submit_plan" "retry_step")
  "Names of the tools only a supervising session gets.
The allowlist keeps them for a session that supervises and `agent/tools'
drops them for any other.  This module defines `no_plan_needed'; the
plan engine defines the others, and an extension adds its own here.")

(defvar harness-supervisor-decision-tools
  '("no_plan_needed" "submit_plan" "retry_step" "hand_in" "task_submit" "task_control"
    "session_send" "session_control")
  "Names of the tools whose call is a decision that ends a supervising turn.
A turn in which the model stops without having called one is sent back
\(see `harness-supervisor--stop').  They are the plan itself or the
reason none is needed, handing a task in, and handing the work to
another session or task.")

;;;; The allowlist

(defconst harness-supervisor--read-tools
  '("read_file" "grep" "glob" "list_dir" "file_info" "session_info" "session_history"
    "session_list" "session_read" "session_search" "session_wait" "task_list" "task_wait"
    "skill_search" "skill_load" "notification_providers" "emacs_buffers" "emacs_windows"
    "emacs_buffer" "emacs_describe" "emacs_find_definition" "emacs_messages" "emacs_open")
  "Tools a supervising session uses to look at things.  None changes a file.")

(defconst harness-supervisor--net-tools '("web_fetch" "web_search")
  "Tools a supervising session uses to read the web.")

(defconst harness-supervisor--coordination-tools
  '("ask_user" "todo_write" "hand_in" "notify" "session_control" "session_send" "session_move"
    "set_non_interactive" "task_control" "task_submit")
  "Tools a supervising session uses to coordinate with the user and other sessions.")

(defun harness-supervisor--allowed-tools ()
  "Return the names of the tools a supervising session may use besides bash.
They are the reading, web and coordination tools, the tool to ask for
a directory when the permission module defines it, and the tools of
`harness-supervisor-tools'."
  (append harness-supervisor--read-tools
          harness-supervisor--net-tools
          harness-supervisor--coordination-tools
          (and (boundp 'harness-perms-dir-tool) (stringp harness-perms-dir-tool)
               (list harness-perms-dir-tool))
          harness-supervisor-tools))

(defun harness-supervisor--confined-p (dir)
  "Non-nil when commands run in DIR can be confined by the sandbox.
Bash runs read-only and offline only then, so without it a supervising
session has no bash.  Anything that goes wrong counts as not confined."
  (and dir
       (harness-method-exists-p 'sandbox/confined-p)
       (condition-case err
           (and (harness-call 'sandbox/confined-p dir) t)
         (error (harness-log 'warn "supervisor: asking whether %s is confined failed: %S" dir err)
                nil))))

(defun harness-supervisor--dir (session)
  "Return the directory SESSION, a plist, runs commands in, host prefix and all."
  (let ((cwd (plist-get session :cwd))
        (host (plist-get session :host)))
    (if (and (stringp cwd) (stringp host) (not (string-empty-p host)) (not (file-remote-p cwd)))
        (concat host cwd)
      cwd)))

(defun harness-supervisor--tool-allowed-p (tool dir)
  "Non-nil when a supervising session may use TOOL, to run in DIR when it is bash."
  (or (and (member tool (harness-supervisor--allowed-tools)) t)
      (and (equal tool "bash") (harness-supervisor--confined-p dir))))

(defun harness-supervisor--tools (names session)
  "Offer a supervising SESSION only the tools it may use among NAMES.
An `agent/tools' filter at 90, after the filters that add and remove
tools for other reasons.  Every other session loses the supervisor's own
tools.  A nil SESSION is the catalogue of every tool, which stays whole."
  (cond
   ((null session) names)
   ((harness-supervisor--session-p session)
    (let ((dir (harness-supervisor--dir session)))
      (cl-remove-if-not (lambda (name) (harness-supervisor--tool-allowed-p name dir)) names)))
   (t (cl-remove-if (lambda (name) (member name harness-supervisor-tools)) names))))

;;;; The permission stage

(defconst harness-supervisor--deny-hint
  "Put the change in a step of your plan (submit_plan), for a worker to make, or ask the user to switch supervisor mode off with the supervisor button in the chat header."
  "What a supervising session is told when a call is denied.")

(defun harness-supervisor--denial (reason)
  "Return the decision that denies a call for good, because of REASON."
  (list :behavior 'deny :final t
        :reason (format "supervisor mode: %s" reason)
        :hint harness-supervisor--deny-hint))

(defun harness-supervisor--refusal (request)
  "Return the decision that denies REQUEST in a supervising session, or nil.
A call is refused when the session supervises and the tool is not on
the allowlist, or is bash and the sandbox cannot confine the command."
  (let* ((session (plist-get request :session))
         (tool (plist-get request :tool))
         (dir (or (car (plist-get request :paths)) (harness-supervisor--dir session))))
    (when (and (harness-supervisor--session-p session)
               (not (harness-supervisor--tool-allowed-p tool dir)))
      (harness-supervisor--denial
       (if (equal tool "bash")
           (format "bash runs only read-only and offline here, which needs the sandbox, and the sandbox cannot confine commands in %s"
                   (or dir "this session's directory"))
         (format "this session plans and delegates, so it may not use %s" tool))))))

(defun harness-supervisor--gate (decision next request)
  "Deny a call a supervising session may not make, then go on with NEXT.
A `permission/decide' stage at 8, before the jail, the mode and the
judge: DECISION is the current value and REQUEST the call.  The denial
is final, so no permission mode, rule or answer lets the call run.
Calls of a session that does not supervise go on as they were.  A call
this stage cannot check is denied too: it fails closed, since a handler
that signals would be skipped, and the call would then be decided as if
the mode were off.  The stage only refuses: it allows nothing, so what
a supervising session may do is decided by the stages after it, and by
`harness-supervisor--approval' for the tools of its own."
  (funcall next
           (condition-case err
               (or (harness-supervisor--refusal request) decision)
             (error
              (harness-log 'error "supervisor: checking a call of %s failed, so it is denied: %S"
                           (plist-get request :tool) err)
              (harness-supervisor--denial "this call could not be checked, so it is not made")))))

(defconst harness-supervisor--approval-tools '("no_plan_needed" "submit_plan" "retry_step")
  "The supervisor's own tools, which `harness-supervisor--approval' decides.
A tool an extension adds to `harness-supervisor-tools' is decided as
any other is.")

(defconst harness-supervisor--approval-reason
  "a plan is approved by the user in ask mode only, and no judge rules on plans: every call of its workers is decided in the worker's own session"
  "Why `harness-supervisor--approval' allows a plan without asking.")

(defun harness-supervisor--approval-decision (decision request)
  "Return what the approval of REQUEST comes to, given DECISION.
That is DECISION itself, unless it still asks, REQUEST is a call of one
of `harness-supervisor--approval-tools' by a supervising session, and
no user is there to approve it: then it is an allow.  See
`harness-supervisor--approval' for when that is."
  (let ((session (plist-get request :session))
        (tool (plist-get request :tool)))
    (cond
     ((not (and (eq (plist-get decision :behavior) 'ask)
                (member tool harness-supervisor--approval-tools)
                (harness-supervisor--session-p session)))
      decision)
     ;; It records a decision and nothing more, so asking about it is no use.
     ((equal tool "no_plan_needed")
      (list :behavior 'allow :reason "no_plan_needed only records a decision"))
     ;; The mode and whether the user is there are the permission
     ;; module's to say: without it the plan is left as it is.
     ((not (and (fboundp 'harness-perms--mode-of) (fboundp 'harness-perms--non-interactive-p)))
      decision)
     ;; Ask mode, the user there: they approve the plan, at 90.
     ((and (eq (harness-perms--mode-of session) 'ask)
           (not (harness-perms--non-interactive-p session)))
      decision)
     (t (list :behavior 'allow :reason harness-supervisor--approval-reason)))))

(defun harness-supervisor--approval (decision next request)
  "Have only the user approve a plan, and only in ask mode, then go on with NEXT.
A `permission/decide' stage at 28, after the mode and the standing rules
\(20) and the write-up gate of the tasks module (25), before the
auto-mode judge (30): DECISION is the current value and REQUEST the call.
It decides the calls of a supervising session to `submit_plan',
`retry_step' and `no_plan_needed' that are still undecided.

A plan changes nothing by itself: each call of its workers goes through
the whole permission chain in the worker's own session, by that
session's mode, rules and judge.  So the user alone approves a plan,
and only in ask mode while they are there: the stage leaves the decision
as it is, and the prompt at 90 asks.  In every other mode (accept-edits,
auto, yolo), and in a non-interactive session whatever its mode, the plan
is allowed, and no judge ever rules on it.  `no_plan_needed' only
records a decision, and is allowed in every mode.  What an earlier stage
decided stays decided, since only a call that still asks is touched: the
refusals of `harness-supervisor--gate', a standing rule, the write-up
gate.  Without the permission module the mode is not known, so a plan is
left as it is.

A handler that signals is skipped, so when anything goes wrong here the
error is logged and DECISION goes on unchanged: refusing is the work of
the gate."
  (funcall next
           (condition-case err
               (harness-supervisor--approval-decision decision request)
             (error
              (harness-log 'error "supervisor: deciding whether a call of %s needs approval failed, so the other stages decide: %S"
                           (plist-get request :tool) err)
              decision))))

;;;; Bash

(defconst harness-supervisor--sandbox-options '(:read-only t :network nil)
  "The sandbox options of a supervising session's commands: look, don't touch.")

(defun harness-supervisor--sandbox-options (options session-id)
  "Make the commands of a supervising session read-only and offline.
A `tools/sandbox-options' filter: OPTIONS is what the handlers before
this one made, SESSION-ID the session about to run a command.  Options
ask for the sandbox, so a command that cannot have it fails with an
error rather than run unconfined.  A handler that signals is skipped,
which would leave bash writable, so when anything goes wrong here the
answer is read-only all the same."
  (condition-case err
      (if (harness-supervisor--active-id-p session-id)
          (harness-plist-merge options harness-supervisor--sandbox-options)
        options)
    (error
     (harness-log 'error "supervisor: choosing the sandbox options of %s failed, so they are read-only: %S"
                  session-id err)
     (condition-case nil
         (harness-plist-merge options harness-supervisor--sandbox-options)
       (error (copy-sequence harness-supervisor--sandbox-options))))))

;;;; Whether a session supervises

(defun harness-supervisor--value (session)
  "Return the supervisor setting of SESSION, a plist: t, `:false' or nil.
Nil is no setting at all: the session is not governed."
  (let ((value (plist-get (plist-get session :ext) :supervisor)))
    (cond ((null value) nil)
          ((harness-json-true-p value) t)
          (t :false))))

(defun harness-supervisor--session-p (session)
  "Non-nil when SESSION, a plist, supervises."
  (eq (harness-supervisor--value session) t))

(defun harness-supervisor--active-id-p (session-id)
  "Non-nil when the session SESSION-ID supervises.
Signals when there is no such session, unlike `supervisor/active-p'."
  (harness-supervisor--session-p (harness-call 'session/get session-id)))

(harness-defmethod supervisor/active-p (session-id)
  "Return non-nil when session SESSION-ID supervises.
That is when its `:ext' `:supervisor' is set and not `:false'.  A
session that is not governed, or that does not exist, does not."
  (and session-id (harness-call 'session/exists-p session-id)
       (harness-supervisor--active-id-p session-id)))

(harness-defmethod supervisor/get (session-id)
  "Return the supervisor setting of session SESSION-ID: t, `:false' or nil.
`:false' is the user's explicit off, hands-on.  Nil means the session
has no setting: sub-agents and side conversations are not governed, and
neither is a session older than this module."
  (harness-supervisor--value (harness-call 'session/get session-id)))

(harness-defmethod supervisor/set (session-id on)
  "Turn supervisor mode on or off for session SESSION-ID; return its plist.
ON is true for on and `:false' or nil for off, which is stored as an
explicit off, not as no setting.  The change is a hint in the
transcript, \"Supervisor mode on\" or \"Supervisor mode off\", and the
event `supervisor/changed' (SESSION-ID ON), with ON t or `:false'.  On
takes effect at the next tool call, which the permission stage checks
against the session as it is then; off gives the tools back from the
next step.  Only the user does this, over ACP as `_harness/supervisor/set'
with `:sessionId' and `:on'; the agent has no tool for it."
  (let* ((value (if (harness-json-true-p on) t :false))
         (session (harness-call 'session/set-ext session-id :supervisor value
                                (if (eq value t) "Supervisor mode on" "Supervisor mode off"))))
    (harness-emit 'supervisor/changed session-id value)
    session))

(harness-declare-event 'supervisor/changed
                       "(SESSION-ID ON) when the user turned supervisor mode on (ON t) or off (ON :false) for a session")

;;;; New sessions

(defconst harness-supervisor--write-up-key :supervisor-write-up
  "The `:ext' key that marks the session of a backlog task's write-up.
That session does not supervise while it only reads, and takes
`harness-supervisor-tasks' when the task starts.  The mark is what tells
it from a session older than this module, which is never governed.")

(defvar harness-supervisor--configured (make-hash-table :test 'equal)
  "Ids of the task sessions whose setting `task/changed' decided.
Each is decided once, so that a later event never overrides a switch the
user flipped.")

(defun harness-supervisor--setting (cwd)
  "Return non-nil when `harness-supervisor' is on for new sessions at CWD."
  (harness-json-true-p
   (if (harness-method-exists-p 'config/get)
       (condition-case nil
           (harness-call 'config/get 'harness-supervisor cwd)
         (error harness-supervisor))
     harness-supervisor)))

(defun harness-supervisor--kind (session)
  "Return the kind of SESSION, a plist, as a symbol."
  (let ((kind (plist-get session :kind)))
    (if (stringp kind) (intern kind) kind)))

(defun harness-supervisor--set-ext (id key value)
  "Set KEY of session ID's `:ext' to VALUE (nil removes it), with no hint.
A hint would start the transcript of a session that has no message yet."
  (harness-call 'session/set-ext id key value))

(defun harness-supervisor--on-created (id session)
  "Give the new session ID, whose plist is SESSION, its supervisor setting.
A subscriber of `session/created'.  A top-level session takes
`harness-supervisor' for its directory, and a fork its parent's value
when the parent has one.  A sub-agent, a side conversation and any
other kind are never governed; only a top-level session of its own
starts supervised.  A setting its maker gave it in `:ext' stays."
  (condition-case err
      (unless (plist-member (plist-get session :ext) :supervisor)
        (let* ((kind (harness-supervisor--kind session))
               (parent-id (plist-get session :parent-id))
               (value (cond
                       ((and (eq kind 'main) (null parent-id))
                        (if (harness-supervisor--setting (plist-get session :cwd)) t :false))
                       ((and (eq kind 'fork) parent-id (harness-call 'session/exists-p parent-id))
                        (harness-supervisor--value (harness-call 'session/get parent-id))))))
          ;; `session/create' announces and returns the session as it is
          ;; after this, so its maker and the header see the setting.
          (when value
            (harness-supervisor--set-ext id :supervisor value))))
    (error (harness-log 'warn "supervisor: setting up session %s failed: %S" id err))))

(defun harness-supervisor--write-up-p (task)
  "Non-nil when TASK, a task view, is being written up or waits in the backlog.
The tasks module's session then only reads.  That is the state
`refining', or `pending' with a session: a task that waits for a slot
has none."
  (or (eq (plist-get task :state) 'refining)
      (and (eq (plist-get task :state) 'pending) (plist-get task :session) t)))

(defun harness-supervisor--on-task-changed (task)
  "Set the supervisor setting of the session of TASK, a task view, when it is new.
A subscriber of `task/changed'.  The tasks module makes the session of a
task, and the one that writes a backlog task up, as top-level sessions,
and links them to the task afterwards.  While the session has no
message yet, the session of a write-up has no setting, as it only reads,
and the session of the work takes `harness-supervisor-tasks'.  A session
that wrote a task up takes it when the task starts.  Both act on a
brand-new session only, once, so a restart never overrides the user's
switch; a session the user adopted as a task is theirs already."
  (condition-case err
      (let ((sid (plist-get task :session)))
        (when (and sid (harness-call 'session/exists-p sid))
          (let* ((session (harness-call 'session/get sid))
                 (write-up (harness-supervisor--write-up-p task)))
            (cond
             ((and (plist-get (plist-get session :ext) harness-supervisor--write-up-key)
                   (not write-up))
              (unless (harness-supervisor--value session)
                (harness-supervisor--set-ext sid :supervisor (if harness-supervisor-tasks t :false)))
              (harness-supervisor--set-ext sid harness-supervisor--write-up-key nil))
             ((or (plist-get session :head)
                  (plist-get task :adopted)
                  (gethash sid harness-supervisor--configured))
              nil)
             (t
              (puthash sid t harness-supervisor--configured)
              (if write-up
                  (progn (harness-supervisor--set-ext sid :supervisor nil)
                         (harness-supervisor--set-ext sid harness-supervisor--write-up-key t))
                (harness-supervisor--set-ext sid :supervisor (if harness-supervisor-tasks t :false))))))))
    (error (harness-log 'warn "supervisor: setting up the session of task %s failed: %S"
                        (plist-get task :id) err))))

;;;; Turns: decisions and the budget

(defvar harness-supervisor--decisions (make-hash-table :test 'equal)
  "Session id -> ids of the decision tool calls of its running turn.
A call that failed is taken out again: it decided nothing.")

(defvar harness-supervisor--reminders (make-hash-table :test 'equal)
  "Session id -> how many times its running turn was sent back for a decision.")

(defvar harness-supervisor--calls (make-hash-table :test 'equal)
  "Session id -> how many tool calls its running turn made.")

(defconst harness-supervisor--max-reminders 2
  "Most times a turn is sent back to end on a decision.")

(defconst harness-supervisor--reminder
  "Supervisor mode: end this turn on a decision. If the work changes files, end with submit_plan, putting the work in its steps. If you answered a question, nothing needs doing, or a plan is still running, end with no_plan_needed and a one-line reason."
  "What a supervising model is told when it stops without a decision.")

(defconst harness-supervisor--no-decision-hint
  "The turn ended without a decision: no plan was submitted, and no_plan_needed was not called."
  "Hint left when a supervising turn ends without a decision all the same.")

(defun harness-supervisor--sender ()
  "Return the sender of the messages this module sends, the harness's own."
  (harness-sender-system "supervisor"))

(defun harness-supervisor--decided-p (session-id)
  "Non-nil when the running turn of SESSION-ID called a decision tool."
  (and (gethash session-id harness-supervisor--decisions) t))

(defun harness-supervisor--note-decision (session-id call-id)
  "Note that CALL-ID, a decision tool call, was made in SESSION-ID's turn."
  (cl-pushnew call-id (gethash session-id harness-supervisor--decisions) :test #'equal))

(defun harness-supervisor--on-turn-started (session-id)
  "Forget what the last turn of SESSION-ID did: a new one starts."
  (remhash session-id harness-supervisor--decisions)
  (remhash session-id harness-supervisor--reminders)
  (remhash session-id harness-supervisor--calls))

(defun harness-supervisor--on-session-deleted (session-id &rest _)
  "Forget everything about the deleted session SESSION-ID.
A supervisor's running workers are cancelled, and the step of a deleted
worker is cancelled (see `harness-supervisor--forget-plans')."
  (harness-supervisor--on-turn-started session-id)
  (remhash session-id harness-supervisor--configured)
  (condition-case err
      (progn (harness-supervisor--forget-plans session-id)
             (harness-supervisor--worker-deleted session-id))
    (error (harness-log 'warn "supervisor: cleaning up after session %s failed: %S" session-id err))))

(defun harness-supervisor--budget-point-p (n)
  "Non-nil when N tool calls in a turn call for a nudge.
That is when N reaches `harness-supervisor-step-budget' and every half
budget after it."
  (let ((budget harness-supervisor-step-budget))
    (and (integerp budget) (> budget 0) (>= n budget)
         (zerop (mod (- n budget) (max 1 (/ budget 2)))))))

(defun harness-supervisor--budget-text (n)
  "Return the message that tells a turn which made N tool calls to wrap up."
  (format "%d tool calls so far. Stop investigating and submit the plan with what you know, putting open questions in the steps." n))

(defun harness-supervisor--on-tool-call (session-id node)
  "Count the tool call NODE of SESSION-ID; note a decision; nudge a long turn.
A subscriber of `agent/tool-call', for a supervising session.  The nudge
is a steering message the running turn takes at its next step."
  (when (harness-supervisor--active-id-p session-id)
    (let ((n (1+ (gethash session-id harness-supervisor--calls 0))))
      (puthash session-id n harness-supervisor--calls)
      (when (member (plist-get node :tool) harness-supervisor-decision-tools)
        (harness-supervisor--note-decision session-id (plist-get node :call-id)))
      (when (harness-supervisor--budget-point-p n)
        (harness-catch (harness-call-async 'agent/prompt session-id (harness-supervisor--budget-text n)
                                           (list :from (harness-supervisor--sender)))
                       #'ignore)))))

(defun harness-supervisor--on-tool-finished (session-id call result)
  "Take CALL of SESSION-ID back out of the decisions when RESULT is an error.
A subscriber of `tools/finished'.  A plan that was refused, or a call
that was denied, decided nothing, so the turn is still owed one.  A
result that ends the turn (`hand_in') begins the time in which a report
to the session would be lost with the turn, which the end of the turn
closes (see `harness-supervisor--send')."
  (when (and (harness-json-true-p (plist-get result :is-error))
             (gethash session-id harness-supervisor--decisions))
    (setf (gethash session-id harness-supervisor--decisions)
          (cl-remove (plist-get call :id) (gethash session-id harness-supervisor--decisions)
                     :test #'equal)))
  (when (and (plist-get result :end-turn)
             (harness-method-exists-p 'agent/running)
             (harness-call 'agent/running session-id))
    (puthash session-id t harness-supervisor--ending)))

(defun harness-supervisor--stop-answer (value session)
  "Return what the `agent/stop' chain goes on with for the stop VALUE of SESSION.
VALUE is (:stop t) and SESSION the session plist.  A supervising session
whose turn called no decision tool is sent back with a reminder, at most
`harness-supervisor--max-reminders' times a turn; after that the turn
ends, with a hint.  Any other value goes through unchanged."
  (let ((sid (plist-get session :id)))
    (cond
     ((not (and (harness-json-true-p (plist-get value :stop))
                (harness-supervisor--session-p session)
                (not (harness-supervisor--decided-p sid))))
      value)
     ((< (gethash sid harness-supervisor--reminders 0) harness-supervisor--max-reminders)
      (cl-incf (gethash sid harness-supervisor--reminders 0))
      (list :stop nil :message harness-supervisor--reminder :from (harness-supervisor--sender)))
     (t
      (harness-call 'session/hint sid harness-supervisor--no-decision-hint)
      value))))

(defun harness-supervisor--stop (value next session)
  "Send a supervising model that stopped without a decision back (`agent/stop').
VALUE and SESSION are the filter's, and NEXT continues the chain with the
answer of `harness-supervisor--stop-answer'.  A failure here lets the
model stop, as it would without this module: the reminder only nudges."
  (funcall next (condition-case err
                    (harness-supervisor--stop-answer value session)
                  (error (harness-log 'error "supervisor: the stop rule failed: %S" err)
                         value))))

;;;; no_plan_needed

(defun harness-supervisor--no-plan-needed (input ctx)
  "Handler of the no_plan_needed tool: record that INPUT's reason needs no plan.
CTX is the call's context.  The call is the turn's decision, noted with a
hint in the transcript.  It does not end the turn, so the model can
still write its answer."
  (let ((sid (plist-get ctx :session-id))
        (reason (plist-get input :reason)))
    (if (harness-string-blank-p reason)
        (harness-tool-error "A reason is needed: one line on why this turn needs no plan")
      (harness-supervisor--note-decision sid (plist-get ctx :call-id))
      (harness-call 'session/hint sid (format "No plan needed: %s" (string-trim reason)))
      (harness-tool-ok "Noted. Give your reply now and end the turn."))))

(harness-define-tool "no_plan_needed"
  :label "No plan needed"
  :description "Say that this turn needs no plan, with a one-line reason: you answered a question, there is nothing to do, or a plan you submitted is still running. It ends your turn's duty to decide, not the turn: give your reply after it. Work that changes files always goes in a plan (submit_plan), however small: you cannot change files yourself, and a worker makes the change."
  :schema '(:type "object"
            :properties (:reason (:type "string" :description "One line on why this turn needs no plan."))
            :required ("reason"))
  :kind 'meta
  :subject (lambda (input) (harness-first-line (plist-get input :reason) 60))
  :handler #'harness-supervisor--no-plan-needed)

;;;; The plan engine: plans and steps
;;
;; A session's plans are its `:ext' `:supervisor-plans': a list of plists,
;; oldest first, that JSON keeps as they are (strings, numbers and lists;
;; a field with nothing to say is left out).
;;
;;   plan  (:id :title :summary :node :call-id :created :steps)
;;   step  (:id :title :prompt :tier :reason :context :after :model :state
;;          :session :attempts :result :error :worker-model :previous)
;;
;; `:node' and `:call-id' are the fork point of the plan: the call that
;; submitted it, which every fork step forks the supervisor at.  A step's
;; `:state' is "pending", "running", "done", "failed", "interrupted",
;; "cancelled" or "superseded"; `:session' is the id of its worker, and
;; `:result' the worker's final reply when it is done.  `:worker-model' is
;; the model that worker was made for, which `retry_step' may change.  A
;; step that started again has `:previous', the attempt before:
;; (:attempt N :session SESSION :model MODEL :error TEXT).

(declare-function harness-tools-agent-context-limit "harness-tools-agent" (parent-id fork &optional inherited))
(declare-function harness-tools-agent-inherited-context "harness-tools-agent" (parent-id))
(declare-function harness-tools-agent-context-limit-hint "harness-tools-agent" (limit fork &optional inherited))

(defconst harness-supervisor--plans-key :supervisor-plans
  "The `:ext' key under which a session keeps its plans.")

(defconst harness-supervisor--tier-names '("mundane" "standard" "hard")
  "The tiers a step may have, as the tools take them.")

(defconst harness-supervisor--provider-tiers
  '(("mundane" . cheap) ("standard" . balanced) ("hard" . frontier))
  "The tier of its provider's models that each tier of a step ranks with.")

(defconst harness-supervisor--context-names '("fork" "fresh")
  "The contexts a step's worker may start with.")

(defconst harness-supervisor--retryable-states '("failed" "interrupted" "cancelled")
  "The states of a step that ended without being done, which `retry_step' accepts.")

(defconst harness-supervisor--result-limit 4000
  "Most characters of a worker's final reply that its step keeps as its result.")

(defconst harness-supervisor--hand-over-limit 2000
  "Most characters of a step's result that the prompt of a later step repeats.")

(defconst harness-supervisor--report-limit 1500
  "Most characters of a result, an error or a reply that a report repeats.")

(defvar harness-supervisor--live (make-hash-table :test 'equal)
  "(SESSION-ID PLAN-ID STEP-ID) -> the worker of a step that runs.
The value is the worker's session id, or t while the worker is being
made.  It lives in memory only, which is the point: after a restart no
worker is alive, and a step stored as running with no entry here is one
the restart interrupted.")

(defvar harness-supervisor--ending (make-hash-table :test 'equal)
  "Session id -> t while the turn that submitted a plan is ending.
`submit_plan' ends its turn, and a message that steers it meanwhile
would be lost with it, so reports wait (see `harness-supervisor--send').")

(defvar harness-supervisor--held (make-hash-table :test 'equal)
  "Session id -> the reports held back until its ending turn is over, oldest first.")

(defvar harness-supervisor--spawns (make-hash-table :test 'equal)
  "Worker session id -> the spawn_agent call shown for it, while it has no result.
The call is (:session SUPERVISOR :call-id ID :started TIME), SUPERVISOR
the session whose transcript shows it (see
`harness-supervisor--open-call').")

(defun harness-supervisor--plans (session-id)
  "Return the plans of session SESSION-ID, oldest first."
  (let ((plans (plist-get (plist-get (harness-call 'session/get session-id) :ext)
                          harness-supervisor--plans-key)))
    (and (consp plans) (consp (car plans)) plans)))

(defun harness-supervisor--plan (plans plan-id)
  "Return the plan whose id is PLAN-ID among PLANS, or nil."
  (cl-find plan-id plans :key (lambda (plan) (plist-get plan :id)) :test #'equal))

(defun harness-supervisor--step (plan step-id)
  "Return the step whose id is STEP-ID in PLAN, or nil."
  (cl-find step-id (plist-get plan :steps) :key (lambda (step) (plist-get step :id)) :test #'equal))

(defun harness-supervisor--find-step (plans step-id &optional plan-id)
  "Return (PLAN . STEP) for STEP-ID among PLANS, or nil.
With PLAN-ID the step is looked for in that plan only, else in the
latest plan that has it."
  (cl-loop for plan in (if plan-id
                           (let ((plan (harness-supervisor--plan plans plan-id))) (and plan (list plan)))
                         (reverse plans))
           for step = (harness-supervisor--step plan step-id)
           when step return (cons plan step)))

(defun harness-supervisor--with (plist &rest props)
  "Return a copy of PLIST with PROPS set.  A nil value removes its key."
  (let ((out (copy-sequence plist)))
    (cl-loop for (key value) on props by #'cddr
             do (setq out (if value
                              (plist-put out key value)
                            (harness-plist-remove out key))))
    out))

(defun harness-supervisor--save-plans (session-id plans)
  "Store PLANS as the plans of session SESSION-ID.
The session announces the change (`session/ext-changed'), which is how
the UI sees a step move on."
  (harness-call 'session/set-ext session-id harness-supervisor--plans-key plans))

(defun harness-supervisor--update-step (session-id plan-id step-id &rest props)
  "Set PROPS on step STEP-ID of plan PLAN-ID of session SESSION-ID.
A nil value removes its key.  Return the new step, or nil, storing
nothing, when the session has no such step."
  (let* ((plans (harness-supervisor--plans session-id))
         (plan (harness-supervisor--plan plans plan-id))
         (step (and plan (harness-supervisor--step plan step-id))))
    (when step
      (let ((new (apply #'harness-supervisor--with step props)))
        (harness-supervisor--save-plans
         session-id
         (mapcar (lambda (other)
                   (if (eq other plan)
                       (harness-supervisor--with
                        plan :steps (mapcar (lambda (s) (if (eq s step) new s)) (plist-get plan :steps)))
                     other))
                 plans))
        new))))

(defun harness-supervisor--state-p (step &rest states)
  "Non-nil when the state of STEP is one of STATES."
  (and (member (plist-get step :state) states) t))

(defun harness-supervisor--ready-p (plan step)
  "Non-nil when STEP of PLAN is pending and every step it waits for is done."
  (and (harness-supervisor--state-p step "pending")
       (cl-every (lambda (id) (harness-supervisor--state-p (harness-supervisor--step plan id) "done"))
                 (plist-get step :after))))

(defun harness-supervisor--waiting-p (plan step &optional seen)
  "Non-nil when pending STEP of PLAN can still start.
That is when nothing it waits for, directly or not, ended without being
done: a step held behind a failure is the supervisor's to decide on.
SEEN holds the steps being looked at, which keeps a damaged plan with a
cycle from looping."
  (and (harness-supervisor--state-p step "pending")
       (not (memq step seen))
       (cl-every (lambda (id)
                   (let ((dep (harness-supervisor--step plan id)))
                     (or (harness-supervisor--state-p dep "done" "running")
                         (and dep (harness-supervisor--waiting-p plan dep (cons step seen))))))
                 (plist-get step :after))))

(defun harness-supervisor--dependants (plan step-id)
  "Return the steps of PLAN that wait for STEP-ID, directly or not, in plan order."
  (let ((found nil) (frontier (list step-id)))
    (while frontier
      (let ((id (pop frontier)))
        (dolist (step (plist-get plan :steps))
          (when (and (member id (plist-get step :after)) (not (member (plist-get step :id) found)))
            (push (plist-get step :id) found)
            (push (plist-get step :id) frontier)))))
    (cl-remove-if-not (lambda (step) (member (plist-get step :id) found)) (plist-get plan :steps))))

(defun harness-supervisor--running-steps (plans)
  "Return the running steps of PLANS."
  (cl-loop for plan in plans
           append (cl-remove-if-not (lambda (step) (harness-supervisor--state-p step "running"))
                                    (plist-get plan :steps))))

(defun harness-supervisor--supersede (plan)
  "Return PLAN with the steps that are still pending superseded."
  (if (cl-some (lambda (step) (harness-supervisor--state-p step "pending")) (plist-get plan :steps))
      (harness-supervisor--with
       plan :steps (mapcar (lambda (step)
                             (if (harness-supervisor--state-p step "pending")
                                 (harness-supervisor--with step :state "superseded")
                               step))
                           (plist-get plan :steps)))
    plan))

;;;; The plan engine: reading a plan

(defun harness-supervisor--text (value)
  "Return VALUE as trimmed text when it is a string or a number, else nil."
  (cond ((stringp value) (string-trim value))
        ((numberp value) (number-to-string value))))

(defun harness-supervisor--text-list (value)
  "Return VALUE, a list of ids as a model may give it, as a list of texts.
A text that is not one stays out; one string stands for a list of one."
  (let ((items (cond ((stringp value) (list value))
                     ((vectorp value) (append value nil))
                     ((listp value) value))))
    (delq nil (mapcar #'harness-supervisor--text items))))

(defun harness-supervisor--read-step (raw index)
  "Read RAW, the INDEXth step (from 1) of a plan as the model gave it.
Return (STEP . PROBLEMS): STEP is a plist of the fields the model
chooses, nil when RAW is no object, and PROBLEMS are texts, one for
each thing wrong with the step."
  (if (not (and (consp raw) (keywordp (car raw))))
      (cons nil (list (format "step %d is not an object" index)))
    (let* ((id (harness-supervisor--text (plist-get raw :id)))
           (name (if (harness-string-blank-p id) (format "step %d" index) (format "step %s" id)))
           (prompt (harness-supervisor--text (plist-get raw :prompt)))
           (title (harness-supervisor--text (plist-get raw :title)))
           (tier (downcase (or (harness-supervisor--text (plist-get raw :tier)) "")))
           (context (let ((c (downcase (or (harness-supervisor--text (plist-get raw :context)) ""))))
                      (if (string-empty-p c) "fork" c)))
           (problems nil))
      (when (harness-string-blank-p id)
        (push (format "%s has no id: give each step a short unique id" name) problems))
      (when (harness-string-blank-p prompt)
        (push (format "%s has a blank prompt: the worker has nothing to do" name) problems))
      (unless (member tier harness-supervisor--tier-names)
        (push (format "%s has %s as its tier: it must be mundane, standard or hard"
                      name (if (string-empty-p tier) "none" (format "%S" tier)))
              problems))
      (unless (member context harness-supervisor--context-names)
        (push (format "%s has %S as its context: it must be fork or fresh" name context) problems))
      (cons (harness-supervisor--with
             nil
             :id id
             :title (if (harness-string-blank-p title)
                        (if (harness-string-blank-p prompt) id (harness-first-line prompt 60))
                      title)
             :prompt prompt :tier tier
             :reason (let ((reason (harness-supervisor--text (plist-get raw :reason))))
                       (and (not (harness-string-blank-p reason)) reason))
             :context context
             :after (harness-supervisor--text-list (plist-get raw :after)))
            (nreverse problems)))))

(defun harness-supervisor--cycle-ids (steps)
  "Return the ids of the STEPS that wait for themselves, directly or not."
  (let ((after (mapcar (lambda (step) (cons (plist-get step :id) (plist-get step :after))) steps)))
    (cl-remove-if-not
     (lambda (id)
       (let ((seen nil) (frontier (cdr (assoc id after))) (found nil))
         (while (and frontier (not found))
           (let ((next (pop frontier)))
             (cond ((equal next id) (setq found t))
                   ((member next seen))
                   (t (push next seen)
                      (setq frontier (append (cdr (assoc next after)) frontier))))))
         found))
     (delete-dups (delq nil (mapcar #'car after))))))

(defun harness-supervisor--check-steps (steps)
  "Return the problems STEPS have together: ids used twice, unknown ids, cycles."
  (let* ((ids (delq nil (mapcar (lambda (step) (plist-get step :id)) steps)))
         (problems nil))
    (dolist (id (delete-dups (copy-sequence ids)))
      (let ((n (cl-count id ids :test #'equal)))
        (when (> n 1)
          (push (format "the id %s is used by %d steps: ids must be unique" id n) problems))))
    (dolist (step steps)
      (dolist (dep (plist-get step :after))
        (unless (member dep ids)
          (push (format "step %s waits for %s, which is no step of this plan" (plist-get step :id) dep)
                problems))))
    (let ((cyclic (harness-supervisor--cycle-ids steps)))
      (when cyclic
        (push (format "steps %s wait for each other in a cycle, so none of them could start"
                      (string-join cyclic ", "))
              problems)))
    (nreverse problems)))

(defun harness-supervisor--read-plan (input)
  "Read the plan in INPUT, the arguments of a `submit_plan' call.
Return (STEPS . PROBLEMS): STEPS are the steps as
`harness-supervisor--read-step' reads them, PROBLEMS everything wrong
with the plan, as texts."
  (let* ((summary (harness-supervisor--text (plist-get input :summary)))
         (raw (let ((steps (plist-get input :steps)))
                (cond ((vectorp steps) (append steps nil))
                      ;; One step given as an object instead of a list of them.
                      ((and (consp steps) (keywordp (car steps))) (list steps))
                      (t steps))))
         (problems nil)
         (steps nil))
    (when (harness-string-blank-p summary)
      (push "the summary is empty: it is the plan in markdown, shown to the user" problems))
    (if (not (and (consp raw) (proper-list-p raw)))
        (push "the plan has no steps: it needs at least one" problems)
      (cl-loop for item in raw for index from 1
               do (let ((read (harness-supervisor--read-step item index)))
                    (when (car read) (push (car read) steps))
                    (dolist (problem (cdr read)) (push problem problems)))))
    (setq steps (nreverse steps))
    (dolist (problem (harness-supervisor--check-steps steps)) (push problem problems))
    (cons steps (nreverse problems))))

(defun harness-supervisor--problems-result (tool problems)
  "Return the error result of TOOL for PROBLEMS, every one listed.
It is an error result so that the turn still owes a decision (see
`harness-supervisor--on-tool-finished')."
  (harness-tool-error
   (format "%s was refused, and nothing started. Fix %s and call %s again:\n%s"
           tool (if (cdr problems) "these problems" "this problem") tool
           (mapconcat (lambda (problem) (concat "- " problem)) problems "\n"))))

;;;; The plan engine: models

(defun harness-supervisor--provider-tier-model (model tier)
  "Return the model of the provider of MODEL that ranks with TIER, or nil."
  (when (and (stringp model) (harness-method-exists-p 'provider/tier-model))
    (condition-case err
        (let ((found (harness-call 'provider/tier-model model
                                   (cdr (assoc tier harness-supervisor--provider-tiers)))))
          (and (stringp found) (not (string-empty-p found)) found))
      (error (harness-log 'warn "supervisor: finding the %s model for %s failed: %S" tier model err)
             nil))))

(defun harness-supervisor--tier-model (session tier)
  "Return (MODEL . FALLBACK) for the workers of TIER of the supervising SESSION.
MODEL is the model of `harness-supervisor-tiers' for TIER, else the one
of SESSION's provider that ranks with TIER (cheap, balanced or
frontier), else SESSION's own, and FALLBACK is then non-nil."
  (let ((override (cdr (assoc-string tier harness-supervisor-tiers))))
    (if (and (stringp override) (not (string-empty-p override)))
        (cons override nil)
      (let ((found (harness-supervisor--provider-tier-model (plist-get session :model) tier)))
        (if found
            (cons found nil)
          (cons (plist-get session :model) t))))))

(defun harness-supervisor--fallback-hint (session steps)
  "Say in SESSION's transcript which STEPS run on its own model.
They do for want of another."
  (when steps
    (harness-call 'session/hint (plist-get session :id)
                  (format "No model was found for the tier of %s: %s run%s on this session's own model, %s"
                          (string-join (mapcar (lambda (step) (format "step %s (%s)" (plist-get step :id)
                                                                      (plist-get step :tier)))
                                               steps)
                                       ", ")
                          (if (cdr steps) "they" "it") (if (cdr steps) "" "s")
                          (plist-get session :model)))))

;;;; The plan engine: workers

(defun harness-supervisor--worker-name (step)
  "Return the name of the session of STEP's worker."
  (harness-truncate-end (format "Step %s: %s" (plist-get step :id) (plist-get step :title)) 80))

(defun harness-supervisor--context-limit (session-id fork &optional inherited)
  "Return the context window limit of a worker of SESSION-ID, or nil for none.
FORK is non-nil for a worker that starts with the conversation, and
INHERITED, when known, the tokens of context it starts with."
  (and (fboundp 'harness-tools-agent-context-limit)
       (harness-tools-agent-context-limit session-id fork inherited)))

(defun harness-supervisor--inherited (session-id fork)
  "Return the tokens of context a worker of SESSION-ID starts with, or nil.
FORK is non-nil for a worker that starts with the conversation: it
inherits what the supervisor holds.  A fresh one starts with none."
  (and fork (fboundp 'harness-tools-agent-inherited-context)
       (harness-tools-agent-inherited-context session-id)))

(defun harness-supervisor--limit-hint (worker limit fork inherited)
  "Say in the transcript of WORKER that its context window is capped at LIMIT.
WORKER is the worker's session; FORK is non-nil when it started with
the conversation, INHERITED tokens of it.  A worker is a sub-agent,
whose window is deliberately short (`harness-subagent-context-limit'),
and the cap is never silent.  Nothing is said without a cap, and a
hint that cannot be added fails nothing."
  (condition-case err
      (when-let* ((text (and (fboundp 'harness-tools-agent-context-limit-hint)
                             (harness-tools-agent-context-limit-hint limit fork inherited))))
        (harness-supervisor--hint (plist-get worker :id) text))
    (error (harness-log 'warn "supervisor: no context cap hint for %s: %s"
                        (plist-get worker :id) (harness-error-message err)))))

(defun harness-supervisor--refit-limit (session-id worker)
  "Fit the context window limit of WORKER to its compacted conversation.
WORKER is a fork of SESSION-ID, the supervisor.  Its limit was set when
it was made, from all the supervisor holds; compacted, it starts with
far less, so it gets the limit of a fork that starts with that much
\(`harness-supervisor--context-limit'), and no window of its own beyond
it.  The change is silent here: the hint about the cap that follows says
it.  Return (:context-limit LIMIT :context-inherited N) once the limit
is set, nil when nothing caps a worker or the context cannot be told."
  (condition-case err
      (let* ((wid (plist-get worker :id))
             (context (and (harness-method-exists-p 'compaction/estimate)
                           (plist-get (harness-call 'compaction/estimate wid) :context)))
             (limit (and (numberp context)
                         (harness-supervisor--context-limit session-id t (round context)))))
        (when limit
          (harness-call 'session/update wid :context-window-limit limit :silent t)
          (list :context-limit limit :context-inherited (round context))))
    (error (harness-log 'warn "supervisor: could not fit the context limit of %s: %s"
                        (plist-get worker :id) (harness-error-message err))
           nil)))

(defun harness-supervisor--seeded-p (plan step)
  "Non-nil when the worker of STEP forks through a seed.
That is when PLAN has two or more fork steps on STEP's model, all its
steps counted: they share one seed, whose cache is written once."
  (and (equal (plist-get step :context) "fork")
       (harness-method-exists-p 'seed/fork)
       (>= (cl-count-if (lambda (other) (and (equal (plist-get other :context) "fork")
                                             (equal (plist-get other :model) (plist-get step :model))))
                        (plist-get plan :steps))
           2)))

(defun harness-supervisor--restarted-p (step)
  "Non-nil when STEP starts again: this is its second attempt or a later one.
`harness-supervisor--start-step' counts the attempt before the worker is
made, so a step on its first attempt has 1."
  (> (or (plist-get step :attempts) 0) 1))

(defun harness-supervisor--warm-seed (session-id plan step)
  "Return the id of the warm seed a fork of STEP of PLAN would read, or nil.
SESSION-ID is the supervisor.  It is `seed/warm-p' for the plan's node
and the step's model: a seed whose cache lasts, or is being primed or
warmed.  Nil too when there is no seed module, or it cannot tell."
  (and (harness-method-exists-p 'seed/warm-p)
       (harness-method-exists-p 'seed/fork)
       (condition-case nil
           (harness-call 'seed/warm-p session-id (plist-get step :model) (plist-get plan :node))
         (error nil))))

(defun harness-supervisor--own-compaction (worker-id)
  "Return the kind of the compaction WORKER-ID itself made, a string, or nil.
Its own: the nodes it inherited from the supervisor may hold others."
  (condition-case nil
      (let ((node (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'compaction)
                                               (equal (plist-get n :session) worker-id)))
                              (harness-call 'session/nodes worker-id) :from-end t)))
        (and node (harness-node-compaction-kind node)))
    (error nil)))

(defun harness-supervisor--compaction-hint (worker-id model text)
  "Add a hint to WORKER-ID, a fork onto MODEL: no cache holds its context.
TEXT says what is done about it."
  (harness-supervisor--hint
   worker-id (format "No prompt cache on %s holds the supervisor's conversation: %s" model text)))

(defun harness-supervisor--compact-fork (session-id worker model)
  "Return a promise of WORKER, a fork of SESSION-ID onto MODEL, compacted.
No warm prompt cache holds the conversation the fork inherited, so its
first turn would send all of it uncached at MODEL's price.  The cowboy
compacts it as it does a session nobody is asked about (`cowboy/compact',
its default, brief unless the user chose otherwise); without the cowboy
a brief summary is made (`compaction/compact'); without compaction the
fork goes on as it is, with a hint saying so.  A compaction that fails
fails nothing: the promise resolves all the same.

It resolves with WORKER and, under `:context-cache', how its context
stands: `compacted' (and `:compaction', the kind of node the worker
made) or `whole'.  A compacted fork's context window limit is fitted to
what it now holds (`harness-supervisor--refit-limit'), whose
`:context-limit' and `:context-inherited' it then has too."
  (let* ((wid (plist-get worker :id))
         (done (lambda (&rest _)
                 (append worker
                         (if-let* ((kind (harness-supervisor--own-compaction wid)))
                             (append (list :context-cache 'compacted :compaction kind)
                                     (harness-supervisor--refit-limit session-id worker))
                           (list :context-cache 'whole))))))
    (harness-then
     (cond
      ((harness-method-exists-p 'cowboy/compact)
       (harness-call-async 'cowboy/compact wid
                           :why (format "No prompt cache on %s holds the supervisor's conversation" model)
                           :by 'cold-start))
      ((harness-method-exists-p 'compaction/compact)
       (harness-supervisor--compaction-hint wid model "compacting into a brief summary first")
       (harness-call-async 'compaction/compact wid (list :kind 'brief)))
      (t
       (harness-supervisor--compaction-hint
        wid model "nothing can compact it here, so carrying on with the whole conversation, uncached")
       (harness-resolved nil)))
     done
     (lambda (err)
       (harness-log 'warn "supervisor: compacting the fork %s failed: %s" wid (harness-error-message err))
       (harness-supervisor--hint
        wid (format "No compaction (%s): carrying on with the whole conversation" (harness-error-message err)))
       (funcall done)))))

(defun harness-supervisor--make-worker (session-id plan step)
  "Return a promise of the session of the worker of STEP of PLAN.
SESSION-ID is the supervisor.  A fork step forks it at the call that
submitted the plan -- through a seed when the plan has several fork
steps on the model -- and a fresh step is a new session in the
supervisor's directory, with its settings.

A fork step that starts again (`harness-supervisor--restarted-p': its
`retry_step', or a restart of the harness) decides by the cache instead,
for the model it now has may be one that has never read the plan's
conversation, and a fork never shares its parent's cache.  With a warm
seed for it (`seed/warm-p') it forks through the seed as above: the
shared context is read from the cache.  Without one it forks the
supervisor directly and compacts the fork before its first turn
\(`harness-supervisor--compact-fork'), rather than send the whole
conversation uncached.  The worker the promise resolves with then has
`:context-cache' (`seed', `compacted' or `whole'); a first attempt and
a fresh step never do.

Every worker's context window is capped as a sub-agent's is
\(`harness-supervisor--context-limit'), and once the worker exists a
hint in its transcript says so (`harness-supervisor--limit-hint'): with
the limit fitted to the compacted conversation for a fork compacted."
  (let* ((session (harness-call 'session/get session-id))
         (model (plist-get step :model))
         (name (harness-supervisor--worker-name step))
         (fresh (equal (plist-get step :context) "fresh"))
         (inherited (harness-supervisor--inherited session-id (not fresh)))
         (limit (harness-supervisor--context-limit session-id (not fresh) inherited))
         (options (and limit (list :context-window-limit limit)))
         (seed-fork (lambda ()
                      (apply #'harness-call-async 'seed/fork session-id model
                             :node (plist-get plan :node) :call-id (plist-get plan :call-id)
                             :name name options)))
         (plain-fork (lambda ()
                       (apply #'harness-call-async 'session/fork session-id
                              :node (plist-get plan :node) :call-id (plist-get plan :call-id)
                              :kind 'subagent :model model :name name options))))
    (harness-then
     (cond
      (fresh
       (apply #'harness-call-async 'session/create
              :cwd (plist-get session :cwd) :worktree (plist-get session :worktree)
              :kind 'subagent :parent-id session-id :name name :model model
              :host (plist-get session :host)
              :permission-mode (plist-get session :permission-mode)
              :thinking (plist-get session :thinking)
              ;; Off too, not left to the setting.
              :non-interactive (if (harness-json-true-p (plist-get session :non-interactive)) t :false)
              :allowed-dirs (plist-get session :allowed-dirs)
              options))
      ((harness-supervisor--restarted-p step)
       (if (harness-supervisor--warm-seed session-id plan step)
           (harness-then (funcall seed-fork)
                         (lambda (worker) (append worker (list :context-cache 'seed))))
         (harness-then (funcall plain-fork)
                       (lambda (worker) (harness-supervisor--compact-fork session-id worker model)))))
      ((harness-supervisor--seeded-p plan step)
       (funcall seed-fork))
      (t
       (funcall plain-fork)))
     (lambda (worker)
       ;; A compacted fork's limit was fitted to what it holds now.
       (harness-supervisor--limit-hint
        worker
        (if (plist-member worker :context-limit) (plist-get worker :context-limit) limit)
        (not fresh)
        (if (plist-member worker :context-inherited) (plist-get worker :context-inherited) inherited))
       worker))))

(defconst harness-supervisor--fork-opening
  "You are now a worker for one step of the supervisor's plan, not the supervisor. You have the full tool set: you can read and change files and run commands. The supervisor's rules and reminders earlier in this conversation (read-only tools, ending every turn on a decision, submit_plan and retry_step) do not apply to you. Do this one step and nothing else; other workers do the other steps."
  "What a worker that forked the supervisor is told first.")

(defconst harness-supervisor--fresh-opening
  "You are a worker for one step of a plan that a supervisor made. You have the full tool set: you can read and change files and run commands. You start without the supervisor's conversation, so the step below holds what you need. Do this one step and nothing else; other workers do the other steps."
  "What a worker that starts fresh is told first.")

(defconst harness-supervisor--compacted-note
  "The conversation before this message was compacted into a summary; the session_history tool searches and reads the full conversation it replaced."
  "What a worker whose forked conversation was compacted is told after its opening.")

(defconst harness-supervisor--worker-closing
  "Do the step, then verify it. End with a short report of what you changed and how you checked it. Do not commit unless the step says so."
  "What a worker is told last.")

(defun harness-supervisor--previous-text (previous)
  "Return what a worker is told about the attempt before it, PREVIOUS, or nil.
PREVIOUS is the step's `:previous': the attempt, session and model of
the worker that ran before, and the error it ended with.  The worker is
pointed at that session, if it still exists, and told not to repeat
what failed."
  (when (and (consp previous) (stringp (plist-get previous :session)))
    (let ((sid (plist-get previous :session))
          (model (plist-get previous :model))
          (reason (harness-supervisor--cut (plist-get previous :error) harness-supervisor--report-limit)))
      (format "Attempt %s ran%s in session %s and ended: %s. %s"
              (or (plist-get previous :attempt) "?")
              (if (harness-string-blank-p model) "" (format " on %s" model))
              sid
              (if reason (string-remove-suffix "." reason) "no reason was recorded")
              (if (harness-call 'session/exists-p sid)
                  "You can read what it tried with the session_read tool on that session, and should not repeat what failed."
                "That session was deleted, so what it tried cannot be read; do not repeat what failed.")))))

(defun harness-supervisor--worker-text (plan step preamble &optional compacted)
  "Return the message that gives the worker of STEP of PLAN its job.
PREAMBLE is what `seed/fork' asks a fork's first message to open with,
or nil.  COMPACTED is non-nil for a fork whose inherited conversation
was compacted before this message, which the opening then says.  The
message is the opening, the step, the attempt before it when STEP
starts again (its `:previous'), what the steps it waits for reported
\(cut short), and the closing."
  (let ((before (delq nil (mapcar (lambda (id) (harness-supervisor--step plan id))
                                  (plist-get step :after))))
        (previous (harness-supervisor--previous-text (plist-get step :previous))))
    (concat
     (and (stringp preamble) (not (string-blank-p preamble)) (concat (string-trim preamble) "\n\n"))
     (if (equal (plist-get step :context) "fresh")
         harness-supervisor--fresh-opening
       (concat harness-supervisor--fork-opening
               (and compacted (concat " " harness-supervisor--compacted-note))))
     (format "\n\n## Step %s: %s\n\n%s\n" (plist-get step :id) (plist-get step :title)
             (plist-get step :prompt))
     (and previous (format "\n## The previous attempt\n\n%s\n" previous))
     (and before
          (concat "\n## What the steps before this one reported\n\n"
                  (mapconcat
                   (lambda (dep)
                     (format "### %s (%s)\n%s" (plist-get dep :id) (plist-get dep :title)
                             (let ((result (plist-get dep :result)))
                               (if (harness-string-blank-p result)
                                   "(it reported nothing)"
                                 (harness-truncate-middle result harness-supervisor--hand-over-limit)))))
                   before "\n\n")
                  "\n"))
     "\n" harness-supervisor--worker-closing)))

(defun harness-supervisor--last-reply (worker-id)
  "Return the last thing the worker WORKER-ID said, or nil."
  (when (and (stringp worker-id) (harness-call 'session/exists-p worker-id))
    (condition-case nil
        (let ((node (cl-find-if (lambda (n)
                                  (and (eq (plist-get n :kind) 'assistant)
                                       (equal (plist-get n :session) worker-id)
                                       (not (harness-string-blank-p (plist-get n :content)))))
                                (harness-call 'session/nodes worker-id) :from-end t)))
          (and node (string-trim (plist-get node :content))))
      (error nil))))

(defun harness-supervisor--step-key (session-id plan-id step-id)
  "Return the key of a step in `harness-supervisor--live'.
It is the step STEP-ID of plan PLAN-ID of session SESSION-ID."
  (list session-id plan-id step-id))

(defun harness-supervisor--previous-attempt (step)
  "Return what STEP, which ended, leaves of its attempt for the next, or nil.
That is (:attempt N :session SID :model MODEL :error TEXT) when it had
a worker, else nil.  MODEL is the one the worker ran on: its session's
now when it still exists, else the one `harness-supervisor--worker-made'
noted (`:worker-model'), since `retry_step' may have moved the step to
another model by the time it starts again."
  (let ((sid (plist-get step :session)))
    (when (stringp sid)
      (let ((model (or (ignore-errors
                         (and (harness-call 'session/exists-p sid)
                              (plist-get (harness-call 'session/get sid) :model)))
                       (plist-get step :worker-model)
                       (plist-get step :model)))
            (error-text (plist-get step :error)))
        (append (list :attempt (or (plist-get step :attempts) 1) :session sid)
                (and model (list :model model))
                (and (not (harness-string-blank-p error-text)) (list :error error-text)))))))

(defun harness-supervisor--start-step (session-id plan-id step-id)
  "Start a worker for step STEP-ID of plan PLAN-ID of session SESSION-ID.
The step is running from now on, which is what `agent/outstanding'
reports; the worker is made, and runs, in the background.  A step that
is not waiting to start, or to start again, is left alone: promises
that settled already call back at once, so a step can have been started
by the time its turn comes.

A step that starts again loses its session and its error, which belong
to the attempt before; when that attempt had a worker, the step keeps
it as `:previous' (`harness-supervisor--previous-attempt'), which the
new worker is told of (`harness-supervisor--worker-text')."
  (let* ((plan (harness-supervisor--plan (harness-supervisor--plans session-id) plan-id))
         (old (and plan (harness-supervisor--step plan step-id))))
    (when (and old (harness-supervisor--state-p old "pending" "failed" "interrupted" "cancelled"))
      (puthash (harness-supervisor--step-key session-id plan-id step-id) t harness-supervisor--live)
      (apply #'harness-supervisor--update-step session-id plan-id step-id
             :state "running" :attempts (1+ (or (plist-get old :attempts) 0))
             :session nil :result nil :error nil :worker-model nil
             (let ((previous (harness-supervisor--previous-attempt old)))
               (and previous (list :previous previous))))
      (let ((plan (harness-supervisor--plan (harness-supervisor--plans session-id) plan-id)))
        (harness-then
         (condition-case err
             (harness-supervisor--make-worker session-id plan (harness-supervisor--step plan step-id))
           (error (harness-rejected err)))
         (lambda (worker)
           (harness-supervisor--worker-made session-id plan-id step-id worker))
         (lambda (err)
           (harness-supervisor--step-ended
            session-id plan-id step-id "failed"
            (format "the worker could not be made: %s" (harness-error-message err)))))))))

(defun harness-supervisor--start-ready (session-id plan-id)
  "Start the steps of plan PLAN-ID of session SESSION-ID that are ready."
  (let ((plan (harness-supervisor--plan (harness-supervisor--plans session-id) plan-id)))
    (dolist (step (plist-get plan :steps))
      (when (harness-supervisor--ready-p plan step)
        (condition-case err
            (harness-supervisor--start-step session-id plan-id (plist-get step :id))
          (error (harness-supervisor--step-ended
                  session-id plan-id (plist-get step :id) "failed"
                  (format "the worker could not be started: %s" (harness-error-message err)))))))))

(defun harness-supervisor--compaction-words (kind)
  "Return in words what a compaction of KIND, a string, leaves of a conversation."
  (pcase kind
    ("brief" "a brief summary of it")
    ("summary" "a summary of it")
    ("transcript" "a note pointing at a transcript file of it")
    ("fresh" "nothing but a note pointing at it")
    (_ "a compacted copy of it")))

(defun harness-supervisor--restart-hint (session-id step worker)
  "Tell supervisor SESSION-ID how the worker of STEP got its context.
WORKER is its session, whose `:context-cache' says: `seed' (forked from
a warm shared context), `compacted' (no warm cache held the plan's
conversation, so the fork starts from a compaction of it) or `whole'
\(and was not compacted).  Only a fork step that starts again has one;
nothing is said for any other."
  (when-let* ((how (plist-get worker :context-cache)))
    (harness-supervisor--hint
     session-id
     (format "Step %s (attempt %s) on %s: %s" (plist-get step :id) (or (plist-get step :attempts) "?")
             (plist-get step :model)
             (pcase how
               ('seed "forked from the warm shared context")
               ('compacted
                (format "no warm prompt cache holds the plan's conversation, so its worker starts from %s rather than reading it all uncached"
                        (harness-supervisor--compaction-words (plist-get worker :compaction))))
               (_ "no warm prompt cache holds the plan's conversation and it was not compacted, so its worker reads it all uncached"))))))

(defun harness-supervisor--worker-made (session-id plan-id step-id worker)
  "Run the step STEP-ID of plan PLAN-ID of session SESSION-ID on its new WORKER.
WORKER is the session `seed/fork', `session/fork' or `session/create'
made, plus `:context-cache' and `:compaction' for a fork step that
starts again (see `harness-supervisor--make-worker'), whose supervisor
is told how its context stands (`harness-supervisor--restart-hint').
The step notes the model of the worker, which `retry_step' may change
before the step starts again.  The worker's turn is the step: when it
ends the step is done or it failed.  A step that was ended meanwhile, or
whose supervisor was deleted, does not run."
  (let ((key (harness-supervisor--step-key session-id plan-id step-id))
        (wid (plist-get worker :id)))
    (when (and (gethash key harness-supervisor--live) (harness-call 'session/exists-p session-id))
      (condition-case err
          (progn
            (puthash key wid harness-supervisor--live)
            (harness-supervisor--update-step session-id plan-id step-id
                                             :session wid :worker-model (plist-get worker :model))
            (let* ((plan (harness-supervisor--plan (harness-supervisor--plans session-id) plan-id))
                   (step (harness-supervisor--step plan step-id)))
              ;; A hint that cannot be added fails nothing.
              (condition-case hint-err
                  (harness-supervisor--restart-hint session-id step worker)
                (error (harness-log 'warn "supervisor: no hint for step %s: %s"
                                    step-id (harness-error-message hint-err))))
              ;; The worker shows in the supervisor's chat as the
              ;; spawn_agent call that would have started it.
              (harness-supervisor--open-call session-id wid step)
              (harness-then
               (harness-call-async 'agent/prompt wid
                                   (harness-supervisor--worker-text
                                    plan step (plist-get worker :preamble)
                                    (eq (plist-get worker :context-cache) 'compacted))
                                   (list :from (harness-sender-session (harness-call 'session/get session-id))))
               (lambda (result)
                 (harness-supervisor--turn-ended session-id plan-id step-id wid result))
               (lambda (err)
                 (harness-supervisor--turn-ended session-id plan-id step-id wid
                                                 (list :stop-reason 'error
                                                       :error (harness-error-message err)))))))
        ;; A step must not stay running for a worker that never got its job.
        (error (harness-supervisor--step-ended
                session-id plan-id step-id "failed"
                (format "the worker could not be given its step: %s" (harness-error-message err))))))))

(defun harness-supervisor--turn-ended (session-id plan-id step-id worker-id result)
  "Settle step STEP-ID of plan PLAN-ID of SESSION-ID: the turn of WORKER-ID ended.
RESULT is what `agent/prompt' answered.  A turn that ended on its own
or at its output limit did the step; any other end -- an error, a
cancel, a block -- failed it.  Nothing happens when the step is not
running on that worker any more."
  (let ((key (harness-supervisor--step-key session-id plan-id step-id)))
    (when (equal (gethash key harness-supervisor--live) worker-id)
      (let ((reason (let ((r (plist-get result :stop-reason))) (if (stringp r) (intern r) r)))
            (error-text (plist-get result :error)))
        (cond
         ((memq reason '(end-turn max-tokens))
          (harness-supervisor--step-done session-id plan-id step-id worker-id))
         (t
          (harness-supervisor--step-ended
           session-id plan-id step-id "failed"
           (if (eq reason 'cancelled)
               "the worker's turn was cancelled, most likely by the user"
             (format "the worker's turn ended with %s%s" (or reason "no reason")
                     (if (harness-string-blank-p error-text) "" (format ": %s" error-text)))))))))))

;;;; The workers' spawn_agent calls
;;
;; A worker shows in its supervisor's transcript as the spawn_agent call
;; that would have started it, as the merge queue shows its conflict
;; resolver in the session whose branch it merges.  The call is an
;; outside node (`harness-outside-node-p'): the supervisor's model never
;; gets it and nothing waits for its result.  Its `:meta' names the
;; worker as `:child-id', which the chat renders as a clickable session
;; line (`harness-chat--child-line'), and its input carries the step,
;; its tier, its model and the attempt.  The result joins the call when
;; the step ends -- done, failed, cancelled or interrupted by a restart.
;; A retried step gets a call of its own for its new worker.

(defun harness-supervisor--spawn-input (step)
  "Return the input of the spawn_agent call that shows the worker of STEP.
It names the worker as `spawn_agent' names a sub-agent, and says where
it runs: the step's model and tier, and the attempt of the step."
  (append (list :name (harness-supervisor--worker-name step)
                :prompt (plist-get step :prompt))
          (and (plist-get step :model) (list :model (plist-get step :model)))
          (and (plist-get step :tier) (list :tier (plist-get step :tier)))
          (and (plist-get step :attempts) (list :attempt (plist-get step :attempts)))
          (and (equal (plist-get step :context) "fork") (list :fork t))))

(defun harness-supervisor--open-call (session-id worker-id step)
  "Show WORKER-ID, the worker of STEP, in SESSION-ID's transcript.
That is the spawn_agent call that would have started the worker, an
outside node (`harness-outside-node-p'): the supervisor's model never
gets it and nothing waits for its result.  The `:meta' names the worker
as `:child-id', which the chat links to its session.  A call that
cannot be shown fails nothing.  Return the open call, or nil."
  (let* ((call-id (concat "sup-" (harness-short-id 10)))
         (input (harness-supervisor--spawn-input step)))
    (condition-case err
        (progn
          (harness-call 'session/append session-id
                        (list :kind 'tool-call :tool "spawn_agent" :call-id call-id :input input
                              :title (harness-tool-title "spawn_agent" input)
                              :meta (list :from (harness-supervisor--sender) :child-id worker-id)))
          (puthash worker-id (list :session session-id :call-id call-id :started (float-time))
                   harness-supervisor--spawns))
      (error (harness-log 'warn "supervisor: could not show the worker %s in %s: %s"
                          worker-id session-id (harness-error-message err))
             nil))))

(defun harness-supervisor--spawn-call-node (session-id worker-id)
  "Return the open spawn_agent call of WORKER-ID in SESSION-ID, or nil.
An open call is a tool-call node naming WORKER-ID as its `:meta'
`:child-id' that no tool-result node answers.  After a restart the hash
`harness-supervisor--spawns' is gone, but the call is in the transcript."
  (let ((nodes (ignore-errors (harness-call 'session/nodes session-id)))
        (answered (make-hash-table :test 'equal)))
    (dolist (node nodes)
      (when (eq (plist-get node :kind) 'tool-result)
        (puthash (plist-get node :call-id) t answered)))
    (cl-find-if (lambda (node)
                  (and (eq (plist-get node :kind) 'tool-call)
                       (equal (plist-get (plist-get node :meta) :child-id) worker-id)
                       (not (gethash (plist-get node :call-id) answered))))
                nodes :from-end t)))

(defun harness-supervisor--spawn-result (step state why)
  "Return what the spawn_agent call of STEP reports, now that it ended.
STATE is \"done\", \"failed\", \"cancelled\" or \"interrupted\"; WHY
says what stopped a step that did not get done.  The text is what the
worker reported -- its final reply for a step that is done, WHY and its
last reply otherwise -- then a footer naming the step, the state, the
model, the worker's session and, for a step that is done, what the
worker did and cost."
  (let* ((worker (plist-get step :session))
         (session (and (stringp worker) (harness-call 'session/exists-p worker)
                       (ignore-errors (harness-call 'session/get worker))))
         (reply (if (equal state "done")
                    (plist-get step :result)
                  (harness-supervisor--cut (harness-supervisor--last-reply worker)
                                           harness-supervisor--report-limit)))
         (why (harness-supervisor--cut why harness-supervisor--report-limit))
         (body (cond ((and why reply) (concat why "\n\n" reply))
                     (why why)
                     (reply reply)
                     (t "(the worker reported nothing)")))
         (calls (and session
                     (cl-count-if (lambda (node) (and (eq (plist-get node :kind) 'tool-call)
                                                      (equal (plist-get node :session) worker)))
                                  (ignore-errors (harness-call 'session/nodes worker))))))
    (format "%s\n\n[step %s %s on %s, session %s%s]"
            body
            (harness-supervisor--step-name step)
            state
            (or (plist-get step :worker-model) (plist-get step :model) "?")
            (or worker "?")
            (if (and (equal state "done") (numberp calls))
                (format ", %d tool calls, cost %s" calls (harness-format-spend (plist-get session :usage)))
              ""))))

(defun harness-supervisor--close-call (session-id step state why)
  "Record the result of the spawn_agent call shown for STEP of SESSION-ID.
STATE is \"done\", \"failed\", \"cancelled\" or \"interrupted\"; WHY
says what stopped a step that did not get done.  The call is found in
`harness-supervisor--spawns', or in the transcript after a restart
\(`harness-supervisor--spawn-call-node'): a call the restart already
answered, or one that was never shown, gets nothing.  Return the new
result node, or nil."
  (let* ((worker (plist-get step :session))
         (call (gethash worker harness-supervisor--spawns))
         (open (and worker (harness-call 'session/exists-p session-id)
                    (or call (harness-supervisor--spawn-call-node session-id worker)))))
    (when open
      (when call (remhash worker harness-supervisor--spawns))
      (condition-case err
          (harness-call 'session/append session-id
                        (list :kind 'tool-result :call-id (plist-get open :call-id)
                              :output (harness-supervisor--spawn-result step state why)
                              :is-error (not (equal state "done"))
                              :meta (append (list :from (harness-supervisor--sender) :child-id worker)
                                            (and call (list :duration
                                                            (- (float-time) (plist-get call :started)))))))
        (error (harness-log 'warn "supervisor: could not record the result of the worker %s: %s"
                            worker (harness-error-message err))
               nil)))))

;;;; The plan engine: what the supervisor is told

(defun harness-supervisor--task-p (session-id)
  "Non-nil when session SESSION-ID is a task's."
  (and (harness-method-exists-p 'task/for-session)
       (condition-case nil (and (harness-call 'task/for-session session-id) t) (error nil))))

(defun harness-supervisor--deliver (session-id text &optional queue)
  "Send TEXT to session SESSION-ID as a message of the harness's supervisor.
An idle session starts a turn on it and a running turn is steered; with
QUEUE the message waits for the session's next message instead."
  (harness-catch
   (harness-call-async 'agent/prompt session-id text
                       (append (list :from (harness-supervisor--sender)) (and queue (list :queue t))))
   (lambda (err)
     (harness-log 'warn "supervisor: reporting to %s failed: %s" session-id (harness-error-message err)))))

(defun harness-supervisor--send (session-id text)
  "Report TEXT to the supervising session SESSION-ID.
It is a message of the harness's: an idle session starts a turn on it,
a running turn is steered.  While the turn that submitted a plan is
still ending (`harness-supervisor--ending') the report is held, since
that turn would not take it, and goes out when the turn is over."
  (when (harness-call 'session/exists-p session-id)
    (if (and (gethash session-id harness-supervisor--ending)
             (harness-method-exists-p 'agent/running)
             (harness-call 'agent/running session-id))
        (puthash session-id (append (gethash session-id harness-supervisor--held) (list text))
                 harness-supervisor--held)
      (harness-supervisor--deliver session-id text))))

(defun harness-supervisor--hint (session-id text)
  "Add the hint TEXT to session SESSION-ID's transcript, if it still exists."
  (when (harness-call 'session/exists-p session-id)
    (harness-call 'session/hint session-id text)))

(defun harness-supervisor--step-name (step)
  "Return STEP as a model reads it: its id and its title."
  (format "%s (%s)" (plist-get step :id) (plist-get step :title)))

(defun harness-supervisor--cut (text limit)
  "Return TEXT cut to LIMIT characters, or nil when it says nothing."
  (and (stringp text) (not (string-blank-p text)) (harness-truncate-middle (string-trim text) limit)))

(defun harness-supervisor--failure-text (session-id plan step)
  "Return the report to SESSION-ID that STEP of PLAN did not get done.
It names the step, its tier and model, what went wrong, the steps held
on it, and the ways on."
  (let* ((id (plist-get step :id))
         (state (plist-get step :state))
         (held (cl-remove-if-not (lambda (s) (harness-supervisor--state-p s "pending"))
                                 (harness-supervisor--dependants plan id)))
         (running (cl-remove id (mapcar (lambda (s) (plist-get s :id))
                                        (harness-supervisor--running-steps
                                         (harness-supervisor--plans session-id)))
                            :test #'equal))
         (reply (harness-supervisor--cut (harness-supervisor--last-reply (plist-get step :session))
                                         harness-supervisor--report-limit)))
    (concat
     (format "Supervisor report: step %s %s.\n" (harness-supervisor--step-name step)
             (pcase state
               ("interrupted" "was interrupted")
               ("cancelled" "was cancelled")
               (_ "failed")))
     (format "It ran on tier %s, model %s (attempt %d).\n"
             (plist-get step :tier) (plist-get step :model) (or (plist-get step :attempts) 1))
     (and (plist-get step :error)
          (format "Why: %s.\n" (harness-supervisor--cut (plist-get step :error)
                                                        harness-supervisor--report-limit)))
     (and reply (format "The worker's last reply:\n%s\n" reply))
     (and (plist-get step :session)
          (format "Its worker is session %s: session_read shows what it did.\n" (plist-get step :session)))
     (if held
         (format "Held on it, pending until it is done: %s.\n"
                 (mapconcat #'harness-supervisor--step-name held ", "))
       "No step waits for it.\n")
     (and running (format "Still running: %s.\n" (string-join running ", ")))
     (format "Plan %s. Decide: retry_step %s (on a higher tier if the model was not up to it), a new plan with submit_plan, or ask the user with ask_user."
             (plist-get plan :id) id))))

(defun harness-supervisor--finished-p (plan)
  "Non-nil when nothing is left to do in PLAN: every step is done or superseded.
No step is pending or running, and none failed, was interrupted or
cancelled.  A step a later plan superseded never runs."
  (let ((steps (plist-get plan :steps)))
    (and steps
         (cl-every (lambda (step) (harness-supervisor--state-p step "done" "superseded")) steps)
         (cl-some (lambda (step) (harness-supervisor--state-p step "done")) steps))))

(defun harness-supervisor--finished-text (session-id plan)
  "Return the report to SESSION-ID that PLAN is finished.
Every step is done, or was superseded by a later plan and never ran."
  (let* ((steps (plist-get plan :steps))
         (superseded (cl-remove-if-not (lambda (step) (harness-supervisor--state-p step "superseded")) steps)))
    (concat
     (format "Supervisor report: plan %s%s finished. %s\n"
             (plist-get plan :id)
             (if (plist-get plan :title) (format " (%s)" (plist-get plan :title)) "")
             (cond
              (superseded
               (format "%d of its %d steps are done; a later plan superseded %s, which never ran."
                       (- (length steps) (length superseded)) (length steps)
                       (mapconcat (lambda (step) (plist-get step :id)) superseded ", ")))
              ((cdr steps) (format "All %d steps are done." (length steps)))
              (t "Its one step is done.")))
     (mapconcat
      (lambda (step)
        (if (harness-supervisor--state-p step "superseded")
            (format "- %s: superseded by a later plan, it never ran" (harness-supervisor--step-name step))
          (format "- %s on %s%s: %s" (harness-supervisor--step-name step) (plist-get step :model)
                  (if (plist-get step :session) (format ", session %s" (plist-get step :session)) "")
                  (or (harness-supervisor--cut (plist-get step :result) harness-supervisor--report-limit)
                      "(it reported nothing)"))))
      steps "\n")
     "\n\nCheck the work now, with the read-only tools: read the files the steps changed, and use session_read on a worker when its report is not enough. Then decide: a follow-up plan with submit_plan if something is missing or wrong, "
     (if (harness-supervisor--task-p session-id)
         "hand_in once the work is checked and committed, or no_plan_needed with your reply to the user."
       "or no_plan_needed with your reply to the user."))))

(defun harness-supervisor--step-done (session-id plan-id step-id worker-id)
  "Record that step STEP-ID of plan PLAN-ID of SESSION-ID is done.
WORKER-ID's turn is over.  The supervisor gets a hint, and the steps
that waited for this one start.  When nothing is left to do in its plan
the supervisor is told the plan finished (`harness-supervisor--finished-p'):
the steps a later plan superseded count as nothing to do, so that a plan
the supervisor replaced while one of its steps ran still reports when
that step ends."
  (remhash (harness-supervisor--step-key session-id plan-id step-id) harness-supervisor--live)
  (when (harness-call 'session/exists-p session-id)
    (let ((step (harness-supervisor--update-step
                 session-id plan-id step-id
                 :state "done" :error nil
                 :result (harness-supervisor--cut (harness-supervisor--last-reply worker-id)
                                                  harness-supervisor--result-limit))))
      (when step
        ;; The call's result joins the call before the hints and reports.
        (harness-supervisor--close-call session-id step "done" nil)
        (harness-supervisor--hint session-id (format "Step %s done on %s" step-id (plist-get step :model)))
        (harness-supervisor--start-ready session-id plan-id)
        (let ((plan (harness-supervisor--plan (harness-supervisor--plans session-id) plan-id)))
          (when (and plan (harness-supervisor--finished-p plan))
            (harness-supervisor--send session-id (harness-supervisor--finished-text session-id plan))))))))

(defun harness-supervisor--step-ended (session-id plan-id step-id state error)
  "Record that step STEP-ID of plan PLAN-ID of SESSION-ID ended, for ERROR.
STATE is \"failed\", \"interrupted\" or \"cancelled\".  The supervisor
is told in a message of its own, which names the steps now held on it."
  (remhash (harness-supervisor--step-key session-id plan-id step-id) harness-supervisor--live)
  (when (harness-call 'session/exists-p session-id)
    (let ((step (harness-supervisor--update-step session-id plan-id step-id :state state :error error)))
      (when step
        ;; The call's result joins the call before the report.
        (harness-supervisor--close-call session-id step state error)
        (harness-supervisor--send
         session-id
         (harness-supervisor--failure-text
          session-id (harness-supervisor--plan (harness-supervisor--plans session-id) plan-id) step))))))

;;;; The plan engine: submit_plan

(defun harness-supervisor--call-node (session-id call-id)
  "Return the id of the node of tool call CALL-ID in SESSION-ID's transcript.
That is the head of the session at the time of the call unless the model
made more calls in the same message; without the call, the head."
  (let ((call (and call-id
                   (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-call)
                                                (equal (plist-get n :call-id) call-id)))
                               (harness-call 'session/nodes session-id) :from-end t))))
    (or (plist-get call :id) (plist-get (harness-call 'session/get session-id) :head))))

(defun harness-supervisor--make-plan (input steps node call-id)
  "Return the plan that INPUT, a `submit_plan' call, makes of STEPS.
NODE and CALL-ID are the fork point.  Every step starts out pending."
  (let ((title (harness-supervisor--text (plist-get input :title))))
    (harness-supervisor--with
     (list :id (concat "p-" (harness-short-id 6)))
     :title (and (not (harness-string-blank-p title)) title)
     :summary (harness-supervisor--text (plist-get input :summary))
     :node node :call-id call-id :created (float-time)
     :steps (mapcar (lambda (step) (harness-supervisor--with step :state "pending" :attempts 0)) steps))))

(defun harness-supervisor--step-line (step)
  "Return the line of the answer to `submit_plan' that tells where STEP runs."
  (format "- %s → %s (%s%s%s)" (plist-get step :id) (plist-get step :model) (plist-get step :tier)
          (if (equal (plist-get step :context) "fresh") ", fresh" "")
          (if (plist-get step :after) (format ", after %s" (string-join (plist-get step :after) " ")) "")))

(defun harness-supervisor--submit-plan (input ctx)
  "Handler of the submit_plan tool: record INPUT's plan and start its workers.
CTX is the call's context.  A plan with problems is refused as a whole,
every problem named.  Otherwise the plan is recorded on the session --
the steps of its earlier plans that have not started are superseded --
shown like the `plan' tool shows one, and its ready steps start.  The
answer ends the turn: the harness reports back."
  (let* ((sid (plist-get ctx :session-id))
         (session (harness-call 'session/get sid))
         (read (harness-supervisor--read-plan input)))
    (if (cdr read)
        (harness-supervisor--problems-result "submit_plan" (cdr read))
      (let* ((fallback nil)
             (steps (mapcar (lambda (step)
                              (let ((model (harness-supervisor--tier-model session (plist-get step :tier))))
                                (when (cdr model) (push step fallback))
                                (harness-supervisor--with step :model (car model))))
                            (car read)))
             ;; The call's own node, taken before the plan and its hint join the transcript.
             (plan (harness-supervisor--make-plan input steps
                                                  (harness-supervisor--call-node sid (plist-get ctx :call-id))
                                                  (plist-get ctx :call-id)))
             (n (length steps)))
        (harness-supervisor--save-plans
         sid (append (mapcar #'harness-supervisor--supersede (harness-supervisor--plans sid)) (list plan)))
        (harness-call 'session/set-plan sid (plist-get plan :summary))
        (harness-call 'session/append sid (list :kind 'plan :content (plist-get plan :summary)
                                                :title (plist-get plan :title)
                                                :meta (list :plan-id (plist-get plan :id))))
        (harness-call 'session/hint sid (format "Plan submitted: %d step%s" n (if (= n 1) "" "s")))
        (harness-supervisor--fallback-hint session (nreverse fallback))
        (when (and (harness-method-exists-p 'agent/running) (harness-call 'agent/running sid))
          (puthash sid t harness-supervisor--ending))
        (harness-supervisor--start-ready sid (plist-get plan :id))
        (harness-tool-ok
         (concat (format "Plan %s submitted: %d step%s, started where they are ready.\n"
                         (plist-get plan :id) n (if (= n 1) "" "s"))
                 (mapconcat #'harness-supervisor--step-line steps "\n")
                 "\nThis ends your turn. The harness reports a failed step, and the finished plan, to you in a new message: do not wait or poll.")
         :end-turn t)))))

(harness-define-tool "submit_plan"
  :label "Submit plan"
  :description "Submit the plan for the work and start its workers. Call it once you know enough to plan; it is your decision for the turn whenever the work changes files, however small. The plan is a list of steps, each a self-contained job for a worker on a cheaper model, which has the full tool set that you lack. summary is the plan in markdown, shown to the user: the approach, the steps, and how the result is verified. Each step has an id (short, unique), a title, a prompt (self-contained: what to do, which files, how to verify, what to report; say when the step must commit), a tier with a one-line reason (mundane for mechanical, well-specified edits; standard for ordinary work; hard for subtle design or debugging), a context (fork, the default: the worker sees this conversation up to now; or fresh: it starts empty, so the prompt must hold everything), and after: the ids of the steps that must be done first. Steps with no order between them run at once in the same working tree, so give them different files. A worker also gets the reports of the steps it follows. The harness starts the steps that are ready, tells you in a new message when a step fails and when the plan has finished, and ends this turn now. A problem with the plan (an id used twice, an after that names no step, a cycle, an unknown tier or context, a blank prompt) is returned as an error and nothing starts: fix it and call again."
  :schema '(:type "object"
            :properties (:title (:type "string" :description "Optional short title for the plan.")
                         :summary (:type "string" :description "The plan in markdown, shown to the user.")
                         :steps (:type "array"
                                 :description "The steps, at least one."
                                 :items (:type "object"
                                         :properties (:id (:type "string" :description "A short id, unique in the plan.")
                                                      :title (:type "string" :description "What the step does, in a few words.")
                                                      :prompt (:type "string" :description "Self-contained instructions for the worker: what to do, which files, how to verify, what to report.")
                                                      :tier (:type "string" :enum ("mundane" "standard" "hard")
                                                             :description "How hard the step is, which decides the worker's model.")
                                                      :reason (:type "string" :description "Why this tier, in one line.")
                                                      :context (:type "string" :enum ("fork" "fresh")
                                                                :description "fork (default): the worker sees this conversation. fresh: it starts empty.")
                                                      :after (:type "array" :items (:type "string")
                                                              :description "Ids of the steps of this plan that must be done before this one starts."))
                                         :required ("id" "title" "prompt" "tier" "reason"))))
            :required ("summary" "steps"))
  :kind 'meta
  :subject (lambda (input)
             (let ((title (plist-get input :title)))
               (if (harness-string-blank-p title)
                   (harness-first-line (plist-get input :summary) 60)
                 (harness-first-line title 60))))
  :handler #'harness-supervisor--submit-plan)

;;;; The plan engine: retry_step

(defun harness-supervisor--retry-step (input ctx)
  "Handler of the retry_step tool: run a step of INPUT again on a new worker.
CTX is the call's context.  Only a step that failed, was interrupted or
was cancelled can be retried.  A new tier moves the step to that tier's
model; notes in INPUT are added to its prompt.  The steps held on it
start once it is done.  The turn goes on: several steps can be retried
in one message.

The new worker is told of the attempt before it: the step keeps it as
`:previous' (`harness-supervisor--start-step'), so the worker can read
what it tried.  A fork step's worker does not read the plan's
conversation uncached on a model that never saw it: the cache decides
\(`harness-supervisor--make-worker').  It forks through a warm shared
context when a seed holds one, else it is compacted before it starts,
and a hint tells the supervisor which."
  (let* ((sid (plist-get ctx :session-id))
         (step-id (harness-supervisor--text (plist-get input :step)))
         (plan-id (harness-supervisor--text (plist-get input :plan)))
         (tier (let ((tier (harness-supervisor--text (plist-get input :tier)))) (and tier (downcase tier))))
         (reason (harness-supervisor--text (plist-get input :reason)))
         (notes (harness-supervisor--text (plist-get input :prompt)))
         (plans (harness-supervisor--plans sid))
         (found (and (not (harness-string-blank-p step-id))
                     (harness-supervisor--find-step plans step-id (and (not (harness-string-blank-p plan-id)) plan-id))))
         (plan (car found))
         (step (cdr found))
         (problems
          (delq nil
                (list (and (harness-string-blank-p step-id) "step is empty: name the step to run again")
                      (and (harness-string-blank-p reason)
                           "reason is empty: say in a line why the step runs again")
                      (and (not (harness-string-blank-p tier))
                           (not (member tier harness-supervisor--tier-names))
                           (format "%S is no tier: use mundane, standard or hard" tier))
                      (and (not (harness-string-blank-p step-id)) (not found)
                           (if (harness-string-blank-p plan-id)
                               (format "no step %s in any plan of this session%s" step-id
                                       (harness-supervisor--known-steps plans))
                             (format "no step %s in plan %s%s" step-id plan-id
                                     (harness-supervisor--known-steps plans))))
                      (and step (not (member (plist-get step :state) harness-supervisor--retryable-states))
                           (format "step %s is %s%s: only a failed, interrupted or cancelled step can be retried"
                                   step-id (plist-get step :state)
                                   (let ((waits (and (harness-supervisor--state-p step "pending")
                                                     (cl-remove-if
                                                      (lambda (id) (harness-supervisor--state-p
                                                                    (harness-supervisor--step plan id) "done"))
                                                      (plist-get step :after)))))
                                     (if waits (format ", waiting for %s" (string-join waits ", ")) ""))))))))
    (if problems
        (harness-supervisor--problems-result "retry_step" problems)
      (let* ((plan-id (plist-get plan :id))
             (session (harness-call 'session/get sid))
             (attempt (1+ (or (plist-get step :attempts) 0)))
             (new-tier (and (not (harness-string-blank-p tier)) (not (equal tier (plist-get step :tier))) tier))
             (model (and new-tier (harness-supervisor--tier-model session new-tier)))
             (now (apply #'harness-supervisor--update-step
                         sid plan-id step-id
                         :prompt (if (harness-string-blank-p notes)
                                     (plist-get step :prompt)
                                   (format "%s\n\nNotes for attempt %d: %s" (plist-get step :prompt) attempt notes))
                         ;; A step that moves to another tier has its reason: why this one.
                         (and new-tier (list :tier new-tier :model (car model) :reason reason)))))
        (when (cdr model)
          (harness-supervisor--fallback-hint session (list now)))
        (harness-supervisor--hint sid (format "Retrying step %s on %s (attempt %d): %s"
                                              step-id (plist-get now :model) attempt reason))
        (harness-supervisor--start-step sid plan-id step-id)
        (harness-tool-ok
         (format "Step %s of plan %s runs again on %s (tier %s, attempt %d). The steps held on it start once it is done."
                 step-id plan-id (plist-get now :model) (plist-get now :tier) attempt))))))

(defun harness-supervisor--known-steps (plans)
  "Return a text naming the steps of the latest of PLANS, for an error."
  (let ((plan (car (last plans))))
    (if plan
        (format ". The latest plan, %s, has: %s" (plist-get plan :id)
                (mapconcat (lambda (s) (format "%s (%s)" (plist-get s :id) (plist-get s :state)))
                           (plist-get plan :steps) ", "))
      ". This session has no plan")))

(harness-define-tool "retry_step"
  :label "Retry step"
  :description "Run a step of a submitted plan again on a new worker: a step that failed, was interrupted by a restart, or was cancelled. step is its id. plan is the id of its plan and defaults to the latest plan that has the step. tier moves the step to another tier, usually a higher one, when its model was not up to it. reason says in a line why. prompt adds notes to the step's prompt for the new worker, such as what went wrong the first time. The steps held on the step start once it is done. It does not end your turn, so you can retry several steps in one message."
  :schema '(:type "object"
            :properties (:step (:type "string" :description "Id of the step to run again.")
                         :plan (:type "string" :description "Id of the plan (default: the latest plan that has the step).")
                         :tier (:type "string" :enum ("mundane" "standard" "hard")
                                :description "A new tier for the step, to escalate it.")
                         :reason (:type "string" :description "Why the step runs again, in one line.")
                         :prompt (:type "string" :description "Notes added to the step's prompt, such as what went wrong."))
            :required ("step" "reason"))
  :kind 'meta
  :subject (lambda (input)
             (format "%s%s" (or (harness-supervisor--text (plist-get input :step)) "?")
                     (if (harness-string-blank-p (plist-get input :tier)) ""
                       (format " on %s" (plist-get input :tier)))))
  :handler #'harness-supervisor--retry-step)

;;;; The plan engine: work outside the turn

(defun harness-supervisor--outstanding-line (session-id)
  "Return what the plans of session SESSION-ID have outstanding, as a line, or nil.
That is the steps running and the pending steps that can still start.
A step held behind one that ended without being done does not count:
the supervisor was told, and has to decide.  Reports waiting for the
end of a turn do."
  (let ((running 0) (waiting 0))
    (dolist (plan (harness-supervisor--plans session-id))
      (dolist (step (plist-get plan :steps))
        (cond ((harness-supervisor--state-p step "running") (cl-incf running))
              ((harness-supervisor--waiting-p plan step) (cl-incf waiting)))))
    (let ((parts (delq nil (list (and (> running 0)
                                      (format "%d step%s running" running (if (= running 1) "" "s")))
                                 (and (> waiting 0)
                                      (if (> running 0)
                                          (format "%d waiting" waiting)
                                        (format "%d step%s waiting" waiting (if (= waiting 1) "" "s"))))
                                 (and (gethash session-id harness-supervisor--held)
                                      "a report to deliver")))))
      (and parts (concat "Supervisor plan: " (string-join parts ", "))))))

(defun harness-supervisor--outstanding (value session-id)
  "Add what the plans of SESSION-ID have outstanding to VALUE.
An `agent/outstanding' filter: the tasks module keeps the task of a
session active, waiting, while this says anything.  VALUE is what the
handlers before it said; it stays as it is when the session has
nothing running or waiting."
  (let ((line (and (harness-call 'session/exists-p session-id)
                   (harness-supervisor--outstanding-line session-id))))
    (cond ((null line) value)
          ((and (stringp value) (not (string-blank-p value))) (concat value "; " line))
          (t line))))

(defun harness-supervisor--flush (session-id reason)
  "Send the reports held for SESSION-ID, whose turn ended with REASON.
They go as one message.  After a turn that ended any other way than
`end-turn' they are queued instead, for the user's next message: a turn
the user stopped is not one to start another on."
  (let ((reports (gethash session-id harness-supervisor--held)))
    (remhash session-id harness-supervisor--held)
    (when (and reports (harness-call 'session/exists-p session-id))
      (harness-supervisor--deliver session-id (string-join reports "\n\n") (not (eq reason 'end-turn))))))

(defun harness-supervisor--on-turn-ended (session-id reason)
  "Let the reports held for SESSION-ID go out: its turn ended with REASON.
A subscriber of `agent/turn-ended'.  They go soon, after the other
subscribers saw the turn end: the tasks module asks for what is
outstanding, which the held reports are part of."
  (remhash session-id harness-supervisor--ending)
  (when (gethash session-id harness-supervisor--held)
    (harness-run-soon #'harness-supervisor--flush session-id reason)))

(defun harness-supervisor--forget-plans (session-id)
  "Stop what the plans of the deleted session SESSION-ID started.
Its running workers are cancelled; nothing is written to the session,
which is going."
  (remhash session-id harness-supervisor--ending)
  (remhash session-id harness-supervisor--held)
  (let (mine spawns)
    (maphash (lambda (key worker) (when (equal (car key) session-id) (push (cons key worker) mine)))
             harness-supervisor--live)
    (maphash (lambda (worker call) (when (equal (plist-get call :session) session-id) (push worker spawns)))
             harness-supervisor--spawns)
    (dolist (worker spawns) (remhash worker harness-supervisor--spawns))
    (dolist (entry mine)
      (remhash (car entry) harness-supervisor--live)
      (when (and (stringp (cdr entry)) (harness-method-exists-p 'agent/cancel)
                 (harness-call 'session/exists-p (cdr entry)))
        (condition-case err
            (harness-call 'agent/cancel (cdr entry))
          (error (harness-log 'warn "supervisor: cancelling worker %s failed: %S" (cdr entry) err)))))))

(defun harness-supervisor--worker-deleted (worker-id)
  "Cancel the step that the worker WORKER-ID, a deleted session, was running."
  (let (key)
    (maphash (lambda (k worker) (when (equal worker worker-id) (setq key k))) harness-supervisor--live)
    (when key
      (harness-supervisor--step-ended (nth 0 key) (nth 1 key) (nth 2 key) "cancelled"
                                      "the worker's session was deleted"))))

(defun harness-supervisor--recover-session (session-id)
  "Interrupt the steps of session SESSION-ID that no worker runs any more.
A step stored as running that this process has no worker for belongs to
a harness that stopped.  Each is reported as a failure is: to the
session of a task as a message, so the task carries on, and to any other
queued, to go with the user's next message instead of starting an
expensive turn they did not ask for."
  (let ((interrupted nil))
    (dolist (plan (harness-supervisor--plans session-id))
      (dolist (step (plist-get plan :steps))
        (when (and (harness-supervisor--state-p step "running")
                   (not (gethash (harness-supervisor--step-key session-id (plist-get plan :id)
                                                               (plist-get step :id))
                                 harness-supervisor--live)))
          (push (cons (plist-get plan :id) (plist-get step :id)) interrupted))))
    (setq interrupted (nreverse interrupted))
    (dolist (ids interrupted)
      (harness-supervisor--update-step session-id (car ids) (cdr ids)
                                       :state "interrupted"
                                       :error "the harness stopped while the worker was running"))
    (let ((task (harness-supervisor--task-p session-id)))
      (dolist (ids interrupted)
        (let* ((plan (harness-supervisor--plan (harness-supervisor--plans session-id) (car ids)))
               (step (harness-supervisor--step plan (cdr ids))))
          ;; The call's result joins the call before the report.
          (harness-supervisor--close-call session-id step "interrupted" (plist-get step :error))
          (harness-supervisor--deliver session-id (harness-supervisor--failure-text session-id plan step)
                                       (not task))))
      ;; A task carries on by itself, so a step whose turn came just as
      ;; the harness stopped starts now; `agent/outstanding' counts it as
      ;; waiting, and the task would wait for it forever otherwise.
      (when task
        (dolist (plan (harness-supervisor--plans session-id))
          (harness-supervisor--start-ready session-id (plist-get plan :id)))))
    interrupted))

(defun harness-supervisor--recover ()
  "Interrupt the steps that a stopped harness left running, in every session.
It runs once the modules are up (see `harness-supervisor--start')."
  (dolist (session (harness-call 'session/list))
    (when (plist-get (plist-get session :ext) harness-supervisor--plans-key)
      (condition-case err
          (harness-supervisor--recover-session (plist-get session :id))
        (error (harness-log 'warn "supervisor: recovering the plans of %s failed: %S"
                            (plist-get session :id) err))))))

;;;; The system prompt

(defun harness-supervisor-prompt-section ()
  "Return the Supervisor mode section of a supervising session's system prompt.
It is the same text on every call, since the system prompt is part of the
prompt cache: nothing in it names a session, a directory or a count."
  (concat
   "## Supervisor mode\n"
   "You plan and coordinate; workers on cheaper models make the changes. You cannot change files yourself, and bash is read-only and offline.\n"
   "- Investigate just enough to plan, then call submit_plan. Each step is self-contained, with a tier (mundane, standard or hard) and a one-line reason for it.\n"
   "- A step's context is fork (the default: the worker sees this conversation, and forks onto one model share one cache seed) or fresh (a self-contained job that needs none of it).\n"
   "- `after` sets the order of the steps. Steps that run in parallel must touch different files: they share the working tree.\n"
   "- The harness reports a failed step, and the finished plan, back to you. After a failure call retry_step (it escalates the tier) or submit a new plan.\n"
   "- Every turn ends on a decision: "
   (string-join harness-supervisor-decision-tools ", ")
   ". Use submit_plan when the work changes files, and no_plan_needed when you answered a question, there is nothing to do, or the plan is still running.\n"
   "- In a task, the last step commits (git add -A && git commit). Once the plan has finished and you checked the result, call hand_in; review feedback means a new plan to fix it."))

(defun harness-supervisor--system-prompt (prompt session)
  "Give a supervising SESSION the Supervisor mode section in place of Planning.
An `agent/system-prompt' filter that runs after the others, with the
PROMPT they made.  Without a Planning section to replace the new one is
appended.  Other sessions keep PROMPT."
  (if (not (harness-supervisor--session-p session))
      prompt
    (let* ((section (harness-supervisor-prompt-section))
           (planning (and (boundp 'harness-tools-agent-planning-section)
                          (stringp harness-tools-agent-planning-section)
                          (not (string-empty-p harness-tools-agent-planning-section))
                          harness-tools-agent-planning-section))
           (start (and planning (string-search planning prompt))))
      (if start
          (concat (substring prompt 0 start) section (substring prompt (+ start (length planning))))
        (concat prompt "\n\n" section "\n")))))

;;;; Module

(defun harness-supervisor--init ()
  "Hook the module into the bus (idempotent)."
  (harness-add-filter 'agent/tools #'harness-supervisor--tools 90)
  (harness-add-filter 'permission/decide #'harness-supervisor--gate 8)
  ;; After the mode and the rules (20) and the tasks' write-up gate (25),
  ;; before the judge (30): it keeps the judge off the plans.
  (harness-add-filter 'permission/decide #'harness-supervisor--approval 28)
  ;; Late, so the options of the handlers before it cannot undo its own.
  (harness-add-filter 'tools/sandbox-options #'harness-supervisor--sandbox-options 90)
  (harness-add-filter 'agent/stop #'harness-supervisor--stop)
  ;; After the sections the other modules add, before the seed freezes the prompt.
  (harness-add-filter 'agent/system-prompt #'harness-supervisor--system-prompt 900)
  (harness-on 'session/created #'harness-supervisor--on-created)
  (harness-on 'task/changed #'harness-supervisor--on-task-changed)
  (harness-on 'agent/turn-started #'harness-supervisor--on-turn-started)
  (harness-on 'agent/tool-call #'harness-supervisor--on-tool-call)
  (harness-on 'tools/finished #'harness-supervisor--on-tool-finished)
  (harness-on 'session/deleted #'harness-supervisor--on-session-deleted)
  (harness-on 'agent/turn-ended #'harness-supervisor--on-turn-ended)
  (harness-add-filter 'agent/outstanding #'harness-supervisor--outstanding))

(defun harness-supervisor--start ()
  "Start the module: hook it into the bus, then recover from a restart.
Steps stored as running belong to a harness that stopped, unless this
process runs their workers; once every module is up they are interrupted
\(`harness-supervisor--recover'), as the tasks module picks up what it
left once they are (`harness-tasks--pick-up').  A reload hooks in again
\(`harness-supervisor--init') but starts nothing: its workers run on."
  (harness-supervisor--init)
  (harness-run-soon #'harness-supervisor--recover))

(defun harness-supervisor--shutdown ()
  "Take the module off the bus.  Sessions keep their setting."
  (harness-remove-filter 'agent/tools #'harness-supervisor--tools)
  (harness-remove-filter 'permission/decide #'harness-supervisor--gate)
  (harness-remove-filter 'permission/decide #'harness-supervisor--approval)
  (harness-remove-filter 'tools/sandbox-options #'harness-supervisor--sandbox-options)
  (harness-remove-filter 'agent/stop #'harness-supervisor--stop)
  (harness-remove-filter 'agent/system-prompt #'harness-supervisor--system-prompt)
  (harness-off (cons 'session/created #'harness-supervisor--on-created))
  (harness-off (cons 'task/changed #'harness-supervisor--on-task-changed))
  (harness-off (cons 'agent/turn-started #'harness-supervisor--on-turn-started))
  (harness-off (cons 'agent/tool-call #'harness-supervisor--on-tool-call))
  (harness-off (cons 'tools/finished #'harness-supervisor--on-tool-finished))
  (harness-off (cons 'session/deleted #'harness-supervisor--on-session-deleted))
  (harness-off (cons 'agent/turn-ended #'harness-supervisor--on-turn-ended))
  (harness-remove-filter 'agent/outstanding #'harness-supervisor--outstanding))

;; A reload does not initialise a running module again: hook in what
;; this version brings now.
(when (harness-module-ready-p 'supervisor)
  (harness-supervisor--init))

(harness-define-module 'supervisor
  :doc "Supervisor mode: sessions that plan and delegate, enforced by the harness."
  :requires '(session agent tools)
  :init #'harness-supervisor--start
  :shutdown #'harness-supervisor--shutdown)

(provide 'harness-supervisor)
;;; harness-supervisor.el ends here
