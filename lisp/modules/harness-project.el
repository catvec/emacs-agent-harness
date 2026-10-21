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

(harness-defmethod project/mains (roots)
  "Return the main checkout of each of ROOTS, as (:root ROOT :main MAIN) entries.
ROOTS is a list of absolute directory names, such as the working
directories of sessions.  A linked git worktree, such as a task's or a
sub-agent's, belongs to the checkout it was made from, wherever it was
made and also once it is gone from disk; any other directory is its own
checkout (`harness-files-owning-checkout').  ROOT comes back as it was
given.  It reads .git files and runs no process, so a client that lists
projects, a phone say, asks for all the directories it knows at once to
fold the worktrees of a project into it.  A name that is not an absolute
directory name is left out."
  (let ((roots (if (stringp roots) (list roots) (append roots nil))))
    (delq nil
          (mapcar (lambda (root)
                    (and (stringp root)
                         (file-name-absolute-p root)
                         (not (string-prefix-p "~" root))
                         (list :root root
                               :main (or (ignore-errors (harness-files-owning-checkout root))
                                         root))))
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
