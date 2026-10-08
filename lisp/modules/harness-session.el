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
;; A fork copies its parent's transcript and settles it the same way:
;; forked mid-turn (a `spawn_agent' call forking its session, say), it
;; copies calls whose results only ever reach the parent, so each gets
;; a result in the fork.  `session/messages' makes sure of the same
;; for every request, whatever the path holds: a provider that pairs
;; tool calls with results, as DeepSeek does, rejects a request with
;; an unanswered call.
;;
;; A hosted-loop provider (Claude Code, Copilot) keeps the conversation
;; itself, so the transcript and that conversation must agree.  Nodes
;; carry the provider's `:checkpoint' where it reported one (for Claude
;; Code the CLI session and message uuid holding them), and the session
;; remembers the node its provider conversation reached
;; (`provider-node').  When the head moves off that conversation (a
;; checkout at an earlier node) or a fork starts at an earlier node,
;; the conversation is cut at the last checkpoint up to the node, or
;; started anew from the transcript (`harness-session--continuation'),
;; so the model never knows what came after the node.
;;
;; A session's context window is its model's, looked up in the provider
;; catalogue whenever the session is described, unless one was set for
;; the session (`:context-window' to `session/create' or
;; `session/update').  Only such a window is stored: a copy of the
;; catalogue's would go stale when the catalogue changes, or keep the
;; stand-in given for a model the catalogue had not listed yet.  When
;; the catalogue changes, the sessions whose window moved are announced.
;;
;; Every local session has a temporary directory of its own,
;; harness-UID/ID in `temporary-file-directory' (/tmp/harness-1000/ID/).
;; It is made with the session, made again whenever it is asked for and
;; missing (a reboot empties /tmp), and deleted with the session.
;; `session/tmp-dir' hands it out: the permission layer lets the session
;; use it, the sandbox lets its commands write there, and the system
;; prompt names it.  /tmp is shared, so only a directory that is the
;; user's own is ever handed out.
;;
;; A session may instead cap its context window at a number of tokens
;; (`:context-window-limit' to `session/create' or `session/update'):
;; the window in effect is then the smaller of the model's and the
;; limit, computed afresh so a model change moves it too.  Task
;; sessions use this to compact earlier than interactive ones (see
;; `harness-tasks-context-limit').  A `:context-window' set outright
;; for the session wins over the limit, being the more explicit choice.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar harness-state-directory)
(defvar harness-provider-fallback-context-window)
(defvar harness-cache-ttl)

(defconst harness-session--save-delay 0.3
  "Seconds of quiet before a changed session record is written to disk.")

(cl-defstruct (harness-session (:copier nil))
  id name kind project cwd host worktree model permission-mode thinking non-interactive
  allowed-dirs (status 'idle) parent-id fork-node created updated
  (usage (list :input 0 :output 0 :cache-read 0 :cache-write 0 :cost 0.0 :list-cost 0.0 :context 0 :turns 0))
  context-window                        ; one set for the session, else nil: the model's
  context-window-limit                  ; most tokens of context, else nil: the model's
  budget head queue pending todos plan provider-state
  ;; runtime only
  (nodes (make-hash-table :test 'equal))
  (loaded nil)
  (runtime nil)
  ;; Slots added later go last, see `harness-session--upgrade-records'.
  provider-node)                        ; the node its provider conversation reached

(defvar harness-sessions (make-hash-table :test 'equal)
  "Session id -> `harness-session'.")

(defun harness-session--upgrade-records ()
  "Give the sessions in memory the slots the struct gained since they were made.
A reload replaces the definitions under the running sessions, and a
record made by an earlier layout is too short for the slots added at
the end: it is copied into a new record whose new slots keep their
defaults."
  (let ((size (length (make-harness-session)))
        (old nil))
    (maphash (lambda (id s) (when (< (length s) size) (push (cons id s) old))) harness-sessions)
    (pcase-dolist (`(,id . ,s) old)
      (let ((new (make-harness-session)))
        (dotimes (i (1- (length s)))
          (aset new (1+ i) (aref s (1+ i))))
        (puthash id new harness-sessions)))))

(harness-session--upgrade-records)

(defconst harness-session--public-keys
  '(:id :name :kind :project :cwd :host :worktree :model :permission-mode :thinking
    :non-interactive :allowed-dirs :status :parent-id :fork-node :created :updated :usage
    :context-window :context-window-override :context-window-limit :budget :head :queue :pending
    :todos :plan :provider-state :provider-node :cache))

(defconst harness-session--symbol-keys '(:kind :status :permission-mode)
  "Keys whose values are symbols in memory and strings on disk.")

(defconst harness-session--settings
  '(:name :model :permission-mode :thinking :non-interactive :allowed-dirs :budget :context-window
    :context-window-limit :cwd :host :worktree)
  "Keys `session/update' accepts.")

;;;; Conversions

(defun harness-session--get (id)
  "Return the session struct for ID or signal."
  (or (gethash id harness-sessions)
      (signal 'harness-error (list (format "No session %s" id)))))

(defun harness-session-plist (s)
  "Return the public plist of session struct S.
`:context-window' is the window in effect (see `harness-session--window');
`:context-window-override' and `:context-window-limit' are what was set
for S, and are nil when unset.  `:cache' is what is known of its prompt
cache (see `harness-session--cache')."
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
        :context-window-limit (harness-session-context-window-limit s)
        :budget (harness-session-budget s) :head (harness-session-head s)
        :queue (harness-session-queue s) :pending (harness-session-pending s)
        :todos (harness-session-todos s) :plan (harness-session-plan s)
        :provider-state (harness-session-provider-state s)
        :provider-node (harness-session-provider-node s)
        :cache (harness-session--cache s)))

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
          (harness-session-context-window-limit s)
          (harness-session--context-window-limit-value (plist-get pl :context-window-limit))
          (harness-session-budget s) (plist-get pl :budget)
          (harness-session-head s) (plist-get pl :head)
          (harness-session-queue s) (plist-get pl :queue)
          (harness-session-pending s) nil
          (harness-session-todos s) (plist-get pl :todos)
          (harness-session-plan s) (plist-get pl :plan)
          (harness-session-provider-state s) (plist-get pl :provider-state)
          (harness-session-provider-node s) (plist-get pl :provider-node))
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
                    harness-session--save-delay #'harness-session--save (harness-session-id s))
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

(defun harness-session--from-compaction (path)
  "Return PATH from its last compaction node on, or all of it without one.
That is the part of a transcript `session/messages' sends: the summary
in the compaction node stands for everything before it."
  (let ((start (cl-position-if (lambda (n) (eq (plist-get n :kind) 'compaction)) path :from-end t)))
    (if start (nthcdr start path) path)))

(defun harness-session--unanswered (path)
  "Return the tool-call nodes on PATH that no tool result on PATH answers.
Only the calls from the last compaction on count: the ones before it
reach no provider, and a result added for one would answer nothing."
  (let ((path (harness-session--from-compaction path))
        (answered (make-hash-table :test 'equal)))
    (dolist (n path)
      (when (eq (plist-get n :kind) 'tool-result)
        (puthash (plist-get n :call-id) t answered)))
    (cl-remove-if-not (lambda (n) (and (eq (plist-get n :kind) 'tool-call)
                                       (not (gethash (plist-get n :call-id) answered))))
                      path)))

(defun harness-session--answer (id calls result)
  "Append a tool result to session ID for each tool-call node in CALLS.
RESULT, called with a call node, returns the rest of its result node:
`:output', `:is-error', `:meta'."
  (dolist (call calls)
    (harness-call 'session/append id
                  (append (list :kind 'tool-result :call-id (plist-get call :call-id))
                          (funcall result call)))))

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

(defun harness-session--last-checkpoint (path)
  "Return the last node of PATH that carries a provider `:checkpoint', or nil."
  (cl-find-if (lambda (n) (plist-get n :checkpoint)) path :from-end t))

(defun harness-session--went-past-p (s node-id)
  "Non-nil when the provider conversation of S went past NODE-ID, S's head.
For a session that recorded no `provider-node', made before sessions
recorded one.  Its conversation went on past its head when S holds a
node after the head (the head was moved back to it, and no turn ran
since), or, for a fork, when its parent held a node after the fork node
before the fork was made: the fork was taken at an earlier node, and
then got the parent's whole provider conversation."
  (let ((after (lambda (table node before)
                 (catch 'found
                   (maphash (lambda (_ n)
                              (when (and (equal (plist-get n :parent) node)
                                         (or (null before) (< (or (plist-get n :ts) 0) before)))
                                (throw 'found t)))
                            table)
                   nil)))
        (parent (and (equal (format "%s" (harness-session-kind s)) "fork")
                     (gethash (harness-session-parent-id s) harness-sessions))))
    (or (and node-id (funcall after (harness-session-nodes s) node-id nil))
        (and parent (harness-session-fork-node s)
             (progn (harness-session--load-nodes parent)
                    (funcall after (harness-session-nodes parent) (harness-session-fork-node s)
                             (harness-session-created s)))))))

(defun harness-session--continuation (s node-id)
  "Return how the provider conversation of S goes on from NODE-ID.
A hosted-loop provider keeps the conversation itself, so the transcript
up to NODE-ID and the conversation the provider holds must agree before
anything is sent after NODE-ID.  The value is one of:

  (:mode current)      S's own provider state is that conversation as
                       it stands: NODE-ID is S's head and comes at or
                       after the node the conversation reached
                       (`provider-node').  A session older than
                       `provider-node' counts as there unless its
                       conversation went past its head
                       (`harness-session--went-past-p').
  (:mode checkpoint :checkpoint CP :node ID)
                       the conversation must be cut at CP, the provider
                       checkpoint of node ID, the last node on the path
                       to NODE-ID that has one.  A node after ID that
                       the provider would have to know again, such as a
                       user message, is sent once more with the next
                       turn's message.
  (:mode fresh)        no checkpoint precedes NODE-ID: the provider must
                       start a new conversation, which it seeds with
                       the transcript.

The head moves off the conversation when it is checked out at an
earlier node or on another branch (`session/set-head'), and a fork
taken anywhere but at the head of its parent starts off it."
  (let* ((path (harness-session--path s node-id))
         (reached (harness-session-provider-node s)))
    (if (and (equal node-id (harness-session-head s))
             (if reached
                 (cl-find reached path :key (lambda (n) (plist-get n :id)) :test #'equal)
               (not (harness-session--went-past-p s node-id))))
        (list :mode 'current)
      (let ((cut (harness-session--last-checkpoint path)))
        (if cut
            (list :mode 'checkpoint :checkpoint (plist-get cut :checkpoint) :node (plist-get cut :id))
          (list :mode 'fresh))))))

(defun harness-session--config (key cwd)
  (if (harness-method-exists-p 'config/get)
      (ignore-errors (harness-call 'config/get key cwd))
    (and (boundp key) (symbol-value key))))

(defun harness-session--model-window (model)
  "Return the context window the provider catalogue gives MODEL.
The catalogue gives every model one, estimated where no provider says
\(see `provider/model'); without a catalogue the window is
`harness-provider-fallback-context-window'."
  (or (and (harness-method-exists-p 'provider/model)
           (condition-case err
               (plist-get (harness-call 'provider/model model) :context-window)
             (error (harness-log 'debug "session: no context window for %s: %S" model err)
                    nil)))
      (bound-and-true-p harness-provider-fallback-context-window)
      200000))

(defun harness-session--context-window-limit-value (v)
  "Return V when it is a usable limit on a context window, else nil.
A limit is a positive number of tokens, kept whole."
  (and (numberp v) (> v 0) (round v)))

(defun harness-session--window (s)
  "Return the context window of S: the one set for it, else its model's.
Its `context-window-limit' caps the model's window; a window set for S
outright (`:context-window') wins over the limit."
  (or (harness-session-context-window s)
      (let ((window (harness-session--model-window (harness-session-model s)))
            (limit (harness-session--context-window-limit-value
                    (harness-session-context-window-limit s))))
        (if limit (min window limit) window))))

;;;; The prompt cache
;;
;; A provider keeps the start of a conversation cached for a while
;; after a request used it, and every request that reads or writes the
;; cache keeps it longer.  The usage of a session remembers when its
;; last such request was made (`:cache-at'), the model it was sent to
;; (`:cache-model') and the lifetime its provider reported for it, if
;; any (`:cache-ttl'), so a session idle for longer can be told that
;; its next request sends everything again uncached.  All three
;; persist with the session.
;;
;; A cache serves the model that wrote it, no other, so a session
;; switched to another model has nothing cached for it whatever the
;; stamp says: its `:cache' names the stamp's model, which tells the two
;; apart.  A request still sent to the old model (a step that ends after
;; the switch) stamps that model's cache.  Some changes start the
;; conversation over instead, so that the next request sends none of the
;; old one, cached or not: a compaction, whose summary replaces it, and a
;; switch to a provider that keeps a conversation of its own and holds
;; none of this session's (a hosted loop: Claude Code, Copilot), which is
;; sent only the newest messages and whatever a handoff gives it.  The
;; compaction drops the stamp (`:cache-reset'); the switch is told by
;; the provider state the session holds for the model, and the session
;; reports no cache while it holds none.

(defun harness-session--tokens (value)
  "Return VALUE when it is a number of tokens, else 0."
  (if (numberp value) value 0))

(defun harness-session--cache-stamp (usage record model)
  "Return USAGE with the prompt cache stamp of usage RECORD.
MODEL is the session's model.  A record with `:cache-reset' drops the
stamp: the conversation starts over, from a summary say, so nothing its
next request sends is cached yet.  A record of a request, one that
counts tokens, that read or wrote the cache stamps when that was (its
`:cache-at', else now), the model it was sent to (its `:model', else
MODEL), and the lifetime its provider reported (its `:cache-ttl', else
none).  One that used no cache drops the stamp: nothing is cached to
lose.  A record without tokens, a turn counted, leaves it."
  (cond
   ((harness-json-true-p (plist-get record :cache-reset))
    (harness-plist-remove usage :cache-at :cache-ttl :cache-model))
   ((not (or (numberp (plist-get record :input)) (numberp (plist-get record :output))))
    usage)
   ((> (+ (harness-session--tokens (plist-get record :cache-read))
          (harness-session--tokens (plist-get record :cache-write)))
       0)
    (let* ((at (plist-get record :cache-at))
           (ttl (plist-get record :cache-ttl))
           (u (plist-put usage :cache-at (if (numberp at) (float at) (float-time))))
           (u (plist-put u :cache-model (or (plist-get record :model) model))))
      (if (and (numberp ttl) (> ttl 0))
          (plist-put u :cache-ttl ttl)
        (harness-plist-remove u :cache-ttl))))
   (t (harness-plist-remove usage :cache-at :cache-ttl :cache-model))))

(defun harness-session--cache-ttl (model reported)
  "Return the seconds MODEL's provider keeps a prompt cache after its use.
REPORTED is the lifetime the provider reported for the last request;
see `provider/cache-ttl'.  Without a provider module, REPORTED when it
is a positive number, else `harness-cache-ttl'."
  (or (and (harness-method-exists-p 'provider/cache-ttl)
           (condition-case err
               (harness-call 'provider/cache-ttl model reported)
             (error (harness-log 'debug "session: no cache lifetime for %s: %S" model err)
                    nil)))
      (and (numberp reported) (> reported 0) reported)
      (bound-and-true-p harness-cache-ttl)
      300))

(defun harness-session--new-conversation-p (s model)
  "Non-nil when S's next request on MODEL starts a conversation of its own.
That is a model whose provider keeps the conversation itself (a hosted
loop) and holds none of S's: it is sent only the newest messages, so
none of the old conversation is sent to it again.  Only the provider a
state names counts: a state written before states named theirs would
take reading the transcript to place."
  (and (harness-method-exists-p 'provider/capabilities)
       (harness-json-true-p
        (plist-get (condition-case err
                       (harness-call 'provider/capabilities model)
                     (error (harness-log 'debug "session: no capabilities for %s: %S" model err)
                            nil))
                   :hosted-loop))
       (not (eq (harness-provider-state-owner (harness-session-provider-state s))
                (harness-model-provider model)))))

(defun harness-session--cache (s)
  "Return what is known of the prompt cache of session S, or nil.
That is (:at TIME :ttl SECONDS :expires TIME :model MODEL): when the
last request that used the cache was made, how long the provider keeps
it, when it lapses unless another request comes first, and the model it
was sent to.  A cache serves its MODEL only: one of a model S no longer
uses holds nothing S's next request reads back, which then sends the
conversation uncached.  Nil while S has no context, before any of its
requests used a cache, after one that did not, after a compaction, and
while S's next request starts a conversation of its own on its new
model (`harness-session--new-conversation-p'), which sends none of the
old one."
  (let* ((u (harness-session-usage s))
         (at (plist-get u :cache-at))
         (model (or (plist-get u :cache-model) (harness-session-model s))))
    (when (and (numberp at) (> (harness-session--tokens (plist-get u :context)) 0)
               (or (equal model (harness-session-model s))
                   (not (harness-session--new-conversation-p s (harness-session-model s)))))
      (let ((ttl (harness-session--cache-ttl model (plist-get u :cache-ttl))))
        (list :at at :ttl ttl :expires (+ at ttl) :model model)))))

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

;;;; Temporary directories

(defvar harness-session--tmp-root nil
  "Directory holding every session's temporary directory, or nil for the default.
The default is harness-UID in `temporary-file-directory', UID being the
user's, so that the users of a machine never share it.  Internal, not
an option (see docs/configuration-audit.md): TMPDIR, through
`temporary-file-directory', already says where temporary files go.
The tests point it into their throwaway state directory.")

(defvar harness-session--tmp-warned nil
  "Temporary directories the log already said could not be had.")

(defun harness-session-tmp-root ()
  "Return the directory holding every session's temporary directory."
  (file-name-as-directory
   (expand-file-name (or harness-session--tmp-root
                         (expand-file-name (format "harness-%d" (user-uid)) temporary-file-directory)))))

(defun harness-session--tmp-name (id)
  "Return the file name of the temporary directory of session ID.
A plain id, as a UUID is, names it; any other is hashed, so that no id
can reach outside the root and no two ids share a directory."
  (let ((id (format "%s" id)))
    (if (string-match-p "\\`[A-Za-z0-9_-]+\\'" id)
        id
      (concat "id-" (md5 id)))))

(defun harness-session--tmp-path (s)
  "Return the name of the temporary directory of session S.
Nil for a remote session: its tools work on another host, where the
harness makes no directories behind the user's back.  Only the name:
`harness-session--tmp-dir' makes the directory and checks it."
  (unless (or (harness-session-host s)
              (file-remote-p (or (harness-session-cwd s) "")))
    (file-name-as-directory
     (expand-file-name (harness-session--tmp-name (harness-session-id s))
                       (harness-session-tmp-root)))))

(defun harness-session--own-dir-p (dir)
  "Non-nil when DIR is a directory of the user's own.
A symbolic link is not, even to such a directory, nor is a directory
somebody else owns."
  (let ((attrs (file-attributes (directory-file-name dir) 'integer)))
    (and attrs
         (eq t (file-attribute-type attrs))
         (eql (file-attribute-user-id attrs) (user-uid)))))

(defun harness-session--tmp-warn (dir why)
  "Log, once, that DIR cannot be had as a temporary directory because of WHY.
Return nil."
  (unless (member dir harness-session--tmp-warned)
    (push dir harness-session--tmp-warned)
    (harness-log 'warn "session: no temporary directory %s: %s" dir why))
  nil)

(defun harness-session--own-dir (dir)
  "Return DIR when it is a directory of the user's own, made if missing.
A directory made here is private to the user (mode 700).  Anything else
in its place, a symbolic link or somebody else's directory, is refused:
the log says so, once, and the value is nil."
  (condition-case err
      (progn
        (unless (file-attributes (directory-file-name dir))
          (with-file-modes #o700 (make-directory dir t)))
        (if (harness-session--own-dir-p dir)
            dir
          (harness-session--tmp-warn dir "something other than a directory of the user's own is there")))
    (error (harness-session--tmp-warn dir (harness-error-message err)))))

(defun harness-session--tmp-dir (s)
  "Return the temporary directory of session S, made if missing, or nil.
Nil for a remote session, and when the directory or the root holding
every session's is not the user's own (see `harness-session--own-dir')."
  (when-let* ((dir (harness-session--tmp-path s)))
    (and (harness-session--own-dir (harness-session-tmp-root))
         (harness-session--own-dir dir))))

(defun harness-session--delete-tmp (s)
  "Delete the temporary directory of session S and everything in it.
Only a directory of the user's own, in a root of the user's own, is
deleted; symbolic links inside it are removed, never followed."
  (when-let* ((dir (harness-session--tmp-path s)))
    (when (and (harness-session--own-dir-p (harness-session-tmp-root))
               (harness-session--own-dir-p dir))
      (condition-case err
          (delete-directory dir t)
        (error (harness-log 'warn "session: could not delete %s: %s"
                            dir (harness-error-message err)))))))

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
         (model (or (plist-get plist :model) (harness-session--config 'harness-model cwd)))
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
          (harness-session-context-window-limit s)
          (harness-session--context-window-limit-value (plist-get plist :context-window-limit))
          ;; Only a budget given to this session: the Budget setting
          ;; (`harness-budget') is one budget for all sessions together.
          (harness-session-budget s) (plist-get plist :budget)
          (harness-session-provider-state s) (plist-get plist :provider-state)
          (harness-session-loaded s) t)
    (puthash (harness-session-id s) s harness-sessions)
    (harness-session--save (harness-session-id s))
    (harness-session--tmp-dir s)
    (let ((pl (harness-session-plist s)))
      (harness-emit 'session/created (harness-session-id s) pl)
      (harness-session--announce s pl))))

(harness-defmethod session/get (id)
  "Return the public plist of session ID."
  (harness-session-plist (harness-session--get id)))

(harness-defmethod session/exists-p (id)
  "Non-nil when session ID is known."
  (and (gethash id harness-sessions) t))

(harness-defmethod session/tmp-dir (id)
  "Return the temporary directory of session ID, made if missing.
Every local session has one of its own, harness-UID/ID in
`temporary-file-directory', private to the user.  It is made with the
session, made again whenever it is asked for and missing (a reboot
empties /tmp), and deleted with the session.  The permission layer lets
the session use it, the sandbox lets its commands write there, and the
system prompt names it.  Nil for a remote session, and when no
directory of the user's own can be had there: /tmp is shared, so a
directory somebody else made, or a symbolic link, is refused."
  (harness-session--tmp-dir (harness-session--get id)))

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
  "Delete session ID and its files, its temporary directory included."
  (let ((s (harness-session--get id)))
    (harness-emit 'session/deleted id (harness-session-plist s))
    (remhash id harness-sessions)
    (remhash id harness-session--announced-windows)
    (harness-call 'store/delete (harness-session--meta-name id))
    (harness-call 'store/delete (harness-session--nodes-name id))
    (harness-session--delete-tmp s)
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
The record is written at once rather than after `harness-session--save-delay',
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
    (:context-window-limit (if value (format "context window limit → %s"
                                             (harness-format-tokens value))
                             "context window limit removed"))
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
also sets one.  `:context-window-limit N' caps its model's window at N
tokens, nil the model's again; a `:context-window' set for the session
wins over it."
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
                  (:context-window-limit (setf (harness-session-context-window-limit s)
                                               (harness-session--context-window-limit-value v)))
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

(harness-defmethod session/set-all (settings &optional filter)
  "Apply SETTINGS to every session FILTER selects; return the ids changed.
SETTINGS is a plist of keys `session/update' accepts, usually just
`:model'.  FILTER is `session/list''s filter (`:project' `:status'
`:kind' `:parent-id' `:active'), plus `:except', a list of session ids
to leave alone; nil means every session.  A session whose value is
already the one asked for is left alone, and one that changes is
changed exactly as `session/update' would (same event, same hint).  The
return value lists the ids that changed, newest first."
  (let* ((except (plist-get filter :except))
         (list-filter (harness-plist-remove filter :except))
         (keys (cl-intersection (harness-plist-keys settings) harness-session--settings))
         changed)
    (dolist (s (harness-call 'session/list list-filter))
      (let ((id (plist-get s :id)))
        (when (and (not (member id except))
                   (cl-some (lambda (k) (not (equal (plist-get s k) (plist-get settings k)))) keys))
          (apply #'harness-call 'session/update id settings)
          (push id changed))))
    (nreverse changed)))

(harness-defmethod session/set-provider-state (id state)
  "Replace the opaque provider state of session ID with STATE.
A STATE different from the one held is announced as
`session/provider-state-changed', so a provider whose live process
serves the old conversation can let it go."
  (let ((s (harness-session--get id)))
    (unless (equal state (harness-session-provider-state s))
      (setf (harness-session-provider-state s) state)
      (harness-emit 'session/provider-state-changed id state)
      (harness-session--touch s))
    state))

(defun harness-session--last-model (s)
  "Return the model that answered last in the transcript of S, or nil.
That is the `:meta' `:model' of the newest assistant or thinking node."
  (cl-loop for n in (reverse (harness-session--path s))
           for model = (and (memq (plist-get n :kind) '(assistant thinking))
                            (plist-get (plist-get n :meta) :model))
           when (and (stringp model) (not (string-empty-p model))) return model))

(defun harness-session--state-owner (s state)
  "Return the provider, a symbol, that provider STATE of session S belongs to.
A state names its provider (see `harness-tag-provider-state').  One
written before states did belongs to the provider that answered last in
S's transcript: had another provider answered since, the state's own
would not have seen those turns.  With no answer to go by, it is the
provider of S's model.  Nil means no provider can vouch for STATE."
  (or (harness-provider-state-owner state)
      (harness-model-provider (or (harness-session--last-model s) (harness-session-model s)))))

(harness-defmethod session/provider-state (id &optional model)
  "Return the provider state of session ID that MODEL can continue, or nil.
MODEL defaults to the session's model.  A state belongs to the provider
it names (`:provider'), and only that provider's models continue it: a
model of another provider gets nil, as if the session had no state.  A
state written before states named their provider is attributed as
`harness-session--state-owner' says."
  (let* ((s (harness-session--get id))
         (state (harness-session-provider-state s))
         (provider (harness-model-provider (or model (harness-session-model s)))))
    (and state provider
         (eq provider (harness-session--state-owner s state))
         state)))

(harness-defmethod session/set-provider-node (id node-id)
  "Record NODE-ID as the node the provider conversation of session ID reached.
The agent records the head when a turn ends; `session/provider-continuation'
compares it with the head to tell whether the head moved off that
conversation since."
  (let ((s (harness-session--get id)))
    (unless (equal node-id (harness-session-provider-node s))
      (setf (harness-session-provider-node s) node-id)
      (harness-session--touch s))
    node-id))

(harness-defmethod session/provider-continuation (id &optional node-id)
  "Return how the provider conversation of session ID goes on from NODE-ID.
NODE-ID defaults to the head.  The value is (:mode current),
\(:mode checkpoint :checkpoint CP :node ID) or (:mode fresh); see
`harness-session--continuation'."
  (let ((s (harness-session--get id)))
    (harness-session--continuation s (or node-id (harness-session-head s)))))

(harness-defmethod session/runtime (id &optional key value)
  "Get or set the runtime (unpersisted) property KEY of session ID.
With only ID return the whole runtime plist."
  (let ((s (harness-session--get id)))
    (cond ((null key) (harness-session-runtime s))
          ((eq value :get) (plist-get (harness-session-runtime s) key))
          (t (setf (harness-session-runtime s) (plist-put (harness-session-runtime s) key value))
             value))))

;;;; Methods: forks, BTWs and trees

(defconst harness-session-forked-output
  "No result in this fork: the session was forked before this call returned, and the result went to the session it was forked from."
  "Result a fork records for a tool call that had none when it was forked.")

(defconst harness-session-spawned-output
  "You are the sub-agent this call started: the session was forked here, and the next message is your task. Do the task yourself; your final message is this call's result for the session that forked you."
  "Result a fork records for the call that forked it to start a sub-agent.")

(defun harness-session--settle-fork (cs spawn-call)
  "Answer the tool calls that the transcript of fork CS copied unanswered.
A session forked in the middle of a turn copies the calls still
running, the forking spawn_agent call among them, and one forked where
its head was moved back copies calls without the results that came
later.  Their results go to the parent, never to the fork, so each gets
one in the fork: providers that pair calls with results reject a
transcript with an unanswered call.  The call whose id is SPAWN-CALL is
the one that forked the session to start a sub-agent, which the fork
is; its result says so rather than that it is missing."
  (harness-session--answer
   (harness-session-id cs) (harness-session--unanswered (harness-session--path cs))
   (lambda (call)
     (if (and spawn-call (equal (plist-get call :call-id) spawn-call))
         (list :output harness-session-spawned-output :meta (list :forked t))
       (list :output harness-session-forked-output :is-error t :meta (list :forked t))))))

(harness-defmethod session/fork (id &rest plist)
  "Fork session ID; return a promise of the new session plist.
PLIST may set `:kind' (fork, subagent), `:name', `:cwd', `:model' and
any other `session/create' key, and `:node', the node to fork at: by
default the head.  Forking at another node leaves ID's head where it
is.  The path from the root to that node is copied (same node ids), so
the fork starts with the parent's transcript up to there.

A tool call it copies without a result -- ID is in the middle of a
turn, or its head was moved back between a call and its result -- gets
one in the fork, saying the result went to ID
\(`harness-session-forked-output'), so the fork's first request pairs
every call with a result, as providers such as DeepSeek require.
PLIST's `:call-id' names ID's tool call that forks it to start a
sub-agent (spawn_agent's), whose result says instead that the fork is
that sub-agent and its task comes next
\(`harness-session-spawned-output').

Its provider state is the one `provider/fork' derives from the
parent's, and holds exactly that transcript, nothing after it (see
`harness-session--continuation'): at the parent's head, a fork of the
parent's whole provider conversation; at an earlier node, a fork of it
cut at the last provider checkpoint up to the node; and none when no
checkpoint precedes the node, or the provider cannot fork the state,
or the fork's model is of another provider, which cannot continue the
parent's state (`session/provider-state'), so that the provider starts
a new conversation from the transcript.  It is never the parent's own
state, which would carry on the parent's provider conversation: for
Claude Code, resume and write into the parent's CLI session.  A BTW is
no fork; see `session/btw'."
  (let* ((parent (harness-session--get id))
         (node (or (plist-get plist :node) (harness-session-head parent)))
         (path (progn (harness-session--load-nodes parent)
                      (when (and node (not (gethash node (harness-session-nodes parent))))
                        (signal 'harness-error (list (format "No node %s in %s" node id))))
                      (harness-session--path parent node)))
         (continuation (harness-session--continuation parent node))
         (spawn-call (plist-get plist :call-id))
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
                             :context-window-limit (harness-session-context-window-limit parent)
                             :kind 'fork
                             :parent-id id
                             :fork-node node)
                       (harness-plist-remove plist :node :call-id)))
         (child (apply #'harness-call 'session/create child-plist))
         (cs (harness-session--get (plist-get child :id))))
    (dolist (n path)
      (puthash (plist-get n :id) n (harness-session-nodes cs))
      (harness-session--persist-node cs n))
    (setf (harness-session-head cs) node
          ;; Its provider state, whatever it is, is the conversation up to NODE.
          (harness-session-provider-node cs) node)
    (harness-session--settle-fork cs spawn-call)
    (harness-session--save (harness-session-id cs))
    (harness-then
     (if (and (harness-method-exists-p 'provider/fork)
              (not (eq (plist-get continuation :mode) 'fresh)))
         (harness-catch (apply #'harness-call 'provider/fork (harness-session-model cs)
                               (harness-call 'session/provider-state id (harness-session-model cs))
                               (and (eq (plist-get continuation :mode) 'checkpoint)
                                    (list (plist-get continuation :checkpoint))))
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
  "Move the head of session ID to NODE-ID (time travel within the DAG).
The next message continues from NODE-ID: the transcript the model gets
is the path up to it, and before the next turn the agent rewinds a
hosted provider's conversation to match (`session/provider-continuation').
A session running a turn refuses, since the turn would go on writing
after the new head."
  (let ((s (harness-session--get id)))
    (harness-session--load-nodes s)
    (unless (gethash node-id (harness-session-nodes s))
      (signal 'harness-error (list (format "No node %s" node-id))))
    (when (if (harness-method-exists-p 'agent/running)
              (harness-call 'agent/running id)
            (eq (harness-session-status s) 'running))
      (signal 'harness-error (list "The session is running a turn; stop it before moving its head")))
    (setf (harness-session-head s) node-id)
    (harness-emit 'session/head-moved id node-id)
    (harness-session--touch s)
    node-id))

(harness-defmethod session/hint (id text)
  "Append a system hint TEXT to session ID."
  (harness-call 'session/append id (list :kind 'hint :content text)))

;;;; Methods: queue, pending, usage, todos, plan

(harness-defmethod session/queue (id text &optional attachments from)
  "Queue TEXT with ATTACHMENTS for the next turn of session ID; return the item.
FROM, when non-nil, is who sent it, when that was not the user (see
`harness-node-sender'); the item keeps it as `:from'."
  (let* ((s (harness-session--get id))
         (item (append (list :id (harness-short-id 6) :text text :attachments attachments :ts (float-time))
                       (and (harness-sender-kind from) (list :from from)))))
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
:context :turns, :billing and :plan saying how the call was paid,
:model the model the request was sent to (the session's when unsaid),
:cache-at and :cache-ttl, when the request used the prompt cache and
how long its provider said it keeps it, and :cache-reset, which says
the conversation starts over (a compaction).  Counters accumulate;
`:context' replaces, and so do `:billing' and `:plan' when RECORD has
a billing.  A request that read or wrote the cache stamps the totals'
`:cache-at', `:cache-model' and `:cache-ttl' (see
`harness-session--cache-stamp').  A missing `:cost' is priced
from the model catalogue; a missing `:list-cost', the call at API
prices, is the cost, or priced when a subscription paid.  Return the
totals."
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
    (setq u (harness-session--cache-stamp u record (harness-session-model s)))
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

(defconst harness-session-missing-result-output
  "No result was recorded for this call."
  "Result `session/messages' gives a tool call whose result is not on the path.")

(defun harness-session--stray-text (block)
  "Return tool_result BLOCK, which answers no call before it, as text."
  (list :type "text"
        :text (format "[Result of tool call %s%s]\n%s" (plist-get block :tool_use_id)
                      (if (plist-get block :is_error) ", an error" "")
                      (plist-get block :content))))

(defun harness-session--pair-tools (messages)
  "Return MESSAGES with every tool call answered by the message after it.
A tool_use block whose result is not in the next message gets an error
result there (`harness-session-missing-result-output'), in a user
message of its own when no user message follows; a tool_result block
that answers no tool_use of the message before it becomes text.
Providers that pair calls with results, such as DeepSeek and Bedrock,
reject a request with either.  A path has an unanswered call when its
head was moved back between a call and its result, say, or a stray
result when a call finished after its turn ended.  A message that needs
no change is returned as it is; one that does lists its results first."
  (let ((out nil) (asked nil))
    (cl-flet ((missing (call-id)
                (list :type "tool_result" :tool_use_id call-id
                      :content harness-session-missing-result-output :is_error t)))
      (dolist (m messages)
        (if (not (eq (plist-get m :role) 'user))
            (progn
              (when asked (push (list :role 'user :content (mapcar #'missing asked)) out))
              (push m out)
              (setq asked (delq nil (mapcar (lambda (b) (and (equal (plist-get b :type) "tool_use")
                                                             (plist-get b :id)))
                                            (plist-get m :content)))))
          (let ((results nil) (others nil) (answered nil) (stray nil))
            (dolist (b (plist-get m :content))
              (let ((call-id (plist-get b :tool_use_id)))
                (cond ((not (equal (plist-get b :type) "tool_result")) (push b others))
                      ((and (member call-id asked) (not (member call-id answered)))
                       (push call-id answered)
                       (push b results))
                      (t (setq stray t)
                         (push (harness-session--stray-text b) others)))))
            (let ((unanswered (cl-remove-if (lambda (call-id) (member call-id answered)) asked)))
              (push (if (or stray unanswered)
                        (list :role 'user :content (append (nreverse results) (mapcar #'missing unanswered)
                                                           (nreverse others)))
                      m)
                    out))
            (setq asked nil))))
      (when asked (push (list :role 'user :content (mapcar #'missing asked)) out)))
    (nreverse out)))

(harness-defmethod session/messages (id)
  "Return provider messages (:role :content BLOCKS) for the transcript of ID.
Adjacent assistant-side nodes merge into one assistant message; tool
results become user messages with tool_result blocks; the transcript
starts at the last compaction node when one exists.  A steering message
stands where the model got it, after its `:delivered-after' node and
the tool results right after that, not where it was sent mid-step.
Every tool call is answered in the message after it, by a stand-in
result when the path has none (see `harness-session--pair-tools')."
  (let* ((s (harness-session--get id))
         (path (harness-session--from-compaction (harness-session--path s)))
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
    (harness-session--pair-tools (nreverse messages))))

(harness-defmethod session/transcript-text (id)
  "Return the transcript of session ID as searchable plain text.
A user message the user did not write says who sent it."
  (mapconcat (lambda (n)
               (pcase (plist-get n :kind)
                 ('tool-call (format "[tool %s] %s" (plist-get n :tool) (or (plist-get n :title) "")))
                 ('tool-result (format "[result] %s" (or (plist-get n :output) "")))
                 ((and 'user (guard (harness-node-sender n)))
                  (format "[user, from %s] %s" (harness-sender-description (harness-node-sender n))
                          (or (plist-get n :content) "")))
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
  (let ((id (harness-session-id s)))
    (harness-session--answer id (harness-session--unanswered (harness-session--path s))
                             (lambda (_call)
                               (list :output harness-session-interrupted-output :is-error t
                                     :meta (list :interrupted t))))
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

(defconst harness-session--budget-copies-marker "session-budget-copies-dropped.json"
  "Store document written once the copies of the Budget setting are dropped.")

(defun harness-session--drop-budget-copies ()
  "Drop the copies of the Budget setting from the loaded sessions, once.
Sessions used to copy `harness-budget' into a budget of their own when
they were made, so the setting became one budget per session instead of
one for them all.  Nothing else gave a session a budget then, so every
session budget saved before the marker document exists is such a copy.
After that, a budget a session has was given to it, and stays."
  (unless (harness-call 'store/load harness-session--budget-copies-marker)
    (let ((n 0))
      (dolist (name (harness-call 'store/list "sessions" "\\.json\\'"))
        (let ((s (gethash (file-name-base name) harness-sessions)))
          (when (and s (harness-session-budget s))
            (setf (harness-session-budget s) nil)
            (harness-session--save (harness-session-id s))
            (harness-session--announce s)
            (cl-incf n))))
      (harness-call 'store/save harness-session--budget-copies-marker
                    (list :dropped n :date (format-time-string "%F")))
      (when (> n 0)
        (harness-log 'info "session: dropped the copy of the Budget setting from %d session%s"
                     n (if (= n 1) "" "s"))))))

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
  (harness-session--drop-budget-copies)
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

;; Nor does it drop the copies of the Budget setting the loaded sessions
;; may hold: this does, the first time.
(when (harness-module-ready-p 'session)
  (harness-session--drop-budget-copies))

(dolist (ev '((session/created . "(ID SESSION)")
              (session/changed . "(ID SESSION) after any change")
              (session/updated . "(ID CHANGES) settings changed")
              (session/status . "(ID STATUS)")
              (session/deleted . "(ID SESSION)") (session/resumed . "(ID)") (session/deactivated . "(ID)")
              (session/forked . "(PARENT-ID CHILD-ID)")
              (session/provider-state-changed . "(ID STATE) when the provider state is replaced by another")
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
