;;; harness-revision.el --- Which commit of the harness this Emacs runs  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Both sides of the process split load this library.  Whenever the
;; harness starts or reloads, it notes the commit of the checkout its
;; files were just read from: that commit is what runs, even once the
;; checkout moves on (a pull, a merge), until the next reload.  The
;; version module (harness-version.el) compares the harness process's
;; with the places newer versions come from, and the UI shows its own
;; beside it, since the two load their files separately.
;;
;; The checkout is `harness-directory' with symbolic links followed:
;; straight.el and other package managers load the harness from a build
;; directory of links into their clone.  It counts only when it is the
;; top of a git working tree, so a harness installed inside another
;; repository (Doom's ~/.emacs.d is one) is not mistaken for that
;; repository's commit.
;;
;; Git runs in the background, always: asynchronously, without optional
;; locks, so the user's own git commands never meet ours, and with
;; prompts turned off, so a check never waits on a password, a host key
;; or a passphrase nobody sees -- nor puts a dialog on the screen.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar harness-directory)
(defvar harness-version)
(defvar harness-start-hook)
(defvar harness-reload-hook)

(defconst harness-revision--git-timeout 30
  "Seconds a git command gets before it is given up on.
Local commands take milliseconds; this bounds one stuck on a lock or a
slow network.")

;;;; Git, in the background

(defun harness-revision-git-environment ()
  "Return the environment alist git runs with in the background.
Nothing may prompt: not the terminal (there is none), not an askpass
program or a credential manager (they would put a dialog on the
screen), not ssh (BatchMode refuses passwords, passphrases and unknown
host keys; keys in the agent still work).  An empty GIT_ASKPASS keeps
git from falling back to core.askPass and SSH_ASKPASS, so it fails
saying terminal prompts are disabled.  An ssh command the user set up
is kept."
  (append '(("GIT_TERMINAL_PROMPT" . "0")
            ("GIT_ASKPASS" . "")
            ("SSH_ASKPASS_REQUIRE" . "never")
            ("GCM_INTERACTIVE" . "never"))
          (unless (or (getenv "GIT_SSH_COMMAND") (getenv "GIT_SSH"))
            '(("GIT_SSH_COMMAND" . "ssh -o BatchMode=yes")))))

(defun harness-revision--subcommand (args)
  "Return the git command ARGS run, such as \"status\": git's options skipped."
  (while (and args (string-prefix-p "-" (car args)))
    (setq args (if (member (car args) '("-c" "-C")) (cddr args) (cdr args))))
  (or (car args) "git"))

(defun harness-revision--git-error (args result)
  "Return the message for git ARGS that ended with RESULT.
It is git's first fatal error, without the advice git adds after it
for someone at a terminal, else the last line git wrote."
  (let* ((exit (plist-get result :exit))
         (lines (split-string (or (plist-get result :stderr) "") "\n" t "[ \t\r]+"))
         (prefix "\\`\\(?:fatal\\|error\\): ")
         (line (or (cl-find-if (lambda (l) (string-match-p prefix l)) lines)
                   (car (last lines)))))
    (cond ((eq exit 'timeout) (format "git %s timed out" (harness-revision--subcommand args)))
          ((null line) (format "git %s exited with %s" (harness-revision--subcommand args) exit))
          (t (replace-regexp-in-string prefix "" line)))))

(defun harness-revision-error-message (err)
  "Return the message of ERR, a rejection of the functions here.
A `harness-error' with one string reads as that string alone."
  (if (and (eq (car-safe err) 'harness-error) (stringp (cadr err)) (null (cddr err)))
      (cadr err)
    (harness-error-message err)))

(defun harness-revision-git (dir args &optional timeout)
  "Run git with ARGS in DIR in the background; return a promise of its output.
The promise is rejected with a `harness-error' carrying git's message
when git fails, or after TIMEOUT seconds (default
`harness-revision--git-timeout').  See `harness-revision-git-environment'
for why git never prompts.

Here and in the version module, a handler that fails returns a rejected
promise rather than signal: a signal in a handler is logged as an error
of the harness, and a repository out of reach is none."
  (harness-then
   (harness-run-command (cons "git" args)
                        :cwd (or dir temporary-file-directory)
                        :name "harness-revision-git"
                        :timeout (or timeout harness-revision--git-timeout)
                        :env (harness-revision-git-environment))
   (lambda (result)
     (if (eql (plist-get result :exit) 0)
         (plist-get result :stdout)
       (harness-revision-failed (harness-revision--git-error args result))))))

(defun harness-revision-failed (message)
  "Return a promise rejected with a `harness-error' saying MESSAGE."
  (harness-rejected (list 'harness-error message)))

;;;; The remote a checkout follows

(defun harness-revision-remote-urls (output)
  "Parse OUTPUT of git config --get-regexp for remote URLs into (NAME . URL)."
  (let ((urls nil))
    (dolist (line (split-string output "\n" t))
      (when (string-match "\\`remote\\.\\(.+\\)\\.url \\(.+\\)\\'" line)
        (let ((name (match-string 1 line)))
          (unless (assoc name urls)
            (push (cons name (match-string 2 line)) urls)))))
    (nreverse urls)))

(defun harness-revision-remote (dir &optional branch)
  "Return a promise of the remote DIR's BRANCH follows, or of nil.

DIR is a git checkout, BRANCH the branch of DIR to resolve, or nil for
a detached HEAD, which follows none.  The promise is never rejected: a
checkout git cannot read, or one without a remote, has none to follow.
The plist is:

  :remote   the name of the remote BRANCH tracks, else \"origin\",
            else the only remote DIR has
  :url      that remote's URL, as configured
  :branch   the branch to fetch or compare with: the one BRANCH tracks
            on that remote, else BRANCH itself
  :tracked  non-nil when BRANCH tracks that remote there

The remote a checkout's branch tracks is the one straight.el and other
package managers configure, and the branch it tracks is the one they
pull; a checkout that tracks none is read from the same-named branch of
its origin.  This is what the version module names as an origin and what
`harness--update-checkout' fetches."
  (harness-then
   (harness-all
    (list (if branch
              (harness-revision-git dir (list "for-each-ref"
                                             "--format=%(upstream:remotename)%09%(upstream:remoteref)"
                                             (concat "refs/heads/" branch)))
            (harness-resolved ""))
          (harness-revision-git dir '("config" "--get-regexp" "^remote\\..*\\.url$"))))
   (lambda (outputs)
     (let* ((fields (split-string (car (split-string (car outputs) "\n")) "\t"))
            (remote (nth 0 fields))
            (ref (nth 1 fields))
            (urls (harness-revision-remote-urls (cadr outputs)))
            (tracked (and remote (not (member remote '("" "."))) (assoc remote urls)))
            (pick (or tracked (assoc "origin" urls)
                      (and (= 1 (length urls)) (car urls)))))
       (when pick
         (let* ((url (cdr pick))
                (tracked-branch (and tracked ref (string-prefix-p "refs/heads/" ref)
                                     (string-remove-prefix "refs/heads/" ref))))
           (list :remote (car pick) :url url
                 :branch (or tracked-branch branch)
                 :tracked (and tracked t))))))
   (lambda (_err) nil)))

;;;; Checkouts

(defun harness-revision-parse-status (output)
  "Parse OUTPUT of git status --porcelain=v2 --branch into a plist.
It has :commit, the full hash of HEAD (nil before the first commit),
:branch (nil on a detached HEAD) and :dirty, t when a tracked file has
changes."
  (let (commit branch dirty)
    (dolist (line (split-string output "\n" t))
      (cond ((string-prefix-p "# branch.oid " line)
             (let ((oid (substring line 13)))
               (unless (equal oid "(initial)") (setq commit oid))))
            ((string-prefix-p "# branch.head " line)
             (let ((head (substring line 14)))
               (unless (equal head "(detached)") (setq branch head))))
            ((string-prefix-p "#" line))
            (t (setq dirty t))))
    (list :commit commit :branch branch :dirty dirty)))

(defun harness-revision--same-directory-p (a b)
  "Non-nil when directories A and B are the same, links followed."
  (equal (file-name-as-directory (file-truename (expand-file-name a)))
         (file-name-as-directory (file-truename (expand-file-name b)))))

(defun harness-revision-describe-checkout (dir)
  "Describe the git checkout DIR, in the background.
Return a promise of (:commit HASH :branch NAME :dirty BOOL), the state
of DIR's working tree now (see `harness-revision-parse-status').  It is
rejected with a `harness-error' when DIR is not the top of a git working
tree, or git fails."
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (if (not (file-directory-p dir))
        (harness-revision-failed (format "%s does not exist" (abbreviate-file-name dir)))
      (harness-then
       (harness-all
        (list (harness-revision-git dir '("rev-parse" "--show-toplevel"))
              (harness-revision-git dir '("--no-optional-locks" "status" "--porcelain=v2"
                                          "--branch" "--untracked-files=no"))))
       (lambda (outputs)
         (let ((status (harness-revision-parse-status (cadr outputs))))
           (cond ((not (harness-revision--same-directory-p (string-trim (car outputs)) dir))
                  (harness-revision-failed
                   (format "%s is not a git checkout of its own" (abbreviate-file-name dir))))
                 ((not (plist-get status :commit))
                  (harness-revision-failed (format "%s has no commit yet" (abbreviate-file-name dir))))
                 (t status))))))))

;;;; What this Emacs loaded

(defvar harness-revision--loaded nil
  "Promise of the revision this Emacs last loaded the harness from, or nil.
See `harness-revision-loaded'.")

(defun harness-revision-source-directory ()
  "Return the directory the running harness's files come from.
That is `harness-directory' with symbolic links followed: straight.el
and other package managers load the harness from a build directory of
links into their clone of it, and the clone is the checkout."
  (file-name-directory (file-truename (expand-file-name "harness.el" harness-directory))))

(defun harness-revision-note-loaded ()
  "Note, in the background, the revision this Emacs just loaded the harness from.
`harness-start-hook' and `harness-reload-hook' run it: the files were
just read, so the checkout's commit now is the one running.  Return the
promise `harness-revision-loaded' gives from now on."
  (let ((dir (harness-revision-source-directory))
        (loaded (float-time)))
    (setq harness-revision--loaded
          (harness-then (harness-revision-describe-checkout dir)
                        (lambda (status)
                          (append (list :directory dir :loaded loaded :version harness-version) status))
                        (lambda (err)
                          (list :directory dir :loaded loaded :version harness-version
                                :error (harness-revision-error-message err)))))))

(defun harness-revision-loaded ()
  "Return a promise of the revision this Emacs runs the harness from.
It is a plist: :directory the checkout, :loaded when the files were
read (float seconds), :version `harness-version', and :commit, :branch
and :dirty as the checkout was then -- or :error, saying why there is
no commit, such as a harness installed from a package archive.  It is
never rejected.  A harness started without `harness-start' notes its
revision on the first call."
  (or harness-revision--loaded (harness-revision-note-loaded)))

(add-hook 'harness-start-hook #'harness-revision-note-loaded)
(add-hook 'harness-reload-hook #'harness-revision-note-loaded)

;;;; Reading commits

(defconst harness-revision-commit-format "%H%x1f%ct%x1f%s%x1f%b"
  "git log format of a commit read as a changelog entry.
Fields, separated by the ASCII unit separator: the full commit hash,
the commit time in seconds, the subject and the message body.  Read
with `-z', so a body of several lines stays one record.  No diff or
file statistics: a commit is its message.")

(defun harness-revision-parse-commits (output)
  "Parse OUTPUT of a git log in `harness-revision-commit-format' into plists.
Each commit is (:commit HASH :date SECONDS :subject TEXT :body TEXT),
the body empty when the commit has none, in the order git printed
them.  Output of a log without `-z' reads as one commit."
  (delq nil
        (mapcar (lambda (record)
                  (let ((fields (split-string record "\x1f")))
                    (when (>= (length fields) 3)
                      (list :commit (nth 0 fields)
                            :date (string-to-number (nth 1 fields))
                            :subject (nth 2 fields)
                            :body (string-trim (string-join (nthcdr 3 fields) "\x1f"))))))
                (split-string output "\0" t))))

(provide 'harness-revision)
;;; harness-revision.el ends here
