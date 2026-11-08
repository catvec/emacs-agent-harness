;;; harness-commit-msg-test.el --- Tests for the commit-msg module  -*- lexical-binding: t; -*-

;;; Commentary:

;; The commit-msg module installs a `commit-msg' hook stripping Claude
;; attribution, only in the repositories that turn
;; `harness-commit-msg-strip-attribution' on.  These tests make git
;; repositories of their own, in temporary directories, and read no
;; global or system git configuration (whose `core.hooksPath' would put
;; the hooks elsewhere).

;;; Code:

(require 'harness-test-helpers)

(defvar harness-commit-msg-strip-attribution)
(defvar harness-commit-msg--installed)
(defvar harness-commit-msg--noted)
(defvar harness-commit-msg--subscriptions)
(declare-function harness-commit-msg-uninstall "harness-ui-commit-msg" (directory))
(declare-function harness-ui-commit-msg--describe "harness-ui-commit-msg" (dir result))
(declare-function harness-commit-msg--install "harness-commit-msg" (root))
(declare-function harness-commit-msg--hook "harness-commit-msg" ())
(declare-function harness-commit-msg--hook-p "harness-commit-msg" (text))
(declare-function harness-commit-msg--selected-p "harness-commit-msg" (main &optional dirs))
(declare-function harness-commit-msg--recorded "harness-commit-msg" ())
(declare-function harness-commit-msg--main "harness-commit-msg" (dir))
(declare-function harness-commit-msg--canonical "harness-commit-msg" (dir))
(declare-function harness-acp-request "harness-acp" (conn method params))

;;;; Repositories of the tests' own

(defun harness-commit-msg-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure, return stdout."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "Running git %s failed: %s" args (buffer-string)))
      (buffer-string))))

(defun harness-commit-msg-test--make-repo (&optional base name)
  "Create BASE/NAME with one commit; return (BASE . ROOT).
BASE defaults to a fresh temporary directory, NAME to repo."
  (let* ((base (or base (harness-test-temp-dir)))
         (root (file-name-as-directory (expand-file-name (or name "repo") base))))
    (make-directory root t)
    (harness-commit-msg-test--git root "init" "-q" "-b" "main")
    (harness-commit-msg-test--git root "config" "user.name" "Harness Test")
    (harness-commit-msg-test--git root "config" "user.email" "test@example.invalid")
    (harness-commit-msg-test--git root "config" "commit.gpgsign" "false")
    (with-temp-file (expand-file-name "README" root) (insert "hello\n"))
    (harness-commit-msg-test--git root "add" "README")
    (harness-commit-msg-test--git root "commit" "-q" "-m" "initial")
    (cons base root)))

(defmacro harness-commit-msg-test-with-repo (&rest body)
  "Run BODY with `base' and `root' bound to a fresh git repository.
The project, config, worktree and commit-msg modules are loaded, the
state directory holding the record is a fresh one, and the setting is
off.  git reads no global or system configuration."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let ((process-environment (append '("GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1")
                                        process-environment)))
       (harness-test-reset-bus)
       (harness-test-load-module 'project)
       (harness-test-load-module 'config)
       (harness-test-load-module 'worktree)
       (harness-test-load-module 'commit-msg)
       (clrhash harness-commit-msg--installed)
       (clrhash harness-commit-msg--noted)
       (let* ((repo (harness-commit-msg-test--make-repo))
              (base (car repo))
              (root (cdr repo))
              (harness-commit-msg-strip-attribution nil))
         (ignore base root)
         (unwind-protect (progn ,@body)
           (ignore-errors (delete-directory base t)))))))

(defun harness-commit-msg-test--dir (path)
  "Return PATH's truename as a directory name, for comparisons."
  (file-name-as-directory (file-truename path)))

(defun harness-commit-msg-test--hooks (dir)
  "Return the directory git resolves the hooks of DIR to."
  (harness-commit-msg-test--dir
   (expand-file-name
    (string-trim (harness-commit-msg-test--git dir "rev-parse" "--git-path" "hooks"))
    dir)))

(defun harness-commit-msg-test--hook-file (dir)
  "Return the path of the `commit-msg' hook of DIR."
  (expand-file-name "commit-msg" (harness-commit-msg-test--hooks dir)))

(defun harness-commit-msg-test--turn-on (dir)
  "Write a .dir-locals.el in DIR that turns the setting on."
  (with-temp-file (expand-file-name ".dir-locals.el" dir)
    (prin1 '((nil . ((harness-commit-msg-strip-attribution . t)))) (current-buffer))))

(defun harness-commit-msg-test--own-hook-file (dir)
  "Return the path of the `commit-msg' hook in the own hooks directory of DIR.
That is where git looks unless a `core.hooksPath' says otherwise."
  (expand-file-name
   "hooks/commit-msg"
   (expand-file-name (string-trim (harness-commit-msg-test--git dir "rev-parse" "--git-common-dir")) dir)))

(defun harness-commit-msg-test--hook-checks (calls)
  "Return how many of CALLS, argument lists of git runs, looked for the hooks."
  (cl-count-if (lambda (args) (member "--git-path" args)) calls))

(defun harness-commit-msg-test--wait-for-hook (dir)
  "Wait until the repository of DIR has the harness's `commit-msg' hook."
  (let ((hook (harness-commit-msg-test--hook-file dir)))
    (harness-test-wait (lambda () (harness-commit-msg--hook-p (harness-read-file hook)))
                       10 (format "the commit-msg hook of %s" dir))))

(defmacro harness-commit-msg-test-counting (fn counter &rest body)
  "Run BODY counting the calls of function FN in the variable COUNTER.
COUNTER holds the list of the calls' arguments, the latest first."
  (declare (indent 2))
  (let ((advice (make-symbol "advice")))
    `(let ((,advice (lambda (&rest args) (push args ,counter))))
       (advice-add ',fn :before ,advice)
       (unwind-protect (progn ,@body)
         (advice-remove ',fn ,advice)))))

;;;; The hook

(ert-deftest harness-commit-msg-installs-the-hook-once ()
  "A second install changes nothing and says so; the repository is recorded once."
  (harness-commit-msg-test-with-repo
    (let* ((hook (harness-commit-msg-test--hook-file root))
           (text (progn (should (harness-test-await (harness-commit-msg--install root)))
                        (harness-read-file hook))))
      (should (harness-commit-msg--hook-p text))
      (should (string= text (harness-commit-msg--hook)))
      (should (= #o755 (logand #o7777 (file-modes hook))))
      (should-not (harness-test-await (harness-commit-msg--install root)))
      (should (string= text (harness-read-file hook)))
      ;; A hook the harness wrote that is stale is written again.
      (harness-write-file-atomically hook (concat text "# extra\n"))
      (should (harness-test-await (harness-commit-msg--install root)))
      (should (string= text (harness-read-file hook)))
      (should (file-executable-p hook))
      (should (equal (list (harness-commit-msg--canonical root)) (harness-commit-msg--recorded))))))

(ert-deftest harness-commit-msg-keeps-a-foreign-hook ()
  "A `commit-msg' somebody else wrote is left byte for byte, and not recorded."
  (harness-commit-msg-test-with-repo
    (let* ((hooks (harness-commit-msg-test--hooks root))
           (hook (expand-file-name "commit-msg" hooks)))
      (harness-ensure-directory hooks)
      (harness-write-file-atomically hook "#!/bin/sh\necho hi\n")
      (let ((before (harness-read-file hook)))
        (should-not (harness-test-await (harness-commit-msg--install root)))
        (should (string= before (harness-read-file hook)))
        (should-not (harness-commit-msg--recorded))))))

(ert-deftest harness-commit-msg-leaves-a-hooks-path-elsewhere-alone ()
  "A `core.hooksPath' pointing elsewhere is nobody else's to write."
  (harness-commit-msg-test-with-repo
    (let ((elsewhere (expand-file-name "my-hooks" base)))
      (harness-ensure-directory elsewhere)
      (harness-commit-msg-test--git root "config" "core.hooksPath" elsewhere)
      (should-not (harness-test-await (harness-commit-msg--install root)))
      (should-not (file-exists-p (expand-file-name "commit-msg" elsewhere)))
      (should-not (file-exists-p (harness-commit-msg-test--hook-file root)))
      (should-not (file-exists-p (expand-file-name ".git/hooks/commit-msg" root)))
      (should-not (harness-commit-msg--recorded)))))

;;;; Which repositories, and when

(ert-deftest harness-commit-msg-dir-locals-at-the-root-turn-it-on ()
  "A .dir-locals.el at the root of the main checkout opts the repository in.
`worktree/create' installs the hook, and the worktree's commits lose
the lines attributing them to Claude, every other line kept."
  (harness-commit-msg-test-with-repo
    (harness-commit-msg-test--turn-on root)
    (let ((dir (expand-file-name "wt-hooked" base))
          (hook (harness-commit-msg-test--hook-file root)))
      (harness-test-await (harness-call 'worktree/create root :branch "hooked" :path dir))
      (harness-commit-msg-test--wait-for-hook root)
      (should (file-executable-p hook))
      (should (equal (list (harness-commit-msg--canonical root)) (harness-commit-msg--recorded)))
      (with-temp-file (expand-file-name "feature.txt" dir) (insert "x\n"))
      (harness-commit-msg-test--git dir "add" "feature.txt")
      (harness-commit-msg-test--git dir "commit" "-q" "-m"
                                    (concat "Add a feature\n\nWhat it does.\n\n"
                                            "Co-Authored-By: Claude <noreply@anthropic.com>\n"
                                            "Generated with [Claude Code](https://claude.com/claude-code)\n"
                                            "https://claude.ai/code\n"
                                            "Co-Authored-By: Jane <jane@example.com>\n"))
      (should (equal "Add a feature\n\nWhat it does.\n\nCo-Authored-By: Jane <jane@example.com>"
                     (string-trim-right
                      (harness-commit-msg-test--git dir "log" "-1" "--format=%B")))))))

(ert-deftest harness-commit-msg-does-nothing-unless-turned-on ()
  "With the setting off everywhere nothing is installed or recorded.
Not by a new worktree, a new or moved session, nor a start's pass over
the repositories the sessions work in."
  (harness-commit-msg-test-with-repo
    (let ((dir (expand-file-name "wt-plain" base))
          (installs nil))
      (harness-register-method 'session/list
        (lambda (&optional _filter) (list (list :id "a" :cwd root) (list :id "b" :cwd dir))))
      (harness-commit-msg-test-counting harness-commit-msg--install installs
        (harness-test-await (harness-call 'worktree/create root :branch "plain" :path dir))
        (harness-emit 'session/created "a" (list :id "a" :cwd root))
        (harness-emit 'session/created "b" (list :id "b" :cwd dir))
        (harness-emit 'session/moved "a" root dir)
        (harness-emit 'harness/started))
      (should-not installs)
      (should-not (file-exists-p (harness-commit-msg-test--hook-file root)))
      (should-not (harness-commit-msg--recorded))
      (should-not (file-exists-p (expand-file-name "commit-msg-hooks.json" harness-state-directory))))))

(ert-deftest harness-commit-msg-a-work-dir-selects-its-repository ()
  "A .dir-locals.el applying to a directory a session works in selects its repository.
That directory, a subdirectory of the repository, counts whether the
event names it or a session works there.  A .dir-locals.el in another
repository selects that one, never this one."
  (harness-commit-msg-test-with-repo
    (let* ((sub (file-name-as-directory (expand-file-name "sub" root)))
           (other (cdr (harness-commit-msg-test--make-repo base "other")))
           (plain (cdr (harness-commit-msg-test--make-repo base "plain")))
           (main (harness-commit-msg--main root))
           (sessions nil)
           (installs nil))
      (make-directory sub)
      (harness-commit-msg-test--turn-on sub)
      (harness-commit-msg-test--turn-on other)
      (harness-register-method 'session/select (lambda (&optional _filter) sessions))
      (should (equal (harness-commit-msg-test--dir root) main))
      (should (equal main (harness-commit-msg--main sub)))
      ;; Nobody works in sub: only an event naming it selects the repository.
      (should-not (harness-commit-msg--selected-p main))
      (should (harness-commit-msg--selected-p main (list sub)))
      ;; A session works in sub.
      (setq sessions (list (list :id "a" :cwd sub)))
      (should (harness-commit-msg--selected-p main))
      ;; The other repository's own file selects it, and nothing else.
      (setq sessions (list (list :id "b" :cwd other) (list :id "c" :cwd plain)))
      (should (harness-commit-msg--selected-p (harness-commit-msg--main other)))
      (should-not (harness-commit-msg--selected-p main))
      (should-not (harness-commit-msg--selected-p main (list other)))
      (should-not (harness-commit-msg--selected-p (harness-commit-msg--main plain) (list other plain)))
      ;; New sessions: one in plain installs nothing, one in sub installs
      ;; the hook in root's repository.
      (harness-commit-msg-test-counting harness-commit-msg--install installs
        (harness-emit 'session/created "c" (list :id "c" :cwd plain))
        (harness-emit 'session/created "a" (list :id "a" :cwd sub))
        (harness-commit-msg-test--wait-for-hook root))
      (should (equal (list (list main)) installs))
      (should-not (file-exists-p (harness-commit-msg-test--hook-file plain)))
      (should (equal (list main) (harness-commit-msg--recorded))))))

(ert-deftest harness-commit-msg-the-global-value-selects-every-repository ()
  "The global value t selects every local repository, and a session in each gets the hook."
  (harness-commit-msg-test-with-repo
    (let ((other (cdr (harness-commit-msg-test--make-repo base "other")))
          (nowhere (file-name-as-directory (expand-file-name "not-a-repository" base))))
      (make-directory nowhere)
      (should-not (harness-commit-msg--selected-p (harness-commit-msg--main root)))
      (should-not (harness-commit-msg--selected-p (harness-commit-msg--main other)))
      (let ((harness-commit-msg-strip-attribution t))
        (should (harness-commit-msg--selected-p (harness-commit-msg--main root)))
        (should (harness-commit-msg--selected-p (harness-commit-msg--main other)))
        (should-not (harness-commit-msg--main nowhere))
        (harness-emit 'session/created "a" (list :id "a" :cwd root))
        (harness-emit 'session/created "b" (list :id "b" :cwd other))
        (harness-emit 'session/created "c" (list :id "c" :cwd nowhere))
        (harness-commit-msg-test--wait-for-hook root)
        (harness-commit-msg-test--wait-for-hook other))
      (should (equal (sort (mapcar #'harness-commit-msg--canonical (list root other)) #'string<)
                     (sort (harness-commit-msg--recorded) #'string<))))))

(ert-deftest harness-commit-msg-a-start-installs-the-hook-in-known-repositories ()
  "A start or reload installs the hook in the selected repositories the sessions work in.
It puts back one that went, and installs none elsewhere."
  (harness-commit-msg-test-with-repo
    (let ((other (cdr (harness-commit-msg-test--make-repo base "other")))
          (hook (harness-commit-msg-test--hook-file root)))
      (harness-commit-msg-test--turn-on root)
      (harness-register-method 'session/list
        (lambda (&optional _filter) (list (list :id "a" :cwd root) (list :id "b" :cwd other))))
      (harness-emit 'harness/started)
      (harness-commit-msg-test--wait-for-hook root)
      (should-not (file-exists-p (harness-commit-msg-test--hook-file other)))
      (should (equal (list (harness-commit-msg--canonical root)) (harness-commit-msg--recorded)))
      ;; A reload puts back the hook of a selected repository.
      (delete-file hook)
      (harness-emit 'harness/reloaded)
      (harness-commit-msg-test--wait-for-hook root)
      (should-not (file-exists-p (harness-commit-msg-test--hook-file other))))))

(ert-deftest harness-commit-msg-the-settings-page-takes-effect-at-once ()
  "`config/set' of the setting at the project scope installs the hook at once.
`config/unset' takes it away at once: neither waits for a start or a
reload of the harness."
  (harness-commit-msg-test-with-repo
    (let ((hook (harness-commit-msg-test--hook-file root)))
      (harness-call 'config/set "harness-commit-msg-strip-attribution" "t" :printed t
                    :scope 'project :cwd root)
      (should (equal '((nil . ((harness-commit-msg-strip-attribution . t))))
                     (with-temp-buffer
                       (insert-file-contents (expand-file-name ".dir-locals.el" root))
                       (read (current-buffer)))))
      (harness-commit-msg-test--wait-for-hook root)
      (should (equal (list (harness-commit-msg--canonical root)) (harness-commit-msg--recorded)))
      (harness-call 'config/unset 'harness-commit-msg-strip-attribution :scope 'project :cwd root)
      (should-not (file-exists-p (expand-file-name ".dir-locals.el" root)))
      (harness-test-wait (lambda () (not (file-exists-p hook))) 10 "the hook to go")
      (harness-test-wait (lambda () (null (harness-commit-msg--recorded))) 10 "the record to empty"))))

(ert-deftest harness-commit-msg-a-deselected-repository-loses-only-the-harness-hook ()
  "A full pass takes the harness's hook out of a recorded repository no longer selected.
Never a hook somebody else wrote, nor anything in a `core.hooksPath'
elsewhere, though the harness's own goes from the repository's hooks
directory there too.  Those repositories leave the record all the
same, and so does one whose hook is gone already.  A repository still
selected keeps its hook and its place in the record."
  (harness-commit-msg-test-with-repo
    (let* ((foreign (cdr (harness-commit-msg-test--make-repo base "foreign")))
           (gone (cdr (harness-commit-msg-test--make-repo base "gone")))
           (moved (cdr (harness-commit-msg-test--make-repo base "moved")))
           (kept (cdr (harness-commit-msg-test--make-repo base "kept")))
           (elsewhere (expand-file-name "shared-hooks/" base))
           (shared (expand-file-name "commit-msg" elsewhere))
           (mine "#!/bin/sh\necho mine\n"))
      (dolist (repo (list root foreign gone moved kept))
        (should (harness-test-await (harness-commit-msg--install repo))))
      (should (= 5 (length (harness-commit-msg--recorded))))
      ;; Somebody put their own hook in foreign, took gone's away, and
      ;; pointed moved's core.hooksPath to a directory of their own,
      ;; with a copy of the harness's hook in it.
      (harness-write-file-atomically (harness-commit-msg-test--hook-file foreign) mine)
      (delete-file (harness-commit-msg-test--hook-file gone))
      (harness-ensure-directory elsewhere)
      (copy-file (harness-commit-msg-test--hook-file moved) shared)
      (harness-commit-msg-test--git moved "config" "core.hooksPath" elsewhere)
      ;; Only kept still turns the setting on.
      (harness-commit-msg-test--turn-on kept)
      (harness-emit 'harness/reloaded)
      (harness-test-wait (lambda () (equal (list (harness-commit-msg--canonical kept))
                                           (harness-commit-msg--recorded)))
                         10 "the record to keep only kept")
      (should-not (file-exists-p (harness-commit-msg-test--hook-file root)))
      (should (equal mine (harness-read-file (harness-commit-msg-test--hook-file foreign))))
      (should-not (file-exists-p (harness-commit-msg-test--hook-file gone)))
      (should-not (file-exists-p (harness-commit-msg-test--own-hook-file moved)))
      (should (harness-commit-msg--hook-p (harness-read-file shared)))
      (should (harness-commit-msg--hook-p (harness-read-file (harness-commit-msg-test--hook-file kept)))))))

;;;; Taking a hook out

(ert-deftest harness-commit-msg-uninstall-removes-only-the-harness-hook ()
  "`commit-msg/uninstall' takes out the harness's hook, and the repository's record.
It leaves a hook somebody else wrote, and says why nothing was removed
and whether the setting still selects the repository."
  (harness-commit-msg-test-with-repo
    (let* ((other (cdr (harness-commit-msg-test--make-repo base "other")))
           (nowhere (file-name-as-directory (expand-file-name "not-a-repository" base)))
           (deep (file-name-as-directory (expand-file-name "deep/er" root)))
           (main (harness-commit-msg--canonical root))
           (mine "#!/bin/sh\necho mine\n")
           (uninstall (lambda (dir) (harness-test-await (harness-call 'commit-msg/uninstall dir)))))
      (make-directory nowhere)
      (make-directory deep t)
      (should (harness-test-await (harness-commit-msg--install root)))
      (should (eq t (gethash main harness-commit-msg--installed)))
      (should (equal (list :repository main :removed t :reason nil :selected :false)
                     (funcall uninstall root)))
      (should-not (file-exists-p (harness-commit-msg-test--hook-file root)))
      (should-not (harness-commit-msg--recorded))
      (should-not (gethash main harness-commit-msg--installed))
      ;; Nothing left to remove.
      (should (equal (list :repository main :removed :false :reason "none" :selected :false)
                     (funcall uninstall root)))
      ;; A hook somebody else wrote stays, byte for byte.
      (harness-write-file-atomically (harness-commit-msg-test--hook-file other) mine)
      (should (equal "foreign" (plist-get (funcall uninstall other) :reason)))
      (should (equal mine (harness-read-file (harness-commit-msg-test--hook-file other))))
      ;; No repository at all.
      (should (equal (list :repository nil :removed :false :reason "no-repository" :selected :false)
                     (funcall uninstall nowhere)))
      ;; Asked from a subdirectory while the setting is still on: the
      ;; hook goes, and the answer says it comes back.
      (harness-commit-msg-test--turn-on root)
      (should (harness-test-await (harness-commit-msg--install root)))
      (should (equal (list :repository main :removed t :reason nil :selected t)
                     (funcall uninstall deep)))
      (should-not (file-exists-p (harness-commit-msg-test--hook-file root)))
      (should-not (harness-commit-msg--recorded)))))

(ert-deftest harness-commit-msg-uninstall-over-acp ()
  "Clients call the method as `_harness/commit-msg/uninstall'."
  (harness-commit-msg-test-with-repo
    (should (harness-test-await (harness-commit-msg--install root)))
    (let* ((conn (harness-test-connect-ui-client))
           (answer (harness-test-await
                    (harness-acp-request conn "_harness/commit-msg/uninstall" (list :dir root)))))
      (should (eq t (plist-get answer :removed)))
      (should (eq :false (plist-get answer :selected)))
      (should-not (file-exists-p (harness-commit-msg-test--hook-file root))))))

(ert-deftest harness-commit-msg-the-command-says-what-happened ()
  "`harness-commit-msg-uninstall' asks the harness, and says in the echo area what happened.
While the setting still selects the repository, it says the setting
has to be turned off for the hook to stay away."
  (require 'harness-ui-commit-msg)
  (harness-commit-msg-test-with-repo
    (let ((hook (harness-commit-msg-test--hook-file root))
          (asked nil)
          (shown nil))
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (method params callback &optional _on-error)
                   (push (cons method params) asked)
                   ;; As the answer comes over ACP, through JSON.
                   (funcall callback
                            (harness-json-parse
                             (harness-json-encode
                              (harness-test-await (harness-call 'commit-msg/uninstall
                                                                (plist-get params :dir))))))))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) shown))))
        (should (harness-test-await (harness-commit-msg--install root)))
        (harness-commit-msg-uninstall root)
        (should (equal (list (cons "_harness/commit-msg/uninstall" (list :dir root))) asked))
        (should (string-prefix-p "Removed the harness's commit-msg hook from " (car shown)))
        (should-not (string-search "still on" (car shown)))
        (should-not (file-exists-p hook))
        (harness-commit-msg-uninstall root)
        (should (string-match-p "has no commit-msg hook to remove\\'" (car shown)))
        ;; Still on for the repository: the hook comes back, and it says so.
        (harness-commit-msg-test--turn-on root)
        (should (harness-test-await (harness-commit-msg--install root)))
        (harness-commit-msg-uninstall root)
        (should (string-prefix-p "Removed the harness's commit-msg hook from " (car shown)))
        (should (string-match-p "still on for it.*turn the setting off for the hook to stay away"
                                (car shown)))))
    ;; What each other answer says.
    (dolist (case '(("foreign" . "Left the commit-msg hook of /r alone: the harness did not write it")
                    ("hooks-path" . "Left /r alone: its core.hooksPath puts the hooks elsewhere")
                    ("no-repository" . "/r is in no local git repository")))
      (should (equal (cdr case)
                     (harness-ui-commit-msg--describe
                      "/r/" (list :repository nil :removed :false :reason (car case) :selected :false)))))))

(ert-deftest harness-commit-msg-subscribes-once-and-shuts-down ()
  "Loading the module again, as a hot reload does, subscribes each handler once.
Shutting the module down stops them all."
  (harness-commit-msg-test-with-repo
    (let ((count (lambda (cell)
                   (cl-count (cdr cell) (gethash (car cell) harness--subscribers) :key #'cdr)))
          (installs nil))
      (harness-commit-msg-test--turn-on root)
      (harness-test-load-module 'commit-msg)
      (harness-test-load-module 'commit-msg)
      (should (= 6 (length harness-commit-msg--subscriptions)))
      (dolist (cell harness-commit-msg--subscriptions)
        (should (= 1 (funcall count cell))))
      (harness-module-disable 'commit-msg)
      (dolist (cell harness-commit-msg--subscriptions)
        (should (= 0 (funcall count cell))))
      (harness-commit-msg-test-counting harness-commit-msg--install installs
        (harness-emit 'session/created "a" (list :id "a" :cwd root))
        (harness-emit 'harness/reloaded))
      (should-not installs))))

;;;; What a session costs

(ert-deftest harness-commit-msg-sessions-run-git-once-per-installed-repository ()
  "Many new sessions in a repository whose hook is installed run git once.
The repositories found installed since the last full pass are skipped,
and so is one whose install still runs.  A full pass looks again, once."
  (harness-commit-msg-test-with-repo
    (let ((sub (file-name-as-directory (expand-file-name "sub" root)))
          (main (harness-commit-msg--canonical root))
          (gits nil))
      (make-directory sub)
      (harness-commit-msg-test--turn-on root)
      (harness-commit-msg-test-counting harness-worktree--git gits
        ;; Five at once, while the first install runs.
        (dotimes (i 5)
          (harness-emit 'session/created (format "a%d" i)
                        (list :id (format "a%d" i) :cwd (if (cl-oddp i) sub root))))
        (harness-commit-msg-test--wait-for-hook root)
        (should (eq t (gethash main harness-commit-msg--installed)))
        ;; Five more, and a move, once it is installed.
        (dotimes (i 5)
          (harness-emit 'session/created (format "b%d" i) (list :id (format "b%d" i) :cwd sub)))
        (harness-emit 'session/moved "a0" root sub)
        (should (= 1 (harness-commit-msg-test--hook-checks gits)))
        ;; A full pass forgets what it found and looks again; the sessions
        ;; after it run no git.
        (harness-emit 'harness/reloaded)
        (harness-test-wait (lambda () (eq t (gethash main harness-commit-msg--installed)))
                           10 "the pass to find the hook")
        (dotimes (i 5)
          (harness-emit 'session/created (format "c%d" i) (list :id (format "c%d" i) :cwd root))))
      (should (= 2 (harness-commit-msg-test--hook-checks gits))))))

(provide 'harness-commit-msg-test)
;;; harness-commit-msg-test.el ends here
