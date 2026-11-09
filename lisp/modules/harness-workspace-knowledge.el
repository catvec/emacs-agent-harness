;;; harness-workspace-knowledge.el --- The workspace's Logseq knowledge graph -*- lexical-binding: t; -*-

;;; Commentary:

;; The workspace's knowledge lives in a Logseq graph (harness-logseq.el),
;; not in the harness's memory store.  A thread is a page, the durable
;; things the agent learns are blocks on it, and the conversation's
;; turns are captured in the day's journal under a link to the thread's
;; page.  The graph is the source of truth: the user can open it in
;; Logseq, edit or delete a block, and the next search reads what they
;; wrote.  Nothing here writes a second store or a cache.
;;
;; The graph is the user's, not the harness's.  A workspace has a
;; `:graph' directory (defaulting to `harness-logseq-directory', which
;; reads `LOGSEQ_HOME'), and several workspaces may share one graph:
;; every block says which workspace wrote it, so a search sees its own
;; workspace's knowledge unless it asks for the whole graph.
;;
;; What is written when:
;;
;; - `knowledge/thread-page': the thread's page (`Threads/<title>') with
;;   its identity block -- workspace, workspace id, thread id, status,
;;   project -- created when the thread starts and looked up by id;
;; - the capture: one journal block per message, with the thread's page
;;   as a link and the session and node as provenance;
;; - `knowledge/write': a durable block on the thread's page, or on a
;;   page the agent names (`Projects/harness', `Preferences'), which is
;;   what the knowledge tools write;
;; - `knowledge/thread-touch': the thread page's status, last-touched,
;;   summary and next-action properties, so the page reads current in
;;   Logseq;
;; - the nightly dream: `knowledge/dream' runs over every workspace once a
;;   day at `harness-workspace-knowledge-dream-hour';
;; - `knowledge/dream': the graph's maintenance pass.  A thread page gets
;;   its current identity and state again, a note this workspace wrote
;;   twice is kept once, and the changes go on a `Dreams/<date>' report
;;   page.  `:dry-run' reports without writing, and no block the user
;;   wrote is touched.
;;
;; Who writes a note, and when: the agent, in its turn, through
;; `knowledge_write' -- it knows what the turn settled and writes what
;; is worth keeping while it still has the conversation in context.
;; Nothing here reads a finished turn with a model of its own: a second
;; pass over every turn repeats the work the agent had already done,
;; costs a call per turn, and tends to accumulate trivia.  The dream
;; below is the only automatic writer, it asks no model, and it touches
;; nothing but the state of pages this workspace made.
;;
;; A block keeps its shape: a line of a message or a note becomes an
;; indented continuation, so code, quotes and paragraphs stay whole, and
;; a fenced code block is text even where a line looks like a bullet or
;; a property.  The properties are lowercase and dashed, pages are
;; namespaced (`Threads/', `Projects/', `Dreams/'), and only a page that
;; exists is linked.
;;
;; The tools (`knowledge_search', `knowledge_write', `knowledge_read'
;; and `knowledge_status') are offered to workspace episodes only; every
;; other session keeps the harness's memory tools.  Memories are the
;; small behavioral notes -- how the user wants work done -- and the
;; workspace's own prompt says so.
;;
;; The module is deliberately not an index: a search reads the graph and
;; ranks the blocks it finds (harness-logseq/search).  The graph can be
;; large, so a search reads the newest pages and journals first and
;; stops at `harness-logseq-search-pages' and `...-journal-pages'.  A
;; later stage can put an index in front of the same answers without
;; changing this contract.
;;
;; A semantic search goes one step further without an index: with
;; `harness-workspace-knowledge-embedding-model' set, the word matches
;; and the workspace's newest blocks are embedded (provider/embed), and
;; the blocks nearest the query in meaning come first, with a small
;; boost for the words they matched.  The vectors are kept in memory and
;; are dropped when the cache is full; the graph is not changed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-logseq)
(require 'harness-session)
(require 'harness-tools)

(defvar harness-state-directory)

(declare-function harness-secrets-mask-text "harness-secrets" (text))

(defgroup harness-workspace-knowledge nil
  "The workspace's Logseq knowledge graph."
  :group 'harness
  :prefix "harness-workspace-knowledge-")

(defcustom harness-workspace-knowledge-capture-chars 3000
  "Most characters of one message the journal capture keeps."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-recall-limit 8
  "Blocks a brief recalls from the graph."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-thread-blocks 12
  "Blocks a brief quotes from the thread's own page."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-embedding-model nil
  "Model that embeds the graph for semantic search, as PROVIDER:NAME.
nil turns the semantic mode off;
`harness-workspace-knowledge-embedding-dimensions' asks for shorter
vectors where the model allows it."
  :type '(choice (const :tag "Off" nil)
                 (string :tag "Model" :names model))
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-embedding-dimensions nil
  "Length of the vectors to ask for, or nil for the model's own."
  :type '(choice (const :tag "The model's own" nil) integer)
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-embedding-batch 64
  "Most blocks one embedding request carries."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-embedding-cache 2000
  "Most block vectors kept in memory before the cache is cleared."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-semantic-candidates 100
  "Most blocks a semantic search embeds and ranks."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defvar harness-workspace-knowledge--vectors (make-hash-table :test 'equal)
  "The model key and the block text -> its vector.")

(defconst harness-workspace-knowledge--tool-names
  '("knowledge_search" "knowledge_write" "knowledge_read" "knowledge_status")
  "The tools this module offers, to workspace episodes only.")

(defvar harness-workspace-knowledge--pages (make-hash-table :test 'equal)
  "Workspace and thread ids -> the page this module made for them.")

(defvar harness-workspace-knowledge--pending (make-hash-table :test 'equal)
  "Session id -> assistant node ids whose final text is not captured yet.")

(defvar harness-workspace-knowledge--subscribed nil
  "Non-nil once the module follows workspace episodes.")

;;;; Workspaces and pages

(defun harness-workspace-knowledge--workspace (workspace)
  "Return WORKSPACE as its plist, an id or the plist itself."
  (cond ((and (listp workspace) (plist-get workspace :id)) workspace)
        ((and (stringp workspace) (harness-method-exists-p 'workspace/get))
         (harness-call 'workspace/get workspace))
        ((stringp workspace)
         (signal 'harness-error (list (format "No workspace %s" workspace))))
        (t (signal 'harness-error (list "A workspace is needed")))))

(defun harness-workspace-knowledge--root (workspace)
  "Return the Logseq graph WORKSPACE keeps its knowledge in."
  (or (plist-get workspace :graph)
      harness-logseq-directory
      (harness-logseq-root)))

(defun harness-workspace-knowledge--name (workspace)
  "Return the name WORKSPACE writes on its blocks."
  (or (plist-get workspace :name) (plist-get workspace :id) "Workspace"))

(defun harness-workspace-knowledge--thread (workspace thread)
  "Return THREAD of WORKSPACE as its plist.
THREAD may be a thread plist, a thread id or nil."
  (cond ((and (listp thread) (plist-get thread :id)) thread)
        ((stringp thread)
         (let ((found (cl-find thread (plist-get workspace :threads)
                               :key (lambda (item) (plist-get item :id))
                               :test #'equal)))
           (or found (signal 'harness-error (list (format "No thread %s" thread))))))
        ((plist-get workspace :last-thread)
         (harness-workspace-knowledge--thread workspace (plist-get workspace :last-thread)))
        (t nil)))

(defun harness-workspace-knowledge--thread-title (workspace thread)
  "Return the title of THREAD in WORKSPACE."
  (or (plist-get (harness-workspace-knowledge--thread workspace thread) :title)
      "Thread"))

(defun harness-workspace-knowledge--thread-page-name (workspace thread)
  "Return the page name of THREAD in WORKSPACE, without checking the graph."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (wid (plist-get workspace :id))
         (thread (harness-workspace-knowledge--thread workspace thread))
         (tid (plist-get thread :id))
         (key (cons wid tid)))
    (or (gethash key harness-workspace-knowledge--pages)
        (plist-get thread :page)
        (let ((page (harness-logseq-page-name
                     (concat "Threads/" (harness-workspace-knowledge--thread-title
                                         workspace thread)))))
          (puthash key page harness-workspace-knowledge--pages)
          page))))

(defun harness-workspace-knowledge--free-page (workspace thread)
  "Return a page name for THREAD of WORKSPACE that no other thread owns."
  (let* ((root (harness-workspace-knowledge--root workspace))
         (base (harness-workspace-knowledge--thread-page-name workspace thread))
         (tid (plist-get thread :id))
         (candidate base)
         (n 1)
         (found nil))
    (while (and (not found) (< n 100))
      (let ((page (harness-call 'logseq/page candidate (list :root root))))
        (if (null page)
            (setq found candidate)
          (let ((owner (harness-logseq-block-property
                        (car (plist-get page :blocks)) "thread-id")))
            (if (equal owner tid)
                (setq found candidate)
              (setq n (1+ n)
                    candidate (format "%s (%d)" base n)))))))
    (or found candidate)))

(defun harness-workspace-knowledge--summary-line (text)
  "Return TEXT as the one line a page's `summary' property keeps."
  (let ((line (harness-logseq--one-line text)))
    (if (> (length line) 400) (concat (substring line 0 397) "…") line)))

(defun harness-workspace-knowledge--identity (workspace thread)
  "Return the identity properties of THREAD's page in WORKSPACE."
  (let ((workspace (harness-workspace-knowledge--workspace workspace))
        (thread (harness-workspace-knowledge--thread workspace thread)))
    (append
     (list (cons "workspace" (harness-workspace-knowledge--name workspace))
           (cons "workspace-id" (plist-get workspace :id))
           (cons "thread-id" (plist-get thread :id))
           (cons "workspace-status" (or (plist-get thread :status) "active"))
           (cons "thread-title" (plist-get thread :title))
           (cons "project" (or (plist-get thread :project)
                               (plist-get workspace :root)))
           (cons "created" (format-time-string "%Y-%m-%d")))
     (let ((summary (plist-get thread :summary))
           (next (plist-get thread :next-action)))
       (append (when (and (stringp summary) (not (string-blank-p summary)))
                 (list (cons "summary"
                             (harness-workspace-knowledge--summary-line summary))))
               (when (and (stringp next) (not (string-blank-p next)))
                 (list (cons "next-action"
                             (harness-workspace-knowledge--summary-line next)))))))))

(defun harness-workspace-knowledge--ensure-page (workspace thread)
  "Make sure THREAD of WORKSPACE has a page and return its name."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (thread (harness-workspace-knowledge--thread workspace thread))
         (root (harness-workspace-knowledge--root workspace)))
    (unless thread
      (signal 'harness-error (list "A thread is needed for a knowledge page")))
    (let ((page (harness-workspace-knowledge--free-page workspace thread)))
      (unless (harness-call 'logseq/page page (list :root root))
        (harness-call 'logseq/page-add page nil
                      (list :root root
                            :properties (harness-workspace-knowledge--identity
                                         workspace thread))))
      page)))

(defun harness-workspace-knowledge--thread-page (workspace thread)
  "Return THREAD's page name in WORKSPACE's graph, creating it."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (thread (harness-workspace-knowledge--thread workspace thread))
         (page (harness-workspace-knowledge--ensure-page workspace thread))
         (key (cons (plist-get workspace :id) (plist-get thread :id))))
    (puthash key page harness-workspace-knowledge--pages)
    page))

;;;; Reading

(defun harness-workspace-knowledge--scan (workspace &optional opts)
  "Return `(:blocks BLOCKS :pages N)' of what WORKSPACE owns, newest first.
OPTS may name `:limit' and `:page' (one page name).  A block belongs to
WORKSPACE when its `workspace-id' property (or its page's) is the
workspace's; a page counts when the same holds, even if it has no
content blocks yet."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (wid (plist-get workspace :id))
         (limit (or (plist-get opts :limit) 100))
         (page (plist-get opts :page))
         (files (if page
                    (let ((data (harness-call 'logseq/page page (list :root root))))
                      (and data (list (plist-get data :file))))
                  (mapcar (lambda (item) (plist-get item :file))
                          (harness-call 'logseq/page-list
                                        (list :root root :limit 1000)))))
         (blocks nil)
         (pages nil))
    (dolist (file (delete-dups (delq nil files)))
      (let ((content (harness-read-file file)))
        (when (and content (string-match-p (regexp-quote wid) content))
          (let* ((page-name (harness-logseq-page-name-of file root))
                 (journal (equal file (harness-logseq-journal-file page-name root)))
                 (parsed (harness-logseq-parse-blocks content))
                 (page-workspace
                  (cdr (assoc "workspace-id" (plist-get (car parsed) :properties)))))
            (when (and (equal page-workspace wid)
                       (string-prefix-p "Threads/" page-name))
              (push page-name pages))
            (dolist (block (harness-logseq-content-blocks content))
              (let ((block-workspace
                     (or (cdr (assoc "workspace-id" (plist-get block :properties)))
                         page-workspace)))
                (when (equal block-workspace wid)
                  (push (harness-logseq-block-result block page-name journal file)
                        blocks))))))))
    (list :pages (length (delete-dups pages))
          :blocks (seq-take
                   (sort blocks (lambda (a b)
                                  (> (or (plist-get a :ts) 0)
                                     (or (plist-get b :ts) 0))))
                   limit))))

(defun harness-workspace-knowledge--blocks (workspace &optional opts)
  "Return the blocks WORKSPACE owns, newest first.
OPTS may name `:limit' and `:page' (one page name)."
  (plist-get (harness-workspace-knowledge--scan workspace opts) :blocks))

(defun harness-workspace-knowledge--search (workspace query &optional opts)
  "Return the blocks of WORKSPACE's graph that match QUERY.
OPTS may name `:limit', `:thread', `:all' and `:semantic'; see
`knowledge/search'.  The semantic mode returns a promise."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (thread (plist-get opts :thread))
         (page (when thread
                 (harness-workspace-knowledge--thread-page-name workspace thread)))
         (all (plist-get opts :all))
         (limit (or (plist-get opts :limit) 50)))
    (if (plist-get opts :semantic)
        (if (harness-workspace-knowledge--embedding-ready-p)
            (harness-workspace-knowledge--semantic-search workspace query opts)
          (signal 'harness-error
                  (list "Semantic knowledge search needs an embedding model: set harness-workspace-knowledge-embedding-model")))
      (let ((results (harness-call
                      'logseq/search query
                      (list :root root
                            :limit (if page 300 limit)
                            :workspace (unless all (plist-get workspace :id))))))
        (if page
            (seq-take
             (cl-remove-if-not
              (lambda (block)
                (or (equal (plist-get block :page) page)
                    (equal (format "%s" (plist-get block :thread)) page)))
              results)
             limit)
          results)))))

;;;; Semantic search

(defun harness-workspace-knowledge--embedding-key ()
  "Return what a vector is of: the model and the dimensions asked for."
  (format "%s|%s" harness-workspace-knowledge-embedding-model
          (or harness-workspace-knowledge-embedding-dimensions "")))

(defun harness-workspace-knowledge--embedding-ready-p ()
  "Non-nil when semantic search can ask for vectors."
  (and (stringp harness-workspace-knowledge-embedding-model)
       (not (string-empty-p harness-workspace-knowledge-embedding-model))
       (harness-method-exists-p 'provider/embed)))

(defun harness-workspace-knowledge--record-embedding-usage (usage)
  "Record what an embedding request took, USAGE, under no session."
  (when (and usage (harness-method-exists-p 'usage/record))
    (condition-case err
        (let* ((model harness-workspace-knowledge-embedding-model)
               (tokens (list :input (or (plist-get usage :input) 0) :output 0))
               (cost (or (and (harness-method-exists-p 'usage/price)
                              (ignore-errors (harness-call 'usage/price model tokens)))
                         0)))
          (when (> (plist-get tokens :input) 0)
            (harness-call 'usage/record
                          (append (list :session nil :project nil :model model
                                        :cost cost)
                                  tokens))))
      (error
       (harness-log 'warn "workspace knowledge: recording embedding usage failed: %s"
                    (harness-error-message err))))))

(defun harness-workspace-knowledge--embed (texts)
  "Return a promise of the vectors of TEXTS by the embedding model."
  (harness-then
   (harness-call 'provider/embed harness-workspace-knowledge-embedding-model texts
                 (and harness-workspace-knowledge-embedding-dimensions
                      (list :dimensions
                            harness-workspace-knowledge-embedding-dimensions)))
   (lambda (result)
     (harness-workspace-knowledge--record-embedding-usage (plist-get result :usage))
     (plist-get result :vectors))))

(defun harness-workspace-knowledge--embed-batches (texts)
  "Return a promise of the vectors of TEXTS, a request per batch."
  (if (null texts)
      (harness-resolved nil)
    (let ((batch (seq-take texts harness-workspace-knowledge-embedding-batch))
          (rest (seq-drop texts harness-workspace-knowledge-embedding-batch)))
      (harness-then
       (harness-workspace-knowledge--embed batch)
       (lambda (vectors)
         (if (/= (length vectors) (length batch))
             (harness-rejected
              (list 'error
                    (format "The embedding model answered %d vectors for %d blocks"
                            (length vectors) (length batch))))
           (harness-then (harness-workspace-knowledge--embed-batches rest)
                         (lambda (more) (append vectors more)))))))))

(defun harness-workspace-knowledge--cache-vectors (texts vectors)
  "Remember VECTORS of TEXTS, clearing the cache when it is full."
  (let ((key (harness-workspace-knowledge--embedding-key)))
    (when (> (+ (hash-table-count harness-workspace-knowledge--vectors)
                (length texts))
             harness-workspace-knowledge-embedding-cache)
      (clrhash harness-workspace-knowledge--vectors))
    (cl-loop for text in texts
             for vector in vectors
             do (puthash (cons key text) vector
                         harness-workspace-knowledge--vectors))))

(defun harness-workspace-knowledge--embed-texts (texts)
  "Return a promise of nil with the vectors of TEXTS in the cache.
Only the texts without a current vector are sent to the model."
  (let* ((key (harness-workspace-knowledge--embedding-key))
         (missing (cl-remove-if
                   (lambda (text)
                     (gethash (cons key text) harness-workspace-knowledge--vectors))
                   (delete-dups texts))))
    (if (null missing)
        (harness-resolved nil)
      (harness-then
       (harness-workspace-knowledge--embed-batches missing)
       (lambda (vectors)
         (harness-workspace-knowledge--cache-vectors missing vectors)
         nil)))))

(defun harness-workspace-knowledge--cosine (a b)
  "Return the cosine of A and B, sequences of numbers."
  (let ((n (min (length a) (length b)))
        (dot 0.0) (na 0.0) (nb 0.0))
    (dotimes (i n)
      (let ((x (float (elt a i)))
            (y (float (elt b i))))
        (cl-incf dot (* x y))
        (cl-incf na (* x x))
        (cl-incf nb (* y y))))
    (if (or (<= na 0) (<= nb 0))
        0.0
      (/ dot (sqrt (* na nb))))))

(defun harness-workspace-knowledge--semantic-candidates (workspace query opts)
  "Return `(:blocks BLOCKS :ranks RANKS)' for QUERY in WORKSPACE.
BLOCKS are the word matches and the workspace's newest blocks, at most
`harness-workspace-knowledge-semantic-candidates'; RANKS maps a block
id to its place in the word search."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (wid (plist-get workspace :id))
         (thread (plist-get opts :thread))
         (page (when thread
                 (harness-workspace-knowledge--thread-page-name workspace thread)))
         (all (plist-get opts :all))
         (limit (max 1 harness-workspace-knowledge-semantic-candidates))
         (words (harness-call
                 'logseq/search query
                 (list :root root :limit limit :workspace (unless all wid))))
         (recent (harness-workspace-knowledge--blocks workspace (list :limit limit)))
         (seen (make-hash-table :test 'equal))
         (ranks (make-hash-table :test 'equal))
         (blocks nil)
         (rank 0))
    (dolist (block words)
      (let ((id (plist-get block :id)))
        (when id
          (puthash id rank ranks)
          (cl-incf rank))))
    (dolist (block (append words recent))
      (let ((id (or (plist-get block :id) (plist-get block :text))))
        (when (and id (not (gethash id seen))
                   (not (string-blank-p (or (plist-get block :text) "")))
                   (or (not page)
                       (equal (plist-get block :page) page)
                       (equal (format "%s" (plist-get block :thread)) page)))
          (puthash id t seen)
          (push block blocks))))
    (list :blocks (seq-take (nreverse blocks) limit) :ranks ranks)))

(defun harness-workspace-knowledge--semantic-search (workspace query opts)
  "Return a promise of the blocks of WORKSPACE nearest QUERY in meaning.
The candidates are the word matches and the newest blocks; each keeps a
small boost for the words it matched, so the two modes agree."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (limit (or (plist-get opts :limit) 50))
         (candidates (harness-workspace-knowledge--semantic-candidates
                      workspace query opts))
         (blocks (plist-get candidates :blocks))
         (ranks (plist-get candidates :ranks))
         (key (harness-workspace-knowledge--embedding-key))
         (texts (mapcar (lambda (block) (or (plist-get block :text) "")) blocks)))
    (if (null blocks)
        nil
      (harness-then
       (harness-workspace-knowledge--embed-texts (cons query texts))
       (lambda (_)
         (let ((query-vector (gethash (cons key query)
                                      harness-workspace-knowledge--vectors))
               (scored nil))
           (unless query-vector
             (signal 'harness-error
                     (list "The embedding model gave no vector for the query")))
           (dolist (block blocks)
             (let ((vector (gethash (cons key (or (plist-get block :text) ""))
                                    harness-workspace-knowledge--vectors)))
               (when vector
                 (let ((rank (gethash (plist-get block :id) ranks)))
                   (push (cons block
                               (+ (harness-workspace-knowledge--cosine
                                   query-vector vector)
                                  (if rank (/ 0.2 (1+ rank)) 0.0)))
                         scored)))))
           (mapcar #'car
                   (seq-take (sort scored (lambda (a b) (> (cdr a) (cdr b))))
                             limit))))))))

(harness-defmethod knowledge/nearest (query texts &optional timeout)
  "Return how near QUERY is to each of TEXTS in meaning, or nil.
The numbers are cosines in the order of TEXTS.  They need the
workspace's embedding model (`harness-workspace-knowledge-embedding-model');
without one, or when the model does not answer within TIMEOUT seconds
(2 by default), the answer is nil and the caller keeps its own order.
The vectors are cached by text, so a page that did not change is not
embedded twice."
  (when (and (stringp query) (not (string-blank-p query))
             (listp texts) texts
             (harness-workspace-knowledge--embedding-ready-p))
    (let* ((key (harness-workspace-knowledge--embedding-key))
           (texts (mapcar (lambda (text) (or text "")) texts)))
      (condition-case err
          (progn
            (harness-await (harness-workspace-knowledge--embed-texts
                            (cons query texts))
                           (or timeout 2))
            (let ((vector (gethash (cons key query)
                                   harness-workspace-knowledge--vectors)))
              (when vector
                (mapcar (lambda (text)
                          (when-let* ((other (gethash (cons key text)
                                                      harness-workspace-knowledge--vectors)))
                            (harness-workspace-knowledge--cosine vector other)))
                        texts))))
        (error
         (harness-log 'warn "workspace knowledge: nearest failed: %s"
                      (error-message-string err))
         nil)))))

;;;; Writing

(defun harness-workspace-knowledge--capture (workspace thread role session node)
  "Capture NODE of SESSION as ROLE in THREAD of WORKSPACE."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (thread (harness-workspace-knowledge--thread workspace thread))
         (root (harness-workspace-knowledge--root workspace))
         (page (harness-workspace-knowledge--thread-page workspace thread))
         (text (harness-workspace-knowledge--clip
                (or (plist-get node :content) "")))
         (role (format "%s" (or role 'user))))
    (unless (string-blank-p text)
      (harness-call
       'logseq/block-add (harness-logseq-journal-name)
       (format "%s: %s" role text)
       (list :root root
             :journal t
             :date (plist-get node :ts)
             :properties
             (list (cons "workspace" (harness-workspace-knowledge--name workspace))
                   (cons "workspace-id" (plist-get workspace :id))
                   (cons "role" role)
                   (cons "thread" (format "[[%s]]" page))
                   (cons "source-session" session)
                   (cons "source-node" (plist-get node :id)))))
      (harness-workspace-knowledge--changed workspace)
      (harness-emit 'workspace/knowledge-changed
                    (plist-get workspace :id)
                    (list :page page :role role :node (plist-get node :id))))))

(defun harness-workspace-knowledge--clip (text)
  "Return TEXT cut to the most one capture keeps.
Its lines are kept: a message with code or a list stays that shape in
the journal, as Logseq reads a block's continuation lines."
  (let* ((text (string-trim (replace-regexp-in-string
                             "\r\n?" "\n" (or text ""))))
         (limit harness-workspace-knowledge-capture-chars))
    (if (> (length text) limit)
        (concat (replace-regexp-in-string "[ \t\n]+\\'" "" (substring text 0 limit)) "…")
      text)))

;;;; Methods

(defvar harness-workspace-knowledge--status-cache (make-hash-table :test 'equal)
  "Workspace id -> (STATUS . TIME) as `knowledge/status' answered last.")

(defcustom harness-workspace-knowledge-status-seconds 20
  "Seconds a workspace's knowledge status is kept before it is read again.
A write from this process drops it at once; this only bounds how often
the graph is read while nothing changes."
  :type 'number
  :group 'harness-workspace-knowledge)

(defun harness-workspace-knowledge--changed (workspace)
  "Forget what WORKSPACE's status said, after a write."
  (when (listp workspace)
    (remhash (plist-get workspace :id) harness-workspace-knowledge--status-cache)))

(harness-defmethod knowledge/status (&optional workspace)
  "Return what WORKSPACE's knowledge graph holds, or nil for no workspace."
  (let* ((workspace (and workspace (harness-workspace-knowledge--workspace workspace)))
         (wid (plist-get workspace :id))
         (key (or wid "all"))
         (cached (gethash key harness-workspace-knowledge--status-cache)))
    (if (and cached (< (- (float-time) (cdr cached))
                       harness-workspace-knowledge-status-seconds))
        (car cached)
      (let* ((root (harness-workspace-knowledge--root workspace))
             (status (harness-call 'logseq/status root))
             (scan (and wid (harness-workspace-knowledge--scan
                             workspace (list :limit 500))))
             (blocks (plist-get scan :blocks))
             (times (delq nil (mapcar (lambda (block) (plist-get block :ts)) blocks)))
             (answer (list :workspace wid
                           :graph root
                           :available (and (plist-get status :available) t)
                           :reason (plist-get status :reason)
                           :pages (or (plist-get scan :pages) 0)
                           :notes (length blocks)
                           :last (and times (apply #'max times))
                           :fts t
                           :status status)))
        (puthash key (cons answer (float-time))
                 harness-workspace-knowledge--status-cache)
        answer))))

(harness-defmethod knowledge/thread-page (workspace thread)
  "Return THREAD's page name in WORKSPACE's graph, creating it.
The page carries the thread's identity block; the next call finds it by
the thread id."
  (harness-workspace-knowledge--thread-page workspace thread))

(harness-defmethod knowledge/thread-touch (workspace thread &optional status)
  "Bring THREAD's page in WORKSPACE up to date: STATUS and last-touched.
STATUS is `active' or `parked'.  Return the page."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (thread (harness-workspace-knowledge--thread workspace thread))
         (root (harness-workspace-knowledge--root workspace))
         (page (harness-workspace-knowledge--thread-page workspace thread)))
    (harness-call 'logseq/property-set page "last-touched"
                  (format-time-string "%Y-%m-%d") (list :root root))
    (when thread
      (when (plist-get thread :title)
        (harness-call 'logseq/property-set page "thread-title"
                      (plist-get thread :title) (list :root root)))
      (when (plist-get thread :project)
        (harness-call 'logseq/property-set page "project"
                      (plist-get thread :project) (list :root root))))
    (when status
      (harness-call 'logseq/property-set page "workspace-status" status
                    (list :root root)))
    (let ((summary (plist-get thread :summary))
          (next (plist-get thread :next-action)))
      (when (and (stringp summary) (not (string-blank-p summary)))
        (harness-call 'logseq/property-set page "summary"
                      (harness-workspace-knowledge--summary-line summary)
                      (list :root root)))
      (when (and (stringp next) (not (string-blank-p next)))
        (harness-call 'logseq/property-set page "next-action"
                      (harness-workspace-knowledge--summary-line next)
                      (list :root root))))
    page))

(defun harness-workspace-knowledge--masked (text)
  "Return TEXT with the secrets the secrets module knows taken out.
A note is written to a graph a person reads and a model may retrieve, so
a value the redaction layer would mask never reaches it: the value is
replaced by its placeholder.  Without the secrets module the text is
written as it is."
  (if (and (fboundp 'harness-secrets-mask-text)
           (stringp text)
           (not (string-empty-p text)))
      (condition-case err
          (car (harness-secrets-mask-text text))
        (error
         (harness-log 'warn "knowledge: masking a note failed: %s"
                      (harness-error-message err))
         text))
    text))

(defun harness-workspace-knowledge--same-note (page text root)
  "Return PAGE's block that says TEXT as a result plist, or nil.
A note is written once: the comparison is the page's own words, with
whitespace runs and case set aside, so asking for the same statement
again finds the block already there."
  (let* ((wanted (downcase (harness-logseq--one-line (or text ""))))
         (data (and (not (string-empty-p wanted))
                    (harness-call 'logseq/page page (list :root root))))
         (file (plist-get data :file)))
    (when file
      (when-let* ((block (cl-find-if
                          (lambda (block)
                            (equal wanted
                                   (downcase (harness-logseq--one-line
                                              (or (plist-get block :text) "")))))
                          (harness-logseq-content-blocks
                           (or (harness-read-file file) "")))))
        (harness-logseq-block-result block page nil file)))))

(harness-defmethod knowledge/write (workspace thread role text &optional opts)
  "Write TEXT as durable knowledge of WORKSPACE's THREAD, as ROLE.
OPTS may name `:page' (another page of the graph, such as
`Projects/harness'), `:session' and `:node' for provenance, and `:date'.
Return the block, or the block already holding the same statement: a
note is written once, whatever asked for it twice.  This is what
`knowledge_write' writes; a message is captured in the journal instead."
  (ignore role)
  (setq text (harness-workspace-knowledge--masked text))
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (thread (harness-workspace-knowledge--thread workspace thread))
         (named (plist-get opts :page))
         (own (and thread
                   (harness-workspace-knowledge--thread-page workspace thread)))
         (page (if named (harness-logseq-page-name named) own))
         (source-session (plist-get opts :session))
         (source-node (plist-get opts :node))
         (existing (harness-workspace-knowledge--same-note page text root))
         (props (append
                 (list (cons "workspace" (harness-workspace-knowledge--name workspace))
                       (cons "workspace-id" (plist-get workspace :id))
                       ;; Durable knowledge is a note; a capture in the
                       ;; journal is the turn, and says `user' or
                       ;; `assistant' instead.
                       (cons "role" "note"))
                 ;; A note on the thread's own page is already there: a
                 ;; `thread' link to itself would only be a self-reference.
                 (when (and thread own (not (equal page own)))
                   (list (cons "thread" (format "[[%s]]" own))))
                 (when (and source-session (stringp source-session))
                   (list (cons "source-session" source-session)))
                 (when (and source-node (stringp source-node))
                   (list (cons "source-node" source-node)))))
         (block (if existing
                    existing
                  (harness-call 'logseq/page-add page text
                                (list :root root :properties props
                                      :date (plist-get opts :date))))))
    (unless existing
      (harness-workspace-knowledge--changed workspace)
      (harness-emit 'workspace/knowledge-changed
                    (plist-get workspace :id)
                    (list :page page :block (plist-get block :id))))
    block))

(harness-defmethod knowledge/search (workspace query &optional opts)
  "Return the blocks of WORKSPACE's knowledge graph that match QUERY.
OPTS may name `:limit', `:thread' (only that thread's page and
captures) and `:all' (the whole graph, the user's own notes included;
the default is this workspace's blocks).  With `:semantic' non-nil and
`harness-workspace-knowledge-embedding-model' set, the answer is a
promise of the blocks nearest QUERY in meaning, from the word matches
and the workspace's newest blocks.  A result is a block plist as
`harness-logseq/search' returns it."
  (harness-workspace-knowledge--search workspace query opts))

(harness-defmethod knowledge/recall (workspace thread text &optional opts)
  "Return what a brief recalls for TEXT in WORKSPACE's THREAD.
That is the thread's own blocks first, then the graph's matching
blocks, at most `harness-workspace-knowledge-recall-limit'.
OPTS is accepted for the contract."
  (ignore opts)
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (page (harness-workspace-knowledge--thread-page workspace thread))
         (data (harness-call 'logseq/page page (list :root root)))
         (own (when data
                (mapcar (lambda (block)
                          (harness-logseq-block-result block page nil
                                                       (plist-get data :file)))
                        (seq-take (harness-logseq-content-blocks
                                   (harness-read-file (plist-get data :file)))
                                  harness-workspace-knowledge-thread-blocks))))
         (found (harness-call 'knowledge/search workspace
                              (string-trim (format "%s %s" page (or text "")))
                              (list :limit harness-workspace-knowledge-recall-limit)))
         (all (delete-dups (append own found))))
    (seq-take all harness-workspace-knowledge-recall-limit)))

(harness-defmethod knowledge/pages (workspace &optional filter)
  "Return the pages of WORKSPACE's graph it made for its threads.
FILTER is accepted for the contract.  Each page is
`(:id :title :notes :last :page)'."
  (ignore filter)
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (wid (plist-get workspace :id))
         (out nil))
    (dolist (page (harness-call 'logseq/page-list (list :root root :limit 500)))
      (when (string-prefix-p "Threads/" (plist-get page :name))
        (let ((data (harness-call 'logseq/page (plist-get page :name)
                                  (list :root root))))
          (when (equal wid (harness-logseq-block-property
                            (car (plist-get data :blocks)) "workspace-id"))
            (let ((blocks (harness-logseq-content-blocks
                           (harness-read-file (plist-get data :file)))))
              (push (list :id (harness-logseq-block-property
                               (car (plist-get data :blocks)) "thread-id")
                          :title (or (plist-get page :name) "")
                          :notes (length blocks)
                          :last (plist-get page :updated)
                          :page (plist-get page :name))
                    out))))))
    (sort out (lambda (a b) (> (or (plist-get a :last) 0)
                              (or (plist-get b :last) 0))))))

(harness-defmethod knowledge/page (workspace page &optional opts)
  "Return PAGE of WORKSPACE's graph with its blocks.
OPTS may name `:limit'.  A journal page name returns that day."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (data (harness-call 'logseq/page page (list :root root)))
         (limit (or (plist-get opts :limit) 200)))
    (when data
      (list :name (plist-get data :name)
            :file (plist-get data :file)
            :journal (plist-get data :journal)
            :properties (plist-get data :properties)
            :blocks (seq-take (plist-get data :blocks) limit)))))

(harness-defmethod knowledge/notes (workspace &optional opts)
  "Return the newest blocks of WORKSPACE's knowledge, newest first.
OPTS may name `:limit' and `:thread'."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (thread (plist-get opts :thread))
         (blocks (harness-workspace-knowledge--blocks
                  workspace (list :limit (or (plist-get opts :limit) 50)))))
    (if thread
        (let ((page (harness-workspace-knowledge--thread-page-name workspace thread)))
          (cl-remove-if-not (lambda (block)
                              (equal (format "%s" (plist-get block :thread)) page))
                            blocks))
      blocks)))

(harness-defmethod knowledge/remember (session-id text &optional thread)
  "Write TEXT as knowledge for SESSION-ID's workspace and THREAD.
The session must be a workspace episode.  Return the block."
  (let* ((session (harness-call 'session/get session-id))
         (ext (plist-get session :ext))
         (workspace (plist-get ext :workspace)))
    (unless workspace
      (signal 'harness-error (list "Not a workspace episode")))
    (harness-call 'knowledge/write workspace (or thread (plist-get ext :thread))
                  'assistant text (list :session session-id))))

;;;; The graph explorer

;; A thread's page and its blocks, the pages they link and the blocks
;; that link back, as the Emacs buffer and the app read them.  The
;; state layer answers, so both clients see the same graph.

(defun harness-workspace-knowledge--link-targets (text)
  "Return the page names TEXT links with [[...]], in order."
  (let ((start 0) (out nil))
    (while (and (stringp text)
                (string-match "\\[\\[\\([^]\n]+\\)\\]\\]" text start))
      (let ((target (string-trim (match-string 1 text))))
        (unless (or (string-empty-p target) (member target out))
          (push target out)))
      (setq start (match-end 0)))
    (nreverse out)))

(defun harness-workspace-knowledge--tag-values (properties)
  "Return the tags PROPERTIES names, from `tags' or `tag'."
  (let* ((value (or (cdr (assoc "tags" properties))
                    (cdr (assoc "tag" properties))))
         (text (cond ((stringp value) value)
                     ((listp value) (mapconcat (lambda (item) (format "%s" item)) value " "))
                     (t ""))))
    (delete-dups
     (cl-remove-if #'string-empty-p
                   (mapcar (lambda (tag) (string-trim tag " \t#,;"))
                           (split-string text "[,;]" t))))))

(defun harness-workspace-knowledge--block-time-ms (block)
  "Return BLOCK's learned or created time in milliseconds, or nil."
  (let ((value (or (harness-logseq-block-property block "learned-at")
                   (harness-logseq-block-property block "created"))))
    (when (and (stringp value)
               (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" value))
      (ignore-errors (round (* 1000 (float-time (date-to-time value))))))))

(defun harness-workspace-knowledge--block-view (block page)
  "Return BLOCK of PAGE as the explorer reads it."
  (let ((properties (plist-get block :properties)))
    (list :id (or (harness-logseq-block-property block "id")
                  (format "%s#%s" page (plist-get block :line)))
          :line (plist-get block :line)
          :indent (plist-get block :indent)
          :text (plist-get block :text)
          :properties properties
          :tags (harness-workspace-knowledge--tag-values properties)
          :links (harness-workspace-knowledge--link-targets
                  (concat (or (plist-get block :text) "") " "
                          (mapconcat (lambda (pair) (format "%s" (cdr pair)))
                                     properties " ")))
          :created (harness-workspace-knowledge--block-time-ms block)
          :page page)))

(defun harness-workspace-knowledge--graph-page (workspace name)
  "Return page NAME of WORKSPACE's graph with its blocks and backlinks.
The answer is (:workspace :workspace-name :status :why :page-name
:page :blocks :links :backlinks)."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (name (harness-logseq-page-name name))
         (status (harness-call 'logseq/status root))
         (data (when (plist-get status :available)
                 (harness-call 'logseq/page name (list :root root)))))
    (if (null data)
        (list :workspace (plist-get workspace :id)
              :workspace-name (harness-workspace-knowledge--name workspace)
              :status (if (plist-get status :available) "missing" "unavailable")
              :why (plist-get status :reason)
              :page-name name
              :page (list :title name :name name :properties nil :tags nil :links nil)
              :blocks nil :links nil :backlinks nil)
      (let* ((properties (plist-get data :properties))
             ;; A property-only bullet is the page's identity, which the
             ;; page record already carries; it is not a node to read.
             (blocks (cl-loop for block in (plist-get data :blocks)
                              for view = (harness-workspace-knowledge--block-view block name)
                              unless (string-blank-p (or (plist-get view :text) ""))
                              collect view))
             (links (delete name
                            (delete-dups
                             (append (harness-workspace-knowledge--link-targets
                                      (mapconcat (lambda (pair) (format "%s" (cdr pair)))
                                                 properties " "))
                                     (cl-mapcan (lambda (block) (plist-get block :links)) blocks)))))
             ;; A node of this page that links the page is not a node
             ;; that links back to it.
             (backlinks (cl-remove-if
                         (lambda (block) (equal (plist-get block :page) name))
                         (harness-call 'logseq/backlinks name (list :root root)))))
        (list :workspace (plist-get workspace :id)
              :workspace-name (harness-workspace-knowledge--name workspace)
              :status (if (plist-get status :available) "ready" "unavailable")
              :why (plist-get status :reason)
              :page-name name
              :page (list :title name :name name :properties properties
                          :tags (harness-workspace-knowledge--tag-values properties)
                          :links links)
              :blocks blocks :links links :backlinks backlinks
              :count (length blocks))))))

(harness-defmethod knowledge/graph (workspace &optional opts)
  "Return the page of WORKSPACE's thread with its blocks and backlinks.
OPTS may name `:thread'; the last thread is read by default.  The
answer is what the graph explorer draws, the same for every client."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (thread (harness-workspace-knowledge--thread workspace (plist-get opts :thread)))
         (root (harness-workspace-knowledge--root workspace))
         ;; A page is made for the thread when the graph can be written;
         ;; an unavailable graph is read by the page name it would have,
         ;; so the explorer says why instead of failing on the write.
         (page (if (plist-get (harness-call 'logseq/status root) :available)
                   (harness-workspace-knowledge--thread-page workspace thread)
                 (harness-workspace-knowledge--thread-page-name workspace thread))))
    (append (harness-workspace-knowledge--graph-page workspace page)
            (list :thread (harness-workspace-knowledge--thread-title workspace thread)
                  :thread-id (plist-get thread :id)))))

(harness-defmethod knowledge/graph/node (workspace node &optional opts)
  "Return NODE of WORKSPACE's thread's page, with its children.
NODE is a block id or its line.  OPTS may name `:thread'."
  (let* ((data (harness-call 'knowledge/graph workspace opts))
         (blocks (plist-get data :blocks))
         (position (cl-position-if
                    (lambda (block)
                      (or (equal (plist-get block :id) node)
                          (equal (format "%s" (plist-get block :line))
                                 (format "%s" node))))
                    blocks))
         (block (and position (nth position blocks)))
         (indent (and block (plist-get block :indent)))
         (children (and block
                        (cl-loop for child in (nthcdr (1+ position) blocks)
                                 while (> (or (plist-get child :indent) 0)
                                          (or indent 0))
                                 collect child))))
    (if block
        (append data (list :node block :block block :children children))
      (let ((missing (plist-put (copy-sequence data) :status "missing")))
        (append (plist-put missing :why "no-node")
                (list :node nil :block nil :children nil))))))

(harness-defmethod knowledge/graph/page (workspace name &optional opts)
  "Return page NAME of WORKSPACE's graph with its blocks and backlinks.
OPTS is accepted for the contract."
  (ignore opts)
  (harness-workspace-knowledge--graph-page workspace name))

;;;; Maintenance

;; The dream is the graph's own pass over its thread pages: every thread
;; has its page and its current properties, a note this workspace wrote
;; twice is kept once, and what it changed is written down.  It is a
;; method any client can call; the routines stage calls it on a schedule.

(defcustom harness-workspace-knowledge-dream-report t
  "Whether `knowledge/dream' writes a report page in the graph."
  :type 'boolean
  :group 'harness-workspace-knowledge)

(defun harness-workspace-knowledge--note-blocks (blocks)
  "Return the durable notes in BLOCKS, the user's own blocks left out.
A note is a block this workspace wrote as a note; a capture in the
journal and a block the user edited are not maintenance candidates."
  (cl-remove-if-not
   (lambda (block)
     (let ((properties (plist-get block :properties)))
       (and (equal "note" (cdr (assoc "role" properties)))
            (cdr (assoc "workspace-id" properties)))))
   blocks))

(defun harness-workspace-knowledge--duplicates (blocks)
  "Return the later of the notes in BLOCKS whose text repeats an earlier one."
  (let ((seen (make-hash-table :test 'equal))
        (duplicates nil))
    (dolist (block (harness-workspace-knowledge--note-blocks blocks))
      (let ((text (harness-logseq--one-line (or (plist-get block :text) ""))))
        (unless (string-blank-p text)
          (if (gethash text seen)
              (push block duplicates)
            (puthash text t seen)))))
    (nreverse duplicates)))

(harness-defmethod knowledge/dream (workspace &optional opts)
  "Consolidate WORKSPACE's Logseq graph and return what it did.
Every thread gets its page and its current identity, summary and next
action; a note this workspace wrote more than once is kept once, the
others removed (the first stays).  OPTS may name `:dry-run' (report
what would change, write nothing) and `:report' (write a
`Dreams/<date>' page of the changes; the default is
`harness-workspace-knowledge-dream-report').  The answer is
`(:workspace :date :dry-run :pages :removed :report-page)'."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (dry (plist-get opts :dry-run))
         (report (if (plist-member opts :report)
                     (plist-get opts :report)
                   harness-workspace-knowledge-dream-report))
         (date (format-time-string "%Y-%m-%d"))
         (pages 0) (removed 0) (report-page nil) (lines nil))
    (dolist (thread (plist-get workspace :threads))
      (unless (equal (format "%s" (plist-get thread :status)) "merged")
        (let* ((page (harness-workspace-knowledge--thread-page workspace thread))
               (file (harness-logseq-page-file page root))
               (blocks (harness-logseq-parse-blocks (or (harness-read-file file) "")))
               (duplicates (harness-workspace-knowledge--duplicates blocks)))
          (cl-incf pages)
          (dolist (block duplicates)
            (when (not dry)
              (harness-call 'logseq/block-remove
                            page (harness-logseq-block-property block "id")
                            (list :root root)))
            (cl-incf removed)
            (push (format "%s: removed a duplicate note" (plist-get thread :title))
                  lines))
          (unless dry
            (harness-call 'knowledge/thread-touch
                          (plist-get workspace :id) (plist-get thread :id)
                          (plist-get thread :status))))))
    (when (and report (not dry) lines)
      (setq report-page (harness-logseq-page-name (concat "Dreams/" date)))
      (harness-call 'logseq/block-add report-page
                    (format "Dream over %s" (harness-workspace-knowledge--name workspace))
                    (list :root root
                          :properties
                          (list (cons "workspace" (harness-workspace-knowledge--name workspace))
                                (cons "workspace-id" (plist-get workspace :id)))))
      (dolist (line (nreverse lines))
        (harness-call 'logseq/block-add report-page line
                      (list :root root
                            :properties
                            (list (cons "workspace" (harness-workspace-knowledge--name workspace))
                                  (cons "workspace-id" (plist-get workspace :id))
                                  (cons "dreamed-at" (format-time-string "%Y-%m-%d %H:%M")))))))
    (list :workspace (plist-get workspace :id)
          :date date :dry-run (and dry t)
          :pages pages :removed removed :report-page report-page)))

;;;; The nightly dream

(defcustom harness-workspace-knowledge-dream 'auto
  "Whether the graph maintains itself once a day.
`auto' runs `knowledge/dream' over every workspace at
`harness-workspace-knowledge-dream-hour'; nil leaves the pass to a
caller.  A dream that fails is logged and tried again the next night."
  :type '(choice (const :tag "Once a day" auto)
                 (const :tag "Only on request" nil))
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-hour 3
  "Hour of the local day the nightly dream runs, 0 to 23."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defvar harness-workspace-knowledge--dream-timer nil
  "The timer that wakes the nightly dream.")

(defun harness-workspace-knowledge--dreams-file ()
  "Return the file that records each workspace's last dream."
  (expand-file-name "workspace-dreams.eld" harness-state-directory))

(defun harness-workspace-knowledge--dreams ()
  "Return the alist of workspace id to the date of its last dream."
  (let ((file (harness-workspace-knowledge--dreams-file)))
    (when (file-readable-p file)
      (ignore-errors (read (harness-read-file file))))))

(defun harness-workspace-knowledge--dream-record (workspace date)
  "Record that WORKSPACE was dreamed on DATE."
  (let* ((file (harness-workspace-knowledge--dreams-file))
         (all (cons (cons workspace date)
                    (assoc-delete-all workspace
                                      (harness-workspace-knowledge--dreams)))))
    (make-directory (file-name-directory file) t)
    (harness-write-file-atomically file (prin1-to-string all))))

(defun harness-workspace-knowledge--next-dream-time ()
  "Return the time of the next nightly dream, as a float."
  (let* ((now (float-time))
         (today (format-time-string "%Y-%m-%d"))
         (at (float-time (date-to-time
                          (format "%s %02d:00:00" today
                                  harness-workspace-knowledge-dream-hour)))))
    (if (> at now) at (+ at 86400))))

(defun harness-workspace-knowledge--dream-tick ()
  "Dream every workspace that has not been dreamed today."
  (when (eq harness-workspace-knowledge-dream 'auto)
    (dolist (workspace (and (harness-method-exists-p 'workspace/list)
                            (ignore-errors (harness-call 'workspace/list))))
      (let* ((id (plist-get workspace :id))
             (today (format-time-string "%Y-%m-%d"))
             (last (cdr (assoc id (harness-workspace-knowledge--dreams)))))
        (when (and id (not (equal last today)))
          (condition-case err
              (progn
                (harness-call 'knowledge/dream id)
                (harness-workspace-knowledge--dream-record id today)
                (harness-log 'info "workspace dream: %s done" id))
            (error
             (harness-log 'warn "workspace dream: %s: %s"
                          id (harness-error-message err))))))))
  (harness-workspace-knowledge--schedule-dream))

(defun harness-workspace-knowledge--schedule-dream ()
  "Arrange the next nightly dream, or none when it is off."
  (when (timerp harness-workspace-knowledge--dream-timer)
    (cancel-timer harness-workspace-knowledge--dream-timer)
    (setq harness-workspace-knowledge--dream-timer nil))
  (when (eq harness-workspace-knowledge-dream 'auto)
    (setq harness-workspace-knowledge--dream-timer
          (run-at-time (max 60 (- (harness-workspace-knowledge--next-dream-time)
                                  (float-time)))
                       nil #'harness-workspace-knowledge--dream-tick))))

;;;; Session events

(defun harness-workspace-knowledge--episode-ext (session-id)
  "Return SESSION-ID's ext when it names a workspace."
  (when (and (stringp session-id)
             (harness-method-exists-p 'session/exists-p)
             (harness-call 'session/exists-p session-id))
    (let ((ext (plist-get (harness-call 'session/get session-id) :ext)))
      (and (plist-get ext :workspace) ext))))

(defun harness-workspace-knowledge--role (kind)
  "Return KIND as the role a capture writes."
  (let ((kind (if (stringp kind) (intern kind) kind)))
    (pcase kind
      ('user "user")
      ('plan "plan")
      (_ "assistant"))))

(defun harness-workspace-knowledge--on-node-added (session-id node)
  "Capture a workspace message NODE of SESSION-ID in the journal.
An assistant reply is captured when its turn ends, with its final text;
the turn's later chunks would otherwise each become a block.  A capture
records what was said; it asks no model and writes nothing else."
  (when-let* ((ext (harness-workspace-knowledge--episode-ext session-id))
              (kind (plist-get node :kind))
              ((memq (if (stringp kind) (intern kind) kind) '(user assistant plan)))
              (role (harness-workspace-knowledge--role kind))
              ((not (equal role "assistant")))
              ((not (plist-get (plist-get node :meta) :workspace-brief)))
              ;; The harness's own notices and another session's agent are
              ;; not what the user said: they are not knowledge.
              ((not (harness-node-sender node)))
              (text (plist-get node :content))
              ((and (stringp text) (not (string-blank-p text)))))
    (ignore-errors
      (harness-workspace-knowledge--capture
       (plist-get ext :workspace) (plist-get ext :thread)
       role session-id node))))

(defun harness-workspace-knowledge--on-node-updated (session-id node transient)
  "Remember the assistant NODE of SESSION-ID to capture when its turn ends."
  (when (and (not transient)
             (memq (let ((kind (plist-get node :kind)))
                     (if (stringp kind) (intern kind) kind))
                   '(assistant))
             (equal (harness-workspace-knowledge--role (plist-get node :kind))
                    "assistant")
             (harness-workspace-knowledge--episode-ext session-id))
    (let ((nodes (gethash session-id harness-workspace-knowledge--pending)))
      (puthash session-id (cons (plist-get node :id) nodes)
               harness-workspace-knowledge--pending))))

(defun harness-workspace-knowledge--on-turn-ended (session-id &rest _)
  "Capture the final assistant replies of SESSION-ID's finished turn.
What the turn is worth keeping in the graph was decided while it ran:
the agent writes it with `knowledge_write', in its own reply, and no
model is asked anything once the turn is over."
  (when-let* ((nodes (gethash session-id harness-workspace-knowledge--pending))
              (ext (harness-workspace-knowledge--episode-ext session-id)))
    (remhash session-id harness-workspace-knowledge--pending)
    (dolist (node-id (delete-dups nodes))
      (when (and (stringp node-id)
                 (harness-method-exists-p 'session/node))
        (ignore-errors
          (let ((node (harness-call 'session/node session-id node-id)))
            (when node
              (harness-workspace-knowledge--capture
               (plist-get ext :workspace) (plist-get ext :thread)
               "assistant" session-id node))))))))

;;;; Tools

(defun harness-workspace-knowledge--tool-workspace (ctx)
  "Return (WORKSPACE . THREAD) of the episode in CTX, or signal."
  (let* ((session-id (plist-get ctx :session-id))
         (session (and session-id (harness-call 'session/get session-id)))
         (ext (plist-get session :ext))
         (workspace (plist-get ext :workspace)))
    (unless workspace
      (signal 'harness-error (list "Workspace episode only")))
    (cons workspace (plist-get ext :thread))))

(defun harness-workspace-knowledge--search-result (query cards)
  "Return CARDS as the knowledge_search answer to QUERY."
  (if (null cards)
      (harness-tool-ok (format "No knowledge matches %S." query))
    (harness-tool-ok
     (concat (format "%d block%s:\n" (length cards)
                     (if (= (length cards) 1) "" "s"))
             (mapconcat (lambda (card)
                          (format "- [%s] %s"
                                  (or (plist-get card :page) "graph")
                                  (plist-get card :text)))
                        cards "\n")))))

(defun harness-workspace-knowledge--tool-search (input ctx)
  "Handler of knowledge_search with INPUT and CTX."
  (let* ((pair (harness-workspace-knowledge--tool-workspace ctx))
         (workspace (car pair))
         (thread (plist-get input :thread))
         (query (or (plist-get input :query) ""))
         (limit (or (plist-get input :limit) 20))
         (mode (let ((mode (plist-get input :mode)))
                 (if (stringp mode) (intern mode) mode))))
    (condition-case err
        (let ((cards (harness-call 'knowledge/search workspace query
                                   (list :limit limit
                                         :semantic (eq mode 'semantic)
                                         :all (plist-get input :all)
                                         :thread (and thread
                                                      (not (plist-get input :all))
                                                      thread)))))
          (if (harness-promise-p cards)
              (harness-then cards
                            (lambda (found)
                              (harness-workspace-knowledge--search-result query found))
                            (lambda (failure)
                              (harness-tool-error
                               (format "The knowledge search failed: %s"
                                       (harness-error-message failure)))))
            (harness-workspace-knowledge--search-result query cards)))
      (harness-error
       (harness-tool-error (harness-error-message err)))
      (error
       (harness-tool-error (format "The knowledge search failed: %s"
                                   (harness-error-message err)))))))

(defun harness-workspace-knowledge--tool-write (input ctx)
  "Handler of knowledge_write with INPUT and CTX."
  (let* ((pair (harness-workspace-knowledge--tool-workspace ctx))
         (workspace (car pair))
         (thread (or (plist-get input :thread) (cdr pair)))
         (text (or (plist-get input :text) "")))
    (if (string-blank-p text)
        (harness-tool-error "Empty knowledge text")
      (let ((block (harness-call 'knowledge/write
                                 workspace thread 'assistant text
                                 (list :page (plist-get input :page)
                                       :session (plist-get ctx :session-id)))))
        (harness-tool-ok (format "Wrote [[%s]] block %s."
                                 (plist-get block :page) (plist-get block :id)))))))

(defun harness-workspace-knowledge--tool-read (input ctx)
  "Handler of knowledge_read with INPUT and CTX."
  (let* ((pair (harness-workspace-knowledge--tool-workspace ctx))
         (page (or (plist-get input :page) ""))
         (data (harness-call 'knowledge/page (car pair) page
                             (list :limit (or (plist-get input :limit) 100)))))
    (if (null data)
        (harness-tool-error (format "No page %S." page))
      (harness-tool-ok
       (format "[[%s]]%s\n%s"
               (plist-get data :name)
               (if (plist-get data :journal) " (journal)" "")
               (mapconcat (lambda (block)
                            (format "- %s" (plist-get block :text)))
                          (cl-remove-if (lambda (block)
                                          (string-empty-p (plist-get block :text)))
                                        (plist-get data :blocks))
                          "\n"))))))

(defun harness-workspace-knowledge--tool-status (_input ctx)
  "Handler of knowledge_status with CTX."
  (let* ((pair (harness-workspace-knowledge--tool-workspace ctx))
         (status (harness-call 'knowledge/status (car pair))))
    (if (plist-get status :available)
        (harness-tool-ok
         (format "%s blocks on %s pages in [[%s]]; last %s."
                 (plist-get status :notes)
                 (plist-get status :pages)
                 (or (plist-get status :graph) "graph")
                 (if-let* ((last (plist-get status :last)))
                     (format-time-string "%Y-%m-%d %H:%M" last)
                   "never")))
      (harness-tool-error
       (format "No Logseq graph at %s." (or (plist-get status :graph) "the root"))))))

;;;; The tool filter

(defun harness-workspace-knowledge--tools (tools session)
  "Offer the knowledge tools to a workspace episode, and to no one else.
TOOLS are the names another filter left; SESSION is the session plist."
  (let ((workspace (plist-get (plist-get session :ext) :workspace)))
    (if (or (null session) workspace)
        (delete-dups
         (append (cl-remove-if (lambda (name)
                                 (member name harness-workspace-knowledge--tool-names))
                               tools)
                 (cl-remove-if-not #'harness-tool-get
                                   harness-workspace-knowledge--tool-names)))
      (cl-remove-if (lambda (name)
                      (member name harness-workspace-knowledge--tool-names))
                    tools))))

;;;; Module

(harness-define-tool "knowledge_search"
  :label "Search knowledge"
  :description "Search the workspace's Logseq knowledge graph: decisions, facts, projects, people and the notes of every thread. Use it for anything the brief did not give you, for what another thread learned, or for a preference the user wrote down. Set all to search the user's whole graph, not only this workspace. With mode semantic and an embedding model set, it finds blocks by meaning rather than by words. Never invent knowledge you did not retrieve."
  :schema '(:type "object"
            :properties (:query (:type "string" :description "Words or a question to find in the graph.")
                         :mode (:type "string" :enum ("text" "semantic")
                                :description "Match words, or meaning when an embedding model is set.")
                         :thread (:type "string" :description "Only this thread's page and captures; the current thread by default.")
                         :all (:type "boolean" :description "Search the whole graph, the user's own notes included.")
                         :limit (:type "integer" :description "Most blocks to return."))
            :required ("query"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (plist-get input :query))
  :handler #'harness-workspace-knowledge--tool-search)

(harness-define-tool "knowledge_write"
  :label "Write knowledge"
  :description "Write durable knowledge to the workspace's Logseq graph: a decision, a fact, a commitment, an open loop or a next action. The block goes on the current thread's page unless page names another one (Projects/harness, Preferences, People/Ada); a statement already on the page is not written again. Write one concise statement, not a transcript dump, and only when the turn settled something; the user's own edits in Logseq outrank what you write."
  :schema '(:type "object"
            :properties (:text (:type "string" :description "The knowledge: one concise, self-contained statement.")
                         :page (:type "string" :description "Another page of the graph, such as Projects/harness; the thread's page by default.")
                         :thread (:type "string" :description "The thread whose page gets it; the current one by default."))
            :required ("text"))
  :kind 'write
  :coalescable t
  :subject (lambda (input) (harness-first-line (plist-get input :text) 60))
  :handler #'harness-workspace-knowledge--tool-write)

(harness-define-tool "knowledge_read"
  :label "Read knowledge page"
  :description "Read one page of the workspace's Logseq graph by name, such as a thread's page or Projects/harness. Returns the page's blocks, newest last."
  :schema '(:type "object"
            :properties (:page (:type "string" :description "The page name, such as Threads/Kitchen renovation.")
                         :limit (:type "integer" :description "Most blocks to return."))
            :required ("page"))
  :kind 'read
  :coalescable t
  :subject (lambda (input) (plist-get input :page))
  :handler #'harness-workspace-knowledge--tool-read)

(harness-define-tool "knowledge_status"
  :label "Knowledge status"
  :description "Say what the workspace's Logseq graph holds: blocks, pages, the graph root and when it last changed."
  :schema '(:type "object" :properties :empty)
  :kind 'read
  :handler #'harness-workspace-knowledge--tool-status)

(defun harness-workspace-knowledge--install-acp ()
  "Expose the knowledge methods, and the names the app already calls them by.
The Flutter workspace app asks for `memory/notes', `memory/search' and
`memory/status' with a `:workspace'; those names call the knowledge
methods, while the harness's own memory tools keep their names."
  (when (boundp 'harness-acp-extra-method-prefixes)
    (add-to-list 'harness-acp-extra-method-prefixes "knowledge/"))
  (when (boundp 'harness-acp-extra-method-aliases)
    (let ((workspace-p (lambda (params) (plist-get params :workspace))))
      (dolist (pair '(("memory/notes" "knowledge/notes")
                      ("memory/search" "knowledge/search")
                      ("memory/status" "knowledge/status")))
        (add-to-list 'harness-acp-extra-method-aliases
                     (list (car pair) (cadr pair) workspace-p))))))

(defun harness-workspace-knowledge--init ()
  "Follow the workspace's episodes and offer the knowledge tools to them."
  (harness-workspace-knowledge--install-acp)
  (with-eval-after-load 'harness-acp (harness-workspace-knowledge--install-acp))
  (unless harness-workspace-knowledge--subscribed
    (setq harness-workspace-knowledge--subscribed t)
    (harness-on 'session/node-added #'harness-workspace-knowledge--on-node-added)
    (harness-on 'session/node-updated #'harness-workspace-knowledge--on-node-updated)
    (harness-on 'agent/turn-ended #'harness-workspace-knowledge--on-turn-ended)
    (harness-add-filter 'agent/tools #'harness-workspace-knowledge--tools 40))
  (harness-workspace-knowledge--schedule-dream))

(defun harness-workspace-knowledge--shutdown ()
  "Stop following the workspace's episodes."
  (when harness-workspace-knowledge--subscribed
    (setq harness-workspace-knowledge--subscribed nil)
    (harness-off (cons 'session/node-added #'harness-workspace-knowledge--on-node-added))
    (harness-off (cons 'session/node-updated #'harness-workspace-knowledge--on-node-updated))
    (harness-off (cons 'agent/turn-ended #'harness-workspace-knowledge--on-turn-ended))
    (harness-remove-filter 'agent/tools #'harness-workspace-knowledge--tools))
  (when (timerp harness-workspace-knowledge--dream-timer)
    (cancel-timer harness-workspace-knowledge--dream-timer)
    (setq harness-workspace-knowledge--dream-timer nil)))

(harness-declare-event 'workspace/knowledge-changed
                       "(WORKSPACE OP) when a block was written to the workspace's graph.")

(harness-define-module 'workspace-knowledge
  :doc "The workspace's Logseq knowledge graph: thread pages, journal captures, retrieval and the knowledge tools."
  :requires '(logseq session tools)
  :init #'harness-workspace-knowledge--init
  :shutdown #'harness-workspace-knowledge--shutdown)

(provide 'harness-workspace-knowledge)
;;; harness-workspace-knowledge.el ends here
