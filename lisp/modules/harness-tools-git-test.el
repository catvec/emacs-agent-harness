;;; harness-tools-git-test.el --- Tests for the git tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; The git tool runs one git command in a repository and shows that
;; process the ssh material the user's configuration needs -- read-only,
;; for the call alone -- instead of granting ~/.ssh to the session.
;;
;; What is checked here is what the tool decides before and around
;; running git: which files of ~/.ssh a configuration, an Include, an
;; IdentityFile or a GIT_SSH_COMMAND asks for; the command line, which
;; no shell reads and which closes the protocols and the prompts; the
;; repository it refuses to leave; and the sandbox options the material
;; becomes.  The calls themselves run for real, against a repository
;; this suite makes, and against a local sshd when HARNESS_TEST_GIT_SSHD
;; names one: nothing here needs a network or the user's own keys.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defvar harness-tools-corporate-hint)
(defvar harness-corporate-mode)
(defvar harness-tools--corporate-remote-tools)

;;;; Helpers

(defun harness-tools-git-test--allow (_decision next &rest _)
  "Permission filter that allows every call."
  (funcall next (list :behavior 'allow)))

(defun harness-tools-git-test--setup ()
  "Load the modules the tool needs and allow every call.
The bus starts empty, as the ssh tool's suite does, so that a jail a
test before this one left behind does not judge these calls."
  (harness-test-reset-bus)
  (harness-test-load-module 'store)
  (harness-test-load-module 'project)
  (harness-test-load-module 'config)
  (harness-test-load-module 'tools)
  (harness-test-load-module 'tools-shell)
  (harness-test-load-module 'sandbox)
  (harness-test-load-module 'tools-git)
  (harness-add-filter 'permission/decide #'harness-tools-git-test--allow 10))

(defun harness-tools-git-test--call (&rest input)
  "Run the git tool with INPUT through `tools/execute' and wait for its result."
  (harness-await (harness-call 'tools/execute nil (list :id "c1" :name "git" :input input)) 120))

(defun harness-tools-git-test--repo (&optional name)
  "Make a repository in a fresh directory and return it.
NAME names a file committed to it, so that a log or a status has
something to say."
  (let ((dir (harness-test-temp-dir)))
    (let ((default-directory dir))
      (call-process "git" nil nil nil "init" "-q" "-b" "main")
      (call-process "git" nil nil nil "config" "user.email" "test@example.invalid")
      (call-process "git" nil nil nil "config" "user.name" "Test")
      (with-temp-file (expand-file-name (or name "README") dir) (insert "hello\n"))
      (call-process "git" nil nil nil "add" "-A")
      (call-process "git" nil nil nil "commit" "-q" "-m" "first"))
    dir))

(defmacro harness-tools-git-test--with-home (&rest body)
  "Run BODY with a home directory of its own, bound as `home'.
Nothing reads the real ~/.ssh: the tests make the files they are about."
  (declare (indent 0))
  `(let* ((home (file-name-as-directory (harness-test-temp-dir)))
          (process-environment (cons (format "HOME=%s" (directory-file-name home))
                                     (cl-remove-if (lambda (v) (string-prefix-p "HOME=" v))
                                                   process-environment))))
     (make-directory (expand-file-name ".ssh" home) t)
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-directory home t)))))

(defun harness-tools-git-test--write (file text)
  "Write TEXT to FILE, making its directory."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert text))
  file)

;;;; What is shown of the ssh setup

(ert-deftest harness-tools-git-ssh-material-shows-the-files-ssh-reads ()
  "The configuration, the known hosts and the keys it names are shown;
a key nobody names is not, and nothing is writable."
  (harness-tools-git-test--with-home
    (let* ((ssh (expand-file-name ".ssh" home))
           (config (harness-tools-git-test--write
                    (expand-file-name "config" ssh)
                    (concat "Host box\n"
                            "  HostName box.example.invalid\n"
                            "  IdentityFile ~/.ssh/id_box\n"
                            "  UserKnownHostsFile ~/.ssh/known_box\n")))
           (key (harness-tools-git-test--write (expand-file-name "id_box" ssh) "private\n"))
           (known (harness-tools-git-test--write (expand-file-name "known_box" ssh) "box ssh-ed25519 AAAA\n"))
           (known-default (harness-tools-git-test--write (expand-file-name "known_hosts" ssh) ""))
           (unnamed (harness-tools-git-test--write (expand-file-name "id_other" ssh) "not mine\n"))
           (material (harness-tools-git-ssh-material nil home))
           (readable (plist-get material :readable)))
      (should (member config readable))
      (should (member key readable))
      (should (member known readable))
      (should (member known-default readable))
      (should-not (member unnamed readable))
      ;; The directory itself is never shown: it holds keys nobody asked for.
      (should-not (member ssh readable))
      (should-not (member (file-name-as-directory ssh) readable)))))

(ert-deftest harness-tools-git-ssh-material-follows-include-and-config-d ()
  "A file the configuration includes is shown, and a directory it
includes stands for the files in it; so does ~/.ssh/config.d."
  (harness-tools-git-test--with-home
    (let* ((ssh (expand-file-name ".ssh" home))
           (included (harness-tools-git-test--write
                      (expand-file-name "work.conf" ssh)
                      "Host work\n  IdentityFile ~/.ssh/id_work\n"))
           (key (harness-tools-git-test--write (expand-file-name "id_work" ssh) "k\n"))
           (dropped (harness-tools-git-test--write
                     (expand-file-name "config.d/10-host.conf" ssh)
                     "Host other\n  IdentityFile ~/.ssh/id_config_d\n"))
           (key2 (harness-tools-git-test--write (expand-file-name "id_config_d" ssh) "k\n")))
      (harness-tools-git-test--write (expand-file-name "config" ssh)
                                      (concat "Include work.conf\nInclude ~/.ssh/config.d\n"))
      (let ((readable (plist-get (harness-tools-git-ssh-material nil home) :readable)))
        (should (member included readable))
        (should (member key readable))
        (should (member dropped readable))
        (should (member key2 readable))))))

(ert-deftest harness-tools-git-ssh-material-gives-the-agent ()
  "A live agent socket is shown by its directory and named in the
environment; a socket that is not there is no agent to show."
  (harness-tools-git-test--with-home
    (skip-unless (executable-find "python3"))
    (let* ((dir (harness-test-temp-dir))
           (sock (expand-file-name "agent.sock" dir)))
      (should (eql 0 (let ((default-directory dir))
                       (call-process "python3" nil nil nil "-c"
                                     (format "import socket; s=socket.socket(socket.AF_UNIX); s.bind(%S)"
                                             sock)))))
      (should (file-exists-p sock))
      (let* ((env (list (cons "SSH_AUTH_SOCK" sock)))
             (material (harness-tools-git-ssh-material env home)))
        (should (member dir (plist-get material :readable)))
        (should (equal (list (cons "SSH_AUTH_SOCK" sock)) (plist-get material :env))))
      (let ((material (harness-tools-git-ssh-material
                       (list (cons "SSH_AUTH_SOCK" (expand-file-name "gone.sock" dir))) home)))
        (should-not (plist-get material :env))
        (should-not (member dir (plist-get material :readable)))))))

(ert-deftest harness-tools-git-ssh-material-shows-the-git-ssh-command ()
  "The program GIT_SSH_COMMAND names, and the key its -i option names,
are shown when they are paths; a name on the PATH is no file to show."
  (harness-tools-git-test--with-home
    (let* ((bin (harness-test-temp-dir))
           (wrapper (harness-tools-git-test--write (expand-file-name "my-ssh" bin) "#!/bin/sh\n"))
           (key (harness-tools-git-test--write (expand-file-name ".ssh/id_cmd" home) "k\n")))
      (set-file-modes wrapper #o755)
      (let ((readable (plist-get (harness-tools-git-ssh-material
                                  (list (cons "GIT_SSH_COMMAND" (format "%s -i ~/.ssh/id_cmd" wrapper)))
                                  home)
                                 :readable)))
        (should (member wrapper readable))
        (should (member key readable)))
      ;; A bare name is resolved by the sandbox's own PATH, and there is
      ;; nothing to show for it.
      (let ((readable (plist-get (harness-tools-git-ssh-material
                                  (list (cons "GIT_SSH" "ssh")) home)
                                 :readable)))
        (should-not (cl-some (lambda (p) (and (file-executable-p p) (not (file-directory-p p))
                                              (string-match-p "ssh\\'" (file-name-nondirectory p))))
                             readable)))
      ;; GIT_SSH with a path is shown too.
      (let ((readable (plist-get (harness-tools-git-ssh-material
                                  (list (cons "GIT_SSH" wrapper)) home)
                                 :readable)))
        (should (member wrapper readable))))))

(ert-deftest harness-tools-git-ssh-material-is-nil-without-a-home-of-ssh ()
  "A user with no ~/.ssh has nothing shown, which is no error."
  (harness-tools-git-test--with-home
    (should-not (harness-tools-git-ssh-material nil home))))

(ert-deftest harness-tools-git-ssh-material-never-follows-another-users-home ()
  "~bob is another user's home, which only that machine's ssh knows:
no path is shown for it, and nothing signals."
  (harness-tools-git-test--with-home
    (let ((config (harness-tools-git-test--write
                   (expand-file-name ".ssh/config" home)
                   "Host x\n  IdentityFile ~bob/.ssh/id_x\n  UserKnownHostsFile ~bob/.ssh/known\n")))
      (should (equal '("config")
                     (mapcar #'file-name-nondirectory
                             (plist-get (harness-tools-git-ssh-material nil home) :readable))))
      (should config))))

;;;; The command line

(ert-deftest harness-tools-git-command-is-git-with-no-shell ()
  "The words are git's arguments, not a shell line: a pipe, a quote and
a substitution stay words, and the settings that close protocols and
prompts go before the subcommand."
  (harness-tools-git-test--setup)
  (should (equal '("git" "-c" "protocol.file.allow=never" "-c" "protocol.ext.allow=never"
                   "-c" "core.fsmonitor=false" "status" "--short")
                 (harness-tools-git--command '("status" "--short"))))
  (let ((command (harness-tools-git--command
                  '("log" "--format=%s" "|" "rm" "-rf" "/" "$(id)" "`id`" ";id"))))
    (should (member "|" command))
    (should (member "$(id)" command))
    (should (member "`id`" command))
    (should (member ";id" command))
    ;; Every one of them is one argument of the one program.
    (should (equal "git" (car command)))
    (should-not (member "sh" command))
    ;; -c is git's own "a setting", never a shell's; there is no shell word.
    (should (equal '("-c" "protocol.file.allow=never") (seq-take (cdr command) 2)))
    (should-not (member "sh" command))
    (should-not (member "-e" command)))
  ;; The leading git is optional, and so is a list of words.
  (should (equal (harness-tools-git--words '(:command "push -u origin HEAD"))
                 '("push" "-u" "origin" "HEAD")))
  (should (equal (harness-tools-git--words '(:command "git push -u origin HEAD"))
                 '("push" "-u" "origin" "HEAD")))
  (should (equal (harness-tools-git--words '(:command ("push" "-u" "origin HEAD")))
                 '("push" "-u" "origin HEAD")))
  (should-not (harness-tools-git--words '(:command "  ")))
  (should-not (harness-tools-git--words '(:command 42))))

(ert-deftest harness-tools-git-command-closes-what-nothing-can-answer ()
  "The environment closes the prompt, the pager, the editor and the
transports git would otherwise run or ask for."
  (harness-tools-git-test--setup)
  (let ((env (harness-tools-git--environment nil)))
    (should (equal "0" (cdr (assoc "GIT_TERMINAL_PROMPT" env))))
    (should (equal "/bin/true" (cdr (assoc "GIT_ASKPASS" env))))
    (should (equal "ssh:https:http:git" (cdr (assoc "GIT_ALLOW_PROTOCOL" env))))
    (should (equal "cat" (cdr (assoc "GIT_PAGER" env))))
    (should (equal "true" (cdr (assoc "GIT_EDITOR" env))))
    (should (equal "true" (cdr (assoc "GIT_SEQUENCE_EDITOR" env))))
    ;; A user who set an ssh command of their own keeps it.
    (let ((process-environment (cons "GIT_SSH_COMMAND=ssh -i ~/.ssh/mine" process-environment)))
      (should-not (assoc "GIT_SSH_COMMAND" (harness-tools-git--environment nil))))
    (let ((process-environment (cl-remove-if (lambda (v) (string-prefix-p "GIT_SSH" v))
                                             process-environment)))
      (should (equal "ssh -o BatchMode=yes"
                     (cdr (assoc "GIT_SSH_COMMAND" (harness-tools-git--environment nil))))))
    ;; And what the material needs to find the agent comes last.
    (should (equal "sock"
                   (cdr (assoc "SSH_AUTH_SOCK"
                               (harness-tools-git--environment (list :env (list (cons "SSH_AUTH_SOCK" "sock"))))))))))

(ert-deftest harness-tools-git-command-runs-help-without-a-viewer ()
  "`git help' with no argument opens the documentation viewer, which
needs a terminal: the tool asks git for its usage instead."
  (harness-tools-git-test--setup)
  (should (equal '("git" "-c" "protocol.file.allow=never" "-c" "protocol.ext.allow=never"
                   "-c" "core.fsmonitor=false" "help" "--help")
                 (harness-tools-git--command '("help"))))
  (should (equal '("help" "push")
                 (last (harness-tools-git--command '("help" "push")) 2))))

;;;; The repository

(ert-deftest harness-tools-git-repository-is-found-and-refused ()
  "A call runs in the repository a directory is in, or in the bare
repository it names; a directory that is no repository is refused
before anything is asked about it."
  (harness-tools-git-test--setup)
  (let* ((repo (harness-tools-git-test--repo))
         (sub (file-name-as-directory (expand-file-name "sub/dir" repo))))
    (make-directory sub t)
    (unwind-protect
        (progn
          (should (equal (file-name-as-directory (file-truename repo))
                         (harness-tools-git--root repo)))
          ;; A directory in the repository is about the top of it.
          (should (equal (file-name-as-directory (file-truename repo))
                         (harness-tools-git--root sub)))
          (should (equal (list (file-name-as-directory (file-truename repo)))
                         (harness-tools-git--paths (list :command "status") (list :cwd sub))))
          ;; A bare repository is a repository.
          (let ((bare (harness-test-temp-dir)))
            (call-process "git" nil nil nil "init" "-q" "--bare" bare)
            (should (equal (file-name-as-directory (file-truename bare))
                           (harness-tools-git--root bare)))
            (delete-directory bare t))
          ;; A directory that is no repository is refused, with the
          ;; directory named, before the jail is asked.
          (let ((plain (harness-test-temp-dir)))
            (let ((r (harness-tools-git-test--call :command "status" :cwd plain)))
              (should (plist-get r :is-error))
              (should (string-match-p "No git repository in " (plist-get r :content))))
            (delete-directory plain t)))
      (delete-directory repo t))))

(ert-deftest harness-tools-git-refuses-what-is-no-git-command ()
  "A word that is no git subcommand is refused before git runs, and so
is an empty command: a mistyped verb, or a program the user happens to
have called git-NAME, is no call at all."
  (harness-tools-git-test--setup)
  (let ((repo (harness-tools-git-test--repo)))
    (unwind-protect
        (progn
          (let ((r (harness-tools-git-test--call :command "frobnicate")))
            (should (plist-get r :is-error))
            (should (string-match-p "Unknown git command \"frobnicate\"" (plist-get r :content))))
          ;; A word git would take for its own subcommand, spelled as a
          ;; program on the PATH, is no subcommand either.
          (let ((r (harness-tools-git-test--call :command "push-x --force")))
            (should (plist-get r :is-error)))
          (let ((r (harness-tools-git-test--call :command "   ")))
            (should (plist-get r :is-error))
            (should (string-match-p "Missing command" (plist-get r :content))))
          ;; A program a repository could make git run as its own
          ;; subcommand is not one the tool runs either.
          (let* ((bin (harness-test-temp-dir))
                 (fake (harness-tools-git-test--write
                        (expand-file-name "git-owned" bin) "#!/bin/sh\necho pwned\n")))
            (set-file-modes fake #o755)
            (let ((process-environment (cons (format "PATH=%s:%s" bin (getenv "PATH"))
                                             process-environment)))
              (let ((r (harness-tools-git-test--call :command "owned")))
                (should (plist-get r :is-error))
                (should-not (string-match-p "pwned" (plist-get r :content)))))
            (delete-directory bin t)))
      (delete-directory repo t))))

;;;; The calls

(ert-deftest harness-tools-git-runs-git-and-reports-it ()
  "A call runs git in the repository and returns what git wrote, with
its exit status; a failing command is the tool's error."
  (harness-tools-git-test--setup)
  (let ((repo (harness-tools-git-test--repo "hello.txt")))
    (unwind-protect
        (progn
          (let ((r (harness-tools-git-test--call :command "status --short" :cwd repo)))
            (should-not (plist-get r :is-error))
            (should (string-match-p "git .*status --short" (plist-get r :content)))
            (should (string-match-p "exit 0" (plist-get r :content))))
          (let ((r (harness-tools-git-test--call :command "log --oneline -1" :cwd repo)))
            (should-not (plist-get r :is-error))
            (should (string-match-p "first" (plist-get r :content))))
          ;; The words reach git as arguments, not through a shell.
          (let ((r (harness-tools-git-test--call :command "rev-parse --show-toplevel" :cwd repo)))
            (should-not (plist-get r :is-error))
            (should (string-match-p (regexp-quote (directory-file-name (file-truename repo)))
                                    (plist-get r :content))))
          ;; A pipe and a substitution are words git receives, not shell
          ;; syntax: git takes them for pathspecs and refuses them outside
          ;; the repository, and nothing in /etc was read.
          (let ((r (harness-tools-git-test--call
                    :command "log --format=%s -- | $(cat /etc/passwd)" :cwd repo)))
            (should (plist-get r :is-error))
            (should (string-match-p "outside repository" (plist-get r :content)))
            (should-not (string-match-p "root:" (plist-get r :content))))
          ;; A command git fails is the tool's error, with git's own words.
          (let ((r (harness-tools-git-test--call :command "rev-parse no-such-ref" :cwd repo)))
            (should (plist-get r :is-error))
            (should (string-match-p "no-such-ref" (plist-get r :content)))
            (should (string-match-p "exit 128" (plist-get r :content)))))
      (delete-directory repo t))))

(ert-deftest harness-tools-git-closes-the-local-and-ext-transports ()
  "A repository's own configuration cannot reopen `file' or `ext':
a clone of a local path and a command named as a transport are both
refused, whatever a repository or the environment says."
  (harness-tools-git-test--setup)
  (let* ((repo (harness-tools-git-test--repo))
         (local (harness-tools-git-test--repo)))
    (unwind-protect
        (progn
          ;; file is closed on the command line, whatever the
          ;; environment allows.
          (let ((process-environment (cons "GIT_ALLOW_PROTOCOL=all" process-environment)))
            (let ((r (harness-tools-git-test--call :command (format "ls-remote %s" local) :cwd repo)))
              (should (plist-get r :is-error))
              (should (string-match-p "not allowed\\|not a git repository\\|does not appear"
                                      (plist-get r :content)))))
          ;; ext runs a program, and is no transport here.
          (let ((r (harness-tools-git-test--call :command "ls-remote ext::sh -c touch% /tmp/harness-git-test-pwned"
                                                 :cwd repo)))
            (should (plist-get r :is-error))
            (should-not (file-exists-p "/tmp/harness-git-test-pwned"))))
      (delete-directory repo t)
      (delete-directory local t))))

(ert-deftest harness-tools-git-shows-ssh-to-the-one-call ()
  "A call's sandbox options show the ssh files read-only, for that call
alone, and the session's own directories are not widened by it."
  (harness-tools-git-test--setup)
  (harness-tools-git-test--with-home
    (let* ((repo (harness-tools-git-test--repo))
           (config (harness-tools-git-test--write
                    (expand-file-name ".ssh/config" home) "Host box\n  IdentityFile ~/.ssh/id_box\n"))
           (key (harness-tools-git-test--write (expand-file-name ".ssh/id_box" home) "k\n"))
           (material (harness-tools-git-ssh-material nil home))
           (readable (plist-get material :readable)))
      (unwind-protect
          (progn
            (should (member config readable))
            (should (member key readable))
            (should-not (member (expand-file-name ".ssh" home) readable))
            ;; The material goes to the sandbox as readable, never writable.
            (let ((opts (harness-tools-shell--wrap-options
                         nil readable nil nil (list (cons "SSH_AUTH_SOCK" "/x")) nil)))
              (should (equal (plist-get opts :readable) readable))
              (should-not (plist-get opts :writable))
              (should (equal (list (cons "SSH_AUTH_SOCK" "/x")) (plist-get opts :env)))))
        (delete-directory repo t)))))

;;;; Corporate mode

(ert-deftest harness-tools-git-is-off-in-corporate-mode ()
  "Corporate mode turns the git tool off, as it turns off ssh: a push
carries the repository to another machine."
  (harness-tools-git-test--setup)
  (let ((harness-corporate-mode t))
    (should (member "git" harness-tools--corporate-remote-tools))
    (should (harness-tools--corporate-off-p "git" 'exec))
    (should-not (harness-tools--corporate-off-p "bash" 'exec)))
  (let ((harness-corporate-mode nil))
    (should-not (harness-tools--corporate-off-p "git" 'exec))))

;;;; The tool itself

(ert-deftest harness-tools-git-is-registered-with-a-label ()
  "The tool has a label people read, a schema, a subject and the exec
kind, and its module is the one that defines it."
  (harness-tools-git-test--setup)
  (let ((tool (harness-tool-get "git")))
    (should tool)
    (should (equal "Git" (harness-tool-label tool)))
    (should (eq 'exec (harness-tool-kind tool)))
    (should (equal "git" (harness-tool-name tool)))
    (should (equal 'tools-git (harness-tool-module tool)))
    (should (equal "push -u origin HEAD" (harness-tools-git--subject '(:command "push -u origin HEAD"))))
    ;; The leading git is the program, not a word of the call.
    (should (equal "push" (harness-tools-git--subject '(:command "git push")))))
  ;; The schema is an object of the three arguments, with command required.
  (let ((schema (harness-tool-schema (harness-tool-get "git"))))
    (should (equal '("command") (plist-get schema :required)))
    (should (equal "string" (plist-get (plist-get (plist-get schema :properties) :command) :type)))))

;;;; Over real ssh

(defun harness-tools-git-test--sshd (root)
  "Start an sshd for ROOT and return its port, or nil when none can start.
ROOT gets the host key, the authorized key, the client configuration
and the sshd configuration of a server only this test reaches, on the
loopback address and a port of its own.  Nothing of the user's own ssh
setup is read: HOME is ROOT, which is what the tool then shows git."
  (let* ((ssh (expand-file-name "home/.ssh" root))
         (key (expand-file-name "id_ed25519" ssh))
         (hostkey (expand-file-name "hostkey" ssh))
         (port (+ 20000 (mod (emacs-pid) 20000)))
         (sshd (or (executable-find "sshd") (and (file-executable-p "/usr/sbin/sshd") "/usr/sbin/sshd")))
         (default-directory root))
    (when (and sshd (executable-find "ssh-keygen"))
      (make-directory ssh t)
      (set-file-modes ssh #o700)
      (dolist (k (list key hostkey))
        (call-process "ssh-keygen" nil nil nil "-q" "-t" "ed25519" "-N" "" "-f" k))
      (harness-tools-git-test--write
       (expand-file-name "config" ssh)
       (format "Host harness-git-test\n  HostName 127.0.0.1\n  Port %d\n  User %s\n  IdentityFile %s\n  IdentitiesOnly yes\n  StrictHostKeyChecking no\n  UserKnownHostsFile %s\n  BatchMode yes\n"
               port (user-login-name) key (expand-file-name "known_hosts" ssh)))
      (harness-tools-git-test--write (expand-file-name "known_hosts" ssh) "")
      (harness-tools-git-test--write
       (expand-file-name "sshd_config" root)
       (format "Port %d\nListenAddress 127.0.0.1\nHostKey %s\nAuthorizedKeysFile %s.pub\nPidFile %s\nStrictModes no\nUsePAM no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n"
               port hostkey key (expand-file-name "sshd.pid" root)))
      (make-directory "/run/sshd" t)
      (let ((process (make-process :name "harness-git-test-sshd"
                                   :command (list sshd "-f" (expand-file-name "sshd_config" root)
                                                  "-E" (expand-file-name "sshd.log" root) "-D")
                                   :noquery t
                                   :connection-type 'pipe)))
        (let ((log (expand-file-name "sshd.log" root))
              (deadline (+ (float-time) 10)))
          (while (and (process-live-p process)
                      (< (float-time) deadline)
                      (not (and (file-exists-p log)
                                (with-temp-buffer
                                  (insert-file-contents log)
                                  (string-match-p "Server listening" (buffer-string))))))
            (accept-process-output nil 0.1)))
        (and (process-live-p process) port)))))

(ert-deftest harness-tools-git-pushes-over-real-ssh ()
  "A push over ssh works with the material shown read-only to the one
call, and ~/.ssh is never granted to the session.

The test starts its own sshd on the loopback address, with a host key
and an authorized key it makes, and a HOME of its own that holds that
ssh setup and nothing else: it is skipped where sshd cannot be started."
  (harness-tools-git-test--setup)
  (let* ((root (file-name-as-directory (harness-test-temp-dir)))
         (port (harness-tools-git-test--sshd root)))
    (skip-unless port)
    (unwind-protect
        (let* ((home (expand-file-name "home/" root))
               (remote (expand-file-name "remote.git" root))
               (repo (expand-file-name "work" root))
               (process-environment
                (cons (format "GIT_SSH_COMMAND=ssh -F %s -o BatchMode=yes"
                              (expand-file-name ".ssh/config" home))
                      (cons (format "HOME=%s" (directory-file-name home))
                            (cl-remove-if (lambda (v) (string-prefix-p "HOME=" v))
                                          process-environment))))
               (default-directory root))
          (call-process "git" nil nil nil "init" "-q" "--bare" remote)
          (call-process "git" nil nil nil "init" "-q" "-b" "main" repo)
          (dolist (setting '(("user.email" "test@example.invalid") ("user.name" "Test")))
            (call-process "git" nil nil nil "-C" repo "config" (car setting) (cadr setting)))
          (with-temp-file (expand-file-name "file.txt" repo) (insert "over ssh\n"))
          (call-process "git" nil nil nil "-C" repo "add" "-A")
          (call-process "git" nil nil nil "-C" repo "commit" "-q" "-m" "over ssh")
          (call-process "git" nil nil nil "-C" repo "remote" "add" "origin"
                        (format "ssh://harness-git-test%s/tmp/../%s" "" remote))
          ;; The remote URL names the host the client configuration
          ;; describes, and the path on it.
          (call-process "git" nil nil nil "-C" repo "remote" "set-url" "origin"
                        (format "ssh://harness-git-test%s" (directory-file-name remote)))
          (let ((r (harness-tools-git-test--call :command "push -u origin main" :cwd repo)))
            (should-not (plist-get r :is-error))
            (should (string-match-p "main" (plist-get r :content)))
            ;; The material was shown to that call, and the sandbox held.
            (should (plist-get (plist-get r :meta) :ssh-paths))
            (should (plist-get (plist-get r :meta) :sandboxed)))
          ;; And the remote has the commit.
          (let ((default-directory remote))
            (should (eql 0 (call-process "git" nil nil nil "log" "--oneline" "-1" "main")))))
      (let ((pid (expand-file-name "sshd.pid" root)))
        (when (file-exists-p pid)
          (ignore-errors
            (call-process "kill" nil nil nil (string-trim
                                              (with-temp-buffer
                                                (insert-file-contents pid)
                                                (buffer-string)))))))
      (delete-directory root t))))

(provide 'harness-tools-git-test)
;;; harness-tools-git-test.el ends here
