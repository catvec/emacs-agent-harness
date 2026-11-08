;;; harness-memory-test.el --- Tests for lasting memories  -*- lexical-binding: t; -*-

;;; Commentary:

;; The memories are kept in memory.db, their only copy: a row each, with
;; the full-text index and the vectors beside them in the same file.
;; The tests cover the database and the scopes, full-text search and its
;; Elisp fallback, the prompt section and its budget, the tools,
;; consolidation with a stubbed judge, and a redaction.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-redaction)

(defvar harness-memory--entries)
(defvar harness-memory--loaded)
(defvar harness-memory--db)
(defvar harness-memory--db-failed)
(defvar harness-memory--fts-ok)
(defvar harness-memory-embedding-model)
(defvar harness-memory-in-prompt)
(defvar harness-memory-prompt-budget)
(defvar harness-acp--forwarded-events)
(declare-function harness-memory--parse-consolidation "harness-memory" (text))
(declare-function harness-memory--consolidation-plan "harness-memory" (value entries))
(declare-function harness-memory--tool-save "harness-memory" (input ctx))
(declare-function harness-memory--tool-search "harness-memory" (input ctx))
(declare-function harness-memory--tool-get "harness-memory" (input ctx))
(declare-function harness-memory--tool-forget "harness-memory" (input ctx))
(declare-function harness-memory--system-prompt-filter "harness-memory" (prompt session))
(declare-function harness-memory--db-reset "harness-memory" ())
(declare-function harness-acp--extension-allowed-p "harness-acp" (name))

(defvar harness-memory-test--dir nil
  "The project a test adds its memories to; the `dir' of the test's body.")

(defmacro harness-memory-test-with (&rest body)
  "Run BODY with the memory module and a fresh store, one project and another.
`dir' is the project every test works in, `other' a second one."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
       (ert-skip "SQLite is needed: it is where the memories are kept"))
     (harness-test-reset-bus)
     (dolist (m '(store project config tools memory))
       (harness-test-load-module m))
     (let* ((dir (file-name-as-directory (harness-test-temp-dir)))
            (other (file-name-as-directory (harness-test-temp-dir)))
            (default-directory dir))
       (harness-memory--db-reset)
       (setq harness-memory--entries nil
             harness-memory--loaded nil
             harness-memory--db nil
             harness-memory--db-failed nil
             harness-memory--fts-ok nil
             harness-memory-test--dir dir)
       ,@body)))

(defun harness-memory-test-add (text &rest opts)
  "Add TEXT as a memory of the project `dir' with OPTS; return it."
  (harness-call 'memory/add text (append (list :project harness-memory-test--dir) opts)))

(defun harness-memory-test-ids (memories)
  "Return the ids of MEMORIES, in their order."
  (mapcar (lambda (memory) (plist-get memory :id)) memories))

(defun harness-memory-test-texts (memories)
  "Return the texts of MEMORIES, in their order."
  (mapcar (lambda (memory) (plist-get memory :text)) memories))

(ert-deftest harness-memory-saves-user-and-project-memories ()
  "A project memory is filed by the checkout of its worktree; a user memory is everywhere.
The store keeps them, lists them for the project they belong to, and
reads them back after the module forgets what it held."
  (harness-memory-test-with
    (let* ((convention (harness-memory-test-add
                        "Don't import inside function bodies; imports go at the top."
                        :kind "convention" :scope "project" :source "s1"))
           (preference (harness-call 'memory/add "Prefer short answers and no filler."
                                     (list :kind "preference" :scope "user")))
           (fact (harness-memory-test-add "The deploy target is Fly.io."
                                          :kind "fact" :scope "project")))
      (should (string-prefix-p "m-" (plist-get convention :id)))
      (should (eq 'project (plist-get convention :scope)))
      (should (eq 'convention (plist-get convention :kind)))
      (should (eq 'user (plist-get preference :scope)))
      (should-not (plist-get preference :project))
      (should (file-exists-p (expand-file-name "memory.db" harness-state-directory)))
      (should-not (file-exists-p (expand-file-name "memories.json" harness-state-directory)))
      ;; This project sees its own memories and the user's, not another's.
      (should (equal (list (plist-get fact :id) (plist-get preference :id)
                           (plist-get convention :id))
                     (harness-memory-test-ids (harness-call 'memory/list (list :project dir)))))
      (should (equal (list (plist-get preference :id))
                     (harness-memory-test-ids (harness-call 'memory/list (list :project other)))))
      (should (equal (sort (list (plist-get convention :id) (plist-get fact :id)) #'string<)
                     (sort (harness-memory-test-ids
                            (harness-call 'memory/list (list :project dir :scope "project")))
                           #'string<)))
      (should (equal (list (plist-get preference :id))
                     (harness-memory-test-ids
                      (harness-call 'memory/list (list :project dir :scope "user")))))
      ;; Closed and opened again, they are the same memories.
      (harness-memory--db-reset)
      (setq harness-memory--loaded nil harness-memory--entries nil)
      (should (equal (list (plist-get fact :id) (plist-get preference :id)
                           (plist-get convention :id))
                     (harness-memory-test-ids (harness-call 'memory/list (list :project dir))))))))

(ert-deftest harness-memory-add-edits-the-same-memory-and-replaces ()
  "Saving the same text again edits it, and replaces folds older memories into one."
  (harness-memory-test-with
    (let* ((first (harness-memory-test-add "Imports go at the top of the file."
                                           :kind "convention"))
           (again (harness-memory-test-add "Imports go at the top of the file."
                                           :kind "convention"))
           (second (harness-memory-test-add "Never nest imports in a function."
                                            :kind "convention"))
           (third (harness-memory-test-add "Every namespace import is at the top."
                                           :kind "convention")))
      (should (equal (plist-get first :id) (plist-get again :id)))
      (should (= 3 (length (harness-call 'memory/list (list :project dir)))))
      ;; Updating one changes what a search finds.
      (harness-call 'memory/update (plist-get first :id) :text "Put every import at the top."
                    :kind "preference")
      (should (member (plist-get first :id)
                      (harness-memory-test-ids
                       (harness-call 'memory/search "imports" (list :project dir)))))
      (should-not (member (plist-get first :id)
                          (harness-memory-test-ids
                           (harness-call 'memory/search "nested" (list :project dir)))))
      ;; The two older memories are absorbed by a third.
      (let ((merged (harness-memory-test-add
                     "Keep imports at the top of the file."
                     :kind "convention"
                     :replaces (list (plist-get second :id) (plist-get third :id)))))
        (should (= 2 (length (harness-call 'memory/list (list :project dir)))))
        (should-not (harness-call 'memory/get (plist-get second :id)))
        (should-not (harness-call 'memory/get (plist-get third :id)))
        (should (harness-call 'memory/get (plist-get merged :id))))
      ;; A replacement that names nothing changes nothing.
      (let ((before (harness-memory-test-ids (harness-call 'memory/list (list :project dir)))))
        (should-error (harness-memory-test-add "Another import rule."
                                               :kind "convention" :replaces '("m-nope")))
        (should (equal before
                       (harness-memory-test-ids (harness-call 'memory/list (list :project dir))))))
      ;; A memory that does not exist cannot be edited by name.
      (should-error (harness-call 'memory/add "Text" (list :project dir :id "m-nope"
                                                           :kind "fact" :scope "project")))
      ;; A project memory needs a project.
      (should-error (harness-call 'memory/add "Text" (list :kind "convention" :scope "project"))))))

(ert-deftest harness-memory-search-words-phrases-prefixes-or-and-not ()
  "Search reads the session search's syntax, and empty lists every memory."
  (harness-memory-test-with
    (harness-memory-test-add "Don't import inside function bodies." :kind "convention")
    (harness-memory-test-add "The deployment runs on Fly.io." :kind "fact")
    (harness-memory-test-add "Heroku was the old host." :kind "fact")
    (harness-memory-test-add "Prefer short answers, without filler." :kind "preference" :scope "user")
    (should (equal (list "Don't import inside function bodies.")
                   (harness-memory-test-texts (harness-call 'memory/search "imports" (list :project dir)))))
    (should (equal (list "Prefer short answers, without filler.")
                   (harness-memory-test-texts
                    (harness-call 'memory/search "\"short answers\"" (list :project dir)))))
    (should (equal (list "The deployment runs on Fly.io.")
                   (harness-memory-test-texts
                    (harness-call 'memory/search "deploy*" (list :project dir)))))
    (should (= 2 (length (harness-call 'memory/search "deploy OR heroku" (list :project dir)))))
    (should (equal (list "The deployment runs on Fly.io.")
                   (harness-memory-test-texts
                    (harness-call 'memory/search "deploy -heroku" (list :project dir)))))
    (should-not (harness-call 'memory/search "zeppelin" (list :project dir)))
    (should (= 4 (length (harness-call 'memory/search "" (list :project dir)))))
    (should (= 4 (length (harness-call 'memory/list (list :project dir)))))
    ;; Kind limits the search too.
    (should (equal (list "The deployment runs on Fly.io.")
                   (harness-memory-test-texts
                    (harness-call 'memory/search "deploy" (list :project dir :kind "fact")))))
    (should-not (harness-call 'memory/search "imports" (list :project dir :kind "fact")))))

(ert-deftest harness-memory-search-without-fts-filters-in-elisp ()
  "When SQLite has no FTS5, search still finds words, phrases and exclusions."
  (harness-memory-test-with
    (harness-memory-test-add "Don't import inside function bodies." :kind "convention")
    (harness-memory-test-add "The deployment runs on Fly.io." :kind "fact")
    (harness-memory-test-add "Heroku was the old host." :kind "fact")
    ;; No full-text index here, as in a SQLite built without FTS5.
    (let ((harness-memory--fts-ok nil))
      (should (equal (list "Don't import inside function bodies.")
                     (harness-memory-test-texts
                      (harness-call 'memory/search "imports" (list :project dir)))))
      (should (equal (list "The deployment runs on Fly.io.")
                     (harness-memory-test-texts
                      (harness-call 'memory/search "deploy -heroku" (list :project dir)))))
      (should-not (harness-call 'memory/search "zeppelin" (list :project dir))))))

(ert-deftest harness-memory-prompt-section-is-stable-and-budgeted ()
  "The Memory section holds instructions first, then notes, and does not change between calls.
The project's memories and the user's are in it; another project's
are not.  Over the budget, notes are listed by id for `memory_get'."
  (harness-memory-test-with
    (should-not (harness-call 'memory/prompt (list :project dir :cwd dir)))
    (let* ((convention (harness-memory-test-add "Don't import inside function bodies."
                                                :kind "convention"))
           (preference (harness-call 'memory/add "Prefer short answers."
                                     (list :kind "preference" :scope "user")))
           (fact (harness-memory-test-add "The deploy target is Fly.io." :kind "fact"))
           (long (harness-memory-test-add
                  (concat "The release checklist: "
                          (mapconcat #'identity
                                     (make-list 24 "rotate the logs, drain the queue, check the dashboards")
                                     " "))
                  :kind "reference"))
           (reference (harness-call 'memory/add "The dashboard is at https://fly.io/apps."
                                    (list :kind "reference" :scope "user")))
           (session (list :id "s1" :project dir :cwd dir))
           (section (harness-call 'memory/prompt session)))
      (ignore convention preference fact long reference)
      (should (string-prefix-p "## Memory" section))
      (should (string-search "### Project instructions" section))
      (should (string-search "Don't import inside function bodies." section))
      (should (string-search "### User instructions" section))
      (should (string-search "Prefer short answers." section))
      (should (string-search "### Project notes" section))
      (should (string-search "The deploy target is Fly.io." section))
      (should (string-search "### User notes" section))
      (should (string-search "https://fly.io/apps" section))
      ;; The same function of the store twice, and the filter adds it once.
      (should (equal section (harness-call 'memory/prompt session)))
      (should (equal (concat "BASE\n\n" section "\n")
                     (harness-run-filter 'agent/system-prompt "BASE" session)))
      ;; Another project does not see the project's memories.
      (let ((elsewhere (harness-call 'memory/prompt (list :project other :cwd other))))
        (should-not (string-search "Don't import" elsewhere))
        (should (string-search "Prefer short answers." elsewhere)))
      ;; A small budget lists the notes by id instead of in full.
      (let ((harness-memory-prompt-budget 900))
        (let ((small (harness-call 'memory/prompt session)))
          (should (< (length small) 1200))
          (should (string-search (plist-get fact :id) small))
          (should (string-search "(index)" small))))
      ;; Off, it adds nothing.
      (let ((harness-memory-in-prompt nil))
        (should-not (harness-call 'memory/prompt session))))))

(ert-deftest harness-memory-tools-save-search-read-and-forget ()
  "The tools write, find, read and forget, and answer with ids."
  (harness-memory-test-with
    (let* ((ctx (list :session-id nil :cwd dir))
           (saved (harness-memory--tool-save
                   '(:text "Don't import inside function bodies." :kind "convention"
                     :scope "project")
                   ctx)))
      (should-not (plist-get saved :is-error))
      (should (string-search "Saved" (plist-get saved :content)))
      (let* ((found (harness-memory--tool-search '(:query "imports") ctx))
             (id (and (string-match "m-[a-z0-9]+" (plist-get found :content))
                      (match-string 0 (plist-get found :content)))))
        (should (string-search "convention" (plist-get found :content)))
        (should id)
        (let ((read (harness-memory--tool-get (list :id id) ctx)))
          (should (string-search "Don't import inside function bodies." (plist-get read :content))))
        (let ((deleted (harness-memory--tool-forget (list :id id) ctx)))
          (should-not (plist-get deleted :is-error))
          (should (string-search "Forgot" (plist-get deleted :content)))
          (should-not (harness-call 'memory/get id)))))
    ;; An empty save is refused as a tool error, not a signal.
    (let ((empty (harness-memory--tool-save '(:text "  " :kind "fact" :scope "project")
                                            (list :cwd dir))))
      (should (plist-get empty :is-error)))
    ;; The model is told which tools exist and what they are for.
    (should (harness-tool-get "memory_save"))
    (should (harness-tool-get "memory_search"))
    (should (harness-tool-get "memory_get"))
    (should (harness-tool-get "memory_forget"))
    (should (harness-tool-get "memory_consolidate"))
    (should (equal "Save memory" (harness-tools-label "memory_save")))))

(ert-deftest harness-memory-semantic-search-ranks-by-meaning ()
  "With an embedding model, semantic search embeds the memories and the query."
  (skip-unless (and (fboundp 'sqlite-available-p) (sqlite-available-p)))
  (harness-memory-test-with
    (harness-register-method
     'provider/embed
     (lambda (_model texts &optional _opts)
       (harness-resolved
        (list :vectors (mapcar (lambda (text)
                                 (let ((text (downcase text)))
                                   (list (if (string-match-p "deploy\\|shipping\\|fly" text) 1.0 0.0)
                                         (if (string-match-p "import" text) 1.0 0.0)
                                         (if (string-match-p "answer\\|prefer\\|response\\|style" text) 1.0 0.0)
                                         (if (string-match-p "terse" text) 1.0 0.0))))
                               texts)
              :usage (list :input 1)))))
    (let ((harness-memory-embedding-model "test:embed"))
      (harness-memory-test-add "The deployment runs on Fly.io." :kind "fact")
      (harness-memory-test-add "Don't import inside function bodies." :kind "convention")
      (harness-memory-test-add "Prefer short answers." :kind "preference" :scope "user")
      (let* ((deploy (car (harness-test-await
                           (harness-call 'memory/search "shipping"
                                         (list :mode "semantic" :project dir)))))
             (answers (car (harness-test-await
                            (harness-call 'memory/search "response style"
                                          (list :mode "semantic" :project dir))))))
        (should (equal "The deployment runs on Fly.io." (plist-get deploy :text)))
        (should (string-search "short" (plist-get answers :text)))
        ;; The vectors are kept, and a changed memory is embedded again.
        (let ((id (plist-get deploy :id)))
          (harness-call 'memory/update id :text "Prefer a terse answer.")
          (let ((now (car (harness-test-await
                           (harness-call 'memory/search "terse answer"
                                         (list :mode "semantic" :project dir))))))
            (should (equal id (plist-get now :id)))))))))

(ert-deftest harness-memory-consolidation-merges-only-valid-answers ()
  "A judge's answer merges the ids it names, and no answer changes nothing."
  (harness-memory-test-with
    (let* ((one (harness-memory-test-add "The deploy target is Fly.io." :kind "fact"))
           (two (harness-memory-test-add "Deploys go to Fly.io." :kind "fact"))
           (three (harness-memory-test-add "Use make deploy." :kind "fact")))
      (ignore three)
      ;; A fenced answer parses; an answer naming an unknown id does not validate.
      (should (harness-memory--parse-consolidation
               "```json\n{\"memories\": [], \"drop\": []}\n```"))
      (should (equal (list :add nil :remove nil)
                     (harness-memory--consolidation-plan
                      '(:memories nil :drop nil)
                      (harness-call 'memory/list (list :project dir)))))
      (should-not (harness-memory--consolidation-plan
                   (list :memories (list (list :text "New" :kind "fact" :replaces '("m-nope")))
                         :drop nil)
                   (harness-call 'memory/list (list :project dir))))
      (should-not (harness-memory--consolidation-plan
                   (list :memories (list (list :text "New" :kind "opinion" :replaces nil))
                         :drop nil)
                   (harness-call 'memory/list (list :project dir))))
      ;; A plan that joins the two facts.
      (require 'harness-judge)
      (cl-letf (((symbol-function 'harness-judge-ask)
                 (lambda (&rest _)
                   (harness-resolved
                    (list :value (list :memories
                                       (list (list :text "Deploy with make deploy, to Fly.io."
                                                   :kind "fact"
                                                   :replaces (list (plist-get one :id)
                                                                   (plist-get two :id))))
                                         :drop nil)
                          :text "" :lookups 0)))))
        (let ((result (harness-test-await
                       (harness-call 'memory/consolidate (list :scope "project" :project dir)))))
          (should (= 3 (plist-get result :changed)))
          (should (= 1 (plist-get result :added-count)))
          (should (= 2 (plist-get result :removed-count)))
          (should-not (harness-call 'memory/get (plist-get one :id)))
          (should-not (harness-call 'memory/get (plist-get two :id)))
          (should (cl-find "Deploy with make deploy, to Fly.io."
                           (harness-call 'memory/list (list :project dir))
                           :key (lambda (m) (plist-get m :text)) :test #'equal))))
      ;; Fewer than two memories is no work.
      (harness-call 'memory/delete (car (harness-memory-test-ids
                                         (harness-call 'memory/list (list :project dir)))))
      (harness-call 'memory/delete (car (harness-memory-test-ids
                                         (harness-call 'memory/list (list :project dir)))))
      (let ((result (harness-test-await
                     (harness-call 'memory/consolidate (list :scope "project" :project dir)))))
        (should (= 0 (plist-get result :changed)))))))

(ert-deftest harness-memory-redaction-takes-the-secret-out ()
  "A redaction replaces the secret in the memory and in the database's pages."
  (harness-memory-test-with
    (let* ((secret (harness-redaction-secret "s3cr3t-value" "test"))
           (memory (harness-memory-test-add "The API key is s3cr3t-value." :kind "fact")))
      (let ((dry (harness-call 'memory/redact (list secret) nil t)))
        (should (= 1 (plist-get dry :count)))
        (should (string-search "s3cr3t-value"
                               (plist-get (harness-call 'memory/get (plist-get memory :id)) :text))))
      (let ((done (harness-call 'memory/redact (list secret) nil nil)))
        (should (= 1 (plist-get done :count)))
        (let ((text (plist-get (harness-call 'memory/get (plist-get memory :id)) :text)))
          (should-not (string-search "s3cr3t-value" text))
          (should (string-search "redacted" text))))
      ;; Neither the database nor its log keeps the old text in a page.
      (dolist (name '("memory.db" "memory.db-wal"))
        (let ((file (expand-file-name name harness-state-directory)))
          (when (file-exists-p file)
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally file)
              (goto-char (point-min))
              (should-not (search-forward "s3cr3t-value" nil t)))))))))

(ert-deftest harness-memory-is-on-the-bus ()
  "The methods are callable over ACP and the change event reaches the UI."
  (harness-memory-test-with
    (harness-test-load-module 'acp)
    (dolist (method '("memory/add" "memory/list" "memory/search" "memory/get"
                      "memory/update" "memory/delete" "memory/consolidate" "memory/redact"))
      (should (harness-acp--extension-allowed-p method)))
    (should-not (harness-acp--extension-allowed-p "private/thing"))
    (should (memq 'memory/changed harness-acp--forwarded-events))
    (let ((events nil))
      (harness-on 'memory/changed (lambda (&rest args) (push args events)))
      (harness-memory-test-add "A lasting preference." :kind "preference")
      (should (= 1 (length events)))
      (should (eq 'added (cadr (car events)))))))

(provide 'harness-memory-test)
;;; harness-memory-test.el ends here
