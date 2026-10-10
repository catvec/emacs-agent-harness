;;; harness-ui-worktree-test.el --- Tests for the worktree list  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-worktree-branch-prefix)
(require 'harness-acp)

(defun harness-ui-worktree-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure, return stdout."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string)))
      (buffer-string))))

(defun harness-ui-worktree-test--make-repo (base)
  "Create BASE/repo with one commit and a worktree; return (ROOT . WORKTREE)."
  (let* ((root (file-name-as-directory (expand-file-name "repo" base)))
         (wt (expand-file-name "wt-feature" base)))
    (make-directory root t)
    (harness-ui-worktree-test--git root "init" "-q" "-b" "main")
    (harness-ui-worktree-test--git root "config" "user.name" "Harness Test")
    (harness-ui-worktree-test--git root "config" "user.email" "test@example.invalid")
    (harness-ui-worktree-test--git root "config" "commit.gpgsign" "false")
    (with-temp-file (expand-file-name "README" root) (insert "hello\n"))
    (harness-ui-worktree-test--git root "add" "README")
    (harness-ui-worktree-test--git root "commit" "-q" "-m" "initial")
    (harness-ui-worktree-test--git root "worktree" "add" "-q" "-b" "feature/x" wt)
    (cons root (file-name-as-directory wt))))

(defmacro harness-ui-worktree-test-with (&rest body)
  "Load the state layer, ACP, the UI and the worktree list with a repo, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent usage worktree merge acp ui ui-worktree))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-ui--sessions)
     (let* ((harness-provider-demo--delay 0.005)
            (harness-acp-token nil)
            (default-directory dir)
            (repo (harness-ui-worktree-test--make-repo dir))
            (root (car repo))
            (wt (cdr repo)))
       (ignore root wt)
       (unwind-protect
           (progn ,@body)
         (when (get-buffer harness-ui-worktree--buffer-name) (kill-buffer harness-ui-worktree--buffer-name))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-worktree-test-same-p (a b)
  "Non-nil when A and B name the same directory."
  (string= (file-name-as-directory (file-truename a)) (file-name-as-directory (file-truename b))))

(defun harness-ui-worktree-test-open (root count)
  "Open the list for ROOT and wait until COUNT rows with status are shown."
  (harness-worktrees root)
  (set-buffer harness-ui-worktree--buffer-name)
  (harness-test-wait (lambda () (and (not harness-ui-worktree--loading)
                                     (= count (length harness-ui-worktree--worktrees))
                                     (= count (hash-table-count harness-ui-worktree--status))))
                     10 "worktree rows"))

(defun harness-ui-worktree-test-wait-rows (count)
  "Wait until the list shows COUNT rows with their status."
  (harness-test-wait (lambda () (and (not harness-ui-worktree--loading)
                                     (= count (length harness-ui-worktree--worktrees))
                                     (= count (hash-table-count harness-ui-worktree--status))))
                     10 "worktree rows"))

(defun harness-ui-worktree-test-goto (path)
  "Move point to the row of worktree PATH."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (and (tabulated-list-get-id) (harness-ui-worktree-test-same-p (tabulated-list-get-id) path))))
    (forward-line 1))
  (should-not (eobp)))

(defun harness-ui-worktree-test-mode-line ()
  "Return the text of `mode-line-process' (batch Emacs cannot format mode lines)."
  (mapconcat (lambda (x) (if (stringp x) (substring-no-properties x) "")) mode-line-process ""))

(defun harness-ui-worktree-test-column (name)
  "Return the text of column NAME on the current line."
  (let ((i (cl-position name tabulated-list-format :key #'car :test #'equal)))
    (substring-no-properties (aref (tabulated-list-get-entry) i))))

(ert-deftest harness-ui-worktree-rows-flags-and-status ()
  (harness-ui-worktree-test-with
    (harness-ui-worktree-test-open root 2)
    (should (derived-mode-p 'harness-ui-worktree-mode))
    ;; q buries the list rather than quitting its window.
    (should (eq #'harness-ui-quit-view (key-binding (kbd "q"))))
    (should (harness-ui-worktree-test-same-p root harness-ui-worktree--root))
    (harness-ui-worktree-test-goto root)
    (should (equal "main" (harness-ui-worktree-test-column "Branch")))
    (should (string-match-p "main" (harness-ui-worktree-test-column "Flags")))
    (should (string-match-p "clean" (harness-ui-worktree-test-column "Status")))
    (harness-ui-worktree-test-goto wt)
    (should (equal "feature/x" (harness-ui-worktree-test-column "Branch")))
    (should-not (string-match-p "main" (harness-ui-worktree-test-column "Flags")))
    (should (= 8 (length (harness-ui-worktree-test-column "Head"))))
    ;; Dirty shows after a refresh.
    (with-temp-file (expand-file-name "scratch" wt) (insert "x\n"))
    (harness-ui-worktree-refresh)
    (harness-ui-worktree-test-wait-rows 2)
    (harness-ui-worktree-test-goto wt)
    (should (string-match-p "dirty" (harness-ui-worktree-test-column "Status")))
    ;; Opening from inside a worktree resolves to the main root.
    (kill-buffer harness-ui-worktree--buffer-name)
    (harness-ui-worktree-test-open wt 2)
    (should (harness-ui-worktree-test-same-p root harness-ui-worktree--root))
    ;; The mode line carries a mouse target for every command.
    (let ((ml (harness-ui-worktree-test-mode-line)))
      (dolist (label '("new" "remove" "prune" "lock" "session" "fork" "merge"))
        (should (string-match-p label ml)))
      (dolist (seg mode-line-process)
        (when (and (stringp seg) (string-match-p "\\[" seg))
          (should (keymapp (get-text-property 0 'local-map seg)))
          (should (get-text-property 0 'help-echo seg)))))))

(ert-deftest harness-ui-worktree-status-fanout-bounded-and-coalesced ()
  "Hundreds of rows fetch their status a few at a time and redraw once."
  (harness-ui-worktree-test-with
    ;; The reload/reconnect hooks would fire a second load mid-test; isolate
    ;; this test to the status fan-out and redraw behaviour it measures.
    (unwind-protect
        (progn
          (remove-hook 'harness-ui-redraw-hook #'harness-ui-worktree--redraw-all)
          (remove-hook 'harness-ui-event-functions #'harness-ui-worktree--on-event)
          (let* ((n 200)
                 (main-path (harness-ui-worktree--dir root))
                 (paths (cons main-path
                              (cl-loop for i from 1 below n
                                       collect (file-name-as-directory (expand-file-name (format "wt-%d" i) dir)))))
                 (wts (mapcar (lambda (p) (list :path p :branch "wt" :head "deadbeef" :main (equal p main-path)))
                              paths))
                 (in-flight 0) (max-inflight 0) (arrived 0) (prints 0)
                 (orig-print (symbol-function 'tabulated-list-print)))
            (cl-letf (((symbol-function 'tabulated-list-print)
                       (lambda (&rest args) (cl-incf prints) (apply orig-print args)))
                      ((symbol-function 'harness-ui-call)
                       (lambda (method params callback &optional _on-error)
                         (pcase method
                           ("_harness/worktree/root-of" (funcall callback main-path))
                           ("_harness/worktree/list" (funcall callback wts))
                           ("_harness/worktree/status"
                            (cl-incf in-flight)
                            (setq max-inflight (max max-inflight in-flight))
                            (run-at-time 0 nil
                                         (lambda ()
                                           (cl-decf in-flight)
                                           (cl-incf arrived)
                                           (funcall callback (list :dirty nil :ahead 0 :behind 0 :branch "wt")))))
                           (_ (funcall callback nil))))))
              (harness-worktrees root)
              (set-buffer harness-ui-worktree--buffer-name)
              (harness-test-wait (lambda () (= n (length harness-ui-worktree--worktrees))) 10 "rows")
              (harness-test-wait
               (lambda () (and (= n arrived)
                               (= n (hash-table-count harness-ui-worktree--status))))
               10 "statuses")
              (should (= harness-ui-worktree--status-concurrency max-inflight))
              (should (< prints 10))
              ;; A stale generation is ignored: a reload's answer must not overwrite.
              (cl-incf harness-ui-worktree--status-generation)
              (harness-ui-worktree--status-arrived
               (current-buffer) 0 main-path (list :dirty t :ahead 1 :behind 0 :branch "wt"))
              (should-not (plist-get (gethash main-path harness-ui-worktree--status) :dirty)))))
      (add-hook 'harness-ui-redraw-hook #'harness-ui-worktree--redraw-all)
      (add-hook 'harness-ui-event-functions #'harness-ui-worktree--on-event))))

(ert-deftest harness-ui-worktree-sessions-create-remove-prune ()
  (harness-ui-worktree-test-with
    (harness-ui-worktree-test-open root 2)
    ;; A new session in the worktree at point gets it as cwd and worktree.
    (harness-ui-worktree-test-goto wt)
    (harness-ui-worktree-new-session)
    (let ((s (harness-test-wait (lambda () (cl-find-if (lambda (s) (and (plist-get s :worktree)
                                                                          (harness-ui-worktree-test-same-p wt (plist-get s :worktree))))
                                                        (harness-call 'session/list)))
                                5 "session in worktree")))
      (should (harness-ui-worktree-test-same-p wt (plist-get s :cwd)))
      (harness-test-wait (lambda () (progn (harness-ui-worktree-test-goto wt)
                                           (string-match-p "unnamed" (harness-ui-worktree-test-column "Sessions"))))
                         5 "sessions column"))
    ;; Create through the command with the prompt stubbed.
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "feature/y")))
      (call-interactively #'harness-ui-worktree-create))
    (harness-ui-worktree-test-wait-rows 3)
    (let ((new (cl-find "feature/y" harness-ui-worktree--worktrees :key (lambda (w) (plist-get w :branch)) :test #'equal)))
      (should new)
      (should (file-directory-p (plist-get new :path)))
      ;; Removing a dirty worktree fails, then succeeds when forcing is accepted.
      (with-temp-file (expand-file-name "dirty" (plist-get new :path)) (insert "x\n"))
      (harness-ui-worktree-test-goto (plist-get new :path))
      (let ((asked-force nil))
        ;; The force question is asked from the request's error callback, so the
        ;; stubs must stay in place while waiting.
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                  ((symbol-function 'y-or-n-p) (lambda (prompt) (setq asked-force (string-match-p "force" prompt)) t)))
          (harness-ui-worktree-remove)
          (harness-ui-worktree-test-wait-rows 2))
        (should asked-force)
        (should-not (file-exists-p (plist-get new :path)))))
    ;; An empty answer has the harness name the branch, with its prefix.
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
      (call-interactively #'harness-ui-worktree-create))
    (harness-ui-worktree-test-wait-rows 3)
    (let ((named (cl-find-if (lambda (w) (string-prefix-p harness-worktree-branch-prefix
                                                          (or (plist-get w :branch) "")))
                             harness-ui-worktree--worktrees)))
      (should named)
      (harness-ui-worktree-test-goto (plist-get named :path))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (harness-ui-worktree-remove)
        (harness-ui-worktree-test-wait-rows 2)))
    ;; The main worktree refuses to be removed.
    (harness-ui-worktree-test-goto root)
    (should-error (harness-ui-worktree-remove) :type 'user-error)
    ;; Prune drops a worktree deleted behind git's back.
    (let ((gone (expand-file-name "wt-gone" dir)))
      (harness-ui-worktree-test--git root "worktree" "add" "-q" "-b" "gone" gone)
      (harness-ui-worktree-refresh)
      (harness-ui-worktree-test-wait-rows 3)
      (delete-directory gone t)
      (harness-ui-worktree-prune)
      (harness-ui-worktree-test-wait-rows 2))))

(ert-deftest harness-ui-worktree-locked-rows ()
  "A locked worktree says so; prune keeps it, saying why; d removes it all the same."
  (harness-ui-worktree-test-with
    (let ((locked (plist-get (harness-test-await (harness-call 'worktree/create root :branch "task/locked")) :path))
          (shown nil))
      (harness-ui-worktree-test-open root 3)
      (harness-ui-worktree-test-goto locked)
      (should (string-match-p "locked" (harness-ui-worktree-test-column "Flags")))
      (let* ((flags (aref (tabulated-list-get-entry)
                          (cl-position "Flags" tabulated-list-format :key #'car :test #'equal)))
             (help (get-text-property (string-match "locked" flags) 'help-echo flags)))
        (should (string-match-p "harness: task/locked" help))
        (should (string-match-p "prune" help)))
      ;; Its directory gone, the prune keeps it and says so.
      (delete-directory locked t)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) shown))))
        (harness-ui-worktree-prune)
        (harness-test-wait (lambda () (cl-some (lambda (m) (string-match-p "\\`Kept .*task-locked" m)) shown))
                           10 "the prune message"))
      (harness-ui-worktree-test-wait-rows 3)
      (harness-ui-worktree-test-goto locked)
      (should (string-match-p "locked missing" (harness-ui-worktree-test-column "Flags")))
      ;; d asks, mentioning the lock, and removes it without forcing.
      (let ((asked nil) (asked-force nil))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (setq asked prompt) t))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) (setq asked-force t) t)))
          (harness-ui-worktree-remove)
          (harness-ui-worktree-test-wait-rows 2))
        (should (string-match-p "locked: harness: task/locked" asked))
        (should-not asked-force)))))

(ert-deftest harness-ui-worktree-lock-keys ()
  "l locks or unlocks the worktree at point; L locks the harness's worktrees that have none."
  (harness-ui-worktree-test-with
    (let ((old (expand-file-name ".worktrees/old" root)))
      ;; Made as before locks, in the harness's worktree directory.
      (harness-ui-worktree-test--git root "worktree" "add" "-q" "-b" "task/old" old)
      (harness-ui-worktree-test-open root 3)
      (cl-flet ((flags (path) (harness-ui-worktree-test-goto path) (harness-ui-worktree-test-column "Flags")))
        (should-not (string-match-p "locked" (flags old)))
        ;; L locks it, but not the foreign worktree outside that directory.
        (harness-ui-worktree-lock-existing)
        (harness-test-wait (lambda () (and (harness-ui-worktree-test-wait-rows 3) (string-match-p "locked" (flags old))))
                           10 "the lock")
        (should-not (string-match-p "locked" (flags wt)))
        ;; l unlocks it after asking, and locks it again.
        (harness-ui-worktree-test-goto old)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (should (string-match-p "harness: task/old" prompt)) t)))
          (harness-ui-worktree-toggle-lock))
        (harness-test-wait (lambda () (and (harness-ui-worktree-test-wait-rows 3) (not (string-match-p "locked" (flags old)))))
                           10 "the unlock")
        (harness-ui-worktree-test-goto wt)
        (harness-ui-worktree-toggle-lock)
        (harness-test-wait (lambda () (and (harness-ui-worktree-test-wait-rows 3) (string-match-p "locked" (flags wt))))
                           10 "the lock at point")
        (should (equal "locked harness: feature/x"
                       (seq-find (lambda (l) (string-prefix-p "locked" l))
                                 (split-string (harness-ui-worktree-test--git root "worktree" "list" "--porcelain") "\n"))))
        (harness-ui-worktree-test-goto root)
        (should-error (harness-ui-worktree-toggle-lock) :type 'user-error)))))

(ert-deftest harness-ui-worktree-prune-merged-key ()
  "P removes the worktrees whose work merged, after asking; a no keeps them."
  (harness-ui-worktree-test-with
    (let* ((merged (plist-get (harness-test-await (harness-call 'worktree/create root :branch "task/merged")) :path))
           (asked nil) (messages nil))
      ;; Unlocked, as the merge queue leaves a merged worktree, and at the
      ;; repository's HEAD: git ancestry says it merged.
      (harness-test-await (harness-call 'worktree/unlock root merged))
      ;; The other worktree (at the repository's HEAD as well) has local
      ;; changes, so it is no candidate and the working copy is left alone.
      (with-temp-file (expand-file-name "scratch" wt) (insert "x\n"))
      (harness-ui-worktree-test-open root 3)
      (should (string-match-p "\\[P merged\\]" (harness-ui-worktree-test-mode-line)))
      (should (eq (lookup-key harness-ui-worktree-mode-map (kbd "P"))
                  #'harness-ui-worktree-prune-merged))
      ;; A no leaves the worktree alone.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (prompt) (setq asked prompt) nil)))
        (harness-ui-worktree-prune-merged)
        (harness-test-wait (lambda () asked) 5 "the question"))
      (should (string-match-p "Remove 1 worktree" asked))
      (should (string-match-p "task-merged" asked))
      (should (file-directory-p merged))
      ;; A yes removes it and reloads the list.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) t))
                ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (harness-ui-worktree-prune-merged)
        (harness-ui-worktree-test-wait-rows 2))
      (should-not (file-exists-p merged))
      (should (file-directory-p wt))
      (should (cl-some (lambda (m) (string-match-p "Removed 1 merged worktree" m)) messages))
      ;; Nothing merged left to remove: it says so and asks nothing.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "should not ask")))
                ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (harness-ui-worktree-prune-merged)
        (harness-test-wait (lambda () (cl-some (lambda (m) (string-match-p "No merged worktrees" m)) messages))
                           5 "the empty message")))))

(ert-deftest harness-ui-worktree-fork-and-merge-queue ()
  (harness-ui-worktree-test-with
    (harness-ui-worktree-test-open root 2)
    (let* ((parent (harness-call 'session/create :cwd root :model "demo:scripted" :name "Parent"))
           (pid (plist-get parent :id)))
      ;; f: fork the current session into a new worktree.
      (cl-letf (((symbol-function 'harness-ui-display-session) #'ignore))
        (harness-ui-worktree-fork-session pid "feature/fork"))
      (harness-ui-worktree-test-wait-rows 3)
      (let* ((wt2 (cl-find "feature/fork" harness-ui-worktree--worktrees :key (lambda (w) (plist-get w :branch)) :test #'equal))
             (path (plist-get wt2 :path))
             (child (cl-find-if (lambda (s) (equal (plist-get s :parent-id) pid)) (harness-call 'session/list))))
        (should child)
        (should (harness-ui-worktree-test-same-p path (plist-get child :worktree)))
        (should (harness-ui-worktree-test-same-p path (plist-get child :cwd)))
        (harness-test-wait (lambda () (harness-ui-session (plist-get child :id))) 5 "session cached")
        ;; m: queue the child for merging into the parent; the queue shows in the mode line.
        (harness-ui-worktree-test-goto path)
        (harness-ui-worktree-merge)
        (harness-test-wait (lambda () harness-ui-worktree--queue) 5 "merge queue")
        (should (equal pid (car harness-ui-worktree--queue)))
        (should (string-match-p "merge queue" (harness-ui-worktree-test-mode-line)))))))

(provide 'harness-ui-worktree-test)
;;; harness-ui-worktree-test.el ends here
