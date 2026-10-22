;;; harness-project.el --- Project detection  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sessions are scoped to a project.  Roots and file lists come from
;; harness-files.el, shared with the UI so both agree on what a project
;; is; see there for why listing never blocks.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)

(defvar projectile-projects-cache)
(defvar projectile-projects-cache-time)

(harness-defmethod project/root (cwd)
  "Return the project root directory for CWD, or CWD itself."
  (harness-files-project-root cwd))

(harness-defmethod project/name (root)
  "Return a display name for the project at ROOT."
  (file-name-nondirectory (directory-file-name root)))

(defun harness-project--dir (dir)
  "Return DIR as the directory name the harness compares: expanded, with a slash."
  (file-name-as-directory (expand-file-name dir)))

(defun harness-project--scratch-main (name seen)
  "Return the main checkout the work in the temporary directory NAME counts for.
NAME is the name of a session's temporary directory (see
`harness-files-scratch-owner'): the project of that session, as
`harness-project-main' has it, or nil when no session of that name is
known.  SEEN holds the names already followed, so that a session whose
project is in its own directory, or in another's that points back, ends
the search."
  (when (and (not (member name seen))
             (harness-method-exists-p 'session/exists-p)
             (harness-call 'session/exists-p name))
    (let ((project (plist-get (harness-call 'session/get name) :project)))
      (and (stringp project) (not (string-empty-p project))
           (harness-project-main project (cons name seen))))))

(defun harness-project-main (root &optional seen)
  "Return the main checkout the work in ROOT counts for, or nil for none.
That is ROOT's own checkout (`harness-files-owning-checkout'): the one
a linked git worktree, such as a task's or a sub-agent's, was made
from, wherever it was made and also once it is gone from disk.  Else,
when ROOT is a scratch directory, one in a session's temporary directory
\(`harness-files-scratch-owner'), the work is its session's, and counts
for that session's project: the working directory of a sub-agent its
parent made there is no project of the user's.  Nil when that session
is gone.  ROOT is a name the harness recorded, a project or a working
directory.  SEEN is for the recursion."
  (if (file-remote-p root)
      root
    (let* ((scratch (harness-files-scratch-owner root))
           ;; Nothing around a scratch directory that is gone is a project,
           ;; so the tree is not searched for one.
           (own (if (and scratch (not (file-directory-p root)))
                    root
                  (or (ignore-errors (harness-files-owning-checkout root)) root))))
      (if (and scratch (equal (harness-project--dir own) (harness-project--dir root)))
          (harness-project--scratch-main scratch seen)
        own))))

(harness-defmethod project/mains (roots)
  "Return the main checkout of each of ROOTS, as (:root ROOT :main MAIN) entries.
ROOTS is a list of absolute directory names, such as the working
directories of sessions.  A linked git worktree, such as a task's or a
sub-agent's, belongs to the checkout it was made from, wherever it was
made and also once it is gone from disk; any other directory is its own
checkout (`harness-project-main').  A scratch directory in a session's
temporary directory is no checkout: the work in it counts for the
project of the session whose directory it is, and for none, with :main
\"\", once that session is gone.  ROOT comes back as it was given.  It
reads .git files and runs no process, so a client that lists projects,
a phone say, asks for all the directories it knows at once to fold the
worktrees of a project into it.  A name that is not an absolute
directory name is left out."
  (let ((roots (if (stringp roots) (list roots) (append roots nil))))
    (delq nil
          (mapcar (lambda (root)
                    (and (stringp root)
                         (file-name-absolute-p root)
                         (not (string-prefix-p "~" root))
                         (list :root root
                               :main (or (harness-project-main root) ""))))
                  roots))))

(harness-defmethod project/files (root &optional query limit)
  "Return a promise of the files under project ROOT, relative to it.
Fuzzy filtered by QUERY, at most LIMIT; nil when ROOT is not a project."
  (harness-files-list-limited root query limit))

(harness-defmethod project/invalidate (root)
  "Forget projectile's cached file list for ROOT."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (when (featurep 'projectile)
      (remhash root projectile-projects-cache)
      (remhash root projectile-projects-cache-time))))

(harness-define-module 'project
  :doc "Project roots and non-blocking file lists (harness-files.el).")

(provide 'harness-project)
;;; harness-project.el ends here
