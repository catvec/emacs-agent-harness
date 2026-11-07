;;; harness-provider-check.el --- Live provider and model checks  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A provider is imported from a plugin author, a model is chosen in the
;; catalogue, and neither is trusted to work until it has answered a real
;; request.  `harness-provider-check' (its UI, harness-ui-provider-check.el)
;; runs these checks from inside the harness, on the session's model or on
;; any model the catalogue lists.  They are opt-in: the ordinary suites use
;; fake providers and never call one of these.
;;
;; The checks are split in two, because the two failures need different
;; fixes.  The provider contract asks whether the generic provider API is
;; honoured: the catalogue has the model, events start and end exactly once,
;; usage is a number, an unsupported reasoning effort is rejected rather
;; than silently mislabelled, images and tools survive transport, and a
;; cancelled request really stops.  The model behavior suite asks whether
;; the model is good enough for the harness: does it follow an instruction,
;; choose a tool with structured arguments, and use the result it got.
;; A model that refuses to call a tool is no evidence that tool transport
;; is broken, so the contract check skips while the behavior check fails.
;;
;; Checks are incremental in both senses.  Each one reports PASS, FAIL or
;; SKIP as soon as it settles, with guidance about the feature that may need
;; to be removed or fixed, and the remaining checks keep running.  Nothing
;; stops at the first failure, and a SKIP means unverified, not supported.
;; A check that cannot run because the account is out of quota or money, is
;; rate-limited, refused its credential or cannot reach the provider is a
;; SKIP too: an exhausted plan is not a broken provider, and the report says
;; which of those it was without echoing the provider's error text.
;;
;; Every model request a check makes is recorded as an internal session
;; named after the check, and the result names its sessions, so the page
;; can open the prompt, the reply and the provider's own error: the result
;; never carries that error text, which a plugin may have filled with a key.
;;
;; A hosted loop runs the tools itself: it hands the turn a `tool-call'
;; and writes nothing more until the result passed to its `:respond'
;; arrives.  The checks answer every such call, with the receipt a check
;; asked for or a short plain result, and the transport check passes only
;; once its answer was delivered; an unanswered call would look hung until
;; the check's timeout.
;;
;; The job runs in the harness process, so it must not block the event loop:
;; every check returns a promise, and completions are driven by the
;; provider's own events.  The UI half follows the job's events over ACP
;; (`provider-check/started', `provider-check/result' and
;; `provider-check/finished').
;;
;; Checks run together where nothing joins them.  Each check owns its
;; sessions, its live handles and its cancellation; the job owns the bounds
;; -- how many checks and requests run at once, how many requests a run may
;; start, how many output tokens a request may ask for, and how long the
;; whole run may take -- and keeps the results in plan order.  Only genuine
;; dependencies keep their order: the catalogue before the checks that read
;; it, a completion before the usage it accounts, a tool turn before the
;; model checks that read it, and the phases inside a cache experiment.  A
;; cache experiment runs alone, so ordinary probes do not compete with the
;; concurrency it measures.
;;
;; The cache experiments are synthetic.  One check measures exact-prefix
;; reuse, refresh during a wait and a no-refresh control with a fresh nonce
;; per probe; the other gives each independent session its own early prefix,
;; primes every prefix in that same session, then reuses all of them
;; concurrently in two rounds with fresh never-primed controls kept apart:
;; four sessions by default and twelve in the opt-in stress run, which runs
;; the cache checks only.  No prefix or session is shared, and no probe
;; carries a user's conversation.  A hit is an observation, not a
;; guarantee; missing telemetry is unknown, not zero; one miss is not proof
;; that a provider lacks a cache; and no request waits out a provider's
;; cache lifetime.  `provider/cache-evidence' reads back the conservative
;; record those runs saved, and says when a changed provider, model,
;; configuration or request identity made it stale.  The record changes no
;; setting and starts no automatic keep-warm request.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-provider)
;; The checks' text is in the prompt registry.
(require 'harness-prompts)

(declare-function harness-agent-step-request "harness-agent" (session-id state on-event))
(declare-function harness-session-flush "harness-session" ())
(declare-function harness-session-reload-nodes "harness-session" (id))

(defgroup harness-provider-check nil
  "Live checks of a provider's contract and a model's harness skills."
  :prefix "harness-provider-check-"
  :group 'harness)

(defcustom harness-provider-check-timeout 90
  "Seconds to wait for one live request or one provider answer.
A check that waits longer is a failure of its own, and the checks after
it still run."
  :type 'number
  :group 'harness-provider-check)

(defcustom harness-provider-check-concurrency 3
  "Most live checks that run at once.
Their requests run at most at the same number, except that the
independent-prefix cache experiment may hold its whole batch in flight
(`harness-provider-check-max-concurrency' bounds that).  A check that
genuinely needs another keeps its order (see the dependencies in
`harness-provider-check--plan')."
  :type 'integer
  :group 'harness-provider-check)

(defcustom harness-provider-check-max-concurrency 12
  "Most requests one check job may have in flight at once.
It bounds the opt-in independent-prefix experiment, which asks a
provider for twelve concurrent answers at most; the number of checks
that run together stays `harness-provider-check-concurrency'."
  :type 'integer
  :group 'harness-provider-check)

(defcustom harness-provider-check-max-requests 64
  "Most live model requests one check job may start.
A job that reaches it stops issuing requests and reports the check that
needed one as SKIP: a bound on spending, not a provider failure.  It is
an upper bound for the whole run; the estimate on the page says how
many requests the selected checks can make.  The twelve-session stress
runs only the cache checks, whose bounded plan stays under this number."
  :type 'integer
  :group 'harness-provider-check)

(defcustom harness-provider-check-max-output-tokens 512
  "Most output tokens one check request may ask for.
A request that asks for more is cut to this before it is sent."
  :type 'integer
  :group 'harness-provider-check)

(defcustom harness-provider-check-total-timeout 900
  "Seconds a whole check job may run before it stops with what it has.
Each request and each check has a shorter bound of its own; this one
keeps a job whose checks wait on one another from running forever."
  :type 'number
  :group 'harness-provider-check)

(defcustom harness-provider-check-cache-sessions 4
  "Independent sessions in the ordinary independent-prefix cache experiment.
Every session has its own synthetic prefix, primed and reused by that
same session.  The experiment asks each primed prefix for itself again
serially, then reuses all of them concurrently in two rounds, and keeps
fresh never-primed controls separate.  Four keeps an ordinary paid run
cheap; 12 matches a usual desktop with twelve sessions and is the
opt-in stress mode."
  :type 'integer
  :group 'harness-provider-check)

(defcustom harness-provider-check-cache-stress-sessions 12
  "Independent sessions the opt-in cache stress run uses.
It is bounded by `harness-provider-check-max-concurrency'."
  :type 'integer
  :group 'harness-provider-check)

(defcustom harness-provider-check-cache-persistence-wait 2
  "Seconds between the cache probes that measure persistence.
The check reports reuse after this wait as measured persistence over
that interval only.  It never waits for a provider's cache lifetime and
never claims that lifetime: a TTL remains unverified, and zero means the
repeats are back to back.  At most
`harness-provider-check-cache-max-wait' seconds are ever waited."
  :type 'number
  :group 'harness-provider-check)

(defcustom harness-provider-check-cache-max-wait 60
  "Most seconds one cache persistence wait may take.
The check makes two such waits, one for the refreshed prefix and one for
its no-refresh control."
  :type 'number
  :group 'harness-provider-check)

(defcustom harness-provider-check-cache-min-samples 2
  "Fewest repeat requests that can support a cache finding.
One hit is an observation, not a guarantee; one miss is not evidence
that a provider lacks a cache."
  :type 'integer
  :group 'harness-provider-check)

(define-error 'harness-provider-check-failure "Provider check failed")

(define-error 'harness-provider-check-unavailable "Provider check could not run")

(define-error 'harness-provider-check-budget "Provider check request budget exhausted")

(defconst harness-provider-check--environment-kinds
  '(quota billing rate-limit auth transport)
  "Done-event error kinds that say a check could not run.
A plan's usage limit, an empty balance, a short rate limit, a refused
credential and an unreachable route are conditions of the account or
the network.  None is evidence about the provider contract or the
model, so a check that hits one is SKIPped rather than failed.  A
`request' kind is different: it says the body was wrong, which is the
provider's own contract to keep.")

(defconst harness-provider-check--image
  "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAS0lEQVR42u3PQQkAAAgAsetfWiP4FgYrsKZeS0BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEDgsqnc8OJg6Ln3AAAAAElFTkSuQmCC"
  "64x64 solid red PNG used to check whether a vision model accepts images.
The bytes are a complete PNG: some APIs reject a truncated image as an
unsupported format rather than a bad request.")

(cl-defstruct (harness-provider-check-run (:copier nil))
  "One check's own state while it runs.
The job is shared and read-only for the checks; this holds what belongs
to one check: the calls it recorded, the handles still live, and whether
the user cancelled it.  Two checks therefore never overwrite each
other's request or cancel state."
  job entry id sessions handles active peak cancelled)

(cl-defstruct (harness-provider-check-job (:copier nil))
  id model suite embedding-model options
  provider-id provider
  plan pending
  metadata base tool-attempt
  results completed total
  cancelled timed-out finished
  promise
  started-at
  sessions runs done order
  concurrency request-concurrency max-requests max-output-tokens
  request-count active-requests request-queue
  pumping pump-again
  timer)

(defconst harness-provider-check-suites '(provider model all)
  "Suites `harness-provider-check-start' runs.")

(defun harness-provider-check--require (condition message)
  "Signal `harness-provider-check-failure' with MESSAGE unless CONDITION."
  (unless condition
    (signal 'harness-provider-check-failure (list message))))

;;;; Requests and event validation

(defun harness-provider-check--request (model session-id user &optional system)
  "Build a minimal REQUEST for MODEL, SESSION-ID, USER and SYSTEM."
  (list :model model
        :session (list :id session-id :cwd default-directory)
        :ephemeral t
        :system (or system (harness-prompt 'provider-check-system nil model))
        :max-tokens 512
        :messages (list (list :role 'user
                              :content (list (list :type "text" :text user))))))

(defun harness-provider-check--image-request (model id prompt)
  "Return a request for MODEL and ID with PROMPT and a small red image."
  (let* ((request (harness-provider-check--request model id prompt))
         (message (car (plist-get request :messages))))
    (setf message
          (plist-put message :content
                     (append (plist-get message :content)
                             (list (list :type "image" :mime "image/png"
                                         :data harness-provider-check--image)))))
    (plist-put request :messages (list message))))

(defun harness-provider-check--kind (value)
  "Return VALUE, an error kind, as a non-keyword symbol, or nil."
  (and value (intern (string-remove-prefix ":" (format "%s" value)))))

(defun harness-provider-check--unavailable-detail (kind)
  "Return a safe explanation for a check that ended with error KIND.
The text is built from the kind alone, never from the provider's error
message, which a third-party plugin may have filled with a key.  It
says that the account or network is the reason, so a reader does not
mistake the SKIP for a verdict on the provider."
  (pcase kind
    ('quota (concat "The account's plan usage limit is reached, so this check "
                    "could not run; try again after the limit resets."))
    ('billing (concat "The account cannot be billed for this provider, so this "
                      "check could not run; check the account's balance or plan."))
    ('rate-limit (concat "The provider rate-limited this check, so it could not "
                         "run; try again shortly."))
    ('auth (concat "The provider refused the account's credential, so this check "
                   "could not run; sign in again and rerun."))
    ('transport (concat "The provider could not be reached, so this check could "
                        "not run; try again later."))
    (_ "This check could not run against this account.")))

(defun harness-provider-check--events (events &optional allow-cancel)
  "Validate the transport shape of EVENTS, allowing cancellation if ALLOW-CANCEL.
Do not assert the model's words or its choice to use tools here.  A
turn that ended because the account is out of quota or money, was
rate-limited, refused the credential or could not reach the provider
signals `harness-provider-check-unavailable', which the runner reports
as SKIP: nothing about the provider was observed."
  (harness-provider-check--require (eq (plist-get (car events) :type) 'start)
                                   "No start event")
  (harness-provider-check--require (eq (plist-get (car (last events)) :type) 'done)
                                   "Done was not the last event")
  (harness-provider-check--require
   (= 1 (cl-count 'done events :key (lambda (e) (plist-get e :type))))
   "Expected exactly one done event")
  (dolist (event events)
    (harness-provider-check--require
     (and (listp event) (symbolp (plist-get event :type)))
     "An event is not a plist with a symbol :type")
    (pcase (plist-get event :type)
      ((or 'text 'thinking)
       (harness-provider-check--require (stringp (plist-get event :delta))
                                        "A text/thinking delta is not a string"))
      ('tool-call
       (harness-provider-check--require
        (and (stringp (plist-get event :id))
             (not (string-empty-p (plist-get event :id)))
             (stringp (plist-get event :name))
             (listp (plist-get event :input))
             (or (not (plist-get event :respond))
                 (functionp (plist-get event :respond))))
        "A tool-call needs a name, id, plist input and optional respond function"))
      ('usage
       (dolist (key '(:input :output))
         (harness-provider-check--require
          (and (numberp (plist-get event key)) (>= (plist-get event key) 0))
          (format "Usage %s is not a nonnegative number" key))))
      ('done
       (harness-provider-check--require
        (memq (plist-get event :stop-reason)
              (if allow-cancel
                  '(cancelled end-turn error tool-use max-tokens)
                '(end-turn error tool-use max-tokens)))
        "Missing or unknown stop reason"))))
  ;; A turn that ran out of account or network is not a provider verdict.
  (let* ((done (car (last events)))
         (kind (and (eq (plist-get done :stop-reason) 'error)
                    (harness-provider-check--kind
                     (plist-get done :error-kind)))))
    (when (memq kind harness-provider-check--environment-kinds)
      (signal 'harness-provider-check-unavailable
              (list (harness-provider-check--unavailable-detail kind)))))
  t)

(defun harness-provider-check--finish-events (events &optional allow-tool-use allow-cancel)
  "Check EVENTS for a successful turn, optionally ALLOW-TOOL-USE or ALLOW-CANCEL."
  (harness-provider-check--events events allow-cancel)
  (let ((reason (plist-get (car (last events)) :stop-reason)))
    (harness-provider-check--require
     (or (eq reason 'end-turn)
         (and allow-tool-use (eq reason 'tool-use))
         (and allow-cancel (eq reason 'cancelled)))
     ;; Never echo error text: a third-party provider could put credentials in it.
     (format "Turn ended with %s (error text suppressed)" reason))))

(defun harness-provider-check--expect-text (events)
  "Check that EVENTS ended with an answer rather than a tool call or an error.
The failure message names the stop reason but never the provider's error
text, which a third-party plugin may have filled with a key."
  (harness-provider-check--events events)
  (let ((reason (plist-get (car (last events)) :stop-reason)))
    (harness-provider-check--require
     (eq reason 'end-turn)
     (format "Model ended with %s instead of answering" reason))))

(defun harness-provider-check--text (events)
  "Join the text deltas in EVENTS."
  (mapconcat (lambda (event)
               (if (eq (plist-get event :type) 'text)
                   (plist-get event :delta)
                 ""))
             events ""))

;;;; Running one completion without blocking

(defun harness-provider-check--close (model session-id)
  "Free what MODEL's provider keeps for SESSION-ID, ignoring a failure."
  (ignore-errors (harness-call 'provider/close model session-id)))

(defun harness-provider-check--note-session (run session)
  "Remember SESSION as one of RUN's model calls.
SESSION is the id of the internal session that recorded the call, or
nil for a call nothing recorded.  The check's result names its sessions,
so the page can open what the check asked and answered.  The job keeps
the same list by check id, for a check that reads another's evidence."
  (when (and run (stringp session) (not (string-empty-p session)))
    (unless (member session (harness-provider-check-run-sessions run))
      (setf (harness-provider-check-run-sessions run)
            (append (harness-provider-check-run-sessions run) (list session))))
    (when-let* ((job (harness-provider-check-run-job run))
                (id (harness-provider-check-run-id run))
                (table (harness-provider-check-job-sessions job)))
      (unless (member session (gethash id table))
        (puthash id (append (gethash id table) (list session)) table)))))

(defun harness-provider-check--entry-sessions (job entry)
  "Return the internal sessions of JOB's check ENTRY, in call order."
  (let ((table (and job (harness-provider-check-job-sessions job))))
    (and table (gethash (plist-get entry :id) table))))

(defun harness-provider-check--note-attempt-sessions (run attempt)
  "Remember the calls of ATTEMPT, a tool turn, as ones of RUN."
  (dolist (session (plist-get attempt :sessions))
    (harness-provider-check--note-session run session)))

(defun harness-provider-check--note-check-sessions (job run id)
  "Remember the calls of JOB's check ID as ones of RUN.
A check that reads another's evidence, such as usage accounting reading
the text completion, then opens the call that produced it."
  (let ((table (harness-provider-check-job-sessions job)))
    (dolist (session (and table (gethash id table)))
      (harness-provider-check--note-session run session))))

(defun harness-provider-check--answer-tool-call (event on-tool)
  "Answer the hosted tool call EVENT with what ON-TOOL says, so its loop goes on.
A hosted loop -- Claude Code is one -- hands the turn a `tool-call'
event whose `:respond' takes the result, and it waits for that result
before it writes anything more.  Left unanswered, the request never
ends, so the check would look hung and only its timeout would settle it.
ON-TOOL, when non-nil, is called with EVENT and returns the result plist
\(:content TEXT :is-error BOOL); without it the call is answered with a
short plain result.  An ON-TOOL that signals, or a `:respond' that fails,
is logged: the model must not be left waiting for an answer."
  (when-let* ((respond (plist-get event :respond)))
    (when (functionp respond)
      (let ((result (condition-case err
                        (if on-tool
                            (funcall on-tool event)
                          (list :content "ok"))
                      (error
                       (harness-log 'warn "provider-check: answering a tool call failed: %s"
                                    (harness-error-short-message err))
                       (list :content "The harness could not answer this call."
                             :is-error t)))))
        (condition-case err
            (funcall respond result)
          (error (harness-log 'warn "provider-check: sending a tool result failed: %s"
                              (harness-error-short-message err))))))))

;;;; Bounds on what a job may spend

(defun harness-provider-check--bounded-request (request)
  "Return REQUEST with its output made no larger than the job allows."
  (let ((max (max 1 harness-provider-check-max-output-tokens)))
    (plist-put (copy-sequence request) :max-tokens
               (min max (or (plist-get request :max-tokens) max)))))

(defun harness-provider-check--release-request (job)
  "Free one request slot of JOB and start what waited for it."
  (when (and job (> (harness-provider-check-job-active-requests job) 0))
    (cl-decf (harness-provider-check-job-active-requests job)))
  (harness-provider-check--pump-requests job))

(defun harness-provider-check--pump-requests (job)
  "Start queued requests of JOB while it has slots and is not cancelled."
  (while (and (harness-provider-check-job-request-queue job)
              (not (harness-provider-check-job-finished job))
              (not (harness-provider-check-job-cancelled job))
              (< (harness-provider-check-job-active-requests job)
                 (harness-provider-check-job-request-concurrency job)))
    (let ((item (pop (harness-provider-check-job-request-queue job))))
      (cl-incf (harness-provider-check-job-active-requests job))
      (funcall (plist-get item :start)))))

(defun harness-provider-check--queue-request (job start cancel)
  "Run START when JOB has a request slot, else queue it; CANCEL drops it.
START is called with one request slot held; it must release the slot
through `harness-provider-check--release-request'.  CANCEL settles the
request that never started when the job is cancelled."
  (cond
   ((or (harness-provider-check-job-finished job)
        (harness-provider-check-job-cancelled job))
    (funcall cancel))
   ((< (harness-provider-check-job-active-requests job)
       (harness-provider-check-job-request-concurrency job))
    (cl-incf (harness-provider-check-job-active-requests job))
    (funcall start))
   (t
    (push (list :start start :cancel cancel)
          (harness-provider-check-job-request-queue job)))))

(defun harness-provider-check--complete (run request &optional keep-open cancel-now on-tool)
  "Complete REQUEST for RUN; return a promise of (:events EVENTS :state STATE).
The promise also says `:session', the internal session that recorded the
call, when one did, `:started-at' and `:seconds'.  Close the request's
session afterwards unless KEEP-OPEN.  With CANCEL-NOW, cancel the handle
as soon as it exists, so the cancellation path is exercised.  ON-TOOL,
when non-nil, is called with each hosted `tool-call' event to produce the
result its loop waits for (see `harness-provider-check--answer-tool-call').
The request holds one of the job's request slots while it runs; every
wait is bounded by `harness-provider-check-timeout', and the job refuses
a request past `harness-provider-check-max-requests'."
  (let* ((job (harness-provider-check-run-job run))
         (request (harness-provider-check--bounded-request request))
         (model (plist-get request :model))
         (session-id (plist-get (plist-get request :session) :id))
         (entry (harness-provider-check-run-entry run))
         (events nil)
         (state nil)
         (done nil)
         (handle nil)
         (session nil)
         (started nil)
         (acquired nil)
         (settle-pending nil)
         (timer nil)
         (promise (harness-make-promise)))
    (cl-labels
        ((settle (error)
           (cond
            (done nil)
            ;; A provider may answer while `provider/complete' still runs,
            ;; before it returns the handle that names the call's session.
            ;; Settle then, once the handle is in hand.
            ((and (null error) (null handle))
             (setq settle-pending t))
            (t
             (setq done t)
             (when timer (cancel-timer timer) (setq timer nil))
             (when handle
               (setf (harness-provider-check-run-handles run)
                     (delq handle (harness-provider-check-run-handles run))))
             (when (and (harness-provider-check-run-active run)
                        (> (harness-provider-check-run-active run) 0))
               (cl-decf (harness-provider-check-run-active run)))
             (when acquired
               (setq acquired nil)
               (harness-provider-check--release-request job))
             (unless keep-open
               (harness-provider-check--close model session-id))
             (if error
                 (harness-reject promise error)
               (harness-resolve promise
                                (list :events (nreverse events)
                                      :state state
                                      :session session
                                      :started-at started
                                      :seconds (and started (- (float-time) started))))))))
         (timed-out ()
           (unless done
             (let ((cancel (plist-get handle :cancel)))
               ;; Settle first: a provider whose cancel answers at once must
               ;; not turn a timeout into a successful cancellation.
               (settle (list 'harness-provider-check-failure
                             (format "Timed out after %s seconds"
                                     harness-provider-check-timeout)))
               (when (functionp cancel) (ignore-errors (funcall cancel))))))
         (begin ()
           (setq acquired t
                 started (float-time))
           (cl-incf (harness-provider-check-job-request-count job))
           (setf (harness-provider-check-run-active run)
                 (1+ (or (harness-provider-check-run-active run) 0)))
           (setf (harness-provider-check-run-peak run)
                 (max (or (harness-provider-check-run-peak run) 0)
                      (harness-provider-check-run-active run)))
           (setq timer (run-at-time harness-provider-check-timeout nil #'timed-out))
           (condition-case err
               (setq handle
                     (harness-call
                      'provider/complete
                      (plist-put
                       (plist-put
                        (copy-sequence request)
                        :job (format "Provider check: %s"
                                     (or (and entry (plist-get entry :name))
                                         (plist-get request :model))))
                       :on-event
                       (lambda (event)
                         (push event events)
                         (when (eq (plist-get event :type) 'provider-state)
                           (setq state (plist-get event :state)))
                         (when (eq (plist-get event :type) 'tool-call)
                           (harness-provider-check--answer-tool-call event on-tool))
                         (when (eq (plist-get event :type) 'done)
                           (settle nil))))))
             (error (settle err)))
           ;; Record it before the handle's own state is looked at: a provider
           ;; that answers while `provider/complete' runs still made this call.
           (when handle
             (setq session (plist-get handle :session))
             (harness-provider-check--note-session run session)
             (push handle (harness-provider-check-run-handles run)))
           (when cancel-now
             (let ((cancel (plist-get (or handle (list :cancel nil)) :cancel)))
               (if (functionp cancel)
                   (ignore-errors (funcall cancel))
                 (settle (list 'harness-provider-check-failure
                               "Completion handle has no :cancel function")))))
           (when settle-pending
             (setq settle-pending nil)
             (settle nil)))
         (start ()
           (cond
            ((or (harness-provider-check-job-finished job)
                 (harness-provider-check-job-cancelled job))
             (settle (list 'harness-provider-check-failure "Cancelled by the user")))
            ((>= (harness-provider-check-job-request-count job)
                 (harness-provider-check-job-max-requests job))
             ;; `harness-provider-check--queue-request' gave this request a
             ;; slot before calling START; settle must give it back.
             (setq acquired t)
             (settle (list 'harness-provider-check-budget
                           (format "Request budget of %d requests exhausted"
                                   (harness-provider-check-job-max-requests job)))))
            (t (begin)))))
      (harness-provider-check--queue-request job #'start
                                             (lambda ()
                                               (settle (list 'harness-provider-check-failure
                                                             "Cancelled by the user")))))
    promise))

(defun harness-provider-check--delay (seconds)
  "Return a promise resolved after SECONDS, bounded by the cache wait."
  (let ((promise (harness-make-promise)))
    (run-at-time (max 0 (min seconds harness-provider-check-cache-max-wait))
                 nil (lambda () (harness-resolve promise t)))
    promise))

(defun harness-provider-check--in-parallel (thunks)
  "Return a promise of the results of THUNKS, all started together.
Each thunk returns a promise or a value; `harness-all' keeps their
order.  A thunk that rejects is not expected: a probe that fails
resolves its own failure so the others still report."
  (harness-all (mapcar (lambda (thunk) (harness-as-promise (funcall thunk))) thunks)))



(defun harness-provider-check--finally (promise fn)
  "Call FN after PROMISE settles, either way, and pass its outcome on."
  (harness-then promise
                (lambda (value) (funcall fn) value)
                (lambda (error) (funcall fn) (harness-rejected error))))

;;;; The checks
;;
;; Each check is a function of JOB returning a cons (STATUS . DETAIL), or a
;; promise of one.  STATUS is `pass', `fail' or `skip'.  A check that cannot
;; run because an optional feature is not advertised returns `skip': it was
;; not verified, so it says nothing for or against the provider.

(defun harness-provider-check--check-catalogue (job _run)
  "Check that the model of JOB is listed with usable metadata."
  (let* ((model (harness-provider-check-job-model job))
         (parsed (harness-provider-parse-model model))
         (pid (car parsed))
         (name (cdr parsed))
         (provider (and pid (harness-provider-get pid))))
    (harness-provider-check--require provider "Provider is not registered")
    (harness-provider-check--require (functionp (harness-provider-models-fn provider))
                                     "Provider does not list models")
    (setf (harness-provider-check-job-provider-id job) pid
          (harness-provider-check-job-provider job) provider)
    (harness-then
     (or (harness-as-promise (harness-provider-relist pid))
         (harness-resolved nil))
     (lambda (_)
       (let* ((listed (harness-call 'provider/cached-models pid))
              (metadata (harness-call 'provider/model model)))
         (harness-provider-check--require
          (cl-find name listed :key (lambda (m) (plist-get m :name)) :test #'equal)
          "Selected model absent from the refreshed provider catalogue")
         (harness-provider-check--require
          (and (equal (plist-get metadata :id) model)
               (eq (plist-get metadata :provider) pid)
               (numberp (plist-get metadata :context-window))
               (> (plist-get metadata :context-window) 0))
          "Model id, provider or context window is invalid")
         (setf (harness-provider-check-job-metadata job) metadata)
         (cons 'pass
               (if (plist-get metadata :context-window-estimated)
                   "Listed; context window is estimated (check its value)."
                 "Listed with model id and context window."))))
     (lambda (_error)
       (harness-rejected
        (list 'harness-provider-check-failure
              "Refreshing the provider catalogue failed"))))))

(defun harness-provider-check--check-completion (job run)
  "Check a plain text completion of JOB and its start/text/done lifecycle."
  (harness-then
   (harness-provider-check--complete
    run
    (harness-provider-check--request (harness-provider-check-job-model job)
                                     "provider-check-basic"
                                     (harness-prompt 'provider-check-greeting nil
                                                     (harness-provider-check-job-model job))))
   (lambda (reply)
     (let ((events (plist-get reply :events)))
       (harness-provider-check--finish-events events)
       (harness-provider-check--require
        (not (string-empty-p
              (string-trim (harness-provider-check--text events))))
        "No text deltas")
       (setf (harness-provider-check-job-base job) reply)
       '(pass . "Start, text and one successful done; no model wording asserted.")))))

(defun harness-provider-check--usage (events)
  "Return the last usage event of EVENTS, or nil."
  (car (last (cl-remove-if-not (lambda (event) (eq (plist-get event :type) 'usage))
                               events))))

(defun harness-provider-check--check-usage (job run)
  "Check that the basic completion of JOB reported nonnegative usage."
  (let ((base (harness-provider-check-job-base job)))
    (if (not base)
        '(skip . "Text completion did not return events.")
      (harness-provider-check--note-check-sessions job run "completion")
      (let* ((events (plist-get base :events))
             (usage (harness-provider-check--usage events)))
        (harness-provider-check--require usage "No usage event")
        (harness-provider-check--events events)
        '(pass . "Nonnegative input and output usage reported.")))))

(defconst harness-provider-check--cache-filler
  (mapconcat #'identity (make-list 200 "Padding for the prompt cache check.") " ")
  "Text long enough to pass a provider's minimum cacheable prompt length.
The probes carry it in the system prompt, whose prefix the provider
should cache after the first; a few kilobytes put the prompt over the
1,024-token minimum of the models that document one.")

(defconst harness-provider-check--cache-warm-max-tokens 8
  "Most tokens a synthetic keep-warm request may take.
Its answer is never read, as in `harness-cache-warm--max-tokens'.")

(defun harness-provider-check--echo-tool ()
  "Return the synthetic echo tool the tool and cache probes offer."
  (list '(:name "check_echo"
          :description "Return a receipt for value."
          :schema (:type "object"
                   :properties (:value (:type "string"))
                   :required ("value")))))

(defun harness-provider-check--cache-thinking (job)
  "Return the thinking level the cache probes of JOB use, or nil.
The first level the model advertises is the cheapest realistic setting;
a model that advertises none is probed without one."
  (let ((levels (plist-get (harness-provider-check-job-metadata job) :thinking-levels)))
    (and (listp levels) (stringp (car levels)) (car levels))))

(defun harness-provider-check--cache-system (model nonce &optional mismatch)
  "Return the synthetic system prompt for MODEL and NONCE.
The nonce is the very first thing in the prompt, so probes with
different nonces share no prefix at all and cannot warm each other.
MISMATCH adds a word right after it, which makes that probe a
deliberate identity mismatch."
  (concat (format "%s [synthetic cache probe%s]\n" nonce (if mismatch " mismatch" ""))
          (harness-prompt 'provider-check-system nil model)
          "\n\n" harness-provider-check--cache-filler))

(defun harness-provider-check--cache-request (job session system messages &optional max-tokens)
  "Return a cache probe request of JOB for SESSION, SYSTEM and MESSAGES.
The request carries the model's realistic identity: the same system
prefix, the same synthetic tool schema, the same thinking parameter and
the same message order for every request that is meant to share a
prefix.  MAX-TOKENS bounds its answer."
  (let ((model (harness-provider-check-job-model job))
        (request (harness-provider-check--request
                  (harness-provider-check-job-model job) session
                  (harness-prompt 'provider-check-greeting nil
                                  (harness-provider-check-job-model job))
                  system)))
    (setf request (plist-put request :messages messages)
          request (plist-put request :tools (harness-provider-check--echo-tool))
          request (plist-put request :max-tokens (or max-tokens 24)))
    (when-let* ((thinking (harness-provider-check--cache-thinking job)))
      (setf request (plist-put request :thinking thinking)))
    (ignore model)
    request))

(defun harness-provider-check--cache-message (text)
  "Return one user message carrying TEXT."
  (list :role 'user
        :content (list (list :type "text" :text text))))

(defun harness-provider-check--cache-spec (phase session request
                                                 &optional prefix index control)
  "Return one cache probe spec of PHASE, recorded in SESSION, for REQUEST.
PREFIX and INDEX name the synthetic prefix and its place in an
independent-prefix experiment; CONTROL marks a fresh never-primed
control.  The exact-prefix experiment leaves them nil."
  (append (list :phase phase :session-id session :request request)
          (and prefix (list :prefix prefix))
          (and index (list :index index))
          (and control (list :control t))))

(defun harness-provider-check--cache-specs (job)
  "Return the ordered probes of JOB's exact-prefix cache experiment.
Every request under test shares one synthetic prefix except where the
experiment deliberately compares against a control: a second prefix
that is not refreshed, and a mismatched prefix.  Each request names a
different provider session, so reuse can only come from the prompt
cache, not from conversation state."
  (let* ((model (harness-provider-check-job-model job))
         (nonce (format "synthetic-%s" (harness-short-id 10)))
         (control (format "control-%s" (harness-short-id 10)))
         (mismatch (format "mismatch-%s" (harness-short-id 10)))
         (system (harness-provider-check--cache-system model nonce))
         (control-system (harness-provider-check--cache-system model control))
         (mismatch-system (harness-provider-check--cache-system model mismatch t))
         (base (harness-provider-check--cache-message
                (harness-prompt 'provider-check-cache-probe (list :nonce nonce) model)))
         (control-base (harness-provider-check--cache-message
                        (harness-prompt 'provider-check-cache-probe
                                        (list :nonce control) model)))
         (mismatch-base (harness-provider-check--cache-message
                         (harness-prompt 'provider-check-cache-probe
                                         (list :nonce mismatch) model)))
         (warm (harness-provider-check--cache-message
                (harness-prompt 'cache-warm-ping nil model)))
         (resume (harness-provider-check--cache-message
                  (harness-prompt 'provider-check-cache-resume
                                  (list :nonce nonce) model)))
         (control-resume (harness-provider-check--cache-message
                          (harness-prompt 'provider-check-cache-resume
                                          (list :nonce control) model)))
         (wait (max 0 (min (or harness-provider-check-cache-persistence-wait 0)
                           harness-provider-check-cache-max-wait)))
         (session (lambda (role)
                    (format "provider-check-cache-%s-%s" nonce role))))
    (list
     (harness-provider-check--cache-spec
      'prime (funcall session "prime")
      (harness-provider-check--cache-request job (funcall session "prime") system (list base)))
     (harness-provider-check--cache-spec
      'repeat-immediate (funcall session "repeat-1")
      (harness-provider-check--cache-request job (funcall session "repeat-1") system (list base)))
     (append
      (harness-provider-check--cache-spec
       'repeat-persistence (funcall session "repeat-2")
       (harness-provider-check--cache-request job (funcall session "repeat-2") system (list base)))
      (list :delay wait))
     (harness-provider-check--cache-spec
      'warm-1 (funcall session "warm-1")
      (harness-provider-check--cache-request
       job (funcall session "warm-1") system (list base warm)
       harness-provider-check--cache-warm-max-tokens))
     (harness-provider-check--cache-spec
      'warm-2 (funcall session "warm-2")
      (harness-provider-check--cache-request
       job (funcall session "warm-2") system (list base warm)
       harness-provider-check--cache-warm-max-tokens))
     (harness-provider-check--cache-spec
      'resume (funcall session "resume")
      (harness-provider-check--cache-request job (funcall session "resume") system (list base resume)))
     (harness-provider-check--cache-spec
      'control-prime (funcall session "control-prime")
      (harness-provider-check--cache-request
       job (funcall session "control-prime") control-system (list control-base)))
     (append
      (harness-provider-check--cache-spec
       'control-resume (funcall session "control-resume")
       (harness-provider-check--cache-request
        job (funcall session "control-resume") control-system
        (list control-base control-resume)))
      (list :delay wait))
     (harness-provider-check--cache-spec
      'mismatch (funcall session "mismatch")
      (harness-provider-check--cache-request
       job (funcall session "mismatch") mismatch-system (list mismatch-base))))))

(defun harness-provider-check--safe-error-kind (error)
  "Return a symbol naming ERROR without its text.
A provider's error text is not persisted: a third-party plugin may have
put a credential in it."
  (cond ((and (consp error) (memq (car error)
                                  '(harness-provider-check-failure
                                    harness-provider-check-unavailable
                                    harness-provider-check-budget)))
         (car error))
        ((and (consp error) (symbolp (car error))) (car error))
        (t 'error)))

(defun harness-provider-check--usage-cost (job usage)
  "Return (USD . SOURCE) for USAGE of JOB's model.
SOURCE is `provider' when the answer carried a cost, `catalogue' when
the model's prices estimate it, and nil when neither gives a number."
  (cond
   ((null usage) nil)
   ((numberp (plist-get usage :cost)) (cons (plist-get usage :cost) 'provider))
   (t
    (let* ((metadata (harness-provider-check-job-metadata job))
           (rates (or (and metadata
                           (let ((fn (plist-get metadata :pricing-fn)))
                             (and (functionp fn)
                                  (condition-case nil (funcall fn metadata usage nil)
                                    (error nil)))))
                      (plist-get metadata :pricing))))
      (when (and rates
                 (numberp (plist-get rates :input))
                 (numberp (plist-get rates :output)))
        (cons (/ (+ (* (or (plist-get usage :input) 0) (plist-get rates :input))
                    (* (or (plist-get usage :output) 0) (plist-get rates :output))
                    (* (or (plist-get usage :cache-read) 0)
                       (or (plist-get rates :cache-read) (plist-get rates :input)))
                    (* (or (plist-get usage :cache-write) 0)
                       (or (plist-get rates :cache-write) 0)))
                 1000000.0)
              'catalogue))))))

(defun harness-provider-check--cache-summary (job spec reply)
  "Return the safe summary of REPLY to cache spec SPEC of JOB."
  (let* ((events (plist-get reply :events))
         (usage (harness-provider-check--usage events))
         (done (car (last events)))
         (stop (plist-get done :stop-reason))
         (kind (and (eq stop 'error)
                    (harness-provider-check--kind (plist-get done :error-kind))))
         (cost (harness-provider-check--usage-cost job usage)))
    (list :phase (plist-get spec :phase)
          :prefix (plist-get spec :prefix)
          :index (plist-get spec :index)
          :control (plist-get spec :control)
          :session-id (plist-get spec :session-id)
          :started-at (plist-get reply :started-at)
          :seconds (plist-get reply :seconds)
          :session (plist-get reply :session)
          :stop stop
          :error-kind (and (eq stop 'error) (or kind 'error))
          :usage usage
          :telemetry (and usage (if (plist-member usage :cache-read)
                                    'present
                                  'missing))
          :cache-read (and usage (plist-get usage :cache-read))
          :context (and usage (or (plist-get usage :context)
                                  (plist-get usage :input)))
          :input (and usage (plist-get usage :input))
          :output (and usage (plist-get usage :output))
          :cost (car cost)
          :cost-source (cdr cost))))

(defun harness-provider-check--cache-call-run (run spec)
  "Send cache spec SPEC for RUN; resolve its summary, even when it fails."
  (harness-then
   (harness-provider-check--complete run (plist-get spec :request))
   (lambda (reply)
     (harness-provider-check--cache-summary (harness-provider-check-run-job run)
                                            spec reply))
   (lambda (error)
     (list :phase (plist-get spec :phase)
           :prefix (plist-get spec :prefix)
           :index (plist-get spec :index)
           :control (plist-get spec :control)
           :session-id (plist-get spec :session-id)
           :error (harness-provider-check--safe-error-kind error)))))

(defun harness-provider-check--cache-sequence (run specs done)
  "Run SPECS in order for RUN, collecting summaries in DONE.
A spec may carry `:delay' seconds to wait before its request, which is
how a measured persistence point is made."
  (if (null specs)
      (harness-resolved (nreverse done))
    (let* ((spec (car specs))
           (wait (plist-get spec :delay)))
      (harness-then
       (if (and (numberp wait) (> wait 0))
           (harness-provider-check--delay wait)
         (harness-resolved nil))
       (lambda (_)
         (harness-then
          (harness-provider-check--cache-call-run run spec)
          (lambda (summary)
            (harness-provider-check--cache-sequence run (cdr specs)
                                                    (cons summary done)))))))))

(defun harness-provider-check--cache-totals (results)
  "Return token, cost and error totals of cache RESULTS."
  (let (observed estimated sources)
    (dolist (result results)
      (let ((cost (plist-get result :cost))
            (source (plist-get result :cost-source)))
        (cond ((and (numberp cost) (eq source 'provider))
               (push cost observed))
              ((numberp cost) (push cost estimated)))
        (when source (cl-pushnew source sources))))
    (list :observed-cost (and observed (apply #'+ observed))
          :estimated-cost (and estimated (apply #'+ estimated))
          :cost-source (cond ((null sources) nil)
                             ((null (cdr sources)) (car sources))
                             (t 'mixed))
          ;; The check reports recovered requests separately from cache hits.
          :errors (cl-count-if (lambda (r) (plist-get r :error)) results)
          :environment (cl-remove-duplicates
                        (delq nil (mapcar (lambda (r)
                                            (let ((kind (plist-get r :error-kind)))
                                              (and (memq kind
                                                         harness-provider-check--environment-kinds)
                                                   kind)))
                                          results))))))

(defun harness-provider-check--cache-fact (results phase)
  "Return the cache-read value of PHASE in RESULTS, or nil."
  (plist-get (cl-find phase results :key (lambda (r) (plist-get r :phase))) :cache-read))

(defun harness-provider-check--cache-hit-p (result)
  "Non-nil when RESULT reported a positive cache read."
  (let ((read (plist-get result :cache-read)))
    (and (numberp read) (> read 0))))

(defun harness-provider-check--cache-evidence (_job specs results)
  "Return the conservative evidence of JOB's cache EXPERIMENT.
SPECS is what was planned and RESULTS what came back.  Missing telemetry
is unknown, not zero; a hit is an observation, not a guarantee, and no
request measures a provider's cache lifetime."
  (let* ((usable (cl-remove-if (lambda (r) (plist-get r :error)) results))
         (repeats (cl-remove-if-not
                   (lambda (r) (memq (plist-get r :phase)
                                     '(repeat-immediate repeat-persistence)))
                   usable))
         (repeats-with-telemetry
          (cl-remove-if-not (lambda (r) (eq (plist-get r :telemetry) 'present))
                            repeats))
         (warm (cl-remove-if-not
                (lambda (r) (memq (plist-get r :phase) '(warm-1 warm-2)))
                usable))
         (resume (cl-find 'resume usable :key (lambda (r) (plist-get r :phase))))
         (control-resume (cl-find 'control-resume usable
                                  :key (lambda (r) (plist-get r :phase))))
         (mismatch (cl-find 'mismatch usable :key (lambda (r) (plist-get r :phase))))
         (control-prime (cl-find 'control-prime usable
                                 :key (lambda (r) (plist-get r :phase))))
         ;; These are first requests of their own prefixes: a cold control.
         ;; The unrefreshed control-resume is expected to read its prefix at
         ;; a short wait, so it is a baseline, not a cold control.
         (controls (delq nil (list mismatch control-prime)))
         (controls-clean
          (and controls
               (cl-every (lambda (r)
                           (and (eq (plist-get r :telemetry) 'present)
                                (zerop (or (plist-get r :cache-read) 0))))
                         controls)))
         (totals (harness-provider-check--cache-totals results))
         (persistence-spec (cl-find 'repeat-persistence specs
                                    :key (lambda (s) (plist-get s :phase))))
         (persistence-result (cl-find 'repeat-persistence usable
                                      :key (lambda (r) (plist-get r :phase))))
         (wait (or (plist-get persistence-spec :delay) 0))
         (sessions (delq nil (mapcar (lambda (r) (plist-get r :session-id))
                                     results))))
    (list :kind 'prompt-cache
          :requested (length specs)
          :actual (length results)
          :telemetry (cond ((cl-some (lambda (r) (eq (plist-get r :telemetry) 'present))
                                     usable) 'present)
                           ((cl-some (lambda (r) (eq (plist-get r :telemetry) 'missing))
                                     usable) 'missing)
                           (t 'no-usage))
          :prime (harness-provider-check--cache-fact usable 'prime)
          :context (apply #'+ (mapcar (lambda (r) (or (plist-get r :context) 0)) usable))
          :input (apply #'+ (mapcar (lambda (r) (or (plist-get r :input) 0)) usable))
          :cache-read (apply #'+ (mapcar (lambda (r) (or (plist-get r :cache-read) 0))
                                         usable))
          :output (apply #'+ (mapcar (lambda (r) (or (plist-get r :output) 0)) usable))
          :repeats (mapcar (lambda (r) (plist-get r :cache-read)) repeats)
          :repeat-samples (length repeats-with-telemetry)
          :repeat-hits (cl-count-if #'harness-provider-check--cache-hit-p
                                    repeats-with-telemetry)
          :repeat-seconds (mapcar (lambda (r) (plist-get r :seconds)) repeats)
          :control (list :prime (and control-prime
                                     (plist-get control-prime :cache-read))
                         :resume (and control-resume
                                      (plist-get control-resume :cache-read))
                         :mismatch (and mismatch (plist-get mismatch :cache-read)))
          :controls-clean (and controls-clean t)
          :keep-warm (list :refresh (mapcar (lambda (r) (plist-get r :cache-read)) warm)
                           :refresh-samples (length warm)
                           :refresh-hits (cl-count-if #'harness-provider-check--cache-hit-p warm)
                           :resume (and resume (plist-get resume :cache-read)))
          :persistence (list :wait wait
                             :sample (and persistence-result
                                          (plist-get persistence-result :cache-read)))
          :cost (list :observed (plist-get totals :observed-cost)
                      :estimated (plist-get totals :estimated-cost)
                      :source (plist-get totals :cost-source))
          :errors (plist-get totals :errors)
          :environment (plist-get totals :environment)
          :sessions sessions
          :distinct-sessions (and sessions
                                  (= (length sessions) (length (delete-dups
                                                                (copy-sequence sessions))))))))

(defun harness-provider-check--cost-label (cost)
  "Return COST, a plist, as the observed or estimated amount and its source."
  (let ((observed (plist-get cost :observed))
        (estimated (plist-get cost :estimated))
        (source (plist-get cost :source)))
    (cond
     ((and (numberp observed) (numberp estimated))
      (format "$%.4f observed · $%.4f estimated (%s)" observed estimated source))
     ((numberp observed) (format "$%.4f observed (%s)" observed source))
     ((numberp estimated) (format "$%.4f estimated (%s)" estimated source))
     (t "unknown"))))

(defun harness-provider-check--cache-detail (evidence)
  "Return a compact noun-phrase summary of cache EVIDENCE."
  (let* ((repeats (plist-get evidence :repeats))
         (hits (plist-get evidence :repeat-hits))
         (samples (plist-get evidence :repeat-samples))
         (warm (plist-get evidence :keep-warm))
         (persistence (plist-get evidence :persistence))
         (telemetry (plist-get evidence :telemetry))
         (cost (plist-get evidence :cost)))
    (format (concat "repeats %s/%s cached · keep-warm %s/%s cached · resume %s"
                    " · persistence %ss · controls %s · prompt %s · cached %s"
                    " · output %s · telemetry %s · cost %s · n=%s · TTL unverified")
            (or hits 0) (or samples 0)
            (or (plist-get warm :refresh-hits) 0) (or (plist-get warm :refresh-samples) 0)
            (if (plist-get warm :resume) "cached" "not cached")
            (or (plist-get persistence :wait) 0)
            (if (plist-get evidence :controls-clean) "cold" "ambiguous")
            (or (plist-get evidence :context) 0)
            (or (plist-get evidence :cache-read) 0)
            (or (plist-get evidence :output) 0)
            telemetry
            (harness-provider-check--cost-label cost)
            (length repeats))))

(defun harness-provider-check--check-prompt-cache (job run)
  "Measure exact-prefix reuse, keep-warm refresh and a no-refresh control.
Every probe is synthetic and nonce-isolated; the requests under test
share model, system prefix, tools and schema, thinking parameter and
message order, and each carries a different provider session.  The
check reports observations, not a cache guarantee: a single hit is not
a lifetime, a single miss is not proof that a provider lacks a cache,
and the provider's TTL remains unknown."
  (let ((specs (harness-provider-check--cache-specs job)))
    (harness-then
     (harness-provider-check--cache-sequence run specs nil)
     (lambda (results)
       (let* ((evidence (harness-provider-check--cache-evidence job specs results))
              (environment (plist-get evidence :environment))
              (telemetry (plist-get evidence :telemetry))
              (samples (plist-get evidence :repeat-samples))
              (hits (plist-get evidence :repeat-hits))
              (verdict
               (cond
                (environment
                 (cons 'skip (format "unavailable: %s"
                                     (mapconcat #'symbol-name environment ", "))))
                ((and (null (plist-get evidence :repeats))
                      (> (plist-get evidence :errors) 0))
                 '(skip . "incomplete probes; nothing observed"))
                ((not (eq telemetry 'present))
                 '(skip . "no cache telemetry; unknown, not zero"))
                ((< samples harness-provider-check-cache-min-samples)
                 (cons 'skip (format "%d/%d repeat samples"
                                     samples harness-provider-check-cache-min-samples)))
                ((not (plist-get evidence :controls-clean))
                 '(skip . "control prefix warm; isolation ambiguous"))
                ((>= hits harness-provider-check-cache-min-samples)
                 '(pass . "exact-prefix reuse observed; not a guarantee"))
                (t
                 '(skip . "repeated misses in one run; not unsupported")))))
         (list :status (car verdict)
               :detail (format "%s · %s"
                               (harness-provider-check--cache-detail evidence)
                               (cdr verdict))
               :evidence evidence
               :summary (harness-provider-check--cache-detail evidence)))))))



;;;; The independent-prefix cache experiment
;;
;; Twelve sessions on one desktop do not share a prompt prefix: each
;; has its own conversation and its own early content.  The question is
;; therefore whether every session's own prefix is cached, and whether
;; many such sessions can reuse their own prefixes at the same time
;; without mixing them up.  One shared prefix reused across sessions is
;; a different question; this experiment does not measure it, and its
;; results are not evidence here.

(defconst harness-provider-check--cache-control-prefixes 2
  "Fresh never-primed prefixes the independent-prefix experiment uses.
They are controls, not part of the reuse count: they were never primed,
so a cold read shows that the primed prefixes' hits come from their own
cached content and not from telemetry that counts every input or from a
provider that reports cached tokens for everything.  Two keep the
control cheap while still being more than one sample.")

(defun harness-provider-check--peak-concurrency (results)
  "Return the most RESULTS whose measured intervals overlapped."
  (let ((intervals
         (delq nil
               (mapcar (lambda (result)
                         (let ((start (plist-get result :started-at))
                               (seconds (plist-get result :seconds)))
                           (and (numberp start) (numberp seconds)
                                (cons start (+ start seconds)))))
                       results))))
    (let ((peak 0))
      (dolist (interval intervals peak)
        (setq peak (max peak
                        (cl-count-if
                         (lambda (other)
                           (and (<= (car other) (car interval))
                                (> (cdr other) (car interval))))
                         intervals)))))))

(defun harness-provider-check--median (numbers)
  "Return the median of NUMBERS, or nil when it is empty."
  (let ((sorted (sort (cl-remove-if-not #'numberp numbers) #'<)))
    (when sorted
      (let* ((n (length sorted))
             (middle (/ n 2)))
        (if (cl-oddp n)
            (nth middle sorted)
          (/ (+ (nth (1- middle) sorted) (nth middle sorted)) 2.0))))))

(defun harness-provider-check--independent-prefix-identity (job index control)
  "Return the synthetic prefix identity of JOB's INDEX-th independent session.
CONTROL makes a fresh, never-primed control identity.  The random tag is
the first thing in the system prompt, so two identities share no prompt
prefix at all; model, tools, thinking level and message order stay the
same, as they do for real sessions of one model.  The session id belongs
to this prefix alone and is stable through the whole experiment."
  (let* ((model (harness-provider-check-job-model job))
         (prefix (format "%s-%s-%d"
                         (harness-short-id 10)
                         (if control "control" "independent")
                         index)))
    (list :index index
          :control (and control t)
          :prefix prefix
          :session-id (format "provider-check-independent-%s" prefix)
          :system (harness-provider-check--cache-system model prefix)
          :messages (list (harness-provider-check--cache-message
                           (harness-prompt 'provider-check-cache-probe
                                           (list :nonce prefix) model))))))

(defun harness-provider-check--independent-session-specs (job sessions)
  "Return JOB's independent-prefix probe specs for SESSIONS sessions.
Each session has its own synthetic prefix and its own stable session
id.  The specs prime every prefix and ask for it again serially in that
same session, which is its per-prefix baseline; then they reuse those
same prefixes in two concurrent rounds, the second in reverse order.
The last specs are fresh, never-primed control prefixes.  No prefix and
no session id is shared between sessions."
  (let* ((identities (cl-loop for i below sessions
                              collect (harness-provider-check--independent-prefix-identity
                                       job i nil)))
         (controls (cl-loop for i below harness-provider-check--cache-control-prefixes
                            collect (harness-provider-check--independent-prefix-identity
                                     job i t)))
         (spec (lambda (phase identity)
                 (let ((session-id (plist-get identity :session-id)))
                   (harness-provider-check--cache-spec
                    phase session-id
                    (harness-provider-check--cache-request
                     job session-id
                     (plist-get identity :system)
                     (plist-get identity :messages)
                     24)
                    (plist-get identity :prefix)
                    (plist-get identity :index)
                    (plist-get identity :control)))))
         (baseline (cl-loop for identity in identities
                            append (list (funcall spec 'prime identity)
                                         (funcall spec 'baseline identity))))
         (round-1 (mapcar (lambda (identity) (funcall spec 'round-1 identity))
                          identities))
         (round-2 (mapcar (lambda (identity) (funcall spec 'round-2 identity))
                          (reverse (copy-sequence identities))))
         (control-specs (mapcar (lambda (identity) (funcall spec 'control identity))
                                controls)))
    (append baseline round-1 round-2 control-specs)))

(defun harness-provider-check--independent-identities (specs)
  "Return one identity plist per prefix in SPECS, controls included."
  (let (seen out)
    (dolist (spec specs)
      (let ((key (list (and (plist-get spec :control) t)
                       (plist-get spec :index))))
        (unless (member key seen)
          (push key seen)
          (push (list :control (and (plist-get spec :control) t)
                      :index (plist-get spec :index)
                      :prefix (plist-get spec :prefix)
                      :session-id (plist-get spec :session-id))
                out))))
    (nreverse out)))

(defun harness-provider-check--independent-result (results phase index &optional control)
  "Return the result of PHASE, INDEX and CONTROL in RESULTS, or nil."
  (cl-find-if (lambda (result)
                (and (eq (plist-get result :phase) phase)
                     (eql (plist-get result :index) index)
                     (eq (and (plist-get result :control) t)
                         (and control t))))
              results))

(defun harness-provider-check--independent-hit-p (result)
  "Non-nil when RESULT shows a positive cache read."
  (let ((read (and result (plist-get result :cache-read))))
    (and (numberp read) (> read 0))))

(defun harness-provider-check--independent-request-summary (result)
  "Return the safe per-request part of RESULT for the evidence record."
  (and result
       (list :cache-read (plist-get result :cache-read)
             :input (plist-get result :input)
             :output (plist-get result :output)
             :seconds (plist-get result :seconds)
             :started-at (plist-get result :started-at)
             :telemetry (plist-get result :telemetry)
             :error-kind (plist-get result :error-kind)
             :error (plist-get result :error))))

(defun harness-provider-check--independent-mismatch-count (identities results)
  "Return how many RESULTS do not carry the prefix identity they claim.
An independent session uses one prefix and one session id for its whole
experiment; a result that names another prefix's session, or a phase
with no identity, is mixing and makes the evidence unverified."
  (let ((mismatches 0))
    (dolist (result results)
      (let* ((control (and (plist-get result :control) t))
             (identity (cl-find-if
                        (lambda (one)
                          (and (eq (and (plist-get one :control) t) control)
                               (eql (plist-get one :index)
                                    (plist-get result :index))))
                        identities)))
        (unless (and identity
                     (equal (plist-get result :prefix)
                            (plist-get identity :prefix))
                     (equal (plist-get result :session-id)
                            (plist-get identity :session-id)))
          (cl-incf mismatches))))
    mismatches))

(defun harness-provider-check--independent-evidence (_job specs results)
  "Return the evidence of JOB's independent-prefix experiment SPECS and RESULTS.
Every prefix is reported on its own: its prime, serial baseline and both
concurrent rounds, with cached and prompt tokens, output, latency and the
same session id throughout.  Fresh controls stay apart from the prefixes
under test.  Missing telemetry, a failed or throttled request, a repeated
session or a prefix that does not match its session stays visible so the
classification can call it unverified rather than a hit or a miss."
  (let* ((identities (harness-provider-check--independent-identities specs))
         (prefixes (cl-remove-if (lambda (one) (plist-get one :control)) identities))
         (controls (cl-remove-if-not (lambda (one) (plist-get one :control)) identities))
         (usable (cl-remove-if (lambda (r) (plist-get r :error)) results))
         (control-results (cl-remove-if-not
                           (lambda (r) (eq (plist-get r :phase) 'control))
                           usable))
         (totals (harness-provider-check--cache-totals results))
         (per-prefix
          (cl-loop
           for identity in prefixes
           for i = (plist-get identity :index)
           for baseline = (harness-provider-check--independent-result results 'baseline i)
           for round-1 = (harness-provider-check--independent-result results 'round-1 i)
           for round-2 = (harness-provider-check--independent-result results 'round-2 i)
           collect (list :index i
                         :prefix (plist-get identity :prefix)
                         :session-id (plist-get identity :session-id)
                         :prime (harness-provider-check--independent-request-summary
                                 (harness-provider-check--independent-result
                                  results 'prime i))
                         :baseline (harness-provider-check--independent-request-summary
                                    baseline)
                         :round-1 (harness-provider-check--independent-request-summary
                                   round-1)
                         :round-2 (harness-provider-check--independent-request-summary
                                   round-2)
                         :baseline-hit (and (harness-provider-check--independent-hit-p
                                             baseline)
                                            t)
                         :round-1-hit (and (harness-provider-check--independent-hit-p
                                            round-1)
                                           t)
                         :round-2-hit (and (harness-provider-check--independent-hit-p
                                            round-2)
                                           t)
                         :cached (and (harness-provider-check--independent-hit-p round-1)
                                      (harness-provider-check--independent-hit-p round-2)
                                      t))))
         (control-evidence
          (cl-loop
           for identity in controls
           for i = (plist-get identity :index)
           for result = (harness-provider-check--independent-result results 'control i t)
           collect (list :index i
                         :prefix (plist-get identity :prefix)
                         :session-id (plist-get identity :session-id)
                         :cache-read (plist-get result :cache-read)
                         :input (plist-get result :input)
                         :seconds (plist-get result :seconds)
                         :error (plist-get result :error))))
         (round-1-results (cl-remove-if-not
                           (lambda (r) (eq (plist-get r :phase) 'round-1)) usable))
         (round-2-results (cl-remove-if-not
                           (lambda (r) (eq (plist-get r :phase) 'round-2)) usable))
         (round-results (append round-1-results round-2-results))
         (telemetry-results
          (append (cl-remove-if-not
                   (lambda (r) (memq (plist-get r :phase)
                                     '(baseline round-1 round-2)))
                   usable)
                  control-results))
         (telemetry
          (cond ((and telemetry-results
                      (cl-every (lambda (r) (eq (plist-get r :telemetry) 'present))
                                telemetry-results))
                 'present)
                ((cl-some (lambda (r) (eq (plist-get r :telemetry) 'present))
                          telemetry-results)
                 'partial)
                ((cl-some (lambda (r) (eq (plist-get r :telemetry) 'missing))
                          telemetry-results)
                 'missing)
                (t 'no-usage)))
         (sessions (delq nil (mapcar (lambda (one) (plist-get one :session-id))
                                     prefixes)))
         (control-sessions (delq nil (mapcar (lambda (one)
                                               (plist-get one :session-id))
                                             controls)))
         (control-hits (cl-count-if #'harness-provider-check--independent-hit-p
                                    control-results)))
    (list :kind 'independent-prefixes
          :requested-sessions (length prefixes)
          :requested (length specs)
          :actual (length results)
          :rounds 2
          :telemetry telemetry
          :prefixes per-prefix
          :controls control-evidence
          :control-samples (length control-results)
          :control-hits control-hits
          :controls-clean (and control-results
                               (zerop control-hits)
                               (eq telemetry 'present)
                               t)
          :prefix-count (length prefixes)
          :cached-count (cl-count-if (lambda (p) (plist-get p :cached)) per-prefix)
          :baseline-hits (cl-count-if (lambda (p) (plist-get p :baseline-hit))
                                      per-prefix)
          :round-1-hits (cl-count-if #'harness-provider-check--independent-hit-p
                                     round-1-results)
          :round-2-hits (cl-count-if #'harness-provider-check--independent-hit-p
                                     round-2-results)
          :peak-concurrency (harness-provider-check--peak-concurrency round-results)
          :median-seconds (harness-provider-check--median
                           (mapcar (lambda (r) (plist-get r :seconds))
                                   round-results))
          :context (apply #'+ (mapcar (lambda (r) (or (plist-get r :context) 0)) usable))
          :input (apply #'+ (mapcar (lambda (r) (or (plist-get r :input) 0)) usable))
          :cache-read (apply #'+ (mapcar (lambda (r) (or (plist-get r :cache-read) 0))
                                         usable))
          :output (apply #'+ (mapcar (lambda (r) (or (plist-get r :output) 0)) usable))
          :throttled (cl-count-if
                      (lambda (r) (eq (plist-get r :error-kind) 'rate-limit))
                      results)
          :errors (cl-count-if
                   (lambda (r) (and (plist-get r :error)
                                    (not (eq (plist-get r :error)
                                             'harness-provider-check-unavailable))))
                   results)
          :identity-mismatches (harness-provider-check--independent-mismatch-count
                                identities results)
          :sessions sessions
          :control-sessions control-sessions
          :distinct-sessions (and (or sessions control-sessions)
                                  (let ((all (append (copy-sequence sessions)
                                                     control-sessions)))
                                    (= (length all)
                                       (length (delete-dups all)))))
          :environment (plist-get totals :environment)
          :cost (list :observed (plist-get totals :observed-cost)
                      :estimated (plist-get totals :estimated-cost)
                      :source (plist-get totals :cost-source)))))

(defun harness-provider-check--independent-detail (evidence)
  "Return a compact noun-phrase summary of independent-prefix EVIDENCE."
  (let ((cost (plist-get evidence :cost))
        (count (or (plist-get evidence :prefix-count) 0)))
    (format (concat "independent prefixes %s/%s cached · baseline %s/%s"
                    " · round 1 %s/%s · round 2 %s/%s"
                    " · controls %s/%s cached · sessions %s/%s (%s distinct)"
                    " · peak %s parallel · throttled %s · errors %s · median %ss"
                    " · prompt %s · cached %s · output %s · cost %s · TTL unverified")
            (or (plist-get evidence :cached-count) 0) count
            (or (plist-get evidence :baseline-hits) 0) count
            (or (plist-get evidence :round-1-hits) 0) count
            (or (plist-get evidence :round-2-hits) 0) count
            (or (plist-get evidence :control-hits) 0)
            (or (plist-get evidence :control-samples) 0)
            (length (plist-get evidence :sessions))
            (or (plist-get evidence :requested-sessions) 0)
            (if (plist-get evidence :distinct-sessions) "all" "not all")
            (or (plist-get evidence :peak-concurrency) 0)
            (or (plist-get evidence :throttled) 0)
            (or (plist-get evidence :errors) 0)
            (or (and (plist-get evidence :median-seconds)
                     (format "%.2f" (plist-get evidence :median-seconds)))
                "?")
            (or (plist-get evidence :context) 0)
            (or (plist-get evidence :cache-read) 0)
            (or (plist-get evidence :output) 0)
            (harness-provider-check--cost-label cost))))

(defun harness-provider-check--check-independent-prefix-cache (job run)
  "Measure whether independent sessions cache their own prefixes.
Each of the job's sessions has a different synthetic prefix, different
from its first character, and its own session id.  Every prefix is primed
and asked for again serially by the same session; then all of those same
prefixes are reused concurrently by their own sessions in two rounds, the
second in reverse order.  Fresh never-primed controls are asked once,
separately.  Neither prefixes nor sessions are shared, so a hit for one
session cannot come from another session's conversation.  A shared-prefix
experiment would answer a different question and is not evidence here.
Throttling, missing telemetry, identity mixing, a warm control, a partial
batch or requests that did not overlap leave the result unverified."
  (let ((capabilities (or (plist-get (harness-provider-check-job-metadata job)
                                     :capabilities)
                          (and (harness-provider-check-job-provider job)
                               (harness-provider-capabilities
                                (harness-provider-check-job-provider job))))))
    (if (and capabilities (harness-json-true-p (plist-get capabilities :hosted-loop)))
        '(skip . "hosted conversation; synthetic prefix sessions unsupported")
      (let* ((sessions (max 2 (or (plist-get (harness-provider-check-job-options job)
                                             :cache-sessions)
                                  harness-provider-check-cache-sessions)))
             (specs (harness-provider-check--independent-session-specs job sessions))
             (serial (cl-remove-if-not
                      (lambda (spec)
                        (memq (plist-get spec :phase) '(prime baseline)))
                      specs))
             (round-1 (cl-remove-if-not
                       (lambda (spec) (eq (plist-get spec :phase) 'round-1))
                       specs))
             (round-2 (cl-remove-if-not
                       (lambda (spec) (eq (plist-get spec :phase) 'round-2))
                       specs))
             (controls (cl-remove-if-not
                        (lambda (spec) (eq (plist-get spec :phase) 'control))
                        specs))
             (call (lambda (spec)
                     (lambda ()
                       (harness-provider-check--cache-call-run run spec)))))
        (harness-then
         (harness-provider-check--cache-sequence run serial nil)
         (lambda (serial-results)
           (harness-then
            (harness-provider-check--in-parallel (mapcar call round-1))
            (lambda (round-1-results)
              (harness-then
               (harness-provider-check--in-parallel (mapcar call round-2))
               (lambda (round-2-results)
                 (harness-then
                  (harness-provider-check--in-parallel (mapcar call controls))
                  (lambda (control-results)
                    (let* ((results (append serial-results round-1-results
                                            round-2-results control-results))
                           (evidence (harness-provider-check--independent-evidence
                                      job specs results))
                           (telemetry (plist-get evidence :telemetry))
                           (environment (plist-get evidence :environment))
                           (count (plist-get evidence :prefix-count))
                           (cached (plist-get evidence :cached-count))
                           (baseline (plist-get evidence :baseline-hits))
                           (round-1-hits (plist-get evidence :round-1-hits))
                           (round-2-hits (plist-get evidence :round-2-hits))
                           (peak (or (plist-get evidence :peak-concurrency) 0))
                           (verdict
                            (cond
                             (environment
                              (cons 'skip (format "unavailable: %s"
                                                  (mapconcat #'symbol-name environment
                                                             ", "))))
                             ((> (plist-get evidence :throttled) 0)
                              (cons 'skip
                                    (format "%d of %d requests throttled; concurrency unverified"
                                            (plist-get evidence :throttled)
                                            (plist-get evidence :actual))))
                             ((> (plist-get evidence :identity-mismatches) 0)
                              '(skip . "prefix and session identity mismatched; mixing unverified"))
                             ((> (plist-get evidence :errors) 0)
                              '(skip . "some requests failed; concurrency result incomplete"))
                             ((not (plist-get evidence :distinct-sessions))
                              '(skip . "session ids repeated; independent sessions unverified"))
                             ((< count 2)
                              '(skip . "fewer than 2 independent prefixes"))
                             ((not (eq telemetry 'present))
                              '(skip . "no cache telemetry; unknown, not zero"))
                             ((> (plist-get evidence :control-hits) 0)
                              '(skip . "fresh control prefix read cached tokens; isolation ambiguous"))
                             ((< peak 2)
                              '(skip . "requests did not overlap; concurrency unverified"))
                             ((and (>= baseline count)
                                   (>= round-1-hits count)
                                   (>= round-2-hits count))
                              '(pass . "independent-prefix reuse observed; not a guarantee"))
                             ((and (> baseline 0) (zerop round-1-hits) (zerop round-2-hits))
                              '(skip . "serial baseline hit but concurrent reuse missed; unverified"))
                             ((and (< cached count) (> (+ round-1-hits round-2-hits) 0))
                              (cons 'skip
                                    (format "partial reuse: %d/%d prefixes cached in both rounds"
                                            cached count)))
                             (t
                              '(skip . "primed prefixes missed in one run; not unsupported")))))
                      (list :status (car verdict)
                            :detail (format "%s · %s"
                                            (harness-provider-check--independent-detail
                                             evidence)
                                            (cdr verdict))
                            :evidence evidence
                            :summary (harness-provider-check--independent-detail
                                      evidence)))))))))))))))
;;;; What a cache self-test observed, for later reasoning

(defconst harness-provider-check--evidence-schema 2
  "Version of the capability evidence record and its classification.
Bump it when a recorded field or a rule changes meaning, so old
evidence is not read as if it had the new one.  Version 2 replaced the
shared-prefix cross-session finding with independent-prefix reuse: each
session primes and reuses its own prefix, never a prefix common to all.")

(defconst harness-provider-check--request-identity 2
  "Version of the synthetic request identity the cache probes use.
Bump it when the probe's system prefix, tool schema, thinking setting
or message order changes: evidence from another identity is stale.
Version 2 puts the nonce at the very first byte of the system prompt.")

(defun harness-provider-check--evidence-file ()
  "Return the capability evidence file, or nil without a state directory."
  (and (bound-and-true-p harness-state-directory)
       (expand-file-name "provider-check/capabilities.json"
                         harness-state-directory)))

(defun harness-provider-check--evidence-records ()
  "Return the capability evidence records kept, newest data first."
  (let ((file (harness-provider-check--evidence-file)))
    (when (and file (file-readable-p file))
      (condition-case err
          (let ((data (harness-json-parse (harness-read-file file))))
            (when (listp data)
              (let ((records (plist-get data :records)))
                (and records (append records nil)))))
        (error
         (harness-log 'warn "provider-check: reading capability evidence failed: %s"
                      (harness-error-short-message err))
         nil)))))

(defun harness-provider-check--evidence-symbol (value)
  "Return VALUE as a symbol when it is a non-empty string or symbol."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))
        (t nil)))

(defun harness-provider-check--evidence-normalize-finding (finding)
  "Return FINDING with its capability and state as symbols after JSON."
  (let ((copy (copy-sequence finding)))
    (setf (plist-get copy :capability)
          (harness-provider-check--evidence-symbol (plist-get copy :capability))
          (plist-get copy :state)
          (harness-provider-check--evidence-symbol (plist-get copy :state)))
    copy))

(defun harness-provider-check--evidence-normalize-kind (evidence)
  "Return EVIDENCE with the symbol fields of JSON read back as symbols."
  (when evidence
    (let ((copy (copy-sequence evidence)))
      (setf (plist-get copy :kind)
            (harness-provider-check--evidence-symbol (plist-get copy :kind))
            (plist-get copy :telemetry)
            (harness-provider-check--evidence-symbol (plist-get copy :telemetry))
            (plist-get copy :environment)
            (mapcar #'harness-provider-check--evidence-symbol
                    (plist-get copy :environment)))
      copy)))

(defun harness-provider-check--evidence-normalize (record)
  "Return RECORD with the fields a JSON store turned into strings as symbols.
The classification and `provider/cache-evidence' expose symbols; a
record read from disk must mean the same as the one just made."
  (when record
    (let* ((copy (copy-sequence record))
           (findings (plist-get copy :findings)))
      (setf (plist-get copy :source)
            (harness-provider-check--evidence-symbol (plist-get copy :source))
            (plist-get copy :provider)
            (harness-provider-check--evidence-symbol (plist-get copy :provider))
            (plist-get copy :cache)
            (harness-provider-check--evidence-normalize-kind
             (plist-get copy :cache))
            (plist-get copy :cross-session)
            (harness-provider-check--evidence-normalize-kind
             (plist-get copy :cross-session))
            (plist-get copy :findings)
            (when findings
              (list :observed
                    (mapcar #'harness-provider-check--evidence-normalize-finding
                            (plist-get findings :observed))
                    :unsupported
                    (mapcar #'harness-provider-check--evidence-normalize-finding
                            (plist-get findings :unsupported))
                    :unverified
                    (mapcar #'harness-provider-check--evidence-normalize-finding
                            (plist-get findings :unverified))
                    :cache-miss-runs (plist-get findings :cache-miss-runs)
                    :cross-miss-runs (plist-get findings :cross-miss-runs))))
      copy)))

(defun harness-provider-check--evidence-record-for (model)
  "Return the recorded evidence of MODEL, normalized, or nil."
  (let ((record (cl-find model (harness-provider-check--evidence-records)
                         :key (lambda (one) (plist-get one :model)) :test #'equal)))
    (harness-provider-check--evidence-normalize record)))

(defun harness-provider-check--evidence-store (record)
  "Keep RECORD with the other capability evidence; return RECORD.
A model's earlier record is replaced: its scope fingerprint is kept in
the new record, and a changed scope makes the record stale when read.
A missing state directory or a failed write never fails the check."
  (let ((file (harness-provider-check--evidence-file)))
    (when file
      (condition-case err
          (let* ((old (harness-provider-check--evidence-records))
                 (kept (cl-remove (plist-get record :model) old
                                  :key (lambda (one) (plist-get one :model))
                                  :test #'equal))
                 (data (list :schema harness-provider-check--evidence-schema
                             :records (harness-json-array
                                       (cons record (cl-subseq kept 0 (min (length kept) 63)))))))
            (harness-write-file-atomically file (harness-json-encode data)))
        (error
         (harness-log 'warn "provider-check: writing capability evidence failed: %s"
                      (harness-error-short-message err)))))
    record))

(defun harness-provider-check--scope (model metadata provider)
  "Return the scope that gives evidence about MODEL its meaning.
The advertised capabilities, cache lifetime, prices and provider
description (which names an OpenAI-compatible endpoint) are part of it,
as are the evidence schema and the synthetic request identity.  A
change to any of them makes an old record stale rather than silently
read as evidence about the new configuration."
  (list :provider (plist-get metadata :provider)
        :model model
        :provider-doc (and provider (harness-provider-doc provider))
        :advertised (plist-get metadata :capabilities)
        :cache-ttl (ignore-errors (harness-call 'provider/cache-ttl model))
        :pricing (plist-get metadata :pricing)
        :peak-pricing (plist-get metadata :peak-pricing)
        :max-output (plist-get metadata :max-output)
        :schema harness-provider-check--evidence-schema
        :request-identity harness-provider-check--request-identity))

(defun harness-provider-check--model-scope (model)
  "Return the current scope of MODEL, read from the catalogue."
  (let* ((parsed (harness-provider-parse-model model))
         (provider (and (car parsed) (harness-provider-get (car parsed))))
         (metadata (ignore-errors (harness-call 'provider/model model))))
    (harness-provider-check--scope model metadata provider)))

(defun harness-provider-check--fingerprint (scope)
  "Return the SHA-256 of SCOPE, the identity a record is valid for."
  (secure-hash 'sha256 (prin1-to-string scope)))

(defun harness-provider-check--advertised (job)
  "Return what the provider of JOB advertises about caching, as data.
Advertised is not observed: a declared lifetime is what the provider
says, not what this run measured."
  (let* ((metadata (harness-provider-check-job-metadata job))
         (capabilities (plist-get metadata :capabilities))
         (pricing (plist-get metadata :pricing)))
    (list :cache-ttl (or (plist-get capabilities :cache-ttl)
                         (ignore-errors
                           (harness-call 'provider/cache-ttl
                                         (harness-provider-check-job-model job))))
          :cache-refresh (and (harness-json-true-p
                               (plist-get capabilities :cache-refresh))
                              t)
          :cache-read-price (plist-get pricing :cache-read)
          :input-price (plist-get pricing :input)
          :output-price (plist-get pricing :output)
          :thinking (and (harness-json-true-p (plist-get capabilities :thinking)) t)
          :hosted-loop (and (harness-json-true-p
                             (plist-get capabilities :hosted-loop))
                            t))))

(defun harness-provider-check--capability-name (capability)
  "Return CAPABILITY as a short label."
  (format "%s" capability))

(defun harness-provider-check--finding (capability &rest keys)
  "Return a finding plist for CAPABILITY with KEYS."
  (append (list :capability capability) keys))

(defun harness-provider-check--cache-miss-run-p (cache)
  "Non-nil when CACHE is a complete run of repeated misses with cold controls."
  (and cache
       (eq (plist-get cache :telemetry) 'present)
       (>= (or (plist-get cache :repeat-samples) 0)
           harness-provider-check-cache-min-samples)
       (zerop (or (plist-get cache :repeat-hits) 0))
       (plist-get cache :controls-clean)
       (null (plist-get cache :environment))))

(defun harness-provider-check--independent-miss-run-p (cross)
  "Non-nil when CROSS is a complete run of primed independent prefixes missing.
Every prefix was primed and asked for serially and concurrently, the
controls stayed cold, and nothing was throttled, mixed or failed.  A
batch the request gate serialised is not excluded here: a miss run only
needs the requests to have run, and the observed path requires overlap."
  (and cross
       (eq (plist-get cross :telemetry) 'present)
       (>= (or (plist-get cross :prefix-count) 0)
           harness-provider-check-cache-min-samples)
       (cl-every (lambda (prefix)
                   (and (not (plist-get prefix :baseline-hit))
                        (not (plist-get prefix :round-1-hit))
                        (not (plist-get prefix :round-2-hit))))
                 (plist-get cross :prefixes))
       (zerop (or (plist-get cross :control-hits) 0))
       (zerop (or (plist-get cross :errors) 0))
       (zerop (or (plist-get cross :throttled) 0))
       (zerop (or (plist-get cross :identity-mismatches) 0))
       (plist-get cross :distinct-sessions)
       (>= (or (plist-get cross :peak-concurrency) 0) 2)
       (null (plist-get cross :environment))))

(defun harness-provider-check--cache-findings (cache cross previous)
  "Classify CACHE and CROSS evidence, against PREVIOUS, into conservative findings.
Observed needs telemetry and at least `harness-provider-check-cache-min-samples'
hits with cold controls.  Unsupported needs repeated misses with cold
controls in two independent runs; one run is unverified.  A missing
telemetry value is unknown, not zero, and no probe measures a cache
lifetime extension."
  (let ((observed nil) (unsupported nil) (unverified nil)
        (prev-cache-misses (or (plist-get previous :cache-miss-runs) 0))
        (prev-cross-misses (or (plist-get previous :cross-miss-runs) 0))
        (cache-miss-runs 0) (cross-miss-runs 0)
        (min harness-provider-check-cache-min-samples))
    (cl-labels
        ((observe (finding) (push finding observed))
         (refute (finding) (push finding unsupported))
         (unknown (finding) (push finding unverified)))
      ;; Exact-prefix reuse.
      (cond
       ((null cache)
        (unknown (harness-provider-check--finding
                  'prompt-cache-exact-prefix :state 'unverified :reason "no evidence")))
       ((not (eq (plist-get cache :telemetry) 'present))
        (unknown (harness-provider-check--finding
                  'prompt-cache-exact-prefix :state 'unverified
                  :reason "missing telemetry; unknown, not zero")))
       ((< (or (plist-get cache :repeat-samples) 0) min)
        (unknown (harness-provider-check--finding
                  'prompt-cache-exact-prefix :state 'unverified
                  :samples (plist-get cache :repeat-samples)
                  :reason "sample size too small")))
       ((not (plist-get cache :controls-clean))
        (unknown (harness-provider-check--finding
                  'prompt-cache-exact-prefix :state 'unverified
                  :reason "control prefix read cached tokens")))
       ((>= (or (plist-get cache :repeat-hits) 0) min)
        (observe (harness-provider-check--finding
                  'prompt-cache-exact-prefix :state 'observed
                  :samples (plist-get cache :repeat-samples)
                  :hits (plist-get cache :repeat-hits)
                  :scope "model, system, tools, thinking, message order")))
       ((harness-provider-check--cache-miss-run-p cache)
        (setq cache-miss-runs (1+ prev-cache-misses))
        (if (>= cache-miss-runs 2)
            (refute (harness-provider-check--finding
                     'prompt-cache-exact-prefix :state 'unsupported
                     :runs cache-miss-runs
                     :samples (plist-get cache :repeat-samples)
                     :hits 0 :controls "cold"
                     :reason "repeated misses in two independent runs"))
          (unknown (harness-provider-check--finding
                    'prompt-cache-exact-prefix :state 'unverified
                    :runs 1
                    :samples (plist-get cache :repeat-samples)
                    :hits 0
                    :reason "repeated misses in one run; more runs needed"))))
       (t
        (unknown (harness-provider-check--finding
                  'prompt-cache-exact-prefix :state 'unverified
                  :reason "incomplete probe"))))
      ;; Keep-warm refresh reuse.
      (let* ((warm (plist-get cache :keep-warm))
             (samples (or (plist-get warm :refresh-samples) 0))
             (hits (or (plist-get warm :refresh-hits) 0))
             (base-observed (and cache
                                 (eq (plist-get cache :telemetry) 'present)
                                 (>= (or (plist-get cache :repeat-hits) 0) min)
                                 (plist-get cache :controls-clean))))
        (cond
         ((not base-observed)
          (unknown (harness-provider-check--finding
                    'prompt-cache-keep-warm-reuse :state 'unverified
                    :reason "base prefix reuse not established")))
         ((< samples min)
          (unknown (harness-provider-check--finding
                    'prompt-cache-keep-warm-reuse :state 'unverified
                    :samples samples :reason "sample size too small")))
         ((>= hits min)
          (observe (harness-provider-check--finding
                    'prompt-cache-keep-warm-reuse :state 'observed
                    :samples samples :hits hits
                    :request "prefix plus a short keep-warm message")))
         (t
          (unknown (harness-provider-check--finding
                    'prompt-cache-keep-warm-reuse :state 'unverified
                    :samples samples :hits hits
                    :reason "refresh missed in one run; more runs needed")))))
      ;; Persistence over a measured wait, and the no-refresh control.
      (let* ((persistence (plist-get cache :persistence))
             (wait (or (plist-get persistence :wait) 0))
             (sample (plist-get persistence :sample))
             (control (plist-get (plist-get cache :control) :resume)))
        (cond
         ((<= wait 0)
          (unknown (harness-provider-check--finding
                    'prompt-cache-persistence :state 'unverified
                    :reason "no measured wait configured")))
         ((and (numberp sample) (> sample 0))
          (observe (harness-provider-check--finding
                    'prompt-cache-persistence :state 'observed
                    :seconds wait :samples 1 :hits 1
                    :control (if (and (numberp control) (> control 0))
                                 "control also cached"
                               "control missed"))))
         (t
          (unknown (harness-provider-check--finding
                    'prompt-cache-persistence :state 'unverified
                    :seconds wait :samples 1 :hits 0
                    :reason "repeat after the wait missed"))))
      ;; Whether a keep-warm request benefited the resumed request.
      (let* ((warm (plist-get cache :keep-warm))
             (resume (plist-get warm :resume))
             (control (plist-get (plist-get cache :control) :resume)))
        (cond
         ((and (numberp resume) (> resume 0)
               (numberp control) (zerop control))
          (observe (harness-provider-check--finding
                    'prompt-cache-keep-warm-benefit :state 'observed
                    :samples 1
                    :reason "resumed request read the cache after keep-warm; control lapsed")))
         ((and (numberp resume) (> resume 0))
          (unknown (harness-provider-check--finding
                    'prompt-cache-keep-warm-benefit :state 'unverified
                    :reason "both resumed and unrefreshed control read the cache; no incremental benefit at this wait")))
         ((null resume)
          (unknown (harness-provider-check--finding
                    'prompt-cache-keep-warm-benefit :state 'unverified
                    :reason "no resumed request")))
         (t
          (unknown (harness-provider-check--finding
                    'prompt-cache-keep-warm-benefit :state 'unverified
                    :reason "resumed request missed; more runs needed"))))
      ;; A lifetime is never inferred from a hit or a short wait.
      (unknown (harness-provider-check--finding
                'prompt-cache-ttl :state 'unverified
                :reason "no TTL measurement; a hit does not extend a lifetime"))
      (when cache
        (unknown (harness-provider-check--finding
                  'prompt-cache-keep-warm-extension :state 'unverified
                  :reason "no wait near the provider's cache lifetime")))
      ;; Whether every independent session cached its own prefix.
      (let* ((prefixes (plist-get cross :prefixes))
             (count (length prefixes))
             (cached (or (plist-get cross :cached-count) 0))
             (baseline (or (plist-get cross :baseline-hits) 0))
             (round-1 (or (plist-get cross :round-1-hits) 0))
             (round-2 (or (plist-get cross :round-2-hits) 0))
             (peak (or (plist-get cross :peak-concurrency) 0)))
        (cond
         ((null cross)
          (unknown (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'unverified
                    :reason "no evidence")))
         ((not (eq (plist-get cross :telemetry) 'present))
          (unknown (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'unverified
                    :reason "missing or partial telemetry; unknown, not zero")))
         ((> (or (plist-get cross :throttled) 0) 0)
          (unknown (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'unverified
                    :throttled (plist-get cross :throttled)
                    :reason "rate limited; not a capability verdict")))
         ((> (or (plist-get cross :errors) 0) 0)
          (unknown (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'unverified
                    :errors (plist-get cross :errors)
                    :reason "some requests failed")))
         ((> (or (plist-get cross :identity-mismatches) 0) 0)
          (unknown (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'unverified
                    :mismatches (plist-get cross :identity-mismatches)
                    :reason "prefix and session identity mismatched")))
         ((not (plist-get cross :distinct-sessions))
          (unknown (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'unverified
                    :reason "session ids were not independent")))
         ((> (or (plist-get cross :control-hits) 0) 0)
          (unknown (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'unverified
                    :reason "fresh control prefix read cached tokens")))
         ((< count min)
          (unknown (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'unverified
                    :samples count
                    :reason "fewer than the minimum independent prefixes")))
         ((< peak 2)
          (unknown (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'unverified
                    :peak peak
                    :reason "requests did not overlap; concurrency unverified")))
         ((and (>= cached count) (>= baseline count))
          (observe (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'observed
                    :sessions count
                    :prefixes count
                    :samples (* count 2)
                    :hits (* count 2)
                    :baseline "serial per-prefix reuse"
                    :peak peak
                    :controls "fresh never-primed prefixes cold")))
         ((and (>= baseline count) (zerop round-1) (zerop round-2))
          (unknown (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'unverified
                    :baseline baseline
                    :reason "serial baseline hit but concurrent reuse missed")))
         ((and (< cached count) (> (+ round-1 round-2) 0))
          (unknown (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'unverified
                    :prefixes count
                    :hits cached
                    :reason "partial: some independent prefixes missed")))
         ((harness-provider-check--independent-miss-run-p cross)
          (setq cross-miss-runs (1+ prev-cross-misses))
          (if (>= cross-miss-runs 2)
              (refute (harness-provider-check--finding
                       'independent-prefix-cache-reuse :state 'unsupported
                       :runs cross-miss-runs
                       :sessions count
                       :samples (* count 2)
                       :hits 0
                       :controls "fresh never-primed prefixes cold"
                       :reason "primed independent prefixes missed in two independent runs"))
            (unknown (harness-provider-check--finding
                      'independent-prefix-cache-reuse :state 'unverified
                      :runs 1
                      :samples (* count 2)
                      :hits 0
                      :reason "primed independent prefixes missed in one run; more runs needed"))))
         (t
          (unknown (harness-provider-check--finding
                    'independent-prefix-cache-reuse :state 'unverified
                    :reason "incomplete or mixed independent-prefix probe")))))
    (list :observed (nreverse observed)
          :unsupported (nreverse unsupported)
          :unverified (nreverse unverified)
          :cache-miss-runs cache-miss-runs
          :cross-miss-runs cross-miss-runs))))))

(defun harness-provider-check--findings-label (findings key)
  "Return the capability labels of FINDINGS at KEY, or nil."
  (let ((items (plist-get findings key)))
    (and items
         (mapconcat (lambda (finding)
                      (harness-provider-check--capability-name
                       (plist-get finding :capability)))
                    items ", "))))

(defun harness-provider-check--evidence-record (job cache cross)
  "Return a conservative capability record from JOB's CACHE and CROSS evidence.
CROSS is the independent-prefix experiment: every session primes and
reuses its own prefix.  The scope fingerprint covers the provider, model,
advertised capabilities, cache lifetime, prices and the synthetic request
identity; the previous record of the same model supplies the second run a
refusal needs.  No raw provider error text and no conversation content is
kept."
  (let* ((model (harness-provider-check-job-model job))
         (provider (harness-provider-check-job-provider job))
         (metadata (harness-provider-check-job-metadata job))
         (previous (harness-provider-check--evidence-record-for model))
         (advertised (harness-provider-check--advertised job))
         (findings (harness-provider-check--cache-findings cache cross previous))
         (scope (harness-provider-check--scope model metadata provider)))
    (list :schema harness-provider-check--evidence-schema
          :source 'live-self-test
          :provider (plist-get metadata :provider)
          :model model
          :fingerprint (harness-provider-check--fingerprint scope)
          :scope scope
          :checked-at (float-time)
          :advertised advertised
          :findings findings
          :cache cache
          :cross-session cross
          :cache-miss-runs (plist-get findings :cache-miss-runs)
          :cross-miss-runs (plist-get findings :cross-miss-runs)
          :settings (list :concurrency (harness-provider-check-job-request-concurrency job)
                          :check-concurrency (harness-provider-check-job-concurrency job)
                          :cache-sessions (or (plist-get
                                               (harness-provider-check-job-options job)
                                               :cache-sessions)
                                              harness-provider-check-cache-sessions)
                          :persistence-wait harness-provider-check-cache-persistence-wait
                          :max-output harness-provider-check-max-output-tokens))))

(defun harness-provider-check--evidence-detail (record)
  "Return a compact noun-phrase summary of capability RECORD."
  (let* ((findings (plist-get record :findings))
         (observed (harness-provider-check--findings-label findings :observed))
         (unsupported (harness-provider-check--findings-label findings :unsupported))
         (unverified (harness-provider-check--findings-label findings :unverified))
         (advertised (plist-get record :advertised)))
    (format "observed %s · unsupported %s · unverified %s · advertised TTL %s"
            (or observed "none")
            (or unsupported "none")
            (or unverified "none")
            (or (plist-get advertised :cache-ttl) "none"))))

(defun harness-provider-check--check-cache-evidence (job _run)
  "Record what the cache checks of JOB observed, conservatively.
The record separates advertised, observed, unsupported and unverified
findings; it never turns one run into a guarantee, a missing telemetry
value into zero, or a hit into a cache lifetime.  It changes no setting
and starts no request."
  (let* ((cache (plist-get (gethash "cache"
                                    (harness-provider-check-job-done job))
                           :evidence))
         (cross (plist-get (gethash "cache-parallel"
                                    (harness-provider-check-job-done job))
                           :evidence))
         (record (harness-provider-check--evidence-record job cache cross))
         (findings (plist-get record :findings))
         (observed (plist-get findings :observed))
         (unsupported (plist-get findings :unsupported))
         (status (if (or observed unsupported) 'pass 'skip)))
    (harness-provider-check--evidence-store record)
    (list :status status
          :detail (format "%s · record %s"
                          (harness-provider-check--evidence-detail record)
                          (if (harness-provider-check--evidence-file)
                              "saved"
                            "not saved (no state directory)"))
          :evidence record)))

(harness-defmethod provider/cache-evidence (model)
  "Return the conservative cache evidence recorded for MODEL, or nil.
The answer is a plist `(:model :stale :scope :record)'.  STALE is
non-nil when the provider, model, advertised capabilities, cache
lifetime, prices or the synthetic request identity changed since the
record was made, so its findings no longer describe this configuration.
A record says what a live self-test observed; it is not a guarantee, a
cache lifetime or permission to enable automatic keep-warm requests."
  (when (and (stringp model) (not (string-empty-p model)))
    (when-let* ((record (harness-provider-check--evidence-record-for model)))
      (let* ((scope (harness-provider-check--model-scope model))
             (stale (not (equal (plist-get record :fingerprint)
                                (harness-provider-check--fingerprint scope)))))
        (list :model model :stale (and stale t) :scope scope :record record)))))

(defun harness-provider-check--check-tiers (job _run)
  "Check that the tier models the provider of JOB declares resolve.
A tier that names no model of the catalogue is not an error in itself,
but the callers that ask for it -- the permission judge, naming, recaps
-- fall back to the session's own model, which is the expensive one.
`frontier' is the exception: the harness never picks it on its own (see
`harness-model-tiers'), so a plan that declares none, or one its
catalogue does not list, costs no fallback."
  (let* ((model (harness-provider-check-job-model job))
         (provider (harness-provider-check-job-provider job))
         (listed (ignore-errors (harness-call 'provider/cached-models
                                              (harness-provider-check-job-provider-id job))))
         (tiers (and provider (harness-provider-normalize-tiers
                               (harness-provider-tiers provider)))))
    (cond
     ((not provider) '(skip . "Provider is not registered."))
     ((not tiers) '(skip . "Provider declares no tier models."))
     ((and listed (null (cdr listed)))
      '(skip . "The catalogue lists one model."))
     (t
      (let (missing notes)
        (dolist (tier '(:simple :medium :hard :frontier))
          (when (plist-get tiers tier)
            (let* ((name (substring (symbol-name tier) 1))
                   (info (ignore-errors (harness-call 'provider/tier-model-info model tier)))
                   (resolved (car info))
                   (reason (cdr info)))
              (cond
               (resolved
                (push (format "%s: %s" name
                              (or (cdr (harness-provider-parse-model resolved)) resolved))
                      notes))
               ((eq tier :frontier)
                (push (format "frontier: none (%s)" (or reason 'none)) notes))
               (t (push (format "%s (%s)" name (or reason 'none)) missing))))))
        (if missing
            (harness-provider-check--require
             nil
             (format "Tier %s matches no model; judges, naming and recaps fall back to the session's model"
                     (mapconcat #'identity (nreverse missing) ", ")))
          (cons 'pass
                (if notes
                    (format "Resolved %s." (mapconcat #'identity (nreverse notes) "; "))
                  "No tier names a model."))))))))

(defun harness-provider-check--check-transcript-round-trip (job _run)
  "Check that the same transcript renders to the same request twice.
The harness builds every request from the session's transcript, and a
provider's prompt cache reads a request only as far as it starts like
the one that wrote the prompt: a message that renders differently on a
second pass -- rebuilt from blocks instead of replayed, or read back
from the store in another order -- pays for the whole conversation
again.  This makes a small session with a text message, thinking with
its signature, and a tool call with its result; renders its request;
writes the session to the store and reads it back as a restart does;
renders it again; and compares what the provider would be sent.  It
makes no request, so it checks the harness rather than the provider,
and runs for every model."
  (let ((model (harness-provider-check-job-model job)))
    (if (not (and (harness-method-exists-p 'session/create)
                  (harness-method-exists-p 'session/append)
                  (fboundp 'harness-agent-step-request)
                  (fboundp 'harness-session-reload-nodes)))
        '(skip . "The session and agent layers are not loaded.")
      (let ((sid (plist-get (harness-call 'session/create
                                          :cwd (or (bound-and-true-p harness-state-directory)
                                                   temporary-file-directory)
                                          :model model :kind 'internal
                                          :name "Transcript round trip")
                            :id)))
        (unwind-protect
            (condition-case err
                (progn
                  (harness-call 'session/append sid
                                '(:kind user :content "Round trip: read a.txt."))
                  (harness-call 'session/append sid
                                (list :kind 'assistant
                                      :content (list (list :type "thinking" :text "I will read it."
                                                           :signature "signature-round-trip")
                                                     (list :type "tool_use" :id "call-round-trip"
                                                           :name "read_file" :input (list :path "a.txt")))))
                  (harness-call 'session/append sid
                                (list :kind 'tool-result :call-id "call-round-trip" :content "hello"))
                  (let* ((first (harness-agent-step-request sid nil #'ignore))
                         (again (progn
                                  (harness-session-flush)
                                  (harness-session-reload-nodes sid)
                                  (harness-agent-step-request sid nil #'ignore)))
                         (same (and (equal (plist-get first :system) (plist-get again :system))
                                    (equal (plist-get first :messages) (plist-get again :messages))
                                    (equal (plist-get first :tools) (plist-get again :tools)))))
                    (if same
                        '(pass . "The same transcript rendered to the same request before and after a restart.")
                      (cons 'fail
                            (format (concat "The same transcript rendered differently the second time (%s):"
                                            " every message after the one that changed would be sent"
                                            " again, uncached")
                                    (cond ((not (equal (plist-get first :system)
                                                       (plist-get again :system))) "system prompt")
                                          ((not (equal (plist-get first :tools)
                                                       (plist-get again :tools))) "tools")
                                          (t "messages")))))))
              (error (cons 'skip (format "Nothing could be rendered: %s"
                                         (harness-error-short-message err)))))
          (ignore-errors (harness-call 'session/delete sid)))))))

(defun harness-provider-check--check-no-thinking (job run)
  "Check that a request without thinking is accepted for JOB."
  (let ((request (harness-provider-check--request
                  (harness-provider-check-job-model job)
                  "provider-check-no-thinking"
                  (harness-prompt 'provider-check-greeting nil
                                  (harness-provider-check-job-model job)))))
    (setf request (plist-put request :no-thinking t))
    (harness-then
     (harness-provider-check--complete run request)
     (lambda (reply)
       (harness-provider-check--finish-events (plist-get reply :events))
       '(pass . "No-thinking request accepted; API did not reject its effort.")))))

(defun harness-provider-check--check-thinking (job run)
  "Check the deepest thinking level the model of JOB advertises."
  (let* ((metadata (harness-provider-check-job-metadata job))
         (levels (plist-get metadata :thinking-levels))
         (level (car (last levels))))
    (if (not (and (stringp level)
                  (member level '("low" "medium" "high" "xhigh" "max"))))
        '(skip . "Model advertises no known thinking level (or catalogue failed).")
      (let ((request (harness-provider-check--request
                      (harness-provider-check-job-model job)
                      "provider-check-thinking"
                      (harness-prompt 'provider-check-greeting nil
                                      (harness-provider-check-job-model job)))))
        (setf request (plist-put request :thinking level))
        (harness-then
         (harness-provider-check--complete run request)
         (lambda (reply)
           (harness-provider-check--finish-events (plist-get reply :events))
           (cons 'pass
                 (format "Requested advertised level %s without API rejection." level))))))))

(defun harness-provider-check--vision-p (metadata provider)
  "Return non-nil when METADATA or PROVIDER advertises image input."
  (or (plist-get (or (plist-get metadata :capabilities)
                     (and provider (harness-provider-capabilities provider)))
                 :vision)
      (member "image" (plist-get metadata :input-modalities))))

(defun harness-provider-check--check-image-input (job run)
  "Check that the provider of JOB accepts an advertised image block."
  (let ((metadata (harness-provider-check-job-metadata job)))
    (if (not (harness-provider-check--vision-p
              metadata (harness-provider-check-job-provider job)))
        '(skip . "This model does not advertise image input.")
      (harness-then
       (harness-provider-check--complete
        run
        (harness-provider-check--image-request
         (harness-provider-check-job-model job)
         "provider-check-image"
         (harness-prompt 'provider-check-image nil
                         (harness-provider-check-job-model job))))
       (lambda (reply)
         (harness-provider-check--finish-events (plist-get reply :events) t)
         '(pass . "Image block accepted; visual recognition not asserted."))))))

(defun harness-provider-check--tool-turn (job run)
  "Try an echo-tool round trip on the model of JOB.
Return a promise of (:first EVENTS :second EVENTS :call TOOL-CALL :marker
RECEIPT :answered BOOL :sessions SESSION-IDS).  A hosted loop receives
the result through :respond, and ANSWERED says it was delivered; a
native loop gets assistant/tool messages in a second completion.  Not
calling the tool is reported separately as model behavior, not a
provider bug."
  (let* ((model (harness-provider-check-job-model job))
         (id (format "provider-check-tool-%x" (random most-positive-fixnum)))
         (marker (format "receipt-%x" (random most-positive-fixnum)))
         (user (harness-prompt 'provider-check-tool nil model))
         (request (harness-provider-check--request model id user))
         (answered nil)
         (tool '(:name "check_echo"
                  :description "Return a receipt for value."
                  :schema (:type "object"
                           :properties (:value (:type "string"))
                           :required ("value")))))
    (setf request (plist-put request :tools (list tool)))
    (harness-then
     (harness-provider-check--complete
      run request nil nil
      (lambda (_call)
        (setq answered t)
        (list :content marker)))
     (lambda (first)
       (let* ((first-events (plist-get first :events))
              (call (cl-find 'tool-call first-events
                             :key (lambda (event) (plist-get event :type))))
              (second nil))
         (when (and call
                    (not (plist-get call :respond))
                    (eq (plist-get (car (last first-events)) :stop-reason) 'tool-use))
           (let* ((text (harness-provider-check--text first-events))
                  (assistant
                   (list :role 'assistant
                         :content
                         (append
                          (unless (string-empty-p text)
                            (list (list :type "text" :text text)))
                          (list (list :type "tool_use"
                                      :id (plist-get call :id)
                                      :name (plist-get call :name)
                                      :input (plist-get call :input))))))
                  (tool-result
                   (list :role 'tool
                         :content (list (list :type "tool_result"
                                              :tool_use_id (plist-get call :id)
                                              :content marker))))
                  (follow (plist-put (copy-sequence request)
                                     :messages
                                     (append (plist-get request :messages)
                                             (list assistant tool-result)))))
             (setf follow (plist-put follow :provider-state
                                     (plist-get first :state)))
             (setq second
                   (harness-provider-check--complete run follow))))
         (if second
             (harness-then second
                           (lambda (reply)
                             (list :first first-events
                                   :second (plist-get reply :events)
                                   :call call :marker marker :answered answered
                                   :sessions (delq nil (list (plist-get first :session)
                                                             (plist-get reply :session))))))
           (harness-resolved
            (list :first first-events :second nil
                  :call call :marker marker :answered answered
                  :sessions (delq nil (list (plist-get first :session)))))))))))

(defun harness-provider-check--check-tool-transport (job run)
  "Check the tool-call event of JOB and its result continuation."
  (harness-then
   (harness-provider-check--tool-turn job run)
   (lambda (attempt)
     (setf (harness-provider-check-job-tool-attempt job) attempt)
     (harness-provider-check--note-attempt-sessions run attempt)
     (let ((events (plist-get attempt :first))
           (call (plist-get attempt :call))
           (second (plist-get attempt :second))
           (answered (plist-get attempt :answered)))
       (harness-provider-check--finish-events events t)
       (if (not call)
           (if (eq (plist-get (car (last events)) :stop-reason) 'tool-use)
               '(fail . "Turn ended for tool use but delivered no tool-call event")
             '(skip . "Model chose not to call a tool; transport unexercised (see behavior suite)."))
         (harness-provider-check--require
          (equal (plist-get call :name) "check_echo")
          "Tool name changed in transport")
         (when second (harness-provider-check--finish-events second))
         (harness-provider-check--require
          (or second
              (and (plist-get call :respond)
                   answered
                   (eq (plist-get (car (last events)) :stop-reason) 'end-turn)))
          "Tool result did not reach a completed continuation")
         '(pass . "Tool id/input and hosted or native result continuation completed."))))))

(defun harness-provider-check--check-quota (job _run)
  "Check the generic shape of the optional quota hook of JOB."
  (let* ((pid (harness-provider-check-job-provider-id job))
         (provider (harness-provider-check-job-provider job))
         (capabilities (and provider (harness-provider-capabilities provider))))
    (if (not (and provider (harness-provider-quota-fn provider)))
        (progn
          (harness-provider-check--require
           (not (plist-get capabilities :quota))
           "Advertises :quota but has no quota hook")
          '(skip . "Provider has no quota hook."))
      (harness-then
       (harness-as-promise (harness-call 'provider/quota pid))
       (lambda (quota)
         (if (null quota)
             '(skip . "No quota reported for this account; cannot validate windows.")
           (harness-provider-check--require
            (and (listp quota)
                 (memq (plist-get quota :billing) '(api subscription nil)))
            "Quota billing is invalid")
           (dolist (window (plist-get quota :windows))
             (harness-provider-check--require
              (and (stringp (plist-get window :name))
                   (numberp (plist-get window :used))
                   (<= 0 (plist-get window :used) 1))
              "Quota window needs a name and used fraction in [0,1]"))
           '(pass . "Billing and reported quota windows have the generic shape.")))))))

(defun harness-provider-check--check-fork (job run)
  "Check the optional provider-state and fork support of JOB."
  (let* ((metadata (harness-provider-check-job-metadata job))
         (provider (harness-provider-check-job-provider job))
         (capabilities (or (plist-get metadata :capabilities)
                           (and provider (harness-provider-capabilities provider)))))
    (if (not (plist-get capabilities :fork))
        '(skip . "Provider does not advertise fork support.")
      (let* ((model (harness-provider-check-job-model job))
             (session-id "provider-check-fork")
             (request (harness-provider-check--request
                       model session-id
                       (harness-prompt 'provider-check-greeting nil model))))
        (setf request (plist-put request :ephemeral nil))
        (harness-then
         (harness-provider-check--finally
          (harness-provider-check--complete run request t)
          (lambda () (harness-provider-check--close model session-id)))
         (lambda (reply)
           (let ((state (plist-get reply :state)))
             (harness-provider-check--finish-events (plist-get reply :events))
             (harness-provider-check--require (listp state) "No provider-state event")
             (harness-then
              (harness-as-promise (harness-call 'provider/fork model state))
              (lambda (forked)
                (harness-provider-check--require
                 (plist-get forked :provider)
                 "Fork returned no provider-owned state")
                '(pass . "Emitted state and returned a provider-tagged fork."))))))))))

(defun harness-provider-check--check-embeddings (job _run)
  "Check the optional embedding hook of JOB when an embedding model is given."
  (let* ((model (harness-provider-check-job-model job))
         (pid (car (harness-provider-parse-model model)))
         (embedding-model (harness-provider-check-job-embedding-model job)))
    (cond
     ((not (and pid (harness-call 'provider/embeds-p model)))
      '(skip . "Provider has no embedding hook."))
     ((null embedding-model)
      '(skip . "Give an embedding model to check this hook."))
     (t
      (harness-provider-check--require
       (eq (car (harness-provider-parse-model embedding-model)) pid)
       "Embedding model belongs to another provider")
      (harness-then
       (harness-as-promise
        (harness-call 'provider/embed embedding-model '("alpha" "beta")))
       (lambda (answer)
         (let* ((vectors (plist-get answer :vectors)))
           (harness-provider-check--require
            (and (= (length vectors) 2)
                 (cl-every (lambda (vector)
                             (and (listp vector) vector
                                  (cl-every #'numberp vector)))
                           vectors)
                 (= (length (car vectors)) (length (cadr vectors))))
            "Embeddings need two same-size numeric vectors in input order")
           '(pass . "Two ordered inputs returned same-size numeric vectors."))))))))

(defun harness-provider-check--check-cancellation (job run)
  "Check that cancelling a live request of JOB ends it once as cancelled."
  (harness-then
   (harness-provider-check--complete
    run
    (harness-provider-check--request (harness-provider-check-job-model job)
                                     "provider-check-cancel"
                                     (harness-prompt 'provider-check-greeting nil
                                                     (harness-provider-check-job-model job)))
    nil t)
   (lambda (reply)
     (let ((events (plist-get reply :events)))
       (harness-provider-check--events events t)
       (harness-provider-check--require
        (eq (plist-get (car (last events)) :stop-reason) 'cancelled)
        "Cancelling did not end with cancelled")
       '(pass . "Cancel produced exactly one cancelled done event.")))))

;;;; Model behavior

(defun harness-provider-check--resubmit-label ()
  "Return a fresh exact label for the resubmit-tool instruction check.
The label keeps its \"marker-\" prefix: the tool description asks for
the exact string, prefix included, so dropping the prefix is a real
failure to follow the tool's instruction."
  (format "marker-%06x%06x" (random #x1000000) (random #x1000000)))

(defun harness-provider-check--resubmit-tool (label)
  "Return a resubmit tool whose description demands LABEL exactly."
  (list :name "resubmit"
        :description (format (concat "Resubmit finished work after review. "
                                     "Put the exact string %s in the note, "
                                     "including the marker- prefix.")
                             label)
        :schema (list :type "object"
                      :properties (list :note
                                        (list :type "string"
                                              :description
                                              (format (concat "The exact string %s, "
                                                              "prefix included.")
                                                      label)))
                      :required (list "note"))))

(defun harness-provider-check--check-instructions (job run)
  "Check that the model of JOB follows a resubmit tool's label instruction.
Tool descriptions carry the formats that resubmit, hand-in and other
harness tools rely on.  This check puts a fresh label in the resubmit
tool's description, and requires the model to carry it, prefix included,
into the structured note argument rather than dropping it as a label."
  (let* ((label (harness-provider-check--resubmit-label))
         (request (harness-provider-check--request
                   (harness-provider-check-job-model job)
                   "provider-check-instructions"
                   (harness-prompt 'provider-check-instructions nil
                                   (harness-provider-check-job-model job))
                   (harness-prompt 'provider-check-instructions-system nil
                                   (harness-provider-check-job-model job)))))
    (setf request (plist-put request :tools
                             (list (harness-provider-check--resubmit-tool
                                    label))))
    (harness-then
     (harness-provider-check--complete
      run request nil nil
      (lambda (_call)
        ;; A hosted loop waits for this result before it can finish its
        ;; turn; the check reads the call's argument, not the answer.
        (list :content "Resubmitted.")))
     (lambda (reply)
       (let* ((events (plist-get reply :events))
              (call (cl-find 'tool-call events
                             :key (lambda (event) (plist-get event :type))))
              (note (and call (plist-get (plist-get call :input) :note))))
         (harness-provider-check--finish-events events t)
         (harness-provider-check--require
          (and call (equal (plist-get call :name) "resubmit"))
          "Model did not call the resubmit tool")
         (harness-provider-check--require
          (and (stringp note)
               (string-match-p (regexp-quote label) note))
          "Model dropped the label from the resubmit note")
         '(pass . "Followed the resubmit tool's label in its argument."))))))

(defun harness-provider-check--check-vision (job run)
  "Check that the model of JOB names the color of a red image."
  (let* ((model (harness-provider-check-job-model job))
         (info (harness-call 'provider/model model)))
    (if (not (harness-provider-check--vision-p info
                                               (harness-provider-check-job-provider job)))
        '(skip . "Model does not advertise image input.")
      (harness-then
       (harness-provider-check--complete
        run
        (harness-provider-check--image-request
         model "provider-check-vision"
         (harness-prompt 'provider-check-vision nil model)))
       (lambda (reply)
         (let ((events (plist-get reply :events)))
           (harness-provider-check--expect-text events)
           (harness-provider-check--require
            (string-match-p "\\bred\\b" (downcase (harness-provider-check--text events)))
            "Model did not identify the red image")
           '(pass . "Identified the solid red image without a tool.")))))))

(defun harness-provider-check--check-tool-call (job run)
  "Check that the model of JOB chooses the offered tool with structured arguments."
  (harness-then
   (if (harness-provider-check-job-tool-attempt job)
       (harness-resolved (harness-provider-check-job-tool-attempt job))
     (harness-then
      (harness-provider-check--tool-turn job run)
      (lambda (attempt)
        (setf (harness-provider-check-job-tool-attempt job) attempt)
        attempt)))
   (lambda (attempt)
     (harness-provider-check--note-attempt-sessions run attempt)
     (let ((call (plist-get attempt :call))
           (events (plist-get attempt :first)))
       ;; An account or network failure is not the model's choice.
       (harness-provider-check--events events t)
       (if (not call)
           (if (eq (plist-get (car (last events)) :stop-reason) 'tool-use)
               '(skip . "Turn ended for tool use without a tool-call event; model choice unobserved.")
             (harness-provider-check--require nil "Model did not call the offered tool"))
         (progn
           (harness-provider-check--require
            (and (equal (plist-get call :name) "check_echo")
                 (equal (plist-get (plist-get call :input) :value) "ping"))
            "Model chose the wrong tool or arguments")
           '(pass . "Called check_echo with the requested structured argument.")))))))

(defun harness-provider-check--check-tool-result (job run)
  "Check that the model of JOB used the receipt only the tool returned."
  (let ((attempt (harness-provider-check-job-tool-attempt job)))
    (when attempt
      (harness-provider-check--note-attempt-sessions run attempt))
    (if (not (and attempt (plist-get attempt :call)))
        '(skip . "No tool call to return a result to.")
      (let* ((second (plist-get attempt :second))
             (events (or second (plist-get attempt :first)))
             (marker (plist-get attempt :marker)))
        ;; A continuation that ran out of quota never reached the model.
        (when second (harness-provider-check--events second))
        (harness-provider-check--require
         (string-match-p (regexp-quote marker)
                         (harness-provider-check--text events))
         "Model omitted the receipt only the tool returned")
        '(pass . "Final answer included the tool-only receipt.")))))

;;;; The plan

;;;; Options, plan and estimate

(defconst harness-provider-check--stress-checks
  '("catalogue" "cache" "cache-parallel" "cache-evidence")
  "Checks the opt-in twelve-session cache stress runs.
The stress is the two cache experiments and the record they produce; the
provider contract checks are not repeated, so the bounded stress plan
stays under `harness-provider-check-max-requests' without raising it.")

(defun harness-provider-check--selected-checks (options)
  "Return the check ids OPTIONS selects, or the stress checks for a stress run.
An explicit `:checks' list always wins; a true `:cache-stress' without
one runs the cache checks only."
  (or (plist-get options :checks)
      (and (harness-json-true-p (plist-get options :cache-stress))
           (copy-sequence harness-provider-check--stress-checks))))

(defun harness-provider-check--options (options)
  "Return OPTIONS as a plist, accepting what JSON made of it.
A hash table's keys become keywords; nil and a plist are unchanged."
  (cond
   ((null options) nil)
   ((hash-table-p options)
    (let (out)
      (maphash (lambda (key value)
                 (push value out)
                 (push (intern (concat ":"
                                       (string-remove-prefix ":" (format "%s" key))))
                       out))
               options)
      (nreverse out)))
   ((listp options) options)
   (t nil)))

(defun harness-provider-check--cache-sessions (options)
  "Return the bounded number of sessions the independent-prefix experiment uses.
It is at least two (a concurrency comparison needs two), at most
`harness-provider-check-cache-stress-sessions' and at most
`harness-provider-check-max-concurrency'.  A true `:cache-stress'
option asks for the stress number; `:cache-sessions' names another."
  (let* ((stress (harness-json-true-p (plist-get options :cache-stress)))
         (requested (or (and stress harness-provider-check-cache-stress-sessions)
                        (plist-get options :cache-sessions)
                        harness-provider-check-cache-sessions))
         (n (if (numberp requested)
                (truncate requested)
              harness-provider-check-cache-sessions))
         (ceiling (max 2 (min harness-provider-check-max-concurrency
                              (max 2 harness-provider-check-cache-stress-sessions)))))
    (max 2 (min ceiling n))))

(defun harness-provider-check--persistence-wait ()
  "Return the bounded persistence wait the cache check may use."
  (let ((wait (or harness-provider-check-cache-persistence-wait 0)))
    (if (numberp wait)
        (max 0 (min wait harness-provider-check-cache-max-wait))
      0)))

(defun harness-provider-check--plan (suite &optional options)
  "Return the checks of SUITE, provider or model, in running order.
OPTIONS say how many sessions the independent-prefix experiment uses.
`:after' names the checks whose result a check reads, so independent
checks run together while a genuine dependency keeps its order:
catalogue metadata, completion -> usage, a tool turn -> its model
checks, and the cache experiments -> their evidence record.  `:solo'
marks an experiment that runs alone, so its concurrency measurement is
not taken while ordinary probes compete for request slots."
  (let* ((provider (memq suite '(provider all)))
         (model (memq suite '(model all)))
         (sessions (harness-provider-check--cache-sessions options))
         (wait (harness-provider-check--persistence-wait))
         (cache-timeout (max 2 (+ 5 (* 3 harness-provider-check-timeout) (* 2 wait))))
         (parallel-timeout (max 2 (+ 5 (* 3 harness-provider-check-timeout)))))
    (append
     (when provider
       (list
        (list :suite 'provider :id "catalogue"
              :name "Registry and model catalogue"
              :requests 0
              :advice "Fix :models / model metadata; do not rely on the model picker until it lists this model."
              :fn #'harness-provider-check--check-catalogue)
        (list :suite 'provider :id "tiers"
              :name "Tier model resolution"
              :requests 0
              :advice (concat "Judges, naming and recaps fall back to the session's model when a tier "
                              "matches none; name a model of this plan for :simple (see `harness-responses-tiers').")
              :fn #'harness-provider-check--check-tiers)
        (list :suite 'provider :id "completion"
              :name "Text completion and event lifecycle"
              :requests 1
              :advice "Do not use this provider for sessions until completion and event framing work."
              :fn #'harness-provider-check--check-completion)
        (list :suite 'provider :id "usage"
              :name "Usage accounting"
              :requests 0
              :after '("completion")
              :advice "Do not advertise accurate token/cost tracking until :usage is populated."
              :fn #'harness-provider-check--check-usage)
        (list :suite 'provider :id "cache"
              :name "Exact-prefix cache reuse and keep-warm"
              :requests 9
              :solo t
              :after '("catalogue")
              :timeout cache-timeout
              :advice (concat "Repeated misses with cold controls in more than one run mean every step "
                              "would re-send the prompt uncached; fix the provider's cache, or use one "
                              "that caches, before long sessions.  A single run is unverified.")
              :fn #'harness-provider-check--check-prompt-cache)
        (list :suite 'provider :id "cache-parallel"
              :name "Independent-prefix cache reuse"
              :requests (+ 2 (* 4 sessions))
              :solo t
              :after '("catalogue")
              :timeout parallel-timeout
              :advice (concat "Independent sessions whose own primed prefixes miss, while fresh "
                              "controls stay cold, mean each session re-sends its prompt uncached; "
                              "do not plan many parallel sessions around the cache.  A partial "
                              "batch or one run is unverified.")
              :fn #'harness-provider-check--check-independent-prefix-cache)
        (list :suite 'provider :id "cache-evidence"
              :name "Cache capability evidence"
              :requests 0
              :after '("cache" "cache-parallel")
              :advice (concat "A FAIL here is the harness's evidence record, not the provider: "
                              "the cache observations could not be classified or kept.")
              :fn #'harness-provider-check--check-cache-evidence)
        (list :suite 'provider :id "transcript-round-trip"
              :name "Transcript round trip"
              :requests 0
              :advice (concat "The harness renders one transcript two ways; messages would be "
                              "re-sent uncached from the one that differs. Fix the rendering, not the provider.")
              :fn #'harness-provider-check--check-transcript-round-trip)
        (list :suite 'provider :id "no-thinking"
              :name "No-thinking request"
              :requests 1
              :advice "Fix reasoning-effort mapping (e.g. unsupported 'none'); do not claim :thinking support until fixed."
              :fn #'harness-provider-check--check-no-thinking)
        (list :suite 'provider :id "thinking"
              :name "Declared thinking level"
              :requests 1
              :after '("catalogue")
              :advice "Remove unsupported :thinking-levels / :thinking capability, or map efforts per model."
              :fn #'harness-provider-check--check-thinking)
        (list :suite 'provider :id "image-input"
              :name "Advertised image input"
              :requests 1
              :after '("catalogue")
              :advice "Remove :vision / image input modality for this model until image requests work."
              :fn #'harness-provider-check--check-image-input)
        (list :suite 'provider :id "tool-transport"
              :name "Tool-call transport and tool-result continuation"
              :requests 2
              :advice "If calls are malformed or results cannot round-trip, fix tool transport before using this model as an agent."
              :fn #'harness-provider-check--check-tool-transport)
        (list :suite 'provider :id "quota"
              :name "Quota reporting (optional)"
              :requests 0
              :advice "Do not advertise :quota until provider/quota returns valid windows and billing."
              :fn #'harness-provider-check--check-quota)
        (list :suite 'provider :id "fork"
              :name "Provider-state and fork (optional)"
              :requests 1
              :advice "Do not advertise :fork / :resume until the provider emits usable state and forks it."
              :fn #'harness-provider-check--check-fork)
        (list :suite 'provider :id "embeddings"
              :name "Embeddings (optional)"
              :requests 0
              :advice "Do not advertise :embed until vectors match inputs and have numeric components."
              :fn #'harness-provider-check--check-embeddings)
        (list :suite 'provider :id "cancellation"
              :name "Cancellation and cleanup"
              :requests 1
              :advice "Fix :cancel to end a live request once and release its resources."
              :fn #'harness-provider-check--check-cancellation)))
     (when model
       (list
        (list :suite 'model :id "instructions"
              :name "Instruction following"
              :requests 1
              :advice (concat "A model that drops exact text from a tool description "
                              "fills resubmit or hand-in arguments wrongly; do not use it "
                              "for tools whose instructions carry exact formats.")
              :fn #'harness-provider-check--check-instructions)
        (list :suite 'model :id "vision"
              :name "Image recognition (optional)"
              :requests 1
              :after '("catalogue")
              :advice "Remove :vision / image input modality for this model if it cannot see images."
              :fn #'harness-provider-check--check-vision)
        (list :suite 'model :id "tool-call"
              :name "Choose and form a harness tool call"
              ;; The provider suite already made the turn; reuse it.
              :requests (if provider 0 2)
              :after (when provider '("tool-transport"))
              :advice "Use a stronger tool-using model; do not assign this one autonomous harness tasks."
              :fn #'harness-provider-check--check-tool-call)
        (list :suite 'model :id "tool-result"
              :name "Use the returned tool result"
              :requests 0
              :after '("tool-call")
              :advice "Do not rely on this model for tool-grounded answers; try a different model."
              :fn #'harness-provider-check--check-tool-result))))))

(defun harness-provider-check--select-plan (plan checks)
  "Return the checks of PLAN whose ids CHECKS names, or PLAN when CHECKS is nil."
  (if (null checks)
      plan
    (let ((wanted (mapcar (lambda (check) (format "%s" check)) (append checks nil))))
      (cl-remove-if-not (lambda (entry)
                          (member (plist-get entry :id) wanted))
                        plan))))

(defun harness-provider-check--plan-summary (plan)
  "Return PLAN without the functions, for a UI or an event."
  (mapcar (lambda (entry)
            (list :id (plist-get entry :id)
                  :suite (plist-get entry :suite)
                  :name (plist-get entry :name)
                  :requests (plist-get entry :requests)
                  :solo (and (plist-get entry :solo) t)
                  :after (plist-get entry :after)))
          plan))

(defconst harness-provider-check--estimate-input-tokens 4096
  "Input tokens one request is estimated to send, an upper bound.
The cache probes carry about two thousand; ordinary probes far less.
An estimate that is too high is honest about its bound.")

(defun harness-provider-check--pricing (model)
  "Return the prices MODEL is billed at now, or nil.
A model whose `:pricing-fn' answers uses the rates it returns for now,
so a time-of-day price is honoured."
  (let* ((metadata (ignore-errors (harness-call 'provider/model model)))
         (function (plist-get metadata :pricing-fn))
         (rates (and (functionp function)
                     (condition-case nil (funcall function metadata nil nil)
                       (error nil)))))
    (or rates (plist-get metadata :pricing))))

(defun harness-provider-check--estimate (model plan)
  "Return the request, output and cost bounds of PLAN on MODEL.
Cost is nil when the catalogue gives no input and output prices: an
unknown cost is said to be unknown rather than shown as zero."
  (let* ((requests (apply #'+ (mapcar (lambda (entry)
                                       (or (plist-get entry :requests) 0))
                                     plan)))
         (rates (harness-provider-check--pricing model))
         (input (and rates (plist-get rates :input)))
         (output (and rates (plist-get rates :output)))
         (cost (and (numberp input) (numberp output)
                    (/ (+ (* requests
                             harness-provider-check--estimate-input-tokens
                             input)
                          (* requests harness-provider-check-max-output-tokens
                             output))
                       1000000.0))))
    (list :model model
          :checks (length plan)
          :requests requests
          :input-per-request harness-provider-check--estimate-input-tokens
          :max-output harness-provider-check-max-output-tokens
          :cost cost
          :currency (and cost "USD")
          :basis (if cost
                     "catalogue prices · all input uncached · full output cap"
                   "cost unknown: no catalogue input and output prices"))))

;;;; Running the plan
;;
;; Each check gets a `harness-provider-check-run' of its own: its
;; sessions, its live handles and its cancellation.  The job holds what
;; all checks share (the catalogue, the base completion, a tool attempt),
;; the bounds, and the result set.  A check that names another in
;; `:after' waits for it; the rest run together, up to the job's check
;; and request slots.  Nothing is started twice: usage reads the
;; completion, and the model checks read the provider suite's tool turn.

(defvar harness-provider-check--jobs (make-hash-table :test #'equal)
  "Running checks, id -> `harness-provider-check-job'.")

(defun harness-provider-check--timeout (promise seconds what)
  "Return a promise like PROMISE, rejecting after SECONDS waiting for WHAT."
  (let ((result (harness-make-promise))
        (timer nil)
        (settled nil))
    (setq timer
          (run-at-time seconds nil
                       (lambda ()
                         (unless settled
                           (setq settled t)
                           (harness-reject
                            result
                            (list 'harness-provider-check-failure
                                  (format "Timed out after %s seconds waiting for %s"
                                          seconds what)))))))
    (harness-then
     promise
     (lambda (value)
       (unless settled
         (setq settled t)
         (cancel-timer timer)
         (harness-resolve result value)))
     (lambda (error)
       (unless settled
         (setq settled t)
         (cancel-timer timer)
         (harness-reject result error))))
    result))

(defun harness-provider-check--result (_job run value)
  "Return the result plist of RUN from VALUE, its status or (STATUS . DETAIL).
A check may return a plist with `:status', `:detail' and `:evidence'."
  (let* ((plist (and (consp value)
                     (keywordp (car value))
                     (plist-member value :status)))
         (status (if plist (plist-get value :status) (car-safe value)))
         (detail (if plist (plist-get value :detail) (cdr-safe value)))
         (evidence (and plist (plist-get value :evidence)))
         (summary (and plist (plist-get value :summary)))
         (sessions (harness-provider-check-run-sessions run)))
    (unless (memq status '(pass fail skip))
      (setq status 'fail
            detail "Check returned no status"))
    (append
     (list :id (plist-get (harness-provider-check-run-entry run) :id)
           :suite (plist-get (harness-provider-check-run-entry run) :suite)
           :name (plist-get (harness-provider-check-run-entry run) :name)
           :status status
           :detail (or detail "")
           :advice (and (eq status 'fail)
                        (plist-get (harness-provider-check-run-entry run) :advice)))
     (and summary (list :summary summary))
     (and evidence (list :evidence evidence))
     (and sessions (list :sessions sessions)))))

(defun harness-provider-check--failure-result (_job run error)
  "Return the result of RUN that signalled ERROR.
A check that could not run because the account is out of quota or
money, was rate-limited, refused the credential, could not reach the
provider, or ran past the job's request budget is a SKIP, with the safe
explanation attached to the condition.  Any other failure is a FAIL.
Do not print a provider's error text in either case: a third-party
plugin may have put its key in it."
  (let* ((entry (harness-provider-check-run-entry run))
         (sessions (harness-provider-check-run-sessions run))
         (kind (and (consp error) (car error)))
         (skip (memq kind '(harness-provider-check-unavailable
                            harness-provider-check-budget))))
    (append
     (list :id (plist-get entry :id)
           :suite (plist-get entry :suite)
           :name (plist-get entry :name)
           :status (if skip 'skip 'fail)
           :detail (cond
                    (skip (or (cadr error) "This check could not run."))
                    ((eq kind 'harness-provider-check-failure) (cadr error))
                    ((and (eq kind 'error) (stringp (cadr error)))
                     "Provider raised error (details suppressed)")
                    (t
                     (format "Provider raised %s (details suppressed)"
                             (or kind error))))
           :advice (and (not skip) (plist-get entry :advice)))
     (and sessions (list :sessions sessions)))))

(defun harness-provider-check--stage (job entry)
  "Run ENTRY as one check of JOB; return a promise of its result.
A failure of this check, and a timeout, become a result rather than an
error that would hide the other checks, which keep running."
  (let* ((name (plist-get entry :name))
         (id (plist-get entry :id))
         (run (make-harness-provider-check-run
               :job job :entry entry :id id
               :sessions nil :handles nil :active 0 :peak 0))
         (promise (progn
                    (puthash id run (harness-provider-check-job-runs job))
                    (condition-case error
                        (harness-as-promise (funcall (plist-get entry :fn) job run))
                      (error (harness-rejected error))))))
    (harness-then
     (harness-provider-check--timeout
      promise
      (or (plist-get entry :timeout) (+ harness-provider-check-timeout 5))
      name)
     (lambda (value) (harness-provider-check--result job run value))
     (lambda (error)
       ;; A check that timed out may still hold requests: cancel them, so
       ;; nothing pays for an answer no one will record.
       (dolist (handle (harness-provider-check-run-handles run))
         (let ((cancel (plist-get handle :cancel)))
           (when (functionp cancel) (ignore-errors (funcall cancel)))))
       (harness-provider-check--failure-result job run error)))))

(defun harness-provider-check--deps-ready-p (job entry)
  "Non-nil when the checks ENTRY names in `:after' have settled.
A name that is not in this job's plan, because the suite left it out,
is not a dependency."
  (cl-every (lambda (dependency)
              (or (not (cl-find dependency (harness-provider-check-job-plan job)
                                :key (lambda (one) (plist-get one :id))
                                :test #'equal))
                  (gethash dependency (harness-provider-check-job-done job))))
            (plist-get entry :after)))

(defun harness-provider-check--ready-solo (job)
  "Return the first solo check of JOB whose dependencies have settled."
  (cl-find-if (lambda (entry)
                (and (plist-get entry :solo)
                     (harness-provider-check--deps-ready-p job entry)))
              (harness-provider-check-job-pending job)))

(defun harness-provider-check--settle-check (job entry result)
  "Record RESULT of check ENTRY of JOB, announce it and schedule more."
  (let* ((id (plist-get entry :id))
         (run (gethash id (harness-provider-check-job-runs job))))
    (when run
      (setf (harness-provider-check-run-cancelled run) t)
      (remhash id (harness-provider-check-job-runs job)))
    (unless (or (harness-provider-check-job-cancelled job)
                (harness-provider-check-job-finished job))
      (puthash id result (harness-provider-check-job-done job))
      (push result (harness-provider-check-job-results job))
      (cl-incf (harness-provider-check-job-completed job))
      (harness-emit 'provider-check/result
                    (harness-provider-check-job-id job)
                    result
                    (harness-provider-check-job-completed job)
                    (harness-provider-check-job-total job)))
    (harness-provider-check--pump job)))

(defun harness-provider-check--start-entry (job entry)
  "Start ENTRY of JOB; its result settles the run and schedules more."
  (setf (harness-provider-check-job-pending job)
        (delq entry (harness-provider-check-job-pending job)))
  (harness-then
   (harness-provider-check--stage job entry)
   (lambda (result)
     (harness-provider-check--settle-check job entry result)
     nil)))

(defun harness-provider-check--pump-1 (job)
  "Start what JOB may start now."
  (unless (or (harness-provider-check-job-finished job)
              (harness-provider-check-job-cancelled job))
    (let* ((solo (harness-provider-check--ready-solo job))
           (in-flight (hash-table-count (harness-provider-check-job-runs job))))
      (cond
       ;; A cache experiment runs alone: its parallel batch must not have
       ;; to compete for the slots its measurement describes.
       ((and solo (zerop in-flight))
        (harness-provider-check--start-entry job solo))
       (solo nil)
       (t
        (let ((slots (- (harness-provider-check-job-concurrency job) in-flight)))
          (dolist (entry (copy-sequence (harness-provider-check-job-pending job)))
            (when (and (> slots 0)
                       (not (plist-get entry :solo))
                       (harness-provider-check--deps-ready-p job entry))
              (harness-provider-check--start-entry job entry)
              (cl-decf slots))))))
      (when (and (null (harness-provider-check-job-pending job))
                 (zerop (hash-table-count (harness-provider-check-job-runs job))))
        (harness-provider-check--finish job)))))

(defun harness-provider-check--pump (job)
  "Schedule JOB's checks, without nesting when one settles synchronously."
  (if (harness-provider-check-job-pumping job)
      (setf (harness-provider-check-job-pump-again job) t)
    (setf (harness-provider-check-job-pumping job) t)
    (unwind-protect
        (harness-provider-check--pump-1 job)
      (setf (harness-provider-check-job-pumping job) nil))
    (when (harness-provider-check-job-pump-again job)
      (setf (harness-provider-check-job-pump-again job) nil)
      (harness-provider-check--pump job))))

(defun harness-provider-check--summary (job results)
  "Return the summary plist of JOB with RESULTS."
  (list :pass (cl-count 'pass results :key (lambda (r) (plist-get r :status)))
        :fail (cl-count 'fail results :key (lambda (r) (plist-get r :status)))
        :skip (cl-count 'skip results :key (lambda (r) (plist-get r :status)))
        :completed (harness-provider-check-job-completed job)
        :total (harness-provider-check-job-total job)
        :cancelled (and (harness-provider-check-job-cancelled job) t)
        :timed-out (and (harness-provider-check-job-timed-out job) t)
        :requests (harness-provider-check-job-request-count job)
        :seconds (max 0 (- (float-time)
                           (harness-provider-check-job-started-at job)))))

(defun harness-provider-check--ordered-results (job)
  "Return JOB's results in plan order, whatever order they settled in."
  (let ((order (harness-provider-check-job-order job)))
    (sort (copy-sequence (harness-provider-check-job-results job))
          (lambda (a b)
            (< (or (gethash (plist-get a :id) order) 9999)
               (or (gethash (plist-get b :id) order) 9999))))))

(defun harness-provider-check--finish (job)
  "Finish JOB, announce its results and resolve its promise."
  (unless (harness-provider-check-job-finished job)
    (setf (harness-provider-check-job-finished job) t)
    (when-let* ((timer (harness-provider-check-job-timer job)))
      (cancel-timer timer)
      (setf (harness-provider-check-job-timer job) nil))
    (remhash (harness-provider-check-job-id job) harness-provider-check--jobs)
    (let* ((results (harness-provider-check--ordered-results job))
           (summary (harness-provider-check--summary job results)))
      (harness-emit 'provider-check/finished
                    (harness-provider-check-job-id job)
                    (harness-provider-check-job-model job)
                    results summary)
      (harness-resolve (harness-provider-check-job-promise job) results))))

(defun harness-provider-check--abort (job &optional why)
  "Cancel every request and check of JOB, then finish it with what it has."
  (unless (harness-provider-check-job-finished job)
    (setf (harness-provider-check-job-cancelled job) t)
    (when (equal why 'timed-out)
      (setf (harness-provider-check-job-timed-out job) t))
    (dolist (item (harness-provider-check-job-request-queue job))
      (funcall (plist-get item :cancel)))
    (setf (harness-provider-check-job-request-queue job) nil)
    (maphash (lambda (_id run)
               (setf (harness-provider-check-run-cancelled run) t)
               (dolist (handle (harness-provider-check-run-handles run))
                 (let ((cancel (plist-get handle :cancel)))
                   (when (functionp cancel) (ignore-errors (funcall cancel))))))
             (harness-provider-check-job-runs job))
    (harness-provider-check--finish job)))

(defun harness-provider-check-cancel (id)
  "Cancel the check job ID, if it runs; return non-nil when it was found.
Every request in flight is cancelled, the remaining checks are not
started, and the job finishes with the results it has."
  (let ((job (gethash id harness-provider-check--jobs)))
    (when job
      (harness-provider-check--abort job)
      t)))

(defun harness-provider-check--start (model suite embedding-model job-id options)
  "Start JOB-ID for MODEL, SUITE, EMBEDDING-MODEL and OPTIONS."
  (let* ((options (harness-provider-check--options options))
         (plan (harness-provider-check--select-plan
                (harness-provider-check--plan suite options)
                (harness-provider-check--selected-checks options)))
         (sessions (harness-provider-check--cache-sessions options))
         (options (plist-put (copy-sequence options) :cache-sessions sessions))
         (parsed (harness-provider-parse-model model))
         (pid (car parsed))
         (provider (and pid (harness-provider-get pid)))
         (concurrency (min (max 1 harness-provider-check-max-concurrency)
                           (max 1 harness-provider-check-concurrency)))
         ;; The independent-prefix experiment needs its whole batch in
         ;; flight at once to measure concurrency; that raises the request
         ;; cap, not the number of checks that run together.
         (request-concurrency
          (min (max 1 harness-provider-check-max-concurrency)
               (if (cl-find "cache-parallel" plan
                            :key (lambda (entry) (plist-get entry :id))
                            :test #'equal)
                   (max concurrency sessions)
                 concurrency)))
         (job (make-harness-provider-check-job
               :id job-id
               :model model
               :suite suite
               :embedding-model embedding-model
               :options options
               :provider-id pid
               :provider provider
               :plan plan
               :pending (copy-sequence plan)
               :completed 0
               :total (length plan)
               :sessions (make-hash-table :test #'equal)
               :runs (make-hash-table :test #'equal)
               :done (make-hash-table :test #'equal)
               :order (let ((table (make-hash-table :test #'equal)))
                        (cl-loop for entry in plan for index from 0
                                 do (puthash (plist-get entry :id) index table))
                        table)
               :concurrency concurrency
               :request-concurrency request-concurrency
               :max-requests (max 1 harness-provider-check-max-requests)
               :max-output-tokens (max 1 harness-provider-check-max-output-tokens)
               :active-requests 0
               :request-count 0
               :request-queue nil
               :promise (harness-make-promise)
               :started-at (float-time))))
    (puthash job-id job harness-provider-check--jobs)
    (setf (harness-provider-check-job-timer job)
          (run-at-time (max 1 harness-provider-check-total-timeout) nil
                       (lambda ()
                         (harness-log 'warn
                                      "provider-check: job %s timed out after %s seconds"
                                      job-id harness-provider-check-total-timeout)
                         (harness-provider-check--abort job 'timed-out))))
    (harness-emit 'provider-check/started job-id model suite
                  (harness-provider-check-job-total job)
                  (harness-provider-check--plan-summary plan)
                  (harness-provider-check--estimate model plan))
    (harness-run-soon #'harness-provider-check--pump job)
    job))

(defun harness-provider-check-start (model &optional suite embedding-model job-id options)
  "Start live checks of MODEL; return the `harness-provider-check-job'.
SUITE is `provider', `model' or `all' (the default).  EMBEDDING-MODEL
checks the optional embed hook.  JOB-ID lets a caller name the job, so
that events arriving before this returns still name the right one.
OPTIONS is a plist: `:checks' restricts the plan to those ids,
`:cache-sessions' sets the independent-session count and a true
`:cache-stress' asks for the bounded 12-session experiment, which runs
the cache checks only.  The job's
promise resolves with its results, in plan order.  This makes real API
requests: only `harness-provider-check' and its UI call it."
  (let* ((suite (cond ((null suite) 'all)
                      ((stringp suite) (intern suite))
                      (t suite)))
         (job-id (or (and (stringp job-id) (not (string-empty-p job-id)) job-id)
                     (format "provider-check-%s" (harness-uuid)))))
    (unless (memq suite harness-provider-check-suites)
      (error "Unknown provider-check suite: %s" suite))
    (harness-provider-check--start model suite embedding-model job-id options)))

(harness-defmethod provider/check-estimate (model &optional suite options)
  "Return the bounds of a live check of MODEL without starting it.
SUITE is \"provider\", \"model\" or \"all\"; OPTIONS takes
`:cache-sessions', `:cache-stress' and `:checks' as
`provider/check-start' does.  A true `:cache-stress' without `:checks'
is the cache checks only, so its cost stays bounded.  The answer is a
plist with `:checks', `:requests' (an upper bound), `:max-output',
`:cost' in USD or nil when the catalogue gives no prices, and `:plan'."
  (let* ((suite (cond ((null suite) 'all)
                      ((stringp suite) (intern suite))
                      (t suite)))
         (options (harness-provider-check--options options))
         (plan (harness-provider-check--select-plan
                (harness-provider-check--plan suite options)
                (harness-provider-check--selected-checks options))))
    (append (harness-provider-check--estimate model plan)
            (list :plan (harness-provider-check--plan-summary plan)))))

(harness-defmethod provider/check-start (model &optional suite embedding-model job options)
  "Start live provider and model checks of MODEL; return the job.
SUITE is \"provider\", \"model\" or \"all\".  EMBEDDING-MODEL checks the
optional embed hook.  JOB is an id the caller chooses, so events that
arrive before this answer still name the right job.  OPTIONS takes
`:checks', `:cache-sessions' and `:cache-stress'.

The checks run in the background, independent ones together and genuine
dependencies in order.  A stress run is the cache checks only.  Each
result is announced as `provider-check/result'; `provider-check/finished'
carries them all.
They make real, paid model requests: this is the method behind
`harness-provider-check', not a routine call."
  (let* ((suite (cond ((null suite) 'all)
                      ((stringp suite) (intern suite))
                      (t suite)))
         (job-id (or (and (stringp job) (not (string-empty-p job)) job)
                     (format "provider-check-%s" (harness-uuid))))
         (started (harness-provider-check-start model suite embedding-model job-id
                                                options)))
    (list :job job-id
          :model model
          :suite suite
          :total (harness-provider-check-job-total started)
          :options (harness-provider-check-job-options started)
          :estimate (harness-provider-check--estimate
                     model (harness-provider-check-job-plan started))
          :checks (harness-provider-check--plan-summary
                   (harness-provider-check-job-plan started)))))

(harness-defmethod provider/check-cancel (job)
  "Cancel the live provider check JOB; non-nil when it was running."
  (and (stringp job) (harness-provider-check-cancel job) t))

;;;; Following a job

(harness-declare-event 'provider-check/started
                       "(JOB MODEL SUITE TOTAL CHECKS ESTIMATE) before the first check of JOB runs.")
(harness-declare-event 'provider-check/result
                       "(JOB RESULT COMPLETED TOTAL) after each check of JOB settles.")
(harness-declare-event 'provider-check/finished
                       "(JOB MODEL RESULTS SUMMARY) when JOB ends, cancelled or done.")

(defvar harness-acp-extra-events nil)
(add-to-list 'harness-acp-extra-events 'provider-check/started)
(add-to-list 'harness-acp-extra-events 'provider-check/result)
(add-to-list 'harness-acp-extra-events 'provider-check/finished)

(defun harness-provider-check--init ()
  "Cancel checks that the code a reload replaces would leave half-run."
  (dolist (id (hash-table-keys harness-provider-check--jobs))
    (harness-provider-check-cancel id)))

(harness-define-module 'provider-check
  :doc "Live checks of a provider's contract and a model's harness skills, run from the harness."
  :requires '(provider)
  :init #'harness-provider-check--init)

(provide 'harness-provider-check)
;;; harness-provider-check.el ends here
