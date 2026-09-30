;;; harness-skills.el --- Skill discovery, search and loading  -*- lexical-binding: t; -*-

;;; Commentary:

;; A skill is a directory NAME holding a SKILL.md file, the layout used
;; by Claude Code and friends.  SKILL.md may start with YAML front
;; matter (name, description); without it the directory name and the
;; first paragraph stand in.
;;
;; The module scans `harness-skills-directories' (global locations plus
;; project-relative ones resolved against a session's cwd), caches each
;; directory by modification time, and exposes:
;;
;; - the bus methods `skills/list', `skills/search', `skills/load' and
;;   `skills/refresh';
;; - the tools `skill_search' and `skill_load' for the model;
;; - a filter on `agent/system-prompt' that appends a compact index so
;;   the model knows which skills exist and loads one before relying
;;   on it;
;; - `harness-skills-expand-references' for the compose UI, which turns
;;   explicit "/name" and "@skill:name" references in a message into
;;   the skill's content.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

;;;; Customisation

(defcustom harness-skills-directories
  '("~/.claude/skills" "~/.config/harness/skills" harness-skills-project-directories)
  "Where skills are looked for.
Each entry is either a directory name or a function called with the
session's cwd (possibly nil) that returns a directory or a list of
directories.  Directories from functions are `project' skills, plain
directory entries are `global' skills; a project skill shadows a
global one with the same name."
  :type '(repeat (choice directory function))
  :group 'harness)

(defcustom harness-skills-prompt-limit 40
  "Maximum number of skills listed in the system prompt index."
  :type 'integer :group 'harness)

(defcustom harness-skills-description-limit 120
  "Descriptions longer than this are truncated in listings."
  :type 'integer :group 'harness)

(defconst harness-skills-file-name "SKILL.md"
  "Name of the file that makes a directory a skill.")

;;;; Directories

(defun harness-skills--project-root (cwd)
  "Return the project root for CWD using `project/root' when available."
  (let ((cwd (file-name-as-directory (expand-file-name cwd))))
    (or (and (harness-method-exists-p 'project/root)
             (ignore-errors (harness-call 'project/root cwd)))
        cwd)))

(defun harness-skills-project-directories (cwd)
  "Return the project-relative skill directories for CWD.
Looks for .claude/skills and .harness/skills under CWD and under its
project root.  Return nil when CWD is nil."
  (when cwd
    (let ((bases (delete-dups (list (file-name-as-directory (expand-file-name cwd))
                                    (harness-skills--project-root cwd))))
          out)
      (dolist (base bases (nreverse out))
        (dolist (rel '(".claude/skills" ".harness/skills"))
          (push (expand-file-name rel base) out))))))

(defun harness-skills--directories (cwd)
  "Return ((DIR . SOURCE) ...) for CWD, project directories first.
DIR is an absolute directory name; SOURCE is `project' or `global'.
Missing directories are left out."
  (let (project global)
    (dolist (entry harness-skills-directories)
      (cond
       ((functionp entry)
        (let ((dirs (ignore-errors (funcall entry cwd))))
          (dolist (d (if (listp dirs) dirs (list dirs)))
            (when (stringp d) (push (cons d 'project) project)))))
       ((stringp entry) (push (cons entry 'global) global))))
    (let (out seen)
      (dolist (cell (append (nreverse project) (nreverse global)))
        (let ((dir (file-name-as-directory (expand-file-name (car cell)))))
          (when (and (not (member dir seen)) (file-directory-p dir))
            (push dir seen)
            (push (cons dir (cdr cell)) out))))
      (nreverse out))))

;;;; Parsing SKILL.md

(defun harness-skills--unquote (value)
  "Strip surrounding quotes from the YAML scalar VALUE."
  (let ((v (string-trim value)))
    (if (and (>= (length v) 2)
             (memq (aref v 0) '(?\" ?\'))
             (eq (aref v 0) (aref v (1- (length v)))))
        (substring v 1 -1)
      v)))

(defun harness-skills--parse-front-matter (text)
  "Split TEXT into (FIELDS . BODY).
FIELDS is an alist of lowercased key strings to values parsed from a
leading YAML front matter block, or nil when there is none.  Only the
flat subset (key: value, and | or > block scalars) is understood."
  (if (not (string-match "\\`---[ \t]*\n" text))
      (cons nil text)
    (let* ((start (match-end 0))
           (end (and (string-match "^\\(?:---\\|\\.\\.\\.\\)[ \t]*\\(?:\n\\|\\'\\)" text start)
                     (match-beginning 0)))
           (after (and end (match-end 0))))
      (if (not end)
          (cons nil text)
        (let ((lines (split-string (substring text start end) "\n"))
              fields current)
          (dolist (line lines)
            (cond
             ((string-match "\\`[ \t]+\\(.*\\)\\'" line)
              (when current
                (setcdr current (concat (cdr current)
                                        (if (string-empty-p (cdr current)) "" " ")
                                        (string-trim (match-string 1 line))))))
             ((string-match "\\`\\([A-Za-z0-9_-]+\\)[ \t]*:[ \t]*\\(.*\\)\\'" line)
              (let ((key (downcase (match-string 1 line)))
                    (val (match-string 2 line)))
                (setq current (cons key (if (member (string-trim val) '("|" ">" "|-" ">-"))
                                            ""
                                          (harness-skills--unquote val))))
                (push current fields)))
             ((string-blank-p line) nil)
             (t (setq current nil))))
          (cons (nreverse fields) (substring text after)))))))

(defun harness-skills--first-paragraph (body)
  "Return the first paragraph of BODY as a single line, skipping headings."
  (let ((paragraphs (split-string body "\n[ \t]*\n" t "[ \t\n]+")))
    (or (cl-loop for p in paragraphs
                 for text = (string-join (split-string p "\n" t "[ \t]+") " ")
                 unless (or (string-prefix-p "#" text) (string-empty-p text))
                 return text)
        (and (car paragraphs)
             (string-trim (replace-regexp-in-string "\\`#+[ \t]*" "" (car paragraphs))))
        "")))

(defun harness-skills--read (dir source)
  "Read the skill in DIR (a directory containing SKILL.md) tagged SOURCE.
Return a plist (:name :description :path :source :content :fields) or
nil when the file cannot be read."
  (let* ((file (expand-file-name harness-skills-file-name dir))
         (text (harness-read-file file)))
    (when text
      (let* ((parsed (harness-skills--parse-front-matter text))
             (fields (car parsed))
             (body (cdr parsed))
             (dirname (file-name-nondirectory (directory-file-name dir)))
             (name (let ((n (cdr (assoc "name" fields))))
                     (if (harness-string-blank-p n) dirname n)))
             (description (let ((d (cdr (assoc "description" fields))))
                            (if (harness-string-blank-p d)
                                (harness-skills--first-paragraph body)
                              d))))
        (list :name name :description description
              :path (file-name-as-directory (expand-file-name dir))
              :source source :content body :fields fields)))))

;;;; Cache

(defvar harness-skills--cache (make-hash-table :test 'equal)
  "Directory -> (STAMP . SKILLS).  STAMP is the directory and file mtimes.")

(defun harness-skills--mtime (path)
  "Return the modification time of PATH as a float, or nil."
  (let ((attrs (file-attributes path)))
    (and attrs (float-time (file-attribute-modification-time attrs)))))

(defun harness-skills--skill-dirs (dir)
  "Return the subdirectories of DIR that contain a SKILL.md, sorted."
  (let (out)
    (dolist (entry (directory-files dir t "\\`[^.]" t))
      (when (and (file-directory-p entry)
                 (file-readable-p (expand-file-name harness-skills-file-name entry)))
        (push (file-name-as-directory entry) out)))
    (sort out #'string<)))

(defun harness-skills--stamp (dir skill-dirs)
  "Return a freshness stamp for DIR and its SKILL-DIRS."
  (cons (harness-skills--mtime dir)
        (mapcar (lambda (d) (harness-skills--mtime (expand-file-name harness-skills-file-name d)))
                skill-dirs)))

(defun harness-skills--scan (dir source)
  "Return the skills under DIR tagged SOURCE, using the mtime cache."
  (let* ((cached (gethash dir harness-skills--cache))
         (dirs (harness-skills--skill-dirs dir))
         (stamp (harness-skills--stamp dir dirs)))
    (if (and cached (equal (car cached) stamp)
             (equal (mapcar (lambda (s) (plist-get s :path)) (cdr cached)) dirs))
        (cdr cached)
      (let ((skills (delq nil (mapcar (lambda (d) (harness-skills--read d source)) dirs))))
        (puthash dir (cons stamp skills) harness-skills--cache)
        skills))))

(defun harness-skills--all (cwd)
  "Return every skill visible from CWD, full records, deduplicated by name."
  (let (out seen)
    (dolist (cell (harness-skills--directories cwd))
      (dolist (skill (harness-skills--scan (car cell) (cdr cell)))
        (let ((name (plist-get skill :name)))
          (unless (member name seen)
            (push name seen)
            (push skill out)))))
    (nreverse out)))

(defun harness-skills--summary (skill)
  "Return the public listing plist of SKILL."
  (list :name (plist-get skill :name)
        :description (plist-get skill :description)
        :path (plist-get skill :path)
        :source (plist-get skill :source)))

(defun harness-skills--find (name cwd)
  "Return the full record of the skill NAME visible from CWD, or nil.
Matches the declared name first, then the directory name."
  (let ((skills (harness-skills--all cwd)))
    (or (cl-find name skills :key (lambda (s) (plist-get s :name)) :test #'string=)
        (cl-find name skills
                 :key (lambda (s) (file-name-nondirectory (directory-file-name (plist-get s :path))))
                 :test #'string=))))

(defun harness-skills--files (dir)
  "Return the files under skill directory DIR other than SKILL.md, relative."
  (let ((dir (file-name-as-directory dir)))
    (sort (delq nil
                (mapcar (lambda (f)
                          (let ((rel (file-relative-name f dir)))
                            (unless (string= rel harness-skills-file-name) rel)))
                        (directory-files-recursively dir "\\`[^.]" nil
                                                     (lambda (d) (not (string-prefix-p "." (file-name-nondirectory d)))))))
          #'string<)))

;;;; Methods

(harness-defmethod skills/list (&optional cwd)
  "Return the skills visible from CWD.
Each is (:name :description :path :source).  Project skills (resolved
against CWD) come first and shadow global skills with the same name."
  (mapcar #'harness-skills--summary (harness-skills--all cwd)))

(harness-defmethod skills/search (query &optional cwd)
  "Return the skills visible from CWD fuzzy-matching QUERY, best first.
A blank QUERY returns every skill."
  (let ((skills (harness-call 'skills/list cwd)))
    (if (harness-string-blank-p query)
        skills
      (harness-fuzzy-filter query skills
                            (lambda (s) (format "%s %s" (plist-get s :name)
                                                (or (plist-get s :description) "")))))))

(harness-defmethod skills/load (name &optional cwd)
  "Return the skill NAME visible from CWD.
The result is (:name :description :content :path :source :files).
:content is SKILL.md without its front matter; :files lists the other
files in the skill directory, relative to it.  Signals `harness-error'
when no such skill exists."
  (let ((skill (harness-skills--find name cwd)))
    (unless skill (signal 'harness-error (list (format "No skill named %s" name))))
    (list :name (plist-get skill :name)
          :description (plist-get skill :description)
          :content (plist-get skill :content)
          :path (plist-get skill :path)
          :source (plist-get skill :source)
          :files (harness-skills--files (plist-get skill :path)))))

(harness-defmethod skills/refresh ()
  "Forget every cached skill directory so the next call rescans."
  (clrhash harness-skills--cache)
  t)

;;;; Formatting

(defun harness-skills--format-line (skill)
  "Return a one-line description of SKILL for listings."
  (let ((desc (harness-truncate-end (harness-first-line (or (plist-get skill :description) ""))
                                    harness-skills-description-limit)))
    (if (string-empty-p desc)
        (plist-get skill :name)
      (format "%s — %s" (plist-get skill :name) desc))))

(defun harness-skills--format-loaded (skill)
  "Return the text a tool returns for the loaded SKILL."
  (let ((files (plist-get skill :files)))
    (concat (format "# Skill: %s\nPath: %s\n\n" (plist-get skill :name) (plist-get skill :path))
            (string-trim-right (or (plist-get skill :content) ""))
            (if files
                (format "\n\nSupporting files in %s:\n%s"
                        (plist-get skill :path)
                        (mapconcat (lambda (f) (concat "- " f)) files "\n"))
              "")
            "\n")))

;;;; Tools

(defun harness-skills--tool-search (input ctx)
  "Handler for the skill_search tool with INPUT and CTX."
  (let* ((query (or (plist-get input :query) ""))
         (found (harness-call 'skills/search query (plist-get ctx :cwd))))
    (cond
     ((null found)
      (harness-tool-ok
       (if (harness-string-blank-p query)
           "No skills are installed."
         (format "No skills match %S. Try a shorter query or skill_search with no query to list every skill."
                 query))))
     (t (harness-tool-ok
         (concat (format "%d skill%s (load one with skill_load before using it):\n"
                         (length found) (if (= (length found) 1) "" "s"))
                 (mapconcat (lambda (s) (format "- %s [%s]" (harness-skills--format-line s)
                                                (plist-get s :source)))
                            found "\n")))))))

(defun harness-skills--tool-load (input ctx)
  "Handler for the skill_load tool with INPUT and CTX."
  (let* ((name (or (plist-get input :name) ""))
         (cwd (plist-get ctx :cwd)))
    (if (harness-string-blank-p name)
        (harness-tool-error "The skill_load tool needs a skill name")
      (condition-case nil
          (harness-tool-ok (harness-skills--format-loaded (harness-call 'skills/load name cwd)))
        (harness-error
         (let ((close (seq-take (harness-call 'skills/search name cwd) 5)))
           (harness-tool-error
            (concat (format "No skill named %S." name)
                    (if close
                        (format " Did you mean: %s?"
                                (mapconcat (lambda (s) (plist-get s :name)) close ", "))
                      " Use skill_search to list the available skills.")))))))))

(harness-define-tool "skill_search"
  :description "Search the installed skills (reusable instructions for specific tasks) by name and description. Returns matching skill names with a one-line summary; load one with skill_load before following it."
  :schema '(:type "object"
            :properties (:query (:type "string"
                                 :description "Words to match against skill names and descriptions; empty lists every skill."))
            :required ("query"))
  :kind 'read
  :coalescable t
  :title (lambda (input) (format "skill_search %s" (or (plist-get input :query) "")))
  :handler #'harness-skills--tool-search)

(harness-define-tool "skill_load"
  :description "Load a skill by name and return its full instructions and the list of its supporting files. Always load a skill before relying on it."
  :schema '(:type "object"
            :properties (:name (:type "string" :description "The skill name as listed by skill_search."))
            :required ("name"))
  :kind 'read
  :coalescable t
  :title (lambda (input) (format "skill_load %s" (or (plist-get input :name) "")))
  :handler #'harness-skills--tool-load)

;;;; System prompt

(defun harness-skills-system-prompt-filter (prompt session)
  "Append an index of the skills visible from SESSION's cwd to PROMPT.
Registered on `agent/system-prompt'.  Does nothing when no skill exists."
  (let ((skills (ignore-errors (harness-call 'skills/list (plist-get session :cwd)))))
    (if (null skills)
        prompt
      (let* ((total (length skills))
             (shown (seq-take skills harness-skills-prompt-limit)))
        (concat (or prompt "")
                (if (harness-string-blank-p prompt) "" "\n\n")
                "## Available skills\n"
                "Skills are reusable instructions. When a task matches one, call "
                "skill_load with its name and follow the loaded instructions before "
                "relying on it; skill_search finds more.\n"
                (mapconcat (lambda (s) (concat "- " (harness-skills--format-line s))) shown "\n")
                (if (> total (length shown))
                    (format "\n(%d more; use skill_search)" (- total (length shown)))
                  ""))))))

;;;; Explicit references

(defconst harness-skills--reference-regexp
  (concat "\\(?:^/\\([A-Za-z0-9][A-Za-z0-9._-]*\\)\\(?:[ \t]\\|$\\)\\)"
          "\\|\\(?:@skill:\\([A-Za-z0-9][A-Za-z0-9._-]*\\)\\)")
  "Matches /NAME at the start of a line (group 1) or @skill:NAME (group 2).")

(defun harness-skills--fence-for (content)
  "Return a backtick fence longer than any run of backticks in CONTENT."
  (let ((longest 0) (pos 0))
    (while (string-match "`+" content pos)
      (setq longest (max longest (- (match-end 0) (match-beginning 0)))
            pos (match-end 0)))
    (make-string (max 3 (1+ longest)) ?`)))

(defun harness-skills-expand-references (text cwd)
  "Expand skill references in TEXT for a message composed at CWD.
A reference is /NAME at the start of a line or @skill:NAME anywhere.
For each one naming an installed skill, a fenced block holding the
skill's content is inserted after the line containing the reference;
a skill referenced several times is inserted once.  Unknown names are
left alone.  Return (TEXT2 . ATTACHED) where ATTACHED is the list of
loaded skill plists in order of first reference."
  (let ((pos 0) (out nil) (attached nil) (last 0))
    (while (string-match harness-skills--reference-regexp text pos)
      (let* ((name (or (match-string 1 text) (match-string 2 text)))
             (match-end (match-end 0))
             (skill (and (not (cl-find name attached :key (lambda (s) (plist-get s :name))
                                       :test #'string=))
                         (harness-skills--find name cwd)
                         (condition-case nil (harness-call 'skills/load name cwd) (harness-error nil)))))
        (setq pos match-end)
        (when skill
          (let* ((eol (or (string-search "\n" text match-end) (length text)))
                 (fence (harness-skills--fence-for (or (plist-get skill :content) ""))))
            (push (substring text last eol) out)
            (push (format "\n%smarkdown skill:%s\n%s\n%s"
                          fence (plist-get skill :name)
                          (string-trim-right (or (plist-get skill :content) ""))
                          fence)
                  out)
            (setq last eol pos eol)
            (push skill attached)))))
    (push (substring text last) out)
    (cons (apply #'concat (nreverse out)) (nreverse attached))))

;;;; Module

(defun harness-skills--init ()
  "Register the skills system prompt filter."
  (harness-add-filter 'agent/system-prompt #'harness-skills-system-prompt-filter 60))

(defun harness-skills--shutdown ()
  "Remove the skills system prompt filter."
  (harness-remove-filter 'agent/system-prompt #'harness-skills-system-prompt-filter))

(harness-define-module 'skills
  :doc "Skill discovery (SKILL.md directories), search, loading and prompt index."
  :requires '(tools)
  :init #'harness-skills--init
  :shutdown #'harness-skills--shutdown)

(harness-defmethod skills/expand (text cwd)
  "Expand skill references in TEXT for a session at CWD.
Return (:text EXPANDED :skills SKILLS) where SKILLS are the attached
skill plists.  See `harness-skills-expand-references'."
  (let ((r (harness-skills-expand-references text cwd)))
    (list :text (car r) :skills (cdr r))))

(provide 'harness-skills)
;;; harness-skills.el ends here
