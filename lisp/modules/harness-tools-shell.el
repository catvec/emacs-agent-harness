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

(defcustom harness-bash-program "bash"
  "Shell used by the bash tool."
  :type 'string :group 'harness)

(defcustom harness-bash-default-timeout 120
  "Seconds a bash command may run when the model gives no timeout."
  :type 'number :group 'harness)

(defcustom harness-bash-max-timeout 3600
  "Upper bound for the timeout a model may request for a bash command."
  :type 'number :group 'harness)

(defcustom harness-elisp-timeout 30
  "Seconds an elisp evaluation may take before it is abandoned."
  :type 'number :group 'harness)

(defcustom harness-elisp-max-value-chars 10000
  "Printed values longer than this are elided in elisp results."
  :type 'integer :group 'harness)

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
  :description "Run a shell command with bash in the working directory (or a subdirectory). Output is stdout, then stderr if any, then the exit status. Long jobs are killed at timeout seconds (default 120). Prefer read_file, grep, glob and edit_file over cat, grep, find and sed."
  :schema '(:type "object"
            :properties (:command (:type "string" :description "The command line to run")
                         :timeout (:type "integer" :description "Seconds before the command is killed. Default 120")
                         :cwd (:type "string" :description "Directory to run in, relative to the working directory. Default: the working directory"))
            :required ("command"))
  :kind 'exec
  :timeout 3700
  :paths (lambda (input) (list (or (plist-get input :cwd) ".")))
  :title (lambda (input) (format "bash %s" (harness-truncate-end (harness-first-line (plist-get input :command)) 70)))
  :handler #'harness-tools-shell--bash)

;;;; elisp

(defun harness-tools-shell--read-forms (code)
  "Return the list of forms read from CODE."
  (with-temp-buffer
    (insert code)
    (emacs-lisp-mode)
    (goto-char (point-min))
    (let (forms)
      ;; Skip whitespace and comments between forms so a clean end of
      ;; input is told apart from an unterminated form.
      (while (progn (forward-comment (buffer-size)) (not (eobp)))
        (push (condition-case nil
                  (read (current-buffer))
                (end-of-file (error "End of file during parsing: unbalanced form at line %d"
                                    (line-number-at-pos))))
              forms))
      (nreverse forms))))

(defun harness-tools-shell--messages-since (pos)
  "Return the text of *Messages* from POS to the end, trimmed."
  (let ((buf (get-buffer "*Messages*")))
    (if (and buf (buffer-live-p buf))
        (with-current-buffer buf
          (string-trim (buffer-substring-no-properties (min pos (point-max)) (point-max))))
      "")))

(defun harness-tools-shell--messages-end ()
  "Return the current end of *Messages*, or 1 when the buffer is absent."
  (let ((buf (messages-buffer)))
    (with-current-buffer buf (point-max))))

(defun harness-tools-shell--eval (code)
  "Evaluate CODE and return (VALUE OUTPUT MESSAGES).
OUTPUT is what the forms printed to `standard-output'; MESSAGES are
`message' calls logged while they ran."
  (let* ((forms (harness-tools-shell--read-forms code))
         (out (generate-new-buffer " *harness-elisp-out*" t))
         (msg-start (harness-tools-shell--messages-end))
         (value nil))
    (unwind-protect
        (let ((standard-output out)
              (message-log-max t)
              (inhibit-message t)
              (debug-on-error nil))
          (with-timeout (harness-elisp-timeout
                         (error "Evaluation exceeded %ss" harness-elisp-timeout))
            (dolist (form forms)
              (setq value (eval form t))))
          (list value
                (with-current-buffer out (buffer-string))
                (harness-tools-shell--messages-since msg-start)))
      (when (buffer-live-p out) (kill-buffer out)))))

(defun harness-tools-shell--elisp (input _ctx)
  "Handler for the elisp tool with INPUT."
  (let ((code (plist-get input :code)))
    (if (or (not (stringp code)) (string-blank-p code))
        (harness-tool-error "Missing code")
      (condition-case err
          (pcase-let ((`(,value ,output ,messages) (harness-tools-shell--eval code)))
            (let ((printed (string-trim-right
                            (condition-case perr
                                (pp-to-string value)
                              (error (format "%S [pp failed: %s]" value (error-message-string perr)))))))
              (harness-tool-ok
               (string-join
                (delq nil
                      (list (format "=> %s" (harness-truncate-end printed harness-elisp-max-value-chars))
                            (unless (string-empty-p output)
                              (concat "--- output ---\n" (string-trim-right output)))
                            (unless (string-empty-p messages)
                              (concat "--- messages ---\n" messages))))
                "\n"))))
        (error (harness-tool-error (format "Error: %s" (error-message-string err))))))))

(harness-define-tool "elisp"
  :description "Evaluate Emacs Lisp in the running Emacs (lexical binding). Returns the value of the last form, anything printed to standard-output, and messages logged during evaluation. Use it to inspect or drive Emacs, or as an alternative to bash for file work."
  :schema '(:type "object"
            :properties (:code (:type "string" :description "One or more Emacs Lisp forms"))
            :required ("code"))
  :kind 'exec
  :title (lambda (input) (format "elisp %s" (harness-truncate-end (harness-first-line (plist-get input :code)) 70)))
  :handler #'harness-tools-shell--elisp)

(harness-define-module 'tools-shell
  :doc "bash (async, sandboxed when available) and elisp evaluation tools."
  :requires '(tools))

(provide 'harness-tools-shell)
;;; harness-tools-shell.el ends here
