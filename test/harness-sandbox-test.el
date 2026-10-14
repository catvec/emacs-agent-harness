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

(defun harness-sandbox-test--binds (cmd)
  "Return the (FLAG SOURCE DEST) bind mounts of bwrap command line CMD, in order."
  (cl-loop for tail on cmd
           when (member (car tail) '("--bind" "--ro-bind"))
           collect (seq-take tail 3)))

(defmacro harness-sandbox-test-with-home (home &rest body)
  "Run BODY with HOME, a fresh directory, as $HOME; delete it afterwards."
  (declare (indent 1))
  `(let* ((,home (harness-test-temp-dir))
          (process-environment (cons (concat "HOME=" (directory-file-name ,home)) process-environment)))
     (unwind-protect (progn ,@body)
       (delete-directory ,home t))))

(ert-deftest harness-sandbox-bwrap-arguments ()
  (harness-sandbox-test--setup)
  (harness-sandbox-test-with-home home
    (let* ((cwd (harness-test-temp-dir))
           (extra (harness-test-temp-dir))
           (harness-sandbox-policy 'preferred)
           (harness-sandbox-backend 'auto)
           (command '("sh" "-c" "true")))
      (with-temp-file (expand-file-name "secret.txt" home) (insert "s3cret\n"))
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
          ;; $HOME keeps its path, emptied by a tmpfs after /tmp's (it
          ;; may lie there) and before every bind.
          (let ((at (cl-loop for tail on cmd for i from 0
                             when (equal (seq-take tail 2) (list "--tmpfs" (directory-file-name home))) return i)))
            (should at)
            (should (< (cl-position "/tmp" cmd :test #'equal) at))
            (should (< at (cl-position "--bind" cmd :test #'equal))))
          ;; The only variable set is the sandbox's marker: $HOME keeps
          ;; its value.
          (should (equal '(("HARNESS_SANDBOX" "bwrap"))
                         (cl-loop for tail on (seq-take-while (lambda (a) (not (equal a "--"))) cmd)
                                  when (equal (car tail) "--setenv")
                                  collect (list (cadr tail) (caddr tail)))))
          ;; Network stays on by default.
          (should-not (member "--unshare-net" cmd))
          ;; Neither home directory is ever a bind's source.
          (should-not (member (directory-file-name home) (mapcar #'cadr (harness-sandbox-test--binds cmd))))
          (should-not (member (harness-test-real-home) cmd))
          ;; The command follows the separator untouched.
          (should (equal command (cdr (member "--" cmd)))))
        ;; Options: network off and extra writable/readable directories.
        (let ((cmd (harness-call 'sandbox/wrap cwd command :network nil :writable (list extra)
                                 :readable (list "/var/empty-nonexistent-dir"))))
          (should (member "--unshare-net" cmd))
          (should (harness-sandbox-test--subseq-p
                   (list "--bind" (directory-file-name extra) (directory-file-name extra)) cmd))
          ;; Missing readable directories are silently skipped.
          (should-not (member "/var/empty-nonexistent-dir" cmd)))
        ;; A $HOME no tmpfs may cover, or none, gives way to a home of
        ;; the sandbox's own.
        (dolist (value '("HOME=/" "HOME=/usr" "HOME=/etc/x" "HOME=relative" "HOME"))
          (let* ((process-environment (cons value process-environment))
                 (cmd (harness-call 'sandbox/wrap cwd command)))
            (should (harness-sandbox-test--subseq-p (list "--dir" harness-sandbox--home) cmd))
            (should (harness-sandbox-test--subseq-p (list "--setenv" "HOME" harness-sandbox--home) cmd))
            (should-not (cl-loop for tail on cmd thereis (and (equal (car tail) "--tmpfs")
                                                              (not (equal (cadr tail) "/tmp"))))))))
      ;; Restore the real detection for later tests.
      (harness-sandbox-detect)
      (delete-directory cwd t)
      (delete-directory extra t))))

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
        ;; The command can tell it runs confined.
        (should (member "--setenv=HARNESS_SANDBOX=systemd"
                        (seq-take-while (lambda (a) (not (equal a "--"))) cmd)))
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
  "Run a command under the real bwrap and check the real HOME is unreachable.
$HOME keeps its path in there, but shows nothing of what it holds, and
nothing written there reaches it."
  (harness-sandbox-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  ;; A home of the test's own with a file in it, so the check does not
  ;; depend on what, if anything, the process's own home holds.
  (harness-sandbox-test-with-home home
    (let* ((cwd (harness-test-temp-dir))
           (harness-sandbox-policy 'required))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "secret-in-real-home" home)
              (insert "must not show\n"))
            (let* ((cmd (harness-call 'sandbox/wrap cwd
                                      (list "sh" "-c" (format "echo HOME=$HOME; echo SANDBOX=$HARNESS_SANDBOX; ls -A $HOME; cat %ssecret-in-real-home 2>&1; touch ~/left-behind 2>&1; touch outside-test 2>&1 || true; echo ok" home))))
                   (r (harness-await (harness-run-command cmd :cwd cwd :timeout 20))))
              (when (and (not (eql 0 (plist-get r :exit)))
                         (string-match-p "bwrap:" (plist-get r :stderr)))
                (ert-skip (format "bwrap cannot start in this environment: %s"
                                  (string-trim (plist-get r :stderr)))))
              (should (eql 0 (plist-get r :exit)))
              (let* ((out (plist-get r :stdout))
                     (lines (split-string out "\n" t)))
                (should (member "ok" lines))
                (should (member (concat "HOME=" (directory-file-name home)) lines))
                ;; The command can tell it runs confined.
                (should (member "SANDBOX=bwrap" lines))
                ;; Nothing from the real home directory shows up, and the
                ;; file in it cannot be read.
                (let ((real-entries (directory-files home nil "\\`[^.]" t)))
                  (should real-entries)
                  (should-not (cl-intersection real-entries lines :test #'equal))
                  (should-not (string-search "must not show" out))
                  (should (cl-some (lambda (l) (string-match-p "No such file" l)) lines)))
                ;; What a command leaves in $HOME stays in the sandbox.
                (should-not (file-exists-p (expand-file-name "left-behind" home)))
                ;; The cwd itself is writable.
                (should (file-exists-p (expand-file-name "outside-test" cwd))))))
        (delete-directory cwd t)))))

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
        (should (harness-sandbox-test--subseq-p (list "--ro-bind" (concat common "/index") (concat common "/index")) cmd))
        (should (harness-sandbox-test--subseq-p (list "--ro-bind" (concat common "/HEAD") (concat common "/HEAD")) cmd))
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

(ert-deftest harness-sandbox-bwrap-real-run-main-index-read-only ()
  "Under the real bwrap, git in a worktree cannot change the main checkout's index.
The main checkout's files are not in the sandbox, so git there sees them
all deleted; staging anything would wreck its index."
  (harness-sandbox-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (let* ((repo (harness-sandbox-test--worktree))
         (root (car repo))
         (wt (cdr repo))
         (harness-sandbox-policy 'required)
         (cmd (harness-call 'sandbox/wrap wt
                            (list "sh" "-c"
                                  (format "git -C %s rm -q --cached README 2>/dev/null && echo staged || echo index-refused; echo change > f && git add f && git -c commit.gpgsign=false commit -q -m inside && echo committed"
                                          (shell-quote-argument root)))))
         (r (harness-await (harness-run-command cmd :cwd wt :timeout 20))))
    (when (and (not (eql 0 (plist-get r :exit))) (string-match-p "bwrap:" (plist-get r :stderr)))
      (ert-skip (format "bwrap cannot start here: %s" (string-trim (plist-get r :stderr)))))
    (should (string-match-p "index-refused" (plist-get r :stdout)))
    (should (string-match-p "committed" (plist-get r :stdout)))
    (should (string-empty-p (harness-sandbox-test--git root "status" "--porcelain")))))

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

;;;; Directories shown read-only

(defun harness-sandbox-test--write (file text)
  "Write TEXT to FILE, making its directory."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert text)))

(defun harness-sandbox-test--call-with-skills (fn)
  "Call FN with (HOME SKILLS DOTFILES OTHER) under a home of the test's own.
HOME, which $HOME names while FN runs, holds the skills directory
SKILLS (~/.claude/skills) with a skill of its own, commit, and two
linked in from DOTFILES (~/dotfiles), linked by an absolute link and
rel by a relative one.  ~/.agents/skills links to OTHER, outside HOME.
HOME also holds secret.txt."
  (let* ((home (harness-test-temp-dir))
         (process-environment (cons (concat "HOME=" (directory-file-name home)) process-environment))
         (skills (file-name-as-directory (expand-file-name ".claude/skills" home)))
         (dotfiles (file-name-as-directory (expand-file-name "dotfiles" home)))
         (other (harness-test-temp-dir)))
    (harness-sandbox-test--write (expand-file-name "commit/SKILL.md" skills) "commit-skill\n")
    (harness-sandbox-test--write (expand-file-name "linked/SKILL.md" dotfiles) "linked-skill\n")
    (harness-sandbox-test--write (expand-file-name "rel/SKILL.md" dotfiles) "rel-skill\n")
    (harness-sandbox-test--write (expand-file-name "agents/SKILL.md" other) "agents-skill\n")
    (harness-sandbox-test--write (expand-file-name "secret.txt" home) "s3cret\n")
    (make-symbolic-link (directory-file-name (expand-file-name "linked" dotfiles)) (expand-file-name "linked" skills))
    (make-symbolic-link "../../dotfiles/rel" (expand-file-name "rel" skills))
    (make-directory (expand-file-name ".agents" home))
    (make-symbolic-link (directory-file-name other) (expand-file-name ".agents/skills" home))
    (unwind-protect (funcall fn home skills dotfiles other)
      (delete-directory home t)
      (delete-directory other t))))

(ert-deftest harness-sandbox-readable-dirs-show-where-they-are-named ()
  "A readable directory is shown read-only where it is named, where its
links lead and, for one under the home directory, at the same place
under the sandbox's $HOME, before the working directory is mounted.
Never the home directory itself, nor what the working directory shows
anyway; and no mount below another one, where bwrap would find a link."
  (harness-sandbox-test--setup)
  (harness-sandbox-test--call-with-skills
   (lambda (home skills dotfiles other)
     (let* ((cwd (harness-test-temp-dir))
            (harness-sandbox--home "/tmp/harness-sandbox-test-home")
            (harness-sandbox-policy 'preferred)
            (harness-sandbox-backend 'auto)
            (real (lambda (dir) (directory-file-name (file-truename dir))))
            (sbh (lambda (rel) (concat "/tmp/harness-sandbox-test-home/" rel)))
            (readable (list skills (expand-file-name "linked/" skills) (expand-file-name "rel/" skills)
                            (expand-file-name ".agents/skills" home)
                            ;; Shown read-write anyway.
                            (expand-file-name ".claude/skills" cwd)
                            ;; The home directory, and what holds it.
                            home (file-name-directory (directory-file-name home))
                            "/var/empty-nonexistent-dir")))
       (unwind-protect
           (progn
             (make-directory (expand-file-name ".claude/skills" cwd) t)
             (should (equal
                      (list (cons (funcall real skills) (directory-file-name skills))
                            (cons (funcall real skills) (funcall sbh ".claude/skills"))
                            (cons (funcall real (expand-file-name "linked" dotfiles)) (funcall real (expand-file-name "linked" dotfiles)))
                            (cons (funcall real (expand-file-name "linked" dotfiles)) (funcall sbh "dotfiles/linked"))
                            (cons (funcall real (expand-file-name "rel" dotfiles)) (funcall real (expand-file-name "rel" dotfiles)))
                            (cons (funcall real (expand-file-name "rel" dotfiles)) (funcall sbh "dotfiles/rel"))
                            (cons (funcall real other) (expand-file-name ".agents/skills" home))
                            (cons (funcall real other) (funcall real other))
                            (cons (funcall real other) (funcall sbh ".agents/skills")))
                      (harness-sandbox--readable-mounts readable cwd harness-sandbox--home)))
             ;; Without a home of its own, nothing is shown under one.
             (should-not (cl-find-if (lambda (m) (string-prefix-p "/tmp/harness-sandbox-test-home" (cdr m)))
                                     (harness-sandbox--readable-mounts readable cwd nil)))
             ;; A directory holding a working directory reached through a
             ;; link is not shown: the working directory is mounted where
             ;; it is named, which would be a link in there.
             (let ((work (expand-file-name "commit/work" skills)))
               (make-symbolic-link (directory-file-name cwd) work)
               (should-not (rassoc (directory-file-name skills) (harness-sandbox--readable-mounts readable work harness-sandbox--home)))
               (should (rassoc (directory-file-name skills) (harness-sandbox--readable-mounts readable cwd harness-sandbox--home)))
               (delete-file work))
             ;; bwrap keeps $HOME's path, so it needs no second place.
             (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
               (let* ((cmd (harness-call 'sandbox/wrap cwd '("true") :readable readable))
                      (bind (cl-position "--bind" cmd :test #'equal)))
                 (should (equal (mapcar (lambda (m) (list "--ro-bind" (car m) (cdr m)))
                                        (harness-sandbox--readable-mounts readable cwd nil))
                                (cl-remove-if (lambda (b) (member (cadr b) '("/usr" "/etc" "/lib" "/lib64" "/bin" "/sbin")))
                                              (harness-sandbox-test--binds (seq-take cmd bind)))))
                 (should (equal (list "--bind" (directory-file-name cwd) (directory-file-name cwd)) (seq-take (nthcdr bind cmd) 3)))
                 (should-not (cl-find-if (lambda (a) (string-prefix-p "/tmp/harness-sandbox-test-home" a)) cmd))
                 (should-not (member (directory-file-name home) (mapcar #'cadr (harness-sandbox-test--binds cmd))))
                 (should-not (member (harness-test-real-home) cmd))
                 (should-not (member "/var/empty-nonexistent-dir" cmd)))))
         (harness-sandbox-detect)
         (delete-directory cwd t))))))

(ert-deftest harness-sandbox-systemd-shows-readable-dirs ()
  "systemd-run shows a readable directory with BindReadOnlyPaths, under
its home tmpfs at /tmp too, and leaves out what its setting cannot
hold as written."
  (harness-sandbox-test--setup)
  (harness-sandbox-test--call-with-skills
   (lambda (home skills _dotfiles other)
     (let* ((cwd (harness-test-temp-dir))
            (elsewhere (harness-test-temp-dir))
            (spaced (file-name-as-directory (expand-file-name "with space/skills" elsewhere)))
            (harness-sandbox-policy 'preferred)
            (harness-sandbox-backend 'auto)
            (real (lambda (dir) (directory-file-name (file-truename dir)))))
       (unwind-protect
           (progn
             (make-directory spaced t)
             (harness-sandbox-test-with-executables '(("systemd-run" . "/usr/bin/systemd-run"))
               (let ((cmd (harness-call 'sandbox/wrap cwd '("true")
                                        :readable (list skills (expand-file-name ".agents/skills" home) spaced home))))
                 (dolist (setting (list (concat "BindReadOnlyPaths=" (funcall real skills))
                                        (concat "BindReadOnlyPaths=" (funcall real skills) ":/tmp/.claude/skills")
                                        (concat "BindReadOnlyPaths=" (funcall real other) ":" (expand-file-name ".agents/skills" home))
                                        (concat "BindReadOnlyPaths=" (funcall real other))
                                        (concat "BindReadOnlyPaths=" (funcall real other) ":/tmp/.agents/skills")))
                   (should (harness-sandbox-test--subseq-p (list "-p" setting) cmd)))
                 (should-not (cl-find-if (lambda (a) (string-search "with space" a)) cmd))
                 (should-not (member (concat "BindReadOnlyPaths=" (directory-file-name home)) cmd))
                 (should (member "--setenv=HOME=/tmp" cmd)))))
         (harness-sandbox-detect)
         (delete-directory cwd t)
         (delete-directory elsewhere t))))))

(ert-deftest harness-sandbox-readable-files-are-shown-read-only ()
  "A readable file is shown read-only where it is named, as a readable
directory is, and its directory is not; a missing one is left out."
  (harness-sandbox-test--setup)
  (harness-sandbox-test-with-home home
    (ignore home)
    (let* ((cwd (harness-test-temp-dir))
           (dir (harness-test-temp-dir))
           (file (expand-file-name "shown.el" dir))
           (path (directory-file-name (file-truename file)))
           (harness-sandbox-policy 'preferred)
           (harness-sandbox-backend 'auto))
      (harness-sandbox-test--write file ";; shown\n")
      (unwind-protect
          (progn
            (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
              (let ((cmd (harness-call 'sandbox/wrap cwd '("true")
                                       :readable (list file (expand-file-name "missing.el" dir)))))
                (should (harness-sandbox-test--subseq-p (list "--ro-bind" path path) cmd))
                (should-not (member (directory-file-name dir) cmd))
                (should-not (cl-find-if (lambda (a) (string-search "missing.el" a)) cmd))))
            (harness-sandbox-test-with-executables '(("systemd-run" . "/usr/bin/systemd-run"))
              (should (harness-sandbox-test--subseq-p
                       (list "-p" (concat "BindReadOnlyPaths=" path))
                       (harness-call 'sandbox/wrap cwd '("true") :readable (list file))))))
        (harness-sandbox-detect)
        (delete-directory cwd t)
        (delete-directory dir t)))))

(ert-deftest harness-sandbox-bwrap-real-run-readable-file ()
  "Under the real bwrap a readable file reads but cannot be written, and
the other files of its directory do not show."
  (harness-sandbox-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (let* ((cwd (harness-test-temp-dir))
         (dir (harness-test-temp-dir))
         (file (expand-file-name "shown.el" dir))
         (harness-sandbox-policy 'required)
         (script (format "cat %s; cat %s 2>/dev/null || echo sibling-hidden; { echo x >> %s; } 2>/dev/null && echo file-written || echo file-refused"
                         (shell-quote-argument file)
                         (shell-quote-argument (expand-file-name "sibling.txt" dir))
                         (shell-quote-argument file))))
    (harness-sandbox-test--write file "shown\n")
    (harness-sandbox-test--write (expand-file-name "sibling.txt" dir) "hidden\n")
    (unwind-protect
        (let ((probe (harness-await (harness-run-command (harness-call 'sandbox/wrap cwd '("true"))
                                                         :cwd cwd :timeout 20))))
          (unless (eql 0 (plist-get probe :exit))
            (ert-skip (format "bwrap cannot start here: %s" (string-trim (plist-get probe :stderr)))))
          (let* ((cmd (harness-call 'sandbox/wrap cwd (list "sh" "-c" script) :readable (list file)))
                 (r (harness-await (harness-run-command cmd :cwd cwd :timeout 20))))
            (should (equal "shown\nsibling-hidden\nfile-refused\n" (plist-get r :stdout)))
            (should (equal "shown\n" (with-temp-buffer (insert-file-contents file) (buffer-string))))))
      (delete-directory cwd t)
      (delete-directory dir t))))

(ert-deftest harness-sandbox-confined-p-says-when-commands-are-confined ()
  "`sandbox/confined-p' is non-nil where a backend wraps the commands."
  (harness-sandbox-test--setup)
  (let ((cwd (harness-test-temp-dir))
        (harness-sandbox-backend 'auto))
    (unwind-protect
        (progn
          (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
            (let ((harness-sandbox-policy 'preferred))
              (should (harness-call 'sandbox/confined-p cwd))
              (should-not (harness-call 'sandbox/confined-p "/ssh:example.invalid:/srv/"))
              (should-not (harness-call 'sandbox/confined-p nil)))
            (let ((harness-sandbox-policy 'off))
              (should-not (harness-call 'sandbox/confined-p cwd))))
          (harness-sandbox-test-with-executables nil
            (let ((harness-sandbox-policy 'preferred))
              (should-not (harness-call 'sandbox/confined-p cwd)))))
      (harness-sandbox-detect)
      (delete-directory cwd t))))

(ert-deftest harness-sandbox-bwrap-real-run-reads-skills ()
  "Under the real bwrap a command reads the skills directories it is
shown, by their own names, through their links and from ~, and writes
none of them, while the rest of the home directory stays hidden."
  (harness-sandbox-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (harness-sandbox-test--call-with-skills
   (lambda (home skills _dotfiles _other)
     (let* ((cwd (harness-test-temp-dir))
            (harness-sandbox-policy 'required)
            (script (mapconcat
                     #'identity
                     (list (format "cat %scommit/SKILL.md ~/.claude/skills/commit/SKILL.md" skills)
                           (format "cat %slinked/SKILL.md ~/.claude/skills/linked/SKILL.md" skills)
                           (format "cat %srel/SKILL.md ~/.claude/skills/rel/SKILL.md" skills)
                           "cat ~/.agents/skills/agents/SKILL.md"
                           (format "cat %s 2>/dev/null || echo secret-hidden" (expand-file-name "secret.txt" home))
                           (format "touch %snew 2>/dev/null && echo wrote || echo write-refused" skills)
                           "touch ~/.claude/skills/new 2>/dev/null && echo wrote || echo write-refused"
                           "touch made-here && echo cwd-writable")
                     "; ")))
       (unwind-protect
           (let ((probe (harness-await (harness-run-command (harness-call 'sandbox/wrap cwd '("true"))
                                                            :cwd cwd :timeout 20))))
             ;; Skipped only when bwrap cannot start at all: a mount it
             ;; refuses here is a failure.
             (unless (eql 0 (plist-get probe :exit))
               (ert-skip (format "bwrap cannot start here: %s" (string-trim (plist-get probe :stderr)))))
             (let* ((cmd (harness-call 'sandbox/wrap cwd (list "sh" "-c" script)
                                       :readable (list skills (expand-file-name "linked/" skills) (expand-file-name "rel/" skills)
                                                       (expand-file-name ".agents/skills" home))))
                    (r (harness-await (harness-run-command cmd :cwd cwd :timeout 20))))
               (should (equal "" (plist-get r :stderr)))
               (should (equal '("commit-skill" "commit-skill" "linked-skill" "linked-skill" "rel-skill" "rel-skill"
                                "agents-skill" "secret-hidden" "write-refused" "write-refused" "cwd-writable")
                              (split-string (plist-get r :stdout) "\n" t)))
               (should-not (file-exists-p (expand-file-name "new" skills)))
               (should (file-exists-p (expand-file-name "made-here" cwd)))))
         (delete-directory cwd t))))))

;;;; Directories shown read-write: what a session was granted

(ert-deftest harness-sandbox-writable-dirs-show-where-they-are-named ()
  "A writable directory or file is shown read-write where it is named and
where its links lead, after the read-only mounts, which may hold it.
One named both ways is writable, a read-only one inside a writable one
goes, the home directory shows when it is granted itself, and neither
the root directory nor what the working directory holds is mounted.
systemd-run shows them under its $HOME, /tmp, too."
  (harness-sandbox-test--setup)
  (harness-sandbox-test-with-home home
    (let* ((cwd (harness-test-temp-dir))
           (outside (harness-test-temp-dir))
           (real (lambda (p) (directory-file-name (file-truename p))))
           (granted (file-name-as-directory (expand-file-name "granted" home)))
           (linked (expand-file-name "linked" home))
           (file (expand-file-name "notes.txt" home))
           (claude (file-name-as-directory (expand-file-name ".claude" home)))
           (skills (file-name-as-directory (expand-file-name "skills" claude)))
           (mine (file-name-as-directory (expand-file-name "mine" skills)))
           (harness-sandbox-policy 'preferred)
           (harness-sandbox-backend 'auto))
      (make-directory granted t)
      (make-directory mine t)
      (make-directory (expand-file-name "sub" cwd))
      (make-symbolic-link (directory-file-name outside) linked)
      (with-temp-file file (insert "notes\n"))
      (unwind-protect
          (let ((expected (list (list 'ro (funcall real skills) (funcall real skills))
                                (list 'rw (funcall real granted) (funcall real granted))
                                (list 'rw (funcall real outside) linked)
                                (list 'rw (funcall real outside) (funcall real outside))
                                (list 'rw (funcall real file) (funcall real file))
                                (list 'rw (funcall real mine) (funcall real mine)))))
            (should (equal expected
                           (harness-sandbox--mounts (list skills)
                                                    (list granted linked file mine "/" "/nonexistent/x"
                                                          (expand-file-name "sub" cwd))
                                                    cwd nil)))
            ;; Named both ways: writable, once.
            (should (equal (list (list 'rw (funcall real granted) (funcall real granted)))
                           (harness-sandbox--mounts (list granted) (list granted) cwd nil)))
            ;; A read-only directory inside a writable one shows through it.
            (should (equal (list (list 'rw (funcall real claude) (funcall real claude)))
                           (harness-sandbox--mounts (list skills) (list claude) cwd nil)))
            ;; The home directory: granted, it shows; read-only, never.
            (should (equal (list (list 'rw (funcall real home) (funcall real home)))
                           (harness-sandbox--mounts nil (list home) cwd nil)))
            (should-not (harness-sandbox--mounts (list home) nil cwd nil))
            ;; Under a $HOME of the sandbox's own, at the same place too.
            (should (equal (list (list 'rw (funcall real granted) (funcall real granted))
                                 (list 'rw (funcall real granted) "/tmp/granted"))
                           (harness-sandbox--mounts nil (list granted) cwd "/tmp")))
            (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
              (let* ((cmd (harness-call 'sandbox/wrap cwd '("true") :readable (list skills)
                                        :writable (list granted linked file mine)))
                     (binds (harness-sandbox-test--binds cmd)))
                ;; In that order, the working directory last.
                (should (harness-sandbox-test--subseq-p
                         (append (mapcar (lambda (m) (list (if (eq (car m) 'rw) "--bind" "--ro-bind") (nth 1 m) (nth 2 m)))
                                         expected)
                                 (list (list "--bind" (directory-file-name cwd) (directory-file-name cwd))))
                         binds))
                ;; After the tmpfs that empties the home directory.
                (should (< (cl-position (directory-file-name home) cmd :test #'equal)
                           (cl-position (funcall real granted) cmd :test #'equal)))))
            (harness-sandbox-test-with-executables '(("systemd-run" . "/usr/bin/systemd-run"))
              (let ((cmd (harness-call 'sandbox/wrap cwd '("true") :writable (list granted linked))))
                (dolist (setting (list (concat "BindPaths=" (funcall real granted))
                                       (concat "BindPaths=" (funcall real granted) ":/tmp/granted")
                                       (concat "BindPaths=" (funcall real outside) ":" linked)
                                       (concat "BindPaths=" (funcall real outside))
                                       (concat "BindPaths=" (funcall real outside) ":/tmp/linked")))
                  (should (harness-sandbox-test--subseq-p (list "-p" setting) cmd))))))
        (harness-sandbox-detect)
        (delete-directory cwd t)
        (delete-directory outside t)))))

(ert-deftest harness-sandbox-bwrap-real-run-shows-grants ()
  "Under the real bwrap a directory granted to the session is there,
read-write, at its own path and from ~, wherever the command runs,
while the rest of the home directory stays hidden.  Bash used to see
none of them: a grant reached every tool but the sandbox, whose $HOME
was somewhere else."
  (harness-sandbox-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (harness-sandbox-test-with-home home
    (let* ((cwd (harness-test-temp-dir))
           (granted (file-name-as-directory (expand-file-name ".emacs.d/modules" home)))
           (harness-sandbox-policy 'required)
           (script (mapconcat
                    #'identity
                    (list (format "cat %snote.txt" granted)
                          "cat ~/.emacs.d/modules/note.txt"
                          "ls -A ~ ~/.emacs.d"
                          "cat ~/secret.txt 2>/dev/null || echo secret-hidden"
                          "ls ~/.emacs.d/init.el 2>/dev/null || echo sibling-hidden"
                          "echo made > ~/.emacs.d/modules/made.txt && echo granted-writable")
                    "; ")))
      (harness-sandbox-test--write (expand-file-name "note.txt" granted) "granted-note\n")
      (harness-sandbox-test--write (expand-file-name ".emacs.d/init.el" home) ";; init\n")
      (harness-sandbox-test--write (expand-file-name "secret.txt" home) "s3cret\n")
      (unwind-protect
          (let ((probe (harness-await (harness-run-command (harness-call 'sandbox/wrap cwd '("true"))
                                                           :cwd cwd :timeout 20))))
            ;; Skipped only when bwrap cannot start at all: a mount it
            ;; refuses here is a failure.
            (unless (eql 0 (plist-get probe :exit))
              (ert-skip (format "bwrap cannot start here: %s" (string-trim (plist-get probe :stderr)))))
            (let* ((cmd (harness-call 'sandbox/wrap cwd (list "sh" "-c" script) :writable (list granted)))
                   (r (harness-await (harness-run-command cmd :cwd cwd :timeout 20))))
              (should (equal "" (plist-get r :stderr)))
              (should (equal (list "granted-note" "granted-note"
                                   (concat (directory-file-name home) ":") ".emacs.d"
                                   (concat (directory-file-name home) "/.emacs.d:") "modules"
                                   "secret-hidden" "sibling-hidden" "granted-writable")
                             (split-string (plist-get r :stdout) "\n" t)))
              (should (equal "made\n" (with-temp-buffer
                                        (insert-file-contents (expand-file-name "made.txt" granted))
                                        (buffer-string))))))
        (delete-directory cwd t)))))

;;;; Read-only commands

(defun harness-sandbox-test--rw-binds (cmd)
  "Return the writable bind mounts of bwrap command line CMD."
  (cl-remove-if-not (lambda (bind) (equal (car bind) "--bind")) (harness-sandbox-test--binds cmd)))

(ert-deftest harness-sandbox-read-only-bwrap-arguments ()
  "With :read-only the working directory and the writable mounts are read-only."
  (harness-sandbox-test--setup)
  (harness-sandbox-test-with-home home
    (let* ((cwd (harness-test-temp-dir))
           (extra (harness-test-temp-dir))
           (cwd-bind (directory-file-name cwd))
           (extra-bind (directory-file-name extra))
           (harness-sandbox-policy 'preferred)
           (harness-sandbox-backend 'auto)
           (command '("sh" "-c" "true")))
      (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
        ;; Read-write as before when it is not asked for, and for a JSON false.
        (dolist (opts '(nil (:read-only nil) (:read-only :false)))
          (let ((cmd (apply #'harness-call 'sandbox/wrap cwd command :writable (list extra) opts)))
            (should (harness-sandbox-test--subseq-p (list "--bind" cwd-bind cwd-bind) cmd))
            (should (harness-sandbox-test--subseq-p (list "--bind" extra-bind extra-bind) cmd))))
        (let ((cmd (harness-call 'sandbox/wrap cwd command :writable (list extra) :read-only t)))
          (should (equal "/usr/bin/bwrap" (car cmd)))
          ;; No mount of the file system is writable: the working
          ;; directory and the granted one are bound read-only.
          (should (harness-sandbox-test--subseq-p (list "--ro-bind" cwd-bind cwd-bind) cmd))
          (should (harness-sandbox-test--subseq-p (list "--ro-bind" extra-bind extra-bind) cmd))
          (should-not (harness-sandbox-test--rw-binds cmd))
          (should-not (member "--bind" cmd))
          ;; What the command writes goes to the sandbox's private /tmp.
          (should (harness-sandbox-test--subseq-p '("--tmpfs" "/tmp") cmd))
          ;; The working directory is still mounted last, over the others.
          (should (equal (list "--ro-bind" cwd-bind cwd-bind)
                         (car (last (harness-sandbox-test--binds cmd)))))
          (dolist (flag '("--unshare-pid" "--unshare-ipc" "--unshare-uts" "--die-with-parent" "--new-session"))
            (should (member flag cmd)))
          (should (harness-sandbox-test--subseq-p (list "--chdir" cwd-bind) cmd))
          (should (equal command (cdr (member "--" cmd)))))
        ;; The other options go on working.
        (let ((cmd (harness-call 'sandbox/wrap cwd command :read-only t :network nil
                                 :readable (list extra))))
          (should (member "--unshare-net" cmd))
          (should-not (harness-sandbox-test--rw-binds cmd))
          (should (harness-sandbox-test--subseq-p (list "--ro-bind" extra-bind extra-bind) cmd)))
        ;; Granted directories that hold the working directory, and the
        ;; one inside it, are read-only too.
        (let* ((inner (file-name-as-directory (expand-file-name "inner" cwd)))
               (cmd (progn (make-directory inner)
                           (harness-call 'sandbox/wrap inner command
                                         :writable (list cwd) :read-only t))))
          (should (harness-sandbox-test--subseq-p
                   (list "--ro-bind" cwd-bind cwd-bind) cmd))
          (should-not (harness-sandbox-test--rw-binds cmd))
          (should (equal (list "--ro-bind" (directory-file-name inner) (directory-file-name inner))
                         (car (last (harness-sandbox-test--binds cmd)))))))
      (harness-sandbox-detect)
      (delete-directory cwd t)
      (delete-directory extra t))))

(ert-deftest harness-sandbox-read-only-systemd-arguments ()
  "With :read-only systemd binds read-only, sets no ReadWritePaths= and protects the rest."
  (harness-sandbox-test--setup)
  (let* ((cwd (harness-test-temp-dir))
         (extra (harness-test-temp-dir))
         (cwd-path (directory-file-name cwd))
         (extra-path (directory-file-name extra))
         (harness-sandbox-policy 'preferred)
         (harness-sandbox-backend 'auto)
         (command '("sh" "-c" "true")))
    (harness-sandbox-test-with-executables '(("systemd-run" . "/usr/bin/systemd-run"))
      (let ((cmd (harness-call 'sandbox/wrap cwd command :writable (list extra))))
        (should (member (concat "BindPaths=" cwd-path) cmd))
        (should (member (concat "ReadWritePaths=" cwd-path) cmd))
        (should (member (concat "BindPaths=" extra-path) cmd))
        (should-not (member "ProtectSystem=strict" cmd)))
      (let ((cmd (harness-call 'sandbox/wrap cwd command :writable (list extra) :read-only t)))
        (should (equal "/usr/bin/systemd-run" (car cmd)))
        (should (harness-sandbox-test--subseq-p (list "-p" (concat "BindReadOnlyPaths=" cwd-path)) cmd))
        (should (harness-sandbox-test--subseq-p (list "-p" (concat "BindReadOnlyPaths=" extra-path)) cmd))
        (should (harness-sandbox-test--subseq-p '("-p" "ProtectSystem=strict") cmd))
        (should (harness-sandbox-test--subseq-p '("-p" "PrivateTmp=yes") cmd))
        (should (harness-sandbox-test--subseq-p '("-p" "ProtectHome=tmpfs") cmd))
        ;; Nothing is made writable.
        (should-not (cl-some (lambda (a) (string-match-p "\\`\\(BindPaths\\|ReadWritePaths\\)=" a)) cmd))
        (should (member (concat "--working-directory=" cwd-path) cmd))
        (should-not (member "PrivateNetwork=yes" cmd))
        (should (equal command (cdr (member "--" cmd)))))
      (should (harness-sandbox-test--subseq-p
               '("-p" "PrivateNetwork=yes")
               (harness-call 'sandbox/wrap cwd command :read-only t :network nil))))
    (harness-sandbox-detect)
    (delete-directory cwd t)
    (delete-directory extra t)))

(ert-deftest harness-sandbox-read-only-shows-the-git-directory-read-only ()
  "A worktree's git directory is read-only whole, with no overlay on its hooks."
  (harness-sandbox-test--setup)
  (let* ((repo (harness-sandbox-test--worktree))
         (wt (cdr repo))
         (wt-path (directory-file-name wt))
         (common (directory-file-name (expand-file-name ".git" (car repo))))
         (harness-sandbox-policy 'preferred)
         (harness-sandbox-backend 'auto))
    (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
      (let ((cmd (harness-call 'sandbox/wrap wt '("true") :read-only t)))
        (should (harness-sandbox-test--subseq-p (list "--ro-bind" common common) cmd))
        (should (harness-sandbox-test--subseq-p (list "--ro-bind" wt-path wt-path) cmd))
        (should-not (harness-sandbox-test--rw-binds cmd))
        ;; The git directory is one read-only mount, after the working
        ;; directory's: no overlay of its hooks, config, index or HEAD,
        ;; which it shows as they are.
        (should (equal (list (list "--ro-bind" wt-path wt-path) (list "--ro-bind" common common))
                       (cl-remove-if-not (lambda (bind) (member (cadr bind) (list common wt-path)))
                                         (harness-sandbox-test--binds cmd))))
        (dolist (name '("hooks" "config" "index" "HEAD"))
          (should-not (member (concat common "/" name) cmd)))
        ;; git still has the commit identity of the host.
        (should (harness-sandbox-test--subseq-p '("--setenv" "GIT_AUTHOR_NAME" "Sandbox Test") cmd)))
      ;; Not read-only, it is read-write with the overlay as it was.
      (let ((cmd (harness-call 'sandbox/wrap wt '("true"))))
        (should (harness-sandbox-test--subseq-p (list "--bind" common common) cmd))
        (should (member (concat common "/hooks") cmd))))
    (harness-sandbox-test-with-executables '(("systemd-run" . "/usr/bin/systemd-run"))
      (let ((cmd (harness-call 'sandbox/wrap wt '("true") :read-only t)))
        (should (harness-sandbox-test--subseq-p (list "-p" (concat "BindReadOnlyPaths=" common)) cmd))
        (should (harness-sandbox-test--subseq-p (list "-p" (concat "BindReadOnlyPaths=" wt-path)) cmd))
        (should-not (cl-some (lambda (a) (string-match-p "\\`\\(BindPaths\\|ReadWritePaths\\)=" a)) cmd))
        (should-not (member (concat "BindReadOnlyPaths=" common "/hooks") cmd))
        (should (member "--setenv=GIT_AUTHOR_NAME=Sandbox Test" cmd)))
      (should (member (concat "BindPaths=" common)
                      (harness-call 'sandbox/wrap wt '("true")))))
    (harness-sandbox-detect)))

(ert-deftest harness-sandbox-read-only-fails-closed ()
  "A read-only command never runs unconfined, whatever the policy."
  (harness-sandbox-test--setup)
  (let* ((cwd (harness-test-temp-dir))
         (harness-sandbox-backend 'auto)
         (remote "/ssh:example.invalid:/tmp/")
         (command '("sh" "-c" "true"))
         (logged nil)
         (harness-log-hook (list (lambda (level message) (push (cons level message) logged)))))
    (cl-flet ((refused (&rest args)
                (setq logged nil)
                (should-error (apply #'harness-call 'sandbox/wrap args) :type 'harness-sandbox-unavailable)
                (should (cl-some (lambda (entry)
                                   (and (eq (car entry) 'error)
                                        (string-match-p "read-only command needs the sandbox" (cdr entry))))
                                 logged))))
      ;; The policy off.
      (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
        (let ((harness-sandbox-policy 'off))
          (refused cwd command :read-only t)
          (should (equal command (harness-call 'sandbox/wrap cwd command)))
          (should (equal command (harness-call 'sandbox/wrap cwd command :read-only nil)))
          (should (equal command (harness-call 'sandbox/wrap cwd command :read-only :false))))
        ;; A remote working directory, which is never wrapped.
        (dolist (policy '(preferred required off))
          (let ((harness-sandbox-policy policy))
            (refused remote command :read-only t)
            (unless (eq policy 'off)
              (should (equal command (harness-call 'sandbox/wrap remote command)))))))
      ;; No backend, even where the policy lets other commands run unconfined.
      (harness-sandbox-test-with-executables nil
        (let ((harness-sandbox-policy 'preferred))
          (refused cwd command :read-only t)
          (refused cwd command :read-only t :writable (list cwd))
          (should (equal command (harness-call 'sandbox/wrap cwd command))))
        (let ((harness-sandbox-policy 'required))
          (refused cwd command :read-only t)
          (should-error (harness-call 'sandbox/wrap cwd command) :type 'harness-sandbox-unavailable)))
      ;; Before the module has chosen a backend.
      (let ((harness-sandbox--backend nil)
            (harness-sandbox-policy 'preferred))
        (refused cwd command :read-only t)))
    (harness-sandbox-detect)
    (delete-directory cwd t)))

(ert-deftest harness-sandbox-read-only-reads-the-policy-of-the-directory ()
  "The policy the working directory's settings give is the one that decides."
  (harness-sandbox-test--setup)
  (let* ((cwd (harness-test-temp-dir))
         (harness-sandbox-policy 'preferred)
         (command '("true")))
    (with-temp-file (expand-file-name ".dir-locals.el" cwd)
      (insert "((nil . ((harness-sandbox-policy . off))))"))
    (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
      (should (equal command (harness-call 'sandbox/wrap cwd command)))
      (should-error (harness-call 'sandbox/wrap cwd command :read-only t)
                    :type 'harness-sandbox-unavailable))
    (harness-sandbox-detect)
    (delete-directory cwd t)))

(ert-deftest harness-sandbox-bwrap-real-run-read-only ()
  "Under the real bwrap a :read-only command reads the directory and writes nothing there."
  (harness-sandbox-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (let* ((cwd (harness-test-temp-dir))
         (granted (harness-test-temp-dir))
         (harness-sandbox-policy 'required)
         (script (mapconcat
                  #'identity
                  (list "cat seen.txt"
                        (format "cat %snote.txt" granted)
                        "echo x > new.txt 2>/dev/null && echo cwd-written || echo cwd-refused"
                        "echo x >> seen.txt 2>/dev/null && echo cwd-appended || echo append-refused"
                        "rm seen.txt 2>/dev/null && echo cwd-removed || echo remove-refused"
                        (format "echo x > %snew.txt 2>/dev/null && echo granted-written || echo granted-refused" granted)
                        "echo x > /tmp/scratch && cat /tmp/scratch")
                  "; ")))
    (harness-sandbox-test--write (expand-file-name "seen.txt" cwd) "seen\n")
    (harness-sandbox-test--write (expand-file-name "note.txt" granted) "note\n")
    (unwind-protect
        (let ((probe (harness-await (harness-run-command (harness-call 'sandbox/wrap cwd '("true"))
                                                         :cwd cwd :timeout 20))))
          (unless (eql 0 (plist-get probe :exit))
            (ert-skip (format "bwrap cannot start here: %s" (string-trim (plist-get probe :stderr)))))
          (let* ((cmd (harness-call 'sandbox/wrap cwd (list "sh" "-c" script)
                                    :writable (list granted) :read-only t))
                 (r (harness-await (harness-run-command cmd :cwd cwd :timeout 20))))
            (should (equal "seen\nnote\ncwd-refused\nappend-refused\nremove-refused\ngranted-refused\nx\n"
                           (plist-get r :stdout)))
            (should (eql 0 (plist-get r :exit)))
            ;; Nothing the command tried reached either directory.
            (should (equal '("seen.txt") (directory-files cwd nil "\\`[^.]")))
            (should (equal "seen\n" (with-temp-buffer
                                      (insert-file-contents (expand-file-name "seen.txt" cwd))
                                      (buffer-string))))
            (should (equal '("note.txt") (directory-files granted nil "\\`[^.]")))
            ;; The same command, not read-only, writes both.
            (let ((r (harness-await
                      (harness-run-command (harness-call 'sandbox/wrap cwd (list "sh" "-c" script)
                                                         :writable (list granted))
                                           :cwd cwd :timeout 20))))
              (should (string-match-p "cwd-written" (plist-get r :stdout)))
              (should (string-match-p "granted-written" (plist-get r :stdout)))
              (should (file-exists-p (expand-file-name "new.txt" cwd)))
              (should (file-exists-p (expand-file-name "new.txt" granted))))))
      (delete-directory cwd t)
      (delete-directory granted t))))

(ert-deftest harness-sandbox-bwrap-real-run-read-only-worktree ()
  "Under the real bwrap git reads a worktree's repository and changes none of it."
  (harness-sandbox-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (let* ((repo (harness-sandbox-test--worktree))
         (root (car repo))
         (wt (cdr repo))
         (hook (expand-file-name ".git/hooks/post-merge" root))
         (before (harness-sandbox-test--git wt "rev-parse" "HEAD"))
         (harness-sandbox-policy 'required)
         (cmd (harness-call
               'sandbox/wrap wt
               (list "sh" "-c"
                     (format "git log -1 --format=%%s; git diff --stat; git status --short; echo change > f 2>/dev/null || echo cwd-refused; git -c commit.gpgsign=false commit -q --allow-empty -m inside 2>/dev/null && echo committed || echo commit-refused; git branch inside 2>/dev/null && echo branched || echo branch-refused; echo x > %s 2>/dev/null || echo hook-refused"
                             (shell-quote-argument hook)))
               :read-only t))
         (r (harness-await (harness-run-command cmd :cwd wt :timeout 20))))
    (when (and (not (eql 0 (plist-get r :exit))) (string-match-p "bwrap:" (plist-get r :stderr)))
      (ert-skip (format "bwrap cannot start here: %s" (string-trim (plist-get r :stderr)))))
    (should (equal "initial\ncwd-refused\ncommit-refused\nbranch-refused\nhook-refused\n"
                   (plist-get r :stdout)))
    (should-not (file-exists-p hook))
    (should-not (file-exists-p (expand-file-name "f" wt)))
    (should (equal before (harness-sandbox-test--git wt "rev-parse" "HEAD")))
    (should (string-empty-p (harness-sandbox-test--git wt "status" "--porcelain")))
    (should-not (string-match-p "inside" (harness-sandbox-test--git root "branch" "--list")))))

;;;; MXC, on macOS

;; Everything here but the last tests runs on any system: the command
;; line is built and read back, and run by /bin/sh as MXC would run it,
;; or by a stand-in for mxc-exec-mac.  Only the last ones need a Mac
;; with MXC, and skip elsewhere.

(defun harness-sandbox-test--detect-on-macos (available)
  "Detect the backends as on macOS, `executable-find' finding only AVAILABLE.
AVAILABLE is an alist of program name to path, as for
`harness-sandbox-test-with-executables'.  Only the detection runs as on
macOS; what follows sees the backend it chose."
  (let ((system-type 'darwin))
    (harness-sandbox-test-with-executables available nil)))

(defun harness-sandbox-test--mxc-config (cmd)
  "Return the configuration that MXC command line CMD gives its executor, parsed."
  (should (= 3 (length cmd)))
  (should (equal "--config-base64" (nth 1 cmd)))
  (harness-json-parse (decode-coding-string (base64-decode-string (nth 2 cmd)) 'utf-8)))

(defun harness-sandbox-test--mxc-env (config name)
  "Return the values that CONFIG's environment gives NAME, one per entry."
  (cl-loop for entry in (harness-plist-get-in config '(:process :env))
           when (string-prefix-p (concat name "=") entry)
           collect (substring entry (1+ (length name)))))

(defun harness-sandbox-test--mxc-network (config)
  "Return CONFIG's egress default, ingress default and loopback ingress."
  (mapcar (lambda (path) (harness-plist-get-in config (cons :network path)))
          '((:egress :default) (:ingress :default) (:ingress :hostLoopback))))

(defun harness-sandbox-test--real (path)
  "Return PATH's real path without a trailing slash, as MXC is given it."
  (directory-file-name (file-truename path)))

(ert-deftest harness-sandbox-mxc-detection ()
  "MXC is looked for on macOS only, and bwrap and systemd-run everywhere else."
  (harness-sandbox-test--setup)
  (let ((harness-sandbox-backend 'auto)
        (harness-sandbox-policy 'preferred)
        (programs '(("mxc-exec-mac" . "/opt/mxc/bin/mxc-exec-mac")
                    ("bwrap" . "/usr/bin/bwrap")
                    ("systemd-run" . "/usr/bin/systemd-run"))))
    (unwind-protect
        (progn
          (let ((system-type 'darwin))
            (harness-sandbox-test-with-executables programs
              (should (eq 'mxc (plist-get (harness-call 'sandbox/status) :backend)))
              (should (equal '(mxc) (plist-get (harness-call 'sandbox/status) :available)))
              (should (equal '((mxc . "/opt/mxc/bin/mxc-exec-mac")) harness-sandbox--programs)))
            ;; Forced, it is MXC or nothing there.
            (let ((harness-sandbox-backend 'mxc))
              (harness-sandbox-test-with-executables programs
                (should (eq 'mxc (plist-get (harness-call 'sandbox/status) :backend))))
              (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
                (should (eq 'none (plist-get (harness-call 'sandbox/status) :backend)))
                (should-not (plist-get (harness-call 'sandbox/status) :available))))
            (let ((harness-sandbox-backend 'bwrap))
              (harness-sandbox-test-with-executables programs
                (should (eq 'none (plist-get (harness-call 'sandbox/status) :backend)))))
            ;; The executor named by a path, from ~ here, is found there.
            (let* ((harness-sandbox-mxc-program "~/mxc/mxc-exec-mac")
                   (path (expand-file-name "~/mxc/mxc-exec-mac"))
                   (asked nil))
              (cl-letf (((symbol-function 'executable-find)
                         (lambda (name &optional _remote) (push name asked) (and (equal name path) name))))
                (harness-sandbox-detect)
                (should (eq 'mxc harness-sandbox--backend))
                (should (equal (list (cons 'mxc path)) harness-sandbox--programs))
                (should (equal (list path) asked)))))
          ;; GNU/Linux: the same programs give bwrap and systemd-run, and
          ;; never MXC, even forced.
          (let ((system-type 'gnu/linux))
            (harness-sandbox-test-with-executables programs
              (should (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
              (should (equal '(bwrap systemd) (plist-get (harness-call 'sandbox/status) :available))))
            (let ((harness-sandbox-backend 'mxc))
              (harness-sandbox-test-with-executables programs
                (should (eq 'none (plist-get (harness-call 'sandbox/status) :backend)))))))
      (harness-sandbox-detect))))

(ert-deftest harness-sandbox-mxc-config ()
  "The MXC command line carries the whole command as JSON: what runs,
where, in which environment, what it may read and write and whether
it has the network."
  (harness-sandbox-test--setup)
  (harness-sandbox-test-with-home home
    (let* ((cwd (harness-test-temp-dir))
           (tmp (harness-test-temp-dir))
           (granted (harness-test-temp-dir))
           (readable (harness-test-temp-dir))
           (system (harness-test-temp-dir))
           (extra (harness-test-temp-dir))
           (vendor (file-name-as-directory (expand-file-name "vendor" cwd)))
           (harness-sandbox--mxc-system-dirs (list system "/nonexistent/harness-test-dir"))
           ;; One inside the working directory, which shows it read-write anyway.
           (harness-sandbox-extra-read-only-dirs (list extra vendor))
           (process-environment (append (list "HARNESS_TEST_FIRST=one" "HARNESS_TEST_UNSET"
                                              "HARNESS_TEST_FIRST=two" "HARNESS_TEST_UNSET=set"
                                              "TMPDIR=/elsewhere/" "HARNESS_SANDBOX=outer"
                                              "PWD=/elsewhere")
                                        process-environment))
           (build (lambda (&rest opts)
                    (harness-sandbox-test--mxc-config
                     ;; The home directory is never shown read-only.
                     (apply #'harness-sandbox--mxc-command "/opt/mxc/mxc-exec-mac" cwd '("bash" "-c" "true")
                            :writable (list granted) :readable (list readable home) :tmp tmp opts))))
           (real #'harness-sandbox-test--real))
      (make-directory vendor)
      (unwind-protect
          (progn
            (let* ((config (funcall build))
                   (process (plist-get config :process))
                   (env (lambda (name) (harness-sandbox-test--mxc-env config name))))
              (should (equal "1.0.0" (plist-get config :version)))
              (should (equal "seatbelt" (plist-get config :containment)))
              (should (equal (directory-file-name cwd) (plist-get process :cwd)))
              (should (eql 0 (plist-get process :timeout)))
              (should (eq t (harness-plist-get-in config '(:seatbelt :nestedPty))))
              ;; The words quoted, then the private TMPDIR removed.
              (should (equal (format "'bash' '-c' 'true'; s=$?; rm -rf -- '%s'; exit $s" (funcall real tmp))
                             (plist-get process :commandLine)))
              ;; The host's network, both ways and loopback too, by default.
              (should (equal '("allow" "allow" "allow") (harness-sandbox-test--mxc-network config)))
              ;; Writable: the working directory, what was granted and the
              ;; private TMPDIR, at their real paths.
              (should (equal (list (funcall real cwd) (funcall real granted) (funcall real tmp))
                             (harness-plist-get-in config '(:filesystem :readwritePaths))))
              ;; Readable: what was asked for but the home directory, the
              ;; toolchain directories and the extra ones that exist, but
              ;; not one the working directory holds.
              (should (equal (list (funcall real readable) (funcall real system) (funcall real extra))
                             (harness-plist-get-in config '(:filesystem :readonlyPaths))))
              ;; The environment: the first entry of a name wins, a bare
              ;; name unsets it, and the sandbox's own come on top.
              (should (equal '("one") (funcall env "HARNESS_TEST_FIRST")))
              (should-not (funcall env "HARNESS_TEST_UNSET"))
              (should (equal (list (file-name-as-directory (funcall real tmp))) (funcall env "TMPDIR")))
              (should (equal '("mxc") (funcall env "HARNESS_SANDBOX")))
              (should (equal (list (directory-file-name cwd)) (funcall env "PWD")))
              (should (equal (list (getenv "PATH")) (funcall env "PATH")))
              ;; $HOME keeps its path.
              (should (equal (list (directory-file-name home)) (funcall env "HOME"))))
            ;; The network cut, loopback too.
            (should (equal '("deny" "deny" "deny") (harness-sandbox-test--mxc-network (funcall build :network nil))))
            ;; Read-only: only the private TMPDIR is writable; the working
            ;; directory and the granted one are readable, and an extra
            ;; one inside the working directory stays.
            (let ((config (funcall build :read-only t)))
              (should (equal (list (funcall real tmp)) (harness-plist-get-in config '(:filesystem :readwritePaths))))
              (should (equal (mapcar real (list cwd granted readable system extra vendor))
                             (harness-plist-get-in config '(:filesystem :readonlyPaths))))
              (should (equal '("allow" "allow" "allow") (harness-sandbox-test--mxc-network config))))
            ;; Without a private directory: nothing to remove, nothing
            ;; writable read-only, and $TMPDIR as it was.
            (let ((config (harness-sandbox-test--mxc-config
                           (harness-sandbox--mxc-command "mxc-exec-mac" cwd '("true") :read-only t))))
              (should (equal "'true'" (harness-plist-get-in config '(:process :commandLine))))
              (should-not (harness-plist-get-in config '(:filesystem :readwritePaths)))
              (should (equal '("/elsewhere/") (harness-sandbox-test--mxc-env config "TMPDIR")))))
        (dolist (dir (list cwd tmp granted readable system extra))
          (delete-directory dir t))))))

(ert-deftest harness-sandbox-mxc-leaves-out-what-json-cannot-carry ()
  "An environment entry holding raw bytes is left out rather than failing every command."
  (harness-sandbox-test--setup)
  (let* ((cwd (harness-test-temp-dir))
         (process-environment (append (list (concat "HARNESS_TEST_RAW=" (string #x3FFFFF))
                                            (concat "HARNESS_TEST_BYTES=" (encode-coding-string "é" 'utf-8))
                                            "HARNESS_TEST_TEXT=é")
                                      process-environment))
         (config (harness-sandbox-test--mxc-config (harness-sandbox--mxc-command "mxc-exec-mac" cwd '("true")))))
    (should-not (harness-sandbox-test--mxc-env config "HARNESS_TEST_RAW"))
    (should-not (harness-sandbox-test--mxc-env config "HARNESS_TEST_BYTES"))
    (should (equal '("é") (harness-sandbox-test--mxc-env config "HARNESS_TEST_TEXT")))
    (delete-directory cwd t)))

(ert-deftest harness-sandbox-mxc-command-line-runs-the-words-as-they-are ()
  "The command line MXC gives /bin/sh -c runs the command's words exactly,
passes its exit status on and removes the private TMPDIR."
  (harness-sandbox-test--setup)
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((cwd (harness-test-temp-dir))
         (words (list "it's" "two words" "$HOME" "back\\slash" "" "*" "\"q\"" "`x`" "new\nline" "'" "a'b'c"))
         (run (lambda (command)
                (let* ((tmp (harness-test-temp-dir))
                       (line (harness-plist-get-in
                              (harness-sandbox-test--mxc-config
                               (harness-sandbox--mxc-command "mxc-exec-mac" cwd command :tmp tmp))
                              '(:process :commandLine))))
                  (with-temp-file (expand-file-name "left-behind" tmp) (insert "x\n"))
                  (prog1 (with-temp-buffer
                           (let ((default-directory cwd))
                             (list (call-process "/bin/sh" nil t nil "-c" line) (buffer-string))))
                    (should-not (file-exists-p tmp)))))))
    (unwind-protect
        (progn
          (should (equal (list 0 (concat (mapconcat #'identity words "|") "|"))
                         (funcall run (append '("printf" "%s|") words))))
          (should (equal '(3 "") (funcall run '("sh" "-c" "exit 3"))))
          (should (equal '(0 "zero:one\n") (funcall run '("sh" "-c" "echo \"$0:$1\"" "zero" "one")))))
      (delete-directory cwd t))))

(ert-deftest harness-sandbox-mxc-worktree-git ()
  "A worktree's git directory is writable but its hooks, config, index and
HEAD are not; read-only, the whole of it is; git has the commit identity."
  (harness-sandbox-test--setup)
  (let* ((repo (harness-sandbox-test--worktree))
         (wt (cdr repo))
         (common (harness-sandbox-test--real (expand-file-name ".git" (car repo))))
         (harness-sandbox--mxc-system-dirs nil)
         (harness-sandbox-extra-read-only-dirs nil)
         (build (lambda (dir &rest opts)
                  (harness-sandbox-test--mxc-config
                   (apply #'harness-sandbox--mxc-command "mxc-exec-mac" dir '("true") opts)))))
    (unwind-protect
        (progn
          (let ((config (funcall build wt)))
            (should (equal (list (harness-sandbox-test--real wt) common)
                           (harness-plist-get-in config '(:filesystem :readwritePaths))))
            (should (equal (mapcar (lambda (name) (concat common "/" name)) '("hooks" "config" "index" "HEAD"))
                           (harness-plist-get-in config '(:filesystem :readonlyPaths))))
            (should (equal '("Sandbox Test") (harness-sandbox-test--mxc-env config "GIT_AUTHOR_NAME")))
            (should (equal '("sandbox@example.invalid") (harness-sandbox-test--mxc-env config "GIT_COMMITTER_EMAIL"))))
          (let ((config (funcall build wt :read-only t)))
            (should-not (harness-plist-get-in config '(:filesystem :readwritePaths)))
            (should (equal (list (harness-sandbox-test--real wt) common)
                           (harness-plist-get-in config '(:filesystem :readonlyPaths))))
            (should (equal '("Sandbox Test") (harness-sandbox-test--mxc-env config "GIT_AUTHOR_NAME"))))
          ;; A main checkout needs nothing extra: its .git is inside it.
          (let ((config (funcall build (car repo))))
            (should (equal (list (harness-sandbox-test--real (car repo)))
                           (harness-plist-get-in config '(:filesystem :readwritePaths))))
            (should-not (harness-plist-get-in config '(:filesystem :readonlyPaths)))))
      (delete-directory (file-name-directory (directory-file-name (car repo))) t))))

(ert-deftest harness-sandbox-mxc-wrap ()
  "On macOS `sandbox/wrap' runs a command through MXC, with a private
TMPDIR of its own; without MXC there, the refusals name its executor."
  (harness-sandbox-test--setup)
  (let* ((cwd (harness-test-temp-dir))
         (real-cwd (harness-sandbox-test--real cwd))
         (harness-sandbox-policy 'preferred)
         (harness-sandbox-backend 'auto)
         (harness-sandbox--mxc-system-dirs nil)
         (harness-sandbox-extra-read-only-dirs nil)
         (made nil)
         (tmpdir (lambda (cmd)
                   (let ((dir (car (harness-sandbox-test--mxc-env (harness-sandbox-test--mxc-config cmd) "TMPDIR"))))
                     (push dir made)
                     dir))))
    (unwind-protect
        (progn
          (harness-sandbox-test--detect-on-macos '(("mxc-exec-mac" . "/opt/mxc/mxc-exec-mac")))
          (should (eq 'mxc (plist-get (harness-call 'sandbox/status) :backend)))
          (should (equal '(mxc) (plist-get (harness-call 'sandbox/status) :available)))
          (should (eq t (harness-call 'sandbox/confined-p cwd)))
          (should-not (harness-call 'sandbox/confined-p "/ssh:example.invalid:/srv/"))
          (let* ((cmd (harness-call 'sandbox/wrap cwd '("bash" "-c" "true") :network nil))
                 (config (harness-sandbox-test--mxc-config cmd))
                 (dir (funcall tmpdir cmd)))
            (should (equal "/opt/mxc/mxc-exec-mac" (car cmd)))
            ;; Made for the command, private, named in the configuration.
            (should (file-directory-p dir))
            (should (= #o700 (file-modes dir)))
            (should (equal (list real-cwd (directory-file-name dir))
                           (harness-plist-get-in config '(:filesystem :readwritePaths))))
            (should (string-search (concat "rm -rf -- " (harness-sandbox--sh-quote (directory-file-name dir)))
                                   (harness-plist-get-in config '(:process :commandLine))))
            (should (equal '("deny" "deny" "deny") (harness-sandbox-test--mxc-network config)))
            ;; Each command has a directory of its own.
            (should-not (equal dir (funcall tmpdir (harness-call 'sandbox/wrap cwd '("true"))))))
          ;; Read-only: nothing writable but its TMPDIR.
          (let* ((cmd (harness-call 'sandbox/wrap cwd '("true") :read-only t :writable (list cwd)))
                 (config (harness-sandbox-test--mxc-config cmd))
                 (dir (funcall tmpdir cmd)))
            (should (equal (list (directory-file-name dir))
                           (harness-plist-get-in config '(:filesystem :readwritePaths))))
            (should (equal (list real-cwd) (harness-plist-get-in config '(:filesystem :readonlyPaths)))))
          ;; The policy off: unchanged, and a read-only command refused.
          (let ((harness-sandbox-policy 'off))
            (should (equal '("true") (harness-call 'sandbox/wrap cwd '("true"))))
            (should-error (harness-call 'sandbox/wrap cwd '("true") :read-only t) :type 'harness-sandbox-unavailable)
            (should-not (harness-call 'sandbox/confined-p cwd)))
          ;; On macOS without MXC, nothing confines a read-only command,
          ;; and the refusal names MXC's executor.
          (let ((system-type 'darwin))
            (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
              (should (eq 'none (plist-get (harness-call 'sandbox/status) :backend)))
              (should-not (harness-call 'sandbox/confined-p cwd))
              (let ((err (should-error (harness-call 'sandbox/wrap cwd '("true") :read-only t)
                                       :type 'harness-sandbox-unavailable)))
                (should (string-match-p "mxc-exec-mac (MXC) is not available" (cadr err))))
              (let* ((harness-sandbox-policy 'required)
                     (err (should-error (harness-call 'sandbox/wrap cwd '("true"))
                                        :type 'harness-sandbox-unavailable)))
                (should (string-match-p "mxc-exec-mac (MXC)" (cadr err))))
              (should (equal '("true") (harness-call 'sandbox/wrap cwd '("true"))))))
          ;; On GNU/Linux they name bwrap and systemd-run, as before.
          (let ((system-type 'gnu/linux))
            (harness-sandbox-test-with-executables nil
              (let ((err (should-error (harness-call 'sandbox/wrap cwd '("true") :read-only t)
                                       :type 'harness-sandbox-unavailable)))
                (should (string-match-p "neither bwrap nor systemd-run is available" (cadr err)))))))
      (dolist (dir made) (ignore-errors (delete-directory dir t)))
      (harness-sandbox-detect)
      (delete-directory cwd t))))

(defun harness-sandbox-test--fake-mxc (dir)
  "Write a stand-in for MXC's mxc-exec-mac in DIR and return its path.
It runs the command its configuration describes as mxc-exec-mac does,
but unconfined: the command line with /bin/sh -c, in its cwd, with
exactly its environment (Emacs, which runs it, sets PWD), passing its
output, its standard error and its exit status on."
  (let ((script (expand-file-name "mxc-exec-mac" dir))
        (lisp (expand-file-name "fake-mxc.el" dir)))
    (with-temp-file lisp
      (insert ";;; fake-mxc.el --- a stand-in for mxc-exec-mac  -*- lexical-binding: t; -*-\n"
              (prin1-to-string
               '(let* ((b64 (cadr (member "--config-base64" command-line-args-left)))
                       (config (json-parse-string (decode-coding-string (base64-decode-string b64) 'utf-8)
                                                  :object-type 'plist :array-type 'list))
                       (process (plist-get config :process))
                       (default-directory (file-name-as-directory (plist-get process :cwd)))
                       (process-environment (plist-get process :env))
                       (status (progn
                                 (setq command-line-args-left nil)
                                 (call-process "/bin/sh" nil '((:file "/dev/stdout") "/dev/stderr") nil
                                               "-c" (plist-get process :commandLine)))))
                  (kill-emacs (if (integerp status) status 1))))
              "\n"))
    (with-temp-file script
      (insert "#!/bin/sh\n"
              (format "exec %s -Q --batch -l %s \"$@\"\n"
                      (shell-quote-argument (expand-file-name invocation-name invocation-directory))
                      (shell-quote-argument lisp))))
    (set-file-modes script #o755)
    script))

(ert-deftest harness-sandbox-mxc-runs-through-a-stand-in ()
  "End to end on any system, mxc-exec-mac being a stand-in that runs the
command unconfined: the command `sandbox/wrap' gives runs in its
directory with its environment, its output, standard error and exit
status come back, and its private TMPDIR is gone afterwards."
  (harness-sandbox-test--setup)
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((bin (harness-test-temp-dir))
         (cwd (harness-test-temp-dir))
         (fake (harness-sandbox-test--fake-mxc bin))
         (harness-sandbox-policy 'required)
         (harness-sandbox-backend 'auto)
         (harness-sandbox--mxc-system-dirs nil)
         (process-environment (cons "HARNESS_TEST_PASSED=yes" process-environment)))
    (unwind-protect
        (progn
          (harness-sandbox-test--detect-on-macos (list (cons "mxc-exec-mac" fake)))
          (should (eq 'mxc (plist-get (harness-call 'sandbox/status) :backend)))
          (let* ((cmd (harness-call 'sandbox/wrap cwd
                                    (list "bash" "-c" (concat "pwd; echo \"sandbox=$HARNESS_SANDBOX passed=$HARNESS_TEST_PASSED\";"
                                                              " echo \"$TMPDIR\"; echo kept > \"$TMPDIR/scratch\" && cat \"$TMPDIR/scratch\";"
                                                              " echo made > made.txt; echo oops >&2; exit 7"))))
                 (tmpdir (car (harness-sandbox-test--mxc-env (harness-sandbox-test--mxc-config cmd) "TMPDIR")))
                 (r (harness-await (harness-run-command cmd :cwd cwd :timeout 60) 70)))
            (should (equal fake (car cmd)))
            (should (eql 7 (plist-get r :exit)))
            (should (equal (list (directory-file-name cwd) "sandbox=mxc passed=yes" tmpdir "kept")
                           (split-string (plist-get r :stdout) "\n" t)))
            (should (equal "oops\n" (plist-get r :stderr)))
            (should (file-exists-p (expand-file-name "made.txt" cwd)))
            (should-not (file-exists-p tmpdir))))
      (harness-sandbox-detect)
      (delete-directory bin t)
      (delete-directory cwd t))))

(ert-deftest harness-sandbox-mxc-real-run-confines ()
  "Under the real MXC, on macOS, a command writes its directory and its
TMPDIR but no other, reads nothing of the home directory, and with
:read-only writes nothing but its TMPDIR."
  (harness-sandbox-test--setup)
  (skip-unless (and (eq system-type 'darwin) (executable-find harness-sandbox-mxc-program)))
  (harness-sandbox-detect)
  (skip-unless (eq 'mxc (plist-get (harness-call 'sandbox/status) :backend)))
  (harness-sandbox-test-with-home home
    (let* ((cwd (harness-test-temp-dir))
           (sibling (harness-test-temp-dir))
           (key (expand-file-name ".ssh/id_test" home))
           (harness-sandbox-policy 'required)
           (run (lambda (script &rest opts)
                  (harness-await (harness-run-command (apply #'harness-call 'sandbox/wrap cwd (list "sh" "-c" script) opts)
                                                      :cwd cwd :timeout 60)
                                 70))))
      (harness-sandbox-test--write key "s3cret\n")
      (unwind-protect
          (let ((probe (funcall run "true")))
            ;; Skipped only when MXC cannot start at all, as on a macOS
            ;; before 15.
            (unless (eql 0 (plist-get probe :exit))
              (ert-skip (format "mxc-exec-mac cannot start here: %s" (string-trim (plist-get probe :stderr)))))
            (let ((r (funcall run (mapconcat
                                   #'identity
                                   (list "echo x > in-cwd && echo cwd-written"
                                         "echo x > \"$TMPDIR/t\" && echo tmp-written"
                                         (format "echo x > %s 2>/dev/null && echo sibling-written || echo sibling-refused"
                                                 (shell-quote-argument (expand-file-name "f" sibling)))
                                         (format "cat %s 2>/dev/null || echo key-hidden" (shell-quote-argument key))
                                         "echo $HARNESS_SANDBOX")
                                   "; "))))
              (should (equal "cwd-written\ntmp-written\nsibling-refused\nkey-hidden\nmxc\n" (plist-get r :stdout)))
              (should (file-exists-p (expand-file-name "in-cwd" cwd)))
              (should-not (file-exists-p (expand-file-name "f" sibling))))
            (let ((r (funcall run (concat "echo x > ro.txt 2>/dev/null && echo cwd-written || echo cwd-refused; "
                                          "echo x > \"$TMPDIR/t\" && cat \"$TMPDIR/t\"")
                              :read-only t)))
              (should (equal "cwd-refused\nx\n" (plist-get r :stdout)))
              (should-not (file-exists-p (expand-file-name "ro.txt" cwd)))))
        (delete-directory cwd t)
        (delete-directory sibling t)))))

;;;; Scratch directories

(ert-deftest harness-sandbox-scratch-bwrap-arguments ()
  "A scratch directory is bound writable after every other mount, so it
is writable whatever covers it, :read-only included."
  (harness-sandbox-test--setup)
  (harness-sandbox-test-with-home home
    (ignore home)
    (let* ((cwd (harness-test-temp-dir))
           (scratch (harness-test-temp-dir))
           (inner (file-name-as-directory (expand-file-name "inner" cwd)))
           (cwd-bind (directory-file-name cwd))
           (scratch-bind (directory-file-name scratch))
           (harness-sandbox-policy 'preferred)
           (harness-sandbox-backend 'auto)
           (command '("sh" "-c" "true")))
      (make-directory inner)
      (unwind-protect
          (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
            (dolist (read-only '(nil t))
              (let ((cmd (harness-call 'sandbox/wrap cwd command :scratch (list scratch)
                                       :readable (list scratch) :read-only read-only)))
                ;; Shown read-only as the readable directory it also is,
                ;; then writable over that, last of all.
                (should (harness-sandbox-test--subseq-p (list "--ro-bind" scratch-bind scratch-bind) cmd))
                (should (equal (list "--bind" scratch-bind scratch-bind)
                               (car (last (harness-sandbox-test--binds cmd)))))
                (should (harness-sandbox-test--subseq-p
                         (list (if read-only "--ro-bind" "--bind") cwd-bind cwd-bind) cmd))
                (should (equal command (cdr (member "--" cmd))))))
            ;; Read-only, it is the one writable mount.
            (should (equal (list (list "--bind" scratch-bind scratch-bind))
                           (harness-sandbox-test--rw-binds
                            (harness-call 'sandbox/wrap cwd command :scratch (list scratch) :read-only t))))
            ;; One in the working directory is writable in the read-only one.
            (should (equal (list (list "--ro-bind" cwd-bind cwd-bind)
                                 (list "--bind" (directory-file-name inner) (directory-file-name inner)))
                           (last (harness-sandbox-test--binds
                                  (harness-call 'sandbox/wrap cwd command :scratch (list inner) :read-only t))
                                 2)))
            ;; Without one, the command line is as it was.
            (should (equal (harness-call 'sandbox/wrap cwd command :read-only t)
                           (harness-call 'sandbox/wrap cwd command :read-only t :scratch nil))))
        (harness-sandbox-detect)
        (delete-directory cwd t)
        (delete-directory scratch t)))))

(ert-deftest harness-sandbox-scratch-systemd-arguments ()
  "systemd binds a scratch directory writable, read-only or not, and
refuses one whose path its settings cannot hold."
  (harness-sandbox-test--setup)
  (let* ((cwd (harness-test-temp-dir))
         (scratch (harness-test-temp-dir))
         (spaced (file-name-as-directory (make-temp-file "harness scratch " t)))
         (cwd-path (directory-file-name cwd))
         (scratch-path (directory-file-name scratch))
         (harness-sandbox-policy 'preferred)
         (harness-sandbox-backend 'auto)
         (command '("sh" "-c" "true"))
         (writable-settings (lambda (cmd)
                              (cl-remove-if-not
                               (lambda (a) (string-match-p "\\`\\(BindPaths\\|ReadWritePaths\\)=" a)) cmd))))
    (unwind-protect
        (harness-sandbox-test-with-executables '(("systemd-run" . "/usr/bin/systemd-run"))
          (dolist (read-only '(nil t))
            (let ((cmd (harness-call 'sandbox/wrap cwd command :scratch (list scratch) :read-only read-only)))
              (should (harness-sandbox-test--subseq-p
                       (list "-p" (concat "BindPaths=" scratch-path) "-p" (concat "ReadWritePaths=" scratch-path))
                       cmd))
              (should (equal command (cdr (member "--" cmd))))))
          (let ((cmd (harness-call 'sandbox/wrap cwd command :scratch (list scratch) :read-only t)))
            (should (harness-sandbox-test--subseq-p '("-p" "ProtectSystem=strict") cmd))
            (should (harness-sandbox-test--subseq-p (list "-p" (concat "BindReadOnlyPaths=" cwd-path)) cmd))
            ;; Nothing else is writable.
            (should (equal (list (concat "BindPaths=" scratch-path) (concat "ReadWritePaths=" scratch-path))
                           (funcall writable-settings cmd))))
          (should-error (harness-call 'sandbox/wrap cwd command :scratch (list spaced) :read-only t)))
      (harness-sandbox-detect)
      (delete-directory cwd t)
      (delete-directory scratch t)
      (delete-directory spaced t))))

(ert-deftest harness-sandbox-scratch-refuses-what-it-must-not-show ()
  "A scratch directory that would show writable what the sandbox hides or
keeps read-only is refused with an error, and so is one that is no local
directory.  Where the command runs unconfined nothing is checked: it
reaches the directory anyway."
  (harness-sandbox-test--setup)
  (harness-sandbox-test-with-home home
    (let* ((cwd (harness-test-temp-dir))
           (inner (file-name-as-directory (expand-file-name "inner" cwd)))
           (harness-sandbox-policy 'preferred)
           (harness-sandbox-backend 'auto)
           (command '("true")))
      (make-directory inner)
      (unwind-protect
          (progn
            (dolist (backend '(("bwrap" . "/usr/bin/bwrap") ("systemd-run" . "/usr/bin/systemd-run")))
              (harness-sandbox-test-with-executables (list backend)
                (dolist (bad (list "/"
                                   ;; The working directory, and what holds it.
                                   inner cwd (file-name-directory (directory-file-name cwd))
                                   ;; The home directory, and what holds it.
                                   home (file-name-directory (directory-file-name home))
                                   ;; System directories, and what lies in them.
                                   "/usr" "/usr/share" "/etc" "/proc/self" "/dev/shm"
                                   ;; No local directory.
                                   (expand-file-name "missing" cwd) "/ssh:example.invalid:/tmp/x" 42))
                  (dolist (read-only '(nil t))
                    (should-error (harness-call 'sandbox/wrap inner command :scratch (list bad)
                                                :read-only read-only))))
                ;; A good one beside a bad one does not save it.
                (should-error (harness-call 'sandbox/wrap cwd command :scratch (list home inner)))))
            ;; No backend, or the policy off: the command runs as it is.
            (harness-sandbox-test-with-executables nil
              (should (equal command (harness-call 'sandbox/wrap cwd command :scratch (list "/")))))
            (harness-sandbox-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
              (let ((harness-sandbox-policy 'off))
                (should (equal command (harness-call 'sandbox/wrap cwd command :scratch (list "/")))))))
        (harness-sandbox-detect)
        (delete-directory cwd t)))))

(ert-deftest harness-sandbox-bwrap-real-run-scratch ()
  "Under the real bwrap a :read-only command writes its scratch directory
and nothing else."
  (harness-sandbox-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (let* ((cwd (harness-test-temp-dir))
         (scratch (harness-test-temp-dir))
         (harness-sandbox-policy 'required)
         (script (format "cat seen.txt; echo x > new.txt 2>/dev/null && echo cwd-written || echo cwd-refused; echo made > %s && echo scratch-written"
                         (shell-quote-argument (expand-file-name "result.json" scratch)))))
    (harness-sandbox-test--write (expand-file-name "seen.txt" cwd) "seen\n")
    (unwind-protect
        (let ((probe (harness-await (harness-run-command (harness-call 'sandbox/wrap cwd '("true"))
                                                         :cwd cwd :timeout 20))))
          (unless (eql 0 (plist-get probe :exit))
            (ert-skip (format "bwrap cannot start here: %s" (string-trim (plist-get probe :stderr)))))
          (let* ((cmd (harness-call 'sandbox/wrap cwd (list "sh" "-c" script)
                                    :read-only t :scratch (list scratch)))
                 (r (harness-await (harness-run-command cmd :cwd cwd :timeout 20))))
            (should (equal "seen\ncwd-refused\nscratch-written\n" (plist-get r :stdout)))
            (should (eql 0 (plist-get r :exit)))
            (should (equal '("seen.txt") (directory-files cwd nil "\\`[^.]")))
            (should (equal "made\n" (with-temp-buffer
                                      (insert-file-contents (expand-file-name "result.json" scratch))
                                      (buffer-string))))))
      (delete-directory cwd t)
      (delete-directory scratch t))))

(provide 'harness-sandbox-test)
;;; harness-sandbox-test.el ends here
