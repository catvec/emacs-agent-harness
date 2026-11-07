;;; harness-cache.el --- Watching the prompt caches of the sessions  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider keeps the start of a conversation cached for a while after
;; a request used it, and a session records when that was and for how long
;; (its `:cache', see harness-session.el).  Two things are worth doing
;; with a cache that is about to lapse while the context is still hot in
;; it: read it once more, which restarts its lifetime (harness-cache-warm.el),
;; or compact the conversation, which is cheaper from a cache that lasts
;; (harness-cache-compact.el).  Neither needs to watch the clock: this
;; module does, and says when.
;;
;; The watcher keeps one timer for each session whose `:cache' will lapse,
;; set for `lead' seconds before it does, and emits `cache/pre-expire'
;; then: (SESSION-ID INFO), INFO being (:expires TIME :ttl SECONDS :lead
;; SECONDS :at TIME :model MODEL :context TOKENS :status STATUS :running
;; BOOL).  Whoever subscribes acts on the event; the watcher does nothing
;; to the session itself, and nothing polls.  Every change of a session
;; (`session/changed') sets the timer again from its `:cache' as it is
;; then, so a request that read the cache -- a refresh included -- moves
;; the moment on by itself, and a cache that is gone (a compaction, a
;; redaction, a switch to another model, whose provider holds none of it)
;; takes the timer away.  The event comes once for each moment a cache
;; lapses, and never for one that is lapsed already or has too little
;; time left to act on: a machine that slept through the moment says
;; nothing when it wakes.
;;
;; Two handlers of the event may want the same cache -- one reads it
;; again, the other compacts the conversation that is in it, and the
;; second has no use for it once the first took it.  The one that acts
;; claims the session for that moment (`cache/claim'), and the ones that
;; come after it ask (`cache/claimed').  The claim is good for the moment
;; of the lapse it was made for: a request that read the cache moves the
;; moment, and with it ends the claim.
;;
;; A cache is worth more than a warning about the lapse: it is what keeps
;; an agent loop from paying for its whole conversation every step.  The
;; session says after each request how much of the last prompt came from
;; the cache (`cache/reuse', emitted by `session/usage-add'), and this
;; module watches that: a request that reads less than
;; `harness-cache-health-threshold' of the previous prompt is a miss, and
;; a streak of them says the cache is not working.  It then tells the
;; user -- a hint, a notification, a warning, `cache/poor-hit' -- and,
;; with `harness-cache-health-action' `stop', cancels the turn, rather
;; than let a session re-send its context at the uncached rate step after
;; step without anyone noticing.
;;
;; Whether to act on a lapse depends on whether the user is around.  A
;; sign of life from them -- a message they send, a question they answer,
;; and whatever a client says with `cache/active': the chat reports the
;; user typing, or using the session's buffer -- makes them count as
;; around for the warm period that follows (below), and the user can say
;; they will be back though nothing says so yet, a period of their own
;; (`cache/active' with the seconds).  `cache/presence' says when they
;; stop counting as around; `cache/presence-changed' announces it.  The
;; one feature reads the cache again for as long as the user is around;
;; the other compacts the conversation once they are not.
;;
;; The periods are generic in the cache's lifetime T, so that a provider
;; keeping its cache 37 minutes, or an hour and a half, behaves as one
;; that keeps it five minutes or an hour (`cache/periods'):
;;
;; - the lead, how long before the cache lapses the event comes: T/30,
;;   not under 10 seconds and not over a minute -- close enough to be as
;;   efficient as can be, far enough that a request that has to retry, or
;;   meets some latency, still lands before the cache is gone.  10
;;   seconds for a five-minute cache, a minute for an hour's;
;; - the active window, how long after a sign of life from the user
;;   (typing, a message, any command in the session's chat) they count as
;;   active: T/5.  A minute for a five-minute cache, 12 minutes for an
;;   hour's;
;; - the grace, how much longer the cache is kept warm after that: a
;;   third of T, but at least five minutes.  Five minutes for a
;;   five-minute cache, 20 for an hour's;
;; - the warm period, the two together: how long after a sign of life a
;;   session's cache is kept warm.  Six minutes for a five-minute cache,
;;   32 for an hour's, 19 for 37 minutes, 48 for an hour and a half.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

;;;; The periods

(defconst harness-cache--lead-fraction (/ 1.0 30)
  "Part of a cache's lifetime that is the lead, before the bounds.")

(defconst harness-cache--lead-min 10
  "Fewest seconds the lead is: a request needs time to land before the lapse.")

(defconst harness-cache--lead-max 60
  "Most seconds the lead is, however long the cache lasts.")

(defconst harness-cache--active-fraction 0.2
  "Part of a cache's lifetime that the user counts as active after a sign of life.")

(defconst harness-cache--grace-fraction (/ 1.0 3)
  "Part of a cache's lifetime that it is kept warm after the active window.")

(defconst harness-cache--grace-min 300
  "Fewest seconds the grace is: a five-minute cache is kept warm five minutes more.")

(defconst harness-cache--too-late 2
  "Seconds before a cache lapses from which an event about it comes too late.
A request cannot be made, let alone land, in less.")

(defun harness-cache--seconds (ttl)
  "Return TTL when it is a positive number of seconds, else `harness-cache-ttl'."
  (cond ((and (numberp ttl) (> ttl 0)) ttl)
        ((and (boundp 'harness-cache-ttl) (numberp (symbol-value 'harness-cache-ttl))
              (> (symbol-value 'harness-cache-ttl) 0))
         (symbol-value 'harness-cache-ttl))
        (t 300)))

(defun harness-cache-lead (ttl)
  "Return how many seconds before a cache kept TTL seconds lapses the event comes.
A thirtieth of TTL, between `harness-cache--lead-min' and
`harness-cache--lead-max' seconds, and never over half of TTL, for a
cache that lasts hardly any time at all."
  (let ((ttl (harness-cache--seconds ttl)))
    (float (min (/ ttl 2.0)
                (max harness-cache--lead-min
                     (min harness-cache--lead-max (* ttl harness-cache--lead-fraction)))))))

(defun harness-cache-active-window (ttl)
  "Return how many seconds after a sign of life the user counts as active.
A fifth of TTL, the cache's lifetime in seconds."
  (float (* (harness-cache--seconds ttl) harness-cache--active-fraction)))

(defun harness-cache-grace (ttl)
  "Return how many seconds the cache is kept warm after the active window.
A third of TTL, but at least `harness-cache--grace-min'."
  (let ((ttl (harness-cache--seconds ttl)))
    (float (max harness-cache--grace-min (* ttl harness-cache--grace-fraction)))))

(defun harness-cache-warm-period (ttl)
  "Return how long a cache kept TTL seconds stays warm after a sign of life.
In seconds: the active window and the grace together."
  (+ (harness-cache-active-window ttl) (harness-cache-grace ttl)))

(harness-defmethod cache/periods (ttl)
  "Return the periods that go with a prompt cache kept TTL seconds.
TTL nil is `harness-cache-ttl'.  The answer is (:ttl S :lead S :active S
:grace S :warm S), all in seconds: how long before the cache lapses
`cache/pre-expire' comes, how long after a sign of life the user counts
as active, how much longer the cache is kept warm after that, and the
last two together, the warm period.  See the commentary of
harness-cache.el for the formulas."
  (let ((ttl (harness-cache--seconds ttl)))
    (list :ttl ttl :lead (harness-cache-lead ttl)
          :active (harness-cache-active-window ttl)
          :grace (harness-cache-grace ttl)
          :warm (harness-cache-warm-period ttl))))

;;;; The user

(defconst harness-cache--max-manual (* 24 3600)
  "Most seconds a period the user asked for lasts.")

(defconst harness-cache--drift 30
  "Seconds the end of a period moves before it is announced again.")

(defvar harness-cache--presence (make-hash-table :test 'equal)
  "Session id -> (:active-at TIME :manual-until TIME).
When the user last showed a sign of life in the session, and when the
period they asked for ends.  A session leaves it once the user stops
counting as around.")

(defvar harness-cache--announced (make-hash-table :test 'equal)
  "Session id -> the presence `cache/presence-changed' last announced.")

(defvar harness-cache--ends (make-hash-table :test 'equal)
  "Session id -> the timer set for the end of the user's period.")

(defun harness-cache--session (sid)
  "Return the plist of session SID, or nil when there is none."
  (and (harness-call 'session/exists-p sid) (harness-call 'session/get sid)))

(defun harness-cache-ttl-of (session)
  "Return the lifetime of the prompt cache of SESSION, a plist, in seconds.
The lifetime its cache was stamped with, else the one its model's
provider keeps one for."
  (let ((ttl (plist-get (plist-get session :cache) :ttl)))
    (or (and (numberp ttl) (> ttl 0) ttl)
        (and (harness-method-exists-p 'provider/cache-ttl) (plist-get session :model)
             (ignore-errors (harness-call 'provider/cache-ttl (plist-get session :model))))
        (harness-cache--seconds nil))))

(defun harness-cache-around-until (sid &optional session)
  "Return when the user stops counting as around in session SID, or nil.
SESSION is its plist.  The later of the warm period after their last
sign of life, for the lifetime of the session's cache
\(`harness-cache-warm-period'), and the period they asked for."
  (let* ((rec (gethash sid harness-cache--presence))
         (session (and rec (or session (harness-cache--session sid))))
         (active (plist-get rec :active-at))
         (manual (plist-get rec :manual-until))
         (auto (and session (numberp active)
                    (+ active (harness-cache-warm-period (harness-cache-ttl-of session))))))
    (cond ((and auto manual) (max auto manual))
          (auto)
          (manual))))

(defun harness-cache-around-p (sid &optional session now)
  "Non-nil when the user counts as around in session SID at NOW.
SESSION is its plist.  See `harness-cache-around-until'."
  (let ((until (harness-cache-around-until sid session)))
    (and until (> until (or now (float-time))) t)))

(defun harness-cache-around-ids ()
  "Return the ids of the sessions the user ever showed a sign of life in lately.
Some of them have stopped counting as around: `cache/presence' says."
  (hash-table-keys harness-cache--presence))

(defun harness-cache--presence-of (sid &optional session now)
  "Return the presence of the user in session SID, a plist, or nil.
It is (:session-id SID :around BOOL :until TIME :active-at TIME
:manual-until TIME), nil when the user never showed a sign of life in the
session or the time for it has passed.  SESSION is the plist of the
session, NOW the time."
  (when-let* ((rec (gethash sid harness-cache--presence))
              (session (or session (harness-cache--session sid))))
    (let* ((now (or now (float-time)))
           (until (harness-cache-around-until sid session))
           (manual (let ((m (plist-get rec :manual-until))) (and (numberp m) (> m now) m))))
      (when (and until (> until now))
        (list :session-id sid :around t :until until
              :active-at (plist-get rec :active-at) :manual-until manual)))))

(defun harness-cache--same-presence-p (a b)
  "Non-nil when presences A and B say the same, but for a little drift in time."
  (or (and (null a) (null b))
      (and a b
           (equal (plist-get a :manual-until) (plist-get b :manual-until))
           (< (abs (- (plist-get a :until) (plist-get b :until))) harness-cache--drift))))

(defun harness-cache--announce (sid &optional session)
  "Announce the presence of the user in session SID if it changed.
`cache/presence-changed' carries it, nil once the user stops counting as
around.  SESSION is the plist of the session, when the caller has it."
  (let ((presence (harness-cache--presence-of sid session))
        (old (gethash sid harness-cache--announced)))
    (unless (harness-cache--same-presence-p old presence)
      (if presence
          (puthash sid presence harness-cache--announced)
        (remhash sid harness-cache--announced))
      (harness-emit 'cache/presence-changed sid presence))
    presence))

(defun harness-cache--arm-end (sid)
  "Set the timer for the end of the period of the user in session SID."
  (when-let* ((timer (gethash sid harness-cache--ends)))
    (cancel-timer timer)
    (remhash sid harness-cache--ends))
  (when-let* ((until (harness-cache-around-until sid))
              ((> until (float-time))))
    (puthash sid (run-at-time (+ 0.25 (- until (float-time))) nil #'harness-cache--end sid)
             harness-cache--ends)))

(defun harness-cache--end (sid)
  "Close the period of the user in session SID, now over unless it was lengthened."
  (remhash sid harness-cache--ends)
  (if (harness-cache-around-p sid)
      (harness-cache--arm-end sid)
    (remhash sid harness-cache--presence)
    (harness-cache--announce sid)))

(defun harness-cache--note (sid &optional seconds)
  "Note a sign of life of the user in session SID; return their presence.
With SECONDS a positive number the user also asks to count as around for
that long from now, a day at most; with 0 the period they asked for is
taken away, and that is no sign of life."
  (when (harness-call 'session/exists-p sid)
    (let ((rec (copy-sequence (gethash sid harness-cache--presence)))
          (now (float-time)))
      (cond ((and (numberp seconds) (> seconds 0))
             (setq rec (plist-put (plist-put rec :active-at now)
                                  :manual-until (+ now (min seconds harness-cache--max-manual)))))
            ((and (numberp seconds) (= seconds 0))
             (setq rec (harness-plist-remove rec :manual-until)))
            (t (setq rec (plist-put rec :active-at now))))
      (if rec
          (puthash sid rec harness-cache--presence)
        (remhash sid harness-cache--presence))
      (harness-cache--arm-end sid)
      (harness-cache--announce sid))))

(harness-defmethod cache/active (session-id &optional seconds)
  "Note that the user is active in SESSION-ID now; return their presence in it.
A client says so when the user types, or does anything in the session's
chat, as often as it likes: the user counts as around for the warm period
that follows (`cache/periods'), and a sign of life makes it longer.
With SECONDS, a positive number, the user also asks to count as around
for that long from now, a day at most -- they know they will be back,
though nothing says so yet; with 0 the period they asked for before is
taken away, which leaves the one their own signs of life made, and is no
sign of life.  The presence is (:session-id :around :until :active-at
:manual-until), see `cache/presence'; nil for a session that is gone."
  (harness-cache--note session-id (cond ((numberp seconds) seconds)
                                        ((and (stringp seconds) (string-match-p "\\`[0-9.]+\\'" seconds))
                                         (string-to-number seconds)))))

(harness-defmethod cache/presence (session-id)
  "Return when the user stops counting as around in SESSION-ID, or nil.
The presence is (:session-id SID :around t :until TIME :active-at TIME
:manual-until TIME): `:until' is the end of the warm period after their
last sign of life (`cache/active') or of the one they asked for,
whichever is later, `:active-at' the time of that sign of life and
`:manual-until' the end of the period they asked for, if there is one.
Nil when the user never was around or no longer is."
  (harness-cache--presence-of session-id))

(defun harness-cache--on-message (blocks session-id opts)
  "Note a message the user sends to SESSION-ID; return BLOCKS as they are.
On the `agent/message' filter.  OPTS is its (:from :steering :queued):
a message another session or the harness sends, or one the queue sends
out, is no sign of life."
  (when (and (not (plist-get opts :from)) (not (plist-get opts :queued)))
    (condition-case err
        (harness-cache--note session-id)
      (error (harness-log 'warn "cache: noting a message in %s failed: %s"
                          session-id (harness-error-short-message err)))))
  blocks)

(defun harness-cache--on-answered (session-id &rest _)
  "Note the answer to a question of SESSION-ID: the user is there."
  (harness-cache--note session-id))

;;;; What is watched

(defvar harness-cache--watched (make-hash-table :test 'equal)
  "Session id -> (:expires TIME :fire TIME :lead SECONDS :timer TIMER).
The moment the session's cache lapses, and the timer set for the event
that comes ahead of it.")

(defvar harness-cache--fired (make-hash-table :test 'equal)
  "Session id -> the `:expires' of the cache the last event was emitted for.
So that one moment of lapse is announced once, whatever else happens to
the session before it.")

(defvar harness-cache--claims (make-hash-table :test 'equal)
  "Session id -> (:expires TIME :by SYMBOL): who acts on the lapse at `:expires'.")

(defvar harness-cache--health (make-hash-table :test 'equal)
  "Session id -> (:streak N :wasted N :alerted-at TIME :ratio R).
The misses since the last good read or alert, the tokens they sent
again, and when the session last alerted.")

(defun harness-cache--lapsing (session)
  "Return SESSION's `:cache' when it is one that lapses by itself, else nil.
SESSION is a session plist.  A cache a redaction dropped, one held for a
model the session no longer uses, and a session without one have
nothing to lapse: they are cold already."
  (let* ((cache (plist-get session :cache))
         (expires (plist-get cache :expires)))
    (and (numberp expires)
         (not (numberp (plist-get cache :dropped)))
         (let ((cached (plist-get cache :model)) (model (plist-get session :model)))
           (or (not (stringp cached)) (not (stringp model)) (equal cached model)))
         cache)))

(defun harness-cache--cancel (sid)
  "Take the timer of session SID away, if it has one."
  (when-let* ((entry (gethash sid harness-cache--watched)))
    (when (timerp (plist-get entry :timer))
      (cancel-timer (plist-get entry :timer)))
    (remhash sid harness-cache--watched)))

(defun harness-cache--schedule (sid session)
  "Set the timer of session SID, a plist SESSION, from its cache as it is.
The timer stays when it is set for the moment already; it goes when the
cache will not lapse by itself, has lapsed, lapses within
`harness-cache--too-late' seconds, or was announced already."
  (let* ((cache (harness-cache--lapsing session))
         (expires (plist-get cache :expires))
         (now (float-time))
         (entry (gethash sid harness-cache--watched)))
    (cond
     ((or (null cache)
          (<= expires (+ now harness-cache--too-late))
          (eql expires (gethash sid harness-cache--fired)))
      (harness-cache--cancel sid))
     ((and entry (eql (plist-get entry :expires) expires)
           (memq (plist-get entry :timer) timer-list))
      nil)
     (t
      (harness-cache--cancel sid)
      (let* ((lead (harness-cache-lead (plist-get cache :ttl)))
             (fire (max now (- expires lead))))
        (puthash sid (list :expires expires :fire fire :lead lead
                           :timer (run-at-time (- fire now) nil #'harness-cache--fire sid expires))
                 harness-cache--watched))))))

(defun harness-cache--info (session cache lead)
  "Return the INFO of `cache/pre-expire' for SESSION, a plist, and its CACHE.
LEAD is the lead the event came with."
  (let ((status (plist-get session :status)))
    (list :expires (plist-get cache :expires) :ttl (plist-get cache :ttl) :lead lead
          :at (plist-get cache :at) :model (plist-get cache :model)
          :context (plist-get (plist-get session :usage) :context)
          :status status
          :running (and (memq (if (stringp status) (intern status) status) '(running blocked)) t))))

(defun harness-cache--fire (sid expires)
  "Emit `cache/pre-expire' for session SID, whose cache lapses at EXPIRES.
Nothing comes of it when the session is gone, its cache is not the one
the timer was set for, or too little time is left to act on it."
  (when-let* ((entry (gethash sid harness-cache--watched)))
    (when (eql (plist-get entry :expires) expires)
      (remhash sid harness-cache--watched)))
  (when (harness-call 'session/exists-p sid)
    (let* ((session (harness-call 'session/get sid))
           (cache (harness-cache--lapsing session)))
      (when (and cache (eql (plist-get cache :expires) expires)
                 (> expires (+ (float-time) harness-cache--too-late))
                 (not (eql expires (gethash sid harness-cache--fired))))
        (puthash sid expires harness-cache--fired)
        (harness-emit 'cache/pre-expire sid
                      (harness-cache--info session cache (harness-cache-lead (plist-get cache :ttl))))))))

(defun harness-cache--on-changed (sid session)
  "Set the timer of session SID, a plist SESSION, again: it changed.
On `session/changed'."
  (harness-cache--schedule sid session))

(defun harness-cache--on-deleted (sid &rest _)
  "Forget session SID, which is gone.  On `session/deleted'."
  (harness-cache--cancel sid)
  (remhash sid harness-cache--fired)
  (remhash sid harness-cache--claims)
  (remhash sid harness-cache--health)
  (when-let* ((timer (gethash sid harness-cache--ends)))
    (cancel-timer timer))
  (remhash sid harness-cache--ends)
  (remhash sid harness-cache--presence)
  (when (gethash sid harness-cache--announced)
    (remhash sid harness-cache--announced)
    (harness-emit 'cache/presence-changed sid nil)))

;;;; Cache health

;; A cache that does not serve the next request costs the whole prompt
;; again, at the uncached rate or worse (a write, on a provider that
;; charges for one), and an agent loop makes that cost every step.  The
;; session says after each request how much of the last prompt came from
;; the cache (`cache/reuse'); these settings decide when that is a
;; problem worth telling the user about.  The measure is the share of the
;; *previous* prompt, so a working cache reads 1.0 however much new
;; content the request added.

(defcustom harness-cache-health-threshold 0.99
  "Share of the previous prompt a request should read from the cache.
A request that reads less is a cache miss: the rest of the last prompt
was sent again and paid for at the uncached rate.  The share is of the
previous prompt, not of the current one, so a cache that serves the
whole reusable prefix reads 1.0 even when the request added a tool
result.  A provider caches in blocks (128 tokens on OpenAI's routes,
1024 on Amazon Bedrock's Anthropic models), and the last, partial one
is not served: on a prompt just over the minimum the share reads a
little low, and a provider whose blocks are large wants the minimum
raised.  See `harness-cache-health-streak' for how many misses alert."
  :type 'number :group 'harness)

(defcustom harness-cache-health-min-context 20000
  "Fewest tokens of previous prompt for which a miss is worth an alert.
A small prompt costs little to send again, and a provider caches only
above a minimum length; below this a miss is neither surprising nor
expensive."
  :type 'integer :group 'harness)

(defcustom harness-cache-health-streak 2
  "Consecutive misses before the cache health alert comes.
One miss can be a provider routing a request to another machine; a
streak is a cache that is not serving the conversation.  0 alerts on
the first miss of each episode, the cooldown still holding between
them."
  :type 'integer :group 'harness)

(defcustom harness-cache-health-cooldown 300
  "Seconds before a session that alerted can alert again.
A session whose cache keeps missing says so once in this long, however
many requests it makes meanwhile."
  :type 'integer :group 'harness)

(defcustom harness-cache-health-action 'alert
  "What a cache health alert does beyond telling the user.
`alert' adds a hint to the transcript, sends a notification when one
can be sent, logs a warning and emits `cache/poor-hit'.  `stop' does
that too and cancels the running turn, so the session does not go on
paying for a cache that does not work.  See
`harness-cache-health-threshold' for what counts as a miss."
  :type '(choice (const :tag "Alert" alert)
                 (const :tag "Stop the turn" stop))
  :group 'harness)

(defun harness-cache--alert (sid info)
  "Tell the user that SESSION-ID's prompt cache is missing, about INFO.
INFO is the `cache/reuse' plist with `:streak' and `:wasted' added.  The
alert is a hint in the transcript, a notification when the notifications
module is loaded, a warning in the log, and `cache/poor-hit'.  With
`harness-cache-health-action' `stop', the running turn is cancelled too."
  (let* ((session (ignore-errors (harness-call 'session/get sid)))
         (name (or (and session (plist-get session :name)) "Session"))
         (streak (plist-get info :streak))
         (wasted (plist-get info :wasted))
         (ratio (plist-get info :ratio))
         (summary (format "%d calls · %s tokens re-sent"
                          streak (harness-format-tokens-compact wasted)))
         (hint (format "Prompt cache miss · %d%% cached · %s"
                       (round (* 100 (or ratio 0))) summary)))
    (when session
      (harness-call 'session/hint sid hint)
      (when (harness-method-exists-p 'notification/send)
        (harness-catch
         (harness-call-async 'notification/send
                             (list :title "Prompt cache miss"
                                   :body (format "%s · %s" name summary)
                                   :urgency 'normal
                                   :source "cache" :kind "cache-health"
                                   :session sid :project (plist-get session :project)))
         (lambda (err) (harness-log 'warn "cache: notifying failed: %s"
                                    (harness-error-message err)))))
      (harness-log 'warn "cache: %s read %d%% of its previous prompt; %s over %d calls"
                   sid (round (* 100 (or ratio 0)))
                   (harness-format-tokens wasted) streak)
      (harness-emit 'cache/poor-hit sid info)
      (when (eq harness-cache-health-action 'stop)
        (when (harness-method-exists-p 'agent/cancel)
          (harness-call 'agent/cancel sid)))))
  info)

(defun harness-cache--on-reuse (sid info)
  "Watch the reuse of SESSION-ID's prompt cache from INFO, a `cache/reuse'.
A request that reads its share (`harness-cache-health-threshold') clears
the streak.  A miss counts, and when `harness-cache-health-streak' of
them have come and the cooldown has passed, `harness-cache--alert' tells
the user.  Nothing is said of a prompt under
`harness-cache-health-min-context', of an internal session, or of an
event without a ratio.  On `cache/reuse'."
  (let* ((ratio (plist-get info :ratio))
         (previous (plist-get info :previous))
         (session (ignore-errors (harness-call 'session/get sid)))
         (kind (and session (plist-get session :kind))))
    (when (and session
               (not (eq (if (stringp kind) (intern kind) kind) 'internal))
               (numberp ratio)
               (numberp previous)
               (>= previous harness-cache-health-min-context))
      (if (>= ratio harness-cache-health-threshold)
          (remhash sid harness-cache--health)
        (let* ((old (gethash sid harness-cache--health))
               (streak (1+ (or (plist-get old :streak) 0)))
               (wasted (+ (or (plist-get old :wasted) 0) (or (plist-get info :wasted) 0)))
               (now (float-time))
               (last (plist-get old :alerted-at)))
          (if (and (>= streak harness-cache-health-streak)
                   (or (not (numberp last))
                       (>= (- now last) harness-cache-health-cooldown)))
              (progn
                (harness-cache--alert sid (plist-put (plist-put (copy-sequence info)
                                                                :streak streak)
                                                     :wasted wasted))
                ;; Start a new episode: the next alert reports its own misses,
                ;; and the cooldown holds until then.
                (puthash sid (list :streak 0 :wasted 0 :alerted-at now :ratio ratio)
                         harness-cache--health))
            (puthash sid (list :streak streak :wasted wasted :alerted-at last :ratio ratio)
                     harness-cache--health)))))))

;;;; Claiming a lapse

(defun harness-cache--current-expires (sid)
  "Return when session SID's cache lapses, or nil."
  (and (harness-call 'session/exists-p sid)
       (plist-get (harness-cache--lapsing (harness-call 'session/get sid)) :expires)))

(harness-defmethod cache/claim (session-id by)
  "Claim the lapse of SESSION-ID's cache for BY, a symbol; non-nil if it is yours.
A handler of `cache/pre-expire' that acts on the cache -- reads it
again, compacts what is in it -- claims the session for the moment the
cache lapses, so that the handlers after it, which would act on the same
cache, find it taken (`cache/claimed').  The first claim wins; the same
BY claiming again still holds it.  The claim ends with the moment: a
request that reads the cache moves it.  Nil when the session has no
cache that lapses, or another holds the claim."
  (when-let* ((expires (harness-cache--current-expires session-id)))
    (let ((claim (gethash session-id harness-cache--claims)))
      (cond ((or (null claim) (not (eql (plist-get claim :expires) expires)))
             (puthash session-id (list :expires expires :by by) harness-cache--claims)
             t)
            ((eq (plist-get claim :by) by) t)))))

(harness-defmethod cache/claimed (session-id)
  "Return who holds the claim on the lapse of SESSION-ID's cache, or nil.
See `cache/claim'."
  (when-let* ((claim (gethash session-id harness-cache--claims))
              (expires (harness-cache--current-expires session-id)))
    (and (eql (plist-get claim :expires) expires) (plist-get claim :by))))

(harness-defmethod cache/watching (session-id)
  "Return when the event about SESSION-ID's cache is due, or nil.
The answer is (:fire-at TIME :expires TIME :lead SECONDS): when
`cache/pre-expire' comes, when the cache lapses and how long before it
the event comes.  Nil when no event is awaited: the session has no cache
that lapses, or the event came already."
  (when-let* ((entry (gethash session-id harness-cache--watched)))
    (list :fire-at (plist-get entry :fire) :expires (plist-get entry :expires)
          :lead (plist-get entry :lead))))

;;;; Module

(defun harness-cache--shutdown ()
  "Take every timer away."
  (dolist (sid (hash-table-keys harness-cache--watched))
    (harness-cache--cancel sid))
  (dolist (sid (hash-table-keys harness-cache--ends))
    (when-let* ((timer (gethash sid harness-cache--ends)))
      (cancel-timer timer))
    (remhash sid harness-cache--ends))
  (clrhash harness-cache--health))

(defun harness-cache--init ()
  "Watch the sessions' caches: subscribe, and set the timers of those that exist.
Set again at a reload, which leaves a timer set for the moment as it is."
  (harness-on 'session/changed #'harness-cache--on-changed)
  (harness-on 'session/deleted #'harness-cache--on-deleted)
  (harness-on 'question/answered #'harness-cache--on-answered)
  (harness-on 'cache/reuse #'harness-cache--on-reuse)
  (harness-add-filter 'agent/message #'harness-cache--on-message 90)
  (when (harness-method-exists-p 'session/list)
    (dolist (session (harness-call 'session/list))
      (harness-cache--schedule (plist-get session :id) session))))

(harness-declare-event 'cache/presence-changed "(SESSION-ID PRESENCE) when the user starts or stops counting as around in a session, or the end of the period they count as around for moves: PRESENCE is as `cache/presence' returns it, nil once they are not.")

(harness-declare-event 'cache/pre-expire "(SESSION-ID INFO) a few seconds before the prompt cache of the session lapses, while the context is still hot in it: INFO is (:expires TIME :ttl SECONDS :lead SECONDS :at TIME :model MODEL :context TOKENS :status STATUS :running BOOL).  Once for each moment a cache lapses.")

(harness-declare-event 'cache/reuse "(SESSION-ID INFO) after a request that follows another on the same model, saying how much of the last prompt it read from the cache: INFO is (:ratio F :previous TOKENS :cache-read TOKENS :wasted TOKENS :context TOKENS :model MODEL :at TIME).  The first request of a session, one after a compaction or a model switch, a hosted loop's and one with no cache stamp say nothing.")

(harness-declare-event 'cache/poor-hit "(SESSION-ID INFO) when a session's prompt cache misses again and again: INFO is a `cache/reuse' with :streak, the misses it took, and :wasted, the tokens they sent again, added.  See `harness-cache-health-threshold'.")

(harness-define-module 'cache
  :doc "Watches the sessions' prompt caches: says when one is about to lapse (cache/pre-expire), whether the user is around, and alerts when a request reads too little of the last prompt (cache/poor-hit)."
  :requires '(session)
  :init #'harness-cache--init
  :shutdown #'harness-cache--shutdown)

(provide 'harness-cache)
;;; harness-cache.el ends here
