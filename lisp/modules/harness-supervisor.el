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
;; The plan engine itself -- the `submit_plan' and `retry_step' tools and
;; the workers on cheaper models -- is not here.  Its tools are named in
;; `harness-supervisor-tools' and `harness-supervisor-decision-tools'
;; already, so the gates above apply to them from the day they exist; the
;; models of its workers come from `harness-supervisor-tiers', and their
;; context window from `harness-tools-agent-context-limit'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defvar harness-tasks--merge-session-name)
(defvar harness-tools-agent-planning-section)
(defvar harness-perms-dir-tool)

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
the mode were off.  The supervisor's own `no_plan_needed' only records
a decision, so what would ask the user is allowed."
  (funcall next
           (condition-case err
               (cond
                ((harness-supervisor--refusal request))
                ((and (equal (plist-get request :tool) "no_plan_needed")
                      (eq (plist-get decision :behavior) 'ask)
                      (harness-supervisor--session-p (plist-get request :session)))
                 (list :behavior 'allow :reason "no_plan_needed only records a decision"))
                (t decision))
             (error
              (harness-log 'error "supervisor: checking a call of %s failed, so it is denied: %S"
                           (plist-get request :tool) err)
              (harness-supervisor--denial "this call could not be checked, so it is not made")))))

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

(defun harness-supervisor--merge-session-p (session)
  "Non-nil when SESSION, a plist, is the one task branches merge into.
The tasks module makes it for itself and names it
`harness-tasks--merge-session-name'; it is no one's conversation."
  (and (boundp 'harness-tasks--merge-session-name)
       (stringp (plist-get session :name))
       (equal (plist-get session :name) (symbol-value 'harness-tasks--merge-session-name))))

(defun harness-supervisor--set-ext (id key value)
  "Set KEY of session ID's `:ext' to VALUE (nil removes it), with no hint.
A hint would start the transcript of a session that has no message yet."
  (harness-call 'session/set-ext id key value))

(defun harness-supervisor--update-payload (payload id)
  "Make PAYLOAD, a session plist, carry the `:ext' that session ID holds now.
`session/create' hands the plist it announced with to `session/created'
and then announces it again and returns it, so without this the last
`session/changed' of a new session, and the plist its maker gets, would
lack the setting made here, and the header would not show it until the
session changes again."
  (let ((cell (plist-member payload :ext)))
    (when cell
      (setcar (cdr cell) (plist-get (harness-call 'session/get id) :ext)))))

(defun harness-supervisor--on-created (id session)
  "Give the new session ID, whose plist is SESSION, its supervisor setting.
A subscriber of `session/created'.  A top-level session takes
`harness-supervisor' for its directory, and a fork its parent's value
when the parent has one.  The merge session of the tasks module, a
sub-agent, a side conversation and any other kind are never governed.
A setting its maker gave it in `:ext' stays."
  (condition-case err
      (unless (plist-member (plist-get session :ext) :supervisor)
        (let* ((kind (harness-supervisor--kind session))
               (parent-id (plist-get session :parent-id))
               (value (cond
                       ((and (eq kind 'main) (null parent-id)
                             (not (harness-supervisor--merge-session-p session)))
                        (if (harness-supervisor--setting (plist-get session :cwd)) t :false))
                       ((and (eq kind 'fork) parent-id (harness-call 'session/exists-p parent-id))
                        (harness-supervisor--value (harness-call 'session/get parent-id))))))
          (when value
            (harness-supervisor--set-ext id :supervisor value)
            (harness-supervisor--update-payload session id))))
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
  "Forget everything about the deleted session SESSION-ID."
  (harness-supervisor--on-turn-started session-id)
  (remhash session-id harness-supervisor--configured))

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
that was denied, decided nothing, so the turn is still owed one."
  (when (and (harness-json-true-p (plist-get result :is-error))
             (gethash session-id harness-supervisor--decisions))
    (setf (gethash session-id harness-supervisor--decisions)
          (cl-remove (plist-get call :id) (gethash session-id harness-supervisor--decisions)
                     :test #'equal))))

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
  (harness-on 'session/deleted #'harness-supervisor--on-session-deleted))

(defun harness-supervisor--shutdown ()
  "Take the module off the bus.  Sessions keep their setting."
  (harness-remove-filter 'agent/tools #'harness-supervisor--tools)
  (harness-remove-filter 'permission/decide #'harness-supervisor--gate)
  (harness-remove-filter 'tools/sandbox-options #'harness-supervisor--sandbox-options)
  (harness-remove-filter 'agent/stop #'harness-supervisor--stop)
  (harness-remove-filter 'agent/system-prompt #'harness-supervisor--system-prompt)
  (harness-off (cons 'session/created #'harness-supervisor--on-created))
  (harness-off (cons 'task/changed #'harness-supervisor--on-task-changed))
  (harness-off (cons 'agent/turn-started #'harness-supervisor--on-turn-started))
  (harness-off (cons 'agent/tool-call #'harness-supervisor--on-tool-call))
  (harness-off (cons 'tools/finished #'harness-supervisor--on-tool-finished))
  (harness-off (cons 'session/deleted #'harness-supervisor--on-session-deleted)))

;; A reload does not initialise a running module again: hook in what
;; this version brings now.
(when (harness-module-ready-p 'supervisor)
  (harness-supervisor--init))

(harness-define-module 'supervisor
  :doc "Supervisor mode: sessions that plan and delegate, enforced by the harness."
  :requires '(session agent tools)
  :init #'harness-supervisor--init
  :shutdown #'harness-supervisor--shutdown)

(provide 'harness-supervisor)
;;; harness-supervisor.el ends here
