;;; harness-skills-scan.el --- Finding, reading and identifying skills  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A skill is a directory NAME holding a SKILL.md file, the layout used
;; by Claude Code and friends.  This file is the one place that finds
;; them, reads their front matter and says what identifies one, and both
;; sides of the process split use it: the skills module in the harness
;; process, and the computer endpoint a client runs on the machine the
;; skills live on.  There is no second scanner and no second registry.
;;
;; A scan takes *entries*: `(:dir DIR :source SOURCE :origin ORIGIN
;; :within BASE)'.  SOURCE is `global', `project' or `plugin' and ORIGIN
;; names the convention that provides it (`claude', `harness', `agents',
;; `copilot', a plugin's `MARKETPLACE/PLUGIN'), so that provenance says
;; where a skill came from and not only what kind of place it was.  BASE,
;; when given, is the directory a linked-out skill may not leave: a
;; project's own skills, or a marketplace's plugins, once symbolic links
;; are resolved.
;;
;; What a scan returns is metadata and the SKILL.md body, never a
;; promise to run anything: name, description, source, origin, the
;; explicit version when the front matter has one, a content
;; fingerprint, the supporting files and bounded diagnostics.  A skill
;; whose front matter is malformed is reported with its diagnostics and
;; the rest of the scan goes on, so one bad skill never breaks a
;; registration.
;;
;; Identity.  A skill's id is made from the computer-independent parts
;; of its *location*: its source, its origin and its path relative to
;; the scan root that holds it.  So it survives a change of the declared
;; name, of the description or of the content -- those are what the
;; fingerprint is for -- and it survives a reconnect, since it names no
;; process and no time.  A skill directory that is moved or renamed is a
;; different skill: the old id is removed when the owner reports its
;; resources again, and a qualified reference to it says it is gone
;; instead of quietly resolving to something else.
;;
;; Fingerprint.  A fingerprint is `fp-' and the first 32 hex digits of
;; the SHA-256 of the SKILL.md bytes, the sorted relative names of the
;; supporting files and each file's size.  It changes when any of those
;; change, and it needs no clock, so two computers can compare their
;; copies of a skill without trusting a modification time.  When the
;; front matter declares no version, the fingerprint is the version too
;; (`fp-XXXXXXXX'), which is what a pin uses.
;;
;; Bounds.  Every scan is bounded: a number of skills per root, a size
;; for SKILL.md, a number and total size of supporting files, a depth
;; and a count of diagnostics, and a wall-clock budget for one scan.
;; Symbolic links are followed only to decide whether a skill stays
;; inside what may be read; nothing is ever read outside a skill
;; directory, and no file is read whole above the size bound.  Nothing
;; here reads a credential: the roots are the documented skill
;; locations, and a path that is or holds the home directory is refused.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-util)

(defgroup harness-skills-scan nil
  "Finding and identifying the skills on a machine."
  :group 'harness
  :prefix "harness-skills-scan-")

(defconst harness-skills-scan-file-name "SKILL.md"
  "Name of the file that makes a directory a skill.")

(defconst harness-skills-scan-capability "skills"
  "The computer-use capability a client that serves its skills advertises.
It says the computer can answer its `skills' tool: list the skills it
has, scan again, and return the content of one by its stable id.  A
harness may grant it to a session as it grants any other capability, and
listing needs no grant.  It does not make a skill runnable and it
executes nothing: reading instructions is not permission to follow
them.")

(defconst harness-skills-scan-user-roots
  '(("~/.claude/skills" . "claude")
    ("~/.config/harness/skills" . "harness")
    ("~/.agents/skills" . "agents")
    ("~/.copilot/skills" . "copilot"))
  "Where a user keeps skills, and the convention each place belongs to.
These are the documented locations: Claude Code's, the harness's own,
the open Agent Skills convention's (which Codex and GitHub Copilot CLI
read too) and Copilot CLI's.")

(defconst harness-skills-scan-project-subdirectories
  '((".claude/skills" . "claude")
    (".harness/skills" . "harness")
    (".agents/skills" . "agents")
    (".github/skills" . "copilot"))
  "Where a project keeps skills, beside its directory.
Each pair is (SUBDIRECTORY . ORIGIN), the convention the place belongs
to.")

(defconst harness-skills-scan-source-rank '((project . 0) (global . 1) (plugin . 2))
  "Order in which the kinds of place a skill comes from are listed.
A project's skills come before the user's, and a plugin's last, so a
listing reads from the nearest to the farthest.")

(defcustom harness-skills-scan-max-skills 500
  "Most skills one scan returns from one root.
The rest are left out with a diagnostic, so a directory holding a whole
disk's worth of them can neither hang a registration nor fill it."
  :type 'integer
  :group 'harness-skills-scan)

(defcustom harness-skills-scan-max-file-bytes (* 256 1024)
  "Largest SKILL.md a scan reads, in bytes.
A larger file is a diagnostic, not a skill: instructions that big do not
belong in a prompt."
  :type 'integer
  :group 'harness-skills-scan)

(defcustom harness-skills-scan-max-files 200
  "Most supporting files one skill lists.
The listing is what a skill_load returns; a directory with more is
reported with a diagnostic and the first files, in order."
  :type 'integer
  :group 'harness-skills-scan)

(defcustom harness-skills-scan-max-files-bytes (* 8 1024 1024)
  "Total size of the supporting files one skill lists, in bytes."
  :type 'integer
  :group 'harness-skills-scan)

(defcustom harness-skills-scan-max-file-read-bytes (* 2 1024 1024)
  "Largest supporting file one retrieval returns, in bytes."
  :type 'integer
  :group 'harness-skills-scan)

(defcustom harness-skills-scan-max-depth 6
  "How deep below a skill directory supporting files are listed."
  :type 'integer
  :group 'harness-skills-scan)

(defconst harness-skills-scan--max-diagnostics 8
  "Most diagnostics one skill reports.")

(defconst harness-skills-scan--max-diagnostic-chars 240
  "Longest diagnostic text one skill reports.")

(defconst harness-skills-scan--description-limit 400
  "Longest description a scan keeps, in characters.")

;;;; Entries and containment

(defun harness-skills-scan--name (value)
  "Return VALUE as a trimmed non-blank string, or nil."
  (cond ((stringp value) (and (not (harness-string-blank-p value)) (string-trim value)))
        ((and value (symbolp value) (not (keywordp value))) (symbol-name value))))

(defun harness-skills-scan--directory (dir)
  "Return DIR as an absolute directory name."
  (file-name-as-directory (expand-file-name dir)))

(defun harness-skills-scan-home-p (dir)
  "Non-nil when DIR is or holds the home directory."
  (harness-path-within-p dir (expand-file-name "~")))

(defun harness-skills-scan--entry (entry)
  "Return ENTRY, a plist, with its directory absolute and its origin named."
  (when (and (listp entry) (stringp (plist-get entry :dir)))
    (let ((dir (harness-skills-scan--directory (plist-get entry :dir))))
      (list :dir dir
            :source (or (plist-get entry :source) 'global)
            :origin (or (harness-skills-scan--name (plist-get entry :origin))
                        (symbol-name (or (plist-get entry :source) 'global)))
            :within (let ((within (plist-get entry :within)))
                      (and (stringp within) (harness-skills-scan--directory within)))))))

(defun harness-skills-scan-entries (&optional cwd plugins)
  "Return the documented skill entries for CWD.
They are the user's convention directories (`harness-skills-scan-user-roots'),
the plugins Claude Code installed when PLUGINS is non-nil
\(`harness-skills-scan-plugin-entries') and, with CWD, the project's
\(`harness-skills-scan-project-subdirectories') under CWD and its project
root when the project module is loaded."
  (let ((out nil))
    (dolist (pair harness-skills-scan-user-roots)
      (push (list :dir (car pair) :source 'global :origin (cdr pair)) out))
    (when plugins
      (setq out (append (harness-skills-scan-plugin-entries) out)))
    (when cwd
      (let* ((cwd (harness-skills-scan--directory cwd))
             (root (or (and (harness-method-exists-p 'project/root)
                            (ignore-errors (harness-call 'project/root cwd)))
                       cwd)))
        (dolist (base (delete-dups (list cwd (harness-skills-scan--directory root))))
          (dolist (pair harness-skills-scan-project-subdirectories)
            (push (list :dir (expand-file-name (car pair) base) :source 'project
                        :origin (cdr pair) :within base)
                  out)))))
    (nreverse out)))

(defcustom harness-skills-scan-plugins-directory nil
  "The root of Claude Code's plugins, or nil for its default.
nil means $CLAUDE_CODE_PLUGIN_CACHE_DIR when that is set, else
~/.claude/plugins, as Claude Code itself decides."
  :type '(choice (const :tag "Claude Code's default" nil) directory)
  :group 'harness-skills-scan)

(defun harness-skills-scan-plugins-root ()
  "Return the root of Claude Code's plugins as a directory name."
  (let ((env (getenv "CLAUDE_CODE_PLUGIN_CACHE_DIR")))
    (file-name-as-directory
     (expand-file-name (cond (harness-skills-scan-plugins-directory)
                             ((not (harness-string-blank-p env)) env)
                             (t "~/.claude/plugins"))))))

(defun harness-skills-scan--subdirs (dir)
  "Return the subdirectories of DIR whose names do not start with a dot, sorted."
  (cl-remove-if-not #'file-directory-p (directory-files dir t "\\`[^.]")))

(defun harness-skills-scan--mtime (path)
  "Return the modification time of PATH as a float, or nil."
  (let ((attrs (file-attributes path)))
    (and attrs (float-time (file-attribute-modification-time attrs)))))

(defun harness-skills-scan-plugin-entries ()
  "Return the skills directories of the plugins Claude Code installed.
Claude Code copies each installed version of a marketplace plugin to
cache/MARKETPLACE/PLUGIN/VERSION/ under its plugins root; the plugin's
skills are in its skills/ directory there.  A version it replaced or
uninstalled carries an .orphaned_at marker until it is deleted, and is
left out; of the other versions of a plugin the newest comes first.
Each entry is `(:dir DIR :source plugin :origin \"MARKETPLACE/PLUGIN\"
:within MARKETPLACE-DIR)': like Claude Code, which loads no component
that leads out of its plugin, other than to another plugin of the same
marketplace, the permission layer and a scan take a plugin's skills only
while they stay in its marketplace's directory."
  (let ((cache (expand-file-name "cache" (harness-skills-scan-plugins-root)))
        out)
    (when (file-directory-p cache)
      (dolist (market (harness-skills-scan--subdirs cache))
        (let ((market-name (file-name-nondirectory (directory-file-name market))))
          (dolist (plugin (harness-skills-scan--subdirs market))
            (let ((plugin-name (file-name-nondirectory (directory-file-name plugin))))
              (dolist (version (sort (harness-skills-scan--subdirs plugin)
                                     (lambda (a b) (> (or (harness-skills-scan--mtime a) 0)
                                                      (or (harness-skills-scan--mtime b) 0)))))
                (let ((skills (expand-file-name "skills" version)))
                  (when (and (file-directory-p skills)
                             (not (file-exists-p (expand-file-name ".orphaned_at" version))))
                    (push (list :dir skills :source 'plugin
                                :origin (format "%s/%s" market-name plugin-name)
                                :within (file-name-as-directory market))
                          out)))))))))
    (nreverse out)))

(defun harness-skills-scan-contained-p (dir &optional within)
  "Non-nil when DIR holds skills and nothing else.
That is unless it is or holds the home directory, and unless WITHIN is
given and DIR leads out of it once symbolic links are resolved: a link
committed to a repository then cannot open the rest of the disk."
  (and (stringp dir)
       (not (harness-skills-scan-home-p dir))
       (or (null within) (harness-path-within-p within dir))
       t))

(defun harness-skills-scan-inside-p (dir path)
  "Non-nil when PATH stays inside DIR once symbolic links are resolved."
  (and (stringp dir) (stringp path) (harness-path-within-p dir path) t))

;;;; Parsing SKILL.md

(defun harness-skills-scan--unquote (value)
  "Strip surrounding quotes from the YAML scalar VALUE."
  (let ((v (string-trim value)))
    (if (and (>= (length v) 2)
             (memq (aref v 0) '(?\" ?\'))
             (eq (aref v 0) (aref v (1- (length v)))))
        (substring v 1 -1)
      v)))

(defun harness-skills-scan-parse-front-matter (text)
  "Split TEXT into (FIELDS . BODY).
FIELDS is an alist of lowercased key strings to values parsed from a
leading YAML front matter block, or nil when there is none.  Only the
flat subset (key: value, and | or > block scalars) is understood.  An
opening `---' with no closing one is no front matter, and the whole text
is the body."
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
                                          (harness-skills-scan--unquote val))))
                (push current fields)))
             ((string-blank-p line) nil)
             (t (setq current nil))))
          (cons (nreverse fields) (substring text after)))))))

(defun harness-skills-scan-first-paragraph (body)
  "Return the first paragraph of BODY as a single line, skipping headings."
  (let ((paragraphs (split-string body "\n[ \t]*\n" t "[ \t\n]+")))
    (or (cl-loop for p in paragraphs
                 for text = (string-join (split-string p "\n" t "[ \t]+") " ")
                 unless (or (string-prefix-p "#" text) (string-empty-p text))
                 return text)
        (and (car paragraphs)
             (string-trim (replace-regexp-in-string "\\`#+[ \t]*" "" (car paragraphs))))
        "")))

(defun harness-skills-scan--nested-field (fields key)
  "Return KEY's value from FIELDS' flattened `metadata' text, or nil.
An Agent Skills skill may write `metadata: {version: 1.0}' over several
lines; the flat parser keeps them as one string, and this reads the
version out of it."
  (when-let* ((metadata (cdr (assoc "metadata" fields))))
    (when (string-match (format "\\(?:^\\|[ ,{]\\)%s[ \t]*:[ \t]*\\([^,}]*\\)" (regexp-quote key))
                        metadata)
      (harness-skills-scan--name (harness-skills-scan--unquote (match-string 1 metadata))))))

(defun harness-skills-scan-version (fields)
  "Return the explicit version FIELDS declares, or nil."
  (or (harness-skills-scan--name (cdr (assoc "version" fields)))
      (harness-skills-scan--nested-field fields "version")))

(defun harness-skills-scan-version-matches-p (skill version)
  "Non-nil when SKILL is VERSION, by its explicit version or its fingerprint.
A version that is a fingerprint prefix matches it, so `@fp-1a2b3c4d' pins
a skill that declares no version; nothing else does."
  (let ((entry-version (plist-get skill :version))
        (key (plist-get skill :version-key))
        (fingerprint (plist-get skill :fingerprint)))
    (and (stringp version)
         (or (and entry-version (string-equal version entry-version))
             (and key (string-equal version key))
             (and fingerprint (string-prefix-p version fingerprint))
             (and fingerprint (string-equal version fingerprint))))))

;;;; Reading a skill directory

(defun harness-skills-scan--diagnostic (skill code text)
  "Add a diagnostic of CODE and TEXT to SKILL, bounded, and return SKILL."
  (let ((diagnostics (plist-get skill :diagnostics)))
    (when (and (< (length diagnostics) harness-skills-scan--max-diagnostics)
               (not (cl-some (lambda (d) (equal (plist-get d :code) code)) diagnostics)))
      (plist-put skill :diagnostics
                 (append diagnostics
                         (list (list :code (symbol-name code)
                                     :text (harness-truncate-end
                                            (format "%s" text)
                                            harness-skills-scan--max-diagnostic-chars)))))))
  skill)

(defun harness-skills-scan--size (path)
  "Return the size of PATH in bytes, or nil."
  (let ((attrs (file-attributes path)))
    (and attrs (file-regular-p path) (file-attribute-size attrs))))

(defun harness-skills-scan--text (path max)
  "Return the text of PATH when it is a regular file no larger than MAX.
Return (TEXT . SIZE) or (nil . SIZE) when it is too large or unreadable;
SIZE is nil when PATH is not a regular file."
  (let ((size (harness-skills-scan--size path)))
    (if (and size (<= size max))
        (cons (harness-read-file path) size)
      (cons nil size))))

(defun harness-skills-scan-files (dir)
  "Return the supporting files of skill directory DIR, as relative names.
They are sorted, no deeper than `harness-skills-scan-max-depth', dot
files left out, and at most `harness-skills-scan-max-files' of them
within `harness-skills-scan-max-files-bytes'.  Return (FILES . TRUNCATED)
where TRUNCATED says the bounds cut the list."
  (let* ((dir (harness-skills-scan--directory dir))
         (seen nil)
         (out nil)
         (total 0)
         (truncated nil)
         (stack (list (cons dir 0))))
    (while (and stack (not truncated))
      (let* ((pair (pop stack))
             (current (car pair))
             (depth (cdr pair)))
        (dolist (entry (ignore-errors (directory-files current t "\\`[^.]" t)))
          (unless truncated
            (cond
             ((member entry seen) nil)
             ((and (file-directory-p entry) (not (file-symlink-p entry)))
              (push entry seen)
              (if (< depth harness-skills-scan-max-depth)
                  (push (cons (harness-skills-scan--directory entry) (1+ depth)) stack)
                (setq truncated t)))
             ((file-regular-p entry)
              (push entry seen)
              (let* ((rel (file-relative-name entry dir))
                     (size (or (harness-skills-scan--size entry) 0)))
                (cond
                 ((>= (length out) harness-skills-scan-max-files) (setq truncated t))
                 ((> (+ total size) harness-skills-scan-max-files-bytes) (setq truncated t))
                 (t (setq total (+ total size))
                    (push rel out))))))))))
    (cons (sort out #'string<) truncated)))

(defun harness-skills-scan--fingerprint (text files dir)
  "Return the fingerprint of a skill whose SKILL.md is TEXT, with FILES in DIR.
It hashes the SKILL.md bytes, each file's relative name and each one's
size, so it needs no clock and two machines can compare their copies."
  (let ((material (concat text "\0"
                          (mapconcat (lambda (file)
                                       (format "%s\0%s\0" file
                                               (or (harness-skills-scan--size
                                                    (expand-file-name file dir))
                                                   0)))
                                     files ""))))
    (concat "fp-" (substring (secure-hash 'sha256 material) 0 32))))

(defun harness-skills-scan--id (root source origin relative)
  "Return the stable id of a skill at RELATIVE under ROOT, from SOURCE and ORIGIN.
It names where the skill is on its computer -- the root that holds it,
its source and its origin -- never what the skill is called and never
when it was read.  So it survives a rename of the declared name, a change
of the description or the content, and a reconnect; and two copies of one
skill in two roots, such as two versions of a plugin, stay two skills.  A
skill directory that is moved or renamed under its root is a different
skill, and its old id is removed when the owner reports again."
  (concat "sk-" (substring (secure-hash 'sha1 (format "%s\0%s\0%s\0%s"
                                                       (or root "")
                                                       source origin relative))
                              0 16)))

(defun harness-skills-scan-read (dir &optional entry)
  "Read the skill in DIR, described by ENTRY, or return nil.
The result is a plist of metadata and content: `:id', `:name',
`:description', `:source', `:origin', `:dir', `:file', `:root',
`:relative', `:version', `:version-source', `:version-key',
`:fingerprint', `:files', `:files-truncated', `:bytes', `:content',
`:fields' and `:diagnostics'.  A SKILL.md that cannot be read, or is
larger than `harness-skills-scan-max-file-bytes', returns nil; a
malformed one returns the skill with diagnostics, so one bad skill
cannot break a scan."
  (let* ((entry (harness-skills-scan--entry entry))
         (dir (harness-skills-scan--directory dir))
         (file (expand-file-name harness-skills-scan-file-name dir))
         (size (harness-skills-scan--size file))
         (text (and size (<= size harness-skills-scan-max-file-bytes)
                    (harness-read-file file))))
    (when text
      (let* ((parsed (harness-skills-scan-parse-front-matter text))
             (fields (car parsed))
             (body (cdr parsed))
             (dirname (file-name-nondirectory (directory-file-name dir)))
             (declared (harness-skills-scan--name (cdr (assoc "name" fields))))
             (name (or declared dirname))
             (description (let ((d (harness-skills-scan--name (cdr (assoc "description" fields)))))
                            (or d (harness-skills-scan-first-paragraph body))))
             (source (or (plist-get entry :source) 'global))
             (origin (or (plist-get entry :origin) (symbol-name source)))
             (root (plist-get entry :dir))
             (relative (if root
                           (file-relative-name (directory-file-name dir)
                                               (directory-file-name root))
                         (file-name-nondirectory (directory-file-name dir))))
             (listing (harness-skills-scan-files dir))
             (files (delq nil (mapcar (lambda (f)
                                        (unless (string= f harness-skills-scan-file-name) f))
                                      (car listing))))
             (fingerprint (harness-skills-scan--fingerprint text files dir))
             (version (harness-skills-scan-version fields))
             (skill (list :id (harness-skills-scan--id root source origin relative)
                          :name name :description (harness-truncate-end description
                                                                      harness-skills-scan--description-limit)
                          :source source :origin origin
                          :dir dir :file file :root root :relative relative
                          :within (plist-get entry :within)
                          :contained (harness-skills-scan-contained-p
                                      dir (plist-get entry :within))
                          :version version
                          :version-source (if version "explicit" "fingerprint")
                          :version-key (or version (concat "fp-" (substring fingerprint 3 11)))
                          :fingerprint fingerprint
                          :files files :files-truncated (and (cdr listing) t)
                          :bytes size :content body :fields fields
                          :diagnostics nil)))
        (unless (string-prefix-p "---" text)
          (harness-skills-scan--diagnostic skill 'no-front-matter
                                          "no front matter: the name is the directory and the description its first paragraph"))
        (unless declared
          (harness-skills-scan--diagnostic skill 'name-from-directory
                                          "no declared name: the directory's name stands in"))
        (when (and declared (> (length declared) 80))
          (harness-skills-scan--diagnostic skill 'name-too-long
                                          "the declared name is longer than 80 characters"))
        (when (and declared (string-match-p "[\0\n\t]" declared))
          (harness-skills-scan--diagnostic skill 'name-malformed
                                          "the declared name holds a line break, a tab or a null byte")
          (plist-put skill :name dirname))
        (when (string-empty-p description)
          (harness-skills-scan--diagnostic skill 'no-description
                                          "no description: search finds it by name alone"))
        (when (> (length (or (cdr (assoc "description" fields)) ""))
                 harness-skills-scan--description-limit)
          (harness-skills-scan--diagnostic skill 'description-truncated
                                          "the description is longer than the listing keeps"))
        (when (cdr listing)
          (harness-skills-scan--diagnostic skill 'files-truncated
                                          "the supporting files are more, or larger, than one listing keeps"))
        skill))))

(defun harness-skills-scan-root (entry)
  "Return the skills under ENTRY's directory, newest metadata first by name.
Each is what `harness-skills-scan-read' returns, sorted by name and then
directory.  A skill directory whose SKILL.md cannot be read is left out
with a diagnostic entry of its own (`:id' nil, `:error' text), so the
scan says what it skipped."
  (let* ((entry (harness-skills-scan--entry entry))
         (dir (plist-get entry :dir))
         (out nil)
         (count 0)
         (limit harness-skills-scan-max-skills)
         (truncated nil))
    (when (and dir (file-directory-p dir))
      (dolist (sub (sort (ignore-errors (directory-files dir t "\\`[^.]" t)) #'string<))
        (when (and (not truncated)
                   (file-directory-p sub)
                   (file-readable-p (expand-file-name harness-skills-scan-file-name sub)))
          (if (>= count limit)
              (setq truncated t)
            (cl-incf count)
            (let* ((error-entry (lambda (text)
                                  (list :id nil :dir (harness-skills-scan--directory sub)
                                        :source (plist-get entry :source)
                                        :origin (plist-get entry :origin)
                                        :error text)))
                   (skill (condition-case err
                              (or (harness-skills-scan-read sub entry)
                                  (funcall error-entry
                                           (format "its %s is no file that can be read"
                                                   harness-skills-scan-file-name)))
                            (error (funcall error-entry (harness-error-message err))))))
              (when skill (push skill out))))))
      (when truncated
        (push (list :id nil :dir dir :source (plist-get entry :source)
                    :origin (plist-get entry :origin)
                    :error (format "more than %d skills here; the rest are not registered" limit))
              out)))
    (sort (nreverse out)
          (lambda (a b)
            (let ((an (or (plist-get a :name) "")) (bn (or (plist-get b :name) "")))
              (if (string-equal an bn)
                  (string< (or (plist-get a :dir) "") (or (plist-get b :dir) ""))
                (string< an bn)))))))

(defun harness-skills-scan (entries)
  "Return every skill under ENTRIES, in search order.
ENTRIES are (`:dir' `:source' `:origin' `:within') plists, as
`harness-skills-scan-entries' makes them; a missing directory holds
none.  The result keeps the order of ENTRIES and, within one, the order
of `harness-skills-scan-root', and holds no duplicate directory."
  (let ((out nil) (seen nil))
    (dolist (entry entries)
      (let ((entry (harness-skills-scan--entry entry)))
        (when (and entry (not (member (plist-get entry :dir) seen)))
          (push (plist-get entry :dir) seen)
          (setq out (append out (harness-skills-scan-root entry))))))
    out))

(defun harness-skills-scan-sort (skills)
  "Return SKILLS in listing order: project, global, plugin, then by name."
  (let ((rank (lambda (s)
                (alist-get (plist-get s :source) harness-skills-scan-source-rank 1))))
    (sort (append skills nil)
          (lambda (a b)
            (let ((ar (funcall rank a)) (br (funcall rank b)))
              (cond ((/= ar br) (< ar br))
                    ((not (string-equal (or (plist-get a :name) "")
                                        (or (plist-get b :name) "")))
                     (string< (or (plist-get a :name) "") (or (plist-get b :name) "")))
                    ((not (string-equal (or (plist-get a :origin) "")
                                        (or (plist-get b :origin) "")))
                     (string< (or (plist-get a :origin) "") (or (plist-get b :origin) "")))
                    (t (string< (or (plist-get a :dir) "") (or (plist-get b :dir) "")))))))))

;;;; What a skill says about itself, for a listing

(defun harness-skills-scan-summary (skill)
  "Return SKILL as a listing plist: what names it, and what it is.
No content and no body: a listing is metadata.  The fields a client of
the harness reads are stable, and `:properties' is the same metadata
under the names a computer's resource carries."
  (list :id (plist-get skill :id)
        :name (plist-get skill :name)
        :description (plist-get skill :description)
        :source (plist-get skill :source)
        :origin (plist-get skill :origin)
        :version (plist-get skill :version)
        :version-source (plist-get skill :version-source)
        :version-key (plist-get skill :version-key)
        :fingerprint (plist-get skill :fingerprint)
        :files (plist-get skill :files)
        :files-truncated (and (plist-get skill :files-truncated) t)
        :path (plist-get skill :dir)
        :relative (plist-get skill :relative)
        :bytes (plist-get skill :bytes)
        :diagnostics (plist-get skill :diagnostics)))

(defun harness-skills-scan-properties (skill)
  "Return SKILL's metadata as the `:properties' of a computer resource.
It is the summary without the local `:path', so what crosses the wire
says where in its own convention a skill is, not what the scanning
machine's disk is called."
  (let ((summary (harness-skills-scan-summary skill)))
    (harness-plist-remove (copy-sequence summary) :path)))

(provide 'harness-skills-scan)
;;; harness-skills-scan.el ends here
