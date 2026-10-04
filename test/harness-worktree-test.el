;;; harness-worktree-test.el --- Tests for the worktree module  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-worktree-directory-function)

(defun harness-worktree-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure, return stdout."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string)))
      (buffer-string))))

(defun harness-worktree-test--make-repo ()
  "Create BASE/repo with one commit; return (BASE . ROOT)."
  (let* ((base (harness-test-temp-dir))
         (root (file-name-as-directory (expand-file-name "repo" base))))
    (make-directory root t)
    (harness-worktree-test--git root "init" "-q" "-b" "main")
    (harness-worktree-test--git root "config" "user.name" "Harness Test")
    (harness-worktree-test--git root "config" "user.email" "test@example.invalid")
    (harness-worktree-test--git root "config" "commit.gpgsign" "false")
    (with-temp-file (expand-file-name "README" root) (insert "hello\n"))
    (harness-worktree-test--git root "add" "README")
    (harness-worktree-test--git root "commit" "-q" "-m" "initial")
    (cons base root)))

(defmacro harness-worktree-test-with-repo (&rest body)
  "Run BODY with `base' and `root' bound to a fresh git repository."
  (declare (indent 0))
  `(progn
     (harness-test-reset-bus)
     (harness-test-load-module 'project)
     (harness-test-load-module 'worktree)
     (let* ((repo (harness-worktree-test--make-repo))
            (base (car repo))
            (root (cdr repo)))
       (ignore base root)
       (unwind-protect (progn ,@body)
         (ignore-errors (delete-directory base t))))))

(defun harness-worktree-test--dir (path)
  "Return PATH's truename as a directory name, for comparisons."
  (file-name-as-directory (file-truename path)))

(defun harness-worktree-test--find (worktrees path)
  "Return the entry of WORKTREES whose :path is PATH."
  (cl-find-if (lambda (wt) (string= (harness-worktree-test--dir (plist-get wt :path))
                                    (harness-worktree-test--dir path)))
              worktrees))

(ert-deftest harness-worktree-list-main-only ()
  (harness-worktree-test-with-repo
    (let ((wts (harness-test-await (harness-call 'worktree/list root))))
      (should (= 1 (length wts)))
      (let ((main (car wts)))
        (should (plist-get main :main))
        (should (equal "main" (plist-get main :branch)))
        (should (= 40 (length (plist-get main :head))))
        (should-not (plist-get main :bare))
        (should-not (plist-get main :detached))
        (should-not (plist-get main :locked))
        (should (equal (harness-worktree-test--dir root) (harness-worktree-test--dir (plist-get main :path))))))))

(ert-deftest harness-worktree-create-list-status-remove ()
  (harness-worktree-test-with-repo
    (let* ((created nil) (removed nil)
           (path (expand-file-name "wt-feature" base)))
      (harness-on 'worktree/created (lambda (r wt) (push (cons r wt) created)))
      (harness-on 'worktree/removed (lambda (r p) (push (cons r p) removed)))
      ;; Create with an explicit branch and path.
      (let ((wt (harness-test-await (harness-call 'worktree/create root :branch "feature/x" :path path))))
        (should (equal "feature/x" (plist-get wt :branch)))
        (should (equal (harness-worktree-test--dir path) (harness-worktree-test--dir (plist-get wt :path))))
        (should-not (plist-get wt :main))
        (should (file-exists-p (expand-file-name "README" path)))
        (should (= 1 (length created)))
        (should (equal "feature/x" (plist-get (cdar created) :branch))))
      ;; The list shows it with its branch.
      (let* ((wts (harness-test-await (harness-call 'worktree/list root)))
             (entry (harness-worktree-test--find wts path)))
        (should (= 2 (length wts)))
        (should entry)
        (should (equal "feature/x" (plist-get entry :branch)))
        (should (plist-get (car wts) :main))
        (should-not (plist-get entry :main)))
      (should (equal "feature/x" (harness-test-await (harness-call 'worktree/branch path))))
      (should (equal "main" (harness-test-await (harness-call 'worktree/branch root))))
      ;; Clean, no upstream.
      (should (equal '(:dirty nil :ahead 0 :behind 0 :branch "feature/x")
                     (harness-test-await (harness-call 'worktree/status path))))
      ;; Ahead of its upstream after a commit.
      (harness-worktree-test--git path "branch" "--set-upstream-to=main")
      (with-temp-file (expand-file-name "new.txt" path) (insert "x\n"))
      (harness-worktree-test--git path "add" "new.txt")
      (harness-worktree-test--git path "commit" "-q" "-m" "work")
      (let ((st (harness-test-await (harness-call 'worktree/status path))))
        (should-not (plist-get st :dirty))
        (should (= 1 (plist-get st :ahead)))
        (should (= 0 (plist-get st :behind))))
      ;; Dirty after an untracked file appears.
      (with-temp-file (expand-file-name "scratch.txt" path) (insert "dirty\n"))
      (should (plist-get (harness-test-await (harness-call 'worktree/status path)) :dirty))
      ;; Removing a dirty worktree without force rejects with git's stderr.
      (let ((err (should-error (harness-test-await (harness-call 'worktree/remove root path))
                               :type 'harness-error)))
        (should (string-match-p "modified or untracked" (harness-error-message err))))
      (should (file-directory-p path))
      ;; With force it goes away.
      (should (equal (file-name-as-directory path)
                     (harness-test-await (harness-call 'worktree/remove root path t))))
      (should-not (file-exists-p path))
      (should (= 1 (length removed)))
      (should (= 1 (length (harness-test-await (harness-call 'worktree/list root)))))
      ;; The branch survives the worktree; creating again reuses it (no -b).
      (let ((wt (harness-test-await (harness-call 'worktree/create root :branch "feature/x" :path path))))
        (should (equal "feature/x" (plist-get wt :branch)))
        (should (file-exists-p (expand-file-name "new.txt" path)))))))

(ert-deftest harness-worktree-create-defaults-and-base ()
  (harness-worktree-test-with-repo
    ;; Default branch and path come from the prefix and the directory function.
    (let* ((wt (harness-test-await (harness-call 'worktree/create root)))
           (branch (plist-get wt :branch))
           (expected (expand-file-name (replace-regexp-in-string "/" "-" branch)
                                       (expand-file-name ".worktrees" root))))
      (should (string-prefix-p "harness/" branch))
      (should (equal (harness-worktree-test--dir expected) (harness-worktree-test--dir (plist-get wt :path))))
      (should (file-directory-p expected))
      ;; The container ignores itself, so the main checkout stays clean.
      (should (equal "" (harness-worktree-test--git root "status" "--porcelain"))))
    ;; A custom directory function and an explicit base commit.
    (let* ((harness-worktree-directory-function
            (lambda (r b) (expand-file-name (concat "custom-" (file-name-nondirectory b))
                                            (expand-file-name "elsewhere" (file-name-directory (directory-file-name r))))))
           (head (string-trim (harness-worktree-test--git root "rev-parse" "HEAD"))))
      (with-temp-file (expand-file-name "second" root) (insert "2\n"))
      (harness-worktree-test--git root "add" "second")
      (harness-worktree-test--git root "commit" "-q" "-m" "second")
      (let ((wt (harness-test-await (harness-call 'worktree/create root :branch "old" :base head))))
        (should (equal "old" (plist-get wt :branch)))
        (should (equal (harness-worktree-test--dir (expand-file-name "elsewhere/custom-old" base))
                       (harness-worktree-test--dir (plist-get wt :path))))
        (should (equal head (plist-get wt :head)))
        (should-not (file-exists-p (expand-file-name "second" (plist-get wt :path))))))
    ;; Errors from git reject the promise with its stderr.
    (let ((err (should-error (harness-test-await (harness-call 'worktree/create root :branch "old"))
                             :type 'harness-error)))
      (should (string-match-p "already" (harness-error-message err))))
    (should-error (harness-test-await (harness-call 'worktree/list (harness-test-temp-dir)))
                  :type 'harness-error)))

(ert-deftest harness-files-main-root-of-a-worktree ()
  "A linked worktree's main root is the main checkout, without running git."
  (harness-worktree-test-with-repo
    (let ((path (expand-file-name "wt-main-root" base)))
      (harness-worktree-test--git root "worktree" "add" "-q" "-b" "main-root" path)
      (make-directory (expand-file-name "sub" path) t)
      (should (equal (harness-worktree-test--dir root)
                     (harness-worktree-test--dir (harness-files-main-root (expand-file-name "sub" path)))))
      (should (equal (harness-worktree-test--dir root)
                     (harness-worktree-test--dir (harness-files-main-root root))))
      ;; Outside git it is the plain root.
      (let ((plain (harness-test-temp-dir)))
        (should (equal (file-name-as-directory plain) (harness-files-main-root plain)))))))

(ert-deftest harness-files-main-checkout-of-a-root ()
  "A root's main checkout comes from its own .git file, CRLF or not."
  (harness-worktree-test-with-repo
    (let ((path (file-name-as-directory (expand-file-name "wt-checkout" base))))
      (harness-worktree-test--git root "worktree" "add" "-q" "-b" "checkout" path)
      (should (equal (harness-worktree-test--dir root)
                     (harness-worktree-test--dir (harness-files-main-checkout path))))
      (should (equal root (harness-files-main-checkout root)))
      ;; A directory below a root is not looked up the tree, unlike
      ;; `harness-files-main-root'.
      (let ((sub (expand-file-name "sub/" path)))
        (make-directory sub)
        (should (equal sub (harness-files-main-checkout sub))))
      ;; A .git file with CRLF line ends.
      (let ((crlf (file-name-as-directory (expand-file-name "wt-crlf" base)))
            (dotgit (with-temp-buffer
                      (insert-file-contents (expand-file-name ".git" path))
                      (buffer-string))))
        (make-directory crlf)
        (with-temp-file (expand-file-name ".git" crlf)
          (insert (replace-regexp-in-string "\n" "\r\n" dotgit)))
        (should (equal (harness-worktree-test--dir root)
                       (harness-worktree-test--dir (harness-files-main-checkout crlf)))))
      ;; Remote roots come back untouched.
      (let ((remote "/ssh:nobody@example.invalid:/srv/x/"))
        (should (file-remote-p remote)) ; loads TRAMP before file access is watched
        (cl-letf (((symbol-function 'file-regular-p) (lambda (&rest _) (error "Looked at"))))
          (should (equal remote (harness-files-main-checkout remote))))))))

(ert-deftest harness-files-main-checkout-of-a-pruned-worktree ()
  "A worktree whose registration git pruned still names its main checkout.
Its gitdir, ROOT/.git/worktrees/ID, is gone; a submodule's is no worktree."
  (harness-worktree-test-with-repo
    (let ((path (file-name-as-directory (expand-file-name "wt-pruned" base))))
      (harness-worktree-test--git root "worktree" "add" "-q" "-b" "pruned" path)
      (delete-directory (expand-file-name ".git/worktrees/wt-pruned" root) t)
      (should (file-regular-p (expand-file-name ".git" path)))
      (should (equal (harness-worktree-test--dir root)
                     (harness-worktree-test--dir (harness-files-main-checkout path))))
      ;; The sandbox's common dir is left as it was: none for a gitdir gone.
      (should-not (harness-files-git-common-dir path))
      ;; A .git file naming a submodule's gitdir is its own checkout.
      (let ((module (harness-test-temp-dir)))
        (with-temp-file (expand-file-name ".git" module)
          (insert (format "gitdir: %s\n" (expand-file-name ".git/modules/lib" root))))
        (should (equal module (harness-files-main-checkout module)))))))

(ert-deftest harness-files-owning-checkout-of-every-root ()
  "The main checkout a session's root belongs to, gone from disk or not."
  (harness-worktree-test-with-repo
    (let ((live (file-name-as-directory (expand-file-name ".worktrees/task-live" root)))
          (gone (file-name-as-directory (expand-file-name ".worktrees/task-gone" root)))
          (plain (harness-test-temp-dir)))
      (harness-worktree-test--git root "worktree" "add" "-q" "-b" "task/live" live)
      (harness-worktree-test--git root "worktree" "add" "-q" "-b" "task/gone" gone)
      (harness-worktree-test--git root "worktree" "remove" gone)
      (should-not (file-exists-p gone))
      (dolist (dir (list root live gone))
        (should (equal (harness-worktree-test--dir root)
                       (harness-worktree-test--dir (harness-files-owning-checkout dir)))))
      (should (equal plain (harness-files-owning-checkout plain)))
      ;; Remote roots are not looked at.
      (let ((remote "/ssh:nobody@example.invalid:/srv/x/"))
        (should (file-remote-p remote)) ; loads TRAMP before file access is watched
        (cl-letf (((symbol-function 'file-directory-p) (lambda (&rest _) (error "Looked at")))
                  ((symbol-function 'harness-files-main-root) (lambda (&rest _) (error "Looked at"))))
          (should (equal remote (harness-files-owning-checkout remote))))))))

(ert-deftest harness-files-git-common-dir-is-the-main-repository ()
  "Every directory of a repository, linked worktrees included, shares the main .git."
  (harness-worktree-test-with-repo
    (let ((git (harness-worktree-test--dir (expand-file-name ".git" root)))
          (path (file-name-as-directory (expand-file-name "wt-common" base))))
      (harness-worktree-test--git root "worktree" "add" "-q" "-b" "common" path)
      (make-directory (expand-file-name "sub/dir" path) t)
      (make-directory (expand-file-name "lib" root) t)
      (dolist (dir (list root (expand-file-name "lib" root) path (expand-file-name "sub/dir" path)))
        (should (equal git (harness-worktree-test--dir (harness-files-git-common-dir dir)))))
      ;; Not a worktree's own gitdir, which lies in the main .git too.
      (should-not (string-match-p "/worktrees/" (harness-files-git-common-dir path)))
      ;; Outside a repository, behind a .git file pointing nowhere, or remote: none.
      (should-not (harness-files-git-common-dir (harness-test-temp-dir)))
      (let ((stale (harness-test-temp-dir)))
        (with-temp-file (expand-file-name ".git" stale)
          (insert "gitdir: /nonexistent/repo/.git/worktrees/gone\n"))
        (should-not (harness-files-git-common-dir stale)))
      (let ((remote "/ssh:nobody@example.invalid:/srv/x/"))
        (should (file-remote-p remote)) ; loads TRAMP before file access is watched
        (cl-letf (((symbol-function 'locate-dominating-file) (lambda (&rest _) (error "Looked at"))))
          (should-not (harness-files-git-common-dir remote)))))))

(ert-deftest harness-files-main-checkout-non-ascii-path ()
  "The .git file and commondir are read as UTF-8, as git writes them."
  (skip-unless (eq 'utf-8 (coding-system-base
                           (or file-name-coding-system default-file-name-coding-system 'undecided))))
  (harness-worktree-test-with-repo
    ;; wt- then u with diaeresis, n, i with diaeresis, c, o with stroke, d, e with acute.
    (let* ((name (concat "wt-" (string #xfc ?n #xef ?c #xf8 ?d #xe9)))
           (path (file-name-as-directory (expand-file-name name base))))
      (harness-worktree-test--git root "worktree" "add" "-q" "-b" "unicode" path)
      (should (equal (harness-worktree-test--dir root)
                     (harness-worktree-test--dir (harness-files-main-checkout path))))
      (should (equal (harness-worktree-test--dir root)
                     (harness-worktree-test--dir (harness-files-main-root path)))))))

(ert-deftest harness-worktree-root-of ()
  (harness-worktree-test-with-repo
    (let ((path (expand-file-name "wt-root-of" base)))
      (harness-test-await (harness-call 'worktree/create root :branch "root-of" :path path))
      (make-directory (expand-file-name "sub/dir" path) t)
      (should (equal (harness-worktree-test--dir root)
                     (harness-test-await (harness-call 'worktree/root-of (expand-file-name "sub/dir" path)))))
      (should (equal (harness-worktree-test--dir root)
                     (harness-test-await (harness-call 'worktree/root-of (expand-file-name "README" path)))))
      (should (equal (harness-worktree-test--dir root) (harness-test-await (harness-call 'worktree/root-of root)))))))

(defun harness-worktree-test--lock-line (root path)
  "Return the `locked' line `git worktree list --porcelain' gives PATH of ROOT.
nil when it is not locked or not registered."
  (cl-some (lambda (block)
             (let ((lines (split-string block "\n" t)))
               (and (string-prefix-p "worktree " (car lines))
                    (equal (harness-worktree-test--dir (substring (car lines) 9)) (harness-worktree-test--dir path))
                    (seq-find (lambda (l) (string-prefix-p "locked" l)) lines))))
           (split-string (harness-worktree-test--git root "worktree" "list" "--porcelain") "\n\n" t)))

(defun harness-worktree-test--create (root branch)
  "Create a worktree of ROOT on BRANCH the way the harness does; return its path."
  (plist-get (harness-test-await (harness-call 'worktree/create root :branch branch)) :path))

(ert-deftest harness-worktree-create-locks ()
  "The harness locks every worktree it makes, naming the branch."
  (harness-worktree-test-with-repo
    (let ((new (harness-worktree-test--create root "task/new")))
      (should (equal "locked harness: task/new" (harness-worktree-test--lock-line root new)))
      (let ((wt (harness-worktree-test--find (harness-test-await (harness-call 'worktree/list root)) new)))
        (should (plist-get wt :locked))
        (should (equal "harness: task/new" (plist-get wt :lock-reason)))
        (should (harness-worktree-harness-lock-p wt))
        (should-not (plist-get wt :missing)))
      ;; An existing branch is checked out locked as well.
      (harness-test-await (harness-call 'worktree/remove root new))
      (let ((again (harness-worktree-test--create root "task/new")))
        (should (equal "locked harness: task/new" (harness-worktree-test--lock-line root again))))
      ;; The main checkout never is.
      (should-not (harness-worktree-test--lock-line root root)))))

(ert-deftest harness-worktree-locked-survives-a-hidden-prune ()
  "A prune that cannot see the worktree directories keeps the locked ones.
That is a prune in a session's sandbox: git takes every worktree it
cannot see for deleted."
  (harness-worktree-test-with-repo
    (let ((locked (harness-worktree-test--create root "task/locked"))
          (plain (file-name-as-directory (expand-file-name ".worktrees/plain" root)))
          (hidden (expand-file-name "hidden" base)))
      ;; One made as the harness makes them now, one as it did before.
      (harness-worktree-test--git root "worktree" "add" "-q" "-b" "plain" plain)
      ;; Out of sight, as in the sandbox, then a prune, then back.
      (make-directory hidden)
      (rename-file (directory-file-name locked) (expand-file-name "locked" hidden))
      (rename-file (directory-file-name plain) (expand-file-name "plain" hidden))
      (harness-worktree-test--git root "worktree" "prune")
      (rename-file (expand-file-name "locked" hidden) (directory-file-name locked))
      (rename-file (expand-file-name "plain" hidden) (directory-file-name plain))
      ;; The locked worktree is still registered, and git works in it.
      (should (equal "task/locked\n" (harness-worktree-test--git locked "branch" "--show-current")))
      (should (equal "" (harness-worktree-test--git locked "status" "--porcelain")))
      (should (equal "locked harness: task/locked" (harness-worktree-test--lock-line root locked)))
      ;; The other lost its registration: git fails in it.
      (should-not (harness-worktree-test--find (harness-test-await (harness-call 'worktree/list root)) plain))
      (should-error (harness-worktree-test--git plain "status")))))

(ert-deftest harness-worktree-remove-locked ()
  "git refuses to remove a locked worktree unless forced twice; `worktree/remove' still removes it."
  (harness-worktree-test-with-repo
    (let ((clean (harness-worktree-test--create root "clean"))
          (dirty (harness-worktree-test--create root "dirty"))
          (removed nil))
      (harness-on 'worktree/removed (lambda (_r p) (push p removed)))
      ;; One --force does not override the lock.
      (should-error (harness-worktree-test--git root "worktree" "remove" "--force" clean))
      (should (file-directory-p clean))
      ;; The harness lifts its own lock.
      (should (equal clean (harness-test-await (harness-call 'worktree/remove root clean))))
      (should-not (file-exists-p clean))
      (should (equal (list clean) removed))
      ;; Local changes still need FORCE, and the lock goes back on meanwhile.
      (with-temp-file (expand-file-name "scratch" dirty) (insert "x\n"))
      (let ((err (should-error (harness-test-await (harness-call 'worktree/remove root dirty))
                               :type 'harness-error)))
        (should (string-match-p "modified or untracked" (harness-error-message err))))
      (should (equal "locked harness: dirty" (harness-worktree-test--lock-line root dirty)))
      (harness-test-await (harness-call 'worktree/remove root dirty t))
      (should-not (file-exists-p dirty))
      ;; Someone else's lock is kept, unless forced.
      (let ((foreign (file-name-as-directory (expand-file-name "foreign" base))))
        (harness-worktree-test--git root "worktree" "add" "-q" "--lock" "--reason" "on a usb stick" "-b" "foreign" foreign)
        (let ((err (should-error (harness-test-await (harness-call 'worktree/remove root foreign))
                                 :type 'harness-error)))
          (should (string-match-p "locked" (harness-error-message err))))
        (should (equal "locked on a usb stick" (harness-worktree-test--lock-line root foreign)))
        (harness-test-await (harness-call 'worktree/remove root foreign t))
        (should-not (file-exists-p foreign)))
      ;; A locked worktree whose directory is gone goes too.
      (let ((gone (harness-worktree-test--create root "gone")))
        (delete-directory gone t)
        (harness-test-await (harness-call 'worktree/remove root gone)))
      (should (= 1 (length (harness-test-await (harness-call 'worktree/list root))))))))

(ert-deftest harness-worktree-lock-and-unlock ()
  (harness-worktree-test-with-repo
    (let ((path (file-name-as-directory (expand-file-name "wt-lock" base)))
          (events nil))
      (harness-on 'worktree/locked (lambda (_r p) (push (cons 'locked p) events)))
      (harness-on 'worktree/unlocked (lambda (_r p) (push (cons 'unlocked p) events)))
      (harness-worktree-test--git root "worktree" "add" "-q" "-b" "feature/lock" path)
      (should (harness-test-await (harness-call 'worktree/lock root path)))
      (should (equal "locked harness: feature/lock" (harness-worktree-test--lock-line root path)))
      ;; Locked already: it keeps its lock.
      (should-not (harness-test-await (harness-call 'worktree/lock root path "another reason")))
      (should (equal "locked harness: feature/lock" (harness-worktree-test--lock-line root path)))
      (should (harness-test-await (harness-call 'worktree/unlock root path)))
      (should-not (harness-worktree-test--lock-line root path))
      (should-not (harness-test-await (harness-call 'worktree/unlock root path)))
      ;; Someone else's lock stays, unless ANY.
      (harness-worktree-test--git root "worktree" "lock" "--reason" "mine" path)
      (should-not (harness-test-await (harness-call 'worktree/unlock root path)))
      (should (equal "locked mine" (harness-worktree-test--lock-line root path)))
      (should (harness-test-await (harness-call 'worktree/unlock root path t)))
      (should-not (harness-worktree-test--lock-line root path))
      (should (equal (list (cons 'locked path) (cons 'unlocked path) (cons 'unlocked path))
                     (reverse events)))
      ;; The main checkout cannot be locked.
      (should-error (harness-test-await (harness-call 'worktree/lock root root)) :type 'harness-error))))

(ert-deftest harness-worktree-prune-skips-locked ()
  "`worktree/prune' keeps a locked worktree whose directory is gone and prunes the others."
  (harness-worktree-test-with-repo
    (let ((locked (harness-worktree-test--create root "keep-me"))
          (plain (expand-file-name "wt-plain" base)))
      (harness-worktree-test--git root "worktree" "add" "-q" "-b" "prune-me" plain)
      (delete-directory locked t)
      (delete-directory plain t)
      (let ((listed (harness-test-await (harness-call 'worktree/list root))))
        (should (= 3 (length listed)))
        (should (plist-get (harness-worktree-test--find listed locked) :missing))
        (should-not (plist-get (harness-worktree-test--find listed locked) :prunable))
        (should (plist-get (harness-worktree-test--find listed plain) :prunable)))
      ;; git's line for the one it pruned, then the one it kept.
      (let ((lines (harness-test-await (harness-call 'worktree/prune root))))
        (should (= 2 (length lines)))
        (should (string-match-p "wt-plain" (car lines)))
        (should (string-match-p "\\`Kept .*keep-me: .*locked (harness: keep-me)" (cadr lines))))
      (let ((listed (harness-test-await (harness-call 'worktree/list root))))
        (should (= 2 (length listed)))
        (should (harness-worktree-test--find listed locked)))
      ;; Unlocked, as once its branch is merged, it is pruned like any other.
      (harness-test-await (harness-call 'worktree/unlock root locked))
      (should (= 1 (length (harness-test-await (harness-call 'worktree/prune root)))))
      (should (= 1 (length (harness-test-await (harness-call 'worktree/list root)))))
      (should-not (harness-test-await (harness-call 'worktree/prune root))))))

(ert-deftest harness-worktree-lock-existing ()
  "Worktrees made before the harness locked them get their lock; no others do."
  (harness-worktree-test-with-repo
    (let* ((container (expand-file-name ".worktrees" root))
           (old (file-name-as-directory (expand-file-name "old" container)))
           (merged (file-name-as-directory (expand-file-name "merged" container)))
           (gone (file-name-as-directory (expand-file-name "gone" container)))
           (theirs (file-name-as-directory (expand-file-name "theirs" container)))
           (foreign (file-name-as-directory (expand-file-name "foreign" base)))
           (asked nil))
      (dolist (wt (list (cons old "task/old") (cons merged "task/merged") (cons gone "task/gone")
                        (cons foreign "foreign")))
        (harness-worktree-test--git root "worktree" "add" "-q" "-b" (cdr wt) (car wt)))
      (harness-worktree-test--git root "worktree" "add" "-q" "--lock" "--reason" "theirs" "-b" "theirs" theirs)
      (delete-directory gone t)
      ;; A filter turns one down, as the tasks module does a merged task's.
      (harness-add-filter 'worktree/lock-existing-p
                          (lambda (lock _root wt)
                            (push (plist-get wt :branch) asked)
                            (and lock (not (equal "task/merged" (plist-get wt :branch))))))
      (let ((locked (harness-test-await (harness-call 'worktree/lock-existing root))))
        (should (equal (list (harness-worktree-test--dir old)) (mapcar #'harness-worktree-test--dir locked))))
      (should (equal '("task/merged" "task/old") (sort asked #'string<)))
      (should (equal "locked harness: task/old" (harness-worktree-test--lock-line root old)))
      (should-not (harness-worktree-test--lock-line root merged))
      (should-not (harness-worktree-test--lock-line root gone))
      (should-not (harness-worktree-test--lock-line root foreign))
      (should (equal "locked theirs" (harness-worktree-test--lock-line root theirs)))
      (should-not (harness-worktree-test--lock-line root root))
      ;; Nothing left to lock.
      (should-not (harness-test-await (harness-call 'worktree/lock-existing root))))))

(ert-deftest harness-worktree-lock-known-once-per-repository ()
  "When the harness starts, the repositories its sessions use get their worktrees locked, once."
  (harness-worktree-test-with-repo
    (harness-test-with-temp-state
      (let ((old (file-name-as-directory (expand-file-name ".worktrees/old" root)))
            (outside (harness-test-temp-dir)))
        (harness-worktree-test--git root "worktree" "add" "-q" "-b" "task/old" old)
        (harness-register-method 'session/list
                                 (lambda (&optional _filter)
                                   (list (list :id "a" :cwd old :project old :worktree old)
                                         (list :id "b" :cwd root :project root)
                                         (list :id "c" :cwd outside :project outside))))
        (harness-emit 'harness/started)
        (harness-test-wait (lambda () (harness-worktree--locked-roots)) 10 "the repository noted")
        (should (equal "locked harness: task/old" (harness-worktree-test--lock-line root old)))
        (should (equal (list (harness-worktree-test--dir root))
                       (mapcar #'harness-worktree-test--dir (harness-worktree--locked-roots))))
        ;; Merged and unlocked, it stays so: the next start leaves the repository alone.
        (harness-test-await (harness-call 'worktree/unlock root old))
        (harness-emit 'harness/reloaded)
        (accept-process-output nil 0.3)
        (should-not (harness-worktree-test--lock-line root old))))))

(ert-deftest harness-worktree-parsers ()
  (let ((wts (harness-worktree--parse-list
              (concat "worktree /repo\nHEAD 0123456789abcdef0123456789abcdef01234567\nbranch refs/heads/main\n\n"
                      "worktree /repo-wt/a\nHEAD 89abcdef0123456789abcdef0123456789abcdef\ndetached\nlocked reason\n\n"
                      "worktree /bare.git\nbare\n\n"))))
    (should (equal '(:path "/repo/" :branch "main" :head "0123456789abcdef0123456789abcdef01234567"
                     :bare nil :detached nil :locked nil :main t)
                   (car wts)))
    (should (plist-get (nth 1 wts) :detached))
    (should (plist-get (nth 1 wts) :locked))
    (should (equal "reason" (plist-get (nth 1 wts) :lock-reason)))
    (should-not (harness-worktree-harness-lock-p (nth 1 wts)))
    (should-not (plist-get (nth 1 wts) :branch))
    (should (plist-get (nth 2 wts) :bare)))
  (harness-worktree-test--parse-lock-reasons)
  (should (equal '(:dirty t :ahead 2 :behind 1 :branch "x")
                 (harness-worktree--parse-status
                  "# branch.oid abc\n# branch.head x\n# branch.upstream origin/x\n# branch.ab +2 -1\n1 .M N... 100644 100644 100644 abc abc f.el\n")))
  (should (equal '(:dirty nil :ahead 0 :behind 0 :branch nil)
                 (harness-worktree--parse-status "# branch.oid abc\n# branch.head (detached)\n"))))

(defun harness-worktree-test--parse-lock-reasons ()
  "Check locks without a reason, and reasons git quoted."
  ;; git quotes the UTF-8 bytes of e with acute accent as two octal escapes.
  (let* ((octal (string ?\\ ?3 ?0 ?3 ?\\ ?2 ?5 ?1))
         (wts (harness-worktree--parse-list
               (concat "worktree /repo\nHEAD 0123\nbranch refs/heads/main\n\n"
                       "worktree /repo/a\nHEAD 0123\nlocked\n\n"
                       "worktree /repo/b\nHEAD 0123\nlocked \"harness: task/caf" octal "\"\n\n"))))
    (should (plist-get (nth 1 wts) :locked))
    (should-not (plist-get (nth 1 wts) :lock-reason))
    (should-not (harness-worktree-harness-lock-p (nth 1 wts)))
    (should (equal (concat "harness: task/caf" (string #xe9)) (plist-get (nth 2 wts) :lock-reason)))
    (should (harness-worktree-harness-lock-p (nth 2 wts)))))

(provide 'harness-worktree-test)
;;; harness-worktree-test.el ends here
