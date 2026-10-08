;;; harness-server.el --- The harness as its own Emacs process  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Emacs runs Lisp on one thread, so anything the harness does in the
;; user's Emacs -- a slow tool, a big directory listing, a JSON parse --
;; freezes the UI, however asynchronous the protocol around it is.  The
;; harness therefore runs in a separate `emacs --batch' process and the
;; user's Emacs keeps only the presentation layer, talking ACP over a
;; loopback TCP socket.  Nothing the harness does can block the UI.
;;
;; This file is both halves:
;;
;; - `harness-server-main' runs in the child.  It loads the forwarded
;;   configuration, starts the state, completion and tool modules (never
;;   the UI), serves ACP on an ephemeral port guarded by a per-spawn
;;   token, prints the address on stderr and then just runs timers and
;;   process output until it is told to stop or its parent goes away.
;;
;; - `harness-server-spawn' runs in the user's Emacs.  It writes the
;;   configuration file, starts the child asynchronously, reads the
;;   address from its stderr and hands it to a callback.  Nothing in it
;;   waits: the UI connects when the address arrives.
;;
;; The child's stdin is closed at once, so code that tries to prompt
;; there fails instead of hanging.  Its stderr carries the address
;; announcement and its log lines, which the parent copies into
;; `harness-log'; stdout is unused because batch Emacs buffers it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar harness-directory)
(defvar harness-state-directory)
(defvar harness-module-directories)
(defvar harness-extra-module-directories)
(defvar harness-acp-token)
(defvar harness-acp-port)
(defvar harness-acp-host)
(defvar harness-acp--server-enabled)
(defvar harness-compile-subdirectory)
(defvar harness-process)
(defvar harness-policy-exempt)
(defvar harness-server--own-variables)  ; Below, with the parent's code.
(declare-function harness--reload "harness")
(declare-function harness--extra-module-directories "harness")
(declare-function harness--ui-module-file-p "harness" (file))
(declare-function harness-start "harness")
(declare-function harness-stop "harness")
(declare-function harness-acp-server-address "harness-acp")

(defcustom harness-server-emacs (expand-file-name invocation-name invocation-directory)
  "Emacs executable that runs the harness process."
  :type 'file :group 'harness)

(defcustom harness-server-forward-variables '(auth-sources exec-path)
  "Variables copied into the harness process besides the `harness-' ones.
Every `harness-' variable you set is copied anyway, and so are the
TRAMP options that decide how remote hosts are reached, when you set
them (`harness-server--tramp-variables').  The harness process starts
from `emacs -Q', so anything else its modules read from your
configuration must be listed here or set in `harness-server-init-file'."
  :type '(repeat variable) :group 'harness)

(defcustom harness-server-init-file nil
  "File the harness process loads after the forwarded variables, or nil.
Use it for configuration that is not a plain variable, such as hooks
or filters added to the harness bus."
  :type '(choice (const nil) file) :group 'harness)

(defconst harness-server--address-prefix "HARNESS-ACP-ADDRESS "
  "Prefix of the stderr line on which the child announces its address.")

;;;; Child

(defun harness-server--parent-alive-p (pid)
  "Non-nil while process PID exists."
  (condition-case nil (eq 0 (signal-process pid 0)) (error nil)))

(defconst harness-server--max-wait 60
  "Longest the harness process's event loop sleeps, in seconds.")

(defun harness-server--wait-time ()
  "Return how long the event loop may sleep: until the earliest timer is due.
Emacs runs the due timers inside `accept-process-output' from a copy
of `timer-list', then sleeps until the next timer of that copy is due.
A timer that a timer function adds -- `harness-run-soon' in a request
handler, the next step of a provider's script -- is not in the copy,
and would wait for an unrelated timer or process output, seconds
later.  An interactive Emacs runs timers again until none is due, but
`emacs --batch' waits only in `accept-process-output', so
`harness-server--event-loop' never sleeps past the earliest timer it
knows of and, waking, sees the ones added meanwhile."
  (let ((now (float-time))
        (wait harness-server--max-wait))
    (dolist (timer timer-list)
      ;; A triggered timer is running or will not run again.
      (unless (timer--triggered timer)
        (setq wait (min wait (- (float-time (timer--time timer)) now)))))
    ;; Zero would wait forever; a timer due now still needs one pass.
    (max 0.001 wait)))

(defun harness-server--event-loop ()
  "Run timers and process output until Emacs exits; never return."
  (while t
    (condition-case err
        (accept-process-output nil (harness-server--wait-time))
      (error (harness-log 'error "server: event loop: %s" (error-message-string err))))))

(defun harness-server--reload ()
  "Reload the harness process in place, for its `harness/reload' method.
Return (:files N).  Signal a `harness-error' naming the problems when a
file does not compile, so that nothing was reloaded, or when some files
failed to load while the others did."
  (let ((result (harness--reload)))
    (cond
     ((plist-get result :refused)
      (signal 'harness-error
              (list (format "reload refused, nothing was reloaded: %s"
                            (string-join (plist-get result :refused) "; ")))))
     ((plist-get result :errors)
      (signal 'harness-error
              (list (format "reloaded, but these files failed to load: %s"
                            (string-join (plist-get result :errors) "; ")))))
     (t (harness-log 'info "server: reloaded %d files" (plist-get result :files))
        (list :files (plist-get result :files))))))

(defun harness-server--log-to-stderr (level msg)
  "Write LEVEL and MSG as one stderr line for the parent's log."
  (princ (format "%s %s\n" (upcase (symbol-name level)) (replace-regexp-in-string "\n" "\\\\n" msg))
         #'external-debugging-output))

(defun harness-server-main ()
  "Run the harness process.  Called by `emacs --batch'; never returns.
Reads HARNESS_SERVER_CONFIG (a file of forms to load),
HARNESS_SERVER_TOKEN and HARNESS_SERVER_PARENT from the environment."
  (let ((config (getenv "HARNESS_SERVER_CONFIG"))
        (parent (let ((p (getenv "HARNESS_SERVER_PARENT"))) (and p (string-to-number p)))))
    (add-hook 'harness-log-hook #'harness-server--log-to-stderr)
    (when (and config (file-readable-p config))
      (load config nil t t))
    (when (and harness-server-init-file (file-readable-p harness-server-init-file))
      (load harness-server-init-file nil t))
    (setq harness-process nil
          harness-compile-subdirectory "elc-server/"
          ;; So it loads the modules of lisp/modules, and of
          ;; `harness-extra-module-directories' all but the UI ones
          ;; (see `harness--module-files').
          harness-module-directories '("lisp/modules")
          harness-acp-token (getenv "HARNESS_SERVER_TOKEN")
          harness-acp-host "127.0.0.1"
          harness-acp-port 0
          harness-acp--server-enabled t
          ;; They are this process's own, whatever a policy says.
          harness-policy-exempt harness-server--own-variables)
    (require 'harness)
    (with-no-warnings
      (harness-defmethod harness/reload ()
        "Reload the harness process's modules in place, keeping its sessions."
        (harness-server--reload)))
    (harness-start)
    (let ((address (harness-acp-server-address)))
      (unless address
        (princ "harness: ACP server did not start\n" #'external-debugging-output)
        (kill-emacs 1))
      ;; stderr: batch Emacs block-buffers stdout when it is a pipe.
      (princ (concat harness-server--address-prefix address "\n") #'external-debugging-output))
    (when parent
      (run-at-time 2 2 (lambda ()
                         (unless (harness-server--parent-alive-p parent)
                           (harness-log 'info "server: parent %d is gone, exiting" parent)
                           (kill-emacs 0)))))
    (harness-server--event-loop)))

;;;; Parent

(defun harness-server--user-set-p (sym)
  "Non-nil when SYM holds a value the user chose rather than a file's default."
  (and (boundp sym)
       (let ((standard (get sym 'standard-value)))
         (if standard
             (not (equal (symbol-value sym)
                         (ignore-errors (eval (car standard) t))))
           ;; Not defined in this Emacs: a module variable set from the init file.
           (null (symbol-file sym 'defvar))))))

(defun harness-server--readable-p (value)
  "Non-nil when VALUE survives `prin1' and `read'."
  (condition-case nil
      (let ((print-length nil) (print-level nil))
        (equal value (car (read-from-string (prin1-to-string value)))))
    (error nil)))

(defconst harness-server--tramp-variables
  '(tramp-default-method tramp-default-method-alist
    tramp-default-user tramp-default-user-alist
    tramp-default-host tramp-default-host-alist
    tramp-default-proxies-alist
    tramp-remote-path tramp-remote-process-environment
    tramp-connection-timeout tramp-shell-prompt-pattern
    tramp-use-connection-share)
  "TRAMP options copied into the harness process when the user set them.
The harness reaches remote hosts through its own TRAMP -- a remote
session's, the ssh tool's, a TRAMP path given to any tool -- and the
process starts from `emacs -Q'.  These options decide how TRAMP
connects (methods, users, jump hosts, connection sharing) and what a
remote command finds there (`tramp-remote-path'), so the harness uses
the user's, as their own Emacs does.")

(defconst harness-server--own-variables
  '(harness-process harness-module-directories harness-extra-module-directories
    harness-compile-subdirectory harness-acp-token harness-acp-host harness-acp-port
    harness-server-forward-variables
    ;; The harness process reads the policy from where the administrator
    ;; put it, not from where this Emacs was told to look.
    harness-policy-file)
  "Variables never forwarded as they are.
The harness process sets them for itself, but for
`harness-extra-module-directories', which `harness-server--forwarded'
expands first.")

(defun harness-server--forwardable-p (sym)
  "Non-nil when SYM configures the harness process, not this Emacs's UI.
A variable a UI module defines, the harness's or the user's, is the
UI's.  It is defined in the compiled copy of the module's file, so the
file's name tells, not its directory."
  (let ((name (symbol-name sym)))
    (and (string-prefix-p "harness-" name)
         (not (string-match-p "--" name))
         (not (memq sym harness-server--own-variables))
         (not (and (fboundp sym) (string-suffix-p "-mode" name)))
         ;; Last: `symbol-file' walks `load-history', far too slow to ask
         ;; of every symbol `harness-server--forwarded' goes through.
         (not (let ((file (symbol-file sym 'defvar)))
                (and file (harness--ui-module-file-p file))))
         (harness-server--user-set-p sym))))

(defun harness-server--forwarded ()
  "Return ((SYMBOL . VALUE) ...) to set in the harness process.
`harness-extra-module-directories' goes as absolute directories: the
process starts from `emacs -Q', whose `user-emacs-directory', which
relative ones are relative to, may not be this Emacs's."
  (let (out)
    (mapatoms (lambda (sym) (when (harness-server--forwardable-p sym) (push sym out))))
    (dolist (sym harness-server-forward-variables)
      (when (boundp sym) (cl-pushnew sym out)))
    (dolist (sym harness-server--tramp-variables)
      (when (harness-server--user-set-p sym) (cl-pushnew sym out)))
    (append
     (cl-loop for sym in (cons 'harness-state-directory (delq 'harness-state-directory out))
              if (harness-server--readable-p (symbol-value sym))
              collect (cons sym (symbol-value sym))
              else do (harness-log 'warn "server: %s has no readable value; not forwarded" sym))
     (and (bound-and-true-p harness-extra-module-directories)
          (list (cons 'harness-extra-module-directories (harness--extra-module-directories)))))))

(defun harness-server--write-config (file)
  "Write the forwarded configuration to FILE."
  (let ((print-length nil) (print-level nil) (print-escape-newlines t))
    (harness-write-file-atomically
     file
     (concat ";;; Generated by harness-server.el -*- lexical-binding: t; -*-\n"
             (mapconcat (lambda (cell)
                          (format "(customize-set-variable '%s '%s)"
                                  (car cell) (prin1-to-string (cdr cell))))
                        (harness-server--forwarded) "\n")
             "\n"))))

(defun harness-server--token ()
  "Return a fresh secret for one harness process."
  (secure-hash 'sha256
               (condition-case nil
                   (with-temp-buffer
                     (set-buffer-multibyte nil)
                     (insert-file-contents-literally "/dev/urandom" nil 0 32)
                     (buffer-string))
                 (error (format "%s %s %s" (random t) (float-time) (emacs-pid))))))

(cl-defun harness-server-spawn (&key on-address on-exit)
  "Start the harness process; return it without waiting for anything.
ON-ADDRESS is called with (ADDRESS TOKEN) once the child listens.
ON-EXIT is called with the exit status and the process when the child
ends: a caller that started another meanwhile can tell which one ended."
  (let* ((token (or (bound-and-true-p harness-acp-token) (harness-server--token)))
         (config (expand-file-name "server-config.el" harness-state-directory))
         (announced nil)
         (process-environment (append (list (concat "HARNESS_SERVER_CONFIG=" config)
                                            (concat "HARNESS_SERVER_TOKEN=" token)
                                            (format "HARNESS_SERVER_PARENT=%d" (emacs-pid)))
                                      process-environment))
         (stderr (make-pipe-process
                  :name "harness-server-stderr" :noquery t
                  :filter (let ((pending ""))
                            (lambda (_p chunk)
                              (let ((lines (split-string (concat pending chunk) "\n")))
                                (setq pending (car (last lines)))
                                (dolist (line (butlast lines))
                                  (cond
                                   ((string-empty-p line))
                                   ((string-prefix-p harness-server--address-prefix line)
                                    (unless announced
                                      (setq announced t)
                                      (when on-address
                                        (funcall on-address
                                                 (substring line (length harness-server--address-prefix))
                                                 token))))
                                   (t
                                    (if (string-match "\\`\\(DEBUG\\|INFO\\|WARN\\|ERROR\\) \\(.*\\)\\'" line)
                                        (harness-log (intern (downcase (match-string 1 line)))
                                                     "[server] %s" (match-string 2 line))
                                      (harness-log 'info "[server] %s" line)))))))))))
    (harness-server--write-config config)
    (let ((proc (make-process
                 :name "harness-server"
                 :command (list harness-server-emacs "--batch" "-Q"
                                "-L" harness-directory
                                "-L" (expand-file-name "lisp" harness-directory)
                                "-l" (expand-file-name "lisp/harness-server.el" harness-directory)
                                "-f" "harness-server-main")
                 :connection-type 'pipe :noquery t
                 :stderr stderr
                 :filter #'ignore
                 :sentinel (lambda (p _event)
                             (unless (process-live-p p)
                               (when on-exit (funcall on-exit (process-exit-status p) p)))))))
      (process-send-eof proc)
      proc)))

(defun harness-server-stop (proc)
  "Ask the harness process PROC to exit cleanly (SIGTERM runs its kill hooks)."
  (when (process-live-p proc)
    (signal-process proc 'term)))

(provide 'harness-server)
;;; harness-server.el ends here
