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

;;;; Scratch directories

(defvar harness-sessions)

(defmacro harness-project-test-with-sessions (&rest body)
  "Run BODY with the project and session modules loaded into a fresh bus.
`base' names a directory of its own, in which a session's temporary
directory is made as harness-1000/ID, as /tmp/harness-1000/ID is."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session)) (harness-test-load-module m))
     (clrhash harness-sessions)
     (let ((base (harness-test-temp-dir)))
       (unwind-protect (progn ,@body)
         (ignore-errors (delete-directory base t))))))

(defun harness-project-test--id (n)
  "Return the Nth session id, a UUID as the harness makes them."
  (format "6f2c1a90-%04d-4000-8000-%012d" n n))

(defun harness-project-test--scratch (base n &optional leaf)
  "Return the directory LEAF in the temporary directory of session N, in BASE."
  (file-name-as-directory
   (expand-file-name (concat "harness-1000/" (harness-project-test--id n) "/" (or leaf "")) base)))

(defun harness-project-test--session (n project &rest plist)
  "Create session N working in PROJECT, PLIST added; return its id."
  (plist-get (apply #'harness-call 'session/create :id (harness-project-test--id n)
                    :cwd project :project project plist)
             :id))

(ert-deftest harness-project-main-counts-a-scratch-directory-for-its-sessions-project ()
  "A sub-agent's working directory in its parent's temporary directory is no
project: its work counts for the project of the session whose directory it
is, gone from disk or not, and for none once that session is gone."
  (skip-unless (executable-find "git"))
  (harness-project-test-with-sessions
    (let* ((root (harness-project-test--committed-repo base))
           (elsewhere (harness-test-temp-dir))
           (gone (harness-project-test--scratch base 1 "q13b-1"))
           (made (harness-project-test--scratch base 1 "proto3"))
           (repo (harness-project-test--scratch base 1 "scratch-repo")))
      (harness-project-test--session 1 root)
      (make-directory made t)
      (make-directory repo t)
      (harness-project-test--git repo "init" "-q" "-b" "main")
      (dolist (dir (list gone made repo (harness-project-test--scratch base 1)))
        (should (harness-project-test--same-dir root (harness-project-main dir))))
      ;; A session that works in its own temporary directory is its own.
      (harness-project-test--session 2 (harness-project-test--scratch base 2 "x"))
      (should-not (harness-project-main (harness-project-test--scratch base 2 "x")))
      ;; Scratch directories of scratch directories end at the first project.
      (harness-project-test--session 3 made)
      (harness-project-test--session 4 (harness-project-test--scratch base 3 "deep"))
      (should (harness-project-test--same-dir
               root (harness-project-main (harness-project-test--scratch base 4 "deeper"))))
      ;; Sessions that point at each other's directories end the search.
      (harness-project-test--session 5 (harness-project-test--scratch base 6 "a"))
      (harness-project-test--session 6 (harness-project-test--scratch base 5 "b"))
      (should-not (harness-project-main (harness-project-test--scratch base 5 "c")))
      ;; No session of that name: no project.
      (should-not (harness-project-main (harness-project-test--scratch base 7 "x")))
      ;; What is not in a temporary directory is its own checkout, as ever,
      ;; though its name is like one's.
      (let ((named (file-name-as-directory (expand-file-name "harness-1000/notes" base))))
        (make-directory named t)
        (should (equal named (harness-project-main named))))
      (should (equal elsewhere (harness-project-main elsewhere)))
      (should (harness-project-test--same-dir root (harness-project-main root))))))

(ert-deftest harness-project-main-of-a-scratch-worktree-is-the-checkout-it-is-of ()
  "A worktree made in a scratch directory is of the checkout it was made from,
whatever project the session whose directory it is works for."
  (skip-unless (executable-find "git"))
  (harness-project-test-with-sessions
    (let* ((root (harness-project-test--committed-repo base))
           (other (harness-test-temp-dir))
           (worktree (harness-project-test--scratch base 8 "wt/core")))
      (harness-project-test--session 8 other)
      (harness-project-test--git root "worktree" "add" "-q" "-b" "core" worktree)
      (should (harness-project-test--same-dir root (harness-project-main worktree)))
      ;; Gone, it is only a scratch directory of that session.
      (harness-project-test--git root "worktree" "remove" worktree)
      (should-not (file-exists-p worktree))
      (should (equal other (harness-project-main worktree))))))

(ert-deftest harness-project-mains-answers-for-scratch-directories ()
  "`project/mains' names the project a scratch directory's work counts for,
and says \"\" for none."
  (harness-project-test-with-sessions
    (let* ((project (harness-test-temp-dir))
           (scratch (harness-project-test--scratch base 9 "q13b-2"))
           (orphan (harness-project-test--scratch base 10 "q13b-3")))
      (harness-project-test--session 9 project)
      (should (equal (list (list :root scratch :main project)
                           (list :root orphan :main "")
                           (list :root project :main project))
                     (harness-call 'project/mains (list scratch orphan project)))))))

(ert-deftest harness-project-main-of-a-scratch-directory-needs-the-sessions ()
  "Without the session module a scratch directory counts for no project."
  (harness-project-test-with-module
    (let ((scratch (format "/tmp/harness-1000/%s/x/" (harness-project-test--id 11))))
      (should-not (harness-method-exists-p 'session/exists-p))
      (should-not (harness-project-main scratch))
      (should (equal (list (list :root scratch :main ""))
                     (harness-call 'project/mains (list scratch)))))))

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
