;;; harness-tools-emacs-test.el --- Tests for the built-in tools -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-tools)
(require 'harness-tools-emacs)
(require 'harness-sandbox)
(require 'harness-test-helpers)

(harness-module-load 'harness-sandbox)
(harness-module-load 'harness-tools)
(harness-module-load 'harness-tools-emacs)

(defvar harness-tools-emacs-test--calls nil)

(defun harness-tools-emacs-test--context (directory &optional session-id)
  "Build a tool context rooted at DIRECTORY."
  (harness-tool-context-create
   :session-id (or session-id "test-session")
   :cwd directory
   :abort (harness-deferred-new)))

(defun harness-tools-emacs-test--run (name arguments directory &optional session-id)
  "Execute tool NAME with ARGUMENTS in DIRECTORY."
  (let ((deferred (harness-tools-execute
                   name arguments
                   (harness-tools-emacs-test--context directory session-id))))
    (harness-test-settle deferred 30)
    (harness-deferred-value deferred)))

(defun harness-tools-emacs-test--text (result)
  "Return the text of RESULT."
  (harness-tools--text-of (plist-get result :content)))

(defmacro harness-tools-emacs-test--with-directory (&rest body)
  "Run BODY with `test-directory' bound to a fresh temp directory."
  (declare (indent 0))
  `(let ((test-directory (make-temp-file "harness-tools-" t)))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-directory test-directory t)))))

(defun harness-tools-emacs-test--write (directory path content)
  "Write CONTENT to PATH under DIRECTORY."
  (let ((full (expand-file-name path directory)))
    (make-directory (file-name-directory full) t)
    (with-temp-file full (insert content))
    full))

;;; read

(ert-deftest harness-tools-emacs-read ()
  (harness-tools-emacs-test--with-directory
    (harness-tools-emacs-test--write test-directory "file.txt" "one\ntwo\nthree\n")
    (let ((result (harness-tools-emacs-test--run "read" '(:path "file.txt") test-directory)))
      (should-not (plist-get result :is-error))
      (should (string-match-p "file.txt (3 lines)" (harness-tools-emacs-test--text result)))
      (should (string-match-p "1\tone" (harness-tools-emacs-test--text result)))
      (should (string-match-p "3\tthree" (harness-tools-emacs-test--text result))))
    (let ((result (harness-tools-emacs-test--run "read" '(:path "file.txt" :offset 2 :limit 1)
                                                 test-directory)))
      (should (string-match-p "2\ttwo" (harness-tools-emacs-test--text result)))
      (should-not (string-match-p "three" (harness-tools-emacs-test--text result)))
      (should (string-match-p "offset=3" (harness-tools-emacs-test--text result))))
    (let ((result (harness-tools-emacs-test--run "read" '(:path "nope.txt") test-directory)))
      (should (plist-get result :is-error)))))

;;; write

(ert-deftest harness-tools-emacs-write ()
  (harness-tools-emacs-test--with-directory
    (let ((result (harness-tools-emacs-test--run "write"
                                                 '(:path "a/b/c.txt" :content "hello")
                                                 test-directory)))
      (should-not (plist-get result :is-error))
      (should (equal (with-temp-buffer
                       (insert-file-contents (expand-file-name "a/b/c.txt" test-directory))
                       (buffer-string))
                     "hello"))
      (should (string-match-p "Wrote 5 bytes" (harness-tools-emacs-test--text result))))))

;;; edit

(ert-deftest harness-tools-emacs-edit ()
  (harness-tools-emacs-test--with-directory
    (harness-tools-emacs-test--write test-directory "code.el" "(defun a () 1)\n(defun b () 2)\n")
    ;; Unique replacement.
    (let ((result (harness-tools-emacs-test--run
                   "edit" '(:path "code.el" :oldText "(defun a () 1)" :newText "(defun a () 42)")
                   test-directory)))
      (should-not (plist-get result :is-error))
      (should (string-match-p "Replaced 1 occurrence" (harness-tools-emacs-test--text result)))
      (should (string-match-p "42"
                              (with-temp-buffer
                                (insert-file-contents (expand-file-name "code.el" test-directory))
                                (buffer-string)))))
    ;; Missing text.
    (let ((result (harness-tools-emacs-test--run
                   "edit" '(:path "code.el" :oldText "not there" :newText "x")
                   test-directory)))
      (should (plist-get result :is-error)))
    ;; Ambiguous text.
    (harness-tools-emacs-test--write test-directory "dup.txt" "same\nsame\n")
    (let ((result (harness-tools-emacs-test--run
                   "edit" '(:path "dup.txt" :oldText "same" :newText "different")
                   test-directory)))
      (should (plist-get result :is-error))
      (should (string-match-p "occurs 2 times" (harness-tools-emacs-test--text result))))
    ;; replaceAll.
    (let ((result (harness-tools-emacs-test--run
                   "edit" '(:path "dup.txt" :oldText "same" :newText "different" :replaceAll t)
                   test-directory)))
      (should-not (plist-get result :is-error))
      (should (string-match-p "different\ndifferent"
                              (with-temp-buffer
                                (insert-file-contents (expand-file-name "dup.txt" test-directory))
                                (buffer-string)))))))

;;; list and glob

(ert-deftest harness-tools-emacs-list-and-glob ()
  (harness-tools-emacs-test--with-directory
    (harness-tools-emacs-test--write test-directory "src/main.el" "(provide 'main)")
    (harness-tools-emacs-test--write test-directory "src/util/helper.el" "(provide 'helper)")
    (harness-tools-emacs-test--write test-directory "README.md" "docs")
    (let* ((result (harness-tools-emacs-test--run "list" '(:path ".") test-directory))
           (text (harness-tools-emacs-test--text result)))
      (should (string-match-p "src/" text))
      (should (string-match-p "README.md" text))
      (should-not (string-match-p "helper.el" text)))
    (let* ((result (harness-tools-emacs-test--run "list" '(:path "." :depth 3) test-directory))
           (text (harness-tools-emacs-test--text result)))
      (should (string-match-p "src/util/helper.el" text)))
    (let* ((result (harness-tools-emacs-test--run "glob" '(:pattern "**/*.el") test-directory))
           (text (harness-tools-emacs-test--text result)))
      (should (string-match-p "src/main.el" text))
      (should (string-match-p "src/util/helper.el" text))
      (should-not (string-match-p "README" text)))
    (let* ((result (harness-tools-emacs-test--run "glob" '(:pattern "*.md") test-directory))
           (text (harness-tools-emacs-test--text result)))
      (should (string-match-p "README.md" text))
      (should-not (string-match-p "main.el" text)))))

;;; search

(ert-deftest harness-tools-emacs-search-finds-matches ()
  (harness-tools-emacs-test--with-directory
    (harness-tools-emacs-test--write test-directory "a.el" "(defun alpha ())\n")
    (harness-tools-emacs-test--write test-directory "b.el" "(defun beta ())\n")
    (let* ((result (harness-tools-emacs-test--run "search" '(:pattern "defun") test-directory))
           (text (harness-tools-emacs-test--text result)))
      (should-not (plist-get result :is-error))
      (should (string-match-p "a\\.el:1:.*alpha" text))
      (should (string-match-p "b\\.el:1:.*beta" text)))
    (let* ((result (harness-tools-emacs-test--run "search"
                                                  '(:pattern "defun" :glob "*.el")
                                                  test-directory))
           (text (harness-tools-emacs-test--text result)))
      (should (string-match-p "a\\.el" text)))
    (let* ((result (harness-tools-emacs-test--run "search" '(:pattern "nothing-here") test-directory))
           (text (harness-tools-emacs-test--text result)))
      (should (string-match-p "No matches" text)))))

(ert-deftest harness-tools-emacs-search-elisp-fallback ()
  (harness-tools-emacs-test--with-directory
    (harness-tools-emacs-test--write test-directory "a.el" "(defun alpha ())\n")
    (let ((result (cl-letf (((symbol-function 'executable-find)
                             (lambda (_program) nil)))
                    (harness-tools-emacs-test--run "search" '(:pattern "alpha") test-directory))))
      (should (string-match-p "a\\.el:1" (harness-tools-emacs-test--text result))))))

;;; bash

(ert-deftest harness-tools-emacs-bash-basic ()
  (harness-tools-emacs-test--with-directory
    (let* ((result (harness-tools-emacs-test--run "bash" '(:command "echo hello; pwd") test-directory))
           (text (harness-tools-emacs-test--text result)))
      (should-not (plist-get result :is-error))
      (should (string-match-p "exit code: 0" text))
      (should (string-match-p "hello" text))
      (should (string-match-p (regexp-quote (directory-file-name test-directory)) text)))
    (let* ((result (harness-tools-emacs-test--run "bash" '(:command "exit 3") test-directory))
           (text (harness-tools-emacs-test--text result)))
      (should (string-match-p "exit code: 3" text)))))

(ert-deftest harness-tools-emacs-bash-timeout ()
  (harness-tools-emacs-test--with-directory
    (let* ((result (harness-tools-emacs-test--run
                    "bash" '(:command "sleep 10" :timeout 1) test-directory))
           (text (harness-tools-emacs-test--text result)))
      (should (string-match-p "timed out" text)))))

(ert-deftest harness-tools-emacs-bash-output-cap ()
  (harness-tools-emacs-test--with-directory
    (let ((harness-tools-emacs-bash-max-output 100))
      (let* ((result (harness-tools-emacs-test--run
                      "bash"
                      '(:command "i=0; while [ $i -lt 1000 ]; do printf a; i=$((i+1)); done")
                      test-directory))
             (text (harness-tools-emacs-test--text result)))
        (should (string-match-p "output truncated" text))
        (should (< (length text) 1000))))))

(ert-deftest harness-tools-emacs-bash-runs-in-the-sandbox ()
  (skip-unless (harness-sandbox-backend-usable-p 'bwrap))
  (harness-tools-emacs-test--with-directory
    (let* ((result (harness-tools-emacs-test--run
                    "bash"
                    '(:command "echo home=$HOME; touch /usr/nope 2>/dev/null && echo writable || echo read-only")
                    test-directory))
           (text (harness-tools-emacs-test--text result)))
      (should (string-match-p "home=/tmp" text))
      (should (string-match-p "read-only" text)))))

;;; emacs-eval and emacs-describe

(ert-deftest harness-tools-emacs-eval ()
  (harness-tools-emacs-test--with-directory
    (let ((result (harness-tools-emacs-test--run "emacs-eval" '(:expression "(+ 1 2)")
                                                  test-directory)))
      (should (equal (string-trim (harness-tools-emacs-test--text result)) "3")))
    (let ((result (harness-tools-emacs-test--run "emacs-eval" '(:expression "(error \"nope\")")
                                                 test-directory)))
      (should (plist-get result :is-error))
      (should (string-match-p "nope" (harness-tools-emacs-test--text result))))))

(ert-deftest harness-tools-emacs-describe ()
  (harness-tools-emacs-test--with-directory
    (let ((result (harness-tools-emacs-test--run
                   "emacs-describe" '(:name "message" :type "function") test-directory)))
      (should (string-match-p "message" (harness-tools-emacs-test--text result))))
    (let ((result (harness-tools-emacs-test--run
                   "emacs-describe" '(:name "emacs-version" :type "variable") test-directory)))
      (should (string-match-p "Value:" (harness-tools-emacs-test--text result))))
    (let ((result (harness-tools-emacs-test--run
                   "emacs-describe" '(:name "no-such-thing-xyz" :type "function")
                   test-directory)))
      (should (plist-get result :is-error)))))

;;; todo

(ert-deftest harness-tools-emacs-todo ()
  (harness-tools-emacs-test--with-directory
    (setq harness-tools-emacs-test--calls nil)
    (let ((harness-tools-emacs-test--calls nil))
      (harness-service-register
       "session"
       :module 'harness-tools-emacs-test
       :methods
       '((state-set . (lambda (&rest args)
                        (push (cons 'state-set args) harness-tools-emacs-test--calls)))
         (append . (lambda (&rest args)
                     (push (cons 'append args) harness-tools-emacs-test--calls)))))
      (unwind-protect
          (let* ((todos (vector (list :content "Do the thing" :status "pending")
                                (list :content "Done thing" :status "completed")))
                 (result (harness-tools-emacs-test--run "todo" (list :todos todos)
                                                        test-directory "sess-1"))
                 (text (harness-tools-emacs-test--text result)))
            (should (string-match-p "\\[ \\] Do the thing" text))
            (should (string-match-p "\\[x\\] Done thing" text))
            (should (equal (length harness-tools-emacs-test--calls) 2))
            (should (equal (plist-get (cdr (assq 'state-set harness-tools-emacs-test--calls))
                                      :key)
                           'todos))
            (should (equal (plist-get (cdr (assq 'append harness-tools-emacs-test--calls))
                                      :session-id)
                           "sess-1")))
        (harness-service-unregister "session")))))

;;; registration details

(ert-deftest harness-tools-emacs-access-descriptors ()
  (let ((tool (harness-tool-get "read")))
    (should (equal (funcall (harness-tool-access-fn tool) '(:path "x.txt"))
                   '((:path "x.txt" :mode "read")))))
  (let ((tool (harness-tool-get "write")))
    (should (equal (funcall (harness-tool-access-fn tool) '(:path "x.txt"))
                   '((:path "x.txt" :mode "write"))))))

(ert-deftest harness-tools-emacs-teardown-removes-tools ()
  (harness-module-load 'harness-tools-emacs)
  (should (harness-tool-get "read"))
  (harness-module-unload 'harness-tools-emacs)
  (should-not (harness-tool-get "read"))
  ;; Restore for any test that runs afterwards.
  (harness-module-load 'harness-tools-emacs))

(provide 'harness-tools-emacs-test)
;;; harness-tools-emacs-test.el ends here
