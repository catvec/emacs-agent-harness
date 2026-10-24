;;; harness-version.el --- Is the running harness the latest?  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Answers "are we running the latest changes?".  The harness runs the
;; commit it was loaded from (see harness-revision.el); this module
;; compares that commit with the origins newer versions come from:
;;
;; - the checkout it was loaded from, as that checkout is now: whatever
;;   was pulled or merged there since runs only after a reload;
;; - the repository that checkout pulls from: the remote its branch
;;   tracks, which straight.el and other package managers set to the
;;   recipe's repository -- sourcehut, GitHub or another mirror, so the
;;   one an installation can reach is the one checked -- read with git
;;   ls-remote;
;; - the local checkouts of the harness that sessions work in, found from
;;   the sessions' projects, such as a development checkout whose main
;;   has merged work not pushed anywhere yet;
;; - `harness-version-origins', any more the user names.
;;
;; An origin is the same as the running commit, newer (it has commits
;; the harness lacks, which are listed), older, diverged, ahead, or
;; unknown.  The relation is worked out in a local repository holding
;; both commits, local checkouts first: package managers clone shallowly,
;; and a shallow clone's history can be cut between the two.  Nothing is
;; fetched, so an origin's new commit is often in no local repository
;; yet: when the checkout the harness was loaded from lacks it, so does
;; the harness, and the origin is ahead, by commits nobody has counted.
;;
;; All of it runs in the background.  Every git command is asynchronous
;; and never prompts (`harness-revision-git'); a check runs once however
;; many callers ask for it, and its report is kept; checks run by
;; themselves a little after the harness starts or reloads and every half
;; hour, and each report is announced with `version/checked', which the
;; UI follows.  `version/check' answers from the last report unless asked
;; for a fresher one; `version/report' answers with the last report, or
;; nil, and never checks.
;;
;; A report is a plist:
;;
;;   :checked  when it was made (float seconds)
;;   :version  `harness-version'
;;   :running  the revision running: :directory :loaded :commit :branch
;;             :dirty :subject :date, or :error (see `harness-revision-loaded')
;;   :origins  a list of plists, one per origin: :name, :kind ("loaded",
;;             "local" or "remote"), :location, :branch, :upstream (t for
;;             the repository the loaded checkout pulls from), :commit,
;;             :subject, :date, :dirty (a checkout with uncommitted
;;             changes), :status, :missing and :extra (how many commits
;;             the harness lacks and how many the origin lacks, merges
;;             counted), :missing-commits and :extra-commits (the newest
;;             of them, merges left out, each (:commit :date :subject :body)),
;;             :error
;;   :plugins  a list of plists, one per plugin the running harness has:
;;             :name, :version (its Version header, or nil), :directory,
;;             :files, :checkout, :commit/:subject/:date (its last change),
;;             :status ("same", "newer", "older", "diverged", "ahead",
;;             "untracked", "unknown" or "error"), :missing, :extra,
;;             :target, :remote, :branch, :error
;;   :verdict  "latest", "behind" or "unknown"
;;
;; :status is "same", "newer", "older", "diverged", "ahead" (a commit
;; the harness lacks, not counted), "unknown" or "error".  The verdict is
;; "behind" when the checkout the harness runs from, or the repository
;; that checkout pulls from, is newer, diverged or ahead; "unknown" when
;; one of those cannot be placed or read and none says behind; else
;; "latest".  Other checkouts of the harness, such as a development
;; checkout whose commits are not pushed, are compared with but are not
;; version origins: the running harness cannot be updated from them, so
;; they do not make it behind.  A plugin is checked against the commits
;; that touched its directory in the same origins.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)
(require 'harness-revision)

(defvar harness-version)

(defcustom harness-version-origins nil
  "More places newer versions of the harness come from, to compare with.
The version check finds the usual ones by itself: the checkout the
harness was loaded from, the repository that checkout pulls from (the
remote its branch tracks, which straight.el sets to the recipe's, be it
sourcehut or GitHub) and the local checkouts of the harness that
sessions work in.  List others here, such as a mirror the installation
does not pull from.  Each entry is a plist:

  :name      what the version page calls it
  :location  a local checkout of the harness, or the URL of a git
             repository (read with git ls-remote; nothing is fetched)
  :branch    the branch to compare with; without it, a checkout's
             current commit and the branch a repository's HEAD names

Repositories are read in the background and never prompt: one that
needs credentials should have an ssh URL whose key is in the ssh
agent."
  :type '(repeat
          (plist
           :tag "Origin"
           :value (:name "upstream" :location "https://git.sr.ht/~catvec/emacs-agent-harness")
           :options
           ((:name (string :tag "Name" :value "upstream"
                           :doc "What the version page calls it."))
            (:location (string :tag "Location" :value "https://git.sr.ht/~catvec/emacs-agent-harness"
                               :doc "A local checkout of the harness, or the URL of a git repository."))
            (:branch (choice :tag "Branch" :value nil
                             :doc "The branch to compare with."
                             (const :tag "Current or default branch" nil)
                             (string :tag "Branch name"))))))
  :group 'harness)

(defconst harness-version--interval (* 30 60)
  "Seconds between checks in the background.
Often enough to notice a push or a merge within the hour; rarely
enough that the requests to a remote repository cost nothing.")

(defconst harness-version--start-delay 30
  "Seconds after the harness starts before the first check.
Starting is busy enough without git processes and network requests.")

(defconst harness-version--reload-delay 3
  "Seconds after a reload before checking again.
A reload is how a new commit starts running, so it is checked soon.")

(defconst harness-version--remote-timeout 30
  "Seconds git ls-remote gets to answer for a remote repository.")

(defconst harness-version--stuck-after 300
  "Seconds after which a check still running is not joined but replaced.
Every git command times out well before; this guards against a bug
leaving a check pending forever, which would stop all later ones.")

(defconst harness-version--listed 8
  "How many of an origin's commits the harness lacks a report lists.")

(defvar harness-version--report nil "The last report, or nil.")

(defvar harness-version--report-revision nil
  "The `harness-revision-loaded' promise the last report is about.
After a reload the harness runs another revision, and the report no
longer answers for it.")

(defvar harness-version--checking nil
  "(REVISION STARTED PROMISE) of the check running, or nil.")

(defvar harness-version--timer nil "Timer running the checks in the background.")

(harness-declare-event 'version/checked
                       "A check of the running harness against its origins finished; arg: the report.")

;;;; Origins

(defun harness-version--url-p (location)
  "Non-nil when LOCATION is a git URL rather than a directory."
  (or (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" location)
      ;; scp-like, as git reads it: a colon before any slash, as in
      ;; git@git.sr.ht:~user/repo or a host of ~/.ssh/config, box:repo
      ;; (two characters at least, so as not to take a drive letter).
      (and (string-match-p "\\`[^/:]\\{2,\\}:" location) (not (file-remote-p location)))))

(defun harness-version--key (location)
  "Return a key telling whether two origin LOCATIONs are the same."
  (if (harness-version--url-p location)
      (string-remove-suffix ".git" (string-remove-suffix "/" location))
    (file-name-as-directory (file-truename (expand-file-name location)))))

(defun harness-version--harness-checkout-p (dir)
  "Non-nil when DIR holds the harness's own files."
  (and (file-exists-p (expand-file-name "harness.el" dir))
       (file-exists-p (expand-file-name "lisp/harness-core.el" dir))))

(defun harness-version--session-checkouts ()
  "Return the local checkouts of the harness that sessions work in.
A session's project counts through the main checkout that owns it, so
the worktrees of a checkout's tasks all lead to that checkout."
  (when (harness-method-exists-p 'session/list)
    (let ((roots nil) (out nil))
      (dolist (s (harness-call 'session/list))
        (let ((root (plist-get s :project)))
          (when (and (stringp root) (not (plist-get s :host)) (not (file-remote-p root)))
            (cl-pushnew root roots :test #'equal))))
      (dolist (root (nreverse roots))
        (let ((checkout (ignore-errors (harness-files-owning-checkout root))))
          (when (and checkout (harness-version--harness-checkout-p checkout))
            (cl-pushnew (file-name-as-directory (expand-file-name checkout)) out :test #'equal))))
      (nreverse out))))

(defconst harness-version--hosts
  '(("github.com" . "github") ("git.sr.ht" . "sourcehut") ("gitlab.com" . "gitlab")
    ("codeberg.org" . "codeberg") ("bitbucket.org" . "bitbucket"))
  "What the version page calls the repositories of well-known hosts.")

(defun harness-version--host (url)
  "Return the host of the git URL, downcased, or nil for a local repository."
  (let ((host (cond ((string-match "\\`[a-zA-Z][a-zA-Z0-9+.-]*://\\(?:[^@/]*@\\)?\\([^/:]*\\)" url)
                     ;; Empty for file:///srv/harness.
                     (match-string 1 url))
                    ((harness-version--url-p url)
                     (and (string-match "\\`\\(?:[^/:@]*@\\)?\\([^/:]+\\):" url)
                          (match-string 1 url))))))
    (and host (not (string-empty-p host)) (downcase host))))

(defun harness-version--host-name (url)
  "Return what the version page calls the repository at URL, after its host."
  (let ((host (harness-version--host url)))
    (or (cdr (assoc host harness-version--hosts)) host "upstream")))

(defun harness-version--upstream (running)
  "Return a promise of the origin the checkout RUNNING was loaded from pulls from.
That is the remote its branch tracks, on the branch it tracks there:
straight.el and other package managers clone the recipe's repository
and track its branch, so whichever repository an installation came from
-- sourcehut, GitHub, a mirror -- is the one compared with.  On a
detached HEAD, or a branch tracking no remote, it is the remote origin
and the branch its HEAD names.  The URL is as configured, before any
insteadOf rewriting, which git ls-remote does itself.  The promise is
of nil when RUNNING has no commit or its checkout no remote; never
rejected."
  (let ((dir (plist-get running :directory))
        (branch (plist-get running :branch)))
    (if (not (and dir (plist-get running :commit)))
        (harness-resolved nil)
      (harness-then
       (harness-revision-remote dir branch)
       (lambda (target)
         (when target
           (let* ((url (plist-get target :url))
                  (path (not (harness-version--url-p url)))
                  ;; Without a tracked upstream the remote's own HEAD
                  ;; branch counts, read with ls-remote below.
                  (branch (and (plist-get target :tracked) (plist-get target :branch))))
             ;; A remote that is a directory, relative to the checkout
             ;; as git reads it, is a local repository, read on its
             ;; branch; without one, ls-remote reads the branch its
             ;; HEAD names, as for a URL.
             (list :name (harness-version--host-name url)
                   :kind (if (and path branch) "local" "remote")
                   :location (if path (file-name-as-directory (expand-file-name url dir)) url)
                   :branch branch
                   :upstream t))))
       (lambda (_err) nil)))))

(defun harness-version--origins (running &optional upstream)
  "Return the origins to compare RUNNING with, as (:name :kind :location :branch).
The checkout RUNNING was loaded from comes first, then local checkouts
\(the configured ones, then those of sessions), then remote
repositories.  UPSTREAM, the repository that checkout pulls from (see
`harness-version--upstream'), comes first among those of its kind,
unless the configuration names it already, on its branch or none.  An
origin met twice is listed once."
  (let ((seen nil) (loaded nil) (local nil) (remote nil) (up nil))
    (cl-flet ((new-p (location branch)
                (let ((key (list (harness-version--key location) branch)))
                  (unless (member key seen) (push key seen) t))))
      (when-let* ((dir (and (plist-get running :commit) (plist-get running :directory))))
        (new-p dir nil)
        (setq loaded (list (list :name "loaded" :kind "loaded" :location dir))))
      (dolist (o harness-version-origins)
        (let ((location (plist-get o :location))
              (branch (plist-get o :branch)))
          (when (and (stringp location) (not (string-empty-p location)))
            (let* ((url (harness-version--url-p location))
                   (location (if url location (file-name-as-directory (expand-file-name location)))))
              (when (new-p location branch)
                (let ((origin (list :name (or (plist-get o :name) (abbreviate-file-name location))
                                    :kind (if url "remote" "local")
                                    :location location :branch branch)))
                  (if url (push origin remote) (push origin local))))))))
      (when upstream
        (let ((location (plist-get upstream :location)))
          (when (and (not (member (list (harness-version--key location) nil) seen))
                     (new-p location (plist-get upstream :branch)))
            (setq up upstream))))
      (dolist (dir (harness-version--session-checkouts))
        (when (new-p dir nil)
          (push (list :name "local" :kind "local" :location dir) local))))
    (cl-flet ((first-of (kind) (and up (equal (plist-get up :kind) kind) (list up))))
      (append loaded (first-of "local") (nreverse local) (first-of "remote") (nreverse remote)))))

;;;; Reading an origin

(defun harness-version--ls-remote (url branch)
  "Return a promise of (:commit HASH :branch NAME) for BRANCH at URL.
URL is a git repository; without BRANCH, the branch its HEAD names
counts.  Credential helpers are left out: in the background they could
only prompt."
  (harness-then
   (harness-revision-git nil (append '("-c" "credential.helper=" "ls-remote")
                                     (if branch
                                         (list url (concat "refs/heads/" branch))
                                       (list "--symref" url "HEAD")))
                         harness-version--remote-timeout)
   (lambda (output)
     (let ((wanted (if branch (concat "refs/heads/" branch) "HEAD"))
           commit head)
       (dolist (line (split-string output "\n" t))
         (cond ((string-match "\\`ref: refs/heads/\\(.+\\)\tHEAD\\'" line)
                (setq head (match-string 1 line)))
               ((string-match "\\`\\([0-9a-f]\\{40,64\\}\\)\t\\(.+\\)\\'" line)
                (when (equal (match-string 2 line) wanted)
                  (setq commit (match-string 1 line))))))
       (if commit
           (list :commit commit :branch (or branch head))
         (harness-revision-failed (if branch (format "it has no branch %s" branch) "it has no commit")))))))

(defun harness-version--branch-commit (dir branch)
  "Return a promise of (:commit HASH :branch BRANCH) for BRANCH in DIR."
  (if (string-prefix-p "-" branch)
      (harness-revision-failed (format "%s is no branch name" branch))
    (harness-then (harness-revision-git dir (list "rev-parse" "--verify" "--quiet" (concat branch "^{commit}")))
                  (lambda (output) (list :commit (string-trim output) :branch branch))
                  (lambda (_err) (harness-revision-failed (format "it has no branch %s" branch))))))

(defun harness-version--read-origin (origin)
  "Return a promise of ORIGIN with what it holds now.
That is :commit and :branch, with :dirty for a checkout; or :status
\"error\" and :error when it cannot be read.  Never rejected."
  (let ((location (plist-get origin :location))
        (branch (plist-get origin :branch)))
    (harness-then
     (cond ((equal (plist-get origin :kind) "remote")
            (harness-version--ls-remote location branch))
           ((file-remote-p location)
            (harness-revision-failed "a remote directory; give the URL of its repository"))
           (branch (harness-version--branch-commit location branch))
           (t (harness-revision-describe-checkout location)))
     (lambda (state) (harness-plist-merge origin state))
     (lambda (err) (harness-plist-merge origin (list :status "error"
                                                     :error (harness-revision-error-message err)))))))

;;;; Relating an origin to the running commit

(defun harness-version--describe-commit (repo commit)
  "Return a promise of COMMIT as (:commit :date :subject :body), or of nil."
  (harness-then (harness-revision-git repo (list "log" "-1" "-z"
                                                 (concat "--format=" harness-revision-commit-format)
                                                 commit "--"))
                (lambda (output) (car (harness-revision-parse-commits output)))
                (lambda (_err) nil)))

(defun harness-version--commits (repo from to)
  "Return a promise of the newest commits of TO that FROM lacks, in REPO.
Merges are left out: a task's merge says less than its own commits.
Each is (:commit :date :subject :body).  Of nil when git fails."
  (harness-then (harness-revision-git repo (list "log" "-z" "--no-merges"
                                                 (format "--max-count=%d" harness-version--listed)
                                                 (concat "--format=" harness-revision-commit-format)
                                                 (concat from ".." to) "--"))
                #'harness-revision-parse-commits
                (lambda (_err) nil)))

(defun harness-version--count (repos running origin)
  "Return a promise of (REPO EXTRA MISSING), counted in the first REPO that can.
That is the first of REPOS holding both the commits RUNNING and ORIGIN.
EXTRA counts the commits of RUNNING that ORIGIN lacks, MISSING those of
ORIGIN that RUNNING lacks.  Of nil when no repository holds both."
  (if (null repos)
      (harness-resolved nil)
    (harness-then
     (harness-revision-git (car repos) (list "rev-list" "--left-right" "--count" (concat running "..." origin) "--"))
     (lambda (output)
       (let ((counts (split-string output)))
         (list (car repos) (string-to-number (nth 0 counts)) (string-to-number (nth 1 counts)))))
     (lambda (_err) (harness-version--count (cdr repos) running origin)))))

(defun harness-version--repositories (running origins)
  "Return the local repositories to relate commits in, best first.
The local checkouts among ORIGINS read without trouble come first, the
checkout RUNNING was loaded from last: a package manager's clone is
often shallow."
  (let ((out nil))
    (dolist (o origins)
      (when (and (equal (plist-get o :kind) "local") (not (plist-get o :error)))
        (cl-pushnew (plist-get o :location) out :test #'equal)))
    (when-let* ((dir (and (plist-get running :commit) (plist-get running :directory))))
      (setq out (cons dir (delete dir out))))
    (nreverse out)))

(defun harness-version--has-commit (repo commit)
  "Return a promise of non-nil when the repository REPO has COMMIT."
  (harness-then (harness-revision-git repo (list "cat-file" "-e" (concat commit "^{commit}")))
                (lambda (_) t)
                (lambda (_err) nil)))

(defun harness-version--unplaced (running origin)
  "Return a promise of ORIGIN, whose commit no repository holds with RUNNING's.
When the checkout RUNNING was loaded from lacks the origin's commit,
the harness lacks it too: the origin is \"ahead\", by commits nobody
fetched to count (in a shallow clone, unless the origin went back to a
commit older than the cut, which a branch that only moves forward
never does).  When that checkout has it, it is the running commit that
went missing, and the origin is \"unknown\"."
  (let ((dir (plist-get running :directory)))
    (if (not (and dir (file-directory-p dir)))
        (harness-resolved (harness-plist-merge origin (list :status "unknown")))
      (harness-then (harness-version--has-commit dir (plist-get origin :commit))
                    (lambda (has)
                      (harness-plist-merge origin (list :status (if has "unknown" "ahead"))))))))

(defun harness-version--relate (running origin repos)
  "Return a promise of ORIGIN with its relation to the RUNNING commit worked out.
REPOS are the local repositories to look for both commits in.  Never rejected."
  (let ((r (plist-get running :commit))
        (o (plist-get origin :commit)))
    (cond
     ((plist-get origin :error) (harness-resolved origin))
     ((null r) (harness-resolved (harness-plist-merge origin (list :status "unknown"))))
     ((equal r o) (harness-resolved (harness-plist-merge origin (list :status "same" :missing 0 :extra 0))))
     (t
      (harness-catch
       (harness-then
        (harness-version--count repos r o)
        (lambda (found)
          (if (null found)
              (harness-version--unplaced running origin)
            (pcase-let ((`(,repo ,extra ,missing) found))
              (harness-then
               (harness-all (list (harness-version--describe-commit repo o)
                                  (and (> missing 0) (harness-version--commits repo r o))
                                  (and (> extra 0) (harness-version--commits repo o r))))
               (lambda (parts)
                 (harness-plist-merge
                  origin
                  (list :status (cond ((and (> missing 0) (> extra 0)) "diverged")
                                      ((> missing 0) "newer")
                                      ((> extra 0) "older")
                                      (t "same"))
                        :subject (plist-get (nth 0 parts) :subject)
                        :date (plist-get (nth 0 parts) :date)
                        :missing missing :extra extra
                        :missing-commits (nth 1 parts) :extra-commits (nth 2 parts)))))))))
       (lambda (err)
         (harness-plist-merge origin (list :status "error" :error (harness-revision-error-message err)))))))))

;;;; Plugins

(defconst harness-version--plugin-header-bytes 4000
  "How much of a plugin's file the Version header is read from.")

(defun harness-version--version-header (file)
  "Return the version in FILE's package header, or nil.
A plugin is a package in miniature: its `Version:' header is its
version, as `package.el' reads a package's."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file nil 0 harness-version--plugin-header-bytes)
      (goto-char (point-min))
      (when (re-search-forward "^;; Version:[ \t]+\\([^ \t\n]+\\)" nil t)
        (match-string 1)))))

(defun harness-version--plugin-el-files (dir)
  "Return the source files of the plugin in DIR, its tests left out.
The file named for the directory comes first, so its header is the
plugin's version; the rest follow sorted."
  (let* ((name (file-name-nondirectory (directory-file-name dir)))
         (files (cl-remove-if (lambda (file) (string-match-p "-test\\.el\\'" file))
                              (directory-files dir t "\\`[^.].*\\.el\\'"))))
    (sort files (lambda (a b)
                  (cond ((equal (file-name-base a) name) t)
                        ((equal (file-name-base b) name) nil)
                        (t (string< a b)))))))

(defun harness-version--plugin-version (files)
  "Return the version of the plugin whose source FILES are these, or nil."
  (cl-some #'harness-version--version-header files))

(defun harness-version--plugin-directories (running)
  "Return the directories of the plugins of the running harness, sorted.
That is the libraries vendored under lisp/vendor and the plugin modules
loaded into this process, such as a project's own plugins loaded from
its directory-local variables.  A plugin directory counts once."
  (let* ((root (plist-get running :directory))
         (vendor (and root (expand-file-name "lisp/vendor" root)))
         (vendored (and vendor (file-directory-p vendor)
                        (cl-remove-if-not #'file-directory-p
                                          (directory-files vendor t "\\`[^.]"))))
         (loaded (when (and (fboundp 'harness-modules)
                            (fboundp 'harness-module-plugin-p))
                   ;; The harness's own module directories, where its code
                   ;; loaded from: not the checkout the report is about,
                   ;; which a test may have rebound.
                   (let ((root (if (and (boundp 'harness--self-file) harness--self-file)
                                   (file-name-directory harness--self-file)
                                 root)))
                     (delq nil
                           (mapcar
                            (lambda (module)
                              (let ((name (harness-module-name module)))
                                (when (harness-module-plugin-p name)
                                  (when-let* ((file (harness-module-file module)))
                                    (let ((dir (file-name-directory
                                                (file-truename (expand-file-name file)))))
                                      (unless (cl-some
                                               (lambda (own)
                                                 (file-in-directory-p
                                                  dir (expand-file-name own root)))
                                               '("lisp/modules" "lisp/ui"))
                                        dir))))))
                            (harness-modules)))))))
    (sort (delete-dups (append vendored loaded)) #'string<)))

(defun harness-version--path-count (repo from to path)
  "Return a promise of how many commits of FROM..TO touch PATH in REPO.
Nil when the two commits cannot be compared there."
  (if (or (null from) (null to) (equal from to))
      (harness-resolved 0)
    (harness-then
     (harness-revision-git repo (list "rev-list" "--count" (concat from ".." to)
                                      "--" (or path ".")))
     (lambda (output) (string-to-number (string-trim output)))
     (lambda (_err) nil))))

(defun harness-version--plugin-last-commit (repo path)
  "Return a promise of the last commit of REPO touching PATH.
That is (:commit :date :subject :body), or nil."
  (harness-then
   (harness-revision-git repo (list "log" "-1" "-z"
                                    (concat "--format=" harness-revision-commit-format)
                                    "--" (or path ".")))
   (lambda (output) (car (harness-revision-parse-commits output)))
   (lambda (_err) nil)))

(defun harness-version--plugin-in-running (running checkout)
  "Non-nil when CHECKOUT is the checkout RUNNING was loaded from."
  (let ((dir (plist-get running :directory)))
    (and dir checkout (harness-revision--same-directory-p dir checkout))))

(defun harness-version--plugin-counts (plugin running origins)
  "Return a promise of PLUGIN with its relation to ORIGINS worked out.
PLUGIN is one in the checkout RUNNING was loaded from; ORIGINS are the
report's origins, already related to the running commit.  Only the
commits that touched the plugin's directory count."
  (let* ((checkout (plist-get plugin :checkout))
         (dir (plist-get plugin :directory))
         (rel (file-relative-name dir checkout))
         (commit (plist-get running :commit))
         (missing 0)
         (uncounted nil))
    (harness-then
     (harness-all
      (mapcar
       (lambda (origin)
         (if (not (harness-version--version-origin-p origin))
             (harness-resolved nil)
           (pcase (plist-get origin :status)
             ((or "newer" "diverged")
              (harness-then
               (harness-version--path-count checkout commit (plist-get origin :commit) rel)
               (lambda (n)
                 (if n (setq missing (+ missing n)) (setq uncounted t))
                 nil)))
             ("ahead" (setq uncounted t) (harness-resolved nil))
             (_ (harness-resolved nil)))))
       origins))
     (lambda (_)
       (harness-plist-merge plugin
                            (list :status (cond ((> missing 0) "newer")
                                                (uncounted "ahead")
                                                (t "same"))
                                  :missing (unless uncounted missing)))))))

(defun harness-version--plugin-remote-result (plugin head remote target found)
  "Return PLUGIN of HEAD, against TARGET of REMOTE, from the counts FOUND."
  (let ((base (harness-plist-merge
               plugin
               (list :commit head
                     :remote (plist-get remote :url)
                     :branch (or (plist-get remote :branch)
                                 (plist-get target :branch))
                     :target (plist-get target :commit)))))
    (if (null found)
        (harness-plist-merge base (list :status "ahead" :missing nil))
      (pcase-let ((`(,_repo ,extra ,missing) found))
        (harness-plist-merge
         base
         (list :status (cond ((and (> missing 0) (> extra 0)) "diverged")
                             ((> missing 0) "newer")
                             ((> extra 0) "older")
                             (t "same"))
               :missing missing :extra extra))))))

(defun harness-version--plugin-remote (plugin)
  "Return a promise of PLUGIN, outside the running checkout, against its remote.
Its status is how its own checkout stands to the branch it pulls from:
what its update action would change."
  (let ((checkout (plist-get plugin :checkout)))
    (harness-then
     (harness-all
      (list (harness-revision-describe-checkout checkout)
            (harness-revision-remote checkout)))
     (lambda (parts)
       (let ((head (plist-get (nth 0 parts) :commit))
             (remote (nth 1 parts)))
         (if (null remote)
             (harness-plist-merge plugin (list :commit head :status "untracked"))
           (harness-then
            (harness-version--ls-remote (plist-get remote :url)
                                        (and (plist-get remote :tracked)
                                             (plist-get remote :branch)))
            (lambda (target)
              (harness-then
               (harness-version--count (list checkout) head (plist-get target :commit))
               (lambda (found)
                 (harness-version--plugin-remote-result plugin head remote target found))))))))
     (lambda (err)
       (harness-plist-merge plugin
                            (list :status "error"
                                  :error (harness-revision-error-message err)))))))

(defun harness-version--plugin-checkout (dir)
  "Return a promise of the top of the git checkout holding DIR, or nil."
  (harness-then
   (harness-revision-git dir '("rev-parse" "--show-toplevel"))
   (lambda (output) (file-name-as-directory (expand-file-name (string-trim output))))
   (lambda (err)
     (harness-log 'debug "version: %s is no git checkout: %s"
                  (abbreviate-file-name dir) (harness-revision-error-message err))
     nil)))

(defun harness-version--read-plugin (dir running origins)
  "Return a promise of DIR as a plugin of the running harness.
RUNNING and ORIGINS are the report's, already related.  Never rejected:
an unreadable plugin is one with an :error."
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (files (harness-version--plugin-el-files dir))
         (plugin (list :name (file-name-nondirectory (directory-file-name dir))
                       :version (harness-version--plugin-version files)
                       :directory (directory-file-name dir)
                       :files (mapcar (lambda (file) (file-relative-name file dir)) files)
                       :checkout nil
                       :status "unknown")))
    (if (null files)
        (harness-resolved nil)
      (harness-then
       (harness-version--plugin-checkout dir)
       (lambda (checkout)
         (if (null checkout)
             (harness-plist-merge plugin (list :status "untracked"))
           (let* ((plugin (harness-plist-merge plugin (list :checkout checkout)))
                  (rel (file-relative-name dir checkout)))
             (harness-then
              (harness-all
               (list (harness-version--plugin-last-commit checkout rel)
                     (harness-catch
                      (if (harness-version--plugin-in-running running checkout)
                          (harness-version--plugin-counts plugin running origins)
                        (harness-version--plugin-remote plugin))
                      (lambda (err)
                        (harness-plist-merge
                         plugin
                         (list :status "error"
                               :error (harness-revision-error-message err)))))))
              (lambda (parts)
                (harness-plist-merge (nth 1 parts)
                                     (list :commit (or (plist-get (nth 0 parts) :commit)
                                                       (plist-get (nth 1 parts) :commit))
                                           :subject (plist-get (nth 0 parts) :subject)
                                           :date (plist-get (nth 0 parts) :date)
                                           :body (plist-get (nth 0 parts) :body))))))))))))

(defun harness-version--plugins (running origins)
  "Return a promise of the plugins of the running harness.
Each is a plist; see the report's shape at the top of this file."
  (harness-all
   (mapcar (lambda (dir) (harness-version--read-plugin dir running origins))
           (harness-version--plugin-directories running))))

(defun harness-version--describe-running (running)
  "Return a promise of RUNNING with the subject and date of its commit."
  (if-let* ((commit (plist-get running :commit)))
      (harness-then (harness-version--describe-commit (plist-get running :directory) commit)
                    (lambda (described)
                      (harness-plist-merge running (list :subject (plist-get described :subject)
                                                         :date (plist-get described :date)))))
    (harness-resolved running)))

(defun harness-version--development-counts (_running origins)
  "Return a promise of ORIGINS, development checkouts with :unpushed.
That is how many of a development checkout's commits the upstream
repository the running harness pulls from lacks: what a push would
send.  Nil when the checkout does not hold the upstream commit."
  (let ((upstream (cl-find-if (lambda (o) (eq (plist-get o :upstream) t)) origins)))
    (harness-all
     (mapcar
      (lambda (origin)
        (if (or (not (equal (plist-get origin :kind) "local"))
                (harness-version--version-origin-p origin)
                (null (plist-get origin :commit)))
            (harness-resolved origin)
          (harness-then
           (if (and upstream (plist-get upstream :commit))
               (harness-version--path-count (plist-get origin :location)
                                            (plist-get upstream :commit)
                                            (plist-get origin :commit) ".")
             (harness-resolved nil))
           (lambda (n)
             (harness-plist-merge origin (list :unpushed n))))))
      origins))))

(defun harness-version--version-origin-p (origin)
  "Non-nil when ORIGIN is a place the running harness can get a new version from.
That is the checkout it was loaded from and the repository that checkout
pulls from.  Other checkouts of the harness are compared with, but the
running harness cannot be updated from them, so they do not make it
behind."
  (or (equal (plist-get origin :kind) "loaded")
      (eq (plist-get origin :upstream) t)))

(defun harness-version--verdict (origins)
  "Return the verdict on ORIGINS: \"latest\", \"behind\" or \"unknown\".
Only the origins the running harness can be updated from count (see
`harness-version--version-origin-p'): a development checkout with
unpushed commits is not one of them."
  (let* ((origins (cl-remove-if-not #'harness-version--version-origin-p origins))
         (statuses (mapcar (lambda (o) (plist-get o :status)) origins)))
    (cond ((cl-some (lambda (s) (member s statuses)) '("newer" "diverged" "ahead")) "behind")
          ((member "unknown" statuses) "unknown")
          ((or (member "same" statuses) (member "older" statuses)) "latest")
          (t "unknown"))))

(defun harness-version--make-report (revision)
  "Return a promise of a report on REVISION, a `harness-revision-loaded' promise."
  (harness-then
   revision
   (lambda (running)
     (harness-then
      (harness-version--upstream running)
      (lambda (upstream)
        (harness-then
         (harness-all (mapcar #'harness-version--read-origin (harness-version--origins running upstream)))
         (lambda (origins)
           (let ((repos (harness-version--repositories running origins)))
             (harness-then
              (harness-all (cons (harness-version--describe-running running)
                                 (mapcar (lambda (o) (harness-version--relate running o repos)) origins)))
              (lambda (results)
                (let ((running (car results))
                      (origins (cdr results)))
                  (harness-then
                   (harness-version--development-counts running origins)
                   (lambda (origins)
                     (harness-then
                      (harness-version--plugins running origins)
                      (lambda (plugins)
                        (list :checked (float-time) :version harness-version
                              :running running :origins origins :plugins plugins
                              :verdict (harness-version--verdict origins)))))))))))))))))

;;;; Checking

(defun harness-version--current-report ()
  "Return the last report when it is about the revision running now."
  (and harness-version--report
       (eq harness-version--report-revision (harness-revision-loaded))
       harness-version--report))

(defun harness-version--check ()
  "Check now, in the background; return the promise of the report.
A check already running for the revision running now is joined.  The
report is kept and announced with `version/checked'."
  (let ((revision (harness-revision-loaded)))
    (pcase harness-version--checking
      ((and `(,rev ,started ,promise)
            (guard (eq rev revision))
            (guard (< (- (float-time) started) harness-version--stuck-after)))
       promise)
      (_
       (let ((promise (harness-make-promise)))
         (setq harness-version--checking (list revision (float-time) promise))
         (harness-then (harness-version--make-report revision)
                       (lambda (report)
                         (when (eq (nth 2 harness-version--checking) promise)
                           (setq harness-version--checking nil))
                         (setq harness-version--report report
                               harness-version--report-revision revision)
                         (harness-emit 'version/checked report)
                         (harness-resolve promise report)
                         nil)
                       (lambda (err)
                         (when (eq (nth 2 harness-version--checking) promise)
                           (setq harness-version--checking nil))
                         (harness-log 'warn "version: the check failed: %s" (harness-revision-error-message err))
                         (harness-reject promise err)
                         nil))
         promise)))))

(harness-defmethod version/check (&optional max-age)
  "Return a promise of the report comparing the running harness with its origins.
The last report is the answer when it is at most MAX-AGE seconds old
\(any age when MAX-AGE is nil) and about the revision running now;
otherwise a check runs in the background, or the one running is
joined.  See harness-version.el for the report's shape."
  (let ((report (harness-version--current-report)))
    (if (and report
             (or (not (numberp max-age))
                 (<= (- (float-time) (plist-get report :checked)) max-age)))
        (harness-resolved report)
      (harness-version--check))))

(harness-defmethod version/report ()
  "Return the last report, when it is about the revision running now, else nil.
Unlike `version/check', it never checks.  A UI asks for it as it
connects, so its nag icon shows at once what the last check found,
while a harness just starting still checks only when it means to."
  (harness-version--current-report))

(defun harness-version--background-check ()
  "Check, from the timer; the report is announced, a failure was logged."
  (harness-catch (harness-version--check) #'ignore))

(defun harness-version--schedule (delay)
  "Check after DELAY seconds, then every `harness-version--interval'."
  (when (timerp harness-version--timer) (cancel-timer harness-version--timer))
  (setq harness-version--timer
        (run-at-time delay harness-version--interval #'harness-version--background-check)))

(defun harness-version--on-reloaded (&rest _)
  "Check again soon: a reload is how a new revision starts running."
  (harness-version--schedule harness-version--reload-delay))

(defun harness-version--init ()
  "Check a little after the start, after each reload and every half hour."
  (harness-on 'harness/reloaded #'harness-version--on-reloaded)
  (harness-version--schedule harness-version--start-delay))

(defun harness-version--shutdown ()
  "Stop checking in the background."
  (harness-off (cons 'harness/reloaded #'harness-version--on-reloaded))
  (when (timerp harness-version--timer) (cancel-timer harness-version--timer))
  (setq harness-version--timer nil))

(harness-define-module 'version
  :doc "Whether the running harness is the latest: its commit against its origins."
  :init #'harness-version--init
  :shutdown #'harness-version--shutdown)

(provide 'harness-version)
;;; harness-version.el ends here
