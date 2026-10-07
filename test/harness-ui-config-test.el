;;; harness-ui-config-test.el --- Tests for the settings page  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-model)
(defvar harness-permission-mode)
(defvar harness-thinking)
(defvar harness-log-level)
(defvar harness-non-interactive)
(defvar harness-ui--models)

(defcustom harness-ui-config-test-api-key nil
  "A secret option for the tests."
  :type '(choice (const nil) string) :group 'harness)

(defconst harness-ui-config-test--server-type
  '(plist :tag "Server"
          :value (:id new :url "http://localhost")
          :options ((:id (symbol :tag "ID" :value new :doc "Names the server."))
                    (:url (string :tag "URL" :value "http://localhost"))
                    (:port (integer :tag "Port" :value 8080 :doc "Port it listens on."))
                    (:secure (const :tag "Speaks TLS" t))))
  "A record type, like a provider endpoint's.")

(defcustom harness-ui-config-test-servers '((:id alpha :url "http://alpha"))
  "Servers, records in a list, for the tests.
Each is a plist with these keys:

  :id    a symbol
  :url   where it is"
  :type `(repeat ,harness-ui-config-test--server-type) :group 'harness)

(defcustom harness-ui-config-test-limit 20000
  "A number option for the tests, an advanced one: no section shows it."
  :type 'integer :group 'harness)

(defcustom harness-ui-config-test-hours '((1 . 4))
  "Hours, whose type has numbers among its arguments, like DeepSeek's peak windows."
  :type '(repeat (cons (integer 0 23) (integer 1 24))) :group 'harness)

(defcustom harness-ui-config-test-judge-model nil
  "A model or none, a menu for the tests."
  :type '(choice (const :tag "The session's model" nil) (string :tag "Model" :names model))
  :group 'harness)

(defcustom harness-ui-config-test-fallbacks nil
  "Providers and models, a list for the tests."
  :type '(repeat (string :tag "Provider or model id" :names (provider model))) :group 'harness)

(defconst harness-ui-config-test--models
  '((:id "claude:claude-fable-5-1" :label "Claude Fable 5.1" :provider "claude"
     :provider-label "Claude Code" :context-window 1000000 :pricing (:input 5.0 :output 25.0))
    (:id "claude:claude-opus-5-5" :label "Claude Opus 5.5" :provider "claude"
     :provider-label "Claude Code" :context-window 1000000)
    (:id "deepseek:deepseek-flash" :label "DeepSeek-V4.1-Flash" :provider "deepseek"
     :provider-label "DeepSeek" :context-window 128000 :pricing (:input 0.15 :output 0.6))
    (:id "copilot:gpt-5" :label "GPT-5" :provider "copilot" :provider-label "GitHub Copilot"
     :context-window 400000))
  "The models three providers list, as `provider/models' answers.")

(defun harness-ui-config-test--catalogue ()
  "Make the tests' models the UI's catalogue."
  (clrhash harness-ui--models)
  (dolist (m harness-ui-config-test--models)
    (puthash (plist-get m :id) m harness-ui--models)))

(defvar harness-ui-config-test--picker nil
  "What the last model picker offered: (PROMPT DEFAULT ROWS).
Each of ROWS is (GROUP CANDIDATE ANNOTATION).")

(defmacro harness-ui-config-test-picking (answer &rest body)
  "Run BODY answering the model picker with ANSWER.
ANSWER is text, answered as typed, or a function of the candidates
that returns the answer.  `harness-ui-config-test--picker' then says
what the picker offered."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (prompt table _pred _require _initial _history &optional default &rest _)
                (let* ((all (all-completions "" table))
                       (metadata (completion-metadata "" table nil))
                       (group (completion-metadata-get metadata 'group-function))
                       (note (completion-metadata-get metadata 'annotation-function))
                       (answer ,answer))
                  (setq harness-ui-config-test--picker
                        (list prompt default
                              (mapcar (lambda (c) (list (funcall group c nil) c (funcall note c))) all)))
                  (if (functionp answer) (funcall answer all) answer)))))
     ,@body))

(defun harness-ui-config-test-candidate (regexp)
  "Return a function picking the first candidate matching REGEXP."
  (lambda (all) (or (cl-find-if (lambda (c) (string-match-p regexp c)) all)
                    (error "No candidate matches %s" regexp))))

(defun harness-ui-config-test--project ()
  "Return a fresh git project."
  (let ((root (harness-test-temp-dir)))
    (let ((default-directory root)) (call-process "git" nil nil nil "init" "-q"))
    root))

(defmacro harness-ui-config-test-with (&rest body)
  "Load the state layer, ACP, the UI and the settings page; run BODY.
ROOT is a fresh project.  Global saves reach a custom file of the temp
state directory, as they would the user's."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config acp ui ui-config))
         (harness-test-load-module m)))
     (let* ((harness-acp-token nil)
            (root (harness-ui-config-test--project))
            (default-directory root)
            ;; Like a normal session: customize refuses to save under "emacs -q".
            (init-file-user "")
            (user-init-file (expand-file-name "init.el" harness-state-directory))
            (custom-file (expand-file-name "custom.el" harness-state-directory))
            (harness-ui-config--default-scope 'global)
            (harness-model harness-model)
            (harness-permission-mode harness-permission-mode)
            (harness-thinking harness-thinking)
            (harness-ui-config-test-limit 20000)
            (harness-ui-config-test-judge-model nil)
            (harness-ui-config-test-fallbacks nil)
            ;; The providers have listed nothing, unless a test says what.
            (harness-ui--models (make-hash-table :test 'equal))
            (harness-log-level 'info)
            (harness-non-interactive harness-non-interactive)
            (harness-ui-config-test-api-key nil)
            (harness-ui-config-test-servers (copy-tree harness-ui-config-test-servers)))
       (unwind-protect
           (progn ,@body)
         (dolist (b (harness-ui-config--buffers)) (kill-buffer b))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))
         (ignore-errors (delete-directory root t))))))

(defun harness-ui-config-test-open (dir)
  "Open the settings page of DIR, make it current and wait for its data."
  (set-buffer (harness-settings dir))
  (harness-test-wait (lambda () (and harness-ui-config--data (not harness-ui-config--loading))) 5 "settings"))

(defun harness-ui-config-test-setting (key)
  "Return the latest description of KEY on the current page."
  (harness-ui-config--setting key))

(defun harness-ui-config-test-wait (key prop value)
  "Wait until PROP of setting KEY on the current page is VALUE."
  (let ((buf (current-buffer)))
    (harness-test-wait (lambda () (with-current-buffer buf
                                    (equal value (plist-get (harness-ui-config-test-setting key) prop))))
                       5 (format "%s %s = %S" key prop value))
    (set-buffer buf)))

(defun harness-ui-config-test-block (key)
  "Return the text the page shows for setting KEY."
  (let ((start (harness-ui-config--setting-start key)))
    (buffer-substring-no-properties
     start (next-single-property-change start 'harness-ui-config-key nil (point-max)))))

(defun harness-ui-config-test-goto (key text)
  "Move point to TEXT inside the block of setting KEY."
  (goto-char (harness-ui-config--setting-start key))
  (let ((case-fold-search nil)) (search-forward text))
  (goto-char (match-beginning 0)))

(defun harness-ui-config-test-type (key text)
  "Replace the text field of setting KEY with TEXT, typing it."
  (goto-char (harness-ui-config--setting-start key))
  (let ((field (progn (widget-forward 1) (widget-field-at (point)))))
    (should field)
    (goto-char (widget-field-start field))
    (delete-region (point) (widget-field-end field))
    (execute-kbd-macro text)))

(defun harness-ui-config-test-press (key label &optional last)
  "Press the button LABEL of setting KEY, the LAST one with LAST non-nil."
  (let ((start (harness-ui-config--setting-start key))
        (case-fold-search nil))
    (goto-char start)
    (if (not last)
        (search-forward label)
      (goto-char (next-single-property-change start 'harness-ui-config-key nil (point-max)))
      (search-backward label start))
    (goto-char (match-beginning 0))
    (should (get-char-property (point) 'button))
    (execute-kbd-macro (kbd "RET"))))

(defun harness-ui-config-test-await-block (key regexp)
  "Wait until the block of setting KEY matches REGEXP; return the block."
  (let ((buf (current-buffer)))
    (harness-test-wait (lambda () (with-current-buffer buf
                                    (string-match-p regexp (harness-ui-config-test-block key))))
                       5 (format "%s showing %s" key regexp))
    (set-buffer buf)
    (harness-ui-config-test-block key)))

(defun harness-ui-config-test-type-after (key label text)
  "Replace the text of the field after LABEL in setting KEY with TEXT, typing it."
  (harness-ui-config-test-goto key label)
  (widget-forward 1)
  (let ((field (widget-field-at (point))))
    (should field)
    (goto-char (widget-field-start field))
    (delete-region (point) (widget-field-end field))
    (execute-kbd-macro text)))

(defun harness-ui-config-test-dir-locals (dir)
  "Return the alist of DIR's .dir-locals.el, or `none'."
  (let ((file (expand-file-name ".dir-locals.el" dir)))
    (if (file-exists-p file)
        (with-temp-buffer (insert-file-contents file) (read (current-buffer)))
      'none)))

(ert-deftest harness-ui-config-renders-layers-and-toggles-scope ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (with-temp-file (expand-file-name ".dir-locals.el" root)
      (insert "((nil . ((harness-permission-mode . yolo) (harness-sandbox-policy . 5))))"))
    (harness-ui-config-test-open root)
    (should (derived-mode-p 'harness-ui-config-mode))
    (should-not (string-match-p "does not fit" (harness-ui-config-test-block "harness-sandbox-policy")))
    (should (equal (format "*harness settings: %s*" (file-name-nondirectory (directory-file-name root)))
                   (buffer-name)))
    (should (eq 'global harness-ui-config--scope))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      ;; The common settings come in sections named by what they are for.
      (should (string-match-p "^ New sessions$" text))
      (should (string-match-p "^ Spending$" text))
      (should (string-match-p "^ Files and safety$" text))
      ;; The tasks module is not loaded here, so its section is absent.
      (should-not (string-match-p "^ Task board$" text))
      ;; The advanced ones are folded into one line until asked for.
      (should (string-match-p "^ Advanced  \\[?Show [0-9]+ more" text))
      (should-not (string-match-p "Log level: " text)))
    (execute-kbd-macro "a")
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      ;; Shown, they are listed by module.
      (should (string-match-p "^ Core$" text))
      (should (string-match-p "Log level: " text)))
    ;; Each setting shows its value, and where the project's comes from.
    (should (string-match-p "Permission mode: \\[Value Menu\\] Ask"
                            (harness-ui-config-test-block "harness-permission-mode")))
    (should (string-match-p "this project uses YOLO" (harness-ui-config-test-block "harness-permission-mode")))
    (should (string-match-p "Model: " (harness-ui-config-test-block "harness-model")))
    ;; The header line has a mouse target for both scopes.
    (let ((header (harness-ui-config--header most-positive-fixnum)))
      (dolist (label '("Global" "Project"))
        (let ((pos (string-match label header)))
          (should pos)
          (should (keymapp (get-text-property pos 'local-map header)))
          (should (get-text-property pos 'help-echo header)))))
    ;; s switches to the Project scope.
    (goto-char (point-min))
    (execute-kbd-macro "s")
    (should (eq 'project harness-ui-config--scope))
    (let ((mode (harness-ui-config-test-block "harness-permission-mode")))
      (should (string-match-p "\\[Value Menu\\] YOLO" mode))
      (should (string-match-p "set for this project" mode))
      (should (string-match-p "global is Ask" mode))
      (should (string-match-p "Remove override" mode)))
    (should (string-match-p "uses the global value" (harness-ui-config-test-block "harness-model")))
    ;; A project value the harness finds invalid is edited as Lisp, with a warning.
    (should (string-match-p "does not fit" (harness-ui-config-test-block "harness-sandbox-policy")))
    ;; The Budget is one for all sessions, set globally only.
    (should-not (harness-ui-config--setting-start "harness-budget"))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "more settings have a global value only" text))
      (should-not (string-match-p "Advanced" text))
      (should-not (string-match-p "Log level: " text)))
    ;; And back, with the advanced settings still shown.
    (harness-ui-config-toggle-scope)
    (should (eq 'global harness-ui-config--scope))
    (should (string-match-p "Log level: " (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest harness-ui-config-saves-and-resets-global-values ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (harness-ui-config-test-open root)
    (harness-ui-config-toggle-advanced)
    ;; Typing marks the setting edited; RET saves it through customize.
    (harness-ui-config-test-type "harness-ui-config-test-limit" "30000")
    (should (harness-ui-config--edited-p "harness-ui-config-test-limit"))
    (should (= 1 (harness-ui-config--edit-count)))
    (execute-kbd-macro (kbd "RET"))
    (harness-ui-config-test-wait "harness-ui-config-test-limit" :global "30000")
    (should (= 30000 harness-ui-config-test-limit))
    (harness-test-wait (lambda () (and (file-exists-p custom-file)
                                       (string-search "(harness-ui-config-test-limit 30000"
                                                      (harness-read-file custom-file))))
                       5 "custom file")
    (should-not (harness-ui-config--edited-p "harness-ui-config-test-limit"))
    (should (string-match-p "customized . default is 20000"
                            (harness-ui-config-test-block "harness-ui-config-test-limit")))
    ;; A toggle saves at once.
    (harness-ui-config-test-goto "harness-non-interactive" "[Toggle]")
    (execute-kbd-macro (kbd "RET"))
    (harness-ui-config-test-wait "harness-non-interactive" :global "t")
    (should (eq t harness-non-interactive))
    ;; d resets a customized value to its default.
    (goto-char (harness-ui-config--setting-start "harness-ui-config-test-limit"))
    (execute-kbd-macro "d")
    (harness-ui-config-test-wait "harness-ui-config-test-limit" :global "20000")
    (should (= 20000 harness-ui-config-test-limit))
    ;; Nothing was written to the project.
    (should (eq 'none (harness-ui-config-test-dir-locals root)))))

(ert-deftest harness-ui-config-saves-and-removes-project-overrides ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (harness-ui-config-test-open root)
    (harness-ui-config-set-scope 'project)
    ;; A menu pick saves at once, to the project's .dir-locals.el.
    (cl-letf (((symbol-function 'widget-choose)
               (lambda (_title items &rest _) (cdr (assoc "YOLO" items)))))
      (harness-ui-config-test-goto "harness-permission-mode" "[Value Menu]")
      (execute-kbd-macro (kbd "RET")))
    (harness-ui-config-test-wait "harness-permission-mode" :project "yolo")
    (should (equal '((nil . ((harness-permission-mode . yolo)))) (harness-ui-config-test-dir-locals root)))
    ;; The global value is untouched.
    (should-not (eq 'yolo harness-permission-mode))
    ;; So does a model.  Before the providers list theirs, the picker
    ;; takes one typed.
    (should (null (plist-get (harness-ui-config-test-setting "harness-model") :project)))
    (harness-ui-config-test-picking "demo:scripted"
      (harness-ui-config-test-press "harness-model" "\u25be"))
    (should (string-match-p "no models listed yet" (car harness-ui-config-test--picker)))
    (harness-ui-config-test-wait "harness-model" :project "\"demo:scripted\"")
    (should (equal "demo:scripted"
                   (cdr (assq 'harness-model (cdr (assq nil (harness-ui-config-test-dir-locals root)))))))
    ;; [Remove override] deletes the entry; the global value applies again.
    (harness-ui-config-test-goto "harness-permission-mode" "Remove override")
    (execute-kbd-macro (kbd "RET"))
    (harness-ui-config-test-wait "harness-permission-mode" :project nil)
    (should (equal '((nil . ((harness-model . "demo:scripted")))) (harness-ui-config-test-dir-locals root)))
    (should (string-match-p "uses the global value" (harness-ui-config-test-block "harness-permission-mode")))
    ;; Removing the last one removes the file.
    (goto-char (harness-ui-config--setting-start "harness-model"))
    (execute-kbd-macro "d")
    (harness-ui-config-test-wait "harness-model" :project nil)
    (should (eq 'none (harness-ui-config-test-dir-locals root)))))

(ert-deftest harness-ui-config-follows-changes-made-elsewhere ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (harness-ui-config-test-open root)
    (harness-ui-config-set-scope 'project)
    (harness-call 'config/set 'harness-thinking "high" :scope 'project :cwd root)
    (harness-ui-config-test-wait "harness-thinking" :project "\"high\"")
    (let ((block (harness-ui-config-test-block "harness-thinking")))
      (should (string-match-p "\\[Value Menu\\] High" block))
      (should (string-match-p "set for this project" block)))
    (harness-call 'config/unset 'harness-thinking :scope 'project :cwd root)
    (harness-ui-config-test-wait "harness-thinking" :project nil)
    (should (string-match-p "uses the global value" (harness-ui-config-test-block "harness-thinking")))))

(ert-deftest harness-ui-config-keeps-edits-across-redraws-and-scopes ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (harness-ui-config-test-open root)
    (harness-ui-config-toggle-advanced)
    (harness-ui-config-test-type "harness-ui-config-test-limit" "30000")
    ;; A change elsewhere redraws the page; the edit and point stay, in
    ;; the setting, which the change above it moved down.
    (let ((offset (lambda () (- (point) (harness-ui-config--setting-start "harness-ui-config-test-limit"))))
          (pos (point)))
      (let ((before (funcall offset)))
        (harness-call 'config/set 'harness-thinking "low" :scope 'global :cwd root)
        (harness-ui-config-test-wait "harness-thinking" :global "\"low\"")
        (should (< pos (point)))
        (should (= before (funcall offset)))))
    (should (equal 30000 (widget-value (harness-ui-config--widget "harness-ui-config-test-limit"))))
    (should (harness-ui-config--edited-p "harness-ui-config-test-limit"))
    ;; Edits belong to their scope.
    (harness-ui-config-set-scope 'project)
    (should-not (harness-ui-config--edited-p "harness-ui-config-test-limit"))
    (should (= 1 (harness-ui-config--edit-count 'global)))
    (should (string-match-p "Global." (harness-ui-config--header most-positive-fixnum)))
    (harness-ui-config-set-scope 'global)
    (should (equal 30000 (widget-value (harness-ui-config--widget "harness-ui-config-test-limit"))))
    ;; C-c C-k drops the edit.
    (goto-char (harness-ui-config--setting-start "harness-ui-config-test-limit"))
    (execute-kbd-macro (kbd "C-c C-k"))
    (should-not (harness-ui-config--edited-p "harness-ui-config-test-limit"))
    (should (equal 20000 (widget-value (harness-ui-config--widget "harness-ui-config-test-limit"))))
    ;; Invalid input is refused on the page, with the reason on the setting.
    (harness-ui-config-test-type "harness-ui-config-test-limit" "12x")
    (should-error (execute-kbd-macro (kbd "RET")) :type 'user-error)
    (should (eq 'error (car-safe (harness-ui-config--state-of "harness-ui-config-test-limit"))))
    ;; The advanced settings do not fold away with an edit not saved.
    (should-error (harness-ui-config-toggle-advanced) :type 'user-error)
    (should (harness-ui-config--setting-start "harness-ui-config-test-limit"))))

(ert-deftest harness-ui-config-never-shows-secrets ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (setq harness-ui-config-test-api-key "sk-already-set")
    (harness-ui-config-test-open root)
    (harness-ui-config-toggle-advanced)
    (let ((block (harness-ui-config-test-block "harness-ui-config-test-api-key")))
      (should (string-match-p "Change" block))
      (should (string-match-p "never shown" block)))
    (should-not (string-search "sk-already-set" (buffer-string)))
    (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (copy-sequence "sk-new-value"))))
      (harness-ui-config-test-goto "harness-ui-config-test-api-key" "Change")
      (execute-kbd-macro (kbd "RET")))
    (harness-test-wait (lambda () (equal "sk-new-value" harness-ui-config-test-api-key)) 5 "secret saved")
    (let ((buf (current-buffer)))
      (harness-test-wait (lambda () (with-current-buffer buf
                                      (null (harness-ui-config--state-of "harness-ui-config-test-api-key"))))
                         5 "save settled"))
    (should-not (string-search "sk-new-value" (buffer-string)))
    ;; Secrets have a global value only.
    (harness-ui-config-set-scope 'project)
    (should-not (harness-ui-config--setting-start "harness-ui-config-test-api-key"))))

(ert-deftest harness-ui-config-names-settings-and-sections ()
  (require 'harness-ui-config)
  (dolist (case '(("harness-model" "config" "Model")
                  ("harness-non-interactive" "config" "Non-interactive")
                  ("harness-tasks-non-interactive" "tasks" "Non-interactive")
                  ("harness-tasks-max-running" "tasks" "Max running")
                  ("harness-tasks-refine-model" "tasks" "Refine model")
                  ("harness-brave-api-key" "tools-web" "Brave API key")
                  ("harness-openai-endpoints" "provider-openai" "Endpoints")
                  ("harness-anthropic-admin-api-key" "usage" "Anthropic admin API key")
                  ("harness-provider-claude-program" "provider-claude" "Program")
                  ("harness-log-level" "core" "Log level")))
    (should (equal (nth 2 case)
                   (harness-ui-config--label (list :key (nth 0 case) :module (nth 1 case))))))
  (should (equal "Task mode" (harness-ui-config--module-title "tasks")))
  (should (equal "AWS Bedrock" (harness-ui-config--module-title "provider-bedrock")))
  (should (equal "Some module" (harness-ui-config--module-title "some-module"))))

(ert-deftest harness-ui-config-folds-advanced-settings ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (setq harness-log-level 'debug)
    (harness-ui-config-test-open root)
    (let* ((settings (plist-get harness-ui-config--data :settings))
           (advanced (cl-remove-if-not #'harness-ui-config--advanced-p settings))
           (text (buffer-substring-no-properties (point-min) (point-max))))
      (should (member "harness-log-level" (mapcar (lambda (s) (plist-get s :key)) advanced)))
      (should-not (cl-some #'harness-ui-config--advanced-p
                           (cl-remove-if-not (lambda (s) (harness-ui-config--true (plist-get s :layered)))
                                             settings)))
      ;; Folded: how many there are, and how many differ from their default.
      (should (string-match-p (format "Show %d more" (length advanced)) text))
      (should (string-match-p "1 changed here" text))
      (should-not (harness-ui-config--setting-start "harness-log-level"))
      ;; The button shows them, and its label offers to hide them again.
      (goto-char (point-min))
      (search-forward (format "Show %d more" (length advanced)))
      (widget-button-press (match-beginning 0))
      (harness-test-wait (lambda () harness-ui-config--show-advanced) 2 "advanced shown")
      (harness-test-wait (lambda () (harness-ui-config--setting-start "harness-log-level")) 2 "drawn")
      (should (string-match-p "Hide them" (buffer-substring-no-properties (point-min) (point-max)))))
    ;; From the Project scope, `a' shows them in the Global scope.
    (harness-ui-config-set-scope 'project)
    (setq harness-ui-config--show-advanced nil)
    (execute-kbd-macro "a")
    (should (eq 'global harness-ui-config--scope))
    (should (harness-ui-config--setting-start "harness-log-level"))
    ;; The interface's own options are a click away, in Customize.
    (let (group)
      (cl-letf (((symbol-function 'customize-group) (lambda (g &rest _) (setq group g))))
        (goto-char (point-min))
        (search-forward "Customize the interface")
        (widget-button-press (match-beginning 0)))
      (should (eq 'harness-ui group)))
    ;; The menu lists the page's commands.
    (let ((commands (cl-loop for column in (cdr (get 'harness-ui-config-mode 'harness-menu-group))
                             append (cl-loop for item across column
                                             when (consp item) collect (nth 2 item)))))
      (should (memq 'harness-ui-config-toggle-advanced commands))
      (should (memq 'harness-ui-config-customize-interface commands)))))

(ert-deftest harness-ui-config-draws-types-with-numbers-in-them ()
  "A type with numbers among its arguments draws, and so does the rest.
DeepSeek's peak windows are (repeat (cons (integer 0 23) (integer 1
24))): looking a number up as a widget type signalled, so the page
stopped drawing at that setting and never set its widgets up."
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (harness-ui-config-test-open root)
    (should-not (harness-ui-config--form-p '(repeat (cons (integer 0 23) (integer 1 24)))))
    (harness-ui-config-toggle-advanced)
    (should (string-match-p "Hours" (harness-ui-config-test-block "harness-ui-config-test-hours")))
    ;; The page goes on to its end.
    (should (string-match-p "Customize the interface"
                            (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest harness-ui-config-entry-points ()
  (harness-ui-config-test-with
    (should (eq 'harness-settings (lookup-key harness-ui-map (kbd "S"))))
    (should (transient-get-suffix 'harness-menu "S"))
    ;; From a buffer in the project the page is about the project.
    (let ((file-buffer (find-file-noselect (expand-file-name "notes.txt" root))))
      (unwind-protect
          (with-current-buffer file-buffer
            (let ((page (harness-settings)))
              (should (equal (harness-ui-config--buffer-name root) (buffer-name page)))
              (should (equal root (buffer-local-value 'harness-ui-config--root page)))
              (should (equal root (buffer-local-value 'harness-ui-config--cwd page)))))
        (kill-buffer file-buffer)))))

;;;; Records

(ert-deftest harness-ui-config-folds-records-and-opens-them-as-forms ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (harness-ui-config-test-open root)
    (harness-ui-config-toggle-advanced)
    (let ((block (harness-ui-config-test-block "harness-ui-config-test-servers")))
      ;; One line per record, never the Lisp of a plist.
      (should (string-match-p "alpha · http://alpha +\\[?Edit" block))
      (should-not (string-match-p "Lisp expression\\|Symbol:\\|URL:" block))
      ;; The documentation shows its first line; the form says the rest.
      (should (string-match-p "Servers, records in a list, for the tests\\. +\\[?More" block))
      (should-not (string-match-p ":url   where it is" block)))
    (harness-ui-config-test-press "harness-ui-config-test-servers" "Edit")
    (let ((block (harness-ui-config-test-await-block "harness-ui-config-test-servers" "Hide")))
      ;; Each key by name, lined up, with its help; a key not set is
      ;; offered with the value it starts from, a flag by what it means.
      (should (string-match-p "\\[X\\] ID: +alpha\n +Names the server\\." block))
      (should (string-match-p "\\[X\\] URL: +http://alpha" block))
      (should (string-match-p "\\[ \\] Port: +8080\n +Port it listens on\\." block))
      (should (string-match-p "\\[ \\] Speaks TLS" block))
      (let ((id (progn (string-match "ID: +" block) (match-end 0)))
            (url (progn (string-match "URL: +" block) (match-end 0))))
        (should (= (- id (save-match-data (string-match "\\[X\\] ID" block)))
                   (- url (string-match "\\[X\\] URL" block))))))
    ;; The page's commands know the form belongs to the setting.
    (harness-ui-config-test-goto "harness-ui-config-test-servers" "Port it listens")
    (should (equal "harness-ui-config-test-servers" (harness-ui-config--key-at-point)))
    (should-not (harness-ui-config--edited-p "harness-ui-config-test-servers"))
    ;; A redraw keeps it open.
    (harness-call 'config/set 'harness-thinking "low" :scope 'global :cwd root)
    (harness-ui-config-test-wait "harness-thinking" :global "\"low\"")
    (should (string-match-p "URL:" (harness-ui-config-test-block "harness-ui-config-test-servers")))
    (harness-ui-config-test-press "harness-ui-config-test-servers" "Hide")
    (harness-ui-config-test-await-block "harness-ui-config-test-servers" "alpha.*Edit")
    (should-not (string-match-p "URL:" (harness-ui-config-test-block "harness-ui-config-test-servers")))
    ;; [More] shows the whole documentation.
    (harness-ui-config-test-press "harness-ui-config-test-servers" "More")
    (harness-ui-config-test-await-block "harness-ui-config-test-servers" ":url   where it is")))

(ert-deftest harness-ui-config-saves-a-record-edited-in-its-form ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (setq harness-ui-config-test-servers '((:id alpha :url "http://alpha" :extra 1)))
    (harness-ui-config-test-open root)
    (harness-ui-config-toggle-advanced)
    (harness-ui-config-test-press "harness-ui-config-test-servers" "Edit")
    (harness-ui-config-test-await-block "harness-ui-config-test-servers" "Hide")
    ;; A key the type does not name stays, to be removed if wanted.
    (should (string-match-p "Other key: :extra" (harness-ui-config-test-block "harness-ui-config-test-servers")))
    (harness-ui-config-test-type-after "harness-ui-config-test-servers" "URL:" "http://beta")
    (should (harness-ui-config--edited-p "harness-ui-config-test-servers"))
    ;; Ticking a key gives it the value it starts from.
    (harness-ui-config-test-goto "harness-ui-config-test-servers" "[ ] Port")
    (execute-kbd-macro (kbd "RET"))
    (harness-ui-config-test-goto "harness-ui-config-test-servers" "[ ] Speaks TLS")
    (execute-kbd-macro (kbd "RET"))
    (execute-kbd-macro (kbd "C-x C-s"))
    (harness-test-wait (lambda () (equal "http://beta" (plist-get (car harness-ui-config-test-servers) :url)))
                       5 "record saved")
    (harness-test-wait (lambda () (null (harness-ui-config--state-of "harness-ui-config-test-servers")))
                       5 "save settled")
    (let ((server (car harness-ui-config-test-servers)))
      (should (eq 'alpha (plist-get server :id)))
      (should (= 8080 (plist-get server :port)))
      (should (eq t (plist-get server :secure)))
      (should (= 1 (plist-get server :extra))))
    ;; Saved, the page draws again with the record still open.
    (let ((block (harness-ui-config-test-await-block "harness-ui-config-test-servers" "customized")))
      (should (string-match-p "\\[X\\] Port: +8080" block))
      (should (string-match-p "default is alpha" block)))
    (should-not (harness-ui-config--edited-p "harness-ui-config-test-servers"))))

(ert-deftest harness-ui-config-adds-a-record-from-where-its-type-starts ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (harness-ui-config-test-open root)
    (harness-ui-config-toggle-advanced)
    (harness-ui-config-test-press "harness-ui-config-test-servers" "INS" t)
    ;; The new record is open, filled in from the type's starting value.
    (let ((block (harness-ui-config-test-await-block "harness-ui-config-test-servers" "Hide")))
      (should (string-match-p "new · http://localhost +\\[?Hide" block))
      (should (string-match-p "\\[X\\] ID: +new" block))
      (should (string-match-p "alpha · http://alpha +\\[?Edit" block)))
    (should (harness-ui-config--edited-p "harness-ui-config-test-servers"))
    (goto-char (harness-ui-config--setting-start "harness-ui-config-test-servers"))
    (execute-kbd-macro (kbd "C-c C-c"))
    (harness-test-wait (lambda () (= 2 (length harness-ui-config-test-servers))) 5 "record added")
    (should (equal '((:id alpha :url "http://alpha") (:id new :url "http://localhost"))
                   harness-ui-config-test-servers))))

(ert-deftest harness-ui-config-keeps-a-key-with-a-value-of-another-type ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    ;; Set in Lisp: the key stays the key, with a plain editor for its
    ;; odd value, and editing the rest of the record never loses it.
    (setq harness-ui-config-test-servers '((:id alpha :port "eighty")))
    (harness-ui-config-test-open root)
    (harness-ui-config-toggle-advanced)
    (harness-ui-config-test-press "harness-ui-config-test-servers" "Edit")
    (let ((block (harness-ui-config-test-await-block "harness-ui-config-test-servers" "Hide")))
      (should (string-match-p "\\[X\\] Port: +\"eighty\"" block))
      (should (string-match-p "Kept as Lisp: it does not fit Port" block)))
    (harness-ui-config-test-type-after "harness-ui-config-test-servers" "ID:" "beta")
    (execute-kbd-macro (kbd "C-x C-s"))
    (harness-test-wait (lambda () (eq 'beta (plist-get (car harness-ui-config-test-servers) :id)))
                       5 "record saved")
    (should (equal '((:id beta :port "eighty")) harness-ui-config-test-servers))))

(ert-deftest harness-ui-config-presents-types-without-changing-their-values ()
  (require 'harness-ui-config)
  (let ((types `((,harness-ui-config-test--server-type
                  (:id a) (:id a :url "u" :port 1 :secure t) (:port "x" :odd 2) nil)
                 ((repeat ,harness-ui-config-test--server-type) ((:id a) (:url "u")) nil)
                 ((cons (regexp :tag "Name") ,harness-ui-config-test--server-type) ("re" :port 2) ("re"))
                 ((choice (const :tag "None" nil) (string :tag "Model" :names model)) nil "claude:x" "")
                 ((choice (const :tag "Cheap tier" auto) (const nil) (string :names model)) auto nil "x")
                 ((string :names model) "claude:x" "")
                 ((repeat (string :names (provider model))) ("claude" "deepseek:x") nil)
                 ((alist :key-type (string :tag "Level") :value-type (integer :tag "Tokens")) (("low" . 1))))))
    (dolist (case types)
      (let ((presented (widget-convert (harness-ui-config--present (car case)))))
        (dolist (value (cdr case))
          (should (widget-apply presented :match value))))
      (should-not (widget-apply (widget-convert (harness-ui-config--present (car case)))
                                :match 'not-a-fitting-value))))
  ;; A string that names a model is a picker, saved at once, alone or
  ;; with constants, which it offers first; a new one starts from the
  ;; menu's first value.
  (let ((picker (harness-ui-config--present '(choice (const :tag "Configured default" nil)
                                                     (string :tag "Model" :names model)))))
    (should (eq 'harness-ui-config-model (car picker)))
    (should (equal '(model) (plist-get (cdr picker) :names)))
    (should (equal '(("Configured default")) (plist-get (cdr picker) :choices)))
    (should (plist-member (cdr picker) :value))
    (should (null (plist-get (cdr picker) :value))))
  (should (harness-ui-config--discrete-p '(string :names model)))
  (should (equal '(provider model)
                 (plist-get (cdr (cadr (harness-ui-config--present '(repeat (string :names (provider model))))))
                            :names)))
  (should-not (harness-ui-config--discrete-p '(repeat (string :names model))))
  ;; Other strings stay fields, and a menu with more than constants a menu.
  (should (eq 'string (car (harness-ui-config--present '(string :tag "Name")))))
  (should (eq 'choice (car (harness-ui-config--present '(choice (integer) (string :names model))))))
  ;; Summaries name a record, then say what it has.
  (should (equal "alpha · http://alpha · Port 8080 · Speaks TLS"
                 (substring-no-properties
                  (harness-ui-config--summary harness-ui-config-test--server-type
                                              '(:id alpha :url "http://alpha" :port 8080 :secure t)))))
  (should (equal "re · Port 2"
                 (substring-no-properties
                  (harness-ui-config--summary `(cons (regexp :tag "Name") ,harness-ui-config-test--server-type)
                                              '("re" :port 2)))))
  (should (equal "1,000,000" (harness-ui-config--short-number 1000000)))
  (should (equal "8192" (harness-ui-config--short-number 8192))))

;;;; Models

(ert-deftest harness-ui-config-picks-models-the-providers-list ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (harness-ui-config-test--catalogue)
    (harness-ui-config-test-open root)
    ;; A dropdown: the model by name, then its id and context window.
    (should (string-match-p "Model: \\[?Fable 5\\.1 (Claude) \u25be\\]? +claude:claude-fable-5-1 \u00b7 1\\.00M context"
                            (harness-ui-config-test-block "harness-model")))
    ;; The picker offers the providers' models by provider, with their
    ;; context and price, and starts on the model set.  A pick saves at once.
    (harness-ui-config-test-picking (harness-ui-config-test-candidate "Opus")
      (harness-ui-config-test-press "harness-model" "\u25be"))
    (pcase-let ((`(,prompt ,default ,rows) harness-ui-config-test--picker))
      (should (equal "Model (default Fable 5.1 (Claude)): " prompt))
      (should (string-match-p "\\`Fable 5\\.1 (Claude) +claude:claude-fable-5-1\\'" (car default)))
      (should (equal '("Claude Code" "Claude Code" "DeepSeek" "GitHub Copilot") (mapcar #'car rows)))
      (should (string-match-p "1\\.00M context \u00b7 \\$5/\\$25 per M tokens" (nth 2 (car rows))))
      (should (string-match-p "\\`DeepSeek-V4\\.1-Flash (DeepSeek) +deepseek:deepseek-flash\\'"
                              (nth 1 (nth 2 rows)))))
    (harness-ui-config-test-wait "harness-model" :global "\"claude:claude-opus-5-5\"")
    (should (equal "claude:claude-opus-5-5" harness-model))
    (should (string-match-p "customized \u00b7 default is Fable 5\\.1 (Claude)"
                            (harness-ui-config-test-block "harness-model")))
    ;; Text that matches nothing offered is taken as typed: a model no
    ;; provider lists, which the page warns of.
    (harness-ui-config-test-picking "mistral:large-3"
      (harness-ui-config-test-press "harness-model" "\u25be"))
    (harness-ui-config-test-wait "harness-model" :global "\"mistral:large-3\"")
    (should (string-match-p "Model: \\[?mistral:large-3 \u25be\\]?\n +.*No provider lists this model, so its context window is a guess"
                            (harness-ui-config-test-block "harness-model")))
    ;; An id typed in full is that model.
    (harness-ui-config-test-picking " deepseek:deepseek-flash "
      (harness-ui-config-test-press "harness-model" "\u25be"))
    (harness-ui-config-test-wait "harness-model" :global "\"deepseek:deepseek-flash\"")
    ;; Drawn again while the picker is open, the page still takes the pick.
    (let ((page (current-buffer)))
      (harness-ui-config-test-picking
          (lambda (all)
            (let ((before (harness-ui-config--widget "harness-model")))
              (with-current-buffer page (harness-ui-config--render))
              (should-not (eq before (harness-ui-config--widget "harness-model"))))
            (funcall (harness-ui-config-test-candidate "GPT-5") all))
        (harness-ui-config-test-press "harness-model" "\u25be")))
    (harness-ui-config-test-wait "harness-model" :global "\"copilot:gpt-5\"")
    ;; Nothing typed changes nothing.
    (harness-ui-config-test-picking ""
      (harness-ui-config-test-press "harness-model" "\u25be"))
    (should-not (harness-ui-config--edited-p "harness-model"))
    (should-not (harness-ui-config--state-of "harness-model"))
    (should (equal "copilot:gpt-5" harness-model))))

(ert-deftest harness-ui-config-picks-constants-and-providers ()
  (skip-unless (executable-find "git"))
  (harness-ui-config-test-with
    (harness-ui-config-test--catalogue)
    (harness-ui-config-test-open root)
    (harness-ui-config-toggle-advanced)
    ;; A menu of constants and a model: the constants come first.
    (should (string-match-p "Test judge model: \\[?The session's model \u25be"
                            (harness-ui-config-test-block "harness-ui-config-test-judge-model")))
    (harness-ui-config-test-picking (harness-ui-config-test-candidate "DeepSeek-V4")
      (harness-ui-config-test-press "harness-ui-config-test-judge-model" "\u25be"))
    (should (equal '("Choices" "The session's model" nil) (car (nth 2 harness-ui-config-test--picker))))
    (harness-ui-config-test-wait "harness-ui-config-test-judge-model" :global "\"deepseek:deepseek-flash\"")
    (should (string-match-p "customized \u00b7 default is The session's model"
                            (harness-ui-config-test-block "harness-ui-config-test-judge-model")))
    (harness-ui-config-test-picking "The session's model"
      (harness-ui-config-test-press "harness-ui-config-test-judge-model" "\u25be"))
    (harness-ui-config-test-wait "harness-ui-config-test-judge-model" :global "nil")
    ;; In a list each entry is a picker, of providers too; the list
    ;; saves with C-c C-c, and an entry that names nothing is refused.
    (harness-ui-config-test-press "harness-ui-config-test-fallbacks" "INS" t)
    (harness-ui-config-test-await-block "harness-ui-config-test-fallbacks" "Choose a provider or model")
    (should (harness-ui-config--edited-p "harness-ui-config-test-fallbacks"))
    (goto-char (harness-ui-config--setting-start "harness-ui-config-test-fallbacks"))
    (should-error (execute-kbd-macro (kbd "C-c C-c")) :type 'user-error)
    (should (equal '(error . "Pick a provider or a model")
                   (harness-ui-config--state-of "harness-ui-config-test-fallbacks")))
    (harness-ui-config-test-picking (harness-ui-config-test-candidate "\\`DeepSeek ")
      (harness-ui-config-test-press "harness-ui-config-test-fallbacks" "\u25be"))
    (let ((rows (nth 2 harness-ui-config-test--picker)))
      (should (equal '("Providers" "Providers" "Providers") (mapcar #'car (cl-subseq rows 0 3))))
      (should (string-match-p "its model of similar ability" (nth 2 (car rows)))))
    (should (string-match-p "DeepSeek \u25be\\]? +deepseek \u00b7 that provider's model of similar ability"
                            (harness-ui-config-test-block "harness-ui-config-test-fallbacks")))
    (execute-kbd-macro (kbd "C-c C-c"))
    (harness-test-wait (lambda () (equal '("deepseek") harness-ui-config-test-fallbacks)) 5 "list saved")
    (harness-ui-config-test-await-block "harness-ui-config-test-fallbacks" "customized")))

(ert-deftest harness-ui-config-names-models-and-flags-unknown-ones ()
  (require 'harness-ui-config)
  (let ((harness-ui--models (make-hash-table :test 'equal)))
    ;; Before the providers list anything, nothing looks wrong.
    (should-not (plist-get (harness-ui-config--model-about "claude:typo" '(model) nil nil) :problem))
    (harness-ui-config-test--catalogue)
    (should (equal "No provider lists this model, so its context window is a guess"
                   (plist-get (harness-ui-config--model-about "claude:typo" '(model) nil nil) :problem)))
    (should (string-match-p "PROVIDER:MODEL"
                            (plist-get (harness-ui-config--model-about "fable" '(model) nil nil) :problem)))
    (should (string-match-p "No provider has this id"
                            (plist-get (harness-ui-config--model-about "mistral" '(provider model) nil nil)
                                       :problem)))
    ;; A provider's own name for one of its models, as Copilot's default.
    (let ((picker (harness-ui-config--present '(string :names model :provider copilot)))
          (rows (harness-ui-config--model-rows '(model) 'copilot nil)))
      (should (equal "GPT-5 (GitHub)" (harness-ui-config--model-label picker "gpt-5")))
      (should (equal "GitHub Copilot lists no model by this name"
                     (plist-get (harness-ui-config--model-about "gpt-9" '(model) 'copilot nil) :problem)))
      (should (equal '("gpt-5") (mapcar (lambda (r) (nth 2 r)) rows)))
      (should (equal '("gpt-6") (harness-ui-config--model-input "copilot:gpt-6" rows 'copilot))))
    ;; What the picker reads: a candidate, a name or id alone, or else
    ;; text as typed; nothing is no pick.
    (let ((rows (harness-ui-config--model-rows '(model) nil '(("Configured default")))))
      (should (equal '(nil) (harness-ui-config--model-input "Configured default" rows nil)))
      (should (equal '("claude:claude-opus-5-5") (harness-ui-config--model-input (nth 0 (nth 2 rows)) rows nil)))
      (should (equal '("claude:claude-opus-5-5") (harness-ui-config--model-input "Opus 5.5 (Claude)" rows nil)))
      (should (equal '("openai:gpt-6") (harness-ui-config--model-input "openai:gpt-6" rows nil)))
      (should-not (harness-ui-config--model-input "  " rows nil)))
    ;; Sentences name models and providers, in a list too.
    (should (equal "Claude Code, DeepSeek-V4.1-Flash (DeepSeek)"
                   (harness-ui-config--show '("claude" "deepseek:deepseek-flash")
                                            (list :key "harness-fallback-models"
                                                  :type (prin1-to-string
                                                         '(repeat (string :names (provider model))))))))))

(provide 'harness-ui-config-test)
;;; harness-ui-config-test.el ends here
