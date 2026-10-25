;;; harness-tools-shell.el --- bash and elisp tools  -*- lexical-binding: t; -*-

;;; Commentary:

;; Two ways for a model to run things:
;;
;; - `bash' runs a command through `bash -c' as an asynchronous
;;   process (`harness-run-command'), in the session's working
;;   directory or a subdirectory of it.  When the sandbox module is
;;   loaded and the directory is local, the command line is wrapped
;;   with `sandbox/wrap' so it runs confined; a `required' policy
;;   without a backend, or without the sandbox module, turns into a
;;   tool error rather than an unconfined run.  The session's own temporary directory
;;   (`session/tmp-dir') is writable in there too, at its real path:
;;   the sandbox's /tmp is private and empty for every command, so
;;   that directory is where commands leave files for later ones and
;;   for the other tools.  So is every other directory the session may
;;   touch (`permission/dirs'): its working directory and worktree, the
;;   configured directories and those granted to it, so a directory the
;;   user granted reaches bash as it reaches the other tools; the tool
;;   output directory is shown read-only.  The skills directories
;;   (`skills/directories') are shown read-only too.  Each is shown at
;;   its own path, and ~ keeps the real home directory's path with only
;;   those inside it, so `cat ~/.claude/skills/x/SKILL.md' or `ls
;;   ~/granted' works in there as it does outside while the rest of the
;;   home directory stays hidden.
;;
;;   A module can confine a session's commands further.  The sync
;;   filter `tools/sandbox-options' runs before each command, the elisp
;;   tool's background Emacs included, with the value nil and the
;;   session id as its argument.  A handler returns
;;   the plist of options for `sandbox/wrap' that it was given with its
;;   own put over them, such as (:read-only t :network nil), so that a
;;   later handler's options win over an earlier one's.  The options
;;   go to `sandbox/wrap' with the directories above, to whose lists a
;;   handler's own `:writable' and `:readable' join.  With `:read-only'
;;   every one of those directories goes as `:readable' and none as
;;   `:writable': the command looks at what its session may touch and
;;   changes none of it.  Options ask for the sandbox, so a command that
;;   cannot have it fails with an error rather than run unconfined: with
;;   no `sandbox/wrap' method, whatever the policy, or in a remote
;;   directory.  With no handler the command runs as it always did.
;;
;;   The filter is also how a session gets the Linux capabilities the user
;;   gave its commands: the access module adds `:capabilities' to the
;;   options, and the sandbox passes them to bwrap (`--cap-add'); a
;;   command in a remote directory that is given some is refused, like
;;   any command that needs the sandbox.
;;
;;   Remote (TRAMP) directories run the command on that host,
;;   unwrapped, as the ssh tool does (tools-ssh): through
;;   `harness-tools-shell-remote-command', with bash, or sh on a host
;;   that has none, and standard input from /dev/null.  TRAMP runs a
;;   remote process on a pty that never passes the end of input on, so
;;   a command reading its input would wait for its timeout.
;;
;;   In the chat its calls fold under one summary line with the reads
;;   around them (`:coalescable', see harness-tools.el), so that a
;;   stretch of looking around, commands included, is one line to open
;;   when it matters.  A command still running notes itself under its
;;   call, which a folded call hides; the activity line under the
;;   transcript says what runs and its latest line.
;;
;; - `elisp' evaluates Emacs Lisp, the Emacs-native alternative to a
;;   shell: the value of the last form, anything printed to
;;   `standard-output' and any `message' calls come back.  It evaluates
;;   in a child `emacs --batch' process, never the user's Emacs, where
;;   model-written code could block the UI beyond recovery (see
;;   harness-elisp.el); a timeout kills the child, its whole process
;;   group included.  The user's Emacs is read and driven with the
;;   bounded `emacs_*' tools (tools-emacs), a fixed vocabulary none of
;;   which evaluates code; no tool evaluates model-written Lisp there.
;;   The tool itself runs here, in the harness, like every tool.
;;
;;   The child is a command like any other, so it runs in the sandbox
;;   as a bash command of the session does: `harness-tools-shell--wrap'
;;   shows it the same directories, asks the same `tools/sandbox-options'
;;   filter, and refuses to run it unconfined where it refuses a bash
;;   command (a `required' policy without the sandbox).  Besides those
;;   it reads the harness's harness.el and lisp/, from which it loads
;;   -- not the rest of the checkout, whose scripts/.dev holds the
;;   sockets of the instances scripts/dev.sh runs -- and the Emacs it
;;   runs, where that is not in /usr; and it writes the call's own io/
;;   directory, where its code waits and it leaves its result, even when
;;   a filter makes it read-only (the sandbox's `:scratch').  The child
;;   always runs on this machine, where a remote session has no
;;   directory, so a remote session's code runs in the call's own.
;;   The result is read back only from a regular file, since a child in
;;   the sandbox could leave a link there to a file only the harness
;;   can read.
;;
;;   With `snapshot' the child starts from a copy of the user's Emacs:
;;   the harness asks that Emacs for it, in slices
;;   (lisp/harness-snapshot.el; the `snapshot' request of
;;   harness-emacs-endpoint.el), puts it in a file in the call's io/
;;   directory and the child reads it as data before the code runs
;;   (`harness-elisp-load-snapshot').  Such a child runs read-only and
;;   offline whatever the session otherwise has, and is refused where no
;;   sandbox can give that: the copy is the user's data and must not
;;   meet an unconfined process.  The code can change its copy and
;;   nothing else; the user's Emacs is only read, and the child cannot
;;   reach it.  Credentials are left out of the copy by name
;;   (docs/trust-model.md).

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pp)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)
(require 'harness-elisp)

(defconst harness-tools-shell--program "bash"
  "Shell used by the bash tool.")

(defconst harness-tools-shell--default-timeout 120
  "Seconds a bash command may run when the model gives no timeout.")

(defconst harness-tools-shell--max-timeout 3600
  "Upper bound for the timeout a model may request for a bash command.")

(defconst harness-tools-shell--remote-script
  "if command -v bash >/dev/null 2>&1; then exec bash -c \"$1\" </dev/null; fi; exec sh -c \"$1\" </dev/null"
  "Script that runs its first argument on a remote host.
It runs it with bash, or with sh on a host without bash, and standard
input from /dev/null: TRAMP runs a remote process on a pty that never
passes the end of input on, so a command that read it, such as `cat'
or a `read', would wait until it was killed.")

(defun harness-tools-shell-remote-command (command)
  "Return the program and arguments that run shell COMMAND on a remote host.
Run them with `harness-run-command' in a TRAMP directory, standard
error mixed into the output (its MERGE-REMOTE-STDERR); see
`harness-tools-shell--remote-script'.  The bash and ssh tools both
run remote commands so."
  (list "sh" "-c" harness-tools-shell--remote-script "sh" command))

;;;; bash

(defun harness-tools-shell--number (v default)
  "Return V as a number, or DEFAULT."
  (cond ((numberp v) v)
        ((and (stringp v) (string-match-p "\\`[0-9.]+\\'" v)) (string-to-number v))
        (t default)))

(defun harness-tools-shell--bash-cwd (input ctx)
  "Return the absolute working directory for a bash call with INPUT under CTX."
  (let ((given (plist-get input :cwd)))
    (file-name-as-directory
     (if (and (stringp given) (not (string-empty-p given)))
         (harness-tools-resolve-path given ctx)
       (or (plist-get ctx :cwd) default-directory)))))

(defun harness-tools-shell--tmp-dir (ctx)
  "Return the temporary directory of CTX's session, made if missing, or nil."
  (let ((sid (plist-get ctx :session-id)))
    (and sid (harness-method-exists-p 'session/tmp-dir)
         (condition-case err
             (harness-call 'session/tmp-dir sid)
           (error (harness-log 'debug "bash: no temporary directory for %s: %s"
                               sid (harness-error-message err))
                  nil)))))

(defun harness-tools-shell--skill-dirs (ctx)
  "Return the skills directories a command of CTX's session may read, or nil.
They are those of `skills/directories' that hold skills and nothing
else, the ones every call that only reads may read too; nil without
the skills module or for a remote session, whose commands run on
another host."
  (let ((cwd (plist-get ctx :cwd)))
    (when (and (harness-method-exists-p 'skills/directories)
               (stringp cwd) (not (file-remote-p cwd)))
      (condition-case err
          (delq nil (mapcar (lambda (e) (and (plist-get e :contained) (plist-get e :dir)))
                            (harness-call 'skills/directories cwd)))
        (error (harness-log 'debug "bash: could not list the skills directories: %s"
                            (harness-error-message err))
               nil)))))

(defun harness-tools-shell--session-dirs (ctx)
  "Return the directories CTX's session may touch as (WRITABLE . READABLE).
They are those the permission layer lets every tool reach
\(`permission/dirs'): its working directory and worktree, its own
temporary directory, the configured ones and those granted to it are
WRITABLE, the tool output directory, which only the harness writes,
and the directories the session may only read (`:read-only' entries,
see the access module) READABLE.  Both are nil without the permissions
module or for a remote session, whose commands run on another host.  A
glob pattern among the grants names no directory, and the sandbox
leaves it out."
  (let ((sid (plist-get ctx :session-id))
        (cwd (plist-get ctx :cwd)))
    (when (and sid (harness-method-exists-p 'permission/dirs)
               (not (plist-get ctx :host))
               (not (and (stringp cwd) (file-remote-p cwd))))
      (condition-case err
          (let (writable readable)
            (dolist (e (harness-call 'permission/dirs sid))
              (let ((dir (plist-get e :dir)))
                (when (and (stringp dir) (not (file-remote-p dir)))
                  (if (or (eq (plist-get e :source) 'outputs)
                          (harness-json-true-p (plist-get e :read-only)))
                      (push dir readable)
                    (push dir writable)))))
            (cons (nreverse writable) (nreverse readable)))
        (error (harness-log 'debug "bash: could not list the directories of %s: %s"
                            sid (harness-error-message err))
               nil)))))

(defun harness-tools-shell--sandbox-required-p (cwd)
  "Non-nil when `harness-sandbox-policy' is `required' for a command in CWD.
The config module's value for CWD decides, and the option's when there
is no config module."
  (let ((policy (or (and (harness-method-exists-p 'config/get)
                          (ignore-errors (harness-call 'config/get 'harness-sandbox-policy cwd)))
                     (and (boundp 'harness-sandbox-policy) (symbol-value 'harness-sandbox-policy)))))
    (equal (format "%s" policy) "required")))

(defun harness-tools-shell--options-p (options)
  "Non-nil when OPTIONS is a plist whose keys are all keywords."
  (and (proper-list-p options)
       (cl-evenp (length options))
       (cl-loop for (key) on options by #'cddr always (keywordp key))))

(defun harness-tools-shell--sandbox-options (ctx)
  "Return the extra `sandbox/wrap' options a command under CTX must run with.
That is a bash call's command or the elisp tool's background Emacs.
They are what the `tools/sandbox-options' filter makes of nil, with the
session id as its argument: a handler returns the plist it was given
with its own options set over it, such as (:read-only t :network nil),
so that a later handler's options win over an earlier one's.  Nil
without a handler.  A value that is no plist of options signals an
error, so that a faulty handler cannot let a command run with fewer
restrictions than it meant."
  (let ((options (harness-run-filter 'tools/sandbox-options nil (plist-get ctx :session-id))))
    (unless (harness-tools-shell--options-p options)
      (error "The handlers of tools/sandbox-options gave %S, not a plist of sandbox options" options))
    options))

(defun harness-tools-shell--wrap-options (writable readable options &optional scratch)
  "Return the `sandbox/wrap' options for the directories WRITABLE and READABLE.
OPTIONS, the plist of extra ones, go with them, and its own `:writable',
`:readable' and `:scratch' directories join the lists.  With
`:read-only' in OPTIONS none is writable: all the directories go as
readable, so that the command is shown what its session may touch and
changes none of it.  The SCRATCH directories, made for the one command
and deleted after it, go as `:scratch', which the command writes
whatever OPTIONS say, and only when there are any."
  (let ((writable (append writable (plist-get options :writable)))
        (readable (append readable (plist-get options :readable)))
        (scratch (append scratch (plist-get options :scratch))))
    (when (harness-json-true-p (plist-get options :read-only))
      (setq readable (delete-dups (append writable readable))
            writable nil))
    (append (list :writable writable :readable readable)
            (and scratch (list :scratch scratch))
            (cl-loop for (key value) on options by #'cddr
                     unless (memq key '(:writable :readable :scratch)) append (list key value)))))

(defun harness-tools-shell--refuse-unconfined (options why)
  "Signal an error: a command that needs sandbox OPTIONS cannot have the sandbox.
WHY says what stands in the way."
  (error "A command that needs the sandbox options %S cannot run unconfined, but %s"
         options why))

(defun harness-tools-shell--wrap (cwd command &optional writable readable options scratch)
  "Return COMMAND wrapped by the sandbox for CWD when the sandbox module is loaded.
WRITABLE lists other directories the command may write to, READABLE
directories it may read, and SCRATCH directories made for this command
alone, which it may write whatever OPTIONS say.  OPTIONS are the extra
`sandbox/wrap' options asked for (see
`harness-tools-shell--sandbox-options'); they are given to it with the
directories (see `harness-tools-shell--wrap-options').  Without the
sandbox module a `required' `harness-sandbox-policy' signals an error
rather than letting COMMAND run unconfined, as the sandbox does when it
has no backend.  OPTIONS ask for the sandbox whatever the policy: the
error comes too when the module is not loaded or CWD is remote.
SCRATCH asks for nothing: unwrapped, COMMAND reaches it anyway.
Unwrapped, COMMAND comes back itself, the very list given."
  (cond
   ((and options (file-remote-p cwd))
    (harness-tools-shell--refuse-unconfined
     options (format "%s is on another host, where the sandbox does not reach" cwd)))
   ((file-remote-p cwd) command)
   ((harness-method-exists-p 'sandbox/wrap)
    (apply #'harness-call 'sandbox/wrap cwd command
           (harness-tools-shell--wrap-options writable readable options scratch)))
   (options
    (harness-tools-shell--refuse-unconfined options "the sandbox module is not loaded"))
   ((harness-tools-shell--sandbox-required-p cwd)
    (error "The sandbox is required (harness-sandbox-policy), but the sandbox module is not loaded"))
   (t command)))

(cl-defun harness-tools-shell-sandbox-profile (ctx cwd &key readable writable scratch)
  "Return the sandbox profile of a process CTX's session runs in CWD, a plist.
It is what a bash command of the session is shown, as data: `:cwd',
`:writable' (the session's own temporary directory, its working
directory and worktree, the configured and granted directories, and
the WRITABLE ones given), `:readable' (the skills directories, the
read-only directories of the session, and the READABLE ones given),
`:scratch' (SCRATCH, directories made for the one process, which it
writes whatever else is read-only) and `:options' (what the
`tools/sandbox-options' filter makes of nil, see
`harness-tools-shell--sandbox-options').  `harness-tools-shell-wrap-profile'
wraps a command in it.  The MCP host (lisp/modules/harness-mcp.el)
starts the servers of a session this way, so a tool it serves sees what
bash sees.  Signals an error when a handler of the filter gives no
plist of options."
  (let ((options (harness-tools-shell--sandbox-options ctx))
        (dirs (harness-tools-shell--session-dirs ctx)))
    (list :cwd cwd
          :writable (delete-dups (delq nil (append writable
                                                   (cons (harness-tools-shell--tmp-dir ctx) (car dirs)))))
          :readable (delete-dups (append readable (harness-tools-shell--skill-dirs ctx) (cdr dirs)))
          :scratch scratch
          :options options)))

(defun harness-tools-shell-wrap-profile (profile command)
  "Return COMMAND wrapped for the sandbox as PROFILE says.
PROFILE is what `harness-tools-shell-sandbox-profile' returned.  This
is `harness-tools-shell--wrap': a `required' policy without a backend, or
options that need a sandbox there is none of, signal an error rather
than leave COMMAND unconfined, and COMMAND comes back itself, the very
list given, when it runs unwrapped."
  (harness-tools-shell--wrap (plist-get profile :cwd) command
                             (plist-get profile :writable) (plist-get profile :readable)
                             (plist-get profile :options) (plist-get profile :scratch)))

(defun harness-tools-shell--format-output (r timeout)
  "Format the result plist R of `harness-run-command' run with TIMEOUT seconds."
  (let* ((exit (plist-get r :exit))
         (stdout (plist-get r :stdout))
         (stderr (string-trim-right (plist-get r :stderr)))
         (parts nil))
    (unless (string-empty-p stdout)
      (push (string-trim-right stdout) parts))
    (unless (string-empty-p stderr)
      (push (concat "--- stderr ---\n" stderr) parts))
    (push (if (eq exit 'timeout)
              (format "exit: killed after %ss timeout" timeout)
            (format "exit %s" exit))
          parts)
    (string-join (nreverse parts) "\n")))

(defconst harness-tools-shell--note-interval 0.25
  "Seconds between updates of the note under a running bash call.
The command's output can arrive in many chunks a second; the note names
the lines so far and the latest one, and nothing needs that per chunk.")

(defun harness-tools-shell--bash-note (lines tail)
  "Return the note under a running bash call.
LINES is how many newlines its output has, TAIL the last of it: the
note says it is still running and how many lines it has written, and
opens the latest line under that."
  (let* ((last (harness-tools-tail-line tail))
         (open (and (stringp tail) (not (string-empty-p tail)) (not (string-suffix-p "\n" tail))))
         (n (+ (or lines 0) (if open 1 0))))
    (concat (if (> n 0)
                (format "still running \N{U+00B7} %s so far" (harness-tools-count-phrase n "line"))
              "still running \N{U+00B7} no output yet")
            (if last (concat "\n" last) ""))))

(defun harness-tools-shell--bash (input ctx)
  "Handler for the bash tool with INPUT under CTX; returns a promise."
  (let* ((command (plist-get input :command))
         (timeout (min harness-tools-shell--max-timeout
                       (max 1 (harness-tools-shell--number (plist-get input :timeout)
                                                           harness-tools-shell--default-timeout))))
         (cwd (harness-tools-shell--bash-cwd input ctx))
         (report (plist-get ctx :report))
         (note (plist-get ctx :note))
         ;; The note's own counters: the command's output arrives in
         ;; chunks, and its size is not ours to keep whole.
         (lines 0) (tail "") (noted 0))
    (cond
     ((or (not (stringp command)) (string-blank-p command))
      (harness-tool-error "Missing command"))
     ((not (file-directory-p cwd))
      (harness-tool-error (format "Working directory does not exist: %s" cwd)))
     (t
      (let* ((remote (file-remote-p cwd))
             (cmd (condition-case err
                      (let ((options (harness-tools-shell--sandbox-options ctx)))
                        ;; A remote command runs unwrapped, so one that needs
                        ;; the sandbox goes to `harness-tools-shell--wrap', which
                        ;; refuses it.
                        (if (and remote (null options))
                            (harness-tools-shell-remote-command command)
                          ;; Not a login shell: the harness already has the user's
                          ;; environment, and a login profile's side effects (starting
                          ;; an ssh-agent, importing keys) go wrong in a sandbox, whose
                          ;; PID namespace hides the user's processes from it.
                          (let ((dirs (harness-tools-shell--session-dirs ctx)))
                            (harness-tools-shell--wrap
                             cwd (list harness-tools-shell--program "-c" command)
                             (delete-dups (delq nil (cons (harness-tools-shell--tmp-dir ctx) (car dirs))))
                             (append (harness-tools-shell--skill-dirs ctx) (cdr dirs))
                             options))))
                    (error (list :error (harness-error-message err))))))
        (if (and (consp cmd) (eq (car cmd) :error))
            (harness-tool-error (format "Cannot run command: %s" (plist-get cmd :error)))
          (let ((started (float-time)))
            (harness-tools-note ctx (harness-tools-shell--bash-note 0 ""))
            (harness-then
             (harness-run-command cmd :cwd cwd :timeout timeout :name "harness-bash"
                                  :merge-remote-stderr t
                                  :on-output
                                  (lambda (chunk)
                                    (when report (funcall report chunk))
                                    (setq lines (+ lines (cl-count ?\n chunk))
                                          tail (let ((text (concat tail chunk)))
                                                 (if (> (length text) 4000)
                                                     (substring text (- (length text) 4000))
                                                   text)))
                                    (let ((now (float-time)))
                                      (when (and note (> (- now noted) harness-tools-shell--note-interval))
                                        (setq noted now)
                                        (harness-tools-note ctx (harness-tools-shell--bash-note lines tail))))))
             (lambda (r)
               (let ((exit (plist-get r :exit)))
                 (funcall (if (eql exit 0) #'harness-tool-ok #'harness-tool-error)
                          (harness-tools-shell--format-output r timeout)
                          :meta (list :exit exit :cwd cwd
                                      :duration (- (float-time) started)
                                      :sandboxed (and (not remote)
                                                      (not (equal (car cmd) harness-tools-shell--program)))))))))))))))

(harness-define-tool "bash"
  :label "Bash"
  :description "Run a shell command with bash in the working directory (or a subdirectory). Output is stdout, then stderr if any, then the exit status. Long jobs are killed at timeout seconds (default 120). Prefer read_file, grep, glob and edit_file over cat, grep, find and sed. Commands may run in a sandbox that shows the system directories and only the directories the session may use (the working directory, its temporary directory, the directories granted to it), each at its real path; anything else, the rest of the home directory included, looks missing there, so reach it with the file tools, which ask the user. The sandbox gives a command no Linux capability, so strace, gdb -p, ping or a raw socket can answer \"Operation not permitted\": ask the user for one with request_escalation (attribute capability, value such as CAP_SYS_PTRACE); it counts inside the sandbox only, never on another machine."
  :schema '(:type "object"
            :properties (:command (:type "string" :description "The command line to run")
                         :timeout (:type "integer" :description "Seconds before the command is killed. Default 120")
                         :cwd (:type "string" :description "Directory to run in, relative to the working directory. Default: the working directory"))
            :required ("command"))
  :kind 'exec
  :coalescable t
  :timeout 3700
  :paths (lambda (input) (list (or (plist-get input :cwd) ".")))
  :subject (lambda (input) (harness-first-line (plist-get input :command) 70))
  :handler #'harness-tools-shell--bash)

;;;; elisp

;; The tool runs here, in the harness, like every tool, and always
;; evaluates in a fresh background Emacs, apart from the user's, so code
;; that blocks cannot freeze theirs.  The Emacs a client lent the
;; harness evaluates nothing: the `emacs_*' tools read and drive it
;; with a fixed vocabulary of bounded requests.  The background child
;; reports its result with `harness-elisp-payload', which one function
;; words.

;;;; A copy of the user's Emacs

(defconst harness-tools-shell--snapshot-options '(:read-only t :network nil)
  "The sandbox options of an elisp call that starts from a copy of the user's Emacs.
Whatever the session otherwise has, such a child reads, changes nothing
but its own call's directory and reaches no network: the copy is the
user's data.  They ask for the sandbox, so a child that cannot have it
is refused, whatever `harness-sandbox-policy' says.")

(defconst harness-tools-shell--snapshot-seconds 8
  "Seconds the harness takes at most to fetch a copy of the user's Emacs.
A copy not whole by then is used as it is, and the result says so.")

(defconst harness-tools-shell--snapshot-request-seconds 4
  "Seconds the user's Emacs has to answer one slice of the copy.")

(defconst harness-tools-shell--snapshot-ttl 60
  "Seconds a copy of the user's Emacs is kept for the next call of its session.
`fresh' asks for a new one.")

(defconst harness-tools-shell--snapshot-load-seconds 20
  "Seconds, besides its timeout, a child has to read the copy.")

(defvar harness-tools-shell--snapshots nil
  "The copies kept, newest first: (SESSION-ID TIME . SNAPSHOT).
SNAPSHOT is a plist of `:text', `:partial' (a reason, or nil) and
`:taken' (a time).")

(defun harness-tools-shell--snapshot-sandbox-options (options)
  "Return OPTIONS, the sandbox options of a call, made read-only and offline.
Capabilities are taken off, as for any command that changes nothing."
  (harness-plist-merge (harness-plist-remove options :capabilities)
                       harness-tools-shell--snapshot-options))

(defun harness-tools-shell--snapshot-fetch ()
  "Ask the user's Emacs for a copy of itself, slice by slice; return a promise.
It resolves to a plist: `:text' (the forms of the copy), `:partial' (why
it is not whole, or nil), `:taken' (the time) and `:slices'.  It rejects
when the Emacs gives nothing at all.  A copy that stops short, because
the time allowed (`harness-tools-shell--snapshot-seconds') ran out or the
Emacs stopped answering, is resolved as it is, marked partial."
  (harness-with-promise (resolve reject)
    (let ((deadline (+ (float-time) harness-tools-shell--snapshot-seconds))
          (chunks nil) (cursor nil) (slices 0))
      (cl-labels
          ((finish (partial)
             (when (and partial cursor)
               ;; The user's Emacs keeps what the cursor stands for for a minute: let it go.
               (ignore-errors
                 (harness-then (harness-tools-ask-emacs "snapshot" (list :cursor cursor :release t) 2)
                               #'ignore #'ignore)))
             (funcall resolve
                      (list :text (apply #'concat (append (reverse chunks)
                                                          (and partial (list (format "(partial %S)\n" partial)))))
                            :partial partial :taken (float-time) :slices slices)))
           (step ()
             (let ((left (- deadline (float-time))))
               (if (< left 0.1)
                   (finish "the time allowed for taking the copy ran out")
                 (harness-then
                  (harness-tools-ask-emacs
                   "snapshot"
                   (append (and cursor (list :cursor cursor)) (list :maxChars (* 256 1024)))
                   (min left harness-tools-shell--snapshot-request-seconds))
                  (lambda (answer)
                    (cl-incf slices)
                    (push (or (plist-get answer :chunk) "") chunks)
                    (setq cursor (plist-get answer :next))
                    (if (or (harness-json-true-p (plist-get answer :done)) (null cursor))
                        (finish nil)
                      (step)))
                  (lambda (err)
                    (if chunks
                        (finish (format "the user's Emacs stopped answering: %s"
                                        (harness-tools-reason err)))
                      (funcall reject err))))))))
        (step)))))

(defun harness-tools-shell--snapshot (ctx fresh)
  "Return a promise of a copy of the user's Emacs for the call under CTX.
It is the copy kept for CTX's session if that is younger than
`harness-tools-shell--snapshot-ttl' seconds and FRESH is nil, else a new
one (`harness-tools-shell--snapshot-fetch'), which is kept.  The plist
it resolves to has `:cached' besides what the fetch gives."
  (let* ((key (or (plist-get ctx :session-id) ""))
         (now (float-time))
         (kept (cl-remove-if (lambda (entry) (> (- now (cadr entry)) harness-tools-shell--snapshot-ttl))
                             harness-tools-shell--snapshots))
         (entry (assoc key kept)))
    (setq harness-tools-shell--snapshots kept)
    (if (and entry (not fresh))
        (harness-resolved (append (list :cached t) (cddr entry)))
      (harness-then
       (harness-tools-shell--snapshot-fetch)
       (lambda (snapshot)
         (setq harness-tools-shell--snapshots
               (seq-take (cons (cons key (cons (float-time) snapshot))
                               (assoc-delete-all key harness-tools-shell--snapshots))
                         3))
         (append (list :cached nil) snapshot))))))

(defun harness-tools-shell--snapshot-note (snapshot)
  "Return what to tell the model about SNAPSHOT, the report of the child, or nil.
Nothing, when the copy was loaded whole; why not, when it was not."
  (let ((partial (plist-get snapshot :partial))
        (error (plist-get snapshot :error)))
    (cond
     ((and (stringp error) (not (string-empty-p error)))
      (format "The copy of the user's Emacs is not usable: %s." error))
     ((and (stringp partial) (not (string-empty-p partial)))
      (format "The copy of the user's Emacs is partial: %s.  (harness-snapshot-info) says what it holds."
              partial)))))

(defun harness-tools-shell--elisp-timeout (input)
  "Return the seconds a call of the elisp tool with INPUT may evaluate for."
  (let ((timeout (or (harness-tools-shell--number (plist-get input :timeout) harness-elisp--timeout)
                     harness-elisp--timeout)))
    (max 1 (min timeout harness-tools-shell--max-timeout))))

(defun harness-tools-shell--elisp-payload-result (payload meta)
  "Turn PAYLOAD, the report of an evaluation, into an elisp tool result with META.
PAYLOAD is what `harness-elisp-payload' returns, as the background
Emacs wrote it or the user's Emacs answered it."
  (let* ((error (and (listp payload) (plist-get payload :error)))
         (snapshot (and (listp payload) (plist-get payload :snapshot)))
         (meta (if snapshot (append (list :snapshot (append (plist-get meta :snapshot) snapshot))
                                    (harness-plist-remove meta :snapshot))
                 meta)))
    (cond
     ((not (and payload (listp payload)))
      (harness-tool-error "Evaluation produced an unreadable result" :meta meta))
     ((and (stringp error) (not (string-empty-p error)))
      (harness-tool-error (format "Error: %s" error) :meta meta))
     (t
      (harness-tool-ok (harness-elisp-format-result (or (plist-get payload :value) "")
                                                    (or (plist-get payload :output) "")
                                                    (or (plist-get payload :messages) "")
                                                    (harness-tools-shell--snapshot-note snapshot))
                       :meta meta)))))

(defun harness-tools-shell--elisp-batch-result (r result-file timeout &optional meta)
  "Turn R, a `harness-run-command' result, into an elisp tool result.
RESULT-FILE is the JSON the child wrote; TIMEOUT names the evaluation's
limit in the message a killed child gets; META goes into the result's
own.  Only a regular file is read: the child, which may run in the
sandbox, could leave a symbolic link there instead, and this Emacs,
which runs outside, would read whatever it names, or a named pipe it
would wait on for good."
  (let* ((exit (plist-get r :exit))
         (meta (append (list :emacs "background" :exit exit) meta)))
    (cond
     ((eq exit 'timeout)
      (harness-tool-error (format "Evaluation timed out after %ss" timeout) :meta meta))
     ((not (and (file-regular-p result-file) (not (file-symlink-p result-file))))
      (harness-tool-error
       (format "Evaluation produced no result (exit %s): %s"
               exit (string-trim (or (plist-get r :stderr) "")))
       :meta meta))
     (t
      (harness-tools-shell--elisp-payload-result
       (condition-case err
           (harness-json-parse (with-temp-buffer (insert-file-contents result-file) (buffer-string)))
         (error (harness-log 'warn "elisp: unreadable result: %S" err) nil))
       meta)))))

(defun harness-tools-shell--emacs-dirs ()
  "Return the directories outside /usr the background Emacs reads itself from.
They are where `harness-elisp-emacs' is, symbolic links followed, and,
when that is this Emacs, where this one keeps its Lisp, its data, its
helper programs and its native code.  The sandbox shows /usr anyway;
an Emacs installed elsewhere, in the home directory say, or run from
its source tree, starts in there only once these are shown."
  (let* ((program (expand-file-name harness-elisp-emacs))
         (real (file-truename program))
         (this (file-truename (expand-file-name invocation-name invocation-directory)))
         (eln (car (last (bound-and-true-p native-comp-eln-load-path))))
         (dirs (append (list (file-name-directory program) (file-name-directory real))
                       (and (equal real this)
                            (list invocation-directory data-directory exec-directory
                                  (bound-and-true-p lisp-directory)
                                  ;; The last is the Emacs's own; the first, the
                                  ;; user's cache in the home directory.
                                  (and (stringp eln) (expand-file-name eln invocation-directory)))))))
    (delete-dups
     (delq nil (mapcar (lambda (dir)
                         (and (stringp dir) (file-directory-p dir)
                              (let ((dir (file-name-as-directory (expand-file-name dir))))
                                (and (not (string-prefix-p "/usr/" dir)) dir))))
                       dirs)))))

(defun harness-tools-shell--harness-files ()
  "Return the harness files the background Emacs loads: harness.el and lisp/.
Of `harness-directory' only these are shown to it, not the whole
checkout: the scripts/.dev of a checkout holds the state of the
instances scripts/dev.sh runs from it, and their sockets, over which
whatever reaches them evaluates Lisp outside the sandbox."
  (list (expand-file-name "harness.el" harness-directory)
        (file-name-as-directory (expand-file-name "lisp" harness-directory))))

(defun harness-tools-shell-child-dirs ()
  "Return what a background Emacs of the harness must be shown to start.
Those are `harness-tools-shell--harness-files' and
`harness-tools-shell--emacs-dirs': the harness's Lisp, read-only, and
the Emacs it runs.  The elisp tool's child is shown them, and so is the
file tools' worker (lisp/harness-mcp-fs.el): a process the harness
starts in the sandbox, whose program is the harness's own."
  (append (harness-tools-shell--harness-files) (harness-tools-shell--emacs-dirs)))

(defun harness-tools-shell--elisp-command (child env cwd io ctx &optional snapshot)
  "Return the command line that runs CHILD, the background Emacs, under CTX.
ENV is the alist of environment variables CHILD reads, CWD where it
runs and IO the directory of its code and its result.  It goes through
the sandbox as a bash command of CTX's session does
\(`harness-tools-shell--wrap'): it is shown the same directories, with
the same `tools/sandbox-options', and fails the same way when it may
not run unconfined.  It is shown besides the harness
\(`harness-tools-shell--harness-files') and the Emacs it runs
\(`harness-tools-shell--emacs-dirs') read-only, and IO writable
whatever the options say, so that it can report even when it is
`:read-only'.  Unwrapped, as without the sandbox module, the command
line is CHILD itself, run with ENV as it always was; in the sandbox
`env' sets ENV first, since systemd-run passes none of the harness's
environment on.  Signals an error when CHILD may not run.  A SNAPSHOT
call runs read-only and offline (`harness-tools-shell--snapshot-options')
whatever the options say, and signals the same error where no sandbox
can give that."
  (let* ((options (let ((options (harness-tools-shell--sandbox-options ctx)))
                    (if snapshot (harness-tools-shell--snapshot-sandbox-options options) options)))
         (dirs (harness-tools-shell--session-dirs ctx))
         (in-env (append (list "env")
                         (mapcar (lambda (v) (concat (car v) "=" (cdr v))) env)
                         child))
         (wrapped (harness-tools-shell--wrap
                   cwd in-env
                   (delete-dups (delq nil (cons (harness-tools-shell--tmp-dir ctx) (car dirs))))
                   (append (harness-tools-shell--skill-dirs ctx) (cdr dirs)
                           (harness-tools-shell--harness-files) (harness-tools-shell--emacs-dirs))
                   options (list io))))
    (if (eq wrapped in-env) child wrapped)))

(defun harness-tools-shell--elisp-batch (code input ctx &optional snapshot)
  "Evaluate CODE for the elisp tool in a background Emacs; return a promise.
With SNAPSHOT, a plist (`:fresh' says not to use a kept copy), the child
starts from a copy of the user's Emacs, read-only and offline.
INPUT and CTX supply the working directory and the timeout; the child
adds the harness to its `load-path' so `(require \='harness-...)' works
as it did when the code ran in the harness's own Emacs.  It runs apart
from the user's Emacs, so code that blocks cannot freeze that, and it
is killed, tree and all, when it overruns.  It runs in the sandbox as
a bash command of the session does (see
`harness-tools-shell--elisp-command'): an error that keeps it from
running there is returned at once as the tool's error, instead of a
promise, and it does not run.

The call has a directory of its own, whose io/ holds the code and the
result.  The child runs on this machine whatever the session's
directory is, so a remote session's code runs in the call's own
directory."
  (let* ((cwd (harness-tools-shell--bash-cwd input ctx))
         (dir (file-name-as-directory (make-temp-file "harness-elisp-" t)))
         (io (expand-file-name "io/" dir))
         (cwd (if (file-remote-p cwd) dir cwd))
         (code-file (expand-file-name "code.el" io))
         (result-file (expand-file-name "result.json" io))
         (timeout (harness-tools-shell--elisp-timeout input))
         (child (list harness-elisp-emacs "--batch" "-Q"
                      "-L" harness-directory
                      "-L" (expand-file-name "lisp" harness-directory)
                      "-l" (expand-file-name "lisp/harness-elisp.el" harness-directory)
                      "-f" "harness-elisp-batch-main"))
         (snapshot-file (and snapshot (expand-file-name "snapshot.eld" io)))
         (env (append (list (cons "HARNESS_ELISP_CODE" code-file)
                            (cons "HARNESS_ELISP_RESULT" result-file)
                            (cons "HARNESS_ELISP_TIMEOUT" (number-to-string timeout))
                            (cons "HARNESS_ELISP_MAX_VALUE_CHARS"
                                  (number-to-string harness-elisp--max-value-chars)))
                      (and snapshot (list (cons "HARNESS_ELISP_SNAPSHOT" snapshot-file)))))
         cmd)
    ;; The call's directory is ours to delete from here on, whatever fails
    ;; before the command that uses it starts: a full /tmp, say.
    (condition-case err
        (progn
          (with-file-modes #o700 (make-directory io))
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region code nil code-file nil 'silent)
            (set-file-modes code-file #o600)))
      (error (ignore-errors (delete-directory dir t))
             (signal (car err) (cdr err))))
    ;; The command comes first: where it may not run, nothing is asked of the
    ;; user's Emacs, and no copy of it is made.
    (setq cmd (condition-case err
                  (harness-tools-shell--elisp-command child env cwd io ctx snapshot)
                (error (list :error (harness-error-message err)))))
    (if (eq (car-safe cmd) :error)
        (progn
          (ignore-errors (delete-directory dir t))
          (harness-tool-error (format "Cannot evaluate: %s" (plist-get cmd :error))))
      (harness-with-promise (resolve reject)
        (ignore reject)
        (let* ((settled nil)
               (meta (list :sandboxed (not (eq cmd child))))
               (finish (lambda (result)
                         (unless settled
                           (setq settled t)
                           (ignore-errors (delete-directory dir t))
                           (funcall resolve result)))))
          (cl-flet
              ((run (extra)
                 (let ((meta (append meta extra)))
                   (harness-then
                    (harness-run-command cmd :cwd cwd :name "harness-elisp" :env env
                                         :timeout (+ timeout 5 (if snapshot harness-tools-shell--snapshot-load-seconds 0)))
                    (lambda (r) (funcall finish (harness-tools-shell--elisp-batch-result r result-file timeout meta)))
                    (lambda (e) (funcall finish (harness-tool-error
                                                 (format "elisp failed: %s" (harness-error-message e))
                                                 :meta meta)))))))
            (if (not snapshot)
                (run nil)
              (harness-then
               (harness-tools-shell--snapshot ctx (plist-get snapshot :fresh))
               (lambda (copy)
                 (condition-case err
                     (progn
                       (let ((coding-system-for-write 'utf-8-unix))
                         (write-region (plist-get copy :text) nil snapshot-file nil 'silent))
                       (set-file-modes snapshot-file #o600)
                       (run (list :snapshot (list :cached (and (plist-get copy :cached) t)
                                                  :partial (plist-get copy :partial)
                                                  :taken (plist-get copy :taken)
                                                  :chars (length (plist-get copy :text))))))
                   (error (funcall finish (harness-tool-error
                                           (format "Cannot start from a copy of the user's Emacs: %s"
                                                   (harness-error-message err))
                                           :meta meta)))))
               (lambda (err)
                 (funcall finish (harness-tool-error
                                  (format "Cannot take a copy of the user's Emacs: %s.  Run the code without snapshot, or read it with the emacs_* tools."
                                          (harness-tools-reason err))
                                  :meta meta)))))))))))

(defun harness-tools-shell--elisp (input ctx)
  "Handler for the elisp tool with INPUT under CTX; returns a promise.
The code always evaluates in a background Emacs, so a call that asks
for the user's Emacs is refused with that explanation."
  (let ((code (plist-get input :code))
        (where (plist-get input :emacs))
        (snapshot (harness-json-true-p (plist-get input :snapshot))))
    (cond
     ((or (not (stringp code)) (string-blank-p code))
      (harness-tool-error "Missing code"))
     ((and (stringp where)
           (not (string-empty-p where))
           (not (equal where "background")))
      (harness-tool-error
       (format "The elisp tool never evaluates in the user's Emacs (%S): it always evaluates in a background Emacs. Read or drive the user's Emacs with the emacs_* tools instead."
               where)))
     (t (harness-tools-shell--elisp-batch
         code input ctx
         (and snapshot (list :fresh (harness-json-true-p (plist-get input :fresh)))))))))

(harness-define-tool "elisp"
  :label "Emacs Lisp"
  :description "Evaluate Emacs Lisp with lexical binding in a fresh background Emacs process, never the user's: its working directory is the working directory, its load path has the harness, so a harness library can be required to inspect or drive it, and it is killed at timeout seconds (30 by default). Use it as the Emacs-native alternative to bash for file work, such as a dired-style batch rename; it may run in the same sandbox as bash commands, and sees what they see and has what they have (no Linux capability unless the user gave this session some: request_escalation, attribute capability). Read or drive the user's live Emacs with the emacs_* tools instead. Returns the value of the last form, anything printed to standard-output, and messages logged during evaluation. With snapshot the process starts from a copy of the user's Emacs: the values of its variables and its buffers (name, mode, file, directory, point, text), to compute over. The code can change the copy and never the user's Emacs; the process then runs read-only and offline, whatever the session otherwise has, and is refused where no sandbox can give that. Credentials are left out of the copy by the names of variables and buffers, and the copy says what it left out: (harness-snapshot-info). The variables the process needs for itself, hooks and every variable that holds a function keep the process's own value: read the user's with (harness-user-value 'load-path)."
  :schema '(:type "object"
            :properties (:code (:type "string" :description "One or more Emacs Lisp forms")
                         :timeout (:type "integer" :description "Seconds before the evaluation is stopped. Default 30")
                         :snapshot (:type "boolean" :description "Start from a copy of the user's Emacs (its variables and buffers, credentials left out), read-only and offline. Default false")
                         :fresh (:type "boolean" :description "With snapshot: take a new copy now instead of the one kept for the last minute. Default false"))
            :required ("code"))
  :kind 'exec
  :timeout 3700
  :subject (lambda (input) (harness-first-line (plist-get input :code) 70))
  :handler #'harness-tools-shell--elisp)

(harness-define-module 'tools-shell
  :doc "Bash (asynchronous, sandboxed when available) and Emacs Lisp evaluation."
  :requires '(tools))

(provide 'harness-tools-shell)
;;; harness-tools-shell.el ends here
