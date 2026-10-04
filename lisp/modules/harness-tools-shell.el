;;; harness-tools-shell.el --- bash and elisp tools  -*- lexical-binding: t; -*-

;;; Commentary:

;; Two ways for a model to run things:
;;
;; - `bash' runs a command through `bash -c' as an asynchronous
;;   process (`harness-run-command'), in the session's working
;;   directory or a subdirectory of it.  When the sandbox module is
;;   loaded and the directory is local, the command line is wrapped
;;   with `sandbox/wrap' so it runs confined; a `required' policy
;;   without a backend turns into a tool error rather than an
;;   unconfined run.  The session's own temporary directory
;;   (`session/tmp-dir') is writable in there too, at its real path:
;;   the sandbox's /tmp is private and empty for every command, so
;;   that directory is where commands leave files for later ones and
;;   for the other tools.  Remote (TRAMP) directories run the command
;;   on that host, unwrapped.
;;
;; - `elisp' evaluates Emacs Lisp, the Emacs-native alternative to a
;;   shell: the value of the last form, anything printed to
;;   `standard-output' and any `message' calls come back.  It evaluates
;;   in a child `emacs --batch' process, never the user's Emacs, where
;;   model-written code could block the UI beyond recovery (see
;;   harness-elisp.el); a timeout kills the child, its whole process
;;   group included.  The user's Emacs answers no request that
;;   evaluates code, whatever anyone configures; it is read and driven
;;   with the bounded `emacs_*' tools (tools-emacs).  The tool itself
;;   runs here, in the harness, like every tool.

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

(defun harness-tools-shell--wrap (cwd command &optional writable)
  "Return COMMAND wrapped by the sandbox for CWD when the sandbox module is loaded.
WRITABLE lists other directories the command may write to."
  (if (and (harness-method-exists-p 'sandbox/wrap) (not (file-remote-p cwd)))
      (harness-call 'sandbox/wrap cwd command :writable writable)
    command))

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
      (let ((cmd (condition-case err
                     ;; Not a login shell: the harness already has the user's
                     ;; environment, and a login profile's side effects (starting
                     ;; an ssh-agent, importing keys) go wrong in a sandbox, whose
                     ;; PID namespace hides the user's processes from it.
                     (harness-tools-shell--wrap cwd (list harness-tools-shell--program "-c" command)
                                                (delq nil (list (harness-tools-shell--tmp-dir ctx))))
                   (error (list :error (harness-error-message err))))))
        (if (and (consp cmd) (eq (car cmd) :error))
            (harness-tool-error (format "Cannot run command: %s" (plist-get cmd :error)))
          (let ((started (float-time)))
            (harness-then
             (harness-run-command cmd :cwd cwd :timeout timeout :name "harness-bash"
                                  :on-output (and report (lambda (chunk) (funcall report chunk))))
             (lambda (r)
               (let ((exit (plist-get r :exit)))
                 (funcall (if (eql exit 0) #'harness-tool-ok #'harness-tool-error)
                          (harness-tools-shell--format-output r timeout)
                          :meta (list :exit exit :cwd cwd
                                      :duration (- (float-time) started)
                                      :sandboxed (not (equal (car cmd) harness-tools-shell--program))))))))))))))

(harness-define-tool "bash"
  :label "Bash"
  :description "Run a shell command with bash in the working directory (or a subdirectory). Output is stdout, then stderr if any, then the exit status. Long jobs are killed at timeout seconds (default 120). Prefer read_file, grep, glob and edit_file over cat, grep, find and sed."
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
;; harness answers no evaluation request at all
;; (lisp/harness-emacs-endpoint.el): the `emacs_*' tools are the whole
;; of what a model may do to the live Emacs.  The background child
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
The code always evaluates in a background Emacs; the user's Emacs
answers no request that evaluates code, so a call that asks for it is
refused with that explanation."
  (let ((code (plist-get input :code))
        (where (plist-get input :emacs)))
    (cond
     ((or (not (stringp code)) (string-blank-p code))
      (harness-tool-error "Missing code"))
     ((and (stringp where)
           (not (string-empty-p where))
           (not (equal where "background")))
      (harness-tool-error
       (format "The elisp tool never evaluates in the user's Emacs (%S): it always evaluates in a background Emacs. Read or drive the user's Emacs with the emacs_* tools instead."
               where)))
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
