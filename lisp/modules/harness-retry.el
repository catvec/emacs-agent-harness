;;; harness-retry.el --- Try a failed step again when the network hiccuped  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; A model call that fails because a connection was reset, a gateway
;; answered 502, or the provider asked the caller to slow down (HTTP 429
;; with a Retry-After) is worth trying again: the next try often answers.
;; The HTTP layer already retries a request whose failure nothing reached
;; the caller from (`harness-http-request'), so what arrives here is a
;; failure that got further: a stream cut in the middle of the answer, or
;; a transport failure that outlived those tries.
;;
;; A step is a safe unit to repeat, because the agent drops the partial
;; answer a failed step had already streamed before it runs the step
;; again (`harness-agent--rewind-step'): neither the transcript nor the
;; model is sent the same tokens twice.  What a step's tools already did
;; stays, and the model goes on from there.
;;
;; Quota and billing failures belong to the fallback module, which moves
;; the session to another provider; this module never answers for them
;; and never overrides an answer the filters before it gave.  A retry is
;; bounded per turn (`harness-retry-max-attempts') and waits longer each
;; time, so a provider that is really down ends the turn rather than
;; keeping it busy.
;;
;; A provider that knows names its failure's kind in `:error-kind'
;; (`transport', `rate-limit', `permanent', see
;; `harness-provider-openai'); a transport failure that arrives as text
;; alone (a CLI provider's, say) is read the same way by
;; `harness-retry-failure-kind'.  So is a CLI provider's process killed
;; mid-turn (out of memory, say): the next try starts it again.  The kind
;; `permanent' is a rejection a provider decoded from its own fields as
;; one an identical request cannot pass: it ends the turn here, at once,
;; before any handler after this one can retry it.
;;
;; The harness's own one-off calls -- a session's name, the permission
;; judge, a recap, a summary (see harness-small.el) -- are no step of a
;; turn, so `agent/step-error' never sees them; they take the same
;; treatment from the same code, to which `harness-small' adds nothing
;; but the request itself: `harness-retry-kind' says whether their
;; failure is worth another try, and `harness-retry-wait-plan' how long
;; to wait.  One place decides for both what a provider's bad minute looks
;; like and how long the harness waits it out.
;;
;; A provider that keeps its own retry bounds keeps none: it says what
;; its requests need (`harness-retry-policy-functions') and this module
;; decides how they are repeated.  OpenRouter, whose policy pins one
;; endpoint per session and refuses a request whose price, privacy or
;; pin no longer checks out, is one: it authorises and counts every send
;; itself, so its policy says `:count-sends' and this module counts what
;; goes on the wire, measures one request from its first send against
;; `harness-retry-max-seconds', and keeps the transport from replaying a
;; request that provider never authorised.  All the numbers are here:
;; `harness-retry-max-attempts', `harness-retry-delay',
;; `harness-retry-max-delay', `harness-retry-jitter' and
;; `harness-retry-max-seconds', so one setting decides every provider.
;;
;; What one request has spent is the request's, not the session's: a
;; turn's step and a recap of the same session are two requests, and
;; neither may consume or reset the other's budget.  The state travels
;; on the request and comes back in its `done' event
;; (`harness-retry--request'), and a provider may record in it what
;; authorised the send (`harness-retry-authorise').  That record is
;; opaque here: the module that wrote it is the only one that can say
;; what it still allows (`harness-retry-authority-of'), so a repeat is a
;; repeat of that request even when the session has moved on or another
;; request of it is in flight.
;;
;; A wait is drawn once and the value drawn is the value waited
;; (`harness-retry-wait-plan'): a jittered backoff that is checked as one
;; delay and spent as another could be admitted under a bound and then
;; sleep past it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defcustom harness-retry-max-attempts 3
  "Most times one turn tries a transiently failed step again.
Counted per turn, so a turn that keeps failing ends however many steps
it ran.  Nil or 0 never tries again.  For a provider that authorises
and counts its own sends (`harness-retry-policy-functions') it is also
the most times one request may be sent: the first attempt and the tries
after it."
  :type 'integer :group 'harness)

(defcustom harness-retry-delay 1.0
  "Seconds to wait before trying a failed step again.
Each further retry waits twice as long, up to
`harness-retry-max-delay'."
  :type 'number :group 'harness)

(defcustom harness-retry-max-delay 30.0
  "Longest a step is waited for before it is tried again, in seconds.
It caps both the growing backoff and a provider's Retry-After: waiting
longer than this inside a turn is worse than ending it and leaving the
next message to try."
  :type 'number :group 'harness)

(defcustom harness-retry-jitter 0.2
  "Fraction of the backoff a retry may be spread by, for randomness.
Several sessions failing together (a provider that went down, say) then
do not all try again in the same instant.  Nil or 0 waits the backoff
exactly."
  :type 'number :group 'harness)

(defcustom harness-retry-max-seconds nil
  "Longest one request and its retries may take, in seconds; nil for no bound.
It is measured from the request's first send, so an attempt's own
duration counts, and a retry is scheduled only when its wait would start
the next attempt inside what is left: a wait longer than that stops the
request at once, with the reason, rather than sleeping first and finding
the bound past at the next send.  Only a provider whose policy counts
its sends (`harness-retry-policy-functions') has a clock here, so an
ordinary provider's requests are not measured."
  :type '(choice (const :tag "No bound" nil) (number :tag "Seconds"))
  :group 'harness)

(defconst harness-retry-transient-kinds '(transport rate-limit process)
  "Kinds of failure a repeat may get past.
`transport' is a connection that failed, `rate-limit' a provider asking
the caller to slow down, and `process' a CLI provider's own process
killed mid-turn.  Quota and billing failures are the fallback module's,
and `permanent' is a rejection no identical request passes
\(`harness-retry--rejection').")

(defconst harness-retry--transport-patterns
  (concat "connection reset\\|recv failure\\|send failure\\|empty reply\\|broken pipe"
          "\\|connection refused\\|could not connect\\|connection timed out\\|timed out"
          "\\|could not resolve\\|name or service not known\\|temporary failure in name resolution"
          "\\|ssl connect error\\|tls\\|eof occurred\\|network is unreachable\\|transport"
          "\\|no response headers")
  "Regexps that say a failure was the transport's, not the request's.")

(defconst harness-retry--rate-limit-patterns
  "rate[ _-]limit\\|too many requests\\|slow down\\|retry after"
  "Regexps that say a provider asked the caller to slow down.")

(defconst harness-retry--process-death-patterns
  "exited with status \\(?:6\\|9\\|11\\|13\\|15\\|134\\|137\\|139\\|141\\|143\\)\\(?:[^0-9]\\|\\'\\)"
  "Regexps that say a provider's own process died of a signal mid-turn.
A CLI provider (Claude Code) killed by the system -- out of memory, say
-- or crashing ends its step with that exit status: the next try starts
the process again, and the conversation goes on where it left off.  An
exit the program chose, status 1 with a message, is no such failure.")

(defvar harness-retry--attempts (make-hash-table :test 'equal)
  "Session id -> how many times its running turn tried a step again.
Reset when a turn starts and when it ends.")

;;;; What a provider's requests need

(defvar harness-retry-policy-functions nil
  "Functions that say how a session's requests are retried.
Each is called with a session plist, as the agent has it, and returns a
policy plist or nil; the first non-nil answer is the session's.  A
policy says what the session's requests need, never how a failure is
read or how long to wait -- those stay in this module:

  :owner        a few words naming who retries them, for the hints and
                stop reasons a retry leaves (\"OpenRouter\", say), so
                what a person reads says whose request was repeated.
  :count-sends  t when the owner authorises and counts every send
                itself.  This module then counts what goes on the wire
                (`harness-retry-send'), measures one request from its
                first send against `harness-retry-max-seconds', and
                keeps the transport from replaying a request the owner
                did not authorise (`harness-retry-transport-retries').

Neither is a number of attempts or a delay: those are
`harness-retry-max-attempts', `harness-retry-delay',
`harness-retry-max-delay', `harness-retry-jitter' and
`harness-retry-max-seconds', so one setting decides every provider.  A
provider that answers this hook does not answer `agent/step-error'
itself: its failures are read here like any other provider's, and a
retry of one is a send like any other, which the provider checks again.")

(defconst harness-retry-policy-keys '(:owner :count-sends)
  "The keys a retry policy may name that change how a request is counted.")

(defun harness-retry-policy (session)
  "Return how SESSION's requests are retried, or nil for the defaults.
The first non-nil answer of `harness-retry-policy-functions' is it.  A
session no function answers for is an ordinary provider's: it is
retried per turn and waited for here, its transport keeps its own
replays, and no clock measures its requests."
  (when (listp session)
    (run-hook-with-args-until-success 'harness-retry-policy-functions session)))

(defun harness-retry-owner (session)
  "Return a few words naming who retries SESSION's requests, or nil.
Nil is an ordinary provider's, whose hints say nothing about an owner."
  (let ((owner (plist-get (harness-retry-policy session) :owner)))
    (and (stringp owner) (not (string-empty-p owner)) owner)))

(defun harness-retry-counted-p (session)
  "Non-nil when SESSION's provider authorises and counts every send."
  (harness-json-true-p (plist-get (harness-retry-policy session) :count-sends)))

(defun harness-retry-transport-retries (request)
  "Return how many times the transport may replay REQUEST on its own, or nil.
Nil is no answer: the transport keeps its own count, which is what an
ordinary provider gets.  0 is the answer for a request whose provider
authorises and counts every send itself (`harness-retry-counted-p'): a
replay decided inside one transport call would be a request that
provider never checked -- sent after a policy it no longer re-read, at a
price, a pin or a privacy setting it did not revalidate -- so it gets
none, and the provider's own count is the only ceiling on what goes on
the wire."
  (let ((session (plist-get request :session)))
    (when (harness-retry-counted-p session) 0)))

;;;; One request, one budget: what travels with a request
;;
;; A budget keyed by session was the wrong owner.  A session can have a
;; step in flight and a recap in flight beside it (a name, a permission
;; verdict, a compaction summary -- all of them `harness-small-ask'), and
;; each is a request of its own: the one that started first must not have
;; its count consumed by the other, and a retry the other one decided
;; must not be taken for the first one's.  The budget therefore belongs
;; to the request, and travels with it.
;;
;; What travels is `harness-retry--request': the sends one request has
;; made, when its first one started, whether the send about to be made
;; repeats a failure, and -- once a provider has authorised it -- the
;; authority that check produced.  A request carries it under
;; `harness-retry--request-key', the provider hands it back in the
;; request's `done' event (`harness-retry--carry'), and a caller that
;; sends the request again returns it on the new request.  A fresh
;; request starts no state at all, and no state is kept by session: two
;; requests of one session cannot read, consume or reset each other's.
;;
;; The authority is opaque here (a provider's own plist).  This module
;; only carries it and hands it back (`harness-retry-authority-of'), and
;; the provider that wrote it decides what it still permits -- the
;; record names the policy and the endpoint the send was checked
;; against, never a policy read later.

(cl-defstruct (harness-retry--request (:copier nil))
  "What one logical request and its retries have done, and by what right."
  (count 0)        ; sends authorised so far, the one in flight included
  (since nil)      ; when its first send started, against `harness-retry-max-seconds'
  (retrying nil)   ; the next send repeats this request, not a new one
  (authority nil)) ; the provider's own record of what authorised its last send

(defconst harness-retry--request-key :harness-retry-request
  "Key under which the state of a logical request travels on it.
A request and the `done' event of its attempt both carry it, so a layer
above a provider can see what authorised the attempt that failed and how
much of its budget it spent.")

(defun harness-retry-state-of (thing)
  "Return the `harness-retry--request' THING carries, or nil.
THING is a request or the `done' event's keys, and both are plists: a
request carries none until its first send, and one is never read from
another request that happens to be nested inside it."
  (when (listp thing)
    (let ((state (plist-get thing harness-retry--request-key)))
      (and (harness-retry--request-p state) state))))

(defun harness-retry-attach (request state)
  "Return REQUEST carrying STATE, the state of the request it repeats.
A copy is returned: a caller's list is not changed, and a caller that
holds a request keeps the one it made.  A request that is not a plist is
returned as it is."
  (if (listp request)
      (plist-put (copy-sequence request) harness-retry--request-key state)
    request))

(defun harness-retry--carry (event request)
  "Return EVENT, a provider's, carrying the state REQUEST was sent with.
The `done' event is how a failure brings back what authorised the
request it came from, so a layer above the provider can ask whether a
repeat of it is still allowed and how much of its budget is spent.
Nothing is added when the request carried no state -- an ordinary
provider's events are unchanged -- and no other event is touched."
  (if (and (listp event) (eq (plist-get event :type) 'done)
           (harness-retry-state-of request))
      (plist-put (copy-sequence event) harness-retry--request-key
                 (harness-retry-state-of request))
    event))

(defun harness-retry-elapsed (state)
  "Return how many seconds STATE's request has taken, or nil.
Nil when no send was counted for it: nothing measured it, so no clock
bounds it."
  (when (and (harness-retry--request-p state)
             (harness-retry--request-since state))
    (- (float-time) (harness-retry--request-since state))))

(defun harness-retry-send (request)
  "Take REQUEST's next send from the budget of the request it belongs to.
Return (:refusal REFUSAL :request REQUEST): REFUSAL is (REASON . DETAIL)
when the request may not be sent any more, and nil after counting the
send that is about to be made; REQUEST is returned carrying the state
the send was counted in.  A provider whose policy counts its sends
(`harness-retry-counted-p') calls this immediately before each attempt,
after it has checked everything else.

The budget is the one REQUEST carries when it repeats a failure
(`:retrying'); otherwise it is a new request's, so a step after a
successful one is not charged to the previous request's sends or clock.
The elapsed time is measured from the request's first send, so the
duration of the attempt that failed is already in it.  One request may
make the first attempt and `harness-retry-max-attempts' more, and take at
most `harness-retry-max-seconds' from its first send; a send past either
is refused here and not counted.  Both bounds are read now, so a setting
lowered while a retry waited refuses that retry here.

A session no policy counts sends nothing here: its budget is not this
module's (`harness-retry-counted-p')."
  (let* ((session (plist-get request :session))
         (policy (harness-retry-policy session))
         (state (harness-retry-state-of request)))
    (if (not (harness-json-true-p (plist-get policy :count-sends)))
        (list :refusal nil :request request)
      ;; A carried state is the request in hand; one that was not carried
      ;; as a retry starts a budget of its own, so a fresh request is
      ;; never charged to another one that shares its session.
      (unless (and state (harness-retry--request-retrying state))
        (setq state (make-harness-retry--request)))
      (setf (harness-retry--request-retrying state) nil)
      (unless (harness-retry--request-since state)
        (setf (harness-retry--request-since state) (float-time)))
      (let ((refusal (harness-retry--send-refusal state policy)))
        (unless refusal
          (cl-incf (harness-retry--request-count state)))
        (list :refusal refusal
              :request (harness-retry-attach request state))))))

(defun harness-retry--send-refusal (state policy)
  "Return (REASON . DETAIL) when STATE's request may not send another attempt.
The most attempts is the first and `harness-retry-max-attempts' more;
the elapsed time is measured from the request's first send, so the
duration of the attempt that failed is already in it.  POLICY is what
names the owner in the reason.  Both bounds are read now, so a setting
lowered while a retry waited refuses that retry here."
  (let* ((owner (or (plist-get policy :owner) "the provider"))
         (most (max 0 (or harness-retry-max-attempts 0)))
         (allowed (1+ most))
         (count (harness-retry--request-count state))
         (seconds harness-retry-max-seconds)
         (elapsed (harness-retry-elapsed state)))
    (cond
     ((>= count allowed)
      (cons 'retry-budget
            (format "%s: one request may make %d send%s, and %d %s made"
                    owner allowed (if (= allowed 1) "" "s")
                    count (if (= count 1) "was" "were"))))
     ((and (numberp seconds) (numberp elapsed) (>= elapsed seconds))
      (cons 'retry-budget
            (format "%s: one request and its retries may take %s s, and %d s passed"
                    owner (harness-retry-span seconds) (round elapsed)))))))

(defun harness-retry-authority-of (thing)
  "Return what authorised the request THING carries, or nil.
THING is a request or the `done' event's keys of its attempt.  The value
is whatever the provider that sent it recorded, an opaque plist: only
that provider knows what it means and what it still allows."
  (let ((state (harness-retry-state-of thing)))
    (and state (harness-retry--request-authority state))))

(defun harness-retry-authorise (request authority)
  "Record AUTHORITY, a provider's own plist, in REQUEST's state.
Return REQUEST as it must then be sent (`harness-retry-attach'), so the
record travels with the send it describes and comes back with its
`done' event.  A request of a session whose sends are not counted keeps
no state, and is returned unchanged."
  (let ((state (harness-retry-state-of request)))
    (if state
        (progn (setf (harness-retry--request-authority state) authority)
               (harness-retry-attach request state))
      request)))

;;;; Reading a failure, and waiting for it

(defun harness-retry-transient-p (text)
  "Non-nil when TEXT says the failure was a transient one.
TEXT is read in lower case; a failure a provider named with
`:error-kind' never needs this."
  (and (stringp text)
       (let ((text (downcase text)))
         (or (string-match-p harness-retry--transport-patterns text)
             (string-match-p harness-retry--rate-limit-patterns text)))))

(defun harness-retry-failure-kind (failure)
  "Return the kind of FAILURE, or nil.
FAILURE is what `agent/step-error' passes, or the `done' event of one
of the harness's own one-off calls (`harness-small-ask'): both carry the
provider's `:error-kind', `:error' and `:retry-after' the same way.  A
kind a provider named is used as it is: `transport', `rate-limit',
`process' and `permanent' are this module's, anything else (a quota, a
refused login) is another module's.  Without a kind, the error's text is
read for a connection that failed, a limit that was hit, or a provider
process that died of a signal (`harness-retry--process-death-patterns')."
  (let ((kind (let ((k (plist-get failure :error-kind)))
                (and k (intern (format "%s" k)))))
        (text (plist-get failure :error)))
    (or kind
        (cond ((and (stringp text) (string-match-p harness-retry--rate-limit-patterns
                                                   (downcase text)))
               'rate-limit)
              ((harness-retry-transient-p text) 'transport)
              ((and (stringp text) (string-match-p harness-retry--process-death-patterns text))
               'process)))))

(defun harness-retry-kind (failure)
  "Return the kind of FAILURE worth trying again, or nil.
A `permanent' rejection is not worth one: see
`harness-retry--rejection'."
  (let ((kind (harness-retry-failure-kind failure)))
    (and (memq kind harness-retry-transient-kinds) kind)))

(defun harness-retry-backoff (attempt failure)
  "Seconds to wait before ATTEMPT tries a step or call that FAILURE failed.
A provider that asked to slow down (Retry-After, in the FAILURE's
`:retry-after') is waited for first, capped at `harness-retry-max-delay';
otherwise the wait doubles per try, spread by `harness-retry-jitter'.
This is the one draw: a caller checks and waits the value it returns
\(`harness-retry-wait-plan'), so drawing it again would be drawing a
different wait."
  (let* ((base (* harness-retry-delay (expt 2 (1- (max 1 attempt)))))
         (jitter (* base (or harness-retry-jitter 0) (/ (random 1000) 1000.0)))
         (asked (plist-get failure :retry-after)))
    (min harness-retry-max-delay
         (max (if (numberp asked) (max 0.0 asked) 0.0)
              (+ base jitter)))))

(defun harness-retry-wait-plan (attempt failure &optional elapsed)
  "Return the wait before ATTEMPT tries FAILURE's request again.
The value is a plist: `:delay', the seconds to wait, and `:fit', non-nil
when that wait starts the next attempt inside what is left of
`harness-retry-max-seconds' after ELAPSED seconds.  The delay is
`harness-retry-backoff''s and is drawn once here: the very value `:fit'
was decided for is the one a caller waits, so a jittered backoff cannot
pass the bound as one wait and be taken as a longer one.  With no bound,
or with no ELAPSED to measure (a provider that does not count its
sends), `:fit' is always non-nil."
  (let ((delay (harness-retry-backoff attempt failure)))
    (list :delay delay
          :fit (or (not (numberp harness-retry-max-seconds))
                   (not (numberp elapsed))
                   (< (+ elapsed delay) harness-retry-max-seconds)))))

(defun harness-retry-time-spent (session elapsed)
  "Return the (REASON . DETAIL) that stops SESSION's request with ELAPSED spent.
Nil when the bound is not passed, or when there is none."
  (when (and (numberp harness-retry-max-seconds) (numberp elapsed)
             (>= elapsed harness-retry-max-seconds))
    (cons 'retry-budget
          (format "%s: one request and its retries may take %s s, and %d s passed"
                  (or (harness-retry-owner session) "the provider")
                  (harness-retry-span harness-retry-max-seconds)
                  (round elapsed)))))

(defun harness-retry-span (seconds)
  "Return SECONDS as a short span for a reason: \"1\", \"1.5\"."
  (if (integerp seconds) (number-to-string seconds) (format "%s" seconds)))

(defun harness-retry-time-refusal (session delay elapsed)
  "Return the (REASON . DETAIL) that stops SESSION's request for DELAY at ELAPSED."
  (cons 'retry-budget
        (format "%s: a %s wait would start the next attempt after the %s s one request and its retries may take%s"
                (or (harness-retry-owner session) "the provider")
                (harness-retry-duration delay)
                (harness-retry-span harness-retry-max-seconds)
                (if (numberp elapsed) (format " (%d s already passed)" (round elapsed)) ""))))

(defun harness-retry-wait (seconds)
  "Return a promise that settles after SECONDS."
  (harness-with-promise (resolve reject)
    (run-at-time seconds nil (lambda () (funcall resolve t)))))

(defun harness-retry-say (kind failure)
  "Return what a hint says about FAILURE of KIND."
  (format "%s: %s"
          (pcase kind
            ('rate-limit "rate limited")
            ('process "the provider's process died")
            (_ "network error"))
          (harness-error-short-message (or (plist-get failure :error) "unknown"))))

(defun harness-retry-duration (seconds)
  "Return SECONDS as a short span, for a hint."
  (if (< seconds 1)
      (format "%.1f s" seconds)
    (format "%d s" (round seconds))))

;;;; What follows a failure

(defun harness-retry--hint (session-id text)
  "Leave TEXT as a hint on SESSION-ID, when it still exists."
  (when (and (harness-method-exists-p 'session/hint)
             (or (not (harness-method-exists-p 'session/exists-p))
                 (ignore-errors (harness-call 'session/exists-p session-id))))
    (ignore-errors (harness-call 'session/hint session-id text))))

(defun harness-retry--stop (session reason)
  "Return a decision that stops SESSION's turn with REASON, and leave it as a hint.
`:final' ends the filter chain here, so no handler after this one --
whatever its priority -- can turn this stop into a retry."
  (harness-retry--hint (plist-get session :id) reason)
  (list :retry nil :stop t :final t :reason reason))

(defun harness-retry--rejection (session failure)
  "Return the decision that ends SESSION's turn for FAILURE's rejection.
A provider that decoded a failure as `permanent' has said an identical
request cannot pass it: repeating it would only spend again, so the
turn stops here, `:final' for the filters after this one."
  (harness-retry--stop
   session
   (format "%s: an identical retry cannot pass it: %s"
           (or (harness-retry-owner session) "the provider")
           (harness-error-short-message (or (plist-get failure :error) "unknown")))))

(defun harness-retry--attempts-made (session request failure)
  "Return how many tries of the request in hand have been made.
A provider that counts its sends counts them itself, at the send, so the
count REQUEST and its FAILURE carry is read (`harness-retry-state-of');
an ordinary provider's is this module's per-turn tally in SESSION.  One
count decides the bound, so a counted request cannot be tried once more
than it was sent, and two requests of one session never share it."
  (if (harness-retry-counted-p session)
      (let ((state (or (harness-retry-state-of failure)
                       (harness-retry-state-of request))))
        (if state (harness-retry--request-count state) 0))
    (1+ (gethash (plist-get session :id) harness-retry--attempts 0))))

(defun harness-retry--request-elapsed (session request failure)
  "Return how many seconds the request in hand has taken, or nil.
A counted request's clock is the one it carries; an ordinary provider's
is not measured, which is what nil says."
  (when (harness-retry-counted-p session)
    (harness-retry-elapsed (or (harness-retry-state-of failure)
                               (harness-retry-state-of request)))))

(defun harness-retry-attempt-plan (session failure kind attempt elapsed
                                           &optional request most)
  "Return what the shared bounds say about trying FAILURE's request again.
SESSION is the session as it failed, FAILURE the `done' event's keys,
KIND what its failure is (`harness-retry-kind'), ATTEMPT how many tries
of the request have been made (the one that failed included), ELAPSED
how many seconds it and its retries have taken (nil when nothing
measured them), REQUEST the request that failed when the caller holds
it, and MOST the most times it may be tried again, when the caller sets
its own bound (`harness-retry-max-attempts' by default).  The value is a
plist:

  `:retry'    non-nil when the request may be tried again
  `:delay'    the wait before that try, drawn once
  `:reason'   a few words on why, when it may not
  `:final'    non-nil when the stop is not another handler's to reverse
  `:state'    the state of the request, which the next attempt continues
  `:request'  REQUEST carrying that state

This is the one place the bounds are read, for a step of a turn and for
one of the harness's own one-off calls alike: the attempts one request
may make (`harness-retry-max-attempts'), the seconds it and its retries
may take (`harness-retry-max-seconds'), and the wait the failure asks
for, which is drawn once and validated as the value it returns.  A retry
marks the request's own state `retrying', so the send that follows
continues that request's count and clock instead of starting a new one."
  (let* ((session-id (plist-get session :id))
         (most (max 0 (or most harness-retry-max-attempts 0)))
         (owner (harness-retry-owner session))
         (state (or (harness-retry-state-of failure)
                    (harness-retry-state-of request)))
         (plan (and (<= attempt most)
                    (harness-retry-wait-plan attempt failure elapsed))))
    (cond
     ((> attempt most)
      (harness-retry--hint
       session-id
       (if (zerop most)
           (format "%s; not trying again (`harness-retry-max-attempts' is 0)"
                   (harness-retry-say kind failure))
         (format "%s; giving up after %d %s"
                 (harness-retry-say kind failure) most
                 (if (= most 1) "try" "tries"))))
      (list :retry nil :state state :request request))
     ((harness-retry-time-spent session elapsed)
      (let ((reason (cdr (harness-retry-time-spent session elapsed))))
        (harness-retry--hint session-id reason)
        (list :retry nil :stop t :final t :reason reason :state state :request request)))
     ((not (plist-get plan :fit))
      (let ((reason (cdr (harness-retry-time-refusal
                          session (plist-get plan :delay) elapsed))))
        (harness-retry--hint session-id reason)
        (list :retry nil :stop t :final t :reason reason :state state :request request)))
     (t
      (let ((delay (plist-get plan :delay)))
        ;; A provider that does not count its sends keeps this module's
        ;; per-turn tally; one that counts them reads its own request's
        ;; count, and is never charged to a turn's tally as well.
        (unless (harness-retry-counted-p session)
          (puthash session-id attempt harness-retry--attempts))
        ;; The next send is this request's retry: it continues the budget
        ;; the failure came back with, never a fresh one.
        (when state
          (setf (harness-retry--request-retrying state) t))
        (harness-retry--hint session-id
                             (format "%s%s; trying again in %s (%d of %d)"
                                     (if owner (concat owner ": ") "")
                                     (harness-retry-say kind failure)
                                     (harness-retry-duration delay) attempt most))
        (list :retry t :delay delay :reason "a transient failure" :state state
              :request (if state
                           (harness-retry-attach (or request '()) state)
                         request)))))))

(defun harness-retry-request-attempts (session request failure &optional fallback)
  "Return how many tries of the request in hand have been made.
A provider that counts its sends counts them itself, at the send, so the
count REQUEST and its FAILURE carry is read (`harness-retry-state-of');
an ordinary provider's is FALLBACK, or this module's per-turn tally in
SESSION, which is what a step of a turn uses."
  (if (harness-retry-counted-p session)
      (let ((state (or (harness-retry-state-of failure)
                       (harness-retry-state-of request))))
        (if state (harness-retry--request-count state) 0))
    (if fallback
        fallback
      (1+ (gethash (plist-get session :id) harness-retry--attempts 0)))))

(defun harness-retry-request-elapsed (session request failure)
  "Return how many seconds the request in hand has taken, or nil.
A counted request's clock is the one it carries; an ordinary provider's
is not measured, which is what nil says."
  (when (harness-retry-counted-p session)
    (harness-retry-elapsed (or (harness-retry-state-of failure)
                               (harness-retry-state-of request)))))

(defun harness-retry--step-error (value next session failure)
  "`agent/step-error' handler: try a transiently failed step again.
VALUE and NEXT are the filter's, SESSION the session as it failed, and
FAILURE what `agent/step-error' passes.  When no filter before this
answered, a `permanent' failure of a
provider's -- one an identical request cannot pass -- ends the turn at
once, and a failure of KIND `transport', `rate-limit' or `process' has
the step run again after a wait, at most `harness-retry-max-attempts'
times a turn.  Each wait is announced as a hint, and so is giving up, so
a turn that ends says what it tried.  A failure another handler already
answered (the fallback having moved the session on) is left alone.

The step that follows a retry is the same logical request, so the state
the failure came back with (`harness-retry-state-of') goes with the
decision as `:request': the agent sends the next step with it, and the
attempt and the clock continue rather than starting again."
  (let ((decision value))
    (unless (plist-get value :retry)
      (condition-case err
          (let ((kind (harness-retry-failure-kind failure)))
            (cond
             ((eq kind 'permanent)
              (setq decision (harness-retry--rejection session failure)))
             ((memq kind harness-retry-transient-kinds)
              (setq decision
                    (harness-retry-attempt-plan
                     session failure kind
                     (harness-retry-request-attempts session nil failure)
                     (harness-retry-request-elapsed session nil failure))))))
        (error (harness-log 'warn "retry: after the failure of %s: %S"
                            (plist-get session :id) err))))
    (if-let* ((delay (plist-get decision :delay)))
        (harness-then (harness-retry-wait delay) (lambda (_) (funcall next decision)))
      (funcall next decision)))
  nil)

(defun harness-retry--forget (session-id &rest _)
  "Forget how many times SESSION-ID's turn tried a step again.
The per-turn tally is all this module keeps for a session: a request's
own budget travels with the request, and ends with it."
  (remhash session-id harness-retry--attempts))

;;;; Module

(defun harness-retry--init ()
  "Count retries per turn and hook into the turn's failures."
  (harness-on 'agent/turn-started #'harness-retry--forget)
  (harness-on 'agent/turn-ended #'harness-retry--forget)
  (harness-add-filter 'agent/step-error #'harness-retry--step-error 60))

(defun harness-retry--shutdown ()
  "Forget what the retries counted."
  (harness-off (cons 'agent/turn-started #'harness-retry--forget))
  (harness-off (cons 'agent/turn-ended #'harness-retry--forget))
  (harness-remove-filter 'agent/step-error #'harness-retry--step-error)
  (clrhash harness-retry--attempts))

(harness-define-module 'retry
  :doc "Try a step again after a transient network or rate-limit failure, within the bounds one place sets."
  :requires '(session agent)
  :init #'harness-retry--init
  :shutdown #'harness-retry--shutdown)

(provide 'harness-retry)
;;; harness-retry.el ends here
