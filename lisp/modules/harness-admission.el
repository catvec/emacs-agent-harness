;;; harness-admission.el --- One provider account's work, let in a piece at a time  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; A rate limit is a fact about a provider account, not about one
;; request.  When DeepInfra answered 429 to a turn's step, the harness
;; had other work in flight against the same account -- another
;; session's step, a recap, a permission verdict, a cache warmer -- and
;; each of those sent its own request, met the same limit, waited its
;; own time and tried again on its own clock.  Nothing knew how much
;; work the harness had in flight against one account, so a provider
;; that had asked everybody to slow down got a fresh burst from every
;; direction a second later, and the 429s outlived the provider's bad
;; minute.
;;
;; This module is the one place that knows.  It sits above every
;; provider transport, at `provider/complete' -- the funnel every
;; request of the harness passes through, a turn's step, the retry of
;; one, a one-off call (`harness-small-ask') and a cache warmer alike --
;; and keeps a pool per provider account.  A pool has work in flight and
;; work waiting; when the provider says it is rate limiting, the pool
;; stops letting work in until the provider says it is ready, and the
;; work waits there instead of being sent and refused.
;;
;; What a pool waits for is the provider's own answer.  A Retry-After,
;; in seconds or as an HTTP-date, is waited out exactly as it asks:
;; sending sooner would only be refused again, so it is never shortened
;; to fit a bound of ours.  A rate limit that names no wait rests the
;; pool for a growing, jittered backoff that is bounded, because that
;; wait is the harness's guess and not the provider's word.  Nothing is
;; sent early in either case.
;;
;; Coming out of a rest, work goes back a piece at a time
;; (`harness-admission-release-spacing'), not as the burst that caused
;; the limit, and in the order that matters: a turn before a one-off
;; call, a one-off call before a cache warmer, first come first served
;; within each.  A warmer exists to save money later; it must never make
;; a person wait.
;;
;; Pools are independent.  A rate limit on one account says nothing
;; about another -- a different provider, another account of the same
;; one, or another upstream endpoint under it
;; (`provider/admission-identity') -- and a pool that is open lets its
;; work in at once, with no queue and no delay, so an ordinary provider
;; behaves exactly as it did before this module existed.
;;
;; A provider that knows who really served a request says so: the method
;; `provider/admission-identity' answers with the account a limit would
;; be about and the pool inside it.  For OpenRouter the account is
;; OpenRouter itself and the pool is the upstream endpoint the session
;; is pinned to, so DeepInfra's bad minute is not Cohere's.  What is
;; demonstrably the account's rather than one endpoint's is said in the
;; failure itself (`:limit-scope' `account'), and then every pool of
;; that account rests, including one made after the fact.  No key, token
;; or other credential is ever part of an identity: an identity is a
;; name the provider publishes, not a secret.
;;
;; A transport that replays a request on its own -- `harness-http' does,
;; for a connection lost before anything reached the caller -- asks the
;; same pool before every replay (`provider/transport-gate'), so a
;; replay made inside an admitted request cannot go into a cooldown
;; another request established meanwhile.  The first attempt is the
;; caller's, already admitted; only the replays after it are gated, so
;; nothing is counted twice and no request waits on itself.
;;
;; This is not a retry.  `harness-retry' decides whether a failed
;; request is worth sending again, how many times and how long to wait;
;; `harness-http' decides whether a transport may replay a request no
;; one saw.  This module decides only *when* a request that is about to
;; be sent may go, and it is the only place that sees every request of
;; the harness at once.  It never changes what is sent: the request
;; reaches the provider untouched, so a pinned endpoint, an approved
;; provider list, a privacy setting and a price limit are checked by the
;; provider that owns them, at the send, exactly as before.
;;
;; A request that waits can be cancelled (`:cancel' on the handle the
;; caller was given), and a request that waits longer than
;; `harness-admission-max-wait' is failed with a rate-limit the retry
;; layer and the fallback read like any other, rather than held for
;; ever.  What a pool is doing is observable: `admission/state' for a
;; client, `admission/waiting' and `admission/cooldown' on the bus, and a
;; hint on the session that waits.
;;
;; The state is the harness process's.  Every session, one-off call and
;; cache warmer of one harness server shares these pools, which is the
;; whole point: they are one account's traffic.  Two harness processes
;; keep two sets of pools, as they keep two of everything else.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)
(require 'harness-request-lifecycle)
;; A failure is read the one way the harness reads one, so that a pool
;; rests on exactly what `harness-retry' would have tried again.
(require 'harness-retry)
;; The pool of a request is the provider its model names, unless a
;; provider says otherwise.
(require 'harness-provider)

(defcustom harness-admission t
  "Whether the harness lets one provider account's work in a piece at a time.
When non-nil (the default), a request waits for its provider's pool
while that pool recovers from a rate limit, and the pool recovers on the
provider's own terms.  Nil sends every request as soon as it is made, as
the harness did before this module existed."
  :type 'boolean :group 'harness)

(defcustom harness-admission-delay 1.0
  "Seconds a provider pool rests after a rate limit that names no wait.
Each further rate limit on the same pool doubles it, up to
`harness-admission-max-delay', and it is spread by
`harness-admission-jitter'."
  :type 'number :group 'harness)

(defcustom harness-admission-max-delay 30.0
  "Longest a provider pool rests on the harness's own guess, in seconds.
It caps the growing backoff only.  A Retry-After the provider sent is
waited out as it asks, however long it is: sending sooner would only be
refused again, and a wait the provider named is its word, not a guess of
ours to shorten."
  :type 'number :group 'harness)

(defcustom harness-admission-jitter 0.2
  "Fraction of a pool's backoff it may be spread by, for randomness.
Two harness processes that meet the same rate limit then do not come
back in the same instant.  Nil or 0 rests exactly the backoff.  A
Retry-After the provider sent is never spread: it is a time, not a
guess."
  :type 'number :group 'harness)

(defcustom harness-admission-max-wait 30.0
  "Longest a request waits for its provider pool, in seconds; nil for no bound.
A request the pool cannot let in by then ends with a rate-limit failure
naming the pool and the wait still owed, which `harness-retry' and
`harness-fallback' read as they read any other rate limit, rather than
waiting for a provider that may be closed for an hour.  It is a ceiling
on one request, not a promise that a task outlives any cooldown: what
follows the failure is `harness-retry''s, whose own bounds
\(`harness-retry-max-delay', `harness-retry-max-attempts' and
`harness-retry-max-seconds') are what decide whether the turn ends."
  :type '(choice (const :tag "As long as the pool says" nil) (number :tag "Seconds"))
  :group 'harness)

(defcustom harness-admission-release-spacing 0.25
  "Seconds between requests a recovering pool lets in.
Work that waited out a rate limit goes back a piece at a time rather
than as the burst that caused the limit.  A pool that is not recovering
from one lets its work in at once, with no spacing."
  :type 'number :group 'harness)

(defcustom harness-admission-max-concurrent nil
  "Most requests one provider pool may have in flight, or nil for no bound.
A provider that refuses concurrent requests, or an account that is
small, can be held to a few.  Nil lets every request in as soon as the
pool is open, which is what a provider answering many at once wants."
  :type '(choice (const :tag "No bound" nil) (integer :tag "Requests"))
  :group 'harness)

(defvar harness-admission-pool-functions nil
  "Functions that say which pool a request belongs to.
Each is called with the request, as `provider/complete' has it, and
returns an identity -- a plist (:pool KEY :account KEY), or a string
for a key that is its own account -- or nil to leave the answer to the
next one.  The method `provider/admission-identity' is asked before
these, so a provider with its own account model answers in its own
module.  The default identity is the provider of the request's model:
every session of one provider shares it, which is what a rate limit on
that provider's account is about.  A provider that serves several
accounts, or several upstream endpoints under one account, splits them
here so that one endpoint's limit does not stop work bound for another.
An identity is never a credential: it is a name the provider publishes,
and it is written into hints and events.")

(defvar harness-admission--pools (make-hash-table :test 'equal)
  "Pool key -> the pool's state (`harness-admission--pool').")

(defvar harness-admission--accounts (make-hash-table :test 'equal)
  "Account key -> what the account itself last said (`harness-admission--account').
A limit the account announced for all of it is kept here, so a pool of
an endpoint the harness has not used yet still inherits the rest.")

(defvar harness-admission--sequence 0
  "Counts the requests that ever asked to be admitted, for first come first served.")

;;;; Pools and what they hold

(cl-defstruct (harness-admission--pool (:copier nil))
  "What one pool has in flight and what waits for it.
A pool is a slice of one account: an ordinary provider's whole account,
or one upstream endpoint of a provider that serves several.  The
account's own rests are kept beside the pools
\(`harness-admission--accounts'), because a limit the account itself
announced applies to every slice of it, including one first used
afterwards."
  key
  account           ; the account this pool is a slice of
  (busy 0)          ; requests in flight
  (queue nil)       ; entries waiting, newest first
  (until 0.0)       ; when the pool opens again; 0 when it is open
  (next 0.0)        ; when the next request of a recovering pool may go
  (streak 0)        ; rate limits in a row, for the backoff
  (resting nil)     ; a rest was established and its end is not yet seen
  (recovering nil)  ; came out of a rest with work still waiting
  (timer nil))      ; the timer that wakes the pool

(cl-defstruct (harness-admission--account (:copier nil))
  "What one provider account itself said, apart from its endpoints.
`until' is the end of a rest the account announced for all of it -- an
OpenRouter account limit rather than one upstream endpoint's -- and
`streak' counts those in a row.  A pool's rest is the later of its own
and its account's, so a pool made after the account rested inherits it."
  key
  (until 0.0)
  (streak 0))

(cl-defstruct (harness-admission--entry (:copier nil))
  "One request asking its pool to be let in."
  pool request on-event start rank sequence session-id key account
  (started nil) (released nil) (cancelled nil) (handle nil) (timer nil))

;; Keep the established entry layout: a reload may leave live entries in
;; timer and provider closures compiled against it.  Ownership is keyed by
;; their exact identity and disappears with them, not with a session ID.
(defvar harness-admission--controls (make-hash-table :test 'eq :weakness 'key)
  "Exact entry -> shared lifecycle, retained safely across reloads.")
(defvar harness-admission--delivery-errors (make-hash-table :test 'eq :weakness 'key)
  "Exact entry -> consumer exception, distinguished from producer startup failure.")

(defun harness-admission--entry-control (entry)
  "Return ENTRY's shared lifecycle, including entries retained across reload."
  (or (gethash entry harness-admission--controls)
      (puthash entry (harness-request-lifecycle-create
                      :phase (and (harness-admission--entry-released entry) 'finished))
               harness-admission--controls)))

(defun harness-admission-enabled-p ()
  "Non-nil when requests are admitted through their provider's pool."
  (and harness-admission
       (harness-module-ready-p 'admission)))

(defun harness-admission--as-identity (value)
  "Return VALUE, a hook's answer, as an identity plist (:pool KEY :account KEY).
A string is a key that is its own account.  A plist keeps the keys it
names and is completed from `:pool': a provider that knows the pool but
not the account gets an account of the pool's own, so its pools are
independent of every other provider's.  Anything else is nil, which
leaves the answer to the next function."
  (cond
   ((stringp value) (and (not (string-empty-p value))
                         (list :pool value :account value)))
   ((and (listp value) (stringp (plist-get value :pool))
         (not (string-empty-p (plist-get value :pool))))
    (let ((pool (plist-get value :pool))
          (account (plist-get value :account)))
      (list :pool pool
            :account (if (and (stringp account) (not (string-empty-p account)))
                         account pool))))
   (t nil)))

(defun harness-admission-identity (request)
  "Return the identity of the pool REQUEST belongs to, or nil for no pool.
An identity is (:pool KEY :account KEY).  The method
`provider/admission-identity' is asked first: a provider that serves
several accounts, or several upstream endpoints under one account,
knows which one a request is bound for and answers in its own module.
Then `harness-admission-pool-functions' is asked, and the last resort is
the provider of the request's model, which every session of that
provider shares -- which is what a rate limit on that provider's account
is about.  A request whose model names no provider has no identity:
nothing is known about who would serve it, so it is sent as it always
was."
  (or (and (harness-method-exists-p 'provider/admission-identity)
           (harness-admission--as-identity
            (ignore-errors (harness-call 'provider/admission-identity request))))
      (harness-admission--as-identity
       (run-hook-with-args-until-success 'harness-admission-pool-functions request))
      (let ((provider (car (harness-provider-parse-model (plist-get request :model)))))
        (and provider
             (list :pool (format "%s" provider) :account (format "%s" provider))))))

(defun harness-admission-pool (request)
  "Return the key of the pool REQUEST belongs to, or nil for no pool.
See `harness-admission-identity' for what decides it."
  (plist-get (harness-admission-identity request) :pool))

(defun harness-admission-rank (request)
  "Return how urgent REQUEST is, as a number a pool sorts by.
A turn's step is foreground, a one-off call the harness makes on its own
\(`:ephemeral') is auxiliary, and a cache warmer (`:cache-refresh') is
background.  A warmer exists to save money later and never delays a
turn; a one-off call answers a question the harness asked itself and
never delays one either."
  (cond ((harness-json-true-p (plist-get request :cache-refresh)) 2)
        ((harness-json-true-p (plist-get request :ephemeral)) 1)
        (t 0)))

(defun harness-admission--account-of (key)
  "Return the record of account KEY, making it if this is the first mention."
  (or (gethash key harness-admission--accounts)
      (puthash key (make-harness-admission--account :key key)
               harness-admission--accounts)))

(defun harness-admission--pool-of (key &optional account)
  "Return the pool KEY names, making it if this is the first request for it.
ACCOUNT, when given, is the account the pool is a slice of, and a rest
the account itself announced is inherited here: a limit that is the
account's is not evaded by an endpoint the harness had not used yet."
  (or (gethash key harness-admission--pools)
      (let* ((account (or account key))
             (record (harness-admission--account-of account))
             (pool (make-harness-admission--pool :key key :account account)))
        (setf (harness-admission--pool-until pool)
              (harness-admission--account-until record)
              (harness-admission--pool-streak pool)
              (harness-admission--account-streak record))
        (puthash key pool harness-admission--pools))))

(defun harness-admission--room-p (pool)
  "Non-nil when POOL may have one more request in flight."
  (or (null harness-admission-max-concurrent)
      (< (harness-admission--pool-busy pool) harness-admission-max-concurrent)))

(defun harness-admission--next-entry (pool)
  "Return the entry of POOL that goes first, or nil when none waits.
A turn before a one-off call, a one-off call before a warmer, first come
first served within each."
  (car (sort (copy-sequence (harness-admission--pool-queue pool))
             (lambda (a b)
               (let ((ra (harness-admission--entry-rank a))
                     (rb (harness-admission--entry-rank b)))
                 (if (= ra rb)
                     (< (harness-admission--entry-sequence a)
                        (harness-admission--entry-sequence b))
                   (< ra rb)))))))

(defun harness-admission--take (pool)
  "Take the entry of POOL that goes first out of its queue and return it."
  (when-let* ((entry (harness-admission--next-entry pool)))
    (setf (harness-admission--pool-queue pool)
          (delq entry (harness-admission--pool-queue pool)))
    entry))

;;;; Admitting a request

(defun harness-admission-admit (request start)
  "Send REQUEST through its provider's pool; return a handle with `:cancel'.
START is called with the request to send, once the pool lets it in, and
returns the provider's handle.  A request that goes in at once is
started here and its handle is the provider's.  One that waits is
started later, and the handle returned now stops it: nothing is sent
when it is cancelled, and its `:on-event' is sent a `done' with
`:stop-reason' cancelled, as a cancelled request of any provider is.

A request whose model names no provider, and every request while
`harness-admission' is off, is sent at once, untouched."
  (if (not (harness-admission-enabled-p))
      (funcall start request)
    (let* ((identity (harness-admission-identity request))
           (key (plist-get identity :pool))
           (account (plist-get identity :account))
           (entry (and key
                       (make-harness-admission--entry
                        :key key
                        :account account
                        :request request
                        :start start
                        :on-event (or (plist-get request :on-event) #'ignore)
                        :rank (harness-admission-rank request)
                        :sequence (cl-incf harness-admission--sequence)
                        :session-id (plist-get (plist-get request :session) :id)))))
      (if (null entry)
          (funcall start request)
        (let ((pool (harness-admission--pool-of key account)))
          (setf (harness-admission--entry-pool entry) pool)
          (push entry (harness-admission--pool-queue pool))
          (harness-admission--arm-patience entry)
          (harness-admission--pump pool)
          (unless (harness-admission--entry-started entry)
            (harness-retry-note-wait (harness-admission--entry-request entry))
            (harness-admission--announce-wait entry))
          (list :cancel (lambda () (harness-admission-cancel entry))
                :admission (list :pool key
                                 :account account
                                 :waiting (not (harness-admission--entry-started entry))
                                 :rank (harness-admission--entry-rank entry))))))))

(defun harness-admission-cancel (entry)
  "Cancel ENTRY and stop its producer, even after terminal delivery.
Protocol failure may have finished the caller before asking its producer to
stop.  Terminal delivery stays fenced; cancellation still reaches that producer."
  (unwind-protect
      (unless (harness-admission--entry-released entry)
        (setf (harness-admission--entry-cancelled entry) t)
        (harness-admission--event entry '(:type done :stop-reason cancelled)))
    (ignore-errors
      (harness-request-lifecycle-cancel (harness-admission--entry-control entry)))))

(defun harness-admission--arm-patience (entry)
  "Fail ENTRY if its pool has not let it in within `harness-admission-max-wait'."
  (when (numberp harness-admission-max-wait)
    (setf (harness-admission--entry-timer entry)
          (run-at-time harness-admission-max-wait nil
                       (lambda () (harness-admission--give-up entry))))))

(defun harness-admission--give-up (entry)
  "End ENTRY with a rate limit, because its pool kept it waiting too long.
The wait still owed travels with the failure as `:retry-after', which
`harness-retry' reads as it reads any rate limit -- under its own
`harness-retry-max-delay' -- so the request does not go again into a
pool that is still closed."
  (setf (harness-admission--entry-timer entry) nil)
  (unless (or (harness-admission--entry-started entry)
              (harness-admission--entry-released entry))
    (let* ((pool (harness-admission--entry-pool entry))
           (left (max 0 (- (harness-admission--pool-until pool) (float-time))))
           (reason (format "%s: rate limited; %s still owed, past the %s wait"
                           (harness-admission--entry-key entry)
                           (harness-admission--duration left)
                           (harness-admission--duration harness-admission-max-wait))))
      (unwind-protect
          (progn
            (harness-log 'warn "admission: %s" reason)
            (harness-admission--hint (harness-admission--entry-session-id entry) reason))
        (harness-admission--event
         entry (list :type 'done :stop-reason 'error :error-kind 'rate-limit
                     :retry-after left :error reason))))))

;;;; A transport replay asks the same pool
;;
;; `harness-http' replays a request of which nothing reached the caller
;; yet -- a connection reset, an empty reply, a refused host -- without
;; going back through `provider/complete'.  That replay is a send: it
;; must not go into a cooldown another request established while this
;; one was in flight.  So the request carries a gate the transport asks
;; immediately before each replay, and the gate answers from the pool
;; the request was admitted by:
;;
;;   nil              send now: the pool is open and spacing allows it
;;   (:wait SECONDS)  not yet; ask again in SECONDS
;;   (:refuse TEXT)   the pool has been closed longer than this request
;;                    may wait, so end it with a rate limit and let the
;;                    retry layer decide, rather than hold the turn
;;
;; Only a replay is gated: the first attempt is the caller's, admitted
;; by `harness-admission-admit', and counting it again here would be a
;; second admission of one send.  No promise is made and nothing waits
;; on a callback, so a gate cannot deadlock the transport.

(defun harness-admission--transport-gate (entry)
  "Return the function the transport asks before replaying ENTRY's request.
The answer is read from the pool each time it is asked, so a cooldown
another request establishes during this one is honoured.  The bound is
the same `harness-admission-max-wait' that bounds an admitted request,
measured from the moment this one was let in, and it is applied to the
wait the replay would need and not only to the time already spent: a
pool that will not open before this request may no longer wait ends it
here, with the wait still owed, rather than sleeping a replay past a
bound the rest of the request is held to."
  (let ((deadline (and (numberp harness-admission-max-wait)
                       (+ (float-time) harness-admission-max-wait))))
    (lambda ()
      (let* ((pool (harness-admission--entry-pool entry))
             (now (float-time))
             (until (and pool (harness-admission--pool-until pool)))
             (next (and pool (harness-admission--pool-next pool)))
             (left (max 0 (- (or until 0) now)))
             (gap (max 0 (- (or next 0) now))))
        (cond
         ((or (null pool)
              (not (harness-admission-enabled-p))
              (harness-admission--entry-released entry))
          nil)
         ((> left 0)
          (if (and deadline (> (+ now left) deadline))
              (list :refuse
                    (format "%s: rate limited; %s still owed, past the %s wait"
                            (harness-admission--entry-key entry)
                            (harness-admission--duration left)
                            (harness-admission--duration harness-admission-max-wait)))
            (list :wait left)))
         ((> gap 0)
          (if (and deadline (> (+ now gap) deadline))
              (list :refuse
                    (format "%s: recovering; next send in %s, past the %s wait"
                            (harness-admission--entry-key entry)
                            (harness-admission--duration gap)
                            (harness-admission--duration harness-admission-max-wait)))
            (list :wait gap)))
         (t nil))))))

;;;; Running the pool

(defun harness-admission--pump (pool &optional now)
  "Let POOL's work in as far as it may go now.
While the pool rests, nothing goes and the pool is woken when the rest
is over.  Once it is open, work goes in at once -- or, coming out of a
rest with work still waiting, a piece at a time
\(`harness-admission-release-spacing').

Every path that changes a pool comes through here -- a request
arriving, a request finishing, a cancel, the timer, a transport replay
-- so the decision to come back gradually is taken here, once, from the
pool's own state: whether a rest has ended with work still waiting, and
whether the spacing after the last piece has passed.  A timer wake is
not a privileged path; a request arriving in the instant after a rest
ends finds the same spacing the timer would have given it."
  (setq now (or now (float-time)))
  (when-let* ((timer (harness-admission--pool-timer pool)))
    (cancel-timer timer)
    (setf (harness-admission--pool-timer pool) nil))
  (cond
   ((not (harness-admission-enabled-p))
    (harness-admission--drain pool nil))
   ((< now (harness-admission--pool-until pool))
    (harness-admission--schedule pool (harness-admission--pool-until pool)))
   ((< now (harness-admission--pool-next pool))
    (harness-admission--schedule pool (harness-admission--pool-next pool)))
   (t
    ;; A rest that has ended, with work that waited it out, comes back a
    ;; piece at a time.  This is read here rather than at the timer, so
    ;; that every entry path decides it the same way.  `resting' is what
    ;; makes it the end of a rest and not any later queue: once the end
    ;; has been seen, a pool that formed a queue afterwards is open and
    ;; not recovering, and lets it in at once.
    (when (harness-admission--pool-resting pool)
      (setf (harness-admission--pool-resting pool) nil
            (harness-admission--pool-recovering pool)
            (and (harness-admission--pool-queue pool) t)))
    (harness-admission--drain pool (harness-admission--pool-recovering pool)))))

(defun harness-admission--drain (pool spaced)
  "Let POOL's waiting work in, one request at a time when SPACED.
SPACED is the pool coming out of a rest: one request goes now, the next
`harness-admission-release-spacing' later, so a queue that waited out a
rate limit does not go back as a burst."
  (let ((more t))
    (while (and more (harness-admission--pool-queue pool)
                (harness-admission--room-p pool))
      (let ((entry (harness-admission--take pool)))
        (when entry
          (harness-admission--admit-now entry)
          (when spaced
            (setq more nil)
            (when (harness-admission--pool-queue pool)
              ;; Not a new rest, just the gap before the next piece: the
              ;; pool is open, and says so, while the queue goes back.
              (setf (harness-admission--pool-next pool)
                    (+ (float-time) (max 0 harness-admission-release-spacing)))
              (harness-admission--schedule
               pool (harness-admission--pool-next pool)))))))
    (unless (harness-admission--pool-queue pool)
      (setf (harness-admission--pool-recovering pool) nil
            (harness-admission--pool-next pool) 0.0))))

(defun harness-admission--admit-now (entry)
  "Start ENTRY's request at its provider.
The request carries `:transport-gate', which a transport asks before it
replays the request on its own: a replay made inside this admitted
request is a send like any other, and must not go into a cooldown that
another request established meanwhile."
  (unless (harness-admission--entry-cancelled entry)
    (let* ((pool (harness-admission--entry-pool entry))
           (request (plist-put (plist-put (copy-sequence (harness-admission--entry-request entry))
                                          :on-event (lambda (event)
                                                      (harness-admission--event entry event)))
                               :transport-gate (harness-admission--transport-gate entry))))
      (setf (harness-admission--entry-started entry) t)
      (cl-incf (harness-admission--pool-busy pool))
      (when-let* ((timer (harness-admission--entry-timer entry)))
        (cancel-timer timer)
        (setf (harness-admission--entry-timer entry) nil))
      (condition-case err
          (let ((handle (funcall (harness-admission--entry-start entry) request)))
            (setf (harness-admission--entry-handle entry) handle)
            (when (functionp (plist-get handle :cancel))
              (harness-request-lifecycle-set-cancel
               (harness-admission--entry-control entry) (plist-get handle :cancel))))
        (error
         (when (equal err (gethash entry harness-admission--delivery-errors))
           (signal (car err) (cdr err)))
         (harness-log 'error "admission: starting a request of %s failed: %s"
                      (harness-admission--entry-key entry) (harness-error-short-message err))
         (harness-admission--event entry
                                  (list :type 'done :stop-reason 'error
                                        :error (harness-error-message err))))))))

(defun harness-admission--event (entry event)
  "Deliver EVENT once, with unconditional terminal settlement and pool release."
  (let ((control (harness-admission--entry-control entry)))
    (when (harness-request-lifecycle-open-p control)
      (if (eq (plist-get event :type) 'done)
          (harness-request-lifecycle-finish
           control
           (lambda (result)
             (unwind-protect
                 (condition-case err
                     (funcall (harness-admission--entry-on-event entry) result)
                   (error
                    (puthash entry err harness-admission--delivery-errors)
                    (signal (car err) (cdr err))))
               (harness-admission--release entry)))
           (lambda ()
             (when (and (harness-admission--entry-started entry)
                        (not (harness-admission--entry-cancelled entry))
                        (not (harness-admission--entry-released entry)))
               (harness-admission--note entry event))
             event)
           event
           (lambda (err)
             ;; Accounting is independent of the consumer's terminal outcome.
             (harness-log 'error "admission: terminal accounting failed: %s"
                          (harness-error-short-message err))
             event))
        (funcall (harness-admission--entry-on-event entry) event)))))

(defun harness-admission--release (entry)
  "Give ENTRY's place in its pool back, and let the next request in.
Doing it twice is harmless: a provider's `done' and a cancel of the same
request both release it, and only the first counts."
  (unless (harness-admission--entry-released entry)
    (setf (harness-admission--entry-released entry) t)
    (when-let* ((timer (harness-admission--entry-timer entry)))
      (cancel-timer timer)
      (setf (harness-admission--entry-timer entry) nil))
    (let ((pool (harness-admission--entry-pool entry)))
      (when (harness-admission--entry-started entry)
        (setf (harness-admission--pool-busy pool)
              (max 0 (1- (harness-admission--pool-busy pool)))))
      (setf (harness-admission--pool-queue pool)
            (delq entry (harness-admission--pool-queue pool)))
      (harness-admission--pump pool))))

;;;; What a failure says about the pool

(defun harness-admission--note (entry event)
  "Rest ENTRY's pool if EVENT says the provider is rate limiting it.
A failure of another kind -- a refusal, an account out of quota, a
connection that dropped -- is not the provider asking for less traffic,
and is left to the modules that answer for it.  A request that ended
well says the provider is serving again, which starts the backoff over.

How far a limit reaches is the failure's own statement, never a guess
made here: `:limit-scope' `account' is a limit the provider said is the
account's -- every pool of it rests, including one first used
afterwards -- and anything else is the pool's, which is one endpoint of
a provider that serves several.  Only a provider that can tell the two
apart says `account'; an ordinary provider's whole account is one pool,
so the two are the same thing there and nothing changes."
  (let ((pool (harness-admission--entry-pool entry)))
    (if (eq (plist-get event :stop-reason) 'error)
        (when (eq (harness-retry-failure-kind event) 'rate-limit)
          (harness-admission--rest pool event))
      (harness-admission--serving pool))))

(defun harness-admission--serving (pool)
  "Record that POOL's provider answered, which starts its backoff over.
A successful answer says the endpoint serves again; it says nothing
about an account-wide rest the account itself announced, so that one is
left to run out where it is kept.  The account's own streak starts over
too, so a pool of an endpoint first used after a recovered account does
not inherit a backoff from limits that are over."
  (setf (harness-admission--pool-streak pool) 0)
  (let ((record (harness-admission--account-of
                 (harness-admission--pool-account pool))))
    (setf (harness-admission--account-streak record) 0)))

(defun harness-admission--rest (pool event)
  "Stop POOL letting work in, for the wait EVENT's rate limit asks for.
A limit EVENT says is the account's (`:limit-scope' `account') rests
every pool of that account, and is kept on the account itself, so a
pool of an endpoint not yet used inherits it."
  (let* ((asked (harness-admission--retry-after event))
         (account-wide (eq (plist-get event :limit-scope) 'account))
         (streak (1+ (harness-admission--pool-streak pool)))
         (wait (if asked asked (harness-admission--backoff streak)))
         (until (+ (float-time) wait)))
    (setf (harness-admission--pool-streak pool) streak)
    ;; A rest already under way that ends later stands: a second limit
    ;; never shortens what the provider asked of the first.
    (when (> until (harness-admission--pool-until pool))
      (setf (harness-admission--pool-until pool) until))
    (setf (harness-admission--pool-resting pool) t)
    (when account-wide
      (let* ((key (harness-admission--pool-account pool))
             (record (harness-admission--account-of key)))
        (setf (harness-admission--account-streak record) streak)
        (when (> (harness-admission--pool-until pool)
                 (harness-admission--account-until record))
          (setf (harness-admission--account-until record)
                (harness-admission--pool-until pool)))))
    (harness-log 'info "admission: %s rests %s (%s%s)"
                 (harness-admission--pool-key pool)
                 (harness-admission--duration
                  (- (harness-admission--pool-until pool) (float-time)))
                 (if asked "the provider asked for it"
                   (format "backoff, %d in a row" streak))
                 (if account-wide ", the whole account" ""))
    (harness-emit 'admission/cooldown (harness-admission--pool-key pool)
                  (harness-admission--pool-until pool) (and asked t))
    (if account-wide
        (harness-admission--rest-account (harness-admission--pool-account pool)
                                         (harness-admission--pool-until pool))
      (harness-admission--pump pool))))

(defun harness-admission--rest-account (account until)
  "Make every pool of ACCOUNT rest until UNTIL, and wake them.
A pool made after this reads the account's own rest when it is made
\(`harness-admission--pool-of'), so nothing has to exist yet for the
account's limit to hold."
  (maphash
   (lambda (_key pool)
     (when (equal (harness-admission--pool-account pool) account)
       (when (> until (harness-admission--pool-until pool))
         (setf (harness-admission--pool-until pool) until))
       (harness-admission--pump pool)))
   harness-admission--pools)
  nil)

(defun harness-admission--retry-after (event)
  "Return the seconds EVENT's failure asks the pool to wait, or nil.
Both forms HTTP allows are read, a number of seconds and an HTTP-date,
and a value a provider gives as a string is read the same way.  A date
already past is 0: the provider is ready now."
  (let ((value (plist-get event :retry-after)))
    (cond ((numberp value) (max 0 value))
          ((stringp value)
           (harness-http-retry-after-seconds (list (cons "Retry-After" value))))
          (t nil))))

(defun harness-admission--backoff (streak)
  "Return the seconds a pool rests after STREAK rate limits in a row.
It doubles per limit, is spread by `harness-admission-jitter', and is
capped at `harness-admission-max-delay': it is the harness's guess, so
it is bounded, unlike a wait the provider named."
  (let* ((base (* harness-admission-delay (expt 2 (1- (max 1 streak)))))
         (jitter (* base (or harness-admission-jitter 0) (/ (random 1000) 1000.0))))
    (min harness-admission-max-delay (+ base jitter))))

;;;; Waking a pool

(defun harness-admission--schedule (pool when)
  "Wake POOL at WHEN, a float time, unless it is woken sooner."
  (when-let* ((timer (harness-admission--pool-timer pool)))
    (cancel-timer timer))
  (setf (harness-admission--pool-timer pool)
        (run-at-time (max 0 (- when (float-time))) nil
                     (lambda ()
                       (setf (harness-admission--pool-timer pool) nil)
                       (harness-admission--wake pool)))))

(defun harness-admission--wake (pool)
  "Let POOL go on after a rest or a spacing delay.
Nothing is decided here: `harness-admission--pump' reads the pool's own
state, so the timer, a request arriving and a request finishing all
come back the same way."
  (harness-admission--pump pool))

;;;; Saying what a pool is doing

(defun harness-admission--announce-wait (entry)
  "Say that ENTRY waits for its pool, when it waits out a rate limit."
  (let* ((pool (harness-admission--entry-pool entry))
         (left (- (harness-admission--pool-until pool) (float-time)))
         (queued (length (harness-admission--pool-queue pool))))
    (when (> left 0)
      (harness-admission--hint
       (harness-admission--entry-session-id entry)
       (format "%s: rate limited; waiting %s%s"
               (harness-admission--entry-key entry)
               (harness-admission--duration left)
               (if (> queued 1) (format " (%d waiting)" queued) "")))
      (harness-emit 'admission/waiting
                    (harness-admission--pool-key pool)
                    (list :session (harness-admission--entry-session-id entry)
                          :wait left :rank (harness-admission--entry-rank entry)
                          :queued queued)))))

(defun harness-admission--hint (session-id text)
  "Leave TEXT as a hint on SESSION-ID, when it still exists."
  (when (and (stringp session-id)
             (harness-method-exists-p 'session/hint)
             (or (not (harness-method-exists-p 'session/exists-p))
                 (ignore-errors (harness-call 'session/exists-p session-id))))
    (ignore-errors (harness-call 'session/hint session-id text))))

(defun harness-admission--duration (seconds)
  "Return SECONDS as a short span, for a hint: \"0.4 s\", \"8 s\"."
  (if (and (numberp seconds) (< seconds 1))
      (format "%.1f s" (max 0 seconds))
    (format "%d s" (round (or seconds 0)))))

(harness-defmethod admission/state ()
  "Return what every provider pool is doing, in key order.
Each is (:key KEY :account KEY :busy N :queued N :until FLOAT :streak N
:recovering BOOL :waiting ((:session ID :rank N :wait SECONDS) ...)).
`:account' is the account the pool is a slice of -- the whole provider
for an ordinary one, an upstream endpoint for a provider that serves
several.  `:until' is the time the pool last said it opens again -- 0
before it ever rested -- and a time in the past is a rest that is over:
the pool is open.  A client shows a session waiting on its provider from
this, without asking the pool anything."
  (let (out)
    (maphash
     (lambda (_key pool)
       (let ((now (float-time)))
         (push (list :key (harness-admission--pool-key pool)
                     :account (harness-admission--pool-account pool)
                     :busy (harness-admission--pool-busy pool)
                     :queued (length (harness-admission--pool-queue pool))
                     :until (harness-admission--pool-until pool)
                     :streak (harness-admission--pool-streak pool)
                     :recovering (and (harness-admission--pool-recovering pool) t)
                     :waiting (mapcar (lambda (entry)
                                        (list :session (harness-admission--entry-session-id entry)
                                              :rank (harness-admission--entry-rank entry)
                                              :wait (max 0 (- (harness-admission--pool-until pool)
                                                              now))))
                                      (harness-admission--pool-queue pool)))
               out)))
     harness-admission--pools)
    (sort out (lambda (a b) (string< (plist-get a :key) (plist-get b :key))))))

(defun harness-admission-reset ()
  "Cancel queued requests, isolating their callbacks from each other.
Detach old pools first: a cancellation observer may enqueue a successor,
which belongs to the new pools and must not be erased by this reset."
  (let ((pools (hash-table-values harness-admission--pools)))
    (clrhash harness-admission--pools)
    (clrhash harness-admission--accounts)
    (dolist (pool pools)
      (when-let* ((timer (harness-admission--pool-timer pool))) (cancel-timer timer))
      (setf (harness-admission--pool-timer pool) nil)
      (let ((queued (harness-admission--pool-queue pool)))
        (setf (harness-admission--pool-queue pool) nil)
        (dolist (entry queued)
          (condition-case err
              (harness-admission-cancel entry)
            (error (harness-log 'error "admission: resetting a request failed: %s"
                                (harness-error-short-message err))))))))
  nil)


;;; The funnel `provider/complete' sends through

(harness-defmethod provider/transport-gate (request)
  "Return the gate a transport asks before it replays REQUEST, or nil.
The gate is called with no arguments immediately before each replay the
transport decides on its own (`harness-http-request''s `:gate'), after
the first attempt.  It answers nil to send now, (:wait SECONDS) to ask
again in that many seconds, or (:refuse TEXT) to end the request with a
rate limit instead of sending it.  A request admitted by this module
carries the gate of the pool that admitted it; a request that was not
admitted -- the module off, no provider named -- has none, and the
transport keeps its own retries exactly as it did before."
  (when (and (harness-admission-enabled-p)
             (harness-admission-identity request))
    (let* ((identity (harness-admission-identity request))
           (entry (make-harness-admission--entry
                   :key (plist-get identity :pool)
                   :account (plist-get identity :account)
                   :request request
                   :session-id (plist-get (plist-get request :session) :id))))
      (setf (harness-admission--entry-pool entry)
            (harness-admission--pool-of (plist-get identity :pool)
                                        (plist-get identity :account)))
      (harness-admission--transport-gate entry))))

(harness-defmethod provider/admit (request start)
  "Let REQUEST in through its provider's pool, and send it with START.
`provider/complete' calls this instead of the provider itself when
`harness-admission' is on, so that every request of the harness -- a
turn's step and the retry of one, a one-off call, a cache warmer -- waits
in one queue per provider account.  A request the pool is ready for is
started here and now, and the provider's handle is returned as it is; one
that must wait gets a handle whose `:cancel' stops it before it is sent.
START is given the request and returns the provider's handle.  Nothing
about the request is changed but its `:on-event', which is wrapped so the
pool learns when the request is done."
  (harness-admission-admit request start))
;;;; Module

(harness-declare-event 'admission/waiting
                       "(POOL-KEY WAIT) when a request waits for its provider pool.
WAIT is (:session ID :wait SECONDS :rank N :queued N).")
(harness-declare-event 'admission/cooldown
                       "(POOL-KEY UNTIL ASKED) when a pool stops letting work in.
UNTIL is when it opens again, and ASKED is non-nil when the provider
named the wait (a Retry-After) rather than the harness backing off.")

(defun harness-admission--init ()
  "Start with no pool resting.
A reload initialises the module again, and must not drop the requests
that are waiting or in flight: only the first start clears the pools."
  (unless (harness-module-ready-p 'admission)
    (harness-admission-reset)))

(defun harness-admission--shutdown ()
  "Forget every pool, and end the requests that waited for one."
  (harness-admission-reset))

(harness-define-module 'admission
  :doc "Let one provider account's work in a piece at a time: a pool per provider, resting when the provider is rate limiting and recovering gradually."
  ;; `harness-retry' is required as a file, for the one reading of a
  ;; failure and nothing else: this module starts nothing of it, and a
  ;; harness that has the pool but not the retry module (a test of one,
  ;; say) still reads a 429 the same way.
  :requires '(provider)
  :init #'harness-admission--init
  :shutdown #'harness-admission--shutdown)

(provide 'harness-admission)
;;; harness-admission.el ends here
