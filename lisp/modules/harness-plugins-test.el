;;; harness-plugins-test.el --- Tests for projects' plugins  -*- lexical-binding: t; -*-

;;; Commentary:

;; A project's .dir-locals.el loads its plugin with a `require' and
;; names its plugin modules in `harness-plugin-modules'; the harness
;; applies those entries as Emacs would, with what the user trusts, and
;; each session freezes the list it starts with (harness-plugins.el).
;; The plugin here is a file of the test's own, harness-fakeplug.el,
;; defining module fakeplug and its tool fake_tool.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-tools)

(defvar harness-sessions)
(defvar harness-model)
(defvar harness-plugins--applied)
(defvar harness-plugin-modules)
(defvar harness-server-dir-locals-variables)

(defvar harness-tools)
(defvar harness-tools-calling-session)

(declare-function harness-plugins--apply "harness-plugins" (dir))
(declare-function harness-plugins--checkout "harness-plugins" (session))
(declare-function harness-plugins--planted-p "harness-plugins" (dir))
(declare-function harness-session-tmp-root "harness-session" ())
(declare-function harness-files-owning-checkout "harness-files" (root))
(declare-function harness-server--forwarded "harness-server")

(defconst harness-plugins-test--plugin
  '((require 'harness-tools)
    (harness-define-tool "fake_tool" :label "Fake tool"
                         :handler (lambda (_input _ctx) "faked"))
    (harness-define-module 'fakeplug :requires '(tools))
    (provide 'harness-fakeplug))
  "The forms of harness-fakeplug.el, the plugin of the test projects.")

(defun harness-plugins-test--write (file form)
  "Write FORM, or the forms of the list FORM when it starts with a list, to FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert ";;; -*- lexical-binding: t -*-\n")
    (let ((print-length nil) (print-level nil))
      (dolist (f (if (consp (car-safe form)) form (list form)))
        (prin1 f (current-buffer))
        (insert "\n")))))

(defun harness-plugins-test--entries (modules)
  "Return the entries of a .dir-locals.el that loads the plugin and names MODULES."
  (list '(eval . (require 'harness-fakeplug
                          (expand-file-name "plug/harness-fakeplug"
                                            (locate-dominating-file default-directory ".dir-locals.el"))))
        (cons 'harness-plugin-modules modules)))

(defun harness-plugins-test--project (&optional modules dir)
  "Make a project whose .dir-locals.el loads the plugin and names MODULES.
MODULES defaults to (fakeplug); the project is DIR, made if missing, by
default a new temporary directory.  Return its directory."
  (let ((dir (if dir
                 (progn (make-directory dir t) (file-name-as-directory dir))
               (harness-test-temp-dir))))
    (harness-plugins-test--write (expand-file-name "plug/harness-fakeplug.el" dir)
                                 harness-plugins-test--plugin)
    (harness-plugins-test--locals dir (or modules '(fakeplug)))
    dir))

(defun harness-plugins-test--locals (dir modules)
  "Make DIR's .dir-locals.el load the plugin and name MODULES.
Emacs reads it again then: the file it cached may have the same time,
written in the same tick of the clock."
  (with-temp-file (expand-file-name ".dir-locals.el" dir)
    (let ((print-length nil) (print-level nil))
      (prin1 (list (cons nil (harness-plugins-test--entries modules))) (current-buffer))
      (insert "\n")))
  (setq dir-locals-directory-cache nil))

(defun harness-plugins-test--forget-plugin ()
  "Unload the plugin: its feature, its module and its tool."
  (setq features (delq 'harness-fakeplug features))
  (remhash 'fakeplug harness--modules)
  (remhash "fake_tool" harness-tools))

(defmacro harness-plugins-test-with (&rest body)
  "Run BODY with sessions, tools and plugins on a fresh bus.
Nothing is trusted: `safe-local-variable-values' is empty and
`enable-local-variables' asks, as Emacs's defaults do."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config tools session plugins))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-plugins--applied)
     (harness-plugins-test--forget-plugin)
     (let ((safe-local-variable-values nil)
           (enable-local-variables t)
           (enable-local-eval 'maybe)
           (harness-plugin-modules nil)
           (dir-locals-directory-cache nil)
           (dir-locals-class-alist nil))
       (unwind-protect (progn ,@body)
         (harness-plugins-test--forget-plugin)))))

(defun harness-plugins-test--session (dir &rest plist)
  "Create a session working in DIR, with PLIST; return its id."
  (plist-get (apply #'harness-call 'session/create :cwd dir :project dir plist) :id))

(defun harness-plugins-test--frozen (id)
  "Return what session ID keeps under `:plugins' in its `:ext'."
  (plist-get (plist-get (harness-call 'session/get id) :ext) :plugins))

(defun harness-plugins-test--tools (id)
  "Return the names of the tools session ID gets."
  (harness-tools--names (harness-call 'session/get id)))

(ert-deftest harness-plugins-load-only-what-the-user-trusts ()
  "A project's .dir-locals.el loads its plugin once the user trusts its entries.
Untrusted, the `eval' that requires the plugin does not run and the list
naming its module does not count: the session starts with no plugin,
and nothing loads.  Trusted as Emacs's `!' trusts them, the harness
applies them as Emacs would: the plugin loads, its module starts, and a
session starting then names it and gets its tool.  The one that started
before keeps its list, which named nothing."
  (harness-plugins-test-with
    (let* ((dir (harness-plugins-test--project))
           (before (harness-plugins-test--session dir)))
      (should (eq :false (harness-plugins-test--frozen before)))
      (should-not (featurep 'harness-fakeplug))
      (should-not (harness-tool-get "fake_tool"))
      (setq safe-local-variable-values (harness-plugins-test--entries '(fakeplug)))
      (let ((after (harness-plugins-test--session dir)))
        (should (equal '("fakeplug") (harness-plugins-test--frozen after)))
        (should (featurep 'harness-fakeplug))
        (should (harness-module-plugin-p 'fakeplug))
        (should (harness-module-ready-p 'fakeplug))
        (should (equal '(fakeplug) (harness-call 'plugins/of-session after)))
        (should (member "fake_tool" (harness-plugins-test--tools after)))
        (should-not (member "fake_tool" (harness-plugins-test--tools before)))
        (harness-add-filter 'permission/decide (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
        (should (equal "faked"
                       (plist-get (harness-test-await
                                   (harness-call 'tools/execute after (list :id "c1" :name "fake_tool")))
                                  :content)))
        (let ((result (harness-test-await
                       (harness-call 'tools/execute before (list :id "c2" :name "fake_tool")))))
          (should (plist-get result :is-error))
          (should (string-prefix-p "Unknown tool fake_tool" (plist-get result :content))))))))

(ert-deftest harness-plugins-what-is-trusted-is-the-very-value ()
  "Trust is for the values the user trusted, not for the variables.
A list rewritten after the user trusted another, as an agent in the
jail could rewrite it, does not count until the user trusts it too, and
the user's own settings are followed: with `enable-local-variables'
nil nothing applies; with :all, or in a directory
`safe-local-variable-directories' names, everything does."
  (harness-plugins-test-with
    (let ((dir (harness-plugins-test--project '(fakeplug other))))
      (setq safe-local-variable-values (harness-plugins-test--entries '(fakeplug)))
      ;; The eval is trusted and runs; the rewritten list is not.
      (should-not (harness-plugins--apply dir))
      (should (featurep 'harness-fakeplug))
      (harness-plugins-test--forget-plugin)
      (let ((enable-local-variables nil))
        (should-not (harness-plugins--apply dir))
        (should-not (featurep 'harness-fakeplug)))
      (let ((safe-local-variable-values nil)
            (enable-local-variables :all))
        (should (equal '(fakeplug other) (harness-plugins--apply dir)))
        (should (featurep 'harness-fakeplug)))
      ;; Emacs 30 trusts every variable of the directories the user names.
      (when (boundp 'safe-local-variable-directories)
        (harness-plugins-test--forget-plugin)
        (let ((safe-local-variable-values nil))
          (cl-progv '(safe-local-variable-directories) (list (list (directory-file-name dir)))
            (should (equal '(fakeplug other) (harness-plugins--apply dir)))
            (should (featurep 'harness-fakeplug)))
          (harness-plugins-test--forget-plugin)
          (cl-progv '(safe-local-variable-directories) (list (list (harness-test-temp-dir)))
            (should-not (harness-plugins--apply dir))
            (should-not (featurep 'harness-fakeplug))))))))

(defvar harness-plugins-test--ran nil
  "Set by the `eval' entry of a project that uses no plugin.")

(ert-deftest harness-plugins-only-a-project-that-names-modules-is-applied ()
  "The harness applies only the variables of a project that uses plugins.
A project whose .dir-locals.el does not set `harness-plugin-modules'
has none of its entries applied in the harness process, not even an
`eval' the user trusts: that is for editing the project, in the user's
Emacs.  Its sessions take the global list."
  (harness-plugins-test-with
    (let* ((dir (harness-plugins-test--project))
           (entry '(eval . (setq harness-plugins-test--ran t)))
           (write (lambda (entries)
                    (with-temp-file (expand-file-name ".dir-locals.el" dir)
                      (prin1 (list (cons nil entries)) (current-buffer)))
                    (setq dir-locals-directory-cache nil)))
           (harness-plugin-modules '(everywhere)))
      (funcall write (list entry))
      (setq safe-local-variable-values (list entry)
            harness-plugins-test--ran nil)
      (should (equal '("everywhere") (harness-plugins-test--frozen (harness-plugins-test--session dir))))
      (should-not harness-plugins-test--ran)
      (should-not (featurep 'harness-fakeplug))
      ;; Once it names modules, all it has trusted applies, that entry too.
      (funcall write (cons entry (harness-plugins-test--entries '(fakeplug))))
      (setq safe-local-variable-values (cons entry (harness-plugins-test--entries '(fakeplug))))
      (should (equal '("fakeplug") (harness-plugins-test--frozen (harness-plugins-test--session dir))))
      (should harness-plugins-test--ran)
      (should (featurep 'harness-fakeplug)))))

(ert-deftest harness-plugins-a-session-keeps-the-list-it-started-with ()
  "A session freezes its list as it enters the jail and keeps it for good.
Neither the project's .dir-locals.el changing nor the user trusting the
change gives a session that started before any other list, a restart
of the harness included; the sessions that start afterwards get the
new one."
  (harness-plugins-test-with
    (let ((dir (harness-plugins-test--project)))
      (setq safe-local-variable-values (harness-plugins-test--entries '(fakeplug)))
      (let ((old (harness-plugins-test--session dir)))
        (should (equal '(fakeplug) (harness-call 'plugins/of-session old)))
        (harness-plugins-test--locals dir nil)
        (setq safe-local-variable-values (harness-plugins-test--entries nil))
        (should (equal '(fakeplug) (harness-call 'plugins/of-session old)))
        (should (member "fake_tool" (harness-plugins-test--tools old)))
        (let ((new (harness-plugins-test--session dir)))
          (should (eq :false (harness-plugins-test--frozen new)))
          (should-not (member "fake_tool" (harness-plugins-test--tools new))))
        ;; As after a restart of the harness: the frozen list stays, and
        ;; the plugin's code loads again from the project's variables.
        (harness-plugins-test--forget-plugin)
        (clrhash harness-plugins--applied)
        (setq safe-local-variable-values (harness-plugins-test--entries nil))
        (should (equal '(fakeplug) (harness-call 'plugins/of-session old)))
        (should (featurep 'harness-fakeplug))
        (should (member "fake_tool" (harness-plugins-test--tools old)))))))

(ert-deftest harness-plugins-a-started-session-takes-its-parents-list ()
  "A session that another session starts takes that one's list, not the files'.
A fork, a sub-agent or a side conversation (`:parent-id') gets the
frozen list of its parent, whatever the directory it works in names
and the user trusts there; one whose parent is gone gets none."
  (harness-plugins-test-with
    (let ((dir (harness-plugins-test--project))
          (elsewhere (harness-plugins-test--project '(other))))
      (setq safe-local-variable-values (append (harness-plugins-test--entries '(fakeplug))
                                               (harness-plugins-test--entries '(other))))
      (let* ((parent (harness-plugins-test--session dir))
             (child (harness-plugins-test--session elsewhere :parent-id parent :kind 'subagent))
             (plain (harness-plugins-test--session dir)))
        (should (equal '("fakeplug") (harness-plugins-test--frozen child)))
        (should (member "fake_tool" (harness-plugins-test--tools child)))
        ;; Without a parent, a session of ELSEWHERE takes what it names.
        (should (equal '("other") (harness-plugins-test--frozen
                                   (harness-plugins-test--session elsewhere))))
        ;; A grandchild too, through its parent.
        (should (equal '("fakeplug") (harness-plugins-test--frozen
                                      (harness-plugins-test--session elsewhere :parent-id child))))
        (should (equal '("fakeplug") (harness-plugins-test--frozen plain)))
        (should (eq :false (harness-plugins-test--frozen
                            (harness-plugins-test--session dir :parent-id "gone"))))))))

(ert-deftest harness-plugins-a-tool-call-gives-the-sessions-it-makes-its-list ()
  "A session made during a tool call of another takes that one's list.
As task_submit makes a task's session: the task gets what the agent
that submitted it has, whatever directory it names -- no plugin it
does not have, and the one it has."
  (harness-plugins-test-with
    (let ((dir (harness-plugins-test--project))
          (plain (harness-test-temp-dir)))
      (setq safe-local-variable-values (harness-plugins-test--entries '(fakeplug)))
      (harness-add-filter 'permission/decide (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
      (harness-define-tool "t_make_session" :label "Make a session"
                           :handler (lambda (input _ctx)
                                      (harness-plugins-test--session (plist-get input :dir))))
      (unwind-protect
          (let ((make (lambda (caller where)
                        (plist-get (harness-test-await
                                    (harness-call 'tools/execute caller
                                                  (list :id (harness-short-id) :name "t_make_session"
                                                        :input (list :dir where))))
                                   :content))))
            ;; An agent with no plugin makes a session in the plugin's
            ;; project: it gets none, and nothing loads.
            (let* ((without (harness-plugins-test--session plain))
                   (made (funcall make without dir)))
              (should (eq :false (harness-plugins-test--frozen without)))
              (should (eq :false (harness-plugins-test--frozen made)))
              (should-not (featurep 'harness-fakeplug)))
            ;; One with the plugin passes it on, wherever it makes the session.
            (let* ((with (harness-plugins-test--session dir))
                   (made (funcall make with plain)))
              (should (equal '("fakeplug") (harness-plugins-test--frozen with)))
              (should (equal '("fakeplug") (harness-plugins-test--frozen made))))
            ;; Outside a tool call, the session's own project decides.
            (should (eq :false (harness-plugins-test--frozen (harness-plugins-test--session plain))))
            (should-not harness-tools-calling-session))
        (remhash "t_make_session" harness-tools)))))

(ert-deftest harness-plugins-none-from-where-a-jail-writes ()
  "No checkout a jailed agent could have made is applied.
A copy of the trusted .dir-locals.el is trusted wherever it is, so one
an agent wrote beside its own plugin code would load that code.  Not
in a task's worktree, nor nested in any checkout, nor in a .git
directory, nor in the sessions' temporary directories -- whether a
session works there or a worktree's rewritten .git file leads there.
The same project anywhere else loads."
  (harness-plugins-test-with
    (setq safe-local-variable-values (harness-plugins-test--entries '(fakeplug)))
    (let* ((worktree (harness-test-temp-dir))
           (main (harness-test-temp-dir))
           (lured (harness-test-temp-dir))
           (tmp (expand-file-name (format "planted-%s/" (harness-short-id)) (harness-session-tmp-root)))
           (places (list (expand-file-name "nested/" worktree)
                         (expand-file-name ".git/planted/" main)
                         tmp)))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name ".git" worktree) (insert "gitdir: /nowhere\n"))
            (make-directory (expand-file-name ".git/" main) t)
            (dolist (place places)
              (harness-plugins-test--project nil place)
              (ert-info ((format "a project in %s" place))
                (should (eq :false (harness-plugins-test--frozen (harness-plugins-test--session place))))))
            ;; A worktree whose .git file an agent rewrote to lead to a
            ;; checkout it made inside it.
            (let ((fake (expand-file-name "fake/" lured)))
              (harness-plugins-test--project nil fake)
              (make-directory (expand-file-name ".git/worktrees/x/" fake) t)
              (with-temp-file (expand-file-name ".git/worktrees/x/commondir" fake) (insert "../..\n"))
              (with-temp-file (expand-file-name ".git" lured)
                (insert "gitdir: " (expand-file-name ".git/worktrees/x" fake) "\n"))
              (should (equal (directory-file-name fake)
                             (directory-file-name (harness-files-owning-checkout lured))))
              (should (harness-plugins--planted-p fake))
              (should-not (harness-plugins--checkout (list :project lured)))
              (should (eq :false (harness-plugins-test--frozen (harness-plugins-test--session lured)))))
            (should-not (featurep 'harness-fakeplug))
            ;; The same project where no jail writes.
            (should (equal '("fakeplug") (harness-plugins-test--frozen
                                          (harness-plugins-test--session (harness-plugins-test--project)))))
            (should (featurep 'harness-fakeplug)))
        (ignore-errors (delete-directory tmp t))))))

(ert-deftest harness-plugins-a-worktree-takes-its-main-checkouts-list ()
  "A session in a linked worktree takes what the main checkout names.
What an agent writes in its task's worktree -- a .dir-locals.el naming
another module, even one the user trusts -- reaches the harness only
once it is merged into the main checkout."
  (harness-plugins-test-with
    (let ((main (harness-plugins-test--project))
          (worktree (harness-plugins-test--project '(other))))
      ;; MAIN is a repository's main checkout, WORKTREE a linked worktree
      ;; of it, as git writes them.
      (make-directory (expand-file-name ".git/worktrees/wt/" main) t)
      (with-temp-file (expand-file-name ".git/worktrees/wt/commondir" main) (insert "../..\n"))
      (with-temp-file (expand-file-name ".git" worktree)
        (insert "gitdir: " (expand-file-name ".git/worktrees/wt" main) "\n"))
      (setq safe-local-variable-values (append (harness-plugins-test--entries '(fakeplug))
                                               (harness-plugins-test--entries '(other))))
      (let ((id (harness-plugins-test--session worktree)))
        (should (equal '("fakeplug") (harness-plugins-test--frozen id)))
        (should (gethash (file-name-as-directory main) harness-plugins--applied))
        (should-not (gethash (file-name-as-directory worktree) harness-plugins--applied))))))

(ert-deftest harness-plugins-old-sessions-freeze-on-first-use ()
  "A session from before sessions froze their lists freezes it when first asked.
Its tools are asked for, and it takes what its project names then."
  (harness-plugins-test-with
    (let ((dir (harness-plugins-test--project)))
      (setq safe-local-variable-values (harness-plugins-test--entries '(fakeplug)))
      (let ((id (harness-plugins-test--session dir)))
        (harness-call 'session/set-ext id :plugins nil)
        (should-not (plist-member (plist-get (harness-call 'session/get id) :ext) :plugins))
        (should (member "fake_tool" (harness-plugins-test--tools id)))
        (should (equal '("fakeplug") (harness-plugins-test--frozen id)))))))

(ert-deftest harness-plugins-trust-takes-the-users-trust-settings-only ()
  "`plugins/trust' sets the settings for directory-local variables, nothing else.
It takes them printed, as the UI sends them over ACP, and the sessions
that start afterwards get what they trust."
  (harness-plugins-test-with
    (let ((dir (harness-plugins-test--project))
          (harness-model "demo:demo-model")
          (print-length nil) (print-level nil))
      (should (equal '(safe-local-variable-values)
                     (harness-call 'plugins/trust
                                   (prin1-to-string
                                    (list (cons 'safe-local-variable-values
                                                (harness-plugins-test--entries '(fakeplug)))
                                          (cons 'harness-model "evil:model"))))))
      (should (equal "demo:demo-model" harness-model))
      (should (equal (harness-plugins-test--entries '(fakeplug)) safe-local-variable-values))
      (should (equal '("fakeplug") (harness-plugins-test--frozen (harness-plugins-test--session dir))))
      (should-error (harness-call 'plugins/trust "42")))))

(ert-deftest harness-plugins-the-ui-forwards-the-users-trust ()
  "The harness process gets the user's settings for directory-local variables.
Those the user set go with the rest of its configuration, as their
global values: a project's own variables, which a buffer visiting one
of its files has, are that buffer's."
  (require 'harness-server)
  (let ((safe-local-variable-values '((harness-plugin-modules . (fakeplug))))
        (harness-plugin-modules nil))
    (with-temp-buffer
      (setq-local harness-plugin-modules '(local))
      (setq-local safe-local-variable-values '((local . t)))
      (let ((forwarded (harness-server--forwarded)))
        (should (equal '((harness-plugin-modules . (fakeplug)))
                       (cdr (assq 'safe-local-variable-values forwarded))))
        (should-not (equal '(local) (cdr (assq 'harness-plugin-modules forwarded))))))
    (should (memq 'safe-local-variable-values harness-server-dir-locals-variables))
    (should (memq 'enable-local-variables harness-server-dir-locals-variables))))

(provide 'harness-plugins-test)
;;; harness-plugins-test.el ends here
