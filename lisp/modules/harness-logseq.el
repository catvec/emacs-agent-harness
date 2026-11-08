;;; harness-logseq.el --- A Logseq markdown graph: pages, journals, blocks -*- lexical-binding: t; -*-

;;; Commentary:

;; A small, strict client for a Logseq graph kept as markdown files.  A
;; graph is a directory with `pages/' and `journals/' in it (the layout
;; `LOGSEQ_HOME' names); a page is one markdown file, a block is one
;; bullet, and properties are `key:: value' lines under it.  The module
;; knows nothing about workspaces, tools or memory policy: it reads and
;; writes pages, searches blocks and answers backlinks.
;;
;; The format is the one Logseq renders, and the rules of the
;; repository's Logseq skill: every content line belongs to a `- '
;; bullet, children are indented under their parent, properties sit
;; under the bullet they describe, and page references are `[[Page]]'
;; links.  No markdown headers and no `---' separators are ever written:
;; Logseq does not render them as part of its outline.
;;
;; A page's name is its path under `pages/' without the extension, so
;; `Threads/Kitchen renovation' is `pages/Threads/Kitchen renovation.md':
;; `/` is Logseq's namespace separator and becomes a directory.  A name
;; Logseq would rewrite (a `#', `[', `|', a control character) is
;; normalized before it becomes a file, and the name the caller writes
;; is the name reported back.
;;
;; Writes are read, changed and renamed into place
;; (`harness-write-file-atomically'), one at a time in this process.
;; The user's own Logseq editor is the only other writer, and Logseq's
;; own lock is the boundary; this module never parses or touches
;; `logseq/' inside a graph, and never deletes a page or a block.
;;
;; There is no index here.  A search reads the graph's pages and
;; returns the blocks that match, the best first.  The graph is the
;; source of truth; a later stage may add a cache in front of it
;; without changing this contract.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defgroup harness-logseq nil
  "The Logseq markdown graph the harness reads and writes."
  :group 'harness
  :prefix "harness-logseq-")

(defcustom harness-logseq-directory nil
  "Root of the Logseq graph, or nil to find it.
Nil means the directory `LOGSEQ_HOME' names when it is set, else
`~/logseq'.  A workspace can name a graph of its own instead."
  :type '(choice (const :tag "From LOGSEQ_HOME, else ~/logseq" nil)
                 (directory :tag "Graph root"))
  :group 'harness-logseq)

(defcustom harness-logseq-pages-directory "pages"
  "Directory of a graph's pages, relative to its root."
  :type 'string
  :group 'harness-logseq)

(defcustom harness-logseq-journals-directory "journals"
  "Directory of a graph's journal pages, relative to its root."
  :type 'string
  :group 'harness-logseq)

(defcustom harness-logseq-journal-format "%Y-%m-%d"
  "Format of a journal page's name, as `format-time-string' reads it."
  :type 'string
  :group 'harness-logseq)

(defcustom harness-logseq-page-name-chars 120
  "Most characters of a page name the client writes."
  :type 'integer
  :group 'harness-logseq)

(defcustom harness-logseq-search-limit 100
  "Blocks a search returns by default."
  :type 'integer
  :group 'harness-logseq)

(defcustom harness-logseq-search-pages 5000
  "Most page files one search reads."
  :type 'integer
  :group 'harness-logseq)

(defcustom harness-logseq-journal-pages 120
  "Most journal files one search reads, the newest."
  :type 'integer
  :group 'harness-logseq)

(defconst harness-logseq--stopwords
  '("a" "an" "and" "are" "as" "at" "be" "been" "but" "by" "did" "do"
    "about" "does" "for" "from" "had" "has" "have" "how" "i" "if" "in" "into"
    "is" "it" "its" "me" "my" "of" "on" "or" "our" "so" "that" "the"
    "their" "them" "then" "there" "these" "they" "this" "to" "us" "was"
    "we" "were" "what" "when" "where" "which" "who" "why" "will" "with"
    "would" "you" "your")
  "Words a search does not need to match when other words are there.")

(defun harness-logseq-root (&optional root)
  "Return the graph ROOT as a directory, or the configured one."
  (file-name-as-directory
   (expand-file-name
    (or root harness-logseq-directory
        (let ((home (getenv "LOGSEQ_HOME")))
          (and home (not (string-blank-p home)) (string-trim home)))
        "~/logseq"))))

(defun harness-logseq-pages-root (&optional root)
  "Return the pages directory of ROOT, or of the configured graph."
  (expand-file-name harness-logseq-pages-directory (harness-logseq-root root)))

(defun harness-logseq-journals-root (&optional root)
  "Return the journals directory of ROOT, or of the configured graph."
  (expand-file-name harness-logseq-journals-directory (harness-logseq-root root)))

;;;; Names

(defun harness-logseq--clean-segment (segment)
  "Return SEGMENT as a Logseq page-name segment.
Whitespace collapses, characters Logseq would rewrite are dropped, and
a name that comes out empty is `Untitled'."
  (let* ((name (replace-regexp-in-string "[ \t\n\r]+" " " (string-trim (or segment ""))))
         (name (replace-regexp-in-string "[]#|^<>:\"*?/\\\\[]" "" name))
         (name (replace-regexp-in-string "\\`\\.+" "" name))
         (name (string-trim name)))
    (if (string-empty-p name) "Untitled" name)))

(defun harness-logseq-page-name (name)
  "Return NAME as a Logseq page name, a `/` naming a namespace.
Nil and blank become `Untitled'."
  (let* ((raw (or name ""))
         (parts (split-string raw "/" t))
         (clean (mapcar #'harness-logseq--clean-segment parts))
         (name (mapconcat #'identity clean "/")))
    (when (string-empty-p name) (setq name "Untitled"))
    (if (> (length name) harness-logseq-page-name-chars)
        (substring name 0 harness-logseq-page-name-chars)
      name)))

(defun harness-logseq-page-file (name &optional root)
  "Return the file of page NAME in the graph at ROOT."
  (expand-file-name (concat (harness-logseq-page-name name) ".md")
                    (harness-logseq-pages-root root)))

(defun harness-logseq-journal-file (name &optional root)
  "Return the file of journal page NAME in the graph at ROOT."
  (expand-file-name (concat (harness-logseq-page-name name) ".md")
                    (harness-logseq-journals-root root)))

(defun harness-logseq-page-name-of (file root)
  "Return the page name FILE has in the graph at ROOT, or nil."
  (let ((pages (file-name-as-directory (expand-file-name (harness-logseq-pages-root root))))
        (journals (file-name-as-directory (expand-file-name (harness-logseq-journals-root root)))))
    (cond ((string-prefix-p pages file)
           (string-remove-suffix ".md" (substring file (length pages))))
          ((string-prefix-p journals file)
           (string-remove-suffix ".md" (file-name-nondirectory file))))))

(defun harness-logseq-journal-name (&optional date)
  "Return the journal page name of DATE, a time value or nil for today."
  (format-time-string harness-logseq-journal-format (or date (current-time))))

(defun harness-logseq--ensure-graph (root)
  "Create ROOT's pages and journals directories and return ROOT."
  (harness-ensure-directory (harness-logseq-pages-root root))
  (harness-ensure-directory (harness-logseq-journals-root root))
  root)

;;;; Rendering

(defun harness-logseq-uuid ()
  "Return a random UUID string, for a block's `id' property."
  (format "%08x-%04x-4%03x-%04x-%012x"
          (random #xffffffff) (random #xffff) (random #x0fff)
          (+ #x8000 (random #x3fff)) (random #xffffffffffff)))

(defun harness-logseq--one-line (text)
  "Return TEXT as one line, its whitespace runs made single spaces."
  (replace-regexp-in-string "[[:space:]\n\r\t]+" " " (string-trim (or text ""))))

(defun harness-logseq-render-block (text &optional properties)
  "Return TEXT as a Logseq bullet with PROPERTIES, an alist, under it.
TEXT becomes the bullet's first line; PROPERTIES follow as
`key:: value' lines.  A block with no text is a properties block, which
Logseq allows and which carries a page's identity."
  (let* ((text (harness-logseq--one-line text))
         (head (if (string-empty-p text) "-" (concat "- " text)))
         (props (mapconcat (lambda (pair)
                             (when (and (car pair) (cdr pair))
                               (format "\n  %s:: %s" (car pair)
                                       (harness-logseq--one-line (cdr pair)))))
                           properties "")))
    (concat head props "\n")))

;;;; Parsing

(defun harness-logseq--indent (line)
  "Return the indentation width of LINE."
  (let ((i 0))
    (while (and (< i (length line)) (memq (aref line i) '(?\s ?\t)))
      (setq i (1+ i)))
    i))

(defun harness-logseq--bullet (line)
  "Return the text after LINE's bullet, or nil when it has none.
A bullet with no text at all, which Logseq writes as a lone `-', is a
bullet too: pages carry their identity in one."
  (when (string-match "\\`[ \t]*-[ \t]*\\(.*\\)\\'" line)
    (match-string 1 line)))

(defun harness-logseq--property (line)
  "Return (KEY . VALUE) when LINE is a property line, else nil."
  (when (string-match "\\`[ \t]*\\([A-Za-z][A-Za-z0-9_-]*\\)::[ \t]*\\(.*\\)\\'" line)
    (cons (match-string 1 line) (string-trim (match-string 2 line)))))

(defun harness-logseq-parse-blocks (content)
  "Return the blocks in CONTENT, oldest first.
Each block is a plist with `:title' (its bullet's text), `:text' (the
title and its continuation lines, one line), `:properties' (an alist),
`:line' (1-based) and `:indent'.  Property lines before the first
bullet are kept as that block's properties, so a page's identity does
not depend on where its first bullet is."
  (let ((lines (split-string (or content "") "\n"))
        (number 0) (current nil) (blocks nil) (page-props nil))
    (dolist (line lines)
      (setq number (1+ number))
      (cond
       ((harness-logseq--bullet line)
        (when current (push current blocks))
        (let ((title (string-trim (harness-logseq--bullet line))))
          (setq current (list :line number
                              :indent (harness-logseq--indent line)
                              :title title
                              :text title
                              :properties nil))))
       ((harness-logseq--property line)
        (let ((pair (harness-logseq--property line)))
          (if current
              (setf (plist-get current :properties)
                    (append (plist-get current :properties) (list pair)))
            (setq page-props (append page-props (list pair))))))
       ((and current (not (string-blank-p line)))
        (let ((continuation (string-trim line)))
          (setf (plist-get current :text)
                (string-trim (concat (plist-get current :text) " " continuation)))))))
    (when current (push current blocks))
    (setq blocks (nreverse blocks))
    (when page-props
      (if blocks
          (setf (plist-get (car blocks) :properties)
                (append page-props (plist-get (car blocks) :properties)))
        (push (list :line 0 :indent 0 :title "" :text ""
                    :properties page-props)
              blocks)))
    (mapcar (lambda (block)
              (list :title (or (plist-get block :title) "")
                    :text (string-trim (or (plist-get block :text) ""))
                    :properties (plist-get block :properties)
                    :line (plist-get block :line)
                    :indent (plist-get block :indent)))
            blocks)))

(defun harness-logseq-block-property (block key)
  "Return BLOCK's property KEY, or nil."
  (cdr (assoc key (plist-get block :properties))))

(defun harness-logseq--block-time (block)
  "Return BLOCK's `learned-at' or `created' as a time value, or nil."
  (let ((value (or (harness-logseq-block-property block "learned-at")
                   (harness-logseq-block-property block "created"))))
    (when (and value
               (string-match
                "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\(?:[ T][0-9]\\{2\\}:[0-9]\\{2\\}\\)?"
                value))
      (ignore-errors (float-time (date-to-time value))))))

(defun harness-logseq--block-id (block page)
  "Return BLOCK's `id', or its page and line as a stable stand-in."
  (or (harness-logseq-block-property block "id")
      (format "%s#%s" page (plist-get block :line))))

(defun harness-logseq--link-target (value)
  "Return the page VALUE links, when it is a `[[Page]]' link."
  (when (and (stringp value)
             (string-match "\\`\\[\\[\\([^]]+\\)\\]\\]\\'" (string-trim value)))
    (match-string 1 (string-trim value))))

;;;; Reading

(defun harness-logseq-read-page (name &optional root)
  "Return page NAME of the graph at ROOT as a plist, or nil when absent.
The plist holds `:name', `:file', `:journal', `:properties' (the
page's identity properties) and `:blocks', as
`harness-logseq-parse-blocks' lists them.  A journal page is found in
`journals/'; any other page is looked for in `pages/' first."
  (let* ((root (harness-logseq-root root))
         (name (harness-logseq-page-name name))
         (journal-file (harness-logseq-journal-file name root))
         (page-file (harness-logseq-page-file name root))
         (file (cond ((file-readable-p journal-file) journal-file)
                     ((file-readable-p page-file) page-file)))
         (content (and file (harness-read-file file))))
    (when content
      (let* ((blocks (harness-logseq-parse-blocks content))
             (properties (plist-get (car blocks) :properties)))
        (list :name name
              :file file
              :journal (equal file journal-file)
              :properties properties
              :blocks blocks)))))

(defun harness-logseq--pages (root)
  "Return the page files of ROOT, newest first."
  (let ((dir (harness-logseq-pages-root root)))
    (when (file-directory-p dir)
      (seq-take
       (sort (directory-files-recursively dir "\\.md\\'")
             (lambda (a b)
               (time-less-p (or (file-attribute-modification-time (file-attributes b)) 0)
                            (or (file-attribute-modification-time (file-attributes a)) 0))))
       (max 0 harness-logseq-search-pages)))))

(defun harness-logseq--journals (root)
  "Return the journal files of ROOT, newest first."
  (let ((dir (harness-logseq-journals-root root)))
    (when (file-directory-p dir)
      (seq-take
       (sort (directory-files dir t "\\.md\\'")
             (lambda (a b) (string> (file-name-nondirectory a)
                                    (file-name-nondirectory b))))
       (max 0 harness-logseq-journal-pages)))))

;;;; Writing

(defun harness-logseq--append-block (file block)
  "Append BLOCK to FILE, making its directory and a separating newline."
  (harness-ensure-directory (file-name-directory file))
  (let* ((existing (or (harness-read-file file) ""))
         (sep (cond ((string-empty-p existing) "")
                    ((string-suffix-p "\n" existing) "\n")
                    (t "\n\n"))))
    (harness-write-file-atomically file (concat existing sep block))))

(defun harness-logseq--block-add (page text &optional opts)
  "Append TEXT as a block of PAGE in the graph at OPTS' `:root'.
OPTS may name `:properties' (an alist written under the bullet),
`:id' (a block id, generated when absent) and `:date' (the time the
block happened, for `learned-at').  The page and the graph are created
when missing.  Return the block with `:id', `:page' and `:file'."
  (let* ((root (harness-logseq-root (plist-get opts :root)))
         (name (harness-logseq-page-name page))
         (journal (or (plist-get opts :journal)
                      (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" name)))
         (file (if journal
                   (harness-logseq-journal-file name root)
                 (harness-logseq-page-file name root)))
         (id (or (plist-get opts :id) (harness-logseq-uuid)))
         (props (append (list (cons "id" id))
                        (plist-get opts :properties)
                        (list (cons "learned-at"
                                    (format-time-string
                                     "%Y-%m-%d %H:%M"
                                     (or (plist-get opts :date) (current-time)))))))
         (block (harness-logseq-render-block text props)))
    (harness-logseq--ensure-graph root)
    (harness-logseq--append-block file block)
    (let* ((page-data (harness-logseq-read-page name root))
           (found (car (last (plist-get page-data :blocks)))))
      (append (list :id id :page name :file file :journal (and journal t)) found))))

(defun harness-logseq--page-add (page text &optional opts)
  "Add TEXT as a block of PAGE, creating the page with OPTS' properties.
When OPTS names `:properties', they are written as the page's identity
block the first time the page is created; a page that already exists
keeps the properties it has.  Return what `logseq/block-add' returns."
  (let* ((root (harness-logseq-root (plist-get opts :root)))
         (name (harness-logseq-page-name page))
         (exists (harness-logseq-read-page name root)))
    (if exists
        (harness-logseq--block-add name text opts)
      (harness-logseq--block-add
       name text
       (plist-put (copy-sequence opts) :properties (plist-get opts :properties))))))

(defun harness-logseq--first-block-end (lines)
  "Return the index after the first block's last line in LINES.
That is its bullet, its continuation lines and its property lines.  A
page with no bullet answers nil."
  (when-let* ((start (cl-position-if (lambda (line) (harness-logseq--bullet line)) lines)))
    (let ((indent (harness-logseq--indent (nth start lines)))
          (index (1+ start))
          (end (1+ start)))
      (while (and (< index (length lines))
                  (let ((line (nth index lines)))
                    (or (harness-logseq--property line)
                        (and (not (string-blank-p line))
                             (> (harness-logseq--indent line) indent)))))
        (setq end (1+ index)
              index (1+ index)))
      end)))

(defun harness-logseq--property-set (page key value &optional opts)
  "Set property KEY of PAGE to VALUE, in the page's identity block.
The page and a block are created when missing.  Return the page."
  (let* ((root (harness-logseq-root (plist-get opts :root)))
         (name (harness-logseq-page-name page))
         (file (if (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" name)
                   (harness-logseq-journal-file name root)
                 (harness-logseq-page-file name root)))
         (content (harness-read-file file)))
    (harness-logseq--ensure-graph root)
    (if (null content)
        (harness-logseq--page-add name nil (list :root root
                                                :properties (list (cons key value))))
      (let* ((line (format "  %s:: %s" key (harness-logseq--one-line value)))
             (lines (split-string content "\n"))
             (pattern (format "\\`[ \t]*%s::" (regexp-quote key)))
             (replaced nil)
             (out (cl-loop for text in lines
                           collect
                           (if (and (not replaced) (string-match-p pattern text))
                               (progn (setq replaced t) line)
                             text))))
        (unless replaced
          (let ((at (or (harness-logseq--first-block-end out)
                        (length out))))
            (setq out (append (cl-subseq out 0 at) (list line)
                              (cl-subseq out at)))))
        (harness-write-file-atomically file (mapconcat #'identity out "\n"))
        (harness-logseq-read-page name root)))))

(harness-defmethod logseq/block-add (page text &optional opts)
  "Append TEXT as a block of PAGE in the graph at OPTS' `:root'.
See `harness-logseq--block-add' for OPTS and the answer."
  (harness-logseq--block-add page text opts))

(harness-defmethod logseq/page-add (page text &optional opts)
  "Add TEXT as a block of PAGE, creating the page with OPTS' properties.
See `harness-logseq--page-add' for OPTS and the answer."
  (harness-logseq--page-add page text opts))

(harness-defmethod logseq/property-set (page key value &optional opts)
  "Set property KEY of PAGE to VALUE, in the page's identity block.
See `harness-logseq--property-set' for OPTS and the answer."
  (harness-logseq--property-set page key value opts))

;;;; Search

(defun harness-logseq--tokens (text)
  "Return the meaningful words of TEXT, lowercased and de-duplicated.
Stopwords are dropped when TEXT holds any other word."
  (let* ((words (cl-remove-if (lambda (word) (< (length word) 2))
                              (split-string (downcase (or text ""))
                                            "[^[:alnum:]_./-]+" t)))
         (words (delete-dups words)))
    (cl-remove-if (lambda (word)
                    (member (replace-regexp-in-string "\\`[./-]+\\|[./-]+\\'" "" word)
                            harness-logseq--stopwords))
                  words)))

(defun harness-logseq--matches (text token)
  "Non-nil when TEXT holds TOKEN, ignoring case."
  (and (stringp text) (not (string-empty-p token))
       (string-match-p (regexp-quote token) (downcase text))))

(defun harness-logseq--score (block tokens)
  "Return how many of TOKENS BLOCK matches, or nil when it matches none."
  (let* ((text (or (plist-get block :text) (plist-get block :title) ""))
         (hits (cl-count-if (lambda (token) (harness-logseq--matches text token)) tokens)))
    (and (> hits 0) hits)))

(defun harness-logseq--window (text start end)
  "Return TEXT cut around START..END, with markers around the match."
  (let* ((from (max 0 (- start 90)))
         (to (min (length text) (+ end 110)))
         (cut (substring text from to)))
    (concat (if (> from 0) "…" "")
            (replace-regexp-in-string
             "[\n\r\t]+" " "
             (if (and (>= (- start from) 0) (<= (- end from) (length cut)))
                 (concat (substring cut 0 (- start from))
                         "<<" (substring cut (- start from) (- end from)) ">>"
                         (substring cut (- end from)))
               cut))
            (if (< to (length text)) "…" ""))))

(defun harness-logseq--snippet (block tokens)
  "Return BLOCK's text with the first match of TOKENS marked."
  (let* ((text (or (plist-get block :text) ""))
         (down (downcase text))
         (found (cl-loop for token in tokens
                         for pos = (string-match (regexp-quote token) down)
                         when pos collect (cons pos token)))
         (first (car (sort (copy-sequence found) (lambda (a b) (< (car a) (car b)))))))
    (if (null first)
        text
      (harness-logseq--window text (car first) (+ (car first) (length (cdr first)))))))

(defun harness-logseq-block-result (block page journal file)
  "Return BLOCK of PAGE as a search result."
  (let* ((properties (plist-get block :properties))
         (thread (or (harness-logseq--link-target
                      (cdr (assoc "thread" properties)))
                     (and (string-prefix-p "Threads/" page) page)))
         (role (cdr (assoc "role" properties)))
         (workspace (cdr (assoc "workspace" properties))))
    (list :id (harness-logseq--block-id block page)
          :page page
          :file file
          :journal journal
          :thread thread
          :role (and role (intern role))
          :workspace workspace
          :text (plist-get block :text)
          :properties properties
          :line (plist-get block :line)
          :ts (harness-logseq--block-time block))))

(defun harness-logseq-content-blocks (content)
  "Return the blocks of CONTENT that carry words, not only properties."
  (cl-remove-if (lambda (block) (string-empty-p (or (plist-get block :text) "")))
                (harness-logseq-parse-blocks content)))

(harness-defmethod logseq/search (query &optional opts)
  "Return the blocks of the graph at OPTS' `:root' that match QUERY.
OPTS may name `:limit' (100 by default), `:workspace' (only blocks of
that workspace, by their `workspace-id' or `workspace' property),
`:all' (every block, the default when no workspace is named),
`:journals' (nil to leave the journal pages out) and `:pages' (only
these page names, a list).

Each result is `(:id :page :file :journal :thread :role :workspace
:text :properties :line :ts :snippet)', best first: more words matched
before fewer, then the newest block.  A block with only properties is
never a result."
  (let* ((root (harness-logseq-root (plist-get opts :root)))
         (tokens (harness-logseq--tokens query))
         (limit (or (plist-get opts :limit) harness-logseq-search-limit))
         (workspace (plist-get opts :workspace))
         (wanted (plist-get opts :pages))
         (files (append
                 (mapcar (lambda (file) (cons file nil))
                         (harness-logseq--pages root))
                 (when (or (null (plist-member opts :journals))
                           (plist-get opts :journals))
                   (mapcar (lambda (file) (cons file t))
                           (harness-logseq--journals root)))))
         (results nil))
    (when tokens
      (dolist (pair files)
        (let* ((file (car pair))
               (journal (cdr pair))
               (name (harness-logseq-page-name-of file root))
               (content (and name (harness-read-file file))))
          (when (and name content (or (not wanted) (member name wanted)))
            (let* ((blocks (harness-logseq-content-blocks content))
                   (all-blocks (harness-logseq-parse-blocks content))
                   (page-workspace
                    (or (cdr (assoc "workspace-id"
                                    (plist-get (car all-blocks) :properties)))
                        (cdr (assoc "workspace"
                                    (plist-get (car all-blocks) :properties))))))
              (dolist (block blocks)
                (let ((score (harness-logseq--score block tokens)))
                  (when (and score
                             (or (null workspace)
                                 (equal workspace
                                        (or (cdr (assoc "workspace-id"
                                                        (plist-get block :properties)))
                                            (cdr (assoc "workspace"
                                                        (plist-get block :properties)))
                                            page-workspace))))
                    (push (plist-put
                           (harness-logseq-block-result block name journal file) :score score)
                          results))))))))
      (setq results
            (sort results
                  (lambda (a b)
                    (let ((sa (plist-get a :score))
                          (sb (plist-get b :score)))
                      (if (= sa sb)
                          (> (or (plist-get a :ts) 0) (or (plist-get b :ts) 0))
                        (> sa sb))))))
      (setq results (seq-take results limit))
      (mapcar (lambda (result)
                (plist-put result :snippet
                           (harness-logseq--snippet
                            (list :text (plist-get result :text)) tokens)))
              results))))

(harness-defmethod logseq/backlinks (name &optional opts)
  "Return the blocks of the graph at OPTS' `:root' that link page NAME."
  (let* ((root (harness-logseq-root (plist-get opts :root)))
         (name (harness-logseq-page-name name))
         (link (format "[[%s]]" name))
         (limit (or (plist-get opts :limit) 100))
         (results nil)
         (files (append (mapcar (lambda (file) (cons file nil))
                                (harness-logseq--pages root))
                        (mapcar (lambda (file) (cons file t))
                                (harness-logseq--journals root)))))
    (dolist (pair files)
      (let* ((file (car pair))
             (page (harness-logseq-page-name-of file root))
             (content (and page (harness-read-file file))))
        (when (and content (string-match-p (regexp-quote link) content))
          (dolist (block (harness-logseq-content-blocks content))
            (when (string-match-p
                   (regexp-quote link)
                   (concat (or (plist-get block :text) "")
                           " "
                           (mapconcat (lambda (prop) (cdr prop))
                                      (plist-get block :properties) " ")))
              (push (harness-logseq-block-result block page (cdr pair) file)
                    results))))))
    (seq-take (nreverse results) limit)))

;;;; Methods

(harness-defmethod logseq/root (&optional graph)
  "Return the graph GRAPH as a directory, or the configured one."
  (harness-logseq-root graph))

(harness-defmethod logseq/status (&optional root)
  "Return what the graph at ROOT says about itself.
`:available' is non-nil when its `pages' directory is there, and
`:reason' says why when it is not.  Nothing is created."
  (let* ((root (harness-logseq-root root))
         (pages (harness-logseq-pages-root root))
         (journals (harness-logseq-journals-root root))
         (available (file-directory-p pages)))
    (list :root root
          :pages pages
          :journals journals
          :available available
          :reason (unless available "no-page-directory")
          :pages-directory (file-directory-p pages)
          :journals-directory (file-directory-p journals)
          :writable (and (file-directory-p root) (file-writable-p root)))))

(harness-defmethod logseq/page (name &optional opts)
  "Return page NAME of the graph at OPTS' `:root', or nil.
See `harness-logseq-read-page' for the shape."
  (harness-logseq-read-page name (plist-get opts :root)))

(harness-defmethod logseq/page-list (&optional opts)
  "Return the pages of the graph at OPTS' `:root', newest first.
Each is `(:name NAME :file PATH :journal BOOL :updated TIME)'.  At most
OPTS' `:limit' (500 by default) are returned."
  (let* ((root (harness-logseq-root (plist-get opts :root)))
         (limit (or (plist-get opts :limit) 500))
         (all (append
               (mapcar (lambda (file)
                         (let ((attrs (file-attributes file)))
                           (list :name (harness-logseq-page-name-of file root)
                                 :file file :journal nil
                                 :updated (and attrs
                                               (float-time
                                                (file-attribute-modification-time attrs))))))
                       (harness-logseq--pages root))
               (mapcar (lambda (file)
                         (let ((attrs (file-attributes file)))
                           (list :name (harness-logseq-page-name-of file root)
                                 :file file :journal t
                                 :updated (and attrs
                                               (float-time
                                                (file-attribute-modification-time attrs))))))
                       (harness-logseq--journals root)))))
    (seq-take (sort all (lambda (a b)
                          (> (or (plist-get a :updated) 0)
                             (or (plist-get b :updated) 0))))
              limit)))

(harness-define-module 'logseq
  :doc "A Logseq markdown graph: pages, journals and blocks, read and written as files."
  :requires nil)

(provide 'harness-logseq)
;;; harness-logseq.el ends here
