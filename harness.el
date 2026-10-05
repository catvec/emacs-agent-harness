;;; harness.el --- Emacs native agent harness  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 catvec
;; Author: catvec
;; Version: 3.0.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience
;; URL: https://git.sr.ht/~catvec/emacs-agent-harness

;;; Commentary:

;; The harness proper is only a module loader on top of `harness-core'.
;; Every feature (sessions, providers, tools, the chat UI, the ACP
;; server) is a module under lisp/modules or lisp/ui.  A harness with
;; every module disabled starts, does nothing, and shows nothing.
;;
;; Start it with `harness-start'.  Reload it after editing the sources
;; with `harness-reload': each file is checked and compiled first and
;; the running instance is only touched when all of them pass, so a
;; broken edit never bricks live sessions.  `harness-auto-reload-mode'
;; does this on every save while dogfooding.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'filenotify)
(require 'bytecomp)

(defconst harness-version "3.0.0" "Version of the harness.")

(defconst harness-directory
  (file-name-directory (or load-file-name buffer-file-name
                           (locate-library "harness") default-directory))
  "Directory containing harness.el.")

(defgroup harness nil
  "Emacs native agent harness."
  :group 'tools :prefix "harness-")

(defcustom harness-module-directories '("lisp/modules" "lisp/ui")
  "Directories, relative to `harness-directory', that hold module files.
Every file named harness-NAME.el in them is a module called NAME."
  :type '(repeat string) :group 'harness)

(defcustom harness-enabled-modules t
  "Modules to load: t for every discovered module, or a list of names."
  :type '(choice (const :tag "All" t) (repeat symbol)) :group 'harness)

(defcustom harness-disabled-modules nil
  "Modules never to load, by name."
  :type '(repeat symbol) :group 'harness)

(defcustom harness-state-directory (locate-user-emacs-file "harness/")
  "Directory where the harness persists sessions, usage and settings."
  :type 'directory :group 'harness)

(defcustom harness-process t
  "Non-nil runs the harness in its own Emacs process, nil in this one.
Emacs runs Lisp on one thread, so harness work done in this Emacs --
tools, listings, model streams -- competes with typing and redisplay.
With this on, this Emacs loads only the UI and the harness runs in a
child `emacs --batch' it talks to over ACP (see harness-server.el).
nil is for tests and for debugging the modules in place."
  :type 'boolean :group 'harness)

(defconst harness--client-module-files '("lisp/modules/harness-acp.el")
  "Module files the UI loads besides lisp/ui when `harness-process' is on.
Only the ACP client half is used: its TCP server stays off here.")

(defvar harness-started nil "Non-nil once `harness-start' has run.")
(defvar harness-reload-hook nil "Hook run after a successful `harness-reload'.")
(defvar harness-start-hook nil "Hook run after `harness-start'.")

(defconst harness--self-file (expand-file-name "harness.el" harness-directory)
  "Absolute path of this file, reloaded first by `harness-reload'.")

(defconst harness--core-files '("lisp/harness-core.el" "lisp/harness-util.el"
                               "lisp/harness-http.el" "lisp/harness-elisp.el")
  "Files loaded before any module, in order, relative to `harness-directory'.
They define the macros modules expand, so a change to one recompiles
every file (see `harness--compiled-fresh-p').")

(defconst harness--library-files '("lisp/harness-files.el" "lisp/harness-emacs-endpoint.el"
                                  "lisp/harness-notifications-desktop.el" "lisp/harness-server.el"
                                  "lisp/harness-revision.el")
  "Libraries loaded after the core files and before any module, in order.
Both sides of the process split use them: the UI requires them all, and
the harness process's modules require harness-files,
harness-notifications-desktop and harness-revision (which notes, on
each side, the commit the harness was loaded from).  They are loaded
compiled as the core files are and every `harness-reload' loads them
again, so a reloaded module never calls a library function as it was
before the update; they define no macros, so a change to one does not
recompile the modules.")

(add-to-list 'load-path (expand-file-name "lisp" harness-directory))
(require 'harness-core)
(require 'harness-util)

(defun harness--path (relative)
  (expand-file-name relative harness-directory))

(defun harness--setup-load-path ()
  (dolist (dir (append '("lisp" "lisp/modules" "lisp/ui") harness-module-directories))
    (add-to-list 'load-path (harness--path dir))))

(defun harness--module-directories ()
  "Directories modules load from in this Emacs."
  (if harness-process '("lisp/ui") harness-module-directories))

(defun harness--file-module-name (file)
  "Return the module name symbol for FILE (harness-NAME.el -> NAME)."
  (intern (string-remove-prefix "harness-" (file-name-base file))))

(defun harness--module-files ()
  "Return the enabled module files, sorted by directory then name."
  (let ((files (and harness-process
                     (reverse (mapcar #'harness--path harness--client-module-files)))))
    (dolist (dir (harness--module-directories))
      (let ((full (harness--path dir)))
        (when (file-directory-p full)
          (dolist (f (directory-files full t "\\`harness-[a-z0-9-]+\\.el\\'"))
            (let ((name (harness--file-module-name f)))
              (when (and (or (eq harness-enabled-modules t)
                             (memq name harness-enabled-modules))
                         (not (memq name harness-disabled-modules)))
                (push f files)))))))
    (nreverse files)))

(defun harness--load-file (file)
  "Compile and load FILE with `harness--defining-module' bound to its module name."
  (let ((harness--defining-module (harness--file-module-name file)))
    (harness-load-compiled file)))

(defvar harness--defining-module)
(defvar harness-acp--server-enabled)
(defvar harness-ui-connection-address)
(declare-function harness-ui-reload-server "harness-ui")

;;;###autoload
(defun harness-start ()
  "Load the core and every enabled module, then initialise them.
Return non-nil when every module loaded and initialised."
  (interactive)
  (harness--setup-load-path)
  (dolist (f (append harness--core-files harness--library-files))
    (condition-case err
        (harness-load-compiled (harness--path f))
      (error (harness-log 'error "compiling %s failed: %S; loading source" f err)
             (load (harness--path f) nil 'nomessage))))
  (let (failed)
    (dolist (f (harness--module-files))
      (condition-case err
          (harness--load-file f)
        (error (push (cons (harness--file-module-name f) err) failed)
               (harness-log 'error "loading %s failed: %S" f err))))
    (when harness-process
      ;; The harness process serves ACP; this Emacs only connects to it.
      (setq harness-acp--server-enabled nil)
      (when (and (boundp 'harness-ui-connection-address)
                 (not (stringp harness-ui-connection-address)))
        (setq harness-ui-connection-address 'process)))
    (harness-modules-init)
    (setq harness-started t)
    (run-hooks 'harness-start-hook)
    (harness-emit 'harness/started)
    (let ((broken (append (mapcar #'car failed)
                          (mapcar #'harness-module-name
                                  (cl-remove-if-not (lambda (m) (eq (harness-module-state m) 'failed))
                                                    (harness-modules))))))
      (cond (broken
             (message "Harness %s started; modules failed: %s (see %s)"
                      harness-version (mapconcat #'symbol-name broken ", ")
                      harness-log-buffer-name))
            ((called-interactively-p 'any)
             (message "Harness %s started with %d modules"
                      harness-version (length (harness-modules)))))
      (null broken))))

(defun harness-stop ()
  "Shut every module down."
  (interactive)
  (when (featurep 'harness-core)
    (harness-emit 'harness/stopping)
    (harness-modules-shutdown))
  (setq harness-started nil))

;;;; Safe reload

(defvar harness-compile-subdirectory "elc/"
  "Subdirectory of `harness-state-directory' for compiled files.
The harness process uses its own so it never races the UI's compiles.")

(defun harness--compile-directory ()
  "Directory holding the byte-compiled files the harness loads."
  (let ((dir (expand-file-name harness-compile-subdirectory harness-state-directory)))
    (unless (file-directory-p dir) (make-directory dir t))
    dir))

(defun harness--compiled-name (file)
  "Return the .elc path in the compile directory for source FILE."
  (expand-file-name (concat (file-name-nondirectory file) "c") (harness--compile-directory)))

(defun harness--compile-file (file)
  "Byte-compile FILE into the compile directory; return the .elc path.
Signal an error describing the first problem when FILE does not parse
or compile.  Interpreted Emacs Lisp closures over large data can blow
the evaluation depth (seen with parsed model catalogues), so the
harness always runs compiled code, even while developing."
  (condition-case err
      (progn
        (with-temp-buffer
          (insert-file-contents file)
          ;; Only its syntax: the user's `emacs-lisp-mode-hook' (linters,
          ;; LSP...) has no business in a buffer that lives for a check.
          (delay-mode-hooks (emacs-lisp-mode))
          (check-parens)
          (goto-char (point-min))
          (condition-case rerr
              (while t (read (current-buffer)))
            (end-of-file nil)
            (error (error "%s" (error-message-string rerr)))))
        (let* ((dest (harness--compiled-name file))
               (byte-compile-dest-file-function (lambda (_f) dest))
               (byte-compile-verbose nil)
               (byte-compile-warnings nil)
               (inhibit-message t)
               (ok (byte-compile-file file)))
          (unless (eq ok t)
            (error "byte compilation failed (see *Compile-Log*)"))
          dest))
    (error (error "%s: %s" (file-name-nondirectory file) (error-message-string err)))))

(defun harness--check-file (file)
  "Return nil when FILE compiles, else an error string."
  (condition-case err
      (progn (harness--compile-file file) nil)
    (error (error-message-string err))))

(defun harness--compiled-fresh-p (file)
  "Non-nil when FILE's .elc is newer than FILE, harness.el and the core files.
Core files define the macros every module expands, so a change there
recompiles everything; a library file (`harness--library-files') does
not."
  (let ((elc (harness--compiled-name file)))
    (and (file-exists-p elc)
         (cl-every (lambda (src) (file-newer-than-file-p elc src))
                   (cons file (cons harness--self-file (mapcar #'harness--path harness--core-files)))))))

(defun harness-load-compiled (file)
  "Compile FILE unless its .elc is fresh, and load the result.
Used by tests and the loader."
  (load (if (harness--compiled-fresh-p file) (harness--compiled-name file) (harness--compile-file file))
        nil 'nomessage))

(defun harness--reload ()
  "Check every harness source file, then load them all again in place.
The files are this one, the core and library files, and the modules of
this Emacs.  Return (:refused PROBLEMS) when one of them does not
compile: then nothing was loaded.  Otherwise return (:files N :errors
ERRORS), where ERRORS describes the files that failed to load: the
others are loaded, modules that were not ready are initialised, and
`harness-reload-hook' and the `harness/reloaded' event have run.  In
the UI of a harness process, the process is asked to reload too."
  (harness--setup-load-path)
  (let* ((early (mapcar #'harness--path (append harness--core-files harness--library-files)))
         (files (append early (harness--module-files)))
         (problems (delq nil (mapcar #'harness--check-file files))))
    (if problems
        (progn
          (when (featurep 'harness-core)
            (dolist (p problems) (harness-log 'error "reload refused: %s" p)))
          (list :refused problems))
      (let ((errors nil))
        (load harness--self-file nil 'nomessage)
        (dolist (f files)
          (condition-case err
              (if (member f early)
                  (harness-load-compiled f)
                (harness--load-file f))
            (error (let ((problem (format "%s: %s" (file-name-nondirectory f) (error-message-string err))))
                     (harness-log 'error "reload: %s" problem)
                     (push problem errors)))))
        (harness-modules-init)
        (when (and harness-process (fboundp 'harness-ui-reload-server))
          (harness-ui-reload-server))
        (run-hooks 'harness-reload-hook)
        (harness-emit 'harness/reloaded)
        (list :files (length files) :errors (nreverse errors))))))

;;;###autoload
(defun harness-reload ()
  "Check every harness source file, then reload all of them in place.
Running sessions and buffers are kept: definitions are replaced under
them and `harness-reload-hook' plus the `harness/reloaded' event let
the UI redraw.  When any file fails to compile nothing is loaded.
Return non-nil when every file loaded again."
  (interactive)
  (let ((result (harness--reload)))
    (cond
     ((plist-get result :refused)
      (message "Harness reload refused: %s" (string-join (plist-get result :refused) "; "))
      nil)
     ((plist-get result :errors)
      (message "Harness reloaded with errors: %s" (string-join (plist-get result :errors) "; "))
      nil)
     (t (message "Harness reloaded (%d files)" (plist-get result :files))
        t))))

;;;; Automatic reload while developing

(defvar harness--watches nil)

(defun harness--auto-reload-callback (event)
  (pcase-let ((`(,_ ,action ,file . ,_) event))
    (when (and (memq action '(changed created renamed))
               (string-suffix-p ".el" file)
               (not (string-match-p "/\\.#\\|flycheck_\\|~\\'" file)))
      (harness-debounce 'auto-reload 0.6 #'harness-reload))))

(define-minor-mode harness-auto-reload-mode
  "Reload the harness whenever one of its source files changes on disk."
  :global t :group 'harness
  (dolist (w harness--watches) (ignore-errors (file-notify-rm-watch w)))
  (setq harness--watches nil)
  (when harness-auto-reload-mode
    (dolist (dir (cons "." (cons "lisp" harness-module-directories)))
      (let ((full (harness--path dir)))
        (when (file-directory-p full)
          (push (file-notify-add-watch full '(change) #'harness--auto-reload-callback)
                harness--watches))))))

;; A reload loads this file first, then every module file by name, and
;; the modules that define tools (harness-tools-fs.el, harness-merge.el,
;; harness-perms.el ...) sort before harness-tools.el, whose
;; `harness-define-tool' they call as they load.  So that they define
;; their tools with the registry as it is now, not as it was, a reload
;; loads the registry before them.
(when (featurep 'harness-tools)
  (condition-case err
      (harness--load-file (harness--path "lisp/modules/harness-tools.el"))
    (error (harness-log 'error "reloading the tool registry first failed: %S" err))))

(provide 'harness)
;;; harness.el ends here
