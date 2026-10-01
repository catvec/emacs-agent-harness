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
                                       (expand-file-name "repo-worktrees" base))))
      (should (string-prefix-p "harness/" branch))
      (should (equal (harness-worktree-test--dir expected) (harness-worktree-test--dir (plist-get wt :path))))
      (should (file-directory-p expected)))
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
