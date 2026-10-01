;;; harness-worktree.el --- Git worktree management  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sessions can live in a git worktree so parallel agents never step on
;; each other's working copy.  This module wraps the handful of git
;; commands that manage worktrees.  Every method is asynchronous: git
;; runs through `harness-run-command' and the method returns a promise
;; that resolves with parsed output or rejects with git's stderr.
;;
;; Nothing here touches sessions; the session module gives a session
;; created with `:worktree PATH' that path as its cwd, and the merge
;; module merges a worktree's branch back into its parent's cwd.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-project)

;;;; Customisation

(defcustom harness-worktree-git-program "git"
  "Name of the git executable used for worktree operations."
  :type 'string :group 'harness)

(defcustom harness-worktree-directory-function #'harness-worktree-default-directory
  "Function returning the directory for a new worktree.
Called with the repository ROOT and the BRANCH name; must return an
absolute path that does not exist yet."
  :type 'function :group 'harness)

(defcustom harness-worktree-branch-prefix "harness/"
  "Prefix of branch names generated for new worktrees."
  :type 'string :group 'harness)

(defcustom harness-worktree-subdirectory ".worktrees"
  "Directory inside the repository root that holds default worktrees.
`worktree/create' writes a `.gitignore' of `*' into it so the main
checkout's status stays clean."
  :type 'string :group 'harness)

(defun harness-worktree-default-directory (root branch)
  "Return ROOT/.worktrees/BRANCH with slashes in BRANCH replaced.
The parent directory is `harness-worktree-subdirectory'."
  (let ((leaf (replace-regexp-in-string "/" "-" branch)))
    (expand-file-name leaf (expand-file-name harness-worktree-subdirectory root))))

(defun harness-worktree--ignore-container (root path)
  "Keep the directory holding worktree PATH out of ROOT's git status.
When PATH's parent is strictly inside ROOT, write a `.gitignore' of
`*' there unless one exists."
  (let* ((parent (file-name-directory (directory-file-name path)))
         (ignore (expand-file-name ".gitignore" parent)))
    (when (and (file-in-directory-p parent root)
               (not (harness-worktree--same-path-p parent root))
               (not (file-exists-p ignore)))
      (harness-write-file-atomically ignore "*\n"))))

;;;; Running git

(defun harness-worktree--error (args result)
  "Return the error data for a failed git invocation of ARGS with RESULT."
  (let* ((stderr (string-trim (or (plist-get result :stderr) "")))
         (exit (plist-get result :exit))
         (message (cond ((not (string-empty-p stderr)) stderr)
                        ((eq exit 'timeout) (format "git %s timed out" (car args)))
                        (t (format "git %s exited with status %s"
                                   (string-join args " ") exit)))))
    (list 'harness-error message)))

(defun harness-worktree--git (cwd &rest args)
  "Run git with ARGS in CWD; return a promise of its standard output.
The promise rejects with `harness-error' carrying git's stderr when
the command fails."
  (let ((cwd (file-name-as-directory (expand-file-name cwd))))
    (harness-then
     (harness-run-command (cons harness-worktree-git-program args) :cwd cwd
                          :name "harness-git")
     (lambda (result)
       (if (eql (plist-get result :exit) 0)
           (plist-get result :stdout)
         (signal 'harness-error (cdr (harness-worktree--error args result))))))))

(defun harness-worktree--git-trimmed (cwd &rest args)
  "Run git with ARGS in CWD; return a promise of the trimmed output."
  (harness-then (apply #'harness-worktree--git cwd args) #'string-trim))

;;;; Parsing

(defun harness-worktree--parse-list (output)
  "Parse the porcelain OUTPUT of `git worktree list' into worktree plists."
  (let ((entries (split-string output "\n\n" t))
        (first t)
        out)
    (dolist (entry entries)
      (let ((wt (list :path nil :branch nil :head nil :bare nil
                      :detached nil :locked nil :main nil)))
        (dolist (line (split-string entry "\n" t))
          (cond
           ((string-prefix-p "worktree " line)
            (setq wt (plist-put wt :path (file-name-as-directory (substring line 9)))))
           ((string-prefix-p "HEAD " line)
            (setq wt (plist-put wt :head (substring line 5))))
           ((string-prefix-p "branch " line)
            (setq wt (plist-put wt :branch (string-remove-prefix "refs/heads/" (substring line 7)))))
           ((string= line "bare") (setq wt (plist-put wt :bare t)))
           ((string= line "detached") (setq wt (plist-put wt :detached t)))
           ((string-prefix-p "locked" line) (setq wt (plist-put wt :locked t)))
           ((string-prefix-p "prunable" line) (setq wt (plist-put wt :prunable t)))))
        (when (plist-get wt :path)
          (when first (setq wt (plist-put wt :main t) first nil))
          (push wt out))))
    (nreverse out)))

(defun harness-worktree--parse-status (output)
  "Parse `git status --porcelain=v2 --branch' OUTPUT.
Return (:dirty BOOL :ahead N :behind N :branch NAME-OR-NIL)."
  (let ((dirty nil) (ahead 0) (behind 0) (branch nil))
    (dolist (line (split-string output "\n" t))
      (cond
       ((string-match "\\`# branch\\.ab \\+\\([0-9]+\\) -\\([0-9]+\\)" line)
        (setq ahead (string-to-number (match-string 1 line))
              behind (string-to-number (match-string 2 line))))
       ((string-match "\\`# branch\\.head \\(.*\\)\\'" line)
        (let ((name (match-string 1 line)))
          (setq branch (unless (string= name "(detached)") name))))
       ((string-prefix-p "#" line) nil)
       (t (setq dirty t))))
    (list :dirty dirty :ahead ahead :behind behind :branch branch)))

(defun harness-worktree--same-path-p (a b)
  "Non-nil when directory names A and B refer to the same place."
  (string= (file-name-as-directory (harness-path-normalize a))
           (file-name-as-directory (harness-path-normalize b))))

;;;; Methods

(harness-defmethod worktree/list (root)
  "Return a promise of the worktrees of the repository at ROOT.
Each is (:path :branch :head :bare BOOL :detached BOOL :locked BOOL
:main BOOL); the main worktree comes first."
  (harness-then (harness-worktree--git root "worktree" "list" "--porcelain")
                #'harness-worktree--parse-list))

(defun harness-worktree--branch-exists-p (root branch)
  "Return a promise of non-nil when BRANCH exists in the repository at ROOT."
  (harness-then
   (harness-run-command (list harness-worktree-git-program "rev-parse" "--verify" "--quiet"
                              (concat "refs/heads/" branch))
                        :cwd root :name "harness-git")
   (lambda (result) (eql (plist-get result :exit) 0))))

(defun harness-worktree--find (root path)
  "Return a promise of the worktree plist for PATH in the repository at ROOT."
  (harness-then
   (harness-call 'worktree/list root)
   (lambda (worktrees)
     (or (cl-find-if (lambda (wt) (harness-worktree--same-path-p (plist-get wt :path) path))
                     worktrees)
         (list :path (file-name-as-directory (expand-file-name path)))))))

(harness-defmethod worktree/create (root &rest opts)
  "Create a worktree of the repository at ROOT; return a promise of its plist.
OPTS: `:branch' (default a fresh `harness-worktree-branch-prefix' name),
`:path' (default from `harness-worktree-directory-function') and `:base'
(default HEAD).  A branch that already exists is checked out as is;
otherwise it is created from `:base'.  Emits `worktree/created'."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (branch (or (plist-get opts :branch)
                     (concat harness-worktree-branch-prefix (harness-short-id))))
         (path (expand-file-name (or (plist-get opts :path)
                                     (funcall harness-worktree-directory-function root branch))))
         (base (or (plist-get opts :base) "HEAD")))
    (harness-then
     (harness-worktree--branch-exists-p root branch)
     (lambda (exists)
       (harness-ensure-directory (file-name-directory (directory-file-name path)))
       (harness-worktree--ignore-container root path)
       (harness-then
        (if exists
            (harness-worktree--git root "worktree" "add" path branch)
          (harness-worktree--git root "worktree" "add" "-b" branch path base))
        (lambda (_)
          (harness-then
           (harness-worktree--find root path)
           (lambda (wt)
             (harness-emit 'worktree/created root wt)
             wt))))))))

(harness-defmethod worktree/remove (root path &optional force)
  "Remove the worktree at PATH from the repository at ROOT.
With FORCE, remove it even when it has local changes.  Return a
promise of PATH.  Emits `worktree/removed'."
  (let ((path (file-name-as-directory (expand-file-name path))))
    (harness-then
     (apply #'harness-worktree--git root
            (append (list "worktree" "remove") (and force (list "--force")) (list path)))
     (lambda (_)
       (harness-emit 'worktree/removed root path)
       path))))

(harness-defmethod worktree/prune (root)
  "Prune stale worktree records of the repository at ROOT.
Return a promise of the lines git printed about what it removed."
  (let ((args (list "worktree" "prune" "-v")))
    (harness-then
     (harness-run-command (cons harness-worktree-git-program args)
                          :cwd (file-name-as-directory (expand-file-name root))
                          :name "harness-git")
     (lambda (result)
       (if (eql (plist-get result :exit) 0)
           ;; git reports what it pruned on stderr.
           (split-string (concat (plist-get result :stdout) "\n" (plist-get result :stderr)) "\n" t)
         (signal 'harness-error (cdr (harness-worktree--error args result))))))))

(harness-defmethod worktree/root-of (path)
  "Return a promise of the main repository root for PATH.
PATH may be inside any worktree of the repository (or a file in it)."
  (let ((dir (if (file-directory-p path)
                 (file-name-as-directory (expand-file-name path))
               (file-name-directory (expand-file-name path)))))
    (harness-then
     (harness-worktree--git-trimmed dir "rev-parse" "--git-common-dir")
     (lambda (common)
       (let ((common (directory-file-name (expand-file-name common dir))))
         (file-name-as-directory
          (harness-path-normalize
           (if (string= (file-name-nondirectory common) ".git")
               (file-name-directory common)
             common))))))))

(harness-defmethod worktree/branch (path)
  "Return a promise of the branch checked out at PATH, or nil when detached."
  (harness-then (harness-worktree--git-trimmed path "branch" "--show-current")
                (lambda (name) (unless (string-empty-p name) name))))

(harness-defmethod worktree/status (path)
  "Return a promise of (:dirty BOOL :ahead N :behind N :branch NAME) for PATH.
Ahead and behind count commits relative to the upstream, 0 without one."
  (harness-then (harness-worktree--git path "status" "--porcelain=v2" "--branch")
                #'harness-worktree--parse-status))

(harness-declare-event 'worktree/created "(ROOT WORKTREE) after a worktree was added.")
(harness-declare-event 'worktree/removed "(ROOT PATH) after a worktree was removed.")

(harness-define-module 'worktree
  :doc "Git worktree listing, creation, removal and status."
  :requires '(project))

(provide 'harness-worktree)
;;; harness-worktree.el ends here
