;;; harness-session.el --- Session records and the conversation DAG  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session is a project-scoped conversation: settings, status, a
;; directed graph of nodes (messages, thinking, tool calls, hints), a
;; queue of messages waiting for the next turn, and pending requests
;; that block it.  Everything a UI shows about a session comes from
;; here through the bus; nothing here renders or calls a model.
;;
;; Persistence: sessions/ID.json holds the record, sessions/ID.nodes.jsonl
;; is an append-only log of nodes and node updates.  Node logs are
;; loaded lazily so listing a thousand sessions stays instant.
;;
;; Every session loads closed (`inactive'); opening one resumes it.  A
;; session saved `running' or `blocked' belonged to a harness that
;; stopped mid-turn (Emacs quit, `harness-restart', a crash), so loading
;; settles that turn: tool calls left without a result get one saying
;; they were interrupted, and a hint says what the session was doing.
;;
;; A session's context window is its model's, looked up in the provider
;; catalogue whenever the session is described, unless one was set for
;; the session (`:context-window' to `session/create' or
;; `session/update').  Only such a window is stored: a copy of the
;; catalogue's would go stale when the catalogue changes, or keep the
;; stand-in given for a model the catalogue had not listed yet.  When
;; the catalogue changes, the sessions whose window moved are announced.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar harness-default-model)
(defvar harness-state-directory)

(defcustom harness-session-save-delay 0.3
  "Seconds of quiet before a changed session record is written to disk."
  :type 'number :group 'harness)

(cl-defstruct (harness-session (:copier nil))
  id name kind project cwd host worktree model permission-mode thinking non-interactive
  allowed-dirs (status 'idle) parent-id fork-node created updated
  (usage (list :input 0 :output 0 :cache-read 0 :cache-write 0 :cost 0.0 :list-cost 0.0 :context 0 :turns 0))
  context-window                        ; one set for the session, else nil: the model's
  budget head queue pending todos plan provider-state
  ;; runtime only
  (nodes (make-hash-table :test 'equal))
  (loaded nil)
  (runtime nil))

(defvar harness-sessions (make-hash-table :test 'equal)
  "Session id -> `harness-session'.")

(defconst harness-session--public-keys
  '(:id :name :kind :project :cwd :host :worktree :model :permission-mode :thinking
    :non-interactive :allowed-dirs :status :parent-id :fork-node :created :updated :usage
    :context-window :context-window-override :budget :head :queue :pending :todos :plan
    :provider-state))

(defconst harness-session--symbol-keys '(:kind :status :permission-mode)
  "Keys whose values are symbols in memory and strings on disk.")

(defconst harness-session--settings
  '(:name :model :permission-mode :thinking :non-interactive :allowed-dirs :budget :context-window
    :cwd :host :worktree)
  "Keys `session/update' accepts.")

;;;; Conversions

(defun harness-session--get (id)
  "Return the session struct for ID or signal."
  (or (gethash id harness-sessions)
      (signal 'harness-error (list (format "No session %s" id)))))

(defun harness-session-plist (s)
  "Return the public plist of session struct S.
`:context-window' is the window in effect (see `harness-session--window'),
`:context-window-override' the one set for S, or nil."
  (list :id (harness-session-id s) :name (harness-session-name s)
        :kind (harness-session-kind s) :project (harness-session-project s)
        :cwd (harness-session-cwd s) :host (harness-session-host s)
        :worktree (harness-session-worktree s) :model (harness-session-model s)
        :permission-mode (harness-session-permission-mode s)
        :thinking (harness-session-thinking s)
        :non-interactive (harness-session-non-interactive s)
        :allowed-dirs (harness-session-allowed-dirs s)
        :status (harness-session-status s) :parent-id (harness-session-parent-id s)
        :fork-node (harness-session-fork-node s) :created (harness-session-created s)
        :updated (harness-session-updated s) :usage (harness-session-usage s)
        :context-window (harness-session--window s)
        :context-window-override (harness-session-context-window s)
        :budget (harness-session-budget s) :head (harness-session-head s)
        :queue (harness-session-queue s) :pending (harness-session-pending s)
        :todos (harness-session-todos s) :plan (harness-session-plan s)
        :provider-state (harness-session-provider-state s)))

(defun harness-session--intern-values (plist)
  "Turn string enum values in PLIST back into symbols."
  (let ((pl (copy-sequence plist)))
    (dolist (k harness-session--symbol-keys pl)
      (let ((v (plist-get pl k)))
        (when (stringp v) (setq pl (plist-put pl k (intern v))))))))

(defun harness-session--from-plist (plist)
  "Build a session struct from a stored PLIST."
  (let* ((pl (harness-session--intern-values plist))
         (s (make-harness-session)))
    (setf (harness-session-id s) (plist-get pl :id)
          (harness-session-name s) (plist-get pl :name)
          (harness-session-kind s) (or (plist-get pl :kind) 'main)
          (harness-session-project s) (plist-get pl :project)
          (harness-session-cwd s) (plist-get pl :cwd)
          (harness-session-host s) (plist-get pl :host)
          (harness-session-worktree s) (plist-get pl :worktree)
          (harness-session-model s) (plist-get pl :model)
          (harness-session-permission-mode s) (or (plist-get pl :permission-mode) 'ask)
          (harness-session-thinking s) (plist-get pl :thinking)
          (harness-session-non-interactive s) (harness-json-true-p (plist-get pl :non-interactive))
          (harness-session-allowed-dirs s) (let ((v (plist-get pl :allowed-dirs))) (and (listp v) v))
          (harness-session-status s) 'inactive
          (harness-session-parent-id s) (plist-get pl :parent-id)
          (harness-session-fork-node s) (plist-get pl :fork-node)
          (harness-session-created s) (or (plist-get pl :created) (float-time))
          (harness-session-updated s) (or (plist-get pl :updated) (float-time))
          (harness-session-usage s) (or (plist-get pl :usage) (harness-session-usage s))
          ;; Not `:context-window': that is the model's window as it was
          ;; when the record was written, and now comes from the catalogue.
          (harness-session-context-window s) (plist-get pl :context-window-override)
          (harness-session-budget s) (plist-get pl :budget)
          (harness-session-head s) (plist-get pl :head)
          (harness-session-queue s) (plist-get pl :queue)
          (harness-session-pending s) nil
          (harness-session-todos s) (plist-get pl :todos)
          (harness-session-plan s) (plist-get pl :plan)
          (harness-session-provider-state s) (plist-get pl :provider-state))
    s))

;;;; Persistence

(defun harness-session--meta-name (id) (format "sessions/%s.json" id))
(defun harness-session--nodes-name (id) (format "sessions/%s.nodes.jsonl" id))

(defun harness-session--save (id)
  "Write the record of session ID now."
  (let ((s (gethash id harness-sessions)))
    (when s
      (harness-call 'store/save (harness-session--meta-name id) (harness-session-plist s)))))

(defvar harness-session--announced-windows (make-hash-table :test 'equal)
  "Session id -> the context window its last `session/changed' carried.")

(defun harness-session--announce (s &optional plist)
  "Emit `session/changed' for S with PLIST, by default its plist now; return it."
  (let ((pl (or plist (harness-session-plist s))))
    (puthash (harness-session-id s) (plist-get pl :context-window) harness-session--announced-windows)
    (harness-emit 'session/changed (harness-session-id s) pl)
    pl))

(defun harness-session--touch (s)
  "Mark S changed: update the timestamp, schedule a save, emit `session/changed'."
  (setf (harness-session-updated s) (float-time))
  (harness-debounce (list 'harness-session (harness-session-id s))
                    harness-session-save-delay #'harness-session--save (harness-session-id s))
  (harness-session--announce s))

(defun harness-session-flush ()
  "Write every session record now (used on exit)."
  (maphash (lambda (id _) (ignore-errors (harness-session--save id))) harness-sessions))

(defun harness-session--intern-node (node)
  (let ((n (copy-sequence node)))
    (when (stringp (plist-get n :kind)) (setq n (plist-put n :kind (intern (plist-get n :kind)))))
    (when (plist-member n :is-error) (setq n (plist-put n :is-error (harness-json-true-p (plist-get n :is-error)))))
    n))

(defun harness-session--load-nodes (s)
  "Load the node log of S into memory if not yet done."
  (unless (harness-session-loaded s)
    (let ((table (harness-session-nodes s)))
      (dolist (rec (harness-call 'store/read-all (harness-session--nodes-name (harness-session-id s))))
        (let ((rec (harness-session--intern-node rec)))
          (if (equal (plist-get rec :_op) "update")
              (let ((existing (gethash (plist-get rec :id) table)))
                (when existing
                  (puthash (plist-get rec :id)
                           (harness-plist-merge existing (harness-plist-remove rec :_op))
                           table)))
            (puthash (plist-get rec :id) rec table)))))
    (setf (harness-session-loaded s) t)))

(defun harness-session--persist-node (s node &optional update)
  (harness-call 'store/append (harness-session--nodes-name (harness-session-id s))
                (if update (plist-put (copy-sequence node) :_op "update") node)))

;;;; Path helpers

(defun harness-session--path (s &optional head)
  "Return the nodes of S from the root to HEAD, oldest first.
HEAD defaults to the session head."
  (harness-session--load-nodes s)
  (let ((table (harness-session-nodes s))
        (id (or head (harness-session-head s)))
        (out nil) (seen (make-hash-table :test 'equal)))
    (while (and id (not (gethash id seen)))
      (puthash id t seen)
      (let ((n (gethash id table)))
        (if n
            (progn (push n out) (setq id (plist-get n :parent)))
          (setq id nil))))
    out))

(defun harness-session--config (key cwd)
  (if (harness-method-exists-p 'config/get)
      (ignore-errors (harness-call 'config/get key cwd))
    (and (boundp key) (symbol-value key))))

(defun harness-session--model-window (model)
  "Return the context window the provider catalogue gives MODEL."
  (or (and (harness-method-exists-p 'provider/model)
           (condition-case err
               (plist-get (harness-call 'provider/model model) :context-window)
             (error (harness-log 'debug "session: no context window for %s: %S" model err)
                    nil)))
      128000))

(defun harness-session--window (s)
  "Return the context window of S: the one set for it, else its model's."
  (or (harness-session-context-window s)
      (harness-session--model-window (harness-session-model s))))

(defun harness-session--model-levels (model)
  "Return the thinking levels the provider catalogue gives MODEL, or nil."
  (and model (harness-method-exists-p 'provider/model)
       (condition-case err
           (plist-get (harness-call 'provider/model model) :thinking-levels)
         (error (harness-log 'debug "session: no thinking levels for %s: %S" model err)
                nil))))

(defun harness-session--btw-thinking (model cwd)
  "Return the thinking level a BTW with MODEL at CWD starts at, or nil.
That is `harness-btw-thinking' as configured at CWD, provided the
provider catalogue lists it among MODEL's thinking levels: a model
without levels may refuse a request that asks for one.  nil leaves the
BTW the level it would have otherwise."
  (let ((level (harness-session--config 'harness-btw-thinking cwd)))
    (and (stringp level)
         (member level (harness-session--model-levels model))
         level)))

;;;; Methods: lifecycle

(harness-defmethod session/create (&rest plist)
  "Create a session.  PLIST needs `:cwd'; see docs/architecture.md for the rest.
A `btw' session without `:thinking' thinks at `harness-btw-thinking'
when its model offers that level, else at `harness-thinking', as
configured at `:cwd'."
  (let* ((cwd (or (plist-get plist :cwd) (error "session/create needs :cwd")))
         (host (or (plist-get plist :host) (file-remote-p cwd)))
         (cwd (file-name-as-directory (expand-file-name cwd)))
         (kind (or (plist-get plist :kind) 'main))
         (project (or (plist-get plist :project)
                      (if (harness-method-exists-p 'project/root) (harness-call 'project/root cwd) cwd)))
         (model (or (plist-get plist :model) (harness-session--config 'harness-model cwd)
                    (and (boundp 'harness-default-model) harness-default-model)))
         (s (make-harness-session)))
    (setf (harness-session-id s) (or (plist-get plist :id) (harness-uuid))
          (harness-session-name s) (plist-get plist :name)
          (harness-session-kind s) kind
          (harness-session-project s) project
          (harness-session-cwd s) cwd
          (harness-session-host s) host
          (harness-session-worktree s) (plist-get plist :worktree)
          (harness-session-model s) model
          (harness-session-permission-mode s) (or (plist-get plist :permission-mode)
                                                  (harness-session--config 'harness-permission-mode cwd) 'ask)
          (harness-session-thinking s) (or (plist-get plist :thinking)
                                           (and (eq kind 'btw) (harness-session--btw-thinking model cwd))
                                           (harness-session--config 'harness-thinking cwd))
          ;; Its own switch from now on: t or nil.  An explicit false
          ;; (`:false') turns it off whatever the setting says.
          (harness-session-non-interactive s) (harness-json-true-p
                                               (or (plist-get plist :non-interactive)
                                                   (harness-session--config 'harness-non-interactive cwd)))
          (harness-session-allowed-dirs s) (plist-get plist :allowed-dirs)
          (harness-session-status s) 'idle
          (harness-session-parent-id s) (plist-get plist :parent-id)
          (harness-session-fork-node s) (plist-get plist :fork-node)
          (harness-session-created s) (float-time)
          (harness-session-updated s) (float-time)
          (harness-session-context-window s) (plist-get plist :context-window)
          (harness-session-budget s) (or (plist-get plist :budget) (harness-session--config 'harness-budget cwd))
          (harness-session-provider-state s) (plist-get plist :provider-state)
          (harness-session-loaded s) t)
    (puthash (harness-session-id s) s harness-sessions)
    (harness-session--save (harness-session-id s))
    (let ((pl (harness-session-plist s)))
      (harness-emit 'session/created (harness-session-id s) pl)
      (harness-session--announce s pl))))

(harness-defmethod session/get (id)
  "Return the public plist of session ID."
  (harness-session-plist (harness-session--get id)))

(harness-defmethod session/exists-p (id)
  "Non-nil when session ID is known."
  (and (gethash id harness-sessions) t))

(harness-defmethod session/list (&optional filter)
  "Return session plists matching FILTER, newest first.
FILTER keys: :project :status :kind :parent-id :active."
  (let (out)
    (maphash
     (lambda (_ s)
       (when (and (or (null (plist-get filter :project))
                      (equal (plist-get filter :project) (harness-session-project s)))
                  (or (null (plist-get filter :status))
                      (eq (plist-get filter :status) (harness-session-status s)))
                  (or (null (plist-get filter :kind))
                      (eq (plist-get filter :kind) (harness-session-kind s)))
                  (or (null (plist-get filter :parent-id))
                      (equal (plist-get filter :parent-id) (harness-session-parent-id s)))
                  (or (null (plist-get filter :active))
                      (not (eq (harness-session-status s) 'inactive))))
         (push (harness-session-plist s) out)))
     harness-sessions)
    (sort out (lambda (a b) (> (plist-get a :updated) (plist-get b :updated))))))

(harness-defmethod session/delete (id)
  "Delete session ID and its files."
  (let ((s (harness-session--get id)))
    (harness-emit 'session/deleted id (harness-session-plist s))
    (remhash id harness-sessions)
    (remhash id harness-session--announced-windows)
    (harness-call 'store/delete (harness-session--meta-name id))
    (harness-call 'store/delete (harness-session--nodes-name id))
    t))

(harness-defmethod session/resume (id)
  "Make session ID active again (status idle) and load its nodes."
  (let ((s (harness-session--get id)))
    (harness-session--load-nodes s)
    (when (eq (harness-session-status s) 'inactive)
      (setf (harness-session-status s) 'idle)
      (harness-emit 'session/status id 'idle))
    (harness-emit 'session/resumed id)
    (harness-session--touch s)
    (harness-session-plist s)))

(harness-defmethod session/deactivate (id)
  "Mark session ID inactive (not open anywhere)."
  (let ((s (harness-session--get id)))
    (setf (harness-session-status s) 'inactive)
    (harness-emit 'session/status id 'inactive)
    (harness-emit 'session/deactivated id)
    (harness-session--touch s)
    (harness-session-plist s)))

(harness-defmethod session/set-status (id status)
  "Set the status of session ID to STATUS (idle, running, blocked, inactive).
The record is written at once rather than after `harness-session-save-delay',
so a harness that dies mid-turn leaves the session saved as running and the
next start settles its turn."
  (let ((s (harness-session--get id)))
    (unless (eq status (harness-session-status s))
      (setf (harness-session-status s) status)
      (harness-emit 'session/status id status)
      (harness-session--touch s)
      (harness-session--save id))
    status))

(defun harness-session--describe-change (key value)
  (pcase key
    (:name (format "renamed to %s" value))
    (:model (format "model → %s" value))
    (:permission-mode (format "permission mode → %s" value))
    (:thinking (format "thinking → %s" (or value "default")))
    (:non-interactive (format "non-interactive %s" (if (harness-json-true-p value) "on" "off")))
    (:budget (if value (format "budget → %s%s" (harness-format-cost (plist-get value :amount))
                               (if (plist-get value :hard) " (hard)" ""))
               "budget removed"))
    (:cwd (format "working directory → %s" (abbreviate-file-name value)))
    (_ nil)))

(harness-defmethod session/update (id &rest plist)
  "Change settings of session ID from PLIST (see `harness-session--settings').
With `:persist' non-nil, model, permission mode and thinking are also
written to the configuration layer.  With `:silent' no hint is added.
`:context-window' sets the session's own context window, nil its
model's again; a new `:model' brings its own window too, unless PLIST
also sets one."
  (let* ((s (harness-session--get id))
         (persist (plist-get plist :persist))
         (silent (plist-get plist :silent))
         changes)
    (cl-loop for (k v) on plist by #'cddr
             when (memq k harness-session--settings)
             do (pcase k
                  (:name (setf (harness-session-name s) v))
                  (:model (setf (harness-session-model s) v)
                          ;; A window set for the old model does not carry over.
                          (unless (plist-member plist :context-window)
                            (setf (harness-session-context-window s) nil)))
                  (:permission-mode (setf (harness-session-permission-mode s) (if (stringp v) (intern v) v)))
                  (:thinking (setf (harness-session-thinking s) v))
                  (:non-interactive (setf (harness-session-non-interactive s) (harness-json-true-p v)))
                  (:allowed-dirs (setf (harness-session-allowed-dirs s) (and (listp v) v)))
                  (:budget (setf (harness-session-budget s) v))
                  (:context-window (setf (harness-session-context-window s) v))
                  (:cwd (setf (harness-session-cwd s) (file-name-as-directory (expand-file-name v))))
                  (:host (setf (harness-session-host s) v))
                  (:worktree (setf (harness-session-worktree s) v)))
             (setq changes (plist-put changes k v)))
    (when (and persist (harness-method-exists-p 'config/set))
      (cl-loop for (k v) on changes by #'cddr
               for var = (pcase k (:model 'harness-model) (:permission-mode 'harness-permission-mode)
                                (:thinking 'harness-thinking) (:non-interactive 'harness-non-interactive))
               when var do (ignore-errors (harness-call 'config/set var v :cwd (harness-session-cwd s)))))
    (unless silent
      (cl-loop for (k v) on changes by #'cddr
               for text = (harness-session--describe-change k v)
               when text do (harness-call 'session/hint id text)))
    (harness-emit 'session/updated id changes)
    (harness-session--touch s)
    (harness-session-plist s)))

(harness-defmethod session/set-provider-state (id state)
  "Replace the opaque provider state of session ID with STATE."
  (let ((s (harness-session--get id)))
    (setf (harness-session-provider-state s) state)
    (harness-session--touch s)
    state))

(harness-defmethod session/runtime (id &optional key value)
  "Get or set the runtime (unpersisted) property KEY of session ID.
With only ID return the whole runtime plist."
  (let ((s (harness-session--get id)))
    (cond ((null key) (harness-session-runtime s))
          ((eq value :get) (plist-get (harness-session-runtime s) key))
          (t (setf (harness-session-runtime s) (plist-put (harness-session-runtime s) key value))
             value))))

;;;; Methods: forks, BTWs and trees

(harness-defmethod session/fork (id &rest plist)
  "Fork session ID; return a promise of the new session plist.
PLIST may set `:kind' (fork, subagent), `:name', `:cwd', `:model' and
any other `session/create' key.  The ancestor chain is copied so the
fork starts with the parent's transcript.  Its provider state is the
one `provider/fork' derives from the parent's, or none when the
provider cannot fork it.  It is never the parent's own state, which
would carry on the parent's provider conversation: for Claude Code,
resume and write into the parent's CLI session.  A BTW is no fork; see
`session/btw'."
  (let* ((parent (harness-session--get id))
         (path (harness-session--path parent))
         (child-plist (harness-plist-merge
                       (list :cwd (harness-session-cwd parent)
                             :host (harness-session-host parent)
                             :worktree (harness-session-worktree parent)
                             :model (harness-session-model parent)
                             :permission-mode (harness-session-permission-mode parent)
                             :thinking (harness-session-thinking parent)
                             ;; Off too, not left to the setting.
                             :non-interactive (if (harness-json-true-p (harness-session-non-interactive parent))
                                                  t :false)
                             :allowed-dirs (harness-session-allowed-dirs parent)
                             :budget (harness-session-budget parent)
                             :kind 'fork
                             :parent-id id
                             :fork-node (harness-session-head parent))
                       plist))
         (child (apply #'harness-call 'session/create child-plist))
         (cs (harness-session--get (plist-get child :id))))
    (dolist (n path)
      (puthash (plist-get n :id) n (harness-session-nodes cs))
      (harness-session--persist-node cs n))
    (setf (harness-session-head cs) (harness-session-head parent))
    (harness-session--save (harness-session-id cs))
    (harness-then
     (if (harness-method-exists-p 'provider/fork)
         (harness-catch (harness-call 'provider/fork (harness-session-model cs)
                                      (harness-session-provider-state parent))
                        (lambda (e)
                          (harness-log 'warn "provider fork failed, %s starts without provider state: %s"
                                       (harness-session-id cs) (harness-error-message e))
                          nil))
       (harness-resolved nil))
     (lambda (state)
       ;; Without a state of its own the fork has none, never the parent's.
       (when state (setf (harness-session-provider-state cs) state))
       (harness-session--save (harness-session-id cs))
       (harness-emit 'session/forked id (harness-session-id cs))
       (harness-session--touch cs)
       (harness-session-plist cs)))))

(harness-defmethod session/btw (id &optional name)
  "Start a BTW side conversation over session ID; return its session.
It is a new, empty session of kind `btw' named NAME, sharing nothing
with ID or with any other BTW, even one opened over ID before.  It has
no transcript and no fork node.  It has no provider state either, so
its first turn starts a provider conversation of its own (a new CLI
session for Claude Code).  It has no directory grants.  It works where
ID does, with ID's model: cwd, project, host, worktree, model and
permission mode are ID's, everything else is the configured default,
as for any new session.  It thinks at `harness-btw-thinking' as
configured there, a low level for quick questions, when the model
offers that level, else at ID's level.  Its `:parent-id' is ID only so
that the session list and the tree show it under ID."
  (let* ((parent (harness-session--get id))
         (cwd (harness-session-cwd parent))
         (model (harness-session-model parent)))
    (harness-call 'session/create
                  :kind 'btw :parent-id id :name name
                  :cwd cwd
                  :project (harness-session-project parent)
                  :host (harness-session-host parent)
                  :worktree (harness-session-worktree parent)
                  :model model
                  :thinking (or (harness-session--btw-thinking model cwd)
                                (harness-session-thinking parent))
                  :permission-mode (harness-session-permission-mode parent))))

(defun harness-session--family (s)
  "Return every session struct in the fork family of S."
  (let ((root s))
    (while (and (harness-session-parent-id root)
                (gethash (harness-session-parent-id root) harness-sessions))
      (setq root (gethash (harness-session-parent-id root) harness-sessions)))
    (let ((family (list root)) (frontier (list root)))
      (while frontier
        (let ((cur (pop frontier)))
          (maphash (lambda (_ c)
                     (when (and (equal (harness-session-parent-id c) (harness-session-id cur))
                                (not (memq c family)))
                       (push c family) (push c frontier)))
                   harness-sessions)))
      (sort family (lambda (a b) (< (harness-session-created a) (harness-session-created b)))))))

(harness-defmethod session/tree (id)
  "Return (:sessions SUMMARIES :nodes NODES) for the family of session ID.
Nodes shared by forks appear once, attributed to the session that
created them; every node carries `:session'."
  (let* ((s (harness-session--get id))
         (family (harness-session--family s))
         (seen (make-hash-table :test 'equal))
         nodes)
    (dolist (m family)
      (harness-session--load-nodes m)
      (maphash (lambda (nid n)
                 (unless (gethash nid seen)
                   (puthash nid t seen)
                   (push (plist-put (copy-sequence n) :session (harness-session-id m)) nodes)))
               (harness-session-nodes m)))
    (list :sessions (mapcar (lambda (m) (list :id (harness-session-id m) :name (harness-session-name m)
                                              :kind (harness-session-kind m) :head (harness-session-head m)
                                              :parent-id (harness-session-parent-id m)
                                              :fork-node (harness-session-fork-node m)
                                              :status (harness-session-status m)
                                              :created (harness-session-created m)))
                            family)
          :nodes (sort nodes (lambda (a b) (< (or (plist-get a :ts) 0) (or (plist-get b :ts) 0)))))))

;;;; Methods: nodes

(harness-defmethod session/nodes (id &optional opts)
  "Return the transcript nodes of session ID, oldest first.
OPTS `:limit' keeps the last N; `:before' NODE-ID returns the nodes
strictly before that node."
  (let* ((s (harness-session--get id))
         (path (harness-session--path s))
         (before (plist-get opts :before))
         (limit (plist-get opts :limit)))
    (when before
      (setq path (cl-loop for n in path until (equal (plist-get n :id) before) collect n)))
    (if (and limit (> (length path) limit)) (last path limit) path)))

(harness-defmethod session/node (id node-id)
  "Return node NODE-ID of session ID or nil."
  (let ((s (harness-session--get id)))
    (harness-session--load-nodes s)
    (gethash node-id (harness-session-nodes s))))

(harness-defmethod session/append (id node)
  "Append NODE to session ID after the current head; return the stored node."
  (let* ((s (harness-session--get id))
         (n (copy-sequence node)))
    (harness-session--load-nodes s)
    (setq n (plist-put n :id (or (plist-get n :id) (concat "n-" (harness-short-id 10)))))
    (setq n (plist-put n :session id))
    (setq n (plist-put n :ts (or (plist-get n :ts) (float-time))))
    (setq n (plist-put n :parent (harness-session-head s)))
    (puthash (plist-get n :id) n (harness-session-nodes s))
    (setf (harness-session-head s) (plist-get n :id))
    (harness-session--persist-node s n)
    (harness-emit 'session/node-added id n)
    (harness-session--touch s)
    n))

(harness-defmethod session/update-node (id node-id &rest plist)
  "Merge PLIST into node NODE-ID of session ID; return the node.
With `:transient' non-nil the change is announced but not persisted
\(streaming deltas); the final update persists."
  (let* ((s (harness-session--get id))
         (transient (plist-get plist :transient))
         (changes (harness-plist-remove plist :transient))
         (n (progn (harness-session--load-nodes s) (gethash node-id (harness-session-nodes s)))))
    (unless n (signal 'harness-error (list (format "No node %s in %s" node-id id))))
    (setq n (harness-plist-merge n changes))
    (puthash node-id n (harness-session-nodes s))
    (unless transient
      (harness-session--persist-node s (plist-put (copy-sequence changes) :id node-id) t))
    (harness-emit 'session/node-updated id n (and transient t))
    n))

(harness-defmethod session/set-head (id node-id)
  "Move the head of session ID to NODE-ID (time travel within the DAG)."
  (let ((s (harness-session--get id)))
    (harness-session--load-nodes s)
    (unless (gethash node-id (harness-session-nodes s))
      (signal 'harness-error (list (format "No node %s" node-id))))
    (setf (harness-session-head s) node-id)
    (harness-emit 'session/head-moved id node-id)
    (harness-session--touch s)
    node-id))

(harness-defmethod session/hint (id text)
  "Append a system hint TEXT to session ID."
  (harness-call 'session/append id (list :kind 'hint :content text)))

;;;; Methods: queue, pending, usage, todos, plan

(harness-defmethod session/queue (id text &optional attachments)
  "Queue TEXT with ATTACHMENTS for the next turn of session ID; return the item."
  (let* ((s (harness-session--get id))
         (item (list :id (harness-short-id 6) :text text :attachments attachments :ts (float-time))))
    (setf (harness-session-queue s) (append (harness-session-queue s) (list item)))
    (harness-emit 'session/queue-changed id (harness-session-queue s))
    (harness-session--touch s)
    item))

(harness-defmethod session/queue-update (id qid text &optional attachments)
  "Replace the text (and attachments when given) of queued item QID in session ID."
  (let ((s (harness-session--get id)))
    (setf (harness-session-queue s)
          (mapcar (lambda (it)
                    (if (equal (plist-get it :id) qid)
                        (let ((it (plist-put (copy-sequence it) :text text)))
                          (if attachments (plist-put it :attachments attachments) it))
                      it))
                  (harness-session-queue s)))
    (harness-emit 'session/queue-changed id (harness-session-queue s))
    (harness-session--touch s)
    (harness-session-queue s)))

(harness-defmethod session/queue-remove (id qid)
  "Remove queued item QID from session ID."
  (let ((s (harness-session--get id)))
    (setf (harness-session-queue s)
          (cl-remove qid (harness-session-queue s) :key (lambda (it) (plist-get it :id)) :test #'equal))
    (harness-emit 'session/queue-changed id (harness-session-queue s))
    (harness-session--touch s)
    (harness-session-queue s)))

(harness-defmethod session/queue-take (id)
  "Return and clear the queued items of session ID."
  (let* ((s (harness-session--get id))
         (items (harness-session-queue s)))
    (setf (harness-session-queue s) nil)
    (when items
      (harness-emit 'session/queue-changed id nil)
      (harness-session--touch s))
    items))

(defun harness-session--reconcile-status (s)
  "Enter or leave `blocked' as pending requests come and go."
  (let ((id (harness-session-id s)))
    (cond ((and (harness-session-pending s) (not (eq (harness-session-status s) 'blocked)))
           (setf (harness-session-runtime s)
                 (plist-put (harness-session-runtime s) :status-before-block (harness-session-status s)))
           (setf (harness-session-status s) 'blocked)
           (harness-emit 'session/status id 'blocked))
          ((and (null (harness-session-pending s)) (eq (harness-session-status s) 'blocked))
           (let ((prev (or (plist-get (harness-session-runtime s) :status-before-block) 'idle)))
             (setf (harness-session-status s) prev)
             (harness-emit 'session/status id prev))))))

(harness-defmethod session/pending-add (id request)
  "Register a blocking REQUEST (:kind permission|question :payload …) on ID.
Return the pending id.  The session becomes `blocked'."
  (let* ((s (harness-session--get id))
         (item (harness-plist-merge (list :id (harness-short-id 6) :created (float-time)) request)))
    (setf (harness-session-pending s) (append (harness-session-pending s) (list item)))
    (harness-session--reconcile-status s)
    (harness-emit 'session/pending-changed id (harness-session-pending s))
    (harness-session--touch s)
    (plist-get item :id)))

(harness-defmethod session/pending-resolve (id pid answer)
  "Remove pending request PID from session ID with ANSWER; return the item or nil."
  (let* ((s (harness-session--get id))
         (item (cl-find pid (harness-session-pending s) :key (lambda (it) (plist-get it :id)) :test #'equal)))
    (when item
      (setf (harness-session-pending s)
            (cl-remove pid (harness-session-pending s) :key (lambda (it) (plist-get it :id)) :test #'equal))
      (harness-session--reconcile-status s)
      (harness-emit 'session/pending-resolved id item answer)
      (harness-emit 'session/pending-changed id (harness-session-pending s))
      (harness-session--touch s))
    item))

(harness-defmethod session/pending (id)
  "Return the pending requests of session ID."
  (harness-session-pending (harness-session--get id)))

(defun harness-session--price-record (model record)
  "Return RECORD for MODEL with a missing `:cost' and `:list-cost' priced.
The cost is what was billed and the list cost what the call costs at
API prices: the same thing unless a subscription paid, when only the
list cost needs pricing.  Records without tokens are returned as is."
  (if (not (or (plist-get record :input) (plist-get record :output)))
      record
    (let* ((priced 'unset)
           (price (lambda ()
                    (when (eq priced 'unset)
                      (setq priced (and (harness-method-exists-p 'usage/price)
                                        (ignore-errors (harness-call 'usage/price model record)))))
                    priced))
           (cost (plist-get record :cost))
           (cost (if (numberp cost) cost (funcall price)))
           (list-cost (plist-get record :list-cost))
           (list-cost (cond ((numberp list-cost) list-cost)
                            ((eq (harness-billing-of record) 'subscription) (funcall price))
                            (t cost))))
      (harness-plist-merge record (list :cost cost :list-cost list-cost)))))

(harness-defmethod session/usage-add (id record)
  "Add usage RECORD to session ID.
RECORD keys: :input :output :cache-read :cache-write :cost :list-cost
:context :turns, and :billing and :plan saying how the call was paid.
Counters accumulate; `:context' replaces, and so do `:billing' and
`:plan' when RECORD has a billing.  A missing `:cost' is priced from
the model catalogue; a missing `:list-cost', the call at API prices,
is the cost, or priced when a subscription paid.  Return the totals."
  (let* ((s (harness-session--get id))
         (u (copy-sequence (harness-session-usage s)))
         (record (harness-session--price-record (harness-session-model s) record)))
    ;; Totals from before list costs were kept count as list cost too.
    (when (and (numberp (plist-get record :list-cost)) (not (numberp (plist-get u :list-cost))))
      (setq u (plist-put u :list-cost (float (or (plist-get u :cost) 0)))))
    (dolist (k '(:input :output :cache-read :cache-write :cost :list-cost :turns))
      (when (numberp (plist-get record k))
        (setq u (plist-put u k (+ (or (plist-get u k) 0) (plist-get record k))))))
    (when (numberp (plist-get record :context))
      (setq u (plist-put u :context (plist-get record :context))))
    (when (harness-billing-of record)
      (setq u (plist-put u :billing (harness-billing-of record)))
      (setq u (plist-put u :plan (plist-get record :plan))))
    (setf (harness-session-usage s) u)
    (harness-emit 'session/usage id u record)
    (harness-session--touch s)
    u))

(harness-defmethod session/set-todos (id todos)
  "Replace the todo list of session ID with TODOS."
  (let ((s (harness-session--get id)))
    (setf (harness-session-todos s) todos)
    (harness-emit 'session/todos id todos)
    (harness-session--touch s)
    todos))

(harness-defmethod session/set-plan (id text)
  "Set the current plan TEXT of session ID."
  (let ((s (harness-session--get id)))
    (setf (harness-session-plan s) text)
    (harness-emit 'session/plan id text)
    (harness-session--touch s)
    text))

;;;; Methods: derived views

(defun harness-session--text-blocks (node)
  (or (plist-get node :blocks)
      (list (list :type "text" :text (or (plist-get node :content) "")))))

(defun harness-session--delivered (path)
  "Return (MOVED . AFTER) for the steering messages PATH shows later.
A steering message (a user node) whose `:delivered-after' node comes
after it on PATH reached the model there.  MOVED holds the ids of those
messages; AFTER maps each such node's id to its messages, oldest first.
A message delivered after a node missing from PATH stays where it is."
  (let ((pos (make-hash-table :test 'equal))
        (moved (make-hash-table :test 'equal))
        (after (make-hash-table :test 'equal))
        (i 0))
    (dolist (n path) (puthash (plist-get n :id) (cl-incf i) pos))
    (dolist (n path)
      (let ((anchor (and (eq (plist-get n :kind) 'user)
                         (plist-get (plist-get n :meta) :delivered-after))))
        (when (and anchor (> (gethash anchor pos 0) (gethash (plist-get n :id) pos)))
          (puthash (plist-get n :id) t moved)
          (puthash anchor (append (gethash anchor after) (list n)) after))))
    (cons moved after)))

(harness-defmethod session/messages (id)
  "Return provider messages (:role :content BLOCKS) for the transcript of ID.
Adjacent assistant-side nodes merge into one assistant message; tool
results become user messages with tool_result blocks; the transcript
starts at the last compaction node when one exists.  A steering message
stands where the model got it, after its `:delivered-after' node and
the tool results right after that, not where it was sent mid-step."
  (let* ((s (harness-session--get id))
         (path (harness-session--path s))
         (start (cl-position-if (lambda (n) (eq (plist-get n :kind) 'compaction)) path :from-end t))
         (path (if start (nthcdr start path) path))
         (delivered (harness-session--delivered path))
         (ready nil)
         (messages nil) (cur nil) (cur-role nil))
    (cl-labels ((flush () (when cur
                            (push (list :role cur-role :content (nreverse cur)) messages)
                            (setq cur nil cur-role nil)))
                (add (role block)
                  (unless (eq role cur-role) (setq cur nil cur-role role))
                  (push block cur))
                (user (n) (unless (eq cur-role 'user) (flush))
                      (dolist (b (harness-session--text-blocks n)) (add 'user b))))
      (dolist (n path)
        ;; Delivered steering goes in before the next node that is not a
        ;; tool result: tool results come first in the user message.
        (when (and ready (memq (plist-get n :kind) '(user assistant thinking tool-call plan compaction)))
          (mapc #'user ready)
          (setq ready nil))
        (pcase (and (not (gethash (plist-get n :id) (car delivered))) (plist-get n :kind))
          ('user (user n))
          ('compaction (flush)
                       (add 'user (list :type "text"
                                        :text (concat "Summary of the conversation so far:\n\n"
                                                      (plist-get n :content)))))
          ('assistant (unless (eq cur-role 'assistant) (flush))
                      (unless (harness-string-blank-p (plist-get n :content))
                        (add 'assistant (list :type "text" :text (plist-get n :content)))))
          ('thinking (unless (eq cur-role 'assistant) (flush))
                     (unless (harness-string-blank-p (plist-get n :content))
                       (add 'assistant (list :type "thinking" :text (plist-get n :content)
                                             :signature (plist-get (plist-get n :meta) :signature)))))
          ('tool-call (unless (eq cur-role 'assistant) (flush))
                      (add 'assistant (list :type "tool_use" :id (plist-get n :call-id)
                                            :name (plist-get n :tool) :input (or (plist-get n :input) :empty))))
          ('tool-result (unless (eq cur-role 'user) (flush))
                        (add 'user (list :type "tool_result" :tool_use_id (plist-get n :call-id)
                                         :content (or (plist-get n :output) "")
                                         :is_error (and (plist-get n :is-error) t))))
          ('plan (unless (eq cur-role 'assistant) (flush))
                 (add 'assistant (list :type "text" :text (concat "Plan:\n" (plist-get n :content)))))
          (_ nil))
        (setq ready (append ready (gethash (plist-get n :id) (cdr delivered)))))
      (mapc #'user ready)
      (flush))
    (nreverse messages)))

(harness-defmethod session/transcript-text (id)
  "Return the transcript of session ID as searchable plain text."
  (mapconcat (lambda (n)
               (pcase (plist-get n :kind)
                 ('tool-call (format "[tool %s] %s" (plist-get n :tool) (or (plist-get n :title) "")))
                 ('tool-result (format "[result] %s" (or (plist-get n :output) "")))
                 (k (format "[%s] %s" k (or (plist-get n :content) "")))))
             (harness-session--path (harness-session--get id)) "\n"))

;;;; Init and reload

(defconst harness-session-interrupted-output
  "Interrupted: the harness stopped before this tool call finished."
  "Result recorded for a tool call that a stopped harness never finished.")

(defun harness-session--interrupted-text (pending)
  "Describe what a session stopped mid-turn was doing.
PENDING is the list of requests it was saved waiting on."
  (let* ((item (car pending))
         (kind (plist-get item :kind))
         (payload (plist-get item :payload)))
    (concat "Interrupted: the harness stopped "
            (pcase (if (stringp kind) (intern kind) kind)
              ('question (format "while waiting for an answer to: %s"
                                 (harness-first-line (plist-get payload :question) 200)))
              ('permission (format "while waiting for permission: %s"
                                   (or (plist-get payload :title) (plist-get payload :tool) "a tool call")))
              (_ "during this turn")))))

(defun harness-session--settle (s pending)
  "Close the turn of S that a stopped harness left unfinished.
S was saved running or blocked, with PENDING the requests it waited on.
Every tool call without a result gets one saying it was interrupted --
providers that pair calls with results reject a transcript with an
unanswered call -- and a hint says what the session was doing.  The
requests themselves are gone: the turn that would read their answers
ended with the process."
  (let ((id (harness-session-id s))
        (path (harness-session--path s))
        (answered (make-hash-table :test 'equal)))
    (dolist (n path)
      (when (eq (plist-get n :kind) 'tool-result)
        (puthash (plist-get n :call-id) t answered)))
    (dolist (n path)
      (when (and (eq (plist-get n :kind) 'tool-call)
                 (not (gethash (plist-get n :call-id) answered)))
        (harness-call 'session/append id
                      (list :kind 'tool-result :call-id (plist-get n :call-id)
                            :output harness-session-interrupted-output :is-error t
                            :meta (list :interrupted t)))))
    (harness-call 'session/hint id (harness-session--interrupted-text pending))
    ;; Saved inactive now, so the next start does not settle it again.
    (harness-session--save id)))

(defun harness-session--load-all ()
  "Load every persisted session record (nodes stay on disk until needed).
Sessions saved mid-turn are settled with `harness-session--settle'."
  (let (interrupted)
    (dolist (name (harness-call 'store/list "sessions" "\\.json\\'"))
      (let ((pl (harness-call 'store/load name)))
        (when (and pl (plist-get pl :id) (not (gethash (plist-get pl :id) harness-sessions)))
          (let ((s (harness-session--from-plist pl)))
            (puthash (plist-get pl :id) s harness-sessions)
            (when (member (plist-get pl :status) '("running" "blocked"))
              (push (cons s (plist-get pl :pending)) interrupted))))))
    (dolist (entry interrupted)
      (condition-case err
          (harness-session--settle (car entry) (cdr entry))
        (error (harness-log 'warn "session %s: could not settle its interrupted turn: %S"
                            (harness-session-id (car entry)) err))))))

(defun harness-session--on-kill-emacs () (harness-session-flush))

(defun harness-session--on-models-updated (&rest _)
  "Announce the sessions whose context window changed with the model catalogue."
  (let (moved)
    (maphash (lambda (id s)
               (unless (eql (harness-session--window s) (gethash id harness-session--announced-windows))
                 (push s moved)))
             harness-sessions)
    (mapc #'harness-session--announce moved)))

(defun harness-session--init ()
  (harness-session--load-all)
  (harness-on 'provider/models-updated #'harness-session--on-models-updated)
  (add-hook 'kill-emacs-hook #'harness-session--on-kill-emacs))

;; A reload does not run `:init' again for a ready module, so the
;; subscription is made here too.
(harness-on 'provider/models-updated #'harness-session--on-models-updated)

;; The context-window slot of sessions loaded by an earlier version of
;; this file holds a copy of their model's window, or the stand-in for
;; a model the catalogue had not listed yet: no window set for them.
;; The first load of this version in a running harness drops them.
(defvar harness-session--window-slot-holds-overrides nil
  "Non-nil once the context-window slot of loaded sessions holds only overrides.")
(unless harness-session--window-slot-holds-overrides
  (maphash (lambda (_ s) (setf (harness-session-context-window s) nil)) harness-sessions)
  (setq harness-session--window-slot-holds-overrides t))

(dolist (ev '((session/created . "(ID SESSION)")
              (session/changed . "(ID SESSION) after any change")
              (session/updated . "(ID CHANGES) settings changed")
              (session/status . "(ID STATUS)")
              (session/deleted . "(ID SESSION)") (session/resumed . "(ID)") (session/deactivated . "(ID)")
              (session/forked . "(PARENT-ID CHILD-ID)")
              (session/node-added . "(ID NODE)") (session/node-updated . "(ID NODE TRANSIENT)")
              (session/head-moved . "(ID NODE-ID)")
              (session/queue-changed . "(ID ITEMS)") (session/pending-changed . "(ID ITEMS)")
              (session/pending-resolved . "(ID ITEM ANSWER)")
              (session/usage . "(ID TOTALS RECORD)") (session/todos . "(ID TODOS)") (session/plan . "(ID TEXT)")))
  (harness-declare-event (car ev) (cdr ev)))

(harness-define-module 'session
  :doc "Session records, conversation DAG, queue and pending requests."
  :requires '(store project)
  :init #'harness-session--init
  :shutdown #'harness-session-flush)

(provide 'harness-session)
;;; harness-session.el ends here
