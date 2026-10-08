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
;;
;; Locks.  Every worktree the harness creates is locked (`git worktree
;; add --lock'), its lock reason starting with
;; `harness-worktree-lock-prefix'.  git never prunes a locked worktree,
;; and that matters because agents run git in a sandbox that shows only
;; their own worktree: a `git worktree prune' there takes every other
;; worktree for deleted and drops its registration, leaving its files
;; without an index and every git command in it failing.  The merge
;; module lifts the lock once the branch is merged (`worktree/unlock'),
;; so merged worktrees can be pruned again; `worktree/remove' lifts the
;; harness's lock itself.  Worktrees made before the harness locked them
;; are locked once per repository when the harness starts
;; (`worktree/lock-existing').  Locks with another reason belong to
;; someone else and are left alone.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-project)

;;;; Customisation

(defcustom harness-worktree-directory-function #'harness-worktree-default-directory
  "Function returning the directory for a new worktree.
Called with the repository ROOT and the BRANCH name; must return an
absolute path that does not exist yet."
  :type 'function :group 'harness)

(defcustom harness-worktree-branch-prefix "harness/"
  "Prefix of branch names generated for new worktrees."
  :type 'string :group 'harness)

(defconst harness-worktree--subdirectory ".worktrees"
  "Directory inside the repository root that holds default worktrees.
`worktree/create' writes a `.gitignore' of `*' into it so the main
checkout's status stays clean.")

(defconst harness-worktree-lock-prefix "harness: "
  "Start of the reason of every lock the harness puts on a worktree.
The branch follows it.  A lock with another reason is not the
harness's: it unlocks only its own.")

(defconst harness-worktree--locked-roots-file "worktree-locks.json"
  "File in `harness-state-directory' naming the repositories already locked.
Those are the repositories whose existing worktrees
`harness-worktree--lock-known' locked, which it does once per repository.")

(defvar harness-state-directory)

(defun harness-worktree-default-directory (root branch)
  "Return ROOT/.worktrees/BRANCH with slashes in BRANCH replaced.
The parent directory is `harness-worktree--subdirectory'."
  (let ((leaf (replace-regexp-in-string "/" "-" branch)))
    (expand-file-name leaf (expand-file-name harness-worktree--subdirectory root))))

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
     (harness-run-command (cons "git" args) :cwd cwd
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
           ((string-prefix-p "locked" line)
            (setq wt (plist-put wt :locked t))
            (when (string-prefix-p "locked " line)
              (setq wt (plist-put wt :lock-reason (harness-worktree--unquote (substring line 7))))))
           ((string-prefix-p "prunable" line) (setq wt (plist-put wt :prunable t)))))
        (when (plist-get wt :path)
          (when first (setq wt (plist-put wt :main t) first nil))
          (push wt out))))
    (nreverse out)))

(defun harness-worktree--unquote (text)
  "Return TEXT, a value git may have quoted C-style, unquoted.
git quotes a lock reason with special characters (non-ASCII ones
included) like a C string of UTF-8 bytes."
  (if (and (string-prefix-p "\"" text) (string-suffix-p "\"" text) (> (length text) 1))
      (condition-case nil
          (decode-coding-string (string-to-unibyte (read text)) 'utf-8)
        (error text))
    text))

(defun harness-worktree-harness-lock-p (wt)
  "Non-nil when the worktree plist WT carries a lock the harness made."
  (let ((reason (plist-get wt :lock-reason)))
    (and (harness-json-true-p (plist-get wt :locked))
         (stringp reason)
         (string-prefix-p harness-worktree-lock-prefix reason))))

(defun harness-worktree--lock-reason (branch)
  "Return the reason of the harness's lock on a worktree of BRANCH."
  (concat harness-worktree-lock-prefix (or branch "detached HEAD")))

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

(defun harness-worktree--inside-p (dir path)
  "Non-nil when PATH lies strictly inside directory DIR."
  (and (harness-path-within-p dir path)
       (not (harness-worktree--same-path-p dir path))))

(defun harness-worktree--mark-missing (root worktrees)
  "Mark the WORKTREES of a local ROOT whose directory is gone with `:missing'.
git flags such a worktree `prunable' only when it is not locked."
  (unless (file-remote-p root)
    (dolist (wt worktrees)
      (unless (or (plist-get wt :bare) (file-directory-p (plist-get wt :path)))
        (plist-put wt :missing t))))
  worktrees)

(harness-defmethod worktree/list (root)
  "Return a promise of the worktrees of the repository at ROOT.
Each is (:path :branch :head :bare BOOL :detached BOOL :locked BOOL
:main BOOL), plus `:lock-reason' when a locked one has a reason,
`:prunable' when git would prune it and `:missing' when its directory
is gone; the main worktree comes first."
  (harness-then (harness-worktree--git root "worktree" "list" "--porcelain")
                (lambda (output)
                  (harness-worktree--mark-missing root (harness-worktree--parse-list output)))))

(defun harness-worktree--branch-exists-p (root branch)
  "Return a promise of non-nil when BRANCH exists in the repository at ROOT."
  (harness-then
   (harness-run-command (list "git" "rev-parse" "--verify" "--quiet"
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
otherwise it is created from `:base'.  The worktree is locked, with the
reason `harness-worktree-lock-prefix' and the branch, so `git worktree
prune' keeps it until the merge queue lifts the lock.  Emits
`worktree/created'."
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (branch (or (plist-get opts :branch)
                     (concat harness-worktree-branch-prefix (harness-short-id))))
         (path (expand-file-name (or (plist-get opts :path)
                                     (funcall harness-worktree-directory-function root branch))))
         (base (or (plist-get opts :base) "HEAD"))
         (lock (list "--lock" "--reason" (harness-worktree--lock-reason branch))))
    (harness-then
     (harness-worktree--branch-exists-p root branch)
     (lambda (exists)
       (harness-ensure-directory (file-name-directory (directory-file-name path)))
       (harness-worktree--ignore-container root path)
       (harness-then
        (apply #'harness-worktree--git root "worktree" "add"
               (append lock (if exists (list path branch) (list "-b" branch path base))))
        (lambda (_)
          (harness-then
           (harness-worktree--find root path)
           (lambda (wt)
             (harness-emit 'worktree/created root wt)
             wt))))))))

(defun harness-worktree--on (root action path &rest options)
  "Run `git worktree ACTION OPTIONS PATH' in ROOT; return a promise of its output.
PATH goes without a trailing slash: git does not find a worktree whose
directory is missing by a path that ends in one."
  (apply #'harness-worktree--git root "worktree" action
         (append options (list (directory-file-name path)))))

(harness-defmethod worktree/lock (root path &optional reason)
  "Lock the worktree at PATH of the repository at ROOT; return a promise.
git keeps a locked worktree when it prunes, even when it cannot see its
directory, and removes it only when forced twice.  REASON defaults to
`harness-worktree-lock-prefix' and the worktree's branch.  A worktree
locked already keeps its lock.  The promise resolves to non-nil when
this call locked it.  Emits `worktree/locked'."
  (let ((path (file-name-as-directory (expand-file-name path))))
    (harness-then
     (harness-worktree--find root path)
     (lambda (wt)
       (unless (harness-json-true-p (plist-get wt :locked))
         (harness-then
          (harness-worktree--on root "lock" path "--reason"
                                (or reason (harness-worktree--lock-reason (plist-get wt :branch))))
          (lambda (_)
            (harness-emit 'worktree/locked root path)
            t)))))))

(defun harness-worktree--lift-lock (root path)
  "Lift the lock of the worktree at PATH of ROOT; return a promise.
It resolves to t when this call lifted the lock, and to nil when
somebody else lifted it between the look that found it locked and
this call: the merge queue unlocks a task's worktree once its branch
merged, while an archive of the task may be removing that worktree.
It rejects with git's error when the worktree is still locked.  git's
message is not matched, as it may come in the user's language: the
worktree is looked at again instead."
  (harness-catch
   (harness-then (harness-worktree--on root "unlock" path) (lambda (_) t))
   (lambda (err)
     (harness-then
      (harness-worktree--find root path)
      (lambda (wt)
        (if (harness-json-true-p (plist-get wt :locked))
            (harness-rejected err)
          nil))))))

(harness-defmethod worktree/unlock (root path &optional any)
  "Unlock the worktree at PATH of the repository at ROOT; return a promise.
Only a lock the harness made, its reason starting with
`harness-worktree-lock-prefix', is lifted, unless ANY: a lock somebody
else put on a worktree stays.  The promise resolves to non-nil when this
call unlocked it, and to nil when somebody else lifted the lock first.
Emits `worktree/unlocked'."
  (let ((path (file-name-as-directory (expand-file-name path))))
    (harness-then
     (harness-worktree--find root path)
     (lambda (wt)
       (when (if any
                 (harness-json-true-p (plist-get wt :locked))
               (harness-worktree-harness-lock-p wt))
         (harness-then
          (harness-worktree--lift-lock root path)
          (lambda (lifted)
            (when lifted
              (harness-emit 'worktree/unlocked root path)
              t))))))))

(defun harness-worktree--remove-unlocking (root path wt)
  "Remove worktree WT at PATH of ROOT, lifting the harness's lock first.
When git still refuses (the worktree has local changes), the lock goes
back on before the promise rejects with git's error.  A lock somebody
else lifted meanwhile, as the merge queue does once a task's branch
merged, is no failure: the worktree goes all the same, and should git
refuse, it stays unlocked as they left it."
  (harness-then
   (harness-worktree--lift-lock root path)
   (lambda (lifted)
     (if (not lifted)
         (harness-worktree--on root "remove" path)
       (harness-catch
        (harness-worktree--on root "remove" path)
        (lambda (err)
          (harness-then
           (harness-catch
            (harness-worktree--on root "lock" path "--reason" (plist-get wt :lock-reason))
            (lambda (e)
              (harness-log 'warn "worktree: could not lock %s again: %s" path (harness-error-message e))
              nil))
           (lambda (_) (harness-rejected err)))))))))

(harness-defmethod worktree/remove (root path &optional force)
  "Remove the worktree at PATH from the repository at ROOT.
A lock the harness made is lifted first, and put back should git still
refuse because the worktree has local changes.  With FORCE the worktree
goes even with local changes or a lock of someone else (`git worktree
remove -f -f').  Return a promise of PATH.  Emits `worktree/removed'."
  (let ((path (file-name-as-directory (expand-file-name path))))
    (harness-then
     (if force
         (harness-worktree--on root "remove" path "-f" "-f")
       (harness-then
        (harness-worktree--find root path)
        (lambda (wt)
          (if (harness-worktree-harness-lock-p wt)
              (harness-worktree--remove-unlocking root path wt)
            (harness-worktree--on root "remove" path)))))
     (lambda (_)
       (harness-emit 'worktree/removed root path)
       path))))

(defun harness-worktree--kept-lines (worktrees)
  "Return a line for each locked worktree of WORKTREES whose directory is gone.
Those are the records a prune keeps because of their lock."
  (cl-loop for wt in worktrees
           when (and (harness-json-true-p (plist-get wt :locked)) (plist-get wt :missing))
           collect (format "Kept %s: its directory is missing, but it is locked (%s)"
                           (abbreviate-file-name (directory-file-name (plist-get wt :path)))
                           (or (plist-get wt :lock-reason) "no reason given"))))

(harness-defmethod worktree/prune (root)
  "Prune stale worktree records of the repository at ROOT.
That is `git worktree prune', run here, outside any sandbox, where git
sees every worktree directory: it drops the records of worktrees whose
directory is gone, and skips locked ones as git always does.  Return a
promise of the lines git printed about what it removed, followed by a
line for every locked worktree it kept although its directory is
missing (`worktree/remove' takes those away)."
  (let ((root (file-name-as-directory (expand-file-name root)))
        (args (list "worktree" "prune" "-v")))
    (harness-then
     (harness-run-command (cons "git" args) :cwd root :name "harness-git")
     (lambda (result)
       (unless (eql (plist-get result :exit) 0)
         (signal 'harness-error (cdr (harness-worktree--error args result))))
       ;; git reports what it pruned on stderr.
       (let ((pruned (split-string (concat (plist-get result :stdout) "\n" (plist-get result :stderr)) "\n" t)))
         (harness-then (harness-call 'worktree/list root)
                       (lambda (worktrees) (append pruned (harness-worktree--kept-lines worktrees)))
                       (lambda (_) pruned)))))))

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

;;;; Locking the worktrees made before the harness locked them

(defun harness-worktree--container (root)
  "Return the directory that holds the worktrees the harness makes for ROOT.
That is where `harness-worktree-directory-function' puts them:
ROOT/.worktrees/ by default."
  (file-name-directory
   (directory-file-name (expand-file-name (funcall harness-worktree-directory-function root "harness-probe")))))

(defun harness-worktree--to-lock-p (root container wt)
  "Non-nil when `worktree/lock-existing' should lock WT of ROOT.
CONTAINER is the directory holding the harness's worktrees of ROOT."
  (and (not (plist-get wt :main))
       (not (plist-get wt :bare))
       (not (harness-json-true-p (plist-get wt :locked)))
       (not (plist-get wt :prunable))
       (not (plist-get wt :missing))
       (harness-worktree--inside-p container (plist-get wt :path))
       (harness-run-filter 'worktree/lock-existing-p t root wt)))

(defun harness-worktree--lock-each (root worktrees)
  "Lock WORKTREES of ROOT one after the other.
Return a promise of the paths locked.  A failure is logged and the
next worktree goes on."
  (let ((locked nil))
    (cl-labels ((next (rest)
                  (if (null rest)
                      (harness-resolved (nreverse locked))
                    (let* ((wt (car rest))
                           (path (plist-get wt :path)))
                      (harness-then
                       (harness-catch
                        (harness-then
                         (harness-worktree--on root "lock" path "--reason"
                                               (harness-worktree--lock-reason (plist-get wt :branch)))
                         (lambda (_)
                           (push path locked)
                           (harness-emit 'worktree/locked root path)))
                        (lambda (err)
                          (harness-log 'warn "worktree: could not lock %s: %s" path (harness-error-message err))
                          nil))
                       (lambda (_) (next (cdr rest))))))))
      (next worktrees))))

(harness-defmethod worktree/lock-existing (root)
  "Lock the worktrees the harness keeps for ROOT that have no lock yet.
Those are the registered worktrees in the directory the harness puts
its worktrees in (see `harness-worktree-directory-function'): never the
main checkout or a foreign worktree elsewhere, never one whose
directory is missing, and none the sync filter `worktree/lock-existing-p'
turns down (value t, args ROOT WORKTREE; the tasks module turns down the
worktrees of merged tasks).  This is how worktrees made before the
harness locked its worktrees get their lock.  Return a promise of the
paths locked."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (harness-then
     (harness-call 'worktree/list root)
     (lambda (worktrees)
       (let ((container (harness-worktree--container root)))
         (harness-worktree--lock-each
          root (cl-remove-if-not (lambda (wt) (harness-worktree--to-lock-p root container wt))
                                 worktrees)))))))

(defun harness-worktree--locked-roots-path ()
  "Return the file naming the repositories whose worktrees were locked."
  (expand-file-name harness-worktree--locked-roots-file harness-state-directory))

(defun harness-worktree--locked-roots ()
  "Return the repositories whose existing worktrees were locked already."
  (let ((data (ignore-errors (harness-json-parse (harness-read-file (harness-worktree--locked-roots-path))))))
    (and (listp data) (cl-remove-if-not #'stringp data))))

(defun harness-worktree--note-locked-root (root)
  "Remember that the existing worktrees of ROOT were locked."
  (let ((roots (harness-worktree--locked-roots)))
    (unless (member root roots)
      (harness-write-file-atomically (harness-worktree--locked-roots-path)
                                     (harness-json-encode (harness-json-array (append roots (list root))))))))

(defun harness-worktree--known-roots ()
  "Return the main checkouts of the local repositories the sessions work in."
  (let (roots)
    (when (harness-method-exists-p 'session/list)
      (dolist (s (ignore-errors (harness-call 'session/list)))
        (let ((dir (or (plist-get s :worktree) (plist-get s :project) (plist-get s :cwd))))
          (when (and (stringp dir) (not (file-remote-p dir)) (file-directory-p dir))
            (let ((main (harness-files-main-checkout dir)))
              (when (file-directory-p (expand-file-name ".git" main))
                (cl-pushnew main roots :test #'equal)))))))
    (nreverse roots)))

(defun harness-worktree--lock-known (&rest _)
  "Lock the existing worktrees of the repositories the sessions work in.
Each repository gets this once (see `harness-worktree--locked-roots-file'):
afterwards its worktrees are locked when they are made, and unlocked
when merged, which this would undo.  Runs when the harness starts or
reloads."
  (dolist (root (cl-set-difference (harness-worktree--known-roots) (harness-worktree--locked-roots)
                                   :test #'equal))
    (harness-then
     (harness-call 'worktree/lock-existing root)
     (lambda (locked)
       (harness-worktree--note-locked-root root)
       (when locked
         (harness-log 'info "worktree: locked %d existing worktree(s) of %s" (length locked) root)))
     (lambda (err)
       (harness-log 'warn "worktree: locking the worktrees of %s failed: %s" root (harness-error-message err))))))

(harness-declare-event 'worktree/created "(ROOT WORKTREE) after a worktree was added.")
(harness-declare-event 'worktree/removed "(ROOT PATH) after a worktree was removed.")
(harness-declare-event 'worktree/locked "(ROOT PATH) after the harness locked a worktree.")
(harness-declare-event 'worktree/unlocked "(ROOT PATH) after the harness unlocked a worktree.")

(defun harness-worktree--init ()
  "Lock the existing worktrees whenever the harness starts or reloads.
Safe to call again."
  (harness-on 'harness/started #'harness-worktree--lock-known)
  (harness-on 'harness/reloaded #'harness-worktree--lock-known))

;; A reload does not run `:init' again for a ready module, so a running
;; harness that reloads this file subscribes here and still locks the
;; worktrees made before.
(harness-worktree--init)

(harness-define-module 'worktree
  :doc "Git worktree listing, creation, locking, removal and status."
  :requires '(project)
  :init #'harness-worktree--init)

(provide 'harness-worktree)
;;; harness-worktree.el ends here
