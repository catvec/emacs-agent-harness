;;; harness-tools-shell.el --- bash and elisp tools  -*- lexical-binding: t; -*-

;;; Commentary:

;; Two ways for a model to run things:
;;
;; - `bash' runs a command through `bash -lc' as an asynchronous
;;   process (`harness-run-command'), in the session's working
;;   directory or a subdirectory of it.  When the sandbox module is
;;   loaded and the directory is local, the command line is wrapped
;;   with `sandbox/wrap' so it runs confined; a `required' policy
;;   without a backend turns into a tool error rather than an
;;   unconfined run.  Remote (TRAMP) directories run the command on
;;   that host, unwrapped.
;;
;; - `elisp' evaluates Emacs Lisp inside the harness Emacs, which is
;;   the Emacs-native alternative to a shell: the value of the last
;;   form, anything printed to `standard-output' and any `message'
;;   calls are returned.  Evaluation is synchronous by nature; it is
;;   capped with `with-timeout', which can interrupt code that yields
;;   to the event loop but not a tight loop.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pp)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)
(require 'harness-client-tools)

(defcustom harness-bash-program "bash"
  "Shell used by the bash tool."
  :type 'string :group 'harness)

(defcustom harness-bash-default-timeout 120
  "Seconds a bash command may run when the model gives no timeout."
  :type 'number :group 'harness)

(defcustom harness-bash-max-timeout 3600
  "Upper bound for the timeout a model may request for a bash command."
  :type 'number :group 'harness)

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

(defun harness-tools-shell--wrap (cwd command)
  "Return COMMAND wrapped by the sandbox for CWD when the sandbox module is loaded."
  (if (and (harness-method-exists-p 'sandbox/wrap) (not (file-remote-p cwd)))
      (harness-call 'sandbox/wrap cwd command)
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
         (timeout (min harness-bash-max-timeout
                       (max 1 (harness-tools-shell--number (plist-get input :timeout)
                                                           harness-bash-default-timeout))))
         (cwd (harness-tools-shell--bash-cwd input ctx))
         (report (plist-get ctx :report)))
    (cond
     ((or (not (stringp command)) (string-blank-p command))
      (harness-tool-error "Missing command"))
     ((not (file-directory-p cwd))
      (harness-tool-error (format "Working directory does not exist: %s" cwd)))
     (t
      (let ((cmd (condition-case err
                     (harness-tools-shell--wrap cwd (list harness-bash-program "-lc" command))
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
                                      :sandboxed (not (equal (car cmd) harness-bash-program))))))))))))))

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

(harness-define-tool "elisp"
  :label "Emacs Lisp"
  :description "Evaluate Emacs Lisp in the running Emacs (lexical binding). Returns the value of the last form, anything printed to standard-output, and messages logged during evaluation. Use it to inspect or drive Emacs, or as an alternative to bash for file work."
  :schema '(:type "object"
            :properties (:code (:type "string" :description "One or more Emacs Lisp forms"))
            :required ("code"))
  :kind 'exec
  :subject (lambda (input) (harness-first-line (plist-get input :code) 70))
  :handler (harness-tools-in-client "elisp"))

(harness-define-module 'tools-shell
  :doc "Bash (asynchronous, sandboxed when available) and Emacs Lisp evaluation."
  :requires '(tools))

(provide 'harness-tools-shell)
;;; harness-tools-shell.el ends here
