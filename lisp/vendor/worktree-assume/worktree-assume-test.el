;;; worktree-assume-test.el --- Tests for worktree-assume  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 catvec

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Run with nothing but this directory on the load path:
;;
;;   emacs -Q --batch -L . -l worktree-assume-test.el -f ert-run-tests-batch-and-exit
;;
;; The tests make real git repositories with real worktrees in a
;; temporary directory, and ask project.el about them.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'project)
(require 'worktree-assume)

;;;; Repositories

(defun worktree-assume-test--git (dir &rest args)
  "Run git with ARGS in DIR, without the user's configuration.
Return what it printed, or signal an error saying what it said."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (unless (zerop (apply #'process-file "git" nil t nil
                            "-c" "user.name=Test" "-c" "user.email=test@example.invalid"
                            "-c" "commit.gpgsign=false" "-c" "init.defaultBranch=main"
                            args))
        (error "Git %S failed in %s: %s" args dir (buffer-string)))
      (buffer-string))))

(defun worktree-assume-test--git-version ()
  "Return the version of git as a string such as \"2.43.0\", or nil without git."
  (when (executable-find "git")
    (with-temp-buffer
      ;; Not the current directory, which may be spelled with a ~ that a
      ;; test that sets HOME cannot expand.
      (setq default-directory (file-name-as-directory temporary-file-directory))
      (call-process "git" nil t nil "--version")
      (when (re-search-backward "\\([0-9]+\\(?:\\.[0-9]+\\)+\\)" nil t)
        (match-string 1)))))

(defun worktree-assume-test--write (file text)
  "Write TEXT to FILE, making its directory."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert text)))

(defun worktree-assume-test--commit-file (dir file text)
  "Commit FILE, holding TEXT, in the worktree DIR."
  (worktree-assume-test--write (expand-file-name file dir) text)
  (worktree-assume-test--git dir "add" file)
  (worktree-assume-test--git dir "commit" "-q" "-m" (concat "Add " file)))

(defmacro worktree-assume-test-with-repo (names &rest body)
  "Make a git repository with worktrees and run BODY with NAMES bound.
NAMES is (ROOT NESTED SECOND SIBLING BASE), each a symbol or nil.
ROOT is the main worktree, with README and sub/main.txt; NESTED and
SECOND are linked worktrees in ROOT/.worktrees, branches feature and
second, where NESTED has feature.txt too; SIBLING is a linked worktree
beside ROOT; BASE holds all of them.  Directory names are true names,
with a trailing slash.  Nothing assumed stands before or after BODY,
and git ignores the user's configuration."
  (declare (indent 1))
  (let ((root (or (nth 0 names) (make-symbol "root")))
        (nested (or (nth 1 names) (make-symbol "nested")))
        (second (or (nth 2 names) (make-symbol "second")))
        (sibling (or (nth 3 names) (make-symbol "sibling")))
        (base (or (nth 4 names) (make-symbol "base"))))
    `(let* ((_ (skip-unless (executable-find "git")))
            (,base (file-name-as-directory
                    (file-truename (make-temp-file "worktree-assume-test" t))))
            (process-environment (append (list (concat "HOME=" ,base)
                                               "GIT_CONFIG_NOSYSTEM=1")
                                         process-environment))
            (,root (expand-file-name "repo/" ,base))
            (,nested (expand-file-name "repo/.worktrees/feature/" ,base))
            (,second (expand-file-name "repo/.worktrees/second/" ,base))
            (,sibling (expand-file-name "sibling/" ,base)))
       (ignore ,root ,nested ,second ,sibling)
       (unwind-protect
           (progn
             (make-directory ,root t)
             (worktree-assume-test--git ,root "init" "-q")
             ;; Whatever git calls the first branch, which older ones do not set by a config.
             (worktree-assume-test--git ,root "symbolic-ref" "HEAD" "refs/heads/main")
             (worktree-assume-test--write (expand-file-name "README" ,root) "main\n")
             (worktree-assume-test--write (expand-file-name "sub/main.txt" ,root) "main\n")
             (worktree-assume-test--git ,root "add" ".")
             (worktree-assume-test--git ,root "commit" "-q" "-m" "Start")
             (worktree-assume-test--git ,root "worktree" "add" "-q" "-b" "feature" ,nested)
             (worktree-assume-test--git ,root "worktree" "add" "-q" "-b" "second" ,second)
             (worktree-assume-test--git ,root "worktree" "add" "-q" "-b" "other" ,sibling)
             (worktree-assume-test--commit-file ,nested "feature.txt" "feature\n")
             (worktree-assume-test--with-clean-state
               ,@body))
         (delete-directory ,base t)))))

(defmacro worktree-assume-test--with-clean-state (&rest body)
  "Run BODY, then forget every assumption and take the mode off again."
  (declare (indent 0))
  `(let ((worktree-assume-change-functions nil)
         (worktree-assume-inhibit nil))
     (unwind-protect
         (progn (worktree-assume-mode -1)
                (setq worktree-assume--entries nil)
                ,@body)
       (worktree-assume-mode -1)
       (setq worktree-assume--entries nil))))

(defun worktree-assume-test--root (dir)
  "Return the root of DIR's project as project.el finds it now, or nil."
  (when-let* ((project (project-current nil dir)))
    (project-root project)))

;;;; Listing the worktrees

(ert-deftest worktree-assume-worktrees-main-first ()
  "The worktrees of a repository come with the main one first, from any of them."
  (worktree-assume-test-with-repo (root nested second sibling)
    (dolist (dir (list root nested (expand-file-name "sub/" root)))
      (let ((worktrees (worktree-assume-worktrees dir)))
        (should (equal root (plist-get (car worktrees) :path)))
        (should (plist-get (car worktrees) :main))
        (should (equal "main" (plist-get (car worktrees) :branch)))
        (should (equal (sort (list root nested second sibling) #'string<)
                       (sort (mapcar (lambda (worktree) (plist-get worktree :path)) worktrees)
                             #'string<)))
        (should-not (cl-some (lambda (worktree) (plist-get worktree :main)) (cdr worktrees)))
        (let ((feature (cl-find nested worktrees :key (lambda (w) (plist-get w :path)) :test #'equal)))
          (should (equal "feature" (plist-get feature :branch)))
          (should (string-match-p "\\`[0-9a-f]\\{40\\}\\'" (plist-get feature :head))))))))

(ert-deftest worktree-assume-worktrees-flags ()
  "A detached, a locked and a missing worktree say so."
  (worktree-assume-test-with-repo (root _nested second sibling base)
    (let ((detached (expand-file-name "detached/" base)))
      (worktree-assume-test--git root "worktree" "add" "-q" "--detach" detached)
      (worktree-assume-test--git root "worktree" "lock" "--reason" "being used" second)
      (delete-directory sibling t)
      (let* ((worktrees (worktree-assume-worktrees root))
             (find (lambda (dir) (cl-find dir worktrees :key (lambda (w) (plist-get w :path))
                                          :test #'equal))))
        (should (plist-get (funcall find detached) :detached))
        (should-not (plist-get (funcall find detached) :branch))
        (should (equal "being used" (plist-get (funcall find second) :locked)))
        (should-not (plist-get (funcall find second) :prunable))
        ;; Older git does not say which worktrees are prunable.
        (when (version<= "2.31" (worktree-assume-test--git-version))
          (should (plist-get (funcall find sibling) :prunable)))))))

(ert-deftest worktree-assume-worktrees-with-names-git-quotes ()
  "A worktree whose name has a space, a quote or an accent is listed and assumed."
  (worktree-assume-test-with-repo (root _nested _second _sibling base)
    (dolist (name '("wt with spaces/" "wt \"quoted\"/" "wt é/" "wt \\back/"))
      (let ((dir (expand-file-name name base)))
        (worktree-assume-test--git root "worktree" "add" "-q" "-b" (md5 name) dir)
        (should (member dir (mapcar (lambda (worktree) (plist-get worktree :path))
                                    (worktree-assume-worktrees root))))
        (worktree-assume dir root)
        (should (equal dir (worktree-assume-test--root root)))
        (worktree-assume-reset root)))))

(ert-deftest worktree-assume-parse-worktrees-reads-the-null-separated-format ()
  "`git worktree list --porcelain -z' is read, a name with a newline in it too."
  (let ((worktrees (worktree-assume--parse-worktrees
                    (concat "worktree /srv/repo\0HEAD aaaa\0branch refs/heads/main\0\0"
                            "worktree /srv/new\nline\0HEAD bbbb\0branch refs/heads/a\0"
                            "locked in use\nby me\0\0"
                            "worktree /srv/\"quoted\"\0HEAD cccc\0detached\0\0"))))
    (should (equal '("/srv/repo/" "/srv/new\nline/" "/srv/\"quoted\"/")
                   (mapcar (lambda (worktree) (plist-get worktree :path)) worktrees)))
    (should (plist-get (car worktrees) :main))
    (should (equal "in use\nby me" (plist-get (nth 1 worktrees) :locked)))
    (should (plist-get (nth 2 worktrees) :detached))
    (should-not (worktree-assume--parse-worktrees "\0\0"))))

(ert-deftest worktree-assume-worktrees-with-a-newline-in-the-name ()
  "A worktree whose directory name has a newline is listed whole, as git has it."
  (skip-unless (version<= "2.36" (or (worktree-assume-test--git-version) "0")))
  (worktree-assume-test-with-repo (root _nested _second _sibling base)
    (let ((dir (expand-file-name "new\nline/" base)))
      (worktree-assume-test--git root "worktree" "add" "-q" "-b" "newline" dir)
      (should (member dir (mapcar (lambda (worktree) (plist-get worktree :path))
                                  (worktree-assume-worktrees root))))
      (worktree-assume dir root)
      (should (equal dir (worktree-assume-test--root root))))))

(ert-deftest worktree-assume-worktrees-without-the-null-separated-format ()
  "Where git does not know -z the listing is read all the same, and git is not asked twice."
  (worktree-assume-test-with-repo (root nested second sibling)
    (let ((calls nil)
          (worktree-assume--null-separated 'unknown)
          (real (symbol-function 'worktree-assume--git-list)))
      (cl-letf (((symbol-function 'worktree-assume--git-list)
                 (lambda (z)
                   (push z calls)
                   (if z (cons 129 "") (funcall real nil)))))
        (should (equal (sort (list root nested second sibling) #'string<)
                       (sort (mapcar (lambda (worktree) (plist-get worktree :path))
                                     (worktree-assume-worktrees root))
                             #'string<)))
        (should (equal '(nil t) calls))
        (should (eq 'no worktree-assume--null-separated))
        ;; Learnt: the second listing asks for the old format alone.
        (setq calls nil)
        (worktree-assume-worktrees root)
        (should (equal '(nil) calls))))))

(ert-deftest worktree-assume-annotation-has-room-for-a-short-head ()
  "A head that is shorter than a short hash is no trouble."
  (should (string-match-p "detached ab" (worktree-assume--annotation '(:detached t :head "ab"))))
  (should (string-match-p "detached" (worktree-assume--annotation '(:detached t)))))

(ert-deftest worktree-assume-worktrees-need-a-repository ()
  "Outside a git repository the worktrees cannot be listed."
  (let ((dir (file-name-as-directory (make-temp-file "worktree-assume-test" t))))
    (unwind-protect
        (should-error (worktree-assume-worktrees dir) :type 'user-error)
      (delete-directory dir t))))

(ert-deftest worktree-assume-unquote-reads-what-git-quotes ()
  "Quotes and escapes of a C string are undone, and plain text is left."
  (should (equal "/plain/path with space" (worktree-assume--unquote "/plain/path with space")))
  (should (equal "a\"b" (worktree-assume--unquote "\"a\\\"b\"")))
  (should (equal "a\\b" (worktree-assume--unquote "\"a\\\\b\"")))
  (should (equal "a\tb\nc" (worktree-assume--unquote "\"a\\tb\\nc\"")))
  (should (equal "café" (worktree-assume--unquote "\"caf\\303\\251\"")))
  (should (equal "café" (worktree-assume--unquote "\"café\""))))

(ert-deftest worktree-assume-parse-worktrees-reads-the-porcelain-format ()
  "Every kind of record of `git worktree list --porcelain' is read."
  (let ((worktrees (worktree-assume--parse-worktrees
                    (concat "worktree /srv/repo\nHEAD aaaa\nbranch refs/heads/main\n\n"
                            "worktree \"/srv/tab\\there\"\nHEAD bbbb\nbranch refs/heads/a/b\n"
                            "locked\n\n"
                            "worktree /srv/detached\nHEAD cccc\ndetached\n"
                            "locked in use by me\nprunable gitdir file points nowhere\n\n"))))
    (should (equal '("/srv/repo/" "/srv/tab\there/" "/srv/detached/")
                   (mapcar (lambda (worktree) (plist-get worktree :path)) worktrees)))
    (should (equal '(t nil nil) (mapcar (lambda (w) (plist-get w :main)) worktrees)))
    (should (equal "a/b" (plist-get (nth 1 worktrees) :branch)))
    (should (eq t (plist-get (nth 1 worktrees) :locked)))
    (should (plist-get (nth 2 worktrees) :detached))
    (should (equal "in use by me" (plist-get (nth 2 worktrees) :locked)))
    (should (equal "gitdir file points nowhere" (plist-get (nth 2 worktrees) :prunable)))
    (should (equal "bbbb" (plist-get (nth 1 worktrees) :head)))
    (let ((bare (worktree-assume--parse-worktrees "worktree /srv/bare.git\nbare\n\n")))
      (should (plist-get (car bare) :bare)))
    (should-not (worktree-assume--parse-worktrees ""))))

;;;; Assuming

(ert-deftest worktree-assume-makes-the-worktree-the-project ()
  "The project of every directory of the project is the worktree assumed."
  (worktree-assume-test-with-repo (root nested)
    (should (equal root (worktree-assume-test--root root)))
    (should-not (worktree-assume-assumed root))
    (should (equal (cons root nested) (worktree-assume nested root)))
    (dolist (dir (list root (expand-file-name "sub/" root) (directory-file-name root)))
      (should (equal nested (worktree-assume-test--root dir))))
    (should (equal nested (worktree-assume-assumed root)))
    (should (equal nested (worktree-assume-assumed (expand-file-name "sub/" root))))
    (should (equal (list (cons root nested)) (worktree-assume-assumptions)))
    ;; What the project's commands list is the worktree's.
    (let ((files (project-files (project-current nil root))))
      (should (member (expand-file-name "feature.txt" nested) files))
      (should (member (expand-file-name "README" nested) files))
      (should-not (member (expand-file-name "README" root) files)))
    (should (equal "feature" (file-name-nondirectory (directory-file-name
                                                      (project-root (project-current nil root))))))))

(ert-deftest worktree-assume-leaves-other-places-alone ()
  "Only the project assumed for changes: not the worktrees, not other projects."
  (worktree-assume-test-with-repo (root nested second sibling base)
    (worktree-assume nested root)
    (should (equal nested (worktree-assume-test--root (expand-file-name "sub/" nested))))
    (should (equal second (worktree-assume-test--root second)))
    (should (equal second (worktree-assume-test--root (expand-file-name "x/y" second))))
    (should (equal sibling (worktree-assume-test--root sibling)))
    (should-not (worktree-assume-test--root base))
    (let ((other (expand-file-name "other/" base)))
      (make-directory other)
      (worktree-assume-test--git other "init" "-q")
      (should (equal other (worktree-assume-test--root other))))
    ;; A directory below the worktrees' container is the project's.
    (should (equal nested (worktree-assume-test--root (expand-file-name ".worktrees/" root))))))

(ert-deftest worktree-assume-keeps-the-parent ()
  "The project assumed for is known from the worktree, and the worktree from it."
  (worktree-assume-test-with-repo (root nested second sibling)
    (should-not (worktree-assume-parent nested))
    (worktree-assume nested root)
    (should (equal root (worktree-assume-parent nested)))
    (should (equal root (worktree-assume-parent (expand-file-name "sub/deeper" nested))))
    (let ((default-directory nested))
      (should (equal root (worktree-assume-parent))))
    (should-not (worktree-assume-parent root))
    (should-not (worktree-assume-parent second))
    (should-not (worktree-assume-parent sibling))
    (should-not (worktree-assume-parent temporary-file-directory))
    (let ((default-directory root))
      (should (equal nested (worktree-assume-assumed))))
    (should-not (worktree-assume-assumed second))
    (should-not (worktree-assume-assumed sibling))))

(ert-deftest worktree-assume-the-parent-is-of-the-worktree-that-holds-the-directory ()
  "A worktree below an assumed one is no part of it: the main worktree holds the others."
  (worktree-assume-test-with-repo (root nested second sibling)
    ;; The main worktree, with `nested' and `second' below it, for `sibling'.
    (worktree-assume root sibling)
    (should (equal sibling (worktree-assume-parent root)))
    (should (equal sibling (worktree-assume-parent (expand-file-name "sub/" root))))
    (should (equal sibling (worktree-assume-parent (expand-file-name ".worktrees/" root))))
    (should-not (worktree-assume-parent nested))
    (should-not (worktree-assume-parent (expand-file-name "sub/deeper/" nested)))
    (should-not (worktree-assume-parent second))
    (should-not (worktree-assume-parent sibling))
    ;; So a reset from a worktree below it leaves the assumption alone.
    (should-not (worktree-assume-reset second))
    (should-not (worktree-assume-reset (expand-file-name "sub/" nested)))
    (should (worktree-assume-assumptions))
    (should (equal (list (cons sibling root)) (worktree-assume-reset (expand-file-name "sub/" root))))
    (should-not (worktree-assume-assumptions))))

(ert-deftest worktree-assume-a-submodule-is-part-of-its-worktree ()
  "A directory that has a .git file of its own, but not a worktree's, is in the worktree."
  (worktree-assume-test-with-repo (root nested _second sibling)
    (let ((submodule (expand-file-name "vendor/sub/" nested)))
      (make-directory submodule t)
      (worktree-assume-test--write (expand-file-name ".git" submodule)
                                   "gitdir: ../../.git/modules/sub\n")
      (worktree-assume nested root)
      (should (equal root (worktree-assume-parent submodule)))
      (should (equal root (worktree-assume-parent (expand-file-name "src/" submodule))))
      (ignore sibling))))

(ert-deftest worktree-assume-a-repository-with-a-git-directory-of-its-own-is-no-worktree ()
  "A git directory kept apart is no linked worktree's, whatever its parent is called."
  (worktree-assume-test-with-repo (root nested _second _sibling base)
    (let ((gitdir (expand-file-name "gitdirs/worktrees/sg/" base))
          (repo (expand-file-name "vendor/sg/" nested)))
      (make-directory (file-name-directory (directory-file-name gitdir)) t)
      (make-directory repo t)
      (worktree-assume-test--git base "init" "-q" "--separate-git-dir" (directory-file-name gitdir) repo)
      (should (string-match-p "worktrees/sg" (with-temp-buffer
                                              (insert-file-contents (expand-file-name ".git" repo))
                                              (buffer-string))))
      (should-not (worktree-assume--linked-worktree-p repo))
      (should (worktree-assume--linked-worktree-p nested))
      (should (worktree-assume--linked-worktree-p (expand-file-name ".worktrees/second/" root)))
      (worktree-assume nested root)
      (should (equal root (worktree-assume-parent (expand-file-name "src/" repo)))))))

(ert-deftest worktree-assume-says-when-git-cannot-be-run ()
  "A machine without git is told so, not that a directory is no repository."
  (let ((dir (file-name-as-directory (file-truename temporary-file-directory))))
    (cl-letf (((symbol-function 'process-file)
               (lambda (&rest _) (signal 'file-missing '("Searching for program" "git")))))
      (let ((worktree-assume--null-separated 'unknown))
        (let ((err (should-error (worktree-assume-worktrees dir) :type 'user-error)))
          (should (string-match-p "git cannot be run" (cadr err))))
        (should (eq 'unknown worktree-assume--null-separated))))))

(ert-deftest worktree-assume-a-failing-change-hook-breaks-nothing ()
  "An error in a function of the change hook leaves the assumptions as they were made.
The rest of the hook runs, the mode goes off whole, and nothing signals."
  (worktree-assume-test-with-repo (root nested second)
    (let ((heard nil)
          (messages nil))
      (add-hook 'worktree-assume-change-functions (lambda (&rest _) (error "Boom")))
      (add-hook 'worktree-assume-change-functions (lambda (parent assumed) (push (list parent assumed) heard)) t)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages))))
        (should (equal (cons root nested) (worktree-assume nested root)))
        (should (equal nested (worktree-assume-test--root root)))
        (should (equal (list (list root nested)) heard))
        (should (cl-some (lambda (text) (string-match-p "Boom" text)) messages))
        (should (equal (list (cons root second)) (progn (worktree-assume second root)
                                                        (worktree-assume-assumptions))))
        (should (equal (list (cons root second)) (worktree-assume-reset root)))
        (should (equal root (worktree-assume-test--root root)))
        (worktree-assume nested root)
        ;; Off: the finder and the advice go, and so do the assumptions.
        (worktree-assume-mode -1))
      (should-not worktree-assume--entries)
      (should-not (memq 'worktree-assume-project-find project-find-functions))
      (should (equal root (worktree-assume-test--root root)))
      (should (equal (list root nil) (car heard))))))

(ert-deftest worktree-assume-resetting-leaves-remote-names-alone ()
  "Asking what to reset for a remote directory touches no remote host."
  (worktree-assume-test-with-repo (root nested)
    (worktree-assume nested root)
    (let ((real (symbol-function 'file-truename)))
      (cl-letf (((symbol-function 'file-truename)
                 (lambda (name &rest args)
                   (if (file-remote-p name) (error "A remote name was looked at") (apply real name args)))))
        (should-not (worktree-assume-reset "/ssh:nowhere.invalid:/srv/repo/"))
        (should-not (worktree-assume--entries-for "/ssh:nowhere.invalid:/srv/repo/"))
        (should-not (worktree-assume--inside-p "/ssh:nowhere.invalid:/srv/repo/" nested))
        (let ((default-directory "/ssh:nowhere.invalid:/srv/repo/"))
          (should (equal root (worktree-assume--read-reset))))))
    (should (worktree-assume-assumptions))))

(ert-deftest worktree-assume-in-the-assumed-worktree-replaces-the-assumption ()
  "Assuming for a directory of an assumed worktree is assuming for its parent."
  (worktree-assume-test-with-repo (root nested second)
    (worktree-assume nested root)
    (should (equal (cons root second) (worktree-assume second (expand-file-name "sub/" nested))))
    (should (equal (list (cons root second)) (worktree-assume-assumptions)))
    (should (equal second (worktree-assume-test--root root)))
    (should (equal second (worktree-assume-assumed (expand-file-name "sub/" root))))))

(ert-deftest worktree-assume-with-parent-sees-the-real-project ()
  "Inside `worktree-assume-with-parent' the project is the parent, as it was."
  (worktree-assume-test-with-repo (root nested)
    (worktree-assume nested root)
    (should (equal root (worktree-assume-with-parent (worktree-assume-test--root root))))
    (should (equal root (worktree-assume-with-parent
                          (worktree-assume-test--root (expand-file-name "sub/" root)))))
    (should-not worktree-assume-inhibit)
    (should (equal nested (worktree-assume-test--root root)))
    ;; Nesting is no trouble, and neither is a non-local exit.
    (should (equal nested (worktree-assume-with-parent
                            (worktree-assume-test--root nested))))
    (ignore-errors (worktree-assume-with-parent (error "Oops")))
    (should (equal nested (worktree-assume-test--root root)))))

(ert-deftest worktree-assume-replaces-the-previous-assumption ()
  "Assuming another worktree for the same project replaces the first."
  (worktree-assume-test-with-repo (root nested second)
    (worktree-assume nested root)
    (worktree-assume second root)
    (should (equal (list (cons root second)) (worktree-assume-assumptions)))
    (should (equal second (worktree-assume-test--root root)))
    (should-not (worktree-assume-parent nested))
    (should (equal root (worktree-assume-parent second)))))

(ert-deftest worktree-assume-keeps-projects-apart ()
  "The assumption of one project does not touch another's."
  (worktree-assume-test-with-repo (root nested _second _sibling base)
    (let ((other (expand-file-name "other/" base))
          (other-worktree (expand-file-name "other-worktree/" base)))
      (make-directory other)
      (worktree-assume-test--git other "init" "-q")
      (worktree-assume-test--commit-file other "file" "x\n")
      (worktree-assume-test--git other "worktree" "add" "-q" "-b" "x" other-worktree)
      (worktree-assume nested root)
      (should (equal other (worktree-assume-test--root other)))
      (worktree-assume other-worktree other)
      (should (equal nested (worktree-assume-test--root root)))
      (should (equal other-worktree (worktree-assume-test--root other)))
      (should (equal 2 (length (worktree-assume-assumptions))))
      (worktree-assume-reset other)
      (should (equal nested (worktree-assume-test--root root)))
      (should (equal other (worktree-assume-test--root other))))))

(ert-deftest worktree-assume-from-a-linked-worktree ()
  "A linked worktree is a project too: another worktree can stand in for it."
  (worktree-assume-test-with-repo (root nested second)
    (worktree-assume second nested)
    (should (equal second (worktree-assume-test--root nested)))
    (should (equal root (worktree-assume-test--root root)))
    (should-not (worktree-assume-parent root))
    (should (equal nested (worktree-assume-parent second)))
    ;; The main worktree can stand in for it as well.
    (worktree-assume root nested)
    (should (equal root (worktree-assume-test--root nested)))))

(ert-deftest worktree-assume-refuses-what-is-not-another-worktree ()
  "Only the top directory of another worktree of the repository can be assumed."
  (worktree-assume-test-with-repo (root nested second sibling base)
    (dolist (not-a-worktree
             (list base (expand-file-name "sub/" nested) (expand-file-name "no-such/" base)
                   (expand-file-name ".worktrees/" root)))
      (should-error (worktree-assume not-a-worktree root) :type 'user-error))
    ;; The project's own worktree.
    (should-error (worktree-assume root root) :type 'user-error)
    (should-error (worktree-assume nested nested) :type 'user-error)
    (should-error (worktree-assume nested (expand-file-name "sub/" nested)) :type 'user-error)
    ;; A worktree of another repository.
    (let ((other (expand-file-name "other/" base)))
      (make-directory other)
      (worktree-assume-test--git other "init" "-q")
      (should-error (worktree-assume other root) :type 'user-error))
    ;; Whose directory is gone.
    (delete-directory sibling t)
    (should-error (worktree-assume sibling root) :type 'user-error)
    (should-not worktree-assume--entries)
    (should-not worktree-assume-mode)
    (ignore second)))

(ert-deftest worktree-assume-refuses-outside-a-git-project ()
  "A directory in no project, and a project that is not git's, cannot stand in."
  (worktree-assume-test-with-repo (_root nested _second _sibling base)
    (let ((plain (expand-file-name "plain/" base))
          (marked (expand-file-name "marked/" base))
          (project-vc-extra-root-markers '(".plain-project")))
      (make-directory plain)
      (worktree-assume-test--write (expand-file-name ".plain-project" marked) "")
      (should-not (worktree-assume-test--root plain))
      (should-error (worktree-assume nested plain) :type 'user-error)
      ;; A project, but not a repository.
      (should (equal marked (worktree-assume-test--root marked)))
      (should-error (worktree-assume nested marked) :type 'user-error)
      (should-not worktree-assume--entries)
      (should-not worktree-assume-mode))))

(ert-deftest worktree-assume-a-directory-of-the-repository-assumes-the-same-directory ()
  "A project that is a directory of its repository gets that directory of the worktree."
  (worktree-assume-test-with-repo (root nested _second _sibling)
    (worktree-assume-test--commit-file root "sub/.sub-project" "")
    (worktree-assume-test--git nested "merge" "-q" "main")
    (let ((project-vc-extra-root-markers '(".sub-project"))
          (sub (expand-file-name "sub/" root))
          (nested-sub (expand-file-name "sub/" nested)))
      (should (equal sub (worktree-assume-test--root (expand-file-name "x/" sub))))
      (should (equal (cons sub nested-sub) (worktree-assume nested sub)))
      (should (equal nested-sub (worktree-assume-test--root sub)))
      (should (equal nested-sub (worktree-assume-test--root (expand-file-name "x/" sub))))
      ;; The rest of the repository is another project, not assumed for.
      (should (equal root (worktree-assume-test--root root)))
      ;; The worktree is assumed for the directory, which is its parent.
      (should (equal sub (worktree-assume-parent nested)))
      (should (equal sub (worktree-assume-parent nested-sub)))
      (should-not (worktree-assume-parent root)))))

(ert-deftest worktree-assume-a-directory-the-project-finders-do-not-know ()
  "Where the worktree's directory is no project to the finders, it is one anyway."
  (worktree-assume-test-with-repo (root nested)
    (worktree-assume-test--commit-file root "sub/.sub-project" "")
    (let ((project-vc-extra-root-markers '(".sub-project"))
          (sub (expand-file-name "sub/" root))
          (nested-sub (expand-file-name "sub/" nested)))
      ;; The worktree is made before the marker, so it has none.
      (should (file-directory-p nested-sub))
      (should-not (file-exists-p (expand-file-name ".sub-project" nested-sub)))
      (worktree-assume nested sub)
      (should (equal nested-sub (worktree-assume-test--root sub)))
      (should (equal nested-sub (project-root (project-current nil (expand-file-name "x/" sub))))))))

(ert-deftest worktree-assume-follows-symbolic-links ()
  "A project spelled through a link is the project assumed for, and the other way."
  (worktree-assume-test-with-repo (root nested _second _sibling base)
    (let ((link (expand-file-name "link/" base)))
      (make-symbolic-link (directory-file-name root) (directory-file-name link))
      (should (equal link (worktree-assume-test--root (expand-file-name "sub/" link))))
      (worktree-assume nested link)
      (should (equal (list (cons link nested)) (worktree-assume-assumptions)))
      (should (equal nested (worktree-assume-test--root (expand-file-name "sub/" link))))
      (should (equal nested (worktree-assume-test--root root)))
      (should (equal nested (worktree-assume-assumed root)))
      (should (equal link (worktree-assume-parent nested)))
      (should (equal (list (cons link nested)) (worktree-assume-reset root)))
      (should-not (worktree-assume-assumptions))
      (should (equal root (worktree-assume-test--root root))))))

(ert-deftest worktree-assume-forgets-a-worktree-that-is-gone ()
  "An assumed worktree whose directory goes is forgotten, and the project is its own."
  (worktree-assume-test-with-repo (root nested)
    (let ((changes nil))
      (add-hook 'worktree-assume-change-functions
                (lambda (parent assumed) (push (list parent assumed) changes)))
      (worktree-assume nested root)
      (should (equal (list (list root nested)) changes))
      (delete-directory nested t)
      (should (equal root (worktree-assume-test--root root)))
      (should-not (worktree-assume-assumptions))
      (should-not (worktree-assume-assumed root))
      ;; The word of it comes when Emacs is idle.
      (let ((messages nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (format &rest args) (push (apply #'format format args) messages))))
          (sit-for 0.1))
        (should (equal (list root nil) (car changes)))
        (should (string-match-p "feature is gone" (car messages)))))))

(ert-deftest worktree-assume-says-what-is-gone ()
  "The word of a forgotten assumption names what went: the worktree, or its directory."
  (worktree-assume-test-with-repo (root nested _second _sibling)
    (worktree-assume-test--commit-file root "sub/.sub-project" "")
    (worktree-assume-test--git nested "merge" "-q" "main")
    (let ((project-vc-extra-root-markers '(".sub-project"))
          (sub (expand-file-name "sub/" root))
          (messages nil))
      (worktree-assume nested sub)
      (delete-directory (expand-file-name "sub/" nested) t)
      (should (equal sub (worktree-assume-test--root sub)))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages))))
        (sit-for 0.1))
      (should (= 1 (length messages)))
      (should (string-match-p "feature has no sub" (car messages)))
      (should-not (string-match-p "is gone" (car messages))))))

(ert-deftest worktree-assume-assumptions-leave-out-a-worktree-that-is-gone ()
  "Asking what is assumed forgets a worktree whose directory went, as a lookup does."
  (worktree-assume-test-with-repo (root nested second)
    (worktree-assume nested root)
    (should (equal (list (cons root nested)) (worktree-assume-assumptions)))
    (delete-directory nested t)
    (should-not (worktree-assume-assumptions))
    (should-not worktree-assume--entries)
    (should (equal root (worktree-assume-test--root root)))
    (ignore second)))

;;;; Resetting

(ert-deftest worktree-assume-reset-goes-back ()
  "Reset makes the project its own worktree again."
  (worktree-assume-test-with-repo (root nested)
    (worktree-assume nested root)
    (should (equal (list (cons root nested)) (worktree-assume-reset root)))
    (should (equal root (worktree-assume-test--root root)))
    (should (equal root (worktree-assume-test--root (expand-file-name "sub/" root))))
    (should-not (worktree-assume-assumptions))
    (should-not (worktree-assume-assumed root))
    (should-not (worktree-assume-parent nested))
    ;; Nothing left to reset.
    (should-not (worktree-assume-reset root))
    (should-not (worktree-assume-reset))))

(ert-deftest worktree-assume-reset-from-inside-the-worktree ()
  "Reset from a directory of the assumed worktree resets the project's assumption."
  (worktree-assume-test-with-repo (root nested second)
    (worktree-assume nested root)
    (should-not (worktree-assume-reset second))
    (should (worktree-assume-assumptions))
    (let ((default-directory (expand-file-name "sub/" nested)))
      (should (equal (list (cons root nested)) (worktree-assume-reset))))
    (should-not (worktree-assume-assumptions))
    (should (equal root (worktree-assume-test--root root)))))

(ert-deftest worktree-assume-reset-all ()
  "Reset `all' resets every assumption."
  (worktree-assume-test-with-repo (root nested _second _sibling base)
    (let ((other (expand-file-name "other/" base))
          (other-worktree (expand-file-name "other-worktree/" base)))
      (make-directory other)
      (worktree-assume-test--git other "init" "-q")
      (worktree-assume-test--commit-file other "file" "x\n")
      (worktree-assume-test--git other "worktree" "add" "-q" "-b" "x" other-worktree)
      (worktree-assume nested root)
      (worktree-assume other-worktree other)
      (should (equal 2 (length (worktree-assume-reset 'all))))
      (should-not (worktree-assume-assumptions))
      (should (equal root (worktree-assume-test--root root)))
      (should (equal other (worktree-assume-test--root other))))))

(ert-deftest worktree-assume-reset-asks-what-to-reset-when-it-must ()
  "Interactively, reset takes this buffer's project, the only assumption, or asks."
  (worktree-assume-test-with-repo (root nested _second _sibling base)
    (should-error (worktree-assume--read-reset) :type 'user-error)
    (worktree-assume nested root)
    (let ((default-directory root))
      (should (equal root (worktree-assume--read-reset)))
      (let ((current-prefix-arg '(4)))
        (should (eq 'all (worktree-assume--read-reset)))))
    ;; Elsewhere, the only assumption there is.
    (let ((default-directory base))
      (should (equal root (worktree-assume--read-reset))))
    (let ((other (expand-file-name "other/" base))
          (other-worktree (expand-file-name "other-worktree/" base))
          (asked nil))
      (make-directory other)
      (worktree-assume-test--git other "init" "-q")
      (worktree-assume-test--commit-file other "file" "x\n")
      (worktree-assume-test--git other "worktree" "add" "-q" "-b" "x" other-worktree)
      (worktree-assume other-worktree other)
      ;; With two, and none of this buffer's, it asks.
      (let ((default-directory base))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (_prompt names &rest _)
                     (setq asked (mapcar #'car names))
                     (car (nth 1 names)))))
          (should (member (worktree-assume--read-reset) (list root other)))
          (should (equal 2 (length asked)))
          (should (cl-some (lambda (name) (string-match-p "other-worktree" name)) asked))
          (should (cl-some (lambda (name) (string-match-p "feature" name)) asked))))
      ;; A buffer of one of them resets that one without asking.
      (let ((default-directory other))
        (should (equal other (worktree-assume--read-reset)))))))

;;;; The mode

(ert-deftest worktree-assume-mode-puts-the-finder-first ()
  "The mode adds its finder ahead of the others, and takes it away."
  (worktree-assume-test-with-repo (root nested)
    (should-not (memq 'worktree-assume-project-find project-find-functions))
    (worktree-assume-mode 1)
    (should (eq 'worktree-assume-project-find (car project-find-functions)))
    (should (memq 'project-try-vc project-find-functions))
    (worktree-assume-mode 1)
    (should (equal 1 (cl-count 'worktree-assume-project-find project-find-functions)))
    (worktree-assume-mode -1)
    (should-not (memq 'worktree-assume-project-find project-find-functions))
    ;; Assuming turns it on by itself.
    (worktree-assume nested root)
    (should worktree-assume-mode)
    (should (eq 'worktree-assume-project-find (car project-find-functions)))))

(ert-deftest worktree-assume-mode-off-resets-everything ()
  "Turning the mode off ends the assumptions."
  (worktree-assume-test-with-repo (root nested)
    (worktree-assume nested root)
    (should (equal nested (worktree-assume-test--root root)))
    (let ((changes nil))
      (add-hook 'worktree-assume-change-functions
                (lambda (parent assumed) (push (list parent assumed) changes)))
      (worktree-assume-mode -1)
      (should (equal (list (list root nil)) changes)))
    (should-not (worktree-assume-assumptions))
    (should (equal root (worktree-assume-test--root root)))))

(ert-deftest worktree-assume-says-when-the-assumptions-change ()
  "The change functions hear of each assumption and each reset."
  (worktree-assume-test-with-repo (root nested second)
    (let ((changes nil))
      (add-hook 'worktree-assume-change-functions
                (lambda (parent assumed) (push (list parent assumed) changes)))
      (worktree-assume nested root)
      (worktree-assume second root)
      (worktree-assume-reset root)
      (worktree-assume-reset root)
      (should (equal (list (list root nil) (list root second) (list root nested))
                     changes)))))

(ert-deftest worktree-assume-the-finder-never-breaks-the-lookup ()
  "A fault in the finder gives no project, and not an error."
  (worktree-assume-test-with-repo (root nested)
    (worktree-assume nested root)
    (cl-letf (((symbol-function 'worktree-assume--entry-for-root)
               (lambda (&rest _) (error "Broken"))))
      (should-not (worktree-assume-project-find root))
      (should (equal root (worktree-assume-test--root root))))))

(ert-deftest worktree-assume-leaves-remote-directories-alone ()
  "A remote directory is no business of the finder."
  (worktree-assume-test-with-repo (root nested)
    (worktree-assume nested root)
    (should-not (worktree-assume-project-find "/ssh:nowhere.invalid:/srv/repo/"))
    (should-not (worktree-assume-parent "/ssh:nowhere.invalid:/srv/repo/"))
    (should-not (worktree-assume-assumed "/ssh:nowhere.invalid:/srv/repo/"))
    (should (equal "/ssh:nowhere.invalid:/srv/repo/"
                   (worktree-assume--projectile-root "/ssh:nowhere.invalid:/srv/repo/")))
    (should-error (worktree-assume nested "/ssh:nowhere.invalid:/srv/repo/") :type 'user-error)))

;;;; Projectile

(defmacro worktree-assume-test--with-projectile (&rest body)
  "Run BODY with a stand-in for `projectile-project-root', as projectile finds roots.
The stand-in looks projects up as project.el does, without an assumption."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (defalias 'projectile-project-root
           (lambda (&optional dir)
             (worktree-assume-with-parent
               (when-let* ((project (project-current nil (or dir default-directory))))
                 (project-root project)))))
         ,@body)
     (advice-remove 'projectile-project-root #'worktree-assume--projectile-root)
     (fmakunbound 'projectile-project-root)))

(ert-deftest worktree-assume-projectile-finds-the-worktree ()
  "While the mode is on, projectile's root of the project is the worktree's."
  (worktree-assume-test--with-projectile
    (worktree-assume-test-with-repo (root nested second)
      (worktree-assume-mode 1)
      (should (equal root (projectile-project-root root)))
      (worktree-assume nested root)
      (should (equal nested (projectile-project-root root)))
      (should (equal nested (projectile-project-root (expand-file-name "sub/" root))))
      (should (equal nested (let ((default-directory root)) (projectile-project-root))))
      (should (equal nested (projectile-project-root nested)))
      (should (equal second (projectile-project-root second)))
      (should (equal root (worktree-assume-with-parent (projectile-project-root root))))
      (worktree-assume-reset root)
      (should (equal root (projectile-project-root root)))
      (worktree-assume-mode -1)
      (should-not (advice-member-p #'worktree-assume--projectile-root 'projectile-project-root)))))

(ert-deftest worktree-assume-projectile-is-no-business-of-the-mode-when-off ()
  "Projectile is left alone while the mode is off, and with no project."
  (worktree-assume-test--with-projectile
    (worktree-assume-test-with-repo (root nested _second _sibling base)
      (should-not (advice-member-p #'worktree-assume--projectile-root 'projectile-project-root))
      (worktree-assume nested root)
      (should (advice-member-p #'worktree-assume--projectile-root 'projectile-project-root))
      (should-not (projectile-project-root base))
      (worktree-assume-mode -1)
      (should (equal root (projectile-project-root root))))))

;;;; Choosing

(ert-deftest worktree-assume-reads-one-of-the-other-worktrees ()
  "Interactively the worktree is read among the others, named below the main one."
  (worktree-assume-test-with-repo (root nested second sibling)
    (let ((offered nil)
          (annotations nil)
          (prompt nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (text table &rest _)
                   (setq prompt text)
                   (setq offered (all-completions "" table))
                   (let ((annotate (cdr (assq 'annotation-function (cdr (funcall table "" nil 'metadata))))))
                     (setq annotations (mapcar annotate offered)))
                   ".worktrees/feature")))
        (let ((args (let ((default-directory (expand-file-name "sub/" root)))
                      (worktree-assume--read-arguments))))
          (should (equal (list nested root) args))))
      (should (string-match-p "repo" prompt))
      ;; Not the project's own worktree, and the nearer ones named short.
      (should (equal (sort (list ".worktrees/feature" ".worktrees/second"
                                 (abbreviate-file-name (directory-file-name sibling)))
                           #'string<)
                     (sort (copy-sequence offered) #'string<)))
      (should (cl-some (lambda (text) (string-match-p "feature" text)) annotations))
      (should (cl-some (lambda (text) (string-match-p "other" text)) annotations))
      (ignore second))))

(ert-deftest worktree-assume-reads-from-a-linked-worktree-too ()
  "From a linked worktree the main one is offered, not the worktree itself."
  (worktree-assume-test-with-repo (root nested second sibling)
    (let ((offered nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_text table &rest _)
                   (setq offered (all-completions "" table))
                   (car offered))))
        (let ((default-directory nested))
          ;; The project the worktree stands in for is the linked worktree.
          (should (equal (list root nested) (worktree-assume--read-arguments))))
        (should (equal (sort (list (abbreviate-file-name (directory-file-name root))
                                   ".worktrees/second"
                                   (abbreviate-file-name (directory-file-name sibling)))
                             #'string<)
                       (sort (copy-sequence offered) #'string<)))
        (ignore second)))))

(ert-deftest worktree-assume-in-the-worktree-chooses-for-the-project-it-stands-in-for ()
  "From a buffer of the assumed worktree, another worktree replaces the assumed one."
  (worktree-assume-test-with-repo (root nested second sibling)
    (worktree-assume nested root)
    (let ((offered nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_text table &rest _)
                   (setq offered (all-completions "" table))
                   ".worktrees/second")))
        (let ((default-directory (expand-file-name "sub/" nested)))
          ;; The project is the parent, not the worktree it is in.
          (should (equal (list second root) (worktree-assume--read-arguments)))
          (call-interactively #'worktree-assume)))
      ;; Everything but the project's own worktree, the assumed one too.
      (should (equal (sort (list ".worktrees/feature" ".worktrees/second"
                                 (abbreviate-file-name (directory-file-name sibling)))
                           #'string<)
                     (sort (copy-sequence offered) #'string<))))
    (should (equal (list (cons root second)) (worktree-assume-assumptions)))
    (should (equal second (worktree-assume-test--root root)))
    (should (equal root (worktree-assume-parent second)))
    (should-not (worktree-assume-parent nested))))

(ert-deftest worktree-assume-is-a-command ()
  "Called interactively, it reads a worktree and assumes it."
  (worktree-assume-test-with-repo (root nested)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) ".worktrees/feature")))
      (let ((default-directory root))
        (call-interactively #'worktree-assume)))
    (should (equal nested (worktree-assume-test--root root)))
    (let ((default-directory root))
      (call-interactively #'worktree-assume-reset))
    (should (equal root (worktree-assume-test--root root)))))

(ert-deftest worktree-assume-has-nothing-to-read-without-another-worktree ()
  "A repository with one worktree has nothing to assume, and a directory no repository."
  (let ((dir (file-name-as-directory (file-truename (make-temp-file "worktree-assume-test" t)))))
    (unwind-protect
        (let ((process-environment (cons (concat "HOME=" dir) process-environment))
              (default-directory dir))
          (should-error (worktree-assume--read-arguments) :type 'user-error)
          (worktree-assume-test--git dir "init" "-q")
          (should-error (worktree-assume--read-arguments) :type 'user-error)
          (worktree-assume-test--git dir "commit" "-q" "--allow-empty" "-m" "x")
          (should-error (worktree-assume--read-arguments) :type 'user-error))
      (delete-directory dir t))))

;;;; The mode line

(ert-deftest worktree-assume-shows-in-the-mode-line ()
  "The mode line names the worktree assumed, or counts them."
  (worktree-assume-test-with-repo (root nested second _sibling base)
    (should-not (worktree-assume--lighter))
    (worktree-assume nested root)
    (let ((text (worktree-assume--lighter)))
      (should (equal " ⇒feature" (substring-no-properties text)))
      (should (eq 'worktree-assume-lighter (get-text-property 1 'face text)))
      (let ((help (funcall (get-text-property 1 'help-echo text))))
        (should (string-match-p "repo/ ⇒ .*feature/" help))))
    (let ((worktree-assume-lighter-width 4))
      (should (equal " ⇒fea…" (substring-no-properties (worktree-assume--lighter)))))
    (let ((worktree-assume-lighter "[%s]"))
      (should (equal "[feature]" (substring-no-properties (worktree-assume--lighter)))))
    (let ((other (expand-file-name "other/" base))
          (other-worktree (expand-file-name "other-worktree/" base)))
      (make-directory other)
      (worktree-assume-test--git other "init" "-q")
      (worktree-assume-test--commit-file other "file" "x\n")
      (worktree-assume-test--git other "worktree" "add" "-q" "-b" "x" other-worktree)
      (worktree-assume other-worktree other)
      (should (equal " ⇒2" (substring-no-properties (worktree-assume--lighter)))))
    (worktree-assume-reset 'all)
    (should-not (worktree-assume--lighter))
    (ignore second)))

(ert-deftest worktree-assume-the-minor-mode-has-the-lighter ()
  "The lighter is the mode's own, so the list of minor modes shows it."
  (worktree-assume-test-with-repo (root nested)
    (let* ((entry (assq 'worktree-assume-mode minor-mode-alist))
           ;; A batch Emacs cannot format a mode line: take the form.
           (lighter (lambda () (eval (cadr (cadr entry)) t))))
      (should entry)
      (should (eq :eval (car (cadr entry))))
      (should-not (funcall lighter))
      (worktree-assume nested root)
      (should (equal " ⇒feature" (substring-no-properties (funcall lighter)))))))

(ert-deftest worktree-assume-status-tells-the-assumptions ()
  "The status says which worktrees are assumed for which projects."
  (worktree-assume-test-with-repo (root nested)
    (let ((said nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (setq said (apply #'format format args)))))
        (worktree-assume-status)
        (should (equal "No worktree is assumed" said))
        (worktree-assume nested root)
        (worktree-assume-status)
        (should (string-match-p "\\`Assumed: .*repo/ ⇒ .*feature/\\'" said))))))

(provide 'worktree-assume-test)

;;; worktree-assume-test.el ends here
