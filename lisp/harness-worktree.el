;;; harness-worktree.el --- Git worktree integration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; Author: Noah Huppert <contact@noahh.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai, vc
;; URL: https://github.com/noahhuppert/emacs-agent-harness

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

;; An agent that edits files should not do it in the working tree you are
;; using.  A session can create its own git worktree, which becomes the
;; session's working directory -- so tools, `@' completion and everything else
;; follow it automatically, because they all resolve through
;; `harness-session-cwd'.
;;
;; Three behaviours matter and are all opt-in:
;;
;; - Create: `harness-worktree-create' adds a worktree on its own branch and
;;   points the session at it.  It runs git asynchronously, because a checkout
;;   of a large repository is exactly the kind of thing that must not freeze
;;   Emacs.
;; - Work in it: nothing else is needed; the session's directory changed.
;; - Clean up: `harness-worktree-remove' removes the worktree (and, when asked,
;;   the branch), and `harness-worktree-cleanup-on-exit' removes worktrees
;;   whose sessions end, or when Emacs exits, so a forgotten worktree does not
;;   accumulate forever.  Cleaning up refuses to throw away work: git itself
;;   refuses to remove a worktree with uncommitted changes, and the error is
;;   reported rather than forced away.
;;
;; See DESIGN.md section 16.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'harness-core)
(require 'harness-session)
(require 'harness-tools)
(require 'harness-ui-conversation)

(defcustom harness-worktree-directory nil
  "Where new worktrees are created.
Nil means a sibling directory of the project named `<project>-worktrees',
which keeps worktrees out of the project itself."
  :type '(choice (const :tag "Next to the project" nil) directory)
  :group 'harness)

(defcustom harness-worktree-branch-prefix "harness/"
  "Prefix for branches created for sessions."
  :type 'string
  :group 'harness)

(defcustom harness-worktree-cleanup-on-exit nil
  "Whether to remove a session's worktree when the session is closed.
Nil leaves it for inspection; `harness-worktree-cleanup-on-emacs-exit'
covers the Emacs-exit case separately."
  :type 'boolean
  :group 'harness)

(defcustom harness-worktree-cleanup-on-emacs-exit t
  "Whether to remove session worktrees when Emacs exits."
  :type 'boolean
  :group 'harness)

(defcustom harness-worktree-delete-branch t
  "Whether removing a worktree also deletes its branch."
  :type 'boolean
  :group 'harness)

(defvar harness-worktree-changed-hook nil
  "Hook run with (SESSION ACTION PATH) after a worktree changes.")


;;; Running git

(defun harness-worktree--run (directory arguments callback)
  "Run git with ARGUMENTS in DIRECTORY, then call CALLBACK with a plist.
CALLBACK receives `:success', `:output' and `:exit'.  Asynchronous, because
`git worktree add' writes a whole checkout."
  (harness-tools-run-process
   (concat "git " (mapconcat #'shell-quote-argument arguments " "))
   directory
   (lambda (result)
     (let ((exit (plist-get result :exit))
           (output (string-trim (or (plist-get result :output) ""))))
       (funcall callback (list :success (and (integerp exit) (zerop exit))
                               :output output
                               :exit exit))))
   600))

(defun harness-worktree--git-directory (session)
  "Return the directory to run git in for SESSION."
  (let ((cwd (harness-session-cwd session)))
    (if (file-directory-p cwd)
        cwd
      (or (harness-session-project-root session) default-directory))))

(defun harness-worktree--repository-root (session)
  "Return SESSION's repository root, or nil when it is not in a repository."
  (let* ((cwd (harness-session-cwd session))
         (root (locate-dominating-file cwd ".git")))
    (and root (file-name-as-directory (expand-file-name root)))))

(defun harness-worktree-p (&optional directory)
  "Return non-nil when DIRECTORY is a linked git worktree."
  (let* ((directory (file-name-as-directory (expand-file-name
                                             (or directory default-directory))))
         (dot-git (expand-file-name ".git" directory)))
    ;; A linked worktree has a .git *file* pointing at the real git dir; the
    ;; main worktree has a .git directory.
    (and (file-exists-p dot-git) (not (file-directory-p dot-git)))))

(defun harness-worktree-slug (session)
  "Return a filesystem-safe slug for SESSION's worktree."
  (let ((name (harness-session-name session)))
    (concat (string-trim
             (replace-regexp-in-string "[^a-zA-Z0-9._-]+" "-" (downcase name))
             "-+" "-+")
            "-"
            (substring (harness-session-id session) -8))))

(defun harness-worktree-path (session)
  "Return the path a worktree for SESSION would use."
  (let* ((root (or (harness-worktree--repository-root session)
                   (harness-session-cwd session)))
         (parent (file-name-directory (directory-file-name root)))
         (name (file-name-nondirectory (directory-file-name root)))
         (base (or harness-worktree-directory
                   (expand-file-name (concat name "-worktrees") parent))))
    (expand-file-name (harness-worktree-slug session) base)))

(defun harness-worktree-branch (session &optional branch)
  "Return the branch name to use for SESSION's worktree."
  (or branch (concat harness-worktree-branch-prefix (harness-worktree-slug session))))

(defun harness-worktree-of (session)
  "Return the worktree plist recorded on SESSION, or nil."
  (plist-get (harness-session-meta session) :worktree))

(defun harness-worktree-record (session worktree)
  "Record WORKTREE on SESSION and announce the change."
  (setf (harness-session-meta session)
        (plist-put (harness-session-meta session) :worktree worktree))
  (harness-session-save-state session)
  (harness-session-notify session 'meta)
  worktree)


;;; Creating

(defun harness-worktree-create (session &optional branch callback)
  "Create a worktree for SESSION and point the session at it.

BRANCH, when given, names the branch; otherwise one is derived from the
session.  CALLBACK receives the worktree plist, or nil on failure.  git runs
asynchronously, and the session's directory is only changed once the checkout
has succeeded."
  (interactive (list (or (when (fboundp 'harness-conversation-session)
                           (harness-conversation-session))
                         (harness-session--read-session "Worktree for"))))
  (let* ((repository (harness-worktree--repository-root session))
         (path (harness-worktree-path session))
         (branch-name (harness-worktree-branch session branch)))
    (cond
     ((null repository)
      (message "%s is not inside a git repository" (harness-session-name session))
      (when callback (funcall callback nil))
      nil)
     ((file-exists-p path)
      (message "A worktree already exists at %s" path)
      (when callback (funcall callback (harness-worktree-of session)))
      nil)
     (t
      (message "Creating worktree %s on %s…" path branch-name)
      (harness-worktree--run
       repository
       (list "worktree" "add" "-b" branch-name path)
       (lambda (result)
         (if (plist-get result :success)
             (let ((worktree (list :path path
                                   :branch branch-name
                                   :repository repository
                                   :created (float-time))))
               (harness-worktree-record session worktree)
               (harness-session-set-working-directory session path)
               (run-hook-with-args 'harness-worktree-changed-hook session 'created path)
               (message "Session %s now works in %s on %s"
                        (harness-session-name session) path branch-name)
               (when callback (funcall callback worktree)))
           (message "git worktree add failed: %s" (plist-get result :output))
           (when callback (funcall callback nil)))))
      t))))

(defun harness-worktree-new (branch)
  "Start a new session that works in a fresh git worktree."
  (interactive "sBranch (default: derived from the session): ")
  (let ((session (harness-session-create
                  (list :name (format "worktree %s" (or (string-remove-prefix
                                                         harness-worktree-branch-prefix
                                                         branch)
                                                        "session"))))))
    (harness-conversation-open session)
    (harness-worktree-create session (unless (string-empty-p branch) branch))))


;;; Listing and removing

(defun harness-worktree-list (&optional session)
  "Return the worktrees of SESSION's repository as plists.
Runs git synchronously: `git worktree list' is a read of one file and this is
a user-invoked command, unlike the tool paths."
  (interactive)
  (let* ((directory (if session (harness-worktree--git-directory session)
                      default-directory))
         (output (ignore-errors
                   (with-temp-buffer
                     (let ((default-directory (file-name-as-directory directory)))
                       (when (zerop (call-process "git" nil t nil
                                                  "worktree" "list" "--porcelain"))
                         (buffer-string)))))))
    (when output
      (let ((worktrees nil)
            (current nil))
        (dolist (line (split-string output "\n" t))
          (cond
           ((string-prefix-p "worktree " line)
            ;; `current' is a plist: never reverse it, that corrupts the pairs.
            (when current (push current worktrees))
            (setq current (list :path (substring line 9))))
           ((string-prefix-p "branch " line)
            (setq current (plist-put current :branch
                                     (string-remove-prefix "refs/heads/"
                                                           (substring line 7)))))
           ((string-prefix-p "HEAD " line)
            (setq current (plist-put current :head (substring line 5))))
           ((string-prefix-p "detached" line)
            (setq current (plist-put current :detached t)))
           ((string-prefix-p "bare" line)
            (setq current (plist-put current :bare t)))))
        (when current (push current worktrees))
        (nreverse worktrees)))))

(defun harness-worktree-remove (session &optional force delete-branch callback)
  "Remove SESSION's worktree.
With FORCE, let git discard a dirty worktree; otherwise git refuses and the
change is reported.  Calls CALLBACK with non-nil on success."
  (interactive (list (or (when (fboundp 'harness-conversation-session)
                           (harness-conversation-session))
                         (harness-session--read-session "Remove worktree of"))
                     current-prefix-arg))
  (let ((worktree (harness-worktree-of session)))
    (if (null worktree)
        (progn
          (message "Session %s has no worktree" (harness-session-name session))
          (when callback (funcall callback nil))
          nil)
      (let ((path (plist-get worktree :path))
            (branch (plist-get worktree :branch))
            (repository (plist-get worktree :repository)))
        (message "Removing worktree %s…" path)
        (harness-worktree--run
         (or repository (harness-worktree--git-directory session))
         (append (list "worktree" "remove") (when force (list "--force")) (list path))
         (lambda (result)
           (if (not (plist-get result :success))
               (progn
                 (message "git worktree remove failed (uncommitted changes?): %s"
                          (plist-get result :output))
                 (when callback (funcall callback nil)))
             (harness-worktree-record session nil)
             ;; Return the session to the project it came from.
             (when (or (harness-session-project-root session)
                       (file-directory-p repository))
               (ignore-errors
                 (harness-session-set-working-directory
                  session (or (harness-session-project-root session) repository))))
             (run-hook-with-args 'harness-worktree-changed-hook session 'removed path)
             (if (and (or delete-branch harness-worktree-delete-branch)
                      (not (string-empty-p (or branch ""))))
                 (harness-worktree--run
                  repository (list "branch" "-D" branch)
                  (lambda (branch-result)
                    (unless (plist-get branch-result :success)
                      (message "Could not delete branch %s: %s" branch
                               (plist-get branch-result :output)))
                    (when callback (funcall callback t))))
               (when callback (funcall callback t))))))
        t))))

(defun harness-worktree-cleanup (session &optional force)
  "Remove SESSION's worktree if it has one and cleanup is wanted."
  (when (and (harness-worktree-of session)
             (or force harness-worktree-cleanup-on-exit))
    (harness-worktree-remove session force)))

(defun harness-worktree-cleanup-all (&optional force)
  "Remove the worktrees of every live session that has one."
  (interactive "P")
  (let ((count 0))
    (dolist (session (harness-session-all))
      (when (harness-worktree-of session)
        (harness-worktree-cleanup session force)
        (setq count (1+ count))))
    (when (called-interactively-p 'interactive)
      (message "Cleaning up %d worktree%s" count (if (= count 1) "" "s")))))

(defun harness-worktree-cleanup-on-kill-emacs ()
  "Remove session worktrees when Emacs exits.
Uncommitted work is never discarded: git refuses those removals."
  (when harness-worktree-cleanup-on-emacs-exit
    ;; A short git call at exit is the only way to be sure it happened, and
    ;; the alternative -- a worktree nobody removes -- is worse.
    (dolist (session (harness-session-all))
      (when (harness-worktree-of session)
        (let* ((worktree (harness-worktree-of session))
               (repository (plist-get worktree :repository))
               (path (plist-get worktree :path)))
          (ignore-errors
            (let ((default-directory (file-name-as-directory
                                      (or repository default-directory))))
              (call-process "git" nil nil nil "worktree" "remove" path))))))))

(add-hook 'kill-emacs-hook #'harness-worktree-cleanup-on-kill-emacs)

(defun harness-worktree--on-session-deleted (session)
  "Clean up SESSION's worktree when the session is removed."
  (when (and harness-worktree-cleanup-on-exit (harness-worktree-of session))
    (harness-worktree-remove session)))

(add-hook 'harness-session-deleted-hook #'harness-worktree--on-session-deleted)

(defun harness-worktree-switch (path)
  "Point the current session at an existing worktree PATH."
  (interactive (list (let ((worktrees (harness-worktree-list)))
                       (if worktrees
                           (completing-read "Worktree: "
                                            (mapcar (lambda (worktree)
                                                      (plist-get worktree :path))
                                                    worktrees)
                                            nil t)
                         (read-directory-name "Worktree: " nil nil t)))))
  (let ((session (or (when (fboundp 'harness-conversation-session)
                       (harness-conversation-session))
                     (harness-session--read-session "Switch to worktree"))))
    (harness-session-set-working-directory session path)
    (when (harness-worktree-p path)
      (harness-worktree-record session (list :path (file-name-as-directory path)
                                             :branch (harness-worktree--current-branch path))))))

(defun harness-worktree--current-branch (directory)
  "Return the branch checked out in DIRECTORY, or nil."
  (ignore-errors
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory directory)))
        (when (zerop (call-process "git" nil t nil "rev-parse" "--abbrev-ref" "HEAD"))
          (string-trim (buffer-string)))))))

(defun harness-worktree-status (session)
  "Return a short description of SESSION's worktree, or nil."
  (when-let* ((worktree (harness-worktree-of session)))
    (format "%s%s"
            (file-name-nondirectory (directory-file-name (plist-get worktree :path)))
            (if-let* ((branch (plist-get worktree :branch)))
                (format " (%s)" branch)
              ""))))


;;; Tool

(harness-define-tool "worktree"
  :description "Create, list or remove a git worktree and work in it. A worktree gives you an isolated checkout so your edits do not disturb the user's working tree."
  :parameters '(:type "object"
                :properties (:action (:type "string" :enum ("create" "remove" "list"))
                             :branch (:type "string"
                                      :description "Branch for create; defaults to one derived from the session")
                             :force (:type "boolean"
                                     :description "For remove: discard uncommitted changes"))
                :required ("action"))
  :category 'execute
  :approval 'ask
  :async
  (lambda (args context done)
    (let ((session (harness-tool-context-session context))
          (action (harness-tools-arg args :action))
          (branch (harness-tools-arg args :branch))
          (force (harness-tools-arg args :force)))
      (pcase action
        ("list"
         (funcall done
                  (harness-tool-result-create
                   :content (string-join
                             (mapcar (lambda (worktree)
                                       (format "%s on %s"
                                               (plist-get worktree :path)
                                               (or (plist-get worktree :branch) "detached")))
                                     (harness-worktree-list session))
                             "\n")
                   :detail (list :kind 'worktrees
                                 :worktrees (harness-worktree-list session)))))
        ("create"
         (harness-worktree-create
          session branch
          (lambda (worktree)
            (funcall done
                     (if worktree
                         (harness-tool-result-create
                          :content (format "Working in %s on %s"
                                           (plist-get worktree :path)
                                           (plist-get worktree :branch))
                          :detail (list :kind 'worktree :worktree worktree))
                       (harness-tool-result-create
                        :content "Could not create the worktree; see the *Messages* buffer"
                        :error "worktree create failed"))))))
        ("remove"
         (harness-worktree-remove
          session force t
          (lambda (success)
            (funcall done
                     (if success
                         (harness-tool-result-create :content "Worktree removed")
                       (harness-tool-result-create
                        :content "Could not remove the worktree; it may have uncommitted changes (pass force to discard them)"
                        :error "worktree remove failed"))))))
        (_
         (funcall done (harness-tool-result-create
                        :content "action must be create, remove or list"
                        :error "bad action")))))))

(provide 'harness-worktree)
;;; harness-worktree.el ends here
