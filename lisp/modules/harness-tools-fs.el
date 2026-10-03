;;; harness-tools-fs.el --- File system tools  -*- lexical-binding: t; -*-

;;; Commentary:

;; The file tools a model uses most: read_file, write_file, edit_file,
;; list_dir, glob, grep and file_info.  Everything runs on Emacs file
;; primitives (`insert-file-contents', `write-region',
;; `directory-files-recursively', `file-expand-wildcards'), so a
;; session whose cwd carries a TRAMP prefix works on the remote host
;; without any tool knowing about it.  Only grep spawns a process, and
;; it does so asynchronously through `harness-run-command' with the
;; session cwd, which also lands on the remote host.
;;
;; Every path is resolved with `harness-tools-resolve-path' against
;; the session cwd and host, and every tool declares the paths it
;; touches so the permission jail can judge them.
;;
;; Reads are guarded against context bombs: read_file trims the
;; requested range to `harness-tools-max-output-chars' at a line
;; boundary and says where to continue, other tools rely on the
;; generic guard in `tools/execute'.
;;
;; read_file also returns media as `:attachments', which the chat
;; shows the user: an image, a video (as a poster the user can play;
;; the model is told what it is and how to look inside), and the
;; picture of an SVG read from its top, whose text the model reads.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'mailcap)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defcustom harness-tools-fs-glob-limit 500
  "Maximum number of paths returned by the glob tool."
  :type 'integer :group 'harness)

(defcustom harness-tools-fs-list-limit 2000
  "Maximum number of entries listed by list_dir before it stops."
  :type 'integer :group 'harness)

(defcustom harness-tools-fs-grep-timeout 60
  "Seconds a grep may run before it is killed."
  :type 'number :group 'harness)

(defcustom harness-tools-fs-binary-probe-bytes 8000
  "How many leading bytes are inspected to decide whether a file is binary."
  :type 'integer :group 'harness)

(defcustom harness-tools-fs-line-count-limit (* 20 1024 1024)
  "Byte size above which file_info stops counting lines."
  :type 'integer :group 'harness)

;;;; Helpers

(defun harness-tools-fs--path (input ctx &optional key)
  "Return the absolute path for KEY (default :path) of INPUT under CTX."
  (let ((p (plist-get input (or key :path))))
    (when (or (null p) (not (stringp p)) (string-empty-p p))
      (error "Missing %s" (substring (symbol-name (or key :path)) 1)))
    (harness-tools-resolve-path p ctx)))

(defun harness-tools-fs--display (path ctx)
  "Return PATH relative to CTX's cwd when inside it, for messages."
  (let ((cwd (plist-get ctx :cwd)))
    (if (and cwd (harness-path-within-p cwd path))
        (let ((rel (file-relative-name path cwd)))
          (if (string= rel ".") "." rel))
      (abbreviate-file-name path))))

(defun harness-tools-fs--int (input key default)
  "Return the integer for KEY in INPUT, or DEFAULT."
  (let ((v (plist-get input key)))
    (cond ((integerp v) v)
          ((numberp v) (truncate v))
          ((and (stringp v) (string-match-p "\\`-?[0-9]+\\'" v)) (string-to-number v))
          (t default))))

(defun harness-tools-fs--mime (path)
  "Return the MIME type guessed from PATH's extension, or nil."
  (let ((ext (file-name-extension path)))
    (and ext (mailcap-extension-to-mime (concat "." (downcase ext))))))

(defun harness-tools-fs--image-p (path)
  "Non-nil when PATH looks like a raster image by extension."
  (let ((mime (harness-tools-fs--mime path)))
    (and mime (string-prefix-p "image/" mime)
         (not (string= mime "image/svg+xml")))))

(defun harness-tools-fs--svg-p (path)
  "Non-nil when PATH is an SVG image by extension (a text file)."
  (equal (harness-tools-fs--mime path) "image/svg+xml"))

(defun harness-tools-fs--binary-p (path)
  "Non-nil when the first bytes of PATH contain a NUL character."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (condition-case nil
        (insert-file-contents-literally path nil 0 harness-tools-fs-binary-probe-bytes)
      (error nil))
    (goto-char (point-min))
    (and (search-forward "\0" nil t) t)))

(defun harness-tools-fs--video-p (path)
  "Non-nil when PATH is a video: a video type by extension, binary inside.
The content counts too, so a text file whose extension some MIME table
gives to video (TypeScript's .ts, an MPEG transport stream elsewhere)
stays a text file."
  (let ((mime (harness-tools-fs--mime path)))
    (and mime (string-prefix-p "video/" mime)
         (harness-tools-fs--binary-p path))))

(defun harness-tools-fs--attachment (path mime)
  "Return the attachment of PATH, of type MIME, that a UI shows."
  (list :path path :mime mime :size (harness-file-size path)
        :name (file-name-nondirectory path)))

(defun harness-tools-fs--insert-text (path)
  "Insert the contents of text file PATH into the current buffer."
  (let ((coding-system-for-read 'utf-8-auto))
    (insert-file-contents path)))

(defun harness-tools-fs--number-lines (lines start)
  "Return LINES prefixed with line numbers counting from START, like `cat -n'."
  (let ((n start))
    (mapconcat (lambda (l) (prog1 (format "%6d\t%s" n l) (cl-incf n)))
               lines "\n")))

(defun harness-tools-fs--write (path content)
  "Write CONTENT to PATH creating parents, then announce it.
The UI reverts unmodified buffers visiting PATH on `tools/file-written'."
  (let ((dir (file-name-directory path)))
    (when (and dir (not (file-directory-p dir)))
      (make-directory dir t)))
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-buffer
      (insert content)
      (write-region (point-min) (point-max) path nil 'silent)))
  (harness-emit 'tools/file-written path))

;;;; read_file

(defun harness-tools-fs--read-range (path offset limit)
  "Return (TEXT FIRST LAST TOTAL) for PATH from line OFFSET, at most LIMIT lines.
TEXT is numbered and already trimmed to the output budget."
  (with-temp-buffer
    (harness-tools-fs--insert-text path)
    (let* ((total (count-lines (point-min) (point-max)))
           (first (max 1 offset))
           (last (if limit (min total (+ first limit -1)) total))
           (budget (max 200 (- harness-tools-max-output-chars 200)))
           (lines nil) (chars 0) (n first))
      (goto-char (point-min))
      (forward-line (1- first))
      (while (and (<= n last) (not (eobp)))
        (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
          (cl-incf chars (+ 8 (length line)))
          (if (and lines (> chars budget))
              (setq n (1+ last))       ; stop: over budget
            (push line lines)
            (cl-incf n)
            (forward-line 1))))
      (let ((shown-last (+ first (length lines) -1)))
        (list (harness-tools-fs--number-lines (nreverse lines) first)
              first shown-last last total)))))

(defun harness-tools-fs--read-file (input ctx)
  "Handler for read_file with INPUT under CTX."
  (let* ((path (harness-tools-fs--path input ctx))
         (shown (harness-tools-fs--display path ctx))
         (offset (harness-tools-fs--int input :offset 1))
         (limit (harness-tools-fs--int input :limit nil)))
    (cond
     ((file-directory-p path)
      (harness-tool-error (format "%s is a directory; use list_dir to see its contents" shown)))
     ((not (file-exists-p path))
      (harness-tool-error (format "File not found: %s (cwd %s). Check the path with list_dir or glob"
                                  shown (plist-get ctx :cwd))))
     ((not (file-readable-p path))
      (harness-tool-error (format "File not readable: %s" shown)))
     ((harness-tools-fs--image-p path)
      (let ((size (harness-file-size path)) (mime (harness-tools-fs--mime path)))
        (harness-tool-ok (format "Image %s (%s, %s) attached." shown mime (harness-format-bytes size))
                         :attachments (list (harness-tools-fs--attachment path mime)))))
     ;; The chat shows a video to the user, who can play it; the model
     ;; gets what it is and how to look inside.
     ((harness-tools-fs--video-p path)
      (let ((mime (harness-tools-fs--mime path)))
        (harness-tool-ok (format "Video %s (%s, %s) is shown to the user in the chat, who can play it there; read_file cannot show you its frames. To inspect it, use bash: ffprobe for its streams and duration, ffmpeg to extract frames."
                                 shown mime (harness-format-bytes (harness-file-size path)))
                         :attachments (list (harness-tools-fs--attachment path mime)))))
     ((harness-tools-fs--binary-p path)
      (harness-tool-error (format "%s is a binary file (%s); read_file only shows text. Use file_info for metadata or bash with `file`, `xxd` or `strings` to inspect it"
                                  shown (harness-format-bytes (harness-file-size path)))))
     ((and limit (< limit 1))
      (harness-tool-error "The limit must be at least 1"))
     (t
      (pcase-let* ((`(,text ,first ,shown-last ,wanted-last ,total)
                    (harness-tools-fs--read-range path offset limit))
                   ;; An SVG is text to the model and a picture to the
                   ;; user: a read from its top shows the user the image.
                   (shows (and (= first 1) (harness-tools-fs--svg-p path)
                               (list :attachments (list (harness-tools-fs--attachment path "image/svg+xml"))))))
        (cond
         ((and (zerop total) (= first 1))
          (harness-tool-ok (format "%s is empty (0 lines)" shown)))
         ((> first total)
          (harness-tool-error (format "offset %d is past the end of %s (%d lines)" first shown total)))
         ((< shown-last wanted-last)
          (apply #'harness-tool-ok
                 (format "%s\n\n[%s: showing lines %d-%d of %d; the requested range was too large for one read. Continue with offset %d, or use a smaller limit.]"
                         text shown first shown-last total (1+ shown-last))
                 :truncated (list :path path :lines (cons first shown-last) :total total)
                 shows))
         (t
          (apply #'harness-tool-ok
                 (if (and (= first 1) (= shown-last total))
                     text
                   (format "%s\n\n[%s: lines %d-%d of %d]" text shown first shown-last total))
                 shows))))))))

(defun harness-tools-fs--read-subject (input)
  "What a read_file call with INPUT reads: the path and the lines asked for."
  (when-let* ((path (plist-get input :path)))
    (let ((offset (harness-tools-fs--int input :offset nil))
          (limit (harness-tools-fs--int input :limit nil)))
      (format "%s%s" path
              (cond ((and offset limit) (format ":%d-%d" offset (+ offset limit -1)))
                    (offset (format ":%d-" offset))
                    (limit (format ":1-%d" limit))
                    (t ""))))))

(harness-define-tool "read_file"
  :label "Read file"
  :description "Read a text file. Output lines are prefixed with their line number. Use offset (1-based line) and limit (number of lines) to read a range of a large file; a read that would be too big is trimmed and tells you where to continue. Images are attached as images; a video is shown to the user, who can play it; other binary files are refused."
  :schema '(:type "object"
            :properties (:path (:type "string" :description "File path, absolute or relative to the working directory")
                         :offset (:type "integer" :description "First line to read (1-based). Default 1")
                         :limit (:type "integer" :description "Maximum number of lines to read. Default: the whole file, within the output budget"))
            :required ("path"))
  :kind 'read
  :coalescable t
  :paths (lambda (input) (list (plist-get input :path)))
  :subject #'harness-tools-fs--read-subject
  :handler #'harness-tools-fs--read-file)

;;;; write_file

(defun harness-tools-fs--write-file (input ctx)
  "Handler for write_file with INPUT under CTX."
  (let* ((path (harness-tools-fs--path input ctx))
         (content (plist-get input :content))
         (shown (harness-tools-fs--display path ctx)))
    (unless (stringp content) (error "Missing content"))
    (when (file-directory-p path)
      (error "%s is a directory" shown))
    (let ((existed (file-exists-p path)))
      (harness-tools-fs--write path content)
      (harness-tool-ok (format "%s %s (%d bytes, %d lines)"
                               (if existed "Overwrote" "Created") shown
                               (string-bytes content)
                               (if (string-empty-p content) 0
                                 (1+ (cl-count ?\n (string-remove-suffix "\n" content)))))
                       :meta (list :bytes (string-bytes content) :created (not existed))))))

(harness-define-tool "write_file"
  :label "Write file"
  :description "Write a whole file, creating it and any missing parent directories. Overwrites existing content; prefer edit_file for small changes to an existing file."
  :schema '(:type "object"
            :properties (:path (:type "string" :description "File path, absolute or relative to the working directory")
                         :content (:type "string" :description "The complete new contents of the file"))
            :required ("path" "content"))
  :kind 'write
  :paths (lambda (input) (list (plist-get input :path)))
  :subject (lambda (input) (when-let* ((path (plist-get input :path)))
                             (format "%s (%d bytes)" path (string-bytes (or (plist-get input :content) "")))))
  :handler #'harness-tools-fs--write-file)

;;;; edit_file

(defun harness-tools-fs--count-occurrences (needle)
  "Count literal occurrences of NEEDLE in the current buffer.
Return (COUNT . FIRST-POS)."
  (let ((count 0) (first nil) (case-fold-search nil))
    (save-excursion
      (goto-char (point-min))
      (while (search-forward needle nil t)
        (cl-incf count)
        (unless first (setq first (match-beginning 0)))))
    (cons count first)))

(defun harness-tools-fs--whitespace-fuzzy-p (needle)
  "Non-nil when NEEDLE matches the buffer once whitespace is normalised.
Used only to give a better error message."
  (let ((rx (mapconcat #'regexp-quote (split-string needle "[ \t\n]+" t) "[ \t\n]+"))
        (case-fold-search nil))
    (and (not (string-empty-p rx))
         (save-excursion (goto-char (point-min)) (re-search-forward rx nil t)))))

(defun harness-tools-fs--edit-file (input ctx)
  "Handler for edit_file with INPUT under CTX."
  (let* ((path (harness-tools-fs--path input ctx))
         (shown (harness-tools-fs--display path ctx))
         (old (plist-get input :old_string))
         (new (plist-get input :new_string))
         (all (harness-json-true-p (plist-get input :replace_all))))
    (cond
     ((not (stringp old)) (harness-tool-error "Missing old_string"))
     ((not (stringp new)) (harness-tool-error "Missing new_string"))
     ((string-empty-p old) (harness-tool-error "An empty old_string is not allowed; use write_file to create or replace a whole file"))
     ((string= old new) (harness-tool-error "Identical old_string and new_string; nothing to do"))
     ((file-directory-p path) (harness-tool-error (format "%s is a directory" shown)))
     ((not (file-exists-p path))
      (harness-tool-error (format "File not found: %s. Use write_file to create a new file" shown)))
     (t
      (with-temp-buffer
        (harness-tools-fs--insert-text path)
        (pcase-let ((`(,count . ,first) (harness-tools-fs--count-occurrences old)))
          (cond
           ((zerop count)
            (harness-tool-error
             (if (harness-tools-fs--whitespace-fuzzy-p old)
                 (format "old_string not found in %s exactly, but a match exists with different whitespace or indentation. Read the file and copy the text verbatim, including leading spaces and tabs" shown)
               (format "old_string not found in %s. Read the file (read_file) and copy the exact current text; it may have changed since you last saw it" shown))))
           ((and (> count 1) (not all))
            (harness-tool-error
             (format "old_string matches %d places in %s. Include more surrounding context so it is unique, or set replace_all to true to change every occurrence" count shown)))
           (t
            (let ((line (line-number-at-pos first)))
              (goto-char (point-min))
              (let ((case-fold-search nil))
                (while (search-forward old nil t)
                  (replace-match new t t)))
              (harness-tools-fs--write path (buffer-string))
              (harness-tool-ok
               (format "Edited %s: replaced %d occurrence%s%s"
                       shown count (if (= count 1) "" "s")
                       (if (= count 1) (format " at line %d" line) ""))
               :meta (list :replacements count :line line)))))))))))

(harness-define-tool "edit_file"
  :label "Edit file"
  :description "Replace an exact string in a file. old_string must match the current file text exactly (including whitespace) and, unless replace_all is true, must occur exactly once; include enough surrounding lines to make it unique."
  :schema '(:type "object"
            :properties (:path (:type "string" :description "File path, absolute or relative to the working directory")
                         :old_string (:type "string" :description "The exact text to replace")
                         :new_string (:type "string" :description "The replacement text")
                         :replace_all (:type "boolean" :description "Replace every occurrence instead of requiring a unique match. Default false"))
            :required ("path" "old_string" "new_string"))
  :kind 'write
  :paths (lambda (input) (list (plist-get input :path)))
  :subject (lambda (input) (plist-get input :path))
  :handler #'harness-tools-fs--edit-file)

;;;; list_dir

(defun harness-tools-fs--list-entries (dir depth prefix acc limit)
  "Collect entries of DIR down to DEPTH levels into ACC (a cons cell holder).
PREFIX is the relative path shown for entries; LIMIT caps the total."
  (let ((entries (condition-case nil
                     (directory-files dir t directory-files-no-dot-files-regexp t)
                   (error nil))))
    (dolist (full (sort entries #'string<))
      (let ((name (file-name-nondirectory full)))
        (unless (string= name ".git")
          (when (< (length (car acc)) limit)
            (let* ((attrs (file-attributes full))
                   (dirp (and attrs (eq t (file-attribute-type attrs))))
                   (link (and attrs (stringp (file-attribute-type attrs)))))
              (push (list :name (concat prefix name (if (file-directory-p full) "/" ""))
                          :size (and (not dirp) attrs (file-attribute-size attrs))
                          :link (and link (file-attribute-type attrs)))
                    (car acc))
              (when (and dirp (> depth 1))
                (harness-tools-fs--list-entries full (1- depth) (concat prefix name "/") acc limit)))))))))

(defun harness-tools-fs--list-dir (input ctx)
  "Handler for list_dir with INPUT under CTX."
  (let* ((path (harness-tools-resolve-path (or (plist-get input :path) ".") ctx))
         (shown (harness-tools-fs--display path ctx))
         (depth (max 1 (harness-tools-fs--int input :depth 1))))
    (cond
     ((not (file-exists-p path)) (harness-tool-error (format "Directory not found: %s" shown)))
     ((not (file-directory-p path))
      (harness-tool-error (format "%s is a file, not a directory; use read_file or file_info" shown)))
     (t
      (let ((acc (list nil)))
        (harness-tools-fs--list-entries path depth "" acc harness-tools-fs-list-limit)
        (let* ((entries (nreverse (car acc)))
               (n (length entries))
               (lines (mapcar (lambda (e)
                                (let ((name (plist-get e :name)))
                                  (cond ((plist-get e :link) (format "%s -> %s" name (plist-get e :link)))
                                        ((plist-get e :size) (format "%s  %s" name (harness-format-bytes (plist-get e :size))))
                                        (t name))))
                              entries)))
          (harness-tool-ok
           (if (zerop n)
               (format "%s is empty" shown)
             (format "%s%s\n%s" (string-join lines "\n")
                     (if (>= n harness-tools-fs-list-limit)
                         (format "\n\n[Listing stopped at %d entries; narrow the path or lower depth]" n)
                       "")
                     (format "(%d entr%s in %s, depth %d)" n (if (= n 1) "y" "ies") shown depth))))))))))

(harness-define-tool "list_dir"
  :label "List directory"
  :description "List a directory: files with sizes, directories with a trailing slash, .git skipped. depth > 1 recurses."
  :schema '(:type "object"
            :properties (:path (:type "string" :description "Directory, absolute or relative to the working directory. Default: the working directory")
                         :depth (:type "integer" :description "How many levels to descend. Default 1")))
  :kind 'read
  :coalescable t
  :paths (lambda (input) (list (or (plist-get input :path) ".")))
  :subject (lambda (input) (or (plist-get input :path) "."))
  :handler #'harness-tools-fs--list-dir)

;;;; glob

(defun harness-tools-fs--glob-regexp (pattern)
  "Translate glob PATTERN (with ** support) into an anchored regexp."
  (let ((i 0) (n (length pattern)) (out "\\`"))
    (while (< i n)
      (let ((c (aref pattern i)))
        (cond
         ((and (eq c ?*) (< (1+ i) n) (eq (aref pattern (1+ i)) ?*))
          (if (and (< (+ i 2) n) (eq (aref pattern (+ i 2)) ?/))
              (progn (setq out (concat out "\\(?:.*/\\)?")) (cl-incf i 3))
            (setq out (concat out ".*")) (cl-incf i 2)))
         ((eq c ?*) (setq out (concat out "[^/]*")) (cl-incf i))
         ((eq c ??) (setq out (concat out "[^/]")) (cl-incf i))
         ((eq c ?\[)
          (let ((end (string-search "]" pattern (1+ i))))
            (if end
                (progn (setq out (concat out (substring pattern i (1+ end)))) (setq i (1+ end)))
              (setq out (concat out "\\[")) (cl-incf i))))
         (t (setq out (concat out (regexp-quote (string c)))) (cl-incf i)))))
    (concat out "\\'")))

(defun harness-tools-fs--not-git-p (dir)
  "Non-nil unless DIR is a .git directory.
A predicate for `directory-files-recursively'."
  (not (string= (file-name-nondirectory (directory-file-name dir)) ".git")))

(defun harness-tools-fs--glob-matches (pattern base)
  "Return absolute paths under BASE matching glob PATTERN."
  (if (string-search "**" pattern)
      (let* ((rx (harness-tools-fs--glob-regexp pattern))
             (leaf (file-name-nondirectory pattern))
             (leaf-rx (if (or (string-empty-p leaf) (string-search "**" leaf))
                          "" (wildcard-to-regexp leaf)))
             (files (directory-files-recursively base leaf-rx nil #'harness-tools-fs--not-git-p)))
        (cl-remove-if-not (lambda (f) (string-match-p rx (file-relative-name f base))) files))
    (cl-remove-if (lambda (f) (string-match-p "\\(\\`\\|/\\)\\.git\\(/\\|\\'\\)" f))
                  (file-expand-wildcards (expand-file-name pattern base) t))))

(defun harness-tools-fs--mtime (path)
  "Modification time of PATH as a float, or 0."
  (let ((attrs (file-attributes path)))
    (if attrs (float-time (file-attribute-modification-time attrs)) 0)))

(defun harness-tools-fs--glob (input ctx)
  "Handler for glob with INPUT under CTX."
  (let* ((pattern (plist-get input :pattern))
         (base (file-name-as-directory (harness-tools-resolve-path (or (plist-get input :path) ".") ctx)))
         (shown (harness-tools-fs--display base ctx)))
    (cond
     ((or (not (stringp pattern)) (string-empty-p pattern)) (harness-tool-error "Missing pattern"))
     ((not (file-directory-p base)) (harness-tool-error (format "Directory not found: %s" shown)))
     (t
      (let* ((matches (harness-tools-fs--glob-matches pattern base))
             (total (length matches))
             (sorted (sort matches (lambda (a b) (> (harness-tools-fs--mtime a) (harness-tools-fs--mtime b)))))
             (kept (seq-take sorted harness-tools-fs-glob-limit))
             (rel (mapcar (lambda (f) (concat (file-relative-name f base) (if (file-directory-p f) "/" ""))) kept)))
        (harness-tool-ok
         (if (zerop total)
             (format "No files match %s in %s" pattern shown)
           (format "%s\n(%d match%s%s, newest first)" (string-join rel "\n") total
                   (if (= total 1) "" "es")
                   (if (> total harness-tools-fs-glob-limit)
                       (format ", showing %d" harness-tools-fs-glob-limit) "")))))))))

(harness-define-tool "glob"
  :label "Find files"
  :description "Find files by name pattern (e.g. \"*.el\", \"src/**/*.ts\"). Results are relative to path, newest first, capped at 500."
  :schema '(:type "object"
            :properties (:pattern (:type "string" :description "Glob pattern; ** matches across directories")
                         :path (:type "string" :description "Directory to search from. Default: the working directory"))
            :required ("pattern"))
  :kind 'read
  :coalescable t
  :paths (lambda (input) (list (or (plist-get input :path) ".")))
  :subject (lambda (input) (format "%s%s" (or (plist-get input :pattern) "")
                                   (if (plist-get input :path) (format " in %s" (plist-get input :path)) "")))
  :handler #'harness-tools-fs--glob)

;;;; grep

(defun harness-tools-fs--grep-command (pattern target glob case-sensitive cwd)
  "Return (PROGRAM . ARGS) for searching PATTERN in TARGET.
GLOB filters file names; CASE-SENSITIVE nil searches case-insensitively.
TARGET is a path local to the host CWD lives on."
  (let ((default-directory cwd))
    (if (executable-find "rg" t)
        (append (list "rg" "--no-heading" "--with-filename" "--line-number" "--no-messages"
                      "--color" "never" "--max-columns" "500" "--max-columns-preview"
                      (if case-sensitive "--case-sensitive" "--ignore-case"))
                (when glob (list "--glob" glob))
                (list "-e" pattern "--" target))
      (append (list "grep" "-rn" "-I" "-H" "-E")
              (unless case-sensitive (list "-i"))
              (when glob (list (concat "--include=" glob)))
              (list "--exclude-dir=.git" "-e" pattern "--" target)))))

(defun harness-tools-fs--grep-format (stdout cwd max-results)
  "Format grep STDOUT lines relative to CWD, keeping at most MAX-RESULTS."
  (let* ((lines (split-string stdout "\n" t))
         (total (length lines))
         (kept (seq-take lines max-results))
         (local-cwd (file-name-as-directory (file-local-name cwd)))
         (out (mapcar (lambda (l)
                        (if (string-match "\\`\\(.*?\\):\\([0-9]+\\):\\(.*\\)\\'" l)
                            (let ((file (match-string 1 l)))
                              (format "%s:%s: %s"
                                      (if (string-prefix-p local-cwd file)
                                          (substring file (length local-cwd))
                                        (string-remove-prefix "./" file))
                                      (match-string 2 l) (match-string 3 l)))
                          l))
                      kept)))
    (cons (string-join out "\n") total)))

(defun harness-tools-fs--grep (input ctx)
  "Handler for grep with INPUT under CTX; returns a promise."
  (let* ((pattern (plist-get input :pattern))
         (cwd (file-name-as-directory (or (plist-get ctx :cwd) default-directory)))
         (path (harness-tools-resolve-path (or (plist-get input :path) ".") ctx))
         (shown (harness-tools-fs--display path ctx))
         (glob (plist-get input :glob))
         (case-sensitive (harness-json-true-p (plist-get input :case_sensitive)))
         (max-results (max 1 (harness-tools-fs--int input :max_results 200))))
    (cond
     ((or (not (stringp pattern)) (string-empty-p pattern)) (harness-tool-error "Missing pattern"))
     ((not (file-exists-p path)) (harness-tool-error (format "Path not found: %s" shown)))
     (t
      (let* ((target (file-local-name path))
             (cmd (harness-tools-fs--grep-command pattern target (and (stringp glob) (not (string-empty-p glob)) glob)
                                                  case-sensitive cwd)))
        (harness-then
         (harness-run-command cmd :cwd cwd :timeout harness-tools-fs-grep-timeout :name "harness-grep")
         (lambda (r)
           (let ((exit (plist-get r :exit)))
             (cond
              ((eq exit 'timeout)
               (harness-tool-error (format "grep timed out after %ss; narrow the pattern or path" harness-tools-fs-grep-timeout)))
              ((and (integerp exit) (> exit 1))
               (harness-tool-error (format "%s failed (exit %d): %s" (car cmd) exit
                                           (string-trim (plist-get r :stderr)))))
              ((string-empty-p (plist-get r :stdout))
               (harness-tool-ok (format "No matches for %s in %s%s" pattern shown
                                        (if glob (format " (glob %s)" glob) ""))))
              (t
               (pcase-let ((`(,text . ,total) (harness-tools-fs--grep-format (plist-get r :stdout) cwd max-results)))
                 (harness-tool-ok
                  (if (> total max-results)
                      (format "%s\n\n[%d matches, showing the first %d. Narrow the pattern, add a glob, or raise max_results]"
                              text total max-results)
                    (format "%s\n(%d match%s)" text total (if (= total 1) "" "es")))))))))))))))

(harness-define-tool "grep"
  :label "Search files"
  :description "Search file contents with a regular expression (ripgrep when available). Output lines are path:line: text. Use glob to restrict file names (e.g. \"*.el\"). Case-insensitive unless case_sensitive is true."
  :schema '(:type "object"
            :properties (:pattern (:type "string" :description "Regular expression to search for")
                         :path (:type "string" :description "File or directory to search. Default: the working directory")
                         :glob (:type "string" :description "Only search files whose name matches this glob")
                         :case_sensitive (:type "boolean" :description "Match case exactly. Default false")
                         :max_results (:type "integer" :description "Maximum matching lines to return. Default 200"))
            :required ("pattern"))
  :kind 'read
  :coalescable t
  :paths (lambda (input) (list (or (plist-get input :path) ".")))
  :subject (lambda (input) (format "%s in %s" (harness-truncate-end (or (plist-get input :pattern) "") 40)
                                   (or (plist-get input :path) ".")))
  :handler #'harness-tools-fs--grep)

;;;; file_info

(defun harness-tools-fs--count-lines (path)
  "Return the number of lines in text file PATH."
  (with-temp-buffer
    (harness-tools-fs--insert-text path)
    (count-lines (point-min) (point-max))))

(defun harness-tools-fs--file-info (input ctx)
  "Handler for file_info with INPUT under CTX."
  (let* ((path (harness-tools-fs--path input ctx))
         (shown (harness-tools-fs--display path ctx))
         (attrs (file-attributes path 'string)))
    (if (null attrs)
        (harness-tool-error (format "Not found: %s" shown))
      (let* ((type (file-attribute-type attrs))
             (kind (cond ((eq type t) "directory") ((stringp type) "symlink") (t "file")))
             (size (file-attribute-size attrs))
             (mtime (file-attribute-modification-time attrs))
             (binary (and (string= kind "file") (harness-tools-fs--binary-p path)))
             (lines (and (string= kind "file") (not binary)
                         (<= size harness-tools-fs-line-count-limit)
                         (harness-tools-fs--count-lines path)))
             (mime (and (string= kind "file") (harness-tools-fs--mime path))))
        (harness-tool-ok
         (string-join
          (delq nil
                (list (format "path: %s" path)
                      (format "type: %s%s" kind (if (stringp type) (format " -> %s" type) ""))
                      (when (string= kind "file") (format "size: %d bytes (%s)" size (harness-format-bytes size)))
                      (format "modified: %s (%s)" (format-time-string "%Y-%m-%d %H:%M:%S" mtime)
                              (harness-relative-time (float-time mtime)))
                      (format "mode: %s" (file-attribute-modes attrs))
                      (format "owner: %s" (file-attribute-user-id attrs))
                      (when mime (format "mime: %s" mime))
                      (when (string= kind "file") (format "content: %s" (if binary "binary" "text")))
                      (when lines (format "lines: %d" lines))
                      (when (string= kind "directory")
                        (format "entries: %d"
                                (length (directory-files path nil directory-files-no-dot-files-regexp t))))))
          "\n")
         :meta (list :size size :type kind :lines lines))))))

(harness-define-tool "file_info"
  :label "File info"
  :description "Metadata for a path: type, size, modification time, mode, mime type and line count for text files."
  :schema '(:type "object"
            :properties (:path (:type "string" :description "File or directory, absolute or relative to the working directory"))
            :required ("path"))
  :kind 'read
  :coalescable t
  :paths (lambda (input) (list (plist-get input :path)))
  :subject (lambda (input) (plist-get input :path))
  :handler #'harness-tools-fs--file-info)

(harness-define-module 'tools-fs
  :doc "Read file, Write file, Edit file, List directory, Find files, Search files and File info."
  :requires '(tools))

(provide 'harness-tools-fs)
;;; harness-tools-fs.el ends here
