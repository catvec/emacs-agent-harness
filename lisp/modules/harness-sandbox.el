;;; harness-sandbox.el --- Kernel-enforced confinement for tool processes  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every process the harness spawns on behalf of a model can be routed
;; through a kernel sandbox.  Isolation is enforced by the kernel
;; (mount and PID namespaces on GNU/Linux, Seatbelt on macOS), not by
;; policy: the permission mode is a prompt-level hint, this is the
;; boundary.
;;
;; A backend is picked when the module initialises, in preference
;; order: `bwrap' (bubblewrap), `systemd-run --user', or none; on macOS
;; `mxc' (MXC's mxc-exec-mac, below) or none.  The
;; `harness-sandbox-policy' setting from the config module decides what
;; happens when no backend exists:
;;
;;   required   `sandbox/wrap' signals `harness-sandbox-unavailable'
;;              (fail closed) and logs an error;
;;   preferred  the command runs unconfined, with a warning in the log;
;;   off        the command is always returned unchanged.
;;
;; What the sandbox sees on GNU/Linux: read-only /usr and /etc (plus
;; the usual /lib, /lib64, /bin, /sbin as symlinks or read-only binds),
;; a fresh /proc, /dev and /tmp, and the session's working directory
;; read-write.  The home directory's contents are *not* mounted
;; (credentials such as ~/.npmrc or ~/.aws stay out of reach).  With
;; bwrap $HOME keeps its path, but an empty tmpfs covers it, so ~/x
;; names the same path inside as outside and only what is mounted
;; there shows; systemd-run hides the home directories and points
;; $HOME at the private /tmp.  The only exception is a home directory
;; inside the working directory, which is then visible anyway.
;;
;; A caller shows more: `:writable' directories (or files) read-write
;; and `:readable' ones read-only.  The bash tool shows the
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
;; A confined command has HARNESS_SANDBOX set to the backend's name,
;; `bwrap', `systemd' or `mxc', so a script can tell it runs confined:
;; scripts/dev.sh warns that an Emacs it starts there ends with the
;; command.
;;
;; On macOS the backend is MXC (Microsoft eXecution Container, see
;; `harness-sandbox-mxc-program'): its executor, mxc-exec-mac, confines
;; a command with Seatbelt, macOS's own sandbox, and needs macOS 15 or
;; later.  It is the only backend looked for there, and is not looked
;; for anywhere else.  Seatbelt allows what it is told and denies the
;; rest, so what a command sees is a list of paths rather than mounts:
;; MXC's baseline of system directories (/bin, /usr/bin, /usr/lib,
;; /System, /Library...), the toolchain directories of
;; `harness-sandbox--mxc-system-dirs' (Homebrew, MacPorts, Nix,
;; /Applications) and `harness-sandbox-extra-read-only-dirs', all
;; read-only; the working directory read-write; the `:writable' and
;; `:readable' directories as they are given; and a private $TMPDIR,
;; made for the command and removed when it ends.  $HOME keeps its
;; path, but nothing in it can be read except what is shown there.
;; MXC passes on none of the harness's environment, so the command's
;; is written out whole: `process-environment' as it is when the
;; command is wrapped, with TMPDIR, PWD, HARNESS_SANDBOX=mxc and a
;; worktree's commit identity set.  `:network nil' denies the network,
;; loopback included; otherwise it is open both ways, as bwrap leaves
;; it.  `:read-only' leaves nothing writable but that $TMPDIR.  Unlike
;; bwrap, MXC gives the command no PID namespace of its own; /tmp
;; cannot be written there (a command uses $TMPDIR); and MXC hands the
;; command's output on only when it ends, so the note under a running
;; bash call shows none until then.
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
;; private /tmp (its private $TMPDIR under MXC).  It fails closed:
;; where the command would run unconfined, with the `off' policy, in a
;; remote directory or with no backend (whatever the policy),
;; `sandbox/wrap' signals `harness-sandbox-unavailable' instead of
;; returning it.
;;
;; `:scratch' lists directories the caller made for the one command and
;; deletes after it, which the command writes even when it is
;; `:read-only': the elisp tool's background Emacs leaves its result in
;; one, for the harness to read.  They are mounted last, so nothing
;; covers them, and one that would show writable what the sandbox hides
;; or keeps read-only -- the root directory, one holding the working
;; directory or the home directory, a system directory -- is refused
;; with an error.
;;
;; Seeing only its own directory makes some git commands destructive
;; inside the sandbox: `git worktree prune' takes every other worktree
;; of the repository for deleted and drops its registration.
;; `sandbox/check-command' finds those in a shell command line so the
;; permission layer can refuse them (see "Capabilities" and "Git
;; worktree commands" below).
;;
;; Linux capabilities: a command in the bwrap sandbox has none at all,
;; bwrap drops every one.  `:capabilities' gives it some, by name: one
;; `--cap-add' each, which in an unprivileged bwrap is a capability of
;; the sandbox's own user namespace -- over its processes, its mounts
;; and, with `:network nil', its empty network namespace -- and never
;; one over the host, its files as their owner or another machine.  The
;; names come from a registry of the capabilities the harness knows
;; (`harness-sandbox-capabilities'), so nothing else ever reaches
;; bwrap's command line, and only those that
;; `harness-sandbox-grantable-capabilities' lists are passed on.  A
;; `:read-only' command is given none.  bwrap alone can: systemd-run
;; and MXC signal `harness-sandbox-unavailable' for `:capabilities',
;; and so does bwrap when `--cap-add' would hand out real capabilities
;; of the host, being setuid or run by root.  See "Capabilities" below.
;;
;; Methods: `sandbox/wrap', `sandbox/status', `sandbox/confined-p',
;; `sandbox/capabilities', `sandbox/capability-name',
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
`auto' picks the first available of bwrap and systemd-run on GNU/Linux,
and `mxc' (MXC's mxc-exec-mac, see `harness-sandbox-mxc-program') on
macOS; a specific symbol forces that backend (and counts as unavailable
when its executable is missing, or on a system it does not run on:
`mxc' anywhere but macOS, `bwrap' and `systemd' on macOS); `none'
disables wrapping regardless of policy detection, subject to
`harness-sandbox-policy'."
  :type '(choice (const auto) (const bwrap) (const systemd) (const mxc) (const none))
  :group 'harness)

(defconst harness-sandbox--bwrap-program "bwrap"
  "Name or path of the bubblewrap executable.")

(defconst harness-sandbox--systemd-run-program "systemd-run"
  "Name or path of the systemd-run executable.")

(defcustom harness-sandbox-mxc-program "mxc-exec-mac"
  "Name or absolute path of MXC's macOS executor, mxc-exec-mac.
MXC (Microsoft eXecution Container, https://github.com/microsoft/mxc)
confines a command with macOS's Seatbelt; it needs macOS 15 or later,
and neither root nor a daemon.  The executor comes in MXC's release
builds and in its npm package (sdk/node/bin/ARCH/mxc-exec-mac), so it
is often not on PATH: name its absolute path here then.  It is looked
for on macOS only, when the sandbox module starts (see
`harness-sandbox-detect')."
  :type 'string :group 'harness)

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

(defvar harness-sandbox--mxc-system-dirs
  '("/opt/homebrew" "/usr/local" "/opt/local" "/nix" "/Applications")
  "Directories MXC's sandbox shows read-only, where they exist, besides its own.
MXC's baseline shows the system's directories (/bin, /usr/bin,
/usr/lib, /System, /Library and the like) and none of these, where the
toolchains and programs a command runs often live: Homebrew
\(/opt/homebrew on Apple silicon, /usr/local on Intel), MacPorts
\(/opt/local), Nix (/nix) and the programs inside app bundles
\(/Applications, Emacs's own among them).  bwrap shows all of /usr.")

(defvar harness-sandbox--backend nil
  "Backend chosen at initialisation: `bwrap', `systemd', `mxc' or `none'.")

(defvar harness-sandbox--available nil
  "Backends whose executables were found at initialisation.")

(defvar harness-sandbox--programs nil
  "Alist of backend -> absolute executable path found at initialisation.")

;;;; Detection

(defun harness-sandbox-detect ()
  "Find the available backends and choose one.
Return the chosen backend symbol.  Safe to call again: it refreshes
`harness-sandbox--available' and `harness-sandbox--backend'.  On macOS
only MXC is looked for (`harness-sandbox-mxc-program'), elsewhere only
bwrap and systemd-run."
  (let* ((darwin (eq system-type 'darwin))
         (bwrap (and (not darwin) (executable-find harness-sandbox--bwrap-program)))
         (systemd (and (not darwin) (executable-find harness-sandbox--systemd-run-program)))
         (mxc (and darwin (stringp harness-sandbox-mxc-program)
                   (not (string-empty-p harness-sandbox-mxc-program))
                   ;; An absolute path, or one from ~, is found as it is.
                   (executable-find (if (file-name-directory harness-sandbox-mxc-program)
                                        (expand-file-name harness-sandbox-mxc-program)
                                      harness-sandbox-mxc-program)))))
    (setq harness-sandbox--programs
          (delq nil (list (and bwrap (cons 'bwrap bwrap))
                          (and systemd (cons 'systemd systemd))
                          (and mxc (cons 'mxc mxc)))))
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

;;;; Capabilities

;; bwrap drops every Linux capability of the commands it runs, and
;; `--cap-add NAME' keeps the one it names.  Run by an ordinary user it
;; first makes a user namespace of its own, so a capability it keeps is
;; one of that namespace: it counts for the processes, the mounts, the
;; IPC objects and the hostname of the sandbox, and for its network
;; namespace when there is one (`:network nil'); it counts for nothing
;; the host owns, such as the host's network namespace, which a sandbox
;; with the network shares.  Run by root, or installed setuid, bwrap
;; does otherwise (see `harness-sandbox--cap-add-unsafe-why'), so then
;; the harness does not use it to grant any.

(defconst harness-sandbox-capabilities
  '(("CAP_CHOWN" :bit 0
     :doc "change the owner and group of files")
    ("CAP_DAC_OVERRIDE" :bit 1
     :doc "read, write and run files whatever their permissions say")
    ("CAP_DAC_READ_SEARCH" :bit 2
     :doc "read files and list directories whatever their permissions say")
    ("CAP_FOWNER" :bit 3
     :doc "act as the owner of any file: change its mode, times and attributes")
    ("CAP_FSETID" :bit 4
     :doc "keep the setuid and setgid bits of a file that is changed")
    ("CAP_KILL" :bit 5
     :doc "send signals to processes of any user")
    ("CAP_SETGID" :bit 6
     :doc "change the process's group ids and write its group id map")
    ("CAP_SETUID" :bit 7
     :doc "change the process's user ids and write its user id map")
    ("CAP_SETPCAP" :bit 8
     :doc "change the capabilities of the process")
    ("CAP_LINUX_IMMUTABLE" :bit 9
     :doc "set the immutable and append-only attributes of files")
    ("CAP_NET_BIND_SERVICE" :bit 10
     :doc "bind sockets to the ports below 1024"
     :scope "Only effective when the session has no network: the sandbox then has an empty network namespace of its own, which this capability covers. With the network on the sandbox shares the host's network namespace, which it does not own, so this changes nothing there.")
    ("CAP_NET_BROADCAST" :bit 11
     :doc "send broadcasts and listen to multicast groups"
     :scope "Only effective when the session has no network: the sandbox then has an empty network namespace of its own, which this capability covers. With the network on the sandbox shares the host's network namespace, which it does not own, so this changes nothing there.")
    ("CAP_NET_ADMIN" :bit 12
     :doc "configure the network: interfaces, addresses, routes and firewall rules"
     :scope "Only effective when the session has no network: the sandbox then has an empty network namespace of its own, which this capability covers. With the network on the sandbox shares the host's network namespace, which it does not own, so this changes nothing there.")
    ("CAP_NET_RAW" :bit 13
     :doc "open raw and packet sockets: ping, tcpdump, packet crafting"
     :scope "Only effective when the session has no network: the sandbox then has an empty network namespace of its own, which this capability covers. With the network on the sandbox shares the host's network namespace, which it does not own, so this changes nothing there.")
    ("CAP_IPC_LOCK" :bit 14
     :doc "lock memory beyond the usual limit")
    ("CAP_IPC_OWNER" :bit 15
     :doc "skip the permission checks of System V IPC objects")
    ("CAP_SYS_MODULE" :bit 16
     :doc "load and unload kernel modules"
     :scope "Kernel modules belong to the host, which a user namespace does not own: the kernel refuses this one there.")
    ("CAP_SYS_RAWIO" :bit 17
     :doc "reach I/O ports and raw device memory"
     :scope "I/O ports and device memory belong to the host, which a user namespace does not own: the kernel refuses this one there.")
    ("CAP_SYS_CHROOT" :bit 18
     :doc "change the root directory with chroot")
    ("CAP_SYS_PTRACE" :bit 19
     :doc "trace and inspect any process in the sandbox (strace, gdb, /proc/PID/mem); it also lifts Yama's rule that a process may only trace its own descendants"
     :scope "It reaches the processes of the sandbox's own PID namespace, which the sandbox owns: never the harness, nor any other process of the host.")
    ("CAP_SYS_PACCT" :bit 20
     :doc "switch process accounting on and off")
    ("CAP_SYS_ADMIN" :bit 21
     :doc "mount, remount and join namespaces, and much else: the broadest capability"
     :scope "Inside the sandbox it can mount, remount and join namespaces, which can undo the read-only mounts the jail relies on: a read-only session's, a worktree's protected git hooks and config, the skills directories.")
    ("CAP_SYS_BOOT" :bit 22
     :doc "reboot and load another kernel")
    ("CAP_SYS_NICE" :bit 23
     :doc "raise priorities and set real-time scheduling or CPU affinity of any process")
    ("CAP_SYS_RESOURCE" :bit 24
     :doc "go past resource limits and quotas")
    ("CAP_SYS_TIME" :bit 25
     :doc "set the system clock"
     :scope "The clock belongs to the host, which a user namespace does not own: the kernel refuses this one there.")
    ("CAP_SYS_TTY_CONFIG" :bit 26
     :doc "configure virtual terminals")
    ("CAP_MKNOD" :bit 27
     :doc "create device files")
    ("CAP_LEASE" :bit 28
     :doc "take leases on files of other users")
    ("CAP_AUDIT_WRITE" :bit 29
     :doc "write records to the kernel audit log")
    ("CAP_AUDIT_CONTROL" :bit 30
     :doc "configure kernel auditing")
    ("CAP_SETFCAP" :bit 31
     :doc "set file capabilities")
    ("CAP_MAC_OVERRIDE" :bit 32
     :doc "override mandatory access control (SELinux, AppArmor, Smack)")
    ("CAP_MAC_ADMIN" :bit 33
     :doc "configure mandatory access control")
    ("CAP_SYSLOG" :bit 34
     :doc "read and configure the kernel log")
    ("CAP_WAKE_ALARM" :bit 35
     :doc "set timers that wake the system")
    ("CAP_BLOCK_SUSPEND" :bit 36
     :doc "block the system from suspending")
    ("CAP_AUDIT_READ" :bit 37
     :doc "read the kernel audit log")
    ("CAP_PERFMON" :bit 38
     :doc "use performance monitoring and tracing: perf, eBPF tracing")
    ("CAP_BPF" :bit 39
     :doc "load BPF programs and use BPF maps")
    ("CAP_CHECKPOINT_RESTORE" :bit 40
     :doc "checkpoint and restore processes"))
  "The Linux capabilities the harness knows, from the kernel's list.
Each is (NAME :bit BIT :doc DOC [:scope SCOPE]): NAME the canonical
name, BIT its number in the kernel's capability sets (the bit that
`CapEff' in /proc/PID/status shows), DOC what it lets a command do, in
one line, and SCOPE, when there is more to say than that every one
counts inside the sandbox's own namespaces only, never on the host,
over files as their owner, or on another machine: where this one
counts, or what it can undo (`harness-sandbox-capability-scope').

This registry is what keeps anything but a capability's name off
bwrap's command line: only a name in it is ever passed on.  `ALL' is
not in it, and so can never be passed.  It says what exists, not what
an agent may ask for: that is `harness-sandbox-grantable-capabilities'.")

(defcustom harness-sandbox-grantable-capabilities
  '("CAP_SYS_PTRACE" "CAP_NET_RAW" "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE")
  "The Linux capabilities an agent may ask the user to give its commands.
An agent asks with request_escalation (attribute capability), and only
your answer grants it; a capability granted is passed to bwrap
\(`--cap-add') for the agent's bash and elisp commands.  A name that is
not listed here cannot even be asked for, and one granted earlier and
no longer listed is no longer passed on.  The names are those of
`harness-sandbox-capabilities'; `ALL' is never grantable.

The default is conservative.  Each capability counts inside the
sandbox's own user namespace only, never on the host:
- CAP_SYS_PTRACE traces and inspects any process of the sandbox
  (strace, gdb, /proc/PID/mem) and lifts Yama's rule that a process
  may only trace its own descendants.
- CAP_NET_RAW, CAP_NET_ADMIN and CAP_NET_BIND_SERVICE (raw sockets,
  network configuration, low ports) are effective only for a session
  without the network, in the sandbox's own empty network namespace;
  with the network on, the sandbox shares the host's, which it does
  not own, and they change nothing there.

CAP_SYS_ADMIN is left out on purpose.  It lets a command mount,
remount and join namespaces inside the sandbox, which can undo the
read-only mounts the jail relies on: a read-only session's, the
protected git hooks and config of a worktree, the skills directories.
Add it, or any other capability of the registry, at your own risk.

Set this to nil to switch the feature off, for a corporate policy
say: nothing can be asked for then.  This is a plain option of yours
or your administrator's (the policy file may set it), not a layered
one: a project's .dir-locals.el cannot widen what the agents jailed in
it may ask for, and the harness reads only its global value."
  :type `(set ,@(mapcar (lambda (entry)
                          (list 'const :tag (format "%s: %s" (car entry) (plist-get (cdr entry) :doc))
                                (car entry)))
                        harness-sandbox-capabilities))
  :risky t
  :group 'harness)

(defvar harness-sandbox--capabilities-reported nil
  "Entries of `harness-sandbox-grantable-capabilities' reported as unknown.")

(defun harness-sandbox-capability-name (value)
  "Return the canonical name of the capability VALUE names, or nil.
VALUE is a string or a symbol.  Case, dashes, spaces and the `CAP_'
prefix do not matter -- CAP_SYS_PTRACE, SYS_PTRACE, sys_ptrace and
cap-sys-ptrace are one -- and a name a registry entry has with SYS_
before it may leave that out: `ptrace'.  Nothing else matches, `ALL'
included; what comes back is always a name of the registry, never VALUE
itself, whatever it holds."
  (let* ((text (cond ((stringp value) value)
                     ((and value (symbolp value) (not (keywordp value))) (symbol-name value))))
         (key (and text (upcase (replace-regexp-in-string "[-[:space:]]+" "_" (string-trim text))))))
    (when (and key (not (string-empty-p key)))
      (let ((bare (string-remove-prefix "CAP_" key)))
        (cl-some (lambda (prefix)
                   (let ((name (concat prefix bare)))
                     (and (assoc name harness-sandbox-capabilities) name)))
                 '("CAP_" "CAP_SYS_"))))))

(defun harness-sandbox-capability-info (name key)
  "Return KEY (`:bit', `:doc' or `:scope') of the capability NAME, or nil.
NAME is any spelling `harness-sandbox-capability-name' knows."
  (when-let* ((canonical (harness-sandbox-capability-name name)))
    (plist-get (cdr (assoc canonical harness-sandbox-capabilities)) key)))

(defun harness-sandbox-capability-scope (name)
  "Return the note on where the capability NAME counts, if it has one, else nil.
That is its registry entry's `:scope': what there is to say besides
that it counts inside the sandbox's own namespaces only."
  (harness-sandbox-capability-info name :scope))

(defun harness-sandbox-capability-mask (names)
  "Return the bits of the capabilities NAMES, as `CapEff' prints them in hex."
  (let ((mask 0))
    (dolist (name names mask)
      (when-let* ((bit (harness-sandbox-capability-info name :bit)))
        (setq mask (logior mask (ash 1 bit)))))))

(defun harness-sandbox-grantable ()
  "Return the capabilities an agent may ask for, as canonical names.
They are the registry's entries among `harness-sandbox-grantable-capabilities'
\(in any spelling), in that order.  Only the option's global value
counts, never a buffer-local or directory-local one: a project's file
must not widen what the agents jailed in it may ask for.  An entry that
is no capability is reported once and skipped."
  (let ((value (default-value 'harness-sandbox-grantable-capabilities))
        names)
    (dolist (item (and (proper-list-p value) value))
      (if-let* ((name (harness-sandbox-capability-name item)))
          (cl-pushnew name names :test #'equal)
        (unless (member item harness-sandbox--capabilities-reported)
          (push item harness-sandbox--capabilities-reported)
          (harness-log 'warn "sandbox: %S in harness-sandbox-grantable-capabilities is no capability the harness knows, so it is skipped"
                       item))))
    (nreverse names)))

(defun harness-sandbox--setuid-p (program)
  "Non-nil when the executable PROGRAM has the setuid bit."
  (let ((modes (and (stringp program) (ignore-errors (file-modes program)))))
    (and modes (/= 0 (logand modes #o4000)))))

(defun harness-sandbox--root-p ()
  "Non-nil when this Emacs, and so bwrap, runs as root."
  (eql 0 (user-real-uid)))

(defun harness-sandbox--cap-add-unsafe-why (program)
  "Return why `--cap-add' of bwrap's PROGRAM is no namespace capability, or nil.
An unprivileged bwrap makes a user namespace of its own, and what it
keeps is a capability of that.  An old bwrap installed setuid root does
not, and `--cap-add' then hands the command a capability over the
whole host.  A bwrap run by root makes no user namespace unless asked,
and starts from all the capabilities of its caller, so a command keeps
every one of them: nothing is dropped there to lower, nor to raise."
  (cond
   ((harness-sandbox--setuid-p program)
    (format "%s is setuid root, where --cap-add would hand out real capabilities of the host, not ones of the sandbox's own user namespace"
            program))
   ((harness-sandbox--root-p)
    "this Emacs runs as root, so bwrap makes no user namespace of its own and keeps every capability of its caller for the commands it runs: there is none to raise or lower, and --cap-add would be real")))

(defun harness-sandbox--capabilities-why (cwd)
  "Return why the jail cannot give commands in CWD capabilities, else nil.
Only bwrap can, for a local CWD, with a sandbox policy other than
`off', and not when `--cap-add' would be no namespace capability."
  (let ((policy (harness-sandbox--policy cwd)))
    (cond
     ((and cwd (harness-file-remote-p cwd))
      "its commands run on another host, where the sandbox does not reach")
     ((eq policy 'off)
      "the sandbox policy is `off': its commands run unconfined, with your own rights")
     ((eq harness-sandbox--backend 'bwrap)
      (harness-sandbox--cap-add-unsafe-why (alist-get 'bwrap harness-sandbox--programs)))
     ((eq harness-sandbox--backend 'systemd)
      "the sandbox backend is systemd-run, not bwrap, and a systemd --user unit cannot be given a capability: it can only lower its own")
     ((eq harness-sandbox--backend 'mxc)
      "the sandbox backend is MXC, not bwrap, and macOS's Seatbelt has no Linux capabilities")
     (t (format "no sandbox backend can confine its commands (%s), and only bwrap can give a command a capability"
                (harness-sandbox--missing-programs))))))

(defun harness-sandbox--refuse-capabilities (command capabilities why)
  "Signal `harness-sandbox-unavailable': COMMAND cannot be given CAPABILITIES.
WHY says what stands in the way.  It is the caller's to give them up:
the command does not run without what was asked for."
  (harness-log 'error "sandbox: cannot give %s to %S: %s"
               (string-join (mapcar (lambda (c) (format "%s" c)) capabilities) ", ") (car command) why)
  (signal 'harness-sandbox-unavailable
          (list (format "this command was to run with the Linux capabilities %s, which the sandbox cannot give it: %s. Give them up with drop_access (attribute capability, value all) to run commands without them"
                        (string-join (mapcar (lambda (c) (format "%s" c)) capabilities) ", ") why))))

(defun harness-sandbox--bwrap-capabilities (command requested program)
  "Return the names among REQUESTED that bwrap's PROGRAM may add to COMMAND.
They are canonical names.  Each must be a capability of the registry
and listed in `harness-sandbox-grantable-capabilities': one that is
not is left out with a line in the log, so a capability that is no
longer grantable is no longer passed on, and the command runs with
fewer.  When there is one left and `--cap-add' would be no namespace
capability, signal `harness-sandbox-unavailable'
\(`harness-sandbox--cap-add-unsafe-why')."
  (let ((grantable (harness-sandbox-grantable))
        granted)
    (dolist (item requested)
      (let ((name (harness-sandbox-capability-name item)))
        (cond
         ((null name)
          (harness-log 'warn "sandbox: not giving %S to %S: it is no capability the harness knows"
                       item (car command)))
         ((not (member name grantable))
          (harness-log 'warn "sandbox: not giving %s to %S: harness-sandbox-grantable-capabilities does not list it"
                       name (car command)))
         (t (cl-pushnew name granted :test #'equal)))))
    (setq granted (nreverse granted))
    (when-let* ((_ granted)
                (why (harness-sandbox--cap-add-unsafe-why program)))
      (harness-sandbox--refuse-capabilities command granted why))
    granted))

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
MODE is `ro' for READABLE and `rw' for WRITABLE, which both list
directories and files.  Each one that exists is shown where it is
named and where its symbolic links lead, and, when it lies under the
real home directory, at the same place under HOME,
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
               (real (and named (or dir (file-exists-p named))
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

(defun harness-sandbox--scratch-mounts (scratch cwd)
  "Return the mounts showing the SCRATCH directories as (SOURCE . DESTINATION).
SCRATCH lists directories the caller made for the one command and
deletes after it, which the command writes even when it is
`:read-only'.  Each is shown where it is named and where its symbolic
links lead.  One that is no existing local directory, or that is the
root directory, holds the working directory CWD or the home directory,
or is, holds or lies in one of `harness-sandbox--system-paths',
signals an error: shown writable, it would undo what the sandbox hides
or keeps read-only."
  (let ((home (getenv "HOME"))
        mounts)
    (dolist (d scratch)
      (let* ((named (and (stringp d) (not (file-remote-p d)) (expand-file-name d)))
             (real (and named (file-directory-p named)
                        (directory-file-name (file-truename named)))))
        (cond
         ((null real)
          (error "Sandbox scratch directory %S is no local directory" d))
         ((or (equal real "/")
              (harness-path-within-p real cwd)
              (and (stringp home) (file-name-absolute-p home) (harness-path-within-p real home))
              (cl-some (lambda (system)
                         (or (harness-path-within-p system real) (harness-path-within-p real system)))
                       harness-sandbox--system-paths))
          (error "Sandbox scratch directory %s would show writable what the sandbox hides or keeps read-only"
                 d))
         (t
          (dolist (dest (delete-dups (list real (directory-file-name named))))
            (push (cons real dest) mounts))))))
    (nreverse mounts)))

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

(cl-defun harness-sandbox--bwrap-command (program cwd command &key (network t) writable readable read-only
                                                   scratch capabilities)
  "Build the bwrap command line running COMMAND in CWD.
PROGRAM is the bwrap executable.  NETWORK nil unshares the network
namespace; WRITABLE and READABLE list extra directories or files to
expose (see `harness-sandbox--mounts' for how they are shown).  READ-ONLY binds
CWD, the git directories and every WRITABLE entry with `--ro-bind', so
that the command writes nothing but the sandbox's private /tmp and the
SCRATCH directories, which are bound with `--bind' after everything
else (see `harness-sandbox--scratch-mounts').

CAPABILITIES, names of `harness-sandbox-capabilities', each get a
`--cap-add' after the flags that make the namespaces, and before the
command: bwrap drops every other capability.  This only builds the
command line, and is the last guard of it: a name the registry does not
know is left out, whatever it holds, and so is every one with READ-ONLY.
Whether the capability may be granted at all is for `sandbox/wrap'
\(`harness-sandbox--bwrap-capabilities').

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
     ;; The scratch directories last, writable whatever holds them.
     (cl-loop for (source . dest) in (harness-sandbox--scratch-mounts scratch cwd)
              append (list "--bind" source dest))
     (list "--unshare-pid" "--unshare-ipc" "--unshare-uts"
           "--die-with-parent" "--new-session")
     ;; Only the registry's own names, none for a command that changes nothing.
     (unless read-only
       (cl-loop for name in (delete-dups (delq nil (mapcar #'harness-sandbox-capability-name capabilities)))
                append (list "--cap-add" name)))
     (list "--chdir" cwd
           "--setenv" "HARNESS_SANDBOX" "bwrap")
     (and private (list "--setenv" "HOME" private))
     (unless network (list "--unshare-net"))
     (list "--")
     command)))

(cl-defun harness-sandbox--systemd-command (program cwd command &key (network t) writable readable read-only
                                                     scratch)
  "Build the systemd-run command line running COMMAND in CWD.
PROGRAM is the systemd-run executable; NETWORK, WRITABLE, READABLE,
READ-ONLY and SCRATCH are as for `harness-sandbox--bwrap-command'.
READ-ONLY binds CWD, the git directories and every WRITABLE entry with
`BindReadOnlyPaths=', sets no `ReadWritePaths=' but for the SCRATCH
directories, and makes the rest of the file system read-only with
`ProtectSystem=strict': unlike bwrap's, this sandbox shows the whole
file system, and only the user's own files are hidden
\(`ProtectHome=tmpfs'), so what it does not show it must still refuse
to write.  The SCRATCH directories are bound writable as CWD is when it
is, whatever READ-ONLY says; one whose path a setting cannot hold as
written signals an error.

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
     (cl-loop for (source . dest) in (harness-sandbox--scratch-mounts scratch cwd)
              do (unless (and (harness-sandbox--systemd-path-p source) (harness-sandbox--systemd-path-p dest))
                   (error "Sandbox scratch directory %s cannot be written in a systemd setting" dest))
              append (list "-p" (concat "BindPaths=" source (if (equal source dest) "" (concat ":" dest)))
                           "-p" (concat "ReadWritePaths=" dest)))
     (unless network (list "-p" "PrivateNetwork=yes"))
     (unless (harness-sandbox--home-inside-p cwd)
       (list "--setenv=HOME=/tmp"))
     (list "--setenv=HARNESS_SANDBOX=systemd")
     (list "--")
     command)))

;;;; MXC (macOS)

;; MXC's Seatbelt executor takes the whole description of a command as
;; JSON rather than as mount arguments.  What the command may read and
;; write is an allowlist of real paths, on top of MXC's own baseline of
;; read-only system directories: Seatbelt matches a path once its
;; symbolic links are resolved, so a path given through a link would
;; match nothing.  The command line runs with /bin/sh -c, in exactly the
;; environment given, never the harness's own, so that is written out
;; whole.

(defun harness-sandbox--sh-quote (word)
  "Return WORD quoted for a POSIX shell, one word that keeps it exactly.
It goes between single quotes, inside which nothing is special, and
each single quote in it is written '\\''."
  (concat "'" (string-replace "'" "'\\''" word) "'"))

(defun harness-sandbox--json-text-p (string)
  "Non-nil when JSON can carry STRING: Unicode text, with no raw bytes."
  (let ((limit (if (multibyte-string-p string) #x10FFFF #x7F)))
    (cl-notany (lambda (c) (> c limit)) string)))

(defun harness-sandbox--mxc-env (overrides)
  "Return the environment of a command MXC runs, as NAME=VALUE strings.
It is the one a process started now gets from `process-environment':
the first entry of a name wins, and an entry without `=' leaves its
name unset, as in Emacs.  OVERRIDES, (NAME . VALUE) pairs, replace
their names' values or add them, at the end.  An entry holding raw
bytes, which JSON cannot carry, is left out."
  (let ((seen (make-hash-table :test 'equal))
        (env nil))
    (dolist (pair overrides) (puthash (car pair) t seen))
    (dolist (entry process-environment)
      (let* ((at (string-search "=" entry))
             (name (if at (substring entry 0 at) entry)))
        (unless (or (string-empty-p name) (gethash name seen))
          (puthash name t seen)
          (cond ((null at))
                ((harness-sandbox--json-text-p entry) (push entry env))
                (t (harness-log 'debug "sandbox: MXC cannot pass %s on, its value is no text" name))))))
    (append (nreverse env)
            (cl-loop for (name . value) in overrides collect (concat name "=" value)))))

(defun harness-sandbox--mxc-path (path)
  "Return the real path of PATH, as Seatbelt matches it, without a trailing slash."
  (directory-file-name (file-truename (expand-file-name path))))

(cl-defun harness-sandbox--mxc-command (program cwd command &key (network t) writable readable read-only tmp
                                                 scratch)
  "Build the MXC command line running COMMAND in CWD, on macOS.
PROGRAM is MXC's executor, mxc-exec-mac, given the whole description
of the command as base64-encoded JSON (`--config-base64').  NETWORK,
WRITABLE, READABLE and READ-ONLY are as for
`harness-sandbox--bwrap-command'.  TMP is the command's private
temporary directory, which `sandbox/wrap' makes: $TMPDIR names it, it
is writable, and the command line removes it when COMMAND ends.  The
SCRATCH directories are writable too, whatever READ-ONLY says (see
`harness-sandbox--scratch-mounts').

Seatbelt allows what it is told and denies the rest, on top of MXC's
baseline of read-only system directories.  Readable are
`harness-sandbox--mxc-system-dirs' and
`harness-sandbox-extra-read-only-dirs' that exist (unless a writable
directory holds one: as with bwrap, that one covers it) and the
READABLE directories; writable are CWD, the WRITABLE directories and
files, a worktree's git directory and TMP.  The git directory's
hooks, config, index and HEAD stay read-only, as with bwrap: the
deepest path given decides.  Each path is given at its real path (see
`harness-sandbox--mounts' for how the directories are found), since
Seatbelt matches the real one.  READ-ONLY makes every one of them
read-only but TMP, so that the command writes nothing else.

Nothing else is shown, the home directory's contents included: $HOME
keeps its path, and only what is shown under it can be read.  NETWORK
nil denies all network access; otherwise the host's network, loopback
included, is open both ways, as bwrap leaves it.  The command gets
exactly the environment `process-environment' holds now (one given to
the process later does not reach it), with TMPDIR, PWD,
HARNESS_SANDBOX=mxc and a worktree's commit identity set.  MXC sets it
no timeout: the harness kills the process tree itself, and finds the
command in it by its parent processes.

This only reads the file system: it writes nothing, TMP included."
  (let* ((cwd (directory-file-name (expand-file-name cwd)))
         (tmp (and tmp (harness-sandbox--mxc-path tmp)))
         (mounts (harness-sandbox--mounts readable writable cwd nil))
         (sources (lambda (mode)
                    (cl-loop for (m source) in mounts when (eq m mode) collect source)))
         (git (harness-sandbox--worktree-git cwd))
         (common (and git (harness-sandbox--mxc-path (plist-get git :common))))
         ;; Read-only inside the writable git directory; with READ-ONLY
         ;; the whole of it is, as with bwrap.
         (protected (and git (not read-only)
                         (mapcar #'harness-sandbox--mxc-path (plist-get git :protected))))
         (shown (delete-dups (delq nil (append (list (harness-sandbox--mxc-path cwd))
                                               (funcall sources 'rw)
                                               (list common)))))
         (rw (cl-remove-if (lambda (path) (member path protected))
                           (delq nil (append (unless read-only shown) (list tmp)
                                             (mapcar (lambda (m) (harness-sandbox--mxc-path (car m)))
                                                     (harness-sandbox--scratch-mounts scratch cwd))))))
         (system (cl-loop for dir in (append harness-sandbox--mxc-system-dirs
                                             harness-sandbox-extra-read-only-dirs)
                          for path = (and (stringp dir) (not (file-remote-p dir))
                                          (file-directory-p dir) (harness-sandbox--mxc-path dir))
                          when (and path (not (cl-some (lambda (w) (harness-path-within-p w path)) rw)))
                          collect path))
         (ro (cl-remove-if (lambda (path) (member path rw))
                           (delete-dups (append (and read-only shown) (funcall sources 'ro)
                                                system protected))))
         ;; The command's status is the command line's, after the
         ;; private TMPDIR is gone.  A command killed by a signal leaves
         ;; it behind; macOS clears what is old in its temporary
         ;; directories itself.
         (command-line (concat (mapconcat #'harness-sandbox--sh-quote command " ")
                               (and tmp (concat "; s=$?; rm -rf -- " (harness-sandbox--sh-quote tmp)
                                                "; exit $s"))))
         (env (harness-sandbox--mxc-env
               (append (and tmp (list (cons "TMPDIR" (file-name-as-directory tmp))))
                       ;; As Emacs sets it for a process it starts itself.
                       (list (cons "PWD" cwd)
                             (cons "HARNESS_SANDBOX" "mxc"))
                       (and git (harness-sandbox--git-env (plist-get git :common))))))
         (net (if network "allow" "deny"))
         (json (harness-json-encode
                (list :version "1.0.0"
                      :containment "seatbelt"
                      :process (list :commandLine command-line
                                     :cwd cwd
                                     :env (harness-json-array env)
                                     :timeout 0)
                      :filesystem (list :readwritePaths (harness-json-array rw)
                                        :readonlyPaths (harness-json-array ro))
                      :network (list :egress (list :default net)
                                     :ingress (list :default net :hostLoopback net))
                      :seatbelt (list :nestedPty t)))))
    (list program "--config-base64"
          ;; Bytes: Emacs 29's `json-serialize' still gives text.
          (base64-encode-string (if (multibyte-string-p json) (encode-coding-string json 'utf-8-unix) json)
                                t))))

;;;; Methods

(defun harness-sandbox--missing-programs (&optional list)
  "Say that this system's sandbox programs are missing, for a message.
GNU/Linux has bwrap and systemd-run, macOS MXC's mxc-exec-mac.  With
LIST non-nil, only name them, as a list."
  (let ((darwin (eq system-type 'darwin)))
    (cond ((and list darwin) "mxc-exec-mac (MXC)")
          (list "bwrap, systemd-run")
          (darwin "mxc-exec-mac (MXC) is not available (see `harness-sandbox-mxc-program')")
          (t "neither bwrap nor systemd-run is available"))))

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
directories granted to a session) and `:readable' (extra directories
or files mounted read-only).  Both are shown where they are named,
where their symbolic links lead and, under a sandbox $HOME that is not
the real one's path, where they are under the real one; see
`harness-sandbox--mounts'.  `:read-only' non-nil mounts read-only the
working directory, the git directories and every `:writable' entry as
well, so that the command can write nothing but the sandbox's private
/tmp and the `:scratch' directories: those the caller made for the one
command and deletes after it, mounted writable whatever `:read-only'
says, after everything else (see `harness-sandbox--scratch-mounts',
which signals an error for one that would show writable what the
sandbox hides or keeps read-only).  Under MXC, on macOS, the private
/tmp is its private $TMPDIR, a directory made here for the command,
which removes it when it ends; see `harness-sandbox--mxc-command'.
They ask for no confinement: where COMMAND runs unconfined it reaches
them anyway.  A remote CWD or the `off' policy return COMMAND
unchanged.  Signals `harness-sandbox-unavailable' when the policy is
`required' and no backend exists.  A `:read-only' command fails closed
instead of running unconfined: it signals `harness-sandbox-unavailable'
too for the `off' policy, for a remote CWD and for no backend, whatever
the policy.

`:capabilities' names the Linux capabilities COMMAND is given, none by
default (see \"Capabilities\" in the commentary).  bwrap adds each with
`--cap-add' provided it is in `harness-sandbox-capabilities' and listed
in `harness-sandbox-grantable-capabilities' when COMMAND is wrapped;
one that is not is left out, with a line in the log.  A `:read-only'
command gets none, whatever is asked.  systemd-run and MXC cannot give
any: with names to give they signal `harness-sandbox-unavailable', as
bwrap does when `--cap-add' would be no capability of the sandbox's own
user namespace (setuid, or run by root).  Where COMMAND runs
unconfined anyway -- the `off' policy, a remote CWD, no backend -- it
has its user's own rights, and is returned as it is, with a line in
the debug log."
  (let* ((policy (harness-sandbox--policy cwd))
         (network (if (plist-member opts :network) (plist-get opts :network) t))
         (writable (plist-get opts :writable))
         (readable (plist-get opts :readable))
         (read-only (harness-json-true-p (plist-get opts :read-only)))
         (scratch (plist-get opts :scratch))
         ;; A command that changes nothing is given no capability.
         (capabilities (and (not read-only) (plist-get opts :capabilities))))
    (cond
     ((and read-only (eq policy 'off))
      (harness-sandbox--refuse-read-only command "the sandbox policy is `off'"))
     ((eq policy 'off)
      (when capabilities
        (harness-log 'debug "sandbox: policy off, so %S runs unconfined, with its user's own capabilities" (car command)))
      command)
     ((file-remote-p cwd)
      (when read-only
        (harness-sandbox--refuse-read-only
         command (format "%s is on another host, where the sandbox does not reach" cwd)))
      (harness-log 'debug "sandbox: remote cwd %s runs unconfined" cwd)
      command)
     ((eq harness-sandbox--backend 'bwrap)
      (let ((program (alist-get 'bwrap harness-sandbox--programs)))
        (harness-sandbox--bwrap-command program cwd command
                                        :network network :writable writable :readable readable
                                        :read-only read-only :scratch scratch
                                        :capabilities (and capabilities
                                                           (harness-sandbox--bwrap-capabilities
                                                            command capabilities program)))))
     ((eq harness-sandbox--backend 'systemd)
      (when capabilities
        (harness-sandbox--refuse-capabilities
         command capabilities
         "systemd-run --user cannot give a unit a capability, it can only lower its own"))
      (harness-sandbox--systemd-command (alist-get 'systemd harness-sandbox--programs) cwd command
                                        :network network :writable writable :readable readable
                                        :read-only read-only :scratch scratch))
     ((eq harness-sandbox--backend 'mxc)
      (when capabilities
        (harness-sandbox--refuse-capabilities
         command capabilities "MXC confines with macOS's Seatbelt, which has no Linux capabilities"))
      ;; The command's own $TMPDIR, private as bwrap's /tmp is: MXC
      ;; shows no shared temporary directory.
      (let ((tmp (with-file-modes #o700 (make-temp-file "harness-sandbox-" t))))
        (condition-case err
            (harness-sandbox--mxc-command (alist-get 'mxc harness-sandbox--programs) cwd command
                                          :network network :writable writable :readable readable
                                          :read-only read-only :tmp tmp
                                          :scratch scratch)
          (error (ignore-errors (delete-directory tmp t))
                 (signal (car err) (cdr err))))))
     (read-only
      (harness-sandbox--refuse-read-only command (harness-sandbox--missing-programs)))
     ((eq policy 'required)
      (harness-log 'error "sandbox: policy is `required' but no backend (%s) is available; refusing to run %S"
                   (harness-sandbox--missing-programs t) (car command))
      (signal 'harness-sandbox-unavailable
              (list (format "harness-sandbox-policy is `required' but %s"
                            (harness-sandbox--missing-programs)))))
     (t
      (harness-log 'warn "sandbox: no backend available; running %S unconfined" (car command))
      (when capabilities
        (harness-log 'debug "sandbox: no backend, so %S runs with its user's own capabilities" (car command)))
      command))))

(harness-defmethod sandbox/status ()
  "Return (:backend BACKEND :available (BACKENDS…) :policy POLICY)."
  (list :backend (or harness-sandbox--backend 'none)
        :available harness-sandbox--available
        :policy (harness-sandbox--policy nil)))

(harness-defmethod sandbox/capabilities (cwd)
  "Say what the jail does about the Linux capabilities of commands run in CWD.
Return (:enforced BOOL :backend BACKEND :grantable (NAME…) :docs
\((NAME . DOC)…) :scopes ((NAME . SCOPE)…) :why TEXT).  `:enforced' is
non-nil when the jail can give such a command a capability and drops
every other: the backend is bwrap, CWD is local, the sandbox policy is
not `off', and `--cap-add' is a capability of the sandbox's own user
namespace (bwrap is neither setuid nor run by root).  `:why' says what
stands in the way when it is not.  `:grantable' are the canonical
names of `harness-sandbox-grantable-capabilities' that are
capabilities the harness knows, `:docs' says in a line what each lets a
command do and `:scopes' what there is to say on top of that it counts
inside the sandbox's own namespaces only, for those that have it.
Whether a session may be given one is for the access module, which
asks the user."
  (let* ((why (harness-sandbox--capabilities-why cwd))
         (grantable (harness-sandbox-grantable)))
    (list :enforced (and (null why) t)
          :backend (or harness-sandbox--backend 'none)
          :grantable grantable
          :docs (mapcar (lambda (name) (cons name (harness-sandbox-capability-info name :doc))) grantable)
          :scopes (cl-loop for name in grantable
                           for scope = (harness-sandbox-capability-scope name)
                           when scope collect (cons name scope))
          :why why)))

(harness-defmethod sandbox/capability-name (value)
  "Return the canonical name of the Linux capability VALUE names, or nil.
Case, dashes and the `CAP_' prefix do not matter, and `ptrace' is
CAP_SYS_PTRACE; see `harness-sandbox-capability-name'.  Nil for a name
the harness does not know, `ALL' included."
  (harness-sandbox-capability-name value))

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
       (memq harness-sandbox--backend '(bwrap systemd mxc))
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
  :doc "Kernel sandbox (bwrap / systemd-run / MXC on macOS) for spawned tool processes."
  :requires '(config)
  :init #'harness-sandbox--init)

(provide 'harness-sandbox)
;;; harness-sandbox.el ends here
