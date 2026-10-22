;;; harness-cache-warm.el --- Keeping a session's prompt cache warm while its user is around  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider's prompt cache lasts only a while after a request read it,
;; and every request that reads it keeps it that long again.  A user who
;; reads an answer, thinks, types a long reply, comes back from the
;; kitchen, takes longer than the cache lasts, and the message they send
;; then pays for the whole conversation again at the uncached price.  This
;; module keeps the cache of a session alive for as long as its user is
;; around: just before it would lapse (`cache/pre-expire', see
;; harness-cache.el: ten seconds ahead for a five-minute cache) it sends
;; the conversation once more, which reads the cache and starts its
;; lifetime afresh.  The new stamp moves the next moment on, so the chain
;; goes on by itself -- a refresh every few minutes, at the price of
;; reading the context from the cache, a tenth of sending it uncached --
;; until the user has been gone for the warm period, and the cache is
;; allowed to lapse.
;;
;; Whether the user is around is harness-cache.el's to say
;; (`cache/presence'): after a sign of life -- a message they send, a
;; question they answer, what the chat reports of them typing or using
;; the session's buffer (`cache/active') -- they count as around for the
;; warm period of the cache's lifetime (`cache/periods': the user counts
;; as active for a fifth of the lifetime, and the cache is kept warm for
;; a third of it, five minutes at least, after that; six minutes after
;; the last sign of life for a five-minute cache, 32 for an hour's).  The
;; user can also say they are coming back, though nothing says so yet:
;; `cache/keep-warm' keeps the session's cache warm for the time they
;; give, whatever happens.  The chat shows a flame and a coarse countdown
;; to the end of the period while it is on (`cache/warm-changed' carries
;; the state; harness-ui-cache-warm.el).
;;
;; What is sent is what the agent's next step would send -- the same
;; model, system prompt, tools, thinking level and conversation
;; (`harness-agent-step-request') -- because a cache reads a request only
;; as far as it starts like the one that wrote it, with one short message
;; added at the end.  Nothing of it is written into the session: the
;; message and the answer are not nodes of the transcript, only what the
;; request cost is recorded, in the session's usage, and the cache is
;; stamped anew.  A provider that holds the conversation itself (Claude
;; Code) is sent the message in the process that holds it, and keeps the
;; two short messages in the conversation it holds; one that cannot be
;; asked to without a side effect on the conversation does not say it
;; can (`:cache-refresh' among its capabilities) and its sessions are
;; left alone.  A user message that comes while a refresh is under way
;; waits for it, a few seconds at most.
;;
;; A turn that waits on a tool call lets the cache lapse as surely as a
;; user who is away does: no request reads it, and the step that follows
;; the tool will send the whole conversation, as it comes back from the
;; tool.  So the cache is kept warm for a tool that runs long too, a
;; smoke test, whoever is around: the request the turn's latest step sent
;; (`harness-agent-last-request') is sent again, which reads the very
;; cache that step wrote.  That is done for providers that are sent the
;; conversation at every request; one that holds the conversation in a
;; process has that process busy with the turn.
;;
;; Keeping a cache warm is worth it only for as long as the refreshes cost
;; less than sending the conversation again, uncached, would have: a
;; refresh costs a tenth of that for Claude's cache, so a five-minute cache
;; kept warm for three hours costs three times what letting it lapse and
;; paying for the conversation once more would.  At most as many refreshes
;; are made between two requests of the conversation's own as cost less
;; than the conversation sent uncached, from the prices the catalogue gives
;; the model (`compaction/resend-cost'): 12 for Claude's, two for a cache
;; that reads at half price.  Then the cache is left to lapse, the state
;; says why, and a note in the transcript says so; the next request of the
;; conversation's own starts the count afresh.
;;
;; Care is taken that keeping a cache warm never costs more than letting
;; it lapse would have:
;;
;; - only a warm cache is kept: one that lapsed is not written again for
;;   a user who may be typing, the message they send does that;
;; - a session running a turn is left alone while its model works: its
;;   own requests use the cache;
;; - a hard budget that is spent stops it (`usage/budget-block');
;; - a refresh that fails is tried again while there is time, and said
;;   once;
;; - a refresh that does not read the cache -- the provider wrote it
;;   again instead, because it did not find the conversation it cached --
;;   would repeat at every lapse for no gain: keeping that session warm
;;   stops, and a note in the transcript says why.  Asking for a period
;;   by hand tries again.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-cache)

(declare-function harness-agent-step-request "harness-agent" (session-id state on-event))
(declare-function harness-agent-last-request "harness-agent" (session-id))

(defcustom harness-cache-warm t
  "Non-nil to keep a session's prompt cache warm while its user is around.
A provider keeps the start of a conversation cached for a while after a
request read it.  A user who comes back after a pause longer than that
sends the whole conversation again, uncached.  With this on, the cache
of a session whose user typed, sent a message or used its chat a little
while ago is read once more just before it would lapse, which starts
its lifetime again, for as long as the user is around; it costs a tenth
of what sending the context uncached would.  The same goes for a turn
that waits on a tool call, a long test run say, whoever is around.  How
long after a sign of life depends on the lifetime of the cache (see
`cache/periods'), six minutes for a five-minute cache; and never for
longer than it costs less than sending the conversation again,
uncached (12 refreshes of Claude's cache).  The chat shows a flame and
the time left while it goes on, and a period can be asked for by hand."
  :type 'boolean :safe #'booleanp :group 'harness)

(defconst harness-cache-warm-message
  "[harness] This message only keeps the prompt cache warm: reply with just: ok"
  "The short message that ends the conversation a refresh of an idle session sends.")

(defconst harness-cache-warm--max-tokens 16
  "Most tokens the answer to a refresh may take: it is never read.")

(defconst harness-cache-warm--retries 3
  "How often a refresh that fails is tried, with the first.")

(defconst harness-cache-warm--retry-delay 3
  "Seconds to wait before a refresh that failed is tried again.")

(defconst harness-cache-warm--timeout 30
  "Seconds a refresh may take: a user message waits for it no longer.")

(defconst harness-cache-warm--hit-fraction 0.5
  "Part of the context a refresh has to read from the cache to have kept it.")

(defconst harness-cache-warm--default-max-refreshes 12
  "Most refreshes between two requests when no prices say how many pay.
Claude's cache reads at a tenth of the price of sending the context
again, uncached, and writes at 1.25 times the input price: 12 refreshes.")

;;;; State

(defvar harness-cache-warm--refreshing (make-hash-table :test 'equal)
  "Session id -> (:promise PROMISE :started TIME) while a refresh is under way.")

(defvar harness-cache-warm--counts (make-hash-table :test 'equal)
  "Session id -> how many refreshes were made since the session's last request.")

(defvar harness-cache-warm--blocked (make-hash-table :test 'equal)
  "Session id -> why keeping its cache warm stopped: a refresh did not read it.")

(defvar harness-cache-warm--capped (make-hash-table :test 'equal)
  "Session id -> why keeping its cache warm stopped for its cost.
Until the session's next request of its own.")

(defvar harness-cache-warm--failures (make-hash-table :test 'equal)
  "Session id -> t once a failed refresh was said, until one succeeds.")

(defvar harness-cache-warm--published (make-hash-table :test 'equal)
  "Session id -> the state `cache/warm-changed' last announced for it.")

(defvar harness-cache-warm--tooling (make-hash-table :test 'equal)
  "Session id -> t while its turn is known to wait on a tool call.")

(defvar harness-cache-warm--prices (make-hash-table :test 'equal)
  "Session id -> ((MODEL . CONTEXT) . ECONOMICS).
The prices of its model and context, as `harness-cache-warm--economics'
made them.")

(defvar harness-cache-warm--recording nil
  "Non-nil while the module records the usage of a refresh of its own.")

(defun harness-cache-warm--hosted-p (session)
  "Non-nil when SESSION's model is on a provider that holds the conversation."
  (harness-json-true-p
   (plist-get (ignore-errors (harness-call 'provider/capabilities (plist-get session :model)))
              :hosted-loop)))

(defun harness-cache-warm--running-p (sid)
  "Non-nil when session SID runs a turn."
  (and (harness-method-exists-p 'agent/running) (harness-call 'agent/running sid) t))

(defun harness-cache-warm--tool-wait-p (sid)
  "Non-nil when session SID's turn waits on a tool call.
The model does not work then and nothing reads the cache, though the
step that follows the tool will send the conversation."
  (and (harness-cache-warm--running-p sid)
       (harness-method-exists-p 'agent/activity)
       (eq 'tool (plist-get (harness-call 'agent/activity sid) :phase))))

(defun harness-cache-warm--supported-p (session)
  "Non-nil when SESSION's provider can be asked to read its cache again.
An API provider is sent the conversation as it is at every request, so
it can: while the session waits for the user, with a message added, and
while its turn waits on a tool, with the request of its latest step again
\(`harness-agent-last-request').  One that holds the conversation itself
says it can when sending it a message only keeps the cache of that
conversation warm (`:cache-refresh'), and only while it holds this
session's and no turn runs: its process is busy with the turn."
  (let* ((sid (plist-get session :id))
         (model (plist-get session :model))
         (running (harness-cache-warm--running-p sid)))
    (if (harness-cache-warm--hosted-p session)
        (and (not running)
             (harness-json-true-p (plist-get (ignore-errors (harness-call 'provider/capabilities model))
                                             :cache-refresh))
             (harness-method-exists-p 'session/provider-state)
             (harness-call 'session/provider-state sid model)
             t)
      (or (not running)
          (and (fboundp 'harness-agent-last-request) (harness-agent-last-request sid) t)))))

(defun harness-cache-warm--economics (sid)
  "Return what keeping session SID's cache warm costs against letting it lapse.
The answer is (:refresh USD :resend USD :max N): what one refresh costs,
reading the context from the cache; what sending the context uncached
costs; and how many refreshes cost less than that, at most.  USD is nil
where the catalogue gives the model no price, and N is then
`harness-cache-warm--default-max-refreshes', as it is where a refresh
costs nothing.  Nil, nothing: a cache that reads for as much as the context
costs uncached is not worth keeping."
  (let* ((session (harness-cache--session sid))
         (key (cons (plist-get session :model)
                    (plist-get (plist-get session :usage) :context)))
         (known (gethash sid harness-cache-warm--prices)))
    (if (and known (equal (car known) key))
        (cdr known)
      (let* ((cost (and (harness-method-exists-p 'compaction/resend-cost)
                        (condition-case err
                            (harness-call 'compaction/resend-cost sid)
                          (error (harness-log 'debug "cache-warm: no prices for %s: %s"
                                              sid (harness-error-short-message err))
                                 nil))))
             (read (plist-get cost :cached))
             (resend (plist-get cost :uncached))
             (max (cond ((not (and (numberp read) (numberp resend))) harness-cache-warm--default-max-refreshes)
                        ((<= read 0) harness-cache-warm--default-max-refreshes)
                        ;; As many as cost less than the conversation sent again.
                        (t (max 0 (1- (ceiling (/ resend read)))))))
             (economics (list :refresh (and (numberp read) read) :resend (and (numberp resend) resend)
                              :max max)))
        (puthash sid (cons key economics) harness-cache-warm--prices)
        economics))))

(defun harness-cache-warm--count (sid)
  "Return how many refreshes session SID's cache has had since its last request."
  (or (gethash sid harness-cache-warm--counts) 0))

(defun harness-cache-warm--cap-text (sid)
  "Return why session SID's cache is no longer kept warm for what it costs."
  (let* ((eco (harness-cache-warm--economics sid))
         (n (harness-cache-warm--count sid))
         (each (plist-get eco :refresh))
         (resend (plist-get eco :resend)))
    (format "after %d refresh%s%s keeping it warm costs about what sending the conversation again, uncached, does%s: the cache is left to lapse"
            n (if (= n 1) "" "es")
            (if each (format " (~%s each)" (harness-format-cost each)) "")
            (if resend (format " (~%s)" (harness-format-cost resend)) ""))))

(defun harness-cache-warm--state (sid &optional session now)
  "Return the state of session SID's warm period, or nil when it has none.
SESSION is its plist, NOW the time, by default the current one.  The state
is (:session-id SID :warming BOOL :until TIME :manual-until TIME
:active-at TIME :next TIME :refreshes N :max-refreshes N :refresh-cost USD
:resend-cost USD :tool BOOL :ttl SECONDS :expires TIME :supported BOOL
:blocked WHY).  `:warming' says the cache is being kept alive now: keeping
caches warm is on, the provider can, nothing stopped it, the user counts as
around or the turn waits on a tool call, and the session has a cache that
has not lapsed.  `:until' is the end of the period -- of the user's, or the
count of refreshes that pay, whichever is first --, `:manual-until' that of
the one the user asked for, `:active-at' the last sign of life, `:next'
when the next refresh is due, `:refreshes' how many were made since the
session's last request, `:max-refreshes' how many pay, `:refresh-cost' and
`:resend-cost' what a refresh and sending the conversation uncached cost,
`:tool' that the turn waits on a tool, and `:expires' when the cache
lapses."
  (let* ((session (or session (harness-cache--session sid)))
         (now (or now (float-time)))
         (presence (and session (harness-cache--presence-of sid session now)))
         (tool (and session (harness-cache-warm--tool-wait-p sid))))
    (when (and session (or presence tool))
      (let* ((cache (harness-cache--lapsing session))
             (expires (plist-get cache :expires))
             (ttl (harness-cache-ttl-of session))
             (lead (harness-cache-lead ttl))
             (eco (harness-cache-warm--economics sid))
             (count (harness-cache-warm--count sid))
             (left (- (plist-get eco :max) count))
             (blocked (or (gethash sid harness-cache-warm--blocked)
                          (gethash sid harness-cache-warm--capped)))
             (supported (harness-cache-warm--supported-p session))
             ;; The refreshes that pay end the period, where the user's
             ;; does not come first.
             (cap-until (and expires (> left 0) (+ expires (* (1- left) (- ttl lead)))))
             (until (cond (tool cap-until)
                          ((and (plist-get presence :until) cap-until) (min (plist-get presence :until) cap-until))
                          (t (plist-get presence :until))))
             (warming (and harness-cache-warm supported (not blocked) (> left 0)
                           until (> until now)
                           cache (> expires now))))
        (list :session-id sid :warming (if warming t :false)
              :until until
              :manual-until (plist-get presence :manual-until)
              :active-at (plist-get presence :active-at)
              :next (and warming (- expires lead))
              :refreshes count :max-refreshes (plist-get eco :max)
              :refresh-cost (plist-get eco :refresh) :resend-cost (plist-get eco :resend)
              :tool (if tool t :false)
              :ttl ttl :expires expires :supported (if supported t :false)
              :blocked blocked)))))

(defun harness-cache-warm--same-p (a b)
  "Non-nil when states A and B say the same, but for a little drift in time."
  (or (and (null a) (null b))
      (and a b
           (eq (harness-json-true-p (plist-get a :warming)) (harness-json-true-p (plist-get b :warming)))
           (eq (harness-json-true-p (plist-get a :supported)) (harness-json-true-p (plist-get b :supported)))
           (eq (harness-json-true-p (plist-get a :tool)) (harness-json-true-p (plist-get b :tool)))
           (equal (plist-get a :manual-until) (plist-get b :manual-until))
           (equal (plist-get a :refreshes) (plist-get b :refreshes))
           (equal (plist-get a :max-refreshes) (plist-get b :max-refreshes))
           (equal (plist-get a :blocked) (plist-get b :blocked))
           (cl-flet ((near (key drift)
                       (let ((x (plist-get a key)) (y (plist-get b key)))
                         (if (and (numberp x) (numberp y)) (< (abs (- x y)) drift) (eq x y)))))
             (and (near :until harness-cache--drift)
                  (near :next 5)
                  (near :expires 5))))))

(defun harness-cache-warm--publish (sid &optional session)
  "Announce the state of session SID's warm period if it changed.
`cache/warm-changed' carries the state, nil once the period is over.
SESSION is the plist of the session, when the caller has it.  Return the
state."
  (let ((state (harness-cache-warm--state sid session))
        (old (gethash sid harness-cache-warm--published)))
    (unless (harness-cache-warm--same-p old state)
      (if state
          (puthash sid state harness-cache-warm--published)
        (remhash sid harness-cache-warm--published))
      (harness-emit 'cache/warm-changed sid state))
    state))

(harness-defmethod cache/keep-warm (session-id seconds)
  "Keep SESSION-ID's prompt cache warm for SECONDS from now, whatever happens.
For a user who knows they will be back before anything says so: a
period of their own (`cache/active' with the seconds), a day at most, and
no longer than the refreshes cost less than sending the conversation
again.  SECONDS nil or 0 takes that period away again, which leaves the
one the user's own signs of life made.  Asking for one tries again where
keeping the cache warm had stopped because a refresh did not read it.
Return the state of the session's period (see `cache/warm'), nil for a
session that is gone or has none."
  (when (harness-call 'session/exists-p session-id)
    (let ((n (cond ((numberp seconds) (max 0 seconds))
                   ((and (stringp seconds) (string-match-p "\\`[0-9.]+\\'" seconds))
                    (string-to-number seconds))
                   (t 0))))
      (when (> n 0)
        (remhash session-id harness-cache-warm--blocked)
        (remhash session-id harness-cache-warm--failures))
      (harness-call 'cache/active session-id n)
      (harness-cache-warm--publish session-id))))

(harness-defmethod cache/warm (session-id)
  "Return the state of SESSION-ID's warm period, or nil when it has none.
The state is (:session-id SID :warming BOOL :until TIME :manual-until
TIME :active-at TIME :next TIME :refreshes N :max-refreshes N
:refresh-cost USD :resend-cost USD :tool BOOL :ttl SECONDS :expires TIME
:supported BOOL :blocked WHY).  `:warming' says the session's cache is
being kept alive: keeping caches warm is on (`harness-cache-warm'), its
provider can be asked to, nothing stopped it, the user counts as around
\(`cache/presence') or the turn waits on a tool call, and the cache has
not lapsed.  `:until' is the end of the period, the user's or that of the
refreshes that cost less than sending the conversation again, whichever
comes first; `:manual-until' that of the one asked for by hand,
`:active-at' the time of the last sign of life, `:next' when the next
refresh is due, `:refreshes' how many were made since the session's last
request, `:max-refreshes' how many pay, `:refresh-cost' and `:resend-cost'
what a refresh and sending the conversation uncached cost (nil where the
catalogue has no price), `:ttl' and `:expires' the lifetime of the cache
and when it lapses, `:blocked' why keeping it warm stopped, if it did."
  (harness-cache-warm--state session-id))

(harness-defmethod cache/warm-list ()
  "Return the states of the sessions whose warm period is in effect.
See `cache/warm'; a client that connects asks for them once and then
hears `cache/warm-changed'."
  (let ((now (float-time)) out)
    (dolist (sid (delete-dups (append (harness-cache-around-ids)
                                      (hash-table-keys harness-cache-warm--tooling))))
      (when-let* ((state (harness-cache-warm--state sid nil now)))
        (push state out)))
    out))

;;;; Reading the cache once more

(defun harness-cache-warm--request (sid on-event)
  "Return the request that reads session SID's conversation once more.
For a session that waits for the user, it is what the agent's next step
would send (`harness-agent-step-request') with a short message at the end,
the answer to which is never read: a few tokens at most.  A provider that
holds the conversation itself is sent the message alone, in its process.
For a session whose turn waits on a tool, it is the request the turn's
latest step sent (`harness-agent-last-request'), which the step after the
tool will start as.  The provider is told it is a refresh.  ON-EVENT
listens to it."
  (let ((session (harness-call 'session/get sid)))
    (if (harness-cache-warm--running-p sid)
        (append (harness-plist-remove (harness-agent-last-request sid) :on-event :max-tokens)
                (list :on-event on-event :max-tokens harness-cache-warm--max-tokens :cache-refresh t))
      (let* ((model (plist-get session :model))
             (state (harness-call 'session/provider-state sid model))
             (request (harness-agent-step-request sid state on-event))
             (ping (list :role 'user :content (list (list :type "text" :text harness-cache-warm-message))))
             (messages (if (harness-cache-warm--hosted-p session)
                           (list ping)
                         (append (plist-get request :messages) (list ping)))))
        (append (harness-plist-remove request :messages)
                (list :messages messages :max-tokens harness-cache-warm--max-tokens :cache-refresh t))))))

(defun harness-cache-warm--budget-block (sid)
  "Return why a hard budget forbids another request in session SID, or nil."
  (and (harness-method-exists-p 'usage/budget-block)
       (condition-case err
           (harness-call 'usage/budget-block sid)
         (error (harness-log 'warn "cache-warm: no budget check for %s: %s"
                             sid (harness-error-short-message err))
                nil))))

(defun harness-cache-warm--skip-reason (sid info)
  "Return why session SID's cache is not read again now, or nil.
INFO is that of `cache/pre-expire'.  A cache that has been refreshed as
often as pays is not reported here: `harness-cache-warm--on-pre-expire'
says so."
  (let* ((session (harness-cache--session sid))
         (status (plist-get session :status))
         (running (or (plist-get info :running) (and session (harness-cache-warm--running-p sid))))
         (tool (and session running (harness-cache-warm--tool-wait-p sid))))
    (cond ((null session) "the session is gone")
          ((not harness-cache-warm) "keeping caches warm is off")
          ((not (or tool (harness-cache-around-p sid session)))
           (if running "a turn is running" "the user has been gone for the warm period"))
          ((gethash sid harness-cache-warm--blocked) "keeping it warm stopped")
          ((gethash sid harness-cache-warm--capped) "keeping it warm costs more than it saves")
          ((eql 0 (plist-get (harness-cache-warm--economics sid) :max))
           "reading the cache costs as much as sending the conversation again")
          ((and running (not tool)) "a turn is running")
          ((and (not running) (not (eq (if (stringp status) (intern status) status) 'idle)))
           "the session is not idle")
          ((gethash sid harness-cache-warm--refreshing) "a refresh is under way")
          ((eq (plist-get session :kind) 'internal) "the session records one call")
          ((not (harness-cache-warm--supported-p session)) "its provider cannot be asked to")
          ((harness-cache-warm--budget-block sid)))))

(defun harness-cache-warm--record (sid model usage started ttl)
  "Record in SID's usage what the refresh cost.
USAGE is what the provider reported, MODEL the model it ran on, STARTED
when it was sent and TTL the lifetime of the cache before it.  The
cache is stamped anew when the request read or wrote it, as of when it
was sent, with the lifetime the provider reported or TTL; the
context is left as it was, the message and its answer are not part of
it.  A request that used no cache records its cost alone: the stamp it
would otherwise drop is not its to drop."
  (let ((cached (> (+ (or (plist-get usage :cache-read) 0) (or (plist-get usage :cache-write) 0)) 0))
        (harness-cache-warm--recording t))
    (cond
     (cached
      (harness-call 'session/usage-add sid
                    (list :input (or (plist-get usage :input) 0) :output (or (plist-get usage :output) 0)
                          :cache-read (plist-get usage :cache-read) :cache-write (plist-get usage :cache-write)
                          :cost (plist-get usage :cost) :list-cost (plist-get usage :list-cost)
                          :billing (plist-get usage :billing) :plan (plist-get usage :plan)
                          :model model
                          :cache-at (or (plist-get usage :cache-at) started)
                          :cache-ttl (or (plist-get usage :cache-ttl) ttl))))
     ((numberp (plist-get usage :cost))
      (harness-call 'session/usage-add sid (list :cost (plist-get usage :cost) :model model))))))

(defun harness-cache-warm--stop (sid why)
  "Stop keeping session SID's cache warm for the reason WHY, and say so."
  (puthash sid why harness-cache-warm--blocked)
  (harness-log 'warn "cache-warm: %s: %s" sid why)
  (when (harness-call 'session/exists-p sid)
    (ignore-errors
      (harness-call 'session/hint sid (format "Stopped keeping the prompt cache warm: %s" why)))
    (harness-cache-warm--publish sid)))

(defun harness-cache-warm--cap (sid)
  "Stop keeping session SID's cache warm: it has cost as much as it saves.
Until the session's next request of its own, which starts the count
afresh."
  (let ((why (harness-cache-warm--cap-text sid)))
    (puthash sid why harness-cache-warm--capped)
    (harness-log 'info "cache-warm: %s: %s" sid why)
    (ignore-errors
      (harness-call 'session/hint sid (format "Stopped keeping the prompt cache warm: %s" why)))
    (harness-cache-warm--publish sid)))

(defun harness-cache-warm--failed (sid attempt message)
  "Deal with the refresh of session SID, its ATTEMPT-th, failing with MESSAGE.
It is tried again after a short wait while the cache lasts for it;
otherwise the failure is said, once until a refresh succeeds."
  (let* ((session (harness-cache--session sid))
         (expires (plist-get (harness-cache--lapsing session) :expires)))
    (harness-log 'warn "cache-warm: refresh %d of %s failed: %s" attempt sid message)
    (if (and expires (< attempt harness-cache-warm--retries)
             (> (- expires (float-time))
                (+ harness-cache--too-late harness-cache-warm--retry-delay)))
        (run-at-time harness-cache-warm--retry-delay nil #'harness-cache-warm--retry sid attempt)
      (when (and session (not (gethash sid harness-cache-warm--failures)))
        (puthash sid t harness-cache-warm--failures)
        (ignore-errors
          (harness-call 'session/hint sid (format "Could not keep the prompt cache warm: %s" message)))))))

(defun harness-cache-warm--retry (sid attempt)
  "Try the refresh of session SID again after ATTEMPT failed, if it is still due."
  (when (null (harness-cache-warm--skip-reason sid (list :running nil)))
    (harness-cache-warm--refresh sid (1+ attempt))))

(defun harness-cache-warm--finish (sid attempt model before started ttl usage event)
  "Deal with the end of the refresh of session SID, its ATTEMPT-th.
MODEL, BEFORE (its usage when the refresh was sent), STARTED, TTL, USAGE
and EVENT, the `done' event, are what the refresh met.  A refresh that
read the cache keeps it, and counts; one that did not stops the
session's warming."
  (when (harness-call 'session/exists-p sid)
    (let ((reason (plist-get event :stop-reason)))
      (cond
       ((memq reason '(error cancelled))
        (when usage (harness-cache-warm--record sid model usage started ttl))
        (harness-cache-warm--failed sid attempt (or (plist-get event :error) (format "%s" reason))))
       ((null usage)
        (harness-cache-warm--stop
         sid "the provider reports no usage for a request, so nothing says the cache was read"))
       (t
        (harness-cache-warm--record sid model usage started ttl)
        (let* ((read (or (plist-get usage :cache-read) 0))
               (context (let ((c (plist-get before :context))) (and (numberp c) (> c 0) c))))
          (if (and (> read 0) (or (null context) (>= read (* harness-cache-warm--hit-fraction context))))
              (progn
                (remhash sid harness-cache-warm--failures)
                (puthash sid (1+ (harness-cache-warm--count sid)) harness-cache-warm--counts)
                (harness-cache-warm--publish sid))
            (harness-cache-warm--stop
             sid "the provider did not read the conversation's cache when it was sent again (it wrote it instead)"))))))))

(defun harness-cache-warm--refresh (sid &optional attempt)
  "Send session SID's conversation once more, to read its cache; return a promise.
ATTEMPT counts the tries, from 1.  The promise settles, with
\(:stop-reason R), when the refresh is over, however it ended; a turn the
user starts waits for it.  See `harness-cache-warm--request' for what
is sent and `harness-cache-warm--finish' for what comes of it."
  (let* ((attempt (or attempt 1))
         (promise (harness-make-promise))
         (started (float-time))
         (session (harness-call 'session/get sid))
         (model (plist-get session :model))
         (before (plist-get session :usage))
         (ttl (harness-cache-ttl-of session))
         (usage nil) (handle nil) (done nil) (timer nil))
    (cl-labels ((finish (event)
                  (unless done
                    (setq done t)
                    (when timer (cancel-timer timer))
                    (remhash sid harness-cache-warm--refreshing)
                    (condition-case err
                        (harness-cache-warm--finish sid attempt model before started ttl usage event)
                      (error (harness-log 'warn "cache-warm: finishing the refresh of %s failed: %s"
                                          sid (harness-error-short-message err))))
                    (harness-resolve promise (list :stop-reason (plist-get event :stop-reason)))))
                (cancel ()
                  (when (and handle (functionp (plist-get handle :cancel)))
                    (ignore-errors (funcall (plist-get handle :cancel)))))
                (on-event (event)
                  (unless done
                    (pcase (plist-get event :type)
                      ('usage (setq usage event))
                      ((or 'tool-call 'tool-permission)
                       (cancel)
                       (finish (list :type 'done :stop-reason 'error
                                     :error "the model called a tool in answer to the refresh")))
                      ('done (finish event))))))
      (puthash sid (list :promise promise :started started) harness-cache-warm--refreshing)
      (setq timer (run-at-time harness-cache-warm--timeout nil
                               (lambda ()
                                 (unless done
                                   (cancel)
                                   (finish (list :type 'done :stop-reason 'error :error "it took too long"))))))
      (condition-case err
          (setq handle (harness-call 'provider/complete
                                     (harness-cache-warm--request sid #'on-event)))
        (error (finish (list :type 'done :stop-reason 'error :error (harness-error-short-message err))))))
    promise))

;;;; The event

(defun harness-cache-warm--on-pre-expire (sid info)
  "Read session SID's cache once more, if its user is around.
On `cache/pre-expire'; INFO is its.  The cache is claimed first
\(`cache/claim'), so that whoever would do something else to it, compact
the conversation, finds it taken.  A cache that has been refreshed as
often as pays is left to lapse instead, and the state says why."
  (let ((why (harness-cache-warm--skip-reason sid info)))
    (cond
     (why (harness-log 'debug "cache-warm: %s is not refreshed: %s" sid why))
     ((>= (harness-cache-warm--count sid) (plist-get (harness-cache-warm--economics sid) :max))
      (harness-cache-warm--cap sid))
     ((harness-call 'cache/claim sid 'warm)
      (harness-log 'info "cache-warm: reading the cache of %s again, %.0f seconds before it lapses"
                   sid (max 0 (- (plist-get info :expires) (float-time))))
      (harness-cache-warm--refresh sid)))))

(defun harness-cache-warm--gate (value next session)
  "Hold a user's turn in SESSION while a refresh of its cache is under way.
VALUE and NEXT are those of the `agent/before-turn' filter.  A refresh
runs in the process that holds the conversation of a hosted loop, which
a turn started meanwhile would supersede.  It takes seconds, and ends in
thirty at most."
  (let ((entry (gethash (plist-get session :id) harness-cache-warm--refreshing)))
    (if (and entry (plist-get value :proceed))
        (harness-then (plist-get entry :promise)
                      (lambda (_) (funcall next value))
                      (lambda (_) (funcall next value)))
      (funcall next value)))
  nil)

(defun harness-cache-warm--on-presence (sid presence)
  "Announce session SID's state again: the user's PRESENCE in it changed.
On `cache/presence-changed'."
  (ignore presence)
  (harness-cache-warm--publish sid))

(defun harness-cache-warm--on-changed (sid session)
  "Announce session SID's state again if its period is on and it changed.
On `session/changed'; SESSION is the plist.  A cache that was refreshed,
or went, or a model that was switched, changes what the state says."
  (when (or (gethash sid harness-cache-warm--published)
            (harness-cache--presence-of sid session)
            (gethash sid harness-cache-warm--tooling))
    (harness-cache-warm--publish sid session)))

(defun harness-cache-warm--on-activity (sid activity)
  "Announce session SID's state: its turn started or stopped waiting on a tool.
On `agent/activity-changed'; ACTIVITY is what the turn does, nil once
it ended.  A turn waiting on a tool call is a period of its own."
  (let ((tool (eq 'tool (plist-get activity :phase))))
    (unless (eq tool (and (gethash sid harness-cache-warm--tooling) t))
      (if tool
          (puthash sid t harness-cache-warm--tooling)
        (remhash sid harness-cache-warm--tooling))
      (harness-cache-warm--publish sid))))

(defun harness-cache-warm--on-usage (sid _totals record)
  "Start session SID's count of refreshes afresh: a request of its own was made.
On `session/usage'; RECORD is the usage record.  The module's own
records do not count, and neither do those that report no request."
  (when (and (not harness-cache-warm--recording)
             (or (numberp (plist-get record :input)) (numberp (plist-get record :output))))
    (remhash sid harness-cache-warm--counts)
    (remhash sid harness-cache-warm--capped)))

(defun harness-cache-warm--on-updated (sid changes)
  "Forget why keeping session SID's cache warm stopped if it changed models.
On `session/updated'; CHANGES are the settings that changed.  The cache
is another model's now, and nothing says that one fails to be read."
  (when (plist-member changes :model)
    (remhash sid harness-cache-warm--blocked)
    (remhash sid harness-cache-warm--capped)
    (remhash sid harness-cache-warm--failures)
    (remhash sid harness-cache-warm--prices)))

(defun harness-cache-warm--on-deleted (sid &rest _)
  "Forget session SID, which is gone.  On `session/deleted'."
  (dolist (table (list harness-cache-warm--counts harness-cache-warm--blocked harness-cache-warm--capped
                       harness-cache-warm--failures harness-cache-warm--refreshing
                       harness-cache-warm--tooling harness-cache-warm--prices))
    (remhash sid table))
  (when (gethash sid harness-cache-warm--published)
    (remhash sid harness-cache-warm--published)
    (harness-emit 'cache/warm-changed sid nil)))

;;;; Module

(defun harness-cache-warm--init ()
  "Follow the sessions and the user's presence (idempotent)."
  (harness-on 'cache/pre-expire #'harness-cache-warm--on-pre-expire 40)
  (harness-on 'cache/presence-changed #'harness-cache-warm--on-presence)
  (harness-on 'session/changed #'harness-cache-warm--on-changed)
  (harness-on 'session/updated #'harness-cache-warm--on-updated)
  (harness-on 'session/deleted #'harness-cache-warm--on-deleted)
  (harness-on 'session/usage #'harness-cache-warm--on-usage)
  (harness-on 'agent/activity-changed #'harness-cache-warm--on-activity)
  ;; Ahead of every gate that could change the session or ask about it.
  (harness-add-filter 'agent/before-turn #'harness-cache-warm--gate 1))

(harness-declare-event 'cache/warm-changed "(SESSION-ID STATE) when the state of a session's warm period changed: the cache is being kept warm (STATE's `:warming') or not, the end of the period moved, a refresh was made or keeping the cache warm stopped.  STATE is as `cache/warm' returns it, nil once the period is over.")

(harness-define-module 'cache-warm
  :doc "Keeps a session's prompt cache warm while its user is around or a tool runs: reads it again just before it lapses, for as long as that costs less than sending the conversation again."
  :requires '(session provider agent cache)
  :init #'harness-cache-warm--init)

(provide 'harness-cache-warm)
;;; harness-cache-warm.el ends here
