;;; harness-sandbox.el --- Kernel-enforced process confinement -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; Every process the harness spawns goes through `harness-sandbox-spawn'.
;; The module picks a backend at startup, in preference order:
;;
;;   1. bwrap          (bubblewrap: mount, pid, ipc, uts and net namespaces)
;;   2. systemd-run    (transient user scope with systemd's sandboxing
;;                      properties: ProtectSystem, ProtectHome, ...)
;;   3. none           (unconfined; only when the policy allows it)
;;
;; When a policy requires confinement and no backend is available, spawning
;; fails closed.  When the default policy merely prefers confinement, the
;; process runs unconfined and the human is warned loudly, once.
;;
;; This is a security boundary enforced by the kernel, not by prompts.
;; `:permission-mode' elsewhere in the harness is a prompt-level hint; it
;; never decides whether the sandbox is used.
;;
;; Filesystem inside bwrap: /usr, /etc, /lib, /lib64 (and the /bin, /sbin,
;; /lib64 symlinks) read-only; the session working directory read-write;
;; $HOME a fresh tmpfs; /proc and /dev mounted; extra paths can be granted
;; per policy.  Network is allowed by default because hosted providers need
;; it; disabling it is opt-in and only correct for local models.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)

(define-error 'harness-sandbox-error "Sandbox error" 'harness-error)

(defgroup harness-sandbox nil
  "Process confinement for harness-spawned processes."
  :group 'harness)

(defcustom harness-sandbox-backend 'auto
  "Which sandbox backend to use.
`auto' picks the best available backend.  A specific symbol forces that
backend (and falls back to unconfined only when the policy allows it)."
  :type '(choice (const auto) (const bwrap) (const systemd-run) (const none)))

(defcustom harness-sandbox-mode 'preferred
  "Default confinement mode for spawned processes.
`preferred' uses the chosen backend when available and warns when it is
not; `required' fails closed; `none' never confines."
  :type '(choice (const preferred) (const required) (const none)))

(cl-defstruct (harness-sandbox-policy (:constructor harness-sandbox-policy-create))
  (mode 'preferred)             ; preferred, required, none
  (network t)                   ; nil unshares the network
  (writable nil)                ; extra read-write directories
  (read-only nil))              ; extra read-only directories

(defun harness-sandbox-policy (&rest properties)
  "Build a `harness-sandbox-policy' from PROPERTIES.
Accepted: :mode, :network, :writable, :read-only."
  (harness-sandbox-policy-create
   :mode (or (plist-get properties :mode) harness-sandbox-mode)
   :network (if (plist-member properties :network)
                (plist-get properties :network)
              t)
   :writable (plist-get properties :writable)
   :read-only (plist-get properties :read-only)))

(defvar harness-sandbox--backend nil
  "Resolved backend symbol, or nil when not resolved yet.")

(defvar harness-sandbox--warned nil
  "Non-nil once the loud unconfined warning has been emitted.")

;;; Backend detection

(defun harness-sandbox--probe (program &rest args)
  "Return non-nil when PROGRAM with ARGS exits successfully."
  (let ((exit-code
         (condition-case nil
             (apply #'call-process program nil nil nil args)
           (error 1))))
    (and (integerp exit-code) (zerop exit-code))))

(defun harness-sandbox-backend-usable-p (backend)
  "Return non-nil when BACKEND can actually be used here."
  (pcase backend
    ('bwrap
     (and (executable-find "bwrap")
          (harness-sandbox--probe "bwrap" "--ro-bind" "/" "/" "--"
                                  "/bin/true")))
    ('systemd-run
     (and (executable-find "systemd-run")
          (harness-sandbox--probe "systemd-run" "--user" "--scope" "--quiet"
                                  "/bin/true")))
    ('none t)
    (_ nil)))

(defun harness-sandbox--detect ()
  "Return the best available backend symbol."
  (if (eq harness-sandbox-backend 'auto)
      (or (seq-find #'harness-sandbox-backend-usable-p '(bwrap systemd-run)) 'none)
    (if (harness-sandbox-backend-usable-p harness-sandbox-backend)
        harness-sandbox-backend
      'none)))

(defun harness-sandbox-backend ()
  "Return the resolved backend, detecting it on first use."
  (or harness-sandbox--backend
      (setq harness-sandbox--backend
            (if (eq harness-sandbox-backend 'auto)
                (harness-sandbox--detect)
              (if (harness-sandbox-backend-usable-p harness-sandbox-backend)
                  harness-sandbox-backend
                (progn
                  (harness-log "sandbox: requested backend %s is not usable"
                               harness-sandbox-backend)
                  'none))))))

(defun harness-sandbox-refresh-backend ()
  "Forget the cached backend so the next spawn re-detects it."
  (interactive)
  (setq harness-sandbox--backend nil
        harness-sandbox--warned nil))

(defun harness-sandbox-resolve-backend ()
  "Detect the backend and warn when unconfined."
  (let ((backend (harness-sandbox-backend)))
    (when (and (eq backend 'none)
               (not (eq harness-sandbox-mode 'none))
               (not harness-sandbox--warned))
      (setq harness-sandbox--warned t)
      (display-warning
       'harness
       (concat "No sandbox backend (bwrap or systemd-run) is available; "
               "harness-spawned processes will run UNCONFINED.  "
               "Install bubblewrap, or set `harness-sandbox-mode' to `none' "
               "to silence this warning.")
       :warning))
    backend))

;;; Command construction

(defun harness-sandbox--home-directory ()
  "Return HOME, defaulting to a placeholder when unset."
  (or (getenv "HOME") "/root"))

(defun harness-sandbox--bwrap-args (command args cwd policy)
  "Build the bwrap argument list for COMMAND ARGS CWD and POLICY."
  (let ((argv (list)))
    ;; Read-only system trees; /bin and /sbin are usually symlinks into
    ;; /usr and bind mounts resolve them.
    (dolist (path '("/usr" "/etc" "/lib" "/lib64" "/bin" "/sbin"))
      (when (file-exists-p path)
        (setq argv (append argv (list "--ro-bind" path path)))))
    (setq argv (append argv (list "--proc" "/proc"
                                  "--dev" "/dev"
                                  "--tmpfs" (harness-sandbox--home-directory))))
    (when (and cwd (file-directory-p cwd))
      (setq argv (append argv (list "--bind" cwd cwd))))
    (dolist (directory (harness-sandbox-policy-read-only policy))
      (when (file-exists-p directory)
        (setq argv (append argv (list "--ro-bind" directory directory)))))
    (dolist (directory (harness-sandbox-policy-writable policy))
      (when (file-exists-p directory)
        (setq argv (append argv (list "--bind" directory directory)))))
    (setq argv (append argv (list "--unshare-pid"
                                  "--unshare-ipc"
                                  "--unshare-uts"
                                  "--die-with-parent"
                                  "--new-session")))
    (unless (harness-sandbox-policy-network policy)
      (setq argv (append argv (list "--unshare-net"))))
    (when (and cwd (file-directory-p cwd))
      (setq argv (append argv (list "--chdir" cwd))))
    (append argv (list "--" command) args)))

(defun harness-sandbox--systemd-run-args (command args cwd policy)
  "Build the systemd-run argument list for COMMAND ARGS CWD and POLICY."
  (let ((argv (list "--user" "--scope" "--quiet" "--pipe"
                    "--property=ProtectSystem=strict"
                    "--property=ProtectHome=tmpfs"
                    "--property=PrivateTmp=yes"
                    "--property=NoNewPrivileges=yes"
                    "--property=ProtectKernelTunables=yes"
                    "--property=ProtectKernelModules=yes"
                    "--property=ProtectControlGroups=yes"
                    "--property=RestrictRealtime=yes"
                    "--property=RestrictSUIDSGID=yes")))
    (when (and cwd (file-directory-p cwd))
      (setq argv (append argv (list (format "--property=WorkingDirectory=%s" cwd)
                                    (format "--property=ReadWritePaths=%s" cwd)))))
    (dolist (directory (harness-sandbox-policy-read-only policy))
      (when (file-exists-p directory)
        (setq argv (append argv (list (format "--property=ReadOnlyPaths=%s" directory))))))
    (dolist (directory (harness-sandbox-policy-writable policy))
      (when (file-exists-p directory)
        (setq argv (append argv (list (format "--property=ReadWritePaths=%s" directory))))))
    (unless (harness-sandbox-policy-network policy)
      (setq argv (append argv (list "--property=IPAddressDeny=any"))))
    (append argv (list command) args)))

(defun harness-sandbox-wrap (command args cwd policy)
  "Return the confined command for COMMAND ARGS in CWD under POLICY.

The value is a plist:

  :program   executable to run
  :args      argument list
  :backend   backend symbol actually used
  :confined  non-nil when the kernel confines the process"
  (setq policy (if (harness-sandbox-policy-p policy)
                   policy
                 (harness-sandbox-policy)))
  (when (and cwd (not (file-remote-p cwd)) (not (file-directory-p cwd)))
    (signal 'harness-sandbox-error
            (list (format "Working directory does not exist: %s" cwd))))
  (let ((mode (harness-sandbox-policy-mode policy)))
    (cond
     ((eq mode 'none)
      (list :program command :args args :backend 'none :confined nil))
     ((file-remote-p (expand-file-name cwd))
      ;; The sandbox cannot follow TRAMP; remote processes are confined by
      ;; the remote host, if at all.
      (when (eq mode 'required)
        (signal 'harness-sandbox-error
                (list "Cannot confine a remote process")))
      (harness-sandbox-resolve-backend)
      (list :program command :args args :backend 'none :confined nil))
     (t
      (let ((backend (harness-sandbox-backend)))
        (pcase backend
          ('bwrap
           (list :program "bwrap"
                 :args (harness-sandbox--bwrap-args command args cwd policy)
                 :backend 'bwrap
                 :confined t))
          ('systemd-run
           (list :program "systemd-run"
                 :args (harness-sandbox--systemd-run-args command args cwd policy)
                 :backend 'systemd-run
                 :confined t))
          (_
           (when (eq mode 'required)
             (signal 'harness-sandbox-error
                     (list (concat "No sandbox backend available and the policy "
                                   "requires confinement"))))
           (harness-sandbox-resolve-backend)
           (list :program command :args args :backend 'none :confined nil))))))))

;;; Spawning

(cl-defstruct (harness-sandbox-process (:constructor harness-sandbox-process-create))
  process
  backend
  confined
  command
  args)

(defun harness-sandbox-command-line (wrapped)
  "Return a human-readable command line for WRAPPED."
  (mapconcat #'shell-quote-argument
             (cons (plist-get wrapped :program) (plist-get wrapped :args))
             " "))

(defun harness-sandbox-spawn (&rest properties)
  "Spawn a process through the sandbox.

PROPERTIES:

  :name       process name
  :command    executable (required)
  :args       argument list
  :cwd        working directory
  :policy     a `harness-sandbox-policy', defaults to the global one
  :filter     output filter
  :sentinel   process sentinel
  :coding     coding system
  :stderr     buffer for stderr (when separated)
  :env        environment alist, defaults to the current environment

Returns a `harness-sandbox-process'."
  (declare (indent 1))
  (let* ((command (plist-get properties :command))
         (args (plist-get properties :args))
         (cwd (or (plist-get properties :cwd) default-directory))
         (policy (or (plist-get properties :policy) (harness-sandbox-policy)))
         (wrapped (harness-sandbox-wrap command args cwd policy))
         (process (make-process
                   :name (or (plist-get properties :name) "harness-sandbox")
                   :command (cons (plist-get wrapped :program)
                                  (plist-get wrapped :args))
                   :default-directory (file-name-as-directory
                                       (expand-file-name cwd))
                   :coding (or (plist-get properties :coding) 'utf-8-unix)
                   :connection-type 'pipe
                   :noquery t
                   :filter (plist-get properties :filter)
                   :sentinel (plist-get properties :sentinel)
                   :stderr (plist-get properties :stderr)
                   :environment (plist-get properties :env))))
    (harness-sandbox-process-create
     :process process
     :backend (plist-get wrapped :backend)
     :confined (plist-get wrapped :confined)
     :command command
     :args args)))

(defun harness-sandbox-spawn-sync (command args &rest properties)
  "Run COMMAND with ARGS synchronously through the sandbox.
PROPERTIES accepts the same keys as `harness-sandbox-spawn' plus
`:output' (destination, default a temp buffer that is returned as a
string) and `:timeout' (seconds, enforced by a watchdog that kills the
process).  Returns (EXIT-CODE . OUTPUT)."
  (let* ((buffer (generate-new-buffer " *harness-sandbox-sync*"))
         (result (make-symbol "result"))
         (finished nil)
         (cwd (or (plist-get properties :cwd) default-directory))
         (policy (or (plist-get properties :policy) (harness-sandbox-policy)))
         (wrapped (harness-sandbox-wrap command args cwd policy))
         (process (make-process
                   :name (or (plist-get properties :name) "harness-sandbox-sync")
                   :command (cons (plist-get wrapped :program)
                                  (plist-get wrapped :args))
                   :default-directory (file-name-as-directory
                                       (expand-file-name cwd))
                   :coding (or (plist-get properties :coding) 'utf-8-unix)
                   :connection-type 'pipe
                   :noquery t
                   :buffer buffer
                   :sentinel (lambda (process event)
                               (when (memq (process-status process)
                                           '(exit signal failed))
                                 (setq finished (cons (process-exit-status process) event))))))
         (timeout (plist-get properties :timeout))
         (timed-out nil)
         (watchdog (and timeout
                        (run-at-time timeout nil
                                     (lambda ()
                                       (when (process-live-p process)
                                         (setq timed-out t)
                                         (delete-process process)))))))
    (while (and (not finished) (process-live-p process))
      (accept-process-output process 0.05))
    (when watchdog (cancel-timer watchdog))
    (when (process-live-p process)
      (delete-process process))
    (let ((output (with-current-buffer buffer
                    (string-make-multibyte (buffer-string)))))
      (kill-buffer buffer)
      (cons (cond (timed-out 'timeout)
                  ((car finished) (car finished))
                  (t 'killed))
            output))))

;;; Service

(defun harness-sandbox-service-status (&rest _args)
  "Service: report the resolved backend and policy."
  (list :backend (symbol-name (harness-sandbox-resolve-backend))
        :confined (not (eq (harness-sandbox-backend) 'none))
        :mode (symbol-name harness-sandbox-mode)
        :available (vconcat
                    (seq-filter #'harness-sandbox-backend-usable-p
                                '(bwrap systemd-run)))))

(defun harness-sandbox-service-wrap (&rest args)
  "Service: wrap a command."
  (harness-sandbox-wrap (plist-get args :command)
                        (plist-get args :args)
                        (or (plist-get args :cwd) default-directory)
                        (plist-get args :policy)))

(defun harness-sandbox-setup ()
  "Set up the sandbox module."
  (harness-sandbox-resolve-backend)
  (harness-service-register
   "sandbox"
   :module 'harness-sandbox
   :doc "Kernel-enforced confinement for harness-spawned processes."
   :methods '((status . harness-sandbox-service-status)
              (wrap . harness-sandbox-service-wrap))))

(defun harness-sandbox-teardown ()
  "Tear down the sandbox module."
  (setq harness-sandbox--backend nil
        harness-sandbox--warned nil))

(harness-module-define 'harness-sandbox
  :version harness-version
  :description "Kernel-enforced process confinement (bwrap/systemd-run)."
  :requires '((harness-core "0.1.0"))
  :provides '(harness-sandbox)
  :setup #'harness-sandbox-setup
  :teardown #'harness-sandbox-teardown)

(provide 'harness-sandbox)
;;; harness-sandbox.el ends here
