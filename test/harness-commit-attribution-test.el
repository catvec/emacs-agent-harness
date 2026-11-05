;;; harness-commit-attribution-test.el --- Tests for private commit attribution  -*- lexical-binding: t; -*-

;;; Commentary:

;; The commit-attribution module feeds git-ai checkpoints from the
;; harness's own tool calls, stores redacted prompts only in a private
;; notes service, and reports from that service.  These tests make git
;; repositories of their own, use a fake git-ai that records the
;; payloads it receives, and run the real notes service script
;; (scripts/attribution-notes-server) on a loopback port.  They read no
;; global or system git configuration, so a `core.hooksPath' on the
;; machine cannot move the hooks.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)

(defvar harness-commit-attribution)
(defvar harness-commit-attribution-git-ai-program)
(defvar harness-commit-attribution-git-ai-directory)
(defvar harness-commit-attribution-notes-mode)
(defvar harness-commit-attribution-notes-url)
(defvar harness-commit-attribution-notes-token)
(defvar harness-commit-attribution-prompt-mode)
(defvar harness-commit-attribution-prompt-sync)
(defvar harness-commit-attribution-backend)
(defvar harness-commit-attribution-include-subagents)
(defvar harness-commit-attribution-excerpt-chars)
(defvar harness-commit-attribution--version-cache)
(defvar harness-commit-attribution--session-cache)
(defvar harness-commit-attribution--prompts)
(defvar harness-commit-attribution--turns)
(defvar harness-commit-attribution--calls)
(defvar harness-commit-attribution--seen-results)
(defvar harness-commit-attribution--last-error)
(defvar harness-commit-attribution--queues)
(defvar harness-commit-attribution--running)
(defvar harness-commit-attribution--installed)
(defvar harness-commit-attribution--noted)
(defvar harness-commit-attribution--pass-memo)
(defvar harness-commit-attribution--flush-waiters)
(defvar harness-commit-attribution--prompts-sent)
(defvar harness-commit-attribution--prompts-sending)
(defvar harness-commit-attribution--prompt-error)

(declare-function harness-commit-attribution--install "harness-commit-attribution" (root))
(declare-function harness-commit-attribution--remove "harness-commit-attribution" (root))
(declare-function harness-commit-attribution--hook "harness-commit-attribution" ())
(declare-function harness-commit-attribution--hook-p "harness-commit-attribution" (text))
(declare-function harness-commit-attribution--recorded "harness-commit-attribution" ())
(declare-function harness-commit-attribution--main "harness-commit-attribution" (dir))
(declare-function harness-commit-attribution--pass "harness-commit-attribution" (&optional dirs))
(declare-function harness-commit-attribution--flush "harness-commit-attribution" ())
(declare-function harness-commit-attribution--conversation "harness-commit-attribution" (session prompt-id model))
(declare-function harness-commit-attribution--system-conversation "harness-commit-attribution" (action))
(declare-function harness-commit-attribution--payload "harness-commit-attribution" (context kind &optional paths command tool-id))
(declare-function harness-commit-attribution--note-summary "harness-commit-attribution" (content))
(declare-function harness-commit-attribution--report-data "harness-commit-attribution" (commits notes))
(declare-function harness-commit-attribution--write-context "harness-commit-attribution" (context command))
(declare-function harness-commit-attribution--session-info "harness-commit-attribution" (sid))
(declare-function harness-commit-attribution-redact-prompts "harness-commit-attribution" (run))

(defvar harness-commit-attribution-test--sessions nil
  "Session id -> plist, for the `session/get' stub of these tests.")

(defvar harness-commit-attribution-test--tmp-dir nil
  "The directory the `session/tmp-dir' stub returns.")

(defvar harness-commit-attribution-test--log nil
  "The file the fake git-ai appends its calls to.")

(defvar harness-commit-attribution-test--root nil
  "The repository the test session works in.")

(defun harness-commit-attribution-test--session-get (id)
  "Return the test session ID."
  (gethash id harness-commit-attribution-test--sessions))

(defun harness-commit-attribution-test--session-tmp (_id)
  "Return the test sessions' temporary directory."
  harness-commit-attribution-test--tmp-dir)

(defun harness-commit-attribution-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure, return stdout."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "Running git %s failed: %s" args (buffer-string)))
      (buffer-string))))

(defun harness-commit-attribution-test--make-repo (base)
  "Create BASE/repo with one commit; return its directory."
  (let ((root (file-name-as-directory (expand-file-name "repo/" base))))
    (make-directory root t)
    (harness-commit-attribution-test--git root "init" "-q" "-b" "main")
    (harness-commit-attribution-test--git root "config" "user.name" "Harness Test")
    (harness-commit-attribution-test--git root "config" "user.email" "test@example.invalid")
    (harness-commit-attribution-test--git root "config" "commit.gpgsign" "false")
    (with-temp-file (expand-file-name "README" root) (insert "hello\n"))
    (harness-commit-attribution-test--git root "add" "README")
    (harness-commit-attribution-test--git root "commit" "-q" "-m" "initial")
    root))

(defun harness-commit-attribution-test--commit (root name content message)
  "Write NAME with CONTENT in ROOT, commit it with MESSAGE, and return the SHA."
  (with-temp-file (expand-file-name name root) (insert content))
  (harness-commit-attribution-test--git root "add" name)
  (harness-commit-attribution-test--git root "commit" "-q" "-m" message)
  (string-trim (harness-commit-attribution-test--git root "rev-parse" "HEAD")))

(defun harness-commit-attribution-test--fake-git-ai (base)
  "Write a fake git-ai under BASE; return (PROGRAM . LOG-FILE)."
  (let* ((dir (expand-file-name "bin/" base))
         (program (expand-file-name "git-ai" dir))
         (log (expand-file-name "git-ai.log" base)))
    (make-directory dir t)
    (with-temp-file program
      (insert
       "#!/bin/sh\n"
       "if [ \"$1\" = \"--version\" ]; then echo 'git-ai 1.7.6-fake'; exit 0; fi\n"
       "if [ \"$1\" = \"show\" ]; then\n"
       "  [ -n \"$FAKE_GIT_AI_SHOW\" ] && cat \"$FAKE_GIT_AI_SHOW\"\n"
       "  exit 0\n"
       "fi\n"
       "if [ \"$1\" = \"checkpoint\" ]; then\n"
       "  {\n"
       "    printf '===CALL===\\n'\n"
       "    printf 'cwd=%s\\n' \"$PWD\"\n"
       "    for a in \"$@\"; do printf 'arg=%s\\n' \"$a\"; done\n"
       "    printf '%s\\n' '---stdin---'\n"
       "    cat\n"
       "    printf '\\n'\n"
       "  } >> \"${FAKE_GIT_AI_LOG:-/dev/null}\"\n"
       "fi\n"
       "exit 0\n"))
    (set-file-modes program #o755)
    (cons program log)))

(defun harness-commit-attribution-test--make-ready ()
  "Make the loaded commit-attribution module ready for the test bus.
The module's `:requires' list names the whole harness; these tests
exercise its own code with a `session/get' stub and do not load every
module those requirements name."
  (let ((module (harness-module-get 'commit-attribution)))
    (when module
      (setf (harness-module-state module) 'ready
            (harness-module-error module) nil))
    (harness-commit-attribution--init)))

(defun harness-commit-attribution-test--reset ()
  "Forget the module's tables and caches."
  (dolist (table (list harness-commit-attribution--session-cache
                       harness-commit-attribution--prompts
                       harness-commit-attribution--turns
                       harness-commit-attribution--calls
                       harness-commit-attribution--seen-results
                       harness-commit-attribution--last-error
                       harness-commit-attribution--queues
                       harness-commit-attribution--running
                       harness-commit-attribution--installed
                       harness-commit-attribution--noted
                       harness-commit-attribution--prompts-sent
                       harness-commit-attribution--prompts-sending
                       harness-commit-attribution--prompt-error))
    (clrhash table))
  (setq harness-commit-attribution--flush-waiters nil
        harness-commit-attribution--version-cache nil
        harness-commit-attribution--pass-memo nil))

(defmacro harness-commit-attribution-test-with-repo (&rest body)
  "Run BODY with `base', `root', `fake' and `sessions' bound.
The project, config, worktree and commit-attribution modules are
loaded, the state directory is fresh, the setting is on, and git-ai is
the fake of `harness-commit-attribution-test--fake-git-ai'."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let* ((base (harness-test-temp-dir))
            (root (harness-commit-attribution-test--make-repo base))
            (fake (harness-commit-attribution-test--fake-git-ai base))
            (sessions (make-hash-table :test 'equal))
            (tmp-dir (file-name-as-directory (expand-file-name "session-tmp/" base)))
            (harness-commit-attribution-test--sessions sessions)
            (harness-commit-attribution-test--tmp-dir tmp-dir)
            (harness-commit-attribution-test--log (cdr fake))
            (harness-commit-attribution-test--root root)
            (harness-commit-attribution-git-ai-program (car fake))
            (harness-commit-attribution-git-ai-directory
             (expand-file-name "git-ai/" base))
            (harness-commit-attribution-notes-url "http://127.0.0.1:9")
            (harness-commit-attribution-notes-mode 'private-service)
            (harness-commit-attribution-notes-token "test-token")
            (harness-commit-attribution-prompt-mode 'full)
            (harness-commit-attribution-prompt-sync nil)
            (harness-commit-attribution t)
            (harness-commit-attribution-backend 'git-ai)
            (harness-commit-attribution-include-subagents t)
            (process-environment
             (append (list "GIT_CONFIG_GLOBAL=/dev/null"
                           "GIT_CONFIG_NOSYSTEM=1"
                           (format "FAKE_GIT_AI_LOG=%s" (cdr fake)))
                     process-environment)))
       (make-directory tmp-dir t)
       ;; The module's `:requires' names harness-secrets, which these
       ;; tests do not load; its masker is an identity unless a test
       ;; replaces it with a redacting one.
       (unless (fboundp 'harness-secrets-mask-text)
         (defalias 'harness-secrets-mask-text (lambda (text) (cons text nil))))
       (harness-test-reset-bus)
       (harness-test-load-module 'project)
       (harness-test-load-module 'config)
       (harness-test-load-module 'worktree)
       (harness-test-load-module 'commit-attribution)
       (harness-commit-attribution-test--make-ready)
       (harness-commit-attribution-test--reset)
       (harness-register-method 'session/get #'harness-commit-attribution-test--session-get)
       (harness-register-method 'session/tmp-dir #'harness-commit-attribution-test--session-tmp)
       (unwind-protect (progn ,@body)
         (ignore-errors (delete-directory base t))))))

(defun harness-commit-attribution-test--session (sessions id &optional model child)
  "Add a test session ID in ROOT with MODEL, or as CHILD's sub-agent."
  (let ((parent (and child (gethash child sessions))))
    (puthash id (append (list :id id :cwd harness-commit-attribution-test--root
                              :model (or model "session-model"))
                        (and child (list :parent-id child :kind 'subagent)))
             sessions)))

(defun harness-commit-attribution-test--calls ()
  "Return the fake git-ai checkpoint calls, oldest first.
Each is a plist parsed from the payload after `---stdin---'."
  (let ((log harness-commit-attribution-test--log))
    (when (file-readable-p log)
      (let (calls)
        (dolist (chunk (split-string (harness-read-file log) "===CALL===\n" t))
          (when (string-match "\n---stdin---\n" chunk)
            (let ((payload (substring chunk (match-end 0))))
              (condition-case nil
                  (push (harness-json-parse (string-trim payload)) calls)
                (error nil)))))
        (nreverse calls)))))

(defun harness-commit-attribution-test--arguments ()
  "Return the argument lists of the fake git-ai checkpoint calls."
  (let ((log harness-commit-attribution-test--log))
    (when (file-readable-p log)
      (let (args)
        (dolist (chunk (split-string (harness-read-file log) "===CALL===\n" t))
          (let ((lines (split-string chunk "\n" t)))
            (when (member "arg=checkpoint" lines)
              (push (mapcar (lambda (line) (string-remove-prefix "arg=" line))
                            (cl-remove-if-not (lambda (line) (string-prefix-p "arg=" line))
                                              lines))
                    args))))
        (nreverse args)))))

(defun harness-commit-attribution-test--drain ()
  "Wait until the module's checkpoint queues are idle."
  (harness-test-await (harness-commit-attribution--flush) 20))

(defun harness-commit-attribution-test--prompt-turn (sessions sid prompt model)
  "Make a user message and a running turn for SID, on MODEL."
  (harness-commit-attribution-test--session sessions sid model)
  (harness-emit 'session/node-added sid
                (list :id "n-42" :kind 'user :content prompt :ts (float-time)))
  (harness-emit 'agent/turn-started sid))

;;;; The fake notes service

(defun harness-commit-attribution-test--script ()
  "Return the notes service script of this checkout."
  (expand-file-name "scripts/attribution-notes-server" harness-test-root))

(defun harness-commit-attribution-test--start-notes (&optional base token)
  "Start the notes service under BASE with TOKEN; return its plist."
  (let* ((base (or base (harness-test-temp-dir)))
         (token (or token "test-token"))
         (token-file (expand-file-name "token" base))
         (port-file (expand-file-name "port" base))
         (db (expand-file-name "notes.db" base)))
    (make-directory base t)
    (with-temp-file token-file (insert token "\n"))
    (set-file-modes token-file #o600)
    (let ((process
           (make-process
            :name "attribution-notes-test"
            :command (list (or (executable-find "python3") "python3")
                           (harness-commit-attribution-test--script)
                           "--db" db "--host" "127.0.0.1" "--port" "0"
                           "--port-file" port-file "--token-file" token-file
                           "--device" "test-device" "--quiet")
            :buffer (generate-new-buffer " *attribution-notes-test*")
            :noquery t)))
      (harness-test-wait
       (lambda () (and (file-exists-p port-file)
                       (not (string-empty-p (string-trim (harness-read-file port-file))))))
       10 "the notes service's port file")
      (let ((port (string-to-number (string-trim (harness-read-file port-file)))))
        (list :process process :url (format "http://127.0.0.1:%d" port)
              :token token :db db :base base :port port)))))

(defun harness-commit-attribution-test--stop-notes (service)
  "Stop the notes SERVICE and remove its directory."
  (when-let* ((process (plist-get service :process)))
    (delete-process process))
  (ignore-errors (delete-directory (plist-get service :base) t)))

(defun harness-commit-attribution-test--upload (service sha content)
  "Upload CONTENT as the note of SHA to SERVICE; return the response."
  (harness-test-await
   (harness-http-request-json
    (format "%s/worker/notes/upload" (plist-get service :url))
    :method "POST"
    :headers (list (cons "X-API-Key" (plist-get service :token)))
    :json (list :entries (list (list :commit_sha sha :content content))))))

(defun harness-commit-attribution-test--store-prompt (service conversation record)
  "Store RECORD as CONVERSATION's prompt in SERVICE; return the response."
  (harness-test-await
   (harness-http-request-json
    (format "%s/management/prompts/upload" (plist-get service :url))
    :method "POST"
    :headers (list (cons "X-API-Key" (plist-get service :token)))
    :json (list :entries (list (list :conversation conversation :record record))))))

(defun harness-commit-attribution-test--prompt-records (service conversations)
  "Return SERVICE's alist of CONVERSATION -> prompt record, or nil.
A 404, meaning the service knows none, gives nil."
  (condition-case nil
      (let* ((result (harness-test-await
                      (harness-http-request-json
                       (format "%s/management/prompts/?conversations=%s"
                               (plist-get service :url)
                               (mapconcat #'identity conversations ","))
                       :headers (list (cons "X-API-Key" (plist-get service :token))))
                      10))
             (prompts (plist-get result :prompts)))
        (cl-loop for (key value) on prompts by #'cddr
                 collect (cons (if (keywordp key)
                                   (substring (symbol-name key) 1)
                                 key)
                               value)))
    (error nil)))

(defun harness-commit-attribution-test--session-prompts (service sessions)
  "Return SERVICE's alist of CONVERSATION -> prompt record by SESSIONS."
  (condition-case nil
      (let* ((result (harness-test-await
                      (harness-http-request-json
                       (format "%s/management/prompts/?sessions=%s"
                               (plist-get service :url)
                               (mapconcat #'identity sessions ","))
                       :headers (list (cons "X-API-Key" (plist-get service :token))))
                      10))
             (prompts (plist-get result :prompts)))
        (cl-loop for (key value) on prompts by #'cddr
                 collect (cons (if (keywordp key)
                                   (substring (symbol-name key) 1)
                                 key)
                               value)))
    (error nil)))

(defun harness-commit-attribution-test--note (path model conversation
                                                  &optional key lines)
  "Return a git-ai authorship log for PATH with MODEL and CONVERSATION."
  (let ((key (or key "s_c9883b05a2487d")))
    (format (concat "%s\n"
                    "  %s::t_9f8e7d6c5b4a32 %s\n"
                    "---\n"
                    "{\"schema_version\":\"authorship/3.0.0\","
                    "\"base_commit_sha\":\"0000000000000000000000000000000000000000\","
                    "\"prompts\":{},\"humans\":{},"
                    "\"sessions\":{\"%s\":{\"agent_id\":"
                    "{\"tool\":\"emacs-agent-harness\",\"id\":\"%s\",\"model\":\"%s\"}}}}")
            path key (or lines "1-4,9-10,12") key conversation model)))

;;;; Payloads and epochs

(ert-deftest harness-commit-attribution-conversation-is-one-per-prompt-and-model ()
  "A model switch makes a new epoch; a prompt node is in the id."
  (should (equal "s1@n-1@model-a"
                 (harness-commit-attribution--conversation "s1" "n-1" "model-a")))
  (should (equal "s1@n-1@model-b"
                 (harness-commit-attribution--conversation "s1" "n-1" "model-b")))
  (should (equal "system@merge"
                 (harness-commit-attribution--system-conversation "merge"))))

(ert-deftest harness-commit-attribution-payload-shapes ()
  "The write, pre-shell and post-shell payloads are git-ai's agent-v1."
  (let* ((context (list :model "anthropic:model-a"
                        :conversation "s1@n-1@anthropic:model-a"
                        :root "/tmp/repo"))
         (edit (harness-commit-attribution--payload context 'edit '("/tmp/repo/a")))
         (pre (harness-commit-attribution--payload
               context 'shell-pre nil "npm test" "call-1"))
         (post (harness-commit-attribution--payload
                context 'shell-post nil "npm test" "call-1")))
    (should (equal (plist-get edit :type) "ai_agent"))
    (should (equal (append (plist-get edit :edited_filepaths) nil) '("/tmp/repo/a")))
    (should (equal (plist-get edit :agent_name) "emacs-agent-harness"))
    (should (equal (plist-get edit :model) "anthropic:model-a"))
    (should (equal (plist-get edit :conversation_id) "s1@n-1@anthropic:model-a"))
    (should (equal (plist-get pre :type) "pre_shell_command"))
    (should (equal (plist-get post :type) "post_shell_command"))
    (should (equal (plist-get pre :tool_use_id) "call-1"))
    (should (equal (plist-get pre :command) "npm test"))
    (should (equal (plist-get post :command) "npm test"))))

(ert-deftest harness-commit-attribution-checkpoints-model-of-the-tool-call ()
  "The model is the tool-call node's model, not the session's current model."
  (harness-commit-attribution-test-with-repo
    (let ((sid "session-one"))
      (harness-commit-attribution-test--prompt-turn sessions sid "Write a file" "session-model")
      (harness-emit 'agent/tool-call sid
                    (list :kind 'tool-call :call-id "call-1" :tool "write_file"
                          :input (list :path "a.txt")
                          :meta (list :model "call-model")))
      (harness-emit 'tools/finished sid
                    (list :id "call-1" :name "write_file"
                          :input (list :path "a.txt"))
                    (list :content "wrote" :is-error nil))
      (harness-commit-attribution-test--drain)
      (let ((calls (harness-commit-attribution-test--calls)))
        (should (= 1 (length calls)))
        (should (equal (plist-get (car calls) :model) "call-model"))
        (should (equal (plist-get (car calls) :type) "ai_agent"))
        (should (equal (append (plist-get (car calls) :edited_filepaths) nil)
                       (list (expand-file-name "a.txt" root))))
        (should (equal (plist-get (car calls) :conversation_id)
                       "session-one@n-42@call-model"))))))

(ert-deftest harness-commit-attribution-model-switch-splits-the-epoch ()
  "Two calls of one prompt on two models get two conversation ids and models."
  (harness-commit-attribution-test-with-repo
    (let ((sid "session-two"))
      (harness-commit-attribution-test--prompt-turn sessions sid "Change it" "session-model")
      (dolist (spec '(("call-a" "model-a" "a.txt") ("call-b" "model-b" "b.txt")))
        (pcase-let ((`(,id ,model ,path) spec))
          (harness-emit 'agent/tool-call sid
                        (list :kind 'tool-call :call-id id :tool "write_file"
                              :input (list :path path) :meta (list :model model)))
          (harness-emit 'tools/finished sid
                        (list :id id :name "write_file" :input (list :path path))
                        (list :content "wrote" :is-error nil))))
      (harness-commit-attribution-test--drain)
      (let ((calls (harness-commit-attribution-test--calls)))
        (should (= 2 (length calls)))
        (should (equal (mapcar (lambda (c) (plist-get c :model)) calls)
                       '("model-a" "model-b")))
        (should (equal (mapcar (lambda (c) (plist-get c :conversation_id)) calls)
                       '("session-two@n-42@model-a" "session-two@n-42@model-b")))))))

(ert-deftest harness-commit-attribution-subagent-gets-its-own-epoch ()
  "A sub-agent's session id keeps its lines out of the parent's prompt."
  (harness-commit-attribution-test-with-repo
    (let ((parent "parent-session")
          (child "child-session"))
      (harness-commit-attribution-test--session sessions parent "model-a")
      (harness-commit-attribution-test--session sessions child "model-a" parent)
      (harness-emit 'session/node-added child
                    (list :id "n-9" :kind 'user :content "Do the subtask"))
      (harness-emit 'agent/turn-started child)
      (harness-emit 'agent/tool-call child
                    (list :kind 'tool-call :call-id "call-child" :tool "write_file"
                          :input (list :path "child.txt") :meta (list :model "model-a")))
      (harness-emit 'tools/finished child
                    (list :id "call-child" :name "write_file"
                          :input (list :path "child.txt"))
                    (list :content "wrote" :is-error nil))
      (harness-commit-attribution-test--drain)
      (should (equal (plist-get (car (harness-commit-attribution-test--calls))
                                :conversation_id)
                     "child-session@n-9@model-a")))))

(ert-deftest harness-commit-attribution-bash-gets-pre-and-post-checkpoints ()
  "A bash call emits a pre and a post shell checkpoint with one tool id."
  (harness-commit-attribution-test-with-repo
    (let ((sid "shell-session"))
      (harness-commit-attribution-test--prompt-turn sessions sid "Run the tests" "model-a")
      (harness-emit 'agent/tool-call sid
                    (list :kind 'tool-call :call-id "call-7" :tool "bash"
                          :input (list :command "npm test")
                          :meta (list :model "model-a")))
      (harness-emit 'tools/started sid
                    (list :id "call-7" :name "bash" :input (list :command "npm test")))
      (harness-emit 'tools/finished sid
                    (list :id "call-7" :name "bash" :input (list :command "npm test"))
                    (list :content "ok" :is-error nil :meta (list :exit 0)))
      (harness-commit-attribution-test--drain)
      (let ((calls (harness-commit-attribution-test--calls)))
        (should (= 2 (length calls)))
        (should (equal (mapcar (lambda (c) (plist-get c :type)) calls)
                       '("pre_shell_command" "post_shell_command")))
        (should (equal (mapcar (lambda (c) (plist-get c :tool_use_id)) calls)
                       '("call-7" "call-7")))
        (should (equal (plist-get (car calls) :command) "npm test"))))))

(ert-deftest harness-commit-attribution-commit-command-checkpoints-changes-first ()
  "A `git commit' command checkpoints changed paths before the shell pair."
  (harness-commit-attribution-test-with-repo
    (let ((sid "commit-session"))
      (harness-commit-attribution-test--prompt-turn sessions sid "Commit it" "model-a")
      (with-temp-file (expand-file-name "changed.txt" root) (insert "new\n"))
      (harness-emit 'agent/tool-call sid
                    (list :kind 'tool-call :call-id "call-c" :tool "bash"
                          :input (list :command "git commit -am work")
                          :meta (list :model "model-a")))
      (harness-emit 'tools/started sid
                    (list :id "call-c" :name "bash"
                          :input (list :command "git commit -am work")))
      (harness-commit-attribution-test--drain)
      (let ((calls (harness-commit-attribution-test--calls)))
        (should (equal (mapcar (lambda (c) (plist-get c :type)) calls)
                       '("ai_agent" "pre_shell_command")))
        (should (member (expand-file-name "changed.txt" root)
                        (append (plist-get (car calls) :edited_filepaths) nil)))))))

(ert-deftest harness-commit-attribution-off-by-default-runs-nothing ()
  "With the setting off, no git-ai command runs and no prompt is stored."
  (harness-commit-attribution-test-with-repo
    (setq harness-commit-attribution nil)
    (let ((sid "off-session"))
      (harness-commit-attribution-test--session sessions sid "model-a")
      (harness-emit 'session/node-added sid
                    (list :id "n-1" :kind 'user :content "Do nothing"))
      (harness-emit 'agent/turn-started sid)
      (harness-emit 'agent/tool-call sid
                    (list :kind 'tool-call :call-id "call-1" :tool "write_file"
                          :input (list :path "a.txt") :meta (list :model "model-a")))
      (harness-emit 'tools/finished sid
                    (list :id "call-1" :name "write_file" :input (list :path "a.txt"))
                    (list :content "wrote" :is-error nil))
      (harness-commit-attribution-test--drain)
      (should-not (file-exists-p harness-commit-attribution-test--log)))))

;;;; Hooks and configuration

(ert-deftest harness-commit-attribution-installs-and-removes-the-hook ()
  "Enabling installs the marker hook; disabling removes only that hook."
  (harness-commit-attribution-test-with-repo
    (let* ((hook (expand-file-name "hooks/pre-commit" (expand-file-name ".git" root)))
           (foreign "#!/bin/sh\necho somebody else\n"))
      (harness-test-await (harness-commit-attribution--pass (list root)) 20)
      (should (file-executable-p hook))
      (should (harness-commit-attribution--hook-p (harness-read-file hook)))
      (should (member (harness-commit-attribution--main root)
                      (harness-commit-attribution--recorded)))
      (setq harness-commit-attribution nil)
      (harness-test-await (harness-commit-attribution--pass (list root)) 20)
      (should-not (file-exists-p hook))
      (should-not (harness-commit-attribution--recorded))
      ;; A hook somebody else wrote is left alone.
      (harness-write-file-atomically hook foreign)
      (setq harness-commit-attribution t)
      (harness-test-await (harness-commit-attribution--pass (list root)) 20)
      (should (equal foreign (harness-read-file hook)))
      (should-not (harness-commit-attribution--recorded)))))

(ert-deftest harness-commit-attribution-hook-checkpoints-staged-paths ()
  "The installed hook sends git-ai the staged paths with the turn's context."
  (harness-commit-attribution-test-with-repo
    (let ((sid "hook-session"))
      (harness-commit-attribution-test--prompt-turn sessions sid "Stage this" "hook-model")
      (with-temp-file (expand-file-name "staged.txt" root) (insert "staged\n"))
      (harness-commit-attribution-test--git root "add" "staged.txt")
      (let* ((context (list :model "hook-model"
                            :conversation "hook-session@n-42@hook-model"
                            :prompt-id "n-42" :prompt "Stage this"
                            :root root :session sid))
             (hook (expand-file-name "hooks/pre-commit" (expand-file-name ".git" root))))
        (harness-test-await (harness-commit-attribution--install root))
        (harness-commit-attribution--write-context context "git commit")
        (let ((process-environment
               (cons (concat "PATH=" (file-name-directory
                                      harness-commit-attribution-git-ai-program)
                             ":" (getenv "PATH"))
                     process-environment)))
          (let ((default-directory root))
            (should (zerop (call-process hook nil nil nil))))
          (let ((calls (harness-commit-attribution-test--calls)))
            (should (= 1 (length calls)))
            (should (equal (plist-get (car calls) :type) "ai_agent"))
            (should (equal (plist-get (car calls) :model) "hook-model"))
            (should (equal (plist-get (car calls) :conversation_id)
                           "hook-session@n-42@hook-model"))
            (should (member (expand-file-name "staged.txt" root)
                            (append (plist-get (car calls) :edited_filepaths) nil))))
          ;; The hook gives git-ai a private profile of its own.
          (let ((config (harness-json-parse
                         (harness-read-file
                          (expand-file-name "harness-git-ai-home/.git-ai/config.json"
                                            tmp-dir)))))
            (should (equal (plist-get config :telemetry_oss) "off"))
            (should (equal (plist-get config :prompt_storage) "local"))
            (should (equal (plist-get (plist-get config :notes_backend) :kind) "http"))))))))

(ert-deftest harness-commit-attribution-hook-exits-zero-without-context ()
  "The safety net never fails a commit when there is no context."
  (harness-commit-attribution-test-with-repo
    (harness-test-await (harness-commit-attribution--install root))
    (let ((default-directory root))
      (should (zerop (call-process
                      (expand-file-name "hooks/pre-commit" (expand-file-name ".git" root))
                      nil nil nil))))))

(ert-deftest harness-commit-attribution-configure-writes-private-profile ()
  "Configure backs up the old config and writes the private git-ai profile."
  (harness-commit-attribution-test-with-repo
    (make-directory harness-commit-attribution-git-ai-directory t)
    (let ((file (expand-file-name "config.json" harness-commit-attribution-git-ai-directory))
          (url "https://notes.example.internal"))
      (with-temp-file file
        (insert "{\"telemetry_oss\":\"on\",\"unknown\":42,\"api_key\":\"cloud-key\"}"))
      (let ((result (harness-call 'commit-attribution/configure
                                  root (list :notes-url url :notes-token "device-token"))))
        (should (file-exists-p (plist-get result :backup)))
        (let ((after (harness-json-parse (harness-read-file file))))
          (should (equal (plist-get after :telemetry_oss) "off"))
          (should (equal (plist-get after :prompt_storage) "local"))
          (should (equal (append (plist-get after :exclude_prompts_in_repositories) nil)
                         '("*")))
          (should (harness-json-true-p (plist-get after :disable_auto_updates)))
          (should (harness-json-true-p (plist-get after :disable_version_checks)))
          (should (equal (plist-get (plist-get after :notes_backend) :kind) "http"))
          (should (equal (plist-get (plist-get after :notes_backend) :backend_url) url))
          (should (equal (plist-get after :api_base_url) url))
          (should (equal (plist-get after :api_key) "device-token"))
          (should (equal (plist-get after :unknown) 42)))
        (should (equal (harness-read-file (plist-get result :backup))
                       "{\"telemetry_oss\":\"on\",\"unknown\":42,\"api_key\":\"cloud-key\"}"))
        (should (= #o600 (logand #o777 (file-modes file))))))))

(ert-deftest harness-commit-attribution-configure-refuses-without-a-url ()
  "A profile without a private URL would leave git-ai on git notes."
  (harness-commit-attribution-test-with-repo
    (setq harness-commit-attribution-notes-url nil)
    (should-error (harness-call 'commit-attribution/configure root))
    (should-not (file-exists-p
                 (expand-file-name "config.json" harness-commit-attribution-git-ai-directory)))))

(ert-deftest harness-commit-attribution-doctor-checks-the-private-profile ()
  "The doctor is green for a private config, hook and notes service."
  (harness-commit-attribution-test-with-repo
    (let ((service (harness-commit-attribution-test--start-notes base)))
      (unwind-protect
          (progn
            (setq harness-commit-attribution-notes-url (plist-get service :url))
            (harness-test-await (harness-commit-attribution--install root))
            (harness-call 'commit-attribution/configure root)
            (let ((result (harness-test-await
                           (harness-call 'commit-attribution/doctor root) 20)))
              (should (eq (plist-get result :ok) t))
              (should (equal (plist-get result :failed) nil))
              (should (equal (plist-get result :repository)
                             (harness-commit-attribution--main root)))
              (should (eq (plist-get (cl-find "prompt-sync" (plist-get result :checks)
                                              :key (lambda (check)
                                                     (plist-get check :name))
                                              :test #'equal)
                                     :ok)
                          t)))
            ;; Prompt sync uses the same private service.
            (let ((harness-commit-attribution-prompt-sync t))
              (let ((result (harness-test-await
                             (harness-call 'commit-attribution/doctor root) 20)))
                (should (eq (plist-get result :ok) t))
                (should (eq (plist-get result :prompt-sync) t))
                (should (equal (plist-get (cl-find "prompt-sync" (plist-get result :checks)
                                                   :key (lambda (check)
                                                          (plist-get check :name))
                                                   :test #'equal)
                                          :detail)
                               (format "redacted prompts are stored at %s through the management API"
                                       (harness-commit-attribution--url))))))
            ;; A config that turns telemetry on is not private.
            (let* ((file (expand-file-name "config.json"
                                           harness-commit-attribution-git-ai-directory))
                   (config (harness-json-parse (harness-read-file file))))
              (harness-write-file-atomically
               file (harness-json-encode
                     (plist-put config :telemetry_oss "on"))))
            (let ((result (harness-test-await
                           (harness-call 'commit-attribution/doctor root) 20)))
              (should-not (eq (plist-get result :ok) t))
              (should (member "telemetry" (plist-get result :failed)))))
        (harness-commit-attribution-test--stop-notes service)))))

;;;; Prompts and reports

(ert-deftest harness-commit-attribution-prompt-sync-uploads-the-redacted-prompt ()
  "Prompt sync stores the masked record in the service, never the secret."
  (harness-commit-attribution-test-with-repo
    (let ((service (harness-commit-attribution-test--start-notes base))
          (sid "sync-session")
          (conversation "sync-session@n-42@model-a"))
      (unwind-protect
          (progn
            (setq harness-commit-attribution-notes-url (plist-get service :url)
                  harness-commit-attribution-prompt-sync t)
            (cl-letf (((symbol-function 'harness-secrets-mask-text)
                       (lambda (text)
                         (cons (replace-regexp-in-string "hunter2" "[redacted]" text)
                               (list (list :label "test" :fingerprint "deadbeef" :count 1))))))
              (harness-commit-attribution-test--prompt-turn
               sessions sid "Use hunter2 carefully" "model-a")
              (harness-emit 'agent/tool-call sid
                            (list :kind 'tool-call :call-id "call-s" :tool "write_file"
                                  :input (list :path "a.txt") :meta (list :model "model-a")))
              (harness-emit 'tools/finished sid
                            (list :id "call-s" :name "write_file" :input (list :path "a.txt"))
                            (list :content "wrote" :is-error nil))
              (harness-commit-attribution-test--drain))
            (harness-test-wait
             (lambda ()
               (assoc conversation
                      (harness-commit-attribution-test--prompt-records
                       service (list conversation))))
             10 "the prompt upload")
            (let ((record (cdr (assoc conversation
                                      (harness-commit-attribution-test--prompt-records
                                       service (list conversation))))))
              (should (equal (plist-get record :prompt) "Use [redacted] carefully"))
              (should (harness-json-true-p (plist-get record :redacted)))
              (should (equal (plist-get record :session) sid))
              ;; The service gets the hash of the redacted text, not of
              ;; the secret-bearing original.
              (should (equal (plist-get record :prompt_sha256)
                             (secure-hash 'sha256 "Use [redacted] carefully")))
              (should-not (equal (plist-get record :prompt_sha256)
                                 (secure-hash 'sha256 "Use hunter2 carefully")))
              (should-not (string-match-p "hunter2" (format "%S" record)))))
        (harness-commit-attribution-test--stop-notes service)))))

(ert-deftest harness-commit-attribution-prompt-mode-hash-uploads-only-the-hash ()
  "Prompt mode `hash' stores the hash and no prompt text, and nowhere else."
  (harness-commit-attribution-test-with-repo
    (let* ((service (harness-commit-attribution-test--start-notes base))
           (sid "hash-session")
           (conversation "hash-session@n-42@model-a"))
      (unwind-protect
          (progn
            (setq harness-commit-attribution-notes-url (plist-get service :url)
                  harness-commit-attribution-prompt-mode 'hash
                  harness-commit-attribution-prompt-sync t)
            (cl-letf (((symbol-function 'harness-secrets-mask-text)
                       (lambda (text)
                         (cons (replace-regexp-in-string "hunter2" "[redacted]" text)
                               (list (list :label "test" :fingerprint "deadbeef" :count 1))))))
              (harness-commit-attribution-test--prompt-turn
               sessions sid "Use hunter2 carefully" "model-a")
              (harness-emit 'agent/tool-call sid
                            (list :kind 'tool-call :call-id "call-h" :tool "write_file"
                                  :input (list :path "a.txt") :meta (list :model "model-a")))
              (harness-emit 'tools/finished sid
                            (list :id "call-h" :name "write_file" :input (list :path "a.txt"))
                            (list :content "wrote" :is-error nil))
              (harness-commit-attribution-test--drain))
            (harness-test-wait
             (lambda ()
               (assoc conversation
                      (harness-commit-attribution-test--prompt-records
                       service (list conversation))))
             10 "the hash upload")
            (let ((record (cdr (assoc conversation
                                      (harness-commit-attribution-test--prompt-records
                                       service (list conversation))))))
              (should-not (plist-get record :prompt))
              (should (equal (plist-get record :prompt_sha256)
                             (secure-hash 'sha256 "Use [redacted] carefully")))
              (should-not (string-match-p "hunter2" (format "%S" record)))
              (should (equal (harness-commit-attribution--prompt-hash "Use [redacted] carefully")
                             (plist-get record :prompt_sha256)))
              (should-not (harness-test-await
                           (harness-call 'commit-attribution/show-prompt conversation) 20))))
        (harness-commit-attribution-test--stop-notes service)))))

(ert-deftest harness-commit-attribution-prompt-sync-is-off-by-default ()
  "Without prompt sync the service stores no prompt record, and so does the module."
  (harness-commit-attribution-test-with-repo
    (let ((service (harness-commit-attribution-test--start-notes base))
          (sid "local-session")
          (conversation "local-session@n-42@model-a"))
      (unwind-protect
          (progn
            (setq harness-commit-attribution-notes-url (plist-get service :url))
            (harness-commit-attribution-test--prompt-turn
             sessions sid "A prompt that stays private" "model-a")
            (harness-emit 'agent/tool-call sid
                          (list :kind 'tool-call :call-id "call-l" :tool "write_file"
                                :input (list :path "a.txt") :meta (list :model "model-a")))
            (harness-emit 'tools/finished sid
                          (list :id "call-l" :name "write_file" :input (list :path "a.txt"))
                          (list :content "wrote" :is-error nil))
            (harness-commit-attribution-test--drain)
            (should-not (harness-commit-attribution-test--prompt-records
                         service (list conversation)))
            (should (equal (plist-get (harness-call 'commit-attribution/status root)
                                      :prompt-store)
                           "off")))
        (harness-commit-attribution-test--stop-notes service)))))

(ert-deftest harness-commit-attribution-report-links-a-prompt-from-another-device ()
  "The report links a prompt another device stored in the service."
  (harness-commit-attribution-test-with-repo
    (let ((service (harness-commit-attribution-test--start-notes base))
          (conversation "laptop@n-5@model-x")
          (model "model-x")
          (prompt "Write the retry path on the laptop."))
      (unwind-protect
          (progn
            (setq harness-commit-attribution-notes-url (plist-get service :url))
            (let ((sha (harness-commit-attribution-test--commit
                        root "a.el" "a\n" "A commit")))
              (harness-commit-attribution-test--upload
               service sha
               (harness-commit-attribution-test--note "a.el" model conversation))
              (harness-commit-attribution-test--store-prompt
               service conversation
               (list :conversation conversation :prompt prompt
                     :prompt_sha256 (secure-hash 'sha256 (encode-coding-string prompt 'utf-8))
                     :session "laptop" :turn "n-5" :model model
                     :at "2026-11-04T10:00:00Z" :device "laptop"
                     :prompt_mode "excerpt" :redacted :false))
              (let* ((report (harness-test-await
                              (harness-call 'commit-attribution/report
                                            root "HEAD~1..HEAD") 20))
                     (session (car (plist-get (car (plist-get report :commits))
                                              :sessions))))
                (should (= 1 (plist-get report :notes)))
                (should (equal (plist-get session :prompt) prompt))
                (should (eq (plist-get session :available) t))
                (should (equal (plist-get session :device) "laptop"))
                (should (= 1 (plist-get (plist-get report :prompts) :linked))))
              (should (equal (harness-test-await
                              (harness-call 'commit-attribution/fetch-prompt
                                            conversation) 20)
                             prompt))
              (should-not (harness-test-await
                           (harness-call 'commit-attribution/fetch-prompt
                                         "nobody@n-0@model-z") 20))))
        (harness-commit-attribution-test--stop-notes service)))))

(ert-deftest harness-commit-attribution-report-joins-notes-and-prompts ()
  "The report counts AI lines and links the prompt the service stored."
  (harness-commit-attribution-test-with-repo
    (let* ((service (harness-commit-attribution-test--start-notes base))
           (sid "report-session")
           (prompt "Add idempotency keys to the webhook retry path.")
           (model "anthropic:claude-opus-4-5")
           (conversation "report-session@n-42@anthropic:claude-opus-4-5"))
      (unwind-protect
          (progn
            (setq harness-commit-attribution-notes-url (plist-get service :url)
                  harness-commit-attribution-prompt-sync t)
            (let ((sha (harness-commit-attribution-test--commit
                        root "webhook.el" "(defun retry () nil)\n" "Add retry path")))
              (harness-commit-attribution-test--prompt-turn sessions sid prompt model)
              (harness-emit 'agent/tool-call sid
                            (list :kind 'tool-call :call-id "call-report" :tool "write_file"
                                  :input (list :path "webhook.el")
                                  :meta (list :model model)))
              (harness-emit 'tools/finished sid
                            (list :id "call-report" :name "write_file"
                                  :input (list :path "webhook.el"))
                            (list :content "wrote" :is-error nil))
              (harness-commit-attribution-test--drain)
              (harness-test-wait
               (lambda ()
                 (assoc conversation
                        (harness-commit-attribution-test--prompt-records
                         service (list conversation))))
               10 "the prompt upload")
              (harness-commit-attribution-test--upload
               service sha
               (harness-commit-attribution-test--note "webhook.el" model conversation))
              (let ((report (harness-test-await
                             (harness-call 'commit-attribution/report
                                           root "HEAD~1..HEAD") 20)))
                (should (= 1 (plist-get report :commits-count)))
                (should (= 1 (plist-get report :notes)))
                (should (= 7 (plist-get report :ai-lines)))
                (should (equal (mapcar (lambda (m) (plist-get m :model))
                                       (plist-get report :models))
                               (list model)))
                (should (equal (plist-get (car (plist-get report :commits)) :note) t))
                (let ((session (car (plist-get (car (plist-get report :commits))
                                               :sessions))))
                  (should (equal (plist-get session :prompt) prompt))
                  (should (eq (plist-get session :available) t))
                  (should (equal (plist-get session :turn) "n-42"))))
              (should (equal (harness-test-await
                              (harness-call 'commit-attribution/show-prompt conversation) 20)
                             prompt))
              (let ((shown (harness-test-await
                            (harness-call 'commit-attribution/show root sha) 20)))
                (should (string-match-p "anthropic:claude-opus-4-5"
                                        (plist-get shown :text)))
                (should (string-match-p "webhook.el" (plist-get shown :text))))))
        (harness-commit-attribution-test--stop-notes service)))))

(ert-deftest harness-commit-attribution-report-joins-every-commits-note ()
  "A range of several commits joins each commit to its own note.
`git log' separates records with a newline, which must not become part
of the SHA, or every commit but the first loses its note."
  (harness-commit-attribution-test-with-repo
    (let ((service (harness-commit-attribution-test--start-notes base))
          (model-a "model-a")
          (model-b "model-b"))
      (unwind-protect
          (progn
            (setq harness-commit-attribution-notes-url (plist-get service :url))
            (let ((sha-a (harness-commit-attribution-test--commit
                          root "a.el" "a\n" "First change"))
                  (sha-b (harness-commit-attribution-test--commit
                          root "b.el" "b\n" "Second change")))
              (harness-commit-attribution-test--upload
               service sha-a
               (harness-commit-attribution-test--note
                "a.el" model-a "s1@n-1@model-a" nil "1-2"))
              (harness-commit-attribution-test--upload
               service sha-b
               (harness-commit-attribution-test--note
                "b.el" model-b "s1@n-2@model-b" nil "1-4"))
              (let ((report (harness-test-await
                             (harness-call 'commit-attribution/report
                                           root "HEAD~2..HEAD") 20)))
                (should (= 2 (plist-get report :commits-count)))
                (should (= 2 (plist-get report :notes)))
                (should (= 6 (plist-get report :ai-lines)))
                (should (equal (mapcar (lambda (row) (plist-get row :short))
                                       (plist-get report :commits))
                               (list (substring sha-a 0 7)
                                     (substring sha-b 0 7))))
                (should (equal (mapcar (lambda (row) (plist-get row :note))
                                       (plist-get report :commits))
                               '(t t)))
                (should (equal (mapcar (lambda (m) (plist-get m :model))
                                       (plist-get report :models))
                               (list model-a model-b))))))
        (harness-commit-attribution-test--stop-notes service)))))

(ert-deftest harness-commit-attribution-report-says-prompt-unavailable ()
  "A note without a prompt record still reports the model and session."
  (harness-commit-attribution-test-with-repo
    (let ((service (harness-commit-attribution-test--start-notes base)))
      (unwind-protect
          (progn
            (setq harness-commit-attribution-notes-url (plist-get service :url))
            (let ((sha (harness-commit-attribution-test--commit
                        root "a.el" "x\n" "A commit")))
              (harness-commit-attribution-test--upload
               service sha
               (harness-commit-attribution-test--note
                "a.el" "model-b" "unknown-session@n-1@model-b"))
              (let ((report (harness-test-await
                             (harness-call 'commit-attribution/report
                                           root "HEAD~1..HEAD") 20)))
                (should (= 7 (plist-get report :ai-lines)))
                (should (= 1 (plist-get (plist-get report :prompts) :unavailable)))
                (should (equal (plist-get (car (plist-get (car (plist-get report :commits))
                                                           :sessions))
                                          :prompt)
                               nil)))))
        (harness-commit-attribution-test--stop-notes service)))))

(ert-deftest harness-commit-attribution-prune-removes-old-records ()
  "Pruning deletes the service's records older than the cutoff."
  (harness-commit-attribution-test-with-repo
    (let ((service (harness-commit-attribution-test--start-notes base)))
      (unwind-protect
          (progn
            (setq harness-commit-attribution-notes-url (plist-get service :url))
            (harness-commit-attribution-test--store-prompt
             service "old@n-1@m"
             (list :conversation "old@n-1@m" :prompt "old"
                   :prompt_sha256 "x" :session "old" :at "2000-01-01T00:00:00Z"))
            (harness-commit-attribution-test--store-prompt
             service "new@n-1@m"
             (list :conversation "new@n-1@m" :prompt "new"
                   :prompt_sha256 "y" :session "new" :at (harness-commit-attribution--now)))
            (should (= 2 (length (harness-commit-attribution-test--prompt-records
                                  service (list "old@n-1@m" "new@n-1@m")))))
            (should (= 1 (harness-call 'commit-attribution/prune 30)))
            (let ((records (harness-commit-attribution-test--prompt-records
                            service (list "old@n-1@m" "new@n-1@m"))))
              (should (= 1 (length records)))
              (should (equal (caar records) "new@n-1@m"))))
        (harness-commit-attribution-test--stop-notes service)))))

(ert-deftest harness-commit-attribution-redaction-redacts-the-prompt-service ()
  "A redaction rewrites the records the service holds, sending no secret."
  (harness-commit-attribution-test-with-repo
    (let* ((service (harness-commit-attribution-test--start-notes base))
           (sid "redact-session")
           (conversation "redact-session@n-42@model-a")
           (secret (list :label "test" :value "hunter2" :fingerprint "deadbeef")))
      (unwind-protect
          (progn
            (setq harness-commit-attribution-notes-url (plist-get service :url))
            (harness-commit-attribution-test--store-prompt
             service conversation
             (list :conversation conversation :prompt "Use hunter2 carefully"
                   :prompt_sha256 (secure-hash 'sha256 "Use hunter2 carefully")
                   :session sid :turn "n-42" :model "model-a"
                   :at "2026-11-04T10:00:00Z" :device "test-device"
                   :prompt_mode "full" :redacted :false))
            (require 'harness-redact)
            (should (memq 'harness-redact--stage-attribution-prompts
                          harness-redact--store-functions))
            (let* ((run (harness-redact--make-run
                         :mode 'redact :ids (list sid) :secrets (list secret)))
                   (store (car (harness-redact-run-stores run))))
              (harness-redact--stage-attribution-prompts run)
              (setq store (car (harness-redact-run-stores run)))
              (should (equal (plist-get store :store) "private prompt service"))
              (should (= 1 (plist-get store :count)))
              (let ((record (cdr (assoc conversation
                                        (harness-commit-attribution-test--prompt-records
                                         service (list conversation))))))
                (should (equal (plist-get record :prompt)
                               "Use [redacted: test sha256:deadbeef] carefully"))
                (should (harness-json-true-p (plist-get record :redacted)))
                (should (equal (plist-get record :prompt_sha256)
                               (secure-hash 'sha256
                                            "Use [redacted: test sha256:deadbeef] carefully")))
                (should-not (string-match-p "hunter2" (format "%S" record)))))
            ;; A scan only counts, and leaves the service as it is.
            (harness-commit-attribution-test--store-prompt
             service conversation
             (list :conversation conversation :prompt "Use hunter2 carefully"
                   :prompt_sha256 (secure-hash 'sha256 "Use hunter2 carefully")
                   :session sid :turn "n-42" :model "model-a"
                   :at "2026-11-04T10:00:00Z" :device "test-device"
                   :prompt_mode "full" :redacted :false))
            (let* ((run (harness-redact--make-run
                         :mode 'scan :ids (list sid) :secrets (list secret)))
                   (store (progn (harness-redact--stage-attribution-prompts run)
                                 (car (harness-redact-run-stores run)))))
              (should (= 1 (plist-get store :count)))
              (let ((record (cdr (assoc conversation
                                        (harness-commit-attribution-test--prompt-records
                                         service (list conversation))))))
                (should (equal (plist-get record :prompt) "Use hunter2 carefully")))))
        (harness-commit-attribution-test--stop-notes service)))))

;;;; The notes service and the public remote

(ert-deftest harness-commit-attribution-notes-service-round-trip ()
  "The service authenticates, stores a note, reads it and says 404 for unknown."
  (let* ((base (harness-test-temp-dir))
         (service (harness-commit-attribution-test--start-notes base)))
    (unwind-protect
        (progn
          (should (equal (harness-commit-attribution-test--upload
                          service "abc123def456" "a note")
                         '(:success_count 1 :failure_count 0)))
          (let ((read (harness-test-await
                       (harness-http-request-json
                        (format "%s/worker/notes/?commits=abc123def456,ffff"
                                (plist-get service :url))
                        :headers (list (cons "X-API-Key" (plist-get service :token)))))))
            (should (equal (plist-get (plist-get read :notes) :abc123def456)
                           "a note")))
          ;; An unknown commit is a 404, which git-ai reads as no note.
          (let ((status nil))
            (harness-http-request
             (format "%s/worker/notes/?commits=ffff" (plist-get service :url))
             :headers (list (cons "X-API-Key" (plist-get service :token)))
             :callback (lambda (s _h _b _e) (setq status s)))
            (harness-test-wait (lambda () status) 10 "the 404")
            (should (= status 404)))
          ;; No token is refused.
          (let ((status nil))
            (harness-http-request
             (format "%s/worker/notes/?commits=abc123def456" (plist-get service :url))
             :callback (lambda (s _h _b _e) (setq status s)))
            (harness-test-wait (lambda () status) 10 "the 401")
            (should (= status 401)))
          ;; Prompt records go through the management API, apart from
          ;; git-ai's worker endpoints; they are in their own table,
          ;; behind the same token.
          (let ((record (list :conversation "conv-a" :prompt "a redacted prompt"
                              :prompt_sha256 (secure-hash 'sha256 "a raw prompt")
                              :session "s" :turn "n-1" :model "model-a"
                              :at "2026-11-04T10:00:00Z" :device "test-device"
                              :prompt_mode "excerpt" :redacted :false)))
            (should (equal (harness-commit-attribution-test--store-prompt
                            service "conv-a" record)
                           '(:success_count 1 :failure_count 0)))
            ;; A record naming another conversation is refused.
            (should (equal (harness-commit-attribution-test--store-prompt
                            service "conv-b" (list :conversation "other" :prompt "x"))
                           '(:success_count 0 :failure_count 1)))
            (let ((records (harness-commit-attribution-test--prompt-records
                            service (list "conv-a" "conv-b"))))
              (should (equal (plist-get (cdr (assoc "conv-a"
                                                    (harness-commit-attribution-test--session-prompts
                                                     service (list "s"))))
                                        :prompt)
                             "a redacted prompt"))
              (should (equal (plist-get (cdr (assoc "conv-a" records)) :prompt)
                             "a redacted prompt"))
              (should (equal (plist-get (cdr (assoc "conv-a" records)) :model)
                             "model-a"))
              (should-not (assoc "conv-b" records))))
          ;; An unknown conversation is a 404, as for notes.
          (let ((status nil))
            (harness-http-request
             (format "%s/management/prompts/?conversations=nobody" (plist-get service :url))
             :headers (list (cons "X-API-Key" (plist-get service :token)))
             :callback (lambda (s _h _b _e) (setq status s)))
            (harness-test-wait (lambda () status) 10 "the prompt 404")
            (should (= status 404)))
          ;; The management status endpoint says the API is there, even
          ;; before a prompt is stored; the doctor probes it.
          (let ((status (harness-test-await
                         (harness-http-request-json
                          (format "%s/management/status" (plist-get service :url))
                          :headers (list (cons "X-API-Key" (plist-get service :token))))
                         10)))
            (should (harness-json-true-p (plist-get status :ok)))
            (should (numberp (plist-get status :prompts))))
          ;; Prompt reads need the token too.
          (let ((status nil))
            (harness-http-request
             (format "%s/management/prompts/?conversations=conv-a" (plist-get service :url))
             :callback (lambda (s _h _b _e) (setq status s)))
            (harness-test-wait (lambda () status) 10 "the prompt 401")
            (should (= status 401)))
          ;; Prompts are not on git-ai's worker API: the management API is
          ;; the only way in, and git-ai never sees a prompt endpoint.
          (let ((status nil))
            (harness-http-request
             (format "%s/worker/prompts/upload" (plist-get service :url))
             :method "POST"
             :headers (list (cons "X-API-Key" (plist-get service :token)))
             :json (list :entries nil)
             :callback (lambda (s _h _b _e) (setq status s)))
            (harness-test-wait (lambda () status) 10 "the worker prompt 404")
            (should (= status 404)))
          ;; The notes table has no prompt column; prompts have their own
          ;; table, and the prompt text is stored only there.  Reading it
          ;; through SQLite also sees the WAL, which a byte scan of the
          ;; main file would miss.
          (let* ((schema (string-trim
                          (with-temp-buffer
                            (call-process (or (executable-find "python3") "python3")
                                          nil t nil "-c"
                                          (concat "import json,sqlite3,sys;"
                                                  "db=sqlite3.connect(sys.argv[1]);"
                                                  "print(json.dumps({"
                                                  "'notes':[r[1] for r in db.execute("
                                                  "'pragma table_info(notes)')],"
                                                  "'prompts':[r[1] for r in db.execute("
                                                  "'pragma table_info(prompts)')],"
                                                  "'records':[r[0] for r in db.execute("
                                                  "'select record from prompts')]}))")
                                          (plist-get service :db))
                            (buffer-string))))
                 (notes-columns (and (string-match "\"notes\": \\[\\(.*?\\)\\]" schema)
                                     (match-string 1 schema)))
                 (prompt-columns (and (string-match "\"prompts\": \\[\\(.*?\\)\\]" schema)
                                      (match-string 1 schema))))
            (should-not (string-match-p "prompt" notes-columns))
            (should (string-match-p "commit_sha" notes-columns))
            (should (string-match-p "conversation" prompt-columns))
            (should (string-match-p "record" prompt-columns))
            (should (string-match-p "session" prompt-columns))
            (should (string-match-p "prompt_at" prompt-columns))
            (should (string-match-p "a redacted prompt" schema))
            (should-not (string-match-p "hello prompt" schema))))
          ;; Deleting is a management operation too.
          (let ((deleted (harness-test-await
                          (harness-http-request-json
                           (format "%s/management/prompts/delete" (plist-get service :url))
                           :method "POST"
                           :headers (list (cons "X-API-Key" (plist-get service :token)))
                           :json (list :conversations (list "conv-a")))
                          10)))
            (should (= 1 (plist-get deleted :deleted)))
            (should-not (harness-commit-attribution-test--prompt-records
                         service (list "conv-a"))))
      (harness-commit-attribution-test--stop-notes service))))

(ert-deftest harness-commit-attribution-public-remote-gets-no-notes ()
  "Push and mirror carry no refs/notes and no model or prompt string."
  (harness-commit-attribution-test-with-repo
    (let* ((public (expand-file-name "public.git" base))
           (mirror (expand-file-name "mirror.git" base))
           (prompt "PROMPT-ATTRIBUTION-TEST-SECRET")
           (model "MODEL-ATTRIBUTION-TEST-SECRET")
           (sid "private-session"))
      (harness-commit-attribution-test--prompt-turn sessions sid prompt model)
      (harness-emit 'agent/tool-call sid
                    (list :kind 'tool-call :call-id "call-p" :tool "write_file"
                          :input (list :path "README") :meta (list :model model)))
      (harness-emit 'tools/finished sid
                    (list :id "call-p" :name "write_file" :input (list :path "README"))
                    (list :content "wrote" :is-error nil))
      (harness-commit-attribution-test--drain)
      (let ((sha (harness-commit-attribution-test--commit
                  root "secret.txt" "ordinary code\n" "An ordinary commit")))
        (harness-commit-attribution-test--git base "init" "--bare" "-q" public)
        (harness-commit-attribution-test--git base "init" "--bare" "-q" mirror)
        (harness-commit-attribution-test--git root "remote" "add" "origin" public)
        (harness-commit-attribution-test--git root "push" "-q" "origin" "main")
        (harness-commit-attribution-test--git root "push" "-q" "--mirror" mirror)
        (dolist (bare (list public mirror))
          (let ((refs (harness-commit-attribution-test--git bare "for-each-ref")))
            (should-not (string-match-p "refs/notes" refs))
            (let ((objects (with-temp-buffer
                             (let ((default-directory (file-name-as-directory bare)))
                               (call-process "git" nil t nil
                                             "cat-file" "--batch-all-objects" "--batch"))
                             (buffer-string))))
              (should-not (string-match-p (regexp-quote model) objects))
              (should-not (string-match-p (regexp-quote prompt) objects)))))
        ;; The note lives in the private service, not in the repository.
        (let ((notes (harness-commit-attribution-test--git root "for-each-ref" "refs/notes")))
          (should (string-empty-p notes)))
        (should sha)))))

(ert-deftest harness-commit-attribution-status-reports-the-private-mode ()
  "Status names the mode, the program and the missing vault follow-up."
  (harness-commit-attribution-test-with-repo
    (let ((status (harness-call 'commit-attribution/status root)))
      (should (eq (plist-get status :enabled) t))
      (should (equal (plist-get status :notes-mode) "private-service"))
      (should (equal (plist-get status :notes-url) harness-commit-attribution-notes-url))
      (should (equal (plist-get status :program) harness-commit-attribution-git-ai-program))
      (should (eq (plist-get status :prompt-sync) :false))
      (should (string-match-p "phase 3" (plist-get status :vault))))
    (let ((harness-commit-attribution-prompt-sync t))
      (should (eq (plist-get (harness-call 'commit-attribution/status root)
                             :prompt-sync)
                  t)))))

(provide 'harness-commit-attribution-test)
;;; harness-commit-attribution-test.el ends here
