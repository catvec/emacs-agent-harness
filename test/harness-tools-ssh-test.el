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
(defvar harness-tools-remote-setup-hint)
(defvar tramp-use-connection-share)
(defvar harness-tools-corporate-hint)
(defvar harness-corporate-mode)
(defvar harness-allowed-directories)
(defvar harness-perms-rules)
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
without connecting.  An absolute cwd is the path.  Where the host decides,
in the login's home directory (no cwd, ~, a relative cwd), the path is
that home directory by name, /ssh:HOST:~/src/, which nothing expands; a
cwd that leaves the home, or is another user's, is about the host's root."
  (harness-tools-ssh-test--setup)
  (harness-test-without-connections
    (cl-flet ((where (&rest input) (harness-tools-ssh--where input))
              (paths (&rest input) (harness-tools-ssh--paths input)))
      ;; Where the call runs is worked out as before: the host's own
      ;; expansion of ~ is still left to the host.
      (should (equal '("/ssh:box:" "~/") (where :host "box")))
      (should (equal '("/ssh:box:" "/srv/app/") (where :host "box" :cwd "/srv/app")))
      (should (equal '("/ssh:box:" "/etc/") (where :host "box" :cwd "/srv/../etc/")))
      (should (equal '("/ssh:box:" "~/app/") (where :host "box" :cwd "app")))
      (should (equal '("/ssh:box:" "~/src/") (where :host "box" :cwd "~/src")))
      (should (equal '("/ssh:box:" "~/") (where :host "box" :cwd " ")))
      (should (equal '("/ssh:box:" "/srv/") (where :host "/ssh:box:/srv")))
      (should (equal '("/ssh:box:" "/var/") (where :host "/ssh:box:/srv" :cwd "/var")))
      ;; The path the jail checks: the home directory by name ...
      (should (equal '("/ssh:box:~/") (paths :host "box")))
      (should (equal '("/ssh:box:~/") (paths :host "box" :cwd " ")))
      (should (equal '("/ssh:box:~/") (paths :host "box" :cwd "~")))
      (should (equal '("/ssh:box:~/app/") (paths :host "box" :cwd "app")))
      (should (equal '("/ssh:box:~/projects/x/") (paths :host "box" :cwd "projects/x")))
      (should (equal '("/ssh:box:~/projects/x/") (paths :host "box" :cwd "~/projects/x")))
      (should (equal '("/ssh:box:~/src/") (paths :host "box" :cwd "~/src")))
      ;; ... with `.' and `..' resolved inside it.
      (should (equal '("/ssh:box:~/b/") (paths :host "box" :cwd "~/a/../b")))
      (should (equal '("/ssh:box:~/a/b/") (paths :host "box" :cwd "./a//b/.")))
      (should (equal '("/ssh:box:~/") (paths :host "box" :cwd "a/..")))
      ;; ... or the host's root when the cwd leaves the home or is another user's.
      (should (equal '("/ssh:box:/") (paths :host "box" :cwd "~/..")))
      (should (equal '("/ssh:box:/") (paths :host "box" :cwd "../x")))
      (should (equal '("/ssh:box:/") (paths :host "box" :cwd "~bob/x")))
      ;; An absolute cwd is itself, normalised.
      (should (equal '("/ssh:box:/srv/app/") (paths :host "box" :cwd "/srv/app")))
      (should (equal '("/ssh:box:/etc/") (paths :host "box" :cwd "/srv/../etc/")))
      (should (equal '("/ssh:box:/") (paths :host "box" :cwd "/")))
      ;; The host may bring a directory of its own, a TRAMP name too.
      (should (equal '("/ssh:box:/srv/") (paths :host "/ssh:box:/srv")))
      (should (equal '("/ssh:box:~/") (paths :host "/ssh:box:")))
      (should (equal '("/ssh:box:~/") (paths :host "/ssh:box:~")))
      (should (equal '("/ssh:box:~/x/") (paths :host "/ssh:box:~/x")))
      (should (equal '("/ssh:box:/var/") (paths :host "/ssh:box:/srv" :cwd "/var")))
      ;; A cwd with a TRAMP prefix: on the same host only.
      (should (equal '("/ssh:box:" "/var/log/") (where :host "box" :cwd "/ssh:box:/var/log")))
      (should (equal '("/ssh:box:" "~/src/") (where :host "box" :cwd "/ssh:box:~/src")))
      (should (equal '("/ssh:box:/var/log/") (paths :host "box" :cwd "/ssh:box:/var/log")))
      (should (equal '("/ssh:box:~/src/") (paths :host "box" :cwd "/ssh:box:~/src")))
      (should (equal '("/ssh:box:~/") (paths :host "box" :cwd "/ssh:box:~")))
      (should (string-match-p "is not on /ssh:box:"
                              (cadr (should-error (where :host "box" :cwd "/ssh:other:/var/log")))))
      (should (string-match-p "is not on /ssh:box:"
                              (cadr (should-error (where :host "box" :cwd "/ssh:other:~/src")))))
      (should-not (paths :host "box" :cwd "/ssh:other:/var/log"))
      (should-not (paths :host "box" :cwd "/ssh:other:~/src"))
      ;; A host with a user and a port, an IPv6 address, another method, a jump host.
      (should (equal '("/ssh:admin@laptop-0#4358:~/") (paths :host "admin@laptop-0:4358" :command "uptime")))
      (should (equal '("/ssh:admin@laptop-0#4358:~/projects/x/")
                     (paths :host "admin@laptop-0:4358" :cwd "projects/x")))
      (should (equal '("/ssh:[::1]#2222:~/") (paths :host "[::1]:2222")))
      (should (equal '("/scp:noah@box:~/src/") (paths :host "/scp:noah@box:~/src")))
      (should (equal '("/ssh:j|ssh:box:~/") (paths :host "/ssh:j|ssh:box:")))
      (should (equal '("/ssh:j|ssh:box:~/src/") (paths :host "/ssh:j|ssh:box:" :cwd "~/src")))
      (should (equal '("/ssh:j|ssh:box:/") (paths :host "/ssh:j|ssh:box:" :cwd "~/..")))
      ;; A call whose host is no good has no path: it fails before it connects.
      (should-not (paths :host "-oProxyCommand=x"))
      (should-not (paths :host "/sudo::"))
      (should-not (paths)))))

(defun harness-tools-ssh-test--attempts (fn)
  "Call FN where TRAMP cannot connect; return the hosts it tried, oldest first.
Errors FN signals are ignored: the question is only whether it tried."
  (let (attempts)
    (cl-letf (((symbol-function 'tramp-maybe-open-connection)
               (lambda (vec &rest _)
                 (push (tramp-make-tramp-file-name vec 'noloc) attempts)
                 (error "Nothing may connect"))))
      (ignore-errors (funcall fn)))
    (nreverse attempts)))

(ert-deftest harness-tools-ssh-paths-do-not-depend-on-an-open-connection ()
  "A name in a home directory is read as it is written, connected or not.
TRAMP's `file-remote-p' expands a ~ once it is connected to the host, so
the local part of /mock:127.0.0.1:~/x is the real home directory after a
call ran there.  The prompt for a host's home directory must not turn into
one for the whole host, or for another directory, the moment a connection
opens: the permission chain reads names itself, and asks no connection."
  (harness-tools-ssh-test--setup)
  (harness-tools-ssh-test--with-mock
    (let ((name "/mock:127.0.0.1:~/x")
          (call '(:host "/mock:127.0.0.1:" :command "pwd")))
      (unwind-protect
          (progn
            ;; Before any connection TRAMP reads the name as it is written,
            ;; and expanding it is what would connect ...
            (should (equal "~/x" (file-remote-p name 'localname)))
            (should (equal '("/mock:127.0.0.1:")
                           (harness-tools-ssh-test--attempts (lambda () (expand-file-name name "/")))))
            ;; ... a connection opens ...
            (should (file-exists-p "/mock:127.0.0.1:/tmp"))
            (should (file-remote-p "/mock:127.0.0.1:" nil t))
            ;; ... and TRAMP expands the ~.
            (let ((expanded (file-remote-p name 'localname)))
              (should-not (equal "~/x" expanded))
              (should (string-prefix-p "/" expanded))
              (should (string-suffix-p "/x" expanded)))
            ;; The permission chain does not, and asks the connection nothing.
            (harness-test-without-connections
              (should (equal '("/mock:127.0.0.1:" . "~/x") (harness-remote-parts name)))
              (should (harness-remote-home-p name))
              (should (equal "~/x" (harness-file-remote-p name 'localname)))
              (should (equal "/mock:127.0.0.1:" (harness-file-remote-p name)))
              (should (equal name (harness-absolute-file-name name "/")))
              (should (equal name (harness-abbreviate-file-name name)))
              (should (equal '("/mock:127.0.0.1:" "~/") (harness-tools-ssh--where call)))
              (should (equal '("/mock:127.0.0.1:~/") (harness-tools-ssh--paths call)))
              (should (equal '("/mock:127.0.0.1:~/src/") (harness-tools-ssh--paths (append call '(:cwd "~/src")))))
              (should (equal '("/mock:127.0.0.1:~/src/")
                             (harness-tools-ssh--paths (append call '(:cwd "/mock:127.0.0.1:~/src")))))
              (should (equal '("/mock:127.0.0.1:~/src/")
                             (harness-tools-ssh--paths '(:host "/mock:127.0.0.1:~/src" :command "pwd"))))
              (should (equal '("/mock:127.0.0.1:~/x/")
                             (harness-tools--paths (harness-tool-get "ssh") (list :host name :command "pwd")
                                                   (list :cwd "/work/"))))
              ;; Messages name a path without asking an open connection about it either:
              ;; TRAMP's abbreviating asks the host whether its file system is case sensitive.
              (should (equal "/mock:127.0.0.1:/tmp/x" (harness-abbreviate-file-name "/mock:127.0.0.1:/tmp/x")))
              (should (equal "/mock:127.0.0.1:/tmp/x/../y" (harness-abbreviate-file-name "/mock:127.0.0.1:/tmp/x/../y")))))
        (ignore-errors (tramp-cleanup-connection (tramp-dissect-file-name "/mock:127.0.0.1:") t t))))))

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
    ;; A host that cannot be reached.  mockfail does not log in with
    ;; ssh, so there is no ssh to ask why, nor an ssh login to set up.
    (let ((r (harness-tools-ssh-test--call :host "/mockfail:localhost:" :cwd "/tmp" :command "true")))
      (should (plist-get r :is-error))
      (should (equal "Could not connect to /mockfail:localhost:." (plist-get r :content)))
      (should (equal '(:host "/mockfail:localhost:" :connected nil) (plist-get r :meta))))))

(ert-deftest harness-tools-ssh-explains-failed-connections ()
  "A failed connection is explained by ssh in batch mode, which says
what it would have asked or why it failed."
  (harness-tools-ssh-test--setup)
  ;; The command that asks, for every way of naming a host.
  (should (equal '("ssh" "-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "--" "box" "true")
                 (harness-tools--ssh-batch-command "/ssh:box:")))
  (should (equal '("ssh" "-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "-p" "2222" "-l" "noah" "--" "box" "true")
                 (harness-tools--ssh-batch-command "/scp:noah@box#2222:")))
  (should (equal '("ssh" "-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "-J" "j1,u@[::1]:22" "--" "box" "true")
                 (harness-tools--ssh-batch-command "/ssh:j1|ssh:u@[::1]#22|ssh:box:")))
  (harness-tools-ssh-test--enable-mock)
  (should-not (harness-tools--ssh-batch-command "/mock:box:"))
  (should-not (harness-tools--ssh-batch-command "/sudo:root@localhost:"))
  ;; What TRAMP signalled, said plainly.
  (should (string-match-p "asked for a password, a passphrase or a host key confirmation"
                          (harness-tools--remote-reason '(end-of-file "Error reading from stdin"))))
  (should-not (harness-tools--remote-reason
               '(file-error "Tramp failed to connect.  If this happens repeatedly, try\n    `M-x tramp-cleanup-this-connection'")))
  (should (equal "Login failed" (harness-tools--remote-reason '(error "Login failed\nmore"))))
  (should (equal "Timeout reached" (harness-tools--remote-reason
                                    '(remote-file-error "Timeout reached, see buffer `*tramp/ssh box*' for details"))))
  ;; A connection busy with another call did not fail: no ssh is asked.
  (let ((r (harness-tools-remote-failure "/ssh:box:" '(remote-file-error "Forbidden reentrant call of Tramp"))))
    (should (plist-get r :is-error))
    (should (equal "TRAMP was busy with another call on /ssh:box:; make this call again." (plist-get r :content))))
  ;; An ssh of our own, which says what a real one would.
  (let* ((bin (harness-test-temp-dir))
         (ssh (expand-file-name "ssh" bin))
         (exec-path (cons bin exec-path))
         (process-environment (cons (concat "PATH=" bin path-separator (getenv "PATH")) process-environment)))
    (with-temp-file ssh
      (insert "#!/bin/sh\necho \"$*\" > \"$(dirname \"$0\")/args\"\n"
              "echo 'noah@box: Permission denied (publickey).' >&2\nexit 255\n"))
    (set-file-modes ssh #o755)
    (let ((r (harness-await (harness-tools-remote-failure
                             "/ssh:noah@box:"
                             '(file-error "Tramp failed to connect.  If this happens repeatedly, try"))
                            30)))
      (should (plist-get r :is-error))
      (should (equal (concat "Could not connect to /ssh:noah@box:.\n"
                             "ssh -o BatchMode=yes says: noah@box: Permission denied (publickey).\n"
                             harness-tools-remote-setup-hint)
                     (plist-get r :content)))
      (should (equal "-o BatchMode=yes -o ConnectTimeout=10 -l noah -- box true\n"
                     (with-temp-buffer (insert-file-contents (expand-file-name "args" bin)) (buffer-string)))))
    ;; ssh gets in where TRAMP did not: TRAMP could not start its shell.
    (with-temp-file ssh (insert "#!/bin/sh\nexit 0\n"))
    (let ((r (harness-await (harness-tools-remote-failure "/ssh:box:" '(end-of-file "Error reading from stdin"))
                            30)))
      (should (string-prefix-p
               (concat "Could not connect to /ssh:box: (the login asked for a password, a passphrase or a host key confirmation, which the harness cannot answer).\n"
                       "ssh -o BatchMode=yes says: nothing: it connects")
               (plist-get r :content))))
    ;; No ssh to ask at all.
    (delete-file ssh)
    (let* ((exec-path (list bin))
           (r (harness-await (harness-tools-remote-failure "/ssh:box:" '(remote-file-error "Login failed")) 30)))
      (should (equal (concat "Could not connect to /ssh:box: (Login failed).\n" harness-tools-remote-setup-hint)
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

(defun harness-tools-ssh-test--ask (id input)
  "Start a call of the ssh tool with INPUT in session ID; return (PROMISE . PROMPT).
The prompt is the first permission request the call waits on."
  (let ((p (harness-tools-ssh-test--run id "ssh" input)))
    (cons p (harness-tools-ssh-test--prompt id))))

(ert-deftest harness-tools-ssh-jail-asks-for-the-host ()
  "A call reaches the directory it runs in on the host.  The jail asks for
it as for any directory outside the session's; for a call that runs in the
login's home directory that is the home directory by name, which no
connection has to find.  A grant of it holds for the home: an absolute
directory asks again, and a grant of the host's root lets every tool work
anywhere on the host."
  (harness-tools-ssh-test--with-session (id :permission-mode 'yolo)
    (let* ((remote (harness-test-temp-dir))
           (dir (concat "/mock:localhost:" remote)))
      (with-temp-file (expand-file-name "data.txt" remote) (insert "on the host\n"))
      ;; Denied: the call does not run.
      (let ((asked (harness-test-without-connections
                     (harness-tools-ssh-test--ask id (list :host "/mock:localhost:" :cwd remote
                                                           :command "touch ran")))))
        (should (equal dir (plist-get (plist-get (cdr asked) :payload) :dir)))
        (harness-call 'permission/answer id (plist-get (cdr asked) :id) "deny-once")
        (let ((r (harness-await (car asked) 60)))
          (should (plist-get r :is-error))
          (should (string-match-p "denied access" (plist-get r :content))))
        (should-not (file-exists-p (expand-file-name "ran" remote))))
      ;; No cwd: the home directory of the login, by name, granted to the session.
      (let* ((asked (harness-test-without-connections
                      (harness-tools-ssh-test--ask id (list :host "/mock:localhost:" :command "echo hi"))))
             (payload (plist-get (cdr asked) :payload)))
        (should (equal "/mock:localhost:~/" (plist-get payload :dir)))
        (should (equal "/mock:localhost:~/**" (plist-get payload :pattern)))
        (should (equal '("/mock:localhost:~/") (plist-get payload :paths)))
        (should (equal "Access /mock:localhost:~/ (the login's home directory)" (plist-get payload :title)))
        (should (string-match-p "the home directory of the login on localhost, where ssh starts"
                                (plist-get payload :reason)))
        (harness-call 'permission/answer id (plist-get (cdr asked) :id) "allow-session")
        (should (string-prefix-p "hi\nexit 0" (plist-get (harness-await (car asked) 60) :content))))
      (should (member "/mock:localhost:~/" (harness-call 'permission/allowed-dirs id)))
      (should-not (member "/mock:localhost:/" (harness-call 'permission/allowed-dirs id)))
      ;; The home is granted, not the host: an absolute directory asks again ...
      (let ((asked (harness-test-without-connections
                     (harness-tools-ssh-test--ask id (list :host "/mock:localhost:" :cwd remote
                                                           :command "cat data.txt")))))
        (should (equal dir (plist-get (plist-get (cdr asked) :payload) :dir)))
        ;; ... and is answered for the whole host, by a pattern of the user's own.
        (harness-call 'permission/answer id (plist-get (cdr asked) :id)
                      (list :option "allow-session" :pattern "/mock:localhost:/**"))
        (should (string-prefix-p "on the host\n" (plist-get (harness-await (car asked) 60) :content))))
      (should (member "/mock:localhost:/" (harness-call 'permission/allowed-dirs id)))
      ;; Then everything on the host is the session's, for every tool.
      (should (string-match-p "on the host"
                              (plist-get (harness-await (harness-tools-ssh-test--run
                                                         id "read_file" (list :path (concat dir "data.txt")))
                                                        60)
                                         :content)))
      (should-not (harness-call 'permission/pending id)))))

(ert-deftest harness-tools-ssh-jail-without-a-user ()
  "A non-interactive session cannot be asked: a host it was not granted
is denied at once, the directory it needs named as the prompt would have
named it, and one granted beforehand is reached: the host's root for
every directory on it, its home directory for the home and what is in it."
  (harness-tools-ssh-test--with-session (id :permission-mode 'yolo :non-interactive t)
    (cl-flet ((run (host command &rest more)
                (harness-await (harness-tools-ssh-test--run id "ssh" (append (list :host host :command command) more))
                               60)))
      (harness-test-without-connections
        ;; No cwd: the home directory, which the hint names to be granted.
        (let ((r (run "/mock:localhost:" "echo hi")))
          (should (plist-get r :is-error))
          (should (string-match-p
                   "/mock:localhost:~/ (the home directory of the login on localhost, where ssh starts) is outside the allowed directories"
                   (plist-get r :content)))
          (should (string-match-p
                   "ask the user to grant access to /mock:localhost:~/ (the home directory of the login on localhost, where ssh starts) with the allow-dir command"
                   (plist-get r :content))))
        ;; An absolute directory is named as it is, a cwd out of the home is the host.
        (let ((r (run "/mock:localhost:" "echo hi" :cwd "/srv/app")))
          (should (string-match-p "/mock:localhost:/srv/app/ is outside the allowed directories" (plist-get r :content)))
          (should-not (string-match-p "home directory" (plist-get r :content))))
        (let ((r (run "/mock:localhost:" "echo hi" :cwd "~/..")))
          (should (string-match-p
                   "/mock:localhost:/ (the root directory of localhost, which is the whole host) is outside the allowed directories"
                   (plist-get r :content))))
        (should-not (harness-call 'permission/pending id)))
      ;; Granted beforehand: the host's root, for every directory on it.
      (let* ((harness-allowed-directories '("/mock:localhost:/"))
             (r (run "/mock:localhost:" "echo hi")))
        (should-not (plist-get r :is-error))
        (should (string-prefix-p "hi\nexit 0 in /mock:localhost:/" (plist-get r :content)))
        (should-not (plist-get (run "/mock:localhost:" "echo hi" :cwd "/tmp") :is-error)))
      ;; Its home directory alone: the home and what is in it, not a directory the harness
      ;; cannot tell is the home, even when it is.  A host of its own, whose home is a
      ;; directory of ours.
      (let* ((home (harness-test-temp-dir))
             (process-environment (cons (concat "HOME=" (directory-file-name home)) process-environment))
             (harness-allowed-directories '("/mock:localhost6:~/")))
        (make-directory (expand-file-name "sub" home))
        (let ((r (run "/mock:localhost6:" "pwd")))
          (should-not (plist-get r :is-error))
          (should (string-prefix-p (concat (directory-file-name home) "\nexit 0") (plist-get r :content))))
        (dolist (cwd '("sub" "~/sub" "./sub/." "/mock:localhost6:~/sub"))
          (let ((r (run "/mock:localhost6:" "pwd" :cwd cwd)))
            (should-not (plist-get r :is-error))
            (should (string-prefix-p (concat (directory-file-name home) "/sub\nexit 0") (plist-get r :content)))))
        (dolist (cwd (list (directory-file-name home) (concat home "sub") "/tmp" "~/.."))
          (let ((r (harness-test-without-connections (run "/mock:localhost6:" "pwd" :cwd cwd))))
            (should (plist-get r :is-error))
            (should (string-match-p "is outside the allowed directories" (plist-get r :content)))))))))

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

(ert-deftest harness-tools-ssh-prompt-names-paths-in-the-home ()
  "A command run in the login's home directory names its relative paths in
it: they are the home directory's, so a command that names nothing but
them is about where it runs, and one that names a path elsewhere is about
that.  A word that leaves the home goes somewhere on the host, which only
the host can say, so it names the host's root, as the call's own cwd does
when it leaves the home; a word that starts with ~ names nothing the
harness can place, as before."
  (harness-tools-ssh-test--with-session (id :permission-mode 'ask)
    (let ((harness-allowed-directories '("/mock:localhost:~/")))
      ;; Only home paths: the prompt is about where the command runs.
      (let* ((asked (harness-test-without-connections
                      (harness-tools-ssh-test--ask id (list :host "/mock:localhost:"
                                                            :command "cat ./notes ./sub/../more"))))
             (payload (plist-get (cdr asked) :payload)))
        (should (equal "/mock:localhost:~/" (plist-get payload :cwd)))
        (should (equal '("/mock:localhost:~/") (plist-get payload :paths)))
        (harness-call 'permission/answer id (plist-get (cdr asked) :id) "deny-once")
        (should (plist-get (harness-await (car asked) 60) :is-error)))
      ;; The paths elsewhere on the host are what the prompt is about: the root
      ;; of the host for a word that leaves the home, and a path on it; the home
      ;; paths and the words nothing can place are left out.
      (let* ((asked (harness-test-without-connections
                      (harness-tools-ssh-test--ask id (list :host "/mock:localhost:" :cwd "projects/x"
                                                            :command "cat ./notes ../up ../../../out ~/other /etc/hostname"))))
             (payload (plist-get (cdr asked) :payload)))
        (should (equal "/mock:localhost:~/projects/x/" (plist-get payload :cwd)))
        (should (equal '("/mock:localhost:/" "/mock:localhost:/etc/hostname") (plist-get payload :paths)))
        (harness-call 'permission/answer id (plist-get (cdr asked) :id) "deny-once")
        (should (plist-get (harness-await (car asked) 60) :is-error)))
      ;; The same command without the word that leaves the home asks about the one path.
      (let* ((asked (harness-test-without-connections
                      (harness-tools-ssh-test--ask id (list :host "/mock:localhost:" :cwd "projects/x"
                                                            :command "cat ./notes ../up ~/other /etc/hostname"))))
             (payload (plist-get (cdr asked) :payload)))
        (should (equal '("/mock:localhost:/etc/hostname") (plist-get payload :paths)))
        (harness-call 'permission/answer id (plist-get (cdr asked) :id) "deny-once")
        (should (plist-get (harness-await (car asked) 60) :is-error))))))

(ert-deftest harness-tools-ssh-prompts-for-a-host-ask-without-connecting ()
  "The first call to a host reaches a person, whatever the mode, and nothing
the permission chain does for it connects: the prompt, its answer and the
denial that follows are worked out for a host that exists nowhere.  A call
that runs in the login's home is asked about as the home directory by
name, a relative or ~/ cwd as the directory in it, an absolute cwd as
itself, and a cwd that leaves the home as the host's root."
  (harness-tools-ssh-test--with-session (id :permission-mode 'ask)
    (harness-test-without-connections
      (dolist (mode '(ask accept-edits yolo))
        (harness-call 'session/update id :permission-mode mode)
        (dolist (case '(("box.example.invalid" nil "/ssh:box.example.invalid:~/")
                        ("admin@laptop-0:4358" nil "/ssh:admin@laptop-0#4358:~/")
                        ("admin@laptop-0:4358" (:cwd "projects/x") "/ssh:admin@laptop-0#4358:~/projects/x/")
                        ("benito.example.invalid" (:cwd "~/p/x") "/ssh:benito.example.invalid:~/p/x/")
                        ("benito.example.invalid" (:cwd "/var/log/nginx") "/ssh:benito.example.invalid:/var/log/nginx/")
                        ("box.example.invalid" (:cwd "~/..") "/ssh:box.example.invalid:/")
                        ("box.example.invalid" (:cwd "~bob/x") "/ssh:box.example.invalid:/")
                        ("/ssh:u@box.example.invalid:~/src" nil "/ssh:u@box.example.invalid:~/src/")
                        ;; The permission model knows a host by its last hop, as TRAMP's own name for it does.
                        ("/ssh:j|ssh:box.example.invalid:" nil "/ssh:box.example.invalid:~/"
                         "/ssh:j|ssh:box.example.invalid:~/")))
          (let* ((asked (harness-tools-ssh-test--ask id (append (list :host (nth 0 case) :command "uptime") (nth 1 case))))
                 (payload (plist-get (cdr asked) :payload))
                 (dir (nth 2 case)))
            ;; A person is asked, and about the directory the call needs.
            (should (equal dir (plist-get payload :dir)))
            (should (equal (concat dir "**") (plist-get payload :pattern)))
            (should (equal (list (or (nth 3 case) dir)) (plist-get payload :paths)))
            (should (string-prefix-p (concat "Access " dir) (plist-get payload :title)))
            (should (string-match-p "outside the allowed directories" (plist-get payload :reason)))
            (should (equal '(allow-once allow-session allow-always deny-once deny-always) (plist-get payload :options)))
            ;; The call waits for the answer, which here is no.
            (should-not (harness-promise-settled-p (car asked)))
            (harness-call 'permission/answer id (plist-get (cdr asked) :id) "deny-once")
            (let ((r (harness-await (car asked) 60)))
              (should (plist-get r :is-error))
              (should (string-match-p "denied access" (plist-get r :content))))
            (should-not (harness-call 'permission/pending id))))))))

(ert-deftest harness-tools-ssh-prompts-say-what-the-home-directory-is ()
  "The prompt for the login's home says what it is: its title and its reason
name the home directory of the login on the host, where ssh starts, rather
than just a path with a tilde in it."
  (harness-tools-ssh-test--with-session (id :permission-mode 'ask)
    (harness-test-without-connections
      (let* ((asked (harness-tools-ssh-test--ask id '(:host "admin@laptop-0:4358" :command "uptime")))
             (payload (plist-get (cdr asked) :payload)))
        (should (equal "Access /ssh:admin@laptop-0#4358:~/ (the login's home directory)"
                       (plist-get payload :title)))
        (should (equal "SSH wants /ssh:admin@laptop-0#4358:~/ (the home directory of the login on admin@laptop-0#4358, where ssh starts), which is outside the allowed directories"
                       (plist-get payload :reason)))
        (harness-call 'permission/answer id (plist-get (cdr asked) :id) "deny-once")
        (harness-await (car asked) 60))
      ;; A directory in the home, and the host's root, say so as well.
      (let* ((asked (harness-tools-ssh-test--ask id '(:host "benito.example.invalid" :command "ls" :cwd "projects/x")))
             (payload (plist-get (cdr asked) :payload)))
        (should (equal "Access /ssh:benito.example.invalid:~/projects/x/ (in the login's home directory)"
                       (plist-get payload :title)))
        (should (equal "SSH wants /ssh:benito.example.invalid:~/projects/x/ (in the home directory of the login on benito.example.invalid), which is outside the allowed directories"
                       (plist-get payload :reason)))
        (harness-call 'permission/answer id (plist-get (cdr asked) :id) "deny-once")
        (harness-await (car asked) 60))
      (let* ((asked (harness-tools-ssh-test--ask id '(:host "benito.example.invalid" :command "ls" :cwd "~/..")))
             (payload (plist-get (cdr asked) :payload)))
        (should (equal "Access /ssh:benito.example.invalid:/ (the whole host)" (plist-get payload :title)))
        (should (string-match-p "the root directory of benito.example.invalid, which is the whole host"
                                (plist-get payload :reason)))
        (harness-call 'permission/answer id (plist-get (cdr asked) :id) "deny-once")
        (harness-await (car asked) 60))
      ;; An absolute directory is just that.
      (let* ((asked (harness-tools-ssh-test--ask id '(:host "benito.example.invalid" :command "ls" :cwd "/var/log")))
             (payload (plist-get (cdr asked) :payload)))
        (should (equal "Access /ssh:benito.example.invalid:/var/log/" (plist-get payload :title)))
        (should (equal "SSH wants /ssh:benito.example.invalid:/var/log/, which is outside the allowed directories"
                       (plist-get payload :reason)))
        (harness-call 'permission/answer id (plist-get (cdr asked) :id) "deny-once")
        (harness-await (car asked) 60)))))

(ert-deftest harness-tools-ssh-tool-prompt-offers-this-host-first ()
  "After the home directory is granted, the prompt for the call itself offers
lasting answers for this host: the exact call, the programs on the host (the
step the answers start on), any command on the host, and only then the
programs and the tool for every host."
  (harness-tools-ssh-test--with-session (id :permission-mode 'ask)
    (harness-test-without-connections
      (let* ((command "journalctl -u k3s | tail -50")
             (asked (harness-tools-ssh-test--ask id (list :host "admin@laptop-0:4358" :command command))))
        ;; First the jail's prompt, about the home directory.
        (should (equal "/ssh:admin@laptop-0#4358:~/" (plist-get (plist-get (cdr asked) :payload) :dir)))
        (harness-call 'permission/answer id (plist-get (cdr asked) :id) "allow-session")
        ;; Then the call's own.
        (let* ((prompt (harness-tools-ssh-test--prompt id))
               (payload (plist-get prompt :payload)))
          (should-not (plist-get payload :dir))
          (should (equal "/ssh:admin@laptop-0#4358:~/" (plist-get payload :cwd)))
          (should (equal '("/ssh:admin@laptop-0#4358:~/") (plist-get payload :paths)))
          (should (equal '(("journalctl") ("tail")) (plist-get payload :commands)))
          (should (equal "host-programs" (plist-get payload :cover)))
          (should (equal '("exact" "host-programs" "host-tool" "programs" "tool")
                         (mapcar (lambda (s) (plist-get s :id)) (plist-get payload :ladder))))
          (should (equal (list (format "every ssh call whose host is exactly \"admin@laptop-0:4358\" and command is exactly \"%s\""
                                       command)
                               "every journalctl and tail call on admin@laptop-0:4358 (any arguments)"
                               "every ssh call on admin@laptop-0:4358 (any command)"
                               "every journalctl and tail call (any host, any arguments)"
                               "every ssh call (any host, any command)")
                         (mapcar (lambda (s) (plist-get s :label)) (plist-get payload :ladder))))
          (harness-call 'permission/answer id (plist-get prompt :id) "deny-once")
          (let ((r (harness-await (car asked) 60)))
            (should (plist-get r :denied))))))))

(ert-deftest harness-tools-ssh-denying-a-host-denies-that-host-only ()
  "\"Always deny\" on the programs on a host holds for that host and those
programs, as the cover says: the same programs with other arguments are
denied at once on that host, and other programs, and the same programs on
another host, are asked about as ever.  Nothing connects."
  (harness-tools-ssh-test--with-session (id :permission-mode 'ask)
    (let ((harness-perms-rules nil)
          (harness-allowed-directories nil))
      (cl-letf (((symbol-function 'harness-save-user-option) (lambda (sym value) (set sym value))))
        (harness-test-without-connections
          (cl-flet ((start (host command)
                      (harness-tools-ssh-test--ask id (list :host host :command command))))
            ;; The first call: the home directory, granted; then the call, denied for good.
            (let ((asked (start "box.example.invalid" "journalctl -u k3s | tail -50")))
              (harness-call 'permission/answer id (plist-get (cdr asked) :id) "allow-session")
              (let ((prompt (harness-tools-ssh-test--prompt id)))
                (harness-call 'permission/answer id (plist-get prompt :id)
                              (list :option "deny-always" :cover "host-programs")))
              (should (plist-get (harness-await (car asked) 60) :denied)))
            (should (equal '((:tool "ssh" :input (:host "box.example.invalid")
                                    :commands (("journalctl") ("tail")) :behavior deny))
                           harness-perms-rules))
            ;; The same programs on that host: denied at once, by the rule, with nobody asked.
            (let ((r (harness-await (harness-tools-ssh-test--run
                                     id "ssh" '(:host "box.example.invalid" :command "journalctl -n 5 | tail -1"))
                                    60)))
              (should (plist-get r :denied))
              (should (string-match-p
                       "denied by a standing rule for ssh (journalctl and tail) whose host is exactly \"box.example.invalid\""
                       (plist-get r :content))))
            (should-not (harness-call 'permission/pending id))
            ;; Another program on that host: the call is asked about.
            (let ((asked (start "box.example.invalid" "uptime")))
              (should (plist-get (plist-get (cdr asked) :payload) :ladder))
              (harness-call 'permission/answer id (plist-get (cdr asked) :id) "deny-once")
              (should (plist-get (harness-await (car asked) 60) :denied)))
            ;; The same programs on another host: its home is asked about first.
            (let ((asked (start "other.example.invalid" "journalctl -u k3s | tail -50")))
              (should (equal "/ssh:other.example.invalid:~/" (plist-get (plist-get (cdr asked) :payload) :dir)))
              (harness-call 'permission/answer id (plist-get (cdr asked) :id) "deny-once")
              (should (plist-get (harness-await (car asked) 60) :denied)))))))))

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
          ;; The reason and the hint; the denial then names the handle the
          ;; user can approve the call under (harness-perms.el).
          (should (string-prefix-p (concat "Denied: corporate mode: tools that reach other machines are off "
                                           harness-tools-corporate-hint)
                                   (plist-get r :content)))
          (should (string-match-p "rerun_approved" (plist-get r :content))))
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

(ert-deftest harness-tools-ssh-file-tools-explain-failed-connections ()
  "Any tool that cannot reach the host its path is on says why, as the
ssh tool does; a file error on a host TRAMP is connected to stays an
error about that file."
  (harness-tools-ssh-test--with-session (id :permission-mode 'yolo)
    (let ((harness-allowed-directories '("/mock:localhost:/" "/mockfail:localhost:/" "/ssh:box:/")))
      (cl-flet ((run (name input) (harness-await (harness-tools-ssh-test--run id name input) 60)))
        ;; A host nothing answers on, which ssh does not log in to.
        (dolist (call '(("read_file" :path "/mockfail:localhost:/etc/hostname")
                        ("list_dir" :path "/mockfail:localhost:/tmp")
                        ("grep" :pattern "x" :path "/mockfail:localhost:/tmp")
                        ("bash" :command "true" :cwd "/mockfail:localhost:/tmp")))
          (let ((r (run (car call) (cdr call))))
            (should (plist-get r :is-error))
            (should (equal "Could not connect to /mockfail:localhost:." (plist-get r :content)))
            (should (equal '(:host "/mockfail:localhost:" :connected nil) (plist-get r :meta)))))
        ;; A host ssh logs in to, through an ssh of our own, which TRAMP
        ;; runs too: ssh in batch mode says why.
        (let* ((bin (harness-test-temp-dir))
               (ssh (expand-file-name "ssh" bin))
               (exec-path (cons bin exec-path))
               (process-environment (cons (concat "PATH=" bin path-separator (getenv "PATH")) process-environment))
               (tramp-use-connection-share nil))
          (with-temp-file ssh
            (insert "#!/bin/sh\necho 'noah@box: Permission denied (publickey).' >&2\nexit 255\n"))
          (set-file-modes ssh #o755)
          (let ((r (run "read_file" (list :path "/ssh:box:/etc/hostname"))))
            (should (plist-get r :is-error))
            (should (string-match-p "\\`Could not connect to /ssh:box:\\(?: (.*)\\)?\\.\n" (plist-get r :content)))
            (should (string-suffix-p (concat "\nssh -o BatchMode=yes says: noah@box: Permission denied (publickey).\n"
                                             harness-tools-remote-setup-hint)
                                     (plist-get r :content)))))
        ;; On a host TRAMP is connected to, a file error is about a file.
        (unless (zerop (user-uid))
          (let* ((remote (harness-test-temp-dir))
                 (ro (expand-file-name "ro" remote)))
            (make-directory ro)
            (set-file-modes ro #o555)
            (unwind-protect
                (let ((r (run "write_file" (list :path (concat "/mock:localhost:" ro "/x.txt") :content "x\n"))))
                  (should (plist-get r :is-error))
                  (should (string-prefix-p "Tool write_file failed: " (plist-get r :content))))
              (set-file-modes ro #o755))))))))

;;;; Over real ssh

(ert-deftest harness-tools-ssh-real-host ()
  "Over real ssh, to HARNESS_TEST_SSH_HOST, which must take a key from
ssh-agent or one without a passphrase and be a known host."
  (let ((host (getenv "HARNESS_TEST_SSH_HOST")))
    (skip-unless (and host (not (string-empty-p host))))
    (harness-tools-ssh-test--setup)
    (let ((r (harness-tools-ssh-test--call :host host :command "echo \"hello from $(hostname)\"; cat; echo $0; echo oops >&2")))
      (should-not (plist-get r :is-error))
      (should (string-match-p "\\`hello from .*\nbash\noops\nexit 0 in /ssh:" (plist-get r :content))))
    (let ((r (harness-tools-ssh-test--call :host host :cwd "/" :command "pwd")))
      (should (string-prefix-p "/\nexit 0 in /ssh:" (plist-get r :content))))
    ;; A name no resolver knows: ssh says so.
    (let ((r (harness-tools-ssh-test--call :host "no-such-host.invalid" :command "true")))
      (should (plist-get r :is-error))
      (should (string-match-p "\\`Could not connect to /ssh:no-such-host.invalid:" (plist-get r :content)))
      (should (string-match-p "ssh -o BatchMode=yes says: .*no-such-host.invalid" (plist-get r :content))))))

(provide 'harness-tools-ssh-test)
;;; harness-tools-ssh-test.el ends here
