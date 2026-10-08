;;; harness-skills-test.el --- Tests for the skills module  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-skills-directories)
(defvar harness-skills--prompt-limit)
(defvar harness-skills--cache)

(defun harness-skills-test--write-skill (base name content)
  "Create skill NAME under BASE with CONTENT in its SKILL.md; return its dir."
  (let ((dir (file-name-as-directory (expand-file-name name base))))
    (make-directory dir t)
    (with-temp-file (expand-file-name "SKILL.md" dir) (insert content))
    dir))

(defmacro harness-skills-test-with-skills (&rest body)
  "Run BODY with a global and a project skill directory populated.
Binds `global' and `project' to the directories and `cwd' to a project
working directory whose .harness/skills is the project directory."
  (declare (indent 0))
  `(progn
     (harness-test-reset-bus)
     (harness-test-load-module 'tools)
     (harness-test-load-module 'skills)
     (harness-skills-test--with-skills-1
      (lambda (global project cwd) (ignore global project cwd) ,@body))))

(defun harness-skills-test--with-skills-1 (body)
  "Populate temporary skill directories and call BODY with them.
BODY receives the global directory, the project directory and the cwd."
  (let* ((global (harness-test-temp-dir))
          (cwd (harness-test-temp-dir))
          (project (file-name-as-directory (expand-file-name ".harness/skills" cwd)))
          (harness-skills-directories (list global #'harness-skills-project-directories)))
     (make-directory project t)
     (harness-skills-test--write-skill
      global "commit"
      "---\nname: commit\ndescription: Write a conventional commit message from the staged diff.\n---\n# Commit\n\nRun `git diff --cached` first.\n")
     (harness-skills-test--write-skill
      global "deploy-notes"
      "# Deploy notes\n\nSummarise what a deploy changes for the release channel.\n\nMore detail here.\n")
     (harness-skills-test--write-skill
      global "shadowed"
      "---\ndescription: global version\n---\nglobal body\n")
     (harness-skills-test--write-skill
      project "shadowed"
      "---\nname: shadowed\ndescription: >\n  project version\n  of the skill\n---\nproject body\n")
     (harness-skills-test--write-skill
      project "review"
      "---\nname: \"code-review\"\ndescription: 'Review a diff for correctness bugs.'\n---\nLook at the diff.\n\n```sh\ngit diff\n```\n")
     (make-directory (expand-file-name "review/templates" project) t)
     (with-temp-file (expand-file-name "review/templates/checklist.md" project) (insert "- [ ] tests\n"))
     (with-temp-file (expand-file-name "review/helper.sh" project) (insert "echo hi\n"))
     (harness-call 'skills/refresh)
     (unwind-protect (funcall body global project cwd)
       (ignore-errors (delete-directory global t))
       (ignore-errors (delete-directory cwd t)))))

(ert-deftest harness-skills-list-with-and-without-front-matter ()
  (harness-skills-test-with-skills
    (let* ((skills (harness-call 'skills/list cwd))
           (names (mapcar (lambda (s) (plist-get s :name)) skills))
           (commit (cl-find "commit" skills :key (lambda (s) (plist-get s :name)) :test #'string=))
           (notes (cl-find "deploy-notes" skills :key (lambda (s) (plist-get s :name)) :test #'string=))
           (review (cl-find "code-review" skills :key (lambda (s) (plist-get s :name)) :test #'string=))
           (shadowed (cl-find "shadowed" skills :key (lambda (s) (plist-get s :name)) :test #'string=)))
      ;; Project skills first, then global; the duplicate name appears once.
      (should (equal '("code-review" "shadowed" "commit" "deploy-notes") names))
      (should (equal "Write a conventional commit message from the staged diff."
                     (plist-get commit :description)))
      (should (eq 'global (plist-get commit :source)))
      (should (equal (file-name-as-directory (expand-file-name "commit" global)) (plist-get commit :path)))
      ;; No front matter: directory name and first paragraph after the heading.
      (should (equal "Summarise what a deploy changes for the release channel."
                     (plist-get notes :description)))
      ;; Quoted scalars are unquoted; the project copy shadows the global one.
      (should (equal "Review a diff for correctness bugs." (plist-get review :description)))
      (should (eq 'project (plist-get review :source)))
      (should (equal "project version of the skill" (plist-get shadowed :description)))
      (should (eq 'project (plist-get shadowed :source))))
    ;; Without a cwd only global skills are visible.
    (should (equal '("commit" "deploy-notes" "shadowed")
                   (mapcar (lambda (s) (plist-get s :name)) (harness-call 'skills/list))))))

(ert-deftest harness-skills-cache-tracks-mtime ()
  (harness-skills-test-with-skills
    (should (= 3 (length (harness-call 'skills/list))))
    ;; A second call is served from the cache (same list object).
    (let ((cache-entry (gethash global harness-skills--cache)))
      (harness-call 'skills/list)
      (should (eq cache-entry (gethash global harness-skills--cache))))
    ;; Editing a SKILL.md with a newer mtime invalidates the entry.
    (let ((file (expand-file-name "commit/SKILL.md" global)))
      (with-temp-file file (insert "---\ndescription: edited\n---\nbody\n"))
      (set-file-times file (time-add (current-time) 5))
      (should (equal "edited"
                     (plist-get (cl-find "commit" (harness-call 'skills/list)
                                         :key (lambda (s) (plist-get s :name)) :test #'string=)
                                :description))))
    ;; Adding a skill directory is noticed too.
    (harness-skills-test--write-skill global "brand-new" "Fresh skill.\n")
    (set-file-times global (time-add (current-time) 5))
    (should (member "brand-new" (mapcar (lambda (s) (plist-get s :name)) (harness-call 'skills/list))))
    (should (harness-call 'skills/refresh))
    (should (= 0 (hash-table-count harness-skills--cache)))))

(ert-deftest harness-skills-search-ranks-names-first ()
  (harness-skills-test-with-skills
    (let ((names (mapcar (lambda (s) (plist-get s :name)) (harness-call 'skills/search "review" cwd))))
      (should (equal "code-review" (car names))))
    (should (equal '("commit") (mapcar (lambda (s) (plist-get s :name))
                                       (harness-call 'skills/search "conventional" cwd))))
    (should-not (harness-call 'skills/search "zzzzqq" cwd))
    (should (= 4 (length (harness-call 'skills/search "" cwd))))
    (should (= 4 (length (harness-call 'skills/search nil cwd))))))

(ert-deftest harness-skills-load-returns-content-and-files ()
  (harness-skills-test-with-skills
    (let ((review (harness-call 'skills/load "code-review" cwd)))
      (should (equal "code-review" (plist-get review :name)))
      (should (string-prefix-p "Look at the diff." (plist-get review :content)))
      (should-not (string-match-p "^---" (plist-get review :content)))
      (should (equal '("helper.sh" "templates/checklist.md") (plist-get review :files)))
      (should (equal (file-name-as-directory (expand-file-name "review" project)) (plist-get review :path))))
    ;; Loading by directory name works when it differs from the declared name.
    (should (equal "code-review" (plist-get (harness-call 'skills/load "review" cwd) :name)))
    (should (equal "project body\n" (plist-get (harness-call 'skills/load "shadowed" cwd) :content)))
    (should (equal "global body\n" (plist-get (harness-call 'skills/load "shadowed") :content)))
    (should-not (plist-get (harness-call 'skills/load "commit") :files))
    (should-error (harness-call 'skills/load "nope" cwd) :type 'harness-error)))

(ert-deftest harness-skills-tools-execute ()
  (harness-skills-test-with-skills
    (harness-test-with-temp-state
      (harness-add-filter 'permission/decide
                          (lambda (_v next &rest _) (funcall next (list :behavior 'allow))))
      (let ((default-directory cwd))
        (should (member "skill_search" (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list))))
        (let ((r (harness-test-await (harness-call 'tools/execute nil '(:id "c1" :name "skill_search" :input (:query "commit"))))))
          (should-not (plist-get r :is-error))
          (should (string-match-p "^- commit — Write a conventional" (plist-get r :content)))
          (should (string-match-p "\\[global\\]" (plist-get r :content))))
        (let ((r (harness-test-await (harness-call 'tools/execute nil '(:id "c2" :name "skill_search" :input (:query ""))))))
          (should (string-match-p "4 skills" (plist-get r :content))))
        (let ((r (harness-test-await (harness-call 'tools/execute nil '(:id "c3" :name "skill_search" :input (:query "zzqqzz"))))))
          (should-not (plist-get r :is-error))
          (should (string-match-p "No skills match" (plist-get r :content))))
        (let ((r (harness-test-await (harness-call 'tools/execute nil '(:id "c4" :name "skill_load" :input (:name "code-review"))))))
          (should-not (plist-get r :is-error))
          (should (string-match-p "# Skill: code-review" (plist-get r :content)))
          (should (string-match-p "Look at the diff." (plist-get r :content)))
          (should (string-match-p "- templates/checklist.md" (plist-get r :content))))
        (let ((r (harness-test-await (harness-call 'tools/execute nil '(:id "c5" :name "skill_load" :input (:name "revew"))))))
          (should (plist-get r :is-error))
          (should (string-match-p "Did you mean: code-review" (plist-get r :content))))
        (should (equal "Load skill: x" (harness-tool-title "skill_load" '(:name "x"))))))))

(ert-deftest harness-skills-system-prompt-filter ()
  (harness-skills-test-with-skills
    (let ((prompt (harness-run-filter 'agent/system-prompt "Base prompt." (list :cwd cwd))))
      (should (string-prefix-p "Base prompt.\n\n## Available skills" prompt))
      (should (string-match-p "^- code-review — Review a diff" prompt))
      (should (string-match-p "^- commit — Write a conventional" prompt))
      (should (string-match-p "skill_load" prompt))
      (should-not (string-match-p "more; use skill_search" prompt)))
    ;; The limit truncates the index and says so.
    (let* ((harness-skills--prompt-limit 2)
           (prompt (harness-run-filter 'agent/system-prompt "" (list :cwd cwd))))
      (should (string-prefix-p "## Available skills" prompt))
      (should (string-match-p "(2 more; use skill_search)" prompt)))
    ;; No skills anywhere: the prompt is untouched.
    (let ((harness-skills-directories (list (harness-test-temp-dir))))
      (should (equal "Base." (harness-run-filter 'agent/system-prompt "Base." (list :cwd cwd)))))))

(ert-deftest harness-skills-expand-references ()
  (harness-skills-test-with-skills
    (let* ((text "/commit please, and keep it short\nAlso see @skill:code-review here.\n/usr/bin is a path\n/nope is unknown\n@skill:commit again")
           (result (harness-skills-expand-references text cwd))
           (out (car result))
           (attached (cdr result)))
      (should (equal '("commit" "code-review") (mapcar (lambda (s) (plist-get s :name)) attached)))
      ;; The reference line is kept and followed by a fenced block.
      (should (string-prefix-p "/commit please, and keep it short\n```markdown skill:commit\n# Commit\n\nRun `git diff --cached` first.\n```\nAlso see @skill:code-review here.\n" out))
      ;; The review body contains a fence, so a longer one wraps it.
      (should (string-match-p "\n````markdown skill:code-review\nLook at the diff\\.\n\n```sh\ngit diff\n```\n````\n" out))
      ;; Paths and unknown names are untouched; repeats are not re-attached.
      (should (string-match-p "^/usr/bin is a path\n/nope is unknown\n@skill:commit again\\'" out))
      (should (= 1 (cl-count "markdown skill:commit" (split-string out "\n") :test #'string-match-p)))
      ;; No references: text is returned unchanged.
      (should (equal (cons "plain text" nil) (harness-skills-expand-references "plain text" cwd))))))

;;;; Where skills live

(defvar harness-skills-plugins-directory)
(defvar harness-skills-project-subdirectories)

(ert-deftest harness-skills-default-locations-are-the-documented-ones ()
  "Out of the box the skills of Claude Code, the harness, the Agent
Skills convention (read by Codex and Copilot CLI) and Copilot CLI are
found, globally and in the project, and so are the skills of Claude
Code's plugins."
  (harness-test-reset-bus)
  (harness-test-load-module 'tools)
  (harness-test-load-module 'skills)
  (let ((defaults (eval (car (get 'harness-skills-directories 'standard-value)) t)))
    (dolist (dir '("~/.claude/skills" "~/.config/harness/skills" "~/.agents/skills" "~/.copilot/skills"))
      (should (member dir defaults)))
    (should (memq 'harness-skills-project-directories defaults))
    (should (memq 'harness-skills-plugin-directories defaults)))
  (should (equal '(".claude/skills" ".harness/skills" ".agents/skills" ".github/skills")
                 harness-skills-project-subdirectories))
  (let* ((cwd (harness-test-temp-dir))
         (sub (file-name-as-directory (expand-file-name "sub" cwd))))
    (make-directory sub)
    (harness-register-method 'project/root (lambda (_dir) cwd))
    ;; Under the working directory, then under its project.
    (should (equal (append (mapcar (lambda (rel) (expand-file-name rel sub)) harness-skills-project-subdirectories)
                           (mapcar (lambda (rel) (expand-file-name rel cwd)) harness-skills-project-subdirectories))
                   (harness-skills-project-directories sub)))
    (should-not (harness-skills-project-directories nil))))

(defun harness-skills-test--plugin (root market plugin version &rest skills)
  "Install VERSION of PLUGIN from MARKET under the plugins ROOT with SKILLS.
Return the version's directory."
  (let ((dir (file-name-as-directory (expand-file-name (format "cache/%s/%s/%s" market plugin version) root))))
    (make-directory dir t)
    (dolist (skill skills)
      (harness-skills-test--write-skill (expand-file-name "skills" dir) skill
                                        (format "---\ndescription: %s from %s %s\n---\nbody\n" skill plugin version)))
    dir))

(ert-deftest harness-skills-plugin-skills-are-found-where-claude-code-installs-them ()
  "The skills of Claude Code's plugins are in cache/MARKETPLACE/PLUGIN/VERSION/skills
under its plugins root: the newest version first, none of a version it
replaced (.orphaned_at), each belonging to its marketplace."
  (harness-test-reset-bus)
  (harness-test-load-module 'tools)
  (harness-test-load-module 'skills)
  (let* ((root (harness-test-temp-dir))
         (old (harness-skills-test--plugin root "market" "tools" "1.0.0" "lint"))
         (new (harness-skills-test--plugin root "market" "tools" "1.1.0" "lint" "fmt"))
         (gone (harness-skills-test--plugin root "market" "tools" "0.9.0" "lint"))
         (other (harness-skills-test--plugin root "other" "notes" "abc123" "notes"))
         (harness-skills-plugins-directory root)
         (process-environment (cons "CLAUDE_CODE_PLUGIN_CACHE_DIR" process-environment)))
    ;; A plugin without skills has no directory to read.
    (make-directory (expand-file-name "cache/market/hooks-only/1.0.0/hooks" root) t)
    (with-temp-file (expand-file-name ".orphaned_at" gone) (insert "1760000000000\n"))
    (set-file-times old (time-subtract (current-time) 3600))
    (set-file-times new (current-time))
    (let ((market (file-name-as-directory (expand-file-name "cache/market" root))))
      (should (equal (list (list :dir (expand-file-name "skills" new) :source 'plugin :within market)
                           (list :dir (expand-file-name "skills" old) :source 'plugin :within market)
                           (list :dir (expand-file-name "skills" other) :source 'plugin
                                 :within (file-name-as-directory (expand-file-name "cache/other" root))))
                     (harness-skills-plugin-directories nil))))
    (let ((harness-skills-directories (list #'harness-skills-plugin-directories)))
      (harness-call 'skills/refresh)
      ;; The newest version's copy of a skill is the one loaded.
      (should (equal '("fmt" "lint" "notes") (mapcar (lambda (s) (plist-get s :name)) (harness-call 'skills/list))))
      (should (equal "lint from tools 1.1.0" (plist-get (harness-call 'skills/load "lint") :description)))
      (should (eq 'plugin (plist-get (harness-call 'skills/load "lint") :source))))
    ;; Without the option, Claude Code's own setting, then its default.
    (let ((harness-skills-plugins-directory nil))
      (let ((process-environment (cons (concat "CLAUDE_CODE_PLUGIN_CACHE_DIR=" root) process-environment)))
        (should (equal root (harness-skills--plugins-root))))
      (let* ((home (harness-test-temp-dir))
             (process-environment (append (list (concat "HOME=" (directory-file-name home))
                                                "CLAUDE_CODE_PLUGIN_CACHE_DIR")
                                          process-environment)))
        (should (equal (expand-file-name ".claude/plugins/" home) (harness-skills--plugins-root)))
        (should-not (harness-skills-plugin-directories nil))))))

(ert-deftest harness-skills-sources-come-in-search-order ()
  "Project skills come first, then the global ones, then the plugins',
whatever the order of `harness-skills-directories': a skill of the user
shadows a plugin's skill of the same name."
  (harness-test-reset-bus)
  (harness-test-load-module 'tools)
  (harness-test-load-module 'skills)
  (let* ((global (harness-test-temp-dir))
         (cwd (harness-test-temp-dir))
         (plugins (harness-test-temp-dir))
         (project (file-name-as-directory (expand-file-name ".agents/skills" cwd)))
         (version (harness-skills-test--plugin plugins "market" "tools" "1.0.0" "commit" "only-plugin"))
         (harness-skills-plugins-directory plugins)
         (harness-skills-directories (list #'harness-skills-plugin-directories global
                                           #'harness-skills-project-directories)))
    (harness-skills-test--write-skill global "commit" "---\ndescription: the user's own\n---\nbody\n")
    (harness-skills-test--write-skill project "review" "Review.\n")
    (harness-call 'skills/refresh)
    (should (equal (list (cons project 'project) (cons global 'global)
                         (cons (file-name-as-directory (expand-file-name "skills" version)) 'plugin))
                   (harness-skills--directories cwd)))
    (should (equal '(("review" . project) ("commit" . global) ("only-plugin" . plugin))
                   (mapcar (lambda (s) (cons (plist-get s :name) (plist-get s :source)))
                           (harness-call 'skills/list cwd))))
    (should (equal "the user's own" (plist-get (harness-call 'skills/load "commit" cwd) :description)))))

;;;; What may be read

(defun harness-skills-test--dirs (cwd)
  "Return `skills/directories' for CWD as (DIR SOURCE CONTAINED) lists."
  (mapcar (lambda (e) (list (plist-get e :dir) (plist-get e :source) (plist-get e :contained)))
          (harness-call 'skills/directories cwd)))

(ert-deftest harness-skills-directories-say-what-may-be-read ()
  "`skills/directories' lists every directory discovery reads, with the
skills linked in from elsewhere, and says which hold skills and nothing
else: a directory a project or a plugin provides only while it stays
inside it, and never one that is or holds the home directory."
  (harness-test-reset-bus)
  (harness-test-load-module 'tools)
  (harness-test-load-module 'skills)
  (let* ((home (harness-test-temp-dir))
         (process-environment (cons (concat "HOME=" (directory-file-name home)) process-environment))
         (global (file-name-as-directory (expand-file-name ".claude/skills" home)))
         (dotfiles (file-name-as-directory (expand-file-name "dotfiles/skills" home)))
         (cwd (harness-test-temp-dir))
         (outside (harness-test-temp-dir))
         (plugins (harness-test-temp-dir))
         (tools (harness-skills-test--plugin plugins "market" "tools" "1.0.0" "lint"))
         (base (harness-skills-test--plugin plugins "market" "base" "1.0.0" "shared"))
         (harness-skills-plugins-directory plugins)
         (harness-skills-directories (list "~/.claude/skills" "~/.config/harness/skills" home
                                           #'harness-skills-project-directories
                                           #'harness-skills-plugin-directories)))
    (harness-register-method 'project/root (lambda (_dir) cwd))
    ;; The user's skills: one of their own, one linked in from their
    ;; dotfiles, and one link to their whole home.
    (harness-skills-test--write-skill global "commit" "Commit.\n")
    (harness-skills-test--write-skill dotfiles "linked" "Linked.\n")
    (make-symbolic-link (directory-file-name (expand-file-name "linked" dotfiles)) (expand-file-name "linked" global))
    (with-temp-file (expand-file-name "SKILL.md" home) (insert "Home.\n"))
    (make-symbolic-link (directory-file-name home) (expand-file-name "everything" global))
    ;; The project's: its own, one of its skills linked out of it, and
    ;; a whole skills directory linked out of it.
    (harness-skills-test--write-skill (expand-file-name ".claude/skills" cwd) "review" "Review.\n")
    (harness-skills-test--write-skill (expand-file-name "vendor" cwd) "vendored" "Vendored.\n")
    (make-symbolic-link "../../vendor/vendored" (expand-file-name ".claude/skills/vendored" cwd))
    (harness-skills-test--write-skill outside "stolen" "Stolen.\n")
    (make-symbolic-link (directory-file-name (expand-file-name "stolen" outside))
                        (expand-file-name ".claude/skills/stolen" cwd))
    (make-directory (expand-file-name ".agents" cwd))
    (make-symbolic-link (directory-file-name outside) (expand-file-name ".agents/skills" cwd))
    ;; A plugin's skills linking to another plugin of its marketplace,
    ;; and out of it.
    (make-symbolic-link (directory-file-name (expand-file-name "skills/shared" base))
                        (expand-file-name "skills/shared" tools))
    (harness-skills-test--write-skill outside "exfil" "Exfil.\n")
    (make-symbolic-link (directory-file-name (expand-file-name "exfil" outside)) (expand-file-name "skills/exfil" tools))
    (should (equal
             (list
              (list (expand-file-name ".claude/skills/" cwd) 'project t)
              (list (expand-file-name ".claude/skills/stolen/" cwd) 'project nil)
              (list (expand-file-name ".claude/skills/vendored/" cwd) 'project t)
              (list (expand-file-name ".agents/skills/" cwd) 'project nil)
              (list global 'global t)
              (list (expand-file-name "everything/" global) 'global nil)
              (list (expand-file-name "linked/" global) 'global t)
              (list home 'global nil)
              (list (expand-file-name "skills/" base) 'plugin t)
              (list (expand-file-name "skills/" tools) 'plugin t)
              (list (expand-file-name "skills/exfil/" tools) 'plugin nil)
              (list (expand-file-name "skills/shared/" tools) 'plugin t))
             (harness-skills-test--dirs cwd)))
    ;; Without a cwd, no project.
    (should-not (cl-find 'project (harness-skills-test--dirs nil) :key #'cadr))))

(ert-deftest harness-skills-load-serves-supporting-files ()
  "skill_load with file returns one of the skill's supporting files, and
nothing outside the skill or outside what may be read."
  (harness-skills-test-with-skills
    (harness-test-with-temp-state
      (harness-add-filter 'permission/decide
                          (lambda (_v next &rest _) (funcall next (list :behavior 'allow))))
      (let* ((default-directory cwd)
             (review (expand-file-name "review/" project))
             (secret (expand-file-name "secret.txt" (harness-test-temp-dir)))
             (load (lambda (&rest input)
                     (harness-test-await (harness-call 'tools/execute nil (list :id (harness-short-id) :name "skill_load"
                                                                                :input input))))))
        (with-temp-file secret (insert "s3cret\n"))
        (make-symbolic-link secret (expand-file-name "leak.txt" review))
        (with-temp-file (expand-file-name "blob.bin" review) (set-buffer-multibyte nil) (insert "\0\1\2"))
        (let ((r (funcall load :name "code-review" :file "templates/checklist.md")))
          (should-not (plist-get r :is-error))
          (should (equal (format "# Skill: code-review, file templates/checklist.md\nPath: %stemplates/checklist.md\n\n- [ ] tests\n"
                                 review)
                         (plist-get r :content))))
        ;; The loaded skill says so.
        (should (string-search "(skill_load with file set to one returns it)"
                               (plist-get (funcall load :name "code-review") :content)))
        (pcase-dolist (`(,file ,why) '(("../shadowed/SKILL.md" "is not inside the directory of the skill code-review")
                                       ("leak.txt" "is not inside the directory of the skill code-review")
                                       ("nope.md" "has no readable file nope.md")
                                       ("templates" "has no readable file templates")
                                       ("blob.bin" "is a binary file")))
          (ert-info (file)
            (let ((r (funcall load :name "code-review" :file file)))
              (should (plist-get r :is-error))
              (should (string-search why (plist-get r :content)))
              (should-not (string-search "s3cret" (plist-get r :content)))
              ;; The agent learns which files there are.
              (should (string-search "Its supporting files: blob.bin, helper.sh, leak.txt, templates/checklist.md."
                                     (plist-get r :content))))))
        (should (string-search "It has no supporting files."
                               (plist-get (funcall load :name "commit" :file "x.md") :content)))
        ;; A blank file loads the skill.
        (should (string-search "Look at the diff." (plist-get (funcall load :name "code-review" :file " ") :content)))
        (should (equal "Load skill: code-review: helper.sh"
                       (harness-tool-title "skill_load" '(:name "code-review" :file "helper.sh"))))
        (should (plist-get (plist-get (plist-get (harness-tool-spec (harness-tool-get "skill_load")) :schema) :properties)
                           :file))))))

(ert-deftest harness-skills-load-serves-no-file-a-project-links-in ()
  "A skill a project links in from outside it is loaded, but its files
are not served: skill_load reads nothing the file tools could not read
without approval."
  (harness-skills-test-with-skills
    (let* ((outside (harness-test-temp-dir))
           (skill (harness-skills-test--write-skill outside "foreign" "Foreign.\n")))
      (with-temp-file (expand-file-name "notes.md" skill) (insert "notes\n"))
      (make-symbolic-link (directory-file-name skill) (expand-file-name "foreign" project))
      (harness-call 'skills/refresh)
      (should (equal "Foreign.\n" (plist-get (harness-call 'skills/load "foreign" cwd) :content)))
      (let ((r (harness-skills--tool-load '(:name "foreign" :file "notes.md") (list :cwd cwd))))
        (should (plist-get r :is-error))
        (should (string-search "The files of the skill foreign are not served" (plist-get r :content))))
      ;; One the user links into their own skills is theirs.
      (make-symbolic-link (directory-file-name skill) (expand-file-name "theirs" global))
      (harness-call 'skills/refresh)
      (let ((r (harness-skills--tool-load '(:name "theirs" :file "notes.md") (list :cwd cwd))))
        (should-not (plist-get r :is-error))
        (should (string-search "\n\nnotes\n" (plist-get r :content)))))))

(provide 'harness-skills-test)
;;; harness-skills-test.el ends here
