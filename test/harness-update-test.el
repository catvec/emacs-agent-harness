;;; harness-update-test.el --- Tests for harness-update  -*- lexical-binding: t; -*-

;;; Commentary:

;; The harness updates the git checkout it runs from: a clone of its
;; own, or the one straight.el keeps behind a build of symbolic links.
;; These tests make an upstream repository and a clone of it, move the
;; upstream on, and update the clone as `harness-update' would.

;;; Code:

(require 'harness-test-helpers)

(defun harness-update-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure, return trimmed stdout."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defun harness-update-test--configure (dir)
  "Give the repository DIR an identity to commit with, and no signing."
  (harness-update-test--git dir "config" "user.name" "Harness Test")
  (harness-update-test--git dir "config" "user.email" "test@example.invalid")
  (harness-update-test--git dir "config" "commit.gpgsign" "false"))

(defun harness-update-test--commit (dir file content message)
  "Write CONTENT to FILE in the repository DIR and commit it with MESSAGE."
  (let ((path (expand-file-name file dir)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert content)))
  (harness-update-test--git dir "add" file)
  (harness-update-test--git dir "commit" "-q" "-m" message))

(defun harness-update-test--read (file)
  "Return the contents of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun harness-update-test--failure (promise)
  "Wait for PROMISE to be rejected and return its error message."
  (condition-case err
      (progn (harness-test-await promise 30)
             (ert-fail "the update was not refused"))
    (error (harness-error-message err))))

(defmacro harness-update-test-with-clone (&rest body)
  "Run BODY with `upstream' a repository and `clone' a clone following its main.
Both are directory names; `base' is the directory holding them."
  (declare (indent 0))
  `(let* ((base (harness-test-temp-dir))
          (upstream (file-name-as-directory (expand-file-name "upstream" base)))
          (clone (file-name-as-directory (expand-file-name "clone" base))))
     (ignore base upstream clone)
     (unwind-protect
         (progn
           (make-directory upstream t)
           (harness-update-test--git upstream "init" "-q" "-b" "main")
           (harness-update-test--configure upstream)
           (harness-update-test--commit upstream "harness.el" ";; one\n" "First")
           (harness-update-test--git base "clone" "-q" upstream clone)
           (harness-update-test--configure clone)
           ,@body)
       (ignore-errors (delete-directory base t)))))

;;;; Where the harness runs from

(ert-deftest harness-update-source-directory-follows-links ()
  "A build of links into a clone, as straight.el makes, runs from the clone.
Then a pull reaches every file, new ones included, with no rebuild."
  (let* ((base (harness-test-temp-dir))
         (repo (file-name-as-directory (expand-file-name "repo" base)))
         (build (file-name-as-directory (expand-file-name "build" base)))
         (expected (file-name-as-directory (file-truename repo))))
    (unwind-protect
        (progn
          (make-directory repo t)
          (make-directory build t)
          (with-temp-file (expand-file-name "harness.el" repo) (insert ";; harness\n"))
          (make-symbolic-link (expand-file-name "harness.el" repo) (expand-file-name "harness.el" build))
          ;; The build's compiled file is its own, not a link.
          (with-temp-file (expand-file-name "harness.elc" build) (insert ";; compiled\n"))
          (should (equal expected (harness--source-directory (expand-file-name "harness.el" build))))
          (should (equal expected (harness--source-directory (expand-file-name "harness.elc" build))))
          ;; A checkout is its own source directory.
          (should (equal expected (harness--source-directory (expand-file-name "harness.el" repo)))))
      (delete-directory base t))))

(ert-deftest harness-update-stale-compiled-copy ()
  "A build's compiled harness.el counts as stale once its source moves on."
  (let* ((base (harness-test-temp-dir))
         (repo (file-name-as-directory (expand-file-name "repo" base)))
         (build (file-name-as-directory (expand-file-name "build" base)))
         (source (expand-file-name "harness.el" repo))
         (compiled (expand-file-name "harness.elc" build)))
    (unwind-protect
        (progn
          (make-directory repo t)
          (make-directory build t)
          (with-temp-file source (insert ";; harness\n"))
          (make-symbolic-link source (expand-file-name "harness.el" build))
          (with-temp-file compiled (insert ";; compiled\n"))
          (set-file-times source (time-subtract nil 60))
          (should-not (harness--stale-compiled-p compiled))
          (set-file-times source (time-add nil 60))
          (should (harness--stale-compiled-p compiled))
          ;; Source is never stale, and neither is nothing.
          (should-not (harness--stale-compiled-p (expand-file-name "harness.el" build)))
          (should-not (harness--stale-compiled-p nil)))
      (delete-directory base t))))

(ert-deftest harness-update-stale-compiled-copy-loads-the-source ()
  "Emacs starting on a build's stale harness.elc ends up running the new source.
The build is straight's kind, links into a clone; the clone moved on."
  (let* ((base (harness-test-temp-dir))
         (clone (file-name-as-directory (expand-file-name "clone" base)))
         (build (file-name-as-directory (expand-file-name "build" base)))
         (emacs (expand-file-name invocation-name invocation-directory))
         (run (lambda (&rest args)
                (with-temp-buffer
                  (let ((status (apply #'call-process emacs nil t nil "--batch" "-Q" args)))
                    (list status (buffer-string)))))))
    (unwind-protect
        (progn
          (make-directory clone t)
          (make-directory build t)
          (copy-file (expand-file-name "harness.el" harness-test-root) (expand-file-name "harness.el" clone))
          (make-symbolic-link (expand-file-name "lisp" harness-test-root) (expand-file-name "lisp" clone))
          (make-symbolic-link (expand-file-name "harness.el" clone) (expand-file-name "harness.el" build))
          ;; The build compiles harness.el, as a package manager does.
          (should (eql 0 (car (funcall run "-L" (expand-file-name "lisp" clone)
                                       "-f" "batch-byte-compile" (expand-file-name "harness.el" build)))))
          (should (file-exists-p (expand-file-name "harness.elc" build)))
          ;; An update moves the clone on.
          (with-temp-buffer
            (insert-file-contents (expand-file-name "harness.el" clone))
            (goto-char (point-max))
            (insert "\n(defun harness--update-test-new () \"New in the update.\" 'new)\n")
            (write-region nil nil (expand-file-name "harness.el" clone)))
          (set-file-times (expand-file-name "harness.el" clone) (time-add nil 60))
          (pcase-let ((`(,status ,output)
                       (funcall run "-L" build "--eval"
                                (prin1-to-string
                                 '(progn (require 'harness)
                                         (princ (format "%S %s" (and (fboundp 'harness--update-test-new)
                                                                     (harness--update-test-new))
                                                        harness-directory)))))))
            (should (eql 0 status))
            (should (string-match-p (format "\\`new %s\\'"
                                            (regexp-quote (file-name-as-directory (file-truename clone))))
                                    (string-trim (car (last (split-string output "\n" t))))))))
      (delete-directory base t))))

;;;; Updating the checkout

(ert-deftest harness-update-fast-forwards-to-the-upstream ()
  "New upstream commits are fetched and the clone moves to them, new files and all."
  (harness-update-test-with-clone
    (let ((before (harness-update-test--git clone "rev-parse" "--short" "HEAD")))
      (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
      (harness-update-test--commit upstream "lisp/modules/harness-new.el" ";; new\n" "Add a module")
      (let ((result (harness-test-await (harness--update-checkout clone) 30)))
        (should (equal before (plist-get result :from)))
        (should (equal (harness-update-test--git upstream "rev-parse" "HEAD")
                       (harness-update-test--git clone "rev-parse" "HEAD")))
        (should (equal (harness-update-test--git clone "rev-parse" "--short" "HEAD")
                       (plist-get result :to)))
        ;; The commits that came in, oldest first, each with its subject.
        (should (equal '("Second" "Add a module")
                       (mapcar (lambda (line) (substring line (1+ (string-search " " line))))
                               (plist-get result :commits))))
        (should (equal ";; two\n" (harness-update-test--read (expand-file-name "harness.el" clone))))
        (should (file-exists-p (expand-file-name "lisp/modules/harness-new.el" clone)))))))

(ert-deftest harness-update-refuses-a-version-that-does-not-compile ()
  "An upstream commit with a file that does not compile is never installed.
It is checked out of the clone and compiled elsewhere, then thrown away."
  (harness-update-test-with-clone
    (let ((head (harness-update-test--git clone "rev-parse" "HEAD"))
          (temporary-file-directory (file-name-as-directory (expand-file-name "tmp" base))))
      (make-directory temporary-file-directory)
      (harness-update-test--commit upstream "lisp/ui/harness-ui-broken.el"
                                   ";;; -*- lexical-binding: t -*-\n(defun harness-ui-broken ()\n  (list 1\n"
                                   "Break the build")
      (let ((problem (harness-update-test--failure (harness--update-checkout clone))))
        (should (string-match-p "is broken, so it was not installed" problem))
        (should (string-match-p "lisp/ui/harness-ui-broken\\.el: End of file during parsing" problem)))
      (should (equal head (harness-update-test--git clone "rev-parse" "HEAD")))
      (should-not (file-exists-p (expand-file-name "lisp/ui/harness-ui-broken.el" clone)))
      ;; The checked-out copy and its compiled files are gone.
      (should-not (directory-files temporary-file-directory nil directory-files-no-dot-files-regexp))
      ;; Fixed upstream, the next update goes through.
      (harness-update-test--commit upstream "lisp/ui/harness-ui-broken.el"
                                   ";;; -*- lexical-binding: t -*-\n(defun harness-ui-broken () (list 1))\n"
                                   "Fix the build")
      (should (= 2 (length (plist-get (harness-test-await (harness--update-checkout clone) 60) :commits))))
      (should (equal (harness-update-test--git upstream "rev-parse" "HEAD")
                     (harness-update-test--git clone "rev-parse" "HEAD"))))))

(ert-deftest harness-update-refuses-a-harness-el-that-does-not-load ()
  "The entry point must load as well as compile: an error as it runs is refused."
  (harness-update-test-with-clone
    (let ((head (harness-update-test--git clone "rev-parse" "HEAD")))
      (harness-update-test--commit upstream "harness.el"
                                   ";;; -*- lexical-binding: t -*-\n(error \"Broken as it loads\")\n"
                                   "Break the load")
      (should (string-match-p "is broken, so it was not installed: harness\\.el does not load: Broken as it loads"
                              (harness-update-test--failure (harness--update-checkout clone))))
      (should (equal head (harness-update-test--git clone "rev-parse" "HEAD"))))))

(ert-deftest harness-update-verify-passes-the-real-harness ()
  "The check passes this very checkout, the way an update would check it."
  (let ((commit (ignore-errors (harness-update-test--git harness-test-root "rev-parse" "HEAD"))))
    (skip-unless commit)
    (should (eq t (harness-test-await (harness--verify-commit harness-test-root commit) 300)))))

(ert-deftest harness-update-shallow-clone-as-doom-makes-it ()
  "Doom's straight.el clones one commit deep, one branch, no tags; that updates too."
  (harness-update-test-with-clone
    (let ((shallow (file-name-as-directory (expand-file-name "shallow" base))))
      (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
      (harness-update-test--git base "clone" "-q" "--depth" "1" "--single-branch" "--no-tags"
                                (concat "file://" (directory-file-name upstream)) shallow)
      (harness-update-test--configure shallow)
      (should (equal "true" (harness-update-test--git shallow "rev-parse" "--is-shallow-repository")))
      (harness-update-test--commit upstream "lisp/ui/harness-ui-new.el" ";; new\n" "Third")
      (harness-update-test--commit upstream "harness.el" ";; four\n" "Fourth")
      (let ((result (harness-test-await (harness--update-checkout shallow) 60)))
        (should (equal '("Third" "Fourth")
                       (mapcar (lambda (line) (substring line (1+ (string-search " " line))))
                               (plist-get result :commits))))
        (should (equal (harness-update-test--git upstream "rev-parse" "HEAD")
                       (harness-update-test--git shallow "rev-parse" "HEAD")))
        (should (file-exists-p (expand-file-name "lisp/ui/harness-ui-new.el" shallow)))))))

(ert-deftest harness-update-up-to-date ()
  "Nothing new upstream: the result says so and the clone stays."
  (harness-update-test-with-clone
    (let* ((head (harness-update-test--git clone "rev-parse" "--short" "HEAD"))
           (result (harness-test-await (harness--update-checkout clone) 30)))
      (should (equal head (plist-get result :from)))
      (should (equal head (plist-get result :to)))
      (should-not (plist-get result :commits)))))

(ert-deftest harness-update-refuses-local-changes ()
  "A clone with edits to its files is left alone, edits and all."
  (harness-update-test-with-clone
    (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
    (with-temp-file (expand-file-name "harness.el" clone) (insert ";; mine\n"))
    (let ((head (harness-update-test--git clone "rev-parse" "HEAD")))
      (should (string-match-p "has local changes"
                              (harness-update-test--failure (harness--update-checkout clone))))
      (should (equal head (harness-update-test--git clone "rev-parse" "HEAD")))
      (should (equal ";; mine\n" (harness-update-test--read (expand-file-name "harness.el" clone)))))))

(ert-deftest harness-update-refuses-diverged-branch ()
  "A clone with a commit the upstream lacks is not merged into."
  (harness-update-test-with-clone
    (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
    (harness-update-test--commit clone "notes.txt" "mine\n" "A commit of the clone's own")
    (let ((head (harness-update-test--git clone "rev-parse" "HEAD")))
      (should (string-match-p "has 1 commit the upstream lacks"
                              (harness-update-test--failure (harness--update-checkout clone))))
      (should (equal head (harness-update-test--git clone "rev-parse" "HEAD"))))))

(ert-deftest harness-update-local-commits-alone-are-up-to-date ()
  "A clone ahead of its upstream, with nothing new there, has nothing to update."
  (harness-update-test-with-clone
    (harness-update-test--commit clone "notes.txt" "mine\n" "A commit of the clone's own")
    (let ((result (harness-test-await (harness--update-checkout clone) 30)))
      (should-not (plist-get result :commits))
      (should (equal (plist-get result :from) (plist-get result :to))))))

(ert-deftest harness-update-refuses-detached-head ()
  "A checkout pinned to a commit, as a :pin in Doom makes, follows no branch."
  (harness-update-test-with-clone
    (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
    (harness-update-test--git clone "checkout" "-q" "--detach" "HEAD")
    (let ((head (harness-update-test--git clone "rev-parse" "HEAD")))
      (should (string-match-p "follows no upstream branch"
                              (harness-update-test--failure (harness--update-checkout clone))))
      (should (equal head (harness-update-test--git clone "rev-parse" "HEAD"))))))

(ert-deftest harness-update-refuses-a-directory-of-another-repository ()
  "A harness kept inside a larger repository, a configuration's, is not updated."
  (harness-update-test-with-clone
    (let ((inner (expand-file-name "vendor/harness/" clone)))
      (harness-update-test--commit clone "vendor/harness/harness.el" ";; vendored\n" "Vendor the harness")
      (should (string-match-p "not a checkout of its own"
                              (harness-update-test--failure (harness--update-checkout inner)))))))

(ert-deftest harness-update-refuses-a-plain-directory ()
  "A harness installed without git is the package manager's to update."
  (let ((dir (harness-test-temp-dir)))
    (unwind-protect
        (should (string-match-p "not a git checkout"
                                (harness-update-test--failure (harness--update-checkout dir))))
      (delete-directory dir t))))

;;;; The command

(ert-deftest harness-update-command-reloads-what-came-in ()
  "The command updates `harness-directory' and reloads a started harness once."
  (harness-update-test-with-clone
    (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
    (let ((harness-directory clone)
          (harness-started t)
          (harness--updating nil)
          (reloads 0)
          (shown nil))
      (cl-letf (((symbol-function 'harness--reload)
                 (lambda () (cl-incf reloads) (list :files 3 :errors nil)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format-message fmt args) shown))))
        (harness-update)
        (should harness--updating)
        (should-error (harness-update) :type 'user-error)
        (harness-test-wait (lambda () (cl-find-if (lambda (m) (string-match-p "and reloaded" m)) shown))
                           30 "the update")
        (should-not harness--updating)
        (should (= 1 reloads))
        (should (string-match-p "\\`Harness updated from [0-9a-f]+ to [0-9a-f]+ (1 commit) and reloaded\\'"
                                (car shown)))
        ;; Run again, it finds nothing new and reloads nothing.
        (harness-update)
        (harness-test-wait (lambda () (string-prefix-p "Harness is up to date" (car shown))) 30 "the check")
        (should (= 1 reloads))))))

(ert-deftest harness-update-command-reports-a-refused-reload ()
  "When the update does not compile here, the message says how to go back."
  (harness-update-test-with-clone
    (let ((before (harness-update-test--git clone "rev-parse" "--short" "HEAD"))
          (shown nil))
      (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
      (cl-letf (((symbol-function 'harness--reload)
                 (lambda () (list :refused '("harness-ui.el: oops"))))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format-message fmt args) shown))))
        (let ((harness-started t))
          (harness--updated clone (harness-test-await (harness--update-checkout clone) 30)))
        (should (string-match-p "reload was refused: harness-ui.el: oops" (car shown)))
        (should (string-match-p (regexp-quote (format "reset --keep %s" before)) (car shown)))))))

(ert-deftest harness-update-command-reports-failures ()
  "A refused update ends in a message, and the next one may run."
  (let ((dir (harness-test-temp-dir))
        (shown nil))
    (unwind-protect
        (let ((harness-directory dir)
              (harness--updating nil))
          (cl-letf (((symbol-function 'message)
                     (lambda (fmt &rest args) (push (apply #'format-message fmt args) shown))))
            (harness-update)
            (harness-test-wait (lambda () (cl-find-if (lambda (m) (string-prefix-p "Harness update failed" m)) shown))
                               30 "the failure")
            (should (string-match-p "not a git checkout" (car shown)))
            (should-not harness--updating)))
      (delete-directory dir t))))

;;;; Git never prompts

(ert-deftest harness-update-git-cannot-prompt ()
  "Git in the background asks for nothing, on the terminal or on the screen."
  (let ((env (let ((process-environment (cl-remove-if (lambda (v) (string-match-p "\\`GIT_SSH" v))
                                                      process-environment)))
               (harness--git-environment))))
    (should (equal "0" (cdr (assoc "GIT_TERMINAL_PROMPT" env))))
    ;; Empty, not unset: unset, git would fall back to SSH_ASKPASS.
    (should (equal "" (cdr (assoc "GIT_ASKPASS" env))))
    (should (string-match-p "BatchMode=yes" (cdr (assoc "GIT_SSH_COMMAND" env)))))
  ;; An ssh command of the user's own is theirs.
  (let ((process-environment (cons "GIT_SSH_COMMAND=ssh -i key" process-environment)))
    (should-not (assoc "GIT_SSH_COMMAND" (harness--git-environment)))))

;;;; Merge conflicts

(ert-deftest harness-update-refuses-conflict-markers-that-compile ()
  "A committed conflict between two balanced sides compiles, yet is refused.
Its markers read as variables, so only the load would fail."
  (harness-update-test-with-clone
    (let ((head (harness-update-test--git clone "rev-parse" "HEAD")))
      (harness-update-test--commit upstream "lisp/modules/harness-mod.el"
                                   (concat ";;; -*- lexical-binding: t -*-\n"
                                           "<<<<<<< HEAD\n(defun harness-mod () 1)\n"
                                           "=======\n(defun harness-mod () 2)\n"
                                           ">>>>>>> feature\n")
                                   "Commit a conflict")
      (let ((problem (harness-update-test--failure (harness--update-checkout clone))))
        (should (string-match-p "lisp/modules/harness-mod\\.el:2: a merge conflict marker" problem)))
      (should (equal head (harness-update-test--git clone "rev-parse" "HEAD"))))))

(ert-deftest harness-update-marker-lines-in-strings-pass ()
  "Lines of a string that look like conflict markers are not conflicts."
  (harness-update-test-with-clone
    (harness-update-test--commit upstream "lisp/modules/harness-doc.el"
                                 (concat ";;; -*- lexical-binding: t -*-\n"
                                         "(defun harness-doc ()\n  \"A conflict looks like this:\n"
                                         "<<<<<<< HEAD\n=======\n>>>>>>> feature\nin a file.\"\n  nil)\n")
                                 "Document conflicts")
    (should (= 1 (length (plist-get (harness-test-await (harness--update-checkout clone) 60) :commits))))
    (should (file-exists-p (expand-file-name "lisp/modules/harness-doc.el" clone)))))

(provide 'harness-update-test)
;;; harness-update-test.el ends here
