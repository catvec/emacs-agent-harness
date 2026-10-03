;;; harness-merge-test.el --- Tests for the merge queue  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)
(defvar harness-merge--queues)
(defvar harness-merge--locks)
(defvar harness-merge--holds)
(defvar harness-merge--hold-timeout)

(defun harness-merge-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure, return stdout."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string)))
      (buffer-string))))

(defun harness-merge-test--write (dir name text)
  "Write TEXT to NAME under DIR."
  (with-temp-file (expand-file-name name dir) (insert text)))

(defun harness-merge-test--commit (dir message &rest files)
  "Stage FILES in DIR and commit them with MESSAGE."
  (apply #'harness-merge-test--git dir "add" files)
  (harness-merge-test--git dir "commit" "-q" "-m" message))

(defun harness-merge-test--make-repo ()
  "Create BASE/repo with one commit; return (BASE . ROOT)."
  (let* ((base (harness-test-temp-dir))
         (root (file-name-as-directory (expand-file-name "repo" base))))
    (make-directory root t)
    (harness-merge-test--git root "init" "-q" "-b" "main")
    (harness-merge-test--git root "config" "user.name" "Harness Test")
    (harness-merge-test--git root "config" "user.email" "test@example.invalid")
    (harness-merge-test--git root "config" "commit.gpgsign" "false")
    (harness-merge-test--write root "README" "hello\n")
    (harness-merge-test--commit root "initial" "README")
    (cons base root)))

(defun harness-merge-test--worktree (base root branch)
  "Add a worktree of ROOT on new BRANCH under BASE; return its path."
  (let ((path (file-name-as-directory (expand-file-name branch base))))
    (harness-merge-test--git root "worktree" "add" "-q" "-b" branch path)
    path))

(defmacro harness-merge-test-with (&rest body)
  "Load the state layer, the demo provider and the merge module; run BODY.
Binds `base', `root' (a git repo), `parent' (a session at ROOT) and
`wt' plus `child' (a worktree on branch child and a session in it)."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent merge))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-merge--queues)
     (clrhash harness-merge--locks)
     (clrhash harness-merge--holds)
     (harness-define-tool "list_dir" :label "List directory" :description "list" :kind 'read
                          :handler (lambda (input _ctx) (format "listing of %s" (plist-get input :path))))
     (harness-add-filter 'permission/decide
                         (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
     (let* ((harness-provider-demo--delay 0.005)
            (default-directory dir)
            (repo (harness-merge-test--make-repo))
            (base (car repo))
            (root (cdr repo))
            (wt (harness-merge-test--worktree base root "child"))
            (parent (plist-get (harness-call 'session/create :cwd root :model "demo:scripted" :name "main") :id))
            (child (plist-get (harness-call 'session/create :cwd wt :worktree wt :parent-id parent
                                            :kind 'fork :model "demo:scripted" :name "fixer")
                              :id)))
       (ignore base root wt parent child)
       (unwind-protect (progn ,@body)
         (ignore-errors (delete-directory base t))))))

(defun harness-merge-test--hints (sid)
  "Return the hint texts of SID in order."
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'hint)) (harness-call 'session/nodes sid))))

(defun harness-merge-test--merge-done (sid)
  "Run the merge_done tool in SID and return its result."
  (harness-test-await (harness-call 'tools/execute sid (list :id (harness-short-id) :name "merge_done" :input nil))))

(ert-deftest harness-merge-enqueue-validates ()
  (harness-merge-test-with
    ;; A child without a worktree is refused.
    (let ((plain (plist-get (harness-call 'session/create :cwd root :model "demo:scripted") :id)))
      (should-error (harness-call 'merge/enqueue plain parent) :type 'harness-error))
    ;; A parent outside any git repository is refused.
    (let ((outside (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id)))
      (should-error (harness-call 'merge/enqueue child outside) :type 'harness-error))
    (should-error (harness-call 'merge/enqueue "nope" parent) :type 'harness-error)
    (should (null (harness-call 'merge/queue parent)))
    (should (null (harness-call 'merge/status child)))))

(ert-deftest harness-merge-fast-path-when-parent-idle ()
  (harness-merge-test-with
    (harness-merge-test--write wt "feature.txt" "new feature\n")
    (harness-merge-test--commit wt "add feature" "feature.txt")
    (let ((events nil))
      (harness-on 'merge/queued (lambda (c p pos) (push (list 'queued c p pos) events)))
      (harness-on 'merge/started (lambda (c p) (push (list 'started c p) events)))
      (harness-on 'merge/finished (lambda (c p s) (push (list 'finished c p s) events)))
      (should (= 1 (harness-call 'merge/enqueue child parent :message "feature")))
      (let ((q (harness-call 'merge/queue parent)))
        (should (= 1 (length q)))
        (should (equal child (plist-get (car q) :child)))
        (should (eq 'queued (plist-get (car q) :status)))
        (should (= 1 (plist-get (car q) :position)))
        (should (numberp (plist-get (car q) :requested))))
      (should (eq 'queued (harness-call 'merge/status child)))
      (harness-test-wait (lambda () (assq 'finished events)) 10 "merge finished")
      (should (equal (list 'finished child parent 'merged) (assq 'finished events)))
      (should (equal (list (list 'queued child parent 1) (list 'started child parent)
                           (list 'finished child parent 'merged))
                     (reverse events)))
      (should (file-exists-p (expand-file-name "feature.txt" root)))
      (should (string-match-p "Merge branch 'child'" (harness-merge-test--git root "log" "-1" "--format=%s")))
      (should (null (harness-call 'merge/queue parent)))
      (should (null (harness-call 'merge/status child)))
      (should (cl-some (lambda (h) (string-match-p "Merge from fixer finished: merged" h)) (harness-merge-test--hints parent)))
      (should (cl-some (lambda (h) (string-match-p "Merge into main finished: merged" h)) (harness-merge-test--hints child)))
      ;; The parent stays usable: a new turn is not held.
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt parent "hello")) :stop-reason))))))

(ert-deftest harness-merge-dirty-child-is-told-to-commit ()
  (harness-merge-test-with
    (harness-merge-test--write wt "feature.txt" "uncommitted\n")
    (let ((finished nil))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () finished) 10 "merge finished")
      (should (equal (list child parent 'failed) (car finished)))
      (should-not (file-exists-p (expand-file-name "feature.txt" root)))
      ;; The child got a steering prompt (it was idle, so it started a turn).
      (harness-test-wait (lambda () (eq 'idle (plist-get (harness-call 'session/get child) :status))) 10 "child idle")
      (let ((users (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes child))))
        (should (= 1 (length users)))
        (should (string-match-p "Commit your changes in the worktree first" (plist-get (car users) :content)))
        ;; From the merge queue, not the user.
        (should (equal (harness-sender-system "merge queue") (harness-node-sender (car users)))))
      (should (cl-some (lambda (h) (string-match-p "commit your changes" h)) (harness-merge-test--hints parent)))
      (should (null (harness-call 'merge/queue parent))))))

(ert-deftest harness-merge-conflict-resolved-with-merge-done ()
  (harness-merge-test-with
    ;; Both sides change the same line.
    (harness-merge-test--write wt "README" "child version\n")
    (harness-merge-test--commit wt "child edit" "README")
    (harness-merge-test--write root "README" "parent version\n")
    (harness-merge-test--commit root "parent edit" "README")
    (let ((conflicts nil) (finished nil) (allowed nil))
      (harness-on 'merge/conflict (lambda (c p files) (push (list c p files) conflicts)))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      ;; A stand-in for the perms module: record the widened jail.
      (harness-register-method 'permission/allow-dir (lambda (sid dir) (push (cons sid dir) allowed) (list dir)))
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () conflicts) 10 "conflict")
      (should (equal (list child parent '("README")) (car conflicts)))
      (should (eq 'conflict (harness-call 'merge/status child)))
      (should (equal (list (cons child root)) allowed))
      (should (null finished))
      ;; The child was steered with the file names and instructions.
      (harness-test-wait (lambda () (cl-find-if (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes child)))
                         10 "child steering node")
      (let ((user (cl-find-if (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes child))))
        (should (string-match-p "- README" (plist-get user :content)))
        (should (string-match-p (regexp-quote root) (plist-get user :content)))
        (should (string-match-p "merge_done" (plist-get user :content)))
        (should (equal (harness-sender-system "merge queue") (harness-node-sender user))))
      (harness-test-wait (lambda () (eq 'idle (plist-get (harness-call 'session/get child) :status))) 10 "child idle")
      ;; The parent is held: a new turn waits for the lock.
      (let ((held (harness-call 'agent/prompt parent "hello while merging")))
        (should-not (harness-promise-settled-p held))
        (accept-process-output nil 0.1)
        (should-not (harness-promise-settled-p held))
        ;; merge_done fails while the conflict remains.
        (let ((r (harness-merge-test--merge-done child)))
          (should (plist-get r :is-error))
          (should (string-match-p "README" (plist-get r :content))))
        ;; Resolve but do not commit: still refused.
        (harness-merge-test--write root "README" "resolved version\n")
        (harness-merge-test--git root "add" "README")
        (let ((r (harness-merge-test--merge-done child)))
          (should (plist-get r :is-error))
          (should (string-match-p "not committed" (plist-get r :content))))
        (harness-merge-test--git root "commit" "-q" "--no-edit")
        (let ((r (harness-merge-test--merge-done child)))
          (should-not (plist-get r :is-error))
          (should (string-match-p "completed" (plist-get r :content))))
        (should (equal (list child parent 'merged) (car finished)))
        (should (null (harness-call 'merge/queue parent)))
        (should (null (gethash parent harness-merge--locks)))
        ;; The held turn now runs.
        (should (eq 'end-turn (plist-get (harness-test-await held) :stop-reason)))
        (should (equal "resolved version\n"
                       (with-temp-buffer (insert-file-contents (expand-file-name "README" root)) (buffer-string))))
        (should (= 2 (length (split-string (harness-merge-test--git root "log" "-1" "--format=%P") " " t))))))))

(ert-deftest harness-merge-pauses-a-running-parent-at-a-step ()
  (harness-merge-test-with
    (harness-merge-test--write wt "feature.txt" "new feature\n")
    (harness-merge-test--commit wt "add feature" "feature.txt")
    (let* ((harness-provider-demo--delay 0.05)
           (finished nil)
           (enqueued nil))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      ;; Queue the merge while the parent is mid-turn, at its tool call.
      (harness-on 'agent/tool-call (lambda (sid _node)
                                     (when (and (equal sid parent) (not enqueued))
                                       (setq enqueued t)
                                       (harness-call 'merge/enqueue child parent))))
      (let ((turn (harness-call 'agent/prompt parent "give me the tour")))
        (should (eq 'end-turn (plist-get (harness-test-await turn 20) :stop-reason))))
      (should enqueued)
      (should (equal (list child parent 'merged) (car finished)))
      (should (file-exists-p (expand-file-name "feature.txt" root)))
      ;; Order: tool result, pause hint, finished hint, then the model's next step.
      (let* ((nodes (harness-call 'session/nodes parent))
             (kinds (mapcar (lambda (n) (plist-get n :kind)) nodes))
             (pos (lambda (pred) (cl-position-if pred nodes)))
             (result-pos (funcall pos (lambda (n) (eq (plist-get n :kind) 'tool-result))))
             (pause-pos (funcall pos (lambda (n) (and (eq (plist-get n :kind) 'hint)
                                                      (string-match-p "Pausing for merge from fixer" (plist-get n :content))))))
             (done-pos (funcall pos (lambda (n) (and (eq (plist-get n :kind) 'hint)
                                                     (string-match-p "Merge from fixer finished: merged" (plist-get n :content))))))
             (final-pos (cl-position 'assistant kinds :from-end t)))
        (should (and result-pos pause-pos done-pos final-pos))
        (should (< result-pos pause-pos done-pos final-pos))
        (should (string-match-p "# Tour" (plist-get (nth final-pos nodes) :content))))
      (should (null (gethash parent harness-merge--holds)))
      (should (eq 'idle (plist-get (harness-call 'session/get parent) :status))))))

(ert-deftest harness-merge-queue-serves-children-in-order-and-cancel ()
  (harness-merge-test-with
    (let* ((wt2 (harness-merge-test--worktree base root "second"))
           (child2 (plist-get (harness-call 'session/create :cwd wt2 :worktree wt2 :parent-id parent
                                            :kind 'fork :model "demo:scripted" :name "second")
                              :id))
           (wt3 (harness-merge-test--worktree base root "third"))
           (child3 (plist-get (harness-call 'session/create :cwd wt3 :worktree wt3 :parent-id parent
                                            :kind 'fork :model "demo:scripted" :name "third")
                              :id))
           (finished nil))
      (harness-merge-test--write wt "one.txt" "1\n") (harness-merge-test--commit wt "one" "one.txt")
      (harness-merge-test--write wt2 "two.txt" "2\n") (harness-merge-test--commit wt2 "two" "two.txt")
      (harness-merge-test--write wt3 "three.txt" "3\n") (harness-merge-test--commit wt3 "three" "three.txt")
      (harness-on 'merge/finished (lambda (c _p s) (push (cons c s) finished)))
      ;; Hold the parent so the queue builds up.
      (puthash parent "someone" harness-merge--locks)
      (should (= 1 (harness-call 'merge/enqueue child parent)))
      (should (= 2 (harness-call 'merge/enqueue child2 parent)))
      (should (= 3 (harness-call 'merge/enqueue child3 parent)))
      (should-error (harness-call 'merge/enqueue child parent) :type 'harness-error)
      (should (equal (list child child2 child3) (mapcar (lambda (e) (plist-get e :child)) (harness-call 'merge/queue parent))))
      (should (harness-call 'merge/cancel child2))
      (should-not (harness-call 'merge/cancel child2))
      (should (equal (list child child3) (mapcar (lambda (e) (plist-get e :child)) (harness-call 'merge/queue parent))))
      (should (equal '(1 2) (mapcar (lambda (e) (plist-get e :position)) (harness-call 'merge/queue parent))))
      (remhash parent harness-merge--locks)
      (harness-run-soon #'harness-merge--pump parent)
      (harness-test-wait (lambda () (= 3 (length finished))) 15 "all merges")
      (should (equal (list (cons child2 'cancelled) (cons child 'merged) (cons child3 'merged)) (reverse finished)))
      (should (file-exists-p (expand-file-name "one.txt" root)))
      (should-not (file-exists-p (expand-file-name "two.txt" root)))
      (should (file-exists-p (expand-file-name "three.txt" root)))
      (should (null (harness-call 'merge/queue parent))))))

(ert-deftest harness-merge-hold-timeout-aborts ()
  (harness-merge-test-with
    (harness-merge-test--write wt "README" "child version\n")
    (harness-merge-test--commit wt "child edit" "README")
    (harness-merge-test--write root "README" "parent version\n")
    (harness-merge-test--commit root "parent edit" "README")
    (let ((harness-merge--hold-timeout 0.2) (finished nil))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () finished) 10 "aborted")
      (should (equal (list child parent 'aborted) (car finished)))
      (should (string-empty-p (harness-merge-test--git root "diff" "--name-only" "--diff-filter=U")))
      (should (equal "parent version\n"
                     (with-temp-buffer (insert-file-contents (expand-file-name "README" root)) (buffer-string))))
      (should (null (gethash parent harness-merge--locks))))))

(defun harness-merge-test--lock-line (root path)
  "Return the `locked' line `git worktree list --porcelain' gives PATH of ROOT, or nil."
  (let ((dir (file-name-as-directory (file-truename path))))
    (cl-some (lambda (block)
               (let ((lines (split-string block "\n" t)))
                 (and (equal dir (file-name-as-directory (file-truename (substring (car lines) 9))))
                      (seq-find (lambda (l) (string-prefix-p "locked" l)) lines))))
             (split-string (harness-merge-test--git root "worktree" "list" "--porcelain") "\n\n" t))))

(ert-deftest harness-merge-unlocks-the-merged-worktree ()
  "Once its branch is merged, a child's worktree loses the harness's lock; until then it keeps it."
  (harness-merge-test-with
    (harness-test-load-module 'worktree)
    (harness-merge-test--git root "worktree" "lock" "--reason" "harness: child" wt)
    (let ((finished nil))
      (harness-on 'merge/finished (lambda (c _p s) (push (cons c s) finished)))
      ;; A merge that fails leaves the lock on.
      (harness-merge-test--write wt "feature.txt" "new feature\n")
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () finished) 10 "the failed merge")
      (should (equal (cons child 'failed) (car finished)))
      (should (equal "locked harness: child" (harness-merge-test--lock-line root wt)))
      (harness-test-wait (lambda () (eq 'idle (plist-get (harness-call 'session/get child) :status))) 10 "child idle")
      ;; Committed, it merges, and the lock goes.
      (harness-merge-test--commit wt "add feature" "feature.txt")
      (setq finished nil)
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () finished) 10 "the merge")
      (should (equal (cons child 'merged) (car finished)))
      (harness-test-wait (lambda () (not (harness-merge-test--lock-line root wt))) 10 "the unlock")
      (should (file-exists-p (expand-file-name "feature.txt" root))))))

(ert-deftest harness-merge-keeps-a-lock-of-someone-else ()
  "Only the harness's own lock goes with the merge."
  (harness-merge-test-with
    (harness-test-load-module 'worktree)
    (harness-merge-test--git root "worktree" "lock" "--reason" "on a usb stick" wt)
    (harness-merge-test--write wt "feature.txt" "new feature\n")
    (harness-merge-test--commit wt "add feature" "feature.txt")
    (let ((finished nil))
      (harness-on 'merge/finished (lambda (c _p s) (push (cons c s) finished)))
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () finished) 10 "the merge")
      (should (equal (cons child 'merged) (car finished)))
      (accept-process-output nil 0.3)
      (should (equal "locked on a usb stick" (harness-merge-test--lock-line root wt))))))

(provide 'harness-merge-test)
;;; harness-merge-test.el ends here
