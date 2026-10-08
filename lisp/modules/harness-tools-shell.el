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
;;   filter `tools/sandbox-options' runs before each command, with the
;;   value nil and the session id as its argument.  A handler returns
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
;;   Remote (TRAMP) directories run the command on that host,
;;   unwrapped, as the ssh tool does (tools-ssh): through
;;   `harness-tools-shell-remote-command', with bash, or sh on a host
;;   that has none, and standard input from /dev/null.  TRAMP runs a
;;   remote process on a pty that never passes the end of input on, so
;;   a command reading its input would wait for its timeout.
;;
;; - `elisp' evaluates Emacs Lisp, the Emacs-native alternative to a
;;   shell: the value of the last form, anything printed to
;;   `standard-output' and any `message' calls come back.  It evaluates
;;   in a child `emacs --batch' process, never the user's Emacs, where
;;   model-written code could block the UI beyond recovery (see
;;   harness-elisp.el); a timeout kills the child, its whole process
;;   group included.  The user's Emacs is read and driven with the
;;   bounded `emacs_*' tools (tools-emacs); only emacs_eval
;;   (tools-emacs-eval) evaluates there, when a judge model expects the
;;   code to return at once and the user did not turn it off with
;;   `harness-emacs-eval'.  The tool itself runs here, in the harness,
;;   like every tool.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pp)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)
(require 'harness-elisp)

(declare-function harness-emacs-eval-p "harness-emacs-endpoint" ())

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
READABLE.  Both are nil without the permissions module or for a
remote session, whose commands run on another host.  A glob pattern
among the grants names no directory, and the sandbox leaves it out."
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
                  (if (eq (plist-get e :source) 'outputs)
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
  "Return the extra `sandbox/wrap' options a bash call under CTX must run with.
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

(defun harness-tools-shell--wrap-options (writable readable options)
  "Return the `sandbox/wrap' options for the directories WRITABLE and READABLE.
OPTIONS, the plist of extra ones, go with them, and its own `:writable'
and `:readable' directories join the lists.  With `:read-only' in
OPTIONS none is writable: all the directories go as readable, so that
the command is shown what its session may touch and changes none of it."
  (let ((writable (append writable (plist-get options :writable)))
        (readable (append readable (plist-get options :readable))))
    (when (harness-json-true-p (plist-get options :read-only))
      (setq readable (delete-dups (append writable readable))
            writable nil))
    (append (list :writable writable :readable readable)
            (cl-loop for (key value) on options by #'cddr
                     unless (memq key '(:writable :readable)) append (list key value)))))

(defun harness-tools-shell--refuse-unconfined (options why)
  "Signal an error: a command that needs sandbox OPTIONS cannot have the sandbox.
WHY says what stands in the way."
  (error "A command that needs the sandbox options %S cannot run unconfined, but %s"
         options why))

(defun harness-tools-shell--wrap (cwd command &optional writable readable options)
  "Return COMMAND wrapped by the sandbox for CWD when the sandbox module is loaded.
WRITABLE lists other directories the command may write to, READABLE
directories it may read.  OPTIONS are the extra `sandbox/wrap' options
asked for (see `harness-tools-shell--sandbox-options'); they are given
to it with the directories (see `harness-tools-shell--wrap-options').
Without the sandbox module a `required' `harness-sandbox-policy'
signals an error rather than letting COMMAND run unconfined, as the
sandbox does when it has no backend.  OPTIONS ask for the sandbox
whatever the policy: the error comes too when the module is not loaded
or CWD is remote."
  (cond
   ((and options (file-remote-p cwd))
    (harness-tools-shell--refuse-unconfined
     options (format "%s is on another host, where the sandbox does not reach" cwd)))
   ((file-remote-p cwd) command)
   ((harness-method-exists-p 'sandbox/wrap)
    (apply #'harness-call 'sandbox/wrap cwd command
           (harness-tools-shell--wrap-options writable readable options)))
   (options
    (harness-tools-shell--refuse-unconfined options "the sandbox module is not loaded"))
   ((harness-tools-shell--sandbox-required-p cwd)
    (error "The sandbox is required (harness-sandbox-policy), but the sandbox module is not loaded"))
   (t command)))

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

(defun harness-tools-shell--bash (input ctx)
  "Handler for the bash tool with INPUT under CTX; returns a promise."
  (let* ((command (plist-get input :command))
         (timeout (min harness-tools-shell--max-timeout
                       (max 1 (harness-tools-shell--number (plist-get input :timeout)
                                                           harness-tools-shell--default-timeout))))
         (cwd (harness-tools-shell--bash-cwd input ctx))
         (report (plist-get ctx :report)))
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
            (harness-then
             (harness-run-command cmd :cwd cwd :timeout timeout :name "harness-bash"
                                  :merge-remote-stderr t
                                  :on-output (and report (lambda (chunk) (funcall report chunk))))
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
  :description "Run a shell command with bash in the working directory (or a subdirectory). Output is stdout, then stderr if any, then the exit status. Long jobs are killed at timeout seconds (default 120). Prefer read_file, grep, glob and edit_file over cat, grep, find and sed. Commands may run in a sandbox that shows the system directories and only the directories the session may use (the working directory, its temporary directory, the directories granted to it), each at its real path; anything else, the rest of the home directory included, looks missing there, so reach it with the file tools, which ask the user."
  :schema '(:type "object"
            :properties (:command (:type "string" :description "The command line to run")
                         :timeout (:type "integer" :description "Seconds before the command is killed. Default 120")
                         :cwd (:type "string" :description "Directory to run in, relative to the working directory. Default: the working directory"))
            :required ("command"))
  :kind 'exec
  :timeout 3700
  :paths (lambda (input) (list (or (plist-get input :cwd) ".")))
  :subject (lambda (input) (harness-first-line (plist-get input :command) 70))
  :handler #'harness-tools-shell--bash)

;;;; elisp

;; The tool runs here, in the harness, like every tool, and always
;; evaluates in a fresh background Emacs, apart from the user's, so code
;; that blocks cannot freeze theirs.  The Emacs a client lent the
;; harness evaluates only for emacs_eval (tools-emacs-eval), which runs
;; only code a judge expects to return at once, unless the user turned
;; it off with `harness-emacs-eval'; the other `emacs_*' tools read and
;; drive it without evaluating anything.  The background child
;; reports its result with `harness-elisp-payload', which one function
;; words.

(defun harness-tools-shell--elisp-timeout (input)
  "Return the seconds a call of the elisp tool with INPUT may evaluate for."
  (let ((timeout (or (harness-tools-shell--number (plist-get input :timeout) harness-elisp--timeout)
                     harness-elisp--timeout)))
    (max 1 (min timeout harness-tools-shell--max-timeout))))

(defun harness-tools-shell--elisp-payload-result (payload meta)
  "Turn PAYLOAD, the report of an evaluation, into an elisp tool result with META.
PAYLOAD is what `harness-elisp-payload' returns, as the background
Emacs wrote it or the user's Emacs answered it."
  (let ((error (and (listp payload) (plist-get payload :error))))
    (cond
     ((not (and payload (listp payload)))
      (harness-tool-error "Evaluation produced an unreadable result" :meta meta))
     ((and (stringp error) (not (string-empty-p error)))
      (harness-tool-error (format "Error: %s" error) :meta meta))
     (t
      (harness-tool-ok (harness-elisp-format-result (or (plist-get payload :value) "")
                                                    (or (plist-get payload :output) "")
                                                    (or (plist-get payload :messages) ""))
                       :meta meta)))))

(defun harness-tools-shell--elisp-batch-result (r result-file timeout)
  "Turn R, a `harness-run-command' result, into an elisp tool result.
RESULT-FILE is the JSON the child wrote; TIMEOUT names the evaluation's
limit in the message a killed child gets."
  (let* ((exit (plist-get r :exit))
         (meta (list :emacs "background" :exit exit)))
    (cond
     ((eq exit 'timeout)
      (harness-tool-error (format "Evaluation timed out after %ss" timeout) :meta meta))
     ((not (file-readable-p result-file))
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

(defun harness-tools-shell--elisp-batch (code input ctx)
  "Evaluate CODE for the elisp tool in a background Emacs; return a promise.
INPUT and CTX supply the working directory and the timeout; the child
adds the harness to its `load-path' so `(require \='harness-...)' works
as it did when the code ran in the harness's own Emacs.  It runs apart
from the user's Emacs, so code that blocks cannot freeze that, and it
is killed, tree and all, when it overruns."
  (let* ((cwd (harness-tools-shell--bash-cwd input ctx))
         (cwd (if (file-remote-p cwd) default-directory cwd))
         (dir (make-temp-file "harness-elisp-" t))
         (code-file (expand-file-name "code.el" dir))
         (result-file (expand-file-name "result.json" dir))
         (timeout (harness-tools-shell--elisp-timeout input)))
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region code nil code-file nil 'silent)
      (set-file-modes code-file #o600))
    (harness-with-promise (resolve reject)
      (ignore reject)
      (let* ((settled nil)
             (finish (lambda (result)
                       (unless settled
                         (setq settled t)
                         (ignore-errors (delete-directory dir t))
                         (funcall resolve result)))))
        (harness-then
         (harness-run-command
          (list harness-elisp-emacs "--batch" "-Q"
                "-L" harness-directory
                "-L" (expand-file-name "lisp" harness-directory)
                "-l" (expand-file-name "lisp/harness-elisp.el" harness-directory)
                "-f" "harness-elisp-batch-main")
          :cwd cwd
          :timeout (+ timeout 5)
          :name "harness-elisp"
          :env (list (cons "HARNESS_ELISP_CODE" code-file)
                     (cons "HARNESS_ELISP_RESULT" result-file)
                     (cons "HARNESS_ELISP_TIMEOUT" (number-to-string timeout))
                     (cons "HARNESS_ELISP_MAX_VALUE_CHARS"
                           (number-to-string harness-elisp--max-value-chars))))
         (lambda (r) (funcall finish (harness-tools-shell--elisp-batch-result r result-file timeout)))
         (lambda (e) (funcall finish (harness-tool-error
                                      (format "elisp failed: %s" (harness-error-message e))))))))))

(defun harness-tools-shell--elisp (input ctx)
  "Handler for the elisp tool with INPUT under CTX; returns a promise.
The code always evaluates in a background Emacs, so a call that asks
for the user's Emacs is refused with that explanation, which names
emacs_eval unless the user turned that off (`harness-emacs-eval')."
  (let ((code (plist-get input :code))
        (where (plist-get input :emacs)))
    (cond
     ((or (not (stringp code)) (string-blank-p code))
      (harness-tool-error "Missing code"))
     ((and (stringp where)
           (not (string-empty-p where))
           (not (equal where "background")))
      (harness-tool-error
       (format "The elisp tool never evaluates in the user's Emacs (%S): it always evaluates in a background Emacs. Read or drive the user's Emacs with the emacs_* tools instead%s."
               where
               (if (and (fboundp 'harness-emacs-eval-p) (harness-emacs-eval-p))
                   "; emacs_eval evaluates code there that returns at once"
                 ""))))
     (t (harness-tools-shell--elisp-batch code input ctx)))))

(harness-define-tool "elisp"
  :label "Emacs Lisp"
  :description "Evaluate Emacs Lisp with lexical binding in a fresh background Emacs process, never the user's: its working directory is the working directory, its load path has the harness, so a harness library can be required to inspect or drive it, and it is killed at timeout seconds (30 by default). Use it as the Emacs-native alternative to bash for file work, such as a dired-style batch rename. Read or drive the user's live Emacs with the emacs_* tools instead. Returns the value of the last form, anything printed to standard-output, and messages logged during evaluation."
  :schema '(:type "object"
            :properties (:code (:type "string" :description "One or more Emacs Lisp forms")
                         :timeout (:type "integer" :description "Seconds before the evaluation is stopped. Default 30"))
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
