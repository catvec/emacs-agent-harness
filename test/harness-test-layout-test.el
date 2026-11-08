;;; harness-test-layout-test.el --- Every test lives beside its module  -*- lexical-binding: t; -*-

;;; Commentary:

;; A module's tests live beside it, as NAME-test.el next to NAME.el, so
;; that moving or deleting the module moves or deletes its tests with
;; it.  The vendored libraries already keep to this (see
;; lisp/vendor/README.md, "Each has a test file beside it"); this suite
;; holds the harness's own modules and its plugins to it, and keeps the
;; few suites that test the repository itself from drifting into test/.
;;
;; The rule: a suite's file name carries the name of a module in its
;; own directory -- NAME-test.el for NAME.el, or NAME-ASPECT-test.el
;; for NAME.el.  A module may have more than one suite, and a suite
;; that spans modules belongs to the one it mainly tests.

;;; Code:

(require 'harness-test-helpers)

(defconst harness-test-layout--repository-suites
  '("test/harness-dev-frame-test.el"
    "test/harness-docs-test.el"
    "test/harness-test-layout-test.el"
    "test/harness-test-runner-test.el"
    "test/harness-update-test.el"
    "test/harness-voice-gate-test.el")
  "Suites that test the repository, not one of its modules.
Each is in test/ because it belongs to no module file: the dev loop's
frames, the README's pictures, this layout, the test runner itself,
`harness-update' in harness.el, and the voice gate's Python suite.  A
suite of a module does not belong here.")

(defun harness-test-layout--suites-in (dir)
  "Return the suite files directly in DIR, absolute and sorted.
A missing DIR holds none."
  (let ((full (expand-file-name dir harness-test-root)))
    (and (file-directory-p full)
         (sort (directory-files full t "-test\\.el\\'") #'string<))))

(defun harness-test-layout--subdirectories (dir)
  "Return the absolute directories directly under DIR, sorted."
  (let ((full (expand-file-name dir harness-test-root)))
    (and (file-directory-p full)
         (sort (cl-remove-if-not #'file-directory-p
                                 (directory-files full t "\\`[^.]"))
               #'string<))))

(defun harness-test-layout--suites ()
  "Return every ERT suite of the repository, absolute and sorted.
That is the modules' own beside them, the vendored libraries' beside
their libraries, the plugins', and the repository suites in test/."
  (let ((dirs (append (list (expand-file-name "lisp" harness-test-root)
                            (expand-file-name "lisp/modules" harness-test-root)
                            (expand-file-name "lisp/ui" harness-test-root)
                            (expand-file-name "test" harness-test-root))
                      (harness-test-layout--subdirectories "lisp/vendor")
                      (harness-test-layout--subdirectories ".harness/plugins"))))
    (sort (delete-dups
           (cl-loop for dir in dirs
                    append (and (file-directory-p dir)
                                (directory-files dir t "-test\\.el\\'"))))
          #'string<)))

(defun harness-test-layout--module-for (file)
  "Return the module FILE's name carries, or nil when it carries none.
The module is the longest-named source file beside FILE whose name is
FILE's name before -test, or a prefix of it followed by a dash."
  (let* ((dir (file-name-directory file))
         (base (file-name-base file))
         (want (string-remove-suffix "-test" base))
         (module nil))
    (dolist (source (directory-files dir t "\\.el\\'"))
      (unless (string-match-p "-test\\.el\\'" source)
        (let ((name (file-name-base source)))
          (when (and (or (string= want name)
                         (string-prefix-p (concat name "-") want))
                     (or (null module) (> (length name) (length module))))
            (setq module name)))))
    module))

(defun harness-test-layout--relative (file)
  "Return FILE relative to the repository."
  (file-relative-name file harness-test-root))

(ert-deftest harness-test-layout-every-suite-lives-beside-its-module ()
  "Every suite outside test/ carries the name of a module beside it."
  (let ((orphans nil)
        (known (mapcar (lambda (f) (expand-file-name f harness-test-root))
                       harness-test-layout--repository-suites)))
    (dolist (file (harness-test-layout--suites))
      (unless (member file known)
        (unless (harness-test-layout--module-for file)
          (push (harness-test-layout--relative file) orphans))))
    (should (equal nil (sort orphans #'string<)))))

(ert-deftest harness-test-layout-test-holds-only-the-repository-suites ()
  "test/ holds the repository's own suites, and no module's."
  (should (equal harness-test-layout--repository-suites
                 (mapcar #'harness-test-layout--relative
                         (harness-test-layout--suites-in "test")))))

(ert-deftest harness-test-layout-every-suite-is-in-a-known-place ()
  "No suite hides where the test runner does not look for it."
  (let ((found nil))
    (dolist (dir '("lisp" "test" ".harness" "scripts"))
      (setq found (append found
                          (and (file-directory-p (expand-file-name dir harness-test-root))
                               (directory-files-recursively
                                (expand-file-name dir harness-test-root)
                                "-test\\.el\\'")))))
    (should (equal (sort (copy-sequence (harness-test-layout--suites)) #'string<)
                   (sort (delete-dups found) #'string<)))))

(provide 'harness-test-layout-test)
;;; harness-test-layout-test.el ends here
