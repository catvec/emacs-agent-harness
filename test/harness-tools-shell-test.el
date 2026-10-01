;;; harness-tools-shell-test.el --- Tests for the bash and elisp tools  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defun harness-tools-shell-test--allow (_decision next &rest _)
  "Permissive permission filter for tests."
  (funcall next (list :behavior 'allow)))

(defun harness-tools-shell-test--setup ()
  "Load the tools modules and allow everything."
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-shell)
  (harness-test-connect-ui-client)
  (harness-add-filter 'permission/decide #'harness-tools-shell-test--allow 10))

(defun harness-tools-shell-test--call (name &rest input)
  "Execute tool NAME with INPUT through tools/execute and wait."
  (harness-await (harness-call 'tools/execute nil (list :id "c1" :name name :input input)) 20))

(defmacro harness-tools-shell-test-in-dir (&rest body)
  "Run BODY with `default-directory' bound to a fresh temp dir named ROOT."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let* ((root (harness-test-temp-dir))
            (default-directory root))
       (unwind-protect (progn ,@body)
         (delete-directory root t)))))

;;;; bash

(ert-deftest harness-tools-shell-bash-output-and-exit-codes ()
  (harness-tools-shell-test--setup)
  (harness-tools-shell-test-in-dir
    (let ((r (harness-tools-shell-test--call "bash" :command "echo hi")))
      (should-not (plist-get r :is-error))
      (should (equal "hi\nexit 0" (plist-get r :content)))
      (should (eql 0 (plist-get (plist-get r :meta) :exit))))
    (let ((r (harness-tools-shell-test--call "bash" :command "echo out; echo err >&2; exit 3")))
      (should (plist-get r :is-error))
      (should (equal "out\n--- stderr ---\nerr\nexit 3" (plist-get r :content)))
      (should (eql 3 (plist-get (plist-get r :meta) :exit))))
    ;; No output at all still reports the exit line.
    (should (equal "exit 0" (plist-get (harness-tools-shell-test--call "bash" :command "true") :content)))
    ;; Runs in the session cwd, and in a relative subdirectory when asked.
    (should (equal (concat (directory-file-name (file-truename root)) "\nexit 0")
                   (plist-get (harness-tools-shell-test--call "bash" :command "pwd -P") :content)))
    (make-directory (expand-file-name "sub" root))
    (should (string-prefix-p (directory-file-name (file-truename (expand-file-name "sub" root)))
                             (plist-get (harness-tools-shell-test--call "bash" :command "pwd -P" :cwd "sub") :content)))
    (should (plist-get (harness-tools-shell-test--call "bash" :command "pwd" :cwd "nope") :is-error))
    (should (plist-get (harness-tools-shell-test--call "bash" :command "") :is-error))
    (should (equal "bash echo hi" (harness-tool-title "bash" '(:command "echo hi\nsecond"))))
    (should (eq 'exec (harness-tool-kind (harness-tool-get "bash"))))
    (should (equal '("sub") (funcall (harness-tool-paths-fn (harness-tool-get "bash")) '(:command "x" :cwd "sub"))))
    (should (equal '(".") (funcall (harness-tool-paths-fn (harness-tool-get "bash")) '(:command "x"))))))

(ert-deftest harness-tools-shell-bash-timeout ()
  (harness-tools-shell-test--setup)
  (harness-tools-shell-test-in-dir
    (let* ((start (float-time))
           (r (harness-tools-shell-test--call "bash" :command "echo start; sleep 10; echo never" :timeout 1)))
      (should (plist-get r :is-error))
      (should (< (- (float-time) start) 8))
      (should (string-search "start" (plist-get r :content)))
      (should-not (string-search "never" (plist-get r :content)))
      (should (string-search "killed after 1s timeout" (plist-get r :content)))
      (should (eq 'timeout (plist-get (plist-get r :meta) :exit))))))

(ert-deftest harness-tools-shell-bash-is-async ()
  (harness-tools-shell-test--setup)
  (harness-tools-shell-test-in-dir
    (let ((p (harness-call 'tools/execute nil (list :id "c9" :name "bash" :input (list :command "sleep 0.3; echo done")))))
      (should (harness-promise-p p))
      (should-not (harness-promise-settled-p p))
      (should (equal "done\nexit 0" (plist-get (harness-await p) :content))))))

(ert-deftest harness-tools-shell-bash-reports-progress ()
  (harness-tools-shell-test--setup)
  (harness-tools-shell-test-in-dir
    (let (chunks)
      (harness-on 'tools/progress (lambda (_sid _cid text) (push text chunks)))
      (harness-tools-shell-test--call "bash" :command "echo one; echo two")
      (should (string-search "one" (apply #'concat (reverse chunks)))))))

(ert-deftest harness-tools-shell-bash-sandbox-required-without-backend ()
  "With the sandbox loaded, a required policy and no backend, bash refuses."
  (harness-tools-shell-test--setup)
  (harness-test-load-module 'project)
  (harness-test-load-module 'config)
  (harness-test-load-module 'sandbox)
  (harness-tools-shell-test-in-dir
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
          (harness-sandbox-detect)
          (let* ((harness-sandbox-policy 'required)
                 (r (harness-tools-shell-test--call "bash" :command "echo leaked")))
            (should (plist-get r :is-error))
            (should (string-search "Cannot run command" (plist-get r :content)))
            (should-not (string-search "leaked" (plist-get r :content))))
          ;; preferred without a backend runs plain.
          (let ((harness-sandbox-policy 'preferred))
            (should (equal "ok\nexit 0" (plist-get (harness-tools-shell-test--call "bash" :command "echo ok") :content)))))
      (harness-sandbox-detect))))

(ert-deftest harness-tools-shell-bash-runs-inside-bwrap ()
  "With bwrap available the command sees the sandbox HOME, not the real one."
  (harness-tools-shell-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-test-load-module 'project)
  (harness-test-load-module 'config)
  (harness-test-load-module 'sandbox)
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (harness-tools-shell-test-in-dir
    (let* ((harness-sandbox-policy 'required)
           (r (harness-tools-shell-test--call "bash" :command (format "echo HOME=$HOME; ls %s >/dev/null 2>&1 && echo visible || echo hidden" (getenv "HOME")))))
      (when (and (plist-get r :is-error) (string-search "bwrap:" (plist-get r :content)))
        (ert-skip (format "bwrap cannot start in this environment: %s" (plist-get r :content))))
      (should-not (plist-get r :is-error))
      (should (string-search (concat "HOME=" harness-sandbox-home) (plist-get r :content)))
      (should (string-search "hidden" (plist-get r :content)))
      (should (plist-get (plist-get r :meta) :sandboxed)))))

;;;; elisp

(ert-deftest harness-tools-shell-elisp-values-output-and-messages ()
  (harness-tools-shell-test--setup)
  (harness-test-with-temp-state
    (let ((r (harness-tools-shell-test--call "elisp" :code "(+ 1 2)")))
      (should-not (plist-get r :is-error))
      (should (equal "=> 3" (plist-get r :content))))
    ;; Several forms: the last value wins; lexical binding is on.
    (should (equal "=> 5" (plist-get (harness-tools-shell-test--call
                                      "elisp" :code "(setq harness-test--unused 1) (let ((f (let ((y 5)) (lambda () y)))) (funcall f))")
                                     :content)))
    (let* ((r (harness-tools-shell-test--call
               "elisp" :code "(message \"hello %d\" 42) (princ \"printed\") (list :a 1)"))
           (c (plist-get r :content)))
      (should-not (plist-get r :is-error))
      (should (string-prefix-p "=> (:a 1)" c))
      (should (string-search "--- output ---\nprinted" c))
      (should (string-search "--- messages ---\nhello 42" c)))
    ;; Strings and long values.
    (should (equal "=> \"s\"" (plist-get (harness-tools-shell-test--call "elisp" :code "\"s\"") :content)))
    (let ((harness-elisp-max-value-chars 20))
      (should (<= (length (plist-get (harness-tools-shell-test--call "elisp" :code "(make-string 500 ?x)") :content)) 24)))
    (should (eq 'exec (harness-tool-kind (harness-tool-get "elisp"))))
    (should (equal "elisp (+ 1 2)" (harness-tool-title "elisp" '(:code "(+ 1 2)\n(more)"))))))

(ert-deftest harness-tools-shell-elisp-errors ()
  (harness-tools-shell-test--setup)
  (harness-test-with-temp-state
    (let ((r (harness-tools-shell-test--call "elisp" :code "(error \"boom %d\" 7)")))
      (should (plist-get r :is-error))
      (should (equal "Error: boom 7" (plist-get r :content))))
    (let ((r (harness-tools-shell-test--call "elisp" :code "(harness-test-no-such-function-xyz)")))
      (should (plist-get r :is-error))
      (should (string-search "void" (plist-get r :content)))
      (should (string-search "harness-test-no-such-function-xyz" (plist-get r :content))))
    (let ((r (harness-tools-shell-test--call "elisp" :code "(+ 1")))
      (should (plist-get r :is-error))
      (should (string-search "End of file" (plist-get r :content))))
    (should (plist-get (harness-tools-shell-test--call "elisp" :code "  ") :is-error))
    ;; The timeout interrupts code that yields to the event loop.
    (let* ((harness-elisp-timeout 0.3)
           (r (harness-tools-shell-test--call "elisp" :code "(sit-for 5) 'never")))
      (should (plist-get r :is-error))
      (should (string-search "exceeded" (plist-get r :content))))))

(provide 'harness-tools-shell-test)
;;; harness-tools-shell-test.el ends here
