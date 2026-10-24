;;; harness-client-check.el --- Hold a hand-in of the Flutter app to its build check  -*- lexical-binding: t; -*-

;; Version: 0.1.0

;;; Commentary:

;; A plugin of the harness's own repository, not a module of the
;; harness.  What this repository asks of a task that changes its
;; Flutter app (harness_client/) is this repository's business, so it
;; lives in .harness/plugins/dev/, beside the other module of that
;; plugin, and only the sessions of this repository are asked (see
;; `harness-client-check--in-scope-p'): the repository's .dir-locals.el
;; loads the plugin and names this module, once the user trusts that
;; file's entries when Emacs asks (see harness-dev-plugin.el beside this
;; file, and lisp/modules/harness-plugins.el).  The harness knows
;; nothing of a Flutter app, an Android SDK or their licences.  It only
;; lets a project hold a hand-in to checks of its own, with the
;; asynchronous filter `task/before-hand-in' that `hand_in' runs
;; (lisp/modules/harness-tools-handin.el); this module adds one
;; function to it.
;;
;; Why.  Tasks had handed in apps that did not compile, whose tests
;; failed, or that built only from an empty build/ and not over the one
;; the user's checkout keeps.  Nothing a task could run before handing
;; in had ever built the app, so the first a person saw of it was a
;; build that failed.
;;
;; What.  A task that changed the app (the paths in
;; `harness-client-check--paths') is refused until the build check has
;; passed for the app as the branch now has it.  The check is
;; harness_client/tool/check_build.sh, which builds the committed tree
;; in a copy of its own and leaves a stamp -- the commit it passed for
;; -- in the worktree (`harness-client-check--stamp').  This module
;; only reads that stamp, with git: it never runs the worktree's
;; script, which the task's agent may have edited, outside the sandbox.
;; The stamp counts while the app's paths are as they were in that
;; commit and nothing in them is uncommitted, so a later commit of
;; notes, evidence or the Emacs side leaves it valid.  A task whose
;; branch left the app alone is asked nothing, nor is one that says it
;; cannot continue or has nothing to merge (`hand_in' puts neither to
;; the filter).
;;
;; Whose.  The filter runs for every session of the harness, so the
;; function asks first whether the session names this module in the
;; plugin modules it froze when it started
;; (`harness-client-check--in-scope-p'), as the tools of a plugin are
;; offered only to the sessions that name its module.  The
;; repository's .dir-locals.el names `client-check' in
;; `harness-plugin-modules', beside `tools-dev', so its sessions are
;; asked and no other session is.  A session keeps the list it started
;; with, so a task that began before the user trusted that entry is not
;; asked.  A task that another project's session started takes that
;; session's list, and its worktree has no harness_client/ paths to
;; change, so it is asked nothing either way.
;;
;; Failing open.  What git cannot answer -- no base to measure from, no
;; repository, a directory on another host -- holds nothing back, and
;; neither does a function that fails (`harness-run-filter-async'):
;; a gate that guesses refuses work that is fine.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-revision)

(defvar harness-client-check--paths
  '("harness_client/lib" "harness_client/test" "harness_client/android"
    "harness_client/assets" "harness_client/pubspec.yaml"
    "harness_client/pubspec.lock" "harness_client/analysis_options.yaml"
    "harness_client/.flutter-version")
  "The paths, relative to the repository, that a build of the Flutter app reads.
A task whose branch changes any of them, or has changes in them that are
not committed, cannot be handed in unless the build check passed for the
app as it is (see `harness-client-check--stamp').  The list is the
`inputs' of harness_client/tool/check_build.sh, and a test keeps the two
equal.  Nil asks nothing of any task.")

(defvar harness-client-check--stamp "scripts/.dev/client-check/stamp.json"
  "Where the build check leaves its stamp, relative to the task's worktree.
It is JSON with `result' (\"pass\") and `head' (the commit the check
passed for), written by `harness-client-check--command'.")

(defvar harness-client-check--command "harness_client/tool/check_build.sh"
  "The command, relative to the task's worktree, that makes the stamp.
It is only named to the agent that is refused; this module never runs it.")

;;;; Git, and the stamp

(defun harness-client-check--git (dir &rest args)
  "Return a promise of the output of git ARGS run in DIR, rejected when git fails.
It takes no optional lock: the task's agent may be committing in DIR."
  (harness-revision-git dir (cons "--no-optional-locks" args)))

(defun harness-client-check--lines (output)
  "Return the lines of git's OUTPUT that are not blank."
  (split-string (or output "") "\n" t "[ \t\r]+"))

(defun harness-client-check--file-list (files)
  "Return FILES, a list of names, as text: the first few, then how many more."
  (let ((shown (cl-subseq files 0 (min 6 (length files)))))
    (concat (string-join shown ", ")
            (and (> (length files) 6) (format " (%d more)" (- (length files) 6))))))

(defun harness-client-check--stamp-in (dir)
  "Return the build check's stamp in the worktree DIR as a plist, or nil."
  (let ((text (harness-read-file (expand-file-name harness-client-check--stamp dir))))
    (when text
      (let ((stamp (ignore-errors (harness-json-parse text))))
        (and (keywordp (car-safe stamp)) stamp)))))

(defun harness-client-check--stamp-problem (dir)
  "Return a promise of why the stamp in DIR does not cover the app, or of nil.
The stamp covers it when it says \"pass\" for a commit in the history of
HEAD and the app's paths are as they were in that commit."
  (let* ((stamp (harness-client-check--stamp-in dir))
         (head (and stamp (plist-get stamp :head)))
         (paths harness-client-check--paths))
    (cond
     ((null stamp)
      (harness-resolved
       (format "there is no stamp (%s): the check has not passed in this worktree"
               harness-client-check--stamp)))
     ((not (equal (plist-get stamp :result) "pass"))
      (harness-resolved (format "the stamp says %s, not \"pass\""
                                (prin1-to-string (plist-get stamp :result)))))
     ((not (and (stringp head) (string-match-p "\\`[0-9a-f]\\{40\\}\\'" head)))
      (harness-resolved "the stamp names no commit"))
     (t
      (harness-then
       (harness-all
        (list (harness-then (harness-client-check--git
                             dir "merge-base" "--is-ancestor" head "HEAD")
                            (lambda (_) t)
                            (lambda (_) nil))
              (harness-then (apply #'harness-client-check--git
                                   dir "diff" "--name-only" head "HEAD" "--" paths)
                            #'harness-client-check--lines
                            (lambda (_) :unknown))))
       (lambda (results)
         (let ((ancestor (nth 0 results))
               (changed (nth 1 results))
               (short (substring head 0 12)))
           (cond
            ((or (not ancestor) (eq changed :unknown))
             (format "the stamp is for %s, which is not in the history of this branch" short))
            (changed
             (format "the app changed after the check passed for %s: %s"
                     short (harness-client-check--file-list changed)))))))))))

;;;; The refusal

(defun harness-client-check--text (changed problem)
  "Return the refusal for an app change: CHANGED the files, PROBLEM why."
  (format "hand_in: this task changed the Flutter app (harness_client/), and its build check has not passed for the app as the branch has it now, so nothing is handed in.  Apps have been handed in that did not compile, whose tests failed, or whose release build died over the build a person already had; this repository asks that nothing of the app goes in unbuilt.

The app files that changed: %s
Why the check does not count: %s

In this worktree, after your last change to the app and with everything committed, run

  %s

It builds the committed tree in a copy of its own and passes only if pub get, analyze, the tests (no failure that the branch's base did not have), the release APK build and, when dependencies or Android files changed, the build over the base's build all pass.  It takes minutes, so give that bash call a timeout of 3600 seconds.  Where no Android SDK is installed -- a task's sandbox has none -- add --accept-android-licenses: the first run then installs Flutter, a JDK and an Android SDK of its own, and accepts the licences of that SDK only.  The whole output is kept under scripts/.dev/client-check/logs/.  Quote the run as evidence (a tool_call) and call hand_in again.

If the check cannot run here -- the toolchain cannot be downloaded, say -- do not hand in an unbuilt app: call hand_in with cannot_continue true and say what stopped it."
          (harness-client-check--file-list changed) problem
          harness-client-check--command))

(defun harness-client-check--refusal (task)
  "Return a promise of nil, or of the text refusing TASK's hand-in over the app.
TASK is refused when its branch (or its worktree) changes a path of
`harness-client-check--paths' and the build check has not passed for
the app as it stands.  A task with no worktree or base, or a repository
git cannot answer for, is asked nothing: what the task changed cannot be
told."
  (let ((dir (plist-get task :worktree))
        (base (plist-get task :base))
        (paths harness-client-check--paths))
    (if (or (null paths) (not (stringp dir)) (not (stringp base))
            (file-remote-p dir) (not (file-directory-p dir)))
        (harness-resolved nil)
      (harness-then
       (harness-catch (harness-client-check--git dir "merge-base" "HEAD" base)
                      (lambda (_) nil))
       (lambda (merge-base)
         (when (stringp merge-base)
           (harness-then
            (harness-all
             (list (harness-catch
                    (apply #'harness-client-check--git
                           dir "diff" "--name-only" (string-trim merge-base) "HEAD" "--" paths)
                    (lambda (_) ""))
                   (harness-catch
                    (apply #'harness-client-check--git
                           dir "status" "--porcelain" "--" paths)
                    (lambda (_) ""))))
            (lambda (outputs)
              (let* ((committed (harness-client-check--lines (nth 0 outputs)))
                     (uncommitted (mapcar (lambda (line) (replace-regexp-in-string "\\`.. " "" line))
                                          (harness-client-check--lines (nth 1 outputs))))
                     (changed (delete-dups (append committed uncommitted))))
                (when changed
                  (harness-then
                   (if uncommitted
                       (harness-resolved
                        (format "the app has changes that are not committed: %s"
                                (harness-client-check--file-list uncommitted)))
                     (harness-client-check--stamp-problem dir))
                   (lambda (problem)
                     (and problem (harness-client-check--text changed problem))))))))))))))

;;;; The filter

(defun harness-client-check--in-scope-p (session)
  "Non-nil when SESSION names this module among the plugin modules it froze.
That is the list `plugins/of-session' gives for it when it started, as
the tools of a plugin are offered only to the sessions that name it."
  (let ((id (plist-get session :id)))
    (and (stringp id)
         (harness-method-exists-p 'plugins/of-session)
         (memq 'client-check
               (condition-case err
                   (harness-call 'plugins/of-session id)
                 (error (harness-log 'warn "client-check: the plugins of session %s: %s"
                                     id (harness-error-message err))
                        nil)))
         t)))

(defun harness-client-check--before-hand-in (refusal _next task session)
  "Add what the app's build check says of TASK to REFUSAL, and pass it on.
A function of the filter `task/before-hand-in' (see
harness-tools-handin.el): REFUSAL is the text an earlier function
refused with, or nil.  SESSION is the task's session; one that does
not name this module is asked nothing.  It returns a promise, as the
filter allows, so _NEXT is not called here."
  (if (not (harness-client-check--in-scope-p session))
      (harness-resolved refusal)
    (harness-then (harness-client-check--refusal task)
                  (lambda (text)
                    (cond ((null text) refusal)
                          (refusal (concat refusal "\n\n" text))
                          (t text))))))

;;;; Module

(defun harness-client-check--init ()
  "Hold a task's hand-in to the app's build check."
  (harness-add-filter 'task/before-hand-in #'harness-client-check--before-hand-in 50))

(defun harness-client-check--shutdown ()
  "Stop holding hand-ins to it."
  (harness-remove-filter 'task/before-hand-in #'harness-client-check--before-hand-in))

(harness-define-module 'client-check
  :doc "Refuse a hand-in of the Flutter app until its build check has passed (this repository's plugin)."
  :requires '(tools-handin)
  :init #'harness-client-check--init
  :shutdown #'harness-client-check--shutdown)

(provide 'harness-client-check)
;;; harness-client-check.el ends here
