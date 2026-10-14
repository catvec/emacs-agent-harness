;;; harness-commit-msg.el --- Commit messages without Claude attribution, where asked  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sessions commit in the repositories the harness works in, and the
;; tools they run -- Claude Code above all -- write lines into the
;; message that attribute the commit to Claude: `Co-Authored-By: Claude
;; <noreply@anthropic.com>', `Generated with [Claude
;; Code](https://claude.com/claude-code)'.  This module can install a
;; `commit-msg' hook that takes those lines out at commit time, which is
;; better than rewriting history afterwards.
;;
;; Opt-in, always.  A tool that many repositories share must not rewrite
;; commit messages unasked: another workflow may depend on the trailer
;; of a co-signing agent, which the hook would drop silently.  So
;; nothing is installed in a repository unless the layered setting
;; `harness-commit-msg-strip-attribution' (see harness-config.el) is on
;; for it.  It is off by default.  A project turns it on in its
;; .dir-locals.el, which the settings page's Project scope writes, and
;; the global value t turns it on in every repository the harness works
;; in.
;;
;; The repository is the unit: the hook lives in the repository's own
;; hooks directory, which its main checkout and every linked worktree
;; share.  A repository is named by its main checkout MAIN, and it is
;; selected when the setting is on at MAIN or at any directory the
;; harness works in that lies in it (`harness-commit-msg--selected-p').
;; A .dir-locals.el at the root of the main checkout opts the project
;; in, and so does one that applies to a session working in it, in a
;; task's worktree or in a subdirectory.
;;
;; When it acts.  A new worktree (`worktree/created') and a new or moved
;; session (`session/created', `session/moved') install the hook in
;; their repository when it is selected.  Many sessions are made, so a
;; repository found installed since the last full pass is skipped and
;; such a session runs no git.  A full pass runs when the harness starts
;; or reloads, and when the setting changes through `config/set' or
;; `config/unset' (the settings page).  It installs the hook in every
;; selected repository the harness knows of, and removes it from every
;; recorded one that is no longer selected.  A .dir-locals.el edited by
;; hand sends no event: the next start or reload applies it, while the
;; worktree and session events see it at once when it turns the setting
;; on.
;;
;; Turning it off.  The repositories that have the harness's hook are
;; recorded (`harness-commit-msg--record-file').  A full pass takes the
;; hook out of a recorded repository that is no longer selected, but
;; only while the file still carries the harness's marker and sits in
;; the repository's own hooks directory, and drops the repository from
;; the record.  `commit-msg/uninstall' removes one repository's hook at
;; once (the UI's `harness-commit-msg-uninstall').
;;
;; The hook itself (`harness-commit-msg--hook') keeps every other byte
;; of the message and always succeeds.  A `commit-msg' somebody else
;; wrote is left alone, and so is a `core.hooksPath' pointing elsewhere.
;; Agents working in a linked worktree cannot change the hook: the
;; sandbox mounts the repository's hooks directory read-only there
;; (harness-sandbox.el).
;;
;; The git helpers come from the worktree module (harness-worktree.el),
;; and the directories the harness works in from the config module.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)

(defvar harness-state-directory)

(declare-function harness-worktree--git "harness-worktree" (cwd &rest args))
(declare-function harness-worktree--same-path-p "harness-worktree" (a b))
(declare-function harness-worktree--known-roots "harness-worktree" ())
(declare-function harness-config--work-dirs "harness-config" ())

;;;; The setting

(defcustom harness-commit-msg-strip-attribution nil
  "Non-nil takes the lines attributing a commit to Claude out of its message.
Where it is on, the harness installs a `commit-msg' hook in the git
repository that drops those lines -- a `Co-Authored-By' or
`Signed-off-by' naming Claude, a `Generated with' line naming it, a
`Claude-Session' line, a bare claude.com or claude.ai link -- and keeps
every other byte of the message.  The hook belongs to the repository,
so it acts on every commit made there, in the main checkout and in
every worktree, by a session or by you.

It is off by default, and the harness installs nothing in a repository
nobody turned it on for.  Turn it on for a project in that project's
.dir-locals.el, which the settings page's Project scope writes:

  ((nil . ((harness-commit-msg-strip-attribution . t))))

A .dir-locals.el that applies to a directory a session works in, a
task's worktree or a subdirectory, turns it on for that repository
too.  The global value t turns it on in every repository the harness
works in; turning it on per project is the better habit.

Changed on the settings page, it applies at once.  A .dir-locals.el
edited by hand applies at the next start or reload of the harness, and
when it turns the setting on, as soon as a worktree or a session is
made in the repository.  Turned off, it has the harness remove the hook
it installed; `harness-commit-msg-uninstall' removes a repository's
hook at once.

It is off by default because a tool that many repositories share must
not rewrite commit messages unasked: another workflow may depend on the
trailer of a co-signing agent, which the hook would drop silently."
  :type 'boolean :safe #'booleanp :group 'harness)

;;;; The hook

(defconst harness-commit-msg-hook-marker "# harness: strip Claude attribution trailers"
  "Line marking a `commit-msg' hook as the harness's own.
`harness-commit-msg--install' writes a hook carrying it on this, its
second, line.  The harness rewrites or removes only such a hook, never
one somebody else wrote.")

(defconst harness-commit-msg--claude-attribution-regexp
  (concat "^(co-authored-by|signed-off-by):.*claude"
          "|^[^[:alnum:]]*generated[[:space:]]+with.*claude"
          "|^[[:space:]]*claude-session:"
          "|^[[:space:]]*(https?://)?(www\\.)?claude\\.(com|ai)/[^[:space:]]*[[:space:]]*$")
  "Extended regexp of a commit-message line attributing it to Claude.
The hook matches it with `grep -iE', so it is written in lower case.  A
line matched is dropped from the message: a `Co-Authored-By' or
`Signed-off-by' to Claude, a `Generated with' line naming Claude, a
`Claude-Session' line, or a bare claude.com/claude-code or
claude.ai/code link.")

(defun harness-commit-msg--hook ()
  "Return the text of the `commit-msg' hook the harness installs.
It removes the lines matching
`harness-commit-msg--claude-attribution-regexp' and keeps every other
byte of the message, trailing newlines included; it always exits 0, so
it never fails a commit, and a message that would be empty without its
Claude lines is left as it was, which git would refuse anyway."
  (concat
   "#!/bin/sh\n"
   harness-commit-msg-hook-marker "\n"
   "# Installed by the emacs-agent-harness, because the setting\n"
   "# harness-commit-msg-strip-attribution is on for this repository: it\n"
   "# takes the lines that attribute a commit to Claude out of the message.\n"
   "# Every other byte of the message stays as it was, and the hook always\n"
   "# succeeds.  The harness removes this file once the setting is off.\n"
   "# Agents working in a linked worktree of this repository run in a\n"
   "# sandbox that mounts this directory read-only.\n"
   "pattern='" harness-commit-msg--claude-attribution-regexp "'\n"
   "msg=\"$1\"\n"
   "[ -n \"$msg\" ] && [ -f \"$msg\" ] || exit 0\n"
   "grep -qiE \"$pattern\" \"$msg\" 2>/dev/null || exit 0\n"
   "tmp=\"$msg.harness.$$\"\n"
   "grep -viE \"$pattern\" \"$msg\" > \"$tmp\" 2>/dev/null\n"
   "status=$?\n"
   "if [ \"$status\" -le 1 ] && grep -q '[^[:space:]]' \"$tmp\" 2>/dev/null; then\n"
   "  if [ -z \"$(tail -c 1 \"$msg\" 2>/dev/null)\" ]; then\n"
   "    cat \"$tmp\" > \"$msg\" 2>/dev/null\n"
   "  else\n"
   "    printf '%s' \"$(cat \"$tmp\")\" > \"$msg\" 2>/dev/null\n"
   "  fi\n"
   "fi\n"
   "rm -f \"$tmp\"\n"
   "exit 0\n"))

(defun harness-commit-msg--hook-p (text)
  "Non-nil when TEXT is a `commit-msg' hook the harness wrote."
  (and (stringp text)
       (string-match-p (concat "\\`#![^\n]*\n"
                               (regexp-quote harness-commit-msg-hook-marker))
                       text)))

(defvar harness-commit-msg--noted (make-hash-table :test 'equal)
  "Repositories whose `commit-msg' hook was logged as left alone already.
The harness leaves somebody else's hook and a `core.hooksPath'
elsewhere alone; this keeps it from saying so on every worktree and
session made there.")

(defun harness-commit-msg--note-once (root fmt &rest args)
  "Log FMT with ARGS about ROOT's `commit-msg' hook, once per repository."
  (unless (gethash root harness-commit-msg--noted)
    (puthash root t harness-commit-msg--noted)
    (apply #'harness-log 'info (concat "commit-msg: " fmt) args)))

(defun harness-commit-msg--hook-dirs (root)
  "Return a promise of (HOOKS . OWN) for the repository at ROOT.
HOOKS is the directory git resolves the hooks to (`git rev-parse
--git-path hooks'), OWN the repository's own `hooks' directory, in its
common git directory (`--git-common-dir').  They differ when a
`core.hooksPath' points elsewhere.  The promise rejects when git fails,
as it does outside a repository."
  (harness-then
   (harness-worktree--git root "rev-parse" "--git-path" "hooks" "--git-common-dir")
   (lambda (output)
     (let* ((lines (split-string output "\n" t))
            (hooks (expand-file-name (string-trim (or (car lines) "hooks")) root))
            (common (expand-file-name (string-trim (or (cadr lines) ".git")) root)))
       (cons hooks (expand-file-name "hooks" common))))))

(defun harness-commit-msg--write-hook (file root verb)
  "Write the harness's hook to FILE, mode 0755, and log VERB for ROOT."
  (harness-write-file-atomically file (harness-commit-msg--hook))
  (set-file-modes file #o755)
  (harness-log 'info "commit-msg: %s the commit-msg hook in %s" verb (abbreviate-file-name root)))

(defun harness-commit-msg--install (root)
  "Install the harness's `commit-msg' hook in the repository at ROOT.
The hook (`harness-commit-msg--hook') goes into the hooks directory git
resolves for ROOT, and only when that is the repository's own `hooks'
directory (`harness-commit-msg--hook-dirs'): a `core.hooksPath'
somewhere else is somebody else's and is left alone, as is a
`commit-msg' they wrote, each logged once per repository.  A hook the
harness wrote is rewritten when its text changed.  Whenever the hook is
the harness's afterwards, written by this call or current already, ROOT
is recorded and counts as installed (`harness-commit-msg--installed-in').
Return a promise resolving to non-nil when this call wrote the hook,
and to nil when it did not: ROOT is remote, the hooks directory is
elsewhere, a hook somebody else wrote is there, or the harness's is
current.  A promise rejected by git or by the write is the caller's to
log."
  (if (file-remote-p root)
      (harness-resolved nil)
    (harness-then
     (harness-commit-msg--hook-dirs root)
     (lambda (dirs)
       (let ((hooks (car dirs)))
         (cond
          ((not (harness-worktree--same-path-p hooks (cdr dirs)))
           (harness-commit-msg--note-once
            root "leaving the commit-msg hook of %s alone: core.hooksPath puts the hooks in %s"
            (abbreviate-file-name root) (abbreviate-file-name hooks))
           nil)
          (t
           (let ((file (expand-file-name "commit-msg" hooks)))
             (if (file-exists-p file)
                 (let ((existing (harness-read-file file)))
                   (cond
                    ((not (harness-commit-msg--hook-p existing))
                     (harness-commit-msg--note-once
                      root "leaving the commit-msg hook of %s alone: it is not the harness's"
                      (abbreviate-file-name root))
                     nil)
                    ((and (string= existing (harness-commit-msg--hook))
                          (file-executable-p file))
                     (harness-commit-msg--installed-in root)
                     nil)
                    (t
                     (harness-commit-msg--write-hook file root "updated")
                     (harness-commit-msg--installed-in root)
                     t)))
               (harness-commit-msg--write-hook file root "installed")
               (harness-commit-msg--installed-in root)
               t)))))))))

(defun harness-commit-msg--remove (root)
  "Remove the harness's `commit-msg' hook from the repository at ROOT.
Only a hook carrying `harness-commit-msg-hook-marker' goes, and only
from the repository's own hooks directory (`harness-commit-msg--hook-dirs'):
a hook somebody else wrote stays, and nothing in a `core.hooksPath'
elsewhere is touched.  The harness's hook goes from the own directory
also when a `core.hooksPath' set since keeps git from running it, as
it would run again once that is unset.  Return a promise of what
happened: `removed'; `foreign', the hook there is somebody else's;
`hooks-path', there is none and the hooks are elsewhere; or `none',
there is no `commit-msg' hook.  A promise rejected by git or by the
deletion is the caller's to log."
  (harness-then
   (harness-commit-msg--hook-dirs root)
   (lambda (dirs)
     (let ((file (expand-file-name "commit-msg" (cdr dirs))))
       (cond
        ((and (file-exists-p file) (harness-commit-msg--hook-p (harness-read-file file)))
         (delete-file file)
         (harness-log 'info "commit-msg: removed the commit-msg hook from %s"
                      (abbreviate-file-name root))
         'removed)
        ((file-exists-p file) 'foreign)
        ((not (harness-worktree--same-path-p (car dirs) (cdr dirs))) 'hooks-path)
        (t 'none))))))

;;;; Repositories

(defun harness-commit-msg--canonical (dir)
  "Return DIR as the record and the table keep a main checkout.
That is absolute, with symbolic links resolved and a trailing slash."
  (file-name-as-directory (harness-path-normalize dir)))

(defun harness-commit-msg--repository-p (main)
  "Non-nil when MAIN is the main checkout of a local git repository.
That is a local directory with a .git directory in it."
  (and (stringp main)
       (not (file-remote-p main))
       (file-directory-p (expand-file-name ".git" main))))

(defvar harness-commit-msg--memo nil
  "A table of directory -> main checkout while a full pass runs, else nil.
A pass looks at every work directory for every repository it
considers, so it finds each one's repository once.")

(defun harness-commit-msg--find-main (dir)
  "Return the main checkout of the repository DIR lies in, or nil.
See `harness-commit-msg--main'."
  (let ((main (ignore-errors (harness-files-main-root dir))))
    (and (harness-commit-msg--repository-p main)
         (harness-commit-msg--canonical main))))

(defun harness-commit-msg--main (dir)
  "Return the main checkout of the local git repository DIR lies in, or nil.
That is the main checkout of DIR's project (`harness-files-main-root')
made canonical (`harness-commit-msg--canonical'), when it has a .git
directory.  A remote DIR, one that is gone and one in no repository
give nil."
  (when (and (stringp dir) (not (file-remote-p dir)) (file-directory-p dir))
    (if (not harness-commit-msg--memo)
        (harness-commit-msg--find-main dir)
      (let ((found (gethash dir harness-commit-msg--memo 'unknown)))
        (if (eq found 'unknown)
            (puthash dir (harness-commit-msg--find-main dir) harness-commit-msg--memo)
          found)))))

(defvar harness-commit-msg--pass-work-dirs nil
  "(DIRS) while a full pass runs: the work directories, found once for it.")

(defun harness-commit-msg--work-dirs ()
  "Return the directories the harness works in now.
Those of `harness-config--work-dirs': the active sessions', the current
tasks' and their sessions'.  A full pass finds them once."
  (cond (harness-commit-msg--pass-work-dirs (car harness-commit-msg--pass-work-dirs))
        ((fboundp 'harness-config--work-dirs) (harness-config--work-dirs))))

(defun harness-commit-msg--on-at-p (dir)
  "Non-nil when `harness-commit-msg-strip-attribution' is on at DIR.
That is the value in effect there (`config/get'): the policy's, else
the .dir-locals.el in DIR, else the one at its project's root, else the
global value."
  (harness-json-true-p (harness-call 'config/get 'harness-commit-msg-strip-attribution dir)))

(defun harness-commit-msg--selected-p (main &optional dirs)
  "Non-nil when the repository whose main checkout is MAIN is selected.
It is when `harness-commit-msg-strip-attribution' is on at MAIN, or at
any directory the harness works in that lies in that repository: one of
DIRS, the directories the event at hand names, or one of the work
directories (`harness-commit-msg--work-dirs').  A directory of another
repository, a remote one or one that is gone counts for nothing.  The
work directories are looked at only when MAIN and DIRS do not select
the repository."
  (let ((on-in-repository (lambda (dir)
                            (and (equal (harness-commit-msg--main dir) main)
                                 (harness-commit-msg--on-at-p dir)))))
    (and (or (harness-commit-msg--on-at-p main)
             (cl-some on-in-repository dirs)
             (cl-some on-in-repository (harness-commit-msg--work-dirs)))
         t)))

;;;; The record

(defconst harness-commit-msg--record-file "commit-msg-hooks.json"
  "File in `harness-state-directory' naming the repositories with the hook.
A JSON array of their main checkouts.  A repository goes in whenever
its hook is the harness's after an install, and out once a full pass
or `commit-msg/uninstall' took the hook away or found it gone.  A full
pass removes the hook from a recorded repository that is no longer
selected; the harness never removes one from elsewhere.")

(defun harness-commit-msg--record-path ()
  "Return the file naming the repositories that have the harness's hook."
  (expand-file-name harness-commit-msg--record-file harness-state-directory))

(defun harness-commit-msg--recorded ()
  "Return the main checkouts of the repositories that have the harness's hook.
They are canonical (`harness-commit-msg--canonical'), as they are
compared with the repositories found."
  (let ((data (ignore-errors (harness-json-parse (harness-read-file (harness-commit-msg--record-path))))))
    (and (listp data)
         (delete-dups (mapcar #'harness-commit-msg--canonical (cl-remove-if-not #'stringp data))))))

(defun harness-commit-msg--write-record (mains)
  "Write MAINS as the record of the repositories with the harness's hook."
  (harness-write-file-atomically (harness-commit-msg--record-path)
                                 (harness-json-encode (harness-json-array mains))))

(defun harness-commit-msg--note (main)
  "Record that the repository at MAIN has the harness's hook."
  (let ((main (harness-commit-msg--canonical main))
        (mains (harness-commit-msg--recorded)))
    (unless (member main mains)
      (harness-commit-msg--write-record (append mains (list main))))))

(defun harness-commit-msg--forget (main)
  "Drop the repository at MAIN from the record."
  (let ((main (harness-commit-msg--canonical main))
        (mains (harness-commit-msg--recorded)))
    (when (member main mains)
      (harness-commit-msg--write-record (remove main mains)))))

;;;; Installed repositories

(defvar harness-commit-msg--installed (make-hash-table :test 'equal)
  "Main checkout -> t for the repositories found installed lately.
Lately is since the last full pass, which clears the table.  The value
is `pending' while an install runs there, so the sessions made
meanwhile start no git either.  A new session in one of these
repositories runs no git and reads no setting (see
`harness-commit-msg--consider').  `commit-msg/uninstall' takes its
repository out of the table.")

(defun harness-commit-msg--installed-in (root)
  "Note that the repository at ROOT has the harness's hook now.
It goes into the record and the table of installed repositories."
  (harness-commit-msg--note root)
  (puthash (harness-commit-msg--canonical root) t harness-commit-msg--installed))

(defun harness-commit-msg--settled (main)
  "Take MAIN out of the table when an install there is still `pending'.
That install is over and the hook is not the harness's."
  (when (eq (gethash main harness-commit-msg--installed) 'pending)
    (remhash main harness-commit-msg--installed)))

(defun harness-commit-msg--install-logged (main)
  "Install the hook in MAIN's repository; log a failure rather than signal it.
MAIN is `pending' in `harness-commit-msg--installed' while the install
runs.  Return a promise that never rejects."
  (unless (gethash main harness-commit-msg--installed)
    (puthash main 'pending harness-commit-msg--installed))
  (harness-then
   (condition-case err
       (harness-commit-msg--install main)
     (error (harness-rejected err)))
   (lambda (wrote)
     (harness-commit-msg--settled main)
     wrote)
   (lambda (err)
     (harness-commit-msg--settled main)
     (harness-log 'warn "commit-msg: could not install the commit-msg hook in %s: %s"
                  (abbreviate-file-name main) (harness-error-message err))
     nil)))

(defun harness-commit-msg--remove-logged (main)
  "Remove the harness's hook from MAIN's repository and drop MAIN from the record.
The record lets go of MAIN also when its hook was gone already, or is
somebody else's now.  A failure is logged, MAIN stays recorded and the
next full pass tries again.  Return a promise that never rejects."
  (remhash main harness-commit-msg--installed)
  (harness-then
   (condition-case err
       (harness-commit-msg--remove main)
     (error (harness-rejected err)))
   (lambda (outcome)
     (harness-commit-msg--forget main)
     outcome)
   (lambda (err)
     (harness-log 'warn "commit-msg: could not remove the commit-msg hook from %s: %s"
                  (abbreviate-file-name main) (harness-error-message err))
     nil)))

;;;; When it acts

(defun harness-commit-msg--consider (dir dirs &optional always)
  "Install the hook in the repository DIR lies in, when it is selected.
DIRS are the directories the event at hand names (see
`harness-commit-msg--selected-p').  Unless ALWAYS, a repository found
installed since the last full pass is skipped, reading no setting and
running no git.  Return a promise, or nil when nothing was to be done."
  (when-let* ((main (harness-commit-msg--main dir)))
    (unless (and (not always) (gethash main harness-commit-msg--installed))
      (when (harness-commit-msg--selected-p main dirs)
        (harness-commit-msg--install-logged main)))))

(defun harness-commit-msg--settle (main dirs recorded)
  "Install or remove the hook of the repository at MAIN, as the setting says.
DIRS are the directories the event at hand names; RECORDED is non-nil
when MAIN is in the record.  A selected repository gets the hook, and a
recorded one that is not loses it.  A recorded MAIN that is no
repository any more only leaves the record.  A repository whose
setting cannot be read is left as it is.  Return a promise that never
rejects."
  (condition-case err
      (cond
       ((not (harness-commit-msg--repository-p main))
        (when recorded (harness-commit-msg--forget main))
        (harness-resolved nil))
       ((harness-commit-msg--selected-p main dirs)
        (harness-commit-msg--install-logged main))
       (recorded (harness-commit-msg--remove-logged main))
       (t (harness-resolved nil)))
    (error
     (harness-log 'warn "commit-msg: could not look at %s: %s"
                  (abbreviate-file-name main) (harness-error-message err))
     (harness-resolved nil))))

(defun harness-commit-msg--pass (&optional dirs)
  "Bring the hook of every repository the harness knows in line with the setting.
DIRS are the directories the event at hand names.  The table of
installed repositories is cleared first.  The candidates are the
repositories the sessions work in (`harness-worktree--known-roots'),
those of the work directories and of DIRS, and the recorded ones: each
is settled by `harness-commit-msg--settle'.  Return a promise resolved
once every candidate was seen to; it never rejects."
  (clrhash harness-commit-msg--installed)
  (let* ((harness-commit-msg--memo (make-hash-table :test 'equal))
         (work (harness-commit-msg--work-dirs))
         (harness-commit-msg--pass-work-dirs (list work))
         (recorded (harness-commit-msg--recorded))
         (known (mapcar #'harness-commit-msg--canonical (harness-worktree--known-roots)))
         (candidates (delete-dups (delq nil (append known
                                                    (mapcar #'harness-commit-msg--main (append dirs work))
                                                    recorded)))))
    (harness-all (mapcar (lambda (main) (harness-commit-msg--settle main dirs (member main recorded)))
                         candidates))))

(defun harness-commit-msg--safely (what fn &rest args)
  "Call FN with ARGS for WHAT while the module is ready; log what it signals.
Nothing that emits the events this module follows may fail because of
it.  Return FN's value, or nil."
  (when (harness-module-ready-p 'commit-msg)
    (condition-case err
        (apply fn args)
      (error (harness-log 'warn "commit-msg: %s: %s" what (harness-error-message err))
             nil))))

(defun harness-commit-msg--on-worktree-created (root worktree)
  "Install the hook in the repository of ROOT, which got WORKTREE, when selected.
ROOT and WORKTREE's path are the directories the event names.  The
hook is installed again even when the repository was found installed
before, in case it went.  Nothing here may fail `worktree/create': an
error is logged."
  (harness-commit-msg--safely
   "a new worktree"
   (lambda ()
     (harness-commit-msg--consider root (delq nil (list root (plist-get worktree :path))) t))))

(defun harness-commit-msg--on-session-created (_id session)
  "Install the hook in the repository SESSION works in, when it is selected.
SESSION's directory is the one the event names.  A repository found
installed since the last full pass costs nothing."
  (harness-commit-msg--safely
   "a new session"
   (lambda ()
     (let ((cwd (plist-get session :cwd)))
       (harness-commit-msg--consider cwd (list cwd))))))

(defun harness-commit-msg--on-session-moved (_id _old new)
  "Install the hook in the repository of NEW, where a session moved, when selected."
  (harness-commit-msg--safely "a session's move" #'harness-commit-msg--consider new (list new)))

(defun harness-commit-msg--on-config-changed (key &optional _value _scope cwd)
  "Run a full pass when KEY, the option that changed, is this module's setting.
CWD, the directory it changed for, is a directory the event names: a
setting written into a .dir-locals.el there takes effect at once."
  (when (equal (format "%s" key) "harness-commit-msg-strip-attribution")
    (harness-commit-msg--safely "a change of the setting" #'harness-commit-msg--pass
                                (and (stringp cwd) (list cwd)))))

(defun harness-commit-msg--on-started (&rest _)
  "Run a full pass, as the harness starts or reloads."
  (harness-commit-msg--safely "the pass at start" #'harness-commit-msg--pass))

;;;; Taking a hook out

(harness-defmethod commit-msg/uninstall (dir)
  "Remove the harness's `commit-msg' hook from the git repository of DIR.
Only a hook the harness wrote goes, and only from the repository's own
hooks directory: one somebody else wrote stays.  The repository leaves
the record and the table of installed repositories either way.  Return
a promise of (:repository MAIN :removed BOOL :reason REASON :selected
BOOL).  MAIN is the main checkout of the repository, nil when DIR lies
in no local one.  REASON says why nothing was removed, and is nil when
the hook was removed: \"none\" (there was no `commit-msg' hook),
\"foreign\" (the hook is somebody else's), \"hooks-path\"
\(`core.hooksPath' puts the hooks elsewhere), \"remote\" (DIR is on
another host) or \"no-repository\".  :selected says whether the setting
still selects the repository (`harness-commit-msg--selected-p'): the
hook then comes back the next time the harness installs it, for a new
worktree or session there or at the next full pass."
  (let ((main (harness-commit-msg--main dir))
        (refused (lambda (reason)
                   (harness-resolved (list :repository nil :removed :false :reason reason
                                           :selected :false)))))
    (cond
     ((and (stringp dir) (file-remote-p dir)) (funcall refused "remote"))
     ((null main) (funcall refused "no-repository"))
     (t
      (remhash main harness-commit-msg--installed)
      (harness-then
       (harness-commit-msg--remove main)
       (lambda (outcome)
         (remhash main harness-commit-msg--installed)
         (harness-commit-msg--forget main)
         (list :repository main
               :removed (if (eq outcome 'removed) t :false)
               :reason (unless (eq outcome 'removed) (symbol-name outcome))
               :selected (if (ignore-errors (harness-commit-msg--selected-p main)) t :false))))))))

;;;; Module

(defconst harness-commit-msg--subscriptions
  '((worktree/created . harness-commit-msg--on-worktree-created)
    (session/created . harness-commit-msg--on-session-created)
    (session/moved . harness-commit-msg--on-session-moved)
    (config/changed . harness-commit-msg--on-config-changed)
    (harness/started . harness-commit-msg--on-started)
    (harness/reloaded . harness-commit-msg--on-started))
  "The events the module follows, with the function each one calls.")

(defun harness-commit-msg--init ()
  "Follow the events that install the hook or take it away.
Safe to call again: `harness-on' subscribes a function once."
  (pcase-dolist (`(,event . ,fn) harness-commit-msg--subscriptions)
    (harness-on event fn)))

(defun harness-commit-msg--shutdown ()
  "Stop following the events of `harness-commit-msg--init'."
  (pcase-dolist (`(,event . ,fn) harness-commit-msg--subscriptions)
    (harness-off (cons event fn))))

;; A reload does not run `:init' again for a ready module, so a running
;; harness that reloads this file subscribes here.
(harness-commit-msg--init)

(harness-define-module 'commit-msg
  :doc "A commit-msg hook stripping Claude attribution, in the repositories that turn it on."
  :requires '(config worktree)
  :init #'harness-commit-msg--init
  :shutdown #'harness-commit-msg--shutdown)

(provide 'harness-commit-msg)
;;; harness-commit-msg.el ends here
