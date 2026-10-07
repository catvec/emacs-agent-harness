;;; harness-version-test.el --- Tests for the version check  -*- lexical-binding: t; -*-

;;; Commentary:

;; The check runs against real git repositories made for each test: an
;; upstream reached by a file:// URL, as GitHub and sourcehut are by
;; https, a clone of it the harness is "installed" from, as straight.el
;; clones the recipe's repository, and a development clone with a commit
;; of its own.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-revision)
(require 'harness-version)
(require 'harness-acp)

(defvar harness-acp--server-enabled)

;;;; Repositories

(defun harness-version-test--git (dir &rest args)
  "Run git ARGS in DIR, wait for it and return its output, trimmed.
Signal an error when git fails."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" (string-join args " ") (buffer-string)))
      (string-trim (buffer-string)))))

(defun harness-version-test--configure (dir)
  "Let the tests commit in the repository DIR, unsigned."
  (harness-version-test--git dir "config" "user.name" "Harness Test")
  (harness-version-test--git dir "config" "user.email" "test@example.invalid")
  (harness-version-test--git dir "config" "commit.gpgsign" "false"))

(defun harness-version-test--commit (dir subject)
  "Commit a change in DIR with SUBJECT; return the commit's hash."
  (with-temp-file (expand-file-name "CHANGES" dir) (insert subject "\n"))
  (harness-version-test--git dir "add" "CHANGES")
  (harness-version-test--git dir "commit" "-q" "-m" subject)
  (harness-version-test--git dir "rev-parse" "HEAD"))

(defun harness-version-test--harness-repo (dir)
  "Make DIR a repository of the harness with one commit, first; return its hash."
  (make-directory (expand-file-name "lisp" dir) t)
  (harness-version-test--git dir "init" "-q" "-b" "main")
  (harness-version-test--configure dir)
  (with-temp-file (expand-file-name "harness.el" dir) (insert ";; a harness\n"))
  (with-temp-file (expand-file-name "lisp/harness-core.el" dir) (insert ";; its core\n"))
  (harness-version-test--git dir "add" "-A")
  (harness-version-test--git dir "commit" "-q" "-m" "first")
  (harness-version-test--git dir "rev-parse" "HEAD"))

(defun harness-version-test--clone (from to)
  "Clone FROM into TO, ready to commit in; return TO as a directory."
  (harness-version-test--git (file-name-directory (directory-file-name to)) "clone" "-q" from to)
  (harness-version-test--configure to)
  (file-name-as-directory to))

(defun harness-version-test--world (base)
  "Make the repositories of a test in BASE; return them as a plist.
:upstream has the commits first and second, and :url reaches it.
:installed is a clone of it made at first, and :dev a clone made at
second, with a commit of its own, third: both are cloned from :url, as
straight.el clones from the recipe's URL, and their main tracks it.
:first, :second and :third are the commits' hashes."
  (let* ((upstream (file-name-as-directory (expand-file-name "upstream" base)))
         (url (concat "file://" (directory-file-name upstream)))
         first second third installed dev)
    (make-directory upstream t)
    (setq first (harness-version-test--harness-repo upstream)
          installed (harness-version-test--clone url (expand-file-name "installed" base))
          second (harness-version-test--commit upstream "second")
          dev (harness-version-test--clone url (expand-file-name "dev" base))
          third (harness-version-test--commit dev "third"))
    (list :upstream upstream :url url
          :installed installed :dev dev :first first :second second :third third)))

;;;; Fixture

(defmacro harness-version-test-with (&rest body)
  "Run BODY with the version module started on a fresh bus.
BASE is a temporary directory for repositories.  `harness-directory',
the revision noted and `harness-version-origins' are the test's own:
the harness runs from this checkout, and no origin is configured.
Nothing BODY does may log an error: an origin out of reach is none."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let* ((base (harness-test-temp-dir))
            (errors nil)
            (harness-log-hook (list (lambda (level message)
                                      (when (eq level 'error) (push message errors)))))
            (harness-directory harness-directory)
            (harness-revision--loaded nil)
            (harness-version-origins nil)
            (harness-version--report nil)
            (harness-version--report-revision nil)
            (harness-version--checking nil)
            (harness-version--timer nil))
       (ignore base)
       (unwind-protect
           (progn (harness-test-load-module 'version)
                  ,@body
                  (should-not errors))
         (harness-modules-shutdown)
         (ignore-errors (delete-directory base t))))))

(defun harness-version-test--check (&optional max-age)
  "Ask for a report at most MAX-AGE seconds old; wait for it and return it."
  (harness-test-await (harness-call 'version/check max-age) 60))

(defun harness-version-test--origin (report name)
  "Return the origin called NAME in REPORT."
  (cl-find name (plist-get report :origins) :key (lambda (o) (plist-get o :name)) :test #'equal))

(defun harness-version-test--subjects (commits)
  "Return the subjects of COMMITS."
  (mapcar (lambda (c) (plist-get c :subject)) commits))

(defun harness-version-test--sessions-in (&rest projects)
  "Stand in for the session module with sessions in PROJECTS.
A project may be a plist of a session instead of its directory."
  (harness-register-method
   'session/list
   (lambda (&rest _)
     (mapcar (lambda (p) (if (stringp p) (list :project p) p)) projects))))

;;;; Reading checkouts

(ert-deftest harness-revision-parses-git-status ()
  (should (equal '(:commit "0123abc" :branch "main" :dirty nil)
                 (harness-revision-parse-status
                  "# branch.oid 0123abc\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +0 -0\n")))
  (should (equal '(:commit nil :branch "main" :dirty nil)
                 (harness-revision-parse-status "# branch.oid (initial)\n# branch.head main\n")))
  (should (equal '(:commit "0123abc" :branch nil :dirty t)
                 (harness-revision-parse-status
                  "# branch.oid 0123abc\n# branch.head (detached)\n1 .M N... 100644 100644 100644 a b harness.el\n"))))

(ert-deftest harness-revision-describes-a-checkout-as-it-is ()
  (skip-unless (executable-find "git"))
  (let* ((base (harness-test-temp-dir))
         (repo (file-name-as-directory (expand-file-name "repo" base)))
         (errors nil)
         (harness-log-hook (list (lambda (level message) (when (eq level 'error) (push message errors))))))
    (unwind-protect
        (let ((commit (progn (make-directory repo t) (harness-version-test--harness-repo repo))))
          (should (equal (list :commit commit :branch "main" :dirty nil)
                         (harness-test-await (harness-revision-describe-checkout repo))))
          ;; A file git does not track changes nothing; a tracked one does.
          (with-temp-file (expand-file-name "notes" repo) (insert "notes\n"))
          (should-not (plist-get (harness-test-await (harness-revision-describe-checkout repo)) :dirty))
          (with-temp-file (expand-file-name "harness.el" repo) (insert ";; changed\n"))
          (should (plist-get (harness-test-await (harness-revision-describe-checkout repo)) :dirty))
          (harness-version-test--git repo "checkout" "-q" "--detach")
          (should (equal (list :commit commit :branch nil :dirty t)
                         (harness-test-await (harness-revision-describe-checkout repo))))
          ;; Only the top of a working tree is a checkout: a harness
          ;; installed inside another repository has no commit of its own.
          (let ((err (should-error (harness-test-await
                                    (harness-revision-describe-checkout (expand-file-name "lisp" repo))))))
            (should (string-match-p "not a git checkout of its own" (harness-revision-error-message err))))
          (should-error (harness-test-await (harness-revision-describe-checkout base)))
          (let ((err (should-error (harness-test-await
                                    (harness-revision-describe-checkout (expand-file-name "gone" base))))))
            (should (string-match-p "gone/ does not exist" (harness-revision-error-message err))))
          ;; None of it is an error of the harness's own.
          (should-not errors))
      (delete-directory base t))))

(ert-deftest harness-revision-notes-what-was-loaded-until-the-next-load ()
  (skip-unless (executable-find "git"))
  (let* ((base (harness-test-temp-dir))
         (repo (file-name-as-directory (expand-file-name "repo" base)))
         (harness-directory repo)
         (harness-revision--loaded nil))
    (unwind-protect
        (let* ((first (progn (make-directory repo t) (harness-version-test--harness-repo repo)))
               (promise (harness-revision-loaded))
               (loaded (harness-test-await promise)))
          (should (equal first (plist-get loaded :commit)))
          (should (equal (file-truename repo) (file-truename (plist-get loaded :directory))))
          (should (equal harness-version (plist-get loaded :version)))
          (should (numberp (plist-get loaded :loaded)))
          ;; A commit in the checkout runs only once the harness loads again.
          (let ((second (harness-version-test--commit repo "second")))
            (should (eq promise (harness-revision-loaded)))
            (should (equal first (plist-get (harness-test-await (harness-revision-loaded)) :commit)))
            (harness-revision-note-loaded)
            (should-not (eq promise (harness-revision-loaded)))
            (should (equal second (plist-get (harness-test-await (harness-revision-loaded)) :commit))))
          ;; A harness from no checkout says why, and is not rejected.
          (let ((harness-directory base))
            (with-temp-file (expand-file-name "harness.el" base) (insert ";; a harness\n"))
            (let ((noted (harness-test-await (harness-revision-note-loaded))))
              (should-not (plist-get noted :commit))
              (should (stringp (plist-get noted :error))))))
      (delete-directory base t))))

(ert-deftest harness-revision-runs-git-without-prompts ()
  (let ((process-environment (copy-sequence process-environment)))
    (setenv "GIT_SSH_COMMAND" nil)
    (setenv "GIT_SSH" nil)
    (let ((env (harness-revision-git-environment)))
      (should (equal "0" (cdr (assoc "GIT_TERMINAL_PROMPT" env))))
      (should (equal "" (cdr (assoc "GIT_ASKPASS" env))))
      (should (equal "never" (cdr (assoc "SSH_ASKPASS_REQUIRE" env))))
      (should (equal "never" (cdr (assoc "GCM_INTERACTIVE" env))))
      (should (string-match-p "BatchMode=yes" (cdr (assoc "GIT_SSH_COMMAND" env)))))
    ;; An ssh command of the user's own is kept.
    (setenv "GIT_SSH_COMMAND" "ssh -i ~/.ssh/harness")
    (should-not (assoc "GIT_SSH_COMMAND" (harness-revision-git-environment)))))

(ert-deftest harness-revision-says-what-went-wrong-with-git ()
  ;; git's fatal error, not the advice it adds for someone at a terminal.
  (should (equal "'/srv/nowhere' does not appear to be a git repository"
                 (harness-revision--git-error
                  '("-c" "credential.helper=" "ls-remote" "/srv/nowhere")
                  '(:exit 128 :stderr "fatal: '/srv/nowhere' does not appear to be a git repository
fatal: Could not read from remote repository.

Please make sure you have the correct access rights
and the repository exists.
"))))
  (should (equal "git ls-remote timed out"
                 (harness-revision--git-error '("-c" "credential.helper=" "ls-remote" "u") '(:exit timeout))))
  (should (equal "git status exited with 1"
                 (harness-revision--git-error '("--no-optional-locks" "status") '(:exit 1 :stderr ""))))
  (should (equal "something odd"
                 (harness-revision--git-error '("log") '(:exit 1 :stderr "warning: x\nsomething odd\n")))))

(ert-deftest harness-version-asks-no-credentials-in-the-background ()
  (skip-unless (executable-find "git"))
  ;; A repository wanting a password fails at once rather than waiting
  ;; for an answer nobody can give, and the askpass programs of the
  ;; user's desktop, which would put a dialog on the screen, never run.
  (let* ((server (harness-test-http-serve
                  '(("/repo/info/refs?service=git-upload-pack"
                     401 (("WWW-Authenticate" . "Basic realm=\"harness\"")) "who are you?"))))
         (url (harness-test-http-url server "/repo"))
         (base (harness-test-temp-dir))
         (askpass (expand-file-name "askpass" base))
         (asked (expand-file-name "asked" base))
         (process-environment (append (list (concat "GIT_ASKPASS=" askpass) (concat "SSH_ASKPASS=" askpass))
                                      process-environment)))
    (with-temp-file askpass (insert "#!/bin/sh\ntouch " (shell-quote-argument asked) "\necho secret\n"))
    (set-file-modes askpass #o755)
    (unwind-protect
        (let* ((started (float-time))
               (origin (harness-test-await
                        (harness-version--read-origin (list :name "private" :kind "remote" :location url))
                        30)))
          (should (equal "error" (plist-get origin :status)))
          (should (string-match-p "could not read Username.*terminal prompts disabled"
                                  (plist-get origin :error)))
          (should (< (- (float-time) started) 20))
          (should-not (file-exists-p asked)))
      (delete-process server)
      (delete-directory base t))))

;;;; Origins

(ert-deftest harness-version-tells-urls-from-directories ()
  (should (harness-version--url-p "https://git.sr.ht/~catvec/emacs-agent-harness"))
  (should (harness-version--url-p "ssh://git@git.sr.ht/~catvec/emacs-agent-harness"))
  (should (harness-version--url-p "git@git.sr.ht:~catvec/emacs-agent-harness"))
  (should (harness-version--url-p "file:///srv/harness"))
  (should-not (harness-version--url-p "/home/me/src/harness"))
  (should-not (harness-version--url-p "~/src/harness"))
  (should (harness-version--url-p "box:srv/harness"))
  (should-not (harness-version--url-p "/ssh:box:/srv/harness"))
  (should-not (harness-version--url-p "/ssh:me@box:/srv/harness"))
  (should-not (harness-version--url-p "C:/src/harness")))

(ert-deftest harness-version-names-repositories-after-their-hosts ()
  (should (equal "github" (harness-version--host-name "https://github.com/catvec/emacs-agent-harness.git")))
  (should (equal "github" (harness-version--host-name "git@github.com:catvec/emacs-agent-harness.git")))
  (should (equal "github" (harness-version--host-name "ssh://git@GitHub.com:22/catvec/emacs-agent-harness")))
  (should (equal "sourcehut" (harness-version--host-name "https://git.sr.ht/~catvec/emacs-agent-harness")))
  (should (equal "sourcehut" (harness-version--host-name "git@git.sr.ht:~catvec/emacs-agent-harness")))
  (should (equal "gitlab" (harness-version--host-name "https://me:secret@gitlab.com/me/harness")))
  (should (equal "git.example.org" (harness-version--host-name "https://git.example.org/harness")))
  (should (equal "box" (harness-version--host-name "box:srv/harness")))
  ;; A repository on this machine has no host to be named after.
  (should (equal "upstream" (harness-version--host-name "file:///srv/harness")))
  (should (equal "upstream" (harness-version--host-name "/srv/harness")))
  (should (equal "upstream" (harness-version--host-name "../harness"))))

(ert-deftest harness-version-lists-each-origin-once ()
  (harness-version-test-with
    (let* ((checkout (file-name-as-directory (expand-file-name "checkout" base)))
           (running (list :commit "0123abc" :directory checkout))
           (url "https://git.sr.ht/~catvec/emacs-agent-harness"))
      (make-directory checkout t)
      (setq harness-version-origins
            (list (list :name "sourcehut" :location url)
                  (list :name "again" :location (concat url ".git/"))
                  (list :name "its main" :location url :branch "main")
                  (list :name "the checkout" :location (directory-file-name checkout))
                  (list :name "its next" :location checkout :branch "next")
                  (list :name "empty" :location "")
                  (list :name "nowhere")))
      (should (equal '(("loaded" "loaded" nil) ("its next" "local" "next")
                       ("sourcehut" "remote" nil) ("its main" "remote" "main"))
                     (mapcar (lambda (o) (list (plist-get o :name) (plist-get o :kind) (plist-get o :branch)))
                             (harness-version--origins running))))
      ;; Without a commit, the checkout is compared as configured.
      (should (equal '("the checkout" "its next" "sourcehut" "its main")
                     (mapcar (lambda (o) (plist-get o :name))
                             (harness-version--origins (list :directory checkout :error "no commit")))))
      ;; The repository the checkout pulls from comes first of its kind,
      ;; unless the configuration names it already, on its branch or none.
      (cl-flet ((names (upstream)
                  (mapcar (lambda (o) (plist-get o :name)) (harness-version--origins running upstream)))
                (up (name kind location branch)
                  (list :name name :kind kind :location location :branch branch :upstream t)))
        (let ((github "https://github.com/catvec/emacs-agent-harness.git")
              (mirror (file-name-as-directory (expand-file-name "mirror" base))))
          (should (equal '("loaded" "its next" "github" "sourcehut" "its main")
                         (names (up "github" "remote" github "main"))))
          (should (eq t (plist-get (nth 2 (harness-version--origins running (up "github" "remote" github "main")))
                                   :upstream)))
          (should (equal '("loaded" "upstream" "its next" "sourcehut" "its main")
                         (names (up "upstream" "local" mirror "main"))))
          (should (equal '("loaded" "its next" "sourcehut" "its main")
                         (names (up "sourcehut" "remote" (concat url ".git") "trunk"))))
          (let ((harness-version-origins (list (list :name "its main" :location url :branch "main"))))
            (should (equal '("loaded" "its main") (names (up "sourcehut" "remote" url "main"))))
            (should (equal '("loaded" "sourcehut" "its main") (names (up "sourcehut" "remote" url "next"))))))))))

(ert-deftest harness-version-finds-the-repository-the-checkout-pulls-from ()
  (skip-unless (executable-find "git"))
  (harness-version-test-with
    (let* ((w (harness-version-test--world base))
           (installed (plist-get w :installed))
           (url (plist-get w :url))
           (github "https://github.com/catvec/emacs-agent-harness.git")
           (running (list :commit (plist-get w :first) :branch "main" :directory installed)))
      (cl-flet ((upstream (&optional revision)
                  (harness-test-await (harness-version--upstream (or revision running))))
                (track (remote branch)
                  (harness-version-test--git installed "config" "branch.main.remote" remote)
                  (harness-version-test--git installed "config" "branch.main.merge" (concat "refs/heads/" branch))))
        ;; As straight.el clones it: main tracks the recipe's repository.
        (should (equal (list :name "upstream" :kind "remote" :location url :branch "main" :upstream t)
                       (upstream)))
        ;; Cloned from GitHub, on another branch: the remote and the
        ;; branch main tracks count, whatever the remote is called.
        (harness-version-test--git installed "remote" "add" "github" github)
        (track "github" "trunk")
        (should (equal (list :name "github" :kind "remote" :location github :branch "trunk" :upstream t)
                       (upstream)))
        ;; On a detached HEAD: origin, and the branch its HEAD names.
        (should (equal (list :name "upstream" :kind "remote" :location url :branch nil :upstream t)
                       (upstream (list :commit (plist-get w :first) :directory installed))))
        ;; A remote that is a directory, relative to the checkout as git
        ;; reads it, is a local repository.
        (harness-version-test--git installed "remote" "add" "mirror" "../upstream")
        (track "mirror" "main")
        (should (equal (list :name "upstream" :kind "local" :location (plist-get w :upstream) :branch "main"
                             :upstream t)
                       (upstream)))
        ;; A branch tracking another of its own checkout: origin.
        (track "." "next")
        (should (equal (list :name "upstream" :kind "remote" :location url :branch nil :upstream t)
                       (upstream)))
        ;; A checkout with no remote pulls from nowhere, nor does a harness
        ;; loaded from no commit.
        (dolist (remote '("origin" "github" "mirror"))
          (harness-version-test--git installed "remote" "remove" remote))
        (should-not (upstream))
        (should-not (upstream (list :directory installed :error "no commit")))))))

(ert-deftest harness-version-finds-the-checkouts-sessions-work-in ()
  (skip-unless (executable-find "git"))
  (harness-version-test-with
    (let* ((w (harness-version-test--world base))
           (dev (plist-get w :dev))
           (task (file-name-as-directory (expand-file-name "task" base)))
           (other (file-name-as-directory (expand-file-name "other" base))))
      (harness-version-test--git dev "worktree" "add" "-q" "-b" "task" task)
      (make-directory other t)
      (harness-version-test--git other "init" "-q")
      (should-not (harness-version--session-checkouts))
      ;; A task's worktree leads to the checkout it belongs to; another
      ;; project is no harness, and remote ones are not looked at.
      (harness-version-test--sessions-in task dev other
                                         (list :project (plist-get w :upstream) :host "box")
                                         "/ssh:box:/srv/harness/")
      (should (equal (list (file-truename dev))
                     (mapcar #'file-truename (harness-version--session-checkouts))))
      (setq harness-version-origins (list (list :name "upstream" :location (plist-get w :upstream))))
      (should (equal '(("upstream" "local") ("local" "local"))
                     (mapcar (lambda (o) (list (plist-get o :name) (plist-get o :kind)))
                             (harness-version--origins nil)))))))

(ert-deftest harness-version-relates-commits-in-full-clones-first ()
  ;; A package manager's clone is shallow: the local checkouts come
  ;; first, the one the harness was loaded from last.
  (should (equal '("/a/" "/c/" "/loaded/")
                 (harness-version--repositories
                  (list :commit "0123abc" :directory "/loaded/")
                  (list (list :kind "loaded" :location "/loaded/")
                        (list :kind "local" :location "/a/")
                        (list :kind "local" :location "/b/" :status "error" :error "gone")
                        (list :kind "remote" :location "https://example.invalid/harness")
                        (list :kind "local" :location "/loaded/")
                        (list :kind "local" :location "/c/"))))))

;;;; Reports

(ert-deftest harness-version-finds-the-commits-the-harness-lacks ()
  (skip-unless (executable-find "git"))
  (harness-version-test-with
    (let* ((w (harness-version-test--world base))
           (installed (plist-get w :installed)))
      ;; Nothing is configured: the origins are found.
      (setq harness-directory installed)
      (harness-version-test--sessions-in (plist-get w :dev))
      (let* ((report (harness-version-test--check))
             (running (plist-get report :running))
             (loaded (harness-version-test--origin report "loaded"))
             (dev (harness-version-test--origin report "local"))
             (upstream (harness-version-test--origin report "upstream")))
        (should (equal "behind" (plist-get report :verdict)))
        (should (equal harness-version (plist-get report :version)))
        (should (numberp (plist-get report :checked)))
        ;; What runs is what the installed checkout held when it loaded.
        (should (equal (plist-get w :first) (plist-get running :commit)))
        (should (equal "main" (plist-get running :branch)))
        (should (equal "first" (plist-get running :subject)))
        (should (numberp (plist-get running :date)))
        (should-not (plist-get running :dirty))
        (should (equal (file-truename installed) (file-truename (plist-get running :directory))))
        ;; The loaded checkout first, then local checkouts, then remote ones.
        (should (equal '("loaded" "local" "remote")
                       (mapcar (lambda (o) (plist-get o :kind)) (plist-get report :origins))))
        (should (equal "same" (plist-get loaded :status)))
        (should (equal (list "newer" 2 0 (plist-get w :third) "third")
                       (mapcar (lambda (k) (plist-get dev k)) '(:status :missing :extra :commit :subject))))
        (should (equal '("third" "second") (harness-version-test--subjects (plist-get dev :missing-commits))))
        (should-not (plist-get dev :extra-commits))
        ;; The repository the installed checkout pulls from, on its branch;
        ;; the development checkout holds its commit, so it is counted.
        (should (equal (list "newer" 1 0 (plist-get w :second) (plist-get w :url) "main" t)
                       (mapcar (lambda (k) (plist-get upstream k))
                               '(:status :missing :extra :commit :location :branch :upstream))))
        (should (equal '("second") (harness-version-test--subjects (plist-get upstream :missing-commits))))))))

(ert-deftest harness-version-follows-the-loaded-checkout-until-a-reload ()
  (skip-unless (executable-find "git"))
  (harness-version-test-with
    (let* ((w (harness-version-test--world base))
           (installed (plist-get w :installed)))
      (setq harness-directory installed)
      (cl-flet ((statuses (report)
                  (mapcar (lambda (o) (list (plist-get o :name) (plist-get o :status))) (plist-get report :origins))))
        ;; The repository it pulls from has a commit the installed
        ;; checkout lacks, as a package manager's clone does until it
        ;; is pulled: the harness lacks it too, by commits not counted.
        (let* ((report (harness-version-test--check))
               (upstream (harness-version-test--origin report "upstream")))
          (should (equal "behind" (plist-get report :verdict)))
          (should (equal '(("loaded" "same") ("upstream" "ahead")) (statuses report)))
          (should (equal (plist-get w :second) (plist-get upstream :commit)))
          (should-not (plist-get upstream :missing))
          (should (eq report (harness-version-test--check))))
        ;; A pull: the checkout holds a commit the harness does not run yet.
        (harness-version-test--git installed "pull" "-q" "--ff-only")
        (let* ((report (harness-version-test--check 0))
               (loaded (harness-version-test--origin report "loaded")))
          (should (equal "behind" (plist-get report :verdict)))
          (should (equal '(("loaded" "newer") ("upstream" "newer")) (statuses report)))
          (should (equal (plist-get w :first) (plist-get (plist-get report :running) :commit)))
          (should (equal (list "newer" 1 (plist-get w :second))
                         (mapcar (lambda (k) (plist-get loaded k)) '(:status :missing :commit)))))
        ;; A reload runs it, with the change made to it since.
        (with-temp-file (expand-file-name "harness.el" installed) (insert ";; changed\n"))
        (harness-revision-note-loaded)
        (let* ((report (harness-version-test--check))
               (running (plist-get report :running)))
          (should (equal "latest" (plist-get report :verdict)))
          (should (equal '(("loaded" "same") ("upstream" "same")) (statuses report)))
          (should (equal (plist-get w :second) (plist-get running :commit)))
          (should (eq t (plist-get running :dirty)))
          (should (eq t (plist-get (harness-version-test--origin report "loaded") :dirty))))))))

(ert-deftest harness-version-places-older-ahead-and-unknown-origins ()
  (skip-unless (executable-find "git"))
  (harness-version-test-with
    (let* ((w (harness-version-test--world base))
           (upstream (plist-get w :upstream))
           (url (plist-get w :url)))
      ;; The harness runs from the development checkout, at third.
      (setq harness-directory (plist-get w :dev))
      (harness-version-test--git upstream "branch" "old" (plist-get w :first))
      (setq harness-version-origins (list (list :name "main" :location url :branch "main")
                                          (list :name "old" :location url :branch "old")))
      (let* ((report (harness-version-test--check))
             (main (harness-version-test--origin report "main"))
             (old (harness-version-test--origin report "old")))
        (should (equal "latest" (plist-get report :verdict)))
        (should (equal '("older" 0 1) (mapcar (lambda (k) (plist-get main k)) '(:status :missing :extra))))
        (should (equal '("third") (harness-version-test--subjects (plist-get main :extra-commits))))
        (should (equal "second" (plist-get main :subject)))
        (should (equal '("older" 0 2) (mapcar (lambda (k) (plist-get old k)) '(:status :missing :extra)))))
      ;; A commit no local repository holds is not counted: nothing is
      ;; fetched.  The checkout the harness was loaded from lacks it, so
      ;; the harness does: the origin is ahead.
      (harness-version-test--git upstream "checkout" "-q" "-b" "next")
      (let ((fourth (harness-version-test--commit upstream "fourth")))
        (setq harness-version-origins (list (list :name "next" :location url :branch "next")))
        (let* ((report (harness-version-test--check 0))
               (next (harness-version-test--origin report "next")))
          (should (equal "behind" (plist-get report :verdict)))
          (should (equal "ahead" (plist-get next :status)))
          (should (equal fourth (plist-get next :commit)))
          (should-not (plist-get next :missing))
          ;; Configured no more, the repository the checkout pulls from
          ;; is found by itself.
          (should (equal '("older" 0 1 t)
                         (mapcar (lambda (k) (plist-get (harness-version-test--origin report "upstream") k))
                                 '(:status :missing :extra :upstream))))))
      ;; When it is the running commit no repository holds, as after a
      ;; history was rewritten, nothing can be said.
      (let ((origin (list :name "main" :commit (plist-get w :second))))
        (should (equal "unknown"
                       (plist-get (harness-test-await
                                   (harness-version--relate (list :commit (make-string 40 ?f) :directory (plist-get w :dev))
                                                            origin (list (plist-get w :dev))))
                                  :status)))
        (should (equal "unknown"
                       (plist-get (harness-test-await
                                   (harness-version--relate (list :commit (make-string 40 ?f)
                                                                  :directory (expand-file-name "gone/" base))
                                                            origin nil))
                                  :status)))))))

(ert-deftest harness-version-sees-an-origin-that-diverged ()
  (skip-unless (executable-find "git"))
  (harness-version-test-with
    (let* ((w (harness-version-test--world base))
           (installed (plist-get w :installed))
           (dev (plist-get w :dev)))
      ;; The installed checkout has a fix of its own, which the
      ;; development checkout fetched: it holds both sides.
      (harness-version-test--commit installed "local fix")
      (harness-version-test--git dev "fetch" "-q" installed "main")
      (setq harness-directory installed
            harness-version-origins (list (list :name "dev" :location dev)))
      (let* ((report (harness-version-test--check))
             (o (harness-version-test--origin report "dev")))
        (should (equal "behind" (plist-get report :verdict)))
        (should (equal '("diverged" 2 1) (mapcar (lambda (k) (plist-get o k)) '(:status :missing :extra))))
        (should (equal '("third" "second") (harness-version-test--subjects (plist-get o :missing-commits))))
        (should (equal '("local fix") (harness-version-test--subjects (plist-get o :extra-commits))))))))

(ert-deftest harness-version-reports-origins-it-cannot-read ()
  (skip-unless (executable-find "git"))
  (harness-version-test-with
    (let* ((w (harness-version-test--world base))
           (dev (plist-get w :dev))
           (plain (file-name-as-directory (expand-file-name "plain" base))))
      (make-directory plain t)
      ;; The installed checkout pulls from nowhere: every origin is one
      ;; configured.
      (harness-version-test--git (plist-get w :installed) "remote" "remove" "origin")
      (setq harness-directory (plist-get w :installed)
            harness-version-origins
            (list (list :name "gone" :location (expand-file-name "gone/" base))
                  (list :name "plain" :location plain)
                  (list :name "inside" :location (expand-file-name "lisp/" dev))
                  (list :name "no branch" :location dev :branch "nope")
                  (list :name "an option" :location dev :branch "--output=x")
                  (list :name "nowhere" :location (concat "file://" (expand-file-name "nowhere" base)))
                  (list :name "no remote branch" :location (plist-get w :url) :branch "nope")))
      (let ((report (harness-version-test--check)))
        (dolist (o (cdr (plist-get report :origins)))
          (should (equal "error" (plist-get o :status)))
          (should (stringp (plist-get o :error))))
        (cl-flet ((err (name) (plist-get (harness-version-test--origin report name) :error)))
          (should (string-match-p "gone/ does not exist" (err "gone")))
          (should (string-match-p "not a git checkout of its own" (err "inside")))
          (should (equal "it has no branch nope" (err "no branch")))
          (should (equal "--output=x is no branch name" (err "an option")))
          (should (string-match-p "does not appear to be a git repository" (err "nowhere")))
          (should (equal "it has no branch nope" (err "no remote branch"))))
        (should-not (file-exists-p (expand-file-name "x" dev)))
        ;; What could be read is the commit running.
        (should (equal "same" (plist-get (harness-version-test--origin report "loaded") :status)))
        (should (equal "latest" (plist-get report :verdict))))
      ;; A harness from no checkout cannot be placed at all.
      (setq harness-directory plain
            harness-version-origins (list (list :name "sourcehut" :location (plist-get w :url))))
      (with-temp-file (expand-file-name "harness.el" plain) (insert ";; a harness\n"))
      (harness-revision-note-loaded)
      (let ((report (harness-version-test--check)))
        (should (equal "unknown" (plist-get report :verdict)))
        (should (stringp (plist-get (plist-get report :running) :error)))
        (should (equal '(("sourcehut" "unknown"))
                       (mapcar (lambda (o) (list (plist-get o :name) (plist-get o :status)))
                               (plist-get report :origins))))))))

;;;; Checking in the background

(ert-deftest harness-version-checks-once-for-every-caller ()
  (skip-unless (executable-find "git"))
  (harness-version-test-with
    (let ((w (harness-version-test--world base))
          (events nil))
      (setq harness-directory (plist-get w :installed))
      (harness-on 'version/checked (lambda (report) (push report events)))
      (let ((p1 (harness-call 'version/check))
            (p2 (harness-call 'version/check 0)))
        ;; A second caller joins the check running.
        (should (eq p1 p2))
        (let ((report (harness-test-await p1 60)))
          (should (equal (list report) events))
          ;; The report answers until it is older than asked for.
          (should (eq report (harness-version-test--check)))
          (should (eq report (harness-version-test--check 3600)))
          (let ((fresh (harness-version-test--check 0)))
            (should-not (eq report fresh))
            (should (equal 2 (length events)))
            ;; After a reload another revision runs: the report no longer answers.
            (harness-revision-note-loaded)
            (should-not (eq fresh (harness-version-test--check)))
            (should (equal 3 (length events))))))
      ;; A check stuck for long is replaced, not joined.
      (let ((stuck (harness-make-promise)))
        (setq harness-version--checking (list (harness-revision-loaded) (- (float-time) 1000) stuck))
        (let ((promise (harness-call 'version/check 0)))
          (should-not (eq promise stuck))
          (harness-test-await promise 60)
          (should-not harness-version--checking))))))

(ert-deftest harness-version-checks-by-itself ()
  (harness-version-test-with
    (let ((timer harness-version--timer))
      (should (timerp timer))
      (should (memq timer timer-list))
      (should (eq #'harness-version--background-check (timer--function timer)))
      (should (equal harness-version--interval (timer--repeat-delay timer)))
      (should (< 20 (- (float-time (timer--time timer)) (float-time)) 31))
      ;; A reload checks again soon.
      (harness-emit 'harness/reloaded)
      (should-not (memq timer timer-list))
      (let ((soon harness-version--timer))
        (should (memq soon timer-list))
        (should (< 0 (- (float-time (timer--time soon)) (float-time)) 4))
        (should (equal harness-version--interval (timer--repeat-delay soon)))
        (harness-modules-shutdown)
        (should-not (memq soon timer-list))
        (should-not harness-version--timer)
        (harness-emit 'harness/reloaded)
        (should-not harness-version--timer)))))

(ert-deftest harness-version-goes-over-acp ()
  ;; The UI asks with _harness/version/check and hears version/checked.
  (let ((harness-acp--server-enabled nil))
    (harness-test-reset-bus)
    (harness-test-load-module 'acp))
  (should (harness-acp--extension-allowed-p "version/check"))
  (should (memq 'version/checked harness-acp--forwarded-events)))

(ert-deftest harness-version-origins-option-is-documented ()
  ;; With the module loaded: the docstring is read from its compiled file.
  (harness-version-test-with
    (let ((type (get 'harness-version-origins 'custom-type)))
      (should (harness-test-fits-p type (eval (car (get 'harness-version-origins 'standard-value)) t)))
      (let ((entry (cadr type)))
        (should (equal '(:name :location :branch) (harness-test-option-keys entry)))
        (should (equal (harness-test-option-keys entry) (harness-test-documented-keys 'harness-version-origins)))
        (harness-test-check-record-type entry)))))

(provide 'harness-version-test)
;;; harness-version-test.el ends here
