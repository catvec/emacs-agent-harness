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

(ert-deftest harness-tools-shell-bash-skips-the-login-profile ()
  "A command runs without the user's login profile.
A profile's side effects go wrong there: one that started an ssh-agent
when it saw none ran in the sandbox's PID namespace, saw none, and
overwrote the user's saved agent details with a dead one."
  (harness-tools-shell-test--setup)
  (harness-tools-shell-test-in-dir
    (with-temp-file (expand-file-name ".bash_profile" root)
      (insert "echo profile-ran\n"))
    (with-temp-file (expand-file-name ".profile" root)
      (insert "echo profile-ran\n"))
    (let* ((process-environment (cons (concat "HOME=" root) process-environment))
           (r (harness-tools-shell-test--call "bash" :command "echo hi")))
      (should (equal "hi\nexit 0" (plist-get r :content))))))

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
    (should (equal "Bash: echo hi" (harness-tool-title "bash" '(:command "echo hi\nsecond"))))
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
           ;; A distinct sandbox home, so listing the process home stays
           ;; hidden even when the process is started with HOME under /tmp.
           (harness-sandbox--home (expand-file-name "sandbox-home" (harness-test-temp-dir)))
           (r (harness-tools-shell-test--call "bash" :command (format "echo HOME=$HOME; ls %s >/dev/null 2>&1 && echo visible || echo hidden" (getenv "HOME")))))
      (when (and (plist-get r :is-error) (string-search "bwrap:" (plist-get r :content)))
        (ert-skip (format "bwrap cannot start in this environment: %s" (plist-get r :content))))
      (should-not (plist-get r :is-error))
      (should (string-search (concat "HOME=" harness-sandbox--home) (plist-get r :content)))
      (should (string-search "hidden" (plist-get r :content)))
      (should (plist-get (plist-get r :meta) :sandboxed)))))

(ert-deftest harness-tools-shell-bash-lets-the-sandbox-write-the-tmp-dir ()
  "bash asks the sandbox to let the command write the session's own
temporary directory, and asks for nothing more without a session."
  (harness-tools-shell-test--setup)
  (let ((saved (mapcar (lambda (m) (cons m (gethash m harness--methods))) '(session/tmp-dir sandbox/wrap)))
        (seen nil))
    (harness-register-method 'session/tmp-dir (lambda (sid) (and (equal sid "s1") "/tmp/harness-0/s1/")))
    (harness-register-method 'sandbox/wrap (lambda (cwd command &rest opts) (push (cons cwd opts) seen) command))
    (unwind-protect
        (harness-tools-shell-test-in-dir
          (should (equal "exit 0" (plist-get (harness-await (harness-call 'tools/execute "s1"
                                                                          (list :id "c1" :name "bash" :input '(:command "true")))
                                                            20)
                                             :content)))
          (should (equal '("/tmp/harness-0/s1/") (plist-get (cdar seen) :writable)))
          (harness-tools-shell-test--call "bash" :command "true")
          (should-not (plist-get (cdar seen) :writable)))
      (dolist (m saved)
        (if (cdr m) (puthash (car m) (cdr m) harness--methods) (remhash (car m) harness--methods))))))

(ert-deftest harness-tools-shell-bwrap-keeps-files-in-the-session-tmp-dir ()
  "Under the real bwrap a command writes the session's own temporary
directory at its real path, where the next command and the harness
find the file, while the rest of /tmp stays private to the command."
  (harness-tools-shell-test--setup)
  (skip-unless (executable-find "bwrap"))
  (dolist (m '(store project config provider session sandbox)) (harness-test-load-module m))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (harness-tools-shell-test-in-dir
    (let* ((harness-sandbox-policy 'required)
           (sid (plist-get (harness-call 'session/create :cwd root) :id))
           (tmp (harness-call 'session/tmp-dir sid))
           (stray (format "/tmp/harness-stray-%s" (harness-short-id)))
           (run (lambda (command)
                  (harness-await (harness-call 'tools/execute sid (list :id (harness-short-id) :name "bash"
                                                                        :input (list :command command)))
                                 20)))
           (r (funcall run (format "echo made > %s; touch %s"
                                   (shell-quote-argument (concat tmp "note.txt")) stray))))
      (when (and (plist-get r :is-error) (string-search "bwrap:" (plist-get r :content)))
        (ert-skip (format "bwrap cannot start in this environment: %s" (plist-get r :content))))
      (should-not (plist-get r :is-error))
      (should (plist-get (plist-get r :meta) :sandboxed))
      (should (equal "made\n" (with-temp-buffer (insert-file-contents (concat tmp "note.txt")) (buffer-string))))
      (should-not (file-exists-p stray))
      (should (string-search "made" (plist-get (funcall run (format "cat %s" (shell-quote-argument (concat tmp "note.txt"))))
                                               :content)))
      (harness-call 'session/delete sid))))

(defvar harness-sandbox-policy)

(ert-deftest harness-tools-shell-bash-timeout-kills-the-process-tree ()
  "A timed-out command takes its children with it."
  (harness-tools-shell-test--setup)
  (harness-tools-shell-test-in-dir
    (let* ((pidfile (expand-file-name "child.pid" root))
           ;; Unconfined, whether or not an earlier test loaded the
           ;; sandbox: in bwrap's PID namespace $! is a number of that
           ;; namespace, which says nothing about a process out here.
           (harness-sandbox-policy 'off)
           (r (harness-tools-shell-test--call
               "bash"
               :command (format "sleep 300 & echo $! > %s; wait" (shell-quote-argument pidfile))
               :timeout 2)))
      (should (eq 'timeout (plist-get (plist-get r :meta) :exit)))
      (should (file-exists-p pidfile))
      (let ((child (string-to-number (string-trim (with-temp-buffer (insert-file-contents pidfile) (buffer-string))))))
        (should (> child 0))
        (let ((deadline (+ (float-time) 5)))
          (while (and (eql 0 (signal-process child 0)) (< (float-time) deadline))
            (sleep-for 0.1)))
        (should-not (eql 0 (signal-process child 0)))))))

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
    (let ((harness-elisp--max-value-chars 20))
      (should (<= (length (plist-get (harness-tools-shell-test--call "elisp" :code "(make-string 500 ?x)") :content)) 24)))
    (should (eq 'exec (harness-tool-kind (harness-tool-get "elisp"))))
    (should (equal "Emacs Lisp: (+ 1 2)" (harness-tool-title "elisp" '(:code "(+ 1 2)\n(more)"))))))

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
    (let* ((harness-elisp--timeout 0.3)
           (r (harness-tools-shell-test--call "elisp" :code "(sit-for 5) 'never")))
      (should (plist-get r :is-error))
      (should (string-search "exceeded" (plist-get r :content))))))

(ert-deftest harness-tools-shell-elisp-runs-out-of-process ()
  "The tool evaluates in a child Emacs, never in this one, with the
harness on its load path."
  (harness-tools-shell-test--setup)
  (harness-test-with-temp-state
    (let* ((content (plist-get (harness-tools-shell-test--call "elisp" :code "(emacs-pid)") :content))
           (pid (string-trim (string-remove-prefix "=> " content))))
      (should (string-prefix-p "=> " content))
      (should-not (equal (number-to-string (emacs-pid)) pid)))
    (should (string-search "harness-provider-openai"
                           (plist-get (harness-tools-shell-test--call
                                       "elisp" :code "(locate-library \"harness-provider-openai\")")
                                      :content)))))

(ert-deftest harness-tools-shell-elisp-timeout-kills-a-blocked-evaluation ()
  "A blocking evaluation is killed, tree and all, at its timeout.
This is the freeze this design exists for: a `call-process' waiting on
a child never yields, so nothing in the evaluating Emacs can end it."
  (harness-tools-shell-test--setup)
  (harness-tools-shell-test-in-dir
    (let* ((pidfile (expand-file-name "blocked.pid" root))
           (command (format "echo $$ > %s; sleep 300" (shell-quote-argument pidfile)))
           (code (format "(call-process \"sh\" nil nil nil \"-c\" %S)" command))
           (start (float-time))
           (harness--process-kill-grace 0.3)
           (r (harness-tools-shell-test--call "elisp" :timeout 1 :code code)))
      (should (plist-get r :is-error))
      (should (string-search "timed out" (plist-get r :content)))
      (should (< (- (float-time) start) 15))
      (should (file-exists-p pidfile))
      (let ((pid (string-to-number (string-trim (with-temp-buffer (insert-file-contents pidfile) (buffer-string))))))
        (should (> pid 0))
        (let ((deadline (+ (float-time) 5)))
          (while (and (eql 0 (signal-process pid 0)) (< (float-time) deadline))
            (sleep-for 0.1)))
        (should-not (eql 0 (signal-process pid 0)))))))

(ert-deftest harness-tools-shell-elisp-never-runs-in-the-users-emacs ()
  "The elisp tool always evaluates in the background Emacs.
There is no option to put it in the user's Emacs, its schema has no
place to ask for one, and a call that asks anyway is refused."
  (harness-tools-shell-test--setup)
  (harness-test-with-temp-state
    ;; The option that used to allow it is gone, not just off.
    (should-not (boundp 'harness-elisp-allow-ui-eval))
    (let ((r (harness-tools-shell-test--call "elisp" :code "(emacs-pid)" :emacs "user")))
      (should (plist-get r :is-error))
      (should (string-search "never evaluates in the user's Emacs" (plist-get r :content)))
      (should (string-search "emacs_* tools" (plist-get r :content))))
    (should-not (plist-get (plist-get (plist-get (harness-tool-spec (harness-tool-get "elisp")) :schema)
                                      :properties)
                           :emacs))
    ;; A call without a target evaluates in the background, not here.
    (let* ((r (harness-tools-shell-test--call "elisp" :code "(emacs-pid)"))
           (content (plist-get r :content)))
      (should (string-prefix-p "=> " content))
      (should-not (equal (format "=> %d" (emacs-pid)) content))
      (should (equal "background" (plist-get (plist-get r :meta) :emacs))))
    (should (equal "Emacs Lisp: (+ 1 2)" (harness-tool-title "elisp" '(:code "(+ 1 2)"))))))

(provide 'harness-tools-shell-test)
;;; harness-tools-shell-test.el ends here
