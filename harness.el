;;; harness.el --- A coding agent harness for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; Author: Noah Huppert <contact@noahh.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai, convenience
;; URL: https://github.com/noahhuppert/emacs-agent-harness

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; The entry point: load the modules, provide the commands and the `C-c h'
;; keymap, load plugins, and implement hot reload.
;;
;; Hot reload uses the built-in machinery rather than a loader of its own.
;; Registries remember the file that registered them (`harness-unload-file'
;; removes a file's tools and renderers), so `load' after `unload-feature' is
;; enough; `harness-plugin-mode' watches the plugin directory with
;; `file-notify-add-watch' and reloads a saved file; and `harness-reload'
;; reloads the harness modules in dependency order.  A reload never touches
;; live sessions or buffers -- only code -- and ends by running
;; `harness-after-reload-hook', which the UI uses to re-render.
;;
;; The harness also extends itself with the same mechanism: the
;; `harness_eval', `harness_define_tool', `harness_write_plugin' and
;; `harness_reload' tools are registered here, so the agent editing its own
;; source code and the person editing a plugin take the exact same path.
;;
;; See DESIGN.md sections 9.4, 13 and 13.1.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'filenotify)
(require 'harness-core)
(require 'harness-faces)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-provider-process)
(require 'harness-session)
(require 'harness-tools)
(require 'harness-perms)
(require 'harness-agent)
(require 'harness-queue)
(require 'harness-subagents)
(require 'harness-mode-line)
(require 'harness-ui-conversation)
(require 'harness-ui-sessions)
(require 'harness-ui-tree)
(require 'harness-ui-ask)
(require 'harness-ui-model)

(defcustom harness-plugins-directory
  (expand-file-name "agent-harness/plugins" user-emacs-directory)
  "Directory whose `*.el' files are loaded as harness plugins."
  :type 'directory
  :group 'harness)

(defcustom harness-plugin-auto-load t
  "Whether `harness-setup' loads the plugins directory."
  :type 'boolean
  :group 'harness)

(defcustom harness-plugin-mode-lighter " H-Reload"
  "Mode line lighter for `harness-plugin-mode'."
  :type 'string
  :group 'harness)

(defcustom harness-plugin-watch-harness-directory nil
  "Also watch the harness's own source directory for changes.
Useful while developing the harness itself; off by default because reloading
the harness is slower than reloading a plugin."
  :type 'boolean
  :group 'harness)

(defcustom harness-plugin-reload-delay 0.25
  "Seconds to wait after a file changes before reloading it.
Editors write a file more than once; this coalesces the writes."
  :type 'number
  :group 'harness)

(defconst harness--modules
  '(harness-core harness-faces harness-http harness-provider
    harness-provider-openai harness-provider-process harness-session
    harness-tools harness-perms harness-agent harness-queue
    harness-subagents harness-mode-line harness-ui-conversation
    harness-ui-sessions harness-ui-tree harness-ui-ask harness-ui-model
    harness)
  "Harness modules in dependency order, for `harness-reload'.")

(defvar harness--watch-descriptors nil
  "Active file notification descriptors, for `harness-plugin-mode'.")

(defvar harness--reload-timers (make-hash-table :test #'equal)
  "Pending per-file reload timers, keyed by file name.")

(defvar harness-setup-hook nil
  "Hook run at the end of `harness-setup'.")

(defvar harness--setup-done nil
  "Non-nil once `harness-setup' has run.")


;;; Setup

(defun harness-setup ()
  "Prepare the harness: providers, permissions, plugins and hooks."
  (interactive)
  (harness-provider-setup)
  (harness-permission-rules-load)
  (when harness-plugin-auto-load
    (harness-load-plugins))
  (setq harness--setup-done t)
  (run-hooks 'harness-setup-hook)
  (message "Harness ready: %d provider%s, %d model%s, %d tool%s"
           (length (harness-provider-all))
           (if (= (length (harness-provider-all)) 1) "" "s")
           (length (harness-model-search))
           (if (= (length (harness-model-search)) 1) "" "s")
           (length (harness-tool-all))
           (if (= (length (harness-tool-all)) 1) "" "s")))

(defun harness-ensure-setup ()
  "Run `harness-setup' once, lazily."
  (unless harness--setup-done
    (harness-setup)))


;;; Plugins and hot reload

(defun harness-plugin-files ()
  "Return the plugin files, in load order."
  (when (file-directory-p harness-plugins-directory)
    (sort (directory-files harness-plugins-directory t "\\`[^.#].*\\.el\\'") #'string<)))

(defun harness-file-features (file)
  "Return the features provided by FILE."
  (let* ((file (expand-file-name file))
         (entry (assoc file load-history)))
    (delq nil (mapcar (lambda (item)
                        (and (consp item) (eq (car item) 'provide) (cdr item)))
                      entry))))

(defun harness-unload-file (file)
  "Remove everything FILE registered: tools, renderers and its features.
This is what lets a plugin be reloaded without accumulating dead
registrations, and it uses the standard `unload-feature' to drop the
functions and variables the file defined."
  (dolist (name (harness-tools-for-file (expand-file-name file)))
    (harness-unregister-tool name))
  (dolist (kind (harness-renderers-for-file (expand-file-name file)))
    (harness-remove-renderer kind))
  (dolist (feature (harness-file-features file))
    (condition-case err
        (unload-feature feature t)
      (error (harness--log "could not unload %s: %s" feature
                           (error-message-string err)))))
  file)

(defun harness-reload-plugin (file)
  "Reload the plugin in FILE."
  (interactive (list (or (and (buffer-file-name) (buffer-file-name))
                         (read-file-name "Plugin: " harness-plugins-directory nil t
                                         nil #'file-regular-p))))
  (let ((file (expand-file-name file)))
    (unless (file-readable-p file)
      (user-error "Cannot read %s" file))
    (harness-unload-file file)
    (let ((load-prefer-newer t))
      (load file nil 'nomessage))
    (run-hooks 'harness-after-reload-hook)
    (message "Reloaded %s" (file-name-nondirectory file))
    file))

(defun harness-load-plugins ()
  "Load every plugin in `harness-plugins-directory'."
  (interactive)
  (let ((files (harness-plugin-files))
        (loaded 0))
    (dolist (file files)
      (condition-case err
          (progn
            (let ((load-prefer-newer t))
              (load file nil 'nomessage))
            (setq loaded (1+ loaded)))
        (error (harness--log "plugin %s failed: %s" file (error-message-string err))
               (message "Harness plugin %s failed: %s"
                        (file-name-nondirectory file) (error-message-string err)))))
    (when (called-interactively-p 'interactive)
      (message "Loaded %d plugin%s" loaded (if (= loaded 1) "" "s")))
    loaded))

(defun harness-reload-plugins ()
  "Reload every plugin, so edits take effect without a restart."
  (interactive)
  (dolist (file (harness-plugin-files))
    (condition-case err
        (harness-reload-plugin file)
      (error (harness--log "plugin %s failed: %s" file (error-message-string err))
             (message "Harness plugin %s failed: %s"
                      (file-name-nondirectory file) (error-message-string err)))))
  (run-hooks 'harness-after-reload-hook))

(defun harness-reload (&optional quiet)
  "Reload every harness module, keeping sessions and buffers alive.

Modules are loaded in dependency order, so a change to a lower module is
picked up exactly as a restart would pick it up.  `defvar' does not re-run
when the variable is already bound, so registries and session state survive;
`defcustom' keeps the user's value."
  (interactive)
  (dolist (module harness--modules)
    (let ((file (locate-library (symbol-name module))))
      (when (and file (file-readable-p file))
        (condition-case err
            (let ((load-prefer-newer t))
              (load file nil 'nomessage))
          (error (harness--log "reload of %s failed: %s" module
                               (error-message-string err))
                 (message "Harness reload of %s failed: %s" module
                          (error-message-string err)))))))
  ;; Doom's autoloads are the one piece of the environment a reload can
  ;; invalidate; refreshing them when Doom is present keeps new autoloaded
  ;; commands working the way `doom/reload' would.
  (when (fboundp 'doom/reload-autoloads)
    (ignore-errors (doom/reload-autoloads)))
  (harness-provider-setup)
  (run-hooks 'harness-after-reload-hook)
  (unless quiet
    (message "Harness reloaded (%d modules); sessions and buffers kept"
             (length harness--modules))))

(defun harness-reload-file (file)
  "Reload whatever FILE is: a plugin, or a harness module."
  (interactive (list (or (buffer-file-name)
                         (read-file-name "Reload: " nil nil t nil #'file-regular-p))))
  (if (string-prefix-p (expand-file-name harness-plugins-directory)
                       (expand-file-name file))
      (harness-reload-plugin file)
    (harness-unload-file file)
    (let ((load-prefer-newer t))
      (load file nil 'nomessage))
    (run-hooks 'harness-after-reload-hook)
    (message "Reloaded %s" (file-name-nondirectory file))))

(defun harness--reload-after-change (file)
  "Reload FILE after a short delay, coalescing repeated writes.

Editors write more than once (a temp file, a rename, a mode line), so a reload
is scheduled rather than run immediately; the timer is per file, and the last
change wins."
  (when-let* ((timer (gethash file harness--reload-timers)))
    (cancel-timer timer))
  (puthash file
           (run-at-time harness-plugin-reload-delay nil
                        (lambda ()
                          (remhash file harness--reload-timers)
                          (when (file-readable-p file)
                            (condition-case err
                                (harness-reload-file file)
                              (error (message "Harness reload of %s failed: %s"
                                              (file-name-nondirectory file)
                                              (error-message-string err)))))))
           harness--reload-timers)
  file)

(defun harness--watch-file (event)
  "Reload the file described by file notification EVENT."
  (let* ((descriptor (car event))
         (action (cadr event))
         (file (nth 2 event)))
    (ignore descriptor)
    (when (and (stringp file)
               (string-suffix-p ".el" file)
               (memq action '(created changed renamed)))
      (harness--reload-after-change file))))

(defvar harness--file-notify-support 'unknown
  "Cached answer from `harness-file-notify-works-p'.")

(defun harness-file-notify-works-p ()
  "Return non-nil when file notifications actually fire in this Emacs.

Batch Emacs, and some remote filesystems, cannot watch files.  The plugin mode
still works there -- `harness-reload-plugins' does the same job on demand --
and this predicate lets callers tell which world they are in."
  (when (eq harness--file-notify-support 'unknown)
    (let* ((directory (make-temp-file "harness-notify" t))
           (seen nil)
           (descriptor (ignore-errors
                         (file-notify-add-watch
                          directory '(change)
                          (lambda (_event) (setq seen t))))))
      (unwind-protect
          (progn
            (when descriptor
              (with-temp-file (expand-file-name "probe" directory)
                (insert "probe"))
              (let ((tries 0))
                (while (and (not seen) (< tries 20))
                  (accept-process-output nil 0.05)
                  (setq tries (1+ tries)))))
            (setq harness--file-notify-support (and seen t)))
        (when descriptor (ignore-errors (file-notify-rm-watch descriptor)))
        (ignore-errors (delete-directory directory t)))))
  harness--file-notify-support)

(defun harness--watch-directory (directory)
  "Watch DIRECTORY for changed Elisp files."
  (when (file-directory-p directory)
    (push (file-notify-add-watch directory '(change) #'harness--watch-file)
          harness--watch-descriptors)))

(define-minor-mode harness-plugin-mode
  "Reload plugins (and optionally the harness) whenever they are saved."
  :global t
  :lighter harness-plugin-mode-lighter
  :group 'harness
  (if harness-plugin-mode
      (progn
        (unless (file-directory-p harness-plugins-directory)
          (make-directory harness-plugins-directory t))
        (harness--watch-directory harness-plugins-directory)
        (when harness-plugin-watch-harness-directory
          (harness--watch-directory
           (file-name-directory (or (locate-library "harness") default-directory)))))
    (dolist (descriptor harness--watch-descriptors)
      (ignore-errors (file-notify-rm-watch descriptor)))
    (setq harness--watch-descriptors nil)
    (maphash (lambda (_file timer) (cancel-timer timer)) harness--reload-timers)
    (clrhash harness--reload-timers)))

(defun harness-author-plugin (name)
  "Create a new plugin NAME and open it for editing.
The scaffold registers nothing but is byte-compile clean and reloads, which
is the point: the loop from empty file to working tool is one save."
  (interactive "sPlugin name: ")
  (let* ((file (expand-file-name (concat (replace-regexp-in-string
                                          "[^a-zA-Z0-9_-]" "-" name)
                                         ".el")
                                 harness-plugins-directory))
         (feature (intern (file-name-base file))))
    (make-directory harness-plugins-directory t)
    (unless (file-exists-p file)
      (with-temp-file file
        (insert (format ";;; %s.el --- Harness plugin: %s -*- lexical-binding: t; -*-\n\n"
                        (file-name-base file) name)
                ";;; Commentary:\n\n"
                ";; A harness plugin.  Everything here is hot reloadable:\n"
                ";; `M-x harness-plugin-mode' reloads this file when it is saved.\n\n"
                ";;; Code:\n\n"
                "(require 'harness)\n\n"
                ";; Register a tool with `harness-define-tool', a renderer with\n"
                ";; `harness-add-renderer', or a hook function with `add-hook'.\n\n"
                (format "(provide '%s)\n;;; %s.el ends here\n"
                        feature (file-name-base file)))))
    (find-file file)
    file))

(defun harness-load-plugin-directory (&optional directory)
  "Load every `*.el' file in DIRECTORY as a plugin.
This is how a project-local plugin folder is picked up."
  (interactive "DPlugin directory: ")
  (let ((harness-plugins-directory (expand-file-name directory))
        (harness-plugin-auto-load t))
    (harness-load-plugins)))


;;; Self-extension tools

(harness-define-tool "harness_eval"
  :description "Evaluate Emacs Lisp in the running Emacs. Use this to extend or inspect the harness itself."
  :parameters '(:type "object"
                :properties (:code (:type "string"
                                   :description "Emacs Lisp to evaluate; the value is returned"))
                :required ("code"))
  :category 'execute
  :approval 'ask
  :function
  (lambda (args _context)
    (let* ((code (or (harness-tools-arg args :code) ""))
           (result (eval (car (read-from-string code)) t)))
      (harness-tool-result-create
       :content (format "%S" result)
       :error nil
       :detail (list :kind 'elisp :code code)))))

(harness-define-tool "harness_write_plugin"
  :description "Write a harness plugin file and reload it. The plugin can register tools and renderers."
  :parameters '(:type "object"
                :properties (:name (:type "string" :description "Plugin file name, without .el")
                             :code (:type "string" :description "The Elisp source"))
                :required ("name" "code"))
  :category 'edit
  :approval 'ask
  :function
  (lambda (args _context)
    (let* ((name (or (harness-tools-arg args :name) "plugin"))
           (slug (replace-regexp-in-string "[^a-zA-Z0-9_-]" "-" name))
           (code (or (harness-tools-arg args :code) ""))
           (file (expand-file-name (concat slug ".el") harness-plugins-directory)))
      (make-directory harness-plugins-directory t)
      (let ((coding-system-for-write 'utf-8-unix)
            (write-region-inhibit-fsync t))
        (write-region code nil file nil 'silent))
      (harness-reload-plugin file)
      (harness-tool-result-create
       :content (format "Wrote and reloaded %s" file)
       :detail (list :kind 'edit :path file)))))

(harness-define-tool "harness_define_tool"
  :description "Define a new tool at runtime. The code is an Elisp body with the parsed arguments bound to `args' and the tool context to `context'."
  :parameters '(:type "object"
                :properties (:name (:type "string" :description "Tool name")
                             :description (:type "string" :description "What the tool does, for the model")
                             :parameters (:type "object" :description "JSON schema for the arguments")
                             :code (:type "string" :description "Elisp body returning a harness-tool-result"))
                :required ("name" "description" "code"))
  :category 'edit
  :approval 'ask
  :function
  (lambda (args _context)
    (let* ((name (harness-tools-arg args :name))
           (description (or (harness-tools-arg args :description) ""))
           (parameters (harness-tools-arg args :parameters))
           (code (or (harness-tools-arg args :code) "")))
      (if (or (null name) (string-empty-p (format "%s" name)))
          (harness-tool-result-create :content "harness_define_tool needs a name"
                                      :error "no name")
        (condition-case err
            (let* ((forms (car (read-from-string (concat "(" code ")"))))
                   (function (eval (append (list 'lambda '(args context)) forms) t)))
              (harness-register-tool
               (harness-tool--make
                :name (format "%s" name)
                :description description
                :parameters parameters
                :category 'meta
                :approval 'ask
                :function function))
              (harness-tool-result-create
               :content (format "Registered tool %s. It is available from the next request."
                                name)
               :detail (list :kind 'tool :name name)))
          (error
           (harness-tool-result-create
            :content (format "Could not define %s: %s" name (error-message-string err))
            :error (error-message-string err))))))))

(harness-define-tool "harness_reload"
  :description "Reload the harness or its plugins in the running Emacs. Use after editing harness or plugin code."
  :parameters '(:type "object"
                :properties (:what (:type "string"
                                   :enum ("plugins" "harness" "plugin"))
                             :file (:type "string"
                                    :description "Required when what is plugin"))
                :required ("what"))
  :category 'meta
  :approval 'allow
  :function
  (lambda (args _context)
    (pcase (harness-tools-arg args :what)
      ("plugins" (harness-reload-plugins)
                 (harness-tool-result-create :content "Reloaded all plugins"))
      ("harness" (harness-reload)
                 (harness-tool-result-create :content "Reloaded the harness"))
      ("plugin" (let ((file (harness-tools-arg args :file)))
                  (unless file
                    (harness-tool-result-create :content "harness_reload needs :file"
                                                :error "no file"))
                  (harness-reload-plugin file)
                  (harness-tool-result-create
                   :content (format "Reloaded %s" file))))
      (_ (harness-tool-result-create :content "what must be plugins, harness or plugin"
                                     :error "bad what")))))


;;; Commands

(defun harness-new-session (&optional name)
  "Start a new session for the current project and open it."
  (interactive)
  (harness-ensure-setup)
  (let ((session (harness-session-create (list :name name))))
    (unless (harness-session-model session)
      (message "No model selected yet; M-x harness-select-model"))
    (harness-conversation-open session)))

(defun harness-resume-session (file)
  "Resume a saved session and open it."
  (interactive (list (harness-session--read-file "Resume session")))
  (harness-ensure-setup)
  (harness-conversation-open (harness-session-resume file)))

(defun harness-switch-session ()
  "Switch to another live session, asking which."
  (interactive)
  (harness-conversation-open (harness-session--read-session "Switch to")))

(defun harness-switch-blocked ()
  "Switch to the next session that is waiting for the user.
This is the command that makes a stalled run impossible to miss."
  (interactive)
  (let ((blocked (seq-filter #'harness-session-blocked-p (harness-session-list))))
    (cond
     ((null blocked) (message "No session is waiting for you"))
     ((= (length blocked) 1) (harness-conversation-open (car blocked)))
     (t (harness-conversation-open (harness-session--read-session "Blocked session"))))))

(defun harness-cycle-sessions (&optional arg)
  "Cycle through live sessions, most recently used last.
With ARG, go backwards."
  (interactive "p")
  (let ((sessions (seq-filter (lambda (session)
                                (buffer-live-p (harness-session-buffer session)))
                              (harness-session-list))))
    (if (null sessions)
        (message "No open sessions")
      (let* ((current (harness-conversation-session))
             (index (or (cl-position current sessions) -1))
             (count (length sessions))
             (next (mod (+ index (if (> arg 0) 1 -1)) count)))
        (harness-conversation-open (nth next sessions))))))

(defun harness-abort-all ()
  "Abort every running session."
  (interactive)
  (harness-agent-abort-all))

(defun harness-open-at-project ()
  "Open the most recent session of the current project, or start one."
  (interactive)
  (harness-ensure-setup)
  (let* ((root (file-name-as-directory (expand-file-name default-directory)))
         (records (harness-session-records root)))
    (if (null records)
        (harness-new-session)
      (harness-conversation-open
       (harness-session-resume (harness-plist-or-alist-get :file (car records)))))))

(defun harness-toggle-thinking ()
  "Toggle reasoning traces in the current conversation buffer."
  (interactive)
  (harness-conversation-toggle-thinking))

(defun harness-eval-expression (code)
  "Evaluate CODE in the running Emacs and show the result.
The same operation the `harness_eval' tool performs, for a person at a
keyboard."
  (interactive "sEval: ")
  (message "%S" (eval (car (read-from-string code)) t)))

(defun harness-describe-session ()
  "Show a description of the current session."
  (interactive)
  (let ((session (harness-conversation-session)))
    (unless session (user-error "Not in a harness buffer"))
    (message "%s · %s · %s · %s"
             (harness-session-name session)
             (harness-session-status-string session)
             (harness-model-describe-current session)
             (harness-usage-format (harness-session-usage-total session)))))


;;; Keymap and global mode

(defvar harness-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'harness-new-session)
    (define-key map (kbd "o") #'harness-open-at-project)
    (define-key map (kbd "r") #'harness-resume-session)
    (define-key map (kbd "l") #'harness-list-sessions)
    (define-key map (kbd "s") #'harness-search-sessions-ui)
    (define-key map (kbd "b") #'harness-switch-blocked)
    (define-key map (kbd "TAB") #'harness-cycle-sessions)
    (define-key map (kbd "m") #'harness-select-model)
    (define-key map (kbd "M") #'harness-list-models)
    (define-key map (kbd "t") #'harness-tree)
    (define-key map (kbd "q") #'harness-queue-edit)
    (define-key map (kbd "a") #'harness-approve-next)
    (define-key map (kbd "A") #'harness-toggle-auto-mode)
    (define-key map (kbd "e") #'harness-eval-expression)
    (define-key map (kbd "R") #'harness-reload)
    (define-key map (kbd "P") #'harness-reload-plugins)
    (define-key map (kbd "L") #'harness-plugin-mode)
    (define-key map (kbd "N") #'harness-author-plugin)
    (define-key map (kbd "f") #'harness-refresh-models)
    (define-key map (kbd "x") #'harness-abort-all)
    (define-key map (kbd "i") #'harness-index-rebuild)
    (define-key map (kbd "d") #'harness-describe-session)
    (define-key map (kbd "h") #'harness-setup)
    map)
  "Keymap for harness commands, bound to `C-c h' by `harness-global-mode'.")

(defvar harness-global-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c h") harness-command-map)
    map)
  "Global keymap for the harness.")

(define-minor-mode harness-global-mode
  "Global harness mode: key bindings and the blocked-session indicator."
  :global t
  :lighter nil
  :group 'harness
  :keymap harness-global-mode-map
  (harness-mode-line-global-mode (if harness-global-mode 1 -1)))

(provide 'harness)
;;; harness.el ends here
