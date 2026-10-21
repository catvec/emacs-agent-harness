;;; harness-project-test.el --- Tests for project detection and file listing  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defun harness-project-test--touch (root &rest paths)
  "Create each of PATHS (relative) under ROOT."
  (dolist (p paths)
    (let ((f (expand-file-name p root)))
      (make-directory (file-name-directory f) t)
      (with-temp-file f))))

(defun harness-project-test--repo ()
  "Return a fresh git repository with a staged, an ignored and an untracked file."
  (let ((root (harness-test-temp-dir)))
    (let ((default-directory root))
      (call-process "git" nil nil nil "init" "-q")
      (harness-project-test--touch root "src/a.el" ".gitignore" "build/out.elc")
      (with-temp-file (expand-file-name ".gitignore" root) (insert "build/\n"))
      (call-process "git" nil nil nil "add" ".")
      (harness-project-test--touch root "new.el"))
    root))

(defmacro harness-project-test-with-module (&rest body)
  (declare (indent 0))
  `(progn (harness-test-reset-bus) (harness-test-load-module 'project) ,@body))

(ert-deftest harness-project-files-is-a-promise-of-git-files ()
  (skip-unless (executable-find "git"))
  (harness-project-test-with-module
    (let* ((root (harness-project-test--repo))
           (p (harness-call 'project/files root)))
      (should (harness-promise-p p))
      (should (equal (sort (harness-test-await p) #'string<)
                     '(".gitignore" "new.el" "src/a.el"))))))

(ert-deftest harness-project-files-sees-files-created-later ()
  (skip-unless (executable-find "git"))
  (harness-project-test-with-module
    (let ((root (harness-project-test--repo)))
      (harness-test-await (harness-call 'project/files root))
      (harness-project-test--touch root "later.el")
      (should (member "later.el" (harness-test-await (harness-call 'project/files root)))))))

(ert-deftest harness-project-files-lists-nothing-outside-a-project ()
  (harness-project-test-with-module
    (let ((root (harness-test-temp-dir)))
      (harness-project-test--touch root "a" "d/b")
      (should (null (harness-test-await (harness-call 'project/files root)))))))

(ert-deftest harness-project-files-shares-one-listing ()
  (skip-unless (executable-find "git"))
  (harness-project-test-with-module
    (let* ((root (harness-project-test--repo))
           (a (harness-call 'project/files root))
           (b (harness-call 'project/files root nil 1)))
      (should (= 3 (length (harness-test-await a))))
      (should (= 1 (length (harness-test-await b))))
      (should (= 0 (hash-table-count harness-files--listings))))))

(ert-deftest harness-project-files-query-filters ()
  (skip-unless (executable-find "git"))
  (harness-project-test-with-module
    (let ((root (harness-project-test--repo)))
      (should (equal (harness-test-await (harness-call 'project/files root "a.el"))
                     '("src/a.el"))))))

(defvar projectile-enable-caching)
(defvar projectile-projects-cache)
(defvar projectile-projects-cache-time)
(defvar projectile-known-projects-file)
(declare-function projectile-project-files "projectile")
(declare-function projectile-invalidate-cache "projectile")

(ert-deftest harness-project-files-fills-projectile-cache ()
  "A miss is listed asynchronously into projectile's cache, a hit reads it,
and `projectile-invalidate-cache' makes the next request list again."
  (skip-unless (and (executable-find "git") (locate-library "projectile")))
  (require 'projectile)
  (harness-project-test-with-module
    (let* ((root (harness-project-test--repo))
           (projectile-enable-caching t)
           (projectile-projects-cache (make-hash-table :test 'equal))
           (projectile-projects-cache-time (make-hash-table :test 'equal))
           (projectile-known-projects-file (make-temp-file "projectile-known")))
      (should (equal (sort (copy-sequence (harness-test-await (harness-call 'project/files root))) #'string<)
                     '(".gitignore" "new.el" "src/a.el")))
      (should (gethash root projectile-projects-cache))
      (harness-project-test--touch root "later.el")
      ;; A cache hit: the new file is unknown until projectile is told.
      (should-not (member "later.el" (harness-test-await (harness-call 'project/files root))))
      (let ((default-directory root)) (projectile-invalidate-cache nil))
      (should (member "later.el" (harness-test-await (harness-call 'project/files root))))
      (should (member "later.el" (projectile-project-files root))))))

;;;; project/mains

(defun harness-project-test--git (dir &rest args)
  "Run git ARGS in DIR; signal when it fails."
  (let ((default-directory (file-name-as-directory dir)))
    (unless (zerop (apply #'call-process "git" nil nil nil args))
      (error "git %s failed" args))))

(defun harness-project-test--committed-repo (base)
  "Return a git repository with a commit at BASE/repo/, a directory name."
  (let ((root (file-name-as-directory (expand-file-name "repo" base))))
    (make-directory root t)
    (harness-project-test--git root "init" "-q" "-b" "main")
    (harness-project-test--git root "config" "user.name" "Harness Test")
    (harness-project-test--git root "config" "user.email" "test@example.invalid")
    (harness-project-test--git root "config" "commit.gpgsign" "false")
    (harness-project-test--touch root "README")
    (harness-project-test--git root "add" "README")
    (harness-project-test--git root "commit" "-q" "-m" "initial")
    root))

(defun harness-project-test--same-dir (a b)
  "Non-nil when A and B name the same directory."
  (equal (file-name-as-directory (file-truename a))
         (file-name-as-directory (file-truename b))))

(ert-deftest harness-project-mains-names-the-checkout-of-a-worktree ()
  "A linked worktree, wherever it is, is of the checkout it was made from."
  (skip-unless (executable-find "git"))
  (harness-project-test-with-module
    (let* ((base (harness-test-temp-dir))
           (root (harness-project-test--committed-repo base))
           (inside (file-name-as-directory (expand-file-name ".worktrees/task-a" root)))
           (beside (file-name-as-directory (expand-file-name "repo-worktrees/task-b" base)))
           (gone (file-name-as-directory (expand-file-name ".worktrees/task-gone" root)))
           (plain (harness-test-temp-dir)))
      (unwind-protect
          (progn
            (harness-project-test--git root "worktree" "add" "-q" "-b" "task/a" inside)
            (harness-project-test--git root "worktree" "add" "-q" "-b" "task/b" beside)
            (harness-project-test--git root "worktree" "add" "-q" "-b" "task/gone" gone)
            (harness-project-test--git root "worktree" "remove" gone)
            (should-not (file-exists-p gone))
            (let* ((asked (list root inside beside gone plain))
                   (answer (harness-call 'project/mains asked)))
              ;; One entry for each, in order, the directory as it was given.
              (should (equal asked (mapcar (lambda (entry) (plist-get entry :root)) answer)))
              (dolist (entry (list (nth 0 answer) (nth 1 answer) (nth 2 answer) (nth 3 answer)))
                (should (harness-project-test--same-dir root (plist-get entry :main))))
              ;; Not a worktree, not a project of a repository: its own.
              (should (equal plain (plist-get (nth 4 answer) :main)))))
        (ignore-errors (delete-directory base t))))))

(ert-deftest harness-project-mains-leaves-out-what-is-not-a-directory-name ()
  (harness-project-test-with-module
    (let ((dir (harness-test-temp-dir)))
      (should (equal (list dir)
                     (mapcar (lambda (entry) (plist-get entry :root))
                             (harness-call 'project/mains
                                           (list "" "relative/dir" "~/elsewhere/" 42 nil dir)))))
      (should (null (harness-call 'project/mains nil)))
      (should (null (harness-call 'project/mains '("not/absolute"))))
      ;; A vector, as a client's JSON array may arrive, and a lone name.
      (should (equal (list dir)
                     (mapcar (lambda (entry) (plist-get entry :root))
                             (harness-call 'project/mains (vector dir)))))
      (should (equal (list dir)
                     (mapcar (lambda (entry) (plist-get entry :root))
                             (harness-call 'project/mains dir)))))))

(ert-deftest harness-project-mains-does-not-look-at-a-remote-root ()
  "A remote root is its own checkout, and nothing connects to find out."
  (harness-project-test-with-module
    (let ((remote "/ssh:nobody@example.invalid:/srv/app/"))
      (should (file-remote-p remote)) ; loads TRAMP before file access is watched
      (cl-letf (((symbol-function 'file-directory-p) (lambda (&rest _) (error "Looked at")))
                ((symbol-function 'harness-files-main-root) (lambda (&rest _) (error "Looked at"))))
        (should (equal (list (list :root remote :main remote))
                       (harness-call 'project/mains (list remote))))))))

(provide 'harness-project-test)
;;; harness-project-test.el ends here
