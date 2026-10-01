;;; harness-ui-sessions-test.el --- Tests for the session list  -*- lexical-binding: t; -*-

;;; Commentary:

;; The session list's project scope.  A task's session runs in a linked
;; git worktree under ROOT/.worktrees/ and has that worktree as its
;; `:project'; the list shows it with ROOT, the main checkout, resolved
;; once per root without running git.  Sessions go straight into the UI
;; cache; no harness or connection is needed.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)
(require 'harness-ui-sessions)

(defvar harness-ui--sessions)

(defun harness-ui-sessions-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string))))))

(defmacro harness-ui-sessions-test-with-repo (&rest body)
  "Run BODY with a git repository at `root', a linked worktree of it at
`wt' (under ROOT/.worktrees/, where tasks work), an unrelated directory
`other' and an empty session cache.  The list never asks the harness."
  (declare (indent 0))
  `(let* ((base (file-name-as-directory (file-truename (harness-test-temp-dir))))
          (root (file-name-as-directory (expand-file-name "repo" base)))
          (wt (file-name-as-directory (expand-file-name ".worktrees/task-x" root)))
          (other (file-name-as-directory (expand-file-name "other" base))))
     (unwind-protect
         (progn
           (make-directory root t)
           (make-directory other t)
           (harness-ui-sessions-test--git root "init" "-q" "-b" "main")
           (harness-ui-sessions-test--git root "config" "user.name" "Harness Test")
           (harness-ui-sessions-test--git root "config" "user.email" "test@example.invalid")
           (harness-ui-sessions-test--git root "config" "commit.gpgsign" "false")
           (harness-ui-sessions-test--git root "commit" "-q" "--allow-empty" "-m" "initial")
           (harness-ui-sessions-test--git root "worktree" "add" "-q" "-b" "task/x" wt)
           (clrhash harness-ui--sessions)
           (cl-letf (((symbol-function 'harness-ui-refresh-sessions)
                      (lambda (&optional callback) (when callback (funcall callback nil))))
                     ((symbol-function 'harness-ui-display-view) #'ignore))
             ,@body))
       (clrhash harness-ui--sessions)
       (when-let* ((buf (get-buffer harness-ui-sessions-buffer-name))) (kill-buffer buf))
       (ignore-errors (delete-directory base t)))))

(defun harness-ui-sessions-test--add (id project)
  "Cache a session ID whose project root is PROJECT, as the wire has it."
  (puthash id (list :id id :name id :project project :cwd project :status "idle" :kind "main"
                    :model "demo:scripted" :permission-mode "auto" :usage (list :cost 0 :context 0)
                    :context-window 200000 :created (float-time) :updated (float-time))
           harness-ui--sessions))

(defun harness-ui-sessions-test--shown ()
  "Return the sorted ids the list buffer shows."
  (with-current-buffer harness-ui-sessions-buffer-name
    (sort (mapcar #'car tabulated-list-entries) #'string<)))

(ert-deftest harness-ui-sessions-project-includes-its-worktrees ()
  "A task's session in a worktree is listed with its project, not another's."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (harness-ui-sessions-test--add "task" wt)
    (harness-ui-sessions-test--add "elsewhere" other)
    (let ((default-directory root)) (harness-sessions))
    (should (equal '("main" "task") (harness-ui-sessions-test--shown)))
    ;; `a' toggles every project, and back.
    (with-current-buffer harness-ui-sessions-buffer-name
      (harness-ui-sessions-toggle-scope)
      (should (equal '("elsewhere" "main" "task") (harness-ui-sessions-test--shown)))
      (harness-ui-sessions-toggle-scope)
      (should (equal '("main" "task") (harness-ui-sessions-test--shown))))
    ;; The other project's list has only its own session.
    (let ((default-directory other)) (harness-sessions))
    (should (equal '("elsewhere") (harness-ui-sessions-test--shown)))
    ;; A task created while the list is open shows on the next redraw.
    (let ((default-directory root)) (harness-sessions))
    (let ((wt2 (file-name-as-directory (expand-file-name ".worktrees/task-y" root))))
      (harness-ui-sessions-test--git root "worktree" "add" "-q" "-b" "task/y" wt2)
      (harness-ui-sessions-test--add "task-2" wt2))
    (harness-ui-sessions--redraw)
    (should (equal '("main" "task" "task-2") (harness-ui-sessions-test--shown)))))

(ert-deftest harness-ui-sessions-from-a-worktree-shows-the-whole-project ()
  "Opened from a task's worktree, the list is scoped to the main checkout."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (harness-ui-sessions-test--add "task" wt)
    (harness-ui-sessions-test--add "elsewhere" other)
    (let ((default-directory (expand-file-name "sub/" wt)))
      (make-directory default-directory t)
      (harness-sessions))
    (should (equal root (buffer-local-value 'harness-ui-sessions--project
                                            (get-buffer harness-ui-sessions-buffer-name))))
    (should (equal '("main" "task") (harness-ui-sessions-test--shown)))))

(ert-deftest harness-ui-sessions-removed-worktree-stays-with-its-project ()
  "An archived task's worktree is gone from disk; its session still lists."
  (harness-ui-sessions-test-with-repo
    (let ((gone (file-name-as-directory (expand-file-name ".worktrees/task-gone" root))))
      (harness-ui-sessions-test--git root "worktree" "add" "-q" "-b" "task/gone" gone)
      (harness-ui-sessions-test--git root "worktree" "remove" gone)
      (should-not (file-exists-p gone))
      (harness-ui-sessions-test--add "main" root)
      (harness-ui-sessions-test--add "archived" gone)
      (let ((default-directory root)) (harness-sessions))
      (should (equal '("archived" "main") (harness-ui-sessions-test--shown))))))

(ert-deftest harness-ui-sessions-remote-roots-are-not-looked-at ()
  "A remote session's root is compared as it is, with no file access."
  (harness-ui-sessions-test-with-repo
    (let ((remote "/ssh:nobody@example.invalid:/srv/project/"))
      (harness-ui-sessions-test--add "main" root)
      (harness-ui-sessions-test--add "remote" remote)
      (let ((default-directory root)) (harness-sessions))
      (should (equal '("main") (harness-ui-sessions-test--shown)))
      (with-current-buffer harness-ui-sessions-buffer-name
        (cl-letf (((symbol-function 'harness-files-main-checkout) (lambda (&rest _) (error "Looked at")))
                  ((symbol-function 'harness-files-main-root) (lambda (&rest _) (error "Looked at")))
                  ((symbol-function 'file-directory-p) (lambda (&rest _) (error "Looked at"))))
          (setq harness-ui-sessions--main-roots nil)
          (should (equal remote (harness-ui-sessions--main-root remote))))
        (harness-ui-sessions-toggle-scope)
        (should (equal '("main" "remote") (harness-ui-sessions-test--shown)))))))

(ert-deftest harness-ui-sessions-resolve-each-root-once ()
  "Redraws reuse resolved roots; `g' resolves them again."
  (harness-ui-sessions-test-with-repo
    (harness-ui-sessions-test--add "main" root)
    (harness-ui-sessions-test--add "task" wt)
    (harness-ui-sessions-test--add "task-again" wt)
    (harness-ui-sessions-test--add "elsewhere" other)
    (let* ((calls 0)
           (resolve (symbol-function 'harness-files-main-checkout)))
      (cl-letf (((symbol-function 'harness-files-main-checkout)
                 (lambda (r) (cl-incf calls) (funcall resolve r))))
        (let ((default-directory root)) (harness-sessions))
        (should (equal '("main" "task" "task-again") (harness-ui-sessions-test--shown)))
        ;; One for the scope, one for each distinct session root.
        (should (= 4 calls))
        (dotimes (_ 3) (harness-ui-sessions--redraw))
        (should (= 4 calls))
        (with-current-buffer harness-ui-sessions-buffer-name (harness-ui-sessions-reload))
        (should (= 7 calls))
        (should (equal '("main" "task" "task-again") (harness-ui-sessions-test--shown)))))))

(provide 'harness-ui-sessions-test)
;;; harness-ui-sessions-test.el ends here
