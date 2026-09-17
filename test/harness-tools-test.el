;;; harness-tools-test.el --- Tests for the tool registry and built-ins -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; This file is not part of GNU Emacs.

;;; Code:

(require 'ert)
(require 'harness-tools)
(require 'harness-test-util)

(defun harness-tools-test--call (name args &optional session)
  "Run tool NAME with ARGS and return the finished tool call.
Waits for asynchronous tools to finish."
  (let* ((tool-call (harness-tool-call-create
                     :name name
                     :args-string (harness-json-write args)))
         (finished nil))
    (harness-tool-run tool-call session (lambda (call) (setq finished call)))
    (should (harness-test-wait-for (lambda () finished) 20))
    finished))

(defun harness-tools-test--output (call)
  "Return the model-facing output of CALL."
  (harness-tool-call-output call))

(defmacro harness-tools-test-with-dir (&rest body)
  "Run BODY with a temporary project directory."
  (declare (indent 0))
  `(let* ((harness-tools--directory (make-temp-file "harness-tools" t))
          (default-directory (file-name-as-directory harness-tools--directory)))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-directory harness-tools--directory t)))))

(defun harness-tools-test--write (name content)
  "Write CONTENT to NAME in the current test directory."
  (let ((path (expand-file-name name default-directory)))
    (make-directory (file-name-directory path) t)
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region content nil path nil 'silent))
    path))


;;; Registry

(ert-deftest harness-tools-test-registry ()
  "Tools register, are found by name and appear in the model's tool list."
  (harness-define-tool "harness-test-echo"
    :description "Echo the input"
    :parameters '(:type "object" :properties (:text (:type "string")))
    :category 'read
    :read-only t
    :approval 'allow
    :function (lambda (args _context)
                (harness-tool-result-create
                 :content (harness-tools-arg args :text))))
  (let ((tool (harness-tool-get "harness-test-echo")))
    (should tool)
    (should (equal (harness-tool-category tool) 'read))
    (should (harness-tool-read-only tool))
    (let ((spec (cl-find-if (lambda (spec)
                              (equal (harness-alist-get :name (harness-alist-get :function spec))
                                     "harness-test-echo"))
                            (harness-tools-specs))))
      (should spec)
      (should (equal (harness-alist-get :description (harness-alist-get :function spec))
                     "Echo the input")))))

(ert-deftest harness-tools-test-schemas-encode-as-objects ()
  "Tool parameter plists serialise as JSON objects, not arrays.
This is the regression test for the plist schema choice."
  (let* ((specs (harness-tools-specs))
         (round-tripped (harness-json-read (harness-json-write specs)))
         (bash (cl-find-if (lambda (spec)
                             (equal (harness-alist-get :name (harness-alist-get :function spec))
                                    "bash"))
                           round-tripped))
         (parameters (harness-alist-get :parameters (harness-alist-get :function bash))))
    (should (equal (harness-alist-get :type parameters) "object"))
    (should (harness-alist-get :properties parameters))
    (should (equal (harness-alist-get :required parameters) '("command")))))

(ert-deftest harness-tools-test-enabled-functions ()
  "The enablement hook can hide tools from a session."
  (let ((harness-tool-enabled-functions
         (list (lambda (tool _session)
                 (not (equal (harness-tool-category tool) 'execute))))))
    (should-not (cl-find-if (lambda (spec)
                              (equal (harness-alist-get :name (harness-alist-get :function spec))
                                     "bash"))
                            (harness-tools-specs)))
    (should (cl-find-if (lambda (spec)
                          (equal (harness-alist-get :name (harness-alist-get :function spec))
                                 "read"))
                        (harness-tools-specs)))))

(ert-deftest harness-tools-test-unknown-tool ()
  "Calling an unknown tool is an error result, not a signal."
  (harness-tools-test-with-dir
    (let ((call (harness-tools-test--call "no-such-tool" '(:x 1))))
      (should (eq (harness-tool-call-status call) 'error))
      (should (string-match-p "Unknown tool" (harness-tools-test--output call))))))

(ert-deftest harness-tools-test-tool-error-is-captured ()
  "A tool that signals becomes an error result with a message."
  (harness-define-tool "harness-test-explode"
    :description "Always fails"
    :function (lambda (_args _context) (error "boom")))
  (harness-tools-test-with-dir
    (let ((call (harness-tools-test--call "harness-test-explode" nil)))
      (should (eq (harness-tool-call-status call) 'error))
      (should (string-match-p "boom" (harness-tools-test--output call))))))


;;; File tools

(ert-deftest harness-tools-test-read ()
  "read returns numbered lines and honours offset and limit."
  (harness-tools-test-with-dir
    (harness-tools-test--write "a.txt" "one\ntwo\nthree\nfour\n")
    (let ((all (harness-tools-test--call "read" '(:file_path "a.txt")))
          (some (harness-tools-test--call "read" '(:file_path "a.txt" :offset 2 :limit 2))))
      (should (eq (harness-tool-call-status all) 'ok))
      (should (string-match-p "1\tone" (harness-tools-test--output all)))
      (should (string-match-p "4\tfour" (harness-tools-test--output all)))
      (should (string-match-p "2\ttwo" (harness-tools-test--output some)))
      (should (string-match-p "3\tthree" (harness-tools-test--output some)))
      (should-not (string-match-p "four" (harness-tools-test--output some))))))

(ert-deftest harness-tools-test-read-missing ()
  "read reports a missing file without signalling."
  (harness-tools-test-with-dir
    (let ((call (harness-tools-test--call "read" '(:file_path "nope.txt"))))
      (should (eq (harness-tool-call-status call) 'error))
      (should (string-match-p "No such file" (harness-tools-test--output call))))))

(ert-deftest harness-tools-test-write ()
  "write creates parent directories and records old content for the diff."
  (harness-tools-test-with-dir
    (let ((created (harness-tools-test--call "write" '(:file_path "deep/dir/x.txt"
                                                                 :content "hello"))))
      (should (eq (harness-tool-call-status created) 'ok))
      (should (equal (with-temp-buffer
                       (insert-file-contents (expand-file-name "deep/dir/x.txt"
                                                               default-directory))
                       (buffer-string))
                     "hello"))
      (should-not (plist-get (harness-tool-call-detail created) :old))
      (let ((rewritten (harness-tools-test--call "write" '(:file_path "deep/dir/x.txt"
                                                                     :content "bye"))))
        (should (equal (plist-get (harness-tool-call-detail rewritten) :old) "hello"))
        (should (equal (plist-get (harness-tool-call-detail rewritten) :new) "bye"))
        (should (eq (plist-get (harness-tool-call-detail rewritten) :action) 'write))))))

(ert-deftest harness-tools-test-edit ()
  "edit replaces exactly, refuses ambiguity, and supports replace_all."
  (harness-tools-test-with-dir
    (harness-tools-test--write "e.txt" "alpha\nbeta\ngamma\n")
    (let ((ok (harness-tools-test--call "edit" '(:file_path "e.txt"
                                                           :old_string "beta"
                                                           :new_string "BETA"))))
      (should (eq (harness-tool-call-status ok) 'ok))
      (should (string-match-p "BETA" (with-temp-buffer
                                       (insert-file-contents (expand-file-name "e.txt"
                                                                               default-directory))
                                       (buffer-string))))
      (should (equal (plist-get (harness-tool-call-detail ok) :new) "BETA"))
      (should (equal (plist-get (harness-tool-call-detail ok) :line) 2)))
    (harness-tools-test--write "dup.txt" "x\nx\n")
    (let ((ambiguous (harness-tools-test--call "edit" '(:file_path "dup.txt"
                                                                  :old_string "x"
                                                                  :new_string "y")))
          (all (harness-tools-test--call "edit" '(:file_path "dup.txt"
                                                            :old_string "x"
                                                            :new_string "y"
                                                            :replace_all t))))
      (should (eq (harness-tool-call-status ambiguous) 'error))
      (should (string-match-p "appears 2 times" (harness-tools-test--output ambiguous)))
      (should (eq (harness-tool-call-status all) 'ok))
      (should (string-match-p "Replaced 2 occurrences" (harness-tools-test--output all))))
    (let ((missing (harness-tools-test--call "edit" '(:file_path "dup.txt"
                                                                :old_string "zzz"
                                                                :new_string "y"))))
      (should (eq (harness-tool-call-status missing) 'error))
      (should (string-match-p "not found" (harness-tools-test--output missing))))))

(ert-deftest harness-tools-test-glob ()
  "glob finds files by pattern relative to the project."
  (harness-tools-test-with-dir
    (harness-tools-test--write "src/a.el" "")
    (harness-tools-test--write "src/deep/b.el" "")
    (harness-tools-test--write "src/c.txt" "")
    (let ((elisp (harness-tools-test--call "glob" '(:pattern "**/*.el"))))
      (should (string-match-p "src/a.el" (harness-tools-test--output elisp)))
      (should (string-match-p "src/deep/b.el" (harness-tools-test--output elisp)))
      (should-not (string-match-p "c.txt" (harness-tools-test--output elisp))))
    (let ((txt (harness-tools-test--call "glob" '(:pattern "*.txt"))))
      (should (string-match-p "src/c.txt" (harness-tools-test--output txt))))))

(ert-deftest harness-tools-test-grep ()
  "grep finds matching lines asynchronously."
  (harness-tools-test-with-dir
    (harness-tools-test--write "src/a.el" "(defun needle ())\n(other)\n")
    (harness-tools-test--write "src/b.el" "(nothing here)\n")
    (let ((hit (harness-tools-test--call "grep" '(:pattern "needle")))
          (miss (harness-tools-test--call "grep" '(:pattern "haystack"))))
      (should (eq (harness-tool-call-status hit) 'ok))
      (should (string-match-p "needle" (harness-tools-test--output hit)))
      (should (string-match-p "a\\.el" (harness-tools-test--output hit)))
      (should (string-match-p "No matches" (harness-tools-test--output miss))))))

(ert-deftest harness-tools-test-bash ()
  "bash runs in the project directory and reports the exit code."
  (harness-tools-test-with-dir
    (harness-tools-test--write "marker.txt" "here")
    (let ((ok (harness-tools-test--call "bash" '(:command "cat marker.txt"))))
      (should (eq (harness-tool-call-status ok) 'ok))
      (should (string-match-p "here" (harness-tools-test--output ok)))
      (should (string-match-p "(exit 0)" (harness-tools-test--output ok))))
    (let ((bad (harness-tools-test--call "bash" '(:command "exit 3"))))
      (should (eq (harness-tool-call-status bad) 'error))
      (should (equal (harness-tool-call-error bad) "exit code 3")))))

(ert-deftest harness-tools-test-bash-timeout ()
  "A command that outlives its timeout is killed and reported."
  (harness-tools-test-with-dir
    (let* ((harness-bash-timeout 1)
           (call (harness-tools-test--call "bash" '(:command "sleep 30"))))
      (should (eq (harness-tool-call-status call) 'error))
      (should (string-match-p "timed out" (harness-tool-call-error call))))))

(ert-deftest harness-tools-test-bash-output-is-capped ()
  "Runaway output is truncated before it becomes a message."
  (harness-tools-test-with-dir
    (let* ((harness-tool-max-output 2000)
           (call (harness-tools-test--call
                  "bash" '(:command "i=0; while [ $i -lt 500 ]; do echo aaaaaaaaaaaaaaaaaaaa; i=$((i+1)); done"))))
      (should (< (length (harness-tools-test--output call)) 4000))
      (should (string-match-p "truncated" (harness-tools-test--output call))))))


;;; Session tools

(ert-deftest harness-tools-test-todo ()
  "todo replaces the session's task list and records it in meta."
  (harness-test-with-temp-session-dir
    (let* ((session (harness-session-create '(:name "todo test")))
           (call (harness-tools-test--call
                  "todo"
                  ;; An array of objects must be a vector; see `harness-json-array'.
                  (list :todos (vector '(:text "first" :status "completed")
                                       '(:text "second" :status "in_progress")
                                       '(:text "third" :status "pending")))
                  session)))
      (should (eq (harness-tool-call-status call) 'ok))
      (should (string-match-p "\\[x\\] first" (harness-tools-test--output call)))
      (should (string-match-p "\\[~\\] second" (harness-tools-test--output call)))
      (should (equal (mapcar (lambda (todo) (harness-plist-or-alist-get :text todo))
                             (harness-session-todos session))
                     '("first" "second" "third")))
      (should (equal (plist-get (harness-tool-call-detail call) :kind) 'todo)))))

(provide 'harness-tools-test)
;;; harness-tools-test.el ends here
