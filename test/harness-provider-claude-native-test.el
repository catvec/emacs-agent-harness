;;; harness-provider-claude-native-test.el --- Claude Code's own tools and its plugin in place of the harness's MCP tools  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The experimental, opt-in modes of the Claude provider
;; (`harness-provider-claude-native-tools', `harness-provider-claude-plugin'),
;; against test/fixtures/fake-claude.py, which decides permissions the
;; way the real CLI was observed to: deny rules, then `ask' rules, then
;; the mode and the allow rules, reads in the working directory run
;; without asking, and a managed policy outranks the command line.  The
;; plugin tests run the plugin's real relay script against the real
;; listener (lisp/harness-claude-plugin.el).
;;
;; Every command line these modes build is checked for what a company's
;; managed settings may forbid: no `bypassPermissions', no
;; --dangerously-skip-permissions.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-provider)

(defvar harness-provider-claude-program)
(defvar harness-provider-claude-permission-args)
(defvar harness-provider-claude-native-tools)
(defvar harness-provider-claude-native-permissions)
(defvar harness-provider-claude-plugin)
(defvar harness-provider-claude--plugin-broken)
(defvar harness-provider-claude--plugin-wait)
(defvar harness-provider-claude--sessions)
(defvar harness-provider-claude--status)
(defvar harness-provider-claude--asked)
(defvar harness-provider-claude--probe)
(defvar harness-provider-claude-api-key)
(defvar harness-provider-claude--api-base)
(defvar harness-sandbox-policy)
(defvar harness-websearch-builtin)
(declare-function harness-provider-claude--forget-listing "harness-provider-claude")
(declare-function harness-provider--forget "harness-provider")
(declare-function harness-provider-claude--command "harness-provider-claude")
(declare-function harness-provider-claude--cli-tools "harness-provider-claude")
(declare-function harness-provider-claude--tool-input "harness-provider-claude")
(declare-function harness-provider-claude--builtin-filter "harness-provider-claude")
(declare-function harness-provider-claude--plugin-wanted-p "harness-provider-claude")
(declare-function harness-provider-claude--spawn-key "harness-provider-claude")
(declare-function harness-provider-claude--prompts-lost "harness-provider-claude")
(declare-function harness-provider-claude--ours-p "harness-provider-claude")
(declare-function harness-provider-claude--strip-prefix "harness-provider-claude")
(declare-function harness-provider-claude--make-session "harness-provider-claude")
(declare-function harness-provider-claude--can-use-tool "harness-provider-claude")
(declare-function harness-provider-claude-session-process "harness-provider-claude")
(declare-function harness-provider-claude-session-spawn-key "harness-provider-claude")
(declare-function harness-provider-claude-session-bridge "harness-provider-claude")
(declare-function harness-provider-claude-session-plugin-gate "harness-provider-claude")
(declare-function harness-provider-claude-session-plugin-state "harness-provider-claude")
(declare-function harness-provider-claude--relay-closed "harness-provider-claude")
(declare-function harness-provider-claude--stale-slot "harness-provider-claude")
(declare-function harness-provider-claude--make-session "harness-provider-claude")
(declare-function harness-provider-claude-close "harness-provider-claude")
(declare-function harness-provider-claude-close-all "harness-provider-claude")
(declare-function harness-claude-plugin-stop "harness-claude-plugin")
(declare-function harness-claude-plugin-close "harness-claude-plugin")
(defvar harness-sessions)
(declare-function harness-provider-claude-session-bridge "harness-provider-claude")
(declare-function harness-provider-claude-session-spawn-key "harness-provider-claude")

(defun harness-provider-claude-native-test--setup ()
  "Fresh bus with the Claude provider loaded, the options off, the fake CLI in place."
  (harness-test-reset-bus)
  (harness-test-load-module 'provider)
  (harness-test-load-module 'provider-claude)
  (setq harness-provider-claude-program (harness-test-fixture "fake-claude.py"))
  (harness-provider-claude-close-all)
  (clrhash harness-provider-claude--sessions)
  (setq harness-provider-claude--status nil
        harness-provider-claude--asked nil
        harness-provider-claude--probe nil
        harness-provider-claude-api-key 'none
        harness-provider-claude--api-base nil
        harness-provider-claude-native-tools nil
        harness-provider-claude-native-permissions 'harness
        harness-provider-claude-plugin nil
        harness-provider-claude--plugin-broken nil)
  (harness-provider-claude--forget-listing)
  (harness-provider--forget 'claude))

(defmacro harness-provider-claude-native-test--with (&rest body)
  "Run BODY after `harness-provider-claude-native-test--setup', cleaning up after it.
It runs in a state directory of its own, as the plugin is written there."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-provider-claude-native-test--setup)
     (unwind-protect (progn ,@body)
       (harness-provider-claude-close-all)
       (clrhash harness-provider-claude--sessions)
       (setq harness-provider-claude-native-tools nil
             harness-provider-claude-native-permissions 'harness
             harness-provider-claude-plugin nil
             harness-provider-claude--plugin-broken nil))))

(defconst harness-provider-claude-native-test--all
  '("web_search" "bash" "read_file" "write_file" "edit_file" "glob" "grep" "web_fetch")
  "The harness tools the CLI can run with its own.")

(defun harness-provider-claude-native-test--cwd ()
  "Return a working directory for a session, with a file the fake CLI reads."
  (let ((dir (harness-test-temp-dir)))
    (with-temp-file (expand-file-name "notes.txt" dir) (insert "Hello\n"))
    dir))

(defun harness-provider-claude-native-test--request (sid text &rest extra)
  "Build a request for session SID asking TEXT, with EXTRA plist keys."
  (harness-plist-merge
   (list :model "claude:claude-fable-5-1"
         :session (list :id sid :cwd (harness-provider-claude-native-test--cwd))
         :system "You are a test agent"
         :messages (list (list :role 'user :content (list (list :type "text" :text text))))
         :tools (list '(:name "echo" :description "Echo TEXT back to the caller."
                        :schema (:type "object" :properties (:text (:type "string")) :required ("text")))))
   extra))

(defun harness-provider-claude-native-test--find (events type &optional all)
  "Return the first event of TYPE in EVENTS, or with ALL every one."
  (if all
      (cl-remove-if-not (lambda (e) (eq (plist-get e :type) type)) events)
    (cl-find type events :key (lambda (e) (plist-get e :type)))))

(defun harness-provider-claude-native-test--run (request &optional decide timeout)
  "Run REQUEST to its end; return its events, oldest first.
DECIDE, a function of the `tool-permission' event, returns the decision
the harness's permission chain gives it (default: allow).  The harness's
own tools are answered \"echo: ping\"."
  (let (events)
    (harness-call 'provider/complete
                  (plist-put (copy-sequence request) :on-event
                             (lambda (ev)
                               (push ev events)
                               (pcase (plist-get ev :type)
                                 ('tool-permission
                                  (funcall (plist-get ev :respond)
                                           (if decide (funcall decide ev) '(:behavior allow))))
                                 ('tool-call
                                  (when-let* ((respond (plist-get ev :respond)))
                                    (funcall respond '(:content "echo: ping" :is-error nil))))))))
    (harness-test-wait (lambda () (harness-provider-claude-native-test--find events 'done))
                       (or timeout 20) "done event")
    (nreverse events)))

(defmacro harness-provider-claude-native-test--with-argv (spec &rest body)
  "Run BODY with the fake CLI dumping its argv to a file.
SPEC is (VAR ENV...): VAR is bound to a function returning the dump,
parsed; ENV are further environment entries for the CLI."
  (declare (indent 1))
  (let ((file (make-symbol "file")))
    `(let* ((,file (make-temp-file "harness-claude-argv-"))
            (process-environment (append (list (concat "HARNESS_FAKE_CLAUDE_ARGV=" ,file) ,@(cdr spec))
                                         process-environment))
            (,(car spec) (lambda ()
                           (harness-test-wait (lambda () (> (or (harness-file-size ,file) 0) 0)) 5 "argv file")
                           (harness-json-parse (harness-read-file ,file)))))
       ,@body)))

(defun harness-provider-claude-native-test--after (flag argv)
  "Return the argument after FLAG in ARGV."
  (nth (1+ (cl-position flag argv :test #'equal)) argv))

(defun harness-provider-claude-native-test--no-bypass (argv)
  "Fail unless ARGV skips none of the CLI's permission checks.
That is what managed settings may forbid (permissions.disableBypassPermissionsMode)."
  (should-not (cl-some (lambda (a) (string-match-p "bypassPermissions\\|dangerously-skip\\|dangerously-skip-permissions" a))
                       argv)))

;;;; The command line

(ert-deftest harness-provider-claude-native-options-off-change-nothing ()
  "With the options off the command line is the one the provider always built."
  (harness-provider-claude-native-test--with
    (let ((cmd (harness-provider-claude--command "m" nil nil nil nil)))
      (should (equal "" (harness-provider-claude-native-test--after "--tools" cmd)))
      (should (member "--strict-mcp-config" cmd))
      (should (member "--mcp-config" cmd))
      (should-not (member "--plugin-dir" cmd))
      (should-not (member "--settings" cmd))
      (should-not (member "--disallowedTools" cmd))
      (should-not (member "--permission-prompt-tool" cmd))
      (should (equal "mcp__harness__*" (harness-provider-claude-native-test--after "--allowedTools" cmd))))
    ;; Even a request that names the CLI's tools: only WebSearch asks (the old way).
    (let ((cmd (harness-provider-claude--command "m" nil nil nil nil '("WebSearch"))))
      (should-not (member "--settings" cmd))
      (should (equal "stdio" (harness-provider-claude-native-test--after "--permission-prompt-tool" cmd))))))

(ert-deftest harness-provider-claude-native-harness-decides-by-ask-rules ()
  "The harness is asked before every call: ask rules and a prompt tool, no allowance."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-native-tools t)
          (tools '("Bash" "Read" "Write" "Edit" "Glob" "Grep" "WebFetch" "WebSearch")))
      (let ((cmd (harness-provider-claude--command "m" nil nil nil nil tools)))
        (should (equal "Bash,Read,Write,Edit,Glob,Grep,WebFetch,WebSearch"
                       (harness-provider-claude-native-test--after "--tools" cmd)))
        (should (equal "default" (harness-provider-claude-native-test--after "--permission-mode" cmd)))
        (should (equal "stdio" (harness-provider-claude-native-test--after "--permission-prompt-tool" cmd)))
        (should (= 1 (cl-count "--permission-prompt-tool" cmd :test #'equal)))
        ;; The one --settings carries the ask rules, one for each tool.
        (should (= 1 (cl-count "--settings" cmd :test #'equal)))
        (should (equal tools (harness-plist-get-in
                              (harness-json-parse (harness-provider-claude-native-test--after "--settings" cmd))
                              '(:permissions :ask))))
        ;; Nothing is allowed by flag but the harness's own MCP tools.
        (should (equal "mcp__harness__*" (harness-provider-claude-native-test--after "--allowedTools" cmd)))
        (should (= 1 (cl-count "--allowedTools" cmd :test #'equal)))
        ;; What the harness's bash does not have, the CLI's Bash may not do either.
        (should (equal '("Bash(run_in_background:true)" "Bash(dangerouslyDisableSandbox:true)")
                       (cl-subseq cmd (1+ (cl-position "--disallowedTools" cmd :test #'equal))
                                  (+ 3 (cl-position "--disallowedTools" cmd :test #'equal)))))
        (harness-provider-claude-native-test--no-bypass cmd))
      ;; Without Bash there is nothing to take from.
      (should-not (member "--disallowedTools" (harness-provider-claude--command "m" nil nil nil nil '("Read"))))
      ;; Thinking off goes in the same --settings: a second flag would replace it.
      (let ((cmd (harness-provider-claude--command "m" 'off nil nil nil tools)))
        (should (= 1 (cl-count "--settings" cmd :test #'equal)))
        (let ((settings (harness-json-parse (harness-provider-claude-native-test--after "--settings" cmd))))
          (should (equal "0" (harness-plist-get-in settings '(:env :MAX_THINKING_TOKENS))))
          (should (equal tools (harness-plist-get-in settings '(:permissions :ask))))
          ;; The CLI's sandbox runs a command it sandboxes without asking unless told not to.
          (should (eq :false (harness-plist-get-in settings '(:sandbox :autoAllowBashIfSandboxed))))))
      ;; Without Bash there is no sandbox to say it about.
      (let ((cmd (harness-provider-claude--command "m" nil nil nil nil '("Read"))))
        (should-not (harness-plist-get-in (harness-json-parse
                                           (harness-provider-claude-native-test--after "--settings" cmd))
                                          '(:sandbox :autoAllowBashIfSandboxed)))))))

(ert-deftest harness-provider-claude-native-cli-allows-by-rule ()
  "The `cli' setting allows the tools by rule, every use, and still bypasses nothing."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-native-tools t)
          (harness-provider-claude-native-permissions 'cli)
          (tools '("Bash" "Read" "WebSearch")))
      (let ((cmd (harness-provider-claude--command "m" nil nil nil nil tools)))
        (should (equal "default" (harness-provider-claude-native-test--after "--permission-mode" cmd)))
        ;; Flags accumulate: the harness's tools by one, the CLI's by another.
        (should (equal '("mcp__harness__*" "Bash,Read,WebSearch")
                       (cl-loop for (a b) on cmd when (equal a "--allowedTools") collect b)))
        (should-not (member "--settings" cmd))
        ;; Where managed settings ignore the rule, the CLI asks the harness
        ;; rather than deny every call (the first version's failure).
        (should (equal "stdio" (harness-provider-claude-native-test--after "--permission-prompt-tool" cmd)))
        (should (= 1 (cl-count "--permission-prompt-tool" cmd :test #'equal)))
        (harness-provider-claude-native-test--no-bypass cmd)))))

(ert-deftest harness-provider-claude-native-permission-arguments-are-respected ()
  "Arguments of the user's that route the prompts elsewhere switch native tools off.
Bypassing is the user's to choose, in `harness-provider-claude-permission-args'
\(the provider never adds it), and then nothing can ask, so the tools
stay the harness's own; a prompt tool of another server gets the
prompts; stdio, the user's own, is the harness; a --settings of their
own would replace the harness's rules."
  (harness-provider-claude-native-test--with
    (dolist (case '((("--permission-mode" "bypassPermissions") . t)
                    (("--dangerously-skip-permissions") . t)
                    (("--permission-mode=bypassPermissions") . t)
                    (("--permission-mode" "dontAsk") . t)
                    (("--permission-mode" "default" "--permission-prompt-tool" "mcp__x__approve") . t)
                    (("--permission-mode" "default" "--settings" "{}") . t)
                    (("--permission-mode" "default" "--permission-prompt-tool" "stdio") . nil)
                    (("--permission-mode" "default" "--allowedTools" "mcp__harness__*") . nil)))
      (let* ((harness-provider-claude-permission-args (car case))
             (harness-provider-claude-native-tools t)
             (lost (harness-provider-claude--prompts-lost))
             (request (harness-provider-claude-native-test--request "na" "hi" :builtin-tools '("bash")))
             (spawn-key (harness-provider-claude--spawn-key request)))
        (should (eq (and (cdr case) t) (and lost t)))
        (when lost (should (stringp lost)))
        ;; The tools stay the harness's own when the harness cannot be asked.
        (should (eq (and (cdr case) t) (null (harness-provider-claude--native-set))))
        ;; A request naming the tool turns nothing on while the harness cannot decide.
        (should (equal (and (not (cdr case)) '("Bash")) (nth 3 spawn-key)))
        ;; What it decided is part of the process's settings, so a change restarts it.
        (should (eq (and (cdr case) t) (null (nth 7 spawn-key))))))))

(ert-deftest harness-provider-claude-native-refusal-is-said ()
  "A session whose arguments keep the harness from deciding native tools is told why, once."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-native-tools t)
          (harness-provider-claude-native-permissions 'harness)
          (harness-provider-claude-permission-args '("--dangerously-skip-permissions")))
      (harness-provider-claude-native-test--with-argv (dump)
        (let* ((events (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request "n10" "call echo" :builtin-tools '("read_file"))))
               (hint (harness-provider-claude-native-test--find events 'hint))
               (argv (plist-get (funcall dump) :argv)))
          (should hint)
          (should (string-match-p "own tools are off" (plist-get hint :text)))
          (should (string-match-p "dangerously-skip-permissions" (plist-get hint :text)))
          ;; No tool of the CLI's is turned on, and the harness's tools stay served.
          (should (equal "" (harness-provider-claude-native-test--after "--tools" argv)))
          (should-not (member "--settings" argv))
          ;; The user's own argument stands: the provider does not remove it.
          (should (member "--dangerously-skip-permissions" argv))
          ;; The turn ran, with the echo tool the harness serves.
          (should (equal "echo" (plist-get (harness-provider-claude-native-test--find events 'tool-call) :name)))
          (should (eq 'end-turn (plist-get (harness-provider-claude-native-test--find events 'done) :stop-reason))))))))

(ert-deftest harness-provider-claude-native-plugin-command-line ()
  "With the plugin the CLI loads it in place of the SDK server, and allows its tools."
  (harness-provider-claude-native-test--with
    (let ((cmd (harness-provider-claude--command "m" nil nil nil nil nil nil "/state/claude-plugin/emacs-harness")))
      (should (equal "/state/claude-plugin/emacs-harness"
                     (harness-provider-claude-native-test--after "--plugin-dir" cmd)))
      ;; --strict-mcp-config would hide the plugin's server.
      (should-not (member "--strict-mcp-config" cmd))
      (should-not (member "--mcp-config" cmd))
      (should (equal "mcp__plugin_emacs-harness_harness__*"
                     (harness-provider-claude-native-test--after "--allowedTools" cmd)))
      (should-not (cl-some (lambda (a) (string-match-p "mcp__harness__" a)) cmd))
      (should (equal "default" (harness-provider-claude-native-test--after "--permission-mode" cmd)))
      ;; The session also has the user's own MCP servers: their tools are asked about, and refused.
      (should (equal "stdio" (harness-provider-claude-native-test--after "--permission-prompt-tool" cmd)))
      (harness-provider-claude-native-test--no-bypass cmd))
    ;; The user's own rules for the harness's tools follow it.
    (let* ((harness-provider-claude-permission-args
            '("--permission-mode" "default" "--allowedTools" "mcp__harness__* Bash(ls)"))
           (cmd (harness-provider-claude--command "m" nil nil nil nil nil nil "/p")))
      (should (equal "mcp__plugin_emacs-harness_harness__* Bash(ls)"
                     (harness-provider-claude-native-test--after "--allowedTools" cmd))))))

(ert-deftest harness-provider-claude-native-tool-inputs-are-the-harness-tools ()
  "What the CLI's tool is called with becomes the input of the harness tool it stands in for."
  (cl-flet ((in (name input) (harness-provider-claude--tool-input name input)))
    (should (equal '(:path "/a/b" :offset 10 :limit 5)
                   (in "Read" '(:file_path "/a/b" :offset 10 :limit 5 :pages "1-2"))))
    (should (equal '(:path "/a/b" :content "x") (in "Write" '(:file_path "/a/b" :content "x"))))
    (should (equal '(:path "/a/b" :old_string "o" :new_string "n" :replace_all t)
                   (in "Edit" '(:file_path "/a/b" :old_string "o" :new_string "n" :replace_all t))))
    (should (equal '(:pattern "*.el" :path "/src") (in "Glob" '(:pattern "*.el" :path "/src"))))
    ;; Milliseconds become seconds; what bash does not know is left out.
    (should (equal '(:command "ls" :timeout 5)
                   (in "Bash" '(:command "ls" :timeout 5000 :description "List" :run_in_background :false))))
    (should (equal '(:command "ls") (in "Bash" '(:command "ls"))))
    (should (equal '(:command "ls" :timeout 1) (in "Bash" '(:command "ls" :timeout 10))))
    ;; The CLI's search is case sensitive unless -i; the harness's is not unless told.
    (should (equal '(:pattern "foo" :case_sensitive t) (in "Grep" '(:pattern "foo"))))
    (should (equal '(:pattern "foo" :path "." :glob "*.el" :case_sensitive :false)
                   (in "Grep" '(:pattern "foo" :path "." :glob "*.el" :-i t :output_mode "content"))))
    (should (equal '(:url "https://e.org") (in "WebFetch" '(:url "https://e.org" :prompt "p"))))
    ;; The CLI's WebSearch input goes as it is: the harness tool's schema has only `query'.
    (should (equal '(:query "emacs" :allowed_domains ("a.org"))
                   (in "WebSearch" '(:query "emacs" :allowed_domains ("a.org")))))
    ;; Anything else, and no input, pass.
    (should (equal '(:x 1) (in "Task" '(:x 1))))
    (should-not (in "Bash" nil))))

(ert-deftest harness-provider-claude-native-tools-are-named-by-both-servers ()
  "The harness's tools are the SDK server's and the plugin's, and no one else's."
  (harness-provider-claude-native-test--with
    (should (harness-provider-claude--ours-p "mcp__harness__echo"))
    (should (harness-provider-claude--ours-p "mcp__plugin_emacs-harness_harness__echo"))
    (should-not (harness-provider-claude--ours-p "mcp__other__echo"))
    (should-not (harness-provider-claude--ours-p "mcp__plugin_other_harness__echo"))
    (should-not (harness-provider-claude--ours-p "Bash"))
    (should-not (harness-provider-claude--ours-p nil))
    (should (equal "echo" (harness-provider-claude--strip-prefix "mcp__harness__echo")))
    (should (equal "echo" (harness-provider-claude--strip-prefix "mcp__plugin_emacs-harness_harness__echo")))
    (should (equal "Bash" (harness-provider-claude--strip-prefix "Bash")))))

;;;; Which tools run natively

(ert-deftest harness-provider-claude-native-filter ()
  "The `agent/builtin-tools' filter picks the tools the option names, for Claude sessions only."
  (harness-provider-claude-native-test--with
    (let ((offered harness-provider-claude-native-test--all)
          (session '(:id "s" :model "claude:claude-fable-5-1" :cwd "/tmp/"))
          (harness-sandbox-policy 'preferred))
      ;; Off: nothing.
      (should-not (harness-provider-claude--builtin-filter nil session offered))
      (let ((harness-provider-claude-native-tools t))
        (should (equal (sort (copy-sequence offered) #'string<)
                       (sort (harness-provider-claude--builtin-filter nil session offered) #'string<)))
        ;; What other filters chose stays, once.
        (let ((names (harness-provider-claude--builtin-filter '("web_search") session offered)))
          (should (= 1 (cl-count "web_search" names :test #'equal)))
          (should (equal (sort (copy-sequence offered) #'string<) (sort (copy-sequence names) #'string<))))
        ;; Only what the provider offers.
        (should-not (harness-provider-claude--builtin-filter nil session '("ssh")))
        ;; A session on another host keeps the harness's tools: TRAMP names are theirs.
        (should-not (harness-provider-claude--builtin-filter
                     nil '(:id "s" :model "claude:claude-fable-5-1" :cwd "/tmp/" :host "/ssh:box:") offered))
        (should-not (harness-provider-claude--builtin-filter
                     nil '(:id "s" :model "claude:claude-fable-5-1" :cwd "/ssh:box:/home/me/") offered))
        ;; Another provider's session gets none.
        (should-not (harness-provider-claude--builtin-filter
                     nil '(:id "s" :model "bedrock:claude" :cwd "/tmp/") offered))
        (should-not (harness-provider-claude--builtin-filter nil nil offered))
        ;; A required sandbox keeps bash a harness tool: the CLI's Bash is not sandboxed.
        (let ((harness-sandbox-policy 'required))
          (let ((names (harness-provider-claude--builtin-filter nil session offered)))
            (should-not (member "bash" names))
            (should (member "read_file" names)))))
      ;; The usual set leaves the search to `harness-websearch-builtin', unless it is asked for by name.
      (let ((harness-provider-claude-native-tools t)
            (harness-websearch-builtin 'never))
        (should-not (member "web_search" (harness-provider-claude--builtin-filter nil session offered)))
        (should (member "read_file" (harness-provider-claude--builtin-filter nil session offered))))
      (let ((harness-provider-claude-native-tools '("web_search"))
            (harness-websearch-builtin 'never))
        (should (equal '("web_search") (harness-provider-claude--builtin-filter nil session offered))))
      ;; A list names the tools.
      (let ((harness-provider-claude-native-tools '("read_file" "grep" "ssh" "no_such_tool")))
        (should (equal '("read_file" "grep") (harness-provider-claude--builtin-filter nil session offered)))))))

(ert-deftest harness-provider-claude-native-spawn-key-follows-the-options ()
  "Every setting that changes the command line changes the key that restarts the process."
  (harness-provider-claude-native-test--with
    (let* ((cwd (harness-test-temp-dir))
           (request (list :model "claude:claude-fable-5-1" :session (list :id "k" :cwd cwd)
                          :builtin-tools '("read_file")
                          :tools (list '(:name "echo" :description "e" :schema (:type "object")))))
           (base (harness-provider-claude--spawn-key request)))
      (should (equal '("Read") (nth 3 base)))
      (should-not (nth 6 base))
      (should-not (nth 7 base))
      (let ((harness-provider-claude-native-tools t))
        (should (equal 'harness (nth 7 (harness-provider-claude--spawn-key request))))
        (let ((harness-provider-claude-native-permissions 'cli))
          (should (equal 'cli (nth 7 (harness-provider-claude--spawn-key request))))))
      (let ((harness-provider-claude-plugin t))
        (should (nth 6 (harness-provider-claude--spawn-key request)))
        ;; A plugin that did not work is not one the process was started with.
        (let ((harness-provider-claude--plugin-broken "refused"))
          (should-not (nth 6 (harness-provider-claude--spawn-key request))))
        ;; Not for another host, nor a one-off request, nor a side conversation.
        (should-not (nth 6 (harness-provider-claude--spawn-key
                            (plist-put (copy-sequence request) :session (list :id "k" :cwd cwd :host "/ssh:h:")))))
        (should-not (nth 6 (harness-provider-claude--spawn-key (plist-put (copy-sequence request) :ephemeral t))))
        (should-not (nth 6 (harness-provider-claude--spawn-key
                            (plist-put (copy-sequence request) :session
                                       (list :id "k" :cwd cwd :provider-state '(:cli-session-id "a"))))))))))


;;;; The CLI's own tools, decided by the harness

(defun harness-provider-claude-native-test--reply (events)
  "Return the text the model answered with in EVENTS."
  (mapconcat (lambda (e) (plist-get e :delta))
             (harness-provider-claude-native-test--find events 'text t) ""))

(defun harness-provider-claude-native-test--names (events type)
  "Return the tool names of the EVENTS of TYPE, in order."
  (mapcar (lambda (e) (plist-get e :name)) (harness-provider-claude-native-test--find events type t)))

(ert-deftest harness-provider-claude-native-every-call-reaches-the-harness ()
  "With ask rules the harness is asked about every call, reads in the working directory too.
The calls, the questions and the results all name the harness tools,
with the harness tools' inputs; no tool is allowed by flag, and the
CLI is never told to skip its checks."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-native-tools t))
      (harness-provider-claude-native-test--with-argv (dump)
        (let* ((events (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request
                         "n1" "call native"
                         :builtin-tools '("read_file" "write_file" "edit_file" "glob" "grep" "web_fetch" "bash"))))
               (calls (harness-provider-claude-native-test--find events 'tool-call t))
               (asks (harness-provider-claude-native-test--find events 'tool-permission t))
               (results (harness-provider-claude-native-test--find events 'tool-result t))
               (argv (plist-get (funcall dump) :argv))
               (by-name (lambda (list name) (cl-find name list :key (lambda (e) (plist-get e :name)) :test #'equal)))
               (expected '("read_file" "write_file" "edit_file" "glob" "grep" "web_fetch" "bash")))
          ;; Every call is a harness tool's, run by the CLI.
          (should (equal expected (mapcar (lambda (e) (plist-get e :name)) calls)))
          (should (cl-every (lambda (e) (plist-get e :builtin)) calls))
          (should-not (cl-some (lambda (e) (plist-get e :respond)) calls))
          ;; Every call is asked about, the reads the CLI would not ask about too.
          (should (equal expected (mapcar (lambda (e) (plist-get e :name)) asks)))
          (should (equal (mapcar (lambda (e) (plist-get e :id)) calls)
                         (mapcar (lambda (e) (plist-get e :id)) asks)))
          (should (equal (length expected) (length results)))
          (should-not (cl-some (lambda (e) (plist-get e :is-error)) results))
          ;; The questions are about the harness tools' inputs.
          (should (string-suffix-p "/notes.txt" (plist-get (plist-get (funcall by-name calls "read_file") :input) :path)))
          (should (string-suffix-p "/notes.txt" (plist-get (plist-get (funcall by-name asks "read_file") :input) :path)))
          (should (string-suffix-p "/out.txt" (plist-get (plist-get (funcall by-name asks "write_file") :input) :path)))
          (should (equal "hi\n" (plist-get (plist-get (funcall by-name asks "write_file") :input) :content)))
          (should (equal "ho" (plist-get (plist-get (funcall by-name asks "edit_file") :input) :new_string)))
          (should (equal "*.txt" (plist-get (plist-get (funcall by-name asks "glob") :input) :pattern)))
          (should (equal '(:pattern "Hello" :case_sensitive :false) (plist-get (funcall by-name asks "grep") :input)))
          (should (equal '(:url "https://example.com/") (plist-get (funcall by-name asks "web_fetch") :input)))
          (should (equal '(:command "touch made.txt" :timeout 5) (plist-get (funcall by-name asks "bash") :input)))
          ;; The command line: the harness decides, nothing bypassed or allowed.
          (should (equal "Bash,Read,Write,Edit,Glob,Grep,WebFetch"
                         (harness-provider-claude-native-test--after "--tools" argv)))
          (should (equal "stdio" (harness-provider-claude-native-test--after "--permission-prompt-tool" argv)))
          (should (equal '("Bash" "Read" "Write" "Edit" "Glob" "Grep" "WebFetch")
                         (harness-plist-get-in (harness-json-parse
                                                (harness-provider-claude-native-test--after "--settings" argv))
                                               '(:permissions :ask))))
          (should (equal '("mcp__harness__*")
                         (cl-loop for (a b) on argv when (equal a "--allowedTools") collect b)))
          (harness-provider-claude-native-test--no-bypass argv)
          (should (eq 'end-turn (plist-get (harness-provider-claude-native-test--find events 'done) :stop-reason)))
          (should-not (harness-provider-claude-native-test--find events 'hint)))))))

(ert-deftest harness-provider-claude-native-without-ask-rules-reads-escape-the-harness ()
  "Without the ask rules the CLI asks only what its mode asks: the reason the rules are there."
  (harness-provider-claude-native-test--with
    (let ((events (harness-provider-claude-native-test--run
                   (harness-provider-claude-native-test--request
                    "n2" "call native" :builtin-tools '("read_file" "write_file" "glob" "grep")))))
      ;; The fake CLI runs the reads in the working directory without asking, as the real one does.
      (should (equal '("write_file") (harness-provider-claude-native-test--names events 'tool-permission)))
      (should (= 4 (length (harness-provider-claude-native-test--find events 'tool-call t))))
      (should (= 4 (length (harness-provider-claude-native-test--find events 'tool-result t)))))))

(ert-deftest harness-provider-claude-native-the-harness-can-refuse ()
  "A call the harness denies does not run, and the model is told why."
  (harness-provider-claude-native-test--with
    (let* ((harness-provider-claude-native-tools t)
           (events (harness-provider-claude-native-test--run
                    (harness-provider-claude-native-test--request
                     "n3" "call write" :builtin-tools '("read_file" "write_file"))
                    (lambda (ev)
                      (if (equal (plist-get ev :name) "write_file")
                          '(:behavior deny :message "Denied: nothing may be written here")
                        '(:behavior allow)))))
           (result (harness-provider-claude-native-test--find events 'tool-result)))
      (should (equal "write_file" (plist-get (harness-provider-claude-native-test--find events 'tool-call) :name)))
      (should (plist-get result :is-error))
      (should (equal "Denied: nothing may be written here" (plist-get result :content)))
      (should (eq 'end-turn (plist-get (harness-provider-claude-native-test--find events 'done) :stop-reason))))))

(ert-deftest harness-provider-claude-native-cli-allows-and-the-harness-only-records ()
  "With the `cli' setting the CLI runs the tools by rule; the harness hears of them, and decides nothing."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-native-tools t)
          (harness-provider-claude-native-permissions 'cli))
      (harness-provider-claude-native-test--with-argv (dump)
        (let* ((events (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request
                         "n4" "call native" :builtin-tools '("read_file" "write_file" "bash"))
                        (lambda (_ev) '(:behavior deny :message "never asked"))))
               (argv (plist-get (funcall dump) :argv)))
          (should-not (harness-provider-claude-native-test--find events 'tool-permission))
          (should (equal '("read_file" "write_file" "bash")
                         (harness-provider-claude-native-test--names events 'tool-call)))
          (should (= 3 (length (harness-provider-claude-native-test--find events 'tool-result t))))
          (should-not (cl-some (lambda (e) (plist-get e :is-error))
                               (harness-provider-claude-native-test--find events 'tool-result t)))
          (should (member "Bash,Read,Write" (cl-loop for (a b) on argv when (equal a "--allowedTools") collect b)))
          (should (equal "stdio" (harness-provider-claude-native-test--after "--permission-prompt-tool" argv)))
          (should-not (member "--settings" argv))
          (harness-provider-claude-native-test--no-bypass argv))))))

(ert-deftest harness-provider-claude-native-cli-allowance-ignored-by-policy ()
  "Where managed settings ignore the allow rule, the harness is asked instead of every call denied.
That was the first version's failure on a company laptop: the CLI
ignored the rule, had no one to ask, and denied everything."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-native-tools t)
          (harness-provider-claude-native-permissions 'cli))
      (harness-provider-claude-native-test--with-argv (dump "HARNESS_FAKE_CLAUDE_POLICY=managedRulesOnly")
        (ignore dump)
        (let ((events (harness-provider-claude-native-test--run
                       (harness-provider-claude-native-test--request
                        "n9" "call native" :builtin-tools '("read_file" "write_file" "bash")))))
          (should (equal '("write_file" "bash") (harness-provider-claude-native-test--names events 'tool-permission)))
          (should-not (cl-some (lambda (e) (plist-get e :is-error))
                               (harness-provider-claude-native-test--find events 'tool-result t)))
          (should-not (harness-provider-claude-native-test--find events 'hint)))))))

(ert-deftest harness-provider-claude-native-managed-deny-holds ()
  "A managed deny rule outranks everything the harness does: the call is refused, and said so.
The harness is not asked, does not try to get round the rule, and tells
the user that settings outrank it."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-native-tools t))
      (harness-provider-claude-native-test--with-argv (dump "HARNESS_FAKE_CLAUDE_POLICY=deny=Bash")
        (ignore dump)
        (let* ((events (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request
                         "n5" "call native" :builtin-tools '("read_file" "bash"))))
               (hint (harness-provider-claude-native-test--find events 'hint))
               (bash (cl-find "bash" (harness-provider-claude-native-test--find events 'tool-call t)
                              :key (lambda (e) (plist-get e :name)) :test #'equal))
               (result (cl-find (plist-get bash :id) (harness-provider-claude-native-test--find events 'tool-result t)
                                :key (lambda (e) (plist-get e :id)) :test #'equal)))
          (should bash)
          (should (equal '("read_file") (harness-provider-claude-native-test--names events 'tool-permission)))
          (should (plist-get result :is-error))
          (should (string-match-p "has been denied" (plist-get result :content)))
          (should hint)
          (should (string-match-p "Bash" (plist-get hint :text)))
          (should (string-match-p "bash" (plist-get hint :text)))
          (should (string-match-p "settings or managed policy outrank the harness" (plist-get hint :text)))
          (should (string-match-p "harness-provider-claude-native-permissions" (plist-get hint :text)))
          (should (string-match-p "harness-provider-claude-permission-args" (plist-get hint :text)))
          (should (string-match-p "Reason: Permission to use Bash has been denied" (plist-get hint :text)))
          (should (eq 'end-turn (plist-get (harness-provider-claude-native-test--find events 'done) :stop-reason))))))))

(ert-deftest harness-provider-claude-native-managed-rules-only ()
  "Where managed settings ignore the command line's rules, the CLI asks what its mode asks.
The ask rules do nothing there; the writes and commands still reach the
harness, and the reads the CLI runs on its own are the managed
settings' to allow."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-native-tools t))
      (harness-provider-claude-native-test--with-argv (dump "HARNESS_FAKE_CLAUDE_POLICY=managedRulesOnly")
        (ignore dump)
        (let ((events (harness-provider-claude-native-test--run
                       (harness-provider-claude-native-test--request
                        "n6" "call native" :builtin-tools '("read_file" "write_file" "glob" "bash")))))
          (should (equal '("write_file" "bash") (harness-provider-claude-native-test--names events 'tool-permission)))
          (should (= 4 (length (harness-provider-claude-native-test--find events 'tool-result t))))
          (should-not (cl-some (lambda (e) (plist-get e :is-error))
                               (harness-provider-claude-native-test--find events 'tool-result t))))))))

(ert-deftest harness-provider-claude-native-works-where-bypass-is-forbidden ()
  "Under a policy that forbids bypassing the checks every call still gets its answer.
The first version asked for `bypassPermissions', which such a policy
turns into `default': nothing was allowed, and every call was denied."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-native-tools t))
      (harness-provider-claude-native-test--with-argv (dump "HARNESS_FAKE_CLAUDE_POLICY=disableBypass")
        (let ((events (harness-provider-claude-native-test--run
                       (harness-provider-claude-native-test--request
                        "n7" "call echo and call native" :builtin-tools '("read_file" "write_file" "bash")))))
          (harness-provider-claude-native-test--no-bypass (plist-get (funcall dump) :argv))
          ;; The three of the CLI's own tools were run; the echo's result goes to the CLI only.
          (should (= 3 (length (harness-provider-claude-native-test--find events 'tool-result t))))
          (should-not (cl-some (lambda (e) (plist-get e :is-error))
                               (harness-provider-claude-native-test--find events 'tool-result t)))
          (should-not (harness-provider-claude-native-test--find events 'hint)))))))

(ert-deftest harness-provider-claude-native-change-restarts-with-resume ()
  "Turning native tools on or off, or changing who decides, restarts the process in its conversation."
  (harness-provider-claude-native-test--with
    (let* ((request (lambda (&rest extra)
                      (apply #'harness-provider-claude-native-test--request "n8" "hi" extra)))
           (process (lambda () (harness-provider-claude-session-process
                                (gethash "n8" harness-provider-claude--sessions))))
           (run (lambda (&rest extra)
                  (harness-provider-claude-native-test--run (apply request extra)))))
      (funcall run)
      (let ((proc1 (funcall process)))
        (let ((harness-provider-claude-native-tools t))
          (funcall run :builtin-tools '("read_file"))
          (should-not (eq proc1 (funcall process)))
          (let ((proc2 (funcall process)))
            (funcall run :builtin-tools '("read_file"))
            (should (eq proc2 (funcall process)))
            (let ((harness-provider-claude-native-permissions 'cli))
              (funcall run :builtin-tools '("read_file"))
              (should-not (eq proc2 (funcall process))))))))))

;;;; The plugin

(defun harness-provider-claude-native-test--plugin-dir ()
  "Return the plugin directory in the test's state directory."
  (expand-file-name "claude-plugin/emacs-harness" harness-state-directory))

(ert-deftest harness-provider-claude-native-plugin-serves-the-tools ()
  "The CLI loads the plugin; its server, the real relay, reaches the harness's tools.
The first message waits for the plugin's server, so the model has its
tools from its first request."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t))
      (harness-provider-claude-native-test--with-argv (dump "HARNESS_FAKE_CLAUDE_PLUGIN_DELAY=0.6")
        (let* ((events (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request "p1" "call echo and list your tools and show results")))
               (dump-data (funcall dump))
               (argv (plist-get dump-data :argv))
               (call (harness-provider-claude-native-test--find events 'tool-call))
               (text (harness-provider-claude-native-test--reply events)))
          ;; The plugin, in place of the SDK server.
          (should (equal (harness-provider-claude-native-test--plugin-dir)
                         (harness-provider-claude-native-test--after "--plugin-dir" argv)))
          (should (file-exists-p (expand-file-name ".claude-plugin/plugin.json"
                                                   (harness-provider-claude-native-test--plugin-dir))))
          (should-not (member "--mcp-config" argv))
          (should-not (member "--strict-mcp-config" argv))
          (should (equal "mcp__plugin_emacs-harness_harness__*"
                         (harness-provider-claude-native-test--after "--allowedTools" argv)))
          (harness-provider-claude-native-test--no-bypass argv)
          ;; The CLI's environment names the relay's port and token, and no connector.
          (let ((env (plist-get dump-data :env)))
            (should (string-match-p "\\`[0-9]+\\'" (format "%s" (plist-get env :HARNESS_MCP_PORT))))
            (should (> (length (plist-get env :HARNESS_MCP_TOKEN)) 30))
            (should (equal "false" (plist-get env :ENABLE_CLAUDEAI_MCP_SERVERS)))
            ;; A plugin's tool call that waits for a person is not cut short.
            (should (equal "0" (plist-get env :CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT))))
          ;; A call of the plugin's tool is the harness's tool call.
          (should (equal "echo" (plist-get call :name)))
          (should-not (plist-get call :builtin))
          (should (equal "ping" (plist-get (plist-get call :input) :text)))
          (should (functionp (plist-get call :respond)))
          ;; The result came back through the relay, and the model had the
          ;; tool in its first request, though the plugin takes 0.6 seconds.
          (should (equal "tools: echo ; results: echo: ping" text))
          (should-not (harness-provider-claude-native-test--find events 'hint))
          (should (eq 'end-turn (plist-get (harness-provider-claude-native-test--find events 'done) :stop-reason))))))))

(ert-deftest harness-provider-claude-native-plugin-process-is-kept ()
  "A second turn goes to the same process, which still has the plugin's tools."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t))
      (harness-provider-claude-native-test--run (harness-provider-claude-native-test--request "p2" "hi"))
      (let ((proc (harness-provider-claude-session-process (gethash "p2" harness-provider-claude--sessions))))
        (let ((events (harness-provider-claude-native-test--run
                       (harness-provider-claude-native-test--request "p2" "call echo and show results"))))
          (should (eq proc (harness-provider-claude-session-process (gethash "p2" harness-provider-claude--sessions))))
          (should (equal "echo" (plist-get (harness-provider-claude-native-test--find events 'tool-call) :name)))
          (should (equal "results: echo: ping" (harness-provider-claude-native-test--reply events))))))))

(ert-deftest harness-provider-claude-native-plugin-with-native-tools ()
  "Both modes: the CLI's own tools, and the plugin for the rest. No SDK server at all."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t)
          (harness-provider-claude-native-tools t))
      (harness-provider-claude-native-test--with-argv (dump)
        (let* ((events (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request
                         "p3" "call echo and call read and show results" :builtin-tools '("read_file" "bash"))))
               (argv (plist-get (funcall dump) :argv)))
          (should (equal '("echo" "read_file")
                         (harness-provider-claude-native-test--names events 'tool-call)))
          (should (equal '("read_file") (harness-provider-claude-native-test--names events 'tool-permission)))
          (should (equal "Bash,Read" (harness-provider-claude-native-test--after "--tools" argv)))
          (should (harness-provider-claude-native-test--after "--plugin-dir" argv))
          (should-not (member "--mcp-config" argv))
          (should-not (cl-some (lambda (a) (string-match-p "mcp__harness__" a)) argv))
          (harness-provider-claude-native-test--no-bypass argv)
          (should (string-match-p "\\`results: echo: ping | " (harness-provider-claude-native-test--reply events))))))))

(ert-deftest harness-provider-claude-native-plugin-foreign-tool-is-refused ()
  "Another server's tool is refused when the CLI asks, and said when the CLI does not.
Where the user's Claude Code settings allow the tool the CLI runs it
without asking; the harness then only hears of the call, and says so
once."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t))
      (harness-provider-claude-native-test--with-argv (dump)
        (let* ((events (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request "p15" "call another server")))
               (result (harness-provider-claude-native-test--find events 'tool-result)))
          (ignore dump)
          ;; Refused: the call is an error the model reads, naming the tool.
          (should (plist-get result :is-error))
          (should (string-match-p "only its own tools" (plist-get result :content)))
          (should-not (harness-provider-claude-native-test--find events 'tool-call))
          (should-not (harness-provider-claude-native-test--find events 'hint)))))
    ;; Allowed by the user's own settings: the CLI runs it, and the harness hears of it.
    (let ((harness-provider-claude-plugin t)
          (process-environment (cons "HARNESS_FAKE_CLAUDE_ALLOW=mcp__other__query" process-environment)))
      (let* ((events (harness-provider-claude-native-test--run
                      (harness-provider-claude-native-test--request "p16" "call another server")))
             (hint (harness-provider-claude-native-test--find events 'hint)))
        (should hint)
        (should (string-match-p "mcp__other__query" (plist-get hint :text)))
        (should (string-match-p "ran mcp__other__query from your MCP server other" (plist-get hint :text)))
        (should (string-match-p "allowed it without asking the harness" (plist-get hint :text)))
        (should (string-match-p "refuses such calls when Claude Code asks it" (plist-get hint :text)))
        (should-not (harness-provider-claude-native-test--find events 'tool-call))
        (should (eq 'end-turn (plist-get (harness-provider-claude-native-test--find events 'done) :stop-reason)))))))

(ert-deftest harness-provider-claude-native-plugin-not-for-remote-sessions ()
  "A session on another host never uses the plugin: its relay would not reach this Emacs."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t)
          (cwd (harness-test-temp-dir))
          (tools (list '(:name "echo" :description "e" :schema (:type "object")))))
      (should (harness-provider-claude--plugin-wanted-p
               (list :session (list :id "x" :cwd cwd) :tools tools)))
      (should-not (harness-provider-claude--plugin-wanted-p
                   (list :session (list :id "x" :cwd cwd :host "/ssh:box:") :tools tools)))
      (should-not (harness-provider-claude--plugin-wanted-p
                   (list :session (list :id "x" :cwd "/ssh:box:/home/me/") :tools tools)))
      (should-not (harness-provider-claude--plugin-wanted-p
                   (list :session (list :id "x" :cwd cwd) :tools tools :ephemeral t)))
      ;; A request with no tools of the harness's needs none of the plugin either.
      (should-not (harness-provider-claude--plugin-wanted-p
                   (list :session (list :id "x" :cwd cwd)))))))

(ert-deftest harness-provider-claude-native-plugin-falls-back-when-its-server-fails ()
  "A plugin server that fails sends the turn on over the SDK channel, and says so.
The conversation goes on in a new process, which has the tools; the
plugin stays off for later turns until it is turned off and on."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t))
      (harness-provider-claude-native-test--with-argv (dump "HARNESS_FAKE_CLAUDE_PLUGIN=fail")
        (let* ((events (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request "p4" "call echo and show results")))
               (hint (harness-provider-claude-native-test--find events 'hint))
               (argv (plist-get (funcall dump) :argv)))
          (should hint)
          (should (string-match-p "plugin mode is off" (plist-get hint :text)))
          (should (string-match-p "is failed" (plist-get hint :text)))
          (should (stringp harness-provider-claude--plugin-broken))
          ;; The process that ran the turn serves the tools over the SDK channel.
          (should (member "--mcp-config" argv))
          (should-not (member "--plugin-dir" argv))
          (should (equal "echo" (plist-get (harness-provider-claude-native-test--find events 'tool-call) :name)))
          (should (equal "results: echo: ping" (harness-provider-claude-native-test--reply events)))
          (should (eq 'end-turn (plist-get (harness-provider-claude-native-test--find events 'done) :stop-reason)))
          ;; Later turns do not try the plugin again ...
          (let ((again (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request "p4" "hi"))))
            (should-not (harness-provider-claude-native-test--find again 'hint))
            (should-not (member "--plugin-dir" (plist-get (funcall dump) :argv))))
          ;; ... until the option is set again.
          (customize-set-variable 'harness-provider-claude-plugin t)
          (should-not harness-provider-claude--plugin-broken))))))

(ert-deftest harness-provider-claude-native-plugin-falls-back-when-its-server-never-comes ()
  "A plugin server still pending after the wait sends the turn on without it."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t)
          (harness-provider-claude--plugin-wait 1.0))
      (harness-provider-claude-native-test--with-argv (dump "HARNESS_FAKE_CLAUDE_PLUGIN=never")
        (let* ((events (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request "p5" "call echo and show results")))
               (hint (harness-provider-claude-native-test--find events 'hint)))
          (should (string-match-p "did not come up in time" (plist-get hint :text)))
          (should (member "--mcp-config" (plist-get (funcall dump) :argv)))
          (should (equal "results: echo: ping" (harness-provider-claude-native-test--reply events))))))))

(ert-deftest harness-provider-claude-native-plugin-cli-that-never-answers ()
  "A CLI that does not answer the question about its servers does not hold the turn for good."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t)
          (harness-provider-claude--plugin-wait 0.5))
      (harness-provider-claude-native-test--with-argv (dump "HARNESS_FAKE_CLAUDE_MCP_STATUS=silent")
        (let* ((events (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request "p10" "call echo and show results")))
               (hint (harness-provider-claude-native-test--find events 'hint)))
          (should (string-match-p "did not come up in time" (plist-get hint :text)))
          (should (member "--mcp-config" (plist-get (funcall dump) :argv)))
          (should (equal "results: echo: ping" (harness-provider-claude-native-test--reply events))))))))

(ert-deftest harness-provider-claude-native-plugin-cli-that-cannot-say ()
  "A CLI too old to answer `mcp_status' is trusted: the message goes at once, the plugin stays.
Whether its tools are there for that first request is the CLI's race
to win; nothing here waits for an answer that cannot come."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t))
      (harness-provider-claude-native-test--with-argv (dump "HARNESS_FAKE_CLAUDE_MCP_STATUS=unsupported")
        (let* ((started (float-time))
               (events (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request "p11" "hi"))))
          (ignore dump)
          (should (< (- (float-time) started) 5))
          (should-not harness-provider-claude--plugin-broken)
          (should-not (cl-some (lambda (e) (string-match-p "plugin mode is off" (plist-get e :text)))
                               (harness-provider-claude-native-test--find events 'hint t)))
          (should (eq 'end-turn (plist-get (harness-provider-claude-native-test--find events 'done) :stop-reason))))))))

(ert-deftest harness-provider-claude-native-plugin-refused-by-policy ()
  "A CLI that refuses --plugin-dir (managed settings) exits at once; the turn goes on without it.
Nothing in the harness works round the policy: the plugin is dropped."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t))
      (harness-provider-claude-native-test--with-argv (dump "HARNESS_FAKE_CLAUDE_POLICY=disableSideload")
        (let* ((events (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request "p6" "call echo and show results")))
               (hint (harness-provider-claude-native-test--find events 'hint)))
          (should hint)
          (should (string-match-p "refused --plugin-dir" (plist-get hint :text)))
          (should (string-match-p "disableSideloadFlags" (plist-get hint :text)))
          (should (stringp harness-provider-claude--plugin-broken))
          (should (member "--mcp-config" (plist-get (funcall dump) :argv)))
          (should (equal "results: echo: ping" (harness-provider-claude-native-test--reply events)))
          (should (eq 'end-turn (plist-get (harness-provider-claude-native-test--find events 'done) :stop-reason))))))))

(ert-deftest harness-provider-claude-native-plugin-refusal-keeps-the-conversation ()
  "A plugin refused on a resumed conversation resumes it again, without the plugin."
  (harness-provider-claude-native-test--with
    (let ((store (make-temp-file "harness-claude-store-" t))
          (first-cli nil))
      (let ((process-environment (cons (concat "HARNESS_FAKE_CLAUDE_STORE=" store) process-environment)))
        ;; A first turn, without the plugin.
        (let ((events (harness-provider-claude-native-test--run
                       (harness-provider-claude-native-test--request "p7" "remember this"))))
          (setq first-cli (plist-get (plist-get (harness-provider-claude-native-test--find events 'provider-state) :state)
                                     :cli-session-id)))
        ;; The plugin is turned on and refused: the same conversation goes on.
        (let ((harness-provider-claude-plugin t)
              (process-environment (cons "HARNESS_FAKE_CLAUDE_POLICY=disableSideload" process-environment)))
          (let ((events (harness-provider-claude-native-test--run
                         (harness-provider-claude-native-test--request
                          "p7" "recall" :provider-state (list :cli-session-id first-cli)))))
            (should (string-match-p "remember this"
                                    (mapconcat (lambda (e) (plist-get e :delta))
                                               (harness-provider-claude-native-test--find events 'text t) "")))))))))

(ert-deftest harness-provider-claude-native-plugin-foreign-servers-are-said ()
  "An MCP server of the user's own that the CLI also loads is said once, and refused."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t))
      (harness-provider-claude-native-test--with-argv (dump "HARNESS_FAKE_CLAUDE_USER_MCP=my-database")
        (ignore dump)
        (let* ((first (harness-provider-claude-native-test--run
                       (harness-provider-claude-native-test--request "p8" "hi")))
               (hint (harness-provider-claude-native-test--find first 'hint))
               (second (harness-provider-claude-native-test--run
                        (harness-provider-claude-native-test--request "p8" "hi again"))))
          (should (string-match-p "my-database" (plist-get hint :text)))
          (should (string-match-p "refuses" (plist-get hint :text)))
          ;; Once for the process.
          (should-not (harness-provider-claude-native-test--find second 'hint)))))))

(ert-deftest harness-provider-claude-native-cancel-while-waiting-for-the-plugin ()
  "Cancelling a turn that waits for the plugin's server ends it at once."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t)
          (events nil))
      (let ((process-environment (cons "HARNESS_FAKE_CLAUDE_PLUGIN=never" process-environment)))
        (let ((handle (harness-call 'provider/complete
                                    (plist-put (harness-provider-claude-native-test--request "p9" "hi")
                                               :on-event (lambda (ev) (push ev events))))))
          (accept-process-output nil 0.3)
          (should-not (harness-provider-claude-native-test--find events 'done))
          (funcall (plist-get handle :cancel))
          (harness-test-wait (lambda () (harness-provider-claude-native-test--find events 'done)) 3 "the end")
          (should (eq 'cancelled (plist-get (harness-provider-claude-native-test--find events 'done) :stop-reason))))))))

(defun harness-provider-claude-native-test--run-async (request on-event)
  "Start REQUEST with ON-EVENT as its callback; return its handle."
  (harness-call 'provider/complete
                (plist-put (copy-sequence request) :on-event on-event)))

(ert-deftest harness-provider-claude-native-old-wait-acts-on-nothing ()
  "A wait for the plugin's server that a later message replaced does nothing more.
Its watchdog used to fire into whatever turn was running by then, kill
that turn's process and turn the plugin off for every session."
  (harness-provider-claude-native-test--with
   (let ((harness-provider-claude-plugin t)
         (harness-provider-claude--plugin-wait 60.0)
         (harness-provider-claude--plugin-poll 0.05)
         (first-events nil)
         (second-events nil))
     (let ((process-environment (cons "HARNESS_FAKE_CLAUDE_PLUGIN=never" process-environment)))
       (harness-provider-claude-native-test--run-async
        (harness-provider-claude-native-test--request "p12" "hi")
        (lambda (ev) (push ev first-events)))
       (let* ((entry (harness-test-wait
                      (lambda () (let ((e (gethash "p12" harness-provider-claude--sessions)))
                                   (and e (harness-provider-claude-session-plugin-gate e) e)))
                      10 "the first plugin wait"))
              (old-timer (car (harness-provider-claude-session-plugin-gate entry))))
         ;; A second message replaces the first before the plugin is up.
         (harness-provider-claude-native-test--run-async
          (harness-provider-claude-native-test--request "p12" "hi again")
          (lambda (ev) (push ev second-events)))
         (let ((new-timer
                (harness-test-wait
                 (lambda ()
                   (let* ((e (gethash "p12" harness-provider-claude--sessions))
                          (timer (and e (car (harness-provider-claude-session-plugin-gate e)))))
                     (and (timerp timer) (not (eq timer old-timer)) timer)))
                 10 "the second plugin wait")))
           (should-not (memq old-timer timer-list))
           ;; Simulate the old callback arriving late while the new wait lives.
           (apply (timer--function old-timer) (timer--args old-timer))
           (should-not (harness-provider-claude-native-test--find second-events 'hint))
           (should (memq new-timer timer-list))
           (timer-event-handler new-timer)))
       (harness-test-wait (lambda () (harness-provider-claude-native-test--find second-events 'done))
                          15 "the second turn to end")
       (should (equal "superseded by a new request"
                      (plist-get (harness-provider-claude-native-test--find first-events 'done) :error)))
       ;; Exactly one fallback, the second message's, and one end.
       (should (= 1 (length (harness-provider-claude-native-test--find second-events 'done t))))
       (should (= 1 (length (harness-provider-claude-native-test--find second-events 'hint t))))
       (should (string-match-p "did not come up in time"
                               (plist-get (harness-provider-claude-native-test--find second-events 'hint) :text)))
       (should (eq 'end-turn (plist-get (harness-provider-claude-native-test--find second-events 'done) :stop-reason)))
       (should (= 1 (length (harness-provider-claude-native-test--find second-events 'hint t))))))))

(ert-deftest harness-provider-claude-native-cancel-while-waiting-kills-the-process ()
  "A message cancelled before it was sent takes its process with it: the CLI never got what it carried.
The next turn opens the conversation again rather than send its message
into a process that missed the first."
  (harness-provider-claude-native-test--with
    (let ((harness-provider-claude-plugin t)
          (harness-provider-claude--plugin-wait 30)
          (events nil))
      (let ((process-environment (cons "HARNESS_FAKE_CLAUDE_PLUGIN=never" process-environment)))
        (let ((handle (harness-provider-claude-native-test--run-async
                       (harness-provider-claude-native-test--request "p14" "first message")
                       (lambda (ev) (push ev events)))))
          (accept-process-output nil 0.3)
          (funcall (plist-get handle :cancel))
          (harness-test-wait (lambda () (harness-provider-claude-native-test--find events 'done)) 5 "the end")
          (should (eq 'cancelled (plist-get (harness-provider-claude-native-test--find events 'done) :stop-reason)))
          (should-not (process-live-p (harness-provider-claude-session-process
                                       (gethash "p14" harness-provider-claude--sessions)))))))))

(ert-deftest harness-provider-claude-native-relay-going-is-said ()
  "A process that loses the plugin's relay keeps running, but its next turn starts a new one.
The turn that is over has no events to carry the word, so it is kept as
a hint of the session."
  (harness-provider-claude-native-test--with
    (dolist (m '(store session)) (harness-test-load-module m))
    (let* ((harness-provider-claude-plugin t)
           (cwd (harness-provider-claude-native-test--cwd))
           (sid (plist-get (harness-call 'session/create :cwd cwd :model "claude:claude-fable-5-1") :id))
           (events nil))
      (harness-provider-claude-native-test--run-async
       (harness-provider-claude-native-test--request sid "hi" :session (list :id sid :cwd cwd))
       (lambda (ev) (push ev events)))
      (harness-test-wait (lambda () (harness-provider-claude-native-test--find events 'done)) 15 "the turn")
      (let* ((entry (gethash sid harness-provider-claude--sessions))
             (bridge (harness-provider-claude-session-bridge entry))
             (proc (harness-provider-claude-session-process entry)))
        (should bridge)
        (should-not (memq 'relay-lost (harness-provider-claude-session-spawn-key entry)))
        ;; The relay's connection goes while the CLI still runs.
        (delete-process (harness-claude-plugin-bridge-conn bridge))
        (harness-test-wait (lambda () (memq 'relay-lost (harness-provider-claude-session-spawn-key entry)))
                           10 "the provider to see it go")
        (should (process-live-p proc))
        (let ((hints (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'hint))
                                       (harness-call 'session/nodes sid))))
          (should hints)
          (should (string-match-p "connection to the harness ended"
                                  (plist-get (car (last hints)) :content))))
        ;; Its next turn does not reuse it.
        (harness-provider-claude-native-test--run
         (harness-provider-claude-native-test--request sid "again" :session (list :id sid :cwd cwd)))
        (should-not (eq proc (harness-provider-claude-session-process entry)))))))

;;;; Answers to the CLI's questions

(ert-deftest harness-provider-claude-native-stale-record-lets-go ()
  "A record of an older layout, which a reload keeps, lets go of its bridge and its wait."
  (harness-provider-claude-native-test--with
    (let* ((bridge (harness-claude-plugin-open #'ignore))
           (timer (run-at-time 60 nil #'ignore))
           (bridge-slot (cl-struct-slot-offset 'harness-provider-claude-session 'bridge))
           (gate-slot (cl-struct-slot-offset 'harness-provider-claude-session 'plugin-gate))
           ;; A record of the layout before the last slots were added: the
           ;; same tag, and shorter.
           (record (make-vector (1+ gate-slot) nil)))
      (aset record 0 'harness-provider-claude-session)
      (aset record bridge-slot bridge)
      (aset record gate-slot (list timer))  ; a wait's gate
      (puthash "old" record harness-provider-claude--sessions)
      (should (memq timer timer-list))
      (harness-provider-claude--drop-stale-entries)
      (should-not (gethash "old" harness-provider-claude--sessions))
      (should-not (harness-claude-plugin-connected-p bridge))
      (should-not (timer--triggered timer))
      (should-not (memq timer timer-list))
      ;; Its token is no good any more, either.
      (should-not (gethash (harness-claude-plugin-bridge-token bridge) harness-claude-plugin--bridges)))))

(ert-deftest harness-provider-claude-native-can-use-tool ()
  "The harness lets its own tools through, whichever server serves them, and refuses the rest."
  (harness-provider-claude-native-test--with
    (let* ((sent nil)
           (entry (harness-provider-claude--make-session :id "cu" :active t)))
      (cl-letf (((symbol-function 'harness-provider-claude--send)
                 (lambda (_entry object) (push object sent))))
        (dolist (name '("mcp__harness__echo" "mcp__plugin_emacs-harness_harness__echo"))
          (setq sent nil)
          (harness-provider-claude--can-use-tool entry "r" (list :tool_name name :input '(:text "x")))
          (should (equal "allow" (harness-plist-get-in (car sent) '(:response :response :behavior)))))
        (dolist (name '("mcp__my-database__query" "Task"))
          (setq sent nil)
          (harness-provider-claude--can-use-tool entry "r" (list :tool_name name :input '(:q "x")))
          (should (equal "deny" (harness-plist-get-in (car sent) '(:response :response :behavior))))
          (should (string-match-p "only its own tools"
                                  (harness-plist-get-in (car sent) '(:response :response :message)))))))))


;;;; Sessions: the turn, the transcript and the permission chain

(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-perms-rules)

(defmacro harness-provider-claude-native-test--with-sessions (&rest body)
  "Run BODY with sessions whose turns the agent runs on the fake CLI.
The harness's file, shell and web tools and its permission chain are
loaded, with standing rules that allow what the test does.  BODY sees
CWD, a directory for the sessions."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-provider-claude-native-test--setup)
     (dolist (m '(store project config provider-demo tools tools-fs tools-shell tools-web
                        perms session agent))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (let ((cwd (harness-provider-claude-native-test--cwd))
           (harness-perms-rules '((:tool "read_file" :behavior allow)
                                  (:tool "write_file" :behavior allow)
                                  (:tool "edit_file" :behavior allow)
                                  (:tool "glob" :behavior allow)
                                  (:tool "grep" :behavior allow)
                                  (:tool "web_fetch" :behavior allow)
                                  (:tool "bash" :behavior allow)))
           (default-directory dir))
       (unwind-protect (progn ,@body)
         (harness-provider-claude-close-all)
         (setq harness-provider-claude-native-tools nil
               harness-provider-claude-plugin nil
               harness-provider-claude--plugin-broken nil)))))

(defun harness-provider-claude-native-test--nodes (sid kind)
  "Return the nodes of KIND in session SID's transcript, oldest first."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) kind)) (harness-call 'session/nodes sid)))

(ert-deftest harness-provider-claude-native-session-runs-the-tools-with-the-cli ()
  "A session on Claude Code gets the harness tools run by the CLI and records them as its own.
`tools/builtin' names them and `tools/list' leaves them out, so the CLI
is served the rest; the transcript has each call under the harness
tool's name and title, decided by the permission chain, with the CLI's
output as its result."
  (harness-provider-claude-native-test--with-sessions
    (let* ((harness-provider-claude-native-tools t)
           (sid (plist-get (harness-call 'session/create :cwd cwd :model "claude:claude-fable-5-1"
                                         :permission-mode 'ask)
                           :id)))
      (let ((native (harness-call 'tools/builtin sid))
            (served (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list sid))))
        (dolist (name '("bash" "read_file" "write_file" "edit_file" "glob" "grep" "web_fetch"))
          (should (member name native))
          (should-not (member name served)))
        ;; What the CLI has no counterpart of stays the harness's.
        (should (member "list_dir" served))
        (should-not (member "list_dir" native)))
      (harness-provider-claude-native-test--with-argv (dump)
        (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "call native")) :stop-reason)))
        (let ((argv (plist-get (funcall dump) :argv)))
          (should (equal "stdio" (harness-provider-claude-native-test--after "--permission-prompt-tool" argv)))
          (should (member "--settings" argv))
          (harness-provider-claude-native-test--no-bypass argv)))
      (let* ((calls (harness-provider-claude-native-test--nodes sid 'tool-call))
             (results (harness-provider-claude-native-test--nodes sid 'tool-result)))
        (should (equal '("read_file" "write_file" "edit_file" "glob" "grep" "web_fetch" "bash")
                       (mapcar (lambda (n) (plist-get n :tool)) calls)))
        (should (cl-every (lambda (n) (plist-get (plist-get n :meta) :builtin)) calls))
        ;; Titled as the harness tools are.
        (should (string-prefix-p "Read file: " (plist-get (nth 0 calls) :title)))
        (should (string-prefix-p "Write file: " (plist-get (nth 1 calls) :title)))
        (should (string-prefix-p "Bash: touch made.txt" (plist-get (nth 6 calls) :title)))
        ;; A result for each call, with the CLI's own output.
        (should (equal (mapcar (lambda (n) (plist-get n :call-id)) calls)
                       (mapcar (lambda (n) (plist-get n :call-id)) results)))
        (should-not (cl-some (lambda (n) (plist-get n :is-error)) results))
        (should (string-match-p "ran Read" (plist-get (nth 0 results) :output)))))))

(ert-deftest harness-provider-claude-native-session-keeps-long-output-short ()
  "The transcript keeps no more of a long output than a harness tool's may be."
  (harness-provider-claude-native-test--with-sessions
    (let* ((harness-provider-claude-native-tools t)
           (process-environment (cons "HARNESS_FAKE_CLAUDE_BIG=100000" process-environment))
           (sid (plist-get (harness-call 'session/create :cwd cwd :model "claude:claude-fable-5-1") :id)))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "call read")) :stop-reason)))
      (let ((output (plist-get (car (harness-provider-claude-native-test--nodes sid 'tool-result)) :output)))
        (should (< (length output) 31000))
        (should (string-prefix-p "xxxx" output))
        (should (string-match-p "70000 more characters" output))))))

(ert-deftest harness-provider-claude-native-session-permission-rules-decide ()
  "The harness's standing rules decide the CLI's tools: a rule that denies write_file refuses the CLI's Write."
  (harness-provider-claude-native-test--with-sessions
    (let* ((harness-provider-claude-native-tools t)
           (harness-perms-rules (cons '(:tool "write_file" :behavior deny) harness-perms-rules))
           (sid (plist-get (harness-call 'session/create :cwd cwd :model "claude:claude-fable-5-1") :id)))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "call write")) :stop-reason)))
      (let ((call (car (harness-provider-claude-native-test--nodes sid 'tool-call)))
            (result (car (harness-provider-claude-native-test--nodes sid 'tool-result))))
        (should (equal "write_file" (plist-get call :tool)))
        (should (plist-get result :is-error))
        (should (string-match-p "Denied" (plist-get result :output)))
        (should (plist-get (plist-get result :meta) :denied))))))

(ert-deftest harness-provider-claude-native-session-required-sandbox-keeps-bash ()
  "Under a required sandbox bash stays a harness tool: the CLI's Bash is not sandboxed."
  (harness-provider-claude-native-test--with-sessions
    (let* ((harness-provider-claude-native-tools t)
           (harness-sandbox-policy 'required)
           (sid (plist-get (harness-call 'session/create :cwd cwd :model "claude:claude-fable-5-1") :id)))
      (should-not (member "bash" (harness-call 'tools/builtin sid)))
      (should (member "read_file" (harness-call 'tools/builtin sid)))
      (should (member "bash" (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list sid)))))))

(ert-deftest harness-provider-claude-native-session-off-by-default ()
  "With the option off a session's tools are the harness's own, as before."
  (harness-provider-claude-native-test--with-sessions
    (let ((sid (plist-get (harness-call 'session/create :cwd cwd :model "claude:claude-fable-5-1") :id)))
      (should-not (harness-call 'tools/builtin sid))
      (should (member "read_file" (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list sid)))))))

(ert-deftest harness-provider-claude-native-session-other-providers-are-untouched ()
  "A session on another provider gets none of the CLI's tools."
  (harness-provider-claude-native-test--with-sessions
    (let* ((harness-provider-claude-native-tools t)
           (sid (plist-get (harness-call 'session/create :cwd cwd :model "demo:demo") :id)))
      (should-not (harness-call 'tools/builtin sid)))))

(provide 'harness-provider-claude-native-test)
;;; harness-provider-claude-native-test.el ends here
