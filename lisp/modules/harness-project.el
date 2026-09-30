;;; harness-project.el --- Project detection  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sessions are scoped to a project.  Detection is delegated to
;; project.el so it agrees with the rest of the user's Emacs.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'harness-core)
(require 'harness-util)

(defvar harness-project--file-cache (make-hash-table :test 'equal)
  "Root -> (TIMESTAMP . FILES) cache for `project/files'.")

(defcustom harness-project-files-cache-seconds 5
  "How long a project's file list is reused before it is recomputed."
  :type 'number :group 'harness)

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

(defun harness-project--files (root)
  (let* ((root (file-name-as-directory (expand-file-name root)))
         (cached (gethash root harness-project--file-cache)))
    (if (and cached (< (- (float-time) (car cached)) harness-project-files-cache-seconds))
        (cdr cached)
      (let* ((pr (ignore-errors (project-current nil root)))
             (files (if pr
                        (mapcar (lambda (f) (file-relative-name f root)) (project-files pr))
                      (mapcar (lambda (f) (file-relative-name f root))
                              (directory-files-recursively root "" nil
                                                           (lambda (d) (not (string-match-p "/\\.\\(git\\|hg\\)\\'" d))))))))
        (puthash root (cons (float-time) files) harness-project--file-cache)
        files))))

(harness-defmethod project/files (root &optional query limit)
  "Return files under ROOT relative to it, fuzzy filtered by QUERY, at most LIMIT."
  (let ((files (harness-project--files root)))
    (cond ((harness-string-blank-p query) (if limit (seq-take files limit) files))
          (t (harness-fuzzy-filter query files nil limit)))))

(harness-defmethod project/invalidate (root)
  "Forget the cached file list for ROOT."
  (remhash (file-name-as-directory (expand-file-name root)) harness-project--file-cache))

(harness-define-module 'project
  :doc "Project detection through project.el.")

(provide 'harness-project)
;;; harness-project.el ends here
