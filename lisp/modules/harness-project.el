;;; harness-project.el --- Project detection  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sessions are scoped to a project.  Detection is delegated to
;; project.el so it agrees with the rest of the user's Emacs.
;;
;; File listing never blocks: the UI shares this Emacs, so a synchronous
;; walk of a big tree freezes it.  The harness keeps no file cache of its
;; own.  Files come from projectile's cache when it has them (the one
;; `projectile-invalidate-cache' clears); on a miss the command projectile
;; would run is run asynchronously and its result stored back into
;; projectile's cache.  Without projectile, a git project is listed
;; asynchronously on every request.  Outside a project nothing is listed.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'harness-core)
(require 'harness-util)

(declare-function projectile-project-root "projectile")
(declare-function projectile-project-vcs "projectile")
(declare-function projectile-get-ext-command "projectile")
(declare-function projectile-adjust-files "projectile")
(declare-function projectile-cache-project "projectile")
(declare-function projectile-load-project-cache "projectile")
(declare-function projectile-time-seconds "projectile")
(defvar projectile-enable-caching)
(defvar projectile-indexing-method)
(defvar projectile-projects-cache)
(defvar projectile-projects-cache-time)
(defvar projectile-files-cache-expire)

(defcustom harness-project-files-timeout 30
  "Seconds a file-listing process may run before it is killed."
  :type 'number :group 'harness)

(defvar harness-project--listings (make-hash-table :test 'equal)
  "Root -> promise of the file listing in flight for that root.
Not a cache: an entry lives only until its listing settles.")

(harness-defmethod project/root (cwd)
  "Return the project root directory for CWD, or CWD itself."
  (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
         (pr (ignore-errors (project-current nil cwd))))
    (if pr
        (file-name-as-directory (expand-file-name (project-root pr)))
      cwd)))

(harness-defmethod project/name (root)
  "Return a display name for the project at ROOT."
  (file-name-nondirectory (directory-file-name root)))

;;;; Listing

(defun harness-project--run-listing (root command)
  "Return a promise of the NUL-separated file names shell COMMAND prints in ROOT.
Output collects in a buffer so a large listing costs linear time.  A
failing command resolves to what it printed; a timeout kills it."
  (harness-with-promise (resolve reject)
    (let* ((default-directory root)
           (out (generate-new-buffer " *harness-project-files*" t))
           (timer nil)
           (proc (make-process
                  :name "harness-project-files"
                  :command (list shell-file-name shell-command-switch command)
                  :connection-type 'pipe :noquery t :file-handler t
                  :buffer out :stderr (null-device)
                  :sentinel
                  (lambda (p _event)
                    (unless (process-live-p p)
                      (when timer (cancel-timer timer))
                      (let ((files (and (buffer-live-p out)
                                        (with-current-buffer out
                                          (split-string (buffer-string) "\0" t)))))
                        (when (buffer-live-p out) (kill-buffer out))
                        (funcall resolve files)))))))
      (setq timer (run-at-time harness-project-files-timeout nil
                               (lambda ()
                                 (harness-log 'warn "project: listing %s timed out" root)
                                 (when (process-live-p proc) (delete-process proc))))))))

(defun harness-project--projectile-root-p (root)
  "Non-nil when projectile considers ROOT a project root."
  (and (featurep 'projectile)
       (let ((pr (ignore-errors (projectile-project-root root))))
         (and pr (string= (file-name-as-directory (expand-file-name pr)) root)))))

(defun harness-project--projectile-cached (root)
  "Return projectile's cached files for ROOT without computing any, or nil."
  (when projectile-enable-caching
    (let ((time (gethash root projectile-projects-cache-time)))
      (unless (and projectile-files-cache-expire time
                   (< (+ time projectile-files-cache-expire) (projectile-time-seconds)))
        (or (gethash root projectile-projects-cache)
            (and (eq projectile-enable-caching 'persistent)
                 (projectile-load-project-cache root)))))))

(defun harness-project--projectile-list (root)
  "Return a promise of ROOT's files listed like projectile, cached in projectile.
Git submodules, which projectile lists synchronously, are not included."
  (let* ((vcs (projectile-project-vcs root))
         (command (projectile-get-ext-command vcs))
         (command (if (functionp command) (funcall command vcs) command)))
    (if (not (and (stringp command) (not (string-empty-p command))))
        (harness-resolved nil)
      (harness-then (harness-project--run-listing root command)
                    (lambda (files)
                      (let ((files (if (eq projectile-indexing-method 'alien)
                                       files
                                     (projectile-adjust-files root vcs files))))
                        (when (and files projectile-enable-caching)
                          (projectile-cache-project root files))
                        files))))))

(defun harness-project--git-root-p (root)
  "Non-nil when ROOT is a project.el project with a git checkout at its root."
  (let ((pr (ignore-errors (project-current nil root))))
    (and pr (file-exists-p (expand-file-name ".git" (project-root pr))))))

(defun harness-project--start-listing (root fn)
  "Return the listing of ROOT in flight, or start one with FN."
  (or (gethash root harness-project--listings)
      (let ((p (harness-finally (funcall fn) (lambda () (remhash root harness-project--listings)))))
        (unless (harness-promise-settled-p p) (puthash root p harness-project--listings))
        p)))

(defun harness-project--files (root)
  "Return a promise of the files under project ROOT, relative to it.
Resolves to nil when ROOT is not a project."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (cond
     ((harness-project--projectile-root-p root)
      (if-let* ((cached (harness-project--projectile-cached root)))
          (harness-resolved cached)
        (harness-project--start-listing root (lambda () (harness-project--projectile-list root)))))
     ((harness-project--git-root-p root)
      (harness-project--start-listing
       root (lambda () (harness-project--run-listing root "git ls-files -zco --exclude-standard"))))
     (t (harness-resolved nil)))))

(harness-defmethod project/files (root &optional query limit)
  "Return a promise of the files under project ROOT, relative to it.
Fuzzy filtered by QUERY, at most LIMIT; nil when ROOT is not a project."
  (harness-then (harness-project--files root)
                (lambda (files)
                  (if (harness-string-blank-p query)
                      (if limit (seq-take files limit) files)
                    (harness-fuzzy-filter query files nil limit)))))

(harness-defmethod project/invalidate (root)
  "Forget projectile's cached file list for ROOT."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (when (featurep 'projectile)
      (remhash root projectile-projects-cache)
      (remhash root projectile-projects-cache-time))))

(harness-define-module 'project
  :doc "Project detection through project.el; file lists through projectile's cache.")

(provide 'harness-project)
;;; harness-project.el ends here
