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
;; read-write.  HOME is *not* mounted (credentials such as ~/.npmrc or
;; ~/.aws stay out of reach) and $HOME points at an empty directory on
;; the tmpfs; the only exception is a HOME that lies inside the working
;; directory, which is then visible anyway.  Network access stays on by
;; default because hosted providers and most build tools need it; pass
;; `:network nil' to cut it, which is only correct for local models.
;;
;; Remote working directories (TRAMP) are never wrapped: the sandbox
;; binaries and the mounts would have to exist on the remote host, and
;; the harness has no way to verify them there.  `sandbox/wrap'
;; returns such commands unchanged and logs at debug level.
;;
;; Methods: `sandbox/wrap', `sandbox/status'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

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

(defcustom harness-sandbox-bwrap-program "bwrap"
  "Name or path of the bubblewrap executable."
  :type 'string :group 'harness)

(defcustom harness-sandbox-systemd-run-program "systemd-run"
  "Name or path of the systemd-run executable."
  :type 'string :group 'harness)

(defcustom harness-sandbox-extra-read-only-dirs nil
  "Additional directories bound read-only into every sandbox.
Useful for toolchains that live outside /usr, such as /opt or /nix."
  :type '(repeat directory) :group 'harness)

(defcustom harness-sandbox-home "/tmp/harness-home"
  "Path used as $HOME inside the sandbox.
It lives on the sandbox's private /tmp, so it starts empty for every
command and nothing written there survives."
  :type 'string :group 'harness)

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
  (let ((bwrap (executable-find harness-sandbox-bwrap-program))
        (systemd (executable-find harness-sandbox-systemd-run-program)))
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

;;;; Git worktrees

;; A linked worktree's .git is a file pointing into the main repository's
;; git directory, which lies outside the worktree.  Without it git cannot
;; commit, so the sandbox mounts it read-write -- except its hooks and
;; config, which stay read-only: the harness runs git unconfined in the
;; main checkout (the merge queue), and a planted hook or core.hooksPath
;; would run there outside the jail.  The sandbox hides ~/.gitconfig, so
;; the host's commit identity is passed in through the environment.

(defvar harness-sandbox--git-identity (make-hash-table :test 'equal)
  "Git common dir -> (NAME . EMAIL) as the host's git config gives them.")

(defun harness-sandbox--read-file-line (file)
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
                                                   (expand-file-name "config" common)))))))))

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

(defun harness-sandbox--bwrap-git-args (cwd)
  "Return the bwrap arguments that let git work in a worktree at CWD."
  (when-let* ((git (harness-sandbox--worktree-git cwd)))
    (let ((common (directory-file-name (plist-get git :common))))
      (append (list "--bind" common common)
              (cl-loop for p in (plist-get git :protected) append (list "--ro-bind" p p))
              (cl-loop for (var . value) in (harness-sandbox--git-env (plist-get git :common))
                       append (list "--setenv" var value))))))

(defun harness-sandbox--systemd-git-args (cwd)
  "Return the systemd-run arguments that let git work in a worktree at CWD."
  (when-let* ((git (harness-sandbox--worktree-git cwd)))
    (let ((common (directory-file-name (plist-get git :common))))
      (append (list "-p" (concat "BindPaths=" common) "-p" (concat "ReadWritePaths=" common))
              (cl-loop for p in (plist-get git :protected) append (list "-p" (concat "BindReadOnlyPaths=" p)))
              (cl-loop for (var . value) in (harness-sandbox--git-env (plist-get git :common))
                       collect (format "--setenv=%s=%s" var value))))))

(cl-defun harness-sandbox--bwrap-command (program cwd command &key (network t) writable readable)
  "Build the bwrap command line running COMMAND in CWD.
PROGRAM is the bwrap executable.  NETWORK nil unshares the network
namespace; WRITABLE and READABLE list extra directories to expose."
  (let ((cwd (directory-file-name (expand-file-name cwd))))
    (append
     (list program
           "--ro-bind" "/usr" "/usr"
           "--ro-bind" "/etc" "/etc")
     (harness-sandbox--system-dir-args)
     (cl-loop for d in harness-sandbox-extra-read-only-dirs
              append (harness-sandbox--dir-args d 'ro))
     (list "--proc" "/proc"
           "--dev" "/dev"
           "--tmpfs" "/tmp"
           "--dir" harness-sandbox-home)
     ;; Binds come after the tmpfs so a working directory under /tmp
     ;; is not hidden by it.
     (list "--bind" cwd cwd)
     (cl-loop for d in writable append (harness-sandbox--dir-args d 'rw))
     (cl-loop for d in readable append (harness-sandbox--dir-args d 'ro))
     (harness-sandbox--bwrap-git-args cwd)
     (list "--unshare-pid" "--unshare-ipc" "--unshare-uts"
           "--die-with-parent" "--new-session"
           "--chdir" cwd)
     (unless (harness-sandbox--home-inside-p cwd)
       (list "--setenv" "HOME" harness-sandbox-home))
     (unless network (list "--unshare-net"))
     (list "--")
     command)))

(cl-defun harness-sandbox--systemd-command (program cwd command &key (network t) writable readable)
  "Build the systemd-run command line running COMMAND in CWD.
PROGRAM is the systemd-run executable; NETWORK, WRITABLE and READABLE
are as for `harness-sandbox--bwrap-command'.

Home directories are hidden with `ProtectHome=tmpfs' rather than
`ProtectHome=yes': with the latter systemd cannot mount anything
beneath /home, so a working directory in the user's home would be
unreachable (systemd-run fails with status 200)."
  (let ((cwd (directory-file-name (expand-file-name cwd))))
    (append
     (list program "--user" "--quiet" "--pipe" "--wait" "--collect"
           (concat "--working-directory=" cwd)
           "-p" "PrivateTmp=yes"
           "-p" "ProtectHome=tmpfs"
           "-p" (concat "BindPaths=" cwd)
           "-p" (concat "ReadWritePaths=" cwd))
     (cl-loop for d in writable
              when (file-directory-p d)
              append (list "-p" (concat "BindPaths=" (directory-file-name (expand-file-name d)))))
     (cl-loop for d in readable
              when (file-directory-p d)
              append (list "-p" (concat "BindReadOnlyPaths=" (directory-file-name (expand-file-name d)))))
     (harness-sandbox--systemd-git-args cwd)
     (unless network (list "-p" "PrivateNetwork=yes"))
     (unless (harness-sandbox--home-inside-p cwd)
       (list "--setenv=HOME=/tmp"))
     (list "--")
     command)))

;;;; Methods

(harness-defmethod sandbox/wrap (cwd command &rest opts)
  "Return COMMAND (a list of strings) wrapped to run confined in CWD.
OPTS: `:network' (default t; nil cuts network access), `:writable'
(extra directories mounted read-write) and `:readable' (extra
read-only directories).  A remote CWD or the `off' policy return
COMMAND unchanged.  Signals `harness-sandbox-unavailable' when the
policy is `required' and no backend exists."
  (let ((policy (harness-sandbox--policy cwd))
        (network (if (plist-member opts :network) (plist-get opts :network) t))
        (writable (plist-get opts :writable))
        (readable (plist-get opts :readable)))
    (cond
     ((eq policy 'off) command)
     ((file-remote-p cwd)
      (harness-log 'debug "sandbox: remote cwd %s runs unconfined" cwd)
      command)
     ((eq harness-sandbox--backend 'bwrap)
      (harness-sandbox--bwrap-command (alist-get 'bwrap harness-sandbox--programs) cwd command
                                      :network network :writable writable :readable readable))
     ((eq harness-sandbox--backend 'systemd)
      (harness-sandbox--systemd-command (alist-get 'systemd harness-sandbox--programs) cwd command
                                        :network network :writable writable :readable readable))
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

(defun harness-sandbox--init ()
  "Detect backends.  Idempotent."
  (harness-sandbox-detect))

(harness-define-module 'sandbox
  :doc "Kernel sandbox (bwrap / systemd-run) for spawned tool processes."
  :requires '(config)
  :init #'harness-sandbox--init)

(provide 'harness-sandbox)
;;; harness-sandbox.el ends here
