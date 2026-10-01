;;; harness-tools-agent.el --- Tools that talk to the user and the harness  -*- lexical-binding: t; -*-

;;; Commentary:

;; The "meta" tools: the ones whose effect is on the conversation
;; rather than on files.
;;
;; - `ask_user' blocks the turn on a pending question and resolves when
;;   a UI answers it through `question/answer'.
;; - `plan' records a plan on the session (and adds a Planning section
;;   to the system prompt that explains forks, sub-agents, worktrees
;;   and the merge queue, so plans can use them).
;; - `todo_write' replaces the session's todo list.
;; - `spawn_agent' creates a child session (fresh or forked, optionally
;;   in its own git worktree), runs one prompt in it and returns the
;;   child's final answer.
;; - `session_info' describes the current session to the model.
;;
;; Nothing here waits: every long operation returns a promise, and the
;; continuations of unanswered questions live in a `defvar' so a reload
;; does not lose them.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

;;;; Questions

(defvar harness-tools-agent--questions (make-hash-table :test 'equal)
  "Pending id -> (:session-id ID :resolve FN) for unanswered ask_user calls.")

(defun harness-tools-agent--pending-item (session-id pid)
  "Return the pending item PID of SESSION-ID, or nil."
  (cl-find pid (harness-call 'session/pending session-id)
           :key (lambda (it) (plist-get it :id)) :test #'equal))

(defun harness-tools-agent--ask-user (input ctx)
  "Handler of the ask_user tool: block on a pending question from INPUT in CTX."
  (let* ((sid (plist-get ctx :session-id))
         (question (or (plist-get input :question) ""))
         (options (cl-remove-if-not #'stringp (plist-get input :options)))
         (free (if (plist-member input :allow_free_text)
                   (harness-json-true-p (plist-get input :allow_free_text))
                 t)))
    (harness-with-promise (resolve reject)
      (ignore reject)
      (let ((pid (harness-call 'session/pending-add sid
                               (list :kind 'question
                                     :payload (list :question question :options options
                                                    :allow-free-text free
                                                    :call-id (plist-get ctx :call-id))))))
        (puthash pid (list :session-id sid :resolve resolve) harness-tools-agent--questions)
        (harness-emit 'question/asked sid (harness-tools-agent--pending-item sid pid))))))

(defun harness-tools-agent--answer-text (answer)
  "Return the answer text from ANSWER, a string or a plist with `:answer'."
  (cond ((stringp answer) answer)
        ((and (listp answer) (plist-get answer :answer)) (format "%s" (plist-get answer :answer)))
        ((null answer) "")
        (t (format "%s" answer))))

(defun harness-tools-agent--settle-question (session-id pid answer)
  "Resolve pending question PID of SESSION-ID with ANSWER.
Return non-nil when a continuation was waiting."
  (let ((entry (gethash pid harness-tools-agent--questions)))
    (harness-call 'session/pending-resolve session-id pid answer)
    (when entry
      (remhash pid harness-tools-agent--questions)
      (funcall (plist-get entry :resolve) (harness-tool-ok (harness-tools-agent--answer-text answer)))
      (harness-emit 'question/answered session-id pid answer)
      t)))

(harness-defmethod question/answer (session-id pid answer)
  "Answer pending question PID of SESSION-ID with ANSWER.
ANSWER is a string or a plist (:answer STRING).  The waiting ask_user
call returns the text as its result.  Return non-nil when a question
was waiting."
  (harness-tools-agent--settle-question session-id pid answer))

(harness-defmethod question/cancel (session-id pid)
  "Dismiss pending question PID of SESSION-ID.
The waiting ask_user call returns \"The user dismissed the question\"."
  (harness-tools-agent--settle-question session-id pid "The user dismissed the question"))

(harness-defmethod question/pending (session-id)
  "Return the pending requests of SESSION-ID whose kind is `question'."
  (cl-remove-if-not (lambda (it) (eq (plist-get it :kind) 'question))
                    (harness-call 'session/pending session-id)))

(harness-define-tool "ask_user"
  :description "Ask the user a question and wait for the answer. Use it when only the user can decide (ambiguous requirements, destructive choices, credentials). Offer options when there is a small set of sensible answers; the user may also type a free-form answer unless allow_free_text is false."
  :schema '(:type "object"
            :properties (:question (:type "string" :description "The question to ask.")
                         :options (:type "array" :items (:type "string")
                                   :description "Optional list of suggested answers.")
                         :allow_free_text (:type "boolean"
                                           :description "Whether a free-form answer is acceptable (default true)."))
            :required ("question"))
  :kind 'meta
  :timeout 86400
  :title (lambda (input) (format "ask_user %s" (harness-truncate-end (harness-first-line (or (plist-get input :question) "")) 60)))
  :handler #'harness-tools-agent--ask-user)

;;;; Plan

(defconst harness-tools-agent-planning-section
  "## Planning
When a task is complex (several files, several steps, anything you cannot verify in one go), produce a plan with the `plan` tool before changing anything. The plan states the approach, the concrete steps, how the result will be verified, and how the work will be split.

Split work with the mechanisms this harness provides:
- Session forks share the cached context of the current session, so they are much cheaper than a fresh sub-agent that has to gather all the context again. Prefer a fork (spawn_agent with fork=true) when the sub-task needs what you already know.
- spawn_agent starts a fresh sub-agent (fork=false) when the sub-task is self-contained and does not need the current context; it gets its own session and returns its final answer to you.
- Each sub-agent can work in its own git worktree (worktree=true), so independent steps run in parallel worktrees without touching each other's files.
- A merge queue brings a worktree's branch back into the parent session's working directory, one child at a time; conflicts are handed to the child to resolve. Plan independent steps as parallel worktrees that merge back, and dependent steps sequentially in this session.
Keep the plan short and concrete; update the todo list (todo_write) as steps complete."
  "Text appended to the system prompt by the tools-agent module.")

(defun harness-tools-agent--system-prompt (prompt _session)
  "Append the Planning section to PROMPT (the `agent/system-prompt' filter)."
  (concat prompt "\n\n" harness-tools-agent-planning-section "\n"))

(defun harness-tools-agent--plan (input ctx)
  "Handler of the plan tool: record INPUT's plan on the session in CTX."
  (let ((sid (plist-get ctx :session-id))
        (plan (or (plist-get input :plan) ""))
        (title (plist-get input :title)))
    (harness-call 'session/set-plan sid plan)
    (harness-call 'session/append sid (list :kind 'plan :content plan :title title))
    (harness-call 'session/hint sid "Plan updated")
    (harness-tool-ok "Plan recorded. Proceed when the user agrees or continue if they asked you to just do it.")))

(harness-define-tool "plan"
  :description "Record a plan for a complex task before starting it: approach, steps, verification, and how the work is split (forks, sub-agents, worktrees, merges). The plan is shown to the user."
  :schema '(:type "object"
            :properties (:plan (:type "string" :description "The plan in markdown.")
                         :title (:type "string" :description "Optional short title."))
            :required ("plan"))
  :kind 'meta
  :title (lambda (input) (format "plan %s" (or (plist-get input :title)
                                               (harness-truncate-end (harness-first-line (or (plist-get input :plan) "")) 60))))
  :handler #'harness-tools-agent--plan)

;;;; Todos

(defun harness-tools-agent--todo-status (value)
  "Return VALUE as one of the symbols pending, in-progress or done."
  (let ((s (downcase (format "%s" (or value "pending")))))
    (cond ((member s '("done" "completed" "complete")) 'done)
          ((member s '("in-progress" "in_progress" "in progress" "active" "doing")) 'in-progress)
          (t 'pending))))

(defun harness-tools-agent--normalise-todo (item index)
  "Return todo ITEM (a plist or a string) as (:id :text :status); INDEX numbers it."
  (if (stringp item)
      (list :id (format "t%d" index) :text item :status 'pending)
    (list :id (format "%s" (or (plist-get item :id) (format "t%d" index)))
          :text (or (plist-get item :text) (plist-get item :content) "")
          :status (harness-tools-agent--todo-status (plist-get item :status)))))

(defun harness-tools-agent--render-todos (todos)
  "Return a compact rendering of TODOS with counts."
  (let ((done 0) (active 0) (pending 0))
    (dolist (todo todos)
      (pcase (plist-get todo :status)
        ('done (cl-incf done))
        ('in-progress (cl-incf active))
        (_ (cl-incf pending))))
    (concat
     (mapconcat (lambda (todo)
                  (format "%s %s"
                          (pcase (plist-get todo :status)
                            ('done "[x]") ('in-progress "[~]") (_ "[ ]"))
                          (plist-get todo :text)))
                todos "\n")
     (if todos "\n" "")
     (format "%d todos: %d done, %d in progress, %d pending"
             (length todos) done active pending))))

(defun harness-tools-agent--todo-write (input ctx)
  "Handler of the todo_write tool.
Replace the todos of the session in CTX with those in INPUT."
  (let* ((raw (plist-get input :todos))
         (todos (cl-loop for item in raw for i from 1
                         collect (harness-tools-agent--normalise-todo item i))))
    (harness-call 'session/set-todos (plist-get ctx :session-id) todos)
    (harness-tool-ok (harness-tools-agent--render-todos todos))))

(harness-define-tool "todo_write"
  :description "Replace the session's todo list. Each item has id, text and status (pending, in-progress or done); plain strings are accepted as pending items. Keep exactly one item in progress at a time and mark items done as soon as they are."
  :schema '(:type "object"
            :properties (:todos (:type "array"
                                 :items (:type "object"
                                         :properties (:id (:type "string")
                                                      :text (:type "string")
                                                      :status (:type "string" :enum ("pending" "in-progress" "done")))
                                         :required ("text"))))
            :required ("todos"))
  :kind 'meta
  :coalescable t
  :title (lambda (input) (format "todo_write %d items" (length (plist-get input :todos))))
  :handler #'harness-tools-agent--todo-write)

;;;; Sub-agents

(defvar harness-tools-agent--children (make-hash-table :test 'equal)
  "Child session id -> (:report FN :calls N) while a spawn_agent call runs.")

(defun harness-tools-agent--short-id (id)
  "Return the first eight characters of session ID."
  (substring id 0 (min 8 (length id))))

(defun harness-tools-agent--on-child-tool-call (session-id node)
  "Report the tool call NODE of a running child SESSION-ID to its parent's call."
  (let ((entry (gethash session-id harness-tools-agent--children)))
    (when entry
      (cl-incf (plist-get entry :calls))
      (when (plist-get entry :report)
        (ignore-errors
          (funcall (plist-get entry :report)
                   (format "sub-agent %s: %s" (harness-tools-agent--short-id session-id)
                           (or (plist-get node :title) (plist-get node :tool)))))))))

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

(defun harness-tools-agent--create-child (parent input child-id cwd worktree)
  "Return a promise of the child session plist for PARENT from INPUT.
CHILD-ID is the id to use, CWD its working directory and WORKTREE
its worktree path (or nil)."
  (let ((fork (harness-json-true-p (plist-get input :fork)))
        (name (plist-get input :name))
        (model (or (plist-get input :model) (plist-get parent :model))))
    (if fork
        (harness-as-promise
         (harness-call 'session/fork (plist-get parent :id)
                       :id child-id :kind 'subagent :name name :model model
                       :cwd cwd :worktree worktree))
      (harness-as-promise
       (harness-call 'session/create
                     :id child-id :cwd cwd :worktree worktree :kind 'subagent
                     :parent-id (plist-get parent :id) :name name :model model
                     :host (plist-get parent :host)
                     :permission-mode (plist-get parent :permission-mode)
                     :thinking (plist-get parent :thinking)
                     :non-interactive (plist-get parent :non-interactive))))))

(defun harness-tools-agent--spawn (input ctx)
  "Handler of the spawn_agent tool.
Run INPUT's prompt in a child of the session in CTX."
  (let* ((sid (plist-get ctx :session-id))
         (parent (harness-call 'session/get sid))
         (prompt (or (plist-get input :prompt) ""))
         (child-id (harness-uuid))
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
          (lambda (wt) (plist-get wt :path)))
       (harness-resolved nil))
     (lambda (worktree)
       (harness-then
        (harness-tools-agent--create-child parent input child-id (or worktree cwd) worktree)
        (lambda (child)
          (let ((cid (plist-get child :id)))
            (puthash cid (list :report (plist-get ctx :report) :calls 0) harness-tools-agent--children)
            (harness-emit 'agent/spawned sid cid)
            (when (plist-get ctx :report)
              (funcall (plist-get ctx :report)
                       (format "sub-agent %s started%s" (harness-tools-agent--short-id cid)
                               (if worktree (format " in worktree %s" (abbreviate-file-name worktree)) ""))))
            (harness-then
             (harness-call-async 'agent/prompt cid prompt)
             (lambda (result)
               (remhash cid harness-tools-agent--children)
               (let ((text (harness-tools-agent--child-summary cid)))
                 (if (memq (plist-get result :stop-reason) '(end-turn max-tokens))
                     (harness-tool-ok text :meta (list :child-id cid))
                   (harness-tool-error
                    (format "%s\n\n(sub-agent stopped: %s%s)" text (plist-get result :stop-reason)
                            (if (plist-get result :error) (format ", %s" (plist-get result :error)) ""))
                    :meta (list :child-id cid)))))
             (lambda (err)
               (remhash cid harness-tools-agent--children)
               (signal 'harness-error (list (harness-error-message err))))))))))))

(harness-define-tool "spawn_agent"
  :description "Run a sub-agent on a prompt and return its final answer. fork=true forks this session (the child shares your context and its cached prefix; cheaper when the task needs what you already know); fork=false starts a fresh session with only the prompt. worktree=true gives the child its own git worktree and branch so it can change files in parallel; merge its branch back afterwards through the merge queue. The call returns when the child finishes."
  :schema '(:type "object"
            :properties (:prompt (:type "string" :description "The task for the sub-agent.")
                         :fork (:type "boolean" :description "Fork this session instead of starting fresh (default false).")
                         :model (:type "string" :description "Model id for the child (default: this session's model).")
                         :name (:type "string" :description "Display name for the child session.")
                         :cwd (:type "string" :description "Working directory for the child (default: this session's).")
                         :worktree (:type "boolean" :description "Create a git worktree and branch for the child (default false)."))
            :required ("prompt"))
  :kind 'meta
  :timeout 3600
  :title (lambda (input) (format "spawn_agent%s %s" (if (harness-json-true-p (plist-get input :fork)) " (fork)" "")
                                 (or (plist-get input :name)
                                     (harness-truncate-end (harness-first-line (or (plist-get input :prompt) "")) 50))))
  :handler #'harness-tools-agent--spawn)

;;;; Session info

(defun harness-tools-agent--window-text (window)
  "Describe the quota WINDOW plist in a few words."
  (let ((used (round (* 100 (or (plist-get window :used) 0))))
        (resets (plist-get window :resets)))
    (concat (format "%s %d%% used" (or (plist-get window :label) (plist-get window :name)) used)
            (if (numberp resets) (format-time-string " (resets %a %H:%M)" resets) ""))))

(defun harness-tools-agent--quota-line (session-id)
  "Return a line with the plan quota last reported to SESSION-ID, or \"\"."
  (let ((windows (ignore-errors (harness-call 'session/runtime session-id :quota :get))))
    (if windows
        (format "Plan quota: %s\n" (mapconcat #'harness-tools-agent--window-text windows "; "))
      "")))

(defun harness-tools-agent--session-info (_input ctx)
  "Handler of the session_info tool: describe the session in CTX."
  (let* ((sid (plist-get ctx :session-id))
         (s (harness-call 'session/get sid))
         (u (plist-get s :usage))
         (children (harness-call 'session/list (list :parent-id sid))))
    (harness-tool-ok
     (concat
      (format "Session: %s\nName: %s\nKind: %s\nModel: %s\nWorking directory: %s\nWorktree: %s\nPermission mode: %s\nStatus: %s\n"
              sid (or (plist-get s :name) "(unnamed)") (plist-get s :kind) (plist-get s :model)
              (plist-get s :cwd) (or (plist-get s :worktree) "none")
              (plist-get s :permission-mode) (plist-get s :status))
      (format "Usage: %s input, %s output, %s cache read, cost %s, %d turns, context %s of %s\n"
              (harness-format-tokens (plist-get u :input)) (harness-format-tokens (plist-get u :output))
              (harness-format-tokens (plist-get u :cache-read)) (harness-format-spend u)
              (or (plist-get u :turns) 0) (harness-format-tokens (plist-get u :context))
              (harness-format-tokens (plist-get s :context-window)))
      (harness-tools-agent--quota-line sid)
      (format "Parent: %s\n" (or (plist-get s :parent-id) "none"))
      (format "Children: %s"
              (if children
                  (mapconcat (lambda (c) (format "%s (%s, %s)" (plist-get c :id) (plist-get c :kind) (plist-get c :status)))
                             children ", ")
                "none"))))))

(harness-define-tool "session_info"
  :description "Describe the current session: id, name, model, working directory, permission mode, status, usage and related sessions."
  :schema '(:type "object" :properties :empty)
  :kind 'read
  :coalescable t
  :title (lambda (_input) "session_info")
  :handler #'harness-tools-agent--session-info)

;;;; Registration

(defun harness-tools-agent--init ()
  "Register the module's filter and subscriber (idempotent)."
  (harness-add-filter 'agent/system-prompt #'harness-tools-agent--system-prompt 40)
  (harness-on 'agent/tool-call #'harness-tools-agent--on-child-tool-call))

(harness-tools-agent--init)

(harness-declare-event 'question/asked "(SESSION-ID PENDING) after ask_user added a pending question.")
(harness-declare-event 'question/answered "(SESSION-ID PENDING-ID ANSWER) after a question was answered or dismissed.")
(harness-declare-event 'agent/spawned "(PARENT-ID CHILD-ID) after spawn_agent created a child session.")

(harness-define-module 'tools-agent
  :doc "ask_user, plan, todo_write, spawn_agent and session_info tools."
  :requires '(tools session agent)
  :init #'harness-tools-agent--init)

(provide 'harness-tools-agent)
;;; harness-tools-agent.el ends here
