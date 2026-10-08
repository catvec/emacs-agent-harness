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
;; - the bus methods `skills/list', `skills/search', `skills/load',
;;   `skills/refresh' and `skills/directories';
;; - the tools `skill_search' and `skill_load' for the model;
;; - a filter on `agent/system-prompt' that appends a compact index so
;;   the model knows which skills exist and loads one before relying
;;   on it;
;; - `harness-skills-expand-references' for the compose UI, which turns
;;   explicit "/name" and "@skill:name" references in a message into
;;   the skill's content.
;;
;; Where skills live is a convention each agent keeps, so the defaults
;; cover the documented ones: Claude Code's ~/.claude/skills and
;; .claude/skills, the harness's own ~/.config/harness/skills and
;; .harness/skills, the open Agent Skills convention's ~/.agents/skills
;; and .agents/skills (which Codex and GitHub Copilot CLI read too),
;; Copilot CLI's ~/.copilot/skills and .github/skills, and the skills of
;; the plugins Claude Code installed (`harness-skills-plugin-directories').
;; Locations added later come after the earlier ones, so a skill that
;; was found before keeps winning.
;;
;; Agents read a skill's files directly too, with read_file, grep or
;; bash, and those directories mostly lie outside a session's allowed
;; directories.  `skills/directories' tells the permission layer and the
;; bash tool which directories discovery reads: every call that only
;; reads may read them without a prompt, and the sandbox shows them to
;; bash read-only.  A directory a project or a plugin provides counts
;; only while it stays inside that project or plugin once symbolic links
;; are resolved, so a link committed to a repository cannot open the
;; rest of the disk; neither does a directory that would hold the home
;; directory itself.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

;;;; Customisation

(defcustom harness-skills-directories
  '("~/.claude/skills" "~/.config/harness/skills" "~/.agents/skills" "~/.copilot/skills"
    harness-skills-project-directories harness-skills-plugin-directories)
  "Where skills are looked for.
Each entry is either a directory name or a function called with the
session's cwd (possibly nil) that returns a directory or a list of
directories.  Directories from functions are `project' skills, plain
directory entries are `global' skills; a project skill shadows a
global one with the same name.

A function may also describe its directories itself, with plists
\(:dir DIR :source SOURCE :within BASE), as
`harness-skills-plugin-directories' does: SOURCE `plugin' marks the
skills of a Claude Code plugin, which come after the global ones, and
BASE is the directory DIR belongs to.  A directory from a function
counts for the permission layer and the sandbox only while it stays
inside its BASE, by default the session's project, once symbolic
links are resolved (see `skills/directories')."
  :type '(repeat (choice directory function))
  :group 'harness)

(defcustom harness-skills-plugins-directory nil
  "The root of Claude Code's plugins, or nil for its default.
nil means $CLAUDE_CODE_PLUGIN_CACHE_DIR when that is set, else
~/.claude/plugins, as Claude Code itself decides.  See
`harness-skills-plugin-directories'."
  :type '(choice (const :tag "Claude Code's default" nil) directory)
  :group 'harness)

(defconst harness-skills--prompt-limit 40
  "Maximum number of skills listed in the system prompt index.")

(defconst harness-skills--description-limit 120
  "Descriptions longer than this are truncated in listings.")

(defconst harness-skills-file-name "SKILL.md"
  "Name of the file that makes a directory a skill.")

;;;; Directories

(defun harness-skills--project-root (cwd)
  "Return the project root for CWD using `project/root' when available."
  (let ((cwd (file-name-as-directory (expand-file-name cwd))))
    (or (and (harness-method-exists-p 'project/root)
             (ignore-errors (harness-call 'project/root cwd)))
        cwd)))

(defconst harness-skills-project-subdirectories
  '(".claude/skills" ".harness/skills" ".agents/skills" ".github/skills")
  "Where a project keeps its skills, relative to its directory.
Claude Code's, the harness's own, the Agent Skills convention's (read
by Codex and Copilot CLI too) and Copilot CLI's.")

(defun harness-skills-project-directories (cwd)
  "Return the project-relative skill directories for CWD.
Looks for `harness-skills-project-subdirectories' under CWD and under
its project root.  Return nil when CWD is nil."
  (when cwd
    (let ((bases (delete-dups (list (file-name-as-directory (expand-file-name cwd))
                                    (harness-skills--project-root cwd))))
          out)
      (dolist (base bases (nreverse out))
        (dolist (rel harness-skills-project-subdirectories)
          (push (expand-file-name rel base) out))))))

(defun harness-skills--plugins-root ()
  "Return the root of Claude Code's plugins as a directory name.
See `harness-skills-plugins-directory'."
  (let ((env (getenv "CLAUDE_CODE_PLUGIN_CACHE_DIR")))
    (file-name-as-directory
     (expand-file-name (cond (harness-skills-plugins-directory)
                             ((not (harness-string-blank-p env)) env)
                             (t "~/.claude/plugins"))))))

(defun harness-skills--subdirs (dir)
  "Return the subdirectories of DIR whose names do not start with a dot, sorted."
  (cl-remove-if-not #'file-directory-p (directory-files dir t "\\`[^.]")))

(defun harness-skills-plugin-directories (_cwd)
  "Return the skills directories of the plugins Claude Code installed.
Claude Code copies each installed version of a marketplace plugin to
cache/MARKETPLACE/PLUGIN/VERSION/ under its plugins root (see
`harness-skills-plugins-directory'); the plugin's skills are in its
skills/ directory there.  A version it replaced or uninstalled carries
an .orphaned_at marker until it is deleted, and is left out; of the
other versions of a plugin the newest comes first.  Each directory is
\(:dir DIR :source plugin :within MARKETPLACE-DIR): like Claude Code,
which loads no component that leads out of its plugin, other than to
another plugin of the same marketplace, the permission layer and the
sandbox take a plugin's skills only while they stay in its
marketplace's directory."
  (let ((cache (expand-file-name "cache" (harness-skills--plugins-root)))
        out)
    (when (file-directory-p cache)
      (dolist (market (harness-skills--subdirs cache))
        (dolist (plugin (harness-skills--subdirs market))
          (dolist (version (sort (harness-skills--subdirs plugin)
                                 (lambda (a b) (> (or (harness-skills--mtime a) 0)
                                                  (or (harness-skills--mtime b) 0)))))
            (let ((skills (expand-file-name "skills" version)))
              (when (and (file-directory-p skills)
                         (not (file-exists-p (expand-file-name ".orphaned_at" version))))
                (push (list :dir skills :source 'plugin :within (file-name-as-directory market))
                      out)))))))
    (nreverse out)))

(defconst harness-skills--source-rank '((project . 0) (global . 1) (plugin . 2))
  "Order in which the directories of each source are searched.
A skill shadows the skills of the same name found after it.  A source
missing here ranks with `global'.")

(defun harness-skills--entries (cwd)
  "Return the skills directories for CWD as (:dir DIR :source SOURCE :within BASE).
They come in search order: project directories, then global ones,
then those of plugins, each in the order of `harness-skills-directories'.
DIR is an absolute directory name; BASE, for a directory from a
function, is the directory it belongs to (the session's project unless
the function says otherwise), and nil for a plain entry.  Missing
directories are left out."
  (let ((project-root nil) entries)
    (dolist (entry harness-skills-directories)
      (cond
       ((functionp entry)
        (let ((dirs (ignore-errors (funcall entry cwd))))
          (dolist (d (if (or (stringp dirs) (keywordp (car-safe dirs))) (list dirs) dirs))
            (cond
             ((stringp d)
              (push (list :dir d :source 'project
                          :within (or project-root
                                      (setq project-root
                                            (harness-skills--project-root (or cwd default-directory)))))
                    entries))
             ((and (consp d) (stringp (plist-get d :dir)))
              (push (list :dir (plist-get d :dir) :source (or (plist-get d :source) 'project)
                          :within (plist-get d :within))
                    entries))))))
       ((stringp entry) (push (list :dir entry :source 'global :within nil) entries))))
    (let ((rank (lambda (e) (alist-get (plist-get e :source) harness-skills--source-rank 1)))
          out seen)
      (dolist (e (sort (nreverse entries) (lambda (a b) (< (funcall rank a) (funcall rank b)))))
        (let ((dir (file-name-as-directory (expand-file-name (plist-get e :dir)))))
          (when (and (not (member dir seen)) (file-directory-p dir))
            (push dir seen)
            (push (plist-put (copy-sequence e) :dir dir) out))))
      (nreverse out))))

(defun harness-skills--directories (cwd)
  "Return ((DIR . SOURCE) ...) for CWD, project directories first.
DIR is an absolute directory name; SOURCE is `project', `global' or
`plugin'.  Missing directories are left out."
  (mapcar (lambda (e) (cons (plist-get e :dir) (plist-get e :source)))
          (harness-skills--entries cwd)))

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

(defun harness-skills--contained-p (entry dir)
  "Non-nil when DIR, found through ENTRY, holds skills and nothing else.
ENTRY is one of `harness-skills--entries'.  DIR does unless it leads
out of ENTRY's `:within' once symbolic links are resolved, or it is or
holds the home directory."
  (let ((within (plist-get entry :within)))
    (and (not (harness-path-within-p dir (expand-file-name "~")))
         (or (null within) (harness-path-within-p within dir))
         t)))

(harness-defmethod skills/directories (&optional cwd)
  "Return the directories skill discovery reads for a session at CWD.
Each is (:dir DIR :source SOURCE :contained BOOL), in search order:
every skills directory that exists (see `harness-skills-directories'),
each followed by the skill directories in it that lead elsewhere
through a symbolic link, such as a skill linked in from a dotfiles
repository.  `:contained' is non-nil for the directories that hold
skills and nothing else, which the permission layer lets every call
that only reads read without a prompt and the bash tool's sandbox
shows read-only.  It is nil for a directory from a function that
leads out of where it belongs (its `:within', see
`harness-skills-directories') once symbolic links are resolved, so a
link committed to a repository cannot open the rest of the disk, and
for one that is or holds the home directory."
  (let (out)
    (dolist (entry (harness-skills--entries cwd))
      (let ((dir (plist-get entry :dir))
            (source (plist-get entry :source)))
        (push (list :dir dir :source source :contained (harness-skills--contained-p entry dir)) out)
        (dolist (skill (harness-skills--skill-dirs dir))
          (unless (harness-path-within-p dir skill)
            (push (list :dir skill :source source :contained (harness-skills--contained-p entry skill))
                  out)))))
    (nreverse out)))

(defun harness-skills--readable-p (path cwd)
  "Non-nil when PATH lies in a skills directory that may be read from CWD.
That is one of the `:contained' directories of `skills/directories',
symbolic links resolved."
  (cl-some (lambda (e) (and (plist-get e :contained) (harness-path-within-p (plist-get e :dir) path)))
           (harness-call 'skills/directories cwd)))

(defun harness-skills--file (skill file &optional cwd)
  "Return the text of FILE, one of SKILL's supporting files, and its absolute name.
FILE is relative to the skill's directory and must stay inside it once
symbolic links are resolved, and inside a skills directory that may be
read from CWD (`harness-skills--readable-p'): skill_load reads nothing
the file tools could not read without approval.  Return (PATH . TEXT);
signal `harness-error' when FILE is no readable text file there."
  (let* ((dir (plist-get skill :path))
         (path (expand-file-name file dir))
         (inside (harness-path-within-p dir path))
         (readable (and inside (harness-skills--readable-p path cwd)))
         (text (and readable (file-regular-p path) (harness-read-file path))))
    (cond
     ((not inside)
      (signal 'harness-error (list (format "%s is not inside the directory of the skill %s"
                                           file (plist-get skill :name)))))
     ((not readable)
      (signal 'harness-error (list (format "The files of the skill %s are not served: its directory leads out of the project or plugin that provides it"
                                           (plist-get skill :name)))))
     ((null text)
      (signal 'harness-error (list (format "The skill %s has no readable file %s"
                                           (plist-get skill :name) file))))
     ((string-search "\0" text)
      (signal 'harness-error (list (format "%s of the skill %s is a binary file" file (plist-get skill :name)))))
     (t (cons path text)))))

;;;; Formatting

(defun harness-skills--format-line (skill)
  "Return a one-line description of SKILL for listings."
  (let ((desc (harness-truncate-end (harness-first-line (or (plist-get skill :description) ""))
                                    harness-skills--description-limit)))
    (if (string-empty-p desc)
        (plist-get skill :name)
      (format "%s — %s" (plist-get skill :name) desc))))

(defun harness-skills--format-loaded (skill)
  "Return the text a tool returns for the loaded SKILL."
  (let ((files (plist-get skill :files)))
    (concat (format "# Skill: %s\nPath: %s\n\n" (plist-get skill :name) (plist-get skill :path))
            (string-trim-right (or (plist-get skill :content) ""))
            (if files
                (format "\n\nSupporting files in %s (skill_load with file set to one returns it):\n%s"
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

(defun harness-skills--tool-file (skill file cwd)
  "Return the skill_load result for FILE, one of SKILL's supporting files.
CWD is the session's, as for `harness-skills--file'."
  (condition-case err
      (let ((found (harness-skills--file skill file cwd)))
        (harness-tool-ok (format "# Skill: %s, file %s\nPath: %s\n\n%s"
                                 (plist-get skill :name) file (car found) (cdr found))))
    (harness-error
     (let ((files (plist-get skill :files)))
       (harness-tool-error
        (concat (harness-error-message err) "."
                (if files
                    (format " Its supporting files: %s." (string-join files ", "))
                  " It has no supporting files.")))))))

(defun harness-skills--tool-load (input ctx)
  "Handler for the skill_load tool with INPUT and CTX."
  (let* ((name (or (plist-get input :name) ""))
         (file (plist-get input :file))
         (cwd (plist-get ctx :cwd)))
    (if (harness-string-blank-p name)
        (harness-tool-error "The skill_load tool needs a skill name")
      (let ((skill (condition-case nil (harness-call 'skills/load name cwd) (harness-error nil))))
        (cond
         ((null skill)
          (let ((close (seq-take (harness-call 'skills/search name cwd) 5)))
            (harness-tool-error
             (concat (format "No skill named %S." name)
                     (if close
                         (format " Did you mean: %s?"
                                 (mapconcat (lambda (s) (plist-get s :name)) close ", "))
                       " Use skill_search to list the available skills.")))))
         ((and (stringp file) (not (harness-string-blank-p file)))
          (harness-skills--tool-file skill (string-trim file) cwd))
         (t (harness-tool-ok (harness-skills--format-loaded skill))))))))

(harness-define-tool "skill_search"
  :label "Search skills"
  :description "Search the installed skills (reusable instructions for specific tasks) by name and description. Returns matching skill names with a one-line summary; load one with skill_load before following it."
  :schema '(:type "object"
            :properties (:query (:type "string"
                                 :description "Words to match against skill names and descriptions; empty lists every skill."))
            :required ("query"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (plist-get input :query))
  :handler #'harness-skills--tool-search)

(harness-define-tool "skill_load"
  :label "Load skill"
  :description "Load a skill by name and return its full instructions and the list of its supporting files; with file, return one of those files instead. Always load a skill before relying on it."
  :schema '(:type "object"
            :properties (:name (:type "string" :description "The skill name as listed by skill_search.")
                         :file (:type "string" :description "Optional: one of the skill's supporting files, relative to its directory as skill_load lists them, to return instead of its instructions."))
            :required ("name"))
  :kind 'read
  :coalescable t
  :subject (lambda (input)
             (let ((file (plist-get input :file)))
               (if (harness-string-blank-p file)
                   (plist-get input :name)
                 (format "%s: %s" (plist-get input :name) file))))
  :handler #'harness-skills--tool-load)

;;;; System prompt

(defun harness-skills-system-prompt-filter (prompt session)
  "Append an index of the skills visible from SESSION's cwd to PROMPT.
Registered on `agent/system-prompt'.  Does nothing when no skill exists."
  (let ((skills (ignore-errors (harness-call 'skills/list (plist-get session :cwd)))))
    (if (null skills)
        prompt
      (let* ((total (length skills))
             (shown (seq-take skills harness-skills--prompt-limit)))
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
