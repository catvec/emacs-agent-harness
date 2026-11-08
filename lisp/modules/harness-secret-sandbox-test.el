;;; harness-secret-sandbox-test.el --- Tests for the secret-sandbox module  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-prompts)

;;; Helpers

(defvar harness-secret-sandbox-test--env nil
  "What the last `harness-secret-sandbox-test--setup' made.")

(defun harness-secret-sandbox-test--setup (&rest session-args)
  "Reset the bus, load the modules and make a session with a secret to read.
Return a plist with :root, :cwd, :secrets, :file, :inside (a file in the
working directory) and :session, the session's plist."
  (harness-test-reset-bus)
  (dolist (module '(project store config tools sandbox session secrets perms tools-fs secret-sandbox))
    (harness-test-load-module module))
  (setq harness-secrets-sources nil
        harness-secret-sandbox--live nil)
  (clrhash harness-secret-sandbox--last-use)
  (harness-secrets-forget)
  (let* ((root (harness-test-temp-dir))
         (cwd (file-name-as-directory (expand-file-name "cwd/" root)))
         (secrets (file-name-as-directory (expand-file-name "secrets/" root)))
         (file (expand-file-name "creds.json" secrets))
         (inside (expand-file-name "inside.txt" cwd)))
    (make-directory cwd t)
    (make-directory secrets t)
    (with-temp-file file
      (insert (json-encode '(("token" . "s3cr3t-VALUE-0123456789")
                             ("other" . "another-value-9876543210")))))
    (with-temp-file inside (insert "inside-secret-value-42\n"))
    (setq harness-secret-sandbox-test--env
          (list :root root :cwd cwd :secrets secrets :file file :inside inside
                :session (apply #'harness-call 'session/create
                                :cwd cwd :name "secret-test" :provider 'demo :model "demo"
                                session-args)))
    harness-secret-sandbox-test--env))

(defun harness-secret-sandbox-test--teardown ()
  "Delete what `harness-secret-sandbox-test--setup' made."
  (when-let* ((root (plist-get harness-secret-sandbox-test--env :root)))
    (ignore-errors (delete-directory root t))))

(defun harness-secret-sandbox-test--session () (plist-get harness-secret-sandbox-test--env :session))
(defun harness-secret-sandbox-test--cwd () (plist-get harness-secret-sandbox-test--env :cwd))
(defun harness-secret-sandbox-test--file () (plist-get harness-secret-sandbox-test--env :file))

(defun harness-secret-sandbox-test--entry (&rest extra)
  "Return an entry of `harness-secrets-sources' for the test token.
EXTRA keys go on top; nothing marks it for the sandbox, because nothing
in the entry does."
  (append (list :label "test-token" :file (harness-secret-sandbox-test--file) :json-path "token")
          extra))

(defun harness-secret-sandbox-test--declare (&rest entries)
  "Set `harness-secrets-sources' to ENTRIES and read them; return nothing."
  (setq harness-secrets-sources entries)
  (harness-secrets-forget))

(defun harness-secret-sandbox-test--subseq-p (needle list)
  "Non-nil when the elements of NEEDLE appear consecutively in LIST."
  (cl-loop for tail on list
           thereis (equal (seq-take tail (length needle)) needle)))

(defun harness-secret-sandbox-test--await (value)
  "Await VALUE when it is a promise, else return it."
  (if (harness-promise-p value) (harness-test-await value) value))

(defun harness-secret-sandbox-test--run (label command &optional timeout)
  "Run COMMAND with LABEL through the method, and return the result."
  (harness-secret-sandbox-test--await
   (harness-call 'secret-sandbox/run (plist-get (harness-secret-sandbox-test--session) :id)
                 label command timeout)))

(defun harness-secret-sandbox-test--pending ()
  "Return the pending requests of the test session."
  (plist-get (harness-call 'session/get (plist-get (harness-secret-sandbox-test--session) :id)) :pending))

(defun harness-secret-sandbox-test--answer (option)
  "Answer the test session's first pending request with OPTION; return the decision."
  (let ((pid (plist-get (car (harness-secret-sandbox-test--pending)) :id)))
    (harness-call 'permission/answer (plist-get (harness-secret-sandbox-test--session) :id) pid option)))

(defun harness-secret-sandbox-test--request (tool kind &rest paths)
  "Build a permission request for TOOL of KIND touching PATHS."
  (list :session (harness-secret-sandbox-test--session) :tool tool :kind kind
        :input (list :path (car paths) :secret "test-token" :command "true")
        :paths paths :call-id (harness-short-id)))

(defun harness-secret-sandbox-test--bwrap-p ()
  "Non-nil when the real bwrap is the backend in force."
  (and (executable-find "bwrap")
       (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend))))

;;;; One list, no second declaration

(ert-deftest harness-secret-sandbox-marks-a-secret-in-the-one-list ()
  "Declaring a secret is the whole marking: no key, no second option, no settings."
  (unwind-protect
      (progn
        (harness-secret-sandbox-test--setup)
        (harness-secret-sandbox-test--declare (harness-secret-sandbox-test--entry))
        ;; The entry is untouched: the module adds nothing to it.
        (should (equal (list (harness-secret-sandbox-test--entry)) harness-secrets-sources))
        (let ((secret (harness-secret-sandbox--find "test-token")))
          (should secret)
          (should-not (plist-get secret :error))
          (should (equal "test-token" (plist-get secret :label)))
          (should (string-match-p "creds.json" (plist-get secret :source)))
          (should (equal '("test-token") (harness-secret-sandbox--labels))))
        ;; The same entry is what the secrets module masks: one list, one path.
        (let ((masked (car (harness-secrets-mask-text "x s3cr3t-VALUE-0123456789 y"))))
          (should-not (string-match-p "s3cr3t-VALUE" masked))
          (should (string-match-p "\\[redacted: test-token sha256:[0-9a-f]\\{8\\}\\]" masked)))
        (let ((sources (harness-call 'secrets/sources)))
          (should (cl-find "test-token" sources
                           :key (lambda (s) (plist-get s :label)) :test #'equal)))
        ;; What the agent may ask for names no path, value or fingerprint.
        (let ((public (harness-secret-sandbox--public-entry
                       (harness-secret-sandbox--find "test-token"))))
          (should (equal "test-token" (plist-get public :label)))
          (should (plist-get public :available))
          (should-not (plist-member public :source))
          (should-not (plist-member public :fingerprint))
          (should-not (plist-member public :last_use))
          (should-not (string-match-p "creds.json" (format "%S" public)))
          (should-not (string-match-p "s3cr3t" (format "%S" public)))))
    (harness-secret-sandbox-test--teardown)))

(ert-deftest harness-secret-sandbox-lists-only-labels-it-can-use ()
  "A value no locked run can use is listed with the reason and never offered."
  (unwind-protect
      (progn
        (harness-secret-sandbox-test--setup)
        (setenv "HARNESS_TEST_SECRET" "environment-value-0123456789")
        (unwind-protect
            (progn
              (harness-secret-sandbox-test--declare
               (harness-secret-sandbox-test--entry)
               (list :label "from-env" :env "HARNESS_TEST_SECRET")
               (list :label "literal" :literal "literal-value-0123456789"))
              (should (equal '("test-token") (harness-secret-sandbox--labels)))
              (dolist (pair '(("from-env" . "environment variable")
                              ("literal" . "literal")))
                (let ((secret (harness-secret-sandbox--find (car pair))))
                  (should secret)
                  (should (string-match-p (cdr pair) (plist-get secret :error)))
                  ;; No error names a value.
                  (should-not (string-match-p "0123456789" (plist-get secret :error)))))
              ;; A run refuses them before the prompt, without running anything.
              (dolist (label '("from-env" "literal"))
                (let ((result (harness-secret-sandbox-test--run label "true")))
                  (should (plist-get result :is-error))
                  (should (string-match-p "cannot be used" (plist-get result :content))))))
          (setenv "HARNESS_TEST_SECRET" nil)))
    (harness-secret-sandbox-test--teardown)))

(ert-deftest harness-secret-sandbox-a-label-names-one-secret ()
  "Two secrets with one label cannot be asked for: the label is the only handle."
  (unwind-protect
      (progn
        (harness-secret-sandbox-test--setup)
        (harness-secret-sandbox-test--declare
         (harness-secret-sandbox-test--entry)
         (list :label "test-token" :file (harness-secret-sandbox-test--file)
               :json-path "other"))
        (should-not (harness-secret-sandbox--labels))
        (let ((secret (harness-secret-sandbox--find "test-token")))
          (should (string-match-p "names 2 secrets" (plist-get secret :error))))
        (let ((result (harness-secret-sandbox-test--run "test-token" "true")))
          (should (plist-get result :is-error))
          (should (string-match-p "names 2 secrets" (plist-get result :content)))))
    (harness-secret-sandbox-test--teardown)))

(ert-deftest harness-secret-sandbox-a-source-that-cannot-be-read-has-no-label ()
  "An unreadable source offers nothing to ask for, and never a value."
  (unwind-protect
      (progn
        (harness-secret-sandbox-test--setup)
        (harness-secret-sandbox-test--declare
         (list :label "missing" :file (expand-file-name "missing.json" (plist-get harness-secret-sandbox-test--env :root))
               :json-path "x"))
        (should-not (harness-secret-sandbox--labels))
        (let ((result (harness-secret-sandbox-test--run "missing" "true")))
          (should (plist-get result :is-error))
          (should (string-match-p "no secret is labelled" (plist-get result :content)))))
    (harness-secret-sandbox-test--teardown)))

(ert-deftest harness-secret-sandbox-refuses-a-source-in-the-state-directory ()
  "A source the agent's inspection exception can read is refused.
At listing time when the state directory is known, and at run time when
it changed since the registry was read."
  (unwind-protect
      (progn
        (harness-secret-sandbox-test--setup)
        (let* ((state (harness-test-temp-dir))
               (file (expand-file-name "state-secret.json" state)))
          (with-temp-file file (insert (json-encode '(("token" . "state-secret-value-42")))))
          (harness-secret-sandbox-test--declare
           (list :label "state" :file file :json-path "token"))
          (let ((harness-state-directory state))
            (should (string-match-p "state directory"
                                    (plist-get (harness-secret-sandbox--find "state") :error))))
          ;; Read when the state directory was not known: the run refuses
          ;; before it writes the value anywhere.
          (let ((harness-state-directory nil))
            (should-not (plist-get (harness-secret-sandbox--find "state") :error)))
          (let ((harness-state-directory state))
            (let ((result (harness-secret-sandbox-test--run "state" "true")))
              (should (plist-get result :is-error))
              (should (string-match-p "state directory" (plist-get result :content)))))
          (delete-directory state t)))
    (harness-secret-sandbox-test--teardown)))

;;;; No output comes back

(ert-deftest harness-secret-sandbox-withholds-every-output ()
  "Every run returns the same sentence, whatever the command prints or does.
Under the real bwrap: the value, base64, hex, a length, a hash, an exit
status and a timeout all come back as the one fixed result."
  (unwind-protect
      (let ((env (harness-secret-sandbox-test--setup)))
        (skip-unless (harness-secret-sandbox-test--bwrap-p))
        (harness-secret-sandbox-test--declare (harness-secret-sandbox-test--entry))
        (let* ((commands (list (cons "cat" "cat \"$HARNESS_SECRET_FILE\"")
                               (cons "base64" "base64 -w0 \"$HARNESS_SECRET_FILE\"")
                               (cons "base64 of base64"
                                     "base64 -w0 \"$HARNESS_SECRET_FILE\" | base64 -w0")
                               (cons "hex" "od -An -tx1 \"$HARNESS_SECRET_FILE\" | tr -d ' \\n'")
                               (cons "length" "wc -c < \"$HARNESS_SECRET_FILE\"")
                               (cons "hash" "sha256sum \"$HARNESS_SECRET_FILE\"")
                               (cons "exit status" "exit 3"))))
          (dolist (command commands)
            (let ((result (harness-secret-sandbox-test--run "test-token" (cdr command))))
              (should-not (plist-get result :is-error))
              (should (equal harness-secret-sandbox--withheld-default (plist-get result :content)))
              (should (equal (list :secret "test-token" :withheld t) (plist-get result :meta)))))
          ;; A timeout is the same sentence too, not an error and not a
          ;; duration: an exit status or a timing is an oracle.
          (let ((result (harness-secret-sandbox-test--run
                         "test-token" "cat \"$HARNESS_SECRET_FILE\"; sleep 10" 1)))
            (should-not (plist-get result :is-error))
            (should (equal harness-secret-sandbox--withheld-default (plist-get result :content)))
            (should-not (plist-member (plist-get result :meta) :exit))
            (should-not (plist-member (plist-get result :meta) :duration))
            (should-not (plist-member (plist-get result :meta) :masked)))
          ;; The worktree is read-only, the private temporary directory is
          ;; writable and gone, and no secret directory survives.
          (let ((out (expand-file-name "out" (plist-get env :cwd))))
            (should-not (plist-get (harness-secret-sandbox-test--run
                                    "test-token" (format "touch %s" (directory-file-name out)))
                                   :is-error))
            (should-not (file-exists-p out)))
          (should-not (plist-get (harness-secret-sandbox-test--run
                                  "test-token" "echo scratch > \"$TMPDIR/x\"")
                                 :is-error))
          (should-not harness-secret-sandbox--live)
          (should (numberp (gethash "test-token" harness-secret-sandbox--last-use)))))
    (harness-secret-sandbox-test--teardown)))

(ert-deftest harness-secret-sandbox-the-result-is-a-registered-prompt ()
  "The result text comes from the prompt registry, and a model may override it."
  (should (memq 'secret-sandbox-withheld (harness-prompt-names)))
  (should (equal harness-secret-sandbox--withheld-default
                 (harness-prompt-default 'secret-sandbox-withheld)))
  (unwind-protect
      (progn
        (harness-secret-sandbox-test--setup)
        (skip-unless (harness-secret-sandbox-test--bwrap-p))
        (harness-secret-sandbox-test--declare (harness-secret-sandbox-test--entry))
        (let ((model (plist-get (harness-secret-sandbox-test--session) :model))
              (harness-prompt-overrides nil)
              (harness-prompt-overrides-file nil)
              (harness-prompt--file-cache nil))
          ;; The session's own model's override is the text it gets.
          (setq harness-prompt-overrides
                (list (cons model '((secret-sandbox-withheld . "Ran in the locked sandbox; nothing came back.")))))
          (let ((result (harness-secret-sandbox-test--run "test-token" "true")))
            (should (equal "Ran in the locked sandbox; nothing came back."
                           (plist-get result :content))))
          ;; Another model's override does not change it.
          (setq harness-prompt-overrides
                (list (cons "other:model" '((secret-sandbox-withheld . "Other model's words.")))))
          (let ((result (harness-secret-sandbox-test--run "test-token" "true")))
            (should (equal harness-secret-sandbox--withheld-default (plist-get result :content))))))
    (harness-secret-sandbox-test--teardown)))

(ert-deftest harness-secret-sandbox-nothing-transformed-is-masked ()
  "There is no mask of transformed output, and no declaration of its own."
  (should-not (fboundp 'harness-secret-sandbox--encodings))
  (should-not (fboundp 'harness-secret-sandbox--secret-forms))
  (should-not (boundp 'harness-secrets-extra-secrets))
  (should-not (boundp 'harness-secret-sandbox-secrets))
  ;; No state of its own about what is marked: the secrets registry has it.
  (should-not (boundp 'harness-secret-sandbox--declarations))
  (should-not (boundp 'harness-secret-sandbox--declared)))

;;;; Keeping the agent out

(ert-deftest harness-secret-sandbox-file-tools-cannot-read-a-source ()
  "The file tools are refused for a source, finally, before the jail or the mode."
  (unwind-protect
      (let ((env (harness-secret-sandbox-test--setup :permission-mode 'yolo)))
        (harness-secret-sandbox-test--declare (harness-secret-sandbox-test--entry))
        (cl-labels ((decide (request)
                      (harness-test-await
                       (harness-run-filter-async-between
                        'permission/decide 2 2 (list :behavior 'ask) request))))
          (dolist (tool '("read_file" "edit_file" "write_file" "grep"))
            (let ((decision (decide (harness-secret-sandbox-test--request
                                     tool (if (equal tool "read_file") 'read 'write)
                                     (harness-secret-sandbox-test--file)))))
              (should (eq 'deny (plist-get decision :behavior)))
              (should (plist-get decision :final))
              (should (string-match-p "test-token" (plist-get decision :reason)))))
          ;; A directory holding the source is refused too, as is a live secret file.
          (let ((decision (decide (harness-secret-sandbox-test--request
                                   "grep" 'read (file-name-directory (harness-secret-sandbox-test--file))))))
            (should (eq 'deny (plist-get decision :behavior))))
          (let ((live (harness-test-temp-dir)))
            (unwind-protect
                (progn
                  (push live harness-secret-sandbox--live)
                  (let ((decision (decide (harness-secret-sandbox-test--request
                                           "read_file" 'read (expand-file-name "secret" live)))))
                    (should (eq 'deny (plist-get decision :behavior)))
                    (should (string-match-p "secret file" (plist-get decision :reason)))))
              (setq harness-secret-sandbox--live (delete live harness-secret-sandbox--live))
              (delete-directory live t)))
          ;; The listing tools may say the file exists.
          (dolist (tool '("list_dir" "glob" "file_info"))
            (should-not (eq 'deny (plist-get (decide (harness-secret-sandbox-test--request
                                                     tool 'read (harness-secret-sandbox-test--file)))
                                            :behavior))))))
    (harness-secret-sandbox-test--teardown)))

(ert-deftest harness-secret-sandbox-every-command-hides-the-sources ()
  "Every bash and elisp command is told to hide the sources, and nothing without one."
  (unwind-protect
      (let ((env (harness-secret-sandbox-test--setup))
            (sid (plist-get (harness-secret-sandbox-test--session) :id)))
        (should-not (harness-run-filter 'tools/sandbox-options nil sid))
        (harness-secret-sandbox-test--declare (harness-secret-sandbox-test--entry))
        (let ((options (harness-run-filter 'tools/sandbox-options nil sid)))
          (should (equal (list (harness-secret-sandbox-test--file)) (plist-get options :hide))))
        (let ((live (harness-test-temp-dir)))
          (unwind-protect
              (progn
                (push live harness-secret-sandbox--live)
                (should (member live (plist-get (harness-run-filter 'tools/sandbox-options nil sid) :hide))))
            (setq harness-secret-sandbox--live nil)
            (delete-directory live t))))
    (harness-secret-sandbox-test--teardown)))

;;;; The prompt

(ert-deftest harness-secret-sandbox-the-user-approves-every-use ()
  "A run asks even in yolo, with allow-once and deny-once; an allow runs it."
  (unwind-protect
      (let ((env (harness-secret-sandbox-test--setup :permission-mode 'yolo))
            (sid (plist-get (harness-secret-sandbox-test--session) :id)))
        (harness-secret-sandbox-test--declare (harness-secret-sandbox-test--entry))
        (let ((promise (harness-call 'tools/execute
                                     sid '(:id "c1" :name "run_with_secret"
                                           :input (:secret "test-token"
                                                   :command "cat \"$HARNESS_SECRET_FILE\"")))))
          (harness-test-wait (lambda () (harness-secret-sandbox-test--pending)) 5 "the prompt")
          (let* ((pending (car (harness-secret-sandbox-test--pending)))
                 (payload (plist-get pending :payload)))
            (should (equal "run_with_secret" (plist-get payload :tool)))
            (should (plist-get payload :confirm))
            (should (equal '(allow-once deny-once) (plist-get payload :options)))
            (should (string-match-p "Use secret" (plist-get payload :title)))
            (should (string-match-p "creds.json" (plist-get payload :reason)))
            (should (string-match-p "sha256:" (plist-get payload :reason)))
            (should (string-match-p "read-only" (plist-get payload :reason)))
            (should (string-match-p "Network      none" (plist-get payload :reason)))
            (should (string-match-p "not returned to the agent" (plist-get payload :reason))))
          (harness-secret-sandbox-test--answer "allow-once")
          (let ((result (harness-test-await promise)))
            (should-not (plist-get result :is-error))
            (should (equal harness-secret-sandbox--withheld-default (plist-get result :content)))
            (should-not (string-match-p "s3cr3t-VALUE" (plist-get result :content)))))
        ;; A second call asks again: nothing was remembered.
        (let ((promise (harness-call 'tools/execute
                                     sid '(:id "c2" :name "run_with_secret"
                                           :input (:secret "test-token" :command "true")))))
          (harness-test-wait (lambda () (harness-secret-sandbox-test--pending)) 5 "the second prompt")
          (harness-secret-sandbox-test--answer "deny-once")
          (let ((result (harness-test-await promise)))
            (should (plist-get result :is-error))
            (should (string-match-p "Denied" (plist-get result :content))))
          (should-not (harness-secret-sandbox-test--pending))))
    (harness-secret-sandbox-test--teardown)))

(ert-deftest harness-secret-sandbox-a-standing-rule-cannot-open-a-secret ()
  "A standing deny denies, and a standing allow still prompts."
  (unwind-protect
      (let ((env (harness-secret-sandbox-test--setup :permission-mode 'yolo))
            (sid (plist-get (harness-secret-sandbox-test--session) :id))
            (harness-perms-rules nil))
        (harness-secret-sandbox-test--declare (harness-secret-sandbox-test--entry))
        (let ((harness-perms-rules '((:tool "run_with_secret" :behavior deny))))
          (let ((decision (harness-test-await
                           (harness-tools-decide-traced
                            (harness-secret-sandbox-test--request "run_with_secret" 'exec)))))
            (should (eq 'deny (plist-get decision :behavior)))
            (should-not (harness-secret-sandbox-test--pending))))
        (let ((harness-perms-rules '((:tool "run_with_secret" :behavior allow))))
          (let ((promise (harness-tools-decide-traced
                          (harness-secret-sandbox-test--request "run_with_secret" 'exec))))
            (harness-test-wait (lambda () (harness-secret-sandbox-test--pending)) 5 "the prompt")
            (harness-secret-sandbox-test--answer "deny-once")
            (should (eq 'deny (plist-get (harness-test-await promise) :behavior))))))
    (harness-secret-sandbox-test--teardown)))

(ert-deftest harness-secret-sandbox-nobody-can-answer-is-a-denial ()
  "A non-interactive session, masking off and no sandbox are denied without a prompt."
  (unwind-protect
      (let ((env (harness-secret-sandbox-test--setup :non-interactive t)))
        (harness-secret-sandbox-test--declare (harness-secret-sandbox-test--entry))
        (let ((decision (harness-test-await
                         (harness-tools-decide-traced
                          (harness-secret-sandbox-test--request "run_with_secret" 'exec)))))
          (should (eq 'deny (plist-get decision :behavior)))
          (should (string-match-p "non-interactive" (plist-get decision :reason)))
          (should-not (harness-secret-sandbox-test--pending))))
    (harness-secret-sandbox-test--teardown))
  (unwind-protect
      (progn
        (harness-secret-sandbox-test--setup)
        (harness-secret-sandbox-test--declare (harness-secret-sandbox-test--entry))
        (let ((harness-secrets-mask nil))
          (let ((decision (harness-test-await
                           (harness-tools-decide-traced
                            (harness-secret-sandbox-test--request "run_with_secret" 'exec)))))
            (should (eq 'deny (plist-get decision :behavior)))
            (should (string-match-p "masking is off" (plist-get decision :reason)))
            (should-not (harness-secret-sandbox-test--pending))))
        ;; A policy that cannot give the locked profile refuses before asking.
        (let ((harness-sandbox-policy 'off))
          (let ((decision (harness-test-await
                           (harness-tools-decide-traced
                            (harness-secret-sandbox-test--request "run_with_secret" 'exec)))))
            (should (eq 'deny (plist-get decision :behavior)))
            (should (string-match-p "locked" (plist-get decision :reason)))
            (should-not (harness-secret-sandbox-test--pending))))
        ;; An unknown label is refused without asking.
        (let ((decision (harness-test-await
                         (harness-tools-decide-traced
                          (list :session (harness-secret-sandbox-test--session) :tool "run_with_secret"
                                :kind 'exec :input (list :secret "nope" :command "true")
                                :paths nil :call-id "x")))))
          (should (eq 'deny (plist-get decision :behavior)))
          (should (string-match-p "nope" (plist-get decision :reason)))
          (should-not (harness-secret-sandbox-test--pending))))
    (harness-secret-sandbox-test--teardown)))

;;;; The locked run

(ert-deftest harness-secret-sandbox-run-refuses-what-it-cannot-use ()
  "The run method refuses an unknown label, a source in the worktree and masking off."
  (unwind-protect
      (let ((env (harness-secret-sandbox-test--setup)))
        (harness-secret-sandbox-test--declare
         (harness-secret-sandbox-test--entry)
         (list :label "inside" :file (plist-get env :inside) :regexp "\\(.+\\)"))
        (let ((result (harness-secret-sandbox-test--run "nope" "true")))
          (should (plist-get result :is-error))
          (should (string-match-p "list_secrets" (plist-get result :content))))
        (let ((result (harness-secret-sandbox-test--run "inside" "true")))
          (should (plist-get result :is-error))
          (should (string-match-p "working directory" (plist-get result :content))))
        (let ((harness-secrets-mask nil))
          (let ((result (harness-secret-sandbox-test--run "test-token" "true")))
            (should (plist-get result :is-error))
            (should (string-match-p "masking is off" (plist-get result :content)))))
        (let ((harness-sandbox-policy 'off))
          (let ((result (harness-secret-sandbox-test--run "test-token" "true")))
            (should (plist-get result :is-error))
            (should (string-match-p "locked" (plist-get result :content)))))
        ;; A value that cannot be read is simply not a label.
        (harness-secret-sandbox-test--declare
         (list :label "broken" :file (expand-file-name "missing" (plist-get env :root)) :json-path "x"))
        (should-not (harness-secret-sandbox--find "broken")))
    (harness-secret-sandbox-test--teardown)))

(ert-deftest harness-secret-sandbox-the-tool-runs-through-the-prompt ()
  "The tool runs the locked command only after the user's allow, and lists the secrets."
  (unwind-protect
      (let ((env (harness-secret-sandbox-test--setup :permission-mode 'auto))
            (sid (plist-get (harness-secret-sandbox-test--session) :id)))
        (skip-unless (harness-secret-sandbox-test--bwrap-p))
        (harness-secret-sandbox-test--declare (harness-secret-sandbox-test--entry))
        (let ((list-result (harness-test-await
                            (harness-call 'tools/execute sid '(:id "c0" :name "list_secrets")))))
          (should-not (plist-get list-result :is-error))
          (should (string-match-p "test-token" (plist-get list-result :content)))
          (should-not (string-match-p "creds.json" (plist-get list-result :content)))
          (should-not (string-match-p "s3cr3t" (plist-get list-result :content))))
        (let ((promise (harness-call 'tools/execute
                                     sid '(:id "c1" :name "run_with_secret"
                                           :input (:secret "test-token"
                                                   :command "cat \"$HARNESS_SECRET_FILE\"")))))
          (harness-test-wait (lambda () (harness-secret-sandbox-test--pending)) 5 "the prompt")
          (harness-secret-sandbox-test--answer "allow-once")
          (let ((result (harness-test-await promise)))
            (should-not (plist-get result :is-error))
            (should (equal harness-secret-sandbox--withheld-default (plist-get result :content)))
            (should-not (string-match-p "s3cr3t-VALUE" (plist-get result :content))))))
    (harness-secret-sandbox-test--teardown)))

;;;; The locked sandbox itself

(ert-deftest harness-secret-sandbox-locked-profile-is-asked-for ()
  "The run asks for the locked profile: no environment, no network, the secret read-only."
  (unwind-protect
      (progn
        (harness-secret-sandbox-test--setup)
        (skip-unless (harness-secret-sandbox-test--bwrap-p))
        (harness-secret-sandbox-test--declare (harness-secret-sandbox-test--entry))
        (let ((seen nil)
              (modes nil)
              (original (symbol-function 'harness-run-command)))
          (cl-letf (((symbol-function 'harness-run-command)
                     (lambda (command &rest args)
                       (let* ((at (cl-position "HARNESS_SECRET_FILE" command :test #'equal))
                              (file (and at (nth (1+ at) command))))
                         (setq modes (and file (list (file-modes (file-name-directory file))
                                                     (file-modes file)))))
                       (setq seen (cons command args))
                       (apply original command args))))
            (should-not (plist-get (harness-secret-sandbox-test--run "test-token" "true") :is-error)))
          (let* ((cmd (car seen))
                 (args (cdr seen)))
            (should (member "--clearenv" cmd))
            (should (member "--unshare-net" cmd))
            (should-not (cl-some (lambda (word) (equal word "--cap-add")) cmd))
            (should (equal 120 (plist-get args :timeout)))
            (should (harness-secret-sandbox-test--subseq-p
                     (list "--ro-bind" "/dev/null" (harness-secret-sandbox-test--file)) cmd))
            (should (cl-some (lambda (tail) (and (equal (car tail) "--ro-bind")
                                                 (string-match-p "harness-secret-"
                                                                 (caddr tail))))
                             (cl-loop for tail on cmd collect tail)))
            (let ((environment (cl-loop for tail on cmd
                                        when (equal (car tail) "--setenv")
                                        collect (list (cadr tail) (caddr tail)))))
              (should (assoc "HARNESS_SECRET_FILE" environment))
              (should (assoc "HARNESS_SECRET_LABEL" environment))
              (should (equal "test-token" (cadr (assoc "HARNESS_SECRET_LABEL" environment))))
              (should (equal "/tmp" (cadr (assoc "HOME" environment))))
              (should-not (assoc "PWD" environment)))
            ;; The one file is 0600 in a directory of 0700, while it exists.
            (should (equal (list #o700 #o600) modes)))))
    (harness-secret-sandbox-test--teardown)))

(ert-deftest harness-secret-sandbox-a-shell-command-cannot-read-a-source ()
  "A normal command is shown the directory but not the file: the hide layer."
  (unwind-protect
      (let ((env (harness-secret-sandbox-test--setup :permission-mode 'yolo))
            (shown (harness-test-temp-dir)))
        (skip-unless (harness-secret-sandbox-test--bwrap-p))
        (let ((file (expand-file-name "shown-secret.json" shown)))
          (with-temp-file file
            (insert (json-encode '(("token" . "shown-secret-value-024680")))))
          (harness-secret-sandbox-test--declare
           (list :label "shown" :file file :json-path "token"))
          (let* ((harness-sandbox-extra-read-only-dirs (list shown))
                 (sid (plist-get (harness-secret-sandbox-test--session) :id))
                 (options (harness-run-filter 'tools/sandbox-options nil sid))
                 (without (harness-call 'sandbox/wrap
                                        (harness-secret-sandbox-test--cwd)
                                        (list "cat" file)))
                 (with (apply #'harness-call 'sandbox/wrap
                              (harness-secret-sandbox-test--cwd) (list "cat" file) options)))
            (should (member file (plist-get options :hide)))
            ;; Without the hide, the command reads the value: the test means something.
            (let ((r (harness-test-await
                      (harness-run-command without :cwd (harness-secret-sandbox-test--cwd) :timeout 20))))
              (should (eql 0 (plist-get r :exit)))
              (should (string-match-p "shown-secret-value-024680" (plist-get r :stdout))))
            ;; With it, the file is covered and cannot be opened.
            (let ((r (harness-test-await
                      (harness-run-command with :cwd (harness-secret-sandbox-test--cwd) :timeout 20))))
              (should-not (string-match-p "shown-secret-value" (plist-get r :stdout)))
              (should-not (string-match-p "shown-secret-value" (plist-get r :stderr)))
              (should-not (eql 0 (plist-get r :exit))))))
        (delete-directory shown t))
    (harness-secret-sandbox-test--teardown)))

(ert-deftest harness-secret-sandbox-is-off-by-default ()
  "The module is not one of the core modules; enabling it is a choice."
  (should-not (memq 'secret-sandbox harness-core-modules))
  (should (equal '(secrets sandbox perms session)
                 (harness-module-requires (harness-module-get 'secret-sandbox)))))

(provide 'harness-secret-sandbox-test)
;;; harness-secret-sandbox-test.el ends here
