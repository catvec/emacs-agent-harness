;;; harness-tools-git.el --- Run git with the ssh material it needs, shown to it alone  -*- lexical-binding: t; -*-

;;; Commentary:

;; The bash tool runs a command in a sandbox that hides the home
;; directory (harness-sandbox.el): ~/.ssh is not there, so `git push',
;; `git fetch' and `git clone' over ssh fail in it, and the only way to
;; make them work was to grant the session ~/.ssh -- which hands the
;; model the user's keys, `~/.ssh/config' and whatever else is in it,
;; for every call of every tool, not just for git.
;;
;; This module is the other way.  The git tool runs one git command in
;; the session's repository, and shows that one process the ssh
;; material it needs -- read-only, for that call only -- instead of
;; granting a directory to the session:
;;
;; - the files ssh reads for the user: ~/.ssh/config and what it
;;   includes, the known hosts, and the identity files the user's
;;   configuration names (see `harness-tools-git-ssh-material');
;; - the agent's socket, when `SSH_AUTH_SOCK' names one that exists, in
;;   the command's environment and its directory shown read-only, since
;;   a Unix socket is reached by path;
;; - the program `GIT_SSH_COMMAND' or `GIT_SSH' names, when the user
;;   set one, so that a wrapper of theirs keeps working.
;;
;; None of it is in the model's reach: the paths go to `sandbox/wrap'
;; as `:readable' entries, and a file shown read-only to a sandbox is
;; not a directory the session may read with the file tools, which ask
;; for a grant of their own.  A call says how many paths it was shown,
;; never what one holds.
;;
;; Everything else is the git the sandboxed bash runs, and no more: the
;; repository's own configuration and the host's commit identity
;; (`harness-sandbox--git-env'), not the user's ~/.gitconfig, which the
;; sandbox hides from every command alike.  What changes is that ssh
;; works.
;;
;; git, not a shell.  The tool takes the words of one git command
;; (`status', `push -u origin HEAD', `log --oneline -5') and runs them
;; itself, so no shell reads them: a quote, a `|' or a `$(...)' is an
;; argument git receives, not syntax.  The environment it runs with
;; closes the ways git would otherwise run something else or ask a
;; question nothing can answer:
;;
;;   GIT_TERMINAL_PROMPT=0      no password or passphrase prompt (there is no terminal);
;;   GIT_ASKPASS=/bin/true      no askpass program either;
;;   GIT_ALLOW_PROTOCOL         ssh, https, http and git only: no `file', no `ext';
;;   GIT_SSH_COMMAND            the user's own, else `ssh -o BatchMode=yes';
;;   core.fsmonitor=false       no program a repository names to watch it.
;;
;; A call is of kind exec, as a bash command is, and the path it is
;; about is the top of the repository, so the permission mode, the
;; standing rules and the auto-mode judge decide it as they decide a
;; shell command there.  Its `:command' is the git command line, so a
;; standing rule about `git push' holds a call of this tool too.  The
;; tool refuses a directory that is no git repository before it asks
;; anybody, and a word that is no git subcommand, so a call about a
;; mistyped verb never reaches the jail.
;;
;; Corporate mode turns the tool off, as it turns off ssh: a push
;; carries the repository to another machine, which is what corporate
;; mode exists to stop (see `harness-tools--corporate-remote-tools').
;;
;; Where the sandbox is off -- the `off' policy, no backend -- the
;; command runs with the harness's own environment, which has the agent
;; and the home directory already, and its result says it was not
;; sandboxed.  It does not run with less than it needs and report a
;; failure that would be the sandbox's, not git's.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)
(require 'harness-tools-shell)

(defconst harness-tools-git--default-timeout 120
  "Seconds a git call may run unless it says otherwise.
A push of a large repository over a slow link takes longer than a
status, and git says nothing while it waits, so the default is the bash
tool's.")

(defconst harness-tools-git--max-timeout 3600
  "Most seconds a git call may take, whatever it asks for.")

(defconst harness-tools-git--ssh-files '("config" "known_hosts" "known_hosts2")
  "Files in ~/.ssh a git call is shown, when they exist.
`config' is what says which key, user, port and proxy a host uses;
`known_hosts' answers the host key question the harness cannot ask.
An identity file is shown when the configuration names it
\(`harness-tools-git-ssh-identities'), never merely because it is
there: ~/.ssh holds other people's keys and the user's own notes, and
a call about one repository has no business with them.")

(defconst harness-tools-git--ssh-dirs '("config.d")
  "Directories in ~/.ssh a git call is shown, when they exist.
ssh reads ~/.ssh/config.d/*.conf where a distribution sets `Include'
in the system configuration, and a user's own `Include' names other
places, which `harness-tools-git--includes' reads from the files
themselves.")

(defconst harness-tools-git--subcommands
  '("add" "am" "annotate" "apply" "archive" "bisect" "blame" "branch" "bundle"
    "cat-file" "check-attr" "check-ignore" "check-ref-format" "checkout"
    "cherry" "cherry-pick" "clean" "clone" "column" "commit" "commit-tree"
    "config" "count-objects" "describe" "diff" "diff-files" "diff-index"
    "diff-tree" "fetch" "for-each-ref" "format-patch" "fsck" "gc"
    "get-tar-commit-id" "grep" "hash-object" "help" "init" "log" "ls-files"
    "ls-remote" "ls-tree" "maintenance" "merge" "merge-base" "merge-tree"
    "mktag" "mktree" "mv" "name-rev" "notes" "pack-objects" "prune"
    "pull" "push" "range-diff" "read-tree" "rebase" "reflog" "remote"
    "repack" "replace" "request-pull" "reset" "restore" "rev-list"
    "rev-parse" "revert" "rm" "shortlog" "show" "show-branch" "show-ref"
    "sparse-checkout" "stash" "status" "stripspace" "submodule" "switch"
    "symbolic-ref" "tag" "unpack-file" "update-index" "update-ref"
    "var" "verify-commit" "verify-pack" "verify-tag" "version" "whatchanged"
    "worktree" "write-tree")
  "The git subcommands the tool runs.
It is the porcelain and plumbing a session needs to read, write and
publish a repository.  A word that is no subcommand is refused before
anything runs, so a mistyped verb, or a program the user happens to
have called `git-NAME' on their PATH, is no call at all.")

(defconst harness-tools-git--config
  '(("protocol.file.allow" . "never")
    ("protocol.ext.allow" . "never")
    ("core.fsmonitor" . "false"))
  "git settings every call runs with, as (NAME . VALUE).
`file' and `ext' are closed on the command line as well as in
`GIT_ALLOW_PROTOCOL', since a repository's own configuration can set
the protocol variables and a clone or a submodule would otherwise read
a local path or run a program named there.  `core.fsmonitor' off keeps
git from running the program a repository's configuration names for
it, which is a program the sandbox would not confine.")

(defconst harness-tools-git--env
  '(("GIT_TERMINAL_PROMPT" . "0")
    ("GIT_ASKPASS" . "/bin/true")
    ("GIT_ALLOW_PROTOCOL" . "ssh:https:http:git")
    ("GIT_PAGER" . "cat")
    ("PAGER" . "cat")
    ("GIT_EDITOR" . "true")
    ("GIT_SEQUENCE_EDITOR" . "true")
    ("GIT_MERGE_AUTOEDIT" . "no"))
  "Environment variables every call runs with, as (NAME . VALUE).
Nothing can answer a prompt: the terminal prompt is off and the askpass
program is `true', so a repository that wants a password fails with
git's own error instead of waiting.  The pager is `cat' and the editor
`true', so a command that would open one writes to the result instead
of blocking on a terminal that is not there.")

;;;; The ssh material

(defun harness-tools-git--home ()
  "Return the home directory the user's ssh material is in, or nil.
It is $HOME, or `~' when that is unset, as an absolute local directory
name; nil for a remote one, which this machine's sandbox has nothing to
show."
  (let ((home (or (getenv "HOME") "~")))
    (when (and (stringp home) (file-name-absolute-p home) (not (file-remote-p home)))
      (file-name-as-directory (expand-file-name home)))))

(defun harness-tools-git--read (file)
  "Return the contents of FILE, or nil when it cannot be read.
Nothing signals: the file is one the user may not have, or may not let
this process read, and a call without it is a call without it."
  (when (and (stringp file) (file-readable-p file) (not (file-remote-p file)))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents file)
          (buffer-string))
      (error (harness-log 'debug "git: could not read %s: %s" file (harness-error-message err))
             nil))))

(defun harness-tools-git--config-entries (text)
  "Return the entries of an ssh configuration TEXT, as (KEYWORD ARG...).
KEYWORD is the directive without case (`host', `include',
`identityfile'), and ARG... its arguments as ssh splits a line: `#' is
a comment, and double quotes group words, so a path with a space in it
stays one argument.  A line without a value is left out."
  (let (entries)
    (dolist (line (split-string (or text "") "\n"))
      (let* ((line (car (split-string line "#")))
             (words (and line (split-string (string-trim line) "[ \t]+" t))))
        (when (cdr words)
          (push (cons (downcase (car words)) (cdr words)) entries))))
    (nreverse entries)))

(defun harness-tools-git--expand (path home)
  "Return PATH as an absolute file name, with ~ and %d expanded.
HOME is the home directory.  ssh expands a leading ~ and ~USER, and %d
for the local user's home directory in an `IdentityFile'.  Another
user's home is no file this call may show, and %h, %r and %p name the
host, the user and the port, which no file name can be worked out from
here: nil for each of those, and for a relative path, which ssh reads
in its own directory and this tool has no business guessing at."
  (let ((path (or path "")))
    (cond
     ((string-empty-p path) nil)
     ((equal path "~") (directory-file-name home))
     ((string-prefix-p "~/" path) (expand-file-name (substring path 2) home))
     ((string-prefix-p "~" path) nil)
     ((string-prefix-p "/" path) path)
     (t (let ((expanded (replace-regexp-in-string "%d" (directory-file-name home) path)))
          (and (string-prefix-p "/" expanded) expanded))))))

(defun harness-tools-git--config-paths (keyword text home ssh)
  "Return the files TEXT, an ssh configuration, names for KEYWORD.
HOME is the home directory and SSH the directory of the configuration,
which a relative path is relative to in ssh.  Only files that exist are
returned, and a directory stands for the files in it, as `Include'
takes one."
  (let (paths)
    (dolist (entry (harness-tools-git--config-entries text))
      (when (equal (car entry) keyword)
        (dolist (argument (cdr entry))
          (let ((path (or (harness-tools-git--expand argument home)
                          (expand-file-name argument ssh))))
            (cond
             ((file-directory-p path)
              (dolist (file (ignore-errors (directory-files path t "\\`[^.]")))
                (when (file-regular-p file) (push file paths))))
             ((file-regular-p path) (push path paths)))))))
    (nreverse (delete-dups paths))))

(defun harness-tools-git-ssh-identities (config home)
  "Return the identity files CONFIG, an ssh configuration, names.
HOME is the home directory, which `~' and `%d' in a path stand for.
An `IdentityFile' may be given as a pattern and may name a key that is
not there yet; only the files that exist are returned, since a path a
sandbox is asked to show must be one."
  (harness-tools-git--config-paths "identityfile" config home (expand-file-name ".ssh" home)))

(defun harness-tools-git--ssh-command-paths (env home)
  "Return the files the ssh command in ENV names, or nil.
That is `GIT_SSH_COMMAND' or `GIT_SSH', which git runs instead of ssh:
the program itself, when it is a path rather than a name on the PATH,
the configuration an `-F' option reads in place of ~/.ssh/config, and
the key an `-i' or an `-o IdentityFile=' option names.  HOME is the
home directory, which a `~' in one of those stands for."
  (let ((value (or (cdr (assoc "GIT_SSH_COMMAND" env))
                   (cdr (assoc "GIT_SSH" env)))))
    (when (and (stringp value) (not (string-blank-p value)))
      (let ((words (split-string value "[ \t]+" t))
            (paths nil))
        (while words
          (let ((word (pop words)))
            (cond
             ;; -i PATH and -F PATH, and -iPATH and -FPATH, which ssh both
             ;; take: the key to offer, and the configuration to read in
             ;; place of ~/.ssh/config.
             ((member word '("-i" "-F"))
              (let ((path (harness-tools-git--expand (pop words) home)))
                (when (and path (file-regular-p path)) (push path paths))))
             ((string-match-p "\\`-[iF].+" word)
              (let ((path (harness-tools-git--expand (substring word 2) home)))
                (when (and path (file-regular-p path)) (push path paths))))
             ((string-prefix-p "IdentityFile=" word)
              (let ((path (harness-tools-git--expand (substring word (length "IdentityFile=")) home)))
                (when (and path (file-regular-p path)) (push path paths)))))))
        ;; The program, when it is a path rather than a name on the PATH.
        (let ((path (harness-tools-git--expand (car (split-string value "[ \t]+" t)) home)))
          (when (and path (file-regular-p path) (file-executable-p path))
            (push path paths)))
        (nreverse (delete-dups paths))))))

(defun harness-tools-git--agent-directory (sock)
  "Return the directory a Unix socket SOCK is in, or nil.
A socket is reached by path, so the sandbox shows the directory it is
in, read-only, and the variable names the same path inside."
  (when (and (stringp sock) (string-prefix-p "/" sock) (file-exists-p sock)
             (not (file-remote-p sock)))
    (file-name-directory (directory-file-name sock))))

(defun harness-tools-git-ssh-material (&optional env home)
  "Return what a git call must be shown of the user's ssh setup, as a plist.
ENV is the environment to read, `process-environment' by default, and
HOME the home directory, the user's by default.  The plist has
`:readable', the files and directories to show read-only, and `:env',
the variables the command needs to find them.  Nothing connects and
nothing is read but the user's own configuration; nil when there is
none, which is a call that works for a repository nobody fetches over
ssh."
  (let* ((home (or home (harness-tools-git--home)))
         (env (or env process-environment))
         (ssh (and home (expand-file-name ".ssh" home)))
         (readable nil))
    (when (and ssh (file-directory-p ssh))
      (dolist (name harness-tools-git--ssh-files)
        (let ((file (expand-file-name name ssh)))
          (when (file-regular-p file) (push file readable))))
      (dolist (name harness-tools-git--ssh-dirs)
        (let ((dir (expand-file-name name ssh)))
          (when (file-directory-p dir) (push dir readable))))
      ;; What the configuration includes, the keys it names and the known
      ;; hosts it moves.  A file ssh reads that the sandbox does not show
      ;; is a file ssh reports missing, and a key it cannot open is a push
      ;; that fails for a reason having nothing to do with the repository.
      ;; A file an Include names is a configuration of its own -- ssh reads
      ;; its IdentityFile and UserKnownHostsFile as it reads the main
      ;; file's -- so those are followed too, each file read once.
      (let ((pending (list (expand-file-name "config" ssh)))
            (seen nil))
        (while pending
          (let ((text (harness-tools-git--read (pop pending))))
            (when text
              (dolist (keyword '("identityfile" "userknownhostsfile"))
                (dolist (file (harness-tools-git--config-paths keyword text home ssh))
                  (push file readable)))
              (dolist (file (harness-tools-git--config-paths "include" text home ssh))
                (unless (member file seen)
                  (push file seen)
                  (push file readable)
                  (push file pending)))))))
      (dolist (file (harness-tools-git--ssh-command-paths env home))
        (push file readable))
      (let* ((sock (cdr (assoc "SSH_AUTH_SOCK" env)))
             (dir (harness-tools-git--agent-directory sock)))
        (when dir (push dir readable))
        (when (or readable dir)
          (list :readable (delete-dups (nreverse readable))
                :env (delq nil (list (and dir (cons "SSH_AUTH_SOCK" sock))))))))))

;;;; The call

(defun harness-tools-git--directory (input ctx)
  "Return the directory a call with INPUT under CTX runs in, or nil."
  (let* ((given (plist-get input :cwd))
         (dir (if (and (stringp given) (not (string-blank-p given)))
                  (harness-tools-resolve-path given ctx)
                (or (plist-get ctx :cwd) default-directory))))
    (and (stringp dir) (file-directory-p dir) (file-name-as-directory (expand-file-name dir)))))

(defun harness-tools-git--root (dir)
  "Return the top of the git repository DIR is in, or nil.
That is DIR itself or the nearest directory above it holding a `.git',
as git looks for one, or a bare repository, which holds HEAD, objects
and refs.  Nothing runs git and nothing connects: a directory that is
no repository is told so before anybody is asked about the call."
  (when (and (stringp dir) (file-directory-p dir))
    (let ((dir (file-name-as-directory (expand-file-name dir)))
          (found nil))
      (while (and (not found) dir)
        (cond
         ((file-exists-p (expand-file-name ".git" dir)) (setq found dir))
         ((and (file-exists-p (expand-file-name "HEAD" dir))
               (file-directory-p (expand-file-name "objects" dir))
               (file-directory-p (expand-file-name "refs" dir)))
          (setq found dir))
         (t (let ((up (file-name-directory (directory-file-name dir))))
              (setq dir (and up (not (equal up dir)) up))))))
      found)))

(defun harness-tools-git--words (input)
  "Return the git words a call with INPUT runs, or nil.
INPUT's `:command' is the command line: a git subcommand and its
arguments, with or without the leading `git', as a string or as a list
of words.  No shell reads either, so a `|' in a word is a `|' git
gets."
  (let* ((command (plist-get input :command))
         (words (cond
                 ((listp command) (delq nil (mapcar (lambda (w) (and (stringp w) w)) command)))
                 ((stringp command) (split-string (string-trim command) "[ \t\n]+" t))
                 (t nil))))
    (if (and words (equal (car words) "git")) (cdr words) words)))

(defun harness-tools-git--command (words)
  "Return the command line for WORDS, a git subcommand and its arguments.
`git help' with no argument opens the documentation viewer, which needs
a terminal the harness has not got, and the tool is for the repository:
that call is made `git help --help', which writes git's usage to the
result."
  (append (list "git")
          (cl-loop for (name . value) in harness-tools-git--config
                   append (list "-c" (format "%s=%s" name value)))
          (if (equal words '("help")) (list "help" "--help") words)))

(defun harness-tools-git--environment (material)
  "Return the environment a git call runs with, from MATERIAL.
That is `harness-tools-git--env', then the `:env' of MATERIAL; the
user's own `GIT_SSH_COMMAND' or `GIT_SSH' is kept when they set one,
and `ssh -o BatchMode=yes' is the default otherwise, since nothing can
answer a prompt."
  (let ((env harness-tools-git--env))
    (unless (or (getenv "GIT_SSH_COMMAND") (getenv "GIT_SSH"))
      (setq env (append env (list (cons "GIT_SSH_COMMAND" "ssh -o BatchMode=yes")))))
    (append env (plist-get material :env))))

(defun harness-tools-git--subject (input)
  "Return what a call of the git tool with INPUT is about: the words it runs."
  (let ((words (harness-tools-git--words input)))
    (and words (harness-first-line (string-join words " ") 70))))

(defun harness-tools-git--paths (input ctx)
  "Return the paths a call of the git tool with INPUT under CTX is about.
That is the top of the repository it runs in, so the jail asks about
the repository and not about the session's whole working directory."
  (let ((root (ignore-errors (harness-tools-git--root (harness-tools-git--directory input ctx)))))
    (if root (list root) (list (or (plist-get input :cwd) ".")))))

(defun harness-tools-git--run (input ctx)
  "Handler for the git tool with INPUT under CTX; returns a promise or a result."
  (let* ((words (harness-tools-git--words input))
         (timeout (min harness-tools-git--max-timeout
                       (max 1 (harness-tools-shell--number (plist-get input :timeout)
                                                           harness-tools-git--default-timeout))))
         (report (plist-get ctx :report))
         (dir (harness-tools-git--directory input ctx))
         (root (and dir (harness-tools-git--root dir))))
    (cond
     ((null words)
      (harness-tool-error "Missing command"))
     ((not (member (car words) harness-tools-git--subcommands))
      (harness-tool-error
       (format "Unknown git command %S. Give one git command line and its arguments, such as \"push -u origin HEAD\" or \"log --oneline -5\"."
               (car words))))
     ((null root)
      (harness-tool-error
       (format "No git repository in %s"
               (abbreviate-file-name (or dir (plist-get input :cwd)
                                         (plist-get ctx :cwd) default-directory)))))
     (t
      (harness-tools-git--execute ctx dir root words timeout report)))))

(defun harness-tools-git--execute (ctx dir root words timeout report)
  "Run WORDS in DIR, the repository at ROOT, for a call of CTX.
TIMEOUT is the seconds it may run and REPORT the function that takes
its output as it arrives.  Returns a promise of the tool's result, or
the result itself when nothing could be run."
  (let* ((material (condition-case err
                       (harness-tools-git-ssh-material)
                     (error (harness-log 'warn "git: could not read the ssh setup: %s"
                                         (harness-error-message err))
                            nil)))
         (command (harness-tools-git--command words))
         (env (harness-tools-git--environment material))
         (readable (plist-get material :readable))
         (started (float-time))
         ;; ENV goes to the sandbox for the backends that do not give a
         ;; command its caller's environment, and to the process itself
         ;; for the others; READABLE is what git is shown of the ssh
         ;; setup, read-only, for this one call.
         (wrapped (condition-case err
                      (harness-tools-shell--wrap dir command nil readable nil nil env)
                    (error (list :error (harness-error-message err))))))
    (if (and (consp wrapped) (eq (car wrapped) :error))
        (harness-tool-error (format "Cannot run git: %s" (plist-get wrapped :error)))
      (harness-tools-note ctx "running git")
      (harness-then
       (harness-run-command wrapped :cwd dir :timeout timeout :name "harness-git"
                            :env env
                            :merge-remote-stderr t
                            :on-output (and report (lambda (chunk) (funcall report chunk))))
       (lambda (r)
         (let ((exit (plist-get r :exit)))
           (funcall (if (eql exit 0) #'harness-tool-ok #'harness-tool-error)
                    (format "%s\n%s"
                            (string-join command " ")
                            (harness-tools-shell--format-output r timeout))
                    :meta (list :exit exit :cwd root
                                :duration (- (float-time) started)
                                :ssh-paths (and readable (length readable))
                                :sandboxed (not (equal wrapped command))))))))))

(harness-define-tool "git"
  :label "Git"
  :description "Run one git command in the session's repository, with the ssh setup it needs shown to that process alone. command is a git command line, such as \"status\", \"log --oneline -5\", \"fetch origin\" or \"push -u origin HEAD\", with or without the leading git; a list of words is taken as it is. No shell reads the words, so a quote or a | is an argument git gets. The tool runs git itself with GIT_TERMINAL_PROMPT=0 and an allowlist of ssh, https, http and git, so nothing can answer a prompt and no local path or other program is a transport. The user's ssh setup is not granted to the session: the tool shows the git process ~/.ssh/config, the known hosts and the identity files the configuration names, read-only, for that call only, and SSH_AUTH_SOCK when an agent is running, so git push, fetch and clone over ssh work without a grant of ~/.ssh. The repository's own configuration applies; the user's ~/.gitconfig is not shown, as no sandboxed command sees it. cwd is the repository, by default the working directory, and must be one. Use bash for anything that is not git."
  :schema '(:type "object"
            :properties (:command (:type "string" :description "One git command line and its arguments, such as \"push -u origin HEAD\"")
                         :cwd (:type "string" :description "The repository, or a directory in it, relative to the working directory. Default: the working directory")
                         :timeout (:type "integer" :description "Seconds before the command is killed. Default 120"))
            :required ("command"))
  :kind 'exec
  :coalescable t
  :timeout 3700
  :paths #'harness-tools-git--paths
  :subject #'harness-tools-git--subject
  :handler #'harness-tools-git--run)

(harness-define-module 'tools-git
  :doc "Git: one command in the repository, with ssh shown to that process alone."
  :requires '(tools tools-shell))

(provide 'harness-tools-git)
;;; harness-tools-git.el ends here
