;;; harness-tools-ssh.el --- Run commands on another host over ssh, through TRAMP  -*- lexical-binding: t; -*-

;;; Commentary:

;; The ssh tool runs a shell command on another machine.  It goes
;; through TRAMP, as everything the harness does on a remote host does:
;; the command runs with `harness-run-command' in a TRAMP directory,
;; /ssh:HOST:/DIR/, so it shares TRAMP's connection to HOST and its
;; settings (`tramp-remote-path', proxies, connection sharing).  The
;; other tools reach the same host the same way: the file tools take
;; TRAMP paths (read_file /ssh:HOST:/etc/hosts; write_file, edit_file,
;; list_dir, glob, grep and file_info alike) and bash runs on HOST given
;; a cwd there.  The tool's description says so, and its result names
;; the directory it ran in as such a path.
;;
;; HOST is what ssh takes -- an alias of ~/.ssh/config or
;; [USER@]HOST[:PORT] -- an ssh:// URL, or a TRAMP prefix:
;; /ssh:USER@HOST#PORT:, or /ssh:JUMP|ssh:HOST: through a jump host.
;; It is checked before TRAMP sees it (`harness-tools-ssh-prefix'):
;; TRAMP hands host, user and port to a local shell and to ssh, which
;; takes a word starting with a dash for an option (-oProxyCommand=...),
;; so only the characters of host names, user names and ports get
;; through, and only the methods of `harness-tools-ssh--methods', which
;; all log in with ssh: /sudo::/ and /docker:...: are no hosts.
;;
;; Permissions: a call is of kind exec, so the permission mode and the
;; auto-mode judge decide it as they decide a bash command, and its path
;; is the directory it runs in on HOST, so the jail asks for HOST the
;; first time.  Granting /ssh:HOST:/ lets a session work anywhere on
;; HOST, with this tool and every other; a non-interactive session needs
;; it granted beforehand (`harness-allowed-directories').  The path is
;; worked out without connecting -- nothing in the permission chain may
;; wait on the network -- so a call without an absolute cwd, which runs
;; in the remote home directory, is about the host's root.  Corporate
;; mode turns the tool off (see harness-tools.el).
;;
;; The harness has no terminal: a connection that needs a password, a
;; key passphrase or a host key confirmation fails.  Then ssh is asked
;; once more, in batch mode, why, and the error carries its answer and
;; how to set the host up (`harness-tools-remote-failure', which
;; explains the other tools' failed connections too).  The command runs
;; with bash, or sh on a host without bash, its standard input
;; /dev/null (see `harness-tools-shell-remote-command').

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)
(require 'harness-tools-shell)

(declare-function tramp-dissect-file-name "tramp" (name &optional nodefault))
(declare-function tramp-tramp-file-p "tramp" (name))
(declare-function tramp-file-name-method "tramp" (vec))
(declare-function tramp-file-name-user "tramp" (vec))
(declare-function tramp-file-name-domain "tramp" (vec))
(declare-function tramp-file-name-host "tramp" (vec))
(declare-function tramp-file-name-port "tramp" (vec))
(declare-function tramp-file-name-localname "tramp" (vec))
(declare-function tramp-file-name-hop "tramp" (vec))

(defvar harness-tools-ssh--methods '("ssh" "sshx" "scp" "scpx" "rsync")
  "TRAMP methods the ssh tool connects with, on every hop.
Internal, not an option (see docs/configuration-audit.md).  They all
log in with ssh; a method that reaches another user or a container on
this machine (su, sudo, docker) names no host to ssh to.")

(defconst harness-tools-ssh--default-method "ssh"
  "TRAMP method for a host given as an ssh destination, not a TRAMP prefix.")

(defconst harness-tools-ssh--name-regexp "\\`[A-Za-z0-9_][A-Za-z0-9._-]*\\'"
  "Regexp of the user and host names the tool passes on.
The first character is no dash, which ssh would read as an option.")

(defconst harness-tools-ssh--destination-regexp
  "\\`\\(?:ssh://\\)?\\(?:\\([^@/]+\\)@\\)?\\(\\[[^]/]*\\]\\|[^]:#@/[]+\\)\\(?:[:#]\\([^/]*\\)\\)?/?\\'"
  "Regexp of an ssh destination: [ssh://][USER@]HOST[:PORT].
HOST may be an IPv6 address in brackets; the port may follow a # as in
a TRAMP name.  The parts are checked one by one afterwards.")

;;;; Hosts

(defun harness-tools-ssh--name-p (s)
  "Non-nil when S is a user or host name the tool passes on."
  (and (stringp s) (string-match-p harness-tools-ssh--name-regexp s) t))

(defun harness-tools-ssh--host-p (s)
  "Non-nil when S is a host name or an IPv4 or IPv6 address."
  (and (stringp s)
       (or (harness-tools-ssh--name-p s)
           (and (string-match-p "\\`[0-9A-Fa-f:.]+\\'" s) (string-search ":" s) t))))

(defun harness-tools-ssh--port-p (s)
  "Non-nil when S is a port number."
  (and (stringp s) (string-match-p "\\`[0-9]\\{1,5\\}\\'" s)
       (<= 1 (string-to-number s) 65535)))

(defun harness-tools-ssh--hop (method user host port)
  "Return METHOD:USER@HOST#PORT, one hop of a TRAMP name, all checked.
USER and PORT may be nil.  Signal an error that names the part that
is no good."
  (unless (member method harness-tools-ssh--methods)
    (error "%s is no ssh method; the ssh tool connects with %s"
           (if method (format "/%s:" method) "a name without a method")
           (string-join harness-tools-ssh--methods ", ")))
  (unless (or (null user) (harness-tools-ssh--name-p user))
    (error "%S is no user name" user))
  (unless (harness-tools-ssh--host-p host)
    (error "%S is no host name" (or host "")))
  (unless (or (null port) (harness-tools-ssh--port-p port))
    (error "%S is no port" port))
  (concat method ":" (if user (concat user "@") "")
          (if (string-search ":" host) (concat "[" host "]") host)
          (if port (concat "#" port) "")))

(defun harness-tools-ssh--hop-of (vec)
  "Return the hop TRAMP's dissected name VEC stands for, checked."
  (when (tramp-file-name-domain vec)
    (error "%S is no user name" (concat (tramp-file-name-user vec) "%" (tramp-file-name-domain vec))))
  (cl-flet ((plain (s) (and (stringp s) (not (string-empty-p s)) (substring-no-properties s))))
    (harness-tools-ssh--hop (plain (tramp-file-name-method vec)) (plain (tramp-file-name-user vec))
                            (plain (tramp-file-name-host vec)) (plain (tramp-file-name-port vec)))))

(defun harness-tools-ssh--tramp-prefix (name)
  "Return (PREFIX . LOCALNAME) for NAME, a TRAMP prefix or file name.
Every hop is checked, the jump hosts' as well as the last one's."
  (require 'tramp)
  (let ((vec (and (tramp-tramp-file-p name)
                  (condition-case nil (tramp-dissect-file-name name) (error nil)))))
    (unless vec (error "%S is no TRAMP name" name))
    (let ((hops (mapcar (lambda (hop)
                          (harness-tools-ssh--hop-of
                           (or (condition-case nil (tramp-dissect-file-name (concat "/" hop ":")) (error nil))
                               (error "%S is no hop" hop))))
                        (split-string (or (tramp-file-name-hop vec) "") "|" t))))
      (cons (concat "/" (string-join (append hops (list (harness-tools-ssh--hop-of vec))) "|") ":")
            (substring-no-properties (or (tramp-file-name-localname vec) ""))))))

(defun harness-tools-ssh-prefix (host)
  "Return (PREFIX . LOCALNAME) for HOST, as the ssh tool takes it.
HOST is an ssh destination, [ssh://][USER@]HOST[:PORT] or an alias of
~/.ssh/config, or a TRAMP prefix such as /ssh:USER@HOST#PORT: or
/ssh:JUMP|ssh:HOST:, which may go on with a directory.  PREFIX is the
TRAMP prefix, every hop written out (\"/ssh:USER@HOST#PORT:\");
LOCALNAME is the directory after a TRAMP prefix, or \"\".  Nothing
connects.  Signal an error that says what is wrong with HOST otherwise."
  (let ((host (string-trim (if (stringp host) host ""))))
    (cond
     ((string-empty-p host) (error "Missing host"))
     ((string-prefix-p "/" host) (harness-tools-ssh--tramp-prefix host))
     ((string-match harness-tools-ssh--destination-regexp host)
      (let ((user (match-string 1 host))
            (name (match-string 2 host))
            (port (match-string 3 host)))
        (when (string-prefix-p "[" name) (setq name (substring name 1 -1)))
        (cons (concat "/" (harness-tools-ssh--hop harness-tools-ssh--default-method user name
                                                  (and port (not (string-empty-p port)) port))
                      ":")
              "")))
     (t (error "%S is no ssh destination" host)))))

(defun harness-tools-ssh--where (input)
  "Return (PREFIX LOCAL) for a call with INPUT, worked out without connecting.
PREFIX is the TRAMP prefix of the host (`harness-tools-ssh-prefix').
LOCAL is the directory to run in there, as a directory name: absolute,
or starting with ~ for one the host expands.  The `:cwd' of INPUT
decides it, else the directory a TRAMP name in `:host' goes on with,
else the home directory; a relative cwd is relative to the home
directory, and one with a TRAMP prefix must be on the same host.
Signal an error when the host or the directory is no good."
  (pcase-let* ((`(,prefix . ,localname) (harness-tools-ssh-prefix (plist-get input :host)))
               (given (plist-get input :cwd))
               (cwd (if (and (stringp given) (not (string-blank-p given))) (string-trim given) localname))
               (on (and (stringp cwd) (file-remote-p cwd))))
    (when on
      (unless (equal on (file-remote-p (concat prefix "/")))
        (error "The cwd %s is not on %s" cwd prefix))
      (setq cwd (file-remote-p cwd 'localname)))
    (list prefix
          (file-name-as-directory
           (cond ((or (null cwd) (string-empty-p cwd)) "~")
                 ;; A local name: no file name handler may take it for one of its own.
                 ((string-prefix-p "/" cwd) (let ((file-name-handler-alist nil)) (expand-file-name cwd "/")))
                 ((string-prefix-p "~" cwd) cwd)
                 (t (concat "~/" cwd)))))))

(defun harness-tools-ssh--paths (input)
  "Return the paths a call with INPUT is about, for the permission jail.
That is the directory it runs in on its host, or the host's root when
the host has to say where that is (the home directory, a relative
cwd): nothing in the permission chain connects.  A call whose host is
no good has none; it fails before it connects."
  (condition-case nil
      (pcase-let ((`(,prefix ,local) (harness-tools-ssh--where input)))
        (list (concat prefix (if (string-prefix-p "/" local) local "/"))))
    (error nil)))

;;;; The tool

(defun harness-tools-ssh--dir (prefix local)
  "Return the TRAMP directory LOCAL names on PREFIX's host, or why not.
Why not is (:missing DIR) when there is no such directory and (:failed
ERR) when the host could not be reached.  A directory starting with ~
is expanded on the host, which connects, and so does the check."
  (condition-case err
      (let ((dir (if (string-prefix-p "/" local)
                     (concat prefix local)
                   (file-name-as-directory (expand-file-name (concat prefix local))))))
        (if (file-directory-p dir) dir (list :missing dir)))
    (error (list :failed err))))

(defun harness-tools-ssh--run (input ctx)
  "Handler for the ssh tool with INPUT under CTX; returns a promise or a result."
  (let* ((command (plist-get input :command))
         (timeout (min harness-tools-shell--max-timeout
                       (max 1 (harness-tools-shell--number (plist-get input :timeout)
                                                           harness-tools-shell--default-timeout))))
         (report (plist-get ctx :report))
         (where (condition-case err (harness-tools-ssh--where input) (error err))))
    (cond
     ((or (not (stringp command)) (string-blank-p command))
      (harness-tool-error "Missing command"))
     ((not (stringp (car where)))
      (harness-tool-error
       (format "Bad host %S: %s. Give an alias of ~/.ssh/config, [user@]host[:port], or a TRAMP prefix such as /ssh:user@host#2222: (/ssh:jump|ssh:host: through a jump host)."
               (or (plist-get input :host) "") (harness-error-message where))))
     (t
      (pcase-let* ((`(,prefix ,local) where)
                   (started (float-time))
                   (dir (harness-tools-ssh--dir prefix local)))
        (pcase dir
          (`(:failed ,err) (harness-tools-remote-failure prefix err))
          (`(:missing ,missing)
           (harness-tool-error (format "No directory %s on the host" missing)
                               :meta (list :host prefix :connected t)))
          (_
           (harness-then
            (harness-run-command (harness-tools-shell-remote-command command)
                                 :cwd dir :timeout timeout :name "harness-ssh"
                                 :merge-remote-stderr t
                                 :on-output (and report (lambda (chunk) (funcall report chunk))))
            (lambda (r)
              (let ((exit (plist-get r :exit)))
                (funcall (if (eql exit 0) #'harness-tool-ok #'harness-tool-error)
                         (format "%s in %s" (harness-tools-shell--format-output r timeout) dir)
                         :meta (list :exit exit :host prefix :cwd dir
                                     :duration (- (float-time) started)))))
            (lambda (err) (harness-tools-remote-failure prefix err))))))))))

(defun harness-tools-ssh--subject (input)
  "Return what a call of the ssh tool with INPUT is about: host and command."
  (let ((host (plist-get input :host))
        (command (harness-first-line (plist-get input :command) 60)))
    (if (and (stringp host) (not (string-blank-p host)))
        (format "%s: %s" (string-trim host) command)
      command)))

(harness-define-tool "ssh"
  :label "SSH"
  :description "Run a shell command on another host over ssh, through TRAMP. host is an alias from ~/.ssh/config, [user@]host[:port], or a TRAMP prefix such as /ssh:user@host#2222: (/ssh:jump|ssh:host: through a jump host). The command runs with bash (sh where the host has none) in cwd, by default the remote home directory, with no input. Output is what it printed, stderr mixed in, then the exit status and the directory it ran in, as a TRAMP path. The other tools work on the host too: give read_file, write_file, edit_file, list_dir, glob, grep and file_info a path there, such as /ssh:host:/etc/hosts, and bash a cwd there; prefer them to cat, sed or grep over ssh. Nothing can answer a prompt: the host must accept a key from ssh-agent (or one without a passphrase) and be in known_hosts."
  :schema '(:type "object"
            :properties (:host (:type "string" :description "Where to connect: an alias from ~/.ssh/config, [user@]host[:port], or a TRAMP prefix such as /ssh:user@host#2222:")
                         :command (:type "string" :description "The command line to run")
                         :cwd (:type "string" :description "Directory on the host to run in: absolute, or relative to the remote home directory. Default: the home directory")
                         :timeout (:type "integer" :description "Seconds before the command is killed. Default 120"))
            :required ("host" "command"))
  :kind 'exec
  :timeout 3700
  :paths #'harness-tools-ssh--paths
  :subject #'harness-tools-ssh--subject
  :handler #'harness-tools-ssh--run)

(harness-define-module 'tools-ssh
  :doc "SSH: shell commands on another host, through TRAMP."
  :requires '(tools tools-shell))

(provide 'harness-tools-ssh)
;;; harness-tools-ssh.el ends here
