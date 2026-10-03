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
(defvar harness-tasks--loaded)
(defvar harness-tasks--dirty)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-permission-mode)
(defvar harness-tasks-non-interactive)
(defvar harness-tasks-model)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(declare-function harness-tasks--save "harness-tasks")
(declare-function harness-tasks--forget-stores "harness-tasks")
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
       (dolist (m '(store project config provider provider-demo tools session agent tasks acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-tasks--table)
     (clrhash harness-tasks--starting)
     (harness-tasks--forget-stores)
     ;; Nothing of an earlier test waits to be written over this one's files.
     (setq harness-tasks--loaded t
           harness-tasks--dirty nil
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
(defun harness-tasks-test-default (option)
  "Return the default value of OPTION, which the tests' setup may have bound."
  (eval (car (get option 'standard-value)) t))
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

(ert-deftest harness-tasks-set-all-updates-current-tasks ()
  "task/set-all changes a pending task's record and a started task's session."
  (harness-tasks-test-with
    (let ((harness-provider-demo--delay 5)          ; keep the started one running
          (harness-tasks-max-running 0))
      (let* ((running (harness-tasks-test-submit "running"))
             (waiting (harness-tasks-test-submit "waiting")))
        (harness-call 'task/start running)
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task running) :session))
                           5 "the started task's session")
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
          (should (string-match-p "^> the parser chokes on nested quotes$" (cadr texts))))
        ;; The request is the user's; the harness composed the start message.
        (pcase-let ((`(,request ,start) (harness-tasks-test-user-nodes sid)))
          (should-not (harness-node-sender request))
          (should (equal (harness-sender-system "tasks") (harness-node-sender start))))))))

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
      (should (member (concat harness-naming--base-system-prompt "\n\n" harness-tasks--naming-instructions) systems)))))

;;;; Git: worktree, merge queue, done only when merged

(defvar harness-merge--queues)
(defvar harness-merge--locks)
(defvar harness-merge--holds)
(defvar harness-tasks-worktrees)
(defvar harness-tasks--merge-session-name)

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
      (should (cl-find harness-tasks--merge-session-name (harness-call 'session/list)
                       :key (lambda (s) (plist-get s :name)) :test #'equal))
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
With nil it starts at the level the project configures instead."
  (harness-tasks-test-with
    ;; Not a task: the project's usual model, whose levels the demo
    ;; catalogue lists (low and high).
    (let ((harness-model "demo:scripted") (harness-thinking "high") (harness-btw-thinking "low"))
      (should (equal "low" (plist-get (harness-call 'task/btw default-directory) :thinking)))
      (let ((harness-btw-thinking nil))
        (should (equal "high" (plist-get (harness-call 'task/btw default-directory) :thinking)))))))

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
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :worktree-removed)) 10 "worktree removal")
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
        (harness-test-wait (lambda () (plist-get (harness-tasks-test-task id) :worktree-removed)) 10 "worktree removal")
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

;;;; Handing the finished work in
;;
;; `hand_in' is how a task's session says it is done: the tool records
;; the summary and the evidence on the task and ends the turn, which the
;; review step then picks up as usual.

(defvar harness-tasks-test--handin-evidence nil
  "Evidence the test's hand_in call hands in, when not the default.")

(defun harness-tasks-test--handin-input ()
  "Return the input of the test's hand_in call."
  (list :summary "# Done\n\nThe parser handles nested quotes now."
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
             (:type tool-call :id "h1" :name "hand_in" :input (:summary "# Done" :evidence ("looks good")))
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
          (should (equal "# Done" (plist-get report :summary)))
          (should (numberp (plist-get report :at)))
          (should (equal '((:kind "note" :text "looks good")) (plist-get report :evidence))))
        ;; The transcript shows the call and what it said.
        (let ((result (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                                                   (equal (plist-get n :call-id) "h1")))
                                  (harness-call 'session/nodes sid))))
          (should (string-match-p "waits for the user's review" (plist-get result :output))))
        ;; The user can verify it as any review.
        (harness-call 'task/verify id)
        (harness-tasks-test-wait-state id 'done)
        (should (plist-get (harness-tasks-test-task id) :verified))))))

(ert-deftest harness-tasks-hand-in-needs-a-report ()
  "A hand_in without a summary, without evidence, or with broken items is refused.
The refusal says what to fix, and the task keeps working."
  (harness-tasks-test-with
    (harness-test-load-module 'tools-handin)
    (let* ((id (harness-tasks-test-submit "fix the parser"))
           (sid (plist-get (harness-tasks-test-task id) :session)))
      (dolist (case '((:summary "" :evidence ("x"))
                      (:summary "done" :evidence nil)
                      (:summary "done" :evidence (1))
                      (:summary "done" :evidence ((:image "/no/such/file.png")))
                      (:summary "done" :evidence ((:image "shared.txt")))
                      (:summary "done" :evidence ((:tool_call "nope")))
                      (:summary "done" :evidence ((:code "x" :note "y")))))
        (let* ((input (pcase case
                        (`(:evidence (1)) (list :summary "done" :evidence (list (list :note "x" :caption 7))))
                        (`(:evidence nil) (list :summary "done" :evidence nil))
                        (`(:evidence ((:image ,p))) (list :summary "done" :evidence (list (list :image p))))
                        (`(:evidence ((:tool_call ,c))) (list :summary "done" :evidence (list (list :tool_call c))))
                        (`(:evidence ((:code "x" :note "y"))) (list :summary "done" :evidence (list (list :code "x" :note "y"))))
                        (`(:summary "" :evidence _) (list :summary "" :evidence (list "x")))
                        (`(:summary "done" :evidence _) (list :summary "done" :evidence (list "x")))))
              (result (harness-test-await (harness-call-async 'tools/execute sid (list :id "bad" :name "hand_in" :input input)))))
          (should (plist-get result :is-error))
          (should-not (plist-get result :end-turn))))
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
                     :input (:summary "Done" :evidence ((:tool_call "c1" :caption "the command"))))
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

(provide 'harness-tasks-test)
;;; harness-tasks-test.el ends here
