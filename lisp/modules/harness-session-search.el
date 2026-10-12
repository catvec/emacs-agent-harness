;;; harness-session-search.el --- Search session transcripts: full text, regexp and meaning  -*- lexical-binding: t; -*-

;;; Commentary:

;; One search over the transcripts of every session, for the
;; `session_search' tool, the task board's search and the UI's
;; `harness-search-sessions'.
;;
;; The transcripts stay where they are, in the node logs
;; (sessions/ID.nodes.jsonl).  This module keeps an index of them in
;; SQLite: search.db, beside usage.db in the state directory, with a row
;; per node holding its readable text, and an FTS5 full-text index over
;; the rows.  The index is a cache.  Deleting search.db loses nothing:
;; it is built again from the logs, and `session/search-rebuild' does
;; that on demand.  It is a database of its own, not tables in usage.db,
;; because it grows about as large as the logs, while usage.db is small
;; and holds what nothing can rebuild.
;;
;; Keeping it current.  The index remembers how far it has read each log
;; (a byte offset), so bringing a session up to date reads only the
;; lines appended since.  An update line (the final text of a streamed
;; reply, a changed `:meta') is merged into the row of its node, so the
;; whole of every reply is searchable: grep over the logs sees only what
;; one line holds, and missed everything a reply streamed after its
;; first chunk.  Nodes are indexed shortly after they are written
;; (`session/node-added', `session/node-updated', `session/forked'); a
;; search first catches up with the logs that grew since; and the logs
;; never indexed are read in the background, a slice of a few tens of
;; milliseconds at a time, newest session first (`run-at-time': the
;; harness process has no idle time).  A deleted session's rows go with
;; it, in the background too.
;;
;; Modes (OPTS `:mode' of `session/search'):
;; - `text' (the default): full-text search.  A word matches whole words
;;   in any form ("parse" finds "parsing", porter stemming; case and
;;   accents are ignored), every word must match, "quoted words" match as
;;   a phrase, word* matches a prefix, OR between words matches either
;;   and -word excludes.  Best match first (BM25): each session is
;;   ranked by its best node, fused (reciprocal rank fusion) with the
;;   sessions whose name has the words and, when an embedding model is
;;   set, with how near in meaning they are.  When no session has every
;;   word, those with some of them come back, marked `:loose'; when
;;   none has any, the nearest in meaning, when there are vectors --
;;   those nearly as near as the nearest -- and the result says so
;;   (`:note').
;; - `literal' and `regexp': the text as given, or an extended regular
;;   expression as grep -E reads it, matched case-insensitively by grep
;;   over the logs, newest session first.  Update lines count: a node
;;   matches on the text it has in the end.
;; - `semantic': nearest in meaning only, by the vectors of the
;;   embedding model (`harness-session-search-embedding-model').
;; Without SQLite or FTS5, with `harness-session-search-index' off, or
;; while most of the logs a search covers are still to be indexed, text
;; mode falls back to grep for the text as typed, and the result says so
;; (`:note').
;;
;; Embeddings are off unless `harness-session-search-embedding-model'
;; names a model of a provider that embeds (`provider/embed'): an
;; OpenAI-compatible endpoint (OpenAI, OpenRouter, or a local Ollama,
;; LM Studio, llama.cpp or vLLM server), say
;; "openai:text-embedding-3-small".  Then the text of user messages,
;; replies, plans and compaction summaries is cut into chunks, embedded
;; in batches in the background, newest first, and stored as int8
;; vectors keyed by the hash of their chunk, so text met twice (the
;; history a fork copies) is embedded once.  A search embeds its query
;; and compares it with every vector, in Elisp, with integer arithmetic:
;; a fraction of a second for tens of thousands of chunks.  Changing the
;; model drops the vectors and embeds everything again.  The text goes to
;; the model's provider, which is why it is the user's choice; the
;; allowed models of the policy hold for it (`harness-allowed-models'),
;; and in corporate mode only a server on this machine embeds.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-files)

(defvar harness-state-directory)

;;;; Settings

(defcustom harness-session-search-index t
  "Non-nil keeps a full-text index of the session transcripts, in search.db.
With it, text search ranks sessions by relevance and matches words in
any form.  The index takes about as much disk as the transcripts, and
is a cache: the transcripts stay in their logs, and the index is built
again from them when it is missing.  Nil searches the logs with grep,
for the text as typed."
  :type 'boolean
  :group 'harness)

(defcustom harness-session-search-embedding-model nil
  "Model that embeds session text for semantic search, as PROVIDER:NAME, or nil.
Nil (the default) leaves semantic search off; text, literal and regexp
search need no model.  The models of OpenAI-compatible endpoints embed
\(see `harness-openai-endpoints'): \"openai:text-embedding-3-small\", or
a local server's, such as \"local:nomic-embed-text\" for Ollama at
http://localhost:11434/v1.  With a model set, the text of messages,
replies, plans and summaries goes to its provider, in the background,
until every transcript is embedded; changing the model embeds all of it
again.  In corporate mode only a server on this machine embeds."
  :type '(choice (const :tag "None: no semantic search" nil)
                 (string :tag "Model" :names model))
  :group 'harness)

(defcustom harness-session-search-embedding-dimensions nil
  "Length of the vectors to ask the embedding model for, or nil for its own.
Models that can shorten their vectors (OpenAI's text-embedding-3) take
it: shorter vectors take less space and compare faster, for a little
less precision.  Changing it embeds everything again."
  :type '(choice (const :tag "The model's own" nil) (integer :tag "Dimensions"))
  :group 'harness)

;;;; Constants

(defconst harness-session-search--db-name "search"
  "Name of the index database in the state directory, without .db.")

(defconst harness-session-search--schema-version 1
  "Version of the index's tables; an index of another version is built anew.")

(defconst harness-session-search-kinds
  '(user assistant thinking tool-call tool-result plan compaction)
  "Kinds of transcript node a search looks at.")

(defconst harness-session-search--embed-kinds '(user assistant plan compaction)
  "Kinds of node whose text is embedded for semantic search.
Thinking and tool output are left out: they are long, and seldom what a
search by meaning is after.")

(defconst harness-session-search--sync-delay 1.0
  "Seconds after a node is written that its session's log is indexed.")

(defconst harness-session-search--start-delay 5
  "Seconds after the module starts that the background starts indexing.")

(defconst harness-session-search--slice 0.05
  "Seconds of work one step of the background does before it yields.")

(defconst harness-session-search--gap 0.1
  "Seconds between two steps of the background.")

(defconst harness-session-search--read-bytes (* 512 1024)
  "Bytes of a log read and indexed at a time; more when a line is longer.")

(defconst harness-session-search--catch-up-bytes (* 4 1024 1024)
  "Most bytes of logs a search indexes before it runs.
A search first indexes what the logs it covers gained since they were
last indexed.  When that is more, the index is still being built: text
search falls back to grep, and the background goes on building.")

(defconst harness-session-search--max-text (* 4 1024 1024)
  "Most characters of one node's text the index holds.")

(defconst harness-session-search--max-sql-ids 5000
  "Most session ids a query names; with more, its results are filtered after.")

(defconst harness-session-search--grep-program "grep"
  "Program that searches the logs for literal and regexp search.")

(defconst harness-session-search--piece 50000
  "Length of the pieces of a long text a regexp is run over one at a time.
A regexp like `a.*b' overflows the matcher over a line of a megabyte,
but not over a piece this long; see `harness-session-search--locate'.")

(defconst harness-session-search--snippet-tokens 24
  "Words of context FTS5 puts in the snippet of a text match.")

(defconst harness-session-search--snippet-chars 300
  "Most characters of a snippet.")

(defconst harness-session-search--rrf-k 60
  "Constant of the reciprocal rank fusion of rankings: 1/(K + rank).")

(defconst harness-session-search--mark-start #xE000
  "What starts a match in the snippets FTS5 makes: a private-use character.")

(defconst harness-session-search--mark-end #xE001
  "What ends a match in the snippets FTS5 makes.")

(defconst harness-session-search--chunk-chars 1200
  "Most characters of one embedded chunk of text.
Small enough for the context of small local embedding models.")

(defconst harness-session-search--chunks-per-node 8
  "Most chunks of one node that are embedded: about its first 10000 characters.")

(defconst harness-session-search--embed-batch 16
  "Most chunks one embedding request carries.")

(defconst harness-session-search--embed-backoff-max 600
  "Most seconds the background waits after failed embedding requests.")

(defconst harness-session-search--semantic-limit 200
  "Nodes nearest in meaning a search takes from the vectors.")

(defconst harness-session-search--near-share 0.8
  "Share of the best score a session needs to stand in for missing words.
When no session has the words of a text search, the sessions nearest in
meaning stand in for them, but only those this near the nearest: every
session is somewhere in meaning, and most only far.")

;;;; State

(defvar harness-session-search--db nil
  "The index database whose schema is in place, or nil.")

(defvar harness-session-search--failure nil
  "(DIRECTORY . REASON) when the index cannot be had in that state directory.")

(defvar harness-session-search--dirty (make-hash-table :test 'equal)
  "Sessions whose logs were written to since they were last indexed.")

(defvar harness-session-search--doomed nil
  "Sessions deleted, or unknown, whose rows are still to go.")

(defvar harness-session-search--queue t
  "Sessions the background is still to index, t when it is to list them.")

(defvar harness-session-search--timer nil
  "(DIRECTORY . TIMER) of the next step of the background, or nil.")

(defvar harness-session-search--embedding nil
  "Non-nil while an embedding request is in flight.")

(defvar harness-session-search--embed-failure nil
  "(TIME . MESSAGE) of the last failed embedding request, or nil.")

(defvar harness-session-search--embed-backoff 0
  "Seconds the background waits before its next embedding request after a failure.")

(defvar harness-session-search--embed-size harness-session-search--embed-batch
  "Chunks the next embedding request carries: fewer after a failure.")

(defvar harness-session-search--embed-shrink 0
  "Times a chunk is halved before it is embedded, after a single chunk failed.
A chunk too long for the model's context fails however few go together;
its first half, or quarter, embeds it near enough.")

(defvar harness-session-search--vectors nil
  "The vectors held in memory, a plist.
`:key' says of what, then `:nodes', `:sessions', `:kinds', `:parts',
`:scales' and `:blobs', vectors of one element per chunk.")

(defvar harness-session-search--query-vectors nil
  "Recent query embeddings: ((KEY . VECTOR) ...), newest first.")

;;;; Small helpers

(defun harness-session-search--message (err)
  "Return the message of ERR, without the name of its error symbol."
  (if (and (consp err) (memq (car err) '(error harness-error user-error)) (stringp (cadr err)))
      (cadr err)
    (harness-error-message err)))

(defun harness-session-search--fail (fmt &rest args)
  "Signal a `harness-error' with the message FMT formats with ARGS."
  (signal 'harness-error (list (apply #'format fmt args))))

(defun harness-session-search--placeholders (list)
  "Return \"?, ?, …\", one for each element of LIST."
  (mapconcat (lambda (_) "?") list ", "))

(defun harness-session-search--set (list)
  "Return a hash table with the elements of LIST as keys, or nil when LIST is."
  (when list
    (let ((h (make-hash-table :test 'equal)))
      (dolist (x list h) (puthash x t h)))))

(defun harness-session-search--kind (value)
  "Return the symbol VALUE names, a node kind or a mode, or nil."
  (cond ((and value (symbolp value) (not (keywordp value))) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))))

;;;; The database

(defconst harness-session-search--schema
  '("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)"
    "CREATE TABLE IF NOT EXISTS logs (session TEXT PRIMARY KEY, offset INTEGER NOT NULL)"
    "CREATE TABLE IF NOT EXISTS nodes (id INTEGER PRIMARY KEY, session TEXT NOT NULL, node TEXT NOT NULL, kind TEXT NOT NULL, tool TEXT, ts REAL, sender TEXT, text TEXT NOT NULL, embedded INTEGER, UNIQUE (session, node))"
    "CREATE INDEX IF NOT EXISTS nodes_unembedded ON nodes (id) WHERE embedded IS NULL"
    "CREATE TABLE IF NOT EXISTS vectors (hash TEXT PRIMARY KEY, scale REAL NOT NULL, vec BLOB NOT NULL)"
    "CREATE TABLE IF NOT EXISTS chunks (id INTEGER PRIMARY KEY AUTOINCREMENT, node INTEGER NOT NULL, part INTEGER NOT NULL, hash TEXT NOT NULL, UNIQUE (node, part))"
    "CREATE INDEX IF NOT EXISTS chunks_hash ON chunks (hash)"
    "CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(text, content='nodes', content_rowid='id', tokenize='porter unicode61 remove_diacritics 2')"
    "CREATE TRIGGER IF NOT EXISTS nodes_ai AFTER INSERT ON nodes BEGIN INSERT INTO nodes_fts (rowid, text) VALUES (new.id, new.text); END"
    "CREATE TRIGGER IF NOT EXISTS nodes_ad AFTER DELETE ON nodes BEGIN INSERT INTO nodes_fts (nodes_fts, rowid, text) VALUES ('delete', old.id, old.text); DELETE FROM chunks WHERE node = old.id; END"
    "CREATE TRIGGER IF NOT EXISTS nodes_au AFTER UPDATE OF text ON nodes WHEN old.text IS NOT new.text BEGIN INSERT INTO nodes_fts (nodes_fts, rowid, text) VALUES ('delete', old.id, old.text); INSERT INTO nodes_fts (rowid, text) VALUES (new.id, new.text); DELETE FROM chunks WHERE node = old.id; END")
  "Statements that make the index's tables.
A node's row is written with an upsert, never INSERT OR REPLACE: a
replace deletes the old row without the delete trigger (recursive
triggers are off), which would leave its words in the full-text index.")

(defun harness-session-search--drop (db)
  "Drop every table of the index in DB."
  (dolist (sql '("DROP TRIGGER IF EXISTS nodes_ai" "DROP TRIGGER IF EXISTS nodes_ad"
                 "DROP TRIGGER IF EXISTS nodes_au" "DROP TABLE IF EXISTS nodes_fts"
                 "DROP TABLE IF EXISTS chunks" "DROP TABLE IF EXISTS vectors"
                 "DROP TABLE IF EXISTS nodes" "DROP TABLE IF EXISTS logs"
                 "DROP TABLE IF EXISTS meta"))
    (sqlite-execute db sql)))

(defun harness-session-search--ensure-schema (db)
  "Make the index's tables in DB, anew when they are of another version."
  (ignore-errors (sqlite-pragma db "journal_mode=WAL"))
  (ignore-errors (sqlite-pragma db "synchronous=NORMAL"))
  (let ((version (number-to-string harness-session-search--schema-version))
        (have (ignore-errors (caar (sqlite-select db "SELECT value FROM meta WHERE key = 'schema'")))))
    (unless (equal have version)
      (harness-session-search--drop db))
    (dolist (sql harness-session-search--schema) (sqlite-execute db sql))
    (unless (equal have version)
      (sqlite-execute db "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema', ?)" (list version)))))

(defun harness-session-search--reset ()
  "Forget what the background knew of the database it used before."
  (clrhash harness-session-search--dirty)
  (setq harness-session-search--doomed nil
        harness-session-search--queue t
        harness-session-search--vectors nil
        harness-session-search--query-vectors nil
        harness-session-search--embed-failure nil
        harness-session-search--embed-backoff 0
        harness-session-search--embed-size harness-session-search--embed-batch
        harness-session-search--embed-shrink 0))

(defun harness-session-search--db ()
  "Return the index database with its tables in place, or nil without one.
There is none when `harness-session-search-index' is off, when this
Emacs has no SQLite, and when the database cannot be opened or set up,
which FTS5 missing from SQLite does; `session/search-status' says why."
  (when harness-session-search-index
    (let ((dir (expand-file-name harness-state-directory)))
      (unless (equal (car harness-session-search--failure) dir)
        (let ((db (condition-case err
                      (harness-call 'store/sqlite harness-session-search--db-name)
                    (error (setq harness-session-search--failure
                                 (cons dir (format "cannot open search.db: %s"
                                                   (harness-session-search--message err))))
                           nil))))
          (cond
           ((null db)
            (unless (equal (car harness-session-search--failure) dir)
              (setq harness-session-search--failure (cons dir "this Emacs has no SQLite")))
            nil)
           ((eq db harness-session-search--db) db)
           ((condition-case err
                (progn (harness-session-search--ensure-schema db) t)
              (error
               (setq harness-session-search--failure
                     (cons dir (format "cannot set up search.db: %s" (harness-session-search--message err))))
               nil))
            (harness-session-search--reset)
            (setq harness-session-search--db db))))))))

(defun harness-session-search--unavailable ()
  "Return why there is no index, or nil when there is one."
  (cond ((not harness-session-search-index) "harness-session-search-index is off")
        ((harness-session-search--db) nil)
        ((equal (car harness-session-search--failure) (expand-file-name harness-state-directory))
         (cdr harness-session-search--failure))
        (t "no index")))

(defmacro harness-session-search--transaction (db &rest body)
  "Run BODY in a transaction of DB: commit if it returns, roll back if it fails."
  (declare (indent 1))
  (let ((d (make-symbol "db")) (ok (make-symbol "ok")))
    `(let ((,d ,db) (,ok nil))
       (sqlite-transaction ,d)
       (unwind-protect
           (prog1 (progn ,@body) (setq ,ok t))
         (if ,ok (sqlite-commit ,d) (ignore-errors (sqlite-rollback ,d)))))))

;;;; Text of a node

(defun harness-session-search--string (value)
  "Return VALUE as text: a string as it is, the text blocks of a list joined."
  (cond ((stringp value) value)
        ((and (consp value) (consp (car value)))
         (mapconcat (lambda (b) (let ((s (and (consp b) (plist-get b :text)))) (if (stringp s) s "")))
                    value "\n"))
        (t "")))

(defun harness-session-search--cap (text)
  "Return TEXT cut to `harness-session-search--max-text' characters."
  (if (> (length text) harness-session-search--max-text)
      (substring text 0 harness-session-search--max-text)
    text))

(defun harness-session-search--tool-text (tool input-json)
  "Return the searchable text of a call of TOOL with input INPUT-JSON."
  (let ((tool (or tool "")))
    (if (string-empty-p input-json) tool (concat tool " " input-json))))

(defun harness-session-search-node-text (node)
  "Return the searchable text of transcript NODE.
A tool call reads as the tool's name, as the model knows it, and its
input as JSON; a tool result as its output; anything else as its content."
  (pcase (harness-session-search--kind (plist-get node :kind))
    ('tool-call (harness-session-search--tool-text
                 (or (plist-get node :tool) (plist-get node :title))
                 (let ((input (plist-get node :input))) (if input (harness-json-encode-text input) ""))))
    ('tool-result (harness-session-search--string (plist-get node :output)))
    (_ (harness-session-search--string (plist-get node :content)))))

(defun harness-session-search--sender (meta)
  "Return who sent a user message with META, as JSON text, or nil for the user."
  (let ((from (plist-get meta :from)))
    (and (harness-sender-kind from) (harness-json-encode-text from))))

(defun harness-session-search--entry (rec)
  "Return the index entry of node REC read from a log, or nil.
Nil when REC is of a kind no search looks at."
  (let ((kind (harness-session-search--kind (plist-get rec :kind))))
    (when (memq kind harness-session-search-kinds)
      (list :kind kind
            :tool (and (eq kind 'tool-call) (or (plist-get rec :tool) (plist-get rec :title)))
            :ts (and (numberp (plist-get rec :ts)) (float (plist-get rec :ts)))
            :sender (and (eq kind 'user) (harness-session-search--sender (plist-get rec :meta)))
            :text (harness-session-search--cap (harness-session-search-node-text (plist-put rec :kind kind)))))))

(defun harness-session-search--apply-update (entry rec)
  "Return index ENTRY with update REC of its node merged in.
An update replaces the keys it has, as `session/update-node' does: the
content or output, a tool call's input, the `:meta' and with it who sent
a message."
  (let ((e (copy-sequence entry))
        (kind (plist-get entry :kind)))
    (pcase kind
      ('tool-call
       (when (or (plist-member rec :tool) (plist-member rec :input))
         (let* ((old-tool (or (plist-get e :tool) ""))
                (old (plist-get e :text))
                (tool (or (plist-get rec :tool) old-tool))
                (input (if (plist-member rec :input)
                           (let ((i (plist-get rec :input))) (if i (harness-json-encode-text i) ""))
                         (if (string-prefix-p (concat old-tool " ") old)
                             (substring old (1+ (length old-tool)))
                           ""))))
           (setq e (plist-put e :tool tool))
           (setq e (plist-put e :text (harness-session-search--cap
                                       (harness-session-search--tool-text tool input)))))))
      ('tool-result
       (when (plist-member rec :output)
         (setq e (plist-put e :text (harness-session-search--cap
                                     (harness-session-search--string (plist-get rec :output)))))))
      (_
       (when (plist-member rec :content)
         (setq e (plist-put e :text (harness-session-search--cap
                                     (harness-session-search--string (plist-get rec :content))))))))
    (when (and (eq kind 'user) (plist-member rec :meta))
      (setq e (plist-put e :sender (harness-session-search--sender (plist-get rec :meta)))))
    e))

(defun harness-session-search--stored-entry (db sid node-id)
  "Return the index entry DB holds for node NODE-ID of session SID, or nil."
  (when-let* ((row (car (sqlite-select db "SELECT kind, tool, ts, sender, text FROM nodes WHERE session = ? AND node = ?"
                                       (list sid node-id)))))
    (list :kind (intern (nth 0 row)) :tool (nth 1 row) :ts (nth 2 row) :sender (nth 3 row) :text (nth 4 row))))

;;;; Indexing a log

(defun harness-session-search--log (sid)
  "Return the file name of the node log of session SID."
  (expand-file-name (concat sid ".nodes.jsonl") (expand-file-name "sessions" harness-state-directory)))

(defun harness-session-search--log-size (sid)
  "Return the size in bytes of the node log of SID, or nil when it has none."
  (file-attribute-size (file-attributes (harness-session-search--log sid))))

(defun harness-session-search--index-buffer (db sid)
  "Return (ORDER . ENTRIES) of the log lines of session SID in this buffer.
ENTRIES maps a node id to its index entry, updates merged, an update
of a node written before merged into its row in DB, the index; ORDER
lists the ids in the order they came.  A line that does not parse is
skipped, as the session's own loading skips it."
  (let ((entries (make-hash-table :test 'equal))
        (order nil))
    (goto-char (point-min))
    (while (not (eobp))
      (let ((start (point)))
        (skip-chars-forward " \t\r")
        (unless (eolp)
          (let ((rec (condition-case nil (harness-json-parse-buffer) (error nil))))
            (when (consp rec)
              (let ((id (plist-get rec :id)))
                (when (stringp id)
                  (if (equal (plist-get rec :_op) "update")
                      (when-let* ((base (or (gethash id entries)
                                            (harness-session-search--stored-entry db sid id))))
                        (unless (gethash id entries) (push id order))
                        (puthash id (harness-session-search--apply-update base rec) entries))
                    (when-let* ((entry (harness-session-search--entry rec)))
                      (unless (gethash id entries) (push id order))
                      (puthash id entry entries))))))))
        (goto-char start)
        (forward-line 1)))
    (cons (nreverse order) entries)))

(defun harness-session-search--write (db sid order entries offset)
  "Store ENTRIES of session SID in DB, in ORDER, and its log read to OFFSET."
  (harness-session-search--transaction db
    (dolist (id order)
      (let* ((e (gethash id entries))
             (kind (plist-get e :kind)))
        (sqlite-execute
         db (concat "INSERT INTO nodes (session, node, kind, tool, ts, sender, text, embedded) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
                    "ON CONFLICT (session, node) DO UPDATE SET kind = excluded.kind, tool = excluded.tool, "
                    "ts = excluded.ts, sender = excluded.sender, text = excluded.text, "
                    "embedded = CASE WHEN nodes.text IS excluded.text THEN nodes.embedded ELSE excluded.embedded END")
         (list sid id (symbol-name kind) (plist-get e :tool) (plist-get e :ts) (plist-get e :sender)
               (plist-get e :text) (if (memq kind harness-session-search--embed-kinds) nil 0)))))
    (sqlite-execute db "INSERT INTO logs (session, offset) VALUES (?, ?) ON CONFLICT (session) DO UPDATE SET offset = excluded.offset"
                    (list sid offset))))

(defun harness-session-search--read-chunk (db sid file offset size)
  "Index in DB the complete lines of FILE, SID's log of SIZE bytes, from OFFSET.
Read `harness-session-search--read-bytes' at a time, more for a longer
line.  Return the offset after the last complete line read, OFFSET when
there is none yet (a line still being written)."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((want harness-session-search--read-bytes)
          (end nil))
      (while (progn
               (erase-buffer)
               (insert-file-contents-literally file nil offset (min size (+ offset want)))
               (goto-char (point-max))
               (setq end (and (search-backward "\n" nil t) (1+ (point))))
               (and (null end) (< (+ offset want) size)))
        (setq want (* 2 want)))
      (if (null end)
          offset
        (delete-region end (point-max))
        (set-buffer-multibyte t)
        (decode-coding-region (point-min) (point-max) 'utf-8-unix)
        (let ((read (harness-session-search--index-buffer db sid))
              (next (+ offset (1- end))))
          (harness-session-search--write db sid (car read) (cdr read) next)
          next)))))

(defun harness-session-search--forget (db sid &optional limit)
  "Drop the rows of session SID from DB, at most LIMIT nodes of them.
Return non-nil when none is left."
  (let ((n (if limit
               (sqlite-execute db "DELETE FROM nodes WHERE id IN (SELECT id FROM nodes WHERE session = ? LIMIT ?)"
                               (list sid limit))
             (sqlite-execute db "DELETE FROM nodes WHERE session = ?" (list sid)))))
    (when (or (null limit) (< n limit))
      (sqlite-execute db "DELETE FROM logs WHERE session = ?" (list sid))
      t)))

(defun harness-session-search--sync (db sid &optional deadline)
  "Index what the log of session SID holds beyond what DB has read.
Stop at DEADLINE, a `float-time', between chunks.  Return non-nil when
the log is read to its end, or gone.  A log that shrank was replaced:
it is indexed again from its start."
  (let* ((file (harness-session-search--log sid))
         (size (file-attribute-size (file-attributes file)))
         (offset (or (caar (sqlite-select db "SELECT offset FROM logs WHERE session = ?" (list sid))) 0)))
    (cond
     ((null size)
      (when (> offset 0) (harness-session-search--forget db sid))
      t)
     (t
      (when (< size offset)
        (harness-session-search--forget db sid)
        (setq offset 0))
      (let ((moved t))
        (while (and moved (< offset size) (or (null deadline) (< (float-time) deadline)))
          (let ((next (harness-session-search--read-chunk db sid file offset size)))
            (setq moved (> next offset) offset next)))
        (or (>= offset size) (not moved)))))))

(defun harness-session-search--backlog (db &optional ids)
  "Return (STALE . BYTES) for sessions IDS (default all): what DB has yet to index.
STALE are the sessions whose logs DB has not read whole, in the order
of IDS (newest first by default, as `session/list' orders them); BYTES
how much of their logs is left."
  (let ((offsets (make-hash-table :test 'equal))
        (stale nil) (bytes 0))
    (dolist (row (sqlite-select db "SELECT session, offset FROM logs"))
      (puthash (car row) (cadr row) offsets))
    (dolist (id (or ids (mapcar (lambda (s) (plist-get s :id)) (harness-call 'session/list))))
      (let ((size (harness-session-search--log-size id))
            (done (gethash id offsets 0)))
        (when (and size (/= size done))
          (push id stale)
          (cl-incf bytes (if (< size done) size (- size done))))))
    (cons (nreverse stale) bytes)))

(defun harness-session-search--catch-up (db ids)
  "Index in DB what the logs of IDS gained since, when that is little.
Return non-nil when the index is up to date with all of them; nil when
too much is left, which the background goes on with."
  (pcase-let ((`(,stale . ,bytes) (harness-session-search--backlog db ids)))
    (or (null stale)
        (when (<= bytes harness-session-search--catch-up-bytes)
          (dolist (id stale) (harness-session-search--sync db id))
          t))))

(defun harness-session-search--progress (db)
  "Return how much of the logs DB has indexed, a percentage, or nil when all."
  (let* ((ids (mapcar (lambda (s) (plist-get s :id)) (harness-call 'session/list)))
         (total (cl-loop for id in ids for size = (harness-session-search--log-size id) when size sum size))
         (left (cdr (harness-session-search--backlog db ids))))
    (and (> left 0) (> total 0) (floor (* 100 (- total left)) total))))

(defun harness-session-search--gc (db)
  "Have the background drop the rows in DB of sessions that no longer exist."
  (dolist (row (sqlite-select db "SELECT session FROM logs"))
    (unless (harness-call 'session/exists-p (car row))
      (cl-pushnew (car row) harness-session-search--doomed :test #'equal))))

;;;; The background

(defun harness-session-search--schedule (&optional delay)
  "Run a step of the background in DELAY seconds, unless one is due sooner.
A step due for another state directory is dropped."
  (let* ((dir (expand-file-name harness-state-directory))
         (delay (or delay harness-session-search--gap))
         (pending harness-session-search--timer)
         (timer (cdr pending)))
    (unless (and pending (equal (car pending) dir) (memq timer timer-list)
                 (<= (- (timer-until timer (current-time))) delay))
      (when timer (cancel-timer timer))
      (setq harness-session-search--timer
            (cons dir (run-at-time delay nil #'harness-session-search--work dir))))))

(defun harness-session-search--work (dir)
  "Do a slice of the background's work for state directory DIR, and go on later.
Nothing is done once DIR is not the state directory, or gone: a test's
directory, say."
  (setq harness-session-search--timer nil)
  (when (and harness-session-search-index
             (equal dir (expand-file-name harness-state-directory))
             (file-directory-p dir))
    (when-let* ((db (harness-session-search--db)))
      (let ((more (condition-case err
                      (harness-session-search--step db (+ (float-time) harness-session-search--slice))
                    (error (harness-log 'warn "session-search: indexing failed: %s"
                                        (harness-session-search--message err))
                           nil))))
        (when more (harness-session-search--schedule))))))

(defun harness-session-search--step (db deadline)
  "Do the background's work in DB until DEADLINE; non-nil when some is left.
Deleted sessions go first, then the sessions written to, then the logs
never indexed, newest first; then the next embedding request starts."
  (let ((before (lambda () (< (float-time) deadline))))
    (while (and harness-session-search--doomed (funcall before))
      (when (harness-session-search--forget db (car harness-session-search--doomed) 2000)
        (pop harness-session-search--doomed)))
    (let ((ids (hash-table-keys harness-session-search--dirty)))
      (while (and ids (funcall before))
        (when (harness-session-search--sync db (car ids) deadline)
          (remhash (car ids) harness-session-search--dirty))
        (pop ids)))
    (when (and (eq harness-session-search--queue t) (funcall before))
      (harness-session-search--gc db)
      (setq harness-session-search--queue (car (harness-session-search--backlog db))))
    (while (and (consp harness-session-search--queue) (funcall before))
      (when (harness-session-search--sync db (car harness-session-search--queue) deadline)
        (pop harness-session-search--queue)))
    (when (funcall before)
      (harness-session-search--embed-next db))
    (or harness-session-search--doomed
        (> (hash-table-count harness-session-search--dirty) 0)
        harness-session-search--queue)))

(defun harness-session-search--on-written (sid &rest _)
  "Note that the log of session SID was written to; index it soon."
  (when (and harness-session-search-index (stringp sid))
    (puthash sid t harness-session-search--dirty)
    (harness-session-search--schedule harness-session-search--sync-delay)))

(defun harness-session-search--on-node-updated (sid _node transient)
  "Note a persisted update of a node of SID.
A TRANSIENT update, a streamed delta, is not written, and is no news."
  (unless transient (harness-session-search--on-written sid)))

(defun harness-session-search--on-forked (_parent child &rest _)
  "Index the history a fork copied into the log of CHILD."
  (harness-session-search--on-written child))

(defun harness-session-search--on-deleted (sid &rest _)
  "Drop the rows of deleted session SID, in the background."
  (when (and harness-session-search-index (stringp sid))
    (remhash sid harness-session-search--dirty)
    (cl-pushnew sid harness-session-search--doomed :test #'equal)
    (harness-session-search--schedule)))

;;;; Full-text queries

(defun harness-session-search--parse-query (query)
  "Return the terms of text QUERY: a list of plists and the symbol `or'.
A term has `:text', and `:neg' for -word, `:prefix' for word*, `:phrase'
for \"quoted words\".  A term without a letter or digit, which no word of
the index can match, is dropped."
  (let ((pos 0) items)
    (while (string-match "\\(-\\)?\\(?:\"\\([^\"]*\\)\"?\\|\\([^ \t\n\r\"]+\\)\\)" query pos)
      (setq pos (max (1+ pos) (match-end 0)))
      (let* ((neg (and (match-beginning 1) t))
             (phrase (match-string 2 query))
             (word (match-string 3 query))
             (text (or phrase word))
             (prefix nil))
        ;; "--flag" is a word with dashes, not the exclusion of "-flag".
        (when (and neg word (string-prefix-p "-" word))
          (setq neg nil text (concat "-" word)))
        (if (and word (not neg) (equal word "OR"))
            (push 'or items)
          (when (and word (string-suffix-p "*" text))
            (setq prefix t text (string-trim-right text "\\*+")))
          (when (string-match-p "[[:alnum:]]" text)
            (push (list :text text :neg neg :prefix prefix :phrase (and phrase t)) items)))))
    (nreverse items)))

(defun harness-session-search--fts-term (term)
  "Return TERM as an FTS5 string: in double quotes, a prefix marked with *."
  (concat "\"" (string-replace "\"" "\"\"" (plist-get term :text)) "\""
          (if (plist-get term :prefix) "*" "")))

(defun harness-session-search--fts-expression (items &optional loose)
  "Return the FTS5 MATCH expression of query ITEMS, or nil when none is positive.
Words are ANDed, or ORed when LOOSE; OR joins its neighbours; the
negated ones are excluded.  With no word but negated ones, those are
looked for instead."
  (let (groups negs or-next)
    (dolist (item items)
      (cond ((eq item 'or) (setq or-next (and groups t)))
            ((plist-get item :neg) (push item negs))
            ((and or-next groups) (push item (car groups)) (setq or-next nil))
            (t (push (list item) groups) (setq or-next nil))))
    (when (and (null groups) negs)
      (setq groups (mapcar #'list negs) negs nil))
    (when groups
      (let* ((group-text (lambda (g)
                           (if (cdr g)
                               (concat "(" (mapconcat #'harness-session-search--fts-term (reverse g) " OR ") ")")
                             (harness-session-search--fts-term (car g)))))
             (positive (mapconcat group-text (reverse groups) (if loose " OR " " AND "))))
        (if negs
            (concat "(" positive ") NOT (" (mapconcat #'harness-session-search--fts-term (reverse negs) " OR ") ")")
          positive)))))

(defun harness-session-search--loose-p (items)
  "Non-nil when query ITEMS are several plain words: a loose search may help."
  (and (cl-every (lambda (i) (and (consp i) (not (plist-get i :neg)) (not (plist-get i :phrase)))) items)
       (cdr items)))

(defun harness-session-search--fts (db expr ids kinds max-matches)
  "Return the sessions with nodes matching FTS5 EXPR in DB, best first.
Only sessions IDS (all when nil) and nodes of KINDS (all when nil)
count.  Each is (SID BEST TOTAL HITS): its best score (BM25, lower is
better), how many of its nodes match and the best MAX-MATCHES of them,
plists with `:rowid' `:node' `:kind' `:tool' `:ts' `:sender' `:score'.
The scores are read in a materialized CTE: bm25() reads nothing from a
query that wraps the match in a subquery or an aggregate."
  (let* ((rows (sqlite-select
                db
                (concat "WITH m AS MATERIALIZED (SELECT rowid AS id, bm25(nodes_fts) AS score FROM nodes_fts WHERE nodes_fts MATCH ?), "
                        "h AS (SELECT n.id, n.session, n.node, n.kind, n.tool, n.ts, n.sender, m.score, "
                        "row_number() OVER (PARTITION BY n.session ORDER BY m.score, n.id DESC) AS r, "
                        "count(*) OVER (PARTITION BY n.session) AS total, "
                        "min(m.score) OVER (PARTITION BY n.session) AS best "
                        "FROM m JOIN nodes n ON n.id = m.id WHERE 1"
                        (if ids (format " AND n.session IN (%s)" (harness-session-search--placeholders ids)) "")
                        (if kinds (format " AND n.kind IN (%s)" (harness-session-search--placeholders kinds)) "")
                        ") SELECT id, session, node, kind, tool, ts, sender, score, total, best FROM h "
                        "WHERE r <= ? ORDER BY best, session, r")
                (append (list expr) ids (mapcar #'symbol-name kinds) (list (max 1 max-matches)))))
         (out nil))
    (dolist (row rows)
      (pcase-let ((`(,rowid ,sid ,node ,kind ,tool ,ts ,sender ,score ,total ,best) row))
        (unless (equal (car (car out)) sid)
          (push (list sid best total nil) out))
        (push (list :rowid rowid :node node :kind (intern kind) :tool tool :ts ts :sender sender :score score)
              (nth 3 (car out)))))
    (mapcar (lambda (s) (list (nth 0 s) (nth 1 s) (nth 2 s) (nreverse (nth 3 s)))) (nreverse out))))

(defun harness-session-search--fts-snippets (db expr rowids)
  "Return a table of the FTS5 snippets of ROWIDS of DB where EXPR matches.
It maps a rowid to (TEXT CUT-BEFORE CUT-AFTER).  TEXT marks each
match with `harness-session-search--mark-start' and `--mark-end'.  A
snippet longer than a few thousand characters (FTS5 keeps a word of a
megabyte whole) comes cut around its first match, and the flags say
where it was cut."
  (let ((table (make-hash-table)))
    (when rowids
      (dolist (row (sqlite-select
                    db
                    (format (concat "WITH s AS MATERIALIZED (SELECT rowid AS id, snippet(nodes_fts, 0, char(57344), char(57345), '…', %d) AS t "
                                    "FROM nodes_fts WHERE nodes_fts MATCH ? AND rowid IN (%s)), "
                                    "c AS (SELECT id, t, max(1, instr(t, char(57344)) - 600) AS f FROM s) "
                                    "SELECT id, CASE WHEN length(t) <= 3000 THEN t ELSE substr(t, f, 3000) END, "
                                    "length(t) > 3000 AND f > 1, length(t) > 3000 AND f + 3000 <= length(t) FROM c")
                            harness-session-search--snippet-tokens
                            (harness-session-search--placeholders rowids))
                    (cons expr rowids)))
        (puthash (nth 0 row) (list (nth 1 row) (eql (nth 2 row) 1) (eql (nth 3 row) 1)) table)))
    table))

;;;; Snippets

(defun harness-session-search--squeeze (text)
  "Return TEXT with each run of whitespace made one space."
  (replace-regexp-in-string "[ \t\n\r]+" " " text t t))

(defun harness-session-search--locate (text query regexp)
  "Return (START . END) of the first match of QUERY in TEXT, or nil.
QUERY is literal text, or an Emacs regexp when REGEXP is non-nil; case
is ignored.  Literal text is found by one linear scan, however long
TEXT is.  A regexp that overflows the matcher over the whole of TEXT,
as `a.*b' does over a line of a megabyte, runs over overlapping pieces
of `harness-session-search--piece' characters instead; a regexp Emacs
cannot read finds nothing."
  (let ((re (if regexp query (regexp-quote query)))
        (case-fold-search t))
    (condition-case nil
        (and (string-match re text) (cons (match-beginning 0) (match-end 0)))
      (invalid-regexp nil)
      (error
       (let ((len (length text))
             (piece harness-session-search--piece))
         ;; Each piece overlaps the next by half, so a match up to half a
         ;; piece long lies whole in one of them.
         (cl-loop for at from 0 below len by (/ piece 2)
                  for part = (substring text at (min len (+ at piece)))
                  when (ignore-errors (string-match re part))
                  return (cons (+ at (match-beginning 0)) (+ at (match-end 0)))))))))

(defun harness-session-search--snippet (text query regexp)
  "Return (SNIPPET . RANGES): the part of TEXT around the first match of QUERY.
QUERY is literal text, or an Emacs regexp when REGEXP is non-nil.  The
snippet is one line, its whitespace squeezed: up to 70 characters before
the match, the match and up to 90 after it, cut 300 characters after the
start of a long match.  RANGES is ((START END)), where the match is in
SNIPPET, or nil without one.  Only a window of TEXT around the match is
read, so a node of megabytes costs no more than a short one."
  (let ((len (length text))
        (match (and query (harness-session-search--locate text query regexp))))
    (if (not match)
        (let ((head (harness-session-search--squeeze (substring text 0 (min len 2000)))))
          (cons (harness-truncate-end (if (> len 2000) (concat head "…") head) 160) nil))
      (let* ((start (car match))
             (end (cdr match))
             ;; Squeezing shortens whitespace, so read more than is shown.
             (from (max 0 (- start 400)))
             (to (min len (+ end 400) (+ start 2000)))
             (upto (lambda (pos) (harness-session-search--squeeze (substring text from pos))))
             (window (funcall upto to))
             (s (length (funcall upto start)))
             (e (length (funcall upto (min end to))))
             (b (max 0 (- s 70)))
             (a (min (length window) (+ e 90) (+ s 300)))
             (lead (if (or (> from 0) (> b 0)) "…" "")))
        (cons (concat lead (substring window b a)
                      (if (or (< to len) (< a (length window))) "…" ""))
              (list (list (+ (length lead) (- s b)) (+ (length lead) (- (min e a) b)))))))))

(defun harness-session-search-snippet (text query regexp)
  "Return the part of TEXT around the first match of QUERY, on one line.
QUERY is literal text, or an Emacs regexp when REGEXP is non-nil; see
`harness-session-search--snippet'."
  (car (harness-session-search--snippet text query regexp)))

(defun harness-session-search--marked-snippet (text cut-before cut-after)
  "Return (SNIPPET . RANGES) of FTS5 snippet TEXT, its matches marked.
The marks go, and RANGES says where they were, as (START END).  The
snippet is one line, its whitespace squeezed, cut to some
`harness-session-search--snippet-chars' around its first match;
CUT-BEFORE and CUT-AFTER say the text was cut already."
  (let* ((s (harness-session-search--squeeze (string-trim text)))
         (first (cl-position harness-session-search--mark-start s))
         (limit harness-session-search--snippet-chars)
         (from 0) (to (length s)))
    (when (> (length s) limit)
      (setq from (if first (max 0 (- first 100)) 0)
            to (min (length s) (+ from limit))))
    (let* ((lead (and (or cut-before (> from 0)) (not (eq (aref s from) ?…)) "…"))
           (tail (and (or cut-after (< to (length s))) (not (and (> to 0) (eq (aref s (1- to)) ?…))) "…"))
           (out nil)
           (pos (length lead))
           (ranges nil) (open nil))
      (cl-loop for i from from below to
               for c = (aref s i)
               do (cond ((eq c harness-session-search--mark-start) (setq open pos))
                        ((eq c harness-session-search--mark-end)
                         (when open (push (list open pos) ranges) (setq open nil)))
                        (t (push c out) (cl-incf pos))))
      (when open (push (list open pos) ranges))
      (cons (concat lead (apply #'string (nreverse out)) tail)
            (nreverse ranges)))))

;;;; Literal and regexp search: grep over the logs

(defun harness-session-search-emacs-regexp (ere)
  "Return ERE, an extended regexp as grep -E reads it, as an Emacs regexp.
Grouping, alternation and intervals lose their backslashes, a quoted
one of those characters gains one, \\s and \\S become character
classes, and . matches any character, a newline too: in the log the
text was one line, its newlines escaped."
  (let ((i 0) (n (length ere)) (out nil))
    (while (< i n)
      (let ((c (aref ere i)))
        (cond
         ((eq c ?\\)
          (if (>= (1+ i) n)
              (progn (push "\\\\" out) (setq i n))
            (let ((d (aref ere (1+ i))))
              (push (pcase d
                      ((or ?\( ?\) ?| ?{ ?}) (string d))
                      (?s "[[:space:]]")
                      (?S "[^[:space:]]")
                      (_ (string ?\\ d)))
                    out)
              (setq i (+ i 2)))))
         ((memq c '(?\( ?\) ?| ?{ ?}))
          (push (string ?\\ c) out)
          (setq i (1+ i)))
         ((eq c ?.)
          (push "[^z-a]" out)
          (setq i (1+ i)))
         ((eq c ?\[)
          ;; A bracket expression reads the same in both: copy it whole.
          (let ((j (harness-session-search--bracket-end ere i)))
            (push (substring ere i j) out)
            (setq i j)))
         (t (push (string c) out)
            (setq i (1+ i))))))
    (apply #'concat (nreverse out))))

(defun harness-session-search--bracket-end (ere i)
  "Return where the bracket expression of ERE that opens at I ends, past its ].
A ] first in it, after the [ or the [^, is one of its characters, and
so are the ones of a [:class:], [.symbol.] or [=equivalent=]."
  (let ((n (length ere)) (j (1+ i)))
    (when (and (< j n) (eq (aref ere j) ?^)) (cl-incf j))
    (when (and (< j n) (eq (aref ere j) ?\])) (cl-incf j))
    (while (and (< j n) (not (eq (aref ere j) ?\])))
      (if (and (eq (aref ere j) ?\[) (< (1+ j) n) (memq (aref ere (1+ j)) '(?: ?. ?=)))
          (let ((close (string-search (string (aref ere (1+ j)) ?\]) ere (+ j 2))))
            (setq j (if close (+ close 2) (1+ j))))
        (cl-incf j)))
    (min n (1+ j))))

(defun harness-session-search--unanchored (ere)
  "Return extended regexp ERE without its anchors, the ^ and $ outside brackets.
In a log the text of a node is inside a line of JSON, where an anchor
matches neither where the text starts nor where it ends: grep looks
for the lines without them, and the regexp with them checks the text."
  (let ((i 0) (n (length ere)) (out nil))
    (while (< i n)
      (let ((c (aref ere i)))
        (cond
         ((eq c ?\\)
          (push (substring ere i (min n (+ i 2))) out)
          (setq i (+ i 2)))
         ((memq c '(?^ ?$)) (setq i (1+ i)))
         ((eq c ?\[)
          (let ((j (harness-session-search--bracket-end ere i)))
            (push (substring ere i j) out)
            (setq i j)))
         (t (push (string c) out)
            (setq i (1+ i))))))
    (apply #'concat (nreverse out))))

(defun harness-session-search--valid-regexp (regexp)
  "Return REGEXP when Emacs can read it, else nil."
  (condition-case nil (progn (string-match-p regexp "") regexp) (invalid-regexp nil)))

(defun harness-session-search--json-fragment (text)
  "Return TEXT as it appears inside a JSON string of a log."
  (let ((json (json-serialize text)))
    (substring (if (multibyte-string-p json) json (decode-coding-string json 'utf-8)) 1 -1)))

(defun harness-session-search--grep-hits (stdout)
  "Return ((SESSION-ID . RECORD) …) from grep STDOUT, in output order.
A line of STDOUT holds a whole node, which can be megabytes long:
`harness-grep-hit' splits it without a regexp."
  (let (hits)
    (dolist (line (split-string stdout "\n" t))
      (when-let* ((hit (harness-grep-hit line ".nodes.jsonl"))
                  (rec (ignore-errors (harness-json-parse (cdr hit)))))
        (when (consp rec) (push (cons (car hit) rec) hits))))
    (nreverse hits)))

(defun harness-session-search--grep-node (db current sid rec)
  "Return (NODE-ID . ENTRY) for grep record REC of session SID, or nil.
REC is a node or an update line.  With CURRENT, the index DB is up to
date with the log, and the node's entry is the one DB holds: its final
text, whichever of its lines matched.  Otherwise the entry is REC's,
and an update line, which carries only what changed, takes the rest of
its node from DB when DB has it, else from the session itself."
  (let ((id (plist-get rec :id)))
    (when (stringp id)
      (let ((stored (and db (harness-session-search--stored-entry db sid id))))
        (cond
         ;; A node the current index lacks is of a kind no search reads.
         ((and db current) (and stored (cons id stored)))
         ((not (equal (plist-get rec :_op) "update"))
          (when-let* ((entry (harness-session-search--entry rec)))
            (cons id entry)))
         (t
          (when-let* ((base (or stored
                                (when-let* ((node (ignore-errors (harness-call 'session/node sid id))))
                                  (harness-session-search--entry (copy-sequence node))))))
            (cons id (harness-session-search--apply-update base rec)))))))))

(defun harness-session-search--grep (query emacs-re ids per-session &optional db current)
  "Return a promise of the sessions among IDS whose logs match QUERY.
QUERY is literal text when EMACS-RE is nil, else an extended regexp for
grep and EMACS-RE the same as an Emacs regexp, or t when Emacs cannot
read it.  Case is ignored.  The promise resolves to ((SID . HITS) …) in
no order, HITS the matching nodes in the order they were written, each
\(NODE-ID . ENTRY), an index entry.  A node counts once, and its text
has to match too: a line can match by its JSON and not by its text.
DB is the index, or nil; with CURRENT, DB is up to date with the logs,
and a node's text is its final text, so a node that matched on a line
its last update replaced does not count.  Without, it is the text of
the lines that matched, the later of them winning."
  (let* ((dir (expand-file-name "sessions" harness-state-directory))
         (known (harness-session-search--set ids))
         (files (cl-loop for id in ids
                         for f = (harness-session-search--log id)
                         when (file-exists-p f) collect f)))
    (if (null files)
        (harness-resolved nil)
      (harness-then
       (harness-run-command
        (append (list harness-session-search--grep-program "-i" "-H"
                      (format "--max-count=%d" (* 4 (max 1 per-session)))
                      (if emacs-re "-E" "-F") "-e"
                      ;; In the log, text sits inside JSON strings: a
                      ;; literal is looked for as JSON writes it, and a
                      ;; regexp Emacs reads checks the anchors itself.
                      (cond ((null emacs-re) (harness-session-search--json-fragment query))
                            ((stringp emacs-re) (harness-session-search--unanchored query))
                            (t query))
                      "--")
                files)
        :cwd dir :timeout 60 :name "harness-session-search")
       (lambda (r)
         (unless (memq (plist-get r :exit) '(0 1))
           (harness-session-search--fail
            "search failed: %s" (string-trim (or (plist-get r :stderr) (format "%s" (plist-get r :exit))))))
         (let ((grouped (make-hash-table :test 'equal)) order)
           (dolist (hit (harness-session-search--grep-hits (plist-get r :stdout)))
             (let ((sid (car hit)))
               (when (gethash sid known)
                 (when-let* ((node (harness-session-search--grep-node db current sid (cdr hit))))
                   (let* ((nodes (gethash sid grouped))
                          (old (assoc (car node) nodes)))
                     (if old
                         (setcdr old (cdr node))
                       (unless nodes (push sid order))
                       (puthash sid (append nodes (list node)) grouped)))))))
           (cl-loop for sid in (nreverse order)
                    for nodes = (cl-remove-if-not
                                 (lambda (node)
                                   (let ((text (plist-get (cdr node) :text)))
                                     (cond ((null emacs-re) (harness-session-search--locate text query nil))
                                           ((eq emacs-re t) t)
                                           (t (harness-session-search--locate text emacs-re t)))))
                                 (gethash sid grouped))
                    when nodes collect (cons sid nodes))))))))

;;;; Embeddings

(defun harness-session-search--embedding-key ()
  "Return what the vectors are of: the model and dimensions asked for."
  (format "%s|%s" harness-session-search-embedding-model
          (or harness-session-search-embedding-dimensions "")))

(defun harness-session-search--check-model (db)
  "Drop the vectors in DB when they are of another model than the one set."
  (let ((key (harness-session-search--embedding-key))
        (have (caar (sqlite-select db "SELECT value FROM meta WHERE key = 'embedding'"))))
    (unless (equal key have)
      (harness-session-search--transaction db
        (sqlite-execute db "DELETE FROM chunks")
        (sqlite-execute db "DELETE FROM vectors")
        (sqlite-execute db (format "UPDATE nodes SET embedded = NULL WHERE kind IN (%s)"
                                   (harness-session-search--placeholders harness-session-search--embed-kinds))
                        (mapcar #'symbol-name harness-session-search--embed-kinds))
        (sqlite-execute db "INSERT OR REPLACE INTO meta (key, value) VALUES ('embedding', ?)" (list key)))
      (setq harness-session-search--vectors nil
            harness-session-search--query-vectors nil
            harness-session-search--embed-failure nil
            harness-session-search--embed-backoff 0
            harness-session-search--embed-size harness-session-search--embed-batch
            harness-session-search--embed-shrink 0))))

(defun harness-session-search--last-break (text start end)
  "Return where the last good place to cut TEXT between START and END is, or nil.
After a blank line, else after a newline, else after a space."
  (let ((window (substring text start end)))
    (cl-flet ((last (needle)
                (let ((at nil) (from 0) p)
                  (while (setq p (string-search needle window from))
                    (setq at (+ p (length needle)) from (1+ p)))
                  at)))
      (let ((p (or (last "\n\n") (last "\n") (last " "))))
        (and p (+ start p))))))

(defun harness-session-search--chunks (text)
  "Return the pieces of TEXT that are embedded.
At most `harness-session-search--chunks-per-node' of up to
`harness-session-search--chunk-chars' characters, cut at a blank line, a
line or a space in their second half where there is one."
  (let* ((text (string-trim text))
         (len (length text))
         (size harness-session-search--chunk-chars)
         (start 0) out)
    (while (and (< start len) (< (length out) harness-session-search--chunks-per-node))
      (let* ((end (min len (+ start size)))
             (cut (if (= end len)
                      end
                    (or (harness-session-search--last-break text (+ start (/ size 2)) end) end))))
        (let ((piece (string-trim (substring text start cut))))
          (when (>= (length piece) 3) (push piece out)))
        (setq start cut)))
    (nreverse out)))

(defun harness-session-search--quantize (vector)
  "Return (SCALE . BYTES) for VECTOR, a list of numbers: int8 values offset by 128.
The dot product of a unit vector with the values of BYTES (each byte
less 128), times SCALE, is its cosine with VECTOR."
  (let* ((v (vconcat vector))
         (norm (sqrt (cl-loop for x across v sum (* (float x) x))))
         (peak (cl-loop for x across v maximize (abs x))))
    (if (or (zerop (length v)) (<= peak 0) (<= norm 0))
        (cons 0.0 (apply #'unibyte-string (make-list (length v) 128)))
      (let ((k (/ 127.0 peak)))
        (cons (/ peak (* 127.0 norm))
              (apply #'unibyte-string (cl-loop for x across v collect (+ 128 (round (* x k))))))))))

(defun harness-session-search--query-ints (vector)
  "Return VECTOR made a unit vector of integers, times 1024."
  (let* ((v (vconcat vector))
         (norm (sqrt (cl-loop for x across v sum (* (float x) x)))))
    (if (<= norm 0)
        (make-vector (length v) 0)
      (cl-map 'vector (lambda (x) (round (* 1024.0 (/ x norm)))) v))))

(defun harness-session-search--record-usage (usage)
  "Record what an embedding request took, USAGE, under no session."
  (when (and usage (harness-method-exists-p 'usage/record))
    (condition-case err
        (let* ((model harness-session-search-embedding-model)
               (tokens (list :input (or (plist-get usage :input) 0) :output 0))
               (cost (or (and (harness-method-exists-p 'usage/price)
                              (ignore-errors (harness-call 'usage/price model tokens)))
                         0)))
          (when (> (plist-get tokens :input) 0)
            (harness-call 'usage/record (append (list :session nil :project nil :model model :cost cost) tokens))))
      (error (harness-log 'warn "session-search: recording usage failed: %s" (harness-session-search--message err))))))

(defun harness-session-search--embed (texts)
  "Return a promise of the vectors of TEXTS by the embedding model."
  (harness-then
   (harness-call 'provider/embed harness-session-search-embedding-model texts
                 (and harness-session-search-embedding-dimensions
                      (list :dimensions harness-session-search-embedding-dimensions)))
   (lambda (result)
     (harness-session-search--record-usage (plist-get result :usage))
     (plist-get result :vectors))))

(defun harness-session-search--embed-ready-p ()
  "Non-nil when the background may make an embedding request now."
  (and harness-session-search-embedding-model
       (not harness-session-search--embedding)
       (harness-method-exists-p 'provider/embed)
       (or (null harness-session-search--embed-failure)
           (>= (- (float-time) (car harness-session-search--embed-failure))
               harness-session-search--embed-backoff))))

(defun harness-session-search--embed-next (db)
  "Start the background's next embedding request, when there is one to make.
DB is the index.  It embeds the chunks of the newest nodes without
vectors; a chunk met before is not embedded again."
  (when (harness-session-search--embed-ready-p)
    (harness-session-search--check-model db)
    (let* ((rows (sqlite-select db "SELECT id, text FROM nodes WHERE embedded IS NULL ORDER BY id DESC LIMIT ?"
                                (list (* 2 harness-session-search--embed-batch))))
           (size harness-session-search--embed-size)
           (missing nil) (taken nil) (full nil))
      (dolist (row rows)
        (unless full
          (let ((fits t))
            (dolist (piece (harness-session-search--chunks (cadr row)))
              (let ((hash (secure-hash 'sha1 piece)))
                (unless (or (assoc hash missing)
                            (sqlite-select db "SELECT 1 FROM vectors WHERE hash = ?" (list hash)))
                  (if (>= (length missing) size)
                      (setq fits nil full t)
                    (push (cons hash piece) missing)))))
            (when fits (push (car row) taken)))))
      (cond
       ((null rows) nil)
       ((null missing)
        (harness-session-search--finish db taken)
        (harness-session-search--schedule))
       (t (harness-session-search--embed-request (nreverse missing) taken))))))

(defun harness-session-search--embed-request (missing taken)
  "Embed MISSING, ((HASH . TEXT) …), then record the chunks of nodes TAKEN."
  (let* ((dir (expand-file-name harness-state-directory))
         (shrink harness-session-search--embed-shrink)
         (texts (mapcar (lambda (m)
                          (let ((text (cdr m)))
                            (dotimes (_ shrink) (setq text (substring text 0 (max 1 (/ (length text) 2)))))
                            text))
                        missing))
         (here (lambda () (and (equal dir (expand-file-name harness-state-directory))
                               (file-directory-p dir)
                               (harness-session-search--db))))
         (failed
          (lambda (err)
            (setq harness-session-search--embedding nil
                  harness-session-search--embed-failure (cons (float-time) (harness-session-search--message err)))
            (cond
             ;; Fewer chunks at a time, then shorter ones, then wait longer.
             ((> harness-session-search--embed-size 1)
              (setq harness-session-search--embed-size (max 1 (/ harness-session-search--embed-size 2))
                    harness-session-search--embed-backoff 2))
             ((< harness-session-search--embed-shrink 3)
              (cl-incf harness-session-search--embed-shrink)
              (setq harness-session-search--embed-backoff 2))
             (t (setq harness-session-search--embed-backoff
                      (min harness-session-search--embed-backoff-max
                           (max 30 (* 2 harness-session-search--embed-backoff))))))
            (harness-log (if (>= harness-session-search--embed-backoff 30) 'warn 'debug)
                         "session-search: embedding failed: %s" (cdr harness-session-search--embed-failure))
            (when (funcall here)
              (harness-session-search--schedule (+ 0.5 harness-session-search--embed-backoff)))
            nil)))
    (setq harness-session-search--embedding t)
    (harness-then
     (condition-case err (harness-session-search--embed texts) (error (harness-rejected err)))
     (lambda (vectors)
       (condition-case err
           (if (/= (length vectors) (length missing))
               (funcall failed (list 'error (format "%d vectors for %d texts" (length vectors) (length missing))))
             (setq harness-session-search--embedding nil)
             (when-let* ((db (funcall here)))
               (harness-session-search--transaction db
                 (cl-loop for (hash . _) in missing
                          for vector in vectors
                          for (scale . bytes) = (harness-session-search--quantize vector)
                          do (sqlite-execute db "INSERT OR IGNORE INTO vectors (hash, scale, vec) VALUES (?, ?, ?)"
                                             (list hash scale (propertize bytes 'coding-system 'binary)))))
               (harness-session-search--finish db taken)
               (setq harness-session-search--embed-failure nil
                     harness-session-search--embed-backoff 0
                     harness-session-search--embed-shrink 0
                     harness-session-search--embed-size (min harness-session-search--embed-batch
                                                             (* 2 harness-session-search--embed-size)))
               (harness-session-search--schedule))
             nil)
         (error (funcall failed err))))
     failed)))

(defun harness-session-search--finish (db ids)
  "Record the chunks of nodes IDS whose text has every vector in DB now.
A node whose text changed in the meantime keeps waiting."
  (harness-session-search--transaction db
    (dolist (id ids)
      (when-let* ((text (caar (sqlite-select db "SELECT text FROM nodes WHERE id = ? AND embedded IS NULL" (list id)))))
        (let ((hashes (mapcar (lambda (p) (secure-hash 'sha1 p)) (harness-session-search--chunks text))))
          (when (cl-every (lambda (h) (sqlite-select db "SELECT 1 FROM vectors WHERE hash = ?" (list h))) hashes)
            (sqlite-execute db "DELETE FROM chunks WHERE node = ?" (list id))
            (cl-loop for h in hashes for part from 0
                     do (sqlite-execute db "INSERT INTO chunks (node, part, hash) VALUES (?, ?, ?)" (list id part h)))
            (sqlite-execute db "UPDATE nodes SET embedded = 1 WHERE id = ?" (list id))))))))

(defun harness-session-search--load-vectors (db)
  "Return the vectors of DB in memory; see `harness-session-search--vectors'.
They are read again once the chunks changed."
  (let ((key (cons db (car (sqlite-select db "SELECT count(*), coalesce(max(id), 0) FROM chunks")))))
    (unless (equal (plist-get harness-session-search--vectors :key) key)
      (let ((rows (sqlite-select db (concat "SELECT c.node, n.session, n.kind, c.part, v.scale, v.vec FROM chunks c "
                                            "JOIN vectors v ON v.hash = c.hash JOIN nodes n ON n.id = c.node"))))
        (setq harness-session-search--vectors
              (list :key key
                    :nodes (vconcat (mapcar (lambda (r) (nth 0 r)) rows))
                    :sessions (vconcat (mapcar (lambda (r) (nth 1 r)) rows))
                    :kinds (vconcat (mapcar (lambda (r) (intern (nth 2 r))) rows))
                    :parts (vconcat (mapcar (lambda (r) (nth 3 r)) rows))
                    :scales (vconcat (mapcar (lambda (r) (nth 4 r)) rows))
                    :blobs (vconcat (mapcar (lambda (r) (nth 5 r)) rows))))))
    harness-session-search--vectors))

(defun harness-session-search--nearest (db query-vector allowed kinds limit)
  "Return the LIMIT nodes of DB nearest QUERY-VECTOR, best first.
They come as ((ROWID SCORE PART) …).  A node scores the cosine of its
nearest chunk, PART.  Only the chunks of sessions in ALLOWED, a hash
table (all when nil), and of nodes of KINDS (all when nil) count."
  (let* ((v (harness-session-search--load-vectors db))
         (nodes (plist-get v :nodes)) (sessions (plist-get v :sessions)) (node-kinds (plist-get v :kinds))
         (parts (plist-get v :parts)) (scales (plist-get v :scales)) (blobs (plist-get v :blobs))
         (q (harness-session-search--query-ints query-vector))
         (d (length q))
         (best (make-hash-table)))
    (dotimes (i (length nodes))
      (let ((blob (aref blobs i)))
        (when (and (= (length blob) d)
                   (or (null allowed) (gethash (aref sessions i) allowed))
                   (or (null kinds) (memq (aref node-kinds i) kinds)))
          (let ((sum 0))
            (dotimes (j d)
              (setq sum (+ sum (* (aref q j) (- (aref blob j) 128)))))
            (let ((score (/ (* sum (aref scales i)) 1024.0))
                  (node (aref nodes i)))
              (when (> score (car (gethash node best '(-2.0))))
                (puthash node (list score (aref parts i)) best)))))))
    (let (out)
      (maphash (lambda (node v) (push (cons node v) out)) best)
      (seq-take (sort out (lambda (a b) (> (cadr a) (cadr b)))) limit))))

(defun harness-session-search--query-vector (query)
  "Return a promise of the vector of QUERY by the embedding model; kept a while."
  (let* ((key (cons (harness-session-search--embedding-key) query))
         (hit (assoc key harness-session-search--query-vectors)))
    (if hit
        (harness-resolved (cdr hit))
      (harness-then (harness-session-search--embed (list query))
                    (lambda (vectors)
                      (push (cons key (car vectors)) harness-session-search--query-vectors)
                      (setq harness-session-search--query-vectors
                            (seq-take harness-session-search--query-vectors 20))
                      (car vectors))))))

(defun harness-session-search--semantic (db query-vector allowed kinds max-matches)
  "Return the sessions with nodes nearest QUERY-VECTOR in DB, best first.
Shaped as `harness-session-search--fts' returns them, with higher
scores better, each hit with `:part', its nearest chunk.  ALLOWED and
KINDS restrict them as `harness-session-search--nearest' says."
  (let* ((near (harness-session-search--nearest db query-vector allowed kinds
                                                harness-session-search--semantic-limit))
         (scores (let ((h (make-hash-table))) (dolist (n near h) (puthash (car n) (cdr n) h))))
         (rows (and near
                    (sqlite-select db (format "SELECT id, session, node, kind, tool, ts, sender FROM nodes WHERE id IN (%s)"
                                              (harness-session-search--placeholders near))
                                   (mapcar #'car near))))
         (grouped (make-hash-table :test 'equal))
         order)
    (dolist (row rows)
      (pcase-let ((`(,rowid ,sid ,node ,kind ,tool ,ts ,sender) row))
        (let ((score (gethash rowid scores)))
          (unless (gethash sid grouped) (push sid order))
          (push (list :rowid rowid :node node :kind (intern kind) :tool tool :ts ts :sender sender
                      :score (car score) :part (cadr score))
                (gethash sid grouped)))))
    (sort (mapcar (lambda (sid)
                    (let ((hits (sort (gethash sid grouped)
                                      (lambda (a b) (> (plist-get a :score) (plist-get b :score))))))
                      (list sid (plist-get (car hits) :score) (length hits) (seq-take hits max-matches))))
                  order)
          (lambda (a b) (> (nth 1 a) (nth 1 b))))))

(defun harness-session-search--semantic-snippets (db hits)
  "Return a table of the snippets of semantic HITS, by their rowid in DB.
A hit's snippet is the start of its nearest chunk."
  (let ((table (make-hash-table)))
    (when hits
      (dolist (row (sqlite-select db (format "SELECT id, text FROM nodes WHERE id IN (%s)"
                                             (harness-session-search--placeholders hits))
                                  (mapcar (lambda (h) (plist-get h :rowid)) hits)))
        (let* ((hit (cl-find (car row) hits :key (lambda (h) (plist-get h :rowid))))
               (chunk (or (nth (or (plist-get hit :part) 0) (harness-session-search--chunks (cadr row)))
                          (cadr row))))
          (puthash (car row) (harness-truncate-end (harness-session-search--squeeze chunk) 200) table))))
    table))

(defun harness-session-search--embedding-ready (db)
  "Non-nil when DB has vectors of the embedding model set."
  (and harness-session-search-embedding-model
       (harness-method-exists-p 'provider/embed)
       (equal (caar (sqlite-select db "SELECT value FROM meta WHERE key = 'embedding'"))
              (harness-session-search--embedding-key))
       (sqlite-select db "SELECT 1 FROM chunks LIMIT 1")
       t))

;;;; The search

(defun harness-session-search--mode (value)
  "Return the search mode VALUE names: text, literal, regexp or semantic."
  (let ((mode (harness-session-search--kind value)))
    (cond ((null mode) 'text)
          ((memq mode '(text literal regexp semantic)) mode)
          (t (harness-session-search--fail "Unknown search mode %s: text, literal, regexp or semantic" value)))))

(defun harness-session-search--candidates (opts)
  "Return the session plists OPTS asks to search, newest first.
`:sessions' names them (all when absent), `:exclude' leaves some out and
`:project' keeps those of that project, its worktrees included.  The
internal sessions, the records of the harness's own model calls, are
left out: their prompts hold what the sessions they were made for did,
which would match twice."
  (let* ((only (harness-session-search--set (plist-get opts :sessions)))
         (exclude (plist-get opts :exclude))
         (project (plist-get opts :project))
         (cache (make-hash-table :test 'equal))
         (root-of (lambda (dir)
                    (when (stringp dir)
                      (or (gethash dir cache)
                          (puthash dir (file-name-as-directory
                                        (expand-file-name (or (ignore-errors (harness-files-main-root dir)) dir)))
                                   cache)))))
         (root (and (stringp project) (funcall root-of project))))
    (cl-remove-if-not
     (lambda (s)
       (let ((id (plist-get s :id)))
         (and (or (null only) (gethash id only))
              (not (member id exclude))
              (not (eq (plist-get s :kind) 'internal))
              (or (null root)
                  (equal root (funcall root-of (or (plist-get s :project) (plist-get s :cwd))))))))
     (harness-call 'session/list))))

(defun harness-session-search--name-predicate (mode query items)
  "Return a predicate on a session name: does it match QUERY in MODE?
Text mode wants every positive word of ITEMS in the name; regexp mode
takes QUERY as an Emacs regexp."
  (pcase mode
    ('text (let ((words (cl-loop for i in items
                                 when (and (consp i) (not (plist-get i :neg)))
                                 collect (downcase (plist-get i :text)))))
             (lambda (name) (and words (let ((name (downcase name)))
                                         (cl-every (lambda (w) (string-search w name)) words))))))
    ('literal (let ((q (downcase query))) (lambda (name) (string-search q (downcase name)))))
    ('regexp (lambda (name) (let ((case-fold-search t)) (ignore-errors (string-match-p query name)))))
    (_ #'ignore)))

(defun harness-session-search--fuse (rankings)
  "Fuse RANKINGS, lists of session ids best first; return (IDS . SCORES).
IDS are all of them, best first; SCORES maps each to its score, by
reciprocal rank fusion: the sum of 1/(K + rank) over the rankings it is in."
  (let ((scores (make-hash-table :test 'equal)) order)
    (dolist (ranking rankings)
      (cl-loop for id in ranking for rank from 1
               do (unless (gethash id scores) (push id order))
               do (puthash id (+ (gethash id scores 0) (/ 1.0 (+ harness-session-search--rrf-k rank))) scores)))
    (cons (cl-stable-sort (nreverse order) #'> :key (lambda (id) (gethash id scores))) scores)))

(defun harness-session-search--hit (hit snippet ranges)
  "Return the public plist of HIT with SNIPPET and its match RANGES."
  (let ((from (and (stringp (plist-get hit :sender)) (ignore-errors (harness-json-parse (plist-get hit :sender))))))
    (list :node (plist-get hit :node) :kind (plist-get hit :kind) :tool (plist-get hit :tool)
          :ts (plist-get hit :ts) :from from
          :from-text (and (harness-sender-kind from) (harness-sender-description from))
          :snippet snippet :ranges ranges :score (plist-get hit :score))))

(defun harness-session-search--session (s &rest plist)
  "Return the public plist of matching session S, with PLIST added."
  (append (list :id (plist-get s :id) :name (plist-get s :name) :updated (plist-get s :updated)
                :status (plist-get s :status) :kind (plist-get s :kind)
                :cwd (plist-get s :cwd) :project (plist-get s :project))
          plist))

(defun harness-session-search--result (query mode engine sessions &rest plist)
  "Return the result of searching QUERY in MODE by ENGINE, SESSIONS matching.
PLIST adds `:note', `:loose' and `:total'."
  (list :query query :mode mode :engine engine
        :note (plist-get plist :note) :loose (and (plist-get plist :loose) t)
        :total (or (plist-get plist :total) (length sessions))
        :sessions sessions))

(defun harness-session-search--by-grep (query mode candidates opts &optional note)
  "Return a promise of the result of a search for QUERY, in MODE.
MODE is `literal' or `regexp'; CANDIDATES are the sessions to search,
OPTS as `session/search' takes them.  NOTE says why a text search came
here instead."
  (let* ((regexp (eq mode 'regexp))
         (emacs-re (and regexp (or (harness-session-search--valid-regexp
                                    (harness-session-search-emacs-regexp query))
                                   t)))
         (snippet-re (and (stringp emacs-re) emacs-re))
         (max-sessions (or (plist-get opts :max-sessions) 20))
         (max-matches (or (plist-get opts :max-matches) 3))
         (kinds (mapcar #'harness-session-search--kind (plist-get opts :kinds)))
         (by-id (let ((h (make-hash-table :test 'equal))) (dolist (s candidates h) (puthash (plist-get s :id) s h))))
         (ids (mapcar (lambda (s) (plist-get s :id)) candidates))
         (name-p (if regexp
                     (if snippet-re (harness-session-search--name-predicate 'regexp snippet-re nil) #'ignore)
                   (harness-session-search--name-predicate 'literal query nil)))
         (db (and harness-session-search-index (harness-session-search--db)))
         ;; With the index current, a node's final text is read from it.
         (current (and db (ignore-errors (harness-session-search--catch-up db ids)))))
    (harness-then
     (harness-session-search--grep query emacs-re ids max-matches db current)
     (lambda (found)
       (let* ((content (make-hash-table :test 'equal))
              (_ (cl-loop for (sid . nodes) in found
                          for kept = (if kinds (cl-remove-if-not (lambda (n) (memq (plist-get (cdr n) :kind) kinds)) nodes)
                                       nodes)
                          when kept do (puthash sid kept content)))
              (named (lambda (sid) (and (funcall name-p (or (plist-get (gethash sid by-id) :name) "")) t)))
              (matching (cl-loop for id in ids
                                 when (or (gethash id content) (funcall named id)) collect id))
              (shown (seq-take matching max-sessions)))
         (harness-session-search--result
          query mode "grep"
          (mapcar (lambda (sid)
                    (let ((nodes (gethash sid content)))
                      (harness-session-search--session
                       (gethash sid by-id)
                       :name-match (funcall named sid)
                       :matches (length nodes)
                       :hits (mapcar (lambda (n)
                                       (let ((snip (harness-session-search--snippet
                                                    (plist-get (cdr n) :text) (if regexp snippet-re query) regexp)))
                                         (harness-session-search--hit (append (list :node (car n)) (cdr n))
                                                                      (car snip) (cdr snip))))
                                     (seq-take nodes max-matches)))))
                  shown)
          :total (length matching) :note note))))))

(cl-defun harness-session-search--ranked (query mode db candidates opts
                                         &key fts semantic items loose note rerank)
  "Return the result of a ranked search for QUERY in MODE over CANDIDATES in DB.
FTS and SEMANTIC are sessions as `harness-session-search--fts' and
`harness-session-search--semantic' return them; ITEMS are the query's
terms, for names and snippets; LOOSE says the full-text matches have
only some of the words, and NOTE is what the result says.  With RERANK
the sessions nearest in meaning only rank those the words or names
found, and show no hits of their own."
  (let* ((max-sessions (or (plist-get opts :max-sessions) 20))
         (max-matches (or (plist-get opts :max-matches) 3))
         (by-id (let ((h (make-hash-table :test 'equal))) (dolist (s candidates h) (puthash (plist-get s :id) s h))))
         (fts (cl-remove-if-not (lambda (x) (gethash (car x) by-id)) fts))
         (fts-of (let ((h (make-hash-table :test 'equal))) (dolist (x fts h) (puthash (car x) x h))))
         (name-p (harness-session-search--name-predicate mode query items))
         (names (and (eq mode 'text)
                     (cl-loop for s in candidates
                              when (funcall name-p (or (plist-get s :name) "")) collect (plist-get s :id))))
         (semantic (cl-remove-if-not (lambda (x) (and (gethash (car x) by-id)
                                                      (or (not rerank) (gethash (car x) fts-of)
                                                          (member (car x) names))))
                                     semantic))
         (sem-of (let ((h (make-hash-table :test 'equal))) (dolist (x semantic h) (puthash (car x) x h))))
         (fused (harness-session-search--fuse (delq nil (list (mapcar #'car fts) (mapcar #'car semantic) names))))
         (ids (car fused))
         (shown (seq-take ids max-sessions))
         (expr (and fts (harness-session-search--fts-expression items loose)))
         (fts-hits (cl-loop for sid in shown append (nth 3 (gethash sid fts-of))))
         (snippets (if fts-hits
                       (harness-session-search--fts-snippets db expr (mapcar (lambda (h) (plist-get h :rowid)) fts-hits))
                     (make-hash-table)))
         (sem-hits (unless rerank (cl-loop for sid in shown append (nth 3 (gethash sid sem-of)))))
         (sem-snippets (harness-session-search--semantic-snippets db sem-hits)))
    (harness-session-search--result
     query mode (cond ((and fts semantic) "hybrid") (semantic "vectors") (t "fts"))
     (mapcar
      (lambda (sid)
        (let* ((f (gethash sid fts-of))
               (v (and (not rerank) (gethash sid sem-of)))
               (seen (make-hash-table :test 'equal))
               (hits nil))
          ;; The words' best matches first, then the nearest in meaning.
          (dolist (h (append (nth 3 f) (nth 3 v)))
            (unless (or (gethash (plist-get h :node) seen) (>= (length hits) max-matches))
              (puthash (plist-get h :node) t seen)
              (push (if (plist-member h :part)
                        (harness-session-search--hit h (gethash (plist-get h :rowid) sem-snippets "") nil)
                      (let ((snip (gethash (plist-get h :rowid) snippets)))
                        (if snip
                            (let ((m (harness-session-search--marked-snippet (nth 0 snip) (nth 1 snip) (nth 2 snip))))
                              (harness-session-search--hit h (car m) (cdr m)))
                          (harness-session-search--hit h "" nil))))
                    hits)))
          (harness-session-search--session
           (gethash sid by-id)
           :name-match (and (member sid names) t)
           :matches (cond (f (nth 2 f)) (v (nth 2 v)) (t 0))
           :score (gethash sid (cdr fused))
           :hits (nreverse hits))))
      shown)
     :total (length ids) :loose loose :note note)))

(defun harness-session-search--scope-ids (opts candidates)
  "Return the ids of CANDIDATES for a query to name, or nil to take all.
Only a search OPTS narrows (`:sessions', `:project') names them, and
only when there are not too many."
  (when (and (or (plist-get opts :sessions) (plist-get opts :project))
             (<= (length candidates) harness-session-search--max-sql-ids))
    (mapcar (lambda (s) (plist-get s :id)) candidates)))

(defun harness-session-search--near-enough (semantic)
  "Return the sessions of SEMANTIC near enough to stand in for missing words.
SEMANTIC is best first, as `harness-session-search--semantic' returns
it.  The ones kept score at least `harness-session-search--near-share'
of the best score: the rest are merely the least far."
  (let ((best (nth 1 (car semantic))))
    (when (and (numberp best) (> best 0))
      (cl-remove-if-not (lambda (s) (>= (nth 1 s) (* harness-session-search--near-share best)))
                        semantic))))

(defun harness-session-search--text (query db candidates opts vector)
  "Return the result of text search for QUERY in DB over CANDIDATES, or nil.
OPTS are as `session/search' takes them.  VECTOR is the query's
embedding, or nil: the nearest in meaning then rank the sessions that
have the words, and stand in for them when none has.  Nil when QUERY
has no word to search for and there is no VECTOR."
  (let* ((items (harness-session-search--parse-query query))
         (expr (harness-session-search--fts-expression items))
         (ids (harness-session-search--scope-ids opts candidates))
         (kinds (mapcar #'harness-session-search--kind (plist-get opts :kinds)))
         (max-matches (or (plist-get opts :max-matches) 3))
         (allowed (harness-session-search--set (mapcar (lambda (s) (plist-get s :id)) candidates)))
         (semantic (and vector (harness-session-search--semantic db vector allowed kinds max-matches)))
         ;; The index holds sessions this search leaves out, and deleted
         ;; ones until the background drops them.
         (fts-of (lambda (expr)
                   (cl-remove-if-not (lambda (x) (gethash (car x) allowed))
                                     (harness-session-search--fts db expr ids kinds max-matches))))
         (fts (and expr (funcall fts-of expr)))
         (loose nil))
    (when (and expr (null fts) (harness-session-search--loose-p items))
      (setq fts (funcall fts-of (harness-session-search--fts-expression items t))
            loose (and fts t)))
    (cond
     ((and (null expr) (null vector)) nil)
     (fts (harness-session-search--ranked query 'text db candidates opts
                                          :fts fts :semantic semantic :items items :loose loose :rerank t))
     (t (let ((near (harness-session-search--near-enough semantic)))
          (harness-session-search--ranked
           query 'text db candidates opts
           :semantic near :items items
           :note (and near "No session has these words: these are the nearest in meaning")))))))

(defun harness-session-search--semantic-search (query db candidates opts)
  "Return a promise of the result of semantic search for QUERY in DB.
CANDIDATES are the sessions to search, OPTS as `session/search' takes
them."
  (cond
   ((null harness-session-search-embedding-model)
    (harness-session-search--fail "Semantic search needs an embedding model: set harness-session-search-embedding-model"))
   ((not (harness-session-search--embedding-ready db))
    (harness-session-search--schedule 0)
    (harness-session-search--fail
     "No session text is embedded yet%s"
     (if harness-session-search--embed-failure
         (format ": %s" (cdr harness-session-search--embed-failure))
       "; the background is embedding it")))
   (t
    (let ((kinds (mapcar #'harness-session-search--kind (plist-get opts :kinds))))
      (harness-then (harness-session-search--query-vector query)
                    (lambda (vector)
                      (harness-session-search--ranked
                       query 'semantic db candidates opts
                       :semantic (harness-session-search--semantic
                                  db vector (harness-session-search--set (mapcar (lambda (s) (plist-get s :id)) candidates))
                                  kinds (or (plist-get opts :max-matches) 3)))))))))

(harness-defmethod session/search (query &optional opts)
  "Search the transcripts and names of sessions for QUERY; return a promise.
OPTS:
  :mode          text (the default), literal, regexp or semantic, a
                 symbol or its name; see harness-session-search.el
  :sessions      ids of the sessions to search, all when absent
  :exclude       ids of sessions to leave out (the searching one)
  :project       a directory: only the sessions of its project, the
                 project's worktrees included
  :kinds         kinds of node to look at (default all searched ones)
  :max-sessions  sessions to return (default 20)
  :max-matches   nodes to return of each session (default 3)
The promise resolves to a plist:
  :query :mode   as asked
  :engine        what searched: \"fts\", \"vectors\", \"hybrid\" (both),
                 \"grep\", or \"none\" when no session was to be searched
  :note          why a text search fell back to grep, or nil
  :loose         non-nil when no session had every word of a text
                 search and these have some of them
  :total         how many sessions match
  :sessions      the matching sessions, best first (newest first for
                 literal and regexp), each (:id :name :updated :status
                 :kind :cwd :project :name-match :matches :score :hits);
                 :matches is how many of its nodes match, :hits the best
                 of them, each (:node :kind :tool :ts :from :from-text
                 :snippet :ranges :score), :ranges the matches in the
                 snippet as (START END)."
  (condition-case err
      (let* ((query (if (stringp query) query (format "%s" (or query ""))))
             (mode (harness-session-search--mode (plist-get opts :mode))))
        (when (string-blank-p query)
          (harness-session-search--fail "A search needs a query"))
        (let ((candidates (harness-session-search--candidates opts)))
          (cond
           ((null candidates) (harness-resolved (harness-session-search--result query mode "none" nil)))
           ((memq mode '(literal regexp)) (harness-session-search--by-grep query mode candidates opts))
           (t (harness-session-search--ranked-search query mode candidates opts)))))
    (error (harness-rejected err))))

(defun harness-session-search--ranked-search (query mode candidates opts)
  "Return a promise of the result of a search for QUERY in MODE.
MODE is `text' or `semantic', OPTS as `session/search' takes them.
Catch the index up with the logs of CANDIDATES first; fall back to grep
for the text as typed when there is no index, or it is far behind."
  (let* ((db (harness-session-search--db))
         (ids (mapcar (lambda (s) (plist-get s :id)) candidates))
         (ready (and db (condition-case err
                            (harness-session-search--catch-up db ids)
                          (error (harness-log 'warn "session-search: catching up failed: %s"
                                              (harness-session-search--message err))
                                 nil))))
         (note (cond ((null db) (format "No full-text index (%s): the text was matched as typed"
                                        (harness-session-search--unavailable)))
                     ((not ready)
                      (harness-session-search--schedule 0)
                      (let ((pct (harness-session-search--progress db)))
                        (format "The full-text index is still being built%s: the text was matched as typed"
                                (if pct (format " (%d%% done)" pct) "")))))))
    (cond
     ((eq mode 'semantic)
      (unless db
        (harness-session-search--fail "Semantic search needs the index: %s" (harness-session-search--unavailable)))
      (harness-session-search--semantic-search query db candidates opts))
     (note (harness-session-search--by-grep query 'literal candidates opts note))
     (t
      (let ((text (lambda (vector)
                    (condition-case err
                        (or (harness-session-search--text query db candidates opts vector)
                            (harness-session-search--by-grep query 'literal candidates opts
                                                             "No word to search for: the text was matched as typed"))
                      (error
                       (harness-log 'warn "session-search: full-text search failed: %s"
                                    (harness-session-search--message err))
                       (harness-session-search--by-grep
                        query 'literal candidates opts
                        (format "The full-text search failed (%s): the text was matched as typed"
                                (harness-session-search--message err))))))))
        (if (harness-session-search--embedding-ready db)
            (harness-then (harness-catch (harness-session-search--query-vector query)
                                         (lambda (err)
                                           (harness-log 'warn "session-search: embedding the query failed: %s"
                                                        (harness-session-search--message err))
                                           nil))
                          text)
          (harness-as-promise (funcall text nil))))))))

(harness-defmethod session/search-status ()
  "Return the state of the search index as a plist.
`:index' is non-nil when there is one, else `:reason' says why not;
`:file' and `:size' (bytes, with its write-ahead log) say where and how
big; `:sessions' and `:nodes' how much it holds; `:pending' how many
sessions' logs it is still to read and `:progress' how much of the logs
it has read, a percentage, while that is not all.  `:embedding' is nil
without an embedding model, else (:model :chunks :pending :error): how
many chunks have vectors, how many nodes wait for theirs, and why the
last request failed, while the next has not succeeded."
  (let ((db (harness-session-search--db)))
    (if (not db)
        (list :index nil :reason (harness-session-search--unavailable))
      (let* ((file (expand-file-name (concat harness-session-search--db-name ".db") harness-state-directory))
             (size (+ (or (file-attribute-size (file-attributes file)) 0)
                      (or (file-attribute-size (file-attributes (concat file "-wal"))) 0)))
             (stale (car (harness-session-search--backlog db))))
        (list :index t :file file :size size
              :sessions (caar (sqlite-select db "SELECT count(*) FROM logs"))
              :nodes (caar (sqlite-select db "SELECT count(*) FROM nodes"))
              :pending (length stale)
              :progress (and stale (harness-session-search--progress db))
              :embedding
              (and harness-session-search-embedding-model
                   (list :model harness-session-search-embedding-model
                         :chunks (caar (sqlite-select db "SELECT count(*) FROM chunks"))
                         :pending (caar (sqlite-select db "SELECT count(*) FROM nodes WHERE embedded IS NULL"))
                         :error (cdr harness-session-search--embed-failure))))))))

(harness-defmethod session/search-rebuild ()
  "Drop the search index and build it again from the logs, in the background.
Return the status, as `session/search-status' does."
  (when (equal (car harness-session-search--failure) (expand-file-name harness-state-directory))
    (setq harness-session-search--failure nil))
  (let ((db (harness-session-search--db)))
    (unless db
      (harness-session-search--fail "No search index: %s" (harness-session-search--unavailable)))
    (harness-session-search--drop db)
    (harness-session-search--ensure-schema db)
    (harness-session-search--reset)
    (harness-session-search--schedule 0)
    (harness-call 'session/search-status)))

;;;; Module

(defun harness-session-search--subscribe ()
  "Follow the sessions' writes."
  (harness-on 'session/node-added #'harness-session-search--on-written)
  (harness-on 'session/node-updated #'harness-session-search--on-node-updated)
  (harness-on 'session/forked #'harness-session-search--on-forked)
  (harness-on 'session/deleted #'harness-session-search--on-deleted))

(defun harness-session-search--init ()
  "Follow the sessions' writes and start indexing what is not indexed yet."
  (harness-session-search--subscribe)
  (setq harness-session-search--queue t)
  (when harness-session-search-index
    (harness-session-search--schedule harness-session-search--start-delay)))

(defun harness-session-search--shutdown ()
  "Stop the background."
  (when harness-session-search--timer
    (cancel-timer (cdr harness-session-search--timer))
    (setq harness-session-search--timer nil)))

;; A reload does not run `:init' again for a ready module, so the
;; subscriptions are made here too.
(when (harness-module-ready-p 'session-search)
  (harness-session-search--subscribe))

(harness-define-module 'session-search
  :doc "Searches session transcripts: an SQLite full-text index, grep, and semantic search by embeddings."
  :requires '(store session)
  :init #'harness-session-search--init
  :shutdown #'harness-session-search--shutdown)

(provide 'harness-session-search)
;;; harness-session-search.el ends here
