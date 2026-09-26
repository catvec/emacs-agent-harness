;;; harness-skills.el --- Skill discovery and loading -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; Skills are folders or files of reusable instructions.  They are looked
;; up in the harness configuration directory and in the project
;; (`.harness/skills'), so a repository can ship skills with its code.
;;
;; A skill is either `<dir>/<name>/SKILL.md' or `<dir>/<name>.md'.  An
;; optional front matter block supplies the name and description:
;;
;;   ---
;;   name: release-checklist
;;   description: How to cut a release
;;   ---
;;   ...body...
;;
;; Two tools expose skills to the model: `skills' searches, `skill' loads
;; one.  The same data is available over ACP as `_harness/skills/*' so the
;; UI can attach a skill to a user message with `#name'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xdg)
(require 'harness-core)
(require 'harness-tools)

(defgroup harness-skills nil
  "Reusable instruction skills."
  :group 'harness)

(defcustom harness-skills-directories
  (list (expand-file-name "harness/skills" (xdg-config-home)))
  "Global directories searched for skills."
  :type '(repeat directory))

(defcustom harness-skills-project-directory ".harness/skills"
  "Project-relative directory searched for skills."
  :type 'string)

(defun harness-skills-directories-for (cwd)
  "Return the skill directories that apply in CWD, least specific first."
  (let* ((directory (or cwd default-directory))
         (root (harness-config-project-root directory)))
    (append harness-skills-directories
            (list (expand-file-name harness-skills-project-directory root)))))

(defun harness-skills--parse-front-matter (text)
  "Split TEXT into (FRONT-MATTER . BODY), both strings."
  (if (not (string-prefix-p "---\n" text))
      (cons "" text)
    (let ((end (string-match "\n---\n" text)))
      (cond
       (end (cons (substring text 4 end) (substring text (match-end 0))))
       ((string-match "\n---\\'" text)
        (cons (substring text 4 (match-beginning 0)) ""))
       (t (cons "" text))))))

(defun harness-skills--front-matter-field (front-matter field)
  "Return FIELD from FRONT-MATTER, or nil."
  (when (string-match (format "^%s:[ \t]*\\(.*\\)$" (regexp-quote field))
                      front-matter)
    (string-trim (match-string 1 front-matter))))

(defun harness-skills-parse (path)
  "Parse the skill at PATH into a plist, or nil."
  (when (file-readable-p path)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents path)
          (pcase-let* ((`(,front-matter . ,body) (harness-skills--parse-front-matter
                                                  (buffer-string)))
                       (fallback (file-name-base (directory-file-name path)))
                       (name (or (harness-skills--front-matter-field front-matter "name")
                                 fallback))
                       (description (or (harness-skills--front-matter-field front-matter "description")
                                        (car (seq-filter
                                              (lambda (line)
                                                (not (string-empty-p (string-trim line))))
                                              (split-string (string-trim body) "\n"))))))
            (list :name name
                  :description (string-trim (or description ""))
                  :path (expand-file-name path)
                  :content (string-trim body))))
      (error (harness-log "cannot read skill %s: %S" path err) nil))))

(defun harness-skills-list (&optional cwd)
  "Return all skills visible from CWD, most specific definitions last.
Later definitions shadow earlier ones with the same name."
  (let ((skills (make-hash-table :test #'equal))
        (order nil))
    (dolist (directory (harness-skills-directories-for cwd))
      (when (file-directory-p directory)
        (dolist (entry (directory-files directory t "\\`[^.]" nil))
          (let ((skill (cond
                        ((and (file-directory-p entry)
                              (file-readable-p (expand-file-name "SKILL.md" entry)))
                         (harness-skills-parse (expand-file-name "SKILL.md" entry)))
                        ((and (file-regular-p entry)
                              (string-suffix-p ".md" entry))
                         (harness-skills-parse entry)))))
            (when skill
              (unless (gethash (plist-get skill :name) skills)
                (push (plist-get skill :name) order))
              (puthash (plist-get skill :name) skill skills))))))
    (mapcar (lambda (name) (gethash name skills)) (nreverse order))))

(defun harness-skills-load (name &optional cwd)
  "Return the skill called NAME visible from CWD, or nil."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (skill (harness-skills-list cwd))
      (puthash (plist-get skill :name) skill table))
    (gethash name table)))

(defun harness-skills--format (skill)
  "One-line description of SKILL."
  (format "%-28s %s"
          (plist-get skill :name)
          (or (plist-get skill :description) "")))

(defun harness-skills-tool-list (arguments context)
  "Tool handler: search available skills."
  (let* ((query (plist-get arguments :query))
         (skills (harness-skills-list (harness-tool-context-cwd context)))
         (matching (if (and query (not (string-empty-p query)))
                       (seq-filter (lambda (skill)
                                     (string-match-p (regexp-quote query)
                                                     (concat (plist-get skill :name) " "
                                                             (or (plist-get skill :description) ""))))
                                   skills)
                     skills)))
    (if matching
        (concat (mapconcat #'harness-skills--format matching "\n")
                (when (and query (not (string-empty-p query)))
                  (format "\n\n(use the `skill' tool to load one)")))
      (if skills
          (format "No skill matches %s. Available: %s"
                  query (string-join (mapcar (lambda (skill) (plist-get skill :name)) skills)
                                     ", "))
        "No skills are installed."))))

(defun harness-skills-tool-load (arguments context)
  "Tool handler: load a skill's contents."
  (let* ((name (plist-get arguments :name))
         (skill (harness-skills-load name (harness-tool-context-cwd context))))
    (if (null skill)
        (harness-tool-error-result
         (format "No skill named %s. %s" name
                 (harness-skills-tool-list '(:query "") context)))
      (format "Skill %s: %s\n\n%s"
              (plist-get skill :name)
              (or (plist-get skill :description) "")
              (plist-get skill :content)))))

;;; Service

(defun harness-skills-service-list (&rest args)
  "Service: list skills."
  (vconcat
   (mapcar (lambda (skill)
             (harness-plist-omit-nil
              (list :name (plist-get skill :name)
                    :description (plist-get skill :description)
                    :path (plist-get skill :path))))
           (harness-skills-list (plist-get args :cwd)))))

(defun harness-skills-service-load (&rest args)
  "Service: load one skill."
  (or (harness-skills-load (plist-get args :name) (plist-get args :cwd))
      (signal 'harness-user-error (list (format "No skill named %s" (plist-get args :name))))))

(defun harness-skills-setup ()
  "Set up the skills module."
  (harness-service-register
   "skill"
   :module 'harness-skills
   :doc "Skill discovery and loading."
   :methods '((list . harness-skills-service-list)
              (load . harness-skills-service-load)))
  (harness-tool-register
   "skills"
   :description "Search available skills; loads none. Use `skill' to load one."
   :schema '(:type "object"
             :properties (:query (:type "string" :description "Words to match name or description."))
             :required [])
   :kind 'search
   :read-only t
   :handler #'harness-skills-tool-list)
  (harness-tool-register
   "skill"
   :description "Load a skill's instructions by name and follow them."
   :schema '(:type "object"
             :properties (:name (:type "string"))
             :required ["name"])
   :kind 'read
   :read-only t
   :handler #'harness-skills-tool-load))

(defun harness-skills-teardown ()
  "Tear down the skills module."
  (harness-tool-unregister-module 'harness-skills))

(harness-module-define 'harness-skills
  :version harness-version
  :description "Skill discovery, loading and reference support."
  :requires '((harness-core "0.1.0")
              (harness-config "0.1.0")
              (harness-tools "0.1.0"))
  :provides '(harness-skills)
  :setup #'harness-skills-setup
  :teardown #'harness-skills-teardown)

(provide 'harness-skills)
;;; harness-skills.el ends here
