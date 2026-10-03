;;; harness-config-test.el --- Tests for layered settings  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-model)
(defvar harness-permission-mode)
(defvar harness-thinking)
(defvar harness-tasks-directory)
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
            (harness-tasks-directory harness-tasks-directory)
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
                                               (harness-tasks-directory . 5)))))
    (harness-config-test--write sub '((nil . ((harness-permission-mode . auto)))))
    (let* ((d (harness-call 'config/describe sub))
           (mode (harness-config-test--setting d "harness-permission-mode"))
           (thinking (harness-config-test--setting d "harness-thinking"))
           (model (harness-config-test--setting d "harness-model"))
           (folder (harness-config-test--setting d "harness-tasks-directory")))
      ;; A value that does not fit its type is flagged by layer.
      (should (equal '("project") (plist-get folder :invalid)))
      (should (null (plist-get mode :invalid)))
      (should (equal root (plist-get d :root)))
      (should (equal sub (plist-get d :cwd)))
      (should (eq t (plist-get d :in-project)))
      (should (eq t (plist-get (plist-get d :files) :project-exists)))
      ;; The settings of the sections come first, in their order, here
      ;; all of them layered: no other module is loaded.
      (let ((placed (cl-loop for (_ . props) in harness-config-sections
                             append (cl-remove-if-not #'boundp (plist-get props :keys)))))
        (should (equal (sort (copy-sequence placed) #'string<)
                       (sort (copy-sequence harness-config-keys) #'string<)))
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
                        "harness-auto-reload-mode"))
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
                    (harness-tasks-directory 12 :scope project)
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
    (harness-config-test--write sub '((nil . ((harness-tasks-directory . "notes/tasks")))))
    (should (equal "notes/tasks" (harness-call 'config/get 'harness-tasks-directory sub)))
    (harness-call 'config/unset 'harness-tasks-directory :scope 'directory :cwd sub)
    (should (eq 'none (harness-config-test--read sub)))
    (should (equal harness-tasks-directory (harness-call 'config/get 'harness-tasks-directory sub)))))

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

(ert-deftest harness-config-describe-puts-common-settings-in-sections ()
  (harness-config-test-with
    (let* ((d (harness-call 'config/describe sub))
           (settings (plist-get d :settings))
           (section (lambda (key) (plist-get (harness-config-test--setting d key) :section))))
      ;; Sections with settings, in order; one whose module is not loaded is left out.
      (should (equal '("sessions" "safety" "tasks")
                     (mapcar (lambda (s) (plist-get s :name)) (plist-get d :sections))))
      (should (equal "New sessions" (plist-get (car (plist-get d :sections)) :title)))
      (should (string-match-p "dir-locals" (plist-get (car (plist-get d :sections)) :doc)))
      (should (equal "sessions" (funcall section "harness-model")))
      (should (equal "safety" (funcall section "harness-sandbox-policy")))
      (should (equal "tasks" (funcall section "harness-tasks-directory")))
      ;; Everything else is advanced: no section, after every sectioned one.
      (should (null (funcall section "harness-log-level")))
      (should (null (funcall section "harness-config-test-api-key")))
      (let ((first-advanced (cl-position-if-not (lambda (s) (plist-get s :section)) settings)))
        (should first-advanced)
        (should-not (cl-some (lambda (s) (plist-get s :section)) (nthcdr first-advanced settings))))
      ;; Internal constants are no settings at all.
      (should-not (cl-some (lambda (s) (string-search "--" (plist-get s :key))) settings)))))

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
    (dolist (section harness-config-sections)
      (dolist (key (plist-get (cdr section) :keys))
        (should (memq key defined))))
    ;; Every layered setting is shown in a section.
    (dolist (key harness-config-keys)
      (should (cl-some (lambda (section) (memq key (plist-get (cdr section) :keys)))
                       harness-config-sections)))))

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

(provide 'harness-config-test)
;;; harness-config-test.el ends here
