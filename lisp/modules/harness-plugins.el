;;; harness-plugins.el --- Projects' plugins, which their .dir-locals.el loads  -*- lexical-binding: t; -*-

;;; Commentary:

;; A project may carry harness modules of its own, its plugins: a tool
;; for working on that project, say, as the harness's own repository
;; has its open_harness (.harness/plugins/dev/).  The harness loads
;; none of them.  Emacs does, as it loads any project's Lisp: the
;; project's .dir-locals.el requires the plugin in an `eval' entry, and
;; names the plugin modules its sessions use in `harness-plugin-modules'
;; (the harness's own repository's .dir-locals.el is the example):
;;
;;   ((nil . ((eval . (require 'harness-dev-plugin
;;                             (expand-file-name
;;                              ".harness/plugins/dev/harness-dev-plugin"
;;                              (locate-dominating-file default-directory ".dir-locals.el"))))
;;            (harness-plugin-modules . (tools-dev)))))
;;
;; That repository's `eval' also refuses to load from a checkout nested
;; in another, such as a task's worktree: in the user's Emacs, visiting
;; a worktree's file would otherwise load the worktree's copy of the
;; plugin, which its agent may have changed, if none had loaded yet.
;;
;; Emacs's own trust decides.  Neither entry is safe as it is, so Emacs
;; asks before applying them -- the first time a file of the project is
;; visited, and again whenever they change -- and answering `!' trusts
;; them for good: it records them in `safe-local-variable-values'.
;;
;; In the user's Emacs that is all: the plugin's UI half loads there
;; when a file of the project is visited.  The harness process cannot
;; ask anybody.  Before a session of the project starts there, it
;; applies the project's directory-local variables in a buffer of its
;; own with Emacs's own `hack-dir-local-variables-non-file-buffer',
;; taking only what is safe or trusted already (`harness-plugins--apply'):
;; the `require' loads the plugin's other half, which defines its tools.
;; Only a project whose variables set `harness-plugin-modules' has them
;; applied there, so the `eval' entries a user trusted for editing
;; some other project never run in the harness process.
;; The user's Emacs gives the process the user's settings for this
;; (`harness-server-dir-locals-variables') when it starts it, and any
;; change to them at once (`plugins/trust'), so trusting a project's
;; variables reaches the sessions that start afterwards.  The harness
;; applies the variables of a project's main checkout, never those of
;; a linked worktree such as a task's: what an agent changes there
;; reaches the harness once it is merged.  A plugin's code loads once in
;; the process, by its `require'.
;;
;; Frozen in the jail.  A session takes its list of plugin modules when
;; it starts, which is when it enters the jail, and keeps it for good,
;; in its `:ext' under `:plugins', across restarts of the harness:
;; nothing that happens while it works changes what it has
;; (`harness-plugins--freeze').  A session that another session starts
;; -- a fork, a sub-agent, a side conversation, anything with a
;; `:parent-id', and a session made during one of its tool calls, such
;; as the task task_submit makes -- takes the list of the session that
;; started it, not what the files say by then.  So the list a session
;; gets changes only from outside every jail: when the user trusts a new
;; value in their Emacs, or sets `harness-plugin-modules' in their init
;; file.  An agent that rewrites a project's .dir-locals.el changes
;; nothing until the user trusts what it wrote.
;;
;; Emacs trusts entries, not the directory they are in: a copy of a
;; trusted .dir-locals.el elsewhere, beside plugin code of another's,
;; is trusted all the same.  So the harness applies no checkout that a
;; jailed agent could have made (`harness-plugins--planted-p'): one in
;; the sessions' temporary directories, in a .git directory, or nested
;; in another checkout -- where an agent writes -- whether a session
;; names it or a worktree's rewritten .git file leads there.
;;
;; A plugin's modules keep the harness's conventions: file
;; harness-NAME.el holds module NAME, and modules named ui or ui-* are
;; the halves that run in the user's Emacs.  A module the harness did
;; not load from its own directories is a plugin
;; (`harness-module-plugin-p'): its tools are offered to, and callable
;; from, only the sessions whose list names it (see
;; `harness-tools--in-scope-p').  A plugin module starts as soon as its
;; file has loaded.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)

(defvar harness-server-dir-locals-variables)
(defvar harness-tools-calling-session)
(declare-function harness-module-plugin-p "harness" (name))
(declare-function harness-session-tmp-root "harness-session" ())

(defcustom harness-plugin-modules nil
  "The plugin modules a project's sessions use, by name.
A project names them in its .dir-locals.el, beside the `eval' entry that
requires the plugin, for every mode:

  ((nil . ((harness-plugin-modules . (tools-dev)))))

The tools of a plugin module are offered only to the sessions whose
list names it.  No value is safe as it is: Emacs asks before taking a
project's, as it does for the `eval' that loads the plugin, and `!'
trusts it.  A session keeps the list it started with, and one that
another session starts takes that session's (see harness-plugins.el).

The global value is the list of a project that names none: set it in
your init file for plugins every project may use."
  :type '(repeat symbol) :group 'harness)

(defconst harness-plugins--ext-key :plugins
  "The `:ext' key under which a session keeps its plugin modules.
Its value is their names, strings, or `:false' for none: a session
without the key has not frozen its list yet.")

(defvar harness-plugins--applied (make-hash-table :test 'equal)
  "Directories whose directory-local variables this process applied, to t.")

;;;; Names

(defun harness-plugins--names (value)
  "Return VALUE, a list of plugin modules, as their names: symbols, once each.
An entry may be a symbol or a string; anything else, and an empty
name, counts for nothing.  A VALUE that is no list gives none."
  (and (listp value) (proper-list-p value)
       (delete-dups
        (delq nil (mapcar (lambda (entry)
                            (cond ((and entry (symbolp entry) (not (eq entry t))
                                        (not (keywordp entry)))
                                   entry)
                                  ((and (stringp entry) (not (string-empty-p entry)))
                                   (intern entry))))
                          value)))))

(defun harness-plugins--stored (names)
  "Return NAMES as a session's `:ext' keeps them: strings, or `:false' for none."
  (if names (mapcar #'symbol-name names) :false))

;;;; Applying a project's directory-local variables

(defun harness-plugins--safe-directory-p (dir)
  "Non-nil when the user trusts every directory-local variable that applies in DIR.
That is when `safe-local-variable-directories' (Emacs 30) names the
directory of the .dir-locals.el that applies there, as Emacs checks."
  (when-let* (((boundp 'safe-local-variable-directories))
              (safe (symbol-value 'safe-local-variable-directories))
              (top (locate-dominating-file dir dir-locals-file)))
    (cl-some (lambda (entry) (and (stringp entry) (ignore-errors (file-equal-p entry top))))
             safe)))

(defun harness-plugins--enable-local-variables (dir)
  "Return the `enable-local-variables' to apply DIR's variables with.
The user's own, but for its usual t, which would ask about the
variables that are neither safe nor trusted: nobody can be asked here,
so those are left out (:safe), as Emacs leaves out those the user
declines.  Where `safe-local-variable-directories' trusts every
variable of DIR, every one applies (:all), as in the user's Emacs.
An `enable-local-eval' of t does not make an `eval' the user has not
trusted run here: only :all would, and it would apply every risky
variable of the project too, a hook among them."
  (cond ((null enable-local-variables) nil)
        ((eq enable-local-variables :all) :all)
        ((harness-plugins--safe-directory-p dir) :all)
        (t :safe)))

(defun harness-plugins--names-modules-p (dir)
  "Non-nil when the directory-local variables of DIR set `harness-plugin-modules'.
They are only read, as Emacs reads them before it decides what to
apply: nothing is evaluated, trusted or not."
  (with-temp-buffer
    (setq default-directory dir)
    (let ((found (condition-case err
                     ;; Its PREDICATE is no optional argument before Emacs 30.
                     (hack-dir-local--get-variables nil)
                   (error (harness-log 'warn "plugins: reading the directory-local variables of %s: %s"
                                       (abbreviate-file-name dir) (error-message-string err))
                          nil))))
      (and (assq 'harness-plugin-modules (cdr-safe found)) t))))

(defun harness-plugins--start-new (before)
  "Start the plugin modules registered since BEFORE, a list of module names.
They start at once, rather than when their files have loaded (see
`harness-define-module'), so the session they were loaded for finds
them ready.  `harness-disabled-modules' still keeps one from starting."
  (let ((new (cl-loop for module in (harness-modules)
                      for name = (harness-module-name module)
                      when (and (not (memq name before))
                                (eq (harness-module-state module) 'registered)
                                (fboundp 'harness-module-plugin-p)
                                (harness-module-plugin-p name)
                                (not (memq name (bound-and-true-p harness-disabled-modules))))
                      collect name)))
    (when new (harness-modules-init new))))

(defun harness-plugins--apply (dir)
  "Apply the directory-local variables of DIR as Emacs would.
Return the plugin modules DIR names: the value of
`harness-plugin-modules' there, as a list of names, DIR's own when its
variables set it, else the global one.  The variables are applied to
a buffer of their own, with the user's settings, without asking
anyone: what is neither safe nor trusted is left out (see
`harness-plugins--enable-local-variables').  Their `eval' entries run,
a `require' of the project's plugin among them; the plugin modules
that registers start at once.  A failure is logged, and gives what was
set before it.

Only the variables of a project that uses plugins are applied: when
they do not set `harness-plugin-modules', nothing of them is, so the
`eval' entries a user trusted for their editing never run here."
  (let ((dir (file-name-as-directory (expand-file-name dir)))
        (before (mapcar #'harness-module-name (harness-modules))))
    (prog1
        (if (not (harness-plugins--names-modules-p dir))
            (harness-plugins--names (default-value 'harness-plugin-modules))
          (with-temp-buffer
            (setq default-directory dir)
            (let ((enable-local-variables (harness-plugins--enable-local-variables dir)))
              (condition-case err
                  (hack-dir-local-variables-non-file-buffer)
                (error (harness-log 'warn "plugins: the directory-local variables of %s: %s"
                                    (abbreviate-file-name dir) (error-message-string err)))))
            (harness-plugins--names harness-plugin-modules)))
      (puthash dir t harness-plugins--applied)
      (harness-plugins--start-new before))))

;;;; Sessions

(defun harness-plugins--planted-p (dir)
  "Non-nil when DIR is where a jailed agent could have made a project.
Emacs trusts a project's entries, not the directory they are in, so a
copy of a trusted .dir-locals.el that an agent wrote, beside plugin
code of its own, would load that code.  An agent writes in its
working directory, the repository's git directories, its temporary
directory and the directories granted to it.  So DIR is refused when
it lies in the sessions' temporary directories, in a .git directory,
or inside another checkout -- a task's worktree, or a main checkout --
as a project of the user's never does.  Ancestors are looked at below
the home directory only, which some users keep in git."
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (tmp (and (fboundp 'harness-session-tmp-root) (harness-session-tmp-root)))
         (home (file-name-as-directory (expand-file-name "~")))
         (up (file-name-directory (directory-file-name dir)))
         (inside nil))
    (while (and up (not inside) (not (equal up home))
                (not (equal up (file-name-directory (directory-file-name up)))))
      (when (file-exists-p (expand-file-name ".git" up))
        (setq inside up))
      (setq up (file-name-directory (directory-file-name up))))
    (or (and tmp (file-in-directory-p dir tmp))
        (and (member ".git" (split-string dir "/" t)) t)
        (and inside t))))

(defun harness-plugins--checkout (session)
  "Return the main checkout of SESSION's project, as a directory name, or nil.
A session in a linked git worktree, such as a task's, belongs to the
main checkout of its repository (`harness-files-owning-checkout').  A
session on another host has none: plugins are this machine's.  Nor
has one whose checkout a jailed agent could have made, reached by a
worktree's .git file it rewrote, say (`harness-plugins--planted-p'),
nor a project nested in another checkout, such as a submodule: their
sessions use no plugin."
  (let* ((project (plist-get session :project))
         (cwd (plist-get session :cwd))
         (root (cond ((and (stringp project) (not (string-empty-p project))) project)
                     ((and (stringp cwd) (not (string-empty-p cwd))) cwd)))
         (checkout (and root (not (file-remote-p root)) (not (plist-get session :host))
                        (file-name-as-directory
                         (expand-file-name (harness-files-owning-checkout root))))))
    (if (and checkout (harness-plugins--planted-p checkout))
        (progn (when (harness-plugins--names-modules-p checkout)
                 (harness-log 'warn "plugins: session %s: %s could be a jail's making; no plugins from there"
                              (plist-get session :id) (abbreviate-file-name checkout)))
               nil)
      checkout)))

(defun harness-plugins--frozen (session)
  "Return SESSION's frozen plugin modules as (t . NAMES).
Nil while it has not frozen them."
  (let ((ext (plist-get session :ext)))
    (when (plist-member ext harness-plugins--ext-key)
      (let ((value (plist-get ext harness-plugins--ext-key)))
        (cons t (and (listp value) (harness-plugins--names value)))))))

(defun harness-plugins--get (id)
  "Return the plist of session ID, or nil when there is no such session."
  (and (stringp id) (harness-call 'session/exists-p id)
       (harness-call 'session/get id)))

(defun harness-plugins--freeze (id &optional seen starter)
  "Freeze the plugin modules of session ID, unless it has; return their names.
A session another session started (`:parent-id', else STARTER, the
session whose tool call made it) takes the frozen list of that one,
freezing it first if need be, or none once that one is gone; any
other, what the directory-local variables of its project's main
checkout name (`harness-plugins--apply').  SEEN lists the sessions on
the way, so a cycle of parents ends."
  (let* ((session (harness-plugins--get id))
         (frozen (and session (harness-plugins--frozen session))))
    (cond
     ((null session) nil)
     (frozen (cdr frozen))
     (t
      (let* ((parent (or (plist-get session :parent-id) starter))
             (names (cond ((null parent)
                           (when-let* ((root (harness-plugins--checkout session)))
                             (harness-plugins--apply root)))
                          ((and (not (member parent seen)) (harness-plugins--get parent))
                           (harness-plugins--freeze parent (cons id seen))))))
        (harness-call 'session/set-ext id harness-plugins--ext-key (harness-plugins--stored names))
        names)))))

(defun harness-plugins--load (id &optional seen)
  "Make sure the plugins of session ID have loaded in this process.
A session that froze its list before the harness last started still
needs the plugins' code: the directory-local variables of its
project's main checkout are applied, once per process, and so are
those of the session that started it, up the chain.  SEEN is as for
`harness-plugins--freeze'."
  (when-let* ((session (harness-plugins--get id)))
    (let ((root (harness-plugins--checkout session))
          (parent (plist-get session :parent-id)))
      (when (and root (not (gethash root harness-plugins--applied)))
        (harness-plugins--apply root))
      (when (and parent (not (member parent seen)))
        (harness-plugins--load parent (cons id seen))))))

(defun harness-plugins--on-created (id session)
  "Freeze the plugin modules of the new session ID, whose plist is SESSION.
A subscriber of `session/created': a session enters its jail as it
starts.  A list its maker gave it in `:ext' stays.  One made while
a tool call of another session runs (`harness-tools-calling-session'),
as task_submit makes a task's, was started by that session, and takes
its list: an agent can give a session no more than it has, whatever
directory it names."
  (unless (plist-member (plist-get session :ext) harness-plugins--ext-key)
    (condition-case err
        (harness-plugins--freeze id nil (let ((caller (bound-and-true-p harness-tools-calling-session)))
                                          (and (stringp caller) (not (equal caller id)) caller)))
      (error (harness-log 'warn "plugins: freezing the plugins of session %s: %s"
                          id (error-message-string err))))))

;;;; Methods

(harness-defmethod plugins/of-session (id)
  "Return the plugin modules session ID uses, as it froze them: a list of names.
A session from before it froze its list freezes it now (see
harness-plugins.el).  The plugins' code is loaded first when this
process has not loaded it yet.  A session that does not exist uses
none."
  (let ((names (harness-plugins--freeze id)))
    (when names (harness-plugins--load id))
    names))

(harness-defmethod plugins/trust (values)
  "Take the user's settings for directory-local variables from VALUES.
VALUES is an alist ((VARIABLE . VALUE) ...), printed as `read' reads it,
of the variables `harness-server-dir-locals-variables' names; any
other is ignored.  The UI sends it when one of them changed in the
user's Emacs -- the user trusting a project's variables, say -- so the
sessions that start afterwards get what the user trusts.  Return the
names of the variables set."
  (let ((alist (if (stringp values) (car (read-from-string values)) values))
        (set nil))
    (unless (listp alist) (error "Not an alist of variables: %S" values))
    (dolist (cell alist)
      (when (and (consp cell) (memq (car cell) harness-server-dir-locals-variables))
        (set-default (car cell) (cdr cell))
        (push (car cell) set)))
    (nreverse set)))

;;;; Init

(defun harness-plugins--init ()
  "Freeze the plugin modules of each session as it starts."
  (harness-on 'session/created #'harness-plugins--on-created))

(defun harness-plugins--shutdown ()
  "Freeze no more lists."
  (harness-off (cons 'session/created #'harness-plugins--on-created)))

(harness-define-module 'plugins
  :doc "Projects' plugins: what a project's trusted .dir-locals.el loads, and the plugin modules each session froze."
  :requires '(session)
  :init #'harness-plugins--init
  :shutdown #'harness-plugins--shutdown)

(provide 'harness-plugins)
;;; harness-plugins.el ends here
