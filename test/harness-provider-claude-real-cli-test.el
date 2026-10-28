;;; harness-provider-claude-real-cli-test.el --- The Claude provider against the real `claude' CLI, with a mock API  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The other suites stand test/fixtures/fake-claude.py in for the CLI, and
;; that fake is only as right as what was last seen of the real one.  This
;; suite runs the provider against the real binary, with nothing of the
;; user's and no network: the CLI gets a home directory of its own, a
;; dummy API key and ANTHROPIC_BASE_URL pointing at
;; test/fixtures/mock-anthropic.py, which plays the model from a script.
;;
;; It runs only when HARNESS_REAL_CLAUDE names the binary:
;;
;;   HARNESS_REAL_CLAUDE=$(command -v claude) scripts/test.sh test/harness-provider-claude-real-cli-test.el
;;
;; A managed policy of the kind a company deploys is simulated by running
;; the CLI in a private mount namespace (bubblewrap) in which
;; /etc/claude-code/managed-settings.json is the policy: the machine's own
;; /etc is untouched.  Those tests are skipped where bwrap cannot do that.
;;
;; What this checks is what the experimental modes rest on (see
;; "Looking like an ordinary Claude Code session" in docs/architecture.md):
;; ask rules in --settings send every call of a tool to the permission
;; prompt tool, managed deny rules and `allowManagedPermissionRulesOnly'
;; and `disableBypassPermissionsMode' leave the harness working,
;; `disableSideloadFlags' ends a CLI started with --plugin-dir and the
;; harness carries on without the plugin, a plugin's server is up before
;; the first request, and the plugin's relay reaches the harness.
;; Written against Claude Code 2.1.308.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-provider)

(defvar harness-provider-claude-program)
(defvar harness-provider-claude-native-tools)
(defvar harness-provider-claude-native-permissions)
(defvar harness-provider-claude-plugin)
(defvar harness-provider-claude--plugin-broken)
(defvar harness-provider-claude--sessions)
(defvar harness-provider-claude-api-key)
(defvar harness-provider-claude--api-base)
(defvar harness-provider-claude--status)
(defvar harness-provider-claude--asked)
(defvar harness-provider-claude--probe)
(declare-function harness-provider-claude--forget-listing "harness-provider-claude")
(declare-function harness-provider--forget "harness-provider")
(declare-function harness-provider-claude-close-all "harness-provider-claude")
(declare-function harness-provider-claude-session-process "harness-provider-claude")

(defun harness-real-cli-test--binary ()
  "Return the real CLI HARNESS_REAL_CLAUDE names, or nil."
  (let ((binary (getenv "HARNESS_REAL_CLAUDE")))
    (and binary (file-executable-p binary) binary)))

(defvar harness-real-cli-test--bwrap-works 'unknown
  "Whether bubblewrap can give a process an /etc of its own here.")

(defun harness-real-cli-test--bwrap-p ()
  "Non-nil when a process can be given a private /etc/claude-code."
  (when (eq harness-real-cli-test--bwrap-works 'unknown)
    (setq harness-real-cli-test--bwrap-works
          (and (executable-find "bwrap")
               (eq 0 (call-process "bwrap" nil nil nil "--dev-bind" "/" "/"
                                   "--overlay-src" "/etc" "--tmp-overlay" "/etc"
                                   "sh" "-c" "mkdir -p /etc/claude-code")))))
  harness-real-cli-test--bwrap-works)

(defun harness-real-cli-test--write-script (name steps dir)
  "Write the model's script STEPS to NAME in DIR; return the path."
  (let ((file (expand-file-name name dir)))
    (with-temp-file file (insert (harness-json-encode (apply #'vector steps))))
    file))

(defun harness-real-cli-test--start-mock (script log)
  "Start the mock API with SCRIPT, logging to LOG; return (PROCESS . PORT)."
  (let* ((port nil)
         (proc (make-process :name "mock-anthropic" :noquery t :connection-type 'pipe
                             :command (list "python3" (harness-test-fixture "mock-anthropic.py")
                                            "--script" script "--log" log)
                             :filter (lambda (_p chunk)
                                       (when (string-match "PORT \\([0-9]+\\)" chunk)
                                         (setq port (string-to-number (match-string 1 chunk))))))))
    (harness-test-wait (lambda () port) 10 "the mock API")
    (cons proc port)))

(defun harness-real-cli-test--program (dir policy)
  "Return the program to run as `claude': the real CLI, under POLICY if there is one.
POLICY is an alist, the managed settings; it is written where the CLI
looks for them, in a private /etc, by a wrapper script in DIR."
  (let ((real (harness-real-cli-test--binary)))
    (if (null policy)
        real
      (let ((policy-file (expand-file-name "managed-settings.json" dir))
            (wrapper (expand-file-name "claude-under-policy" dir)))
        (with-temp-file policy-file (insert (harness-json-encode policy)))
        (with-temp-file wrapper
          (insert "#!/bin/sh\n"
                  "exec bwrap --dev-bind / / --overlay-src /etc --tmp-overlay /etc sh -c '"
                  "mkdir -p /etc/claude-code && cp \"$1\" /etc/claude-code/managed-settings.json"
                  " && shift && exec \"$@\"' sh "
                  (shell-quote-argument policy-file) " "
                  (shell-quote-argument real) " \"$@\"\n"))
        (set-file-modes wrapper #o755)
        wrapper))))

(defun harness-real-cli-test--tools-offered (log)
  "Return the tool names the model was offered by the first scripted request in LOG."
  (catch 'found
    (with-temp-buffer
      (insert-file-contents log)
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((line (buffer-substring (line-beginning-position) (line-end-position)))
               (request (harness-json-parse line))
               (body (plist-get request :body))
               (tools (mapcar (lambda (tool) (plist-get tool :name)) (plist-get body :tools))))
          (when (and tools (not (string-match-p "haiku" (or (plist-get body :model) ""))))
            (throw 'found tools)))
        (forward-line 1)))
    nil))

(defun harness-real-cli-test--of (events type)
  "Return the events of TYPE in EVENTS."
  (cl-remove-if-not (lambda (e) (eq (plist-get e :type) type)) events))

(defun harness-real-cli-test--names (events type)
  "Return the tool names of the events of TYPE in EVENTS."
  (mapcar (lambda (e) (plist-get e :name)) (harness-real-cli-test--of events type)))

(defun harness-real-cli-test--steps (&rest which)
  "Return the model's steps for the tools WHICH, then its answer.
WHICH are among read, write, edit, glob, grep, bash, curl, echo."
  (append
   (mapcar (lambda (w)
             (pcase w
               ('read '(:tool "Read" :input (:file_path "notes.txt")))
               ('write '(:tool "Write" :input (:file_path "out.txt" :content "hi\n")))
               ('edit '(:tool "Edit" :input (:file_path "out.txt" :old_string "hi" :new_string "ho")))
               ('glob '(:tool "Glob" :input (:pattern "*.txt")))
               ('grep '(:tool "Grep" :input (:pattern "hello" :-i t :output_mode "content")))
               ('bash '(:tool "Bash" :input (:command "touch made.txt" :description "Make a file")))
               ('curl '(:tool "Bash" :input (:command "curl -s http://127.0.0.1:1/ ; echo x" :description "curl")))
               ('echo '(:tool "mcp__harness__echo" :input (:text "ping")))
               ('plugin-echo '(:tool "mcp__plugin_emacs-harness_harness__echo" :input (:text "ping")))))
           which)
   (list '(:text "all done"))))

(defun harness-real-cli-test--absolute (steps cwd)
  "Return STEPS with the relative file paths of its tool calls under CWD."
  (mapcar (lambda (step)
            (let ((input (plist-get step :input)))
              (if (and input (plist-get input :file_path))
                  (plist-put (copy-sequence step) :input
                             (plist-put (copy-sequence input) :file_path
                                        (expand-file-name (plist-get input :file_path) cwd)))
                step)))
          steps))

(defvar harness-real-cli-test--last-log nil
  "The request log of the last world, which `harness-real-cli-test--tools-offered' reads.")

(cl-defun harness-real-cli-test--call-in-world (steps fn &key policy native plugin permissions deny settings)
  "Call FN with a function that runs turns against the real CLI, the model playing STEPS.
FN is called with TURN, a function of a prompt that runs one turn of
one session and returns the turn's events, oldest first, and with the
working directory.  The options are those the provider has during FN:
POLICY is a managed policy (an alist), NATIVE the native tools option,
PLUGIN the plugin option, PERMISSIONS who decides the native tools, and
DENY the name of a harness tool the harness refuses.  The mock API, the
CLI's home and its working directory are made for the call and gone
after it.  Return what FN returns."
  (let* ((dir (file-name-as-directory (make-temp-file "harness-real-cli-" t)))
         (home (file-name-as-directory (expand-file-name "home" dir)))
         (cwd (file-name-as-directory (expand-file-name "work" dir)))
         (log (expand-file-name "requests.jsonl" dir))
         ;; The paths in STEPS are relative to the working directory made here.
         (script (harness-real-cli-test--write-script
                  "script.json" (harness-real-cli-test--absolute steps cwd) dir))
         (mock (harness-real-cli-test--start-mock script log)))
    (make-directory (expand-file-name ".claude" home) t)
    (make-directory cwd t)
    (when settings
      ;; A project's settings file, which a repository can carry.
      (make-directory (expand-file-name ".claude" cwd) t)
      (with-temp-file (expand-file-name ".claude/settings.json" cwd)
        (insert (harness-json-encode settings))))
    (with-temp-file (expand-file-name "notes.txt" cwd) (insert "Hello from the notes\n"))
    (unwind-protect
        (let* ((process-environment
                (append (list (format "ANTHROPIC_BASE_URL=http://127.0.0.1:%d" (cdr mock))
                              "ANTHROPIC_API_KEY=sk-ant-dummy-key-for-the-mock-api"
                              (concat "HOME=" (directory-file-name home))
                              (concat "CLAUDE_CONFIG_DIR=" (expand-file-name ".claude" home))
                              "DISABLE_AUTOUPDATER=1" "DISABLE_TELEMETRY=1"
                              "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1")
                        (cl-remove-if (lambda (e) (string-match-p "\\`\\(ANTHROPIC_\\|CLAUDE\\|HOME=\\)" e))
                                      process-environment)))
               (harness-provider-claude-program (harness-real-cli-test--program dir policy))
               (harness-provider-claude-native-tools native)
               (harness-provider-claude-native-permissions (or permissions 'harness))
               (harness-provider-claude-plugin plugin)
               (harness-provider-claude--plugin-broken nil)
               (state nil)
               (turn
                (lambda (prompt)
                  (let* ((events nil)
                         (session (list :id "real" :cwd cwd :provider-state state))
                         (request
                          (list :model "claude:claude-sonnet-5"
                                :session session
                                :provider-state state
                                :system "You are a test agent"
                                :messages (list (list :role 'user
                                                      :content (list (list :type "text" :text prompt))))
                                :tools (list '(:name "echo" :description "Echo TEXT back to the caller."
                                               :schema (:type "object" :properties (:text (:type "string"))
                                                              :required ("text"))))
                                :builtin-tools (and harness-provider-claude-native-tools
                                                    '("bash" "read_file" "write_file" "edit_file" "glob" "grep"))
                                :on-event
                                (lambda (ev)
                                  (push ev events)
                                  (pcase (plist-get ev :type)
                                    ('provider-state (setq state (plist-get ev :state)))
                                    ('tool-permission
                                     (funcall (plist-get ev :respond)
                                              (if (equal deny (plist-get ev :name))
                                                  '(:behavior deny :message "Denied: by the harness")
                                                '(:behavior allow))))
                                    ('tool-call
                                     (when-let* ((respond (plist-get ev :respond)))
                                       (funcall respond '(:content "echo: ping" :is-error nil)))))))))
                    (harness-call 'provider/complete request)
                    (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type))))
                                       90 "the turn to end")
                    (nreverse events)))))
          (funcall fn turn cwd))
      (ignore-errors (harness-provider-claude-close-all))
      (when (process-live-p (car mock)) (delete-process (car mock)))
      (setq harness-real-cli-test--last-log log))))

(cl-defun harness-real-cli-test--run (steps &rest keys)
  "Run one turn against the real CLI, the model playing STEPS; KEYS as in `--call-in-world'.
Return a plist: `:events', `:tools' (what the model was offered first),
`:dir' (the working directory) and `:plugin-broken'."
  (let (events broken dir)
    (apply #'harness-real-cli-test--call-in-world
           steps
           (lambda (turn cwd)
             (setq events (funcall turn "go") dir cwd
                   broken harness-provider-claude--plugin-broken))
           keys)
    (list :events events :dir dir :plugin-broken broken
          :tools (harness-real-cli-test--tools-offered harness-real-cli-test--last-log))))

(defmacro harness-real-cli-test--with (&rest body)
  "Run BODY with the Claude provider loaded, against the real CLI, or skip."
  (declare (indent 0))
  `(progn
     (skip-unless (harness-real-cli-test--binary))
     (skip-unless (executable-find "python3"))
     (harness-test-with-temp-state
       (harness-test-reset-bus)
       (harness-test-load-module 'provider)
       (harness-test-load-module 'provider-claude)
       (setq harness-provider-claude-api-key 'none
             harness-provider-claude--api-base nil
             harness-provider-claude--status nil
             harness-provider-claude--asked nil
             harness-provider-claude--probe nil)
       (clrhash harness-provider-claude--sessions)
       (harness-provider-claude--forget-listing)
       (harness-provider--forget 'claude)
       ,@body)))

;;;; Native tools

(ert-deftest harness-real-cli-native-tools-reach-the-harness ()
  "With ask rules the real CLI asks the harness about every call, reads included, and runs them."
  (harness-real-cli-test--with
    (let* ((result (harness-real-cli-test--run
                    (harness-real-cli-test--steps 'read 'write 'edit 'glob 'grep 'bash)
                    :native t))
           (events (plist-get result :events))
           (dir (plist-get result :dir)))
      (should (equal '("read_file" "write_file" "edit_file" "glob" "grep" "bash")
                     (harness-real-cli-test--names events 'tool-call)))
      (should (equal '("read_file" "write_file" "edit_file" "glob" "grep" "bash")
                     (harness-real-cli-test--names events 'tool-permission)))
      (should-not (cl-some (lambda (e) (plist-get e :is-error)) (harness-real-cli-test--of events 'tool-result)))
      ;; The CLI's own tools ran: their files are there.
      (should (file-exists-p (expand-file-name "made.txt" dir)))
      (should (equal "ho\n" (harness-read-file (expand-file-name "out.txt" dir))))
      ;; The model was given the CLI's tools and the harness's remaining one.
      (should (equal '("Bash" "Edit" "Glob" "Grep" "Read" "Write" "mcp__harness__echo")
                     (sort (copy-sequence (plist-get result :tools)) #'string<)))
      (should (eq 'end-turn (plist-get (car (harness-real-cli-test--of events 'done)) :stop-reason))))))

(ert-deftest harness-real-cli-native-the-harness-refuses ()
  "A call the harness denies does not run, and the CLI's answer to the model says why."
  (harness-real-cli-test--with
    (let* ((result (harness-real-cli-test--run
                    (harness-real-cli-test--steps 'write 'bash)
                    :native t :deny "write_file"))
           (events (plist-get result :events))
           (write (car (harness-real-cli-test--of events 'tool-result))))
      (should (plist-get write :is-error))
      (should (equal "Denied: by the harness" (plist-get write :content)))
      (should-not (file-exists-p (expand-file-name "out.txt" (plist-get result :dir))))
      (should (file-exists-p (expand-file-name "made.txt" (plist-get result :dir)))))))

(ert-deftest harness-real-cli-native-cli-allows-by-rule ()
  "With the `cli' setting the real CLI allows the tools and asks the harness nothing."
  (harness-real-cli-test--with
    (let* ((result (harness-real-cli-test--run
                    (harness-real-cli-test--steps 'read 'write 'bash)
                    :native t :permissions 'cli :deny "write_file"))
           (events (plist-get result :events)))
      (should-not (harness-real-cli-test--of events 'tool-permission))
      (should (equal '("read_file" "write_file" "bash") (harness-real-cli-test--names events 'tool-call)))
      (should (file-exists-p (expand-file-name "out.txt" (plist-get result :dir)))))))

;;;; Managed policies

(ert-deftest harness-real-cli-native-works-where-bypass-is-forbidden ()
  "Under `disableBypassPermissionsMode' every call still gets its answer.
The first version of the provider asked the CLI to bypass its checks,
which such a policy turns into the `default' mode; it then denied every call."
  (skip-unless (harness-real-cli-test--bwrap-p))
  (harness-real-cli-test--with
    (dolist (permissions '(harness cli))
      (let* ((result (harness-real-cli-test--run
                      (harness-real-cli-test--steps 'read 'write 'bash)
                      :native t :permissions permissions
                      :policy '(:permissions (:disableBypassPermissionsMode "disable"))))
             (events (plist-get result :events)))
        (should-not (cl-some (lambda (e) (plist-get e :is-error)) (harness-real-cli-test--of events 'tool-result)))
        (should (file-exists-p (expand-file-name "made.txt" (plist-get result :dir))))
        (should (eq (eq permissions 'harness) (and (harness-real-cli-test--of events 'tool-permission) t)))))))

(ert-deftest harness-real-cli-native-under-managed-rules-only ()
  "Where managed settings alone decide, the harness is asked what they leave, and their deny holds.
The command line's ask and allow rules are ignored by the CLI there, so
the reads the managed rules allow are not asked about; the write and the
command are, and a managed deny rule refuses a command without asking."
  (skip-unless (harness-real-cli-test--bwrap-p))
  (harness-real-cli-test--with
    (dolist (permissions '(harness cli))
      (let* ((result (harness-real-cli-test--run
                      (harness-real-cli-test--steps 'read 'glob 'write 'curl 'bash)
                      :native t :permissions permissions
                      :policy '(:allowManagedPermissionRulesOnly t
                                :permissions (:allow ["Read" "Glob" "Grep"]
                                              :deny ["Bash(curl *)"]
                                              :disableBypassPermissionsMode "disable"))))
             (events (plist-get result :events))
             (results (harness-real-cli-test--of events 'tool-result))
             (curl (nth 3 results)))
        ;; The harness hears of every call, and is asked about the write and the plain command only.
        (should (equal '("read_file" "glob" "write_file" "bash" "bash")
                       (harness-real-cli-test--names events 'tool-call)))
        (should (equal '("write_file" "bash") (harness-real-cli-test--names events 'tool-permission)))
        (should (plist-get curl :is-error))
        (should (string-match-p "has been denied" (plist-get curl :content)))
        (let ((text (plist-get (car (harness-real-cli-test--of events 'hint)) :text)))
          (should (string-match-p "settings or managed policy outrank the harness" text))
          (should (string-match-p "harness-provider-claude-native-permissions" text))
          (should (string-match-p "Reason: Permission to use Bash has been denied" text)))
        (should (file-exists-p (expand-file-name "made.txt" (plist-get result :dir))))))))

;;;; The plugin

(ert-deftest harness-real-cli-plugin-serves-the-tools ()
  "The real CLI loads the plugin, its relay reaches the harness, and the model has the tool at once."
  (harness-real-cli-test--with
    (let* ((result (harness-real-cli-test--run (harness-real-cli-test--steps 'plugin-echo) :plugin t))
           (events (plist-get result :events))
           (call (car (harness-real-cli-test--of events 'tool-call))))
      (should (equal "echo" (plist-get call :name)))
      (should-not (plist-get call :builtin))
      ;; In the very first request, though the CLI connects the plugin's server in the background.
      (should (member "mcp__plugin_emacs-harness_harness__echo" (plist-get result :tools)))
      (should-not (member "mcp__harness__echo" (plist-get result :tools)))
      (should-not (plist-get result :plugin-broken))
      (should (eq 'end-turn (plist-get (car (harness-real-cli-test--of events 'done)) :stop-reason))))))

(ert-deftest harness-real-cli-plugin-and-native-tools ()
  "Both modes at once: the CLI's own tools and the plugin's, and no SDK server."
  (harness-real-cli-test--with
    (let* ((result (harness-real-cli-test--run
                    (harness-real-cli-test--steps 'read 'plugin-echo) :native t :plugin t))
           (tools (plist-get result :tools)))
      (should (member "Read" tools))
      (should (member "mcp__plugin_emacs-harness_harness__echo" tools))
      (should-not (cl-some (lambda (name) (string-prefix-p "mcp__harness__" name)) tools))
      (should (equal '("read_file" "echo")
                     (harness-real-cli-test--names (plist-get result :events) 'tool-call))))))

(ert-deftest harness-real-cli-plugin-refused-by-policy ()
  "A CLI that refuses --plugin-dir (`disableSideloadFlags') exits; the harness serves its tools over the SDK channel."
  (skip-unless (harness-real-cli-test--bwrap-p))
  (harness-real-cli-test--with
    (let* ((result (harness-real-cli-test--run
                    (harness-real-cli-test--steps 'echo) :plugin t
                    :policy '(:disableSideloadFlags t)))
           (events (plist-get result :events))
           (hint (car (harness-real-cli-test--of events 'hint))))
      (should (stringp (plist-get result :plugin-broken)))
      (should (string-match-p "disableSideloadFlags" (plist-get hint :text)))
      (should (member "mcp__harness__echo" (plist-get result :tools)))
      (should (equal "echo" (plist-get (car (harness-real-cli-test--of events 'tool-call)) :name)))
      (should (eq 'end-turn (plist-get (car (harness-real-cli-test--of events 'done)) :stop-reason))))))


(ert-deftest harness-real-cli-plugin-survives-a-restart ()
  "A later turn goes to the same process; a changed setting restarts it in its conversation, plugin and all."
  (harness-real-cli-test--with
    (harness-real-cli-test--call-in-world
     (append (harness-real-cli-test--steps 'plugin-echo) (harness-real-cli-test--steps 'plugin-echo)
             (harness-real-cli-test--steps 'plugin-echo))
     (lambda (turn _cwd)
       (let* ((process (lambda () (harness-provider-claude-session-process
                                   (gethash "real" harness-provider-claude--sessions))))
              (cli-id (lambda (events)
                        (plist-get (plist-get (car (harness-real-cli-test--of events 'provider-state)) :state)
                                   :cli-session-id)))
              (one (funcall turn "one"))
              (proc1 (funcall process))
              (two (funcall turn "two"))
              (proc2 (funcall process)))
         (should (equal '("echo") (harness-real-cli-test--names one 'tool-call)))
         (should (equal '("echo") (harness-real-cli-test--names two 'tool-call)))
         (should (eq proc1 proc2))
         ;; Native tools turned on: a new process, the same conversation, the plugin up before its first request.
         (setq harness-provider-claude-native-tools t)
         (let ((three (funcall turn "three")))
           (should-not (eq proc2 (funcall process)))
           (should (equal '("echo") (harness-real-cli-test--names three 'tool-call)))
           (should (equal (funcall cli-id one) (funcall cli-id three)))
           (should-not harness-provider-claude--plugin-broken)
           (should-not (harness-real-cli-test--of three 'hint))
           (should (eq 'end-turn (plist-get (car (harness-real-cli-test--of three 'done)) :stop-reason))))))
     :plugin t)))


(ert-deftest harness-real-cli-native-sandboxed-bash-still-asks ()
  "A repository whose settings turn the CLI's sandbox on cannot have Bash run unasked.
The CLI runs a command it sandboxes without asking its permission prompt
tool unless sandbox.autoAllowBashIfSandboxed is false; the harness sets
it false in the flag settings, which outrank a project's file."
  (harness-real-cli-test--with
    (let* ((result (harness-real-cli-test--run
                    (harness-real-cli-test--steps 'bash)
                    :native t :settings '(:sandbox (:enabled t :autoAllowBashIfSandboxed t))))
           (events (plist-get result :events)))
      ;; A sandbox is what the CLI has; the harness is still asked first.
      (should (equal '("bash") (harness-real-cli-test--names events 'tool-permission)))
      (should (equal '("bash") (harness-real-cli-test--names events 'tool-call)))
      (should (file-exists-p (expand-file-name "made.txt" (plist-get result :dir)))))))

(ert-deftest harness-real-cli-native-the-sandbox-still-runs-the-command ()
  "Bash a settings file asks the CLI to sandbox runs sandboxed, and the harness decides it.
The harness turns off the CLI's self-allowance, not its sandbox."
  (harness-real-cli-test--with
    (let* ((result (harness-real-cli-test--run
                    (harness-real-cli-test--steps 'bash)
                    :native t :settings '(:sandbox (:enabled t))))
           (events (plist-get result :events)))
      (should (equal '("bash") (harness-real-cli-test--names events 'tool-permission)))
      (should-not (plist-get (car (harness-real-cli-test--of events 'tool-result)) :is-error)))))

(ert-deftest harness-real-cli-plugin-asks-about-foreign-servers ()
  "With the plugin, a tool of another MCP server is put to the harness, which refuses it.
The plugin cannot be had along with --strict-mcp-config, so the
harness always names its permission prompt tool; a tool the harness
does not serve, and no rule allows, is asked about and refused."
  (harness-real-cli-test--with
    (let* ((result (harness-real-cli-test--run
                    (harness-real-cli-test--steps 'plugin-echo)
                    :plugin t))
           (events (plist-get result :events)))
      (should (member "mcp__plugin_emacs-harness_harness__echo" (plist-get result :tools)))
      (should (equal '("echo") (harness-real-cli-test--names events 'tool-call)))
      (should-not (harness-real-cli-test--of events 'hint)))))

(provide 'harness-provider-claude-real-cli-test)
;;; harness-provider-claude-real-cli-test.el ends here
