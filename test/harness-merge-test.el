;;; harness-merge-test.el --- Tests for the merge queue  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)
(defvar harness-merge--queues)
(defvar harness-merge--locks)
(defvar harness-merge--holds)
(defvar harness-merge--calls)
(defvar harness-merge--timers)
(defvar harness-merge--hold-timeout)
(defvar harness-session-interrupted-output)
(defvar harness-merge-conflict-resolver)
(defvar harness-provider-demo-script-override)

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
     (clrhash harness-merge--calls)
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

(defun harness-merge-test--outside (sid kind)
  "Return the nodes of KIND (tool-call, tool-result) the harness recorded in SID."
  (cl-remove-if-not (lambda (n) (and (eq (plist-get n :kind) kind) (harness-outside-node-p n)))
                    (harness-call 'session/nodes sid)))

(defun harness-merge-test--position (sid pred)
  "Return the position in SID's transcript of the first node PRED accepts."
  (cl-position-if pred (harness-call 'session/nodes sid)))

(defun harness-merge-test--hint-p (regexp)
  "Return a predicate accepting a hint node whose text matches REGEXP."
  (lambda (n) (and (eq (plist-get n :kind) 'hint) (string-match-p regexp (plist-get n :content)))))

(defun harness-merge-test--tool-blocks (messages)
  "Return the blocks of provider MESSAGES about tool calls.
Those are tool uses, tool results and the text a stray result becomes."
  (cl-loop for m in messages
           append (cl-remove-if-not
                   (lambda (b) (or (member (plist-get b :type) '("tool_use" "tool_result"))
                                   (string-prefix-p "[Result of tool call" (or (plist-get b :text) ""))))
                   (plist-get m :content))))

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
  "A conflict never touches the parent: the child merges the parent in its worktree."
  (harness-merge-test-with
   (let ((harness-merge-conflict-resolver 'child))
    ;; Both sides change the same line.
    (harness-merge-test--write wt "README" "child version\n")
    (harness-merge-test--commit wt "child edit" "README")
    (harness-merge-test--write root "README" "parent version\n")
    (harness-merge-test--commit root "parent edit" "README")
    (let ((conflicts nil) (finished nil)
          (parent-head (string-trim (harness-merge-test--git root "rev-parse" "HEAD"))))
      (harness-on 'merge/conflict (lambda (c p files) (push (list c p files) conflicts)))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () conflicts) 10 "conflict")
      (should (equal (list child parent '("README")) (car conflicts)))
      (should (eq 'conflict (harness-call 'merge/status child)))
      (should (null finished))
      ;; The parent's checkout is exactly as it was, and not locked.
      (should (equal parent-head (string-trim (harness-merge-test--git root "rev-parse" "HEAD"))))
      (should (string-empty-p (harness-merge-test--git root "status" "--porcelain")))
      (should-not (file-exists-p (expand-file-name ".git/MERGE_HEAD" root)))
      (should (null (gethash parent harness-merge--locks)))
      ;; The child was steered to merge the parent's commit in its worktree.
      (harness-test-wait (lambda () (cl-find-if (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes child)))
                         10 "child steering node")
      (let ((user (cl-find-if (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes child))))
        (should (string-match-p "- README" (plist-get user :content)))
        (should (string-match-p (regexp-quote (concat "git merge " (substring parent-head 0 12))) (plist-get user :content)))
        (should (string-match-p "merge_done" (plist-get user :content)))
        (should (equal (harness-sender-system "merge queue") (harness-node-sender user))))
      (harness-test-wait (lambda () (eq 'idle (plist-get (harness-call 'session/get child) :status))) 10 "child idle")
      ;; The parent is not held while the child resolves.
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt parent "hello")) :stop-reason)))
      ;; merge_done fails before the parent's commit is merged in.
      (let ((r (harness-merge-test--merge-done child)))
        (should (plist-get r :is-error))
        (should (string-match-p "does not contain" (plist-get r :content))))
      ;; In the middle of the merge: conflicts remain.
      (ignore-errors (harness-merge-test--git wt "merge" "-q" parent-head))
      (let ((r (harness-merge-test--merge-done child)))
        (should (plist-get r :is-error))
        (should (string-match-p "README" (plist-get r :content))))
      ;; Resolved but not committed: still refused.
      (harness-merge-test--write wt "README" "resolved version\n")
      (harness-merge-test--git wt "add" "README")
      (let ((r (harness-merge-test--merge-done child)))
        (should (plist-get r :is-error))
        (should (string-match-p "not committed" (plist-get r :content))))
      (harness-merge-test--git wt "commit" "-q" "--no-edit")
      (let ((r (harness-merge-test--merge-done child)))
        (should-not (plist-get r :is-error))
        (should (string-match-p "queued" (plist-get r :content))))
      (harness-test-wait (lambda () finished) 10 "merged")
      (should (equal (list child parent 'merged) (car finished)))
      (should (null (harness-call 'merge/queue parent)))
      (should (null (gethash parent harness-merge--locks)))
      (should (equal "resolved version\n"
                     (with-temp-buffer (insert-file-contents (expand-file-name "README" root)) (buffer-string))))
      (should (= 2 (length (split-string (harness-merge-test--git root "log" "-1" "--format=%P") " " t))))))))

(defun harness-merge-test--conflict-setup (wt root)
  "Make the child's branch in WT and ROOT's main change README's one line."
  (harness-merge-test--write wt "README" "child version\n")
  (harness-merge-test--commit wt "child edit" "README")
  (harness-merge-test--write root "README" "parent version\n")
  (harness-merge-test--commit root "parent edit" "README"))

(ert-deftest harness-merge-conflict-goes-to-a-fresh-session ()
  "By default a fresh session resolves the conflict, and the child is left alone."
  (harness-merge-test-with
    (harness-merge-test--conflict-setup wt root)
    (let* ((finished nil) (resolvers nil) (requests nil)
           (parent-head (string-trim (harness-merge-test--git root "rev-parse" "HEAD")))
           (harness-provider-demo-script-override
            (lambda (request)
              (let ((sid (plist-get (plist-get request :session) :id)))
                (push (cons sid (harness-provider-demo--last-user-text request)) requests)
                (if (harness-provider-demo--has-tool-results-p request)
                    '((:type text :delta "Resolved.") (:type done :stop-reason end-turn))
                  ;; The model's work: merge, resolve and commit in the worktree.
                  (ignore-errors (harness-merge-test--git wt "merge" "-q" parent-head))
                  (harness-merge-test--write wt "README" "resolved version\n")
                  (harness-merge-test--git wt "add" "README")
                  (harness-merge-test--git wt "commit" "-q" "--no-edit")
                  '((:type tool-call :id "md-1" :name "merge_done" :input nil)))))))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      (harness-on 'merge/resolver (lambda (c p r) (push (list c p r) resolvers)))
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () finished) 15 "merged")
      (should (equal (list child parent 'merged) (car finished)))
      (should (= 1 (length resolvers)))
      (let* ((rid (nth 2 (car resolvers)))
             (resolver (harness-call 'session/get rid)))
        ;; A new session, a sub-agent of the child, in the child's worktree.
        (should-not (member rid (list child parent)))
        (should (eq 'subagent (plist-get resolver :kind)))
        (should (equal child (plist-get resolver :parent-id)))
        (should (equal (file-name-as-directory wt) (plist-get resolver :cwd)))
        (should (equal "Merge child" (plist-get resolver :name)))
        ;; Only the resolver was prompted, by the merge queue.
        (should (equal (list rid) (delete-dups (mapcar #'car requests))))
        (let ((user (cl-find-if (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes rid))))
          (should (string-match-p "- README" (plist-get user :content)))
          (should (string-match-p (regexp-quote (concat "git merge " (substring parent-head 0 12))) (plist-get user :content)))
          (should (equal (harness-sender-system "merge queue") (harness-node-sender user)))))
      ;; The child got a hint, never a prompt.
      (should-not (cl-find-if (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes child)))
      (should (cl-some (lambda (h) (string-match-p "session Merge child resolves them" h)) (harness-merge-test--hints child)))
      (should (equal "resolved version\n"
                     (with-temp-buffer (insert-file-contents (expand-file-name "README" root)) (buffer-string))))
      (should (null (harness-call 'merge/queue parent))))))

(ert-deftest harness-merge-fresh-resolver-that-gives-up-fails-the-merge ()
  "A resolver whose turn ends without merge_done fails the merge; the parent is untouched."
  (harness-merge-test-with
    (harness-merge-test--conflict-setup wt root)
    (let ((finished nil)
          (harness-provider-demo-script-override
           '((:type text :delta "I cannot resolve this.") (:type done :stop-reason end-turn))))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () finished) 15 "failed")
      (should (equal (list child parent 'failed) (car finished)))
      (should (cl-some (lambda (h) (string-match-p "stopped (end-turn) without merge_done" h)) (harness-merge-test--hints parent)))
      (should (equal "parent version\n"
                     (with-temp-buffer (insert-file-contents (expand-file-name "README" root)) (buffer-string))))
      (should (null (harness-call 'merge/queue parent)))
      (should (null (gethash parent harness-merge--locks)))
      ;; Its spawn_agent call in the child failed: the reply and why,
      ;; recorded before the news that the merge failed.
      (let ((result (car (harness-merge-test--outside child 'tool-result))))
        (should (= 1 (length (harness-merge-test--outside child 'tool-call))))
        (should (equal (plist-get (car (harness-merge-test--outside child 'tool-call)) :call-id)
                       (plist-get result :call-id)))
        (should (plist-get result :is-error))
        (should (string-match-p "I cannot resolve this\\." (plist-get result :output)))
        (should (string-match-p "stopped (end-turn) without calling merge_done" (plist-get result :output)))
        (should (< (harness-merge-test--position child (lambda (n) (equal (plist-get n :id) (plist-get result :id))))
                   (harness-merge-test--position child (harness-merge-test--hint-p "finished: failed"))))))))

(ert-deftest harness-merge-fresh-resolver-shows-as-a-spawn-agent-call ()
  "The fresh resolver shows in the child's transcript as a spawn_agent
call: the call when it starts, after the hint saying why, and its
result -- the resolver's last reply -- when it stops.  The merge queue
made both, so the child's model never gets them: its next request is
the same as without them, with no call left unpaired."
  (harness-merge-test-with
    (harness-merge-test--conflict-setup wt root)
    (let* ((finished nil) (resolvers nil) (child-requests nil)
           (parent-head (string-trim (harness-merge-test--git root "rev-parse" "HEAD")))
           (harness-provider-demo-script-override
            (lambda (request)
              (cond
               ((equal child (plist-get (plist-get request :session) :id))
                (push (plist-get request :messages) child-requests)
                '((:type text :delta "Hello.") (:type done :stop-reason end-turn)))
               ((harness-provider-demo--has-tool-results-p request)
                '((:type text :delta "Resolved: kept both sides.") (:type done :stop-reason end-turn)))
               (t
                (ignore-errors (harness-merge-test--git wt "merge" "-q" parent-head))
                (harness-merge-test--write wt "README" "resolved version\n")
                (harness-merge-test--git wt "add" "README")
                (harness-merge-test--git wt "commit" "-q" "--no-edit")
                '((:type tool-call :id "md-1" :name "merge_done" :input nil)))))))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      (harness-on 'merge/resolver (lambda (_c _p r) (push r resolvers)))
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () (and finished (harness-merge-test--outside child 'tool-result)))
                         15 "the merge and the call's result")
      (should (equal (list child parent 'merged) (car finished)))
      (let* ((rid (car resolvers))
             (calls (harness-merge-test--outside child 'tool-call))
             (call (car calls))
             (result (car (harness-merge-test--outside child 'tool-result)))
             (prompt (plist-get (cl-find-if (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes rid))
                                :content)))
        ;; One call, as the child's own spawn_agent call would be, naming the resolver.
        (should (= 1 (length calls)))
        (should (equal "spawn_agent" (plist-get call :tool)))
        (should (equal "Merge child" (plist-get (plist-get call :input) :name)))
        (should (equal prompt (plist-get (plist-get call :input) :prompt)))
        (should (equal (harness-sender-system "merge queue") (harness-node-sender call)))
        (should (equal rid (plist-get (plist-get call :meta) :child-id)))
        ;; After the hint that says why.
        (should (< (harness-merge-test--position child (harness-merge-test--hint-p "session Merge child resolves them"))
                   (harness-merge-test--position child (lambda (n) (equal (plist-get n :id) (plist-get call :id))))))
        ;; Its result: the resolver's last reply and footer, a success.
        (should (equal (plist-get call :call-id) (plist-get result :call-id)))
        (should-not (plist-get result :is-error))
        (should (string-match-p "\\`Resolved: kept both sides\\." (plist-get result :output)))
        (should (string-match-p (regexp-quote (format "[sub-agent session: %s, 1 tool calls, cost " rid))
                                (plist-get result :output)))
        (should (string-match-p "merge_done queued the branch to merge again" (plist-get result :output)))
        (should (equal (harness-sender-system "merge queue") (harness-node-sender result)))
        (should (equal rid (plist-get (plist-get result :meta) :child-id)))
        (should (numberp (plist-get (plist-get result :meta) :duration))))
      ;; The child was never prompted, and its model sees none of it.
      (should-not (cl-find-if (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes child)))
      (should (null (harness-call 'session/messages child)))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt child "hello")) :stop-reason)))
      (should (= 1 (length child-requests)))
      (should (equal '(user) (mapcar (lambda (m) (plist-get m :role)) (car child-requests))))
      (should-not (harness-merge-test--tool-blocks (car child-requests)))
      ;; Answered once.
      (should (= 1 (length (harness-merge-test--outside child 'tool-result)))))))

(ert-deftest harness-merge-fresh-resolver-timeout-answers-its-call ()
  "A resolver still at work when its conflict times out is stopped, and
its call in the child gets its result then: once, before the news that
the merge was aborted, which happens once."
  (harness-merge-test-with
    (harness-merge-test--conflict-setup wt root)
    (harness-define-tool "stall" :label "Stall" :description "never returns" :kind 'read
                         :handler (lambda (_input _ctx) (harness-with-promise (resolve reject) (ignore resolve reject))))
    (let ((harness-merge--hold-timeout 0.5) (finished nil) (resolvers nil)
          (harness-provider-demo-script-override '((:type tool-call :id "w-1" :name "stall" :input nil))))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      (harness-on 'merge/resolver (lambda (_c _p r) (push r resolvers)))
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () finished) 10 "aborted")
      (should (equal (list (list child parent 'aborted)) finished))
      (let ((result (car (harness-merge-test--outside child 'tool-result))))
        (should (plist-get result :is-error))
        (should (string-match-p "the merge was aborted (not resolved within " (plist-get result :output)))
        (should (string-match-p "so the sub-agent was stopped" (plist-get result :output)))
        (should (< (harness-merge-test--position child (lambda (n) (equal (plist-get n :id) (plist-get result :id))))
                   (harness-merge-test--position child (harness-merge-test--hint-p "finished: aborted")))))
      ;; The resolver stops; that answers nothing again and finishes nothing again.
      (harness-test-wait (lambda () (not (harness-call 'agent/running (car resolvers)))) 10 "the resolver stopped")
      (accept-process-output nil 0.1)
      (should (= 1 (length (harness-merge-test--outside child 'tool-result))))
      (should (= 1 (length finished))))))

(ert-deftest harness-merge-resolver-that-cannot-start-answers-its-call ()
  "A resolver whose prompt fails at once still gets its call answered,
before the news that the merge failed."
  (harness-merge-test-with
    (harness-merge-test--conflict-setup wt root)
    (let ((finished nil)
          (call-async (symbol-function 'harness-call-async)))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      (cl-letf (((symbol-function 'harness-call-async)
                 (lambda (name &rest args)
                   (if (and (eq name 'agent/prompt) (not (member (car args) (list child parent))))
                       (harness-rejected (list 'harness-error "no model for you"))
                     (apply call-async name args)))))
        (harness-call 'merge/enqueue child parent)
        (harness-test-wait (lambda () finished) 10 "failed"))
      (should (equal (list (list child parent 'failed)) finished))
      (let ((result (car (harness-merge-test--outside child 'tool-result))))
        (should (= 1 (length (harness-merge-test--outside child 'tool-call))))
        (should (= 1 (length (harness-merge-test--outside child 'tool-result))))
        (should (plist-get result :is-error))
        (should (string-match-p "(the sub-agent failed: .*no model for you" (plist-get result :output)))
        (should (< (harness-merge-test--position child (lambda (n) (equal (plist-get n :id) (plist-get result :id))))
                   (harness-merge-test--position child (harness-merge-test--hint-p "finished: failed"))))))))

(ert-deftest harness-merge-resolver-refused-a-turn-answers-its-call ()
  "A resolver whose turn never starts, refused at its gate, shows its
call and the call's result at once, before the news that the merge failed."
  (harness-merge-test-with
    (harness-merge-test--conflict-setup wt root)
    (let ((finished nil))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      (harness-add-filter 'agent/before-turn
                          (lambda (value next session)
                            (funcall next (if (eq (plist-get session :kind) 'subagent)
                                              (list :proceed nil :reason "over budget" :final t)
                                            value))
                            nil)
                          10)
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () finished) 10 "failed")
      (should (equal (list (list child parent 'failed)) finished))
      (let ((calls (harness-merge-test--outside child 'tool-call))
            (results (harness-merge-test--outside child 'tool-result)))
        (should (= 1 (length calls)))
        (should (= 1 (length results)))
        (should (equal (plist-get (car calls) :call-id) (plist-get (car results) :call-id)))
        (should (plist-get (car results) :is-error))
        (should (string-match-p "stopped (blocked) without calling merge_done" (plist-get (car results) :output)))
        (should (< (harness-merge-test--position child (lambda (n) (equal (plist-get n :id) (plist-get (car calls) :id))))
                   (harness-merge-test--position child (lambda (n) (equal (plist-get n :id) (plist-get (car results) :id))))
                   (harness-merge-test--position child (harness-merge-test--hint-p "finished: failed"))))))))

(ert-deftest harness-merge-resolver-call-is-answered-after-a-restart ()
  "The resolver's call shows once its turn starts, the resolver running:
a harness stopped from then on answers the call when it starts again,
as it settles the resolver, though the child itself was not running."
  (harness-merge-test-with
    (harness-merge-test--conflict-setup wt root)
    (harness-define-tool "stall" :label "Stall" :description "never returns" :kind 'read
                         :handler (lambda (_input _ctx) (harness-with-promise (resolve reject) (ignore resolve reject))))
    (let ((resolvers nil) (gate nil)
          (harness-provider-demo-script-override '((:type tool-call :id "w-1" :name "stall" :input nil))))
      (harness-on 'merge/resolver (lambda (_c _p r) (push r resolvers)))
      ;; The resolver's turn waits at its gate.
      (harness-add-filter 'agent/before-turn
                          (lambda (value next session)
                            (if (eq (plist-get session :kind) 'subagent)
                                (setq gate (lambda () (funcall next value)))
                              (funcall next value))
                            nil)
                          10)
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () gate) 10 "the resolver's turn at its gate")
      ;; Not started, not running: no call yet.
      (should-not (harness-merge-test--outside child 'tool-call))
      (should-not (eq 'running (plist-get (harness-call 'session/get (car resolvers)) :status)))
      (funcall gate)
      (harness-test-wait (lambda () (harness-merge-test--outside child 'tool-call)) 10 "the call")
      (should (eq 'running (plist-get (harness-call 'session/get (car resolvers)) :status)))
      (should-not (harness-merge-test--outside child 'tool-result))
      ;; The harness stops; the next one starts from what was saved.
      (maphash (lambda (_child timer) (cancel-timer timer)) harness-merge--timers)
      (clrhash harness-merge--timers)
      (harness-session-flush)
      (clrhash harness-sessions)
      (clrhash harness-agent--turns)
      (clrhash harness-merge--calls)
      (harness-session--load-all)
      (let ((call (car (harness-merge-test--outside child 'tool-call)))
            (results (harness-merge-test--outside child 'tool-result)))
        (should (= 1 (length results)))
        (should (equal (plist-get call :call-id) (plist-get (car results) :call-id)))
        (should (plist-get (car results) :is-error))
        (should (equal harness-session-interrupted-output (plist-get (car results) :output)))
        (should (equal (car resolvers) (plist-get (plist-get (car results) :meta) :child-id))))
      (should (null (harness-call 'session/messages child))))))

(ert-deftest harness-merge-keeps-local-work-in-the-parent ()
  "Uncommitted work in the parent's checkout in the merge's way is never touched."
  (harness-merge-test-with
    (harness-merge-test--write wt "README" "child version\n")
    (harness-merge-test--write wt "feature.txt" "new feature\n")
    (harness-merge-test--commit wt "child edit" "README" "feature.txt")
    ;; Someone's uncommitted edit, and an untracked file, in the parent.
    (harness-merge-test--write root "README" "work in progress\n")
    (harness-merge-test--write root "notes.txt" "scratch\n")
    (let ((finished nil)
          (head (string-trim (harness-merge-test--git root "rev-parse" "HEAD"))))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () finished) 10 "merge finished")
      (should (equal (list child parent 'failed) (car finished)))
      (should (equal head (string-trim (harness-merge-test--git root "rev-parse" "HEAD"))))
      (should-not (file-exists-p (expand-file-name ".git/MERGE_HEAD" root)))
      (should-not (file-exists-p (expand-file-name "feature.txt" root)))
      (should (equal "work in progress\n"
                     (with-temp-buffer (insert-file-contents (expand-file-name "README" root)) (buffer-string))))
      (should (file-exists-p (expand-file-name "notes.txt" root)))
      (should (cl-some (lambda (h) (string-match-p "left untouched" h)) (harness-merge-test--hints parent)))
      (should (null (gethash parent harness-merge--locks))))))

(ert-deftest harness-merge-leaves-a-merge-in-progress-alone ()
  "A merge someone left in progress in the parent is neither finished nor aborted."
  (harness-merge-test-with
    (harness-merge-test--write wt "feature.txt" "new feature\n")
    (harness-merge-test--commit wt "add feature" "feature.txt")
    (let ((other (harness-merge-test--worktree base root "other")))
      (harness-merge-test--write other "README" "other version\n")
      (harness-merge-test--commit other "other edit" "README")
      (harness-merge-test--write root "README" "parent version\n")
      (harness-merge-test--commit root "parent edit" "README")
      (ignore-errors (harness-merge-test--git root "merge" "-q" "other")))
    (should (file-exists-p (expand-file-name ".git/MERGE_HEAD" root)))
    (let ((finished nil))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () finished) 10 "merge finished")
      (should (equal (list child parent 'failed) (car finished)))
      (should (file-exists-p (expand-file-name ".git/MERGE_HEAD" root)))
      (should (equal '("README") (split-string (harness-merge-test--git root "diff" "--name-only" "--diff-filter=U") "\n" t)))
      (should-not (file-exists-p (expand-file-name "feature.txt" root))))))

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
    (let ((harness-merge--hold-timeout 0.2) (harness-merge-conflict-resolver 'child) (finished nil))
      (harness-on 'merge/finished (lambda (c p s) (push (list c p s) finished)))
      (harness-call 'merge/enqueue child parent)
      (harness-test-wait (lambda () finished) 10 "aborted")
      (should (equal (list child parent 'aborted) (car finished)))
      (should (null (harness-call 'merge/status child)))
      (should (string-empty-p (harness-merge-test--git root "status" "--porcelain")))
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
