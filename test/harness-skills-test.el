;;; harness-skills-test.el --- Tests for skills -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-config)
(require 'harness-tools)
(require 'harness-skills)
(require 'harness-test-helpers)

(harness-module-load 'harness-config)
(harness-module-load 'harness-tools)
(harness-module-load 'harness-skills)

(defvar harness-skills-test--global nil)
(defvar harness-skills-test--root nil)

(defun harness-skills-test--setup ()
  "Create a global skill directory and a project that shadows one skill."
  (setq harness-skills-test--global (make-temp-file "harness-skills-global-" t)
        harness-skills-test--root (make-temp-file "harness-skills-project-" t))
  (make-directory (expand-file-name ".git" harness-skills-test--root) t)
  (dolist (spec (list (cons "alpha/SKILL.md"
                            "---\nname: alpha\ndescription: Global alpha skill\n---\nDo the alpha thing.")
                      (cons "beta.md" "Beta instructions on the first line.")))
    (let ((file (expand-file-name (car spec) harness-skills-test--global)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert (cdr spec)))))
  (dolist (spec (list (cons "alpha.md" "---\nname: alpha\ndescription: Project alpha skill\n---\nDo the project alpha.")
                      (cons "gamma.md" "---\nname: gamma\ndescription: Project gamma\n---\nGamma steps.")))
    (let ((file (expand-file-name (concat ".harness/skills/" (car spec)) harness-skills-test--root)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert (cdr spec)))))
  (list harness-skills-test--root (expand-file-name "nested" harness-skills-test--root)))

(defun harness-skills-test--cleanup ()
  "Delete the temporary skill directories."
  (dolist (dir (list harness-skills-test--global harness-skills-test--root))
    (when (file-directory-p dir) (delete-directory dir t)))
  (setq harness-skills-test--global nil harness-skills-test--root nil))

(defmacro harness-skills-test--with-skills (&rest body)
  "Run BODY with isolated skill directories."
  (declare (indent 0))
  `(let ((harness-skills-directories (list harness-skills-test--global)))
     (unwind-protect (progn ,@body)
       (harness-skills-test--cleanup))))

(defun harness-skills-test--list (&optional cwd)
  "List skills visible from CWD."
  (harness-skills-list (or cwd harness-skills-test--root)))

(ert-deftest harness-skills-list-and-shadowing ()
  (pcase-let ((`(,root ,nested) (harness-skills-test--setup)))
    (make-directory nested t)
    (harness-skills-test--with-skills
      (let ((names (mapcar (lambda (skill) (plist-get skill :name))
                           (harness-skills-test--list nested))))
        (should (member "alpha" names))
        (should (member "beta" names))
        (should (member "gamma" names)))
      ;; The project definition of alpha shadows the global one.
      (let ((alpha (harness-skills-load "alpha" nested)))
        (should (equal (plist-get alpha :description) "Project alpha skill"))
        (should (string-match-p "project alpha" (plist-get alpha :content))))
      ;; Outside the project the global alpha is used.
      (let ((alpha (harness-skills-load "alpha" harness-skills-test--global)))
        (should (equal (plist-get alpha :description) "Global alpha skill"))))))

(ert-deftest harness-skills-parse-front-matter ()
  (pcase-let ((`(,root ,_nested) (harness-skills-test--setup)))
    (harness-skills-test--with-skills
      (let* ((file (expand-file-name "manual.md" root))
             (parsed nil))
        (with-temp-file file (insert "---\nname: manual\ndescription: Written by hand\n---\nBody here."))
        (setq parsed (harness-skills-parse file))
        (should (equal (plist-get parsed :name) "manual"))
        (should (equal (plist-get parsed :description) "Written by hand"))
        (should (equal (plist-get parsed :content) "Body here."))
        ;; Without front matter the file name and first line are used.
        (with-temp-file (expand-file-name "plain.md" harness-skills-test--global)
          (insert "Just instructions\nMore."))
        (let ((plain (harness-skills-parse (expand-file-name "plain.md" harness-skills-test--global))))
          (should (equal (plist-get plain :name) "plain"))
          (should (equal (plist-get plain :description) "Just instructions")))))))

(ert-deftest harness-skills-tools ()
  (pcase-let ((`(,root ,_nested) (harness-skills-test--setup)))
    (harness-skills-test--with-skills
      (let* ((context (harness-tool-context-create :session-id "s1" :cwd root)))
        ;; Search.
        (let* ((deferred (harness-tools-execute "skills" '(:query "gamma") context))
               (result (progn (harness-test-settle deferred)
                              (harness-deferred-value deferred))))
          (should (string-match-p "gamma" (harness-tools--text-of (plist-get result :content))))
          (should-not (string-match-p "beta" (harness-tools--text-of (plist-get result :content)))))
        ;; Load.
        (let* ((deferred (harness-tools-execute "skill" '(:name "gamma") context))
               (result (progn (harness-test-settle deferred)
                              (harness-deferred-value deferred))))
          (should (string-match-p "Gamma steps" (harness-tools--text-of (plist-get result :content)))))
        ;; Unknown skill is an error result that lists what exists.
        (let* ((deferred (harness-tools-execute "skill" '(:name "nope") context))
               (result (progn (harness-test-settle deferred)
                              (harness-deferred-value deferred))))
          (should (plist-get result :is-error))
          (should (string-match-p "alpha" (harness-tools--text-of (plist-get result :content)))))))))

(ert-deftest harness-skills-service ()
  (pcase-let ((`(,root ,_nested) (harness-skills-test--setup)))
    (harness-skills-test--with-skills
      (let ((listed (harness-service-call "skill" 'list :cwd root)))
        (should (vectorp listed))
        (should (> (length listed) 0)))
      (let ((loaded (harness-service-call "skill" 'load :name "beta" :cwd root)))
        (should (equal (plist-get loaded :name) "beta")))
      (should-error (harness-service-call "skill" 'load :name "nope" :cwd root)
                    :type 'harness-user-error))))

(ert-deftest harness-skills-teardown-removes-tools ()
  (harness-module-load 'harness-skills)
  (should (harness-tool-get "skills"))
  (harness-module-unload 'harness-skills)
  (should-not (harness-tool-get "skills"))
  (harness-module-load 'harness-skills))

(provide 'harness-skills-test)
;;; harness-skills-test.el ends here
