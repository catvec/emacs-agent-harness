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

(ert-deftest harness-tools-shell-bash-sandbox-required-without-the-module ()
  "A required sandbox, as a policy sets it, refuses a command when the
sandbox module is not loaded, rather than run it unconfined."
  (harness-test-reset-bus)
  (harness-tools-shell-test--setup)
  (harness-test-load-module 'project)
  (harness-test-load-module 'config)
  (should-not (harness-method-exists-p 'sandbox/wrap))
  (harness-tools-shell-test-in-dir
    (harness-test-with-policy '((harness-sandbox-policy . required))
      (let ((r (harness-tools-shell-test--call "bash" :command "echo leaked")))
        (should (plist-get r :is-error))
        (should (string-search "the sandbox module is not loaded" (plist-get r :content)))
        (should-not (string-search "leaked" (plist-get r :content)))))
    (should (equal "ok\nexit 0"
                   (plist-get (harness-tools-shell-test--call "bash" :command "echo ok") :content)))))

(ert-deftest harness-tools-shell-bash-runs-inside-bwrap ()
  "With bwrap available the command sees $HOME at its path, but emptied."
  (harness-tools-shell-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-test-load-module 'project)
  (harness-test-load-module 'config)
  (harness-test-load-module 'sandbox)
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (harness-tools-shell-test-in-dir
    (let* ((home (harness-test-temp-dir))
           (process-environment (cons (concat "HOME=" (directory-file-name home)) process-environment))
           (harness-sandbox-policy 'required))
      (with-temp-file (expand-file-name "private.txt" home) (insert "private\n"))
      (unwind-protect
          (let ((r (harness-tools-shell-test--call
                    "bash" :command "echo HOME=$HOME; cat ~/private.txt >/dev/null 2>&1 && echo visible || echo hidden")))
            (when (and (plist-get r :is-error) (string-search "bwrap:" (plist-get r :content)))
              (ert-skip (format "bwrap cannot start in this environment: %s" (plist-get r :content))))
            (should-not (plist-get r :is-error))
            (should (equal (format "HOME=%s\nhidden\nexit 0" (directory-file-name home)) (plist-get r :content)))
            (should (plist-get (plist-get r :meta) :sandboxed)))
        (delete-directory home t)))))

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

(defmacro harness-tools-shell-test-with-methods (methods &rest body)
  "Run BODY with the bus METHODS, an alist of name to function, registered.
Each method is restored, or removed, afterwards."
  (declare (indent 1))
  `(let ((saved (mapcar (lambda (m) (cons (car m) (gethash (car m) harness--methods))) ,methods)))
     (dolist (m ,methods) (harness-register-method (car m) (cdr m)))
     (unwind-protect (progn ,@body)
       (dolist (m saved)
         (if (cdr m) (puthash (car m) (cdr m) harness--methods) (remhash (car m) harness--methods))))))

(ert-deftest harness-tools-shell-bash-shows-the-skills-to-the-sandbox ()
  "bash asks the sandbox to show the skills directories every call that
only reads may read, and no others; none without the skills module."
  (harness-tools-shell-test--setup)
  (let ((seen nil) (asked nil))
    (harness-tools-shell-test-with-methods
        (list (cons 'sandbox/wrap (lambda (cwd command &rest opts) (push (cons cwd opts) seen) command)))
      (harness-tools-shell-test-in-dir
        (harness-tools-shell-test-with-methods
            (list (cons 'skills/directories
                        (lambda (cwd)
                          (push cwd asked)
                          (list (list :dir "/skills/mine/" :source 'global :contained t)
                                (list :dir "/proj/.claude/skills/" :source 'project :contained nil)
                                (list :dir "/skills/mine/linked/" :source 'global :contained t)))))
          (should (equal "exit 0" (plist-get (harness-tools-shell-test--call "bash" :command "true") :content)))
          (should (equal '("/skills/mine/" "/skills/mine/linked/") (plist-get (cdar seen) :readable)))
          ;; Asked for the session's directory.
          (should (equal (list root) asked)))
        (harness-tools-shell-test--call "bash" :command "true")
        (should-not (plist-get (cdar seen) :readable))))))

(ert-deftest harness-tools-shell-bash-shows-the-session-dirs-to-the-sandbox ()
  "bash asks the sandbox to show every directory the session may touch:
read-write those the permission layer lets every tool reach, the
directories granted to it among them, and read-only the tool output
directory.  A remote one is left out; without a session nothing is
asked."
  (harness-tools-shell-test--setup)
  (let ((seen nil) (asked nil))
    (harness-tools-shell-test-with-methods
        (list (cons 'sandbox/wrap (lambda (cwd command &rest opts) (push (cons cwd opts) seen) command))
              (cons 'session/tmp-dir (lambda (sid) (and (equal sid "s1") "/tmp/harness-0/s1/")))
              (cons 'permission/dirs
                    (lambda (sid)
                      (push sid asked)
                      (list (list :dir "/work/proj/" :source 'cwd)
                            (list :dir "/tmp/harness-0/s1/" :source 'tmp)
                            (list :dir "/home/u/.emacs.d/" :source 'session)
                            (list :dir "/home/u/notes/*.org" :source 'session)
                            (list :dir "/ssh:box:/srv/" :source 'session)
                            (list :dir "/home/u/shared/" :source 'config)
                            (list :dir "/home/u/later/" :source 'turn)
                            (list :dir "/state/outputs/" :source 'outputs)))))
      (harness-tools-shell-test-in-dir
        (should (equal "exit 0" (plist-get (harness-await (harness-call 'tools/execute "s1"
                                                                        (list :id "c1" :name "bash" :input '(:command "true")))
                                                          20)
                                           :content)))
        (should (equal '("s1") asked))
        (should (equal '("/tmp/harness-0/s1/" "/work/proj/" "/home/u/.emacs.d/" "/home/u/notes/*.org"
                         "/home/u/shared/" "/home/u/later/")
                       (plist-get (cdar seen) :writable)))
        (should (equal '("/state/outputs/") (plist-get (cdar seen) :readable)))
        (harness-tools-shell-test--call "bash" :command "true")
        (should (equal '("s1") asked))
        (should-not (plist-get (cdar seen) :writable))
        (should-not (plist-get (cdar seen) :readable))))))

(ert-deftest harness-tools-shell-bwrap-shows-what-the-user-granted ()
  "Under the real bwrap a command sees what the user granted the session:
at its own path and from ~, wherever the command runs, and writes
there, while the rest of the home directory stays hidden.  It used to
see none of it: list_dir read a granted directory, and `ls' of the
same directory in bash said it did not exist."
  (harness-tools-shell-test--setup)
  (skip-unless (executable-find "bwrap"))
  (dolist (m '(store project config provider session sandbox perms)) (harness-test-load-module m))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (harness-tools-shell-test-in-dir
    (let* ((home (harness-test-temp-dir))
           (process-environment (cons (concat "HOME=" (directory-file-name home)) process-environment))
           (granted (file-name-as-directory (expand-file-name ".emacs.d/modules" home)))
           (harness-sandbox-policy 'required)
           (sid (plist-get (harness-call 'session/create :cwd root) :id))
           (run (lambda (command)
                  (harness-await (harness-call 'tools/execute sid (list :id (harness-short-id) :name "bash"
                                                                        :input (list :command command)))
                                 20))))
      (with-temp-file (expand-file-name "note.txt" (progn (make-directory granted t) granted)) (insert "granted-note\n"))
      (with-temp-file (expand-file-name ".emacs.d/init.el" home) (insert ";; init\n"))
      (with-temp-file (expand-file-name "secret.txt" home) (insert "s3cret\n"))
      (unwind-protect
          (let ((before (funcall run (format "ls %s 2>/dev/null || echo not-shown" granted))))
            (when (and (plist-get before :is-error) (string-search "bwrap:" (plist-get before :content)))
              (ert-skip (format "bwrap cannot start in this environment: %s" (plist-get before :content))))
            ;; Not granted yet: not there.
            (should (equal "not-shown\nexit 0" (plist-get before :content)))
            (harness-call 'permission/allow-dir sid granted)
            (let ((r (funcall run (mapconcat
                                   #'identity
                                   (list (format "cat %snote.txt" granted)
                                         "cat ~/.emacs.d/modules/note.txt"
                                         "ls ~/.emacs.d"
                                         "cat ~/secret.txt 2>/dev/null || echo secret-hidden"
                                         "cat ~/.emacs.d/init.el 2>/dev/null || echo sibling-hidden"
                                         "echo made > ~/.emacs.d/modules/made.txt && echo granted-writable")
                                   "; "))))
              (should (plist-get (plist-get r :meta) :sandboxed))
              (should (equal "granted-note\ngranted-note\nmodules\nsecret-hidden\nsibling-hidden\ngranted-writable\nexit 0"
                             (plist-get r :content)))
              (should (file-exists-p (expand-file-name "made.txt" granted))))
            ;; Revoked: gone again.
            (harness-call 'permission/revoke-dir sid granted)
            (should (equal "not-shown\nexit 0"
                           (plist-get (funcall run (format "ls %s 2>/dev/null || echo not-shown" granted)) :content))))
        (harness-call 'session/delete sid)
        (delete-directory home t)))))

(ert-deftest harness-tools-shell-bash-reads-skills-in-bwrap ()
  "Under the real bwrap a command reads a skill by the path skill_load
gives and from ~, as outside the sandbox, but cannot change it; the
rest of the home directory stays hidden."
  (harness-tools-shell-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-test-load-module 'project)
  (harness-test-load-module 'config)
  (harness-test-load-module 'sandbox)
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (harness-tools-shell-test-in-dir
    (let* ((home (harness-test-temp-dir))
           (process-environment (cons (concat "HOME=" (directory-file-name home)) process-environment))
           (skills (file-name-as-directory (expand-file-name ".claude/skills" home)))
           (harness-sandbox-policy 'required)
           (harness-sandbox--home "/tmp/harness-tools-shell-test-home"))
      (make-directory (expand-file-name "commit" skills) t)
      (with-temp-file (expand-file-name "commit/SKILL.md" skills) (insert "the commit skill\n"))
      (with-temp-file (expand-file-name "notes.txt" home) (insert "private\n"))
      (unwind-protect
          (harness-tools-shell-test-with-methods
              (list (cons 'skills/directories (lambda (_cwd) (list (list :dir skills :source 'global :contained t)))))
            ;; Skipped only when bwrap cannot start at all: a mount it
            ;; refuses here is a failure.
            (let ((probe (harness-await (harness-run-command (harness-call 'sandbox/wrap root '("true"))
                                                             :cwd root :timeout 20))))
              (unless (eql 0 (plist-get probe :exit))
                (ert-skip (format "bwrap cannot start here: %s" (string-trim (plist-get probe :stderr))))))
            (let ((r (harness-tools-shell-test--call
                      "bash" :command (format "cat %scommit/SKILL.md ~/.claude/skills/commit/SKILL.md; cat %snotes.txt 2>/dev/null || echo hidden; touch ~/.claude/skills/x 2>/dev/null || echo read-only"
                                              skills home))))
              (should (equal "the commit skill\nthe commit skill\nhidden\nread-only\nexit 0" (plist-get r :content)))
              (should (plist-get (plist-get r :meta) :sandboxed))
              (should-not (file-exists-p (expand-file-name "x" skills)))))
        (delete-directory home t)))))

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

;;;; bash: sandbox options from a module

(defmacro harness-tools-shell-test-with-options (handlers &rest body)
  "Run BODY with HANDLERS, functions, on the `tools/sandbox-options' filter.
HANDLERS is a list of (PRIORITY . FUNCTION).  They are taken off again."
  (declare (indent 1))
  `(let ((installed ,handlers))
     (dolist (h installed) (harness-add-filter 'tools/sandbox-options (cdr h) (car h)))
     (unwind-protect (progn ,@body)
       (dolist (h installed) (harness-remove-filter 'tools/sandbox-options (cdr h))))))

(defmacro harness-tools-shell-test-without-methods (names &rest body)
  "Run BODY with the bus methods NAMES, symbols, removed; put them back afterwards."
  (declare (indent 1))
  `(let ((saved (mapcar (lambda (name) (cons name (gethash name harness--methods))) ,names)))
     (dolist (m saved) (remhash (car m) harness--methods))
     (unwind-protect (progn ,@body)
       (dolist (m saved)
         (when (cdr m) (puthash (car m) (cdr m) harness--methods))))))

(defun harness-tools-shell-test--as (session-id name &rest input)
  "Execute tool NAME with INPUT for SESSION-ID through tools/execute and wait."
  (harness-await (harness-call 'tools/execute session-id (list :id "c1" :name name :input input)) 20))

(ert-deftest harness-tools-shell-bash-asks-for-sandbox-options ()
  "bash runs the `tools/sandbox-options' filter, from nil and with the
session id, and gives what it returns to the sandbox; with no handler it
asks for nothing more than the directories."
  (harness-tools-shell-test--setup)
  (let ((seen nil) (asked nil))
    (harness-tools-shell-test-with-methods
        (list (cons 'sandbox/wrap (lambda (cwd command &rest opts) (push (cons cwd opts) seen) command)))
      (harness-tools-shell-test-in-dir
        ;; No handler: as it was.
        (should (equal "exit 0" (plist-get (harness-tools-shell-test--as "s1" "bash" :command "true") :content)))
        (should (equal '(:writable nil :readable nil) (cdar seen)))
        (harness-tools-shell-test-with-options
            (list (cons 10 (lambda (options session-id)
                             (push (list options session-id) asked)
                             (plist-put (copy-sequence options) :network nil))))
          (should (equal "exit 0" (plist-get (harness-tools-shell-test--as "s1" "bash" :command "true") :content)))
          (should (equal '((nil "s1")) asked))
          (should-not (plist-member (cdar seen) :read-only))
          (should (plist-member (cdar seen) :network))
          (should (null (plist-get (cdar seen) :network)))
          (should (equal "exit 0" (plist-get (harness-tools-shell-test--call "bash" :command "true") :content)))
          (should (equal '((nil nil) (nil "s1")) asked)))
        ;; A handler that has gone: as it was.
        (harness-tools-shell-test--as "s1" "bash" :command "true")
        (should (equal '(:writable nil :readable nil) (cdar seen)))))))

(ert-deftest harness-tools-shell-bash-merges-the-sandbox-options-of-the-handlers ()
  "Each handler gets the options earlier ones gave, and sets its own over
them, so a later one wins."
  (harness-tools-shell-test--setup)
  (let ((seen nil) (given nil))
    (harness-tools-shell-test-with-methods
        (list (cons 'sandbox/wrap (lambda (cwd command &rest opts) (push (cons cwd opts) seen) command)))
      (harness-tools-shell-test-in-dir
        (harness-tools-shell-test-with-options
            (list (cons 20 (lambda (options _sid)
                             (push options given)
                             (plist-put (plist-put (copy-sequence options) :read-only t) :network :later)))
                  (cons 10 (lambda (options _sid)
                             (push options given)
                             (plist-put (plist-put (copy-sequence options) :network nil) :read-only :false))))
          (should (equal "exit 0" (plist-get (harness-tools-shell-test--as "s1" "bash" :command "true") :content)))
          ;; The one with the lower priority first, from nothing.
          (should (equal (list '(:network nil :read-only :false) nil) given))
          (should (eq t (plist-get (cdar seen) :read-only)))
          (should (eq :later (plist-get (cdar seen) :network))))))))

(ert-deftest harness-tools-shell-bash-read-only-shows-every-directory-to-read ()
  "With :read-only no directory is writable: those that would be, and a
handler's own, are readable, once each."
  (harness-tools-shell-test--setup)
  (let ((seen nil))
    (harness-tools-shell-test-with-methods
        (list (cons 'sandbox/wrap (lambda (cwd command &rest opts) (push (cons cwd opts) seen) command))
              (cons 'session/tmp-dir (lambda (sid) (and (equal sid "s1") "/tmp/harness-0/s1/")))
              (cons 'skills/directories
                    (lambda (_cwd) (list (list :dir "/skills/mine/" :source 'global :contained t))))
              (cons 'permission/dirs
                    (lambda (_sid)
                      (list (list :dir "/work/proj/" :source 'cwd)
                            (list :dir "/tmp/harness-0/s1/" :source 'tmp)
                            (list :dir "/home/u/shared/" :source 'config)
                            (list :dir "/state/outputs/" :source 'outputs)))))
      (harness-tools-shell-test-in-dir
        (let ((read-only :unset) (extra nil))
          (harness-tools-shell-test-with-options
              (list (cons 10 (lambda (options _sid)
                               (append (and (not (eq read-only :unset)) (list :read-only read-only))
                                       extra options))))
            ;; Not read-only: the directories as they were.
            (harness-tools-shell-test--as "s1" "bash" :command "true")
            (should (equal '(:writable ("/tmp/harness-0/s1/" "/work/proj/" "/home/u/shared/")
                             :readable ("/skills/mine/" "/state/outputs/"))
                           (cdar seen)))
            ;; An explicit off is not read-only either; the handler's
            ;; directories join the others.
            (setq read-only :false
                  extra (list :writable '("/handler/rw/") :readable '("/handler/ro/" "/work/proj/")))
            (harness-tools-shell-test--as "s1" "bash" :command "true")
            (should (equal '(:writable ("/tmp/harness-0/s1/" "/work/proj/" "/home/u/shared/" "/handler/rw/")
                             :readable ("/skills/mine/" "/state/outputs/" "/handler/ro/" "/work/proj/")
                             :read-only :false)
                           (cdar seen)))
            ;; Read-only: all of them readable, once each, none writable.
            (setq read-only t)
            (harness-tools-shell-test--as "s1" "bash" :command "true")
            (should (equal '(:writable nil
                             :readable ("/tmp/harness-0/s1/" "/work/proj/" "/home/u/shared/" "/handler/rw/"
                                        "/skills/mine/" "/state/outputs/" "/handler/ro/")
                             :read-only t)
                           (cdar seen)))
            ;; Without a session there is no more to show than the skills.
            (setq extra nil)
            (harness-tools-shell-test--call "bash" :command "true")
            (should-not (plist-get (cdar seen) :writable))
            (should (equal '("/skills/mine/") (plist-get (cdar seen) :readable)))))))))

(ert-deftest harness-tools-shell-bash-sandbox-options-fail-closed-without-the-sandbox ()
  "A command that asks for sandbox options does not run unconfined: not
without the sandbox method, whatever the policy says, not in a remote
directory, and not when a handler's answer is no plist of options."
  (harness-tools-shell-test--setup)
  (harness-tools-shell-test-in-dir
    (let ((marker (expand-file-name "ran" root))
          (answer '(:read-only t)))
      (cl-flet ((run ()
                  (harness-tools-shell-test--as "s1" "bash" :command (format "touch %s; echo leaked" (shell-quote-argument marker)))))
        (harness-tools-shell-test-without-methods '(sandbox/wrap)
          (should-not (harness-method-exists-p 'sandbox/wrap))
          ;; As it is without a handler: no sandbox, no required policy, it runs.
          (let ((r (let ((harness-sandbox-policy 'preferred)) (run))))
            (should-not (plist-get r :is-error))
            (should (string-search "leaked" (plist-get r :content)))
            (should (file-exists-p marker))
            (delete-file marker))
          (dolist (policy '(preferred required off))
            (let ((harness-sandbox-policy policy))
              (dolist (options '((:read-only t) (:network nil) (:read-only :false)))
                (setq answer options)
                (harness-tools-shell-test-with-options (list (cons 10 (lambda (_options _sid) answer)))
                  (let ((r (run)))
                    (should (plist-get r :is-error))
                    (should (string-search "Cannot run command" (plist-get r :content)))
                    (should (string-search "the sandbox module is not loaded" (plist-get r :content)))
                    (should (string-search (format "%S" options) (plist-get r :content)))
                    (should-not (string-search "leaked" (plist-get r :content)))
                    (should-not (file-exists-p marker)))))))
          ;; The sandbox there: it runs again.
          (harness-tools-shell-test-with-methods
              (list (cons 'sandbox/wrap (lambda (_cwd command &rest _opts) command)))
            (harness-tools-shell-test-with-options (list (cons 10 (lambda (_options _sid) '(:read-only t))))
              (should-not (plist-get (run) :is-error))
              (should (file-exists-p marker))
              (delete-file marker))))
        ;; A handler that answers something that is no plist of options.
        (harness-tools-shell-test-with-methods
            (list (cons 'sandbox/wrap (lambda (_cwd command &rest _opts) command)))
          (dolist (bad (list 42 "read-only" '(:read-only) '(read-only t) '(:read-only t . :network)))
            (setq answer bad)
            (harness-tools-shell-test-with-options (list (cons 10 (lambda (_options _sid) answer)))
              (let ((r (run)))
                (should (plist-get r :is-error))
                (should (string-search "Cannot run command" (plist-get r :content)))
                (should (string-search "not a plist of sandbox options" (plist-get r :content)))
                (should-not (file-exists-p marker))))))))))

(defun harness-tools-shell-test--enable-mock-tramp ()
  "Define the local TRAMP method \"mock\", as Emacs's own tests do."
  (require 'tramp)
  (defvar tramp-methods)
  (defvar tramp-default-remote-shell)
  (defvar tramp-verbose)
  (unless (assoc "mock" tramp-methods)
    (add-to-list 'tramp-methods
                 `("mock"
                   (tramp-login-program        ,tramp-default-remote-shell)
                   (tramp-login-args           (("-i")))
                   (tramp-direct-async         ("-c"))
                   (tramp-remote-shell         ,tramp-default-remote-shell)
                   (tramp-remote-shell-args    ("-c"))
                   (tramp-connection-timeout   10))))
  (setq tramp-verbose 1))

(ert-deftest harness-tools-shell-bash-sandbox-options-refuse-a-remote-directory ()
  "The sandbox does not reach another host, so a command there that asks
for sandbox options does not run; without them it runs on the host."
  (harness-tools-shell-test--setup)
  (harness-tools-shell-test--enable-mock-tramp)
  (harness-tools-shell-test-in-dir
    (let* ((remote (concat "/mock::" (directory-file-name root) "/"))
           (marker (expand-file-name "ran" root))
           (wrapped nil)
           (command (format "touch %s; echo leaked" (shell-quote-argument marker))))
      (should (file-remote-p remote))
      (harness-tools-shell-test-with-methods
          (list (cons 'sandbox/wrap (lambda (_cwd command &rest _opts) (setq wrapped t) command)))
        (let ((r (harness-tools-shell-test--as "s1" "bash" :command command :cwd remote)))
          (should-not (plist-get r :is-error))
          (should (file-exists-p marker))
          (delete-file marker))
        (harness-tools-shell-test-with-options (list (cons 10 (lambda (options _sid) (plist-put (copy-sequence options) :read-only t))))
          (let ((r (harness-tools-shell-test--as "s1" "bash" :command command :cwd remote)))
            (should (plist-get r :is-error))
            (should (string-search "Cannot run command" (plist-get r :content)))
            (should (string-search "another host" (plist-get r :content)))
            (should (string-search "(:read-only t)" (plist-get r :content)))
            (should-not (string-search "leaked" (plist-get r :content)))
            (should-not (file-exists-p marker))
            (should-not wrapped)))))))

(ert-deftest harness-tools-shell-bwrap-read-only-session ()
  "Under the real bwrap a command of a session whose handler asks for
:read-only reads the working directory and the session's temporary
directory and writes neither, where another session's command writes both."
  (harness-tools-shell-test--setup)
  (skip-unless (executable-find "bwrap"))
  (dolist (m '(store project config provider session sandbox)) (harness-test-load-module m))
  (harness-sandbox-detect)
  (skip-unless (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
  (harness-tools-shell-test-in-dir
    (let* ((harness-sandbox-policy 'required)
           (sid (plist-get (harness-call 'session/create :cwd root) :id))
           (other (plist-get (harness-call 'session/create :cwd root) :id))
           (tmp (harness-call 'session/tmp-dir sid))
           (script (format "cat seen.txt; { echo x > new.txt; } 2>/dev/null && echo cwd-written || echo cwd-refused; { echo x > %s; } 2>/dev/null && echo tmp-written || echo tmp-refused; echo x > /tmp/scratch && echo scratch-written"
                           (shell-quote-argument (concat tmp "note.txt")))))
      (with-temp-file (expand-file-name "seen.txt" root) (insert "seen\n"))
      (unwind-protect
          (harness-tools-shell-test-with-options
              (list (cons 10 (lambda (options session-id)
                               (if (equal session-id sid) (plist-put (copy-sequence options) :read-only t) options))))
            (let ((r (harness-tools-shell-test--as sid "bash" :command script)))
              (when (and (plist-get r :is-error) (string-search "bwrap:" (plist-get r :content)))
                (ert-skip (format "bwrap cannot start in this environment: %s" (plist-get r :content))))
              (should-not (plist-get r :is-error))
              (should (plist-get (plist-get r :meta) :sandboxed))
              (should (equal "seen\ncwd-refused\ntmp-refused\nscratch-written\nexit 0" (plist-get r :content)))
              (should-not (file-exists-p (expand-file-name "new.txt" root)))
              (should-not (file-exists-p (concat tmp "note.txt"))))
            ;; The other session is untouched by it.
            (let ((r (harness-tools-shell-test--as other "bash" :command "echo x > new.txt && echo written")))
              (should (equal "written\nexit 0" (plist-get r :content)))
              (should (file-exists-p (expand-file-name "new.txt" root)))))
        (harness-call 'session/delete sid)
        (harness-call 'session/delete other)))))

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
