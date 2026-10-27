;;; harness-supervisor-plan-test.el --- Tests for the supervisor's plan engine  -*- lexical-binding: t; -*-

;;; Commentary:

;; The demo provider plays every model: the supervisor's, its workers',
;; and a seed's.  `harness-supervisor-plan-test--script' answers a
;; request by the kind of its session and notes what it was asked.  A
;; supervisor (a main session) submits the plan a test hands it, and
;; deals with the harness's reports as the test's handler says; a worker
;; (a sub-agent) does its step.  Tests that only look at how a step
;; starts stub `session/fork', `seed/fork' and `session/create' for
;; sub-agents: the stub records the call and answers with a promise that
;; never settles, which leaves the step running.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)
(defvar harness-provider-demo-script-override)
(defvar harness-supervisor)
(defvar harness-supervisor-tasks)
(defvar harness-supervisor-tiers)
(defvar harness-supervisor-step-budget)
(defvar harness-supervisor-fork-limit)
(defvar harness-subagent-context-limit)
(defvar harness-cowboy-default)
(defvar harness-cowboy-min-context)
(defvar harness-compaction-brief-model)
(defvar harness-supervisor--decisions)
(defvar harness-supervisor--reminders)
(defvar harness-supervisor--calls)
(defvar harness-supervisor--configured)
(defvar harness-supervisor--live)
(defvar harness-supervisor--ending)
(defvar harness-supervisor--held)
(defvar harness-supervisor--spawns)
(defvar harness-supervisor--raised)
(defvar harness-supervisor--blocks-hand-in)
(defvar harness-tools)
(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness--methods)
(defvar harness--filters)
(defvar harness--subscribers)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--naming)
(defvar harness-tasks--naming-pool)
(defvar harness-tasks--loaded)
(defvar harness-tasks--dirty)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-permission-mode)
(defvar harness-tasks-non-interactive)
(defvar harness-tasks-model)
(defvar harness-naming-auto)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-agent--cancel-grace)
(defvar harness-tasks--preempted-message)
(defvar harness-tasks--paused-message)
(declare-function harness-tasks--free-slots "harness-tasks")
(declare-function harness-tasks--slot-project "harness-tasks")
(declare-function harness-tasks--reject-text "harness-tasks")
(declare-function harness-provider-demo--last-user-text "harness-provider-demo")
(declare-function harness-provider-demo--complete "harness-provider-demo")
(declare-function harness-define-provider "harness-provider")
(declare-function harness-provider-unregister "harness-provider")
(declare-function harness-supervisor--update-step "harness-supervisor")
(declare-function harness-supervisor--conversation-tokens "harness-supervisor")
(declare-function harness-supervisor--tier-model "harness-supervisor")
(declare-function harness-supervisor--on-turn-ended "harness-supervisor")
(declare-function harness-session--ext-json-p "harness-session")
(declare-function harness-tool-title "harness-tools")
(declare-function harness-tool-get "harness-tools")
(declare-function harness-tool-kind "harness-tools")
(declare-function harness-supervisor--start "harness-supervisor")
(declare-function harness-supervisor--init "harness-supervisor")
(declare-function harness-supervisor--shutdown "harness-supervisor")
(declare-function harness-supervisor--recover "harness-supervisor")
(declare-function harness-supervisor--outstanding "harness-supervisor")
(declare-function harness-supervisor--stop-outstanding "harness-supervisor")
(declare-function harness-supervisor--send "harness-supervisor")
(declare-function harness-supervisor--open-steps "harness-supervisor")
(declare-function harness-supervisor--finished-p "harness-supervisor")
(declare-function harness-supervisor--with "harness-supervisor")
(declare-function harness-tools-agent-context-limit "harness-tools-agent")
(declare-function harness-tasks--forget-stores "harness-tasks")
(declare-function harness-tasks--naming-pool-new "harness-tasks")
(declare-function harness-acp--drop-client "harness-acp")
(declare-function harness-session--load-all "harness-session")
(declare-function harness-session-flush "harness-session")

;;;; The provider

(defvar harness-supervisor-plan-test--plan nil
  "The input of the submit_plan call that a supervisor's first answer is.")

(defvar harness-supervisor-plan-test--on-report nil
  "Function of a report's text returning the events a supervisor answers with.
Nil, or a function that returns nil, makes it record that it needs no plan.")

(defvar harness-supervisor-plan-test--worker nil
  "Function of (STEP-ID TEXT REQUEST) returning the events a worker answers with.
Nil, or a function that returns nil, makes the worker reply that it is done.")

(defvar harness-supervisor-plan-test--behaviours nil
  "Alist from a step id to what its next attempts do, oldest first.
An attempt is a string (its reply), `error' (its turn fails), `hold' (it
keeps working until it is cancelled), (wait SECONDS) or (reply TEXT SECONDS).
An attempt past the list replies \"Done STEP.\".")

(defvar harness-supervisor-plan-test--requests nil
  "What the provider was asked, newest first.
Each is (:session ID :kind KIND :model MODEL :text TEXT :step STEP-ID).")

(defun harness-supervisor-plan-test-reply (text)
  "Return the events of a model that answers with TEXT and stops."
  (list (list :type 'text :delta text) '(:type done :stop-reason end-turn)))

(defun harness-supervisor-plan-test-call (name input &optional id)
  "Return the events of a model that calls tool NAME with INPUT, under call ID."
  (list (list :type 'tool-call :id (or id (format "call-%s" (harness-short-id 4))) :name name :input input)))

(defun harness-supervisor-plan-test--after-tool-p (request)
  "Non-nil when the last thing REQUEST holds is the result of a tool call.
Not `harness-provider-demo--has-tool-results-p', which also holds for a
message that follows a result: providers join the two."
  (let* ((last (car (last (plist-get request :messages))))
         (block (car (last (plist-get last :content)))))
    (equal (plist-get block :type) "tool_result")))

(defun harness-supervisor-plan-test--supervisor (request text)
  "Return the events a supervisor answers REQUEST, which says TEXT, with."
  (cond
   ;; Whatever the tool answered, it says so and stops.
   ((harness-supervisor-plan-test--after-tool-p request)
    (harness-supervisor-plan-test-reply "Noted."))
   ((string-prefix-p "Supervisor report:" text)
    (or (and harness-supervisor-plan-test--on-report
             (funcall harness-supervisor-plan-test--on-report text))
        (harness-supervisor-plan-test-call "no_plan_needed" '(:reason "nothing to decide"))))
   ((equal text "Hold on")
    (cons '(:type wait :seconds 1.0) (harness-supervisor-plan-test-reply "Waited.")))
   (harness-supervisor-plan-test--plan
    (harness-supervisor-plan-test-call "submit_plan" harness-supervisor-plan-test--plan "call-plan"))
   (t (harness-supervisor-plan-test-reply "ok"))))

(defun harness-supervisor-plan-test--script (request)
  "Answer REQUEST by the kind of its session, and note it."
  (let* ((session (plist-get request :session))
         (kind (plist-get session :kind))
         (text (harness-provider-demo--last-user-text request))
         (step (and (string-match "^## Step \\([^:\n]+\\):" text) (match-string 1 text))))
    (push (list :session (plist-get session :id) :kind kind :model (plist-get request :model)
                :text text :step step)
          harness-supervisor-plan-test--requests)
    (or (if (eq kind 'main)
            (harness-supervisor-plan-test--supervisor request text)
          (and step harness-supervisor-plan-test--worker
               (funcall harness-supervisor-plan-test--worker step text request)))
        (if step
            (harness-supervisor-plan-test-reply (format "Done %s." step))
          (harness-supervisor-plan-test-reply "ok")))))

;; What a worker does when it is given step STEP.
(defun harness-supervisor-plan-test--do (step _text _request)
  "Return the events of a worker's next attempt at STEP, as the test said."
  (let* ((cell (assoc step harness-supervisor-plan-test--behaviours))
         (attempt (and cell (pop (cdr cell)))))
    (pcase attempt
      ((pred stringp) (harness-supervisor-plan-test-reply attempt))
      ('error '((:type done :stop-reason error :error "boom")))
      ('hold (cons '(:type wait :seconds 60) (harness-supervisor-plan-test-reply "late")))
      (`(wait ,seconds)
       (cons (list :type 'wait :seconds seconds)
             (harness-supervisor-plan-test-reply (format "Done %s." step))))
      (`(reply ,text ,seconds)
       (cons (list :type 'wait :seconds seconds) (harness-supervisor-plan-test-reply text)))
      (`(events . ,events) events))))

(defun harness-supervisor-plan-test-behave (step &rest attempts)
  "Make the workers of STEP do ATTEMPTS, one for each time the step runs."
  (setf (alist-get step harness-supervisor-plan-test--behaviours nil nil #'equal) attempts))

(defun harness-supervisor-plan-test-requests-of-kind (kind)
  "Return the requests that sessions of KIND made, oldest first."
  (nreverse (cl-remove-if-not (lambda (r) (eq kind (plist-get r :kind)))
                              (copy-sequence harness-supervisor-plan-test--requests))))

(defun harness-supervisor-plan-test-step-request (step-id &optional nth)
  "Return the request that gave a worker step STEP-ID, the NTH (from 0)."
  (nth (or nth 0) (nreverse (cl-remove-if-not (lambda (r) (equal step-id (plist-get r :step)))
                                              (copy-sequence harness-supervisor-plan-test--requests)))))

;;;; Fixtures

(defconst harness-supervisor-plan-test-modules
  '(store project config provider provider-demo tools session agent tools-agent tools-question tools-plan tools-todo tools-session-info seed readonly supervisor)
  "The modules every test loads.")

(defun harness-supervisor-plan-test--tier-model (_model &optional tier)
  "Stand in for `provider/tier-model': a model of the demo provider for TIER."
  (pcase tier
    ('simple "demo:simple") ('medium "demo:medium") ('hard "demo:hard")))

(defun harness-supervisor-plan-test-stub-tier-model (fn)
  "Make FN the tier mapping of the provider layer, whatever method it asks through.
FN takes a model id and an optional tier and returns the model of that
tier, or nil.  All three of `provider/tier-model',
`provider/tier-model-info' and `provider/tier-model-async' are
registered, so which one the plan engine prefers makes no difference to
a test that only cares what a tier maps to."
  (harness-register-method
   'provider/tier-model (lambda (model &optional tier) (funcall fn model tier)))
  (harness-register-method
   'provider/tier-model-info
   (lambda (model &optional tier)
     (let ((id (funcall fn model tier)))
       (cons id (and (null id) 'none)))))
  (harness-register-method
   'provider/tier-model-async
   (lambda (model &optional tier)
     (let ((id (funcall fn model tier)))
       (harness-resolved (cons id (and (null id) 'none))))))
  fn)

(defun harness-supervisor-plan-test-real-tiers ()
  "Put back the provider layer's own tier mapping, as the fixture's stub replaced it.
A test of what the real catalogue gives a tier calls this inside
`harness-supervisor-plan-test-with'."
  (harness-test-load-module 'provider))

(defun harness-supervisor-plan-test--allow (_decision next &rest _)
  "Allow every call that gets this far, as yolo mode would; continue with NEXT."
  (funcall next (list :behavior 'allow)))

(defmacro harness-supervisor-plan-test-with-modules (extra &rest body)
  "Load the state layer, the plan engine and the modules EXTRA names, run BODY.
The demo provider plays the model through the script of the test, the
permission chain allows everything the supervisor's own stage lets by,
and the tiers map to the demo models simple, medium and hard."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (when (boundp 'harness-tools) (clrhash harness-tools))
     (dolist (m (append harness-supervisor-plan-test-modules ',extra))
       (harness-test-load-module m))
     ;; The recovery the module schedules is not this test's to run: a
     ;; test that wants it calls it.
     (cancel-function-timers #'harness-supervisor--recover)
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (dolist (table (list harness-supervisor--decisions harness-supervisor--reminders
                          harness-supervisor--calls harness-supervisor--configured
                          harness-supervisor--live harness-supervisor--ending
                          harness-supervisor--held harness-supervisor--spawns
                          harness-supervisor--raised))
       (clrhash table))
     (harness-supervisor-plan-test-stub-tier-model #'harness-supervisor-plan-test--tier-model)
     (harness-add-filter 'permission/decide #'harness-supervisor-plan-test--allow 10)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override #'harness-supervisor-plan-test--script)
           (harness-supervisor-plan-test--plan nil)
           (harness-supervisor-plan-test--on-report nil)
           (harness-supervisor-plan-test--worker #'harness-supervisor-plan-test--do)
           (harness-supervisor-plan-test--behaviours nil)
           (harness-supervisor-plan-test--requests nil)
           (harness-supervisor t)
           (harness-supervisor-tasks t)
           (harness-supervisor-tiers nil)
           (harness-supervisor-step-budget 80)
           (default-directory dir))
       ,@body)))

(defmacro harness-supervisor-plan-test-with (&rest body)
  "Run BODY with the plan engine and the demo provider."
  (declare (indent 0))
  `(harness-supervisor-plan-test-with-modules () ,@body))

(defun harness-supervisor-plan-test-session (&rest plist)
  "Create a supervising demo session with PLIST's settings; return its id."
  (let ((cwd (harness-test-temp-dir)))
    (harness-test-mark-project cwd)
    (plist-get (apply #'harness-call 'session/create :cwd cwd
                      :model "demo:scripted" plist)
               :id)))

(defun harness-supervisor-plan-test-step-input (id &rest props)
  "Return the input of step ID of a plan, PROPS overriding its defaults.
The defaults make a simple step that forks the supervisor, so that
the tests which look at how a fork starts need not say so.  A step with
no context, which the engine makes fresh, is `:context nil'; PROPS come
first, so they win."
  (append props (list :id id :title (format "Title of %s" id) :prompt (format "Do %s." id)
                      :tier "simple" :reason "simple" :context "fork")))

(defun harness-supervisor-plan-test-plan-input (&rest steps)
  "Return the input of a submit_plan call for STEPS, the inputs of its steps."
  (list :title "The plan" :summary "Do it in **steps**." :steps steps))

(defun harness-supervisor-plan-test-run (sid name &optional input id)
  "Execute tool NAME with INPUT, as call ID, in session SID; return its result."
  (harness-test-await
   (harness-call 'tools/execute sid (list :id (or id (harness-short-id)) :name name :input input))
   20))

(defun harness-supervisor-plan-test-prompt (sid text)
  "Run a turn of session SID on TEXT; return how it ended."
  (plist-get (harness-test-await (harness-call 'agent/prompt sid text) 20) :stop-reason))

(defun harness-supervisor-plan-test-plans (sid)
  "Return the plans of session SID, oldest first."
  (plist-get (plist-get (harness-call 'session/get sid) :ext) :supervisor-plans))

(defun harness-supervisor-plan-test-plan (sid &optional n)
  "Return the Nth plan (from 0, the first) of session SID."
  (nth (or n 0) (harness-supervisor-plan-test-plans sid)))

(defun harness-supervisor-plan-test-step (sid id &optional n)
  "Return step ID of the Nth plan (from 0, the first) of session SID."
  (cl-find id (plist-get (harness-supervisor-plan-test-plan sid n) :steps)
           :key (lambda (step) (plist-get step :id)) :test #'equal))

(defun harness-supervisor-plan-test-state (sid id &optional n)
  "Return the state of step ID of the Nth plan of session SID."
  (plist-get (harness-supervisor-plan-test-step sid id n) :state))

(defun harness-supervisor-plan-test-wait-state (sid id state &optional n timeout)
  "Wait until step ID of the Nth plan of session SID is in STATE."
  (condition-case err
      (harness-test-wait (lambda () (equal state (harness-supervisor-plan-test-state sid id n)))
                         (or timeout 15) (format "step %s to be %s" id state))
    (error
     (message "Supervisor test diagnostics: plan=%S requests=%S live=%S running=%S nodes=%S"
              (ignore-errors (harness-supervisor-plan-test-plan sid n))
              harness-supervisor-plan-test--requests
              (hash-table-keys harness-supervisor--live)
              (ignore-errors (harness-call 'agent/running))
              (ignore-errors (harness-call 'session/nodes sid)))
     (signal (car err) (cdr err)))))

(defun harness-supervisor-plan-test-worker (sid id)
  "Wait until the worker of step ID of session SID runs; return its session id."
  (harness-test-wait (lambda ()
                       (let ((worker (plist-get (harness-supervisor-plan-test-step sid id) :session)))
                         (and worker (harness-call 'session/exists-p worker)
                              (harness-call 'agent/running worker) worker)))
                     10 (format "the worker of %s to run" id)))

(defun harness-supervisor-plan-test-nodes (sid kind)
  "Return the nodes of session SID of KIND, oldest first."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) kind)) (harness-call 'session/nodes sid)))

(defun harness-supervisor-plan-test-hints (sid)
  "Return the texts of the hints in session SID's transcript, oldest first."
  (mapcar (lambda (n) (plist-get n :content)) (harness-supervisor-plan-test-nodes sid 'hint)))

(defun harness-supervisor-plan-test-reports (sid)
  "Return the texts of the supervisor's reports in session SID's transcript.
Steering and queued ones included, oldest first."
  (cl-loop for n in (harness-supervisor-plan-test-nodes sid 'user)
           when (and (equal "supervisor" (plist-get (harness-node-sender n) :source))
                     (string-prefix-p "Supervisor report:" (plist-get n :content)))
           collect (plist-get n :content)))

(defun harness-supervisor-plan-test-wait-reports (sid count)
  "Wait until session SID's transcript holds COUNT reports; return them."
  (harness-test-wait (lambda () (>= (length (harness-supervisor-plan-test-reports sid)) count))
                     15 (format "%d reports" count))
  (harness-supervisor-plan-test-reports sid))

(defun harness-supervisor-plan-test-wait-idle (sid)
  "Wait until session SID runs no turn and has nothing queued."
  (harness-test-wait (lambda () (and (not (harness-call 'agent/running sid))
                                     (not (plist-get (harness-call 'session/get sid) :queue))))
                     15 "the supervisor to be idle"))

(defvar harness-supervisor-plan-test--calls nil
  "The calls the stubs of `harness-supervisor-plan-test-stub-starts' noted.
Newest first.
Each is (METHOD . ARGS).")

(defmacro harness-supervisor-plan-test-stub-starts (&rest body)
  "Run BODY with the starts of workers stubbed and noted.
`session/fork', `seed/fork' and, for sub-agents, `session/create' note
their call in `harness-supervisor-plan-test--calls' and answer with a
promise that never settles, so the steps stay running."
  (declare (indent 0))
  `(let ((harness-supervisor-plan-test--calls nil)
         (create (harness-method-fn (gethash 'session/create harness--methods))))
     (dolist (method '(session/fork seed/fork))
       (let ((method method))
         (harness-register-method
          method (lambda (&rest args)
                   (push (cons method args) harness-supervisor-plan-test--calls)
                   (harness-make-promise)))))
     (harness-register-method
      'session/create
      (lambda (&rest args)
        (if (eq 'subagent (plist-get args :kind))
            (progn (push (cons 'session/create args) harness-supervisor-plan-test--calls)
                   (harness-make-promise))
          (apply create args))))
     ,@body))

(defun harness-supervisor-plan-test-calls (method)
  "Return the arguments of the noted calls of METHOD, oldest first."
  (nreverse (mapcar #'cdr (cl-remove-if-not (lambda (call) (eq method (car call)))
                                            (copy-sequence harness-supervisor-plan-test--calls)))))

;;;; The workers' spawn_agent calls

(defun harness-supervisor-plan-test-spawn-calls (sid)
  "Return the spawn_agent calls of session SID's transcript, oldest first."
  (cl-remove-if-not (lambda (node) (and (eq (plist-get node :kind) 'tool-call)
                                        (equal "spawn_agent" (plist-get node :tool))))
                    (harness-call 'session/nodes sid)))

(defun harness-supervisor-plan-test-spawn-call-of (sid worker-id)
  "Return the spawn_agent call of session SID that names WORKER-ID."
  (cl-find worker-id (harness-supervisor-plan-test-spawn-calls sid)
           :key (lambda (node) (plist-get (plist-get node :meta) :child-id))
           :test #'equal))

(defun harness-supervisor-plan-test-spawn-results (sid call)
  "Return the tool results of session SID that answer the spawn_agent CALL."
  (cl-remove-if-not (lambda (node) (and (eq (plist-get node :kind) 'tool-result)
                                        (equal (plist-get call :call-id) (plist-get node :call-id))))
                    (harness-call 'session/nodes sid)))

(defun harness-supervisor-plan-test-node-position (sid pred)
  "Return where in session SID's transcript the first node satisfying PRED is."
  (cl-position-if pred (harness-call 'session/nodes sid)))

;;;; Reading the plan

(ert-deftest harness-supervisor-plan-the-tools-are-meta-tools-with-a-subject ()
  "submit_plan and retry_step are meta tools, and say in the approval prompt what they are."
  (harness-supervisor-plan-test-with
    (dolist (name '("submit_plan" "retry_step"))
      (let ((tool (harness-tool-get name)))
        (should tool)
        (should (eq 'meta (harness-tool-kind tool)))))
    (should (equal "Submit plan: The plan"
                   (harness-tool-title "submit_plan" '(:title "The plan" :summary "Long text\nmore"))))
    (should (equal "Submit plan: Long text"
                   (harness-tool-title "submit_plan" '(:summary "Long text\nmore"))))
    (should (equal "Retry step: s2 on hard" (harness-tool-title "retry_step" '(:step "s2" :tier "hard"))))
    (should (equal "Retry step: s2" (harness-tool-title "retry_step" '(:step "s2"))))
    ;; The supervisor's own stage lets them by: whether the user approves is the mode's call.
    (let* ((sid (harness-supervisor-plan-test-session))
           (names (mapcar (lambda (spec) (plist-get spec :name)) (harness-call 'tools/list sid))))
      (should (member "submit_plan" names))
      (should (member "retry_step" names)))))

(ert-deftest harness-supervisor-plan-refuses-a-plan-with-problems-and-names-every-one ()
  "Nothing starts, the result is an error, and it lists each problem."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let* ((sid (harness-supervisor-plan-test-session))
             (result (harness-supervisor-plan-test-run
                      sid "submit_plan"
                      (list :summary "  "
                            :steps (list (harness-supervisor-plan-test-step-input "a")
                                         ;; Same id, a blank prompt, a tier and a context nobody knows.
                                         (harness-supervisor-plan-test-step-input
                                          "a" :prompt "   " :tier "huge" :context "clone")
                                         (harness-supervisor-plan-test-step-input "b" :after '("nobody"))
                                         (harness-supervisor-plan-test-step-input "c" :after '("d"))
                                         (harness-supervisor-plan-test-step-input "d" :after '("c"))
                                         (harness-supervisor-plan-test-step-input "e" :after '("e")))))))
        (should (plist-get result :is-error))
        (should-not (plist-get result :end-turn))
        (let ((text (plist-get result :content)))
          (should (string-match-p "submit_plan was refused, and nothing started" text))
          (should (string-match-p "summary is empty" text))
          (should (string-match-p "the id a is used by 2 steps" text))
          (should (string-match-p "step a has a blank prompt" text))
          (should (string-match-p "step a has \"huge\" as its tier" text))
          (should (string-match-p "step a has \"clone\" as its context" text))
          (should (string-match-p "step b waits for nobody, which is no step of this plan" text))
          (should (string-match-p "steps c, d, e wait for each other in a cycle" text)))
        (should-not (harness-supervisor-plan-test-plans sid))
        (should-not harness-supervisor-plan-test--calls)
        (should (zerop (hash-table-count harness-supervisor--live)))
        (should-not (harness-supervisor-plan-test-hints sid))))))

(ert-deftest harness-supervisor-plan-a-plan-without-steps-or-summary-is-refused ()
  "A plan needs a summary and a step, and a step must be an object with an id."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (let ((text (plist-get (harness-supervisor-plan-test-run sid "submit_plan" '(:summary "x")) :content)))
        (should (string-match-p "the plan has no steps" text))
        (should (string-match-p "Fix this problem and call submit_plan again" text)))
      (let ((text (plist-get (harness-supervisor-plan-test-run sid "submit_plan" '(:steps nil)) :content)))
        (should (string-match-p "summary is empty" text))
        (should (string-match-p "the plan has no steps" text)))
      (let ((text (plist-get (harness-supervisor-plan-test-run
                              sid "submit_plan"
                              (list :summary "x" :steps (list "just a string"
                                                              (list :prompt "p" :tier "medium"))))
                             :content)))
        (should (string-match-p "step 1 is not an object" text))
        (should (string-match-p "step 2 has no id" text)))
      (should-not (harness-supervisor-plan-test-plans sid)))))

(ert-deftest harness-supervisor-plan-a-refused-plan-decides-nothing ()
  "A refused plan leaves the turn owing a decision, so the model is sent back to submit a good one."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((sid (harness-supervisor-plan-test-session)))
        (setq harness-supervisor-plan-test--plan
              (harness-supervisor-plan-test-plan-input (harness-supervisor-plan-test-step-input "a" :prompt "")))
        (should (eq 'end-turn (harness-supervisor-plan-test-prompt sid "Do the thing")))
        ;; The refusal, then the reminder: the model gave no decision.
        (let ((reminders (cl-loop for n in (harness-supervisor-plan-test-nodes sid 'user)
                                  when (equal "supervisor" (plist-get (harness-node-sender n) :source))
                                  collect (plist-get n :content))))
          (should (= 2 (length reminders)))
          (should (string-match-p "decision" (car reminders))))
        (should-not (harness-supervisor-plan-test-plans sid))
        (should-not harness-supervisor-plan-test--calls)))))

;;;; Models

(ert-deftest harness-supervisor-plan-each-tier-runs-on-the-model-of-its-provider ()
  "Simple runs on the provider's simple model, medium on its medium one.
A tier is read whatever its case, and the names of old, mundane and
standard, stand for simple and medium."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let* ((sid (harness-supervisor-plan-test-session))
             (result (harness-supervisor-plan-test-run
                      sid "submit_plan"
                      (harness-supervisor-plan-test-plan-input
                       (harness-supervisor-plan-test-step-input "m" :tier "simple")
                       (harness-supervisor-plan-test-step-input "s" :tier "MEDIUM" :context "fresh")
                       (harness-supervisor-plan-test-step-input "o" :tier "mundane")
                       (harness-supervisor-plan-test-step-input "p" :tier "standard")))))
        (should-not (plist-get result :is-error))
        (should (equal "demo:simple" (plist-get (harness-supervisor-plan-test-step sid "m") :model)))
        (should (equal "demo:medium" (plist-get (harness-supervisor-plan-test-step sid "s") :model)))
        (should (equal "medium" (plist-get (harness-supervisor-plan-test-step sid "s") :tier)))
        (should (equal "demo:simple" (plist-get (harness-supervisor-plan-test-step sid "o") :model)))
        (should (equal "simple" (plist-get (harness-supervisor-plan-test-step sid "o") :tier)))
        (should (equal "demo:medium" (plist-get (harness-supervisor-plan-test-step sid "p") :model)))
        (should (equal "medium" (plist-get (harness-supervisor-plan-test-step sid "p") :tier)))
        ;; The answer says where each step runs, and marks the forks: a
        ;; fresh step is the usual one and goes unmarked.
        (let ((text (plist-get result :content)))
          (should (string-match-p "^- m → demo:simple (simple, fork)$" text))
          (should (string-match-p "^- s → demo:medium (medium)$" text)))
        (should-not (cl-some (lambda (h) (string-match-p "own model" h))
                             (harness-supervisor-plan-test-hints sid)))))))

(ert-deftest harness-supervisor-plan-a-hard-step-is-refused ()
  "The steps of a plan are simple or medium: hard is for retry_step alone.
The supervisor runs on the hard model, so the refusal tells it to break
the step down, and nothing starts."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let* ((sid (harness-supervisor-plan-test-session))
             (result (harness-supervisor-plan-test-run
                      sid "submit_plan"
                      (harness-supervisor-plan-test-plan-input
                       (harness-supervisor-plan-test-step-input "a")
                       (harness-supervisor-plan-test-step-input "b" :tier "HARD")
                       (harness-supervisor-plan-test-step-input "c" :tier "frontier")))))
        (should (plist-get result :is-error))
        (let ((text (plist-get result :content)))
          (should (string-match-p (concat "step b has \"hard\" as its tier: the steps of a plan are"
                                          " simple or medium")
                                  text))
          (should (string-match-p "Break it down until each step is medium at most" text))
          (should (string-match-p "retry_step runs it again on hard" text))
          (should (string-match-p "step c has \"frontier\" as its tier: it must be simple or medium" text))
          (should-not (string-match-p "step a" text)))
        (should-not (harness-supervisor-plan-test-plans sid))
        (should-not harness-supervisor-plan-test--calls)))))

(ert-deftest harness-supervisor-plan-the-setting-overrides-the-model-of-a-tier ()
  "A model in `harness-supervisor-tiers' wins for its tier; the others keep the provider's.
An entry may name a thinking level too, or that alone, and an entry
under a name of old counts for its tier."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((harness-supervisor-tiers '((hard . "demo:opus") (mundane . "demo:haiku")
                                        (medium :model "demo:sonnet" :thinking "low")))
            (sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-run
         sid "submit_plan"
         (harness-supervisor-plan-test-plan-input
          (harness-supervisor-plan-test-step-input "m" :tier "simple")
          (harness-supervisor-plan-test-step-input "s" :tier "medium")))
        (should (equal "demo:haiku" (plist-get (harness-supervisor-plan-test-step sid "m") :model)))
        (should-not (plist-get (harness-supervisor-plan-test-step sid "m") :thinking))
        (should (equal "demo:sonnet" (plist-get (harness-supervisor-plan-test-step sid "s") :model)))
        (should (equal "low" (plist-get (harness-supervisor-plan-test-step sid "s") :thinking)))
        ;; Hard, which only a retry reaches, takes its entry too.
        (should (equal '("demo:opus" nil nil)
                       (harness-test-await (harness-supervisor--tier-model
                                            (harness-call 'session/get sid) "hard"))))))
    ;; A level alone keeps the provider's model.
    (let ((harness-supervisor-tiers '((simple :thinking "high")))
          (sid (harness-supervisor-plan-test-session)))
      (should (equal '("demo:simple" nil "high")
                     (harness-test-await (harness-supervisor--tier-model
                                          (harness-call 'session/get sid) "simple")))))))

(ert-deftest harness-supervisor-plan-a-tier-without-a-model-runs-on-the-supervisors-own ()
  "With no model for a tier the step runs on the supervisor's, and a hint says so."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (harness-supervisor-plan-test-stub-tier-model
       (lambda (_model &optional tier) (and (eq tier 'simple) "demo:simple")))
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-run
         sid "submit_plan"
         (harness-supervisor-plan-test-plan-input
          (harness-supervisor-plan-test-step-input "m" :tier "simple")
          (harness-supervisor-plan-test-step-input "h" :tier "medium")))
        (should (equal "demo:simple" (plist-get (harness-supervisor-plan-test-step sid "m") :model)))
        (should (equal "demo:scripted" (plist-get (harness-supervisor-plan-test-step sid "h") :model)))
        (let ((hint (cl-find-if (lambda (h) (string-match-p "own model" h))
                                (harness-supervisor-plan-test-hints sid))))
          (should hint)
          (should (string-match-p "step h (medium)" hint))
          (should-not (string-match-p "step m" hint))
          (should (string-match-p "demo:scripted" hint))))))
  ;; A provider that fails to answer counts as having no model.
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (harness-supervisor-plan-test-stub-tier-model (lambda (&rest _) (error "No catalogue")))
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-run
         sid "submit_plan"
         (harness-supervisor-plan-test-plan-input (harness-supervisor-plan-test-step-input "m")))
        (should (equal "demo:scripted" (plist-get (harness-supervisor-plan-test-step sid "m") :model)))))))

(defun harness-supervisor-plan-test-define-catalogue (id &optional delay)
  "Register provider ID with a big, a mid and a small model, dearest first.
No `:tiers' names them, so the provider layer ranks them by price, as it
does for a provider that declares none.  DELAY non-nil makes its
catalogue answer that many seconds later, which a plan has to wait for.
Its completions are the demo's script, so the conversation stays
scripted while the models are the provider's own."
  (let ((models (lambda ()
                  (list (list :name "big" :context-window 200000
                              :pricing '(:input 10.0 :output 50.0))
                        (list :name "mid" :context-window 200000
                              :pricing '(:input 3.0 :output 15.0))
                        (list :name "small" :context-window 200000
                              :pricing '(:input 1.0 :output 5.0))))))
    (harness-define-provider id
      :complete #'harness-provider-demo--complete
      :models (if delay
                  (lambda ()
                    (let ((answer (harness-make-promise)))
                      (run-at-time delay nil
                                   (lambda () (harness-resolve answer (funcall models))))
                      answer))
                (lambda () (harness-resolved (funcall models)))))))

(defun harness-supervisor-plan-test-session-on (model &rest plist)
  "Create a supervising session on MODEL, with PLIST's settings, and return its id."
  (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir)
                    :model model plist)
             :id))

(ert-deftest harness-supervisor-plan-the-real-catalogue-decides-what-a-worker-runs-on ()
  "The provider's own catalogue gives each tier its model, and the workers start on it.
Two simple steps share a seed -- one seeded fork between them -- and a
medium step forks the supervisor directly; every worker's model is the
one its tier ranks with, not the supervisor's."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (harness-supervisor-plan-test-real-tiers)
      (harness-supervisor-plan-test-define-catalogue 'tiered)
      (unwind-protect
          (let ((sid (harness-supervisor-plan-test-session-on "tiered:big")))
            (harness-call 'session/usage-add sid '(:input 10 :output 5 :context 7000))
            (harness-supervisor-plan-test-submit
             sid
             (harness-supervisor-plan-test-step-input "m1" :tier "simple")
             (harness-supervisor-plan-test-step-input "m2" :tier "simple")
             (harness-supervisor-plan-test-step-input "h" :tier "medium"))
            (should (equal "tiered:small" (plist-get (harness-supervisor-plan-test-step sid "m1") :model)))
            (should (equal "tiered:small" (plist-get (harness-supervisor-plan-test-step sid "m2") :model)))
            (should (equal "tiered:mid" (plist-get (harness-supervisor-plan-test-step sid "h") :model)))
            (should (equal '("tiered:small" "tiered:small")
                           (mapcar (lambda (args) (nth 1 args))
                                   (harness-supervisor-plan-test-calls 'seed/fork))))
            ;; `session/fork' takes the session id first, then its plist.
            (should (equal '("tiered:mid")
                           (mapcar (lambda (args) (plist-get (cdr args) :model))
                                   (harness-supervisor-plan-test-calls 'session/fork))))
            (should-not (cl-some (lambda (h) (string-match-p "own model" h))
                                 (harness-supervisor-plan-test-hints sid))))
        (harness-provider-unregister 'tiered)))))

(ert-deftest harness-supervisor-plan-waits-for-a-catalogue-that-answers-late ()
  "A provider not listed yet does not cost a step its model: the plan waits for the catalogue.
The lookup once read the empty cache as a provider with no model for the
tier, and ran the step on the supervisor's own, expensive model."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (harness-supervisor-plan-test-real-tiers)
      (harness-supervisor-plan-test-define-catalogue 'slow 0.05)
      (unwind-protect
          (let ((sid (harness-supervisor-plan-test-session-on "slow:big")))
            (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "m"))
            (should (equal "slow:small" (plist-get (harness-supervisor-plan-test-step sid "m") :model)))
            (should-not (cl-some (lambda (h) (string-match-p "own model" h))
                                 (harness-supervisor-plan-test-hints sid))))
        (harness-provider-unregister 'slow)))))

(ert-deftest harness-supervisor-plan-names-the-provider-when-it-has-no-model-for-a-tier ()
  "A catalogue with nothing for a tier runs the step on the supervisor's model, and says why."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (harness-supervisor-plan-test-real-tiers)
      (harness-define-provider 'unpriced
        :complete #'harness-provider-demo--complete
        :models (lambda () (harness-resolved '((:name "only" :context-window 200000)))))
      (unwind-protect
          (let ((sid (harness-supervisor-plan-test-session-on "unpriced:only")))
            (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "m"))
            (should (equal "unpriced:only" (plist-get (harness-supervisor-plan-test-step sid "m") :model)))
            (let ((hint (cl-find-if (lambda (h) (string-match-p "own model" h))
                                    (harness-supervisor-plan-test-hints sid))))
              (should hint)
              (should (string-match-p "step m (simple)" hint))
              (should (string-match-p "unpriced names no simple model" hint))
              (should (string-match-p "unpriced:only" hint))))
        (harness-provider-unregister 'unpriced)))))

;;;; Starting the steps

(defun harness-supervisor-plan-test-submit (sid &rest steps)
  "Run a turn of session SID in which it submits a plan of STEPS, as call-plan.
Return how the turn ended.  A turn the session still runs ends first."
  (harness-supervisor-plan-test-wait-idle sid)
  (setq harness-supervisor-plan-test--plan (apply #'harness-supervisor-plan-test-plan-input steps))
  (harness-supervisor-plan-test-prompt sid "Do the thing"))

(defun harness-supervisor-plan-test-call-node (sid call-id)
  "Return the id of the node of tool call CALL-ID in session SID."
  (plist-get (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-call)
                                          (equal (plist-get n :call-id) call-id)))
                         (harness-call 'session/nodes sid))
             :id))

(ert-deftest harness-supervisor-plan-submitting-records-and-shows-the-plan-and-ends-the-turn ()
  "The plan is stored on the session, shown like the plan tool shows one, and ends the turn."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((sid (harness-supervisor-plan-test-session)))
        (should (eq 'end-turn
                    (harness-supervisor-plan-test-submit
                     sid
                     (harness-supervisor-plan-test-step-input "s1" :tier "medium" :reason "subtle"
                                                              :context "fork")
                     ;; No context: the step is fresh.
                     (harness-supervisor-plan-test-step-input "s2" :after '("s1") :context nil))))
        ;; The turn ended on the tool: the model said nothing after the call.
        (should (= 1 (length harness-supervisor-plan-test--requests)))
        (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))
        (let ((plan (harness-supervisor-plan-test-plan sid)))
          (should (= 1 (length (harness-supervisor-plan-test-plans sid))))
          (should (string-match-p "\\`p-[a-z0-9]+\\'" (plist-get plan :id)))
          (should (equal "The plan" (plist-get plan :title)))
          (should (equal "Do it in **steps**." (plist-get plan :summary)))
          (should (equal "call-plan" (plist-get plan :call-id)))
          (should (numberp (plist-get plan :created)))
          ;; The fork point is the submit_plan call itself.
          (should (equal (harness-supervisor-plan-test-call-node sid "call-plan") (plist-get plan :node)))
          (let ((s1 (harness-supervisor-plan-test-step sid "s1"))
                (s2 (harness-supervisor-plan-test-step sid "s2")))
            (should (equal "Title of s1" (plist-get s1 :title)))
            (should (equal "Do s1." (plist-get s1 :prompt)))
            (should (equal "medium" (plist-get s1 :tier)))
            (should (equal "subtle" (plist-get s1 :reason)))
            (should (equal "fork" (plist-get s1 :context)))
            (should (equal "demo:medium" (plist-get s1 :model)))
            (should (equal "running" (plist-get s1 :state)))
            (should (= 1 (plist-get s1 :attempts)))
            (should-not (plist-get s1 :after))
            (should (equal "fresh" (plist-get s2 :context)))
            (should (equal '("s1") (plist-get s2 :after)))
            (should (equal "pending" (plist-get s2 :state)))
            (should (= 0 (plist-get s2 :attempts)))))
        ;; Shown to the user as a plan: the session's plan, a plan node, a hint.
        (should (equal "Do it in **steps**." (plist-get (harness-call 'session/get sid) :plan)))
        (let ((node (car (harness-supervisor-plan-test-nodes sid 'plan))))
          (should (equal "Do it in **steps**." (plist-get node :content)))
          (should (equal "The plan" (plist-get node :title)))
          (should (equal (plist-get (harness-supervisor-plan-test-plan sid) :id)
                         (plist-get (plist-get node :meta) :plan-id))))
        (should (member "Plan submitted: 2 steps" (harness-supervisor-plan-test-hints sid)))
        ;; The tool answered with one line per step.
        (let ((answer (plist-get (car (harness-supervisor-plan-test-nodes sid 'tool-result)) :output)))
          (should (string-match-p "Plan p-[a-z0-9]+ submitted: 2 steps" answer))
          (should (string-match-p "^- s1 → demo:medium (medium, fork)$" answer))
          (should (string-match-p "^- s2 → demo:simple (simple, after s1)$" answer)))))))

(ert-deftest harness-supervisor-plan-one-step-is-a-hint-of-one-step ()
  "The hint says \"1 step\" for a plan of one."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "only"))
        (should (member "Plan submitted: 1 step" (harness-supervisor-plan-test-hints sid)))))))

(ert-deftest harness-supervisor-plan-fork-steps-on-one-model-fork-through-one-seed ()
  "Two or more fork steps on a model share a seed: the same node, the plan's call."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-call 'session/usage-add sid '(:input 10 :output 5 :context 7000))
        (harness-supervisor-plan-test-submit
         sid
         (harness-supervisor-plan-test-step-input "a")
         (harness-supervisor-plan-test-step-input "b")
         ;; Not ready yet, but a fork step on the model all the same.
         (harness-supervisor-plan-test-step-input "e" :after '("a"))
         ;; Alone on its model: a plain fork.
         (harness-supervisor-plan-test-step-input "c" :tier "medium")
         ;; Fresh steps fork nothing.
         (harness-supervisor-plan-test-step-input "d" :context "fresh"))
        (let* ((node (harness-supervisor-plan-test-call-node sid "call-plan"))
               (limit (harness-tools-agent-context-limit sid t))
               (seeds (harness-supervisor-plan-test-calls 'seed/fork))
               (forks (harness-supervisor-plan-test-calls 'session/fork)))
          (should node)
          (should (> limit harness-subagent-context-limit))
          (should (= 2 (length seeds)))
          (should (equal (list sid "demo:simple" :node node :call-id "call-plan"
                               :name "Step a: Title of a" :context-window-limit limit)
                         (nth 0 seeds)))
          (should (equal (list sid "demo:simple" :node node :call-id "call-plan"
                               :name "Step b: Title of b" :context-window-limit limit)
                         (nth 1 seeds)))
          (should (= 1 (length forks)))
          (should (equal (list sid :node node :call-id "call-plan" :kind 'subagent
                               :model "demo:medium" :name "Step c: Title of c"
                               :context-window-limit limit)
                         (car forks)))
          (should (= 1 (length (harness-supervisor-plan-test-calls 'session/create))))
          (should (equal '("running" "running" "pending" "running" "running")
                         (mapcar (lambda (id) (harness-supervisor-plan-test-state sid id))
                                 '("a" "b" "e" "c" "d")))))))))

(ert-deftest harness-supervisor-plan-a-lone-fork-step-forks-the-supervisor-directly ()
  "One fork step on a model needs no seed; neither does a harness without the module."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "a")
                                             (harness-supervisor-plan-test-step-input "b" :tier "medium"))
        (should-not (harness-supervisor-plan-test-calls 'seed/fork))
        (should (= 2 (length (harness-supervisor-plan-test-calls 'session/fork)))))))
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (harness-unregister-method 'seed/fork)
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "a")
                                             (harness-supervisor-plan-test-step-input "b"))
        (should (= 2 (length (harness-supervisor-plan-test-calls 'session/fork))))))))

(ert-deftest harness-supervisor-plan-a-fresh-step-is-a-new-session-with-the-supervisors-settings ()
  "A fresh worker starts empty in the supervisor's directory, with its settings and a window."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let* ((dir (harness-test-temp-dir))
             (extra (harness-test-temp-dir))
             (sid (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted"
                                           :worktree dir :permission-mode 'auto :thinking "high"
                                           :non-interactive t :allowed-dirs (list extra))
                             :id)))
        (harness-call 'session/usage-add sid '(:input 10 :output 5 :context 7000))
        (harness-supervisor-plan-test-submit
         sid (harness-supervisor-plan-test-step-input "f" :tier "medium" :context "fresh"))
        (let ((args (car (harness-supervisor-plan-test-calls 'session/create)))
              (session (harness-call 'session/get sid)))
          (should (equal (plist-get session :cwd) (plist-get args :cwd)))
          (should (equal dir (plist-get args :worktree)))
          (should (eq 'subagent (plist-get args :kind)))
          (should (equal sid (plist-get args :parent-id)))
          (should (equal "demo:medium" (plist-get args :model)))
          (should (equal "Step f: Title of f" (plist-get args :name)))
          (should (eq 'auto (plist-get args :permission-mode)))
          (should (equal "high" (plist-get args :thinking)))
          (should (eq t (plist-get args :non-interactive)))
          (should (equal (list extra) (plist-get args :allowed-dirs)))
          (should (plist-member args :host))
          ;; Fresh: the cap, not the conversation it does not inherit.
          (should (eql harness-subagent-context-limit (plist-get args :context-window-limit)))
          (should (< (plist-get args :context-window-limit) (harness-tools-agent-context-limit sid t))))))))

(ert-deftest harness-supervisor-plan-a-step-with-no-context-is-fresh ()
  "A step that names no context is fresh: it is stored so, and its worker is a new session.
Only a step that says fork forks the supervisor, and the answer to the
plan marks that one; a fresh step is the usual one and goes unmarked."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let* ((sid (harness-supervisor-plan-test-session))
             (result (harness-supervisor-plan-test-run
                      sid "submit_plan"
                      (harness-supervisor-plan-test-plan-input
                       (harness-supervisor-plan-test-step-input "a" :context nil)
                       (harness-supervisor-plan-test-step-input "b" :context "fork")
                       (harness-supervisor-plan-test-step-input "c" :context "fresh")))))
        (should-not (plist-get result :is-error))
        (should (equal '("fresh" "fork" "fresh")
                       (mapcar (lambda (id) (plist-get (harness-supervisor-plan-test-step sid id) :context))
                               '("a" "b" "c"))))
        ;; The workers of a and c are new sessions; only b forks the supervisor.
        (should (equal '("Step a: Title of a" "Step c: Title of c")
                       (mapcar (lambda (args) (plist-get args :name))
                               (harness-supervisor-plan-test-calls 'session/create))))
        (should (equal '("Step b: Title of b")
                       (mapcar (lambda (args) (plist-get (cdr args) :name))
                               (harness-supervisor-plan-test-calls 'session/fork))))
        (should-not (harness-supervisor-plan-test-calls 'seed/fork))
        (let ((answer (plist-get result :content)))
          (should (string-match-p "^- a → demo:simple (simple)$" answer))
          (should (string-match-p "^- b → demo:simple (simple, fork)$" answer))
          (should (string-match-p "^- c → demo:simple (simple)$" answer))
          (should-not (string-match-p "fresh" answer)))))))

(defun harness-supervisor-plan-test-tier-thinking (levels)
  "Make every provider's tiers name LEVELS, an alist from a tier to its level.
It stands in for `provider/tier-thinking', as DeepSeek's tiers name
low, high and max; a tier LEVELS leaves out names none."
  (harness-register-method 'provider/tier-thinking
                           (lambda (_model &optional tier) (cdr (assq tier levels)))))

(ert-deftest harness-supervisor-plan-a-worker-thinks-at-the-level-of-its-tier ()
  "The level the provider's tier names is the one every kind of worker starts at.
The step keeps it, and the answer to the plan says it."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (harness-supervisor-plan-test-tier-thinking '((simple . "low") (medium . "high")))
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-submit
         sid (harness-supervisor-plan-test-step-input "a")
         ;; Same model, and forked too: both share a seed.
         (harness-supervisor-plan-test-step-input "b")
         ;; Alone on its model: forked directly.
         (harness-supervisor-plan-test-step-input "c" :tier "medium")
         (harness-supervisor-plan-test-step-input "f" :context "fresh"))
        (should (= 2 (length (harness-supervisor-plan-test-calls 'seed/fork))))
        ;; The calls carry positional arguments first (the session forked
        ;; and, for a seed, its model), so the plist follows them.
        (dolist (call (harness-supervisor-plan-test-calls 'seed/fork))
          (should (equal "low" (plist-get (cddr call) :thinking))))
        (dolist (call (harness-supervisor-plan-test-calls 'session/fork))
          (should (equal "high" (plist-get (cdr call) :thinking))))
        (should (equal "low" (plist-get (car (harness-supervisor-plan-test-calls 'session/create))
                                        :thinking)))
        (should (equal "low" (plist-get (harness-supervisor-plan-test-step sid "a") :thinking)))
        (should (equal "high" (plist-get (harness-supervisor-plan-test-step sid "c") :thinking)))
        (let ((answer (plist-get (car (harness-supervisor-plan-test-nodes sid 'tool-result)) :output)))
          (should (string-match-p "^- c → demo:medium (medium, high thinking, fork)$" answer))
          (should (string-match-p "^- f → demo:simple (simple, low thinking)$" answer)))))))

(ert-deftest harness-supervisor-plan-the-worker-level-is-the-worker-models-providers ()
  "A worker takes the level its own model's provider names, not its supervisor's provider."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      ;; DeepSeek names a level for its simple tier; the demo provider none.
      (harness-register-method 'provider/tier-thinking
                               (lambda (model &optional tier)
                                 (and (string-prefix-p "deepseek:" model) (eq tier 'simple) "low")))
      (let ((harness-supervisor-tiers '((simple . "deepseek:deepseek-flash"))))
        (let ((sid (harness-supervisor-plan-test-session)))
          (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "a"))
          ;; A session/fork call leads with the session forked and its plist follows.
          (let ((args (cdr (car (harness-supervisor-plan-test-calls 'session/fork)))))
            (should (equal "deepseek:deepseek-flash" (plist-get args :model)))
            (should (equal "low" (plist-get args :thinking)))))))))

(ert-deftest harness-supervisor-plan-no-worker-level-leaves-the-supervisors-own ()
  "A tier that names no level leaves its workers at the supervisor's level.
Fitted to what the worker's model offers: the demo model thinks at low
or high, so the worker of a supervisor at max thinks at high."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((sid (harness-supervisor-plan-test-session :thinking "high")))
        (harness-supervisor-plan-test-submit
         sid (harness-supervisor-plan-test-step-input "c" :tier "medium")
         (harness-supervisor-plan-test-step-input "f" :context "fresh"))
        ;; A fork inherits it (no `:thinking' passed), a fresh worker is told it.
        (should-not (plist-member (cdr (car (harness-supervisor-plan-test-calls 'session/fork)))
                                  :thinking))
        (should (equal "high" (plist-get (car (harness-supervisor-plan-test-calls 'session/create))
                                         :thinking)))
        (should-not (plist-get (harness-supervisor-plan-test-step sid "c") :thinking)))))
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((harness-supervisor-tiers '((medium . "demo:scripted")))
            (sid (harness-supervisor-plan-test-session :thinking "max")))
        (harness-supervisor-plan-test-submit
         sid (harness-supervisor-plan-test-step-input "c" :tier "medium")
         (harness-supervisor-plan-test-step-input "f" :tier "medium" :context "fresh"))
        (should (equal "high" (plist-get (cdr (car (harness-supervisor-plan-test-calls 'session/fork)))
                                         :thinking)))
        (should (equal "high" (plist-get (car (harness-supervisor-plan-test-calls 'session/create))
                                         :thinking)))))))

(ert-deftest harness-supervisor-plan-a-seeded-worker-gets-the-level-itself ()
  "A worker forked through a seed thinks at the worker level, not the seed's or the supervisor's."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-tier-thinking '((simple . "low")))
    (let ((sid (harness-supervisor-plan-test-session :thinking "high")))
      (harness-supervisor-plan-test-submit
       sid (harness-supervisor-plan-test-step-input "a")
       (harness-supervisor-plan-test-step-input "b"))
      (harness-supervisor-plan-test-wait-state sid "a" "done")
      (let* ((step (harness-supervisor-plan-test-step sid "a"))
             (worker (plist-get step :session)))
        (should (harness-call 'session/exists-p worker))
        ;; The plan has two fork steps on one model, so the workers fork a
        ;; seed, and it is the worker that takes the level, not the seed.
        (should (harness-call 'seed/list sid))
        (should (equal "low" (plist-get (harness-call 'session/get worker) :thinking)))))))

(ert-deftest harness-supervisor-plan-a-fresh-step-is-hands-on-when-the-supervisor-is-interactive ()
  "A supervisor that is not non-interactive makes workers that are not, explicitly."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-submit
         sid (harness-supervisor-plan-test-step-input "f" :context "fresh"))
        (should (eq :false (plist-get (car (harness-supervisor-plan-test-calls 'session/create))
                                      :non-interactive)))))))

(ert-deftest harness-supervisor-plan-no-cap-means-no-limit-is-passed ()
  "With `harness-subagent-context-limit' nil a worker keeps the window it would have."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((harness-subagent-context-limit nil)
            (sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-submit
         sid (harness-supervisor-plan-test-step-input "a")
         (harness-supervisor-plan-test-step-input "b")
         (harness-supervisor-plan-test-step-input "c" :tier "medium")
         (harness-supervisor-plan-test-step-input "d" :context "fresh"))
        (dolist (call (append (harness-supervisor-plan-test-calls 'seed/fork)
                              (harness-supervisor-plan-test-calls 'session/fork)
                              (harness-supervisor-plan-test-calls 'session/create)))
          (should-not (plist-member call :context-window-limit)))
        (should (= 4 (length (append (harness-supervisor-plan-test-calls 'seed/fork)
                                     (harness-supervisor-plan-test-calls 'session/fork)
                                     (harness-supervisor-plan-test-calls 'session/create)))))))))

(ert-deftest harness-supervisor-plan-a-workers-context-cap-shows-in-its-transcript ()
  "A worker's window is capped as a sub-agent's is, and a hint in its transcript says so.
The cap is never silent: a fork's hint says what it starts with, a fresh
worker's the cap alone."
  (harness-supervisor-plan-test-with
    (let ((harness-subagent-context-limit 256000)
          (sid (harness-supervisor-plan-test-session)))
      (harness-call 'session/usage-add sid '(:input 10 :output 5 :context 90000))
      (harness-supervisor-plan-test-submit
       sid (harness-supervisor-plan-test-step-input "a")
       (harness-supervisor-plan-test-step-input "f" :context "fresh"))
      (harness-supervisor-plan-test-wait-state sid "a" "done")
      (harness-supervisor-plan-test-wait-state sid "f" "done")
      (let ((fork (plist-get (harness-supervisor-plan-test-step sid "a") :session))
            (fresh (plist-get (harness-supervisor-plan-test-step sid "f") :session))
            (limit (harness-tools-agent-context-limit sid t)))
        (should (= limit (plist-get (harness-call 'session/get fork) :context-window-limit)))
        (should (member (format "Context window capped at %s tokens: the 90k it starts with plus 256k of its own, as a sub-agent's is (harness-subagent-context-limit)"
                                (harness-tools-agent--tokens limit))
                        (harness-supervisor-plan-test-hints fork)))
        (should (= 256000 (plist-get (harness-call 'session/get fresh) :context-window-limit)))
        (should (equal '("Context window capped at 256k tokens, as a sub-agent's is (harness-subagent-context-limit)")
                       (harness-supervisor-plan-test-hints fresh))))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-no-cap-means-no-cap-hint ()
  "Without `harness-subagent-context-limit' a worker's transcript says nothing of a cap."
  (harness-supervisor-plan-test-with
    (let ((harness-subagent-context-limit nil)
          (sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-submit
       sid (harness-supervisor-plan-test-step-input "a")
       (harness-supervisor-plan-test-step-input "f" :context "fresh"))
      (harness-supervisor-plan-test-wait-state sid "a" "done")
      (harness-supervisor-plan-test-wait-state sid "f" "done")
      (dolist (id '("a" "f"))
        (let ((worker (plist-get (harness-supervisor-plan-test-step sid id) :session)))
          (should-not (cl-find-if (lambda (h) (string-prefix-p "Context window capped" h))
                                  (harness-supervisor-plan-test-hints worker)))))
      (harness-supervisor-plan-test-wait-idle sid))))

;;;; Workers at work

(defun harness-supervisor-plan-test-user-texts (sid)
  "Return the texts of the user messages of session SID, oldest first."
  (mapcar (lambda (n) (plist-get n :content)) (harness-supervisor-plan-test-nodes sid 'user)))

(ert-deftest harness-supervisor-plan-a-fork-step-runs-in-a-fork-of-the-supervisor-and-is-done ()
  "The worker forks the supervisor at the plan's call, is told its job, and its reply is the result."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session :name "The boss")))
      (harness-supervisor-plan-test-behave "s1" "Added the flag.")
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "s1"))
      (harness-supervisor-plan-test-wait-state sid "s1" "done")
      (let* ((step (harness-supervisor-plan-test-step sid "s1"))
             (wid (plist-get step :session))
             (worker (harness-call 'session/get wid)))
        (should (equal "Added the flag." (plist-get step :result)))
        (should-not (plist-get step :error))
        (should (= 1 (plist-get step :attempts)))
        (should (eq 'subagent (plist-get worker :kind)))
        (should (equal sid (plist-get worker :parent-id)))
        (should (equal "demo:simple" (plist-get worker :model)))
        (should (equal "Step s1: Title of s1" (plist-get worker :name)))
        (should (equal (plist-get (harness-supervisor-plan-test-plan sid) :node) (plist-get worker :fork-node)))
        ;; A worker works; it does not plan: nothing governs it, and it has no tool of the supervisor's.
        (should-not (harness-call 'supervisor/active-p wid))
        (should-not (cl-intersection '("submit_plan" "retry_step" "no_plan_needed")
                                     (mapcar (lambda (spec) (plist-get spec :name)) (harness-call 'tools/list wid))
                                     :test #'equal))
        ;; It has the supervisor's conversation up to the plan, and the call that made it answered.
        (should (member "Do the thing" (harness-supervisor-plan-test-user-texts wid)))
        (let ((answer (cl-find "call-plan" (harness-supervisor-plan-test-nodes wid 'tool-result)
                               :key (lambda (n) (plist-get n :call-id)) :test #'equal)))
          (should answer)
          (should (string-match-p "You are the sub-agent this call started" (plist-get answer :output))))
        ;; Its task is the harness's message for the supervisor, with the step in it.
        (let* ((task (car (last (harness-supervisor-plan-test-nodes wid 'user))))
               (text (plist-get task :content)))
          (should (equal (list :kind 'session :id sid :name "The boss") (harness-node-sender task)))
          (should (string-match-p "\\`You are now a worker for one step of the supervisor's plan, not the supervisor" text))
          (should (string-match-p "full tool set" text))
          (should (string-match-p "rules and reminders earlier in this conversation .* do not apply to you" text))
          (should (string-match-p (concat "do the other steps, some at the same time in the same working tree,"
                                          " so keep to your step's files\\.")
                                  text))
          (should (string-match-p "^## Step s1: Title of s1\n\nDo s1\\.$" text))
          (should (string-match-p (concat "Do the step, then verify it\\. End with a short report of what you changed,"
                                          " how you checked it, and anything the other steps need to know\\."
                                          " Do not commit unless the step says so\\.\\'")
                                  text))
          (should-not (string-match-p "What the steps before this one reported" text))
          ;; The fork has the plan's own call in its conversation: the message does not copy it.
          (should-not (string-match-p "## The plan" text))))
      ;; The supervisor got a hint, then the report that the plan finished, in a turn of its own.
      (should (member "Step s1 done on demo:simple" (harness-supervisor-plan-test-hints sid)))
      (let ((reports (harness-supervisor-plan-test-wait-reports sid 1)))
        (should (= 1 (length reports)))
        (should (string-match-p "plan p-[a-z0-9]+ (The plan) finished\\. Its one step is done" (car reports))))
      (harness-supervisor-plan-test-wait-idle sid)
      (should-not (harness-call 'agent/outstanding sid))
      (should (zerop (hash-table-count harness-supervisor--live))))))

(ert-deftest harness-supervisor-plan-a-fresh-step-runs-in-a-session-that-starts-empty ()
  "A fresh worker is told it starts without the conversation, and does not have it."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-submit
       sid (harness-supervisor-plan-test-step-input "f" :context "fresh" :tier "medium"))
      (harness-supervisor-plan-test-wait-state sid "f" "done")
      (let* ((wid (plist-get (harness-supervisor-plan-test-step sid "f") :session))
             (worker (harness-call 'session/get wid))
             (texts (harness-supervisor-plan-test-user-texts wid)))
        (should (eq 'subagent (plist-get worker :kind)))
        (should (equal sid (plist-get worker :parent-id)))
        (should (equal "demo:medium" (plist-get worker :model)))
        (should-not (plist-get worker :fork-node))
        (should (= 1 (length texts)))
        (should (string-match-p "\\`You are a worker for one step of a plan that a supervisor made" (car texts)))
        (should (string-match-p "start without the supervisor's conversation" (car texts)))
        (should (string-match-p "some at the same time in the same working tree, so keep to your step's files\\."
                                (car texts)))
        (should (string-match-p "^## Step f: Title of f\n\nDo f\\.$" (car texts)))
        (should (string-match-p (concat "Do the step, then verify it\\. End with a short report of what you changed,"
                                        " how you checked it, and anything the other steps need to know\\."
                                        " Do not commit unless the step says so\\.\\'")
                                (car texts)))
        (should-not (member "Do the thing" texts))))))

(ert-deftest harness-supervisor-plan-a-fresh-worker-is-given-the-plan-and-the-other-steps ()
  "A fresh worker has no conversation, so its message holds the plan.
After the opening come the plan's summary and the worker's own step,
then one line for each other step, with the steps it waits for, then
what the steps before it reported, and the closing.  A fork step is one
of the others like any, and the worker's own step is not."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" "Added the flag.")
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "s1" :context nil)
       (harness-supervisor-plan-test-step-input "s2" :context nil :after '("s1"))
       (harness-supervisor-plan-test-step-input "s3" :context "fork" :after '("s1" "s2")))
      (harness-supervisor-plan-test-wait-state sid "s3" "done")
      (let ((first (plist-get (harness-supervisor-plan-test-step-request "s1") :text))
            (second (plist-get (harness-supervisor-plan-test-step-request "s2") :text)))
        (should (string-prefix-p "You are a worker for one step of a plan that a supervisor made." second))
        (should (string-match-p
                 (concat "so keep to your step's files\\.\n"
                         "\n## The plan\n\nDo it in \\*\\*steps\\*\\*\\.\n"
                         "\n## Step s2: Title of s2\n\nDo s2\\.\n"
                         "\n## The other steps\n\n- s1: Title of s1\n- s3: Title of s3 (after s1, s2)\n"
                         "\n## What the steps before this one reported\n\n### s1 (Title of s1)\nAdded the flag\\.\n"
                         "\nDo the step, then verify it\\.")
                 second))
        (should-not (string-match-p "^- s2:" second))
        ;; The first has nothing before it, and one line for each step after.
        (should (string-match-p
                 (concat "\n## Step s1: Title of s1\n\nDo s1\\.\n"
                         "\n## The other steps\n\n- s2: Title of s2 (after s1)\n- s3: Title of s3 (after s1, s2)\n"
                         "\nDo the step, then verify it\\.")
                 first))
        (should-not (string-match-p "What the steps before this one reported" first)))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-plan-of-one-step-has-no-other-steps ()
  "With no other step to tell of, a worker's message has no section for them.
It has the plan's summary all the same."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "only" :context nil))
      (harness-supervisor-plan-test-wait-state sid "only" "done")
      (let ((text (plist-get (harness-supervisor-plan-test-step-request "only") :text)))
        (should (string-match-p
                 (concat "\n\n## The plan\n\nDo it in \\*\\*steps\\*\\*\\.\n"
                         "\n## Step only: Title of only\n\nDo only\\.\n"
                         "\nDo the step, then verify it\\.")
                 text))
        (should-not (string-match-p "^## The other steps" text)))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-whole-fork-is-given-neither-the-plan-nor-the-other-steps ()
  "A fork that keeps the whole conversation has the plan's own call in it.
Its message holds its step alone, whether it forked the supervisor
directly or through a seed; a fresh worker of the same plan is given
the plan and the other steps."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-submit
       sid
       ;; a and d share a seed; b forks the supervisor directly.
       (harness-supervisor-plan-test-step-input "a")
       (harness-supervisor-plan-test-step-input "d")
       (harness-supervisor-plan-test-step-input "b" :tier "medium")
       (harness-supervisor-plan-test-step-input "f" :context nil))
      (dolist (id '("a" "b" "d" "f"))
        (harness-supervisor-plan-test-wait-state sid id "done"))
      (should (harness-call 'seed/list sid))
      (should (equal (plist-get (car (harness-call 'seed/list sid)) :id)
                     (harness-supervisor-plan-test-forked-from
                      (plist-get (harness-supervisor-plan-test-step sid "a") :session))))
      (should (equal sid (harness-supervisor-plan-test-forked-from
                          (plist-get (harness-supervisor-plan-test-step sid "b") :session))))
      (dolist (id '("a" "b" "d"))
        (let ((text (plist-get (harness-supervisor-plan-test-step-request id) :text)))
          (should (string-match-p "You are now a worker for one step of the supervisor's plan" text))
          (should (string-match-p
                   (format "\n\n## Step %s: Title of %s\n\nDo %s\\.\n\nDo the step, then verify it" id id id)
                   text))
          (should-not (string-match-p "## The plan\\|## The other steps" text))))
      (let ((text (plist-get (harness-supervisor-plan-test-step-request "f") :text)))
        (should (string-match-p "\n## The plan\n\nDo it in \\*\\*steps\\*\\*\\." text))
        (should (string-match-p "\n## The other steps\n\n- a: Title of a\n- d: Title of d\n- b: Title of b\n" text)))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-the-other-steps-leave-out-the-superseded-ones ()
  "A step a later plan superseded is not one of the other steps.
It never runs, and listing it would send a worker to wait for work that
is not coming.  A step of the later plan is not one either: it is
another plan's."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "a" 'error "Done again.")
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "a" :context nil)
       (harness-supervisor-plan-test-step-input "b" :context nil :after '("a"))
       (harness-supervisor-plan-test-step-input "c" :context nil))
      (harness-supervisor-plan-test-wait-state sid "a" "failed")
      (harness-supervisor-plan-test-wait-state sid "c" "done")
      (harness-supervisor-plan-test-wait-reports sid 1)
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "z" :context nil))
      (harness-supervisor-plan-test-wait-state sid "z" "done" 1)
      (should (equal "superseded" (harness-supervisor-plan-test-state sid "b" 0)))
      (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "a") :is-error))
      (harness-supervisor-plan-test-wait-state sid "a" "done" 0)
      (let ((first (plist-get (harness-supervisor-plan-test-step-request "a" 0) :text))
            (again (plist-get (harness-supervisor-plan-test-step-request "a" 1) :text)))
        ;; Before the later plan, b was one of the others.
        (should (string-match-p "\n## The other steps\n\n- b: Title of b (after a)\n- c: Title of c\n" first))
        (should (string-match-p "\n## The other steps\n\n- c: Title of c\n\n## The previous attempt" again))
        (should-not (string-match-p "- b:\\|- z:" again)))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-step-waits-for-the-steps-it-follows-and-gets-their-results ()
  "Step 2 starts when step 1 is done, and its prompt has what step 1 reported."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" '(reply "Added the --verbose flag to cli.el." 0.6))
      (harness-supervisor-plan-test-behave "s2" "Documented it.")
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "s1")
       (harness-supervisor-plan-test-step-input "s2" :after '("s1")))
      ;; Step 1 works, step 2 waits, and nothing started it meanwhile.
      (should (equal "running" (harness-supervisor-plan-test-state sid "s1")))
      (should (equal "pending" (harness-supervisor-plan-test-state sid "s2")))
      (should (equal "Supervisor plan: 1 step running, 1 waiting" (harness-call 'agent/outstanding sid)))
      (harness-supervisor-plan-test-wait-state sid "s2" "done")
      (should-not (harness-supervisor-plan-test-step-request "s2" 1))
      (let ((s1 (harness-supervisor-plan-test-step-request "s1"))
            (s2 (harness-supervisor-plan-test-step-request "s2")))
        (should s1)
        (should s2)
        ;; The provider heard of step 2 after step 1.
        (should (< (cl-position s1 (reverse harness-supervisor-plan-test--requests))
                   (cl-position s2 (reverse harness-supervisor-plan-test--requests))))
        (let ((text (plist-get s2 :text)))
          (should (string-match-p "^## Step s2: Title of s2\n\nDo s2\\.$" text))
          (should (string-match-p "## What the steps before this one reported\n\n### s1 (Title of s1)\nAdded the --verbose flag to cli\\.el\\." text))))
      (should-not (plist-get (harness-supervisor-plan-test-step-request "s1") :nope)))))

(ert-deftest harness-supervisor-plan-results-are-cut-to-size ()
  "A reply is kept up to about 4000 characters, and repeated to a later step up to 2000."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session))
          (long (concat "START " (make-string 6000 ?x) " END")))
      (harness-supervisor-plan-test-behave "s1" long)
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "s1")
       (harness-supervisor-plan-test-step-input "s2" :after '("s1")))
      (harness-supervisor-plan-test-wait-state sid "s2" "done")
      (let ((result (plist-get (harness-supervisor-plan-test-step sid "s1") :result)))
        (should (<= (length result) 4000))
        (should (string-prefix-p "START " result))
        (should (string-suffix-p " END" result))
        (should (string-match-p "…" result)))
      (let ((text (plist-get (harness-supervisor-plan-test-step-request "s2") :text)))
        (should (string-match-p "START " text))
        (should (string-match-p " END" text))
        (should (< (length text) 4500))))))

(ert-deftest harness-supervisor-plan-forks-on-one-model-run-through-a-real-seed ()
  "Two fork steps on a model share the seed that `seed/fork' makes at the plan's call."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "a")
       (harness-supervisor-plan-test-step-input "b"))
      (harness-supervisor-plan-test-wait-state sid "a" "done")
      (harness-supervisor-plan-test-wait-state sid "b" "done")
      (let* ((plan (harness-supervisor-plan-test-plan sid))
             (seeds (harness-call 'seed/list sid))
             (a (harness-call 'session/get (plist-get (harness-supervisor-plan-test-step sid "a") :session)))
             (b (harness-call 'session/get (plist-get (harness-supervisor-plan-test-step sid "b") :session))))
        (should (= 1 (length seeds)))
        (should (equal (plist-get plan :node) (plist-get (car seeds) :node)))
        (should (equal "demo:simple" (plist-get (car seeds) :model)))
        (should (equal (plist-get (car seeds) :id) (plist-get a :parent-id)))
        (should (equal (plist-get (car seeds) :id) (plist-get b :parent-id)))
        (should (equal "Step a: Title of a" (plist-get a :name)))
        (should (equal "Step b: Title of b" (plist-get b :name)))
        (should (eq 'subagent (plist-get a :kind)))
        (should (equal "demo:simple" (plist-get a :model)))))))

(ert-deftest harness-supervisor-plan-the-seed-preamble-opens-a-workers-first-message ()
  "What `seed/fork' asks a fork's first message to say goes before the opening."
  (harness-supervisor-plan-test-with
    (let* ((sid (harness-supervisor-plan-test-session))
           (real (harness-method-fn (gethash 'seed/fork harness--methods))))
      (harness-register-method
       'seed/fork
       (lambda (&rest args)
         (harness-then (apply real args)
                       (lambda (fork) (plist-put (copy-sequence fork) :preamble "Your directory is /elsewhere.")))))
      (harness-supervisor-plan-test-submit sid
                                           (harness-supervisor-plan-test-step-input "a")
                                           (harness-supervisor-plan-test-step-input "b"))
      (harness-supervisor-plan-test-wait-state sid "a" "done")
      (should (string-prefix-p "Your directory is /elsewhere.\n\nYou are now a worker"
                               (plist-get (harness-supervisor-plan-test-step-request "a") :text))))))

;;;; When a step does not get done

(ert-deftest harness-supervisor-plan-a-report-waits-for-a-turn-that-a-tool-is-ending ()
  "A tool that ends the turn (hand_in) closes the turn to steering: reports wait for its end."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session :ext '(:supervisor :false))))
      (let ((turn (harness-call 'agent/prompt sid "Hold on")))
        (harness-test-wait (lambda () (harness-call 'agent/running sid)) 10 "the turn")
        ;; Not ending: the report steers the turn.
        (harness-supervisor--send sid "Supervisor report: early")
        (should-not (gethash sid harness-supervisor--held))
        ;; A tool's result ends the turn: from now on a report would be lost with it.
        (harness-emit 'tools/finished sid '(:id "c-1") '(:content "Handed in." :is-error nil :end-turn t))
        (should (gethash sid harness-supervisor--ending))
        (harness-supervisor--send sid "Supervisor report: late")
        (should (equal '("Supervisor report: late") (gethash sid harness-supervisor--held)))
        (should (equal "Supervisor plan: a report to deliver" (harness-call 'agent/outstanding sid)))
        (harness-test-await turn 10))
      ;; The turn is over: the held report goes out, as a turn of its own.
      (harness-test-wait (lambda () (and (not (gethash sid harness-supervisor--held))
                                         (cl-find "Supervisor report: late" harness-supervisor-plan-test--requests
                                                  :key (lambda (r) (plist-get r :text)) :test #'equal)))
                         10 "the held report to go out")
      (harness-supervisor-plan-test-wait-idle sid)
      (should-not (gethash sid harness-supervisor--ending))
      (should-not (harness-call 'agent/outstanding sid))
      (should (member "Supervisor report: late"
                      (mapcar (lambda (n) (plist-get n :content)) (harness-supervisor-plan-test-nodes sid 'user)))))))

(ert-deftest harness-supervisor-plan-held-reports-are-queued-after-a-turn-that-did-not-end-well ()
  "After a turn the user stopped, held reports wait for their next message instead of starting one."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session :ext '(:supervisor :false))))
      (let ((turn (harness-call 'agent/prompt sid "Hold on")))
        (harness-test-wait (lambda () (harness-call 'agent/running sid)) 10 "the turn")
        (puthash sid t harness-supervisor--ending)
        (harness-supervisor--send sid "Supervisor report: late")
        (harness-supervisor--send sid "Supervisor report: later")
        (harness-call 'agent/cancel sid)
        (harness-test-await turn 10))
      (harness-test-wait (lambda () (plist-get (harness-call 'session/get sid) :queue)) 10 "the queue")
      (let ((queue (plist-get (harness-call 'session/get sid) :queue)))
        (should (= 1 (length queue)))
        (should (equal "Supervisor report: late\n\nSupervisor report: later" (plist-get (car queue) :text))))
      (should-not (harness-call 'agent/running sid))
      (should-not (gethash sid harness-supervisor--held)))))

(ert-deftest harness-supervisor-plan-a-worker-that-hits-its-output-limit-is-done ()
  "A turn that ended at the model's output limit did its step as far as it could."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave
       "s1" '(events (:type text :delta "Most of it, and then") (:type done :stop-reason max-tokens)))
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "s1"))
      (harness-supervisor-plan-test-wait-state sid "s1" "done")
      (should (equal "Most of it, and then" (plist-get (harness-supervisor-plan-test-step sid "s1") :result)))
      (should-not (plist-get (harness-supervisor-plan-test-step sid "s1") :error)))))

(defun harness-supervisor-plan-test-failure-fixture (sid)
  "Submit, as SID, a plan where s1 fails, s2 follows it, and s3 goes its own way.
Step s4 waits for s2 and s3."
  (harness-supervisor-plan-test-behave "s1" 'error)
  (harness-supervisor-plan-test-behave "s3" 'hold)
  (harness-supervisor-plan-test-submit
   sid
   (harness-supervisor-plan-test-step-input "s1" :prompt "Make the parser strict.")
   (harness-supervisor-plan-test-step-input "s2" :after '("s1"))
   (harness-supervisor-plan-test-step-input "s3" :tier "medium")
   (harness-supervisor-plan-test-step-input "s4" :after '("s2" "s3"))))

(ert-deftest harness-supervisor-plan-a-failed-step-holds-its-dependants-and-tells-the-supervisor ()
  "One message for the failure: the step, its tier and model, why, what is held, and the way on."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-failure-fixture sid)
      (harness-supervisor-plan-test-wait-state sid "s1" "failed")
      (let ((reports (harness-supervisor-plan-test-wait-reports sid 1)))
        (harness-supervisor-plan-test-wait-idle sid)
        (should (= 1 (length reports)))
        (let ((text (car reports))
              (step (harness-supervisor-plan-test-step sid "s1")))
          (should (equal "the worker's turn ended with error: boom" (plist-get step :error)))
          (should (string-prefix-p "Supervisor report: step s1 (Title of s1) failed.\n" text))
          (should (string-match-p "tier simple, model demo:simple (attempt 1)" text))
          (should (string-match-p "Why: the worker's turn ended with error: boom" text))
          (should (string-match-p (format "session %s" (plist-get step :session)) text))
          (should (string-match-p "Held on it, pending until it is done: s2 (Title of s2), s4 (Title of s4)\\." text))
          (should (string-match-p "Still running: s3" text))
          (should (string-match-p "retry_step s1 (on a higher tier" text))
          (should (string-match-p "a new plan with submit_plan" text))
          (should (string-match-p "ask the user" text))))
      ;; The held steps wait, and are not what the task would wait for.
      (should (equal "pending" (harness-supervisor-plan-test-state sid "s2")))
      (should (equal "pending" (harness-supervisor-plan-test-state sid "s4")))
      (should (equal "Supervisor plan: 1 step running" (harness-call 'agent/outstanding sid)))
      ;; Deleting the supervisor cancels the worker that is still working.
      (let ((worker (plist-get (harness-supervisor-plan-test-step sid "s3") :session)))
        (should (harness-call 'agent/running worker))
        (harness-call 'session/delete sid)
        (harness-test-wait (lambda () (not (harness-call 'agent/running worker))) 10 "the worker to stop")
        (should (zerop (hash-table-count harness-supervisor--live)))))))

(ert-deftest harness-supervisor-plan-steps-held-behind-a-failure-are-not-outstanding ()
  "With only held steps left nothing is outstanding: the supervisor must decide."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" 'error)
      (harness-supervisor-plan-test-submit sid
                                           (harness-supervisor-plan-test-step-input "s1")
                                           (harness-supervisor-plan-test-step-input "s2" :after '("s1")))
      (harness-supervisor-plan-test-wait-state sid "s1" "failed")
      (harness-supervisor-plan-test-wait-reports sid 1)
      (harness-supervisor-plan-test-wait-idle sid)
      (should (equal "pending" (harness-supervisor-plan-test-state sid "s2")))
      (should-not (harness-call 'agent/outstanding sid))
      ;; The filter leaves what other handlers said alone.
      (should (equal "other" (harness-supervisor--outstanding "other" sid)))
      (should (equal "other" (harness-supervisor--outstanding "other" "no-such-session"))))))

(ert-deftest harness-supervisor-plan-retrying-on-a-higher-tier-releases-the-dependants ()
  "retry_step runs the step on a new worker; when it is done the steps held on it start."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session))
          (first-worker nil))
      (setq harness-supervisor-plan-test--on-report
            (lambda (text)
              (when (string-match-p "step s1 .* failed" text)
                (harness-supervisor-plan-test-call
                 "retry_step" '(:step "s1" :tier "hard" :reason "mundane was not enough"
                                :prompt "The first attempt failed with boom.")))))
      (harness-supervisor-plan-test-behave "s1" 'error "Fixed s1.")
      (harness-supervisor-plan-test-submit sid
                                           (harness-supervisor-plan-test-step-input "s1")
                                           (harness-supervisor-plan-test-step-input "s2" :after '("s1")))
      ;; Too quick to catch it failed: the supervisor retries it at once.
      (harness-test-wait (lambda () (harness-supervisor-plan-test-step-request "s1" 1)) 15 "the retry")
      (setq first-worker (plist-get (harness-supervisor-plan-test-step-request "s1" 0) :session))
      (harness-supervisor-plan-test-wait-state sid "s2" "done")
      (let ((s1 (harness-supervisor-plan-test-step sid "s1"))
            (s2 (harness-supervisor-plan-test-step sid "s2")))
        (should (equal "done" (plist-get s1 :state)))
        (should (= 2 (plist-get s1 :attempts)))
        (should (equal "hard" (plist-get s1 :tier)))
        (should (equal "demo:hard" (plist-get s1 :model)))
        (should (equal "mundane was not enough" (plist-get s1 :reason)))
        (should (equal "Fixed s1." (plist-get s1 :result)))
        (should-not (plist-get s1 :error))
        (should-not (equal first-worker (plist-get s1 :session)))
        (should (string-suffix-p "\n\nNotes for attempt 2: The first attempt failed with boom." (plist-get s1 :prompt)))
        (should (string-prefix-p "Do s1." (plist-get s1 :prompt)))
        ;; The second attempt ran on the higher tier's model, with the notes.
        (let ((again (harness-supervisor-plan-test-step-request "s1" 1)))
          (should (equal "demo:hard" (plist-get again :model)))
          (should (string-match-p "Notes for attempt 2: The first attempt failed with boom\\." (plist-get again :text))))
        (should (equal "demo:simple" (plist-get (harness-supervisor-plan-test-step-request "s1" 0) :model)))
        ;; The step that waited got the result of the attempt that worked.
        (should (string-match-p "### s1 (Title of s1)\nFixed s1\\."
                                (plist-get (harness-supervisor-plan-test-step-request "s2") :text)))
        (should (equal "demo:simple" (plist-get s2 :model))))
      (should (member "Retrying step s1 on demo:hard (attempt 2): mundane was not enough"
                      (harness-supervisor-plan-test-hints sid)))
      ;; The retry did not end the turn: the model went on and said its piece.
      (let ((reports (harness-supervisor-plan-test-wait-reports sid 2)))
        (should (string-match-p "step s1 .* failed" (nth 0 reports)))
        (should (string-match-p "plan p-[a-z0-9]+ (The plan) finished" (nth 1 reports))))
      (harness-supervisor-plan-test-wait-idle sid)
      (let ((turn (cl-remove-if-not (lambda (r) (and (eq 'main (plist-get r :kind))
                                                     (string-prefix-p "Supervisor report: step s1"
                                                                      (plist-get r :text))))
                                    harness-supervisor-plan-test--requests)))
        (should (= 2 (length turn)))))))

(ert-deftest harness-supervisor-plan-a-retry-on-hard-thinks-at-the-hard-tiers-level ()
  "A step escalated to hard takes the hard tier's model and thinking level.
retry_step reads the names of old too, and a step moved to a tier that
names no level loses the level of the tier it left."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (harness-supervisor-plan-test-tier-thinking '((simple . "low") (hard . "high")))
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-submit
         sid (harness-supervisor-plan-test-step-input "s1" :tier "medium" :context "fresh")
         (harness-supervisor-plan-test-step-input "s2" :context "fresh"))
        (let ((plan-id (plist-get (harness-supervisor-plan-test-plan sid) :id)))
          (should-not (plist-get (harness-supervisor-plan-test-step sid "s1") :thinking))
          (should (equal "low" (plist-get (harness-supervisor-plan-test-step sid "s2") :thinking)))
          (dolist (id '("s1" "s2"))
            (harness-supervisor--update-step sid plan-id id :state "failed" :error "boom"))
          (let ((result (harness-supervisor-plan-test-retry-step sid "s1" :tier "hard")))
            (should-not (plist-get result :is-error))
            (should (string-match-p "runs again on demo:hard (tier hard, high thinking, attempt 2)"
                                    (plist-get result :content))))
          (let ((s1 (harness-supervisor-plan-test-step sid "s1")))
            (should (equal "hard" (plist-get s1 :tier)))
            (should (equal "demo:hard" (plist-get s1 :model)))
            (should (equal "high" (plist-get s1 :thinking))))
          ;; Its new worker thinks at that level.
          (let ((create (car (last (harness-supervisor-plan-test-calls 'session/create)))))
            (should (equal "demo:hard" (plist-get create :model)))
            (should (equal "high" (plist-get create :thinking))))
          ;; A name of old is read as its tier of now; medium names no level here.
          (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "s2" :tier "standard") :is-error))
          (let ((s2 (harness-supervisor-plan-test-step sid "s2")))
            (should (equal "medium" (plist-get s2 :tier)))
            (should (equal "demo:medium" (plist-get s2 :model)))
            (should-not (plist-get s2 :thinking))))))))

;; A step that starts again decides what its worker reads by the cache: a
;; warm seed, else a compacted fork (harness-supervisor.el).

(defmacro harness-supervisor-plan-test-with-cache (extra &rest body)
  "Run BODY with the plan engine, the modules EXTRA names and the cowboy's defaults.
The cowboy's default is the brief summary and its minimum context is
none, whatever the user's settings say; the summary is the cheap
model's."
  (declare (indent 1))
  `(harness-supervisor-plan-test-with-modules ,extra
     (let ((harness-cowboy-default 'brief)
           (harness-cowboy-min-context 0)
           (harness-compaction-brief-model "demo:simple"))
       ,@body)))

(defun harness-supervisor-plan-test-own-compactions (sid)
  "Return the compaction nodes that session SID itself wrote, oldest first.
Not the ones a fork inherited."
  (cl-remove-if-not (lambda (n) (equal sid (plist-get n :session)))
                    (harness-supervisor-plan-test-nodes sid 'compaction)))

(defun harness-supervisor-plan-test-messages-text (sid)
  "Return the text of the messages that session SID sends the model next."
  (mapconcat (lambda (m) (mapconcat (lambda (b) (or (plist-get b :text) "")) (plist-get m :content) "\n"))
             (harness-call 'session/messages sid) "\n"))

(defun harness-supervisor-plan-test-stamp-seed (seed-id warm)
  "Make the prompt cache of seed SEED-ID warm, or with WARM nil lapsed long ago.
The demo provider reports no usage, so the seed has no context, and
no cache, until this says it has."
  (harness-call 'session/usage-add seed-id
                (list :input 1 :output 1 :cache-read 1 :cache-ttl 300 :context 5000
                      :model (plist-get (harness-call 'session/get seed-id) :model)
                      :cache-at (if warm (float-time) 1000.0))))

(defun harness-supervisor-plan-test-fail-first (sid &rest steps)
  "Submit, as SID, a plan of STEPS whose first attempts fail; wait for their reports.
Each of STEPS is the input of a step, whose worker fails the first time
and says \"Done again.\" the second."
  (dolist (step steps)
    (harness-supervisor-plan-test-behave (plist-get step :id) 'error "Done again."))
  (apply #'harness-supervisor-plan-test-submit sid steps)
  (dolist (step steps)
    (harness-supervisor-plan-test-wait-state sid (plist-get step :id) "failed"))
  (harness-supervisor-plan-test-wait-reports sid (length steps))
  (harness-supervisor-plan-test-wait-idle sid))

(defun harness-supervisor-plan-test-retry-step (sid step &rest input)
  "Run retry_step for STEP of session SID with INPUT, a plist; return its result."
  (harness-supervisor-plan-test-run sid "retry_step" (append (list :step step :reason "once more") input)))

(defun harness-supervisor-plan-test-forked-from (step-session)
  "Return the id of the session that the worker STEP-SESSION was forked from."
  (plist-get (harness-call 'session/get step-session) :parent-id))

(ert-deftest harness-supervisor-plan-a-retry-on-a-higher-tier-compacts-the-worker ()
  "No warm cache holds the plan's conversation on the new model: the fork is
compacted as the cowboy would, the supervisor is told, and so is the worker."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-fail-first sid (harness-supervisor-plan-test-step-input "s1"))
      (let ((first (plist-get (harness-supervisor-plan-test-step sid "s1") :session)))
        (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "s1" :tier "hard") :is-error))
        (harness-supervisor-plan-test-wait-state sid "s1" "done")
        (let* ((s1 (harness-supervisor-plan-test-step sid "s1"))
               (wid (plist-get s1 :session))
               (nodes (harness-supervisor-plan-test-own-compactions wid))
               (hints (harness-supervisor-plan-test-hints sid))
               (text (plist-get (harness-supervisor-plan-test-step-request "s1" 1) :text)))
          (should (equal "demo:hard" (plist-get s1 :model)))
          (should (= 2 (plist-get s1 :attempts)))
          ;; The fork was compacted, by the cowboy's default, before its turn.
          (should (= 1 (length nodes)))
          (should (equal "brief" (harness-node-compaction-kind (car nodes))))
          (should (equal '(:choice "brief" :by "cold-start") (plist-get (plist-get (car nodes) :meta) :cowboy)))
          (should (member (concat "No prompt cache on demo:hard holds the supervisor's conversation: compacting"
                                  " into a brief summary first, the default for a session no warm cache holds"
                                  " (harness-cowboy-default)")
                          (harness-supervisor-plan-test-hints wid)))
          ;; The worker reads the summary, with the conversation's first and
          ;; last messages kept verbatim: the task it was given is there,
          ;; while the middle is the summary.
          (let ((sent (harness-supervisor-plan-test-messages-text wid)))
            (should (string-match-p "Do s1\\." sent))
            (should (string-match-p "Do the thing" sent)))
          ;; The supervisor is told, after the retry it made.
          (let ((retry (cl-position "Retrying step s1 on demo:hard (attempt 2): once more" hints :test #'equal))
                (told (cl-position (concat "Step s1 (attempt 2) on demo:hard: no warm prompt cache holds the"
                                           " plan's conversation, so its worker starts from a brief summary of it"
                                           " rather than reading it all uncached")
                                   hints :test #'equal)))
            (should retry)
            (should told)
            (should (< retry told)))
          ;; The worker's message says its conversation was compacted.
          (should (string-match-p "was compacted into a summary; the session_history tool searches and reads" text))
          ;; The first attempt was a plain fork, as before.
          (should-not (harness-supervisor-plan-test-own-compactions first))
          (should (equal sid (harness-supervisor-plan-test-forked-from first)))
          (should (equal sid (harness-supervisor-plan-test-forked-from wid)))))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-compacted-retry-fits-its-context-cap-to-the-summary ()
  "A compacted worker is capped from the summary it starts with, not from what
the supervisor holds, and its transcript says so after the compaction."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let ((harness-subagent-context-limit 256000)
          (sid (harness-supervisor-plan-test-session)))
      (harness-call 'session/usage-add sid '(:input 10 :output 5 :context 90000))
      (harness-supervisor-plan-test-fail-first sid (harness-supervisor-plan-test-step-input "s1"))
      (let ((first (plist-get (harness-supervisor-plan-test-step sid "s1") :session)))
        ;; The first attempt inherited the whole conversation, and its cap says so.
        (should (= (harness-tools-agent-context-limit sid t)
                   (plist-get (harness-call 'session/get first) :context-window-limit)))
        (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "s1" :tier "hard") :is-error))
        (harness-supervisor-plan-test-wait-state sid "s1" "done")
        (let* ((wid (plist-get (harness-supervisor-plan-test-step sid "s1") :session))
               (limit (plist-get (harness-call 'session/get wid) :context-window-limit))
               (hints (harness-supervisor-plan-test-hints wid))
               (cowboy (cl-position-if (lambda (h) (string-prefix-p "No prompt cache on demo:hard" h)) hints))
               (cap (cl-position-if (lambda (h) (string-prefix-p "Context window capped at" h)) hints)))
          (should (= 1 (length (harness-supervisor-plan-test-own-compactions wid))))
          ;; The cap and the summary's few tokens, far below the 90k and the cap.
          (should (<= 256000 limit))
          (should (< limit (+ 256000 90000)))
          (should cowboy)
          (should cap)
          (should (< cowboy cap))
          (should (string-match-p (format "\\`Context window capped at %s tokens: the .* it starts with plus 256k of its own"
                                          (regexp-quote (harness-tools-agent--tokens limit)))
                                  (nth cap hints)))
          ;; Set with no hint of its own: the one about the cap says it.
          (should-not (cl-find-if (lambda (h) (string-prefix-p "context window limit" h)) hints))))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-retry-takes-a-warm-seed-and-compacts-without-one ()
  "A seed whose cache is warm is forked through, and reads cheap; one that lapsed is not."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let ((sid (harness-supervisor-plan-test-session)))
      ;; Two fork steps on a model: their first attempts fork through one seed, as always.
      (harness-supervisor-plan-test-fail-first
       sid
       (harness-supervisor-plan-test-step-input "s1" :tier "medium")
       (harness-supervisor-plan-test-step-input "s2" :tier "medium"))
      (let* ((node (plist-get (harness-supervisor-plan-test-plan sid) :node))
             (seed (plist-get (car (harness-call 'seed/list sid)) :id)))
        (should seed)
        (should (equal seed (harness-supervisor-plan-test-forked-from
                             (plist-get (harness-supervisor-plan-test-step sid "s1") :session))))
        (should-not (harness-call 'seed/warm-p sid "demo:medium" node))
        ;; Warm: s1 forks through the seed and is not compacted.
        (harness-supervisor-plan-test-stamp-seed seed t)
        (should (equal seed (harness-call 'seed/warm-p sid "demo:medium" node)))
        (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "s1") :is-error))
        (harness-supervisor-plan-test-wait-state sid "s1" "done")
        (let ((wid (plist-get (harness-supervisor-plan-test-step sid "s1") :session)))
          (should (equal seed (harness-supervisor-plan-test-forked-from wid)))
          (should-not (harness-supervisor-plan-test-own-compactions wid))
          (should (member "Step s1 (attempt 2) on demo:medium: forked from the warm shared context"
                          (harness-supervisor-plan-test-hints sid)))
          (should-not (string-match-p "was compacted"
                                      (plist-get (harness-supervisor-plan-test-step-request "s1" 1) :text))))
        ;; Lapsed: s2 forks the supervisor and is compacted instead of waking the seed.
        (harness-supervisor-plan-test-stamp-seed seed nil)
        (should-not (harness-call 'seed/warm-p sid "demo:medium" node))
        (let ((messages (length (harness-supervisor-plan-test-nodes seed 'user))))
          (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "s2") :is-error))
          (harness-supervisor-plan-test-wait-state sid "s2" "done")
          (should (= messages (length (harness-supervisor-plan-test-nodes seed 'user)))))
        (let ((wid (plist-get (harness-supervisor-plan-test-step sid "s2") :session)))
          (should (equal sid (harness-supervisor-plan-test-forked-from wid)))
          (should (= 1 (length (harness-supervisor-plan-test-own-compactions wid))))
          (should (member (concat "Step s2 (attempt 2) on demo:medium: no warm prompt cache holds the plan's"
                                  " conversation, so its worker starts from a brief summary of it rather than"
                                  " reading it all uncached")
                          (harness-supervisor-plan-test-hints sid)))))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-seed-at-work-counts-as-warm-for-a-retry ()
  "A seed that runs a turn is forked through: the fork waits for the turn that warms it."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let ((sid (harness-supervisor-plan-test-session))
          (script harness-provider-demo-script-override))
      (setq harness-provider-demo-script-override
            (lambda (request)
              (if (equal "Slow warm-up" (harness-provider-demo--last-user-text request))
                  (cons '(:type wait :seconds 1.0) (harness-supervisor-plan-test-reply "ok"))
                (funcall script request))))
      (harness-supervisor-plan-test-fail-first
       sid
       (harness-supervisor-plan-test-step-input "s1" :tier "medium")
       (harness-supervisor-plan-test-step-input "s2" :tier "medium"))
      (let ((seed (plist-get (car (harness-call 'seed/list sid)) :id)))
        (harness-supervisor-plan-test-stamp-seed seed nil)
        ;; The module's own kind of message: the cold cache is not asked about.
        (let ((turn (harness-call 'agent/prompt seed "Slow warm-up" (list :from (harness-sender-system "seed")))))
          (should (harness-call 'agent/running seed))
          (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "s1") :is-error))
          (harness-test-await turn 20)
          (harness-supervisor-plan-test-wait-state sid "s1" "done")
          (let ((wid (plist-get (harness-supervisor-plan-test-step sid "s1") :session)))
            (should (equal seed (harness-supervisor-plan-test-forked-from wid)))
            (should-not (harness-supervisor-plan-test-own-compactions wid))
            ;; The fork came after the turn it waited for.
            (should (member "Slow warm-up" (harness-supervisor-plan-test-user-texts wid))))))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-first-attempts-do-not-compact ()
  "A step that starts for the first time forks as before: directly, or through a seed."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-submit sid
                                           (harness-supervisor-plan-test-step-input "a" :tier "simple")
                                           (harness-supervisor-plan-test-step-input "b" :tier "medium")
                                           (harness-supervisor-plan-test-step-input "c" :tier "medium"))
      (dolist (id '("a" "b" "c"))
        (harness-supervisor-plan-test-wait-state sid id "done"))
      (let ((seed (plist-get (car (harness-call 'seed/list sid)) :id)))
        (should seed)
        ;; a alone on its model: the supervisor forked.  b and c: through the seed.
        (should (equal sid (harness-supervisor-plan-test-forked-from
                            (plist-get (harness-supervisor-plan-test-step sid "a") :session))))
        (dolist (id '("b" "c"))
          (should (equal seed (harness-supervisor-plan-test-forked-from
                               (plist-get (harness-supervisor-plan-test-step sid id) :session)))))
        (dolist (id '("a" "b" "c"))
          (let ((step (harness-supervisor-plan-test-step sid id)))
            (should (= 1 (plist-get step :attempts)))
            (should-not (plist-member step :previous))
            (should-not (harness-supervisor-plan-test-own-compactions (plist-get step :session)))
            (should-not (string-match-p "was compacted\\|previous attempt"
                                        (plist-get (harness-supervisor-plan-test-step-request id) :text))))))
      (should-not (cl-some (lambda (h) (string-match-p "attempt" h)) (harness-supervisor-plan-test-hints sid)))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-fresh-steps-retry-is-unchanged ()
  "A fresh step starts a new session again, which reads nothing of the supervisor's:
there is nothing to compact, and nothing is said of a cache."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let ((compacted nil))
      (dolist (method '(cowboy/compact compaction/compact))
        (let ((method method))
          (harness-register-method method (lambda (&rest args)
                                            (push (cons method args) compacted)
                                            (harness-resolved nil)))))
      (harness-supervisor-plan-test-stub-starts
        (let ((sid (harness-supervisor-plan-test-session)))
          (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "f" :context "fresh"))
          (harness-supervisor--update-step sid (plist-get (harness-supervisor-plan-test-plan sid) :id) "f"
                                           :state "failed" :error "boom")
          (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "f" :tier "hard") :is-error))
          (let ((creates (harness-supervisor-plan-test-calls 'session/create)))
            (should (= 2 (length creates)))
            (should (equal "demo:simple" (plist-get (nth 0 creates) :model)))
            (should (equal "demo:hard" (plist-get (nth 1 creates) :model))))
          (should-not (harness-supervisor-plan-test-calls 'session/fork))
          (should-not (harness-supervisor-plan-test-calls 'seed/fork))
          (should-not compacted)
          (should (= 2 (plist-get (harness-supervisor-plan-test-step sid "f") :attempts))))))))

(ert-deftest harness-supervisor-plan-the-worker-of-a-second-attempt-is-told-of-the-first ()
  "The step keeps the attempt before, and the new worker is pointed at its session."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-fail-first
       sid
       (harness-supervisor-plan-test-step-input "s1")
       (harness-supervisor-plan-test-step-input "f" :context "fresh"))
      (let ((first (plist-get (harness-supervisor-plan-test-step sid "s1") :session))
            (first-fresh (plist-get (harness-supervisor-plan-test-step sid "f") :session)))
        (should-not (plist-member (harness-supervisor-plan-test-step sid "s1") :previous))
        (should-not (string-match-p "previous attempt"
                                    (plist-get (harness-supervisor-plan-test-step-request "s1") :text)))
        (harness-supervisor-plan-test-retry-step sid "s1" :tier "hard")
        (harness-supervisor-plan-test-retry-step sid "f" :tier "medium")
        (harness-supervisor-plan-test-wait-state sid "s1" "done")
        (harness-supervisor-plan-test-wait-state sid "f" "done")
        ;; The tier moved the step's model; the previous attempt keeps the one it ran on.
        (let ((s1 (harness-supervisor-plan-test-step sid "s1"))
              (f (harness-supervisor-plan-test-step sid "f")))
          (should (equal "demo:hard" (plist-get s1 :model)))
          (should (equal (list :attempt 1 :session first :model "demo:simple"
                               :error "the worker's turn ended with error: boom")
                         (plist-get s1 :previous)))
          (should (equal (list :attempt 1 :session first-fresh :model "demo:simple"
                               :error "the worker's turn ended with error: boom")
                         (plist-get f :previous))))
        ;; It is in the worker's message, after the step (and, for the fresh
        ;; worker, after the other steps) and before the closing.  The fork
        ;; has the whole conversation, so it is not given the other steps.
        (dolist (cell `(("s1" ,first "") ("f" ,first-fresh "\n## The other steps\n\n- s1: Title of s1\n")))
          (let ((text (plist-get (harness-supervisor-plan-test-step-request (car cell) 1) :text)))
            (should (string-match-p
                     (concat "\n\n## Step " (car cell) ": Title of " (car cell) "\n\nDo " (car cell) "\\.\n"
                             (regexp-quote (nth 2 cell))
                             "\n## The previous attempt\n\nAttempt 1 ran on demo:simple in session "
                             (regexp-quote (nth 1 cell))
                             " and ended: the worker's turn ended with error: boom\\. You can read what it tried"
                             " with the session_read tool on that session, and should not repeat what failed\\.\n"
                             "\nDo the step, then verify it\\.")
                     text))))
        ;; Neither lost its first attempt's session: it is still there to read.
        (should (harness-call 'session/exists-p first))
        (should (harness-call 'session/exists-p first-fresh)))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-the-previous-attempt-keeps-the-model-it-ran-on ()
  "A worker deleted before the retry cannot say its model: the step noted it.
With no cowboy and no compaction the retried fork goes on with the whole conversation."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" 'hold)
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "s1"))
      (let ((first (harness-supervisor-plan-test-worker sid "s1")))
        (should (equal "demo:simple" (plist-get (harness-supervisor-plan-test-step sid "s1") :worker-model)))
        (harness-call 'session/delete first)
        (should (equal "cancelled" (harness-supervisor-plan-test-state sid "s1")))
        (harness-supervisor-plan-test-wait-reports sid 1)
        (harness-supervisor-plan-test-wait-idle sid)
        (harness-supervisor-plan-test-retry-step sid "s1" :tier "hard")
        (harness-supervisor-plan-test-wait-state sid "s1" "done")
        (let ((s1 (harness-supervisor-plan-test-step sid "s1")))
          (should (equal (list :attempt 1 :session first :model "demo:simple"
                               :error "the worker's session was deleted")
                         (plist-get s1 :previous)))
          (should (equal "demo:hard" (plist-get s1 :worker-model)))
          (should (string-match-p (concat "Attempt 1 ran on demo:simple in session " (regexp-quote first)
                                          " and ended: the worker's session was deleted\\. That session was deleted,"
                                          " so what it tried cannot be read; do not repeat what failed\\.")
                                  (plist-get (harness-supervisor-plan-test-step-request "s1" 1) :text)))
          ;; Neither module: nothing could compact the fork, and it says so.
          (should-not (harness-supervisor-plan-test-own-compactions (plist-get s1 :session)))
          (should (member (concat "No prompt cache on demo:hard holds the supervisor's conversation: nothing can"
                                  " compact it here, so carrying on with the whole conversation, uncached")
                          (harness-supervisor-plan-test-hints (plist-get s1 :session))))
          (should (member (concat "Step s1 (attempt 2) on demo:hard: no warm prompt cache holds the plan's"
                                  " conversation and it was not compacted, so its worker reads it all uncached")
                          (harness-supervisor-plan-test-hints sid)))
          (should-not (string-match-p "was compacted"
                                      (plist-get (harness-supervisor-plan-test-step-request "s1" 1) :text)))))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-without-the-cowboy-the-retry-asks-for-a-brief-summary ()
  "With compaction but no cowboy the fork is compacted into a brief summary, and a hint says why."
  (harness-supervisor-plan-test-with-cache (compaction)
    (should-not (harness-method-exists-p 'cowboy/compact))
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-fail-first sid (harness-supervisor-plan-test-step-input "s1"))
      (harness-supervisor-plan-test-retry-step sid "s1" :tier "hard")
      (harness-supervisor-plan-test-wait-state sid "s1" "done")
      (let* ((wid (plist-get (harness-supervisor-plan-test-step sid "s1") :session))
             (nodes (harness-supervisor-plan-test-own-compactions wid)))
        (should (= 1 (length nodes)))
        (should (equal "brief" (harness-node-compaction-kind (car nodes))))
        (should-not (plist-get (plist-get (car nodes) :meta) :cowboy))
        (should (member (concat "No prompt cache on demo:hard holds the supervisor's conversation:"
                                " compacting into a brief summary first")
                        (harness-supervisor-plan-test-hints wid)))
        (should (member (concat "Step s1 (attempt 2) on demo:hard: no warm prompt cache holds the plan's"
                                " conversation, so its worker starts from a brief summary of it rather than"
                                " reading it all uncached")
                        (harness-supervisor-plan-test-hints sid)))
        (should (string-match-p "was compacted into a summary"
                                (plist-get (harness-supervisor-plan-test-step-request "s1" 1) :text))))
      (harness-supervisor-plan-test-wait-idle sid))))

(defun harness-supervisor-plan-test-check-failed-compaction ()
  "Retry a failed step whose fork cannot be compacted; check the worker runs on it as it is."
  (harness-register-method 'compaction/compact
                           (lambda (&rest _) (harness-rejected '(harness-error "the summariser is down"))))
  (let ((sid (harness-supervisor-plan-test-session)))
    (harness-supervisor-plan-test-fail-first sid (harness-supervisor-plan-test-step-input "s1"))
    (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "s1" :tier "hard") :is-error))
    (harness-supervisor-plan-test-wait-state sid "s1" "done")
    (let* ((s1 (harness-supervisor-plan-test-step sid "s1"))
           (wid (plist-get s1 :session)))
      (should (equal "Done again." (plist-get s1 :result)))
      (should-not (harness-supervisor-plan-test-own-compactions wid))
      (should (cl-some (lambda (h) (string-match-p "the summariser is down" h))
                       (harness-supervisor-plan-test-hints wid)))
      (should (member (concat "Step s1 (attempt 2) on demo:hard: no warm prompt cache holds the plan's"
                              " conversation and it was not compacted, so its worker reads it all uncached")
                      (harness-supervisor-plan-test-hints sid)))
      (should-not (string-match-p "was compacted"
                                  (plist-get (harness-supervisor-plan-test-step-request "s1" 1) :text))))
    (harness-supervisor-plan-test-wait-idle sid)))

(ert-deftest harness-supervisor-plan-a-compaction-the-cowboy-cannot-make-does-not-fail-the-step ()
  "The cowboy falls back as it does, down to carrying on; the worker runs on the fork as it is."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (harness-supervisor-plan-test-check-failed-compaction)))

(ert-deftest harness-supervisor-plan-a-brief-summary-that-fails-does-not-fail-the-step ()
  "With no cowboy a brief summary that cannot be made leaves the fork as it is."
  (harness-supervisor-plan-test-with-cache (compaction)
    (harness-supervisor-plan-test-check-failed-compaction)))

(ert-deftest harness-supervisor-plan-a-cowboy-that-compacts-nothing-leaves-the-whole-conversation ()
  "A conversation under the cowboy's minimum goes whole, and the supervisor hears that."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let ((harness-cowboy-min-context 1000000)
          (sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-fail-first sid (harness-supervisor-plan-test-step-input "s1"))
      (harness-supervisor-plan-test-retry-step sid "s1" :tier "hard")
      (harness-supervisor-plan-test-wait-state sid "s1" "done")
      (let ((wid (plist-get (harness-supervisor-plan-test-step sid "s1") :session)))
        (should-not (harness-supervisor-plan-test-own-compactions wid))
        (should (member (concat "Step s1 (attempt 2) on demo:hard: no warm prompt cache holds the plan's"
                                " conversation and it was not compacted, so its worker reads it all uncached")
                        (harness-supervisor-plan-test-hints sid)))
        (should (string-match-p "Do the thing" (harness-supervisor-plan-test-messages-text wid))))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-retry-step-says-what-is-wrong ()
  "Only a failed, interrupted or cancelled step can be retried; anything else is an error result."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-submit sid
                                             (harness-supervisor-plan-test-step-input "s1")
                                             (harness-supervisor-plan-test-step-input "s2" :after '("s1")))
        (cl-flet ((retry (input) (harness-supervisor-plan-test-run sid "retry_step" input)))
          ;; Running, and pending: not for a retry.
          (let ((result (retry '(:step "s1" :reason "why not"))))
            (should (plist-get result :is-error))
            (should (string-match-p "step s1 is running: only a failed, interrupted or cancelled step can be retried"
                                    (plist-get result :content))))
          (should (string-match-p "step s2 is pending, waiting for s1:" (plist-get (retry '(:step "s2" :reason "x")) :content)))
          ;; Nothing is wrong with the step, but with the call: every problem is named.
          (let ((text (plist-get (retry '(:tier "gigantic")) :content)))
            (should (string-match-p "step is empty" text))
            (should (string-match-p "reason is empty" text))
            (should (string-match-p "\"gigantic\" is no tier" text)))
          (let ((text (plist-get (retry '(:step "nope" :reason "x")) :content)))
            (should (string-match-p "no step nope in any plan of this session" text))
            (should (string-match-p "s1 (running), s2 (pending)" text)))
          (let ((text (plist-get (retry '(:step "s1" :plan "p-none" :reason "x")) :content)))
            (should (string-match-p "no step s1 in plan p-none" text)))
          ;; Nothing was started, and the steps are as they were.
          (should (equal "running" (harness-supervisor-plan-test-state sid "s1")))
          (should (= 1 (plist-get (harness-supervisor-plan-test-step sid "s1") :attempts)))
          (should (= 1 (length (harness-supervisor-plan-test-calls 'seed/fork)))))))))

(ert-deftest harness-supervisor-plan-retry-step-names-the-plan-or-takes-the-latest ()
  "Without a plan the step of the latest plan that has it is retried; plan names another."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" 'error 'error 'error "ok")
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "s1"))
      (harness-supervisor-plan-test-wait-state sid "s1" "failed" 0)
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "s1"))
      (harness-supervisor-plan-test-wait-state sid "s1" "failed" 1)
      (harness-supervisor-plan-test-wait-idle sid)
      (let ((first (plist-get (harness-supervisor-plan-test-plan sid 0) :id)))
        ;; The latest plan has the step: that is the one retried.
        (should-not (plist-get (harness-supervisor-plan-test-run
                                sid "retry_step" '(:step "s1" :reason "again")) :is-error))
        (should (= 1 (plist-get (harness-supervisor-plan-test-step sid "s1" 0) :attempts)))
        (should (= 2 (plist-get (harness-supervisor-plan-test-step sid "s1" 1) :attempts)))
        (harness-supervisor-plan-test-wait-state sid "s1" "failed" 1)
        (harness-supervisor-plan-test-wait-idle sid)
        ;; Named, the first one.
        (should-not (plist-get (harness-supervisor-plan-test-run
                                sid "retry_step" (list :step "s1" :plan first :reason "the old one"))
                               :is-error))
        (harness-supervisor-plan-test-wait-state sid "s1" "done" 0)
        (should (= 2 (plist-get (harness-supervisor-plan-test-step sid "s1" 0) :attempts)))))))

;;;; A finished plan

(ert-deftest harness-supervisor-plan-done-steps-leave-hints-and-a-finished-plan-one-report ()
  "Each done step is a hint; the plan finishing is a message listing every step and its result."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" "Added the flag.")
      (harness-supervisor-plan-test-behave "s2" "Wrote the docs.")
      (harness-supervisor-plan-test-behave "s3" "Ran the tests: 12 passed.")
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "s1")
       (harness-supervisor-plan-test-step-input "s2" :after '("s1") :tier "medium")
       (harness-supervisor-plan-test-step-input "s3" :after '("s1" "s2") :tier "medium"))
      (let ((reports (harness-supervisor-plan-test-wait-reports sid 1)))
        (harness-supervisor-plan-test-wait-idle sid)
        ;; One message, however many steps: the steps that got done said it in hints.
        (should (= 1 (length reports)))
        (let ((text (car reports)))
          (should (string-prefix-p "Supervisor report: plan " text))
          (should (string-match-p "(The plan) finished\\. All 3 steps are done\\.\n" text))
          (should (string-match-p "^- s1 (Title of s1) on demo:simple, session [^ ]+: Added the flag\\.$" text))
          (should (string-match-p "^- s2 (Title of s2) on demo:medium, session [^ ]+: Wrote the docs\\.$" text))
          (should (string-match-p "^- s3 (Title of s3) on demo:medium, session [^ ]+: Ran the tests: 12 passed\\.$" text))
          (should (string-match-p (concat "Check the work now, as cheaply as settles it: the reports above, a diff,"
                                          " the test output; read a file, or a worker's session with session_read,"
                                          " only where a report leaves doubt\\.")
                                  text))
          (should-not (string-match-p "read-only tools" text))
          (should (string-match-p "a follow-up plan with submit_plan" text))
          (should (string-match-p "no_plan_needed with your reply to the user" text))
          ;; Not a task's session: there is nothing to hand in.
          (should-not (string-match-p "hand_in" text))))
      (should (equal '("Plan submitted: 3 steps" "Step s1 done on demo:simple" "Step s2 done on demo:medium"
                       "Step s3 done on demo:medium" "No plan needed: nothing to decide")
                     (harness-supervisor-plan-test-hints sid)))
      ;; The supervisor had a turn for the plan (a request) and one for the report (two).
      (should (= 3 (cl-count 'main harness-supervisor-plan-test--requests
                             :key (lambda (r) (plist-get r :kind)) :test #'eq)))
      (should (zerop (hash-table-count harness-supervisor--live))))))

(ert-deftest harness-supervisor-plan-a-plan-that-finished-is-reported-once-even-with-failures-before ()
  "A plan finishes when its last step is done: a failure and a retry before it do not report twice."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" 'error "Fixed.")
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "s1"))
      (harness-supervisor-plan-test-wait-reports sid 1)
      (harness-supervisor-plan-test-wait-idle sid)
      (should (equal "failed" (harness-supervisor-plan-test-state sid "s1")))
      (should-not (cl-some (lambda (r) (string-match-p "finished" r)) (harness-supervisor-plan-test-reports sid)))
      (harness-supervisor-plan-test-run sid "retry_step" '(:step "s1" :reason "once more"))
      (harness-supervisor-plan-test-wait-state sid "s1" "done")
      (let ((reports (harness-supervisor-plan-test-wait-reports sid 2)))
        (harness-supervisor-plan-test-wait-idle sid)
        (should (= 2 (length reports)))
        (should (string-match-p "failed" (nth 0 reports)))
        (should (string-match-p "finished" (nth 1 reports)))))))

(ert-deftest harness-supervisor-plan-a-replaced-plan-supersedes-its-pending-steps ()
  "A new plan supersedes the old plan's pending steps; its running steps finish and report as usual."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "a1" '(reply "Done a1." 1.0))
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "a1")
       (harness-supervisor-plan-test-step-input "a2" :after '("a1"))
       (harness-supervisor-plan-test-step-input "a3" :after '("a2")))
      (should (equal '("running" "pending" "pending")
                     (mapcar (lambda (id) (harness-supervisor-plan-test-state sid id 0)) '("a1" "a2" "a3"))))
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "b1" :tier "medium"))
      (should (= 2 (length (harness-supervisor-plan-test-plans sid))))
      ;; The steps that waited are superseded; the one that runs is still running.
      (should (equal '("running" "superseded" "superseded")
                     (mapcar (lambda (id) (harness-supervisor-plan-test-state sid id 0)) '("a1" "a2" "a3"))))
      (should (equal "running" (harness-supervisor-plan-test-state sid "b1" 1)))
      ;; Both count while they run; the superseded ones do not.
      (should (equal "Supervisor plan: 2 steps running" (harness-call 'agent/outstanding sid)))
      (harness-supervisor-plan-test-wait-state sid "a1" "done" 0)
      (harness-supervisor-plan-test-wait-state sid "b1" "done" 1)
      (harness-supervisor-plan-test-wait-idle sid)
      ;; Nothing waits, and the superseded steps never ran.
      (should-not (harness-call 'agent/outstanding sid))
      (should-not (harness-supervisor-plan-test-step-request "a2"))
      (should (equal "superseded" (harness-supervisor-plan-test-state sid "a2" 0)))
      (should (member "Step a1 done on demo:simple" (harness-supervisor-plan-test-hints sid)))
      ;; Each plan reports when nothing is left to do in it: the new one first, the old one
      ;; when its running step ended, saying what a later plan kept from running.
      (let ((reports (harness-supervisor-plan-test-wait-reports sid 2)))
        (harness-supervisor-plan-test-wait-idle sid)
        (should (= 2 (length reports)))
        (should (string-match-p "plan p-[a-z0-9]+ (The plan) finished\\. Its one step is done" (nth 0 reports)))
        (should (string-match-p "^- b1 " (nth 0 reports)))
        (should (string-match-p "finished\\. 1 of its 3 steps are done; a later plan superseded a2, a3, which never ran\\."
                                (nth 1 reports)))
        (should (string-match-p "^- a1 (Title of a1) on demo:simple, session [^ ]+: Done a1\\.$" (nth 1 reports)))
        (should (string-match-p "^- a2 (Title of a2): superseded by a later plan, it never ran$" (nth 1 reports)))))))

;;;; The fork limit
;;
;; A fork never reads its parent's prompt cache, so it writes the whole
;; conversation into its worker model's cache and reads it again on every
;; call.  `harness-supervisor-fork-limit' keeps that to a short
;; conversation: submit_plan refuses fork steps past it, and a fork step
;; that starts past it anyway (its plan was made before, or under a higher
;; limit) starts from a compaction.

(defun harness-supervisor-plan-test-long-conversation (sid &optional chars)
  "Give session SID a user message of CHARS characters, 40000 by default.
That is about 10k tokens: what a fork of SID would inherit."
  (harness-call 'session/append sid (list :kind 'user :content (make-string (or chars 40000) ?x))))

(defun harness-supervisor-plan-test-before-step (step-id fn)
  "Make FN run when the worker of STEP-ID gets its job, before it replies.
A test changes a setting that way at a moment no timer could be trusted to hit."
  (let ((do harness-supervisor-plan-test--worker))
    (setq harness-supervisor-plan-test--worker
          (lambda (step text request)
            (when (equal step step-id) (funcall fn))
            (funcall do step text request)))))

(ert-deftest harness-supervisor-plan-the-fork-limit-defaults-to-20000-tokens ()
  "A fork may inherit 20000 tokens of conversation unless the user says otherwise.
Nil is no limit, and a setting that is not a count of tokens is not safe."
  (harness-supervisor-plan-test-with
    (should (equal 20000 (eval (car (get 'harness-supervisor-fork-limit 'standard-value)))))
    (let ((safe (get 'harness-supervisor-fork-limit 'safe-local-variable)))
      (should (funcall safe nil))
      (should (funcall safe 0))
      (should (funcall safe 20000))
      (should-not (funcall safe -1))
      (should-not (funcall safe "20000")))))

(ert-deftest harness-supervisor-plan-a-conversation-counts-by-its-text-its-tool-inputs-and-results ()
  "What a fork inherits is what the provider is sent, counted at four characters a token.
Text, what a call is given and what it answered count.  Thinking does
not, since its signature ties it to the model that made it.  A
conversation that cannot be read counts as none."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (cl-flet ((add (node) (harness-call 'session/append sid node))
                (tokens () (harness-supervisor--conversation-tokens sid)))
        (should (= 0 (tokens)))
        (add (list :kind 'user :content (make-string 400 ?u)))
        (should (= 100 (tokens)))
        (add (list :kind 'thinking :content (make-string 4000 ?t) :meta (list :signature "sig")))
        (should (= 100 (tokens)))
        (add (list :kind 'assistant :content (make-string 80 ?a)))
        (should (= 120 (tokens)))
        ;; A call counts by its input (about 400 characters here, as the
        ;; plist prints) and its result by its output (200).
        (add (list :kind 'tool-call :tool "bash" :call-id "c-1"
                   :input (list :command (make-string 400 ?i))))
        (add (list :kind 'tool-result :call-id "c-1" :output (make-string 200 ?o)))
        (should (<= 270 (tokens) 280)))
      (should (= 0 (harness-supervisor--conversation-tokens "no-such-session"))))))

(ert-deftest harness-supervisor-plan-a-fork-of-a-long-conversation-is-refused ()
  "Past `harness-supervisor-fork-limit' submit_plan refuses fork steps, and names them.
The refusal is an error result like any other problem with a plan, listed
with the others: nothing is recorded, shown or started.  It says to make
the step fresh, and a fresh step is not the problem."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((harness-supervisor-fork-limit 1000)
            (sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-long-conversation sid)
        (cl-flet ((submit (&rest steps)
                    (harness-supervisor-plan-test-run
                     sid "submit_plan" (apply #'harness-supervisor-plan-test-plan-input steps))))
          ;; One fork among fresh steps: it alone is named.
          (let ((result (submit (harness-supervisor-plan-test-step-input "a" :context "fork")
                                (harness-supervisor-plan-test-step-input "b" :context "fresh"))))
            (should (plist-get result :is-error))
            (should-not (plist-get result :end-turn))
            (let ((text (plist-get result :content)))
              (should (string-match-p "submit_plan was refused, and nothing started" text))
              (should (string-match-p (concat "step a forks this conversation, which holds about 10k tokens,"
                                              " past harness-supervisor-fork-limit (1k):")
                                      text))
              (should (string-match-p (concat "a fork writes all of it into its worker model's cache"
                                              " and reads it again on every call")
                                      text))
              (should (string-match-p "Make it fresh, and put what the workers need in the summary" text))
              (should-not (string-match-p "step b" text))))
          (should-not (harness-supervisor-plan-test-plans sid))
          (should-not harness-supervisor-plan-test--calls)
          (should (zerop (hash-table-count harness-supervisor--live)))
          (should-not (harness-supervisor-plan-test-hints sid))
          (should-not (harness-supervisor-plan-test-nodes sid 'plan))
          ;; Several forks are one problem, beside the plan's other problems.
          (let ((text (plist-get (submit (harness-supervisor-plan-test-step-input "a" :context "fork")
                                         (harness-supervisor-plan-test-step-input "b" :context "fork")
                                         (harness-supervisor-plan-test-step-input "c" :context "fresh"
                                                                                  :prompt " "))
                                 :content)))
            (should (string-match-p "Fix these problems and call submit_plan again" text))
            (should (string-match-p "steps a, b fork this conversation, which holds about 10k tokens" text))
            (should (string-match-p "Make them fresh" text))
            (should (string-match-p "step c has a blank prompt" text)))
          (should-not (harness-supervisor-plan-test-plans sid))
          (should-not harness-supervisor-plan-test--calls))))))

(ert-deftest harness-supervisor-plan-the-limit-leaves-fresh-steps-and-short-conversations-alone ()
  "Fresh steps never fork, so a long conversation does not stop them.
Nil is no limit, and a conversation exactly at the limit may still be
forked: only one past it may not."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (cl-flet ((long-session ()
                  (let ((sid (harness-supervisor-plan-test-session)))
                    (harness-supervisor-plan-test-long-conversation sid)
                    sid))
                (submit (sid &rest steps)
                  (setq harness-supervisor-plan-test--calls nil)
                  (harness-supervisor-plan-test-run
                   sid "submit_plan" (apply #'harness-supervisor-plan-test-plan-input steps))))
        ;; Fresh steps only, under a limit far below the conversation.
        (let ((harness-supervisor-fork-limit 1000)
              (sid (long-session)))
          (should-not (plist-get (submit sid
                                         (harness-supervisor-plan-test-step-input "a" :context nil)
                                         (harness-supervisor-plan-test-step-input "b" :context "fresh"))
                                 :is-error))
          (should (= 2 (length (harness-supervisor-plan-test-calls 'session/create))))
          (should-not (harness-supervisor-plan-test-calls 'session/fork)))
        ;; No limit: the same conversation may be forked.
        (let ((harness-supervisor-fork-limit nil)
              (sid (long-session)))
          (should-not (plist-get (submit sid (harness-supervisor-plan-test-step-input "a" :context "fork"))
                                 :is-error))
          (should (= 1 (length (harness-supervisor-plan-test-calls 'session/fork)))))
        ;; At the limit it is not past it; a token less of limit, it is.
        (let ((tokens (let ((sid (long-session))) (harness-supervisor--conversation-tokens sid))))
          (should (= 10000 tokens))
          (let ((harness-supervisor-fork-limit tokens)
                (sid (long-session)))
            (should-not (plist-get (submit sid (harness-supervisor-plan-test-step-input "a" :context "fork"))
                                   :is-error))
            (should (= 1 (length (harness-supervisor-plan-test-calls 'session/fork)))))
          (let ((harness-supervisor-fork-limit (1- tokens))
                (sid (long-session)))
            (should (plist-get (submit sid (harness-supervisor-plan-test-step-input "a" :context "fork"))
                               :is-error))
            (should-not harness-supervisor-plan-test--calls)))))))

(ert-deftest harness-supervisor-plan-a-plan-with-a-fork-step-records-the-size-of-the-conversation ()
  "An accepted plan with a fork step keeps, as :fork-tokens, what a fork of it inherits.
It is measured before the plan or a hint joins the conversation.  A plan
of fresh steps has none, and what is kept is a plain number, which the
JSON store holds."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((harness-supervisor-fork-limit nil)
            (sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-long-conversation sid)
        (let ((before (harness-supervisor--conversation-tokens sid)))
          (should (= 10000 before))
          (should-not (plist-get (harness-supervisor-plan-test-run
                                  sid "submit_plan"
                                  (harness-supervisor-plan-test-plan-input
                                   (harness-supervisor-plan-test-step-input "a" :context "fork")
                                   (harness-supervisor-plan-test-step-input "b" :context nil)))
                                 :is-error))
          (should (numberp (plist-get (harness-supervisor-plan-test-plan sid 0) :fork-tokens)))
          (should (= before (plist-get (harness-supervisor-plan-test-plan sid 0) :fork-tokens))))
        (should-not (plist-get (harness-supervisor-plan-test-run
                                sid "submit_plan"
                                (harness-supervisor-plan-test-plan-input
                                 (harness-supervisor-plan-test-step-input "c" :context nil)
                                 (harness-supervisor-plan-test-step-input "d" :context "fresh")))
                               :is-error))
        (should (= 2 (length (harness-supervisor-plan-test-plans sid))))
        (should-not (plist-member (harness-supervisor-plan-test-plan sid 1) :fork-tokens))
        (should (harness-session--ext-json-p (harness-supervisor-plan-test-plans sid)))))))

(ert-deftest harness-supervisor-plan-a-fork-step-starts-compacted-once-the-conversation-is-past-the-limit ()
  "A fork step starts compacted when the limit is below its plan's conversation by then.
The plan was made while forks were allowed.  Its workers fork the
supervisor directly, not through the seed that two fork steps on one
model would share, and each is compacted before its first turn, on a
first attempt too.  The supervisor is told why, and the message of each
holds the plan and the other steps, which its compaction left out."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let ((harness-supervisor-fork-limit nil)
          (sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-long-conversation sid)
      ;; The limit falls while a works, before b and c, which wait for it, start.
      (harness-supervisor-plan-test-before-step
       "a" (lambda () (setq harness-supervisor-fork-limit 1000)))
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "a" :context nil)
       (harness-supervisor-plan-test-step-input "b" :after '("a"))
       (harness-supervisor-plan-test-step-input "c" :after '("a")))
      (should (numberp (plist-get (harness-supervisor-plan-test-plan sid) :fork-tokens)))
      (harness-supervisor-plan-test-wait-state sid "b" "done")
      (harness-supervisor-plan-test-wait-state sid "c" "done")
      (should-not (harness-call 'seed/list sid))
      (dolist (id '("b" "c"))
        (let* ((step (harness-supervisor-plan-test-step sid id))
               (wid (plist-get step :session))
               (nodes (harness-supervisor-plan-test-own-compactions wid))
               (text (plist-get (harness-supervisor-plan-test-step-request id) :text)))
          (should (= 1 (plist-get step :attempts)))
          (should (equal sid (harness-supervisor-plan-test-forked-from wid)))
          (should (= 1 (length nodes)))
          (should (equal "brief" (harness-node-compaction-kind (car nodes))))
          (should (string-prefix-p "You are now a worker for one step of the supervisor's plan" text))
          (should (string-match-p "was compacted into a summary" text))
          (should (string-match-p (concat "\n\n## The plan\n\nDo it in \\*\\*steps\\*\\*\\.\n"
                                          "\n## Step " id ": Title of " id "\n\nDo " id "\\.\n"
                                          "\n## The other steps\n\n- a: Title of a\n")
                                  text))
          (should-not (string-match-p "previous attempt" text))))
      ;; The supervisor hears why, for each fork, and not that a cache was cold.
      (let ((hints (harness-supervisor-plan-test-hints sid)))
        (dolist (id '("b" "c"))
          (should (member (format (concat "Step %s (attempt 1) on demo:simple: the plan's conversation is past"
                                          " harness-supervisor-fork-limit, so its worker starts from a brief"
                                          " summary of it rather than inheriting all of it")
                                  id)
                          hints)))
        (should-not (cl-some (lambda (hint) (string-match-p "warm prompt cache" hint)) hints)))
      ;; a is a fresh step: nothing to compact.
      (should-not (harness-supervisor-plan-test-own-compactions
                   (plist-get (harness-supervisor-plan-test-step sid "a") :session)))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-fork-step-within-the-limit-still-forks-whole ()
  "A fork step under the limit starts as it always did: no compaction, none of it said.
Two fork steps on a model share a seed, and a worker with the whole
conversation has the plan's own call in it, so its message holds no copy."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let ((harness-supervisor-fork-limit 1000)
          (sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "a")
       (harness-supervisor-plan-test-step-input "b"))
      (harness-supervisor-plan-test-wait-state sid "a" "done")
      (harness-supervisor-plan-test-wait-state sid "b" "done")
      (should (< (harness-supervisor--conversation-tokens sid) 1000))
      (should (numberp (plist-get (harness-supervisor-plan-test-plan sid) :fork-tokens)))
      (let ((seed (plist-get (car (harness-call 'seed/list sid)) :id)))
        (should seed)
        (dolist (id '("a" "b"))
          (let ((wid (plist-get (harness-supervisor-plan-test-step sid id) :session)))
            (should (equal seed (harness-supervisor-plan-test-forked-from wid)))
            (should-not (harness-supervisor-plan-test-own-compactions wid))
            (should-not (string-match-p "## The plan\\|was compacted"
                                        (plist-get (harness-supervisor-plan-test-step-request id) :text))))))
      (should-not (cl-some (lambda (hint) (string-match-p "fork-limit" hint))
                           (harness-supervisor-plan-test-hints sid)))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-retry-past-the-limit-compacts-even-where-a-warm-seed-waits ()
  "The limit comes before a retry's choice by the cache.
Two fork steps share a seed, and with its cache warm a retry would read
from it.  The conversation is past the limit now, so the retry forks
the supervisor and is compacted instead, and the supervisor is told
that is why."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let ((harness-supervisor-fork-limit nil)
          (sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-long-conversation sid)
      (harness-supervisor-plan-test-fail-first
       sid
       (harness-supervisor-plan-test-step-input "s1" :tier "medium")
       (harness-supervisor-plan-test-step-input "s2" :tier "medium"))
      (let* ((node (plist-get (harness-supervisor-plan-test-plan sid) :node))
             (seed (plist-get (car (harness-call 'seed/list sid)) :id)))
        (should seed)
        (harness-supervisor-plan-test-stamp-seed seed t)
        (should (equal seed (harness-call 'seed/warm-p sid "demo:medium" node)))
        (setq harness-supervisor-fork-limit 1000)
        (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "s1") :is-error))
        (harness-supervisor-plan-test-wait-state sid "s1" "done")
        (let ((wid (plist-get (harness-supervisor-plan-test-step sid "s1") :session))
              (hints (harness-supervisor-plan-test-hints sid))
              (text (plist-get (harness-supervisor-plan-test-step-request "s1" 1) :text)))
          (should (equal sid (harness-supervisor-plan-test-forked-from wid)))
          (should (= 1 (length (harness-supervisor-plan-test-own-compactions wid))))
          (should (member (concat "Step s1 (attempt 2) on demo:medium: the plan's conversation is past"
                                  " harness-supervisor-fork-limit, so its worker starts from a brief"
                                  " summary of it rather than inheriting all of it")
                          hints))
          (should-not (member "Step s1 (attempt 2) on demo:medium: forked from the warm shared context" hints))
          (should (string-match-p "was compacted into a summary" text))
          (should (string-match-p "\n## The plan\n\nDo it in \\*\\*steps\\*\\*\\." text))
          (should (string-match-p "\n## The other steps\n\n- s2: Title of s2\n" text))
          (should (string-match-p "\n## The previous attempt\n\nAttempt 1 ran on demo:medium" text))))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-plan-with-no-size-measures-the-conversation-when-a-fork-starts ()
  "A plan stored before plans recorded :fork-tokens has no size.
Its fork step measures the supervisor's conversation as it stands when
the step starts: past the limit the worker is compacted, under it the
worker forks whole."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (dolist (long '(t nil))
      (ert-info ((if long "a long conversation" "a short one"))
        ;; Each round sets its own hook on the worker's script.
        (let ((harness-supervisor-plan-test--worker harness-supervisor-plan-test--worker)
              (harness-supervisor-fork-limit nil)
              (sid (harness-supervisor-plan-test-session)))
          (when long (harness-supervisor-plan-test-long-conversation sid))
          (harness-supervisor-plan-test-before-step
           "a" (lambda ()
                 ;; The plan as an older harness stored it, and a limit set since.
                 (harness-call 'session/set-ext sid :supervisor-plans
                               (mapcar (lambda (plan) (harness-plist-remove plan :fork-tokens))
                                       (harness-supervisor-plan-test-plans sid)))
                 (setq harness-supervisor-fork-limit 1000)))
          (harness-supervisor-plan-test-submit
           sid
           (harness-supervisor-plan-test-step-input "a" :context nil)
           (harness-supervisor-plan-test-step-input "b" :after '("a")))
          (harness-supervisor-plan-test-wait-state sid "b" "done")
          (should-not (plist-member (harness-supervisor-plan-test-plan sid) :fork-tokens))
          (let ((wid (plist-get (harness-supervisor-plan-test-step sid "b") :session))
                (told (cl-some (lambda (hint) (string-match-p "past harness-supervisor-fork-limit" hint))
                               (harness-supervisor-plan-test-hints sid))))
            (should (equal sid (harness-supervisor-plan-test-forked-from wid)))
            (if long
                (progn (should (= 1 (length (harness-supervisor-plan-test-own-compactions wid))))
                       (should told))
              (should-not (harness-supervisor-plan-test-own-compactions wid))
              (should-not told)))
          (harness-supervisor-plan-test-wait-idle sid))))))

(ert-deftest harness-supervisor-plan-a-fork-past-the-limit-is-compacted-as-far-as-the-modules-allow ()
  "With compaction but no cowboy the fork is compacted into a brief summary; with neither it goes whole.
Either way the supervisor hears that the limit made the worker start
so.  A fork that kept the whole conversation has the plan's own call in
it, so its message holds no copy of the plan."
  (cl-flet ((run-plan (sid)
              (harness-supervisor-plan-test-long-conversation sid)
              (harness-supervisor-plan-test-before-step
               "a" (lambda () (setq harness-supervisor-fork-limit 1000)))
              (harness-supervisor-plan-test-submit
               sid
               (harness-supervisor-plan-test-step-input "a" :context nil)
               (harness-supervisor-plan-test-step-input "b" :after '("a")))
              (harness-supervisor-plan-test-wait-state sid "b" "done")))
    ;; Compaction, no cowboy: a brief summary.
    (harness-supervisor-plan-test-with-cache (compaction)
      (should-not (harness-method-exists-p 'cowboy/compact))
      (let ((harness-supervisor-fork-limit nil)
            (sid (harness-supervisor-plan-test-session)))
        (run-plan sid)
        (let ((wid (plist-get (harness-supervisor-plan-test-step sid "b") :session)))
          (should (equal sid (harness-supervisor-plan-test-forked-from wid)))
          (should (= 1 (length (harness-supervisor-plan-test-own-compactions wid))))
          (should (member (concat "No prompt cache on demo:simple holds the supervisor's conversation:"
                                  " compacting into a brief summary first")
                          (harness-supervisor-plan-test-hints wid)))
          (should (member (concat "Step b (attempt 1) on demo:simple: the plan's conversation is past"
                                  " harness-supervisor-fork-limit, so its worker starts from a brief"
                                  " summary of it rather than inheriting all of it")
                          (harness-supervisor-plan-test-hints sid)))
          (should (string-match-p "\n## The plan\n"
                                  (plist-get (harness-supervisor-plan-test-step-request "b") :text))))
        (harness-supervisor-plan-test-wait-idle sid)))
    ;; Neither module: nothing compacts it, and the fork goes on whole.
    (harness-supervisor-plan-test-with
      (let ((harness-supervisor-fork-limit nil)
            (sid (harness-supervisor-plan-test-session)))
        (run-plan sid)
        (let ((wid (plist-get (harness-supervisor-plan-test-step sid "b") :session))
              (text (plist-get (harness-supervisor-plan-test-step-request "b") :text)))
          (should (equal sid (harness-supervisor-plan-test-forked-from wid)))
          (should-not (harness-supervisor-plan-test-own-compactions wid))
          (should (member (concat "No prompt cache on demo:simple holds the supervisor's conversation:"
                                  " nothing can compact it here, so carrying on with the whole"
                                  " conversation, uncached")
                          (harness-supervisor-plan-test-hints wid)))
          (should (member (concat "Step b (attempt 1) on demo:simple: the plan's conversation is past"
                                  " harness-supervisor-fork-limit but could not be compacted, so its"
                                  " worker reads it all uncached")
                          (harness-supervisor-plan-test-hints sid)))
          (should (string-match-p "\\`You are now a worker for one step of the supervisor's plan" text))
          (should-not (string-match-p "## The plan\\|was compacted" text)))
        (harness-supervisor-plan-test-wait-idle sid)))))

(ert-deftest harness-supervisor-plan-a-fork-inherits-the-conversation-up-to-the-plan-only ()
  "A fork has the conversation up to the plan's call, which the plan measured.
A conversation that grows past the limit after the plan was made
changes nothing for its fork steps: they fork it where it was, whole,
and have none of what came later."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let ((harness-supervisor-fork-limit 1000)
          (sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-before-step
       "a" (lambda () (harness-supervisor-plan-test-long-conversation sid)))
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "a" :context nil)
       (harness-supervisor-plan-test-step-input "b" :after '("a")))
      (harness-supervisor-plan-test-wait-state sid "b" "done")
      (should (< (plist-get (harness-supervisor-plan-test-plan sid) :fork-tokens) 1000))
      (should (> (harness-supervisor--conversation-tokens sid) 1000))
      (let ((wid (plist-get (harness-supervisor-plan-test-step sid "b") :session)))
        (should (equal sid (harness-supervisor-plan-test-forked-from wid)))
        (should-not (harness-supervisor-plan-test-own-compactions wid))
        (should-not (string-match-p "xxxxxxxxxx" (harness-supervisor-plan-test-messages-text wid))))
      (should-not (cl-some (lambda (hint) (string-match-p "fork-limit" hint))
                           (harness-supervisor-plan-test-hints sid)))
      (harness-supervisor-plan-test-wait-idle sid))))

;;;; The workers' spawn_agent calls

(ert-deftest harness-supervisor-plan-every-worker-shows-as-a-spawn-agent-call ()
  "Every worker shows in the supervisor's transcript as the spawn_agent
call that would have started it: the step, its tier, model and thinking
in the input, the worker as a clickable `:child-id', and the call is
outside the conversation, so the supervisor's model never gets it."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-tier-thinking '((medium . "high")))
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "a" '(reply "Done a." 2.0))
      (harness-supervisor-plan-test-behave "b" '(reply "Done b." 2.0))
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "a" :tier "medium" :reason "ordinary")
       (harness-supervisor-plan-test-step-input "b" :context "fresh" :tier "simple" :reason "small"))
      (let* ((a (harness-supervisor-plan-test-worker sid "a"))
             (b (harness-supervisor-plan-test-worker sid "b"))
             (calls (harness-supervisor-plan-test-spawn-calls sid))
             (call-a (harness-supervisor-plan-test-spawn-call-of sid a))
             (call-b (harness-supervisor-plan-test-spawn-call-of sid b)))
        ;; One call for each worker, naming it, and the step runs on it.
        (should (= 2 (length calls)))
        (should call-a)
        (should call-b)
        (should (equal a (plist-get (harness-supervisor-plan-test-step sid "a") :session)))
        (should (equal b (plist-get (harness-supervisor-plan-test-step sid "b") :session)))
        (dolist (call (list call-a call-b))
          (should (equal "spawn_agent" (plist-get call :tool)))
          (should (string-prefix-p "sup-" (plist-get call :call-id)))
          (should (harness-outside-node-p call))
          (should (equal (harness-sender-system "supervisor") (harness-node-sender call))))
        ;; The fork step's call says it forks, on its tier's model, first attempt.
        (should (equal "Sub-agent: Step a: Title of a (fork)" (plist-get call-a :title)))
        (should (equal "Step a: Title of a" (plist-get (plist-get call-a :input) :name)))
        (should (equal "Do a." (plist-get (plist-get call-a :input) :prompt)))
        (should (equal "demo:medium" (plist-get (plist-get call-a :input) :model)))
        (should (equal "medium" (plist-get (plist-get call-a :input) :tier)))
        (should (equal "high" (plist-get (plist-get call-a :input) :thinking)))
        (should (= 1 (plist-get (plist-get call-a :input) :attempt)))
        (should (harness-json-true-p (plist-get (plist-get call-a :input) :fork)))
        ;; A fresh step's call forks nothing and names its own model.
        (should (equal "Sub-agent: Step b: Title of b" (plist-get call-b :title)))
        (should (equal "demo:simple" (plist-get (plist-get call-b :input) :model)))
        ;; Its tier names no level, and its supervisor has none: nothing said.
        (should-not (plist-member (plist-get call-b :input) :thinking))
        (should-not (plist-get (plist-get call-b :input) :fork))
        ;; The plan block is still shown once, before the first call.
        (let ((plan (harness-supervisor-plan-test-nodes sid 'plan)))
          (should (= 1 (length plan)))
          (should (equal (plist-get (harness-supervisor-plan-test-plan sid) :id)
                         (plist-get (plist-get (car plan) :meta) :plan-id)))
          (should (< (harness-supervisor-plan-test-node-position
                      sid (lambda (n) (equal (plist-get n :id) (plist-get (car plan) :id))))
                     (harness-supervisor-plan-test-node-position
                      sid (lambda (n) (equal (plist-get n :id) (plist-get call-a :id)))))))
        ;; The model's own messages hold no spawn_agent call.
        (should-not (cl-some (lambda (message)
                               (cl-some (lambda (block) (equal "spawn_agent" (plist-get block :name)))
                                        (plist-get message :content)))
                             (harness-call 'session/messages sid)))
        (harness-supervisor-plan-test-wait-state sid "a" "done")
        (harness-supervisor-plan-test-wait-state sid "b" "done")
        (harness-supervisor-plan-test-wait-idle sid)))))

(ert-deftest harness-supervisor-plan-a-done-workers-result-joins-its-call ()
  "A done step's result joins its call: what the worker reported, then a
footer with the step, its model, its session and what it cost, before
the hint that says the step is done."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "a" "Checked it: all good.")
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "a"))
      (harness-supervisor-plan-test-wait-state sid "a" "done")
      (let* ((step (harness-supervisor-plan-test-step sid "a"))
             (worker (plist-get step :session))
             (call (harness-supervisor-plan-test-spawn-call-of sid worker))
             (results (harness-supervisor-plan-test-spawn-results sid call))
             (result (car results)))
        (should (= 1 (length results)))
        (should (equal (plist-get call :call-id) (plist-get result :call-id)))
        (should-not (plist-get result :is-error))
        (should (harness-outside-node-p result))
        (should (equal (harness-sender-system "supervisor") (harness-node-sender result)))
        (should (equal worker (plist-get (plist-get result :meta) :child-id)))
        (should (numberp (plist-get (plist-get result :meta) :duration)))
        (should (string-prefix-p "Checked it: all good." (plist-get result :output)))
        (should (string-match-p
                 (format "\\[step a (Title of a) done on demo:simple, session %s, [0-9]+ tool calls, cost "
                         (regexp-quote worker))
                 (plist-get result :output)))
        ;; Before the hint that says the step is done.
        (should (< (harness-supervisor-plan-test-node-position
                    sid (lambda (n) (equal (plist-get n :id) (plist-get result :id))))
                   (harness-supervisor-plan-test-node-position
                    sid (lambda (n) (and (eq (plist-get n :kind) 'hint)
                                         (equal "Step a done on demo:simple" (plist-get n :content))))))))
      (harness-supervisor-plan-test-wait-reports sid 1)
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-failed-workers-result-is-an-error ()
  "A step whose worker's turn failed gets an error result naming why,
with the footer saying the step failed."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "a" 'error)
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "a"))
      (harness-supervisor-plan-test-wait-state sid "a" "failed")
      (let* ((worker (plist-get (harness-supervisor-plan-test-step sid "a") :session))
             (call (harness-supervisor-plan-test-spawn-call-of sid worker))
             (results (harness-supervisor-plan-test-spawn-results sid call))
             (result (car results)))
        (should (= 1 (length results)))
        (should (plist-get result :is-error))
        (should (equal worker (plist-get (plist-get result :meta) :child-id)))
        (should (string-match-p "the worker's turn ended with error: boom" (plist-get result :output)))
        (should (string-match-p
                 (format "\\[step a (Title of a) failed on demo:simple, session %s]" (regexp-quote worker))
                 (plist-get result :output))))
      (harness-supervisor-plan-test-wait-reports sid 1)
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-retried-step-shows-a-call-of-its-own ()
  "A step that starts again gets a new call for its new worker, after the
first attempt's call and its error result: the attempts do not share one."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "a" 'error "Done again.")
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "a"))
      (harness-supervisor-plan-test-wait-state sid "a" "failed")
      (harness-supervisor-plan-test-wait-reports sid 1)
      (harness-supervisor-plan-test-wait-idle sid)
      (let* ((first (plist-get (harness-supervisor-plan-test-step sid "a") :session))
             (first-call (harness-supervisor-plan-test-spawn-call-of sid first))
             (first-result (car (harness-supervisor-plan-test-spawn-results sid first-call))))
        (should first-call)
        (should (plist-get first-result :is-error))
        (harness-supervisor-plan-test-retry-step sid "a")
        (harness-supervisor-plan-test-wait-state sid "a" "done")
        (harness-supervisor-plan-test-wait-reports sid 2)
        (harness-supervisor-plan-test-wait-idle sid)
        (let* ((step (harness-supervisor-plan-test-step sid "a"))
               (second (plist-get step :session))
               (second-call (harness-supervisor-plan-test-spawn-call-of sid second))
               (second-result (car (harness-supervisor-plan-test-spawn-results sid second-call))))
          (should (= 2 (plist-get step :attempts)))
          (should-not (equal first second))
          (should-not (equal (plist-get first-call :call-id) (plist-get second-call :call-id)))
          (should (= 1 (plist-get (plist-get first-call :input) :attempt)))
          (should (= 2 (plist-get (plist-get second-call :input) :attempt)))
          ;; Both calls are in the transcript, each with its one result.
          (should (= 2 (length (harness-supervisor-plan-test-spawn-calls sid))))
          (should (plist-get first-result :is-error))
          (should-not (plist-get second-result :is-error))
          (should (string-prefix-p "Done again." (plist-get second-result :output))))))))

(ert-deftest harness-supervisor-plan-a-restart-closes-the-call-of-an-interrupted-step ()
  "The harness stopping while a worker ran leaves its call open; recovering
interrupts the step and answers the call once, naming the interruption."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (let ((worker (harness-supervisor-plan-test-running-plan sid)))
        (harness-supervisor-plan-test-restart sid)
        ;; The call in memory is gone, as it is after a restart.
        (should (zerop (hash-table-count harness-supervisor--spawns)))
        (harness-supervisor--recover)
        (let* ((call (harness-supervisor-plan-test-spawn-call-of sid worker))
               (results (harness-supervisor-plan-test-spawn-results sid call)))
          (should call)
          (should (= 1 (length results)))
          (should (plist-get (car results) :is-error))
          (should (equal worker (plist-get (plist-get (car results) :meta) :child-id)))
          (should (string-match-p "interrupted" (plist-get (car results) :output)))
          (should (string-match-p "step s1 (Title of s1)" (plist-get (car results) :output)))
          (should (string-match-p "the harness stopped while the worker was running"
                                  (plist-get (car results) :output)))
          ;; Recovering again, for a step that is not running any more, adds nothing.
          (harness-supervisor--recover)
          (should (= 1 (length (harness-supervisor-plan-test-spawn-results sid call)))))))))

(ert-deftest harness-supervisor-plan-a-new-plan-leaves-a-running-workers-call-alone ()
  "A superseding plan forks at its own submit_plan call, not the one the
plan before it used, and the worker of the plan it replaced keeps its
call and still gets its result."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "a1" '(reply "Done a1." 2.0))
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "a1")
       (harness-supervisor-plan-test-step-input "a2" :after '("a1")))
      (let ((old (harness-supervisor-plan-test-worker sid "a1")))
        (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "b1" :tier "medium"))
        (harness-supervisor-plan-test-wait-state sid "b1" "done" 1)
        (let* ((plan (harness-supervisor-plan-test-plan sid 1))
               (b1 (plist-get (harness-supervisor-plan-test-step sid "b1" 1) :session))
               (submits (cl-remove-if-not (lambda (n) (and (eq (plist-get n :kind) 'tool-call)
                                                          (equal "submit_plan" (plist-get n :tool))))
                                          (harness-call 'session/nodes sid))))
          ;; The new plan's fork point is the last submit_plan call, its own.
          (should (= 2 (length submits)))
          (should (equal (plist-get (car (last submits)) :id) (plist-get plan :node)))
          (should (equal (plist-get plan :node) (plist-get (harness-call 'session/get b1) :fork-node)))
          ;; The running worker's call is untouched: no result yet.
          (let ((call (harness-supervisor-plan-test-spawn-call-of sid old)))
            (should call)
            (should-not (harness-supervisor-plan-test-spawn-results sid call)))
          (harness-supervisor-plan-test-wait-state sid "a1" "done" 0)
          (harness-supervisor-plan-test-wait-idle sid)
          ;; It still gets its one result, and the superseded step ran nothing.
          (should (= 2 (length (harness-supervisor-plan-test-spawn-calls sid))))
          (should (= 1 (length (harness-supervisor-plan-test-spawn-results
                                sid (harness-supervisor-plan-test-spawn-call-of sid old)))))
          (should-not (harness-supervisor-plan-test-step-request "a2")))))))

(ert-deftest harness-supervisor-plan-deleting-a-worker-closes-its-call ()
  "Deleting the session of a running worker answers its spawn_agent call
with the cancellation."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" 'hold)
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "s1"))
      (let ((worker (harness-supervisor-plan-test-worker sid "s1")))
        (harness-call 'session/delete worker)
        (should (equal "cancelled" (harness-supervisor-plan-test-state sid "s1")))
        (let* ((call (harness-supervisor-plan-test-spawn-call-of sid worker))
               (results (harness-supervisor-plan-test-spawn-results sid call))
               (result (car results)))
          (should (= 1 (length results)))
          (should (plist-get result :is-error))
          (should (equal worker (plist-get (plist-get result :meta) :child-id)))
          (should (string-match-p "the worker's session was deleted" (plist-get result :output)))
          (should (string-match-p
                   (format "\\[step s1 (Title of s1) cancelled on demo:simple, session %s]"
                           (regexp-quote worker))
                   (plist-get result :output))))
        (harness-supervisor-plan-test-wait-reports sid 1)))))

;;;; When something else goes wrong

(ert-deftest harness-supervisor-plan-a-worker-that-cannot-be-made-fails-its-step ()
  "A rejected fork, seed or create is a failed step with the reason, and the supervisor is told."
  (dolist (method '(session/fork seed/fork session/create))
    (ert-info ((format "%s" method))
      (harness-supervisor-plan-test-with
        (harness-supervisor-plan-test-stub-starts
          (let ((method method))
            (harness-register-method
             method
             (if (eq method 'session/create)
                 (let ((create (harness-method-fn (gethash 'session/create harness--methods))))
                   (lambda (&rest args)
                     (if (eq 'subagent (plist-get args :kind))
                         (harness-rejected '(error "no room for a session"))
                       (apply create args))))
               (lambda (&rest _) (harness-rejected '(error "no room for a session"))))))
          (let ((sid (harness-supervisor-plan-test-session)))
            (harness-supervisor-plan-test-submit
             sid
             (harness-supervisor-plan-test-step-input "a" :context (if (eq method 'session/create) "fresh" "fork"))
             ;; On another model, so that a does not fork through a seed unless the test says.
             (harness-supervisor-plan-test-step-input "b" :context (if (eq method 'session/create) "fresh" "fork")
                                                      :tier (if (eq method 'seed/fork) "simple" "medium")
                                                      :after '("a")))
            (harness-supervisor-plan-test-wait-state sid "a" "failed")
            (should (string-match-p "the worker could not be made: no room for a session"
                                    (plist-get (harness-supervisor-plan-test-step sid "a") :error)))
            (should (equal "pending" (harness-supervisor-plan-test-state sid "b")))
            (let ((reports (harness-supervisor-plan-test-wait-reports sid 1)))
              (should (string-match-p "step a .* failed" (car reports)))
              (should (string-match-p "no room for a session" (car reports)))
              (should (string-match-p "Held on it, pending until it is done: b " (car reports))))
            (should-not (harness-call 'agent/outstanding sid))
            (should (zerop (hash-table-count harness-supervisor--live)))))))))

(ert-deftest harness-supervisor-plan-a-failure-during-the-submitting-turn-is-not-lost ()
  "A report that comes while the turn that submitted the plan ends waits for it, then gets a turn."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      ;; Settled at once, so its failure is known before submit_plan returns.
      (harness-register-method 'session/fork (lambda (&rest _) (harness-rejected '(error "no fork today"))))
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "a"))
        (should (equal "failed" (harness-supervisor-plan-test-state sid "a")))
        ;; The turn is over, and so is the wait: the report is on its way as a turn.
        (let ((reports (harness-supervisor-plan-test-wait-reports sid 1)))
          (should (string-match-p "no fork today" (car reports))))
        (harness-supervisor-plan-test-wait-idle sid)
        ;; In the order it should read: the plan and its answer, then the report and the reply.
        (let ((kinds (mapcar (lambda (n) (plist-get n :kind))
                             (cl-remove-if (lambda (n) (memq (plist-get n :kind) '(hint plan)))
                                           (harness-call 'session/nodes sid)))))
          (should (equal '(user tool-call tool-result user tool-call tool-result assistant) kinds)))
        (should (= 3 (cl-count 'main harness-supervisor-plan-test--requests
                               :key (lambda (r) (plist-get r :kind)) :test #'eq)))
        (should-not (gethash sid harness-supervisor--held))
        (should-not (gethash sid harness-supervisor--ending))))))

(ert-deftest harness-supervisor-plan-reports-to-a-running-turn-steer-it ()
  "A report that finds the supervisor in a turn of its own steers that turn."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" 'error)
      (setq harness-supervisor-plan-test--plan
            (harness-supervisor-plan-test-plan-input (harness-supervisor-plan-test-step-input "s1")))
      ;; The user's next message keeps the supervisor busy while the step fails.
      (harness-supervisor-plan-test-prompt sid "Do the thing")
      (let ((script harness-provider-demo-script-override))
        (setq harness-provider-demo-script-override
              (lambda (request)
                (let ((text (harness-provider-demo--last-user-text request)))
                  (if (equal text "Still there?")
                      (cons '(:type wait :seconds 0.8) (harness-supervisor-plan-test-reply "Yes."))
                    (funcall script request)))))
        (harness-supervisor-plan-test-wait-reports sid 1)
        (harness-supervisor-plan-test-wait-idle sid)
        (harness-supervisor-plan-test-behave "s1" 'error)
        (let ((turn (harness-call 'agent/prompt sid "Still there?")))
          (harness-supervisor-plan-test-run sid "retry_step" '(:step "s1" :reason "again"))
          ;; Fails again while the supervisor talks: the report lands in that turn.
          (harness-test-wait (lambda () (>= (length (harness-supervisor-plan-test-reports sid)) 2)) 10
                             "the second report")
          (let ((node (car (last (cl-remove-if-not
                                  (lambda (n) (equal "supervisor" (plist-get (harness-node-sender n) :source)))
                                  (harness-supervisor-plan-test-nodes sid 'user))))))
            (should (plist-get (plist-get node :meta) :steering)))
          (harness-test-await turn 10))))))

(ert-deftest harness-supervisor-plan-a-worker-that-is-stopped-is-a-failed-step ()
  "The turn of a worker the user stopped is a failed step that says so; it is reported and can be retried."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" 'hold "Second time lucky.")
      (harness-supervisor-plan-test-submit sid
                                           (harness-supervisor-plan-test-step-input "s1")
                                           (harness-supervisor-plan-test-step-input "s2" :after '("s1")))
      (harness-call 'agent/cancel (harness-supervisor-plan-test-worker sid "s1"))
      (harness-supervisor-plan-test-wait-state sid "s1" "failed")
      (should (equal "the worker's turn was cancelled, most likely by the user"
                     (plist-get (harness-supervisor-plan-test-step sid "s1") :error)))
      (let ((reports (harness-supervisor-plan-test-wait-reports sid 1)))
        (should (string-match-p "step s1 (Title of s1) failed\\." (car reports)))
        (should (string-match-p "Why: the worker's turn was cancelled, most likely by the user" (car reports)))
        (should (string-match-p "Held on it, pending until it is done: s2 " (car reports))))
      (harness-supervisor-plan-test-wait-idle sid)
      (should-not (harness-call 'agent/outstanding sid))
      (should-not (plist-get (harness-supervisor-plan-test-run sid "retry_step" '(:step "s1" :reason "stopped by mistake"))
                             :is-error))
      (harness-supervisor-plan-test-wait-state sid "s2" "done"))))

(ert-deftest harness-supervisor-plan-a-deleted-worker-cancels-its-step ()
  "Deleting the session of a running worker cancels its step, and the supervisor is told."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" 'hold)
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "s1"))
      (harness-call 'session/delete (harness-supervisor-plan-test-worker sid "s1"))
      (should (equal "cancelled" (harness-supervisor-plan-test-state sid "s1")))
      (should (equal "the worker's session was deleted" (plist-get (harness-supervisor-plan-test-step sid "s1") :error)))
      (let ((reports (harness-supervisor-plan-test-wait-reports sid 1)))
        (should (string-match-p "was cancelled" (car reports))))
      (should (zerop (hash-table-count harness-supervisor--live))))))

(ert-deftest harness-supervisor-plan-deleting-the-supervisor-cancels-its-workers ()
  "The workers of a deleted supervisor are stopped, and nothing reports to it."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" 'hold)
      (harness-supervisor-plan-test-behave "s2" 'hold)
      (harness-supervisor-plan-test-submit sid
                                           (harness-supervisor-plan-test-step-input "s1" :context "fresh")
                                           (harness-supervisor-plan-test-step-input "s2" :context "fresh")
                                           (harness-supervisor-plan-test-step-input "s3" :after '("s1")))
      (let ((workers (mapcar (lambda (id) (plist-get (harness-supervisor-plan-test-step sid id) :session))
                             '("s1" "s2"))))
        (harness-test-wait (lambda () (cl-every (lambda (w) (and w (harness-call 'agent/running w))) workers))
                           10 "the workers to run")
        (harness-call 'session/delete sid)
        (harness-test-wait (lambda () (not (cl-some (lambda (w) (harness-call 'agent/running w)) workers)))
                           10 "the workers to stop")
        (should (zerop (hash-table-count harness-supervisor--live)))
        ;; Their turns ended cancelled and nobody was told: there is nobody.
        (accept-process-output nil 0.2)
        (should-not (harness-call 'session/exists-p sid))
        (should (cl-every (lambda (w) (harness-call 'session/exists-p w)) workers))))))

;;;; Plans outlive the harness

(ert-deftest harness-supervisor-plan-the-plans-are-json-and-survive-a-reload-of-the-record ()
  "The plans come back from the JSON store, and from a restart, as they were."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" 'error)
      (harness-supervisor-plan-test-submit
       sid
       (harness-supervisor-plan-test-step-input "s1" :prompt "Do s1 \"carefully\"\nwith newlines and ünïcode …")
       (harness-supervisor-plan-test-step-input "s2" :after '("s1") :context "fresh" :tier "medium")
       (harness-supervisor-plan-test-step-input "s3"))
      (harness-supervisor-plan-test-wait-state sid "s3" "done")
      (harness-supervisor-plan-test-wait-state sid "s1" "failed")
      (harness-supervisor-plan-test-wait-reports sid 1)
      (harness-supervisor-plan-test-wait-idle sid)
      (let ((plans (harness-supervisor-plan-test-plans sid)))
        (should (= 1 (length plans)))
        ;; Only what JSON keeps: strings, numbers, lists of those, no empty fields.
        (should (harness-session--ext-json-p plans))
        (dolist (plan plans)
          (should-not (cl-some #'null (cl-loop for (_k v) on plan by #'cddr collect v)))
          (dolist (step (plist-get plan :steps))
            (should-not (cl-some #'null (cl-loop for (_k v) on step by #'cddr collect v)))
            (should (stringp (plist-get step :state)))))
        (should (equal plans (harness-json-parse (harness-json-encode plans))))
        ;; And from the disk, after a restart.
        (harness-session-flush)
        (clrhash harness-sessions)
        (harness-session--load-all)
        (should (equal plans (harness-supervisor-plan-test-plans sid)))
        (let ((s1 (harness-supervisor-plan-test-step sid "s1")))
          (should (equal "failed" (plist-get s1 :state)))
          (should (equal "Do s1 \"carefully\"\nwith newlines and ünïcode …" (plist-get s1 :prompt))))
        (should (equal "done" (harness-supervisor-plan-test-state sid "s3")))
        (should (equal "pending" (harness-supervisor-plan-test-state sid "s2")))
        (should (equal '("s1") (plist-get (harness-supervisor-plan-test-step sid "s2") :after)))))))

(ert-deftest harness-supervisor-plan-a-change-of-a-step-is-announced-to-the-ui ()
  "Each change of a step is a `session/ext-changed' of the plans, which is how the UI sees it."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session))
          (seen nil))
      (harness-on 'session/ext-changed
                  (lambda (id key value)
                    (when (and (equal id sid) (eq key :supervisor-plans))
                      (push (mapcar (lambda (step) (plist-get step :state))
                                    (plist-get (car (last value)) :steps))
                            seen))))
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "s1"))
      (harness-supervisor-plan-test-wait-state sid "s1" "done")
      (let ((states (delete-dups (mapcar #'car (reverse seen)))))
        (should (equal '("pending" "running" "done") states))))))

;;;; Restarts

(defun harness-supervisor-plan-test-restart (sid)
  "Make the harness restart as far as session SID can tell.
Its workers die, memory is forgotten and the sessions come back from the disk."
  ;; Forget the workers first, so that their end is nobody's news.
  (let ((workers (cl-loop for plan in (harness-supervisor-plan-test-plans sid)
                          append (cl-loop for step in (plist-get plan :steps)
                                          when (plist-get step :session) collect (plist-get step :session)))))
    (clrhash harness-supervisor--live)
    (dolist (w workers)
      (when (and (harness-call 'session/exists-p w) (harness-call 'agent/running w))
        (harness-call 'agent/cancel w)
        (harness-test-wait (lambda () (not (harness-call 'agent/running w))) 10 "the worker to stop"))))
  (clrhash harness-supervisor--ending)
  (clrhash harness-supervisor--held)
  ;; A real restart loses the calls in memory too: the open call is
  ;; found in the transcript when its result is recorded.
  (clrhash harness-supervisor--spawns)
  (harness-session-flush)
  (clrhash harness-sessions)
  (harness-session--load-all))

(defun harness-supervisor-plan-test-running-plan (sid)
  "Submit, as SID, a plan whose step s1 works for good.
Step s2 follows it, and s3 follows s2.  Return the worker of s1."
  (harness-supervisor-plan-test-behave "s1" 'hold)
  (harness-supervisor-plan-test-submit sid
                                       (harness-supervisor-plan-test-step-input "s1" :tier "medium")
                                       (harness-supervisor-plan-test-step-input "s2" :after '("s1"))
                                       (harness-supervisor-plan-test-step-input "s3" :after '("s2")))
  (harness-supervisor-plan-test-worker sid "s1"))

(ert-deftest harness-supervisor-plan-a-restart-interrupts-the-running-steps-and-queues-the-report ()
  "The user's supervisor is not woken: the report waits for their next message."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-running-plan sid)
      (harness-supervisor-plan-test-restart sid)
      (should (equal "running" (harness-supervisor-plan-test-state sid "s1")))
      (setq harness-supervisor-plan-test--requests nil)
      (harness-supervisor--recover)
      (let ((s1 (harness-supervisor-plan-test-step sid "s1")))
        (should (equal "interrupted" (plist-get s1 :state)))
        (should (equal "the harness stopped while the worker was running" (plist-get s1 :error))))
      (should (equal '("pending" "pending") (list (harness-supervisor-plan-test-state sid "s2")
                                                  (harness-supervisor-plan-test-state sid "s3"))))
      ;; Queued, as the harness's: it goes with the user's next message.
      (let ((queue (plist-get (harness-call 'session/get sid) :queue)))
        (should (= 1 (length queue)))
        (should (equal (harness-sender-system "supervisor") (plist-get (car queue) :from)))
        (let ((text (plist-get (car queue) :text)))
          (should (string-prefix-p "Supervisor report: step s1 (Title of s1) was interrupted." text))
          (should (string-match-p "tier medium, model demo:medium (attempt 1)" text))
          (should (string-match-p "the harness stopped while the worker was running" text))
          (should (string-match-p "Held on it, pending until it is done: s2 (Title of s2), s3 (Title of s3)\\." text))
          (should (string-match-p "retry_step s1" text))))
      ;; No turn was started, and nothing waits for the held steps.
      (accept-process-output nil 0.2)
      (should-not harness-supervisor-plan-test--requests)
      (should-not (harness-call 'agent/running sid))
      (should-not (harness-call 'agent/outstanding sid))
      ;; Doing it again changes nothing: the step is not running any more.
      (harness-supervisor--recover)
      (should (= 1 (length (plist-get (harness-call 'session/get sid) :queue)))))))

(ert-deftest harness-supervisor-plan-a-restart-tells-the-session-of-a-task-at-once ()
  "A task has no next message: the supervisor of a task gets the report as a turn."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-running-plan sid)
      (harness-supervisor-plan-test-restart sid)
      (harness-register-method 'task/for-session
                               (lambda (id) (and (equal id sid) (list :id "t-1" :session sid))))
      (setq harness-supervisor-plan-test--on-report
            (lambda (_text)
              (harness-supervisor-plan-test-call "retry_step" '(:step "s1" :reason "the harness restarted"))))
      (harness-supervisor--recover)
      (let ((reports (harness-supervisor-plan-test-wait-reports sid 1)))
        (should (string-match-p "was interrupted" (car reports))))
      ;; The session is awake and acted on it; nothing is queued.
      (harness-test-wait (lambda () (equal "running" (harness-supervisor-plan-test-state sid "s1"))) 10
                         "the retry")
      (should (= 2 (plist-get (harness-supervisor-plan-test-step sid "s1") :attempts)))
      (should-not (plist-get (harness-call 'session/get sid) :queue))
      (harness-supervisor-plan-test-wait-idle sid))))

(ert-deftest harness-supervisor-plan-a-restart-starts-the-ready-steps-of-a-task ()
  "A task's step whose turn came just as the harness stopped starts on recovery.
`agent/outstanding' counts such a step as waiting, so the task would
otherwise wait for it for good.  Another session's step waits for the
supervisor."
  (dolist (task '(nil t))
    (harness-supervisor-plan-test-with
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-running-plan sid)
        ;; The harness stopped once s1 was done, before s2 started.
        (harness-supervisor--update-step sid (plist-get (harness-supervisor-plan-test-plan sid) :id) "s1"
                                         :state "done" :result "s1 is done")
        (harness-supervisor-plan-test-restart sid)
        (when task
          (harness-register-method 'task/for-session
                                   (lambda (id) (and (equal id sid) (list :id "t-1" :session sid)))))
        (harness-supervisor--recover)
        (if task
            (harness-supervisor-plan-test-wait-state sid "s3" "done")
          (should (equal "pending" (harness-supervisor-plan-test-state sid "s2"))))
        (harness-supervisor-plan-test-wait-idle sid)))))

(ert-deftest harness-supervisor-plan-every-interrupted-step-gets-a-report-of-its-own ()
  "Two steps running at the restart are two interrupted steps and two reports."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "a" 'hold)
      (harness-supervisor-plan-test-behave "b" 'hold)
      (harness-supervisor-plan-test-submit sid
                                           (harness-supervisor-plan-test-step-input "a")
                                           (harness-supervisor-plan-test-step-input "b" :tier "medium"))
      (harness-supervisor-plan-test-worker sid "a")
      (harness-supervisor-plan-test-worker sid "b")
      (harness-supervisor-plan-test-restart sid)
      (harness-supervisor--recover)
      (should (equal '("interrupted" "interrupted")
                     (list (harness-supervisor-plan-test-state sid "a") (harness-supervisor-plan-test-state sid "b"))))
      (let ((queue (plist-get (harness-call 'session/get sid) :queue)))
        (should (= 2 (length queue)))
        (should (string-match-p "step a .* interrupted" (plist-get (nth 0 queue) :text)))
        (should (string-match-p "step b .* interrupted" (plist-get (nth 1 queue) :text)))))))

(ert-deftest harness-supervisor-plan-an-interrupted-step-can-be-retried ()
  "retry_step takes an interrupted step, and its dependants go on from there."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-running-plan sid)
      (harness-supervisor-plan-test-restart sid)
      (harness-supervisor--recover)
      (let ((result (harness-supervisor-plan-test-run
                     sid "retry_step" '(:step "s1" :reason "the harness restarted" :prompt "Check what is done."))))
        (should-not (plist-get result :is-error))
        (should (string-match-p "Step s1 of plan p-[a-z0-9]+ runs again on demo:medium" (plist-get result :content))))
      (harness-supervisor-plan-test-wait-state sid "s3" "done")
      (should (equal "done" (harness-supervisor-plan-test-state sid "s1")))
      (should (= 2 (plist-get (harness-supervisor-plan-test-step sid "s1") :attempts))))))

(ert-deftest harness-supervisor-plan-an-interrupted-step-starts-again-from-a-summary ()
  "After a restart no cache holds the conversation: the retried fork is compacted,
and the worker is told what the interrupted one ran on and how it ended."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let* ((sid (harness-supervisor-plan-test-session))
           (first (harness-supervisor-plan-test-running-plan sid)))
      (harness-supervisor-plan-test-restart sid)
      (harness-supervisor--recover)
      (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "s1" :prompt "Check what is done.")
                             :is-error))
      (harness-supervisor-plan-test-wait-state sid "s3" "done")
      (let* ((s1 (harness-supervisor-plan-test-step sid "s1"))
             (wid (plist-get s1 :session))
             (text (plist-get (harness-supervisor-plan-test-step-request "s1" 1) :text)))
        (should (= 2 (plist-get s1 :attempts)))
        (should (equal (list :attempt 1 :session first :model "demo:medium"
                             :error "the harness stopped while the worker was running")
                       (plist-get s1 :previous)))
        (should (= 1 (length (harness-supervisor-plan-test-own-compactions wid))))
        (should (member (concat "Step s1 (attempt 2) on demo:medium: no warm prompt cache holds the plan's"
                                " conversation, so its worker starts from a brief summary of it rather than"
                                " reading it all uncached")
                        (harness-supervisor-plan-test-hints sid)))
        (should (string-match-p "was compacted into a summary" text))
        (should (string-match-p (concat "Attempt 1 ran on demo:medium in session " (regexp-quote first)
                                        " and ended: the harness stopped while the worker was running\\. You can read")
                                text))
        ;; The notes the supervisor gave come first, then what happened before.
        (should (< (string-match "Check what is done\\." text) (string-match "## The previous attempt" text))))
      ;; The steps that waited start for the first time: no compaction, nothing of a previous attempt.
      (dolist (id '("s2" "s3"))
        (let ((step (harness-supervisor-plan-test-step sid id)))
          (should (= 1 (plist-get step :attempts)))
          (should-not (plist-member step :previous))
          (should-not (harness-supervisor-plan-test-own-compactions (plist-get step :session)))))
      (harness-supervisor-plan-test-wait-idle sid))))

(defun harness-supervisor-plan-test-start-again ()
  "Start the supervisor module as a new harness does, which recovers the steps.
A module that is ready initialises again instead, as a reload has it,
and recovers nothing."
  (setf (harness-module-state (harness-module-get 'supervisor)) 'registered)
  (should (harness-module-start 'supervisor)))

(ert-deftest harness-supervisor-plan-the-module-recovers-once-it-is-up-but-a-reload-does-not ()
  "Starting the module schedules the recovery; initialising it again at a reload starts nothing."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-running-plan sid)
      (harness-supervisor-plan-test-restart sid)
      ;; A reload initialises the ready module again: the steps are not
      ;; touched.
      (should (harness-module-ready-p 'supervisor))
      (should (harness-module-start 'supervisor))
      (accept-process-output nil 0.2)
      (should (equal "running" (harness-supervisor-plan-test-state sid "s1")))
      ;; The start, once every module is up, sees them interrupted.
      (harness-supervisor-plan-test-start-again)
      (harness-supervisor-plan-test-wait-state sid "s1" "interrupted")
      ;; A step this process runs is left alone: its worker is alive.
      (let ((sid2 (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-behave "w" 'hold)
        (harness-supervisor-plan-test-submit sid2 (harness-supervisor-plan-test-step-input "w"))
        (harness-supervisor-plan-test-worker sid2 "w")
        (harness-supervisor-plan-test-start-again)
        (accept-process-output nil 0.2)
        (should (equal "running" (harness-supervisor-plan-test-state sid2 "w")))
        (harness-call 'session/delete sid2)))))

(ert-deftest harness-supervisor-plan-the-module-takes-itself-off-the-bus ()
  "A stopped module reports nothing outstanding and hears no turn end; starting again hooks in once."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-running-plan sid)
      (should (equal "Supervisor plan: 1 step running, 2 waiting" (harness-call 'agent/outstanding sid)))
      (harness-supervisor--shutdown)
      (should-not (harness-call 'agent/outstanding sid))
      (should-not (memq #'harness-supervisor--outstanding (mapcar #'cdr (gethash 'agent/outstanding harness--filters))))
      (should-not (memq #'harness-supervisor--stop-outstanding
                        (mapcar #'cdr (gethash 'agent/stop-outstanding harness--filters))))
      ;; A stopped module stops nothing.
      (should-not (harness-call 'agent/stop-outstanding sid "its task was returned to the queue"))
      (should (equal "running" (harness-supervisor-plan-test-state sid "s1")))
      (harness-supervisor--init)
      (harness-supervisor--init)
      (should (equal "Supervisor plan: 1 step running, 2 waiting" (harness-call 'agent/outstanding sid)))
      (should (= 1 (cl-count #'harness-supervisor--outstanding (gethash 'agent/outstanding harness--filters)
                             :key #'cdr)))
      (should (= 1 (cl-count #'harness-supervisor--stop-outstanding (gethash 'agent/stop-outstanding harness--filters)
                             :key #'cdr)))
      (should (= 1 (cl-count #'harness-supervisor--on-turn-ended (gethash 'agent/turn-ended harness--subscribers)
                             :key #'cdr))))))

;;;; What is outstanding

(ert-deftest harness-supervisor-plan-outstanding-is-one-line-of-what-runs-and-waits ()
  "Running steps and the pending steps that can start; held and superseded ones do not count."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((sid (harness-supervisor-plan-test-session)))
        (should-not (harness-call 'agent/outstanding sid))
        (harness-supervisor-plan-test-submit
         sid
         (harness-supervisor-plan-test-step-input "a")
         (harness-supervisor-plan-test-step-input "b" :tier "medium")
         (harness-supervisor-plan-test-step-input "c" :after '("a" "b"))
         (harness-supervisor-plan-test-step-input "d" :after '("c")))
        (should (equal "Supervisor plan: 2 steps running, 2 waiting" (harness-call 'agent/outstanding sid)))
        (let ((plan-id (plist-get (harness-supervisor-plan-test-plan sid) :id)))
          (cl-flet ((mark (step state)
                      (harness-supervisor--update-step sid plan-id step :state state)))
            (mark "a" "done")
            (should (equal "Supervisor plan: 1 step running, 2 waiting" (harness-call 'agent/outstanding sid)))
            (mark "b" "done")
            (should (equal "Supervisor plan: 2 steps waiting" (harness-call 'agent/outstanding sid)))
            (mark "c" "pending")
            (mark "d" "pending")
            ;; c is ready, d waits for c: both can start.
            (should (equal "Supervisor plan: 2 steps waiting" (harness-call 'agent/outstanding sid)))
            (mark "a" "failed")
            ;; c waits for a failed step, and d for c: held, not outstanding.
            (should-not (harness-call 'agent/outstanding sid))
            (mark "a" "done")
            (mark "c" "running")
            (should (equal "Supervisor plan: 1 step running, 1 waiting" (harness-call 'agent/outstanding sid)))
            (mark "c" "cancelled")
            (should-not (harness-call 'agent/outstanding sid))
            (mark "c" "interrupted")
            (should-not (harness-call 'agent/outstanding sid))
            (mark "c" "done")
            (should (equal "Supervisor plan: 1 step waiting" (harness-call 'agent/outstanding sid)))
            (mark "d" "superseded")
            (should-not (harness-call 'agent/outstanding sid))))
        ;; Added to what other handlers said, not replacing it.
        (harness-supervisor--update-step sid (plist-get (harness-supervisor-plan-test-plan sid) :id)
                                         "d" :state "running")
        (should (equal "2 workers; Supervisor plan: 1 step running"
                       (harness-supervisor--outstanding "2 workers" sid)))))))

(ert-deftest harness-supervisor-plan-a-session-with-no-plans-has-nothing-outstanding ()
  "The filter is silent for sessions that never planned, whatever the mode."
  (harness-supervisor-plan-test-with
    (let ((hands-on (harness-supervisor-plan-test-session :ext '(:supervisor :false)))
          (supervising (harness-supervisor-plan-test-session)))
      (should-not (harness-call 'agent/outstanding hands-on))
      (should-not (harness-call 'agent/outstanding supervising))
      (should (equal "other" (harness-run-filter 'agent/outstanding "other" supervising))))))

(ert-deftest harness-supervisor-plan-workers-carry-on-when-the-mode-is-switched-off ()
  "Turning supervisor mode off mid-plan leaves the workers, and their reports, as they are."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-behave "s1" '(reply "Done s1." 0.6))
      (harness-supervisor-plan-test-submit sid
                                           (harness-supervisor-plan-test-step-input "s1")
                                           (harness-supervisor-plan-test-step-input "s2" :after '("s1")))
      (harness-call 'supervisor/set sid :false)
      (should (equal "Supervisor plan: 1 step running, 1 waiting" (harness-call 'agent/outstanding sid)))
      (harness-supervisor-plan-test-wait-state sid "s2" "done")
      (let ((reports (harness-supervisor-plan-test-wait-reports sid 1)))
        (should (string-match-p "finished" (car reports)))))))

;;;; Stopping what runs outside the turn

(defun harness-supervisor-plan-test-as-task (sid)
  "Make session SID the session of a task, as far as the plan engine can tell."
  (harness-register-method 'task/for-session
                           (lambda (id) (and (equal id sid) (list :id "t-1" :session sid)))))

(defun harness-supervisor-plan-test-requests-of (session-id)
  "Return the requests that session SESSION-ID made, oldest first."
  (nreverse (cl-remove-if-not (lambda (r) (equal session-id (plist-get r :session)))
                              (copy-sequence harness-supervisor-plan-test--requests))))

(defmacro harness-supervisor-plan-test-with-held-fork (settle &rest body)
  "Run BODY with the first `session/fork' held until SETTLE is called.
SETTLE is bound to a function of `resolve' or `reject'.  `resolve'
forks now and settles the held promise with the fork, returning its
id, so the worker is made late; `reject' rejects it and returns nil.
Every fork after the first is made at once."
  (declare (indent 1))
  `(let* ((fork (harness-method-fn (gethash 'session/fork harness--methods)))
          (held nil)
          (,settle (lambda (how)
                     (if (eq how 'reject)
                         (progn (harness-reject (car held) '(error "The fork came too late")) nil)
                       (let ((made (apply fork (cdr held))))
                         (harness-resolve (car held) made)
                         (plist-get (harness-test-await made 10) :id))))))
     (harness-register-method
      'session/fork
      (lambda (&rest args)
        (if held
            (apply fork args)
          (setq held (cons (harness-make-promise) args))
          (car held))))
     ,@body))

(ert-deftest harness-supervisor-plan-stopping-interrupts-a-running-step-and-reports-it-once ()
  "`agent/stop-outstanding' interrupts a running step, for its reason, and cancels its worker.
The worker's late end changes nothing, the steps held on it never start,
and the supervisor is told once: at once in a task's session, queued in
any other.  Nothing is outstanding afterwards, and retry_step runs the
step again."
  (dolist (task '(nil t))
    (ert-info ((if task "a task's session" "another session"))
      (harness-supervisor-plan-test-with
        (let* ((sid (harness-supervisor-plan-test-session))
               (worker (harness-supervisor-plan-test-running-plan sid))
               (ended nil))
          (when task (harness-supervisor-plan-test-as-task sid))
          (harness-on 'agent/turn-ended (lambda (id reason) (when (equal id worker) (push reason ended))))
          (setq harness-supervisor-plan-test--requests nil)
          (should (equal "Supervisor plan: 1 step interrupted"
                         (harness-call 'agent/stop-outstanding sid "its task was returned to the queue")))
          ;; At once: the step is interrupted, nothing runs it, and its call has its result.
          (let ((s1 (harness-supervisor-plan-test-step sid "s1")))
            (should (equal "interrupted" (plist-get s1 :state)))
            (should (equal "its task was returned to the queue" (plist-get s1 :error)))
            (should (equal worker (plist-get s1 :session))))
          (should (zerop (hash-table-count harness-supervisor--live)))
          (should (zerop (hash-table-count harness-supervisor--spawns)))
          (let* ((call (harness-supervisor-plan-test-spawn-call-of sid worker))
                 (results (harness-supervisor-plan-test-spawn-results sid call))
                 (output (plist-get (car results) :output)))
            (should (= 1 (length results)))
            (should (plist-get (car results) :is-error))
            (should (string-match-p "its task was returned to the queue" output))
            (should (string-match-p (format "\\[step s1 (Title of s1) interrupted on demo:medium, session %s]"
                                            (regexp-quote worker))
                                    output)))
          ;; The worker's turn is cancelled, and its end changes nothing.
          (harness-test-wait (lambda () ended) 10 "the worker's turn to end")
          (should (equal '(cancelled) ended))
          (accept-process-output nil 0.3)
          (let ((s1 (harness-supervisor-plan-test-step sid "s1")))
            (should (equal "interrupted" (plist-get s1 :state)))
            (should (equal "its task was returned to the queue" (plist-get s1 :error)))
            (should (= 1 (plist-get s1 :attempts))))
          ;; The steps held on it are still pending and never started.
          (dolist (id '("s2" "s3"))
            (let ((step (harness-supervisor-plan-test-step sid id)))
              (should (equal "pending" (plist-get step :state)))
              (should (= 0 (plist-get step :attempts)))
              (should-not (plist-get step :session))
              (should-not (harness-supervisor-plan-test-step-request id))))
          (should-not (harness-supervisor-plan-test-requests-of-kind 'subagent))
          (should-not (cl-some (lambda (hint) (string-match-p "done on" hint))
                               (harness-supervisor-plan-test-hints sid)))
          ;; One report from the harness, naming the step and why.
          (let ((texts (if task
                           (progn (harness-supervisor-plan-test-wait-reports sid 1)
                                  (harness-supervisor-plan-test-wait-idle sid)
                                  (harness-supervisor-plan-test-reports sid))
                         (let ((queue (plist-get (harness-call 'session/get sid) :queue)))
                           (should (cl-every (lambda (item) (equal (harness-sender-system "supervisor")
                                                                   (plist-get item :from)))
                                             queue))
                           (mapcar (lambda (item) (plist-get item :text)) queue)))))
            (should (= 1 (length texts)))
            (let ((text (car texts)))
              (should (string-prefix-p
                       (concat "Supervisor report: the plan's workers were stopped, interrupting 1 running step: s1.\n"
                               "Why: its task was returned to the queue.\n"
                               "Nothing runs or starts again on its own: decide for the step below.\n\n"
                               "Supervisor report: step s1 (Title of s1) was interrupted.\n"
                               "It ran on tier medium, model demo:medium (attempt 1).\n"
                               "Why: its task was returned to the queue.\n")
                       text))
              (should (string-match-p (format "Its worker is session %s" (regexp-quote worker)) text))
              (should (string-match-p "Held on it, pending until it is done: s2 (Title of s2), s3 (Title of s3)\\." text))
              (should-not (string-match-p "Still running" text))
              (should (string-match-p "Decide: retry_step s1 to run it again" text))))
          ;; In a session that is not a task's no turn was started for it.
          (unless task
            (should-not (harness-supervisor-plan-test-requests-of-kind 'main))
            (should-not (harness-call 'agent/running sid)))
          (should-not (harness-call 'agent/outstanding sid))
          ;; Stopping again finds nothing.
          (should-not (harness-call 'agent/stop-outstanding sid "its task was returned to the queue"))
          ;; retry_step runs it again, and the steps held on it follow.
          (should-not (plist-get (harness-supervisor-plan-test-run sid "retry_step" '(:step "s1" :reason "the task is back"))
                                 :is-error))
          (harness-supervisor-plan-test-wait-state sid "s3" "done")
          (let ((s1 (harness-supervisor-plan-test-step sid "s1")))
            (should (equal "done" (plist-get s1 :state)))
            (should (= 2 (plist-get s1 :attempts)))
            (should (equal (list :attempt 1 :session worker :model "demo:medium"
                                 :error "its task was returned to the queue")
                           (plist-get s1 :previous))))
          (harness-supervisor-plan-test-wait-idle sid))))))

(ert-deftest harness-supervisor-plan-steps-stopped-together-are-one-report-and-one-refused-turn ()
  "Every step interrupted at once goes in one message, so a session whose task
waits in the queue refuses one turn for them, and keeps the message.  With no
reason given, the steps were interrupted as their task went back to the queue."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session))
          (refused 0))
      (harness-supervisor-plan-test-behave "a" 'hold)
      (harness-supervisor-plan-test-behave "b" 'hold)
      (harness-supervisor-plan-test-submit sid
                                           (harness-supervisor-plan-test-step-input "a")
                                           (harness-supervisor-plan-test-step-input "b" :tier "medium")
                                           (harness-supervisor-plan-test-step-input "c" :after '("a" "b")))
      (let ((workers (list (harness-supervisor-plan-test-worker sid "a")
                           (harness-supervisor-plan-test-worker sid "b"))))
        (harness-supervisor-plan-test-wait-idle sid)
        ;; The session of a task that waits in the queue: as the tasks
        ;; module's gate does, it takes no turn a message of the harness's starts.
        (harness-supervisor-plan-test-as-task sid)
        (harness-add-filter 'agent/before-turn
                            (lambda (value next session)
                              (funcall next (if (equal (plist-get session :id) sid)
                                                (progn (cl-incf refused)
                                                       (list :proceed nil :reason "its task waits in the queue"))
                                              value))
                              nil)
                            5)
        (setq harness-supervisor-plan-test--requests nil)
        ;; Added to what the handlers before it stopped.
        (should (equal "a sub-agent; Supervisor plan: 2 steps interrupted"
                       (harness-run-filter 'agent/stop-outstanding "a sub-agent" sid nil)))
        (should (equal '("interrupted" "interrupted" "pending")
                       (mapcar (lambda (id) (harness-supervisor-plan-test-state sid id)) '("a" "b" "c"))))
        (dolist (id '("a" "b"))
          (should (equal "its task was returned to the queue"
                         (plist-get (harness-supervisor-plan-test-step sid id) :error))))
        (harness-test-wait (lambda () (not (cl-some (lambda (w) (harness-call 'agent/running w)) workers)))
                           10 "the workers to stop")
        (accept-process-output nil 0.3)
        (should (= 1 refused))
        (let ((reports (harness-supervisor-plan-test-reports sid)))
          (should (= 1 (length reports)))
          (let ((text (car reports)))
            (should (string-prefix-p
                     (concat "Supervisor report: the plan's workers were stopped, interrupting 2 running steps: a, b.\n"
                             "Why: its task was returned to the queue.\n"
                             "Nothing runs or starts again on its own: decide for each step below.\n\n"
                             "Supervisor report: step a (Title of a) was interrupted.\n")
                     text))
            (should (string-match-p "\n\nSupervisor report: step b (Title of b) was interrupted\\.\n" text))
            (should (string-match-p "Decide: retry_step a to run it again" text))
            (should (string-match-p "Decide: retry_step b to run it again" text))
            ;; Neither is reported as running while the other is reported.
            (should-not (string-match-p "Still running" text))))
        ;; The model was asked nothing, the steps stay as they are, and nothing is outstanding.
        (should-not (harness-supervisor-plan-test-requests-of-kind 'main))
        (should-not (harness-supervisor-plan-test-requests-of-kind 'subagent))
        (should (equal '("interrupted" "interrupted" "pending")
                       (mapcar (lambda (id) (harness-supervisor-plan-test-state sid id)) '("a" "b" "c"))))
        (should-not (harness-call 'agent/outstanding sid))))))

(ert-deftest harness-supervisor-plan-stopping-with-nothing-running-changes-nothing ()
  "A session with no plan, or none of whose steps runs, has nothing to stop."
  (harness-supervisor-plan-test-with
    (let ((none (harness-supervisor-plan-test-session))
          (sid (harness-supervisor-plan-test-session)))
      (should-not (harness-call 'agent/stop-outstanding none "its task was returned to the queue"))
      (should-not (harness-call 'agent/stop-outstanding "no-such-session"))
      (should (equal "a sub-agent" (harness-run-filter 'agent/stop-outstanding "a sub-agent" none nil)))
      ;; A failed step, a step held on it, and a step done.
      (harness-supervisor-plan-test-behave "s1" 'error)
      (harness-supervisor-plan-test-submit sid
                                           (harness-supervisor-plan-test-step-input "s1")
                                           (harness-supervisor-plan-test-step-input "s2" :after '("s1"))
                                           (harness-supervisor-plan-test-step-input "s3" :tier "medium"))
      (harness-supervisor-plan-test-wait-state sid "s1" "failed")
      (harness-supervisor-plan-test-wait-state sid "s3" "done")
      (harness-supervisor-plan-test-wait-reports sid 1)
      (harness-supervisor-plan-test-wait-idle sid)
      (let ((plans (harness-supervisor-plan-test-plans sid))
            (nodes (length (harness-call 'session/nodes sid))))
        (setq harness-supervisor-plan-test--requests nil)
        (should-not (harness-call 'agent/stop-outstanding sid "its task was returned to the queue"))
        (should (equal "a sub-agent" (harness-run-filter 'agent/stop-outstanding "a sub-agent" sid nil)))
        (accept-process-output nil 0.2)
        (should (equal plans (harness-supervisor-plan-test-plans sid)))
        (should (= nodes (length (harness-call 'session/nodes sid))))
        (should-not (plist-get (harness-call 'session/get sid) :queue))
        (should-not harness-supervisor-plan-test--requests)))))

(ert-deftest harness-supervisor-plan-a-step-left-running-by-a-restart-is-stopped-too ()
  "A step stored running that no worker runs any more counts as outstanding,
so stopping interrupts it as well: nothing is outstanding afterwards, and
the recovery finds nothing left to do."
  (harness-supervisor-plan-test-with
    (let* ((sid (harness-supervisor-plan-test-session))
           (worker (harness-supervisor-plan-test-running-plan sid)))
      (harness-supervisor-plan-test-restart sid)
      (should (equal "Supervisor plan: 1 step running, 2 waiting" (harness-call 'agent/outstanding sid)))
      (should (equal "Supervisor plan: 1 step interrupted"
                     (harness-call 'agent/stop-outstanding sid "its task was returned to the queue")))
      (should (equal "interrupted" (harness-supervisor-plan-test-state sid "s1")))
      (should-not (harness-call 'agent/outstanding sid))
      ;; Its call, found in the transcript, has its result.
      (let ((results (harness-supervisor-plan-test-spawn-results
                      sid (harness-supervisor-plan-test-spawn-call-of sid worker))))
        (should (= 1 (length results)))
        (should (string-match-p "interrupted" (plist-get (car results) :output))))
      (should (= 1 (length (plist-get (harness-call 'session/get sid) :queue))))
      (harness-supervisor--recover)
      (should (= 1 (length (plist-get (harness-call 'session/get sid) :queue))))
      (should (equal "its task was returned to the queue"
                     (plist-get (harness-supervisor-plan-test-step sid "s1") :error))))))

(ert-deftest harness-supervisor-plan-a-worker-made-after-its-step-was-interrupted-never-gets-it ()
  "A step interrupted while its worker is made is reported at once; the worker,
made later, is given up: it is never prompted, and nothing shows it."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-with-held-fork settle
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-submit sid
                                             (harness-supervisor-plan-test-step-input "s1" :tier "medium")
                                             (harness-supervisor-plan-test-step-input "s2" :after '("s1")))
        (should (equal "running" (harness-supervisor-plan-test-state sid "s1")))
        (should (equal "Supervisor plan: 1 step running, 1 waiting" (harness-call 'agent/outstanding sid)))
        (should (equal "Supervisor plan: 1 step interrupted"
                       (harness-call 'agent/stop-outstanding sid "its task was pre-empted")))
        (let ((s1 (harness-supervisor-plan-test-step sid "s1")))
          (should (equal "interrupted" (plist-get s1 :state)))
          (should (equal "its task was pre-empted" (plist-get s1 :error)))
          (should-not (plist-get s1 :session)))
        ;; Reported, with no worker to point at.
        (let ((queue (plist-get (harness-call 'session/get sid) :queue)))
          (should (= 1 (length queue)))
          (should (string-match-p "step s1 (Title of s1) was interrupted\\.\n" (plist-get (car queue) :text)))
          (should (string-match-p "Why: its task was pre-empted\\." (plist-get (car queue) :text)))
          (should-not (string-match-p "Its worker is session" (plist-get (car queue) :text))))
        ;; The worker is made now, too late.
        (let ((late (funcall settle 'resolve)))
          (should (harness-call 'session/exists-p late))
          (accept-process-output nil 0.3)
          (should-not (harness-call 'agent/running late))
          (should-not (harness-supervisor-plan-test-requests-of late))
          ;; It holds the transcript it was forked from, and no message of its own.
          (should-not (cl-some (lambda (node) (equal late (plist-get node :session)))
                               (harness-supervisor-plan-test-nodes late 'user)))
          (should-not (cl-some (lambda (node) (string-match-p "^## Step s1:" (plist-get node :content)))
                               (harness-supervisor-plan-test-nodes late 'user)))
          (should-not (harness-supervisor-plan-test-spawn-call-of sid late)))
        (should-not (harness-supervisor-plan-test-step-request "s1"))
        (let ((s1 (harness-supervisor-plan-test-step sid "s1")))
          (should (equal "interrupted" (plist-get s1 :state)))
          (should-not (plist-get s1 :session)))
        (should (equal "pending" (harness-supervisor-plan-test-state sid "s2")))
        (should (zerop (hash-table-count harness-supervisor--live)))
        (should-not (harness-supervisor-plan-test-spawn-calls sid))
        (should (= 1 (length (plist-get (harness-call 'session/get sid) :queue))))
        (should-not (harness-call 'agent/outstanding sid))))))

(ert-deftest harness-supervisor-plan-a-late-worker-of-an-interrupted-attempt-leaves-the-next-alone ()
  "The worker of an interrupted attempt that is made, or fails, after the step
started again changes nothing: the new attempt runs on its own worker and is done."
  (dolist (late '(resolve reject))
    (ert-info ((format "the late worker: %s" late))
      (harness-supervisor-plan-test-with
        (harness-supervisor-plan-test-with-held-fork settle
          (let ((sid (harness-supervisor-plan-test-session)))
            (harness-supervisor-plan-test-behave "s1" '(reply "Second attempt." 0.6))
            (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "s1" :tier "medium"))
            (harness-call 'agent/stop-outstanding sid "its task was returned to the queue")
            (should (equal "interrupted" (harness-supervisor-plan-test-state sid "s1")))
            (should-not (plist-get (harness-supervisor-plan-test-run sid "retry_step" '(:step "s1" :reason "the task is back"))
                                   :is-error))
            (let* ((second (harness-supervisor-plan-test-worker sid "s1"))
                   ;; The first attempt's worker comes now, while the second runs.
                   (first (funcall settle late)))
              (accept-process-output nil 0.1)
              (let ((s1 (harness-supervisor-plan-test-step sid "s1")))
                (should (equal "running" (plist-get s1 :state)))
                (should (equal second (plist-get s1 :session)))
                (should (= 2 (plist-get s1 :attempts))))
              (harness-supervisor-plan-test-wait-state sid "s1" "done")
              (let ((s1 (harness-supervisor-plan-test-step sid "s1")))
                (should (equal second (plist-get s1 :session)))
                (should (equal "Second attempt." (plist-get s1 :result))))
              ;; Only the second worker was given the step.
              (should (= 1 (cl-count "s1" harness-supervisor-plan-test--requests
                                     :key (lambda (r) (plist-get r :step)) :test #'equal)))
              (when first
                (should-not (equal first second))
                (should-not (harness-supervisor-plan-test-requests-of first))
                (should-not (harness-supervisor-plan-test-spawn-call-of sid first)))
              (should (= 1 (length (harness-supervisor-plan-test-spawn-calls sid)))))
            (harness-supervisor-plan-test-wait-idle sid)
            ;; Nothing said the step failed.
            (should-not (cl-some (lambda (text) (string-match-p "step s1 (Title of s1) failed" text))
                                 (harness-supervisor-plan-test-reports sid)))
            (should (zerop (hash-table-count harness-supervisor--live)))))))))

(ert-deftest harness-supervisor-plan-stopping-a-worker-stops-its-own-sub-agents ()
  "What a worker started that runs on without its turn stops with it: its
sub-agent is stopped and reports to it, and nothing the step started is
left running."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session))
          (step-requests (lambda (id) (cl-remove id harness-supervisor-plan-test--requests
                                                 :key (lambda (r) (plist-get r :step)) :test-not #'equal))))
      ;; The worker starts a sub-agent, then works on.
      (harness-supervisor-plan-test-behave
       "s1" '(events (:type tool-call :id "call-helper" :name "spawn_agent"
                            :input (:prompt "## Step g1: Help.\n\nHelp with it." :name "helper")))
       'hold)
      (harness-supervisor-plan-test-behave "g1" 'hold)
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "s1" :tier "medium"))
      (let* ((worker (harness-supervisor-plan-test-worker sid "s1"))
             (helper (harness-test-wait (lambda () (plist-get (car (funcall step-requests "g1")) :session))
                                        10 "the worker's sub-agent to run")))
        (harness-test-wait (lambda () (= 2 (length (funcall step-requests "s1")))) 10 "the worker to work on")
        (should (harness-call 'agent/running helper))
        (should (equal "Sub-agent helper running" (harness-call 'agent/outstanding worker)))
        (should (equal "Supervisor plan: 1 step interrupted"
                       (harness-call 'agent/stop-outstanding sid "its task was returned to the queue")))
        ;; The sub-agent is cancelled, and its report reaches the worker.
        (harness-test-wait (lambda ()
                             (cl-some (lambda (node) (equal "sub-agent" (plist-get (harness-node-sender node) :source)))
                                      (harness-supervisor-plan-test-nodes worker 'user)))
                           10 "the sub-agent's report")
        (harness-test-wait (lambda () (not (or (harness-call 'agent/running helper)
                                               (harness-call 'agent/running worker))))
                           10 "the worker and its sub-agent to stop")
        (should (cl-some (lambda (node) (string-match-p "its task was returned to the queue" (plist-get node :content)))
                         (harness-supervisor-plan-test-nodes worker 'user)))
        (should-not (harness-call 'agent/outstanding worker))
        (should-not (harness-call 'agent/outstanding sid))
        ;; Whatever the worker does now changes no step.
        (should (equal "interrupted" (harness-supervisor-plan-test-state sid "s1")))
        (should (= 1 (length (harness-supervisor-plan-test-spawn-results
                              sid (harness-supervisor-plan-test-spawn-call-of sid worker)))))
        ;; The supervisor's report waits for its next message.
        (should-not (harness-call 'agent/running sid))
        (should (= 1 (length (plist-get (harness-call 'session/get sid) :queue))))))))

;;;; Approval

(ert-deftest harness-supervisor-plan-in-ask-mode-the-user-approves-the-plan-before-a-worker-starts ()
  "submit_plan goes through the permission chain: nothing starts until the user says yes."
  (harness-supervisor-plan-test-with-modules (perms)
    (harness-remove-filter 'permission/decide #'harness-supervisor-plan-test--allow)
    (harness-supervisor-plan-test-stub-starts
      (let* ((sid (harness-supervisor-plan-test-session :permission-mode 'ask))
             (input (harness-supervisor-plan-test-plan-input (harness-supervisor-plan-test-step-input "s1")))
             (done (harness-call 'tools/execute sid (list :id "call-1" :name "submit_plan" :input input))))
        (let ((pending (harness-test-wait (lambda () (car (harness-call 'permission/pending sid))) 10
                                          "the approval prompt")))
          (should (equal "submit_plan" (plist-get (plist-get pending :payload) :tool)))
          (should (string-match-p "Submit plan: The plan" (plist-get (plist-get pending :payload) :title)))
          (should-not (harness-supervisor-plan-test-plans sid))
          (should-not harness-supervisor-plan-test--calls)
          (harness-call 'permission/answer sid (plist-get pending :id) "allow-once"))
        (should-not (plist-get (harness-test-await done) :is-error))
        (should (harness-supervisor-plan-test-plans sid))
        (should (= 1 (length harness-supervisor-plan-test--calls)))))))

(ert-deftest harness-supervisor-plan-the-user-can-refuse-a-plan ()
  "A plan the user refuses starts nothing and leaves no plan."
  (harness-supervisor-plan-test-with-modules (perms)
    (harness-remove-filter 'permission/decide #'harness-supervisor-plan-test--allow)
    (harness-supervisor-plan-test-stub-starts
      (let* ((sid (harness-supervisor-plan-test-session :permission-mode 'ask))
             (input (harness-supervisor-plan-test-plan-input (harness-supervisor-plan-test-step-input "s1")))
             (done (harness-call 'tools/execute sid (list :id "call-1" :name "submit_plan" :input input))))
        (let ((pending (harness-test-wait (lambda () (car (harness-call 'permission/pending sid))) 10
                                          "the approval prompt")))
          (harness-call 'permission/answer sid (plist-get pending :id) "deny-once"))
        (should (plist-get (harness-test-await done) :is-error))
        (should-not (harness-supervisor-plan-test-plans sid))
        (should-not harness-supervisor-plan-test--calls)))))

;; The user approves a plan in ask mode alone.  In every other mode, and
;; whenever the user is away, the plan is allowed at once and the judge of
;; auto mode never rules on it.  The probe below is a judge that would
;; deny every call: a plan that gets through was not put to it.

(defvar harness-perms-auto-model)
(defvar harness-perms-rules)

(defun harness-supervisor-plan-test-judge-provider ()
  "Register the provider `judge', a model that denies every call it is asked about.
Return a function that gives the requests the judge got, newest first."
  (let ((requests nil))
    (harness-define-provider 'judge
      :label "Judge"
      :complete (lambda (req)
                  (push req requests)
                  (let ((cb (plist-get req :on-event)))
                    (dolist (ev '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"a detail in the plan looks insecure\"}")
                                  (:type done :stop-reason end-turn)))
                      (let ((ev ev)) (run-at-time 0.01 nil (lambda () (funcall cb ev))))))
                  (list :cancel #'ignore)))
    (lambda () requests)))

(defun harness-supervisor-plan-test-judged-p (probe)
  "Return non-nil when the judge PROBE does answer the call of a session.
The session does not supervise, is non-interactive and in auto mode, so
the judge decides its call to submit_plan, and denies it.  A probe that
did not answer would make \"the judge was never asked\" mean nothing."
  (let* ((hands-on (harness-supervisor-plan-test-session
                    :permission-mode 'auto :non-interactive t :ext '(:supervisor :false)))
         (decision (harness-test-await
                    (harness-run-filter-async
                     'permission/decide (list :behavior 'ask)
                     (list :session (harness-call 'session/get hands-on) :tool "submit_plan"
                           :input nil :kind 'meta :call-id "call-hands-on"))
                    10)))
    (and (eq 'deny (plist-get decision :behavior))
         (= 1 (length (funcall probe))))))

(ert-deftest harness-supervisor-plan-in-auto-mode-the-plan-starts-with-no-prompt-and-no-judge ()
  "The judge is not asked about a plan, so a detail in it cannot make the judge refuse."
  (harness-supervisor-plan-test-with-modules (perms)
    (harness-remove-filter 'permission/decide #'harness-supervisor-plan-test--allow)
    (harness-supervisor-plan-test-stub-starts
      (let* ((probe (harness-supervisor-plan-test-judge-provider))
             (harness-perms-auto-model "judge:x")
             (sid (harness-supervisor-plan-test-session :permission-mode 'auto))
             (input (harness-supervisor-plan-test-plan-input (harness-supervisor-plan-test-step-input "s1")))
             (result (harness-supervisor-plan-test-run sid "submit_plan" input "call-1")))
        (should-not (plist-get result :is-error))
        (should (plist-get result :end-turn))
        ;; Nobody was asked: nothing is pending, and the step runs.
        (should-not (harness-call 'permission/pending sid))
        (should (harness-supervisor-plan-test-plans sid))
        (should (= 1 (length harness-supervisor-plan-test--calls)))
        (should-not (funcall probe))
        ;; The probe does hear of calls that are not plans of a supervisor.
        (should (harness-supervisor-plan-test-judged-p probe))))))

(ert-deftest harness-supervisor-plan-in-every-mode-but-ask-and-when-the-user-is-away-the-plan-starts-at-once ()
  "Yolo, accept-edits, and ask mode with the user away, like auto mode: no prompt, no judge."
  (dolist (settings '((:permission-mode yolo)
                      (:permission-mode accept-edits)
                      (:permission-mode ask :non-interactive t)
                      (:permission-mode auto :non-interactive t)))
    (ert-info ((format "%S" settings))
      (harness-supervisor-plan-test-with-modules (perms)
        (harness-remove-filter 'permission/decide #'harness-supervisor-plan-test--allow)
        (harness-supervisor-plan-test-stub-starts
          (let* ((probe (harness-supervisor-plan-test-judge-provider))
                 (harness-perms-auto-model "judge:x")
                 (sid (apply #'harness-supervisor-plan-test-session settings))
                 (input (harness-supervisor-plan-test-plan-input (harness-supervisor-plan-test-step-input "s1")))
                 (result (harness-supervisor-plan-test-run sid "submit_plan" input "call-1")))
            (should-not (plist-get result :is-error))
            (should-not (harness-call 'permission/pending sid))
            (should (harness-supervisor-plan-test-plans sid))
            (should (= 1 (length harness-supervisor-plan-test--calls)))
            (should-not (funcall probe))
            (should (harness-supervisor-plan-test-judged-p probe))))))))

(ert-deftest harness-supervisor-plan-in-auto-mode-a-retry-needs-no-approval-and-no-judge ()
  "retry_step is allowed like submit_plan, and the step runs again on a new worker."
  (harness-supervisor-plan-test-with-modules (perms)
    (harness-remove-filter 'permission/decide #'harness-supervisor-plan-test--allow)
    (harness-supervisor-plan-test-stub-starts
      (let* ((probe (harness-supervisor-plan-test-judge-provider))
             (harness-perms-auto-model "judge:x")
             (sid (harness-supervisor-plan-test-session :permission-mode 'auto)))
        (should-not (plist-get (harness-supervisor-plan-test-run
                                sid "submit_plan"
                                (harness-supervisor-plan-test-plan-input
                                 (harness-supervisor-plan-test-step-input "s1")))
                               :is-error))
        ;; The worker of the step failed.
        (harness-supervisor--update-step sid (plist-get (harness-supervisor-plan-test-plan sid) :id) "s1"
                                         :state "failed" :error "boom")
        (let ((result (harness-supervisor-plan-test-run sid "retry_step" '(:step "s1" :reason "once more"))))
          (should-not (plist-get result :is-error))
          (should (string-match-p "runs again" (plist-get result :content))))
        (should-not (harness-call 'permission/pending sid))
        (should (= 2 (plist-get (harness-supervisor-plan-test-step sid "s1") :attempts)))
        (should (= 2 (length harness-supervisor-plan-test--calls)))
        (should-not (funcall probe))
        (should (harness-supervisor-plan-test-judged-p probe))))))

(ert-deftest harness-supervisor-plan-a-plan-that-waits-for-approval-starts-when-the-user-goes-away ()
  "Switching the session to non-interactive decides the waiting plan as a new one is: allowed, not judged."
  (harness-supervisor-plan-test-with-modules (perms)
    (harness-remove-filter 'permission/decide #'harness-supervisor-plan-test--allow)
    (harness-supervisor-plan-test-stub-starts
      (let* ((probe (harness-supervisor-plan-test-judge-provider))
             (harness-perms-auto-model "judge:x")
             (sid (harness-supervisor-plan-test-session :permission-mode 'ask))
             (input (harness-supervisor-plan-test-plan-input (harness-supervisor-plan-test-step-input "s1")))
             (done (harness-call 'tools/execute sid (list :id "call-1" :name "submit_plan" :input input))))
        (harness-test-wait (lambda () (car (harness-call 'permission/pending sid))) 10 "the approval prompt")
        (should-not (harness-supervisor-plan-test-plans sid))
        (harness-call 'session/update sid :non-interactive t)
        (should-not (plist-get (harness-test-await done) :is-error))
        (should (harness-supervisor-plan-test-plans sid))
        (should-not (harness-call 'permission/pending sid))
        (should-not (funcall probe))))))

(ert-deftest harness-supervisor-plan-a-standing-deny-rule-still-refuses-a-plan-in-auto-mode ()
  "Only a call that would ask is allowed: what a rule denied stays denied, and nothing starts."
  (harness-supervisor-plan-test-with-modules (perms)
    (harness-remove-filter 'permission/decide #'harness-supervisor-plan-test--allow)
    (harness-supervisor-plan-test-stub-starts
      (let* ((probe (harness-supervisor-plan-test-judge-provider))
             (harness-perms-auto-model "judge:x")
             (harness-perms-rules '((:tool "submit_plan" :behavior deny)))
             (sid (harness-supervisor-plan-test-session :permission-mode 'auto))
             (input (harness-supervisor-plan-test-plan-input (harness-supervisor-plan-test-step-input "s1")))
             (result (harness-supervisor-plan-test-run sid "submit_plan" input "call-1")))
        (should (plist-get result :is-error))
        (should (string-match-p "standing rule" (plist-get result :content)))
        (should-not (harness-supervisor-plan-test-plans sid))
        (should-not harness-supervisor-plan-test--calls)
        (should-not (harness-call 'permission/pending sid))
        (should-not (funcall probe))))))

;;;; Handing the work in
;;
;; A task's supervisor hands the work in as done only once it is: the
;; permission gate refuses hand_in while a step of its plans is open.
;; These tests call the tool in a session that is no task's, so a
;; hand-in the gate lets by fails in the tool itself, saying so.

(defconst harness-supervisor-plan-test-hand-in
  '(:problem "The parser breaks on nested quotes." :summary "The parser is fixed."
    :evidence ("Read the diff: it does what the plan said."))
  "The input of a hand_in call that hands the work in as done.")

(defun harness-supervisor-plan-test-hand-in (sid &rest input)
  "Call hand_in in session SID with INPUT before the fields of a hand-in as done; return the result."
  (harness-supervisor-plan-test-run sid "hand_in" (append input harness-supervisor-plan-test-hand-in)))

(defun harness-supervisor-plan-test-let-by-p (result)
  "Non-nil when RESULT is that of a hand_in the gate let by, in a session that is no task's."
  (and (not (plist-get result :denied))
       (string-match-p "this session is no task" (plist-get result :content))))

(ert-deftest harness-supervisor-plan-the-steps-that-block-a-hand-in ()
  "A step blocks a hand-in while it is pending or running, or once it did not get done.
A step that did not get done stops blocking once a plan made after it
ended replaces it; a plan made while it still ran does not.  One stored
before steps kept when they ended counts any later plan.  A step that is
done or superseded never blocks."
  (harness-supervisor-plan-test-with
    (let* ((old (list :id "p-old" :created 100.0
                      :steps (list (list :id "a" :state "done" :ended 110.0)
                                   (list :id "b" :state "superseded")
                                   (list :id "c" :state "failed" :ended 120.0)
                                   (list :id "d" :state "interrupted" :ended 130.0)
                                   (list :id "e" :state "cancelled")
                                   (list :id "f" :state "failed" :ended 250.0)
                                   (list :id "g" :state "running"))))
           (new (list :id "p-new" :created 200.0
                      :steps (list (list :id "h" :state "done" :ended 210.0)
                                   (list :id "i" :state "failed" :ended 220.0)
                                   (list :id "j" :state "pending" :after '("i")))))
           (ids (lambda (plans)
                  (mapcar (lambda (pair) (format "%s/%s" (plist-get (car pair) :id) (plist-get (cdr pair) :id)))
                          (harness-supervisor--open-steps plans)))))
      ;; c, d and e ended before the new plan was made, f after it; the new plan's failure stands.
      (should (equal '("p-old/f" "p-old/g" "p-new/i" "p-new/j") (funcall ids (list old new))))
      ;; Alone, the old plan has nothing to replace its failures.
      (should (equal '("p-old/c" "p-old/d" "p-old/e" "p-old/f" "p-old/g") (funcall ids (list old))))
      ;; A plan without the time it was made replaces whatever came before it.
      (should (equal '("p-old/g" "p-new/i" "p-new/j")
                     (funcall ids (list old (harness-supervisor--with new :created nil)))))
      ;; Nothing blocks when every step is done or superseded, as when the plan finished.
      (let ((finished (list :id "p-1" :created 1.0
                            :steps (list (list :id "a" :state "done") (list :id "b" :state "superseded")))))
        (should (harness-supervisor--finished-p finished))
        (should-not (funcall ids (list finished))))
      (should-not (funcall ids nil)))))

(ert-deftest harness-supervisor-plan-a-hand-in-as-done-is-refused-while-a-step-is-open ()
  "The gate refuses hand_in for good while a step failed, is held, or runs, naming each.
It says the ways on.  Handing in as needing no merge is refused the
same; giving the task up with cannot_continue is not, and neither is the
hand-in of a session that does not supervise."
  (harness-supervisor-plan-test-with-modules (tools-handin)
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-failure-fixture sid)
      (harness-supervisor-plan-test-wait-state sid "s1" "failed")
      (harness-supervisor-plan-test-wait-reports sid 1)
      (harness-supervisor-plan-test-wait-idle sid)
      (let* ((plan-id (plist-get (harness-supervisor-plan-test-plan sid) :id))
             (result (harness-supervisor-plan-test-hand-in sid))
             (text (plist-get result :content)))
        (should (plist-get result :is-error))
        (should (plist-get result :denied))
        (should (string-prefix-p
                 (format (concat "Denied: supervisor mode: the work is not done, so the task cannot be handed in as done:"
                                 " step s1 (Title of s1) of plan %s failed;"
                                 " step s2 (Title of s2) of plan %s is pending, waiting for s1;"
                                 " step s3 (Title of s3) of plan %s is still running;"
                                 " step s4 (Title of s4) of plan %s is pending, waiting for s2, s3."
                                 " Run a step that did not get done again with retry_step (on a higher tier if its"
                                 " model was not up to it), or replace it with a new plan (submit_plan)."
                                 " A step that runs, or waits to start, is reported to you when it ends: wait for it,"
                                 " ending this turn with no_plan_needed."
                                 " If the task cannot be finished, call hand_in with cannot_continue true and say"
                                 " what blocks it.")
                         plan-id plan-id plan-id plan-id)
                 text)))
      ;; The failure is reported to a session that is no task's without a word of hand_in.
      (should-not (string-match-p "hand_in" (car (harness-supervisor-plan-test-reports sid))))
      (should (plist-get (harness-supervisor-plan-test-hand-in sid :no_merge t) :denied))
      (should (harness-supervisor-plan-test-let-by-p (harness-supervisor-plan-test-hand-in sid :cannot_continue t)))
      ;; A session that works hands-on hands in as it likes.
      (harness-call 'supervisor/set sid :false)
      (should (harness-supervisor-plan-test-let-by-p (harness-supervisor-plan-test-hand-in sid)))
      ;; Nothing was run again or decided for the steps.
      (should (equal '("failed" "pending" "running" "pending")
                     (mapcar (lambda (id) (harness-supervisor-plan-test-state sid id)) '("s1" "s2" "s3" "s4"))))
      (should (numberp (plist-get (harness-supervisor-plan-test-step sid "s1") :ended)))
      (should-not (plist-get (harness-supervisor-plan-test-step sid "s3") :ended))
      ;; Deleting the supervisor cancels the worker that is still working.
      (let ((worker (plist-get (harness-supervisor-plan-test-step sid "s3") :session)))
        (harness-call 'session/delete sid)
        (harness-test-wait (lambda () (not (harness-call 'agent/running worker))) 10 "the worker to stop")))))

(ert-deftest harness-supervisor-plan-a-new-plan-replaces-only-the-failures-it-was-made-after ()
  "A plan made after a step failed replaces it; a step of an older plan that fails later blocks again.
A retry that gets that step done lets the hand-in by."
  (harness-supervisor-plan-test-with-modules (tools-handin)
    (let ((harness-agent--cancel-grace 0.05)
          (sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-fail-first sid (harness-supervisor-plan-test-step-input "s1"))
      (should (string-match-p "step s1 (Title of s1) of plan p-[a-z0-9]+ failed"
                              (plist-get (harness-supervisor-plan-test-hand-in sid) :content)))
      ;; A new plan, made since s1 failed, replaces it; its step a1 runs until it is cancelled.
      (harness-supervisor-plan-test-behave "a1" 'hold)
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "a1"))
      (let ((worker (harness-test-wait
                     (lambda () (let ((w (plist-get (harness-supervisor-plan-test-step sid "a1" 1) :session)))
                                  (and w (harness-call 'session/exists-p w) (harness-call 'agent/running w) w)))
                     10 "the worker of a1 to run")))
        (let ((text (plist-get (harness-supervisor-plan-test-hand-in sid) :content)))
          (should (string-match-p "step a1 (Title of a1) of plan p-[a-z0-9]+ is still running\\." text))
          (should-not (string-match-p "step s1 " text)))
        ;; A plan made while a1 still runs does not replace it when it then fails.
        (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "b1"))
        (harness-supervisor-plan-test-wait-state sid "b1" "done" 2)
        (harness-call 'agent/cancel worker)
        (harness-supervisor-plan-test-wait-state sid "a1" "failed" 1)
        (harness-supervisor-plan-test-wait-idle sid)
        (should (< (plist-get (harness-supervisor-plan-test-plan sid 2) :created)
                   (plist-get (harness-supervisor-plan-test-step sid "a1" 1) :ended)))
        (let ((text (plist-get (harness-supervisor-plan-test-hand-in sid) :content)))
          (should (string-match-p "step a1 (Title of a1) of plan p-[a-z0-9]+ failed\\." text))
          (should-not (string-match-p "step [sb]1 " text))))
      ;; Run again, a1 gets done, and nothing blocks the hand-in any more.
      (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "a1") :is-error))
      (harness-supervisor-plan-test-wait-state sid "a1" "done" 1)
      (harness-supervisor-plan-test-wait-idle sid)
      (should (equal "failed" (harness-supervisor-plan-test-state sid "s1" 0)))
      (should (harness-supervisor-plan-test-let-by-p (harness-supervisor-plan-test-hand-in sid))))))

;;;; A task's supervisor

(defmacro harness-supervisor-plan-test-with-tasks (&rest body)
  "Run BODY with task mode too.
A task's session supervises, and a finished task waits for review."
  (declare (indent 0))
  `(let ((harness-acp--server-enabled nil)
         (harness-acp-token nil))
     (harness-supervisor-plan-test-with-modules (tools-handin tasks acp)
       (clrhash harness-tasks--table)
       (clrhash harness-tasks--starting)
       (clrhash harness-tasks--naming)
       (harness-tasks--forget-stores)
       (setq harness-tasks--loaded t
             harness-tasks--dirty nil
             harness-tasks--naming-pool (harness-tasks--naming-pool-new)
             harness-acp--clients nil)
       (let ((harness-naming-auto nil)
             (harness-tasks-max-running 3)
             (harness-tasks-require-verification t)
             (harness-tasks-permission-mode 'auto)
             (harness-tasks-non-interactive t)
             (harness-tasks-model "demo:scripted"))
         (unwind-protect (progn ,@body)
           (dolist (c (copy-sequence harness-acp--clients))
             (harness-acp--drop-client c)))))))

(defun harness-supervisor-plan-test-task (id)
  "Return task ID."
  (harness-call 'task/get id))

(defun harness-supervisor-plan-test--hand-in-on-report ()
  "Have a supervisor hand its work in when it is told its plan is finished.
hand_in needs the problem as well as the summary and the evidence."
  (setq harness-supervisor-plan-test--on-report
        (lambda (_text)
          (harness-supervisor-plan-test-call
           "hand_in" '(:problem "The parser breaks on nested quotes." :summary "The parser is fixed."
                       :evidence ("Read the diff: it does what the plan said."))))))

(ert-deftest harness-supervisor-plan-a-task-waits-for-its-workers-and-the-supervisor-hands-it-in ()
  "submit_plan ends the turn but not the task; the finished plan wakes the supervisor, whose hand_in ends it."
  (harness-supervisor-plan-test-with-tasks
    (let ((reviews nil))
      (harness-on 'task/review (lambda (task) (push (plist-get task :id) reviews)))
      (harness-supervisor-plan-test-behave "s1" '(reply "Fixed the parser." 0.8))
      (harness-supervisor-plan-test-behave "s2" '(reply "Committed it." 0.2))
      (setq harness-supervisor-plan-test--plan
            (harness-supervisor-plan-test-plan-input
             (harness-supervisor-plan-test-step-input "s1" :tier "medium")
             (harness-supervisor-plan-test-step-input "s2" :after '("s1") :prompt "Commit the change.")))
      (setq harness-supervisor-plan-test--on-report
            (lambda (_text)
              (harness-supervisor-plan-test-call
               "hand_in" '(:problem "The parser breaks on nested quotes." :summary "The parser is fixed and committed." :evidence ("Read the diff: it does what the plan said.")))))
      (let* ((id (plist-get (harness-call 'task/submit default-directory "Fix the parser") :id))
             (sid (plist-get (harness-supervisor-plan-test-task id) :session)))
        (should (harness-call 'supervisor/active-p sid))
        ;; The supervisor's turn ends on the plan; the task does not go to review.
        (harness-test-wait (lambda () (plist-get (harness-supervisor-plan-test-task id) :waiting)) 10
                           "the task to wait for its workers")
        (let ((task (harness-supervisor-plan-test-task id)))
          (should (eq 'active (plist-get task :state)))
          (should (eq 'active (plist-get task :column)))
          (should (string-match-p "\\`Supervisor plan: 1 step running, 1 waiting\\'" (plist-get task :waiting)))
          (should-not (plist-get task :outcome))
          (should-not (plist-get task :finished)))
        (should-not (harness-call 'agent/running sid))
        (should-not reviews)
        ;; The plan finishes: the supervisor is prompted, hands the work in, and the task is in review.
        (harness-test-wait (lambda () (eq 'review (plist-get (harness-supervisor-plan-test-task id) :state))) 15
                           "the task to be in review")
        (let ((task (harness-supervisor-plan-test-task id)))
          (should-not (plist-get task :waiting))
          (should (eq 'end-turn (plist-get task :outcome)))
          (should (plist-get task :finished)))
        (should (equal (list id) reviews))
        (let ((reports (harness-supervisor-plan-test-reports sid)))
          (should (= 1 (length reports)))
          (should (string-match-p "finished\\. All 2 steps are done" (car reports)))
          ;; A task's supervisor is told it can hand the work in.
          (should (string-match-p "hand_in once the work is checked and committed" (car reports))))
        (should (equal '("done" "done") (list (harness-supervisor-plan-test-state sid "s1")
                                              (harness-supervisor-plan-test-state sid "s2"))))
        (should (cl-find "hand_in" (harness-supervisor-plan-test-nodes sid 'tool-call)
                         :key (lambda (n) (plist-get n :tool)) :test #'equal))))))

;; A failed step blocks the hand-in: the supervisor of these tests hands
;; the work in on every report, the failure's too, is refused, and then
;; does what the test says (`harness-supervisor-plan-test--on-refusal').

(defun harness-supervisor-plan-test-results-of (sid tool)
  "Return the results of the calls of TOOL in session SID's transcript, oldest first."
  (let ((ids (mapcar (lambda (n) (plist-get n :call-id))
                     (cl-remove-if-not (lambda (n) (equal tool (plist-get n :tool)))
                                       (harness-supervisor-plan-test-nodes sid 'tool-call)))))
    (cl-remove-if-not (lambda (n) (member (plist-get n :call-id) ids))
                      (harness-supervisor-plan-test-nodes sid 'tool-result))))

(defun harness-supervisor-plan-test--refused-p (request)
  "Non-nil when REQUEST's last message holds a hand-in the gate refused.
Any of its results counts, not only its last block: a note the harness
adds to a denial, such as a non-interactive session's, comes after it."
  (cl-some (lambda (block)
             (and (equal (plist-get block :type) "tool_result")
                  (string-prefix-p "Denied: supervisor mode: the work is not done"
                                   (format "%s" (plist-get block :content)))))
           (plist-get (car (last (plist-get request :messages))) :content)))

(defun harness-supervisor-plan-test--on-refusal (script name input)
  "Return a provider script whose supervisor calls NAME with INPUT on a refused hand-in.
Any other request is answered as SCRIPT does."
  (lambda (request)
    (let ((events (funcall script request)))
      (if (and (eq 'main (plist-get (plist-get request :session) :kind))
               (harness-supervisor-plan-test--refused-p request))
          (harness-supervisor-plan-test-call name input)
        events))))

(defun harness-supervisor-plan-test--fail-s1-task (name input)
  "Submit a supervising task whose step s1 fails, holding s2; return (TASK SESSION).
The supervisor hands the work in on each report, and when that is
refused it calls NAME with INPUT."
  (harness-supervisor-plan-test--hand-in-on-report)
  (setq harness-supervisor-plan-test--plan
        (harness-supervisor-plan-test-plan-input
         (harness-supervisor-plan-test-step-input "s1")
         (harness-supervisor-plan-test-step-input "s2" :after '("s1"))))
  (setq harness-provider-demo-script-override
        (harness-supervisor-plan-test--on-refusal harness-provider-demo-script-override name input))
  (let ((id (plist-get (harness-call 'task/submit default-directory "Fix the parser") :id)))
    (list id (plist-get (harness-supervisor-plan-test-task id) :session))))

(defun harness-supervisor-plan-test--check-refused (sid results)
  "Check that RESULTS, the results of session SID's hand_in calls, start with a refusal for s1.
s1 of the first plan failed and s2 waits for it; a second hand_in went through."
  (let ((plan-id (plist-get (harness-supervisor-plan-test-plan sid 0) :id)))
    (should (= 2 (length results)))
    (should (plist-get (nth 0 results) :is-error))
    (should (string-prefix-p
             (format (concat "Denied: supervisor mode: the work is not done, so the task cannot be handed in as done:"
                             " step s1 (Title of s1) of plan %s failed;"
                             " step s2 (Title of s2) of plan %s is pending, waiting for s1."
                             " Run a step that did not get done again with retry_step (on a higher tier if its"
                             " model was not up to it), or replace it with a new plan (submit_plan)."
                             " If the task cannot be finished, call hand_in with cannot_continue true and say"
                             " what blocks it.")
                     plan-id plan-id)
             (plist-get (nth 0 results) :output)))
    (should-not (plist-get (nth 1 results) :is-error))))

(ert-deftest harness-supervisor-plan-a-task-with-a-failed-step-is-not-handed-in-as-done ()
  "A failure wakes the supervisor of a task, whose hand_in is then refused: the task stays out of review.
The report says the step blocks hand_in, and the refusal names it, the
step held on it and the ways on.  Held steps do not keep the task
waiting on their own.  Giving the task up with cannot_continue goes
through, and puts it before the user instead of in review."
  (harness-supervisor-plan-test-with-tasks
    (let ((reviews nil))
      (harness-on 'task/review (lambda (task) (push (plist-get task :id) reviews)))
      (harness-supervisor-plan-test-behave "s1" 'error)
      (pcase-let ((`(,id ,sid) (harness-supervisor-plan-test--fail-s1-task
                                "hand_in" '(:problem "The parser breaks on nested quotes."
                                            :summary "Step s1 failed twice: the parser is not fixed."
                                            :cannot_continue t))))
        ;; The failure reaches the supervisor as a turn, even though the first one ended.
        (harness-test-wait (lambda () (eq 'cannot-continue (plist-get (harness-supervisor-plan-test-task id) :outcome)))
                           15 "the task to wait for the user")
        (harness-supervisor-plan-test-wait-idle sid)
        (let ((reports (harness-supervisor-plan-test-reports sid)))
          (should (= 1 (length reports)))
          (should (string-match-p "step s1 .* failed" (car reports)))
          (should (string-suffix-p (concat "\n" harness-supervisor--blocks-hand-in) (car reports))))
        (harness-supervisor-plan-test--check-refused sid (harness-supervisor-plan-test-results-of sid "hand_in"))
        (let ((task (harness-supervisor-plan-test-task id)))
          (should (eq 'active (plist-get task :state)))
          (should (eq 'needs-input (plist-get task :column)))
          (should (harness-json-true-p (plist-get (plist-get task :report) :cannot-continue)))
          (should (equal "Step s1 failed twice: the parser is not fixed." (plist-get (plist-get task :report) :summary)))
          (should-not (plist-get task :waiting)))
        (should-not reviews)
        (should (equal "failed" (harness-supervisor-plan-test-state sid "s1")))
        (should (equal "pending" (harness-supervisor-plan-test-state sid "s2")))))))

(ert-deftest harness-supervisor-plan-a-task-is-handed-in-once-a-retry-got-the-failed-step-done ()
  "Refused, the supervisor retries the failed step; once the plan has finished, hand_in goes through."
  (harness-supervisor-plan-test-with-tasks
    (harness-supervisor-plan-test-behave "s1" 'error "Fixed the parser.")
    (pcase-let ((`(,id ,sid) (harness-supervisor-plan-test--fail-s1-task
                              "retry_step" '(:step "s1" :reason "its worker failed"))))
      (harness-test-wait (lambda () (eq 'review (plist-get (harness-supervisor-plan-test-task id) :state))) 20
                         "the task to be in review")
      (harness-supervisor-plan-test--check-refused sid (harness-supervisor-plan-test-results-of sid "hand_in"))
      (let ((report (plist-get (harness-supervisor-plan-test-task id) :report)))
        (should (equal "The parser is fixed." (plist-get report :summary)))
        (should-not (plist-get report :missing)))
      (should (equal '("done" "done") (list (harness-supervisor-plan-test-state sid "s1")
                                            (harness-supervisor-plan-test-state sid "s2"))))
      (should (= 2 (plist-get (harness-supervisor-plan-test-step sid "s1") :attempts)))
      (let ((reports (harness-supervisor-plan-test-reports sid)))
        (should (= 2 (length reports)))
        (should (string-match-p "step s1 .* failed" (nth 0 reports)))
        (should (string-match-p "finished\\. All 2 steps are done" (nth 1 reports)))))))

(ert-deftest harness-supervisor-plan-a-task-is-handed-in-once-a-new-plan-replaced-the-failed-step ()
  "Refused, the supervisor makes a new plan; once that has finished, hand_in goes through.
A plan made after a step failed replaces it: the failed step stays as it
was, and the one held on it is superseded."
  (harness-supervisor-plan-test-with-tasks
    (harness-supervisor-plan-test-behave "s1" 'error)
    (pcase-let ((`(,id ,sid) (harness-supervisor-plan-test--fail-s1-task
                              "submit_plan" (harness-supervisor-plan-test-plan-input
                                             (harness-supervisor-plan-test-step-input
                                              "t1" :prompt "Fix the parser in smaller steps.")))))
      (harness-test-wait (lambda () (eq 'review (plist-get (harness-supervisor-plan-test-task id) :state))) 20
                         "the task to be in review")
      (harness-supervisor-plan-test--check-refused sid (harness-supervisor-plan-test-results-of sid "hand_in"))
      (should (equal "The parser is fixed." (plist-get (plist-get (harness-supervisor-plan-test-task id) :report)
                                                       :summary)))
      (should (equal '("failed" "superseded") (list (harness-supervisor-plan-test-state sid "s1" 0)
                                                    (harness-supervisor-plan-test-state sid "s2" 0))))
      (should (equal "done" (harness-supervisor-plan-test-state sid "t1" 1)))
      (should (< (plist-get (harness-supervisor-plan-test-step sid "s1" 0) :ended)
                 (plist-get (harness-supervisor-plan-test-plan sid 1) :created)))
      (let ((reports (harness-supervisor-plan-test-reports sid)))
        (should (= 2 (length reports)))
        (should (string-match-p "step s1 .* failed" (nth 0 reports)))
        (should (string-match-p "finished\\. Its one step is done" (nth 1 reports)))))))

;;;; A task sent back to the queue while its workers run
;;
;; The supervising task of these tests submits a plan whose worker holds
;; until it is cancelled, so its turn is over and it waits on the worker
;; (`:waiting'), holding its slot.  Pre-empted by work sent back from
;; review, or returned to pending by hand, the task has the worker stopped
;; with it, and carries on, told why, once it starts again.

(defun harness-supervisor-plan-test-said (sid text)
  "Return the user messages of session SID that say exactly TEXT, oldest first."
  (cl-remove-if-not (lambda (n) (equal text (plist-get n :content)))
                    (harness-supervisor-plan-test-nodes sid 'user)))

(defun harness-supervisor-plan-test-user-position (sid pred)
  "Return where in session SID's transcript the first user message PRED accepts is.
PRED takes the message's text."
  (harness-supervisor-plan-test-node-position
   sid (lambda (n) (and (eq 'user (plist-get n :kind)) (funcall pred (or (plist-get n :content) ""))))))

(defun harness-supervisor-plan-test--retry-on (script text)
  "Return a provider script that has a supervisor retry step s1 when TEXT is its message.
The harness tells the session of a task that carries on again why it
waited (TEXT); its supervisor, who has read the report of the steps that
were interrupted, retries s1.  Any other request is answered as SCRIPT does."
  (lambda (request)
    (let ((events (funcall script request)))
      (if (and (eq 'main (plist-get (plist-get request :session) :kind))
               (not (harness-supervisor-plan-test--after-tool-p request))
               (equal text (harness-provider-demo--last-user-text request)))
          (harness-supervisor-plan-test-call "retry_step" '(:step "s1" :reason "the task is back"))
        events))))

(defun harness-supervisor-plan-test--submit-waiting-task ()
  "Submit a supervising task whose plan's worker runs for good; return (TASK SESSION WORKER).
The first attempt of step s1 holds until it is cancelled, the second replies.
Returns once the task waits on the worker, its turn over, and the plan is
cleared so that no later request submits it again."
  (harness-supervisor-plan-test-behave "s1" 'hold '(reply "Fixed the parser." 0.4))
  (setq harness-supervisor-plan-test--plan
        (harness-supervisor-plan-test-plan-input
         (harness-supervisor-plan-test-step-input "s1" :tier "medium")))
  (let* ((task (plist-get (harness-call 'task/submit default-directory "Fix the parser") :id))
         (sid (plist-get (harness-supervisor-plan-test-task task) :session))
         (worker (harness-supervisor-plan-test-worker sid "s1")))
    (setq harness-supervisor-plan-test--plan nil)
    (harness-test-wait (lambda () (plist-get (harness-supervisor-plan-test-task task) :waiting)) 10
                       "the task to wait for its worker")
    ;; Its turn is over and its worker runs on: it holds a slot.
    (should-not (harness-call 'agent/running sid))
    (should (harness-call 'agent/running worker))
    (should (string-match-p "\\`Supervisor plan: 1 step running" (harness-call 'agent/outstanding sid)))
    (list task sid worker)))

(defun harness-supervisor-plan-test--check-carried-on (task sid worker opening why)
  "Check that TASK, which carried on in session SID after its worker was stopped, is done.
OPENING is the harness's message that started it again, and WHY what the
interrupted step says: the start of the reason it was stopped for.  The
supervisor retried the step, which ran on a worker of its own, and handed in;
its transcript holds the one report of the interruption, then OPENING, the
retry, and the report that the plan is done."
  (let ((task (harness-supervisor-plan-test-task task))
        (s1 (harness-supervisor-plan-test-step sid "s1")))
    (should (eq 'review (plist-get task :state)))
    (should-not (plist-get task :waiting))
    (should-not (plist-get task :return-reason))
    (should-not (plist-get task :preempted-by))
    (should (equal "The parser is fixed." (plist-get (plist-get task :report) :summary)))
    (should-not (plist-get (plist-get task :report) :missing))
    (should (equal "done" (plist-get s1 :state)))
    (should (= 2 (plist-get s1 :attempts)))
    (should (equal "Fixed the parser." (plist-get s1 :result)))
    (should-not (equal worker (plist-get s1 :session)))
    (should (equal worker (plist-get (plist-get s1 :previous) :session)))
    (should (string-prefix-p why (plist-get (plist-get s1 :previous) :error))))
  (let ((reports (harness-supervisor-plan-test-reports sid))
        (said (harness-supervisor-plan-test-said sid opening)))
    (should (= 2 (length reports)))
    (should (string-prefix-p "Supervisor report: the plan's workers were stopped" (nth 0 reports)))
    (should (string-match-p "finished\\. Its one step is done" (nth 1 reports)))
    (should (= 1 (length said)))
    (should (eq 'system (harness-sender-kind (harness-node-sender (car said))))))
  (let ((interrupted (harness-supervisor-plan-test-user-position
                      sid (lambda (text) (string-prefix-p "Supervisor report: the plan's workers were stopped" text))))
        (carried-on (harness-supervisor-plan-test-user-position sid (lambda (text) (equal opening text))))
        (retry (harness-supervisor-plan-test-node-position
                sid (lambda (n) (and (eq 'tool-call (plist-get n :kind)) (equal "retry_step" (plist-get n :tool))))))
        (finished (harness-supervisor-plan-test-user-position
                   sid (lambda (text) (string-match-p "finished\\. Its one step is done" text)))))
    (should (and interrupted carried-on retry finished))
    (should (< interrupted carried-on retry finished))))

(ert-deftest harness-supervisor-plan-a-task-waiting-on-its-workers-is-preempted-and-carries-on ()
  "Work sent back from review pre-empts a supervising task that only waits on its worker.
With one slot, the task whose supervisor submitted a plan holds it while the
plan's worker runs on.  Sending a reviewed task back takes that slot: the
worker's turn is cancelled, its step is interrupted for the pre-emption, and
nothing starts on its own.  The task waits in the queue, and its supervisor is
told once, in a message that waits in its session.  When the slot frees the
task carries on in that session, told why by the harness; its supervisor, who
has both messages, retries the step, and the work comes back to review."
  (harness-supervisor-plan-test-with-tasks
    (harness-supervisor-plan-test--hand-in-on-report)
    (let* ((harness-tasks-max-running 1)
           (harness-agent--cancel-grace 0.05)
           ;; A hands-on task whose work is done, waiting for review.
           (reviewed (plist-get (harness-call 'task/submit default-directory "Document the parser"
                                              (list :supervisor :false))
                                :id)))
      (harness-test-wait (lambda () (eq 'review (plist-get (harness-supervisor-plan-test-task reviewed) :state)))
                         15 "the hands-on task to be in review")
      ;; A supervising one takes the slot, and its plan's worker runs for good.
      (pcase-let* ((`(,busy ,bsid ,worker) (harness-supervisor-plan-test--submit-waiting-task))
                   (harness-provider-demo-script-override
                    (harness-supervisor-plan-test--retry-on harness-provider-demo-script-override
                                                            harness-tasks--preempted-message))
                   (ended nil))
        (should (= 0 (harness-tasks--free-slots
                      (harness-tasks--slot-project (harness-supervisor-plan-test-task busy)))))
        (harness-on 'agent/turn-ended (lambda (id reason) (when (equal id worker) (push reason ended))))
        (setq harness-supervisor-plan-test--requests nil)
        ;; The reviewed task is sent back, with no slot free.
        (harness-call 'task/reject reviewed "Handle tabs too.")
        ;; At once: the task waits in the queue, pre-empted, with nothing at work for it.
        (let ((task (harness-supervisor-plan-test-task busy)))
          (should (eq 'pending (plist-get task :state)))
          (should (eq 'preempted (plist-get task :return-reason)))
          (should (equal reviewed (plist-get task :preempted-by)))
          (should-not (plist-get task :waiting)))
        (should (eq 'active (plist-get (harness-supervisor-plan-test-task reviewed) :state)))
        (let ((s1 (harness-supervisor-plan-test-step bsid "s1")))
          (should (equal "interrupted" (plist-get s1 :state)))
          (should (equal worker (plist-get s1 :session)))
          (should (string-prefix-p (format "its task was pre-empted by task %s" reviewed) (plist-get s1 :error)))
          (should (string-suffix-p ", sent back from review" (plist-get s1 :error))))
        (should (zerop (hash-table-count harness-supervisor--live)))
        (should-not (harness-call 'agent/outstanding bsid))
        (should-not (harness-supervisor-plan-test-step-request "s1"))
        ;; The worker's turn is cancelled.
        (harness-test-wait (lambda () ended) 10 "the worker's turn to end")
        (should (equal '(cancelled) ended))
        (should-not (harness-call 'agent/running worker))
        ;; The supervisor is told once, but its session takes no turn while its task waits.
        (let ((reports (harness-supervisor-plan-test-wait-reports bsid 1)))
          (should (= 1 (length reports)))
          (should (string-prefix-p "Supervisor report: the plan's workers were stopped, interrupting 1 running step: s1."
                                   (car reports)))
          (should (string-match-p "Why: its task was pre-empted by task " (car reports)))
          (should (string-match-p "Decide: retry_step s1 to run it again" (car reports))))
        (harness-test-wait
         (lambda () (cl-some (lambda (hint) (string-prefix-p "Turn not started: task " hint))
                             (harness-supervisor-plan-test-hints bsid)))
         10 "the report's turn refused")
        (let ((hints (harness-supervisor-plan-test-hints bsid)))
          (should (cl-some (lambda (hint) (string-prefix-p "Pre-empted by task " hint)) hints))
          (should (member "Stopped while the task waits for a slot: Supervisor plan: 1 step interrupted" hints)))
        ;; The slot frees when the task sent back is in review again: the
        ;; pre-empted one carries on in its session, told why by the harness.
        (harness-test-wait (lambda () (harness-supervisor-plan-test-said bsid harness-tasks--preempted-message)) 15
                           "the pre-empted task to carry on")
        (harness-test-wait (lambda () (eq 'review (plist-get (harness-supervisor-plan-test-task busy) :state))) 25
                           "the supervising task to be in review again")
        (should (eq 'review (plist-get (harness-supervisor-plan-test-task reviewed) :state)))
        (should (harness-supervisor-plan-test-said
                 (plist-get (harness-supervisor-plan-test-task reviewed) :session)
                 (harness-tasks--reject-text "Handle tabs too.")))
        (harness-supervisor-plan-test--check-carried-on
         busy bsid worker harness-tasks--preempted-message
         (format "its task was pre-empted by task %s" reviewed))
        ;; Both tasks are in review, so no slot is taken.
        (should (= 1 (harness-tasks--free-slots
                      (harness-tasks--slot-project (harness-supervisor-plan-test-task busy)))))))))

(ert-deftest harness-supervisor-plan-a-task-returned-to-pending-while-it-waits-on-its-workers-stops-them ()
  "Returning a supervising task that only waits on its worker to pending stops the worker.
The worker's turn is cancelled and its step interrupted, at once, for the
return.  The report to the supervisor waits in its session, whose turn is
refused, and the return starts nothing, though a slot is free: the task waits
in the queue until it is started.  Then it carries on in its session, told
why by the harness; its supervisor retries the step, and the work comes back
to review."
  (harness-supervisor-plan-test-with-tasks
    (harness-supervisor-plan-test--hand-in-on-report)
    (let ((harness-agent--cancel-grace 0.05))
      (pcase-let* ((`(,busy ,bsid ,worker) (harness-supervisor-plan-test--submit-waiting-task))
                   (harness-provider-demo-script-override
                    (harness-supervisor-plan-test--retry-on harness-provider-demo-script-override
                                                            harness-tasks--paused-message))
                   (ended nil))
        (harness-on 'agent/turn-ended (lambda (id reason) (when (equal id worker) (push reason ended))))
        (setq harness-supervisor-plan-test--requests nil)
        (harness-call 'task/return-to-pending busy)
        ;; At once: the task waits in the queue, returned, and its step is interrupted.
        (let ((task (harness-supervisor-plan-test-task busy)))
          (should (eq 'pending (plist-get task :state)))
          (should (eq 'returned (plist-get task :return-reason)))
          (should-not (plist-get task :preempted-by))
          (should-not (plist-get task :waiting)))
        (let ((s1 (harness-supervisor-plan-test-step bsid "s1")))
          (should (equal "interrupted" (plist-get s1 :state)))
          (should (equal worker (plist-get s1 :session)))
          (should (equal "its task was paused" (plist-get s1 :error))))
        (should-not (harness-call 'agent/outstanding bsid))
        (harness-test-wait (lambda () ended) 10 "the worker's turn to end")
        (should (equal '(cancelled) ended))
        (let ((reports (harness-supervisor-plan-test-wait-reports bsid 1)))
          (should (= 1 (length reports)))
          (should (string-match-p "Why: its task was paused\\." (car reports))))
        (harness-test-wait
         (lambda () (cl-some (lambda (hint) (string-prefix-p "Turn not started: task " hint))
                             (harness-supervisor-plan-test-hints bsid)))
         10 "the report's turn refused")
        (should (member "Stopped while the task waits for a slot: Supervisor plan: 1 step interrupted"
                        (harness-supervisor-plan-test-hints bsid)))
        ;; The refused turn started nothing: a slot is free, but the task waits.
        (accept-process-output nil 0.5)
        (should (= 3 (harness-tasks--free-slots
                      (harness-tasks--slot-project (harness-supervisor-plan-test-task busy)))))
        (should (eq 'pending (plist-get (harness-supervisor-plan-test-task busy) :state)))
        (should-not (harness-supervisor-plan-test-said bsid harness-tasks--paused-message))
        (should-not (harness-supervisor-plan-test-step-request "s1"))
        ;; Started, it carries on in its session, told why by the harness.
        (harness-call 'task/start busy)
        (harness-test-wait (lambda () (eq 'review (plist-get (harness-supervisor-plan-test-task busy) :state))) 25
                           "the supervising task to be in review again")
        (harness-supervisor-plan-test--check-carried-on
         busy bsid worker harness-tasks--paused-message "its task was paused")))))

(provide 'harness-supervisor-plan-test)
;;; harness-supervisor-plan-test.el ends here
