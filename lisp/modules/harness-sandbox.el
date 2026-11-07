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
;; `mxc' (MXC's mxc-exec-mac, below) or none.  NVIDIA OpenShell
;; (below) is a backend too, but only one you ask for with
;; `harness-sandbox-backend': `auto' never picks it.  The
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
;; a fresh /proc and /dev, a /tmp of its own (the caller's, when it
;; gives one: `:tmp' below), and the session's working directory
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
;; `:tmp' makes the session's temporary directory the command's /tmp,
;; writable, instead of an empty tmpfs of its own: programs that go to
;; /tmp without asking (most of them do; `$TMPDIR' is often ignored)
;; then leave their files where the next command, the file tools and
;; the harness find them, instead of in a place thrown away with the
;; command.  TMPDIR is set to /tmp as well, so the two agree, and
;; anything the command makes there is the session's to clean up.  It
;; is shown at its own path too, so that the path `session_info' and the
;; file tools name leads to the same files; a directory in /tmp cannot
;; be shown that way, and keeps the private /tmp.
;; A command that changes nothing (`:read-only') and one that must not
;; see what the session left behind (the `locked' profile) keep a
;; private empty /tmp.  bwrap and systemd-run give it; MXC has no
;; mount namespace and cannot write /tmp at all, and OpenShell's /tmp
;; is the image's, so both keep their own and a command there leaves
;; nothing to find.
;;
;; A confined command has HARNESS_SANDBOX set to the backend's name,
;; `bwrap', `systemd', `mxc' or `openshell', so a script can tell it
;; runs confined: scripts/dev.sh warns that an Emacs it starts there
;; ends with the command.
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
;; That includes the ~/Library that Cocoa programs look in on their
;; own, without asking $HOME: the NS build of Emacs, which loads its
;; color list from ~/Library/Colors and writes it when it is short,
;; aborts at startup if it cannot, even in a --batch process such as
;; the file tools' worker and the elisp tool's child.  So Cocoa's home
;; (CFFIXED_USER_HOME, which moves nothing else) is that same private
;; directory, where such a program finds nothing and makes what it
;; needs.  MXC passes on none of the harness's environment, so the
;; command's is written out whole: `process-environment' as it is when
;; the command is wrapped, with TMPDIR, CFFIXED_USER_HOME, PWD,
;; HARNESS_SANDBOX=mxc and a worktree's commit identity set.
;; `:network nil' denies the network, loopback included; otherwise it
;; is open both ways, as bwrap leaves it.  `:read-only' leaves nothing
;; writable but that $TMPDIR.  Unlike bwrap, MXC gives the command no
;; PID namespace of its own; /tmp cannot be written there (a command
;; uses $TMPDIR); and MXC hands the command's output on only when it
;; ends, so the note under a running bash call shows none until then.
;;
;; NVIDIA OpenShell (https://github.com/NVIDIA/OpenShell, see
;; `harness-sandbox-openshell-program') is a different kind of backend,
;; and the one `auto' never picks.  It is no wrapper but a runtime: a
;; gateway, a service of yours, makes each sandbox a container from an
;; image, in which a supervisor enforces a policy with Landlock and
;; seccomp and lets out only the network connections the policy
;; allows.  Ask for it with `harness-sandbox-backend' set to
;; `openshell'; docs/openshell.md says how to set the gateway up.  When
;; it cannot be used -- no openshell program, no gateway that answers
;; `openshell status', a program too old for the options this module
;; passes -- the harness falls back to the backend `auto' would pick,
;; logs why, and `sandbox/status' says so (`:requested', `:problem');
;; it falls back to no sandbox only when there is no other.
;;
;; A command runs in a sandbox made for it alone: openshell's
;; `sandbox create' (detached, ephemeral) makes it, `sandbox exec' runs
;; the command, whose output, standard error and exit status come back
;; as they are, and `sandbox delete' removes it, in the background (a
;; sandbox whose deletion fails ends by itself, an hour or so after it
;; was made).  The gateway is the one `openshell' uses: the active one,
;; or that of $OPENSHELL_GATEWAY.  What the command sees is what the
;; access model lists, as OpenShell can say it: the working directory, the
;; `:writable' directories and the `:scratch' ones are bind mounts,
;; read-write; the `:readable' ones, the skills and a worktree's git
;; directory (its hooks, config, index and HEAD read-only inside it) are
;; bind mounts too, as bwrap shows them, each at its own path; a tmpfs
;; is $HOME, with the directories of the real home shown under it as
;; systemd-run does.  The gateway must allow bind mounts
;; (docs/openshell.md).  The policy file the sandbox is made with names
;; the same directories for Landlock (`filesystem_policy'), the system
;; paths of the image and those of `harness-sandbox-openshell-image-paths',
;; the network rules and the host user's own uid and gid; `:read-only'
;; makes every directory read-only but /tmp.  A command in the image
;; is not a command on this machine: it sees the image's /usr, so the
;; tools it runs -- git, and Emacs for the elisp tool -- must be in the
;; image (`harness-sandbox-openshell-image'), and
;; `harness-sandbox-extra-read-only-dirs' means nothing to it.
;;
;; What OpenShell cannot say the harness does not pretend.  It gives a
;; command no Linux capability, and `:capabilities' signal
;; `harness-sandbox-unavailable' as for systemd-run.  Its network is a
;; list of the endpoints a policy allows, never open: `:network nil' is
;; a policy with none, as empty as bwrap's network namespace, and a
;; command with the network on reaches only the hosts of
;; `harness-sandbox-openshell-network-rules'.  No argument of a command
;; may be longer than 32 KiB, which the gateway refuses.
;; `sandbox/status' lists such limits of the backend in use (`:limits').
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
;; of the repository for deleted and drops its registration.  No command
;; line is read to refuse those: the registration of every worktree the
;; sandbox does not show is mounted read-only over the writable git
;; directory, so those commands change nothing however they are written
;; (see "Git worktrees" below).
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
;; `:read-only' command is given none.  bwrap alone can: systemd-run,
;; MXC and OpenShell signal `harness-sandbox-unavailable' for
;; `:capabilities', and so does bwrap when `--cap-add' would hand out
;; real capabilities of the host, being setuid or run by root.  See
;; "Capabilities" below.
;;
;; Profiles: `sandbox/wrap' takes `:profile', `default' being the
;; sandbox above.  `locked' is the secret-file sandbox (the module
;; secret-sandbox asks for it): a minimal environment built from `:env'
;; instead of the harness's own, the network off, no capability and
;; nothing writable but the sandbox's private temporary directory, and
;; `:hide' paths covered after every other mount so that a secret file
;; the agent must not read is not shown even where a directory holding
;; it is.  Only bwrap and MXC give it; systemd-run and OpenShell, the
;; `off' policy, no backend and a remote directory signal
;; `harness-sandbox-unavailable' rather than run with a wider view.
;; `sandbox/profiles' says what the backend in force can give, so a
;; caller can refuse before it asks the user.  A locked command has no
;; network at all; no option opens it.
;;
;; Methods: `sandbox/wrap', `sandbox/status', `sandbox/profiles',
;; `sandbox/confined-p', `sandbox/capabilities',
;; `sandbox/capability-name'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar harness-sandbox-policy)         ; defined by the config module
(defvar harness-state-directory)        ; defined in harness.el

(define-error 'harness-sandbox-unavailable
  "Sandbox required but no backend is available" 'harness-error)

(defcustom harness-sandbox-backend 'auto
  "Which sandbox backend to use.
`auto' picks the first available of bwrap and systemd-run on GNU/Linux,
and `mxc' (MXC's mxc-exec-mac, see `harness-sandbox-mxc-program') on
macOS; it never picks `openshell'.  A specific symbol forces that
backend (and counts as unavailable when its executable is missing, or
on a system it does not run on: `mxc' anywhere but macOS, `bwrap' and
`systemd' on macOS); `none' disables wrapping regardless of policy
detection, subject to `harness-sandbox-policy'.

`openshell' runs commands in NVIDIA OpenShell sandboxes (see
`harness-sandbox-openshell-program'; docs/openshell.md says how to set
it up).  It needs a gateway that answers `openshell status', and when
it cannot be used the harness falls back to what `auto' would pick,
says why in the log and in `sandbox/status', and tries again the next
time the backend is detected (`harness-sandbox-detect')."
  :type '(choice (const auto) (const bwrap) (const systemd) (const mxc)
                 (const :tag "openshell (NVIDIA OpenShell)" openshell) (const none))
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

;;;; OpenShell options

;; These are read from their global values only (`default-value'), never
;; a buffer's or a directory's: a project's .dir-locals.el must not
;; widen the network, choose the image or add arguments for the sandbox
;; its own sessions run in.  The gateway is the one `openshell' uses
;; itself: the active one, or that of $OPENSHELL_GATEWAY, which the
;; commands this module runs inherit.

(defcustom harness-sandbox-openshell-program "openshell"
  "Name or absolute path of NVIDIA OpenShell's command line, openshell.
OpenShell (https://github.com/NVIDIA/OpenShell) runs each command in a
sandbox of a gateway you run: a container whose supervisor enforces a
policy with Landlock and seccomp.  This module drives it through this
program (`openshell sandbox create', `sandbox exec' and `sandbox
delete'), and only when `harness-sandbox-backend' is `openshell'.
docs/openshell.md has the setup: the gateway, an image with the tools
your commands run, and the gateway's permission for bind mounts.  The
program is looked for when the sandbox module starts (see
`harness-sandbox-detect')."
  :type 'string :group 'harness)

(defcustom harness-sandbox-openshell-image nil
  "The image OpenShell sandboxes are made from, or nil for the gateway's default.
Any reference `openshell sandbox create --from' takes: an image the
gateway's container engine has or can pull.  A command runs in it, and
sees its /usr, not this machine's, so it must hold bash, sleep and the
tools commands use -- git, and Emacs for the elisp tool.  The gateway's
default image is a bare Ubuntu."
  :type '(choice (const :tag "The gateway's default image" nil) string)
  :risky t :group 'harness)

(defcustom harness-sandbox-openshell-driver 'docker
  "The compute driver of the gateway, `docker' or `podman'.
It names the key of the driver config that carries the bind mounts the
sandbox is made with (`--driver-config-json', see
`harness-sandbox--openshell-driver-config').  The microVM and
Kubernetes drivers cannot be used: they take few or no host
directories."
  :type '(choice (const docker) (const podman))
  :risky t :group 'harness)

(defcustom harness-sandbox-openshell-network-rules nil
  "The endpoints a command with the network on may reach in an OpenShell sandbox.
OpenShell denies every outbound connection that no rule of its policy
allows, and has no rule for an open network, so a command with the
network on reaches exactly what this list names, and nothing when it
is nil.  An entry is an endpoint, \"HOST:PORT\" or \"HOST:PORT,PORT\", the
host a name or a wildcard OpenShell takes (\"*.example.com\"), such as
\"github.com:443\"; they make one rule, which any program may use.  An
entry (NAME :endpoints (ENDPOINT...) :binaries (PATH...)) is a rule of
its own, for the programs whose real paths the globs of :binaries name
\(\"/**\", any, by default).  A session whose network is off gets none of
them.  An entry that is neither is left out, with a line in the log."
  :type '(repeat (choice (string :tag "Endpoint HOST:PORT")
                         (sexp :tag "Rule (NAME :endpoints (ENDPOINT...) :binaries (PATH...))")))
  :risky t :group 'harness)

(defcustom harness-sandbox-openshell-image-paths nil
  "Directories of the OpenShell image a command may read, besides the system ones.
The policy lists what a command may reach and Landlock refuses the
rest.  The image's system directories (/usr, /lib, /bin, /etc and the
like) are listed; a toolchain the image keeps elsewhere, Emacs in /opt
say, only when it is named here.  They are paths of the image, not
of this machine, and nothing of this machine is shown there for them:
this is not `harness-sandbox-extra-read-only-dirs', which OpenShell
ignores, since its image is no copy of this machine's /usr."
  :type '(repeat directory) :risky t :group 'harness)

(defcustom harness-sandbox-openshell-extra-args nil
  "Further arguments for `openshell sandbox create', a list of strings.
For instance (\"--cpu\" \"2\" \"--memory\" \"4Gi\") to size the sandboxes.
They come before the command, after everything this module passes."
  :type '(repeat string) :risky t :group 'harness)

(defconst harness-sandbox--openshell-system-paths
  '(:read-only ("/usr" "/lib" "/lib64" "/bin" "/sbin" "/etc" "/proc" "/var/lib" "/var/log"
                "/dev/urandom" "/dev/random" "/dev/zero")
    :read-write ("/tmp" "/dev/null"))
  "The paths of the sandbox image a command may read and write, as a plist.
`:read-only' and `:read-write' list absolute paths, which go into the
policy's `filesystem_policy' beside the directories of the session; a
path the image lacks is skipped.  OpenShell adds such paths itself only
when the policy has network rules, so they are listed here.")

(defconst harness-sandbox--openshell-ttl 3900
  "Seconds an OpenShell sandbox lives at most, whatever happens to its command.
Its main process is a `sleep' for so long, and OpenShell deletes an
ephemeral sandbox when that ends: the harness deletes the sandbox
itself as soon as the command is done, and this is what removes one
the harness could not.  It must be longer than the longest command (the
bash tool's limit is 3600 seconds), or a long command loses its sandbox.")

(defconst harness-sandbox--openshell-probe-timeout 10
  "Seconds `harness-sandbox-detect' waits for each openshell call that checks it.")

(defvar harness-sandbox--openshell-run-as-host-user t
  "Non-nil runs the commands of an OpenShell sandbox as this user's uid and gid.
Files a command writes in a bind-mounted directory are then yours, as
they are under bwrap; left to the image and the driver, the commands
run as another user, who cannot write what yours do.  It does not
apply when this Emacs runs as root: OpenShell refuses uid 0.  Nobody
should have to change it; a rootless Podman that maps users its own
way may.")

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
  "Backend chosen at initialisation.
It is `bwrap', `systemd', `mxc', `openshell' or `none'.")

(defvar harness-sandbox--available nil
  "Backends whose executables were found at initialisation.")

(defvar harness-sandbox--programs nil
  "Alist of backend -> absolute executable path found at initialisation.")

(defvar harness-sandbox--requested nil
  "The backend that was asked for and could not be used, or nil.
Only OpenShell can be: the others count as `none' when they are missing,
as always.  `harness-sandbox--problem' says why.")

(defvar harness-sandbox--problem nil
  "Why `harness-sandbox--requested' could not be used, as text, or nil.")

(defconst harness-sandbox--auto-backends '(bwrap systemd mxc)
  "The backends `auto' chooses among, in the order of preference.
OpenShell is not one: it needs a gateway and an image set up on purpose,
and what a command sees there is a container, not this machine.")

;;;; Detection

(defun harness-sandbox--auto-backend ()
  "Return the backend `auto' picks among those found, or `none'.
It is the first of `harness-sandbox--auto-backends' that was found."
  (or (cl-find-if (lambda (backend) (memq backend harness-sandbox--available))
                  harness-sandbox--auto-backends)
      'none))

(defun harness-sandbox-detect ()
  "Find the available backends and choose one.
Return the chosen backend symbol.  Safe to call again: it refreshes
`harness-sandbox--available' and `harness-sandbox--backend', so it is
what to run after starting an OpenShell gateway that was down.  On
macOS only MXC is looked for (`harness-sandbox-mxc-program'),
elsewhere only bwrap and systemd-run; OpenShell
\(`harness-sandbox-openshell-program') anywhere, and chosen only when
`harness-sandbox-backend' asks for it, after a check that it can be
used (`harness-sandbox--openshell-problem'): without it the backend is
the one `auto' picks, and `harness-sandbox--problem' says why."
  (interactive)
  (let* ((darwin (eq system-type 'darwin))
         (bwrap (and (not darwin) (executable-find harness-sandbox--bwrap-program)))
         (systemd (and (not darwin) (executable-find harness-sandbox--systemd-run-program)))
         (mxc (and darwin (stringp harness-sandbox-mxc-program)
                   (not (string-empty-p harness-sandbox-mxc-program))
                   ;; An absolute path, or one from ~, is found as it is.
                   (executable-find (if (file-name-directory harness-sandbox-mxc-program)
                                        (expand-file-name harness-sandbox-mxc-program)
                                      harness-sandbox-mxc-program))))
         (openshell (harness-sandbox--openshell-find)))
    (setq harness-sandbox--programs
          (delq nil (list (and bwrap (cons 'bwrap bwrap))
                          (and systemd (cons 'systemd systemd))
                          (and mxc (cons 'mxc mxc))
                          (and openshell (cons 'openshell openshell)))))
    (setq harness-sandbox--available (mapcar #'car harness-sandbox--programs))
    (setq harness-sandbox--requested nil
          harness-sandbox--problem nil)
    (setq harness-sandbox--backend
          (pcase harness-sandbox-backend
            ('auto (harness-sandbox--auto-backend))
            ('none 'none)
            ('openshell
             (if-let* ((problem (harness-sandbox--openshell-problem openshell)))
                 (let ((fallback (harness-sandbox--auto-backend)))
                   (setq harness-sandbox--requested 'openshell
                         harness-sandbox--problem problem)
                   (harness-log 'warn "sandbox: OpenShell was asked for, but %s; using %s instead"
                                problem fallback)
                   fallback)
               'openshell))
            (forced (if (memq forced harness-sandbox--available) forced 'none))))
    (harness-log 'info "sandbox: backend %s (available: %s, policy %s)"
                 harness-sandbox--backend
                 (if harness-sandbox--available
                     (mapconcat #'symbol-name harness-sandbox--available ", ")
                   "none")
                 (harness-sandbox--policy nil))
    (when (called-interactively-p 'interactive)
      (message "Sandbox backend: %s%s" harness-sandbox--backend
               (if harness-sandbox--problem
                   (format " (OpenShell cannot be used: %s)" harness-sandbox--problem)
                 "")))
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
     ((eq harness-sandbox--backend 'openshell)
      "the sandbox backend is OpenShell, not bwrap, and it runs commands as a non-root user with no Linux capability, with no way to give one")
     (t (format "no sandbox backend can confine its commands (%s), and only bwrap can give a command a capability"
                (harness-sandbox--missing-programs))))))

(defun harness-sandbox--refuse-locked (command why)
  "Signal `harness-sandbox-unavailable': a locked COMMAND cannot be confined.
WHY says what stands in the way.  A command that is to read a secret
must not run in a wider sandbox, whatever the policy says: the secret
would be in reach of the agent's own commands."
  (harness-log 'error "sandbox: a locked command needs the locked profile, but %s; refusing to run %S"
               why (car command))
  (signal 'harness-sandbox-unavailable
          (list (format "a locked command cannot run without the locked profile, but %s" why))))

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

(defconst harness-sandbox--tmp "/tmp"
  "The path a command's temporary directory is shown at, when `:tmp' gives one.
The library and the programs a command runs know it without being told:
`mkstemp' and the shell's own `mktemp' go there when nothing says
otherwise.")

(defun harness-sandbox--tmp-directory (tmp)
  "Return the directory a command's /tmp shows for the `:tmp' option TMP, or nil.
TMP is that option's value: a local directory the caller keeps files in
from one command to the next, the session's own temporary directory.
Nil for anything else -- no local directory, the root directory, one
that is or lies in /tmp, one that holds the home directory, or one that
is, holds or lies in a directory the sandbox mounts its own
\\(`harness-sandbox--system-paths') -- with a line in the log saying
why: shown writable at /tmp, such a directory would show more than the
caller meant to give, or undo what the sandbox keeps out of the
command's sight, and one in /tmp would lose its own path inside the
sandbox, where /tmp is the directory itself and what the file tools
name would no longer reach it.  A command given none keeps the
sandbox's own private /tmp, as it had before there was one to show."
  (when (and (stringp tmp) (not (file-remote-p tmp)))
    (let* ((named (expand-file-name tmp))
           (real (and (file-directory-p named)
                      (directory-file-name (file-truename named))))
           (home (getenv "HOME"))
           (why (cond
                 ((null real) "it is no local directory")
                 ((equal real "/") "it is the root directory")
                 ((harness-path-within-p harness-sandbox--tmp real)
                  "it is or lies in /tmp, where showing it would leave its own path unreachable")
                 ((and (stringp home) (file-name-absolute-p home)
                       (harness-path-within-p real home))
                  "it holds the home directory")
                 ((cl-some (lambda (system)
                             (or (harness-path-within-p system real)
                                 (harness-path-within-p real system)))
                           harness-sandbox--system-paths)
                  "it is, holds or lies in a directory the sandbox mounts its own"))))
      (when why
        (harness-log 'warn "sandbox: not showing %s as /tmp: %s" tmp why))
      (unless why real))))

(defun harness-sandbox--tmp-path-mounts (mounts tmp)
  "Return MOUNTS with TMP shown at its own path, unless it is there already.
A command's /tmp shows TMP (`sandbox/wrap'); the session's other tools
name that directory at its own path -- `session_info' tells a session
where it is -- so that path has to lead to it as well, whether the
caller listed it or not."
  (if (or (null tmp)
          (cl-find tmp mounts :key (lambda (mount) (directory-file-name (nth 2 mount)))
                   :test #'equal))
      mounts
    (append mounts (list (list 'rw tmp tmp)))))

(defun harness-sandbox--hide-paths (hide tmp)
  "Return the paths of HIDE the sandbox must hide, as (PATH . DIRECTORY-P).
TMP is the directory the sandbox's /tmp shows, or nil.  Each path is
made absolute and its symbolic links followed; one that does not exist,
or that lies under /proc, /dev or /sys, is left out.

With TMP, a path under /tmp names what TMP holds at the same place:
one in TMP is hidden where it is named and at /tmp/REL alike, since
both show it; one that is not in TMP is left out, since /tmp does not
lead to it, and hiding it there would make an empty file or directory
in TMP."
  (cl-loop for path in hide
           for named = (and (stringp path) (not (file-remote-p path))
                            (expand-file-name path))
           for real = (and named (file-exists-p named)
                           (directory-file-name (file-truename named)))
           for directory = (and real (file-directory-p real))
           when (and real
                     (not (cl-some (lambda (system) (harness-path-within-p system real))
                                   '("/proc" "/dev" "/sys"))))
           append
           (cond
            ((null tmp) (list (cons real directory)))
            ((harness-path-within-p tmp real)
             (delete-dups
              (list (cons real directory)
                    (cons (concat harness-sandbox--tmp
                                  (substring real (length tmp)))
                          directory))))
            ((harness-path-within-p harness-sandbox--tmp real) nil)
            (t (list (cons real directory))))))

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
;;
;; The other worktrees.  That git directory holds a registration for
;; every linked worktree of the repository, worktrees/NAME, and the
;; `gitdir' file in it names the worktree's .git file.  The sandbox
;; shows the working directory and what is mounted, not the other
;; worktrees, so git there takes each of them for deleted: `git worktree
;; prune' drops its registration, which leaves the worktree's files
;; without an index and every git command in them failing, and `remove',
;; `move', `lock' and `unlock' of another worktree change a registration
;; that is not the session's to change.  Nothing here reads a command
;; line to refuse any of that, since a command line can always be
;; written so that it is not read.  The registration of every worktree
;; the sandbox does not show is mounted read-only over the writable git
;; directory (`harness-sandbox--hidden-registrations'), so no command
;; changes it, however it is run.
;;
;; A worktree is shown when it lies in the working directory or in a
;; directory mounted writable, as it is recorded -- the sandbox has only
;; the names it mounts, so a recorded path that goes round them does not
;; exist there, whatever it leads to outside -- and its real path lies in
;; one of the sources of those mounts, so a link on the way does not lead
;; out of them.  A registration whose worktree cannot be told is not
;; shown, the safe answer.  The session's own registration, and those of
;; the worktrees it makes in its own directory, stay writable: it commits
;; and cleans up after itself.  A worktree that is really gone, inside
;; the working directory, is pruned as it should be.
;;
;; What is covered is the git directory of a linked worktree used as the
;; working directory, and the .git directory at the top of the working
;; directory or of a directory mounted writable: the repositories a
;; session works in.  A repository further down a granted directory is
;; not looked for, and only the registrations there are when the command
;; starts are kept: a worktree another session adds meanwhile is not.
;; bwrap and systemd-run mount them.  MXC has no mounts: it lists them
;; as read-only paths, with the git directory's other protected paths
;; (its commentary is below), so that the registry is not left to a
;; command line there either.  That is tested as the configuration it
;; builds; no macOS host has run it.

(defvar harness-sandbox--git-identity (make-hash-table :test 'equal)
  "Git common dir -> (NAME . EMAIL) as the host's git config gives them.")

(defun harness-sandbox--read-file-line (file)
  "Return the text of FILE with surrounding whitespace trimmed.
FILE holds one line, as a worktree's .git file and the commondir file
of its git directory do.  Git writes these as UTF-8, and naming the
coding system skips the detection, nearly all of a read's time; a
file is read to its first 4096 bytes, far more than a path."
  (let ((coding-system-for-read 'utf-8))
    (with-temp-buffer
      (insert-file-contents file nil 0 4096)
      (string-trim (buffer-string)))))

(defun harness-sandbox--worktree-git (cwd)
  "When CWD is inside a linked git worktree, describe its git directory.
Return (:common DIR :gitdir DIR :protected (PATH…)) or nil.  `:gitdir' is
the worktree's own registration in the common directory."
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
                :gitdir (and gitdir (file-name-as-directory gitdir))
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

(defun harness-sandbox--directory-name (path)
  "Return PATH made absolute, as written (no link followed), as a directory name."
  (file-name-as-directory (expand-file-name path)))

(defun harness-sandbox--path-in-p (dir path)
  "Non-nil when PATH lies in DIR, both taken as written: no link is followed."
  (string-prefix-p (harness-sandbox--directory-name dir) (harness-sandbox--directory-name path)))

(defun harness-sandbox--same-place-p (a b)
  "Non-nil when A and B name the same place, links followed."
  (equal (file-name-as-directory (file-truename a))
         (file-name-as-directory (file-truename b))))

(defun harness-sandbox--admin-dirs (common)
  "Return the registrations of the worktrees of the git directory COMMON.
They are the directories worktrees/NAME of it, without a trailing slash.
A link there is left out: git makes none, and a bind mount cannot be
made on one."
  (let ((dir (expand-file-name "worktrees" common)))
    (when (file-directory-p dir)
      (cl-loop for (name . attributes) in (directory-files-and-attributes
                                           dir t directory-files-no-dot-files-regexp t)
               for type = (file-attribute-type attributes)
               if (stringp type)
               do (harness-log 'warn "sandbox: not protecting %s, which is a link" name)
               else if (eq type t)
               collect (directory-file-name name)))))

(defun harness-sandbox--recorded-worktree (admin)
  "Return the directory the registration ADMIN says it is for, or nil.
It is the one holding the .git file ADMIN's gitdir file names, as it is
recorded, relative to ADMIN when the path is.  Nil without a gitdir file
that can be read."
  (let ((file (expand-file-name "gitdir" admin)))
    (when (file-regular-p file)
      (condition-case nil
          (let ((line (harness-sandbox--read-file-line file)))
            (and (not (string-empty-p line))
                 (file-name-directory (expand-file-name line admin))))
        (error nil)))))

(defun harness-sandbox--shown-p (worktree shown)
  "Non-nil when the sandbox shows the directory WORKTREE to a command that writes.
SHOWN is (DESTINATIONS . SOURCES) of what it mounts writable, as
directory names (`harness-sandbox--directory-name').  WORKTREE must lie
in one of the DESTINATIONS as it is recorded, and its real path in one
of the SOURCES.  Unknown, it is not shown."
  (and worktree
       (let ((named (harness-sandbox--directory-name worktree)))
         (and (cl-some (lambda (dest) (string-prefix-p dest named)) (car shown))
              (let ((real (ignore-errors (harness-sandbox--directory-name (file-truename worktree)))))
                (and real (cl-some (lambda (source) (string-prefix-p source real)) (cdr shown))))))))

(defun harness-sandbox--hidden-registrations (cwd mounts scratch-mounts)
  "Return the registrations of the worktrees a sandbox for CWD does not show.
MOUNTS are those `harness-sandbox--mounts' made for it and
SCRATCH-MOUNTS those of `harness-sandbox--scratch-mounts'.  Each
registration is (SOURCE . DESTINATION): the directory worktrees/NAME of a
git directory that is writable there, where it is on this machine and
where it shows in the sandbox, which the sandbox mounts read-only over
it.  See the commentary above for what is covered and when a worktree
is shown.  The session's own registration is never one."
  (let* ((cwd (directory-file-name (expand-file-name cwd)))
         (git (harness-sandbox--worktree-git cwd))
         (own (and git (plist-get git :gitdir)))
         ;; (SOURCE . DESTINATION) of what a command may write.
         (writable (append (list (cons (directory-file-name (file-truename cwd)) cwd))
                           (cl-loop for (mode source dest) in mounts
                                    when (eq mode 'rw) collect (cons source dest))
                           scratch-mounts))
         (shown (cons (mapcar (lambda (w) (harness-sandbox--directory-name (cdr w))) writable)
                      (mapcar (lambda (w) (harness-sandbox--directory-name (car w))) writable)))
         views registrations)
    ;; The git directories whose registrations are writable there: the
    ;; common one of a worktree used as the working directory, which is
    ;; bound where it is, and the .git directory at the top of what is
    ;; mounted writable, wherever it shows.
    (when git
      (let ((common (directory-file-name (plist-get git :common))))
        (push (cons common common) views)))
    (dolist (w writable)
      (let ((dotgit (expand-file-name ".git" (car w))))
        (when (file-directory-p dotgit)
          (push (cons (directory-file-name dotgit)
                      (directory-file-name (expand-file-name ".git" (cdr w))))
                views))))
    (dolist (view (delete-dups (nreverse views)))
      (let* ((registry (expand-file-name "worktrees" (car view)))
             ;; The session's own registration is in this git directory when
             ;; its parent is the same place as this registry's; it is then
             ;; told apart by its name.  One comparison of places here, not
             ;; one for each registration.
             (own-name (and own
                            (harness-sandbox--same-place-p (file-name-directory (directory-file-name own))
                                                           registry)
                            (file-name-nondirectory (directory-file-name own)))))
        (dolist (admin (harness-sandbox--admin-dirs (car view)))
          (unless (or (and own-name (equal own-name (file-name-nondirectory admin)))
                      (harness-sandbox--shown-p (harness-sandbox--recorded-worktree admin) shown))
            (push (cons admin (expand-file-name (file-name-nondirectory admin)
                                                (expand-file-name "worktrees" (cdr view))))
                  registrations)))))
    (delete-dups (nreverse registrations))))

(defun harness-sandbox--bwrap-git-args (cwd &optional read-only registry)
  "Return the bwrap arguments that let git work in a worktree at CWD.
With READ-ONLY the git directory is shown read-only whole, hooks,
config, index and HEAD no more or less than the rest: git then reads
the repository and changes none of it.  REGISTRY, the registrations of
the worktrees that are not shown (`harness-sandbox--hidden-registrations'),
are mounted read-only over the git directory, after everything that
makes it writable, whether CWD is a worktree or the main checkout."
  (let ((git (harness-sandbox--worktree-git cwd)))
    (append
     (when git
       (let ((common (directory-file-name (plist-get git :common))))
         (append (list (if read-only "--ro-bind" "--bind") common common)
                 (unless read-only
                   (cl-loop for p in (plist-get git :protected) append (list "--ro-bind" p p))))))
     (unless read-only
       (cl-loop for (source . dest) in registry append (list "--ro-bind" source dest)))
     (when git
       (cl-loop for (var . value) in (harness-sandbox--git-env (plist-get git :common))
                append (list "--setenv" var value))))))

(defun harness-sandbox--systemd-registry-args (registry)
  "Return the systemd-run settings showing the registrations REGISTRY read-only.
A path a setting cannot hold as written cannot be kept from the command:
that is an error, not a registration left writable."
  (cl-loop for (source . dest) in registry
           do (unless (and (harness-sandbox--systemd-path-p source) (harness-sandbox--systemd-path-p dest))
                (signal 'harness-sandbox-unavailable
                        (list (format "the registration of a worktree, %s, cannot be written in a systemd setting, so it cannot be kept from the commands that run here"
                                      dest))))
           append (list "-p" (concat "BindReadOnlyPaths=" source
                                     (if (equal source dest) "" (concat ":" dest))))))

(defun harness-sandbox--systemd-git-args (cwd &optional read-only registry)
  "Return the systemd-run arguments that let git work in a worktree at CWD.
With READ-ONLY the git directory is bound read-only whole and not made
writable, as for `harness-sandbox--bwrap-git-args', and REGISTRY is as
there."
  (let ((git (harness-sandbox--worktree-git cwd)))
    (append
     (when git
       (let ((common (directory-file-name (plist-get git :common))))
         (if read-only
             (list "-p" (concat "BindReadOnlyPaths=" common))
           (append (list "-p" (concat "BindPaths=" common) "-p" (concat "ReadWritePaths=" common))
                   (cl-loop for p in (plist-get git :protected)
                            append (list "-p" (concat "BindReadOnlyPaths=" p)))))))
     (unless read-only (harness-sandbox--systemd-registry-args registry))
     (when git
       (cl-loop for (var . value) in (harness-sandbox--git-env (plist-get git :common))
                collect (format "--setenv=%s=%s" var value))))))

(defconst harness-sandbox--private-home "/tmp"
  "The home a locked command gets.
It is the sandbox's own private /tmp, the only place a locked command
may write.  A real home is never passed on: it would show the
credentials the locked profile exists to keep away from the agent.")

(defun harness-sandbox--locked-env (env)
  "Return the minimal environment of a locked command, as (NAME . VALUE).
ENV, an alist, adds to it; the harness's own environment is not used.
PATH is the harness's, so a command finds the tools the user has; HOME
and TMPDIR are the sandbox's private /tmp; LANG and TERM are passed on
when set."
  (append
   (list (cons "PATH" (or (getenv "PATH") "/usr/local/bin:/usr/bin:/bin"))
         (cons "HOME" harness-sandbox--private-home)
         (cons "TMPDIR" harness-sandbox--private-home)
         (cons "HARNESS_SANDBOX" "bwrap"))
   (cl-loop for name in '("LANG" "TERM")
            for value = (getenv name)
            when value collect (cons name value))
   (cl-loop for (name . value) in env
            when (and (stringp name) (stringp value)) collect (cons name value))))

(defun harness-sandbox--hide-args (hide &optional tmp)
  "Return bwrap arguments that hide each path of HIDE.
TMP is the directory the sandbox's /tmp shows, or nil
\\(`harness-sandbox--hide-paths' says where each path is hidden then).
A file is bound to `/dev/null', a directory covered by a tmpfs, after
every other mount, so a path shown by a mount below it is hidden too.
A path under /proc, /dev or /sys is left alone: covering one of those
would break the sandbox itself."
  (cl-loop for (path . directory) in (harness-sandbox--hide-paths hide tmp)
           append (if directory
                      (list "--tmpfs" path)
                    (list "--ro-bind" "/dev/null" path))))

(cl-defun harness-sandbox--bwrap-command (program cwd command &key (network t) writable readable read-only
                                                   scratch capabilities env profile hide tmp)
  "Build the bwrap command line running COMMAND in CWD.
PROGRAM is the bwrap executable.  NETWORK nil unshares the network
namespace; WRITABLE and READABLE list extra directories or files to
expose (see `harness-sandbox--mounts' for how they are shown).  READ-ONLY binds
CWD, the git directories and every WRITABLE entry with `--ro-bind', so
that the command writes nothing but the sandbox's private /tmp and the
SCRATCH directories, which are bound with `--bind' after everything
else (see `harness-sandbox--scratch-mounts').

TMP is the directory the command's /tmp shows, writable, instead of the
empty tmpfs it has without one (see `harness-sandbox--tmp-directory',
which says which directories may be shown there); TMPDIR names /tmp
either way.  READ-ONLY and the locked profile keep the empty tmpfs: a
command that changes nothing, and one that must not see what the
session left behind, write only what they throw away.

CAPABILITIES, names of `harness-sandbox-capabilities', each get a
`--cap-add' after the flags that make the namespaces, and before the
command: bwrap drops every other capability.  This only builds the
command line, and is the last guard of it: a name the registry does not
know is left out, whatever it holds, and so is every one with READ-ONLY.
Whether the capability may be granted at all is for `sandbox/wrap'
\(`harness-sandbox--bwrap-capabilities').

PROFILE, when `locked', is the secret-file sandbox: no capability, a
minimal environment built from ENV (an alist of NAME . VALUE, which adds
to PATH, HOME, TMPDIR, LANG, TERM and HARNESS_SANDBOX; the harness's
own environment is cleared with `--clearenv'), and HIDE, paths bound to
`/dev/null' (a file) or covered by a tmpfs (a directory) after every
other mount so that nothing shows them.  For any other profile ENV adds
to the environment the command inherits, and HIDE still hides.

$HOME keeps its path: an empty tmpfs covers the home directory, so
~/x names the same path inside as outside and shows only what is
mounted there.  A home directory inside CWD is shown as it is; one no
tmpfs may cover (see `harness-sandbox--real-home') gives way to
`harness-sandbox--home', with the directories under the real one shown
under it too."
  (let* ((cwd (directory-file-name (expand-file-name cwd)))
         (inside (harness-sandbox--home-inside-p cwd))
         (real-home (and (not inside) (harness-sandbox--real-home)))
         (private (and (not inside) (not real-home) harness-sandbox--home))
         (locked (eq profile 'locked))
         ;; A command that changes nothing, and one that must not see
         ;; the session's scratch, keep a /tmp of their own.
         (tmp (and (not read-only) (not locked)
                   (harness-sandbox--tmp-directory tmp)))
         ;; Worked out once: the mounts show what the registrations of
         ;; the other worktrees must be kept from.
         (mounts (harness-sandbox--tmp-path-mounts
                  (harness-sandbox--mounts readable writable cwd (unless locked private))
                  tmp))
         (scratch-mounts (harness-sandbox--scratch-mounts scratch cwd))
         (registry (unless (or read-only locked)
                     (harness-sandbox--hidden-registrations
                      cwd (if tmp (append mounts (list (list 'rw tmp harness-sandbox--tmp)))
                            mounts)
                      scratch-mounts))))
    (append
     (list program
           "--ro-bind" "/usr" "/usr"
           "--ro-bind" "/etc" "/etc")
     (harness-sandbox--system-dir-args)
     (list "--proc" "/proc"
           "--dev" "/dev")
     (if tmp
         (list "--bind" tmp harness-sandbox--tmp)
       (list "--tmpfs" harness-sandbox--tmp))
     ;; The home directory after /tmp, which may hold it; binds after
     ;; both, so neither hides them.
     (cond (real-home (list "--tmpfs" real-home))
           (private (list "--dir" private)))
     (cl-loop for d in harness-sandbox-extra-read-only-dirs
              append (harness-sandbox--dir-args d 'ro))
     ;; The read-only binds before the others, and the working directory
     ;; last: a later mount covers what an earlier one shows below it, so
     ;; the working directory stays writable inside a read-only directory.
     (cl-loop for (mode source dest) in mounts
              append (list (if (and (eq mode 'rw) (not read-only)) "--bind" "--ro-bind") source dest))
     (list (if read-only "--ro-bind" "--bind") cwd cwd)
     (harness-sandbox--bwrap-git-args cwd read-only registry)
     ;; The scratch directories last, writable whatever holds them.
     (cl-loop for (source . dest) in scratch-mounts
              append (list "--bind" source dest))
     ;; The paths kept from the command, after every mount that could show them.
     (harness-sandbox--hide-args hide tmp)
     (list "--unshare-pid" "--unshare-ipc" "--unshare-uts"
           "--die-with-parent" "--new-session")
     ;; Only the registry's own names, none for a command that changes nothing.
     (unless read-only
       (cl-loop for name in (delete-dups (delq nil (mapcar #'harness-sandbox-capability-name capabilities)))
                append (list "--cap-add" name)))
     (list "--chdir" cwd)
     (if locked
         (append (list "--clearenv")
                 (cl-loop for (name . value) in (harness-sandbox--locked-env env)
                          append (list "--setenv" name value)))
       (append (list "--setenv" "HARNESS_SANDBOX" "bwrap")
               (and private (list "--setenv" "HOME" private))
               ;; The library and the shell go to /tmp without being
               ;; asked; what is asked is told the same, so that a
               ;; script honoring TMPDIR and one ignoring it agree.
               (list "--setenv" "TMPDIR" harness-sandbox--tmp)
               (cl-loop for (name . value) in env
                        append (list "--setenv" (format "%s" name) (format "%s" value)))))
     (unless network (list "--unshare-net"))
     (list "--")
     command)))

(cl-defun harness-sandbox--systemd-command (program cwd command &key (network t) writable readable read-only
                                                     scratch env hide tmp)
  "Build the systemd-run command line running COMMAND in CWD.
PROGRAM is the systemd-run executable; NETWORK, WRITABLE, READABLE,
READ-ONLY, SCRATCH, ENV and TMP are as for
`harness-sandbox--bwrap-command'.  HIDE lists paths made inaccessible
with `InaccessiblePaths=', after every mount that could show them, at
the path each is on this machine.
READ-ONLY binds CWD, the git directories and every WRITABLE entry with
`BindReadOnlyPaths=', sets no `ReadWritePaths=' but for the SCRATCH
directories, and makes the rest of the file system read-only with
`ProtectSystem=strict': unlike bwrap's, this sandbox shows the whole
file system, and only the user's own files are hidden
\(`ProtectHome=tmpfs'), so what it does not show it must still refuse
to write.  The SCRATCH directories are bound writable as CWD is when it
is, whatever READ-ONLY says; one whose path a setting cannot hold as
written signals an error.

TMP is bound at /tmp in place of the unit's own private one
\(`PrivateTmp=yes'), which a READ-ONLY command keeps; a path a setting
cannot hold as written keeps it too, with a line in the log, and
TMPDIR names /tmp either way.

Home directories are hidden with `ProtectHome=tmpfs' rather than
`ProtectHome=yes': with the latter systemd cannot mount anything
beneath /home, so a working directory in the user's home would be
unreachable (systemd-run fails with status 200).  That tmpfs is
read-only, so $HOME is /tmp, and the directories shown under the real
home directory are shown at the same place under it too, so ~/x
reaches them."
  (let* ((cwd (directory-file-name (expand-file-name cwd)))
         (tmp (and (not read-only) (harness-sandbox--tmp-directory tmp)))
         (tmp (if (and tmp (not (harness-sandbox--systemd-path-p tmp)))
                  (progn
                    (harness-log 'debug "sandbox: systemd cannot bind %s at /tmp; the unit keeps its own" tmp)
                    nil)
                tmp))
         (mounts (harness-sandbox--tmp-path-mounts
                  (harness-sandbox--mounts readable writable cwd
                                           (unless (harness-sandbox--home-inside-p cwd) "/tmp"))
                  tmp))
         (scratch-mounts (harness-sandbox--scratch-mounts scratch cwd))
         (registry (unless read-only
                     (harness-sandbox--hidden-registrations
                      cwd (if tmp (append mounts (list (list 'rw tmp harness-sandbox--tmp)))
                            mounts)
                      scratch-mounts))))
    (append
     (list program "--user" "--quiet" "--pipe" "--wait" "--collect"
           (concat "--working-directory=" cwd))
     (if tmp
         (list "-p" (concat "BindPaths=" tmp ":" harness-sandbox--tmp)
               "-p" (concat "ReadWritePaths=" harness-sandbox--tmp))
       (list "-p" "PrivateTmp=yes"))
     (list "-p" "ProtectHome=tmpfs")
     (if read-only
         (list "-p" "ProtectSystem=strict"
               "-p" (concat "BindReadOnlyPaths=" cwd))
       (list "-p" (concat "BindPaths=" cwd)
             "-p" (concat "ReadWritePaths=" cwd)))
     ;; systemd orders the mounts itself, a directory before what lies
     ;; in it.  A path its setting cannot hold as written is not shown.
     (cl-loop for (mode source dest) in mounts
              if (and (harness-sandbox--systemd-path-p source) (harness-sandbox--systemd-path-p dest))
              append (list "-p" (concat (if (and (eq mode 'rw) (not read-only)) "BindPaths=" "BindReadOnlyPaths=")
                                        source (if (equal source dest) "" (concat ":" dest))))
              else do (harness-log 'debug "sandbox: systemd cannot show %s at %s" source dest))
     (harness-sandbox--systemd-git-args cwd read-only registry)
     (cl-loop for (path . _directory) in (harness-sandbox--hide-paths hide tmp)
              when (harness-sandbox--systemd-path-p path)
              append (list "-p" (concat "InaccessiblePaths=" path)))
     (cl-loop for (source . dest) in scratch-mounts
              do (unless (and (harness-sandbox--systemd-path-p source) (harness-sandbox--systemd-path-p dest))
                   (error "Sandbox scratch directory %s cannot be written in a systemd setting" dest))
              append (list "-p" (concat "BindPaths=" source (if (equal source dest) "" (concat ":" dest)))
                           "-p" (concat "ReadWritePaths=" dest)))
     (unless network (list "-p" "PrivateNetwork=yes"))
     (unless (harness-sandbox--home-inside-p cwd)
       (list "--setenv=HOME=/tmp"))
     (list "--setenv=HARNESS_SANDBOX=systemd"
           ;; A script honoring TMPDIR and one going to /tmp without
           ;; asking write the same place.
           "--setenv=TMPDIR=/tmp")
     (cl-loop for (name . value) in env
              collect (format "--setenv=%s=%s" name value))
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

(defconst harness-sandbox--mxc-cocoa-home-variable "CFFIXED_USER_HOME"
  "The variable of MXC's environment that says where Cocoa looks for ~/Library.
Core Foundation reads it before it asks the system for the home
directory, so it moves only where a Cocoa program looks for ~/Library
\(its preferences, caches, color lists), and not $HOME, which every
other program reads.  The sandbox sets it to the command's private
temporary directory (see `harness-sandbox--mxc-command').")

(defun harness-sandbox--mxc-path (path)
  "Return the real path of PATH, as Seatbelt matches it, without a trailing slash."
  (directory-file-name (file-truename (expand-file-name path))))

(cl-defun harness-sandbox--mxc-command (program cwd command &key (network t) writable readable read-only tmp
                                                 scratch extra-env profile hide)
  "Build the MXC command line running COMMAND in CWD, on macOS.
PROGRAM is MXC's executor, mxc-exec-mac, given the whole description
of the command as base64-encoded JSON (`--config-base64').  NETWORK,
WRITABLE, READABLE and READ-ONLY are as for
`harness-sandbox--bwrap-command'.

PROFILE, when `locked', builds the environment from EXTRA-ENV (an
alist) and nothing of the harness's, denies the network, and refuses
when HIDE names a path the sandbox shows: MXC cannot hide a file inside
a directory it mounts.  TMP is the command's private
temporary directory, which `sandbox/wrap' makes: $TMPDIR names it, so
does the command's Cocoa home (see below), it is writable, and the
command line removes it when COMMAND ends.  The SCRATCH directories
are writable too, whatever READ-ONLY says (see
`harness-sandbox--scratch-mounts').

Seatbelt allows what it is told and denies the rest, on top of MXC's
baseline of read-only system directories.  Readable are
`harness-sandbox--mxc-system-dirs' and
`harness-sandbox-extra-read-only-dirs' that exist (unless a writable
directory holds one: as with bwrap, that one covers it) and the
READABLE directories; writable are CWD, the WRITABLE directories and
files, a worktree's git directory and TMP.  The git directory's
hooks, config, index and HEAD stay read-only, as with bwrap: the
deepest path given decides.  So do the registrations of the worktrees
the command is not shown (see \"The other worktrees\" above), in a
worktree's git directory and in a main checkout's.  Each path is given
at its real path (see
`harness-sandbox--mounts' for how the directories are found), since
Seatbelt matches the real one.  READ-ONLY makes every one of them
read-only but TMP, so that the command writes nothing else.

Nothing else is shown, the home directory's contents included: $HOME
keeps its path, and only what is shown under it can be read.

Cocoa programs ignore $HOME: they ask the system where ~/Library is,
and that is hidden too.  The NS build of Emacs aborts at startup on
that, in a --batch process as in any other: it loads its color list
from ~/Library/Colors and writes it back there when it is short, which
Seatbelt refuses, and AppKit raises an exception that nothing catches.
So the command's Cocoa home, CFFIXED_USER_HOME, is TMP: empty,
writable and its own, where such a program finds nothing and makes
what it needs, and what it makes goes with TMP.  The variable moves
only where Cocoa looks for ~/Library, never $HOME, and it replaces one
of the harness's own, which would name a directory the command is not
shown.

NETWORK nil denies all network access; otherwise the host's network,
loopback included, is open both ways, as bwrap leaves it.  The command
gets exactly the environment `process-environment' holds now (one
given to the process later does not reach it), with TMPDIR,
CFFIXED_USER_HOME, PWD, HARNESS_SANDBOX=mxc and a worktree's commit
identity set.  MXC sets it no timeout: the harness kills the process
tree itself, and finds the command in it by its parent processes.

This only reads the file system: it writes nothing, TMP included."
  (let* ((cwd (directory-file-name (expand-file-name cwd)))
         (locked (eq profile 'locked))
         (tmp (and tmp (harness-sandbox--mxc-path tmp)))
         (mounts (harness-sandbox--mounts readable writable cwd nil))
         (scratch-mounts (harness-sandbox--scratch-mounts scratch cwd))
         (sources (lambda (mode)
                    (cl-loop for (m source) in mounts when (eq m mode) collect source)))
         (git (harness-sandbox--worktree-git cwd))
         (common (and git (harness-sandbox--mxc-path (plist-get git :common))))
         ;; Read-only inside the writable git directory; with READ-ONLY
         ;; the whole of it is, as with bwrap.  So are the registrations
         ;; of the worktrees the command is not shown, whether the git
         ;; directory is a worktree's or the main checkout's.
         (protected (and (not read-only)
                         (append
                          (and git (mapcar #'harness-sandbox--mxc-path (plist-get git :protected)))
                          (mapcar (lambda (r) (harness-sandbox--mxc-path (car r)))
                                  (harness-sandbox--hidden-registrations cwd mounts scratch-mounts)))))
         (shown (delete-dups (delq nil (append (list (harness-sandbox--mxc-path cwd))
                                               (funcall sources 'rw)
                                               (list common)))))
         (rw (cl-remove-if (lambda (path) (member path protected))
                           (delq nil (append (unless read-only shown) (list tmp)
                                             (mapcar (lambda (m) (harness-sandbox--mxc-path (car m)))
                                                     scratch-mounts)))))
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
         (env (if locked
                  (append (list (concat "PATH=" (or (getenv "PATH")
                                                    "/usr/local/bin:/usr/bin:/bin"))
                                (concat "HOME=" (file-name-as-directory (or tmp "/tmp")))
                                (concat "TMPDIR=" (file-name-as-directory (or tmp "/tmp")))
                                (concat "PWD=" cwd)
                                "HARNESS_SANDBOX=mxc")
                          (cl-loop for name in '("LANG" "TERM")
                                   for value = (getenv name)
                                   when value collect (concat name "=" value))
                          (cl-loop for (name . value) in extra-env
                                   when (and (stringp name) (stringp value))
                                   collect (concat name "=" value)))
                (harness-sandbox--mxc-env
                 (append (and tmp (list (cons "TMPDIR" (file-name-as-directory tmp))
                                        ;; Cocoa's home, which is TMP too (see
                                        ;; `harness-sandbox--mxc-cocoa-home-variable').
                                        (cons harness-sandbox--mxc-cocoa-home-variable tmp)))
                         ;; As Emacs sets it for a process it starts itself.
                         (list (cons "PWD" cwd)
                               (cons "HARNESS_SANDBOX" "mxc"))
                         (and git (harness-sandbox--git-env (plist-get git :common)))
                         extra-env))))
         (net (if (and network (not locked)) "allow" "deny"))
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
    (dolist (path hide)
      (let* ((named (and (stringp path) (not (file-remote-p path))
                         (expand-file-name path)))
             (real (and named (file-exists-p named)
                        (directory-file-name (file-truename named)))))
        (when (and real
                   (cl-some (lambda (shown) (harness-path-within-p shown real))
                            (delete-dups (append rw ro))))
          (signal 'harness-sandbox-unavailable
                  (list (format "MXC cannot hide %s: it lies under a directory the sandbox shows"
                                real))))))
    (list program "--config-base64"
          ;; Bytes: Emacs 29's `json-serialize' still gives text.
          (base64-encode-string (if (multibyte-string-p json) (encode-coding-string json 'utf-8-unix) json)
                                t))))

;;;; OpenShell

;; NVIDIA OpenShell is driven through its command line, which talks to a
;; gateway.  A command is three calls of it, run by a small bash script
;; (`harness-sandbox--openshell-script') this module hands back as the
;; command line: `sandbox create --detach --no-keep' makes a sandbox
;; from a policy file and the bind mounts of the directories the command
;; may reach, `sandbox exec' runs the command in it -- and only that
;; writes to the script's standard output and standard error, which
;; `sandbox create' would fill with its progress lines -- and `sandbox
;; delete' removes the sandbox, in the background and out of the process
;; group the harness kills on a timeout, so that a command killed for
;; running too long loses its sandbox too.  A sandbox the script could
;; not delete ends by itself: its main process is a `sleep' of
;; `harness-sandbox--openshell-ttl' seconds, after which OpenShell
;; deletes an ephemeral sandbox.
;;
;; What OpenShell is told is a description of the command, as MXC's is:
;; `harness-sandbox--openshell-spec' makes it, from the same directories
;; bwrap's arguments are made from, and three functions put it where
;; OpenShell reads it -- the policy file (`filesystem_policy' for
;; Landlock, `process', `network_policies'), the driver config (the bind
;; mounts) and the environment of the command.

(defconst harness-sandbox--openshell-script
  (mapconcat
   #'identity
   '("prog=$1 name=$2 nc=$3"
     "shift 3"
     "create=(\"${@:1:$nc}\")"
     "shift \"$nc\""
     ;; The sandbox goes in the background and in a session of its own,
     ;; or the kill of the command's process group takes the delete too.
     ;; From /, not the command's directory: whoever ran the command may
     ;; remove that the moment this script ends, before the delete starts.
     "drop() {"
     "  if command -v setsid >/dev/null 2>&1; then"
     "    (cd / && exec setsid \"$prog\" sandbox delete \"$name\") </dev/null >/dev/null 2>&1 &"
     "  else"
     "    (cd / && trap '' HUP INT TERM && exec \"$prog\" sandbox delete \"$name\") </dev/null >/dev/null 2>&1 &"
     "  fi"
     "}"
     "trap 'drop; exit 143' HUP INT TERM"
     ;; Its progress lines are not the command's output.
     "made=$(\"$prog\" sandbox create --name \"$name\" \"${create[@]}\" </dev/null 2>&1)"
     "status=$?"
     "if [ \"$status\" -ne 0 ]; then"
     "  drop"
     "  { echo \"harness-sandbox: OpenShell could not start a sandbox for this command (openshell exited $status):\""
     "    printf '%s\\n' \"$made\" | tail -n 40; } >&2"
     "  exit 125"
     "fi"
     "\"$prog\" sandbox exec -n \"$name\" \"$@\""
     "status=$?"
     "drop"
     "exit \"$status\"")
   "\n")
  "The bash script that runs a command in a sandbox made for it alone.
Its arguments are the openshell program, the sandbox's name, the
number of the arguments of `sandbox create' that follow, those, and
then the arguments of `sandbox exec' after its `-n NAME'.  It runs
openshell as the harness's own environment has it, so the gateway is
the active one, or that of $OPENSHELL_GATEWAY.  Its status is the
command's, or 125 when no sandbox could be made, 143 when it was told
to stop.")

(defconst harness-sandbox--openshell-flags
  '((("sandbox" "create") "--detach" "--no-keep" "--no-tty" "--no-auto-providers" "--policy"
     "--from" "--label" "--driver-config-json")
    (("sandbox" "exec") "--name" "--workdir" "--env" "--no-tty" "--no-login-shell")
    (("sandbox" "delete")))
  "The commands of openshell this module runs, with the options of each.
`harness-sandbox--openshell-cli-problem' reads the help of each for
them: a program without one is too old.")

(defconst harness-sandbox--openshell-control-roots
  '("/opt/openshell" "/etc/openshell" "/etc/openshell-tls" "/run/openshell"
    "/run/openshell-sidecar" "/run/netns" "/var/run/netns" "/proc" "/sys" "/dev")
  "Paths of a sandbox that OpenShell keeps for itself.
The gateway refuses a bind mount whose target is, holds or lies in one
of them.")

(defconst harness-sandbox--openshell-image-roots '("/usr" "/lib" "/lib64" "/bin" "/sbin")
  "System directories of the sandbox image, which no mount may replace.
A mount of this machine's /usr over the image's would swap its system
for one the image's own programs were not made for.  A mount below one,
such as /usr/local/cuda, is fine.")

(defconst harness-sandbox--openshell-max-argument 32768
  "The longest argument, in bytes, the gateway runs a command with.")

(defconst harness-sandbox--openshell-max-paths 256
  "The most paths a policy's `filesystem_policy' may list.
Read-only and read-write ones together.")

(defvar harness-sandbox--openshell-reported nil
  "Entries of the OpenShell options reported as unusable, so each is reported once.")

(defun harness-sandbox--openshell-find ()
  "Return the absolute path of the openshell program, or nil."
  (let ((program harness-sandbox-openshell-program))
    (and (stringp program) (not (string-empty-p program))
         ;; An absolute path, or one from ~, is found as it is.
         (executable-find (if (file-name-directory program)
                              (expand-file-name program)
                            program)))))

(defun harness-sandbox--first-lines (text &optional n)
  "Return the first N (3 by default) non-blank lines of TEXT, joined by spaces."
  (string-join (seq-take (split-string (or text "") "[\n\r]+" t "[ \t]+") (or n 3)) " "))

(defun harness-sandbox--run-sync (program args timeout)
  "Run PROGRAM with ARGS, waiting at most TIMEOUT seconds; return (STATUS OUT ERR).
STATUS is its exit status, OUT what it wrote to standard output and ERR to
standard error.  It is nil when PROGRAM could not start or did not end in
time, and ERR then says why.  Its standard input is closed."
  (let ((out (generate-new-buffer " *harness-sandbox-out*" t))
        (err (generate-new-buffer " *harness-sandbox-err*" t))
        proc)
    (unwind-protect
        (condition-case failure
            (progn
              (setq proc (make-process :name "harness-sandbox-run" :command (cons program args)
                                       :buffer out :stderr err :connection-type 'pipe
                                       :noquery t :coding 'utf-8-unix :sentinel #'ignore))
              (when-let* ((stderr-proc (get-buffer-process err)))
                (set-process-query-on-exit-flag stderr-proc nil)
                (set-process-sentinel stderr-proc #'ignore))
              (process-send-eof proc)
              (let ((deadline (+ (float-time) timeout)))
                (while (and (process-live-p proc) (< (float-time) deadline))
                  (accept-process-output proc 0.05)))
              (if (process-live-p proc)
                  (progn (delete-process proc)
                         (list nil "" (format "did not answer within %s seconds" timeout)))
                ;; What it wrote last may not have been read yet.
                (accept-process-output proc 0.05)
                (when-let* ((stderr-proc (get-buffer-process err)))
                  (accept-process-output stderr-proc 0.05))
                (list (process-exit-status proc)
                      (with-current-buffer out (buffer-string))
                      (with-current-buffer err (buffer-string)))))
          (error (list nil "" (error-message-string failure))))
      (when (and proc (process-live-p proc)) (delete-process proc))
      (when-let* ((stderr-proc (get-buffer-process err))) (delete-process stderr-proc))
      (kill-buffer out)
      (kill-buffer err))))

(defun harness-sandbox--openshell-config-problem ()
  "Return what is wrong with the OpenShell options, as text, or nil.
They are read from their global values only."
  (let ((image (default-value 'harness-sandbox-openshell-image))
        (driver (default-value 'harness-sandbox-openshell-driver))
        (paths (default-value 'harness-sandbox-openshell-image-paths))
        (extra (default-value 'harness-sandbox-openshell-extra-args)))
    (cond
     ((and image (not (and (stringp image)
                           (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9._/:@+-]*\\'" image))))
      (format "harness-sandbox-openshell-image %S is no image reference" image))
     ((not (memq driver '(docker podman)))
      (format "harness-sandbox-openshell-driver %S is neither docker nor podman" driver))
     ((not (and (proper-list-p paths)
                (cl-every (lambda (path) (and (stringp path) (string-prefix-p "/" path)
                                              (not (equal (directory-file-name path) "/"))
                                              (not (string-match-p "[[:cntrl:]]" path))))
                          paths)))
      "harness-sandbox-openshell-image-paths is no list of absolute paths, the root directory apart")
     ((not (and (proper-list-p extra)
                (cl-every (lambda (arg) (and (stringp arg) (not (string-search "\0" arg)))) extra)))
      "harness-sandbox-openshell-extra-args is no list of strings"))))

(defun harness-sandbox--openshell-cli-problem (program)
  "Return why the openshell PROGRAM is too old for this module, or nil.
It reads the help of each command the module runs
\(`harness-sandbox--openshell-flags') for the options it passes."
  (cl-loop for (command . flags) in harness-sandbox--openshell-flags
           for result = (harness-sandbox--run-sync
                         program (append command '("--help"))
                         harness-sandbox--openshell-probe-timeout)
           for help = (concat (nth 1 result) (nth 2 result))
           thereis (cond
                    ((not (eql 0 (car result)))
                     (format "`openshell %s --help' failed: %s" (string-join command " ")
                             (harness-sandbox--first-lines (or (nth 2 result) help))))
                    (t (when-let* ((missing (cl-find-if-not (lambda (flag) (string-search flag help)) flags)))
                         (format "this openshell is too old: `openshell %s' has no %s (the harness was written for OpenShell 0.1.5)"
                                 (string-join command " ") missing))))))

(defun harness-sandbox--openshell-gateway-problem (program)
  "Return why `openshell status' of PROGRAM shows no usable gateway, or nil."
  (let* ((result (harness-sandbox--run-sync
                  program '("status" "-o" "json") harness-sandbox--openshell-probe-timeout))
         (json (and (eql 0 (car result))
                    (condition-case nil
                        (with-temp-buffer
                          (insert (nth 1 result))
                          (goto-char (point-min))
                          (and (search-forward "{" nil t)
                               (progn (backward-char) (harness-json-parse-buffer))))
                      (error nil))))
         (status (and (listp json) (plist-get json :status)))
         (auth (and (listp json) (plist-get json :authentication))))
    (cond
     ((null (car result))
      (format "`openshell status' %s" (nth 2 result)))
     ((not (eql 0 (car result)))
      (format "`openshell status' failed (exit %s): %s" (car result)
              (harness-sandbox--first-lines (concat (nth 2 result) " " (nth 1 result)))))
     ((equal status "connected")
      (when (equal (and (listp auth) (plist-get auth :status)) "failed")
        (format "the gateway %s does not accept this user: %s"
                (or (plist-get json :gateway) "") (or (plist-get auth :error) "no reason given"))))
     ((equal status "not_configured")
      "no OpenShell gateway is registered (see `openshell gateway add' and `openshell gateway select')")
     ((member status '("disconnected" "error" "connected_http"))
      (format "the gateway %s at %s does not answer%s"
              (or (plist-get json :gateway) "") (or (plist-get json :server) "")
              (if-let* ((why (plist-get json :error))) (format ": %s" why) "")))
     (t (format "`openshell status' gave an answer the harness does not understand: %s"
                (harness-sandbox--first-lines (nth 1 result)))))))

(defun harness-sandbox--openshell-problem (&optional program)
  "Return why OpenShell cannot run commands, as text, or nil when it can.
PROGRAM is the openshell executable, found by default.  It checks the
program, the options, that its command line has what this module
passes, and that `openshell status' reaches a gateway; it starts no
sandbox (`harness-sandbox-openshell-check' does)."
  (let ((program (or program (harness-sandbox--openshell-find))))
    (cond
     ((null program)
      (format "the program %s (harness-sandbox-openshell-program) is not installed or not on the exec path"
              harness-sandbox-openshell-program))
     ((harness-sandbox--openshell-config-problem))
     ((harness-sandbox--openshell-cli-problem program))
     (t (harness-sandbox--openshell-gateway-problem program)))))

;;;;; The network rules

(defun harness-sandbox--openshell-parse-endpoint (endpoint)
  "Return (HOST PORT…) for the ENDPOINT \"HOST:PORT[,PORT…]\", or nil."
  (when (and (stringp endpoint)
             (string-match "\\`\\([A-Za-z0-9*.-]+\\):\\([0-9]+\\(?:,[0-9]+\\)*\\)\\'" endpoint))
    ;; Both groups first: `split-string' searches, and so changes them.
    (let* ((host (match-string 1 endpoint))
           (ports (mapcar #'string-to-number (split-string (match-string 2 endpoint) ","))))
      (when (cl-every (lambda (port) (<= 1 port 65535)) ports)
        (cons host ports)))))

(defun harness-sandbox--openshell-skip (entry why)
  "Log once that ENTRY of the OpenShell network rules is left out, for WHY."
  (unless (member entry harness-sandbox--openshell-reported)
    (push entry harness-sandbox--openshell-reported)
    (harness-log 'warn "sandbox: %S in harness-sandbox-openshell-network-rules is left out: %s" entry why)))

(defun harness-sandbox--openshell-rules ()
  "Return the network rules the option names that are well formed.
Each is (NAME ENDPOINTS BINARIES): NAME the rule's key in the policy,
ENDPOINTS lists of (HOST PORT…) and BINARIES path globs.  The plain
endpoints of the option make one rule, any program may use.  An entry
that is neither is left out, with a line in the log."
  (let ((value (default-value 'harness-sandbox-openshell-network-rules))
        plain rules)
    (dolist (entry (and (proper-list-p value) value))
      (cond
       ((stringp entry)
        (if-let* ((endpoint (harness-sandbox--openshell-parse-endpoint entry)))
            (push endpoint plain)
          (harness-sandbox--openshell-skip entry "it is no HOST:PORT")))
       ((and (consp entry) (or (stringp (car entry)) (and (car entry) (symbolp (car entry))))
             (proper-list-p (cdr entry)))
        (let* ((name (format "%s" (car entry)))
               (endpoints (mapcar #'harness-sandbox--openshell-parse-endpoint
                                  (let ((list (plist-get (cdr entry) :endpoints)))
                                    (and (proper-list-p list) list))))
               (binaries (if (plist-member (cdr entry) :binaries)
                             (plist-get (cdr entry) :binaries)
                           '("/**"))))
          (cond
           ((not (string-match-p "\\`[A-Za-z][A-Za-z0-9_-]*\\'" name))
            (harness-sandbox--openshell-skip entry "its name is no plain word"))
           ((string-prefix-p "_provider_" name)
            (harness-sandbox--openshell-skip entry "OpenShell keeps names with _provider_ for itself"))
           ((or (null endpoints) (memq nil endpoints))
            (harness-sandbox--openshell-skip entry "it has no endpoints, or one that is no HOST:PORT"))
           ((not (and binaries (proper-list-p binaries)
                      (cl-every (lambda (path)
                                  (and (stringp path)
                                       (string-match-p "\\`/[A-Za-z0-9_./*?@+,=-]*\\'" path)))
                                binaries)))
            (harness-sandbox--openshell-skip entry "its :binaries are no absolute path globs"))
           (t (push (list name endpoints binaries) rules)))))
       (t (harness-sandbox--openshell-skip entry "it is neither an endpoint nor a rule"))))
    (append (and plain (list (list "harness_endpoints" (nreverse plain) '("/**"))))
            (nreverse rules))))

(defun harness-sandbox--openshell-hosts ()
  "Return the endpoints of the network rules, as \"HOST:PORT[,PORT…]\" strings."
  (cl-loop for (_name endpoints _binaries) in (harness-sandbox--openshell-rules)
           append (mapcar (lambda (endpoint)
                            (format "%s:%s" (car endpoint)
                                    (mapconcat #'number-to-string (cdr endpoint) ",")))
                          endpoints)))

;;;;; What the sandbox shows

(defun harness-sandbox--openshell-target-problem (target)
  "Return why the gateway would refuse TARGET as a mount's target, or nil."
  (cond
   ((not (and (stringp target) (string-prefix-p "/" target)
              (not (string-match-p "[[:cntrl:]]" target))
              (not (string-match-p "\\(?:\\`\\|/\\)\\.\\.?\\(?:/\\|\\'\\)\\|//" target))))
    "it is no normalized absolute path")
   ((equal target "/") "it is the root directory")
   ((cl-find-if (lambda (root)
                  (or (harness-path-within-p root target) (harness-path-within-p target root)))
                harness-sandbox--openshell-control-roots)
    "OpenShell keeps it, or what is in it, for itself")
   ((cl-find-if (lambda (root) (harness-path-within-p target root))
                harness-sandbox--openshell-image-roots)
    "it would replace the sandbox image's own system directory")))

(defun harness-sandbox--openshell-mounts (cwd readable writable read-only scratch)
  "Return the mounts of the sandbox of a command in CWD.
They are lists (TARGET SOURCE MODE).  MODE is `ro' or `rw' for a bind
mount of SOURCE, and `tmpfs' (SOURCE nil) for the sandbox's $HOME,
which is a tmpfs: bwrap's covers the home
directory, and the directories of the real home show under it
\(`harness-sandbox--mounts').  READABLE, WRITABLE, READ-ONLY and SCRATCH
are as for `harness-sandbox--bwrap-command', which this follows: those,
then CWD, a worktree's git directory and the scratch directories, a
later mount of a target taking the place of an earlier one.  With
READ-ONLY every bind mount is read-only but the scratch directories'.
`harness-sandbox-extra-read-only-dirs' is not shown: it names
directories of this machine's toolchains, which the image has no use for.
A target the gateway would refuse is left out, with a line in the log."
  (let* ((cwd (directory-file-name (expand-file-name cwd)))
         (real-cwd (directory-file-name (file-truename cwd)))
         (private (and (not (harness-sandbox--home-inside-p cwd)) harness-sandbox--home))
         (git (harness-sandbox--worktree-git cwd))
         mounts)
    (cl-flet ((add (target source mode)
                (let ((target (and (stringp target) (directory-file-name target))))
                  (if-let* ((why (harness-sandbox--openshell-target-problem target)))
                      (harness-log 'warn "sandbox: not showing %s to OpenShell: %s" target why)
                    (if-let* ((old (assoc target mounts)))
                        (setcdr old (list source mode))
                      (push (list target source mode) mounts))))))
      (pcase-dolist (`(,mode ,source ,target)
                     (harness-sandbox--mounts readable writable cwd private))
        (add target source (if (and (eq mode 'rw) (not read-only)) 'rw 'ro)))
      (dolist (target (delete-dups (list cwd real-cwd)))
        (add target real-cwd (if read-only 'ro 'rw)))
      (when git
        (let ((common (directory-file-name (plist-get git :common))))
          (add common (directory-file-name (file-truename common)) (if read-only 'ro 'rw))
          (unless read-only
            (dolist (path (plist-get git :protected))
              (add path (directory-file-name (file-truename path)) 'ro)))))
      (pcase-dolist (`(,source . ,target) (harness-sandbox--scratch-mounts scratch cwd))
        (add target source 'rw))
      (when private
        (add private nil 'tmpfs)))
    (nreverse mounts)))

(cl-defun harness-sandbox--openshell-spec (cwd &key (network t) writable readable read-only scratch env)
  "Describe the sandbox of a command in CWD, as a plist.
NETWORK, WRITABLE, READABLE, READ-ONLY, SCRATCH and ENV are as for
`harness-sandbox--bwrap-command'.  The plist is `:cwd', `:mounts'
\(`harness-sandbox--openshell-mounts'), the paths Landlock allows,
`:read-only' and `:read-write', the network rules of the policy
`:rules' (those of `harness-sandbox-openshell-network-rules' when
NETWORK, else none: a session without the network gets none), and the
`:env' of the command as (NAME . VALUE) pairs, ENV after the ones the
spec sets, so it wins over them."
  (let* ((cwd (directory-file-name (expand-file-name cwd)))
         (mounts (harness-sandbox--openshell-mounts cwd readable writable read-only scratch))
         (system harness-sandbox--openshell-system-paths)
         (image-paths (mapcar #'directory-file-name
                              (default-value 'harness-sandbox-openshell-image-paths)))
         (git (harness-sandbox--worktree-git cwd))
         (home (cl-find 'tmpfs mounts :key #'caddr))
         (paths (lambda (modes)
                  (cl-loop for (target _source mode) in mounts
                           when (memq mode modes) collect target)))
         (shown-ro (funcall paths '(ro)))
         (shown-rw (funcall paths '(rw tmpfs)))
         ;; A directory the session shows decides over the system path it is.
         (system-ro (cl-remove-if (lambda (path) (member path shown-rw))
                                  (append (plist-get system :read-only) image-paths)))
         (system-rw (cl-remove-if (lambda (path) (member path shown-ro)) (plist-get system :read-write))))
    (list :cwd cwd
          :mounts mounts
          :read-only (delete-dups (append system-ro shown-ro))
          :read-write (delete "/" (delete-dups (append system-rw shown-rw)))
          :rules (and network (harness-sandbox--openshell-rules))
          :env (append (list (cons "HARNESS_SANDBOX" "openshell")
                             (cons "HOME" (if home (car home) (or (getenv "HOME") harness-sandbox--home))))
                       (and git (harness-sandbox--git-env (plist-get git :common)))
                       ;; The command's language and time zone are its user's.
                       (cl-loop for name in '("LANG" "LANGUAGE" "LC_ALL" "TZ")
                                for value = (getenv name)
                                when (and value (not (string-empty-p value))) collect (cons name value))
                       env))))

(defun harness-sandbox--yaml-string (value)
  "Return the string VALUE as a double-quoted YAML scalar."
  (concat "\""
          (replace-regexp-in-string
           "[\"\\[:cntrl:]]"
           (lambda (c)
             (pcase (aref c 0)
               (?\" "\\\"") (?\\ "\\\\") (?\n "\\n") (?\t "\\t") (?\r "\\r")
               (ch (format "\\x%02X" ch))))
           value t t)
          "\""))

(defun harness-sandbox--openshell-policy-text (spec)
  "Return the OpenShell policy file, YAML, for the sandbox SPEC describes.
Landlock gets the directories and system paths of the spec, and must
enforce them (`hard_requirement': a sandbox that cannot is not started,
rather than run without the rules); the process runs as the host
user's uid and gid (`harness-sandbox--openshell-run-as-host-user'), and
`network_policies' hold the rules of the spec, none for a command that
is offline.  Everything OpenShell does not list is refused."
  (let ((q #'harness-sandbox--yaml-string)
        (uid (user-uid))
        (gid (group-gid)))
    (with-temp-buffer
      (insert "# Written by the Emacs agent harness for `openshell sandbox create --policy'.\n"
              "# Each command gets the policy of its own directories; nothing to edit here.\n"
              "version: 1\n"
              "filesystem_policy:\n"
              "  include_workdir: false\n"
              "  read_only:\n")
      (dolist (path (plist-get spec :read-only)) (insert "    - " (funcall q path) "\n"))
      (insert "  read_write:\n")
      (dolist (path (plist-get spec :read-write)) (insert "    - " (funcall q path) "\n"))
      (insert "landlock:\n"
              "  compatibility: hard_requirement\n")
      (when (and harness-sandbox--openshell-run-as-host-user
                 (integerp uid) (> uid 0) (integerp gid) (> gid 0))
        (insert "process:\n"
                (format "  run_as_user: \"%d\"\n  run_as_group: \"%d\"\n" uid gid)))
      (when-let* ((rules (plist-get spec :rules)))
        (insert "network_policies:\n")
        (pcase-dolist (`(,name ,endpoints ,binaries) rules)
          (insert "  " name ":\n    endpoints:\n")
          (pcase-dolist (`(,host . ,ports) endpoints)
            (insert "      - host: " (funcall q host) "\n")
            (if (cdr ports)
                (insert "        ports: [" (mapconcat #'number-to-string ports ", ") "]\n")
              (insert (format "        port: %d\n" (car ports)))))
          (insert "    binaries:\n")
          (dolist (path binaries) (insert "      - path: " (funcall q path) "\n"))))
      (buffer-string))))

(defun harness-sandbox--openshell-driver-config (spec)
  "Return the `--driver-config-json' of the sandbox SPEC describes, or nil.
It carries the bind mounts, under the key of the gateway's driver
\(`harness-sandbox-openshell-driver'), and the tmpfs that is $HOME."
  (when-let* ((mounts (plist-get spec :mounts)))
    (harness-json-encode-text
     (list (intern (concat ":" (symbol-name (default-value 'harness-sandbox-openshell-driver))))
           (list :mounts
                 (harness-json-array
                  (mapcar (lambda (mount)
                            (pcase-let ((`(,target ,source ,mode) mount))
                              (if (eq mode 'tmpfs)
                                  ;; Writable by the command, whoever it runs as.
                                  (list :type "tmpfs" :target target :mode 511)
                                (list :type "bind" :source source :target target
                                      :read_only (if (eq mode 'ro) t :false)))))
                          mounts)))))))

(defun harness-sandbox--openshell-policy-file (text)
  "Return the path of a file holding the policy TEXT, written if it is not there.
The files are named for what is in them and kept in the harness's state
directory, where only this user writes; one that is there is used again
only when it holds exactly TEXT.  A file older than a week is deleted."
  (let* ((dir (expand-file-name "openshell/" harness-state-directory))
         (file (expand-file-name (format "policy-%s.yaml" (substring (secure-hash 'sha256 (encode-coding-string text 'utf-8-unix)) 0 24))
                                 dir)))
    (condition-case err
        (progn
          (unless (and (file-regular-p file)
                       (not (file-symlink-p file))
                       (equal text (with-temp-buffer
                                     (let ((coding-system-for-read 'utf-8-unix))
                                       (insert-file-contents file))
                                     (buffer-string))))
            (with-file-modes #o700 (make-directory dir t))
            (let ((tmp (make-temp-file (expand-file-name "policy-" dir) nil ".tmp"))
                  (coding-system-for-write 'utf-8-unix))
              (write-region text nil tmp nil 'silent)
              (set-file-modes tmp #o600)
              (rename-file tmp file t))
            (dolist (old (directory-files dir t "\\`policy-.*\\.yaml\\'"))
              (when (and (not (equal old file))
                         (time-less-p (file-attribute-modification-time (file-attributes old))
                                      (time-subtract nil (* 7 24 60 60))))
                (ignore-errors (delete-file old)))))
          file)
      (file-error
       (signal 'harness-sandbox-unavailable
               (list (format "OpenShell needs a policy file it cannot write in %s: %s" dir
                             (error-message-string err))))))))

(defun harness-sandbox--openshell-exec-error (word why)
  "Signal `harness-sandbox-unavailable': the command WORD cannot go to OpenShell.
WHY says what stands in the way."
  (harness-log 'error "sandbox: OpenShell cannot run %S: %s" word why)
  (signal 'harness-sandbox-unavailable
          (list (format "OpenShell cannot run this command: %s" why))))

(cl-defun harness-sandbox--openshell-command (program cwd command &key (network t) writable readable
                                                     read-only scratch env)
  "Build the command line running COMMAND in CWD in an OpenShell sandbox.
PROGRAM is the openshell executable; NETWORK, WRITABLE, READABLE,
READ-ONLY, SCRATCH and ENV are as for `harness-sandbox--bwrap-command'.
The line is bash running `harness-sandbox--openshell-script' with a
name for the sandbox, the options of its creation -- the policy file of
`harness-sandbox--openshell-policy-text', the mounts of
`harness-sandbox--openshell-driver-config' -- and the options of the
command's `sandbox exec': its directory and its environment, which is
the sandbox's own besides what the spec sets.  Signals
`harness-sandbox-unavailable' when an OpenShell option is unusable, or
a word of COMMAND is longer than the gateway runs.  It writes the
policy file, and nothing else."
  (when-let* ((problem (harness-sandbox--openshell-config-problem)))
    (harness-sandbox--openshell-exec-error (car command) problem))
  (dolist (word command)
    (when (> (string-bytes word) harness-sandbox--openshell-max-argument)
      (harness-sandbox--openshell-exec-error
       (car command)
       (format "an argument of %d bytes is longer than the %d bytes the gateway runs a command with; put it in a file and run that"
               (string-bytes word) harness-sandbox--openshell-max-argument))))
  (let* ((cwd (directory-file-name (expand-file-name cwd)))
         (spec (harness-sandbox--openshell-spec cwd :network network :writable writable
                                                :readable readable :read-only read-only
                                                :scratch scratch :env env))
         (listed (+ (length (plist-get spec :read-only)) (length (plist-get spec :read-write))))
         (policy (progn
                   (when (> listed harness-sandbox--openshell-max-paths)
                     (harness-sandbox--openshell-exec-error
                      (car command)
                      (format "its policy would list %d paths, and OpenShell takes at most %d: give some directories up"
                              listed harness-sandbox--openshell-max-paths)))
                   (harness-sandbox--openshell-policy-file (harness-sandbox--openshell-policy-text spec))))
         (config (harness-sandbox--openshell-driver-config spec))
         (image (default-value 'harness-sandbox-openshell-image))
         (create (append (list "--detach" "--no-keep" "--no-tty" "--no-auto-providers"
                               "--label" "harness=emacs-agent-harness"
                               "--policy" policy)
                         (and image (list "--from" image))
                         (and config (list "--driver-config-json" config))
                         (default-value 'harness-sandbox-openshell-extra-args)
                         (list "--" "sleep" (number-to-string harness-sandbox--openshell-ttl))))
         (exec (append (list "--no-tty" "--no-login-shell" "--workdir" cwd)
                       (cl-loop for (name . value) in (plist-get spec :env)
                                if (and (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*\\'" name)
                                        (not (string-prefix-p "OPENSHELL_" name))
                                        (not (string-match-p "[\n\r\0]" value))
                                        (<= (string-bytes value) harness-sandbox--openshell-max-argument))
                                append (list "--env" (concat name "=" value))
                                else do (harness-log 'debug "sandbox: OpenShell cannot pass %s on" name))
                       (list "--")
                       command)))
    (append (list (or (executable-find "bash") "/bin/bash") "-c" harness-sandbox--openshell-script
                  "harness-openshell" program
                  (format "harness-%d-%s" (emacs-pid) (harness-short-id 8))
                  (number-to-string (length create)))
            create exec)))

;;;;; What the backend cannot do

(defun harness-sandbox--openshell-limits ()
  "Return what OpenShell cannot do of the harness's access model, as lines of text."
  (let ((hosts (harness-sandbox--openshell-hosts))
        (image (default-value 'harness-sandbox-openshell-image)))
    (list
     "No Linux capability can be given: OpenShell runs commands as a non-root user with none."
     (if hosts
         (format "The network is never open: a command with it on reaches only %s (harness-sandbox-openshell-network-rules); with it off, nothing."
                 (string-join hosts ", "))
       "The network is never open: OpenShell refuses every connection no rule allows, and harness-sandbox-openshell-network-rules lists none, so commands are offline even where the session's network is on.")
     (format "Commands run in %s, with its own /usr, not this machine's: the tools they run, git and Emacs for the elisp tool among them, must be in it."
             (if image (format "the image %s" image) "the gateway's default image"))
     "Every command starts a sandbox of its own, which takes a moment."
     (format "No argument of a command may be longer than %d bytes." harness-sandbox--openshell-max-argument)
     "Directories show as bind mounts, which the gateway must allow (allow_driver_config and enable_bind_mounts).")))

(defun harness-sandbox--limits (backend)
  "Return what the sandbox BACKEND cannot do of the access model, as lines of text.
Nil for a backend that gives it whole."
  (pcase backend
    ('openshell (harness-sandbox--openshell-limits))
    ('systemd '("No Linux capability can be given: a systemd --user unit can only lower its own."))
    ('mxc '("No Linux capability can be given: Seatbelt has none."
            "No PID namespace of its own, and /tmp cannot be written (a command uses $TMPDIR)."))
    (_ nil)))

;;;###autoload
(defun harness-sandbox-openshell-check ()
  "Run a command in a throwaway OpenShell sandbox and say whether that worked.
It goes the way every command does, with the working directory a
directory of its own, so it finds what `harness-sandbox-detect' does not
look for: a gateway that refuses the bind mounts, an image that lacks bash
or sleep, a kernel without Landlock.  Return a promise of (:ok BOOL
:message TEXT); called interactively it shows the message too."
  (interactive)
  (let* ((program (or (harness-sandbox--openshell-find)
                      (user-error "The program %s is not installed"
                                  harness-sandbox-openshell-program)))
         (dir (file-name-as-directory (make-temp-file "harness-openshell-check-" t)))
         (command (condition-case err
                      (harness-sandbox--openshell-command
                       program dir '("sh" "-c" "echo harness-openshell-ok")
                       :network nil)
                    (error (delete-directory dir t) (signal (car err) (cdr err)))))
         (interactive (called-interactively-p 'interactive)))
    (when interactive (message "Starting an OpenShell sandbox..."))
    (harness-then
     (harness-run-command command :cwd dir :timeout 300 :name "harness-openshell-check")
     (lambda (r)
       (ignore-errors (delete-directory dir t))
       (let* ((ok (and (eql 0 (plist-get r :exit))
                       (string-search "harness-openshell-ok" (plist-get r :stdout))))
              (message (if ok
                           "OpenShell started a sandbox and ran a command in it"
                         (format "OpenShell could not run a command: exit %s: %s"
                                 (plist-get r :exit)
                                 (harness-sandbox--first-lines
                                  (concat (plist-get r :stderr) " " (plist-get r :stdout)) 6)))))
         (when interactive (message "%s" message))
         (list :ok (and ok t) :message message))))))

;;;; Methods

(defun harness-sandbox--missing-programs (&optional list)
  "Say that this system's sandbox programs are missing, for a message.
GNU/Linux has bwrap and systemd-run, macOS MXC's mxc-exec-mac.  With
LIST non-nil, only name them, as a list; otherwise the message also
says why OpenShell cannot be used, when it was asked for."
  (let* ((darwin (eq system-type 'darwin))
         (text (cond ((and list darwin) "mxc-exec-mac (MXC)")
                     (list "bwrap, systemd-run")
                     (darwin "mxc-exec-mac (MXC) is not available (see `harness-sandbox-mxc-program')")
                     (t "neither bwrap nor systemd-run is available"))))
    (if (and (not list) harness-sandbox--problem)
        (format "%s, and OpenShell, which was asked for, cannot be used: %s"
                text harness-sandbox--problem)
      text)))

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
`harness-sandbox--mounts'.

`:tmp' names the caller's temporary directory (a session's own,
`session/tmp-dir'), which the command's /tmp shows, writable, instead of
an empty tmpfs of its own, and TMPDIR names /tmp as well: a script that
goes to /tmp without asking, as most do, leaves its files where the next
command and the harness's other tools find them.  It is shown at its
own path too.  `harness-sandbox--tmp-directory' says which directories
may be shown there; one that may not is left out with a line in the log
and the command keeps its private /tmp.  A `:read-only' command keeps it
too, as does the `locked' profile, which refuses `:tmp': a command that
must change nothing, and one that must not see what the session left
behind, write only what they throw away.  MXC and OpenShell show none
(the first has no mount namespace, the second's /tmp is the image's); a
command there finds its `:writable' directory at its real path, and the
private `$TMPDIR' under MXC.

`:read-only' non-nil mounts read-only the
working directory, the git directories and every `:writable' entry as
well, so that the command can write nothing but the sandbox's private
/tmp and the `:scratch' directories: those the caller made for the one
command and deletes after it, mounted writable whatever `:read-only'
says, after everything else (see `harness-sandbox--scratch-mounts',
which signals an error for one that would show writable what the
sandbox hides or keeps read-only).  Under MXC, on macOS, the private
/tmp is its private $TMPDIR, a directory made here for the command,
which removes it when it ends; see `harness-sandbox--mxc-command'.
Under OpenShell the mounts are bind mounts of a sandbox made for the
command (`harness-sandbox--openshell-command'), and the network is the
rules of `harness-sandbox-openshell-network-rules', or none with
`:network nil'.
They ask for no confinement: where COMMAND runs unconfined it reaches
them anyway.  A remote CWD or the `off' policy return COMMAND
unchanged.

`:profile' is `default' or `locked'.  `locked' is the secret-file
sandbox: the network off, `:read-only' always, no capability, the
`:scratch', `:tmp' and `:writable' options refused, and `:env' the
command's whole environment rather than an addition to the harness's.  It fails
closed for every case in which it cannot be given, whatever the policy:
the `off' policy, a remote CWD, no backend, systemd-run and OpenShell
signal `harness-sandbox-unavailable'.  bwrap and MXC give it.
`:hide' lists paths the backend keeps out of the command's sight, after
every mount that could show them.
  Signals `harness-sandbox-unavailable' when the policy is
`required' and no backend exists.  A `:read-only' command fails closed
instead of running unconfined: it signals `harness-sandbox-unavailable'
too for the `off' policy, for a remote CWD and for no backend, whatever
the policy.

`:capabilities' names the Linux capabilities COMMAND is given, none by
default (see \"Capabilities\" in the commentary).  bwrap adds each with
`--cap-add' provided it is in `harness-sandbox-capabilities' and listed
in `harness-sandbox-grantable-capabilities' when COMMAND is wrapped;
one that is not is left out, with a line in the log.  A `:read-only'
command gets none, whatever is asked.  systemd-run, MXC and OpenShell
cannot give any: with names to give they signal
`harness-sandbox-unavailable', as
bwrap does when `--cap-add' would be no capability of the sandbox's own
user namespace (setuid, or run by root).  Where COMMAND runs
unconfined anyway -- the `off' policy, a remote CWD, no backend -- it
has its user's own rights, and is returned as it is, with a line in
the debug log."
  (let* ((policy (harness-sandbox--policy cwd))
         (network (if (plist-member opts :network) (plist-get opts :network) t))
         (profile (or (plist-get opts :profile) 'default))
         (hide (plist-get opts :hide))
         (writable (plist-get opts :writable))
         (readable (plist-get opts :readable))
         (read-only (harness-json-true-p (plist-get opts :read-only)))
         (scratch (plist-get opts :scratch))
         (tmp (plist-get opts :tmp))
         (env (plist-get opts :env))
         (locked (eq profile 'locked))
         ;; A command that changes nothing is given no capability.
         (capabilities (and (not read-only) (plist-get opts :capabilities))))
    (unless (memq profile '(default locked))
      (error "Sandbox profile %S is neither `default' nor `locked'" profile))
    (when (and locked (or (plist-get opts :writable) (plist-get opts :scratch) tmp
                          (plist-get opts :capabilities)))
      (error "A locked command takes no temporary directory of its own, no writable directory, no scratch directory and no capability"))
    (cond
     (locked
      (cond
       ((or (eq policy 'off) (file-remote-p cwd))
        (harness-sandbox--refuse-locked
         command (if (eq policy 'off) "the sandbox policy is `off'"
                   (format "%s is on another host, where the sandbox does not reach" cwd))))
       ((eq harness-sandbox--backend 'bwrap)
        (let ((program (alist-get 'bwrap harness-sandbox--programs)))
          (harness-sandbox--bwrap-command program cwd command
                                          :network nil :writable nil :readable readable
                                          :read-only t :scratch nil
                                          :profile 'locked :env env :hide hide)))
       ((eq harness-sandbox--backend 'mxc)
        (let ((tmp (with-file-modes #o700 (make-temp-file "harness-sandbox-" t))))
          (condition-case err
              (harness-sandbox--mxc-command (alist-get 'mxc harness-sandbox--programs) cwd command
                                            :network nil :writable nil :readable readable
                                            :read-only t :tmp tmp :scratch nil
                                            :profile 'locked :extra-env env :hide hide)
            (error (ignore-errors (delete-directory tmp t))
                   (signal (car err) (cdr err))))))
       ((eq harness-sandbox--backend 'openshell)
        (harness-sandbox--refuse-locked command "OpenShell cannot give the locked profile"))
       ((eq harness-sandbox--backend 'systemd)
        (harness-sandbox--refuse-locked
         command "systemd-run shows the whole file system read-only; the locked profile needs a backend that shows only what it mounts"))
       (t
        (harness-sandbox--refuse-locked command (harness-sandbox--missing-programs)))))
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
                                        :env env :profile profile :hide hide :tmp tmp
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
                                        :read-only read-only :scratch scratch :env env :hide hide
                                        :tmp tmp))
     ((eq harness-sandbox--backend 'openshell)
      (when capabilities
        (harness-sandbox--refuse-capabilities
         command capabilities
         "OpenShell runs commands as a non-root user with no Linux capability, and has no way to give one"))
      (when tmp
        (harness-log 'debug "sandbox: OpenShell's sandbox has a /tmp of the image; %s shows at its own path" tmp))
      (harness-sandbox--openshell-command (alist-get 'openshell harness-sandbox--programs) cwd command
                                          :network network :writable writable :readable readable
                                          :read-only read-only :scratch scratch :env env))
     ((eq harness-sandbox--backend 'mxc)
      (when capabilities
        (harness-sandbox--refuse-capabilities
         command capabilities "MXC confines with macOS's Seatbelt, which has no Linux capabilities"))
      ;; The command's own $TMPDIR, private as bwrap's /tmp is: MXC
      ;; shows no shared temporary directory.
      (when tmp
        (harness-log 'debug "sandbox: MXC cannot show %s as /tmp; a command there uses $TMPDIR" tmp))
      (let ((tmp (with-file-modes #o700 (make-temp-file "harness-sandbox-" t))))
        (condition-case err
            (harness-sandbox--mxc-command (alist-get 'mxc harness-sandbox--programs) cwd command
                                          :network network :writable writable :readable readable
                                          :read-only read-only :tmp tmp
                                          :scratch scratch :extra-env env
                                          :profile profile :hide hide)
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
  "Return (:backend BACKEND :available (BACKENDS…) :policy POLICY :limits (TEXT…)).
`:limits' says in a line each what the backend in use cannot do of the
harness's access model: the Linux capabilities it cannot give, the
network OpenShell cannot open; nil for a backend that does all of it.
When OpenShell was asked for (`harness-sandbox-backend') and could not
be used, the plist also has `:requested' (`openshell') and `:problem',
why, and `:backend' is what the harness fell back to."
  (append (list :backend (or harness-sandbox--backend 'none)
                :available harness-sandbox--available
                :policy (harness-sandbox--policy nil)
                :limits (harness-sandbox--limits harness-sandbox--backend))
          (and harness-sandbox--requested
               (list :requested harness-sandbox--requested
                     :problem harness-sandbox--problem))))

(harness-defmethod sandbox/profiles (&optional cwd)
  "Say which sandbox profiles `sandbox/wrap' can enforce for CWD, and how.
Return a plist (:backend BACKEND :profiles (PROFILE…) :hide BOOL
:why TEXT).  `:profiles' names the profiles `sandbox/wrap' can give a
command run in CWD: `default' always, and `locked' only where the
backend implements it -- bwrap and MXC on macOS; systemd-run and
OpenShell cannot give the locked profile's limited view, and signal
rather than run with a wider one.  `:hide' says the backend can keep a
path out of a command's sight with `:hide' (bwrap, systemd-run and MXC
can; MXC refuses one lying under a directory it shows).  `:why',
present when `locked' is missing, says what stands in the way.  CWD
defaults to the current directory; a remote one, the `off' policy and
no backend leave only `default', as `sandbox/wrap' refuses a locked
command there whatever the policy."
  (let* ((policy (harness-sandbox--policy cwd))
         (backend harness-sandbox--backend)
         (profiles '(default))
         (why nil))
    (cond
     ((eq policy 'off) (setq why "the sandbox policy is `off'"))
     ((and cwd (file-remote-p cwd))
      (setq why (format "%s is on another host, where the sandbox does not reach"
                        (abbreviate-file-name cwd))))
     ((null backend) (setq why (harness-sandbox--missing-programs)))
     ((eq backend 'bwrap) (setq profiles '(default locked)))
     ((eq backend 'mxc) (setq profiles '(default locked)))
     ((eq backend 'openshell)
      (setq why "OpenShell cannot give the locked profile's minimal environment and file set"))
     ((eq backend 'systemd)
      (setq why "systemd-run shows the whole file system read-only; the locked profile needs a backend that shows only what it mounts")))
    (list :backend (or backend 'none)
          :profiles profiles
          :hide t
          :why why)))

(harness-defmethod sandbox/detect ()
  "Look for the backends again, choose one, and return `sandbox/status'.
What to call after starting an OpenShell gateway that was down: the
backend is chosen when the module starts, and again only by this.  It
waits for the checks of OpenShell, when that is asked for, which take a
moment when its gateway does not answer.  The access view's [Detect
again] calls it, for a UI that is no part of this process."
  (harness-sandbox-detect)
  (harness-call 'sandbox/status))

(harness-defmethod sandbox/check ()
  "Start a throwaway OpenShell sandbox, run a command in it, say how it went.
Return a promise of (:ok BOOL :message TEXT): `harness-sandbox-openshell-check'
for a UI that is no part of this process, the access view's [Test
OpenShell].  With no openshell program it answers at once, `:ok' false."
  (if (harness-sandbox--openshell-find)
      (harness-sandbox-openshell-check)
    (harness-resolved
     (list :ok :false
           :message (format "The program %s (harness-sandbox-openshell-program) is not installed or not on the exec path"
                            harness-sandbox-openshell-program)))))

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

(defun harness-sandbox--confined-p (cwd)
  "Non-nil when commands run in CWD are confined by a sandbox backend."
  (and cwd (not (file-remote-p cwd))
       (not (eq (harness-sandbox--policy cwd) 'off))
       (memq harness-sandbox--backend '(bwrap systemd mxc openshell))
       t))

(harness-defmethod sandbox/confined-p (cwd)
  "Non-nil when commands run in CWD are confined by a sandbox backend.
They are not when no backend exists, the policy is `off' or CWD is
remote: such a command sees what the user sees."
  (harness-sandbox--confined-p cwd))

(defun harness-sandbox--init ()
  "Detect backends.  Idempotent."
  (harness-sandbox-detect))

(harness-define-module 'sandbox
  :doc "Kernel sandbox (bwrap / systemd-run / MXC on macOS, or NVIDIA OpenShell on request) for spawned tool processes."
  :requires '(config)
  :init #'harness-sandbox--init)

(provide 'harness-sandbox)
;;; harness-sandbox.el ends here
