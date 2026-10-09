;;; harness-sandbox.el --- Kernel-enforced confinement for tool processes  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every process the harness spawns on behalf of a model can be routed
;; through a kernel sandbox.  Isolation is enforced by the kernel
;; (mount and PID namespaces), not by policy: the permission mode is a
;; prompt-level hint, this is the boundary.
;;
;; A backend is picked when the module initialises, in preference
;; order: `bwrap' (bubblewrap), `systemd-run --user', or none.  The
;; `harness-sandbox-policy' setting from the config module decides what
;; happens when no backend exists:
;;
;;   required   `sandbox/wrap' signals `harness-sandbox-unavailable'
;;              (fail closed) and logs an error;
;;   preferred  the command runs unconfined, with a warning in the log;
;;   off        the command is always returned unchanged.
;;
;; What the sandbox sees: read-only /usr and /etc (plus the usual
;; /lib, /lib64, /bin, /sbin as symlinks or read-only binds), a fresh
;; /proc, /dev and /tmp, and the session's working directory
;; read-write.  The home directory's contents are *not* mounted
;; (credentials such as ~/.npmrc or ~/.aws stay out of reach).  With
;; bwrap $HOME keeps its path, but an empty tmpfs covers it, so ~/x
;; names the same path inside as outside and only what is mounted
;; there shows; systemd-run hides the home directories and points
;; $HOME at the private /tmp.  The only exception is a home directory
;; inside the working directory, which is then visible anyway.
;;
;; A caller shows more: `:writable' directories (or files) read-write
;; and `:readable' directories read-only.  The bash tool shows the
;; session's own temporary directory and every directory granted to the
;; session read-write, so a grant reaches bash as it reaches the other
;; tools, and the skills directories and the tool output directory
;; read-only.  Each is shown where it is named, where its symbolic links
;; lead and, under a $HOME that is not the real one's path (systemd-run),
;; at the same place under it, so ~/.claude/skills reads the same
;; inside as outside.  Network access stays on by default because
;; hosted providers and most build tools need it; pass `:network nil'
;; to cut it, which is only correct for local models.
;;
;; Remote working directories (TRAMP) are never wrapped: the sandbox
;; binaries and the mounts would have to exist on the remote host, and
;; the harness has no way to verify them there.  `sandbox/wrap'
;; returns such commands unchanged and logs at debug level.
;;
;; A caller that needs a command to change nothing -- a supervisor's
;; shell, which only looks -- passes `:read-only': the working
;; directory, the git directories and every `:writable' entry are then
;; mounted read-only, and the command writes nothing but the sandbox's
;; private /tmp.  It fails closed: where the command would run
;; unconfined, with the `off' policy, in a remote directory or with no
;; backend (whatever the policy), `sandbox/wrap' signals
;; `harness-sandbox-unavailable' instead of returning it.
;;
;; Seeing only its own directory makes some git commands destructive
;; inside the sandbox: `git worktree prune' takes every other worktree
;; of the repository for deleted and drops its registration.
;; `sandbox/check-command' finds those in a shell command line so the
;; permission layer can refuse them (see "Git worktree commands" below).
;;
;; Methods: `sandbox/wrap', `sandbox/status', `sandbox/confined-p',
;; `sandbox/check-command'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)

(defvar harness-sandbox-policy)         ; defined by the config module

(define-error 'harness-sandbox-unavailable
  "Sandbox required but no backend is available" 'harness-error)

(defcustom harness-sandbox-backend 'auto
  "Which sandbox backend to use.
`auto' picks the first available of bwrap and systemd-run; a specific
symbol forces that backend (and counts as unavailable when its
executable is missing); `none' disables wrapping regardless of policy
detection, subject to `harness-sandbox-policy'."
  :type '(choice (const auto) (const bwrap) (const systemd) (const none))
  :group 'harness)

(defconst harness-sandbox--bwrap-program "bwrap"
  "Name or path of the bubblewrap executable.")

(defconst harness-sandbox--systemd-run-program "systemd-run"
  "Name or path of the systemd-run executable.")

(defcustom harness-sandbox-extra-read-only-dirs nil
  "Additional directories bound read-only into every sandbox.
Useful for toolchains that live outside /usr, such as /opt or /nix."
  :type '(repeat directory) :group 'harness)

(defconst harness-sandbox--home "/tmp/harness-home"
  "Path used as $HOME inside a bwrap sandbox when the real one's path cannot be.
That is when $HOME is unset or names a directory no empty tmpfs may
cover (see `harness-sandbox--real-home').  It lives on the sandbox's
private /tmp, so it starts empty for every command and nothing written
there survives.")

(defconst harness-sandbox--system-paths '("/usr" "/etc" "/proc" "/dev" "/sys")
  "Directories a home directory must neither be, hold, nor lie in.
The sandbox mounts its own there, so an empty tmpfs on such a home
would hide them or be hidden by them.")

(defconst harness-sandbox--system-dirs '("/lib" "/lib64" "/bin" "/sbin")
  "Top-level directories mirrored as symlinks or read-only binds.")

(defvar harness-sandbox--backend nil
  "Backend chosen at initialisation: `bwrap', `systemd' or `none'.")

(defvar harness-sandbox--available nil
  "Backends whose executables were found at initialisation.")

(defvar harness-sandbox--programs nil
  "Alist of backend -> absolute executable path found at initialisation.")

;;;; Detection

(defun harness-sandbox-detect ()
  "Find the available backends and choose one.
Return the chosen backend symbol.  Safe to call again: it refreshes
`harness-sandbox--available' and `harness-sandbox--backend'."
  (let ((bwrap (executable-find harness-sandbox--bwrap-program))
        (systemd (executable-find harness-sandbox--systemd-run-program)))
    (setq harness-sandbox--programs
          (delq nil (list (and bwrap (cons 'bwrap bwrap))
                          (and systemd (cons 'systemd systemd)))))
    (setq harness-sandbox--available (mapcar #'car harness-sandbox--programs))
    (setq harness-sandbox--backend
          (pcase harness-sandbox-backend
            ('auto (or (car harness-sandbox--available) 'none))
            ('none 'none)
            (forced (if (memq forced harness-sandbox--available) forced 'none))))
    (harness-log 'info "sandbox: backend %s (available: %s, policy %s)"
                 harness-sandbox--backend
                 (if harness-sandbox--available
                     (mapconcat #'symbol-name harness-sandbox--available ", ")
                   "none")
                 (harness-sandbox--policy nil))
    harness-sandbox--backend))

(defun harness-sandbox--policy (cwd)
  "Return the effective sandbox policy for a session at CWD."
  (or (and cwd (not (file-remote-p cwd))
           (harness-method-exists-p 'config/get)
           (ignore-errors (harness-call 'config/get 'harness-sandbox-policy cwd)))
      (and (boundp 'harness-sandbox-policy) harness-sandbox-policy)
      'preferred))

;;;; Argument construction

(defun harness-sandbox--dir-args (dir mode)
  "Return bwrap arguments exposing DIR with MODE (`ro' or `rw'), or nil."
  (when (and dir (file-directory-p dir))
    (let ((d (directory-file-name (expand-file-name dir))))
      (list (if (eq mode 'rw) "--bind" "--ro-bind") d d))))

(defun harness-sandbox--system-dir-args ()
  "Mirror /lib, /lib64, /bin and /sbin the way the host has them."
  (cl-loop for d in harness-sandbox--system-dirs
           for target = (file-symlink-p d)
           append (cond (target (list "--symlink" target d))
                        ((file-directory-p d) (list "--ro-bind" d d)))))

(defun harness-sandbox--home-inside-p (cwd)
  "Non-nil when the real HOME lies inside CWD (and is thus visible anyway)."
  (let ((home (getenv "HOME")))
    (and home (harness-path-within-p cwd home))))

(defun harness-sandbox--real-home ()
  "Return the home directory an empty tmpfs may cover, without a slash, or nil.
That is $HOME, absolute and local, unless it is the root directory or
is, holds or lies in one of `harness-sandbox--system-paths': bwrap
then keeps $HOME's path inside the sandbox, emptied, rather than
moving it to `harness-sandbox--home'."
  (let ((home (getenv "HOME")))
    (when (and (stringp home) (file-name-absolute-p home) (not (file-remote-p home)))
      (let ((home (directory-file-name (expand-file-name home))))
        (unless (or (equal home "/")
                    (cl-some (lambda (system)
                               (or (harness-path-within-p system home) (harness-path-within-p home system)))
                             harness-sandbox--system-paths))
          home)))))

(defun harness-sandbox--mounts (readable writable cwd home)
  "Return the mounts showing READABLE and WRITABLE as (MODE SOURCE DESTINATION).
MODE is `ro' for READABLE, which lists directories, and `rw' for
WRITABLE, which lists directories and files.  Each one that exists is
shown where it is named and where its symbolic links lead, and, when
it lies under the real home directory, at the same place under HOME,
the sandbox's $HOME when that is not the real home's path (nil
otherwise), so that ~/... names it inside as well.  Left out are what
lies inside CWD, which is shown read-write anyway; a readable
directory that is or holds the real home directory, which the sandbox
hides (a writable one was granted, so it shows); and the root
directory, which would cover the sandbox's own /proc, /dev and /tmp.

A destination below another one is left out when it shows through
that one as it is, a symbolic link included: below a writable one, or
a readable one below a readable one.  bwrap refuses to mount on a link,
and a skill linked into ~/.claude/skills is one.  A writable
destination below a readable one stays when it is its own real path,
with no link on the way, and is mounted after it, so a granted
directory in a skills directory is writable.  A destination named
both ways is writable when either list has it.  A destination holding
CWD when symbolic links lead CWD elsewhere is left out too, since the
working directory is mounted where it is named, after these."
  (let* ((real-home (file-name-as-directory (expand-file-name "~")))
         (cwd-dir (file-name-as-directory (expand-file-name cwd)))
         (cwd-linked (not (equal cwd-dir (file-name-as-directory (file-truename cwd-dir)))))
         (below (lambda (dir parent)
                  (let ((dir (file-name-as-directory dir)) (parent (file-name-as-directory parent)))
                    (and (not (equal dir parent)) (string-prefix-p parent dir)))))
         (alias (lambda (path)
                  (and home (string-prefix-p real-home path)
                       (not (equal (file-name-as-directory path) real-home))
                       (expand-file-name (substring path (length real-home)) home))))
         mounts)
    (pcase-dolist (`(,mode . ,paths) (list (cons 'ro readable) (cons 'rw writable)))
      (dolist (d paths)
        (let* ((named (and (stringp d) (not (file-remote-p d)) (expand-file-name d)))
               (dir (and named (file-directory-p named)))
               (real (and named (or dir (and (eq mode 'rw) (file-exists-p named)))
                          (funcall (if dir #'file-name-as-directory #'directory-file-name)
                                   (file-truename named))))
               (named (and real (funcall (if dir #'file-name-as-directory #'directory-file-name) named))))
          (cond
           ((or (null real) (harness-path-within-p cwd real)) nil)
           ((equal real "/")
            (harness-log 'warn "sandbox: not showing %s, the root directory" d))
           ((and (eq mode 'ro) (harness-path-within-p real real-home))
            (harness-log 'warn "sandbox: not showing %s, which holds the home directory" d))
           (t
            (dolist (dest (delq nil (list named real (funcall alias named) (funcall alias real))))
              (let* ((dest (directory-file-name dest))
                     (old (cl-find dest mounts :key #'caddr :test #'equal)))
                (cond
                 ((and cwd-linked (funcall below cwd-dir dest)) nil)
                 ((null old) (push (list mode (directory-file-name real) dest) mounts))
                 ((and (eq mode 'rw) (eq (car old) 'ro))
                  (setcar old 'rw)
                  (setcar (cdr old) (directory-file-name real)))))))))))
    (setq mounts (nreverse mounts))
    (cl-remove-if (lambda (m)
                    (cl-some (lambda (o)
                               (and (funcall below (nth 2 m) (nth 2 o))
                                    (or (eq (car o) 'rw) (eq (car m) 'ro)
                                        (not (equal (nth 1 m) (nth 2 m))))))
                             mounts))
                  ;; Read-only first: a writable mount covers what it holds.
                  (append (cl-remove-if-not (lambda (m) (eq (car m) 'ro)) mounts)
                          (cl-remove-if-not (lambda (m) (eq (car m) 'rw)) mounts)))))

(defun harness-sandbox--readable-mounts (readable cwd home)
  "Return the read-only mounts showing READABLE as (SOURCE . DESTINATION).
See `harness-sandbox--mounts', of which these are the READABLE ones
with no writable ones beside them; CWD and HOME are as there."
  (mapcar (lambda (m) (cons (nth 1 m) (nth 2 m)))
          (harness-sandbox--mounts readable nil cwd home)))

(defun harness-sandbox--systemd-path-p (path)
  "Non-nil when PATH can be written in a systemd mount setting as it is.
Whitespace, colons, quotes and backslashes are separators or escapes
there."
  (not (string-match-p "[[:space:]:\"'\\]" path)))

;;;; Git worktrees

;; A linked worktree's .git is a file pointing into the main repository's
;; git directory, which lies outside the worktree.  Without it git cannot
;; commit, so the sandbox mounts it read-write -- except its hooks and
;; config, which stay read-only: the harness runs git unconfined in the
;; main checkout (the merge queue), and a planted hook or core.hooksPath
;; would run there outside the jail.  The main checkout's index and HEAD
;; stay read-only too: the sandbox does not show the main checkout's
;; files, so `git -C MAIN …' from a worktree sees every file deleted,
;; and anything it staged or checked out there would wreck that
;; checkout's index (a worktree keeps its own index and HEAD under
;; worktrees/).  The sandbox hides ~/.gitconfig, so the host's commit
;; identity is passed in through the environment.

(defvar harness-sandbox--git-identity (make-hash-table :test 'equal)
  "Git common dir -> (NAME . EMAIL) as the host's git config gives them.")

(defun harness-sandbox--read-file-line (file)
  "Return the text of FILE with surrounding whitespace trimmed.
FILE holds one line, as a worktree's .git file and the commondir file
of its git directory do."
  (with-temp-buffer (insert-file-contents file) (string-trim (buffer-string))))

(defun harness-sandbox--worktree-git (cwd)
  "When CWD is inside a linked git worktree, describe its git directory.
Return (:common DIR :protected (PATH…)) or nil."
  (let* ((top (locate-dominating-file cwd ".git"))
         (dotgit (and top (expand-file-name ".git" top))))
    (when (and dotgit (file-regular-p dotgit))
      (let* ((line (harness-sandbox--read-file-line dotgit))
             (gitdir (and (string-match "\\`gitdir: *\\(.+\\)\\'" line)
                          (expand-file-name (match-string 1 line) top)))
             (commondir (and gitdir (expand-file-name "commondir" gitdir)))
             (common (and gitdir
                          (file-name-as-directory
                           (if (file-exists-p commondir)
                               (expand-file-name (harness-sandbox--read-file-line commondir) gitdir)
                             gitdir)))))
        (when (and common (file-directory-p common))
          (list :common common
                :protected (cl-remove-if-not #'file-exists-p
                                             (list (expand-file-name "hooks" common)
                                                   (expand-file-name "config" common)
                                                   (expand-file-name "index" common)
                                                   (expand-file-name "HEAD" common)))))))))

(defun harness-sandbox--git-identity (common)
  "Return the host's (NAME . EMAIL) for the repository at COMMON, cached."
  (with-memoization (gethash common harness-sandbox--git-identity)
    (let ((default-directory common)
          (get (lambda (key) (ignore-errors (car (process-lines "git" "config" "--get" key))))))
      (cons (funcall get "user.name") (funcall get "user.email")))))

(defun harness-sandbox--git-env (common)
  "Return (VAR . VALUE) pairs carrying the host's commit identity for COMMON."
  (let ((id (harness-sandbox--git-identity common)))
    (append (and (car id) (list (cons "GIT_AUTHOR_NAME" (car id)) (cons "GIT_COMMITTER_NAME" (car id))))
            (and (cdr id) (list (cons "GIT_AUTHOR_EMAIL" (cdr id)) (cons "GIT_COMMITTER_EMAIL" (cdr id)))))))

(defun harness-sandbox--bwrap-git-args (cwd &optional read-only)
  "Return the bwrap arguments that let git work in a worktree at CWD.
With READ-ONLY the git directory is shown read-only whole, hooks,
config, index and HEAD no more or less than the rest: git then reads
the repository and changes none of it."
  (when-let* ((git (harness-sandbox--worktree-git cwd)))
    (let ((common (directory-file-name (plist-get git :common))))
      (append (list (if read-only "--ro-bind" "--bind") common common)
              (unless read-only
                (cl-loop for p in (plist-get git :protected) append (list "--ro-bind" p p)))
              (cl-loop for (var . value) in (harness-sandbox--git-env (plist-get git :common))
                       append (list "--setenv" var value))))))

(defun harness-sandbox--systemd-git-args (cwd &optional read-only)
  "Return the systemd-run arguments that let git work in a worktree at CWD.
With READ-ONLY the git directory is bound read-only whole and not made
writable, as for `harness-sandbox--bwrap-git-args'."
  (when-let* ((git (harness-sandbox--worktree-git cwd)))
    (let ((common (directory-file-name (plist-get git :common))))
      (append (if read-only
                  (list "-p" (concat "BindReadOnlyPaths=" common))
                (append (list "-p" (concat "BindPaths=" common) "-p" (concat "ReadWritePaths=" common))
                        (cl-loop for p in (plist-get git :protected)
                                 append (list "-p" (concat "BindReadOnlyPaths=" p)))))
              (cl-loop for (var . value) in (harness-sandbox--git-env (plist-get git :common))
                       collect (format "--setenv=%s=%s" var value))))))

(cl-defun harness-sandbox--bwrap-command (program cwd command &key (network t) writable readable read-only)
  "Build the bwrap command line running COMMAND in CWD.
PROGRAM is the bwrap executable.  NETWORK nil unshares the network
namespace; WRITABLE and READABLE list extra directories to expose (see
`harness-sandbox--mounts' for how they are shown).  READ-ONLY binds
CWD, the git directories and every WRITABLE entry with `--ro-bind', so
that the command writes nothing but the sandbox's private /tmp.

$HOME keeps its path: an empty tmpfs covers the home directory, so
~/x names the same path inside as outside and shows only what is
mounted there.  A home directory inside CWD is shown as it is; one no
tmpfs may cover (see `harness-sandbox--real-home') gives way to
`harness-sandbox--home', with the directories under the real one shown
under it too."
  (let* ((cwd (directory-file-name (expand-file-name cwd)))
         (inside (harness-sandbox--home-inside-p cwd))
         (real-home (and (not inside) (harness-sandbox--real-home)))
         (private (and (not inside) (not real-home) harness-sandbox--home)))
    (append
     (list program
           "--ro-bind" "/usr" "/usr"
           "--ro-bind" "/etc" "/etc")
     (harness-sandbox--system-dir-args)
     (list "--proc" "/proc"
           "--dev" "/dev"
           "--tmpfs" "/tmp")
     ;; The home directory after /tmp, which may hold it; binds after
     ;; both, so neither hides them.
     (cond (real-home (list "--tmpfs" real-home))
           (private (list "--dir" private)))
     (cl-loop for d in harness-sandbox-extra-read-only-dirs
              append (harness-sandbox--dir-args d 'ro))
     ;; The read-only binds before the others, and the working directory
     ;; last: a later mount covers what an earlier one shows below it, so
     ;; the working directory stays writable inside a read-only directory.
     (cl-loop for (mode source dest) in (harness-sandbox--mounts readable writable cwd private)
              append (list (if (and (eq mode 'rw) (not read-only)) "--bind" "--ro-bind") source dest))
     (list (if read-only "--ro-bind" "--bind") cwd cwd)
     (harness-sandbox--bwrap-git-args cwd read-only)
     (list "--unshare-pid" "--unshare-ipc" "--unshare-uts"
           "--die-with-parent" "--new-session"
           "--chdir" cwd)
     (and private (list "--setenv" "HOME" private))
     (unless network (list "--unshare-net"))
     (list "--")
     command)))

(cl-defun harness-sandbox--systemd-command (program cwd command &key (network t) writable readable read-only)
  "Build the systemd-run command line running COMMAND in CWD.
PROGRAM is the systemd-run executable; NETWORK, WRITABLE, READABLE and
READ-ONLY are as for `harness-sandbox--bwrap-command'.  READ-ONLY binds
CWD, the git directories and every WRITABLE entry with
`BindReadOnlyPaths=', sets no `ReadWritePaths=', and makes the rest of
the file system read-only with `ProtectSystem=strict': unlike bwrap's,
this sandbox shows the whole file system, and only the user's own files
are hidden (`ProtectHome=tmpfs'), so what it does not show it must
still refuse to write.

Home directories are hidden with `ProtectHome=tmpfs' rather than
`ProtectHome=yes': with the latter systemd cannot mount anything
beneath /home, so a working directory in the user's home would be
unreachable (systemd-run fails with status 200).  That tmpfs is
read-only, so $HOME is the private /tmp, and the directories shown
under the real home directory are shown at the same place under it
too, so ~/x reaches them."
  (let ((cwd (directory-file-name (expand-file-name cwd))))
    (append
     (list program "--user" "--quiet" "--pipe" "--wait" "--collect"
           (concat "--working-directory=" cwd)
           "-p" "PrivateTmp=yes"
           "-p" "ProtectHome=tmpfs")
     (if read-only
         (list "-p" "ProtectSystem=strict"
               "-p" (concat "BindReadOnlyPaths=" cwd))
       (list "-p" (concat "BindPaths=" cwd)
             "-p" (concat "ReadWritePaths=" cwd)))
     ;; systemd orders the mounts itself, a directory before what lies
     ;; in it.  A path its setting cannot hold as written is not shown.
     (cl-loop for (mode source dest) in (harness-sandbox--mounts
                                         readable writable cwd (unless (harness-sandbox--home-inside-p cwd) "/tmp"))
              if (and (harness-sandbox--systemd-path-p source) (harness-sandbox--systemd-path-p dest))
              append (list "-p" (concat (if (and (eq mode 'rw) (not read-only)) "BindPaths=" "BindReadOnlyPaths=")
                                        source (if (equal source dest) "" (concat ":" dest))))
              else do (harness-log 'debug "sandbox: systemd cannot show %s at %s" source dest))
     (harness-sandbox--systemd-git-args cwd read-only)
     (unless network (list "-p" "PrivateNetwork=yes"))
     (unless (harness-sandbox--home-inside-p cwd)
       (list "--setenv=HOME=/tmp"))
     (list "--")
     command)))

;;;; Methods

(defun harness-sandbox--refuse-read-only (command why)
  "Signal `harness-sandbox-unavailable': a read-only COMMAND cannot be confined.
WHY says what stands in the way.  A command that is to write nothing
must not run unconfined, whatever the policy says."
  (harness-log 'error "sandbox: a read-only command needs the sandbox, but %s; refusing to run %S"
               why (car command))
  (signal 'harness-sandbox-unavailable
          (list (format "a read-only command cannot run unconfined, but %s" why))))

(harness-defmethod sandbox/wrap (cwd command &rest opts)
  "Return COMMAND (a list of strings) wrapped to run confined in CWD.
OPTS: `:network' (default t; nil cuts network access), `:writable'
\(extra directories or files mounted read-write, such as the
directories granted to a session) and `:readable' (extra read-only
directories).  Both are shown where they are named, where their
symbolic links lead and, under a sandbox $HOME that is not the real
one's path, where they are under the real one; see
`harness-sandbox--mounts'.  `:read-only' non-nil mounts read-only the
working directory, the git directories and every `:writable' entry as
well, so that the command can write nothing but the sandbox's private
/tmp.  A remote CWD or the `off' policy return COMMAND unchanged.
Signals `harness-sandbox-unavailable' when the policy is `required' and
no backend exists.  A `:read-only' command fails closed instead of
running unconfined: it signals `harness-sandbox-unavailable' too for
the `off' policy, for a remote CWD and for no backend, whatever the
policy."
  (let ((policy (harness-sandbox--policy cwd))
        (network (if (plist-member opts :network) (plist-get opts :network) t))
        (writable (plist-get opts :writable))
        (readable (plist-get opts :readable))
        (read-only (harness-json-true-p (plist-get opts :read-only))))
    (cond
     ((and read-only (eq policy 'off))
      (harness-sandbox--refuse-read-only command "the sandbox policy is `off'"))
     ((eq policy 'off) command)
     ((file-remote-p cwd)
      (when read-only
        (harness-sandbox--refuse-read-only
         command (format "%s is on another host, where the sandbox does not reach" cwd)))
      (harness-log 'debug "sandbox: remote cwd %s runs unconfined" cwd)
      command)
     ((eq harness-sandbox--backend 'bwrap)
      (harness-sandbox--bwrap-command (alist-get 'bwrap harness-sandbox--programs) cwd command
                                      :network network :writable writable :readable readable
                                      :read-only read-only))
     ((eq harness-sandbox--backend 'systemd)
      (harness-sandbox--systemd-command (alist-get 'systemd harness-sandbox--programs) cwd command
                                        :network network :writable writable :readable readable
                                        :read-only read-only))
     (read-only
      (harness-sandbox--refuse-read-only command "neither bwrap nor systemd-run is available"))
     ((eq policy 'required)
      (harness-log 'error "sandbox: policy is `required' but no backend (bwrap, systemd-run) is available; refusing to run %S"
                   (car command))
      (signal 'harness-sandbox-unavailable
              (list "harness-sandbox-policy is `required' but neither bwrap nor systemd-run is available")))
     (t
      (harness-log 'warn "sandbox: no backend available; running %S unconfined" (car command))
      command))))

(harness-defmethod sandbox/status ()
  "Return (:backend BACKEND :available (BACKENDS…) :policy POLICY)."
  (list :backend (or harness-sandbox--backend 'none)
        :available harness-sandbox--available
        :policy (harness-sandbox--policy nil)))

(harness-defmethod sandbox/confined-p (cwd)
  "Non-nil when commands run in CWD are confined by a sandbox backend.
They are not when no backend exists, the policy is `off' or CWD is
remote: such a command sees what the user sees."
  (harness-sandbox--confined-p cwd))

;;;; Git worktree commands the sandbox makes destructive

;; In the sandbox git sees the session's directory and the repository's
;; git directory, but no other worktree's files.  So it takes every
;; other worktree for deleted: `git worktree prune' drops their
;; registration, which leaves their files without an index and every git
;; command in them failing.  Unlocking, removing or moving another
;; worktree from in here does damage just as blindly.  The harness locks
;; its worktrees, which prune always skips; on top of that
;; `sandbox/check-command' finds such commands in a command line, so the
;; permission layer refuses them before they run.
;;
;; The command line is read the way the shell reads it, closely enough:
;; quotes and backslashes; operators (; & | && || newlines, parentheses,
;; redirections) between commands; command substitutions, `sh -c' and
;; `eval' scripts read on their own; wrappers like env, timeout, xargs
;; or find; `cd'; and git's global options, -C and aliases defined with
;; -c alias.NAME=....  Shell variables, scripts run from files and
;; aliases from git's config are not resolved: the locks protect the
;; harness's worktrees from those.
;; Like git, a worktree may be named by the end of its path.

(defconst harness-sandbox--shells '("sh" "bash" "dash" "zsh" "ksh" "mksh" "ash" "busybox")
  "Programs whose -c argument is a script of its own.")

(defconst harness-sandbox--wrappers
  '("env" "command" "builtin" "exec" "nohup" "nice" "ionice" "timeout" "time" "stdbuf"
    "setsid" "xargs" "find" "flock" "chronic" "unbuffer" "watch")
  "Programs that run a command given among their arguments.")

(defconst harness-sandbox--open-wrappers '("xargs" "find")
  "Wrappers that give the command more arguments when it runs.")

(defconst harness-sandbox--reserved-words
  '("!" "{" "}" "if" "then" "else" "elif" "do" "while" "until" "time" "coproc")
  "Shell words that may stand before a command.")

(defconst harness-sandbox--git-options-with-value
  '("-C" "-c" "--git-dir" "--work-tree" "--namespace" "--super-prefix" "--attr-source" "--config-env")
  "Global options of git that take the next word as their value.")

(defconst harness-sandbox--max-depth 8
  "How deep scripts within scripts are read.")

(defun harness-sandbox--closing-paren (string start)
  "Return the index of the parenthesis closing the one before START in STRING.
Nested parentheses and quoted text are skipped.  Return the length of
STRING when nothing closes it."
  (let ((depth 1) (i start) (n (length string)) (quote nil))
    (while (and (< i n) (> depth 0))
      (let ((c (aref string i)))
        (cond
         (quote (cond ((and (eq c ?\\) (eq quote ?\")) (cl-incf i))
                      ((eq c quote) (setq quote nil))))
         ((eq c ?\\) (cl-incf i))
         ((memq c '(?' ?\")) (setq quote c))
         ((eq c ?\() (cl-incf depth))
         ((eq c ?\)) (cl-decf depth))))
      (when (> depth 0) (cl-incf i)))
    (min i n)))

(defun harness-sandbox--closing-backtick (string start)
  "Return the index of the backtick closing the one before START in STRING.
Return the length of STRING when nothing closes it."
  (let ((i start) (n (length string)))
    (while (and (< i n) (not (eq (aref string i) ?`)))
      (cl-incf i (if (eq (aref string i) ?\\) 2 1)))
    (min i n)))

(defun harness-sandbox--double-quoted (string i add substitution)
  "Read the double-quoted text of STRING from I, just after the quote.
Call ADD with each character the shell keeps and SUBSTITUTION with
the start and end of each command substitution.  Return the index
after the closing quote."
  (let ((n (length string)))
    (while (and (< i n) (not (eq (aref string i) ?\")))
      (let ((d (aref string i)))
        (cond
         ((and (eq d ?\\) (< (1+ i) n) (memq (aref string (1+ i)) '(?\" ?\\ ?$ ?` ?\n)))
          (unless (eq (aref string (1+ i)) ?\n) (funcall add (aref string (1+ i))))
          (cl-incf i 2))
         ((and (eq d ?$) (< (1+ i) n) (eq (aref string (1+ i)) ?\())
          (let ((end (harness-sandbox--closing-paren string (+ i 2))))
            (funcall substitution (+ i 2) end)
            (setq i (1+ end))))
         ((eq d ?`)
          (let ((end (harness-sandbox--closing-backtick string (1+ i))))
            (funcall substitution (1+ i) end)
            (setq i (1+ end))))
         (t (funcall add d) (cl-incf i)))))
    (1+ i)))

(defun harness-sandbox--add (state c)
  "Add character C to the word being read in STATE."
  (plist-put state :chars (cons c (plist-get state :chars)))
  (plist-put state :in-word t))

(defun harness-sandbox--end-word (state)
  "End the word being read in STATE, if any.
The word right after a redirection names its file, and is dropped."
  (when (plist-get state :in-word)
    (if (plist-get state :skip)
        (plist-put state :skip nil)
      (plist-put state :words (cons (concat (nreverse (plist-get state :chars))) (plist-get state :words)))))
  (plist-put state :chars nil)
  (plist-put state :in-word nil))

(defun harness-sandbox--end-command (state &optional op)
  "End the simple command being read in STATE, if any.
OP is the operator that ends it, a string, nil at the end of the text."
  (harness-sandbox--end-word state)
  (when (plist-get state :words)
    (plist-put state :commands (cons (cons (nreverse (plist-get state :words)) op)
                                     (plist-get state :commands))))
  (plist-put state :words nil)
  (plist-put state :skip nil))

(defun harness-sandbox--subshell (state c)
  "End the command being read in STATE at parenthesis C; mark the subshell.
An `open' entry starts it and a `close' entry ends it."
  (harness-sandbox--end-command state (string c))
  (plist-put state :commands (cons (if (eq c ?\() 'open 'close) (plist-get state :commands))))

(defun harness-sandbox--redirection (state i)
  "Read the redirection at index I of STATE's string; return the index after it.
A file descriptor number right before it is no argument; neither is the
file it names, which the next word is.  Duplicating a descriptor (>&2,
<&-) names no file."
  (let* ((string (plist-get state :string))
         (n (length string))
         (j (1+ i))
         (fd-p (lambda (ch) (or (<= ?0 ch ?9) (eq ch ?-)))))
    (if (and (plist-get state :in-word) (cl-every (lambda (ch) (<= ?0 ch ?9)) (plist-get state :chars)))
        (progn (plist-put state :chars nil) (plist-put state :in-word nil))
      (harness-sandbox--end-word state))
    (while (and (< j n) (memq (aref string j) '(?< ?> ?& ?|))) (cl-incf j))
    (if (and (eq (aref string (1- j)) ?&) (< j n) (funcall fd-p (aref string j)))
        (while (and (< j n) (funcall fd-p (aref string j))) (cl-incf j))
      (plist-put state :skip t))
    j))

(defun harness-sandbox--substitution (state start end)
  "Note the command substitution from START to END of STATE's string.
Its text is read on its own later; its word gets a $ for it."
  (plist-put state :nested (cons (substring (plist-get state :string) start end) (plist-get state :nested)))
  (harness-sandbox--add state ?$))

(defun harness-sandbox--shell-step (state i)
  "Read the shell text of STATE at index I; return the index after it."
  (let* ((string (plist-get state :string))
         (n (length string))
         (c (aref string i))
         (next (and (< (1+ i) n) (aref string (1+ i)))))
    (cond
     ((memq c '(?\s ?\t ?\r)) (harness-sandbox--end-word state) (1+ i))
     ((or (memq c '(?< ?>)) (and (eq c ?&) (eq next ?>)))
      (harness-sandbox--redirection state i))
     ((memq c '(?\( ?\))) (harness-sandbox--subshell state c) (1+ i))
     ((memq c '(?\n ?\; ?& ?|))
      (let ((op (if (and (memq c '(?& ?|)) (eq next c)) (string c c) (string c))))
        (harness-sandbox--end-command state op)
        (+ i (length op))))
     ((and (eq c ?#) (not (plist-get state :in-word)))
      (or (string-search "\n" string i) n))
     ((eq c ?\\)
      (when (and next (not (eq next ?\n))) (harness-sandbox--add state next))
      (+ i 2))
     ((eq c ?')
      (let ((end (or (string-search "'" string (1+ i)) n)))
        (plist-put state :in-word t)
        (mapc (lambda (ch) (harness-sandbox--add state ch)) (substring string (1+ i) end))
        (1+ end)))
     ((eq c ?\")
      (plist-put state :in-word t)
      (harness-sandbox--double-quoted string (1+ i)
                                      (lambda (ch) (harness-sandbox--add state ch))
                                      (lambda (s e) (harness-sandbox--substitution state s e))))
     ((and (eq c ?$) (eq next ?\())
      (let ((end (harness-sandbox--closing-paren string (+ i 2))))
        (harness-sandbox--substitution state (+ i 2) end)
        (1+ end)))
     ((eq c ?`)
      (let ((end (harness-sandbox--closing-backtick string (1+ i))))
        (harness-sandbox--substitution state (1+ i) end)
        (1+ end)))
     (t (harness-sandbox--add state c) (1+ i)))))

(defun harness-sandbox--shell-parse (string)
  "Split the shell command line STRING into simple commands.
Return (ENTRIES . NESTED).  ENTRIES lists the simple commands in order
as (WORDS . OP): their words, quotes and backslashes removed as the
shell removes them, and the operator that ends them (nil at the end);
`open' and `close' entries stand where a subshell starts and ends.
NESTED lists the text of the command substitutions found, each a
command line of its own; a substitution leaves a $ in its word."
  (let ((state (list :string string :chars nil :in-word nil :skip nil :words nil :commands nil :nested nil))
        (i 0))
    (while (< i (length string))
      (setq i (harness-sandbox--shell-step state i)))
    (harness-sandbox--end-command state)
    (cons (nreverse (plist-get state :commands)) (nreverse (plist-get state :nested)))))

(defun harness-sandbox--program (word)
  "Return the program name WORD runs: its last path component."
  (file-name-nondirectory word))

(defun harness-sandbox--command-word-p (word)
  "Non-nil when WORD names git, a shell, eval or a wrapper."
  (let ((program (harness-sandbox--program word)))
    (or (member program '("git" "eval"))
        (member program harness-sandbox--shells)
        (member program harness-sandbox--wrappers))))

(defun harness-sandbox--command (words)
  "Return (WORDS . OPEN): the simple command WORDS without what precedes it.
Assignments and reserved words go; after a wrapper (env, timeout,
xargs...) the command starts at the next word naming git, a shell or
eval.  OPEN is non-nil when a wrapper adds arguments at run time."
  (let ((open nil))
    (while (and words (or (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*=" (car words))
                          (member (car words) harness-sandbox--reserved-words)))
      (pop words))
    (while (and words (member (harness-sandbox--program (car words)) harness-sandbox--wrappers))
      (when (member (harness-sandbox--program (car words)) harness-sandbox--open-wrappers)
        (setq open t))
      (setq words (seq-drop-while (lambda (w) (not (harness-sandbox--command-word-p w))) (cdr words))))
    (cons words open)))

(defun harness-sandbox--dynamic-p (word)
  "Non-nil when the shell may turn WORD into something else when it runs.
That is a word with a variable, a substitution, a glob or a tilde."
  (or (string-match-p "[$`*?[{}]" word) (string-prefix-p "~" word)))

(defun harness-sandbox--resolve-dir (word dir)
  "Return directory WORD taken relative to DIR, or nil when it cannot be told."
  (cond ((harness-sandbox--dynamic-p word) nil)
        ((file-name-absolute-p word) (file-name-as-directory (expand-file-name word)))
        (dir (file-name-as-directory (expand-file-name word dir)))))

(defun harness-sandbox--cd (args dir)
  "Return the directory `cd' with ARGS leads to from DIR, or nil when unknown."
  (let ((args (seq-drop-while (lambda (a) (string-match-p "\\`-[LPe@]+\\'" a)) args)))
    (and args (not (equal (car args) "-")) (harness-sandbox--resolve-dir (car args) dir))))

(defun harness-sandbox--git-call (args dir open)
  "Return what git with ARGS, run in DIR, does to worktrees, or nil.
Return (:action prune|unlock|remove|move :dir DIR :args WORDS :open
OPEN) for the `git worktree' actions that matter, DIR being the
directory after -C (nil when it cannot be told), or (:script TEXT
:dir DIR) for an alias that runs a shell command.  OPEN non-nil means
xargs or find add arguments at run time."
  (let ((aliases nil) (sub nil))
    (while (and args (not sub))
      (let ((a (pop args)))
        (cond
         ((equal a "-C") (let ((d (pop args))) (setq dir (and d (harness-sandbox--resolve-dir d dir)))))
         ((equal a "-c")
          (let ((kv (pop args)))
            (when (and kv (string-match "\\`alias\\.\\([^=]+\\)=\\(.*\\)\\'" kv))
              (push (cons (match-string 1 kv) (match-string 2 kv)) aliases))))
         ((member a harness-sandbox--git-options-with-value) (pop args))
         ((string-prefix-p "-" a) nil)
         (t (setq sub a)))))
    (let ((alias (and sub (cdr (assoc sub aliases)))))
      (cond
       ((and alias (string-prefix-p "!" alias)) (list :script (substring alias 1) :dir dir))
       (alias (harness-sandbox--git-call (append (car (seq-find #'consp (car (harness-sandbox--shell-parse alias))))
                                                 args)
                                         dir open))
       ((equal sub "worktree")
        (let ((action (seq-find (lambda (a) (not (string-prefix-p "-" a))) args)))
          (when (member action '("prune" "unlock" "remove" "move"))
            (list :action action :dir dir :open open :args (cdr (member action args))))))))))

(defun harness-sandbox--operands (args)
  "Return the operands among ARGS: the words that are not options."
  (let ((out nil) (only-operands nil))
    (dolist (a args (nreverse out))
      (cond (only-operands (push a out))
            ((equal a "--") (setq only-operands t))
            ((string-prefix-p "-" a) nil)
            (t (push a out))))))

(defun harness-sandbox--shell-script (args)
  "Return the script of a shell run with ARGS and -c, or nil."
  (let ((flag (seq-drop-while (lambda (a) (not (string-match-p "\\`-[A-Za-z]*c[A-Za-z]*\\'" a))) args)))
    (seq-find (lambda (a) (not (string-prefix-p "-" a))) (cdr flag))))

(defun harness-sandbox--git-worktree-calls (string dir &optional depth)
  "Return the `git worktree' prune, unlock, remove and move calls in STRING.
STRING is a shell command line run in directory DIR.  Each call is a
plist (:action :dir :args :open), see `harness-sandbox--git-call'.
Scripts inside it (substitutions, `sh -c', `eval', git aliases that
run a shell command) are read too; DEPTH counts how deep."
  (let ((depth (or depth 0))
        (start dir)
        (outer nil)
        (calls nil))
    (when (< depth harness-sandbox--max-depth)
      (let ((parsed (harness-sandbox--shell-parse string)))
        (cl-flet ((scan (text in)
                    (setq calls (append calls (harness-sandbox--git-worktree-calls text in (1+ depth))))))
          (dolist (entry (car parsed))
            (pcase entry
              ('open (push dir outer))
              ('close (when outer (setq dir (pop outer))))
              (`(,command . ,op)
               (pcase-let* ((`(,words . ,open) (harness-sandbox--command command))
                            (program (and words (harness-sandbox--program (car words)))))
                 (cond
                  ((null words))
                  ;; A directory change carries on to the next command,
                  ;; unless it ran in a pipe or the background.
                  ((member program '("cd" "pushd"))
                   (unless (member op '("|" "&"))
                     (setq dir (harness-sandbox--cd (cdr words) dir))))
                  ((equal program "popd") (unless (member op '("|" "&")) (setq dir nil)))
                  ((equal program "git")
                   (let ((call (harness-sandbox--git-call (cdr words) dir open)))
                     (cond ((plist-get call :script) (scan (plist-get call :script) (plist-get call :dir)))
                           (call (setq calls (append calls (list call)))))))
                  ((member program harness-sandbox--shells)
                   (when-let* ((script (harness-sandbox--shell-script (cdr words)))) (scan script dir)))
                  ((equal program "eval") (scan (string-join (cdr words) " ") dir)))))))
          (dolist (text (cdr parsed)) (scan text start)))))
    calls))

;;;;; Judging the calls

(defun harness-sandbox--worktree-top (dir)
  "Return the top of the worktree holding DIR, or nil outside git."
  (let ((top (locate-dominating-file dir ".git")))
    (and top (file-name-as-directory (expand-file-name top)))))

(defun harness-sandbox--admin-worktree (admin)
  "Return (PATH . LOCK) for the linked worktree whose git admin dir is ADMIN.
LOCK is the reason of its lock (\"\" without one), nil when unlocked;
nil without a gitdir file."
  (let ((gitdir (expand-file-name "gitdir" admin))
        (locked (expand-file-name "locked" admin)))
    (when (file-regular-p gitdir)
      (cons (file-name-directory (expand-file-name (harness-sandbox--read-file-line gitdir) admin))
            (and (file-exists-p locked) (harness-sandbox--read-file-line locked))))))

(defun harness-sandbox--registered-worktrees (dir)
  "Return the worktrees git has registered for the repository holding DIR.
Each is (PATH . LOCK) as `harness-sandbox--admin-worktree' gives it;
the main worktree comes first.  They are read from the repository's git
directory, as the harness sees it outside the sandbox."
  (when-let* ((common (harness-files-git-common-dir dir)))
    (let ((main (and (equal (file-name-nondirectory (directory-file-name common)) ".git")
                     (file-name-directory (directory-file-name common))))
          (admins (expand-file-name "worktrees" common)))
      (append (and main (list (list main)))
              (and (file-directory-p admins)
                   (delq nil (mapcar #'harness-sandbox--admin-worktree
                                     (directory-files admins t directory-files-no-dot-files-regexp))))))))

(defun harness-sandbox--suffix-p (suffix path)
  "Non-nil when SUFFIX ends PATH at a directory boundary, as git matches worktrees."
  (let ((path (directory-file-name path))
        (suffix (directory-file-name suffix)))
    (and (not (string-empty-p suffix))
         (string-suffix-p suffix path)
         (let ((start (- (length path) (length suffix))))
           (or (zerop start) (eq (aref path (1- start)) ?/))))))

(defun harness-sandbox--same-dir-p (a b)
  "Non-nil when directories A and B are the same place."
  (equal (file-name-as-directory (harness-path-normalize a))
         (file-name-as-directory (harness-path-normalize b))))

(defun harness-sandbox--target (arg dir worktrees)
  "Return (PATH . LOCK) for the worktree git takes ARG to name, run in DIR.
git takes ARG as the end of a registered worktree's path when exactly
one of WORKTREES ends so, and otherwise as a path relative to DIR.  A
path that is no registered worktree comes back as (PATH).  Return nil
when it cannot be told."
  (let ((matches (cl-remove-if-not (lambda (wt) (harness-sandbox--suffix-p arg (car wt))) worktrees)))
    (if (and (= 1 (length matches)) (not (harness-sandbox--dynamic-p arg)))
        (car matches)
      (when-let* ((path (harness-sandbox--resolve-dir arg dir)))
        (or (cl-find-if (lambda (wt) (harness-sandbox--same-dir-p (car wt) path)) worktrees)
            (list path))))))

(defun harness-sandbox--why-not (target arg own)
  "Return why a worktree action must leave TARGET, named ARG, alone; or nil.
TARGET is (PATH . LOCK), nil when it cannot be told; OWN is the
session's own worktree."
  (let ((path (car target))
        (lock (cdr target))
        (show (lambda (dir) (abbreviate-file-name (directory-file-name dir)))))
    (cond
     ((null target) (format "it cannot be told which worktree %s names" arg))
     ((not (harness-path-within-p own path))
      (format "%s is outside this session's worktree %s" (funcall show path) (funcall show own)))
     ((harness-sandbox--same-dir-p own path)
      (format "%s is this session's own worktree, which the harness manages" (funcall show path)))
     ((and (stringp lock) (string-prefix-p "harness: " lock))
      (format "the harness locked %s (%s)" (funcall show path) lock)))))

(defun harness-sandbox--judge (call cwd own)
  "Return why the worktree CALL of a command run in CWD is refused, or nil.
OWN is the session's own worktree."
  (let* ((args (harness-sandbox--operands (plist-get call :args)))
         (dir (plist-get call :dir))
         (worktrees (harness-sandbox--registered-worktrees (or dir cwd)))
         (named (lambda (arg) (harness-sandbox--why-not (harness-sandbox--target arg dir worktrees) arg own))))
    (pcase (plist-get call :action)
      ("prune" "git sees only this session's worktree there, so it would drop the registration of every other one")
      ((guard (plist-get call :open))
       "its arguments come only when it runs, so it cannot be told which worktree it acts on")
      ("move" (or (and (car args) (funcall named (car args)))
                  (and (cadr args)
                       (let ((to (harness-sandbox--resolve-dir (cadr args) dir)))
                         (harness-sandbox--why-not (and to (list to)) (cadr args) own)))))
      (_ (cl-some named args)))))

(defconst harness-sandbox-worktree-hint
  "To clean up a worktree you made inside your own worktree, run `git worktree remove` on its path; never `git worktree prune`. If another worktree really has to go, tell the user: the keys p and d in M-x harness-worktrees run worktree/prune and worktree/remove outside the sandbox."
  "Hint that comes with a refused `git worktree' command.")

(defun harness-sandbox--refusal (action why)
  "Return the refusal of `git worktree ACTION' because of WHY."
  (list :reason (format "`git worktree %s` is refused in the sandbox: %s. Use the harness's worktree/prune and worktree/remove instead: they run outside the sandbox, where git sees every worktree, and keep the locked ones."
                        action why)
        :hint harness-sandbox-worktree-hint))

(defun harness-sandbox--confined-p (cwd)
  "Non-nil when commands run in CWD are confined by a sandbox backend."
  (and cwd (not (file-remote-p cwd))
       (not (eq (harness-sandbox--policy cwd) 'off))
       (memq harness-sandbox--backend '(bwrap systemd))
       t))

(harness-defmethod sandbox/check-command (cwd command &optional own)
  "Return why the shell COMMAND must not run in the sandbox at CWD, or nil.
Refused are `git worktree prune', and `git worktree unlock', `remove'
or `move' of a worktree outside OWN, of OWN itself or of one the
harness locked: git in the sandbox cannot see the other worktrees, so
it takes them for deleted.  OWN is the session's own worktree, by
default the worktree holding CWD.  A command that runs unconfined (no
backend, the `off' policy, a remote CWD) is never refused.  Return
\(:reason TEXT :hint TEXT) or nil."
  (when (and (stringp command) (string-match-p "worktree" command)
             (harness-sandbox--confined-p cwd))
    (let* ((cwd (file-name-as-directory (expand-file-name cwd)))
           (own (file-name-as-directory (expand-file-name (or own (harness-sandbox--worktree-top cwd) cwd)))))
      (condition-case err
          (cl-some (lambda (call)
                     (when-let* ((why (harness-sandbox--judge call cwd own)))
                       (harness-sandbox--refusal (plist-get call :action) why)))
                   (harness-sandbox--git-worktree-calls command cwd))
        (error
         (harness-log 'warn "sandbox: could not read the command %S: %S" command err)
         (when (string-match "worktree[[:space:]]+\\(prune\\|unlock\\|remove\\|move\\)" command)
           (harness-sandbox--refusal (match-string 1 command) "the command line could not be read")))))))

(defun harness-sandbox--init ()
  "Detect backends.  Idempotent."
  (harness-sandbox-detect))

(harness-define-module 'sandbox
  :doc "Kernel sandbox (bwrap / systemd-run) for spawned tool processes."
  :requires '(config)
  :init #'harness-sandbox--init)

(provide 'harness-sandbox)
;;; harness-sandbox.el ends here
