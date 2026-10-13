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
;; Modules of the user's own live in `harness-extra-module-directories',
;; outside the harness's tree, and load beside its own.
;;
;; Libraries that are not the harness's -- compose-quote, which the
;; compose box quotes with -- live under lisp/vendor, a directory each,
;; laid out as their own repositories would be (lisp/vendor/README.md).
;; Their directories are on `load-path' from the moment this file loads.
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

(defun harness--source-directory (file)
  "Return the directory of the harness sources, given FILE, the harness.el loading.
FILE may be harness.el or its .elc.  Symbolic links are followed:
straight.el and elpaca build a package as links into their git clone,
and the harness runs from the clone itself, so that updating the clone
\(`harness-update', a git pull) reaches every file, the ones it adds
included, without rebuilding the package."
  (let ((source (expand-file-name "harness.el" (file-name-directory file))))
    (file-name-directory (file-truename (if (file-exists-p source) source file)))))

(defun harness--stale-compiled-p (file)
  "Non-nil when FILE is a compiled harness.el older than the source it links to.
A package manager's build keeps the copy it compiled while the clone
moves on (`harness-update', a git pull): loading only the copy would
run the old harness.el with every other file new."
  (and file
       (string-suffix-p ".elc" file)
       (file-newer-than-file-p (expand-file-name "harness.el" (harness--source-directory file))
                               file)))

(defconst harness-directory
  (harness--source-directory (or load-file-name buffer-file-name
                                 (locate-library "harness") default-directory))
  "Directory containing harness.el, symbolic links followed.
See `harness--source-directory'.")

(defun harness--vendored-directories (&optional root)
  "Return the directories of the libraries vendored under ROOT, sorted.
ROOT is the harness's tree, `harness-directory' by default.  Each
subdirectory of its lisp/vendor holds one library, laid out as its own
repository would be and needing nothing of the harness (see
lisp/vendor/README.md).  The result is absolute names without a
trailing slash, nil when there is no lisp/vendor; a hidden directory
holds no library.

This file calls it as it loads, to put the libraries on `load-path', so
it comes before `harness--path'."
  (let ((vendor (expand-file-name "lisp/vendor" (or root harness-directory))))
    (when (file-directory-p vendor)
      (sort (cl-loop for dir in (directory-files vendor t "\\`[^.]")
                     when (file-directory-p dir) collect (directory-file-name dir))
            #'string<))))

(defgroup harness nil
  "Emacs native agent harness."
  :group 'tools :prefix "harness-")

(defcustom harness-module-directories '("lisp/modules" "lisp/ui")
  "Directories, relative to `harness-directory', that hold module files.
Every file named harness-NAME.el in them is a module called NAME.
These are the harness's own; modules of your own go in
`harness-extra-module-directories'."
  :type '(repeat string) :group 'harness)

(defcustom harness-extra-module-directories nil
  "Directories of modules of your own, outside the harness's tree.
Each is absolute, or relative to `user-emacs-directory'.  As in the
harness's own directories, every file named harness-NAME.el in them is
a module called NAME, which `harness-enabled-modules' and
`harness-disabled-modules' name like any other.

A module named ui or ui-NAME (in harness-ui-NAME.el) is a UI module:
it loads where the harness's own UI modules do, in this Emacs.  Every
other module loads where the rest of the harness runs: in the harness
process while `harness-process' is on, else in this Emacs too.  A
module whose name an earlier one has, the harness's own included, is
left out, with a warning in the log.

The modules are compiled and reloaded like the harness's own:
`harness-reload' and `harness-update' reload them, and
`harness-auto-reload-mode' watches their directories, which are on
`load-path' so that a module can require the other files of its
directory.  The harness process reads this option when it starts, so
after changing it run \\[harness-restart]."
  :type '(repeat directory) :group 'harness)

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

(defconst harness--library-files '("lisp/harness-policy.el" "lisp/harness-files.el"
                                  "lisp/harness-redaction.el"
                                  "lisp/harness-emacs-endpoint.el"
                                  "lisp/harness-notifications-desktop.el" "lisp/harness-server.el"
                                  "lisp/harness-revision.el" "lisp/harness-slots.el"
                                  "lisp/vendor/compose-quote/compose-quote.el")
  "Libraries loaded after the core files and before any module, in order.
Both sides of the process split use them: the UI requires them all, and
the harness process's modules require harness-policy (the settings an
administrator fixes, which each side reads for itself), harness-files,
harness-redaction (how a secret is named and taken out of text, which
the harness process's modules and the commands of the UI share),
harness-notifications-desktop, harness-revision (which notes, on each
side, the commit the harness was loaded from) and harness-emacs-endpoint
\(whose `harness-emacs-eval' each side reads for itself).  Only the
harness process's modules use harness-slots, the pools of slots that
hold work back to so many at once (the tool slots, the task board's
title requests).  They are loaded compiled as the core files are and
every `harness-reload' loads them again, so a reloaded module never
calls a library function as it was before the update; they define no
macros, so a change to one does not recompile the modules.

The last is vendored (lisp/vendor/README.md): compose-quote, which the
compose box quotes with.  Listed here it loads compiled at start, and
`harness-reload' checks it compiles and loads it again, as it does
the others.")

(add-to-list 'load-path (expand-file-name "lisp" harness-directory))
;; The libraries vendored under lisp/vendor go on `load-path' as this file
;; loads, not only when the harness starts: an Emacs that merely loads
;; harness.el must find them.  That is the harness process, the tests,
;; and above all the check of an update by a harness older than this
;; one, which loads the new harness.el and then compiles every file of
;; the new tree, where the compose box requires `compose-quote'.
(dolist (dir (harness--vendored-directories))
  (add-to-list 'load-path dir))
(require 'harness-core)
(require 'harness-util)
(require 'harness-revision)

(defun harness--path (relative)
  "Return RELATIVE, a file name in the harness's tree, made absolute."
  (expand-file-name relative harness-directory))

(defun harness--extra-module-directories ()
  "Return `harness-extra-module-directories' as absolute directory names.
An entry that is not absolute is relative to `user-emacs-directory'."
  (cl-loop for dir in harness-extra-module-directories
           when (stringp dir)
           collect (directory-file-name (expand-file-name dir user-emacs-directory))))

(defun harness--setup-load-path ()
  "Put the harness's directories on `load-path', and the user's module ones.
The harness's are lisp/, the module directories and the directory of
each library vendored under lisp/vendor (`harness--vendored-directories').
The harness's go first, the user's last, so that a file of the user's
never shadows a library."
  (dolist (dir (append '("lisp" "lisp/modules" "lisp/ui") harness-module-directories))
    (add-to-list 'load-path (harness--path dir)))
  (dolist (dir (harness--vendored-directories (harness--path ".")))
    (add-to-list 'load-path dir))
  (dolist (dir (harness--extra-module-directories))
    (add-to-list 'load-path dir t)))

(defun harness--module-directories ()
  "Directories modules load from in this Emacs."
  (if harness-process '("lisp/ui") harness-module-directories))

(defconst harness--module-file-regexp "\\`harness-[a-z0-9-]+\\.el\\'"
  "Names of module files: harness-NAME.el holds module NAME.")

(defun harness--file-module-name (file)
  "Return the module name symbol for FILE (harness-NAME.el -> NAME)."
  (intern (string-remove-prefix "harness-" (file-name-base file))))

(defun harness--ui-module-p (name)
  "Non-nil when module NAME, a symbol, is a UI module: ui or ui-SOMETHING."
  (string-match-p "\\`ui\\(?:-\\|\\'\\)" (symbol-name name)))

(defun harness--ui-module-file-p (file)
  "Non-nil when FILE, a module's source or compiled file, holds a UI module."
  (string-match-p "\\`harness-ui\\(?:-\\|\\'\\)" (file-name-base file)))

(defun harness--module-enabled-p (name)
  "Non-nil when module NAME is to load.
That is when `harness-enabled-modules' has it and
`harness-disabled-modules' does not."
  (and (or (eq harness-enabled-modules t)
           (memq name harness-enabled-modules))
       (not (memq name harness-disabled-modules))))

(defun harness--module-files ()
  "Return the enabled module files of this Emacs, in the order they load.
The harness's own come first, by directory then name, then those of
`harness-extra-module-directories', likewise.  Of these, a UI module
\(`harness--ui-module-p') loads where the harness's own UI modules do,
from lisp/ui, and any other where the rest of its modules do, from
lisp/modules.  One whose name an earlier one has, or one of the
harness's libraries, is left out with a warning: it would replace it."
  (let* ((dirs (harness--module-directories))
         (kinds (append (and (member "lisp/ui" dirs) '(ui))
                        (and (member "lisp/modules" dirs) '(other))))
         (files (and harness-process
                     (reverse (mapcar #'harness--path harness--client-module-files))))
         (taken (mapcar (lambda (f) (cons (harness--file-module-name f) (harness--path f)))
                        (append harness--core-files harness--library-files
                                harness--client-module-files))))
    (dolist (dir dirs)
      (let ((full (harness--path dir)))
        (when (file-directory-p full)
          (dolist (f (directory-files full t harness--module-file-regexp))
            (let ((name (harness--file-module-name f)))
              (when (harness--module-enabled-p name)
                (push f files)
                (push (cons name f) taken)))))))
    (dolist (dir (harness--extra-module-directories))
      (when (file-directory-p dir)
        (dolist (f (directory-files dir t harness--module-file-regexp))
          (let ((name (harness--file-module-name f)))
            (when (and (memq (if (harness--ui-module-p name) 'ui 'other) kinds)
                       (harness--module-enabled-p name))
              (if-let* ((other (alist-get name taken)))
                  (harness-log 'warn "module %s: %s is left out, as %s has that name"
                               name (abbreviate-file-name f) (abbreviate-file-name other))
                (push f files)
                (push (cons name f) taken)))))))
    (nreverse files)))

(defun harness--load-file (file)
  "Compile and load FILE with `harness--defining-module' bound to its module name.
`harness--defining-file' is bound to FILE, which its module records as
its source: what loads is a compiled copy elsewhere."
  (let ((harness--defining-module (harness--file-module-name file))
        (harness--defining-file file))
    (harness-load-compiled file)))

(defvar harness--defining-module)
(defvar harness--defining-file)
(defvar harness-acp--server-enabled)
(defvar harness-ui-connection-address)
(declare-function harness-ui-reload-server "harness-ui")
(declare-function harness-policy-load "harness-policy")
(declare-function harness-policy-apply "harness-policy" (&optional final))
(declare-function straight-pull-package "straight" (package &optional from-upstream))

;;;###autoload
(defun harness-start ()
  "Load the core and every enabled module, then initialise them.
The policy (see harness-policy.el) is read first and applied before any
module loads, and again once they all have: a policy that cannot be
trusted signals an error, and nothing starts.
Return non-nil when every module loaded and initialised."
  (interactive)
  (harness--setup-load-path)
  (dolist (f (append harness--core-files harness--library-files))
    (condition-case err
        (harness-load-compiled (harness--path f))
      (error (harness-log 'error "compiling %s failed: %S; loading source" f err)
             (load (harness--path f) nil 'nomessage))))
  ;; Before any module: which ones load is a setting too.  Required
  ;; too, in case the library files left it out: no policy is no option.
  (condition-case err
      (progn (require 'harness-policy)
             (harness-policy-load)
             (harness-policy-apply))
    (error (harness-log 'error "%s" (error-message-string err))
           (signal (car err) (cdr err))))
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
    ;; The options the modules define.  The UI of a harness process
    ;; lacks those of lisp/modules, which that process applies itself.
    (condition-case err
        (harness-policy-apply (not harness-process))
      (error (harness-log 'error "%s" (error-message-string err))
             (signal (car err) (cdr err))))
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
            (error "Byte compilation failed (see *Compile-Log*)"))
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
        ;; The policy file is read again; one that cannot be trusted
        ;; leaves the policy in force as it was.  Applying it again
        ;; also guards anew the options whose definitions were evaluated.
        (dolist (step (list (lambda () (require 'harness-policy))
                            #'harness-policy-load
                            (lambda () (harness-policy-apply (not harness-process)))))
          (condition-case err
              (funcall step)
            (error (let ((problem (error-message-string err)))
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
  "Schedule `harness-reload' for EVENT, a file notification of a watch.
A change, creation or rename of an .el file reloads the harness 0.6
seconds after the last such event; lock and flycheck files do not."
  (pcase-let ((`(,_ ,action ,file . ,_) event))
    (when (and (memq action '(changed created renamed))
               (string-suffix-p ".el" file)
               (not (string-match-p "/\\.#\\|flycheck_\\|~\\'" file)))
      (harness-debounce 'auto-reload 0.6 #'harness-reload))))

(define-minor-mode harness-auto-reload-mode
  "Reload the harness whenever one of its source files changes on disk.
The libraries vendored under lisp/vendor and the modules of
`harness-extra-module-directories' count as its sources."
  :global t :group 'harness
  (dolist (w harness--watches) (ignore-errors (file-notify-rm-watch w)))
  (setq harness--watches nil)
  (when harness-auto-reload-mode
    (dolist (full (append (mapcar #'harness--path (cons "." (cons "lisp" harness-module-directories)))
                          (harness--vendored-directories (harness--path "."))
                          (harness--extra-module-directories)))
      (when (file-directory-p full)
        (push (file-notify-add-watch full '(change) #'harness--auto-reload-callback)
              harness--watches)))))

;;;; Version and updates

;; The harness has no numbered releases to follow: its branch is the
;; release, and the commit a checkout is at is its version.  So
;; `harness-update' updates the git checkout the harness runs from (a
;; clone of its own, or the one straight.el or elpaca keeps, see
;; `harness--source-directory') to its upstream branch, then reloads.
;;
;; That checkout is the live harness, which must load at the next start
;; whatever an update brought.  So the update only ever fast-forwards,
;; which cannot conflict, and only to a commit checked first in another
;; Emacs, out of the checkout: its harness.el loads, every file compiles
;; and none has a merge conflict marker in its code.  A broken version
;; stays out.  Git and that Emacs run in the background, so this Emacs
;; stays responsive meanwhile.

(defun harness--fail (format-string &rest args)
  "Return a promise rejected with an error saying FORMAT-STRING with ARGS."
  (harness-rejected (list 'error (apply #'format-message format-string args))))

(defun harness--git-environment ()
  "Return the environment alist under which git runs in the background.
Nothing may prompt for a password or a passphrase nobody waits on: not
the terminal (there is none), not an askpass program or a credential
manager, which would put a dialog on the screen, nor ssh, run in batch
mode (keys in the agent still work) unless the user set up an ssh
command.  An empty GIT_ASKPASS keeps git from falling back to
core.askPass and SSH_ASKPASS."
  (append '(("GIT_TERMINAL_PROMPT" . "0")
            ("GIT_ASKPASS" . "")
            ("SSH_ASKPASS_REQUIRE" . "never")
            ("GCM_INTERACTIVE" . "never"))
          (unless (or (getenv "GIT_SSH_COMMAND") (getenv "GIT_SSH"))
            '(("GIT_SSH_COMMAND" . "ssh -o BatchMode=yes")))))

(defun harness--git (dir &rest args)
  "Run git with ARGS in DIR; return a promise of its trimmed output.
The promise is rejected with an error carrying git's message when git
fails, a prompt for credentials included: git cannot prompt, see
`harness--git-environment'."
  (harness-then
   (harness-run-command (cons "git" args) :cwd dir :name "harness-git"
                        :env (harness--git-environment))
   (lambda (result)
     (let ((exit (plist-get result :exit))
           (lines (cl-remove-if (lambda (line) (string-prefix-p "hint:" line))
                                (split-string (plist-get result :stderr) "\n" t "[ \t]+"))))
       (if (eql exit 0)
           (string-trim (plist-get result :stdout))
         (harness--fail "git %s: %s" (car args)
                        (cond ((eq exit 'timeout) "timed out")
                              (lines (string-join lines "; "))
                              (t (format "exited with status %s" exit)))))))))

(defun harness--checkout-top (dir)
  "Return a promise resolved when DIR is the top of a git checkout.
It is rejected when DIR is not in a git checkout, or is in one whose
top is another directory: a harness kept inside a larger repository,
such as a configuration's, is that repository's to update."
  (harness-then
   (harness--git dir "rev-parse" "--show-toplevel")
   (lambda (top)
     (or (file-equal-p top dir)
         (harness--fail "%s is inside the git repository %s, not a checkout of its own" dir top)))
   (lambda (err)
     (if (locate-dominating-file dir ".git")
         (harness-rejected err)
       (harness--fail "%s is not a git checkout; update the harness with the package manager that installed it"
                      dir)))))

(defconst harness--conflict-marker-regexp
  (rx bol (or (seq (or "<<<<<<<" "|||||||" ">>>>>>>") (opt " " (* nonl))) "=======") eol)
  "Regexp matching a line git writes around the sides of a merge conflict.")

(defun harness--verify-program (tree out)
  "Return a form that checks the harness sources in TREE, compiling into OUT.
`emacs --batch -Q' evaluates it on a version about to be installed.  It
loads harness.el first, into an Emacs as fresh as one starting up, then
byte-compiles every source file: the harness-NAME.el files under lisp/,
and the .el files, their tests (NAME-test.el) aside, of the libraries
vendored under lisp/vendor, whose directories it puts on `load-path'
beside the harness's.  It prints a line for each file that does not
load or compile, or has a merge conflict marker in its code, naming it
by its path in TREE, and exits non-zero when there is one.  The markers
need a check of their own: a conflict between two balanced sides
compiles, its markers read as variables, and fails only as it runs.  The
form uses nothing of the harness, so that any version can check any
other: it finds the vendored directories itself, as
`harness--vendored-directories' does."
  `(let ((problems nil)
         ;; The directories of the libraries vendored in TREE, sorted.
         (vendored
          (let ((vendor (expand-file-name "lisp/vendor" ,tree)) (dirs nil))
            (when (file-directory-p vendor)
              (dolist (dir (directory-files vendor t "\\`[^.]"))
                (when (file-directory-p dir) (push dir dirs))))
            (nreverse dirs)))
         (conflict-line
          (lambda (file)
            (with-temp-buffer
              (insert-file-contents file)
              (emacs-lisp-mode)
              (let ((line nil))
                (while (and (not line) (re-search-forward ,harness--conflict-marker-regexp nil t))
                  (let ((end (match-end 0)))
                    ;; In code only: a line of a string may be anything.
                    (unless (nth 3 (syntax-ppss (match-beginning 0)))
                      (setq line (line-number-at-pos (match-beginning 0))))
                    (goto-char end)))
                line))))
         (compile-problem
          (lambda (file name)
            (unless (byte-compile-file file)
              (with-current-buffer (get-buffer-create byte-compile-log-buffer)
                (goto-char (point-max))
                (if (re-search-backward "Error: \\(.*\\)" nil t)
                    (format "%s: %s" name (match-string 1))
                  (format "%s does not compile" name)))))))
     (make-directory ,out t)
     (dolist (dir '("" "lisp" "lisp/modules" "lisp/ui"))
       (push (expand-file-name dir ,tree) load-path))
     (dolist (dir vendored)
       (push dir load-path))
     (setq byte-compile-dest-file-function
           (lambda (file) (expand-file-name (concat (file-name-nondirectory file) "c") ,out)))
     (dolist (file (append
                    (list (expand-file-name "harness.el" ,tree))
                    (and (file-directory-p (expand-file-name "lisp" ,tree))
                         (directory-files-recursively (expand-file-name "lisp" ,tree)
                                                      "\\`harness-.*\\.el\\'"))
                    ;; A vendored library's files do not start with "harness-".
                    ;; Its tests are not part of what the harness runs.
                    (let ((files nil))
                      (dolist (dir vendored)
                        (dolist (f (directory-files dir t "\\`[^.].*\\.el\\'"))
                          (unless (string-match-p "-test\\.el\\'" f)
                            (push f files))))
                      (nreverse files))))
       (let* ((name (file-relative-name file ,tree))
              (problem
               (condition-case err
                   (let ((line (funcall conflict-line file)))
                     (cond
                      (line (format "%s:%d: a merge conflict marker" name line))
                      ((and (equal name "harness.el")
                            (condition-case load-error (progn (load file nil t t) nil)
                              (error (format "%s does not load: %s"
                                             name (error-message-string load-error))))))
                      (t (funcall compile-problem file name))))
                 (error (format "%s: %s" name (error-message-string err))))))
         (when problem (push problem problems))))
     (dolist (problem (nreverse problems))
       (princ (concat problem "\n")))
     (kill-emacs (if problems 1 0))))

(defun harness--verify-commit (dir rev)
  "Return a promise resolved when the sources of commit REV of DIR pass a check.
REV is checked out of the repository of DIR into a temporary directory
and checked there by another Emacs, `harness-server-emacs', so that
neither DIR nor this Emacs is touched: harness.el must load, and every
source file compile, with no merge conflict marker in its code (see
`harness--verify-program').  The promise is rejected with the problems
otherwise."
  (let* ((tmp (file-name-as-directory (make-temp-file "harness-update-" t)))
         (tree (expand-file-name "tree/" tmp))
         (archive (expand-file-name "update.tar" tmp))
         (emacs (if (boundp 'harness-server-emacs) harness-server-emacs
                  (expand-file-name invocation-name invocation-directory))))
    (make-directory tree)
    (harness-then
     (thread-first
       (harness--git dir "archive" "--format=tar" "-o" archive rev)
       (harness-then (lambda (_)
                       (harness-run-command (list "tar" "-xf" archive "-C" tree) :name "harness-tar")))
       (harness-then (lambda (result)
                       (if (eql 0 (plist-get result :exit))
                           (harness-run-command
                            (list emacs "--batch" "-Q" "--eval"
                                  (prin1-to-string (harness--verify-program tree (expand-file-name "elc/" tmp))))
                            :cwd tree :timeout 600 :name "harness-verify")
                         (harness--fail "tar: %s" (string-trim (plist-get result :stderr))))))
       (harness-then (lambda (result)
                       (or (eql 0 (plist-get result :exit))
                           (harness--fail "%s is broken, so it was not installed: %s"
                                          (substring rev 0 (min 12 (length rev)))
                                          (let ((problems (split-string (plist-get result :stdout) "\n" t)))
                                            (cond
                                             ((null problems)
                                              (format "the check exited with %s" (plist-get result :exit)))
                                             ((cdr (cdr (cdr problems)))
                                              (format "%s; and %d more" (string-join (seq-take problems 3) "; ")
                                                      (- (length problems) 3)))
                                             (t (string-join problems "; ")))))))))
     (lambda (value) (delete-directory tmp t) value)
     (lambda (err) (delete-directory tmp t) (harness-rejected err)))))

(defconst harness--update-listed 20
  "How many of the commits an update brought its changelog lists.
The newest are listed, with a count of the rest.")

(defun harness--update-result (dir from target)
  "Return the update result for DIR having moved FROM to TARGET.
FROM and TARGET are full commits.  The commits that came in are read as
changelog entries, newest first: their subjects and message bodies, no
diff or file statistics.  When there is any, TARGET is checked by
another Emacs (`harness--verify-commit') and DIR is fast-forwarded to
it, so a broken version is never installed and a fast-forward cannot
conflict.  The result is (:from FROM-short :to TO-short :commits COMMITS
:count COUNT): COMMITS are the newest of the commits that came in, each
(:commit :date :subject :body), and COUNT counts every one of them."
  (let (commits count)
    (thread-first
      (harness-all
       (list (harness--git dir "rev-list" "--count" (concat from ".." target))
             (harness--git dir "log" "-z" "--no-merges"
                           (format "--max-count=%d" harness--update-listed)
                           (concat "--format=" harness-revision-commit-format)
                           (concat from ".." target) "--")))
      (harness-then
       (lambda (parts)
         (setq count (string-to-number (string-trim (car parts)))
               commits (harness-revision-parse-commits (cadr parts)))
         (when (> count 0)
           (thread-first
             (harness--verify-commit dir target)
             (harness-then (lambda (_) (harness--git dir "merge" "--ff-only" "--quiet" target)))
             (harness-then (lambda (_) nil))))))
      (harness-then (lambda (_) (harness--git dir "rev-parse" "--short" "HEAD")))
      (harness-then (lambda (to) (list :from (substring from 0 7) :to to
                                       :commits commits :count count))))))

(defun harness--update-checkout (dir)
  "Fast-forward DIR, a git checkout of the harness, to its remote branch.
The remote is the one DIR's branch tracks, or else origin, or else its
only remote, and the branch is the one it tracks there, or else DIR's
own branch; that is how straight.el and the other package managers
configure a clone, and how a checkout that tracks nothing is updated.
The remote branch is fetched by name, and the commit it names is
checked by another Emacs, out of the checkout (`harness--verify-commit'),
before DIR moves to it, so a broken version is never installed; a
fast-forward cannot conflict.  Return a promise of (:from FROM :to TO
:commits COMMITS :count COUNT): FROM and TO are the abbreviated commits
before and after, the same when nothing was new; COMMITS are the newest
commits that came in, each (:commit :date :subject :body), and COUNT
counts every one of them.  The promise is rejected, and DIR left as it
was, when DIR is not the top of a git checkout, its tracked files have
changes, its HEAD is detached, it has no remote, its branch has commits
the remote lacks, or the remote's commit fails the check."
  (let ((dir (file-name-as-directory (expand-file-name dir)))
        target)
    (thread-first
      (harness--checkout-top dir)
      (harness-then (lambda (_) (harness--git dir "status" "--porcelain" "--untracked-files=no")))
      (harness-then (lambda (changes)
                      (if (string-empty-p changes)
                          (harness-then (harness--git dir "symbolic-ref" "--short" "HEAD")
                                        #'identity
                                        (lambda (_err) nil))
                        (harness--fail "%s has local changes; commit or discard them first" dir))))
      (harness-then (lambda (branch)
                      (if (null branch)
                          (harness--fail "%s follows no branch to update from: its HEAD is detached.  Check out the branch to update, or update the harness with the package manager that installed it"
                                         dir)
                        (harness-revision-remote dir branch))))
      (harness-then (lambda (remote)
                      (cond
                       ((null remote)
                        (harness--fail "%s has no remote to update from; update the harness with the package manager that installed it"
                                       dir))
                       ((null (plist-get remote :branch))
                        (harness--fail "%s tracks no branch of %s to update from"
                                       dir (plist-get remote :remote)))
                       (t
                        (harness-then
                         (harness--git dir "fetch" "--quiet"
                                       (plist-get remote :remote) (plist-get remote :branch))
                         #'identity
                         (lambda (err)
                           (if (plist-get remote :tracked)
                               (harness-rejected err)
                             (harness--fail "%s follows no upstream branch and %s has no branch %s to fetch (%s)"
                                            dir (plist-get remote :remote) (plist-get remote :branch)
                                            (harness-error-message err)))))))))
      (harness-then (lambda (_) (harness--git dir "rev-parse" "--verify" "FETCH_HEAD^{commit}")))
      (harness-then (lambda (commit)
                      (setq target commit)
                      (harness--git dir "rev-parse" "HEAD")))
      (harness-then (lambda (from)
                      (thread-first
                        (harness--git dir "rev-list" "--left-right" "--count"
                                      (concat "HEAD..." target))
                        (harness-then
                         (lambda (counts)
                           (pcase-let ((`(,ours ,theirs)
                                        (mapcar #'string-to-number (split-string counts))))
                             (if (and (> ours 0) (> theirs 0))
                                 (harness--fail "%s has %d commit%s the upstream lacks; not updating"
                                                dir ours (if (= ours 1) "" "s"))
                               (harness--update-result dir from target)))))))))))

(defun harness--straight-package ()
  "Return the name of the straight.el package this harness runs from, or nil.
That is the harness's directory under straight's repos, or the build
directory of links into it, when it is one: straight.el installs a
package by cloning its repository there.  Nil for a checkout of one's
own, and in an Emacs that never loaded straight.el."
  (when (stringp harness-directory)
    (let* ((dir (file-name-as-directory (expand-file-name harness-directory)))
           (name (file-name-nondirectory (directory-file-name dir)))
           (parent (file-name-directory (directory-file-name dir)))
           (grand (and parent (file-name-directory (directory-file-name parent)))))
      (or (when (fboundp 'straight--repos-dir)
            (let ((repos (file-name-as-directory (expand-file-name (straight--repos-dir)))))
              (when (and (not (equal repos dir))
                         (equal (file-name-directory (directory-file-name dir)) repos))
                name)))
          (when (and grand parent
                     (equal (file-name-nondirectory (directory-file-name grand)) "straight")
                     (let ((kind (file-name-nondirectory (directory-file-name parent))))
                       (or (equal kind "repos") (string-prefix-p "build" kind))))
            name)))))

(defun harness--straight-pull (dir package)
  "Pull PACKAGE, the straight.el package whose checkout is DIR, and report it.
straight's own pull (`straight-pull-package') fetches and merges the
repository and branch its recipe names, which need not be the ones DIR's
branch tracks; that is what an install from straight.el is updated
with.  With nothing new it does not move DIR.  The commit it lands on is
checked like any other (`harness--verify-commit'), and DIR is put back to
the commit it held when the check fails, so a broken version is not left
installed.  Return the promise of the same plist
`harness--update-checkout' makes."
  (let ((dir (file-name-as-directory (expand-file-name dir)))
        from target)
    (thread-first
      (harness--git dir "status" "--porcelain" "--untracked-files=no")
      (harness-then (lambda (changes)
                      (if (string-empty-p changes)
                          (harness--git dir "rev-parse" "HEAD")
                        (harness--fail "%s has local changes; commit or discard them first" dir))))
      (harness-then (lambda (head)
                      (setq from head)
                      (condition-case err
                          (progn (straight-pull-package package) t)
                        (error (harness--fail "straight-pull-package failed: %s"
                                              (error-message-string err))))))
      (harness-then (lambda (_) (harness--git dir "rev-parse" "HEAD")))
      (harness-then (lambda (head)
                      (if (equal head from)
                          (list :from (substring from 0 7) :to (substring from 0 7)
                                :commits nil :count 0)
                        (setq target head)
                        (harness-catch
                         (harness--update-result dir from target)
                         (lambda (err)
                           (harness-then (harness--git dir "reset" "--keep" from)
                                         (lambda (_) (harness-rejected err))
                                         (lambda (_) (harness-rejected err)))))))))))

(defun harness--update-package (dir)
  "Update DIR, the checkout the harness runs from, the way it was installed.
A checkout straight.el manages is pulled with its own
`straight-pull-package', the way its package manager updates it, when
this Emacs has straight.el loaded; any other checkout is fast-forwarded
to its remote branch (`harness--update-checkout')."
  (let ((package (and (fboundp 'straight-pull-package) (harness--straight-package))))
    (if package
        (harness--straight-pull dir package)
      (harness--update-checkout dir))))

(defvar harness--last-update nil
  "The last update's outcome, a plist; see `harness-update-hook'.")

(defvar harness-update-hook nil
  "Hook run after `harness-update' settles, with the outcome as its argument.
The outcome is a plist: :state \"updated\", \"up-to-date\" or \"failed\";
:from and :to the abbreviated commits; :commits the newest commits that
came in, each (:commit :date :subject :body); :count how many came in;
:reload the `harness--reload' result or nil; :message the line shown;
:at when it settled; and :error why it failed.")

(defun harness--updated (dir result)
  "Report RESULT of `harness--update-checkout' on DIR, reloading what came in.
Return the message shown, and record the outcome in `harness--last-update'
and on `harness-update-hook' for the version page."
  (let* ((from (plist-get result :from))
         (to (plist-get result :to))
         (commits (plist-get result :commits))
         (count (or (plist-get result :count) (length commits)))
         (summary (format "Harness updated from %s to %s (%d commit%s)"
                          from to count (if (= count 1) "" "s")))
         state reload text)
    (if (zerop count)
        (setq state "up-to-date"
              text (format "Harness is up to date (%s)" to))
      (setq state "updated")
      (harness-log 'info "update: %s..%s brought:\n  %s" from to
                   (string-join (mapcar (lambda (c)
                                          (format "%s %s" (substring (plist-get c :commit) 0 7)
                                                  (plist-get c :subject)))
                                        commits)
                                "\n  "))
      (cond
       ((not harness-started)
        (setq text (format "%s; `harness-start' loads it" summary)))
       (t
        (setq reload (harness--reload))
        (setq text
              (cond
               ((plist-get reload :refused)
                (format "%s, but the reload was refused: %s.  The harness still runs %s: restart Emacs to load the update, or go back with git -C %s reset --keep %s"
                        summary (string-join (plist-get reload :refused) "; ") from
                        (shell-quote-argument (directory-file-name dir)) from))
               ((plist-get reload :errors)
                (format "%s and reloaded, but these failed to load: %s"
                        summary (string-join (plist-get reload :errors) "; ")))
               (t (format "%s and reloaded" summary)))))))
    (message "%s" text)
    (setq harness--last-update (list :state state :from from :to to :commits commits
                                     :count count :reload reload :message text
                                     :at (float-time)))
    (run-hook-with-args 'harness-update-hook harness--last-update)
    text))

(defvar harness--updating nil
  "Non-nil while `harness-update' runs, so that two updates never overlap.")

;;;###autoload
(defun harness-update ()
  "Update the harness from its checkout, then reload it in place.
The harness runs from a git checkout of its own.  The remote branch to
fetch is the one its branch tracks, or else the same-named branch of
origin, or of its only remote; a checkout straight.el manages is pulled
with `straight-pull-package', the way its package manager updates it.
A detached HEAD and a checkout without a remote are refused with a
message that says so.  When the remote has new commits, the newest is
checked by another Emacs, out of the checkout: its harness.el must load,
and every source file compile with no merge conflict marker in its
code.  Only then is the checkout fast-forwarded to it and
`harness-reload' run, which loads it in this Emacs and in the harness
process, keeping running sessions.  Nothing changes when the update
fails the check, or the checkout has local changes or commits of its
own.  Git and the checking Emacs run in the background: this Emacs stays
responsive.  The harness log and the version page list the commits that
came in, each with its subject and message body."
  (interactive)
  (when harness--updating
    (user-error "The harness is updating already"))
  (setq harness--updating t)
  (message "Harness: fetching and checking updates…")
  (let ((dir harness-directory))
    (harness-then (harness--update-package dir)
                  (lambda (result)
                    (setq harness--updating nil)
                    ;; From the command loop, not the dynamic extent of git's sentinel.
                    (harness-run-soon #'harness--updated dir result)
                    nil)
                  (lambda (err)
                    (setq harness--updating nil)
                    (let ((reason (harness-error-message err)))
                      (message "Harness update failed: %s" reason)
                      (setq harness--last-update
                            (list :state "failed" :error reason
                                  :message (format "Harness update failed: %s" reason)
                                  :at (float-time)))
                      (run-hook-with-args 'harness-update-hook harness--last-update))
                    nil))))

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

;; Loaded from a compiled copy older than the source: the source is
;; what is installed, so it loads over the copy, as a reload would.
(when (harness--stale-compiled-p load-file-name)
  (load harness--self-file nil t t))

(provide 'harness)
;;; harness.el ends here
