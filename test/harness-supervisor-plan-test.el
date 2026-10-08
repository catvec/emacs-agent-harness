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
(defvar harness-tools)
(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness--methods)
(defvar harness--filters)
(defvar harness--subscribers)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--naming)
(defvar harness-tasks--naming-queue)
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
(declare-function harness-provider-demo--last-user-text "harness-provider-demo")
(declare-function harness-supervisor--update-step "harness-supervisor")
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
(declare-function harness-supervisor--send "harness-supervisor")
(declare-function harness-tools-agent-context-limit "harness-tools-agent")
(declare-function harness-tasks--forget-stores "harness-tasks")
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
  '(store project config provider provider-demo tools session agent tools-agent seed supervisor)
  "The modules every test loads.")

(defun harness-supervisor-plan-test--tier-model (_model &optional tier)
  "Stand in for `provider/tier-model': a model of the demo provider for TIER."
  (pcase tier
    ('cheap "demo:cheap") ('balanced "demo:balanced") ('frontier "demo:frontier")))

(defun harness-supervisor-plan-test--allow (_decision next &rest _)
  "Allow every call that gets this far, as yolo mode would; continue with NEXT."
  (funcall next (list :behavior 'allow)))

(defmacro harness-supervisor-plan-test-with-modules (extra &rest body)
  "Load the state layer, the plan engine and the modules EXTRA names, run BODY.
The demo provider plays the model through the script of the test, the
permission chain allows everything the supervisor's own stage lets by,
and the tiers map to the demo models cheap, balanced and frontier."
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
                          harness-supervisor--held))
       (clrhash table))
     (harness-register-method 'provider/tier-model #'harness-supervisor-plan-test--tier-model)
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
  (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir)
                    :model "demo:scripted" plist)
             :id))

(defun harness-supervisor-plan-test-step-input (id &rest props)
  "Return the input of step ID of a plan, PROPS overriding its defaults."
  (append props (list :id id :title (format "Title of %s" id) :prompt (format "Do %s." id)
                      :tier "mundane" :reason "simple")))

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
  (harness-test-wait (lambda () (equal state (harness-supervisor-plan-test-state sid id n)))
                     (or timeout 15) (format "step %s to be %s" id state)))

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
                                                              (list :prompt "p" :tier "hard"))))
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
  "Mundane is the provider's cheap model, standard its balanced one, hard its frontier one."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let* ((sid (harness-supervisor-plan-test-session))
             (result (harness-supervisor-plan-test-run
                      sid "submit_plan"
                      (harness-supervisor-plan-test-plan-input
                       (harness-supervisor-plan-test-step-input "m" :tier "mundane")
                       (harness-supervisor-plan-test-step-input "s" :tier "standard")
                       (harness-supervisor-plan-test-step-input "h" :tier "HARD" :context "fresh")))))
        (should-not (plist-get result :is-error))
        (should (equal "demo:cheap" (plist-get (harness-supervisor-plan-test-step sid "m") :model)))
        (should (equal "demo:balanced" (plist-get (harness-supervisor-plan-test-step sid "s") :model)))
        (should (equal "demo:frontier" (plist-get (harness-supervisor-plan-test-step sid "h") :model)))
        (should (equal "hard" (plist-get (harness-supervisor-plan-test-step sid "h") :tier)))
        ;; The answer says where each step runs.
        (let ((text (plist-get result :content)))
          (should (string-match-p "^- m → demo:cheap" text))
          (should (string-match-p "^- s → demo:balanced" text))
          (should (string-match-p "^- h → demo:frontier" text)))
        (should-not (cl-some (lambda (h) (string-match-p "own model" h))
                             (harness-supervisor-plan-test-hints sid)))))))

(ert-deftest harness-supervisor-plan-the-setting-overrides-the-model-of-a-tier ()
  "A model in `harness-supervisor-tiers' wins for its tier; the others keep the provider's."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (let ((harness-supervisor-tiers '((hard . "demo:opus") (mundane . "demo:haiku")))
            (sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-run
         sid "submit_plan"
         (harness-supervisor-plan-test-plan-input
          (harness-supervisor-plan-test-step-input "m" :tier "mundane")
          (harness-supervisor-plan-test-step-input "s" :tier "standard")
          (harness-supervisor-plan-test-step-input "h" :tier "hard")))
        (should (equal "demo:haiku" (plist-get (harness-supervisor-plan-test-step sid "m") :model)))
        (should (equal "demo:balanced" (plist-get (harness-supervisor-plan-test-step sid "s") :model)))
        (should (equal "demo:opus" (plist-get (harness-supervisor-plan-test-step sid "h") :model)))))))

(ert-deftest harness-supervisor-plan-a-tier-without-a-model-runs-on-the-supervisors-own ()
  "With no model for a tier the step runs on the supervisor's, and a hint says so."
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (harness-register-method 'provider/tier-model
                               (lambda (_model &optional tier) (and (eq tier 'cheap) "demo:cheap")))
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-run
         sid "submit_plan"
         (harness-supervisor-plan-test-plan-input
          (harness-supervisor-plan-test-step-input "m" :tier "mundane")
          (harness-supervisor-plan-test-step-input "h" :tier "hard")))
        (should (equal "demo:cheap" (plist-get (harness-supervisor-plan-test-step sid "m") :model)))
        (should (equal "demo:scripted" (plist-get (harness-supervisor-plan-test-step sid "h") :model)))
        (let ((hint (cl-find-if (lambda (h) (string-match-p "own model" h))
                                (harness-supervisor-plan-test-hints sid))))
          (should hint)
          (should (string-match-p "step h (hard)" hint))
          (should-not (string-match-p "step m" hint))
          (should (string-match-p "demo:scripted" hint))))))
  ;; A provider that fails to answer counts as having no model.
  (harness-supervisor-plan-test-with
    (harness-supervisor-plan-test-stub-starts
      (harness-register-method 'provider/tier-model (lambda (&rest _) (error "No catalogue")))
      (let ((sid (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-run
         sid "submit_plan"
         (harness-supervisor-plan-test-plan-input (harness-supervisor-plan-test-step-input "m")))
        (should (equal "demo:scripted" (plist-get (harness-supervisor-plan-test-step sid "m") :model)))))))

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
                     (harness-supervisor-plan-test-step-input "s1" :tier "hard" :reason "subtle")
                     (harness-supervisor-plan-test-step-input "s2" :after '("s1") :context "fresh"))))
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
            (should (equal "hard" (plist-get s1 :tier)))
            (should (equal "subtle" (plist-get s1 :reason)))
            (should (equal "fork" (plist-get s1 :context)))
            (should (equal "demo:frontier" (plist-get s1 :model)))
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
          (should (string-match-p "^- s1 → demo:frontier" answer))
          (should (string-match-p "^- s2 → demo:cheap" answer))
          (should (string-match-p "after s1" answer)))))))

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
         (harness-supervisor-plan-test-step-input "c" :tier "hard")
         ;; Fresh steps fork nothing.
         (harness-supervisor-plan-test-step-input "d" :context "fresh"))
        (let* ((node (harness-supervisor-plan-test-call-node sid "call-plan"))
               (limit (harness-tools-agent-context-limit sid t))
               (seeds (harness-supervisor-plan-test-calls 'seed/fork))
               (forks (harness-supervisor-plan-test-calls 'session/fork)))
          (should node)
          (should (> limit harness-subagent-context-limit))
          (should (= 2 (length seeds)))
          (should (equal (list sid "demo:cheap" :node node :call-id "call-plan"
                               :name "Step a: Title of a" :context-window-limit limit)
                         (nth 0 seeds)))
          (should (equal (list sid "demo:cheap" :node node :call-id "call-plan"
                               :name "Step b: Title of b" :context-window-limit limit)
                         (nth 1 seeds)))
          (should (= 1 (length forks)))
          (should (equal (list sid :node node :call-id "call-plan" :kind 'subagent
                               :model "demo:frontier" :name "Step c: Title of c"
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
                                             (harness-supervisor-plan-test-step-input "b" :tier "hard"))
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
         sid (harness-supervisor-plan-test-step-input "f" :tier "standard" :context "fresh"))
        (let ((args (car (harness-supervisor-plan-test-calls 'session/create)))
              (session (harness-call 'session/get sid)))
          (should (equal (plist-get session :cwd) (plist-get args :cwd)))
          (should (equal dir (plist-get args :worktree)))
          (should (eq 'subagent (plist-get args :kind)))
          (should (equal sid (plist-get args :parent-id)))
          (should (equal "demo:balanced" (plist-get args :model)))
          (should (equal "Step f: Title of f" (plist-get args :name)))
          (should (eq 'auto (plist-get args :permission-mode)))
          (should (equal "high" (plist-get args :thinking)))
          (should (eq t (plist-get args :non-interactive)))
          (should (equal (list extra) (plist-get args :allowed-dirs)))
          (should (plist-member args :host))
          ;; Fresh: the cap, not the conversation it does not inherit.
          (should (eql harness-subagent-context-limit (plist-get args :context-window-limit)))
          (should (< (plist-get args :context-window-limit) (harness-tools-agent-context-limit sid t))))))))

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
         (harness-supervisor-plan-test-step-input "c" :tier "hard")
         (harness-supervisor-plan-test-step-input "d" :context "fresh"))
        (dolist (call (append (harness-supervisor-plan-test-calls 'seed/fork)
                              (harness-supervisor-plan-test-calls 'session/fork)
                              (harness-supervisor-plan-test-calls 'session/create)))
          (should-not (plist-member call :context-window-limit)))
        (should (= 4 (length (append (harness-supervisor-plan-test-calls 'seed/fork)
                                     (harness-supervisor-plan-test-calls 'session/fork)
                                     (harness-supervisor-plan-test-calls 'session/create)))))))))

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
        (should (equal "demo:cheap" (plist-get worker :model)))
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
          (should (string-match-p "^## Step s1: Title of s1\n\nDo s1\\.$" text))
          (should (string-match-p "Do the step, then verify it\\. End with a short report of what you changed and how you checked it\\. Do not commit unless the step says so\\.\\'" text))
          (should-not (string-match-p "What the steps before this one reported" text))))
      ;; The supervisor got a hint, then the report that the plan finished, in a turn of its own.
      (should (member "Step s1 done on demo:cheap" (harness-supervisor-plan-test-hints sid)))
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
       sid (harness-supervisor-plan-test-step-input "f" :context "fresh" :tier "standard"))
      (harness-supervisor-plan-test-wait-state sid "f" "done")
      (let* ((wid (plist-get (harness-supervisor-plan-test-step sid "f") :session))
             (worker (harness-call 'session/get wid))
             (texts (harness-supervisor-plan-test-user-texts wid)))
        (should (eq 'subagent (plist-get worker :kind)))
        (should (equal sid (plist-get worker :parent-id)))
        (should (equal "demo:balanced" (plist-get worker :model)))
        (should-not (plist-get worker :fork-node))
        (should (= 1 (length texts)))
        (should (string-match-p "\\`You are a worker for one step of a plan that a supervisor made" (car texts)))
        (should (string-match-p "start without the supervisor's conversation" (car texts)))
        (should (string-match-p "^## Step f: Title of f\n\nDo f\\.$" (car texts)))
        (should-not (member "Do the thing" texts))))))

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
        (should (equal "demo:cheap" (plist-get (car seeds) :model)))
        (should (equal (plist-get (car seeds) :id) (plist-get a :parent-id)))
        (should (equal (plist-get (car seeds) :id) (plist-get b :parent-id)))
        (should (equal "Step a: Title of a" (plist-get a :name)))
        (should (equal "Step b: Title of b" (plist-get b :name)))
        (should (eq 'subagent (plist-get a :kind)))
        (should (equal "demo:cheap" (plist-get a :model)))))))

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
   (harness-supervisor-plan-test-step-input "s3" :tier "standard")
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
          (should (string-match-p "tier mundane, model demo:cheap (attempt 1)" text))
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
        (should (equal "demo:frontier" (plist-get s1 :model)))
        (should (equal "mundane was not enough" (plist-get s1 :reason)))
        (should (equal "Fixed s1." (plist-get s1 :result)))
        (should-not (plist-get s1 :error))
        (should-not (equal first-worker (plist-get s1 :session)))
        (should (string-suffix-p "\n\nNotes for attempt 2: The first attempt failed with boom." (plist-get s1 :prompt)))
        (should (string-prefix-p "Do s1." (plist-get s1 :prompt)))
        ;; The second attempt ran on the higher tier's model, with the notes.
        (let ((again (harness-supervisor-plan-test-step-request "s1" 1)))
          (should (equal "demo:frontier" (plist-get again :model)))
          (should (string-match-p "Notes for attempt 2: The first attempt failed with boom\\." (plist-get again :text))))
        (should (equal "demo:cheap" (plist-get (harness-supervisor-plan-test-step-request "s1" 0) :model)))
        ;; The step that waited got the result of the attempt that worked.
        (should (string-match-p "### s1 (Title of s1)\nFixed s1\\."
                                (plist-get (harness-supervisor-plan-test-step-request "s2") :text)))
        (should (equal "demo:cheap" (plist-get s2 :model))))
      (should (member "Retrying step s1 on demo:frontier (attempt 2): mundane was not enough"
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
           (harness-compaction-brief-model "demo:cheap"))
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
          (should (equal "demo:frontier" (plist-get s1 :model)))
          (should (= 2 (plist-get s1 :attempts)))
          ;; The fork was compacted, by the cowboy's default, before its turn.
          (should (= 1 (length nodes)))
          (should (equal "brief" (harness-node-compaction-kind (car nodes))))
          (should (equal '(:choice "brief" :by "cold-start") (plist-get (plist-get (car nodes) :meta) :cowboy)))
          (should (member (concat "No prompt cache on demo:frontier holds the supervisor's conversation: compacting"
                                  " into a brief summary first, the default for a session no warm cache holds"
                                  " (harness-cowboy-default)")
                          (harness-supervisor-plan-test-hints wid)))
          ;; The worker reads the summary, not the supervisor's conversation.
          (let ((sent (harness-supervisor-plan-test-messages-text wid)))
            (should (string-match-p "Do s1\\." sent))
            (should-not (string-match-p "Do the thing" sent)))
          ;; The supervisor is told, after the retry it made.
          (let ((retry (cl-position "Retrying step s1 on demo:frontier (attempt 2): once more" hints :test #'equal))
                (told (cl-position (concat "Step s1 (attempt 2) on demo:frontier: no warm prompt cache holds the"
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

(ert-deftest harness-supervisor-plan-a-retry-takes-a-warm-seed-and-compacts-without-one ()
  "A seed whose cache is warm is forked through, and reads cheap; one that lapsed is not."
  (harness-supervisor-plan-test-with-cache (compaction cowboy)
    (let ((sid (harness-supervisor-plan-test-session)))
      ;; Two fork steps on a model: their first attempts fork through one seed, as always.
      (harness-supervisor-plan-test-fail-first
       sid
       (harness-supervisor-plan-test-step-input "s1" :tier "hard")
       (harness-supervisor-plan-test-step-input "s2" :tier "hard"))
      (let* ((node (plist-get (harness-supervisor-plan-test-plan sid) :node))
             (seed (plist-get (car (harness-call 'seed/list sid)) :id)))
        (should seed)
        (should (equal seed (harness-supervisor-plan-test-forked-from
                             (plist-get (harness-supervisor-plan-test-step sid "s1") :session))))
        (should-not (harness-call 'seed/warm-p sid "demo:frontier" node))
        ;; Warm: s1 forks through the seed and is not compacted.
        (harness-supervisor-plan-test-stamp-seed seed t)
        (should (equal seed (harness-call 'seed/warm-p sid "demo:frontier" node)))
        (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "s1") :is-error))
        (harness-supervisor-plan-test-wait-state sid "s1" "done")
        (let ((wid (plist-get (harness-supervisor-plan-test-step sid "s1") :session)))
          (should (equal seed (harness-supervisor-plan-test-forked-from wid)))
          (should-not (harness-supervisor-plan-test-own-compactions wid))
          (should (member "Step s1 (attempt 2) on demo:frontier: forked from the warm shared context"
                          (harness-supervisor-plan-test-hints sid)))
          (should-not (string-match-p "was compacted"
                                      (plist-get (harness-supervisor-plan-test-step-request "s1" 1) :text))))
        ;; Lapsed: s2 forks the supervisor and is compacted instead of waking the seed.
        (harness-supervisor-plan-test-stamp-seed seed nil)
        (should-not (harness-call 'seed/warm-p sid "demo:frontier" node))
        (let ((messages (length (harness-supervisor-plan-test-nodes seed 'user))))
          (should-not (plist-get (harness-supervisor-plan-test-retry-step sid "s2") :is-error))
          (harness-supervisor-plan-test-wait-state sid "s2" "done")
          (should (= messages (length (harness-supervisor-plan-test-nodes seed 'user)))))
        (let ((wid (plist-get (harness-supervisor-plan-test-step sid "s2") :session)))
          (should (equal sid (harness-supervisor-plan-test-forked-from wid)))
          (should (= 1 (length (harness-supervisor-plan-test-own-compactions wid))))
          (should (member (concat "Step s2 (attempt 2) on demo:frontier: no warm prompt cache holds the plan's"
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
       (harness-supervisor-plan-test-step-input "s1" :tier "hard")
       (harness-supervisor-plan-test-step-input "s2" :tier "hard"))
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
                                           (harness-supervisor-plan-test-step-input "a" :tier "hard")
                                           (harness-supervisor-plan-test-step-input "b" :tier "standard")
                                           (harness-supervisor-plan-test-step-input "c" :tier "standard"))
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
            (should (equal "demo:cheap" (plist-get (nth 0 creates) :model)))
            (should (equal "demo:frontier" (plist-get (nth 1 creates) :model))))
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
        (harness-supervisor-plan-test-retry-step sid "f" :tier "standard")
        (harness-supervisor-plan-test-wait-state sid "s1" "done")
        (harness-supervisor-plan-test-wait-state sid "f" "done")
        ;; The tier moved the step's model; the previous attempt keeps the one it ran on.
        (let ((s1 (harness-supervisor-plan-test-step sid "s1"))
              (f (harness-supervisor-plan-test-step sid "f")))
          (should (equal "demo:frontier" (plist-get s1 :model)))
          (should (equal (list :attempt 1 :session first :model "demo:cheap"
                               :error "the worker's turn ended with error: boom")
                         (plist-get s1 :previous)))
          (should (equal (list :attempt 1 :session first-fresh :model "demo:cheap"
                               :error "the worker's turn ended with error: boom")
                         (plist-get f :previous))))
        ;; It is in the worker's message, after the step and before the closing.
        (dolist (cell `(("s1" . ,first) ("f" . ,first-fresh)))
          (let ((text (plist-get (harness-supervisor-plan-test-step-request (car cell) 1) :text)))
            (should (string-match-p
                     (concat "\n\n## Step " (car cell) ": Title of " (car cell) "\n\nDo " (car cell) "\\.\n"
                             "\n## The previous attempt\n\nAttempt 1 ran on demo:cheap in session "
                             (regexp-quote (cdr cell))
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
        (should (equal "demo:cheap" (plist-get (harness-supervisor-plan-test-step sid "s1") :worker-model)))
        (harness-call 'session/delete first)
        (should (equal "cancelled" (harness-supervisor-plan-test-state sid "s1")))
        (harness-supervisor-plan-test-wait-reports sid 1)
        (harness-supervisor-plan-test-wait-idle sid)
        (harness-supervisor-plan-test-retry-step sid "s1" :tier "hard")
        (harness-supervisor-plan-test-wait-state sid "s1" "done")
        (let ((s1 (harness-supervisor-plan-test-step sid "s1")))
          (should (equal (list :attempt 1 :session first :model "demo:cheap"
                               :error "the worker's session was deleted")
                         (plist-get s1 :previous)))
          (should (equal "demo:frontier" (plist-get s1 :worker-model)))
          (should (string-match-p (concat "Attempt 1 ran on demo:cheap in session " (regexp-quote first)
                                          " and ended: the worker's session was deleted\\. That session was deleted,"
                                          " so what it tried cannot be read; do not repeat what failed\\.")
                                  (plist-get (harness-supervisor-plan-test-step-request "s1" 1) :text)))
          ;; Neither module: nothing could compact the fork, and it says so.
          (should-not (harness-supervisor-plan-test-own-compactions (plist-get s1 :session)))
          (should (member (concat "No prompt cache on demo:frontier holds the supervisor's conversation: nothing can"
                                  " compact it here, so carrying on with the whole conversation, uncached")
                          (harness-supervisor-plan-test-hints (plist-get s1 :session))))
          (should (member (concat "Step s1 (attempt 2) on demo:frontier: no warm prompt cache holds the plan's"
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
        (should (member (concat "No prompt cache on demo:frontier holds the supervisor's conversation:"
                                " compacting into a brief summary first")
                        (harness-supervisor-plan-test-hints wid)))
        (should (member (concat "Step s1 (attempt 2) on demo:frontier: no warm prompt cache holds the plan's"
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
      (should (member (concat "Step s1 (attempt 2) on demo:frontier: no warm prompt cache holds the plan's"
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
        (should (member (concat "Step s1 (attempt 2) on demo:frontier: no warm prompt cache holds the plan's"
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
       (harness-supervisor-plan-test-step-input "s2" :after '("s1") :tier "standard")
       (harness-supervisor-plan-test-step-input "s3" :after '("s1" "s2") :tier "hard"))
      (let ((reports (harness-supervisor-plan-test-wait-reports sid 1)))
        (harness-supervisor-plan-test-wait-idle sid)
        ;; One message, however many steps: the steps that got done said it in hints.
        (should (= 1 (length reports)))
        (let ((text (car reports)))
          (should (string-prefix-p "Supervisor report: plan " text))
          (should (string-match-p "(The plan) finished\\. All 3 steps are done\\.\n" text))
          (should (string-match-p "^- s1 (Title of s1) on demo:cheap, session [^ ]+: Added the flag\\.$" text))
          (should (string-match-p "^- s2 (Title of s2) on demo:balanced, session [^ ]+: Wrote the docs\\.$" text))
          (should (string-match-p "^- s3 (Title of s3) on demo:frontier, session [^ ]+: Ran the tests: 12 passed\\.$" text))
          (should (string-match-p "Check the work now, with the read-only tools" text))
          (should (string-match-p "session_read on a worker" text))
          (should (string-match-p "a follow-up plan with submit_plan" text))
          (should (string-match-p "no_plan_needed with your reply to the user" text))
          ;; Not a task's session: there is nothing to hand in.
          (should-not (string-match-p "hand_in" text))))
      (should (equal '("Plan submitted: 3 steps" "Step s1 done on demo:cheap" "Step s2 done on demo:balanced"
                       "Step s3 done on demo:frontier" "No plan needed: nothing to decide")
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
      (harness-supervisor-plan-test-submit sid (harness-supervisor-plan-test-step-input "b1" :tier "hard"))
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
      (should (member "Step a1 done on demo:cheap" (harness-supervisor-plan-test-hints sid)))
      ;; Each plan reports when nothing is left to do in it: the new one first, the old one
      ;; when its running step ended, saying what a later plan kept from running.
      (let ((reports (harness-supervisor-plan-test-wait-reports sid 2)))
        (harness-supervisor-plan-test-wait-idle sid)
        (should (= 2 (length reports)))
        (should (string-match-p "plan p-[a-z0-9]+ (The plan) finished\\. Its one step is done" (nth 0 reports)))
        (should (string-match-p "^- b1 " (nth 0 reports)))
        (should (string-match-p "finished\\. 1 of its 3 steps are done; a later plan superseded a2, a3, which never ran\\."
                                (nth 1 reports)))
        (should (string-match-p "^- a1 (Title of a1) on demo:cheap, session [^ ]+: Done a1\\.$" (nth 1 reports)))
        (should (string-match-p "^- a2 (Title of a2): superseded by a later plan, it never ran$" (nth 1 reports)))))))

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
                                                      :tier (if (eq method 'seed/fork) "mundane" "hard")
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
       (harness-supervisor-plan-test-step-input "s2" :after '("s1") :context "fresh" :tier "hard")
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
  (harness-session-flush)
  (clrhash harness-sessions)
  (harness-session--load-all))

(defun harness-supervisor-plan-test-running-plan (sid)
  "Submit, as SID, a plan whose step s1 works for good.
Step s2 follows it, and s3 follows s2.  Return the worker of s1."
  (harness-supervisor-plan-test-behave "s1" 'hold)
  (harness-supervisor-plan-test-submit sid
                                       (harness-supervisor-plan-test-step-input "s1" :tier "hard")
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
          (should (string-match-p "tier hard, model demo:frontier (attempt 1)" text))
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
                                           (harness-supervisor-plan-test-step-input "b" :tier "hard"))
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
        (should (string-match-p "Step s1 of plan p-[a-z0-9]+ runs again on demo:frontier" (plist-get result :content))))
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
        (should (equal (list :attempt 1 :session first :model "demo:frontier"
                             :error "the harness stopped while the worker was running")
                       (plist-get s1 :previous)))
        (should (= 1 (length (harness-supervisor-plan-test-own-compactions wid))))
        (should (member (concat "Step s1 (attempt 2) on demo:frontier: no warm prompt cache holds the plan's"
                                " conversation, so its worker starts from a brief summary of it rather than"
                                " reading it all uncached")
                        (harness-supervisor-plan-test-hints sid)))
        (should (string-match-p "was compacted into a summary" text))
        (should (string-match-p (concat "Attempt 1 ran on demo:frontier in session " (regexp-quote first)
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

(ert-deftest harness-supervisor-plan-the-module-recovers-once-it-is-up-but-a-reload-does-not ()
  "Starting the module schedules the recovery; hooking in again after a reload starts nothing."
  (harness-supervisor-plan-test-with
    (let ((sid (harness-supervisor-plan-test-session)))
      (harness-supervisor-plan-test-running-plan sid)
      (harness-supervisor-plan-test-restart sid)
      ;; A reload hooks the module in again: the steps are not touched.
      (harness-supervisor--init)
      (accept-process-output nil 0.2)
      (should (equal "running" (harness-supervisor-plan-test-state sid "s1")))
      ;; The start, once every module is up, sees them interrupted.
      (harness-supervisor--start)
      (harness-supervisor-plan-test-wait-state sid "s1" "interrupted")
      ;; A step this process runs is left alone: its worker is alive.
      (let ((sid2 (harness-supervisor-plan-test-session)))
        (harness-supervisor-plan-test-behave "w" 'hold)
        (harness-supervisor-plan-test-submit sid2 (harness-supervisor-plan-test-step-input "w"))
        (harness-supervisor-plan-test-worker sid2 "w")
        (harness-supervisor--start)
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
      (harness-supervisor--init)
      (harness-supervisor--init)
      (should (equal "Supervisor plan: 1 step running, 2 waiting" (harness-call 'agent/outstanding sid)))
      (should (= 1 (cl-count #'harness-supervisor--outstanding (gethash 'agent/outstanding harness--filters)
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
         (harness-supervisor-plan-test-step-input "b" :tier "hard")
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
             harness-tasks--naming-queue nil
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

(ert-deftest harness-supervisor-plan-a-task-waits-for-its-workers-and-the-supervisor-hands-it-in ()
  "submit_plan ends the turn but not the task; the finished plan wakes the supervisor, whose hand_in ends it."
  (harness-supervisor-plan-test-with-tasks
    (let ((reviews nil))
      (harness-on 'task/review (lambda (task) (push (plist-get task :id) reviews)))
      (harness-supervisor-plan-test-behave "s1" '(reply "Fixed the parser." 0.8))
      (harness-supervisor-plan-test-behave "s2" '(reply "Committed it." 0.2))
      (setq harness-supervisor-plan-test--plan
            (harness-supervisor-plan-test-plan-input
             (harness-supervisor-plan-test-step-input "s1" :tier "standard")
             (harness-supervisor-plan-test-step-input "s2" :after '("s1") :prompt "Commit the change.")))
      (setq harness-supervisor-plan-test--on-report
            (lambda (_text)
              (harness-supervisor-plan-test-call
               "hand_in" '(:summary "The parser is fixed and committed." :evidence ("Read the diff: it does what the plan said.")))))
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

(ert-deftest harness-supervisor-plan-a-task-stays-active-while-a-failed-step-waits-for-the-supervisor ()
  "A failure wakes the supervisor of a task; held steps do not keep the task waiting on their own."
  (harness-supervisor-plan-test-with-tasks
    (harness-supervisor-plan-test-behave "s1" 'error)
    (setq harness-supervisor-plan-test--plan
          (harness-supervisor-plan-test-plan-input
           (harness-supervisor-plan-test-step-input "s1")
           (harness-supervisor-plan-test-step-input "s2" :after '("s1"))))
    (setq harness-supervisor-plan-test--on-report
          (lambda (_text)
            (harness-supervisor-plan-test-call
             "hand_in" '(:summary "The step failed; handing in what there is." :evidence ("Step s1 failed twice.")))))
    (let* ((id (plist-get (harness-call 'task/submit default-directory "Fix the parser") :id))
           (sid (plist-get (harness-supervisor-plan-test-task id) :session)))
      ;; The failure reaches the supervisor as a turn, even though the first one ended.
      (harness-test-wait (lambda () (eq 'review (plist-get (harness-supervisor-plan-test-task id) :state))) 15
                         "the task to be in review")
      (let ((reports (harness-supervisor-plan-test-reports sid)))
        (should (= 1 (length reports)))
        (should (string-match-p "step s1 .* failed" (car reports))))
      (should (equal "pending" (harness-supervisor-plan-test-state sid "s2")))
      (should-not (plist-get (harness-supervisor-plan-test-task id) :waiting)))))

(provide 'harness-supervisor-plan-test)
;;; harness-supervisor-plan-test.el ends here
