;;; harness-prompts-test.el --- The prompt registry, its overrides, its call sites  -*- lexical-binding: t; -*-

;;; Commentary:

;; `harness-prompts' keeps every prompt the harness's own model calls
;; send in one registry, and lets a model be sent a template of its own.
;; These tests check the registry itself, the {{variable}} renderer, the
;; override alist and file, that the documentation names every prompt,
;; and that each call site's request builder resolves its text through
;; the registry with the model it asks.  They also check the Customize
;; option, the page, the override editor and what the audit reports of
;; a bad override.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-prompts)
(require 'harness-naming)
(require 'harness-recap)
(require 'harness-compaction)
(require 'harness-insights)
(require 'harness-todo-sync)
(require 'harness-tasks-search)
(require 'harness-pet)
(require 'harness-perms)
(require 'harness-supervisor)
(require 'harness-tools-events)
(require 'harness-cache-warm)
(require 'harness-provider-check)
(require 'harness-tasks)
(require 'harness-agent)
(require 'harness-small)
(require 'harness-secret-sandbox)

(defmacro harness-prompts-test-with-overrides (model overrides &rest body)
  "Run BODY with OVERRIDES for MODEL in `harness-prompt-overrides'."
  (declare (indent 2))
  `(let ((harness-prompt-overrides (list (cons ,model ,overrides)))
         (harness-prompt-overrides-file nil)
         (harness-prompt--file-cache nil))
     ,@body))

(defun harness-prompts-test--system (request)
  "Return REQUEST's system prompt."
  (plist-get request :system))

(defun harness-prompts-test--user-text (request)
  "Return the text of REQUEST's last user message."
  (let* ((messages (plist-get request :messages))
         (last (car (last messages)))
         (content (plist-get last :content)))
    (string-join (delq nil (mapcar (lambda (block) (plist-get block :text)) content))
                 "\n\n")))

(defun harness-prompts-test--references ()
  "Return the prompt names the source under lisp/ passes to the registry."
  (let ((names nil))
    (dolist (file (directory-files-recursively (expand-file-name "lisp" harness-test-root)
                                               "\\.el\\'"))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (re-search-forward
                "(harness-prompt\\(?:-effective\\|-template\\|-default\\)?[ \t\n]*'\\([a-z0-9-]+\\)"
                nil t)
          (push (intern (match-string 1)) names))))
    (delete-dups names)))

;;;; The registry

(ert-deftest harness-prompts-registry-is-well-formed ()
  "Every prompt has one name, a purpose, a module and a template,
its variables are described and its placeholders and variables agree."
  (should-not (harness-prompts-audit))
  (should (> (length (harness-prompt-names)) 20))
  (should (equal (length (harness-prompt-names))
                 (length (delete-dups (copy-sequence (harness-prompt-names)))))))

(ert-deftest harness-prompts-docs-name-every-prompt ()
  "docs/prompts.md names every prompt and tells how to override one."
  (let ((doc (with-temp-buffer
               (insert-file-contents (expand-file-name "docs/prompts.md" harness-test-root))
               (buffer-string))))
    (dolist (name (harness-prompt-names))
      (should (string-match-p (concat "`" (regexp-quote (symbol-name name)) "`") doc)))
    (should (string-match-p "harness-prompt-overrides" doc))
    (should (string-match-p "harness-prompt-overrides-file" doc))))

(ert-deftest harness-prompts-every-call-site-is-registered ()
  "Every prompt a call site resolves is registered, and every one is used."
  (let ((references (harness-prompts-test--references))
        (names (harness-prompt-names)))
    (ert-info ((format "registered but unused: %S" (cl-set-difference names references)))
      (should-not (cl-set-difference names references)))
    (ert-info ((format "used but unregistered: %S" (cl-set-difference references names)))
      (should-not (cl-set-difference references names)))))

;;;; Rendering and overrides

(ert-deftest harness-prompts-render-fills-variables ()
  "A template's placeholders take the values given, once each, and an
undeclared or missing variable is an error."
  (should (equal "a X b Y X" (harness-prompt-render "a {{x}} b {{y}} {{x}}" '(:x "X" :y "Y"))))
  (should (equal "nothing" (harness-prompt-render "nothing" nil)))
  (should (equal "{{not a placeholder" (harness-prompt-render "{{not a placeholder" nil)))
  (should-error (harness-prompt-render "{{x}}" nil) :type 'harness-prompt-error)
  (should-error (harness-prompt-render "{{x}}" '(:y "Y")) :type 'harness-prompt-error))

(ert-deftest harness-prompts-an-override-changes-one-model ()
  "An override is sent to the model it names and no other; without one,
the registry's default template is sent."
  (harness-prompts-test-with-overrides "model:a" '((recap-system . "Recap for A."))
    (should (equal "Recap for A." (harness-prompt 'recap-system nil "model:a")))
    (should (equal (harness-prompt-default 'recap-system)
                   (harness-prompt 'recap-system nil "model:b")))
    (should (equal (harness-prompt-default 'recap-system)
                   (harness-prompt 'recap-system nil nil))))
  (harness-prompts-test-with-overrides "model:a" '((recap-system . "Exact."))
    (let ((harness-prompt-overrides
           (append harness-prompt-overrides
                   '((t . ((recap-system . "Every model.")))))))
      (should (equal "Exact." (harness-prompt 'recap-system nil "model:a")))
      (should (equal "Every model." (harness-prompt 'recap-system nil "model:b"))))))

(ert-deftest harness-prompts-effective-keeps-the-callers-default ()
  "With no override the caller's own string is returned, not the registry's;
with one, the registry template is rendered."
  (let ((harness-prompt-overrides nil)
        (harness-prompt-overrides-file nil))
    (should (equal "The caller's own." (harness-prompt-effective 'recap-system "The caller's own." "m"))))
  (harness-prompts-test-with-overrides "m" '((recap-system . "Override {{x}}."))
    (should (equal "Override V." (harness-prompt-effective 'recap-system "The caller's own." "m" '(:x "V"))))))

(ert-deftest harness-prompts-an-overrides-file-is-read-and-reread ()
  "A file of overrides is read, used for the model it names, read again
when it changes, and beaten by an exact entry in the option."
  (let* ((file (make-temp-file "harness-prompts-" nil ".el"))
         (harness-prompt-overrides nil)
         (harness-prompt-overrides-file file)
         (harness-prompt--file-cache nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "((" "\"model:a\"" " . ((recap-system . \"From the file.\"))))"))
          (should (equal "From the file." (harness-prompt 'recap-system nil "model:a")))
          (should (equal (harness-prompt-default 'recap-system)
                         (harness-prompt 'recap-system nil "model:b")))
          ;; Changed on disk: read again, without a restart.
          (with-temp-file file
            (insert "((" "\"model:a\"" " . ((recap-system . \"Changed on disk.\"))))"))
          (set-file-times file (time-add (current-time) 5))
          (should (equal "Changed on disk." (harness-prompt 'recap-system nil "model:a")))
          ;; The option wins at the same specificity, but not over an
          ;; exact entry in the file when it only has a fallback.
          (let ((harness-prompt-overrides '((t . ((recap-system . "Every model."))))))
            (should (equal "Changed on disk." (harness-prompt 'recap-system nil "model:a")))
            (should (equal "Every model." (harness-prompt 'recap-system nil "model:b")))))
      (delete-file file))))

(ert-deftest harness-prompts-describe-names-purpose-and-template ()
  "A prompt's audit shows its purpose, variables, template and overrides."
  (let ((description (harness-prompt-describe 'recap-system)))
    (should (string-match-p "Purpose:" description))
    (should (string-match-p "Variables:" description))
    (should (string-match-p "Template:" description))
    (should (string-search (harness-prompt-default 'recap-system) description)))
  (harness-prompts-test-with-overrides "model:a" '((recap-system . "The override."))
    (let ((description (harness-prompt-describe 'recap-system "model:a")))
      (should (string-match-p "Override for model:a:" description))
      (should (string-search "The override." description)))))

(ert-deftest harness-prompts-no-override-sends-the-registry-default ()
  "With no override set, every builder sends the registered default text."
  (let ((harness-prompt-overrides nil)
        (harness-prompt-overrides-file nil))
    (should (equal harness-naming--base-system-prompt
                   (harness-naming--system-prompt (list :id "s" :model "m") "m")))
    (should (equal harness-recap--system-prompt
                   (harness-prompts-test--system
                    (harness-recap--request (list :id "s" :model "m" :todos nil)
                                            (list :prompt "Do it" :progress "Progress: 0 turns")
                                            "m"))))
    (should (equal harness-compaction--system-prompt
                   (harness-prompts-test--system
                    (harness-compaction--summary-request
                     (list :id "s" :model "m") "m" nil nil))))
    (should (equal harness-insights--system-prompt
                   (harness-prompts-test--system
                    (harness-insights--request "m" "figures" "/p" "sid"))))
    (should (equal harness-tasks-search--system
                   (harness-prompts-test--system
                    (harness-tasks-search--request "m" "sid"))))
    (should (equal harness-perms--judge-system
                   (harness-perms--judge-system-prompt "m")))
    (should (equal harness-supervisor--judge-system-prompt
                   (harness-supervisor--judge-system "m")))
    (should (equal harness-tools-events--classifier-system
                   (harness-tools-events--classifier-system-prompt "m")))
    (should (equal harness-cache-warm-message (harness-cache-warm--ping "m")))
    (should (equal "You are a helpful assistant."
                   (harness-prompts-test--system
                    (harness-provider-check--request "m" "sid" "Hello"))))))

;;;; Call sites

(ert-deftest harness-prompts-naming-resolves-every-text ()
  "The naming request's system prompt, opening labels, ask and title
request all come from the registry for the model asked."
  (harness-prompts-test-with-overrides
   "model:a"
   '((naming-system . "NAMING")
     (naming-request . "REQUEST")
     (naming-opening . "OPENING")
     (naming-latest . "LATEST")
     (naming-opening-request . "OPENING REQUEST"))
    (should (equal "NAMING"
                   (harness-naming--system-prompt (list :id "s" :model "model:a") "model:a")))
    (let* ((blocks (harness-naming--opening-blocks (cons "First" "Last") "model:a"))
           (opening (plist-get (car blocks) :text)))
      (should (string-prefix-p "OPENING\n\n" opening))
      (should (string-match-p "LATEST\n\n" opening))
      (should (equal "OPENING REQUEST" (plist-get (cadr blocks) :text))))
    (harness-register-method 'session/messages
                             (lambda (_sid)
                               '((:role user :content ((:type "text" :text "First"))))))
    (unwind-protect
        (let* ((messages (harness-naming--messages "s" "model:a"))
               (ask (car (last (plist-get (car (last messages)) :content)))))
          (should (equal "REQUEST" (plist-get ask :text))))
      (harness-unregister-method 'session/messages))))

(ert-deftest harness-prompts-task-naming-resolves-through-the-registry ()
  "A task's ticket-title instruction is resolved for the naming model."
  (harness-prompts-test-with-overrides "model:a" '((task-naming-instructions . "TICKET"))
    (should (equal "BASE\n\nTICKET"
                   (harness-tasks--naming-prompt "BASE" (list :model "model:a" :task "t1"))))))

(ert-deftest harness-prompts-recap-resolves-through-the-registry ()
  "A recap request's system prompt and ask come from the registry."
  (harness-prompts-test-with-overrides
   "model:a" '((recap-system . "RECAP SYSTEM") (recap-ask . "RECAP ASK"))
    (let* ((session (list :id "s" :model "model:a" :todos nil))
           (task (list :prompt "Do it" :progress "Progress: 1 turn"))
           (request (harness-recap--request session task "model:a")))
      (should (equal "RECAP SYSTEM" (harness-prompts-test--system request)))
      (should (string-suffix-p "RECAP ASK" (harness-prompts-test--user-text request))))))

(ert-deftest harness-prompts-compaction-resolves-through-the-registry ()
  "A compaction request's system prompt and final line come from the registry."
  (harness-prompts-test-with-overrides
   "model:a" '((compaction-system . "COMPACTION SYSTEM")
                (compaction-request . "COMPACTION ASK"))
    (let* ((session (list :id "s" :model "model:a"))
           (messages (list (list :role 'user
                                 :content (list (list :type "text" :text "Hello")))))
           (request (harness-compaction--summary-request session "model:a" nil messages)))
      (should (equal "COMPACTION SYSTEM" (harness-prompts-test--system request)))
      (let ((asked (harness-compaction--with-ask messages "model:a")))
        (should (string-suffix-p "COMPACTION ASK" (harness-prompts-test--user-text
                                                  (list :messages asked))))))))

(ert-deftest harness-prompts-insights-resolves-through-the-registry ()
  "An Insights request's system prompt comes from the registry."
  (harness-prompts-test-with-overrides "model:a" '((insights-system . "INSIGHTS"))
    (let ((request (harness-insights--request "model:a" "the figures" "/project" "sid")))
      (should (equal "INSIGHTS" (harness-prompts-test--system request))))))

(ert-deftest harness-prompts-todo-sync-resolves-through-the-registry ()
  "The todo sync's system prompt, ask and fork instructions come from the registry."
  (harness-prompts-test-with-overrides
   "model:a" '((todo-sync-system . "TODO SYSTEM")
                (todo-sync-ask . "TODO ASK")
                (todo-sync-fork-ask . "TODO FORK"))
    (let ((session (list :id "s" :model "model:a" :cwd default-directory)))
      (should (equal "TODO SYSTEM"
                     (harness-prompts-test--system
                      (harness-todo-sync--dumb-request session "model:a" "question"))))
      (should (string-suffix-p "TODO ASK"
                               (harness-todo-sync--prompt session nil nil nil "model:a")))
      (should (string-suffix-p "TODO FORK"
                               (harness-todo-sync--fork-question nil "model:a"))))))

(ert-deftest harness-prompts-task-search-resolves-through-the-registry ()
  "A search's system prompt and closing line come from the registry."
  (harness-prompts-test-with-overrides
   "model:a" '((search-system . "SEARCH SYSTEM") (search-final . "SEARCH FINAL"))
    (should (equal "SEARCH SYSTEM"
                   (harness-prompts-test--system
                    (harness-tasks-search--request "model:a" "sid"))))
    (should (equal "SEARCH FINAL" (harness-tasks-search--closing-text "model:a")))))

(ert-deftest harness-prompts-pet-resolves-through-the-registry ()
  "The pet's hatching system prompt and its voice come from the registry."
  (harness-prompts-test-with-overrides
   "model:a" '((pet-hatch-system . "HATCH")
                (pet-say-system . "SAY {{name}} {{rarity}} {{species}} {{personality}} {{stats}} {{actions}}"))
    (should (equal "HATCH" (harness-pet--hatch-system-for "model:a")))
    (let ((harness-pet--pet (list :seed "a seed" :name "Pip" :personality "Dry.")))
      (should (string-prefix-p "SAY Pip " (harness-pet--say-system "model:a"))))))

(ert-deftest harness-prompts-perms-resolves-every-text ()
  "The permission judge's and the summary's system prompts and questions
come from the registry for the model asked."
  (harness-prompts-test-with-overrides
   "model:a"
   '((perms-judge-system . "JUDGE SYSTEM")
     (perms-judge-question . "JUDGE {{tool}} {{kind}} {{description}} {{input}} {{cwd}} {{roots}} {{harness}}")
     (perms-summary-system . "SUMMARY SYSTEM")
     (perms-summary-question . "SUMMARY {{tool}} {{kind}} {{description}} {{cwd}} {{paths}}{{reason}} {{input}}"))
    (let* ((session (list :id "s" :cwd default-directory :model "model:a"))
           (request (list :session session :tool "t_exec" :kind 'exec
                          :input '(:command "make")))
           (judge-text (harness-perms--judge-text request "model:a")))
      (should (equal "JUDGE SYSTEM" (harness-perms--judge-system-prompt "model:a")))
      (should (string-prefix-p "JUDGE t_exec exec " judge-text))
      (let ((judge (harness-perms--judge-request session "model:a" "SYSTEM" judge-text 1)))
        (should (equal "SYSTEM" (harness-prompts-test--system judge)))
        (should (string-prefix-p "JUDGE" (harness-prompts-test--user-text judge))))
      (let* ((payload (list :tool "t_exec" :kind 'exec :input '(:command "make")
                            :cwd default-directory))
             (summary-text (harness-perms--summary-text session payload "model:a"))
             (summary (harness-perms--summary-request session "model:a" summary-text 1)))
        (should (string-prefix-p "SUMMARY t_exec exec " summary-text))
        (should (equal "SUMMARY SYSTEM" (harness-prompts-test--system summary)))))))

(ert-deftest harness-prompts-session-judge-resolves-through-the-registry ()
  "The session judge's system prompt and question come from the registry."
  (harness-prompts-test-with-overrides
   "model:a" '((session-judge-system . "JUDGE SYSTEM")
                (session-judge-question . "JUDGE {{message}}"))
    (should (equal "JUDGE SYSTEM" (harness-supervisor--judge-system "model:a")))
    (should (equal "JUDGE Hello" (harness-supervisor--judge-question "Hello" "model:a")))))

(ert-deftest harness-prompts-event-classifier-resolves-through-the-registry ()
  "An event watch's classifier system prompt and question come from the registry."
  (harness-prompts-test-with-overrides
   "model:a" '((event-classifier-system . "CLASSIFIER SYSTEM")
                (event-classifier-question . "CLASSIFY {{tag}} {{instructions}} {{event}} {{actions}} {{action-json}}"))
    (let* ((watch (harness-tools-events--make-watch
                   :id "w1" :prompt "Watch failures." :actions '("wake")))
           (record (list :id "e1" :kind 'tool-finished :time (float-time)
                         :summary "It failed.")))
      (should (equal "CLASSIFIER SYSTEM"
                     (harness-tools-events--classifier-system-prompt "model:a")))
      (should (string-prefix-p "CLASSIFY "
                               (harness-tools-events--classifier-text watch record "model:a"))))))

(ert-deftest harness-prompts-cache-warm-resolves-through-the-registry ()
  "The cache warmer's message comes from the registry."
  (harness-prompts-test-with-overrides "model:a" '((cache-warm-ping . "PING"))
    (should (equal "PING" (harness-cache-warm--ping "model:a")))))

(ert-deftest harness-prompts-provider-check-resolves-its-system ()
  "A provider check's system prompt comes from the registry for its model."
  (harness-prompts-test-with-overrides "model:a" '((provider-check-system . "CHECK SYSTEM"))
    (should (equal "CHECK SYSTEM"
                   (harness-prompts-test--system
                    (harness-provider-check--request "model:a" "sid" "Hello"))))))

;;;; Customize and the page

(defmacro harness-prompts-test-with-page (expanded &rest body)
  "Render the prompt page with EXPANDED prompt names open, and run BODY.
The page is the current buffer, with no overrides unless BODY binds some."
  (declare (indent 1))
  `(let ((harness-prompt-overrides nil)
         (harness-prompt-overrides-file nil))
     (with-temp-buffer
       (setq harness-prompts--expanded ,expanded
             harness-prompts--model nil)
       (harness-prompts--render)
       ,@body)))

(ert-deftest harness-prompts-options-are-customizable ()
  "The overrides are Customize options in the `harness-prompts' group,
and the prompt name in an override is chosen from the registry."
  (should (custom-variable-p 'harness-prompt-overrides))
  (should (custom-variable-p 'harness-prompt-overrides-file))
  (let ((group (get 'harness-prompts 'custom-group)))
    (should (assq 'harness-prompt-overrides group))
    (should (assq 'harness-prompt-overrides-file group)))
  (let ((type (format "%S" (get 'harness-prompt-overrides 'custom-type))))
    (should (string-match-p "\\`(alist" type))
    (dolist (name (harness-prompt-names))
      (should (string-match-p (concat "const :tag \"" (regexp-quote (symbol-name name)))
                              type)))))

(ert-deftest harness-prompts-page-shows-every-prompt-and-its-overrides ()
  "The page names every prompt in its module, and lists an override by
the model it is for, with buttons to change it."
  (let ((harness-prompt-overrides '(("model:a" . ((recap-system . "Recap for A."))))))
    (with-temp-buffer
      (setq harness-prompts--expanded nil
            harness-prompts--model nil)
      (harness-prompts--render)
      (let ((page (buffer-string)))
        (dolist (name (harness-prompt-names))
          (should (string-match-p (concat " " (regexp-quote (symbol-name name)))
                                  page)))
        (dolist (module (mapcar (lambda (entry) (plist-get entry :module))
                                harness-prompts--registry))
          (should (string-match-p (concat "^" (regexp-quote (symbol-name module)) "  ")
                                  page)))
        (should (string-match-p "Overrides" page))
        (should (string-match-p "model:a" page))
        (should (string-match-p "Customize" page))
        (should (string-match-p "Add…" page))))))

(ert-deftest harness-prompts-page-keeps-templates-folded-until-opened ()
  "A prompt's template is not on the page until its row is unfolded."
  (harness-prompts-test-with-page nil
    (should-not (string-search (harness-prompt-default 'recap-system)
                               (buffer-string)))
    (harness-prompts--goto-prompt 'recap-system)
    (harness-prompts-toggle)
    (should (string-search (harness-prompt-default 'recap-system)
                           (buffer-string)))
    (harness-prompts-toggle)
    (should-not (string-search (harness-prompt-default 'recap-system)
                               (buffer-string)))))

(ert-deftest harness-prompts-page-shows-what-a-model-is-sent ()
  "With a model shown, the page opens prompts with that model's template,
and marks the ones an override covers."
  (let ((harness-prompt-overrides '(("model:a" . ((recap-system . "RECAP FOR A"))))))
    (with-temp-buffer
      (setq harness-prompts--expanded '(recap-system)
            harness-prompts--model "model:a")
      (harness-prompts--render)
      (should (string-search "RECAP FOR A" (buffer-string)))
      (should (string-search "Model  model:a" (buffer-string)))
      (should (string-match-p "override: model:a" (buffer-string)))))
  (harness-prompts-test-with-page '(recap-system)
    (should (string-search (harness-prompt-default 'recap-system)
                           (buffer-string)))
    (should (string-search "Defaults  Model…" (buffer-string)))))

(ert-deftest harness-prompts-editor-opens-the-template-in-effect ()
  "The editor starts from the template its key is sent.
A model with an entry of its own gets that; one covered by the t entry
starts from what the t entry sends; one covered by nothing starts from
the registry's default."
  (let ((harness-prompt-overrides '((t . ((recap-system . "EVERY MODEL")))
                                    ("model:a" . ((recap-system . "ONLY A")))))
        (buffer nil))
    (unwind-protect
        (progn
          (setq buffer (harness-prompt-edit 'recap-system t))
          (with-current-buffer buffer
            (should (derived-mode-p 'harness-prompt-edit-mode))
            (should (equal "EVERY MODEL" (buffer-string)))
            (should (eq t harness-prompt-edit--key))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (setq buffer (harness-prompt-edit 'recap-system "model:a"))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal "ONLY A" (buffer-string))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (setq buffer (harness-prompt-edit 'recap-system "model:b"))
    (unwind-protect
        (with-current-buffer buffer
          (should (equal "EVERY MODEL" (buffer-string))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))
    (let ((harness-prompt-overrides nil))
      (setq buffer (harness-prompt-edit 'recap-system "model:c"))
      (unwind-protect
          (with-current-buffer buffer
            (should (equal (harness-prompt-default 'recap-system)
                           (buffer-string))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest harness-prompts-editor-saves-through-customize ()
  "Saving the editor stores the override as the Customize option would,
and removing it takes the entry out again."
  (let ((harness-prompt-overrides nil)
        (harness-prompt-overrides-file nil)
        (saved nil)
        (buffer nil))
    (cl-letf (((symbol-function 'harness-save-user-option)
               (lambda (symbol value)
                 (setq saved (list symbol value))
                 (set symbol value))))
      (setq buffer (harness-prompt-edit 'recap-system "model:a"))
      (with-current-buffer buffer
        (erase-buffer)
        (insert "A template for {{name}}")
        (harness-prompt-edit-save))
      (should (equal 'harness-prompt-overrides (car saved)))
      (should (equal "A template for {{name}}"
                     (harness-prompt-template 'recap-system "model:a")))
      (should (equal "A template for A"
                     (harness-prompt 'recap-system '(:name "A") "model:a")))
      (should-not (buffer-live-p buffer))
      (setq saved nil)
      (harness-prompt-remove 'recap-system "model:a" nil t)
      (should (eq 'harness-prompt-overrides (car saved)))
      (should-not (harness-prompt-override 'recap-system "model:a"))
      (should-not harness-prompt-overrides))))

(ert-deftest harness-prompts-audit-checks-the-overrides ()
  "An override naming an unknown prompt or variable is reported."
  (let ((harness-prompt-overrides '((t . ((not-a-prompt . "Text")))))
        (harness-prompt-overrides-file nil))
    (should (cl-some (lambda (problem)
                       (string-match-p "not-a-prompt" problem))
                     (harness-prompts-audit))))
  (let ((harness-prompt-overrides '((t . ((recap-system . "{{unknown}}")))))
        (harness-prompt-overrides-file nil))
    (should (cl-some (lambda (problem)
                       (string-match-p "unknown" problem))
                     (harness-prompts-audit))))
  (let ((harness-prompt-overrides '((t . ((recap-system . "Sound."))))))
    (should-not (harness-prompts-audit))))

;;;; The API a module calls

(ert-deftest harness-prompts-a-small-call-names-its-prompts ()
  "A one-off call that names no prompt, or one the registry lacks, is
refused before it reaches a provider; a named one carries its names."
  (should-error (harness-small-ask (list :model "m" :system "S" :messages nil))
                :type 'harness-prompt-error)
  (should-error (harness-prompt-ask 'not-a-prompt
                                    (list :model "m" :system "S" :messages nil))
                :type 'harness-prompt-error)
  (let ((sent nil))
    (cl-letf (((symbol-function 'harness-small-ask)
               (lambda (request &optional _opts) (setq sent request))))
      (harness-prompt-ask '(recap-system recap-ask)
                          (list :model "m" :system "S" :messages nil))
      (should (equal '(recap-system recap-ask) (plist-get sent :prompts)))
      (should (equal "S" (plist-get sent :system))))))

(ert-deftest harness-prompts-a-module-can-register-a-prompt ()
  "A prompt registered at run time joins the names, renders and audits."
  (let ((harness-prompts--registered nil))
    (harness-prompt-register 'plugin-test-prompt
                             :module 'plugin-test
                             :purpose "Tries the registry from a module."
                             :used-by "plugin-test"
                             :variables '((:name "thing" :description "What it says."))
                             :template "Say {{thing}}.")
    (should (memq 'plugin-test-prompt (harness-prompt-names)))
    (should (equal "Say hello."
                   (harness-prompt 'plugin-test-prompt '(:thing "hello"))))
    (should-not (harness-prompts-audit))
    (should (string-match-p "plugin-test"
                            (harness-prompt-describe 'plugin-test-prompt)))
    (let ((sent nil))
      (cl-letf (((symbol-function 'harness-small-ask)
                 (lambda (request &optional _opts) (setq sent request))))
        (harness-prompt-ask 'plugin-test-prompt (list :model "m"))
        (should (equal '(plugin-test-prompt) (plist-get sent :prompts)))))))

(ert-deftest harness-prompts-only-the-wrapper-calls-small-ask ()
  "Every one-off call in the harness's own source goes through
`harness-prompt-ask', which is what enforces the registry."
  (dolist (file (directory-files-recursively
                 (expand-file-name "lisp" harness-test-root) "\\.el\\'"))
    (unless (member (file-relative-name file harness-test-root)
                    '("lisp/harness-prompts.el" "lisp/modules/harness-small.el"))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (ert-info ((format "calls harness-small-ask directly: %s"
                           (file-relative-name file harness-test-root)))
          (should-not (re-search-forward "(harness-small-ask[ \t\n]" nil t)))))))

(provide 'harness-prompts-test)
;;; harness-prompts-test.el ends here
