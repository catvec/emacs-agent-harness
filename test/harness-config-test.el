;;; harness-config-test.el --- Tests for layered configuration -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-config)
(require 'harness-test-helpers)

(harness-module-load 'harness-config)

(defvar harness-test-config-value nil)

(defcustom harness-test-config-setting "global"
  "Test setting."
  :type 'string)

(defcustom harness-test-global-only "global-only"
  "Test setting that is only set globally."
  :type 'string)

(defun harness-test-config--project ()
  "Create a temporary project with layered configuration files."
  (let* ((root (make-temp-file "harness-config-project-" t))
         (sub (expand-file-name "sub" root))
         (deep (expand-file-name "sub/deep" root))
         (outside (make-temp-file "harness-config-outside-" t)))
    (make-directory (expand-file-name ".git" root) t)
    (make-directory deep t)
    (harness-config-write-variable (expand-file-name ".dir-locals.el" root)
                                   'harness-test-config-setting "project")
    (harness-config-write-variable (expand-file-name "sub/.dir-locals.el" root)
                                   'harness-test-config-setting "directory")
    (list root sub deep outside)))

(defun harness-test-config--cleanup (dirs)
  "Delete the temporary DIRS."
  (dolist (dir dirs)
    (ignore-errors (delete-directory dir t))))

(ert-deftest harness-config-project-root ()
  (pcase-let ((`(,root ,sub ,deep ,outside) (harness-test-config--project)))
    (unwind-protect
        (progn
          (should (equal (harness-config-project-root deep)
                         (file-name-as-directory root)))
          (should (equal (harness-config-project-root sub)
                         (file-name-as-directory root)))
          (should (equal (harness-config-project-root outside)
                         (file-name-as-directory outside)))
          (should (harness-config-project-p sub))
          (should-not (harness-config-project-p outside)))
      (harness-test-config--cleanup (list root outside)))))

(ert-deftest harness-config-resolve-layers ()
  (pcase-let ((`(,root ,sub ,deep ,outside) (harness-test-config--project)))
    (unwind-protect
        (progn
          ;; Nearest directory file wins.
          (should (equal (harness-config-resolve 'harness-test-config-setting deep)
                         "directory"))
          ;; The project file applies where no nearer file sets it.
          (let ((root-only (expand-file-name "root-only" root)))
            (make-directory root-only t)
            (should (equal (harness-config-resolve 'harness-test-config-setting root-only)
                           "project")))
          ;; Outside a project the global value is used.
          (should (equal (harness-config-resolve 'harness-test-config-setting outside)
                         "global"))
          ;; Unset variables fall back to the global value.
          (should (equal (harness-config-resolve 'harness-test-global-only deep)
                         "global-only")))
      (harness-test-config--cleanup (list root outside)))))

(ert-deftest harness-config-chain-is-outermost-first ()
  (pcase-let ((`(,root ,_sub ,deep ,outside) (harness-test-config--project)))
    (unwind-protect
        (progn
          (should (equal (harness-config-dir-locals-chain deep)
                         (list (expand-file-name ".dir-locals.el" root)
                               (expand-file-name "sub/.dir-locals.el" root))))
          (should (equal (harness-config-dir-locals-chain outside) nil)))
      (harness-test-config--cleanup (list root outside)))))

(ert-deftest harness-config-set-updates-nearest-existing-file ()
  (pcase-let ((`(,root ,sub ,deep ,outside) (harness-test-config--project)))
    (unwind-protect
        (progn
          ;; `sub' already holds harness settings, so new ones go there.
          (harness-config-set 'harness-test-other "x" deep)
          (should (equal (cdr (assq 'harness-test-other
                                    (harness-config--variables
                                     (expand-file-name "sub/.dir-locals.el" root))))
                         "x"))
          (should-not (assq 'harness-test-other
                            (harness-config--variables
                             (expand-file-name ".dir-locals.el" root)))))
      (harness-test-config--cleanup (list root outside)))))

(ert-deftest harness-config-set-uses-project-file-when-none-exists ()
  (let* ((root (make-temp-file "harness-config-plain-" t))
         (sub (expand-file-name "a/b" root)))
    (make-directory (expand-file-name ".git" root) t)
    (make-directory sub t)
    (unwind-protect
        (progn
          (harness-config-set 'harness-test-model "m" sub)
          (let ((project-file (expand-file-name ".dir-locals.el" root)))
            (should (file-exists-p project-file))
            (should (equal (cdr (assq 'harness-test-model
                                      (harness-config--variables project-file)))
                           "m"))
            ;; The file is standard .dir-locals.el data.
            (with-temp-buffer
              (insert-file-contents project-file)
              (goto-char (point-min))
              (let ((form (read (current-buffer))))
                (should (assq nil form))
                (should (equal (cdr (assq 'harness-test-model (cdr (assq nil form))))
                               "m"))))
            ;; A second setting lands in the same file.
            (harness-config-set 'harness-test-mode "plan" sub)
            (should (equal (length (harness-config--variables project-file)) 2))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest harness-config-set-outside-project-uses-directory-file ()
  (let* ((outside (make-temp-file "harness-config-no-project-" t))
         (custom-file (make-temp-file "harness-custom-" nil ".el")))
    (unwind-protect
        (progn
          (should (equal (harness-config-set 'harness-test-global-only "local" outside)
                         (expand-file-name ".dir-locals.el" outside)))
          (should (file-exists-p (expand-file-name ".dir-locals.el" outside)))
          (should (equal (harness-config-resolve 'harness-test-global-only outside)
                         "local")))
      (ignore-errors (delete-directory outside t))
      (ignore-errors (delete-file custom-file)))))

(ert-deftest harness-config-write-preserves-other-modes ()
  (let* ((dir (make-temp-file "harness-config-preserve-" t))
         (file (expand-file-name ".dir-locals.el" dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "((emacs-lisp-mode . ((indent-tabs-mode . nil)))\n"
                    " (nil . ((harness-test-config-setting . \"kept\"))))"))
          (harness-config-write-variable file 'harness-test-other 42)
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            (let* ((form (read (current-buffer)))
                   (nil-entry (cdr (assq nil form))))
              (should (equal (cdr (assq 'harness-test-config-setting nil-entry)) "kept"))
              (should (equal (cdr (assq 'harness-test-other nil-entry)) 42))
              (should (equal (cdr (assq 'indent-tabs-mode (cdr (assq 'emacs-lisp-mode form))))
                             nil)))))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest harness-config-cache-invalidates ()
  (let* ((dir (make-temp-file "harness-config-cache-" t))
         (file (expand-file-name ".dir-locals.el" dir)))
    (unwind-protect
        (progn
          (harness-config-write-variable file 'harness-test-config-setting "one")
          (should (equal (harness-config-resolve 'harness-test-config-setting dir) "one"))
          (harness-config-write-variable file 'harness-test-config-setting "two")
          (should (equal (harness-config-resolve 'harness-test-config-setting dir) "two")))
      (ignore-errors (delete-directory dir t)))))

(ert-deftest harness-config-service-surface ()
  (let* ((dir (make-temp-file "harness-config-service-" t)))
    (unwind-protect
        (progn
          (should (equal (harness-service-call "config" 'project-root :directory dir)
                         (file-name-as-directory dir)))
          (harness-service-call "config" 'set :variable 'harness-test-config-setting
                                :value "svc" :directory dir)
          (should (equal (harness-service-call "config" 'resolve
                                               :variable 'harness-test-config-setting
                                               :directory dir)
                         "svc"))
          (should (file-exists-p (expand-file-name ".dir-locals.el" dir)))
          (let ((description (harness-service-call "config" 'describe :directory dir)))
            (should (equal (plist-get description :directory) (file-name-as-directory dir)))))
      (ignore-errors (delete-directory dir t)))))

(provide 'harness-config-test)
;;; harness-config-test.el ends here
