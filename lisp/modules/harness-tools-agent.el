;;; harness-tools-agent.el --- Sub-agents: the spawn_agent tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; `spawn_agent' creates a child session (fresh or forked, optionally
;; in its own git worktree, optionally at a priority of its own) and
;; runs one prompt in it.  The call returns as soon as the child
;; starts, so a spawn never blocks the conversation and several
;; sub-agents can run at once; the child's answer arrives later in a
;; message of its own, and one that still has work going on (a wait it
;; registered, a sub-agent of its own) is reported when that work is
;; over.  Several spawn_agent calls made in one step run at once.  A
;; sub-agent works on a deliberately shorter context window
;; (`harness-subagent-context-limit'); the limit a child gets is
;; `harness-tools-agent-context-limit', which other modules that start
;; sub-agents use too.  The cap is never silent: a hint at the start of
;; the child's transcript says it
;; (`harness-tools-agent-context-limit-hint').  Without a priority of
;; its own the child works at its parent's (`harness-priority-session').
;;
;; The module also adds a Planning section to the system prompt that
;; explains forks, sub-agents, worktrees and the merge queue, so plans
;; can use them.  It names the plan tool (tools-plan) and todo_write
;; (tools-todo), modules of their own, as are ask_user (tools-question)
;; and session_info (tools-session-info).
;;
;; Nothing here waits: every long operation returns a promise.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-priority)
(require 'harness-tools)

;; The module requires `session' at runtime (see `harness-define-module'
;; at the end of the file): the levels a model offers come from it.
(declare-function harness-session--model-levels "harness-session" (model))

;;;; Planning

(defconst harness-tools-agent-planning-section
  "## Planning
When a task is complex (several files, several steps, anything you cannot verify in one go), produce a plan with the `plan` tool before changing anything. The plan states the approach, the concrete steps, how the result will be verified, and how the work will be split.

Split work with the mechanisms this harness provides:
- Session forks share the cached context of the current session, so they are much cheaper than a fresh sub-agent that has to gather all the context again. Prefer a fork (spawn_agent with fork=true) when the sub-task needs what you already know.
- spawn_agent starts a fresh sub-agent (fork=false) when the sub-task is self-contained and does not need the current context; it gets its own session, and the call never blocks: it returns as soon as the child starts, and the child's answer arrives later in a message of its own. Start independent sub-tasks that way, together, and carry on while they run instead of waiting for one after another.
- Several spawn_agent calls made in the same step run at once, each child starting its own turn without blocking the others.
- Each sub-agent can work in its own git worktree (worktree=true), so independent steps run in parallel worktrees without touching each other's files.
- A merge queue brings a worktree's branch back into the parent session's working directory, one child at a time; conflicts are handed to the child to resolve. Plan independent steps as parallel worktrees that merge back, and dependent steps sequentially in this session.
Keep the plan short and concrete; update the todo list (todo_write) as steps complete."
  "Text appended to the system prompt by the tools-agent module.")

(defun harness-tools-agent--system-prompt (prompt _session)
  "Append the Planning section to PROMPT (the `agent/system-prompt' filter)."
  (concat prompt "\n\n" harness-tools-agent-planning-section "\n"))

;;;; Sub-agents

(defvar harness-tools-agent--children (make-hash-table :test 'equal)
  "Child session id -> what a spawn_agent call knows of a running child.
A plist (:parent PARENT-ID :name NAME :worktree PATH :branch BRANCH
:result RESULT :unwatch STOP :stopped WHY :adopted ADOPTED).  A child's
call has always returned, since it started; RESULT is what the child's
first turn ended with, nil while it runs.  The entry stays until the
child is done with everything it has going on, so a parent counts it as
work it still runs (`harness-tools-agent--outstanding') and a child
that registered a wait is not reported as finished when its turn merely
ended; STOP, when there is one, stops the note under the child's
spawn_agent call (`harness-tools-agent--watch-child').  WHY is there
once the parent's outstanding work was stopped and took the child's
with it (`harness-tools-agent--stop-outstanding'): the reason, or t
without one.  A child so stopped is reported as cancelled, whatever its
last turn said.  ADOPTED is non-nil for a child this harness took back
from one that stopped before reporting it (`harness-tools-agent--adopt'):
whichever of its turns ends next reports it.

Each entry is kept in the child's record too, as `:report-to' in its
`ext' (`harness-tools-agent--remember'), so that it outlives the
harness process.")

(defun harness-tools-agent--remember (cid entry)
  "Keep in the record of child CID whom it reports to, from ENTRY.
That is `:report-to' in its `ext': (:parent ID :name NAME :worktree
PATH :branch BRANCH :stopped WHY), the keys with a value.  Nothing
fails for it: a child that cannot be remembered still runs."
  (condition-case err
      (when (harness-call 'session/exists-p cid)
        (harness-call 'session/set-ext cid :report-to
                      (cl-loop for key in '(:parent :name :worktree :branch :stopped)
                               for value = (plist-get entry key)
                               when (or (stringp value) (eq value t))
                               append (list key value))))
    (error (harness-log 'warn "tools-agent: remembering the parent of sub-agent %s failed: %s"
                        cid (harness-error-message err)))))

(defun harness-tools-agent--adopt ()
  "Take back the sub-agents a stopped harness had not reported yet.
Each spawn_agent child keeps whom it reports to in its record
\(`harness-tools-agent--remember') until it is reported.  A harness
that stops meanwhile forgets the children it ran, and their parents
would wait for reports that never come; the next start takes them
back, marked `:adopted': the next turn of each that ends reports it, as
its first one would have (see `harness-tools-agent--on-turn-ended'),
and one left with nothing to run is reported by
`harness-tools-agent-settle-adopted'.  A child whose parent is gone
is forgotten."
  (dolist (s (harness-call 'session/list (list :kind 'subagent)))
    (let* ((cid (plist-get s :id))
           (link (plist-get (plist-get s :ext) :report-to))
           (parent (and (consp link) (plist-get link :parent))))
      (when (and link (not (gethash cid harness-tools-agent--children)))
        (if (and (stringp parent) (harness-call 'session/exists-p parent))
            (progn
              (puthash cid (list :parent parent
                                 :name (or (plist-get link :name) (plist-get s :name))
                                 :worktree (plist-get link :worktree) :branch (plist-get link :branch)
                                 :result nil :stopped (plist-get link :stopped) :unwatch nil :adopted t)
                       harness-tools-agent--children)
              (harness-log 'info "tools-agent: sub-agent %s reports to %s when it is done, after the restart"
                           (harness-tools-agent--short-id cid) (harness-tools-agent--short-id parent)))
          (harness-call 'session/set-ext cid :report-to nil))))))

(defun harness-tools-agent-settle-adopted (&optional reasons)
  "Report the sub-agents taken back after a restart that have nothing to run.
A child taken back (`harness-tools-agent--adopt') reports when its next
turn ends; one that has no turn to run -- nothing carried it on,
nothing it waits on is left -- would leave its parent waiting for good.
So each such child is reported now: as cancelled when it was being
stopped, else with its reason in REASONS, an alist (ID . REASON) of the
sessions whose turns did not end by themselves (`interrupted' for a
turn the restart cut short, `cancelled' for one cancelled), else as
finished.  The resilience module calls this once it has carried on
what it carries on; without it, the tools-agent module calls it
itself, a little after it starts.  Return the ids reported."
  (let (reported)
    (dolist (child (let (all)
                     (maphash (lambda (cid entry) (when (plist-get entry :adopted) (push (cons cid entry) all)))
                              harness-tools-agent--children)
                     all))
      (let ((cid (car child)))
        (unless (or (harness-call 'agent/running cid)
                    (harness-tools-agent--child-busy-p cid))
          (condition-case err
              (progn
                (harness-tools-agent--settle-child
                 cid (cond ((plist-get (cdr child) :stopped) 'cancelled)
                           ((cdr (assoc cid reasons)))
                           (t 'end-turn)))
                (push cid reported))
            (error (harness-log 'warn "tools-agent: reporting sub-agent %s after the restart failed: %s"
                                cid (harness-error-message err)))))))
    reported))

(defun harness-tools-agent--short-id (id)
  "Return the first eight characters of session ID."
  (substring id 0 (min 8 (length id))))

(defun harness-tools-agent--child-name (cid entry)
  "Return how reports name child CID, from ENTRY: its name, or its short id."
  (let ((name (plist-get entry :name)))
    (if (and (stringp name) (not (harness-string-blank-p name)))
        name
      (harness-tools-agent--short-id cid))))

(defun harness-tools-agent--child-entries (session-id)
  "Return (ID . ENTRY) for the sub-agents of SESSION-ID still running.
They come in the order they were spawned.  ENTRY is the child's entry
in `harness-tools-agent--children'."
  (let (entries)
    (maphash (lambda (cid entry)
               (when (equal (plist-get entry :parent) session-id)
                 (push (cons cid entry) entries)))
             harness-tools-agent--children)
    (nreverse entries)))

(defun harness-tools-agent--running-children (session-id)
  "Return the names of the sub-agents of SESSION-ID still running."
  (mapcar (lambda (child) (harness-tools-agent--child-name (car child) (cdr child)))
          (harness-tools-agent--child-entries session-id)))

(defun harness-tools-agent--add-names (value names verb)
  "Return VALUE with a text appended saying the sub-agents NAMES VERB.
That is \"Sub-agent A running\" or \"Sub-agents A, B stopped\", joined to
what VALUE says already by \"; \", as the handlers of `agent/outstanding'
and `agent/stop-outstanding' add to the text before them."
  (let ((text (format "Sub-agent%s %s %s" (if (cdr names) "s" "") (string-join names ", ") verb)))
    (if (and (stringp value) (not (harness-string-blank-p value)))
        (concat value "; " text)
      text)))

(defun harness-tools-agent--outstanding (value session-id)
  "Add the sub-agents of SESSION-ID that still run to VALUE.
The `agent/outstanding' filter: a task whose session's turn ended stays
active, waiting, while this says something, as it does while a
supervisor's steps run."
  (let ((names (harness-tools-agent--running-children session-id)))
    (if (null names)
        value
      (harness-tools-agent--add-names value names "running"))))

(defun harness-tools-agent--child-busy-p (cid)
  "Non-nil when child CID has work going on but its turn.
A sub-agent that registered a wait (`session_wait') or started a
sub-agent of its own has ended its turn while it works; it is not done
until nothing is outstanding for it any more (see `agent/outstanding')."
  (and (harness-call 'session/exists-p cid)
       (harness-method-exists-p 'agent/outstanding)
       (harness-call 'agent/outstanding cid)))

(defun harness-tools-agent--settle-child (cid &optional reason)
  "Report child CID to its parent once nothing of it runs on but its turn.
REASON is how the turn that just ended ended, for a child whose own
result is not known (a later turn's, which carries no error text).  A
child that is still busy is left for the turn that ends its wait, or its
sub-agent's report.  A child its parent's outstanding work stopped
\(`harness-tools-agent--stop-outstanding') is reported as cancelled
whatever its last turn said: it did not finish."
  (let ((entry (gethash cid harness-tools-agent--children)))
    (when (and entry (not (harness-tools-agent--child-busy-p cid)))
      (harness-tools-agent--forget-child cid)
      (harness-tools-agent--report-child (plist-get entry :parent) cid entry
                                         (cond ((plist-get entry :stopped)
                                                (list :stop-reason 'cancelled))
                                               ((plist-get entry :result))
                                               (t (list :stop-reason reason)))))))

(defun harness-tools-agent--child-result (cid result)
  "Note RESULT, how the first turn of child CID ended, then settle it.
The entry keeps RESULT for the report; a later turn's end carries none
of it, `agent/turn-ended' holding only the reason."
  (let ((entry (gethash cid harness-tools-agent--children)))
    (when entry
      (plist-put entry :result result)
      (harness-tools-agent--settle-child cid))))

(defun harness-tools-agent--on-turn-ended (session-id reason)
  "Settle the sub-agent SESSION-ID whose turn ended with REASON.
A subscriber of `agent/turn-ended'.  The first turn of a child is
settled by its `agent/prompt' result (`harness-tools-agent--child-result'),
which holds a failure's error too; this settles the turns that follow,
such as the wake-up turn of a wait the child registered."
  (let ((entry (gethash session-id harness-tools-agent--children)))
    ;; A child taken back after a restart has no first turn to wait for.
    (when (and entry (or (plist-get entry :result) (plist-get entry :adopted)))
      (harness-tools-agent--settle-child session-id reason))))

(defun harness-tools-agent--watch-child (cid note)
  "Have the note of child CID show under its spawn_agent call.
NOTE is the call's note function.  Return the function that stops the
watching, or nil when the call has no note function."
  (when (and note (harness-method-exists-p 'session/exists-p))
    (harness-tools-watch-session cid (lambda (text) (funcall note text)) (list :recap t))))

(defun harness-tools-agent--forget-child (cid)
  "Stop watching child CID and forget what its call knew of it.
Its record forgets whom it reports to too (`harness-tools-agent--remember')."
  (when-let* ((entry (gethash cid harness-tools-agent--children)))
    (when-let* ((stop (plist-get entry :unwatch)))
      (funcall stop))
    (remhash cid harness-tools-agent--children)
    (condition-case err
        (when (harness-call 'session/exists-p cid)
          (harness-call 'session/set-ext cid :report-to nil))
      (error (harness-log 'warn "tools-agent: forgetting the parent of sub-agent %s failed: %s"
                          cid (harness-error-message err))))))

(defun harness-tools-agent--child-summary (child-id)
  "Return the final text of CHILD-ID plus a footer with its tool calls and cost."
  (let* ((child (harness-call 'session/get child-id))
         (own (cl-remove-if-not (lambda (n) (equal (plist-get n :session) child-id))
                                (harness-call 'session/nodes child-id)))
         (last-assistant (cl-find-if (lambda (n) (eq (plist-get n :kind) 'assistant)) (reverse own)))
         (calls (cl-count-if (lambda (n) (eq (plist-get n :kind) 'tool-call)) own)))
    (format "%s\n\n[sub-agent session: %s, %d tool calls, cost %s]"
            (or (plist-get last-assistant :content) "(the sub-agent produced no answer)")
            child-id calls (harness-format-spend (plist-get child :usage)))))

(defun harness-tools-agent--child-report-text (cid entry result)
  "Return the report of child CID, of ENTRY, ended RESULT.
ENTRY is the child's entry in `harness-tools-agent--children'.  RESULT
is what `agent/prompt' answered for the child's first turn, or just
\(:stop-reason REASON) for a later one: the text names the child, says
how its turn ended, holds its summary, and says where it worked when it
had a worktree.  A child the outstanding work of its parent stopped,
for a reason (`:stopped' in its entry), says it in brackets after how
its turn ended."
  (let* ((name (harness-tools-agent--child-name cid entry))
         (reason (plist-get result :stop-reason))
         (error (plist-get result :error))
         (why (let ((stopped (plist-get entry :stopped)))
                (and (stringp stopped) (not (harness-string-blank-p stopped)) stopped)))
         (summary (condition-case err
                      (harness-tools-agent--child-summary cid)
                    (error (format "(its session is gone: %s)" (harness-error-message err)))))
         (summary (if (> (length summary) harness-tools-max-output-chars)
                      (concat (harness-truncate-middle summary harness-tools-max-output-chars)
                              (format "\n\n(Its answer was long; session_read on %s shows the rest.)" cid))
                    summary))
         (state (concat
                 (pcase reason
                   ('end-turn "finished")
                   ('cancelled "stopped: its turn was cancelled")
                   ('max-tokens "stopped: it hit its output limit")
                   ('blocked "stopped: its turn was blocked")
                   ('interrupted "stopped: the harness restarted during its turn, which was not resumed")
                   ('error (format "stopped: it failed%s"
                                   (if (and (stringp error) (not (harness-string-blank-p error)))
                                       (format ": %s" error)
                                     "")))
                   (_ (format "stopped: its turn ended (%s)" (or reason "no reason"))))
                 (and why (format " (%s)" why))))
         (worktree (plist-get entry :worktree))
         (branch (plist-get entry :branch)))
    (concat
     (format "Sub-agent report: %s (session %s) %s.\n\n%s" name cid state summary)
     (when worktree
       (format (concat "\n\nIt worked in worktree %s%s; "
                       (if (harness-method-exists-p 'merge/enqueue)
                           (concat "its branch merges back into this session's working directory "
                                   "through the merge queue, one branch at a time.")
                         (concat "this harness runs no merge queue (the merge module), so the branch "
                                 "stays there until you merge it yourself.")))
               (abbreviate-file-name worktree)
               (if (and (stringp branch) (not (harness-string-blank-p branch)))
                   (format " on branch %s" branch)
                 ""))))))

(defun harness-tools-agent--report-child (parent-id cid entry result)
  "Tell PARENT-ID that its sub-agent CID, of ENTRY, ended with RESULT.
The report is a message of the harness's: an idle parent starts a turn
on it and a running one is steered, as a supervisor step's report
arrives."
  (when (harness-call 'session/exists-p parent-id)
    (harness-catch
     (harness-call-async 'agent/prompt parent-id (harness-tools-agent--child-report-text cid entry result)
                         (list :from (harness-sender-system "sub-agent")))
     (lambda (err)
       (harness-log 'warn "tools-agent: reporting sub-agent %s to session %s failed: %s"
                    (harness-tools-agent--short-id cid) parent-id (harness-error-message err))))))

(defun harness-tools-agent--mark-stopped (cid reason)
  "Note in the entry of sub-agent CID that it was stopped, for REASON.
REASON is the text the report of CID says (`:stopped' in its entry),
or t when there is none.  A child that has been reported meanwhile has no
entry, and none is made."
  (when-let* ((entry (gethash cid harness-tools-agent--children)))
    (puthash cid (plist-put entry :stopped reason) harness-tools-agent--children)
    (harness-tools-agent--remember cid entry)))

(defun harness-tools-agent--stop-child (cid reason)
  "Stop sub-agent CID, as its parent's outstanding work is stopped for REASON.
Work of its own it has outside its turn -- its sub-agents -- is stopped
first (`agent/stop-outstanding' for CID), which may wake it with the
reports of what stopped.  Then the turn it runs, or the one those
reports started, is cancelled; once that has ended and nothing of it is
outstanding, the child is reported to its parent as a cancelled
sub-agent is (`harness-tools-agent--settle-child').  An idle child is
reported at once unless work of its own is still stopping.  It is
marked as stopped before its turn can end, so that its report says why.
A child with nothing running and nothing to stop is left as it is:
one that is done with everything, or waits for something a stop leaves
alone, as `session_wait' does.  Nothing is merged: a child in a worktree
is reported as any cancelled sub-agent is, which says where it worked,
and its branch and worktree stay.  Return non-nil when the child, or
work of its own, was stopped; nil for a child already being stopped,
whose cancelled turn has not ended yet."
  (let* ((entry (gethash cid harness-tools-agent--children))
         (running (harness-call 'agent/running cid))
         (note (and (stringp reason) (not (harness-string-blank-p reason)) (string-trim reason))))
    (when (and entry (not (and running (plist-get entry :stopped))))
      (when running
        (harness-tools-agent--mark-stopped cid (or note t)))
      (let* ((below (and (harness-method-exists-p 'agent/stop-outstanding)
                         (harness-call 'agent/stop-outstanding cid reason)))
             (running (or running (harness-call 'agent/running cid))))
        (when (or running below)
          (harness-log 'info "tools-agent: stopping sub-agent %s%s"
                       (harness-tools-agent--short-id cid) (if note (format ": %s" note) ""))
          (harness-tools-agent--mark-stopped cid (or note t))
          (if running
              (harness-call 'agent/cancel cid)
            (harness-tools-agent--settle-child cid 'cancelled))
          t)))))

(defun harness-tools-agent--stop-outstanding (value session-id reason)
  "Stop the sub-agents SESSION-ID still runs, and name them in VALUE.
The `agent/stop-outstanding' filter: REASON, or nil, says why the work
SESSION-ID has outside its turn is stopped -- its task was pre-empted,
say -- and the reports of the sub-agents say it too.  Each sub-agent it
spawned that has not been reported yet (`harness-tools-agent--children')
is stopped (`harness-tools-agent--stop-child'): the turn it runs is
cancelled, and so is work of its own, so that nothing it started is left
running.  Their reports reach SESSION-ID as those of cancelled
sub-agents do, messages of the harness's.  The workers of a supervisor's
plan are no sub-agents here, the supervisor stops those, and a
sub-agent that only waits is left alone.  VALUE is what the handlers
before this one stopped: \"Sub-agent A stopped\" or \"Sub-agents A, B
stopped\" follows it, and it stays as it is when no sub-agent was
stopped."
  (let (names)
    (dolist (child (harness-tools-agent--child-entries session-id))
      (when (condition-case err
                (harness-tools-agent--stop-child (car child) reason)
              (error (harness-log 'warn "tools-agent: stopping sub-agent %s of %s failed: %s"
                                  (harness-tools-agent--short-id (car child)) session-id
                                  (harness-error-message err))
                     nil))
        (push (harness-tools-agent--child-name (car child) (cdr child)) names)))
    (if names
        (harness-tools-agent--add-names value (nreverse names) "stopped")
      value)))

(defcustom harness-subagent-context-limit 256000
  "Most tokens of context a sub-agent adds of its own, or nil for no cap.
A sub-agent does one job, so it works on a deliberately shorter
context window than the session that started it: it compacts once its
own work has filled this many tokens, which keeps its calls cheap and
its reports short.  A fresh sub-agent starts empty, so its window is
this limit.  A fork starts with the context it inherits from the
session it was forked from and gets this many tokens on top of that,
so it does not compact at once (see
`harness-tools-agent-context-limit').  Neither window goes above the
limit of the session that started it, and neither is above its model's
own window.  With nil sub-agents use the whole window like any other
session.  A sub-agent's transcript says it is capped, in a hint (see
`harness-tools-agent-context-limit-hint')."
  :type '(choice (const :tag "No cap" nil)
                 (integer :tag "Tokens of context"))
  :safe (lambda (v) (or (null v) (and (integerp v) (> v 0))))
  :group 'harness)

(defun harness-tools-agent-inherited-context (parent-id)
  "Return the tokens of context a fork of session PARENT-ID starts with.
That is the parent's `:usage' `:context' plus its `:last-output' (what
the conversation holds about), 0 when the parent has not run yet or
there is no such session."
  (let* ((parent (and parent-id (harness-call 'session/exists-p parent-id)
                      (harness-call 'session/get parent-id)))
         (usage (plist-get parent :usage)))
    (+ (let ((n (plist-get usage :context))) (if (numberp n) n 0))
       (let ((n (plist-get usage :last-output))) (if (numberp n) n 0)))))

(defun harness-tools-agent-context-limit (parent-id fork &optional inherited)
  "Return the `:context-window-limit' for a sub-agent of session PARENT-ID.
It is nil when `harness-subagent-context-limit' is nil: no cap.
Otherwise a fresh sub-agent (FORK nil or `:false') gets the cap itself,
and a fork the context it inherits plus the cap, so that it does not
compact at once.  What a fork inherits is INHERITED, a number of tokens,
when the caller knows better -- a fork compacted before its first turn
starts with far less than its parent holds -- and otherwise
`harness-tools-agent-inherited-context'.  Either way the limit is never
above the parent's own `:context-window-limit', when it has one, so
sub-agents of sub-agents do not grow.  `spawn_agent' and the
supervisor's workers pass the result to `session/create' or
`session/fork', and say it in the sub-agent's transcript with
`harness-tools-agent-context-limit-hint'."
  (let ((cap harness-subagent-context-limit))
    (when (and (integerp cap) (> cap 0))
      (let* ((parent (and parent-id (harness-call 'session/exists-p parent-id)
                          (harness-call 'session/get parent-id)))
             (inherited (cond ((not (harness-json-true-p fork)) 0)
                              ((and (numberp inherited) (>= inherited 0)) inherited)
                              (t (harness-tools-agent-inherited-context parent-id))))
             (limit (round (+ cap inherited)))
             (own (plist-get parent :context-window-limit)))
        (if (and (numberp own) (> own 0))
            (min limit (round own))
          limit)))))

(defun harness-tools-agent--tokens (n)
  "Format N tokens as `harness-format-tokens' does, but \"90k\" for \"90.0k\"."
  (harness-format-tokens-compact n))

(defun harness-tools-agent-context-limit-hint (limit fork &optional inherited)
  "Return the text of a hint saying a sub-agent's window is capped at LIMIT.
It is nil when LIMIT is nil: no cap, nothing to say.  LIMIT is what
`harness-tools-agent-context-limit' returned, FORK says whether the
sub-agent is a fork, and INHERITED is the tokens of context it starts
with (`harness-tools-agent-inherited-context'), none when nil.  A fork's
window is those plus `harness-subagent-context-limit' on top, and the
text says so; when the limit of the session that started the sub-agent
holds it lower, the text says that instead.  The text is for the
sub-agent's transcript, so that the cap is never silent:
`harness-tools-agent--create-child' adds it."
  (when (numberp limit)
    (let* ((cap (and (integerp harness-subagent-context-limit) harness-subagent-context-limit))
           (start (if (and (harness-json-true-p fork) (numberp inherited) (> inherited 0))
                      (round inherited)
                    0))
           (wanted (and cap (round (+ cap start))))
           (capped (format "Context window capped at %s tokens" (harness-tools-agent--tokens limit)))
           (as-a-sub-agent "as a sub-agent's is (harness-subagent-context-limit)"))
      (cond
       ((and wanted (> start 0) (= limit wanted))
        (format "%s: the %s it starts with plus %s of its own, %s"
                capped (harness-tools-agent--tokens start) (harness-tools-agent--tokens cap)
                as-a-sub-agent))
       ((and wanted (< limit wanted))
        (format "%s, %s, and no higher than the limit of the session that started it"
                capped as-a-sub-agent))
       (t (format "%s, %s" capped as-a-sub-agent))))))

(defun harness-tools-agent--child-priority (input)
  "Return the priority INPUT gives a new child session, or nil.
That is the `priority' option, read the way the priority plugin reads a
level (a name no level has is refused here, before any child is made:
`spawn_agent' calls this before the worktree).  nil, the default, is no
priority of its own, so the child works at what it inherits -- its
parent's priority, and the default when the chain up has none (see
`harness-priority-session')."
  (let ((value (plist-get input :priority)))
    (and (not (harness-string-blank-p value))
         (harness-priority-read value))))

(defun harness-tools-agent--child-thinking (model level)
  "Return the thinking level a sub-agent on MODEL is asked to run at.
LEVEL is what the spawn_agent call asked for, or nil: nil leaves the
child the level it would have had otherwise, which comes back as nil.
A LEVEL MODEL does not offer signals an error, rather than starting a
child that thinks at a level its model cannot act on: the provider
catalogue says which levels MODEL has (`harness-session--model-levels',
as `harness-session--btw-thinking' and the session UI keep to), and the
message names them, so the caller can ask for one of those or leave the
level out."
  (when level
    (let ((levels (harness-session--model-levels model)))
      (unless (and (stringp level) (member level levels))
        (signal 'harness-error
                (list (format (concat "Model %s does not offer the thinking level %s; it offers %s. "
                                      "Leave :thinking out to use this session's level.")
                              (or model "?")
                              level
                              (if levels (string-join levels ", ") "none"))))))
    level))

(defun harness-tools-agent--create-child (parent input child-id cwd worktree call-id priority)
  "Return a promise of the child session plist for PARENT from INPUT.
CHILD-ID is the id to use, CWD its working directory and WORKTREE
its worktree path (or nil).  CALL-ID is the spawn_agent call's: a fork
copies it among the parent's calls still running, and answers it with
a result saying the fork is the sub-agent it started.  PRIORITY, a
level or nil, is the child session's own priority (see
`harness-tools-agent--child-priority'): it orders the queues the
child's work waits in, as the parent's does its own (see the priority
plugin).  The child's context is capped as
`harness-tools-agent-context-limit' says, and a hint in its transcript
says so (`harness-tools-agent-context-limit-hint'), added once it
exists.  INPUT's `:thinking', when given, is checked against the
child's model (`harness-tools-agent--child-thinking'); a fresh child
without one starts at its parent's level, and a fork inherits it."
  (let* ((fork (harness-json-true-p (plist-get input :fork)))
         (name (plist-get input :name))
         (model (or (plist-get input :model) (plist-get parent :model)))
         (thinking (harness-tools-agent--child-thinking model (plist-get input :thinking)))
         ;; Only a level the call asked for goes to a fork: one it did not
         ;; ask for is the fork's own default, its parent's level.
         (thinking-option (and thinking (list :thinking thinking)))
         (limit (harness-tools-agent-context-limit (plist-get parent :id) fork))
         (hint (harness-tools-agent-context-limit-hint
                limit fork (and fork (harness-tools-agent-inherited-context (plist-get parent :id)))))
         ;; Without a cap a fork keeps its parent's limit, as it always did.
         (limit-option (and limit (list :context-window-limit limit)))
         (created
          (if fork
              (harness-as-promise
               (apply #'harness-call 'session/fork (plist-get parent :id)
                      :id child-id :kind 'subagent :name name :model model
                      :cwd cwd :worktree worktree :call-id call-id
                      (append limit-option thinking-option)))
            (harness-as-promise
             (apply #'harness-call 'session/create
                    :id child-id :cwd cwd :worktree worktree :kind 'subagent
                    :parent-id (plist-get parent :id) :name name :model model
                    :host (plist-get parent :host)
                    :permission-mode (plist-get parent :permission-mode)
                    ;; Its parent's level, unless the call asked for its own.
                    :thinking (or thinking (plist-get parent :thinking))
                    ;; Off too, not left to the setting.
                    :non-interactive (if (harness-json-true-p (plist-get parent :non-interactive)) t :false)
                    limit-option)))))
    (if (and (null hint) (null priority))
        created
      (harness-then created
                    (lambda (child)
                      ;; A hint or a priority that cannot be set must not
                      ;; fail the sub-agent.
                      (when hint
                        (condition-case err
                            (harness-call 'session/hint (plist-get child :id) hint)
                          (error (harness-log 'warn "tools-agent: adding the context cap hint to %s failed: %S"
                                              (plist-get child :id) err))))
                      (when priority
                        (condition-case err
                            (harness-call 'priority/set (plist-get child :id) (symbol-name priority))
                          (error (harness-log 'warn "tools-agent: giving %s priority %s failed: %S"
                                              (plist-get child :id) priority err))))
                      child)))))

(defun harness-tools-agent--call-node (session-id call-id)
  "Return the newest tool-call node of SESSION-ID whose call id is CALL-ID, or nil."
  (cl-find-if (lambda (node) (and (eq (plist-get node :kind) 'tool-call)
                                  (equal (plist-get node :call-id) call-id)))
              (harness-call 'session/nodes session-id) :from-end t))

(defun harness-tools-agent--name-child (session-id call-id child-id)
  "Name CHILD-ID on the tool call CALL-ID of SESSION-ID, as its result will.
The call is the spawn_agent call that started the sub-agent: the chat
links it to the child's session from the moment the child exists,
rather than only once the call returns and its result names the child.
The call node's `:meta' keeps what it held, such as the model.  Nothing
happens when no such call node is on the transcript: a call run without
one (`tools/execute' from outside an agent turn) has none to name."
  (when-let* ((node (harness-tools-agent--call-node session-id call-id)))
    (harness-call 'session/update-node session-id (plist-get node :id)
                  :meta (plist-put (copy-sequence (plist-get node :meta)) :child-id child-id))))

(defun harness-tools-agent--spawn (input ctx)
  "Handler of the spawn_agent tool.
Run INPUT's prompt in a child of the session in CTX and return at once,
naming the child.  A spawn never blocks the conversation: the child runs
on its own, and its answer is reported to the parent in a message of its
own once its turn ends and nothing of it is outstanding any more."
  (let* ((sid (plist-get ctx :session-id))
         (parent (harness-call 'session/get sid))
         ;; The child reads the prompt in its own session, so the links in
         ;; it are written out in full in this one's terms first
         ;; (`harness-tools-written'): harness:call/last is this session's.
         (written (harness-tools-written (or (plist-get input :prompt) "") ctx))
         (prompt (car written))
         (child-id (harness-uuid))
         ;; A priority no level has is refused here, before the worktree
         ;; or the child is made.
         (priority (harness-tools-agent--child-priority input))
         (want-worktree (and (harness-json-true-p (plist-get input :worktree))
                             (harness-method-exists-p 'worktree/create)))
         (cwd (or (plist-get input :cwd) (plist-get parent :cwd))))
    (when (string-empty-p (string-trim prompt))
      (signal 'harness-error (list "spawn_agent needs a prompt")))
    (harness-then
     (if want-worktree
         (harness-then
          (harness-call 'worktree/create (or (plist-get parent :project) (plist-get parent :cwd))
                        :branch (concat "harness/" (harness-tools-agent--short-id child-id)))
          (lambda (wt) (list :path (plist-get wt :path) :branch (plist-get wt :branch))))
       (harness-resolved nil))
     (lambda (wt)
       (let ((worktree (plist-get wt :path))
             (branch (plist-get wt :branch)))
         (harness-then
          (harness-tools-agent--create-child parent input child-id (or worktree cwd) worktree
                                             (plist-get ctx :call-id) priority)
          (lambda (child)
            (let* ((cid (plist-get child :id))
                   (entry (list :parent sid :name (plist-get child :name)
                                :worktree worktree :branch branch :result nil :stopped nil
                                :unwatch (harness-tools-agent--watch-child cid (plist-get ctx :note)))))
              ;; From here the call itself names its sub-agent, not only its
              ;; result: the chat links it while the call still runs.  A call
              ;; that could not be named still runs; only its link waits.
              (condition-case err
                  (harness-tools-agent--name-child sid (plist-get ctx :call-id) cid)
                (error (harness-log 'warn "tools-agent: naming the sub-agent %s on its call failed: %S"
                                    cid err)))
              (puthash cid entry harness-tools-agent--children)
              (harness-tools-agent--remember cid entry)
              (harness-emit 'agent/spawned sid cid)
              ;; The parent hears of the child's end in a message of its
              ;; own; this call returns now, while the child runs.
              (harness-then
               (harness-call-async 'agent/prompt cid prompt
                                   (list :from (harness-sender-session parent)))
               (lambda (result)
                 (harness-tools-agent--child-result cid result))
               (lambda (err)
                 (harness-tools-agent--child-result
                  cid (list :stop-reason 'error :error (harness-error-message err)))))
              (harness-tool-ok
               (harness-tools-with-note
                (format (concat "Sub-agent %s started (session %s%s). It runs in the background; "
                                "its answer arrives later in a message of its own, so do not "
                                "wait or poll. Start more sub-agents the same way, or carry on "
                                "with other work.")
                        (harness-tools-agent--child-name cid entry) cid
                        (if worktree (format ", worktree %s" (abbreviate-file-name worktree)) ""))
                (cdr written))
               :meta (list :child-id cid))))))))))

(harness-define-tool "spawn_agent"
  :label "Sub-agent"
  :description "Run a sub-agent on a prompt and return at once, naming the child session: it runs in the background and its answer arrives later in a message of its own when it is done, so the call never blocks this conversation -- never wait or poll for a sub-agent. Start several at once, in several calls in the same step or one after another, and carry on; each reports back on its own. fork=true forks this session (the child shares your context and its cached prefix; cheaper when the task needs what you already know); fork=false starts a fresh session with only the prompt. worktree=true gives the child its own git worktree and branch so it can change files in parallel; merge its branch back afterwards through the merge queue. priority is the child session's own priority (low, medium or high), which orders the queues its work waits in: without it the child works at what it inherits from this session. thinking chooses the child's thinking level, one the child's model offers (after any model override); without it the child thinks at this session's level, and a level the model does not offer fails the call."
  :schema '(:type "object"
            :properties (:prompt (:type "string" :description "The task for the sub-agent.")
                         :fork (:type "boolean" :description "Fork this session instead of starting fresh (default false).")
                         :model (:type "string" :description "Model id for the child (default: this session's model).")
                         :thinking (:type "string" :description "Thinking level for the child (default: this session's). One of the levels the child's model offers.")
                         :name (:type "string" :description "Display name for the child session.")
                         :cwd (:type "string" :description "Working directory for the child (default: this session's), inside this session's allowed directories.")
                         :worktree (:type "boolean" :description "Create a git worktree and branch for the child (default false).")
                         :priority (:type "string" :enum ("low" "medium" "high")
                                    :description "The child session's priority (default: what it inherits from this session's)."))
            :required ("prompt"))
  :kind 'meta
  ;; The child works where it starts: the jail checks that like bash's cwd.
  :paths (lambda (input) (list (or (plist-get input :cwd) ".")))
  :timeout 3600
  :subject (lambda (input) (format "%s%s"
                                   (or (plist-get input :name) (harness-first-line (plist-get input :prompt) 50))
                                   (if (harness-json-true-p (plist-get input :fork)) " (fork)" "")))
  :handler #'harness-tools-agent--spawn)

;;;; Registration

(defun harness-tools-agent--init ()
  "Register the module's filters and subscribers (idempotent)."
  (harness-add-filter 'agent/system-prompt #'harness-tools-agent--system-prompt 40)
  (harness-add-filter 'agent/outstanding #'harness-tools-agent--outstanding)
  (harness-add-filter 'agent/stop-outstanding #'harness-tools-agent--stop-outstanding)
  (harness-on 'agent/turn-ended #'harness-tools-agent--on-turn-ended))

(harness-tools-agent--init)

(defvar harness-tools-agent--settle-delay 60
  "Seconds after a start before children taken back with nothing to run report.
Internal.  The resilience module reports them as soon as it has resumed
what it resumes (`harness-tools-agent-settle-adopted'); this is for a
harness without it, and catches what it left.")

(defun harness-tools-agent--settle-late ()
  "Report the children taken back after a restart that still have nothing to run."
  (when (and (harness-module-ready-p 'tools-agent)
             (harness-method-exists-p 'agent/running))
    (condition-case err
        (harness-tools-agent-settle-adopted
         (and (harness-method-exists-p 'session/interrupted)
              (mapcar (lambda (it) (cons (plist-get it :id) 'interrupted))
                      (harness-call 'session/interrupted))))
      (error (harness-log 'warn "tools-agent: reporting the children taken back failed: %s"
                          (harness-error-message err))))))

(defun harness-tools-agent--start ()
  "Start the module: its filters and subscribers, every time it starts.
At a start, not at a reload, it also takes back the sub-agents a
stopped harness had not reported (`harness-tools-agent--adopt')."
  (harness-tools-agent--init)
  (unless (harness-module-ready-p 'tools-agent)
    (harness-tools-agent--adopt)
    (when (cl-some (lambda (entry) (plist-get entry :adopted))
                   (hash-table-values harness-tools-agent--children))
      (run-at-time harness-tools-agent--settle-delay nil #'harness-tools-agent--settle-late))))

(harness-declare-event 'agent/spawned "(PARENT-ID CHILD-ID) after spawn_agent created a child session.")

(harness-define-module 'tools-agent
  :doc "The Sub-agent tool (spawn_agent), and the Planning section of the system prompt."
  :requires '(tools session agent)
  :init #'harness-tools-agent--start)

(provide 'harness-tools-agent)
;;; harness-tools-agent.el ends here
