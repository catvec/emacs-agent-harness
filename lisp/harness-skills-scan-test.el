;;; harness-skills-scan-test.el --- Tests for the shared skill scanner  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; `harness-skills-scan' is what both sides of the process split use to
;; find skills, read their metadata and identify them: the harness
;; process for its own, and a client for the computer it runs on.  These
;; tests hold it to the contracts the two rely on: the documented roots,
;; the front-matter fallbacks, bounded diagnostics that isolate a bad
;; skill, an id that survives a rename and an edit, a fingerprint that
;; two machines can compare, and containment that never reads outside a
;; skill.  Fixtures are temporary directories; nothing privileged runs.

;;; Code:

(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-skills-scan)

(defvar harness-skills-scan-plugins-directory
  "Where the tests put Claude Code's plugin cache, without the user's.")

(defun harness-skills-scan-test--write (base name content)
  "Create skill NAME under BASE with CONTENT in its SKILL.md; return its dir."
  (let ((dir (file-name-as-directory (expand-file-name name base))))
    (make-directory dir t)
    (with-temp-file (expand-file-name "SKILL.md" dir) (insert content))
    dir))

(defun harness-skills-scan-test--entry (dir &optional source origin within)
  "Return a scan entry for DIR with SOURCE, ORIGIN and WITHIN."
  (list :dir dir :source (or source 'global) :origin (or origin "test")
        :within within))

(defmacro harness-skills-scan-test-with-root (&rest body)
  "Run BODY with `root' bound to a fresh directory holding four skills.
The skills cover explicit front matter, no front matter, a malformed
name and a large supporting-file list.  `root' is deleted afterwards."
  (declare (indent 0))
  `(let ((root (harness-test-temp-dir)))
     (unwind-protect
         (progn
           (harness-skills-scan-test--write
            root "commit"
            "---\nname: commit\ndescription: Write a conventional commit.\nversion: \"1.4\"\n---\n# Commit\n\nRun `git diff --cached`.\n")
           (harness-skills-scan-test--write
            root "notes"
            "---\nmetadata:\n  version: \"0.3\"\ndescription: >\n  Notes that\n  span lines\n---\nBody of the notes.\n")
           (harness-skills-scan-test--write
            root "bare"
            "# Deploy notes\n\nSummarise what a deploy changes.\n\nMore detail.\n")
           (harness-skills-scan-test--write
            root "odd"
            "---\nname: \"bad\tname\"\ndescription: \"\"\n---\nbody\n")
           ,@body)
       (ignore-errors (delete-directory root t)))))

(ert-deftest harness-skills-scan-reads-front-matter-and-falls-back ()
  "An explicit version, a description with a block scalar, the directory
name when no name is declared and the first paragraph when there is no
description: the layouts the conventions document, and no others."
  (harness-skills-scan-test-with-root
    (let* ((commit (harness-skills-scan-read (expand-file-name "commit" root)
                                             (harness-skills-scan-test--entry root)))
           (notes (harness-skills-scan-read (expand-file-name "notes" root)
                                            (harness-skills-scan-test--entry root)))
           (bare (harness-skills-scan-read (expand-file-name "bare" root)
                                           (harness-skills-scan-test--entry root))))
      (should (equal "commit" (plist-get commit :name)))
      (should (equal "1.4" (plist-get commit :version)))
      (should (equal "explicit" (plist-get commit :version-source)))
      (should (equal "1.4" (plist-get commit :version-key)))
      (should (string-prefix-p "fp-" (plist-get commit :fingerprint)))
      (should (equal "# Commit\n\nRun `git diff --cached`.\n" (plist-get commit :content)))
      (should-not (string-search "---" (plist-get commit :content)))
      ;; A nested metadata block still yields the version the convention
      ;; writes there, and a folded description its one line.
      (should (equal "0.3" (plist-get notes :version)))
      (should (equal "Notes that span lines" (plist-get notes :description)))
      ;; No front matter: the directory's name and the first paragraph.
      (should (equal "bare" (plist-get bare :name)))
      (should (equal "Summarise what a deploy changes." (plist-get bare :description)))
      (should-not (plist-get bare :version))
      (should (string-prefix-p "fp-" (plist-get bare :version-key)))
      ;; The provenance the entry named is the provenance kept.
      (should (eq 'global (plist-get commit :source)))
      (should (equal "test" (plist-get commit :origin))))))

(ert-deftest harness-skills-scan-malformed-metadata-is-bounded-and-isolated ()
  "A malformed name is reported, the skill still lists, and the scan
goes on: one bad skill never breaks a registration."
  (harness-skills-scan-test-with-root
    (let* ((odd (expand-file-name "odd" root))
           (skill (harness-skills-scan-read odd (harness-skills-scan-test--entry root)))
           (codes (mapcar (lambda (d) (plist-get d :code)) (plist-get skill :diagnostics))))
      ;; The declared name held a line break: the directory's name stands
      ;; in, and the diagnostic says so, bounded to a short line.
      (should (equal "odd" (plist-get skill :name)))
      (should (member "name-malformed" codes))
      ;; The empty description falls back to the body, and says nothing:
      ;; the fallback is the convention, not a fault.
      (should (equal "body" (plist-get skill :description)))
      (should-not (member "no-description" codes))
      (should (<= (length (plist-get skill :diagnostics))
                  harness-skills-scan--max-diagnostics))
      (dolist (diagnostic (plist-get skill :diagnostics))
        (should (<= (length (plist-get diagnostic :text))
                    harness-skills-scan--max-diagnostic-chars)))
      ;; Sorted, and every good skill beside it still read.
      (should (equal '("bare" "commit" "notes" "odd")
                     (mapcar (lambda (s) (plist-get s :name))
                             (harness-skills-scan (list (harness-skills-scan-test--entry root)))))))
    ;; A SKILL.md that cannot be read is an error entry, not a failure of
    ;; the whole scan.
    (let* ((broken (expand-file-name "broken" root))
           (scan (progn (make-directory broken t)
                        (harness-skills-scan (list (harness-skills-scan-test--entry root))))))
      ;; No SKILL.md at all: not a skill directory, so not in the scan.
      (should-not (cl-find broken scan :key (lambda (s) (plist-get s :dir)))))))

(ert-deftest harness-skills-scan-unreadable-skill-is-reported-not-raised ()
  "A skill whose SKILL.md is unreadable becomes an error entry of the scan."
  (let* ((root (harness-test-temp-dir))
         (dir (file-name-as-directory (expand-file-name "locked" root))))
    (unwind-protect
        (progn
          (make-directory dir t)
          ;; A directory named SKILL.md is readable as a path but is no
          ;; file: reading signals, and the scan reports it.
          (make-directory (expand-file-name "SKILL.md" dir) t)
          (let ((scan (harness-skills-scan (list (harness-skills-scan-test--entry root)))))
            (should (= 1 (length scan)))
            (should-not (plist-get (car scan) :id))
            (should (plist-get (car scan) :error))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest harness-skills-scan-identity-survives-rename-and-edit ()
  "The id names the skill's place, not its name or its content.
Renaming the declared name, rewriting the description or editing the
body keeps it; the fingerprint changes with the content."
  (harness-skills-scan-test-with-root
    (let* ((dir (expand-file-name "commit" root))
           (entry (harness-skills-scan-test--entry root))
           (first (harness-skills-scan-read dir entry)))
      ;; A changed name and body: same id, new fingerprint.
      (with-temp-file (expand-file-name "SKILL.md" dir)
        (insert "---\nname: commit-message\ndescription: Reworded.\n---\nDifferent.\n"))
      (let ((second (harness-skills-scan-read dir entry)))
        (should (equal (plist-get first :id) (plist-get second :id)))
        (should-not (equal (plist-get first :fingerprint) (plist-get second :fingerprint)))
        (should (equal "commit-message" (plist-get second :name)))
        ;; The old version is still identifiable by its fingerprint, which
        ;; is what a pin named: it is not served as the new one.
        (should-not (harness-skills-scan-version-matches-p
                     second (plist-get first :version)))
        ;; A pin may name a prefix of the fingerprint a version had.
        (should (harness-skills-scan-version-matches-p
                 first (substring (plist-get first :fingerprint) 0 11))))
      ;; A different root is a different skill, even with one path: two
      ;; versions of one plugin never collide.
      (let ((other (harness-skills-scan-read
                    dir (harness-skills-scan-test--entry dir 'plugin "market/tools"))))
        (should-not (equal (plist-get first :id) (plist-get other :id)))))))

(ert-deftest harness-skills-scan-fingerprint-covers-supporting-files ()
  "A supporting file's name or size changes the fingerprint, so two
computers compare their copies without trusting a clock."
  (harness-skills-scan-test-with-root
    (let* ((dir (expand-file-name "commit" root))
           (entry (harness-skills-scan-test--entry root))
           (first (harness-skills-scan-read dir entry)))
      (with-temp-file (expand-file-name "templates.md" dir) (insert "- one\n"))
      (let* ((second (harness-skills-scan-read dir entry))
             (second-fingerprint (plist-get second :fingerprint)))
        (should-not (equal (plist-get first :fingerprint) second-fingerprint))
        (should (equal '("templates.md") (plist-get second :files)))
        ;; The same file, a byte longer: another fingerprint.
        (with-temp-file (expand-file-name "templates.md" dir) (insert "- one\n- two\n"))
        (should-not (equal second-fingerprint
                           (plist-get (harness-skills-scan-read dir entry) :fingerprint))))
      ;; A SKILL.md too large is no skill at all.
      (let ((harness-skills-scan-max-file-bytes 10))
        (should-not (harness-skills-scan-read dir entry))))))

(ert-deftest harness-skills-scan-bounds-what-it-lists ()
  "The listing of supporting files is bounded in number and size, and a
listing that was cut says so; the SKILL.md is never among them."
  (harness-skills-scan-test-with-root
    (let* ((dir (expand-file-name "bare" root))
           (entry (harness-skills-scan-test--entry root)))
      (dotimes (i 6)
        (with-temp-file (expand-file-name (format "file-%d.txt" i) dir)
          (insert (make-string 8 ?x))))
      ;; The skill's own file is no supporting file, so it takes no place
      ;; of the bound: 3 leaves 3 files, not 2 and the skill itself.
      (let ((harness-skills-scan-max-files 3))
        (let ((skill (harness-skills-scan-read dir entry)))
          (should (equal '("file-0.txt" "file-1.txt" "file-2.txt")
                         (plist-get skill :files)))
          (should (plist-get skill :files-truncated))
          (should (cl-find "files-truncated"
                           (mapcar (lambda (d) (plist-get d :code)) (plist-get skill :diagnostics))
                           :test #'equal))))
      ;; No bound reached: every supporting file, the skill's own not among
      ;; them, and nothing truncated.  It counts against neither bound.
      (let ((harness-skills-scan-max-files 200)
            (harness-skills-scan-max-files-bytes 100))
        (let ((skill (harness-skills-scan-read dir entry)))
          (should-not (plist-get skill :files-truncated))
          (should-not (cl-intersection '("SKILL.md") (plist-get skill :files) :test #'equal))
          (should (equal (sort (copy-sequence (plist-get skill :files)) #'string<)
                         (plist-get skill :files))))))))

(ert-deftest harness-skills-scan-roots-are-the-documented-conventions ()
  "The user's four conventions and the project's four, each with the
origin a listing names, and the plugins when they are asked for."
  (let* ((cwd (harness-test-temp-dir))
         (entries (harness-skills-scan-entries cwd)))
    (unwind-protect
        (progn
          (should (equal '("claude" "harness" "agents" "copilot")
                         (mapcar (lambda (e) (plist-get e :origin))
                                 (cl-remove-if-not (lambda (e) (eq (plist-get e :source) 'global))
                                                   entries))))
          (should (equal '("claude" "harness" "agents" "copilot")
                         (mapcar (lambda (e) (plist-get e :origin))
                                 (cl-remove-if-not (lambda (e) (eq (plist-get e :source) 'project))
                                                   entries))))
          ;; A project entry says what it may not leave.
          (dolist (entry (cl-remove-if-not (lambda (e) (eq (plist-get e :source) 'project))
                                           entries))
            (should (plist-get entry :within))))
      (ignore-errors (delete-directory cwd t)))
    ;; Without a cwd there is no project.
    (should-not (cl-find 'project (harness-skills-scan-entries nil)
                         :key (lambda (e) (plist-get e :source))))))

(ert-deftest harness-skills-scan-plugin-entries-name-their-plugin ()
  "A plugin's skills are read where Claude Code installs them, the
newest version first, none orphaned, and each names its marketplace and
plugin."
  (let ((root (harness-test-temp-dir)))
    (unwind-protect
        (let ((harness-skills-scan-plugins-directory root))
          (dolist (version '("0.9.0" "1.0.0" "1.1.0"))
            (harness-skills-scan-test--write
             (expand-file-name (format "cache/market/tools/%s/skills" version) root)
             "lint" (format "---\ndescription: lint %s\n---\nbody\n" version)))
          (make-directory (expand-file-name "cache/market/hooks/1.0.0/hooks" root) t)
          (with-temp-file (expand-file-name "cache/market/tools/1.0.0/.orphaned_at" root)
            (insert "1760000000000\n"))
          ;; The versions are set apart by their modification times.
          (set-file-times (expand-file-name "cache/market/tools/0.9.0" root)
                          (time-subtract (current-time) 7200))
          (set-file-times (expand-file-name "cache/market/tools/1.1.0" root) (current-time))
          (set-file-times (expand-file-name "cache/market/tools/1.0.0" root)
                          (time-subtract (current-time) 3600))
          (let ((entries (harness-skills-scan-plugin-entries)))
            (should (equal '("market/tools" "market/tools")
                           (mapcar (lambda (e) (plist-get e :origin)) entries)))
            (should (equal (list (expand-file-name "cache/market/tools/1.1.0/skills" root)
                                 (expand-file-name "cache/market/tools/0.9.0/skills" root))
                           (mapcar (lambda (e) (plist-get e :dir)) entries)))))
      (ignore-errors (delete-directory root t)))))

(ert-deftest harness-skills-scan-contained-refuses-home-and-escapes ()
  "A directory that is or holds the home directory is not contained, and
neither is one a link leads out of its base; a path a link leads out of
its skill is not inside it."
  (let* ((home (harness-test-temp-dir))
         (process-environment (cons (concat "HOME=" (directory-file-name home))
                                    process-environment))
         (outside (harness-test-temp-dir))
         (project (harness-test-temp-dir)))
    (unwind-protect
        (progn
          (should-not (harness-skills-scan-contained-p home))
          ;; A user's convention directory is inside the home and fine;
          ;; the home itself, or a directory holding it, is not.
          (should (harness-skills-scan-contained-p (expand-file-name ".claude/skills" home) home))
          (should-not (harness-skills-scan-contained-p (file-name-directory
                                                        (directory-file-name home))
                                                       home))
          (should (harness-skills-scan-contained-p (expand-file-name ".claude/skills" project) project))
          ;; A directory linked out of its base is no longer contained.
          (let ((link (expand-file-name ".claude/skills" project)))
            (make-directory (file-name-directory link) t)
            (make-symbolic-link outside link)
            (should-not (harness-skills-scan-contained-p link project)))
          ;; A file linked out of a skill is not inside the skill.
          (let* ((dir (file-name-as-directory (expand-file-name "skill" project)))
                 (secret (expand-file-name "secret.txt" outside)))
            (make-directory dir t)
            (with-temp-file secret (insert "s3cret\n"))
            (make-symbolic-link secret (expand-file-name "leak.txt" dir))
            (should (harness-skills-scan-inside-p dir (expand-file-name "a.txt" dir)))
            (should-not (harness-skills-scan-inside-p dir (expand-file-name "leak.txt" dir)))
            (should-not (harness-skills-scan-inside-p dir (expand-file-name "../outside.txt" dir)))))
      (ignore-errors (delete-directory home t))
      (ignore-errors (delete-directory outside t))
      (ignore-errors (delete-directory project t)))))

(ert-deftest harness-skills-scan-properties-carry-no-local-path ()
  "What crosses the wire is metadata: where in its convention the skill
is, not what this machine's disk is called."
  (harness-skills-scan-test-with-root
    (let* ((skill (harness-skills-scan-read (expand-file-name "commit" root)
                                            (harness-skills-scan-test--entry root)))
           (properties (harness-skills-scan-properties skill)))
      (should (equal "commit" (plist-get properties :name)))
      (should (equal "1.4" (plist-get properties :version)))
      (should (string-prefix-p "fp-" (plist-get properties :fingerprint)))
      (should (equal "commit" (plist-get properties :relative)))
      (should-not (plist-member properties :path))
      (should-not (plist-member properties :content))
      (should-not (string-search root (format "%S" properties))))))

(provide 'harness-skills-scan-test)
;;; harness-skills-scan-test.el ends here
