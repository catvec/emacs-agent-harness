;;; harness-resilience-test.el --- Sessions carry on through restarts, prompts and stalls  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)
(defvar harness-provider-demo--continuations)
(defvar harness-provider-demo-script-override)
(defvar harness-agent--turns)
(defvar harness-tools-agent--children)
(defvar harness-resilience--tick-seconds)
(defvar harness-resilience--progress)
(defvar harness-resilience--stalled)
(defvar harness-resilience-prompt-timeout)
(defvar harness-resilience--stall-after)
(defvar harness-resilience--resume-max)
(defvar harness-resilience-resume-interrupted)
(declare-function harness-agent-turn-handle "harness-agent")
(declare-function harness-provider-demo--last-user-text "harness-provider-demo")
(declare-function harness-session-flush "harness-session")
(declare-function harness-session--load-all "harness-session")
(declare-function harness-tools-agent--adopt "harness-tools-agent")
(declare-function harness-resilience--recover "harness-resilience")
(declare-function harness-resilience--check-prompts "harness-resilience")
(declare-function harness-resilience--check-stalls "harness-resilience")
(declare-function harness-resilience--stop-timer "harness-resilience")

(defvar harness-resilience-test--notifications nil
  "The notifications sent during a test, newest first.")

(defmacro harness-resilience-test-with (&rest body)
  "Run BODY with sessions, the agent, sub-agents, prompts and resilience.
Every tool runs without asking but `risky', which asks the user.
Notifications are kept in `harness-resilience-test--notifications'.
The checks of the resilience module run every tenth of a second."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (when (fboundp 'harness-resilience--stop-timer) (harness-resilience--stop-timer))
     (let ((harness-provider-demo--delay 0.005)
           (harness-resilience--tick-seconds 0.1)
           (harness-resilience-test--notifications nil)
           (default-directory dir))
       (dolist (m '(store project config provider provider-demo tools session agent perms
                          tools-agent tools-question priority resilience))
         (harness-test-load-module m))
       (clrhash harness-sessions)
       (clrhash harness-agent--turns)
       (clrhash harness-tools-agent--children)
       (clrhash harness-resilience--progress)
       (clrhash harness-resilience--stalled)
       (harness-register-method 'notification/send
                                (lambda (notification &optional _providers)
                                  (push notification harness-resilience-test--notifications)
                                  (harness-resolved (list :id "n" :results nil))))
       (harness-add-filter 'permission/decide
                           (lambda (d next request)
                             (funcall next (if (equal (plist-get request :tool) "risky")
                                               d
                                             (list :behavior 'allow))))
                           10)
       (harness-define-tool "risky" :label "Risky" :description "Asks first." :kind 'exec
                            :handler (lambda (_input _ctx) "did the risky thing"))
       (unwind-protect (progn ,@body)
         (dolist (sid (hash-table-keys harness-agent--turns))
           (ignore-errors (harness-call 'agent/cancel sid)))
         (harness-resilience--stop-timer)))))

(defun harness-resilience-test-session (&rest props)
  "Create a demo session with PROPS and return its id."
  (plist-get (apply #'harness-call 'session/create :cwd default-directory :model "demo:scripted" props) :id))

(defun harness-resilience-test--hang-tool ()
  "Define the tool `hang', whose calls never return."
  (harness-define-tool "hang" :label "Hang" :description "never returns" :kind 'read
                       :handler (lambda (_input _ctx) (harness-make-promise))))

(defun harness-resilience-test--die ()
  "Stop like a killed harness: running turns vanish and nobody is told."
  (dolist (sid (hash-table-keys harness-agent--turns))
    (let ((turn (gethash sid harness-agent--turns)))
      (remhash sid harness-agent--turns)
      (ignore-errors (funcall (plist-get (harness-agent-turn-handle turn) :cancel))))))

(defun harness-resilience-test--restart ()
  "Write what is in memory, forget it, and start again as a new process does."
  (harness-session-flush)
  (clrhash harness-sessions)
  (clrhash harness-tools-agent--children)
  (clrhash harness-provider-demo--continuations)
  (clrhash harness-resilience--progress)
  (clrhash harness-resilience--stalled)
  (harness-session--load-all)
  ;; What the modules' starts do, in order.
  (harness-tools-agent--adopt)
  (harness-resilience--recover))

(defun harness-resilience-test--nodes (sid kind)
  "Return the nodes of session SID of KIND, oldest first."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) kind)) (harness-call 'session/nodes sid)))

(defun harness-resilience-test--from (sid source)
  "Return the messages the harness sent SID from SOURCE, oldest first.
A message read back from the store names its sender's kind as a string."
  (cl-remove-if-not (lambda (n) (let ((from (harness-node-sender n)))
                                  (and (equal "system" (format "%s" (plist-get from :kind)))
                                       (equal source (plist-get from :source)))))
                    (harness-resilience-test--nodes sid 'user)))

(defun harness-resilience-test--wait-call (sid tool)
  "Wait until session SID has called TOOL."
  (harness-test-wait (lambda () (cl-find tool (harness-resilience-test--nodes sid 'tool-call)
                                         :key (lambda (n) (plist-get n :tool)) :test #'equal))
                     10 (format "a call to %s" tool)))

(defun harness-resilience-test--wait-idle (sid)
  "Wait until session SID runs no turn."
  (harness-test-wait (lambda () (not (harness-call 'agent/running sid))) 10 "the turn to end"))

(defun harness-resilience-test--script (scripts)
  "Return a demo script function answering by the last user message.
SCRIPTS is an alist (REGEXP . EVENTS): the first whose REGEXP matches
the request's last user text plays; without one, a short answer.  Each
tool call gets an id of its own, as a model's calls do."
  (lambda (request)
    (let ((text (harness-provider-demo--last-user-text request)))
      (mapcar (lambda (ev)
                (if (eq (plist-get ev :type) 'tool-call)
                    (plist-put (copy-sequence ev) :id (format "%s-%s" (plist-get ev :id) (harness-short-id)))
                  ev))
              (or (cdr (cl-find-if (lambda (s) (string-match-p (car s) text)) scripts))
                  '((:type text :delta "Noted.") (:type done :stop-reason end-turn)))))))

(defun harness-resilience-test--spawn (parent prompt &optional name)
  "Have PARENT spawn a sub-agent on PROMPT, called NAME; return its id."
  (let ((result (harness-test-await
                 (harness-call 'tools/execute parent
                               (list :id (harness-short-id) :name "spawn_agent"
                                     :input (list :prompt prompt :name (or name "helper")))))))
    (plist-get (plist-get result :meta) :child-id)))

;;;; Restarts

(ert-deftest harness-resilience-restart-during-a-running-turn-resumes-it ()
  "A turn the harness stopped in is carried on when the harness starts again.
The interrupted call gets a result saying so; a message of the
harness's names it, and the session goes on by itself to the end of
its work.  Nobody types \"continue\"."
  (harness-resilience-test-with
    (harness-resilience-test--hang-tool)
    (let* ((harness-provider-demo-script-override
            (harness-resilience-test--script
             '(("\\`The harness restarted" . ((:type text :delta "Carrying on.") (:type done :stop-reason end-turn)))
               ("." . ((:type tool-call :id "h1" :name "hang" :input (:path "x"))
                       (:type text :delta "Done.") (:type done :stop-reason end-turn))))))
           (sid (harness-resilience-test-session :name "Worker")))
      (harness-call 'agent/prompt sid "do the slow thing")
      (harness-resilience-test--wait-call sid "hang")
      (harness-resilience-test--die)
      (harness-resilience-test--restart)
      ;; Recorded as interrupted, then carried on.
      (should (equal (list sid) (mapcar (lambda (it) (plist-get it :id)) (harness-call 'session/interrupted))))
      (should (cl-find-if (lambda (n) (plist-get (plist-get n :meta) :interrupted))
                          (harness-resilience-test--nodes sid 'tool-result)))
      (let ((resume (harness-test-wait (lambda () (car (harness-resilience-test--from sid "restart")))
                                       10 "the message that carries it on")))
        (should (string-match-p "\\`The harness restarted and cut your last turn short" (plist-get resume :content)))
        (should (string-match-p "Your hang call did not finish" (plist-get resume :content))))
      (harness-resilience-test--wait-idle sid)
      (should (equal "Carrying on." (plist-get (car (last (harness-resilience-test--nodes sid 'assistant))) :content)))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))
      ;; A turn that ended normally: the next restart may carry it on again.
      (should-not (plist-get (plist-get (harness-call 'session/get sid) :ext) :resilience-resumes)))))

(ert-deftest harness-resilience-restart-resumes-a-sub-agent-that-reports-to-its-parent ()
  "A sub-agent cut short by a restart is carried on, and its parent hears from it.
The parent knew of its child only in memory before: after a restart it
waited for a report that never came."
  (harness-resilience-test-with
    (harness-resilience-test--hang-tool)
    (let* ((harness-provider-demo-script-override
            (harness-resilience-test--script
             '(("\\`The harness restarted" . ((:type text :delta "Found it after all.") (:type done :stop-reason end-turn)))
               ("\\`research" . ((:type tool-call :id "h1" :name "hang" :input (:path "x"))
                              (:type text :delta "Done.") (:type done :stop-reason end-turn))))))
           (parent (harness-resilience-test-session :name "Lead"))
           (child (harness-resilience-test--spawn parent "research the licence" "researcher")))
      (harness-resilience-test--wait-call child "hang")
      ;; The child's record says whom it reports to.
      (should (equal parent (plist-get (plist-get (plist-get (harness-call 'session/get child) :ext) :report-to)
                                       :parent)))
      (harness-resilience-test--die)
      (harness-resilience-test--restart)
      (harness-test-wait (lambda () (harness-resilience-test--from child "restart")) 10 "the child carried on")
      (harness-test-wait (lambda () (harness-resilience-test--from parent "sub-agent")) 10 "the report")
      (let ((report (plist-get (car (harness-resilience-test--from parent "sub-agent")) :content)))
        (should (string-match-p "Sub-agent report: researcher (session [-0-9a-f]+) finished" report))
        (should (string-match-p "Found it after all\\." report)))
      ;; Reported: the child forgot its parent, and the parent waits on nothing.
      (should-not (plist-get (plist-get (harness-call 'session/get child) :ext) :report-to))
      (should-not (harness-call 'agent/outstanding parent)))))

(ert-deftest harness-resilience-user-cancel-is-not-resumed ()
  "A turn the user cancelled stays stopped, even when the harness died meanwhile.
The cancel marks the session; the restart leaves it alone, and only the
next turn the user starts drops the mark."
  (harness-resilience-test-with
    (harness-resilience-test--hang-tool)
    (let* ((harness-provider-demo-script-override
            '((:type tool-call :id "h1" :name "hang" :input (:path "x"))
              (:type text :delta "Done.") (:type done :stop-reason end-turn)))
           (sid (harness-resilience-test-session :name "Stopped on purpose")))
      (harness-call 'agent/prompt sid "do the slow thing")
      (harness-resilience-test--wait-call sid "hang")
      ;; The user cancels; the harness dies before the turn has ended.
      (harness-call 'agent/cancel sid)
      (should (eq t (plist-get (plist-get (harness-call 'session/get sid) :ext) :resilience-cancelled)))
      (harness-resilience-test--die)
      (harness-resilience-test--restart)
      ;; Interrupted, but not carried on: no message of the harness's, no turn.
      (should (equal (list sid) (mapcar (lambda (it) (plist-get it :id)) (harness-call 'session/interrupted))))
      (accept-process-output nil 0.2)
      (should-not (harness-resilience-test--from sid "restart"))
      (should-not (harness-call 'agent/running sid))
      (should (eq 'inactive (plist-get (harness-call 'session/get sid) :status)))
      (should-not harness-resilience-test--notifications)
      ;; The user carries it on; that turn is theirs, and drops the mark.
      (let ((harness-provider-demo-script-override
             '((:type text :delta "On it.") (:type done :stop-reason end-turn))))
        (harness-test-await (harness-call 'agent/prompt sid "carry on") 10))
      (should-not (plist-get (plist-get (harness-call 'session/get sid) :ext) :resilience-cancelled)))))

(ert-deftest harness-resilience-cancelled-sub-agent-is-reported-cancelled ()
  "A sub-agent whose cancelled turn a restart cut short is not carried on,
and its parent is told it was cancelled rather than left waiting."
  (harness-resilience-test-with
    (harness-resilience-test--hang-tool)
    (let* ((harness-provider-demo-script-override
            (harness-resilience-test--script
             '(("\\`research" . ((:type tool-call :id "h1" :name "hang" :input (:path "x"))
                              (:type done :stop-reason end-turn))))))
           (parent (harness-resilience-test-session :name "Lead"))
           (child (harness-resilience-test--spawn parent "research the licence" "researcher")))
      (harness-resilience-test--wait-call child "hang")
      (harness-call 'agent/cancel child)
      (harness-resilience-test--die)
      (harness-resilience-test--restart)
      (should-not (harness-resilience-test--from child "restart"))
      (harness-test-wait (lambda () (harness-resilience-test--from parent "sub-agent")) 10 "the report")
      (should (string-match-p "researcher (session [-0-9a-f]+) stopped: its turn was cancelled"
                              (plist-get (car (harness-resilience-test--from parent "sub-agent")) :content))))))

(ert-deftest harness-resilience-carries-a-session-on-a-bounded-number-of-times ()
  "A session the harness stopped in too many times in a row is left stopped.
It says why, and the user is told; a turn that ends normally starts the
count again."
  (harness-resilience-test-with
    (harness-resilience-test--hang-tool)
    (let* ((harness-resilience--resume-max 2)
           (harness-provider-demo-script-override
            (harness-resilience-test--script
             '(("." . ((:type tool-call :id "h1" :name "hang" :input (:path "x"))
                       (:type done :stop-reason end-turn))))))
           (sid (harness-resilience-test-session :name "Crashy")))
      (harness-call 'agent/prompt sid "do the slow thing")
      (dotimes (i 2)
        (harness-resilience-test--wait-call sid "hang")
        (harness-resilience-test--die)
        (harness-resilience-test--restart)
        ;; Carried on, and counted.
        (harness-test-wait (lambda () (= (1+ i) (length (harness-resilience-test--from sid "restart"))))
                           10 "the message that carries it on")
        (should (equal (1+ i) (plist-get (plist-get (harness-call 'session/get sid) :ext) :resilience-resumes)))
        ;; The next turn hangs on its call again.
        (harness-test-wait (lambda () (= (+ 2 i) (length (harness-resilience-test--nodes sid 'tool-call))))
                           10 "the next hanging call"))
      (harness-resilience-test--die)
      (harness-resilience-test--restart)
      (accept-process-output nil 0.2)
      (should (= 2 (length (harness-resilience-test--from sid "restart"))))
      (should-not (harness-call 'agent/running sid))
      (should (cl-find-if (lambda (n) (string-match-p "\\`Not carried on after the restart: the harness stopped during its turn 3 times in a row"
                                                      (plist-get n :content)))
                          (harness-resilience-test--nodes sid 'hint)))
      (let ((note (car harness-resilience-test--notifications)))
        (should (equal "Left stopped: Crashy" (plist-get note :title)))
        (should (equal sid (plist-get note :session)))))))

(ert-deftest harness-resilience-resume-off-leaves-sessions-stopped ()
  (harness-resilience-test-with
    (harness-resilience-test--hang-tool)
    (let ((harness-resilience-resume-interrupted nil)
          (harness-provider-demo-script-override
           '((:type tool-call :id "h1" :name "hang" :input (:path "x")) (:type done :stop-reason end-turn)))
          (sid (harness-resilience-test-session)))
      (harness-call 'agent/prompt sid "do the slow thing")
      (harness-resilience-test--wait-call sid "hang")
      (harness-resilience-test--die)
      (harness-resilience-test--restart)
      (accept-process-output nil 0.2)
      (should-not (harness-resilience-test--from sid "restart"))
      ;; The session module's hint says what happened, as it always did.
      (should (cl-find-if (lambda (n) (string-match-p "\\`Interrupted: the harness stopped during this turn"
                                                      (plist-get n :content)))
                          (harness-resilience-test--nodes sid 'hint))))))

(ert-deftest harness-resilience-wakes-a-session-whose-wait-was-lost ()
  "A session waiting, its turn over, for work the restart forgot is woken.
A session that still waits for work this process runs is left waiting."
  (harness-resilience-test-with
    (let* ((harness-provider-demo-script-override
            '((:type text :delta "Waiting.") (:type done :stop-reason end-turn)))
           (lost (harness-resilience-test-session :name "Lost wait"))
           (kept (harness-resilience-test-session :name "Kept wait"))
           (waits (list (cons lost "Waiting on session builder") (cons kept "Sub-agent X running")))
           (outstanding (lambda (value sid) (or (cdr (assoc sid waits)) value))))
      ;; As `session_wait' registers a wait, the turn ending meanwhile.
      (harness-add-filter 'agent/outstanding outstanding)
      (harness-test-await (harness-call 'agent/prompt lost "wait for the builder") 10)
      (harness-test-await (harness-call 'agent/prompt kept "wait for the sub-agent") 10)
      (should (equal "Waiting on session builder"
                     (plist-get (plist-get (harness-call 'session/get lost) :ext) :resilience-awaiting)))
      ;; The restart forgets the wait of the one, not of the other.
      (setq waits (list (cons kept "Sub-agent X running")))
      (harness-resilience-test--restart)
      (let ((wake (harness-test-wait (lambda () (car (harness-resilience-test--from lost "restart")))
                                     10 "the message that wakes it")))
        (should (string-match-p "The harness restarted while you waited for work to finish (Waiting on session builder)"
                                (plist-get wake :content))))
      (should-not (harness-resilience-test--from kept "restart"))
      (harness-resilience-test--wait-idle lost)
      ;; Woken, it waits on nothing any more.
      (should-not (plist-get (plist-get (harness-call 'session/get lost) :ext) :resilience-awaiting)))))

;;;; Prompts nobody answers

(ert-deftest harness-resilience-sub-agent-permission-wait-times-out ()
  "A sub-agent's permission prompt nobody answers is denied in the end.
The sub-agent carries on without it, its parent is told, and so is
the user; the parent then gets the sub-agent's report as usual."
  (harness-resilience-test-with
    (let* ((harness-resilience-prompt-timeout 0.3)
           (harness-provider-demo-script-override
            (harness-resilience-test--script
             '(("\\`research" . ((:type tool-call :id "r1" :name "risky" :input (:command "rm -rf build"))
                              (:type text :delta "Worked around it.") (:type done :stop-reason end-turn))))))
           (timed-out nil)
           (parent (harness-resilience-test-session :name "Lead"))
           (child (harness-resilience-test--spawn parent "research the licence" "researcher")))
      (harness-on 'resilience/prompt-timed-out (lambda (sid item) (push (cons sid item) timed-out)))
      (harness-test-wait (lambda () (harness-call 'session/pending child)) 10 "the permission prompt")
      (should (eq 'blocked (plist-get (harness-call 'session/get child) :status)))
      ;; Unanswered: the checks deny it once its time is up.
      (harness-test-wait (lambda () timed-out) 10 "the prompt to time out")
      (should (equal child (caar timed-out)))
      (should (eq 'permission (plist-get (cdar timed-out) :kind)))
      (harness-resilience-test--wait-idle child)
      (should-not (harness-call 'session/pending child))
      (let ((result (car (harness-resilience-test--nodes child 'tool-result))))
        (should (plist-get result :is-error))
        (should (string-match-p "nobody answered this permission prompt" (plist-get result :output))))
      (should (equal "Worked around it."
                     (plist-get (car (last (harness-resilience-test--nodes child 'assistant))) :content)))
      ;; The parent hears of it, then of the sub-agent's end.
      (harness-test-wait (lambda () (harness-resilience-test--from parent "sub-agent")) 10 "the report")
      (let ((notice (car (harness-resilience-test--from parent "resilience"))))
        (should notice)
        (should (string-match-p "\\`Sub-agent researcher (session [-0-9a-f]+) waited 1 minute for permission to run Risky"
                                (plist-get notice :content)))
        (should (string-match-p "the harness denied it" (plist-get notice :content))))
      (let ((note (cl-find "prompt-timeout" harness-resilience-test--notifications
                           :key (lambda (n) (plist-get n :kind)) :test #'equal)))
        (should note)
        (should (equal "Answered for you: researcher" (plist-get note :title)))))))

(ert-deftest harness-resilience-sub-agent-question-wait-times-out ()
  "A sub-agent's question nobody answers is answered: decide for yourself."
  (harness-resilience-test-with
    (let* ((harness-resilience-prompt-timeout 0.3)
           (harness-provider-demo-script-override
            (harness-resilience-test--script
             '(("\\`research" . ((:type tool-call :id "q1" :name "ask_user"
                                     :input (:question "Which licence applies?" :options ("ODbL" "CC-BY")))
                              (:type text :delta "Assumed ODbL.") (:type done :stop-reason end-turn))))))
           (parent (harness-resilience-test-session :name "Lead"))
           (child (harness-resilience-test--spawn parent "research the licence" "researcher")))
      (harness-test-wait (lambda () (harness-call 'session/pending child)) 10 "the question")
      (harness-resilience-test--wait-idle child)
      (let ((result (car (harness-resilience-test--nodes child 'tool-result))))
        (should (string-match-p "\\`Nobody answered in 1 minute\\. Decide for yourself" (plist-get result :output))))
      (harness-test-wait (lambda () (harness-resilience-test--from parent "resilience")) 10 "the notice")
      (should (string-match-p "waited 1 minute for an answer to the question \"Which licence applies\\?\""
                              (plist-get (car (harness-resilience-test--from parent "resilience")) :content))))))

(ert-deftest harness-resilience-users-own-prompts-wait-for-the-user ()
  "The user's own session waits for the user, however long it takes."
  (harness-resilience-test-with
    (let ((harness-resilience-prompt-timeout 0.1)
          (harness-provider-demo-script-override
           '((:type tool-call :id "r1" :name "risky" :input (:command "rm -rf build"))
             (:type done :stop-reason end-turn)))
          (sid (harness-resilience-test-session)))
      (harness-call 'agent/prompt sid "clean up")
      (harness-test-wait (lambda () (harness-call 'session/pending sid)) 10 "the permission prompt")
      (accept-process-output nil 0.5)
      (harness-resilience--check-prompts)
      (should (harness-call 'session/pending sid))
      (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status))))))

;;;; Watchdog

(ert-deftest harness-resilience-watchdog-reports-a-stalled-turn ()
  "A running turn that makes no progress is reported once, until it moves.
The session says so, `resilience/stalled' is emitted, the user is
notified."
  (harness-resilience-test-with
    (let* ((harness-resilience--stall-after 0.3)
           (harness-provider-demo-script-override
            '((:type wait :seconds 3600) (:type done :stop-reason end-turn)))
           (stalled nil)
           (sid (harness-resilience-test-session :name "Quiet")))
      (harness-on 'resilience/stalled (lambda (id seconds) (push (cons id seconds) stalled)))
      (harness-call 'agent/prompt sid "think hard")
      ;; The checks run on their own.
      (harness-test-wait (lambda () stalled) 10 "the watchdog")
      (should (equal sid (caar stalled)))
      (should (> (cdar stalled) 0.3))
      (should (cl-find-if (lambda (n) (string-match-p "\\`No progress for 1 minute (waiting for the model): the turn may be stuck"
                                                      (plist-get n :content)))
                          (harness-resilience-test--nodes sid 'hint)))
      (let ((note (car harness-resilience-test--notifications)))
        (should (equal "Stalled: Quiet" (plist-get note :title)))
        (should (equal "stalled" (plist-get note :kind)))
        (should (equal sid (plist-get note :session))))
      ;; Once per stall.
      (accept-process-output nil 0.5)
      (should (= 1 (length stalled)))
      ;; Progress re-arms it.
      (harness-emit 'agent/stream sid "n1" 'text "x")
      (harness-test-wait (lambda () (= 2 (length stalled))) 10 "the second stall"))))

(ert-deftest harness-resilience-watchdog-gives-a-tool-its-timeout ()
  "A tool call may run as long as its timeout allows without being reported."
  (harness-resilience-test-with
    (harness-define-tool "slow" :label "Slow" :description "takes its time" :kind 'read :timeout 1000
                         :handler (lambda (_input _ctx) (harness-make-promise)))
    (let* ((harness-resilience--stall-after 0.2)
           (harness-provider-demo-script-override
            '((:type tool-call :id "s1" :name "slow" :input (:path "x")) (:type done :stop-reason end-turn)))
           (stalled nil)
           (sid (harness-resilience-test-session)))
      (harness-on 'resilience/stalled (lambda (id _seconds) (push id stalled)))
      (harness-call 'agent/prompt sid "be slow")
      (harness-resilience-test--wait-call sid "slow")
      (accept-process-output nil 0.8)
      (harness-resilience--check-stalls)
      (should (harness-call 'agent/running sid))
      (should-not stalled))))

(provide 'harness-resilience-test)
;;; harness-resilience-test.el ends here
