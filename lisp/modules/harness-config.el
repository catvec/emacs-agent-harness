;;; harness-config.el --- Layered configuration via .dir-locals.el -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; Harness settings are ordinary Emacs customization variables.  Values are
;; resolved with the standard directory-variables mechanism, most specific
;; last:
;;
;;   1. the global (custom-file) value,
;;   2. the project's .dir-locals.el,
;;   3. the nearest .dir-locals.el between the directory and the project
;;      root.
;;
;; `harness-config-set' persists a value to the most specific file that
;; already configures it, else the project's file, else the global custom
;; file.  Settings live in the nil ("all modes") entry of .dir-locals.el,
;; so they apply to any file in the directory, not just harness buffers.
;;
;; Emacs' own `add-dir-local-variable' is interactive and does not persist
;; in batch; this module reads and writes the same file format directly.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'harness-core)

(defgroup harness-config nil
  "Layered harness configuration."
  :group 'harness)

(defcustom harness-config-dir-locals-file ".dir-locals.el"
  "Name of the directory configuration file."
  :type 'string)

(defvar harness-config--cache (make-hash-table :test #'equal)
  "File -> (MTIME . VARIABLES-ALIST).")

;;; Project root

(defun harness-config-project-root (directory)
  "Return the project root of DIRECTORY, or DIRECTORY itself."
  (let ((dir (file-name-as-directory (expand-file-name directory))))
    (or (when-let* ((project (ignore-errors (project-current nil dir))))
          (file-name-as-directory (expand-file-name (project-root project))))
        dir)))

(defun harness-config-project-p (directory)
  "Return non-nil when DIRECTORY belongs to a project."
  (and (ignore-errors (project-current nil (file-name-as-directory
                                            (expand-file-name directory))))
       t))

;;; Reading .dir-locals.el

(defun harness-config--read-form (file)
  "Read the Lisp form in FILE, or nil."
  (when (file-exists-p file)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (read (current-buffer)))
      (error
       (harness-log "cannot read %s: %S" file err)
       nil))))

(defun harness-config--variables (file)
  "Return the nil-mode variables alist of FILE, cached by mtime."
  (let* ((attributes (file-attributes file))
         (mtime (and attributes (file-attribute-modification-time attributes)))
         (cached (gethash file harness-config--cache)))
    (if (and cached (equal (car cached) mtime))
        (cdr cached)
      (let* ((form (harness-config--read-form file))
             (entry (assq nil form))
             (variables (and (listp entry) (cdr entry))))
        (puthash file (cons mtime variables) harness-config--cache)
        variables))))

(defun harness-config-dir-locals-chain (directory)
  "Return the .dir-locals.el files affecting DIRECTORY, outermost first.
The chain stops at the project root; outside a project only DIRECTORY's
own file is considered."
  (let* ((dir (file-name-as-directory (expand-file-name directory)))
         (root (harness-config-project-root dir))
         (files nil)
         (current dir))
    (catch 'done
      (while t
        (let ((file (expand-file-name harness-config-dir-locals-file current)))
          (when (file-exists-p file)
            (push file files)))
        (when (equal current root)
          (throw 'done nil))
        (let ((parent (file-name-directory (directory-file-name current))))
          (when (or (null parent) (equal parent current))
            (throw 'done nil))
          (setq current parent))))
    files))

;;; Resolution and persistence

(defun harness-config-resolve (variable directory)
  "Return the effective value of VARIABLE for DIRECTORY.
The nearest .dir-locals.el that sets VARIABLE wins; otherwise the global
custom value."
  (let ((value :harness-unset))
    (dolist (file (harness-config-dir-locals-chain directory))
      (when-let* ((pair (assq variable (harness-config--variables file))))
        (setq value (cdr pair))))
    (if (eq value :harness-unset)
        (default-value variable)
      value)))

(defun harness-config--write-form (file form)
  "Write FORM to FILE in the standard .dir-locals.el style."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert ";;; Directory Local Variables            -*- no-byte-compile: t -*-\n")
    (insert ";;; For more information see (info \"(emacs) Directory Variables\")\n\n")
    (let ((print-length nil)
          (print-level nil))
      (pp form (current-buffer)))
    (unless (bolp) (insert "\n"))))

(defun harness-config-write-variable (file variable value)
  "Set VARIABLE to VALUE in the .dir-locals.el FILE."
  (let* ((form (or (harness-config--read-form file) nil))
         (entry (assq nil form))
         (variables (copy-sequence (and (listp entry) (cdr entry))))
         (existing (assq variable variables)))
    (cond
     (existing (setcdr existing value))
     (t (setq variables (cons (cons variable value) variables))))
    (if entry
        (setcdr entry variables)
      (setq form (cons (cons nil variables) form)))
    ;; Keep the file tidy: sort entries by variable name.
    (let ((sorted (sort variables (lambda (a b)
                                    (string< (symbol-name (car a))
                                             (symbol-name (car b)))))))
      (setcdr (assq nil form) sorted))
    (harness-config--write-form file form)
    (remhash file harness-config--cache)
    file))

(defun harness-config--dir-locals-file-for (directory)
  "Return the file `harness-config-set' should write for DIRECTORY.
The most specific file already holding harness settings, else the
project file, else the directory's own file."
  (let* ((dir (file-name-as-directory (expand-file-name directory)))
         (chain (harness-config-dir-locals-chain dir)))
    (or (harness-config--file-already-setting chain)
        (when (harness-config-project-p dir)
          (expand-file-name harness-config-dir-locals-file
                            (harness-config-project-root dir)))
        (expand-file-name harness-config-dir-locals-file dir))))

(defun harness-config--file-already-setting (chain)
  "Return the most specific file in CHAIN that sets a harness variable.
Any harness variable counts: the file already being used for harness
settings should keep receiving them."
  (seq-find (lambda (file)
              (seq-some (lambda (pair)
                          (string-prefix-p "harness-" (symbol-name (car pair))))
                        (harness-config--variables file)))
            (reverse chain)))

(defun harness-config-set (variable value directory)
  "Persist VARIABLE=VALUE for DIRECTORY.
Writes to the nearest file that already holds harness settings, else the
project's .dir-locals.el, else the global custom file.  Returns the file
written, or `global'."
  (let ((file (harness-config--dir-locals-file-for directory)))
    (if file
        (harness-config-write-variable file variable value)
      (customize-save-variable variable value)
      'global)))

(defun harness-config-describe (&optional directory)
  "Return the configuration files and resolved harness values for DIRECTORY."
  (let ((dir (file-name-as-directory (expand-file-name (or directory default-directory)))))
    (list :directory dir
          :project-root (harness-config-project-root dir)
          :files (harness-config-dir-locals-chain dir))))

;;; Service

(defun harness-config-service-resolve (&rest args)
  "Service: resolve a variable for a directory."
  (harness-config-resolve (plist-get args :variable)
                          (or (plist-get args :directory) default-directory)))

(defun harness-config-service-set (&rest args)
  "Service: persist a variable for a directory."
  (harness-config-set (plist-get args :variable)
                      (plist-get args :value)
                      (or (plist-get args :directory) default-directory)))

(defun harness-config-service-describe (&rest args)
  "Service: configuration files for a directory."
  (harness-config-describe (plist-get args :directory)))

(defun harness-config-service-project-root (&rest args)
  "Service: project root of a directory."
  (harness-config-project-root (or (plist-get args :directory) default-directory)))

(defun harness-config-setup ()
  "Set up the config module."
  (harness-service-register
   "config"
   :module 'harness-config
   :doc "Layered configuration through .dir-locals.el."
   :methods '((resolve . harness-config-service-resolve)
              (set . harness-config-service-set)
              (describe . harness-config-service-describe)
              (project-root . harness-config-service-project-root))))

(defun harness-config-teardown ()
  "Tear down the config module."
  (clrhash harness-config--cache))

(harness-module-define 'harness-config
  :version harness-version
  :description "Layered configuration through .dir-locals.el."
  :requires '((harness-core "0.1.0"))
  :provides '(harness-config)
  :setup #'harness-config-setup
  :teardown #'harness-config-teardown)

(provide 'harness-config)
;;; harness-config.el ends here
