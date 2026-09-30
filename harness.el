;;; harness.el --- Emacs Agent Harness entry point -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience
;; URL: https://git.sr.ht/~catvec/emacs-agent-harness

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; The distribution bundle.  The kernel and every feature are modules; this
;; file only decides which ones a normal install loads and provides the
;; lifecycle commands:
;;
;;   M-x harness-start   load the modules and start the ACP server
;;   M-x harness-stop    tear everything down
;;   M-x harness-reload  safely reload every loaded module
;;   M-x harness-auto-reload-mode
;;                       watch the source tree and reload after saves
;;
;; Reloading is safe by design (DESIGN.md): every source is byte-compiled
;; first, and if a new load fails the previous definitions and setup are
;; restored, so a bad edit never bricks a running session.  UI modules
;; listen for `harness-reloaded' and redraw their buffers.
;;
;; The bundle is self-locating: loading (or byte-compiling) this file puts
;; the source directories next to it on `load-path', so the entry point
;; works both from a checkout and from a package manager's build
;; directory.  See "Install" in README.md for the straight.el and Doom
;; Emacs recipes.

;;; Code:

(require 'cl-lib)
(require 'filenotify)
(require 'seq)
(require 'subr-x)

;;; Source layout

(eval-and-compile
  ;; `byte-compile-current-file' makes the same directories visible at
  ;; compile time, so the `require's below resolve in a build directory
  ;; that has never been loaded.
  (let ((directory (file-name-directory
                    (or load-file-name
                        (bound-and-true-p byte-compile-current-file)
                        buffer-file-name
                        default-directory))))
    (dolist (relative '("" "lisp" "lisp/modules" "lisp/transports" "lisp/ui"))
      (let ((path (directory-file-name (expand-file-name relative directory))))
        (when (file-directory-p path)
          (add-to-list 'load-path path))))))

(require 'harness-core)

(defcustom harness-modules
  '(harness-acp
    harness-acp-tcp
    harness-config
    harness-sandbox
    harness-session
    harness-provider
    harness-provider-openai
    harness-provider-claude
    harness-tools
    harness-tools-emacs
    harness-skills
    harness-perms
    harness-perms-jail
    harness-agent
    harness-usage
    harness-subagents
    harness-search
    harness-plan
    harness-merge
    harness-worktree
    harness-ui
    harness-ui-chat
    harness-ui-ask
    harness-ui-sessions
    harness-ui-config
    harness-ui-notifier
    harness-ui-tree
    harness-ui-usage
    harness-ui-worktree)
  "Modules a normal `harness-start' loads, in addition to dependencies."
  :type '(repeat symbol))

(defcustom harness-acp-server-port nil
  "TCP port for remote ACP clients, or nil to not listen.
A local UI uses the in-process transport and does not need a port."
  :type '(choice (const nil) natnum))

(defcustom harness-acp-server-host "127.0.0.1"
  "Address the ACP server listens on when `harness-acp-server-port' is set."
  :type 'string)

(defcustom harness-acp-server-file
  (expand-file-name "acp-server" "~/.local/share/harness")
  "File recording the running ACP server's host and port.
Written only when `harness-acp-server-port' is set, so a remote UI can
find the address without guessing the ephemeral port."
  :type 'file)

(defvar harness--acp-server nil
  "The remote ACP server process, when running.")

(defun harness--write-acp-server-file (host port)
  "Record HOST and PORT for remote clients."
  (ignore-errors
    (make-directory (file-name-directory harness-acp-server-file) t)
    (with-temp-file harness-acp-server-file
      (insert (format "%s:%s\n" host port)))))

(defun harness--remove-acp-server-file ()
  "Forget the recorded server address."
  (ignore-errors (delete-file harness-acp-server-file)))

;;; Lifecycle

;;;###autoload
(defun harness-load (&optional modules)
  "Load MODULES (default `harness-modules') and their dependencies."
  (interactive)
  (dolist (module (or modules harness-modules))
    (harness-module-load module))
  (harness-module-list))

;;;###autoload
(defun harness-start (&optional modules)
  "Load the harness and, when configured, start the remote ACP server."
  (interactive)
  (harness-load modules)
  (when (harness-module-set-up-p 'harness-ui)
    (harness-ui-start))
  (when (and harness-acp-server-port
             (harness-module-set-up-p 'harness-acp-tcp))
    (unless (and harness--acp-server (process-live-p harness--acp-server))
      (setq harness--acp-server
            (harness-acp-tcp-server harness-acp-server-port
                                    #'harness-acp-agent-started
                                    harness-acp-server-host))
      (let ((port (process-contact harness--acp-server :service)))
        (harness--write-acp-server-file harness-acp-server-host port)
        (message "Harness ACP server listening on %s:%s"
                 harness-acp-server-host port))))
  (message "Harness ready (%d modules)" (length (harness-module-list)))
  (harness-global-mode 1)
  t)

;;;###autoload
(defun harness-stop ()
  "Stop the ACP server and unload every module."
  (interactive)
  (when (and harness--acp-server (process-live-p harness--acp-server))
    (delete-process harness--acp-server)
    (setq harness--acp-server nil)
    (harness--remove-acp-server-file))
  (dolist (module (reverse (harness-module-load-order)))
    (harness-module-unload module))
  (message "Harness stopped")
  t)

;;;###autoload
(defun harness-reload ()
  "Safely reload every loaded module.
The kernel itself is never reloaded (it is the ground the reload stands
on).  All other sources are compiled first; if any fails, nothing is
touched.  If a module fails while loading, the previous definitions and
setup are restored for every module, so existing sessions keep working."
  (interactive)
  (let* ((order (seq-remove (lambda (module) (eq module 'harness-core))
                            (harness-module-load-order)))
         (broken (seq-remove #'harness-module-validate order)))
    (when broken
      (user-error "Not reloading; these do not compile: %s"
                  (string-join (mapcar #'symbol-name broken) ", ")))
    (let ((snapshots (mapcar #'harness-module-snapshot order)))
      (condition-case err
          (progn
            (dolist (module (reverse order))
              (harness-module-unload module))
            (dolist (module order)
              (harness-module-load module)
              (harness-emit 'harness-reloaded :module module))
            (message "Harness reloaded (%d modules)" (length order))
            t)
        (error
         (harness-log "reload failed: %S; restoring" err)
         (dolist (snapshot (reverse snapshots))
           (condition-case restore-error
               (harness-module-restore snapshot)
             (error (harness-log "restore of %s failed: %S"
                                 (harness-module-snapshot-name snapshot)
                                 restore-error))))
         (signal 'harness-module-error
                 (list (format "Reload failed (%s); the previous harness was restored"
                               (error-message-string err)))))))))

;;; Global key bindings

(defvar harness-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'harness-ui-chat-new)
    (define-key map (kbd "s") #'harness-ui-sessions)
    (define-key map (kbd "w") #'harness-ui-worktrees)
    (define-key map (kbd "u") #'harness-ui-usage)
    (define-key map (kbd "m") #'harness-ui-switch-model)
    (define-key map (kbd "t") #'harness-ui-set-thinking)
    (define-key map (kbd "p") #'harness-ui-set-permission-mode)
    (define-key map (kbd "C") #'harness-ui-set-session-mode)
    (define-key map (kbd "r") #'harness-reload)
    (define-key map (kbd "S") #'harness-start)
    (define-key map (kbd "q") #'harness-stop)
    (define-key map (kbd "?") #'describe-prefix-bindings)
    (define-key map (kbd "h") #'describe-prefix-bindings)
    map)
  "Prefix map for the harness' commands from anywhere in Emacs.
Bound to `C-c h' by `harness-global-mode'.")

;;;###autoload
(define-minor-mode harness-global-mode
  "Global harness command prefix.
With the mode on, `C-c h' is a prefix for the common commands:
new session, the session list, model/thinking/permission controls,
reload, start and stop.  `harness-start' enables it; enable it by
hand when starting the harness lazily from a key binding."
  :global t
  :lighter nil
  :group 'harness
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c h") harness-command-map)
            map))

;;; Auto reload

(defvar harness--auto-reload-watches nil
  "File notification watches for `harness-auto-reload-mode'.")

(defun harness--module-source-directory (name)
  "Return the directory holding module NAME's true source, or nil.
A package manager may load modules from a build directory that only
holds symlinks; resolve through them so the checkout is watched."
  (when-let* ((file (harness-module-source-file name)))
    (when (string-suffix-p ".elc" file)
      (let ((source (concat (file-name-sans-extension file) ".el")))
        (when (file-exists-p source)
          (setq file source))))
    (when (string-suffix-p ".el" file)
      (file-name-directory (file-truename file)))))

(defun harness--watch-directories ()
  "Return the source directories that hold harness modules."
  (or (delete-dups
       ;; Where the loaded modules came from.  Straight.el installs symlink
       ;; the checkout into a build directory, so resolve the symlinks:
       ;; edits happen in the checkout, not on `load-path'.
       (seq-keep #'harness--module-source-directory (harness-module-list)))
      ;; Nothing is loaded yet: an edit before `harness-start' still
      ;; deserves a watch, so fall back to the load-path.
      (delete-dups
       (seq-keep (lambda (directory)
                   (when (seq-some (lambda (file)
                                     (string-prefix-p "harness" file))
                                   (ignore-errors
                                     (directory-files directory nil "^harness.*\\.elc?\\'")))
                     directory))
                 load-path))))

(defun harness--auto-reload-event (_event)
  "Reload the harness after a source file changed, without breaking it."
  (harness-batch 'harness-auto-reload 0.4
                 (lambda ()
                   (condition-case err
                       (harness-reload)
                     (error
                      (message "Harness auto-reload skipped: %s"
                               (error-message-string err)))))))

;;;###autoload
(define-minor-mode harness-auto-reload-mode
  "Watch the harness source tree and reload the harness after changes."
  :global t
  :group 'harness
  (if harness-auto-reload-mode
      (progn
        (setq harness--auto-reload-watches
              (delq nil
                    (mapcar (lambda (directory)
                              (condition-case nil
                                  (file-notify-add-watch directory '(change)
                                                         #'harness--auto-reload-event)
                                (error nil)))
                            (harness--watch-directories))))
        (message "Watching %d harness source directories"
                 (length harness--auto-reload-watches)))
    (dolist (watch harness--auto-reload-watches)
      (ignore-errors (file-notify-rm-watch watch)))
    (setq harness--auto-reload-watches nil)
    (message "Stopped watching harness sources")))

;;;###autoload
(defun harness-version ()
  "Report the harness version and loaded module count."
  (interactive)
  (message "emacs-agent-harness %s (%d modules loaded)"
           harness-version
           (length (seq-filter #'harness-module-set-up-p (harness-module-list)))))

(provide 'harness)
;;; harness.el ends here
