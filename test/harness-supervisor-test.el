;;; harness-supervisor-test.el --- Tests for supervisor mode  -*- lexical-binding: t; -*-

;;; Commentary:

;; The demo provider plays the model.  `harness-supervisor-test--answer'
;; hands it one list of events per request, in the order the test queued
;; them, and notes what it was asked.  The permission chain is whatever
;; a test adds: most add one stage after the supervisor's that allows
;; everything, as yolo mode would, to show that the supervisor's denial
;; is not something a mode can undo.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)
(defvar harness-provider-demo-script-override)
(defvar harness-supervisor)
(defvar harness-supervisor-tasks)
(defvar harness-supervisor-tiers)
(defvar harness-supervisor-thinking)
(defvar harness-supervisor-worker-thinking)
(defvar harness-supervisor-step-budget)
(defvar harness-supervisor-judge-model)
(defvar harness-supervisor--judge-timeout)
(defvar harness-supervisor--judging)
(defvar harness-supervisor-tools)
(defvar harness-tools)
(defvar harness-supervisor-decision-tools)
(defvar harness-supervisor--decisions)
(defvar harness-supervisor--reminders)
(defvar harness-supervisor--calls)
(defvar harness-supervisor--configured)
(defvar harness-supervisor--raised)
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
(defvar harness-perms-auto-model)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(declare-function harness-provider-demo--last-user-text "harness-provider-demo")
(declare-function harness-provider-demo--script "harness-provider-demo")
(declare-function harness-agent--system-prompt "harness-agent")
(declare-function harness-supervisor--budget-point-p "harness-supervisor")
(declare-function harness-supervisor--on-task-changed "harness-supervisor")
(declare-function harness-supervisor--shutdown "harness-supervisor")
(declare-function harness-supervisor--init "harness-supervisor")
(declare-function harness-supervisor--approval "harness-supervisor")
(declare-function harness-supervisor--on-turn-started "harness-supervisor")
(declare-function harness-supervisor--note-decision "harness-supervisor")
(declare-function harness-supervisor--decided-p "harness-supervisor")
(declare-function harness-tools-agent--system-prompt "harness-tools-agent")
(declare-function harness-supervisor-prompt-section "harness-supervisor")
(declare-function harness-tasks--forget-stores "harness-tasks")
(declare-function harness-acp-connect "harness-acp")
(declare-function harness-acp-set-handler "harness-acp")
(declare-function harness-acp-request "harness-acp")
(declare-function harness-acp--drop-client "harness-acp")

;;;; Fixtures

(defvar harness-supervisor-test--script nil
  "The events the demo provider answers its next requests with.
One list of events per request, oldest first.  A request past the end
gets a plain answer that stops the turn.")

(defvar harness-supervisor-test--requests nil
  "What the demo provider was asked, newest first: (:text TEXT :system TEXT :model MODEL :ephemeral BOOL).")

(defun harness-supervisor-test--answer (request)
  "Answer REQUEST with the next list of events of the script, and note it."
  (push (list :text (harness-provider-demo--last-user-text request)
              :system (plist-get request :system)
              :model (plist-get request :model)
              :ephemeral (plist-get request :ephemeral))
        harness-supervisor-test--requests)
  (or (pop harness-supervisor-test--script)
      '((:type text :delta "ok") (:type done :stop-reason end-turn))))

(defconst harness-supervisor-test-stops
  '((:type text :delta "Here is the answer.") (:type done :stop-reason end-turn))
  "A request the model answers by stopping, with no decision.")

(defun harness-supervisor-test-calls (name &optional input)
  "Return the events of a request in which the model calls tool NAME with INPUT."
  (list (list :type 'tool-call :id (format "call-%s" (harness-short-id 4)) :name name :input input)))

(defconst harness-supervisor-test-modules
  '(store project config provider provider-demo tools session agent tools-agent supervisor)
  "The modules every test loads.")

(defmacro harness-supervisor-test-with-modules (extra &rest body)
  "Load the state layer, the supervisor and the modules EXTRA names, run BODY.
The demo provider plays the model through the script of the test."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     ;; The tools a test defines, and those of the modules an earlier test
     ;; loaded, are not this test's.
     (when (boundp 'harness-tools) (clrhash harness-tools))
     (dolist (m (append harness-supervisor-test-modules ',extra))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (dolist (table (list harness-supervisor--decisions harness-supervisor--reminders
                          harness-supervisor--calls harness-supervisor--configured
                          harness-supervisor--raised))
       (clrhash table))
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override #'harness-supervisor-test--answer)
           (harness-supervisor-test--script nil)
           (harness-supervisor-test--requests nil)
           (harness-supervisor t)
           (harness-supervisor-tasks t)
           (harness-supervisor-step-budget 80)
           (default-directory dir))
       ,@body)))

(defmacro harness-supervisor-test-with (&rest body)
  "Run BODY in the state layer with the demo provider and the supervisor."
  (declare (indent 0))
  `(harness-supervisor-test-with-modules () ,@body))

(defun harness-supervisor-test-allow-all ()
  "Add a stage after the supervisor's that allows every call, as yolo mode would."
  (harness-add-filter 'permission/decide
                      (lambda (_decision next &rest _) (funcall next (list :behavior 'allow)))
                      10))

(defun harness-supervisor-test-session (&rest plist)
  "Create a demo session with PLIST's settings; return its id."
  (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir)
                    :model "demo:scripted" plist)
             :id))

(defun harness-supervisor-test-get (sid)
  "Return the supervisor setting of session SID, as the session holds it."
  (plist-get (plist-get (harness-call 'session/get sid) :ext) :supervisor))

(defun harness-supervisor-test-confined (value)
  "Stub `sandbox/confined-p': answer VALUE, or signal when it is `error'."
  (harness-register-method 'sandbox/confined-p
                           (lambda (_cwd) (if (eq value 'error) (error "No sandbox today") value))))

(defun harness-supervisor-test-tool-names (sid)
  "Return the names of the tools session SID is offered."
  (mapcar (lambda (spec) (plist-get spec :name)) (harness-call 'tools/list sid)))

(defun harness-supervisor-test-decide (sid tool &optional kind paths)
  "Return what the permission chain decides for a call of TOOL in session SID."
  (harness-test-await
   (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                             (list :session (harness-call 'session/get sid) :tool tool
                                   :input nil :kind (or kind 'write) :paths paths :call-id "c1"))))

(defun harness-supervisor-test-approve (sid tool &optional decision)
  "Return what the approval stage makes of a call of TOOL in session SID.
DECISION is what the stages before it left, `ask' unless given.  The
stage goes on at once, so there is nothing to wait for."
  (let (result)
    (harness-supervisor--approval (or decision (list :behavior 'ask))
                                  (lambda (d) (setq result d))
                                  (list :session (harness-call 'session/get sid) :tool tool
                                        :input nil :kind 'meta :call-id "c1"))
    result))

(defun harness-supervisor-test-judge ()
  "Register the provider `judge', a model that denies every call it is asked about.
Return a function that gives the requests it got, newest first."
  (let ((requests nil))
    (harness-define-provider 'judge
      :label "Judge"
      :complete (lambda (req)
                  (push req requests)
                  (let ((cb (plist-get req :on-event)))
                    (dolist (ev '((:type text :delta "{\"decision\":\"deny\",\"reason\":\"too risky\"}")
                                  (:type done :stop-reason end-turn)))
                      (let ((ev ev)) (run-at-time 0.01 nil (lambda () (funcall cb ev))))))
                  (list :cancel #'ignore)))
    (lambda () requests)))

(defun harness-supervisor-test-run (sid name &optional input)
  "Execute tool NAME with INPUT in session SID and return its result."
  (harness-test-await
   (harness-call 'tools/execute sid (list :id (harness-short-id) :name name :input input))
   20))

(defun harness-supervisor-test-prompt (sid text)
  "Run a turn of session SID on TEXT; return how it ended."
  (plist-get (harness-test-await (harness-call 'agent/prompt sid text) 20) :stop-reason))

(defun harness-supervisor-test-nodes (sid kind)
  "Return the nodes of session SID of KIND, oldest first."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) kind)) (harness-call 'session/nodes sid)))

(defun harness-supervisor-test-reminders (sid)
  "Return the texts the supervisor steered session SID with, oldest first."
  (cl-loop for n in (harness-supervisor-test-nodes sid 'user)
           when (equal (plist-get (harness-node-sender n) :source) "supervisor")
           collect (plist-get n :content)))

(defun harness-supervisor-test-hints (sid)
  "Return the texts of the hints in session SID's transcript, oldest first."
  (mapcar (lambda (n) (plist-get n :content)) (harness-supervisor-test-nodes sid 'hint)))

;;;; The settings

(ert-deftest harness-supervisor-settings-have-their-defaults ()
  "Sessions and tasks are judged from their first message by default; a soft budget of 80 calls.
DeepSeek supervisors think at max, their workers at medium."
  (should (eq 'auto (eval (car (get 'harness-supervisor 'standard-value)) t)))
  (should (eq 'auto (eval (car (get 'harness-supervisor-tasks 'standard-value)) t)))
  (should (eq 'auto (eval (car (get 'harness-supervisor-judge-model 'standard-value)) t)))
  (should (null (eval (car (get 'harness-supervisor-tiers 'standard-value)) t)))
  (should (equal '((deepseek . "max"))
                 (eval (car (get 'harness-supervisor-thinking 'standard-value)) t)))
  (should (equal '((deepseek . "medium"))
                 (eval (car (get 'harness-supervisor-worker-thinking 'standard-value)) t)))
  (should (= 80 (eval (car (get 'harness-supervisor-step-budget 'standard-value)) t)))
  ;; The mode is a choice of three: judge, always supervise, always hands-on.
  (dolist (value '(auto t nil))
    (should (harness-test-fits-p (get 'harness-supervisor 'custom-type) value))
    (should (harness-test-fits-p (get 'harness-supervisor-tasks 'custom-type) value)))
  (should-not (harness-test-fits-p (get 'harness-supervisor 'custom-type) 'sometimes))
  ;; A .dir-locals.el may set the three, but nothing else.
  (should (funcall (get 'harness-supervisor 'safe-local-variable) 'auto))
  (should (funcall (get 'harness-supervisor 'safe-local-variable) nil))
  (should-not (funcall (get 'harness-supervisor 'safe-local-variable) 'sometimes))
  (should (harness-test-fits-p (get 'harness-supervisor-tiers 'custom-type)
                               '((mundane . "demo:cheap") (hard . "demo:big"))))
  (should-not (harness-test-fits-p (get 'harness-supervisor-tiers 'custom-type) '((easy . "demo:cheap"))))
  (dolist (option '(harness-supervisor-thinking harness-supervisor-worker-thinking))
    (should (harness-test-fits-p (get option 'custom-type) '((deepseek . "max"))))
    (should-not (harness-test-fits-p (get option 'custom-type) '((deepseek . max))))
    (should-not (harness-test-fits-p (get option 'custom-type) '(("deepseek" . "max")))))
  ;; The module is loaded in here, so the documentation can be read.
  (harness-supervisor-test-with
    (dolist (option '(harness-supervisor harness-supervisor-tasks harness-supervisor-judge-model
                      harness-supervisor-tiers harness-supervisor-thinking
                      harness-supervisor-worker-thinking harness-supervisor-step-budget))
      (ert-info ((symbol-name option))
        (should (assq option (get 'harness 'custom-group)))
        (should (string-match-p "settings page"
                                (replace-regexp-in-string
                                 "[ \n]+" " " (documentation-property option 'variable-documentation t))))))
    (should (string-match-p "164 real sessions"
                            (documentation-property 'harness-supervisor-step-budget
                                                    'variable-documentation t)))))

;;;; Which sessions supervise

(ert-deftest harness-supervisor-main-sessions-take-the-setting ()
  "A top-level session supervises, or is hands-on, as the setting says."
  (harness-supervisor-test-with
    (let ((created (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted")))
      (should (eq t (harness-supervisor-test-get (plist-get created :id))))
      ;; The plist `session/create' returns shows it too, for whoever made the session.
      (should (eq t (plist-get (plist-get created :ext) :supervisor))))
    (let ((harness-supervisor nil))
      (let ((sid (harness-supervisor-test-session)))
        (should (eq :false (harness-supervisor-test-get sid)))
        (should-not (harness-call 'supervisor/active-p sid))))))

(ert-deftest harness-supervisor-announces-the-setting-with-the-session ()
  "The last `session/changed' of a new session carries its setting."
  (harness-supervisor-test-with
    (let ((announced nil))
      (harness-on 'session/changed (lambda (id plist) (push (cons id plist) announced)))
      (let* ((sid (harness-supervisor-test-session))
             (last (cdr (cl-find sid announced :key #'car :test #'equal))))
        (should (eq t (plist-get (plist-get last :ext) :supervisor)))))))

(ert-deftest harness-supervisor-setting-is-read-per-project ()
  "A .dir-locals.el of the project overrides `harness-supervisor' for its sessions."
  (harness-supervisor-test-with
    (let ((project (harness-test-temp-dir)))
      (with-temp-file (expand-file-name ".dir-locals.el" project)
        (prin1 '((nil . ((harness-supervisor . nil)))) (current-buffer)))
      (let ((elsewhere (harness-supervisor-test-session))
            (here (plist-get (harness-call 'session/create :cwd project :model "demo:scripted") :id)))
        (should (eq t (harness-supervisor-test-get elsewhere)))
        (should (eq :false (harness-supervisor-test-get here)))))))

(ert-deftest harness-supervisor-forks-copy-their-parents ()
  "A fork supervises as its parent does; a parent not governed gives it nothing."
  (harness-supervisor-test-with
    (let ((parent (harness-supervisor-test-session)))
      (should (eq t (harness-supervisor-test-get
                     (plist-get (harness-test-await (harness-call 'session/fork parent)) :id))))
      (harness-call 'supervisor/set parent :false)
      (let ((fork (harness-test-await (harness-call 'session/fork parent))))
        (should (eq 'fork (plist-get fork :kind)))
        (should (eq :false (harness-supervisor-test-get (plist-get fork :id)))))
      (harness-call 'session/set-ext parent :supervisor nil)
      (should-not (harness-supervisor-test-get
                   (plist-get (harness-test-await (harness-call 'session/fork parent)) :id))))))

(ert-deftest harness-supervisor-other-kinds-are-never-governed ()
  "Sub-agents, side conversations and any other kind get no setting."
  (harness-supervisor-test-with
    (let ((parent (harness-supervisor-test-session)))
      (dolist (kind '(subagent btw scratch))
        (ert-info ((symbol-name kind))
          (let ((sid (harness-supervisor-test-session :kind kind :parent-id parent)))
            (should-not (harness-supervisor-test-get sid))
            (should-not (harness-call 'supervisor/active-p sid))
            (should-not (harness-call 'supervisor/get sid)))))
      ;; Nor is a fork made on a sub-agent's behalf, and a main session
      ;; with a parent is not top-level.
      (should-not (harness-supervisor-test-get (harness-supervisor-test-session :parent-id parent)))
      (let* ((child (harness-supervisor-test-session :kind 'subagent :parent-id parent))
             (fork (plist-get (harness-test-await (harness-call 'session/fork child :kind 'subagent)) :id)))
        (should-not (harness-supervisor-test-get fork))))))

(ert-deftest harness-supervisor-a-setting-its-maker-gave-stays ()
  "A session made with its setting in `:ext' keeps it."
  (harness-supervisor-test-with
    (should (eq :false (harness-supervisor-test-get
                        (harness-supervisor-test-session :ext '(:supervisor :false)))))
    (let ((harness-supervisor nil))
      (should (eq t (harness-supervisor-test-get
                     (harness-supervisor-test-session :ext '(:supervisor t))))))))

(ert-deftest harness-supervisor-a-session-from-before-the-module-is-not-governed ()
  "A session with no setting is not governed: it is not supervised and `get' says nil."
  (harness-supervisor-test-with-modules (tools-fs)
    (let ((sid (harness-supervisor-test-session)))
      (harness-call 'session/set-ext sid :supervisor nil)
      (should-not (harness-call 'supervisor/get sid))
      (should-not (harness-call 'supervisor/active-p sid))
      (should (member "read_file" (harness-supervisor-test-tool-names sid)))
      (should-not (member "no_plan_needed" (harness-supervisor-test-tool-names sid))))))

;;;; The session judge

(defconst harness-supervisor-test-judge-supervises
  '((:type text :delta "SUPERVISE") (:type done :stop-reason end-turn))
  "What a session judge answers when the job is to supervise.")

(defun harness-supervisor-test-judge-requests ()
  "Return the requests the demo provider saw for a session judge, oldest first."
  (cl-remove-if-not (lambda (request) (plist-get request :ephemeral))
                    (reverse harness-supervisor-test--requests)))

(defun harness-supervisor-test-judge-mark (sid)
  "Return session SID's pending judge mark, as its `:ext' holds it."
  (plist-get (plist-get (harness-call 'session/get sid) :ext) :supervisor-judge))

(defun harness-supervisor-test-judge-says (word &optional delay)
  "Return a judge script that answers WORD, after DELAY seconds when given.
A DELAY is how a test has the judge answer while, or after, its turn runs."
  (if delay
      (list (list :type 'text :delta word)
            (list :type 'wait :seconds delay)
            (list :type 'done :stop-reason 'end-turn))
    (list (list :type 'text :delta word)
          (list :type 'done :stop-reason 'end-turn))))

(defun harness-supervisor-test-session-in (dir &rest plist)
  "Create a demo session in DIR with PLIST's settings; return its id.
Sessions in one directory share the settings of that directory, as
sessions a project starts do."
  (plist-get (apply #'harness-call 'session/create :cwd dir :model "demo:scripted" plist) :id))

(defun harness-supervisor-test-note (sid)
  "Return the note that says how session SID's opening message was judged."
  (car (cl-remove-if-not #'harness-node-supervisor (harness-supervisor-test-nodes sid 'hint))))

(defun harness-supervisor-test-note-record (sid)
  "Return what the chat reads of session SID's judgement note, or nil."
  (harness-node-supervisor (harness-supervisor-test-note sid)))

(defun harness-supervisor-test-action (sid name)
  "Return action NAME of session SID's judgement note, as the chat reads it."
  (cl-find name (plist-get (harness-supervisor-test-note-record sid) :actions)
           :key (lambda (action) (plist-get action :action)) :test #'equal))

(defun harness-supervisor-test-act (sid action)
  "Move ACTION of session SID's judgement note on; return what the harness answered."
  (harness-call 'supervisor/act sid (plist-get (harness-supervisor-test-note sid) :id) action))

(ert-deftest harness-supervisor-a-judged-supervising-job-keeps-the-mode ()
  "An `auto' session whose opening message reads supervising stays supervising."
  (harness-supervisor-test-with
    (let ((harness-supervisor 'auto))
      (let ((sid (harness-supervisor-test-session)))
        ;; It starts supervising as new sessions did, with the judgement to come.
        (should (eq t (harness-supervisor-test-get sid)))
        (should (eq t (harness-supervisor-test-judge-mark sid)))
        (setq harness-supervisor-test--script
              (list harness-supervisor-test-judge-supervises
                    (harness-supervisor-test-calls "no_plan_needed" '(:reason "the whole storage layer"))
                    '((:type text :delta "Plan it.") (:type done :stop-reason end-turn))))
        (should (eq 'end-turn (harness-supervisor-test-prompt sid "Rework the whole storage layer")))
        (harness-test-wait (lambda () (null (harness-supervisor-test-judge-mark sid))) 5
                           "the judge to answer")
        (should (eq t (harness-supervisor-test-get sid)))
        (should (harness-call 'supervisor/active-p sid))
        (should (member "judged supervising (demo:scripted)"
                        (harness-supervisor-test-hints sid)))
        ;; The judge was asked once, in a request of its own: ephemeral, the
        ;; opening message, and the one-word question.
        (let ((judge (car (harness-supervisor-test-judge-requests))))
          (should (= 1 (length (harness-supervisor-test-judge-requests))))
          (should (equal "demo:scripted" (plist-get judge :model)))
          (should (string-match-p "Rework the whole storage layer" (plist-get judge :text)))
          (should (string-match-p "Reply with exactly one word" (plist-get judge :system)))
          ;; The judge is not the turn: its request carries no session transcript.
          (should (string-match-p "SUPERVISE or HANDS-ON" (plist-get judge :text))))))))

(ert-deftest harness-supervisor-a-judged-hands-on-job-gives-the-mode-up ()
  "An `auto' session whose opening message reads hands-on ends up hands-on."
  (harness-supervisor-test-with-modules (tools-fs)
    (let ((harness-supervisor 'auto))
      (let ((sid (harness-supervisor-test-session)))
        (setq harness-supervisor-test--script
              (list (harness-supervisor-test-judge-says "HANDS-ON" 0.05)
                    (harness-supervisor-test-calls "no_plan_needed" '(:reason "a question"))
                    '((:type text :delta "It copies the buffer.") (:type done :stop-reason end-turn))))
        (should (eq 'end-turn (harness-supervisor-test-prompt sid "What does this function do?")))
        (harness-test-wait (lambda () (eq :false (harness-supervisor-test-get sid))) 5
                           "the judge to read the message hands-on")
        (should-not (harness-call 'supervisor/active-p sid))
        (should-not (harness-supervisor-test-judge-mark sid))
        (should (member "judged hands-on (demo:scripted)"
                        (harness-supervisor-test-hints sid)))
        ;; Hands-on from then on: the writing tools come back, the plan tools go.
        (should (member "edit_file" (harness-supervisor-test-tool-names sid)))
        (should-not (member "no_plan_needed" (harness-supervisor-test-tool-names sid)))))))

(ert-deftest harness-supervisor-a-plan-from-a-hands-on-session-is-refused ()
  "A plan call written before the judge read the message hands-on starts nothing."
  (harness-supervisor-test-with
    (harness-supervisor-test-allow-all)
    (let ((sid (harness-supervisor-test-session :ext '(:supervisor :false))))
      (dolist (case (list (cons "submit_plan"
                                '(:summary "Do it."
                                  :steps ((:id "a" :title "One" :prompt "Do a."
                                           :tier "mundane" :reason "small"))))
                          (cons "retry_step" '(:step "a" :reason "it failed"))))
        (pcase-let ((`(,tool . ,input) case))
          (ert-info (tool)
            (let ((result (harness-supervisor-test-run sid tool input)))
              (should (plist-get result :is-error))
              (should (string-match-p "hands-on" (plist-get result :content)))))))
      ;; Nothing was recorded, and no worker was made.
      (should-not (plist-get (plist-get (harness-call 'session/get sid) :ext) :supervisor-plans))
      (should-not (harness-call 'supervisor/active-p sid)))))

(ert-deftest harness-supervisor-the-judge-asks-the-cheap-tier ()
  "The judge runs on the provider's cheap tier, or the model the setting names."
  (harness-supervisor-test-with
    (harness-register-method 'provider/tier-model
                             (lambda (_model tier) (and (eq tier 'cheap) "demo:cheap")))
    (let ((harness-supervisor 'auto))
      (let ((sid (harness-supervisor-test-session)))
        (setq harness-supervisor-test--script
              (list harness-supervisor-test-judge-supervises
                    (harness-supervisor-test-calls "no_plan_needed" '(:reason "big"))
                    '((:type text :delta "Plan it.") (:type done :stop-reason end-turn))))
        (harness-supervisor-test-prompt sid "Build the whole feature")
        (should (equal "demo:cheap" (plist-get (car (harness-supervisor-test-judge-requests)) :model))))
      ;; A named model is used as it is.
      (let ((harness-supervisor-judge-model "demo:chosen")
            (harness-supervisor-test--requests nil)
            (harness-supervisor-test--script nil))
        (let ((sid (harness-supervisor-test-session)))
          (setq harness-supervisor-test--script
                (list harness-supervisor-test-judge-supervises
                      (harness-supervisor-test-calls "no_plan_needed" '(:reason "big"))
                      '((:type text :delta "Plan it.") (:type done :stop-reason end-turn))))
          (harness-supervisor-test-prompt sid "Build the whole feature")
          (should (equal "demo:chosen" (plist-get (car (harness-supervisor-test-judge-requests)) :model))))))))

(ert-deftest harness-supervisor-a-setting-that-decides-is-never-judged ()
  "With `t' or nil, no judge runs and no mark waits on the session."
  (harness-supervisor-test-with
    (dolist (case (list (list t (list (harness-supervisor-test-calls "no_plan_needed" '(:reason "nothing"))
                                      '((:type text :delta "Fine.") (:type done :stop-reason end-turn))))
                        (list nil (list harness-supervisor-test-stops))))
      (pcase-let ((`(,setting ,script) case))
        (ert-info ((format "%S" setting))
          (let ((harness-supervisor setting)
                (harness-supervisor-test--requests nil))
            (let ((sid (harness-supervisor-test-session)))
              (should-not (harness-supervisor-test-judge-mark sid))
              (setq harness-supervisor-test--script script)
              (harness-supervisor-test-prompt sid "What does foo do?")
              (should-not (harness-supervisor-test-judge-requests))
              (should (eq (if setting t :false) (harness-supervisor-test-get sid))))))))))

(ert-deftest harness-supervisor-the-user-switch-takes-the-judgement-away ()
  "A mode the user flipped, before the message or while the judge runs, is never judged."
  (harness-supervisor-test-with
    (let ((harness-supervisor 'auto))
      ;; Before the first message: the mark is dropped, and no judge is asked.
      (let ((sid (harness-supervisor-test-session)))
        (should (eq t (harness-supervisor-test-judge-mark sid)))
        (harness-call 'supervisor/set sid :false)
        (should-not (harness-supervisor-test-judge-mark sid))
        (setq harness-supervisor-test--script (list harness-supervisor-test-stops)
              harness-supervisor-test--requests nil)
        (should (eq 'end-turn (harness-supervisor-test-prompt sid "What does foo do?")))
        (should-not (harness-supervisor-test-judge-requests))
        (should (eq :false (harness-supervisor-test-get sid))))
      ;; While the judge is in flight: its verdict arrives after the user's
      ;; switch, and is dropped.
      (let ((sid (harness-supervisor-test-session)))
        (setq harness-supervisor-test--script
              (list (harness-supervisor-test-judge-says "HANDS-ON" 0.15)
                    (harness-supervisor-test-calls "no_plan_needed" '(:reason "a question"))
                    '((:type text :delta "It copies the buffer.") (:type done :stop-reason end-turn))))
        (should (eq 'end-turn (harness-supervisor-test-prompt sid "What does this function do?")))
        (should (eq t (harness-supervisor-test-get sid))) ; the judge has not answered yet
        (harness-call 'supervisor/set sid t)
        (harness-test-wait (lambda () (not (gethash sid harness-supervisor--judging))) 5
                           "the dropped judge to finish")
        (should (eq t (harness-supervisor-test-get sid)))
        ;; The dropped verdict writes no note: the user's choice stands alone.
        (should-not (harness-supervisor-test-note sid))))))

(defun harness-supervisor-test-judge-failure (answer reason-regexp)
  "Run a session whose judge answers ANSWER and then gives no verdict.
REASON-REGEXP is matched against the hint that says the default stands."
  (let ((sid (harness-supervisor-test-session)))
    (setq harness-supervisor-test--script
          (list answer
                (harness-supervisor-test-calls "no_plan_needed" '(:reason "nothing to do"))
                '((:type text :delta "Fine.") (:type done :stop-reason end-turn))))
    (should (eq 'end-turn (harness-supervisor-test-prompt sid "What does foo do?")))
    (harness-test-wait (lambda () (null (harness-supervisor-test-judge-mark sid))) 5
                       "the judge to give no verdict")
    (should (eq t (harness-supervisor-test-get sid)))
    (should (cl-some (lambda (hint) (string-match-p reason-regexp hint))
                     (harness-supervisor-test-hints sid)))
    sid))

(ert-deftest harness-supervisor-a-judge-with-no-answer-keeps-the-default ()
  "An unusable word, an error or a timeout leaves the session supervising, and says so."
  (harness-supervisor-test-with
    (let ((harness-supervisor 'auto))
      (harness-supervisor-test-judge-failure
       '((:type text :delta "Hard to say, maybe both.") (:type done :stop-reason end-turn))
       "not judged (the model answered")
      (harness-supervisor-test-judge-failure
       '((:type done :stop-reason error :error "no model today"))
       "not judged (no model today)")
      (let ((harness-supervisor--judge-timeout 0.05))
        (harness-supervisor-test-judge-failure
         '((:type wait :seconds 5) (:type done :stop-reason end-turn))
         "not judged (the model took longer than")))))

(ert-deftest harness-supervisor-the-judge-is-asked-once ()
  "Once judged, later turns ask no judge again."
  (harness-supervisor-test-with
    (let ((harness-supervisor 'auto)
          (harness-supervisor-test--requests nil))
      (let ((sid (harness-supervisor-test-session)))
        (setq harness-supervisor-test--script
              (list harness-supervisor-test-judge-supervises
                    (harness-supervisor-test-calls "no_plan_needed" '(:reason "answered"))
                    '((:type text :delta "Yes.") (:type done :stop-reason end-turn))
                    (harness-supervisor-test-calls "no_plan_needed" '(:reason "answered again"))
                    '((:type text :delta "Again.") (:type done :stop-reason end-turn))))
        (harness-supervisor-test-prompt sid "What does foo do?")
        (harness-supervisor-test-prompt sid "And bar?")
        (should (= 1 (length (harness-supervisor-test-judge-requests))))))))

(ert-deftest harness-supervisor-the-note-is-the-harnesss-own-word ()
  "The judgement reads as a harness hint, and the judge's answer is nowhere.
The note says it in the harness's voice, carries the two actions as its
`:meta', and the hint never reaches the model: nothing of the judge is
shown as an agent response."
  (harness-supervisor-test-with
    (let* ((dir (harness-test-temp-dir))
           (harness-supervisor 'auto))
      (let ((sid (harness-supervisor-test-session-in dir)))
        (setq harness-supervisor-test--script
              (list (harness-supervisor-test-judge-says "HANDS-ON")
                    (harness-supervisor-test-calls "no_plan_needed" '(:reason "a question"))
                    '((:type text :delta "It copies the buffer.") (:type done :stop-reason end-turn))))
        (harness-supervisor-test-prompt sid "What does this function do?")
        (harness-test-wait (lambda () (null (harness-supervisor-test-judge-mark sid))) 5
                           "the judge to answer")
        ;; One note, in the harness's voice, saying what was decided.
        (should (member "judged hands-on (demo:scripted)" (harness-supervisor-test-hints sid)))
        (should (= 1 (length (cl-remove-if-not #'harness-node-supervisor
                                               (harness-supervisor-test-nodes sid 'hint)))))
        (let ((record (harness-supervisor-test-note-record sid)))
          (should record)
          (should-not (harness-json-true-p (plist-get record :judged)))
          (should (equal "demo:scripted" (plist-get record :model)))
          (should-not (harness-json-true-p (plist-get record :mode)))
          (should (equal "harness-supervisor" (plist-get record :setting)))
          (should (equal (file-name-as-directory (expand-file-name dir))
                         (file-name-as-directory (expand-file-name (plist-get record :cwd)))))
          (should (equal '("always" "mode")
                         (mapcar (lambda (action) (plist-get action :action))
                                 (plist-get record :actions))))
          (should (equal '("always hands-on" "switch to supervising")
                         (mapcar (lambda (action) (plist-get action :label))
                                 (plist-get record :actions))))
          (should (cl-every (lambda (action) (null (plist-get action :state)))
                            (plist-get record :actions))))
        ;; The judge's own answer is in no node of the transcript.
        (should-not (let ((case-fold-search nil))
                      (cl-some (lambda (node)
                                 (string-match-p "HANDS-ON" (format "%s" (plist-get node :content))))
                               (harness-call 'session/nodes sid))))
        ;; Nor does the model ever get the note: it is no agent response.
        (should-not (string-match-p "judged hands-on"
                                    (harness-json-encode-text (harness-call 'session/messages sid))))))))

(defun harness-supervisor-test-judge-a-question (sid)
  "Run the turn of SID that the judge reads as a hands-on job, and wait for it."
  (setq harness-supervisor-test--script
        (list (harness-supervisor-test-judge-says "HANDS-ON")
              (harness-supervisor-test-calls "no_plan_needed" '(:reason "a question"))
              '((:type text :delta "It copies the buffer.") (:type done :stop-reason end-turn))))
  (harness-supervisor-test-prompt sid "What does this function do?")
  (harness-test-wait (lambda () (null (harness-supervisor-test-judge-mark sid))) 5
                     "the judge to read the message hands-on"))

(ert-deftest harness-supervisor-the-notes-always-action-stops-judging-here ()
  "The note's \"always\" action writes the setting, and takes it back again.
One click and no new session here is judged -- they start as the judge
read this one -- the click after that judges them again, and the one
after that stops the judging once more."
  (harness-supervisor-test-with
    (let* ((dir (harness-test-temp-dir))
           (harness-supervisor 'auto))
      (let ((sid (harness-supervisor-test-session-in dir)))
        (harness-supervisor-test-judge-a-question sid)
        (should (eq 'auto (harness-supervisor--setting 'harness-supervisor dir)))
        ;; A click: new sessions here are hands-on, and none of them is judged.
        (let ((answer (harness-supervisor-test-act sid "always")))
          (should (eq 'done (plist-get answer :state)))
          (should (string-match-p "always hands-on" (plist-get answer :message))))
        (should-not (harness-supervisor--setting 'harness-supervisor dir))
        (should (eq 'done (plist-get (harness-supervisor-test-action sid "always") :state)))
        (setq harness-supervisor-test--requests nil
              harness-supervisor-test--script (list harness-supervisor-test-stops))
        (let ((next (harness-supervisor-test-session-in dir)))
          (should (eq :false (harness-supervisor-test-get next)))
          (should-not (harness-supervisor-test-judge-mark next))
          (harness-supervisor-test-prompt next "What does this function do?")
          (should-not (harness-supervisor-test-judge-requests)))
        ;; Undone: the setting goes back to a model's choice, and sessions are judged.
        (let ((answer (harness-supervisor-test-act sid "always")))
          (should (eq 'undone (plist-get answer :state)))
          (should (string-match-p "Judging on again" (plist-get answer :message))))
        (should (eq 'auto (harness-supervisor--setting 'harness-supervisor dir)))
        (should (eq 'undone (plist-get (harness-supervisor-test-action sid "always") :state)))
        ;; Redone: the setting is the judge's mode again.
        (should (eq 'done (plist-get (harness-supervisor-test-act sid "always") :state)))
        (should-not (harness-supervisor--setting 'harness-supervisor dir))
        (should (eq 'done (plist-get (harness-supervisor-test-action sid "always") :state)))))))

(ert-deftest harness-supervisor-a-note-without-the-config-module-offers-the-mode-only ()
  "The setting's action needs `config/set'; without it the note offers no more.
A harness without the config module has no setting to write, so the note
keeps the one action that is the session's own."
  (harness-supervisor-test-with
    (let ((harness-supervisor 'auto))
      (let ((sid (harness-supervisor-test-session)))
        (remhash 'config/set harness--methods)
        (harness-supervisor-test-judge-a-question sid)
        (should (equal '("mode")
                       (mapcar (lambda (action) (plist-get action :action))
                               (plist-get (harness-supervisor-test-note-record sid) :actions))))))))

(ert-deftest harness-supervisor-the-notes-mode-action-puts-the-session-elsewhere ()
  "The note's \"mode\" action is the V key's switch, with its way back.
A click makes the session hands-on, and the click after that makes it
supervise again, as the note records; the switch is a hint of its own,
as a turn of the key is."
  (harness-supervisor-test-with
    (let ((harness-supervisor 'auto))
      (let ((sid (harness-supervisor-test-session)))
        (setq harness-supervisor-test--script
              (list harness-supervisor-test-judge-supervises
                    (harness-supervisor-test-calls "no_plan_needed" '(:reason "the whole layer"))
                    '((:type text :delta "Plan it.") (:type done :stop-reason end-turn))))
        (harness-supervisor-test-prompt sid "Rework the whole storage layer")
        (harness-test-wait (lambda () (null (harness-supervisor-test-judge-mark sid))) 5
                           "the judge to answer")
        (should (eq t (harness-supervisor-test-get sid)))
        (should (equal "switch to hands-on"
                       (plist-get (harness-supervisor-test-action sid "mode") :label)))
        ;; A click, as the V key would: hands-on, and the transcript says so.
        (let ((answer (harness-supervisor-test-act sid "mode")))
          (should (eq 'done (plist-get answer :state)))
          (should (string-match-p "off" (plist-get answer :message))))
        (should (eq :false (harness-supervisor-test-get sid)))
        (should-not (harness-call 'supervisor/active-p sid))
        (should (member "Supervisor mode off" (harness-supervisor-test-hints sid)))
        (should (eq 'done (plist-get (harness-supervisor-test-action sid "mode") :state)))
        ;; Undone: supervising again, and the note offers the switch again.
        (should (eq 'undone (plist-get (harness-supervisor-test-act sid "mode") :state)))
        (should (eq t (harness-supervisor-test-get sid)))
        (should (member "Supervisor mode on" (harness-supervisor-test-hints sid)))
        ;; Redone.
        (should (eq 'done (plist-get (harness-supervisor-test-act sid "mode") :state)))
        (should (eq :false (harness-supervisor-test-get sid)))))))

(ert-deftest harness-supervisor-the-note-of-a-task-writes-the-tasks-setting ()
  "A task session's note writes `harness-supervisor-tasks' at the task's project.
That is the setting that decided how the session starts, so no session
of a task here is judged either."
  (harness-supervisor-test-with-tasks
    (setq harness-supervisor-tasks 'auto
          harness-supervisor 'auto)
    (let* ((id (plist-get (harness-call 'task/submit default-directory "fix the parser") :id))
           (sid (harness-supervisor-test-task-session id)))
      (harness-supervisor-test-judge-a-question sid)
      (should (equal "harness-supervisor-tasks" (plist-get (harness-supervisor-test-note-record sid) :setting)))
      (should (eq 'auto (harness-supervisor--setting 'harness-supervisor-tasks default-directory)))
      (let ((answer (harness-supervisor-test-act sid "always")))
        (should (eq 'done (plist-get answer :state))))
      (should-not (harness-supervisor--setting 'harness-supervisor-tasks default-directory))
      ;; The tasks setting took it; how sessions of the user start is untouched.
      (should (eq 'auto (harness-supervisor--setting 'harness-supervisor default-directory)))
      (harness-supervisor-test-wait-task id 'done))))

(ert-deftest harness-supervisor-a-note-action-that-cannot-be-taken-changes-nothing ()
  "An action that fails leaves the note as it was, with its state nil.
The harness then answers nothing, and the button is still the action."
  (harness-supervisor-test-with
    (let ((harness-supervisor 'auto))
      (let ((sid (harness-supervisor-test-session)))
        (harness-supervisor-test-judge-a-question sid)
        ;; A call the harness cannot make: writing the setting fails, and the
        ;; action stays the one to take.
        (harness-register-method 'config/set (lambda (&rest _) (error "the policy fixes it")))
        (should-error (harness-supervisor-test-act sid "always"))
        (should (null (plist-get (harness-supervisor-test-action sid "always") :state)))
        ;; A node that is no note, and an action the note does not offer.
        (harness-call 'session/hint sid "Plan updated")
        (let ((plan (car (last (harness-supervisor-test-nodes sid 'hint)))))
          (should-error (harness-call 'supervisor/act sid (plist-get plan :id) "always")))
        (should-error (harness-supervisor-test-act sid "whatever"))))))

(ert-deftest harness-supervisor-the-demo-plays-the-session-judge ()
  "The demo provider answers the judge, so a demo session is judged like any other."
  (harness-supervisor-test-with
    (let ((harness-provider-demo-script-override nil))
      (dolist (case '(("Plan the whole refactor of the storage layer" "SUPERVISE")
                      ("What does this function do?" "HANDS-ON")))
        (pcase-let ((`(,message ,word) case))
          (ert-info (message)
            (let* ((events (harness-provider-demo--script
                            (list :system harness-supervisor--judge-system-prompt
                                  :messages (list (list :role 'user
                                                        :content (list (list :type "text"
                                                                             :text (harness-supervisor--judge-question
                                                                                    message))))))))
                   (reply (mapconcat (lambda (event) (or (plist-get event :delta) "")) events "")))
              (should (equal word (string-trim reply))))))))))

;;;; Thinking levels

(ert-deftest harness-supervisor-the-mode-raises-the-thinking-its-provider-names ()
  "A session that starts supervising takes the level of its provider, and gets its own back."
  (harness-supervisor-test-with
    (let ((harness-supervisor-thinking '((demo . "max"))))
      (let* ((sid (harness-supervisor-test-session :thinking "low"))
             (thinking (lambda () (plist-get (harness-call 'session/get sid) :thinking))))
        (should (equal "max" (funcall thinking)))
        ;; Off puts back what it had; on raises it again and remembers that.
        (harness-call 'supervisor/set sid :false)
        (should (equal "low" (funcall thinking)))
        (harness-call 'supervisor/set sid t)
        (should (equal "max" (funcall thinking)))
        (harness-call 'supervisor/set sid :false)
        (should (equal "low" (funcall thinking)))))
    ;; A session that had no level of its own gets none back.
    (let ((harness-supervisor-thinking '((demo . "max"))))
      (let* ((sid (harness-supervisor-test-session))
             (thinking (lambda () (plist-get (harness-call 'session/get sid) :thinking))))
        (should (equal "max" (funcall thinking)))
        (harness-call 'supervisor/set sid :false)
        (should (null (funcall thinking)))))
    ;; A provider the setting does not name keeps the session's own level.
    (let ((harness-supervisor-thinking '((deepseek . "max"))))
      (let ((sid (harness-supervisor-test-session :thinking "low")))
        (should (equal "low" (plist-get (harness-call 'session/get sid) :thinking)))
        (harness-call 'supervisor/set sid :false)
        (should (equal "low" (plist-get (harness-call 'session/get sid) :thinking)))))))

(ert-deftest harness-supervisor-a-level-chosen-while-supervising-stands ()
  "Turning the mode off keeps a level the session was changed to meanwhile."
  (harness-supervisor-test-with
    (let ((harness-supervisor-thinking '((demo . "max"))))
      (let ((sid (harness-supervisor-test-session :thinking "low")))
        (should (equal "max" (plist-get (harness-call 'session/get sid) :thinking)))
        (harness-call 'session/update sid :thinking "high")
        (harness-call 'supervisor/set sid :false)
        (should (equal "high" (plist-get (harness-call 'session/get sid) :thinking)))))))

;;;; Methods

(ert-deftest harness-supervisor-set-get-and-active-p ()
  "`supervisor/set' turns the mode on and off, and says so in a hint and an event."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session))
          (changed nil) (ext-changed nil))
      (harness-on 'supervisor/changed (lambda (id on) (push (list id on) changed)))
      (harness-on 'session/ext-changed (lambda (id key value) (push (list id key value) ext-changed)))
      (should (eq t (harness-call 'supervisor/get sid)))
      (should (harness-call 'supervisor/active-p sid))
      ;; Off is an explicit off, not no setting.
      (let ((session (harness-call 'supervisor/set sid :false)))
        (should (equal sid (plist-get session :id)))
        (should (eq :false (plist-get (plist-get session :ext) :supervisor))))
      (should (eq :false (harness-call 'supervisor/get sid)))
      (should-not (harness-call 'supervisor/active-p sid))
      (should (equal (list (list sid :false)) changed))
      (should (equal (list (list sid :supervisor :false)) ext-changed))
      (should (equal '("Supervisor mode off") (harness-supervisor-test-hints sid)))
      ;; Any true value turns it on; nil turns it off like :false.
      (should (eq t (plist-get (plist-get (harness-call 'supervisor/set sid t) :ext) :supervisor)))
      (should (harness-call 'supervisor/active-p sid))
      (harness-call 'supervisor/set sid nil)
      (should (eq :false (harness-call 'supervisor/get sid)))
      (harness-call 'supervisor/set sid "yes")
      (should (eq t (harness-call 'supervisor/get sid)))
      (should (equal (list (list sid t) (list sid :false) (list sid t) (list sid :false)) changed))
      (should (equal '("Supervisor mode off" "Supervisor mode on" "Supervisor mode off" "Supervisor mode on")
                     (harness-supervisor-test-hints sid))))))

(ert-deftest harness-supervisor-methods-know-no-such-session ()
  "A session that is not there does not supervise, and cannot be asked about."
  (harness-supervisor-test-with
    (should-not (harness-call 'supervisor/active-p "no-such-session"))
    (should-not (harness-call 'supervisor/active-p nil))
    (should-error (harness-call 'supervisor/get "no-such-session"))
    (should-error (harness-call 'supervisor/set "no-such-session" t))))

(ert-deftest harness-supervisor-set-reaches-the-ui-as-a-session-update ()
  "Setting the mode touches the session, so the UI is sent its new plist."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session))
          (seen nil))
      (harness-on 'session/changed (lambda (id plist) (when (equal id sid) (push plist seen))))
      (harness-call 'supervisor/set sid :false)
      (should (eq :false (plist-get (plist-get (car seen) :ext) :supervisor)))
      (harness-call 'supervisor/set sid t)
      (should (eq t (plist-get (plist-get (car seen) :ext) :supervisor))))))

(ert-deftest harness-supervisor-the-switch-survives-a-reload-of-the-record ()
  "The setting is stored with the session as JSON does: t and :false come back as they were."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session)))
      (harness-call 'supervisor/set sid :false)
      (let ((stored (harness-json-parse (harness-json-encode (plist-get (harness-call 'session/get sid) :ext)))))
        (should (eq :false (plist-get stored :supervisor))))
      (harness-call 'supervisor/set sid t)
      (let ((stored (harness-json-parse (harness-json-encode (plist-get (harness-call 'session/get sid) :ext)))))
        (should (eq t (plist-get stored :supervisor)))))))

;;;; Methods, for every session at once

(ert-deftest harness-supervisor-set-all-changes-the-governed ()
  "`supervisor/set-all' turns the mode on or off for every governed session
the filter selects, and for no other: a sub-agent, a side conversation
and a session already at the asked value keep theirs.  Each change is
the hint and the event of `supervisor/set', and the ids changed come
back, newest first."
  (harness-supervisor-test-with
    (let* ((one (harness-supervisor-test-session :ext '(:supervisor :false)))
           (two (harness-supervisor-test-session :ext '(:supervisor :false)))
           (on (harness-supervisor-test-session))
           (sub (harness-supervisor-test-session :kind 'subagent :parent-id one))
           (btw (harness-supervisor-test-session :kind 'btw :parent-id one))
           (events nil))
      (harness-on 'supervisor/changed (lambda (id on) (push (list id on) events)))
      (let ((changed (harness-call 'supervisor/set-all t (list :active t))))
        (should (equal (sort (list one two) #'string<) (sort changed #'string<))))
      (dolist (sid (list one two))
        (should (eq t (harness-supervisor-test-get sid)))
        (should (equal '("Supervisor mode on") (harness-supervisor-test-hints sid))))
      (dolist (sid (list sub btw))
        (should-not (harness-supervisor-test-get sid))
        (should-not (harness-supervisor-test-hints sid)))
      (should (equal (sort (list (list one t) (list two t))
                           (lambda (a b) (string< (car a) (car b))))
                     (sort events (lambda (a b) (string< (car a) (car b))))))
      ;; Already on, and ungoverned: asking again changes nothing.
      (setq events nil)
      (should-not (harness-call 'supervisor/set-all t (list :active t)))
      (should-not events)
      ;; Off, as `supervisor/set' stores it, for every governed session.
      (should (equal (sort (list one two on) #'string<)
                     (sort (harness-call 'supervisor/set-all :false (list :active t)) #'string<)))
      (dolist (sid (list one two on))
        (should (eq :false (harness-supervisor-test-get sid))))
      (should (equal '("Supervisor mode on" "Supervisor mode off")
                     (harness-supervisor-test-hints one)))
      ;; A session that is not there is not selected, and no error.
      (should-not (harness-call 'supervisor/set-all nil (list :active t :except (list one two on)))))))

(ert-deftest harness-supervisor-set-all-takes-the-filter-and-every-session-without-one ()
  "`supervisor/set-all' changes what the filter selects: `:except' skips a
session, `:active' an inactive one, and without a filter every governed
session changes, an inactive one too, as `session/set-all' does."
  (harness-supervisor-test-with
    (let ((here (harness-supervisor-test-session :ext '(:supervisor :false)))
          (away (harness-supervisor-test-session :ext '(:supervisor :false)))
          (left (harness-supervisor-test-session :ext '(:supervisor :false))))
      (harness-call 'supervisor/set-all t (list :active t :except (list left)))
      (should (eq t (harness-supervisor-test-get here)))
      (should (eq :false (harness-supervisor-test-get left)))
      ;; Inactive, and so out of an active-only filter.
      (harness-call 'session/deactivate away)
      (harness-call 'supervisor/set away :false)
      (should-not (harness-call 'supervisor/set-all t (list :active t :except (list left))))
      (should (eq :false (harness-supervisor-test-get away)))
      ;; Without a filter, every governed session changes, inactive included.
      (should (equal (sort (list away left) #'string<)
                     (sort (harness-call 'supervisor/set-all t) #'string<)))
      (should (eq t (harness-supervisor-test-get away)))
      (should (eq t (harness-supervisor-test-get left))))))

;;;; The ACP call

(defvar harness-supervisor-test--messages nil
  "What the ACP client received, newest first: (METHOD PARAMS RESPOND).")

(defmacro harness-supervisor-test-with-acp (&rest body)
  "Run BODY with the supervisor and the ACP module, no server, no token."
  (declare (indent 0))
  `(let ((harness-acp--server-enabled nil)
         (harness-acp-token nil))
     (harness-supervisor-test-with-modules (acp)
       (setq harness-acp--clients nil
             harness-supervisor-test--messages nil)
       (unwind-protect (progn ,@body)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-supervisor-test-connect ()
  "Return an ACP connection whose messages go to `harness-supervisor-test--messages'."
  (let ((conn (harness-acp-connect)))
    (harness-acp-set-handler conn (lambda (method params respond)
                                    (push (list method params respond) harness-supervisor-test--messages)))
    conn))

(defun harness-supervisor-test-events (name)
  "Return the arguments of the bus events NAME the ACP client received, oldest first."
  (cl-loop for (method params) in (reverse harness-supervisor-test--messages)
           when (and (equal method "_harness/event") (equal (plist-get params :event) name))
           collect (plist-get params :args)))

(ert-deftest harness-supervisor-acp-call-from-the-ui ()
  "The call the UI makes, `_harness/supervisor/set' with `:sessionId' and `:on', works."
  (harness-supervisor-test-with-acp
    (let ((conn (harness-supervisor-test-connect))
          (sid (harness-supervisor-test-session)))
      (let ((session (harness-test-await
                      (harness-acp-request conn "_harness/supervisor/set" (list :sessionId sid :on :false)))))
        (should (equal sid (plist-get session :id)))
        (should (eq :false (plist-get (plist-get session :ext) :supervisor))))
      (should (eq :false (harness-supervisor-test-get sid)))
      (should (equal (list (list sid :false)) (harness-supervisor-test-events "supervisor/changed")))
      (let ((session (harness-test-await
                      (harness-acp-request conn "_harness/supervisor/set" (list :sessionId sid :on t)))))
        (should (eq t (plist-get (plist-get session :ext) :supervisor))))
      (should (harness-call 'supervisor/active-p sid))
      (should (equal (list (list sid :false) (list sid t)) (harness-supervisor-test-events "supervisor/changed")))
      ;; Reading it works over the same prefix, and the hints say what happened.
      (should (eq t (harness-test-await
                     (harness-acp-request conn "_harness/supervisor/get" (list :sessionId sid)))))
      (should (harness-test-await
               (harness-acp-request conn "_harness/supervisor/active-p" (list :sessionId sid))))
      (should (equal '("Supervisor mode off" "Supervisor mode on") (harness-supervisor-test-hints sid))))))

(ert-deftest harness-supervisor-acp-call-from-the-ui-all ()
  "The call the UI makes, `_harness/supervisor/set-all' with `:on' and `:filter', works."
  (harness-supervisor-test-with-acp
    (let* ((conn (harness-supervisor-test-connect))
           (one (harness-supervisor-test-session :ext '(:supervisor :false)))
           (two (harness-supervisor-test-session :ext '(:supervisor :false)))
           (sub (harness-supervisor-test-session :kind 'subagent :parent-id one)))
      (let ((changed (harness-test-await
                      (harness-acp-request conn "_harness/supervisor/set-all"
                                           (list :on t :filter (list :active t))))))
        (should (equal (sort (list one two) #'string<) (sort changed #'string<))))
      (should (eq t (harness-supervisor-test-get one)))
      (should (eq t (harness-supervisor-test-get two)))
      (should-not (harness-supervisor-test-get sub))
      (should (equal (sort (list (list one t) (list two t))
                           (lambda (a b) (string< (car a) (car b))))
                     (sort (harness-supervisor-test-events "supervisor/changed")
                           (lambda (a b) (string< (car a) (car b))))))
      ;; Off for one of them: the filter reaches exactly what it names.
      (should (equal (list one)
                     (harness-test-await
                      (harness-acp-request conn "_harness/supervisor/set-all"
                                           (list :on :false :filter (list :active t :except (list two)))))))
      (should (eq :false (harness-supervisor-test-get one)))
      (should (eq t (harness-supervisor-test-get two))))))

(ert-deftest harness-supervisor-acp-call-needs-its-arguments ()
  "A call without the session or without the switch is refused, and changes nothing."
  (harness-supervisor-test-with-acp
    (let ((conn (harness-supervisor-test-connect))
          (sid (harness-supervisor-test-session)))
      (should-error (harness-test-await (harness-acp-request conn "_harness/supervisor/set" (list :on :false))))
      (should-error (harness-test-await (harness-acp-request conn "_harness/supervisor/set" (list :sessionId sid))))
      (should-error (harness-test-await (harness-acp-request conn "_harness/supervisor/set"
                                                             (list :sessionId "nope" :on t))))
      (should (eq t (harness-supervisor-test-get sid)))
      (should-not (harness-supervisor-test-events "supervisor/changed")))))

;;;; Tasks

(defconst harness-supervisor-test-task-script
  '((:type text :delta "Working on it.") (:type done :stop-reason end-turn))
  "What the model answers a task: it works, and stops.")

(defmacro harness-supervisor-test-with-tasks (&rest body)
  "Run BODY with task mode and the supervisor; tasks finish at once, unreviewed."
  (declare (indent 0))
  `(let ((harness-acp--server-enabled nil)
         (harness-acp-token nil))
     (harness-supervisor-test-with-modules (tasks acp)
       (clrhash harness-tools)
       (clrhash harness-tasks--table)
       (clrhash harness-tasks--starting)
       (clrhash harness-tasks--naming)
       (harness-tasks--forget-stores)
       (setq harness-tasks--loaded t
             harness-tasks--dirty nil
             harness-tasks--naming-queue nil
             harness-acp--clients nil)
       (let ((harness-provider-demo-script-override harness-supervisor-test-task-script)
             (harness-naming-auto nil)
             (harness-tasks-max-running 3)
             (harness-tasks-require-verification nil)
             (harness-tasks-permission-mode 'auto)
             (harness-tasks-non-interactive t)
             (harness-tasks-model "demo:scripted"))
         (harness-add-filter 'permission/decide
                             (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
         (unwind-protect (progn ,@body)
           (dolist (c (copy-sequence harness-acp--clients))
             (harness-acp--drop-client c)))))))

(defun harness-supervisor-test-task (id)
  "Return task ID."
  (harness-call 'task/get id))

(defun harness-supervisor-test-task-session (id)
  "Return the id of the session of task ID."
  (plist-get (harness-supervisor-test-task id) :session))

(defun harness-supervisor-test-wait-task (id state)
  "Wait until task ID is in STATE."
  (harness-test-wait (lambda () (eq state (plist-get (harness-supervisor-test-task id) :state))) 30
                     (format "task %s to be %s" id state)))

(defun harness-supervisor-test-ext (sid)
  "Return the ext of session SID."
  (plist-get (harness-call 'session/get sid) :ext))

(ert-deftest harness-supervisor-work-tasks-take-the-tasks-setting ()
  "The session of a work task supervises as `harness-supervisor-tasks' says."
  (harness-supervisor-test-with-tasks
    (let* ((id (plist-get (harness-call 'task/submit default-directory "fix the parser") :id))
           (sid (harness-supervisor-test-task-session id)))
      (should (eq t (plist-get (harness-supervisor-test-ext sid) :supervisor)))
      (harness-supervisor-test-wait-task id 'done))
    (let ((harness-supervisor-tasks nil))
      (let* ((id (plist-get (harness-call 'task/submit default-directory "fix the lexer") :id))
             (sid (harness-supervisor-test-task-session id)))
        (should (eq :false (plist-get (harness-supervisor-test-ext sid) :supervisor)))
        (harness-supervisor-test-wait-task id 'done)))
    ;; The two settings are independent: sessions off, tasks on.
    (let ((harness-supervisor nil))
      (let* ((id (plist-get (harness-call 'task/submit default-directory "fix the linker") :id))
             (sid (harness-supervisor-test-task-session id)))
        (should (eq t (plist-get (harness-supervisor-test-ext sid) :supervisor)))
        (harness-supervisor-test-wait-task id 'done)))))

(ert-deftest harness-supervisor-a-task-that-does-not-supervise-keeps-its-thinking ()
  "A task session raised as a top-level session is put back when tasks work hands-on."
  (harness-supervisor-test-with-tasks
    (let ((harness-supervisor-thinking '((demo . "max")))
          (harness-supervisor-tasks nil))
      (let* ((id (plist-get (harness-call 'task/submit default-directory "fix the parser") :id))
             (sid (harness-supervisor-test-task-session id)))
        (should (eq :false (plist-get (harness-supervisor-test-ext sid) :supervisor)))
        (should (null (plist-get (harness-call 'session/get sid) :thinking)))
        (harness-supervisor-test-wait-task id 'done)))))

(ert-deftest harness-supervisor-write-ups-only-read-and-do-not-supervise ()
  "The session of a backlog write-up has no setting, until its task starts."
  (harness-supervisor-test-with-tasks
    (let* ((id (plist-get (harness-call 'task/submit default-directory "jot this down" '(:refine t)) :id))
           (sid (harness-supervisor-test-task-session id)))
      (harness-test-wait (lambda () (eq 'pending (plist-get (harness-supervisor-test-task id) :state))) 30
                         "the write-up to finish")
      (let ((ext (harness-supervisor-test-ext sid)))
        (should-not (plist-member ext :supervisor))
        (should (eq t (plist-get ext :supervisor-write-up))))
      (should-not (harness-call 'supervisor/active-p sid))
      ;; The task starts in the same session: now it works, and supervises.
      (harness-call 'task/start id)
      (let ((ext (harness-supervisor-test-ext sid)))
        (should (eq t (plist-get ext :supervisor)))
        (should-not (plist-member ext :supervisor-write-up)))
      (harness-supervisor-test-wait-task id 'done)
      (should (eq t (harness-supervisor-test-get sid))))))

(ert-deftest harness-supervisor-a-started-write-up-takes-the-tasks-setting ()
  "A written-up task works hands-on when `harness-supervisor-tasks' is off."
  (harness-supervisor-test-with-tasks
    (let* ((id (plist-get (harness-call 'task/submit default-directory "jot this down" '(:refine t)) :id))
           (sid (harness-supervisor-test-task-session id))
           (harness-supervisor-tasks nil))
      (harness-test-wait (lambda () (eq 'pending (plist-get (harness-supervisor-test-task id) :state))) 30
                         "the write-up to finish")
      (harness-call 'task/start id)
      (should (eq :false (harness-supervisor-test-get sid)))
      (should-not (plist-member (harness-supervisor-test-ext sid) :supervisor-write-up))
      (harness-supervisor-test-wait-task id 'done))))

(ert-deftest harness-supervisor-a-work-task-is-judged-from-its-start-message ()
  "A task session under `auto' is judged on the message that starts the work."
  (harness-supervisor-test-with-tasks
    (setq harness-supervisor-tasks 'auto
          harness-provider-demo-script-override #'harness-supervisor-test--answer
          harness-supervisor-test--script
          (list (harness-supervisor-test-judge-says "HANDS-ON" 0.05)
                '((:type wait :seconds 0.1) (:type text :delta "Working on it.")
                  (:type done :stop-reason end-turn))))
    (let* ((id (plist-get (harness-call 'task/submit default-directory "fix the parser") :id))
           (sid (harness-supervisor-test-task-session id))
           (judge (car (harness-supervisor-test-judge-requests))))
      (harness-supervisor-test-wait-task id 'done)
      ;; The judge read the work's start message, and the task works hands-on.
      (should judge)
      (should (string-match-p "fix the parser" (plist-get judge :text)))
      (should (eq :false (harness-supervisor-test-get sid)))
      (should-not (harness-supervisor-test-judge-mark sid))
      (should (member "judged hands-on (demo:scripted)"
                      (harness-supervisor-test-hints sid))))))

(ert-deftest harness-supervisor-a-write-up-is-never-judged ()
  "Writing a backlog task up carries no judge mark; the work, later, is judged."
  (harness-supervisor-test-with-tasks
    (setq harness-supervisor-tasks 'auto)
    (let* ((id (plist-get (harness-call 'task/submit default-directory "jot this down" '(:refine t)) :id))
           (sid (harness-supervisor-test-task-session id)))
      (harness-test-wait (lambda () (eq 'pending (plist-get (harness-supervisor-test-task id) :state))) 30
                         "the write-up to finish")
      (should-not (plist-member (harness-supervisor-test-ext sid) :supervisor))
      (should-not (harness-supervisor-test-judge-mark sid))
      (should-not (harness-supervisor-test-judge-requests))
      ;; The task starts in the same session, and the work is judged.
      (setq harness-provider-demo-script-override #'harness-supervisor-test--answer
            harness-supervisor-test--requests nil
            harness-supervisor-test--script
            (list (harness-supervisor-test-judge-says "HANDS-ON" 0.05)
                  '((:type wait :seconds 0.1) (:type text :delta "Working on it.")
                    (:type done :stop-reason end-turn))))
      (harness-call 'task/start id)
      (harness-supervisor-test-wait-task id 'done)
      (should (= 1 (length (harness-supervisor-test-judge-requests))))
      (should (eq :false (harness-supervisor-test-get sid))))))
(ert-deftest harness-supervisor-a-task-takes-the-setting-it-was-submitted-with ()
  "A task's own supervisor setting wins over `harness-supervisor-tasks'.
The board sends it with the task; a task without one follows the
default, as before."
  (harness-supervisor-test-with-tasks
    ;; Submitted hands-on while tasks supervise by default.
    (let* ((id (plist-get (harness-call 'task/submit default-directory "fix the parser"
                                        (list :supervisor :false))
                          :id))
           (sid (harness-supervisor-test-task-session id)))
      (should (eq :false (plist-get (harness-supervisor-test-ext sid) :supervisor)))
      (should (eq :false (plist-get (harness-supervisor-test-task id) :supervisor)))
      (harness-supervisor-test-wait-task id 'done))
    ;; Submitted supervising while tasks work hands-on by default.
    (let ((harness-supervisor-tasks nil))
      (let* ((id (plist-get (harness-call 'task/submit default-directory "fix the lexer"
                                          (list :supervisor t))
                            :id))
             (sid (harness-supervisor-test-task-session id)))
        (should (eq t (plist-get (harness-supervisor-test-ext sid) :supervisor)))
        (harness-supervisor-test-wait-task id 'done)))))

(ert-deftest harness-supervisor-task-settings-report-the-tasks-default ()
  "`task/settings' says what a new task's supervisor mode would be.
The board sets up the next task from it; without the module the setting
is not there at all (see `harness-tasks-supervisor-setting-without-the-module')."
  (harness-supervisor-test-with-tasks
    (should (eq t (plist-get (harness-call 'task/settings default-directory) :supervisor)))
    (let ((harness-supervisor-tasks nil))
      (should (eq :false (plist-get (harness-call 'task/settings default-directory) :supervisor))))))

(ert-deftest harness-supervisor-a-bulk-change-reaches-the-sessions ()
  "`task/set-all' with `:supervisor' changes the task and its session.
A task that has not started keeps the setting until it does."
  (harness-supervisor-test-with-tasks
    (let ((harness-tasks-max-running 0))
      (let ((id (plist-get (harness-call 'task/submit default-directory "wait for a slot") :id)))
        ;; No session yet: the setting waits on the task with it.
        (should (equal (list id) (harness-call 'task/set-all (list :supervisor :false)
                                               (list :ids (list id) :cwd default-directory))))
        (should (eq :false (plist-get (harness-supervisor-test-task id) :supervisor)))
        (harness-call 'task/start id)
        (let ((sid (harness-supervisor-test-task-session id)))
          (should (eq :false (plist-get (harness-supervisor-test-ext sid) :supervisor)))
          ;; A started task's session takes the change at once, as the
          ;; board's other bulk settings reach a running task's session.
          (should (equal (list id) (harness-call 'task/set-all (list :supervisor t)
                                                 (list :ids (list id) :cwd default-directory))))
          (should (eq t (plist-get (harness-supervisor-test-ext sid) :supervisor)))
          (should (member "Supervisor mode on" (harness-supervisor-test-hints sid)))
          (harness-supervisor-test-wait-task id 'done))))))

(ert-deftest harness-supervisor-a-write-up-keeps-its-setting-for-the-start ()
  "A bulk change leaves a write-up's session alone; the setting waits for the work.
A write-up only reads, so it never supervises (see
`harness-supervisor-write-ups-only-read-and-do-not-supervise')."
  (harness-supervisor-test-with-tasks
    (let* ((id (plist-get (harness-call 'task/submit default-directory "jot this down"
                                        (list :refine t :supervisor t))
                          :id))
           (sid (harness-supervisor-test-task-session id)))
      (harness-test-wait (lambda () (eq 'pending (plist-get (harness-supervisor-test-task id) :state))) 30
                         "the write-up to finish")
      (harness-call 'task/set-all (list :supervisor :false)
                    (list :columns '(pending needs-input) :ids (list id) :cwd default-directory))
      (let ((ext (harness-supervisor-test-ext sid)))
        (should-not (plist-member ext :supervisor))
        (should (eq t (plist-get ext :supervisor-write-up))))
      (should (eq :false (plist-get (harness-supervisor-test-task id) :supervisor)))
      ;; The task starts in the same session: now it works, hands-on.
      (harness-call 'task/start id)
      (should (eq :false (harness-supervisor-test-get sid)))
      (harness-supervisor-test-wait-task id 'done))))

(ert-deftest harness-supervisor-only-a-new-session-is-set-by-its-task ()
  "The task events never override a switch the user flipped, or a session with a past."
  (harness-supervisor-test-with-tasks
    (let* ((id (plist-get (harness-call 'task/submit default-directory "fix the parser") :id))
           (task (harness-supervisor-test-task id))
           (sid (plist-get task :session)))
      (harness-supervisor-test-wait-task id 'done)
      ;; The user turns it off; the next task event leaves it so.
      (harness-call 'supervisor/set sid :false)
      (harness-supervisor--on-task-changed task)
      (harness-call 'supervisor/set sid :false)
      (should (eq :false (harness-supervisor-test-get sid))))
    ;; A session that already has messages is left alone, and so is one a task adopts.
    (let* ((sid (harness-supervisor-test-session)))
      (harness-test-await (harness-call 'agent/prompt sid "hello"))
      (harness-call 'supervisor/set sid :false)
      (let ((task (harness-call 'task/adopt sid)))
        (should (plist-get task :adopted))
        (harness-supervisor--on-task-changed task)
        (should (eq :false (harness-supervisor-test-get sid)))))
    (let* ((sid (harness-supervisor-test-session)))
      (harness-call 'supervisor/set sid :false)
      (harness-supervisor--on-task-changed (list :id "t-x" :session sid :state 'active))
      (should (eq :false (harness-supervisor-test-get sid)))
      ;; Not once it has a message, even for a task that is new to the supervisor.
      (harness-call 'session/hint sid "hello")
      (harness-call 'supervisor/set sid t)
      (harness-supervisor--on-task-changed (list :id "t-y" :session sid :state 'active))
      (should (eq t (harness-supervisor-test-get sid))))))

(ert-deftest harness-supervisor-set-all-leaves-a-completed-tasks-session-alone ()
  "With the everything filter, a done task's session is left alone by
`supervisor/set-all', even though it is still active and would be
selected by `:active' alone; the active sessions change as ever."
  (harness-supervisor-test-with-tasks
    (let* ((done-task (plist-get (harness-call 'task/submit default-directory "finish this") :id))
           (done-sid (harness-supervisor-test-task-session done-task))
           (open (harness-supervisor-test-session)))
      (harness-supervisor-test-wait-task done-task 'done)
      (should (eq 'done (plist-get (harness-supervisor-test-task done-task) :column)))
      ;; The session of the finished task is still active, and supervises.
      (should-not (eq 'inactive (plist-get (harness-call 'session/get done-sid) :status)))
      (should (eq t (harness-supervisor-test-get done-sid)))
      (let ((changed (harness-call 'supervisor/set-all :false (list :active t :tasks t))))
        (should (member open changed))
        (should-not (member done-sid changed)))
      (should (eq t (harness-supervisor-test-get done-sid)))
      (should (eq :false (harness-supervisor-test-get open)))
      ;; Wanted on again: the finished task's session stays hands-on.
      (harness-call 'supervisor/set done-sid :false)
      (harness-call 'supervisor/set-all t (list :active t :tasks t))
      (should (eq :false (harness-supervisor-test-get done-sid)))
      (should (eq t (harness-supervisor-test-get open))))))

;;;; The allowlist

(defconst harness-supervisor-test-allowed
  '("read_file" "grep" "glob" "list_dir" "file_info" "session_info" "session_history"
    "session_list" "session_read" "session_search" "session_wait" "task_list" "task_wait"
    "skill_search" "skill_load" "notification_providers" "emacs_buffers" "emacs_windows"
    "emacs_buffer" "emacs_describe" "emacs_find_definition" "emacs_messages" "emacs_open"
    "request_directory_access"
    "web_fetch" "web_search"
    "ask_user" "todo_write" "hand_in" "notify" "session_control" "session_send" "session_move"
    "set_non_interactive" "task_control" "task_submit"
    "no_plan_needed" "submit_plan" "retry_step")
  "The tools a supervising session is offered, bash apart: the contract.")

(defconst harness-supervisor-test-dropped
  '("edit_file" "write_file" "emacs_insert" "emacs_save_buffer" "emacs_trace" "elisp"
    "emacs_eval" "ssh" "open_harness" "merge_done" "plan" "spawn_agent")
  "The tools a supervising session is not offered, bash apart.")

(defconst harness-supervisor-test-tool-modules
  '(tools-fs tools-shell tools-ssh tools-emacs tools-emacs-eval tools-web tools-sessions
    tools-notify tools-handin tools-dev skills merge perms tasks)
  "The modules that define the tools of the harness.")

(defun harness-supervisor-test-sorted (names)
  "Return NAMES sorted."
  (sort (copy-sequence names) #'string<))

(ert-deftest harness-supervisor-a-supervisor-is-offered-the-allowlist-only ()
  "A supervising session gets reading, the web and coordination, and no way to write."
  (harness-supervisor-test-with-modules (tools-fs tools-shell tools-ssh tools-emacs tools-emacs-eval
                                         tools-web tools-sessions tools-notify tools-handin tools-dev
                                         skills merge perms tasks)
    (harness-supervisor-test-confined nil)
    (let ((sid (harness-supervisor-test-session))
          (catalogue (mapcar (lambda (spec) (plist-get spec :name)) (harness-call 'tools/list))))
      ;; Every tool the contract names is there to be offered, and every
      ;; one it drops is a tool the harness has.
      (dolist (name (append harness-supervisor-test-allowed harness-supervisor-test-dropped '("bash")))
        (should (member name catalogue)))
      ;; Not a task's session: hand_in is not offered to it at all.
      (should (equal (harness-supervisor-test-sorted (remove "hand_in" harness-supervisor-test-allowed))
                     (harness-supervisor-test-sorted (harness-supervisor-test-tool-names sid))))
      ;; A tool added tomorrow is dropped.
      (harness-define-tool "tomorrow_tool" :label "Tomorrow" :description "x" :kind 'read
                           :handler (lambda (&rest _) "x"))
      (should-not (member "tomorrow_tool" (harness-supervisor-test-tool-names sid)))
      ;; A task's session gets hand_in.
      (let ((task-session (harness-supervisor-test-session)))
        (harness-call 'task/adopt task-session)
        (should (member "hand_in" (harness-supervisor-test-tool-names task-session)))
        (should (equal (harness-supervisor-test-sorted harness-supervisor-test-allowed)
                       (harness-supervisor-test-sorted (harness-supervisor-test-tool-names task-session)))))
      ;; The catalogue keeps everything.
      (should (member "write_file" (mapcar (lambda (spec) (plist-get spec :name)) (harness-call 'tools/list))))
      (should (member "tomorrow_tool" (mapcar (lambda (spec) (plist-get spec :name)) (harness-call 'tools/list)))))))

(ert-deftest harness-supervisor-others-keep-their-tools-but-lose-the-supervisors ()
  "A session that is hands-on, or not governed, keeps every tool but the supervisor's own."
  (harness-supervisor-test-with-modules (tools-fs tools-shell tools-ssh tools-emacs tools-web tools-notify)
    (harness-supervisor-test-confined nil)
    (let* ((everything (mapcar (lambda (spec) (plist-get spec :name)) (harness-call 'tools/list)))
           (hands-on (harness-supervisor-test-session :ext '(:supervisor :false)))
           (ungoverned (harness-supervisor-test-session :kind 'subagent)))
      (should (member "no_plan_needed" everything))
      (should (member "submit_plan" everything))
      (should (member "retry_step" everything))
      (dolist (sid (list hands-on ungoverned))
        (should (equal (harness-supervisor-test-sorted
                        (cl-set-difference everything '("no_plan_needed" "submit_plan" "retry_step")
                                           :test #'equal))
                       (harness-supervisor-test-sorted (harness-supervisor-test-tool-names sid))))
        (should (member "write_file" (harness-supervisor-test-tool-names sid)))
        (should (member "bash" (harness-supervisor-test-tool-names sid)))))))

(ert-deftest harness-supervisor-the-supervisors-own-tools-are-named-in-one-place ()
  "The tools the plan engine adds to `harness-supervisor-tools' are offered to supervisors only."
  (harness-supervisor-test-with-modules (tools-fs)
    (dolist (name '("submit_plan" "retry_step"))
      (harness-define-tool name :label name :description "x" :kind 'meta :handler (lambda (&rest _) "x")))
    (let ((supervising (harness-supervisor-test-session))
          (hands-on (harness-supervisor-test-session :ext '(:supervisor :false))))
      (should (member "submit_plan" harness-supervisor-tools))
      (should (member "retry_step" harness-supervisor-tools))
      (dolist (name '("submit_plan" "retry_step" "no_plan_needed"))
        (should (member name (harness-supervisor-test-tool-names supervising)))
        (should-not (member name (harness-supervisor-test-tool-names hands-on))))
      ;; A tool another module adds there is offered the same way.
      (let ((harness-supervisor-tools (cons "extra_tool" harness-supervisor-tools)))
        (harness-define-tool "extra_tool" :label "Extra" :description "x" :kind 'meta
                             :handler (lambda (&rest _) "x"))
        (should (member "extra_tool" (harness-supervisor-test-tool-names supervising)))
        (should-not (member "extra_tool" (harness-supervisor-test-tool-names hands-on)))))))

(ert-deftest harness-supervisor-bash-is-offered-only-where-the-sandbox-confines-it ()
  "A supervising session has bash when `sandbox/confined-p' says its directory is confined."
  (harness-supervisor-test-with-modules (tools-fs tools-shell)
    (let ((sid (harness-supervisor-test-session))
          (hands-on (harness-supervisor-test-session :ext '(:supervisor :false)))
          (asked nil))
      ;; No such method at all: bash cannot be confined.
      (should-not (harness-method-exists-p 'sandbox/confined-p))
      (should-not (member "bash" (harness-supervisor-test-tool-names sid)))
      (should (member "bash" (harness-supervisor-test-tool-names hands-on)))
      (harness-register-method 'sandbox/confined-p (lambda (cwd) (push cwd asked) t))
      (should (member "bash" (harness-supervisor-test-tool-names sid)))
      (should (equal (plist-get (harness-call 'session/get sid) :cwd) (car asked)))
      (harness-supervisor-test-confined nil)
      (should-not (member "bash" (harness-supervisor-test-tool-names sid)))
      (should (member "bash" (harness-supervisor-test-tool-names hands-on)))
      ;; A sandbox that fails is no sandbox.
      (harness-supervisor-test-confined 'error)
      (should-not (member "bash" (harness-supervisor-test-tool-names sid)))
      (should (member "read_file" (harness-supervisor-test-tool-names sid))))))

(ert-deftest harness-supervisor-bash-on-another-host-is-not-confined ()
  "The sandbox is asked about the directory on the session's host, which it cannot confine."
  (harness-supervisor-test-with-modules (tools-fs tools-shell)
    (let ((asked nil)
          (sid (harness-supervisor-test-session :host "/ssh:me@box:")))
      (harness-register-method 'sandbox/confined-p
                               (lambda (cwd) (push cwd asked) (not (file-remote-p cwd))))
      (should-not (member "bash" (harness-supervisor-test-tool-names sid)))
      (should (file-remote-p (car asked)))
      (should (string-prefix-p "/ssh:me@box:" (car asked))))))

(ert-deftest harness-supervisor-switching-the-mode-changes-the-next-tool-list ()
  "The tool list follows the switch: write tools go on the next step, and come back."
  (harness-supervisor-test-with-modules (tools-fs)
    (let ((sid (harness-supervisor-test-session)))
      (should-not (member "write_file" (harness-supervisor-test-tool-names sid)))
      (harness-call 'supervisor/set sid :false)
      (should (member "write_file" (harness-supervisor-test-tool-names sid)))
      (should-not (member "no_plan_needed" (harness-supervisor-test-tool-names sid)))
      (harness-call 'supervisor/set sid t)
      (should-not (member "write_file" (harness-supervisor-test-tool-names sid)))
      (should (member "no_plan_needed" (harness-supervisor-test-tool-names sid))))))

;;;; The permission stage

(ert-deftest harness-supervisor-denies-a-call-outside-the-allowlist-for-good ()
  "A supervising session's call to anything else is denied, whatever stage follows."
  (harness-supervisor-test-with
    (harness-supervisor-test-allow-all)
    (let ((sid (harness-supervisor-test-session)))
      (dolist (tool '("write_file" "edit_file" "emacs_insert" "emacs_save_buffer" "emacs_trace" "elisp"
                      "emacs_eval" "ssh" "open_harness" "merge_done" "plan" "spawn_agent" "made_up"))
        (ert-info (tool)
          (let ((decision (harness-supervisor-test-decide sid tool)))
            (should (eq 'deny (plist-get decision :behavior)))
            (should (plist-get decision :final))
            (should (string-match-p (regexp-quote tool) (plist-get decision :reason)))
            (should (string-match-p "submit_plan" (plist-get decision :hint)))
            (should (string-match-p "switch supervisor mode off" (plist-get decision :hint)))
            (should (string-match-p "header" (plist-get decision :hint)))))))))

(ert-deftest harness-supervisor-lets-the-allowed-calls-through-unchanged ()
  "The stage passes the allowed calls on with the decision it was given."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session)))
      (dolist (tool (append '("read_file" "web_fetch" "task_submit" "session_send" "ask_user"
                              "request_directory_access" "submit_plan")
                            '("hand_in" "session_move")))
        (ert-info (tool)
          (should (equal '(:behavior ask) (harness-supervisor-test-decide sid tool 'read)))))
      ;; Its own tool only records a decision, so asking the user about it is no use.
      (let ((decision (harness-supervisor-test-decide sid "no_plan_needed" 'meta)))
        (should (eq 'allow (plist-get decision :behavior)))
        (should-not (plist-get decision :final))))))

(ert-deftest harness-supervisor-leaves-other-sessions-alone ()
  "A hands-on session, or one not governed, is decided as it was."
  (harness-supervisor-test-with
    (let ((sessions (list (harness-supervisor-test-session :ext '(:supervisor :false))
                          (harness-supervisor-test-session :kind 'subagent))))
      ;; Undecided stays undecided: the stage adds nothing.
      (dolist (sid sessions)
        (dolist (tool '("write_file" "elisp" "spawn_agent" "bash" "no_plan_needed"))
          (ert-info (tool)
            (should (equal '(:behavior ask) (harness-supervisor-test-decide sid tool))))))
      ;; What a later stage allows stays allowed.
      (harness-supervisor-test-allow-all)
      (dolist (sid sessions)
        (dolist (tool '("write_file" "elisp" "spawn_agent" "bash" "no_plan_needed"))
          (ert-info (tool)
            (should (eq 'allow (plist-get (harness-supervisor-test-decide sid tool) :behavior)))))))))

(ert-deftest harness-supervisor-stage-runs-before-the-jail-the-mode-and-the-judge ()
  "The stage is at 8: after the move and sandbox guards, before the jail at 10."
  (harness-supervisor-test-with
    (let ((priorities (mapcar #'car (gethash 'permission/decide harness--filters))))
      (should (= 8 (car (rassq #'harness-supervisor--gate (gethash 'permission/decide harness--filters)))))
      (should (equal priorities (sort (copy-sequence priorities) #'<))))
    (should (= 90 (car (rassq #'harness-supervisor--tools (gethash 'agent/tools harness--filters)))))
    (should (> (car (rassq #'harness-supervisor--system-prompt (gethash 'agent/system-prompt harness--filters)))
               60))))

;; The approval of a plan: the user's in ask mode, nobody's otherwise.

(ert-deftest harness-supervisor-approval-stage-runs-after-the-mode-and-before-the-judge ()
  "The approval stage is at 28: after the mode and its rules (20) and the write-up gate (25), before the judge (30)."
  (harness-supervisor-test-with-modules (perms tasks)
    (let* ((filters (gethash 'permission/decide harness--filters))
           (priority (lambda (fn) (car (rassq fn filters))))
           (order (mapcar #'cdr filters)))
      (should (= 28 (funcall priority #'harness-supervisor--approval)))
      ;; The neighbours are the stages named in the Commentary of the permission module.
      (should (= 20 (funcall priority #'harness-perms--mode)))
      (should (= 25 (funcall priority #'harness-tasks--write-up-gate)))
      (should (= 30 (funcall priority #'harness-perms--auto)))
      ;; So the order of the chain is the gate, the jail, the mode, the write-up gate, the approval, the judge.
      (should (equal '(harness-supervisor--gate harness-perms--jail harness-perms--mode
                       harness-tasks--write-up-gate harness-supervisor--approval harness-perms--auto
                       harness-perms--non-interactive harness-perms--ask)
                     (seq-filter (lambda (fn) (memq fn '(harness-supervisor--gate harness-perms--jail
                                                         harness-perms--mode harness-tasks--write-up-gate
                                                         harness-supervisor--approval harness-perms--auto
                                                         harness-perms--non-interactive harness-perms--ask)))
                                 order)))
      ;; Once only: the module hooks in again after a reload.
      (harness-supervisor--init)
      (should (= 1 (cl-count #'harness-supervisor--approval (gethash 'permission/decide harness--filters)
                             :key #'cdr))))))

(ert-deftest harness-supervisor-approval-leaves-a-plan-to-the-user-in-ask-mode-and-allows-it-otherwise ()
  "Only ask mode with the user there asks: any other mode, and a user who is away, allow a plan."
  (harness-supervisor-test-with-modules (perms)
    (dolist (mode '(ask accept-edits auto yolo))
      (dolist (away '(nil t))
        (let ((sid (harness-supervisor-test-session :permission-mode mode
                                                    :non-interactive (if away t :false))))
          (dolist (tool '("submit_plan" "retry_step"))
            (ert-info ((format "%s in %s mode, the user %s" tool mode (if away "away" "there")))
              (let ((decision (harness-supervisor-test-approve sid tool)))
                (if (and (eq mode 'ask) (not away))
                    (should (equal '(:behavior ask) decision))
                  (should (eq 'allow (plist-get decision :behavior)))
                  (should-not (plist-get decision :final))
                  (should (string-match-p "approved by the user in ask mode only" (plist-get decision :reason)))
                  (should (string-match-p "no judge rules on plans" (plist-get decision :reason)))))))
          ;; It only records a decision: nobody approves that, in any mode.
          (ert-info ((format "no_plan_needed in %s mode, the user %s" mode (if away "away" "there")))
            (let ((decision (harness-supervisor-test-approve sid "no_plan_needed")))
              (should (eq 'allow (plist-get decision :behavior)))
              (should-not (plist-get decision :final))
              (should (string-match-p "only records a decision" (plist-get decision :reason))))))))))

(ert-deftest harness-supervisor-approval-touches-only-what-would-ask ()
  "A decision made before it stands, whatever the mode: a refusal, a rule, an allowance."
  (harness-supervisor-test-with-modules (perms)
    (let ((sid (harness-supervisor-test-session :permission-mode 'auto)))
      (dolist (decision (list '(:behavior deny :final t :reason "supervisor mode: no")
                              '(:behavior deny :reason "a standing rule denies it")
                              '(:behavior allow :reason "a standing rule allows it")))
        (dolist (tool '("submit_plan" "retry_step" "no_plan_needed"))
          (ert-info ((format "%s after %S" tool decision))
            (should (equal decision (harness-supervisor-test-approve sid tool decision)))))))))

(ert-deftest harness-supervisor-approval-decides-only-the-supervisors-own-tools-of-a-supervising-session ()
  "Other tools stay as they were, and so do the calls of a session that does not supervise."
  (harness-supervisor-test-with-modules (perms)
    (let ((supervising (harness-supervisor-test-session :permission-mode 'auto))
          (others (list (harness-supervisor-test-session :permission-mode 'auto :ext '(:supervisor :false))
                        (harness-supervisor-test-session :permission-mode 'auto :kind 'subagent))))
      (dolist (tool '("hand_in" "task_submit" "session_send" "read_file" "ask_user" "made_up"))
        (ert-info (tool)
          (should (equal '(:behavior ask) (harness-supervisor-test-approve supervising tool)))))
      (dolist (sid others)
        (dolist (tool '("submit_plan" "retry_step" "no_plan_needed"))
          (ert-info (tool)
            (should (equal '(:behavior ask) (harness-supervisor-test-approve sid tool)))))))))

(ert-deftest harness-supervisor-approval-without-the-permission-module-leaves-a-plan-as-it-is ()
  "The mode is not known without it: a plan is left to the chain, and only the decision tool is allowed."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session :permission-mode 'auto)))
      (cl-letf (((symbol-function 'harness-perms--mode-of) nil)
                ((symbol-function 'harness-perms--non-interactive-p) nil))
        (should-not (fboundp 'harness-perms--mode-of))
        (dolist (tool '("submit_plan" "retry_step"))
          (should (equal '(:behavior ask) (harness-supervisor-test-approve sid tool))))
        (should (eq 'allow (plist-get (harness-supervisor-test-approve sid "no_plan_needed") :behavior)))))))

(ert-deftest harness-supervisor-approval-that-fails-passes-the-decision-on ()
  "A stage that signals is skipped, and refusing is the gate's work: the decision goes on as it was."
  (harness-supervisor-test-with-modules (perms)
    (let ((sid (harness-supervisor-test-session :permission-mode 'auto)))
      (cl-letf (((symbol-function 'harness-perms--mode-of) (lambda (_session) (error "Broken"))))
        (dolist (tool '("submit_plan" "retry_step"))
          (should (equal '(:behavior ask) (harness-supervisor-test-approve sid tool)))
          (should (equal '(:behavior deny :reason "no")
                         (harness-supervisor-test-approve sid tool '(:behavior deny :reason "no")))))
        ;; The decision tool needs no mode.
        (should (eq 'allow (plist-get (harness-supervisor-test-approve sid "no_plan_needed") :behavior)))))))

(ert-deftest harness-supervisor-the-gate-only-refuses ()
  "The gate at 8 allows nothing: what a later stage decides about a call it lets by is that stage's."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session)))
      (dolist (tool '("no_plan_needed" "submit_plan" "retry_step" "read_file"))
        (ert-info (tool)
          (let (result)
            (harness-supervisor--gate '(:behavior ask) (lambda (d) (setq result d))
                                      (list :session (harness-call 'session/get sid) :tool tool
                                            :input nil :kind 'meta :call-id "c1"))
            (should (equal '(:behavior ask) result))))))))

(ert-deftest harness-supervisor-bash-is-denied-where-the-sandbox-cannot-confine-it ()
  "A call to bash is denied when `sandbox/confined-p' says no, fails or is not there."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session))
          (seen nil))
      (harness-add-filter 'permission/decide
                          (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
      (dolist (stub (list nil nil 'error))
        (if stub (harness-supervisor-test-confined stub) (remhash 'sandbox/confined-p harness--methods))
        (let ((decision (harness-supervisor-test-decide sid "bash" 'exec)))
          (should (eq 'deny (plist-get decision :behavior)))
          (should (plist-get decision :final))
          (should (string-match-p "sandbox" (plist-get decision :reason)))
          (should (string-match-p "submit_plan" (plist-get decision :hint)))))
      (harness-supervisor-test-confined nil)
      (should (eq 'deny (plist-get (harness-supervisor-test-decide sid "bash" 'exec) :behavior)))
      ;; Confined: bash goes through, to be made read-only.  The directory
      ;; asked about is the one the command runs in.
      (harness-register-method 'sandbox/confined-p (lambda (cwd) (push cwd seen) t))
      (should (eq 'allow (plist-get (harness-supervisor-test-decide sid "bash" 'exec (list "/tmp/elsewhere/"))
                                    :behavior)))
      (should (equal '("/tmp/elsewhere/") seen)))))

(ert-deftest harness-supervisor-a-call-it-cannot-check-is-denied ()
  "When the stage fails it denies: a stage that signalled would be skipped, and the call allowed."
  (harness-supervisor-test-with
    (harness-supervisor-test-allow-all)
    (let ((sid (harness-supervisor-test-session))
          (hands-on (harness-supervisor-test-session :ext '(:supervisor :false))))
      (cl-letf (((symbol-function 'harness-supervisor--allowed-tools) (lambda () (error "Broken"))))
        (let ((decision (harness-supervisor-test-decide sid "read_file" 'read)))
          (should (eq 'deny (plist-get decision :behavior)))
          (should (plist-get decision :final)))
        ;; A session that does not supervise never meets the failure.
        (should (eq 'allow (plist-get (harness-supervisor-test-decide hands-on "read_file" 'read) :behavior)))))))

(ert-deftest harness-supervisor-writes-are-denied-through-the-whole-tool-call ()
  "A supervising session's write_file is refused with the reason, and writes nothing."
  (harness-supervisor-test-with-modules (tools-fs)
    (harness-supervisor-test-allow-all)
    (let* ((dir (harness-test-temp-dir))
           (file (expand-file-name "out.txt" dir))
           (sid (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted") :id)))
      (let ((result (harness-supervisor-test-run sid "write_file" (list :path file :content "hello"))))
        (should (plist-get result :is-error))
        (should (string-match-p "^Denied: supervisor mode: .*write_file" (plist-get result :content)))
        (should (string-match-p "submit_plan" (plist-get result :content)))
        (should-not (file-exists-p file)))
      ;; Reading still works.
      (with-temp-file file (insert "hello\n"))
      (should-not (plist-get (harness-supervisor-test-run sid "read_file" (list :path file)) :is-error))
      ;; The user turns the mode off: the next call writes.
      (harness-call 'supervisor/set sid :false)
      (delete-file file)
      (should-not (plist-get (harness-supervisor-test-run sid "write_file" (list :path file :content "hello"))
                             :is-error))
      (should (file-exists-p file))
      ;; And back on: the next call after the switch is denied, with no new tool list.
      (harness-call 'supervisor/set sid t)
      (delete-file file)
      (should (plist-get (harness-supervisor-test-run sid "write_file" (list :path file :content "hello"))
                         :is-error))
      (should-not (file-exists-p file)))))

;;;; Bash

(ert-deftest harness-supervisor-sandbox-options-make-bash-read-only-and-offline ()
  "A supervising session's commands run with every directory read-only and no network."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session))
          (hands-on (harness-supervisor-test-session :ext '(:supervisor :false))))
      (should (equal '(:read-only t :network nil) (harness-run-filter 'tools/sandbox-options nil sid)))
      (should (plist-get (harness-run-filter 'tools/sandbox-options nil sid) :read-only))
      (should (plist-member (harness-run-filter 'tools/sandbox-options nil sid) :network))
      (should-not (plist-get (harness-run-filter 'tools/sandbox-options nil sid) :network))
      ;; The options others asked for stay, and ours cannot be undone before us.
      (harness-add-filter 'tools/sandbox-options
                          (lambda (options _id)
                            (plist-put (plist-put (copy-sequence options) :writable '("/x"))
                                       :network t))
                          10)
      (let ((options (harness-run-filter 'tools/sandbox-options nil sid)))
        (should (equal '("/x") (plist-get options :writable)))
        (should (plist-get options :read-only))
        (should-not (plist-get options :network)))
      ;; Hands-on: only what the others asked for.
      (should (equal '(:writable ("/x") :network t)
                     (harness-run-filter 'tools/sandbox-options nil hands-on))))))

(ert-deftest harness-supervisor-sandbox-options-fail-closed ()
  "When the stage cannot tell, it answers read-only: a skipped stage would leave bash writable."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session)))
      ;; A session nobody knows.
      (should (equal '(:read-only t :network nil)
                     (harness-run-filter 'tools/sandbox-options nil "no-such-session")))
      ;; A failure in the check.
      (cl-letf (((symbol-function 'harness-supervisor--active-id-p) (lambda (_id) (error "Broken"))))
        (let ((options (harness-run-filter 'tools/sandbox-options nil sid)))
          (should (plist-get options :read-only))
          (should-not (plist-get options :network))
          (should (plist-member options :network))))
      ;; Options from a handler before it that are no plist at all.
      (harness-add-filter 'tools/sandbox-options (lambda (_options _id) 5) 10)
      (cl-letf (((symbol-function 'harness-supervisor--active-id-p) (lambda (_id) (error "Broken"))))
        (should (equal '(:read-only t :network nil) (harness-run-filter 'tools/sandbox-options nil sid)))))))

(ert-deftest harness-supervisor-bash-reaches-the-sandbox-read-only ()
  "The options reach `sandbox/wrap' with nothing writable; hands-on, the directories are writable."
  (harness-supervisor-test-with-modules (tools-shell)
    (harness-supervisor-test-allow-all)
    (harness-supervisor-test-confined t)
    (let ((wrapped nil)
          (sid (harness-supervisor-test-session))
          (hands-on (harness-supervisor-test-session :ext '(:supervisor :false))))
      (harness-register-method 'sandbox/wrap
                               (lambda (_cwd command &rest options) (push options wrapped) command))
      (should-not (plist-get (harness-supervisor-test-run sid "bash" '(:command "true")) :is-error))
      (let ((options (car wrapped)))
        (should (plist-get options :read-only))
        (should (plist-member options :network))
        (should-not (plist-get options :network))
        (should-not (plist-get options :writable))
        (should (plist-get options :readable)))
      (should-not (plist-get (harness-supervisor-test-run hands-on "bash" '(:command "true")) :is-error))
      (let ((options (car wrapped)))
        (should-not (plist-get options :read-only))
        (should (plist-get options :writable))))))

(ert-deftest harness-supervisor-bash-refuses-to-run-without-a-sandbox ()
  "Read-only bash fails closed: with no sandbox to run it in, the command does not run."
  (harness-supervisor-test-with-modules (tools-shell)
    (harness-supervisor-test-allow-all)
    ;; The permission stage believes in a sandbox the shell tool cannot find.
    (harness-supervisor-test-confined t)
    (should-not (harness-method-exists-p 'sandbox/wrap))
    (let* ((dir (harness-test-temp-dir))
           (file (expand-file-name "made.txt" dir))
           (sid (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted") :id))
           (result (harness-supervisor-test-run sid "bash" (list :command (format "touch %s" file)))))
      (should (plist-get result :is-error))
      (should (string-match-p "cannot run unconfined" (plist-get result :content)))
      (should-not (file-exists-p file)))))

(ert-deftest harness-supervisor-bash-under-bwrap-cannot-write ()
  "Under the real sandbox a supervising session's command can look but not touch."
  (skip-unless (executable-find "bwrap"))
  (harness-supervisor-test-with-modules (tools-shell sandbox)
    (harness-supervisor-test-allow-all)
    (harness-sandbox-detect)
    (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
    (let* ((dir (harness-test-temp-dir))
           (probe (harness-await (harness-run-command (harness-call 'sandbox/wrap dir '("true"))
                                                      :cwd dir :timeout 20))))
      (unless (eql 0 (plist-get probe :exit))
        (ert-skip (format "bwrap cannot start here: %s" (string-trim (plist-get probe :stderr)))))
      (with-temp-file (expand-file-name "seen.txt" dir) (insert "visible\n"))
      (let* ((sid (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted") :id))
             (hands-on (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted"
                                                :ext '(:supervisor :false))
                                  :id))
             (look (harness-supervisor-test-run sid "bash" '(:command "cat seen.txt")))
             (touch (harness-supervisor-test-run sid "bash" '(:command "touch made.txt")))
             (own (harness-supervisor-test-run hands-on "bash" '(:command "touch own.txt"))))
        (should (equal "visible\nexit 0" (plist-get look :content)))
        (should (plist-get touch :is-error))
        (should-not (file-exists-p (expand-file-name "made.txt" dir)))
        (should-not (plist-get own :is-error))
        (should (file-exists-p (expand-file-name "own.txt" dir)))))))

;;;; The turn must end on a decision

(ert-deftest harness-supervisor-a-turn-without-a-decision-is-sent-back ()
  "A model that stops with no decision is reminded; once it decides, it can stop."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session)))
      (setq harness-supervisor-test--script
            (list harness-supervisor-test-stops
                  (harness-supervisor-test-calls "no_plan_needed" '(:reason "answered a question"))
                  '((:type text :delta "Final reply.") (:type done :stop-reason end-turn))))
      (should (eq 'end-turn (harness-supervisor-test-prompt sid "What does foo do?")))
      (let ((requests (reverse harness-supervisor-test--requests)))
        (should (= 3 (length requests)))
        (should (equal "What does foo do?" (plist-get (nth 0 requests) :text)))
        ;; The second request is the reminder, which names the two ways to decide.
        (should (string-match-p "decision" (plist-get (nth 1 requests) :text)))
        (should (string-match-p "submit_plan" (plist-get (nth 1 requests) :text)))
        (should (string-match-p "no_plan_needed" (plist-get (nth 1 requests) :text))))
      ;; It is the harness's own message, steering the turn, and says so.
      (let ((reminder (car (cl-remove-if-not
                            (lambda (n) (equal "supervisor" (plist-get (harness-node-sender n) :source)))
                            (harness-supervisor-test-nodes sid 'user)))))
        (should (equal (harness-sender-system "supervisor") (harness-node-sender reminder)))
        (should (plist-get (plist-get reminder :meta) :steering)))
      (should (= 1 (length (harness-supervisor-test-reminders sid))))
      ;; The tool does not end the turn: the model still wrote its reply.
      (should (equal "Final reply."
                     (plist-get (car (last (harness-supervisor-test-nodes sid 'assistant))) :content)))
      (should (equal '("No plan needed: answered a question") (harness-supervisor-test-hints sid))))))

(ert-deftest harness-supervisor-a-turn-is-sent-back-twice-at-most ()
  "After two reminders the turn ends, and a hint says it ended without a decision."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session)))
      (setq harness-supervisor-test--script (list harness-supervisor-test-stops harness-supervisor-test-stops
                                                  harness-supervisor-test-stops harness-supervisor-test-stops))
      (should (eq 'end-turn (harness-supervisor-test-prompt sid "What does foo do?")))
      (should (= 3 (length harness-supervisor-test--requests)))
      (should (= 2 (length (harness-supervisor-test-reminders sid))))
      (should (= 1 (length (harness-supervisor-test-hints sid))))
      (should (string-match-p "without a decision" (car (harness-supervisor-test-hints sid))))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))
      ;; The next turn starts afresh: the reminders count per turn.
      (setq harness-supervisor-test--script (list harness-supervisor-test-stops harness-supervisor-test-stops
                                                  harness-supervisor-test-stops))
      (should (eq 'end-turn (harness-supervisor-test-prompt sid "And bar?")))
      (should (= 4 (length (harness-supervisor-test-reminders sid))))
      (should (= 2 (length (harness-supervisor-test-hints sid)))))))

(ert-deftest harness-supervisor-a-decision-counts-whenever-it-is-made ()
  "A turn that decided before it stopped is not sent back, and neither is one that decides twice."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session)))
      (setq harness-supervisor-test--script
            (list (harness-supervisor-test-calls "no_plan_needed" '(:reason "nothing to do"))
                  '((:type text :delta "Nothing to do.") (:type done :stop-reason end-turn))))
      (should (eq 'end-turn (harness-supervisor-test-prompt sid "Anything?")))
      (should (= 2 (length harness-supervisor-test--requests)))
      (should-not (harness-supervisor-test-reminders sid))
      (should-not (cl-some (lambda (h) (string-match-p "without a decision" h))
                           (harness-supervisor-test-hints sid))))))

(ert-deftest harness-supervisor-every-decision-tool-lets-the-turn-stop ()
  "Calling any of the decision tools is a decision."
  (harness-supervisor-test-with
    (harness-supervisor-test-allow-all)
    (let ((sid (harness-supervisor-test-session)))
      (should (equal '("no_plan_needed" "submit_plan" "retry_step" "hand_in" "task_submit" "task_control"
                       "session_send" "session_control")
                     harness-supervisor-decision-tools))
      (dolist (name harness-supervisor-decision-tools)
        ;; The plan engine's own tools want a real plan: stand in for them,
        ;; this test is about the decision being a decision.
        (unless (and (harness-tool-get name) (not (member name '("submit_plan" "retry_step"))))
          (harness-define-tool name :label name :description "A decision." :kind 'meta
                               :handler (lambda (&rest _) (harness-tool-ok "ok"))))
        (ert-info (name)
          (setq harness-supervisor-test--script
                (list (harness-supervisor-test-calls name '(:reason "because"))
                      '((:type text :delta "Done.") (:type done :stop-reason end-turn))))
          (should (eq 'end-turn (harness-supervisor-test-prompt sid (format "Turn with %s" name))))
          (should-not (harness-supervisor-test-reminders sid))))
      ;; Another tool is no decision.
      (setq harness-supervisor-test--script
            (list (harness-supervisor-test-calls "todo_write" '(:todos ("a")))
                  '((:type text :delta "Done.") (:type done :stop-reason end-turn))))
      (harness-supervisor-test-prompt sid "Turn with todo_write")
      ;; The model keeps stopping, so it is sent back as often as it may be.
      (should (= 2 (length (harness-supervisor-test-reminders sid)))))))

(ert-deftest harness-supervisor-a-decision-that-failed-decided-nothing ()
  "A call that was refused, or failed, does not let the turn stop."
  (harness-supervisor-test-with
    (let ((sid (harness-supervisor-test-session)))
      (setq harness-supervisor-test--script
            (list (harness-supervisor-test-calls "no_plan_needed" '(:reason "  "))
                  harness-supervisor-test-stops
                  (harness-supervisor-test-calls "no_plan_needed" '(:reason "nothing to do"))
                  '((:type text :delta "Done.") (:type done :stop-reason end-turn))))
      (should (eq 'end-turn (harness-supervisor-test-prompt sid "Anything?")))
      (should (= 4 (length harness-supervisor-test--requests)))
      (should (= 1 (length (harness-supervisor-test-reminders sid))))
      (should (equal '("No plan needed: nothing to do") (harness-supervisor-test-hints sid))))))

(ert-deftest harness-supervisor-a-session-that-does-not-supervise-stops-when-it-likes ()
  "Hands-on sessions and ungoverned ones are not sent back."
  (harness-supervisor-test-with
    (dolist (sid (list (harness-supervisor-test-session :ext '(:supervisor :false))
                       (harness-supervisor-test-session :kind 'subagent)))
      (setq harness-supervisor-test--script (list harness-supervisor-test-stops)
            harness-supervisor-test--requests nil)
      (should (eq 'end-turn (harness-supervisor-test-prompt sid "What does foo do?")))
      (should (= 1 (length harness-supervisor-test--requests)))
      (should-not (harness-supervisor-test-reminders sid))
      (should-not (harness-supervisor-test-hints sid)))))

(ert-deftest harness-supervisor-the-stop-filter-answers-as-the-agent-asks ()
  "The `agent/stop' chain gets (:stop t) back for others, and a reminder from the harness."
  (harness-supervisor-test-with
    (let* ((sid (harness-supervisor-test-session))
           (session (harness-call 'session/get sid))
           (hands-on (harness-call 'session/get (harness-supervisor-test-session :ext '(:supervisor :false))))
           (ask (lambda (session) (harness-test-await (harness-run-filter-async 'agent/stop (list :stop t) session)))))
      (should (equal '(:stop t) (funcall ask hands-on)))
      (dotimes (_ 2)
        (let ((answer (funcall ask session)))
          (should-not (plist-get answer :stop))
          (should (equal (harness-sender-system "supervisor") (plist-get answer :from)))
          (should (string-match-p "submit_plan" (plist-get answer :message)))
          (should (string-match-p "no_plan_needed" (plist-get answer :message)))))
      (should (equal '(:stop t) (funcall ask session)))
      (should (string-match-p "without a decision" (car (harness-supervisor-test-hints sid))))
      ;; A decision this turn is let through, however many reminders went.
      (harness-supervisor--on-turn-started sid)
      (harness-supervisor--note-decision sid "call-1")
      (should (equal '(:stop t) (funcall ask session)))
      (should (= 1 (length (harness-supervisor-test-hints sid)))))))

;;;; The soft step budget

(ert-deftest harness-supervisor-the-budget-nudges-at-the-budget-and-every-half-budget ()
  "With 80 calls as the budget: 80, 120, 160 and so on."
  (let ((harness-supervisor-step-budget 80))
    (should-not (cl-some #'harness-supervisor--budget-point-p '(0 1 61 79 81 100 119 121 159)))
    (should (cl-every #'harness-supervisor--budget-point-p '(80 120 160 200))))
  (let ((harness-supervisor-step-budget 4))
    (should (equal '(4 6 8 10) (cl-remove-if-not #'harness-supervisor--budget-point-p (number-sequence 1 10)))))
  (let ((harness-supervisor-step-budget 1))
    (should (equal '(1 2 3) (cl-remove-if-not #'harness-supervisor--budget-point-p '(0 1 2 3)))))
  (dolist (budget '(nil 0 -3 "many"))
    (let ((harness-supervisor-step-budget budget))
      (should-not (cl-some #'harness-supervisor--budget-point-p '(1 80 120))))))

(ert-deftest harness-supervisor-a-long-turn-is-steered-to-submit-its-plan ()
  "At the budget, then every half budget, the turn is steered; it is never stopped."
  (harness-supervisor-test-with
    (harness-supervisor-test-allow-all)
    (let ((harness-supervisor-step-budget 4)
          (sid (harness-supervisor-test-session)))
      (setq harness-supervisor-test--script
            (append (make-list 7 (harness-supervisor-test-calls "todo_write" '(:todos ("a"))))
                    (list (harness-supervisor-test-calls "no_plan_needed" '(:reason "enough"))
                          '((:type text :delta "Done.") (:type done :stop-reason end-turn)))))
      (should (eq 'end-turn (harness-supervisor-test-prompt sid "Look into everything")))
      ;; All eight calls were made: nothing was stopped.
      (should (= 8 (length (harness-supervisor-test-nodes sid 'tool-call))))
      (should (= 9 (length harness-supervisor-test--requests)))
      (should (= 8 (gethash sid harness-supervisor--calls)))
      (let ((nudges (harness-supervisor-test-reminders sid)))
        (should (= 3 (length nudges)))
        (should (equal '("4" "6" "8") (mapcar (lambda (text) (and (string-match "\\`\\([0-9]+\\) tool calls so far" text)
                                                                  (match-string 1 text)))
                                              nudges)))
        (dolist (text nudges)
          (should (string-match-p "Stop investigating and submit the plan with what you know" text))
          (should (string-match-p "open questions in the steps" text))))
      ;; The nudge is sent from the harness, as steering of the running turn.
      (let ((nudge (cl-find-if (lambda (n) (equal "supervisor" (plist-get (harness-node-sender n) :source)))
                               (harness-supervisor-test-nodes sid 'user))))
        (should (plist-get (plist-get nudge :meta) :steering)))
      (should-not (cl-some (lambda (h) (string-match-p "without a decision" h))
                           (harness-supervisor-test-hints sid)))
      ;; The next turn counts afresh.
      (setq harness-supervisor-test--script
            (append (make-list 3 (harness-supervisor-test-calls "todo_write" '(:todos ("a"))))
                    (list (harness-supervisor-test-calls "no_plan_needed" '(:reason "enough"))
                          '((:type text :delta "Done.") (:type done :stop-reason end-turn)))))
      (harness-supervisor-test-prompt sid "Again")
      (should (= 4 (gethash sid harness-supervisor--calls)))
      (should (= 4 (length (harness-supervisor-test-reminders sid)))))))

(ert-deftest harness-supervisor-only-a-supervisor-is-nudged ()
  "A hands-on session makes as many calls as it likes."
  (harness-supervisor-test-with
    (harness-supervisor-test-allow-all)
    (let ((harness-supervisor-step-budget 2)
          (sid (harness-supervisor-test-session :ext '(:supervisor :false))))
      (setq harness-supervisor-test--script
            (append (make-list 5 (harness-supervisor-test-calls "todo_write" '(:todos ("a"))))
                    (list '((:type text :delta "Done.") (:type done :stop-reason end-turn)))))
      (harness-supervisor-test-prompt sid "Look into everything")
      (should (= 5 (length (harness-supervisor-test-nodes sid 'tool-call))))
      (should-not (harness-supervisor-test-reminders sid)))))

;;;; The system prompt

(ert-deftest harness-supervisor-the-prompt-says-how-the-mode-works ()
  "A supervising session reads about the mode in place of the Planning section."
  (harness-supervisor-test-with
    (let* ((sid (harness-supervisor-test-session))
           (hands-on (harness-supervisor-test-session :ext '(:supervisor :false)))
           (prompt (harness-agent--system-prompt (harness-call 'session/get sid)))
           (other (harness-agent--system-prompt (harness-call 'session/get hands-on))))
      (should (string-match-p "^## Supervisor mode$" prompt))
      (should-not (string-match-p "^## Planning" prompt))
      (should-not (string-match-p "spawn_agent" prompt))
      (should (string-match-p "^## Planning" other))
      (should-not (string-match-p "Supervisor mode" other))
      ;; The section stands after the environment, where Planning stood, and ends the prompt.
      (should (< (string-match "^## Environment" prompt) (string-match "^## Supervisor mode" prompt)))
      (should (string-suffix-p (concat (harness-supervisor-prompt-section) "\n") prompt))
      (dolist (needle '("workers on cheaper models" "cannot change files yourself" "read-only and offline"
                        "submit_plan" "mundane, standard or hard" "one-line reason"
                        "fork (the default" "forks onto one model share one cache seed" "fresh"
                        "`after` sets the order" "different files" "share the working tree"
                        "reports a failed step" "retry_step" "escalates the tier" "submit a new plan"
                        "Every turn ends on a decision"
                        "no_plan_needed" "hand_in" "task_submit" "task_control" "session_send" "session_control"
                        "you answered a question" "the plan is still running"
                        "In a task, the last step commits (git add -A && git commit)"
                        "review feedback means a new plan to fix it"))
        (ert-info (needle)
          (should (string-match-p needle prompt)))))))

(ert-deftest harness-supervisor-the-prompt-section-is-the-same-every-time ()
  "The section is part of the prompt cache: it names no session, no directory, no count."
  (harness-supervisor-test-with
    (let* ((one (harness-agent--system-prompt (harness-call 'session/get (harness-supervisor-test-session))))
           (two (harness-agent--system-prompt (harness-call 'session/get (harness-supervisor-test-session))))
           (section (lambda (prompt) (substring prompt (string-match "^## Supervisor mode" prompt)))))
      (should (equal (funcall section one) (funcall section two)))
      (should (equal (harness-supervisor-prompt-section) (harness-supervisor-prompt-section)))
      (should-not (string-match-p "[0-9]" (harness-supervisor-prompt-section)))
      (should-not (string-match-p "/tmp" (harness-supervisor-prompt-section))))))

(ert-deftest harness-supervisor-the-prompt-section-is-appended-where-planning-is-missing ()
  "Without a Planning section to replace, the Supervisor mode section comes last."
  (harness-supervisor-test-with
    (let ((session (harness-call 'session/get (harness-supervisor-test-session))))
      (dolist (planning (list nil "" "A section nobody added."))
        (let ((harness-tools-agent-planning-section planning))
          (harness-remove-filter 'agent/system-prompt #'harness-tools-agent--system-prompt)
          (let ((prompt (harness-agent--system-prompt session)))
            (should (string-suffix-p (concat "\n\n" (harness-supervisor-prompt-section) "\n") prompt))
            ;; Once, and not a second copy of it anywhere.
            (should (= 2 (length (split-string prompt "^## Supervisor mode"))))))))))

(ert-deftest harness-supervisor-the-prompt-follows-the-decision-tools ()
  "The decisions the prompt lists are the ones the stop rule accepts."
  (harness-supervisor-test-with
    (let ((harness-supervisor-decision-tools '("no_plan_needed" "submit_plan" "a_new_decision")))
      (should (string-match-p "no_plan_needed, submit_plan, a_new_decision" (harness-supervisor-prompt-section)))
      (should-not (string-match-p "task_submit" (harness-supervisor-prompt-section))))))

;;;; no_plan_needed

(ert-deftest harness-supervisor-no-plan-needed-is-a-meta-tool-with-a-reason ()
  "The tool takes a required reason, and its description keeps file changes in plans."
  (harness-supervisor-test-with
    (let* ((spec (harness-call 'tools/get "no_plan_needed"))
           (schema (plist-get spec :schema)))
      (should (eq 'meta (plist-get spec :kind)))
      (should (equal "object" (plist-get schema :type)))
      (should (equal '("reason") (plist-get schema :required)))
      (should (equal "string" (plist-get (plist-get (plist-get schema :properties) :reason) :type)))
      (should (equal '(:reason) (cl-loop for (k _) on (plist-get schema :properties) by #'cddr collect k)))
      (should (string-match-p "Work that changes files always goes in a plan"
                              (plist-get spec :description)))
      (should (string-match-p "not the turn: give your reply after it" (plist-get spec :description))))))

(ert-deftest harness-supervisor-no-plan-needed-records-the-decision-and-lets-the-turn-go-on ()
  "The tool leaves a hint, says what to do next, and does not end the turn."
  (harness-supervisor-test-with
    (let* ((sid (harness-supervisor-test-session))
           (result (harness-supervisor-test-run sid "no_plan_needed" '(:reason "answered the question"))))
      (should-not (plist-get result :is-error))
      (should (equal "Noted. Give your reply now and end the turn." (plist-get result :content)))
      (should-not (plist-get result :end-turn))
      (should (equal '("No plan needed: answered the question") (harness-supervisor-test-hints sid)))
      (should (harness-supervisor--decided-p sid))
      ;; Without a reason there is nothing to note.
      (let ((other (harness-supervisor-test-session)))
        (dolist (input '(nil (:reason "") (:reason "   ")))
          (let ((bad (harness-supervisor-test-run other "no_plan_needed" input)))
            (should (plist-get bad :is-error))
            (should (string-match-p "reason is needed" (plist-get bad :content)))))
        (should-not (harness-supervisor-test-hints other))))))

;;;; In the real permission chain

(ert-deftest harness-supervisor-no-mode-lets-a-supervisor-write ()
  "With the permission module's stages after it, not even yolo mode lets a write through."
  (harness-supervisor-test-with-modules (tools-fs perms)
    (let* ((dir (harness-test-temp-dir))
           (file (expand-file-name "out.txt" dir)))
      (dolist (mode '(yolo accept-edits auto ask))
        (ert-info ((symbol-name mode))
          (let ((supervising (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted"
                                                      :permission-mode mode)
                                        :id))
                (hands-on (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted"
                                                   :permission-mode mode :non-interactive t
                                                   :ext '(:supervisor :false))
                                     :id)))
            (when (file-exists-p file) (delete-file file))
            (let ((result (harness-supervisor-test-run supervising "write_file"
                                                       (list :path file :content "hello"))))
              (should (plist-get result :is-error))
              (should (string-match-p "^Denied: supervisor mode" (plist-get result :content))))
            (should-not (file-exists-p file))
            (should-not (harness-call 'session/pending supervising))
            ;; The same call in a hands-on session is decided by the mode as ever.
            (when (memq mode '(yolo accept-edits))
              (should-not (plist-get (harness-supervisor-test-run hands-on "write_file"
                                                                  (list :path file :content "hello"))
                                     :is-error))
              (should (file-exists-p file)))))))))

(ert-deftest harness-supervisor-reading-and-deciding-need-no-approval ()
  "A supervisor reads and records its decision without being asked, in the ask mode too."
  (harness-supervisor-test-with-modules (tools-fs perms)
    (let* ((dir (harness-test-temp-dir))
           (file (expand-file-name "in.txt" dir))
           (sid (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted"
                                         :permission-mode 'ask)
                           :id)))
      (with-temp-file file (insert "contents\n"))
      (should-not (plist-get (harness-supervisor-test-run sid "read_file" (list :path file)) :is-error))
      (should-not (plist-get (harness-supervisor-test-run sid "no_plan_needed" '(:reason "just reading"))
                             :is-error))
      (should-not (harness-call 'session/pending sid))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status))))))

(ert-deftest harness-supervisor-no-plan-needed-needs-no-approval-in-any-mode ()
  "Recording a decision is allowed in every mode and with the user away, and no judge rules on it."
  (harness-supervisor-test-with-modules (perms)
    (let ((probe (harness-supervisor-test-judge))
          (harness-perms-auto-model "judge:x"))
      (dolist (mode '(ask accept-edits auto yolo))
        (dolist (away '(nil t))
          (ert-info ((format "%s mode, the user %s" mode (if away "away" "there")))
            (let ((sid (harness-supervisor-test-session :permission-mode mode
                                                        :non-interactive (if away t :false))))
              (should-not (plist-get (harness-supervisor-test-run sid "no_plan_needed" '(:reason "just reading"))
                                     :is-error))
              (should-not (harness-call 'session/pending sid))))))
      (should-not (funcall probe))
      ;; The judge is wired up: a session that does not supervise gets its verdict.
      (let ((sid (harness-supervisor-test-session :permission-mode 'auto :non-interactive t
                                                  :ext '(:supervisor :false))))
        (should (eq 'deny (plist-get (harness-supervisor-test-decide sid "no_plan_needed" 'meta) :behavior)))
        (should (= 1 (length (funcall probe))))))))

;;;; The settings page

(ert-deftest harness-supervisor-the-settings-are-on-the-settings-page ()
  "`config/describe' lists the settings, and the context cap, for the settings page."
  (harness-supervisor-test-with
    (let* ((description (harness-call 'config/describe default-directory))
           (settings (plist-get description :settings))
           (find (lambda (key) (cl-find key settings :key (lambda (s) (plist-get s :key)) :test #'equal)))
           (sections (mapcar (lambda (section) (plist-get section :name)) (plist-get description :sections))))
      (should (member "supervisor" sections))
      (dolist (key '("harness-supervisor" "harness-supervisor-tasks" "harness-supervisor-judge-model"
                     "harness-supervisor-tiers" "harness-supervisor-thinking"
                     "harness-supervisor-worker-thinking" "harness-supervisor-step-budget"
                     "harness-subagent-context-limit"))
        (should (funcall find key)))
      (should (equal "sessions" (plist-get (funcall find "harness-supervisor") :section)))
      (should (plist-get (funcall find "harness-supervisor") :layered))
      (dolist (key '("harness-supervisor-tasks" "harness-supervisor-judge-model"
                     "harness-supervisor-tiers" "harness-supervisor-thinking"
                     "harness-supervisor-worker-thinking" "harness-supervisor-step-budget"))
        (should (equal "supervisor" (plist-get (funcall find key) :section)))))))

;;;; Taking the module off

(ert-deftest harness-supervisor-not-loaded-changes-nothing ()
  "A harness without the module governs no session, and offers every tool as before."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (clrhash harness-tools)
    (dolist (m '(store project config provider provider-demo tools session agent tools-agent tools-fs))
      (harness-test-load-module m))
    (clrhash harness-sessions)
    (let* ((sid (harness-supervisor-test-session))
           (names (harness-supervisor-test-tool-names sid)))
      (should-not (harness-method-exists-p 'supervisor/set))
      (should-not (plist-get (plist-get (harness-call 'session/get sid) :ext) :supervisor))
      (should (member "write_file" names))
      (should (member "plan" names))
      (should-not (member "no_plan_needed" names))
      (should (string-match-p "^## Planning" (harness-agent--system-prompt (harness-call 'session/get sid))))
      (should (equal '(:behavior ask) (harness-supervisor-test-decide sid "write_file")))
      ;; No stage of the module is on the bus, so not even a session that
      ;; carries the switch is decided: its plans go to the chain as any call.
      (should-not (rassq #'harness-supervisor--gate (gethash 'permission/decide harness--filters)))
      (should-not (rassq #'harness-supervisor--approval (gethash 'permission/decide harness--filters)))
      (let ((marked (harness-supervisor-test-session :ext '(:supervisor t))))
        (dolist (tool '("write_file" "no_plan_needed" "submit_plan" "retry_step"))
          (ert-info (tool)
            (should (equal '(:behavior ask) (harness-supervisor-test-decide marked tool 'meta)))))))))

(ert-deftest harness-supervisor-shutdown-takes-it-off-the-bus ()
  "A stopped module sets nothing, denies nothing and nudges nobody; sessions keep their switch."
  (harness-supervisor-test-with-modules (tools-fs)
    (let ((sid (harness-supervisor-test-session)))
      (should (eq t (harness-supervisor-test-get sid)))
      (should (rassq #'harness-supervisor--gate (gethash 'permission/decide harness--filters)))
      (should (rassq #'harness-supervisor--approval (gethash 'permission/decide harness--filters)))
      (should (eq 'allow (plist-get (harness-supervisor-test-decide sid "no_plan_needed" 'meta) :behavior)))
      (harness-supervisor--shutdown)
      (should (eq t (harness-supervisor-test-get sid)))
      (should-not (harness-supervisor-test-get (harness-supervisor-test-session)))
      (should (member "write_file" (harness-supervisor-test-tool-names sid)))
      (should (equal '(:behavior ask) (harness-supervisor-test-decide sid "write_file")))
      ;; Neither stage is left, and what the approval allowed is asked about again.
      (should-not (rassq #'harness-supervisor--gate (gethash 'permission/decide harness--filters)))
      (should-not (rassq #'harness-supervisor--approval (gethash 'permission/decide harness--filters)))
      (dolist (tool '("no_plan_needed" "submit_plan" "retry_step"))
        (should (equal '(:behavior ask) (harness-supervisor-test-decide sid tool 'meta))))
      (should (equal nil (harness-run-filter 'tools/sandbox-options nil sid)))
      (should (string-match-p "^## Planning" (harness-agent--system-prompt (harness-call 'session/get sid))))
      (setq harness-supervisor-test--script (list harness-supervisor-test-stops))
      (should (eq 'end-turn (harness-supervisor-test-prompt sid "What does foo do?")))
      (should (= 1 (length harness-supervisor-test--requests))))))

(provide 'harness-supervisor-test)
;;; harness-supervisor-test.el ends here
