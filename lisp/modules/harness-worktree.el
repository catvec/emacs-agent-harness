;;; harness-worktree.el --- Git worktree management -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; Sessions can live in a git worktree so parallel agents never fight over
;; one checkout.  This module wraps `git worktree' (list, add, remove) and
;; can create a session whose working directory is the new worktree, with
;; the worktree recorded on the session for the UI and the merge queue.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-config)
(require 'harness-session)

(defcustom harness-worktree-root nil
  "Directory under which new worktrees are created.
Defaults to a sibling `<repo>.worktrees' directory next to the
repository's parent, so worktrees never nest inside the checkout."
  :type '(choice directory (const nil)))

(defcustom harness-worktree-branch-prefix "harness/"
  "Prefix added to generated worktree branches when a name is given."
  :type 'string)

(defun harness-worktree--git (directory &rest args)
  "Run git ARGS in DIRECTORY.  Returns (EXIT-CODE . OUTPUT)."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory (expand-file-name directory)))
          (process-environment (cons "GIT_TERMINAL_PROMPT=0" process-environment)))
      (let ((code (apply #'process-file "git" nil (current-buffer) nil args)))
        (cons code (string-trim (buffer-string)))))))

(defun harness-worktree--git-ok (directory &rest args)
  "Run git ARGS in DIRECTORY and return output, or signal a user error."
  (let ((result (apply #'harness-worktree--git directory args)))
    (if (zerop (car result))
        (cdr result)
      (signal 'harness-user-error
              (list (format "git %s failed: %s"
                            (string-join args " ")
                            (or (cdr result) "no output")))))))

(defun harness-worktree-root-directory (directory)
  "Return the repository root of DIRECTORY."
  (harness-worktree--git-ok directory "rev-parse" "--show-toplevel"))

(defun harness-worktree--parse-porcelain (output)
  "Parse `git worktree list --porcelain' OUTPUT."
  (let ((worktrees nil)
        (current nil))
    (dolist (line (split-string output "\n" t))
      (cond
       ((string-prefix-p "worktree " line)
        (when current (push current worktrees))
        (setq current (list :path (substring line 9))))
       ((string-prefix-p "HEAD " line)
        (setq current (plist-put current :head (substring line 5))))
       ((string-prefix-p "branch " line)
        (let ((ref (substring line 7)))
          (setq current (plist-put current :branch
                                   (string-remove-prefix "refs/heads/" ref)))))
       ((string= line "detached")
        (setq current (plist-put current :detached t)))
       ((string= line "bare")
        (setq current (plist-put current :bare t)))
       ((string= line "locked")
        (setq current (plist-put current :locked t)))
       ((string-prefix-p "prunable" line)
        (setq current (plist-put current :prunable
                                 (string-trim (string-remove-prefix "prunable" line)))))))
    (when current (push current worktrees))
    (nreverse worktrees)))

(defun harness-worktree-list (&optional directory)
  "List the worktrees of the repository containing DIRECTORY.
The first entry is the main worktree."
  (let ((output (harness-worktree--git-ok (or directory default-directory)
                                          "worktree" "list" "--porcelain")))
    (let ((worktrees (harness-worktree--parse-porcelain output)))
      (when worktrees
        (setf (plist-get (car worktrees) :main) t))
      (mapcar (lambda (worktree)
                (plist-put worktree :path
                           (file-name-as-directory
                            (expand-file-name (plist-get worktree :path)))))
              worktrees))))

(defun harness-worktree--slug (name)
  "Turn NAME into a branch-safe slug."
  (let ((slug (downcase (replace-regexp-in-string "[^[:alnum:]]+" "-" (string-trim name)))))
    (string-trim slug "-" "-")))

(defun harness-worktree-create (&rest args)
  "Create a worktree.
ARGS: :repo (directory in the repository, default `default-directory'),
:name (branch name; a `harness-worktree-branch-prefix' is added when
missing), :base (starting revision, default HEAD), :path (default under
`harness-worktree-root').  Returns the new worktree plist."
  (let* ((repo (harness-worktree-root-directory
                (or (plist-get args :repo) default-directory)))
         (name (or (plist-get args :name) "session"))
         (branch (if (string-match-p "/" name)
                     name
                   (concat harness-worktree-branch-prefix (harness-worktree--slug name))))
         (base (or (plist-get args :base) "HEAD"))
         (root (or harness-worktree-root
                   (expand-file-name (concat (file-name-nondirectory (directory-file-name repo))
                                             ".worktrees")
                                     (file-name-directory (directory-file-name repo)))))
         (requested (plist-get args :path))
         (path (file-name-as-directory
                (if requested
                    (expand-file-name requested root)
                  (expand-file-name (harness-worktree--slug name) root)))))
    (when (file-exists-p path)
      (signal 'harness-user-error (list (format "Worktree path already exists: %s" path))))
    (make-directory root t)
    ;; Reuse an existing branch when it is not a fresh name.
    (let* ((branch-exists (zerop (car (harness-worktree--git
                                       repo "rev-parse" "--verify" "--quiet"
                                       (concat "refs/heads/" branch)))))
           (output (if branch-exists
                       (harness-worktree--git-ok repo "worktree" "add" path branch)
                     (harness-worktree--git-ok repo "worktree" "add" "-b" branch path base))))
      (ignore output)
      (list :path path :branch branch :repo repo :base base))))

(defun harness-worktree--main-repo (path)
  "Return the main repository root that owns the worktree at PATH.
The removal runs there: the worktree's own directory disappears while the
command runs."
  (let ((common (harness-worktree--git-ok
                 path "rev-parse" "--path-format=absolute" "--git-common-dir")))
    (file-name-as-directory
     (file-name-directory (directory-file-name (file-name-as-directory common))))))

(defun harness-worktree-remove (path &optional force)
  "Remove the worktree at PATH.  FORCE discards uncommitted changes."
  (let ((repo (or (ignore-errors (harness-worktree--main-repo path))
                  (ignore-errors (harness-worktree--git-ok path "rev-parse" "--show-toplevel"))
                  (harness-worktree-root-directory default-directory))))
    (harness-worktree--git-ok
     repo "worktree" "remove" (if force "--force" "--") path)
    (harness-worktree--git repo "worktree" "prune")
    t))

(defun harness-worktree-session (&rest args)
  "Create a worktree and a session that works in it.
ARGS: :repo, :name, :base, :title, plus any `harness-session-create'
arguments.  Returns (WORKTREE . SESSION)."
  (let* ((worktree (harness-worktree-create
                    :repo (plist-get args :repo)
                    :name (plist-get args :name)
                    :base (plist-get args :base)
                    :path (plist-get args :path)))
         (session (harness-session-create
                   :cwd (plist-get worktree :path)
                   :title (or (plist-get args :title)
                              (format "%s (%s)"
                                      (file-name-nondirectory
                                       (directory-file-name (plist-get worktree :repo)))
                                      (plist-get worktree :branch)))
                   :parent-id (plist-get args :parent-id)
                   :model (plist-get args :model)
                   :thinking (plist-get args :thinking)
                   :permission-mode (plist-get args :permission-mode)
                   :worktree worktree)))
    (cons worktree session)))

(defun harness-worktree-service-list (&rest args)
  "Service: list worktrees."
  (vconcat (harness-worktree-list (plist-get args :directory))))

(defun harness-worktree-service-create (&rest args)
  "Service: create a worktree."
  (harness-worktree-create
   :repo (plist-get args :repo)
   :name (plist-get args :name)
   :base (plist-get args :base)
   :path (plist-get args :path)))

(defun harness-worktree-service-remove (&rest args)
  "Service: remove a worktree."
  (harness-worktree-remove (plist-get args :path) (plist-get args :force)))

(defun harness-worktree-service-session (&rest args)
  "Service: create a worktree and a session in it.
Returns a plist with :worktree and :sessionId."
  (let ((result (harness-worktree-session
                 :repo (plist-get args :repo)
                 :name (plist-get args :name)
                 :base (plist-get args :base)
                 :title (plist-get args :title)
                 :parent-id (plist-get args :parent-id))))
    (list :worktree (car result)
          :sessionId (harness-session-id (cdr result)))))

(defun harness-worktree-setup ()
  "Set up the worktree module."
  (harness-service-register
   "worktree"
   :module 'harness-worktree
   :doc "Git worktree listing, creation and session association."
   :methods '((list . harness-worktree-service-list)
              (create . harness-worktree-service-create)
              (remove . harness-worktree-service-remove)
              (session . harness-worktree-service-session))))

(defun harness-worktree-teardown ()
  "Tear down the worktree module."
  (harness-service-unregister "worktree"))

(harness-module-define 'harness-worktree
  :version harness-version
  :description "Git worktrees for parallel sessions."
  :requires '((harness-core "0.1.0")
              (harness-config "0.1.0")
              (harness-session "0.1.0"))
  :provides '(harness-worktree)
  :setup #'harness-worktree-setup
  :teardown #'harness-worktree-teardown)

(provide 'harness-worktree)
;;; harness-worktree.el ends here
