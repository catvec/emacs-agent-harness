;;; harness-config-test.el --- Tests for layered settings  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-model)
(defvar harness-permission-mode)
(defvar harness-thinking)
(defvar harness-log-level)
(defvar harness-acp--server-enabled)
(declare-function harness-acp-request "harness-acp")

(defcustom harness-config-test-api-key nil
  "A secret option for the tests."
  :type '(choice (const nil) string) :group 'harness)

(defun harness-config-test--project ()
  "Return (ROOT . SUB): a fresh git project and a directory inside it."
  (let* ((root (harness-test-temp-dir))
         (sub (file-name-as-directory (expand-file-name "sub" root))))
    (make-directory sub t)
    (let ((default-directory root)) (call-process "git" nil nil nil "init" "-q"))
    (cons root sub)))

(defun harness-config-test--write (dir alist)
  "Write ALIST as DIR's .dir-locals.el."
  (with-temp-file (expand-file-name ".dir-locals.el" dir)
    (let ((print-length nil)) (prin1 alist (current-buffer)))))

(defun harness-config-test--read (dir)
  "Return the alist in DIR's .dir-locals.el, or `none' without the file."
  (let ((file (expand-file-name ".dir-locals.el" dir)))
    (if (file-exists-p file)
        (with-temp-buffer (insert-file-contents file) (read (current-buffer)))
      'none)))

(defun harness-config-test--setting (description key)
  "Return the setting KEY (a string) of DESCRIPTION from `config/describe'."
  (cl-find key (plist-get description :settings) :key (lambda (s) (plist-get s :key)) :test #'equal))

(defmacro harness-config-test-with (&rest body)
  "Run BODY with the config module and a project bound to ROOT and SUB.
Global saves are recorded in SAVED as (SYMBOL . VALUE) instead of
reaching a custom file."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (harness-test-load-module 'project)
     (harness-test-load-module 'config)
     (let* ((project (harness-config-test--project))
            (root (car project))
            (sub (cdr project))
            (saved nil)
            (harness-model harness-model)
            (harness-permission-mode harness-permission-mode)
            (harness-thinking harness-thinking)
            (harness-config-test-api-key nil))
       (ignore root sub)
       (cl-letf (((symbol-function 'harness-save-user-option)
                  (lambda (symbol value) (set symbol value) (push (cons symbol value) saved))))
         (unwind-protect (progn ,@body)
           (ignore-errors (delete-directory root t)))))))

(ert-deftest harness-config-describe-reports-layers-and-sources ()
  (skip-unless (executable-find "git"))
  (harness-config-test-with
    (harness-config-test--write root '((nil . ((harness-permission-mode . yolo) (harness-thinking . nil)
                                               (harness-sandbox-policy . 5) (harness-budget . (:amount 5))))))
    (harness-config-test--write sub '((nil . ((harness-permission-mode . auto)))))
    (let* ((d (harness-call 'config/describe sub))
           (mode (harness-config-test--setting d "harness-permission-mode"))
           (thinking (harness-config-test--setting d "harness-thinking"))
           (model (harness-config-test--setting d "harness-model"))
           (policy (harness-config-test--setting d "harness-sandbox-policy"))
           (budget (harness-config-test--setting d "harness-budget")))
      ;; A value that does not fit its type is flagged by layer.
      (should (equal '("project") (plist-get policy :invalid)))
      (should (null (plist-get mode :invalid)))
      ;; The Budget is one budget for all sessions: a project's value is
      ;; not one of its layers.
      (should (eq :false (plist-get budget :layered)))
      (should (equal "global" (plist-get budget :source)))
      (should (null (plist-get budget :project)))
      (should (equal "spending" (plist-get budget :section)))
      (should (equal root (plist-get d :root)))
      (should (equal sub (plist-get d :cwd)))
      (should (eq t (plist-get d :in-project)))
      (should (eq t (plist-get (plist-get d :files) :project-exists)))
      ;; The settings of the sections come first, in their order, here
      ;; the layered ones and the Budget: no other module is loaded.
      ;; `harness-emacs-eval' too once lisp/harness-emacs-endpoint.el
      ;; is, as the UI client of another test loads it.
      ;; Those no module defines are not there: the supervisor's, until
      ;; its plugin is loaded.  One that two sections name is there once.
      (let ((placed (delete-dups (cl-loop for (_ . props) in harness-config-sections
                                          append (cl-remove-if-not #'boundp (plist-get props :keys))))))
        (should (equal (sort (copy-sequence placed) #'string<)
                       (sort (append (list 'harness-budget)
                                     (and (boundp 'harness-emacs-eval) (list 'harness-emacs-eval))
                                     (cl-remove-if-not #'boundp harness-config-keys)
                                     (cl-remove-if-not #'boundp '(harness-supervisor-tasks
                                                                  harness-supervisor-judge-model
                                                                  harness-supervisor-tiers
                                                                  harness-supervisor-step-budget)))
                             #'string<)))
        (should (equal (mapcar #'symbol-name placed)
                       (mapcar (lambda (s) (plist-get s :key))
                               (seq-take (plist-get d :settings) (length placed))))))
      ;; The directory layer wins over the project's; all values print.
      (should (equal "directory" (plist-get mode :source)))
      (should (equal "auto" (plist-get mode :value)))
      (should (equal "yolo" (plist-get mode :project)))
      (should (equal "auto" (plist-get mode :directory)))
      (should (equal (prin1-to-string harness-permission-mode) (plist-get mode :global)))
      (should (string-match-p "accept-edits" (plist-get mode :type)))
      (should (eq t (plist-get mode :layered)))
      ;; Set to nil in the project is not the same as unset.
      (should (equal "nil" (plist-get thinking :project)))
      (should (equal "project" (plist-get thinking :source)))
      (should (null (plist-get model :project)))
      (should (equal "global" (plist-get model :source)))
      (should (equal (prin1-to-string harness-model) (plist-get model :value))))))

(ert-deftest harness-config-describe-lists-global-options-and-hides-secrets ()
  (harness-config-test-with
    (setq harness-config-test-api-key "sk-very-secret")
    (let* ((d (harness-call 'config/describe sub))
           (keys (mapcar (lambda (s) (plist-get s :key)) (plist-get d :settings)))
           (level (harness-config-test--setting d "harness-log-level"))
           (secret (harness-config-test--setting d "harness-config-test-api-key")))
      ;; Options of the `harness' group with a global value only.
      (should level)
      (should (eq :false (plist-get level :layered)))
      (should (equal "core" (plist-get level :module)))
      (should (member "core" (mapcar (lambda (m) (plist-get m :name)) (plist-get d :modules))))
      ;; What decides how the harness starts or talks to the UI is left out.
      (dolist (hidden '("harness-process" "harness-state-directory" "harness-module-directories"
                        "harness-extra-module-directories" "harness-auto-reload-mode"))
        (should-not (member hidden keys)))
      (should-not (cl-some (lambda (k) (string-prefix-p "harness-acp-" k)) keys))
      ;; A secret says whether it is set, never what it is.
      (should (eq t (plist-get secret :secret)))
      (should (eq t (plist-get secret :has-value)))
      (should-not (string-search "sk-very-secret" (prin1-to-string d))))))

(ert-deftest harness-config-set-takes-names-and-printed-values ()
  (skip-unless (executable-find "git"))
  (harness-config-test-with
    (let (events)
      (harness-on 'config/changed (lambda (&rest args) (push args events)))
      (should (equal (cons 'project (expand-file-name ".dir-locals.el" root))
                     (harness-call 'config/set "harness-permission-mode" "yolo" :printed t
                                   :scope 'project :cwd sub)))
      (should (equal '((nil . ((harness-permission-mode . yolo)))) (harness-config-test--read root)))
      (should (eq 'yolo (harness-call 'config/get "harness-permission-mode" sub)))
      (should (equal (list 'harness-permission-mode 'yolo 'project sub) (car events)))
      ;; A printed list keeps its shape; a printed nil is nil, not "nil".
      (harness-call 'config/set 'harness-allowed-directories "(\"/a/\" \"/b/\")" :printed t :scope 'project :cwd sub)
      (harness-call 'config/set 'harness-thinking "nil" :printed t :scope 'project :cwd sub)
      (should (equal '("/a/" "/b/") (harness-call 'config/get 'harness-allowed-directories sub)))
      (should (null (harness-call 'config/get 'harness-thinking sub)))
      (should (assq 'harness-thinking (cdr (assq nil (harness-config-test--read root)))))
      ;; Globally, any listed option; without a scope a global-only one is global.
      (harness-call 'config/set 'harness-log-level "debug" :printed t :cwd sub)
      (should (equal '(harness-log-level . debug) (car saved)))
      ;; No backup files are left next to the user's settings.
      (should (equal '(".dir-locals.el") (directory-files root nil "dir-locals"))))))

(ert-deftest harness-config-set-refuses-what-does-not-fit ()
  (harness-config-test-with
    (dolist (call `((harness-permission-mode bogus :scope project)
                    (harness-model 42 :scope global)
                    (harness-budget 12 :scope project)
                    (harness-log-level debug :scope project)
                    (harness-config-test-api-key "sk" :scope project)
                    (harness-model "x" :scope nowhere)
                    (not-a-harness-option 1 :scope global)
                    (harness-process nil :scope global)))
      (should-error (apply #'harness-call 'config/set (car call) (cadr call) :cwd sub (cddr call))))
    (should-error (harness-call 'config/set 'harness-model "(unclosed" :printed t :scope 'global))
    (should-error (harness-call 'config/set 'harness-model "\"a\" \"b\"" :printed t :scope 'global))
    (should (eq 'none (harness-config-test--read root)))
    (should-not saved)))

(ert-deftest harness-config-corporate-mode-is-set-in-the-init-file-only ()
  "The settings page never lists `harness-corporate-mode', and neither
`config/set' nor `config/unset' changes it, here or over ACP."
  (harness-config-test-with
    (let ((keys (mapcar (lambda (s) (plist-get s :key))
                        (plist-get (harness-call 'config/describe sub) :settings))))
      (should-not (member "harness-corporate-mode" keys)))
    (dolist (key '(harness-corporate-mode "harness-corporate-mode"))
      (dolist (call (list (lambda () (harness-call 'config/set key t :cwd sub))
                          (lambda () (harness-call 'config/set key "t" :printed t :scope 'global :cwd sub))
                          (lambda () (harness-call 'config/unset key :cwd sub))))
        (let ((message (error-message-string (should-error (funcall call)))))
          (should (equal "harness-corporate-mode is set in the init file only" message)))))
    ;; Over ACP too.
    (let* ((conn (harness-test-connect-ui-client))
           (err (should-error
                 (harness-test-await
                  (harness-acp-request conn "_harness/config/set"
                                       (list :key "harness-corporate-mode" :value "t"
                                             :printed t :scope "global" :cwd sub))))))
      (should (string-search "set in the init file only" (format "%S" err))))
    (should-not harness-corporate-mode)
    (should-not saved)))

(ert-deftest harness-config-unset-removes-the-entry-then-the-file ()
  (skip-unless (executable-find "git"))
  (harness-config-test-with
    (let (events)
      (harness-on 'config/changed (lambda (&rest args) (push args events)))
      (harness-call 'config/set 'harness-permission-mode 'yolo :scope 'project :cwd sub)
      (harness-call 'config/set 'harness-thinking "high" :scope 'project :cwd sub)
      (should (equal (cons 'project (expand-file-name ".dir-locals.el" root))
                     (harness-call 'config/unset "harness-permission-mode" :scope 'project :cwd sub)))
      (should (equal '((nil . ((harness-thinking . "high")))) (harness-config-test--read root)))
      ;; The event carries the value in effect now: the global one.
      (should (equal (list 'harness-permission-mode harness-permission-mode 'project sub) (car events)))
      (should (eq harness-permission-mode (harness-call 'config/get 'harness-permission-mode sub)))
      ;; The last entry takes the file with it.
      (harness-call 'config/unset 'harness-thinking :cwd sub)
      (should (eq 'none (harness-config-test--read root)))
      (should-not (directory-files root nil "dir-locals"))
      ;; Nothing to remove is not an error.
      (should (equal '(project) (harness-call 'config/unset 'harness-thinking :scope 'project :cwd sub))))))

(ert-deftest harness-config-unset-keeps-other-modes ()
  (skip-unless (executable-find "git"))
  (harness-config-test-with
    (harness-config-test--write root '((nil . ((harness-model . "demo:x")))
                                       (python-mode . ((fill-column . 79)))))
    (harness-call 'config/unset 'harness-model :scope 'project :cwd sub)
    (should (equal '((python-mode . ((fill-column . 79)))) (harness-config-test--read root)))
    ;; The directory layer is removed from its own file.
    (harness-config-test--write sub '((nil . ((harness-model . "demo:notes")))))
    (should (equal "demo:notes" (harness-call 'config/get 'harness-model sub)))
    (harness-call 'config/unset 'harness-model :scope 'directory :cwd sub)
    (should (eq 'none (harness-config-test--read sub)))
    (should (equal harness-model (harness-call 'config/get 'harness-model sub)))))

(ert-deftest harness-config-unset-global-restores-the-default ()
  (harness-config-test-with
    (let ((harness-log-level 'debug)
          (standard (eval (car (get 'harness-log-level 'standard-value)) t))
          events)
      (harness-on 'config/changed (lambda (&rest args) (push args events)))
      (should (equal '(global) (harness-call 'config/unset "harness-log-level" :cwd sub)))
      (should (equal (cons 'harness-log-level standard) (car saved)))
      (should (eq standard harness-log-level))
      (should (equal (list 'harness-log-level standard 'global sub) (car events)))
      ;; Layered settings cannot be removed from a scope they never had.
      (should-error (harness-call 'config/unset 'harness-log-level :scope 'project :cwd sub)))))

(ert-deftest harness-config-changed-never-carries-a-secret ()
  (harness-config-test-with
    (let (events)
      (harness-on 'config/changed (lambda (&rest args) (push args events)))
      (harness-call 'config/set 'harness-config-test-api-key "sk-secret" :cwd sub)
      (should (equal "sk-secret" harness-config-test-api-key))
      (should (equal (list 'harness-config-test-api-key nil 'global sub) (car events))))))

(defvar harness-tasks-model)
(defvar harness-tasks-non-interactive)
(defvar harness-non-interactive)

(ert-deftest harness-config-overrides-names-what-wins-over-the-global-value ()
  "`config/overrides' names the .dir-locals.el files of the places work
goes on, at the project and the directory layer, that set the key to
another value, and the task default that wins over it for tasks.  A
finished task's directory, a remote one and a missing one are not
looked at, and nothing is written."
  (skip-unless (executable-find "git"))
  (harness-config-test-with
    (let* ((other (harness-config-test--project))
           (finished (harness-config-test--project))
           (board (harness-config-test--project))
           (gone (expand-file-name "gone/" (harness-test-temp-dir)))
           (dirs (list root sub (car other) (cdr other) (car finished) (car board)))
           (before nil)
           (summary (lambda (found)
                      (mapcar (lambda (f) (list (plist-get f :file) (plist-get f :scope)
                                                (plist-get f :dir) (plist-get f :value)))
                              (plist-get found :files)))))
      (harness-config-test--write root '((nil . ((harness-model . "claude:opus")))))
      (harness-config-test--write sub '((nil . ((harness-model . "claude:sonnet")))))
      ;; The new value already: nothing to say.
      (harness-config-test--write (car other) '((nil . ((harness-model . "demo:scripted")))))
      (harness-config-test--write (cdr other) '((nil . ((harness-thinking . "high")
                                                        (harness-non-interactive . nil)))))
      (harness-config-test--write (car finished) '((nil . ((harness-model . "claude:haiku")))))
      (harness-config-test--write (car board) '((nil . ((harness-model . "claude:board")))))
      (setq before (mapcar #'harness-config-test--read dirs))
      (harness-register-method 'session/select
        (lambda (&optional _filter)
          (list (list :id "a" :cwd sub) (list :id "b" :cwd "/ssh:box:/srv/"))))
      (harness-register-method 'task/list
        (lambda (&rest _)
          (list (list :id "t1" :column 'pending :cwd (cdr other))
                (list :id "t2" :column 'done :cwd (car finished))
                (list :id "t3" :column 'active :cwd gone))))
      (let ((harness-tasks-model nil))
        (let ((found (harness-call 'config/overrides "harness-model" :value "\"demo:scripted\""
                                   :printed t :dirs (list (car board)))))
          (should (equal "harness-model" (plist-get found :key)))
          (should (equal "\"demo:scripted\"" (plist-get found :value)))
          (should-not (plist-get found :tasks))
          (should (equal (list (list (expand-file-name ".dir-locals.el" root) "project" root "\"claude:opus\"")
                               (list (expand-file-name ".dir-locals.el" sub) "directory" sub "\"claude:sonnet\"")
                               (list (expand-file-name ".dir-locals.el" (car board)) "project" (car board)
                                     "\"claude:board\""))
                         (funcall summary found)))
          (should (equal (harness-call 'project/name root) (plist-get (car (plist-get found :files)) :project)))
          (should (equal (harness-call 'project/name root) (plist-get (cadr (plist-get found :files)) :project))))
        ;; Without a value, the global one is compared.
        (let ((harness-model "claude:sonnet"))
          (should (equal (list (list (expand-file-name ".dir-locals.el" root) "project" root "\"claude:opus\"")
                               (list (expand-file-name ".dir-locals.el" (car other)) "project" (car other)
                                     "\"demo:scripted\""))
                         (funcall summary (harness-call 'config/overrides 'harness-model))))))
      ;; The task default is named when it is set to something else.
      (let ((harness-tasks-model "claude:tasks"))
        (should (equal '(:option "harness-tasks-model" :value "\"claude:tasks\"")
                       (plist-get (harness-call 'config/overrides "harness-model" :value "\"demo:scripted\""
                                                :printed t)
                                  :tasks)))
        (should-not (plist-get (harness-call 'config/overrides "harness-model" :value "claude:tasks") :tasks)))
      ;; Non-interactive compares as a boolean.
      (let ((harness-tasks-non-interactive t))
        (let ((found (harness-call 'config/overrides "harness-non-interactive" :value "nil" :printed t)))
          (should (equal '(:option "harness-tasks-non-interactive" :value "t") (plist-get found :tasks)))
          (should-not (plist-get found :files)))
        (let ((found (harness-call 'config/overrides "harness-non-interactive" :value t)))
          (should-not (plist-get found :tasks))
          (should (equal (list (list (expand-file-name ".dir-locals.el" (cdr other)) "directory" (cdr other) "nil"))
                         (funcall summary found)))))
      ;; Only layered settings have overrides; nothing was written.
      (should-error (harness-call 'config/overrides "harness-log-level"))
      (should (equal before (mapcar #'harness-config-test--read dirs)))
      (should-not saved))))

(ert-deftest harness-config-overrides-names-a-worktree-copy-as-its-project-file ()
  "A task's worktree carries its project's checked-in .dir-locals.el:
`config/overrides' names the project's file, the one to change, and
the project, once for all the tasks.  A worktree whose file says
something else, a task's edit, is named itself."
  (skip-unless (executable-find "git"))
  (harness-config-test-with
    (let* ((git (lambda (dir &rest args)
                  (let ((default-directory dir))
                    (should (eq 0 (apply #'call-process "git" nil nil nil
                                         "-c" "user.name=t" "-c" "user.email=t@example.invalid"
                                         "-c" "commit.gpgsign=false" "-c" "core.hooksPath=/dev/null"
                                         args))))))
           (worktree (lambda (name)
                       (let ((wt (expand-file-name (concat ".worktrees/" name "/") root)))
                         (funcall git root "worktree" "add" "-q" "--detach" wt)
                         wt)))
           (wt1 nil) (wt2 nil) (wt3 nil))
      (harness-config-test--write root '((nil . ((harness-model . "claude:opus")))))
      (harness-config-test--write sub '((nil . ((harness-model . "claude:sonnet")))))
      (funcall git root "add" "-f" ".dir-locals.el" "sub/.dir-locals.el")
      (funcall git root "commit" "-q" "--no-verify" "-m" "init")
      (setq wt1 (funcall worktree "one") wt2 (funcall worktree "two") wt3 (funcall worktree "three"))
      (should (equal '((nil . ((harness-model . "claude:sonnet"))))
                     (harness-config-test--read (expand-file-name "sub" wt2))))
      (harness-config-test--write (expand-file-name "sub" wt3) '((nil . ((harness-model . "claude:haiku")))))
      (harness-register-method 'session/select
        (lambda (&optional _filter)
          (mapcar (lambda (cwd) (list :id cwd :cwd cwd))
                  (list wt1 (expand-file-name "sub/" wt1) (expand-file-name "sub/" wt2)
                        (expand-file-name "sub/" wt3)))))
      (harness-register-method 'task/list (lambda (&rest _) nil))
      (let* ((harness-tasks-model nil)
             (found (plist-get (harness-call 'config/overrides "harness-model"
                                             :value "\"demo:scripted\"" :printed t)
                               :files)))
        (should (equal (list (list (file-truename (expand-file-name ".dir-locals.el" root)) "project"
                                   (harness-call 'project/name root) "\"claude:opus\"")
                             (list (file-truename (expand-file-name ".dir-locals.el" sub)) "directory"
                                   (harness-call 'project/name root) "\"claude:sonnet\"")
                             (list (file-truename (expand-file-name "sub/.dir-locals.el" wt3)) "directory"
                                   "three" "\"claude:haiku\""))
                       (mapcar (lambda (f) (list (file-truename (plist-get f :file)) (plist-get f :scope)
                                                 (plist-get f :project) (plist-get f :value)))
                               found)))
        (dolist (f found)
          (should (equal (file-name-directory (plist-get f :file)) (plist-get f :dir))))))))

(ert-deftest harness-config-describe-puts-common-settings-in-sections ()
  ;; A library both sides load, as `harness-start' does.
  (require 'harness-emacs-endpoint)
  (harness-config-test-with
    (let* ((d (harness-call 'config/describe sub))
           (settings (plist-get d :settings))
           (section (lambda (key) (plist-get (harness-config-test--setting d key) :section))))
      ;; Sections with settings, in order; one whose module is not loaded is left out.
      (should (equal '("sessions" "spending" "safety")
                     (mapcar (lambda (s) (plist-get s :name)) (plist-get d :sections))))
      (should (equal "New sessions" (plist-get (car (plist-get d :sections)) :title)))
      (should (string-match-p "dir-locals" (plist-get (car (plist-get d :sections)) :doc)))
      (should (equal "sessions" (funcall section "harness-model")))
      (should (equal "spending" (funcall section "harness-budget")))
      (should (equal "safety" (funcall section "harness-sandbox-policy")))
      ;; Letting agents evaluate in the user's Emacs is a safety matter.
      (should (equal "safety" (funcall section "harness-emacs-eval")))
      ;; The tasks module is not loaded, so its settings and section are absent.
      (should (null (funcall section "harness-tasks-model")))
      ;; Everything else is advanced: no section, after every sectioned one.
      (should (null (funcall section "harness-log-level")))
      (should (null (funcall section "harness-config-test-api-key")))
      (let ((first-advanced (cl-position-if-not (lambda (s) (plist-get s :section)) settings)))
        (should first-advanced)
        (should-not (cl-some (lambda (s) (plist-get s :section)) (nthcdr first-advanced settings))))
      ;; Internal constants are no settings at all.
      (should-not (cl-some (lambda (s) (string-search "--" (plist-get s :key))) settings)))))

(ert-deftest harness-config-leaves-out-what-no-module-defines ()
  "The supervisor's layered keys and its section's options name nothing
before its plugin is loaded: the layers, the description and the methods
that take a key all leave them out, as they would without the keys."
  (skip-unless (executable-find "git"))
  (skip-unless (not (boundp 'harness-supervisor)))
  (harness-config-test-with
    (harness-config-test--write root '((nil . ((harness-supervisor . t) (harness-permission-mode . yolo)))))
    (should (memq 'harness-supervisor harness-config-keys))
    (should (memq 'harness-supervisor-tasks harness-config-keys))
    (let ((layers (harness-call 'config/layers sub)))
      (dolist (layer '(policy global project directory))
        (should-not (plist-member (cdr (assq layer layers)) 'harness-supervisor))
        (should-not (plist-member (cdr (assq layer layers)) 'harness-supervisor-tasks)))
      ;; The others are there, global lists every key that is defined.
      (should (eq 'yolo (plist-get (cdr (assq 'project layers)) 'harness-permission-mode)))
      (should (equal (remq 'harness-supervisor-tasks (remq 'harness-supervisor harness-config-keys))
                     (cl-loop for (key _) on (cdr (assq 'global layers)) by #'cddr collect key))))
    (let* ((d (harness-call 'config/describe sub))
           (keys (mapcar (lambda (s) (plist-get s :key)) (plist-get d :settings))))
      (should (member "harness-permission-mode" keys))
      (should-not (cl-some (lambda (key) (string-prefix-p "harness-supervisor" key)) keys))
      (should-not (member "supervisor" (mapcar (lambda (s) (plist-get s :name)) (plist-get d :sections)))))
    ;; The keys are unknown, not variables with no value.
    (dolist (key '(harness-supervisor harness-supervisor-tasks))
      (dolist (call (list (lambda () (harness-call 'config/get key sub))
                          (lambda () (harness-call 'config/get (symbol-name key) sub))
                          (lambda () (harness-call 'config/set key t :scope 'project :cwd sub))
                          (lambda () (harness-call 'config/unset key :scope 'project :cwd sub))
                          (lambda () (harness-call 'config/overrides key))))
        (should (equal (format "Unknown config key %s" key)
                       (cadr (should-error (funcall call)))))))
    (should (equal '((nil . ((harness-supervisor . t) (harness-permission-mode . yolo))))
                   (harness-config-test--read root)))))

(ert-deftest harness-config-describes-the-supervisor-options-once-defined ()
  "Once a module defines them, `harness-supervisor' layers like the other
sessions' settings and shows once, in the first section that names it,
and the supervisor's section follows `sessions' with its own options."
  (skip-unless (executable-find "git"))
  (skip-unless (not (boundp 'harness-supervisor)))
  (harness-config-test-with
    (unwind-protect
        (progn
          ;; As the plugin defines them: a layered switch and a global option.
          (set 'harness-supervisor nil)
          (set 'harness-supervisor-tiers nil)
          (put 'harness-supervisor-tiers 'standard-value '(nil))
          (harness-config-test--write root '((nil . ((harness-supervisor . t)))))
          (let ((layers (harness-call 'config/layers sub)))
            (should (plist-member (cdr (assq 'global layers)) 'harness-supervisor))
            (should (null (plist-get (cdr (assq 'global layers)) 'harness-supervisor)))
            (should (eq t (plist-get (cdr (assq 'project layers)) 'harness-supervisor)))
            (should-not (plist-member (cdr (assq 'global layers)) 'harness-supervisor-tiers)))
          (should (eq t (harness-call 'config/get 'harness-supervisor sub)))
          (should (null (harness-call 'config/get 'harness-supervisor (harness-test-temp-dir))))
          (let* ((d (harness-call 'config/describe sub))
                 (settings (plist-get d :settings))
                 (keys (mapcar (lambda (s) (plist-get s :key)) settings))
                 (switch (harness-config-test--setting d "harness-supervisor"))
                 (tiers (harness-config-test--setting d "harness-supervisor-tiers")))
            ;; Once, in the first section, right after the setting it follows.
            (should (= 1 (cl-count "harness-supervisor" keys :test #'equal)))
            (should (equal "harness-non-interactive" (nth (1- (cl-position "harness-supervisor" keys :test #'equal)) keys)))
            (should (equal "sessions" (plist-get switch :section)))
            (should (eq t (plist-get switch :layered)))
            (should (equal "t" (plist-get switch :value)))
            (should (equal "project" (plist-get switch :source)))
            (should (equal "supervisor" (plist-get tiers :section)))
            (should (eq :false (plist-get tiers :layered)))
            ;; Its section comes after `sessions', with the title and text it was given.
            (let ((sections (plist-get d :sections)))
              (should (equal '("sessions" "supervisor" "spending" "safety")
                             (mapcar (lambda (s) (plist-get s :name)) sections)))
              (should (equal "Supervisor mode" (plist-get (cadr sections) :title)))
              (should (string-match-p "delegate" (plist-get (cadr sections) :doc)))))
          ;; It is set and unset like any layered setting.
          (should (equal (cons 'project (expand-file-name ".dir-locals.el" root))
                         (harness-call 'config/set 'harness-supervisor :false :scope 'project :cwd sub)))
          (should (eq :false (harness-call 'config/get 'harness-supervisor sub)))
          (harness-call 'config/unset 'harness-supervisor :scope 'project :cwd sub)
          (should (null (harness-call 'config/get 'harness-supervisor sub))))
      (makunbound 'harness-supervisor)
      (makunbound 'harness-supervisor-tiers)
      (put 'harness-supervisor-tiers 'standard-value nil))))

(ert-deftest harness-config-sections-name-real-options ()
  "Every option `harness-config-sections' names is a `defcustom' of the harness.
A misspelt name would quietly drop a setting from the settings page."
  (let ((defined nil))
    (dolist (dir '("lisp" "lisp/modules" "lisp/ui"))
      (dolist (file (directory-files (expand-file-name dir harness-test-root) t "\\.el\\'"))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (re-search-forward "^(defcustom \\(harness-[^ \n]+\\)" nil t)
            (push (intern (match-string 1)) defined)))))
    ;; The supervisor's options are defined by its plugin, a file of its
    ;; own; they name nothing before it is there.
    (let ((undefined-yet (unless (file-exists-p (expand-file-name "lisp/modules/harness-supervisor.el"
                                                                  harness-test-root))
                           '(harness-supervisor harness-supervisor-tasks harness-supervisor-tiers
                             harness-supervisor-step-budget))))
      (dolist (section harness-config-sections)
        (dolist (key (plist-get (cdr section) :keys))
          (unless (memq key undefined-yet)
            (should (memq key defined))))))
    ;; Every layered setting is shown in a section.
    (dolist (key harness-config-keys)
      (should (cl-some (lambda (section) (memq key (plist-get (cdr section) :keys)))
                       harness-config-sections)))))

(ert-deftest harness-config-model-options-name-models ()
  "Every option holding models says so in its type, with `:names'.
The settings page then offers the models the providers list, rather
than a text field, whose typo would go unnoticed.  Customize and the
widget library ignore the property."
  (require 'wid-edit)
  (let (found)
    (dolist (dir '("lisp" "lisp/modules" "lisp/ui"))
      (dolist (file (directory-files (expand-file-name dir harness-test-root) t "\\.el\\'"))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (re-search-forward "^(defcustom \\(harness\\(?:-[a-z-]+\\)?-models?\\)[ \n]" nil t)
            (goto-char (match-beginning 0))
            (let* ((form (read (current-buffer)))
                   (type (eval (plist-get (nthcdr 4 form) :type) t)))
              ;; A switch named after models, such as whether to list
              ;; them (`harness-deepseek-list-models'), holds none.
              (unless (eq type 'boolean)
                (push (nth 1 form) found)
                (should (memq :names (flatten-tree type)))
                ;; The type takes the option's value as before.
                (should (harness-test-fits-p type (eval (nth 2 form) t)))))))))
    (dolist (key '(harness-model harness-tasks-model harness-tasks-refine-model harness-tasks-recap-model
                   harness-tasks-search-model harness-perms-auto-model harness-fallback-models
                   harness-provider-copilot-default-model))
      (should (memq key found)))))

(ert-deftest harness-config-works-over-acp-with-json ()
  "A client whose wire is JSON describes, sets and unsets by name."
  (skip-unless (executable-find "git"))
  (harness-config-test-with
    (let* ((conn (harness-test-connect-ui-client))
           (json (lambda (obj) (harness-json-parse (harness-json-encode obj))))
           (call (lambda (method params)
                   (funcall json (harness-test-await
                                  (harness-acp-request conn method (funcall json params)))))))
      (let* ((d (funcall call "_harness/config/describe" (list :cwd sub)))
             (mode (harness-config-test--setting d "harness-permission-mode")))
        (should (eq t (plist-get mode :layered)))
        (should (equal (prin1-to-string harness-permission-mode) (plist-get mode :value))))
      (funcall call "_harness/config/set" (list :key "harness-permission-mode" :value "accept-edits"
                                                :printed t :scope "project" :cwd sub))
      (should (equal '((nil . ((harness-permission-mode . accept-edits))))
                     (harness-config-test--read root)))
      (let ((mode (harness-config-test--setting (funcall call "_harness/config/describe" (list :cwd sub))
                                                "harness-permission-mode")))
        (should (equal "project" (plist-get mode :source)))
        (should (equal "accept-edits" (plist-get mode :project))))
      (funcall call "_harness/config/unset" (list :key "harness-permission-mode" :scope "project" :cwd sub))
      (should (eq 'none (harness-config-test--read root))))))

;;;; A policy

(defvar harness-corporate-mode)

(ert-deftest harness-config-policy-wins-over-every-layer ()
  "A value the policy sets is the one in effect, whatever the project's
and the directory's .dir-locals.el say, and the page is told so."
  (skip-unless (executable-find "git"))
  (harness-config-test-with
    (harness-config-test--write root '((nil . ((harness-permission-mode . yolo)))))
    (harness-config-test--write sub '((nil . ((harness-permission-mode . auto)))))
    (should (eq 'auto (harness-call 'config/get 'harness-permission-mode sub)))
    (harness-test-with-policy '((harness-permission-mode . ask) (harness-corporate-mode . t)
                                (harness-config-test-api-key . "sk-managed"))
      (should (eq 'ask (harness-call 'config/get 'harness-permission-mode sub)))
      (should (eq 'ask (harness-call 'config/get "harness-permission-mode" root)))
      (let ((layers (harness-call 'config/layers sub)))
        (should (equal '(harness-permission-mode ask) (cdr (assq 'policy layers))))
        ;; The other layers still say what their files hold.
        (should (eq 'auto (plist-get (cdr (assq 'directory layers)) 'harness-permission-mode))))
      (let* ((d (harness-call 'config/describe sub))
             (mode (harness-config-test--setting d "harness-permission-mode"))
             (model (harness-config-test--setting d "harness-model"))
             (secret (harness-config-test--setting d "harness-config-test-api-key"))
             (policy (plist-get d :policy)))
        (should (eq t (plist-get mode :locked)))
        (should (equal "policy" (plist-get mode :source)))
        (should (equal "ask" (plist-get mode :value)))
        (should (eq :false (plist-get mode :editable)))
        (should (equal "auto" (plist-get mode :directory)))
        (should (eq :false (plist-get model :locked)))
        (should (eq t (plist-get model :editable)))
        ;; A secret the policy sets is locked, and still never shown.
        (should (eq t (plist-get secret :locked)))
        (should (eq :false (plist-get secret :editable)))
        (should (eq t (plist-get secret :has-value)))
        (should-not (string-search "sk-managed" (prin1-to-string d)))
        ;; The policy is described whole, corporate mode, hidden from the page, included.
        (should (equal policy-file (plist-get policy :file)))
        (should (equal '("harness-permission-mode" "harness-corporate-mode" "harness-config-test-api-key")
                       (mapcar (lambda (e) (plist-get e :key)) (plist-get policy :settings))))
        (let ((corporate (cadr (plist-get policy :settings))))
          (should (equal "t" (plist-get corporate :value)))
          (should (eq :false (plist-get corporate :listed)))
          (should (eq t (plist-get corporate :defined))))
        (should-not (plist-get (caddr (plist-get policy :settings)) :value))))
    ;; No policy, no description of one.
    (should-not (plist-get (harness-call 'config/describe sub) :policy))
    (should (eq 'auto (harness-call 'config/get 'harness-permission-mode sub)))))

(ert-deftest harness-config-policy-refuses-changes-at-every-scope ()
  "Neither `config/set' nor `config/unset' changes what the policy sets,
in any scope, and nothing is written."
  (skip-unless (executable-find "git"))
  (harness-config-test-with
    (harness-test-with-policy '((harness-permission-mode . ask) (harness-allowed-directories "/srv/"))
      (dolist (call (list (lambda () (harness-call 'config/set 'harness-permission-mode 'yolo :scope 'project :cwd sub))
                          (lambda () (harness-call 'config/set "harness-permission-mode" "yolo" :printed t
                                                   :scope 'directory :cwd sub))
                          (lambda () (harness-call 'config/set 'harness-permission-mode 'yolo :scope 'global :cwd sub))
                          (lambda () (harness-call 'config/set 'harness-permission-mode 'ask :scope 'project :cwd sub))
                          (lambda () (harness-call 'config/unset 'harness-permission-mode :scope 'global :cwd sub))
                          (lambda () (harness-call 'config/unset "harness-allowed-directories" :scope 'project :cwd sub))))
        (let ((err (should-error (funcall call))))
          (should (string-match-p "is set by policy (.*) and cannot be changed" (cadr err)))))
      (should (eq 'none (harness-config-test--read root)))
      (should (eq 'none (harness-config-test--read sub)))
      (should-not saved)
      ;; The rest still changes.
      (harness-call 'config/set 'harness-model "claude:opus" :scope 'project :cwd sub)
      (should (equal "claude:opus" (harness-call 'config/get 'harness-model sub))))))

(provide 'harness-config-test)
;;; harness-config-test.el ends here
