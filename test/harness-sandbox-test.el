;;; harness-sandbox-test.el --- Tests for the sandbox module  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defun harness-sandbox-test--setup ()
  "Load the sandbox module and what it requires."
  (harness-test-load-module 'project)
  (harness-test-load-module 'config)
  (harness-test-load-module 'sandbox))

(defmacro harness-sandbox-test-with-executables (available &rest body)
  "Run BODY with `executable-find' answering only for programs in AVAILABLE.
AVAILABLE is an alist of program name to path.  The backend is
re-detected before BODY and restored afterwards."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'executable-find)
              (lambda (name &optional _remote) (cdr (assoc name ,available)))))
     (unwind-protect
         (progn (harness-sandbox-detect) ,@body)
       nil)))

(defun harness-sandbox-test--subseq-p (needle list)
  "Non-nil when the elements of NEEDLE appear consecutively in LIST."
  (cl-loop for tail on list
           thereis (equal (seq-take tail (length needle)) needle)))

(ert-deftest harness-sandbox-bwrap-arguments ()
  (harness-sandbox-test--setup)
  (let* ((cwd (harness-test-temp-dir))
         (extra (harness-test-temp-dir))
         ;; The sandbox's own home must differ from the process home, or the
         ;; "real home is never bound" check below cannot tell them apart.
         (harness-sandbox--home (expand-file-name "sandbox-home" cwd))
         (harness-sandbox-policy 'preferred)
         (harness-sandbox-backend 'auto)
         (command '("sh" "-c" "true")))
    (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
      (should (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
      (should (equal '(bwrap) (plist-get (harness-call 'sandbox/status) :available)))
      (let ((cmd (harness-call 'sandbox/wrap cwd command)))
        (should (equal "/usr/bin/bwrap" (car cmd)))
        (should (harness-sandbox-test--subseq-p '("--ro-bind" "/usr" "/usr") cmd))
        (should (harness-sandbox-test--subseq-p '("--ro-bind" "/etc" "/etc") cmd))
        (should (harness-sandbox-test--subseq-p '("--proc" "/proc") cmd))
        (should (harness-sandbox-test--subseq-p '("--dev" "/dev") cmd))
        (should (harness-sandbox-test--subseq-p '("--tmpfs" "/tmp") cmd))
        (should (harness-sandbox-test--subseq-p
                 (list "--bind" (directory-file-name cwd) (directory-file-name cwd)) cmd))
        ;; The tmpfs must come before the cwd bind so a cwd under /tmp stays visible.
        (should (< (cl-position "--tmpfs" cmd :test #'equal) (cl-position "--bind" cmd :test #'equal)))
        (dolist (flag '("--unshare-pid" "--unshare-ipc" "--unshare-uts" "--die-with-parent" "--new-session"))
          (should (member flag cmd)))
        (should (harness-sandbox-test--subseq-p (list "--chdir" (directory-file-name cwd)) cmd))
        (should (harness-sandbox-test--subseq-p (list "--setenv" "HOME" harness-sandbox--home) cmd))
        ;; Network stays on by default.
        (should-not (member "--unshare-net" cmd))
        ;; The real home is never bound.
        (should-not (member (directory-file-name (getenv "HOME")) cmd))
        ;; The command follows the separator untouched.
        (should (equal command (cdr (member "--" cmd)))))
      ;; Options: network off and extra writable/readable directories.
      (let ((cmd (harness-call 'sandbox/wrap cwd command :network nil :writable (list extra)
                               :readable (list "/var/empty-nonexistent-dir"))))
        (should (member "--unshare-net" cmd))
        (should (harness-sandbox-test--subseq-p
                 (list "--bind" (directory-file-name extra) (directory-file-name extra)) cmd))
        ;; Missing readable directories are silently skipped.
        (should-not (member "/var/empty-nonexistent-dir" cmd))))
    ;; Restore the real detection for later tests.
    (harness-sandbox-detect)
    (delete-directory cwd t)
    (delete-directory extra t)))

(ert-deftest harness-sandbox-systemd-arguments ()
  (harness-sandbox-test--setup)
  (let* ((cwd (harness-test-temp-dir))
         (harness-sandbox-policy 'preferred)
         (harness-sandbox-backend 'auto)
         (command '("sh" "-c" "true")))
    (harness-sandbox-test-with-executables '(("systemd-run" . "/usr/bin/systemd-run"))
      (should (eq 'systemd (plist-get (harness-call 'sandbox/status) :backend)))
      (let ((cmd (harness-call 'sandbox/wrap cwd command)))
        (should (equal "/usr/bin/systemd-run" (car cmd)))
        (dolist (flag '("--user" "--quiet" "--pipe" "--wait" "--collect"))
          (should (member flag cmd)))
        (should (member (concat "--working-directory=" (directory-file-name cwd)) cmd))
        (should (harness-sandbox-test--subseq-p '("-p" "PrivateTmp=yes") cmd))
        (should (harness-sandbox-test--subseq-p '("-p" "ProtectHome=tmpfs") cmd))
        (should (harness-sandbox-test--subseq-p (list "-p" (concat "BindPaths=" (directory-file-name cwd))) cmd))
        (should (harness-sandbox-test--subseq-p (list "-p" (concat "ReadWritePaths=" (directory-file-name cwd))) cmd))
        (should-not (member "PrivateNetwork=yes" cmd))
        (should (equal command (cdr (member "--" cmd)))))
      (let ((cmd (harness-call 'sandbox/wrap cwd command :network nil)))
        (should (harness-sandbox-test--subseq-p '("-p" "PrivateNetwork=yes") cmd))))
    ;; bwrap wins when both are present.
    (harness-sandbox-test-with-executables '(("systemd-run" . "/usr/bin/systemd-run") ("bwrap" . "/usr/bin/bwrap"))
      (should (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
      (should (equal '(bwrap systemd) (plist-get (harness-call 'sandbox/status) :available))))
    (harness-sandbox-detect)
    (delete-directory cwd t)))

(ert-deftest harness-sandbox-policy-fail-closed-preferred-off ()
  (harness-sandbox-test--setup)
  (let* ((cwd (harness-test-temp-dir))
         (harness-sandbox-backend 'auto)
         (command '("sh" "-c" "true")))
    (harness-sandbox-test-with-executables nil
      (should (eq 'none (plist-get (harness-call 'sandbox/status) :backend)))
      (should (null (plist-get (harness-call 'sandbox/status) :available)))
      ;; required + nothing available: refuse.
      (let ((harness-sandbox-policy 'required))
        (should (eq 'required (plist-get (harness-call 'sandbox/status) :policy)))
        (should-error (harness-call 'sandbox/wrap cwd command) :type 'harness-sandbox-unavailable)
        (with-current-buffer (get-buffer-create harness-log-buffer-name)
          (should (string-match-p "ERROR.*sandbox: policy is .required" (buffer-string)))))
      ;; preferred: run unconfined.
      (let ((harness-sandbox-policy 'preferred))
        (should (equal command (harness-call 'sandbox/wrap cwd command)))))
    ;; off: unchanged even when a backend exists.
    (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
      (let ((harness-sandbox-policy 'off))
        (should (equal command (harness-call 'sandbox/wrap cwd command))))
      ;; A remote cwd is never wrapped, whatever the policy.
      (let ((harness-sandbox-policy 'required))
        (should (equal command (harness-call 'sandbox/wrap "/ssh:example.invalid:/tmp/" command)))))
    ;; A forced backend that is missing counts as none.
    (let ((harness-sandbox-backend 'systemd))
      (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
        (should (eq 'none (plist-get (harness-call 'sandbox/status) :backend)))))
    (harness-sandbox-detect)
    (delete-directory cwd t)))

(ert-deftest harness-sandbox-policy-from-config-layers ()
  "The policy is read per cwd through config/get, so dir-locals apply."
  (harness-sandbox-test--setup)
  (let* ((cwd (harness-test-temp-dir))
         (harness-sandbox-policy 'preferred)
         (command '("true")))
    (with-temp-file (expand-file-name ".dir-locals.el" cwd)
      (insert "((nil . ((harness-sandbox-policy . off))))"))
    (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
      (should (equal command (harness-call 'sandbox/wrap cwd command)))
      (should (eq 'preferred (plist-get (harness-call 'sandbox/status) :policy))))
    (harness-sandbox-detect)
    (delete-directory cwd t)))

(ert-deftest harness-sandbox-bwrap-real-run-hides-home ()
  "Run a command under the real bwrap and check the real HOME is unreachable."
  (harness-sandbox-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (let* ((cwd (harness-test-temp-dir))
         (home (getenv "HOME"))
         ;; A distinct sandbox home, so the real home is a different path even
         ;; when the process is started with HOME under /tmp.
         (harness-sandbox--home (expand-file-name "sandbox-home" cwd))
         (harness-sandbox-policy 'required)
         (cmd (harness-call 'sandbox/wrap cwd
                            (list "sh" "-c" (format "echo HOME=$HOME; ls $HOME; ls %s 2>&1; touch outside-test 2>&1 || true; echo ok" home))))
         (r (harness-await (harness-run-command cmd :cwd cwd :timeout 20))))
    (unwind-protect
        (progn
          (when (and (not (eql 0 (plist-get r :exit)))
                     (string-match-p "bwrap:" (plist-get r :stderr)))
            (ert-skip (format "bwrap cannot start in this environment: %s"
                              (string-trim (plist-get r :stderr)))))
          (should (eql 0 (plist-get r :exit)))
          (let* ((out (plist-get r :stdout))
                 (lines (split-string out "\n" t)))
            (should (member "ok" lines))
            (should (member (concat "HOME=" harness-sandbox--home) lines))
            ;; Nothing from the real home directory shows up: not the
            ;; empty sandbox home, not a listing of the real path.
            (let ((real-entries (directory-files home nil "\\`[^.]" t)))
              ;; An empty real home (a temp HOME) has nothing to leak.
              (when real-entries
                (should-not (cl-intersection real-entries lines :test #'equal)))
              (should (cl-some (lambda (l) (string-match-p "cannot access\\|No such file" l)) lines)))
            ;; The cwd itself is writable.
            (should (file-exists-p (expand-file-name "outside-test" cwd)))))
      (delete-directory cwd t))))

;;;; Git worktrees

(defun harness-sandbox-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure, return stdout."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string)))
      (buffer-string))))

(defun harness-sandbox-test--worktree ()
  "Make a repository with an identity and a linked worktree; return (ROOT . WT)."
  (let* ((base (harness-test-temp-dir))
         (root (file-name-as-directory (expand-file-name "repo" base)))
         (wt (file-name-as-directory (expand-file-name "wt" base))))
    (make-directory root t)
    (harness-sandbox-test--git root "init" "-q" "-b" "main")
    (harness-sandbox-test--git root "config" "user.name" "Sandbox Test")
    (harness-sandbox-test--git root "config" "user.email" "sandbox@example.invalid")
    (harness-sandbox-test--git root "config" "commit.gpgsign" "false")
    (with-temp-file (expand-file-name "README" root) (insert "hi\n"))
    (harness-sandbox-test--git root "add" "README")
    (harness-sandbox-test--git root "commit" "-q" "-m" "initial")
    (harness-sandbox-test--git root "worktree" "add" "-q" "-b" "work" wt)
    (cons root wt)))

(ert-deftest harness-sandbox-worktree-git-mounts ()
  "A worktree's git directory is writable but its hooks and config are not."
  (harness-sandbox-test--setup)
  (let* ((repo (harness-sandbox-test--worktree))
         (common (directory-file-name (expand-file-name ".git" (car repo))))
         (harness-sandbox-policy 'preferred)
         (harness-sandbox-backend 'auto))
    (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
      (let ((cmd (harness-call 'sandbox/wrap (cdr repo) '("true"))))
        (should (harness-sandbox-test--subseq-p (list "--bind" common common) cmd))
        (should (harness-sandbox-test--subseq-p (list "--ro-bind" (concat common "/hooks") (concat common "/hooks")) cmd))
        (should (harness-sandbox-test--subseq-p (list "--ro-bind" (concat common "/config") (concat common "/config")) cmd))
        ;; Read-only binds come after the writable one, so they win.
        (should (< (cl-position (concat common "/hooks") cmd :test #'equal)
                   (cl-position "--unshare-pid" cmd :test #'equal)))
        (should (harness-sandbox-test--subseq-p '("--setenv" "GIT_AUTHOR_NAME" "Sandbox Test") cmd))
        (should (harness-sandbox-test--subseq-p '("--setenv" "GIT_COMMITTER_EMAIL" "sandbox@example.invalid") cmd)))
      ;; A main checkout needs nothing extra: its .git is inside the cwd.
      (should-not (member common (harness-call 'sandbox/wrap (car repo) '("true")))))
    (harness-sandbox-test-with-executables '(("systemd-run" . "/usr/bin/systemd-run"))
      (let ((cmd (harness-call 'sandbox/wrap (cdr repo) '("true"))))
        (should (member (concat "BindPaths=" common) cmd))
        (should (member (concat "BindReadOnlyPaths=" common "/hooks") cmd))))))

(ert-deftest harness-sandbox-bwrap-real-run-worktree-commit ()
  "Under the real bwrap, git commits in a worktree but cannot plant a hook."
  (harness-sandbox-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (let* ((repo (harness-sandbox-test--worktree))
         (wt (cdr repo))
         (hook (expand-file-name ".git/hooks/post-merge" (car repo)))
         (harness-sandbox-policy 'required)
         (cmd (harness-call 'sandbox/wrap wt
                            (list "sh" "-c"
                                  (format "echo change > f && git add f && git -c commit.gpgsign=false commit -q -m inside && echo committed; echo x > %s 2>/dev/null || echo hook-refused"
                                          hook))))
         (r (harness-await (harness-run-command cmd :cwd wt :timeout 20))))
    (when (and (not (eql 0 (plist-get r :exit))) (string-match-p "bwrap:" (plist-get r :stderr)))
      (ert-skip (format "bwrap cannot start here: %s" (string-trim (plist-get r :stderr)))))
    (should (string-match-p "committed" (plist-get r :stdout)))
    (should (string-match-p "hook-refused" (plist-get r :stdout)))
    (should-not (file-exists-p hook))
    (should (equal "inside\n" (harness-sandbox-test--git wt "log" "-1" "--format=%s")))
    (should (equal "Sandbox Test\n" (harness-sandbox-test--git wt "log" "-1" "--format=%an")))))

;;;; Refusing git worktree commands

(defmacro harness-sandbox-test-with-worktrees (&rest body)
  "Run BODY in a repository with worktrees, sandboxed by a stand-in bwrap.
Binds `root', `own' (the session's worktree, locked as the harness
locks its worktrees), `other' (another session's, locked too),
`merged' (unlocked, as after its merge), `foreign' (outside the
repository) and `base' (a worktree the session made inside its own)."
  (declare (indent 0))
  `(progn
     (harness-sandbox-test--setup)
     (let* ((tmp (harness-test-temp-dir))
            (root (file-name-as-directory (expand-file-name "repo" tmp)))
            (own (file-name-as-directory (expand-file-name ".worktrees/own" root)))
            (other (file-name-as-directory (expand-file-name ".worktrees/other" root)))
            (merged (file-name-as-directory (expand-file-name ".worktrees/merged" root)))
            (foreign (file-name-as-directory (expand-file-name "foreign" tmp)))
            (base (file-name-as-directory (expand-file-name ".test-logs/base" own)))
            (harness-sandbox-policy 'preferred)
            (harness-sandbox-backend 'auto))
       (ignore merged foreign base)
       (make-directory root t)
       (harness-sandbox-test--git root "init" "-q" "-b" "main")
       (harness-sandbox-test--git root "config" "user.name" "Sandbox Test")
       (harness-sandbox-test--git root "config" "user.email" "sandbox@example.invalid")
       (harness-sandbox-test--git root "config" "commit.gpgsign" "false")
       (harness-sandbox-test--git root "commit" "-q" "--allow-empty" "-m" "initial")
       (harness-sandbox-test--git root "worktree" "add" "-q" "--lock" "--reason" "harness: task/own" "-b" "task/own" own)
       (harness-sandbox-test--git root "worktree" "add" "-q" "--lock" "--reason" "harness: task/other" "-b" "task/other" other)
       (harness-sandbox-test--git root "worktree" "add" "-q" "-b" "task/merged" merged)
       (harness-sandbox-test--git root "worktree" "add" "-q" "-b" "foreign" foreign)
       (harness-sandbox-test--git own "worktree" "add" "-q" "--detach" base)
       (unwind-protect
           (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
             ,@body)
         (harness-sandbox-detect)
         (delete-directory tmp t)))))

(ert-deftest harness-sandbox-refuses-git-worktree-prune ()
  "`git worktree prune' is refused in the sandbox, however it is written."
  (harness-sandbox-test-with-worktrees
    (dolist (command '("git worktree prune"
                       "git worktree prune -v --expire now"
                       "git worktree remove --force .test-logs/base && git worktree prune"
                       "git -C .. worktree prune"
                       "/usr/bin/git --no-pager -c core.quotepath=off worktree prune"
                       "cd sub; git worktree prune 2>&1 | tail"
                       "bash -lc 'git worktree prune'"
                       "sh -c \"cd /tmp && git worktree prune\""
                       "echo $(git worktree prune)"
                       "x=`git worktree prune`"
                       "eval git worktree prune"
                       "env GIT_TRACE=1 timeout 30 git worktree prune"
                       "git -c alias.tidy='worktree prune' tidy"
                       "git -c alias.tidy='!git worktree prune' tidy"
                       "true\ngit worktree prune"))
      (let ((refusal (harness-call 'sandbox/check-command own command own)))
        (should refusal)
        (should (string-match-p "\\``git worktree prune` is refused in the sandbox" (plist-get refusal :reason)))
        (should (string-match-p "worktree/prune" (plist-get refusal :reason)))
        (should (string-match-p "never `git worktree prune`" (plist-get refusal :hint)))))
    ;; The session's own worktree is the default.
    (should (harness-call 'sandbox/check-command own "git worktree prune"))
    ;; Commands that only mention it, and the other worktree commands, run.
    (dolist (command '("git commit -m \"Refuse git worktree prune in the sandbox\""
                       "grep -rn 'git worktree prune' lisp/"
                       "echo git worktree prune # not run"
                       "git log --grep 'worktree prune'"
                       "git worktree list --porcelain"
                       "git worktree add --detach .test-logs/new HEAD"
                       "git worktree lock --reason mine .test-logs/base"))
      (should-not (harness-call 'sandbox/check-command own command own)))))

(ert-deftest harness-sandbox-refuses-touching-other-worktrees ()
  "Unlocking, removing or moving a worktree is refused unless the session made it in its own."
  (harness-sandbox-test-with-worktrees
    (cl-flet ((check (command) (harness-call 'sandbox/check-command own command own)))
      ;; A worktree the session made inside its own may go.
      (dolist (command (list "git worktree remove .test-logs/base"
                             "git worktree remove --force .test-logs/base 2>/dev/null"
                             "git worktree unlock .test-logs/base"
                             (format "git worktree remove %s" base)
                             "git worktree move .test-logs/base .test-logs/moved"
                             "cd .test-logs && git worktree remove -f base"
                             "(cd /tmp); git worktree remove .test-logs/base"
                             ;; By the end of its path, as git allows.
                             "git worktree remove base"))
        (should-not (check command)))
      ;; Not the others, however they are named.
      (dolist (case (list '("git worktree unlock ../other" "outside this session's worktree")
                          '("git worktree unlock other" "outside this session's worktree")
                          (list (format "git worktree remove -f -f %s" other) "outside")
                          '("git -C ../other worktree remove ." "outside")
                          '("git worktree remove 2>/dev/null ../other" "outside")
                          ;; A cd in a subshell or a pipe does not carry on.
                          '("(cd .test-logs); git worktree remove -f -f ../other" "outside")
                          '("cd .test-logs | git worktree remove ../other" "outside")
                          (list (format "git worktree remove %s" foreign) "outside")
                          '("git worktree remove merged" "outside")
                          '("git worktree move ../merged ../elsewhere" "outside")
                          '("git worktree move .test-logs/base /tmp/away" "outside")
                          '("git worktree unlock ." "own worktree")
                          (list (format "git worktree remove %s" own) "own worktree")
                          '("git worktree remove $WT" "cannot be told")
                          '("git worktree remove ~/x" "cannot be told")
                          '("cd - && git worktree remove base2" "cannot be told")
                          '("ls -d .test-logs/* | xargs git worktree remove" "only when it runs")))
        (let ((refusal (check (car case))))
          (should refusal)
          (should (string-match-p (regexp-quote (cadr case)) (plist-get refusal :reason)))
          (should (string-match-p "worktree/prune" (plist-get refusal :reason))))))
    ;; From the main checkout: the worktrees inside it that the harness locked.
    (cl-flet ((check (command) (harness-call 'sandbox/check-command root command root)))
      (should (string-match-p "the harness locked .*other (harness: task/other)"
                              (plist-get (check "git worktree remove .worktrees/other") :reason)))
      (should (check "git worktree unlock other"))
      (should-not (check "git worktree remove .worktrees/merged"))
      (should (check "git worktree remove ../foreign")))))

(ert-deftest harness-sandbox-guard-only-when-confined ()
  "Without the sandbox git sees every worktree, so nothing is refused."
  (harness-sandbox-test-with-worktrees
    (should (harness-call 'sandbox/check-command own "git worktree prune" own))
    (let ((harness-sandbox-policy 'off))
      (should-not (harness-call 'sandbox/check-command own "git worktree prune" own)))
    (should-not (harness-call 'sandbox/check-command "/ssh:example.invalid:/srv/" "git worktree prune"))
    (harness-sandbox-test-with-executables nil
      (should-not (harness-call 'sandbox/check-command own "git worktree prune" own)))))

(ert-deftest harness-sandbox-bwrap-real-prune-keeps-locked-worktrees ()
  "Under the real bwrap, a prune from one worktree drops the unlocked others, never a locked one."
  (harness-sandbox-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (let* ((repo (harness-sandbox-test--worktree))
         (root (car repo))
         (wt (cdr repo))
         (locked (file-name-as-directory (expand-file-name ".worktrees/locked" root)))
         (plain (file-name-as-directory (expand-file-name ".worktrees/plain" root)))
         (harness-sandbox-policy 'required))
    (harness-sandbox-test--git root "worktree" "add" "-q" "--lock" "--reason" "harness: locked" "-b" "locked" locked)
    (harness-sandbox-test--git root "worktree" "add" "-q" "-b" "plain" plain)
    ;; The guard refuses it ...
    (should (harness-call 'sandbox/check-command wt "git worktree prune -v"))
    ;; ... and should it run anyway, the lock keeps the worktree.
    (let ((r (harness-await (harness-run-command (harness-call 'sandbox/wrap wt '("git" "worktree" "prune" "-v"))
                                                 :cwd wt :timeout 20))))
      (when (and (not (eql 0 (plist-get r :exit))) (string-match-p "bwrap:" (plist-get r :stderr)))
        (ert-skip (format "bwrap cannot start here: %s" (string-trim (plist-get r :stderr)))))
      (should (eql 0 (plist-get r :exit)))
      (should (string-match-p "worktrees/plain" (plist-get r :stderr)))
      (should-not (string-match-p "worktrees/locked" (plist-get r :stderr))))
    (should (equal "locked\n" (harness-sandbox-test--git locked "branch" "--show-current")))
    (should-error (harness-sandbox-test--git plain "status"))))

(provide 'harness-sandbox-test)
;;; harness-sandbox-test.el ends here
