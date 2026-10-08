;;; harness-seed.el --- Seed sessions: forks that share one prompt cache  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider's prompt cache has two limits.  It serves only the model
;; that wrote it, and only a request that starts with the very prefix
;; the writing request had: the tools, then the system prompt, then the
;; messages, word for word.  Forking a long session onto a cheaper model
;; therefore makes each fork pay to write the whole context into that
;; model's cache.  Worse, two forks never share a prefix, however alike
;; their transcripts are: a session's system prompt names its own
;; working and temporary directories (`harness-agent--system-prompt'),
;; so the requests of two sessions differ from the system prompt on.
;;
;; A seed fixes both.  `seed/fork' forks the source session once onto
;; the model; that fork is the seed.  It sends the seed one tiny
;; message, whose request writes the context into the model's cache, and
;; makes every further fork onto that model a fork of the seed that
;; sends the seed's system prompt word for word.  The first request of
;; such a fork then reads the shared context from the cache instead of
;; writing it again.  The supervisor starts its worker sub-agents on
;; cheaper models this way; any other feature that forks a session
;; several times can too.
;;
;; A seed is an ordinary session of kind `subagent', named "Shared
;; context for ...": it shows in the session list, can be read, and is
;; deleted with `session/delete' like any other.  Nothing here deletes
;; one.  The harness knows seeds by (SOURCE, NODE, MODEL): one seed
;; serves every fork of that node onto that model.  A caller that forks
;; the same turn of a session several times should therefore give the
;; same `:node' each time, since the head moves as the turn goes on.
;; The forks are children of the seed, not of the source: whatever is
;; keyed on `:parent-id' (the merge queue, say) sees the seed as their
;; parent.
;;
;; Warm seeds.  A fork reads the shared context from the cache only
;; while the cache lasts, so `seed/fork' looks at the seed's `:cache'
;; first (see "Session" in docs/architecture.md).  When it is gone, or
;; lapses within `harness-seed-warm-margin' seconds, the seed is sent a
;; short message (`harness-seed-warm-message') and the fork waits for
;; that turn, which writes the cache again.  A seed that was just primed
;; is warm by construction; one whose provider reports no use of the
;; cache reads as cold every time, and is sent the message every time.
;; Concurrent calls for the same seed share one piece of work: one
;; creation, one priming turn, one warm-up; and a turn of the seed that
;; is running already is waited for rather than followed by another.  A
;; turn that does not end well rejects the call, and the caller may fork
;; the source directly instead.
;;
;; Frozen system prompts.  An `agent/system-prompt' filter, run after
;; every other section was added, records the final prompt of each seed,
;; and gives it, as it stood when the fork was made, to every fork made
;; from the seed, in place of the one the fork would assemble.  That
;; prompt names the seed's working and temporary directories, not the
;; fork's, so `seed/fork' also returns a `:preamble': a text for the
;; fork's first message that names the fork's own.  The records live in
;; memory only: after a restart of the harness a fork that is resumed
;; assembles its own prompt, which is right, just uncached, and the next
;; call makes a new seed.
;;
;; Turns of a seed.  The messages the module sends are the harness's
;; (sender "seed"), and they must leave the seed as it is: the seed's
;; transcript is the prefix its forks share, and its model is the one
;; whose cache they read.  The `agent/before-turn' stages that would
;; change either -- the model fallback and a handoff (10), the question
;; about a cold cache (cowboy, 15) and compaction (20) -- are therefore
;; left out for those messages: a warm-up is by nature a message to a
;; lapsed cache, which the cowboy would ask about, or answer with a
;; summary of the seed.  The stages after them, the budgets, still
;; apply: a priming turn writes a whole context to the cache.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

;;;; Messages and margins

(defconst harness-seed-prime-message
  "This conversation is kept as shared context: the harness starts sub-agents from it, each with its own task in its own message. Reply with just: ok"
  "Message that makes a new seed write its context into the model's cache.
It is the seed's first message of its own.  Every fork of the seed
inherits it with the model's answer, and reads its task in the next
message.")

(defconst harness-seed-warm-message
  "Still here? Reply with just: ok"
  "Message that writes a seed's context into the model's cache again.
It is sent to a seed whose cache lapsed, or is about to, before a fork
is made from it.")

(defconst harness-seed-warm-margin 30
  "Seconds before its cache lapses from which a seed counts as cold.
A fork made from a seed that lapses sooner might send its first request
after the cache is gone, so the seed is warmed first.")

(defconst harness-seed--source "seed"
  "Source of the messages the module sends, in their sender.
See `harness-sender-system'.")

(defconst harness-seed--first-kept-stage 21
  "Priority of the first `agent/before-turn' stage a seed's own message meets.
The stages before it would change the seed (see
`harness-seed--before-turn'); the budget check, from 30 on, is kept.")

;;;; State
;;
;; Kept by session id in tables that outlive a reload, and never saved.

(defvar harness-seed--seeds (make-hash-table :test 'equal)
  "Seed session id -> (:id ID :source ID :node NODE :model MODEL :created TIME).")

(defvar harness-seed--index (make-hash-table :test 'equal)
  "(SOURCE-ID NODE MODEL) -> id of the seed made for it.")

(defvar harness-seed--pending (make-hash-table :test 'equal)
  "(SOURCE-ID NODE MODEL) -> promise of its seed's id, while the seed is made or warmed.
Concurrent calls for the same key wait on it instead of starting
the same work again.")

(defvar harness-seed--prompts (make-hash-table :test 'equal)
  "Seed session id -> (:prompt PROMPT :cwd DIR :tmp DIR), its last system prompt.
The directories are the working and temporary ones PROMPT names.")

(defvar harness-seed--frozen (make-hash-table :test 'equal)
  "Fork session id -> (:seed SEED-ID :prompt PROMPT), the prompt the fork sends.
PROMPT is the seed's, as recorded when the fork was made: a fork keeps
its prompt for its whole life, since a prompt that changed would make
the fork's own cache miss.")

(defvar harness-seed--waiters (make-hash-table :test 'equal)
  "Seed session id -> promises waiting for the turn it runs to end.")

;;;; Frozen system prompts

(defun harness-seed--tmp-dir (session-id)
  "Return the temporary directory of SESSION-ID, or nil when it has none."
  (condition-case nil
      (harness-call 'session/tmp-dir session-id)
    (error nil)))

(defun harness-seed--system-prompt (prompt session)
  "Return PROMPT, the system prompt SESSION sends, as a seed shares it.
The `agent/system-prompt' filter, last of the chain (priority 1000), so
that every other section is in PROMPT.  For a seed, record PROMPT and
the directories it names, and return it as it is.  For a fork made
from a seed, return the seed's prompt instead.  Any other session gets
PROMPT back."
  (let ((id (plist-get session :id)))
    (cond
     ((gethash id harness-seed--seeds)
      (puthash id (list :prompt prompt :cwd (plist-get session :cwd) :tmp (harness-seed--tmp-dir id))
               harness-seed--prompts)
      prompt)
     ((gethash id harness-seed--frozen)
      (or (plist-get (gethash id harness-seed--frozen) :prompt) prompt))
     (t prompt))))

(defun harness-seed--freeze (fork-id seed-id)
  "Make fork FORK-ID of seed SEED-ID send the seed's system prompt.
Return the seed's record of that prompt (see `harness-seed--prompts'),
or nil when it has none: the fork then sends a prompt of its own."
  (when-let* ((record (gethash seed-id harness-seed--prompts)))
    (puthash fork-id (list :seed seed-id :prompt (plist-get record :prompt)) harness-seed--frozen)
    record))

(defun harness-seed--preamble (fork recorded)
  "Return the text telling FORK where it works, or nil when that is no news.
FORK is the session plist.  RECORDED is the seed's record of the system
prompt FORK sends (`harness-seed--prompts'), which names the directories
of the seed.  The text names FORK's working and temporary directories,
when either differs from what the prompt names, and is for the caller
to put before FORK's first message, since the prompt cannot say it."
  (let ((cwd (plist-get fork :cwd))
        (tmp (harness-seed--tmp-dir (plist-get fork :id))))
    (when (or (and cwd (not (equal cwd (plist-get recorded :cwd))))
              (and tmp (not (equal tmp (plist-get recorded :tmp)))))
      (format "Your own environment, which differs from the one your system prompt names (you share that prompt with other sessions): %s."
              (string-join
               (delq nil (list (and cwd (format "working directory %s" cwd))
                               (and tmp (format "temporary directory %s (yours alone: put scratch files there)" tmp))))
               "; ")))))

;;;; Turns of a seed

(defun harness-seed--own-message-p (session message)
  "Non-nil when MESSAGE is one the module sends to SESSION, a seed.
MESSAGE is the `:message' of the `agent/before-turn' value."
  (and (gethash (plist-get session :id) harness-seed--seeds)
       (let ((from (plist-get message :from)))
         (and (eq (harness-sender-kind from) 'system)
              (equal (plist-get from :source) harness-seed--source)))))

(defun harness-seed--before-turn (value next session)
  "Keep a seed's own message from changing the seed (an `agent/before-turn' stage).
VALUE, NEXT and SESSION are the filter's.  The model fallback, a
handoff, the question about a cold cache and compaction would each
change the seed, or ask about it, before the message: the seed must
stay on its model, with the transcript its forks share, and the cache
it is warmed for is cold by the nature of the message.  So the message
goes through the stages from `harness-seed--first-kept-stage' on only,
the budget check among them, and the chain ends there.  Messages from
anybody else, and sessions that are no seed, are passed on as they
are.  Always returns nil: it settles the chain by calling NEXT."
  (if (and (plist-get value :proceed)
           (harness-seed--own-message-p session (plist-get value :message)))
      (harness-then
       (harness-run-filter-async-between 'agent/before-turn harness-seed--first-kept-stage
                                         most-positive-fixnum value session)
       (lambda (gate)
         (funcall next (plist-put (copy-sequence gate) :final t))
         nil)
       (lambda (err)
         (harness-log 'warn "seed: the stages before the turn of %s failed: %s"
                      (plist-get session :id) (harness-error-message err))
         (funcall next value)
         nil))
    (funcall next value))
  nil)

(defun harness-seed--check-turn (result)
  "Return RESULT, how a seed's turn ended, or a rejection if it ended badly."
  (if (eq (plist-get result :stop-reason) 'end-turn)
      result
    (harness-rejected
     (list 'harness-error
           (format "the seed's turn stopped before the model was done: %s%s"
                   (or (plist-get result :stop-reason) "no reason given")
                   (if (plist-get result :error) (format " (%s)" (plist-get result :error)) ""))))))

(defun harness-seed--send (seed-id text)
  "Send TEXT to seed SEED-ID as the harness; return a promise of its turn.
The promise is rejected when the turn does not end well."
  (harness-then (harness-call-async 'agent/prompt seed-id text
                                    (list :from (harness-sender-system harness-seed--source)))
                #'harness-seed--check-turn))

(defun harness-seed--await-turn (seed-id)
  "Return a promise of the turn seed SEED-ID runs now, settled when it ends.
It is rejected when the turn does not end well."
  (let ((promise (harness-make-promise)))
    (push promise (gethash seed-id harness-seed--waiters))
    (harness-then promise #'harness-seed--check-turn)))

(defun harness-seed--on-turn-ended (session-id reason)
  "Settle the promises waiting for the turn of SESSION-ID, which ended for REASON."
  (when-let* ((waiting (gethash session-id harness-seed--waiters)))
    (remhash session-id harness-seed--waiters)
    (dolist (promise (nreverse waiting))
      (harness-resolve promise (list :stop-reason reason)))))

;;;; Finding, making and warming a seed

(defun harness-seed--unseed (session-id)
  "Forget that SESSION-ID is a seed, and the system prompt it recorded.
The forks frozen to its prompt keep their copies of it."
  (when-let* ((seed (gethash session-id harness-seed--seeds)))
    (let ((key (list (plist-get seed :source) (plist-get seed :node) (plist-get seed :model))))
      (when (equal (gethash key harness-seed--index) session-id)
        (remhash key harness-seed--index))))
  (remhash session-id harness-seed--seeds)
  (remhash session-id harness-seed--prompts))

(defun harness-seed--on-deleted (session-id &rest _)
  "Forget session SESSION-ID, which is gone (on `session/deleted').
That is everything about it: its place among the seeds, its recorded
prompt, the prompt it was frozen to, and the callers waiting for a turn
of it."
  (harness-seed--unseed session-id)
  (remhash session-id harness-seed--frozen)
  (when-let* ((waiting (gethash session-id harness-seed--waiters)))
    (remhash session-id harness-seed--waiters)
    (dolist (promise waiting)
      (harness-reject promise (list 'harness-error "the seed was deleted")))))

(defun harness-seed--lookup (key model)
  "Return the id of the seed for KEY, a session on MODEL, or nil if it has none.
A seed that is gone without the module having heard of it, or that was
switched to another model, whose cache is not MODEL's, is forgotten."
  (when-let* ((id (gethash key harness-seed--index)))
    (if (and (harness-call 'session/exists-p id)
             (equal (plist-get (harness-call 'session/get id) :model) model))
        id
      (harness-seed--unseed id)
      nil)))

(defun harness-seed--cold-p (seed-id)
  "Non-nil when the prompt cache of seed SEED-ID is gone, or lapses very soon."
  (let ((expires (plist-get (plist-get (harness-call 'session/get seed-id) :cache) :expires)))
    (or (not (numberp expires))
        (< expires (+ (float-time) harness-seed-warm-margin)))))

(defun harness-seed--warm (seed-id)
  "Return a promise of SEED-ID once its prompt cache is warm.
A cold seed is sent `harness-seed-warm-message'.  A turn the seed runs
already is waited for instead, whoever began it, and no other follows."
  (cond
   ((harness-call 'agent/running seed-id)
    (harness-then (harness-seed--await-turn seed-id) (lambda (_) seed-id)))
   ((harness-seed--cold-p seed-id)
    (harness-log 'info "seed: the cache of %s is cold; warming it" seed-id)
    (harness-then (harness-seed--send seed-id harness-seed-warm-message) (lambda (_) seed-id)))
   (t (harness-resolved seed-id))))

(defun harness-seed--default-name (source model)
  "Return the name of a seed of SOURCE, a session plist, on MODEL."
  (format "Shared context for %s (%s)"
          (or (plist-get source :name) (substring (plist-get source :id) 0 (min 8 (length (plist-get source :id)))))
          model))

(defun harness-seed--make (key source-id node model plist)
  "Fork SOURCE-ID at NODE onto MODEL as the seed for KEY, and prime it.
PLIST is `seed/fork''s.  Return a promise of the seed's id, resolved
once the priming turn ended.  The seed is known from the moment it
exists, so a priming turn that fails leaves it to be warmed by the
next call.  Rejected when the fork cannot be made."
  (let* ((source (harness-call 'session/get source-id))
         (name (plist-get plist :seed-name)))
    (harness-then
     (harness-call-async 'session/fork source-id
                         :node node :model model :kind 'subagent
                         :name (if (harness-string-blank-p name) (harness-seed--default-name source model) name)
                         :call-id (plist-get plist :call-id))
     (lambda (seed)
       (let ((id (plist-get seed :id)))
         (puthash id (list :id id :source source-id :node node :model model :created (float-time))
                  harness-seed--seeds)
         (puthash key id harness-seed--index)
         (harness-log 'info "seed: %s made for %s on %s; priming it" id source-id model)
         (harness-then (harness-seed--send id harness-seed-prime-message) (lambda (_) id)))))))

(defun harness-seed--ready (key source-id node model plist)
  "Return a promise of the id of the seed for KEY, which exists and is warm.
SOURCE-ID, NODE, MODEL and PLIST are those of `seed/fork'."
  (if-let* ((id (harness-seed--lookup key model)))
      (harness-seed--warm id)
    (harness-seed--make key source-id node model plist)))

(defun harness-seed--check-model (seed-id model)
  "Return SEED-ID, or a rejection when the seed no longer runs on MODEL.
A cache serves the model that wrote it.  The fallback module moves a
session whose request failed to another model and runs it again there,
which can end well: the cache the turn wrote is then that model's, not
the one the forks go onto."
  (let ((now (plist-get (harness-call 'session/get seed-id) :model)))
    (if (equal now model)
        seed-id
      (harness-rejected
       (list 'harness-error
             (format "the seed was moved to %s while it ran, so what it cached is not %s's"
                     now model))))))

(defun harness-seed--ensure (key source-id node model plist)
  "Return a promise of the id of the seed for KEY, which exists and is warm.
SOURCE-ID, NODE, MODEL and PLIST are those of `seed/fork'.  Calls for
the same KEY at the same time share the promise, and so the work: it
is registered before the work starts, and dropped when it is over,
however it ends."
  (or (gethash key harness-seed--pending)
      (let ((promise (harness-make-promise)))
        (puthash key promise harness-seed--pending)
        (condition-case err
            (harness-resolve promise
                             (harness-then (harness-seed--ready key source-id node model plist)
                                           (lambda (id) (harness-seed--check-model id model))))
          (error (harness-reject promise err)))
        (let ((drop (lambda ()
                      (when (eq (gethash key harness-seed--pending) promise)
                        (remhash key harness-seed--pending)))))
          (harness-then promise
                        (lambda (id) (funcall drop) id)
                        (lambda (err) (funcall drop) (harness-rejected err))))
        promise)))

(defun harness-seed--fork-from (seed-id model plist)
  "Fork seed SEED-ID onto MODEL with PLIST's keys, frozen to the seed's prompt.
PLIST is `seed/fork''s.  Return a promise of the fork's plist with
`:seed' and `:preamble'."
  (harness-then
   (apply #'harness-call-async 'session/fork seed-id
          :model model :kind (or (plist-get plist :kind) 'subagent)
          (harness-plist-remove plist :node :call-id :seed-name :kind :model))
   (lambda (fork)
     (let ((recorded (harness-seed--freeze (plist-get fork :id) seed-id)))
       (append fork (list :seed seed-id
                          :preamble (and recorded (harness-seed--preamble fork recorded))))))))

;;;; Methods

(harness-defmethod seed/fork (source-id model &rest plist)
  "Fork SOURCE-ID onto MODEL through a seed; return a promise of the fork.
The promise resolves with the new fork's session plist plus `:seed',
the id of the seed it was forked from, and `:preamble', a string or nil.

Why a seed.  A provider's prompt cache serves only the model that
wrote it, and only a request that starts with the prefix the writing
request had: the tools, then the system prompt, then the messages,
word for word.  Forking a long session onto a cheaper model makes each
fork write the whole context into that model's cache.  Two forks never
share a prefix either: a session's system prompt names its own working
and temporary directories, so their requests differ from the system
prompt on.  So the context is written once, by the seed, which is the
first fork of SOURCE-ID onto MODEL, sent one tiny message.  Every fork
onto MODEL after that is a fork of the seed that sends the seed's
system prompt word for word, and its first request reads the shared
context from the cache instead of writing it again.

PLIST keys:
 `:node'       the node of SOURCE-ID to share; default its head.  The
               seed, and so the cache, belongs to (SOURCE-ID, NODE,
               MODEL): callers that fork one turn several times should
               give the same node each time, since the head moves.
 `:call-id'    the tool call of SOURCE-ID that starts the forks; it is
               answered in the seed as the call that started it (see
               `session/fork').
 `:seed-name'  the name of the seed, when it is made; default \"Shared
               context for <source name> (<model>)\".
 any `session/fork' key of the new fork: `:name', `:cwd', `:worktree',
 `:kind' (default `subagent'), `:id', and so on.  MODEL is the fork's
 model.  A nil MODEL means SOURCE-ID's own.

The steps:
1. Find the seed for (SOURCE-ID, NODE, MODEL), or make it: fork
   SOURCE-ID at NODE onto MODEL as a `subagent' session and send it
   `harness-seed-prime-message', as the harness (sender \"seed\"),
   waiting for that turn.  The seed stays known even if the turn fails.
2. Warm the seed.  Its cache is cold when `session/get' gives it no
   `:cache', or one that lapses within `harness-seed-warm-margin'
   seconds.  It is then sent `harness-seed-warm-message' and the call
   waits for that turn.  A turn the seed runs already is waited for
   instead, and no other follows.
3. Fork the seed at its head with PLIST's keys, onto MODEL, and make
   the fork send the seed's system prompt (see below).
Calls for the same (SOURCE-ID, NODE, MODEL) at the same time share the
work of steps 1 and 2: one seed, one priming turn, one warm-up.

If a turn of the seed does not end well, or a fork cannot be made, the
promise is rejected and nothing is frozen; the caller may fork
SOURCE-ID directly instead.  Errors of the call itself reject too: the
method always returns a promise.

The system prompt.  Each seed's final system prompt, the value of the
`agent/system-prompt' chain after every other section was added, is
recorded every time the seed assembles it.  A fork made here sends
that prompt, as it was when the fork was made, for as long as the
harness runs, whatever its own would say.  It names the seed's working
directory and temporary directory, so `:preamble' says what the fork's
own are: a text for the caller to put before the fork's first message,
nil when nothing differs (or when the seed has no recorded prompt, and
the fork sends one of its own).  The records are kept in memory only.
After a restart of the harness a resumed fork assembles its own prompt,
which is right, just uncached, and the next call makes a new seed.

The messages to the seed are not subject to the stages of the
`agent/before-turn' chain that would change the seed (fallback,
handoff, the cold-cache question, compaction); its budgets still apply."
  (condition-case err
      (let* ((source (harness-call 'session/get source-id))
             (model (or model (plist-get source :model)))
             (node (or (plist-get plist :node) (plist-get source :head)))
             (key (list source-id node model)))
        (harness-then (harness-seed--ensure key source-id node model plist)
                      (lambda (seed-id) (harness-seed--fork-from seed-id model plist))))
    (error (harness-rejected err))))

(harness-defmethod seed/list (&optional source-id)
  "Return the seeds that exist, newest first, as plists.
Each is (:id SEED :source SOURCE :node NODE :model MODEL :cache CACHE):
the seed's session id, the session it was forked from, the node of that
session it shares, the model it runs on, and its `:cache' as
`session/get' gives it (nil, or when the prompt cache lapses; see
`seed/fork' for why a seed is warmed).  With SOURCE-ID only the seeds of
that session.  For diagnostics and the UI.  The harness keeps seeds in
memory: one made before a restart is no longer listed, though its
session remains."
  (let (seeds)
    (maphash (lambda (id seed)
               (when (and (or (null source-id) (equal source-id (plist-get seed :source)))
                          (harness-call 'session/exists-p id))
                 (push seed seeds)))
             harness-seed--seeds)
    (mapcar (lambda (seed)
              (list :id (plist-get seed :id) :source (plist-get seed :source)
                    :node (plist-get seed :node) :model (plist-get seed :model)
                    :cache (plist-get (harness-call 'session/get (plist-get seed :id)) :cache)))
            (sort seeds (lambda (a b) (> (plist-get a :created) (plist-get b :created)))))))

;;;; Module

(defun harness-seed--init ()
  "Hook the module into the bus (idempotent).
The system prompt filter runs last, after every section was added; the
before-turn stage runs first, before the ones it takes the seed's own
messages out of."
  (harness-add-filter 'agent/system-prompt #'harness-seed--system-prompt 1000)
  (harness-add-filter 'agent/before-turn #'harness-seed--before-turn 5)
  (harness-on 'session/deleted #'harness-seed--on-deleted)
  (harness-on 'agent/turn-ended #'harness-seed--on-turn-ended))

(defun harness-seed--shutdown ()
  "Take the module off the bus.  The records are kept."
  (harness-remove-filter 'agent/system-prompt #'harness-seed--system-prompt)
  (harness-remove-filter 'agent/before-turn #'harness-seed--before-turn)
  (harness-off (cons 'session/deleted #'harness-seed--on-deleted))
  (harness-off (cons 'agent/turn-ended #'harness-seed--on-turn-ended)))

;; A reload does not initialise a running module again: hook in what
;; this version brings now.
(when (harness-module-ready-p 'seed)
  (harness-seed--init))

(harness-define-module 'seed
  :doc "Seed sessions: forks onto a model that share one warm prompt cache."
  :requires '(session agent)
  :init #'harness-seed--init
  :shutdown #'harness-seed--shutdown)

(provide 'harness-seed)
;;; harness-seed.el ends here
