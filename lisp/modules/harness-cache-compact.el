;;; harness-cache-compact.el --- Compacting a conversation just before its prompt cache lapses  -*- lexical-binding: t; -*-

;;; Commentary:

;; A conversation whose prompt cache is about to lapse is going to be
;; sent again, whole and uncached, by whoever writes to it next -- or,
;; when the cold-cache question is on, compacted first (harness-cowboy.el),
;; with the user waiting for it.  Compacting it a few seconds before the
;; cache lapses is the same job done at the better time: what the
;; summarising model reads of the conversation it reads from the cache,
;; a tenth of the uncached price (a `brief' summary of the narrative and
;; the kinds that ask no model cost the same at either moment), and the
;; next message finds a small conversation and no wait.
;;
;; This module does it on `cache/pre-expire' (harness-cache.el), when
;; the cache is not claimed -- the user is no longer around, so there is no
;; reason to keep it warm (harness-cache-warm.el, the handler before this
;; one, claims it while there is) -- and all of these hold:
;;
;; - `harness-cache-precompact' is on;
;; - the session waits for the user, with no turn, no question, no
;;   compaction and no work of its own outside its turn under way, and is
;;   not a seed, whose context other sessions share;
;; - the conversation holds at least `harness-cache-precompact-min-context'
;;   tokens (and `harness-cowboy-min-context', when that is more): the
;;   compaction of a small one saves little and costs the detail;
;; - the option the user saved for a cold cache -- the choice an
;;   \"always\" answer to the cold-cache question made the default, else
;;   `harness-cowboy-default' (`cowboy/default') -- is to compact.  \"Carry
;;   on\" and \"ignore\" are the user's word that the conversation goes on
;;   as it is, and so nothing is done here;
;; - nobody would be asked: the compaction is what the cold-cache gate
;;   would have done, unasked, to a message that comes later, only
;;   earlier and cheaper, so a session whose user is asked what goes
;;   first when a message meets the cold cache -- asking is on and the
;;   session waits for them -- is left as it is, its question not taken
;;   from them.  Answering \"always\" turns asking off; a session that
;;   never waits for the user (a non-interactive task) is never asked.
;;
;; The compaction is the one the cold-cache gate would have made
;; (`compaction/compact' of that kind); its node says it was made before
;; the cache lapsed (`:meta' `:precompact').  A note follows it in the
;; transcript.  The note is a lasting decision's (see harness-decisions.el):
;; a decision of the kind `precompact', which is done while the
;; feature is on, with [Turn off] to undo it and [Turn on] to redo it, in
;; any session -- the way \"Always a brief summary\" can be undone and redone.
;; The note also names the decision that made the saved option the default,
;; if there is one (`:decided-by'), with its own undo and redo: so the
;; choice of what goes first can be changed from the note, too.
;;
;; A message that comes to the session while the compaction runs waits
;; for it: it is sent the compacted conversation, as one that met the
;; cold-cache gate would be.  Any compaction of a session holds a turn
;; that starts meanwhile (`harness-compaction--wait-gate'); this module's
;; gate covers what that one cannot see: the moment between the decision
;; and the compaction's start, and the note written after it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-cache)

(defvar harness-cowboy-min-context)

(declare-function harness-compaction-busy-p "harness-compaction" (session-id))

(defcustom harness-cache-precompact t
  "Non-nil to compact a conversation just before its prompt cache lapses.
When nobody has been around for a while, so that nothing keeps the
cache warm (`harness-cache-warm'), the conversation is compacted a few
seconds before the cache lapses, while the context is still hot in it:
what the summarising model reads, it reads from the cache at a tenth of
the price, and the next message finds a small conversation instead of
sending the whole one again, uncached.  It is compacted as the user
saved for a cold cache -- the choice an \"always\" answer to the
cold-cache question made the default (`harness-cowboy-default'), a brief
summary unless they chose otherwise -- and a user who chose to carry on
or to ignore the cold cache has nothing compacted.  It is what would be
done, unasked, to the message that comes later, done sooner: a session
whose user would be asked what goes first (`harness-cowboy-ask' on, and
a session that waits for them) is left alone.  Only conversations of
`harness-cache-precompact-min-context' tokens or more.  The note that
tells of it offers [Turn off] and then [Turn on]."
  :type 'boolean :safe #'booleanp :group 'harness)

(defcustom harness-cache-precompact-min-context 30000
  "Smallest context, in tokens, that is compacted just before its cache lapses.
A conversation under it is left as it is: sending it again, uncached,
costs little, and a summary of it loses detail for the little it saves.
The context of the last request counts; `harness-cowboy-min-context' is
a floor to it, the size under which a cold cache is no concern at all."
  :type 'natnum :safe #'natnump :group 'harness)

(defconst harness-cache-compact--decision-text
  "Compacting a conversation just before its prompt cache lapses, while it is still cached"
  "What the lasting decision of the kind `precompact' says it does.")

(defconst harness-cache-compact--kinds '(brief summary transcript fresh)
  "The compaction kinds a saved option can make.
They are the choices of the cold-cache question that compact.")

(defvar harness-cache-compact--running (make-hash-table :test 'equal)
  "Session id -> promise of the compaction made before its cache lapsed.")

;;;; The saved option

(defun harness-cache-compact--option (sid)
  "Return the compaction the user saved for a cold cache, for session SID.
The answer is (:kind KIND :decision ID :asks BOOL), nil without the
cowboy module, which keeps it (`cowboy/default').  KIND is the compaction
kind to make, nil when the saved option is not to compact; ID the id of
the lasting decision that set it, if an \"always\" answer did; ASKS says a
message that meets SID's cold cache would be asked about."
  (when (harness-method-exists-p 'cowboy/default)
    (let* ((option (harness-call 'cowboy/default sid))
           (choice (plist-get option :choice)))
      (list :kind (and (memq choice harness-cache-compact--kinds) choice)
            :decision (plist-get option :decision)
            :asks (harness-json-true-p (plist-get option :asks))))))

(defun harness-cache-compact--min-context ()
  "Return the fewest tokens of context that are compacted before the lapse."
  (max (or harness-cache-precompact-min-context 0)
       (if (and (boundp 'harness-cowboy-min-context) (numberp harness-cowboy-min-context))
           harness-cowboy-min-context
         0)))

;;;; When

(defun harness-cache-compact--seed-p (session)
  "Non-nil when SESSION is a seed: its context is shared with the forks made of it."
  (harness-json-true-p (plist-get (plist-get session :ext) :seed)))

(defun harness-cache-compact--skip-reason (sid info)
  "Return why session SID is not compacted before its cache lapses, or nil.
INFO is that of `cache/pre-expire'."
  (let* ((session (harness-cache--session sid))
         (status (plist-get session :status))
         (context (plist-get (plist-get session :usage) :context))
         (option (and session (harness-cache-compact--option sid))))
    (cond ((null session) "the session is gone")
          ((not harness-cache-precompact) "compacting before the cache lapses is off")
          ((harness-cache-around-p sid session) "the user is around")
          ((harness-call 'cache/claimed sid)
           (format "the cache is claimed by %s" (harness-call 'cache/claimed sid)))
          ((plist-get info :running) "a turn is running")
          ((not (eq (if (stringp status) (intern status) status) 'idle)) "the session is not idle")
          ((eq (plist-get session :kind) 'internal) "the session records one call")
          ((harness-cache-compact--seed-p session) "the session is a seed")
          ((gethash sid harness-cache-compact--running) "a compaction is under way")
          ((and (fboundp 'harness-compaction-busy-p) (harness-compaction-busy-p sid))
           "a compaction is under way")
          ((and (harness-method-exists-p 'agent/outstanding) (harness-call 'agent/outstanding sid))
           "work of the session goes on outside its turn")
          ((< (if (numberp context) context 0) (harness-cache-compact--min-context))
           "the conversation is small")
          ((null option) "there is no saved option to follow")
          ((plist-get option :asks) "a message to it would be asked what goes first")
          ((null (plist-get option :kind)) "the saved option is to carry on"))))

;;;; The decision: turning it off and on

(defun harness-cache-compact--settings ()
  "Return what the setting holds now, as a decision records it: (:enabled BOOL).
BOOL is t or `:false', so that it travels as JSON."
  (list :enabled (if harness-cache-precompact t :false)))

(defun harness-cache-compact--settings-equal (a b)
  "Non-nil when settings A and B say the same.  Each is (:enabled BOOL)."
  (eq (and (harness-json-true-p (plist-get a :enabled)) t)
      (and (harness-json-true-p (plist-get b :enabled)) t)))

(defun harness-cache-compact--set-settings (settings)
  "Make the setting hold SETTINGS, saved as Settings saves it.
Signal when it cannot be saved, as when the policy sets it."
  (let ((enabled (and (harness-json-true-p (plist-get settings :enabled)) t)))
    (if (harness-method-exists-p 'config/set)
        (harness-call 'config/set 'harness-cache-precompact enabled)
      (harness-save-user-option 'harness-cache-precompact enabled))))

(defun harness-cache-compact--decision-undo (decision)
  "Undo DECISION, the one the feature keeps: turn compacting before the lapse off.
The `:undo' of the kind `precompact'.  While the setting holds what the
decision set it goes back to what it held before.  Return (OUTCOME .
MESSAGE), as `harness-decisions-define-kind' says."
  (let* ((record (plist-get decision :record))
         (now (harness-cache-compact--settings)))
    (cond ((harness-cache-compact--settings-equal now (plist-get record :after))
           (harness-cache-compact--set-settings (plist-get record :before))
           (cons 'undone "Undone: conversations are no longer compacted just before their prompt cache lapses"))
          ((harness-cache-compact--settings-equal now (plist-get record :before))
           (cons 'changed "Not undone: compacting before the prompt cache lapses was turned off since, so it stays off"))
          (t (cons 'changed "Not undone: the setting changed since (in Settings, say), so it stays as it is")))))

(defun harness-cache-compact--decision-redo (decision)
  "Redo DECISION, the one the feature keeps: turn compacting before the lapse on.
The `:redo' of the kind `precompact'.  While the setting holds what its
undo put back it holds what the decision set again.  Return (OUTCOME .
MESSAGE), as `harness-decisions-define-kind' says."
  (let* ((record (plist-get decision :record))
         (now (harness-cache-compact--settings)))
    (cond ((harness-cache-compact--settings-equal now (plist-get record :before))
           (harness-cache-compact--set-settings (plist-get record :after))
           (cons 'done "Redone: conversations are compacted just before their prompt cache lapses again"))
          ((harness-cache-compact--settings-equal now (plist-get record :after))
           (cons 'changed "Not redone: compacting before the prompt cache lapses is on again already, so it stays on"))
          (t (cons 'changed "Not redone: the setting changed since (in Settings, say), so it stays as it is")))))

(declare-function harness-decisions-define-kind "harness-decisions" (kind &rest spec))

(with-eval-after-load 'harness-decisions
  (harness-decisions-define-kind 'precompact
                                 :undo #'harness-cache-compact--decision-undo
                                 :redo #'harness-cache-compact--decision-redo))

(defun harness-cache-compact--live-decision (sid)
  "Return the id of the decision that keeps the feature on, making one if needed.
That is the newest `precompact' decision in effect whose settings after
it are the settings now; when there is none, one is kept, made in session
SID.  Nil without the decisions module, or when keeping it failed."
  (when (harness-method-exists-p 'decision/record)
    (condition-case err
        (let ((now (harness-cache-compact--settings)))
          (or (plist-get (cl-find-if
                          (lambda (d) (harness-cache-compact--settings-equal
                                       (plist-get (plist-get d :record) :after) now))
                          (harness-call 'decision/list :kind 'precompact :state 'done))
                         :id)
              (plist-get (harness-call 'decision/record 'precompact sid harness-cache-compact--decision-text
                                       (list :before (list :enabled :false) :after now))
                         :id)))
      (error (harness-log 'warn "cache-compact: could not keep the decision for %s: %s"
                          sid (harness-error-short-message err))
             nil))))

;;;; Doing it

(defun harness-cache-compact--clock (time)
  "Return TIME as a clock time."
  (format-time-string "%H:%M" time))

(defun harness-cache-compact--what (kind)
  "Return in words what compacting as KIND did."
  (pcase kind
    ('brief "compacted into a brief summary")
    ('summary "compacted into a summary")
    ('transcript "wrote the conversation to a transcript file")
    ('fresh "started afresh")
    (_ (format "compacted (%s)" kind))))

(defun harness-cache-compact--note-text (kind info)
  "Return the note that tells session compacted as KIND before its cache lapsed.
INFO is that of `cache/pre-expire'."
  (let ((context (plist-get info :context)))
    (format "Prompt cache about to lapse at %s: %s, while it was still cached%s"
            (harness-cache-compact--clock (plist-get info :expires))
            (harness-cache-compact--what kind)
            (if (and (numberp context) (> context 0))
                (format ", so the next message sends that instead of ~%s tokens uncached"
                        (harness-format-tokens context))
              ""))))

(defun harness-cache-compact--note (sid kind decided-by info)
  "Write the note that session SID was compacted as KIND before its cache lapsed.
It tells of the feature's decision (`:decision', [Turn off] and
\[Turn on]) and follows from the decision that made the saved option
the default, DECIDED-BY, if there is one.  INFO is that of
`cache/pre-expire'."
  (let* ((decision (harness-cache-compact--live-decision sid))
         (meta (append (and decision (list :decision decision))
                       (and (stringp decided-by) (list :decided-by decided-by))))
         (text (harness-cache-compact--note-text kind info)))
    (if (null meta)
        (harness-call 'session/hint sid text)
      (let ((node (harness-call 'session/append sid (list :kind 'hint :content text :meta meta))))
        (when (and decision (harness-method-exists-p 'decision/attach))
          (condition-case err
              (harness-call 'decision/attach decision sid (plist-get node :id))
            (error (harness-log 'warn "cache-compact: could not name the note of %s: %s"
                                decision (harness-error-short-message err)))))
        node))))

(defun harness-cache-compact--done (sid kind decided-by info node)
  "Tell of the compaction of session SID as KIND, NODE being its node."
  (when (harness-call 'session/exists-p sid)
    (harness-cache-compact--note sid kind decided-by info)
    (harness-emit 'cache/compacted sid kind node)))

(defun harness-cache-compact--run (sid kind decided-by info)
  "Compact session SID as KIND before its cache lapses; return a promise.
DECIDED-BY is the decision that made KIND the saved option, if any, and
INFO that of `cache/pre-expire'.  A failure is said in a hint and
logged, and the conversation is left as it was."
  (let ((promise (harness-make-promise)))
    (puthash sid promise harness-cache-compact--running)
    (harness-then
     (harness-call-async 'compaction/compact sid
                         (list :kind kind :idle t
                               :meta (list :precompact (list :choice (symbol-name kind)
                                                             :expires (plist-get info :expires)))))
     (lambda (node)
       (remhash sid harness-cache-compact--running)
       (condition-case err
           (harness-cache-compact--done sid kind decided-by info node)
         (error (harness-log 'warn "cache-compact: the note for %s failed: %s"
                             sid (harness-error-short-message err))))
       (harness-resolve promise node))
     (lambda (err)
       (remhash sid harness-cache-compact--running)
       (harness-log 'warn "cache-compact: compacting %s before its cache lapsed failed: %s"
                    sid (harness-error-short-message err))
       (harness-resolve promise nil)))
    promise))

(defun harness-cache-compact--on-pre-expire (sid info)
  "Compact session SID before its cache lapses, if all is as it should be.
On `cache/pre-expire'; INFO is its.  The cache is claimed first
\(`cache/claim'): this is the last handler, and the claim says so to
whoever comes after it."
  (let ((why (harness-cache-compact--skip-reason sid info)))
    (if why
        (harness-log 'debug "cache-compact: %s is not compacted: %s" sid why)
      (let* ((option (harness-cache-compact--option sid))
             (kind (plist-get option :kind)))
        (when (harness-call 'cache/claim sid 'compact)
          (harness-log 'info "cache-compact: compacting %s as %s, %.0f seconds before its cache lapses"
                       sid kind (max 0 (- (plist-get info :expires) (float-time))))
          (harness-cache-compact--run sid kind (plist-get option :decision) info))))))

(defun harness-cache-compact--gate (value next session)
  "Hold a turn in SESSION while the compaction before its cache lapsed runs.
VALUE and NEXT are those of the `agent/before-turn' filter: the message
goes with the compacted conversation, as one that met a cold cache
would."
  (let ((promise (gethash (plist-get session :id) harness-cache-compact--running)))
    (if (and promise (plist-get value :proceed))
        (harness-then promise
                      (lambda (_) (funcall next value))
                      (lambda (_) (funcall next value)))
      (funcall next value)))
  nil)

(defun harness-cache-compact--on-deleted (sid &rest _)
  "Forget session SID, which is gone.  On `session/deleted'."
  (remhash sid harness-cache-compact--running))

;;;; Module

(defun harness-cache-compact--init ()
  "Follow the caches that are about to lapse (idempotent)."
  ;; After the handler that reads the cache again (40), which claims it.
  (harness-on 'cache/pre-expire #'harness-cache-compact--on-pre-expire 60)
  (harness-on 'session/deleted #'harness-cache-compact--on-deleted)
  ;; Before the gate of a queued compaction (12) and the cold-cache one (15).
  (harness-add-filter 'agent/before-turn #'harness-cache-compact--gate 11))

(harness-declare-event 'cache/compacted "(SESSION-ID KIND NODE) after a session was compacted as KIND just before its prompt cache lapsed (harness-cache-compact.el): NODE is the compaction node.")

(harness-define-module 'cache-compact
  :doc "Compacts a conversation just before its prompt cache lapses, while it is still hot in it, as the user saved for a cold cache and where they would not be asked."
  :requires '(session compaction cache cowboy)
  :init #'harness-cache-compact--init)

(provide 'harness-cache-compact)
;;; harness-cache-compact.el ends here
