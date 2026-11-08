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
;; - `knowledge/thread-touch': the thread page's status and last-touched
;;   properties, so the page reads current in Logseq.
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

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-logseq)
(require 'harness-session)
(require 'harness-tools)

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
        (let ((page (concat "Threads/" (harness-workspace-knowledge--thread-title
                                        workspace thread))))
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

(defun harness-workspace-knowledge--identity (workspace thread)
  "Return the identity properties of THREAD's page in WORKSPACE."
  (let ((workspace (harness-workspace-knowledge--workspace workspace))
        (thread (harness-workspace-knowledge--thread workspace thread)))
    (list (cons "workspace" (harness-workspace-knowledge--name workspace))
          (cons "workspace-id" (plist-get workspace :id))
          (cons "thread-id" (plist-get thread :id))
          (cons "workspace-status" (or (plist-get thread :status) "active"))
          (cons "thread-title" (plist-get thread :title))
          (cons "project" (or (plist-get thread :project)
                              (plist-get workspace :root)))
          (cons "created" (format-time-string "%Y-%m-%d")))))

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
OPTS may name `:limit', `:thread' and `:all'; see `knowledge/search'."
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (thread (plist-get opts :thread))
         (page (when thread
                 (harness-workspace-knowledge--thread-page-name workspace thread)))
         (all (plist-get opts :all))
         (limit (or (plist-get opts :limit) 50))
         (results (harness-call
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
      results)))

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
  "Return TEXT cut to the most one capture keeps."
  (let ((text (harness-logseq--one-line text)))
    (if (> (length text) harness-workspace-knowledge-capture-chars)
        (concat (substring text 0 harness-workspace-knowledge-capture-chars) "…")
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
    page))

(harness-defmethod knowledge/write (workspace thread role text &optional opts)
  "Write TEXT as durable knowledge of WORKSPACE's THREAD, as ROLE.
OPTS may name `:page' (another page of the graph, such as
`Projects/harness'), `:session' and `:node' for provenance, and `:date'.
Return the block.  This is what `knowledge_write' writes; a message is
captured in the journal instead."
  (ignore role)
  (let* ((workspace (harness-workspace-knowledge--workspace workspace))
         (root (harness-workspace-knowledge--root workspace))
         (thread (harness-workspace-knowledge--thread workspace thread))
         (named (plist-get opts :page))
         (page (if named
                   (harness-logseq-page-name named)
                 (harness-workspace-knowledge--thread-page workspace thread)))
         (source-session (plist-get opts :session))
         (source-node (plist-get opts :node))
         (props (append
                 (list (cons "workspace" (harness-workspace-knowledge--name workspace))
                       (cons "workspace-id" (plist-get workspace :id)))
                 (when thread
                   (list (cons "thread" (format "[[%s]]"
                                                (harness-workspace-knowledge--thread-page
                                                 workspace thread)))))
                 (when (and source-session (stringp source-session))
                   (list (cons "source-session" source-session)))
                 (when (and source-node (stringp source-node))
                   (list (cons "source-node" source-node)))))
         (block (harness-call 'logseq/page-add page text
                              (list :root root :properties props
                                    :date (plist-get opts :date)))))
    (harness-workspace-knowledge--changed workspace)
    (harness-emit 'workspace/knowledge-changed
                  (plist-get workspace :id)
                  (list :page page :block (plist-get block :id)))
    block))

(harness-defmethod knowledge/search (workspace query &optional opts)
  "Return the blocks of WORKSPACE's knowledge graph that match QUERY.
OPTS may name `:limit', `:thread' (only that thread's page and
captures) and `:all' (the whole graph, the user's own notes included;
the default is this workspace's blocks).  A result is a block plist as
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
the turn's later chunks would otherwise each become a block."
  (when-let* ((ext (harness-workspace-knowledge--episode-ext session-id))
              (kind (plist-get node :kind))
              ((memq (if (stringp kind) (intern kind) kind) '(user assistant plan)))
              (role (harness-workspace-knowledge--role kind))
              ((not (equal role "assistant")))
              ((not (plist-get (plist-get node :meta) :workspace-brief)))
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
  "Capture the final assistant replies of SESSION-ID's finished turn."
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

(defun harness-workspace-knowledge--tool-search (input ctx)
  "Handler of knowledge_search with INPUT and CTX."
  (let* ((pair (harness-workspace-knowledge--tool-workspace ctx))
         (workspace (car pair))
         (thread (plist-get input :thread))
         (query (or (plist-get input :query) ""))
         (limit (or (plist-get input :limit) 20))
         (cards (harness-call 'knowledge/search workspace query
                              (list :limit limit
                                    :all (plist-get input :all)
                                    :thread (and thread (not (plist-get input :all))
                                                 thread)))))
    (if (null cards)
        (harness-tool-ok (format "No knowledge matches %S." query))
      (harness-tool-ok
       (concat (format "%d block%s:\n" (length cards)
                       (if (= (length cards) 1) "" "s"))
               (mapconcat (lambda (card)
                            (format "- [%s] %s"
                                    (or (plist-get card :page) "graph")
                                    (plist-get card :text)))
                          cards "\n"))))))

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
  :description "Search the workspace's Logseq knowledge graph: decisions, facts, projects, people and the notes of every thread. Use it for anything the brief did not give you, for what another thread learned, or for a preference the user wrote down. Set all to search the user's whole graph, not only this workspace. Never invent knowledge you did not retrieve."
  :schema '(:type "object"
            :properties (:query (:type "string" :description "Words or a question to find in the graph.")
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
  :description "Write durable knowledge to the workspace's Logseq graph: a decision, a fact, a commitment, an open loop or a next action. The block goes on the current thread's page unless page names another one (Projects/harness, Preferences, People/Ada). Write one concise statement, not a transcript dump; the user's own edits in Logseq outrank what you write."
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
    (harness-add-filter 'agent/tools #'harness-workspace-knowledge--tools 40)))

(defun harness-workspace-knowledge--shutdown ()
  "Stop following the workspace's episodes."
  (when harness-workspace-knowledge--subscribed
    (setq harness-workspace-knowledge--subscribed nil)
    (harness-off (cons 'session/node-added #'harness-workspace-knowledge--on-node-added))
    (harness-off (cons 'session/node-updated #'harness-workspace-knowledge--on-node-updated))
    (harness-off (cons 'agent/turn-ended #'harness-workspace-knowledge--on-turn-ended))
    (harness-remove-filter 'agent/tools #'harness-workspace-knowledge--tools)))

(harness-declare-event 'workspace/knowledge-changed
                       "(WORKSPACE OP) when a block was written to the workspace's graph.")

(harness-define-module 'workspace-knowledge
  :doc "The workspace's Logseq knowledge graph: thread pages, journal captures, retrieval and the knowledge tools."
  :requires '(logseq session tools)
  :init #'harness-workspace-knowledge--init
  :shutdown #'harness-workspace-knowledge--shutdown)

(provide 'harness-workspace-knowledge)
;;; harness-workspace-knowledge.el ends here
