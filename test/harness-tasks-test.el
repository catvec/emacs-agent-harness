;;; harness-tasks-test.el --- Tests for task mode  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo-delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks-max-running)
(defvar harness-tasks-permission-mode)
(defvar harness-tasks-non-interactive)
(defvar harness-tasks-model)
(defvar harness-acp-server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(declare-function harness-tasks--save "harness-tasks")
(declare-function harness-acp-connect "harness-acp")
(declare-function harness-acp-set-handler "harness-acp")
(declare-function harness-acp-request "harness-acp")
(declare-function harness-acp--drop-client "harness-acp")

(defconst harness-tasks-test-script
  '((:type text :delta "Working on it.") (:type done :stop-reason end-turn)))

(defmacro harness-tasks-test-with (&rest body)
  "Load the state layer with the demo provider and tasks, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent tasks acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (setq harness-tasks--loaded t
           harness-acp--clients nil)
     (let ((harness-provider-demo-delay 0.005)
           (harness-provider-demo-script-override harness-tasks-test-script)
           (harness-naming-auto nil)
           (harness-tasks-max-running 3)
           (harness-tasks-permission-mode 'auto)
           (harness-tasks-non-interactive t)
           (harness-tasks-model "demo:scripted")
           (harness-acp-token nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (unwind-protect (progn ,@body)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-tasks-test-task (id) (harness-call 'task/get id))
(defun harness-tasks-test-state (id) (plist-get (harness-tasks-test-task id) :state))

(defun harness-tasks-test-wait-state (id state)
  (harness-test-wait (lambda () (eq (harness-tasks-test-state id) state)) 5
                     (format "task %s to become %s" id state)))

(defun harness-tasks-test-submit (prompt &optional cwd)
  (plist-get (harness-call 'task/submit (or cwd default-directory) prompt) :id))

(ert-deftest harness-tasks-submit-runs-to-done ()
  (harness-tasks-test-with
    (let* ((id (harness-tasks-test-submit "  fix the parser  "))
           (task (harness-tasks-test-task id))
           (sid (plist-get task :session)))
      (should (equal "fix the parser" (plist-get task :prompt)))
      (should (eq 'active (plist-get task :state)))
      (should sid)
      (let ((session (harness-call 'session/get sid)))
        (should (eq 'auto (plist-get session :permission-mode)))
        (should (plist-get session :non-interactive)))
      (harness-tasks-test-wait-state id 'done)
      (should (eq 'end-turn (plist-get (harness-tasks-test-task id) :outcome)))
      (should (plist-get (harness-tasks-test-task id) :finished))
      (should (equal "fix the parser"
                     (plist-get (cl-find 'user (harness-call 'session/nodes sid)
                                         :key (lambda (n) (plist-get n :kind)))
                                :content))))))

(ert-deftest harness-tasks-limit-queues-pending ()
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 1))
      (let ((a (harness-tasks-test-submit "first"))
            (b (harness-tasks-test-submit "second")))
        (should (eq 'active (harness-tasks-test-state a)))
        (should (eq 'pending (harness-tasks-test-state b)))
        (should-not (plist-get (harness-tasks-test-task b) :session))
        (harness-tasks-test-wait-state a 'done)
        (harness-tasks-test-wait-state b 'done)
        (should (plist-get (harness-tasks-test-task b) :session))))))

(ert-deftest harness-tasks-start-ignores-limit ()
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (let ((id (harness-tasks-test-submit "later")))
        (should (eq 'pending (harness-tasks-test-state id)))
        (harness-call 'task/start id)
        (should (eq 'active (harness-tasks-test-state id)))
        (harness-tasks-test-wait-state id 'done)
        (should-error (harness-call 'task/start id))))))

(ert-deftest harness-tasks-edit-and-cancel-pending ()
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (let ((id (harness-tasks-test-submit "draft")))
        (harness-call 'task/update id "better prompt")
        (should (equal "better prompt" (plist-get (harness-tasks-test-task id) :prompt)))
        (should-error (harness-call 'task/update id "  "))
        (harness-call 'task/cancel id)
        (should-not (gethash id harness-tasks--table))))))

(ert-deftest harness-tasks-stopped-turn-stays-active ()
  (harness-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
      (let ((id (harness-tasks-test-submit "will fail")))
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :outcome)) 5 "an outcome")
        (should (eq 'active (harness-tasks-test-state id)))
        (should (eq 'error (plist-get (harness-tasks-test-task id) :outcome)))
        (should (eq 'needs-input (plist-get (harness-tasks-test-task id) :column)))))))

(ert-deftest harness-tasks-blocked-session-needs-input ()
  (harness-tasks-test-with
    (let ((harness-provider-demo-delay 0.3)
          (columns nil))
      (harness-on 'task/changed (lambda (task) (push (plist-get task :column) columns)))
      (let* ((id (harness-tasks-test-submit "slow one"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (should (eq 'active (plist-get (harness-tasks-test-task id) :column)))
        (harness-test-wait (lambda () (eq 'running (plist-get (harness-call 'session/get sid) :status))) 5 "running")
        (let ((pid (harness-call 'session/pending-add sid '(:kind question :payload (:question "Which?")))))
          (should (eq 'needs-input (plist-get (harness-tasks-test-task id) :column)))
          (should (eq 'needs-input (car columns)))
          (harness-call 'session/pending-resolve sid pid "this")
          (should (eq 'active (plist-get (harness-tasks-test-task id) :column))))
        (harness-tasks-test-wait-state id 'done)
        (should (eq 'done (plist-get (harness-tasks-test-task id) :column)))))))

(ert-deftest harness-tasks-follow-up-reopens ()
  (harness-tasks-test-with
    (let ((id (harness-tasks-test-submit "do it")))
      (harness-tasks-test-wait-state id 'done)
      (let ((seen nil))
        (harness-on 'task/changed (lambda (task) (push (plist-get task :state) seen)))
        (harness-call 'task/prompt id "and also this")
        (harness-tasks-test-wait-state id 'done)
        (should (memq 'active seen)))
      (should (= 2 (cl-count 'user (harness-call 'session/nodes (plist-get (harness-tasks-test-task id) :session))
                             :key (lambda (n) (plist-get n :kind))))))))

(ert-deftest harness-tasks-complete-and-archive ()
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (let ((a (harness-tasks-test-submit "a")))
        (harness-call 'task/start a)
        (harness-tasks-test-wait-state a 'done)
        (should (= 1 (harness-call 'task/archive-done default-directory)))
        (should (plist-get (harness-tasks-test-task a) :archived))
        (should (eq 'inactive (plist-get (harness-call 'session/get (plist-get (harness-tasks-test-task a) :session))
                                         :status)))
        (harness-call 'task/archive a t)
        (should-not (plist-get (harness-tasks-test-task a) :archived))
        (let ((b (harness-tasks-test-submit "b")))
          (harness-call 'task/complete b)
          (should (eq 'done (harness-tasks-test-state b))))))))

(ert-deftest harness-tasks-message-revives-archived-task ()
  ;; Sending in an archived task's chat buffer (`agent/prompt', not
  ;; `task/prompt') resumes its session and puts the task back on the board.
  (harness-tasks-test-with
    (let* ((id (harness-tasks-test-submit "a"))
           (sid (plist-get (harness-tasks-test-task id) :session))
           (states nil))
      (harness-tasks-test-wait-state id 'done)
      (harness-call 'task/archive id)
      (should (eq 'inactive (plist-get (harness-call 'session/get sid) :status)))
      (harness-on 'task/changed (lambda (task) (push (plist-get task :state) states)))
      (harness-await (harness-call 'agent/prompt sid "one more thing"))
      (should (memq 'active states))
      (should-not (plist-get (harness-tasks-test-task id) :archived))
      (harness-tasks-test-wait-state id 'done)
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status))))))

(ert-deftest harness-tasks-delete ()
  (harness-tasks-test-with
    (let ((a (harness-tasks-test-submit "a"))
          (b (harness-tasks-test-submit "b")))
      (harness-tasks-test-wait-state a 'done)
      (harness-tasks-test-wait-state b 'done)
      (let ((sa (plist-get (harness-tasks-test-task a) :session))
            (sb (plist-get (harness-tasks-test-task b) :session)))
        (harness-call 'task/delete a t)
        (should-not (gethash a harness-tasks--table))
        (should-not (harness-call 'session/exists-p sa))
        ;; Deleting the session elsewhere forgets its task.
        (harness-call 'session/delete sb)
        (should-not (gethash b harness-tasks--table))))))

(ert-deftest harness-tasks-scoped-to-project-and-persisted ()
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (other (harness-test-temp-dir)))
      (let ((a (harness-tasks-test-submit "here"))
            (b (harness-tasks-test-submit "there" other)))
        (should (equal (list a) (mapcar (lambda (task) (plist-get task :id))
                                        (harness-call 'task/list default-directory))))
        (should (= 2 (length (harness-call 'task/list))))
        (harness-tasks--save)
        (clrhash harness-tasks--table)
        (setq harness-tasks--loaded nil)
        (should (= 2 (length (harness-call 'task/list))))
        (should (eq 'pending (harness-tasks-test-state b)))
        (should (equal "here" (plist-get (harness-tasks-test-task a) :prompt)))))))

(ert-deftest harness-tasks-listed-from-a-worktree ()
  "A board opened from a task's worktree shows the main checkout's tasks."
  (harness-tasks-test-with
    (let* ((harness-tasks-max-running 0)
           (base (harness-test-temp-dir))
           (root (file-name-as-directory (expand-file-name "repo" base)))
           (wt (expand-file-name "wt" base)))
      (make-directory root t)
      (dolist (args '(("init" "-q" "-b" "main") ("config" "user.name" "T")
                      ("config" "user.email" "t@example.invalid") ("config" "commit.gpgsign" "false")
                      ("commit" "-q" "--allow-empty" "-m" "init") ("worktree" "add" "-q" "-b" "task" "../wt")))
        (let ((default-directory root)) (should (zerop (apply #'call-process "git" nil nil nil args)))))
      (let ((id (harness-tasks-test-submit "in the main checkout" root)))
        (should (equal (list id) (mapcar (lambda (task) (plist-get task :id))
                                         (harness-call 'task/list wt))))))))

(ert-deftest harness-tasks-over-acp ()
  (harness-tasks-test-with
    (let* ((events nil)
           (conn (harness-acp-connect)))
      (harness-acp-set-handler conn (lambda (method params _respond)
                                      (when (equal method "_harness/event") (push params events))))
      (let* ((task (harness-test-await
                    (harness-acp-request conn "_harness/task/submit"
                                         (list :cwd default-directory :prompt "over the wire"))))
             (id (plist-get task :id)))
        (should (member (plist-get task :state) '("pending" "active")))
        (harness-tasks-test-wait-state id 'done)
        (harness-test-wait (lambda () (cl-some (lambda (e) (and (equal (plist-get e :event) "task/changed")
                                                                 (equal (plist-get (car (plist-get e :args)) :state) "done")))
                                                events))
                           5 "a task/changed event saying done")
        (should (= 1 (length (harness-test-await
                              (harness-acp-request conn "_harness/task/list" (list :cwd default-directory))))))))))

(defvar harness-model)
(defvar harness-thinking)
(defvar harness-tasks-thinking)

(ert-deftest harness-tasks-settings-report-real-defaults ()
  "Without task defaults, the settings are what the project configures."
  (harness-tasks-test-with
    (let ((harness-tasks-model nil) (harness-tasks-thinking nil)
          (harness-model "demo:scripted") (harness-thinking "high"))
      (let ((s (harness-call 'task/settings default-directory)))
        (should (equal "demo:scripted" (plist-get s :model)))
        (should (equal "high" (plist-get s :thinking)))))))

(ert-deftest harness-tasks-submit-with-session-settings ()
  (harness-tasks-test-with
    (let* ((id (plist-get (harness-call 'task/submit default-directory "careful one"
                                        (list :permission-mode "ask" :thinking "high" :non-interactive :false))
                          :id))
           (session (harness-call 'session/get (plist-get (harness-tasks-test-task id) :session))))
      (should (eq 'ask (plist-get session :permission-mode)))
      (should (equal "high" (plist-get session :thinking)))
      (should-not (plist-get session :non-interactive)))))

(ert-deftest harness-tasks-adopt-ongoing-session ()
  (harness-tasks-test-with
    (let ((sid (plist-get (harness-call 'session/create :cwd default-directory :model "demo:scripted") :id)))
      (harness-test-await (harness-call-async 'agent/prompt sid "Tidy the imports"))
      (should (member sid (mapcar (lambda (s) (plist-get s :id)) (harness-call 'task/adoptable default-directory))))
      (let* ((task (harness-call 'task/adopt sid))
             (id (plist-get task :id)))
        (should (equal "Tidy the imports" (plist-get task :prompt)))
        (should (equal sid (plist-get task :session)))
        ;; An idle session is waiting for the user.
        (should (eq 'needs-input (plist-get task :column)))
        (should-not (member sid (mapcar (lambda (s) (plist-get s :id)) (harness-call 'task/adoptable default-directory))))
        (should-error (harness-call 'task/adopt sid))
        ;; From here on it is an ordinary task.
        (harness-call 'task/prompt id "and sort them")
        (harness-tasks-test-wait-state id 'done)
        (should (eq 'done (plist-get (harness-tasks-test-task id) :column)))))))

;;;; Restarts: nothing is lost, interrupted work carries on

(defvar harness-provider-demo--continuations)
(defvar harness-tasks--dirty)
(defvar harness-tasks-resume-interrupted)
(defvar harness-tasks-resume-prompt)
(declare-function harness-agent-turn-handle "harness-agent")
(declare-function harness-session-flush "harness-session")
(declare-function harness-session--load-all "harness-session")
(declare-function harness-tasks--load "harness-tasks")
(declare-function harness-tasks--recover "harness-tasks")
(declare-function harness-tasks--recover-refinements "harness-tasks")
(declare-function harness-tasks--schedule "harness-tasks")
(declare-function harness-tasks--set "harness-tasks")
(declare-function harness-tasks-flush "harness-tasks")

(defun harness-tasks-test--die ()
  "Stop like a killed harness: running turns vanish and nobody is told."
  (dolist (sid (hash-table-keys harness-agent--turns))
    (let ((turn (gethash sid harness-agent--turns)))
      (remhash sid harness-agent--turns)
      (ignore-errors (funcall (plist-get (harness-agent-turn-handle turn) :cancel))))))

(defun harness-tasks-test--restart ()
  "Run the exit hooks, forget everything in memory and start again."
  (harness-tasks-flush)
  (harness-session-flush)
  (clrhash harness-sessions)
  (clrhash harness-tasks--table)
  (clrhash harness-tasks--starting)
  (clrhash harness-provider-demo--continuations)
  (setq harness-tasks--loaded nil)
  (when (boundp 'harness-merge--queues)
    (clrhash harness-merge--queues)
    (clrhash harness-merge--locks)
    (clrhash harness-merge--holds))
  (harness-session--load-all)
  (harness-tasks--load)
  ;; What the module's init schedules, in order.
  (harness-tasks--recover)
  (harness-tasks--recover-refinements)
  (harness-tasks--schedule))

(defun harness-tasks-test--hang-tool ()
  "Define the tool `hang', whose first call never returns."
  (let ((calls 0))
    (harness-define-tool "hang" :description "never returns the first time" :kind 'read
                         :handler (lambda (_input _ctx)
                                    (if (= 1 (cl-incf calls)) (harness-make-promise) "ok")))))

(defun harness-tasks-test--node (sid pred)
  "Return the first node of SID matching PRED."
  (cl-find-if pred (harness-call 'session/nodes sid)))

(ert-deftest harness-tasks-flushed-on-exit ()
  "A change waiting for its save is written when Emacs exits."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (should (memq #'harness-tasks-flush kill-emacs-hook))
      (let ((id (harness-tasks-test-submit "submitted just before quitting")))
        (should-not (harness-call 'store/load "tasks.json"))
        (harness-tasks-flush)
        (should-not harness-tasks--dirty)
        (should (equal (list id) (mapcar (lambda (task) (plist-get task :id))
                                         (harness-call 'store/load "tasks.json"))))))))

(ert-deftest harness-tasks-interrupted-task-resumes-after-restart ()
  (harness-tasks-test-with
    (harness-tasks-test--hang-tool)
    (let* ((harness-provider-demo-script-override
            '((:type tool-call :id "h1" :name "hang" :input (:path "x"))
              (:type text :delta "Done.") (:type done :stop-reason end-turn)))
           (id (harness-tasks-test-submit "slow work"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (harness-test-wait (lambda () (harness-tasks-test--node sid (lambda (n) (eq (plist-get n :kind) 'tool-call))))
                         5 "the hanging tool call")
      (harness-tasks-test--die)
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Carrying on.") (:type done :stop-reason end-turn))))
        (harness-tasks-test--restart)
        (harness-tasks-test-wait-state id 'done))
      (should (eq 'end-turn (plist-get (harness-tasks-test-task id) :outcome)))
      ;; The call the restart cut short has a result; then the task was told to carry on.
      (should (harness-tasks-test--node sid (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                                                             (plist-get (plist-get n :meta) :interrupted)))))
      (should (harness-tasks-test--node sid (lambda (n) (and (eq (plist-get n :kind) 'user)
                                                             (equal harness-tasks-resume-prompt (plist-get n :content))))))
      (should (= 2 (cl-count 'user (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind))))))))

(ert-deftest harness-tasks-interrupted-task-waits-when-resume-is-off ()
  (harness-tasks-test-with
    (harness-tasks-test--hang-tool)
    (let* ((harness-tasks-resume-interrupted nil)
           (harness-provider-demo-script-override
            '((:type tool-call :id "h1" :name "hang" :input (:path "x")) (:type done :stop-reason end-turn)))
           (id (harness-tasks-test-submit "slow work"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (harness-test-wait (lambda () (harness-tasks-test--node sid (lambda (n) (eq (plist-get n :kind) 'tool-call))))
                         5 "the hanging tool call")
      (harness-tasks-test--die)
      (harness-tasks-test--restart)
      (let ((task (harness-tasks-test-task id)))
        (should (eq 'active (plist-get task :state)))
        (should (eq 'interrupted (plist-get task :outcome)))
        (should (eq 'needs-input (plist-get task :column))))
      (should (= 1 (cl-count 'user (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind)))))
      ;; A reply carries it on like any stopped task.
      (let ((harness-provider-demo-script-override
             '((:type text :delta "On it.") (:type done :stop-reason end-turn))))
        (harness-call 'task/prompt id "carry on")
        (harness-tasks-test-wait-state id 'done)))))

(ert-deftest harness-tasks-interrupted-while-starting-starts-over ()
  "A task stopped before its session existed starts again from scratch."
  (harness-tasks-test-with
    (let ((id (let ((harness-tasks-max-running 0)) (harness-tasks-test-submit "barely begun"))))
      ;; Where `harness-tasks--start' leaves a task until its session exists.
      (harness-tasks--set id :state 'active :started (float-time))
      (harness-tasks-test--restart)
      (harness-tasks-test-wait-state id 'done)
      (should (plist-get (harness-tasks-test-task id) :session)))))

(ert-deftest harness-tasks-recover-leaves-working-tasks-alone ()
  "Tasks this process works on are not interrupted, whatever their state says."
  (harness-tasks-test-with
    (let* ((harness-provider-demo-delay 0.2)
           (id (harness-tasks-test-submit "busy"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (harness-tasks--recover)
      (harness-test-wait (lambda () (eq 'running (plist-get (harness-call 'session/get sid) :status))) 5 "running")
      (harness-tasks--recover)
      (harness-tasks-test-wait-state id 'done)
      (should (= 1 (cl-count 'user (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind))))))))

;;;; Backlog refinement: written up by an agent, started by the user
;;
;; Submitted with :refine, a task is written up by a read-only session
;; and waits in pending until task/start, which hands it to that session.

(defvar harness-tasks-start-text)

(defconst harness-tasks-test-write-up
  "Fix nested quotes in the parser\n\n- Handle nested quotes in `parse-args'.\n- Done when the quote tests pass.")

(defun harness-tasks-test-refine (prompt &optional cwd)
  "Submit PROMPT for the backlog; return the task id."
  (plist-get (harness-call 'task/submit (or cwd default-directory) prompt (list :refine t)) :id))

(defun harness-tasks-test-user-texts (sid)
  "The user messages of session SID, oldest first."
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes sid))))

(ert-deftest harness-tasks-refine-writes-up-then-waits ()
  "A refined task is written up by a read-only session, waits, then that session does it."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running nil)
          (harness-provider-demo-script-override
           `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn))))
      (let* ((id (harness-tasks-test-refine "  the parser chokes on nested quotes  "))
             (task (harness-tasks-test-task id))
             (sid (plist-get task :session)))
        (should (eq 'refining (plist-get task :state)))
        (should (eq 'pending (plist-get task :column)))
        (should (plist-get task :backlog))
        (should (equal "the parser chokes on nested quotes" (plist-get task :note)))
        (let ((session (harness-call 'session/get sid)))
          ;; Asking with nobody to ask: reads only.
          (should (eq 'ask (plist-get session :permission-mode)))
          (should (plist-get session :non-interactive))
          (should (equal "low" (plist-get session :thinking)))
          (should (equal default-directory (plist-get session :cwd)))
          (should-not (plist-get session :worktree))
          (should (string-match-p "## Task refinement" (harness-run-filter 'agent/system-prompt "" session))))
        (harness-tasks-test-wait-state id 'pending)
        (setq task (harness-tasks-test-task id))
        (should (equal harness-tasks-test-write-up (plist-get task :prompt)))
        (should (plist-get task :refined))
        (should (eq 'pending (plist-get task :column)))
        ;; Free slots do not start a backlog task; only the user does.
        (harness-tasks--schedule)
        (should (eq 'pending (harness-tasks-test-state id)))
        (should (= 1 (length (harness-tasks-test-user-texts sid))))
        (should (string-match-p "## Task refinement"
                                (harness-run-filter 'agent/system-prompt "" (harness-call 'session/get sid))))
        (harness-call 'task/start id)
        (should (eq 'active (harness-tasks-test-state id)))
        (should (equal sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-tasks-test-wait-state id 'done)
        (let ((session (harness-call 'session/get sid)))
          ;; The work runs with the task's settings, not the write-up's.
          (should (eq 'auto (plist-get session :permission-mode)))
          (should-not (equal "low" (plist-get session :thinking)))
          (should-not (string-match-p "## Task refinement" (harness-run-filter 'agent/system-prompt "" session))))
        ;; The start message carries the write-up and the words it came from.
        (let ((texts (harness-tasks-test-user-texts sid)))
          (should (= 2 (length texts)))
          (should (equal "the parser chokes on nested quotes" (car texts)))
          (should (string-match-p (regexp-quote harness-tasks-test-write-up) (cadr texts)))
          (should (string-match-p "^> the parser chokes on nested quotes$" (cadr texts))))))))

(ert-deftest harness-tasks-refine-failure-needs-input-then-retries ()
  (harness-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
      (let ((id (harness-tasks-test-refine "a flaky idea")))
        (harness-test-wait (lambda () (equal "boom" (plist-get (harness-tasks-test-task id) :error))) 5 "the error")
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'refining (plist-get task :state)))
          (should (eq 'error (plist-get task :outcome)))
          (should (eq 'needs-input (plist-get task :column)))
          (should (equal "a flaky idea" (plist-get task :prompt))))
        ;; A turn without a final message is no write-up either.
        (let ((harness-provider-demo-script-override '((:type done :stop-reason end-turn))))
          (harness-call 'task/refine id)
          (harness-test-wait (lambda () (equal "the agent wrote no task description"
                                               (plist-get (harness-tasks-test-task id) :error)))
                             5 "no description"))
        (let ((harness-provider-demo-script-override
               '((:type text :delta "Make the flaky idea solid") (:type done :stop-reason end-turn))))
          (harness-call 'task/refine id)
          (harness-tasks-test-wait-state id 'pending)
          (should (equal "Make the flaky idea solid" (plist-get (harness-tasks-test-task id) :prompt)))
          (should-not (plist-get (harness-tasks-test-task id) :outcome)))))))

(ert-deftest harness-tasks-refine-feedback-rewrites-the-task ()
  (harness-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "First write-up") (:type done :stop-reason end-turn))))
      (let ((id (harness-tasks-test-refine "an idea")))
        (harness-tasks-test-wait-state id 'pending)
        (let ((harness-provider-demo-script-override
               '((:type text :delta "Second write-up") (:type done :stop-reason end-turn))))
          (harness-call 'task/prompt id "mention the docs too")
          (harness-test-wait (lambda () (equal "Second write-up" (plist-get (harness-tasks-test-task id) :prompt)))
                             5 "the new write-up"))
        (should (eq 'pending (harness-tasks-test-state id)))
        (should (equal "an idea" (plist-get (harness-tasks-test-task id) :note)))
        ;; Editing it by hand works as for any pending task.
        (harness-call 'task/update id "Third, by hand")
        (should (equal "Third, by hand" (plist-get (harness-tasks-test-task id) :prompt)))
        (should (plist-get (harness-tasks-test-task id) :backlog))))))

(ert-deftest harness-tasks-refine-cancel-stops-then-drops ()
  "Cancelling stops a write-up in progress; once stopped, it drops the task and its session."
  (harness-tasks-test-with
    ;; A turn that never ends.
    (let ((harness-provider-demo-script-override '((:type text :delta "Thinking about it"))))
      (let* ((id (harness-tasks-test-refine "a slow idea"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (should-error (harness-call 'task/start id))
        (should-error (harness-call 'task/update id "by hand"))
        (should (harness-call 'task/cancel id))
        (harness-test-wait (lambda () (eq 'cancelled (plist-get (harness-tasks-test-task id) :outcome)))
                           5 "the write-up to stop")
        (should (eq 'needs-input (plist-get (harness-tasks-test-task id) :column)))
        (should-not (harness-call 'task/cancel id))
        (should-not (gethash id harness-tasks--table))
        (should-not (harness-call 'session/exists-p sid))))))

(ert-deftest harness-tasks-refine-a-queued-task ()
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-provider-demo-script-override
           '((:type text :delta "Queued, then written up") (:type done :stop-reason end-turn))))
      (let ((id (harness-tasks-test-submit "a queued idea")))
        (should-not (plist-get (harness-tasks-test-task id) :session))
        (harness-call 'task/refine id)
        (harness-test-wait (lambda () (equal "Queued, then written up" (plist-get (harness-tasks-test-task id) :prompt)))
                           5 "the write-up")
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'pending (plist-get task :state)))
          (should (plist-get task :backlog))
          (should (equal "a queued idea" (plist-get task :note)))
          (should (plist-get task :session)))
        (should-error (harness-call 'task/refine "t-nonexistent"))))))

(defvar harness-tasks-refine-tool-calls)

(ert-deftest harness-tasks-refine-told-to-finish-after-enough-calls ()
  "A write-up that keeps looking around is steered, once, to write it up."
  (harness-tasks-test-with
    (let ((harness-tasks-refine-tool-calls 2)
          (harness-provider-demo-script-override
           '((:type tool-call :id "r1" :name "peek" :input (:n 1))
             (:type tool-call :id "r2" :name "peek" :input (:n 2))
             (:type tool-call :id "r3" :name "peek" :input (:n 3))
             (:type text :delta "Look less next time")
             (:type done :stop-reason end-turn))))
      (let* ((id (harness-tasks-test-refine "a curious idea"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-tasks-test-wait-state id 'pending)
        (should (equal "Look less next time" (plist-get (harness-tasks-test-task id) :prompt)))
        (let ((steers (cl-remove-if-not (lambda (n) (and (eq (plist-get n :kind) 'user)
                                                          (plist-get (plist-get n :meta) :steering)))
                                        (harness-call 'session/nodes sid))))
          (should (= 1 (length steers)))
          (should (string-match-p "enough looking" (plist-get (car steers) :content))))))))

(ert-deftest harness-tasks-backlog-survives-a-restart ()
  "A written-up task waits in the backlog across a restart; nothing starts it."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running nil)
          (harness-provider-demo-script-override '((:type text :delta "Written up") (:type done :stop-reason end-turn))))
      (let* ((id (harness-tasks-test-refine "for later"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-tasks-test-wait-state id 'pending)
        (harness-tasks-test--restart)
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'pending (plist-get task :state)))
          (should (plist-get task :backlog))
          (should (equal "Written up" (plist-get task :prompt)))
          (should (equal sid (plist-get task :session))))
        (should (= 1 (length (harness-tasks-test-user-texts sid))))))))

(defun harness-tasks-test--refine-then-die (note)
  "Refine NOTE, cut its write-up short with a restart's hard stop; return the id."
  (harness-tasks-test--hang-tool)
  (let* ((harness-provider-demo-script-override
          '((:type tool-call :id "h1" :name "hang" :input (:path "x")) (:type done :stop-reason end-turn)))
         (id (harness-tasks-test-refine note))
         (sid (plist-get (harness-tasks-test-task id) :session)))
    (harness-test-wait (lambda () (harness-tasks-test--node sid (lambda (n) (eq (plist-get n :kind) 'tool-call))))
                       5 "the hanging tool call")
    (harness-tasks-test--die)
    id))

(ert-deftest harness-tasks-write-up-cut-short-is-written-again ()
  (harness-tasks-test-with
    (let ((id (harness-tasks-test--refine-then-die "cut short")))
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Written after all") (:type done :stop-reason end-turn))))
        (harness-tasks-test--restart)
        (harness-tasks-test-wait-state id 'pending))
      (should (equal "Written after all" (plist-get (harness-tasks-test-task id) :prompt)))
      (should (equal "cut short" (plist-get (harness-tasks-test-task id) :note))))))

(ert-deftest harness-tasks-write-up-cut-short-waits-when-resume-is-off ()
  (harness-tasks-test-with
    (let ((harness-tasks-resume-interrupted nil)
          (id (harness-tasks-test--refine-then-die "cut short")))
      (harness-tasks-test--restart)
      (let ((task (harness-tasks-test-task id)))
        (should (eq 'refining (plist-get task :state)))
        (should (eq 'interrupted (plist-get task :outcome)))
        (should (eq 'needs-input (plist-get task :column))))
      ;; Retrying writes it up.
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Retried") (:type done :stop-reason end-turn))))
        (harness-call 'task/refine id)
        (harness-tasks-test-wait-state id 'pending))
      (should (equal "Retried" (plist-get (harness-tasks-test-task id) :prompt))))))

(ert-deftest harness-tasks-backlog-task-cut-short-while-starting ()
  "A backlog task stopped before its session got the work starts again, or with resume off waits."
  (harness-tasks-test-with
    (let* ((harness-provider-demo-script-override '((:type text :delta "Written up") (:type done :stop-reason end-turn)))
           (id (harness-tasks-test-refine "for later"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (harness-tasks-test-wait-state id 'pending)
      ;; Where `harness-tasks--start' leaves a task until its session is prompted.
      (harness-tasks--set id :state 'active :started (float-time))
      (let ((harness-tasks-resume-interrupted nil))
        (harness-tasks-test--restart)
        (should (eq 'pending (harness-tasks-test-state id)))
        (should-not (plist-get (harness-tasks-test-task id) :started)))
      (harness-tasks--set id :state 'active :started (float-time))
      (let ((harness-provider-demo-script-override '((:type text :delta "Did it.") (:type done :stop-reason end-turn))))
        (harness-tasks-test--restart)
        (harness-tasks-test-wait-state id 'done))
      ;; It got the work, not the message that resumes work cut short.
      (let ((texts (harness-tasks-test-user-texts sid)))
        (should (= 2 (length texts)))
        (should (string-prefix-p harness-tasks-start-text (cadr texts)))))))

;;;; Naming: task sessions are titled like tickets

(defvar harness-tasks-naming-prompt)
(defvar harness-naming-system-prompt)

(ert-deftest harness-tasks-naming-prompt-for-task-sessions-only ()
  (harness-tasks-test-with
    (let* ((id (harness-tasks-test-submit "fix the parser"))
           (task-session (harness-call 'session/get (plist-get (harness-tasks-test-task id) :session)))
           (plain (harness-call 'session/create :cwd default-directory :model "demo:scripted")))
      (should (equal (concat "Name it.\n\n" harness-tasks-naming-prompt)
                     (harness-run-filter 'naming/system-prompt "Name it." task-session)))
      (should (equal "Name it." (harness-run-filter 'naming/system-prompt "Name it." plain)))
      (let ((harness-tasks-naming-prompt nil))
        (should (equal "Name it." (harness-run-filter 'naming/system-prompt "Name it." task-session))))
      (harness-tasks-test-wait-state id 'done))))

(ert-deftest harness-tasks-auto-named-like-tickets ()
  "Naming a task's session after its first turn asks for a ticket title."
  (harness-tasks-test-with
    (harness-test-load-module 'naming)
    (let ((harness-naming-auto t)
          (systems nil))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push (plist-get req :system) systems) (funcall orig req))))
        (let* ((id (harness-tasks-test-submit "fix the parser"))
               (sid (plist-get (harness-tasks-test-task id) :session)))
          (harness-test-wait (lambda () (plist-get (harness-call 'session/get sid) :name)) 5 "the task's name")
          (should (equal "Working on it" (plist-get (harness-call 'session/get sid) :name)))
          (harness-tasks-test-wait-state id 'done)))
      (should (member (concat harness-naming-system-prompt "\n\n" harness-tasks-naming-prompt) systems)))))

;;;; Git: worktree, merge queue, done only when merged

(defvar harness-merge--queues)
(defvar harness-merge--locks)
(defvar harness-merge--holds)
(defvar harness-tasks-worktrees)
(defvar harness-tasks-merge-session-name)

(defun harness-tasks-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure, return stdout."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string)))
      (buffer-string))))

(defun harness-tasks-test--make-repo ()
  "Create a repository with one commit on main; return its root."
  (let ((root (file-name-as-directory (expand-file-name "repo" (harness-test-temp-dir)))))
    (make-directory root t)
    (harness-tasks-test--git root "init" "-q" "-b" "main")
    (harness-tasks-test--git root "config" "user.name" "Harness Test")
    (harness-tasks-test--git root "config" "user.email" "test@example.invalid")
    (harness-tasks-test--git root "config" "commit.gpgsign" "false")
    (with-temp-file (expand-file-name "shared.txt" root) (insert "one\n"))
    (harness-tasks-test--git root "add" "shared.txt")
    (harness-tasks-test--git root "commit" "-q" "-m" "initial")
    root))

(defvar harness-tasks-test--commit-on-call 1
  "The call of the change tool (1-based) from which it also commits.")
(defvar harness-tasks-test--calls 0 "Calls of the change tool so far.")

(defmacro harness-tasks-test-with-git (&rest body)
  "Like `harness-tasks-test-with', in a fresh git repository bound to `root'.
The demo agent calls change_shared, which edits shared.txt in its cwd and
commits from call `harness-tasks-test--commit-on-call' on."
  (declare (indent 0))
  `(harness-tasks-test-with
     (dolist (m '(worktree merge)) (harness-test-load-module m))
     (clrhash harness-merge--queues)
     (clrhash harness-merge--locks)
     (clrhash harness-merge--holds)
     (setq harness-tasks-test--calls 0)
     (let* ((root (harness-tasks-test--make-repo))
            (default-directory root)
            (harness-tasks-worktrees t)
            (harness-tasks-test--commit-on-call 1)
            (harness-provider-demo-script-override
             '((:type tool-call :id "c1" :name "change_shared" :input (:text "two"))
               (:type text :delta "Changed it.")
               (:type done :stop-reason end-turn))))
       (harness-define-tool "change_shared" :description "edit shared.txt" :kind 'write
                            :handler (lambda (input ctx)
                                       (let ((cwd (plist-get ctx :cwd)))
                                         (cl-incf harness-tasks-test--calls)
                                         (with-temp-file (expand-file-name "shared.txt" cwd)
                                           (insert (plist-get input :text) "\n"))
                                         (when (>= harness-tasks-test--calls harness-tasks-test--commit-on-call)
                                           (harness-tasks-test--git cwd "commit" "-q" "-am" "change shared"))
                                         "ok")))
       ,@body)))

(defun harness-tasks-test--main-text (root)
  "Return shared.txt as checked out at ROOT."
  (with-temp-buffer (insert-file-contents (expand-file-name "shared.txt" root)) (buffer-string)))

(ert-deftest harness-tasks-git-lifecycle ()
  (harness-tasks-test-with-git
    (let ((id (harness-tasks-test-submit "Change the shared file"))
          (task nil))
      (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :session)) 5 "a session")
      (setq task (harness-tasks-test-task id))
      (should (string-prefix-p "task/change-the-shared-file-" (plist-get task :branch)))
      (should (equal "main" (plist-get task :base)))
      (should (file-directory-p (plist-get task :worktree)))
      (let ((session (harness-call 'session/get (plist-get task :session))))
        (should (equal (plist-get task :worktree) (plist-get session :cwd)))
        (should (equal (plist-get task :worktree) (plist-get session :worktree)))
        (should (string-match-p "own git worktree" (harness-run-filter 'agent/system-prompt "" session))))
      ;; Complete only once main has the change.
      (harness-tasks-test-wait-state id 'done)
      (should (equal "two\n" (harness-tasks-test--main-text root)))
      (should (plist-get (harness-tasks-test-task id) :merged))
      (should (string-match-p "Merge branch" (harness-tasks-test--git root "log" "-1" "--format=%s")))
      (should (cl-find harness-tasks-merge-session-name (harness-call 'session/list)
                       :key (lambda (s) (plist-get s :name)) :test #'equal))
      ;; Archiving removes the worktree and the merged branch.
      (harness-call 'task/archive id)
      (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :worktree-removed)) 10 "worktree removal")
      (should-not (file-directory-p (plist-get task :worktree)))
      (harness-test-wait (lambda () (string-empty-p (harness-tasks-test--git root "branch" "--list" (plist-get task :branch))))
                         10 "branch deletion"))))

(ert-deftest harness-tasks-git-merge-failure-needs-input ()
  (harness-tasks-test-with-git
    ;; Uncommitted edits at the root make the merge refuse to run.
    (with-temp-file (expand-file-name "shared.txt" root) (insert "local edit\n"))
    (let ((id (harness-tasks-test-submit "Change the shared file")))
      (harness-test-wait (lambda () (eq 'merge-failed (plist-get (harness-tasks-test-task id) :outcome))) 10
                         "the merge to fail")
      (should (eq 'needs-input (plist-get (harness-tasks-test-task id) :column)))
      (should-not (eq 'done (harness-tasks-test-state id)))
      (harness-tasks-test--git root "checkout" "--" "shared.txt")
      (harness-call 'task/merge id)
      (harness-tasks-test-wait-state id 'done)
      (should (equal "two\n" (harness-tasks-test--main-text root))))))

(ert-deftest harness-tasks-git-interrupted-task-resumes-and-merges ()
  "A task a restart interrupted in its worktree carries on and merges."
  (harness-tasks-test-with-git
    (harness-tasks-test--hang-tool)
    (let* ((harness-provider-demo-script-override
            '((:type tool-call :id "h1" :name "hang" :input (:path "x")) (:type done :stop-reason end-turn)))
           (id (harness-tasks-test-submit "Change the shared file"))
           (sid nil))
      (harness-test-wait (lambda () (setq sid (plist-get (harness-tasks-test-task id) :session))) 5 "a session")
      (harness-test-wait (lambda () (harness-tasks-test--node sid (lambda (n) (eq (plist-get n :kind) 'tool-call))))
                         5 "the hanging tool call")
      (harness-tasks-test--die)
      (let ((harness-provider-demo-script-override
             '((:type tool-call :id "c1" :name "change_shared" :input (:text "two"))
               (:type text :delta "Changed it.") (:type done :stop-reason end-turn))))
        (harness-tasks-test--restart)
        (harness-tasks-test-wait-state id 'done))
      (should (plist-get (harness-tasks-test-task id) :merged))
      (should (equal "two\n" (harness-tasks-test--main-text root))))))

(ert-deftest harness-tasks-git-uncommitted-work-is-steered ()
  (harness-tasks-test-with-git
    ;; The first call edits without committing; the merge queue tells the
    ;; agent to commit, and its next turn commits and merges.
    (let ((harness-tasks-test--commit-on-call 2))
      (let ((id (harness-tasks-test-submit "Change the shared file")))
        (harness-tasks-test-wait-state id 'done)
        (should (= 2 harness-tasks-test--calls))
        (should (equal "two\n" (harness-tasks-test--main-text root)))))))

(ert-deftest harness-tasks-git-refined-task-moves-into-its-worktree ()
  "A backlog task is written up at the root; starting moves its session into a worktree."
  (harness-tasks-test-with-git
    (let* ((harness-provider-demo-script-override
            '((:type text :delta "Change the shared file\n\nWrite two into shared.txt.")
              (:type done :stop-reason end-turn)))
           (id (harness-tasks-test-refine "shared.txt should say two"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (harness-tasks-test-wait-state id 'pending)
      (let ((session (harness-call 'session/get sid)))
        (should (equal root (plist-get session :cwd)))
        (should-not (plist-get session :worktree)))
      (should-not (plist-get (harness-tasks-test-task id) :worktree))
      (should (equal "one\n" (harness-tasks-test--main-text root)))
      ;; The provider's conversation stays behind at the root.
      (harness-call 'session/set-provider-state sid '(:cli-session-id "from-the-root"))
      (setq harness-provider-demo-script-override
            '((:type tool-call :id "c1" :name "change_shared" :input (:text "two"))
              (:type text :delta "Changed it.")
              (:type done :stop-reason end-turn)))
      (harness-call 'task/start id)
      (harness-tasks-test-wait-state id 'done)
      (let ((task (harness-tasks-test-task id))
            (session (harness-call 'session/get sid)))
        (should (equal sid (plist-get task :session)))
        (should (string-prefix-p "task/change-the-shared-file-" (plist-get task :branch)))
        (should (equal (plist-get task :worktree) (plist-get session :cwd)))
        (should (equal (plist-get task :worktree) (plist-get session :worktree)))
        (should-not (plist-get session :provider-state))
        (should (plist-get task :merged)))
      (should (equal "two\n" (harness-tasks-test--main-text root))))))

;;;; BTW: side conversations about the board

(defvar harness-tasks-btw-prompt)

(defun harness-tasks-test--ids (sessions)
  "Return the ids of SESSIONS."
  (mapcar (lambda (s) (plist-get s :id)) sessions))

(ert-deftest harness-tasks-btw-is-about-the-board ()
  "Only the board's BTWs, BTWs without a parent, are told to answer about the tasks."
  (harness-tasks-test-with
    (let* ((btw (harness-call 'task/btw default-directory "btw: how goes"))
           (id (harness-tasks-test-submit "fix the parser"))
           (task-session (harness-call 'session/get (plist-get (harness-tasks-test-task id) :session)))
           (plain (harness-call 'session/create :cwd default-directory :model "demo:scripted"))
           (fork (harness-test-await (harness-call 'session/fork (plist-get plain :id) :kind 'btw))))
      (should (eq 'btw (plist-get btw :kind)))
      (should-not (plist-get btw :parent-id))
      (should (equal "btw: how goes" (plist-get btw :name)))
      (should (equal (concat "Base.\n\n" harness-tasks-btw-prompt "\n")
                     (harness-run-filter 'agent/system-prompt "Base." btw)))
      ;; Task sessions, other sessions and a BTW about a session are left alone.
      (dolist (s (list task-session plain fork))
        (should (equal "Base." (harness-run-filter 'agent/system-prompt "Base." s))))
      (let ((harness-tasks-btw-prompt nil))
        (should (equal "Base." (harness-run-filter 'agent/system-prompt "Base." btw))))
      ;; A conversation about the board is no task to onboard.
      (should (member (plist-get plain :id) (harness-tasks-test--ids (harness-call 'task/adoptable default-directory))))
      (should-not (member (plist-get btw :id) (harness-tasks-test--ids (harness-call 'task/adoptable default-directory))))
      (should-error (harness-call 'task/adopt (plist-get btw :id)))
      (harness-tasks-test-wait-state id 'done))))

(ert-deftest harness-tasks-btw-turn-sees-the-board-prompt ()
  "A question asked in a board's BTW reaches the model with the board's instructions."
  (harness-tasks-test-with
    ;; Not a task: it talks to the project's usual model, not the task model.
    (let ((systems nil) (harness-model "demo:scripted"))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push (plist-get req :system) systems) (funcall orig req))))
        (let* ((conn (harness-acp-connect))
               (btw (harness-test-await (harness-acp-request conn "_harness/task/btw"
                                                             (list :cwd default-directory :name "btw: status?"))))
               (sid (plist-get btw :id)))
          ;; Over the wire too: a new btw session at the root.
          (should (equal "btw" (plist-get btw :kind)))
          (should (equal default-directory (plist-get btw :cwd)))
          (should (eq 'end-turn (plist-get (harness-test-await (harness-call-async 'agent/prompt sid "how are the tasks?"))
                                           :stop-reason)))
          (should (cl-some (lambda (s) (string-match-p (regexp-quote harness-tasks-btw-prompt) s)) systems)))))))

(ert-deftest harness-tasks-btw-starts-at-the-project-root ()
  "From anywhere in a repository, or one of its task worktrees, the BTW sits at the main checkout."
  (harness-tasks-test-with
    (let* ((root (harness-tasks-test--make-repo))
           (sub (file-name-as-directory (expand-file-name "lib" root))))
      (make-directory sub)
      (should (equal root (plist-get (harness-call 'task/btw sub) :cwd)))
      (let ((wt (expand-file-name ".worktrees/side" root)))
        (harness-tasks-test--git root "worktree" "add" "-q" "-b" "side" wt)
        (should (equal root (plist-get (harness-call 'task/btw wt) :cwd)))))))

(provide 'harness-tasks-test)
;;; harness-tasks-test.el ends here
