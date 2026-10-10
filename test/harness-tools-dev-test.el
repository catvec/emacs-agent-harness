;;; harness-tools-dev-test.el --- Tests for the open_harness tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; The tool and method that run a checkout's harness in an Emacs of its
;; own (harness-tools-dev.el), and the lifetimes of those Emacsen.  A
;; fake scripts/dev.sh in a temp checkout records what the launcher ran,
;; and stand-in sessions and tasks say who needs an instance, so no
;; Emacs is started here but by the one test that stops a real daemon.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-tools)

(defvar harness-tools-dev--check-timer)

(defmacro harness-tools-dev-test-with (&rest body)
  "Load the tools registry and tools-dev on a fresh bus; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(tools tools-dev))
       (harness-test-load-module m))
     ,@body))

;;;; A stand-in world of sessions and tasks

(defvar harness-tools-dev-test--sessions nil
  "The stand-in sessions, an alist of id -> plist.")

(defvar harness-tools-dev-test--tasks nil
  "The stand-in tasks, plists.")

(defvar harness-tools-dev-test--asked nil
  "The sockets of the instances asked to exit, newest first.")

(defun harness-tools-dev-test--task (id)
  "Return stand-in task ID, or nil."
  (cl-find id harness-tools-dev-test--tasks :key (lambda (task) (plist-get task :id)) :test #'equal))

(defun harness-tools-dev-test--world ()
  "Stand in for the session and task modules, from the variables above."
  (harness-register-method 'session/exists-p
                           (lambda (id) (and (assoc id harness-tools-dev-test--sessions) t)))
  (harness-register-method 'session/get
                           (lambda (id) (or (cdr (assoc id harness-tools-dev-test--sessions))
                                            (error "No session %s" id))))
  (harness-register-method 'session/list
                           (lambda (&optional filter)
                             (cl-remove-if (lambda (s) (and (plist-get filter :active)
                                                            (eq (plist-get s :status) 'inactive)))
                                           (mapcar #'cdr harness-tools-dev-test--sessions))))
  (harness-register-method 'task/list (lambda (&optional _cwd) harness-tools-dev-test--tasks))
  (harness-register-method 'task/get
                           (lambda (id) (or (harness-tools-dev-test--task id) (error "No task %s" id))))
  (harness-register-method 'task/for-session
                           (lambda (sid) (cl-find sid harness-tools-dev-test--tasks
                                                  :key (lambda (task) (plist-get task :session))
                                                  :test #'equal))))

(defun harness-tools-dev-test--session (id &rest plist)
  "Make stand-in session ID, or change it, with PLIST.
A new one is idle, of kind main and just active, unless PLIST says otherwise."
  (let ((cell (assoc id harness-tools-dev-test--sessions)))
    (if cell
        (setcdr cell (harness-plist-merge (cdr cell) plist))
      (push (cons id (harness-plist-merge (list :id id :status 'idle :kind 'main :updated (float-time))
                                          plist))
            harness-tools-dev-test--sessions))))

(defun harness-tools-dev-test--set-task (id &rest plist)
  "Make stand-in task ID, or change it, with PLIST.
A new one is active, unless PLIST says otherwise."
  (let ((task (harness-tools-dev-test--task id)))
    (setq harness-tools-dev-test--tasks
          (cons (harness-plist-merge (or task (list :id id :state 'active)) plist)
                (remove task harness-tools-dev-test--tasks)))))

(defmacro harness-tools-dev-test-world (&rest body)
  "Run BODY with tools-dev over stand-in sessions and tasks.
No instance is asked to exit for real: `harness-tools-dev-test--asked'
collects the sockets that are."
  (declare (indent 0))
  `(harness-tools-dev-test-with
     (let ((harness-tools-dev-test--sessions nil)
           (harness-tools-dev-test--tasks nil)
           (harness-tools-dev-test--asked nil))
       (harness-tools-dev-test--world)
       (when (timerp harness-tools-dev--check-timer) (cancel-timer harness-tools-dev--check-timer))
       (setq harness-tools-dev--check-timer nil)
       (cl-letf (((symbol-function 'harness-tools-dev--ask-to-exit)
                  (lambda (socket) (push socket harness-tools-dev-test--asked) (harness-resolved nil))))
         (unwind-protect (progn ,@body)
           (when (timerp harness-tools-dev--check-timer) (cancel-timer harness-tools-dev--check-timer))
           (setq harness-tools-dev--check-timer nil))))))

(defun harness-tools-dev-test--open (dir sid &optional focus)
  "Open DIR's harness with the tool, as session SID's agent; return the result."
  (harness-test-await (harness-tools-dev--open (list :path dir :focus (if focus t :false))
                                               (list :session-id sid :cwd dir))))

(defun harness-tools-dev-test--check ()
  "Run the check; return the sockets it stopped, sorted."
  (sort (harness-test-await (harness-tools-dev--check)) #'string<))

(defun harness-tools-dev-test--sockets (&rest dirs)
  "Return the sockets of DIRS, sorted."
  (sort (mapcar #'harness-tools-dev-socket dirs) #'string<))

(ert-deftest harness-tools-dev-socket-is-stable-and-distinct ()
  "A checkout always opens under the same socket, another under another."
  (harness-tools-dev-test-with
    (let ((a (harness-test-harness-checkout))
          (b (harness-test-harness-checkout)))
      (should (string-prefix-p "harness-dev-" (harness-tools-dev-socket a)))
      (should (equal (harness-tools-dev-socket a) (harness-tools-dev-socket a)))
      (should-not (equal (harness-tools-dev-socket a) (harness-tools-dev-socket b)))
      (should (string-prefix-p (expand-file-name "scripts/.dev/" a)
                               (harness-tools-dev-state a (harness-tools-dev-socket a)))))))

(ert-deftest harness-tools-dev-checkout-detection ()
  "A checkout is harness.el and scripts/dev.sh side by side."
  (harness-tools-dev-test-with
    (let ((dir (harness-test-harness-checkout))
          (plain (harness-test-temp-dir)))
      (should (harness-tools-dev-checkout-p dir))
      (should (harness-tools-dev-checkout-p harness-test-root))
      (should-not (harness-tools-dev-checkout-p plain))
      (should-not (harness-tools-dev-checkout-p nil))
      (delete-file (expand-file-name "scripts/dev.sh" dir))
      (should-not (harness-tools-dev-checkout-p dir)))))

(ert-deftest harness-tools-dev-tool-is-for-this-project-only ()
  "The tool is offered in a harness checkout, and nowhere else."
  (harness-tools-dev-test-with
    (let* ((dir (harness-test-harness-checkout))
           (here (list :cwd dir))
           (elsewhere (list :cwd (harness-test-temp-dir)))
           (names (list "open_harness" "bash")))
      (should (equal '("open_harness" "bash") (harness-tools-dev--tools names here)))
      (should (equal '("bash") (harness-tools-dev--tools names elsewhere)))
      ;; The catalogue (no session) keeps it.
      (should (equal '("open_harness" "bash") (harness-tools-dev--tools names nil)))
      ;; The real filter chain `tools/list' runs.
      (should (member "open_harness" (harness-run-filter 'agent/tools names here)))
      (should-not (member "open_harness" (harness-run-filter 'agent/tools names elsewhere)))
      ;; A task worktree counts through the session's :worktree too.
      (let ((worktree (list :cwd (harness-test-temp-dir) :worktree dir)))
        (should (member "open_harness" (harness-run-filter 'agent/tools names worktree)))))))

(ert-deftest harness-tools-dev-tool-runs-the-live-loop ()
  "The tool runs the checkout's scripts/dev.sh with its own socket."
  (harness-tools-dev-test-with
    (let* ((dir (harness-test-harness-checkout))
           (result (harness-test-await (harness-tools-dev--open nil (list :cwd dir)))))
      (should-not (plist-get result :is-error))
      (should (string-match-p (regexp-quote (harness-tools-dev-socket dir))
                              (plist-get result :content)))
      (let ((calls (harness-test-dev-invocations dir)))
        (should (= 1 (length calls)))
        (should (file-equal-p dir (cdr (assoc "cwd" (car calls)))))
        (should (equal "start" (cdr (assoc "args" (car calls)))))
        (should (equal (harness-tools-dev-socket dir) (cdr (assoc "socket" (car calls)))))
        ;; The instance knows which process to outlive no longer.
        (should (equal (number-to-string (emacs-pid)) (cdr (assoc "owner" (car calls)))))))))

(ert-deftest harness-tools-dev-tool-refuses-other-directories ()
  "A path that is not a harness checkout is an error, before anything runs."
  (harness-tools-dev-test-with
    (let ((plain (harness-test-temp-dir)))
      (let ((result (harness-tools-dev--open (list :path plain) (list :cwd plain))))
        (should (plist-get result :is-error))
        (should (string-match-p "not a checkout" (plist-get result :content)))
        (should-not (file-exists-p (expand-file-name "invocation.log" plain)))))))

(ert-deftest harness-tools-dev-method-opens-a-checkout ()
  "The board's method starts the checkout and returns its info."
  (harness-tools-dev-test-with
    (let* ((dir (harness-test-harness-checkout))
           (info (harness-test-await (harness-call 'harness-dev/open dir))))
      (should (equal dir (plist-get info :path)))
      (should (equal (harness-tools-dev-socket dir) (plist-get info :socket)))
      (should-not (plist-get info :focused))
      (should (= 1 (length (harness-test-dev-invocations dir)))))))

(ert-deftest harness-tools-dev-method-focuses-the-frame ()
  "With focus the instance's frame is raised through its own dev loop."
  (harness-tools-dev-test-with
    (let* ((dir (harness-test-harness-checkout))
           (info (harness-test-await (harness-call 'harness-dev/open dir t))))
      (should (plist-get info :focused))
      (let ((calls (harness-test-dev-invocations dir)))
        (should (= 2 (length calls)))
        (should (equal "start" (cdr (assoc "args" (car calls)))))
        (should (equal "eval (harness-dev-focus)" (cdr (assoc "args" (cadr calls)))))))))

;;;; Lifetimes

(ert-deftest harness-tools-dev-task-instance-stops-with-the-task ()
  "The instance a task's agent opened stops once the task stops working."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir)))
      (harness-tools-dev-test--session "s1" :worktree dir :cwd dir :status 'running)
      (harness-tools-dev-test--set-task "t1" :session "s1" :worktree dir)
      (let ((result (harness-tools-dev-test--open dir "s1")))
        (should-not (plist-get result :is-error))
        ;; The agent hears when it stops.
        (should (string-match-p "stops by itself once this task stops working"
                                (plist-get result :content))))
      (should (equal '("s1") (plist-get (harness-tools-dev--find socket) :sessions)))
      (should (file-exists-p (harness-tools-dev--registry-path)))
      ;; While the task works, between turns too, it stays.
      (should-not (harness-tools-dev-test--check))
      (harness-tools-dev-test--session "s1" :status 'idle)
      (should-not (harness-tools-dev-test--check))
      ;; In review, it goes.
      (harness-tools-dev-test--set-task "t1" :state 'review)
      (should (equal (list socket) (harness-tools-dev-test--check)))
      (should (equal (list socket) harness-tools-dev-test--asked))
      (should-not (harness-tools-dev--find socket))
      ;; Forgotten on disk too.
      (setq harness-tools-dev--instances-dir nil)
      (should-not (harness-tools-dev--instances))
      ;; Stopping ran nothing of the checkout's: its dev loop only started it.
      (should (equal '("start") (mapcar (lambda (call) (cdr (assoc "args" call)))
                                        (harness-test-dev-invocations dir)))))))

(ert-deftest harness-tools-dev-task-instance-stops-when-the-task-stops ()
  "A task stopped by an error or a cancel no longer needs its instance."
  (harness-tools-dev-test-world
    (let ((dir (harness-test-harness-checkout)))
      (harness-tools-dev-test--session "s1" :worktree dir :status 'running)
      (harness-tools-dev-test--set-task "t1" :session "s1" :worktree dir)
      (harness-tools-dev-test--open dir "s1")
      (harness-tools-dev-test--session "s1" :status 'idle)
      (harness-tools-dev-test--set-task "t1" :outcome 'cancelled)
      (should (equal (harness-tools-dev-test--sockets dir) (harness-tools-dev-test--check))))))

(ert-deftest harness-tools-dev-focused-instance-stays-until-the-task-is-done ()
  "An instance opened for the user to look at stays through review and merge."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir)))
      (harness-tools-dev-test--session "s1" :worktree dir :status 'running)
      (harness-tools-dev-test--set-task "t1" :session "s1" :worktree dir)
      (should (string-match-p "stays until the task is done"
                              (plist-get (harness-tools-dev-test--open dir "s1" t) :content)))
      (let ((entry (harness-tools-dev--find socket)))
        (should (plist-get entry :user))
        (should (equal "t1" (plist-get entry :task))))
      (harness-tools-dev-test--session "s1" :status 'idle)
      (dolist (state '(review merging))
        (harness-tools-dev-test--set-task "t1" :state state)
        (should-not (harness-tools-dev-test--check)))
      (harness-tools-dev-test--set-task "t1" :state 'done)
      (should (equal (list socket) (harness-tools-dev-test--check))))))

(ert-deftest harness-tools-dev-board-instance-stays-until-the-task-goes ()
  "The board's Open harness lasts until its task is done, archived or deleted."
  (harness-tools-dev-test-world
    (let ((a (harness-test-harness-checkout))
          (b (harness-test-harness-checkout)))
      (harness-tools-dev-test--set-task "ta" :state 'review :worktree a)
      (harness-tools-dev-test--set-task "tb" :state 'review :worktree b)
      (harness-test-await (harness-call 'harness-dev/open a t))
      (harness-test-await (harness-call 'harness-dev/open b t))
      (should (equal "ta" (plist-get (harness-tools-dev--find (harness-tools-dev-socket a)) :task)))
      (should-not (harness-tools-dev-test--check))
      (harness-tools-dev-test--set-task "ta" :archived t)
      (should (equal (harness-tools-dev-test--sockets a) (harness-tools-dev-test--check)))
      (setq harness-tools-dev-test--tasks (remove (harness-tools-dev-test--task "tb")
                                                  harness-tools-dev-test--tasks))
      (should (equal (harness-tools-dev-test--sockets b) (harness-tools-dev-test--check))))))

(ert-deftest harness-tools-dev-subagent-instance-stops-with-its-work ()
  "A sub-agent's instance goes with its work, unless its task works in the same checkout."
  (harness-tools-dev-test-world
    (let ((own (harness-test-harness-checkout))
          (shared (harness-test-harness-checkout)))
      (harness-tools-dev-test--session "parent" :worktree shared :status 'running)
      (harness-tools-dev-test--set-task "t1" :session "parent" :worktree shared)
      ;; One sub-agent in a worktree of its own, one in its task's.
      (harness-tools-dev-test--session "c1" :kind 'subagent :parent-id "parent"
                                       :worktree own :cwd own :status 'running)
      (harness-tools-dev-test--session "c2" :kind 'subagent :parent-id "parent"
                                       :cwd shared :status 'running)
      (should (string-match-p "once your work is done"
                              (plist-get (harness-tools-dev-test--open own "c1") :content)))
      (harness-tools-dev-test--open shared "c2")
      (should-not (harness-tools-dev-test--check))
      (harness-tools-dev-test--session "c1" :status 'idle)
      (harness-tools-dev-test--session "c2" :status 'idle)
      (should (equal (harness-tools-dev-test--sockets own) (harness-tools-dev-test--check)))
      ;; The task still works in the shared checkout, between its turns too.
      (harness-tools-dev-test--session "parent" :status 'idle)
      (should-not (harness-tools-dev-test--check))
      (harness-tools-dev-test--set-task "t1" :state 'done)
      (should (equal (harness-tools-dev-test--sockets shared) (harness-tools-dev-test--check))))))

(ert-deftest harness-tools-dev-conversation-instance-stays-while-it-goes-on ()
  "A conversation's instance stays until it is closed or long idle."
  (harness-tools-dev-test-world
    (let ((a (harness-test-harness-checkout))
          (b (harness-test-harness-checkout)))
      (harness-tools-dev-test--session "talk" :cwd a :status 'running)
      (harness-tools-dev-test--session "other" :cwd b :status 'running)
      (should (string-match-p "once this session is closed"
                              (plist-get (harness-tools-dev-test--open a "talk") :content)))
      (harness-tools-dev-test--open b "other")
      (harness-tools-dev-test--session "talk" :status 'idle)
      (harness-tools-dev-test--session "other" :status 'idle)
      (should-not (harness-tools-dev-test--check))
      (harness-tools-dev-test--session "talk" :status 'inactive)
      (harness-tools-dev-test--session "other" :updated (- (float-time) harness-tools-dev--idle-timeout 1))
      (should (equal (harness-tools-dev-test--sockets a b) (harness-tools-dev-test--check))))))

(ert-deftest harness-tools-dev-instance-of-a-removed-checkout-stops ()
  "An instance whose checkout is gone stops, needed or not."
  (harness-tools-dev-test-world
    (let* ((dir (harness-test-harness-checkout))
           (socket (harness-tools-dev-socket dir)))
      (harness-tools-dev-test--session "talk" :cwd dir :status 'running)
      (harness-tools-dev-test--open dir "talk")
      (delete-directory dir t)
      (should (equal (list socket) (harness-tools-dev-test--check))))))

(ert-deftest harness-tools-dev-events-start-the-check ()
  "A task going to review stops its agent's instance a moment later."
  (harness-tools-dev-test-world
    (let ((dir (harness-test-harness-checkout))
          (stopped nil))
      (harness-on 'harness-dev/stopped (lambda (socket path reason) (push (list socket path reason) stopped)))
      (harness-tools-dev-test--session "s1" :worktree dir :status 'running)
      (harness-tools-dev-test--set-task "t1" :session "s1" :worktree dir)
      (harness-tools-dev-test--open dir "s1")
      (harness-tools-dev-test--session "s1" :status 'idle)
      (harness-tools-dev-test--set-task "t1" :state 'review)
      (harness-emit 'task/review (harness-tools-dev-test--task "t1"))
      (harness-test-wait (lambda () stopped) 10 "the instance to stop")
      (should (equal (list (list (harness-tools-dev-socket dir) dir
                                 "the sessions that opened it are done with it"))
                     stopped)))))

(ert-deftest harness-tools-dev-sweep-finds-unrecorded-instances ()
  "The sweep takes on the instances of this harness's worktrees, and no others."
  (harness-tools-dev-test-world
    (let* ((done (harness-test-harness-checkout))
           (working (harness-test-harness-checkout))
           (stranger (harness-test-harness-checkout))
           (gone (harness-test-harness-checkout))
           (exited (harness-test-harness-checkout))
           (running (mapcar (lambda (dir) (list :socket (harness-tools-dev-socket dir) :path dir :pid 0))
                            (list done working stranger gone)))
           ;; An instance asked to exit does.
           (harness-tools-dev--processes-function
            (lambda () (cl-remove-if (lambda (daemon)
                                       (member (plist-get daemon :socket) harness-tools-dev-test--asked))
                                     running))))
      (delete-directory gone t)
      (harness-tools-dev-test--set-task "t-done" :state 'done :worktree done)
      (harness-tools-dev-test--set-task "t-working" :session "s" :worktree working)
      (harness-tools-dev-test--session "s" :worktree working :status 'running)
      ;; One recorded once, which has exited since.
      (harness-tools-dev-test--session "talk" :cwd exited :status 'running)
      (harness-tools-dev-test--open exited "talk")
      (should (equal (harness-tools-dev-test--sockets done gone)
                     (sort (harness-test-await (harness-call 'harness-dev/sweep)) #'string<)))
      (should (plist-get (harness-tools-dev--find (harness-tools-dev-socket working)) :adopted))
      (should-not (harness-tools-dev--find (harness-tools-dev-socket stranger)))
      (should-not (member (harness-tools-dev-socket stranger) harness-tools-dev-test--asked))
      (should-not (harness-tools-dev--find (harness-tools-dev-socket exited)))
      (should-not (member (harness-tools-dev-socket exited) harness-tools-dev-test--asked))
      ;; What is left is what something needs.
      (should (equal (list (list (harness-tools-dev-socket working) t))
                     (mapcar (lambda (entry) (list (plist-get entry :socket) (plist-get entry :needed)))
                             (harness-call 'harness-dev/instances))))
      ;; Once its task is done, the next sweep stops it too.
      (harness-tools-dev-test--session "s" :status 'idle)
      (harness-tools-dev-test--set-task "t-working" :state 'done)
      (should (equal (harness-tools-dev-test--sockets working)
                     (harness-test-await (harness-call 'harness-dev/sweep)))))))

(ert-deftest harness-tools-dev-worktree-instance-stops-before-removal ()
  "The instance of a worktree stops before the worktree is removed."
  (harness-tools-dev-test-world
    (let ((dir (harness-test-harness-checkout))
          (other (harness-test-harness-checkout)))
      (harness-tools-dev-test--session "talk" :cwd dir :status 'running)
      (harness-tools-dev-test--open dir "talk")
      (should (eq 'kept (harness-test-await
                         (harness-run-filter-async 'worktree/before-remove 'kept "/repo/" dir))))
      (should (equal (harness-tools-dev-test--sockets dir) harness-tools-dev-test--asked))
      (should-not (harness-tools-dev--find (harness-tools-dev-socket dir)))
      ;; Where no instance runs, nothing is asked.
      (should (eq 'kept (harness-test-await
                         (harness-run-filter-async 'worktree/before-remove 'kept "/repo/" other))))
      (should (equal (harness-tools-dev-test--sockets dir) harness-tools-dev-test--asked)))))

(ert-deftest harness-tools-dev-start-waits-for-a-stop ()
  "Opening an instance being stopped starts it again once it has stopped."
  (harness-tools-dev-test-world
    (let ((dir (harness-test-harness-checkout))
          (gate (harness-make-promise)))
      (harness-tools-dev-test--session "talk" :cwd dir :status 'running)
      (harness-tools-dev-test--open dir "talk")
      (cl-letf (((symbol-function 'harness-tools-dev--ask-to-exit)
                 (lambda (socket) (push socket harness-tools-dev-test--asked) gate)))
        (let ((stop (harness-call 'harness-dev/stop dir))
              (start (harness-tools-dev--open (list :path dir) (list :session-id "talk" :cwd dir))))
          (harness-test-wait (lambda () harness-tools-dev-test--asked) 5 "the stop to begin")
          (sit-for 0.2)
          ;; The dev loop ran for the first open only.
          (should (= 1 (length (harness-test-dev-invocations dir))))
          (harness-resolve gate nil)
          (should (harness-test-await stop))
          (should-not (plist-get (harness-test-await start) :is-error))
          (should (= 2 (length (harness-test-dev-invocations dir))))
          (should (harness-tools-dev--find (harness-tools-dev-socket dir))))))))

(ert-deftest harness-tools-dev-reads-daemon-command-lines ()
  "An instance is told by the command line scripts/dev.sh gives its daemon."
  (should (equal '(:socket "harness-dev-0123456789ab" :path "/w/a b/")
                 (harness-tools-dev--parse-command
                  "emacs -Q --daemon=harness-dev-0123456789ab -l /w/a b/scripts/harness-dev.el")))
  (should (equal '(:socket "harness-dev-0123456789ab" :path nil)
                 (harness-tools-dev--parse-command "emacs --daemon=harness-dev-0123456789ab")))
  ;; The user's own dev daemon, and anything else, is not one.
  (should-not (harness-tools-dev--parse-command "emacs -Q --daemon=harness-v3 -l /w/scripts/harness-dev.el"))
  (should-not (harness-tools-dev--parse-command "emacs --daemon=harness-dev-xyz"))
  (should-not (harness-tools-dev--parse-command "emacs --batch -l harness-server.el"))
  (should-not (harness-tools-dev--parse-command nil)))

(ert-deftest harness-tools-dev-stops-a-real-daemon ()
  "A daemon started the way scripts/dev.sh starts one is found and stopped."
  (harness-tools-dev-test-with
    (skip-unless (listp (harness-tools-dev-processes)))
    (let* ((dir (harness-test-harness-checkout))
           ;; A temporary checkout's, so no other Emacs runs under it.
           (socket (harness-tools-dev-socket dir))
           (emacs (expand-file-name invocation-name invocation-directory))
           ;; Only the daemon this test starts is ever seen, or stopped.
           (harness-tools-dev--processes-function
            (lambda ()
              (let ((all (harness-tools-dev-processes)))
                (if (listp all)
                    (cl-remove-if-not (lambda (daemon) (equal socket (plist-get daemon :socket))) all)
                  all)))))
      (with-temp-file (expand-file-name "scripts/harness-dev.el" dir)
        (insert ";; A dev loop that loads nothing.\n"))
      (unwind-protect
          (progn
            (call-process emacs nil nil nil "-Q" (concat "--daemon=" socket)
                          "-l" (expand-file-name "scripts/harness-dev.el" dir))
            (let ((found (car (harness-test-wait (lambda () (funcall harness-tools-dev--processes-function))
                                                 10 "the daemon to start"))))
              (should (equal dir (plist-get found :path)))
              (should (integerp (plist-get found :pid))))
            (should (harness-test-await (harness-call 'harness-dev/stop dir) 30))
            (should-not (funcall harness-tools-dev--processes-function)))
        (let ((left (funcall harness-tools-dev--processes-function)))
          (when (listp left)
            (dolist (daemon left) (ignore-errors (signal-process (plist-get daemon :pid) 'kill)))))))))

(provide 'harness-tools-dev-test)
;;; harness-tools-dev-test.el ends here
