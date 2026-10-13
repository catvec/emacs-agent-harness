;;; harness-tasks-test.el --- Tests for task mode  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--waking)
(defvar harness-tasks--joining)
(defvar harness-tasks--naming)
(defvar harness-tasks--blocked-at)
(defvar harness-tasks--lend-timers)
(defvar harness-tasks-lend-blocked-slot-after)
(defvar harness-tasks--reclaimed-message)
(defvar harness-tasks--naming-pool)
(defvar harness-tasks--naming-concurrency)
(defvar harness-tasks--loaded)
(defvar harness-tasks--dirty)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-permission-mode)
(defvar harness-tasks-non-interactive)
(defvar harness-tasks-context-limit)
(defvar harness-tasks-model)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-agent--cancel-grace)
(defvar harness-tasks--paused-message)
(defvar harness-tasks--preempted-message)
(defvar harness-tasks--sent-back-message)
(declare-function harness-tasks--save "harness-tasks")
(declare-function harness-tasks--forget-stores "harness-tasks")
(declare-function harness-tasks--naming-pool-new "harness-tasks")
(declare-function harness-acp-connect "harness-acp")
(declare-function harness-acp-set-handler "harness-acp")
(declare-function harness-acp-request "harness-acp")
(declare-function harness-acp--drop-client "harness-acp")

(defconst harness-tasks-test-script
  '((:type text :delta "Working on it.") (:type done :stop-reason end-turn)))

(defmacro harness-tasks-test-with (&rest body)
  "Load the state layer with the demo provider and tasks, run BODY.
Finished tasks are done at once, as before review: the tests of review
turn `harness-tasks-require-verification' on themselves."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent priority
                          tasks acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (clrhash harness-tasks--waking)
     (clrhash harness-tasks--naming)
     ;; No earlier test's blocked session or lend timer reaches this one.
     (clrhash harness-tasks--blocked-at)
     (maphash (lambda (_ timer) (cancel-timer timer)) harness-tasks--lend-timers)
     (clrhash harness-tasks--lend-timers)
     (harness-tasks--forget-stores)
     ;; Nothing of an earlier test waits to be written over this one's files,
     ;; nor for a slot of the title throttle: a request of an earlier test
     ;; that is answered late gives its slot back to the pool it took it from.
     (setq harness-tasks--loaded t
           harness-tasks--dirty nil
           harness-tasks--naming-pool (harness-tasks--naming-pool-new)
           harness-acp--clients nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override harness-tasks-test-script)
           (harness-naming-auto nil)
           (harness-tasks-max-running 3)
           (harness-tasks-require-verification nil)
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
(defun harness-tasks-test-session (id)
  (harness-call 'session/get (plist-get (harness-tasks-test-task id) :session)))
(defun harness-tasks-test-session-id (id)
  "The id of task ID's session, which every task has from submission."
  (plist-get (harness-tasks-test-task id) :session))
(defun harness-tasks-test-default (option)
  "Return the default value of OPTION, which the tests' setup may have bound."
  (eval (car (get option 'standard-value)) t))
(defun harness-tasks-test-state (id) (plist-get (harness-tasks-test-task id) :state))

(defun harness-tasks-test-wait-state (id state)
  "Wait until task ID is in STATE: merges run git, slow on a busy machine."
  (harness-test-wait (lambda () (eq (harness-tasks-test-state id) state)) 30
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

(ert-deftest harness-tasks-session-runs-on-a-capped-context ()
  "A task's session is capped by `harness-tasks-context-limit'.
The demo model's window is 8000: a 4000-token limit halves the window
the session works on, the default 384000 leaves it whole, and nil
leaves it whole too."
  (harness-tasks-test-with
    (let* ((id (harness-tasks-test-submit "fix the parser"))
           (session (harness-tasks-test-session id)))
      (should (= 384000 (plist-get session :context-window-limit)))
      (should (= 8000 (plist-get session :context-window))))
    (let ((harness-tasks-context-limit 4000))
      (let* ((id (harness-tasks-test-submit "keep it small"))
             (session (harness-tasks-test-session id)))
        (should (= 4000 (plist-get session :context-window-limit)))
        (should (= 4000 (plist-get session :context-window)))))
    (let ((harness-tasks-context-limit nil))
      (let* ((id (harness-tasks-test-submit "and another one"))
             (session (harness-tasks-test-session id)))
        (should-not (plist-get session :context-window-limit))
        (should (= 8000 (plist-get session :context-window)))))))

(ert-deftest harness-tasks-limit-queues-pending ()
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 1))
      (let ((a (harness-tasks-test-submit "first"))
            (b (harness-tasks-test-submit "second")))
        (should (eq 'active (harness-tasks-test-state a)))
        (should (eq 'pending (harness-tasks-test-state b)))
        ;; Every task has its session from submission: the waiting one's
        ;; is idle, in the main checkout, and holds its priority.  The
        ;; work goes on in it once a slot frees.
        (let ((sid (harness-tasks-test-session-id b)))
          (should sid)
          (should (not (equal sid (harness-tasks-test-session-id a))))
          (should (eq 'idle (plist-get (harness-tasks-test-session b) :status)))
          (should (equal (file-name-as-directory (expand-file-name default-directory))
                         (plist-get (harness-tasks-test-session b) :cwd)))
          (should-not (plist-get (harness-tasks-test-task b) :started))
          (harness-tasks-test-wait-state a 'done)
          (harness-tasks-test-wait-state b 'done)
          (should (equal sid (harness-tasks-test-session-id b))))))))

(declare-function harness-tasks--free-slots "harness-tasks")
(declare-function harness-tasks--slot-project "harness-tasks")
(declare-function harness-tasks--schedule "harness-tasks")

(ert-deftest harness-tasks-limit-is-per-project ()
  "Every project has `harness-tasks-max-running' slots of its own.
With one slot each, a project's first task starts at once, however busy
another project is, and its second waits only for its own first one."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 1)
          (other (harness-test-temp-dir)))
      (let* ((a1 (harness-tasks-test-submit "here, first"))
             (a2 (harness-tasks-test-submit "here, second"))
             (b1 (harness-tasks-test-submit "there, first" other))
             (b2 (harness-tasks-test-submit "there, second" other)))
        (should-not (equal (plist-get (harness-tasks-test-task a1) :project)
                           (plist-get (harness-tasks-test-task b1) :project)))
        ;; This project's slot is taken; the other's first task gets its own.
        (should (eq 'active (harness-tasks-test-state a1)))
        (should (eq 'pending (harness-tasks-test-state a2)))
        (should (eq 'active (harness-tasks-test-state b1)))
        (should (eq 'pending (harness-tasks-test-state b2)))
        ;; Each waiting task has its own session already (idle, in its
        ;; project's main checkout); the slot decides whose work starts.
        (let ((a2-sid (harness-tasks-test-session-id a2))
              (b2-sid (harness-tasks-test-session-id b2)))
          (should a2-sid)
          (should b2-sid)
          (should-not (equal a2-sid b2-sid))
          (dolist (task (list a2 b2))
            (should (eq 'idle (plist-get (harness-tasks-test-session task) :status)))))
        (dolist (id (list a1 a2 b1 b2)) (harness-tasks-test-wait-state id 'done))
        ;; Each second task started once its own project's first one was done.
        (should (>= (plist-get (harness-tasks-test-task a2) :started)
                    (plist-get (harness-tasks-test-task a1) :finished)))
        (should (>= (plist-get (harness-tasks-test-task b2) :started)
                    (plist-get (harness-tasks-test-task b1) :finished)))))))

(ert-deftest harness-tasks-schedule-gives-each-project-its-slots ()
  "One scheduling pass starts the oldest queued tasks of every project.
The queue is oldest first across projects: a project out of slots
leaves its later tasks waiting and the walk goes on to the next one."
  (harness-tasks-test-with
    (let ((other (harness-test-temp-dir))
          a1 a2 b1 b2)
      ;; Queued while nothing may run: here, here, there, there.
      (let ((harness-tasks-max-running 0))
        (setq a1 (harness-tasks-test-submit "here, first")
              a2 (harness-tasks-test-submit "here, second")
              b1 (harness-tasks-test-submit "there, first" other)
              b2 (harness-tasks-test-submit "there, second" other)))
      (dolist (id (list a1 a2 b1 b2)) (should (eq 'pending (harness-tasks-test-state id))))
      (let ((harness-tasks-max-running 1))
        (harness-tasks--schedule)
        (should (eq 'active (harness-tasks-test-state a1)))
        (should (eq 'pending (harness-tasks-test-state a2)))
        (should (eq 'active (harness-tasks-test-state b1)))
        (should (eq 'pending (harness-tasks-test-state b2)))
        (dolist (id (list a1 a2 b1 b2)) (harness-tasks-test-wait-state id 'done))))))

(defun harness-tasks-test-submit-at (prompt priority)
  "Submit PROMPT here with PRIORITY; return its id."
  (plist-get (harness-call 'task/submit default-directory prompt (list :priority priority)) :id))

(defun harness-tasks-test-start-order (ids)
  "Return IDS in the order their tasks started."
  (sort (copy-sequence ids)
        (lambda (a b) (< (plist-get (harness-tasks-test-task a) :started)
                         (plist-get (harness-tasks-test-task b) :started)))))

(ert-deftest harness-tasks-schedule-starts-highest-priority-first ()
  "Waiting tasks take free slots by priority, the oldest first among equals.
With one slot, the tasks run one after the other in that order."
  (harness-tasks-test-with
    (let (low med high med2 high2)
      (let ((harness-tasks-max-running 0))
        (setq low (harness-tasks-test-submit-at "low" "low")
              med (harness-tasks-test-submit "medium, by default")
              high (harness-tasks-test-submit-at "high" 'high)
              med2 (harness-tasks-test-submit-at "medium, later" "med")
              high2 (harness-tasks-test-submit-at "high, later" "HIGH")))
      (let ((harness-tasks-max-running 1))
        (harness-tasks--schedule)
        ;; The oldest high one gets the slot, older tasks of lower priority wait.
        (should (eq 'active (harness-tasks-test-state high)))
        (dolist (id (list low med med2 high2)) (should (eq 'pending (harness-tasks-test-state id))))
        (dolist (id (list low med high med2 high2)) (harness-tasks-test-wait-state id 'done))
        (should (equal (list high high2 med med2 low)
                       (harness-tasks-test-start-order (list low med high med2 high2))))))))

(ert-deftest harness-tasks-priority-reorders-the-queue ()
  "Setting a waiting task's priority moves it up or down the queue.
A task's priority is its session's (see the priority plugin): the board
reads and orders by `harness-priority-of-task'."
  (harness-tasks-test-with
    (let (a b c)
      (let ((harness-tasks-max-running 0))
        (setq a (harness-tasks-test-submit "first")
              b (harness-tasks-test-submit "second")
              c (harness-tasks-test-submit "third"))
        (should (equal "high" (harness-call 'priority/set (harness-tasks-test-session-id c) "high")))
        (should (equal "low" (harness-call 'priority/set (harness-tasks-test-session-id a) 'low)))
        ;; The board says what the sessions say.
        (should (eq 'high (plist-get (harness-tasks-test-task c) :priority)))
        (should (eq 'low (plist-get (harness-tasks-test-task a) :priority)))
        (should (eq 'medium (plist-get (harness-tasks-test-task b) :priority)))
        ;; Changing a priority frees no slot: nothing starts.
        (dolist (id (list a b c)) (should (eq 'pending (harness-tasks-test-state id)))))
      (let ((harness-tasks-max-running 1))
        (harness-tasks--schedule)
        (should (eq 'active (harness-tasks-test-state c)))
        (dolist (id (list a b c)) (harness-tasks-test-wait-state id 'done))
        (should (equal (list c b a) (harness-tasks-test-start-order (list a b c))))))))

(ert-deftest harness-tasks-priority-is-checked-and-kept-on-the-session ()
  "A priority is low, medium or high, from a symbol or a string (\"med\" too).
A task's is its session's: nothing about it is stored on the task's
record, reading it is forgiving, a name no level has is refused, and it
reaches the session over the wire."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (let ((high (harness-tasks-test-submit-at "urgent" "High"))
            (plain (harness-tasks-test-submit "whenever")))
        (should (eq 'high (plist-get (harness-tasks-test-task high) :priority)))
        (should (eq 'medium (plist-get (harness-tasks-test-task plain) :priority)))
        ;; On the session, as its `:ext', where the queues read it.
        (should (equal "high" (harness-call 'priority/get (harness-tasks-test-session-id high))))
        (should (equal '(:priority "high") (plist-get (harness-tasks-test-session high) :ext)))
        (should (equal "medium" (harness-call 'priority/get (harness-tasks-test-session-id plain))))
        ;; Nothing of a task's own stores it, in memory or on disk.
        (should-not (plist-member (gethash high harness-tasks--table) :priority))
        (should-not (plist-member (gethash plain harness-tasks--table) :priority))
        ;; A name no level has is refused, and adds or changes nothing.
        (should-error (harness-call 'task/submit default-directory "nope" (list :priority "urgent")))
        (should (= 2 (length (harness-call 'task/list))))
        (should-error (harness-call 'priority/set (harness-tasks-test-session-id high) 'critical))
        (should (eq 'high (plist-get (harness-tasks-test-task high) :priority)))
        ;; The level is kept on the session, which the store keeps: a task
        ;; read back from disk says it.
        (harness-tasks--save)
        (should-not (plist-member
                     (cl-find high (harness-tasks-test--read (harness-tasks-test--global))
                              :key (lambda (r) (plist-get r :id)) :test #'equal)
                     :priority))
        (clrhash harness-tasks--table)
        (setq harness-tasks--loaded nil)
        (should (= 2 (length (harness-call 'task/list))))
        (should (eq 'high (plist-get (harness-tasks-test-task high) :priority)))
        (should (eq 'medium (plist-get (harness-tasks-test-task plain) :priority)))
        ;; Over the wire: a session id in, the level's name back.
        (let* ((conn (harness-acp-connect))
               (level (harness-test-await
                       (harness-acp-request conn "_harness/priority/set"
                                            (list :sessionId (harness-tasks-test-session-id high)
                                                  :priority "low"))))
               (sent (harness-test-await
                      (harness-acp-request conn "_harness/task/submit"
                                           (list :cwd default-directory :prompt "from a client"
                                                 :opts (list :priority "high"))))))
          (should (equal "low" level))
          (should (eq 'low (plist-get (harness-tasks-test-task high) :priority)))
          ;; The new task's session carries what it was submitted with.
          (should (equal "high" (plist-get sent :priority)))
          (should (equal "high" (harness-call 'priority/get (plist-get sent :session)))))))))

(ert-deftest harness-tasks-a-task-session-works-at-the-tasks-priority ()
  "A task's priority is its session's (see the priority plugin).
Every task has its session from submission, so the level is there
before the task starts, and what works for the task -- a sub-agent
above all -- takes it from the session.  Raising and lowering a task
is setting its session's level."
  (harness-tasks-test-with
    (let* ((high (harness-tasks-test-submit-at "urgent" "high"))
           (plain (harness-tasks-test-submit "whenever"))
           (high-sid (harness-tasks-test-session-id high))
           (plain-sid (harness-tasks-test-session-id plain)))
      (should (equal "high" (harness-call 'priority/get high-sid)))
      (should (equal "medium" (harness-call 'priority/get plain-sid)))
      (should (equal "high" (plist-get (plist-get (harness-tasks-test-session high) :ext) :priority)))
      ;; Raising and lowering a task reaches its session's queue.
      (harness-call 'priority/set plain-sid "low")
      (should (equal "low" (harness-call 'priority/get plain-sid)))
      (should (eq 'low (plist-get (harness-tasks-test-task plain) :priority)))
      (harness-call 'priority/set high-sid "medium")
      (should (equal "medium" (harness-call 'priority/get high-sid)))
      (should (eq 'medium (plist-get (harness-tasks-test-task high) :priority)))
      ;; A session working for the task has none of its own: it works at
      ;; the task's priority, and follows it when the task changes.
      (let ((sub (plist-get (harness-call 'session/create :cwd default-directory
                                          :parent-id high-sid)
                            :id)))
        (should (equal "medium" (harness-call 'priority/get sub)))
        (harness-call 'priority/set high-sid "high")
        (should (equal "high" (harness-call 'priority/get sub))))
      ;; A bulk change reaches the sessions of the tasks it selects.
      (harness-call 'task/set-all (list :priority "high" :ids (list plain)))
      (should (equal "high" (harness-call 'priority/get plain-sid)))
      (should (eq 'high (plist-get (harness-tasks-test-task plain) :priority)))
      (harness-tasks-test-wait-state high 'done)
      (harness-tasks-test-wait-state plain 'done))))

(ert-deftest harness-tasks-a-write-up-session-takes-the-priority ()
  "A backlog task's write-up runs at the task's priority, and keeps it."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running nil)
          (harness-provider-demo-script-override
           `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn))))
      (let* ((id (plist-get (harness-call 'task/submit default-directory "the parser chokes"
                                          (list :refine t :priority "high"))
                            :id))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (should (equal "high" (harness-call 'priority/get sid)))
        (harness-tasks-test-wait-state id 'pending)
        ;; The session that wrote it up goes on with the work, at the same
        ;; priority.
        (harness-call 'task/start id)
        (should (equal "high" (harness-call 'priority/get sid)))
        (harness-tasks-test-wait-state id 'done)))))

(ert-deftest harness-tasks-free-slots-count-per-project ()
  "A project's free slots count its own working tasks only.
A task's project is its `:project', else its `:cwd'."
  (harness-tasks-test-with
    (let ((harness-provider-demo--delay 5)          ; keep the started one running
          (harness-tasks-max-running 2)
          (other (harness-test-temp-dir)))
      (let* ((id (harness-tasks-test-submit "here"))
             (here (plist-get (harness-tasks-test-task id) :project)))
        (should (equal here (harness-tasks--slot-project (harness-tasks-test-task id))))
        (should (= 1 (harness-tasks--free-slots here)))
        (should (= 2 (harness-tasks--free-slots other)))
        (let ((harness-tasks-max-running nil))
          (should (= most-positive-fixnum (harness-tasks--free-slots here))))
        (harness-call 'task/cancel id))
      (should (equal "/p/" (harness-tasks--slot-project '(:project "/p/" :cwd "/p/sub/"))))
      (should (equal "/c/" (harness-tasks--slot-project '(:cwd "/c/")))))))

(ert-deftest harness-tasks-start-ignores-limit ()
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (let ((id (harness-tasks-test-submit "later")))
        (should (eq 'pending (harness-tasks-test-state id)))
        (harness-call 'task/start id)
        (should (eq 'active (harness-tasks-test-state id)))
        (harness-tasks-test-wait-state id 'done)
        (should-error (harness-call 'task/start id))))))

(ert-deftest harness-tasks-limit-changed-starts-waiting-tasks ()
  "A limit raised through `config/set', as the board's button sets it, starts waiting tasks.
At once, not when a task at work ends: here none ever does.  A lower
limit stops no task at work, no limit lets every waiting task start,
and a limit below 0 is refused."
  (harness-tasks-test-with
    ;; Turns that never end: only a new limit can start a task.
    (let ((harness-provider-demo-script-override '((:type text :delta "Working on it.")))
          (harness-tasks-max-running 0)
          (passes 0)
          (schedule (symbol-function 'harness-tasks--schedule)))
      (cl-letf (((symbol-function 'harness-save-user-option) (lambda (symbol value) (set symbol value)))
                ((symbol-function 'harness-tasks--schedule)
                 (lambda () (cl-incf passes) (funcall schedule))))
        (let ((a (harness-tasks-test-submit "first"))
              (b (harness-tasks-test-submit "second"))
              (c (harness-tasks-test-submit "third"))
              (limit (lambda (value)
                       (let ((before passes))
                         (harness-call 'config/set "harness-tasks-max-running" value :printed t :scope 'global)
                         ;; The scheduler runs once the change is announced.
                         (harness-test-wait (lambda () (> passes before)) 5 "a scheduling pass")))))
          (unwind-protect
              (progn
                ;; The pass the module's start queued is over: what runs
                ;; the scheduler from here on is the new limit.
                (accept-process-output nil 0.05)
                (dolist (id (list a b c)) (should (eq 'pending (harness-tasks-test-state id))))
                ;; Two slots: the two oldest start, the third waits.
                (funcall limit "2")
                (should (eql 2 harness-tasks-max-running))
                (should (eq 'active (harness-tasks-test-state a)))
                (should (eq 'active (harness-tasks-test-state b)))
                (should (eq 'pending (harness-tasks-test-state c)))
                ;; One: the two at work go on, and the third still waits.
                (funcall limit "1")
                (dolist (id (list a b)) (should (eq 'active (harness-tasks-test-state id))))
                (should (eq 'pending (harness-tasks-test-state c)))
                ;; No limit: the third starts too.
                (funcall limit "nil")
                (should-not harness-tasks-max-running)
                (should (eq 'active (harness-tasks-test-state c)))
                ;; A number of tasks is never negative.
                (should-error (harness-call 'config/set "harness-tasks-max-running" "-1" :printed t :scope 'global))
                (should-not harness-tasks-max-running))
            (dolist (id (list a b c)) (ignore-errors (harness-call 'task/cancel id)))))))))

(declare-function harness-tasks--holds-slot-p "harness-tasks")
(declare-function harness-tasks--put "harness-tasks")
(declare-function harness-provider-demo--last-user-text "harness-provider-demo")

(defun harness-tasks-test--record (state sid &optional project)
  "Return a task record in STATE worked on by session SID, in PROJECT."
  (list :id (concat "t-" (harness-short-id 8)) :project (or project default-directory)
        :cwd default-directory :prompt "already at it" :state state :session sid
        :merge-status (and (eq state 'merging) 'conflict) :created (float-time)))

(ert-deftest harness-tasks-slot-held-by-top-level-session-at-work ()
  "Only a task's own top-level session at work on it takes a slot.
A task holds one while it starts, and while it is active with that
session running or blocked mid-turn.  A session another one started --
a sub-agent, a fork, a merge-conflict resolver -- holds none, even made
a task, and nor does a task in the merge queue, whatever its session
does; nor review, done, refining or pending."
  (harness-tasks-test-with
    (let* ((top (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted") :id))
           (sub (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted"
                                         :kind 'subagent :parent-id top)
                           :id)))
      (dolist (status '(running blocked))
        (dolist (sid (list top sub)) (harness-call 'session/set-status sid status))
        (should (harness-tasks--holds-slot-p (harness-tasks-test--record 'active top)))
        (should-not (harness-tasks--holds-slot-p (harness-tasks-test--record 'active sub)))
        (dolist (state '(merging pending refining review done))
          (should-not (harness-tasks--holds-slot-p (harness-tasks-test--record state top)))))
      ;; Idle: it stopped, or waits for a follow-up.
      (harness-call 'session/set-status top 'idle)
      (should-not (harness-tasks--holds-slot-p (harness-tasks-test--record 'active top)))
      ;; Idle but waiting on work it left running (a supervisor's
      ;; workers): that work is the task's, so it keeps the slot.
      (should (harness-tasks--holds-slot-p
               (append (harness-tasks-test--record 'active top) (list :waiting "2 workers running"))))
      (should-not (harness-tasks--holds-slot-p
                   (append (harness-tasks-test--record 'active sub) (list :waiting "2 workers running"))))
      ;; Starting holds one before there is a session at all.
      (let ((starting (harness-tasks-test--record 'active nil)))
        (should-not (harness-tasks--holds-slot-p starting))
        (puthash (plist-get starting :id) t harness-tasks--starting)
        (should (harness-tasks--holds-slot-p starting))))))

(ert-deftest harness-tasks-schedule-counts-top-level-sessions-only ()
  "The scheduler fills a project's slots counting top-level task sessions only.
Of two slots, a task whose own session runs takes one.  A task in the
merge queue, its session at work on the conflicts, and a sub-agent made
a task, at work too, take none: the oldest waiting task starts in the
free slot, and the next one waits for it."
  (harness-tasks-test-with
    (let (first second)
      (let ((harness-tasks-max-running 0))
        (setq first (harness-tasks-test-submit "first waiting")
              second (harness-tasks-test-submit "second waiting")))
      (let* ((project (plist-get (harness-tasks-test-task first) :project))
             (running (lambda (&rest opts)
                        (let ((sid (plist-get (apply #'harness-call 'session/create
                                                     :cwd dir :model "demo:scripted" opts)
                                              :id)))
                          (harness-call 'session/set-status sid 'running)
                          sid)))
             (worker (funcall running))
             (merger (funcall running))
             (helper (funcall running :kind 'subagent :parent-id worker))
             (harness-tasks-max-running 2))
        (harness-tasks--put (harness-tasks-test--record 'active worker project))
        (harness-tasks--put (harness-tasks-test--record 'merging merger project))
        (harness-tasks--put (harness-tasks-test--record 'active helper project))
        (should (= 1 (harness-tasks--free-slots project)))
        (harness-tasks--schedule)
        (should (eq 'active (harness-tasks-test-state first)))
        (should (eq 'pending (harness-tasks-test-state second)))
        (should (= 0 (harness-tasks--free-slots project)))
        ;; Its slot is free again once it is done.
        (harness-tasks-test-wait-state first 'done)
        (harness-tasks-test-wait-state second 'done)
        (should (>= (plist-get (harness-tasks-test-task second) :started)
                    (plist-get (harness-tasks-test-task first) :finished)))
        (dolist (sid (list worker merger helper)) (harness-call 'session/set-status sid 'idle))))))

(ert-deftest harness-tasks-sub-agent-takes-no-slot ()
  "A task's sub-agent at work takes no slot: the task holds one, through
its own session, which waits on the sub-agent.  With two slots, while a
task's sub-agent runs, another task starts at once."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-agent)
    (harness-tasks-test--hang-tool)
    (let* ((harness-tasks-max-running 2)
           (harness-provider-demo-script-override
            (lambda (request)
              (cond ((plist-get (plist-get request :session) :parent-id)
                     ;; The sub-agent: its first call hangs.
                     '((:type tool-call :id "h1" :name "hang" :input (:path "x"))
                       (:type done :stop-reason end-turn)))
                    ((string-match-p "delegate" (harness-provider-demo--last-user-text request))
                     '((:type tool-call :id "s1" :name "spawn_agent" :input (:prompt "dig in" :name "helper"))
                       (:type text :delta "Delegated.")
                       (:type done :stop-reason end-turn)))
                    (t harness-tasks-test-script))))
           (a (harness-tasks-test-submit "delegate the work"))
           (sid (plist-get (harness-tasks-test-task a) :session))
           (project (plist-get (harness-tasks-test-task a) :project))
           (helper (harness-test-wait
                    (lambda ()
                      (cl-find-if (lambda (s)
                                    (harness-tasks-test--node (plist-get s :id)
                                                              (lambda (n) (equal (plist-get n :tool) "hang"))))
                                  (harness-call 'session/list (list :parent-id sid))))
                    10 "the sub-agent at work")))
      ;; Two sessions at work, and one slot taken: the task's own.
      (should (eq 'subagent (plist-get helper :kind)))
      (should (eq 'running (plist-get (harness-call 'session/get (plist-get helper :id)) :status)))
      (should (eq 'running (plist-get (harness-tasks-test-session a) :status)))
      (should (eq 'active (harness-tasks-test-state a)))
      (should (= 1 (harness-tasks--free-slots project)))
      (let ((b (harness-tasks-test-submit "something else")))
        (should (eq 'active (harness-tasks-test-state b)))
        (harness-tasks-test-wait-state b 'done))
      ;; The sub-agent stops; its task finishes.
      (harness-call 'agent/cancel (plist-get helper :id))
      (harness-tasks-test-wait-state a 'done))))

(ert-deftest harness-tasks-edit-and-cancel-pending ()
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (let* ((id (harness-tasks-test-submit "draft"))
             (sid (harness-tasks-test-session-id id)))
        (harness-call 'task/update id "better prompt")
        (should (equal "better prompt" (plist-get (harness-tasks-test-task id) :prompt)))
        (should-error (harness-call 'task/update id "  "))
        (harness-call 'task/cancel id)
        (should-not (gethash id harness-tasks--table))
        ;; A task dropped before it started takes its session with it:
        ;; the session held the task's priority and nothing else.
        (should-not (harness-call 'session/exists-p sid))))))

(ert-deftest harness-tasks-delete-a-waiting-task ()
  "Deleting a task that never started takes its session with it.
The session is what holds a waiting task's priority; nothing of the
work exists yet, so nothing of it is kept."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (let* ((id (harness-tasks-test-submit "never started"))
             (sid (harness-tasks-test-session-id id)))
        (should sid)
        (should (harness-call 'session/exists-p sid))
        (harness-call 'task/delete id)
        (should-not (gethash id harness-tasks--table))
        (should-not (harness-call 'session/exists-p sid))))))

(ert-deftest harness-tasks-prompt-refuses-a-waiting-task ()
  "A message to a task waiting for a slot is refused, and reaches nobody.
`task/prompt' sends a message to a task's session; one still waiting
for a slot has not been given the work, and the message would start it
rather than reach a task at work."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (let* ((id (harness-tasks-test-submit "waiting"))
             (sid (harness-tasks-test-session-id id)))
        (should sid)
        (should-error (harness-call 'task/prompt id "are you there?"))
        ;; Nothing was said to the session, and it still waits.  What its
        ;; transcript holds is the task cap's hint, not a message.
        (should-not (cl-find 'user (harness-call 'session/nodes sid)
                             :key (lambda (n) (plist-get n :kind))))
        (should (eq 'pending (harness-tasks-test-state id)))
        (should-not (plist-get (harness-tasks-test-task id) :started))))))

(ert-deftest harness-tasks-set-all-updates-current-tasks ()
  "task/set-all changes a pending task's record and a started task's session."
  (harness-tasks-test-with
    (let ((harness-provider-demo--delay 5)          ; keep the started one running
          (harness-tasks-max-running 0))
      (let* ((running (harness-tasks-test-submit "running"))
             (waiting (harness-tasks-test-submit "waiting")))
        (harness-call 'task/start running)
        (harness-test-wait (lambda () (eq 'active (harness-tasks-test-state running)))
                           5 "the task to start")
        (let ((ids (harness-call 'task/set-all (list :model "demo:other" :thinking "high"))))
          (should (member running ids))
          (should (member waiting ids))
          ;; The started task's session and the pending task's record both change.
          (should (equal "demo:other" (plist-get (harness-tasks-test-session running) :model)))
          (should (equal "high" (plist-get (harness-tasks-test-session running) :thinking)))
          (should (equal "demo:other" (plist-get (harness-tasks-test-task waiting) :model)))
          (should (equal "high" (plist-get (harness-tasks-test-task waiting) :thinking)))
          ;; Asking again changes nothing, and can stay in one project.
          (should-not (harness-call 'task/set-all (list :model "demo:other" :thinking "high")))
          (should-not (harness-call 'task/set-all (list :model "demo:third")
                                    (list :cwd (harness-test-temp-dir)))))
        (harness-call 'task/cancel running)))))

(ert-deftest harness-tasks-set-all-leaves-history ()
  "task/set-all never touches a done or archived task."
  (harness-tasks-test-with
    (let ((id (harness-tasks-test-submit "historical")))
      (harness-tasks-test-wait-state id 'done)
      (harness-call 'task/archive id)
      (should (null (harness-call 'task/set-all (list :model "demo:other"))))
      (should-not (plist-get (harness-tasks-test-task id) :model)))))

(ert-deftest harness-tasks-set-all-sets-priority-only-when-given ()
  "task/set-all changes priorities only when its settings carry one.
Without `:priority' (or with nil) every task keeps its own; with one,
the tasks that differ take it, a started one too, on their sessions
\(a task's priority is its session's); a bad one is refused before any
task changes."
  (harness-tasks-test-with
    (let ((harness-provider-demo--delay 5)          ; keep the started one running
          (harness-tasks-max-running 0))
      (let* ((running (harness-tasks-test-submit-at "running" "low"))
             (low (harness-tasks-test-submit-at "low" "low"))
             (high (harness-tasks-test-submit-at "high" "high"))
             (plain (harness-tasks-test-submit "medium"))
             (all (list running low high plain)))
        (harness-call 'task/start running)
        (harness-test-wait (lambda () (eq 'active (harness-tasks-test-state running)))
                           5 "the task to start")
        (cl-flet ((priorities ()
                    (mapcar (lambda (id) (plist-get (harness-tasks-test-task id) :priority)) all)))
          ;; Other settings leave every priority as it was.
          (should (seq-set-equal-p all (harness-call 'task/set-all (list :model "demo:other"))))
          (should (equal '(low low high medium) (priorities)))
          ;; A nil priority is none.
          (should-not (harness-call 'task/set-all (list :priority nil)))
          (should-not (harness-call 'task/set-all (list :model "demo:other" :priority nil)))
          (should (equal '(low low high medium) (priorities)))
          ;; A bad one is refused, and nothing changes, not even the other settings.
          (should-error (harness-call 'task/set-all (list :model "demo:third" :priority "urgent")))
          (should (equal '(low low high medium) (priorities)))
          (should (equal "demo:other" (plist-get (harness-tasks-test-task low) :model)))
          ;; Given, it changes the tasks that differ, the started one too...
          (should (seq-set-equal-p (list running low plain)
                                   (harness-call 'task/set-all (list :priority "High"))))
          (should (equal '(high high high high) (priorities)))
          ;; ...on their sessions: the session keeps its other settings,
          ;; and nothing starts.
          (should (equal "demo:other" (plist-get (harness-tasks-test-session running) :model)))
          (dolist (id (list low high plain)) (should (eq 'pending (harness-tasks-test-state id))))
          (should (equal (list high) (harness-call 'task/set-all (list :priority 'med)
                                                   (list :ids (list high)))))
          (should (equal '(high high medium high) (priorities))))
        (harness-call 'task/cancel running)))))

(defun harness-tasks-test--count-hints (sid text)
  "How many hints of session SID say TEXT."
  (cl-count text (harness-tasks-test-hints sid) :test #'equal))

(ert-deftest harness-tasks-set-all-reaches-every-project-once ()
  "What the all-sessions commands send reaches every project, once.
`session/set-all' with `:tasks' takes the sessions of the current tasks
besides the active ones, one closed meanwhile included, and
`task/set-all' without `:cwd' then the current tasks of every project.
Every task has its session from submission, a waiting one too, so the
waiting task's session is reached as well.  A task's session the first
changed is not changed a second time, so each change adds exactly one
hint, whichever comes first."
  (harness-tasks-test-with
    (let ((harness-provider-demo--delay 5)          ; keep the started ones running
          (harness-tasks-max-running 0)
          (harness-tasks-non-interactive nil)
          (other (harness-test-temp-dir))
          (everything '(:active t :tasks t))
          (sorted (lambda (ids) (sort (copy-sequence ids) #'string<))))
      (let* ((here (harness-tasks-test-submit "running here"))
             (there (harness-tasks-test-submit "running there" other))
             (waiting (harness-tasks-test-submit "waiting there" other))
             (plain (plist-get (harness-call 'session/create :cwd other :model "demo:scripted") :id)))
        (harness-call 'task/start here)
        (harness-call 'task/start there)
        (let ((here-sid (harness-tasks-test-session-id here))
              (there-sid (harness-tasks-test-session-id there))
              ;; The waiting task's session waits with it, idle, in the
              ;; main checkout of its project.
              (waiting-sid (harness-tasks-test-session-id waiting)))
          (should (eq 'idle (plist-get (harness-tasks-test-session waiting) :status)))
          (should (equal (file-name-as-directory (expand-file-name other))
                         (plist-get (harness-tasks-test-session waiting) :cwd)))
          ;; The task over there goes on in a session closed meanwhile.
          (harness-call 'session/deactivate there-sid)
          (should-not (member there-sid (harness-tasks-test--ids (harness-call 'session/list '(:active t)))))
          (should (equal (funcall sorted (list here-sid there-sid waiting-sid))
                         (funcall sorted (harness-call 'task/session-ids))))
          (should (equal (funcall sorted (list here-sid there-sid waiting-sid plain))
                         (funcall sorted (harness-tasks-test--ids (harness-call 'session/select everything)))))
          ;; Sessions first, then the tasks: four sessions, three tasks.
          (should (equal (funcall sorted (list here-sid there-sid waiting-sid plain))
                         (funcall sorted (harness-call 'session/set-all '(:non-interactive t) everything))))
          (should (equal (list here there waiting) (harness-call 'task/set-all '(:non-interactive t))))
          (dolist (id (list here there waiting))
            (should (eq t (plist-get (harness-tasks-test-task id) :non-interactive))))
          (dolist (sid (list here-sid there-sid waiting-sid plain))
            (should (plist-get (harness-call 'session/get sid) :non-interactive))
            (should (= 1 (harness-tasks-test--count-hints sid "non-interactive on"))))
          ;; Asked again, nothing changes.
          (should-not (harness-call 'session/set-all '(:non-interactive t) everything))
          (should-not (harness-call 'task/set-all '(:non-interactive t)))
          ;; The tasks first, then the sessions: still one hint each.
          (should (equal (list here there waiting) (harness-call 'task/set-all '(:non-interactive :false))))
          (should (equal (list plain) (harness-call 'session/set-all '(:non-interactive :false) everything)))
          (dolist (sid (list here-sid there-sid waiting-sid plain))
            (should-not (plist-get (harness-call 'session/get sid) :non-interactive))
            (should (= 1 (harness-tasks-test--count-hints sid "non-interactive off"))))
          (dolist (id (list here there waiting))
            (should (eq :false (plist-get (harness-tasks-test-task id) :non-interactive)))))
        (dolist (id (list here there)) (harness-call 'task/cancel id))))))

(ert-deftest harness-tasks-all-commands-leave-a-done-tasks-session-alone ()
  "A completed task is over: its session is left out with `:tasks', and so
changes no more, even while that session is active and `:active' alone
would select it.  The active sessions and the current tasks change as
ever, their records too, and `task/set-all' leaves a done task alone."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 3)
          ;; Sessions start interactive, so an all-command changes them.
          (harness-tasks-non-interactive nil)
          (everything '(:active t :tasks t))
          (sorted (lambda (ids) (sort (copy-sequence ids) #'string<))))
      (let* ((done (harness-tasks-test-submit "finish this")))
        (harness-tasks-test-wait-state done 'done)
        (let* ((done-sid (plist-get (harness-tasks-test-task done) :session))
               ;; A current task that keeps running, and a plain session.
               (running (let ((harness-provider-demo--delay 5))
                          (harness-tasks-test-submit "keep working")))
               (running-sid (plist-get (harness-tasks-test-task running) :session))
               (plain (plist-get (harness-call 'session/create :cwd default-directory
                                               :model "demo:scripted")
                                 :id)))
          (should (eq 'done (plist-get (harness-tasks-test-task done) :column)))
          ;; The finished task's session is still active: `:active' alone
          ;; selects it, `:tasks' takes it out again.
          (should (member done-sid (harness-tasks-test--ids (harness-call 'session/list '(:active t)))))
          (should (equal (funcall sorted (list running-sid plain))
                         (funcall sorted (harness-tasks-test--ids (harness-call 'session/select everything)))))
          ;; The all-commands' sessions change, the finished task's does not.
          (should (equal (funcall sorted (list running-sid plain))
                         (funcall sorted (harness-call 'session/set-all '(:non-interactive t)
                                                       everything))))
          (should (plist-get (harness-call 'session/get running-sid) :non-interactive))
          (should (plist-get (harness-call 'session/get plain) :non-interactive))
          (should-not (plist-get (harness-call 'session/get done-sid) :non-interactive))
          (should (zerop (harness-tasks-test--count-hints done-sid "non-interactive on")))
          ;; Nor does `task/set-all' reach the finished task's record.
          (should (equal (list running) (harness-call 'task/set-all '(:non-interactive t))))
          (should (eq t (plist-get (harness-tasks-test-task running) :non-interactive)))
          (should-not (plist-member (harness-tasks-test-task done) :non-interactive))
          ;; Turning it off again is the same: only the current work.
          (should (equal (funcall sorted (list running-sid plain))
                         (funcall sorted (harness-call 'session/set-all '(:non-interactive :false)
                                                       everything))))
          (should (equal (list running) (harness-call 'task/set-all '(:non-interactive :false))))
          (harness-call 'task/cancel running))))))

(ert-deftest harness-tasks-set-all-off-reaches-tasks-the-defaults-turn-on ()
  "Turning non-interactive off reaches a task with no setting of its own
that would start non-interactive all the same: the task default, or its
directory, turns it on.  It then has its own false.  A task that would
start interactive anyway is left alone, and turning it on reaches it."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-tasks-non-interactive t))
      (let ((id (harness-tasks-test-submit "waiting")))
        (should-not (plist-member (harness-tasks-test-task id) :non-interactive))
        (should (equal (list id) (harness-call 'task/set-all '(:non-interactive :false))))
        (should (eq :false (plist-get (harness-tasks-test-task id) :non-interactive)))
        (should-not (harness-call 'task/set-all '(:non-interactive :false)))
        (harness-call 'task/cancel id)))
    (let ((harness-tasks-max-running 0)
          (harness-tasks-non-interactive nil))
      (let ((id (harness-tasks-test-submit "waiting")))
        (should-not (harness-call 'task/set-all '(:non-interactive :false)))
        (should-not (plist-member (harness-tasks-test-task id) :non-interactive))
        (should (equal (list id) (harness-call 'task/set-all '(:non-interactive t))))
        (should (eq t (plist-get (harness-tasks-test-task id) :non-interactive)))
        (harness-call 'task/cancel id)))))

(ert-deftest harness-tasks-stopped-turn-stays-active ()
  (harness-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
      (let ((id (harness-tasks-test-submit "will fail")))
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :outcome)) 5 "an outcome")
        (should (eq 'active (harness-tasks-test-state id)))
        (should (eq 'error (plist-get (harness-tasks-test-task id) :outcome)))
        (should (eq 'needs-input (plist-get (harness-tasks-test-task id) :column)))))))

(defvar harness-tasks--retry-prompt)
(declare-function harness-tasks--set "harness-tasks")

(ert-deftest harness-tasks-retry-carries-on-a-stopped-task ()
  "task/retry has the session of a task whose turn failed carry on, told
so by the harness, and the task works again."
  (harness-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
      (let* ((id (harness-tasks-test-submit "will fail once"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :outcome)) 5 "an outcome")
        (should (eq 'needs-input (plist-get (harness-tasks-test-task id) :column)))
        (let ((harness-provider-demo-script-override harness-tasks-test-script))
          ;; It is at work again at once, before its turn starts.
          (should (eq 'active (plist-get (harness-call 'task/retry id) :column)))
          (should-error (harness-call 'task/retry id))
          (harness-tasks-test-wait-state id 'done))
        (should (equal sid (plist-get (harness-tasks-test-task id) :session)))
        (let ((retry (car (last (harness-tasks-test-user-nodes sid)))))
          (should (string-match-p "stopped before the task was finished: it failed with an error\\. Check where"
                                  (plist-get retry :content)))
          (should (equal (harness-sender-system "tasks") (harness-node-sender retry))))
        ;; Done: nothing to retry.
        (should-error (harness-call 'task/retry id))))))

(ert-deftest harness-tasks-retry-follows-where-the-task-stopped ()
  "A pending task starts, a write-up that stopped is written again, a
failed merge is merged again, and a task at work or in review is not
retried."
  (harness-tasks-test-with
    ;; Pending: it starts, whatever the limit says.
    (let ((harness-tasks-max-running 0))
      (let ((id (harness-tasks-test-submit "waits for a slot")))
        (should (eq 'pending (harness-tasks-test-state id)))
        (harness-call 'task/retry id)
        (should (eq 'active (harness-tasks-test-state id)))
        (harness-tasks-test-wait-state id 'done)))
    ;; A write-up that failed is written again.
    (let ((id (let ((harness-provider-demo-script-override
                     '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
                (prog1 (harness-tasks-test-refine "a flaky idea")))))
      (harness-test-wait (lambda () (eq 'error (plist-get (harness-tasks-test-task id) :outcome))) 5 "the error")
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Make the flaky idea solid") (:type done :stop-reason end-turn))))
        (harness-call 'task/retry id)
        (harness-tasks-test-wait-state id 'pending)
        (should (equal "Make the flaky idea solid" (plist-get (harness-tasks-test-task id) :prompt)))))
    ;; A failed merge goes back to the merge queue: here, with no
    ;; worktree, `task/merge' says why it cannot.
    (let ((id (harness-tasks-test-submit "merged badly")))
      (harness-tasks-test-wait-state id 'done)
      (harness-tasks--set id :state 'active :outcome 'merge-failed :error "merge conflict")
      (should (string-match-p "no worktree to merge"
                              (cadr (should-error (harness-call 'task/retry id))))))
    ;; At work.
    (let* ((harness-provider-demo--delay 5)
           (id (harness-tasks-test-submit "busy")))
      (harness-test-wait (lambda () (eq 'active (plist-get (harness-tasks-test-task id) :column))) 5 "at work")
      (should (string-match-p "working already" (cadr (should-error (harness-call 'task/retry id)))))
      (harness-call 'task/cancel id))
    ;; In review.
    (let* ((harness-tasks-require-verification t)
           (id (harness-tasks-test-submit "for review")))
      (harness-tasks-test-wait-state id 'review)
      (should (string-match-p "review" (cadr (should-error (harness-call 'task/retry id))))))))

(ert-deftest harness-tasks-blocked-session-needs-input ()
  (harness-tasks-test-with
    (let ((harness-provider-demo--delay 0.3)
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

(ert-deftest harness-tasks-done-event-says-how ()
  "`task/done' fires once a task becomes done, saying what completed it."
  (harness-tasks-test-with
    (let ((done nil))
      (harness-on 'task/done (lambda (task how) (push (cons (plist-get task :id) how) done)))
      ;; Its turn ended, with nothing to merge or review.
      (let ((id (harness-tasks-test-submit "finish it")))
        (harness-tasks-test-wait-state id 'done)
        (should (equal (list (cons id 'finished)) done))
        (should (eq 'done (plist-get (harness-tasks-test-task id) :column))))
      ;; Marked done by hand, once: completing a done task again says nothing.
      (setq done nil)
      (let ((harness-tasks-max-running 0))
        (let ((id (harness-tasks-test-submit "never mind")))
          (harness-call 'task/complete id)
          (harness-call 'task/complete id)
          (should (equal (list (cons id 'completed)) done))))
      ;; Verified, with nothing to merge.
      (setq done nil)
      (let ((harness-tasks-require-verification t))
        (let ((id (harness-tasks-test-submit "check it")))
          (harness-tasks-test-wait-state id 'review)
          (should (null done))
          (harness-call 'task/verify id)
          (should (equal (list (cons id 'verified)) done)))))))

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

(ert-deftest harness-tasks-settings-report-review ()
  "The settings say whether finished work waits for review; off is false, not nil."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t))
      (should (eq t (plist-get (harness-call 'task/settings default-directory) :require-verification))))
    (let ((harness-tasks-require-verification nil))
      (should (eq :false (plist-get (harness-call 'task/settings default-directory) :require-verification)))
      ;; It stays false over the wire, where nil would be a harness that does not say.
      (let ((conn (harness-acp-connect)))
        (should (eq :false (plist-get (harness-test-await
                                       (harness-acp-request conn "_harness/task/settings"
                                                            (list :cwd default-directory)))
                                      :require-verification)))))))

(ert-deftest harness-tasks-review-turned-off-midway ()
  "Review turned off as the settings page or a board does: work finished after that is done at once.
A task that already waits in review waits on until the user verifies it."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t))
      (cl-letf (((symbol-function 'harness-save-user-option) (lambda (symbol value) (set symbol value))))
        (let ((waiting (harness-tasks-test-submit "first")))
          (harness-tasks-test-wait-state waiting 'review)
          (harness-call 'config/set "harness-tasks-require-verification" "nil" :printed t :scope 'global)
          (should-not harness-tasks-require-verification)
          (let ((later (harness-tasks-test-submit "second")))
            (harness-tasks-test-wait-state later 'done)
            (should-not (plist-get (harness-tasks-test-task later) :verified)))
          (should (eq 'review (harness-tasks-test-state waiting)))
          (harness-call 'task/verify waiting)
          (should (eq 'done (harness-tasks-test-state waiting))))))))

(defvar harness-non-interactive)

(ert-deftest harness-tasks-submit-with-session-settings ()
  (harness-tasks-test-with
    ;; An explicit false is off even where sessions start non-interactive.
    (let* ((harness-non-interactive t)
           (id (plist-get (harness-call 'task/submit default-directory "careful one"
                                        (list :permission-mode "ask" :thinking "high" :non-interactive :false))
                          :id))
           (session (harness-call 'session/get (plist-get (harness-tasks-test-task id) :session))))
      (should (eq 'ask (plist-get session :permission-mode)))
      (should (equal "high" (plist-get session :thinking)))
      (should-not (plist-get session :non-interactive)))))

(ert-deftest harness-tasks-supervisor-setting-without-the-module ()
  "The supervisor setting is a task setting even where no module governs it.
`task/settings' does not carry it, the session gets no `:supervisor' in
its `:ext', and giving it one all the same does not error."
  (harness-tasks-test-with
    (should-not (boundp 'harness-supervisor-tasks))
    (should-not (plist-member (harness-call 'task/settings default-directory) :supervisor))
    (let ((harness-tasks-max-running 0))
      (let ((hands-on (plist-get (harness-call 'task/submit default-directory "hands-on please"
                                               (list :supervisor :false))
                                 :id)))
        (should (eq :false (plist-get (harness-tasks-test-task hands-on) :supervisor)))
        (harness-call 'task/start hands-on)
        (should-not (plist-member (plist-get (harness-tasks-test-session hands-on) :ext)
                                  :supervisor))
        ;; A bulk change records the setting and reaches no session.
        (let ((supervising (plist-get (harness-call 'task/submit default-directory "waiting")
                                      :id)))
          (should (equal (list supervising)
                         (harness-call 'task/set-all (list :supervisor t)
                                       (list :ids (list supervising) :cwd default-directory))))
          (should (eq t (plist-get (harness-tasks-test-task supervising) :supervisor))))
        (harness-tasks-test-wait-state hands-on 'done)))))

(ert-deftest harness-tasks-start-interactive-by-default ()
  "Unless the configuration says otherwise, a new task's session is interactive.
It asks the user for what needs a permission instead of being denied."
  (harness-tasks-test-with
    (let ((harness-tasks-non-interactive (harness-tasks-test-default 'harness-tasks-non-interactive)))
      (should-not harness-tasks-non-interactive)
      (should-not (plist-get (harness-call 'task/settings default-directory) :non-interactive))
      (let* ((id (harness-tasks-test-submit "ask me when you must"))
             (session (harness-tasks-test-session id)))
        (should (eq 'auto (plist-get session :permission-mode)))
        (should-not (plist-get session :non-interactive))
        (harness-tasks-test-wait-state id 'done)))))

(ert-deftest harness-tasks-non-interactive-when-configured ()
  "A directory configured non-interactive starts its tasks non-interactive.
`task/settings', from which the board sets up the next task, says so
too; so does `harness-tasks-non-interactive', wherever the task is."
  (harness-tasks-test-with
    (let ((harness-tasks-non-interactive nil)
          (elsewhere (harness-test-temp-dir)))
      (with-temp-file (expand-file-name ".dir-locals.el" default-directory)
        (insert "((nil . ((harness-non-interactive . t))))\n"))
      (should (eq t (plist-get (harness-call 'task/settings default-directory) :non-interactive)))
      (should-not (plist-get (harness-call 'task/settings elsewhere) :non-interactive))
      (let* ((here (harness-tasks-test-submit "nobody watches this one"))
             (there (harness-tasks-test-submit "ask me about that one" elsewhere)))
        (should (plist-get (harness-tasks-test-session here) :non-interactive))
        (should-not (plist-get (harness-tasks-test-session there) :non-interactive))
        (harness-tasks-test-wait-state here 'done)
        (harness-tasks-test-wait-state there 'done))
      (let ((harness-tasks-non-interactive t))
        (should (eq t (plist-get (harness-call 'task/settings elsewhere) :non-interactive)))
        (let ((id (harness-tasks-test-submit "and this one too" elsewhere)))
          (should (plist-get (harness-tasks-test-session id) :non-interactive))
          (harness-tasks-test-wait-state id 'done))))))

(ert-deftest harness-tasks-adopt-ongoing-session ()
  (harness-tasks-test-with
    (let ((sid (plist-get (harness-call 'session/create :cwd default-directory :model "demo:scripted") :id)))
      (harness-test-await (harness-call-async 'agent/prompt sid "Tidy the imports"))
      (should (member sid (mapcar (lambda (s) (plist-get s :id)) (harness-call 'task/adoptable default-directory))))
      (let* ((task (harness-call 'task/adopt sid))
             (id (plist-get task :id)))
        (should (equal "Tidy the imports" (plist-get task :prompt)))
        (should (equal sid (plist-get task :session)))
        ;; The task's shorter context applies from now on.
        (should (= 384000 (plist-get (harness-call 'session/get sid) :context-window-limit)))
        (should (= 8000 (plist-get (harness-call 'session/get sid) :context-window)))
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
(defvar harness-tasks-resume-interrupted)
(defvar harness-tasks--resume-prompt)
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
    (harness-define-tool "hang" :label "Hang" :description "never returns the first time" :kind 'read
                         :handler (lambda (_input _ctx)
                                    (if (= 1 (cl-incf calls)) (harness-make-promise) "ok")))))

(defun harness-tasks-test--node (sid pred)
  "Return the first node of SID matching PRED."
  (cl-find-if pred (harness-call 'session/nodes sid)))

(defun harness-tasks-test-user-nodes (sid)
  "The user messages of session SID, oldest first."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes sid)))

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
                                                             (equal harness-tasks--resume-prompt (plist-get n :content))))))
      (should (= 2 (cl-count 'user (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind)))))
      ;; The task is the user's; the message that carried it on is the harness's.
      (pcase-let ((`(,task ,resume) (harness-tasks-test-user-nodes sid)))
        (should-not (harness-node-sender task))
        (should (equal harness-tasks--resume-prompt (plist-get resume :content)))
        (should (equal (harness-sender-system "tasks") (harness-node-sender resume)))))))

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
        (harness-tasks-test-wait-state id 'done))
      ;; That reply is the user's own.
      (let ((reply (car (last (harness-tasks-test-user-nodes sid)))))
        (should (equal "carry on" (plist-get reply :content)))
        (should-not (harness-node-sender reply))))))

(ert-deftest harness-tasks-interrupted-while-starting-starts-over ()
  "A task stopped before its work began starts again from scratch.
Its session, made at submission, was never given the task: the restart
sends it the task itself, not a \"carry on\"."
  (harness-tasks-test-with
    (let ((id (let ((harness-tasks-max-running 0)) (harness-tasks-test-submit "barely begun"))))
      ;; Where a start cut short leaves a task: active, its session made
      ;; but never given the work (`harness-tasks--work-begun-p').
      (harness-tasks--set id :state 'active :started (float-time))
      (harness-tasks-test--restart)
      (harness-tasks-test-wait-state id 'done)
      (let ((sid (harness-tasks-test-session-id id)))
        (should sid)
        (should (equal "barely begun"
                       (plist-get (cl-find 'user (harness-call 'session/nodes sid)
                                           :key (lambda (n) (plist-get n :kind)))
                                  :content)))))))

(ert-deftest harness-tasks-recover-leaves-working-tasks-alone ()
  "Tasks this process works on are not interrupted, whatever their state says."
  (harness-tasks-test-with
    (let* ((harness-provider-demo--delay 0.2)
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

(defvar harness-tasks--start-message)

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
        ;; A write-up for the backlog is in the backlog column, not among
        ;; the queued pending tasks the scheduler starts.
        (should (eq 'backlog (plist-get task :column)))
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
        ;; A write-up runs on the task's shorter context too.
        (should (= 384000 (plist-get (harness-call 'session/get sid) :context-window-limit)))
        (should (= 8000 (plist-get (harness-call 'session/get sid) :context-window)))
        (harness-tasks-test-wait-state id 'pending)
        (setq task (harness-tasks-test-task id))
        (should (equal harness-tasks-test-write-up (plist-get task :prompt)))
        (should (plist-get task :refined))
        (should (eq 'pending (plist-get task :state)))
        (should (eq 'backlog (plist-get task :column)))
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
          (should (string-match-p "^> the parser chokes on nested quotes$" (cadr texts))))
        ;; The request is the user's; the harness composed the start message.
        (pcase-let ((`(,request ,start) (harness-tasks-test-user-nodes sid)))
          (should-not (harness-node-sender request))
          (should (equal (harness-sender-system "tasks") (harness-node-sender start))))))))

(ert-deftest harness-tasks-queue-a-backlog-task ()
  "task/queue puts a backlog task back in the queue; a free slot starts it.
Its work still opens with the write-up and the request it came from."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-provider-demo-script-override
           `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn))))
      (let ((id (harness-tasks-test-refine "the parser chokes on nested quotes")))
        (harness-tasks-test-wait-state id 'pending)
        (let ((sid (harness-tasks-test-session-id id)))
          (should (eq 'backlog (plist-get (harness-tasks-test-task id) :column)))
          ;; Queueing hands it to the schedule: pending, not the backlog.
          (harness-call 'task/queue id)
          (should (eq 'pending (harness-tasks-test-state id)))
          (should-not (plist-get (harness-tasks-test-task id) :backlog))
          (should (eq 'pending (plist-get (harness-tasks-test-task id) :column)))
          ;; No slot yet; one frees and the queue starts it on its own,
          ;; with the write-up and the request it came from.
          (setq harness-tasks-max-running nil)
          (harness-tasks--schedule)
          (harness-tasks-test-wait-state id 'done)
          (let ((texts (harness-tasks-test-user-texts sid)))
            (should (= 2 (length texts)))
            (should (string-match-p (regexp-quote harness-tasks-test-write-up) (cadr texts)))
            (should (string-match-p "^> the parser chokes on nested quotes$" (cadr texts)))))))))

;;;; Backlog mode: written-up tasks queued by hand, or by themselves

(defun harness-tasks-test--backlog-mode (&optional cwd)
  "The backlog mode of CWD's project, as `task/settings' says it."
  (plist-get (harness-call 'task/settings (or cwd default-directory)) :backlog-mode))

(defun harness-tasks-test--wait-queued (id)
  "Wait until task ID left the backlog for the pending queue, or went further."
  (harness-test-wait (lambda () (let ((task (harness-tasks-test-task id)))
                                  (and (not (plist-get task :backlog))
                                       (not (eq 'refining (plist-get task :state))))))
                     5 (format "task %s to leave the backlog" id)))

(ert-deftest harness-tasks-backlog-mode-is-manual-by-default ()
  "A project's backlog is queued by hand until it is switched to auto.
The toggle switches it both ways, and manual is the backlog as it always
was: the written-up task waits there, whatever the slots."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running nil)
          (harness-provider-demo-script-override
           `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn))))
      (should (eq 'manual (harness-tasks-test--backlog-mode)))
      (should (eq 'manual (plist-get (harness-call 'task/backlog-mode default-directory) :mode)))
      (should (eq 'auto (plist-get (harness-call 'task/toggle-backlog-mode default-directory) :mode)))
      (should (eq 'auto (harness-tasks-test--backlog-mode)))
      (should (eq 'manual (plist-get (harness-call 'task/toggle-backlog-mode default-directory) :mode)))
      (should (eq 'manual (harness-tasks-test--backlog-mode)))
      (let ((id (harness-tasks-test-refine "the parser chokes on nested quotes")))
        (should-not (plist-get (harness-tasks-test-task id) :auto-queue))
        (harness-tasks-test-wait-state id 'pending)
        ;; Its write-up done, it waits: nothing queues it in manual mode.
        (harness-tasks-test--settle)
        (harness-tasks--schedule)
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'pending (plist-get task :state)))
          (should (plist-get task :backlog))
          (should (eq 'backlog (plist-get task :column))))))))

(ert-deftest harness-tasks-auto-queue-starts-a-written-up-task ()
  "In auto mode a finished write-up queues its task, and the queue starts it.
The work opens with the write-up and the request it came from, as a task
queued by hand does."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 1)
          (harness-provider-demo-script-override
           `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn))))
      (harness-call 'task/set-backlog-mode 'auto default-directory)
      (let* ((id (harness-tasks-test-refine "the parser chokes on nested quotes"))
             (sid (harness-tasks-test-session-id id)))
        ;; Being written up, it is in the backlog, and says it queues itself.
        (should (eq 'backlog (plist-get (harness-tasks-test-task id) :column)))
        (should (plist-get (harness-tasks-test-task id) :auto-queue))
        ;; Written up, it leaves the backlog and the queue starts it.
        (harness-tasks-test-wait-state id 'done)
        (let ((task (harness-tasks-test-task id)))
          (should-not (plist-get task :backlog))
          (should (equal harness-tasks-test-write-up (plist-get task :prompt)))
          (should (plist-get task :refined)))
        (let ((texts (harness-tasks-test-user-texts sid)))
          (should (= 2 (length texts)))
          (should (equal "the parser chokes on nested quotes" (car texts)))
          (should (string-match-p (regexp-quote harness-tasks-test-write-up) (cadr texts)))
          (should (string-match-p "^> the parser chokes on nested quotes$" (cadr texts))))
        ;; The harness composed the start message, as for a task queued by hand.
        (should (equal (harness-sender-system "tasks")
                       (harness-node-sender (cadr (harness-tasks-test-user-nodes sid)))))))))

(ert-deftest harness-tasks-auto-queue-says-the-task-joins-the-queue ()
  "From its write-up's end until it is queued, a task's views say it joins the queue.
So nothing takes the moment it spends in the backlog for a wait there
until someone starts it; queued, it no longer says so."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (views nil)
          (harness-provider-demo-script-override
           `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn))))
      (harness-call 'task/set-backlog-mode 'auto default-directory)
      (let ((id (harness-tasks-test-refine "the parser chokes on nested quotes")))
        (harness-on 'task/changed (lambda (view) (when (equal id (plist-get view :id)) (push view views))))
        (harness-tasks-test--wait-queued id)
        (let ((written-up (cl-remove-if-not (lambda (view) (and (eq 'pending (plist-get view :state))
                                                                (plist-get view :backlog)))
                                            views)))
          (should written-up)
          (dolist (view written-up)
            (should (plist-get view :joining-queue))))
        (should-not (plist-get (car views) :backlog))
        (should-not (plist-get (car views) :joining-queue))
        (should-not (plist-get (harness-tasks-test-task id) :joining-queue))
        (should-not (gethash id harness-tasks--joining))))))

(ert-deftest harness-tasks-auto-queue-keeps-to-the-slots-and-the-suspension ()
  "An auto-queued task waits in Pending like any queued one.
No slot free, it waits; a suspended queue holds it even once a slot is
free; resuming starts it."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-provider-demo-script-override
           `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn))))
      (harness-call 'task/set-backlog-mode "auto" default-directory)
      (let ((id (harness-tasks-test-refine "the parser chokes on nested quotes")))
        (harness-tasks-test--wait-queued id)
        ;; Queued, not started: no slot.
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'pending (plist-get task :state)))
          (should (eq 'pending (plist-get task :column)))
          (should-not (plist-get task :started)))
        ;; A slot, but the queue is suspended: it still waits.
        (harness-call 'task/suspend-queue default-directory)
        (setq harness-tasks-max-running 1)
        (harness-tasks--schedule)
        (should (eq 'pending (harness-tasks-test-state id)))
        ;; Resumed, it starts.
        (harness-call 'task/resume-queue default-directory)
        (should (eq 'active (harness-tasks-test-state id)))
        (harness-tasks-test-wait-state id 'done)))))

(ert-deftest harness-tasks-auto-queue-leaves-what-waits-for-the-user ()
  "Auto mode queues only a write-up that ends cleanly.
A write-up that fails or refuses the task as a duplicate waits for the
user as ever; written up after all, the task is queued.  So is one
written up again after feedback.  Switching to auto queues none of the
tasks already waiting in the backlog."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0) waiting failed refused)
      ;; Written up in manual mode: it waits in the backlog.
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Written up before") (:type done :stop-reason end-turn))))
        (setq waiting (harness-tasks-test-refine "an idea from before"))
        (harness-tasks-test-wait-state waiting 'pending))
      (harness-call 'task/set-backlog-mode 'auto default-directory)
      (harness-tasks-test--settle)
      (should (plist-get (harness-tasks-test-task waiting) :backlog))
      ;; A write-up that fails stays in front of the user.
      (let ((harness-provider-demo-script-override
             '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
        (setq failed (harness-tasks-test-refine "a flaky idea"))
        (harness-test-wait (lambda () (equal "boom" (plist-get (harness-tasks-test-task failed) :error))) 5 "the error"))
      ;; So does one that refuses the task as a duplicate.
      (let ((harness-provider-demo-script-override
             `((:type text :delta ,(format "Duplicate of %s\n\nThe board has it." waiting))
               (:type done :stop-reason end-turn))))
        (setq refused (harness-tasks-test-refine "the idea from before, again"))
        (harness-test-wait (lambda () (eq 'duplicate (plist-get (harness-tasks-test-task refused) :outcome)))
                           5 "the refusal"))
      (harness-tasks-test--settle)
      (dolist (id (list failed refused))
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'refining (plist-get task :state)))
          (should (eq 'needs-input (plist-get task :column)))
          (should (plist-get task :backlog))))
      ;; Retried, written up all the same, and feedback on the one from
      ;; before: every write-up that ends cleanly queues its task.
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Written up now") (:type done :stop-reason end-turn))))
        (harness-call 'task/refine failed)
        (harness-call 'task/refine refused)
        (harness-call 'task/prompt waiting "mention the docs too")
        (dolist (id (list failed refused waiting))
          (harness-tasks-test--wait-queued id)
          (let ((task (harness-tasks-test-task id)))
            (should (eq 'pending (plist-get task :state)))
            (should (eq 'pending (plist-get task :column)))
            (should (equal "Written up now" (plist-get task :prompt)))))))))

(ert-deftest harness-tasks-auto-queue-waits-for-queued-feedback ()
  "Feedback queued for a write-up that is running is written up before the task queues.
The write-up's end leaves the task in the backlog while its session has
messages queued: they start another write-up, whose end queues it.  It
never starts in the session that writes it up."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-provider-demo-script-override
           '((:type wait :seconds 0.3) (:type text :delta "Written up") (:type done :stop-reason end-turn))))
      (harness-call 'task/set-backlog-mode 'auto default-directory)
      (let* ((views nil)
             (id (harness-tasks-test-refine "an idea"))
             (sid (harness-tasks-test-session-id id)))
        (harness-on 'task/changed (lambda (view) (when (equal id (plist-get view :id)) (push view views))))
        (harness-test-wait (lambda () (harness-call 'agent/running sid)) 5 "the write-up to run")
        (harness-call 'session/queue sid "and mention the docs")
        (harness-tasks-test--wait-queued id)
        ;; Left in the backlog by the first write-up's end, it was
        ;; announced so: not joining the queue then.
        (should (cl-some (lambda (view) (and (eq 'pending (plist-get view :state)) (plist-get view :backlog)
                                             (not (plist-get view :joining-queue))))
                         views))
        ;; Nothing more runs in its session once it is queued: no slot
        ;; starts it, and no feedback is left to take a turn of its own.
        (let ((deadline (+ (float-time) 0.6)))
          (while (< (float-time) deadline)
            (accept-process-output nil 0.05)))
        (should-not (harness-call 'agent/running sid))
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'pending (plist-get task :state)))
          (should (eq 'pending (plist-get task :column)))
          (should-not (plist-get task :started)))
        ;; Both the request and the queued feedback were written up.
        (should (equal '("an idea" "and mention the docs") (harness-tasks-test-user-texts sid)))))))

(ert-deftest harness-tasks-backlog-mode-is-kept-per-project ()
  "A project's backlog mode is its own, and outlives a restart."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let ((other (harness-test-temp-dir))
          (file (expand-file-name "task-auto-queue.json" harness-state-directory)))
      (harness-call 'task/set-backlog-mode 'auto default-directory)
      (should (file-exists-p file))
      (should-error (harness-call 'task/set-backlog-mode "sometimes" default-directory))
      (harness-tasks-test--restart)
      (should (eq 'auto (harness-tasks-test--backlog-mode)))
      (should (eq 'manual (harness-tasks-test--backlog-mode other)))
      ;; It still works after the restart: a write-up queues its task.
      (let ((harness-tasks-max-running 0)
            (harness-provider-demo-script-override
             '((:type text :delta "Written up") (:type done :stop-reason end-turn))))
        (let ((id (harness-tasks-test-refine "after the restart")))
          (harness-tasks-test--wait-queued id)
          (should (eq 'pending (plist-get (harness-tasks-test-task id) :column)))))
      ;; Back to manual: nothing is left in the file, which goes.
      (harness-call 'task/set-backlog-mode 'manual default-directory)
      (should-not (file-exists-p file))
      (harness-tasks-test--restart)
      (should (eq 'manual (harness-tasks-test--backlog-mode))))))

(ert-deftest harness-tasks-backlog-mode-change-is-announced ()
  "Switching the mode emits `task/backlog-mode' (PROJECT MODE); setting it again does not."
  (harness-tasks-test-with
    (let ((seen nil)
          (project (harness-tasks--project default-directory)))
      (harness-on 'task/backlog-mode (lambda (p mode) (push (list p mode) seen)))
      (harness-call 'task/set-backlog-mode 'auto default-directory)
      (harness-call 'task/set-backlog-mode 'auto default-directory)
      (harness-call 'task/toggle-backlog-mode default-directory)
      (should (equal (list (list project 'manual) (list project 'auto)) seen)))))

(ert-deftest harness-tasks-backlog-work-is-interactive-by-default ()
  "A write-up is non-interactive, to keep it read-only; the work it leads to is not."
  (harness-tasks-test-with
    (let ((harness-tasks-non-interactive (harness-tasks-test-default 'harness-tasks-non-interactive))
          (harness-tasks-max-running nil)
          (harness-provider-demo-script-override
           `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn))))
      (let ((id (harness-tasks-test-refine "the parser chokes on nested quotes")))
        (should (plist-get (harness-tasks-test-session id) :non-interactive))
        (harness-tasks-test-wait-state id 'pending)
        (harness-call 'task/start id)
        (should-not (plist-get (harness-tasks-test-session id) :non-interactive))
        (harness-tasks-test-wait-state id 'done)))))

(ert-deftest harness-tasks-backlog-is-its-own-column ()
  "A backlog task's column is the backlog, not the queued pending one.
Its state stays pending and its `:backlog' set, so the scheduler still
never starts it and `task/start' still does; a bulk change, which
reaches the current tasks, still reaches it by its column."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-provider-demo-script-override
           '((:type text :delta "Fix the lexer\n\nHandle nested quotes.") (:type done :stop-reason end-turn))))
      (let ((queued (harness-tasks-test-submit "waits for a slot"))
            (id (harness-tasks-test-refine "jot this down")))
        (harness-tasks-test-wait-state id 'pending)
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'pending (plist-get task :state)))
          (should (plist-get task :backlog))
          (should (eq 'backlog (plist-get task :column))))
        (should (eq 'pending (plist-get (harness-tasks-test-task queued) :column)))
        ;; Free slots start the queued one -- and never the backlog.
        (harness-tasks--schedule)
        (should (eq 'pending (harness-tasks-test-state id)))
        (should (member id (harness-call 'task/set-all (list :model "demo:other"))))
        (should (member id (harness-call 'task/set-all (list :thinking "high")
                                         (list :columns '(backlog) :cwd default-directory))))))))

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
          (should-not (plist-get (harness-tasks-test-task id) :outcome)))
        ;; The idea is the user's; the harness asked for the write-up again.
        (let ((users (harness-tasks-test-user-nodes (plist-get (harness-tasks-test-task id) :session))))
          (should (= 3 (length users)))
          (should-not (harness-node-sender (car users)))
          (dolist (again (cdr users))
            (should (equal (harness-sender-system "tasks") (harness-node-sender again)))))))))

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
  "A queued task written up by hand is written up in the session it has.
Every task has one from submission, idle and holding its priority; the
write-up goes to it, not to a new one."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0)
          (harness-provider-demo-script-override
           '((:type text :delta "Queued, then written up") (:type done :stop-reason end-turn))))
      (let* ((id (harness-tasks-test-submit "a queued idea"))
             (sid (harness-tasks-test-session-id id)))
        (should sid)
        (should (eq 'idle (plist-get (harness-tasks-test-session id) :status)))
        (harness-call 'task/refine id)
        (harness-test-wait (lambda () (equal "Queued, then written up" (plist-get (harness-tasks-test-task id) :prompt)))
                           5 "the write-up")
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'pending (plist-get task :state)))
          (should (plist-get task :backlog))
          (should (equal "a queued idea" (plist-get task :note)))
          ;; The write-up ran in the task's own session, which keeps the
          ;; prompt written up for when the work starts.
          (should (equal sid (plist-get task :session))))
        (should-error (harness-call 'task/refine "t-nonexistent"))))))

(defvar harness-tasks--refine-tool-calls)

(ert-deftest harness-tasks-refine-told-to-finish-after-enough-calls ()
  "A write-up that keeps looking around is steered, once, to write it up."
  (harness-tasks-test-with
    (let ((harness-tasks--refine-tool-calls 2)
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
          (should (string-match-p "enough looking" (plist-get (car steers) :content)))
          (should (equal (harness-sender-system "tasks") (harness-node-sender (car steers)))))))))

(defvar harness-perms-auto-model)

(ert-deftest harness-tasks-write-up-only-reads ()
  "A backlog write-up reads and does nothing else.  Its session is
non-interactive, where the judge decides what would ask the user, but
the write-up's own stage denies that first; once the task starts, the
judge decides the work's calls."
  (harness-tasks-test-with
    (harness-test-load-module 'perms)
    ;; The real permission chain, without this suite's allow-everything stage.
    (dolist (stage (gethash 'permission/decide harness--filters))
      (unless (symbolp (cdr stage)) (harness-remove-filter 'permission/decide (cdr stage))))
    (let* ((judged nil)
           (harness-perms-auto-model "judge:small")
           (harness-provider-demo-script-override
            `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn)))
           (id (harness-tasks-test-refine "the parser chokes on nested quotes"))
           (sid (plist-get (harness-tasks-test-task id) :session))
           (decide (lambda (tool kind &rest paths)
                     (harness-test-await
                      (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                                (list :session (harness-call 'session/get sid) :tool tool :kind kind
                                                      :input nil :paths paths :call-id (harness-short-id)))))))
      (harness-define-provider 'judge :label "Judge"
        :complete (lambda (req)
                    (push req judged)
                    (let ((cb (plist-get req :on-event)))
                      (run-at-time 0.01 nil (lambda ()
                                              (funcall cb '(:type text :delta "{\"decision\":\"allow\",\"reason\":\"fine\"}"))
                                              (funcall cb '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore)))
      ;; Being written up, then waiting in the backlog with that session.
      (dolist (state '(refining pending))
        (when (eq state 'pending) (harness-tasks-test-wait-state id 'pending))
        (let ((d (funcall decide "bash" 'exec)))
          (should (eq 'deny (plist-get d :behavior)))
          (should (plist-get d :final))
          (should (string-match-p "only reads" (plist-get d :reason)))
          (should (equal harness-tasks--write-up-hint (plist-get d :hint))))
        (should (eq 'allow (plist-get (funcall decide "read_file" 'read (expand-file-name "f" default-directory))
                                      :behavior))))
      (should-not judged)
      ;; Started, the session does the work: the judge decides.
      (harness-call 'task/start id)
      (should (eq 'allow (plist-get (funcall decide "bash" 'exec) :behavior)))
      (should judged))))

;;;; Plan mode: a strong model plans, a medium one does the work
;;
;; Submitted with :plan, a task is planned by a read-only session on the
;; hard tier of the task model's provider, which hands the plan in with
;; submit_task_plan; the work then runs on the medium tier.

(defvar harness-tasks--plan-tier)
(defvar harness-tasks--plan-work-tier)
(defvar harness-tasks--plan-tool-calls)
(defvar harness-tasks-refine-model)
(defvar harness-tasks-refine-thinking)
(defvar harness-tasks-thinking)
(defvar harness-tasks--plan-prompt)
(defvar harness-tasks--plan-reminder)
(defvar harness-tasks--plan-start-message)
(defvar harness-tasks--plan-hint)
(defvar harness-tasks--refine-prompt)
(defvar harness-tools-agent-planning-section)
(declare-function harness-tasks--plan-model "harness-tasks")
(declare-function harness-tasks--plan-thinking "harness-tasks")
(declare-function harness-tasks--plan-work "harness-tasks")
(declare-function harness-tasks--refine-settings "harness-tasks")
(declare-function harness-provider-demo--complete "harness-provider-demo")
(declare-function harness-provider-demo--last-user-text "harness-provider-demo")

(defconst harness-tasks-test-plan-title "Fix nested quotes in the parser")

(defconst harness-tasks-test-plan
  "## Goal\nNested quotes parse.\n\n## Steps\n1. Handle them in `parse-args'.\n\n## Verify\nThe quote tests pass.")

(defun harness-tasks-test-plan-script (request)
  "Hand the plan in when REQUEST plans a task; otherwise just work."
  (if (string-match-p "^## Task planning" (or (plist-get request :system) ""))
      `((:type tool-call :id "p1" :name "submit_task_plan"
               :input (:title ,harness-tasks-test-plan-title :plan ,harness-tasks-test-plan))
        (:type text :delta "Handed in.")
        (:type done :stop-reason end-turn))
    harness-tasks-test-script))

(defmacro harness-tasks-test-with-plans (&rest body)
  "Run BODY in `harness-tasks-test-with', set up for Plan mode.
Provider `test-plan' plays the demo's scripts.  Its hard tier is its
model big, at high thinking, its medium tier mid, and the task model is
its small.  The readonly module holds a plan read-only, and the session
tools give it `submit_task_plan'."
  (declare (indent 0))
  `(harness-tasks-test-with
     (harness-test-load-module 'readonly)
     (harness-test-load-module 'tools-sessions)
     (unwind-protect
         (progn
           (harness-define-provider 'test-plan
             :complete #'harness-provider-demo--complete
             :tiers '(:hard (:model "big" :thinking "high") :medium "mid")
             :models (lambda ()
                       (harness-resolved
                        (mapcar (lambda (name) (list :name name :thinking-levels '("low" "medium" "high")))
                                '("big" "mid" "small")))))
           (let ((harness-tasks-model "test-plan:small"))
             ,@body))
       (remhash 'test-plan harness-providers)
       (harness-provider--forget 'test-plan))))

(defun harness-tasks-test-plan-submit (prompt &rest opts)
  "Submit PROMPT to be planned, with OPTS besides; return the task id."
  (plist-get (harness-call 'task/submit default-directory prompt (append (list :plan t) opts)) :id))

(defun harness-tasks-test-steering (sid)
  "The steering messages of session SID, oldest first."
  (cl-remove-if-not (lambda (n) (and (eq (plist-get n :kind) 'user)
                                     (plist-get (plist-get n :meta) :steering)))
                    (harness-call 'session/nodes sid)))

(ert-deftest harness-tasks-plan-hands-in-then-waits ()
  "A planned task is planned on the hard tier, read-only, and waits in the
backlog with the plan; started, it works on the medium tier from it."
  (harness-tasks-test-with-plans
    (let ((harness-tasks-max-running nil)
          (harness-provider-demo-script-override #'harness-tasks-test-plan-script))
      (let* ((id (harness-tasks-test-plan-submit "  the parser chokes on nested quotes  "))
             (task (harness-tasks-test-task id))
             (sid (plist-get task :session)))
        (should (eq 'refining (plist-get task :state)))
        (should (eq 'backlog (plist-get task :column)))
        (should (eq t (plist-get task :plan)))
        (should (equal "the parser chokes on nested quotes" (plist-get task :note)))
        ;; The work is to run on the medium tier, the model the plan is for.
        (should (equal "test-plan:mid" (plist-get task :model)))
        (let ((session (harness-call 'session/get sid)))
          ;; Planned on the hard tier, at the level the provider runs it,
          ;; asking with nobody to ask: reads only.
          (should (equal "test-plan:big" (plist-get session :model)))
          (should (equal "high" (plist-get session :thinking)))
          (should (eq 'ask (plist-get session :permission-mode)))
          (should (plist-get session :non-interactive))
          (let ((prompt (harness-run-filter 'agent/system-prompt "" session)))
            (should (string-match-p "^## Task planning" prompt))
            (should-not (string-match-p "## Task refinement" prompt)))
          ;; Only the reading tools, the plan's own and the todo list.
          (let ((tools (harness-run-filter 'agent/tools
                                           '("read_file" "grep" "write_file" "edit_file" "hand_in"
                                             "web_fetch" "web_search" "submit_task_plan" "todo_write")
                                           session)))
            (should (equal '("read_file" "grep" "web_search" "submit_task_plan" "todo_write") tools))))
        (harness-tasks-test-wait-state id 'pending)
        (setq task (harness-tasks-test-task id))
        (should (equal (concat harness-tasks-test-plan-title "\n\n" harness-tasks-test-plan)
                       (plist-get task :prompt)))
        (should (plist-get task :refined))
        (should (eq 'backlog (plist-get task :column)))
        (should-not (plist-get task :outcome))
        ;; The plan shows in the transcript as a plan does.
        (let ((plan (cl-find 'plan (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind)))))
          (should (equal harness-tasks-test-plan (plist-get plan :content)))
          (should (equal harness-tasks-test-plan-title (plist-get plan :title))))
        ;; Free slots do not start it; the user does.
        (harness-tasks--schedule)
        (should (eq 'pending (harness-tasks-test-state id)))
        (harness-call 'task/start id)
        (harness-tasks-test-wait-state id 'done)
        (let ((session (harness-call 'session/get sid)))
          (should (equal "test-plan:mid" (plist-get session :model)))
          (should (eq 'auto (plist-get session :permission-mode)))
          (should-not (equal "high" (plist-get session :thinking)))
          (should-not (string-match-p "## Task planning" (harness-run-filter 'agent/system-prompt "" session)))
          ;; A started task has every tool again, and not the plan's.
          (should (equal '("write_file" "hand_in")
                         (harness-run-filter 'agent/tools '("write_file" "hand_in" "submit_task_plan") session))))
        ;; The work starts from the plan, then the request it came from.
        (let ((start (cadr (harness-tasks-test-user-texts sid))))
          (should (string-prefix-p harness-tasks--plan-start-message start))
          (should (string-match-p (regexp-quote harness-tasks-test-plan) start))
          (should (string-match-p "^> the parser chokes on nested quotes$" start)))))))

(ert-deftest harness-tasks-plan-models ()
  "The models and thinking levels of a plan and of the work after it.
By default they are tiers of the task model's provider, else that
model; a task's own choices win, and `task/settings' reports what a new
task would get."
  (harness-tasks-test-with-plans
    (let ((task (list :cwd default-directory)))
      (should (equal "test-plan:big" (harness-tasks--plan-model task)))
      (should (equal "high" (harness-tasks--plan-thinking task)))
      (should (equal '("test-plan:mid" . nil) (harness-tasks--plan-work task)))
      ;; The task's own model is the one whose provider's tiers count:
      ;; the demo provider's one model is every tier of its own.
      (should (equal "demo:scripted" (harness-tasks--plan-model (list :model "demo:scripted"))))
      (should (equal '("demo:scripted" . nil) (harness-tasks--plan-work (list :model "demo:scripted"))))
      ;; Without a level of the tier's, the task's own, else the task default.
      (should (equal "low" (harness-tasks--plan-thinking (list :model "demo:scripted" :thinking "low"))))
      (let ((harness-tasks-thinking "medium"))
        (should (equal "medium" (harness-tasks--plan-thinking (list :model "demo:scripted")))))
      ;; A tier the provider has no model for leaves the task's own:
      ;; none of test-plan's models has a price to rank it by.
      (let ((harness-tasks--plan-tier 'frontier) (harness-tasks--plan-work-tier 'simple))
        (should (equal "test-plan:small" (harness-tasks--plan-model task)))
        (should (equal '(nil . nil) (harness-tasks--plan-work task))))
      ;; Without a model, no tier either.
      (let ((harness-tasks-model nil) (harness-model nil))
        (should-not (harness-tasks--plan-model (list :cwd default-directory)))
        (should (equal '(nil . nil) (harness-tasks--plan-work (list :cwd default-directory))))))
    ;; What the board shows above a new task.
    (let ((settings (harness-call 'task/settings default-directory)))
      (should (equal "test-plan:small" (plist-get settings :model)))
      (should (equal "test-plan:small" (plist-get settings :refine-model)))
      (should (equal "low" (plist-get settings :refine-thinking)))
      (should (equal "test-plan:big" (plist-get settings :plan-model)))
      (should (equal "high" (plist-get settings :plan-thinking)))
      (should (equal "test-plan:mid" (plist-get settings :plan-work-model))))
    (let ((harness-tasks-refine-model "demo:scripted") (harness-tasks-refine-thinking "low"))
      (let ((settings (harness-call 'task/settings default-directory)))
        (should (equal "demo:scripted" (plist-get settings :refine-model)))
        (should (equal "low" (plist-get settings :refine-thinking)))))
    ;; A task submitted with models of its own keeps them: the work's,
    ;; and the plan's (or a write-up's).
    (let ((harness-tasks-max-running 0)
          (harness-provider-demo-script-override '((:type text :delta "Thinking about it"))))
      (let ((id (harness-tasks-test-plan-submit "own models" :model "test-plan:small" :thinking "low"
                                                :refine-model "demo:scripted" :refine-thinking "high")))
        (should (equal "test-plan:small" (plist-get (harness-tasks-test-task id) :model)))
        (should (equal "low" (plist-get (harness-tasks-test-task id) :thinking)))
        (let ((session (harness-tasks-test-session id)))
          (should (equal "demo:scripted" (plist-get session :model)))
          (should (equal "high" (plist-get session :thinking))))
        (harness-call 'task/cancel id))
      (let* ((id (plist-get (harness-call 'task/submit default-directory "brief"
                                          (list :refine t :refine-model "demo:scripted"))
                            :id))
             (task (harness-tasks-test-task id)))
        (should-not (plist-get task :plan))
        (should (equal "demo:scripted" (plist-get (harness-tasks-test-session id) :model)))
        ;; A brief write-up's work keeps the task model.
        (should-not (plist-get task :model))
        (harness-call 'task/cancel id)))))

(ert-deftest harness-tasks-plan-only-reads ()
  "A plan reads, and hands itself in; nothing else, whatever would ask.
Read-only bash runs where the sandbox confines it.  A brief write-up
cannot hand in a plan."
  (harness-tasks-test-with-plans
    (harness-test-load-module 'perms)
    ;; The real permission chain, without this suite's allow-everything stage.
    (dolist (stage (gethash 'permission/decide harness--filters))
      (unless (symbolp (cdr stage)) (harness-remove-filter 'permission/decide (cdr stage))))
    (let* ((harness-provider-demo-script-override #'harness-tasks-test-plan-script)
           (id (harness-tasks-test-plan-submit "the parser chokes on nested quotes"))
           (confined nil)
           (decide (lambda (task-id tool kind &rest paths)
                     (let ((sid (harness-tasks-test-session-id task-id)))
                       (harness-test-await
                        (harness-run-filter-async 'permission/decide (list :behavior 'ask)
                                                  (list :session (harness-call 'session/get sid) :tool tool
                                                        :kind kind :input nil :paths paths
                                                        :call-id (harness-short-id))))))))
      (harness-register-method 'sandbox/confined-p (lambda (_dir) confined))
      (harness-tasks-test-wait-state id 'pending)
      ;; The plan's own tool is allowed, though ask mode would ask.
      (should (eq 'allow (plist-get (funcall decide id "submit_task_plan" 'meta) :behavior)))
      (should (eq 'allow (plist-get (funcall decide id "read_file" 'read (expand-file-name "f" default-directory))
                                    :behavior)))
      ;; Anything else is denied, for good, with the plan's hint.
      (let ((d (funcall decide id "write_file" 'write (expand-file-name "f" default-directory))))
        (should (eq 'deny (plist-get d :behavior)))
        (should (plist-get d :final))
        (should (string-match-p "plan mode: this session plans the task" (plist-get d :reason)))
        (should (equal harness-tasks--plan-hint (plist-get d :hint))))
      ;; Bash only where the sandbox confines it, and then it runs.
      (let ((d (funcall decide id "bash" 'exec)))
        (should (eq 'deny (plist-get d :behavior)))
        (should (string-match-p "needs the sandbox" (plist-get d :reason))))
      (setq confined t)
      (should (eq 'allow (plist-get (funcall decide id "bash" 'exec) :behavior)))
      (should (equal '(:read-only t :network nil)
                     (harness-run-filter 'tools/sandbox-options nil (harness-tasks-test-session-id id))))
      ;; A brief write-up hands no plan in.
      (let* ((harness-provider-demo-script-override
              `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn)))
             (brief (harness-tasks-test-refine "a brief one")))
        (harness-tasks-test-wait-state brief 'pending)
        (should (eq 'deny (plist-get (funcall decide brief "submit_task_plan" 'meta) :behavior)))
        (should-not (member "submit_task_plan"
                            (harness-run-filter 'agent/tools '("read_file" "submit_task_plan")
                                                (harness-tasks-test-session brief))))
        (should-error (harness-call 'task/hand-in-plan (harness-tasks-test-session-id brief) "T" "plan"))))))

(ert-deftest harness-tasks-plan-told-to-hand-in ()
  "A plan that keeps reading is nudged at its budget, then every half budget."
  (harness-tasks-test-with-plans
    (let ((harness-tasks--plan-tool-calls 4)
          (harness-provider-demo-script-override
           `(,@(mapcar (lambda (n) `(:type tool-call :id ,(format "r%d" n) :name "peek" :input (:n ,n)))
                       (number-sequence 1 7))
             (:type tool-call :id "p1" :name "submit_task_plan"
                    :input (:title ,harness-tasks-test-plan-title :plan ,harness-tasks-test-plan))
             (:type done :stop-reason end-turn))))
      (let* ((id (harness-tasks-test-plan-submit "a curious idea"))
             (sid (harness-tasks-test-session-id id)))
        (harness-tasks-test-wait-state id 'pending)
        (should (string-prefix-p harness-tasks-test-plan-title (plist-get (harness-tasks-test-task id) :prompt)))
        (let ((steers (harness-tasks-test-steering sid)))
          (should (equal '("4 tool calls so far" "6 tool calls so far")
                         (mapcar (lambda (n) (car (split-string (plist-get n :content) ":"))) steers)))
          (should (string-match-p "submit_task_plan" (plist-get (car steers) :content)))
          (should (equal (harness-sender-system "tasks") (harness-node-sender (car steers)))))))))

(ert-deftest harness-tasks-plan-sent-back-to-hand-in ()
  "A plan that stops without handing itself in is sent back, twice at most.
Then its last reply is the plan, as a write-up's is.  A reply refusing
the task as a duplicate is not sent back."
  (harness-tasks-test-with-plans
    ;; It never hands in: two reminders, then the reply stands.
    (let ((harness-provider-demo-script-override
           '((:type text :delta "Plan: do it carefully") (:type done :stop-reason end-turn))))
      (let* ((id (harness-tasks-test-plan-submit "an idea"))
             (sid (harness-tasks-test-session-id id)))
        (harness-tasks-test-wait-state id 'pending)
        (should (equal "Plan: do it carefully" (plist-get (harness-tasks-test-task id) :prompt)))
        (let ((steers (harness-tasks-test-steering sid)))
          (should (= 2 (length steers)))
          (dolist (steer steers)
            (should (equal harness-tasks--plan-reminder (plist-get steer :content)))
            (should (equal (harness-sender-system "tasks") (harness-node-sender steer)))))))
    ;; Reminded once, it hands the plan in.
    (let* ((reminded nil)
           (harness-provider-demo-script-override
            (lambda (request)
              (if (string-match-p (regexp-quote harness-tasks--plan-reminder)
                                  (harness-provider-demo--last-user-text request))
                  (progn (setq reminded t) (harness-tasks-test-plan-script request))
                '((:type text :delta "I would rather chat") (:type done :stop-reason end-turn))))))
      (let ((id (harness-tasks-test-plan-submit "another idea")))
        (harness-tasks-test-wait-state id 'pending)
        (should reminded)
        (should (= 1 (length (harness-tasks-test-steering (harness-tasks-test-session-id id)))))
        (should (equal (concat harness-tasks-test-plan-title "\n\n" harness-tasks-test-plan)
                       (plist-get (harness-tasks-test-task id) :prompt)))))
    ;; A duplicate is refused, not reminded.
    (let ((harness-provider-demo-script-override
           '((:type text :delta "Duplicate of t-abc12345\n\nThe board has it.") (:type done :stop-reason end-turn))))
      (let ((id (harness-tasks-test-plan-submit "a third idea")))
        (harness-test-wait (lambda () (eq 'duplicate (plist-get (harness-tasks-test-task id) :outcome)))
                           5 "the refusal")
        (should-not (harness-tasks-test-steering (harness-tasks-test-session-id id)))))))

(ert-deftest harness-tasks-plan-feedback-replans ()
  "Feedback on a planned task goes to the session that planned it, which
hands in the whole plan again: the new one replaces the old."
  (harness-tasks-test-with-plans
    (let ((harness-provider-demo-script-override
           ;; The plan is for what the last message asked.
           (lambda (request)
             `((:type tool-call :id "p1" :name "submit_task_plan"
                      :input (:title "Do it"
                              :plan ,(concat "For: " (harness-provider-demo--last-user-text request))))
               (:type done :stop-reason end-turn)))))
      (let* ((id (harness-tasks-test-plan-submit "an idea"))
             (sid (harness-tasks-test-session-id id)))
        (harness-tasks-test-wait-state id 'pending)
        (should (equal "Do it\n\nFor: an idea" (plist-get (harness-tasks-test-task id) :prompt)))
        (harness-call 'task/prompt id "mention the docs too")
        (harness-test-wait (lambda () (equal "Do it\n\nFor: mention the docs too"
                                             (plist-get (harness-tasks-test-task id) :prompt)))
                           5 "the new plan")
        (should (eq 'pending (harness-tasks-test-state id)))
        (should (plist-get (harness-tasks-test-task id) :backlog))
        (should (= 2 (cl-count 'plan (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind)))))
        ;; It planned on the hard tier both times.
        (should (equal "test-plan:big" (plist-get (harness-call 'session/get sid) :model)))))))

(ert-deftest harness-tasks-write-ups-replace-the-planning-section ()
  "A write-up or a plan reads only, so the Planning section, about plans
and sub-agents of its own, gives way to the section saying what it does."
  (harness-tasks-test-with-plans
    (harness-test-load-module 'tools-agent)
    (let ((harness-provider-demo-script-override '((:type text :delta "Thinking about it"))))
      (let ((plan (harness-tasks-test-plan-submit "an idea"))
            (brief (harness-tasks-test-refine "a brief one")))
        (dolist (case `((,plan "## Task planning") (,brief "## Task refinement")))
          (let ((prompt (harness-run-filter 'agent/system-prompt "Base."
                                            (harness-tasks-test-session (car case)))))
            (should (string-prefix-p "Base." prompt))
            (should (string-match-p (concat "^" (cadr case)) prompt))
            (should-not (string-search harness-tools-agent-planning-section prompt))))
        (harness-call 'task/cancel plan)
        (harness-call 'task/cancel brief)))))

;;;; Duplicates: the write-up looks at the board first

(defvar harness-tasks--refine-anyway-text)
(declare-function harness-tasks--refusal "harness-tasks")
(declare-function harness-tasks--duplicate-of "harness-tasks")

(ert-deftest harness-tasks-refusal-is-the-first-line ()
  "A reply refuses its task as a duplicate by its first line alone: Duplicate of ID."
  (harness-tasks-test-with
    (should (equal '("t-abc12345" . "The board has it: Add CSV export, in review.")
                   (harness-tasks--refusal "Duplicate of t-abc12345\n\nThe board has it: Add CSV export, in review.")))
    ;; Markdown around it, the word task or a full stop change nothing.
    (should (equal '("t-abc12345" . "Same export.")
                   (harness-tasks--refusal "  **Duplicate of `t-abc12345`.**\n\nSame export.")))
    (should (equal "t-abc12345" (car (harness-tasks--refusal "duplicate of task t-abc12345"))))
    ;; With nothing after it, the line is the message, without its markup.
    (should (equal '("t-abc12345" . "Duplicate of t-abc12345: Add CSV export")
                   (harness-tasks--refusal "# Duplicate of t-abc12345: Add CSV export")))
    ;; Write-ups that speak of duplicates are write-ups.
    (should-not (harness-tasks--refusal "Fix duplicate rows in the export\n\nDuplicate of t-abc12345 was wrong."))
    (should-not (harness-tasks--refusal "Not a duplicate of t-abc12345"))
    (should-not (harness-tasks--refusal "Duplicate of"))
    (should-not (harness-tasks--refusal nil))))

(ert-deftest harness-tasks-refine-refuses-a-duplicate ()
  "A write-up that finds the same task on the board refuses it: the task waits for the user.
Written up all the same, it goes to the backlog."
  (harness-tasks-test-with
    (let* ((harness-tasks-max-running nil)
           (harness-provider-demo-script-override
            '((:type text :delta "Add CSV export to reports\n\nExport the report table as CSV.")
              (:type done :stop-reason end-turn)))
           (first (harness-tasks-test-refine "csv export for the reports page")))
      (harness-tasks-test-wait-state first 'pending)
      (let* ((why "The board has this already: “Add CSV export to reports”, waiting in the backlog.")
             (harness-provider-demo-script-override
              `((:type text :delta ,(format "Duplicate of %s\n\n%s" first why)) (:type done :stop-reason end-turn)))
             (id (harness-tasks-test-refine "export the reports as csv"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        ;; It was told to look at the board first, how to refuse, and how a
        ;; write-up names the tasks working on the same code to coordinate with.
        (let ((system (harness-run-filter 'agent/system-prompt "" (harness-call 'session/get sid))))
          (should (string-match-p "call task_list once" system))
          (should (string-match-p "\"Duplicate of ID\"" system))
          (should (string-match-p "Related tasks" system))
          (should (string-match-p "session_send" system))
          (should (string-match-p "cherry-pick" system)))
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :outcome)) 5 "the refusal")
        (cl-flet ((check ()
                    (let ((task (harness-tasks-test-task id)))
                      (should (eq 'refining (plist-get task :state)))
                      (should (eq 'duplicate (plist-get task :outcome)))
                      (should (eq 'needs-input (plist-get task :column)))
                      (should (equal first (plist-get task :duplicate-of)))
                      (should (equal why (plist-get task :error)))
                      ;; Not written up: its prompt is still the request.
                      (should (equal "export the reports as csv" (plist-get task :prompt)))
                      (should-not (plist-get task :refined)))))
          (check)
          ;; Nothing takes it up again by itself, a restart included.
          (harness-tasks--schedule)
          (harness-tasks-test--restart)
          (check))
        ;; What a refusal names: another task, by its id or the start of it.
        (let ((task (harness-tasks-test-task id)))
          (should (equal first (harness-tasks--duplicate-of task (substring first 0 -1))))
          (should-not (harness-tasks--duplicate-of task id))
          (should-not (harness-tasks--duplicate-of task "t-nosuch00")))
        ;; Written up all the same, it waits in the backlog like any other.
        (let ((harness-provider-demo-script-override
               '((:type text :delta "Export reports as CSV\n\nRelated: the CSV export in the backlog.")
                 (:type done :stop-reason end-turn))))
          (harness-call 'task/refine id)
          (harness-tasks-test-wait-state id 'pending))
        (let ((task (harness-tasks-test-task id)))
          (should (equal "Export reports as CSV\n\nRelated: the CSV export in the backlog." (plist-get task :prompt)))
          (should (plist-get task :backlog))
          (should (plist-get task :refined))
          (should-not (plist-get task :outcome))
          (should-not (plist-get task :error))
          (should-not (plist-get task :duplicate-of)))
        ;; It was told that the user wants it after all.
        (should (equal harness-tasks--refine-anyway-text (car (last (harness-tasks-test-user-texts sid)))))
        ;; Starting the work passes the nudge to coordinate on to whoever does it.
        (harness-call 'task/start id)
        (harness-tasks-test-wait-state id 'done)
        (should (string-prefix-p harness-tasks--start-message (nth 2 (harness-tasks-test-user-texts sid))))
        (should (string-match-p "coordinate" (nth 2 (harness-tasks-test-user-texts sid))))))))

(ert-deftest harness-tasks-write-up-opening-duplicate-of ()
  "A write-up that merely opens \"Duplicate of a task …\" is written up, not refused."
  (harness-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type text :delta "Duplicate of a task should not crash\n\nGuard the lookup.")
             (:type done :stop-reason end-turn))))
      (let ((id (harness-tasks-test-refine "duplicates crash the lookup")))
        (harness-tasks-test-wait-state id 'pending)
        (let ((task (harness-tasks-test-task id)))
          (should (equal "Duplicate of a task should not crash\n\nGuard the lookup." (plist-get task :prompt)))
          (should-not (plist-get task :outcome))
          (should-not (plist-get task :duplicate-of)))))))

(ert-deftest harness-tasks-refine-refusal-naming-no-task ()
  "A refusal naming no task on the board waits for the user all the same; dropping it drops it."
  (harness-tasks-test-with
    (let* ((harness-provider-demo-script-override
            '((:type text :delta "**Duplicate of t-nosuch00**") (:type done :stop-reason end-turn)))
           (id (harness-tasks-test-refine "an idea the board may have"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :outcome)) 5 "the refusal")
      (let ((task (harness-tasks-test-task id)))
        (should (eq 'duplicate (plist-get task :outcome)))
        (should (eq 'needs-input (plist-get task :column)))
        (should-not (plist-get task :duplicate-of))
        (should (equal "Duplicate of t-nosuch00" (plist-get task :error))))
      (should-not (harness-call 'task/cancel id))
      (should-not (gethash id harness-tasks--table))
      (should-not (harness-call 'session/exists-p sid)))))

(ert-deftest harness-tasks-refine-feedback-after-a-refusal ()
  "Feedback on a refused task goes to its write-up, which may be written up then; editing it by hand works too."
  (harness-tasks-test-with
    (let* ((harness-provider-demo-script-override
            '((:type text :delta "Duplicate of t-nosuch00\n\nLooks like the same.") (:type done :stop-reason end-turn)))
           (id (harness-tasks-test-refine "an idea"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (harness-test-wait (lambda () (eq 'duplicate (plist-get (harness-tasks-test-task id) :outcome))) 5 "the refusal")
      (let ((harness-provider-demo-script-override
             '((:type text :delta "Do the idea\n\nIt differs.") (:type done :stop-reason end-turn))))
        (harness-call 'task/prompt id "it is not the same: this one is about the other page")
        (harness-tasks-test-wait-state id 'pending))
      (should (equal "Do the idea\n\nIt differs." (plist-get (harness-tasks-test-task id) :prompt)))
      (should (equal "it is not the same: this one is about the other page"
                     (car (last (harness-tasks-test-user-texts sid)))))
      ;; Refused again, then written by hand: a backlog task, nothing left of the refusal.
      (harness-call 'task/prompt id "check again")
      (harness-test-wait (lambda () (eq 'duplicate (plist-get (harness-tasks-test-task id) :outcome))) 5 "the refusal")
      (harness-call 'task/update id "By hand")
      (let ((task (harness-tasks-test-task id)))
        (should (eq 'pending (plist-get task :state)))
        (should (equal "By hand" (plist-get task :prompt)))
        (should-not (plist-get task :outcome))
        (should-not (plist-get task :error))))))

(ert-deftest harness-tasks-demo-write-up-refuses-the-same-words ()
  "The demo provider's write-up looks at the board first and refuses a request it already has."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-sessions)
    (let* ((harness-provider-demo-script-override nil)
           (first (harness-tasks-test-refine "CSV export for the reports")))
      (harness-tasks-test-wait-state first 'pending)
      (should (string-prefix-p "CSV export for the reports\n\n" (plist-get (harness-tasks-test-task first) :prompt)))
      (let* ((id (harness-tasks-test-refine "csv  export for the REPORTS"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :outcome)) 5 "the refusal")
        (should (eq 'duplicate (plist-get (harness-tasks-test-task id) :outcome)))
        (should (equal first (plist-get (harness-tasks-test-task id) :duplicate-of)))
        ;; It searched the board, which showed it its own line too.
        (let ((search (harness-tasks-test--node sid (lambda (n) (and (eq (plist-get n :kind) 'tool-call)
                                                                     (equal "task_list" (plist-get n :tool))))))
              (result (harness-tasks-test--node sid (lambda (n) (eq (plist-get n :kind) 'tool-result)))))
          (should search)
          (should (string-match-p (concat (regexp-quote id) " .*(this task)") (plist-get result :output))))))))

(ert-deftest harness-tasks-demo-plans-a-task ()
  "The demo provider plans a task as a real planner would: the board,
the project, then the plan handed in with submit_task_plan.  Feedback
goes into the plan it hands in again."
  (harness-tasks-test-with-plans
    (let* ((harness-provider-demo-script-override nil)
           (id (harness-tasks-test-plan-submit "add a csv export to the reports"))
           (sid (harness-tasks-test-session-id id)))
      (harness-tasks-test-wait-state id 'pending)
      (let ((prompt (plist-get (harness-tasks-test-task id) :prompt)))
        (should (string-prefix-p "Add a csv export to the reports\n\n## Goal\nadd a csv export to the reports" prompt))
        (should (string-match-p "^## Steps$" prompt)))
      (should (harness-tasks-test--node sid (lambda (n) (and (eq (plist-get n :kind) 'tool-call)
                                                             (equal "task_list" (plist-get n :tool))))))
      ;; The plan shows in its transcript.
      (should (harness-tasks-test--node sid (lambda (n) (eq (plist-get n :kind) 'plan))))
      (harness-call 'task/prompt id "and a json one")
      (harness-test-wait (lambda () (string-match-p "## Also\nand a json one"
                                                    (plist-get (harness-tasks-test-task id) :prompt)))
                         5 "the plan again"))))

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
        (should (string-prefix-p harness-tasks--start-message (cadr texts)))))))

;;;; Naming: task sessions are titled like tickets

(defvar harness-tasks--naming-instructions)
(defvar harness-naming--base-system-prompt)

(ert-deftest harness-tasks-naming-prompt-for-task-sessions-only ()
  (harness-tasks-test-with
    (let* ((id (harness-tasks-test-submit "fix the parser"))
           (task-session (harness-call 'session/get (plist-get (harness-tasks-test-task id) :session)))
           (plain (harness-call 'session/create :cwd default-directory :model "demo:scripted")))
      (should (equal (concat "Name it.\n\n" harness-tasks--naming-instructions)
                     (harness-run-filter 'naming/system-prompt "Name it." task-session)))
      (should (equal "Name it." (harness-run-filter 'naming/system-prompt "Name it." plain)))
      (let ((harness-tasks--naming-instructions nil))
        (should (equal "Name it." (harness-run-filter 'naming/system-prompt "Name it." task-session))))
      (harness-tasks-test-wait-state id 'done))))

(ert-deftest harness-tasks-auto-named-like-tickets ()
  "A task is named like a ticket as soon as it is submitted, and its session too.
Its first turn usually lasts until the task is done: the board must
not show the raw prompt as the task's title until then.  One request
names both: the session's turn leaves its naming to the task's."
  (harness-tasks-test-with
    (harness-test-load-module 'naming)
    (let ((harness-naming-auto t)
          (systems nil)
          (held nil))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req)
                    (if (plist-get req :ephemeral)
                        (progn (push (plist-get req :system) systems) (funcall orig req))
                      ;; The task works on until the test lets its turn end.
                      (push (plist-get req :on-event) held)
                      (list :cancel #'ignore)))))
        (let* ((id (harness-tasks-test-submit "fix the parser"))
               (sid (plist-get (harness-tasks-test-task id) :session)))
          (harness-test-wait (lambda () (plist-get (harness-call 'session/get sid) :name)) 5 "the task's name")
          (should (equal "Working on it" (plist-get (harness-call 'session/get sid) :name)))
          (should (eq 'active (harness-tasks-test-state id)))
          (should (eq 'active (plist-get (harness-tasks-test-task id) :column)))
          (should (equal (list (concat harness-naming--base-system-prompt "\n\n" harness-tasks--naming-instructions))
                         systems))
          (let ((on-event (car held)))
            (funcall on-event '(:type text :delta "Fixed it."))
            (funcall on-event '(:type done :stop-reason end-turn)))
          (harness-tasks-test-wait-state id 'done))))))

;;;; Titles: a task is named as soon as it is submitted
;;
;; The tests below fake the provider: a naming request (`:ephemeral')
;; waits for the test to answer it, unless `harness-tasks-test--title-answer'
;; does, and a turn waits for `harness-tasks-test-release'.

(declare-function harness-tasks--name-untitled "harness-tasks")

(defvar harness-tasks-test--titles nil
  "Naming requests the fake provider got, newest first.")

(defvar harness-tasks-test--turns nil
  "(SESSION-ID . ON-EVENT) of the turns the fake provider holds, newest first.")

(defvar harness-tasks-test--title-answer nil
  "Function of a naming request returning its title.
Nil leaves the requests to the test, which answers them.")

(defun harness-tasks-test--complete (request)
  "Answer REQUEST as the fake provider of the title tests."
  (let ((on-event (plist-get request :on-event)))
    (if (plist-get request :ephemeral)
        (progn
          (push request harness-tasks-test--titles)
          (when harness-tasks-test--title-answer
            (run-at-time 0.005 nil #'harness-tasks-test-answer
                         request (funcall harness-tasks-test--title-answer request))))
      (push (cons (plist-get (plist-get request :session) :id) on-event) harness-tasks-test--turns)))
  (list :cancel #'ignore))

(defmacro harness-tasks-test-with-titles (answer &rest body)
  "Run BODY as `harness-tasks-test-with' does, tasks named as they are submitted.
ANSWER is the `harness-tasks-test--title-answer'."
  (declare (indent 1))
  `(harness-tasks-test-with
     (harness-test-load-module 'naming)
     (let ((harness-naming-auto t)
           (harness-tasks-test--titles nil)
           (harness-tasks-test--turns nil)
           (harness-tasks-test--title-answer ,answer))
       (cl-letf (((symbol-function 'harness-method/provider/complete) #'harness-tasks-test--complete))
         ,@body))))

(defun harness-tasks-test--quoted (request)
  "The message naming REQUEST asks a title for."
  (let ((text (plist-get (car (plist-get (car (plist-get request :messages)) :content)) :text)))
    (and (string-match "<message>\n\\(\\(?:.\\|\n\\)*?\\)\n</message>" text)
         (match-string 1 text))))

(defun harness-tasks-test-title-request (text)
  "The naming request for TEXT, the newest one."
  (cl-find text harness-tasks-test--titles :key #'harness-tasks-test--quoted :test #'equal))

(defun harness-tasks-test-answer (request title)
  "Answer naming REQUEST with TITLE, or fail it when TITLE is (error MESSAGE)."
  (let ((on-event (plist-get request :on-event)))
    (if (stringp title)
        (progn (funcall on-event (list :type 'text :delta title))
               (funcall on-event '(:type done :stop-reason end-turn)))
      (funcall on-event (list :type 'done :stop-reason 'error :error (cadr title))))))

(defun harness-tasks-test-turn (sid)
  "Wait for the fake provider to hold a turn of session SID."
  (harness-test-wait (lambda () (assoc sid harness-tasks-test--turns)) 5 (format "a turn of %s" sid)))

(defun harness-tasks-test-release (sid &optional text)
  "End the turn of session SID the fake provider holds, saying TEXT."
  (let ((held (harness-tasks-test-turn sid)))
    (setq harness-tasks-test--turns (delq held harness-tasks-test--turns))
    (funcall (cdr held) (list :type 'text :delta (or text "Done.")))
    (funcall (cdr held) '(:type done :stop-reason end-turn))))

(defun harness-tasks-test-name (id)
  "Task ID's own name."
  (plist-get (harness-tasks-test-task id) :name))

(defun harness-tasks-test-session-name (sid)
  (plist-get (harness-call 'session/get sid) :name))

(defun harness-tasks-test-hints (sid)
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'hint)) (harness-call 'session/nodes sid))))

(ert-deftest harness-tasks-named-while-it-waits ()
  "A task is named as soon as it is submitted, while it waits for a slot.
Its prompt goes out in the request that names a session from its first
message, asked for a ticket title.  Every task has its session from
submission, so the title reaches the waiting task's session at once;
that session does the work later, and is not named again."
  (harness-tasks-test-with-titles
      (lambda (request)
        (if (string-prefix-p "fix" (harness-tasks-test--quoted request)) "Fix the parser" "Export orders as CSV"))
    (let ((harness-tasks-max-running 1))
      (let* ((first (harness-tasks-test-submit "fix the parser, it drops comments"))
             (second (harness-tasks-test-submit "export the orders as CSV for finance"))
             (first-sid (plist-get (harness-tasks-test-task first) :session))
             (second-sid (plist-get (harness-tasks-test-task second) :session)))
        (should (eq 'pending (harness-tasks-test-state second)))
        (should second-sid)
        (should (eq 'idle (plist-get (harness-tasks-test-session second) :status)))
        (harness-test-wait (lambda () (harness-tasks-test-name second)) 5 "the waiting task's name")
        (should (equal "Export orders as CSV" (harness-tasks-test-name second)))
        (should (eq 'pending (harness-tasks-test-state second)))
        ;; Its own session, waiting with it, takes the title now.
        (should (equal "Export orders as CSV" (harness-tasks-test-session-name second-sid)))
        (let ((request (harness-tasks-test-title-request "export the orders as CSV for finance")))
          (should (equal (concat harness-naming--base-system-prompt "\n\n" harness-tasks--naming-instructions)
                         (plist-get request :system)))
          (should (string-prefix-p "naming-" (plist-get (plist-get request :session) :id))))
        ;; The task at work: its session was named by its task's title.
        (harness-test-wait (lambda () (harness-tasks-test-session-name first-sid)) 5 "the first session's name")
        (should (equal "Fix the parser" (harness-tasks-test-session-name first-sid)))
        (should (equal "Fix the parser" (harness-tasks-test-name first)))
        (harness-tasks-test-release first-sid)
        (harness-tasks-test-wait-state first 'done)
        (harness-test-wait (lambda () (eq 'active (harness-tasks-test-state second))) 5 "the second to start")
        (let ((sid (plist-get (harness-tasks-test-task second) :session)))
          (should (equal second-sid sid))
          (should (equal "Export orders as CSV" (harness-tasks-test-session-name sid)))
          (harness-tasks-test-turn sid)
          ;; Two requests in all, one a task; no session asked for its own.
          (should (= 2 (length harness-tasks-test--titles)))
          (should-not (member "Naming session…" (harness-tasks-test-hints first-sid)))
          (should-not (member "Naming session…" (harness-tasks-test-hints sid)))
          (harness-tasks-test-release sid)
          (harness-tasks-test-wait-state second 'done))))))

(ert-deftest harness-tasks-title-on-its-way-names-the-session ()
  "A task that starts before its title comes leaves its session to that title.
The session's turn does not name it: the title does when it comes."
  (harness-tasks-test-with-titles nil
    (let* ((id (harness-tasks-test-submit "fix the parser, it drops comments"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (should (eq 'active (harness-tasks-test-state id)))
      (harness-tasks-test-turn sid)
      (should (= 1 (length harness-tasks-test--titles)))
      (should-not (harness-tasks-test-session-name sid))
      (harness-tasks-test-answer (car harness-tasks-test--titles) "Fix the parser")
      (harness-test-wait (lambda () (harness-tasks-test-session-name sid)) 5 "the session's name")
      (should (equal "Fix the parser" (harness-tasks-test-session-name sid)))
      (should (equal "Fix the parser" (harness-tasks-test-name id)))
      (should (= 1 (length harness-tasks-test--titles)))
      (should (member "renamed to Fix the parser" (harness-tasks-test-hints sid)))
      (harness-tasks-test-release sid)
      (harness-tasks-test-wait-state id 'done))))

(ert-deftest harness-tasks-failed-title-never-holds-the-task ()
  "A task neither waits for its title nor fails with it.
It starts at once; when the request fails, its session is named the
usual way, from its first message."
  (harness-tasks-test-with-titles nil
    (let* ((id (harness-tasks-test-submit "fix the parser, it drops comments"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (should (eq 'active (harness-tasks-test-state id)))
      (harness-tasks-test-turn sid)
      (harness-tasks-test-answer (car harness-tasks-test--titles) '(error "overloaded"))
      (harness-test-wait (lambda () (= 2 (length harness-tasks-test--titles))) 5 "the session's own request")
      (let ((request (car harness-tasks-test--titles)))
        (should (equal sid (plist-get (plist-get request :session) :id)))
        (should (equal "fix the parser, it drops comments" (harness-tasks-test--quoted request)))
        (harness-tasks-test-answer request "Fix the parser"))
      (harness-test-wait (lambda () (harness-tasks-test-session-name sid)) 5 "the session's name")
      (should (equal "Fix the parser" (harness-tasks-test-session-name sid)))
      (should-not (harness-tasks-test-name id))
      (should (eq 'active (harness-tasks-test-state id)))
      (harness-tasks-test-release sid)
      (harness-tasks-test-wait-state id 'done))))

(ert-deftest harness-tasks-start-never-waits-for-the-title ()
  "A waiting task starts as soon as a slot frees, its title come or not.
The title names its session when it comes."
  (harness-tasks-test-with-titles nil
    (let ((harness-tasks-max-running 1))
      (let* ((first (harness-tasks-test-submit "fix the parser"))
             (second (harness-tasks-test-submit "export the orders as CSV"))
             (first-sid (plist-get (harness-tasks-test-task first) :session)))
        (should (= 2 (length harness-tasks-test--titles)))
        (harness-tasks-test-release first-sid)
        (harness-tasks-test-wait-state first 'done)
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task second) :started))
                           5 "the second to start")
        (let ((sid (harness-tasks-test-session-id second)))
          (harness-tasks-test-turn sid)
          (should-not (harness-tasks-test-session-name sid))
          (harness-tasks-test-answer (harness-tasks-test-title-request "export the orders as CSV")
                                     "Export orders as CSV")
          (harness-test-wait (lambda () (harness-tasks-test-session-name sid)) 5 "the session's name")
          (should (equal "Export orders as CSV" (harness-tasks-test-session-name sid)))
          (should (= 2 (length harness-tasks-test--titles)))
          (harness-tasks-test-release sid)
          (harness-tasks-test-wait-state second 'done))))))

(ert-deftest harness-tasks-backlog-task-named-from-its-request ()
  "A task for the backlog is named from the words it was written up from.
Its write-up's session takes the title, and keeps it through the
write-up and the work."
  (harness-tasks-test-with-titles (lambda (_request) "Handle nested quotes")
    (let* ((id (harness-tasks-test-refine "the parser chokes on nested quotes"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (harness-test-wait (lambda () (harness-tasks-test-session-name sid)) 5 "the write-up's name")
      (should (equal "Handle nested quotes" (harness-tasks-test-name id)))
      (should (equal "Handle nested quotes" (harness-tasks-test-session-name sid)))
      (should (equal '("the parser chokes on nested quotes")
                     (mapcar #'harness-tasks-test--quoted harness-tasks-test--titles)))
      (should (string-prefix-p "naming-" (plist-get (plist-get (car harness-tasks-test--titles) :session) :id)))
      (harness-tasks-test-release sid harness-tasks-test-write-up)
      (harness-tasks-test-wait-state id 'pending)
      (should (equal harness-tasks-test-write-up (plist-get (harness-tasks-test-task id) :prompt)))
      (harness-call 'task/start id)
      (harness-tasks-test-turn sid)
      (should (equal "Handle nested quotes" (harness-tasks-test-session-name sid)))
      (should (= 1 (length harness-tasks-test--titles)))
      (harness-tasks-test-release sid)
      (harness-tasks-test-wait-state id 'done))))

(ert-deftest harness-tasks-edited-prompt-named-again ()
  "A waiting task whose prompt is edited is named again from the new one.
The old prompt's title, should it come after the edit, is dropped."
  (harness-tasks-test-with-titles nil
    (let ((harness-tasks-max-running 0))
      (let ((id (harness-tasks-test-submit "fix the parser")))
        (should (= 1 (length harness-tasks-test--titles)))
        (harness-call 'task/update id "export the orders as CSV")
        (harness-tasks-test-answer (harness-tasks-test-title-request "fix the parser") "Fix the parser")
        (harness-test-wait (lambda () (harness-tasks-test-title-request "export the orders as CSV")) 5
                           "the request for the new prompt")
        (should-not (harness-tasks-test-name id))
        (harness-tasks-test-answer (harness-tasks-test-title-request "export the orders as CSV")
                                   "Export orders as CSV")
        (harness-test-wait (lambda () (harness-tasks-test-name id)) 5 "the new name")
        (should (equal "Export orders as CSV" (harness-tasks-test-name id)))
        ;; Edited once named: the name goes at once, and a new one comes.
        (let ((harness-tasks-test--title-answer (lambda (_request) "Export orders as JSON")))
          (should-not (plist-get (harness-call 'task/update id "export the orders as JSON") :name))
          (harness-test-wait (lambda () (equal "Export orders as JSON" (harness-tasks-test-name id)))
                             5 "the newest name"))
        (should (= 3 (length harness-tasks-test--titles)))
        ;; The same prompt again asks for nothing.
        (harness-call 'task/update id "export the orders as JSON")
        (should (= 3 (length harness-tasks-test--titles)))
        (should (equal "Export orders as JSON" (harness-tasks-test-name id)))))))

(ert-deftest harness-tasks-untitled-tasks-named-at-start-up ()
  "The tasks found without a title when the harness starts or reloads are named.
They come from before tasks were named as they were submitted, or their
naming failed.  Two requests are out at a time.  Archived tasks and
tasks with a title are left alone."
  (harness-tasks-test-with-titles
      (lambda (request) (capitalize (harness-tasks-test--quoted request)))
    (let ((harness-tasks-max-running 0)
          (ids nil))
      (let ((harness-naming-auto nil))
        (setq ids (mapcar #'harness-tasks-test-submit
                          '("fix the parser" "export the orders" "page the orders" "log slow requests" "old work"))))
      (harness-tasks--set (nth 3 ids) :name "Log slow requests")
      (harness-tasks--set (nth 4 ids) :archived t)
      (should-not harness-tasks-test--titles)
      (harness-tasks--name-untitled)
      (should (= 2 (length harness-tasks-test--titles)))
      (should (equal '(2 . 1) (harness-tasks-test--throttle)))
      (harness-test-wait (lambda () (cl-every #'harness-tasks-test-name (seq-take ids 3))) 5 "the names")
      (should (equal '("Fix The Parser" "Export The Orders" "Page The Orders" "Log slow requests" nil)
                     (mapcar #'harness-tasks-test-name ids)))
      (should (= 3 (length harness-tasks-test--titles)))
      (should (equal '(0 . 0) (harness-tasks-test--throttle)))
      (harness-tasks--name-untitled)
      (should (= 3 (length harness-tasks-test--titles))))))

;;;; Internal jobs: no slot taken, none waited for
;;
;; A task's title request is a model call of the harness's own, as a
;; recap or a permission judge is: it goes straight to the provider under
;; an id of its own, which is no session, so it takes none of the
;; project's slots (`harness-tasks-max-running'), waits for none and
;; counts against none.  The tests below give the board a limit of 0, or
;; no slot to spare, and watch the free slots and the sessions.

(declare-function harness-tasks--project "harness-tasks")

(defun harness-tasks-test--session-ids ()
  "The ids of every session there is, sorted."
  (sort (mapcar (lambda (s) (plist-get s :id)) (harness-call 'session/list)) #'string<))

(defun harness-tasks-test--quiet (seconds)
  "Let the event loop run for SECONDS, timers and processes included."
  (let ((until (+ (float-time) seconds)))
    (while (< (float-time) until)
      (accept-process-output nil 0.02))))

(defun harness-tasks-test--title-takes-no-slot (prompt)
  "Submit PROMPT to a board that cannot start it, and check its title request.
The request goes out at once, under an id of its own that names no
session, so the task's own session is the only one made.  The free slots
of its project are what they were before the submit, while the request
is out and after its title came, which the task gets while it waits.
Return the task's id."
  (let* ((project (harness-tasks--project default-directory))
         (free (harness-tasks--free-slots project))
         (before (harness-tasks-test--session-ids))
         (id (harness-tasks-test-submit prompt))
         (own (harness-tasks-test-session-id id))
         (expected (sort (cons own (copy-sequence before)) #'string<))
         (request (harness-tasks-test-title-request prompt))
         (job (plist-get (plist-get request :session) :id)))
    (should request)
    (should (eq 'pending (harness-tasks-test-state id)))
    (should (equal project (plist-get (harness-tasks-test-task id) :project)))
    ;; Out at once: it waited for nothing, and holds a slot of the throttle.
    (should (gethash id harness-tasks--naming))
    (should (equal '(1 . 0) (harness-tasks-test--throttle)))
    ;; An id of its own, which is no session.
    (should (string-prefix-p "naming-" job))
    (should-not (equal own job))
    (should-not (harness-call 'session/exists-p job))
    (should (equal expected (harness-tasks-test--session-ids)))
    ;; No slot taken while it is out.
    (should (= free (harness-tasks--free-slots project)))
    (should-not (harness-tasks-test-name id))
    ;; The title comes while the task waits, and takes no slot either.
    (harness-tasks-test-answer request "Export orders as CSV")
    (harness-test-wait (lambda () (harness-tasks-test-name id)) 5 "the title")
    (should (equal "Export orders as CSV" (harness-tasks-test-name id)))
    (should (eq 'pending (harness-tasks-test-state id)))
    (should-not (gethash id harness-tasks--naming))
    (should (equal '(0 . 0) (harness-tasks-test--throttle)))
    (should (= free (harness-tasks--free-slots project)))
    (should-not (harness-call 'session/exists-p job))
    (should (equal expected (harness-tasks-test--session-ids)))
    id))

(defun harness-tasks-test--at-work (prompt)
  "Submit PROMPT as a task that starts and holds its slot; return its id.
The fake provider holds its turn, and its title is answered."
  (let* ((id (harness-tasks-test-submit prompt))
         (sid (harness-tasks-test-session-id id)))
    (harness-tasks-test-turn sid)
    (harness-tasks-test-answer (harness-tasks-test-title-request prompt) "Fix the parser")
    (harness-test-wait (lambda () (harness-tasks-test-name id)) 5 "the title of the task at work")
    id))

(ert-deftest harness-tasks-title-request-takes-no-slot-at-a-limit-of-0 ()
  "A title request goes out and comes back with `harness-tasks-max-running' at 0.
No task starts by itself then.  The request is no task's work, so the
limit has nothing to say to it."
  (harness-tasks-test-with-titles nil
    (let ((harness-tasks-max-running 0))
      (harness-tasks-test--title-takes-no-slot "export the orders as CSV for finance"))))

(ert-deftest harness-tasks-title-request-ignores-a-full-board ()
  "A title request goes out and comes back while every slot is taken.
The one slot is held by a task at work, so a second task waits for it.
Its request neither waits for that slot nor takes it, and the task
starts, titled, when the first one is done."
  (harness-tasks-test-with-titles nil
    (let ((harness-tasks-max-running 1))
      (let* ((first (harness-tasks-test--at-work "fix the parser"))
             (project (plist-get (harness-tasks-test-task first) :project)))
        (should (= 0 (harness-tasks--free-slots project)))
        (let ((second (harness-tasks-test--title-takes-no-slot "export the orders as CSV")))
          (should (eq 'active (harness-tasks-test-state first)))
          (should (= 0 (harness-tasks--free-slots project)))
          ;; The slot frees: the waiting task starts, its title already there.
          (harness-tasks-test-release (harness-tasks-test-session-id first))
          (harness-tasks-test-wait-state first 'done)
          (harness-test-wait (lambda () (eq 'active (harness-tasks-test-state second))) 5
                             "the second to start")
          (should (equal "Export orders as CSV"
                         (harness-tasks-test-session-name (harness-tasks-test-session-id second))))
          (harness-tasks-test-release (harness-tasks-test-session-id second))
          (harness-tasks-test-wait-state second 'done))))))

(ert-deftest harness-tasks-title-request-leaves-a-free-slot-free ()
  "A title request leaves a free slot free.
Two slots, one taken by a task at work, and the project's queue
suspended so the next task waits though a slot is free.  Its request
neither takes that slot nor changes the count of free ones, and the
task, titled, takes the slot once the queue runs again."
  (harness-tasks-test-with-titles nil
    (let ((harness-tasks-max-running 2))
      (let* ((first (harness-tasks-test--at-work "fix the parser"))
             (project (plist-get (harness-tasks-test-task first) :project)))
        (harness-call 'task/suspend-queue default-directory)
        (should (= 1 (harness-tasks--free-slots project)))
        (let ((second (harness-tasks-test--title-takes-no-slot "export the orders as CSV")))
          (should (= 1 (harness-tasks--free-slots project)))
          (harness-call 'task/resume-queue default-directory)
          (harness-test-wait (lambda () (eq 'active (harness-tasks-test-state second))) 5
                             "the second to start")
          (should (= 0 (harness-tasks--free-slots project)))
          (dolist (id (list first second))
            (harness-tasks-test-release (harness-tasks-test-session-id id)))
          (dolist (id (list first second))
            (harness-tasks-test-wait-state id 'done)))))))

(ert-deftest harness-tasks-judge-decides-at-the-limit ()
  "The auto-mode permission judge decides while the board is at its limit.
It is an internal job like a title request: a model call under an id of
its own (`SESSION-perms'), no turn of any session.  With the limit at 0
and a task waiting, a call of a plain session in auto mode goes through
the judge and is decided; the free slots, the waiting task and the
sessions are as they were."
  (harness-tasks-test-with
    (harness-test-load-module 'perms)
    (harness-define-tool "t_exec" :label "Run" :kind 'exec :description "Runs a thing."
                         :handler #'ignore)
    (let* ((harness-tasks-max-running 0)
           (id (harness-tasks-test-submit "fix the parser"))
           (project (plist-get (harness-tasks-test-task id) :project))
           (plain (harness-call 'session/create :cwd default-directory :model "demo:scripted"
                                :permission-mode 'auto))
           (judge (format "%s-perms" (plist-get plain :id)))
           (free (harness-tasks--free-slots project))
           (sessions (harness-tasks-test--session-ids))
           (requests nil))
      (should (eq 'pending (harness-tasks-test-state id)))
      (cl-letf (((symbol-function 'harness-method/provider/complete)
                 (lambda (request)
                   (push request requests)
                   (let ((on-event (plist-get request :on-event)))
                     (run-at-time 0.005 nil
                                  (lambda ()
                                    (funcall on-event
                                             (list :type 'text
                                                   :delta "{\"decision\":\"allow\",\"reason\":\"ordinary work\"}"))
                                    (funcall on-event '(:type done :stop-reason end-turn)))))
                   (list :cancel #'ignore))))
        ;; The chain from the permission mode on, where the harness's own
        ;; tests allow every call before it (priority 10).
        (let ((decision (harness-test-await
                         (harness-run-filter-async-between
                          'permission/decide 20 30 '(:behavior ask)
                          (list :session plain :tool "t_exec" :kind 'exec
                                :input '(:command "make test") :call-id "c1")))))
          (should (eq 'allow (plist-get decision :behavior)))
          (should (equal "ordinary work" (plist-get decision :reason)))))
      ;; The judge was asked, as the one-off request it is.
      (should (= 1 (length requests)))
      (let ((request (car requests)))
        (should (plist-get request :ephemeral))
        (should-not (plist-get request :tools))
        (should (equal judge (plist-get (plist-get request :session) :id))))
      ;; And it took nothing from the board.
      (should-not (harness-call 'session/exists-p judge))
      (should (equal sessions (harness-tasks-test--session-ids)))
      (should (= free (harness-tasks--free-slots project)))
      (should (eq 'pending (harness-tasks-test-state id))))))

;;;; The title throttle
;;
;; At most `harness-tasks--naming-concurrency' title requests are out at
;; once: a pool of the slots library (`harness-tasks--naming-pool').  The
;; others wait for a slot, by their task's priority, and one that fails
;; is left to the layers below -- task mode asks for no title again on a
;; timer of its own.

(defun harness-tasks-test--throttle ()
  "The throttle's state: (OUT . WAITING), the requests out and those waiting."
  (cons (harness-slots-running harness-tasks--naming-pool)
        (harness-slots-waiting harness-tasks--naming-pool)))

(defun harness-tasks-test--title-requests ()
  "The texts the title requests asked for so far, oldest first."
  (nreverse (mapcar #'harness-tasks-test--quoted harness-tasks-test--titles)))

(ert-deftest harness-tasks-titles-wait-for-the-throttle-by-priority ()
  "When more titles wait than the throttle lets out, the highest priority goes first.
Two requests are out at a time and the others wait for one to settle.
The next to go is the highest priority task's, ahead of older medium
ones, a priority given while the request waited counts, and among
equals the oldest task's goes first."
  (harness-tasks-test-with-titles nil
    (let ((harness-tasks-max-running 0))
      (let* ((ids (mapcar #'harness-tasks-test-submit
                          '("fix the parser" "export the orders" "page the orders"
                            "log slow requests" "audit the logins" "trim the cache")))
             (page (nth 2 ids)) (slow (nth 3 ids)) (audit (nth 4 ids)) (trim (nth 5 ids))
             (out '("fix the parser" "export the orders"))
             (went nil))
        ;; The first two went out at once; the rest wait, oldest first.
        (should (equal out (harness-tasks-test--title-requests)))
        (should (equal '(2 . 4) (harness-tasks-test--throttle)))
        (should (equal (list page slow audit trim) (harness-slots-waiters harness-tasks--naming-pool)))
        ;; Asked for again, a task whose request waits is not queued twice.
        (harness-tasks--name page)
        (should (equal '(2 . 4) (harness-tasks-test--throttle)))
        ;; Priorities given while the requests wait: the audit high, the slow log low.
        (harness-call 'priority/set (harness-tasks-test-session-id audit) "high")
        (harness-call 'priority/set (harness-tasks-test-session-id slow) "low")
        ;; Each answer frees a slot, and the waiting request that ranks first takes it.
        (dotimes (_ 4)
          (let ((before (length harness-tasks-test--titles)))
            (harness-tasks-test-answer (harness-tasks-test-title-request (pop out)) "A title")
            (harness-test-wait (lambda () (> (length harness-tasks-test--titles) before)) 5
                               "the next request")
            (let ((text (harness-tasks-test--quoted (car harness-tasks-test--titles))))
              (push text went)
              (setq out (append out (list text))))))
        (should (equal '("audit the logins" "page the orders" "trim the cache" "log slow requests")
                       (nreverse went)))
        ;; All out; the last two settle and the throttle is empty.
        (should (equal '(2 . 0) (harness-tasks-test--throttle)))
        (dolist (text out)
          (harness-tasks-test-answer (harness-tasks-test-title-request text) "A title"))
        (harness-test-wait (lambda () (equal '(0 . 0) (harness-tasks-test--throttle))) 5
                           "the throttle to empty")
        (should (= 6 (length harness-tasks-test--titles)))))))

(ert-deftest harness-tasks-throttle-lets-out-as-many-as-its-limit ()
  "The throttle allows `harness-tasks--naming-concurrency' requests, whatever that is now."
  (harness-tasks-test-with-titles nil
    (let ((harness-tasks-max-running 0)
          (harness-tasks--naming-concurrency 1))
      (harness-tasks-test-submit "fix the parser")
      (harness-tasks-test-submit "export the orders")
      (should (equal '(1 . 1) (harness-tasks-test--throttle)))
      (should (equal '("fix the parser") (harness-tasks-test--title-requests)))
      (harness-tasks-test-answer (car harness-tasks-test--titles) "Fix the parser")
      (harness-test-wait (lambda () (= 2 (length harness-tasks-test--titles))) 5 "the second request")
      (should (equal '(1 . 0) (harness-tasks-test--throttle))))))

(ert-deftest harness-tasks-title-of-a-task-that-started-meanwhile-is-not-asked-for ()
  "A request that waits for the throttle is dropped when its task starts first.
The start of the task's turn names its session, so when the request's
turn comes its slot goes back at once and nothing is sent for it."
  (harness-tasks-test-with-titles nil
    (let ((harness-tasks-max-running 0)
          (harness-tasks--naming-concurrency 1))
      (let* ((first (harness-tasks-test-submit "fix the parser"))
             (second (harness-tasks-test-submit "export the orders"))
             (sid (harness-tasks-test-session-id second)))
        (ignore first)
        (should (equal '(1 . 1) (harness-tasks-test--throttle)))
        (should (equal (list second) (harness-slots-waiters harness-tasks--naming-pool)))
        ;; Started by hand, whatever the limit: its turn names its session,
        ;; for its title is not on its way, only waiting to be.
        (harness-call 'task/start second)
        (harness-tasks-test-turn sid)
        (harness-test-wait (lambda () (= 2 (length harness-tasks-test--titles))) 5
                           "the session's own request")
        (should (equal sid (plist-get (plist-get (car harness-tasks-test--titles) :session) :id)))
        ;; The first request settles; the second task's turn comes and finds it at work.
        (harness-tasks-test-answer (harness-tasks-test-title-request "fix the parser") "Fix the parser")
        (harness-test-wait (lambda () (equal '(0 . 0) (harness-tasks-test--throttle))) 5
                           "the throttle to empty")
        (harness-tasks-test--quiet 0.1)
        (should (= 2 (length harness-tasks-test--titles)))
        (should-not (gethash second harness-tasks--naming))
        (harness-tasks-test-answer (car harness-tasks-test--titles) "Export orders")
        (harness-test-wait (lambda () (harness-tasks-test-session-name sid)) 5 "the session's name")
        (harness-tasks-test-release sid)
        (harness-tasks-test-wait-state second 'done)))))

(ert-deftest harness-tasks-failed-title-is-not-asked-for-again ()
  "A title request that fails is not made again by task mode.
It is an ordinary provider request, which the HTTP layer or the CLI
retries as they do any; one that still fails leaves a task that waits
for a slot untitled, and no timer of the tasks module asks for it
again.  Its slot of the throttle goes back, and a harness that starts or
reloads names the task (`harness-tasks--name-untitled')."
  (harness-tasks-test-with-titles nil
    ;; The timers due at start-up run first: one of them names the tasks found
    ;; untitled, which would ask again for a title that failed by chance.
    (harness-tasks-test--settle)
    (let ((harness-tasks-max-running 0))
      (let ((id (harness-tasks-test-submit "export the orders as CSV for finance")))
        (should (equal '(1 . 0) (harness-tasks-test--throttle)))
        (harness-tasks-test-answer (car harness-tasks-test--titles) '(error "overloaded"))
        (should (equal '(0 . 0) (harness-tasks-test--throttle)))
        (should-not (gethash id harness-tasks--naming))
        (harness-tasks-test--quiet 0.3)
        (should (= 1 (length harness-tasks-test--titles)))
        (should (eq 'pending (harness-tasks-test-state id)))
        (should-not (harness-tasks-test-name id))
        ;; The harness starts or reloads: the task is found untitled and asked for.
        (harness-tasks--name-untitled)
        (should (= 2 (length harness-tasks-test--titles)))
        (harness-tasks-test-answer (car harness-tasks-test--titles) "Export orders as CSV")
        (harness-test-wait (lambda () (harness-tasks-test-name id)) 5 "the title")
        (should (equal '(0 . 0) (harness-tasks-test--throttle)))))))

(ert-deftest harness-tasks-failed-title-leaves-the-task-to-its-turn ()
  "A task whose title failed while it waited is named by its turn once it starts.
Started by hand, whatever the limit, its turn names its session from its
first message, as it always did; nothing else asks for the title."
  (harness-tasks-test-with-titles nil
    (harness-tasks-test--settle)
    (let ((harness-tasks-max-running 0))
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (harness-tasks-test-session-id id)))
        (harness-tasks-test-answer (car harness-tasks-test--titles) '(error "overloaded"))
        (harness-tasks-test--quiet 0.2)
        (should (= 1 (length harness-tasks-test--titles)))
        (harness-call 'task/start id)
        (harness-tasks-test-turn sid)
        (should (= 2 (length harness-tasks-test--titles)))
        (should (equal sid (plist-get (plist-get (car harness-tasks-test--titles) :session) :id)))
        (harness-tasks-test-answer (car harness-tasks-test--titles) "Fix the parser")
        (harness-test-wait (lambda () (harness-tasks-test-session-name sid)) 5 "the session's name")
        (should (equal "Fix the parser" (harness-tasks-test-session-name sid)))
        (harness-tasks-test--quiet 0.2)
        (should (= 2 (length harness-tasks-test--titles)))
        (harness-tasks-test-release sid)
        (harness-tasks-test-wait-state id 'done)))))

(ert-deftest harness-tasks-edited-prompt-is-named-again-after-a-failed-title ()
  "A prompt edited after its title failed is asked for at once.
The edit names the task afresh, from the new text, as it always did."
  (harness-tasks-test-with-titles nil
    (harness-tasks-test--settle)
    (let ((harness-tasks-max-running 0))
      (let ((id (harness-tasks-test-submit "fix the parser")))
        (harness-tasks-test-answer (car harness-tasks-test--titles) '(error "overloaded"))
        (harness-tasks-test--quiet 0.2)
        (should (= 1 (length harness-tasks-test--titles)))
        (harness-call 'task/update id "export the orders as CSV")
        (should (= 2 (length harness-tasks-test--titles)))
        (should (equal "export the orders as CSV" (harness-tasks-test--quoted (car harness-tasks-test--titles))))
        (harness-tasks-test-answer (car harness-tasks-test--titles) "Export orders as CSV")
        (harness-test-wait (lambda () (harness-tasks-test-name id)) 5 "the title")
        (should (equal "Export orders as CSV" (harness-tasks-test-name id)))
        (should (equal '(0 . 0) (harness-tasks-test--throttle)))))))

;;;; Git: worktree, merge queue, done only when merged

(defvar harness-merge--queues)
(defvar harness-merge--locks)
(defvar harness-merge--holds)
(defvar harness-tasks-worktrees)

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
            ;; As it is outside tests: the tasks live in the repository.
            (harness-tasks-store-in-repository t)
            (harness-tasks-test--commit-on-call 1)
            (harness-provider-demo-script-override
             '((:type tool-call :id "c1" :name "change_shared" :input (:text "two"))
               (:type text :delta "Changed it.")
               (:type done :stop-reason end-turn))))
       (harness-define-tool "change_shared" :label "Change shared file" :description "edit shared.txt" :kind 'write
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

(defun harness-tasks-test--store (root)
  "Return the task store of the repository at ROOT."
  (expand-file-name ".git/harness/tasks.json" root))

(defun harness-tasks-test--read (path)
  "Return the JSON file PATH parsed, nil when there is none."
  (harness-json-parse (harness-read-file path)))

(defun harness-tasks-test--stored-ids (path)
  "Return the ids of the task records in the store PATH, in order."
  (let ((data (harness-tasks-test--read path)))
    (mapcar (lambda (record) (plist-get record :id))
            (if (keywordp (car-safe data)) (plist-get data :tasks) data))))

(ert-deftest harness-tasks-git-lifecycle ()
  (harness-tasks-test-with-git
    (let ((id (harness-tasks-test-submit "Change the shared file"))
          (task nil))
      ;; The task's session is made at submission: what says it started is
      ;; the worktree it works in.
      (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :branch))
                         5 "the task's worktree")
      (setq task (harness-tasks-test-task id))
      (should (string-prefix-p "task/change-the-shared-file-" (plist-get task :branch)))
      (should (equal "main" (plist-get task :base)))
      (should (file-directory-p (plist-get task :worktree)))
      (harness-test-wait
       (lambda () (equal (plist-get task :worktree)
                         (plist-get (harness-call 'session/get (plist-get task :session)) :cwd)))
       5 "the session to move into the worktree")
      (let ((session (harness-call 'session/get (plist-get task :session))))
        (should (equal (plist-get task :worktree) (plist-get session :cwd)))
        (should (equal (plist-get task :worktree) (plist-get session :worktree)))
        (should (string-match-p "own git worktree" (harness-run-filter 'agent/system-prompt "" session))))
      ;; Complete only once main has the change.
      (harness-tasks-test-wait-state id 'done)
      (should (equal "two\n" (harness-tasks-test--main-text root)))
      (should (plist-get (harness-tasks-test-task id) :merged))
      ;; The task's branch landed as one commit, named for the session
      ;; (unnamed here, so its branch) rather than "Merge branch ...".
      (should (string-match-p "task/change-the-shared-file-"
                              (harness-tasks-test--git root "log" "-1" "--format=%s")))
      (should (= 1 (length (split-string (harness-tasks-test--git root "log" "-1" "--format=%P") " " t))))
      ;; The merge went into the main checkout itself: no session was made
      ;; to stand behind it, only the task's own.
      (should (equal (list (plist-get task :session))
                     (mapcar (lambda (s) (plist-get s :id)) (harness-call 'session/list))))
      ;; Its record is in the main repository's git directory, out of every
      ;; working tree: neither the checkout the merge went into nor the
      ;; task's worktree shows it.
      (harness-tasks-flush)
      (should (equal (list id) (harness-tasks-test--stored-ids (harness-tasks-test--store root))))
      (should-not (harness-tasks-test--stored-ids (expand-file-name "tasks.json" harness-state-directory)))
      (should (string-empty-p (harness-tasks-test--git root "status" "--porcelain" "--untracked-files=all")))
      (should (string-empty-p (harness-tasks-test--git (plist-get task :worktree)
                                                       "status" "--porcelain" "--untracked-files=all")))
      ;; Archiving removes the worktree and the merged branch.
      (harness-call 'task/archive id)
      (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :worktree-removed)) 30 "worktree removal")
      (should-not (file-directory-p (plist-get task :worktree)))
      (harness-test-wait (lambda () (string-empty-p (harness-tasks-test--git root "branch" "--list" (plist-get task :branch))))
                         30 "branch deletion"))))

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
      (setq sid (harness-tasks-test-session-id id))
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

(defvar harness-merge-conflict-resolver)

(ert-deftest harness-tasks-git-merge-work-takes-no-slot ()
  "A task in the merge queue holds no slot while its conflicts are resolved,
whoever resolves them: a fresh session, a sub-agent of the task's, or
the task's own session.  With one slot, the next task starts meanwhile."
  (dolist (resolver '(fresh child))
    (harness-tasks-test-with-git
      (harness-tasks-test--hang-tool)
      (let ((harness-merge-conflict-resolver resolver)
            (harness-tasks-require-verification t)
            (harness-tasks-max-running 1)
            ;; Resolving the conflicts hangs; any other work changes the file.
            (harness-provider-demo-script-override
             (lambda (request)
               (if (string-match-p "conflict" (harness-provider-demo--last-user-text request))
                   '((:type tool-call :id "h1" :name "hang" :input (:path "x"))
                     (:type done :stop-reason end-turn))
                 '((:type tool-call :id "c1" :name "change_shared" :input (:text "two"))
                   (:type text :delta "Changed it.")
                   (:type done :stop-reason end-turn)))))
            (hanging-p (lambda (sid)
                         (harness-tasks-test--node sid (lambda (n) (equal (plist-get n :tool) "hang"))))))
        (let* ((a (harness-tasks-test-submit "Change the shared file"))
               (project (plist-get (harness-tasks-test-task a) :project))
               (sid (progn (harness-tasks-test-wait-state a 'review)
                           (plist-get (harness-tasks-test-task a) :session))))
          ;; The main checkout moves on: the task's branch conflicts with it now.
          (with-temp-file (expand-file-name "shared.txt" root) (insert "three\n"))
          (harness-tasks-test--git root "commit" "-q" "-am" "main moves on")
          (harness-call 'task/verify a)
          (let ((resolving
                 (harness-test-wait
                  (lambda ()
                    (cl-find-if hanging-p (cons sid (mapcar (lambda (s) (plist-get s :id))
                                                            (harness-call 'session/list (list :parent-id sid))))))
                  30 (format "the conflicts to be resolved (%s)" resolver))))
            (if (eq resolver 'child)
                (should (equal sid resolving))
              (should (equal sid (plist-get (harness-call 'session/get resolving) :parent-id))))
            (should (eq 'running (plist-get (harness-call 'session/get resolving) :status)))
            (should (eq 'merging (harness-tasks-test-state a)))
            (should (eq 'conflict (plist-get (harness-tasks-test-task a) :merge-status)))
            (should (= 1 (harness-tasks--free-slots project)))
            (let ((b (harness-tasks-test-submit "Change it in another task")))
              (should (eq 'active (harness-tasks-test-state b)))
              (harness-tasks-test-wait-state b 'review))
            ;; Give up on the merge, which stops the resolution.
            (harness-call 'merge/cancel sid)
            (harness-call 'agent/cancel resolving)
            (harness-test-wait (lambda () (not (harness-call 'agent/running resolving))) 10
                               "the resolution to stop")))))))

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

(ert-deftest harness-tasks-git-main-tree-task-works-in-the-checkout ()
  "A task submitted with :main-tree runs at the root, with no branch and nothing to merge."
  (harness-tasks-test-with-git
    (let* ((id (plist-get (harness-call 'task/submit root "Change the shared file" (list :main-tree t)) :id))
           (task nil))
      (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :started))
                         5 "the task to start")
      (setq task (harness-tasks-test-task id))
      (should (harness-json-true-p (plist-get task :main-tree)))
      (should-not (plist-get task :worktree))
      (should-not (plist-get task :branch))
      (let ((session (harness-call 'session/get (plist-get task :session))))
        (should (equal root (plist-get session :cwd)))
        (should-not (plist-get session :worktree))
        (should (string-match-p "main working tree"
                                (harness-run-filter 'agent/system-prompt "" session))))
      (harness-tasks-test-wait-state id 'done)
      (setq task (harness-tasks-test-task id))
      (should-not (plist-get task :merged))
      (should-not (plist-get task :worktree-removed))
      ;; The agent's commit landed on main itself: no merge at all.
      (should (equal "change shared" (string-trim (harness-tasks-test--git root "log" "-1" "--format=%s"))))
      (should (equal "two\n" (harness-tasks-test--main-text root))))))

(ert-deftest harness-tasks-git-refined-main-tree-task-stays-at-the-root ()
  "A backlog task that needs the main tree keeps its session at the root and merges nothing."
  (harness-tasks-test-with-git
    (let* ((harness-provider-demo-script-override
            '((:type text :delta "Change shared.txt to two\n\nWrite two into shared.txt.")
              (:type done :stop-reason end-turn)))
           (id (plist-get (harness-call 'task/submit root "shared.txt should say two"
                                        (list :refine t :main-tree t))
                          :id))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (harness-tasks-test-wait-state id 'pending)
      (should (harness-json-true-p (plist-get (harness-tasks-test-task id) :main-tree)))
      (setq harness-provider-demo-script-override
            '((:type tool-call :id "c1" :name "change_shared" :input (:text "two"))
              (:type text :delta "Changed it.")
              (:type done :stop-reason end-turn)))
      (harness-call 'task/start id)
      (harness-tasks-test-wait-state id 'done)
      (let ((task (harness-tasks-test-task id))
            (session (harness-call 'session/get sid)))
        (should (equal sid (plist-get task :session)))
        (should-not (plist-get task :worktree))
        (should-not (plist-get task :branch))
        (should-not (plist-get task :merged))
        (should (equal root (plist-get session :cwd)))
        (should-not (plist-get session :worktree)))
      (should (equal "two\n" (harness-tasks-test--main-text root)))
      (should (equal "change shared" (string-trim (harness-tasks-test--git root "log" "-1" "--format=%s")))))))

(ert-deftest harness-tasks-main-tree-survives-a-restart ()
  "The main-tree declaration is kept in the project's store across a restart."
  (harness-tasks-test-with
    (let* ((harness-tasks-store-in-repository t)
           (harness-tasks-max-running 0)
           (root (harness-tasks-test--make-repo))
           (id (plist-get (harness-call 'task/submit root "clean the checkout" (list :main-tree t)) :id)))
      (harness-tasks-flush)
      (harness-tasks-test--restart)
      (let ((task (harness-tasks-test-task id)))
        (should (harness-json-true-p (plist-get task :main-tree)))
        (should (eq 'pending (plist-get task :state))))
      ;; The stored record names it too, so a harness that reads the store
      ;; without the files gets it.
      (let* ((store (harness-tasks-test--read (harness-tasks-test--store root)))
             (record (car (plist-get store :tasks))))
        (should (harness-json-true-p (plist-get record :main-tree)))))))

;;;; Where tasks are kept

(declare-function harness-tasks--repository-store "harness-tasks")
(declare-function harness-tasks--state-directory "harness-tasks")

(defun harness-tasks-test--settle ()
  "Let the timers due now run, such as picking up records read late."
  (accept-process-output nil 0.05))

(defun harness-tasks-test--global ()
  "Return the global task store of the test's state directory."
  (expand-file-name "tasks.json" harness-state-directory))

(ert-deftest harness-tasks-kept-in-the-main-repository ()
  "A git project's tasks live in its main repository's .git, from any worktree."
  (harness-tasks-test-with
    (let* ((harness-tasks-store-in-repository t)
           (harness-tasks-max-running 0)
           (root (harness-tasks-test--make-repo))
           (wt (file-name-as-directory (expand-file-name "../side" root)))
           (store (harness-tasks-test--store root))
           (registry (expand-file-name "task-stores.json" harness-state-directory)))
      (harness-tasks-test--git root "worktree" "add" "-q" "-b" "side" wt)
      (should (equal (file-truename store) (file-truename (harness-tasks--repository-store wt))))
      (let ((a (harness-tasks-test-submit "from the main checkout" root))
            (b (harness-tasks-test-submit "from a worktree" wt))
            (c (harness-tasks-test-submit "outside git" (harness-test-temp-dir))))
        (harness-tasks-flush)
        (should (equal (list a b) (harness-tasks-test--stored-ids store)))
        (should (equal (harness-tasks--state-directory)
                       (plist-get (harness-tasks-test--read store) :state-directory)))
        (should (equal (list c) (harness-tasks-test--stored-ids (harness-tasks-test--global))))
        (should (equal (list store) (harness-tasks-test--read registry)))
        ;; No working tree sees it, so neither does the merge queue.
        (should (string-empty-p (harness-tasks-test--git root "status" "--porcelain" "--untracked-files=all")))
        (should (string-empty-p (harness-tasks-test--git wt "status" "--porcelain" "--untracked-files=all")))
        ;; A restart reads it back through the registry.
        (harness-tasks-test--restart)
        (should (equal (list a b) (harness-tasks-test--ids (harness-call 'task/list root))))
        ;; Without the registry, opening the board reads it all the same.
        (harness-tasks-flush)
        (delete-file registry)
        (harness-tasks-test--restart)
        (should-not (gethash a harness-tasks--table))
        (should (equal (list a b) (harness-tasks-test--ids (harness-call 'task/list wt))))
        (harness-tasks-test--settle)
        (harness-tasks-flush)
        (should (equal (list store) (harness-tasks-test--read registry)))
        ;; A store left without tasks goes, and its directory with it.
        (harness-call 'task/delete a)
        (harness-call 'task/delete b)
        (harness-tasks-flush)
        (should-not (file-exists-p (file-name-directory store)))
        (should-not (file-exists-p registry))
        (should (equal (list c) (harness-tasks-test--ids (harness-call 'task/list))))))))

(ert-deftest harness-tasks-move-into-their-repositories ()
  "Tasks from before repository stores move into their repositories, a copy kept."
  (harness-tasks-test-with
    (let* ((harness-tasks-store-in-repository t)
           (harness-tasks-max-running 0)
           (root (harness-tasks-test--make-repo))
           (plain (harness-test-temp-dir))
           (store (harness-tasks-test--store root))
           (global (harness-tasks-test--global))
           (legacy (harness-json-encode
                    (list (list :id "t-gitone" :project root :cwd root :prompt "in git"
                                :state "pending" :created 1.0)
                          (list :id "t-plain" :project plain :cwd plain :prompt "outside git"
                                :state "pending" :created 2.0)
                          (list :id "t-gittwo" :project root :cwd root :prompt "done in git"
                                :state "done" :outcome "end-turn" :created 3.0))))
           (all '("t-gitone" "t-plain" "t-gittwo")))
      (harness-write-file-atomically global legacy)
      (harness-tasks-test--restart)
      (harness-tasks-flush)
      (should (equal '("t-gitone" "t-gittwo") (harness-tasks-test--stored-ids store)))
      (should (equal '("t-plain") (harness-tasks-test--stored-ids global)))
      (should (equal legacy (harness-read-file (concat global ".bak"))))
      (should (equal all (harness-tasks-test--ids (harness-call 'task/list))))
      (should (eq 'done (harness-tasks-test-state "t-gittwo")))
      (should (eq 'end-turn (plist-get (harness-tasks-test-task "t-gittwo") :outcome)))
      ;; From then on each is read where it is, once, and the copy stays.
      (harness-tasks-test--restart)
      (should (equal all (harness-tasks-test--ids (harness-call 'task/list))))
      (harness-tasks-flush)
      (should (equal legacy (harness-read-file (concat global ".bak")))))))

(ert-deftest harness-tasks-move-after-an-in-place-reload ()
  "Reloaded under a running harness, the first save moves the tasks it holds."
  (harness-tasks-test-with
    (let* ((harness-tasks-max-running 0)
           (root (harness-tasks-test--make-repo))
           (store (harness-tasks-test--store root))
           (global (harness-tasks-test--global))
           (id (let ((harness-tasks-store-in-repository nil))
                 (prog1 (harness-tasks-test-submit "kept in the state directory at first" root)
                   (harness-tasks-flush)))))
      (should (equal (list id) (harness-tasks-test--stored-ids global)))
      (should-not (file-exists-p store))
      ;; New definitions arrive with nothing read or written by them yet.
      (harness-tasks--forget-stores)
      (let ((harness-tasks-store-in-repository t))
        (harness-tasks--set id :prompt "changed after the reload")
        (harness-tasks-flush))
      (should (equal (list id) (harness-tasks-test--stored-ids store)))
      (should-not (harness-tasks-test--stored-ids global))
      (should (equal (list id) (harness-tasks-test--stored-ids (concat global ".bak"))))
      ;; Turned off, they come back to the state directory and the store goes.
      (harness-tasks--set id :prompt "changed with the option off")
      (harness-tasks-flush)
      (should (equal (list id) (harness-tasks-test--stored-ids global)))
      (should-not (file-exists-p (file-name-directory store))))))

(ert-deftest harness-tasks-store-with-non-ascii-text-is-not-written-again ()
  ;; What a store holds is compared as text, the way it is read, so saving
  ;; what was just read is skipped for non-ASCII text too.
  (harness-tasks-test-with
    (let* ((path (expand-file-name "store.json" harness-state-directory))
           (prompt "Fix caf\N{U+E9} \N{U+2717}")
           (obj (list :tasks (harness-json-array (list (list :id "t1" :prompt prompt)))))
           (writes 0))
      (harness-tasks--write-json path obj)
      (harness-tasks--forget-stores)
      (should (equal prompt (plist-get (car (plist-get (harness-tasks--read-json path) :tasks)) :prompt)))
      (cl-letf* ((write (symbol-function 'harness-write-file-atomically))
                 ((symbol-function 'harness-write-file-atomically)
                  (lambda (&rest args) (cl-incf writes) (apply write args))))
        (harness-tasks--write-json path obj))
      (should (= 0 writes)))))

(ert-deftest harness-tasks-leave-another-harness-store-alone ()
  "Another live harness's repository store is left alone; a gone one's taken over."
  (harness-tasks-test-with
    (let* ((harness-tasks-store-in-repository t)
           (harness-tasks-max-running 0)
           (root (harness-tasks-test--make-repo))
           (other (harness-test-temp-dir))
           (store (harness-tasks-test--store root))
           (global (harness-tasks-test--global))
           (theirs (harness-json-encode
                    (list :state-directory other
                          :tasks (list (list :id "t-theirs" :project root :cwd root
                                             :prompt "another harness's" :state "pending" :created 1.0))))))
      (harness-write-file-atomically store theirs)
      (let ((id (harness-tasks-test-submit "this harness's" root)))
        (harness-tasks-flush)
        (should (equal theirs (harness-read-file store)))
        (should (equal (list id) (harness-tasks-test--ids (harness-call 'task/list root))))
        (should (equal (list id) (harness-tasks-test--stored-ids global)))
        ;; With its harness gone, the store is this one's, records and all.
        (delete-directory other t)
        (harness-tasks-test--restart)
        (harness-tasks-flush)
        (harness-tasks-test--settle)
        (should (equal (list "t-theirs" id) (harness-tasks-test--ids (harness-call 'task/list root))))
        (should (equal (list "t-theirs" id) (harness-tasks-test--stored-ids store)))
        (should (equal (harness-tasks--state-directory)
                       (plist-get (harness-tasks-test--read store) :state-directory)))
        (should-not (harness-tasks-test--stored-ids global))))))

(ert-deftest harness-tasks-unwritable-repository-store-falls-back ()
  "The tasks of a repository whose store cannot be written stay in the state directory."
  (harness-tasks-test-with
    (let* ((harness-tasks-store-in-repository t)
           (harness-tasks-max-running 0)
           (root (harness-tasks-test--make-repo))
           (global (harness-tasks-test--global)))
      ;; A file where the store's directory would go.
      (with-temp-file (expand-file-name ".git/harness" root) (insert "in the way\n"))
      (let ((id (harness-tasks-test-submit "kept all the same" root)))
        (harness-tasks-flush)
        (should (equal (list id) (harness-tasks-test--stored-ids global)))
        (should-not (file-exists-p (expand-file-name "task-stores.json" harness-state-directory)))
        (harness-tasks--set id :prompt "changed")
        (harness-tasks-flush)
        (should (equal "changed" (plist-get (car (harness-tasks-test--read global)) :prompt)))))))

;;;; BTW: side conversations about the board

(defvar harness-tasks--btw-prompt)

(defun harness-tasks-test--ids (sessions)
  "Return the ids of SESSIONS."
  (mapcar (lambda (s) (plist-get s :id)) sessions))

(ert-deftest harness-tasks-btw-is-about-the-board ()
  "Only the board's BTWs, BTWs without a parent, are told to answer about the tasks.
Each is a new session, never an earlier one."
  (harness-tasks-test-with
    (let* ((btw (harness-call 'task/btw default-directory "btw: how goes"))
           (again (harness-call 'task/btw default-directory "btw: how goes"))
           (id (harness-tasks-test-submit "fix the parser"))
           (task-session (harness-call 'session/get (plist-get (harness-tasks-test-task id) :session)))
           (plain (harness-call 'session/create :cwd default-directory :model "demo:scripted"))
           (side (harness-call 'session/btw (plist-get plain :id))))
      (should (eq 'btw (plist-get btw :kind)))
      (should-not (plist-get btw :parent-id))
      (should (equal "btw: how goes" (plist-get btw :name)))
      ;; Asked again, the board starts another conversation, blank.
      (should-not (equal (plist-get btw :id) (plist-get again :id)))
      (should (eq 'btw (plist-get again :kind)))
      (should-not (harness-call 'session/nodes (plist-get again :id)))
      (should-not (plist-get again :provider-state))
      (should (equal (concat "Base.\n\n" harness-tasks--btw-prompt "\n")
                     (harness-run-filter 'agent/system-prompt "Base." btw)))
      ;; Other sessions and a BTW over a session are left alone.  A task
      ;; session, worktree or not, is told to hand its finished work in.
      (should (equal (plist-get plain :id) (plist-get side :parent-id)))
      (dolist (s (list plain side))
        (should (equal "Base." (harness-run-filter 'agent/system-prompt "Base." s))))
      (let ((task-prompt (harness-run-filter 'agent/system-prompt "Base." task-session)))
        (should (string-match-p "## Task mode" task-prompt))
        (should (string-match-p "hand_in" task-prompt)))
      (let ((harness-tasks--btw-prompt nil))
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
          (should (cl-some (lambda (s) (string-match-p (regexp-quote harness-tasks--btw-prompt) s)) systems)))))))

(defvar harness-btw-thinking)

(ert-deftest harness-tasks-btw-thinks-at-the-btw-level ()
  "A conversation about the board starts at the BTW level, like every BTW.
The level is fitted to what the model offers (`harness-session--btw-thinking'):
the demo model has low and high, so medium becomes low, the nearest
below it, and max becomes high.  With nil it starts at the level the
project configures instead."
  (harness-tasks-test-with
    ;; Not a task: the project's usual model, whose levels the demo
    ;; catalogue lists (low and high).
    (let ((harness-model "demo:scripted") (harness-thinking "high") (harness-btw-thinking "low"))
      (should (equal "low" (plist-get (harness-call 'task/btw default-directory) :thinking)))
      (let ((harness-btw-thinking "medium"))
        (should (equal "low" (plist-get (harness-call 'task/btw default-directory) :thinking))))
      (let ((harness-btw-thinking "max"))
        (should (equal "high" (plist-get (harness-call 'task/btw default-directory) :thinking))))
      (let ((harness-btw-thinking nil))
        (should (equal "high" (plist-get (harness-call 'task/btw default-directory) :thinking)))))))

(defvar harness-model)
(defvar harness-btw-model)
(defvar harness-providers)
(declare-function harness-provider--forget "harness-provider")

(defmacro harness-tasks-test-with-tiers (&rest body)
  "Run BODY in `harness-tasks-test-with' with provider `test-tier' defined too.
Its cheap tier is the model small, beside big; the demo provider has the
one model, so its cheap tier is itself."
  (declare (indent 0))
  `(harness-tasks-test-with
     (unwind-protect
         (progn
           (harness-define-provider 'test-tier
             :complete #'ignore
             :tiers '(:cheap "small")
             :models (lambda ()
                       (harness-resolved
                        (list (list :name "big" :thinking-levels '("low" "medium" "high"))
                              (list :name "small" :thinking-levels '("low" "medium" "high"))))))
           ,@body)
       (remhash 'test-tier harness-providers)
       (harness-provider--forget 'test-tier))))

(ert-deftest harness-tasks-btw-runs-on-the-cheap-tier ()
  "A conversation about the board runs on the cheap tier of the project's model.
Like every BTW: `harness-btw-model' chooses another model, and a model
given to `task/btw' wins over it for that conversation alone, over the
wire too.  The effort is `harness-btw-thinking' as ever."
  (harness-tasks-test-with-tiers
    (let ((harness-model "test-tier:big") (harness-btw-thinking "low") (cwd default-directory))
      (cl-flet ((model-of (&rest args)
                  (plist-get (apply #'harness-call 'task/btw cwd "btw" args) :model)))
        (should (equal "test-tier:small" (model-of)))
        (should (equal "low" (plist-get (harness-call 'task/btw cwd) :thinking)))
        ;; The setting.
        (let ((harness-btw-model nil))
          (should (equal "test-tier:big" (model-of))))
        (let ((harness-btw-model "demo:scripted"))
          (should (equal "demo:scripted" (model-of))))
        ;; A model for this one, blank being none.
        (should (equal "test-tier:big" (model-of "test-tier:big")))
        (should (equal "demo:scripted" (model-of "demo:scripted")))
        (let ((harness-btw-model nil))
          (should (equal "test-tier:small" (model-of "test-tier:small"))))
        (dolist (blank '(nil "" "  "))
          (should (equal "test-tier:small" (model-of blank))))
        ;; Over the wire, where the board asks for it: the model goes only when chosen.
        (let* ((conn (harness-acp-connect))
               (chosen (harness-test-await
                        (harness-acp-request conn "_harness/task/btw"
                                             (list :cwd cwd :name "btw" :model "test-tier:big"))))
               (usual (harness-test-await
                       (harness-acp-request conn "_harness/task/btw" (list :cwd cwd :name "btw")))))
          (should (equal "test-tier:big" (plist-get chosen :model)))
          (should (equal "test-tier:small" (plist-get usual :model)))
          (should-not (plist-get chosen :parent-id)))
        ;; Still the project's model when the provider has no cheaper one.
        (let ((harness-model "demo:scripted"))
          (should (equal "demo:scripted" (model-of))))))))

(ert-deftest harness-tasks-btw-model-follows-the-policy ()
  "A policy on `harness-model' fixes a board BTW's model, and a model that differs is refused."
  (harness-tasks-test-with-tiers
    (harness-test-with-policy '((harness-model . "test-tier:big"))
      (let ((cwd default-directory))
        (should (equal "test-tier:big" (plist-get (harness-call 'task/btw cwd) :model)))
        (should (equal "test-tier:big" (plist-get (harness-call 'task/btw cwd "btw" "test-tier:big") :model)))
        (let ((err (should-error (harness-call 'task/btw cwd "btw" "test-tier:small"))))
          (should (string-match-p "harness-model is set by policy" (cadr err))))))))

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

;;;; Review: finished work waits for the user
;;
;; With `harness-tasks-require-verification' a task whose turn ends
;; cleanly waits in review; `task/verify' merges it (in git) and
;; completes it, `task/reject' sends it back to its session with feedback.

(defvar harness-tasks--reject-message)
(defvar harness-tasks--aside-message)

(ert-deftest harness-tasks-review-then-verify ()
  "Finished work waits in review, not done, until the user verifies it."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (reviews nil))
      (harness-on 'task/review (lambda (task) (push (plist-get task :id) reviews)))
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-tasks-test-wait-state id 'review)
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'review (plist-get task :column)))
          (should (eq 'end-turn (plist-get task :outcome)))
          (should (plist-get task :finished))
          (should-not (plist-get task :verified)))
        (should (equal (list id) reviews))
        ;; Nothing takes it further but the user.
        (harness-tasks--schedule)
        (should (eq 'review (harness-tasks-test-state id)))
        (let ((task (harness-call 'task/verify id)))
          (should (eq 'done (plist-get task :state)))
          (should (eq 'done (plist-get task :column)))
          (should (eq t (plist-get task :verified)))
          (should (numberp (plist-get task :verified-at))))
        (should-error (harness-call 'task/verify id))
        (should-error (harness-call 'task/reject id "too late"))
        (should (= 1 (length (harness-tasks-test-user-texts sid))))
        ;; More work after that is reviewed again.
        (harness-call 'task/prompt id "and also this")
        (harness-tasks-test-wait-state id 'review)
        (should-not (plist-get (harness-tasks-test-task id) :verified))
        (should-not (plist-get (harness-tasks-test-task id) :verified-at))
        (should (equal (list id id) reviews))))))

(ert-deftest harness-tasks-review-off-is-done-at-once ()
  "Without review a finished task is done at once, as before."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification nil)
          (reviews nil))
      (harness-on 'task/review (lambda (task) (push task reviews)))
      (let ((id (harness-tasks-test-submit "fix the parser")))
        (harness-tasks-test-wait-state id 'done)
        (should (eq 'end-turn (plist-get (harness-tasks-test-task id) :outcome)))
        (should-not (plist-get (harness-tasks-test-task id) :verified))
        (should-not reviews)
        (should-error (harness-call 'task/verify id))))))

(ert-deftest harness-tasks-review-reject-works-on-it-again ()
  "Sent back with feedback, the same session works on the task again and it returns to review."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t))
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (plist-get (harness-tasks-test-task id) :session))
             (states nil))
        (harness-tasks-test-wait-state id 'review)
        (should-error (harness-call 'task/reject id "  "))
        (should-error (harness-call 'task/reject "t-nonexistent" "feedback"))
        (harness-on 'task/changed (lambda (task) (push (plist-get task :state) states)))
        (let ((task (harness-call 'task/reject id "  Nested quotes still break.  ")))
          (should (eq 'active (plist-get task :state)))
          (should (eq 'active (plist-get task :column)))
          (should-not (plist-get task :finished)))
        (harness-tasks-test-wait-state id 'review)
        (should (memq 'active states))
        (let* ((task (harness-tasks-test-task id))
               (round (car (plist-get task :feedback))))
          (should (equal sid (plist-get task :session)))
          (should (= 1 (length (plist-get task :feedback))))
          (should (equal "Nested quotes still break." (plist-get round :text)))
          (should (numberp (plist-get round :at))))
        ;; The session got the feedback as a new prompt, opened by the reject text.
        (let ((texts (harness-tasks-test-user-texts sid)))
          (should (= 2 (length texts)))
          (should (string-prefix-p harness-tasks--reject-message (cadr texts)))
          (should (string-suffix-p "\n\nNested quotes still break." (cadr texts))))
        ;; The feedback is the user's own words, so the message is theirs.
        (should-not (harness-node-sender (cadr (harness-tasks-test-user-nodes sid))))
        ;; A second round adds to the first; then the work is accepted.
        (harness-call 'task/reject id "And the docs.")
        (harness-tasks-test-wait-state id 'review)
        (should (equal '("Nested quotes still break." "And the docs.")
                       (mapcar (lambda (round) (plist-get round :text))
                               (plist-get (harness-tasks-test-task id) :feedback))))
        (harness-call 'task/verify id)
        (should (eq 'done (harness-tasks-test-state id)))
        (should (= 2 (length (plist-get (harness-tasks-test-task id) :feedback))))
        (should (= 3 (length (harness-tasks-test-user-texts sid))))))))

(ert-deftest harness-tasks-review-user-message-sends-it-back ()
  "A message the user sends the session of a task in review sends it back.
That is as `task/reject' does, wherever the user wrote it: the
session's chat, without [Send back] (`agent/prompt'), or the board's
reply (`task/prompt').  The task is active at once, the round of
feedback is kept and the agent gets the message opened by the reject
text, as the user's.  The harness's own messages do not count, and
neither do another session's (see
`harness-tasks-review-session-message-is-no-review')."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t))
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (plist-get (harness-tasks-test-task id) :session))
             (rounds (lambda () (mapcar (lambda (round) (plist-get round :text))
                                        (plist-get (harness-tasks-test-task id) :feedback))))
             (last-user (lambda () (car (last (harness-tasks-test-user-nodes sid))))))
        (harness-tasks-test-wait-state id 'review)
        ;; Typed in the session's own chat.
        (harness-call 'agent/prompt sid "  Nested quotes still break.  ")
        ;; Sent back at once: the board and the banner need not wait for the turn.
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'active (plist-get task :state)))
          (should (eq 'active (plist-get task :column))))
        (should (equal '("Nested quotes still break.") (funcall rounds)))
        (harness-tasks-test-wait-state id 'review)
        (should (equal (harness-tasks--reject-text "Nested quotes still break.")
                       (plist-get (funcall last-user) :content)))
        (should-not (harness-node-sender (funcall last-user)))
        ;; A message through `task/prompt' without a sender: the board's reply.
        (harness-call 'task/prompt id "And the docs.")
        (should (eq 'active (harness-tasks-test-state id)))
        (harness-tasks-test-wait-state id 'review)
        (should (equal '("Nested quotes still break." "And the docs.") (funcall rounds)))
        (should (equal (harness-tasks--reject-text "And the docs.") (plist-get (funcall last-user) :content)))
        (should-not (harness-node-sender (funcall last-user)))
        ;; The harness's own message is not feedback: no round, as it was sent.
        (harness-call 'agent/prompt sid "Carry on." (harness-tasks--from-harness))
        (harness-tasks-test-wait-state id 'review)
        (should (= 2 (length (funcall rounds))))
        (should (equal "Carry on." (plist-get (funcall last-user) :content)))
        ;; Sent back twice, then accepted as any review.
        (harness-call 'task/verify id)
        (should (eq 'done (harness-tasks-test-state id)))
        ;; Done, a message is a follow-up again, not feedback.
        (harness-call 'agent/prompt sid "One more thing.")
        (harness-tasks-test-wait-state id 'review)
        (should (= 2 (length (funcall rounds))))
        (should (equal "One more thing." (plist-get (funcall last-user) :content)))))))

(defconst harness-tasks-test--other
  (list :kind 'session :id "s-other" :name "Onboard benito")
  "The sender of the other session's messages, as `harness-sender-session' makes it.")

(defconst harness-tasks-test--other-header
  "[Message from session s-other \"Onboard benito\"]\n\n"
  "The header session_send and task_control open the other session's messages with.")

(ert-deftest harness-tasks-review-session-message-is-no-review ()
  "Another session's message to a task in review does not send it back.
Only the user reviews.  Through `agent/prompt' (as session_send sends
it) or `task/prompt' (as task_control's message does), the agent gets
it as that session's, opened by the aside text and never the reject
text, and no round of feedback is kept.  The task is active while its
session deals with it and waits for review again once the turn ends,
the report handed in standing: the reply is to the other session.  The
user's feedback after that still sends it back, reject text and all."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo-script-override
           '((:type tool-call :id "h1" :name "hand_in"
              :input (:problem "Nested quotes break the parser" :summary "# Done" :evidence ("looks good"))))))
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (plist-get (harness-tasks-test-task id) :session))
             (from harness-tasks-test--other)
             (sent (lambda (text) (concat harness-tasks-test--other-header text)))
             (last-user (lambda () (car (last (harness-tasks-test-user-nodes sid))))))
        (harness-tasks-test-wait-state id 'review)
        (should (equal "# Done" (plist-get (harness-tasks-test--report id) :summary)))
        (setq harness-provider-demo-script-override
              '((:type text :delta "Noted, thanks.\n") (:type done :stop-reason end-turn)))
        ;; As session_send delivers it.
        (harness-call 'agent/prompt sid (funcall sent "Applying now.") (list :from from))
        ;; Active while its session deals with it, but not sent back.
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'active (plist-get task :state)))
          (should (eq 'active (plist-get task :column)))
          (should-not (plist-get task :feedback)))
        (harness-tasks-test-wait-state id 'review)
        (let ((node (funcall last-user)))
          (should (equal (harness-tasks--aside-text (funcall sent "Applying now."))
                         (plist-get node :content)))
          (should (string-prefix-p harness-tasks--aside-message (plist-get node :content)))
          (should-not (string-search harness-tasks--reject-message (plist-get node :content)))
          (should (equal from (harness-node-sender node))))
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'review (plist-get task :column)))
          (should-not (plist-get task :feedback))
          (should-not (plist-get task :reopened)))
        ;; The report handed in stands: the reply was to the other session.
        (should (equal "# Done" (plist-get (harness-tasks-test--report id) :summary)))
        (should-not (harness-tasks-test--missing-p id))
        ;; The same through `task/prompt', as task_control's message sends it.
        (harness-call 'task/prompt id (funcall sent "The Helm job finished.") nil (list :from from))
        (should (eq 'active (harness-tasks-test-state id)))
        (should-not (plist-get (harness-tasks-test-task id) :feedback))
        (harness-tasks-test-wait-state id 'review)
        (let ((node (funcall last-user)))
          (should (equal (harness-tasks--aside-text (funcall sent "The Helm job finished."))
                         (plist-get node :content)))
          (should-not (string-search harness-tasks--reject-message (plist-get node :content)))
          (should (equal from (harness-node-sender node))))
        (should-not (plist-get (harness-tasks-test-task id) :feedback))
        (should (equal "# Done" (plist-get (harness-tasks-test--report id) :summary)))
        ;; The user's own feedback still sends it back, opened by the reject text.
        (harness-call 'task/reject id "Nested quotes still break.")
        (harness-tasks-test-wait-state id 'review)
        (should (equal (harness-tasks--reject-text "Nested quotes still break.")
                       (plist-get (funcall last-user) :content)))
        (should-not (harness-node-sender (funcall last-user)))
        (should (equal '("Nested quotes still break.")
                       (mapcar (lambda (round) (plist-get round :text))
                               (plist-get (harness-tasks-test-task id) :feedback))))
        ;; That is a round of its own: handing nothing in, its report says so.
        (should (harness-tasks-test--missing-p id))
        (should (equal "Noted, thanks." (plist-get (harness-tasks-test--report id) :summary)))))))

(ert-deftest harness-tasks-review-session-message-keeps-a-missing-report ()
  "A round recorded without a report keeps it through another session's message.
The report says what the round's work last said, not the reply the
session gave the other one."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo-script-override
           '((:type text :delta "I fixed the parser; see the diff.\n") (:type done :stop-reason end-turn))))
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-tasks-test-wait-state id 'review)
        (should (harness-tasks-test--missing-p id))
        (should (equal "I fixed the parser; see the diff." (plist-get (harness-tasks-test--report id) :summary)))
        (setq harness-provider-demo-script-override
              '((:type text :delta "Noted, thanks.\n") (:type done :stop-reason end-turn)))
        (harness-call 'agent/prompt sid (concat harness-tasks-test--other-header "Applying now.")
                      (list :from harness-tasks-test--other))
        (should (eq 'active (harness-tasks-test-state id)))
        (harness-tasks-test-wait-state id 'review)
        ;; The session replied, and its reply is not the report's.
        (should (equal "Noted, thanks." (harness-tasks--last-message sid 0)))
        (should (harness-tasks-test--missing-p id))
        (should (equal "I fixed the parser; see the diff." (plist-get (harness-tasks-test--report id) :summary)))
        (should-not (plist-get (harness-tasks-test-task id) :feedback))))))

(ert-deftest harness-tasks-review-queued-session-message-is-no-review ()
  "Another session's message queued while the task works is no review when it goes out.
It goes out once the task waits for review, and the task works on it
and waits for review again without being sent back."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo--delay 0.05)
          (reviews 0))
      (harness-on 'task/review (lambda (_) (cl-incf reviews)))
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (plist-get (harness-tasks-test-task id) :session))
             (text (concat harness-tasks-test--other-header "Rebase when you can.")))
        (should (harness-call 'agent/running sid))
        (harness-call 'agent/prompt sid text (list :queue t :from harness-tasks-test--other))
        (harness-test-wait (lambda () (and (= reviews 2) (eq 'review (harness-tasks-test-state id))))
                           10 "the task back in review after the queued message")
        (should-not (plist-get (harness-tasks-test-task id) :feedback))
        (let ((node (car (last (harness-tasks-test-user-nodes sid)))))
          (should (equal (harness-tasks--aside-text text) (plist-get node :content)))
          (should (equal harness-tasks-test--other (harness-node-sender node))))))))

(ert-deftest harness-tasks-review-queued-message-sends-it-back ()
  "A message queued while the task works goes out when it finishes, and sends it back."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo--delay 0.05)
          (reviews 0))
      (harness-on 'task/review (lambda (_) (cl-incf reviews)))
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (should (harness-call 'agent/running sid))
        (harness-call 'agent/prompt sid "Also the README." '(:queue t))
        ;; It waits for review once, goes back to work on the queued
        ;; message, then waits for review again.
        (harness-test-wait (lambda () (and (= reviews 2) (eq 'review (harness-tasks-test-state id))))
                           10 "the task back in review after the queued message")
        (should (equal '("Also the README.")
                       (mapcar (lambda (round) (plist-get round :text))
                               (plist-get (harness-tasks-test-task id) :feedback))))
        (should (equal (harness-tasks--reject-text "Also the README.")
                       (car (last (harness-tasks-test-user-texts sid)))))))))

(ert-deftest harness-tasks-review-reject-with-attachments-only ()
  "Feedback may be attachments alone, a screenshot say, but not nothing."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (shot (expand-file-name "after.png" default-directory)))
      (with-temp-file shot (insert "not really a png"))
      (let* ((id (harness-tasks-test-submit "fix the layout"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-tasks-test-wait-state id 'review)
        (should-error (harness-call 'task/reject id "" nil))
        (should-error (harness-call 'task/reject id "  " nil))
        (harness-call 'task/reject id "" (list (list :path shot :mime "image/png" :name "after.png" :size 16)))
        (should (eq 'active (harness-tasks-test-state id)))
        (harness-tasks-test-wait-state id 'review)
        (should (equal '("[image]") (mapcar (lambda (round) (plist-get round :text))
                                            (plist-get (harness-tasks-test-task id) :feedback))))
        (let ((message (car (last (harness-tasks-test-user-nodes sid)))))
          (should (string-prefix-p harness-tasks--reject-message (plist-get message :content)))
          (should (equal '("text" "image") (mapcar (lambda (b) (plist-get b :type)) (plist-get message :blocks)))))))))

(ert-deftest harness-tasks-review-failed-work-is-not-reviewed ()
  "Only work that finished cleanly goes to review; work that stopped needs the user as before."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo-script-override
           '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
      (let ((id (harness-tasks-test-submit "will fail")))
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :outcome)) 5 "an outcome")
        (should (eq 'active (harness-tasks-test-state id)))
        (should (eq 'needs-input (plist-get (harness-tasks-test-task id) :column)))
        (should-error (harness-call 'task/verify id))
        ;; A reply that finishes the work puts it in review.
        (let ((harness-provider-demo-script-override harness-tasks-test-script))
          (harness-call 'task/prompt id "try again")
          (harness-tasks-test-wait-state id 'review))))))

(ert-deftest harness-tasks-review-archive-and-mark-done ()
  "Archive all leaves work waiting for review alone; one archived by hand comes back to review."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t))
      (let ((a (harness-tasks-test-submit "a"))
            (b (harness-tasks-test-submit "b")))
        (harness-tasks-test-wait-state a 'review)
        (harness-tasks-test-wait-state b 'review)
        (should (= 0 (harness-call 'task/archive-done default-directory)))
        (should-not (plist-get (harness-tasks-test-task a) :archived))
        (harness-call 'task/archive a)
        (should (plist-get (harness-tasks-test-task a) :archived))
        (harness-call 'task/archive a t)
        (should (eq 'review (plist-get (harness-tasks-test-task a) :column)))
        ;; Marking it done by hand accepts it.
        (harness-call 'task/complete b)
        (should (eq 'done (harness-tasks-test-state b)))
        (should (plist-get (harness-tasks-test-task b) :verified))))))

(ert-deftest harness-tasks-review-survives-a-restart ()
  "A task in review, and its rounds of feedback, wait on across a restart."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t))
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-tasks-test-wait-state id 'review)
        (harness-call 'task/reject id "Again, please.")
        (harness-tasks-test-wait-state id 'review)
        (harness-tasks-test--restart)
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'review (plist-get task :state)))
          (should (eq 'review (plist-get task :column)))
          (should (equal '("Again, please.") (mapcar (lambda (round) (plist-get round :text))
                                                     (plist-get task :feedback)))))
        ;; Nothing carried on by itself: the task and the feedback, nothing else.
        (should (= 2 (length (harness-tasks-test-user-texts sid))))
        (harness-call 'task/verify id)
        (harness-tasks-test--restart)
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'done (plist-get task :state)))
          (should (plist-get task :verified))
          (should (plist-get task :verified-at)))))))

(ert-deftest harness-tasks-git-review-before-merge ()
  "In git, finished work waits in review unmerged; verifying it merges it, and then it is done."
  (harness-tasks-test-with-git
    (let ((harness-tasks-require-verification t))
      (let ((id (harness-tasks-test-submit "Change the shared file")))
        (harness-tasks-test-wait-state id 'review)
        (let ((task (harness-tasks-test-task id)))
          (should-not (plist-get task :merged))
          (should-not (plist-get task :merge-status))
          ;; Nothing reached main: the work waits on its branch.
          (should (equal "one\n" (harness-tasks-test--main-text root)))
          (should (equal "two\n" (harness-tasks-test--main-text (plist-get task :worktree)))))
        (should-error (harness-call 'task/merge id))
        (should (memq (plist-get (harness-call 'task/verify id) :state) '(merging done)))
        (harness-tasks-test-wait-state id 'done)
        (let ((task (harness-tasks-test-task id)))
          (should (plist-get task :merged))
          (should (plist-get task :verified))
          (should (eq 'merged (plist-get task :outcome))))
        (should (equal "two\n" (harness-tasks-test--main-text root)))))))

(ert-deftest harness-tasks-git-done-event-when-merged ()
  "A task the merge queue completes is done `merged', once."
  (harness-tasks-test-with-git
    (let ((done nil))
      (harness-on 'task/done (lambda (task how) (push (list (plist-get task :id) how (plist-get task :merged)) done)))
      (let ((id (harness-tasks-test-submit "Change the shared file")))
        (harness-tasks-test-wait-state id 'done)
        (should (equal (list (list id 'merged t)) done))))))

(ert-deftest harness-tasks-git-merge-queue-column ()
  "A task whose branch is in the merge queue shows in a column of its own.
The task record keeps when the branch joined the queue; done only once
the merge finished."
  (harness-tasks-test-with-git
    (let ((harness-tasks-require-verification t)
          (columns nil))
      (harness-on 'task/changed (lambda (task) (push (plist-get task :column) columns)))
      (let ((id (harness-tasks-test-submit "Change the shared file")))
        (harness-tasks-test-wait-state id 'review)
        (should-not (plist-get (harness-tasks-test-task id) :merge-queued))
        (harness-call 'task/verify id)
        (harness-tasks-test-wait-state id 'done)
        ;; It waited in merging while the queue held its branch, and the
        ;; time it joined the queue is kept.
        (should (memq 'merging columns))
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'done (plist-get task :column)))
          (should-not (plist-get task :merge-status))
          (should (numberp (plist-get task :merge-queued))))
        (should (equal "two\n" (harness-tasks-test--main-text root)))))))

(ert-deftest harness-tasks-column-merging-for-every-place-in-the-queue ()
  "Queued, merging and conflict all read as the merging column.
A session the user has to answer for comes first: the queue waits too."
  (harness-tasks-test-with
    (let* ((sid (plist-get (harness-call 'session/create :cwd default-directory) :id))
           (id "t-in-the-queue")
           (task (list :id id :project default-directory :cwd default-directory
                       :prompt "conflicted" :session sid :state 'merging
                       :merge-status 'queued :created (float-time))))
      (harness-tasks--put task)
      (dolist (status '(queued merging conflict))
        (harness-tasks--set id :merge-status status)
        (should (eq 'merging (plist-get (harness-call 'task/get id) :column))))
      (let ((pid (harness-call 'session/pending-add sid '(:kind question :payload (:question "Which?")))))
        (should (eq 'needs-input (plist-get (harness-call 'task/get id) :column)))
        (harness-call 'session/pending-resolve sid pid "theirs")
        (should (eq 'merging (plist-get (harness-call 'task/get id) :column))))
      ;; Once the merge is done it is not in the queue any more.
      (harness-tasks--set id :state 'done :merge-status nil)
      (should (eq 'done (plist-get (harness-call 'task/get id) :column))))))

(defun harness-tasks-test--lock-line (root path)
  "Return the `locked' line `git worktree list --porcelain' gives PATH of ROOT, or nil."
  (let ((dir (file-name-as-directory (file-truename path))))
    (cl-some (lambda (block)
               (let ((lines (split-string block "\n" t)))
                 (and (equal dir (file-name-as-directory (file-truename (substring (car lines) 9))))
                      (seq-find (lambda (l) (string-prefix-p "locked" l)) lines))))
             (split-string (harness-tasks-test--git root "worktree" "list" "--porcelain") "\n\n" t))))

(ert-deftest harness-tasks-git-worktree-locked-until-merged ()
  "A task's worktree is locked until its branch is merged, and again while it works after that."
  (harness-tasks-test-with-git
    (let ((harness-tasks-require-verification t))
      (let* ((id (harness-tasks-test-submit "Change the shared file"))
             (worktree nil) (lock nil))
        (harness-tasks-test-wait-state id 'review)
        (setq worktree (plist-get (harness-tasks-test-task id) :worktree)
              lock (concat "locked harness: " (plist-get (harness-tasks-test-task id) :branch)))
        (should (equal lock (harness-tasks-test--lock-line root worktree)))
        (harness-call 'task/verify id)
        (harness-tasks-test-wait-state id 'done)
        (harness-test-wait (lambda () (not (harness-tasks-test--lock-line root worktree))) 10 "the unlock")
        ;; Merged, it is left out when the harness locks the worktrees made before locks.
        (should-not (harness-test-await (harness-call 'worktree/lock-existing root)))
        (should-not (harness-tasks-test--lock-line root worktree))
        ;; A follow-up works there again: locked until that is merged too.
        (let ((harness-provider-demo-script-override
               '((:type tool-call :id "c2" :name "change_shared" :input (:text "three"))
                 (:type text :delta "Changed it again.")
                 (:type done :stop-reason end-turn))))
          (harness-call 'task/prompt id "Make it three.")
          (harness-tasks-test-wait-state id 'review))
        (harness-test-wait (lambda () (harness-tasks-test--lock-line root worktree)) 10 "the lock again")
        (should (equal lock (harness-tasks-test--lock-line root worktree)))
        (harness-call 'task/verify id)
        (harness-tasks-test-wait-state id 'done)
        (harness-test-wait (lambda () (not (harness-tasks-test--lock-line root worktree))) 10 "the second unlock")
        (should (equal "three\n" (harness-tasks-test--main-text root)))
        ;; Archived, its worktree goes.
        (harness-call 'task/archive id)
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :worktree-removed)) 30 "worktree removal")
        (should-not (file-directory-p worktree))))))

(ert-deftest harness-tasks-git-archive-removes-a-still-locked-worktree ()
  "Archiving right after the merge, before the lock is lifted, still removes the worktree."
  (harness-tasks-test-with-git
    (let ((id (harness-tasks-test-submit "Change the shared file")))
      (harness-tasks-test-wait-state id 'done)
      (let ((task (harness-tasks-test-task id)))
        ;; As if the merge queue had not unlocked it yet.
        (harness-test-wait (lambda () (not (harness-tasks-test--lock-line root (plist-get task :worktree)))) 10
                           "the merge queue's unlock")
        (harness-tasks-test--git root "worktree" "lock" "--reason" (concat "harness: " (plist-get task :branch))
                                 (directory-file-name (plist-get task :worktree)))
        (should (harness-tasks-test--lock-line root (plist-get task :worktree)))
        (harness-call 'task/archive id)
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :worktree-removed)) 30 "worktree removal")
        (should-not (file-directory-p (plist-get task :worktree)))))))

(ert-deftest harness-tasks-git-reject-continues-in-its-worktree ()
  "Sent back, the session works on in its own worktree, its conversation kept; verifying merges it all."
  (harness-tasks-test-with-git
    (let ((harness-tasks-require-verification t))
      (let* ((id (harness-tasks-test-submit "Change the shared file"))
             (sid nil) (worktree nil))
        (harness-tasks-test-wait-state id 'review)
        (setq sid (plist-get (harness-tasks-test-task id) :session)
              worktree (plist-get (harness-tasks-test-task id) :worktree))
        (harness-call 'session/set-provider-state sid '(:cli-session-id "the-conversation"))
        (let ((harness-provider-demo-script-override
               '((:type tool-call :id "c2" :name "change_shared" :input (:text "three"))
                 (:type text :delta "Changed it again.")
                 (:type done :stop-reason end-turn))))
          (harness-call 'task/reject id "Make it three.")
          (harness-tasks-test-wait-state id 'review))
        (let ((task (harness-tasks-test-task id))
              (session (harness-call 'session/get sid)))
          (should (equal sid (plist-get task :session)))
          (should (equal worktree (plist-get task :worktree)))
          (should (equal worktree (plist-get session :cwd)))
          (should (equal '(:cli-session-id "the-conversation") (plist-get session :provider-state)))
          (should-not (plist-get task :merged)))
        (should (equal "one\n" (harness-tasks-test--main-text root)))
        (should (equal "three\n" (harness-tasks-test--main-text worktree)))
        (harness-call 'task/verify id)
        (harness-tasks-test-wait-state id 'done)
        (should (equal "three\n" (harness-tasks-test--main-text root)))
        (should (= 2 harness-tasks-test--calls))))))

;;;; Work that goes on outside the session's turn
;;
;; A module can start work for a session that runs without its turn (a
;; supervisor plan's workers) and report it through `agent/outstanding'.
;; A turn that ends cleanly while some is outstanding does not finish
;; the task: it stays active and says what it waits for.

(defvar harness-tasks-test--outstanding nil
  "What the test's `agent/outstanding' handler reports, a text, or nil for nothing.")

(defun harness-tasks-test--report-outstanding (value _session-id)
  "`agent/outstanding' handler: add `harness-tasks-test--outstanding' to VALUE."
  (if harness-tasks-test--outstanding
      (concat (and value (concat value "; ")) harness-tasks-test--outstanding)
    value))

(defun harness-tasks-test--waiting (id)
  "Return what task ID waits for, or nil."
  (plist-get (harness-tasks-test-task id) :waiting))

(ert-deftest harness-tasks-outstanding-work-keeps-the-task-active ()
  "A task whose turn ends while work it started runs stays active, and says why.
It is not in review, not done and not merging.  Once nothing runs, the
turn after that ends as usual, in review, and the wait is gone."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (harness-tasks-test--outstanding "2 workers running")
          (reviews nil)
          (changes nil))
      (harness-add-filter 'agent/outstanding #'harness-tasks-test--report-outstanding)
      (harness-on 'task/review (lambda (task) (push (plist-get task :id) reviews)))
      (harness-on 'task/changed
                  (lambda (task) (push (list (plist-get task :state) (plist-get task :waiting)) changes)))
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-test-wait (lambda () (harness-tasks-test--waiting id)) 5 "the task to wait")
        (harness-test-wait (lambda () (not (harness-call 'agent/running sid))) 5 "the turn to end")
        (let ((task (harness-tasks-test-task id)))
          (should (equal "2 workers running" (plist-get task :waiting)))
          (should (eq 'active (plist-get task :state)))
          (should (eq 'active (plist-get task :column)))
          (should-not (plist-get task :outcome))
          (should-not (plist-get task :finished))
          (should-not (plist-get task :merge-status)))
        ;; Nothing takes it further, however long it waits, and the other
        ;; changes to the task leave the wait alone.
        (harness-tasks--schedule)
        (harness-call 'task/set-recap id :recap "Fixing the parser")
        (accept-process-output nil 0.2)
        (should (eq 'active (harness-tasks-test-state id)))
        (should (equal "2 workers running" (harness-tasks-test--waiting id)))
        (should-not reviews)
        ;; The work is done: the session takes a turn and, with nothing
        ;; outstanding, ends it in review.
        (setq harness-tasks-test--outstanding nil)
        (harness-call 'agent/prompt sid "The workers are done." (harness-tasks--from-harness))
        (harness-tasks-test-wait-state id 'review)
        (let ((task (harness-tasks-test-task id)))
          (should-not (plist-get task :waiting))
          (should-not (plist-member task :waiting))
          (should (eq 'review (plist-get task :column)))
          (should (eq 'end-turn (plist-get task :outcome)))
          (should (plist-get task :finished)))
        (should (equal (list id) reviews))
        ;; The wait ended when the state next changed, and never came back.
        (let* ((seen (reverse changes))
               (first (cl-position-if #'cadr seen)))
          (should first)
          (should (equal '(active "2 workers running") (nth first seen)))
          (should (equal '(review nil) (car (last seen))))
          (should-not (cl-some #'cadr (nthcdr (1+ (cl-position-if-not #'cadr seen :start first)) seen))))))))

(ert-deftest harness-tasks-outstanding-work-is-asked-each-time-a-turn-ends ()
  "A task goes on waiting for as long as work is outstanding, whatever it is.
A turn that ends again with some left puts the text it says then."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (harness-tasks-test--outstanding "3 workers running"))
      (harness-add-filter 'agent/outstanding #'harness-tasks-test--report-outstanding)
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-test-wait (lambda () (harness-tasks-test--waiting id)) 5 "the task to wait")
        (harness-test-wait (lambda () (not (harness-call 'agent/running sid))) 5 "the turn to end")
        (setq harness-tasks-test--outstanding "1 worker running")
        (harness-call 'agent/prompt sid "One is done." (harness-tasks--from-harness))
        (harness-test-wait (lambda () (equal "1 worker running" (harness-tasks-test--waiting id))) 5
                           "the new text")
        (harness-test-wait (lambda () (not (harness-call 'agent/running sid))) 5 "the turn to end")
        (should (eq 'active (harness-tasks-test-state id)))
        (should (equal "1 worker running" (harness-tasks-test--waiting id)))))))

(ert-deftest harness-tasks-outstanding-work-holds-back-done-too ()
  "Without review a task is done when nothing is outstanding, not before."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification nil)
          (harness-tasks-test--outstanding "a worker running"))
      (harness-add-filter 'agent/outstanding #'harness-tasks-test--report-outstanding)
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-test-wait (lambda () (harness-tasks-test--waiting id)) 5 "the task to wait")
        (harness-test-wait (lambda () (not (harness-call 'agent/running sid))) 5 "the turn to end")
        (should (eq 'active (harness-tasks-test-state id)))
        (should-not (plist-get (harness-tasks-test-task id) :finished))
        (setq harness-tasks-test--outstanding nil)
        (harness-call 'agent/prompt sid "It is done." (harness-tasks--from-harness))
        (harness-tasks-test-wait-state id 'done)
        (should-not (plist-member (harness-tasks-test-task id) :waiting))))))

(ert-deftest harness-tasks-outstanding-work-is-no-reason-to-hide-a-stop ()
  "A turn that stops some other way than cleanly needs the user, as it always did.
Nor does a write-up wait: it is not the work."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (harness-tasks-test--outstanding "2 workers running"))
      (harness-add-filter 'agent/outstanding #'harness-tasks-test--report-outstanding)
      (let ((harness-provider-demo-script-override
             '((:type text :delta "oops") (:type done :stop-reason error :error "boom"))))
        (let ((id (harness-tasks-test-submit "will fail")))
          (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :outcome)) 5 "an outcome")
          (should (eq 'active (harness-tasks-test-state id)))
          (should (eq 'needs-input (plist-get (harness-tasks-test-task id) :column)))
          (should-not (harness-tasks-test--waiting id))))
      (let ((harness-provider-demo-script-override
             `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn))))
        (let ((id (harness-tasks-test-refine "the parser chokes on nested quotes")))
          (harness-tasks-test-wait-state id 'pending)
          (should (plist-get (harness-tasks-test-task id) :backlog))
          (should-not (harness-tasks-test--waiting id)))))))

(declare-function harness-tasks--on-turn-ended "harness-tasks")

(ert-deftest harness-tasks-outstanding-work-does-not-hold-up-a-merge ()
  "A turn for the merge queue, resolving a conflict, is not the work's end.
The merge decides what happens to the task, whatever is outstanding."
  (harness-tasks-test-with
    (let* ((id (harness-tasks-test-submit "fix the parser"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (harness-tasks-test-wait-state id 'done)
      (harness-tasks--set id :state 'merging :merge-status 'conflict)
      (harness-add-filter 'agent/outstanding #'harness-tasks-test--report-outstanding)
      (let ((harness-tasks-test--outstanding "2 workers running"))
        (harness-tasks--on-turn-ended sid 'end-turn))
      (let ((task (harness-tasks-test-task id)))
        (should (eq 'merging (plist-get task :state)))
        (should (eq 'conflict (plist-get task :merge-status)))
        (should-not (plist-member task :waiting))))))

(ert-deftest harness-tasks-outstanding-work-needs-the-agent-method ()
  "Without the method that tells what is outstanding, a task finishes as usual."
  (harness-tasks-test-with
    (let ((harness-tasks-require-verification t)
          (harness-tasks-test--outstanding "2 workers running"))
      (harness-add-filter 'agent/outstanding #'harness-tasks-test--report-outstanding)
      (harness-unregister-method 'agent/outstanding)
      (let ((id (harness-tasks-test-submit "fix the parser")))
        (harness-tasks-test-wait-state id 'review)
        (should-not (harness-tasks-test--waiting id))))))

;;;; Handing the finished work in
;;
;; `hand_in' is how a task's session says it is done: the tool records
;; the summary and the evidence on the task and ends the turn, which the
;; review step then picks up as usual.

(defvar harness-tasks-test--handin-evidence nil
  "Evidence the test's hand_in call hands in, when not the default.")

(defun harness-tasks-test--handin-input ()
  "Return the input of the test's hand_in call."
  (list :problem "Nested quotes in the parser"
        :summary "# Done\n\nThe parser handles nested quotes now."
        :evidence (or harness-tasks-test--handin-evidence
                      (list (list :code "(parse \"a\\\"b\")" :language "elisp"
                                  :caption "The new case")))))

(ert-deftest harness-tasks-hand-in-waits-for-review ()
  "A task session handing its work in ends the turn and waits for the user.
The tool alone ends the turn: the scripted provider never says done."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo-script-override
           '((:type text :delta "All done.\n")
             (:type tool-call :id "h1" :name "hand_in"
              :input (:problem "Nested quotes break the parser"
                      :reproduction "Parse `(a \"b\")` and watch it stop at the quote."
                      :summary "# Done" :evidence ("looks good")))
             ;; No `done' event: without hand_in ending the turn, this never finishes.
             (:type text :delta " this must not matter"))))
      (let* ((id (harness-tasks-test-submit "fix the parser"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (princ (format "DIAG state=%S col=%S outcome=%S report=%S status=%S err=%S\n"
                       (plist-get (harness-tasks-test-task id) :state)
                       (plist-get (harness-tasks-test-task id) :column)
                       (plist-get (harness-tasks-test-task id) :outcome)
                       (plist-get (harness-tasks-test-task id) :report)
                       (plist-get (harness-call 'session/get sid) :status)
                       (plist-get (harness-tasks-test-task id) :error)))
        (harness-tasks-test-wait-state id 'review)
        (let* ((task (harness-tasks-test-task id))
               (report (plist-get task :report)))
          (should (equal "Nested quotes break the parser" (plist-get report :problem)))
          (should (equal "Parse `(a \"b\")` and watch it stop at the quote."
                         (plist-get report :reproduction)))
          (should (equal "# Done" (plist-get report :summary)))
          (should (numberp (plist-get report :at)))
          (should (equal '((:kind "note" :text "looks good")) (plist-get report :evidence)))
          ;; Handed in: the harness leaves the report as it came.
          (should-not (plist-get report :missing)))
        ;; The transcript shows the call and what it said.
        (let ((result (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                                                   (equal (plist-get n :call-id) "h1")))
                                  (harness-call 'session/nodes sid))))
          (should (string-match-p "waits for the user's review" (plist-get result :output)))
          ;; The report rides the result node, so the transcript can draw it
          ;; after the task left review.
          (should (equal (plist-get (harness-tasks-test-task id) :report)
                         (plist-get (plist-get result :meta) :report))))
        ;; The user can verify it as any review.
        (harness-call 'task/verify id)
        (harness-tasks-test-wait-state id 'done)
        (should (plist-get (harness-tasks-test-task id) :verified))))))

(ert-deftest harness-tasks-hand-in-needs-a-report ()
  "A hand_in without a problem, a summary, without evidence, or with broken items is refused.
The refusal says what to fix, and the task keeps working."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let* ((id (harness-tasks-test-submit "fix the parser"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (with-temp-file (expand-file-name "notes.txt" (plist-get (harness-call 'session/get sid) :cwd))
        (insert "not a picture\n"))
      ;; Each refusal is a tool result that says what to fix, not a Lisp
      ;; error; the broken items are listed, one per line.
      (pcase-dolist (`(,input ,says)
                     '(((:summary "" :evidence ("x")) "\\`hand_in needs summary: ")
                       ;; The problem is required now, and checked next.
                       ((:summary "done" :evidence ("x")) "\\`hand_in needs problem: ")
                       ((:problem " " :summary "done" :evidence ("x")) "\\`hand_in needs problem: ")
                       ((:problem "nested quotes" :summary "done" :evidence nil) "\\`hand_in needs evidence: ")
                       ((:problem "nested quotes" :summary "done" :evidence (1))
                        "\\`Evidence 1 is neither text nor an object\\'")
                       ((:problem "nested quotes" :summary "done" :evidence ((:image "/no/such/file.png")))
                        "\\`Evidence 1: /no/such/file.png not found")
                       ((:problem "nested quotes" :summary "done" :evidence ((:image "notes.txt")))
                        "\\`Evidence 1: notes.txt is not an image")
                       ((:problem "nested quotes" :summary "done" :evidence ((:tool_call "nope")))
                        "\\`Evidence 1: no tool call nope in this session")
                       ((:problem "nested quotes" :summary "done" :evidence ((:code "x" :note "y")))
                        "\\`Evidence 1 gives code and note: give it exactly one of")
                       ((:problem "nested quotes" :summary "done" :evidence ((:image "a.png" :tool_call "c1")))
                        "\\`Evidence 1 gives image and tool_call: ")
                       ((:problem "nested quotes" :summary "done" :evidence ("fine" 1 (:note " ")))
                        "\\`Evidence 2 is neither text nor an object\nEvidence 3 says nothing: ")))
        (let ((result (harness-test-await (harness-call-async 'tools/execute sid (list :id "bad" :name "hand_in" :input input)))))
          (should (plist-get result :is-error))
          (should-not (plist-get result :end-turn))
          (should (string-match-p says (plist-get result :content)))))
      (should-not (plist-get (harness-tasks-test-task id) :report))
      (should (eq 'active (harness-tasks-test-state id))))))

(ert-deftest harness-tasks-hand-in-quotes-a-tool-call ()
  "Evidence may name an earlier tool call: the report copies what it did and showed."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (harness-define-tool "echo_tool" :label "Echo" :description "echoes" :kind 'read
                         :handler (lambda (input _ctx) (harness-tool-ok (format "echo: %s" (plist-get input :text)))))
    (let* ((harness-provider-demo-script-override
            '((:type tool-call :id "c1" :name "echo_tool" :input (:text "hello"))
              (:type tool-call :id "h1" :name "hand_in"
                     :input (:problem "The echo is quiet" :summary "Done" :evidence ((:tool_call "c1" :caption "the command"))))
              (:type done :stop-reason end-turn)))
           (id (harness-tasks-test-submit "run the command")))
      (harness-tasks-test-wait-state id 'done)
      (let* ((report (plist-get (harness-tasks-test-task id) :report))
             (item (car (plist-get report :evidence))))
        (should (equal "tool-call" (plist-get item :kind)))
        (should (equal "c1" (plist-get item :call-id)))
        (should (equal "Echo: hello" (plist-get item :title)))
        (should (equal "echo: hello" (plist-get item :output)))
        (should (equal "the command" (plist-get item :caption)))
        (should (string-match-p "hello" (plist-get item :input)))))))

(ert-deftest harness-tasks-hand-in-copies-the-child-session ()
  "A referenced spawn_agent call carries the sub-agent it started into
the report, so the report links the same session the chat does; a call
that started none carries no key."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id))
           (kid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/append sid
                    (list :kind 'tool-call :tool "spawn_agent" :call-id "sp1"
                          :title "Sub-agent: kid" :input (list :name "kid" :prompt "go")
                          :meta (list :model "demo:scripted" :child-id kid)))
      (harness-call 'session/append sid (list :kind 'tool-result :call-id "sp1" :output "done"))
      (let ((item (harness-tools-handin--call sid "sp1" 1)))
        (should (equal "tool-call" (plist-get item :kind)))
        (should (equal kid (plist-get item :child-id)))
        (should (equal "done" (plist-get item :output))))
      ;; The result's own name counts too, when the call carries none.
      (harness-call 'session/append sid (list :kind 'tool-call :tool "bash" :call-id "b1"
                                              :title "Bash" :input '(:command "true")))
      (harness-call 'session/append sid (list :kind 'tool-result :call-id "b1" :output "ok"
                                              :meta (list :child-id kid)))
      (should (equal kid (plist-get (harness-tools-handin--call sid "b1" 1) :child-id)))
      ;; A call that started no session carries no key.
      (harness-call 'session/append sid (list :kind 'tool-call :tool "bash" :call-id "b2"
                                              :title "Bash" :input '(:command "true")))
      (harness-call 'session/append sid (list :kind 'tool-result :call-id "b2" :output "ok"))
      (should-not (plist-get (harness-tools-handin--call sid "b2" 1) :child-id)))))

(ert-deftest harness-tasks-hand-in-quotes-a-call-by-name-or-handle ()
  "Evidence may name a call by its tool, or by the `#N' handle a miss lists.
The newest call of a tool is the one quoted; `#N' counts every
non-hand_in call, newest first, and a hand_in call appended by a failed
attempt does not shift it."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/append sid (list :kind 'tool-call :tool "bash" :call-id "b1"
                                              :title "Bash: one" :input '(:command "one")))
      (harness-call 'session/append sid (list :kind 'tool-call :tool "bash" :call-id "b2"
                                              :title "Bash: two" :input '(:command "two")))
      (harness-call 'session/append sid (list :kind 'tool-call :tool "read_file" :call-id "r1"
                                              :title "Read file: x" :input '(:path "x")))
      (harness-call 'session/append sid (list :kind 'tool-call :tool "bash" :call-id "b3"
                                              :title "Bash: three" :input '(:command "three")))
      ;; Newest first: b3, r1, b2, b1.
      (should (equal "b3" (plist-get (harness-tools-handin--call sid "bash" 1) :call-id)))
      (should (equal "b3" (plist-get (harness-tools-handin--call sid "last" 1) :call-id)))
      (should (equal "r1" (plist-get (harness-tools-handin--call sid "read_file" 1) :call-id)))
      (should (equal "r1" (plist-get (harness-tools-handin--call sid "#2" 1) :call-id)))
      (should (equal "b2" (plist-get (harness-tools-handin--call sid "bash#2" 1) :call-id)))
      ;; A failed hand_in appends its own call; it is not named by the
      ;; tool-name or handle forms and is not counted, so the handles
      ;; above still mean the same thing.  An exact id names it, as it
      ;; always did: the review fixture hands in quoting its own call.
      (harness-call 'session/append sid (list :kind 'tool-call :tool "hand_in" :call-id "h1"
                                              :title "Hand in the finished work" :input nil))
      (should (equal "b3" (plist-get (harness-tools-handin--call sid "#1" 1) :call-id)))
      (should (equal "r1" (plist-get (harness-tools-handin--call sid "#2" 1) :call-id)))
      (should (equal "h1" (plist-get (harness-tools-handin--call sid "h1" 1) :call-id)))
      (should (string-match-p "\\`Evidence 1: no tool call hand_in"
                              (harness-tools-handin--call sid "hand_in" 1))))))

(ert-deftest harness-tasks-hand-in-quotes-a-call-by-node-id ()
  "A call's node id, and its tool-result node's id, both name the call."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/append sid (list :kind 'tool-call :tool "bash" :call-id "b1"
                                              :id "n-call" :title "Bash: x" :input '(:command "x")))
      (harness-call 'session/append sid (list :kind 'tool-result :call-id "b1" :id "n-result" :output "ok"))
      (should (equal "b1" (plist-get (harness-tools-handin--call sid "n-call" 1) :call-id)))
      (should (equal "b1" (plist-get (harness-tools-handin--call sid "n-result" 1) :call-id)))
      (should (equal "ok" (plist-get (harness-tools-handin--call sid "n-result" 1) :output))))))

(ert-deftest harness-tasks-hand-in-miss-lists-handles ()
  "A wrong reference lists the calls a retry may quote, newest first.
Each entry carries its `#N', node id, call id and a distinguishing
snippet."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)) :id)))
      (harness-call 'session/append sid (list :kind 'tool-call :tool "bash" :call-id "b1"
                                              :title "Bash" :input '(:command "cd /x && scripts/test.sh")))
      (harness-call 'session/append sid (list :kind 'tool-call :tool "bash" :call-id "b2"
                                              :title "Bash" :input '(:command "scripts/lint.sh")))
      (let ((msg (harness-tools-handin--call sid "nope" 3)))
        (should (stringp msg))
        (should (string-match-p "\\`Evidence 3: no tool call nope in this session" msg))
        ;; Newest first: the lint call is #1, the test run #2.
        (should (string-match-p "#1 .+ b2 (bash: scripts/lint.sh)" msg))
        (should (string-match-p "#2 .+ b1 (bash: cd /x && scripts/test.sh)" msg))))))

(ert-deftest harness-tasks-hand-in-offered-to-task-sessions-only ()
  "Only a task's session is offered hand_in; the catalogue keeps every tool."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let* ((plain (plist-get (harness-call 'session/create :cwd default-directory) :id))
           (id (harness-tasks-test-submit "fix the parser"))
           (sid (plist-get (harness-tasks-test-task id) :session))
           (names (lambda (session-id) (mapcar (lambda (s) (plist-get s :name))
                                               (harness-call 'tools/list session-id)))))
      (should-not (member "hand_in" (funcall names plain)))
      (should (member "hand_in" (funcall names sid)))
      (should (member "hand_in" (funcall names nil))))))

(declare-function harness-tasks--no-merge-p "harness-tasks")
(declare-function harness-tasks--wake "harness-tasks")
(declare-function harness-tasks--waking-p "harness-tasks")
(declare-function harness-tasks--wake-worthy-p "harness-tasks")
(declare-function harness-tasks--on-turn-started "harness-tasks")

(ert-deftest harness-tasks-hand-in-cannot-continue-waits-for-the-user ()
  "A task handing in `cannot_continue' waits for the user, not for review.
Its report is kept, nothing merges, and the call itself is a success."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo-script-override
           '((:type tool-call :id "h1" :name "hand_in"
              :input (:problem "The schema is undecided"
                      :summary "# Blocked\n\nNeed a decision" :evidence nil :cannot_continue t)))))
      (let* ((id (harness-tasks-test-submit "decide the schema"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-test-wait
         (lambda () (eq 'needs-input (plist-get (harness-tasks-test-task id) :column)))
         10 "the task to wait for the user")
        (let ((task (harness-tasks-test-task id)))
          ;; It never went to review: it is active, before the user.
          (should (eq 'active (plist-get task :state)))
          (should (eq 'cannot-continue (plist-get task :outcome)))
          (should (eq 'needs-input (plist-get task :column)))
          (should (plist-get task :report))
          (should-not (harness-json-true-p (plist-get (plist-get task :report) :missing)))
          (should (equal "# Blocked\n\nNeed a decision"
                         (plist-get (plist-get task :report) :summary)))
          (should (string-match-p "Blocked" (plist-get task :error)))
          (should-not (plist-get task :finished))
          (should-not (plist-get task :merged))
          (should-not (plist-get task :merge-status)))
        ;; The tool call succeeded: the refusal path ends nothing.
        (let ((result (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                                                   (equal (plist-get n :call-id) "h1")))
                                  (harness-call 'session/nodes sid))))
          (should result)
          (should-not (plist-get result :is-error)))))))

(ert-deftest harness-tasks-hand-in-no-merge-completes-without-merging ()
  "A `no_merge' hand-in still waits for review; verifying completes it unmerged.
The branch never joins the merge queue, even in a git project with a
worktree, so nothing reaches main."
  (harness-tasks-test-with-git
    (harness-test-load-module 'tools-handin)
    (let ((harness-tasks-require-verification t)
          (merges 0)
          (done-how nil))
      (harness-on 'task/done (lambda (_task how) (setq done-how how)))
      ;; The queue's own method: calling it proves a merge was queued.
      (cl-letf (((symbol-function 'harness-method/merge/enqueue)
                 (lambda (&rest _) (cl-incf merges) nil)))
        (setq harness-provider-demo-script-override
              '((:type tool-call :id "h1" :name "hand_in"
                 :input (:problem "The build wants a report"
                         :summary "# Findings" :evidence ("a note") :no_merge t))))
        (let ((id (harness-tasks-test-submit "report on the build")))
          (harness-tasks-test-wait-state id 'review)
          (let ((task (harness-tasks-test-task id)))
            (should (harness-tasks--no-merge-p task))
            (should (plist-get task :no-merge))
            (should-not (plist-get task :merge-status))
            (should-not (plist-get task :merge-queued)))
          (harness-call 'task/verify id)
          (harness-tasks-test-wait-state id 'done)
          (let ((task (harness-tasks-test-task id)))
            (should (eq 'done (plist-get task :state)))
            ;; `:outcome' keeps the turn's own end-turn; the `task/done'
            ;; event carries how it completed, here `verified'.
            (should (plist-get task :verified))
            (should-not (plist-get task :merged))
            (should-not (plist-get task :merge-status))
            (should-not (plist-get task :merge-queued)))
          (should (eq 'verified done-how))
          (should (= 0 merges))
          ;; Nothing reached main: the branch was never merged.
          (should (equal "one\n" (harness-tasks-test--main-text root))))))))

(ert-deftest harness-tasks-hand-in-no-merge-without-review-is-done ()
  "Without review a `no_merge' hand-in completes at once and merges nothing."
  (harness-tasks-test-with-git
    (harness-test-load-module 'tools-handin)
    (let ((harness-tasks-require-verification nil))
      (setq harness-provider-demo-script-override
            '((:type tool-call :id "h1" :name "hand_in"
               :input (:problem "The build wants a report"
                       :summary "# Findings" :evidence ("a note") :no_merge t))))
      (let ((id (harness-tasks-test-submit "report on the build")))
        (harness-tasks-test-wait-state id 'done)
        (let ((task (harness-tasks-test-task id)))
          (should (eq 'done (plist-get task :state)))
          (should (eq 'end-turn (plist-get task :outcome)))
          (should (plist-get task :finished))
          (should-not (plist-get task :merged))
          (should-not (plist-get task :merge-status))
          (should-not (plist-get task :merge-queued)))
        ;; The branch never merged into main.
        (should (equal "one\n" (harness-tasks-test--main-text root)))))))

;; A round whose turn ends without hand_in -- the model replied instead,
;; or could not call the tool (Claude Code offering it none of the
;; harness's tools had it write its calls as text) -- must not leave its
;; review with nothing to read, nor with the report of an earlier round.

(defun harness-tasks-test--report (id)
  "Return the report task ID holds."
  (plist-get (harness-tasks-test-task id) :report))

(defun harness-tasks-test--missing-p (id)
  "Non-nil when task ID's report says its round handed none in."
  (harness-json-true-p (plist-get (harness-tasks-test--report id) :missing)))

(ert-deftest harness-tasks-turn-without-hand-in-reports-it-missing ()
  "A round that ends without hand_in gets a report saying so.
It holds no evidence and, as its summary, the last message the session
wrote, so the review has that to read and knows nothing was handed in.
A task that completes without review gets one the same way."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo-script-override
           '((:type text :delta "I fixed the parser; see the diff.\n")
             (:type done :stop-reason end-turn))))
      (let ((id (harness-tasks-test-submit "fix the parser")))
        (harness-tasks-test-wait-state id 'review)
        (let ((report (harness-tasks-test--report id)))
          (should (harness-tasks-test--missing-p id))
          (should (equal "I fixed the parser; see the diff." (plist-get report :summary)))
          (should-not (plist-get report :evidence))
          (should (numberp (plist-get report :at))))
        ;; Verifying it is still the user's call.
        (harness-call 'task/verify id)
        (harness-tasks-test-wait-state id 'done)))
    ;; Review off: the task completes, with the report that says so.
    (let ((id (harness-tasks-test-submit "tidy the readme")))
      (harness-tasks-test-wait-state id 'done)
      (should (harness-tasks-test--missing-p id))
      (should (equal "Working on it." (plist-get (harness-tasks-test--report id) :summary))))))

(ert-deftest harness-tasks-round-without-hand-in-replaces-a-stale-report ()
  "A round that ends without hand_in never shows an earlier round's report.
That report speaks for work the user sent back.  The round's own last
message replaces it; a round that wrote none has no summary, never one
from before.  A round that hands in again gets its report as handed in."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo-script-override
           '((:type text :delta "First try.\n")
             (:type tool-call :id "h1" :name "hand_in"
              :input (:problem "Nested quotes break the parser" :summary "# Done" :evidence ("looks good"))))))
      (let ((id (harness-tasks-test-submit "fix the parser")))
        (harness-tasks-test-wait-state id 'review)
        (should (equal "# Done" (plist-get (harness-tasks-test--report id) :summary)))
        (should-not (harness-tasks-test--missing-p id))
        ;; Sent back, it replies without handing in.
        (setq harness-provider-demo-script-override
              '((:type text :delta "Fixed the nested case too.\n") (:type done :stop-reason end-turn)))
        (harness-call 'task/reject id "nested quotes still break")
        (harness-tasks-test-wait-state id 'review)
        (should (harness-tasks-test--missing-p id))
        (should (equal "Fixed the nested case too." (plist-get (harness-tasks-test--report id) :summary)))
        ;; Sent back again, it writes nothing at all.
        (setq harness-provider-demo-script-override '((:type done :stop-reason end-turn)))
        (harness-call 'task/reject id "and the empty string")
        (harness-tasks-test-wait-state id 'review)
        (should (harness-tasks-test--missing-p id))
        (should-not (plist-get (harness-tasks-test--report id) :summary))
        ;; Handing in again, the report is the one handed in.
        (setq harness-provider-demo-script-override
              '((:type tool-call :id "h2" :name "hand_in"
              :input (:problem "Nested quotes break the parser" :summary "# Fixed" :evidence ("all cases")))))
        (harness-call 'task/reject id "one more go")
        (harness-tasks-test-wait-state id 'review)
        (should-not (harness-tasks-test--missing-p id))
        (should (equal "# Fixed" (plist-get (harness-tasks-test--report id) :summary)))))))

(ert-deftest harness-tasks-reopened-task-needs-a-report-of-its-own ()
  "New work on a done task is a round of its own: its report is not the old one.
A follow-up to a verified task reopens it; when that round ends without
hand_in, the report says so instead of standing on the first round's."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo-script-override
           '((:type tool-call :id "h1" :name "hand_in"
              :input (:problem "Nested quotes break the parser" :summary "# Done" :evidence ("looks good"))))))
      (let ((id (harness-tasks-test-submit "fix the parser")))
        (harness-tasks-test-wait-state id 'review)
        (harness-call 'task/verify id)
        (harness-tasks-test-wait-state id 'done)
        (should (equal "# Done" (plist-get (harness-tasks-test--report id) :summary)))
        (setq harness-provider-demo-script-override
              '((:type text :delta "Also handled tabs.\n") (:type done :stop-reason end-turn)))
        (harness-call 'task/prompt id "handle tabs too")
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :reopened))
                           10 "the follow-up to reopen the task")
        (harness-tasks-test-wait-state id 'review)
        (should (harness-tasks-test--missing-p id))
        (should (equal "Also handled tabs." (plist-get (harness-tasks-test--report id) :summary)))))))

(ert-deftest harness-tasks-recap-survives-a-restart ()
  "A recap, and the counters it was made at, are kept in the store."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (let ((id (harness-tasks-test-submit "recap me later")))
        (harness-call 'task/set-recap id :recap "Wrote the parser and its tests"
                      :recap-at 1700000000.0 :recap-turns 2 :recap-tools 3)
        (harness-tasks-test--restart)
        (let ((task (harness-tasks-test-task id)))
          (should (equal "Wrote the parser and its tests" (plist-get task :recap)))
          (should (= 1700000000.0 (plist-get task :recap-at)))
          (should (= 2 (plist-get task :recap-turns)))
          (should (= 3 (plist-get task :recap-tools))))))))

;;;; Queue suspension and return to pending

(defun harness-tasks-test--queue-suspended-p (&optional cwd)
  "Whether the queue of CWD's project is suspended, as `task/settings' says."
  (harness-json-true-p (plist-get (harness-call 'task/settings (or cwd default-directory)) :queue-suspended)))

(defun harness-tasks-test--idle (id)
  "Non-nil once task ID's session has no turn running."
  (let ((sid (plist-get (harness-tasks-test-task id) :session)))
    (and sid (not (harness-call 'agent/running sid)))))

(ert-deftest harness-tasks-suspend-queue-holds-back-starts ()
  "A suspended queue starts nothing on its own; an explicit start still works.
Resuming starts the waiting tasks again, up to the limit."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let ((harness-tasks-max-running 1) a b c d)
      (setq a (harness-tasks-test-submit "first")
            b (harness-tasks-test-submit "second"))
      (should (eq 'active (harness-tasks-test-state a)))
      (should (eq 'pending (harness-tasks-test-state b)))
      (harness-call 'task/suspend-queue default-directory)
      (should (harness-tasks-test--queue-suspended-p))
      ;; The slot the first task frees starts nothing: the queue is suspended.
      (harness-tasks-test-wait-state a 'done)
      (should (eq 'pending (harness-tasks-test-state b)))
      ;; Its session waits with it -- every task has one from submission --
      ;; and no work was begun.
      (should-not (plist-get (harness-tasks-test-task b) :started))
      ;; An explicit start goes ahead all the same.
      (harness-call 'task/start b)
      (should (eq 'active (harness-tasks-test-state b)))
      (harness-tasks-test-wait-state b 'done)
      ;; Two more wait; resuming starts one, the limit's worth.
      (setq c (harness-tasks-test-submit "third")
            d (harness-tasks-test-submit "fourth"))
      (should (eq 'pending (harness-tasks-test-state c)))
      (harness-call 'task/resume-queue default-directory)
      (should-not (harness-tasks-test--queue-suspended-p))
      (should (eq 'active (harness-tasks-test-state c)))
      (should (eq 'pending (harness-tasks-test-state d)))
      (dolist (id (list c d)) (harness-tasks-test-wait-state id 'done)))))

(ert-deftest harness-tasks-suspended-queue-is-kept-per-project ()
  "Which queues are suspended is kept, per project, across a restart."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let ((other (harness-test-temp-dir)) id)
      (let ((harness-tasks-max-running 0))
        (harness-call 'task/suspend-queue default-directory)
        (setq id (harness-tasks-test-submit "waits for the queue"))
        (should (eq 'pending (harness-tasks-test-state id))))
      (harness-tasks-test--restart)
      ;; The suspension came back with the records, and it is this
      ;; project's: the other project's queue runs.
      (should (harness-tasks-test--queue-suspended-p))
      (should-not (harness-tasks-test--queue-suspended-p other))
      (should (eq 'pending (harness-tasks-test-state id)))
      ;; Resuming starts the task it held back.
      (harness-call 'task/resume-queue default-directory)
      (should-not (harness-tasks-test--queue-suspended-p))
      (harness-tasks-test-wait-state id 'done))))

(ert-deftest harness-tasks-returned-tasks-lead-their-priority-queue ()
  "A returned task starts ahead of the never-started ones of its priority.
Higher priority still goes first, and among returned tasks the first
returned starts first."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let ((harness-agent--cancel-grace 0.05)
          (harness-tasks-max-running 0)
          (harness-provider-demo-script-override '((:type wait :seconds 30)))
          first second returned1 returned2 high)
      (setq first (harness-tasks-test-submit "never started, first")
            second (harness-tasks-test-submit "never started, second")
            returned1 (harness-tasks-test-submit "returned, first")
            returned2 (harness-tasks-test-submit "returned, second")
            high (harness-tasks-test-submit-at "never started, high" "high"))
      ;; Two start by hand (no slot is free for the queue) and are
      ;; returned, in order.
      (dolist (id (list returned1 returned2)) (harness-call 'task/start id))
      (should (eq 'active (harness-tasks-test-state returned1)))
      (harness-call 'task/return-to-pending returned1)
      (harness-call 'task/return-to-pending returned2)
      (dolist (id (list returned1 returned2))
        (should (eq 'pending (harness-tasks-test-state id)))
        (harness-test-wait (lambda () (harness-tasks-test--idle id)) 5 "its turn to stop"))
      ;; A quick script for the runs that follow.
      (setq harness-provider-demo-script-override
            '((:type text :delta "Done.\n") (:type done :stop-reason end-turn)))
      (let ((harness-tasks-max-running 1))
        (harness-tasks--schedule)
        ;; The high one goes first; then the returned ones, in the order
        ;; they were returned; then the never-started ones, oldest first.
        (should (eq 'active (harness-tasks-test-state high)))
        (should (eq 'pending (harness-tasks-test-state returned1)))
        (dolist (id (list first second returned1 returned2 high)) (harness-tasks-test-wait-state id 'done))
        (should (equal (list high returned1 returned2 first second)
                       (harness-tasks-test-start-order (list first second returned1 returned2 high))))))))

(ert-deftest harness-tasks-returned-task-keeps-a-message-until-it-starts ()
  "A message to a returned task is kept while its queue is suspended.
The task stays pending and its prompt is not rewritten; the message
goes to its session with the start, when the queue resumes."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let ((harness-agent--cancel-grace 0.05)
          (harness-tasks-max-running 1)
          (harness-provider-demo-script-override '((:type wait :seconds 30))))
      (let ((id (harness-tasks-test-submit "first")))
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :session)) 5 "a session")
        (let ((sid (plist-get (harness-tasks-test-task id) :session)))
          (harness-call 'task/suspend-queue default-directory)
          (harness-call 'task/return-to-pending id)
          (harness-test-wait (lambda () (harness-tasks-test--idle id)) 5 "its turn to stop")
          (harness-call 'task/prompt id "also update the docs")
          (let ((task (harness-tasks-test-task id)))
            (should (eq 'pending (plist-get task :state)))
            (should (equal "first" (plist-get task :prompt)))
            (should (equal "also update the docs" (plist-get (car (plist-get task :queued)) :text)))
            (should (equal sid (plist-get task :session))))
          ;; Resuming starts it and delivers the message with the start.
          (setq harness-provider-demo-script-override
                '((:type text :delta "Carried on.\n") (:type done :stop-reason end-turn)))
          (harness-call 'task/resume-queue default-directory)
          (harness-test-wait
           (lambda ()
             (and (harness-tasks-test--node sid (lambda (n) (equal "also update the docs" (plist-get n :content))))
                  (harness-tasks-test--node sid (lambda (n) (equal harness-tasks--paused-message (plist-get n :content))))))
           10 "the kept message and the carry-on")
          (should-not (plist-get (harness-tasks-test-task id) :queued))
          (harness-tasks-test-wait-state id 'done))))))

(ert-deftest harness-tasks-reject-waits-while-the-queue-is-suspended ()
  "Sending a task back while the queue is suspended puts it back in pending.
Its feedback is kept, and goes to its session when the queue starts it."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo-script-override
           '((:type text :delta "Done.\n") (:type done :stop-reason end-turn))))
      (let ((id (harness-tasks-test-submit "fix the parser")))
        (harness-tasks-test-wait-state id 'review)
        (let ((sid (plist-get (harness-tasks-test-task id) :session)))
          (harness-call 'task/suspend-queue default-directory)
          (harness-call 'task/reject id "handle tabs too")
          (let ((task (harness-tasks-test-task id)))
            (should (eq 'pending (plist-get task :state)))
            (should (plist-get task :returned))
            (should (equal sid (plist-get task :session)))
            (should (equal "handle tabs too" (plist-get (car (last (plist-get task :feedback))) :text)))
            (should (equal (harness-tasks--reject-text "handle tabs too")
                           (plist-get (car (plist-get task :queued)) :text))))
          ;; It waits: the queue is suspended.
          (should (eq 'pending (harness-tasks-test-state id)))
          (harness-call 'task/resume-queue default-directory)
          (harness-test-wait
           (lambda () (harness-tasks-test--node sid (lambda (n) (equal (harness-tasks--reject-text "handle tabs too")
                                                                       (plist-get n :content)))))
           10 "the kept feedback")
          (harness-tasks-test-wait-state id 'review))))))

(ert-deftest harness-tasks-returned-task-carries-on-in-its-session ()
  "A returned task keeps its session, branch and worktree.
Starting it again has that session carry on where it stopped, told so
by the harness; no new session or worktree is made."
  (harness-tasks-test-with-git
    (harness-tasks-test--settle)
    (let ((harness-agent--cancel-grace 0.05)
          (harness-tasks-max-running 1)
          (harness-provider-demo-script-override '((:type wait :seconds 30))))
      (let ((id (harness-tasks-test-submit "Change the shared file")))
        ;; Every task has its session from submission; wait for the work to
        ;; have begun in it, in a worktree.
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :worktree)) 5 "a worktree")
        (let* ((task (harness-tasks-test-task id))
               (sid (plist-get task :session))
               (worktree (plist-get task :worktree))
               (branch (plist-get task :branch))
               (sessions (length (harness-call 'session/list))))
          (should (file-directory-p worktree))
          (harness-call 'task/return-to-pending id)
          (let ((stopped (harness-tasks-test-task id)))
            (should (eq 'pending (plist-get stopped :state)))
            (should (plist-get stopped :returned))
            (should (equal sid (plist-get stopped :session)))
            (should (equal branch (plist-get stopped :branch)))
            (should (equal worktree (plist-get stopped :worktree))))
          (harness-test-wait (lambda () (harness-tasks-test--idle id)) 5 "its turn to stop")
          ;; It waits: the return itself started nothing.
          (should (eq 'pending (harness-tasks-test-state id)))
          ;; Starting it again carries on in the same session and worktree.
          (setq harness-provider-demo-script-override
                '((:type tool-call :id "c1" :name "change_shared" :input (:text "two"))
                  (:type text :delta "Carried on.\n")
                  (:type done :stop-reason end-turn)))
          (harness-call 'task/start id)
          (should (eq 'active (harness-tasks-test-state id)))
          (should (equal sid (plist-get (harness-tasks-test-task id) :session)))
          (should (= sessions (length (harness-call 'session/list))))
          (should (equal worktree (plist-get (harness-call 'session/get sid) :cwd)))
          (harness-test-wait
           (lambda () (harness-tasks-test--node sid (lambda (n) (equal harness-tasks--paused-message (plist-get n :content)))))
           10 "the carry-on message")
          (harness-tasks-test-wait-state id 'done)
          (should (equal "two\n" (harness-tasks-test--main-text root))))))))

;;;; Pre-emption: work sent back from review keeps to the limit

(declare-function harness-tasks--outranks-p "harness-tasks")
(declare-function harness-tasks--victim "harness-tasks")
(declare-function harness-tasks--worktree-promise "harness-tasks")
(declare-function harness-tasks--by-session "harness-tasks")

(defconst harness-tasks-test--quick
  '((:type text :delta "Done.\n") (:type done :stop-reason end-turn))
  "A demo script whose turn ends at once.")

(defvar harness-tasks-test--slow nil
  "The prompts of the tasks whose turns run on until they are stopped.
Read by `harness-tasks-test--slow-script'.")

(defun harness-tasks-test--slow-script (request)
  "Return the demo script for REQUEST: slow for a task of `harness-tasks-test--slow'.
A turn of a task whose prompt is in that list runs on until it is
stopped; any other ends at once.  The task is told by its prompt rather
than its session: a task that starts at once makes its first request
before `task/submit' returns, so before the test knows its session."
  (let ((task (harness-tasks--by-session (plist-get (plist-get request :session) :id))))
    (if (and task (member (plist-get task :prompt) harness-tasks-test--slow))
        '((:type wait :seconds 30))
      harness-tasks-test--quick)))

(defun harness-tasks-test--hint-p (sid prefix)
  "Non-nil when session SID has a hint that starts with PREFIX."
  (cl-some (lambda (hint) (and (stringp hint) (string-prefix-p prefix hint)))
           (harness-tasks-test-hints sid)))

(defun harness-tasks-test--said (sid text)
  "The user messages of session SID that say TEXT."
  (cl-remove-if-not (lambda (n) (equal text (plist-get n :content))) (harness-tasks-test-user-nodes sid)))

(defun harness-tasks-test--running-p (sid)
  "Non-nil once session SID runs a turn that began."
  (eq 'running (plist-get (harness-call 'session/get sid) :status)))

(ert-deftest harness-tasks-preempts-the-lowest-ranked-task-it-outranks ()
  "Work sent back from review outranks a lower priority, or its own unless sent back.
Of the tasks at work it outranks, the one that gives its slot up has
the lowest priority, then is work that only started rather than
feedback, then began last.  A task whose turn is over but which waits
on work its session left running holds its slot through that work,
and gives it up like the others: the work stops with it.  Another
project's task, and any task while the limit is 0, give none up."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 1)
          (other (file-name-as-directory (harness-test-temp-dir))))
      (cl-flet ((at-work (priority &rest plist)
                  ;; Starting, it holds a slot; without a session, its
                  ;; record says its priority.
                  (let ((task (append plist
                                      (list :id (concat "t-" (harness-short-id 8))
                                            :project default-directory :cwd default-directory
                                            :prompt "at it" :state 'active :priority priority
                                            :created (float-time)))))
                    (puthash (plist-get task :id) task harness-tasks--table)
                    (puthash (plist-get task :id) t harness-tasks--starting)
                    task))
                (victim (task) (plist-get (harness-tasks--victim task) :id)))
        (let* ((reviewed (list :id "t-reviewed" :project default-directory :cwd default-directory
                               :state 'review :priority "medium"))
               (high (at-work "high" :started 10.0))
               (fed-back (at-work "medium" :started 20.0 :sent-back 600.0))
               (older (at-work "medium" :started 100.0))
               (newer (at-work "medium" :started 200.0))
               (low (at-work "low" :started 300.0))
               ;; Its turn over, it waits on its workers: it holds its
               ;; slot through them, its session idle, not by starting.
               (waiting (let* ((sid (plist-get (harness-call 'session/create :cwd default-directory
                                                             :model "demo:scripted")
                                               :id))
                               (task (list :id (concat "t-" (harness-short-id 8)) :session sid
                                           :project default-directory :cwd default-directory
                                           :prompt "plan it" :state 'active :started 400.0
                                           :waiting "2 workers running" :created (float-time))))
                          (harness-call 'priority/set sid "low")
                          (puthash (plist-get task :id) task harness-tasks--table)
                          task))
               ;; Were it a candidate, this would go first: it began last.
               (_elsewhere (at-work "low" :started 500.0 :project other)))
          (should (harness-tasks--holds-slot-p waiting))
          (should-not (gethash (plist-get waiting :id) harness-tasks--starting))
          (should-not (harness-call 'agent/running (plist-get waiting :session)))
          (should (harness-tasks--outranks-p reviewed waiting))
          (should (harness-tasks--outranks-p reviewed low))
          (should (harness-tasks--outranks-p reviewed older))
          (should-not (harness-tasks--outranks-p reviewed fed-back))
          (should-not (harness-tasks--outranks-p reviewed high))
          ;; The lowest priority first, the work that began last first:
          ;; the task waiting on its workers ...
          (should (equal (plist-get waiting :id) (victim reviewed)))
          ;; ... then the other of its priority ...
          (remhash (plist-get waiting :id) harness-tasks--table)
          (should (equal (plist-get low :id) (victim reviewed)))
          ;; ... then, of its own priority, the work that began last.
          (remhash (plist-get low :id) harness-tasks--table)
          (should (equal (plist-get newer :id) (victim reviewed)))
          (remhash (plist-get newer :id) harness-tasks--table)
          (should (equal (plist-get older :id) (victim reviewed)))
          ;; Feedback of its priority, and a higher priority, keep their slots.
          (remhash (plist-get older :id) harness-tasks--table)
          (should-not (victim reviewed))
          ;; Feedback of a higher priority takes the lower priority's slot
          ;; first, feedback or not; its own priority's work that only
          ;; started is next.
          (let ((urgent (plist-put (copy-sequence reviewed) :priority "high")))
            (should (equal (plist-get fed-back :id) (victim urgent)))
            (remhash (plist-get fed-back :id) harness-tasks--table)
            (should (equal (plist-get high :id) (victim urgent)))
            (let ((harness-tasks-max-running 0))
              (should-not (victim urgent)))))))))

(ert-deftest harness-tasks-sent-back-task-preempts-work-that-just-started ()
  "Work sent back from review takes the slot of work of its priority that just started.
Its slot went to a new task while it waited for review: sending it back
pre-empts that task.  The task pre-empted goes back to the queue, its
turn stopped, and its session says why; once a slot frees it carries on
in that session, told so by the harness."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let* ((harness-tasks-test--slow (list "write the docs"))
           (harness-agent--cancel-grace 0.05)
           (harness-tasks-max-running 1)
           (harness-tasks-require-verification t)
           (harness-provider-demo-script-override #'harness-tasks-test--slow-script)
           (reviewed (harness-tasks-test-submit "fix the parser"))
           (rsid (harness-tasks-test-session-id reviewed)))
      (harness-tasks-test-wait-state reviewed 'review)
      (let* ((fresh (harness-tasks-test-submit "write the docs"))
             (fsid (harness-tasks-test-session-id fresh)))
        (harness-test-wait (lambda () (harness-tasks-test--running-p fsid)) 5 "the new task at work")
        (harness-call 'task/reject reviewed "handle tabs too")
        ;; The task sent back has the slot; the new task is back in line.
        (let ((back (harness-tasks-test-task reviewed))
              (preempted (harness-tasks-test-task fresh)))
          (should (eq 'active (plist-get back :state)))
          (should (eq 'active (plist-get back :column)))
          (should (plist-get back :sent-back))
          (should (eq 'pending (plist-get preempted :state)))
          (should (plist-get preempted :returned))
          (should (eq 'preempted (plist-get preempted :return-reason)))
          (should (equal reviewed (plist-get preempted :preempted-by)))
          (should (= 0 (harness-tasks--free-slots (harness-tasks--slot-project back)))))
        ;; Its next turn ends at once.
        (setq harness-tasks-test--slow nil)
        ;; Its turn stops, and its session says why, once it has.
        (harness-test-wait (lambda () (harness-tasks-test--hint-p fsid "Task pre-empted: task ")) 5
                           "the pre-emption said")
        (should-not (harness-call 'agent/running fsid))
        ;; The task sent back works on the feedback, and is back in review.
        (harness-tasks-test-wait-state reviewed 'review)
        (should (harness-tasks-test--said rsid (harness-tasks--reject-text "handle tabs too")))
        (should-not (plist-get (harness-tasks-test-task reviewed) :sent-back))
        ;; The slot it frees goes to the task it pre-empted, which carries
        ;; on in its own session, told why by the harness.
        (harness-tasks-test-wait-state fresh 'review)
        (let ((opening (car (harness-tasks-test--said fsid harness-tasks--preempted-message))))
          (should opening)
          (should (eq 'system (harness-sender-kind (harness-node-sender opening)))))
        (let ((carried (harness-tasks-test-task fresh)))
          (should (equal fsid (plist-get carried :session)))
          (should-not (plist-get carried :return-reason))
          (should-not (plist-get carried :preempted-by)))))))

(ert-deftest harness-tasks-sent-back-task-waits-behind-higher-priority-work ()
  "Work sent back from review waits when every task at work outranks it.
A task of a higher priority keeps its slot: the task sent back goes to
the front of the queue with its feedback kept, and once a slot frees
its session gets the feedback, after the harness says why it waited."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let* ((harness-tasks-test--slow (list "write the docs"))
           (harness-agent--cancel-grace 0.05)
           (harness-tasks-max-running 1)
           (harness-tasks-require-verification t)
           (harness-provider-demo-script-override #'harness-tasks-test--slow-script)
           (reviewed (harness-tasks-test-submit-at "fix the parser" "low"))
           (rsid (harness-tasks-test-session-id reviewed)))
      (harness-tasks-test-wait-state reviewed 'review)
      (let* ((busy (harness-tasks-test-submit "write the docs"))
             (bsid (harness-tasks-test-session-id busy)))
        (harness-test-wait (lambda () (harness-tasks-test--running-p bsid)) 5 "the other task at work")
        ;; What `task/reject' returns says so, for the board to tell the user.
        (should (eq 'pending (plist-get (harness-call 'task/reject reviewed "handle tabs too") :state)))
        (let ((waiting (harness-tasks-test-task reviewed)))
          (should (eq 'pending (plist-get waiting :state)))
          (should (eq 'pending (plist-get waiting :column)))
          (should (eq 'sent-back (plist-get waiting :return-reason)))
          (should (plist-get waiting :sent-back))
          (should (equal "handle tabs too" (plist-get (car (last (plist-get waiting :feedback))) :text)))
          (should (equal (harness-tasks--reject-text "handle tabs too")
                         (plist-get (car (plist-get waiting :queued)) :text))))
        ;; The task at work goes on.
        (should (eq 'active (harness-tasks-test-state busy)))
        (should (harness-tasks-test--running-p bsid))
        (should-not (harness-tasks-test--said rsid (harness-tasks--reject-text "handle tabs too")))
        ;; Its turn stopped, it frees the slot for the task sent back.
        (harness-call 'task/cancel busy)
        (harness-tasks-test-wait-state reviewed 'review)
        (should (harness-tasks-test--said rsid (harness-tasks--reject-text "handle tabs too")))
        (let ((opening (car (harness-tasks-test--said rsid harness-tasks--sent-back-message))))
          (should opening)
          (should (eq 'system (harness-sender-kind (harness-node-sender opening)))))
        (should-not (plist-get (harness-tasks-test-task reviewed) :queued))))))

(ert-deftest harness-tasks-sent-back-task-waits-behind-feedback-of-its-priority ()
  "Feedback does not pre-empt other feedback of its priority, wherever it was written.
Two tasks of one priority wait for review with one slot: the first sent
back works on its feedback.  The user's message to the second's session
sends it back too, but it waits in the queue: the message stays in the
transcript, its turn refused, and a later message is kept for the
start.  When the slot frees, the harness starts it, saying why it
waited, and the feedback reaches the agent once."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let* ((harness-tasks-test--slow nil)
           (harness-agent--cancel-grace 0.05)
           (harness-tasks-max-running 1)
           (harness-tasks-require-verification t)
           (harness-provider-demo-script-override #'harness-tasks-test--slow-script)
           (first (harness-tasks-test-submit "fix the parser"))
           (second (harness-tasks-test-submit "fix the lexer"))
           (fsid (harness-tasks-test-session-id first))
           (ssid (harness-tasks-test-session-id second))
           (feedback (harness-tasks--reject-text "Nested quotes still break.")))
      (harness-tasks-test-wait-state first 'review)
      (harness-tasks-test-wait-state second 'review)
      (push "fix the parser" harness-tasks-test--slow)
      (harness-call 'task/reject first "handle tabs too")
      (harness-test-wait (lambda () (harness-tasks-test--running-p fsid)) 5 "the first at work on its feedback")
      ;; Typed in the second's chat: sent back, but it waits.
      (harness-call 'agent/prompt ssid "  Nested quotes still break.  ")
      (let ((waiting (harness-tasks-test-task second)))
        (should (eq 'pending (plist-get waiting :state)))
        (should (eq 'sent-back (plist-get waiting :return-reason)))
        (should (equal "Nested quotes still break." (plist-get (car (last (plist-get waiting :feedback))) :text))))
      (harness-test-wait (lambda () (harness-tasks-test--hint-p ssid "Turn not started: its task ")) 5
                         "the turn refused")
      (should (harness-tasks-test--said ssid feedback))
      (should-not (harness-call 'agent/running ssid))
      ;; The refused turn says nothing about the task, which waits on.
      (harness-tasks-test--settle)
      (let ((waiting (harness-tasks-test-task second)))
        (should (eq 'pending (plist-get waiting :state)))
        (should-not (plist-get waiting :outcome)))
      (should (eq 'active (harness-tasks-test-state first)))
      ;; More from the board is kept for its start.
      (harness-call 'task/prompt second "And the docs.")
      (should (equal "And the docs." (plist-get (car (plist-get (harness-tasks-test-task second) :queued)) :text)))
      (should (eq 'pending (harness-tasks-test-state second)))
      ;; The first stops: the second gets the slot and its feedback.
      (harness-call 'task/cancel first)
      (harness-tasks-test-wait-state second 'review)
      (should (harness-tasks-test--said ssid harness-tasks--sent-back-message))
      (should (harness-tasks-test--said ssid "And the docs."))
      (should (= 1 (length (harness-tasks-test--said ssid feedback)))))))

(ert-deftest harness-tasks-sent-back-task-preempts-once-it-outranks ()
  "Feedback waiting for a slot takes one as soon as it outranks a task at work.
Raising its priority above the task at work pre-empts that task."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let* ((harness-tasks-test--slow (list "write the docs"))
           (harness-agent--cancel-grace 0.05)
           (harness-tasks-max-running 1)
           (harness-tasks-require-verification t)
           (harness-provider-demo-script-override #'harness-tasks-test--slow-script)
           (reviewed (harness-tasks-test-submit-at "fix the parser" "low"))
           (rsid (harness-tasks-test-session-id reviewed)))
      (harness-tasks-test-wait-state reviewed 'review)
      (let* ((busy (harness-tasks-test-submit "write the docs"))
             (bsid (harness-tasks-test-session-id busy)))
        (harness-test-wait (lambda () (harness-tasks-test--running-p bsid)) 5 "the other task at work")
        (harness-call 'task/reject reviewed "handle tabs too")
        (should (eq 'pending (harness-tasks-test-state reviewed)))
        (harness-tasks-test--settle)
        (should (eq 'pending (harness-tasks-test-state reviewed)))
        ;; Now above the task at work, it takes that task's slot.
        (harness-call 'priority/set rsid "high")
        (harness-test-wait (lambda () (eq 'pending (harness-tasks-test-state busy))) 5 "the task at work pre-empted")
        (should (equal reviewed (plist-get (harness-tasks-test-task busy) :preempted-by)))
        (should (memq (harness-tasks-test-state reviewed) '(active review)))
        (setq harness-tasks-test--slow nil)
        (harness-tasks-test-wait-state reviewed 'review)
        (should (harness-tasks-test--said rsid harness-tasks--sent-back-message))
        (should (harness-tasks-test--said rsid (harness-tasks--reject-text "handle tabs too")))
        (harness-tasks-test-wait-state busy 'review)
        (should (harness-tasks-test--said bsid harness-tasks--preempted-message))))))

(ert-deftest harness-tasks-waiting-task-takes-no-turn-of-its-own ()
  "The session of a task waiting in the queue takes no turn something else starts.
A message from another session's agent to a task returned to pending
stays in the transcript, its turn refused, and the task waits on; the
user's own message starts it, as `task/start' would."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let ((harness-agent--cancel-grace 0.05)
          (harness-tasks-max-running 0)
          (harness-provider-demo-script-override '((:type wait :seconds 30))))
      (let* ((id (harness-tasks-test-submit "write the docs"))
             (sid (harness-tasks-test-session-id id))
             (other (harness-call 'session/create :cwd default-directory :model "demo:scripted")))
        (harness-call 'task/start id)
        (harness-test-wait (lambda () (harness-tasks-test--running-p sid)) 5 "the task at work")
        (harness-call 'task/return-to-pending id)
        (harness-test-wait (lambda () (harness-tasks-test--idle id)) 5 "its turn to stop")
        (harness-call 'agent/prompt sid "Here is what I found." (list :from (harness-sender-session other)))
        (harness-test-wait (lambda () (harness-tasks-test--hint-p sid "Turn not started: its task ")) 5
                           "the turn refused")
        (should (harness-tasks-test--said sid "Here is what I found."))
        (harness-tasks-test--settle)
        (should (eq 'pending (harness-tasks-test-state id)))
        (should-not (plist-get (harness-tasks-test-task id) :outcome))
        ;; The user's own message starts it.
        (harness-call 'agent/prompt sid "Go on.")
        (harness-test-wait (lambda () (eq 'active (harness-tasks-test-state id))) 5 "the task started")
        (harness-test-wait (lambda () (harness-tasks-test--running-p sid)) 5 "its turn")
        (should-not (plist-get (harness-tasks-test-task id) :return-reason))
        (harness-call 'task/cancel id)))))

(ert-deftest harness-tasks-worktree-made-once-for-starts-that-wait ()
  "Starts of a task that wait for its worktree share the one being made.
A task pre-empted while its worktree was being made, then started
again, must not ask git for a second worktree on the same branch."
  (harness-tasks-test-with
    (let* ((made 0)
           (promise (harness-make-promise))
           (task (list :id "t-one")))
      (cl-letf (((symbol-function 'harness-tasks--make-worktree)
                 (lambda (_task) (cl-incf made) promise)))
        (should (eq (harness-tasks--worktree-promise task) (harness-tasks--worktree-promise task)))
        (should (= 1 made))
        (harness-resolve promise (list :path default-directory :branch "task/one"))
        (harness-tasks-test--settle)
        ;; Made, it is no longer shared: a later start asks for its own.
        (harness-tasks--worktree-promise task)
        (should (= 2 made))))))

(ert-deftest harness-tasks-preempted-while-starting-launches-nothing ()
  "A task pre-empted while its worktree is being made launches nothing.
Its worktree is kept for its next start, which gives its session the
task afresh: its work never began."
  (harness-tasks-test-with-git
    (harness-tasks-test--settle)
    (let ((harness-agent--cancel-grace 0.05)
          (harness-tasks-max-running 1)
          (harness-tasks-require-verification t)
          (harness-provider-demo-script-override harness-tasks-test--quick))
      (let ((reviewed (harness-tasks-test-submit "fix the parser")))
        (harness-tasks-test-wait-state reviewed 'review)
        ;; Its worktree is still being made when the reviewed task is sent back.
        (let* ((fresh (harness-tasks-test-submit "write the docs"))
               (fsid (harness-tasks-test-session-id fresh)))
          (should-not (plist-get (harness-tasks-test-task fresh) :worktree))
          (harness-call 'task/reject reviewed "handle tabs too")
          (should (eq 'pending (harness-tasks-test-state fresh)))
          (should (eq 'preempted (plist-get (harness-tasks-test-task fresh) :return-reason)))
          (harness-tasks-test-wait-state reviewed 'review)
          ;; Then it starts again, in the worktree made for it, with the task.
          (harness-tasks-test-wait-state fresh 'review)
          (let ((task (harness-tasks-test-task fresh)))
            (should (file-directory-p (plist-get task :worktree)))
            (should-not (plist-get task :error))
            (should (equal (file-name-as-directory (plist-get task :worktree))
                           (file-name-as-directory (plist-get (harness-call 'session/get fsid) :cwd)))))
          (should (equal '("write the docs") (harness-tasks-test-user-texts fsid))))))))

;;;; Waiting for a slot: since when, for how long, and what a slot page shows

(defvar harness-tasks-slot-wait-days)
(defvar harness-tasks--slot-waits-max)
(declare-function harness-tasks--queued-since "harness-tasks")
(declare-function harness-tasks--project "harness-tasks")
(declare-function harness-tasks--load "harness-tasks")

(ert-deftest harness-tasks-queued-since-falls-back-on-older-records ()
  "A record from before `:queued-at' says since when it waits by what it has."
  (harness-tasks-test-with
    (should (= 5 (harness-tasks--queued-since (list :queued-at 5 :returned 7 :created 9))))
    (should (= 7 (harness-tasks--queued-since (list :returned 7 :created 9))))
    (should (= 9 (harness-tasks--queued-since (list :created 9))))))

(ert-deftest harness-tasks-queued-at-says-since-when-a-task-waits ()
  "A task is stamped with when it joined the queue, whichever way it did.
At submission that is when it was made.  A task written up for the
backlog waits for the user, so it has none until `task/queue' puts it
in the queue; a task returned to pending waits from the return, however
long ago it was made."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let ((harness-agent--cancel-grace 0.05)
          (harness-tasks-max-running 0))
      ;; Submitted: it waits from the moment it exists.
      (let* ((id (harness-tasks-test-submit "queued as it is submitted"))
             (task (harness-tasks-test-task id)))
        (should (eq 'pending (plist-get task :state)))
        (should (floatp (plist-get task :queued-at)))
        (should (= (plist-get task :created) (plist-get task :queued-at)))
        (should (= (plist-get task :created) (harness-tasks--queued-since task))))
      ;; Written up for the backlog: it waits for the user, not for a slot.
      (let ((harness-provider-demo-script-override
             `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn))))
        (let ((id (harness-tasks-test-refine "the parser chokes on nested quotes")))
          (should-not (plist-get (harness-tasks-test-task id) :queued-at))
          (harness-tasks-test-wait-state id 'pending)
          (should (eq 'backlog (plist-get (harness-tasks-test-task id) :column)))
          (should-not (plist-get (harness-tasks-test-task id) :queued-at))
          (let ((before (float-time)))
            (harness-call 'task/queue id)
            (let ((task (harness-tasks-test-task id)))
              (should (eq 'pending (plist-get task :column)))
              (should (<= before (plist-get task :queued-at) (float-time)))
              (should (< (plist-get task :created) (plist-get task :queued-at)))))))
      ;; Returned to pending: it waits from the return.
      (let ((harness-provider-demo-script-override '((:type wait :seconds 30))))
        (let* ((id (harness-tasks-test-submit "starts, then is returned"))
               (created (plist-get (harness-tasks-test-task id) :created)))
          (harness-call 'task/start id)
          (should-not (plist-get (harness-tasks-test-task id) :queued-at))
          (let ((before (float-time)))
            (harness-call 'task/return-to-pending id)
            (harness-test-wait (lambda () (harness-tasks-test--idle id)) 5 "its turn to stop")
            (let ((task (harness-tasks-test-task id)))
              (should (eq 'pending (plist-get task :state)))
              (should (<= before (plist-get task :queued-at) (float-time)))
              (should (= (plist-get task :returned) (plist-get task :queued-at)))
              (should (< created (plist-get task :queued-at)))
              (should (= (plist-get task :queued-at) (harness-tasks--queued-since task))))))))))

(ert-deftest harness-tasks-queued-at-is-stamped-when-feedback-waits-for-a-slot ()
  "Work sent back from review that has to wait for a slot waits from then.
The suspended queue holds it back; it starts when the queue resumes,
and the wait it recorded began when it was sent back."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let ((harness-tasks-require-verification t)
          (harness-provider-demo-script-override
           '((:type text :delta "Done.\n") (:type done :stop-reason end-turn))))
      (let ((id (harness-tasks-test-submit "fix the parser")))
        (harness-tasks-test-wait-state id 'review)
        (should-not (plist-get (harness-tasks-test-task id) :queued-at))
        (harness-call 'task/suspend-queue default-directory)
        (let ((before (float-time)))
          (harness-call 'task/reject id "handle tabs too")
          (let ((task (harness-tasks-test-task id)))
            (should (eq 'pending (plist-get task :state)))
            (should (<= before (plist-get task :queued-at) (float-time)))
            (should (= (plist-get task :returned) (plist-get task :queued-at)))))
        (harness-tasks--set id :queued-at (- (float-time) 45))
        (harness-call 'task/resume-queue default-directory)
        (let* ((task (harness-tasks-test-task id))
               (wait (car (plist-get task :waits))))
          (should (eq 'active (plist-get task :state)))
          (should-not (plist-get task :queued-at))
          ;; Its first start waited too, for no time at all; this one for 45 s.
          (should (= 2 (length (plist-get task :waits))))
          (should (<= 45 (plist-get wait :seconds) 75))
          (should (= (plist-get task :started) (plist-get wait :at))))
        (harness-tasks-test-wait-state id 'review)))))

(ert-deftest harness-tasks-start-records-how-long-the-task-waited ()
  "A task that waited in the queue records the wait when it starts.
The wait says how long it queued and at which priority, newest first, and
`:queued-at' goes.  A backlog task started by hand waited for no slot
and records nothing; a task keeps its last 20 waits."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let ((harness-agent--cancel-grace 0.05)
          (harness-tasks-max-running 0))
      ;; Start now, on a task in the queue.
      (let* ((id (harness-tasks-test-submit-at "urgent, but it queued" "high"))
             (before (float-time)))
        (harness-tasks--set id :queued-at (- before 30))
        (harness-call 'task/start id)
        (let* ((task (harness-tasks-test-task id))
               (wait (car (plist-get task :waits))))
          (should (= 1 (length (plist-get task :waits))))
          (should (equal "high" (plist-get wait :priority)))
          (should (= (plist-get task :started) (plist-get wait :at)))
          (should (<= 30 (plist-get wait :seconds) (+ 30 (- (float-time) before))))
          (should-not (plist-get task :queued-at)))
        (harness-tasks-test-wait-state id 'done))
      ;; A backlog task started by hand waited for the user, not for a slot.
      (let ((harness-provider-demo-script-override
             `((:type text :delta ,harness-tasks-test-write-up) (:type done :stop-reason end-turn))))
        (let ((id (harness-tasks-test-refine "jot this down")))
          (harness-tasks-test-wait-state id 'pending)
          (harness-call 'task/start id)
          (should (eq 'active (harness-tasks-test-state id)))
          (should-not (plist-get (harness-tasks-test-task id) :waits))
          (harness-tasks-test-wait-state id 'done)
          (should-not (plist-get (harness-tasks-test-task id) :waits))
          (should-not (plist-get (harness-tasks-test-task id) :queued-at))))
      ;; Started, returned and started again: each start recorded its wait,
      ;; at the priority the task had then.
      (let ((harness-provider-demo-script-override '((:type wait :seconds 30))))
        (let ((id (harness-tasks-test-submit "starts twice")))
          (harness-call 'task/start id)
          (harness-call 'task/return-to-pending id)
          (harness-test-wait (lambda () (harness-tasks-test--idle id)) 5 "its turn to stop")
          (harness-call 'priority/set (harness-tasks-test-session-id id) "low")
          (harness-tasks--set id :queued-at (- (float-time) 20))
          (setq harness-provider-demo-script-override harness-tasks-test-script)
          (harness-call 'task/start id)
          (let ((waits (plist-get (harness-tasks-test-task id) :waits)))
            (should (= 2 (length waits)))
            (should (equal "low" (plist-get (car waits) :priority)))
            (should (<= 20 (plist-get (car waits) :seconds) 50))
            (should (equal "medium" (plist-get (cadr waits) :priority)))
            (should (> (plist-get (car waits) :at) (plist-get (cadr waits) :at))))
          (harness-tasks-test-wait-state id 'done)))
      ;; A task keeps its 20 latest waits, the newest first.
      (let ((id (harness-tasks-test-submit "has waited a lot")))
        (harness-tasks--set id :waits (cl-loop for n from 1 to 25
                                               collect (list :at (float n) :seconds 1.0 :priority "low")))
        (harness-call 'task/start id)
        (let ((waits (plist-get (harness-tasks-test-task id) :waits)))
          (should (= 20 (length waits)))
          (should (equal "medium" (plist-get (car waits) :priority)))
          (should (> (plist-get (car waits) :at) 100))
          (should (= 1.0 (plist-get (cadr waits) :at)))
          (should (= 19.0 (plist-get (car (last waits)) :at))))
        (harness-tasks-test-wait-state id 'done)))))

(ert-deftest harness-tasks-waits-are-kept-in-the-store ()
  "The waits a task recorded come back from the store as they were."
  (harness-tasks-test-with
    (let ((harness-tasks-max-running 0))
      (let ((id (harness-tasks-test-submit-at "waits, then is read back" "low")))
        (harness-tasks--set id :queued-at (- (float-time) 12.5))
        (harness-call 'task/start id)
        (harness-tasks-test-wait-state id 'done)
        (let ((waits (plist-get (harness-tasks-test-task id) :waits)))
          (should (= 1 (length waits)))
          (should (equal "low" (plist-get (car waits) :priority)))
          (harness-tasks--save)
          (clrhash harness-tasks--table)
          (setq harness-tasks--loaded nil)
          (harness-tasks--load)
          (should (equal waits (plist-get (harness-tasks-test-task id) :waits)))
          (should (stringp (plist-get (car (plist-get (harness-tasks-test-task id) :waits)) :priority))))))))

(defun harness-tasks-test--slot-ids (entries)
  "The ids of ENTRIES, plists of a `task/slots' answer."
  (mapcar (lambda (entry) (plist-get entry :id)) entries))

(defun harness-tasks-test--slot-values (key entries)
  "The values of KEY in ENTRIES, plists of a `task/slots' answer."
  (mapcar (lambda (entry) (plist-get entry key)) entries))

(defun harness-tasks-test--session-at (status &rest opts)
  "Make a session in the test directory with STATUS; return its id.
OPTS are more arguments of `session/create'."
  (let ((sid (plist-get (apply #'harness-call 'session/create :cwd default-directory
                               :model "demo:scripted" opts)
                        :id)))
    (harness-call 'session/set-status sid status)
    sid))

(defun harness-tasks-test--hold (state sid project &rest props)
  "Store a task record in STATE worked on by session SID, in PROJECT.
PROPS are more fields of the record.  Return its id."
  (let ((record (harness-tasks-test--record state sid project)))
    (while props (setq record (plist-put record (pop props) (pop props))))
    (plist-get (harness-tasks--put record) :id)))

(ert-deftest harness-tasks-slots-report-holders-queue-and-waits ()
  "task/slots tells a project's slot use from what the scheduler goes by.
Of four slots, the two tasks whose own sessions work hold one each, the
longest at work first: a sub-agent at work holds none, its own task or
not, nor does the merge queue.  The queue is the waiting tasks in the
order they will start, each since it joined it.  The waits are the
project's recent ones, any task's, newest first; another project's are
left out."
  (harness-tasks-test-with
    ;; The start-up pass that picks up interrupted work runs before the
    ;; records below exist, not after: it would take them for such work.
    (harness-tasks-test--settle)
    (let* ((now (float-time))
           (other (harness-test-temp-dir))
           low med high pre away project)
      ;; The queue, built while nothing may start.  They were made and
      ;; joined the queue at different times: the one pre-empted before
      ;; was made first and waits the shortest, and goes first of the
      ;; high ones, as a returned task does.
      (let ((harness-tasks-max-running 0))
        (setq low (harness-tasks-test-submit-at "low priority" "low")
              med (harness-tasks-test-submit "medium by default")
              high (harness-tasks-test-submit-at "high priority" "high")
              pre (harness-tasks-test-submit-at "high, pre-empted before" "high")
              away (harness-tasks-test-submit "another project's" other)))
      (setq project (plist-get (harness-tasks-test-task low) :project))
      (should-not (equal project (plist-get (harness-tasks-test-task away) :project)))
      (harness-tasks--set low :created (- now 5000) :queued-at (- now 500))
      (harness-tasks--set med :created (- now 4000) :queued-at (- now 400))
      (harness-tasks--set high :created (- now 3000) :queued-at (- now 300))
      (harness-tasks--set pre :created (- now 9000) :queued-at (- now 100)
                          :returned (- now 100) :return-reason 'preempted :preempted-by "t-other")
      ;; The backlog and the archive are not the queue.
      (harness-tasks-test--hold 'pending nil project :backlog t :prompt "in the backlog")
      (harness-tasks-test--hold 'pending nil project :archived t :prompt "archived while it waited")
      (let* ((sid-a (harness-tasks-test--session-at 'running :name "Parser fix"))
             (sid-b (harness-tasks-test--session-at 'blocked))
             (helper (harness-tasks-test--session-at 'running :kind 'subagent :parent-id sid-a))
             (merger (harness-tasks-test--session-at 'running))
             a b finished archived)
        (harness-call 'priority/set sid-a "high")
        ;; B was made first, but A has worked the longest: B was sent back.
        (setq a (harness-tasks-test--hold 'active sid-a project
                                          :name "Task title" :created (- now 4000) :started (- now 600))
              b (harness-tasks-test--hold 'active sid-b project
                                          :name "Write the docs" :created (- now 5000)
                                          :started (- now 900) :sent-back (- now 100)))
        (harness-tasks-test--hold 'active helper project :started (- now 800))
        (harness-tasks-test--hold 'merging merger project :started (- now 700))
        (harness-tasks-test--hold 'review nil project)
        ;; Waits: one in the queue's tasks, a done one (with an old wait too),
        ;; an archived one, and another project's.
        (harness-tasks--set med :waits (list (list :at (- now 60) :seconds 5.5 :priority "medium")))
        (setq finished (harness-tasks-test--hold
                        'done nil project
                        :waits (list (list :at (- now 3600) :seconds 12.0 :priority "high")
                                     (list :at (- now (* 8 86400)) :seconds 999.0 :priority "low")))
              archived (harness-tasks-test--hold
                        'done nil project :archived t
                        :waits (list (list :at (- now (* 2 86400)) :seconds 300.0 :priority "low"))))
        (harness-tasks--set away :waits (list (list :at (- now 10) :seconds 1.0 :priority "medium")))
        (let* ((harness-tasks-max-running 4)
               (slots (harness-call 'task/slots default-directory))
               (holders (plist-get slots :holders))
               (queue (plist-get slots :queue))
               (waits (plist-get slots :waits)))
          (should (equal project (plist-get slots :project)))
          (should (eql 4 (plist-get slots :limit)))
          (should (eq :false (plist-get slots :suspended)))
          (should (eql 7 (plist-get slots :days)))
          ;; Two slots held, the longest at work first.
          (should (equal (list a b) (harness-tasks-test--slot-ids holders)))
          (should (equal '("Parser fix" "Write the docs") (harness-tasks-test--slot-values :title holders)))
          (should (equal (list sid-a sid-b) (harness-tasks-test--slot-values :session holders)))
          (should (equal '("high" "medium") (harness-tasks-test--slot-values :priority holders)))
          (should (equal '("running" "blocked") (harness-tasks-test--slot-values :state holders)))
          (should (equal (list (- now 600) (- now 100)) (harness-tasks-test--slot-values :since holders)))
          (should (equal '(:false t) (harness-tasks-test--slot-values :sent-back holders)))
          ;; The queue in start order: high first, the pre-empted one leading.
          (should (equal (list pre high med low) (harness-tasks-test--slot-ids queue)))
          (should (equal '("high" "high" "medium" "low") (harness-tasks-test--slot-values :priority queue)))
          (should (equal (list (- now 100) (- now 300) (- now 400) (- now 500))
                         (harness-tasks-test--slot-values :since queue)))
          (should (equal '("preempted" nil nil nil) (harness-tasks-test--slot-values :reason queue)))
          (should (equal '("high, pre-empted before" "high priority" "medium by default" "low priority")
                         (harness-tasks-test--slot-values :title queue)))
          ;; The recent waits of the project, newest first.
          (should (equal (list med finished archived) (harness-tasks-test--slot-ids waits)))
          (should (equal '("medium" "high" "low") (harness-tasks-test--slot-values :priority waits)))
          (should (equal '(5.5 12.0 300.0) (harness-tasks-test--slot-values :seconds waits)))
          (should (equal (list (- now 60) (- now 3600) (- now (* 2 86400)))
                         (harness-tasks-test--slot-values :at waits)))
          ;; How far back they look is an option.
          (let ((harness-tasks-slot-wait-days 1))
            (let ((slots (harness-call 'task/slots default-directory)))
              (should (eql 1 (plist-get slots :days)))
              (should (equal (list med finished) (harness-tasks-test--slot-ids (plist-get slots :waits))))))
          (let ((harness-tasks-slot-wait-days 10))
            (should (equal (list med finished archived finished)
                           (harness-tasks-test--slot-ids
                            (plist-get (harness-call 'task/slots default-directory) :waits)))))
          (let ((harness-tasks--slot-waits-max 2))
            (should (equal (list med finished)
                           (harness-tasks-test--slot-ids
                            (plist-get (harness-call 'task/slots default-directory) :waits)))))
          ;; No limit, and a limit of nothing at all.
          (let ((harness-tasks-max-running nil))
            (should-not (plist-get (harness-call 'task/slots default-directory) :limit)))
          (let ((harness-tasks-max-running 0))
            (should (eql 0 (plist-get (harness-call 'task/slots default-directory) :limit))))
          ;; Another project's slots are its own.
          (let ((elsewhere (harness-call 'task/slots other)))
            (should-not (equal project (plist-get elsewhere :project)))
            (should-not (plist-get elsewhere :holders))
            (should (equal (list away) (harness-tasks-test--slot-ids (plist-get elsewhere :queue))))
            (should (equal (list away) (harness-tasks-test--slot-ids (plist-get elsewhere :waits)))))
          ;; A suspended queue says so.  Over the wire too, where the
          ;; lists arrive as lists of plists, a false as :false and a
          ;; nil as nothing; suspended, the queue starts nothing meanwhile.
          (harness-call 'task/suspend-queue default-directory)
          (should (eq t (plist-get (harness-call 'task/slots default-directory) :suspended)))
          (let* ((conn (harness-acp-connect))
                 (wire (harness-test-await
                        (harness-acp-request conn "_harness/task/slots" (list :cwd default-directory)))))
            (should (equal project (plist-get wire :project)))
            (should (eql 4 (plist-get wire :limit)))
            (should (eq t (plist-get wire :suspended)))
            (should (equal (list a b) (harness-tasks-test--slot-ids (plist-get wire :holders))))
            (should (keywordp (car (car (plist-get wire :holders)))))
            (should (eq :false (plist-get (car (plist-get wire :holders)) :sent-back)))
            (should (eq t (plist-get (cadr (plist-get wire :holders)) :sent-back)))
            (should (equal (list pre high med low) (harness-tasks-test--slot-ids (plist-get wire :queue))))
            (should (equal "preempted" (plist-get (car (plist-get wire :queue)) :reason)))
            (should-not (plist-get (cadr (plist-get wire :queue)) :reason))
            (should (equal (list med finished archived) (harness-tasks-test--slot-ids (plist-get wire :waits))))
            (should (< (abs (- (plist-get (car (plist-get wire :waits)) :at) (- now 60))) 0.001))
            (should (= 5.5 (plist-get (car (plist-get wire :waits)) :seconds)))))))))

(ert-deftest harness-tasks-slots-say-why-a-slot-is-held ()
  "A held slot is a task at work, blocked, waiting on work or still starting.
A task is called by its session's name, else its own, else the first
line of its prompt, cut at 80 characters.  A task whose session is idle
with nothing outstanding holds no slot, and a project without tasks has
nothing to report."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let* ((now (float-time))
           (project (harness-tasks--project default-directory))
           (long (concat "A first line that is longer than eighty characters, so that the slot view "
                         "has to cut it short"))
           (running (harness-tasks-test--hold 'active (harness-tasks-test--session-at 'running) project
                                              :started (- now 400) :name "Named task"
                                              :prompt "Its prompt, which its name beats"))
           (blocked (harness-tasks-test--hold 'active (harness-tasks-test--session-at 'blocked) project
                                              :started (- now 300) :prompt (concat "\n  " long "\nsecond line")))
           (waiting (harness-tasks-test--hold 'active (harness-tasks-test--session-at 'idle) project
                                              :started (- now 200) :waiting "2 workers running"
                                              :prompt "Waits on its workers\nand more"))
           (starting (harness-tasks-test--hold 'active nil project
                                               :started (- now 100) :prompt "Just starting")))
      (puthash starting t harness-tasks--starting)
      ;; Idle, with nothing outstanding: it holds nothing.
      (harness-tasks-test--hold 'active (harness-tasks-test--session-at 'idle) project :started (- now 50))
      (should-not (plist-get (harness-call 'task/slots (harness-test-temp-dir)) :holders))
      (let* ((harness-tasks-max-running 4)
             (slots (harness-call 'task/slots default-directory))
             (holders (plist-get slots :holders)))
        (should-not (plist-get slots :queue))
        (should-not (plist-get slots :waits))
        (should (equal (list running blocked waiting starting) (harness-tasks-test--slot-ids holders)))
        (should (equal '("running" "blocked" "waiting" "starting")
                       (harness-tasks-test--slot-values :state holders)))
        (should (equal '("Named task" "Waits on its workers" "Just starting")
                       (harness-tasks-test--slot-values :title (cons (car holders) (cddr holders)))))
        (let ((title (plist-get (cadr holders) :title)))
          (should (= 80 (length title)))
          (should (string-prefix-p "A first line that is longer than eighty characters" title))
          (should (string-suffix-p "…" title)))
        (should-not (plist-get (car (last holders)) :session))
        (should (equal '("medium" "medium" "medium" "medium")
                       (harness-tasks-test--slot-values :priority holders)))))))
(ert-deftest harness-tasks-session-says-its-context-is-capped ()
  "A task session created with the task cap says so in a hint naming
the setting that capped it, so the cap is never silent; without a cap
nothing is said."
  (harness-tasks-test-with
    (let* ((id (harness-tasks-test-submit "fix the parser"))
           (sid (harness-tasks-test-session-id id)))
      (should (member "Context window capped at 384k tokens, as a task session's is (harness-tasks-context-limit)"
                      (harness-tasks-test-hints sid))))
    (let ((harness-tasks-context-limit 4000))
      (let* ((id (harness-tasks-test-submit "keep it small"))
             (sid (harness-tasks-test-session-id id)))
        (should (member "Context window capped at 4k tokens, as a task session's is (harness-tasks-context-limit)"
                        (harness-tasks-test-hints sid)))))
    (let ((harness-tasks-context-limit nil))
      (let* ((id (harness-tasks-test-submit "and another one"))
             (sid (harness-tasks-test-session-id id)))
        (should-not (harness-tasks-test--hint-p sid "Context window capped"))))))

;;;; Waking a stopped task while a message is on its way

(ert-deftest harness-tasks-wake-shows-a-stopped-task-at-work ()
  "A user's message on its way to a stopped task shows it at work at once.
Until its turn starts the task would still show where it stopped; the
marker clears when the turn begins."
  (harness-tasks-test-with
    (let ((harness-provider-demo-script-override
           '((:type done :stop-reason error :error "boom"))))
      (let* ((id (harness-tasks-test-submit "will fail"))
             (sid (plist-get (harness-tasks-test-task id) :session)))
        (harness-test-wait
         (lambda () (eq 'needs-input (plist-get (harness-tasks-test-task id) :column)))
         10 "the task to stop in needs-input")
        (should (eq 'active (harness-tasks-test-state id)))
        ;; The message is on its way: show it at work though no turn runs.
        (harness-tasks--wake id)
        (should (eq 'active (plist-get (harness-call 'task/get id) :column)))
        (should (harness-tasks--waking-p (harness-tasks-test-task id)))
        ;; The turn starting clears the marker.
        (harness-tasks--on-turn-started sid)
        (should-not (harness-tasks--waking-p (harness-tasks-test-task id)))
        (should-not (gethash id harness-tasks--waking))))))

(ert-deftest harness-tasks-wake-worthy-only-for-stopped-and-done ()
  "Only a task a user's message moves shows the waking marker.
A task stopped part way (active with an outcome) or a completed one
being reopened is woken; one in review, pending or being written up is
not, and neither is one at work or merging already."
  (harness-tasks-test-with
    (let ((sid (plist-get (harness-call 'session/create :cwd default-directory) :id)))
      (dolist (id '("t-review" "t-pending" "t-refining" "t-active"))
        (harness-tasks--put (list :id id :project default-directory :cwd default-directory
                                  :prompt "task" :session sid :state 'active
                                  :created (float-time))))
      (harness-tasks--set "t-review" :state 'review)
      (harness-tasks--set "t-pending" :state 'pending)
      (harness-tasks--set "t-refining" :state 'refining)
      (harness-tasks--set "t-active" :state 'active :outcome 'error)
      (should-not (harness-tasks--wake-worthy-p (harness-tasks-test-task "t-review")))
      (should-not (harness-tasks--wake-worthy-p (harness-tasks-test-task "t-pending")))
      (should-not (harness-tasks--wake-worthy-p (harness-tasks-test-task "t-refining")))
      (should (harness-tasks--wake-worthy-p (harness-tasks-test-task "t-active"))))))

;;;; Pre-emption and return stop the work left running outside the turn
;;
;; A task whose session left work running outside its turn -- a
;; supervisor's workers, sub-agents -- has that work stopped through
;; `agent/stop-outstanding' when it is pre-empted or returned to the
;; queue, once no turn of its session runs.  The tests fake that work
;; with handlers of their own for "write the docs".

(declare-function harness-define-tool "harness-tools")

(defvar harness-tasks-test--workers nil
  "Non-nil while the test's workers run for the task of \"write the docs\".
Its session's `agent/outstanding' then says \"2 workers running\"
\(`harness-tasks-test--report-workers'), and `agent/stop-outstanding'
stops them (`harness-tasks-test--stop-workers').")

(defvar harness-tasks-test--stops nil
  "The calls of the test's `agent/stop-outstanding' handler, newest first.
Each is (SESSION-ID REASON RUNNING), RUNNING non-nil when a turn of
the session ran at the time.")

(defvar harness-tasks-test--stop-report nil
  "What the test's workers report to their session when stopped, or nil.
It goes as a supervisor's report does: a message of the harness's.")

(defun harness-tasks-test--workers-p (session-id)
  "Non-nil while the test's workers run for SESSION-ID."
  (and harness-tasks-test--workers
       (let ((task (harness-tasks--by-session session-id)))
         (and task (equal "write the docs" (plist-get task :prompt))))))

(defun harness-tasks-test--report-workers (value session-id)
  "`agent/outstanding' handler: add the test's workers to VALUE while they run."
  (if (harness-tasks-test--workers-p session-id)
      (concat (and value (concat value "; ")) "2 workers running")
    value))

(defun harness-tasks-test--stop-workers (value session-id reason)
  "`agent/stop-outstanding' handler: stop the test's workers, told REASON.
Every call is recorded in `harness-tasks-test--stops'.  Workers running
for SESSION-ID stop, report `harness-tasks-test--stop-report' when set,
and say so after VALUE; else VALUE stands."
  (push (list session-id reason (and (harness-call 'agent/running session-id) t))
        harness-tasks-test--stops)
  (if (not (harness-tasks-test--workers-p session-id))
      value
    (setq harness-tasks-test--workers nil)
    (when harness-tasks-test--stop-report
      (harness-catch (harness-call-async 'agent/prompt session-id harness-tasks-test--stop-report
                                         (list :from (harness-sender-system "supervisor")))
                     #'ignore))
    (concat (and value (concat value "; ")) "2 workers stopped")))

(defmacro harness-tasks-test-with-workers (&rest body)
  "Run BODY with the test's workers running and their handlers on the bus."
  (declare (indent 0))
  `(let ((harness-tasks-test--workers t)
         (harness-tasks-test--stops nil)
         (harness-tasks-test--stop-report nil))
     (harness-add-filter 'agent/outstanding #'harness-tasks-test--report-workers)
     (harness-add-filter 'agent/stop-outstanding #'harness-tasks-test--stop-workers)
     (unwind-protect (progn ,@body)
       (harness-remove-filter 'agent/outstanding #'harness-tasks-test--report-workers)
       (harness-remove-filter 'agent/stop-outstanding #'harness-tasks-test--stop-workers))))

(defun harness-tasks-test--hint-position (sid prefix)
  "Return where the first hint of session SID starting with PREFIX is, or nil."
  (cl-position-if (lambda (hint) (and (stringp hint) (string-prefix-p prefix hint)))
                  (harness-tasks-test-hints sid)))

(defun harness-tasks-test--said-position (sid text)
  "Return where the first user message of session SID saying TEXT is, or nil."
  (cl-position text (harness-tasks-test-user-nodes sid)
               :key (lambda (n) (plist-get n :content)) :test #'equal))

(ert-deftest harness-tasks-sent-back-task-preempts-a-task-waiting-on-its-workers ()
  "Work sent back from review takes the slot of a task waiting on its workers.
That task's turn is over, but its workers run on, so it holds its slot.
Pre-empting it stops them at once, as no turn of its session runs, told
why: its session says it was pre-empted, then what was stopped.  When
the slot frees again it carries on in its session, told why by the
harness."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (harness-tasks-test-with-workers
      (let* ((harness-tasks-max-running 1)
             (harness-tasks-require-verification t)
             (harness-provider-demo-script-override harness-tasks-test--quick)
             (reviewed (harness-tasks-test-submit "fix the parser"))
             (rsid (harness-tasks-test-session-id reviewed)))
        (harness-tasks-test-wait-state reviewed 'review)
        (let* ((busy (harness-tasks-test-submit "write the docs"))
               (bsid (harness-tasks-test-session-id busy)))
          ;; Its turn ends at once, its workers running on: it waits on
          ;; them, at work, and holds the slot.
          (harness-test-wait (lambda () (harness-tasks-test--waiting busy)) 5 "the task to wait on its workers")
          (harness-test-wait (lambda () (harness-tasks-test--idle busy)) 5 "its turn to end")
          (harness-tasks-test--settle)
          (let ((waiting (harness-tasks-test-task busy)))
            (should (eq 'active (plist-get waiting :state)))
            (should (= 0 (harness-tasks--free-slots (harness-tasks--slot-project waiting)))))
          (should-not harness-tasks-test--stops)
          (harness-call 'task/reject reviewed "handle tabs too")
          ;; The task sent back has the slot; the other is back in line.
          (let ((preempted (harness-tasks-test-task busy)))
            (should (eq 'pending (plist-get preempted :state)))
            (should (eq 'preempted (plist-get preempted :return-reason)))
            (should (equal reviewed (plist-get preempted :preempted-by)))
            (should-not (plist-get preempted :waiting)))
          (should (memq (harness-tasks-test-state reviewed) '(active review)))
          ;; Its workers were stopped there and then, once, told why.
          (should (= 1 (length harness-tasks-test--stops)))
          (pcase-let ((`(,sid ,reason ,running) (car harness-tasks-test--stops)))
            (should (equal bsid sid))
            (should (string-prefix-p (format "its task was pre-empted: task %s" reviewed) reason))
            (should (string-suffix-p ", sent back from review, took its slot" reason))
            (should-not running))
          (should-not harness-tasks-test--workers)
          ;; Its session says it was pre-empted, then what was stopped.
          (let ((said (harness-tasks-test--hint-position bsid "Task pre-empted: task "))
                (stopped (harness-tasks-test--hint-position
                          bsid "Stopped while the task waits in the queue: 2 workers stopped")))
            (should said)
            (should stopped)
            (should (< said stopped)))
          ;; The task sent back works on the feedback, and is back in review;
          ;; the slot it frees goes to the task it pre-empted, which carries
          ;; on in its own session, told why by the harness.
          (harness-tasks-test-wait-state reviewed 'review)
          (should (harness-tasks-test--said rsid (harness-tasks--reject-text "handle tabs too")))
          (harness-tasks-test-wait-state busy 'review)
          (let ((opening (car (harness-tasks-test--said bsid harness-tasks--preempted-message))))
            (should opening)
            (should (eq 'system (harness-sender-kind (harness-node-sender opening)))))
          (should (equal bsid (plist-get (harness-tasks-test-task busy) :session)))
          ;; Nothing else was stopped.
          (should (= 1 (length harness-tasks-test--stops))))))))

(ert-deftest harness-tasks-return-to-pending-stops-the-work-left-running ()
  "Returning a task that waits on its workers stops them and frees its slot.
Its turn is over, so they stop at once, told why, and the task next in
line takes the slot.  When it starts again its session carries on,
told so by the harness."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (harness-tasks-test-with-workers
      (let* ((harness-tasks-max-running 1)
             (harness-provider-demo-script-override harness-tasks-test--quick)
             (busy (harness-tasks-test-submit "write the docs"))
             (bsid (harness-tasks-test-session-id busy)))
        (harness-test-wait (lambda () (harness-tasks-test--waiting busy)) 5 "the task to wait on its workers")
        (harness-test-wait (lambda () (harness-tasks-test--idle busy)) 5 "its turn to end")
        (let ((next (harness-tasks-test-submit "fix the parser")))
          ;; No slot for the next task while the first waits on its workers.
          (harness-tasks-test--settle)
          (should (eq 'pending (harness-tasks-test-state next)))
          (should (eq 'active (harness-tasks-test-state busy)))
          (should (eq 'pending (plist-get (harness-call 'task/return-to-pending busy) :state)))
          ;; Its workers were stopped there and then, once, told why.
          (should (equal (list (list bsid "its task was returned to the queue" nil)) harness-tasks-test--stops))
          (should-not harness-tasks-test--workers)
          (should (harness-tasks-test--hint-p bsid "Stopped while the task waits in the queue: 2 workers stopped"))
          ;; Its slot goes to the next task; when that is done, it carries on.
          (harness-tasks-test-wait-state next 'done)
          (harness-tasks-test-wait-state busy 'done)
          (let ((opening (car (harness-tasks-test--said bsid harness-tasks--paused-message))))
            (should opening)
            (should (eq 'system (harness-sender-kind (harness-node-sender opening)))))
          (should (= 1 (length harness-tasks-test--stops))))))))

(ert-deftest harness-tasks-return-to-pending-is-not-undone-by-the-stopped-work ()
  "What the work stopped with a return reports does not start the task again.
The report reaches the session while the task waits: its turn is
refused and the message kept for the task's start.  The return starts
nothing, though a slot is free, until the task is started; then the
session carries on with the report before the harness's message."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (harness-tasks-test-with-workers
      (let* ((harness-tasks-max-running 1)
             (harness-provider-demo-script-override harness-tasks-test--quick)
             (harness-tasks-test--stop-report "Step 2 (write the docs) was interrupted: its task was returned to the queue.")
             (busy (harness-tasks-test-submit "write the docs"))
             (bsid (harness-tasks-test-session-id busy)))
        (harness-test-wait (lambda () (harness-tasks-test--waiting busy)) 5 "the task to wait on its workers")
        (harness-test-wait (lambda () (harness-tasks-test--idle busy)) 5 "its turn to end")
        ;; The scheduling pass its turn's end asked for is over.
        (harness-tasks-test--settle)
        (harness-call 'task/return-to-pending busy)
        (should (= 1 (length harness-tasks-test--stops)))
        (harness-test-wait (lambda () (harness-tasks-test--hint-p bsid "Turn not started: its task ")) 5
                           "the report's turn refused")
        (should (harness-tasks-test--said bsid harness-tasks-test--stop-report))
        (harness-test-wait (lambda () (harness-tasks-test--idle busy)) 5 "the refused turn over")
        (accept-process-output nil 0.2)
        ;; The slot is free, but the task waits on.
        (should (= 1 (harness-tasks--free-slots (harness-tasks--slot-project (harness-tasks-test-task busy)))))
        (should (eq 'pending (harness-tasks-test-state busy)))
        (should-not (harness-tasks-test--said bsid harness-tasks--paused-message))
        ;; Started, it carries on, the report before the harness's message.
        (harness-call 'task/start busy)
        (harness-tasks-test-wait-state busy 'done)
        (let ((report (harness-tasks-test--said-position bsid harness-tasks-test--stop-report))
              (opening (harness-tasks-test--said-position bsid harness-tasks--paused-message)))
          (should report)
          (should opening)
          (should (< report opening)))
        (should (= 1 (length (harness-tasks-test--said bsid harness-tasks-test--stop-report))))
        (should (= 1 (length harness-tasks-test--stops)))))))

(ert-deftest harness-tasks-preempted-turn-ends-before-its-workers-stop ()
  "A task pre-empted mid-turn has its workers stopped once that turn has ended.
The turn takes a while to stop (a call that does not return holds it
up until the cancel's grace is out); the workers run on until then.
Stopped with no turn of the session running, what they report reaches
it while the task waits, refused and kept, rather than steering the
turn being cancelled, and the task carries on with it once it starts
again."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (harness-tasks-test-with-workers
      (let* ((stall t)
             (stalled nil)
             (feedback-turn
              '((:type wait :seconds 0.6) (:type text :delta "Done.\n") (:type done :stop-reason end-turn)))
             (sent-back nil)
             (harness-agent--cancel-grace 0.2)
             (harness-tasks-max-running 1)
             (harness-tasks-require-verification t)
             (harness-tasks-test--stop-report "Step 2 (write the docs) was interrupted: its task was pre-empted.")
             (harness-provider-demo-script-override
              (lambda (request)
                (let* ((task (harness-tasks--by-session (plist-get (plist-get request :session) :id)))
                       (prompt (plist-get task :prompt)))
                  (cond ((and stall (equal "write the docs" prompt))
                         '((:type tool-call :id "s-1" :name "stall" :input nil)))
                        ((and sent-back (equal "fix the parser" prompt)) feedback-turn)
                        (t harness-tasks-test--quick)))))
             (reviewed (harness-tasks-test-submit "fix the parser")))
        (harness-define-tool "stall" :label "Stall" :description "never returns" :kind 'read
                             :handler (lambda (_input _ctx)
                                        (setq stalled t)
                                        (harness-with-promise (resolve reject) (ignore resolve reject))))
        (harness-tasks-test-wait-state reviewed 'review)
        (let* ((busy (harness-tasks-test-submit "write the docs"))
               (bsid (harness-tasks-test-session-id busy)))
          ;; At work mid-turn, on a call that does not return.
          (harness-test-wait (lambda () stalled) 5 "the task at work on its call")
          (should (harness-tasks-test--running-p bsid))
          (setq stall nil sent-back t)
          (harness-call 'task/reject reviewed "handle tabs too")
          (should (eq 'pending (harness-tasks-test-state busy)))
          (should (eq 'preempted (plist-get (harness-tasks-test-task busy) :return-reason)))
          ;; Its turn is still stopping: its workers run on, untouched.
          (should (harness-call 'agent/running bsid))
          (should-not harness-tasks-test--stops)
          (should harness-tasks-test--workers)
          (should-not (harness-tasks-test--hint-position bsid "Task pre-empted: task "))
          ;; Once the turn has ended they stop, while no turn of it runs.
          (harness-test-wait (lambda () harness-tasks-test--stops) 5 "the workers stopped")
          (should (= 1 (length harness-tasks-test--stops)))
          (pcase-let ((`(,sid ,reason ,running) (car harness-tasks-test--stops)))
            (should (equal bsid sid))
            (should (string-prefix-p (format "its task was pre-empted: task %s" reviewed) reason))
            (should-not running))
          (should (eq 'pending (harness-tasks-test-state busy)))
          (should (memq (harness-tasks-test-state reviewed) '(active review)))
          (let ((said (harness-tasks-test--hint-position bsid "Task pre-empted: task "))
                (stopped (harness-tasks-test--hint-position
                          bsid "Stopped while the task waits in the queue: 2 workers stopped")))
            (should said)
            (should stopped)
            (should (< said stopped)))
          ;; Their report waits in the session for the task's start, which
          ;; comes once the task sent back is in review again.
          (harness-test-wait (lambda () (harness-tasks-test--said bsid harness-tasks-test--stop-report)) 5
                             "the report kept")
          (harness-tasks-test-wait-state reviewed 'review)
          (harness-tasks-test-wait-state busy 'review)
          (let ((report (harness-tasks-test--said-position bsid harness-tasks-test--stop-report))
                (opening (harness-tasks-test--said-position bsid harness-tasks--preempted-message)))
            (should report)
            (should opening)
            (should (< report opening)))
          (should (= 1 (length harness-tasks-test--stops))))))))

(ert-deftest harness-tasks-started-again-before-its-turn-stopped-keeps-its-work ()
  "A task started again while the turn its return stopped is ending keeps its work.
It is back at work when that turn ends, so its workers run on: nothing
of its is stopped, and its next turn ends waiting on them again."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (harness-tasks-test-with-workers
      (let* ((stall t)
             (stalled nil)
             (harness-agent--cancel-grace 0.3)
             (harness-tasks-max-running 1)
             (harness-provider-demo-script-override
              (lambda (request)
                (let ((task (harness-tasks--by-session (plist-get (plist-get request :session) :id))))
                  (if (and stall (equal "write the docs" (plist-get task :prompt)))
                      '((:type tool-call :id "s-1" :name "stall" :input nil))
                    harness-tasks-test--quick)))))
        (harness-define-tool "stall" :label "Stall" :description "never returns" :kind 'read
                             :handler (lambda (_input _ctx)
                                        (setq stalled t)
                                        (harness-with-promise (resolve reject) (ignore resolve reject))))
        (let* ((busy (harness-tasks-test-submit "write the docs"))
               (bsid (harness-tasks-test-session-id busy)))
          (harness-test-wait (lambda () stalled) 5 "the task at work on its call")
          (setq stall nil)
          (harness-call 'task/return-to-pending busy)
          (should (eq 'pending (harness-tasks-test-state busy)))
          (should (harness-call 'agent/running bsid))
          ;; The user's message starts it again while that turn is ending.
          (harness-call 'task/prompt busy "Go on with the docs.")
          (should (eq 'active (harness-tasks-test-state busy)))
          ;; The turn ends, the task carries on, and its workers run on.
          (harness-test-wait (lambda () (harness-tasks-test--waiting busy)) 5 "the task to wait on its workers")
          (should (eq 'active (harness-tasks-test-state busy)))
          (should harness-tasks-test--workers)
          (should-not harness-tasks-test--stops)
          (should-not (harness-tasks-test--hint-p bsid "Stopped while the task waits in the queue: ")))))))

;;;; Lending a blocked task's slot

(declare-function harness-tasks--lending-p "harness-tasks")
(declare-function harness-tasks--blocked-since "harness-tasks")
(declare-function harness-tasks--reclaim "harness-tasks")

(defun harness-tasks-test--block (sid &optional question)
  "Have session SID ask the user QUESTION; return the pending request's id."
  (harness-call 'session/pending-add sid
                (list :kind 'question :payload (list :question (or question "Which one?")))))

(defun harness-tasks-test--borrowed-from (id)
  "Whose lent slot task ID says it works in, or nil."
  (plist-get (harness-tasks-test-task id) :borrowed-from))

(ert-deftest harness-tasks-blocked-task-lends-its-slot-once-it-waited-long-enough ()
  "A task blocked on the user keeps its slot until it has waited long enough.
Then it lends it: it holds no slot, and its project has one more free.
How long it waited is how long its session has been blocked.  A task
waiting on work it left running -- workers once its turn ended,
sub-agents mid-turn -- keeps its slot, and so does one working in a
borrowed slot; a sub-agent blocked takes no slot either way.  With the
wait nil, or without slots, nothing is lent, as before.  Answered, the
task holds its slot again."
  (harness-tasks-test-with
    (let* ((harness-tasks-max-running 2)
           (harness-tasks-lend-blocked-slot-after 300)
           (top (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted") :id))
           (task (harness-tasks-test--record 'active top))
           (project (plist-get task :project)))
      (harness-tasks--put task)
      (harness-call 'session/set-status top 'running)
      (should (harness-tasks--holds-slot-p task))
      (let ((pid (harness-tasks-test--block top)))
        (should (eq 'blocked (plist-get (harness-call 'session/get top) :status)))
        ;; Blocked since now: it keeps its slot for the wait.
        (let ((since (harness-tasks--blocked-since (harness-call 'session/get top))))
          (should (numberp since))
          (should (< (- (float-time) since) 5)))
        (should (harness-tasks--holds-slot-p task))
        (should-not (harness-tasks--lending-p task))
        (should (= 1 (harness-tasks--free-slots project)))
        ;; Blocked for longer than the wait: it lends its slot.
        (puthash top (- (float-time) 301) harness-tasks--blocked-at)
        (should (harness-tasks--lending-p task))
        (should-not (harness-tasks--holds-slot-p task))
        (should (= 2 (harness-tasks--free-slots project)))
        ;; Work it left running keeps its slot: workers once its turn
        ;; ended ...
        (should (harness-tasks--holds-slot-p (append task (list :waiting "2 workers running"))))
        ;; ... or a sub-agent still at work mid-turn.
        (let ((report (lambda (value session-id) (if (equal session-id top) "1 sub-agent running" value))))
          (harness-add-filter 'agent/outstanding report)
          (unwind-protect (should (harness-tasks--holds-slot-p task))
            (harness-remove-filter 'agent/outstanding report)))
        (should-not (harness-tasks--holds-slot-p task))
        ;; A borrowed slot is not lent on.
        (should (harness-tasks--holds-slot-p (append task (list :borrowed-from "t-lender"))))
        ;; Without a wait, or without slots, nothing is lent.
        (let ((harness-tasks-lend-blocked-slot-after nil))
          (should (harness-tasks--holds-slot-p task))
          (should (= 1 (harness-tasks--free-slots project))))
        (dolist (limit '(nil 0))
          (let ((harness-tasks-max-running limit))
            (should (harness-tasks--holds-slot-p task))
            (should-not (harness-tasks--lending-p task))))
        ;; A sub-agent blocked holds no slot, lending or not.
        (let ((sub (plist-get (harness-call 'session/create :cwd dir :model "demo:scripted"
                                            :kind 'subagent :parent-id top)
                              :id)))
          (harness-tasks-test--block sub)
          (should-not (harness-tasks--holds-slot-p (harness-tasks-test--record 'active sub)))
          (puthash sub (- (float-time) 301) harness-tasks--blocked-at)
          (should-not (harness-tasks--holds-slot-p (harness-tasks-test--record 'active sub))))
        ;; Answered, it works again and holds its slot.
        (harness-call 'session/pending-resolve top pid "this")
        (should (eq 'running (plist-get (harness-call 'session/get top) :status)))
        (should-not (gethash top harness-tasks--blocked-at))
        (should-not (harness-tasks--lending-p task))
        (should (harness-tasks--holds-slot-p task))
        (harness-call 'session/set-status top 'idle)))))

(ert-deftest harness-tasks-blocked-task-lends-its-slot-and-takes-it-back ()
  "A task blocked long enough lends its slot; the user's answer takes it back.
While the task has waited less than `harness-tasks-lend-blocked-slot-after'
it keeps its slot and the next task waits.  Then, with no other event,
that task starts in the slot, as its borrower.  The answer takes the
slot back at once: the borrower goes back to the front of the queue,
its turn stopped, its session, branch and worktree kept, and its session
says why; the task answered works on in its slot.  When the slot frees,
the borrower carries on in its own session and worktree, told why by
the harness."
  (harness-tasks-test-with-git
    (harness-tasks-test--settle)
    (let* ((harness-tasks-test--slow (list "Ask about the parser" "Write the docs"))
           (harness-agent--cancel-grace 0.05)
           (harness-tasks-max-running 1)
           (harness-tasks-lend-blocked-slot-after 0.5)
           (harness-provider-demo-script-override #'harness-tasks-test--slow-script)
           (lender (harness-tasks-test-submit "Ask about the parser"))
           (lsid (harness-tasks-test-session-id lender)))
      (harness-test-wait (lambda () (harness-tasks-test--running-p lsid)) 10 "the first task at work")
      (let* ((borrower (harness-tasks-test-submit "Write the docs"))
             (bsid (harness-tasks-test-session-id borrower))
             (pid (harness-tasks-test--block lsid "Which parser?")))
        ;; Blocked for less than the wait: it keeps its slot, and the next
        ;; task waits.
        (harness-tasks--schedule)
        (should (eq 'pending (harness-tasks-test-state borrower)))
        (should (harness-tasks--holds-slot-p (harness-tasks-test-task lender)))
        (should-not (harness-tasks-test--borrowed-from borrower))
        ;; The wait over, the next task starts in the slot it lends.
        (harness-test-wait (lambda () (eq 'active (harness-tasks-test-state borrower))) 10 "the borrower to start")
        (should (equal lender (harness-tasks-test--borrowed-from borrower)))
        (should (harness-tasks--lending-p (harness-tasks-test-task lender)))
        (should (eq 'needs-input (plist-get (harness-tasks-test-task lender) :column)))
        (harness-test-wait (lambda () (and (plist-get (harness-tasks-test-task borrower) :worktree)
                                           (harness-tasks-test--running-p bsid)))
                           10 "the borrower at work in its worktree")
        (let* ((task (harness-tasks-test-task borrower))
               (worktree (plist-get task :worktree))
               (branch (plist-get task :branch)))
          (should (file-directory-p worktree))
          ;; The answer takes the slot back.
          (harness-call 'session/pending-resolve lsid pid "the new one")
          (harness-test-wait (lambda () (eq 'pending (harness-tasks-test-state borrower))) 5
                             "the borrower back in the queue")
          (let ((back (harness-tasks-test-task borrower)))
            (should (eq 'reclaimed (plist-get back :return-reason)))
            (should (equal lender (plist-get back :preempted-by)))
            (should (plist-get back :returned))
            (should-not (plist-get back :borrowed-from))
            (should (equal bsid (plist-get back :session)))
            (should (equal worktree (plist-get back :worktree)))
            (should (equal branch (plist-get back :branch))))
          (should (file-directory-p worktree))
          ;; Its turn stops, and its session says why.
          (harness-test-wait (lambda () (harness-tasks-test--hint-p bsid "Task pre-empted: task ")) 5
                             "the borrower told why")
          (should (cl-some (lambda (hint) (and (stringp hint)
                                               (string-match-p "was answered and took its slot back" hint)))
                           (harness-tasks-test-hints bsid)))
          (should-not (harness-call 'agent/running bsid))
          ;; The task answered works on, in its slot.
          (let ((answered (harness-tasks-test-task lender)))
            (should (eq 'active (plist-get answered :state)))
            (should (eq 'active (plist-get answered :column)))
            (should (harness-tasks-test--running-p lsid))
            (should (= 0 (harness-tasks--free-slots (harness-tasks--slot-project answered)))))
          (harness-tasks-test--settle)
          (should (eq 'pending (harness-tasks-test-state borrower)))
          ;; Once it stops, the borrower carries on in its session and worktree.
          (setq harness-tasks-test--slow nil)
          (harness-call 'task/cancel lender)
          (harness-test-wait (lambda () (harness-tasks-test--said bsid harness-tasks--reclaimed-message)) 10
                             "the borrower to carry on")
          (let ((opening (car (harness-tasks-test--said bsid harness-tasks--reclaimed-message))))
            (should (eq 'system (harness-sender-kind (harness-node-sender opening)))))
          (should (equal worktree (plist-get (harness-call 'session/get bsid) :cwd)))
          (should (equal bsid (harness-tasks-test-session-id borrower))))))))

(ert-deftest harness-tasks-borrower-that-gave-the-slot-up-is-not-stopped ()
  "A borrower that already gave the slot up leaves nothing to take back.
It borrowed the lent slot and finished in it: the loan ended with it.
The lender's answer then stops nothing, and the lender works on."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let* ((harness-tasks-test--slow (list "Ask about the parser"))
           (harness-agent--cancel-grace 0.05)
           (harness-tasks-max-running 1)
           (harness-tasks-lend-blocked-slot-after 0.3)
           (harness-provider-demo-script-override #'harness-tasks-test--slow-script)
           (borrowed nil)
           (lender (harness-tasks-test-submit "Ask about the parser"))
           (lsid (harness-tasks-test-session-id lender)))
      (harness-on 'task/changed (lambda (task)
                                  (when (plist-get task :borrowed-from)
                                    (push (cons (plist-get task :id) (plist-get task :borrowed-from)) borrowed))))
      (harness-test-wait (lambda () (harness-tasks-test--running-p lsid)) 5 "the first task at work")
      (let* ((pid (harness-tasks-test--block lsid))
             (quick (harness-tasks-test-submit "Fix a typo")))
        (should (eq 'pending (harness-tasks-test-state quick)))
        ;; It borrows the lent slot and is done in it; the loan ends.
        (harness-tasks-test-wait-state quick 'done)
        (should (member (cons quick lender) borrowed))
        (harness-tasks-test--settle)
        (should-not (harness-tasks-test--borrowed-from quick))
        ;; The answer has nothing to take back.
        (harness-call 'session/pending-resolve lsid pid "go on")
        (harness-tasks-test--settle)
        (should-not (harness-tasks--reclaim lender))
        (let ((done (harness-tasks-test-task quick)))
          (should (eq 'done (plist-get done :state)))
          (should-not (plist-get done :return-reason)))
        (should (eq 'active (harness-tasks-test-state lender)))
        (should (harness-tasks-test--running-p lsid))
        (harness-call 'task/cancel lender)))))

(ert-deftest harness-tasks-lent-slot-goes-to-the-next-borrower ()
  "The slot a borrower gives up while its lender still waits goes to the next task.
That task is the lender's borrower now, and it is the one the answer
stops; the borrower done stays done."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let* ((harness-tasks-test--slow (list "Ask about the parser" "Write the docs"))
           (harness-agent--cancel-grace 0.05)
           (harness-tasks-max-running 1)
           (harness-tasks-lend-blocked-slot-after 0.3)
           (harness-provider-demo-script-override #'harness-tasks-test--slow-script)
           (lender (harness-tasks-test-submit "Ask about the parser"))
           (lsid (harness-tasks-test-session-id lender)))
      (harness-test-wait (lambda () (harness-tasks-test--running-p lsid)) 5 "the first task at work")
      (let* ((pid (harness-tasks-test--block lsid))
             (quick (harness-tasks-test-submit "Fix a typo"))
             (slow (harness-tasks-test-submit "Write the docs"))
             (ssid (harness-tasks-test-session-id slow)))
        (harness-tasks-test-wait-state quick 'done)
        (harness-test-wait (lambda () (harness-tasks-test--running-p ssid)) 5 "the next borrower at work")
        (should (equal lender (harness-tasks-test--borrowed-from slow)))
        (harness-call 'session/pending-resolve lsid pid "go on")
        (harness-test-wait (lambda () (eq 'pending (harness-tasks-test-state slow))) 5 "the borrower stopped")
        (let ((back (harness-tasks-test-task slow)))
          (should (eq 'reclaimed (plist-get back :return-reason)))
          (should (equal lender (plist-get back :preempted-by))))
        (should (eq 'done (harness-tasks-test-state quick)))
        (should (eq 'active (harness-tasks-test-state lender)))
        (setq harness-tasks-test--slow nil)
        (harness-call 'task/cancel lender)
        (harness-tasks-test-wait-state slow 'done)
        (should (harness-tasks-test--said ssid harness-tasks--reclaimed-message))))))

(ert-deftest harness-tasks-work-sent-back-borrows-a-lent-slot ()
  "Work sent back from review takes a lent slot like a free one, and borrows it.
The lender's answer then takes the slot back from it as from any
borrower: it waits in the queue, its feedback still to finish, and
carries on once the slot frees."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let* ((harness-tasks-test--slow (list "Ask about the parser"))
           (harness-agent--cancel-grace 0.05)
           (harness-tasks-max-running 1)
           (harness-tasks-require-verification t)
           (harness-tasks-lend-blocked-slot-after 0.3)
           (harness-provider-demo-script-override #'harness-tasks-test--slow-script)
           (reviewed (harness-tasks-test-submit "Fix the parser")))
      (harness-tasks-test-wait-state reviewed 'review)
      (let* ((lender (harness-tasks-test-submit "Ask about the parser"))
             (lsid (harness-tasks-test-session-id lender)))
        (harness-test-wait (lambda () (harness-tasks-test--running-p lsid)) 5 "the other task at work")
        (let ((pid (harness-tasks-test--block lsid)))
          (harness-test-wait (lambda () (harness-tasks--lending-p (harness-tasks-test-task lender))) 5
                             "the slot lent")
          (push "Fix the parser" harness-tasks-test--slow)
          (harness-call 'task/reject reviewed "handle tabs too")
          (should (eq 'active (harness-tasks-test-state reviewed)))
          (should (equal lender (harness-tasks-test--borrowed-from reviewed)))
          (harness-call 'session/pending-resolve lsid pid "go on")
          (harness-test-wait (lambda () (eq 'pending (harness-tasks-test-state reviewed))) 5 "the slot taken back")
          (let ((back (harness-tasks-test-task reviewed)))
            (should (eq 'reclaimed (plist-get back :return-reason)))
            (should (plist-get back :sent-back)))
          (setq harness-tasks-test--slow nil)
          (harness-call 'task/cancel lender)
          (harness-tasks-test-wait-state reviewed 'review))))))

(ert-deftest harness-tasks-lend-wait-changed-lends-at-once ()
  "Without a wait a blocked task keeps its slot, as before lending.
A wait set through `config/set' then lends the slot of a task blocked
that long at once, not at the next event: the scheduler runs on the
change."
  (harness-tasks-test-with
    (harness-tasks-test--settle)
    (let* ((harness-tasks-test--slow (list "Ask about the parser" "Write the docs"))
           (harness-agent--cancel-grace 0.05)
           (harness-tasks-max-running 1)
           (harness-tasks-lend-blocked-slot-after nil)
           (harness-provider-demo-script-override #'harness-tasks-test--slow-script)
           (lender (harness-tasks-test-submit "Ask about the parser"))
           (lsid (harness-tasks-test-session-id lender)))
      (cl-letf (((symbol-function 'harness-save-user-option) (lambda (symbol value) (set symbol value))))
        (harness-test-wait (lambda () (harness-tasks-test--running-p lsid)) 5 "the first task at work")
        (harness-tasks-test--block lsid)
        (let ((next (harness-tasks-test-submit "Write the docs")))
          ;; However long it waits on the user, it keeps its slot.
          (accept-process-output nil 0.3)
          (harness-tasks--schedule)
          (should (eq 'pending (harness-tasks-test-state next)))
          (should (harness-tasks--holds-slot-p (harness-tasks-test-task lender)))
          (should-not (gethash lender harness-tasks--lend-timers))
          (harness-call 'config/set "harness-tasks-lend-blocked-slot-after" "0.1" :printed t :scope 'global)
          (harness-test-wait (lambda () (eq 'active (harness-tasks-test-state next))) 5 "the next task to start")
          (should (equal lender (harness-tasks-test--borrowed-from next)))
          (harness-call 'task/cancel next)
          (harness-call 'task/cancel lender))))))

(provide 'harness-tasks-test)
;;; harness-tasks-test.el ends here
