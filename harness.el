;;; harness.el --- Emacs Agent Harness entry point -*- lexical-binding: t; -*-

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

;;; Code:

(require 'cl-lib)
(require 'filenotify)
(require 'seq)
(require 'subr-x)
(require 'harness-core)

(defcustom harness-modules
  '(harness-acp
    harness-acp-tcp
    harness-config
    harness-sandbox
    harness-session
    harness-provider
    harness-provider-openai
    harness-tools
    harness-tools-emacs
    harness-skills
    harness-perms
    harness-perms-jail
    harness-agent
    harness-subagents
    harness-ui
    harness-ui-chat
    harness-ui-ask
    harness-ui-sessions
    harness-ui-config
    harness-ui-notifier
    harness-ui-tree)
  "Modules a normal `harness-start' loads, in addition to dependencies."
  :type '(repeat symbol))

(defcustom harness-acp-server-port nil
  "TCP port for remote ACP clients, or nil to not listen.
A local UI uses the in-process transport and does not need a port."
  :type '(choice (const nil) natnum))

(defcustom harness-acp-server-host "127.0.0.1"
  "Address the ACP server listens on when `harness-acp-server-port' is set."
  :type 'string)

(defvar harness--acp-server nil
  "The remote ACP server process, when running.")

;;; Lifecycle

(defun harness-load (&optional modules)
  "Load MODULES (default `harness-modules') and their dependencies."
  (interactive)
  (dolist (module (or modules harness-modules))
    (harness-module-load module))
  (harness-module-list))

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
      (message "Harness ACP server listening on %s:%s"
               harness-acp-server-host
               (process-contact harness--acp-server :service))))
  (message "Harness ready (%d modules)" (length (harness-module-list)))
  t)

(defun harness-stop ()
  "Stop the ACP server and unload every module."
  (interactive)
  (when (and harness--acp-server (process-live-p harness--acp-server))
    (delete-process harness--acp-server)
    (setq harness--acp-server nil))
  (dolist (module (reverse (harness-module-load-order)))
    (harness-module-unload module))
  (message "Harness stopped")
  t)

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

;;; Auto reload

(defvar harness--auto-reload-watches nil
  "File notification watches for `harness-auto-reload-mode'.")

(defun harness--watch-directories ()
  "Return the source directories that hold harness modules."
  (delete-dups
   (seq-keep (lambda (directory)
               (when (seq-some (lambda (file)
                                 (string-prefix-p "harness" file))
                               (ignore-errors (directory-files directory nil "^harness.*\\.elc?\\'")))
                 directory))
             load-path)))

(defun harness--auto-reload-event (_event)
  "Reload the harness after a source file changed, without breaking it."
  (harness-batch 'harness-auto-reload 0.4
                 (lambda ()
                   (condition-case err
                       (harness-reload)
                     (error
                      (message "Harness auto-reload skipped: %s"
                               (error-message-string err)))))))

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
