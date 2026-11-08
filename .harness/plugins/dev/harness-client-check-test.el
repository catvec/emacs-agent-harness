;;; harness-client-check-test.el --- Tests for the app's build check at hand-in  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tasks had handed in a Flutter app that did not compile, whose tests
;; failed, or whose release build died over the build a person already
;; had.  This repository's plugin (.harness/plugins/dev/harness-client-
;; check.el) refuses a task that changed the app, when it hands in,
;; unless the build check (harness_client/tool/check_build.sh) left a
;; stamp for the app as the branch has it.  It does so through the
;; filter `task/before-hand-in', which the harness's `hand_in' offers
;; any project (harness-tools-handin-test.el tests the filter).  These
;; tests make a repository with the app in it, a branch of work, and
;; the stamp the check would leave, and ask the plugin -- alone, then
;; through the tool -- what it says, and of which sessions.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)
(defvar harness-client-check--paths)
(defvar harness-client-check--stamp)
(declare-function harness-client-check--refusal "harness-client-check")
(declare-function harness-client-check--in-scope-p "harness-client-check")
(declare-function harness-client-check--before-hand-in "harness-client-check")

;;;; A repository with the app in it

(defun harness-client-check-test--git (dir &rest args)
  "Run git ARGS in DIR; signal on failure, return its output without the newline."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %S failed: %s" args (buffer-string)))
      (string-trim-right (buffer-string)))))

(defun harness-client-check-test--write (dir file text)
  "Write TEXT to FILE, relative to DIR."
  (let ((path (expand-file-name file dir)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert text))))

(defun harness-client-check-test--commit (dir message &rest files)
  "Write FILES, alternating a name and its text, in DIR and commit them as MESSAGE.
Return the new commit."
  (cl-loop for (name text) on files by #'cddr
           do (harness-client-check-test--write dir name text))
  (harness-client-check-test--git dir "add" "-A")
  (harness-client-check-test--git dir "commit" "-q" "-m" message)
  (harness-client-check-test--git dir "rev-parse" "HEAD"))

(defun harness-client-check-test--repo ()
  "Make a repository with the app on `main' and the branch `task/x' out; return its root."
  (let ((root (file-name-as-directory (expand-file-name "repo" (harness-test-temp-dir)))))
    (make-directory root t)
    (harness-client-check-test--git root "init" "-q" "-b" "main")
    (harness-client-check-test--git root "config" "user.name" "Harness Test")
    (harness-client-check-test--git root "config" "user.email" "test@example.invalid")
    (harness-client-check-test--git root "config" "commit.gpgsign" "false")
    (harness-client-check-test--commit
     root "base"
     ".gitignore" "scripts/.dev/\n"
     "notes.txt" "notes\n"
     "harness_client/README.md" "the app\n"
     "harness_client/pubspec.yaml" "name: app\n"
     "harness_client/pubspec.lock" "packages: {}\n"
     "harness_client/lib/main.dart" "void main() {}\n"
     "harness_client/test/main_test.dart" "void main() {}\n"
     "harness_client/android/gradle.properties" "kotlin.incremental=false\n"
     "harness_client/tool/check_build.sh" "#!/bin/sh\n")
    (harness-client-check-test--git root "checkout" "-q" "-b" "task/x")
    root))

(defun harness-client-check-test--stamp (root head &optional result)
  "Leave in ROOT the stamp the build check leaves for the commit HEAD."
  (harness-client-check-test--write
   root harness-client-check--stamp
   (format "{\n  \"format\": 1,\n  \"result\": \"%s\",\n  \"head\": \"%s\"\n}\n"
           (or result "pass") head)))

(defun harness-client-check-test--refusal (root &optional base)
  "Return what the plugin says about the task in ROOT, whose base is BASE (`main')."
  (harness-test-await
   (harness-client-check--refusal (list :id "t1" :worktree root :base (or base "main")))))

(defvar harness-client-check-test--plugins '(tools-dev client-check)
  "The plugin modules `plugins/of-session' answers with: those of this repository.")

(defmacro harness-client-check-test-with (&rest body)
  "Load hand_in and the plugin's module and run BODY, as a session of this repository."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tools-handin
                        client-check))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (harness-register-method 'plugins/of-session
                              (lambda (_id) harness-client-check-test--plugins))
     (let ((harness-provider-demo--delay 0.005)
           (harness-client-check-test--plugins '(tools-dev client-check))
           (default-directory dir))
       ,@body)))

;;;; What the plugin says of the app

(ert-deftest harness-client-check-asks-nothing-of-work-outside-the-app ()
  "A branch that changed notes, the app's README and its tools is not held to the check."
  (harness-client-check-test-with
    (let ((root (harness-client-check-test--repo)))
      (harness-client-check-test--commit
       root "notes" "notes.txt" "more\n" "harness_client/README.md" "the app, said again\n"
       "harness_client/tool/check_build.sh" "#!/bin/sh\n# changed\n")
      (should-not (harness-client-check-test--refusal root)))))

(ert-deftest harness-client-check-refuses-an-app-change-with-no-check ()
  "A change to lib/ with no stamp is refused, with the file, the reason and the command."
  (harness-client-check-test-with
    (let ((root (harness-client-check-test--repo)))
      (harness-client-check-test--commit root "ui" "harness_client/lib/main.dart" "void main() { }\n")
      (let ((refusal (harness-client-check-test--refusal root)))
        (should (stringp refusal))
        (should (string-prefix-p "hand_in: this task changed the Flutter app" refusal))
        (should (string-match-p "harness_client/lib/main\\.dart" refusal))
        (should (string-match-p "there is no stamp (scripts/\\.dev/client-check/stamp\\.json)" refusal))
        (should (string-match-p "harness_client/tool/check_build\\.sh" refusal))
        (should (string-match-p "cannot_continue" refusal))))))

(ert-deftest harness-client-check-explains-the-licences-and-asks-for-them-only-where-needed ()
  "The licence flag is for a sandbox with no Android SDK, and says what it accepts."
  (harness-client-check-test-with
    (let ((root (harness-client-check-test--repo)))
      (harness-client-check-test--commit root "ui" "harness_client/lib/main.dart" "void main() { }\n")
      (let ((refusal (harness-client-check-test--refusal root)))
        (should (string-match-p "Where no Android SDK is installed" refusal))
        (should (string-match-p "--accept-android-licenses" refusal))
        (should (string-match-p "licences of that SDK only" refusal))
        ;; The command itself is named without it.
        (should (string-match-p "^  harness_client/tool/check_build\\.sh$" refusal))))))

(ert-deftest harness-client-check-accepts-a-stamp-for-the-app-as-it-is ()
  "A passing stamp for HEAD, or for an earlier commit with the app unchanged since, counts."
  (harness-client-check-test-with
    (let* ((root (harness-client-check-test--repo))
           (head (harness-client-check-test--commit
                  root "ui" "harness_client/lib/main.dart" "void main() { }\n")))
      (harness-client-check-test--stamp root head)
      (should-not (harness-client-check-test--refusal root))
      ;; Notes, evidence and the app's tools, committed after the check.
      (harness-client-check-test--commit
       root "evidence" "harness_client/verification/build.txt" "built\n" "notes.txt" "x\n"
       "harness_client/tool/check_build.sh" "#!/bin/sh\n# edited\n")
      (should-not (harness-client-check-test--refusal root)))))

(ert-deftest harness-client-check-refuses-an-app-changed-after-the-check ()
  "A stamp for an earlier commit does not cover a later change to the app."
  (harness-client-check-test-with
    (let* ((root (harness-client-check-test--repo))
           (head (harness-client-check-test--commit
                  root "ui" "harness_client/lib/main.dart" "void main() { }\n")))
      (harness-client-check-test--stamp root head)
      (harness-client-check-test--commit
       root "more ui" "harness_client/lib/other.dart" "int x = 1;\n"
       "harness_client/pubspec.lock" "packages: {a: 1}\n")
      (let ((refusal (harness-client-check-test--refusal root)))
        (should (stringp refusal))
        (should (string-match-p
                 (format "the app changed after the check passed for %s: " (substring head 0 12))
                 refusal))
        (should (string-match-p "harness_client/lib/other\\.dart" refusal))
        (should (string-match-p "harness_client/pubspec\\.lock" refusal))))))

(ert-deftest harness-client-check-refuses-changes-that-are-not-committed ()
  "What is not committed is not in the commit the check was made for."
  (harness-client-check-test-with
    (let* ((root (harness-client-check-test--repo))
           (head (harness-client-check-test--commit
                  root "ui" "harness_client/lib/main.dart" "void main() { }\n")))
      (harness-client-check-test--stamp root head)
      (should-not (harness-client-check-test--refusal root))
      ;; An edit, and a new file the branch does not have yet.
      (harness-client-check-test--write root "harness_client/lib/main.dart" "void main() {}\n")
      (harness-client-check-test--write root "harness_client/lib/new.dart" "int y = 2;\n")
      (let ((refusal (harness-client-check-test--refusal root)))
        (should (string-match-p "the app has changes that are not committed: " refusal))
        (should (string-match-p "harness_client/lib/main\\.dart" refusal))
        (should (string-match-p "harness_client/lib/new\\.dart" refusal))))))

(ert-deftest harness-client-check-wants-a-stamp-that-says-pass ()
  "A stamp that says anything else, names no commit or cannot be read is no stamp."
  (harness-client-check-test-with
    (let* ((root (harness-client-check-test--repo))
           (head (harness-client-check-test--commit
                  root "ui" "harness_client/lib/main.dart" "void main() { }\n")))
      (harness-client-check-test--stamp root head "fail")
      (should (string-match-p "the stamp says \"fail\", not \"pass\""
                              (harness-client-check-test--refusal root)))
      (harness-client-check-test--write root harness-client-check--stamp "{\"result\": \"pass\"}\n")
      (should (string-match-p "the stamp names no commit" (harness-client-check-test--refusal root)))
      (harness-client-check-test--write root harness-client-check--stamp "not json at all")
      (should (string-match-p "there is no stamp" (harness-client-check-test--refusal root)))
      ;; A commit this repository does not have, as another checkout's stamp names.
      (harness-client-check-test--stamp root (make-string 40 ?a))
      (should (string-match-p "which is not in the history of this branch"
                              (harness-client-check-test--refusal root))))))

(ert-deftest harness-client-check-needs-a-stamp-in-the-history-of-the-branch ()
  "A stamp for a commit of another branch does not cover this one."
  (harness-client-check-test-with
    (let ((root (harness-client-check-test--repo)))
      (harness-client-check-test--git root "checkout" "-q" "-b" "other")
      (let ((other (harness-client-check-test--commit
                    root "other ui" "harness_client/lib/main.dart" "void main() { other(); }\n")))
        (harness-client-check-test--git root "checkout" "-q" "task/x")
        (harness-client-check-test--commit root "ui" "harness_client/lib/main.dart" "void main() { }\n")
        (harness-client-check-test--stamp root other)
        (should (string-match-p "which is not in the history of this branch"
                                (harness-client-check-test--refusal root)))))))

(ert-deftest harness-client-check-measures-from-where-the-branch-started ()
  "The base moving on, with app changes of its own, does not make the branch's work the app's."
  (harness-client-check-test-with
    (let ((root (harness-client-check-test--repo)))
      (harness-client-check-test--commit root "notes" "notes.txt" "branch notes\n")
      (harness-client-check-test--git root "checkout" "-q" "main")
      (harness-client-check-test--commit root "main moves" "harness_client/lib/main.dart" "void main() { m(); }\n")
      (harness-client-check-test--git root "checkout" "-q" "task/x")
      (should-not (harness-client-check-test--refusal root)))))

(ert-deftest harness-client-check-asks-nothing-it-cannot-tell ()
  "No worktree, no base, a base the repository lacks, a remote directory or no paths: no gate."
  (harness-client-check-test-with
    (let ((root (harness-client-check-test--repo)))
      (harness-client-check-test--commit root "ui" "harness_client/lib/main.dart" "void main() { }\n")
      (should (stringp (harness-client-check-test--refusal root)))
      (should-not (harness-client-check-test--refusal root "no-such-branch"))
      (should-not (harness-test-await (harness-client-check--refusal (list :id "t" :base "main"))))
      (should-not (harness-test-await (harness-client-check--refusal (list :id "t" :worktree root))))
      (should-not (harness-test-await
                   (harness-client-check--refusal
                    (list :id "t" :base "main" :worktree "/ssh:nowhere.invalid:/srv/repo/"))))
      (should-not (harness-test-await
                   (harness-client-check--refusal
                    (list :id "t" :base "main" :worktree (expand-file-name "gone" root)))))
      (let ((harness-client-check--paths nil))
        (should-not (harness-client-check-test--refusal root)))
      ;; A directory that is no repository at all.
      (should-not (harness-client-check-test--refusal (harness-test-temp-dir))))))

(ert-deftest harness-client-check-paths-are-the-ones-the-check-reads ()
  "The paths here are the `inputs' of check_build.sh, which builds exactly those."
  (let* ((script (expand-file-name "harness_client/tool/check_build.sh" harness-test-root))
         (text (with-temp-buffer (insert-file-contents script) (buffer-string))))
    (should (string-match "^inputs=(\\(.*\\))$" text))
    (let ((inputs (mapcar (lambda (name) (concat "harness_client/" name))
                          (split-string (match-string 1 text)))))
      (require 'harness-client-check)
      (should (equal (sort (copy-sequence inputs) #'string<)
                     (sort (copy-sequence harness-client-check--paths) #'string<))))))

;;;; Whose sessions

(ert-deftest harness-client-check-asks-the-sessions-that-name-the-module-only ()
  "A session is asked when its plugin modules name this module, and not otherwise."
  (harness-client-check-test-with
    (let ((session (list :id "s1")))
      (dolist (plugins '((client-check) (tools-dev client-check) (other client-check)))
        (let ((harness-client-check-test--plugins plugins))
          (should (harness-client-check--in-scope-p session))))
      ;; The dev plugin's other module does not put a session in scope: a project
      ;; names the check it wants.
      (dolist (plugins '(nil (other) (tools-dev) (deploy other)))
        (let ((harness-client-check-test--plugins plugins))
          (should-not (harness-client-check--in-scope-p session))))
      ;; No session id, no plugins module, a plugins module that fails.
      (should-not (harness-client-check--in-scope-p (list :cwd "/tmp/")))
      (harness-register-method 'plugins/of-session (lambda (_id) (error "No plugins today")))
      (should-not (harness-client-check--in-scope-p session)))
    (harness-unregister-method 'plugins/of-session)
    (should-not (harness-client-check--in-scope-p (list :id "s1")))))

(ert-deftest harness-client-check-leaves-other-projects-sessions-alone ()
  "The filter hands on, unchanged, for a session that does not use the plugin."
  (harness-client-check-test-with
    (let ((root (harness-client-check-test--repo)))
      (harness-client-check-test--commit root "ui" "harness_client/lib/main.dart" "void main() { }\n")
      (let ((task (list :id "t1" :worktree root :base "main"))
            (harness-client-check-test--plugins '(deploy)))
        (should-not (harness-test-await
                     (harness-client-check--before-hand-in nil #'ignore task (list :id "s1"))))
        (should (equal "earlier"
                       (harness-test-await
                        (harness-client-check--before-hand-in "earlier" #'ignore task (list :id "s1")))))
        (let ((harness-client-check-test--plugins '(tools-dev)))
          (should-not (harness-test-await
                       (harness-client-check--before-hand-in nil #'ignore task (list :id "s1")))))
        (let ((harness-client-check-test--plugins '(tools-dev client-check)))
          (should (string-prefix-p "hand_in: this task changed the Flutter app"
                                   (harness-test-await
                                    (harness-client-check--before-hand-in nil #'ignore task
                                                                          (list :id "s1"))))))))))

(ert-deftest harness-client-check-adds-its-text-to-an-earlier-refusal ()
  "A refusal that an earlier function made stays, and the app's follows a blank line."
  (harness-client-check-test-with
    (let ((root (harness-client-check-test--repo)))
      (harness-client-check-test--commit root "ui" "harness_client/lib/main.dart" "void main() { }\n")
      (let* ((task (list :id "t1" :worktree root :base "main"))
             (text (harness-test-await
                    (harness-client-check--before-hand-in "Run the linter first." #'ignore task
                                                          (list :id "s1")))))
        (should (string-prefix-p "Run the linter first.\n\nhand_in: this task changed the Flutter app" text))))))

(ert-deftest harness-client-check-module-adds-and-removes-its-function ()
  "Starting the module puts the function in the filter, and stopping it takes it out."
  (harness-client-check-test-with
    (should (harness-module-plugin-p 'client-check))
    (should (harness-module-ready-p 'client-check))
    (should (memq 'task/before-hand-in (harness-filters)))
    (should (cl-find #'harness-client-check--before-hand-in
                     (gethash 'task/before-hand-in harness--filters) :key #'cdr))
    (harness-module-disable 'client-check)
    (should-not (cl-find #'harness-client-check--before-hand-in
                         (gethash 'task/before-hand-in harness--filters) :key #'cdr))))

;;;; Through the tool

(defvar harness-client-check-test--task nil "The task `task/for-session' answers with.")
(defvar harness-client-check-test--handed-in nil "The reports `task/hand-in' got.")

(defun harness-client-check-test--hand-in (root &rest input)
  "Call hand_in with INPUT (a note as evidence, a problem and a summary) for a task in ROOT.
Return its result.  `harness-client-check-test--handed-in' holds the reports it recorded."
  (setq harness-client-check-test--task (list :id "t1" :worktree root :base "main")
        harness-client-check-test--handed-in nil)
  (harness-register-method 'task/for-session (lambda (_sid) harness-client-check-test--task))
  (harness-register-method 'task/hand-in
                           (lambda (id report)
                             (push (cons id report) harness-client-check-test--handed-in)
                             t))
  (let ((sid (plist-get (harness-call 'session/create :cwd root :model "demo:scripted") :id)))
    (harness-add-filter 'permission/decide
                        (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
    (harness-test-await
     (harness-call 'tools/execute sid
                   (list :id "h1" :name "hand_in"
                         :input (append input
                                        (list :problem "The app" :summary "# Done"
                                              :evidence '("the check passed"))))))))

(ert-deftest harness-client-check-tool-refuses-an-unbuilt-app-and-takes-it-once-built ()
  "hand_in says what to run, records nothing, and takes the same work once the check passed."
  (harness-client-check-test-with
    (let ((root (harness-client-check-test--repo)))
      (let ((head (harness-client-check-test--commit
                   root "ui" "harness_client/lib/main.dart" "void main() { }\n")))
        (let ((result (harness-client-check-test--hand-in root)))
          (should (plist-get result :is-error))
          (should-not (plist-get result :end-turn))
          (should (string-match-p "check_build\\.sh" (plist-get result :content)))
          (should-not harness-client-check-test--handed-in))
        (harness-client-check-test--stamp root head)
        (let ((result (harness-client-check-test--hand-in root)))
          (should-not (plist-get result :is-error))
          (should (plist-get result :end-turn))
          (should (= 1 (length harness-client-check-test--handed-in)))
          (should (equal "# Done" (plist-get (cdar harness-client-check-test--handed-in) :summary))))))))

(ert-deftest harness-client-check-tool-does-not-hold-a-task-that-cannot-continue ()
  "A task that cannot go on, or has nothing to merge, says so without the check."
  (harness-client-check-test-with
    (let ((root (harness-client-check-test--repo)))
      (harness-client-check-test--commit root "ui" "harness_client/lib/main.dart" "void main() { }\n")
      (let ((result (harness-client-check-test--hand-in root :cannot_continue t)))
        (should-not (plist-get result :is-error))
        (should (plist-get (cdar harness-client-check-test--handed-in) :cannot-continue)))
      (let ((result (harness-client-check-test--hand-in root :no_merge t)))
        (should-not (plist-get result :is-error))
        (should (plist-get (cdar harness-client-check-test--handed-in) :no-merge))))))

(ert-deftest harness-client-check-tool-takes-work-outside-the-app-as-before ()
  "A task that left the app alone hands in as it always did."
  (harness-client-check-test-with
    (let ((root (harness-client-check-test--repo)))
      (harness-client-check-test--commit root "notes" "notes.txt" "more\n")
      (let ((result (harness-client-check-test--hand-in root)))
        (should-not (plist-get result :is-error))
        (should (plist-get result :end-turn))
        (should (= 1 (length harness-client-check-test--handed-in)))))))

(ert-deftest harness-client-check-tool-asks-nothing-of-another-projects-task ()
  "A task of a project that does not use the plugin hands the app in unchecked."
  (harness-client-check-test-with
    (let ((root (harness-client-check-test--repo))
          (harness-client-check-test--plugins nil))
      (harness-client-check-test--commit root "ui" "harness_client/lib/main.dart" "void main() { }\n")
      (let ((result (harness-client-check-test--hand-in root)))
        (should-not (plist-get result :is-error))
        (should (plist-get result :end-turn))
        (should (= 1 (length harness-client-check-test--handed-in)))))))

(provide 'harness-client-check-test)
;;; harness-client-check-test.el ends here
