;;; harness-tools-ssh-test.el --- Tests for the ssh tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; The ssh tool runs commands through TRAMP.  The tests reach their
;; "hosts" with TRAMP's local mock method, as harness-tramp-test.el
;; does, so the remote code runs for real without a network: the tool
;; takes the method once it is among `harness-tools-ssh--methods'.
;; Nothing here connects over ssh, but one test, which runs only when
;; HARNESS_TEST_SSH_HOST names a host ssh reaches without a prompt.

;;; Code:

(require 'harness-test-helpers)
(require 'tramp)
(require 'tramp-sh)

(defvar harness-tools-ssh--methods)
(defvar harness-tools-ssh--setup-hint)
(defvar harness-tools-corporate-hint)
(defvar harness-corporate-mode)
(defvar harness-allowed-directories)
(defvar harness-non-interactive)
(defvar harness-sessions)

;;;; Helpers

(defun harness-tools-ssh-test--enable-mock ()
  "Make TRAMP's local mock methods known.
mock runs a local shell, as in Emacs's own TRAMP tests, whatever host
a name gives; mockfail's login program exits at once, a host that
cannot be reached."
  (unless (assoc "mock" tramp-methods)
    (add-to-list 'tramp-methods
                 `("mock"
                   (tramp-login-program        ,tramp-default-remote-shell)
                   (tramp-login-args           (("-i")))
                   (tramp-direct-async         ("-c"))
                   (tramp-remote-shell         ,tramp-default-remote-shell)
                   (tramp-remote-shell-args    ("-c"))
                   (tramp-connection-timeout   10))))
  (unless (assoc "mockfail" tramp-methods)
    (add-to-list 'tramp-methods
                 '("mockfail"
                   (tramp-login-program        "false")
                   (tramp-login-args           nil)
                   (tramp-remote-shell         "/bin/sh")
                   (tramp-remote-shell-args    ("-c"))
                   (tramp-connection-timeout   5))))
  (setq tramp-verbose 1))

(defmacro harness-tools-ssh-test--with-mock (&rest body)
  "Run BODY with the mock methods known and taken by the ssh tool."
  (declare (indent 0))
  `(progn
     (harness-tools-ssh-test--enable-mock)
     (let ((harness-tools-ssh--methods (append '("mock" "mockfail") harness-tools-ssh--methods)))
       ,@body)))

(defun harness-tools-ssh-test--allow (_decision next &rest _)
  "Permission filter that allows every call."
  (funcall next (list :behavior 'allow)))

(defun harness-tools-ssh-test--setup ()
  "Load the tool and allow every call; no session, so no jail."
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-shell)
  (harness-test-load-module 'tools-ssh)
  (harness-add-filter 'permission/decide #'harness-tools-ssh-test--allow 10))

(defun harness-tools-ssh-test--call (&rest input)
  "Run the ssh tool with INPUT through `tools/execute' and wait for its result."
  (harness-await (harness-call 'tools/execute nil (list :id "c1" :name "ssh" :input input)) 60))

(defmacro harness-tools-ssh-test--with-session (spec &rest body)
  "Run BODY with every module a session needs loaded and a session made.
SPEC is (VAR . CREATE-ARGS): VAR is bound to the new session's id and
CREATE-ARGS go to `session/create' after its cwd, a fresh local
directory, which BODY gets as `cwd'."
  (declare (indent 1))
  `(harness-tools-ssh-test--with-mock
     (harness-test-with-temp-state
       (harness-test-reset-bus)
       (dolist (m '(store project config provider provider-demo tools tools-fs tools-shell tools-ssh
                          sandbox perms session))
         (harness-test-load-module m))
       (clrhash harness-sessions)
       (let* ((cwd (harness-test-temp-dir))
              (,(car spec) (plist-get (harness-call 'session/create :cwd cwd :model "demo:scripted"
                                                    ,@(cdr spec))
                                      :id)))
         ,@body))))

(defun harness-tools-ssh-test--run (id name input)
  "Return the promise of SESSION ID's call of tool NAME with INPUT."
  (harness-call 'tools/execute id (list :id (harness-short-id) :name name :input input)))

(defun harness-tools-ssh-test--prompt (id)
  "Wait for SESSION ID's permission prompt and return it."
  (harness-test-wait (lambda () (harness-call 'permission/pending id)) 10 "a permission prompt")
  (car (harness-call 'permission/pending id)))

;;;; Hosts

(ert-deftest harness-tools-ssh-host-forms ()
  "A host is an ssh destination or a TRAMP prefix; both become a TRAMP
prefix with every hop written out, and nothing connects."
  (harness-tools-ssh-test--setup)
  (cl-letf (((symbol-function 'tramp-maybe-open-connection)
             (lambda (&rest _) (error "Nothing may connect"))))
    (dolist (case '(("box" "/ssh:box:" "")
                    (" box\n" "/ssh:box:" "")
                    ("noah@box" "/ssh:noah@box:" "")
                    ("noah@box:2222" "/ssh:noah@box#2222:" "")
                    ("box#2222" "/ssh:box#2222:" "")
                    ("box:" "/ssh:box:" "")
                    ("ssh://noah@box.example.com:2222/" "/ssh:noah@box.example.com#2222:" "")
                    ("192.168.1.5" "/ssh:192.168.1.5:" "")
                    ("[::1]:2222" "/ssh:[::1]#2222:" "")
                    ("noah@[fe80::1]" "/ssh:noah@[fe80::1]:" "")
                    ("/ssh:noah@box#2222:" "/ssh:noah@box#2222:" "")
                    ("/ssh:box:/srv/app" "/ssh:box:" "/srv/app")
                    ("/sshx:box:" "/sshx:box:" "")
                    ("/scp:box:~/src" "/scp:box:" "~/src")
                    ("/ssh:jump|ssh:noah@box:" "/ssh:jump|ssh:noah@box:" "")
                    ("/ssh:j1|ssh:u@j2#22|ssh:box:/tmp" "/ssh:j1|ssh:u@j2#22|ssh:box:" "/tmp")))
      (should (equal (cons (nth 1 case) (nth 2 case)) (harness-tools-ssh-prefix (car case)))))))

(ert-deftest harness-tools-ssh-refuses-what-is-no-host ()
  "Only names that are hosts get through: ssh would read a word that
starts with a dash as an option, and TRAMP hands the parts to a shell.
Methods that reach no other host are refused too."
  (harness-tools-ssh-test--setup)
  (cl-flet ((refusal (host) (condition-case err (progn (harness-tools-ssh-prefix host) nil)
                              (error (error-message-string err)))))
    (should (equal "Missing host" (refusal "")))
    (should (equal "Missing host" (refusal nil)))
    (should (equal "Missing host" (refusal "  ")))
    (dolist (host '("-oProxyCommand=touch /tmp/pwned" "-p2222 box" "box;rm -rf ~" "$(id)" "`id`"
                    "box name" "box|other" "noah@-box" "-l@box" "a@b@c" "box:22:33" "/ssh:box"
                    "/ssh:-oProxyCommand=x:" "/ssh:box;id:"))
      (should (refusal host)))
    (should (string-match-p "is no user name" (refusal "no ah@box")))
    (should (string-match-p "is no port" (refusal "box:http")))
    (should (string-match-p "is no port" (refusal "box:99999")))
    (should (string-match-p "is no port" (refusal "box:0")))
    ;; TRAMP takes these names, the tool does not.
    (should (string-match-p "\"-box\" is no host name" (refusal "/ssh:-box:")))
    (should (string-match-p "\"%x\" is no host name" (refusal "/ssh:%x:")))
    (should (string-match-p "\"-l\" is no user name" (refusal "/ssh:-l@box:")))
    (should (string-match-p "\"-J\" is no user name" (refusal "/ssh:jump|ssh:-J@box:")))
    (should (string-match-p "is no user name" (refusal "/ssh:noah%corp@box:")))
    (dolist (host '("/sudo::" "/sudo:root@localhost:/etc" "/docker:web:" "/ssh:jump|sudo:root@box:"))
      (should (string-match-p "is no ssh method; the ssh tool connects with ssh, sshx" (refusal host))))))

(ert-deftest harness-tools-ssh-paths-without-connecting ()
  "Where a call runs, and the path the jail checks, are worked out
without connecting: an absolute cwd is the path, anything the host has
to expand (its home, a relative cwd) makes the host's root the path."
  (harness-tools-ssh-test--setup)
  (cl-letf (((symbol-function 'tramp-maybe-open-connection)
             (lambda (&rest _) (error "Nothing may connect"))))
    (cl-flet ((where (&rest input) (harness-tools-ssh--where input))
              (paths (&rest input) (harness-tools-ssh--paths input)))
      (should (equal '("/ssh:box:" "~/") (where :host "box")))
      (should (equal '("/ssh:box:/") (paths :host "box")))
      (should (equal '("/ssh:box:" "/srv/app/") (where :host "box" :cwd "/srv/app")))
      (should (equal '("/ssh:box:/srv/app/") (paths :host "box" :cwd "/srv/app")))
      (should (equal '("/ssh:box:" "/etc/") (where :host "box" :cwd "/srv/../etc/")))
      (should (equal '("/ssh:box:" "~/app/") (where :host "box" :cwd "app")))
      (should (equal '("/ssh:box:/") (paths :host "box" :cwd "app")))
      (should (equal '("/ssh:box:" "~/src/") (where :host "box" :cwd "~/src")))
      (should (equal '("/ssh:box:" "/srv/") (where :host "/ssh:box:/srv")))
      (should (equal '("/ssh:box:" "/var/") (where :host "/ssh:box:/srv" :cwd "/var")))
      (should (equal '("/ssh:box:" "~/") (where :host "box" :cwd " ")))
      ;; A cwd with a TRAMP prefix: on the same host only.
      (should (equal '("/ssh:box:" "/var/log/") (where :host "box" :cwd "/ssh:box:/var/log")))
      (should (string-match-p "is not on /ssh:box:"
                              (cadr (should-error (where :host "box" :cwd "/ssh:other:/var/log")))))
      (should-not (paths :host "box" :cwd "/ssh:other:/var/log"))
      (should-not (paths :host "-oProxyCommand=x"))
      (should-not (paths))
      (should (equal '("/ssh:j|ssh:box:/") (paths :host "/ssh:j|ssh:box:"))))))

;;;; Running commands

(ert-deftest harness-tools-ssh-runs-commands-on-the-host ()
  "A command runs on the host in its cwd: its output, its error output
and its exit status come back, with the directory as a TRAMP path."
  (harness-tools-ssh-test--setup)
  (harness-tools-ssh-test--with-mock
    (let* ((local (harness-test-temp-dir))
           (dir (concat "/mock:localhost:" local)))
      (with-temp-file (expand-file-name "notes.txt" local) (insert "remote notes\n"))
      (let ((r (harness-tools-ssh-test--call :host "/mock:localhost:" :cwd local :command "cat notes.txt; pwd")))
        (should-not (plist-get r :is-error))
        (should (equal (format "remote notes\n%s\nexit 0 in %s" (directory-file-name local) dir)
                       (plist-get r :content)))
        (should (equal "/mock:localhost:" (plist-get (plist-get r :meta) :host)))
        (should (equal dir (plist-get (plist-get r :meta) :cwd)))
        (should (eql 0 (plist-get (plist-get r :meta) :exit))))
      ;; A failing command: an error, with its output, standard error
      ;; mixed in as it was written, and its status.
      (let ((r (harness-tools-ssh-test--call :host "/mock:localhost:" :cwd local
                                             :command "echo out; echo err >&2; echo more; exit 3")))
        (should (plist-get r :is-error))
        (should (equal (format "out\nerr\nmore\nexit 3 in %s" dir) (plist-get r :content)))
        (should (eql 3 (plist-get (plist-get r :meta) :exit))))
      ;; The cwd may also come with the host, as a TRAMP name.
      (should (string-prefix-p (directory-file-name local)
                               (plist-get (harness-tools-ssh-test--call :host dir :command "pwd") :content)))
      ;; Lines, quotes and expansions reach the shell as written.
      (should (equal (format "one\nit's \"quoted\" 3\nexit 0 in %s" dir)
                     (plist-get (harness-tools-ssh-test--call
                                 :host "/mock:localhost:" :cwd local
                                 :command "echo one\necho \"it's \\\"quoted\\\" $((1 + 2))\"")
                                :content)))
      ;; Bash runs it, where the host has bash.
      (should (string-prefix-p "bash\n" (plist-get (harness-tools-ssh-test--call
                                                    :host "/mock:localhost:" :cwd local
                                                    :command "[ -n \"$BASH_VERSION\" ] && echo bash")
                                                   :content))))))

(ert-deftest harness-tools-ssh-commands-get-no-input ()
  "A command that reads its input gets none, at once: TRAMP's pty would
never pass the end of input on, and it would wait for its timeout."
  (harness-tools-ssh-test--setup)
  (harness-tools-ssh-test--with-mock
    (let* ((local (harness-test-temp-dir))
           (started (float-time))
           (r (harness-tools-ssh-test--call :host "/mock:localhost:" :cwd local :timeout 20
                                            :command "cat; read line; echo \"read [$line] $?\"")))
      (should (< (- (float-time) started) 15))
      (should (string-prefix-p "read [] 1\nexit 0" (plist-get r :content))))))

(ert-deftest harness-tools-ssh-home-and-relative-cwd ()
  "Without a cwd a command runs in the home directory, as the host has
it, and a relative cwd is relative to that."
  (harness-tools-ssh-test--setup)
  (harness-tools-ssh-test--with-mock
    (let* ((home (harness-test-temp-dir))
           (process-environment (cons (concat "HOME=" (directory-file-name home)) process-environment)))
      (make-directory (expand-file-name "proj" home))
      ;; A host of its own: TRAMP keeps a host's home directory.
      (let ((r (harness-tools-ssh-test--call :host "/mock:localhost4:" :command "pwd")))
        (should-not (plist-get r :is-error))
        (should (equal (concat "/mock:localhost4:" home) (plist-get (plist-get r :meta) :cwd)))
        (should (string-prefix-p (concat (directory-file-name home) "\n") (plist-get r :content))))
      (let ((r (harness-tools-ssh-test--call :host "/mock:localhost4:" :cwd "proj" :command "pwd")))
        (should (equal (concat "/mock:localhost4:" home "proj/") (plist-get (plist-get r :meta) :cwd))))
      (let ((r (harness-tools-ssh-test--call :host "/mock:localhost4:" :cwd "~/proj" :command "pwd")))
        (should (equal (concat "/mock:localhost4:" home "proj/") (plist-get (plist-get r :meta) :cwd)))))))

(ert-deftest harness-tools-ssh-timeout-and-progress ()
  "A command that runs too long is killed, its output so far kept; the
output reaches the call's progress report as it comes."
  (harness-tools-ssh-test--setup)
  (harness-tools-ssh-test--with-mock
    (let* ((local (harness-test-temp-dir))
           (started (float-time))
           (r (harness-tools-ssh-test--call :host "/mock:localhost:" :cwd local :timeout 2
                                            :command "echo start; sleep 30; echo never")))
      (should (< (- (float-time) started) 20))
      (should (plist-get r :is-error))
      (should (string-match-p "\\`start\nexit: killed after 2s timeout in /mock:localhost:" (plist-get r :content))))
    (let* ((chunks nil)
           (r (harness-await (harness-tools-ssh--run (list :host "/mock:localhost:" :command "echo one; echo two")
                                                     (list :report (lambda (c) (push c chunks))))
                             60)))
      (should-not (plist-get r :is-error))
      (should (string-match-p "one\ntwo" (apply #'concat (reverse chunks)))))))

(ert-deftest harness-tools-ssh-errors ()
  "What is wrong with a call comes back as an error that says so."
  (harness-tools-ssh-test--setup)
  (harness-tools-ssh-test--with-mock
    (should (equal "Missing command"
                   (plist-get (harness-tools-ssh-test--call :host "/mock:localhost:" :command " ") :content)))
    (let ((r (harness-tools-ssh-test--call :host "-oProxyCommand=sh" :command "true")))
      (should (plist-get r :is-error))
      (should (string-prefix-p "Bad host \"-oProxyCommand=sh\": \"-oProxyCommand=sh\" is no host name. Give an alias"
                               (plist-get r :content))))
    (let ((r (harness-tools-ssh-test--call :host "/sudo::" :command "true")))
      (should (string-prefix-p "Bad host \"/sudo::\": /sudo: is no ssh method" (plist-get r :content))))
    (let ((r (harness-tools-ssh-test--call :host "/mock:localhost:" :cwd "/no/such/dir" :command "true")))
      (should (plist-get r :is-error))
      (should (equal "No directory /mock:localhost:/no/such/dir/ on the host" (plist-get r :content)))
      (should (eq t (plist-get (plist-get r :meta) :connected))))
    ;; A host that cannot be reached: no ssh to ask why (mockfail does
    ;; not log in with ssh), so the error says how to set a host up.
    (let ((r (harness-tools-ssh-test--call :host "/mockfail:localhost:" :cwd "/tmp" :command "true")))
      (should (plist-get r :is-error))
      (should (string-prefix-p "Could not connect to /mockfail:localhost:" (plist-get r :content)))
      (should (string-suffix-p (concat "\n" harness-tools-ssh--setup-hint) (plist-get r :content)))
      (should-not (string-search "BatchMode=yes says" (plist-get r :content)))
      (should (eq nil (plist-get (plist-get r :meta) :connected))))))

(ert-deftest harness-tools-ssh-explains-failed-connections ()
  "A failed connection is explained by ssh in batch mode, which says
what it would have asked or why it failed."
  (harness-tools-ssh-test--setup)
  ;; The command that asks, for every way of naming a host.
  (should (equal '("ssh" "-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "--" "box" "true")
                 (harness-tools-ssh--batch-command "/ssh:box:")))
  (should (equal '("ssh" "-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "-p" "2222" "-l" "noah" "--" "box" "true")
                 (harness-tools-ssh--batch-command "/scp:noah@box#2222:")))
  (should (equal '("ssh" "-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "-J" "j1,u@[::1]:22" "--" "box" "true")
                 (harness-tools-ssh--batch-command "/ssh:j1|ssh:u@[::1]#22|ssh:box:")))
  (harness-tools-ssh-test--enable-mock)
  (should-not (harness-tools-ssh--batch-command "/mock:box:"))
  ;; What TRAMP signalled, said plainly.
  (should (string-match-p "asked for a password, a passphrase or a host key confirmation"
                          (harness-tools-ssh--reason '(end-of-file "Error reading from stdin"))))
  (should-not (harness-tools-ssh--reason
               '(file-error "Tramp failed to connect.  If this happens repeatedly, try\n    `M-x tramp-cleanup-this-connection'")))
  (should (equal "Login failed" (harness-tools-ssh--reason '(error "Login failed\nmore"))))
  ;; A connection busy with another call did not fail: no ssh is asked.
  (let ((r (harness-tools-ssh--connection-error "/ssh:box:" '(remote-file-error "Forbidden reentrant call of Tramp"))))
    (should (plist-get r :is-error))
    (should (equal "TRAMP was busy with another call on /ssh:box:; run the command again." (plist-get r :content))))
  ;; An ssh of our own, which says what a real one would.
  (let* ((bin (harness-test-temp-dir))
         (ssh (expand-file-name "ssh" bin))
         (exec-path (cons bin exec-path))
         (process-environment (cons (concat "PATH=" bin path-separator (getenv "PATH")) process-environment)))
    (with-temp-file ssh
      (insert "#!/bin/sh\necho \"$*\" > \"$(dirname \"$0\")/args\"\n"
              "echo 'noah@box: Permission denied (publickey).' >&2\nexit 255\n"))
    (set-file-modes ssh #o755)
    (let ((r (harness-await (harness-tools-ssh--connection-error
                             "/ssh:noah@box:"
                             '(file-error "Tramp failed to connect.  If this happens repeatedly, try"))
                            30)))
      (should (plist-get r :is-error))
      (should (equal (concat "Could not connect to /ssh:noah@box:.\n"
                             "ssh -o BatchMode=yes says: noah@box: Permission denied (publickey).\n"
                             harness-tools-ssh--setup-hint)
                     (plist-get r :content)))
      (should (equal "-o BatchMode=yes -o ConnectTimeout=10 -l noah -- box true\n"
                     (with-temp-buffer (insert-file-contents (expand-file-name "args" bin)) (buffer-string)))))
    ;; ssh gets in where TRAMP did not: TRAMP could not start its shell.
    (with-temp-file ssh (insert "#!/bin/sh\nexit 0\n"))
    (let ((r (harness-await (harness-tools-ssh--connection-error "/ssh:box:" '(end-of-file "Error reading from stdin"))
                            30)))
      (should (string-prefix-p
               (concat "Could not connect to /ssh:box: (ssh asked for a password, a passphrase or a host key confirmation, which the harness cannot answer).\n"
                       "ssh -o BatchMode=yes says: nothing: it connects")
               (plist-get r :content))))))

(ert-deftest harness-tools-ssh-remote-command-falls-back-to-sh ()
  "On a host without bash, the command runs with sh."
  (harness-tools-ssh-test--setup)
  (let* ((bin (harness-test-temp-dir))
         (sh (executable-find "sh")))
    (make-symbolic-link sh (expand-file-name "sh" bin))
    (with-temp-buffer
      (let ((process-environment (cons (concat "PATH=" bin) process-environment)))
        (should (eql 0 (apply #'call-process sh nil t nil
                              (cdr (harness-tools-shell-remote-command "echo \"ran $0\"; read line; echo \"done $?\""))))))
      (should (equal "ran sh\ndone 1\n" (buffer-string))))))

;;;; Sessions: the jail, corporate mode and the other tools

(ert-deftest harness-tools-ssh-jail-asks-for-the-host ()
  "A call reaches the directory it runs in on the host, or the host's
root when the host decides where that is; the jail asks for it as for
any directory outside the session's, and a grant of the root lets
every tool work on the host."
  (harness-tools-ssh-test--with-session (id :permission-mode 'yolo)
    (let* ((remote (harness-test-temp-dir))
           (dir (concat "/mock:localhost:" remote)))
      (with-temp-file (expand-file-name "data.txt" remote) (insert "on the host\n"))
      ;; Denied: the call does not run.
      (let* ((p (harness-tools-ssh-test--run id "ssh" (list :host "/mock:localhost:" :cwd remote
                                                           :command "touch ran")))
             (prompt (harness-tools-ssh-test--prompt id)))
        (should (equal dir (plist-get (plist-get prompt :payload) :dir)))
        (harness-call 'permission/answer id (plist-get prompt :id) "deny-once")
        (let ((r (harness-await p 60)))
          (should (plist-get r :is-error))
          (should (string-match-p "denied access" (plist-get r :content))))
        (should-not (file-exists-p (expand-file-name "ran" remote))))
      ;; No cwd: the host's root, granted to the session.
      (let* ((p (harness-tools-ssh-test--run id "ssh" (list :host "/mock:localhost:" :command "echo hi")))
             (prompt (harness-tools-ssh-test--prompt id)))
        (should (equal "/mock:localhost:/" (plist-get (plist-get prompt :payload) :dir)))
        (harness-call 'permission/answer id (plist-get prompt :id) "allow-session")
        (should (string-prefix-p "hi\nexit 0" (plist-get (harness-await p 60) :content))))
      ;; Then everything on the host is the session's, for every tool.
      (let ((r (harness-await (harness-tools-ssh-test--run id "ssh" (list :host "/mock:localhost:" :cwd remote
                                                                         :command "cat data.txt"))
                              60)))
        (should (string-prefix-p "on the host\n" (plist-get r :content))))
      (should (string-match-p "on the host"
                              (plist-get (harness-await (harness-tools-ssh-test--run
                                                         id "read_file" (list :path (concat dir "data.txt")))
                                                        60)
                                         :content)))
      (should-not (harness-call 'permission/pending id)))))

(ert-deftest harness-tools-ssh-jail-without-a-user ()
  "A non-interactive session cannot be asked: a host it was not granted
is denied at once, and one granted beforehand is reached."
  (harness-tools-ssh-test--with-session (id :permission-mode 'yolo :non-interactive t)
    (let ((r (harness-await (harness-tools-ssh-test--run id "ssh" (list :host "/mock:localhost:" :command "echo hi"))
                            60)))
      (should (plist-get r :is-error))
      (should (string-match-p "/mock:localhost:/ is outside the allowed directories" (plist-get r :content))))
    (should-not (harness-call 'permission/pending id))
    (let* ((harness-allowed-directories '("/mock:localhost:/"))
           (r (harness-await (harness-tools-ssh-test--run id "ssh" (list :host "/mock:localhost:" :command "echo hi"))
                             60)))
      (should-not (plist-get r :is-error))
      (should (string-prefix-p "hi\nexit 0 in /mock:localhost:/" (plist-get r :content))))))

(ert-deftest harness-tools-ssh-prompt-names-paths-on-the-host ()
  "A prompt about an ssh command names the paths it reaches on the host
it runs on, not on the session's machine."
  (harness-tools-ssh-test--with-session (id :permission-mode 'ask)
    (let* ((harness-allowed-directories '("/mock:localhost:/"))
           (p (harness-tools-ssh-test--run id "ssh" (list :host "/mock:localhost:" :cwd "/srv"
                                                          :command "cat /etc/hostname ./notes")))
           (prompt (harness-tools-ssh-test--prompt id))
           (payload (plist-get prompt :payload)))
      (should (equal "ssh" (plist-get payload :tool)))
      (should (equal "/mock:localhost:/srv/" (plist-get payload :cwd)))
      ;; Inside the session's directories: the host's root was granted.
      (should (equal '("/mock:localhost:/srv/") (plist-get payload :paths)))
      (harness-call 'permission/answer id (plist-get prompt :id) "deny-once")
      (should (plist-get (harness-await p 60) :is-error)))
    (let* ((p (harness-tools-ssh-test--run id "ssh" (list :host "/mock:localhost:" :cwd "/srv"
                                                          :command "cat /etc/hostname")))
           (prompt (harness-tools-ssh-test--prompt id)))
      ;; Outside: the jail asks for the directory first.
      (should (equal "/mock:localhost:/srv/" (plist-get (plist-get prompt :payload) :dir)))
      (harness-call 'permission/answer id (plist-get prompt :id) "allow-once")
      (let ((prompt (harness-tools-ssh-test--prompt id)))
        (should (equal '("/mock:localhost:/etc/hostname") (plist-get (plist-get prompt :payload) :paths)))
        (harness-call 'permission/answer id (plist-get prompt :id) "deny-once"))
      (should (plist-get (harness-await p 60) :is-error)))))

(ert-deftest harness-tools-ssh-corporate-mode-turns-it-off ()
  "Corporate mode offers no session the ssh tool and denies a call of
it before the permission chain, which would allow it."
  (harness-tools-ssh-test--with-session (id :permission-mode 'yolo)
    (cl-flet ((names () (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list id))))
      (let ((harness-corporate-mode nil))
        (should (member "ssh" (names))))
      (let ((harness-corporate-mode t)
            (harness-allowed-directories '("/mock:localhost:/")))
        (should-not (member "ssh" (names)))
        (should (member "bash" (names)))
        (let ((r (harness-await (harness-tools-ssh-test--run id "ssh" (list :host "/mock:localhost:" :command "echo hi"))
                                60)))
          (should (plist-get r :is-error))
          (should (eq t (plist-get r :denied)))
          (should (equal (concat "Denied: corporate mode: tools that reach other machines are off "
                                 harness-tools-corporate-hint)
                         (plist-get r :content))))
        (let ((d (harness-test-await (harness-call 'tools/authorize id '(:id "c2" :name "ssh"
                                                                          :input (:host "box" :command "true"))))))
          (should (eq 'deny (plist-get d :behavior)))
          (should (equal "corporate mode: tools that reach other machines are off" (plist-get d :reason))))))))

(ert-deftest harness-tools-ssh-file-tools-reach-the-host ()
  "A session on this machine works on a host with the file tools and
bash, given paths there: grep names its hits with their TRAMP prefix,
so another tool can take them."
  (harness-tools-ssh-test--with-session (id :permission-mode 'yolo)
    (let* ((remote (harness-test-temp-dir))
           (dir (concat "/mock:localhost:" remote))
           (harness-allowed-directories '("/mock:localhost:/")))
      (make-directory (expand-file-name "sub" remote))
      (with-temp-file (expand-file-name "sub/a.txt" remote) (insert "first\nneedle here\n"))
      (with-temp-file (expand-file-name "b.txt" remote) (insert "no match\n"))
      (cl-flet ((run (name input) (harness-await (harness-tools-ssh-test--run id name input) 60)))
        (let ((r (run "grep" (list :pattern "needle" :path dir))))
          (should-not (plist-get r :is-error))
          (should (equal (format "%ssub/a.txt:2: needle here\n(1 match)" dir) (plist-get r :content))))
        (let ((r (run "grep" (list :pattern "needle" :path (concat dir "sub/a.txt")))))
          (should (equal (format "%ssub/a.txt:2: needle here\n(1 match)" dir) (plist-get r :content))))
        ;; A pattern grep rejects: what it said comes back, from the
        ;; output, where standard error is on another host.
        (let ((r (run "grep" (list :pattern "needle(" :path dir))))
          (should (plist-get r :is-error))
          (should (string-match-p "\\`\\(?:rg\\|grep\\) failed (exit 2): .*[[:alpha:]]" (plist-get r :content))))
        (let ((r (run "list_dir" (list :path dir))))
          (should-not (plist-get r :is-error))
          (should (string-match-p "^sub/$" (plist-get r :content)))
          (should (string-match-p "^b\\.txt" (plist-get r :content))))
        (should (string-match-p "needle here" (plist-get (run "read_file" (list :path (concat dir "sub/a.txt"))) :content)))
        (should-not (plist-get (run "write_file" (list :path (concat dir "new.txt") :content "made\n")) :is-error))
        (should (file-exists-p (expand-file-name "new.txt" remote)))
        ;; bash with a cwd there runs there, and gets no input.
        (let ((r (run "bash" (list :command "cat; ls" :cwd dir :timeout 20))))
          (should-not (plist-get r :is-error))
          (should (string-match-p "new.txt" (plist-get r :content)))
          (should-not (plist-get (plist-get r :meta) :sandboxed)))))))

;;;; Over real ssh

(ert-deftest harness-tools-ssh-real-host ()
  "Over real ssh, to HARNESS_TEST_SSH_HOST, which must take a key from
ssh-agent or one without a passphrase and be a known host."
  (let ((host (getenv "HARNESS_TEST_SSH_HOST")))
    (skip-unless (and host (not (string-empty-p host))))
    (harness-tools-ssh-test--setup)
    (let ((r (harness-tools-ssh-test--call :host host :command "echo \"hello from $(hostname)\"; cat; echo $0")))
      (should-not (plist-get r :is-error))
      (should (string-match-p "\\`hello from .*\nbash\nexit 0 in /ssh:" (plist-get r :content))))
    (let ((r (harness-tools-ssh-test--call :host host :cwd "/" :command "pwd")))
      (should (string-prefix-p "/\nexit 0 in /ssh:" (plist-get r :content))))
    ;; A name no resolver knows: ssh says so.
    (let ((r (harness-tools-ssh-test--call :host "no-such-host.invalid" :command "true")))
      (should (plist-get r :is-error))
      (should (string-match-p "\\`Could not connect to /ssh:no-such-host.invalid:" (plist-get r :content)))
      (should (string-match-p "ssh -o BatchMode=yes says: .*no-such-host.invalid" (plist-get r :content))))))

(provide 'harness-tools-ssh-test)
;;; harness-tools-ssh-test.el ends here
