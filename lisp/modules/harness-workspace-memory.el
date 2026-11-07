;;; harness-workspace-memory.el --- Long-term notes and recall for workspace mode -*- lexical-binding: t; -*-

;;; Commentary:

;; The workspace's memory is a small, durable note store with a full-text
;; index.  Every user and assistant message of a workspace episode is
;; written here as a note, and `memory/search' is what the
;; workspace's brief asks for the thread it is about to continue.
;;
;; This is the local half of the design's memory layer.  It is
;; deliberately a cache of the distilled conversation, not a second
;; transcript index: the notes are short, they carry the workspace and
;; the thread, and they are searched by the same words a person would
;; use.  A Logseq backend can replace the store behind the same four
;; methods without changing the workspace or the UI.
;;
;; Storage is SQLite in the harness state directory, with FTS5 when the
;; build has it and a LIKE fallback when it does not.  The database is a
;; cache: rebuilding it is a matter of reading the notes again from the
;; timeline, which this module can do with `workspace-memory/rebuild'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-store)
(require 'harness-session)
(require 'harness-tools)

(defvar harness-state-directory)

(defgroup harness-workspace-memory nil
  "Long-term recall for workspace mode."
  :group 'harness
  :prefix "harness-workspace-memory-")

(defcustom harness-workspace-memory-max-chars 20000
  "Most characters of one note the memory keeps."
  :type 'integer
  :group 'harness-workspace-memory)

(defcustom harness-workspace-memory-default-limit 12
  "Notes a search returns by default."
  :type 'integer
  :group 'harness-workspace-memory)

(defconst harness-workspace-memory--db-name "workspace-memory"
  "Name of the memory database, without .db.")

(defvar harness-workspace-memory--db nil
  "The open SQLite handle, or nil.")

(defvar harness-workspace-memory--fts nil
  "Non-nil when the notes full-text table is available.")

(defvar harness-workspace-memory--schema nil
  "The database the schema was made in.")

(defvar harness-workspace-memory--subscribed nil
  "Non-nil once the module follows workspace episodes.")

(defun harness-workspace-memory--open ()
  "Return the memory database, making its schema once."
  (let ((db (harness-call 'store/sqlite harness-workspace-memory--db-name)))
    (unless db
      (signal 'harness-error (list "SQLite unavailable")))
    (unless (and (eq db harness-workspace-memory--schema)
                 (sqlitep db))
      (setq harness-workspace-memory--db db
            harness-workspace-memory--schema db)
      (ignore-errors (sqlite-pragma db "journal_mode=WAL"))
      (ignore-errors (sqlite-pragma db "synchronous=NORMAL"))
      (sqlite-execute db "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, workspace TEXT NOT NULL, thread TEXT, role TEXT NOT NULL, text TEXT NOT NULL, ts REAL NOT NULL)")
      (sqlite-execute db "CREATE INDEX IF NOT EXISTS notes_workspace ON notes (workspace, ts)")
      (setq harness-workspace-memory--fts
            (condition-case err
                (progn
                  (sqlite-execute db "CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(text, content='notes', content_rowid='id', tokenize='porter unicode61 remove_diacritics 2')")
                  (sqlite-execute db "CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN INSERT INTO notes_fts (rowid, text) VALUES (new.id, new.text); END")
                  (sqlite-execute db "CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN INSERT INTO notes_fts (notes_fts, rowid, text) VALUES ('delete', old.id, old.text); END")
                  t)
              (error
               (harness-log 'warn "workspace-memory: FTS5 unavailable, using LIKE: %s"
                            (error-message-string err))
               nil))))
    db))

(defun harness-workspace-memory--clean (text)
  "Return TEXT as one bounded note."
  (let ((text (string-trim (or text ""))))
    (if (> (length text) harness-workspace-memory-max-chars)
        (concat (substring text 0 harness-workspace-memory-max-chars) "\n…")
      text)))

(defun harness-workspace-memory--row (row)
  "Return ROW of the notes table as a plist."
  (list :id (nth 0 row)
        :thread (nth 1 row)
        :role (nth 2 row)
        :text (nth 3 row)
        :ts (nth 4 row)))

(harness-defmethod memory/write (workspace thread role text &optional opts)
  "Write TEXT as a note of WORKSPACE's THREAD.
ROLE is `user', `assistant' or `plan'.  Return the note's id."
  (ignore opts)
  (let* ((db (harness-workspace-memory--open))
         (text (harness-workspace-memory--clean text))
         (role (or role "note")))
    (when (string-blank-p text)
      (signal 'harness-error (list "Empty memory note")))
    (sqlite-execute db "INSERT INTO notes (workspace, thread, role, text, ts) VALUES (?, ?, ?, ?, ?)"
                    (list workspace thread (format "%s" role) text (float-time)))
    (let ((id (caar (sqlite-select db "SELECT last_insert_rowid()"))))
      (harness-emit 'workspace/memory-changed workspace
                    (list :id id :thread thread :role role))
      id)))

(defun harness-workspace-memory--fts-query (query)
  "Return an FTS5 expression for QUERY, or nil."
  (let ((words (cl-remove-if (lambda (word) (< (length word) 2))
                             (split-string (downcase query) "[^[:alnum:]_./-]+" t))))
    (when words
      (mapconcat (lambda (word)
                   (format "\"%s\"*" (replace-regexp-in-string "\"" "\"\"" word)))
                 words " OR "))))

(defun harness-workspace-memory--like (db workspace query limit thread)
  "Search DB with LIKE for QUERY, limited to WORKSPACE and THREAD."
  (let ((pattern (concat "%" (replace-regexp-in-string "[%_]" "\\\\&" query) "%")))
    (mapcar #'harness-workspace-memory--row
            (sqlite-select db
                           (if thread
                               "SELECT id, thread, role, text, ts FROM notes WHERE workspace = ? AND thread = ? AND text LIKE ? ESCAPE '\\' ORDER BY ts DESC LIMIT ?"
                             "SELECT id, thread, role, text, ts FROM notes WHERE workspace = ? AND text LIKE ? ESCAPE '\\' ORDER BY ts DESC LIMIT ?")
                           (if thread (list workspace thread pattern limit)
                             (list workspace pattern limit))))))

(harness-defmethod memory/search (workspace query &optional opts)
  "Return notes of WORKSPACE that match QUERY, best first.
OPTS may name `:limit' and `:thread'.  The result is a list of plists
with `:id', `:thread', `:role', `:text', `:ts' and `:snippet'."
  (let* ((db (harness-workspace-memory--open))
         (limit (or (plist-get opts :limit) harness-workspace-memory-default-limit))
         (thread (plist-get opts :thread))
         (query (string-trim (or query ""))))
    (cond
     ((string-blank-p query)
      nil)
     ((and harness-workspace-memory--fts
           (harness-workspace-memory--fts-query query))
      (condition-case err
          (let ((rows (sqlite-select
                       db
                       (if thread
                           "SELECT n.id, n.thread, n.role, n.text, n.ts, snippet(notes_fts, 0, '<<', '>>', '…', 18) FROM notes_fts JOIN notes n ON n.id = notes_fts.rowid WHERE notes_fts MATCH ? AND n.workspace = ? AND n.thread = ? ORDER BY rank LIMIT ?"
                         "SELECT n.id, n.thread, n.role, n.text, n.ts, snippet(notes_fts, 0, '<<', '>>', '…', 18) FROM notes_fts JOIN notes n ON n.id = notes_fts.rowid WHERE notes_fts MATCH ? AND n.workspace = ? ORDER BY rank LIMIT ?")
                       (if thread
                           (list (harness-workspace-memory--fts-query query) workspace thread limit)
                         (list (harness-workspace-memory--fts-query query) workspace limit)))))
            (mapcar (lambda (row)
                      (append (harness-workspace-memory--row row)
                              (list :snippet (or (nth 5 row) (nth 3 row)))))
                    rows))
        (error
         (harness-log 'warn "workspace-memory: FTS search failed, using LIKE: %s"
                      (error-message-string err))
         (harness-workspace-memory--like db workspace query limit thread))))
     (t
      (harness-workspace-memory--like db workspace query limit thread)))))

(harness-defmethod memory/status (&optional workspace)
  "Return what the memory holds for WORKSPACE, or for every workspace."
  (let* ((db (harness-workspace-memory--open))
         (row (if workspace
                  (car (sqlite-select db "SELECT COUNT(*), MAX(ts) FROM notes WHERE workspace = ?" (list workspace)))
                (car (sqlite-select db "SELECT COUNT(*), MAX(ts) FROM notes"))))
         (count (or (nth 0 row) 0))
         (last (nth 1 row)))
    (list :notes count :last last :fts harness-workspace-memory--fts
          :workspace workspace)))

(harness-defmethod memory/notes (workspace &optional opts)
  "Return the notes of WORKSPACE, newest first."
  (let* ((db (harness-workspace-memory--open))
         (limit (or (plist-get opts :limit) 50))
         (thread (plist-get opts :thread))
         (rows (if thread
                   (sqlite-select db "SELECT id, thread, role, text, ts FROM notes WHERE workspace = ? AND thread = ? ORDER BY ts DESC LIMIT ?"
                                  (list workspace thread limit))
                 (sqlite-select db "SELECT id, thread, role, text, ts FROM notes WHERE workspace = ? ORDER BY ts DESC LIMIT ?"
                                (list workspace limit)))))
    (mapcar #'harness-workspace-memory--row rows)))

(harness-defmethod memory/remember (session-id text &optional thread)
  "Write TEXT as a note for SESSION-ID's workspace and THREAD.
The session must be a workspace episode.  Return the note's id."
  (let* ((session (harness-call 'session/get session-id))
         (ext (plist-get session :ext))
         (workspace (plist-get ext :workspace)))
    (unless workspace
      (signal 'harness-error (list "Not a workspace episode")))
    (harness-call 'memory/write workspace (or thread (plist-get ext :thread))
                  'assistant text)))

;;;; Tool handlers

(defun harness-workspace-memory--tool-workspace (ctx)
  "Return (WORKSPACE . THREAD) of the episode in CTX, or signal."
  (let* ((session-id (plist-get ctx :session-id))
         (session (and session-id (harness-call 'session/get session-id)))
         (ext (plist-get session :ext))
         (workspace (plist-get ext :workspace)))
    (unless workspace
      (signal 'harness-error (list "Workspace episode only")))
    (cons workspace (plist-get ext :thread))))

(defun harness-workspace-memory--tool-search (input ctx)
  "Handler of memory_search with INPUT and CTX."
  (let* ((pair (harness-workspace-memory--tool-workspace ctx))
         (workspace (car pair))
         (thread (or (plist-get input :thread) (cdr pair)))
         (query (or (plist-get input :query) ""))
         (limit (or (plist-get input :limit) harness-workspace-memory-default-limit))
         (cards (harness-call 'memory/search workspace query
                              (list :limit limit :thread (and (not (plist-get input :all)) thread)))))
    (if (null cards)
        (harness-tool-ok (format "No memory matches %S." query))
      (harness-tool-ok
       (concat (format "%d note%s:\n" (length cards) (if (= (length cards) 1) "" "s"))
               (mapconcat (lambda (card)
                            (format "- [%s, %s] %s"
                                    (or (plist-get card :thread) "workspace")
                                    (or (plist-get card :role) "note")
                                    (plist-get card :text)))
                          cards "\n"))))))

(defun harness-workspace-memory--tool-write (input ctx)
  "Handler of memory_write with INPUT and CTX."
  (let* ((pair (harness-workspace-memory--tool-workspace ctx))
         (workspace (car pair))
         (thread (or (plist-get input :thread) (cdr pair)))
         (text (or (plist-get input :text) (plist-get input :memory) "")))
    (if (string-blank-p text)
        (harness-tool-error "Empty memory text")
      (let ((id (harness-call 'memory/write workspace thread 'assistant text)))
        (harness-tool-ok (format "Remembered as note %s." id))))))

(defun harness-workspace-memory--tool-status (_input ctx)
  "Handler of memory_status with CTX."
  (let* ((pair (harness-workspace-memory--tool-workspace ctx))
         (status (harness-call 'memory/status (car pair))))
    (harness-tool-ok
     (format "%s notes in this workspace, last %s; search is %s."
             (plist-get status :notes)
             (if-let* ((last (plist-get status :last)))
                 (format-time-string "%Y-%m-%d %H:%M" last)
               "never")
             (if (plist-get status :fts) "full text" "word matching")))))

;;;; Writing the turns

(defun harness-workspace-memory--on-node-added (session-id node)
  "Write a workspace message NODE of SESSION-ID to the memory."
  (when-let* ((ext (harness-workspace-memory--episode-ext session-id))
              (kind (let ((kind (plist-get node :kind)))
                      (cond ((symbolp kind) kind) ((stringp kind) (intern kind)))))
              ((memq kind '(user assistant plan)))
              ((not (plist-get (plist-get node :meta) :workspace-brief)))
              (text (plist-get node :content))
              ((and (stringp text) (not (string-blank-p text)))))
    (ignore-errors
      (harness-call 'memory/write
                    (plist-get ext :workspace)
                    (plist-get ext :thread)
                    (if (eq kind 'user) 'user 'assistant)
                    text))))

(defun harness-workspace-memory--episode-ext (session-id)
  "Return SESSION-ID's ext when it names a workspace."
  (when (and (stringp session-id)
             (harness-method-exists-p 'session/exists-p)
             (harness-call 'session/exists-p session-id))
    (let ((ext (plist-get (harness-call 'session/get session-id) :ext)))
      (and (plist-get ext :workspace) ext))))

;;;; Module

(harness-define-tool "memory_search"
  :label "Memory search"
  :description "Search the workspace's long-term notes. Use it for anything the brief did not give you, for a decision from another thread, or for a preference the user mentioned before. Returns the matching notes with their thread and role; never invent a memory you did not retrieve."
  :schema '(:type "object"
            :properties (:query (:type "string" :description "Words or a question to find in the notes.")
                         :thread (:type "string" :description "Only notes of this thread; by default the current thread is searched first. Set all to search every thread.")
                         :all (:type "boolean" :description "Search every thread of the workspace, not only the current one.")
                         :limit (:type "integer" :description "Most notes to return."))
            :required ("query"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (plist-get input :query))
  :handler #'harness-workspace-memory--tool-search)

(harness-define-tool "memory_write"
  :label "Remember"
  :description "Write a durable memory note for the workspace: a preference, a decision, a commitment, a fact about a person or project, or an open loop. Use it when the user asks you to remember, when a decision is made, or when a commitment is created. It is not a transcript dump."
  :schema '(:type "object"
            :properties (:text (:type "string" :description "The note, one or two sentences.")
                         :thread (:type "string" :description "The thread to write it to; the current one by default."))
            :required ("text"))
  :kind 'write
  :coalescable t
  :subject (lambda (input) (harness-first-line (plist-get input :text) 60))
  :handler #'harness-workspace-memory--tool-write)

(harness-define-tool "memory_status"
  :label "Memory status"
  :description "Say how many notes the workspace memory holds and when the last one was written."
  :schema '(:type "object" :properties :empty)
  :kind 'read
  :handler #'harness-workspace-memory--tool-status)

(defun harness-workspace-memory--init ()
  "Open the memory and follow the workspace messages.
A build without SQLite leaves the module running with no store: the
workspace still chats, and the memory tools say why they cannot."
  (condition-case err
      (harness-workspace-memory--open)
    (error (harness-log 'warn "workspace-memory: no store: %s"
                        (error-message-string err))))
  (unless harness-workspace-memory--subscribed
    (setq harness-workspace-memory--subscribed t)
    (harness-on 'session/node-added #'harness-workspace-memory--on-node-added)))

(defun harness-workspace-memory--shutdown ()
  "Stop following the workspace messages."
  (when harness-workspace-memory--subscribed
    (setq harness-workspace-memory--subscribed nil)
    (harness-off (cons 'session/node-added #'harness-workspace-memory--on-node-added))))

(harness-define-module 'workspace-memory
  :doc "Long-term notes and full-text recall for workspace mode."
  :requires '(store session tools)
  :init #'harness-workspace-memory--init
  :shutdown #'harness-workspace-memory--shutdown)

(provide 'harness-workspace-memory)
;;; harness-workspace-memory.el ends here
