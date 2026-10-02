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

(ert-deftest harness-files-pruned-worktree-keeps-its-repository ()
  "A worktree whose record git pruned still belongs to its main checkout.
`git worktree prune' run where the worktree is out of sight -- a
sandbox showing only another worktree, say -- deletes its gitdir while
the worktree and its .git file live on."
  (harness-worktree-test-with-repo
    (let* ((path (file-name-as-directory (expand-file-name "wt-pruned" base)))
           (aside (expand-file-name "wt-aside" base))
           (git (harness-worktree-test--dir (expand-file-name ".git" root))))
      (harness-worktree-test--git root "worktree" "add" "-q" "-b" "pruned" path)
      (make-directory (expand-file-name "sub" path) t)
      ;; Out of sight while git prunes, then back.
      (rename-file (directory-file-name path) aside)
      (harness-worktree-test--git root "worktree" "prune")
      (rename-file aside (directory-file-name path))
      (should-not (file-exists-p (expand-file-name "worktrees/wt-pruned" git)))
      (should (file-regular-p (expand-file-name ".git" path)))
      (should (equal (harness-worktree-test--dir root)
                     (harness-worktree-test--dir (harness-files-main-checkout path))))
      (should (equal (harness-worktree-test--dir root)
                     (harness-worktree-test--dir (harness-files-main-root (expand-file-name "sub" path)))))
      (should (equal git (harness-worktree-test--dir (harness-files-git-common-dir path))))
      ;; Only a gitdir under worktrees/ is taken for a pruned worktree's,
      ;; and only while its repository is there.
      (let ((module (file-name-as-directory (expand-file-name "not-a-worktree" base)))
            (moved (file-name-as-directory (expand-file-name "moved" base))))
        (make-directory module)
        (with-temp-file (expand-file-name ".git" module)
          (insert "gitdir: " (expand-file-name ".git/modules/gone" root) "\n"))
        (should (equal module (harness-files-main-checkout module)))
        (make-directory moved)
        (with-temp-file (expand-file-name ".git" moved)
          (insert "gitdir: " (expand-file-name "gone/.git/worktrees/moved" base) "\n"))
        (should (equal moved (harness-files-main-checkout moved)))
        (should-not (harness-files-git-common-dir moved))))))

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

(ert-deftest harness-worktree-root-of-and-prune ()
  (harness-worktree-test-with-repo
    (let* ((path (expand-file-name "wt-prune" base))
           (wt (harness-test-await (harness-call 'worktree/create root :branch "prune-me" :path path))))
      (ignore wt)
      (make-directory (expand-file-name "sub/dir" path) t)
      (should (equal (harness-worktree-test--dir root)
                     (harness-test-await (harness-call 'worktree/root-of (expand-file-name "sub/dir" path)))))
      (should (equal (harness-worktree-test--dir root)
                     (harness-test-await (harness-call 'worktree/root-of (expand-file-name "README" path)))))
      (should (equal (harness-worktree-test--dir root) (harness-test-await (harness-call 'worktree/root-of root))))
      ;; Delete the directory behind git's back; prune drops the record.
      (delete-directory path t)
      (should (= 2 (length (harness-test-await (harness-call 'worktree/list root)))))
      (let ((pruned (harness-test-await (harness-call 'worktree/prune root))))
        (should (= 1 (length pruned)))
        (should (string-match-p "wt-prune" (car pruned))))
      (should (= 1 (length (harness-test-await (harness-call 'worktree/list root)))))
      (should-not (harness-test-await (harness-call 'worktree/prune root))))))

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
    (should-not (plist-get (nth 1 wts) :branch))
    (should (plist-get (nth 2 wts) :bare)))
  (should (equal '(:dirty t :ahead 2 :behind 1 :branch "x")
                 (harness-worktree--parse-status
                  "# branch.oid abc\n# branch.head x\n# branch.upstream origin/x\n# branch.ab +2 -1\n1 .M N... 100644 100644 100644 abc abc f.el\n")))
  (should (equal '(:dirty nil :ahead 0 :behind 0 :branch nil)
                 (harness-worktree--parse-status "# branch.oid abc\n# branch.head (detached)\n"))))

(provide 'harness-worktree-test)
;;; harness-worktree-test.el ends here
