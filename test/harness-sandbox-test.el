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
        (should (harness-sandbox-test--subseq-p (list "--setenv" "HOME" harness-sandbox-home) cmd))
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
            (should (member (concat "HOME=" harness-sandbox-home) lines))
            ;; Nothing from the real home directory shows up: not the
            ;; empty sandbox home, not a listing of the real path.
            (let ((real-entries (directory-files home nil "\\`[^.]" t)))
              (should real-entries)
              (should-not (cl-intersection real-entries lines :test #'equal))
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

(provide 'harness-sandbox-test)
;;; harness-sandbox-test.el ends here
