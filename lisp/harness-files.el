;;; harness-files.el --- Project roots and file lists, never blocking  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Used by both the harness process (project/root, project/files) and the
;; UI (@ completion, session scoping), so a project means the same thing
;; on both sides of harness-server.el.
;;
;; Listing never blocks: a synchronous walk of a big tree freezes Emacs.
;; There is no file cache here.  Files come from projectile's cache when
;; it has them (the one `projectile-invalidate-cache' clears); on a miss
;; the command projectile would run is run asynchronously and the result
;; stored back into projectile's cache.  Without projectile a git project
;; is listed asynchronously on every request.  Outside a project nothing
;; is listed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'harness-core)
(require 'harness-util)

(defun harness-files-project-root (dir)
  "Return the project root directory of DIR, or DIR itself."
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (pr (ignore-errors (project-current nil dir))))
    (if pr
        (file-name-as-directory (expand-file-name (project-root pr)))
      dir)))

(defun harness-files-main-root (dir)
  "Return DIR's project root, or its main checkout when that is a linked
git worktree.  Reads the worktree's .git file and the commondir it points
to, so it runs no process; remote directories get their plain root."
  (let ((root (harness-files-project-root dir)))
    (or (and (not (file-remote-p root))
             (ignore-errors
               (let ((dotgit (expand-file-name ".git" root)))
                 (when (file-regular-p dotgit)
                   (with-temp-buffer
                     (insert-file-contents dotgit)
                     (when (re-search-forward "^gitdir: *\\(.+?\\) *$" nil t)
                       (let* ((gitdir (expand-file-name (match-string 1) root))
                              (commondir (expand-file-name "commondir" gitdir))
                              (common (directory-file-name
                                       (if (file-readable-p commondir)
                                           (progn (erase-buffer)
                                                  (insert-file-contents commondir)
                                                  (expand-file-name (string-trim (buffer-string)) gitdir))
                                         gitdir))))
                         ;; A submodule's gitdir has no commondir and is not a .git.
                         (and (equal (file-name-nondirectory common) ".git")
                              (file-name-as-directory (file-name-directory common))))))))))
        root)))

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

(defcustom harness-files-timeout 30
  "Seconds a file-listing process may run before it is killed."
  :type 'number :group 'harness)

(defvar harness-files--listings (make-hash-table :test 'equal)
  "Root -> promise of the file listing in flight for that root.
Not a cache: an entry lives only until its listing settles.")

;;;; Listing

(defun harness-files--run-listing (root command)
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
      (setq timer (run-at-time harness-files-timeout nil
                               (lambda ()
                                 (harness-log 'warn "project: listing %s timed out" root)
                                 (when (process-live-p proc) (delete-process proc))))))))

(defun harness-files--projectile-root-p (root)
  "Non-nil when projectile considers ROOT a project root."
  (and (featurep 'projectile)
       (let ((pr (ignore-errors (projectile-project-root root))))
         (and pr (string= (file-name-as-directory (expand-file-name pr)) root)))))

(defun harness-files--projectile-cached (root)
  "Return projectile's cached files for ROOT without computing any, or nil."
  (when projectile-enable-caching
    (let ((time (gethash root projectile-projects-cache-time)))
      (unless (and projectile-files-cache-expire time
                   (< (+ time projectile-files-cache-expire) (projectile-time-seconds)))
        (or (gethash root projectile-projects-cache)
            (and (eq projectile-enable-caching 'persistent)
                 (projectile-load-project-cache root)))))))

(defun harness-files--projectile-list (root)
  "Return a promise of ROOT's files listed like projectile, cached in projectile.
Git submodules, which projectile lists synchronously, are not included."
  (let* ((vcs (projectile-project-vcs root))
         (command (projectile-get-ext-command vcs))
         (command (if (functionp command) (funcall command vcs) command)))
    (if (not (and (stringp command) (not (string-empty-p command))))
        (harness-resolved nil)
      (harness-then (harness-files--run-listing root command)
                    (lambda (files)
                      (let ((files (if (eq projectile-indexing-method 'alien)
                                       files
                                     (projectile-adjust-files root vcs files))))
                        (when (and files projectile-enable-caching)
                          (projectile-cache-project root files))
                        files))))))

(defun harness-files--git-root-p (root)
  "Non-nil when ROOT is a project.el project with a git checkout at its root."
  (let ((pr (ignore-errors (project-current nil root))))
    (and pr (file-exists-p (expand-file-name ".git" (project-root pr))))))

(defun harness-files--start-listing (root fn)
  "Return the listing of ROOT in flight, or start one with FN."
  (or (gethash root harness-files--listings)
      (let ((p (harness-finally (funcall fn) (lambda () (remhash root harness-files--listings)))))
        (unless (harness-promise-settled-p p) (puthash root p harness-files--listings))
        p)))

(defun harness-files-list (root)
  "Return a promise of the files under project ROOT, relative to it.
Resolves to nil when ROOT is not a project."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (cond
     ((harness-files--projectile-root-p root)
      (if-let* ((cached (harness-files--projectile-cached root)))
          (harness-resolved cached)
        (harness-files--start-listing root (lambda () (harness-files--projectile-list root)))))
     ((harness-files--git-root-p root)
      (harness-files--start-listing
       root (lambda () (harness-files--run-listing root "git ls-files -zco --exclude-standard"))))
     (t (harness-resolved nil)))))

(defun harness-files-list-limited (root &optional query limit)
  "Return a promise of ROOT's files, fuzzy filtered by QUERY, at most LIMIT."
  (harness-then (harness-files-list root)
                (lambda (files)
                  (if (harness-string-blank-p query)
                      (if limit (seq-take files limit) files)
                    (harness-fuzzy-filter query files nil limit)))))

(provide 'harness-files)
;;; harness-files.el ends here
