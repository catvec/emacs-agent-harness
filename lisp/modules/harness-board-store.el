;;; harness-board-store.el --- Boards kept, committed and followed  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The board as the harness serves it (harness-board.el, the grammar and
;; the document; harness-board-edit.el, the operations and patches): the
;; boards kept under the state directory, the commits that write them, the
;; undo history that survives a restart, and the bus methods a client and a
;; tool call.
;;
;; THE STORE.  One JSON document per board, `boards/BOARD.json' under
;; `harness-state-directory', written atomically.  A board's client state --
;; where each client's viewport and selection are, and the last place a
;; client was asked to look -- is `boards/BOARD.views.json', a second
;; document that navigation writes without making a revision: two people
;; scrolling a board is not an edit of it.
;;
;; A COMMIT is serialized.  The harness runs on one Emacs thread, so a
;; commit checks its read set and writes the document in one turn of the
;; loop: either the whole batch lands or none of it does.  A commit whose
;; idempotency key was used before answers what it answered then, so a
;; retried call after a lost answer commits once.  The keys are kept with
;; the board, bounded, so a restart does not re-commit a retry either.
;;
;; THE METHODS.  `board/list', `board/get', `board/create', `board/delete',
;; `board/patch', `board/preview', `board/commit', `board/undo',
;; `board/grammar', `board/link/describe', `board/focus' and `board/views'.
;; Each is callable over ACP as `_harness/board/...', so the Flutter client
;; and the Emacs page read and write the same boards through the same calls
;; the agent's tools use.  `board/changed' announces every commit.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-board)
(require 'harness-board-edit)

(defvar harness-state-directory)

(defconst harness-board--store-directory "boards/"
  "Where boards are kept under the state directory.")

(defconst harness-board--keys-limit 200
  "How many idempotency keys a board remembers.")

(defcustom harness-board-writers nil
  "Sessions allowed to edit every board, or nil for any session.
A board may name the sessions that may write it in its `:writers'; a
session not listed is refused as a permission failure.  This variable is
the wider rule an installation sets, and by default any session may edit
a board it can see."
  :type '(choice (const nil) (repeat string)) :group 'harness)

(harness-declare-event 'board/changed
  "(:board ID :revision N :patch ID :created (ID ...) :changed (ID ...)) after a board commit.")
(harness-declare-event 'board/created "(:board ID) after a board is made.")
(harness-declare-event 'board/deleted "(:board ID) after a board is removed.")
(harness-declare-event 'board/focused
  "(:board ID :diagram ID :object ID :revision N) when a client is asked to a place.")

;;;; Paths

(defun harness-board--directory ()
  "Return the directory boards are kept in."
  (expand-file-name harness-board--store-directory harness-state-directory))

(defun harness-board--path (id)
  "Return the document path of board ID."
  (expand-file-name (concat (harness-board--id id "board id") ".json")
                    (harness-board--directory)))

(defun harness-board--views-path (id)
  "Return the client-view path of board ID."
  (expand-file-name (concat (harness-board--id id "board id") ".views.json")
                    (harness-board--directory)))

(defun harness-board--pins-directory ()
  "Return the directory pinned board revisions are kept in."
  (expand-file-name "pins/" (harness-board--directory)))

(defun harness-board--pin-path (id)
  "Return the document path of pin ID."
  (expand-file-name (concat (harness-board--id id "pin id") ".json")
                    (harness-board--pins-directory)))

(defun harness-board--ids ()
  "Return the ids of the boards in the store, sorted."
  (let ((dir (harness-board--directory)))
    (if (not (file-directory-p dir))
        nil
      (sort (cl-loop for file in (directory-files dir t "\\.json\\'")
                     unless (string-suffix-p ".views.json" file)
                     collect (file-name-base file))
            #'string<))))

;;;; Loading and saving

(defun harness-board-load (id)
  "Return board ID from the store, or nil when there is none.
A document of a schema this harness does not read is refused."
  (let ((path (harness-board--path id)))
    (when (file-readable-p path)
      (let ((parsed (harness-json-parse (harness-read-file path))))
        (if (null parsed)
            (harness-board--fail 'invalid-parameter "board %s is empty" id)
          (harness-board-normalise-document parsed))))))

(defun harness-board--save (board)
  "Write BOARD's document atomically."
  (harness-write-file-atomically (harness-board--path (plist-get board :id))
                                 (harness-json-encode-text board))
  board)

(defun harness-board-save (board)
  "Write BOARD's document and the client state it carries, atomically.
The board's `:views' key, when present, is the client state, written to
its own document."
  (let ((document (harness-plist-remove board :views)))
    (harness-board--save document)
    (when (plist-member board :views)
      (harness-write-file-atomically
       (harness-board--views-path (plist-get board :id))
       (harness-json-encode-text (list :schema harness-board-schema
                                       :board (plist-get board :id)
                                       :views (plist-get board :views)))))
    document))

(defun harness-board-load-views (id)
  "Return the client state of board ID, or nil."
  (let ((path (harness-board--views-path id)))
    (when (file-readable-p path)
      (let ((parsed (harness-json-parse (harness-read-file path))))
        (and (listp parsed) (plist-get parsed :views))))))

(defun harness-board-set-views (id views)
  "Write the client state VIEWS of board ID.  Return it."
  (harness-write-file-atomically
   (harness-board--views-path id)
   (harness-json-encode-text (list :schema harness-board-schema :board id :views views)))
  views)

(defun harness-board-save-views (board view)
  "Write VIEW, a client state plist, to BOARD's client document."
  (let* ((views (or (harness-board-load-views (plist-get board :id)) nil))
         (key (or (plist-get view :client) "default"))
         (old (plist-get views (intern (concat ":" key))))
         (merged (let ((copy (copy-sequence old)))
                   (while view
                     (unless (eq (car view) :client)
                       (setq copy (plist-put copy (car view) (cadr view))))
                     (setq view (cddr view)))
                   (plist-put copy :time (harness-now)))))
    (harness-board-set-views (plist-get board :id)
                             (plist-put (or (copy-sequence views) nil)
                                        (intern (concat ":" key)) merged))))

;;;; The document a client reads

(defun harness-board--views-of-diagram (board diagram)
  "Return the objects BOARD has a view of in DIAGRAM, in layer order."
  (sort (cl-loop for object in (plist-get board :objects)
                 for view = (harness-board--view object diagram)
                 when view collect (cons object view))
        (lambda (a b) (< (or (plist-get (cdr a) :z) 0) (or (plist-get (cdr b) :z) 0)))))

(defun harness-board--relationship-view (board relationship)
  "Return RELATIONSHIP as a client draws it, its endpoints placed."
  (let* ((diagram (plist-get relationship :diagram))
         (from (plist-get relationship :from))
         (to (plist-get relationship :to))
         (from-object (harness-board--object board (plist-get from :object)))
         (to-object (harness-board--object board (plist-get to :object)))
         (from-view (and from-object (harness-board--view from-object diagram)))
         (to-view (and to-object (harness-board--view to-object diagram))))
    (append
     relationship
     (list :from-point (and from-view
                            (harness-board-anchor-point from-view (or (plist-get from :anchor) "center")))
           :to-point (and to-view
                          (harness-board-anchor-point to-view (or (plist-get to :anchor) "center")))
           :from-box (and from-view (harness-board-view-box from-view))
           :to-box (and to-view (harness-board-view-box to-view))))))

(defun harness-board-document (board &optional diagram)
  "Return BOARD as a client reads it, for DIAGRAM (the first by default).
Every object carries its exact geometry and text, its local frame, its
named anchors, its resources with the state each resolved to, the box it
occupies in the diagram and its layer.  A client draws from this alone:
there is no second model of the board."
  (let* ((diagram (or diagram (plist-get (car (plist-get board :diagrams)) :id)))
         (place (harness-board--diagram! board diagram))
         (placed (harness-board--views-of-diagram board diagram))
         (objects nil))
    (dolist (pair placed)
      (let ((object (car pair)) (view (cdr pair)))
        (push (append
               (harness-plist-remove (harness-plist-remove object :views) :resources)
               (list :diagram diagram
                     :shape (plist-get view :shape)
                     :transform (plist-get view :transform)
                     :style (plist-get view :style)
                     :anchors (harness-board--anchors-data (plist-get view :anchors))
                     :z (plist-get view :z)
                     :box (harness-board-view-box view)
                     :origin (harness-board-matrix-apply (plist-get view :transform) 0 0)
                     :diagrams (vconcat (harness-board--diagram-ids-of object))
                     :resources (harness-board--resources-data object)
                     :locked (and (plist-get object :locked) t)
                     :mirrored (harness-board-matrix-reflects-p (plist-get view :transform))
                     :source-status (harness-board--task-status board object)))
              objects)))
    (list :schema harness-board-schema
          :id (plist-get board :id)
          :name (plist-get board :name)
          :project (plist-get board :project)
          :theme (plist-get board :theme)
          :revision (plist-get board :revision)
          :created (plist-get board :created)
          :updated (plist-get board :updated)
          :diagram place
          :diagrams (vconcat (plist-get board :diagrams))
          :objects (vconcat (nreverse objects))
          :relationships (vconcat
                          (cl-loop for relationship in (plist-get board :relationships)
                                   when (equal (plist-get relationship :diagram) diagram)
                                   collect (harness-board--relationship-view board relationship)))
          :nearby nil
          :undo-depth (length (append (plist-get board :history) nil))
          :writers (vconcat (or (plist-get board :writers) nil))
          :view (harness-board-load-views (plist-get board :id)))))

(defun harness-board--anchors-data (anchors)
  "Return ANCHORS as a client reads them: a plist of [x y]."
  (let (out)
    (while anchors
      (let ((point (plist-get anchors (car anchors))))
        (setq out (plist-put out (car anchors) (vector (aref point 0) (aref point 1)))))
      (setq anchors (cddr anchors)))
    out))

(defun harness-board--resources-data (object)
  "Return OBJECT's resources, each resolved to where it points now."
  (mapcar #'harness-board-link-describe (or (plist-get object :resources) nil)))

(defun harness-board--task-status (_board object)
  "Return what a task marker of OBJECT says now, or nil.
A marker reports the real task: its column, its state and when it
changed, or that the task is gone.  Nothing here invents activity."
  (when-let* ((id (plist-get object :task)))
    (if (not (harness-method-exists-p 'task/get))
        (list :status "unsupported" :label "task · no task board")
      (let ((task (ignore-errors (harness-call 'task/get id))))
        (if (null task)
            (list :status "missing" :label (format "task %s · missing" id))
          (list :status "resolved"
                :label (format "%s · %s"
                               (or (plist-get task :column) (plist-get task :state) "task")
                               (or (plist-get task :name) id))
                :column (plist-get task :column)
                :state (plist-get task :state)
                :updated (plist-get task :updatedAt)
                :session (plist-get task :session)
                :id id))))))

;;;; Resource links, resolved

(defun harness-board--find-node (session node kind)
  "Return NODE of SESSION, a message or a call, or nil.
A session that is not here, an id that names nothing and a node of
another kind all answer nil: the caller says which of them happened,
and never substitutes a page for the precise thing asked for.  KIND is
`message' or `call', and names what NODE must be."
  (when (and (stringp session) (not (string-empty-p session))
             (harness-method-exists-p 'session/node))
    (let ((here (ignore-errors (harness-call 'session/get session))))
      (when here
        (let ((found (ignore-errors (harness-call 'session/node session node))))
          (when found
            (pcase kind
              ('message found)
              ('call (and (equal (plist-get found :kind) 'tool-call) found))
              (_ found))))))))

(defun harness-board-link-describe (resource)
  "Return RESOURCE, a typed link, with where it points now.
Reply `:state' is `resolved', `stale', `unsupported' or `missing', and
what was found: a task's column, a message's role and excerpt, a diagram
on the board, a file that is there.  A precise link is never replaced by
a generic one: an unknown message is `missing', not the task's page."
  (let* ((kind (harness-board--symbol (plist-get resource :kind)))
         (ref (plist-get resource :ref))
         (base (list :kind kind :ref ref
                     :label (or (plist-get resource :label)
                                (format "%s %s" (symbol-name kind) ref))
                     :role (plist-get resource :role))))
    (append
     base
     (pcase kind
       ('task
        (if (not (harness-method-exists-p 'task/get))
            (list :state "unsupported" :note "no task board is loaded")
          (let ((task (ignore-errors (harness-call 'task/get ref))))
            (if (null task)
                (list :state "missing" :note "no such task")
              (list :state "resolved"
                    :name (or (plist-get task :name) (plist-get task :id))
                    :column (plist-get task :column)
                    :task-state (plist-get task :state)
                    :updated (plist-get task :updatedAt)
                    :target (harness-links-task-url (plist-get task :id)))))))
       ('message
        (let* ((parts (split-string ref "/" nil))
               (session (nth 0 parts))
               (node (or (nth 1 parts) (nth 0 parts))))
          (if (not (harness-method-exists-p 'session/node))
              (list :state "unsupported" :note "no session transcript here")
            (let ((found (harness-board--find-node session node 'message)))
              (if (null found)
                  (list :state "missing" :note "no such message")
                (list :state "resolved"
                      :role-name (or (plist-get found :role) "message")
                      :excerpt (harness-truncate-end (or (plist-get found :text) "") 120)
                      :target (harness-links-message-url session (plist-get found :id))))))))
       ('call
        (let* ((parts (split-string ref "/" nil))
               (session (nth 0 parts))
               (node (or (nth 1 parts) (nth 0 parts))))
          (if (not (harness-method-exists-p 'session/node))
              (list :state "unsupported" :note "no session transcript here")
            (let ((found (harness-board--find-node session node 'call)))
              (if (and found (equal (plist-get found :kind) 'tool-call))
                  (list :state "resolved"
                        :tool (plist-get found :tool)
                        :target (harness-links-call-url session (plist-get found :id)))
                (list :state "missing" :note "no such tool call"))))))
       ('thread
        ;; The review keeps its threads and answers for one of them
        ;; (`review/find-thread', the method the linking module names); a
        ;; board never reads the review's store itself.
        (let* ((parts (split-string ref "/" nil))
               (task (nth 0 parts))
               (thread (or (nth 1 parts) (nth 0 parts))))
          (if (not (harness-method-exists-p 'review/find-thread))
              (list :state "unsupported" :note "no review threads here")
            (let ((found (ignore-errors (harness-call 'review/find-thread task thread))))
              (if (null found)
                  (list :state "missing" :note "no such review thread")
                (list :state "resolved"
                      :status (plist-get found :status)
                      :comments (or (plist-get found :comments) 0)
                      :target (harness-links-thread-url task (plist-get found :id))))))))
       ((or 'diagram 'board)
        (let ((board (or (and (equal kind 'board) ref)
                         (plist-get resource :board))))
          (if (and board (harness-board-load board))
              (list :state "resolved" :target (harness-links-board-url board ref))
            (list :state "missing" :note "no such diagram"))))
       ('document
        (cond ((file-readable-p ref)
               (list :state "resolved" :note "readable"))
              ((string-match-p "\\`[a-z][a-z0-9+.-]*:" ref)
               (list :state "unsupported" :note "external address"))
              (t (list :state "missing" :note "no such file"))))
       ('symbol
        (list :state "declared"
              :note "static evidence at a revision: definitions and uses, not runtime flow"))
       ('screen
        (if (harness-method-exists-p 'computer/list)
            (let ((computers (ignore-errors (harness-call 'computer/list))))
              (if computers
                  (list :state "unavailable"
                        :note "no recorded capture for this moment")
                (list :state "unsupported" :note "no computers here")))
          (list :state "unsupported" :note "no computers here")))
       (_ (list :state "unsupported" :note "unknown resource kind"))))))

;;;; Permission

(defun harness-board--session (session)
  "Return the session id SESSION, or nil."
  (cond ((null session) nil)
        ((stringp session) session)
        ((listp session) (plist-get session :id))
        (t (format "%s" session))))

(defun harness-board--may-write-p (board session)
  "Return non-nil when SESSION may edit BOARD."
  (let ((id (harness-board--session session))
        (writers (append (plist-get board :writers) nil)))
    (cond
     (harness-board-writers (and id (member id harness-board-writers)))
     (writers (and id (member id writers)))
     (t t))))

(defun harness-board--check-writer! (board session)
  "Refuse SESSION as a writer of BOARD."
  (unless (harness-board--may-write-p board session)
    (harness-board--fail 'permission
                         "session %s may not write board %s"
                         (or (harness-board--session session) "none")
                         (plist-get board :id))))

;;;; Key state

(defun harness-board--keys (board)
  "Return the idempotency keys BOARD remembers, a plist."
  (let ((keys (plist-get board :keys)))
    (if (and (consp keys) (keywordp (car keys))) keys nil)))

(defun harness-board--remember-key (board key answer)
  "Return BOARD remembering KEY answered by ANSWER.
The oldest keys are forgotten past `harness-board--keys-limit'."
  (let* ((entry (list :patch (plist-get answer :patch)
                      :hash (plist-get answer :hash)
                      :revision (plist-get answer :revision)
                      :created (plist-get answer :created)
                      :changed (plist-get answer :changed)
                      :time (harness-now)))
         (keys (plist-put (copy-sequence (harness-board--keys board))
                          (intern (concat ":" key)) entry))
         (pairs (cl-loop for (k v) on keys by #'cddr collect (cons k v))))
    (when (> (length pairs) harness-board--keys-limit)
      (let ((kept (cl-subseq
                   (sort pairs (lambda (a b)
                                 (> (or (plist-get (cdr a) :time) 0)
                                    (or (plist-get (cdr b) :time) 0))))
                   0 harness-board--keys-limit)))
        (setq keys (apply #'append (cl-loop for (k . v) in kept append (list k v))))))
    (plist-put (copy-sequence board) :keys keys)))

;;;; Reading

(defun harness-board--lookup (id &optional none-ok)
  "Return board ID, or refuse it when it is not here."
  (or (harness-board-load id)
      (if none-ok nil
        (harness-board--fail 'unknown-id "no board %s" id))))

;;;; The methods

(harness-defmethod board/list (&optional opts)
  "Return the boards in the store, newest first.
OPTS `:project' keeps those of one project; `:all' includes every
project, which is what the default does when no project is named."
  (let ((project (plist-get opts :project)))
    (vconcat
     (sort
      (cl-loop for id in (harness-board--ids)
               for board = (ignore-errors (harness-board-load id))
               when board
               when (or (null project)
                        (equal project (plist-get board :project))
                        (plist-get opts :all))
               collect (list :id (plist-get board :id)
                             :name (plist-get board :name)
                             :project (plist-get board :project)
                             :theme (plist-get board :theme)
                             :revision (plist-get board :revision)
                             :updated (plist-get board :updated)
                             :diagrams (length (plist-get board :diagrams))
                             :objects (length (plist-get board :objects))
                             :markers (cl-count-if
                                       (lambda (o) (plist-get o :task))
                                       (plist-get board :objects))))
      (lambda (a b) (> (or (plist-get a :updated) 0) (or (plist-get b :updated) 0)))))))

(harness-defmethod board/create (id name &optional opts)
  "Make a board named NAME with id ID, in the project OPTS names.
Return it as `board/get' reads it.  A board that is already here is
refused rather than emptied."
  (let* ((id (harness-board--id id "board id"))
         (project (plist-get opts :project))
         (theme (plist-get opts :theme))
         (board (harness-board-normalise
                 (harness-board-blank id name project))))
    (when (harness-board-load id)
      (harness-board--fail 'invalid-parameter "board %s is already here" id))
    (when theme
      (setq board (harness-board--set-theme board theme)))
    (when-let* ((writers (plist-get opts :writers)))
      (setq board (plist-put board :writers (vconcat writers))))
    (harness-board-save board)
    (harness-emit 'board/created (list :board id))
    (harness-board-document board)))

(defun harness-board--set-theme (board theme)
  "Return BOARD wearing THEME."
  (harness-board--board-field board (list :theme theme) :theme))

(harness-defmethod board/get (id &optional opts)
  "Return board ID as a client draws it, for the diagram OPTS names.
OPTS `:diagram' picks the diagram; `:near' is an object id whose
neighbours are reported in `:nearby'; `:image' asks for the rendered
snapshot of the diagram as SVG.  The answer carries the revision, the
last commit, the selection of the diagram, every object with its exact
geometry and text and its local frame and anchors, the resources each
with the state it resolved to, and the objects near the selection."
  (let* ((board (harness-board--lookup id))
         (diagram (or (plist-get opts :diagram)
                      (plist-get (car (plist-get board :diagrams)) :id)))
         (document (harness-board-document board diagram))
         (near (or (plist-get opts :near)
                   (and (plist-get opts :nearby)
                        (car (append (plist-get (harness-board--diagram! board diagram)
                                                :selection)
                                     nil))))))
    (setq document (plist-put document :last (harness-board--last-commit board)))
    (when (harness-board--truthy (plist-get opts :image))
      (setq document (plist-put document :image
                                (and (fboundp 'harness-board-svg)
                                     (harness-board-svg board diagram)))))
    (if near
        (plist-put document :nearby (harness-board--near board diagram near))
      document)))

(defun harness-board--last-commit (board)
  "Return the newest commit of BOARD as a client reads it, or nil.
It is the revision, when it was made and what it made and changed --
what the page says of the last commit, and nothing more."
  (let ((entry (car (append (plist-get board :history) nil))))
    (and entry
         (list :revision (plist-get entry :revision)
               :patch (plist-get entry :patch)
               :time (plist-get entry :time)
               :created (vconcat (or (plist-get entry :created) nil))
               :changed (vconcat (or (plist-get entry :changed) nil))))))

(defun harness-board--near (board diagram id)
  "Return the objects of BOARD's DIAGRAM near object ID, nearest first.
Nearness is geometry only: it says where things are, never what they
mean to one another."
  (let* ((object (harness-board--object! board id))
         (view (harness-board--require-view board object diagram))
         (box (harness-board-view-box view))
         (cx (+ (nth 0 box) (/ (nth 2 box) 2.0)))
         (cy (+ (nth 1 box) (/ (nth 3 box) 2.0)))
         (others nil))
    (dolist (other (plist-get board :objects))
      (let ((other-view (harness-board--view other diagram)))
        (when (and other-view (not (equal (plist-get other :id) id)))
          (let* ((b (harness-board-view-box other-view))
                 (ox (- (+ (nth 0 b) (/ (nth 2 b) 2.0)) cx))
                 (oy (- (+ (nth 1 b) (/ (nth 3 b) 2.0)) cy)))
            (push (list :id (plist-get other :id)
                        :name (plist-get other :name)
                        :kind (plist-get other :kind)
                        :distance (round (sqrt (+ (* ox ox) (* oy oy)))))
                  others)))))
    (vconcat (cl-subseq (sort others (lambda (a b) (< (plist-get a :distance)
                                                     (plist-get b :distance))))
                        0 (min 8 (length others))))))

(harness-defmethod board/delete (id)
  "Delete board ID and its client state."
  (let ((board (harness-board--lookup id)))
    (delete-file (harness-board--path (plist-get board :id)))
    (when (file-exists-p (harness-board--views-path (plist-get board :id)))
      (delete-file (harness-board--views-path (plist-get board :id))))
    (harness-emit 'board/deleted (list :board (plist-get board :id)))
    t))

(harness-defmethod board/grammar ()
  "Return the board grammar: shapes, operations, styles, units and limits.
This is the only list of what a board can hold; a renderer, a theme and
an agent all read it, so nothing can draw what an edit could not build."
  (list :schema harness-board-schema
        :units (list :x "right" :y "down" :angle "clockwise degrees" :scale "positive")
        :limits (list :coordinate harness-board-max-coordinate
                      :movement harness-board-movement-budget
                      :undo-depth harness-board-history-limit)
        :shapes (vconcat
                 (cl-loop for kind in harness-board-shape-kinds
                          collect (list :kind kind :fields
                                        (pcase kind
                                          ("rect" ["w" "h"])
                                          ("image" ["w" "h" "src"])
                                          ("ellipse" ["rx" "ry"])
                                          ("polygon" ["points"])
                                          ("path" ["segments" "raw" "closed"])
                                          ("text" ["text" "size"])))))
        :path-commands (vconcat (mapcar (lambda (pair)
                                          (list :command (car pair) :numbers (cdr pair)))
                                        (harness-board--path-commands)))
        :objects (vconcat (cl-loop for (kind . doc) in harness-board-object-kinds
                                   collect (list :kind (symbol-name kind) :doc doc)))
        :operations (vconcat
                     (cl-loop for (kind . doc) in harness-board-op-kinds
                              collect (list :op (symbol-name kind) :doc doc)))
        :styles (vconcat (mapcar #'symbol-name harness-board-style-roles))
        :colors (vconcat harness-board-color-roles)
        :themes (vconcat (mapcar (lambda (theme)
                                   (list :name (symbol-name (car theme))
                                         :palette (harness-board--palette-data (cdr theme))))
                                 harness-board-themes))
        :resources (vconcat (cl-loop for (kind . doc) in harness-board-resource-kinds
                                     collect (list :kind (symbol-name kind) :doc doc)))
        :roles (vconcat (cl-loop for (role . doc) in harness-board-evidence-roles
                                 collect (list :role (symbol-name role) :doc doc)))
        :errors (vconcat (cl-loop for (kind . doc) in harness-board-error-kinds
                                  collect (list :error (symbol-name kind) :doc doc)))
        :transforms ["translate" "rotate" "scale" "reflect" "affine"]
        :constraints ["lock" "scope" "movement budget" "declared overlap"]
        :attachment-order ["reflect the child's growth axis"
                           "scale by the positive size"
                           "rotate clockwise by the angle"
                           "translate the child anchor onto the parent anchor"]))

(defun harness-board--palette-data (palette)
  "Return PALETTE, an alist of roles and colours, as a plist."
  (cl-loop for (role . colour) in palette
           append (list (intern (concat ":" (symbol-name role))) colour)))

;;;; Patching

(defun harness-board--canonical-ops (ops)
  "Return OPS, a list from the wire (a vector or a list), as a list."
  (cond ((null ops) nil)
        ((vectorp ops) (append ops nil))
        ((listp ops) ops)
        (t (harness-board--fail 'invalid-parameter "operations are an array: %S" ops))))

(harness-defmethod board/patch (id ops &optional opts)
  "Return the patch applying OPS to board ID: validated, not committed.
OPTS `:diagram' is the diagram the operations default to; `:scope' is
the list of object ids the batch may touch; `:session' is the writer.
The answer is a plist with `:patch', the patch id, `:hash', `:revision',
`:ops' (the expanded operations), `:created', `:changed', `:preimages',
`:diagnostics' and `:document', the board as it would read afterwards."
  (let ((board (harness-board--lookup id)))
    (harness-board--check-writer! board (plist-get opts :session))
    (harness-board--plan1 board (harness-board--canonical-ops ops) opts)))

(defun harness-board--plan-or-refuse (board ops scope &optional diagram)
  "Return the patch `harness-board-plan' makes, a refusal being a board error.
SCOPE, when non-nil, is the list of object ids the batch may touch.
DIAGRAM, when given, is filled in where an operation leaves it out."
  (setq ops (if diagram (harness-board--default-diagram board ops diagram) ops))
  (condition-case err
      (harness-board-plan board ops :scope (append scope nil))
    (harness-board-error
     (harness-board--fail (or (harness-board-error-kind err) 'invalid-parameter)
                          "%s" (harness-board-error-message err)))))

(defun harness-board--plan1 (board ops opts)
  "Return the answer `board/patch' gives for BOARD, OPS and OPTS."
  (let* ((diagram (or (plist-get opts :diagram)
                      (plist-get (car (plist-get board :diagrams)) :id)))
         (scope (append (plist-get opts :scope) nil))
         (ops (harness-board--default-diagram board ops diagram))
         (patch (harness-board--remember-patch
                 board (harness-board--plan-or-refuse board ops scope diagram))))
    (list :patch (plist-get patch :id)
          :hash (plist-get patch :hash)
          :board (plist-get board :id)
          :revision (plist-get board :revision)
          :base (plist-get board :revision)
          :ops (plist-get patch :ops)
          :requested (plist-get patch :requested)
          :created (plist-get patch :created)
          :changed (plist-get patch :changed)
          :preimages (harness-board--preimages-data (plist-get patch :preimages))
          :diagnostics (plist-get patch :diagnostics)
          :document (harness-board-document (plist-get patch :board) diagram))))

(defun harness-board--default-diagram (board ops diagram)
  "Return OPS with the diagram DIAGRAM filled in where an op leaves it out."
  (harness-board--diagram! board diagram)
  (mapcar (lambda (op)
            (let ((copy (copy-sequence op)))
              (dolist (key '(:diagram))
                (unless (plist-get copy key)
                  (setq copy (plist-put copy key diagram))))
              copy))
          ops))

(defun harness-board--preimages-data (preimages)
  "Return PREIMAGES, a plist, as a client reads it: a list of entries."
  (vconcat
   (cl-loop for (key entry) on preimages by #'cddr
            collect (list :id (substring (symbol-name key) 1)
                          :absent (and (consp entry) (plist-get entry :absent) t)
                          :entry (and (consp entry) (not (plist-get entry :absent)) entry)))))

(harness-defmethod board/preview (id ops &optional opts)
  "Render the exact batch OPS for board ID without changing anything.
The answer is `board/patch's, with `:preview' t and the patch's hash and
revision, so `board/commit' can name exactly this batch."
  (let* ((board (harness-board--lookup id))
         (answer (harness-board--plan1 board (harness-board--canonical-ops ops) opts)))
    (plist-put answer :preview t)))

(harness-defmethod board/commit (id patch-id hash expected &optional opts)
  "Apply a validated patch to board ID atomically.
PATCH-ID and HASH name the batch `board/patch' or `board/preview'
returned; EXPECTED is the revision the caller read; OPTS `:ops' carries
the operations again when the caller has no patch id, `:key' is the
idempotency key, `:session' the writer, `:diagram' and `:scope' as for
`board/patch'.  Return the answer `board/patch' gave, with `:committed'
t and the new `:revision'.
A key used before answers what it answered then.  A batch made against
another revision is refused (`stale-revision') rather than applied to a
board that moved; a batch naming no patch is revalidated whole."
  (let* ((board (harness-board--lookup id))
         (session (plist-get opts :session))
         (key (harness-board--string (plist-get opts :key)))
         (known (and key (plist-get (harness-board--keys board)
                                    (intern (concat ":" key))))))
    (harness-board--check-writer! board session)
    (cond
     (known
      (append (copy-sequence known) (list :idempotent t :committed t :key key)))
     (t
      (let ((want (harness-board--number expected "expected revision"))
            (current (plist-get board :revision)))
        (unless (= want current)
          (harness-board--fail 'stale-revision
                               "the board is at revision %s, not the %s this patch was made against"
                               current want))
        (let* ((ops (harness-board--canonical-ops (plist-get opts :ops)))
               (patch (if ops
                          (harness-board--remember-patch
                           board
                           (harness-board--plan-or-refuse
                            board ops (plist-get opts :scope)
                            (or (plist-get opts :diagram)
                                (plist-get (car (plist-get board :diagrams)) :id))))
                        (harness-board--patch-for board patch-id hash))))
          (harness-board--check-patch-names patch patch-id hash)
          (unless (= (plist-get patch :revision) current)
            (harness-board--fail 'stale-revision
                                 "the patch was made against revision %s; the board is at %s"
                                 (plist-get patch :revision) current))
          (let* ((next (harness-board-commit-patch board patch))
                 (answer (harness-board--commit-answer board patch))
                 (saved (if key (harness-board--remember-key next key answer) next)))
            (harness-board-save saved)
            (harness-emit 'board/changed
                          (list :board id
                                :revision (plist-get saved :revision)
                                :patch (plist-get patch :id)
                                :created (plist-get patch :created)
                                :changed (plist-get patch :changed)))
            (if key (plist-put answer :key key) answer))))))))

(defun harness-board--check-patch-names (patch patch-id hash)
  "Refuse PATCH when PATCH-ID or HASH names another batch."
  (when (and patch-id (not (equal patch-id (plist-get patch :id))))
    (harness-board--fail 'stale-revision
                         "patch %s is not the one these operations make (%s)"
                         patch-id (plist-get patch :id)))
  (when (and hash (not (equal hash (plist-get patch :hash))))
    (harness-board--fail 'stale-revision
                         "content hash %s does not cover these operations (%s)"
                         hash (plist-get patch :hash))))

(defconst harness-board--patch-cache (make-hash-table :test 'equal)
  "Patches `board/patch' made, keyed by board and patch id.
A patch is a draft until it commits or is forgotten; the cache only
saves re-validating the same batch, never bypasses validation.")

(defun harness-board--remember-patch (board patch)
  "Keep PATCH for BOARD, so a commit names exactly it."
  (puthash (cons (plist-get board :id) (plist-get patch :id)) patch
           harness-board--patch-cache)
  patch)

(defun harness-board--patch-for (board patch-id hash)
  "Return the patch PATCH-ID of BOARD, or refuse it.
A patch this Emacs made is kept in `harness-board--patch-cache'.  One
made before a restart is not, and the caller must name its operations
again -- which `board/commit' accepts, and revalidates."
  (let ((patch (and patch-id (gethash (cons (plist-get board :id) patch-id)
                                      harness-board--patch-cache))))
    (unless patch
      (harness-board--fail 'unknown-id
                           "no patch %s here; name the operations again to commit them"
                           (or patch-id "named")))
    (harness-board--check-patch-names patch patch-id hash)
    patch))

(defun harness-board--commit-answer (board patch)
  "Return the answer a commit of PATCH on BOARD gives."
  (let ((document (harness-board-document (plist-get patch :board)
                                          (plist-get (car (plist-get board :diagrams)) :id))))
    (list :patch (plist-get patch :id)
          :hash (plist-get patch :hash)
          :board (plist-get board :id)
          :revision (1+ (plist-get board :revision))
          :committed t
          :created (plist-get patch :created)
          :changed (plist-get patch :changed)
          :ops (plist-get patch :ops)
          :diagnostics (plist-get patch :diagnostics)
          :document document)))

;;;; Undo

(harness-defmethod board/undo (id &optional opts)
  "Take back the newest commit of board ID, or the one OPTS names.
OPTS `:revision' picks a commit (the newest by default); `:dry-run'
returns the operations without committing them; `:session' is the
writer.  The answer is the compensating batch, the conflicts an object
somebody else changed since raises, and, unless this is a dry run, the
new revision.  An object somebody else edited keeps their work."
  (let* ((board (harness-board--lookup id))
         (dry (harness-board--truthy (plist-get opts :dry-run))))
    (harness-board--check-writer! board (plist-get opts :session))
    (let* ((result (harness-board-undo-ops board (plist-get opts :revision)))
           (ops (car result))
           (conflicts (cdr result))
           (undone (or (plist-get opts :revision)
                       (plist-get (car (append (plist-get board :history) nil)) :revision))))
      (when (null ops)
        (harness-board--fail 'precondition "nothing to take back: %s"
                             (if conflicts "every object of the commit changed since"
                               "the board has no commits")))
      (let* ((restored (harness-board-restore-plan board ops))
             (patch (harness-board--plan-or-refuse
                     board
                     (mapcar (lambda (op)
                               (if (equal (plist-get op :op) "restore")
                                   (list :op "restore" :id (plist-get op :id)
                                         :entry (plist-get op :entry))
                                 op))
                             ops)
                     nil
                     (plist-get (car (plist-get board :diagrams)) :id))))
        (unless dry
          (let ((next (harness-board-commit-patch board patch)))
            (harness-board-save next)
            (harness-emit 'board/changed
                          (list :board id
                                :revision (plist-get next :revision)
                                :patch (plist-get patch :id)
                                :created (plist-get patch :created)
                                :changed (plist-get patch :changed)))))
        (list :patch (plist-get patch :id)
              :revision (if dry (plist-get board :revision)
                          (plist-get (plist-get patch :board) :revision))
              :undone undone
              :ops (vconcat ops)
              :conflicts (vconcat conflicts)
              :dry-run (and dry t)
              :document (harness-board-document
                         (if dry restored (plist-get patch :board))))))))

;;;; Pinned revisions: a delivered artifact

(harness-declare-event 'board/pinned
  "(:board ID :pin ID :revision N :diagram ID) after a board revision is pinned.")

(defun harness-board--pin-document (pin)
  "Return the document pin ID keeps, or nil when there is none."
  (let ((path (harness-board--pin-path pin)))
    (when (file-readable-p path)
      (harness-json-parse (harness-read-file path)))))

(defun harness-board--pins-of (board)
  "Return the pins of BOARD, newest first."
  (let ((dir (harness-board--pins-directory)))
    (if (not (file-directory-p dir))
        nil
      (sort (cl-loop for file in (directory-files dir t "\\.json\\'")
                     for pin = (ignore-errors
                                 (harness-json-parse (harness-read-file file)))
                     when (and (listp pin)
                               (equal (plist-get pin :board) board))
                     collect pin)
            (lambda (a b) (> (or (plist-get a :created) 0)
                             (or (plist-get b :created) 0)))))))

(defun harness-board--pin-snapshot (board)
  "Return BOARD as a pin keeps it: the document, without its history.
A pin is the artifact, so it keeps what the board held and not the
commits that made it: the history would be most of the bytes and is not
what was delivered."
  (harness-plist-remove (harness-plist-remove board :history) :writers))

(defun harness-board--pin-view (pin)
  "Return PIN as a client reads it: where it lands and what it holds."
  (let ((snapshot (plist-get pin :snapshot)))
    (list :id (plist-get pin :id)
          :board (plist-get pin :board)
          :task (plist-get pin :task)
          :title (plist-get pin :title)
          :revision (plist-get pin :revision)
          :diagram (plist-get pin :diagram)
          :object (plist-get pin :object)
          :created (plist-get pin :created)
          :objects (length (plist-get snapshot :objects))
          :name (plist-get snapshot :name)
          :theme (plist-get snapshot :theme)
          :diagrams (length (plist-get snapshot :diagrams))
          ;; The artifact is the pinned revision; the board it came from goes on
          ;; moving, so the two links stay apart.
          :target (harness-links-board-url (plist-get pin :board)
                                           (plist-get pin :diagram)
                                           (plist-get pin :object)
                                           :revision (plist-get pin :revision))
          :current (harness-links-board-url (plist-get pin :board)
                                            (plist-get pin :diagram)
                                            (plist-get pin :object)))))

(harness-defmethod board/pin (id &optional opts)
  "Pin board ID's revision as a delivered artifact, and return the pin.
OPTS `:task' is the task that delivered it, `:diagram' the landing diagram
\(the first by default), `:object' a place on it and `:title' what the
artifact is called.  The pin keeps its own copy of the document as it is
now, so later edits cannot rewrite what was delivered; `:current' in the
answer is the separate link to the board as it goes on.

The revision pinned is the board's current one.  A pin is written once
and never changed: pinning the same board again makes a second pin."
  (let* ((board (harness-board--lookup id))
         (diagram (or (plist-get opts :diagram)
                      (plist-get (car (plist-get board :diagrams)) :id)))
         (object (plist-get opts :object))
         (task (harness-board--string (plist-get opts :task)))
         (revision (or (plist-get opts :revision) (plist-get board :revision))))
    (harness-board--diagram! board diagram)
    (when object
      (let ((found (harness-board--object! board object)))
        (unless (harness-board--view found diagram)
          (harness-board--fail 'invalid-reference "%s has no view in %s" object diagram))))
    (let* ((pin (list :id (harness-board-new-id "pin")
                      :board (plist-get board :id)
                      :task task
                      :title (or (harness-board--string (plist-get opts :title))
                                 (plist-get board :name)
                                 (plist-get board :id))
                      :revision revision
                      :diagram diagram
                      :object object
                      :created (harness-now)
                      ;; The snapshot is the artifact: a copy, not a pointer
                      ;; into the live board, and not its history either.
                      :snapshot (harness-board--pin-snapshot board))))
      (harness-write-file-atomically (harness-board--pin-path (plist-get pin :id))
                                     (harness-json-encode-text pin))
      (harness-emit 'board/pinned
                    (list :board (plist-get board :id)
                          :pin (plist-get pin :id)
                          :revision revision
                          :diagram diagram))
      (harness-board--pin-view pin))))

(harness-defmethod board/pins (id &optional opts)
  "Return the pins of board ID, newest first.
OPTS `:task' keeps the ones a task delivered; `:pin' answers one pin with
the document it kept, as a client draws it, read from the snapshot and
not from the board."
  (let* ((board (harness-board--lookup id))
         (board-id (plist-get board :id))
         (wanted (harness-board--string (plist-get opts :pin))))
    (cond
     (wanted
      (let ((pin (harness-board--pin-document wanted)))
        (unless (and pin (equal (plist-get pin :board) board-id))
          (harness-board--fail 'unknown-id "no pin %s of board %s" wanted board-id))
        (let ((snapshot (harness-board-normalise-document (plist-get pin :snapshot))))
          (list :pin (harness-board--pin-view pin)
                ;; Drawn from the snapshot: an edit since cannot reach it.
                :document (harness-board-document snapshot (plist-get pin :diagram))
                :image (and (fboundp 'harness-board-svg)
                            (harness-board-svg snapshot (plist-get pin :diagram)))))))
     (t
      (let ((task (harness-board--string (plist-get opts :task))))
        (vconcat
         (cl-loop for pin in (harness-board--pins-of board-id)
                  when (or (null task) (equal (plist-get pin :task) task))
                  collect (harness-board--pin-view pin))))))))

;;;; Discussing a place on the board

;; A discussion is a native review thread of a task, not a comment store of
;; the board's own: the same threads the review shows, the same replies, the
;; same resolve.  What makes it a board thread is its meta -- the board, the
;; diagram, the object and the revision it was written against -- so the
;; anchor is the object's identity, which survives a move, a rename and a
;; resize, and the revision it keeps is the one that was discussed.
;;
;; Resolving a thread, accepting a diagram change and approving code stay
;; three separate actions: nothing here calls a review verdict.

(defun harness-board--anchor-data (board diagram object revision)
  "Return the meta a thread on BOARD's OBJECT in DIAGRAM keeps at REVISION."
  (list :board (plist-get board :id)
        :diagram diagram
        :object object
        :revision revision
        :name (and object
                   (plist-get (harness-board--object board object) :name))))

(defun harness-board--discuss-view (board data)
  "Return thread DATA of BOARD as a client reads it, with where it stands now.
The revision discussed and the board's revision now are both named: a
thread on a drawing that has moved since says so instead of pretending to
be about what is there."
  (let* ((meta (plist-get data :meta))
         (object (plist-get meta :object))
         (revision (plist-get meta :revision))
         (current (plist-get board :revision))
         (here (and object (harness-board--object board object)))
         (comments (or (plist-get data :comments) [])))
    (list :id (plist-get data :id)
          :status (plist-get data :status)
          :board (plist-get meta :board)
          :diagram (plist-get meta :diagram)
          :object object
          ;; The object's id is the anchor; its words are what to call it now.
          :name (or (and here (plist-get here :name))
                    (plist-get meta :name)
                    object)
          :revision revision
          :current current
          :stale (and revision (not (equal revision current)))
          :gone (and object (null here))
          :comments (length (append comments nil))
          :task (plist-get meta :task)
          :target (and (plist-get meta :task)
                       (harness-links-thread-url (plist-get meta :task)
                                                 (plist-get data :id))))))

(harness-defmethod board/discuss (id object &optional opts)
  "Start or answer a discussion on OBJECT of board ID, in its task's review.
OBJECT is an object of the board, a relationship, or the diagram itself
\(OPTS `:diagram' names it).  OPTS `:task' is the task whose review holds
the thread, `:diagram' the diagram the object is seen in, `:text' the
comment, `:thread' an existing thread to answer and `:session' the agent
writing.

The thread is a native review thread of that task, so it is resolved,
replied to and read in the review like any other.  Its meta keeps the
board, the diagram, the object and the revision it was written against;
the answer also says the board's revision now, so a reader can tell a
drawing that has moved since from one that has not.  Resolving the
thread, accepting a change to the drawing and approving code stay three
separate actions."
  (let* ((board (harness-board--lookup id))
         (task (or (harness-board--string (plist-get opts :task))
                   (harness-board--fail 'invalid-parameter
                                        "a discussion is a thread of a task's review: name :task")))
         (diagram (or (plist-get opts :diagram)
                      (plist-get (car (plist-get board :diagrams)) :id)))
         (object (harness-board--string object))
         (text (harness-board--string (plist-get opts :text)))
         (thread (harness-board--string (plist-get opts :thread))))
    (harness-board--diagram! board diagram)
    (unless (or (harness-board--object board object)
                (harness-board--relationship board object)
                (equal object diagram))
      (harness-board--fail 'unknown-id "no object, relationship or diagram %s here" object))
    (unless (harness-method-exists-p 'patch-review/board-thread)
      (harness-board--fail 'unsupported-operation "no review to discuss this board in"))
    (let* ((meta (harness-board--anchor-data board diagram object
                                             (plist-get board :revision)))
           (answer (harness-call 'patch-review/board-thread task (or text "")
                                 :thread thread
                                 :session (plist-get opts :session)
                                 :call-id (plist-get opts :call-id)
                                 :board (plist-get board :id)
                                 :diagram diagram
                                 :object object
                                 :revision (plist-get board :revision)
                                 :name (plist-get meta :name))))
      ;; The board remembers which reviews it is discussed in, so it can
      ;; find its threads again without reading every task's review.
      (let* ((views (or (copy-sequence (harness-board-load-views (plist-get board :id))) nil))
             (known (append (plist-get views :discussed) nil)))
        (harness-board-set-views
         (plist-get board :id)
         (plist-put views :discussed (vconcat (delete-dups (cons task known))))))
      (list :thread (plist-get answer :thread)
            :status (plist-get answer :status)
            :board (plist-get board :id)
            :diagram diagram
            :object object
            :revision (plist-get board :revision)
            :comment (plist-get answer :comment)
            :meta (or (plist-get answer :meta) meta)))))

(harness-defmethod board/discussions (id &optional opts)
  "Return the discussions of board ID: its objects' threads, newest first.
OPTS `:task' keeps one task's threads and `:object' one object's.  Each
says the revision it was written against and the board's revision now.

The board reads only the reviews it was discussed in -- the ones a
discussion named, kept in its client state -- and the tasks its objects
mark; it never scans every task's review."
  (let* ((board (harness-board--lookup id))
         (task (harness-board--string (plist-get opts :task)))
         (object (harness-board--string (plist-get opts :object))))
    (if (not (harness-method-exists-p 'patch-review/get))
        []
      (let ((tasks (if task (list task)
                     (delete-dups
                      (append (plist-get (harness-board-load-views
                                          (plist-get board :id))
                                         :discussed)
                              (cl-loop for item in (plist-get board :objects)
                                       for id = (plist-get item :task)
                                       when id collect id))))))
        (vconcat
         (cl-loop for one in tasks
                  for data = (ignore-errors (harness-call 'patch-review/get one))
                  when data
                  append (cl-loop for thread in (append (plist-get data :threads) nil)
                                  for meta = (plist-get thread :meta)
                                  when (and (equal (plist-get meta :board)
                                                   (plist-get board :id))
                                            (or (null object)
                                                (equal (plist-get meta :object) object)))
                                  collect (harness-board--discuss-view
                                           board (plist-put (copy-sequence thread)
                                                            :meta (plist-put (copy-sequence meta)
                                                                             :task one))))))))))

;;;; Following a place

(harness-defmethod board/focus (id &optional opts)
  "Ask a connected client to show a place on board ID.
OPTS `:diagram', `:object', `:revision' and `:client' name the place and
who should go there.  The place is kept, so a client that connects later
opens it, and `board/focused' is announced.  Return the place, and
whether a client was connected to hear it -- never that one was when none
was."
  (let* ((board (harness-board--lookup id))
         (diagram (or (plist-get opts :diagram)
                      (plist-get (car (plist-get board :diagrams)) :id)))
         (object (plist-get opts :object))
         (revision (or (plist-get opts :revision) (plist-get board :revision))))
    (harness-board--diagram! board diagram)
    (when object
      (let ((found (harness-board--object! board object)))
        (unless (harness-board--view found diagram)
          (harness-board--fail 'invalid-reference "%s has no view in %s" object diagram))))
    (let ((place (list :board (plist-get board :id)
                       :diagram diagram
                       :object object
                       :revision revision
                       :time (harness-now))))
      (harness-board-set-views
       (plist-get board :id)
       (plist-put (or (copy-sequence (harness-board-load-views (plist-get board :id))) nil)
                  :focus place))
      (harness-emit 'board/focused place)
      (plist-put place :client (and (harness-method-exists-p 'client/request) t)))))

(harness-defmethod board/link/describe (resource)
  "Return RESOURCE, a typed link of an object or relationship, resolved.
The answer is `harness-board-link-describe's: what the link names and
where it points now.  A client asks this for one link without reading
the whole board."
  (harness-board-link-describe resource))

(harness-defmethod board/views (id &optional opts)
  "Return the client state of board ID: viewports, selections and the last focus.
OPTS `:client' picks one client's state."
  (harness-board--lookup id)
  (let ((views (harness-board-load-views (harness-board--id id "board id"))))
    (if (plist-get opts :client)
        (plist-get views (intern (concat ":" (plist-get opts :client))))
      (or views nil))))

;;;; Which boards are a project's

(defun harness-board-for-project (&optional project)
  "Return the boards of PROJECT, newest first, as `board/list' reads them."
  (harness-call 'board/list (list :project project)))

;;;; The module

(harness-define-module 'board-store
  :doc "The board as the harness serves it: the documents kept under the state directory, the atomic commits with their idempotency keys, the client state navigation writes without a revision, and the bus methods the tools and clients call."
  :requires '(board board-edit store linking))

(provide 'harness-board-store)
;;; harness-board-store.el ends here
