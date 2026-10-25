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
;; Redaction: a secret that got into a transcript is taken out of the
;; stored text by `session/redact-text'.  The node log is then the one
;; file here that is not only appended to: it is read, cleaned and
;; replaced whole, atomically, in one step that never yields, so no
;; append of this single-threaded process falls between the read and the
;; rename, and every line that holds no secret stays byte for byte as it
;; was.  The nodes in memory and the text of the record are cleaned too.
;; A hosted provider's own conversation may hold the secret as well,
;; where the harness cannot reach it: `session/reset-provider' drops its
;; state and the checkpoints that name it (rewriting the log again), so
;; the next turn starts a new conversation from the redacted transcript.
;; The provider's prompt cache of the old conversation goes with it, and
;; the session's cache says so (see The prompt cache below).
;; The secrets are given to `session/redact-text' in memory by its caller,
;; and what it reports is node ids, field names and counts, never a value.
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
;; Every local session but an internal one (see below) has a temporary
;; directory of its own, harness-UID/ID in a temporary directory that is
;; no RAM disk (/var/tmp/harness-1000/ID/; see `harness-session-tmp-root'
;; for where, and `harness-session-tmp-directory' to choose).  It is made
;; with the session, made again whenever it is asked for and missing, and
;; deleted with the session.  `session/tmp-dir' hands it out: the
;; permission layer lets the session use it, the sandbox lets its
;; commands write there, and the system prompt names it.  The directory
;; is shared, so only a directory that is the user's own is ever handed
;; out.
;;
;; Nobody has to delete these: the harness does, for the sessions it made
;; them for (`harness-session--tmp-sweep').  A session is over when its
;; task is done (a sub-agent goes with the task it works for) or, when it
;; has no task, when it is closed; `harness-session-tmp-retention-days'
;; after that (counted from its last change, or from the day its task
;; was accepted) its directory goes, and a session still at work, or
;; open, or a task in review, keeps its own.  Only the directories of
;; sessions this harness has are ever touched: another harness of the
;; same user (a development instance, scripts/dev.sh) shares the root.
;;
;; A session can move to another working directory, and with it to that
;; directory's project (`session/move'): one started in the wrong place
;; need not stay listed there.  Its provider conversation stays behind,
;; and a session in the middle of a turn moves when the turn ends (see
;; Methods: moving to another directory).
;;
;; A session may instead cap its context window at a number of tokens
;; (`:context-window-limit' to `session/create' or `session/update'):
;; the window in effect is then the smaller of the model's and the
;; limit, computed afresh so a model change moves it too.  Task
;; sessions use this to compact earlier than interactive ones (see
;; `harness-tasks-context-limit').  A `:context-window' set outright
;; for the session wins over the limit, being the more explicit choice.
;;
;; A session also carries `ext', a plist of the settings that other
;; modules keep for it, whether it is a supervisor's, say
;; (`session/set-ext').  It is stored with the record, announced as
;; `session/ext-changed' and never copied to a fork: each module sets
;; up its own forks.
;;
;; The harness also makes model calls of its own, outside any turn: the
;; permission judge and the session judge, a session's name, the Elisp
;; judge, insights, the pet, task search and recaps.  A request that
;; names its job makes `provider/complete' record the call as a session
;; of kind `internal' (`session/internal-start', then
;; `session/internal-finish'): the prompt as a message the harness
;; sent, the reply, the model, its usage and cost, and as its parent the
;; session the call was made for.  Only the newest
;; `harness-session--internal-keep' are kept: each new one deletes the
;; oldest that are not running.  An internal session is a record, not a
;; conversation: it cannot be continued (the agent refuses to prompt
;; it), it has no temporary directory, and neither bulk changes
;; (`session/select') nor its parent's fork family (`session/tree')
;; take it in.  The session list hides internal sessions unless asked.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-policy)
(require 'harness-redaction)

(defvar harness-state-directory)
(defvar harness-provider-fallback-context-window)
(defvar harness-cache-ttl)

(declare-function harness-provider-model-refusal "harness-provider" (model-id))

(defconst harness-session--save-delay 0.3
  "Seconds of quiet before a changed session record is written to disk.")

(defvar harness-session--internal-keep 100
  "How many internal sessions to keep, the newest ones.
An internal session records one model call the harness makes on its
own, such as the permission judge's (see `session/internal-start').
Each new one deletes the oldest internal sessions that are not
running until at most this many remain; 0 keeps none but the calls
still under way.  They are records to read back what the harness
asked, not conversations, so the count only bounds the state
directory while keeping the recent calls to look at.")

(defconst harness-session--internal-prompt-max 20000
  "Most characters of its prompt an internal session keeps.
A longer prompt is cut there, with a note saying it was.")

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
  provider-node                         ; the node its provider conversation reached
  move                                  ; a move waiting for its turn to end, or nil
  ext                                   ; settings modules keep here, a plist, or nil
  last-message                          ; time of its latest user or assistant message, or nil
  steering)                             ; messages the running turn has not taken yet, or nil

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
    :context-window :context-window-override :context-window-limit :budget :head :queue :steering
    :pending :todos :plan :provider-state :provider-node :cache :move :ext :last-message))

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
cache (see `harness-session--cache').  `:last-message' is when S's latest
user or assistant message was written (see `session/append'), nil
before it has one: unlike `:updated', which moves with every change, it
moves with messages only."
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
        :queue (harness-session-queue s) :steering (harness-session-steering s)
        :pending (harness-session-pending s)
        :todos (harness-session-todos s) :plan (harness-session-plan s)
        :provider-state (harness-session-provider-state s)
        :provider-node (harness-session-provider-node s)
        :cache (harness-session--cache s)
        :move (harness-session-move s)
        :ext (harness-session-ext s)
        :last-message (harness-session-last-message s)))

;; The `ext' slot holds what the modules that are not the session's own
;; keep about it, a plist of keyword to value (`session/set-ext').  It
;; is stored with the record as a JSON object, so a value has to be
;; something JSON keeps as it is: t, `:false' (an explicit off, which
;; nil is not: nil removes the key), a string, a number, or a list or
;; plist of those.  A symbol would come back from a restart as a string.

(defun harness-session--ext-value (value)
  "Return VALUE, a stored or given `ext' plist, as a session holds it.
That is a plist of keyword keys without the keys set to nil, which is
how `session/set-ext' removes one; nil for anything else, a value that
is no plist included."
  (when (and (consp value) (keywordp (car value)) (proper-list-p value) (cl-evenp (length value)))
    (cl-loop for (k v) on value by #'cddr
             when (and (keywordp k) v) append (list k v))))

(defun harness-session--ext-key (key)
  "Return KEY, the name of a setting in `ext', as the keyword it is stored under.
KEY may be that keyword, a symbol or a string -- a client on the wire can
send no more than a string, with or without the colon.  Signal for
anything else."
  (cond ((keywordp key) key)
        ((and key (symbolp key) (not (eq key t))) (intern (concat ":" (symbol-name key))))
        ((and (stringp key) (not (string-empty-p key)))
         (intern (if (string-prefix-p ":" key) key (concat ":" key))))
        (t (signal 'harness-error (list (format "Not the name of a setting: %S" key))))))

(defun harness-session--ext-json-p (value)
  "Non-nil when VALUE comes back from the JSON store of a record as it is.
That is t, `:false', a string, a number, nil inside a list, and a list
or a plist (keyword keys) of those."
  (cond ((or (null value) (eq value t) (eq value :false) (stringp value) (numberp value)) t)
        ((and (consp value) (proper-list-p value))
         (if (keywordp (car value))
             (and (cl-evenp (length value))
                  (cl-loop for (k v) on value by #'cddr
                           always (and (keywordp k) (harness-session--ext-json-p v))))
           (cl-every #'harness-session--ext-json-p value)))))

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
          ;; What the turn of a stopped harness had not taken: no turn
          ;; holds it any more (`harness-session--settle-steering').
          (harness-session-steering s) (plist-get pl :steering)
          (harness-session-pending s) nil
          (harness-session-todos s) (plist-get pl :todos)
          (harness-session-plan s) (plist-get pl :plan)
          (harness-session-provider-state s) (plist-get pl :provider-state)
          (harness-session-provider-node s) (plist-get pl :provider-node)
          (harness-session-move s) (harness-session--move-value (plist-get pl :move))
          (harness-session-ext s) (harness-session--ext-value (plist-get pl :ext))
          ;; Nil for a record written before sessions kept it.
          (harness-session-last-message s) (let ((v (plist-get pl :last-message))) (and (numberp v) v)))
    ;; A session saved before the policy came keeps no setting it fixes.
    (harness-session--apply-policy s)
    s))

;;;; Settings a policy fixes

(defconst harness-session--policy-options
  '((:model . harness-model) (:permission-mode . harness-permission-mode)
    (:thinking . harness-thinking) (:non-interactive . harness-non-interactive))
  "Session settings that start from an option, each with that option.
Every session holds a copy of its own, which it may change.  When the
policy sets the option (see harness-policy.el), the copy of every
session -- new, forked, a sub-agent's, a task's, one saved before the
policy came -- is the policy's value instead, and `session/update'
refuses to change it.  A BTW session's thinking starts from
`harness-btw-thinking', fitted to the levels its model offers, so it is
left to `session/create', which reads both options as the policy has
them.
Its model is not left: a policy on `harness-model' fixes a BTW's model
too, and `harness-btw-model' then changes nothing.")

(defun harness-session--policy-option (key kind)
  "Return the option that fixes setting KEY of a session of KIND, or nil.
Nil for every key of an `internal' session: it records a call made with
the model it names, which the policy's model must not replace."
  (unless (or (eq kind 'internal) (and (eq key :thinking) (eq kind 'btw)))
    (alist-get key harness-session--policy-options)))

(defun harness-session--setting-value (key value)
  "Return VALUE of session setting KEY as a session holds it."
  (pcase key
    (:permission-mode (if (stringp value) (intern value) value))
    (:non-interactive (and (harness-json-true-p value) t))
    (_ value)))

(defun harness-session--pinned (key kind)
  "Return (VALUE) when the policy fixes setting KEY of a session of KIND, else nil.
VALUE is the policy's, as a session holds it."
  (when-let* ((option (harness-session--policy-option key kind))
              (entry (harness-policy-entry option)))
    (list (harness-session--setting-value key (cdr entry)))))

(defun harness-session--setting (s key)
  "Return setting KEY of session S, one of `harness-session--policy-options'."
  (pcase key
    (:model (harness-session-model s))
    (:permission-mode (harness-session-permission-mode s))
    (:thinking (harness-session-thinking s))
    (:non-interactive (harness-session-non-interactive s))))

(defun harness-session--apply-policy (s)
  "Give session S the policy's value of every setting it fixes.
Return the changes as a plist of KEY VALUE, nil when there were none.
A model that changes takes its own context window, as in
`session/update'."
  (let ((kind (harness-session-kind s))
        changes)
    (dolist (cell harness-session--policy-options)
      (let ((key (car cell)))
        (when-let* ((pinned (harness-session--pinned key kind)))
          (let ((value (car pinned)))
            (unless (equal value (harness-session--setting s key))
              (pcase key
                (:model (setf (harness-session-model s) value
                              (harness-session-context-window s) nil))
                (:permission-mode (setf (harness-session-permission-mode s) value))
                (:thinking (setf (harness-session-thinking s) value))
                (:non-interactive (setf (harness-session-non-interactive s) value)))
              (setq changes (plist-put changes key value)))))))
    changes))

(defun harness-session--without-pinned (plist kind)
  "Return PLIST without the settings the policy fixes for a session of KIND.
What `session/create' is asked for gives way to the policy: the session
gets the policy's values, as it reads them from the configuration."
  (cl-loop for (k v) on plist by #'cddr
           unless (harness-session--pinned k kind)
           append (list k v)))

(defun harness-session-check-policy (settings &optional kind)
  "Signal an error when SETTINGS would change a setting the policy fixes.
SETTINGS is a plist of `session/update' keys for a session of KIND
\(`main' when nil).  A value equal to the policy's passes: it changes
nothing.  A model `harness-allowed-models' does not allow is refused
too.  Callers that change sessions for the user, such as the task
board, check first, so they refuse before they change anything else."
  (cl-loop for (k v) on settings by #'cddr
           for pinned = (harness-session--pinned k (or kind 'main))
           when (and pinned (not (equal (harness-session--setting-value k v) (car pinned))))
           do (error "%s" (harness-policy-locked-message
                           (harness-session--policy-option k (or kind 'main)))))
  (when-let* ((model (plist-get settings :model))
              ((fboundp 'harness-provider-model-refusal))
              (refusal (harness-provider-model-refusal model)))
    (error "%s" refusal)))

(defun harness-session--on-reloaded (&rest _)
  "Hold every session to the policy as it is after a reload.
The policy file is read again on reload, and may fix what it did not."
  (maphash (lambda (id s)
             (when-let* ((changes (harness-session--apply-policy s)))
               (harness-emit 'session/updated id changes)
               (harness-session--touch s)))
           harness-sessions))

;;;; Persistence

(defun harness-session--meta-name (id)
  "Return the store name of the record of session ID."
  (format "sessions/%s.json" id))

(defun harness-session--nodes-name (id)
  "Return the store name of the node log of session ID."
  (format "sessions/%s.nodes.jsonl" id))

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
  "Return a copy of NODE, as its node log gave it, in the form used in memory.
A string `:kind' becomes a symbol, and `:is-error' becomes t or nil."
  (let ((n (copy-sequence node)))
    (when (stringp (plist-get n :kind)) (setq n (plist-put n :kind (intern (plist-get n :kind)))))
    (when (plist-member n :is-error) (setq n (plist-put n :is-error (harness-json-true-p (plist-get n :is-error)))))
    n))

(defun harness-session--load-nodes (s)
  "Load the node log of S into memory if not yet done.
A record marked `update' is merged into the node it names, and one
marked `delete' (see `session/discard-nodes') removes it, so a node
discarded during a turn stays gone after a reload."
  (unless (harness-session-loaded s)
    (let ((table (harness-session-nodes s)))
      (dolist (rec (harness-call 'store/read-all (harness-session--nodes-name (harness-session-id s))))
        (let ((rec (harness-session--intern-node rec)))
          (cond
           ((equal (plist-get rec :_op) "delete") (remhash (plist-get rec :id) table))
           ((equal (plist-get rec :_op) "update")
            (let ((existing (gethash (plist-get rec :id) table)))
              (when existing
                (puthash (plist-get rec :id)
                         (harness-plist-merge existing (harness-plist-remove rec :_op))
                         table))))
           (t (puthash (plist-get rec :id) rec table))))))
    (setf (harness-session-loaded s) t)))

(defun harness-session--persist-node (s node &optional update)
  "Append NODE to the node log of S.
With UPDATE non-nil, the line is marked as an update of the node with
that id, which `harness-session--load-nodes' merges into it."
  (harness-call 'store/append (harness-session--nodes-name (harness-session-id s))
                (if update (plist-put (copy-sequence node) :_op "update") node)))

;;;; Path helpers

(defun harness-session--from-compaction (path)
  "Return PATH from its last compaction node on, or all of it without one.
That is the part of a transcript `session/messages' sends: the summary
in the compaction node stands for everything before it.  A compaction
the user reverted (`compaction/revert') is no such node, and neither is
what it carried over: the conversation before it is sent whole
\(`harness-path-from-compaction')."
  (harness-path-from-compaction path))

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
`:output', `:is-error', `:meta'.  The result of a call the harness
recorded (`harness-outside-node-p') says so too, like the call, and
names the same `:child-id': the model never sees either."
  (dolist (call calls)
    (let* ((rest (funcall result call))
           (meta (plist-get call :meta)))
      (when (harness-outside-node-p call)
        (setq rest (plist-put (copy-sequence rest) :meta
                              (append (plist-get rest :meta)
                                      (list :from (plist-get meta :from))
                                      (and (plist-get meta :child-id)
                                           (list :child-id (plist-get meta :child-id)))))))
      (harness-call 'session/append id
                    (append (list :kind 'tool-result :call-id (plist-get call :call-id)) rest)))))

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
  "Return the value of setting KEY in effect at CWD, or nil.
That is what `config/get' says, nil when it fails; without the config
module, the global value of KEY, nil when it has none."
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

(defun harness-session-context-limit-source (session)
  "Return a short name of what capped SESSION's context window, or nil.
SESSION is a session plist, as `session/get' returns it, and nil is
returned when it carries no limit.  A sub-agent's cap is
`harness-subagent-context-limit', a task's `harness-tasks-context-limit',
and anything else is a limit set for the session itself.  Best effort,
as the UI's `harness-ui-context-cap-name': the session's kind says it is
a sub-agent's (the supervisor's workers and spawn_agent's children are
sub-agents, and a fork inherits its parent's limit), the tasks module's
own cap value says a task's, and any other limit is taken for one set
for the session, by the user or through `session/update'."
  (let ((limit (harness-session--context-window-limit-value
                (plist-get session :context-window-limit))))
    (when limit
      (cond
       ((member (format "%s" (plist-get session :kind)) '("subagent" "fork"))
        "a sub-agent cap (harness-subagent-context-limit)")
       ((and (boundp 'harness-tasks-context-limit)
             (numberp (symbol-value 'harness-tasks-context-limit))
             (equal limit (harness-session--context-window-limit-value
                           (symbol-value 'harness-tasks-context-limit))))
        "a task cap (harness-tasks-context-limit)")
       (t "set for this session")))))

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
;; A hosted loop (Claude Code, Copilot) reports what a turn used only when
;; the turn is over, so the stamp would read as of the turn before for as
;; long as the turn runs -- a long tool call, a question waiting for its
;; answer -- and for good when the turn never gets to say it.  The turn
;; says each request as it is made instead (`session/cache-stamp'), the
;; stamp moves on with it, and the turn's usage, when it comes, sets it
;; for good.  That usage comes after the turn's end when a tool ended the
;; turn (`hand_in'): the agent takes it all the same (harness-agent.el),
;; or a session handed in would read 0 tokens and $0, and have no cache
;; for its chat to say lapsed.
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
;;
;; A redaction drops a cache too.  A hosted loop's conversation, and the
;; cache the provider keeps of it, may hold a secret the harness cannot
;; reach, so `session/reset-provider' drops that conversation, and the
;; next turn opens a new one with the redacted transcript as text, a
;; different prefix that reads none of the old cache.  The stamp does not
;; say so: it still names the last request and its lifetime.  So the
;; reset marks the usage with the moment of the drop (`:cache-dropped')
;; when it drops a cache -- the session reports one (a stamp and a
;; context), and its model is a hosted loop -- and, while the stamp has
;; not lapsed by itself, the session's `:cache' says it is gone, from the
;; drop on: `:expires' is the drop and `:dropped' the same time.  The
;; cold-cache gate (harness-cowboy.el), the seeds' warmth check and the
;; UI then see a cold cache without any logic of their own, instead of
;; one that is warm for five more minutes.  Every change of the stamp
;; clears the mark: a request that stamps or drops it, or a compaction.
;; A record without tokens (a turn counted) leaves it.  A session on a
;; provider that is sent the whole transcript is not marked: its next
;; request is rebuilt from the redacted transcript, and still reads the
;; cache up to the first spot that was redacted.

(defun harness-session--tokens (value)
  "Return VALUE when it is a number of tokens, else 0."
  (if (numberp value) value 0))

(defun harness-session--cache-stamp (usage record model)
  "Return USAGE with the prompt cache stamp of usage RECORD.
MODEL is the session's model.  A record with `:cache-reset' drops the
stamp: the conversation starts over, from a summary say, so nothing its
next request sends is cached yet -- and, when the conversation had a
cache, remembers it (`:cache-pending'), so the first request that
follows, which populates the new conversation's cache, stamps it even
when the provider reports no cache tokens for it.  A record of a
request, one that counts tokens, that read or wrote the cache stamps
when that was (its `:cache-at', else now), the model it was sent to
(its `:model', else MODEL), and the lifetime its provider reported (its
`:cache-ttl', else none); one that was the first after a `:cache-reset'
stamps the same way.  A record without tokens, a turn counted, leaves
it.  A record of a request that used no cache and follows no reset
drops the stamp: nothing is cached to lose.  Whatever changes the
stamp clears the moment a redaction dropped the cache
\(`:cache-dropped', see `session/reset-provider'): a new stamp is a new
cache, and a dropped stamp has nothing left to say was dropped.  A
record that leaves the stamp leaves the mark too."
  (cond
   ((harness-json-true-p (plist-get record :cache-reset))
    (let ((u (harness-plist-remove usage :cache-at :cache-ttl :cache-model :cache-dropped)))
      (if (numberp (plist-get usage :cache-at))
          (plist-put u :cache-pending t)
        u)))
   ((not (or (numberp (plist-get record :input)) (numberp (plist-get record :output))))
    usage)
   ((or (> (+ (harness-session--tokens (plist-get record :cache-read))
              (harness-session--tokens (plist-get record :cache-write)))
           0)
        (harness-json-true-p (plist-get usage :cache-pending)))
    (let* ((at (plist-get record :cache-at))
           (ttl (plist-get record :cache-ttl))
           (u (harness-plist-remove usage :cache-pending :cache-dropped))
           (u (plist-put u :cache-at (if (numberp at) (float at) (float-time))))
           (u (plist-put u :cache-model (or (plist-get record :model) model))))
      (if (and (numberp ttl) (> ttl 0))
          (plist-put u :cache-ttl ttl)
        (harness-plist-remove u :cache-ttl))))
   (t (harness-plist-remove usage :cache-at :cache-ttl :cache-model :cache-dropped))))

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

(defun harness-session--hosted-loop-p (model)
  "Non-nil when MODEL's provider keeps the conversation itself.
That is a hosted loop (Claude Code, Copilot): its provider capabilities
say `:hosted-loop'.  Nil without a provider module, and for a model
whose capabilities cannot be had (logged)."
  (and (harness-method-exists-p 'provider/capabilities)
       (harness-json-true-p
        (plist-get (condition-case err
                       (harness-call 'provider/capabilities model)
                     (error (harness-log 'debug "session: no capabilities for %s: %S" model err)
                            nil))
                   :hosted-loop))))

(defun harness-session--new-conversation-p (s model)
  "Non-nil when S's next request on MODEL starts a conversation of its own.
That is a model whose provider keeps the conversation itself (a hosted
loop) and holds none of S's: it is sent only the newest messages, so
none of the old conversation is sent to it again.  Only the provider a
state names counts: a state written before states named theirs would
take reading the transcript to place."
  (and (harness-session--hosted-loop-p model)
       (not (eq (harness-provider-state-owner (harness-session-provider-state s))
                (harness-model-provider model)))))

(defun harness-session--reset-drops-cache-p (s)
  "Non-nil when `session/reset-provider' on S would mark its prompt cache dropped.
That is when S has a cache (its usage holds a cache stamp, `:cache-at',
and a context, and the stamp is a cache its next request would read:
see `harness-session--cache'), S's model is a hosted loop
\(`harness-session--hosted-loop-p'), and the cache was not marked
dropped before.  The provider of a hosted loop keeps the conversation,
and the cache of it; the reset drops the conversation, and S's next turn
opens a new one that is sent the whole transcript as text, a prefix the
old cache does not hold, so nothing of it is read back.  A session on a
provider that is sent the whole transcript with every request is not
marked: its next request is built from the redacted transcript and
still reads the cache up to the first spot that was redacted.  Neither
is one that reports no cache -- the stamp is an earlier model's, and the
next request starts a conversation of its own -- nor one the reset
dropped the cache of already, as long as no request has stamped a cache
since: the first drop stays the one that counts.  The clock of the stamp
does not matter: a cache that lapsed by itself is marked all the same,
and `harness-session--cache' goes on reporting it as it was."
  (and (harness-session--hosted-loop-p (harness-session-model s))
       (not (numberp (plist-get (harness-session-usage s) :cache-dropped)))
       (harness-session--cache s)
       t))

(defun harness-session--cache (s)
  "Return what is known of the prompt cache of session S, or nil.
That is (:at TIME :ttl SECONDS :expires TIME :model MODEL): when the
last request that used the cache was made, how long the provider keeps
it, when it lapses unless another request comes first, and the model it
was sent to.  A cache serves its MODEL only: one of a model S no longer
uses holds nothing S's next request reads back, which then sends the
conversation uncached.  Nil while S has no context, before any of its
requests used a cache, after one that did not, after a compaction --
which, when the conversation had a cache, leaves `:cache-pending'
until the first request that follows stamps the new cache -- and while
S's next request starts a conversation of its own on its new model
(`harness-session--new-conversation-p'), which sends none of the old
one.

A cache a redaction dropped (`session/reset-provider', which marks the
usage `:cache-dropped' with the moment) while it still held is gone from
then on, not at the end of its lifetime: `:expires' is that moment, and
the list ends with `:dropped', the same time, which says why.  So the
cold-cache gate, the seeds and the UI, which read `:expires', find it
cold at once.  A cache that had lapsed by itself before the drop is
reported as it was: nothing was left to drop."
  (let* ((u (harness-session-usage s))
         (at (plist-get u :cache-at))
         (model (or (plist-get u :cache-model) (harness-session-model s))))
    (when (and (numberp at) (> (harness-session--tokens (plist-get u :context)) 0)
               (or (equal model (harness-session-model s))
                   (not (harness-session--new-conversation-p s (harness-session-model s)))))
      (let ((ttl (harness-session--cache-ttl model (plist-get u :cache-ttl)))
            (dropped (plist-get u :cache-dropped)))
        (if (and (numberp dropped) (< dropped (+ at ttl)))
            (list :at at :ttl ttl :expires dropped :model model :dropped dropped)
          (list :at at :ttl ttl :expires (+ at ttl) :model model))))))

(defun harness-session--model-levels (model)
  "Return the thinking levels the provider catalogue gives MODEL, or nil."
  (and model (harness-method-exists-p 'provider/model)
       (condition-case err
           (plist-get (harness-call 'provider/model model) :thinking-levels)
         (error (harness-log 'debug "session: no thinking levels for %s: %S" model err)
                nil))))

(defun harness-session--btw-thinking (model cwd)
  "Return the thinking level a BTW with MODEL at CWD starts at, or nil.
That is `harness-btw-thinking' as configured at CWD, fitted to the
thinking levels the provider catalogue gives MODEL
\(`harness-thinking-level-fit'): the level itself when MODEL offers
it, else the strongest it offers below it, else its weakest.  So a BTW
thinks as little as asked for, or as little as its model allows,
whatever level the session it is opened over thinks at and whether it
runs on that session's model or on another: a model with no `medium'
is not left to the session's `max'.  nil when no level is configured,
and for a model whose catalogue lists no levels, which may refuse a
request that asks for one: the BTW then has the level it would have
otherwise."
  (harness-thinking-level-fit (harness-session--config 'harness-btw-thinking cwd)
                              (harness-session--model-levels model)))

(defun harness-session--btw-model (model cwd)
  "Return the model a BTW at CWD runs on; MODEL is the one it would otherwise use.
MODEL is the model of the session the BTW is opened over, or
`harness-model' as configured at CWD for a BTW over no session.  The
answer is what `harness-btw-model' says at CWD: `auto' (or the string
\"auto\"), the default, is the simple tier of MODEL's provider, MODEL
itself when the provider names none (see `harness-provider-tier-model');
a PROVIDER:NAME is that model, unless `harness-allowed-models' leaves it
out, which the log says and MODEL stands for; nil is MODEL.  A policy
that fixes `harness-model' is no concern of this function: it fixes a
BTW's model too (`harness-session--pinned'), whatever this answers."
  (let ((choice (harness-session--config 'harness-btw-model cwd)))
    (cond
     ((or (eq choice 'auto) (equal choice "auto"))
      (or (and model (harness-method-exists-p 'provider/tier-model)
               (ignore-errors (harness-call 'provider/tier-model model 'simple)))
          model))
     ((and (stringp choice) (not (string-blank-p choice)))
      (let ((refusal (and (fboundp 'harness-provider-model-refusal)
                          (harness-provider-model-refusal choice))))
        (cond (refusal
               (harness-log 'warn "session: harness-btw-model: %s; a BTW runs on %s instead"
                            refusal model)
               model)
              (t choice))))
     (t model))))

;;;; Temporary directories

(defcustom harness-session-tmp-directory nil
  "Directory the sessions' temporary directories are made in, or nil.
The harness makes harness-UID in it, UID being yours, so that the users
of a machine never share it, and a directory for each session in that.
Nil, the default, takes the system's temporary directory when
something chose one (the environment variable TMPDIR, or
`temporary-file-directory'), else /var/tmp where there is one.  On
GNU/Linux /tmp is often a RAM disk, where the Go and Flutter caches of
an agent's builds eat your memory; /var/tmp is on the disk, which the
system cleans out on its own as well (the harness cleans out the
directories of finished sessions sooner, see
`harness-session-tmp-retention-days').  Name /tmp to have them in RAM
again.  It applies to the directories made from then on."
  :type '(choice (const :tag "Automatic" nil) directory)
  :group 'harness)

(defcustom harness-session-tmp-retention-days 1
  "Days a finished session's temporary directory is kept, or nil to keep it.
A session is finished when its task is done (a sub-agent goes with the
task it works for) or, when it belongs to no task, when it is closed;
one still at work, blocked on you, or open keeps its directory.  The
harness deletes the directory of a finished session this many days after
the session was last changed, or its task was accepted or finished if
later (0 deletes it at the next sweep, every half hour), so that scratch
files, Go and Flutter caches do not pile up.  A task in review keeps
its directory, where the screenshots of its report are, however long
you take.  Nil deletes a directory only with its session."
  :type '(choice (const :tag "Only with the session" nil) number)
  :group 'harness)

(defvar harness-session--tmp-root nil
  "Directory holding every session's temporary directory, or nil for the default.
The default is harness-UID, UID being the user's, in the directory
`harness-session--tmp-base' names.  Internal, not an option (see
docs/configuration-audit.md): `harness-session-tmp-directory' says where
it goes.  The tests point it into their throwaway state directory.")

(defvar harness-session--tmp-warned nil
  "Temporary directories the log already said could not be had.")

(defvar harness-session--disk-tmp "/var/tmp/"
  "The temporary directory that is on the disk, where /tmp may be a RAM disk.
Internal, not an option (see docs/configuration-audit.md):
`harness-session-tmp-directory' says where the directories go.  The
system cleans it out by itself, as it does /tmp, only less often.")

(defun harness-session--tmp-base ()
  "Return the directory the root of the sessions' temporary directories is made in.
That is `harness-session-tmp-directory'; else the system's temporary
directory (`temporary-file-directory') when something other than the
stock /tmp chose it -- TMPDIR, or the user's own setting -- else
`harness-session--disk-tmp' (/var/tmp) when that is a directory to
write in, else /tmp after all.  /tmp is a RAM disk on many systems, and
/var/tmp is on the disk.  macOS gets its per-user temporary directory,
which the system cleans out too, from `temporary-file-directory'."
  (let ((chosen harness-session-tmp-directory)
        (system (file-name-as-directory (expand-file-name temporary-file-directory)))
        (disk harness-session--disk-tmp))
    (cond ((and (stringp chosen) (not (string-blank-p chosen)))
           (file-name-as-directory (expand-file-name chosen)))
          ((not (equal system "/tmp/")) system)
          ((and (stringp disk) (file-directory-p disk) (file-writable-p disk))
           (file-name-as-directory (expand-file-name disk)))
          (t system))))

(defun harness-session-tmp-root ()
  "Return the directory holding every session's temporary directory."
  (file-name-as-directory
   (expand-file-name (or harness-session--tmp-root
                         (expand-file-name (format "harness-%d" (user-uid)) (harness-session--tmp-base))))))

(defun harness-session-tmp-roots ()
  "Return the directories that hold, or held, the sessions' temporary directories.
The root in use (`harness-session-tmp-root') first.  Then the one
earlier harnesses used, harness-UID in `temporary-file-directory', when
that is another: the directories they made there are deleted with their
sessions, or once these are finished, all the same.  A root the tests set
(`harness-session--tmp-root') has no other."
  (let ((root (harness-session-tmp-root))
        (old (and (null harness-session--tmp-root)
                  (file-name-as-directory
                   (expand-file-name (format "harness-%d" (user-uid)) temporary-file-directory)))))
    (if (and old (not (equal old root))) (list root old) (list root))))

(defun harness-session--tmp-name (id)
  "Return the file name of the temporary directory of session ID.
A plain id, as a UUID is, names it; any other is hashed, so that no id
can reach outside the root and no two ids share a directory."
  (let ((id (format "%s" id)))
    (if (string-match-p "\\`[A-Za-z0-9_-]+\\'" id)
        id
      (concat "id-" (md5 id)))))

(defun harness-session--tmp-path (s &optional root)
  "Return the name of the temporary directory of session S, in ROOT.
ROOT is by default the one in use, `harness-session-tmp-root'.
Nil for a remote session: its tools work on another host, where the
harness makes no directories behind the user's back.  Nil for an
internal session too: it records one model call and runs no tools.
Only the name: `harness-session--tmp-dir' makes the directory and
checks it."
  (unless (or (eq (harness-session-kind s) 'internal)
              (harness-session-host s)
              (file-remote-p (or (harness-session-cwd s) "")))
    (file-name-as-directory
     (expand-file-name (harness-session--tmp-name (harness-session-id s))
                       (or root (harness-session-tmp-root))))))

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

(defun harness-session--tmp-removable (s root)
  "Return the temporary directory of session S in ROOT if it may be deleted.
That is the directory when it is there, a real directory of the user's
own in a root of the user's own: a symbolic link, or a directory
somebody else made, is nil.  So is a session with no such directory."
  (when-let* ((dir (harness-session--tmp-path s root)))
    (and (harness-session--own-dir-p root)
         (harness-session--own-dir-p dir)
         dir)))

(defconst harness-session--tmp-trash-prefix ".trash-"
  "What the name of a temporary directory starts with while it is being deleted.")

(defun harness-session--remove-tree (path)
  "Delete the directory PATH and everything in it, in the background.
Symbolic links in it are removed, never followed.  A tree of a Flutter
SDK and its caches takes seconds to delete, in which a harness that
did it itself would answer no one; so `rm' does, and the harness goes
on.  A failure is logged, and the next sweep tries again
\(`harness-session--tmp-purge-trash')."
  (let ((rm (executable-find "rm"))
        (failed (lambda (why) (harness-log 'warn "session: could not delete %s: %s" path why))))
    (if (null rm)
        (condition-case err
            (delete-directory path t)
          (error (funcall failed (harness-error-message err))))
      (harness-then
       (harness-run-command (list rm "-rf" "--" path) :cwd "/" :timeout 3600 :name "harness-tmp-rm")
       (lambda (r)
         (unless (eql 0 (plist-get r :exit))
           (funcall failed (let ((err (string-trim (or (plist-get r :stderr) ""))))
                             (if (string-empty-p err) (format "rm: %s" (plist-get r :exit)) err)))))
       (lambda (err) (funcall failed (harness-error-message err)))))))

(defun harness-session--discard-tmp (dir root)
  "Take the temporary directory DIR of ROOT away now, and delete it.
DIR is renamed first, so that its name is free again at once: a session
that asks for its directory while the old one is still being deleted
gets a new, empty one, and nothing it makes there is deleted with the
old.  What is in it is deleted in the background
\(`harness-session--remove-tree'); where it cannot be renamed, it is
deleted where it is.  Callers have checked that DIR and ROOT are the
user's own (`harness-session--tmp-removable')."
  (let ((trash (expand-file-name
                (format "%s%s-%s" harness-session--tmp-trash-prefix
                        (file-name-nondirectory (directory-file-name dir)) (harness-short-id 6))
                root)))
    (if (condition-case nil
            (progn (rename-file (directory-file-name dir) trash) t)
          (error nil))
        (harness-session--remove-tree trash)
      (condition-case err
          (delete-directory dir t)
        (error (harness-log 'warn "session: could not delete %s: %s"
                            dir (harness-error-message err)))))))

(defun harness-session--delete-tmp (s)
  "Delete the temporary directory of session S and everything in it.
That is the one in the root in use and the one earlier harnesses made
in theirs (`harness-session-tmp-roots').  Only a directory of the
user's own, in a root of the user's own, is deleted; symbolic links
inside it are removed, never followed."
  (dolist (root (harness-session-tmp-roots))
    (when-let* ((dir (harness-session--tmp-removable s root)))
      (harness-session--discard-tmp dir root))))

;;;; Temporary directories: the ones nobody needs any more

(defun harness-session--family-task (s)
  "Return the task session S works for, or nil.
That is the task S is the session of (`task/for-session', if the tasks
module is there), else, for a sub-agent, the task of the session that
started it, and so on up: its files are the task's, and are needed as
long as the task is.  A session that started a sub-agent of its own,
other than a task's, has none.  An error of the tasks module is not
caught: a session whose task cannot be told is not to be taken for one
of no task."
  (let ((seen nil) (cur s) task)
    (while (and cur (not task) (< (length seen) 16)
                (not (member (harness-session-id cur) seen)))
      (push (harness-session-id cur) seen)
      (setq task (and (harness-method-exists-p 'task/for-session)
                      (harness-call 'task/for-session (harness-session-id cur))))
      (setq cur (and (not task)
                     (eq (harness-session-kind cur) 'subagent)
                     (harness-session-parent-id cur)
                     (gethash (harness-session-parent-id cur) harness-sessions))))
    task))

(defun harness-session--tmp-over-since (s)
  "Return when session S was over, or nil while it is not.
Over means nothing needs its temporary directory any more.  A session at
work (running) or waiting on the user (blocked) is not.  One that works
on a task is over when the task is done, in the done or cancelled
column of the board, whatever the session itself does (closed, or idle
after the merge); so is a sub-agent of such a task.  One that belongs
to no task is over when it is closed (inactive): an open conversation,
idle as it may be, is one the user can come back to.

The time is the latest of the session's last change and, for a task's, the
time the task was finished and the time the user verified it: a task
that waited a week in review is over from the moment it was accepted, not
from the week before, so that its screenshots outlive the review by the
whole of `harness-session-tmp-retention-days'."
  (let ((status (harness-session-status s)))
    (unless (memq status '(running blocked))
      (let* ((task (harness-session--family-task s))
             (over (if task
                       (and (memq (plist-get task :column) '(done cancelled)) t)
                     (eq status 'inactive))))
        (when over
          (apply #'max (or (harness-session-updated s) 0)
                 (cl-remove-if-not #'numberp (list (plist-get task :finished)
                                                   (plist-get task :verified-at)))))))))

(defun harness-session--tmp-finished-p (s)
  "Non-nil when session S is over, so that nothing needs its temporary directory.
See `harness-session--tmp-over-since'."
  (and (harness-session--tmp-over-since s) t))

(defun harness-session--tmp-purge-trash (root)
  "Delete the leftovers of deletions in ROOT that never finished.
A directory goes by a name of `harness-session--tmp-trash-prefix' while
`rm' deletes it; one still there an hour later was left by a harness
that stopped, or by an `rm' that failed.  They are ours by their name,
and the user's own by their owner."
  (when (harness-session--own-dir-p root)
    (dolist (f (directory-files root t (concat "\\`" (regexp-quote harness-session--tmp-trash-prefix))))
      (let ((attrs (file-attributes f 'integer)))
        (when (and (harness-session--own-dir-p f)
                   (time-less-p (time-add (file-attribute-status-change-time attrs) 3600)
                                (current-time)))
          (harness-session--remove-tree f))))))

(defun harness-session--tmp-sweep-blocked ()
  "Return why the temporary directories must not be swept now, or nil.
The tasks module says which sessions are over: asked before it has its
tasks, or after it failed to start, it would let the session of a task
in review pass for a closed conversation, and its screenshots go."
  (and (harness-module-get 'tasks)
       (not (harness-module-ready-p 'tasks))
       "the tasks module is not ready"))

(defun harness-session--tmp-sweep (&optional dry-run)
  "Delete the temporary directories of the sessions that are over; return them.
A session's directory goes when it has been over for
`harness-session-tmp-retention-days' (`harness-session--tmp-over-since'),
in the root in use and in the one earlier harnesses used
\(`harness-session-tmp-roots').  Only the directories of the sessions
this harness has are looked at: the root is shared with the other
harnesses of the user (a development instance has one), whose sessions
are none of its business, and a directory no session of its own names
is left to the system to clean out.  Return the directories as
\(:id ID :dir DIR) plists, deleted unless DRY-RUN, which leaves
everything and only says what would go.  Without a retention, nothing is
deleted.  While the tasks module is not ready, nothing is swept, and an
error says so (`harness-session--tmp-sweep-blocked')."
  (let ((days harness-session-tmp-retention-days)
        (roots (harness-session-tmp-roots))
        found)
    (when-let* ((why (and (numberp days) (harness-session--tmp-sweep-blocked))))
      (signal 'harness-error (list (format "The temporary directories are not swept: %s" why))))
    (when (numberp days)
      (let ((limit (- (float-time) (* days 86400))))
        (maphash
         (lambda (id s)
           ;; The cheap tests first: most sessions have no directory.
           (when (and (<= (or (harness-session-updated s) 0) limit)
                      (not (memq (harness-session-status s) '(running blocked))))
             (let ((dirs (delq nil (mapcar (lambda (root)
                                             (when-let* ((dir (harness-session--tmp-removable s root)))
                                               (cons dir root)))
                                           roots))))
               (when-let* ((over (and dirs
                                      (condition-case err
                                          (harness-session--tmp-over-since s)
                                        (error (harness-log 'warn "session: keeping the temporary directory of %s: %s"
                                                            id (harness-error-message err))
                                               nil)))))
                 (when (<= over limit)
                   (dolist (d dirs)
                     (push (list :id id :dir (car d) :root (cdr d)) found)))))))
         harness-sessions)))
    (setq found (nreverse found))
    (unless dry-run
      (dolist (f found)
        (harness-session--discard-tmp (plist-get f :dir) (plist-get f :root)))
      (dolist (root roots)
        (harness-session--tmp-purge-trash root))
      (when found
        (let ((n (length (delete-dups (mapcar (lambda (f) (plist-get f :id)) found)))))
          (harness-log 'info "session: deleted the temporary directories of %d finished session%s"
                       n (if (= n 1) "" "s")))))
    (mapcar (lambda (f) (list :id (plist-get f :id) :dir (plist-get f :dir))) found)))

(defvar harness-session--tmp-sweep-delay 120
  "Seconds after the session module starts before the first sweep, or nil.
Internal, not an option (see docs/configuration-audit.md): a harness
that has just started has other things to do, and the sessions and the
tasks must be loaded first.  Nil sets no timer at all, as the tests
have it, so that no suite sweeps behind its back.")

(defconst harness-session--tmp-sweep-interval 1800
  "Seconds between two sweeps of the temporary directories.")

(defvar harness-session--tmp-timer nil
  "The timer that sweeps the temporary directories, or nil.")

(defun harness-session--tmp-sweep-on-timer ()
  "Sweep the temporary directories (`harness-session--tmp-sweep'); log a failure.
A sweep that must wait for the tasks module
\(`harness-session--tmp-sweep-blocked') says so in the debug log only:
for a harness without a working tasks module it would be said every
half hour."
  (if-let* ((why (harness-session--tmp-sweep-blocked)))
      (harness-log 'debug "session: not sweeping the temporary directories: %s" why)
    (condition-case err
        (harness-session--tmp-sweep)
      (error (harness-log 'warn "session: could not sweep the temporary directories: %s"
                          (harness-error-message err))))))

(defun harness-session--tmp-arm ()
  "Start the timer that sweeps the temporary directories, unless there is one.
A module that starts again (a reload) keeps the timer it has."
  (unless (or (timerp harness-session--tmp-timer)
              (null harness-session--tmp-sweep-delay))
    (setq harness-session--tmp-timer
          (run-at-time harness-session--tmp-sweep-delay harness-session--tmp-sweep-interval
                       #'harness-session--tmp-sweep-on-timer))))

(defun harness-session--tmp-disarm ()
  "Stop the timer that sweeps the temporary directories."
  (when (timerp harness-session--tmp-timer)
    (cancel-timer harness-session--tmp-timer))
  (setq harness-session--tmp-timer nil))

;;;; Methods: lifecycle

(harness-defmethod session/create (&rest plist)
  "Create a session.  PLIST needs `:cwd'; see docs/architecture.md for the rest.
A `btw' session without `:model' runs on `harness-btw-model', by
default the simple tier of the provider of `harness-model', both as
configured at `:cwd'; without `:thinking' it thinks at
`harness-btw-thinking' fitted to the levels its model offers (that
level, else the nearest it offers below it, else its weakest:
`harness-session--btw-thinking'), else at `harness-thinking' when no
level is configured or the model lists none.  A setting the policy
fixes (see `harness-session--policy-options') has the policy's value,
whatever PLIST asks for: a BTW's model is the policy's `harness-model',
its thinking is not.  `:ext' gives it settings of the modules that keep
some for a session (see `session/set-ext'), a plist."
  (let* ((plist (harness-session--without-pinned plist (or (plist-get plist :kind) 'main)))
         (cwd (or (plist-get plist :cwd) (error "The session/create method needs :cwd")))
         (host (or (plist-get plist :host) (file-remote-p cwd)))
         (cwd (file-name-as-directory (expand-file-name cwd)))
         (kind (or (plist-get plist :kind) 'main))
         (project (or (plist-get plist :project)
                      (if (harness-method-exists-p 'project/root) (harness-call 'project/root cwd) cwd)))
         (model (or (plist-get plist :model)
                    (let ((usual (harness-session--config 'harness-model cwd)))
                      ;; A model the policy fixes is no one's to choose.
                      (if (and (eq kind 'btw) (not (harness-session--pinned :model kind)))
                          (harness-session--btw-model usual cwd)
                        usual))))
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
          ;; Nothing is copied from a parent: a fork is made with the
          ;; `:ext' its maker gives it.
          (harness-session-ext s) (harness-session--ext-value (plist-get plist :ext))
          (harness-session-loaded s) t)
    ;; Without a config module the defaults are the options' values,
    ;; which hold the policy's already; this makes sure either way.
    (harness-session--apply-policy s)
    (puthash (harness-session-id s) s harness-sessions)
    (harness-session--save (harness-session-id s))
    (harness-session--tmp-dir s)
    (harness-emit 'session/created (harness-session-id s) (harness-session-plist s))
    ;; Announced and returned as it is now: a subscriber of
    ;; `session/created' may have set something on it (its `:ext', say).
    (harness-session--announce s)))

(harness-defmethod session/get (id)
  "Return the public plist of session ID."
  (harness-session-plist (harness-session--get id)))

(harness-defmethod session/exists-p (id)
  "Non-nil when session ID is known."
  (and (gethash id harness-sessions) t))

(harness-defmethod session/tmp-dir (id)
  "Return the temporary directory of session ID, made if missing.
Every local session has one of its own, harness-UID/ID in the
temporary directory `harness-session-tmp-directory' chooses (by
default /var/tmp, on the disk, where /tmp is often a RAM disk),
private to the user.  It is made with the session, made again whenever
it is asked for and missing, and deleted with the session, or once the
session is finished (see `session/tmp-sweep').  The permission layer
lets the session use it, the sandbox lets its commands write there, and
the system prompt names it.  Nil for a remote session, for an internal
one (see `session/internal-start'), and when no directory of the user's
own can be had there: the temporary directory is shared, so a
directory somebody else made, or a symbolic link, is refused."
  (harness-session--tmp-dir (harness-session--get id)))

(harness-defmethod session/tmp-sweep (&optional dry-run)
  "Delete the temporary directories of the sessions that are over; return them.
The harness does this by itself a couple of minutes after it starts and
every half hour (`harness-session--tmp-sweep'); this does it now.  A
session's directory goes when its task is done (a sub-agent goes with
its task) or, with no task, when it is closed, and that has been so for
`harness-session-tmp-retention-days'.  A session at work, blocked
on the user, or open keeps its directory, and so does every directory
no session of this harness names.  Returns a list of (:id ID :dir DIR),
the directories gone; with DRY-RUN true, the ones that would go, and
nothing is deleted."
  (harness-session--tmp-sweep (harness-json-true-p dry-run)))

(harness-defmethod session/list (&optional filter)
  "Return session plists matching FILTER, newest first.
FILTER keys: :project :status :kind :parent-id :active :ids.
`:ids' is a list of session ids: only the sessions it names match, and
nil (or a missing key) matches every session, as the other keys do."
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
                  (or (null (plist-get filter :ids))
                      (member (harness-session-id s) (plist-get filter :ids)))
                  (or (null (plist-get filter :active))
                      (not (eq (harness-session-status s) 'inactive))))
         (push (harness-session-plist s) out)))
     harness-sessions)
    (sort out (lambda (a b) (> (plist-get a :updated) (plist-get b :updated))))))

(harness-defmethod session/delete (id)
  "Delete session ID and its files, its temporary directory included.
The directory is gone at once; what was in it is deleted in the background."
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
  "Mark session ID inactive (not open anywhere).
A closed session waits for nobody: what it still has pending, with no turn
running to read the answers, is dismissed (`session/pending-dismiss'), so
that no UI goes on asking the user a question that nothing waits for.  A
turn that still runs is left to end by itself, and dismisses what its
calls wait on when it does."
  (let ((s (harness-session--get id)))
    (setf (harness-session-status s) 'inactive)
    (harness-emit 'session/status id 'inactive)
    (harness-emit 'session/deactivated id)
    (unless (harness-session--turn-runs-p id)
      (harness-call 'session/pending-dismiss id "the session was closed before anyone answered"))
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
  "Return the hint text that says setting KEY changed to VALUE, or nil.
Nil for a setting that changes without a hint, such as `:allowed-dirs'."
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
wins over it.  A setting the policy fixes (see
`harness-session--policy-options') cannot change: asking for another
value signals an error and changes nothing, asking for the policy's
changes nothing either."
  (let* ((s (harness-session--get id))
         (persist (plist-get plist :persist))
         (silent (plist-get plist :silent))
         changes)
    (harness-session-check-policy plist (harness-session-kind s))
    (cl-loop for (k v) on plist by #'cddr
             when (and (memq k harness-session--settings)
                       (not (harness-session--pinned k (harness-session-kind s))))
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

(harness-defmethod session/select (&optional filter)
  "Return the session plists FILTER selects, newest first.
FILTER is `session/list''s filter (`:project' `:status' `:kind'
`:parent-id' `:active' `:ids'), plus `:except', a list of session ids to
leave out, and `:tasks': non-nil adds the sessions of the current tasks
of every project (`task/session-ids'), whatever the other keys say, so
an inactive session a task goes on in is not missed, and leaves out
the sessions of completed and cancelled tasks, the done and cancelled
columns of the board, even an active one: a bulk change must not reach
a task that is over.  `:ids'
limits even that: a session it does not name is never selected.  An
internal session (see `session/internal-start') is selected only when
`:kind' asks for kind `internal', even when `:ids' names it: it records
a call and goes on with nothing, so a bulk change has nothing to do
there.  Nil selects every other session.  This is the selection of
`session/set-all', `priority/set-all', `supervisor/set-all' and of the
handoff's `handoff/check-all' and `handoff/switch-all'."
  (let* ((except (plist-get filter :except))
         (tasks (plist-get filter :tasks))
         (ids (plist-get filter :ids))
         (internal (eq (plist-get filter :kind) 'internal))
         (done (when (and tasks (harness-method-exists-p 'task/session-ids))
                 (harness-call 'task/session-ids (list :columns '("done" "cancelled")))))
         (selected (harness-call 'session/list (harness-plist-remove filter :except :tasks))))
    (when (and tasks (harness-method-exists-p 'task/session-ids))
      (let ((have (mapcar (lambda (s) (plist-get s :id)) selected))
            (more nil))
        (dolist (id (harness-call 'task/session-ids))
          (when (and (not (member id have)) (gethash id harness-sessions)
                     (or (null ids) (member id ids)))
            (push id have)
            (push (harness-session-plist (gethash id harness-sessions)) more)))
        (when more
          (setq selected (sort (append selected more)
                               (lambda (a b) (> (plist-get a :updated) (plist-get b :updated))))))))
    (cl-remove-if (lambda (s) (or (member (plist-get s :id) except)
                                  (member (plist-get s :id) done)
                                  (and (not internal) (eq (plist-get s :kind) 'internal))))
                  selected)))

(harness-defmethod session/set-all (settings &optional filter)
  "Apply SETTINGS to every session FILTER selects; return the ids changed.
SETTINGS is a plist of keys `session/update' accepts, usually just
`:model'.  FILTER is the one of `session/select': `session/list''s
filter (`:project' `:status' `:kind' `:parent-id' `:active' `:ids'),
plus `:except', a list of session ids to leave alone, and `:tasks' to
add the sessions of the current tasks; nil means every session.  `:ids',
a list of session ids, limits the change to the sessions it names.  A
session whose value is already the one asked for is left alone (see
`harness-setting-equal-p': a false non-interactive is off, a mode's
name is the mode), and one that changes is changed exactly as
`session/update' would (same event, same hint).  The return value
lists the ids that changed, newest first."
  (let ((keys (cl-intersection (harness-plist-keys settings) harness-session--settings))
        changed)
    (dolist (s (harness-call 'session/select filter))
      (let ((id (plist-get s :id)))
        (when (cl-some (lambda (k) (not (harness-setting-equal-p k (plist-get s k) (plist-get settings k))))
                       keys)
          (apply #'harness-call 'session/update id settings)
          (push id changed))))
    (nreverse changed)))

(harness-defmethod session/set-ext (id key value &optional hint)
  "Set the setting KEY of session ID's `:ext' to VALUE; return the session plist.
The `ext' plist is where modules keep what they remember about a
session, such as whether it is a supervisor's (see
`harness-session--ext-value').  KEY is a keyword, or a symbol or a
string naming one (what a client over the wire can send).  VALUE nil
removes KEY; `:false' is stored as it is and means an explicit off.  A
value must come back from the JSON store of the record as it is: t,
`:false', a string, a number, or a list or plist of those; another is
kept in memory but logged, as it would not survive a restart.  A fork
does not get its parent's settings: each module decides what its own
forks take.

The change is saved and announced like any other, and `session/ext-changed'
\(ID KEY VALUE) says which setting changed, KEY being the keyword and
VALUE nil once it was removed.  A HINT that is a string is added to the
transcript as a hint (`session/hint')."
  (let* ((s (harness-session--get id))
         (key (harness-session--ext-key key))
         (ext (harness-session-ext s)))
    (unless (harness-session--ext-json-p value)
      (harness-log 'warn "session %s: the value %S of ext %s would not survive the JSON store"
                   id value key))
    ;; A new plist each time: whoever holds the earlier one keeps what it saw.
    (setf (harness-session-ext s)
          (if (null value)
              (harness-plist-remove ext key)
            (plist-put (copy-sequence ext) key value)))
    (when (and (stringp hint) (not (harness-string-blank-p hint)))
      (harness-call 'session/hint id hint))
    (harness-emit 'session/ext-changed id key value)
    (harness-session--touch s)
    (harness-session-plist s)))

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

;;;; Methods: internal sessions
;;
;; See the Commentary.  The provider module starts and finishes them
;; around a request that names its job (`provider/complete').

(defun harness-session--internal-prompt (prompt)
  "Return PROMPT as an internal session keeps it.
A prompt longer than `harness-session--internal-prompt-max' characters
is cut there, and a note at the end says how long it was."
  (if (<= (length prompt) harness-session--internal-prompt-max)
      prompt
    (concat (substring prompt 0 harness-session--internal-prompt-max)
            (format "\n\n[The prompt was cut here: it had %d characters, the first %d are kept.]"
                    (length prompt) harness-session--internal-prompt-max))))

(defun harness-session--state-dir-p (dir)
  "Non-nil when DIR is `harness-state-directory' or lies inside it."
  (and (bound-and-true-p harness-state-directory)
       (not (file-remote-p dir))
       (string-prefix-p (file-name-as-directory (expand-file-name harness-state-directory))
                        (file-name-as-directory (expand-file-name dir)))))

(defun harness-session--internal-prune (keep)
  "Delete the oldest internal sessions until at most KEEP remain.
Only sessions that are not running are deleted, the oldest created
first, so a call still under way keeps its session even when that
leaves more than KEEP."
  (let ((count 0) idle)
    (maphash (lambda (_ s)
               (when (eq (harness-session-kind s) 'internal)
                 (cl-incf count)
                 (unless (eq (harness-session-status s) 'running)
                   (push s idle))))
             harness-sessions)
    (when (> count keep)
      (dolist (s (take (- count keep)
                       (sort idle (lambda (a b) (< (harness-session-created a)
                                                   (harness-session-created b))))))
        (condition-case err
            (harness-call 'session/delete (harness-session-id s))
          (error (harness-log 'warn "session: could not delete internal session %s: %s"
                              (harness-session-id s) (harness-error-message err))))))))

(harness-defmethod session/internal-start (&rest plist)
  "Start an internal session, the record of one model call; return its id.
The harness makes some model calls on its own, outside any turn: the
permission judge's, a session's name, a recap.  Each is recorded as a
session of kind `internal', running until `session/internal-finish'.
PLIST's `:job' says what the call is for and names the session,
`:model' is the model it asks, and `:prompt' what it asks, appended as
a user message the harness sent, cut at
`harness-session--internal-prompt-max' characters with a note saying
so.  `:parent-id' is the session the call is made for, kept only when
that session exists.  `:cwd' and `:host' say where the session is,
by default where its parent is, else in `harness-state-directory';
`:project' is its project, by default its parent's, else the one of
its directory, where a directory of `harness-state-directory', the
harness's own, is a project of its own rather than part of the one
around it.  Starting one deletes the oldest internal sessions that
are not running beyond `harness-session--internal-keep'.  An internal
session has no temporary directory, the policy fixes none of its
settings, and the agent refuses to prompt it: it cannot be continued."
  (let* ((job (let ((j (plist-get plist :job)))
                (if (and (stringp j) (not (string-blank-p j))) j "Internal call")))
         (parent-id (plist-get plist :parent-id))
         (parent (and parent-id (gethash parent-id harness-sessions)))
         (cwd (plist-get plist :cwd))
         (host (or (plist-get plist :host) (and parent (not cwd) (harness-session-host parent))))
         (cwd (or cwd (and parent (harness-session-cwd parent))
                  (bound-and-true-p harness-state-directory) default-directory))
         (project (or (plist-get plist :project)
                      (and parent (harness-session-project parent))
                      ;; The harness's own directories (the pet's, say)
                      ;; belong to no project around them.
                      (and (harness-session--state-dir-p cwd)
                           (file-name-as-directory (expand-file-name cwd)))))
         (model (plist-get plist :model))
         (prompt (plist-get plist :prompt))
         (id (plist-get (apply #'harness-call 'session/create
                               :kind 'internal :name job :cwd cwd
                               (append (and model (list :model model))
                                       (and host (list :host host))
                                       (and project (list :project project))
                                       (and parent (list :parent-id parent-id))))
                        :id)))
    (when (and (stringp prompt) (not (string-empty-p prompt)))
      (harness-call 'session/append id
                    (list :kind 'user :content (harness-session--internal-prompt prompt)
                          :meta (list :from (harness-sender-system job)))))
    (harness-call 'session/set-status id 'running)
    (harness-session--internal-prune harness-session--internal-keep)
    id))

(harness-defmethod session/internal-finish (id &rest plist)
  "Finish internal session ID, recording how its model call ended.
PLIST keys: `:reply', the text the model wrote, appended as its reply
unless empty; `:stop-reason', how the call ended, a symbol or its name;
`:error', what went wrong.  A call that ended in `error' or was
`cancelled' gets a hint saying so, with the error.  The session is then
idle.  A session that is gone is left alone: this never signals for
one.  Return ID, nil when it is gone."
  (when (gethash id harness-sessions)
    (let ((reply (plist-get plist :reply))
          (stop (let ((r (plist-get plist :stop-reason))) (if (stringp r) (intern r) r)))
          (err (let ((e (plist-get plist :error)))
                 (and e (not (equal e "")) (if (stringp e) e (format "%s" e))))))
      (when (and (stringp reply) (not (string-empty-p reply)))
        (harness-call 'session/append id (list :kind 'assistant :content reply)))
      (pcase stop
        ('error (harness-call 'session/hint id (format "Error: %s" (or err "unknown"))))
        ('cancelled (harness-call 'session/hint id (if err (format "The call was cancelled: %s" err)
                                                     "The call was cancelled."))))
      (harness-call 'session/set-status id 'idle)
      id)))

;;;; Methods: moving to another directory
;;
;; A session works in the directory it was started in, and belongs to
;; that directory's project, until it moves: `session/move' gives it
;; another working directory, and with it the project the session list
;; files it under.  The provider conversation stays behind.  The Claude
;; Code CLI keeps its conversations per directory and cannot resume one
;; elsewhere, so the provider state goes, and the next turn starts a new
;; conversation that gets the transcript as text
;; (`harness-provider-history-text').
;;
;; A session in the middle of a turn moves when the turn ends: its
;; provider process and the system prompt the model works from stay in
;; the old directory until then, and the provider records its state as
;; the turn goes on.  The move waits in the record (`:move'), so a
;; harness that stops first makes it as it loads the session again.
;;
;; Some moves are refused:
;;   - a session working in a worktree, whose branch belongs to the
;;     merge queue;
;;   - a directory on another host: the session's grants hold on its
;;     host, and its temporary directory is this machine's;
;;   - a directory that does not exist;
;;   - whatever a module vetoes through the sync filter
;;     `session/before-move'.  Its value is (:proceed t) and its
;;     arguments the session plist and the new directory; a filter
;;     that refuses returns (:proceed nil :reason WHY).  The tasks
;;     module keeps a task's session in its task's directory this way,
;;     and the merge queue keeps a session that branches are queued to
;;     merge into.

(defun harness-session--move-value (value)
  "Return VALUE, a stored move, as `session/move' records one, or nil.
A move is (:cwd DIR :project ROOT :keep-old-dir BOOL); anything without
a directory is none."
  (when (and (consp value) (stringp (plist-get value :cwd)))
    (list :cwd (plist-get value :cwd)
          :project (let ((p (plist-get value :project))) (and (stringp p) p))
          :keep-old-dir (and (harness-json-true-p (plist-get value :keep-old-dir)) t))))

(defun harness-session--label (s)
  "Return the name of session S, or the start of its id when it has none."
  (let ((name (harness-session-name s)) (id (format "%s" (harness-session-id s))))
    (if (and (stringp name) (not (harness-string-blank-p name)))
        name
      (substring id 0 (min 8 (length id))))))

(defun harness-session--full-cwd (s)
  "Return the working directory of session S, a remote name on a remote host."
  (let ((cwd (harness-session-cwd s))
        (host (harness-session-host s)))
    (if (and host (not (file-remote-p cwd))) (concat host cwd) cwd)))

(defun harness-session--move-target (s dir)
  "Return DIR, where session S is to move, as an absolute directory name.
A relative DIR is relative to S's working directory, and a local name
is one on S's host, as for its tools.  A remote session's DIR may not
start with ~: only the host knows where that is."
  (let* ((cwd (harness-session--full-cwd s))
         (host (file-remote-p cwd))
         (dir (string-trim dir)))
    (file-name-as-directory
     (cond ((file-remote-p dir) (expand-file-name dir))
           ((null host) (expand-file-name dir cwd))
           ((string-prefix-p "~" dir)
            (signal 'harness-error (list (format "Give an absolute path on %s rather than %s" host dir))))
           (t (concat host (expand-file-name dir (file-local-name cwd))))))))

(defun harness-session--project-of (dir)
  "Return the project root of DIR, as `session/create' finds it."
  (if (harness-method-exists-p 'project/root) (harness-call 'project/root dir) dir))

(defun harness-session--turn-running-p (id)
  "Non-nil while session ID runs a turn."
  (if (harness-method-exists-p 'agent/running)
      (harness-call 'agent/running id)
    (eq (harness-session-status (harness-session--get id)) 'running)))

(defun harness-session--move-check (s dir)
  "Return how session S moves to DIR, or signal why it cannot.
The value is (:id ID :name NAME :cwd NEW :host HOST :project ROOT
:old-cwd OLD :old-project OLD-ROOT :defer BOOL :cancel BOOL).  NEW is
DIR as an absolute directory name on S's host, ROOT its project.
DEFER says S runs a turn, so the move waits for the turn to end.
CANCEL says NEW is where S works already: moving there only cancels the
move S waits to make, and with none waiting it is refused."
  (unless (and (stringp dir) (not (harness-string-blank-p dir)))
    (signal 'harness-error (list "Give the directory to move the session to")))
  (let ((label (harness-session--label s))
        (old (harness-session--full-cwd s)))
    (when (harness-session-worktree s)
      (signal 'harness-error
              (list (format "Session %s works in the worktree %s, whose branch merges back through the merge queue; it cannot move. Start or fork a session in the other directory instead"
                            label (abbreviate-file-name (harness-session-worktree s))))))
    (let* ((new (harness-session--move-target s dir))
           (host (file-remote-p new)))
      (unless (equal host (file-remote-p old))
        (signal 'harness-error
                (list (format "%s is on %s and session %s on %s: a session cannot move to another host"
                              new (or host "this machine") label (or (file-remote-p old) "this machine")))))
      (unless (or host (file-directory-p new))
        (signal 'harness-error (list (format "%s is not a directory" (abbreviate-file-name new)))))
      (let ((same (or (equal new (file-name-as-directory old))
                      (and (not host) (file-equal-p new old)))))
        (cond
         ((and same (null (harness-session-move s)))
          (signal 'harness-error (list (format "Session %s works in %s already" label (abbreviate-file-name old)))))
         ((not same)
          (let ((gate (harness-run-filter 'session/before-move (list :proceed t) (harness-session-plist s) new)))
            (unless (plist-get gate :proceed)
              (signal 'harness-error
                      (list (format "Session %s cannot move: %s" label
                                    (or (plist-get gate :reason) "a module refused it"))))))))
        (list :id (harness-session-id s) :name (harness-session-name s)
              :cwd new :host host
              :project (if same (harness-session-project s) (harness-session--project-of new))
              :old-cwd old :old-project (harness-session-project s)
              :defer (and (not same) (harness-session--turn-running-p (harness-session-id s)) t)
              :cancel (and same t))))))

(defun harness-session--moved-grants (s old move)
  "Return the grants of session S after MOVE away from OLD, its working directory.
A grant written relative to the working directory keeps naming what it
named, and with MOVE's `:keep-old-dir' OLD joins them, unless the new
directory holds it already."
  (let* ((local (file-local-name old))
         (grants (mapcar (lambda (d) (if (and (stringp d) (not (file-name-absolute-p d)) (not (file-remote-p d)))
                                         (expand-file-name d local)
                                       d))
                         (harness-session-allowed-dirs s)))
         (new (plist-get move :cwd)))
    (if (and (plist-get move :keep-old-dir)
             (not (member old grants))
             (not (string-prefix-p new (file-name-as-directory old))))
        (append grants (list old))
      grants)))

(defun harness-session--apply-move (s move)
  "Move session S as MOVE, a pending move, says, now.
MOVE is (:cwd NEW :project ROOT :keep-old-dir BOOL): S works in NEW
from now on, and belongs to the project at ROOT (by default NEW's).
Its provider state goes, so the next turn starts a new conversation in
NEW.  Emits `session/updated' and `session/moved'; the record is
written at once."
  (let* ((id (harness-session-id s))
         (old (harness-session--full-cwd s))
         (new (plist-get move :cwd))
         (host (file-remote-p new))
         (project (or (plist-get move :project) (harness-session--project-of new)))
         (grants (harness-session--moved-grants s old move))
         (kept (and (member old grants) (not (member old (harness-session-allowed-dirs s)))))
         (conversation (harness-session-provider-state s)))
    (setf (harness-session-move s) nil)
    ;; The provider conversation stays in OLD: the Claude Code CLI can
    ;; only resume a conversation in the directory it was held in.  A
    ;; process that held it closes once it is idle; the next turn starts
    ;; a new one in NEW, which gets the transcript.
    (harness-call 'session/set-provider-state id nil)
    (setf (harness-session-cwd s) new
          (harness-session-host s) host
          (harness-session-project s) project
          (harness-session-allowed-dirs s) grants)
    (harness-call 'session/hint id
                  (concat (format "Moved to %s (was %s)" (abbreviate-file-name new) (abbreviate-file-name old))
                          (if kept (format "; %s stays allowed" (abbreviate-file-name old)) "")
                          (if conversation
                              "; the next turn starts a new provider conversation there, which gets the transcript"
                            "")))
    (harness-emit 'session/updated id (list :cwd new :host host :project project :allowed-dirs grants))
    (harness-emit 'session/moved id old new)
    (harness-session--touch s)
    (harness-session--save id)
    (harness-session-plist s)))

(defun harness-session--apply-pending-move (id &rest _)
  "Make the move session ID waits to make, now that its turn ended.
On `agent/turn-ended'.  A move that cannot be made any more (its
directory went, a module refuses it now) is dropped, and a hint says
why."
  (when-let* ((s (gethash id harness-sessions))
              (move (harness-session-move s)))
    (condition-case err
        (let ((check (harness-session--move-check s (plist-get move :cwd))))
          (if (plist-get check :cancel)
              (progn (setf (harness-session-move s) nil)
                     (harness-session--touch s)
                     (harness-session--save id))
            (harness-session--apply-move s (append (list :cwd (plist-get check :cwd)) move))))
      (error
       (setf (harness-session-move s) nil)
       (harness-call 'session/hint id (format "Not moved to %s: %s" (abbreviate-file-name (plist-get move :cwd))
                                              ;; A refusal reads as its message alone.
                                              (if (and (eq (car err) 'harness-error) (stringp (cadr err)) (null (cddr err)))
                                                  (cadr err)
                                                (harness-error-message err))))
       (harness-session--touch s)
       (harness-session--save id)))))

(harness-defmethod session/move-check (id dir)
  "Return how session ID would move to DIR, or signal why it cannot.
Nothing changes: this is what a prompt asking the user about the move
says.  See `harness-session--move-check' for the value."
  (harness-session--move-check (harness-session--get id) dir))

(harness-defmethod session/move (id dir &rest options)
  "Move session ID to the working directory DIR, and to DIR's project.
DIR is absolute, or relative to the session's working directory, and
on the session's host.  OPTIONS: `:keep-old-dir' non-nil grants the
old working directory to the session, so it may still reach it;
`:project' names the root of the project to file the session under,
by default the one `project/root' finds for DIR (a UI passes its own,
as for `session/new').
The session's provider conversation stays behind: its next turn starts
a new one, which gets the transcript.  A session running a turn moves
when the turn ends, and the plist returned has the move it waits to
make in `:move'.  Moving a session to where it works cancels that.
Signals when the session cannot move (another host, a worktree, a
directory that is not one, a module's veto through the filter
`session/before-move').  Returns the session plist."
  (let* ((s (harness-session--get id))
         (check (harness-session--move-check s dir))
         (project (plist-get options :project))
         (move (list :cwd (plist-get check :cwd)
                     :project (if (and (stringp project) (not (harness-string-blank-p project)))
                                  (file-name-as-directory (expand-file-name project))
                                (plist-get check :project))
                     :keep-old-dir (and (harness-json-true-p (plist-get options :keep-old-dir)) t))))
    (cond
     ((plist-get check :cancel)
      (let ((pending (harness-session-move s)))
        (setf (harness-session-move s) nil)
        (harness-call 'session/hint id (format "Move to %s cancelled; the session stays in %s"
                                               (abbreviate-file-name (plist-get pending :cwd))
                                               (abbreviate-file-name (plist-get check :old-cwd))))
        (harness-session--touch s)
        (harness-session--save id)))
     ((plist-get check :defer)
      (setf (harness-session-move s) move)
      (harness-call 'session/hint id (format "Moves to %s when this turn ends"
                                             (abbreviate-file-name (plist-get move :cwd))))
      (harness-session--touch s)
      (harness-session--save id))
     (t (harness-session--apply-move s move)))
    (harness-session-plist s)))

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

(harness-defmethod session/btw (id &optional name model)
  "Start a BTW side conversation over session ID; return its session.
It is a new, empty session of kind `btw' named NAME, sharing nothing
with ID or with any other BTW, even one opened over ID before.  It has
no transcript and no fork node.  It has no provider state either, so
its first turn starts a provider conversation of its own (a new CLI
session for Claude Code).  It has no directory grants.  It works where
ID does: cwd, project, host, worktree and permission mode are ID's,
everything else is the configured default, as for any new session.

A BTW is a quick question on the side, so it does not run on ID's model
but on a cheap one: `harness-btw-model' as configured at ID's cwd, by
default the simple tier of the provider of ID's model, which stays ID's
when the provider names none (`harness-session--btw-model').  MODEL, a
PROVIDER:NAME, picks another model for this one BTW and wins over that
setting; blank is none.  It is chosen here, once: from then on the BTW
is a session like any, and its model can be switched like any other's.
A model the policy does not allow signals an error
\(`harness-session-check-policy'), and a policy that fixes
`harness-model' fixes a BTW's too, whatever the setting or MODEL say.

It thinks at `harness-btw-thinking' as configured there, a low level
for quick questions, fitted to the levels its model offers: that level,
else the nearest it offers below it, else the model's weakest
\(`harness-session--btw-thinking').  So on ID's own model, as on a
cheaper one, it thinks no harder than the model has to, whatever ID's
level is.  It starts at ID's level only where nothing is fitted: with
no level configured (nil), or a model whose catalogue lists none.  That
level is kept only if its own model is ID's or lists it, else the BTW
thinks at `harness-thinking'.  Its `:parent-id' is ID only so that the
session list and the tree show it under ID."
  (let* ((parent (harness-session--get id))
         (cwd (harness-session-cwd parent))
         (asked (and (stringp model) (not (string-blank-p model)) (string-trim model))))
    (when asked
      (harness-session-check-policy (list :model asked) 'btw))
    (let* ((btw-model (or (car (harness-session--pinned :model 'btw))
                          asked
                          (harness-session--btw-model (harness-session-model parent) cwd)))
           (inherited (harness-session-thinking parent)))
      (harness-call 'session/create
                    :kind 'btw :parent-id id :name name
                    :cwd cwd
                    :project (harness-session-project parent)
                    :host (harness-session-host parent)
                    :worktree (harness-session-worktree parent)
                    :model btw-model
                    :thinking (or (harness-session--btw-thinking btw-model cwd)
                                  ;; ID's level is for ID's model: another
                                  ;; one may not offer it.
                                  (and inherited
                                       (or (equal btw-model (harness-session-model parent))
                                           (member inherited (harness-session--model-levels btw-model)))
                                       inherited))
                    :permission-mode (harness-session-permission-mode parent)))))

(defun harness-session--family (s)
  "Return every session struct in the fork family of S.
The internal sessions made for its members (see
`session/internal-start') are not of it, but for S itself: they share
no node with the conversation."
  (let ((root s))
    (while (and (harness-session-parent-id root)
                (gethash (harness-session-parent-id root) harness-sessions))
      (setq root (gethash (harness-session-parent-id root) harness-sessions)))
    (let ((family (list root)) (frontier (list root)))
      (while frontier
        (let ((cur (pop frontier)))
          (maphash (lambda (_ c)
                     (when (and (equal (harness-session-parent-id c) (harness-session-id cur))
                                (or (eq c s) (not (eq (harness-session-kind c) 'internal)))
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
  "Append NODE to session ID after the current head; return the stored node.
The node is written to the node log before it becomes the head.  A
write that fails (a node the log cannot encode, a full disk) signals
and leaves the session as it was: a node kept in memory only would
parent the nodes written after it, and when the session is loaded again
their parent would be missing, which cuts the transcript there.
The node's kind `user' or `assistant' (a symbol or a string) also sets the
session's `:last-message' to the node's `:ts', which is now unless NODE
has one.  Nothing else moves it: not a hint, thinking, a tool call or
result, nor a compaction."
  (let* ((s (harness-session--get id))
         (n (copy-sequence node)))
    (harness-session--load-nodes s)
    (setq n (plist-put n :id (or (plist-get n :id) (concat "n-" (harness-short-id 10)))))
    (setq n (plist-put n :session id))
    (setq n (plist-put n :ts (or (plist-get n :ts) (float-time))))
    (setq n (plist-put n :parent (harness-session-head s)))
    (harness-session--persist-node s n)
    (puthash (plist-get n :id) n (harness-session-nodes s))
    (setf (harness-session-head s) (plist-get n :id))
    (let ((kind (plist-get n :kind)))
      (when (memq (if (stringp kind) (intern kind) kind) '(user assistant))
        (setf (harness-session-last-message s) (plist-get n :ts))))
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

(harness-defmethod session/discard-nodes (id node-ids)
  "Remove NODE-IDS from the transcript of session ID; return the ids removed.
The named nodes go wherever they are.  A node that kept nodes follow --
a hint written after the failure, say, before the step is tried again
-- is no reason to keep a partial answer, so it is re-parented to the
last node kept before the removed one, and the transcript stays one
whole chain, in memory and when it is loaded again.  The head moves to
the newest node that stays, and the removal is announced
\(`session/nodes-removed', and `session/head-moved' when it moved), so a
UI following the session drops what went.  This is how the agent drops
the partial answer of a step that failed and is tried again, rather
than sending it to the model twice.  Ids that name no node are ignored;
the return value says what was removed."
  (let* ((s (harness-session--get id))
         (table (progn (harness-session--load-nodes s) (harness-session-nodes s)))
         (gone (make-hash-table :test 'equal))
         (removed nil))
    (dolist (node-id node-ids)
      (when (gethash node-id table) (puthash node-id t gone) (push node-id removed)))
    (setq removed (nreverse removed))
    (when removed
      ;; Every node whose parent goes moves to the last kept ancestor
      ;; before it, and says so where the node log is kept.
      (dolist (node (let (all) (maphash (lambda (_ n) (push n all)) table) all))
        (let ((parent (plist-get node :parent)))
          (when (and parent (gethash parent gone))
            (let ((ancestor (plist-get (gethash parent table) :parent)))
              (while (and ancestor (gethash ancestor gone))
                (setq ancestor (plist-get (gethash ancestor table) :parent)))
              (puthash (plist-get node :id)
                       (plist-put (copy-sequence node) :parent ancestor)
                       table)
              (harness-session--persist-node
               s (list :id (plist-get node :id) :parent ancestor) t)))))
      ;; The head cannot be a node that went.
      (let* ((old-head (harness-session-head s))
             (head old-head))
        (while (and head (gethash head gone))
          (setq head (plist-get (gethash head table) :parent)))
        (setf (harness-session-head s) head)
        (dolist (node-id removed)
          (remhash node-id table)
          (harness-call 'store/append (harness-session--nodes-name id)
                        (list :_op "delete" :id node-id)))
        (harness-session--touch s)
        (harness-emit 'session/nodes-removed id removed)
        (unless (equal head old-head)
          (harness-emit 'session/head-moved id head))))
    removed))

(harness-defmethod session/hint (id text)
  "Append a system hint TEXT to session ID."
  (harness-call 'session/append id (list :kind 'hint :content text)))

;;;; Methods: pictures

(defcustom harness-session-image-max-bytes (* 16 1024 1024)
  "Largest picture file, in bytes, that `session/image' sends."
  :type 'integer :group 'harness)

(defun harness-session--shown-files (id)
  "Return the absolute names of the files the transcript of session ID shows.
They are the files its tool results hand the user (`:attachments', which
read_file fills with the picture or the video it read), the files the
report of a hand_in call names (the evidence on its result's `:meta')
and those of the report its task holds now.  A file that is none of
these is not shown, whoever asks for it."
  (let (files)
    (cl-flet ((note (item)
                (let ((path (and (consp item) (plist-get item :path))))
                  (when (and (stringp path) (not (string-empty-p path)))
                    (push (expand-file-name path) files)))))
      (dolist (node (harness-session--path (harness-session--get id)))
        (mapc #'note (append (plist-get node :attachments) nil))
        (mapc #'note (append (plist-get (plist-get (plist-get node :meta) :report) :evidence) nil)))
      (when-let* (((harness-method-exists-p 'task/for-session))
                  (task (harness-call 'task/for-session id)))
        (mapc #'note (append (plist-get (plist-get task :report) :evidence) nil))))
    files))

(harness-defmethod session/image (id path)
  "Return the picture PATH, a file session ID's transcript shows, as data.
The value is (:mime MIME :name NAME :size BYTES :data BASE64): the file's
bytes, read here, where the harness runs.  It is for a client that cannot
read PATH itself, a phone or any UI on another machine, and so could not
draw the screenshot a hand_in call handed in, nor the picture read_file
showed, which the transcript names by a path on this machine.

It is no way to read this machine.  Only a file the transcript shows is
given (`harness-session--shown-files'), by the name it is shown by; and
only a picture: its bytes must say so (`harness-image-mime-of-bytes'),
whatever its name claims, so that a link made to look like one gives
nothing away.  MIME is the type those bytes say.

Signal an error, in words for the person who sees it, when the session
shows no such file, the file is gone or cannot be read, is no picture, or
is larger than `harness-session-image-max-bytes'."
  (harness-session--get id)
  (let ((file (and (stringp path) (file-name-absolute-p path) (expand-file-name path))))
    (cond
     ((not (and file (member file (harness-session--shown-files id))))
      (error "Session %s shows no file %s" id path))
     ((not (and (file-regular-p file) (file-readable-p file)))
      (error "%s is gone from the harness's machine, or cannot be read" (file-name-nondirectory file)))
     (t
      (let ((size (harness-file-size (file-truename file)))
            (name (file-name-nondirectory file)))
        (when (and size (> size harness-session-image-max-bytes))
          (error "%s is %s, larger than the %s a picture may be"
                 name (harness-format-bytes size) (harness-format-bytes harness-session-image-max-bytes)))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally file)
          (let ((mime (harness-image-mime-of-bytes
                       (buffer-substring-no-properties (point-min) (min (point-max) 4097)))))
            (unless mime
              (error "%s is not a picture of a type clients draw (PNG, JPEG, GIF, WebP, BMP or SVG)" name))
            (base64-encode-region (point-min) (point-max) t)
            (list :mime mime :name name :size size :data (buffer-string)))))))))

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

(harness-defmethod session/queue-take (id &optional qids)
  "Return and remove the queued items of session ID, in queue order.
Without QIDS every item goes and the queue is cleared.  With QIDS, a
list of item ids (a vector of them works too, as JSON may give one),
only those items go and the others stay queued: that is how one queued
message is sent now (`agent/send-queue').  An id with no item is
skipped.  `session/queue-changed' tells what is left, and the session
is touched only when something was taken."
  (let* ((s (harness-session--get id))
         (queue (harness-session-queue s))
         (wanted (and qids (append qids nil)))
         (items (if qids
                    (cl-remove-if-not (lambda (it) (member (plist-get it :id) wanted)) queue)
                  queue)))
    (when items
      (setf (harness-session-queue s) (cl-remove-if (lambda (it) (memq it items)) queue))
      (harness-emit 'session/queue-changed id (harness-session-queue s))
      (harness-session--touch s))
    items))

(defun harness-session--turn-runs-p (id)
  "Non-nil when the agent says that a turn of session ID runs."
  (and (harness-method-exists-p 'agent/running)
       (harness-call 'agent/running id)
       t))

(harness-defmethod session/set-steering (id items)
  "Replace the messages the running turn of session ID has not taken with ITEMS.
A message sent to a turn that runs waits outside the transcript until
the turn takes it at its next step, and only then is a node, so that the
transcript reads in the order the model got things (see `agent/prompt').
Meanwhile the session carries it in `:steering', for a UI to show it
with the messages that wait, above the compose box.  Each item is
\(:id ID :text TEXT :ts TIME): ID is the id of the node the message
becomes, TEXT what the node will say, TIME when it was sent; `:blocks'
holds the message when it is more than text, with no bytes of a
picture, and `:from' who sent it when the user did not.  The turn is
the one to call this, whenever what it holds changes.  Nothing is
announced when ITEMS are what the session carries already;
`session/steering-changed' tells the rest.  The list is kept with the
record, so a harness that stops with messages waiting can give them back
after it (`harness-session--settle-steering'); the turn itself ends with
the process.  Return ITEMS."
  (let ((s (harness-session--get id)))
    (unless (equal items (harness-session-steering s))
      (setf (harness-session-steering s) items)
      (harness-emit 'session/steering-changed id items)
      (harness-session--touch s))
    items))

(defun harness-session--reconcile-status (s)
  "Make S enter or leave `blocked' as its pending requests come and go.
It leaves `blocked' for the status it had before, which `:status-before-block'
of its runtime keeps."
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

(harness-defmethod session/pending-update (id pid changes)
  "Merge CHANGES into the payload of pending request PID of session ID.
CHANGES is a plist of payload keys: a request is shown to the user the
moment it is made, and what is learned about it later, such as a
summary of a permission prompt a cheap model writes while the user
reads it, is added to it here.  Return the updated item, or nil when
nothing was updated: the session or the request is gone, answered
meanwhile.  The request stays what it is: the session's status and
update time stay, and the listeners of `session/pending-changed' hear
nothing.  `session/pending-updated' tells the clients that draw the
request, and the session is announced changed (`session/changed', so
that a client reading the session, not the events, has its pending list
as it is now)."
  (when-let* ((s (gethash id harness-sessions))
              (item (cl-find pid (harness-session-pending s)
                             :key (lambda (it) (plist-get it :id)) :test #'equal)))
    (let ((new (plist-put (copy-sequence item) :payload
                          (harness-plist-merge (plist-get item :payload) changes))))
      (setf (harness-session-pending s)
            (mapcar (lambda (it) (if (eq it item) new it)) (harness-session-pending s)))
      (harness-emit 'session/pending-updated id pid changes)
      ;; Not `harness-session--touch': the session did not change by this,
      ;; its update time stays; but what a client reads of it did.
      (harness-session--announce s)
      new)))

(harness-defmethod session/pending (id)
  "Return the pending requests of session ID."
  (harness-session-pending (harness-session--get id)))

(defun harness-session--dismiss-request (id item reason)
  "Dismiss the pending request ITEM of session ID, for REASON (words).
Whatever waits on a request ends it, so the one that holds it does: a
question is cancelled (`question/cancel'), a permission denied for the
call alone (`permission/answer'), and what waited on them goes on.  A
request that nobody holds any more -- its owner was reloaded, or is not
there -- is taken off the list all the same."
  (let ((pid (plist-get item :id)))
    (condition-case err
        (pcase (format "%s" (plist-get item :kind))
          ("question"
           (when (harness-method-exists-p 'question/cancel)
             (harness-call 'question/cancel id pid)))
          ("permission"
           (when (harness-method-exists-p 'permission/answer)
             (harness-call 'permission/answer id pid
                           (list :behavior 'deny :scope 'once :reason reason)))))
      (error (harness-log 'warn "session %s: dismissing request %s failed: %s"
                          id pid (harness-error-short-message err))))
    (when (cl-find pid (harness-session-pending (harness-session--get id))
                   :key (lambda (it) (plist-get it :id)) :test #'equal)
      (harness-call 'session/pending-resolve id pid nil))))

(harness-defmethod session/pending-dismiss (id &optional reason calls-only)
  "Dismiss the requests of session ID that no one will answer; return how many.
A request is a question or a permission prompt (see `session/pending-add'),
and every UI shows it until it is answered.  When what waited on it is
over -- the turn that asked ended, or the session was closed -- it must
not stay behind: the session would read as waiting for the user, and a
prompt would be shown that no answer can do anything with.  Each request
is dismissed by whoever holds it, as when a user decides: a question is
cancelled (`question/cancel'), a permission denied for the call alone
\(`permission/answer'), and the events say so.  REASON, words, is the
denial's reason.  With CALLS-ONLY non-nil only the requests that wait for
a tool call, those with a `:call-id' in their payload, go: the ones of a
turn that ended.  A question the harness asked on its own has no call,
and an owner that ends it."
  (let ((items (cl-remove-if-not
                (lambda (item) (or (not calls-only)
                                   (plist-get (plist-get item :payload) :call-id)))
                (copy-sequence (harness-session-pending (harness-session--get id)))))
        (reason (or reason "nobody answered it")))
    (dolist (item items)
      (harness-session--dismiss-request id item reason))
    (length items)))

(defvar harness-session--interrupted nil
  "The sessions the start of this harness found cut short, newest first.
Each is a plist (:id ID :status STATUS :pending PENDING :calls CALLS
:text TEXT): STATUS the status the session was saved with, `running'
or `blocked'; PENDING the requests it waited on; CALLS the tool calls
left without a result, each (:tool NAME :call-id ID); TEXT the hint
saying what it was doing.  See `session/interrupted'.")

(harness-defmethod session/interrupted ()
  "Return the sessions the start of this harness found cut short.
They were saved running or blocked: the harness stopped -- it crashed,
was killed, or its machine went down -- in the middle of their turns.
Loading settled each one (see `harness-session--settle'): its tool
calls got results saying they were interrupted, it was given a hint
saying so, and it is inactive.  Each item is a plist (:id ID :status
STATUS :pending PENDING :calls CALLS :text TEXT), oldest load first;
see `harness-session--interrupted'.  A reload finds nothing new: it
loads no session."
  (reverse harness-session--interrupted))

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

(defun harness-session--last-output (record)
  "Return the output of the request whose prompt usage RECORD's `:context' sizes.
That is RECORD's `:last-output', which a record of several requests (a
hosted loop's turn) gives, else its `:output', else 0."
  (let ((last (plist-get record :last-output))
        (output (plist-get record :output)))
    (cond ((numberp last) last)
          ((numberp output) output)
          (t 0))))

(harness-defmethod session/usage-add (id record)
  "Add usage RECORD to session ID.
RECORD keys: :input :output :cache-read :cache-write :cost :list-cost
:context :last-output :turns, :billing and :plan saying how the call
was paid, :model the model the request was sent to (the session's when
unsaid), :cache-at and :cache-ttl, when the request was made (the last
of a turn's, for a record that covers several) and how long its provider
said it keeps the prompt cache it used, and :cache-reset, which says the
conversation starts over (a compaction) and, when the conversation had a
cache, leaves `:cache-pending' until the first request that follows
stamps the new cache (see `harness-session--cache-stamp').  Counters
accumulate; `:context' replaces, and so do `:billing' and `:plan' when
RECORD has a billing.  With `:context', the size of the latest prompt,
comes the totals' `:last-output': the output of that request, which the
next one sends back (`harness-session--last-output'), so the
conversation holds about `:context' plus `:last-output' tokens.  A
request that read or wrote the cache stamps the totals' `:cache-at',
`:cache-model' and `:cache-ttl' (see `harness-session--cache-stamp').
Whatever changes that stamp -- such a request, one that used no cache,
`:cache-reset' -- also clears `:cache-dropped', the moment a redaction
dropped the cache (see `session/reset-provider'); a record of a turn
counted leaves both.
A missing `:cost' is priced from the model catalogue; a missing
`:list-cost', the call at API prices, is the cost, or priced when a
subscription paid.  The totals may also hold `:stream-output' and
`:stream-seconds', the output tokens of the model calls whose streaming
was timed and the seconds they streamed: those are added by
`session/usage-note', not by this method, which keeps them as it finds
them.  Return the totals."
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
      (setq u (plist-put u :context (plist-get record :context)))
      (setq u (plist-put u :last-output (harness-session--last-output record))))
    (when (harness-billing-of record)
      (setq u (plist-put u :billing (harness-billing-of record)))
      (setq u (plist-put u :plan (plist-get record :plan))))
    (setq u (harness-session--cache-stamp u record (harness-session-model s)))
    (setf (harness-session-usage s) u)
    (harness-emit 'session/usage id u record)
    (harness-session--touch s)
    ;; A subscriber of the event may have added to the totals meanwhile
    ;; (the streamed output, see `session/usage-note').
    (harness-session-usage s)))

(harness-defmethod session/cache-stamp (id record)
  "Note that session ID's conversation made a request while its turn runs.
RECORD is (:at TIME :ttl SECONDS :model MODEL :used BOOL): when the
request was made, how long its provider keeps the cache it wrote (when
it says), the model it went to (the session's when unsaid), and whether
its usage says it read or wrote the prompt cache.  A hosted loop (Claude
Code) reports what a turn used only when the turn is over, so until then
the cache would read as of the turn before, lapsed or about to, while
every request of the turn reads it: this moves the stamp on as each is
made (see `harness-session--cache-stamp', which the turn's usage then
sets for good).  Nothing but the stamp changes, no usage is recorded and
no request counted.

It stamps a cache that exists or a request that used one: a session
whose last request used none, or that has none yet, is not made to look
warm by a request that says nothing of the cache; a compaction that
remembered the cache it replaced (`:cache-pending') stamps the first
request that follows either way.  A request older than the stamp changes
nothing, so a late word never takes the cache back, and, as any new
stamp does, this clears the moment a redaction dropped the cache.  A
lifetime RECORD does not say leaves the one the stamp had.  Return the
session's `:cache' (see `harness-session--cache'), nil for none."
  (let* ((s (harness-session--get id))
         (u (harness-session-usage s))
         (at (plist-get record :at))
         (old (plist-get u :cache-at))
         (ttl (plist-get record :ttl)))
    (when (and (numberp at)
               (or (harness-json-true-p (plist-get record :used))
                   (numberp old)
                   (harness-json-true-p (plist-get u :cache-pending)))
               (or (not (numberp old)) (> at old)))
      (let* ((u (harness-plist-remove u :cache-pending :cache-dropped))
             (u (plist-put u :cache-at (float at)))
             (u (plist-put u :cache-model (or (plist-get record :model) (harness-session-model s))))
             (u (if (and (numberp ttl) (> ttl 0)) (plist-put u :cache-ttl ttl) u)))
        (setf (harness-session-usage s) u)
        (harness-session--touch s)))
    (harness-session--cache s)))

(harness-defmethod session/usage-note (id record)
  "Add what RECORD says session ID streamed to its usage totals.
RECORD's `:stream-output', the output tokens of model calls whose
streaming was timed, and `:stream-seconds', the seconds the model spent
streaming them, are added to the totals' keys of the same names; any
other key of RECORD is ignored.  Output over seconds is the average
output rate over the whole session, where `usage/rate' averages only
the newest calls.  The totals are a new plist, as `session/usage-add'
makes one, and the session is saved and announced (`session/changed').
Unlike `session/usage-add', this records no usage row and emits no
`session/usage' event: that event would record a row and be measured
for the output rate again.  A RECORD with neither number changes
nothing.  Return the totals, nil for a session that is gone."
  (when-let* ((s (gethash id harness-sessions)))
    (let ((u (copy-sequence (harness-session-usage s)))
          (added nil))
      (dolist (k '(:stream-output :stream-seconds))
        (when (numberp (plist-get record k))
          (setq u (plist-put u k (+ (or (plist-get u k) 0) (plist-get record k)))
                added t)))
      (when added
        (setf (harness-session-usage s) u)
        (harness-session--touch s))
      (harness-session-usage s))))

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
  "Return the content blocks of NODE for a provider message.
They are its `:blocks' when it has them, else one text block of its
`:content'."
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

(defun harness-session--result-images (node)
  "Return the image blocks of tool-result NODE, for its tool_result block.
The images a tool returned for the model to see are kept on the node as
`:images', (:path PATH :mime MIME) each; here each is the block
\(:type \"image\" :mime MIME :path PATH), which names the file and holds
none of its bytes: the agent reads it when the request goes out, and
only for a model that reads images (`harness-agent--prepare-messages').
A failed call has none: a provider takes only text in the result of one.
Nil when the node has no images."
  (unless (plist-get node :is-error)
    (let ((images (plist-get node :images)))
      (and (proper-list-p images)
           (delq nil (mapcar (lambda (image)
                               (let ((path (and (consp image) (plist-get image :path))))
                                 (and (stringp path) (not (string-empty-p path))
                                      (list :type "image" :mime (plist-get image :mime) :path path))))
                             images))))))

(harness-defmethod session/messages (id)
  "Return provider messages (:role :content BLOCKS) for the transcript of ID.
Adjacent assistant-side nodes merge into one assistant message; tool
results become user messages with tool_result blocks; the transcript
starts at the last compaction node when one exists, one the user did
not revert (`compaction/revert'): the conversation before a reverted
compaction is sent whole.  A steering message stands where the model
got it, after its `:delivered-after' node and the tool results right
after that, not where it was sent mid-step.
Every tool call is answered in the message after it, by a stand-in
result when the path has none (see `harness-session--pair-tools').
A tool_result block is (:type \"tool_result\" :tool_use_id ID :content
TEXT :is_error BOOL), its content always a string; the images the call
returned follow as `:images', image blocks that name their files (see
`harness-session--result-images'), on a block whose call returned any.
A message sent to a running turn is a node where the model got it, so
it stands after the tool results it was recorded between, as a user
message holds results before any words.
A call the harness recorded, and its result, are left out: the model
never made it (`harness-outside-node-p')."
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
                      (dolist (b (harness-session--text-blocks n)) (add 'user b)))
                ;; A steering message that comes between the results of a
                ;; batch of calls: a hosted loop got it with the first of
                ;; them, and a request holds all the results first.
                (between-results-p (n)
                  (and (eq (plist-get n :kind) 'user)
                       (harness-json-true-p (plist-get (plist-get n :meta) :steering))
                       (or ready
                           (and (eq cur-role 'user)
                                (cl-some (lambda (b) (equal (plist-get b :type) "tool_result")) cur))))))
      (dolist (n path)
        ;; Delivered steering goes in before the next node that is not a
        ;; tool result: tool results come first in the user message.
        (when (and ready (memq (plist-get n :kind) '(user assistant thinking tool-call plan compaction))
                   (not (harness-outside-node-p n))
                   (not (and (null (gethash (plist-get n :id) (car delivered))) (between-results-p n))))
          (mapc #'user ready)
          (setq ready nil))
        (pcase (and (not (gethash (plist-get n :id) (car delivered)))
                    ;; The model never made a call the harness recorded.
                    (not (harness-outside-node-p n))
                    (plist-get n :kind))
          ('user (if (between-results-p n)
                     (setq ready (append ready (list n)))
                   (user n)))
          ('compaction (flush)
                       (add 'user (list :type "text"
                                        :text (if (member (harness-node-compaction-kind n) '("transcript" "fresh" "truncate"))
                                                  ;; A note pointing at the file, or saying
                                                  ;; nothing was carried over, or that the
                                                  ;; oldest nodes were cut: no summary.
                                                  (plist-get n :content)
                                                (concat "Summary of the conversation so far:\n\n"
                                                        (plist-get n :content))))))
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
                        (add 'user (append (list :type "tool_result" :tool_use_id (plist-get n :call-id)
                                                 :content (or (plist-get n :output) "")
                                                 :is_error (and (plist-get n :is-error) t))
                                           (when-let* ((images (harness-session--result-images n)))
                                             (list :images images)))))
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

;;;; The transcript as a file

(defconst harness-session-transcript-directory ".harness/transcripts/"
  "Where in a session's directory `session/write-transcript' writes by default.")

(defconst harness-session--transcript-legend
  (concat "This is the conversation so far, oldest first, one entry per message:"
          " [user] the user (or who sent it), [assistant] the model's replies, [thinking] its reasoning,"
          " [tool NAME] a tool call and what it was about, [result] that call's result, [hint] notes of the"
          " harness, [compaction] a summary that stood in for what came before it.")
  "What a transcript file says of its entries, before them.")

(defun harness-session-directory (session)
  "Return the directory of SESSION, a session plist, as this Emacs opens it.
A session on another host has its directory there, through TRAMP."
  (let ((cwd (plist-get session :cwd))
        (host (plist-get session :host)))
    (file-name-as-directory (if (and host (not (file-remote-p cwd))) (concat host cwd) cwd))))

(harness-defmethod session/write-transcript (id &optional opts)
  "Write the transcript of session ID to a new Markdown file in its directory.
The file holds a heading, OPTS `:title' (\"Conversation\" by default),
the session's name and id, OPTS `:about' (a line saying why it was
written), its working directory, a legend of the entries, and then
`session/transcript-text'.  It goes in OPTS `:directory', a directory
relative to the session's, `harness-session-transcript-directory' by
default, named after the session and the time.  The session's own
directory is where its tools read without asking, and a provider's
prompt cache holds what the model reads of it, unlike the state
directory; a `.gitignore' of `*' written there keeps git out.  Signal
when the session's directory does not exist.  Return (:file FILE :lines
N): FILE as this Emacs opens it (through TRAMP for another host's), N
its number of lines.  The handoff to another provider and compaction
into a transcript both write theirs here."
  (let* ((session (harness-session-plist (harness-session--get id)))
         (root (harness-session-directory session))
         (dir (expand-file-name (or (plist-get opts :directory) harness-session-transcript-directory) root))
         (file (expand-file-name (format "%s-%s.md" (substring id 0 (min 8 (length id)))
                                         (format-time-string "%Y%m%dT%H%M%S"))
                                 dir))
         (text (concat
                (format "# %s\n\n" (or (plist-get opts :title) "Conversation"))
                (format "- Session: %s (%s)\n" (or (plist-get session :name) "unnamed") id)
                (if (plist-get opts :about) (format "- %s\n" (plist-get opts :about)) "")
                (format "- Working directory: %s\n\n" (plist-get session :cwd))
                harness-session--transcript-legend "\n\n"
                "---\n\n"
                (harness-call 'session/transcript-text id)
                "\n")))
    (unless (file-directory-p root)
      (signal 'harness-error (list (format "the session's directory %s does not exist" root))))
    (harness-ensure-directory dir)
    (let ((ignore (expand-file-name ".gitignore" dir)))
      (unless (file-exists-p ignore)
        (harness-write-file-atomically ignore "*\n")))
    (harness-write-file-atomically file text)
    (list :file file :lines (1+ (cl-count ?\n text)))))

;;;; Redaction
;;
;; A secret that got into a transcript has to come out of every copy the
;; session keeps.  `session/redact-text' takes it out of the node log,
;; the nodes in memory and the text of the record; `session/reset-provider'
;; drops the hosted provider's conversation, which may hold it too.  What
;; drives them, and cleans the stores that are not the session's (the
;; search index, the provider's own logs, buffers), is the redaction
;; engine.
;;
;; The secrets are plists that the caller holds in memory (see
;; harness-redaction.el).  Nothing here logs one, returns one or puts one
;; in an error: what comes back is node ids, kinds, field names, file
;; names and counts.

(defconst harness-session--redact-slots '(name queue steering pending todos plan ext move)
  "Slots of the record whose text `session/redact-text' cleans.
`name' is what a rename put there, `queue', `steering' and `pending' hold
the messages and requests that wait, `todos' and `plan' what the model
wrote, `ext' what other modules keep for the session -- a supervisor's
plans, with the prompts, results and errors of their steps -- and `move'
a directory a move waits to make.")

(defun harness-session--log-path (id)
  "Return the file name of the node log of session ID."
  (expand-file-name (harness-session--nodes-name id) harness-state-directory))

(defun harness-session--changed-keys (old new)
  "Return the keys whose values differ between the plists OLD and NEW.
They are a node, or a line of its log, before and after a redaction.
The `:_op' that marks an update line is no part of a node."
  (let (keys)
    (dolist (plist (list old new))
      (when (and (consp plist) (keywordp (car plist)))
        (cl-loop for (k _) on plist by #'cddr
                 when (and (keywordp k) (not (eq k :_op)) (not (memq k keys))
                           (not (equal (plist-get old k) (plist-get new k))))
                 do (push k keys))))
    (nreverse keys)))

(defun harness-session--line-kind (s node-id line)
  "Return the kind, a symbol, of the node a log LINE of session S is about.
NODE-ID is its id.  A node's own line says its kind, an update line does
not: the node in memory does, loaded for the purpose when it is not
\(`session/redact-text' lets go of it afterwards).  Nil when it is gone."
  (let ((kind (plist-get line :kind)))
    (cond ((and kind (symbolp kind)) kind)
          ((and (stringp kind) (not (string-empty-p kind))) (intern kind))
          ((stringp node-id)
           (harness-session--load-nodes s)
           (let ((known (plist-get (gethash node-id (harness-session-nodes s)) :kind)))
             (and known (symbolp known) known))))))

(defun harness-session--redact-log (s secrets dry-run note)
  "Take SECRETS out of the node log of session S, unless DRY-RUN; count them.
A log without a secret in it is not even read as lines: counting its
bytes comes first (`harness-redaction-file-count'), so looking through
hundreds of sessions is quick.  Otherwise the lines that hold one are
parsed and written again as the harness writes them, the rest kept byte
for byte, and the file is replaced atomically
\(`harness-redaction-file'), the read and the write with nothing between
that can yield.  NOTE is called with the id, the kind and the changed
keys of each node a secret was in; for an update line the keys are those
the update set."
  (let ((path (harness-session--log-path (harness-session-id s))))
    (if (not (and (file-regular-p path)
                  (> (harness-redaction-file-count path secrets) 0)))
        0
      (let ((result (harness-redaction-file
                     path secrets :style 'jsonl :json-style 'harness :dry-run dry-run
                     :on-line (lambda (old new _count)
                                (when (and (consp old) (keywordp (car old)))
                                  (let ((node-id (plist-get old :id)))
                                    (funcall note node-id
                                             (harness-session--line-kind s node-id old)
                                             (harness-session--changed-keys old new))))))))
        ;; A log that is not text cannot be cleaned: say so rather than
        ;; report a count of what is still there.
        (when (and (plist-get result :binary) (not dry-run))
          (signal 'harness-error
                  (list (format "The node log of session %s is not text; it was left as it was"
                                (harness-session-id s)))))
        (plist-get result :count)))))

(defun harness-session--redact-memory (s secrets dry-run note)
  "Take SECRETS out of the nodes of session S held in memory, unless DRY-RUN.
Return how many there were.  The nodes held are the log's as it was
loaded, and what has come since: a reply still streaming has its text in
memory only until the final update is written.  NOTE is called as for
`harness-session--redact-log'."
  (let ((table (harness-session-nodes s))
        (count 0) (changed nil))
    (maphash (lambda (node-id node)
               (pcase-let ((`(,new . ,n) (harness-redaction-value node secrets)))
                 (when (> n 0)
                   (cl-incf count n)
                   (push (cons node-id new) changed)
                   (funcall note node-id (plist-get node :kind)
                            (harness-session--changed-keys node new)))))
             table)
    (unless dry-run
      (dolist (c changed) (puthash (car c) (cdr c) table)))
    count))

(defun harness-session--redact-record (s secrets dry-run)
  "Take SECRETS out of the text slots of the record of session S, unless DRY-RUN.
Return (COUNT . SLOTS): how many there were, and the keywords of the
slots they were in (`harness-session--redact-slots').  A record that
changed is written at once, not after the delay of a save, and announced."
  (let ((count 0) (slots nil) (changes nil))
    (dolist (slot harness-session--redact-slots)
      (pcase-let ((`(,new . ,n) (harness-redaction-value
                                 (cl-struct-slot-value 'harness-session slot s) secrets)))
        (when (> n 0)
          (cl-incf count n)
          (push (intern (format ":%s" slot)) slots)
          (push (cons slot new) changes))))
    (when (and changes (not dry-run))
      (dolist (c changes)
        (setf (cl-struct-slot-value 'harness-session (car c) s) (cdr c)))
      (harness-session--save (harness-session-id s))
      (harness-session--announce s))
    (cons count (nreverse slots))))

(defun harness-session--spill-paths (node)
  "Return the files that hold the whole output of NODE, a cut tool result.
An output longer than `harness-tools-max-output-chars' is cut, the whole
of it saved in a file; the node's `:meta' names it (`:truncated'), and so
does the note that ends the cut output, which stays when a later update
has replaced the meta."
  (let ((paths nil)
        (meta-path (let ((truncated (plist-get (plist-get node :meta) :truncated)))
                     (and (consp truncated) (plist-get truncated :path))))
        (output (plist-get node :output)))
    (when (stringp meta-path) (push meta-path paths))
    (when (and (stringp output) (string-search "The full output was saved to " output))
      (let ((start 0))
        (while (string-match "The full output was saved to \\(.+?\\)\\. Read it in ranges" output start)
          (cl-pushnew (match-string 1 output) paths :test #'equal)
          (setq start (match-end 0)))))
    (nreverse paths)))

(defun harness-session--spill-and-checkpoints (s)
  "Return (SPILL-FILES . CHECKPOINTS) of the nodes of session S.
The files are those of `harness-session--spill-paths' for its tool
results; the checkpoints are the distinct provider checkpoints on its
nodes, in the order the nodes came.  The nodes are loaded when they are
not yet."
  (harness-session--load-nodes s)
  (let (spill checkpoints)
    (maphash (lambda (_ node)
               (when-let* ((checkpoint (plist-get node :checkpoint)))
                 (cl-pushnew checkpoint checkpoints :test #'equal))
               (when (eq (plist-get node :kind) 'tool-result)
                 (dolist (path (harness-session--spill-paths node))
                   (cl-pushnew path spill :test #'equal))))
             (harness-session-nodes s))
    (cons (nreverse spill) (nreverse checkpoints))))

(defun harness-session--by-name (symbols)
  "Return the SYMBOLS sorted by name."
  (sort (copy-sequence symbols)
        (lambda (a b) (string< (format "%s" a) (format "%s" b)))))

(harness-defmethod session/redact-text (id secrets &optional dry-run)
  "Take SECRETS out of the stored text of session ID, or count them (DRY-RUN).
SECRETS is a list of secrets, plists (:value :label :fingerprint :source)
that the caller holds in memory (see harness-redaction.el); each
occurrence is replaced by a placeholder naming the secret by its label
and fingerprint.  The method is meant for the harness process: a secret
given by a client over the wire is on the wire.  Three copies are
cleaned:

  - the node log, every field of every line, the lines of node updates
    included: the lines that hold no secret are kept byte for byte, the
    rest are written again as the harness writes them, and the file is
    replaced atomically.  The read and the write have nothing between
    them that can yield, so no append of this process falls in between
    and none is lost; a log that another process changes meanwhile is
    read again, and left as it was and signalled if it keeps changing.
    A log without a secret is not read beyond a count of its bytes;
  - the nodes of the session held in memory, when they are loaded:
    including text that is in memory only, such as a streamed reply that
    no update has written yet;
  - the text of the record -- `harness-session--redact-slots' -- which
    is written at once and announced (`session/changed') when it changed.

With DRY-RUN nothing changes and nothing is loaded for good: the result
is what a run would find.  The result is a plist, never a value of a
secret or a snippet of text:

  :id            ID
  :hit           non-nil when a secret was found anywhere, memory included
  :count         the secrets found in the stores of the session: the node
                 log's plus the record's (the nodes in memory overlap
                 the log, so they are reported apart)
  :log-count     how many in the node log
  :memory-count  how many in the nodes held in memory (0: not loaded)
  :record-count  how many in the record
  :nodes         the ids of the nodes a secret was in, in the order of the
                 log, those only in memory last
  :kinds         the kinds of those nodes (`tool-result', `user', ...)
  :fields        the keys of the nodes that changed (`:content', `:output',
                 `:input', `:blocks', `:meta', ...)
  :record-fields the slots of the record that changed (`:name', `:queue', ...)
  :file          the node log, when it held a secret
  :running       non-nil while the session runs a turn: it may write more
                 of the secret, and a reply streamed since is not final

and, when something was found, what else holds copies: `:spill-files',
the files in which the whole of the cut tool outputs are kept,
`:checkpoints', the provider checkpoints of the nodes (for Claude Code,
the CLI sessions and entries that hold the conversation), and
`:provider-state', the state of the provider conversation (see
`session/reset-provider')."
  (let* ((s (harness-session--get id))
         (was-loaded (harness-session-loaded s))
         (seen (make-hash-table :test 'equal))
         (nodes nil) (kinds nil) (fields nil)
         (note (lambda (node-id kind keys)
                 (when (and (stringp node-id) (not (gethash node-id seen)))
                   (puthash node-id t seen)
                   (push node-id nodes))
                 (when kind (cl-pushnew (if (stringp kind) (intern kind) kind) kinds))
                 (dolist (key keys) (cl-pushnew key fields))))
         (log-count 0) (memory-count 0) (record-count 0) (record-fields nil)
         (spill nil) (checkpoints nil))
    (unwind-protect
        (progn
          (setq log-count (harness-session--redact-log s secrets dry-run note))
          ;; The nodes a session had loaded before: loading them here, for
          ;; the kind of an update line, they would be the log's own.
          (when was-loaded
            (setq memory-count (harness-session--redact-memory s secrets dry-run note)))
          (pcase-let ((`(,n . ,slots) (harness-session--redact-record s secrets dry-run)))
            (setq record-count n record-fields slots))
          (when (> (+ log-count memory-count record-count) 0)
            (pcase-let ((`(,files . ,cps) (harness-session--spill-and-checkpoints s)))
              (setq spill files checkpoints cps))))
      ;; A session nobody had open is as it was: its nodes, loaded to
      ;; look, go again rather than pile up while hundreds are looked at.
      (unless was-loaded
        (clrhash (harness-session-nodes s))
        (setf (harness-session-loaded s) nil)))
    (let ((hit (> (+ log-count memory-count record-count) 0)))
      (append
       (list :id id :hit hit
             :count (+ log-count record-count)
             :log-count log-count :memory-count memory-count :record-count record-count
             :nodes (nreverse nodes)
             :kinds (harness-session--by-name kinds)
             :fields (harness-session--by-name fields)
             :record-fields record-fields
             :file (and (> log-count 0) (harness-session--log-path id))
             :running (and (harness-method-exists-p 'agent/running)
                           (harness-call 'agent/running id)
                           t))
       (and hit (list :spill-files spill :checkpoints checkpoints
                      :provider-state (harness-session-provider-state s)))))))

(defun harness-session--without-checkpoint (line)
  "Return (NEW-LINE . NODE-ID) for LINE, a log line, without its checkpoint.
Nil when LINE is no node or update that has one, or does not read back
as the same without it."
  (let ((object (condition-case nil (harness-json-parse line) (error nil))))
    (when (and (consp object) (keywordp (car object))
               (stringp (plist-get object :id))
               (plist-get object :checkpoint))
      (let* ((new (harness-plist-remove object :checkpoint))
             (text (condition-case nil (harness-json-encode-text new) (error nil))))
        (when (and text
                   (equal (condition-case nil (harness-json-parse text) (error nil)) new))
          (cons text (plist-get object :id)))))))

(defun harness-session--strip-log-checkpoints (path)
  "Rewrite the node log PATH without the provider checkpoints of its lines.
Return the ids of the nodes that had one.  Only a line that has one is
written again; the file is replaced atomically, and left as it was when
another process changed it meanwhile (`harness-redaction-rewrite-file')."
  (let ((ids nil))
    (when (file-regular-p path)
      (let ((signature (harness-redaction--signature (file-truename path))))
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8-unix))
            (insert-file-contents path))
          (goto-char (point-min))
          (let ((changed nil))
            (while (not (eobp))
              (let ((beg (pos-bol)) (end (pos-eol)))
                (when (search-forward "checkpoint" end t)
                  (when-let* ((stripped (harness-session--without-checkpoint
                                         (buffer-substring-no-properties beg end))))
                    (push (cdr stripped) ids)
                    (setq changed t)
                    (delete-region beg end)
                    (goto-char beg)
                    (insert (car stripped))))
                (goto-char beg)
                (forward-line 1)))
            (when changed
              (harness-redaction-rewrite-file path (buffer-string) signature))))))
    (nreverse ids)))

(harness-defmethod session/reset-provider (id)
  "Drop the provider conversation of session ID: its next turn starts a new one.
A hosted provider (Claude Code, Copilot) keeps the conversation itself,
and it may hold what the transcript no longer does -- a secret taken out
of it by `session/redact-text'.  So the provider state goes
\(`session/set-provider-state', which announces it: the Claude provider
closes its CLI process), and so does the node the conversation reached
\(`provider-node'), and the `:checkpoint' of every node, the CLI session
and entry a fork or a checkout at an earlier node could cut the
conversation at: from memory, and from the node log, which is replaced
atomically, only the lines that had one written again.

Then `session/provider-continuation' never leads back to the old
conversation (`harness-session--continuation').  At the head it says
\(:mode current) -- the session has no state and no node its conversation
reached -- and the provider, having no state to resume, starts a new
conversation that gets the transcript as text, the redacted one
\(`session/messages', `harness-provider-history-text').  A head off the
conversation, a fork taken at an earlier node or a head moved back, has
no checkpoint to cut at either, and says (:mode fresh): the same.  A
fork made later at an earlier node starts afresh too, rather than
resuming the old CLI session.

The provider's prompt cache of the conversation goes with it: the new
conversation opens with the transcript as text, which is not the prefix
the cache holds, so its first request is sent whole and uncached.  The
reset says so when it drops a cache, which the stamp alone cannot: when
the session reports a cache (a stamp and a context in its usage) and its
model is a hosted loop (`session/reset-drops-cache-p'), it marks the
usage `:cache-dropped' with the moment.  The session's `:cache' then reports
the cache gone from that moment (`:expires', and `:dropped'), however
long its provider would have kept it, so the cold-cache question
\(harness-cowboy.el) is asked before the next message sends everything
uncached.  The next request that stamps a cache, or a compaction,
clears the mark (`harness-session--cache-stamp').  A session whose
provider is sent the whole transcript with every request is not marked.

Signal a `harness-error' when the session runs a turn: its provider
holds the state it is writing, and the nodes it writes are not final.
Return (:checkpoints N), the number of nodes that had a checkpoint, and
`:cache-dropped' t when the reset marked a cache dropped.  The record
is written at once and announced."
  (let ((s (harness-session--get id))
        (stripped (make-hash-table :test 'equal))
        (drops-cache nil))
    (when (and (harness-method-exists-p 'agent/running) (harness-call 'agent/running id))
      (signal 'harness-error
              (list (format "Session %s is running a turn; stop it before dropping its provider conversation"
                            id))))
    ;; First, so that what the reset announces below already says the
    ;; cache is gone.  A new usage plist: whoever holds the old one
    ;; (`session/get', the last `session/usage') keeps what it saw.
    (when (harness-session--reset-drops-cache-p s)
      (setq drops-cache t)
      (setf (harness-session-usage s)
            (plist-put (copy-sequence (harness-session-usage s)) :cache-dropped (float-time))))
    (let ((had-state (harness-session-provider-state s)))
      (harness-call 'session/set-provider-state id nil)
      ;; A process may hold the old conversation even when the record
      ;; had none: tell the provider either way.
      (unless had-state
        (harness-emit 'session/provider-state-changed id nil)))
    (harness-call 'session/set-provider-node id nil)
    (when (harness-session-loaded s)
      (let ((table (harness-session-nodes s)) (marked nil))
        (maphash (lambda (node-id node)
                   (when (plist-get node :checkpoint) (push (cons node-id node) marked)))
                 table)
        (dolist (c marked)
          (puthash (car c) t stripped)
          (puthash (car c) (harness-plist-remove (cdr c) :checkpoint) table))))
    (dolist (node-id (harness-session--strip-log-checkpoints (harness-session--log-path id)))
      (puthash node-id t stripped))
    (harness-session--save id)
    (harness-session--announce s)
    (append (list :checkpoints (hash-table-count stripped))
            (and drops-cache (list :cache-dropped t)))))

(harness-defmethod session/reset-drops-cache-p (id)
  "Non-nil when `session/reset-provider' on session ID would drop its prompt cache.
That is when the reset would mark the usage `:cache-dropped': the
session reports a prompt cache (its usage has a stamp and a context),
its model is a hosted loop (its provider keeps the conversation and the
cache of it, and the new conversation the reset makes is sent the whole
transcript as text, which reads none of it), and no reset marked it
already since the last request that stamped a cache.  Nothing changes;
a redaction asks it to say whose cache a reset would cost.  Signal a
`harness-error' for a session that does not exist."
  (harness-session--reset-drops-cache-p (harness-session--get id)))

(harness-defmethod session/family-ids (id)
  "Return ID followed by the ids of the sessions descended from it.
A session is descended from ID when its parent chain reaches ID, of any
kind -- a fork, a sub-agent, a BTW -- so a fork of a fork is.  They copy
the transcript of the session they came from (a fork), or have lived in
its shadow, so what is taken out of one has to be taken out of them.
Only the sessions the harness holds a record of count.  The others come
oldest first."
  (harness-session--get id)
  (let (family)
    (maphash (lambda (sid s)
               (unless (equal sid id)
                 (let ((current s) (hops 0) (reached nil))
                   (while (and current (not reached) (< hops 1000))
                     (let ((parent (harness-session-parent-id current)))
                       (cond ((null parent) (setq current nil))
                             ((equal parent id) (setq reached t))
                             (t (setq current (gethash parent harness-sessions)
                                      hops (1+ hops))))))
                   (when reached (push s family)))))
             harness-sessions)
    (cons id (mapcar #'harness-session-id
                     (sort family (lambda (a b) (< (harness-session-created a)
                                                   (harness-session-created b))))))))

;;;; Init and reload

(defconst harness-session-interrupted-output
  "Interrupted: the harness stopped before this tool call finished."
  "Result recorded for a tool call that a stopped harness never finished.")

(defun harness-session--interrupted-text (pending)
  "Describe what a session stopped mid-turn was doing.
PENDING is the list of requests it was saved waiting on.  A question
that held a message back (its payload's `:waiting-message', see
`harness-session--requeue') says the message is queued again."
  (let* ((item (car pending))
         (kind (plist-get item :kind))
         (payload (plist-get item :payload)))
    (concat "Interrupted: the harness stopped "
            (pcase (if (stringp kind) (intern kind) kind)
              ((guard (plist-get payload :waiting-message))
               "before you said what goes first, the prompt cache being cold; the message that waited is back in the queue")
              ('question (format "while waiting for an answer to: %s"
                                 (harness-first-line (plist-get payload :question) 200)))
              ('permission (format "while waiting for permission: %s"
                                   (or (plist-get payload :title) (plist-get payload :tool) "a tool call")))
              (_ "during this turn")))))

(defun harness-session--requeue (id pending)
  "Queue again the messages PENDING held back from a turn of session ID.
A question asked before a turn starts (the cowboy module's, about a
cold prompt cache) keeps the message that waits for its answer in its
payload's `:waiting-message', (:text TEXT :from FROM): the turn that
would have appended it ended with the process, so the message goes back
in the queue, to be sent when the user is ready.  Only its text
survives.  The session lists that message with the others that wait
for its turn while the question does (`:steering', `agent/show-waiting'),
and settling queues those again (`harness-session--settle-steering'):
a message listed so is queued there, not twice."
  (let ((listed (harness-session-steering (harness-session--get id))))
    (dolist (item pending)
      (let ((message (plist-get (plist-get item :payload) :waiting-message)))
        (when (and message
                   (not (harness-string-blank-p (plist-get message :text)))
                   (not (cl-some (lambda (waiting)
                                   (and (equal (plist-get waiting :text) (plist-get message :text))
                                        (eq (harness-sender-kind (plist-get waiting :from))
                                            (harness-sender-kind (plist-get message :from)))))
                                 listed)))
          (harness-call 'session/queue id (plist-get message :text) nil (plist-get message :from)))))))

(defun harness-session--settle-steering (s)
  "Queue again the messages the turn of S never took, saved with it.
A message sent to a running turn waits for the turn's next step
\(`session/set-steering'), and the turn ends with the process: what
the record still lists is a message no turn will take.  It goes back in
the queue, to be sent when the user is ready, as one a question held
back does (`harness-session--requeue'); only its text survives.  A
message that is a node already -- the turn recorded it and the harness
stopped before the record was written -- is not sent twice."
  (when-let* ((items (harness-session-steering s)))
    (let ((id (harness-session-id s)))
      (setf (harness-session-steering s) nil)
      (harness-session--load-nodes s)
      (dolist (item items)
        (let ((text (plist-get item :text)))
          (unless (or (gethash (plist-get item :id) (harness-session-nodes s))
                      (harness-string-blank-p text))
            (harness-call 'session/queue id text nil (plist-get item :from)))))
      (harness-session--touch s))))

(defun harness-session--settle (s pending)
  "Close the turn of S that a stopped harness left unfinished.
S was saved running or blocked, with PENDING the requests it waited on.
Every tool call without a result gets one saying it was interrupted --
providers that pair calls with results reject a transcript with an
unanswered call -- and a hint says what the session was doing.  So does
a call the harness recorded in S's parent for S (`harness-outside-node-p'
with S as its `:child-id'), which nothing else would answer: the parent
need not have been running.  The requests themselves are gone: the turn
that would read their answers ended with the process.  A message one
held back goes back in the queue (`harness-session--requeue').
Return the tool calls of S answered so, each (:tool NAME :call-id ID)."
  (let* ((id (harness-session-id s))
         (parent (gethash (harness-session-parent-id s) harness-sessions))
         (interrupted (lambda (_call)
                        (list :output harness-session-interrupted-output :is-error t
                              :meta (list :interrupted t))))
         (calls (harness-session--unanswered (harness-session--path s))))
    (harness-session--answer id calls interrupted)
    ;; A call the harness recorded in the parent for S (the merge
    ;; queue's conflict resolver) waited on S, which stopped with it.
    (when parent
      (harness-session--answer
       (harness-session-id parent)
       (cl-remove-if-not (lambda (call) (and (harness-outside-node-p call)
                                             (equal (plist-get (plist-get call :meta) :child-id) id)))
                         (harness-session--unanswered (harness-session--path parent)))
       interrupted))
    (harness-session--requeue id pending)
    (harness-call 'session/hint id (harness-session--interrupted-text pending))
    ;; Saved inactive now, so the next start does not settle it again.
    (harness-session--save id)
    (mapcar (lambda (call) (list :tool (plist-get call :tool) :call-id (plist-get call :call-id)))
            calls)))

(defun harness-session--load-all ()
  "Load every persisted session record (nodes stay on disk until needed).
Sessions saved mid-turn are settled with `harness-session--settle', and
listed in `harness-session--interrupted' for whoever recovers them."
  (setq harness-session--interrupted nil)
  (let (interrupted loaded)
    (dolist (name (harness-call 'store/list "sessions" "\\.json\\'"))
      (let ((pl (harness-call 'store/load name)))
        (when (and pl (plist-get pl :id) (not (gethash (plist-get pl :id) harness-sessions)))
          (let ((s (harness-session--from-plist pl)))
            (puthash (plist-get pl :id) s harness-sessions)
            (push s loaded)
            (when (member (plist-get pl :status) '("running" "blocked"))
              (push (list s (plist-get pl :pending) (intern (plist-get pl :status))) interrupted))))))
    (dolist (entry interrupted)
      (pcase-let ((`(,s ,pending ,status) entry))
        (condition-case err
            (let ((calls (harness-session--settle s pending)))
              (push (list :id (harness-session-id s) :status status :pending pending :calls calls
                          :text (harness-session--interrupted-text pending))
                    harness-session--interrupted))
          (error (harness-log 'warn "session %s: could not settle its interrupted turn: %S"
                              (harness-session-id s) err)))))
    ;; Messages a turn had not taken when the harness stopped: only the
    ;; sessions loaded now, never one whose turn runs through a reload.
    (dolist (s loaded)
      (when (harness-session-steering s)
        (condition-case err
            (harness-session--settle-steering s)
          (error (harness-log 'warn "session %s: could not queue its waiting messages again: %S"
                              (harness-session-id s) err)))))
    ;; A move waiting for a turn that the stop ended.
    (maphash (lambda (id s)
               (when (harness-session-move s)
                 (condition-case err
                     (harness-session--apply-pending-move id)
                   (error (harness-log 'warn "session %s: could not make its move: %S" id err)))))
             harness-sessions)))

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

(defun harness-session--on-kill-emacs ()
  "Write every session record, as Emacs exits."
  (harness-session-flush))

(defun harness-session--shutdown ()
  "Stop the module: write every session record, and stop sweeping."
  (harness-session--tmp-disarm)
  (harness-session-flush))

(defun harness-session--on-models-updated (&rest _)
  "Announce the sessions whose context window changed with the model catalogue."
  (let (moved)
    (maphash (lambda (id s)
               (unless (eql (harness-session--window s) (gethash id harness-session--announced-windows))
                 (push s moved)))
             harness-sessions)
    (mapc #'harness-session--announce moved)))

(defun harness-session--init ()
  "Start the session module.
Load the saved sessions, drop the copies of the Budget setting they
hold, follow the updates of the model catalogue, hold every session to
the policy after a reload, make the move a session waits to make once
its turn ends, sweep the temporary directories of the sessions that are
over (`harness-session--tmp-sweep') soon and then every half hour, and
write every record when Emacs exits.  A reload loads no session: the
sessions are in memory already, and loading would settle the turns it
finds running and make the moves waiting for them, while these turns
run on in this process."
  (unless (harness-module-ready-p 'session)
    (harness-session--load-all))
  (harness-session--drop-budget-copies)
  (harness-on 'provider/models-updated #'harness-session--on-models-updated)
  (harness-on 'harness/reloaded #'harness-session--on-reloaded)
  ;; A session that asked to move during a turn moves when it ends.
  (harness-on 'agent/turn-ended #'harness-session--apply-pending-move)
  (harness-session--tmp-arm)
  (add-hook 'kill-emacs-hook #'harness-session--on-kill-emacs))

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
              (session/ext-changed . "(ID KEY VALUE) when a module's setting of the session changed (`session/set-ext'); VALUE nil once removed")
              (session/provider-state-changed . "(ID STATE) when the provider state is replaced by another")
              (session/redacted . "(ID RECORD) after a secret was redacted from the session's stores; RECORD is the redaction record: labels, fingerprints and counts, never the secret")
              (session/node-added . "(ID NODE)") (session/node-updated . "(ID NODE TRANSIENT)")
              (session/nodes-removed . "(ID NODE-IDS) after nodes were dropped from the transcript (`session/discard-nodes')")
              (session/head-moved . "(ID NODE-ID)")
              (session/moved . "(ID OLD-CWD NEW-CWD) after the session moved to another working directory")
              (session/queue-changed . "(ID ITEMS)") (session/pending-changed . "(ID ITEMS)")
              (session/steering-changed . "(ID ITEMS) when the messages the running turn has not taken yet changed (`session/set-steering')")
              (session/pending-resolved . "(ID ITEM ANSWER)")
              (session/pending-updated . "(ID PID CHANGES) after a pending request's payload was added to (`session/pending-update'); CHANGES are the keys merged in")
              (session/usage . "(ID TOTALS RECORD)") (session/todos . "(ID TODOS)") (session/plan . "(ID TEXT)")))
  (harness-declare-event (car ev) (cdr ev)))

(harness-define-module 'session
  :doc "Session records, conversation DAG, queue and pending requests."
  :requires '(store project)
  :init #'harness-session--init
  :shutdown #'harness-session--shutdown)

(provide 'harness-session)
;;; harness-session.el ends here
