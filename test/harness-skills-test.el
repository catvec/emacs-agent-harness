;;; harness-skills-test.el --- Tests for the skills module  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-skills-directories)
(defvar harness-skills-prompt-limit)
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
        (should (equal "skill_load x" (harness-tool-title "skill_load" '(:name "x"))))))))

(ert-deftest harness-skills-system-prompt-filter ()
  (harness-skills-test-with-skills
    (let ((prompt (harness-run-filter 'agent/system-prompt "Base prompt." (list :cwd cwd))))
      (should (string-prefix-p "Base prompt.\n\n## Available skills" prompt))
      (should (string-match-p "^- code-review — Review a diff" prompt))
      (should (string-match-p "^- commit — Write a conventional" prompt))
      (should (string-match-p "skill_load" prompt))
      (should-not (string-match-p "more; use skill_search" prompt)))
    ;; The limit truncates the index and says so.
    (let* ((harness-skills-prompt-limit 2)
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

(provide 'harness-skills-test)
;;; harness-skills-test.el ends here
