;;; harness-worktree-test.el --- Tests for git worktrees -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-session)
(require 'harness-worktree)
(require 'harness-test-helpers)

(harness-module-load 'harness-session)
(harness-module-load 'harness-worktree)

(defun harness-worktree-test--git (directory &rest args)
  "Run git ARGS in DIRECTORY for test setup."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory (expand-file-name directory)))
          (process-environment (cons "GIT_TERMINAL_PROMPT=0"
                                     (cons "GIT_CONFIG_NOSYSTEM=1" process-environment))))
      (apply #'process-file "git" nil (current-buffer) nil args)
      (string-trim (buffer-string)))))

(defun harness-worktree-test--repo ()
  "Create a temporary git repository with one commit."
  (unless (executable-find "git")
    (ert-skip "git is not installed"))
  (let ((repo (make-temp-file "harness-worktree-repo-" t)))
    (harness-worktree-test--git repo "init" "-q" "-b" "main")
    (harness-worktree-test--git repo "config" "user.email" "test@example.com")
    (harness-worktree-test--git repo "config" "user.name" "Harness Test")
    (harness-worktree-test--git repo "config" "commit.gpgsign" "false")
    (with-temp-file (expand-file-name "README.md" repo)
      (insert "# test\n"))
    (harness-worktree-test--git repo "add" "README.md")
    (harness-worktree-test--git repo "-c" "commit.gpgsign=false" "commit" "-q" "-m" "init")
    repo))

(ert-deftest harness-worktree-lists-the-main-worktree ()
  (let* ((repo (harness-worktree-test--repo))
         (worktrees (harness-worktree-list repo)))
    (should (= (length worktrees) 1))
    (should (plist-get (car worktrees) :main))
    (should (equal (file-name-as-directory (file-truename (plist-get (car worktrees) :path)))
                   (file-name-as-directory (file-truename repo))))
    (should (equal (plist-get (car worktrees) :branch) "main"))))

(ert-deftest harness-worktree-creates-and-removes ()
  (let* ((repo (harness-worktree-test--repo))
         (root (make-temp-file "harness-worktrees-" t))
         (harness-worktree-root root)
         (created (harness-worktree-create :repo repo :name "fix login" :base "main")))
    (should (file-directory-p (plist-get created :path)))
    (should (file-exists-p (expand-file-name "README.md" (plist-get created :path))))
    (should (equal (plist-get created :branch) "harness/fix-login"))
    ;; It shows up in the listing next to the main worktree.
    (let ((worktrees (harness-worktree-list repo)))
      (should (= (length worktrees) 2))
      (should (cl-some (lambda (worktree)
                         (equal (plist-get worktree :branch) "harness/fix-login"))
                       worktrees)))
    ;; Removing works and prunes the listing.
    (harness-worktree-remove (plist-get created :path))
    (should-not (file-directory-p (plist-get created :path)))
    (should (= (length (harness-worktree-list repo)) 1))))

(ert-deftest harness-worktree-create-reuses-an-existing-branch ()
  (let* ((repo (harness-worktree-test--repo))
         (root (make-temp-file "harness-worktrees-" t))
         (harness-worktree-root root))
    (harness-worktree-test--git repo "branch" "harness/existing")
    (let ((created (harness-worktree-create :repo repo :name "harness/existing")))
      (should (equal (plist-get created :branch) "harness/existing"))
      (should (file-directory-p (plist-get created :path))))))

(ert-deftest harness-worktree-refuses-an-existing-path ()
  (let* ((repo (harness-worktree-test--repo))
         (root (make-temp-file "harness-worktrees-" t))
         (harness-worktree-root root)
         (taken (make-temp-file "harness-worktrees-taken-" t)))
    (should-error (harness-worktree-create :repo repo :name "x" :path taken)
                  :type 'harness-user-error)))

(ert-deftest harness-worktree-session-uses-the-worktree ()
  (let* ((repo (harness-worktree-test--repo))
         (root (make-temp-file "harness-worktrees-" t))
         (harness-worktree-root root)
         (harness-session-storage-directory (make-temp-file "harness-wt-sessions-" t)))
    (clrhash harness-session--active)
    (clrhash harness-session--project-ids)
    (let* ((result (harness-worktree-session :repo repo :name "parallel" :title "Parallel work"))
           (worktree (car result))
           (session (cdr result)))
      (should (equal (harness-session-cwd session) (plist-get worktree :path)))
      (should (equal (plist-get (harness-session-worktree session) :branch)
                     "harness/parallel"))
      (should (equal (harness-session-title session) "Parallel work"))
      ;; The worktree survives a metadata round trip.
      (harness-session-save session)
      (let ((reloaded (harness-session-load (harness-session-id session))))
        (should (equal (plist-get (harness-session-worktree reloaded) :branch)
                       "harness/parallel"))))))

(provide 'harness-worktree-test)
;;; harness-worktree-test.el ends here
