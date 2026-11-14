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
;; own lock is the boundary; this module never parses or writes
;; `logseq/' inside a graph, and never deletes a page or a block.  It
;; reads the names and times under `logseq/bak' only to say what history
;; a graph has (`logseq/recovery'), never to restore from it: the
;; module keeps no copy of a page it wrote.
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
  "Format of a journal page's name this client writes.
It is read as `format-time-string' reads it: `%Y-%m-%d' by default."
  :type 'string
  :group 'harness-logseq)

(defcustom harness-logseq-journal-formats '("%Y-%m-%d" "%Y_%m_%d" "%Y.%m.%d")
  "Journal name formats a graph may already hold, this client's own first.
A day is read from the file that exists, whatever separator the graph
uses: Logseq's own journals are `%Y_%m_%d', while this client writes
`harness-logseq-journal-format'.  A search that sorted journal file
names would push one convention past its bound, so a day is parsed and
ordered by date instead."
  :type '(repeat string)
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
  "Return the file of journal page NAME in the graph at ROOT.
A NAME that is a day resolves to the file the graph already holds for
that day, whatever separator its journals use, else to this client's
own name for it."
  (if-let* ((day (harness-logseq-journal-day name)))
      (harness-logseq-journal-file-for-day day root)
    (expand-file-name (concat (harness-logseq-page-name name) ".md")
                      (harness-logseq-journals-root root))))

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

(defun harness-logseq-journal-name-formats ()
  "Return the journal name formats a graph may hold, this one first.
That is `harness-logseq-journal-formats' with `harness-logseq-journal-format'
at its front, each format once."
  (delete-dups
   (cons harness-logseq-journal-format
         (append harness-logseq-journal-formats nil))))

(defun harness-logseq--date-pattern (format)
  "Return a regexp reading the date FORMAT writes, year-month-day in order.
`%Y' reads four digits, `%m' and `%d' two, and everything else in FORMAT
is literal.  Only formats with those three placeholders count."
  (when (and (string-match-p "%Y" format)
             (string-match-p "%m" format)
             (string-match-p "%d" format))
    (let ((pattern "\\`")
          (index 0)
          (length (length format)))
      (while (< index length)
        (let ((char (aref format index)))
          (if (and (eq char ?%) (< (1+ index) length))
              (let ((code (aref format (1+ index))))
                (setq pattern (concat pattern
                                      (cl-case code
                                        (?Y "\\([0-9]\\{4\\}\\)")
                                        (?m "\\([0-9]\\{2\\}\\)")
                                        (?d "\\([0-9]\\{2\\}\\)")
                                        (t (regexp-quote (substring format index (1+ index)
                                                                    ))))))
                (setq index (+ index 2)))
            (setq pattern (concat pattern (regexp-quote (char-to-string char)))
                  index (1+ index)))))
      (concat pattern "\\'"))))

(defun harness-logseq-journal-date (name)
  "Return NAME read as a journal date, as (YEAR MONTH DAY), or nil.
NAME is a page or file name, with or without its directory and `.md'.
Only the formats in `harness-logseq-journal-name-formats' count, so a
page that happens to start with digits is not taken for a day."
  ;; Only a `.md' suffix goes: `2026.11.08' is a day whose separator is
  ;; a dot, not a file called `2026.11' with an extension.
  (let* ((name (file-name-nondirectory (or name "")))
         (name (if (string-suffix-p ".md" name) (string-remove-suffix ".md" name) name))
         (found nil))
    (cl-loop for format in (harness-logseq-journal-name-formats)
             for regexp = (harness-logseq--date-pattern format)
             until found
             do (when (and regexp (string-match regexp name))
                  (let ((parts (list (match-string 1 name)
                                     (match-string 2 name)
                                     (match-string 3 name))))
                    (when (cl-every #'stringp parts)
                      (setq found (mapcar #'string-to-number parts))))))
    found))

(defun harness-logseq-journal-day (name)
  "Return NAME as a `%Y-%m-%d' day, or nil when it is not a journal name.
A name with a namespace -- `Dreams/2026-11-08' -- is a page in that
namespace, not the day's journal, so only a name of the day itself
answers."
  (when (and (stringp name) (not (string-match-p "/" name)))
    (when-let* ((date (harness-logseq-journal-date name)))
      (format "%04d-%02d-%02d" (nth 0 date) (nth 1 date) (nth 2 date)))))

(defun harness-logseq-journal-file-for-day (day &optional root)
  "Return the file of the journal page of DAY, a `%Y-%m-%d' string.
That is the file the graph already holds for the day when it has one,
whatever separator it uses, else the file this client writes."
  (let ((dir (harness-logseq-journals-root root)))
    (or (cl-loop
         for format in (harness-logseq-journal-name-formats)
         for name = (format-time-string
                     format (date-to-time (concat day " 12:00:00")))
         for file = (expand-file-name (concat name ".md") dir)
         when (file-readable-p file)
         return file)
        (expand-file-name (concat (format-time-string harness-logseq-journal-format
                                                      (date-to-time (concat day " 12:00:00")))
                                  ".md")
                          dir))))

(defun harness-logseq-journal-day-file (name root)
  "Return (DAY . FILE) of journal page NAME in the graph at ROOT.
FILE is the one the graph holds, else the one this client would write;
DAY is nil when NAME is not a journal name."
  (cons (harness-logseq-journal-day name)
        (harness-logseq-journal-file name root)))

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

(defun harness-logseq--block-lines (text)
  "Return TEXT as the lines of one Logseq block.
Carriage returns become newlines, trailing whitespace goes, and leading
and trailing blank lines are dropped.  Blank lines between words stay,
as empty lines: a block keeps its paragraphs, quotes and code."
  (let* ((text (replace-regexp-in-string "\r\n?" "\n" (or text "")))
         (lines (mapcar (lambda (line)
                          (replace-regexp-in-string "[ \t]+\\'" "" line))
                        (split-string text "\n")))
         (start 0)
         (end (length lines)))
    (while (and (< start end) (string-blank-p (nth start lines)))
      (setq start (1+ start)))
    (while (and (> end start) (string-blank-p (nth (1- end) lines)))
      (setq end (1- end)))
    (cl-subseq lines start end)))

(defun harness-logseq-render-block (text &optional properties)
  "Return TEXT as a Logseq bullet with PROPERTIES, an alist, under it.
The first line of TEXT is the bullet; its other lines become the
indented continuation lines Logseq reads as the same block, so code,
quotes and paragraphs keep their shape.  PROPERTIES follow as
`key:: value' lines.  A block with no text is a properties block, which
Logseq allows and which carries a page's identity."
  (let* ((lines (harness-logseq--block-lines text))
         (head (if (null lines) "-" (concat "- " (car lines))))
         (rest (mapconcat (lambda (line) (concat "\n  " line)) (cdr lines) ""))
         (props (mapconcat (lambda (pair)
                             (when (and (car pair) (cdr pair))
                               (format "\n  %s:: %s" (car pair)
                                       (harness-logseq--one-line (cdr pair)))))
                           properties "")))
    (concat head rest props "\n")))

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

(defun harness-logseq--continuation (line indent)
  "Return LINE without the two spaces a block's continuation adds, at INDENT.
A continuation line sits two spaces past its bullet; whatever further
indentation it has is the content's own, such as code."
  (let ((strip (min (length line) (+ indent 2))))
    (cl-subseq line strip)))

(defun harness-logseq--parse-continuation (line current number)
  "Add continuation LINE of block CURRENT, which is line NUMBER.
A blank LINE is a paragraph break inside the block."
  (when current
    (if (string-blank-p line)
        (setf (plist-get current :text)
              (concat (plist-get current :text) "\n"))
      (setf (plist-get current :text)
            (concat (plist-get current :text) "\n"
                    (harness-logseq--continuation
                     line (plist-get current :indent)))))
    (setf (plist-get current :end-line) number)))

(defun harness-logseq-parse-blocks (content)
  "Return the blocks in CONTENT, oldest first.
Each block is a plist with `:title' (its bullet's text), `:text' (the
title and its continuation lines, kept apart by newlines),
`:properties' (an alist), `:line' and `:end-line' (1-based, the last
line of the block and of the children under it) and `:indent'.  A
fenced code block is text, even where a line of it looks like a bullet
or a property.  Property lines before the first bullet are kept as that
block's properties, so a page's identity does not depend on where its
first bullet is."
  (let ((lines (split-string (or content "") "\n"))
        (number 0) (current nil) (blocks nil) (page-props nil)
        (fence nil))
    (dolist (line lines)
      (setq number (1+ number))
      (let* ((trimmed (string-trim line))
             (fence-line (and (string-match "\\`\\(```+\\|~~~+\\)" trimmed)
                              (match-string 1 trimmed))))
        (cond
         ((and fence (not fence-line))
          (harness-logseq--parse-continuation line current number))
         ((and fence fence-line)
          (setq fence nil)
          (harness-logseq--parse-continuation line current number))
         (fence-line
          (setq fence fence-line)
          (harness-logseq--parse-continuation line current number))
         ((harness-logseq--bullet line)
          (when current (push current blocks))
          (let ((title (string-trim (harness-logseq--bullet line))))
            (when (string-match "\\`\\(```+\\|~~~+\\)" title)
              (setq fence (match-string 1 title)))
            (setq current (list :line number
                                :indent (harness-logseq--indent line)
                                :end-line number
                                :title title
                                :text title
                                :properties nil))))
         ((harness-logseq--property line)
          (let ((pair (harness-logseq--property line)))
            (if current
                (progn
                  (setf (plist-get current :properties)
                        (append (plist-get current :properties) (list pair)))
                  (setf (plist-get current :end-line) number))
              (setq page-props (append page-props (list pair))))))
         ((and current (string-blank-p line)
               (> (harness-logseq--indent line) (plist-get current :indent)))
          ;; A blank line indented under the bullet is a paragraph break
          ;; in it; one at the left margin separates blocks.
          (harness-logseq--parse-continuation line current number))
         ((and current (not (string-blank-p line)))
          (harness-logseq--parse-continuation line current number)))))
    (when current (push current blocks))
    (setq blocks (nreverse blocks))
    ;; A block's end covers the blocks indented under it, so removing a
    ;; parent removes its children with it.
    (let ((index 0))
      (while (< index (length blocks))
        (let* ((block (nth index blocks))
               (indent (plist-get block :indent))
               (end (1+ index)))
          (while (and (< end (length blocks))
                      (> (plist-get (nth end blocks) :indent) indent))
            (setq end (1+ end)))
          (when (> end (1+ index))
            (setf (plist-get block :end-line)
                  (plist-get (nth (1- end) blocks) :end-line)))
          (setq index (1+ index)))))
    (when page-props
      (if blocks
          (setf (plist-get (car blocks) :properties)
                (append page-props (plist-get (car blocks) :properties)))
        (push (list :line 0 :end-line 0 :indent 0 :title "" :text ""
                    :properties page-props)
              blocks)))
    (mapcar (lambda (block)
              (list :title (or (plist-get block :title) "")
                    :text (replace-regexp-in-string
                           "[ \t\n]+\\'" ""
                           (or (plist-get block :text) ""))
                    :properties (plist-get block :properties)
                    :line (plist-get block :line)
                    :end-line (max (or (plist-get block :line) 1)
                                   (or (plist-get block :end-line) 1))
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
  "Return the journal files of ROOT, newest day first.
The order is by the day the file's name parses to, not by its name's
text: a graph with both `2026-11-08.md' and `2026_11_07.md' keeps the
newer day ahead however the separators sort.  A file whose name is no
day sorts after every day, by its modification time.  At most
`harness-logseq-journal-pages' are returned."
  (let ((dir (harness-logseq-journals-root root)))
    (when (file-directory-p dir)
      (let ((entries
             (mapcar (lambda (file)
                       (let ((day (harness-logseq-journal-day
                                   (file-name-nondirectory file))))
                         (cons file (if day
                                        (float-time
                                         (date-to-time (concat day " 12:00:00")))
                                      (or (ignore-errors
                                            (float-time
                                             (file-attribute-modification-time
                                              (file-attributes file))))
                                          0)))))
                     (directory-files dir t "\\.md\\'"))))
        (mapcar #'car
                (seq-take (sort entries (lambda (a b) (> (cdr a) (cdr b))))
                          (max 0 harness-logseq-journal-pages)))))))

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
                      (harness-logseq-journal-day name)))
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
         (file (if (harness-logseq-journal-day name)
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

(defun harness-logseq--bak-files (root)
  "Return the files under ROOT's `logseq/bak', a list of (PATH . TIME)."
  (let ((dir (expand-file-name "logseq/bak" root)))
    (when (file-directory-p dir)
      (delq nil
            (mapcar (lambda (file)
                      (let ((attrs (file-attributes file)))
                        (and attrs (not (file-directory-p file))
                             (cons file (float-time (file-attribute-modification-time attrs))))))
                    (directory-files-recursively dir "" nil))))))

(defun harness-logseq--git-repository (root)
  "Return ROOT's git top level when it is in a working tree, else nil.
Only a directory that git itself names is reported: a `.git' file or
directory somewhere above the graph is not evidence on its own."
  (when (and (file-directory-p root) (executable-find "git"))
    (condition-case nil
        (let ((default-directory (file-name-as-directory (expand-file-name root))))
          (with-temp-buffer
            (when (and (eq 0 (call-process "git" nil t nil
                                           "-C" default-directory
                                           "rev-parse" "--show-toplevel"))
                       (not (string-blank-p (buffer-string))))
              (string-trim (buffer-string)))))
      (error nil))))

(harness-defmethod logseq/recovery (&optional root)
  "Return what would bring a page of the graph at ROOT back, as a plist.
`:git' is the working tree's top level when the graph is in a git
checkout, `:backups' how many files Logseq's own `logseq/bak' holds, and
`:backup-latest' when the newest of them was written.  The module keeps
no copy of a page it wrote, so this is the whole of what recovery a
graph has: a directory with neither is a graph whose changes cannot be
taken back by the harness."
  (let* ((root (harness-logseq-root root))
         (bak (harness-logseq--bak-files root))
         (latest (and bak (apply #'max (mapcar #'cdr bak)))))
    (list :git (harness-logseq--git-repository root)
          :backups (length bak)
          :backup-latest (and latest (format-time-string "%Y-%m-%dT%H:%M:%SZ"
                                                         (seconds-to-time latest)
                                                         t))
          :kept nil)))

(harness-defmethod logseq/status (&optional root)
  "Return what the graph at ROOT says about itself.
`:available' is non-nil when its `pages' directory is there, and
`:reason' says why when it is not.  Nothing is created.

`:graph-type' says what the client found: `file' for a markdown file
graph it can read and write, `database' for a Logseq database graph,
whose records live in a database this client does not open, and
`unknown' for a directory with neither layout.  `:adapter' names the
adapter in use, `markdown' when one is, and `:reason' is
`unsupported-database-graph' for a database graph: a database graph's
exported Markdown is not a live database API."
  (let* ((root (harness-logseq-root root))
         (pages (harness-logseq-pages-root root))
         (journals (harness-logseq-journals-root root))
         (file-graph (or (file-directory-p pages) (file-directory-p journals)))
         (database-graph (and (not file-graph)
                              (or (file-exists-p (expand-file-name "db.sqlite" root))
                                  (file-directory-p (expand-file-name "logseq/db" root)))))
         (graph-type (cond (file-graph 'file)
                           (database-graph 'database)
                           (t 'unknown)))
         (available (file-directory-p pages)))
    (list :root root
          :pages pages
          :journals journals
          :available available
          :reason (unless available
                    (if database-graph "unsupported-database-graph" "no-page-directory"))
          :graph-type graph-type
          :adapter (and (eq graph-type 'file) 'markdown)
          :pages-directory (file-directory-p pages)
          :journals-directory (file-directory-p journals)
          :writable (and (file-directory-p root) (file-writable-p root)))))

(harness-defmethod logseq/block-remove (page id &optional opts)
  "Remove block ID from PAGE in the graph at OPTS' `:root'.
ID is the block's `id' property, or its 1-based line for a block
without one.  The block's properties and the blocks indented under it
go with it.  Return the block removed, or nil when PAGE or ID is not
there; nothing is written then."
  (let* ((root (harness-logseq-root (plist-get opts :root)))
         (name (harness-logseq-page-name page))
         (file (if (harness-logseq-journal-day name)
                   (harness-logseq-journal-file name root)
                 (harness-logseq-page-file name root)))
         (content (harness-read-file file)))
    (when content
      (let ((block (cl-find-if
                    (lambda (candidate)
                      (or (equal (harness-logseq--block-id candidate name) id)
                          (equal (format "%s" (plist-get candidate :line))
                                 (format "%s" id))))
                    (harness-logseq-parse-blocks content))))
        (when block
          (let* ((lines (split-string content "\n"))
                 (from (max 0 (1- (plist-get block :line))))
                 (to (min (length lines) (plist-get block :end-line)))
                 (kept (append (cl-subseq lines 0 from) (cl-subseq lines to)))
                 (text (mapconcat #'identity kept "\n")))
            (when (string-suffix-p "\n" content)
              (setq text (concat text "\n")))
            (harness-write-file-atomically file text)
            block))))))

(harness-defmethod logseq/page (name &optional opts)
  "Return page NAME of the graph at OPTS' `:root', or nil.
See `harness-logseq-read-page' for the shape."
  (harness-logseq-read-page name (plist-get opts :root)))

(defun harness-logseq-digest (text)
  "Return a short digest of TEXT, to tell a page as it was from as it is.
Nil and an empty string digest alike: both are a page that is not there."
  (secure-hash 'sha1 (or text "")))

(defun harness-logseq-page-digest (name &optional root)
  "Return the digest of page NAME in the graph at ROOT, or nil.
A page that is not there has no digest; `logseq/page-edit's `:expect'
matches that with `absent'."
  (let* ((file (if (harness-logseq-journal-day name)
                   (harness-logseq-journal-file name root)
                 (harness-logseq-page-file name root)))
         (content (harness-read-file file)))
    (and content (harness-logseq-digest content))))

(defun harness-logseq--journal-p (name root)
  "Non-nil when page NAME is a journal page of the graph at ROOT."
  (or (harness-logseq-journal-day name)
      (file-exists-p (harness-logseq-journal-file name root))))

(defun harness-logseq--dedent (line amount)
  "Return LINE with at most AMOUNT leading spaces taken off."
  (let ((n 0))
    (while (and (< n amount) (< n (length line)) (eq (aref line n) ?\s))
      (setq n (1+ n)))
    (substring line n)))

(defun harness-logseq--block-parts (lines block)
  "Return (OWN . CHILDREN) of BLOCK in LINES, both lists of lines.
OWN is BLOCK's bullet, its continuation lines and its properties;
CHILDREN are the lines of the blocks indented under it.  A Logseq block
keeps its own text and properties before its first child bullet, so
everything from that bullet on is the child's."
  (let* ((from (max 0 (1- (plist-get block :line))))
         (to (min (length lines) (plist-get block :end-line)))
         (subset (cl-subseq lines from to))
         (own (list (car subset)))
         (rest (cdr subset))
         (children nil))
    (while (and rest (not (harness-logseq--bullet (car rest))))
      (push (car rest) own)
      (setq rest (cdr rest)))
    (setq children rest)
    (cons (nreverse own) children)))

(defun harness-logseq--children-lifted (children indent)
  "Return CHILDREN, lines under a block at INDENT, lifted one level.
Each child keeps its own bullet, text, properties and children; only
its indentation loses one level, measured from where its own bullet
sits, so a graph indented by two spaces or by four lifts alike."
  (let* ((first-bullet (cl-find-if #'harness-logseq--bullet children))
         (shift (max 1 (- (harness-logseq--indent first-bullet) indent))))
    (mapcar (lambda (line)
              (if (string-blank-p line) line (harness-logseq--dedent line shift)))
            children)))

(defun harness-logseq--remove-chunks (lines text level)
  "Return LINES without a block at LEVEL that says TEXT, and its children.
A lifted child that only repeats the block that was removed is the same
repetition, not knowledge of its own; one that adds words stays."
  (let* ((wanted (downcase (harness-logseq--one-line (or text ""))))
         (blocks (harness-logseq-parse-blocks (mapconcat #'identity lines "\n")))
         (ranges nil))
    (dolist (block blocks)
      (when (and (equal level (plist-get block :indent))
                 (equal wanted
                        (downcase (harness-logseq--one-line
                                   (or (plist-get block :title) "")))))
        (push (cons (1- (plist-get block :line)) (plist-get block :end-line))
              ranges)))
    (dolist (range (nreverse ranges))
      (setq lines (append (cl-subseq lines 0 (car range))
                          (cl-subseq lines (cdr range)))))
    lines))

(defun harness-logseq--edit-remove (lines block)
  "Return LINES without BLOCK's own lines, its children lifted in its place.
Nothing under BLOCK is dropped with it: a child keeps its text, its
properties and its own children, one level up.  A lifted child that only
repeats BLOCK goes too, since it is the same repetition."
  (let* ((from (max 0 (1- (plist-get block :line))))
         (to (min (length lines) (plist-get block :end-line)))
         (parts (harness-logseq--block-parts lines block))
         (text (harness-logseq--one-line (or (plist-get block :title) "")))
         (indent (max 0 (plist-get block :indent)))
         (children (cdr parts))
         (lifted (harness-logseq--remove-chunks
                  (harness-logseq--children-lifted children indent) text indent)))
    (append (cl-subseq lines 0 from)
            lifted
            (cl-subseq lines to))))

(defun harness-logseq--own-end (lines block)
  "Return the index after BLOCK's own lines in LINES, 0-based.
That is its bullet, its continuation lines and its properties, not the
blocks indented under it."
  (let* ((parts (harness-logseq--block-parts lines block))
         (from (max 0 (1- (plist-get block :line)))))
    (+ from (length (car parts)))))

(defun harness-logseq--set-properties (lines opts)
  "Return LINES with OPTS' `:set' properties on the page's identity block.
A page whose first block carries no properties gets one at its top."
  (let ((out (copy-sequence lines)))
    (dolist (pair (plist-get opts :set))
      (let* ((key (car pair))
             (line (format "  %s:: %s" key (harness-logseq--one-line (cdr pair))))
             (pattern (format "\\`[ \t]*%s::" (regexp-quote key)))
             (replaced nil)
             (made nil))
        (setq out (cl-loop for text in out
                           collect (if (and (not replaced) (string-match-p pattern text))
                                       (progn (setq replaced t) line)
                                     text)))
        (unless replaced
          (let ((at (harness-logseq--first-block-end out)))
            (cond
             (at (setq out (append (cl-subseq out 0 at) (list line)
                                   (cl-subseq out at))))
             (made (setq out (append (cl-subseq out 0 1) (list line)
                                     (cl-subseq out 1))))
             (t
              (setq out (append (list "-" line) out)
                    made t)))))))
    out))

(harness-defmethod logseq/page-edit (name &optional opts)
  "Change page NAME of the graph at OPTS' `:root' in one read and write.
OPTS names what to do, and all of it happens in one atomic write:

`:remove' ids to remove, as `logseq/block-remove' takes them.  A block's
own lines go and the blocks indented under it are lifted in its place,
so a duplicate parent never takes distinct knowledge with it.

`:replace' an alist of (ID . TEXT): the block's text becomes TEXT and
its id, properties and children stay.

`:append' a list of plists, each `(:text TEXT :properties ALIST
:id ID)', appended as new blocks in the order given.

`:set' an alist of (KEY . VALUE) on the page's identity block, made
when the page has none.

`:expect' is a digest as `logseq/page-digest' gives one, or `absent' for
a page that must not exist.  A page whose digest is not the one expected
signals `harness-conflict': it changed since it was read, and the caller
works its change out again rather than saving a stale draft over it.

Return (:page :file :journal :digest :removed :replaced :appended),
or nil when the page is not there and `:create' is nil.  With `:create'
non-nil the page and the graph are made when missing.  The page as it was
is not in the answer: a caller that needs it reads it first, and nothing
here keeps a copy."
  (let* ((root (harness-logseq-root (plist-get opts :root)))
         (name (harness-logseq-page-name name))
         (journal (harness-logseq--journal-p name root))
         (file (if journal
                   (harness-logseq-journal-file name root)
                 (harness-logseq-page-file name root)))
         (before (harness-read-file file))
         (expect (if (eq (plist-get opts :expect) 'absent)
                     nil
                   (plist-get opts :expect)))
         (create (or (plist-get opts :create)
                     (plist-get opts :remove) (plist-get opts :replace)
                     (plist-get opts :append) (plist-get opts :set))))
    (when (and (plist-member opts :expect)
               (not (equal expect (and before (harness-logseq-digest before)))))
      (signal 'harness-conflict
              (list (format "Page %s changed since it was read" name))))
    (when (or before create)
      (harness-logseq--ensure-graph root)
      (let* ((content (or before ""))
             (lines (split-string content "\n"))
             (removed nil) (replaced nil) (appended 0))
        (dolist (id (plist-get opts :remove))
          (when-let* ((block (harness-logseq--find-block id lines name)))
            (let ((after (harness-logseq--edit-remove lines block)))
              (setq lines after)
              (push (harness-logseq--block-id block name) removed))))
        (dolist (pair (plist-get opts :replace))
          (let ((id (car pair))
                (text (cdr pair)))
            (when (stringp text)
              (when-let* ((block (harness-logseq--find-block id lines name)))
                (setq lines (harness-logseq--replace-block lines block text))
                (push (harness-logseq--block-id block name) replaced)))))
        (when (plist-get opts :set)
          (setq lines (harness-logseq--set-properties lines opts)))
        (let ((out (mapconcat #'identity lines "\n")))
          (dolist (item (plist-get opts :append))
            (let ((block (harness-logseq-render-block
                          (plist-get item :text)
                          (append (list (cons "id" (or (plist-get item :id)
                                                       (harness-logseq-uuid))))
                                  (plist-get item :properties)
                                  (list (cons "learned-at"
                                              (format-time-string
                                               "%Y-%m-%d %H:%M"
                                               (or (plist-get item :date)
                                                   (current-time)))))))))
              (setq out (concat out
                                (cond ((string-empty-p out) "")
                                      ((string-suffix-p "\n" out) "\n")
                                      (t "\n\n"))
                                block))
              (cl-incf appended)))
          (let ((digest (harness-logseq-digest out)))
            (unless (equal out content)
              (harness-write-file-atomically file out))
            (list :page name :file file :journal (and journal t) :digest digest
                  :removed (nreverse removed) :replaced (nreverse replaced)
                  :appended appended)))))))

(defun harness-logseq--find-block (id lines name)
  "Return the block of LINES whose id or line number is ID."
  (cl-find-if (lambda (candidate)
                (or (equal (harness-logseq--block-id candidate name) id)
                    (equal (format "%s" (plist-get candidate :line))
                           (format "%s" id))))
              (harness-logseq-parse-blocks (mapconcat #'identity lines "\n"))))

(defun harness-logseq--replace-block (lines block text)
  "Return LINES with BLOCK's own text replaced by TEXT, the rest kept.
That is the block's bullet and its continuation lines: its properties
stay under it, and so do the blocks indented under it, so a rewritten
statement keeps its id, its sources and its children."
  (let* ((from (max 0 (1- (plist-get block :line))))
         (own-end (harness-logseq--own-end lines block))
         (indent (max 0 (plist-get block :indent)))
         (own (cl-subseq lines from own-end))
         (properties (cl-loop for line in (cdr own)
                              when (harness-logseq--property line)
                              collect line))
         (new (harness-logseq--block-lines text))
         (pad (make-string indent ?\s))
         (head (concat pad "- " (car new)))
         (rest (mapcar (lambda (line) (concat pad "  " line)) (cdr new))))
    (append (cl-subseq lines 0 from)
            (cons head rest)
            ;; The property lines keep the indentation they had: the
            ;; block's own indent does not change, so they stay under it.
            properties
            (cl-subseq lines own-end))))

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
