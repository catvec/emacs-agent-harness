;;; harness-sandbox-openshell-test.el --- NVIDIA OpenShell as a sandbox backend  -*- lexical-binding: t; -*-

;;; Commentary:

;; OpenShell needs a gateway and a container engine, which a test run
;; has not: these tests run the module against test/fixtures/fake-openshell.py,
;; a stand-in for openshell's command line.  It answers the calls the
;; module makes as openshell 0.1.5 does, checks what the real gateway
;; checks (the policy file against the documented schema, the driver
;; config's mounts against the Docker driver's rules) and, where bwrap can
;; start, runs a command in what the sandbox's mounts and policy
;; describe -- so a test sees what the command could reach.  The tests
;; of a real OpenShell are at the end, and skip where it is not set up.

;;; Code:

(require 'harness-test-helpers)

(defun harness-openshell-test--setup ()
  "Load the sandbox module and what it requires."
  (harness-test-load-module 'project)
  (harness-test-load-module 'config)
  (harness-test-load-module 'sandbox))

(defun harness-openshell-test--fake ()
  "Return the path of the stand-in for openshell, or skip the test."
  (let ((fake (expand-file-name "test/fixtures/fake-openshell.py" harness-test-root)))
    (unless (and (file-executable-p fake) (executable-find "python3"))
      (ert-skip "the stand-in for openshell needs python3"))
    fake))

(defmacro harness-openshell-test-with-fake (spec &rest body)
  "Run BODY with the sandbox backend asked to be OpenShell, the stand-in.
SPEC is (FAKE STATE): FAKE is the stand-in's path, STATE the directory
it keeps its sandboxes and its log in.  The policy is `required', and
the backend is detected before BODY and again, with the real settings,
afterwards."
  (declare (indent 1))
  `(unwind-protect
       (let* ((,(car spec) (harness-openshell-test--fake))
              (,(cadr spec) (harness-test-temp-dir))
              (process-environment (cons (concat "FAKE_OPENSHELL_STATE=" (directory-file-name ,(cadr spec)))
                                         process-environment))
              (harness-sandbox-openshell-program ,(car spec))
              (harness-sandbox-backend 'openshell)
              (harness-sandbox-policy 'required))
         (unwind-protect
             (progn (harness-sandbox-detect) ,@body)
           (delete-directory ,(cadr spec) t)))
     (harness-sandbox-detect)))

(defmacro harness-openshell-test-with-executables (available &rest body)
  "Run BODY with `executable-find' answering only for programs in AVAILABLE.
AVAILABLE is an alist of program name to path; the name openshell stands for
the program `harness-sandbox-openshell-program' names, whatever it is.
The backend is detected before BODY."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'executable-find)
              (lambda (name &optional _remote)
                (or (cdr (assoc name ,available))
                    (and (equal name harness-sandbox-openshell-program)
                         (cdr (assoc "openshell" ,available)))))))
     (harness-sandbox-detect)
     ,@body))

(defmacro harness-openshell-test-with-home (home &rest body)
  "Run BODY with HOME, a fresh directory, as $HOME; delete it afterwards."
  (declare (indent 1))
  `(let* ((,home (harness-test-temp-dir))
          (process-environment (cons (concat "HOME=" (directory-file-name ,home)) process-environment)))
     (unwind-protect (progn ,@body)
       (delete-directory ,home t))))

(defun harness-openshell-test--calls (state)
  "Return the calls the stand-in logged in STATE, each as its argument list."
  (let ((file (expand-file-name "calls.log" state)))
    (and (file-exists-p file)
         (mapcar (lambda (line) (plist-get (harness-json-parse line) :argv))
                 (with-temp-buffer (insert-file-contents file)
                                   (split-string (buffer-string) "\n" t))))))

(defun harness-openshell-test--ran (state subcommand)
  "Return the calls of `sandbox SUBCOMMAND' in STATE, those that run it, not its help."
  (cl-remove-if-not (lambda (call)
                      (and (equal (seq-take call 2) (list "sandbox" subcommand))
                           (not (equal (car (last call)) "--help"))))
                    (harness-openshell-test--calls state)))

(defun harness-openshell-test--sandboxes (state)
  "Return the names of the sandboxes the stand-in has now, in STATE."
  (let ((dir (expand-file-name "sandboxes/" state)))
    (and (file-directory-p dir)
         (mapcar #'file-name-sans-extension (directory-files dir nil "\\.json\\'")))))

(defun harness-openshell-test--word-after (flag list)
  "Return the element of LIST after the first FLAG."
  (cadr (member flag list)))

(defun harness-openshell-test--create-args (cmd)
  "Return the arguments of `sandbox create' in the wrapper command line CMD."
  (let ((n (string-to-number (nth 6 cmd))))
    (seq-subseq cmd 7 (+ 7 n))))

(defun harness-openshell-test--exec-args (cmd)
  "Return the arguments of `sandbox exec' (after its -n NAME) in the wrapper command line CMD."
  (nthcdr (+ 7 (string-to-number (nth 6 cmd))) cmd))

(defun harness-openshell-test--config (cmd)
  "Return the driver config of the wrapper command line CMD, parsed, or nil."
  (when-let* ((json (harness-openshell-test--word-after "--driver-config-json"
                                                        (harness-openshell-test--create-args cmd))))
    (harness-json-parse json)))

(defun harness-openshell-test--mounts (cmd)
  "Return the mounts of the wrapper command line CMD as (TARGET SOURCE MODE) lists."
  (mapcar (lambda (m)
            (list (plist-get m :target) (plist-get m :source)
                  (cond ((equal (plist-get m :type) "tmpfs") 'tmpfs)
                        ((harness-json-true-p (plist-get m :read_only)) 'ro)
                        (t 'rw))))
          (plist-get (plist-get (harness-openshell-test--config cmd) :docker) :mounts)))

(defun harness-openshell-test--policy (cmd)
  "Return the text of the policy file the wrapper command line CMD names."
  (with-temp-buffer
    (insert-file-contents (harness-openshell-test--word-after "--policy" (harness-openshell-test--create-args cmd)))
    (buffer-string)))

(defun harness-openshell-test--policy-list (text key)
  "Return the strings listed under KEY (read_only, read_write) in policy TEXT."
  (when (string-match (format "^  %s:\n\\(\\(?:    - .*\n\\)*\\)" key) text)
    (mapcar (lambda (line) (json-parse-string (substring line 6)))
            (split-string (match-string 1 text) "\n" t))))

(defun harness-openshell-test--wrap (cwd command &rest opts)
  "Wrap COMMAND for CWD with `sandbox/wrap' and OPTS; run it, return the result."
  (let ((cmd (apply #'harness-call 'sandbox/wrap cwd command opts)))
    (harness-await (harness-run-command cmd :cwd cwd :timeout 60) 70)))

;;;; Detection

(ert-deftest harness-openshell-is-asked-for-and-checked ()
  "`openshell' is the backend when it is asked for and its gateway answers."
  (harness-openshell-test--setup)
  (harness-openshell-test-with-fake (fake state)
    (ignore state)
    (let ((status (harness-call 'sandbox/status)))
      (should (eq 'openshell (plist-get status :backend)))
      (should (memq 'openshell (plist-get status :available)))
      (should-not (plist-member status :requested))
      (should-not (plist-member status :problem))
      (should (equal `((openshell . ,fake)) (list (assq 'openshell harness-sandbox--programs)))))
    ;; The check looked at the command line and the gateway, started nothing.
    (let ((calls (harness-openshell-test--calls state)))
      (should (member '("status" "-o" "json") calls))
      (should (member '("sandbox" "create" "--help") calls))
      (should-not (harness-openshell-test--ran state "create")))))

(ert-deftest harness-openshell-is-never-picked-by-auto ()
  "With `auto', OpenShell is found and listed, and never used."
  (harness-openshell-test--setup)
  (harness-openshell-test-with-fake (fake state)
    (ignore state)
    (let ((harness-sandbox-backend 'auto))
      (harness-openshell-test-with-executables `(("openshell" . ,fake))
        (let ((status (harness-call 'sandbox/status)))
          (should (eq 'none (plist-get status :backend)))
          (should (equal '(openshell) (plist-get status :available)))
          (should-not (plist-member status :requested))))
      (harness-openshell-test-with-executables `(("openshell" . ,fake) ("systemd-run" . "/usr/bin/systemd-run")
                                                 ("bwrap" . "/usr/bin/bwrap"))
        (should (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
        (should (equal '(bwrap systemd openshell) (plist-get (harness-call 'sandbox/status) :available))))
      (harness-openshell-test-with-executables `(("openshell" . ,fake) ("systemd-run" . "/usr/bin/systemd-run"))
        (should (eq 'systemd (plist-get (harness-call 'sandbox/status) :backend)))))))

(ert-deftest harness-openshell-falls-back-and-says-why ()
  "Asked for and unusable, the backend is what `auto' picks, and the status says why."
  (harness-openshell-test--setup)
  (harness-openshell-test-with-fake (fake state)
    (ignore state)
    (dolist (case '(("disconnected" . "does not answer: connection refused")
                    ("error" . "does not answer: connection refused")
                    ("not_configured" . "no OpenShell gateway is registered")
                    ("auth-failed" . "does not accept this user: token expired")))
      (let ((process-environment (cons (concat "FAKE_OPENSHELL_STATUS=" (car case)) process-environment)))
        ;; Another backend takes over.
        (harness-openshell-test-with-executables `(("openshell" . ,fake) ("bwrap" . "/usr/bin/bwrap"))
          (let ((status (harness-call 'sandbox/status)))
            (should (eq 'bwrap (plist-get status :backend)))
            (should (eq 'openshell (plist-get status :requested)))
            (should (string-match-p (regexp-quote (cdr case)) (plist-get status :problem)))
            (with-current-buffer (get-buffer-create harness-log-buffer-name)
              (should (string-match-p "OpenShell was asked for, but .*; using bwrap instead" (buffer-string))))))
        ;; None does: the commands are not confined, and the refusal says why.
        (harness-openshell-test-with-executables `(("openshell" . ,fake))
          (should (eq 'none (plist-get (harness-call 'sandbox/status) :backend)))
          (should (eq 'openshell (plist-get (harness-call 'sandbox/status) :requested)))
          (let ((err (should-error (harness-call 'sandbox/wrap "/tmp/" '("true"))
                                   :type 'harness-sandbox-unavailable)))
            (should (string-match-p "OpenShell, which was asked for, cannot be used" (cadr err)))
            (should (string-match-p (regexp-quote (cdr case)) (cadr err))))
          (should-error (harness-call 'sandbox/wrap "/tmp/" '("true") :read-only t)
                        :type 'harness-sandbox-unavailable)
          (let ((harness-sandbox-policy 'preferred))
            (should (equal '("true") (harness-call 'sandbox/wrap "/tmp/" '("true"))))))))
    ;; The gateway comes up: detecting again moves to it.
    (let ((process-environment (cons "FAKE_OPENSHELL_STATUS=disconnected" process-environment)))
      (harness-sandbox-detect)
      (should (eq 'openshell (plist-get (harness-call 'sandbox/status) :requested))))
    (harness-sandbox-detect)
    (should (eq 'openshell (plist-get (harness-call 'sandbox/status) :backend)))
    (should-not (plist-member (harness-call 'sandbox/status) :requested))))

(ert-deftest harness-openshell-is-found-or-not-installed ()
  "Without the program the harness falls back and names it; with one too old it says so."
  (harness-openshell-test--setup)
  (harness-openshell-test-with-fake (fake state)
    (ignore state)
    (let ((harness-sandbox-openshell-program "harness-test-no-such-openshell"))
      (harness-openshell-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
        (let ((status (harness-call 'sandbox/status)))
          (should (eq 'bwrap (plist-get status :backend)))
          (should (string-match-p "harness-test-no-such-openshell .* is not installed"
                                  (plist-get status :problem)))
          (should-not (memq 'openshell (plist-get status :available))))))
    (let ((process-environment (cons "FAKE_OPENSHELL_OLD=1" process-environment)))
      (harness-openshell-test-with-executables `(("openshell" . ,fake) ("bwrap" . "/usr/bin/bwrap"))
        (should (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
        (should (string-match-p "too old: `openshell sandbox create' has no --no-auto-providers"
                                (plist-get (harness-call 'sandbox/status) :problem)))))
    ;; A program that does not run at all.
    (let ((harness-sandbox-openshell-program "/bin/false"))
      (harness-sandbox-detect)
      (should (string-match-p "--help' failed" (plist-get (harness-call 'sandbox/status) :problem))))))

(ert-deftest harness-openshell-options-are-checked ()
  "An option that would make a wrong command line is a problem, not an argument."
  (harness-openshell-test--setup)
  (harness-openshell-test-with-fake (fake state)
    (ignore fake state)
    (dolist (case '((harness-sandbox-openshell-image "--evil" "is no image reference")
                    (harness-sandbox-openshell-image "a b" "is no image reference")
                    (harness-sandbox-openshell-driver vm "is neither docker nor podman")
                    (harness-sandbox-openshell-image-paths ("relative") "is no list of absolute paths")
                    (harness-sandbox-openshell-image-paths ("/opt" "/") "is no list of absolute paths")
                    (harness-sandbox-openshell-image-paths "/opt" "is no list of absolute paths")
                    (harness-sandbox-openshell-extra-args "--cpu" "is no list of strings")
                    (harness-sandbox-openshell-extra-args (1) "is no list of strings")))
      (cl-progv (list (nth 0 case)) (list (nth 1 case))
        (harness-sandbox-detect)
        (should (string-match-p (nth 2 case) (or (plist-get (harness-call 'sandbox/status) :problem) "")))
        (should (string-match-p (nth 2 case)
                                (cadr (should-error (harness-sandbox--openshell-command
                                                     fake "/tmp/" '("true"))
                                                    :type 'harness-sandbox-unavailable))))))
    (harness-sandbox-detect)
    (should-not (plist-member (harness-call 'sandbox/status) :problem))))

(ert-deftest harness-openshell-uses-the-gateway-the-environment-names ()
  "There is no option for the gateway: the one `openshell' picks, the active one or that
of $OPENSHELL_GATEWAY, is the one every call goes to, the checks of the harness included."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (ignore fake)
      (let ((process-environment (append '("FAKE_OPENSHELL_RUNTIME=none" "OPENSHELL_GATEWAY=work")
                                         process-environment))
            (cwd (harness-test-temp-dir)))
        (unwind-protect
            (progn
              ;; The checks the macro made before the gateway was named are not the test's.
              (delete-file (expand-file-name "calls.log" state))
              (harness-sandbox-detect)
              (should (eql 0 (plist-get (harness-openshell-test--wrap cwd '("true")) :exit)))
              (harness-test-wait (lambda () (harness-openshell-test--ran state "delete")) 10 "the delete")
              (let ((calls (with-temp-buffer
                             (insert-file-contents (expand-file-name "calls.log" state))
                             (mapcar #'harness-json-parse (split-string (buffer-string) "\n" t)))))
                ;; Each of the harness's calls, the probes' and the wrapper's, saw it.
                (should (> (length calls) 5))
                (dolist (call calls)
                  (should (equal "work" (plist-get call :gateway_env))))))
          (delete-directory cwd t))))))

;;;; The policy file

(defmacro harness-openshell-test-with-ids (&rest body)
  "Run BODY as uid 1234 and gid 5678, whoever runs the tests."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'user-uid) (lambda () 1234))
             ((symbol-function 'group-gid) (lambda () 5678)))
     ,@body))

(ert-deftest harness-openshell-policy-says-what-the-session-may-reach ()
  "The policy lists the system paths, the session's directories by mode, and no network."
  (harness-openshell-test--setup)
  (harness-openshell-test-with-ids
    (harness-openshell-test-with-home home
      (ignore home)
      (let* ((cwd (harness-test-temp-dir))
             (granted (harness-test-temp-dir))
             (readable (harness-test-temp-dir))
             (harness-sandbox--openshell-system-paths '(:read-only ("/usr" "/etc") :read-write ("/tmp" "/dev/null")))
             (harness-sandbox-openshell-image-paths '("/opt/emacs/"))
             (harness-sandbox-openshell-network-rules '("github.com:443"))
             (spec (harness-sandbox--openshell-spec cwd :network nil :writable (list granted)
                                                    :readable (list readable))))
        (unwind-protect
            (progn
              (should (equal (concat "# Written by the Emacs agent harness for `openshell sandbox create --policy'.\n"
                                     "# Each command gets the policy of its own directories; nothing to edit here.\n"
                                     "version: 1\n"
                                     "filesystem_policy:\n"
                                     "  include_workdir: false\n"
                                     "  read_only:\n"
                                     "    - \"/usr\"\n"
                                     "    - \"/etc\"\n"
                                     ;; The image's own directory that was named.
                                     "    - \"/opt/emacs\"\n"
                                     (format "    - \"%s\"\n" (directory-file-name readable))
                                     "  read_write:\n"
                                     "    - \"/tmp\"\n"
                                     "    - \"/dev/null\"\n"
                                     (format "    - \"%s\"\n" (directory-file-name granted))
                                     (format "    - \"%s\"\n" (directory-file-name cwd))
                                     "    - \"/tmp/harness-home\"\n"
                                     "landlock:\n"
                                     "  compatibility: hard_requirement\n"
                                     "process:\n"
                                     "  run_as_user: \"1234\"\n"
                                     "  run_as_group: \"5678\"\n")
                             (harness-sandbox--openshell-policy-text spec)))
              ;; The network is off: not a rule, though the option has one.
              (should-not (plist-get spec :rules))
              ;; On, the option's rules are in the policy.
              (let* ((on (harness-sandbox--openshell-spec cwd :readable (list readable)))
                     (text (harness-sandbox--openshell-policy-text on)))
                (should (string-suffix-p (concat "network_policies:\n"
                                                 "  harness_endpoints:\n"
                                                 "    endpoints:\n"
                                                 "      - host: \"github.com\"\n"
                                                 "        port: 443\n"
                                                 "    binaries:\n"
                                                 "      - path: \"/**\"\n")
                                         text)))
              ;; Read-only: nothing but /tmp is writable.
              (let ((text (harness-sandbox--openshell-policy-text
                           (harness-sandbox--openshell-spec cwd :read-only t :writable (list granted)))))
                (should (equal '("/tmp" "/dev/null" "/tmp/harness-home")
                               (harness-openshell-test--policy-list text "read_write")))
                (should (member (directory-file-name cwd) (harness-openshell-test--policy-list text "read_only")))
                (should (member (directory-file-name granted) (harness-openshell-test--policy-list text "read_only")))))
          (dolist (dir (list cwd granted readable)) (delete-directory dir t)))))))

(ert-deftest harness-openshell-policy-options ()
  "Landlock must enforce, the command runs as the host user, and the network rules come from the option."
  (harness-openshell-test--setup)
  (harness-openshell-test-with-home home
    (ignore home)
    (let ((cwd (harness-test-temp-dir)))
      (unwind-protect
          (let ((text (lambda (&rest opts)
                        (harness-sandbox--openshell-policy-text (apply #'harness-sandbox--openshell-spec cwd opts)))))
            ;; A sandbox that cannot enforce the filesystem rules does not start.
            (should (string-match-p "compatibility: hard_requirement" (funcall text)))
            ;; The host user's ids, unless root, or unless left to the image.
            (harness-openshell-test-with-ids
              (should (string-match-p "run_as_user: \"1234\"" (funcall text)))
              (let ((harness-sandbox--openshell-run-as-host-user nil))
                (should-not (string-match-p "process:" (funcall text)))))
            (cl-letf (((symbol-function 'user-uid) (lambda () 0)))
              (should-not (string-match-p "process:" (funcall text))))
            ;; Rules: plain endpoints make one, an entry is a rule, a bad one is left out.
            (let ((harness-sandbox-openshell-network-rules
                   '("registry.npmjs.org:443" "*.example.com:80,443"
                     ("pip" :endpoints ("pypi.org:443" "files.pythonhosted.org:443")
                      :binaries ("/usr/bin/python3.12" "/usr/local/bin/uv"))
                     (git :endpoints ("github.com:443"))
                     "no-port" "host:0" "host:70000" ("bad name" :endpoints ("a.example.com:1"))
                     ("_provider_x" :endpoints ("a.example.com:1")) ("noendpoints") ("b" :endpoints ("x:1") :binaries nil)
                     ("c" :endpoints ("x:1") :binaries ("relative")) 42)))
              (should (equal '("harness_endpoints" "pip" "git") (mapcar #'car (harness-sandbox--openshell-rules))))
              (should (equal '("registry.npmjs.org:443" "*.example.com:80,443" "pypi.org:443"
                               "files.pythonhosted.org:443" "github.com:443")
                             (harness-sandbox--openshell-hosts)))
              (let ((policy (funcall text)))
                (should (string-match-p "        ports: \\[80, 443\\]\n" policy))
                (should (string-match-p "  pip:\n    endpoints:\n      - host: \"pypi.org\"\n" policy))
                (should (string-match-p "      - path: \"/usr/local/bin/uv\"\n" policy))
                (should (string-match-p "  git:\n    endpoints:\n      - host: \"github.com\"\n        port: 443\n    binaries:\n      - path: \"/\\*\\*\"\n"
                                        policy))
                (should-not (string-match-p "bad name\\|_provider_\\|\"host\"\\|relative" policy)))
              ;; A session without the network gets none of it.
              (should-not (string-match-p "network_policies" (funcall text :network nil)))))
        (delete-directory cwd t)))))

(ert-deftest harness-openshell-policy-quotes-what-it-writes ()
  "A path with a quote, a backslash or a tab is written as a YAML string that reads back as it was."
  (should (equal "\"a\\\"b\\\\c\\td\\x07e\"" (harness-sandbox--yaml-string "a\"b\\c\td\ae")))
  (should (equal "\"/home/jürgen/ü\"" (harness-sandbox--yaml-string "/home/jürgen/ü"))))

(ert-deftest harness-openshell-policy-file-is-kept-by-its-content ()
  "Texts that are the same share a file in the state directory, a different one has its own,
a file that was changed is written again, and old ones go."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (let* ((a (harness-sandbox--openshell-policy-file "version: 1\n"))
           (b (harness-sandbox--openshell-policy-file "version: 1\n"))
           (c (harness-sandbox--openshell-policy-file "version: 1\n# c\n"))
           (old (expand-file-name "policy-old.yaml" (file-name-directory a))))
      (should (equal a b))
      (should-not (equal a c))
      (should (string-prefix-p (expand-file-name "openshell/" harness-state-directory) a))
      (should (= #o600 (file-modes a)))
      (should (= #o700 (file-modes (file-name-directory a))))
      (should (equal "version: 1\n" (with-temp-buffer (insert-file-contents a) (buffer-string))))
      ;; Changed behind our back: written as it should be again.
      (with-temp-file a (insert "version: 1\nprocess: {run_as_user: \"0\"}\n"))
      (should (equal a (harness-sandbox--openshell-policy-file "version: 1\n")))
      (should (equal "version: 1\n" (with-temp-buffer (insert-file-contents a) (buffer-string))))
      ;; A link in its place is not followed.
      (delete-file a)
      (make-symbolic-link "/etc/hostname" a)
      (should (equal a (harness-sandbox--openshell-policy-file "version: 1\n")))
      (should-not (file-symlink-p a))
      ;; A file nobody asked for in a week goes when another is written.
      (with-temp-file old (insert "old\n"))
      (set-file-times old (time-subtract nil (* 8 24 60 60)))
      (harness-sandbox--openshell-policy-file "version: 1\n# d\n")
      (should-not (file-exists-p old))
      (should (file-exists-p a)))))

;;;; The mounts

(ert-deftest harness-openshell-mounts-show-the-directories-as-bwrap-does ()
  "The working directory and the grants are read-write mounts at their own path,
what is readable is read-only, $HOME is a tmpfs, and the real home's directories show under it."
  (harness-openshell-test--setup)
  (harness-openshell-test-with-home home
    (let* ((cwd (harness-test-temp-dir))
           (granted (harness-test-temp-dir))
           (readable (harness-test-temp-dir))
           (skills (expand-file-name ".claude/skills/" home))
           (cwd-bind (directory-file-name cwd))
           (extra (harness-test-temp-dir))
           ;; This machine's toolchain directories mean nothing to an image.
           (harness-sandbox-extra-read-only-dirs (list extra "/nonexistent/harness-test"))
           (unshown '("/usr" "/etc/openshell" "/opt/openshell/bin" "/proc/self" "/dev/shm" "/"
                      "/run/netns" "/sys")))
      (make-directory skills t)
      (unwind-protect
          (progn
            (should (equal `((,(directory-file-name readable) ,(directory-file-name readable) ro)
                             (,(directory-file-name skills) ,(directory-file-name skills) ro)
                             (,(concat harness-sandbox--home "/.claude/skills") ,(directory-file-name skills) ro)
                             (,(directory-file-name granted) ,(directory-file-name granted) rw)
                             (,cwd-bind ,cwd-bind rw)
                             (,harness-sandbox--home nil tmpfs))
                           (harness-sandbox--openshell-mounts cwd (list readable skills) (list granted) nil nil)))
            ;; Read-only: nothing is writable, the working directory and the grants too.
            (should (equal '(ro ro ro ro ro tmpfs)
                           (mapcar #'caddr (harness-sandbox--openshell-mounts
                                            cwd (list readable skills) (list granted) t nil))))
            ;; A home inside the working directory is shown as it is: no tmpfs.
            (let ((process-environment (cons (concat "HOME=" cwd-bind "/home") process-environment)))
              (should-not (cl-find 'tmpfs (harness-sandbox--openshell-mounts cwd nil nil nil nil) :key #'caddr))
              (should (equal (concat cwd-bind "/home")
                             (cdr (assoc "HOME" (plist-get (harness-sandbox--openshell-spec cwd) :env))))))
            ;; What OpenShell keeps for itself, or would refuse, is not asked for.
            (should (equal `((,cwd-bind ,cwd-bind rw) (,harness-sandbox--home nil tmpfs))
                           (harness-sandbox--openshell-mounts cwd (list "/usr") unshown nil nil)))
            (dolist (target '("/etc" "/opt" "/run" "/proc" "relative" "/a//b" "/a/../b" "/a\nb"))
              (should (harness-sandbox--openshell-target-problem target)))
            (dolist (target '("/etc/ssl" "/opt/tools" "/home/x" "/tmp/harness-home" "/var/run/other"))
              (should-not (harness-sandbox--openshell-target-problem target))))
        (dolist (dir (list cwd granted readable extra)) (delete-directory dir t))))))

(ert-deftest harness-openshell-mounts-follow-links-and-do-not-repeat ()
  "A directory shown by a link is mounted at the link's path and the real one; no target twice."
  (harness-openshell-test--setup)
  (harness-openshell-test-with-home home
    (ignore home)
    (let* ((base (harness-test-temp-dir))
           (real (expand-file-name "real" base))
           (link (expand-file-name "link" base))
           (cwd (expand-file-name "cwd" base)))
      (make-directory real)
      (make-directory cwd)
      (make-symbolic-link real link)
      (unwind-protect
          (let* ((real-name (directory-file-name (file-truename real)))
                 (mounts (harness-sandbox--openshell-mounts cwd (list link real) (list link) nil nil)))
            (should (equal (sort (list real-name (directory-file-name link)) #'string<)
                           (cl-loop for (target source mode) in mounts
                                    when (and (eq mode 'rw) (equal source real-name)) collect target into targets
                                    finally return (sort targets #'string<))))
            (should (equal (mapcar #'car mounts) (delete-dups (mapcar #'car mounts)))))
        (delete-directory base t)))))

(ert-deftest harness-openshell-mounts-show-a-worktrees-git-directory ()
  "A linked worktree's git directory is a read-write mount, its hooks, config, index and HEAD
read-only in it; read-only, the whole of it is read-only; git has the commit identity."
  (harness-openshell-test--setup)
  (skip-unless (executable-find "git"))
  (harness-openshell-test-with-home home
    (ignore home)
    (let* ((repo (let ((base (harness-test-temp-dir)))
                   (let ((root (expand-file-name "repo/" base)) (wt (expand-file-name "wt/" base)))
                     (make-directory root t)
                     (dolist (args '(("init" "-q" "-b" "main") ("config" "user.name" "Sandbox Test")
                                     ("config" "user.email" "sandbox@example.invalid") ("config" "commit.gpgsign" "false")))
                       (let ((default-directory root)) (apply #'call-process "git" nil nil nil args)))
                     (with-temp-file (expand-file-name "README" root) (insert "hi\n"))
                     (let ((default-directory root))
                       (call-process "git" nil nil nil "add" "README")
                       (call-process "git" nil nil nil "commit" "-q" "-m" "initial")
                       (call-process "git" nil nil nil "worktree" "add" "-q" "-b" "work" wt))
                     (cons root wt))))
           (wt (cdr repo))
           (common (directory-file-name (file-truename (expand-file-name ".git" (car repo)))))
           (mounts (lambda (&rest opts) (apply #'harness-sandbox--openshell-mounts wt nil nil opts))))
      (unwind-protect
          (let ((by-target (lambda (mounts) (mapcar (lambda (m) (cons (car m) (caddr m))) mounts))))
            (let ((shown (funcall by-target (funcall mounts nil nil))))
              (should (eq 'rw (cdr (assoc common shown))))
              (dolist (name '("hooks" "config" "index" "HEAD"))
                (should (eq 'ro (cdr (assoc (concat common "/" name) shown))))))
            (let ((shown (funcall by-target (funcall mounts t nil))))
              (should (eq 'ro (cdr (assoc common shown))))
              (should-not (assoc (concat common "/hooks") shown)))
            (let ((env (plist-get (harness-sandbox--openshell-spec wt) :env)))
              (should (equal "Sandbox Test" (cdr (assoc "GIT_AUTHOR_NAME" env))))
              (should (equal "sandbox@example.invalid" (cdr (assoc "GIT_COMMITTER_EMAIL" env))))))
        (delete-directory (file-name-directory (directory-file-name (car repo))) t)))))

(ert-deftest harness-openshell-mounts-show-scratch-directories-last-and-writable ()
  "A scratch directory is writable whatever :read-only says, as under bwrap."
  (harness-openshell-test--setup)
  (harness-openshell-test-with-home home
    (ignore home)
    (let ((cwd (harness-test-temp-dir)) (scratch (harness-test-temp-dir)))
      (unwind-protect
          (dolist (read-only '(nil t))
            (let ((mounts (harness-sandbox--openshell-mounts cwd nil nil read-only (list scratch))))
              (should (eq 'rw (caddr (assoc (directory-file-name scratch) mounts))))
              (should (eq (if read-only 'ro 'rw) (caddr (assoc (directory-file-name cwd) mounts))))
              (should (member (directory-file-name scratch)
                              (harness-openshell-test--policy-list
                               (harness-sandbox--openshell-policy-text
                                (harness-sandbox--openshell-spec cwd :read-only read-only :scratch (list scratch)))
                               "read_write")))))
        (delete-directory cwd t)
        (delete-directory scratch t)))))

;;;; The command line

(ert-deftest harness-openshell-command-line ()
  "The wrapper gets the program, a name, the arguments of `sandbox create'
and those of `sandbox exec', with the command last."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-home home
      (let* ((cwd (harness-test-temp-dir))
             (granted (harness-test-temp-dir))
             (harness-sandbox-openshell-image "registry.example.com/team/dev:1.0")
             (harness-sandbox-openshell-extra-args '("--cpu" "2" "--memory" "4Gi"))
             (harness-sandbox--openshell-ttl 4000)
             (process-environment (append '("LANG=C.UTF-8" "TZ=UTC" "LC_ALL=") process-environment))
             (command '("bash" "-c" "echo $HOME; exit 3"))
             (cmd (harness-sandbox--openshell-command "/usr/bin/openshell" cwd command
                                                      :writable (list granted) :network nil)))
        (unwind-protect
            (progn
              (should (string-suffix-p "bash" (car cmd)))
              (should (equal harness-sandbox--openshell-script (nth 2 cmd)))
              (should (equal "/usr/bin/openshell" (nth 4 cmd)))
              (should (string-match-p "\\`harness-[0-9]+-[a-z0-9]\\{8\\}\\'" (nth 5 cmd)))
              (let ((create (harness-openshell-test--create-args cmd)))
                (should (equal (number-to-string (length create)) (nth 6 cmd)))
                (should (equal '("--detach" "--no-keep" "--no-tty" "--no-auto-providers"
                                 "--label" "harness=emacs-agent-harness")
                               (seq-take create 6)))
                (should (string-prefix-p (expand-file-name "openshell/" harness-state-directory)
                                         (harness-openshell-test--word-after "--policy" create)))
                (should (equal "registry.example.com/team/dev:1.0"
                               (harness-openshell-test--word-after "--from" create)))
                (should (equal '("--cpu" "2" "--memory" "4Gi" "--" "sleep" "4000") (last create 7)))
                (should (harness-openshell-test--config cmd)))
              (let ((exec (harness-openshell-test--exec-args cmd)))
                (should (equal '("--no-tty" "--no-login-shell" "--workdir") (seq-take exec 3)))
                (should (equal (directory-file-name cwd) (nth 3 exec)))
                (should (equal (append '("--") command) (last exec 4)))
                (let ((env (cl-loop for (flag value) on exec by #'cddr
                                    when (equal flag "--env") collect value)))
                  (should (equal `("HARNESS_SANDBOX=openshell" ,(concat "HOME=" harness-sandbox--home)
                                   "LANG=C.UTF-8" "TZ=UTC")
                                 env))))
              ;; A name of its own for each.
              (should-not (equal (nth 5 cmd)
                                 (nth 5 (harness-sandbox--openshell-command "/usr/bin/openshell" cwd command)))))
          (dolist (dir (list cwd granted)) (delete-directory dir t)))))))

(ert-deftest harness-openshell-command-without-options ()
  "With no image of its own, none is passed, and the default time to live is the one that outlasts a command."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-home home
      (ignore home)
      (let* ((cwd (harness-test-temp-dir))
             (cmd (harness-sandbox--openshell-command "openshell" cwd '("true") :read-only t)))
        (unwind-protect
            (let ((create (harness-openshell-test--create-args cmd)))
              ;; The bash tool's longest command is 3600 seconds.
              (should (> harness-sandbox--openshell-ttl 3600))
              (should-not (member "--from" create))
              (should (equal '("--" "sleep" "3900") (last create 3)))
              (should (equal "podman" (car (mapcar (lambda (key) (string-remove-prefix ":" (symbol-name key)))
                                                   (list (car (let ((harness-sandbox-openshell-driver 'podman))
                                                                (harness-json-parse
                                                                 (harness-sandbox--openshell-driver-config
                                                                  (harness-sandbox--openshell-spec cwd))))))))))
              (should (equal `((,(directory-file-name cwd) ,(directory-file-name cwd) ro)
                               (,harness-sandbox--home nil tmpfs))
                             (harness-openshell-test--mounts cmd))))
          (delete-directory cwd t))))))

(ert-deftest harness-openshell-refuses-what-the-gateway-would ()
  "A command with an argument too long for the gateway is refused here, saying so, before any sandbox starts."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-home home
      (ignore home)
      (let* ((cwd (harness-test-temp-dir))
             (long (make-string (1+ harness-sandbox--openshell-max-argument) ?x))
             (err (should-error (harness-sandbox--openshell-command "openshell" cwd (list "bash" "-c" long))
                                :type 'harness-sandbox-unavailable)))
        (should (string-match-p "32769 bytes is longer than the 32768 bytes the gateway runs" (cadr err)))
        (should (string-match-p "put it in a file" (cadr err)))
        ;; The limit is in bytes: this is 16385 characters of two.
        (should-error (harness-sandbox--openshell-command
                       "openshell" cwd (list "bash" "-c" (make-string 16385 ?é)))
                      :type 'harness-sandbox-unavailable)
        (should (harness-sandbox--openshell-command
                 "openshell" cwd (list "bash" "-c" (make-string harness-sandbox--openshell-max-argument ?x))))
        ;; A policy lists 256 paths at most.
        (let* ((base (harness-test-temp-dir))
               (many (cl-loop for i below 260
                              collect (let ((dir (expand-file-name (format "d%d" i) base)))
                                        (make-directory dir)
                                        dir)))
               (err (should-error (harness-sandbox--openshell-command "openshell" cwd '("true") :readable many)
                                  :type 'harness-sandbox-unavailable)))
          (should (string-match-p "would list 2[0-9][0-9] paths, and OpenShell takes at most 256" (cadr err)))
          (should (harness-sandbox--openshell-command "openshell" cwd '("true") :readable (seq-take many 200)))
          (delete-directory base t))
        (delete-directory cwd t)))))

(ert-deftest harness-openshell-drops-environment-it-cannot-pass ()
  "A variable the gateway would refuse is left out of the command's environment, not sent."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-home home
      (ignore home)
      (let* ((cwd (harness-test-temp-dir))
             (process-environment (append (list "LANG=en\nUS" (concat "TZ=" (make-string 33000 ?x)) "LANGUAGE=en")
                                          process-environment))
             (cmd (harness-sandbox--openshell-command "openshell" cwd '("true")))
             (env (cl-loop for (flag value) on (harness-openshell-test--exec-args cmd) by #'cddr
                           when (equal flag "--env") collect value)))
        (should (equal `("HARNESS_SANDBOX=openshell" ,(concat "HOME=" harness-sandbox--home) "LANGUAGE=en") env))
        (delete-directory cwd t)))))

;;;; The methods

(ert-deftest harness-openshell-wrap-and-the-policy ()
  "`sandbox/wrap' gives the wrapper when OpenShell is the backend, and leaves a command alone
where the policy says, or the directory is remote."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (ignore state)
      (let ((cwd (harness-test-temp-dir)))
        (unwind-protect
            (progn
              (let ((cmd (harness-call 'sandbox/wrap cwd '("true"))))
                (should (equal fake (nth 4 cmd)))
                (should (equal '("true") (last cmd))))
              (should (eq t (harness-call 'sandbox/confined-p cwd)))
              (should-not (harness-call 'sandbox/confined-p "/ssh:example.invalid:/srv/"))
              (let ((harness-sandbox-policy 'off))
                (should (equal '("true") (harness-call 'sandbox/wrap cwd '("true"))))
                (should-error (harness-call 'sandbox/wrap cwd '("true") :read-only t)
                              :type 'harness-sandbox-unavailable)
                (should-not (harness-call 'sandbox/confined-p cwd)))
              ;; A remote directory is never wrapped.
              (should (equal '("true") (harness-call 'sandbox/wrap "/ssh:example.invalid:/srv/" '("true"))))
              (should-error (harness-call 'sandbox/wrap "/ssh:example.invalid:/srv/" '("true") :read-only t)
                            :type 'harness-sandbox-unavailable)
              ;; The access model reaches the command line.
              (let ((cmd (harness-call 'sandbox/wrap cwd '("true") :read-only t :network nil)))
                (should (eq 'ro (caddr (assoc (directory-file-name cwd) (harness-openshell-test--mounts cmd)))))
                (should-not (string-match-p "network_policies" (harness-openshell-test--policy cmd)))))
          (delete-directory cwd t))))))

(ert-deftest harness-openshell-gives-no-capability ()
  "OpenShell cannot give a command a capability: wrapping one that asks signals, and the jail says why."
  (harness-openshell-test--setup)
  (harness-openshell-test-with-fake (fake state)
    (ignore fake state)
    (let ((err (should-error (harness-call 'sandbox/wrap "/tmp/" '("true") :capabilities '("CAP_SYS_PTRACE"))
                             :type 'harness-sandbox-unavailable)))
      (should (string-match-p "CAP_SYS_PTRACE" (cadr err)))
      (should (string-match-p "OpenShell runs commands as a non-root user with no Linux capability" (cadr err))))
    ;; A read-only command is given none, so there is nothing to refuse.
    (should (harness-call 'sandbox/wrap "/tmp/" '("true") :capabilities '("CAP_SYS_PTRACE") :read-only t))
    (let ((info (harness-call 'sandbox/capabilities "/tmp/")))
      (should-not (plist-get info :enforced))
      (should (eq 'openshell (plist-get info :backend)))
      (should (string-match-p "backend is OpenShell, not bwrap, and it runs commands as a non-root user"
                              (plist-get info :why)))
      (should (plist-get info :grantable)))))

(ert-deftest harness-openshell-status-lists-its-limits ()
  "`sandbox/status' says what the backend in use cannot do of the access model."
  (harness-openshell-test--setup)
  (harness-openshell-test-with-fake (fake state)
    (ignore fake state)
    (let* ((limits (plist-get (harness-call 'sandbox/status) :limits))
           (text (string-join limits "\n")))
      (should (string-match-p "No Linux capability can be given" text))
      (should (string-match-p "network is never open.*harness-sandbox-openshell-network-rules lists none" text))
      (should (string-match-p "gateway's default image" text))
      (should (string-match-p "32768 bytes" text))
      (should (string-match-p "bind mounts" text))
      (let ((harness-sandbox-openshell-network-rules '("github.com:443" "pypi.org:443"))
            (harness-sandbox-openshell-image "dev:1"))
        (let ((text (string-join (plist-get (harness-call 'sandbox/status) :limits) "\n")))
          (should (string-match-p "reaches only github.com:443, pypi.org:443" text))
          (should (string-match-p "the image dev:1" text))))))
  ;; The others say theirs, or have none.
  (harness-openshell-test-with-executables '(("bwrap" . "/usr/bin/bwrap"))
    (let ((harness-sandbox-backend 'auto))
      (harness-sandbox-detect)
      (should (eq 'bwrap (plist-get (harness-call 'sandbox/status) :backend)))
      (should-not (plist-get (harness-call 'sandbox/status) :limits))))
  (harness-openshell-test-with-executables '(("systemd-run" . "/usr/bin/systemd-run"))
    (let ((harness-sandbox-backend 'auto))
      (harness-sandbox-detect)
      (should (cl-some (lambda (line) (string-match-p "systemd --user unit" line))
                       (plist-get (harness-call 'sandbox/status) :limits)))))
  (harness-sandbox-detect))

;;;; Through the stand-in

(ert-deftest harness-openshell-runs-a-command-through-the-stand-in ()
  "A command runs in its own sandbox: its output, standard error and exit status come back
as they are, with none of what `sandbox create' prints, in its directory, with its environment;
the sandbox is deleted afterwards."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (let ((process-environment (cons "FAKE_OPENSHELL_RUNTIME=none" process-environment))
            (cwd (harness-test-temp-dir)))
        (unwind-protect
            (let ((r (harness-openshell-test--wrap
                      cwd '("bash" "-c" "pwd; echo \"sandbox=$HARNESS_SANDBOX home=$HOME\"; printf 'a b\\n'; echo oops >&2; exit 7"))))
              (should (eql 7 (plist-get r :exit)))
              (should (equal (list (directory-file-name cwd)
                                   (concat "sandbox=openshell home=" harness-sandbox--home)
                                   "a b")
                             (split-string (plist-get r :stdout) "\n" t)))
              (should (equal "oops\n" (plist-get r :stderr)))
              ;; Made for it alone, run in, deleted: in that order.
              (harness-test-wait (lambda () (harness-openshell-test--ran state "delete")) 10
                                 "the sandbox to be deleted")
              (let ((calls (append (harness-openshell-test--ran state "create")
                                   (harness-openshell-test--ran state "exec")
                                   (harness-openshell-test--ran state "delete"))))
                (should (equal '("create" "exec" "delete") (mapcar #'cadr calls)))
                (should (equal (nth 3 (nth 0 calls)) (nth 3 (nth 1 calls))))
                (should (equal (nth 3 (nth 0 calls)) (nth 2 (nth 2 calls)))))
              (should-not (harness-openshell-test--sandboxes state))
              ;; Each command has a sandbox of its own, and standard input is the command's.
              (let ((names nil))
                (dotimes (_ 2)
                  (harness-openshell-test--wrap cwd '("true"))
                  (push (nth 3 (car (last (harness-openshell-test--ran state "create")))) names))
                (should-not (equal (car names) (cadr names)))))
          (delete-directory cwd t))))))

(ert-deftest harness-openshell-passes-the-command-through-the-shell-whole ()
  "What the gateway does to a command's words, quoting them for the shell, keeps them as they are."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (ignore fake state)
      (let ((process-environment (cons "FAKE_OPENSHELL_RUNTIME=none" process-environment))
            (cwd (harness-test-temp-dir))
            (words (list "it's" "two words" "$HOME" "back\\slash" "" "*" "\"q\"" "`x`" "new\nline" "a'b'c")))
        (unwind-protect
            (let ((r (harness-openshell-test--wrap cwd (append '("printf" "%s|") words))))
              (should (eql 0 (plist-get r :exit)))
              (should (equal (concat (mapconcat #'identity words "|") "|") (plist-get r :stdout))))
          (delete-directory cwd t))))))

(ert-deftest harness-openshell-says-why-no-sandbox-started ()
  "When the sandbox cannot be made, the command does not run, and standard error says
what the gateway said; status 125."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (ignore fake)
      (let ((process-environment (append '("FAKE_OPENSHELL_RUNTIME=none"
                                           "FAKE_OPENSHELL_CREATE_FAIL=docker bind mounts require enable_bind_mounts = true")
                                         process-environment))
            (cwd (harness-test-temp-dir)))
        (unwind-protect
            (let ((r (harness-openshell-test--wrap cwd '("sh" "-c" "touch ran"))))
              (should (eql 125 (plist-get r :exit)))
              (should (string-match-p "could not start a sandbox for this command (openshell exited 1)"
                                      (plist-get r :stderr)))
              (should (string-match-p "docker bind mounts require enable_bind_mounts = true" (plist-get r :stderr)))
              (should (equal "" (plist-get r :stdout)))
              (should-not (file-exists-p (expand-file-name "ran" cwd)))
              ;; No sandbox is left, and none was run in.
              (should-not (harness-openshell-test--ran state "exec"))
              (harness-test-wait (lambda () (harness-openshell-test--ran state "delete"))
                                 10 "a delete of the half-made sandbox"))
          (delete-directory cwd t))))))

(ert-deftest harness-openshell-deletes-the-sandbox-of-a-command-that-is-killed ()
  "A command killed at its timeout loses its sandbox: the delete is made, and nothing it started stays."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (ignore fake)
      (let* ((process-environment (cons "FAKE_OPENSHELL_RUNTIME=none" process-environment))
             (harness--process-kill-grace 0.3)
             ;; A duration no other process sleeps for names this one.
             (marker (format "300.%06d%d" (random 1000000) (emacs-pid)))
             (running (lambda ()
                        (cl-some (lambda (pid)
                                   (member marker (split-string
                                                   (or (alist-get 'args (process-attributes pid)) ""))))
                                 (list-system-processes))))
             (cwd (harness-test-temp-dir)))
        (unwind-protect
            (let* ((cmd (harness-call 'sandbox/wrap cwd (list "sh" "-c" (format "touch started; exec sleep %s" marker))))
                   (start (float-time))
                   (r (harness-await (harness-run-command cmd :cwd cwd :timeout 3) 20)))
              (should (eq 'timeout (plist-get r :exit)))
              (should (< (- (float-time) start) 15))
              (should (file-exists-p (expand-file-name "started" cwd)))
              (harness-test-wait (lambda () (and (null (harness-openshell-test--sandboxes state))
                                                 (not (funcall running))))
                                 10 "the sandbox to be deleted and the command to end")
              (should (harness-openshell-test--ran state "delete")))
          (delete-directory cwd t))))))

(ert-deftest harness-openshell-delete-does-not-need-the-commands-directory ()
  "The delete the wrapper leaves running in the background does not depend on the
command's directory, which the caller may remove the moment the command ends.
(A throwaway directory removed right after the command did exactly that, and the
sandbox was left behind, until the delete went on from /.)"
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (ignore fake)
      ;; The program asks for its directory a moment after it starts: too late for one removed at once.
      (let ((process-environment (append '("FAKE_OPENSHELL_RUNTIME=none" "FAKE_OPENSHELL_NEED_CWD=0.4")
                                         process-environment))
            (cwd (harness-test-temp-dir)))
        (harness-sandbox-detect)
        (let ((r (harness-openshell-test--wrap cwd '("true"))))
          (delete-directory cwd t)
          (should (eql 0 (plist-get r :exit))))
        (harness-test-wait (lambda () (and (harness-openshell-test--ran state "delete")
                                           (null (harness-openshell-test--sandboxes state))))
                           10 "the delete, which the directory's removal must not stop")))))

(ert-deftest harness-openshell-does-not-wait-for-the-delete ()
  "The command's result does not wait for the sandbox to be deleted, which goes on in the background."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (ignore fake)
      (let ((process-environment (append '("FAKE_OPENSHELL_RUNTIME=none" "FAKE_OPENSHELL_DELETE_DELAY=3")
                                         process-environment))
            (cwd (harness-test-temp-dir)))
        (unwind-protect
            (let* ((start (float-time))
                   (r (harness-openshell-test--wrap cwd '("true"))))
              (should (eql 0 (plist-get r :exit)))
              (should (< (- (float-time) start) 2.8))
              (harness-test-wait (lambda () (null (harness-openshell-test--sandboxes state))) 15
                                 "the slow delete to finish"))
          (delete-directory cwd t))))))

;;;; What a command can reach

(defun harness-openshell-test--confines ()
  "Check that a command in an OpenShell sandbox reaches what its access allows, and no more.
It uses the backend as it is set: the stand-in running in bwrap, or a real
OpenShell.  Skips the test when no sandbox can be made."
  (let* ((cwd (harness-test-temp-dir))
         (granted (harness-test-temp-dir))
         (readable (harness-test-temp-dir))
         (outside (harness-test-temp-dir))
         (server (harness-test-http-serve nil))
         (port (process-contact server :service))
         (script (format "echo cwd-here; pwd; echo x > in-cwd && echo cwd-written || echo cwd-refused
echo x > %s/g && echo granted-written || echo granted-refused
echo x > %s/r 2>/dev/null && echo readable-written || echo readable-refused
cat %s/seen.txt
echo x > %s/o 2>/dev/null && echo outside-written || echo outside-refused
ls %s >/dev/null 2>&1 && echo outside-listed || echo outside-hidden
echo sandbox=$HARNESS_SANDBOX
(exec 3<>/dev/tcp/127.0.0.1/%d) 2>/dev/null && echo online || echo offline"
                         granted readable readable outside outside port)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "seen.txt" readable) (insert "seen\n"))
          (let ((probe (harness-openshell-test--wrap cwd '("true"))))
            (unless (eql 0 (plist-get probe :exit))
              (ert-skip (format "OpenShell cannot run a sandbox here: %s"
                                (string-trim (plist-get probe :stderr))))))
          (let ((r (harness-openshell-test--wrap cwd (list "bash" "-c" script)
                                                 :writable (list granted) :readable (list readable))))
            (should (eql 0 (plist-get r :exit)))
            (should (equal (list "cwd-here" (directory-file-name cwd) "cwd-written" "granted-written"
                                 "readable-refused" "seen" "outside-refused" "outside-hidden"
                                 "sandbox=openshell" "offline")
                           (split-string (plist-get r :stdout) "\n" t)))
            (should (file-exists-p (expand-file-name "in-cwd" cwd)))
            (should (file-exists-p (expand-file-name "g" granted)))
            (should-not (file-exists-p (expand-file-name "r" readable)))
            (should-not (file-exists-p (expand-file-name "o" outside))))
          ;; Read-only: nothing but /tmp is writable, a directory granted writable included.
          (let ((r (harness-openshell-test--wrap
                    cwd (list "bash" "-c" "echo x > ro-cwd 2>/dev/null && echo cwd-written || echo cwd-refused
echo x > /tmp/scratch && echo tmp-written || echo tmp-refused")
                    :read-only t :network nil :writable (list granted))))
            (should (equal '("cwd-refused" "tmp-written") (split-string (plist-get r :stdout) "\n" t)))
            (should-not (file-exists-p (expand-file-name "ro-cwd" cwd)))))
      (delete-process server)
      (dolist (dir (list cwd granted readable outside)) (delete-directory dir t)))))

(ert-deftest harness-openshell-stand-in-confines-the-command ()
  "In what the stand-in builds from the mounts and the policy, a command reaches its
directories as the access model says, and the network not at all."
  (harness-openshell-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (ignore fake state)
      (harness-openshell-test--confines))))

(ert-deftest harness-openshell-stand-in-shows-the-session-home ()
  "$HOME is a private directory a command writes, with the real home's directories shown under it."
  (harness-openshell-test--setup)
  (skip-unless (executable-find "bwrap"))
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (ignore fake state)
      (harness-openshell-test-with-home home
        (let* ((cwd (harness-test-temp-dir))
               (skills (expand-file-name ".claude/skills/" home))
               (secret (expand-file-name "secret.txt" home)))
          (make-directory skills t)
          (with-temp-file (expand-file-name "SKILL.md" skills) (insert "skill\n"))
          (with-temp-file secret (insert "must not show\n"))
          (unwind-protect
              (let ((probe (harness-openshell-test--wrap cwd '("true"))))
                (unless (eql 0 (plist-get probe :exit))
                  (ert-skip (format "OpenShell cannot run a sandbox here: %s" (string-trim (plist-get probe :stderr)))))
                (let ((r (harness-openshell-test--wrap
                          cwd (list "bash" "-c" (format "echo HOME=$HOME; cat ~/.claude/skills/SKILL.md; cat %s/SKILL.md; cat %s 2>/dev/null || echo secret-hidden; echo x > ~/cache && echo home-written"
                                                        (shell-quote-argument (directory-file-name skills))
                                                        (shell-quote-argument secret)))
                          :readable (list skills))))
                  (should (equal (list (concat "HOME=" harness-sandbox--home) "skill" "skill" "secret-hidden" "home-written")
                                 (split-string (plist-get r :stdout) "\n" t)))
                  (should-not (file-exists-p (expand-file-name "cache" home)))))
            (delete-directory cwd t)))))))

(ert-deftest harness-openshell-stand-in-checks-what-the-gateway-checks ()
  "The stand-in is strict as the gateway is: a policy that breaks the schema, a mount it
refuses, or one the policy does not allow, fails the creation, and standard error says which."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (ignore state)
      (let ((cwd (harness-test-temp-dir))
            (process-environment (cons "FAKE_OPENSHELL_RUNTIME=none" process-environment)))
        (unwind-protect
            (cl-flet ((create (&rest changes)
                        ;; `sandbox create' as the wrapper makes it, with CHANGES applied to its arguments.
                        (let* ((cmd (harness-call 'sandbox/wrap cwd '("true")))
                               (args (harness-openshell-test--create-args cmd))
                               (args (cl-loop for (flag . fn) in changes
                                              do (setq args (funcall fn args))
                                              finally return args)))
                          (with-temp-buffer
                            (let ((status (apply #'call-process fake nil t nil
                                                 "sandbox" "create" "--name"
                                                 (format "t-%s" (harness-short-id 6)) args)))
                              (cons status (buffer-string)))))))
              (should (eql 0 (car (create))))
              ;; A mount the policy does not list.
              (let ((r (create (cons "--policy"
                                     (lambda (args)
                                       (let ((policy (make-temp-file "policy-" nil ".yaml")))
                                         (with-temp-file policy
                                           (insert "version: 1\nfilesystem_policy:\n  include_workdir: false\n  read_only:\n    - \"/usr\"\n"))
                                         (setcar (cdr (member "--policy" args)) policy)
                                         args))))))
                (should (eql 1 (car r)))
                (should (string-match-p "the policy does not allow" (cdr r))))
              ;; A mount of OpenShell's own path.
              (let ((r (create (cons "--driver-config-json"
                                     (lambda (args)
                                       (setcar (cdr (member "--driver-config-json" args))
                                               "{\"docker\":{\"mounts\":[{\"type\":\"bind\",\"source\":\"/usr\",\"target\":\"/etc/openshell\",\"read_only\":true}]}}")
                                       args)))))
                (should (eql 1 (car r)))
                (should (string-match-p "conflicts with reserved OpenShell path" (cdr r)))))
          (delete-directory cwd t))))))

;;;; The check command

(ert-deftest harness-openshell-check-runs-a-throwaway-sandbox ()
  "`harness-sandbox-openshell-check' makes a sandbox, runs a command in it, and says how it went."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (ignore fake)
      (let ((process-environment (cons "FAKE_OPENSHELL_RUNTIME=none" process-environment)))
        (let ((r (harness-await (harness-sandbox-openshell-check) 60)))
          (should (plist-get r :ok))
          (should (string-match-p "ran a command in it" (plist-get r :message))))
        (should (harness-openshell-test--ran state "create"))
        (harness-test-wait (lambda () (null (harness-openshell-test--sandboxes state))) 10 "the delete")
        ;; A gateway that refuses it: the check says what it said.
        (let ((process-environment (cons "FAKE_OPENSHELL_CREATE_FAIL=driver config is disabled" process-environment)))
          (let ((r (harness-await (harness-sandbox-openshell-check) 60)))
            (should-not (plist-get r :ok))
            (should (string-match-p "driver config is disabled" (plist-get r :message)))))))))

(ert-deftest harness-openshell-detect-and-check-are-methods ()
  "A UI that is no part of the harness's process looks for the backends again with
`sandbox/detect' and tries OpenShell with `sandbox/check'."
  (harness-openshell-test--setup)
  (harness-test-with-temp-state
    (harness-openshell-test-with-fake (fake state)
      (ignore fake state)
      ;; The gateway is down when the backend is chosen, and up when it is asked again.
      (let ((process-environment (cons "FAKE_OPENSHELL_STATUS=disconnected" process-environment)))
        (harness-sandbox-detect))
      (should (eq 'openshell (plist-get (harness-call 'sandbox/status) :requested)))
      (let ((status (harness-call 'sandbox/detect)))
        (should (eq 'openshell (plist-get status :backend)))
        (should-not (plist-member status :requested))
        (should (plist-get status :limits)))
      ;; Asked again and still down: it says why, and the backend is another.
      (let ((process-environment (cons "FAKE_OPENSHELL_STATUS=not_configured" process-environment)))
        (let ((status (harness-call 'sandbox/detect)))
          (should (eq 'openshell (plist-get status :requested)))
          (should (string-match-p "no OpenShell gateway is registered" (plist-get status :problem)))
          (should-not (eq 'openshell (plist-get status :backend)))))
      ;; The check is a promise of what `harness-sandbox-openshell-check' says.
      (harness-sandbox-detect)
      (let ((process-environment (cons "FAKE_OPENSHELL_RUNTIME=none" process-environment)))
        (let ((r (harness-await (harness-call 'sandbox/check) 60)))
          (should (eq t (plist-get r :ok)))
          (should (string-match-p "ran a command in it" (plist-get r :message)))))
      ;; Without the program it answers at once, and does not signal.
      (let ((harness-sandbox-openshell-program "harness-test-no-such-openshell"))
        (let ((r (harness-await (harness-call 'sandbox/check) 10)))
          (should (eq :false (plist-get r :ok)))
          (should (string-match-p "harness-test-no-such-openshell .* is not installed" (plist-get r :message))))))))

;;;; A real OpenShell

(defun harness-openshell-test--real ()
  "Return the real openshell program when a gateway of it answers, or skip the test.
It must be on the exec path, not the stand-in, and `harness-sandbox--openshell-problem'
must find nothing wrong with it."
  (let ((program (executable-find "openshell")))
    (unless program (ert-skip "no openshell on the exec path"))
    (when-let* ((problem (harness-sandbox--openshell-problem program)))
      (ert-skip (format "OpenShell cannot be used here: %s" problem)))
    program))

(ert-deftest harness-openshell-real-run-confines ()
  "Under a real OpenShell a command writes the directories it was given, and no other,
reads nothing the sandbox does not show, and reaches no network.
It needs a gateway that allows bind mounts (docs/openshell.md), and skips without."
  (harness-openshell-test--setup)
  (skip-unless (executable-find "openshell"))
  (harness-test-with-temp-state
    (let ((harness-sandbox-openshell-program (harness-openshell-test--real))
          (harness-sandbox-backend 'openshell)
          (harness-sandbox-policy 'required))
      (unwind-protect
          (progn
            (harness-sandbox-detect)
            (skip-unless (eq 'openshell (plist-get (harness-call 'sandbox/status) :backend)))
            (harness-openshell-test--confines))
        (harness-sandbox-detect)))))

(provide 'harness-sandbox-openshell-test)
;;; harness-sandbox-openshell-test.el ends here
