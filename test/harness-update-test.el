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

(defun harness-update-test--commit-with-body (dir file content subject body)
  "Write CONTENT to FILE in the repository DIR and commit it with SUBJECT and BODY."
  (let ((path (expand-file-name file dir)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert content)))
  (harness-update-test--git dir "add" file)
  (harness-update-test--git dir "commit" "-q" "-m" subject "-m" body))

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

;; straight.el names a package by the name its recipe gives it, and
;; keeps its clone in the directory of the recipe's :local-repo: the
;; recipe (package! harness :recipe (:repo "~me/emacs-agent-harness"))
;; makes package `harness' in the clone emacs-agent-harness/.  Its pull,
;; `straight-pull-package', takes the package's name, looks the recipe up
;; in `straight--recipe-cache' and, finding none, does nothing: it
;; fetches nothing, changes nothing and complains of nothing.  It
;; returns nil then, and nil when it pulls too, so its value says
;; nothing.  The tests below stand in a straight.el that behaves so,
;; with its clones laid out as straight.el lays them out:
;; straight/repos/LOCAL-REPO/.
(defvar straight--recipe-cache)
(defvar straight--repo-cache)

(defmacro harness-update-test-with-straight (local-repo recipes &rest body)
  "Run BODY with `upstream', and `clone' a clone of it as straight.el keeps one.
The clone is depth 1, one branch and no tags, as Doom's straight.el
makes it, in the directory LOCAL-REPO of a straight repos directory,
and `base' holds both; `harness-directory' is the clone, as the
harness runs from it.  RECIPES is a list of (PACKAGE . LOCAL-REPO), the
recipes the fake straight.el has registered; `pulled' collects the
package names its pull was asked for.  The pull does what
`straight-pull-package' does: it fetches and merges the clone of the
recipe of the package it is given, and does nothing, silently, for a
name that has none."
  (declare (indent 2))
  `(let* ((base (harness-test-temp-dir))
          (upstream (file-name-as-directory (expand-file-name "upstream" base)))
          (repos (file-name-as-directory (expand-file-name "straight/repos" base)))
          (clone (file-name-as-directory (expand-file-name ,local-repo repos)))
          ;; The harness runs from the clone, as it does from straight.el's.
          (harness-directory clone)
          (straight--recipe-cache (make-hash-table :test #'equal))
          (straight--repo-cache (make-hash-table :test #'equal))
          (pulled nil))
     (ignore base upstream clone pulled)
     (dolist (recipe ,recipes)
       (let ((plist (list :package (car recipe) :local-repo (cdr recipe) :type 'git)))
         (puthash (car recipe) plist straight--recipe-cache)
         (puthash (cdr recipe) plist straight--repo-cache)))
     (unwind-protect
         (progn
           (make-directory upstream t)
           (make-directory repos t)
           (harness-update-test--git upstream "init" "-q" "-b" "main")
           (harness-update-test--configure upstream)
           (harness-update-test--commit upstream "harness.el" ";; one\n" "First")
           (harness-update-test--git base "clone" "-q" "--depth" "1" "--single-branch" "--no-tags"
                                     (concat "file://" (directory-file-name upstream)) clone)
           (harness-update-test--configure clone)
           (cl-letf (((symbol-function 'straight-pull-package)
                      (lambda (package &optional _from-upstream)
                        (push package pulled)
                        (when-let* ((recipe (gethash package straight--recipe-cache)))
                          (let ((dir (expand-file-name (plist-get recipe :local-repo) repos)))
                            (harness-update-test--git dir "fetch" "-q" "origin")
                            (harness-update-test--git dir "merge" "-q" "--ff-only" "origin/main")))
                        nil)))
             ,@body))
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
        ;; The commits that came in, newest first, each with its subject.
        (should (equal '("Add a module" "Second")
                       (mapcar (lambda (c) (plist-get c :subject))
                               (plist-get result :commits))))
        (should (equal ";; two\n" (harness-update-test--read (expand-file-name "harness.el" clone))))
        (should (file-exists-p (expand-file-name "lisp/modules/harness-new.el" clone)))))))


(ert-deftest harness-update-fast-forwards-with-no-upstream-configured ()
  "A checkout whose branch tracks nothing follows origin's branch of the same name."
  (harness-update-test-with-clone
    (harness-update-test--git clone "config" "--unset" "branch.main.remote")
    (harness-update-test--git clone "config" "--unset" "branch.main.merge")
    (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
    (let ((result (harness-test-await (harness--update-checkout clone) 30)))
      (should (equal (harness-update-test--git upstream "rev-parse" "HEAD")
                     (harness-update-test--git clone "rev-parse" "HEAD")))
      (should (equal '("Second") (mapcar (lambda (c) (plist-get c :subject))
                                         (plist-get result :commits)))))))

(ert-deftest harness-update-refuses-an-untracked-branch-the-remote-lacks ()
  "A branch with no upstream, and no such branch on origin, is refused by name."
  (harness-update-test-with-clone
    (harness-update-test--git clone "config" "--unset" "branch.main.remote")
    (harness-update-test--git clone "config" "--unset" "branch.main.merge")
    (harness-update-test--git clone "checkout" "-q" "-b" "topic")
    (let ((head (harness-update-test--git clone "rev-parse" "HEAD")))
      (should (string-match-p "follows no upstream branch and origin has no branch topic to fetch"
                              (harness-update-test--failure (harness--update-checkout clone))))
      (should (equal head (harness-update-test--git clone "rev-parse" "HEAD"))))))

(ert-deftest harness-update-refuses-a-checkout-without-a-remote ()
  "A checkout with no remote at all has nothing to update from."
  (harness-update-test-with-clone
    (harness-update-test--git clone "remote" "remove" "origin")
    (let ((head (harness-update-test--git clone "rev-parse" "HEAD")))
      (should (string-match-p "has no remote to update from"
                              (harness-update-test--failure (harness--update-checkout clone))))
      (should (equal head (harness-update-test--git clone "rev-parse" "HEAD"))))))

(ert-deftest harness-update-lists-a-commit-body ()
  "The commits an update brought are read as changelog entries, body included."
  (harness-update-test-with-clone
    (harness-update-test--commit-with-body upstream "harness.el" ";; two\n"
                                           "Second" "A body line.\nAnother body line.")
    (let* ((result (harness-test-await (harness--update-checkout clone) 30))
           (commit (car (plist-get result :commits))))
      (should (equal "Second" (plist-get commit :subject)))
      (should (string-match-p "A body line\\.\nAnother body line\\." (plist-get commit :body)))
      (should (= 1 (plist-get result :count))))))

(ert-deftest harness-update-straight-pulls-the-package ()
  "A checkout straight.el manages is updated with its own pull, not a git fetch."
  (harness-update-test-with-clone
    (let ((before (harness-update-test--git clone "rev-parse" "HEAD"))
          (pulled nil))
      (cl-letf (((symbol-function 'harness--straight-package) (lambda (&optional _dir) "harness"))
                ((symbol-function 'straight-pull-package)
                 (lambda (package)
                   (setq pulled package)
                   (harness-update-test--commit clone "harness.el" ";; straight\n" "Straight")
                   t)))
        (let ((result (harness-test-await (harness--update-package clone) 30)))
          (should (equal "harness" pulled))
          (should (equal "Straight" (plist-get (car (plist-get result :commits)) :subject)))
          (should (not (equal before (harness-update-test--git clone "rev-parse" "HEAD")))))))))

(ert-deftest harness-update-straight-resets-a-broken-pull ()
  "straight's pull that lands on a commit that does not compile is put back."
  (harness-update-test-with-clone
    (let ((head (harness-update-test--git clone "rev-parse" "HEAD")))
      (cl-letf (((symbol-function 'harness--straight-package) (lambda (&optional _dir) "harness"))
                ((symbol-function 'straight-pull-package)
                 (lambda (_package)
                   (harness-update-test--commit clone "lisp/ui/harness-ui-broken.el"
                                                ";;; -*- lexical-binding: t -*-\n(defun harness-ui-broken ()\n  (list 1\n"
                                                "Break the build")
                   t)))
        (should (string-match-p "is broken, so it was not installed"
                                (harness-update-test--failure (harness--update-package clone))))
        (should (equal head (harness-update-test--git clone "rev-parse" "HEAD")))
        (should-not (file-exists-p (expand-file-name "lisp/ui/harness-ui-broken.el" clone)))))))

;;;; The package straight.el knows the checkout by

(ert-deftest harness-update-straight-package-is-the-one-registered ()
  "The package of a straight.el clone is its recipe's name, not its directory's.
The recipe (package! harness ...) keeps package `harness' in the
directory emacs-agent-harness/: `straight-pull-package' is given the
package, and a directory's name is none."
  (harness-update-test-with-straight "emacs-agent-harness" '(("harness" . "emacs-agent-harness"))
    (should (equal "harness" (harness--straight-package clone)))
    ;; Another package's directory, or a directory that holds no package.
    (should-not (harness--straight-package (expand-file-name "other-package" repos)))
    (should-not (harness--straight-package (expand-file-name "emacs-agent-harness" base)))
    ;; Its build directory is named for the package.
    (should (equal "harness" (harness--straight-package (expand-file-name "straight/build-31.1/harness/" base))))
    (should-not (harness--straight-package (expand-file-name "straight/build-31.1/emacs-agent-harness/" base)))))

(ert-deftest harness-update-straight-package-named-as-its-repository ()
  "A package named as its repository is the directory's name: that is the usual one."
  (harness-update-test-with-straight "harness" '(("harness" . "harness"))
    (should (equal "harness" (harness--straight-package clone)))
    (should (equal "harness" (harness--straight-package (expand-file-name "straight/build/harness/" base))))))

(ert-deftest harness-update-straight-package-of-a-shared-clone ()
  "Packages that share one clone: the one straight.el keeps the clone's recipe under."
  (harness-update-test-with-straight "emacs-agent-harness"
      '(("harness" . "emacs-agent-harness") ("harness-extras" . "emacs-agent-harness"))
    (should (equal "harness-extras" (harness--straight-package clone)))
    (puthash "emacs-agent-harness" (gethash "harness" straight--recipe-cache) straight--repo-cache)
    (should (equal "harness" (harness--straight-package clone)))
    ;; Without a record of the clone, the first by name.
    (clrhash straight--repo-cache)
    (should (equal "harness" (harness--straight-package clone)))))

(ert-deftest harness-update-straight-package-without-a-recipe ()
  "straight.el loaded, with no recipe for the checkout: it manages none here."
  (harness-update-test-with-straight "emacs-agent-harness" '(("magit" . "magit"))
    (should-not (harness--straight-package clone))
    (should-not (harness--straight-package (expand-file-name "straight/build/harness/" base)))))

(ert-deftest harness-update-straight-package-guessed-without-straight ()
  "An Emacs without straight.el cannot look, and answers with the directory's name.
Only the text on the version page makes use of it: such an Emacs does not pull."
  (let* ((base (harness-test-temp-dir))
         (repos (expand-file-name "straight/repos/emacs-agent-harness/" base)))
    (unwind-protect
        (progn
          (should-not (boundp 'straight--recipe-cache))
          (should (equal "emacs-agent-harness" (harness--straight-package repos)))
          (should (equal "harness" (harness--straight-package (expand-file-name "straight/build/harness/" base))))
          ;; Not under a straight directory: a checkout of one's own.
          (should-not (harness--straight-package (expand-file-name "src/emacs-agent-harness/" base)))
          (should-not (harness--straight-package (expand-file-name "straight/other/harness/" base)))
          (should-not (harness--straight-package (expand-file-name "repos/harness/" base))))
      (ignore-errors (delete-directory base t)))))

(ert-deftest harness-update-straight-package-in-a-linked-repos-directory ()
  "straight.el's repos directory reached through a link still holds the clone.
`harness-directory' has its links followed, straight.el's own name for
its directory has not, and the directory need not be called straight."
  (harness-update-test-with-straight "emacs-agent-harness" '(("harness" . "emacs-agent-harness"))
    (let* ((real (file-name-as-directory (expand-file-name "elsewhere" base)))
           (linked (expand-file-name "linked" base))
           (checkout (file-name-as-directory
                      (file-truename (expand-file-name "repos/emacs-agent-harness" real)))))
      (make-directory (expand-file-name "repos/emacs-agent-harness" real) t)
      (make-symbolic-link (directory-file-name real) linked)
      ;; Nothing about its path says straight.el keeps packages there.
      (should-not (harness--straight-package checkout))
      (cl-letf (((symbol-function 'straight--repos-dir)
                 (lambda (&rest _) (file-name-as-directory (expand-file-name "repos" linked)))))
        (should (equal "harness" (harness--straight-package checkout)))
        ;; The repos directory itself, and a directory beside it, hold none.
        (should-not (harness--straight-package (expand-file-name "repos" real)))
        (should-not (harness--straight-package (expand-file-name "other/emacs-agent-harness" real)))))))

(ert-deftest harness-update-straight-package-defaults-to-the-harness-directory ()
  "Without a directory, the one the harness runs from."
  (harness-update-test-with-straight "emacs-agent-harness" '(("harness" . "emacs-agent-harness"))
    (let ((harness-directory clone))
      (should (equal "harness" (harness--straight-package))))
    (let ((harness-directory nil))
      (should-not (harness--straight-package)))))

;;;; Updating a straight.el clone

(ert-deftest harness-update-straight-pulls-the-package-registered ()
  "A clone kept under another name than its package's is pulled as its package.
This is the install that updated nothing and said it was up to date: the
clone emacs-agent-harness/ of package `harness' was pulled as
\"emacs-agent-harness\", a name straight.el has no recipe for, so its
pull did nothing."
  (harness-update-test-with-straight "emacs-agent-harness" '(("harness" . "emacs-agent-harness"))
    (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
    (harness-update-test--commit upstream "lisp/modules/harness-new.el" ";; new\n" "Add a module")
    (let ((result (harness-test-await (harness--update-package clone) 60)))
      (should (equal '("Add a module" "Second")
                     (mapcar (lambda (c) (plist-get c :subject)) (plist-get result :commits))))
      (should (= 2 (plist-get result :count)))
      (should (equal (harness-update-test--git upstream "rev-parse" "HEAD")
                     (harness-update-test--git clone "rev-parse" "HEAD")))
      (should (file-exists-p (expand-file-name "lisp/modules/harness-new.el" clone)))
      ;; By the package's name, the one straight.el has a recipe for.
      (should (equal '("harness") pulled)))))

(ert-deftest harness-update-straight-pull-that-moves-nothing-asks-the-remote ()
  "A pull that did nothing does not make the clone up to date: the remote is asked.
straight.el's pull returns nil whether it pulled or did nothing, and
says nothing either way, so an unmoved clone is no proof of anything."
  (harness-update-test-with-straight "emacs-agent-harness" '(("harness" . "emacs-agent-harness"))
    (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
    (cl-letf (((symbol-function 'straight-pull-package)
               (lambda (package &optional _from-upstream) (push package pulled) nil)))
      (let ((result (harness-test-await (harness--update-package clone) 60)))
        (should (equal '("harness") pulled))
        (should (equal '("Second") (mapcar (lambda (c) (plist-get c :subject)) (plist-get result :commits))))
        (should (equal (harness-update-test--git upstream "rev-parse" "HEAD")
                       (harness-update-test--git clone "rev-parse" "HEAD")))))))

(ert-deftest harness-update-straight-pull-that-moves-nothing-with-nothing-new ()
  "Up to date is said after the remote was asked, which is seen in the clone's fetch."
  (harness-update-test-with-straight "emacs-agent-harness" '(("harness" . "emacs-agent-harness"))
    (cl-letf (((symbol-function 'straight-pull-package)
               (lambda (package &optional _from-upstream) (push package pulled) nil)))
      (should-not (file-exists-p (expand-file-name ".git/FETCH_HEAD" clone)))
      (let ((head (harness-update-test--git clone "rev-parse" "--short" "HEAD"))
            (result (harness-test-await (harness--update-package clone) 60)))
        (should (equal '("harness") pulled))
        (should (= 0 (plist-get result :count)))
        (should-not (plist-get result :commits))
        (should (equal head (plist-get result :from)))
        (should (equal head (plist-get result :to)))
        (should (file-exists-p (expand-file-name ".git/FETCH_HEAD" clone)))))))

(ert-deftest harness-update-straight-pull-checks-what-the-remote-gave-too ()
  "What the remote gives after a pull that moved nothing is checked like any update."
  (harness-update-test-with-straight "emacs-agent-harness" '(("harness" . "emacs-agent-harness"))
    (let ((head (harness-update-test--git clone "rev-parse" "HEAD")))
      (harness-update-test--commit upstream "lisp/ui/harness-ui-broken.el"
                                   ";;; -*- lexical-binding: t -*-\n(defun harness-ui-broken ()\n  (list 1\n"
                                   "Break the build")
      (cl-letf (((symbol-function 'straight-pull-package) (lambda (&rest _) nil)))
        (should (string-match-p "is broken, so it was not installed"
                                (harness-update-test--failure (harness--update-package clone)))))
      (should (equal head (harness-update-test--git clone "rev-parse" "HEAD"))))))

(ert-deftest harness-update-clone-straight-has-no-recipe-for-is-fetched ()
  "A clone straight.el has no recipe for is updated from its remote branch, not pulled."
  (harness-update-test-with-straight "emacs-agent-harness" '(("magit" . "magit"))
    (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
    (let ((result (harness-test-await (harness--update-package clone) 60)))
      (should-not pulled)
      (should (equal '("Second") (mapcar (lambda (c) (plist-get c :subject)) (plist-get result :commits))))
      (should (equal (harness-update-test--git upstream "rev-parse" "HEAD")
                     (harness-update-test--git clone "rev-parse" "HEAD"))))))

(ert-deftest harness-update-straight-pull-that-fails-is-reported ()
  "An error of straight.el's pull is the update's failure, and the clone stays."
  (harness-update-test-with-straight "emacs-agent-harness" '(("harness" . "emacs-agent-harness"))
    (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
    (let ((head (harness-update-test--git clone "rev-parse" "HEAD")))
      (cl-letf (((symbol-function 'straight-pull-package)
                 (lambda (&rest _) (error "Failed to run git fetch origin, see buffer *straight-process*"))))
        (should (string-match-p "straight-pull-package failed: Failed to run git fetch origin"
                                (harness-update-test--failure (harness--update-package clone)))))
      (should (equal head (harness-update-test--git clone "rev-parse" "HEAD"))))))

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
        (should (equal '("Fourth" "Third")
                       (mapcar (lambda (c) (plist-get c :subject))
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
      (should (string-match-p "follows no branch to update from: its HEAD is detached"
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

(defun harness-update-test--loaded (dir)
  "Return the settled promise of DIR's revision, as the harness notes it on loading."
  (harness-resolved (list :directory dir :loaded (float-time) :version "3.0.0"
                          :commit (harness-update-test--git dir "rev-parse" "HEAD")
                          :branch "main" :dirty nil)))

(ert-deftest harness-update-reloads-a-checkout-that-moved-on-by-itself ()
  "With nothing new from the remote, the harness is not up to date if it runs older code.
A package manager, or a pull by hand, moved the checkout on while the
harness ran the commit it was loaded from.  \"Up to date\" would be false,
and the version page beside the message says it is not the latest."
  (harness-update-test-with-clone
    (let ((harness-directory clone)
          (harness-started t)
          (harness--updating nil)
          (harness-revision--loaded (harness-update-test--loaded clone))
          (reloads 0)
          (shown nil))
      (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
      (harness-update-test--git clone "pull" "-q" "--ff-only")
      (cl-letf (((symbol-function 'harness--reload)
                 (lambda ()
                   (cl-incf reloads)
                   ;; A reload notes the commit it loaded.
                   (setq harness-revision--loaded (harness-update-test--loaded clone))
                   (list :files 3 :errors nil)))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format-message fmt args) shown))))
        (harness-update)
        (harness-test-wait (lambda () (cl-find-if (lambda (m) (string-match-p "which its checkout already had" m)) shown))
                           30 "the update")
        (should (= 1 reloads))
        (should (string-match-p "\\`Harness reloaded from [0-9a-f]+ to [0-9a-f]+, which its checkout already had\\'"
                                (car shown)))
        (should (equal "updated" (plist-get harness--last-update :state)))
        (should (= 0 (plist-get harness--last-update :count)))
        (should-not (plist-get harness--last-update :commits))
        ;; Reloaded, the harness runs the checkout's commit: that is up to date.
        (harness-update)
        (harness-test-wait (lambda () (string-prefix-p "Harness is up to date" (car shown))) 30 "the check")
        (should (= 1 reloads))))))

(ert-deftest harness-update-reload-of-a-checkout-that-moved-on-refused ()
  "A reload that is refused says what still runs, and has no update to go back from."
  (harness-update-test-with-clone
    (let ((harness-started t)
          (harness-revision--loaded (harness-update-test--loaded clone))
          (running (harness-update-test--git clone "rev-parse" "--short" "HEAD"))
          (shown nil))
      (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
      (harness-update-test--git clone "pull" "-q" "--ff-only")
      (cl-letf (((symbol-function 'harness--reload)
                 (lambda () (list :refused '("harness-ui.el: oops"))))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format-message fmt args) shown))))
        (harness--updated clone (harness-test-await (harness--update-checkout clone) 30))
        (should (string-match-p "reload to [0-9a-f]+ was refused: harness-ui.el: oops" (car shown)))
        (should (string-match-p (format "still runs %s: restart Emacs to load it" running) (car shown)))
        (should-not (string-match-p "reset --keep" (car shown)))))))

(ert-deftest harness-update-nothing-new-and-nothing-known-of-what-runs-is-up-to-date ()
  "Without a commit the harness is known to run, or one of another checkout, nothing is reloaded."
  (harness-update-test-with-clone
    (let ((harness-started t)
          (reloads 0)
          result)
      ;; The checkout is ahead of the commit that was noted, and has nothing new to fetch.
      (harness-update-test--commit upstream "harness.el" ";; two\n" "Second")
      (harness-update-test--git clone "pull" "-q" "--ff-only")
      (setq result (harness-test-await (harness--update-checkout clone) 30))
      (should (= 0 (plist-get result :count)))
      (cl-letf (((symbol-function 'harness--reload) (lambda () (cl-incf reloads) (list :files 1)))
                ((symbol-function 'message) #'ignore))
        (dolist (loaded (list
                         ;; Not noted yet, or not settled.
                         nil (harness-make-promise)
                         ;; Not from a git checkout.
                         (harness-resolved (list :directory clone :error "no git"))
                         ;; From another checkout.
                         (harness-resolved (list :directory (expand-file-name "elsewhere/" clone)
                                                 :commit (make-string 40 ?a)))))
          (let ((harness-revision--loaded loaded))
            (should (string-prefix-p "Harness is up to date" (harness--updated clone result)))))
        ;; A harness not started loads what the checkout holds when it does.
        (let ((harness-started nil)
              (harness-revision--loaded (harness-resolved (list :directory clone :commit (make-string 40 ?a)))))
          (should (string-prefix-p "Harness is up to date" (harness--updated clone result))))
        (should (= 0 reloads))))))

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

;;;; Vendored libraries

(ert-deftest harness-update-refuses-a-vendored-library-that-does-not-compile ()
  "A library under lisp/vendor is checked like the harness's own files.
One that does not compile refuses the update, named by its path in the
tree.  Its tests are not compiled: the harness never loads them."
  (harness-update-test-with-clone
    (let ((head (harness-update-test--git clone "rev-parse" "HEAD"))
          (temporary-file-directory (file-name-as-directory (expand-file-name "tmp" base))))
      (make-directory temporary-file-directory)
      (harness-update-test--commit upstream "lisp/vendor/broken/broken.el"
                                   ";;; -*- lexical-binding: t -*-\n(defun broken ()\n  (list 1\n"
                                   "Vendor a library that does not compile")
      (let ((problem (harness-update-test--failure (harness--update-checkout clone))))
        (should (string-match-p "is broken, so it was not installed" problem))
        (should (string-match-p "lisp/vendor/broken/broken\\.el: End of file during parsing" problem)))
      (should (equal head (harness-update-test--git clone "rev-parse" "HEAD")))
      (should-not (file-exists-p (expand-file-name "lisp/vendor/broken/broken.el" clone)))
      ;; The checked-out copy and its compiled files are gone.
      (should-not (directory-files temporary-file-directory nil directory-files-no-dot-files-regexp))
      ;; Fixed upstream, the next update goes through, though the library's
      ;; test file next to it would not compile either.
      (harness-update-test--commit upstream "lisp/vendor/broken/broken.el"
                                   ";;; -*- lexical-binding: t -*-\n(defun broken () (list 1))\n"
                                   "Fix the library")
      (harness-update-test--commit upstream "lisp/vendor/broken/broken-test.el"
                                   ";;; -*- lexical-binding: t -*-\n(ert-deftest broken-test ()\n  (should (broken)\n"
                                   "Add a test that does not compile")
      (should (= 3 (length (plist-get (harness-test-await (harness--update-checkout clone) 60) :commits))))
      (should (equal (harness-update-test--git upstream "rev-parse" "HEAD")
                     (harness-update-test--git clone "rev-parse" "HEAD")))
      (should (file-exists-p (expand-file-name "lisp/vendor/broken/broken-test.el" clone))))))

(ert-deftest harness-update-check-finds-the-vendored-libraries ()
  "The check has the vendored libraries' directories on its load path.
A file of the harness requires a library by its name, as the compose box
requires compose-quote, and a library requires another file of its own
directory; neither compiles unless the directory is on the path."
  (harness-update-test-with-clone
    (harness-update-test--commit upstream "lisp/vendor/lib/lib-util.el"
                                 ";;; -*- lexical-binding: t -*-\n(defun lib-util () 1)\n(provide 'lib-util)\n"
                                 "Vendor a library's helper")
    (harness-update-test--commit upstream "lisp/vendor/lib/lib.el"
                                 (concat ";;; -*- lexical-binding: t -*-\n"
                                         "(require 'lib-util)\n(defun lib () (lib-util))\n(provide 'lib)\n")
                                 "Vendor a library")
    (harness-update-test--commit upstream "lisp/ui/harness-ui-uses-lib.el"
                                 (concat ";;; -*- lexical-binding: t -*-\n"
                                         "(require 'lib)\n(defun harness-ui-uses-lib () (lib))\n")
                                 "Use it")
    (should (= 3 (length (plist-get (harness-test-await (harness--update-checkout clone) 60) :commits))))
    (should (file-exists-p (expand-file-name "lisp/ui/harness-ui-uses-lib.el" clone)))))

(provide 'harness-update-test)
;;; harness-update-test.el ends here
