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
;; - the dream: `knowledge/dream' runs over every workspace once a day
;;   at `harness-workspace-knowledge-dream-hour', and catches up once on
;;   a start that missed it;
;; - `knowledge/dream': the graph's maintenance and synthesis pass.  A
;;   thread page gets its current identity and state again, a note this
;;   workspace wrote twice is kept once (the children of the copy it
;;   removes are lifted, not dropped), and the captures no pass has read
;;   yet are synthesized across threads into sourced project, person,
;;   topic and decision knowledge, a repaired index and a `Dreams/<date>'
;;   report page.  `:dry-run' reports without writing.
;;
;; Who writes a note, and when: the agent, in its turn, through
;; `knowledge_write' -- it knows what the turn settled and writes what
;; is worth keeping while it still has the conversation in context.  The
;; dream is the second writer, and the only automatic one: once a day it
;; reads the captures no pass has read and asks a model to make durable,
;; sourced knowledge of them.  It writes only pages of the maintained
;; namespaces that this workspace owns, and marks a capture read only
;; once every page of its batch was written.  It keeps no copy of what it
;; wrote: the page is the record, and `logseq/status' says what recovery
;; the graph itself has.
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
(require 'harness-prompts)

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
         (raw (or (plist-get node :content) ""))
         (text (harness-workspace-knowledge--clip raw))
         (clipped (harness-workspace-knowledge--clipped-p raw text))
         (role (format "%s" (or role 'user))))
    (unless (string-blank-p text)
      (harness-call
       'logseq/block-add (harness-logseq-journal-name)
       (format "%s: %s" role text)
       (list :root root
             :journal t
             :date (plist-get node :ts)
             :properties
             (append
              (list (cons "workspace" (harness-workspace-knowledge--name workspace))
                    (cons "workspace-id" (plist-get workspace :id))
                    (cons "role" role)
                    (cons "thread" (format "[[%s]]" page))
                    (cons "source-session" session)
                    (cons "source-node" (plist-get node :id)))
              ;; A clipped capture keeps the link back to the whole text,
              ;; so a pass that needs more than the journal holds reads
              ;; the session's node instead of guessing.
              (when clipped
                (list (cons "capture-clipped" "true"))))))
      (harness-workspace-knowledge--changed workspace)
      (harness-emit 'workspace/knowledge-changed
                    (plist-get workspace :id)
                    (list :page page :role role :node (plist-get node :id))))))

(defun harness-workspace-knowledge--clipped-p (raw text)
  "Non-nil when TEXT, a capture, is RAW cut to what a journal block keeps."
  (and (stringp raw) (> (length raw) (length (or text "")))))

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

;; The dream is the graph's own pass over the material a workspace
;; generated: the captures in the journals, the notes its agents wrote
;; and the pages that hold them.  A deterministic pass first brings every
;; thread page's state up to date and keeps a note this workspace wrote
;; twice once, lifting the children of the copy it removes so distinct
;; knowledge survives it.  What the captures settled is then synthesized
;; across threads by one model call per bounded batch: project, person,
;; topic and decision knowledge, each statement with its sources and a
;; confidence that says what the sources confirm from what was inferred
;; or is still unresolved, and a small navigation index.
;;
;; The pass recomputes rather than replays.  It reads the graph, writes
;; what it planned in one atomic change per page with the digest of the
;; page it read (`logseq/page-edit's `:expect'), and marks a batch
;; processed only after every page of it was written.  A page that
;; changed while the pass was planning is read again and the change
;; recomputed; a run that stopped between its last save and its
;; bookkeeping leaves its intent behind, and the next run sees the
;; content it saved instead of writing it again.
;;
;; The user's edits are input to a pass, not a fence around it: a page
;; the user wrote is read, corrected and reorganized like any other.
;; What the user rejects is kept in an exclusion list -- `no-dream:: true'
;; on a page or a block, and `knowledge/dream-exclude' -- and no later
;; pass writes it again.  The pass keeps no copy of what it changed: a
;; page it wrote is read, corrected or removed in Logseq like any other,
;; and the graph's own history (`logseq/bak', or a graph under version
;; control) is the only record of the page before the change.

(defcustom harness-workspace-knowledge-dream-report t
  "Whether `knowledge/dream' writes a report page in the graph."
  :type 'boolean
  :group 'harness-workspace-knowledge)
(defcustom harness-workspace-knowledge-dream 'auto
  "Whether the graph maintains itself once a day.
`auto' runs `knowledge/dream' over every workspace at
`harness-workspace-knowledge-dream-hour', and catches up once on a start
that missed it; nil leaves the pass to a caller.  A dream that fails is
logged and tried again the next night."
  :type '(choice (const :tag "Once a day" auto)
                 (const :tag "Only on request" nil))
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-hour 3
  "Hour of the local day the nightly dream runs, 0 to 23."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-model nil
  "Model the dreaming synthesis is asked of, or nil for the workspace's own.
A judge is the simple tier of the workspace's model; naming a model here
asks that one instead, as PROVIDER:NAME."
  :type '(choice (const :tag "The workspace model's simple tier" nil)
                 (string :tag "Model" :names model))
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-batch 12
  "Most captures one dreaming synthesis reads."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-batches 2
  "Most synthesis requests one pass makes."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-captures 120
  "Most captures one pass considers, however much is waiting.
The rest waits for the next pass: a catch-up is bounded, not a way to
read a year of conversation in one call."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-recovery-days 7
  "Days before the last processed capture a pass still reads.
That is the window in which a capture edited after it was processed is
found again, by its id and the digest of its text."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-pages 12
  "Most maintained pages one synthesis request reads."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-page-blocks 16
  "Most blocks of a maintained page one synthesis request reads."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-capture-chars 2000
  "Most characters of one capture a synthesis request carries."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-full-chars 8000
  "Most characters of a fuller transcript a pass follows a clipped capture to."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-prompt-chars 30000
  "Most characters of captures and pages one synthesis request carries."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-index 12
  "Most pages the navigation index names."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-index-chars 1200
  "Most characters of the navigation index a brief carries."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-sources t
  "Whether a synthesized statement must name a source to be written.
A statement with no source among what the request carried is refused,
and the pass reports how many were."
  :type 'boolean
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-timeout 180
  "Seconds one synthesis request may take before it gives no answer."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-catch-up t
  "Whether a start catches up on a dream it missed while the harness was off.
The catch-up is one bounded pass over the workspaces still due, at most
`harness-workspace-knowledge-dream-catch-up-limit' of them."
  :type 'boolean
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-catch-up-limit 3
  "Most workspaces one startup catch-up dreams."
  :type 'integer
  :group 'harness-workspace-knowledge)

(defcustom harness-workspace-knowledge-dream-exclusions nil
  "Statements the user rejected; no pass writes one again.
`knowledge/dream-exclude' adds one, and a page or a block carries
`no-dream:: true' in the graph to be left out."
  :type '(repeat string)
  :group 'harness-workspace-knowledge)

(defconst harness-workspace-knowledge--dream-namespaces
  '("Projects/" "People/" "Topics/" "Decisions/" "Lessons/" "Questions/")
  "Page namespaces a pass maintains as synthesized knowledge.
A thread's page (`Threads/'), a day's journal and the report pages are
records, not synthesis, and are never rewritten by a pass.")

(defconst harness-workspace-knowledge--dream-preferences "Preferences"
  "The page a pass maintains for durable preferences, beside the namespaces.")

(defconst harness-workspace-knowledge--dream-index-prefix "Index/"
  "Namespace of the small navigation index a pass keeps.")

(defconst harness-workspace-knowledge--dream-kinds
  '("fact" "decision" "lesson" "question" "topic" "person" "project")
  "What a synthesized statement is about.")

(defconst harness-workspace-knowledge--dream-confidences
  '("confirmed" "inferred" "unresolved")
  "How a synthesized statement relates to its sources.")

(defconst harness-workspace-knowledge--dream-statement-chars 800
  "Most characters of one synthesized statement that is written.
A longer one is cut and says so: the statement is knowledge, not the
transcript it came from.")

(defvar harness-workspace-knowledge--running (make-hash-table :test 'equal)
  "Workspace ids whose dream is running, so two never overlap.")

;;;; The dream's state

(defun harness-workspace-knowledge--id (workspace)
  "Return WORKSPACE's id, from its plist or as the id itself."
  (if (listp workspace) (plist-get workspace :id) (format "%s" workspace)))

(defun harness-workspace-knowledge--state-file ()
  "Return the file that keeps every workspace's dream state."
  (expand-file-name "workspace-dreams.eld" harness-state-directory))

(defun harness-workspace-knowledge--state-all ()
  "Return the dream state of every workspace, an alist of id to plist.
A file written before the state was a plist holds the date of a
workspace's last dream, and is read as that."
  (let ((file (harness-workspace-knowledge--state-file)))
    (when (file-readable-p file)
      (condition-case err
          (let ((value (read (harness-read-file file))))
            (when (listp value)
              (delq nil
                    (mapcar (lambda (pair)
                              (when (consp pair)
                                (cons (format "%s" (car pair))
                                      (if (listp (cdr pair))
                                          (cdr pair)
                                        (list :last-date (cdr pair))))))
                            value))))
        (error
         (harness-log 'warn "workspace dream: unreadable state: %s"
                      (harness-error-message err))
         nil)))))

(defun harness-workspace-knowledge--state-write (all)
  "Write the dream state ALL."
  (let ((file (harness-workspace-knowledge--state-file)))
    (harness-ensure-directory (file-name-directory file))
    (harness-write-file-atomically
     file (prin1-to-string (sort (copy-sequence all)
                                 (lambda (a b) (string< (car a) (car b))))))))

(defun harness-workspace-knowledge--state (workspace)
  "Return WORKSPACE's dream state, a plist.
WORKSPACE is its plist or its id.  `:position' is the time captures are
processed up to, `:processed' the alist of capture id to the digest of
the text that was read, `:rejected' the statements the user rejected,
`:intent' the change a pass began and had not yet accounted for, and
`:last' the last pass."
  (or (cdr (assoc (harness-workspace-knowledge--id workspace)
                  (harness-workspace-knowledge--state-all)))
      (list :position 0)))

(defun harness-workspace-knowledge--state-save (workspace state)
  "Save STATE as WORKSPACE's dream state."
  (let* ((id (harness-workspace-knowledge--id workspace))
         (all (assoc-delete-all id (harness-workspace-knowledge--state-all))))
    (harness-workspace-knowledge--state-write (cons (cons id state) all))
    state))

(defun harness-workspace-knowledge--state-update (workspace fn)
  "Change WORKSPACE's dream state with FN, save it, and return the new state."
  (harness-workspace-knowledge--state-save
   workspace (funcall fn (harness-workspace-knowledge--state workspace))))

(defun harness-workspace-knowledge--dreams ()
  "Return the alist of workspace id to the date of its last dream."
  (delq nil
        (mapcar (lambda (pair)
                  (when-let* ((date (plist-get (cdr pair) :last-date)))
                    (cons (car pair) date)))
                (harness-workspace-knowledge--state-all))))

(defun harness-workspace-knowledge--dream-record (workspace date)
  "Record that WORKSPACE was dreamed on DATE."
  (harness-workspace-knowledge--state-update
   workspace (lambda (state) (plist-put state :last-date date))))

(defun harness-workspace-knowledge--true-p (value)
  "Non-nil when VALUE, a property's text, says true."
  (and value
       (not (member (downcase (format "%s" value)) '("" "false" "nil" "no" "0")))))

(defun harness-workspace-knowledge--rejected (workspace)
  "Return the statements WORKSPACE rejects, its state's and the option's."
  (delete-dups
   (append (mapcar #'harness-logseq--one-line
                   (append harness-workspace-knowledge-dream-exclusions nil))
           (mapcar #'harness-logseq--one-line
                   (append (plist-get (harness-workspace-knowledge--state workspace) :rejected)
                           nil)))))

(defun harness-workspace-knowledge--reject (workspace text &optional why)
  "Keep TEXT from being dreamed again in WORKSPACE, and say WHY.
Return TEXT as it was kept, or nil when it holds no words."
  (let ((line (harness-logseq--one-line (or text ""))))
    (unless (string-blank-p line)
      (harness-workspace-knowledge--state-update
       workspace
       (lambda (state)
         (let ((kept (plist-put state :rejected
                                (cons line
                                      (cl-remove-if
                                       (lambda (other)
                                         (equal (harness-logseq--one-line other) line))
                                       (append (plist-get state :rejected) nil))))))
           (when why (setq kept (plist-put kept :rejected-why why)))
           (plist-put kept :rejected-at (float-time)))))
      (harness-emit 'workspace/knowledge-changed
                    (harness-workspace-knowledge--id workspace)
                    (list :op 'excluded :text line))
      line)))

;;;; What a pass reads

(defun harness-workspace-knowledge--journal-pages (workspace)
  "Return (NAME . FILE) of the journal pages of WORKSPACE's graph."
  (let* ((root (harness-workspace-knowledge--root workspace))
         (pages (harness-call 'logseq/page-list (list :root root :limit 2000))))
    (delq nil (mapcar (lambda (page)
                        (when (plist-get page :journal)
                          (cons (plist-get page :name) (plist-get page :file))))
                      pages))))

(defun harness-workspace-knowledge--capture-blocks (workspace)
  "Return the captures of WORKSPACE from its journals, oldest first.
A capture is a block of a journal page this workspace wrote with a role
-- `user', `plan' or `assistant' -- and a link to its thread.  A note is
not a capture: it is already knowledge."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (wid (plist-get workspace :id))
         (out nil))
    (dolist (pair (harness-workspace-knowledge--journal-pages workspace))
      (let ((content (harness-read-file (cdr pair))))
        (when content
          (dolist (block (harness-logseq-content-blocks content))
            (let* ((result (harness-logseq-block-result block (car pair) nil (cdr pair)))
                   (properties (plist-get result :properties)))
              (when (and (equal wid (cdr (assoc "workspace-id" properties)))
                         (memq (plist-get result :role) '(user plan assistant))
                         (plist-get result :thread))
                (push (append result
                              (list :day (car pair)
                                    :clipped (harness-workspace-knowledge--true-p
                                              (cdr (assoc "capture-clipped" properties)))
                                    :session (cdr (assoc "source-session" properties))
                                    :node (cdr (assoc "source-node" properties))))
                      out)))))))
    (sort (nreverse out)
          (lambda (a b) (< (or (plist-get a :ts) 0) (or (plist-get b :ts) 0))))))

(defun harness-workspace-knowledge--capture-digest (capture)
  "Return the digest of CAPTURE's text, what a pass records when it read it."
  (harness-logseq-digest (or (plist-get capture :text) "")))

(defun harness-workspace-knowledge--pending-captures (workspace)
  "Return the captures of WORKSPACE a pass has not read, oldest first.
A capture is read once: its id and the digest of its text are kept, so
one edited after it was read is read again, and one older than the
recovery window waits until the window covers it."
  (let* ((state (harness-workspace-knowledge--state workspace))
         (processed (plist-get state :processed))
         (position (or (plist-get state :position) 0))
         (since (- position (* 86400 harness-workspace-knowledge-dream-recovery-days)))
         (out nil))
    (dolist (capture (harness-workspace-knowledge--capture-blocks workspace))
      (let ((ts (or (plist-get capture :ts) 0)))
        (unless (or (equal (harness-workspace-knowledge--capture-digest capture)
                           (cdr (assoc (plist-get capture :id) processed)))
                    (< ts since))
          (push capture out))))
    (seq-take (nreverse out) harness-workspace-knowledge-dream-captures)))

(defun harness-workspace-knowledge--capture-full (workspace capture)
  "Return CAPTURE's fuller transcript from its session, or nil.
A capture is clipped to what a journal block keeps; its session and node
are the way back to the whole text.  Only a session of the same
workspace is followed: another workspace's transcript is not this one's
to read."
  (when (and (plist-get capture :clipped)
             (plist-get capture :session)
             (plist-get capture :node)
             (harness-method-exists-p 'session/node)
             (harness-method-exists-p 'session/get))
    (condition-case err
        (let ((session (harness-call 'session/get (plist-get capture :session))))
          (when (and session
                     (equal (plist-get (plist-get session :ext) :workspace)
                            (plist-get workspace :id)))
            (let* ((node (harness-call 'session/node (plist-get capture :session)
                                       (plist-get capture :node)))
                   (text (and node (plist-get node :content))))
              (and (stringp text)
                   (not (string-blank-p text))
                   (harness-workspace-knowledge--clip-text
                    text harness-workspace-knowledge-dream-full-chars)))))
      (error
       (harness-log 'warn "workspace dream: cannot follow %s: %s"
                    (plist-get capture :node) (harness-error-message err))
       nil))))

;;;; What a pass maintains

(defun harness-workspace-knowledge--clip-text (text chars)
  "Return TEXT cut to CHARS characters, saying so when it is cut."
  (let ((text (or text "")))
    (if (<= (length text) chars)
        text
      (concat (harness-truncate-end text (max 1 (1- chars))) "…"))))

(defun harness-workspace-knowledge--dream-page-p (name)
  "Non-nil when NAME is a page a pass maintains."
  (or (equal name harness-workspace-knowledge--dream-preferences)
      (cl-some (lambda (prefix) (string-prefix-p prefix name))
               harness-workspace-knowledge--dream-namespaces)))

(defun harness-workspace-knowledge--page-properties (page root)
  "Return PAGE's identity properties in the graph at ROOT, or nil."
  (plist-get (harness-call 'logseq/page page (list :root root)) :properties))

(defun harness-workspace-knowledge--page-owner (page root)
  "Return the workspace id PAGE in the graph at ROOT says it belongs to."
  (cdr (assoc "workspace-id" (harness-workspace-knowledge--page-properties page root))))

(defun harness-workspace-knowledge--page-marked (page root)
  "Non-nil when PAGE in the graph at ROOT carries `no-dream:: true'."
  (harness-workspace-knowledge--true-p
   (cdr (assoc "no-dream" (harness-workspace-knowledge--page-properties page root)))))

(defun harness-workspace-knowledge--page-blocks (page root)
  "Return PAGE's content blocks in the graph at ROOT, oldest first."
  (let ((data (harness-call 'logseq/page page (list :root root))))
    (and data
         (harness-logseq-content-blocks
          (or (harness-read-file (plist-get data :file)) "")))))

(defun harness-workspace-knowledge--page-block-ids (page root)
  "Return the ids of PAGE's content blocks in the graph at ROOT."
  (mapcar (lambda (block) (harness-logseq--block-id block page))
          (harness-workspace-knowledge--page-blocks page root)))

(defun harness-workspace-knowledge--maintained-pages (workspace)
  "Return the pages of WORKSPACE's graph a pass maintains, newest first.
That is a page in one of the maintained namespaces whose identity says
it is this workspace's, and which is not marked `no-dream'."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (wid (plist-get workspace :id))
         (out nil))
    (dolist (page (harness-call 'logseq/page-list (list :root root :limit 1000)))
      (let ((name (plist-get page :name)))
        (when (and (not (plist-get page :journal))
                   (harness-workspace-knowledge--dream-page-p name))
          (let ((properties (harness-workspace-knowledge--page-properties name root)))
            (when (and (equal wid (cdr (assoc "workspace-id" properties)))
                       (not (harness-workspace-knowledge--true-p
                             (cdr (assoc "no-dream" properties)))))
              (push (list :name name
                          :about (cdr (assoc "dream-about" properties))
                          :updated (plist-get page :updated)
                          :blocks (harness-workspace-knowledge--page-blocks name root))
                    out))))))
    (sort (nreverse out)
          (lambda (a b) (> (or (plist-get a :updated) 0)
                           (or (plist-get b :updated) 0))))))

(defun harness-workspace-knowledge--index-page-name (workspace)
  "Return the name of WORKSPACE's navigation index page."
  (concat harness-workspace-knowledge--dream-index-prefix
          (harness-workspace-knowledge--name workspace)))

(defun harness-workspace-knowledge--index-lines (workspace)
  "Return the navigation index of WORKSPACE as the lines it holds now."
  (let ((root (harness-workspace-knowledge--root workspace)))
    (mapcar (lambda (block) (harness-logseq--one-line (plist-get block :text)))
            (harness-workspace-knowledge--page-blocks
             (harness-workspace-knowledge--index-page-name workspace) root))))

(defun harness-workspace-knowledge--index (workspace)
  "Return WORKSPACE's navigation index as text, or nil when it has none.
WORKSPACE is its plist or its id, as a caller of `knowledge/index' has it."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (lines (harness-workspace-knowledge--index-lines workspace)))
    (when lines
      (harness-workspace-knowledge--clip-text
       (mapconcat #'identity lines "\n")
       harness-workspace-knowledge-dream-index-chars))))

;;;; Asking for a synthesis

(defun harness-workspace-knowledge--dream-model (workspace)
  "Return the model WORKSPACE's synthesis is asked of, or nil for its tier."
  (or harness-workspace-knowledge-dream-model
      (plist-get workspace :model)))

(defun harness-workspace-knowledge--window (captures)
  "Return the days CAPTURES were made on, as one line."
  (let ((days (delete-dups (delq nil (mapcar (lambda (capture)
                                               (plist-get capture :day))
                                             captures)))))
    (cond ((null days) "-")
          ((= 1 (length days)) (car days))
          (t (format "%s to %s" (car (last days)) (car days))))))

(defun harness-workspace-knowledge--capture-entry (capture alias &optional full)
  "Return CAPTURE, as ALIAS, as the entry a synthesis request carries.
FULL is the capture's fuller transcript, when a pass followed a
clipped capture back to it."
  (let* ((clipped (harness-workspace-knowledge--clip-text
                   (plist-get capture :text)
                   harness-workspace-knowledge-dream-capture-chars))
         (text (or full clipped))
         (role (or (plist-get capture :role) 'user)))
    (format "%s | %s | %s | %s\n%s%s"
            alias role
            (or (plist-get capture :thread) "-")
            (or (plist-get capture :day) "-")
            (mapconcat (lambda (line) (concat "  " line))
                       (split-string text "\n") "\n")
            (if (and full (not (equal full clipped)))
                (format "\n  (the journal holds the first %d characters)"
                        (length clipped))
              ""))))

(defun harness-workspace-knowledge--page-entry (page)
  "Return PAGE, a maintained page, as the entry a synthesis request carries."
  (let* ((about (plist-get page :about))
         (name (plist-get page :name))
         (blocks (seq-take (plist-get page :blocks)
                           harness-workspace-knowledge-dream-page-blocks)))
    (concat (format "## [[%s]]%s" name
                    (if (and about (not (string-blank-p about)))
                        (format " -- %s" about)
                      ""))
            (when blocks
              (concat
               "\n"
               (mapconcat
                (lambda (block)
                  (let ((properties (plist-get block :properties)))
                    (format "- %s | %s | %s | %s | %s"
                            (harness-logseq--block-id block name)
                            (or (cdr (assoc "dream-kind" properties)) "note")
                            (or (cdr (assoc "dream-confidence" properties)) "confirmed")
                            (or (cdr (assoc "sources" properties)) "-")
                            (harness-workspace-knowledge--clip-text
                             (harness-logseq--one-line (plist-get block :text)) 400))))
                blocks "\n"))))))

(defun harness-workspace-knowledge--fit (entries budget)
  "Return ENTRIES that fit BUDGET characters, in order."
  (let ((out nil) (left budget))
    (dolist (entry entries)
      (when (>= left (length entry))
        (push entry out)
        (setq left (- left (length entry) 2))))
    (nreverse out)))

(defun harness-workspace-knowledge--request (workspace captures aliases)
  "Return (:system SYSTEM :prompt PROMPT) for CAPTURES of WORKSPACE.
ALIASES maps each capture's id to the name the model is given."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (model (harness-workspace-knowledge--dream-model workspace))
         (budget harness-workspace-knowledge-dream-prompt-chars)
         (capture-text
          (mapconcat #'identity
                     (harness-workspace-knowledge--fit
                      (mapcar (lambda (capture)
                                (harness-workspace-knowledge--capture-entry
                                 capture (cdr (assoc (plist-get capture :id) aliases))
                                 ;; A clipped capture is followed back to
                                 ;; its own session for what the journal
                                 ;; could not keep.
                                 (harness-workspace-knowledge--capture-full
                                  workspace capture)))
                              captures)
                      budget)
                     "\n\n"))
         (pages (harness-workspace-knowledge--fit
                 (mapcar #'harness-workspace-knowledge--page-entry
                         (seq-take (harness-workspace-knowledge--maintained-pages workspace)
                                   harness-workspace-knowledge-dream-pages))
                 (max 2000 (/ budget 2))))
         (variables (list :workspace (harness-workspace-knowledge--name workspace)
                          :window (harness-workspace-knowledge--window captures)
                          :captures capture-text
                          :pages (or (mapconcat #'identity pages "\n\n") "(none yet)")
                          :index (or (harness-workspace-knowledge--index workspace)
                                     "(none yet)")
                          :excluded (or (mapconcat #'identity
                                                   (harness-workspace-knowledge--rejected workspace)
                                                   "\n")
                                        "(none)"))))
    (list :system (harness-prompt 'workspace-dream-system nil model)
          :prompt (harness-prompt 'workspace-dream-request variables model))))

(defun harness-workspace-knowledge--parse-plan (text)
  "Return the JSON object TEXT holds as a plan, or nil.
A model may wrap its answer in a code fence or a sentence; the first
object between a { and the last } is read."
  (let* ((text (and (stringp text) (string-trim text)))
         (start (and text (string-match "{" text)))
         (end (and start (string-match "}[^}]*\\'" text))))
    (when (and start end)
      (condition-case nil
          (let ((value (harness-json-parse (substring text start (1+ end)))))
            (and (listp value) value))
        (error nil)))))

;;;; Reading a plan

;; A plan is the model's answer, checked against the graph before any of
;; it is written.  A page it names must be one this workspace maintains:
;; in a maintained namespace, or the preferences page, and either the
;; page it owns or a page that does not exist yet.  A statement must have
;; words, must not be one the user rejected, and -- unless
;; `harness-workspace-knowledge-dream-sources' is off -- must cite a
;; capture of the batch or a block of a page it was given.  What does not
;; pass is dropped and counted, so a pass reports what it refused rather
;; than writing it.

(defun harness-workspace-knowledge--plan-pages (plan)
  "Return PLAN's page entries, each a plist, or nil."
  (let ((pages (and (listp plan) (plist-get plan :pages))))
    (and (listp pages) (listp (car pages)) pages)))

(defun harness-workspace-knowledge--plan-strings (value)
  "Return VALUE, as a model may give it, as a list of strings."
  (cond ((null value) nil)
        ((stringp value) (and (not (string-blank-p value)) (list value)))
        ((symbolp value) (list (format "%s" value)))
        ((listp value)
         (delq nil (mapcar (lambda (item)
                             (cond ((stringp item)
                                    (and (not (string-blank-p item)) item))
                                   ((and (symbolp item) item) (format "%s" item))
                                   (t nil)))
                           value)))
        (t nil)))

(defun harness-workspace-knowledge--plan-page-name (entry)
  "Return the page name ENTRY names, cleaned, or nil."
  (let ((name (and (listp entry) (plist-get entry :page))))
    (when (and (stringp name) (not (string-blank-p name)))
      (harness-logseq-page-name name))))

(defun harness-workspace-knowledge--plan-about (entry)
  "Return the one line ENTRY says its page is about, or nil."
  (let ((about (and (listp entry) (plist-get entry :about))))
    (when (and (stringp about) (not (string-blank-p about)))
      (harness-workspace-knowledge--clip-text
       (harness-logseq--one-line about) 200))))

(defun harness-workspace-knowledge--plan-block (block page-name)
  "Return BLOCK as a statement plist, or nil when it has no words.
The text is one line, since a statement is knowledge rather than the
transcript it came from, and is cut to the most one statement keeps."
  (let ((text (and (listp block) (plist-get block :text))))
    (when (and (stringp text) (not (string-blank-p text)))
      (let* ((kind (format "%s" (or (plist-get block :kind) "fact")))
             (confidence (format "%s" (or (plist-get block :confidence) "confirmed")))
             (id (plist-get block :id)))
        (list :page page-name
              :id (and (stringp id) (not (string-blank-p id)) id)
              :text (harness-workspace-knowledge--clip-text
                     (harness-logseq--one-line text)
                     harness-workspace-knowledge--dream-statement-chars)
              :kind (if (member kind harness-workspace-knowledge--dream-kinds) kind "fact")
              :confidence (if (member confidence harness-workspace-knowledge--dream-confidences)
                              confidence "confirmed")
              :sources (harness-workspace-knowledge--plan-strings
                        (plist-get block :sources)))))))

(defun harness-workspace-knowledge--plan-sourced-p (statement aliases block-ids)
  "Non-nil when STATEMENT cites a capture of ALIASES or a block of BLOCK-IDS.
ALIASES is the list of the names the batch's captures were given."
  (cl-some (lambda (source)
             (or (member source aliases) (member source block-ids)))
           (plist-get statement :sources)))

(defun harness-workspace-knowledge--plan-reason (workspace name root)
  "Return why WORKSPACE may not write NAME in the graph at ROOT, or nil."
  (let ((owner (harness-workspace-knowledge--page-owner name root)))
    (cond
     ((not (harness-workspace-knowledge--dream-page-p name))
      (format "%s is outside the pages a pass maintains" name))
     ((and owner (not (equal owner (plist-get workspace :id))))
      (format "%s belongs to another workspace" name))
     ((harness-workspace-knowledge--page-marked name root)
      (format "%s says no-dream" name))
     (t nil))))

(defun harness-workspace-knowledge--plan-statements (workspace entry name known)
  "Return (STATEMENTS . REFUSED) for ENTRY of page NAME in WORKSPACE.
KNOWN is the aliases of the batch and the block ids the request carried;
REFUSED is what the entry asked for and may not have."
  (let ((rejected (harness-workspace-knowledge--rejected workspace))
        (blocks (let ((value (and (listp entry) (plist-get entry :blocks))))
                  (and (listp value) value)))
        (statements nil) (refused nil))
    (dolist (raw blocks)
      (let ((statement (harness-workspace-knowledge--plan-block raw name)))
        (cond
         ((null statement) nil)
         ((member (plist-get statement :text) rejected)
          (push "a statement the user rejected" refused))
         ((and harness-workspace-knowledge-dream-sources
               (not (harness-workspace-knowledge--plan-sourced-p
                     statement (plist-get known :aliases) (plist-get known :blocks))))
          (push "a statement citing no source it was given" refused))
         (t (push statement statements)))))
    (cons (nreverse statements) (nreverse refused))))

(defun harness-workspace-knowledge--plan-drops (workspace entry name root)
  "Return (DROP . REFUSED) for ENTRY's blocks to drop from NAME in WORKSPACE."
  (ignore workspace)
  (let ((ids (harness-workspace-knowledge--page-block-ids name root))
        (drop nil) (refused nil))
    (dolist (id (harness-workspace-knowledge--plan-strings (plist-get entry :drop)))
      (if (member id ids)
          (push id drop)
        (push (format "a block %s that is not on %s" id name) refused)))
    (cons (nreverse drop) (nreverse refused))))

(defun harness-workspace-knowledge--check-plan (workspace plan captures aliases)
  "Return PLAN of WORKSPACE as the pages it may write, or nil.
CAPTURES is the batch, and ALIASES maps each capture's id to the name
the model was given.  The answer is (:pages ((:page :about :blocks
:drop) ...) :refused N :reasons (...)), or nil when nothing in PLAN may
be written."
  (ignore captures)
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (entries (harness-workspace-knowledge--plan-pages plan))
         (known nil)
         (pages nil)
         (reasons nil))
    ;; A statement may cite a block of any page the request carried, so
    ;; the blocks of every page are known before any page is checked.
    (dolist (entry entries)
      (when-let* ((name (harness-workspace-knowledge--plan-page-name entry)))
        (setq known (append (harness-workspace-knowledge--page-block-ids name root)
                            known))))
    (setq known (list :aliases (mapcar #'cdr aliases) :blocks known))
    (dolist (entry entries)
      (let* ((name (harness-workspace-knowledge--plan-page-name entry))
             (reason (and name (harness-workspace-knowledge--plan-reason
                                workspace name root))))
        (if (or (null name) reason)
            (push (or reason "a page with no name") reasons)
          (let* ((statements (harness-workspace-knowledge--plan-statements
                              workspace entry name known))
                 (drops (harness-workspace-knowledge--plan-drops
                         workspace entry name root))
                 (blocks (car statements))
                 (drop (car drops)))
            (setq reasons (append (cdr statements) (cdr drops) reasons))
            (when (or blocks drop)
              (push (list :page name
                          :about (harness-workspace-knowledge--plan-about entry)
                          :blocks blocks
                          :drop drop)
                    pages))))))
    (when (or pages reasons)
      (list :pages (nreverse pages)
            :refused (length reasons)
            :reasons (delete-dups (nreverse reasons))))))

;;;; Writing a plan

(defun harness-workspace-knowledge--sources-text (sources captures)
  "Return SOURCES as the property text a block keeps.
A capture is cited as the block reference Logseq makes of its id, so the
block links back to what it was made of; a block id is one already."
  (let ((ids (delq nil (mapcar (lambda (source)
                                 (or (cdr (assoc source captures)) source))
                               sources))))
    (and ids (mapconcat (lambda (id) (format "((%s))" id)) ids " "))))

(defun harness-workspace-knowledge--statement-properties (workspace statement captures)
  "Return the properties of WORKSPACE's block for STATEMENT.
CAPTURES maps a capture's alias to its id, the way a block cites it."
  (append
   (list (cons "workspace" (harness-workspace-knowledge--name workspace))
         (cons "workspace-id" (plist-get workspace :id))
         (cons "role" "note")
         (cons "dream" "synth")
         (cons "dream-kind" (plist-get statement :kind))
         (cons "dream-confidence" (plist-get statement :confidence)))
   (when-let* ((sources (harness-workspace-knowledge--sources-text
                         (plist-get statement :sources) captures)))
     (list (cons "sources" sources)))))

(defun harness-workspace-knowledge--page-operations (workspace plan aliases)
  "Return the `logseq/page-edit' options that write PLAN for one page.
ALIASES maps a capture's alias to its id, the way a block cites it."
  (let* ((root (harness-workspace-knowledge--root workspace))
         (page (plist-get plan :page))
         (ids (harness-workspace-knowledge--page-block-ids page root))
         (remove (cl-remove-if-not (lambda (id) (member id ids)) (plist-get plan :drop)))
         (replace nil) (append nil))
    (dolist (statement (plist-get plan :blocks))
      (let ((id (plist-get statement :id)))
        (cond
         ((and id (member id ids))
          (push (cons id (plist-get statement :text)) replace))
         (t
          (push (list :text (plist-get statement :text)
                      :properties (harness-workspace-knowledge--statement-properties
                                   workspace statement aliases))
                append)))))
    (list :root root
          :remove remove
          :replace (nreverse replace)
          :append (nreverse append)
          :set (append
                (list (cons "workspace" (harness-workspace-knowledge--name workspace))
                      (cons "workspace-id" (plist-get workspace :id))
                      (cons "dreamed-at" (format-time-string "%Y-%m-%d %H:%M")))
                (when-let* ((about (plist-get plan :about)))
                  (list (cons "dream-about" about)))))))

(defun harness-workspace-knowledge--apply-page (workspace plan aliases &optional retried)
  "Write PLAN for one page of WORKSPACE, recomputing once on a conflict.
The page is read for its digest and written only while it is still the
page that was read: a change made in between signals `harness-conflict',
and the plan is worked out again against the page as it now is.  ALIASES
maps a capture's alias to its id.  Return what was written, or
\(:page PAGE :error WHY)."
  (let* ((root (harness-workspace-knowledge--root workspace))
         (page (plist-get plan :page))
         (digest (harness-logseq-page-digest page root)))
    (condition-case err
        (let ((result (harness-call
                       'logseq/page-edit page
                       (append (harness-workspace-knowledge--page-operations
                                workspace plan aliases)
                               (list :create t
                                     :expect (or digest 'absent))))))
          (list :page page
                :digest (plist-get result :digest)
                :added (mapcar (lambda (statement) (plist-get statement :text))
                               (plist-get plan :blocks))
                :removed (plist-get result :removed)))
      (harness-conflict
       (if retried
           (list :page page :error "changed while it was written")
         (harness-log 'info "workspace dream: %s changed while it was written; recomputing" page)
         (harness-workspace-knowledge--apply-page workspace plan aliases t)))
      (error
       (list :page page :error (harness-error-message err))))))

(defun harness-workspace-knowledge--index-wanted (workspace)
  "Return the lines WORKSPACE's navigation index calls for."
  (let ((pages (harness-workspace-knowledge--maintained-pages workspace)))
    (seq-take
     (mapcar (lambda (page)
               (let ((about (plist-get page :about))
                     (first (harness-workspace-knowledge--first-line page)))
                 (format "[[%s]] -- %s"
                         (plist-get page :name)
                         (cond ((and about (not (string-blank-p about))) about)
                               (first first)
                               (t "knowledge")))))
             pages)
     harness-workspace-knowledge-dream-index)))

(defun harness-workspace-knowledge--refresh-index (workspace)
  "Bring WORKSPACE's navigation index up to date.
The index is regenerated only when its lines changed, so a pass that
changed nothing writes nothing.  Return what was written, or nil."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (page (harness-workspace-knowledge--index-page-name workspace))
         (wanted (harness-workspace-knowledge--index-wanted workspace))
         (current (harness-workspace-knowledge--index-lines workspace))
         (digest (harness-logseq-page-digest page root)))
    (unless (equal wanted current)
      (let* ((blocks (harness-workspace-knowledge--page-blocks page root))
             (remove (mapcar (lambda (block) (harness-logseq--block-id block page)) blocks))
             (result (harness-call
                      'logseq/page-edit page
                      (list :root root :create t
                            :expect (or digest 'absent)
                            :remove remove
                            :set (list (cons "workspace" (harness-workspace-knowledge--name workspace))
                                       (cons "workspace-id" (plist-get workspace :id))
                                       (cons "dream-index" "true"))
                            :append (mapcar
                                     (lambda (line)
                                       (list :text line
                                             :properties
                                             (list (cons "workspace" (harness-workspace-knowledge--name workspace))
                                                   (cons "workspace-id" (plist-get workspace :id))
                                                   (cons "role" "note")
                                                   (cons "dream" "index"))))
                                     wanted)))))
        (list :page page
              :digest (plist-get result :digest)
              :added wanted
              :removed (plist-get result :removed))))))

;;;; What a pass keeps

(defun harness-workspace-knowledge--first-line (page)
  "Return PAGE's first block as one line, or nil."
  (when-let* ((block (car (plist-get page :blocks))))
    (let ((text (harness-logseq--one-line (or (plist-get block :text) ""))))
      (unless (string-blank-p text)
        (harness-workspace-knowledge--clip-text text 120)))))



;;;; The pass

(defun harness-workspace-knowledge--note-blocks (blocks workspace-id)
  "Return the durable notes in BLOCKS that WORKSPACE-ID wrote.
A note is a block with `role:: note' whose workspace id is this
workspace's.  A capture in the journal is not a maintenance candidate,
and neither is another workspace's block; a block the user wrote on this
workspace's page is, since a page the user edits stays the pass's."
  (cl-remove-if-not
   (lambda (block)
     (let ((properties (plist-get block :properties)))
       (and (equal "note" (cdr (assoc "role" properties)))
            (equal workspace-id (cdr (assoc "workspace-id" properties))))))
   blocks))

(defun harness-workspace-knowledge--duplicates (blocks workspace-id)
  "Return the later of the notes in BLOCKS whose text repeats an earlier one.
Only WORKSPACE-ID's own notes are compared, so a page that holds two
workspaces' notes never has one workspace's note taken for the other's."
  (let ((seen (make-hash-table :test 'equal))
        (duplicates nil))
    (dolist (block (harness-workspace-knowledge--note-blocks blocks workspace-id))
      (let ((text (harness-logseq--one-line (or (plist-get block :text) ""))))
        (unless (string-blank-p text)
          (if (gethash text seen)
              (push block duplicates)
            (puthash text t seen)))))
    (nreverse duplicates)))

(defun harness-workspace-knowledge--dedupe (workspace pages dry)
  "Keep WORKSPACE's note once on each page of PAGES.
The first copy stays and the later ones go, their children lifted into
their place, so a duplicate parent never takes distinct knowledge with
it.  With DRY nothing is written.  Return (:removed N :lines (...) :pages
(RESULT ...))."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (wid (plist-get workspace :id))
         (root (harness-workspace-knowledge--root workspace))
         (removed 0) (lines nil) (results nil))
    (dolist (page pages)
      (let* ((blocks (harness-workspace-knowledge--page-blocks page root))
             (duplicates (harness-workspace-knowledge--duplicates blocks wid)))
        (when duplicates
          (let* ((ids (mapcar (lambda (block) (harness-logseq--block-id block page))
                              duplicates))
                 (result (unless dry
                           (condition-case err
                               (harness-call 'logseq/page-edit page
                                             (list :root root :remove ids))
                             (error
                              (harness-log 'warn "workspace dream: %s: %s"
                                           page (harness-error-message err))
                              nil)))))
            (cl-incf removed (length ids))
            (push (format "%s: %s %s"
                          page
                          (if dry "would remove" "removed")
                          (if (= 1 (length ids))
                              "a duplicate note"
                            (format "%d duplicate notes" (length ids))))
                  lines)
            (when result (push result results))))))
    (list :removed removed :lines (nreverse lines) :pages (nreverse results))))

(defun harness-workspace-knowledge--thread-pages (workspace)
  "Return the pages of WORKSPACE's threads that are still open."
  (let ((workspace (harness-workspace-knowledge--workspace workspace))
        (pages nil))
    (dolist (thread (plist-get workspace :threads))
      (unless (equal (format "%s" (plist-get thread :status)) "merged")
        (push (harness-workspace-knowledge--thread-page workspace thread) pages)))
    (nreverse pages)))

(defun harness-workspace-knowledge--touch-threads (workspace)
  "Bring every open thread page of WORKSPACE up to date; return the count."
  (let ((workspace (harness-workspace-knowledge--workspace workspace))
        (count 0))
    (dolist (thread (plist-get workspace :threads))
      (unless (equal (format "%s" (plist-get thread :status)) "merged")
        (condition-case err
            (progn
              (harness-call 'knowledge/thread-touch
                            (plist-get workspace :id) (plist-get thread :id)
                            (plist-get thread :status))
              (cl-incf count))
          (error
           (harness-log 'warn "workspace dream: thread %s: %s"
                        (plist-get thread :id) (harness-error-message err))))))
    count))

(defun harness-workspace-knowledge--report-line (workspace status sources changes)
  "Return the line a report page keeps for a pass of WORKSPACE."
  (format "Dream over %s: %s, %d source%s, %s"
          (harness-workspace-knowledge--name workspace)
          status sources (if (= 1 sources) "" "s")
          (if changes (mapconcat #'identity changes "; ") "no change")))

(defun harness-workspace-knowledge--report-page (workspace lines)
  "Write LINES to WORKSPACE's report page of today, and return its name."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (page (harness-logseq-page-name
                (concat "Dreams/" (format-time-string "%Y-%m-%d")))))
    (dolist (line lines)
      (harness-call 'logseq/block-add page line
                    (list :root root
                          :properties
                          (list (cons "workspace" (harness-workspace-knowledge--name workspace))
                                (cons "workspace-id" (plist-get workspace :id))
                                (cons "dreamed-at" (format-time-string "%Y-%m-%d %H:%M"))))))
    page))

(defun harness-workspace-knowledge--batches (captures)
  "Return CAPTURES in the batches a pass reads, oldest first."
  (let ((size (max 1 harness-workspace-knowledge-dream-batch))
        (out nil) (rest captures))
    (while rest
      (push (seq-take rest size) out)
      (setq rest (seq-drop rest size)))
    (nreverse out)))

(defun harness-workspace-knowledge--batch-aliases (batch)
  "Return the alist of capture id to the name a model is given for BATCH.
A capture is cited by a short name, `c-1', `c-2', ..., so a model reads
and answers with an id it can keep apart from a block id."
  (let ((n 0))
    (mapcar (lambda (capture)
              (cl-incf n)
              (cons (plist-get capture :id) (format "c-%d" n)))
            batch)))

(defun harness-workspace-knowledge--alias-map (aliases)
  "Return ALIASES as capture alias to id, the way a block cites a capture."
  (mapcar (lambda (pair) (cons (cdr pair) (car pair))) aliases))

(defun harness-workspace-knowledge--intent (workspace plans captures)
  "Return the intent of a pass of WORKSPACE over PLANS and CAPTURES.
It says what the pass is about to write, so a run that stopped between
its saves and its bookkeeping is reconciled by the next one."
  (ignore workspace)
  (list :at (float-time)
        :captures captures
        :pages (mapcar (lambda (plan)
                         (list :page (plist-get plan :page)
                               :texts (mapcar (lambda (statement)
                                                (plist-get statement :text))
                                              (plist-get plan :blocks))))
                       plans)))

(defun harness-workspace-knowledge--mark-processed (state captures at)
  "Return STATE with CAPTURES read at AT.
A capture's id is kept with the digest of the text that was read, so the
same words are not read again and edited ones are."
  (let ((processed (append (plist-get state :processed) nil)))
    (dolist (capture captures)
      (setq processed
            (cons (cons (plist-get capture :id)
                        (harness-workspace-knowledge--capture-digest capture))
                  (cl-remove-if (lambda (pair)
                                  (equal (car pair) (plist-get capture :id)))
                                processed))))
    (setq state (plist-put state :processed processed))
    (when at (setq state (plist-put state :position at)))
    state))

(defun harness-workspace-knowledge--reconcile (workspace)
  "Settle the intent of a pass of WORKSPACE that stopped before its bookkeeping.
A pass writes what it is about to do, then does it, then marks the
captures processed.  One that stopped in between leaves its intent
behind; the pages it planned are read, and a batch whose every page
holds what was planned is taken as written: the captures are marked
processed and the next pass does not write them again.  An intent whose
pages are not there is forgotten, and its captures are read afresh."
  (let ((intent (plist-get (harness-workspace-knowledge--state workspace) :intent)))
    (when intent
      (let* ((root (harness-workspace-knowledge--root workspace))
             (captures (plist-get intent :captures))
             (pages (plist-get intent :pages))
             (saved
              (and pages
                   (cl-every
                    (lambda (page)
                      (let* ((name (plist-get page :page))
                             (texts (plist-get page :texts))
                             (wanted (mapcar (lambda (block)
                                               (harness-logseq--one-line
                                                (or (plist-get block :text) "")))
                                             (harness-workspace-knowledge--page-blocks
                                              name root))))
                        (cl-every (lambda (text)
                                    (member (harness-logseq--one-line text) wanted))
                                  texts)))
                    pages))))
        (harness-log 'info "workspace dream: %s the intent of %s"
                     (if saved "reconciled" "forgot") (plist-get intent :at))
        (harness-workspace-knowledge--state-update
         workspace
         (lambda (state)
           (if saved
               (harness-workspace-knowledge--mark-processed
                (plist-put state :intent nil) captures (plist-get intent :at))
             (plist-put state :intent nil))))
        (when saved
          (list :reconciled t :captures (length captures)))))))

(defun harness-workspace-knowledge--synthesize (workspace captures aliases)
  "Return a promise of the plan a judge makes of CAPTURES for WORKSPACE.
ALIASES maps each capture's id to the name the model is given.  The
answer is (:plan PLAN :refused N :reasons (...) :reason WHY), where WHY
says why there is no plan."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (model (harness-workspace-knowledge--dream-model workspace))
         (request (harness-workspace-knowledge--request workspace captures aliases))
         (session (list :id (format "workspace-dream-%s"
                                    (harness-workspace-knowledge--id workspace))
                        :cwd (or (plist-get workspace :root) default-directory)
                        :model model)))
    (if (not (require 'harness-judge nil t))
        (harness-resolved (list :reason "the judge module is not available"))
      (harness-then
       (harness-judge-ask
        :session session
        :model model
        :system (plist-get request :system)
        :prompt (plist-get request :prompt)
        :max-tokens 3000
        :retry-max-tokens 6000
        :timeout harness-workspace-knowledge-dream-timeout
        :label (format "workspace dream %s" (harness-workspace-knowledge--id workspace))
        :job "Workspace dream"
        :parse #'harness-workspace-knowledge--parse-plan
        :prompts '(workspace-dream-system workspace-dream-request))
       (lambda (answer)
         (let ((value (plist-get answer :value)))
           (if (null value)
               (list :reason (or (plist-get answer :reason) "the judge gave no answer"))
             (let ((checked (harness-workspace-knowledge--check-plan
                             workspace value captures aliases)))
               ;; A plan is what may be written; an answer whose every
               ;; entry was refused has none, and says what it refused.
               (if (and checked (plist-get checked :pages))
                   (list :plan checked
                         :refused (plist-get checked :refused)
                         :reasons (plist-get checked :reasons))
                 (list :reason (if checked
                                   "nothing in the answer could be written"
                                 "the answer named no page a pass maintains")
                       :refused (or (plist-get checked :refused) 0)
                       :reasons (plist-get checked :reasons)))))))))))

(defun harness-workspace-knowledge--synthesize-batch (workspace batch aliases state)
  "Return a promise of one synthesis of BATCH for WORKSPACE.
A plan that may write is written page by page; only when every page of
it was written are the batch's captures marked processed.  ALIASES maps
a capture's id to the name the model was given, and the answer's page
results go on STATE's `:done'."
  (harness-then
   (harness-workspace-knowledge--synthesize workspace batch aliases)
   (lambda (answer)
     (let ((plan (plist-get answer :plan)))
       (cond
        ((null plan)
         (when (plist-get answer :reason)
           (harness-log 'info "workspace dream: %s" (plist-get answer :reason)))
         ;; Nothing was written, but what the answer asked for and
         ;; may not have is still reported.
         (setf (plist-get state :done)
               (append (plist-get state :done)
                       (list (list :results nil
                                   :refused (plist-get answer :refused)
                                   :reasons (plist-get answer :reasons)
                                   :sources 0))))
         (list :status 'no-plan :reason (plist-get answer :reason)
               :refused (plist-get answer :refused)
               :reasons (plist-get answer :reasons)))
        (t
         ;; What is about to be written is recorded before it is, so a
         ;; run that stops here is reconciled by the next one.
         (harness-workspace-knowledge--state-update
          workspace
          (lambda (state)
            (plist-put state :intent
                       (harness-workspace-knowledge--intent
                        workspace (plist-get plan :pages) batch))))
         (let* ((results
                 (mapcar (lambda (page)
                           (harness-workspace-knowledge--apply-page
                            workspace page
                            (harness-workspace-knowledge--alias-map aliases)))
                         (plist-get plan :pages)))
                (failed (cl-remove-if-not (lambda (result) (plist-get result :error))
                                          results))
                (written (cl-remove-if (lambda (result) (plist-get result :error))
                                       results)))
           ;; The index is regenerated after the pages it lists, so a
           ;; batch that wrote nothing does not refresh it.
           (when written
             (harness-workspace-knowledge--refresh-index workspace))
           (if failed
               (progn
                 (harness-log 'warn "workspace dream: %d page(s) not written: %s"
                              (length failed)
                              (mapconcat (lambda (result)
                                           (format "%s: %s" (plist-get result :page)
                                                   (plist-get result :error)))
                                         failed "; "))
                 ;; What was saved is reported with what could not
                 ;; be, and the batch stays unread.
                 (setf (plist-get state :done)
                       (append (plist-get state :done)
                               (list (list :results written
                                           :refused (plist-get answer :refused)
                                           :reasons (plist-get answer :reasons)
                                           :sources 0))))
                 (list :status 'partial :failed failed
                       :refused (plist-get answer :refused)
                       :reasons (plist-get answer :reasons)))
             (harness-workspace-knowledge--state-update
              workspace
              (lambda (state)
                (harness-workspace-knowledge--mark-processed
                 (plist-put state :intent nil)
                 batch (or (plist-get (car (last batch)) :ts) (float-time)))))
             (setf (plist-get state :done)
                   (append (plist-get state :done)
                           (list (list :results written
                                       :refused (plist-get answer :refused)
                                       :reasons (plist-get answer :reasons)
                                       :sources (length batch)))))
             (list :status 'completed)))))))))

(defun harness-workspace-knowledge--synthesize-batches (workspace batches state)
  "Return a promise of what the batches did, one request at a time.
STATE's `:done' collects the page results, so a batch that gave no plan
does not lose the ones before it, and STATE's `:outcome' the worst
outcome: `partial' when a page could not be written, `no-plan' when the
model's answer was not written, `completed' when every batch was."
  (if (null batches)
      (harness-resolved (list :status (or (plist-get state :outcome) 'completed)
                              :reason (plist-get state :reason)))
    (harness-then
     (harness-workspace-knowledge--synthesize-batch
      workspace (car batches) (harness-workspace-knowledge--batch-aliases (car batches))
      state)
     (lambda (result)
       (let ((status (plist-get result :status)))
         (when (and (memq status '(failed partial no-plan))
                    (not (eq (plist-get state :outcome) 'failed)))
           (setf (plist-get state :outcome)
                 (if (eq status 'failed) 'failed
                   (if (eq (plist-get state :outcome) 'partial) 'partial status)))
           (when (plist-get result :reason)
             (setf (plist-get state :reason) (plist-get result :reason))))
         (if (eq status 'failed)
             (list :status 'failed :reason (plist-get result :reason))
           (harness-workspace-knowledge--synthesize-batches
            workspace (cdr batches) state)))))))

(defun harness-workspace-knowledge--dream-finished (workspace result)
  "Record and announce RESULT, a pass of WORKSPACE.
The outcome is kept with what it changed, and a pass that changed
something goes to the workspace as an event; one that changed nothing
stays in the state, where `knowledge/dream-status' reads it."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (id (plist-get workspace :id))
         (status (format "%s" (plist-get result :status))))
    (harness-workspace-knowledge--state-update
     workspace
     (lambda (state)
       (plist-put state :last (append result (list :at (float-time))))))
    (when (member status '("completed" "partial"))
      (harness-emit 'workspace/dream-finished id result))
    (harness-log (if (equal status "failed") 'warn 'info)
                 "workspace dream: %s: %s" id status)
    result))

(defun harness-workspace-knowledge--dream-pass (workspace opts)
  "Run one pass over WORKSPACE; return its result, or a promise of it.
OPTS may name `:dry-run' (report what would change and what a synthesis
would read, write nothing), `:report' (write the report page; the
default is `harness-workspace-knowledge-dream-report') and `:force' (run
while another pass holds the workspace)."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (id (plist-get workspace :id))
         (dry (plist-get opts :dry-run))
         (report (if (plist-member opts :report)
                     (plist-get opts :report)
                   harness-workspace-knowledge-dream-report))
         (date (format-time-string "%Y-%m-%d")))
    (if (and (gethash id harness-workspace-knowledge--running)
             (not (plist-get opts :force)))
        (list :workspace id :date date :status "busy" :dry-run (and dry t)
              :reason "a pass is already running")
      (puthash id t harness-workspace-knowledge--running)
      (let ((answer
             (condition-case err
                 (harness-workspace-knowledge--dream-body workspace date dry report)
               (error
                (harness-log 'warn "workspace dream: %s failed: %s"
                             id (harness-error-message err))
                (list :workspace id :date date :status "failed" :dry-run (and dry t)
                      :reason (harness-error-message err))))))
        ;; A pass that asks a model answers later: the workspace stays
        ;; held until its promise settles, so a second pass cannot start
        ;; in the middle of it.
        (if (harness-promise-p answer)
            (harness-then answer
                          (lambda (result)
                            (remhash id harness-workspace-knowledge--running)
                            result)
                          (lambda (failure)
                            (remhash id harness-workspace-knowledge--running)
                            (harness-log 'warn "workspace dream: %s failed: %s"
                                         id (harness-error-message failure))
                            (list :workspace id :date date :status "failed"
                                  :dry-run (and dry t)
                                  :reason (harness-error-message failure))))
          (remhash id harness-workspace-knowledge--running)
          answer)))))

(defun harness-workspace-knowledge--dream-body (workspace date dry report)
  "Do the work of a pass of WORKSPACE for DATE.
DRY reports without writing; REPORT writes the report page."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (id (plist-get workspace :id))
         (root (harness-workspace-knowledge--root workspace))
         (status (harness-call 'logseq/status root)))
    (if (not (plist-get status :available))
        (harness-workspace-knowledge--dream-finished
         workspace
         (list :workspace id :date date :dry-run (and dry t)
               :status "failed"
               :reason (or (plist-get status :reason) "no-graph")
               :graph-type (plist-get status :graph-type)
               :adapter (plist-get status :adapter)))
      (let* ((reconciled (unless dry (harness-workspace-knowledge--reconcile workspace)))
             (changes (when reconciled
                        (list (format "reconciled a run that stopped before its bookkeeping (%d capture%s)"
                                      (plist-get reconciled :captures)
                                      (if (= 1 (plist-get reconciled :captures)) "" "s")))))
             (threads (harness-workspace-knowledge--thread-pages workspace))
             (touched (unless dry (harness-workspace-knowledge--touch-threads workspace)))
             (pages (append threads
                            (mapcar (lambda (page) (plist-get page :name))
                                    (harness-workspace-knowledge--maintained-pages workspace))))
             (dedupe (harness-workspace-knowledge--dedupe workspace pages dry))
             (captures (harness-workspace-knowledge--pending-captures workspace)))
        (setq changes (append (plist-get dedupe :lines) changes))
        (cond
         (dry
          (harness-workspace-knowledge--dream-finished
           workspace
           (list :workspace id :date date :dry-run t
                 ;; A dry run that would read captures has work ahead of
                 ;; it, even though nothing was written yet.
                 :status (if (or changes captures) "completed" "no-change")
                 :pages (length threads)
                 :removed (plist-get dedupe :removed)
                 :sources (length captures)
                 :would-synthesize (length captures)
                 :changes (append (nreverse changes)
                                  (when captures
                                    (list (format "would read %d capture%s"
                                                  (length captures)
                                                  (if (= 1 (length captures)) "" "s"))))))))
         ((null captures)
          (harness-workspace-knowledge--dream-finished
           workspace
           (list :workspace id :date date
                 :status (if changes "completed" "no-change")
                 :pages (length threads)
                 :removed (plist-get dedupe :removed)
                 :touched touched
                 :sources 0
                 :changes (nreverse changes)
                 :report-page
                 (and report changes
                      (harness-workspace-knowledge--report-page
                       workspace
                       (list (harness-workspace-knowledge--report-line
                              workspace "no new captures" 0 (nreverse changes))))))))
         (t
          (harness-workspace-knowledge--synthesize-captures
           workspace date report (nreverse changes)
           (plist-get dedupe :removed) touched captures)))))))

(defun harness-workspace-knowledge--synthesize-captures (workspace date report changes writes touched captures)
  "Synthesize CAPTURES into WORKSPACE's pages, for DATE.
CHANGES, WRITES and TOUCHED say what the deterministic pass did; REPORT
writes the report page."
  (let* ((batches (seq-take (harness-workspace-knowledge--batches captures)
                            (max 1 harness-workspace-knowledge-dream-batches)))
         (state (list :done nil)))
    (harness-then
     (harness-workspace-knowledge--synthesize-batches workspace batches state)
     (lambda (result)
       (harness-workspace-knowledge--dream-conclude
        workspace date report changes writes touched captures
        (plist-get state :done) result)))))

(defun harness-workspace-knowledge--dream-conclude (workspace date report changes writes touched captures done result)
  "Finish a pass of WORKSPACE: record what it did, report it, return it.
CHANGES, WRITES and TOUCHED are the deterministic pass's; DONE the
synthesis's page results; RESULT the last batch's answer."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (id (plist-get workspace :id))
         (written (cl-mapcan (lambda (entry) (plist-get entry :results)) done))
         (refused (apply #'+ 0 (mapcar (lambda (entry) (or (plist-get entry :refused) 0)) done)))
         (sources (apply #'+ 0 (mapcar (lambda (entry) (or (plist-get entry :sources) 0)) done)))
         (failed (eq (plist-get result :status) 'failed))
         ;; A pass says `partial' when it read a batch and could not save
         ;; all of it, and `no-change' when the answer wrote nothing; the
         ;; rest is done.
         (status (cond (failed "failed")
                       ((eq (plist-get result :status) 'partial) "partial")
                       ((or changes written) "completed")
                       (t "no-change")))
         (page-changes
          (append (mapcar (lambda (entry)
                            (format "%s: %d statement%s"
                                    (plist-get entry :page)
                                    (length (plist-get entry :added))
                                    (if (= 1 (length (plist-get entry :added))) "" "s")))
                          written)
                  (when (> refused 0)
                    (list (format "%d statement%s refused" refused
                                  (if (= 1 refused) "" "s"))))))
         (report-page
          (and report
               (or changes written (not (equal status "no-change")))
               (harness-workspace-knowledge--report-page
                workspace
                (list (harness-workspace-knowledge--report-line
                       workspace status sources
                       (append changes page-changes)))))))
    (harness-workspace-knowledge--dream-finished
     workspace
     (list :workspace id :date date
           :status status
           :pages (length written)
           :removed writes
           :touched touched
           :sources sources
           :remaining (max 0 (- (length captures) sources))
           :refused refused
           :reasons (delete-dups
                     (apply #'append
                            (mapcar (lambda (entry) (plist-get entry :reasons)) done)))
           :changes (append changes page-changes)
           :report-page report-page
           :reason (plist-get result :reason)))))

;;;; The methods

(harness-defmethod knowledge/dream (workspace &optional opts)
  "Dream over WORKSPACE: consolidate its graph and synthesize what it learned.
The pass brings every open thread's page up to date, keeps a note this
workspace wrote twice once (lifting the children of the copy it
removes), and synthesizes the captures no pass has read yet into sourced
project, person, topic and decision knowledge, with a confidence that
says what the sources confirm, and a small navigation index.  A
statement the user rejected is never written again, a page another
workspace owns is never written into, and a page marked `no-dream:: true'
is left alone.

OPTS may name `:dry-run' (report what would change and what a synthesis
would read, write nothing), `:report' (write the `Dreams/<date>' report
page; the default is `harness-workspace-knowledge-dream-report') and
`:force' (run while another pass holds the workspace).

The answer is a plist (:workspace :date :status :pages :removed :sources
:refused :changes :report-page ...), where `:status' is `completed',
`no-change', `partial', `failed' or `busy'.  A synthesis asks a model, so
the answer is a promise when one was asked; `knowledge/dream-status'
reads what the last pass did."
  (harness-workspace-knowledge--dream-pass workspace opts))

(harness-defmethod knowledge/dream-status (workspace &optional opts)
  "Return what WORKSPACE's dreaming is and did.
OPTS is accepted for the contract.  The answer is (:workspace :enabled
:hour :timezone :next :last :processed :rejected :remaining :catch-up
:running :graph :graph-type :adapter :recovery :limitations ...).
`:last' is the last pass's outcome, `:processed' how many captures were
read, `:rejected' how many statements are kept out, `:remaining' how many
captures wait, `:running' whether a pass holds the workspace now,
`:recovery' what the graph itself would bring a page back from, and
`:limitations' what this graph cannot do."
  (ignore opts)
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (id (plist-get workspace :id))
         (root (harness-workspace-knowledge--root workspace))
         (state (harness-workspace-knowledge--state workspace))
         (status (harness-call 'logseq/status root))
         ;; Asked here, not in `logseq/status': it runs git.
         (recovery (harness-call 'logseq/recovery root)))
    (list :workspace id
          :enabled (and (eq harness-workspace-knowledge-dream 'auto) t)
          :hour harness-workspace-knowledge-dream-hour
          :timezone (car (current-time-zone))
          :next (harness-workspace-knowledge--next-dream-time)
          :last (plist-get state :last)
          :last-date (plist-get state :last-date)
          :processed (length (append (plist-get state :processed) nil))
          :rejected (length (harness-workspace-knowledge--rejected workspace))
          :remaining (length (harness-workspace-knowledge--pending-captures workspace))
          :catch-up (and harness-workspace-knowledge-dream-catch-up t)
          :running (and (gethash id harness-workspace-knowledge--running) t)
          :graph root
          :graph-type (plist-get status :graph-type)
          :adapter (plist-get status :adapter)
          :recovery recovery
          :limitations
          (delq nil
                (list (unless (plist-get status :available)
                        (or (plist-get status :reason) "no-graph"))
                      (when (eq (plist-get status :graph-type) 'database)
                        "a database graph is not read")
                      (unless (plist-get recovery :git)
                        "the graph is not in a git checkout")
                      (when (zerop (or (plist-get recovery :backups) 0))
                        "the graph has no logseq/bak history"))))))



(harness-defmethod knowledge/dream-exclude (workspace text &optional why)
  "Keep TEXT out of WORKSPACE's later dreams, for WHY.
A statement excluded is never written again; a page or a block can also
carry `no-dream:: true' in the graph itself.  Return the statement kept
out, or nil when TEXT holds no words."
  (harness-workspace-knowledge--reject workspace text (or why "excluded")))

(harness-defmethod knowledge/index (workspace &optional opts)
  "Return WORKSPACE's navigation index as text, or nil.
OPTS is accepted for the contract.  The index is the small list of the
pages a pass maintains, one line each, which a brief carries so that the
search and the curated graph work together."
  (ignore opts)
  (harness-workspace-knowledge--index workspace))

;;;; The schedule

(defvar harness-workspace-knowledge--dream-timer nil
  "The timer that wakes the nightly dream.")

(defvar harness-workspace-knowledge--catch-up-timer nil
  "The timer that catches up on a dream missed while the harness was off.")

(defun harness-workspace-knowledge--next-dream-time ()
  "Return the time of the next nightly dream, as a float.
That is today's hour when it is still to come, else tomorrow's."
  (let* ((now (float-time))
         (today (format-time-string "%Y-%m-%d"))
         (at (float-time (date-to-time
                          (format "%s %02d:00:00" today
                                  harness-workspace-knowledge-dream-hour)))))
    (if (> at now) at (+ at 86400))))

(defun harness-workspace-knowledge--dream-due-p (workspace)
  "Non-nil when WORKSPACE has not been dreamed since its scheduled hour.
A workspace dreamed yesterday but before today's hour is due once the
hour has passed, which is what a catch-up after a missed night finds."
  (let* ((id (plist-get workspace :id))
         (last (cdr (assoc id (harness-workspace-knowledge--dreams))))
         (today (format-time-string "%Y-%m-%d"))
         (now (float-time))
         (at (float-time (date-to-time
                          (format "%s %02d:00:00" today
                                  harness-workspace-knowledge-dream-hour)))))
    (and id
         (not (equal last today))
         (or (>= now at) (null last)))))

(defun harness-workspace-knowledge--workspaces ()
  "Return the workspaces the harness knows, as their plists."
  (and (harness-method-exists-p 'workspace/list)
       (ignore-errors (harness-call 'workspace/list))))

(defun harness-workspace-knowledge--dream-one (workspace)
  "Dream WORKSPACE and record it; return what the pass answered."
  (let* ((id (plist-get workspace :id))
         (today (format-time-string "%Y-%m-%d")))
    (condition-case err
        (let ((answer (harness-workspace-knowledge--dream-pass workspace nil)))
          (if (harness-promise-p answer)
              (harness-then
               answer
               (lambda (result)
                 (harness-workspace-knowledge--dream-record id today)
                 result)
               (lambda (failure)
                 (harness-log 'warn "workspace dream: %s: %s"
                              id (harness-error-message failure))
                 (harness-workspace-knowledge--dream-record id today)
                 nil))
            (progn
              (harness-workspace-knowledge--dream-record id today)
              answer)))
      (error
       (harness-log 'warn "workspace dream: %s: %s" id (harness-error-message err))
       (harness-workspace-knowledge--dream-record id today)
       nil))))

(defun harness-workspace-knowledge--dream-tick ()
  "Dream every workspace that has not been dreamed today.
The tick runs one workspace after another, so two passes never overlap,
and it schedules the next one."
  (when (eq harness-workspace-knowledge-dream 'auto)
    (dolist (workspace (harness-workspace-knowledge--workspaces))
      (when (harness-workspace-knowledge--dream-due-p workspace)
        (harness-workspace-knowledge--dream-one workspace))))
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

(defun harness-workspace-knowledge--catch-up ()
  "Dream the workspaces a start found due, once and within its bound.
A harness that was off at the scheduled hour dreams the workspaces still
due when it starts, at most `...-catch-up-limit' of them: one bounded
catch-up, not a night's worth of passes one after another."
  (setq harness-workspace-knowledge--catch-up-timer nil)
  (when (and (eq harness-workspace-knowledge-dream 'auto)
             harness-workspace-knowledge-dream-catch-up)
    (let ((due (cl-remove-if-not #'harness-workspace-knowledge--dream-due-p
                                 (harness-workspace-knowledge--workspaces)))
          (limit (max 0 harness-workspace-knowledge-dream-catch-up-limit)))
      (when due
        (harness-log 'info "workspace dream: catching up on %d workspace(s)"
                     (length due))
        (dolist (workspace (seq-take due limit))
          (harness-workspace-knowledge--dream-one workspace))))))

(defun harness-workspace-knowledge--schedule-catch-up ()
  "Arrange the startup catch-up, or cancel it."
  (when (timerp harness-workspace-knowledge--catch-up-timer)
    (cancel-timer harness-workspace-knowledge--catch-up-timer)
    (setq harness-workspace-knowledge--catch-up-timer nil))
  (when (and (eq harness-workspace-knowledge-dream 'auto)
             harness-workspace-knowledge-dream-catch-up)
    ;; A moment after the modules are up, so a start is not held by a
    ;; pass: the workspaces are read and dreamed from the command loop.
    (setq harness-workspace-knowledge--catch-up-timer
          (run-at-time 5 nil #'harness-workspace-knowledge--catch-up))))

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
  (harness-workspace-knowledge--schedule-dream)
  (harness-workspace-knowledge--schedule-catch-up))

(defun harness-workspace-knowledge--shutdown ()
  "Stop following the workspace's episodes."
  (when harness-workspace-knowledge--subscribed
    (setq harness-workspace-knowledge--subscribed nil)
    (harness-off (cons 'session/node-added #'harness-workspace-knowledge--on-node-added))
    (harness-off (cons 'session/node-updated #'harness-workspace-knowledge--on-node-updated))
    (harness-off (cons 'agent/turn-ended #'harness-workspace-knowledge--on-turn-ended))
    (harness-remove-filter 'agent/tools #'harness-workspace-knowledge--tools))
  (dolist (timer '(harness-workspace-knowledge--dream-timer
                  harness-workspace-knowledge--catch-up-timer))
    (when (timerp (symbol-value timer))
      (cancel-timer (symbol-value timer))
      (set timer nil)))
  (clrhash harness-workspace-knowledge--running))

(harness-declare-event 'workspace/knowledge-changed
                       "(WORKSPACE OP) when a block was written to the workspace's graph.")
(harness-declare-event 'workspace/dream-finished
                       "(WORKSPACE RESULT) when a dream changed the workspace's graph.")

(harness-define-module 'workspace-knowledge
  :doc "The workspace's Logseq knowledge graph: thread pages, journal captures, retrieval and the knowledge tools."
  :requires '(logseq session tools)
  :init #'harness-workspace-knowledge--init
  :shutdown #'harness-workspace-knowledge--shutdown)

(provide 'harness-workspace-knowledge)
;;; harness-workspace-knowledge.el ends here
