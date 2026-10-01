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
      (should (= 0 (hash-table-count harness-project--listings))))))

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

(provide 'harness-project-test)
;;; harness-project-test.el ends here
