;;; harness-ui-config-test.el --- Tests for the settings page  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-model)
(defvar harness-permission-mode)
(defvar harness-thinking)
(defvar harness-log-level)
(defvar harness-non-interactive)

(defcustom harness-ui-config-test-api-key nil
  "A secret option for the tests."
  :type '(choice (const nil) string) :group 'harness)

(defcustom harness-ui-config-test-limit 20000
  "A number option for the tests, an advanced one: no section shows it."
  :type 'integer :group 'harness)

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
            (harness-log-level 'info)
            (harness-non-interactive harness-non-interactive)
            (harness-ui-config-test-api-key nil))
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
      (insert "((nil . ((harness-permission-mode . yolo) (harness-tasks-directory . 5))))"))
    (harness-ui-config-test-open root)
    (should (derived-mode-p 'harness-ui-config-mode))
    (should-not (string-match-p "does not fit" (harness-ui-config-test-block "harness-tasks-directory")))
    (should (equal (format "*harness settings: %s*" (file-name-nondirectory (directory-file-name root)))
                   (buffer-name)))
    (should (eq 'global harness-ui-config--scope))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      ;; The common settings come in sections named by what they are for.
      (should (string-match-p "^ New sessions$" text))
      (should (string-match-p "^ Files and safety$" text))
      (should (string-match-p "^ Task board$" text))
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
    (let ((header (harness-ui-config--header)))
      (dolist (label '("Global" "Project"))
        (let ((seg (cl-find-if (lambda (s) (string-match-p label s)) header)))
          (should seg)
          (should (keymapp (get-text-property 1 'local-map seg)))
          (should (get-text-property 1 'help-echo seg)))))
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
    (should (string-match-p "does not fit" (harness-ui-config-test-block "harness-tasks-directory")))
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
    ;; A text edit waits for C-x C-s.
    (harness-ui-config-test-type "harness-model" "demo:scripted")
    (should (harness-ui-config--edited-p "harness-model"))
    (should (null (plist-get (harness-ui-config-test-setting "harness-model") :project)))
    (execute-kbd-macro (kbd "C-x C-s"))
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
    (harness-ui-config-test-type "harness-model" "demo:edited")
    ;; A change elsewhere redraws the page; the edit and point stay.
    (let ((pos (point)))
      (harness-call 'config/set 'harness-thinking "low" :scope 'global :cwd root)
      (harness-ui-config-test-wait "harness-thinking" :global "\"low\"")
      (should (= pos (point))))
    (should (equal "demo:edited" (widget-value (harness-ui-config--widget "harness-model"))))
    (should (harness-ui-config--edited-p "harness-model"))
    ;; Edits belong to their scope.
    (harness-ui-config-set-scope 'project)
    (should-not (harness-ui-config--edited-p "harness-model"))
    (should (= 1 (harness-ui-config--edit-count 'global)))
    (should (string-match-p "Global." (mapconcat #'identity (harness-ui-config--header) "")))
    (harness-ui-config-set-scope 'global)
    (should (equal "demo:edited" (widget-value (harness-ui-config--widget "harness-model"))))
    ;; C-c C-k drops the edit.
    (goto-char (harness-ui-config--setting-start "harness-model"))
    (execute-kbd-macro (kbd "C-c C-k"))
    (should-not (harness-ui-config--edited-p "harness-model"))
    (should (equal harness-model (widget-value (harness-ui-config--widget "harness-model"))))
    ;; Invalid input is refused on the page, with the reason on the setting.
    (harness-ui-config-toggle-advanced)
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

(provide 'harness-ui-config-test)
;;; harness-ui-config-test.el ends here
