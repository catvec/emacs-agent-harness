;;; harness-worktree-test.el --- Tests for git worktrees -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; This file is not part of GNU Emacs.

;;; Commentary:

;; These tests build a real repository in a temporary directory and run real
;; git, because the whole point of the feature is how it behaves with git.
;; They are skipped when git is absent.

;;; Code:

(require 'ert)
(require 'harness-worktree)
(require 'harness-mock-provider)
(require 'harness-test-util)

(defun harness-worktree-test--git-available-p ()
  "Return non-nil when git can be run."
  (and (executable-find "git")
       (zerop (ignore-errors (call-process "git" nil nil nil "--version")))))

(defun harness-worktree-test--git (directory &rest arguments)
  "Run git with ARGUMENTS in DIRECTORY and return its output.

Signing is turned off explicitly: a temporary repository inherits the user's
global `commit.gpgsign', and a test that pops up a pinentry prompt is a test
that hangs forever and a dialog the user did not ask for.  The author and
committer are set for the same reason -- the test must not depend on, or
disturb, the user's git identity."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory directory))
          (process-environment
           (append '("GIT_AUTHOR_NAME=Harness Test"
                     "GIT_AUTHOR_EMAIL=harness-test@example.invalid"
                     "GIT_COMMITTER_NAME=Harness Test"
                     "GIT_COMMITTER_EMAIL=harness-test@example.invalid"
                     ;; Belt and braces: no gpg program, no signing, no prompts.
                     "GIT_CONFIG_COUNT=3"
                     "GIT_CONFIG_KEY_0=commit.gpgsign"
                     "GIT_CONFIG_VALUE_0=false"
                     "GIT_CONFIG_KEY_1=tag.gpgsign"
                     "GIT_CONFIG_VALUE_1=false"
                     "GIT_CONFIG_KEY_2=gpg.program"
                     "GIT_CONFIG_VALUE_2=false")
                   process-environment)))
      (apply #'call-process "git" nil t nil arguments)
      (string-trim (buffer-string)))))

(defmacro harness-worktree-test-with-repo (&rest body)
  "Run BODY in a temporary git repository with a live `session'."
  (declare (indent 0))
  `(harness-test-with-temp-session-dir
     (let* ((repo (expand-file-name "project" harness-test--directory))
            (harness-permission-policy '((:default allow)))
            (harness-providers '((:name mock :kind harness-test :script ((:text "ok")))))
            (harness-models '((:provider mock :id "mock-model")))
            (harness-worktree-directory (expand-file-name "worktrees" harness-test--directory))
            (default-directory (file-name-as-directory repo))
            (session nil))
       (make-directory repo t)
       (harness-worktree-test--git repo "init" "-q" "-b" "main")
       ;; Make sure the temporary repository can never ask for a key, even if
       ;; something later runs git without the helper above.
       (harness-worktree-test--git repo "config" "commit.gpgsign" "false")
       (harness-worktree-test--git repo "config" "tag.gpgsign" "false")
       (harness-worktree-test--git repo "config" "gpg.program" "false")
       (with-temp-file (expand-file-name "README.md" repo)
         (insert "hello\n"))
       (harness-worktree-test--git repo "add" ".")
       (harness-worktree-test--git repo "commit" "-q" "-m" "initial")
       (setq session (harness-session-create (list :name "worktree test"
                                                   :model "mock-model"
                                                   :provider 'mock
                                                   :directory repo)))
       (harness-provider-setup)
       ,@body)))

(defun harness-worktree-test--wait (predicate)
  "Wait for PREDICATE, with a generous timeout because git is slow."
  (harness-test-wait-for predicate 30))

(ert-deftest harness-worktree-test-create ()
  "Creating a worktree moves the session into it."
  (skip-unless (harness-worktree-test--git-available-p))
  (harness-worktree-test-with-repo
    (should (harness-worktree--repository-root session))
    (should (equal (file-name-as-directory (harness-session-cwd session))
                   (file-name-as-directory (expand-file-name
                                            "project" harness-test--directory))))
    (let ((done nil))
      (harness-worktree-create session "harness/test-branch"
                               (lambda (worktree) (setq done worktree)))
      (should (harness-worktree-test--wait (lambda () done)))
      (let ((worktree (harness-worktree-of session)))
        (should worktree)
        (should (equal (plist-get worktree :branch) "harness/test-branch"))
        (should (file-directory-p (plist-get worktree :path)))
        ;; The checkout is real, and the session works there.
        (should (file-exists-p (expand-file-name "README.md" (plist-get worktree :path))))
        (should (equal (file-name-as-directory (harness-session-cwd session))
                       (file-name-as-directory (plist-get worktree :path))))
        (should (harness-worktree-p (plist-get worktree :path)))
        ;; git agrees the branch exists.
        (should (string-match-p "harness/test-branch"
                                (harness-worktree-test--git
                                 (plist-get worktree :path) "rev-parse" "--abbrev-ref" "HEAD")))))))

(ert-deftest harness-worktree-test-tools-use-it ()
  "Tools run in the worktree once the session has moved."
  (skip-unless (harness-worktree-test--git-available-p))
  (harness-worktree-test-with-repo
    (let ((done nil))
      (harness-worktree-create session nil (lambda (worktree) (setq done worktree)))
      (should (harness-worktree-test--wait (lambda () done))))
    ;; A tool that reports its directory: the session's cwd is the worktree.
    (let* ((call (harness-tool-call-create
                  :name "bash" :args-string (harness-json-write '(:command "pwd"))))
           (finished nil))
      (harness-tool-run call session (lambda (result) (setq finished result)))
      (should (harness-worktree-test--wait (lambda () finished)))
      (should (string-match-p (regexp-quote (directory-file-name
                                             (harness-session-cwd session)))
                              (harness-tool-call-result finished))))))

(ert-deftest harness-worktree-test-list ()
  "Listing worktrees reports the new one."
  (skip-unless (harness-worktree-test--git-available-p))
  (harness-worktree-test-with-repo
    (let ((done nil))
      (harness-worktree-create session nil (lambda (worktree) (setq done worktree)))
      (should (harness-worktree-test--wait (lambda () done))))
    (let ((worktrees (harness-worktree-list session)))
      (should (>= (length worktrees) 2))
      (should (seq-some (lambda (worktree)
                          (string-match-p "worktrees"
                                          (plist-get worktree :path)))
                        worktrees)))))

(ert-deftest harness-worktree-test-refuses-to-discard-work ()
  "Removal fails while the worktree has uncommitted changes."
  (skip-unless (harness-worktree-test--git-available-p))
  (harness-worktree-test-with-repo
    (let ((done nil))
      (harness-worktree-create session nil (lambda (worktree) (setq done worktree)))
      (should (harness-worktree-test--wait (lambda () done))))
    (let* ((path (plist-get (harness-worktree-of session) :path))
           (called nil)
           (removed nil))
      (with-temp-file (expand-file-name "dirty.txt" path)
        (insert "uncommitted"))
      (harness-worktree-remove session nil t
                               (lambda (success) (setq called t removed success)))
      ;; Wait for the callback, not for success: the point is that git refuses.
      (should (harness-worktree-test--wait (lambda () called)))
      (should-not removed)
      (should (file-directory-p path))
      ;; With force it goes.
      (let ((forced nil)
            (force-called nil))
        (harness-worktree-remove session t t
                                 (lambda (success) (setq force-called t forced success)))
        (should (harness-worktree-test--wait (lambda () force-called)))
        (should forced)
        (should-not (file-directory-p path))))))

(ert-deftest harness-worktree-test-remove-restores-directory ()
  "Removing a worktree returns the session to its project."
  (skip-unless (harness-worktree-test--git-available-p))
  (harness-worktree-test-with-repo
    (let ((done nil))
      (harness-worktree-create session nil (lambda (worktree) (setq done worktree)))
      (should (harness-worktree-test--wait (lambda () done))))
    (let ((path (plist-get (harness-worktree-of session) :path))
          (removed nil)
          (harness-worktree-delete-branch t))
      (harness-worktree-remove session nil t (lambda (success) (setq removed success)))
      (should (harness-worktree-test--wait (lambda () removed)))
      (should removed)
      (should-not (file-directory-p path))
      (should-not (harness-worktree-of session))
      (should (equal (file-name-as-directory (harness-session-cwd session))
                     (file-name-as-directory (harness-session-project-root session)))))))

(ert-deftest harness-worktree-test-tool ()
  "The worktree tool creates and lists."
  (skip-unless (harness-worktree-test--git-available-p))
  (harness-worktree-test-with-repo
    (let ((created nil))
      (harness-tool-run
       (harness-tool-call-create
        :name "worktree"
        :args-string (harness-json-write '(:action "create" :branch "harness/tool-branch")))
       session
       (lambda (call) (setq created call)))
      (should (harness-worktree-test--wait (lambda () created)))
      (should (eq (harness-tool-call-status created) 'ok))
      (should (string-match-p "harness/tool-branch" (harness-tool-call-result created))))
    (let ((listed nil))
      (harness-tool-run
       (harness-tool-call-create :name "worktree"
                                 :args-string (harness-json-write '(:action "list")))
       session
       (lambda (call) (setq listed call)))
      (should (harness-worktree-test--wait (lambda () listed)))
      (should (eq (harness-tool-call-status listed) 'ok))
      (should (string-match-p "worktrees" (harness-tool-call-result listed))))))

(ert-deftest harness-worktree-test-outside-a-repository ()
  "Creating a worktree outside a repository reports the problem."
  (harness-test-with-temp-session-dir
    (let* ((harness-permission-policy '((:default allow)))
           (harness-providers '((:name mock :kind harness-test :script ((:text "ok")))))
           (harness-models '((:provider mock :id "mock-model")))
           (default-directory (file-name-as-directory harness-test--directory))
           (session (harness-session-create '(:name "plain" :model "mock-model"
                                                      :provider mock))))
      (should-not (harness-worktree--repository-root session))
      (should-not (harness-worktree-create session nil nil))
      (should-not (harness-worktree-of session)))))

(provide 'harness-worktree-test)
;;; harness-worktree-test.el ends here
