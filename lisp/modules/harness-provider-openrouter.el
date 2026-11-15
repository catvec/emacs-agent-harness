;;; harness-provider-openrouter.el --- OpenRouter provider and price-aware endpoint pinning  -*- lexical-binding: t; -*-

;;; Commentary:

;; OpenRouter speaks the OpenAI chat completions API, so the transport,
;; the streaming parser, the tool loop, pricing of usage and the retry
;; machinery come from the rest of the harness.  What lives here is
;; everything that is OpenRouter's own: its request fields (the
;; `provider' routing object, `service_tier', `session_id',
;; `usage.include', the `reasoning' object and `max_tokens'), how its
;; answers say which endpoint served a request, the metadata its errors
;; carry, and -- behind an opt-in policy that is off by default -- which
;; endpoint a session may use and what it may cost.
;;
;; The shared transport (`harness-provider-openai') knows none of that.
;; It reads a `:dialect' plist with hooks -- headers, extra body fields,
;; a chunk reader, an error-detail reader, a response audit, and the
;; state an answer reports -- which this module fills in for its own
;; endpoints.  Plain OpenAI, a local server and a custom
;; OpenAI-compatible endpoint get the body they always got and never
;; reach this module; see "Boundary" in docs/openrouter-pinning.md and
;; the negative tests in harness-provider-openrouter-test.el.

;;; The policy
;;
;; `harness-openrouter-routing' is nil by default.  nil means the
;; provider behaves exactly as it always did: no `provider' object, no
;; catalogue request of this module's, no pin.
;;
;; When it is set (and `:enabled' is on), it names one exact model, the
;; providers allowed to serve it, the most the operator is willing to
;; pay, and retry bounds.  Every price it compares is read from
;; OpenRouter's catalogue when the decision is made: `:max-price' is a
;; spending limit, never a claim about what a provider charges.  A new
;; session gets the cheapest allowed endpoint whose current catalogue
;; price is inside the limits; the choice is stored on the session and
;; every later request is restricted to it.  Nothing is switched
;; automatically: a pin that stops qualifying pauses the session,
;; because a switch is a cache-cold transition and so is the user's
;; decision.
;;
;; Every dispatch of a pinned session checks the policy again -- that
;; the pinned provider is still allowed and the pin still the exact
;; endpoint it was made on, that the price the pin recorded is inside
;; the current limits, and that the catalogue reading is fresh -- and
;; pauses rather than sending.  It never falls back: a pinned session is
;; guarded from `harness-fallback' too, so running out of quota or money
;; stops the turn instead of moving a cache-cold conversation to a model
;; the policy never allowed.
;;
;; The catalogue read is asynchronous, so the policy is read again
;; immediately before the body is built, and that reading -- not the one
;; the dispatch began with -- is the only one the request's fields come
;; from (`harness-openrouter--sending').  A policy disabled, removed or
;; otherwise changed while a request was in flight refuses it with
;; `policy-changed'; the next request is prepared afresh under the policy
;; then in force.  Sending the old request would send under a policy the
;; operator has replaced, and silently choosing again under the new one
;; would be a fallback to a provider the old policy never authorised.
;;
;; A retry is a send like any other, so it goes through the same check.
;; Which is why retrying is not decided here: the shared retry layer
;; (`harness-retry') owns the bounds, the wait, the counting and the
;; repeating for every provider, and this module says only what its
;; requests need (`harness-openrouter--retry-policy'): `:count-sends',
;; because a request this policy governs must be authorised -- pin,
;; price, privacy, catalogue -- every time it is sent, and so the lower
;; layer never replays one it did not authorise.  `harness-retry-send'
;; counts the sends at the dispatch and measures the request from its
;; first one; a send the shared bounds no longer allow is refused there,
;; not converted into another request.  A failure this provider's typed
;; codes say no identical request can pass is decoded to the shared kind
;; `permanent', so the turn ends at once instead of being retried
;; unchanged.
;;
;; What authorised a send travels with the request.  The dispatch records
;; the checked policy and the exact pinned route in the request's own
;; state (`harness-retry-authorise'), and the shared layer hands that back
;; in the request's `done' event.  A repeat is therefore a repeat of
;; *that* request: its own count and clock, its own endpoint, and the
;; policy that checked it -- so a policy edited, disabled or removed
;; while it was in flight refuses the repeat (`policy-changed') instead of
;; re-selecting under the new one or being sent unrestricted.  A recap or
;; a judge's call made for the same session is a request of its own, with
;; its own state, so it neither spends nor resets the step's budget.
;;
;; A configured policy is not nil, and the two kinds of off are not the
;; same: nil is the legacy pass-through for a request started under it
;; (`nil' above), while a policy with `:enabled' off refuses every request
;; it would otherwise govern and sends nothing.  Rolling back to nil
;; deliberately un-governs the *next* request; it never un-governs one
;; already sent, whose repeat is refused if it is still being retried.
;;
;; The privacy side is not a schema here.  Requests always carry
;; `data_collection: "deny"' and `zdr: true', and the operator's
;; provider policy -- DeepInfra and Cohere, nothing in China, US, Canada
;; and the EU acceptable -- is a documented decision about the
;; allowlist, with its sources in docs/openrouter-pinning.md.  `zdr:
;; true' is a routing control, not a proof of strict zero retention:
;; OpenRouter documents that it can include Safety Retention endpoints
;; depending on account settings, so the distinction is written down
;; rather than asserted to be zero by this module.
;;
;; A listing whose rate depends on the time of the week is refused
;; rather than read: the top-level figure is only the rate outside its
;; windows, and which window a request lands in is not something this
;; module reads.  A discount needs no code of its own -- the catalogue
;; lists the discounted rate and the sort reads it -- so a promotional
;; rate winning while it lasts and losing when it ends is the ordinary
;; behaviour of filter-then-cheapest, not a special case.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-retry)

(defvar harness-fallback-guard-functions)
(declare-function harness-fallback-refusal "harness-fallback")

;;;; Customisation

(defcustom harness-openrouter-base-url "https://openrouter.ai/api/v1"
  "Base URL of OpenRouter's OpenAI-compatible API."
  :type 'string :group 'harness)

(defcustom harness-openrouter-api-key-env "OPENROUTER_API_KEY"
  "Environment variable that holds the OpenRouter key."
  :type 'string :group 'harness)

(defcustom harness-openrouter-list-models t
  "Whether this provider lists OpenRouter's model catalogue.
The listing is public; like any hosted service, it lists nothing at all
until a key or other configuration is present
\(`harness-openai--configured-p')."
  :type 'boolean :group 'harness)

(defcustom harness-openrouter-routing nil
  "Opt-in price-aware endpoint policy for one OpenRouter model; nil is off.
nil (the default) leaves OpenRouter as it was: no `provider' object, no
catalogue request of this module's, no pin, no audit of the answer's
endpoint.  When set it is a plist:

  :enabled    t to let the policy route requests.  Without it a
              configured policy still allows nothing: it is a policy,
              not an activation.
  :model      the exact model the policy is for, e.g.
              \"deepseek/deepseek-v4.1-flash-1017\".  Only
              \"openrouter:MODEL\" is routed by it.
  :providers  the providers allowed to serve it, by the name the
              catalogue gives them, e.g. (\"DeepInfra\" \"Cohere\").
              They are the allowlist, and the order they are written in
              decides nothing: an endpoint of any other provider is
              never a candidate, however cheap it is, and among those
              allowed the cheapest that fits is chosen.
  :max-price  the most this policy is willing to pay, in US dollars per
              million tokens: (:prompt N :completion N :cache-read N).
              A spending limit, not a claim about a provider's rate --
              every price it is compared with is read from OpenRouter's
              catalogue at the time of the decision.
  :freshness  seconds a catalogue reading may be old at dispatch.

There is no retry bound and no output limit here: how often and how
long a failed request is tried again is the shared retry layer's
(`harness-retry-max-attempts', `harness-retry-delay',
`harness-retry-max-seconds' and the rest), the same for every provider,
and what a request asks a model to write is the request's own
`:max-tokens' (see `harness-provider-max-output-tokens' for a ceiling
on all of them).  This policy decides who serves a request and what it
may cost, and nothing else.

Once a session is pinned, every send is checked again: the pinned
provider still allowed, the pin still the identity it was vetted as, the
price it recorded still inside the limits, and the catalogue still
fresh.  A send that fails is offered to the shared retry layer like any
other provider's, and a repeat of it is a send like any other: it is
checked again before it goes out, and refused -- with the bound or the
change that stopped it -- if the answer now differs.

Selection reads the model's current catalogue and considers the
endpoints of `:providers' only.  For each provider the exact endpoint
must be unambiguous: one standard-tier record of this model, with no
regional or tier sibling the catalogue could route to instead.  The
cheapest one whose prompt, completion and cache-read prices are all at
or under `:max-price' is chosen; its exact tag, provider name and tier
are stored on the session.  A listing that cannot be read -- absent,
ambiguous, another model, a missing or malformed price, a price that
varies by the time of the week, a component the limits do not cover --
blocks the decision rather than being dropped, because `cannot read
this price' is not `this price is too high', and dropping it would
quietly pick the next provider.

Once a session is pinned every dispatch checks the policy again -- that
the pin's provider is still allowed and the pin still the identity it
was vetted as, that the price the pin recorded is inside the current
limits, and that the catalogue reading is fresh -- and pauses the
session when any of it fails.  It never chooses another endpoint: a
switch is the user's (`harness-openrouter-switch').  A session this
policy routes is also guarded from `harness-fallback': running out of
quota, out of money or out of anything else stops the turn instead of
moving a cache-cold conversation to a model the policy never allowed.

No provider's price is ever written into this option: the operator's
limits are the only numbers here.  Where those numbers come from -- for
example that they match a rate the operator picked from a model owner's
published list -- is a comment in the operator's own configuration, not
something the harness reads.
Every field a check needs must be present and well formed: a policy
with a hole blocks rather than guesses.  See
`harness-openrouter-routing-validate' and docs/openrouter-pinning.md."
  :type '(choice (const :tag "Off" nil) (plist :tag "Policy"))
  :group 'harness)

(defcustom harness-openrouter-catalogue-ttl 900
  "Seconds one shared reading of a model's endpoint catalogue is reused.
The reading is the harness process's, not a session's: every session, a
pinned session's revalidation, a hand switch and the harness's own small
calls -- the permission judge above all -- are answered from it.  So the
catalogue is read about once per this many seconds, not once per caller,
and a lookup made while the reading is younger than this spends no
request at all (`harness-openrouter--reading-for').

This is not the bound on how old a reading may be when a price is
decided from it: that is the policy's `:freshness', and nothing here
extends it.  A reading past this is read again, once, by whichever
caller asks first -- everyone who asks meanwhile shares that read
\(`harness-openrouter--reading-of') -- and is served while it is read,
when `:freshness' admits it.  A re-read that fails leaves the last
reading in place; it may still decide a price only while `:freshness'
admits it, and the dispatch that uses it says so.

Nothing a session does forces a read.  An explicit invalidation
\(`harness-openrouter-catalogue-invalidate') drops the reading and reads
it now, which is what a person who knows a price changed asks for."
  :type 'integer :group 'harness)

(defcustom harness-openrouter-catalogue-timeout 20
  "Seconds a fetch of the endpoint catalogue may take."
  :type 'integer :group 'harness)

(defcustom harness-openrouter-catalogue-ephemeral-wait 5
  "Seconds a one-off call waits for a catalogue reading it does not have.
The harness's own small calls -- the permission judge, a summary, a
title -- have a budget of their own, and that budget is about the model's
answer, not about this module's bookkeeping.  A catalogue read that
stalls can take `harness-openrouter-catalogue-timeout' plus the
transport's watchdog, which is longer than a judge's whole budget: the
judge would then report no verdict for a reason that is not the call it
was asked about.

So a one-off call (`:ephemeral') is answered from the reading in hand and
waits at most this long for one it does not have.  Past it, the call is
refused with `catalogue-unavailable' and the shared read carries on in the
background, so the next call is answered.  Nothing is allowed by the
refusal: the permission chain treats it as a call with no verdict, which
is what it already does with a judge that could not answer."
  :type 'number :group 'harness)

(defcustom harness-openrouter-catalogue-retry-attempts 5
  "Background re-reads of a catalogue whose refresh failed.
After a failed refresh the catalogue is read again in the background, so
the next session does not have to be the one that pays for it.  The
re-reads stop after this many per failure episode, and a successful one
ends the episode.  They never send a request, choose an endpoint or
answer a session: a session is answered only when it asks."
  :type 'integer :group 'harness)

(defcustom harness-openrouter-catalogue-retry-delay 5
  "Seconds before the first background re-read of a failed catalogue.
It is also the window in which a session is answered from the last
reading without trying the catalogue again: an outage costs one failed
request, not one for every session that starts during it."
  :type 'number :group 'harness)

(defcustom harness-openrouter-catalogue-retry-max-delay 300
  "Longest wait between background re-reads of a failed catalogue.
Each re-read that fails waits twice as long as the one before, up to
this, and the number of them is bounded by
`harness-openrouter-catalogue-retry-attempts'."
  :type 'number :group 'harness)

;;;; State

(defconst harness-openrouter--route-key :openrouter-route
  "Key of the pinned route in a session's `ext'.")

(defun harness-openrouter--reading-age (reading)
  "Return how many seconds ago READING was read, or nil for no reading."
  (when (and (listp reading) (numberp (plist-get reading :at)))
    (max 0 (- (float-time) (plist-get reading :at)))))


(defvar harness-openrouter--catalogue (make-hash-table :test 'equal)
  "Model id -> (:at FLOAT :endpoints LIST), the last reading of each catalogue.
It is the process's, not a session's: every session of the model is
answered from the same reading, and one reading is what a burst of new
sessions and a pinned session's revalidation share.  A reading is stored
only when a fetch settles, and it is replaced only by a later reading, so
a failed refresh leaves the last usable one in place.")

(defvar harness-openrouter--fetching (make-hash-table :test 'equal)
  "Model id -> promise of an in-flight catalogue reading.
It is the reading promise every concurrent caller shares
\(`harness-openrouter--reading-of'), not the bare fetch: a second caller
must be answered with the same shape and the same `:at' as the first.")

(defvar harness-openrouter--catalogue-failures (make-hash-table :test 'equal)
  "Model id -> plist of the failure episode of its catalogue.
`:at' when the last refresh failed, `:error' what it failed with,
`:attempts' how many re-reads have been spent, `:next-at' when the next
one is due, `:timer' the timer that will start it, and `:invalidated'
when the episode began with an explicit invalidation rather than with a
failed read.  A successful read removes the entry, which is what ends the
episode.

The episode is what keeps an outage from becoming a retry storm: while
one is live, an ordinary lookup does not read the catalogue again -- it
is answered from the last reading while `:freshness' admits it -- and
the background re-reads are the only reads, bounded by
`harness-openrouter-catalogue-retry-attempts' with a doubling delay.

A read that fails while an episode is live keeps the attempts already
spent, so an outage costs the same handful of requests however often a
person invalidates a reading: an invalidation drops the *reading*, never
the bound.")

(defvar harness-openrouter--invalidations (make-hash-table :test 'equal)
  "Model id -> the number of explicit invalidations it has had.
`harness-openrouter-catalogue-invalidate' bumps it.  A read that began
before the bump answers a reading of the old number and is not stored
over the one the invalidation asked for, so a slow read started for a
session cannot quietly undo an invalidation made meanwhile.")

(defvar harness-openrouter--ephemeral nil
  "Non-nil while a one-off call is being prepared.
Bound around the dispatch of a request that carries `:ephemeral',
which is the harness's own small call -- the permission judge, a
summary, a title.  Such a call has a budget of its own that is about
the model's answer, so it does not wait on this module's catalogue
bookkeeping for longer than `harness-openrouter-catalogue-ephemeral-wait'
(`harness-openrouter--patient-p').")

(defvar harness-openrouter--sending nil
  "The checked routing policy of the request being built, or nil.
Bound around the transport call by `harness-openrouter--dispatch', after
the policy was checked and its route put on the request, so the headers
and the body of that one request describe the policy that authorised
it.  Nothing a handler does meanwhile can change what it carries.")

(harness-declare-event 'openrouter/route-selected
                       "(SESSION-ID ROUTE) when a session is pinned to an endpoint.")
(harness-declare-event 'openrouter/route-paused
                       "(SESSION-ID REASON DETAIL) when a pinned session may not send.")
(harness-declare-event 'openrouter/response-mismatch
                       "(SESSION-ID DETAIL) when an answer came from another endpoint.")
(harness-declare-event 'openrouter/catalogue-degraded
                       "(SESSION-ID READING DETAIL) when a dispatch uses a reading whose refresh failed.")
(harness-declare-event 'openrouter/catalogue-revalidating
                       "(SESSION-ID READING DETAIL) when a dispatch uses a reading a fresh one is being read beside.")

;;;; Prices, exactly
;;
;; The catalogue gives prices in US dollars per *token* as decimal
;; strings, and a policy gives its maximum in US dollars per *million*
;; tokens.  Emacs floats are binary, so a decimal such as 0.098 has no
;; exact float value and comparing through one puts rounding at the
;; boundary: a limit can end up under the price it was meant to admit,
;; or above a price it was meant to exclude.  Every price here is
;; therefore read as an exact decimal -- a numerator over a power of
;; ten, both exact integers -- and every comparison cross-multiplies.
;; Nothing is rounded, in either direction, at any precision the text
;; names; text too long or too finely scaled to be a price is refused as
;; unreadable, which blocks, and never rounds into acceptance.

(defconst harness-openrouter--decimal-length 80
  "Longest price text that is read, in characters.
A longer string is not a price list's figure, and reading it would only
build a very large integer: it is refused as unreadable, which blocks
rather than letting something odd through.")

(defconst harness-openrouter--decimal-places 40
  "Most fractional decimal places a price may name, or an exponent scale.
A price finer than this is refused as unreadable rather than rounded.")

(defun harness-openrouter--decimal (value)
  "Return VALUE as an exact decimal, a cons (NUMERATOR . DENOMINATOR), or nil.
VALUE is a decimal string, an integer, or a float taken as the decimal
it prints as.  Plain decimals (\"0.000000098\") and exponent forms
\(\"9.8e-08\", which is how a float prints) are read exactly, at as
many fractional places as the text names, up to
`harness-openrouter--decimal-places'.  A negative value, a non-number,
an empty string, a value with a larger exponent, or one too long to be
a price is nil: unreadable, never zero.  No step goes through floating
point, so a limit and the price it bounds compare exactly whatever
their precision."
  (let ((text (cond ((integerp value) (and (>= value 0) (number-to-string value)))
                    ((floatp value)
                     ;; The decimal it prints as, not its binary value:
                     ;; 0.098 reads as 98/1000, which is the limit the
                     ;; policy's author wrote.
                     (and (>= value 0) (number-to-string value)))
                    ((and (stringp value) (not (string-empty-p value))) value))))
    (when (and text
               (<= (length text) harness-openrouter--decimal-length)
               (string-match-p "\\`[0-9]*\\(?:\\.[0-9]*\\)?\\(?:[eE][-+]?[0-9]+\\)?\\'" text)
               (string-match-p "[0-9]" text))
      (let* ((mark (progn (string-match "\\`[^eE]*" text) (match-end 0)))
             (mantissa (substring text 0 mark))
             (exponent (if (< mark (length text))
                           (string-to-number (substring text (1+ mark)))
                         0))
             (dot (string-match-p "\\." mantissa))
             (whole (or (and dot (substring mantissa 0 dot)) (and (not dot) mantissa) ""))
             (fraction (or (and dot (substring mantissa (1+ dot))) ""))
             ;; Leading zeros cost nothing and could make the numerator
             ;; huge; only significant digits matter.
             (digits (string-to-number (concat whole fraction)))
             (places (- (length fraction) exponent)))
        (when (and (<= (abs exponent) harness-openrouter--decimal-places)
                   (<= (abs places) harness-openrouter--decimal-places))
          (cond ((zerop digits) '(0 . 1))
                ((>= places 0) (cons digits (expt 10 places)))
                (t (cons (* digits (expt 10 (- places))) 1))))))))

(defun harness-openrouter--decimal-p (value)
  "Non-nil when VALUE reads as an exact price by `harness-openrouter--decimal'."
  (and (consp (harness-openrouter--decimal value)) t))

(defun harness-openrouter--decimal-compare (a b)
  "Compare exact decimals A and B: -1, 0 or 1.  Either may be nil."
  (let ((left (* (car a) (cdr b)))
        (right (* (car b) (cdr a))))
    (cond ((< left right) -1) ((> left right) 1) (t 0))))

(defun harness-openrouter--decimal<= (a b)
  "Non-nil when exact decimal A is at or under exact decimal B."
  (and a b (<= (harness-openrouter--decimal-compare a b) 0)))

(defun harness-openrouter--decimal> (a b)
  "Non-nil when exact decimal A is over exact decimal B."
  (and a b (> (harness-openrouter--decimal-compare a b) 0)))

(defun harness-openrouter--decimal-scale (value places)
  "Return exact decimal VALUE multiplied by 10^PLACES, or nil."
  (when value
    (if (>= places 0)
        (cons (* (car value) (expt 10 places)) (cdr value))
      (cons (car value) (* (cdr value) (expt 10 (- places)))))))

(defun harness-openrouter--limit-per-token (usd-per-million)
  "Return USD-PER-MILLION, a policy maximum, as exact US dollars per token.
The division is exact, so no rounding decides whether a price is over the
limit.  Nil when it is not a decimal, which validation refuses."
  (harness-openrouter--decimal-scale (harness-openrouter--decimal usd-per-million) -6))

(defun harness-openrouter--price-per-token (value)
  "Return VALUE, a catalogue price in US dollars per token, exactly.
A value that is missing or malformed is nil, which is unknown and never
zero."
  (harness-openrouter--decimal value))

(defun harness-openrouter--usd-per-million (per-token)
  "Return PER-TOKEN, an exact per-token price, as USD per million, a float.
This is for a hint, a recorded route or the wire, never a comparison."
  (when (consp per-token)
    (float (/ (* (car per-token) 1000000.0) (cdr per-token)))))

;;;; Reading the catalogue

(defun harness-openrouter--endpoint-record (entry)
  "Return what one catalogue ENTRY says, or nil when it names no endpoint.
Prices are exact decimals in US dollars per token; a field the catalogue
omits stays nil, which the checks read as unknown, never as zero.  The
entry is also kept whole as `:entry', so a check can see a billable
component this module does not price."
  (when (listp entry)
    (let* ((tag (plist-get entry :tag))
           (provider (plist-get entry :provider_name))
           (model (or (plist-get entry :model_id) (plist-get entry :model)))
           (tier (plist-get entry :service_tier))
           (quantization (plist-get entry :quantization))
           (pricing (plist-get entry :pricing)))
      (when (and (stringp tag) (not (string-empty-p tag))
                 (stringp provider) (not (string-empty-p provider))
                 (stringp model))
        (list :tag tag :provider provider :model model
              :tier (and (stringp tier) tier)
              :quantization (and (stringp quantization) quantization)
              :prompt (harness-openrouter--price-per-token (plist-get pricing :prompt))
              :completion (harness-openrouter--price-per-token (plist-get pricing :completion))
              :cache-read (harness-openrouter--price-per-token
                           (plist-get pricing :input_cache_read))
              :discount (harness-openrouter--decimal (plist-get pricing :discount))
              :overrides (plist-get pricing :overrides)
              :pricing (and (listp pricing) pricing)
              :context (plist-get entry :context_length)
              :status (plist-get entry :status)
              :supported-parameters (let ((params (plist-get entry :supported_parameters)))
                                      (and (listp params) (cl-every #'stringp params)
                                           (copy-sequence params)))
              :safety-retention (plist-get entry :safety_retention)
              :entry entry)))))

(defun harness-openrouter-parse-endpoints (json)
  "Return the endpoint records of a catalogue JSON answer.
A record is `harness-openrouter--endpoint-record''s.  A top-level
`error', a missing model id or a missing endpoint list signals
`harness-error', because none of those is a reading a price can be
judged from."
  (let* ((error-object (and (listp json) (plist-get json :error)))
         (data (plist-get json :data)))
    (when error-object
      (signal 'harness-error
              (list (format "OpenRouter catalogue error: %s"
                            (or (and (listp error-object) (plist-get error-object :message))
                                "unknown")))))
    (unless (and (listp data) (stringp (plist-get data :id)))
      (signal 'harness-error (list "OpenRouter catalogue named no model")))
    (let ((entries (plist-get data :endpoints))
          (model (plist-get data :id)))
      (unless (listp entries)
        (signal 'harness-error (list "OpenRouter catalogue listed no endpoints")))
      (delq nil (mapcar (lambda (entry)
                          (let ((record (harness-openrouter--endpoint-record entry)))
                            (when record
                              ;; An entry that names another model is not this
                              ;; model's endpoint, whatever else it says.
                              (unless (equal (plist-get record :model) model)
                                (setq record (plist-put record :model-mismatch t)))
                              record)))
                        entries)))))

(defun harness-openrouter--catalogue-url (model)
  "Return the catalogue URL of MODEL's endpoints."
  (concat (string-remove-suffix "/" harness-openrouter-base-url)
          "/models/" model "/endpoints"))

(defun harness-openrouter--fetch-catalogue (model)
  "Fetch MODEL's endpoint catalogue; return a promise of its records."
  (let ((endpoint (harness-openrouter--endpoint)))
    (harness-then
     (condition-case err
         (harness-http-request-json
          (harness-openrouter--catalogue-url model)
          :headers (harness-openai--headers endpoint (harness-openai--api-key endpoint))
          :timeout harness-openrouter-catalogue-timeout)
       (error (harness-rejected err)))
     (lambda (json)
       (condition-case err
           (harness-openrouter-parse-endpoints json)
         (error (harness-rejected err)))))))

(defun harness-openrouter--catalogue-recovered (model)
  "End MODEL's catalogue failure episode, if it had one.
A reading that settled is the end of the episode: its timer is cancelled
and its record dropped, so the next failure starts a fresh bound rather
than inheriting the attempts of an outage that is over."
  (let ((episode (gethash model harness-openrouter--catalogue-failures)))
    (when episode
      (when (timerp (plist-get episode :timer))
        (cancel-timer (plist-get episode :timer)))
      (remhash model harness-openrouter--catalogue-failures))))

(defun harness-openrouter--invalidation (model)
  "Return the number of explicit invalidations MODEL's catalogue has had."
  (or (gethash model harness-openrouter--invalidations) 0))

(defun harness-openrouter--reading-of (model)
  "Return a promise of one reading of MODEL's catalogue, fetching once.
Every caller that asks while the fetch is in flight shares the same
promise, so it is answered with the same shape -- `:at' and `:endpoints'
-- and the same timestamp; the alternative is one caller getting a bare
list of endpoint records and failing its checks for no reason.  A reading
that settles is stored for every session of the model, and ends any
failure episode.  A failed fetch rejects the shared promise for all of
them and is recorded as a failure episode with a bounded background
re-read behind it; the last reading, if there is one, is left in place
for a policy that still admits it (`harness-openrouter--reading-for').
A reading is stored only when it settles, so a fetch that answers
immediately is never stored settled."
  (or (gethash model harness-openrouter--fetching)
      (let* ((generation (harness-openrouter--invalidation model))
             (fetch (harness-openrouter--fetch-catalogue model))
             (reading (harness-then
                       fetch
                       (lambda (records)
                         (remhash model harness-openrouter--fetching)
                         (let ((reading (list :at (float-time) :endpoints records)))
                           ;; A read that began before an invalidation is a
                           ;; reading of the catalogue that was replaced: it
                           ;; answers its own callers, and is not stored over
                           ;; the one the invalidation asked for.
                           (when (= generation (harness-openrouter--invalidation model))
                             (puthash model reading harness-openrouter--catalogue)
                             (harness-openrouter--catalogue-recovered model))
                           reading))
                       (lambda (err)
                         (remhash model harness-openrouter--fetching)
                         (harness-openrouter--note-catalogue-failure model err)
                         (harness-resignal err)))))
        (unless (harness-promise-settled-p reading)
          (puthash model reading harness-openrouter--fetching))
        reading)))

(defun harness-openrouter--catalogue-delay (attempts)
  "Return the seconds to wait before background re-read ATTEMPTS.
The first re-read waits `harness-openrouter-catalogue-retry-delay' and
each one after it waits twice as long, up to
`harness-openrouter-catalogue-retry-max-delay'.  The growth is bounded so
an outage costs a handful of requests rather than one per tick."
  (let ((delay (* (max 0 harness-openrouter-catalogue-retry-delay)
                  (expt 2 (max 0 attempts)))))
    (min (max 0 harness-openrouter-catalogue-retry-max-delay) delay)))

(defun harness-openrouter--schedule-catalogue-retry (model)
  "Schedule the next background re-read of MODEL's catalogue, if any is due.
The re-reads are a burst and then a heartbeat.  The first
`harness-openrouter-catalogue-retry-attempts' of an episode are the burst,
at a doubling delay, so an outage that ends quickly is over within seconds
of it.  After the burst the episode keeps one slow probe at
`harness-openrouter-catalogue-retry-max-delay' until a read settles: a
catalogue that was unreachable for an hour is read again by itself rather
than staying broken until a person asks, and one request per interval is
what keeps that probe from being a storm.

One timer per model, always replacing the previous one, so a failure that
arrives while another re-read is pending moves the schedule rather than
adding to it.

The timer carries the tables it was scheduled against.  A timer runs
later, in whatever context is current then, and a re-read must write the
catalogue it belongs to and count its attempts against the episode it
belongs to -- never against a table that happens to be bound at that
moment."
  (let* ((episode (gethash model harness-openrouter--catalogue-failures))
         (attempts (or (plist-get episode :attempts) 0))
         (delay (harness-openrouter--catalogue-delay attempts))
         (tables (list harness-openrouter--catalogue
                       harness-openrouter--fetching
                       harness-openrouter--catalogue-failures)))
    (when episode
      (when (timerp (plist-get episode :timer))
        (cancel-timer (plist-get episode :timer)))
      (puthash model
               (plist-put (plist-put (copy-sequence episode) :next-at (+ (float-time) delay))
                          :timer
                          (run-at-time
                           delay nil
                           (lambda ()
                             (let ((harness-openrouter--catalogue (nth 0 tables))
                                   (harness-openrouter--fetching (nth 1 tables))
                                   (harness-openrouter--catalogue-failures (nth 2 tables)))
                               (harness-openrouter--catalogue-retry model)))))
               harness-openrouter--catalogue-failures))))

(defun harness-openrouter--catalogue-retry (model)
  "Read MODEL's catalogue again in the background, and account for it.
A reading that settles ends the failure episode
\(`harness-openrouter--catalogue-recovered'); one that fails is noted by
the same handler that notes a session's own failure, which schedules the
next re-read.  Nothing is chosen, sent or announced to a session here:
this only makes the next lookup more likely to find a reading.

Every re-read of an episode is counted, the slow probes past the burst
included: the count is what a status reports as the attempts spent, and
what tells the burst from the probe."
  (let ((episode (gethash model harness-openrouter--catalogue-failures)))
    (when episode
      (puthash model (plist-put (copy-sequence episode) :timer nil)
               harness-openrouter--catalogue-failures)
      (puthash model
               (plist-put (gethash model harness-openrouter--catalogue-failures)
                          :attempts (1+ (or (plist-get episode :attempts) 0)))
               harness-openrouter--catalogue-failures)
      (harness-then (harness-openrouter--reading-of model)
                    (lambda (reading) reading)
                    (lambda (_err) nil)))))

(defun harness-openrouter--note-catalogue-failure (model err)
  "Record that MODEL's catalogue could not be read, and plan a re-read.
The last reading, if there is one, is left in place: whether it may still
be used is the policy's `:freshness' question, not this function's.  The
failure is remembered with what it was, so a status can say what is wrong
and a session can be told why it is running on an older reading."
  (let ((episode (gethash model harness-openrouter--catalogue-failures)))
    (when (timerp (plist-get episode :timer))
      (cancel-timer (plist-get episode :timer)))
    (puthash model
             (list :at (float-time)
                   :error err
                   :attempts (or (plist-get episode :attempts) 0)
                   :timer nil)
             harness-openrouter--catalogue-failures)
    (harness-openrouter--schedule-catalogue-retry model)))

(defun harness-openrouter--catalogue (model &optional refresh)
  "Return a promise of MODEL's endpoint catalogue, read at `:at'.
A reading inside `harness-openrouter-catalogue-ttl' is answered as it is.
REFRESH is the explicit invalidation this accessor offers its callers: it
reads again now (`harness-openrouter-catalogue-invalidate' is the same,
with the bookkeeping a person's call needs).  An ordinary lookup -- no
REFRESH -- never forces a read, and never adds one to a live failure
episode either: it is answered from the reading in hand, and the bounded
background re-reads are what bring it up to date.

A failed read rejects: this is the raw accessor, and a stale reading is
never evidence that a price changed.  Whether a reading may still be used
after a failed refresh is the policy's question and is decided in
`harness-openrouter--reading-for', which knows the `:freshness' bound."
  (let ((cached (gethash model harness-openrouter--catalogue))
        (episode (gethash model harness-openrouter--catalogue-failures)))
    (cond
     ((and cached (not refresh) (not (harness-openrouter--reading-due-p cached)))
      (harness-resolved cached))
     ((and (not refresh) episode)
      ;; The background re-reads own the next read, so an ordinary lookup
      ;; does not add one to them.
      (if cached
          (harness-resolved cached)
        (harness-rejected (plist-get episode :error))))
     (t (harness-openrouter--reading-of model)))))

(defun harness-openrouter-catalogue-invalidate (&optional model)
  "Drop MODEL's shared catalogue reading, and read it again now.
MODEL defaults to the configured policy's.  This is the one explicit
invalidation this module offers, and what a person asks for when they know
a price changed: the reading is dropped, so nothing is decided from it,
and a read starts at once rather than waiting for
`harness-openrouter-catalogue-ttl' to pass.  Nothing a session does forces
a read, so this is the only path that does.

It is not a retry storm.  While an outage lasts, the read it starts fails
into the failure episode already running, which keeps the attempts it has
spent: the background re-reads stay bounded by
`harness-openrouter-catalogue-retry-attempts' however often this is
called.  It returns a promise of the reading, which rejects with what
failed.  A read that began before the call answers its own callers and is
not stored over the reading this asked for."
  (interactive)
  (let* ((model (or model (plist-get harness-openrouter-routing :model)))
         (episode (and model (gethash model harness-openrouter--catalogue-failures))))
    (unless model
      (error "No OpenRouter model to read the catalogue of"))
    (remhash model harness-openrouter--catalogue)
    (puthash model (1+ (harness-openrouter--invalidation model))
             harness-openrouter--invalidations)
    ;; The read this asks for is the next attempt of the episode it
    ;; belongs to, not a new one, so its failures are bounded with the
    ;; rest of the outage.
    (when (timerp (plist-get episode :timer))
      (cancel-timer (plist-get episode :timer))
      (puthash model (plist-put (copy-sequence episode) :timer nil)
               harness-openrouter--catalogue-failures))
    ;; A read already in flight is a reading of the catalogue that was just
    ;; replaced, so this does not adopt it: the invalidation starts a read
    ;; of its own, and the older one is answered to its own callers without
    ;; being stored (`harness-openrouter--reading-of').
    (remhash model harness-openrouter--fetching)
    (harness-openrouter--reading-of model)))

;;;; Policy validation

(defconst harness-openrouter--price-keys '(:prompt :completion :cache-read)
  "Prices every candidate and the policy's limits must name.
These are the three the policy compares, each in US dollars per million
tokens.  A catalogue listing may carry others (`input_cache_write',
`internal_reasoning', a per-request fee, an audio or image charge);
those are not compared, so a listing that prices them is
`harness-openrouter--unpriceable-components' and blocks rather than
being read as if they cost nothing.")

(defconst harness-openrouter--known-pricing-keys
  '(:prompt :completion :input_cache_read :discount :overrides)
  "The catalogue pricing keys this module reads.
`:prompt', `:completion' and `:input_cache_read' are compared against
`:max-price', `:discount' is recorded, and `:overrides' marks a rate
that varies by the time of the week.  Any other key is a billable
component this module cannot weigh.")

(defun harness-openrouter--providers-error (providers)
  "Return why PROVIDERS is not an allowlist of provider names, or nil."
  (cond
   ((not (and (listp providers) providers))
    "the policy names no provider")
   ((cl-some (lambda (name) (not (and (stringp name) (not (string-empty-p name)))))
             providers)
    "a provider name is empty or not a string")
   ((not (= (length providers) (length (delete-dups (copy-sequence providers)))))
    "a provider is named twice")))

(defun harness-openrouter--policy-error (policy)
  "Return why POLICY may not be used, a string, or nil when it is complete."
  (let ((model (plist-get policy :model))
        (limits (plist-get policy :max-price))
        (freshness (plist-get policy :freshness)))
    (cond
     ((not (listp policy)) "the policy is not a plist")
     ((not (and (stringp model)
                (string-match-p "\\`[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\\'" model)))
      "the policy names no exact model")
     ((harness-openrouter--providers-error (plist-get policy :providers)))
     ((not (and (listp limits) limits))
      "the policy names no maximum price to spend")
     ((cl-some (lambda (key) (not (harness-openrouter--decimal-p (plist-get limits key))))
               harness-openrouter--price-keys)
      "the maximum price is incomplete or not a plain decimal")
     ((not (and (numberp freshness) (>= freshness 0)))
      "the policy names no freshness bound"))))

(defun harness-openrouter-routing-validate (&optional policy)
  "Return nil when POLICY, or `harness-openrouter-routing', may be used.
A string says what is missing.  A nil policy is not an error: it is
simply off."
  (let ((policy (or policy harness-openrouter-routing)))
    (when policy (harness-openrouter--policy-error policy))))

(defun harness-openrouter-routing-p (&optional policy)
  "Non-nil when a routing POLICY is configured, valid or not."
  (and (or policy harness-openrouter-routing) t))

(defun harness-openrouter-routing-enabled-p (&optional policy)
  "Non-nil when the policy POLICY, default the configured one, routes.
That takes a configured policy, `:enabled' in it, and no missing field."
  (let ((policy (or policy harness-openrouter-routing)))
    (and (harness-json-true-p (plist-get policy :enabled))
         (null (harness-openrouter--policy-error policy))
         t)))

;;;; Selection
;;
;; The rule is a filter and a sort, and nothing else:
;;
;;   * only the endpoints of the policy's providers are candidates;
;;   * any whose fresh catalogue listing is dearer than `:max-price' in
;;     any component is dropped -- that is the most this policy spends;
;;   * the cheapest of what remains is chosen.
;;
;; Every price compared is the one OpenRouter's catalogue gives at the
;; time of the decision.  Nothing here reads a provider's price from the
;; policy: `:max-price' is a spending limit, and the catalogue is the
;; only source of what a provider charges.
;;
;; A candidate whose listing cannot be read at all -- absent, ambiguous,
;; another model, a missing or malformed price, a stale reading -- blocks
;; the decision instead of being dropped, because "I cannot read this
;; price" is not "this price is too high".  Dropping it would quietly
;; select the next provider, which is exactly the silent switch the
;; policy exists to prevent.

(defun harness-openrouter--fresh-p (policy at)
  "Non-nil when AT is within POLICY's freshness bound."
  (let ((freshness (plist-get policy :freshness)))
    (and (numberp at) (numberp freshness)
         (not (> (- (float-time) at) freshness)))))

(defun harness-openrouter--limits (policy)
  "Return POLICY's `:max-price' as exact per-token limits, or nil.
A plist of `:prompt', `:completion' and `:cache-read', each the exact
decimal US dollars per token the configured per-million figure names.
The division is exact, so a price at the limit is not over it and a
price above it is never admitted."
  (let ((most (plist-get policy :max-price)))
    (when (listp most)
      (let ((prices (mapcar (lambda (key)
                              (harness-openrouter--limit-per-token (plist-get most key)))
                            harness-openrouter--price-keys)))
        (and (cl-every #'consp prices)
             (list :prompt (nth 0 prices)
                   :completion (nth 1 prices)
                   :cache-read (nth 2 prices)))))))

(defconst harness-openrouter--tier-slugs
  '("priority" "fast" "turbo" "flex" "ultrafast" "highspeed" "prime")
  "The last slug segment of a service-tier endpoint, in providers' spellings.
OpenRouter documents `priority', `fast', `turbo' and `flex', and says a
provider may label its own priority endpoints (`highspeed', `prime').
A tag ending in one of these is read as a tier endpoint even when the
catalogue's own `service_tier' field does not say so.")

(defun harness-openrouter--tier-endpoint-p (record)
  "Non-nil when RECORD is a service-tier endpoint rather than a standard one.
The catalogue says so in `service_tier' (`flex', `priority'), and the
tag's last segment says so in the provider's own spelling."
  (let ((tag (plist-get record :tag))
        (tier (plist-get record :tier)))
    (or (and (stringp tier) (not (string-empty-p tier)))
        (and (stringp tag)
             (member (car (last (split-string tag "/"))) harness-openrouter--tier-slugs)
             t))))

(defun harness-openrouter--candidate (policy records provider)
  "Return the record of RECORDS that is PROVIDER's endpoint of POLICY's model.
Exactly one standard-tier record of this model may name PROVIDER.  A
second one -- a new region or a variant of the same endpoint -- is not
the endpoint the policy allowed, so two of them make the identity
ambiguous and this returns nil as well: an ambiguous identity is no
identity, and blocking is what keeps a new regional variant from joining
the allowed set silently.  A tier endpoint (`flex', `priority') is not
the standard one a provider's name selects; only tier endpoints leave
the provider unresolved too."
  (let* ((model (plist-get policy :model))
         (records (cl-remove-if-not (lambda (record)
                                      (and (equal (plist-get record :model) model)
                                           (equal (plist-get record :provider) provider)))
                                    records)))
    (let ((standard (cl-remove-if #'harness-openrouter--tier-endpoint-p records)))
      ;; Only one standard record of this model may be the provider: a
      ;; second one is a region or a variant, and neither is the endpoint
      ;; the policy allowed.  Tier records are never it.
      (and standard (null (cdr standard)) (car standard)))))

(defun harness-openrouter--candidates (policy records)
  "Return the allowed endpoints of POLICY in RECORDS, as candidate plists.
One per name in `:providers', in that order: `:provider', `:record' when
exactly one record is it, and `:reason' plus `:detail' when it cannot be
resolved."
  (mapcar (lambda (provider)
            (let ((record (harness-openrouter--candidate policy records provider)))
              (if record
                  (list :provider provider :record record)
                (list :provider provider
                      :reason 'unknown-endpoint
                      :detail (format "%s serves this model at no single exact standard endpoint"
                                      provider)))))
          (plist-get policy :providers)))

(defun harness-openrouter--prices-over (limits record)
  "Return the components of RECORD priced above LIMITS, as strings.
A price the record does not give is over: unknown is not free, and it is
not a reading either, so it never earns a place in the sort.  Every
comparison is exact, so a price equal to the limit is not over it and no
rounding admits a price above it."
  (let (over)
    (dolist (key harness-openrouter--price-keys)
      (let ((most (plist-get limits key))
            (price (plist-get record key)))
        (when (or (null price) (harness-openrouter--decimal> price most))
          (push (format "%s %s > %s" (substring (symbol-name key) 1)
                        (or (harness-openrouter--usd-per-million price) "unknown")
                        (harness-openrouter--usd-per-million most))
                over))))
    (nreverse over)))

(defun harness-openrouter--unpriceable-components (record)
  "Return the billable components of RECORD this policy cannot weigh.
The policy compares prompt, completion and cache-read against its
`:max-price'.  A listing that also prices something else -- a
per-request fee, an image, audio, a cache write, internal reasoning --
charges for a component the maximum does not bound, so it is not a
listing the policy can read as inside the maximum.  Nil when the listing
prices nothing but what is compared."
  (let ((pricing (plist-get record :pricing))
        (unknown nil))
    (when (listp pricing)
      (cl-loop for (key value) on pricing by #'cddr
               unless (memq key harness-openrouter--known-pricing-keys)
               when (and value (not (and (numberp value) (zerop value)))
                         (not (equal value "0")))
               do (push (format "%s" (substring (symbol-name key) 1)) unknown)))
    (nreverse unknown)))

(defun harness-openrouter--unreadable (record)
  "Return (REASON . DETAIL) when RECORD is not a price that can be read.
A listing whose rate depends on the time of the week is not one price:
the top-level figure is only the rate outside its override windows, and
which window a request lands in is not something this module reads.  It
blocks, like any other reading it cannot make.  So does a listing that
prices a component the limits do not cover, and one whose endpoint the
catalogue reports as unavailable (`:status' anything but zero)."
  (cond
   ((null record)
    (cons 'unknown-endpoint
          "is not listed for this model, or its listing is ambiguous"))
   ((plist-get record :model-mismatch)
    (cons 'model-mismatch "lists another model"))
   ((and (plist-get record :status)
         (not (and (numberp (plist-get record :status))
                   (zerop (plist-get record :status)))))
    (cons 'endpoint-unavailable
          (format "the catalogue reports status %s for it" (plist-get record :status))))
   ((plist-get record :overrides)
    (cons 'price-varies-by-time "prices by a window of the week"))
   ((or (null (plist-get record :cache-read))
        (cl-some (lambda (key) (null (plist-get record key))) harness-openrouter--price-keys))
    (cons 'price-unknown "gives no price for every component"))
   ((harness-openrouter--unpriceable-components record)
    (cons 'price-component-unknown
          (format "prices %s, which the maximum price does not cover"
                  (string-join (harness-openrouter--unpriceable-components record) ", "))))))

(defun harness-openrouter--standing (candidate limits)
  "Return CANDIDATE's standing against LIMITS, from its catalogue listing.
CANDIDATE is `harness-openrouter--candidates''s: a provider and the
record resolved for it, or why it could not be resolved.  A plist with
`:standing' one of:

  `eligible' -- its fresh listing is exact and no component is dearer
                than the limits; `:order' is the sort key
  `out'      -- its fresh listing is exact and some component is dearer,
                so it is known not to qualify
  `unknown'  -- its listing cannot be read, which says nothing about its
                price, so it blocks rather than being dropped

and `:provider', `:record', `:reason' and `:detail'."
  (let* ((provider (plist-get candidate :provider))
         (record (plist-get candidate :record))
         (unreadable
          (if record
              (harness-openrouter--unreadable record)
            (cons (or (plist-get candidate :reason) 'unknown-endpoint)
                  (or (plist-get candidate :detail) "is not listed"))))
         (over (and record (harness-openrouter--prices-over limits record))))
    (cond
     (unreadable
      (list :standing 'unknown :provider provider :record record
            :reason (car unreadable)
            :detail (format "%s %s" provider (cdr unreadable))))
     (over
      (list :standing 'out :provider provider :record record
            :reason 'over-max-price
            :detail (format "%s is over the maximum price: %s"
                            provider (string-join over ", "))))
     (t
      (list :standing 'eligible :provider provider :record record
            ;; One input token and one output token, in the same unit, so
            ;; the sort needs no guess at the traffic's mix; the cache-read
            ;; price breaks a tie, and the provider name makes the order
            ;; total.  The prices stay exact decimals;
            ;; `harness-openrouter--cheapest' compares them exactly.
            :order (list (harness-openrouter--decimal-sum
                          (plist-get record :prompt) (plist-get record :completion))
                         (plist-get record :cache-read)
                         provider))))))

(defun harness-openrouter--decimal-sum (&rest values)
  "Return the exact sum of exact decimals VALUES, or nil if any is unreadable."
  (when (cl-every #'consp values)
    (let ((denominator (apply #'cl-lcm (mapcar #'cdr values))))
      (cons (cl-loop for value in values
                     sum (* (car value) (/ denominator (cdr value))))
            denominator))))

(defun harness-openrouter--order< (a b)
  "Non-nil when sort key A orders before sort key B, exactly.
A key is (EXACT-SUM EXACT-CACHE-READ PROVIDER-STRING)."
  (cond
   ((not (= 0 (harness-openrouter--decimal-compare (nth 0 a) (nth 0 b))))
    (< (harness-openrouter--decimal-compare (nth 0 a) (nth 0 b)) 0))
   ((not (= 0 (harness-openrouter--decimal-compare (nth 1 a) (nth 1 b))))
    (< (harness-openrouter--decimal-compare (nth 1 a) (nth 1 b)) 0))
   (t (string< (nth 2 a) (nth 2 b)))))

(defun harness-openrouter--cheapest (standings)
  "Return the eligible STANDING with the smallest `:order', or nil.
The prices in `:order' compare exactly, and the key ends it, so the
comparison is total: two endpoints at the same price never depend on the
catalogue's order for which one wins."
  (car (sort (cl-remove-if-not (lambda (s) (eq (plist-get s :standing) 'eligible))
                               (copy-sequence standings))
             (lambda (a b) (harness-openrouter--order< (plist-get a :order)
                                                       (plist-get b :order))))))

(defun harness-openrouter-select (policy records read-at)
  "Choose the cheapest allowed endpoint among RECORDS read at READ-AT.
RECORDS are `harness-openrouter-parse-endpoints''s, read from
OpenRouter's catalogue at READ-AT.  Return (\=':ok t :provider NAME
:record RECORD :reading READ-AT) or (:ok nil :reason SYMBOL :detail
STRING).

Only the policy's providers are candidates, and each is resolved to one
exact standard endpoint of this model.  One whose fresh listing is
dearer than `:max-price' in any component is dropped; the cheapest of
the rest is chosen.  One whose listing cannot be read blocks the
decision, because that is not a reading about its price."
  (let ((problem (harness-openrouter--policy-error policy)))
    (cond
     (problem (list :ok nil :reason 'policy-invalid :detail problem))
     ((not (harness-openrouter--fresh-p policy read-at))
      (list :ok nil :reason 'catalogue-stale
            :detail (format "the endpoint catalogue was read %d s ago; the policy allows %s s"
                            (round (- (float-time) (or read-at 0)))
                            (plist-get policy :freshness))))
     (t
      (let* ((limits (harness-openrouter--limits policy))
             (standings (mapcar (lambda (candidate)
                                  (harness-openrouter--standing candidate limits))
                                (harness-openrouter--candidates policy records)))
             (unknown (cl-find-if (lambda (s) (eq (plist-get s :standing) 'unknown))
                                  standings))
             (chosen (harness-openrouter--cheapest standings)))
        (cond
         ;; An unreadable candidate could have been the cheapest, so the
         ;; decision waits for a reading rather than picking around it.
         (unknown
          (list :ok nil :reason (plist-get unknown :reason)
                :detail (plist-get unknown :detail)
                :provider (plist-get unknown :provider)))
         (chosen
          (list :ok t :provider (plist-get chosen :provider)
                :endpoint (harness-openrouter--endpoint-of
                           (plist-get chosen :record))
                :record (plist-get chosen :record)
                :reading read-at))
         (t
          (list :ok nil :reason 'over-max-price
                :detail (format "no allowed endpoint is within the maximum price: %s"
                                (string-join (mapcar (lambda (s) (plist-get s :detail))
                                                     standings)
                                             "; "))))))))))

(defun harness-openrouter--endpoint-of (record)
  "Return RECORD's exact endpoint identity: tag, provider, tier, quantization."
  (list :slug (plist-get record :tag)
        :provider (plist-get record :provider)
        :tier (or (plist-get record :tier) "default")
        :quantization (plist-get record :quantization)))

;;;; The pinned route

(defun harness-openrouter--route-of (session)
  "Return SESSION's pinned route, or nil."
  (when (listp session)
    (let ((ext (plist-get session :ext)))
      (when (listp ext) (plist-get ext harness-openrouter--route-key)))))

(defun harness-openrouter--route-plist (decision &optional canonical-slug)
  "Return DECISION as the route stored on a session.
Every value survives the JSON store of a session record: strings,
numbers and t, no symbols and no structs.  The tag, provider and tier
are the exact identity the pin is checked against; the prices are the
catalogue's, recorded for display and for the limit check at dispatch.
CANONICAL-SLUG, when the reading carried one, is recorded too: the
routing summary names the slug an aliased model resolved to rather than
the alias asked for, and the audit needs it to tell that apart from
another model (`harness-openrouter--same-model-p')."
  (let ((record (plist-get decision :record))
        (reading (plist-get decision :reading)))
    (append
     (list :model (plist-get record :model)
           :slug (plist-get record :tag)
           :provider (plist-get record :provider)
           :tier (or (plist-get record :tier) "default")
           :quantization (plist-get record :quantization)
           :prompt (harness-openrouter--usd-per-million (plist-get record :prompt))
           :completion (harness-openrouter--usd-per-million (plist-get record :completion))
           :cache-read (harness-openrouter--usd-per-million (plist-get record :cache-read))
           :discount (harness-openrouter--usd-per-million
                      (plist-get record :discount))
           :catalogue-at reading
           :selected-at (float-time)
           :structured-outputs (and (member "structured_outputs"
                                            (plist-get record :supported-parameters))
                                    t))
     (when (and (stringp canonical-slug) (not (string-empty-p canonical-slug)))
       (list :canonical-slug canonical-slug))
     (list :basis "chosen"))))

(defun harness-openrouter--store-route (session-id route)
  "Store ROUTE as SESSION-ID's pinned route; return ROUTE."
  (when (harness-method-exists-p 'session/set-ext)
    (harness-call 'session/set-ext session-id harness-openrouter--route-key route))
  (harness-emit 'openrouter/route-selected session-id route)
  route)

(defun harness-openrouter--hint (session-id text)
  "Leave TEXT as a hint on SESSION-ID, when it still exists."
  (when (and (harness-method-exists-p 'session/hint)
             (or (not (harness-method-exists-p 'session/exists-p))
                 (ignore-errors (harness-call 'session/exists-p session-id))))
    (ignore-errors (harness-call 'session/hint session-id text))))

(defun harness-openrouter--paused (session-id reason detail)
  "Announce that SESSION-ID may not send, for REASON, and say DETAIL.
Return nil, so no request is sent."
  (harness-emit 'openrouter/route-paused session-id reason detail)
  (harness-openrouter--hint session-id
                            (format "OpenRouter routing paused (%s): %s" reason detail))
  nil)

(defun harness-openrouter--degraded (session-id reading)
  "Announce that SESSION-ID is sending on an older catalogue READING.
Two readings are older ones, and both are inside the policy's `:freshness'
-- they were admitted, not tolerated.  A reading whose refresh failed
(`:stale') is the price evidence that could not be brought up to date: the
dispatch says so, with what the refresh said.  A reading that is only past
the shared refresh interval (`:revalidating') is being brought up to date
behind this dispatch, and the dispatch says that instead.  Either way a
person reading the session knows the price was not re-read for this send.

Nothing is emitted for a reading that is current, so an ordinary dispatch
says nothing about the catalogue at all."
  (cond
   ((plist-get reading :stale)
    (let ((detail (format "the catalogue refresh failed (%s); using the reading %d s old, inside the policy's freshness bound"
                          (or (plist-get reading :stale-error) "unknown")
                          (round (or (harness-openrouter--reading-age reading) 0)))))
      (harness-emit 'openrouter/catalogue-degraded session-id reading detail)
      (harness-openrouter--hint
       session-id (format "OpenRouter catalogue degraded: %s" detail))))
   ((plist-get reading :revalidating)
    (let ((detail (format "using the reading %d s old, inside the policy's freshness bound, while a fresh one is read"
                          (round (or (harness-openrouter--reading-age reading) 0)))))
      (harness-emit 'openrouter/catalogue-revalidating session-id reading detail)
      (harness-openrouter--hint
       session-id (format "OpenRouter catalogue revalidating: %s" detail))))))

(defun harness-openrouter-catalogue-status (&optional model)
  "Return the state of MODEL's shared endpoint catalogue reading.
MODEL defaults to the configured policy's.  The value is a plist:

  :model      the model asked about
  :state      `fresh' -- read within `harness-openrouter-catalogue-ttl'
              `revalidating' -- past the interval, a fresh one being read
              `stale' -- an older reading whose refresh failed
              `expired' -- a reading older than the policy's `:freshness'
              `absent' -- no reading at all
  :at         when the reading was made, or nil
  :age        seconds since then, or nil
  :ttl        the shared refresh interval, in seconds
  :endpoints  how many the reading lists, or nil
  :error      what the last refresh failed with, as text, or nil
  :attempts   background re-reads spent on the current failure
  :next-at    when the next one is due, or nil
  :reading    whether a dispatch may decide from the reading now

The state is what the catalogue is, not what a policy decides: `stale',
`revalidating' and `expired' are all readings a read has left behind, and
only `:freshness' says which of them may still be decided from -- which
is what `:reading' reports, for the configured policy.  A reading that is
`fresh' here can still be outside a policy's bound when the bound is
shorter than the interval, and a reading that is `revalidating' or `stale'
is inside the bound when `:reading' is `usable'."
  (let* ((model (or model (plist-get harness-openrouter-routing :model)))
         (reading (and model (gethash model harness-openrouter--catalogue)))
         (episode (and model (gethash model harness-openrouter--catalogue-failures)))
         (age (and reading (harness-openrouter--reading-age reading)))
         (freshness (plist-get harness-openrouter-routing :freshness))
         (due (and reading (harness-openrouter--reading-due-p reading)))
         (admissible (and reading (numberp freshness) (numberp age)
                          (not (> age freshness)))))
    (list :model model
          :state (cond
                  ((null reading) 'absent)
                  ((and (numberp freshness) (numberp age) (> age freshness))
                   'expired)
                  (episode 'stale)
                  (due 'revalidating)
                  (t 'fresh))
          :at (plist-get reading :at)
          :age age
          :ttl harness-openrouter-catalogue-ttl
          :endpoints (and (listp reading) (length (plist-get reading :endpoints)))
          :error (and episode (harness-error-message (plist-get episode :error)))
          :attempts (or (plist-get episode :attempts) 0)
          :next-at (plist-get episode :next-at)
          :reading (cond ((null reading) 'none)
                         (admissible 'usable)
                         (t 'expired)))))

;;;; The reading a policy may decide from
;;
;; The catalogue is the model's, not a session's: one reading is shared by
;; every session of it, and a session that starts while a recent reading
;; exists is answered from it.  Sharing the reading is what keeps a burst
;; of new sessions -- or a pinned session revalidating beside them, or the
;; permission judge deciding a call beside them -- from spending a request
;; each, and it is what lets a session run while the catalogue is briefly
;; unreadable.
;;
;; The refresh interval is `harness-openrouter-catalogue-ttl': the
;; catalogue is read about once per it, by whichever caller finds the
;; reading past it, and every other caller is answered from the reading.
;; A caller past the interval that its policy still admits is answered at
;; once, with the read started behind it, so nothing waits on the
;; catalogue for a decision the operator's bound already allows.
;;
;; What sharing never does is decide from a reading the policy does not
;; admit.  The operator's `:freshness' is the tolerance for an old price,
;; and a reading outside it is not used, however recently the catalogue
;; was read.  A refresh that fails is therefore answered from the last
;; reading only while `:freshness' still admits that reading, and that
;; answer is marked `:stale' so the pin, the hint and the status say the
;; price is an older reading rather than a fresh one.  With no reading
;; inside the bound there is nothing to decide from: the session pauses
;; with the failure, as it did before, and a bounded background re-read
;; works on making the next one possible.
;;
;; Nothing here is evidence about a price now.  A reused reading says what
;; the catalogue said at `:at'; `:freshness' is the operator's statement
;; of how old that may be for a decision, and a session that runs on a
;; reading whose refresh failed is told so.  There is no guarantee that a
;; price is current, and none is implied by sharing a reading.

(defun harness-openrouter--stale-reading (reading err)
  "Return READING marked as served after a failed refresh, saying ERR.
The reading keeps its own `:at': what is stale is the evidence, not the
timestamp, and the freshness bound is measured from the read that
produced it."
  (when (listp reading)
    (plist-put (plist-put (copy-sequence reading) :stale t)
               :stale-error (harness-error-message err))))

(defun harness-openrouter--fresh-reading-p (policy reading)
  "Non-nil when POLICY's `:freshness' admits READING."
  (and (listp reading)
       (harness-openrouter--fresh-p policy (plist-get reading :at))))

(defun harness-openrouter--patient-p ()
  "Non-nil when the request being prepared may wait for a catalogue read.
A step of a turn may: the read is part of preparing it, and its
bounds are the turn's.  A one-off call may not for long
(`harness-openrouter-catalogue-ephemeral-wait'): its budget is about the
answer it asks for, and a stalled read would spend the whole of it.

The flag is bound by `harness-openrouter--complete' from the request's
`:ephemeral', which `harness-small-ask' keeps as the caller wrote it."
  (not harness-openrouter--ephemeral))

(defun harness-openrouter--within (promise seconds fallback)
  "Return a promise settled by PROMISE, or by FALLBACK after SECONDS.
FALLBACK is called when PROMISE has not settled in time; PROMISE is
not cancelled, and its own result is dropped when it comes late."
  (let ((result (harness-make-promise))
        (settled nil)
        (timer nil))
    (let ((finish (lambda (settle value)
                    (unless settled
                      (setq settled t)
                      (when timer (cancel-timer timer))
                      (funcall settle result value)))))
      (harness-then promise
                    (lambda (value) (funcall finish #'harness-resolve value) nil)
                    (lambda (err) (funcall finish #'harness-reject err) nil))
      (unless settled
        (setq timer
              (run-at-time seconds nil
                           (lambda ()
                             (condition-case err
                                 (funcall finish #'harness-resolve (funcall fallback))
                               (error (funcall finish #'harness-reject err))))))))
    result))

(defun harness-openrouter--reading-due-p (reading)
  "Non-nil when READING is older than the shared refresh interval.
The interval is `harness-openrouter-catalogue-ttl': the catalogue is read
about once per it, for every caller of the model together, and a reading
inside it answers without a request."
  (let ((age (harness-openrouter--reading-age reading)))
    (and (numberp age) (>= age harness-openrouter-catalogue-ttl))))

(defun harness-openrouter--revalidate (model)
  "Start the shared background read of MODEL's catalogue, if one is due.
One read serves every caller (`harness-openrouter--reading-of'), so a
burst of callers starts one request, not one each, and a failure is
recorded and retried by the same handlers a session's own read uses.  Its
result is dropped here: whoever is waiting for a reading is waiting for
the one already in hand, and the reading that settles answers the next
lookup.  Nothing is sent, chosen or announced."
  (harness-then (harness-openrouter--reading-of model)
                (lambda (reading) reading)
                (lambda (_err) nil)))

(defun harness-openrouter--reading-for (policy)
  "Return a promise of the catalogue reading POLICY may decide from now.
The reading is the model's, shared by every caller in this process, and
this function decides only whether the one in hand may be used:

- a reading inside `harness-openrouter-catalogue-ttl' is answered as it
  is, with no request: this is what a new session, a pinned session's
  revalidation, a hand switch and the harness's own small calls are all
  answered from, so the catalogue is read about once per the interval
  rather than once per caller;
- a reading past the interval but still inside POLICY's `:freshness' is
  answered at once as well, and the shared read that brings it up to date
  is started in the background.  The reading is inside the bound the
  operator set for a price decision, so waiting for the read would make a
  session wait for something its policy already allows -- which is what a
  stalled catalogue read did to the permission judge;
- a reading past the interval whose refresh has failed is answered
  marked `:stale' with the failure, while the bounded background re-reads
  work on the next one.  No ordinary lookup reads the catalogue during
  that episode: an outage costs one failed read, not one per caller;
- with no reading inside `:freshness' -- the first run, or a reading the
  bound no longer admits -- the catalogue is read now.  A step of a turn
  waits for it; a one-off call (`:ephemeral') waits at most
  `harness-openrouter-catalogue-ephemeral-wait' and is then refused, so
  the judge's budget is spent on the call it was asked to decide.

A failure is never answered from a reading outside `:freshness', and a
reading is never invented: a first run with no catalogue pauses."
  (let* ((model (plist-get policy :model))
         (cached (gethash model harness-openrouter--catalogue))
         (episode (gethash model harness-openrouter--catalogue-failures))
         (admissible (harness-openrouter--fresh-reading-p policy cached)))
    (cond
     ;; The shared reading, still inside its refresh interval.
     ((and cached (not episode) (not (harness-openrouter--reading-due-p cached)))
      (harness-resolved cached))
     ;; Past the interval, inside the policy's bound, and no refresh has
     ;; failed: answer now and bring the reading up to date behind the
     ;; caller.  A one-off call does not start it -- the catalogue is read
     ;; once per interval, by the work that can wait for it, never by a
     ;; judge.
     ((and admissible (not episode))
      ;; A one-off call starts no read, so it is not told one is running:
      ;; `:revalidating' says what the catalogue is, and for a judge that
      ;; asked and did not wait it is simply the reading it was given.
      (if harness-openrouter--ephemeral
          (harness-resolved cached)
        (harness-openrouter--revalidate model)
        (harness-resolved (plist-put (copy-sequence cached) :revalidating t))))
     ;; The last refresh failed.  Answer from the reading the policy still
     ;; admits, saying what failed, and leave the next read to the bounded
     ;; background re-reads: an outage costs one failed read, not one per
     ;; caller.
     ((and admissible episode)
      (harness-resolved
       (harness-openrouter--stale-reading cached (plist-get episode :error))))
     ;; The refresh failed and nothing it left is inside the policy's
     ;; bound: answer the failure already found rather than spending a
     ;; request every caller would fail the same way.  The episode's own
     ;; re-reads -- the burst, then the slow probe -- are what read again.
     (episode
      (harness-rejected (plist-get episode :error)))
     (t
      (let ((read (harness-openrouter--reading-of model)))
        (if (harness-openrouter--patient-p)
            (harness-then
             read
             (lambda (reading) reading)
             (lambda (err)
               (if (harness-openrouter--fresh-reading-p policy cached)
                   (harness-openrouter--stale-reading cached err)
                 (harness-resignal err))))
          ;; A one-off call does not wait on this module's bookkeeping
          ;; for longer than `harness-openrouter-catalogue-ephemeral-wait':
          ;; its own budget is about the answer, and a stalled read would
          ;; spend all of it.  The read is not cancelled -- the next
          ;; caller and the background retry still get it -- and the
          ;; refusal is one the chain already reads as no verdict.
          (harness-openrouter--within
           read harness-openrouter-catalogue-ephemeral-wait
           (lambda ()
             (if (harness-openrouter--fresh-reading-p policy cached)
                 (harness-resolved
                  (harness-openrouter--stale-reading
                   cached (list 'timeout "still being read")))
               (harness-rejected
                (list 'http-error nil
                      (list 'timeout
                            (format "the endpoint catalogue was still being read after %ss"
                                    harness-openrouter-catalogue-ephemeral-wait)))))))))))))

(defun harness-openrouter--choose-now (policy)
  "Return a promise of the reading POLICY may choose from now.
The reading is the model's shared one: a recent reading is answered as it
is, so a session that starts while another has just read the catalogue
spends no request of its own.  A reading older than
`harness-openrouter-catalogue-ttl' is read again, and a read that fails
answers the last reading *only while POLICY's `:freshness' admits it*,
marked `:stale' with the failure in `:error'.  A reading outside that
bound is never used: the policy's freshness is the operator's tolerance
for an old price, and this function does not widen it.

So the promise resolves to the reading (`:at', `:endpoints', and
`:stale' when it is one served after a failed refresh), and rejects when
there is no reading the policy may decide from -- the first run with no
reading at all, or a failure with nothing inside the bound."
  (harness-openrouter--reading-for policy))

(defun harness-openrouter--select-decision (policy records read-at)
  "Return POLICY's decision for a brand new session from RECORDS read at READ-AT.
The policy's completeness, and so its providers and limits, were checked
before this: `select' sees only the endpoints of the named providers."
  (harness-openrouter-select policy records read-at))

;;;; Request fields

(defconst harness-openrouter--legacy-fields
  '(:label :base-url :api-key :api-key-env :headers
    :models :tiers :default-context :capabilities :allow-models)
  "Fields an `harness-openai-endpoints' entry of OpenRouter keeps here.
Before this module existed, an OpenRouter entry in that option was a
generic endpoint like any other, and every field it documented was read:
its label, URL, key, key variable and headers, and also its static
`models', its `tiers', its `default-context' and its `capabilities'.  All
of them are still honoured after the move to this module, so a
configuration made before it keeps working -- those four included, which
a static listing or a fixed tier set depends on.  `:allow-models' is
here for the same reason and for the case it was written for: OpenRouter
lists several hundred models, and an entry that names the few it wants
offered keeps that narrowing.  Only the dialect, the models function and
the completion function are this module's: they are what makes it
OpenRouter's provider rather than the generic one.")

(defun harness-openrouter--legacy-value (configured key)
  "Return CONFIGURED's KEY, the key itself when it is unset."
  (if (plist-member configured key) (plist-get configured key) key))

(defun harness-openrouter--endpoint ()
  "Return the OpenRouter endpoint plist this module registers.
The user's entry in `harness-openai-endpoints' is honoured -- every field
it documents, `harness-openrouter--legacy-fields' -- so an existing
configuration keeps working exactly as it did under the generic module;
the dialect is this module's whatever that entry says."
  (let ((configured (harness-openai-endpoint 'openrouter)))
    (list :id 'openrouter
          :label (or (plist-get configured :label) "OpenRouter")
          :base-url (or (plist-get configured :base-url) harness-openrouter-base-url)
          :api-key (plist-get configured :api-key)
          :api-key-env (or (plist-get configured :api-key-env)
                           harness-openrouter-api-key-env)
          :headers (plist-get configured :headers)
          ;; The static listing and the fixed tier set were the entry's
          ;; own documented keys; a configured endpoint keeps them.
          :models (plist-get configured :models)
          :tiers (plist-get configured :tiers)
          :default-context (plist-get configured :default-context)
          :capabilities (plist-get configured :capabilities)
          :allow-models (plist-get configured :allow-models)
          :flavor 'openrouter
          :dialect (harness-openrouter--dialect)
          :models-fn #'harness-openrouter--models
          :complete-fn #'harness-openrouter--complete)))

(defun harness-openrouter--dialect ()
  "Return the dialect plist this module gives the shared transport."
  (list :flavor 'openrouter
        :key-needed t
        :capabilities '(:vision t :thinking t :pricing dynamic :cost-reported t)
        :headers #'harness-openrouter--headers
        :max-tokens-key :max_tokens
        :reasoning-field :reasoning
        :reasoning-object t
        :body-extra #'harness-openrouter--body-extra
        :response-format #'harness-openrouter--response-format
        :stream-state #'harness-openrouter--stream-state
        :chunk #'harness-openrouter--chunk
        :audit #'harness-openrouter--audit
        :error-detail #'harness-openrouter--error-detail
        ;; OpenRouter names the kind of its failures in its own fields;
        ;; the hook turns those into the kinds every provider's failures
        ;; are read as (`harness-retry-failure-kind').  Whether a governed
        ;; request may be replayed by the transport is not a dialect
        ;; question: the shared retry layer answers it for the session.
        :failure-kind #'harness-openrouter--failure-kind
        ;; Where a rate limit reaches: one pinned endpoint's, or the
        ;; account's own.  Read from the failure's fields, never assumed.
        :limit-scope #'harness-openrouter--limit-scope))

(defun harness-openrouter--authorising-policy (request)
  "Return the policy a routed REQUEST was authorised with, or nil.
That is the policy `harness-openrouter--dispatch' checked and bound in
`harness-openrouter--sending', never the configured variable: the body
and headers of a request must describe the policy that permitted it,
even if the variable is edited afterwards.  A request the dispatch did
not mark with a route is not routed, and has no authorising policy."
  (and (plist-get request :openrouter-route)
       harness-openrouter--sending))

(defun harness-openrouter--headers (_endpoint _key)
  "Return the OpenRouter-specific headers of a request.
The app title names this client (it is not a secret).  The router
metadata header is sent only for a routed request, whose policy the
dispatch checked and bound in `harness-openrouter--sending', so an
unconfigured provider sends exactly what it sent before and a governed
request always asks for the metadata its audit reads."
  (append (list (cons "X-Title" "Emacs agent harness"))
          (when harness-openrouter--sending
            (list (cons "X-OpenRouter-Metadata" "enabled")))))

(defun harness-openrouter--session-id (request)
  "Return the sticky-session id for REQUEST, or nil.
It is the harness's session id, stable across turns, retries and a
restart.  It is not proof of a cache hit; the pin is the `provider'
object, and this only helps OpenRouter keep one session's cache warm
within the endpoint the pin names."
  (let ((id (plist-get (plist-get request :session) :id)))
    (and (stringp id) (<= (length id) 256) id)))

(defun harness-openrouter--wire-price (policy)
  "Return the request-level `max_price' for POLICY, or nil.
OpenRouter's `provider.max_price' takes prompt and completion prices in
USD per million tokens.  Sending the configured maximum there is a
second defence: the router itself refuses an endpoint dearer than the
limit, whatever this module's own reading of the catalogue said.  It
covers prompt and completion only.  It says nothing about cache reads --
OpenRouter's documentation does not offer a cache-read cap, and this
module does not assume one -- so the cache-read price is checked here
\(`harness-openrouter--prices-over') and never inferred to be protected
by the wire field.  A per-request fee is not bounded by it either: an
endpoint that prices one is refused before the request is made
\(`harness-openrouter--unpriceable-components')."
  (let* ((limits (plist-get policy :max-price))
         (prompt (harness-openrouter--decimal (plist-get limits :prompt)))
         (completion (harness-openrouter--decimal (plist-get limits :completion))))
    (when (and prompt completion)
      (list :prompt (float (/ (car prompt) (float (cdr prompt))))
            :completion (float (/ (car completion) (float (cdr completion))))))))

(defun harness-openrouter--response-format (_endpoint request schema name)
  "Return the `response_format' REQUEST asks for, or nil for no schema.
OpenRouter passes `response_format' on to the endpoint it routes to,
and only some endpoints take a JSON schema: its catalogue lists which,
per endpoint, in `supported_parameters' (\"structured_outputs\").  The
pin records what the pinned endpoint said when it was chosen
\(`harness-openrouter--route-plist'), and this reads that.  A session
with no pin, and an endpoint that said nothing, send no schema: a field
the endpoint refuses would fail the call the schema was for.  Without a
policy there is no pin to ask, and none is sent either."
  (when (and (harness-openrouter-routing-enabled-p harness-openrouter-routing)
             (let ((route (or (plist-get request :openrouter-route)
                              (harness-openrouter--route-of (plist-get request :session)))))
               (and (listp route)
                    (harness-json-true-p (plist-get route :structured-outputs)))))
    (list :type "json_schema"
          :json_schema (list :name name :strict :true :schema schema))))

(defun harness-openrouter--body-extra (_endpoint _name request)
  "Return the OpenRouter-only body fields for REQUEST.
Without an enabled policy this is the usage object OpenRouter always
got.  With one, the request is restricted to the session's pinned
endpoint -- its exact slug in `only' and `order', fallbacks off, the
standard tier -- always carries the no-training and retention controls,
and states that policy's maximum as `max_price'.  A request with no
pinned route is never sent (`harness-openrouter--complete'); this
function only describes one that is.

The policy read here is the one `harness-openrouter--dispatch' checked
and bound in `harness-openrouter--sending', not the configured one: the
body of a request must describe the policy that authorised it, even if
the variable is edited between the check and the body being built.  A
routed request -- one the dispatch marked with `:openrouter-route' --
without that checked policy is a bug in the caller, not a reason to
send an unrestricted body, so it signals and the transport sends
nothing."
  (let ((fields (list (cons :usage '(:include t))))
        (route (plist-get request :openrouter-route))
        (policy (harness-openrouter--authorising-policy request)))
    (cond
     ((null (plist-get request :openrouter-route)) fields)
     ((null policy)
      (signal 'harness-error
              (list "OpenRouter routing: a routed request was built without a checked policy")))
     (t
      (let ((slug (plist-get route :slug))
            (max-price (harness-openrouter--wire-price policy)))
        (setq fields (append fields
                             (list (cons :provider
                                         (append
                                          (list :only (vector slug)
                                                :order (vector slug)
                                                :allow_fallbacks :false
                                                :require_parameters t
                                                :data_collection "deny"
                                                :zdr t)
                                          (when max-price
                                            (list :max_price max-price))))
                                   (cons :service_tier "default")))))
      (when-let* ((sid (harness-openrouter--session-id request)))
        (setq fields (append fields (list (cons :session_id sid)))))
      fields))))

;;;; Reading a streamed answer

(defconst harness-openrouter--permanent-types
  '("context_length_exceeded" "max_tokens_exceeded" "token_limit_exceeded"
    "string_too_long" "invalid_request" "invalid_prompt" "not_found"
    "precondition_failed" "payload_too_large" "unprocessable"
    "content_policy_violation" "refusal" "invalid_image" "image_too_large"
    "image_too_small" "unsupported_image_format" "image_not_found"
    "image_download_failed" "authentication" "permission_denied"
    "payment_required")
  "Typed OpenRouter error codes that repeating the identical request cannot pass.
The chunk reader keeps the code or the message reports
\(`harness-openrouter--error-type'), `harness-openrouter--failure-kind'
turns it into the shared kind `permanent', and the shared retry layer
then ends the turn instead of repeating the request unchanged.  That is
what makes an upstream HTTP 400 stop with a reason.")

(defconst harness-openrouter--transient-types
  '("rate_limit_exceeded" "rate_limit" "overloaded" "provider_unavailable"
    "server_error" "internal_error" "timeout" "upstream_timeout"
    "provider_timeout" "unavailable" "too_many_requests")
  "Typed OpenRouter error codes that name a provider's or a gateway's bad minute.
They are a repeat's to pass, so `harness-openrouter--failure-kind' reads
them as the shared kinds `transport' or `rate-limit', and the shared
retry layer decides -- under its own bounds -- whether it tries again.")

(defun harness-openrouter--stream-state (request)
  "Return the dialect state a new stream for REQUEST starts with.
The route audited is the one the dispatch checked and put on REQUEST,
so the audit describes the request that was actually sent."
  (let ((session (plist-get request :session)))
    (list :route (and (harness-openrouter--authorising-policy request)
                      (plist-get request :openrouter-route))
          :session-id (plist-get session :id))))

(defun harness-openrouter--state (stream)
  "Return the dialect state of STREAM, made if absent."
  (or (harness-openai--stream-dialect-state stream)
      (setf (harness-openai--stream-dialect-state stream) (list))))

(defun harness-openrouter--note (stream key value)
  "Remember VALUE under KEY in STREAM's dialect state."
  (let ((state (harness-openrouter--state stream)))
    (setf (harness-openai--stream-dialect-state stream)
          (plist-put (copy-sequence state) key value))))

(defun harness-openrouter--error-type (json)
  "Return the typed error code JSON carries, or nil."
  (let* ((error (plist-get json :error))
         (metadata (and (listp error) (plist-get error :metadata)))
         (type (and (listp metadata) (plist-get metadata :error_type))))
    (and (stringp type) type)))

(defun harness-openrouter--declined-provider-of (json)
  "Return the upstream provider JSON says declined the request, or nil.
OpenRouter names it in `error.metadata.provider_name' when an endpoint
of its own answered the request with a failure; a limit OpenRouter
itself imposed names none.  The two are told apart here, never assumed:
one endpoint's bad minute is not the whole account's, and the account's
own limit is not one endpoint's."
  (let* ((error (plist-get json :error))
         (metadata (and (listp error) (plist-get error :metadata)))
         (name (and (listp metadata) (plist-get metadata :provider_name))))
    (and (stringp name) (not (string-empty-p name)) name)))

(defun harness-openrouter--served-provider (json)
  "Return the provider JSON says served the request, or nil.
The name an answer reports for itself is preferred; the routing summary
the metadata header asks for is read when there is one."
  (let ((own (plist-get json :provider)))
    (or (and (stringp own) own)
        (let* ((metadata (plist-get json :openrouter_metadata))
               (attempts (and (listp metadata) (plist-get metadata :attempts)))
               (last (and (listp attempts) (consp attempts) (car (last attempts))))
               (name (and (listp last) (plist-get last :provider))))
          (and (stringp name) name)))))

(defun harness-openrouter--selected-endpoints (json)
  "Return the endpoints JSON's routing summary says were available, or nil.
Each is (:provider NAME :model ID :selected BOOL), as the metadata
header documents `openrouter_metadata.endpoints.available'.  Nil when
the answer carried no such summary, which is no evidence either way."
  (let* ((metadata (plist-get json :openrouter_metadata))
         (endpoints (and (listp metadata) (plist-get metadata :endpoints)))
         (available (and (listp endpoints) (plist-get endpoints :available))))
    (when (listp available)
      (delq nil
            (mapcar (lambda (entry)
                      (when (listp entry)
                        (list :provider (plist-get entry :provider)
                              :model (plist-get entry :model)
                              :selected (harness-json-true-p (plist-get entry :selected)))))
                    available)))))

(defun harness-openrouter--chunk (json stream)
  "Read the OpenRouter fields of chunk JSON into STREAM.
Return non-nil only for a chunk this module consumes whole -- the final
metadata chunk, which carries no choices for the model to read."
  (when (listp json)
    (dolist (pair '((:model . :model) (:provider . :provider)
                    (:service_tier . :service-tier) (:id . :generation)))
      (let ((value (plist-get json (car pair))))
        (when (stringp value)
          (harness-openrouter--note stream (cdr pair) value))))
    (when-let* ((provider (harness-openrouter--served-provider json)))
      (harness-openrouter--note stream :served-provider provider))
    (when-let* ((type (harness-openrouter--error-type json)))
      (harness-openrouter--note stream :error-type type))
    (when-let* ((declined (harness-openrouter--declined-provider-of json)))
      (harness-openrouter--note stream :declined-provider declined))
    (let ((metadata (plist-get json :openrouter_metadata)))
      (when (listp metadata)
        (harness-openrouter--note stream :metadata metadata)
        (when-let* ((region (plist-get metadata :region)))
          (when (stringp region) (harness-openrouter--note stream :region region)))
        (when (plist-get metadata :endpoints)
          (harness-openrouter--note stream :available-endpoints
                                    (harness-openrouter--selected-endpoints json)))))
    (and (plist-member json :openrouter_metadata)
         (null (plist-get json :choices)))))

(defun harness-openrouter--same-provider-p (wanted served)
  "Non-nil when SERVED is the provider WANTED, a catalogue name.
OpenRouter names a provider the way its catalogue does (\"DeepInfra\");
a metadata summary may spell it differently, so the comparison ignores
case and spacing, and never accepts a different provider for the same
one."
  (let ((normalize (lambda (s)
                     (downcase (replace-regexp-in-string "[^a-z0-9]" "" (or s ""))))))
    (and (stringp served)
         (not (string-empty-p served))
         (equal (funcall normalize wanted) (funcall normalize served)))))

(defun harness-openrouter--endpoint-identity (route)
  "Return ROUTE's identity, every field this module can check.
The model, the exact tag (`:slug'), the provider name, the service tier
and the quantization.  A field the route does not know is nil."
  (list (plist-get route :model) (plist-get route :slug)
        (plist-get route :provider) (or (plist-get route :tier) "default")
        (plist-get route :quantization)))

(defvar harness-openrouter--canonical (make-hash-table :test 'equal)
  "Model id -> promise of its canonical slug.
OpenRouter's own record is read at most once per model per process: the
slug is a property of the model, not of the request, and the form of it
is what the routing summary names.")

(defun harness-openrouter--fetch-canonical-slug (model)
  "Return a promise of MODEL's canonical slug, OpenRouter's own statement.
OpenRouter resolves an alias to a snapshot and says which: the model
record carries `canonical_slug' beside the `id' that was asked for.
This reads that record and adds no rule of its own about how a slug is
spelled: no date, edition or suffix is inferred anywhere in this module.

The promise resolves to the slug, or to nil when there is none to read:
a model whose slug is its own canonical one is not an alias and needs no
recording.  A record that could not be read at all -- a transport
failure, a refusal, a body that makes no sense -- also resolves to nil,
but is *not* kept: it is forgotten, so the next dispatch of the model
reads again rather than reusing a nil that says nothing about the model.
An answer that the model has no other slug is kept, because that is a
reading.  The slug is evidence for the audit, never a reason to refuse a
request that every other check allowed, so nothing here rejects."
  (or (gethash model harness-openrouter--canonical)
      (let* ((endpoint (harness-openrouter--endpoint))
             (url (concat (string-remove-suffix "/" harness-openrouter-base-url)
                          "/model/" model))
             (failed nil)
             (promise (harness-then
                       (condition-case err
                           (harness-http-request-json
                            url :headers (harness-openai--headers
                                          endpoint (harness-openai--api-key endpoint))
                            :timeout harness-openrouter-catalogue-timeout)
                         (error (harness-rejected err)))
                       (lambda (json)
                         (let* ((data (or (plist-get json :data) json))
                                (canonical (and (listp data)
                                                (plist-get data :canonical_slug))))
                           (and (stringp canonical)
                                (not (string-empty-p canonical))
                                (not (equal canonical model))
                                canonical)))
                       ;; A failed read is not a reading.  It answers nil,
                       ;; like an unread record, but it is not kept: the
                       ;; flag below takes the entry straight back out, so
                       ;; the next dispatch of the model spends a new request
                       ;; rather than reusing a nil that says nothing.  A nil
                       ;; cached here would outlive one transient failure and
                       ;; leave a pin with no slug for the rest of the
                       ;; process, which the audit then refuses after a
                       ;; request that worked.
                       (lambda (_err) (setq failed t) nil))))
        (puthash model promise harness-openrouter--canonical)
        ;; A transport that fails at once settles the promise before this
        ;; line, so the flag -- not the order of a `remhash' inside the
        ;; handler -- is what decides whether an entry may stay.
        (when failed (remhash model harness-openrouter--canonical))
        promise)))

(defun harness-openrouter--canonical-slug (model)
  "Return MODEL's canonical slug when it is already known, or nil.
No request is made and nothing is started: this is for a path that must
not spend a request on evidence it may not need (sending an existing
pin).  A model whose record has not been read answers nil, and the audit
then accepts only the model the pin itself names."
  (let ((promise (gethash model harness-openrouter--canonical)))
    (and promise
         (harness-promise-settled-p promise)
         (eq (harness-promise-state promise) 'resolved)
         (harness-promise-value promise))))

(defun harness-openrouter--choose-now-with-slug (policy)
  "Return a promise of POLICY's catalogue reading, carrying its canonical slug.
The reading is `harness-openrouter--choose-now''s, with `:canonical-slug'
added when OpenRouter's own model record names one.  The record is read
beside the catalogue rather than before it, and one that answers nothing
leaves the key out: the pin then records no slug, and the audit accepts
only the model it asked for."
  (harness-then
   (harness-all (list (harness-openrouter--choose-now policy)
                      (harness-openrouter--fetch-canonical-slug
                       (plist-get policy :model))))
   (lambda (values)
     (let ((reading (nth 0 values))
           (slug (nth 1 values)))
       (if (and slug (listp reading))
           (plist-put (copy-sequence reading) :canonical-slug slug)
         reading)))))

(defun harness-openrouter--ensure-canonical (session-id route)
  "Return a promise of ROUTE with its model's canonical slug recorded.
ROUTE is an existing pin.  One that already records a slug is answered as
it is, with no request: this is what a dispatch of a pin made since the
slug was recorded costs, which is nothing.

A pin with no slug was written before this module recorded them, and
OpenRouter serves it exactly as it serves any pin -- the routing summary
still names the canonical slug, and the audit would refuse every answer
it got, after a request that worked.  So the model's record is read once,
the route completed from it, and the completed route stored on
SESSION-ID: same endpoint, same policy, same prices, only the evidence
of which model that endpoint serves made explicit.  That is not a switch
-- nothing is re-selected -- and `harness-openrouter--store-route' says so
by emitting the route it now pins.

A record that cannot be read leaves the route as it was, and the audit
then accepts only the model the pin itself names: strict, never lenient.
This is the evidence path, not a reason to refuse a request every other
check allowed, so nothing here rejects."
  (if (or (plist-get route :canonical-slug)
          (not (stringp (plist-get route :model))))
      (harness-resolved route)
    (harness-then
     (harness-openrouter--fetch-canonical-slug (plist-get route :model))
     (lambda (slug)
       (let ((completed (harness-openrouter--with-canonical route slug)))
         (when (and slug (not (eq completed route)))
           (harness-openrouter--store-route session-id completed))
         completed))
     (lambda (_err) route))))

(defun harness-openrouter--with-canonical (route canonical)
  "Return ROUTE with CANONICAL recorded as its model's canonical slug.
A route that already knows one keeps it, and a CANONICAL that is nil or
the model itself adds nothing: a pin made before this module recorded
slugs is still a pin of the same model, and one made since is not
rewritten by a listing that answered differently."
  (if (or (null canonical)
          (string-empty-p canonical)
          (equal canonical (plist-get route :model))
          (plist-get route :canonical-slug))
      route
    (plist-put (copy-sequence route) :canonical-slug canonical)))

(defun harness-openrouter--same-model-p (route named)
  "Non-nil when the model NAMED is the model ROUTE pinned, alias aside.
ROUTE is the pin and NAMED is a model a response names.

The strings a response names do not all echo the request.  A response's
own \(top-level) `model' field does, while the routing summary names the
model the request resolved to, which OpenRouter calls the canonical
slug: a request for `deepseek/deepseek-v4.1-flash-1017' is answered by
`deepseek/deepseek-v4.1-flash-20261017', and comparing those two as
strings refuses every answer an aliased model gives.

So NAMED is accepted as the pinned model itself or as the canonical slug
recorded for it at pin time, and as nothing else.  The slug comes from
OpenRouter's own listing (`canonical_slug'), never from a rule about how
slugs are spelled: no date, edition or suffix is inferred here, so
another snapshot of the same model and another model altogether are both
still mismatches.  A pin with no recorded slug accepts only the model it
asked for, which refuses rather than assumes."
  (let ((normalize (lambda (s)
                     (downcase (replace-regexp-in-string "[^a-z0-9]+" "" (or s ""))))))
    (and (stringp named)
         (or (equal (funcall normalize (plist-get route :model)) (funcall normalize named))
             (and (stringp (plist-get route :canonical-slug))
                  (equal (funcall normalize (plist-get route :canonical-slug))
                         (funcall normalize named)))))))

(defun harness-openrouter--audit-complaint (route state)
  "Return what STATE's answer claims that ROUTE did not allow, or nil.
Everything the answer can be made to say about which endpoint served it
is checked: the model, the provider, the service tier, the region, and
the routing summary's own list of endpoints if it carried one.  Every
identity field the answer actually names must agree with the pin; one it
does not name is not evidence of a mismatch.

What the API does not give is written down rather than assumed: the
streamed answer names no endpoint tag, and the routing summary names a
provider and a model, not a tag.  So a new regional variant of the same
provider cannot be distinguished from the pinned one by the answer
alone -- which is why `harness-openrouter--candidate' refuses to pin a
provider the catalogue lists at more than one standard endpoint, and why
the pin also sends `only' with the exact tag and `allow_fallbacks:
false'.

A named model is compared by `harness-openrouter--same-model-p', so the
summary's canonical slug is not read as another model."
  (let ((model (plist-get state :model))
        (served (or (plist-get state :served-provider) (plist-get state :provider)))
        (tier (plist-get state :service-tier))
        (region (plist-get state :region))
        (available (plist-get state :available-endpoints))
        (pinned-provider (plist-get route :provider))
        (pinned-region (plist-get route :region)))
    (cond
     ((null model)
      "the answer named no model")
     ((not (harness-openrouter--same-model-p route model))
      (format "OpenRouter answered model %s, not the pinned %s"
              model (plist-get route :model)))
     ((null served)
      "the answer named no provider, so it cannot be shown to be the pinned one")
     ((not (harness-openrouter--same-provider-p pinned-provider served))
      (format "OpenRouter answered from %s, not the pinned %s"
              served pinned-provider))
     ((and tier (not (member (downcase tier) '("default" "standard"))))
      (format "OpenRouter served the %s tier, not the pinned default tier" tier))
     ;; A region the route pins is checked when the answer names one; an
     ;; answer that names no region proves nothing about which region
     ;; served it, and that is stated in the documentation rather than
     ;; read as agreement.
     ((and pinned-region region (not (equal pinned-region region)))
      (format "OpenRouter answered from region %s, not the pinned %s"
              region pinned-region))
     ;; The routing summary lists which endpoints were available.  If it
     ;; names a selected endpoint that is not the pinned provider and
     ;; model, the answer came from somewhere else.  The model it names is
     ;; the canonical slug, which is why the comparison is the same one
     ;; the answer's own model field gets.
     ((let ((selected (cl-find-if (lambda (e) (plist-get e :selected)) available)))
        (and selected
             (or (not (harness-openrouter--same-provider-p
                       pinned-provider (plist-get selected :provider)))
                 (let ((named (plist-get selected :model)))
                   (and (stringp named)
                        (not (harness-openrouter--same-model-p route named)))))))
      (format "the routing summary names %s by %s as selected, not the pinned %s by %s"
              (plist-get (cl-find-if (lambda (e) (plist-get e :selected)) available) :model)
              (plist-get (cl-find-if (lambda (e) (plist-get e :selected)) available) :provider)
              (plist-get route :model) pinned-provider)))))

(defun harness-openrouter--audit (stream _reason)
  "Return what STREAM's answer claims that the pinned request did not allow.
Only a routed session is audited.  Every identity field the answer names
is checked against the pin (`harness-openrouter--audit-complaint');
missing evidence of the provider is a failure too, because the metadata
header asks for it.  A mismatch also leaves an
`openrouter/response-mismatch' event, so a session's own log says when a
provider served it that it did not pin."
  (let* ((state (harness-openai--stream-dialect-state stream))
         (route (plist-get state :route))
         (complaint (when route (harness-openrouter--audit-complaint route state))))
    (when complaint
      (harness-emit 'openrouter/response-mismatch (plist-get state :session-id) complaint))
    complaint))

(defun harness-openrouter--error-detail (body _status)
  "Return a content-free description of an OpenRouter error BODY, or nil.
It names the typed code, the provider that declined, that provider's own
code and the generation id -- what identifies the failure.  It never
includes the request, its prompt or its tool arguments.  This is what
turns \"Upstream returned HTTP 400\" into something to act on."
  (when-let* ((json (ignore-errors (harness-json-parse body))))
    (when (listp json)
      (let* ((error (plist-get json :error))
             (metadata (and (listp error) (plist-get error :metadata)))
             (type (harness-openrouter--error-type json))
             (provider (and (listp metadata) (plist-get metadata :provider_name)))
             (code (and (listp metadata) (plist-get metadata :provider_code)))
             (id (plist-get json :id))
             (parts nil))
        (when type (push (format "error_type=%s" type) parts))
        (when (and (stringp provider) (not (string-empty-p provider)))
          (push (format "provider=%s" (harness-truncate-end provider 60)) parts))
        (when (or (stringp code) (numberp code))
          (push (format "provider_code=%s" (harness-truncate-end (format "%s" code) 40)) parts))
        (when (and (stringp id) (not (string-empty-p id)))
          (push (format "generation=%s" (harness-truncate-end id 80)) parts))
        (when parts (concat " (" (string-join (nreverse parts) "; ") ")"))))))

;;;; Which pool a request belongs to

(defun harness-openrouter--route-for-identity (request)
  "Return the route REQUEST is bound for, or nil.
A repeat carries the route that authorised it (`harness-retry-authority-of'),
so it is identified by the endpoint it will actually be sent to, never
by a session's pin of the moment; a fresh request has its session's pin.
A request with no policy and no pin is OpenRouter's as a whole, and has
no endpoint to name."
  (let* ((authority (harness-retry-authority-of request))
         (route (or (plist-get authority :route)
                    (plist-get request :openrouter-route)
                    (harness-openrouter--route-of (plist-get request :session)))))
    (and (listp route) route)))

(harness-defmethod provider/admission-identity (request)
  "Return the pool REQUEST of OpenRouter belongs to, or nil.
The account is OpenRouter itself: its own key, and its own limits, are
one account's whatever endpoint serves a request.  The pool is the
upstream endpoint the request is bound for -- the exact tag the session
is pinned to, or, for a request that is not pinned, the account's own
pool (`openrouter').  So a rate limit DeepInfra answers holds the work
bound for DeepInfra and not the work bound for Cohere, while a limit
OpenRouter itself imposed rests every pool of the account (see
`harness-openrouter--limit-scope').

Every part of it is a name OpenRouter publishes: the provider id, the
catalogue's endpoint tag.  No key, token or other credential is ever
part of a pool, so nothing here can be read out of a hint or an event."
  (when (harness-openrouter-routing-enabled-p harness-openrouter-routing)
    (let ((slug (plist-get (harness-openrouter--route-for-identity request) :slug)))
      (list :account "openrouter"
            :pool (if (and (stringp slug) (not (string-empty-p slug)))
                      (format "openrouter/%s" slug)
                    "openrouter")))))

;;;; Dispatch: the pin, checked before every request

(defun harness-openrouter--not-routing-refusal (policy)
  "Return (REASON . DETAIL) when POLICY, read now, routes nothing.
A request is prepared under one policy and sent later -- the catalogue
may take a moment to answer -- so the policy is read again at dispatch.
A policy edited to something incomplete, turned off, or removed
altogether stops the request: a restricted request cannot be described
by a policy that routes nothing, and an unrestricted one is exactly what
a governed session must never be sent."
  (cond
   ((null policy)
    (cons 'policy-changed
          "the routing policy was removed while the request was being prepared, so no restricted request can be built and an unrestricted one is not sent"))
   ((harness-openrouter--policy-error policy)
    (cons 'policy-invalid (harness-openrouter--policy-error policy)))
   ((not (harness-json-true-p (plist-get policy :enabled)))
    (cons 'disabled "the policy is configured but not enabled"))))

(defconst harness-openrouter--policy-keys
  '(:enabled :model :providers :max-price :freshness)
  "The keys of a policy that decide what a request may be.
They are the whole schema; a policy that differs in any of them is not
the policy a request in flight was prepared under.")

(defun harness-openrouter--policy-change (authorising now)
  "Return a description of how NOW differs from AUTHORISING, or nil.
Only the fields that decide a request are compared, and a field that is
equal is not named.  A policy replaced by an equal one is the same
policy: nothing it would decide changes."
  (when (and (listp authorising) (listp now))
    (let (changed)
      (dolist (key harness-openrouter--policy-keys)
        (unless (equal (plist-get authorising key) (plist-get now key))
          (push (concat ":" (substring (symbol-name key) 1)) changed)))
      (when changed
        (format "the policy changed while the request was being prepared: %s now differ%s"
                (string-join (nreverse changed) ", ")
                (if (= 1 (length changed)) "s" ""))))))

(defun harness-openrouter--policy-changed-refusal (authorising now)
  "Return (REASON . DETAIL) when NOW is not the policy AUTHORISING a request.
A request is prepared under one policy -- it is what chose the endpoint,
read the limits and authorised the privacy fields -- and sent after an
asynchronous catalogue read.  A policy replaced meanwhile, by a valid
one or not, is a different authority than the one the request was
prepared under: silently sending the old request would send under a
policy the operator has already replaced, and quietly reselecting under
the new one would be a fallback to a provider the old policy did not
authorise.  So the request is refused and the next one is prepared
afresh under the new policy, which is the policy that then decides.
Only an equal policy is not a change: if every field that decides a
request is the same, the operator has edited nothing that matters."
  (when (and (listp authorising) (listp now))
    (let ((change (harness-openrouter--policy-change authorising now)))
      (when change (cons 'policy-changed change)))))

(defun harness-openrouter--pin-allowed (policy route)
  "Non-nil when POLICY still allows ROUTE, by provider and exact identity.
The pin names a provider; the policy's `:providers' says whether that
provider may serve the model, and the route's own exact tag, provider
and tier are what every request is restricted to.  A provider the
policy no longer names leaves the pin unvetted, and a change of
identity under the same name is not the endpoint the pin was made on.

The tag itself is not in the policy: it is the catalogue's, recorded
when the pin was made, and re-read from a fresh catalogue at dispatch
\(`harness-openrouter--pin-refusal'), so a new tag cannot be adopted
here."
  (and (member (plist-get route :provider) (plist-get policy :providers))
       (stringp (plist-get route :slug))
       (string-match-p "/" (plist-get route :slug))
       (equal (plist-get route :model) (plist-get policy :model))
       t))

(defun harness-openrouter--recorded-over (limits route)
  "Return the components of ROUTE's recorded price above LIMITS, as strings.
The route records the catalogue price it was pinned at, for display;
this reads it back exactly, so a maximum lowered under a pin that is
still fresh stops the pin instead of sending at the old price."
  (let (over)
    (dolist (key harness-openrouter--price-keys)
      (let* ((most (plist-get limits key))
             (million (plist-get route key))
             (price (and (numberp million)
                         (harness-openrouter--limit-per-token
                          (number-to-string million)))))
        (when (or (null price) (harness-openrouter--decimal> price most))
          (push (format "%s %s > %s" (substring (symbol-name key) 1)
                        (or million "unknown")
                        (harness-openrouter--usd-per-million most))
                over))))
    (nreverse over)))

(defun harness-openrouter--pin-refusal (policy route &optional reading)
  "Return (REASON . DETAIL) when POLICY may not send ROUTE now, or nil.
Everything a dispatch depends on is checked here, every time: that the
policy is still complete, that the pin's provider is still allowed and
the pin still the identity it was vetted as, that the maximum price
still covers the price the pin recorded, and that the catalogue still
lists the pinned endpoint exactly once under it.  When READING -- a
catalogue reading, `:endpoints' and `:at' -- is given it must be fresh,
must list the pin exactly once as its provider's single standard
endpoint, at a price under the maximum and with no component the limits
do not cover.

A READING that is nil, empty or unreadable is a refusal, never `no
refresh': `harness-openrouter--choose-now' rejects a failed fetch, so
nil here can only be a catalogue that says this model has no endpoints
at all, which is not evidence that the pin still exists."
  (let* ((problem (harness-openrouter--policy-error policy))
         (limits (and (not problem) (harness-openrouter--limits policy)))
         (freshness (plist-get policy :freshness)))
    (cond
     (problem (cons 'policy-invalid problem))
     ((not (harness-openrouter--pin-allowed policy route))
      (cons 'pin-not-vetted
            (format "the pinned provider %s, at %s, is not allowed by the policy now"
                    (or (plist-get route :provider) "?")
                    (or (plist-get route :slug) "?"))))
     ((harness-openrouter--recorded-over limits route)
      (cons 'over-max-price
            (format "the pin's price is over the maximum price now: %s"
                    (string-join (harness-openrouter--recorded-over limits route) ", "))))
     ((null reading)
      (unless (harness-openrouter--fresh-p policy (plist-get route :catalogue-at))
        (cons 'catalogue-stale
              (format "the pin's catalogue reading is %d s old; the policy allows %s s"
                      (round (- (float-time) (or (plist-get route :catalogue-at) 0)))
                      freshness))))
     (reading
      (let* ((records (plist-get reading :endpoints))
             (at (plist-get reading :at))
             (provider (plist-get route :provider))
             (record (and records (harness-openrouter--candidate
                                   policy records provider))))
        (cond
         ((not records)
          (cons 'catalogue-empty
                "the fresh catalogue lists no endpoint for this model at all"))
         ((not (harness-openrouter--fresh-p policy at))
          (cons 'catalogue-stale
                (format "the endpoint catalogue was read %d s ago; the policy allows %s s"
                        (round (- (float-time) (or at 0))) freshness)))
         ((null record)
          (cons 'unknown-endpoint
                (format "the catalogue no longer lists exactly one standard endpoint of %s for this model, so %s cannot be shown to be it"
                        provider (plist-get route :slug))))
         ((not (equal (plist-get record :tag) (plist-get route :slug)))
          (cons 'pin-not-vetted
                (format "the catalogue now lists %s's endpoint as %s, not the pinned %s"
                        provider (plist-get record :tag) (plist-get route :slug))))
         ((not (equal (or (plist-get record :tier) "default")
                      (or (plist-get route :tier) "default")))
          (cons 'pin-not-vetted
                (format "the catalogue now serves %s at the %s tier, not the pinned %s"
                        (plist-get route :slug) (or (plist-get record :tier) "default")
                        (or (plist-get route :tier) "default"))))
         (t
          (let* ((standing (harness-openrouter--standing
                            (list :provider provider :record record) limits))
                 (kind (plist-get standing :standing)))
            (cond
             ((eq kind 'unknown)
              (cons (plist-get standing :reason)
                    (format "the pinned endpoint %s can no longer be read: %s"
                            (plist-get route :slug) (plist-get standing :detail))))
             ((eq kind 'out)
              (cons 'over-max-price
                    (format "the pinned endpoint %s is now dearer than the maximum price: %s"
                            (plist-get route :slug) (plist-get standing :detail))))))))))
     (t nil))))

(defun harness-openrouter--cancelled-p (state)
  "Non-nil when STATE, a shared dispatch state, was cancelled."
  (car state))

(defun harness-openrouter--cancel-handle (state)
  "Return a cancel handle for STATE, the shared state of one dispatch.
STATE is a list whose car is the cancelled flag and whose cadr is the
transport's own cancel function, when the request reached one.
Cancelling marks STATE first and is idempotent, so a repeated cancel, one
before the catalogue resolves, or one during the transport all do the
right thing, and a callback that arrives afterwards sees the flag and
emits nothing."
  (list :cancel
        (lambda ()
          (unless (car state)
            (setcar state t)
            (let ((inner (cadr state)))
              (when (functionp inner) (funcall inner))))
          nil)))

(defun harness-openrouter--start-pinned (state snapshot request on-event)
  "Send REQUEST under SNAPSHOT, keeping the transport handle in STATE.
STATE is shared with the cancel handle.  A dispatch that is already
cancelled sends nothing; otherwise the request goes through
`harness-openrouter--dispatch', which checks the whole policy again at
the moment the body is built.  The transport handle, when the request
reaches one, is what a later cancel reaches; a cancel before this point
has already set the flag, and nothing is sent."
  (unless (car state)
    (let ((sent (harness-openrouter--dispatch snapshot request on-event)))
      (setcar (cdr state) (plist-get sent :cancel))))
  nil)

(defun harness-openrouter--dispatch (snapshot request on-event)
  "Send REQUEST through the shared transport, unless a check refuses it.
SNAPSHOT is what the dispatch was authorised with: its policy, its
pinned route and, when the catalogue was just read, that reading.  The
policy is read again here -- the configured one now, not the one the
dispatch began with -- and the whole check runs against it immediately
before the body is built.  So a policy disabled, removed, made invalid
or pointed at another model while the catalogue was in flight refuses
the request instead of sending it under a weakened one.  The checked
policy is the only one the body, its restriction fields and its
headers are built from: `harness-openrouter--sending' carries it, and
`harness-openrouter--body-extra' reads that, never the variable.

The send is counted here, where it happens, and only after every check
passed: the shared retry layer counts what this policy authorised, so
one request of a pinned session is one POST, and a send beyond the
attempts or the seconds it allows -- a bound reached while a retry
waited, or a setting edited to a smaller one -- is refused, not sent.
The count and the clock are the request's own: they travel with it under
`harness-retry--request-key', so a recap or a judge's question made for
the same session beside this request neither spends this request's
budget nor starts it again.

What authorised the send -- the checked policy and the exact pinned
route -- is recorded in that same request-local state, and handed back
in the request's `done' event.  A repeat of the request is therefore a
repeat of *that* request (`harness-openrouter--resend-refusal'), not a
new one prepared under whatever policy is in force by then.
What a request asks a model to write is not decided here: its own
`:max-tokens' is its own, and a ceiling on it belongs to the request
layer (`harness-provider-max-output-tokens'), not to a routing policy."
  (let* ((route (plist-get snapshot :route))
         (session (plist-get request :session))
         (session-id (plist-get session :id))
         (in-force harness-openrouter-routing)
         (earlier (or (harness-openrouter--not-routing-refusal in-force)
                      (harness-openrouter--policy-changed-refusal
                       (plist-get snapshot :policy) in-force)
                      (harness-openrouter--pin-refusal
                       in-force route (plist-get snapshot :reading))))
         ;; The shared layer reads the bounds as they are now, so a retry
         ;; that waited through an edit is measured by them, and only a
         ;; request every other check allowed takes a send from the count.
         (sent (harness-retry-send request))
         (refusal (or earlier (plist-get sent :refusal)))
         (policy in-force))
    (if refusal
        (progn
          (harness-openrouter--refuse session-id on-event refusal)
          (list :cancel #'ignore))
      (let* ((counted (plist-get sent :request))
             (harness-openrouter--sending policy)
             ;; What this send was authorised by, in the request's own
             ;; state: a repeat of it is checked against this, never
             ;; against a policy or a pin read later, and never sent
             ;; ungoverned when this is gone.
             (counted (harness-retry-authorise
                       counted (list :policy policy :route route))))
        (harness-openai--complete
         (harness-openrouter--endpoint)
         (plist-put counted :openrouter-route route))))))

(defun harness-openrouter--complete (request)
  "Send REQUEST to the session's pinned endpoint, or refuse to send it.
A request without an enabled policy is the generic completion,
unchanged.  With one: a session with no pin is a new session and gets
one chosen from a fresh catalogue; a pinned session is checked again --
model, providers, the pin's recorded identity and price, the maximum
and the catalogue -- and refused with a stop reason when the check
fails.  Nothing is switched: a switch is the user's
\(`harness-openrouter-switch')."
  (let* ((harness-openrouter--ephemeral (and (plist-get request :ephemeral) t))
         (on-event (or (plist-get request :on-event) #'ignore))
         (policy harness-openrouter-routing)
         (session (plist-get request :session))
         (session-id (plist-get session :id))
         ;; A request this module already sent carries what authorised it:
         ;; this is a repeat of that request, not a new one, and it is
         ;; judged as such whatever the configured policy says now.
         (repeat (harness-retry-authority-of request))
         (resend-refusal (and repeat (harness-openrouter--resend-refusal repeat policy))))
    (cond
     ;; A repeat is the request it repeats -- the same endpoint, under the
     ;; policy that authorised it.  One whose policy was removed, disabled,
     ;; narrowed or otherwise edited is refused here, before any branch
     ;; that would prepare a request afresh under the policy of the moment:
     ;; re-selecting for it would be the silent switch the policy prevents,
     ;; and sending it ungoverned would be worse.
     (resend-refusal
      (harness-openrouter--refuse session-id on-event resend-refusal)
      (list :cancel #'ignore))
     ;; No policy at all: the provider as it always was.  (A repeat never
     ;; reaches here: it is refused above.)
     ((not (harness-openrouter-routing-p))
      (harness-openai--complete (harness-openrouter--endpoint) request))
     ;; A policy that cannot be checked, or one that is configured but not
     ;; enabled, sends nothing: an unrestricted request is exactly what a
     ;; policy exists to prevent.
     ((harness-openrouter--policy-error policy)
      (let ((detail (harness-openrouter--policy-error policy)))
        (harness-openrouter--paused session-id 'policy-invalid detail)
        (funcall on-event (list :type 'done :stop-reason 'error
                                :error-kind 'policy-invalid
                                :error (format "OpenRouter routing policy is incomplete: %s"
                                               detail)))
        (list :cancel #'ignore)))
     ((not (harness-json-true-p (plist-get policy :enabled)))
      (harness-openrouter--paused session-id 'disabled
                                  "the policy is configured but not enabled")
      (funcall on-event (list :type 'done :stop-reason 'error
                              :error-kind 'disabled
                              :error "OpenRouter routing is configured but not enabled"))
      (list :cancel #'ignore))
     (t
      (let ((wanted (format "openrouter:%s" (plist-get policy :model))))
        (cond
         ((not (equal (plist-get request :model) wanted))
          (harness-openrouter--paused
           session-id 'model-mismatch
           (format "the policy routes %s only, and %s was asked for"
                   wanted (plist-get request :model)))
          (funcall on-event (list :type 'done :stop-reason 'error
                                  :error-kind 'route-paused
                                  :error (format "OpenRouter routing: %s was asked for, not %s"
                                                 (plist-get request :model) wanted)))
          (list :cancel #'ignore))
         ;; A repeat goes back to the endpoint the request that failed was
         ;; authorised for, under the policy that authorised it -- never to
         ;; the session's pin of the moment, which a switch may have moved
         ;; since: the request is disclosed where it was disclosed, or not
         ;; at all.  The recorded route is checked exactly as a pin is, so
         ;; its price and its endpoint identity are re-read, and a stale
         ;; reading is refreshed before anything is sent.
         (repeat
          (harness-openrouter--complete-pinned
           (plist-get repeat :policy) session-id (plist-get repeat :route)
           request on-event))
         ((harness-openrouter--route-of session)
          (harness-openrouter--complete-pinned
           policy session-id (harness-openrouter--route-of session) request on-event))
         (t
          (harness-openrouter--complete-new policy session-id request on-event))))))))

(defun harness-openrouter--complete-pinned (policy session-id route request on-event)
  "Complete REQUEST in pinned SESSION-ID for ROUTE under POLICY.
A refusal that needs no fresh catalogue stops here; one about the pin's
reading being too old to be evidence of its price reads the catalogue
first and revalidates the pin against it.  Nothing is sent until no
refusal stands.

Either path sends the pin with its model's canonical slug recorded: one
written before this module recorded slugs is completed first
\(`harness-openrouter--ensure-canonical'), once, and every later dispatch
of it finds the slug already there.  Without that, such a pin would be
sent, answered, and then refused by its own audit -- every time -- for a
request that worked."
  (let ((state (list nil nil)))
    (let ((refusal (harness-openrouter--pin-refusal policy route)))
      (cond
       ((and refusal (not (eq (car refusal) 'catalogue-stale)))
        (harness-openrouter--refuse session-id on-event refusal))
       ((null refusal)
        ;; The pin is evidence fresh enough to send on.  The route is
        ;; completed from its model's slug before it goes out; that is a
        ;; request only for a pin that has no slug, and once per pin.
        (harness-then
         (harness-openrouter--ensure-canonical session-id route)
         (lambda (route)
           (unless (harness-openrouter--cancelled-p state)
             (let ((refusal (harness-openrouter--pin-refusal policy route)))
               (if (and refusal (not (eq (car refusal) 'catalogue-stale)))
                   (harness-openrouter--refuse session-id on-event refusal)
                 (harness-openrouter--start-pinned
                  state (list :policy policy :route route) request on-event)))))))
       (t
        (harness-then
         (harness-all (list (harness-openrouter--choose-now policy)
                            (harness-openrouter--ensure-canonical session-id route)))
         (lambda (values)
           (let ((reading (nth 0 values))
                 (route (nth 1 values)))
             (unless (harness-openrouter--cancelled-p state)
               ;; The catalogue may have taken a moment, and the policy that
               ;; sent for it is not necessarily the one in force now: the
               ;; route, the limits and the privacy fields all have to
               ;; describe one policy, and only a policy still in force can
               ;; authorise the request.
               (let* ((in-force harness-openrouter-routing)
                      (refusal (or (harness-openrouter--not-routing-refusal in-force)
                                   (harness-openrouter--policy-changed-refusal
                                    policy in-force)
                                   (harness-openrouter--pin-refusal
                                    in-force route reading))))
                 (if refusal
                     (harness-openrouter--refuse session-id on-event refusal)
                   (progn
                     (harness-openrouter--degraded session-id reading)
                     (harness-openrouter--start-pinned
                      state (list :policy in-force :route route :reading reading)
                      request on-event)))))))
         (lambda (err)
           (unless (harness-openrouter--cancelled-p state)
             (harness-openrouter--catalogue-failure session-id on-event err)))))))
    (harness-openrouter--cancel-handle state)))

(defun harness-openrouter--catalogue-failure (session-id on-event err)
  "End the request of SESSION-ID ON-EVENT because its catalogue could not be read.
ERR is the fetch's rejection, and what it says is what the pause says: a
server that refused the read reads as its HTTP status and its own message, a
connection that never opened as the transport's failure.  It is the reason
the session stopped, so it is never replaced by a description of the
rejection's shape (see `harness-error-message')."
  (let ((detail (format "the endpoint catalogue could not be read: %s"
                        (harness-error-message err))))
    (harness-openrouter--paused session-id 'catalogue-unavailable detail)
    (funcall on-event (list :type 'done :stop-reason 'error
                            :error-kind 'catalogue-unavailable
                            :error (format "OpenRouter routing paused: %s" detail)))))

(defun harness-openrouter--complete-new (policy session-id request on-event)
  "Complete REQUEST in a new SESSION-ID: choose an endpoint, then send it.
Nothing is sent until the pin exists."
  (let ((state (list nil nil)))
    (harness-then
     (harness-openrouter--choose-now-with-slug policy)
     (lambda (reading)
       (unless (harness-openrouter--cancelled-p state)
         ;; The policy is the one in force now, not the one that sent for
         ;; the catalogue: a session must not be pinned by a policy the
         ;; operator has replaced, and the pin, the limits and the privacy
         ;; fields must all come from the one policy that authorised it.
         ;; The reading may be an older one whose refresh failed
         ;; (`harness-openrouter--reading-for'); it is inside the policy's
         ;; freshness bound, and the dispatch says so before it sends.
         (let* ((in-force harness-openrouter-routing)
                (refusal (or (harness-openrouter--not-routing-refusal in-force)
                             (harness-openrouter--policy-changed-refusal
                              policy in-force)))
                (decision (and (not refusal)
                               (harness-openrouter--select-decision
                                in-force (plist-get reading :endpoints)
                                (plist-get reading :at)))))
           (cond
            (refusal (harness-openrouter--refuse session-id on-event refusal))
            ((not (plist-get decision :ok))
             (harness-openrouter--refuse
              session-id on-event
              (cons (or (plist-get decision :reason) 'route-paused)
                    (plist-get decision :detail))))
            (t
             (let* ((route (harness-openrouter--store-route
                            session-id (harness-openrouter--route-plist
                                        decision (plist-get reading :canonical-slug))))
                    (snapshot (list :policy in-force :route route)))
               (harness-openrouter--degraded session-id reading)
               (harness-openrouter--hint
                session-id
                (format "OpenRouter endpoint %s pinned for this session (cache cold)"
                        (plist-get route :slug)))
               ;; The request goes out with the session as it is now: the
               ;; catalogue read may have taken a moment, and the route the
               ;; body describes is the one just stored.  A cancelled
               ;; request is not sent, and does not re-pin: the pin stored
               ;; is the endpoint the session will use when it is sent.
               (harness-openrouter--start-pinned
                state snapshot
                (plist-put (copy-sequence request) :session
                           (or (ignore-errors (harness-call 'session/get session-id))
                               (plist-get request :session)))
                on-event)))))))
     (lambda (err)
       (unless (harness-openrouter--cancelled-p state)
         (harness-openrouter--catalogue-failure session-id on-event err))))
    (harness-openrouter--cancel-handle state)))

(defun harness-openrouter--refuse (session-id on-event refusal)
  "Pause SESSION-ID for REFUSAL, a (REASON . DETAIL), and end with it."
  (harness-openrouter--paused session-id (car refusal) (cdr refusal))
  (funcall on-event (list :type 'done :stop-reason 'error
                          :error-kind (car refusal)
                          :error (format "OpenRouter routing paused (%s): %s"
                                         (car refusal) (cdr refusal))))
  nil)

;;;; Switching, by hand only

(defun harness-openrouter-switch (session-id provider &optional why)
  "Pin SESSION-ID to PROVIDER's endpoint, explicitly, and return the new route.
PROVIDER is one of the policy's `:providers'.  A switch starts a
conversation the provider's cache does not hold, so it is never
automatic: the price rule selects for a new session only.  This is the
one way a pin moves, and it is the user's.  It refuses while the session
has a turn at work, and checks the whole policy again -- the provider is
allowed, its endpoint is exactly one standard endpoint of this model in a
fresh catalogue, and its current price is inside the maximum -- and
records the route as `switched' with WHY.  A provider the policy does not
name cannot be switched to: this call never relaxes the allowlist."
  (unless (harness-openrouter-routing-enabled-p)
    (error "OpenRouter routing is not enabled"))
  (let* ((policy harness-openrouter-routing)
         (session (harness-call 'session/get session-id))
         (named (format "%s" provider)))
    (unless (member named (plist-get policy :providers))
      (error "No allowed provider %s in the policy" provider))
    (when (memq (plist-get session :status) '(running blocked))
      (error "Session %s is busy; stop its turn before switching endpoint" session-id))
    (when-let* ((problem (harness-openrouter--policy-error policy)))
      (error "Cannot switch: %s" problem))
    (harness-then
     (harness-openrouter--choose-now-with-slug policy)
     (lambda (reading)
       ;; A switch is a person's decision, made about the policy they had
       ;; in hand: one replaced while the catalogue was in flight is not
       ;; the policy to pin under, so the switch is refused and can be
       ;; asked for again under the new one.
       (let ((in-force harness-openrouter-routing))
         (when-let* ((refusal (or (harness-openrouter--not-routing-refusal in-force)
                                  (harness-openrouter--policy-changed-refusal
                                   policy in-force))))
           (error "Cannot switch to %s: %s" named (cdr refusal)))
         (unless (member named (plist-get in-force :providers))
           (error "No allowed provider %s in the policy" named))
         (let* ((narrow (list :model (plist-get in-force :model)
                              :providers (list named)
                              :max-price (plist-get in-force :max-price)
                              :freshness (plist-get in-force :freshness)))
                (decision (harness-openrouter-select
                           narrow (plist-get reading :endpoints) (plist-get reading :at))))
           (unless (plist-get decision :ok)
             (error "Cannot switch to %s: %s" named (plist-get decision :detail)))
           (let ((route (plist-put (harness-openrouter--route-plist
                                    decision (plist-get reading :canonical-slug))
                                   :basis "switched")))
             (setq route (plist-put route :why (or why "requested")))
             (harness-openrouter--store-route session-id route)
             (harness-openrouter--hint session-id
                                       (format "OpenRouter endpoint %s pinned by hand; its cache starts cold"
                                               (plist-get route :slug)))
             route)))))))

;;;; What this provider's requests need from the shared retry layer
;;
;; Retrying is not this module's: the bounds, the wait, the count and
;; the repeat are `harness-retry''s, for every provider alike.  What is
;; this module's is which requests may be sent at all, and that is why
;; it asks for them to be counted: a request a policy governs is
;; authorised -- pin, provider allowlist, recorded price, the fresh
;; catalogue -- immediately before it is sent (`harness-openrouter--dispatch'),
;; and a repeat is a send like any other.  Counting them there is what
;; makes "one request" mean one POST; the lower layer is asked for no
;; replay of a governed request, since a replay inside one transport call
;; would be a send after a policy, a price or a pin it never re-read.
;;
;; The shared layer keeps the two bounds it keeps for every provider:
;; `harness-retry-max-attempts' (the first attempt and its tries) and
;; `harness-retry-max-seconds' (the request and its retries, from its
;; first send).  A send either bound no longer allows is refused at the
;; dispatch with the bound that stopped it, and nothing is replayed.
;;
;; A typed rejection that no identical request can pass is decoded here,
;; as `permanent' (`harness-openrouter--failure-kind'), and the shared
;; layer ends the turn at once instead of repeating it.

(defun harness-openrouter--retry-policy (session)
  "Return what SESSION's requests need retried, for the shared retry layer.
A session on the policy's model is one this policy governs: its sends
are counted (`:count-sends') and the transport replays none of them
\(`harness-retry-transport-retries').  A session this policy does not
route -- another model, another provider, or any session while no policy
routes -- has nothing of its own to say and is answered here with nil,
so that the shared layer treats it exactly as any other provider's."
  (when (harness-openrouter--routed-session-p harness-openrouter-routing session)
    (list :owner "OpenRouter" :count-sends t)))

(defun harness-openrouter--routed-session-p (policy session)
  "Non-nil when SESSION is one POLICY routes.
The model is the policy's, and the session's provider is OpenRouter: a
session of another provider on a same-named model is not this policy's
to govern."
  (and (harness-openrouter-routing-enabled-p policy)
       (equal (plist-get session :model)
              (format "openrouter:%s" (plist-get policy :model)))))

(defun harness-openrouter--failure-type-of (stream error)
  "Return the typed code STREAM failed with ERROR, or nil.
The chunk reader keeps `error.metadata.error_type' when the failure
arrives as a chunk (`harness-openrouter--error-type'); an HTTP error
body is not a chunk, so the code is read from the `error_type=' this
module appended to the message it built (`harness-openrouter--error-detail')."
  (or (plist-get (harness-openai--stream-dialect-state stream) :error-type)
      (when (and (stringp error)
                 (string-match "error_type=\\([a-z0-9_]+\\)" error))
        (match-string 1 error))))

(defun harness-openrouter--declined-provider (stream error)
  "Return the upstream provider STREAM's ERROR names as having declined, or nil.
A streamed failure keeps it in its chunk (`harness-openrouter--chunk');
an HTTP failure's body is not a chunk, so the code is read from the
`provider=' this module appended to the message it built
\(`harness-openrouter--error-detail')."
  (or (plist-get (harness-openai--stream-dialect-state stream) :declined-provider)
      (when (and (stringp error)
                 (string-match "provider=\\([^;)]+\\)" error))
        (string-trim (match-string 1 error)))))

(defun harness-openrouter--limit-scope (stream error)
  "Return how far STREAM's failure says a rate limit reaches, or nil.
The failure's own fields decide it, never an assumption:

- `pool' when the answer names the upstream endpoint that declined
  (`error.metadata.provider_name'), which is that endpoint's bad minute
  and not Cohere's;
- `account' when nothing names an upstream -- a limit OpenRouter itself
  imposed on the key that sent the request applies to every endpoint of
  the account, and resting only the pinned one would keep sending into
  a limit that is not about it;
- `account' too when the named upstream is OpenRouter itself.

Only a governed request's rate limit is answered at all: a request this
module did not route keeps the generic reading and answers nil, so an
ordinary provider's pool is never rested on this module's say-so."
  (when (and (plist-get (harness-openai--stream-dialect-state stream) :route)
             (eq (harness-openrouter--failure-kind stream error) 'rate-limit))
    (let ((declined (harness-openrouter--declined-provider stream error)))
      (if (and (stringp declined)
               (not (string-empty-p declined))
               (not (harness-openrouter--same-provider-p "OpenRouter" declined)))
          'pool
        'account))))

(defun harness-openrouter--failure-kind (stream error)
  "Return the shared kind of STREAM's failure, from its typed code, or nil.
OpenRouter names the kind of a failure in `error.metadata.error_type'.
A code in `harness-openrouter--permanent-types' is `permanent': the
identical request cannot pass it, so it is worth no repeat, and the
shared retry layer ends the turn at once.  A code in
`harness-openrouter--transient-types' is the transport's or a rate
limit's bad minute (`transport', `rate-limit'), which the shared layer
bounds like any other provider's.

Only a request a routing policy governs is read this way: its typed
codes were what the policy's own retry bounds were written for.  Any
other request of this endpoint -- the provider with no policy, the
provider as it always was -- answers nil and keeps the generic reading,
so nothing about an ordinary provider changes."
  (when (plist-get (harness-openai--stream-dialect-state stream) :route)
    (let* ((type (harness-openrouter--failure-type-of stream error))
           (status (harness-openai--stream-status stream)))
      (cond
       ((and (stringp type) (member type harness-openrouter--permanent-types))
        'permanent)
       ((and (stringp type) (member type harness-openrouter--transient-types))
        (if (string-match-p "rate_limit\\|too_many" type) 'rate-limit 'transport))
       ((equal status 429) 'rate-limit)
       (t nil)))))

(defun harness-openrouter--withdrawn-refusal (request)
  "Return (REASON . DETAIL) when REQUEST would repeat a governed one ungoverned.
A request this module already sent carries what authorised it
\(`harness-retry-authority-of').  Sending it again with no policy
configured would repeat a restricted request with no restriction, no pin
and no count -- the shape of widening this module exists to prevent --
so it is refused, and the request a session starts afresh under no policy
is the operator's plain provider again.  Nil for anything that is not
such a repeat."
  (when (harness-retry-authority-of request)
    (cons 'policy-changed
          "the routing policy was removed while this request was being retried, so it is not sent unrestricted")))

(defun harness-openrouter--resend-refusal (authority policy)
  "Return (REASON . DETAIL) when a repeat under AUTHORITY may not be sent.
AUTHORITY is what this module recorded when it sent the request --
`:policy', the checked policy, and `:route', the exact pinned endpoint --
and POLICY is the policy in force now.  A repeat is that request's
repeat, so it is sent under the policy that authorised it, to the
endpoint that policy pinned, and never to one chosen since: a policy
edited to another model, another provider, another maximum or another
freshness bound is a different authority, and the repeat is refused
rather than reselected under it."
  (let ((authorised (plist-get authority :policy)))
    (cond
     ((not (listp authorised))
      (cons 'policy-changed
            "this request carries no record of what authorised it, so its repeat cannot be sent"))
     ((null (harness-openrouter-routing-p))
      (cons 'policy-changed
            "the routing policy was removed while this request was being retried, so it is not sent unrestricted"))
     (t
      (when-let* ((change (harness-openrouter--policy-change authorised policy)))
        (cons 'policy-changed change))))))

(defun harness-openrouter--guard (session target _why &optional failure)
  "`harness-fallback-guard-functions' guard: keep a pinned session pinned.
A session this policy routes has one pinned endpoint and one model on
purpose; moving it to another model -- another provider, another host or
another checkpoint -- is not a fallback but a silent widening of the
allowed set, and it is the user's decision (`harness-openrouter-switch').
So a move is refused, with the reason and what to do about it, whether
the quota ran out, the budget did, or anything else did.

FAILURE, when the fallback asks after a failed step, is that step's
`done' event.  A request this module sent carries what authorised it
\(`harness-retry-authority-of'), and that is what decides here: the
request was disclosed to one endpoint under one policy, so it is not
disclosed to another host because the policy was disabled or removed
while it was in flight.  An authority is therefore refused whether or
not a policy is configured now -- disabling a policy is documented as a
refusal, never as permission to send the request elsewhere.  A session
this policy does not route, whose failure carries no such record, is not
guarded."
  (let* ((policy harness-openrouter-routing)
         (pin (harness-openrouter--route-of session))
         (authority (and failure (harness-retry-authority-of failure)))
         (authorised (or (plist-get authority :route) pin)))
    (when (and (not (equal target (plist-get session :model)))
               (or authority
                   (and (harness-openrouter-routing-enabled-p policy)
                        (equal (plist-get session :model)
                               (format "openrouter:%s" (plist-get policy :model))))))
      (format (concat "session %s is pinned to OpenRouter endpoint %s for %s, and the policy allows no other; "
                      "stop it, top up or wait for the quota, or switch endpoint by hand with M-x harness-openrouter-switch")
              (or (plist-get session :id) "?")
              (or (plist-get authorised :slug) "(none chosen yet)")
              (or (plist-get (or (plist-get authority :policy) policy) :model)
                  (plist-get session :model))))))

;;;; Registration

(defun harness-openrouter--models (&optional refresh)
  "Return a promise of OpenRouter's model list.
The list is the generic one; the per-endpoint catalogue a pin is chosen
from is separate (`harness-openrouter--catalogue')."
  (if harness-openrouter-list-models
      (harness-openai--models (harness-openrouter--endpoint) refresh)
    (harness-resolved
     (when-let* ((cached (gethash 'openrouter harness-openai--models-cache)))
       (cdr cached)))))

(defun harness-openrouter-refresh ()
  "Register the OpenRouter provider as this module's own, and return its id."
  (interactive)
  (harness-openai-claim-endpoint 'openrouter)
  (harness-openai-register-endpoint (harness-openrouter--endpoint))
  'openrouter)

(defun harness-openrouter--init ()
  "Register the provider, what its requests need retried, and its guard.
The shared retry layer asks `harness-openrouter--retry-policy' how a
session's requests are retried, so this module answers it here, once,
and answers nothing else about retrying: the bounds, the wait and the
repeat are that layer's.  The guard keeps a pinned session on its pinned
endpoint however it failed."
  (harness-openrouter-refresh)
  (add-hook 'harness-retry-policy-functions #'harness-openrouter--retry-policy)
  (add-hook 'harness-fallback-guard-functions #'harness-openrouter--guard))

(defun harness-openrouter--shutdown ()
  "Drop what this module added and its cached catalogues."
  (remove-hook 'harness-retry-policy-functions #'harness-openrouter--retry-policy)
  (remove-hook 'harness-fallback-guard-functions #'harness-openrouter--guard)
  (maphash (lambda (_model episode)
             (when (timerp (plist-get episode :timer))
               (cancel-timer (plist-get episode :timer))))
           harness-openrouter--catalogue-failures)
  (clrhash harness-openrouter--catalogue)
  (clrhash harness-openrouter--fetching)
  (clrhash harness-openrouter--catalogue-failures)
  (clrhash harness-openrouter--invalidations))

(harness-defmethod openrouter/route (session-id)
  "Return SESSION-ID's pinned OpenRouter route, or nil."
  (ignore-errors (harness-openrouter--route-of (harness-call 'session/get session-id))))

;; Registered when this file loads, as the generic module registers its
;; own endpoints, so the provider exists before its module is started and
;; a session can use OpenRouter without waiting for module init.
(harness-openrouter-refresh)

(harness-define-module 'provider-openrouter
  :doc "OpenRouter provider: request fields, price-aware endpoint pinning, error detail."
  :requires '(provider provider-openai retry)
  :init #'harness-openrouter--init
  :shutdown #'harness-openrouter--shutdown)

(provide 'harness-provider-openrouter)
;;; harness-provider-openrouter.el ends here
