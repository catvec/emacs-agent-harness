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

(ert-deftest harness-tasks-git-uncommitted-work-is-steered ()
  (harness-tasks-test-with-git
    ;; The first call edits without committing; the merge queue tells the
    ;; agent to commit, and its next turn commits and merges.
    (let ((harness-tasks-test--commit-on-call 2))
      (let ((id (harness-tasks-test-submit "Change the shared file")))
        (harness-tasks-test-wait-state id 'done)
        (should (= 2 harness-tasks-test--calls))
        (should (equal "two\n" (harness-tasks-test--main-text root)))))))

(provide 'harness-tasks-test)
;;; harness-tasks-test.el ends here
