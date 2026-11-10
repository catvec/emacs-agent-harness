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
;; vetted endpoint identities that may serve it, the model owner's own
;; published price as the most this may cost, a freshness bound, what
;; each endpoint's privacy evidence must establish, and retry bounds.  A
;; new session gets the cheapest vetted endpoint that is not dearer than
;; the owner's own price; the choice is stored on the session and every
;; later request is restricted to it.  Nothing is switched
;; automatically: a pin that stops qualifying pauses the session,
;; because a switch is a cache-cold transition and so is the user's
;; decision.
;;
;; Every dispatch of a pinned session checks the whole policy again --
;; the owner price's age and the ceiling under the price the pin
;; recorded, the endpoint's own evidence and its age, and the catalogue
;; -- and pauses rather than sending.  It never falls back: a pinned
;; session is guarded from `harness-fallback' too, so running out of
;; quota or money stops the turn instead of moving a cache-cold
;; conversation to a model the policy never vetted.
;;
;; The policy's `:privacy' is a requirement, and each endpoint carries
;; its own evidence.  They are separate facts, not one badge: no
;; training, ZDR eligibility, whether Safety Retention is acceptable,
;; and the processing geography are compared one by one, because
;; OpenRouter's `zdr: true' can include Safety Retention when the account
;; allows it and is therefore not proof of strict zero retention on its
;; own.
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

  :enabled  t to let the policy route requests.  Without it a
            configured policy still allows nothing: it is a policy, not
            an activation.
  :model    the exact model the policy was vetted for, e.g.
            \"deepseek/deepseek-v4.1-flash-1017\".  Only
            \"openrouter:MODEL\" is routed by it.
  :owner-price  the model owner's own published platform price, in US
            dollars per million tokens: (:prompt N :completion N
            :cache-read N).  It is the most this policy will pay, so a
            vetted endpoint dearer than it is never chosen.  It must
            name where it was read and when, because it is a claim
            about someone else's price list:
              :source  the page it was read from
              :read-at a float time
              :max-age seconds it may be trusted for
  :endpoints  the vetted endpoints that may serve the model; the
            cheapest one under `:owner-price' is chosen:
            :key           a name for the endpoint in state and hints
            :slug          the exact endpoint tag, e.g. \"deepinfra/fp8\";
                           a base provider slug is refused, because
                           OpenRouter matches one across every variant
                           and region of that provider
            :provider      the provider name the catalogue gives it
            :tag           the catalogue tag; must equal :slug
            :tier          nil for the standard tier, else \"flex\"
            :quantization  the quantization the catalogue must report
            :host          the host its traffic goes to
            :evidence      this endpoint's own privacy evidence, a plist
                           with the same keys as `:privacy' plus
                           `:checked-at', `:source' and `:max-age'
  :freshness  seconds a catalogue reading may be old at dispatch
  :privacy    what every endpoint's evidence must establish, each key
            machine-checkable because a free-text claim cannot be
            compared: :no-training t, :retention a
            `harness-openrouter--retention-classes' member (\"zero\"),
            :zdr-eligible t, :safety-retention `:excluded' or
            `:allowed', and :regions the allowed processing geography.
            This is a requirement, not evidence: one endpoint's
            evidence never stands for another's.
  :retry      (:max-attempts N :max-seconds N :max-output-tokens N),
            bounds for retrying the same pinned endpoint

Selection filters the endpoints it is given to those not dearer than
`:owner-price' in any priced component and takes the cheapest of them.
`:endpoints' is the allowlist: an endpoint the policy does not name is
never a candidate, however cheap the catalogue says it is.  A candidate
whose listing cannot be read blocks the whole decision rather than being
dropped, because `cannot read this price' is not `this price is too
high', and dropping it would quietly pick the next provider.  A listing
whose rate depends on the time of the week blocks the same way: one
fixed number cannot stand for it.

Once a session is pinned every dispatch checks the whole policy again --
the owner price's age, the price the pin recorded against the current
ceiling, the endpoint's own evidence and its age, and the catalogue the
pin was chosen from -- and pauses the session when any of them fails.
It never chooses another endpoint: a switch is the user's
(`harness-openrouter-switch').  A session this policy routes is also
guarded from `harness-fallback': running out of quota, out of money or
out of anything else stops the turn instead of moving a cache-cold
conversation to a model the vetted set never covered.

Every field a check needs must be present and well formed: a policy with
a hole blocks rather than guesses.  No value here is a default: see
`harness-openrouter-routing-validate', docs/openrouter-pinning.md, and
the concrete values in it that wait for approval."
  :type '(choice (const :tag "Off" nil) (plist :tag "Policy"))
  :group 'harness)

(defcustom harness-openrouter-catalogue-ttl 60
  "Seconds a fetched endpoint catalogue is reused.
A policy's `:freshness' decides whether a reading may be used at
dispatch; this only keeps a burst of requests from fetching twice."
  :type 'integer :group 'harness)

(defcustom harness-openrouter-catalogue-timeout 20
  "Seconds a fetch of the endpoint catalogue may take."
  :type 'integer :group 'harness)

;;;; State

(defconst harness-openrouter--route-key :openrouter-route
  "Key of the pinned route in a session's `ext'.")

(defvar harness-openrouter--catalogue (make-hash-table :test 'equal)
  "Model id -> (:at FLOAT :endpoints LIST).")

(defvar harness-openrouter--fetching (make-hash-table :test 'equal)
  "Model id -> promise of an in-flight catalogue fetch.")

(harness-declare-event 'openrouter/route-selected
                       "(SESSION-ID ROUTE) when a session is pinned to an endpoint.")
(harness-declare-event 'openrouter/route-paused
                       "(SESSION-ID REASON DETAIL) when a pinned session may not send.")
(harness-declare-event 'openrouter/response-mismatch
                       "(SESSION-ID DETAIL) when an answer came from another endpoint.")

;;;; Prices, exactly
;;
;; The catalogue gives prices in US dollars per *token* as decimal
;; strings, and a policy gives ceilings in US dollars per *million*
;; tokens.  Emacs floats are binary, so a decimal such as 0.098 has no
;; exact float value and comparing through one puts rounding at the
;; boundary: a ceiling can end up under the price it was meant to admit,
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
point, so a ceiling and the price it bounds compare exactly whatever
their precision."
  (let ((text (cond ((integerp value) (and (>= value 0) (number-to-string value)))
                    ((floatp value)
                     ;; The decimal it prints as, not its binary value:
                     ;; 0.098 reads as 98/1000, which is the ceiling the
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

(defun harness-openrouter--ceiling-per-token (usd-per-million)
  "Return USD-PER-MILLION, a policy ceiling, as exact US dollars per token.
The division is exact, so no rounding decides whether a price is over
the ceiling.  Nil when it is not a decimal, which validation refuses."
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

(defun harness-openrouter--catalogue (model &optional refresh)
  "Return a promise of MODEL's endpoint catalogue, read at `:at'.
A reading older than `harness-openrouter-catalogue-ttl' is fetched
again; REFRESH always fetches.  A failed fetch rejects rather than
answering an older reading: a stale reading is never evidence that a
price changed."
  (let ((cached (gethash model harness-openrouter--catalogue)))
    (cond
     ((and cached (not refresh)
           (< (- (float-time) (or (plist-get cached :at) 0))
              harness-openrouter-catalogue-ttl))
      (harness-resolved cached))
     ((gethash model harness-openrouter--fetching))
     (t
      (let ((promise (harness-openrouter--fetch-catalogue model)))
        (puthash model promise harness-openrouter--fetching)
        (harness-then
         promise
         (lambda (records)
           (remhash model harness-openrouter--fetching)
           (let ((reading (list :at (float-time) :endpoints records)))
             (puthash model reading harness-openrouter--catalogue)
             reading))
         (lambda (err)
           (remhash model harness-openrouter--fetching)
           (signal (car err) (cdr err)))))))))

;;;; Policy validation

(defconst harness-openrouter--price-keys '(:prompt :completion :cache-read)
  "Prices every vetted endpoint and the owner's own price must name.
These are the three the policy compares.  A catalogue listing may carry
others (`input_cache_write', `internal_reasoning', a per-request fee,
an audio or image charge); those are not compared, so a listing that
prices them is `harness-openrouter--unpriceable-components' and blocks
rather than being read as if they cost nothing.")

(defconst harness-openrouter--known-pricing-keys
  '(:prompt :completion :input_cache_read :discount :overrides)
  "The catalogue pricing keys this module reads.
`:prompt', `:completion' and `:input_cache_read' are compared against
the owner price, `:discount' is recorded, and `:overrides' marks a rate
that varies by the time of the week.  Any other key is a billable
component this module cannot weigh.")

(defconst harness-openrouter--retention-classes '("zero")
  "Retention classes a policy and an endpoint's evidence may name.
\"zero\" is no retention of the request or the response after
processing.  A provider that states anything else -- a number of days,
\"unknown\", \"safety only\" -- is not this class, and a policy that
requires this class refuses it.  This is a vocabulary, not a claim: what
an endpoint's evidence records is what its source said, dated.")

(defconst harness-openrouter--privacy-keys
  '(:no-training :retention :zdr-eligible :safety-retention :regions :host)
  "What an endpoint's privacy evidence must state, each of it checkable.
`:no-training' t, `:retention' a `harness-openrouter--retention-classes'
member, `:zdr-eligible' t, `:safety-retention' `:excluded' or
`:allowed', `:regions' the hosting or processing geography, and `:host'
the host the endpoint's traffic goes to.  `:source', `:checked-at' and
`:max-age' date it.")

(defconst harness-openrouter--retry-keys
  '(:max-attempts :max-seconds :max-output-tokens)
  "The bounds a policy's `:retry' must give, each a positive integer.")

(defun harness-openrouter--retry-error (retry)
  "Return why RETRY, a policy's `:retry', is not a set of bounds, or nil."
  (cond
   ((not (listp retry)) "the policy names no retry bounds")
   ((cl-some (lambda (key)
               (let ((value (plist-get retry key)))
                 (not (and (integerp value) (> value 0)))))
             harness-openrouter--retry-keys)
    "the retry bounds are incomplete or not positive integers")
   (t nil)))

(defun harness-openrouter--evidence-error (policy endpoint evidence)
  "Return why EVIDENCE may not stand for ENDPOINT under POLICY, or nil.
EVIDENCE must state, for this exact endpoint, everything the policy
requires (`harness-openrouter--privacy-keys'), date itself, cite where
it was read and still be inside the age it names.  Anything missing,
unknown, expired, or about another host blocks this endpoint: a policy
does not infer an endpoint's data policy from another one's, and it does
not decide on Noah's behalf what is acceptable."
  (let ((wanted (plist-get policy :privacy))
        (slug (plist-get endpoint :slug)))
    ;; The shape only: whether the evidence is still fresh is decided at
    ;; each dispatch, not here, so a policy that is complete is still a
    ;; valid policy once its evidence ages, and the stop says what lapsed.
    (cond
     ((not (and (listp evidence) evidence))
      (format "%s has no privacy evidence of its own" slug))
     ((not (equal (plist-get evidence :host) (plist-get endpoint :host)))
      (format "%s's evidence names host %s, not the vetted %s"
              slug (or (plist-get evidence :host) "none")
              (or (plist-get endpoint :host) "none")))
     ((not (harness-json-true-p (plist-get evidence :no-training)))
      (format "%s's evidence does not rule out training" slug))
     ((not (member (plist-get evidence :retention) harness-openrouter--retention-classes))
      (format "%s's evidence states retention %s, not one this policy can read"
              slug (or (plist-get evidence :retention) "none")))
     ((not (equal (plist-get evidence :retention) (plist-get wanted :retention)))
      (format "%s keeps %s; the policy requires %s"
              slug (plist-get evidence :retention) (plist-get wanted :retention)))
     ((not (harness-json-true-p (plist-get evidence :zdr-eligible)))
      (format "%s's evidence does not establish ZDR eligibility" slug))
     ;; Compared as values, not as truth: `:excluded' and `:allowed' are
     ;; both non-nil, so `(and value t)' would make them the same fact.
     ((not (eq (plist-get evidence :safety-retention)
               (plist-get wanted :safety-retention)))
      (format "%s's Safety Retention standing (%s) is not the one the policy requires (%s)"
              slug (or (plist-get evidence :safety-retention) "none")
              (or (plist-get wanted :safety-retention) "none")))
     ((not (and (listp (plist-get evidence :regions)) (plist-get evidence :regions)
                (cl-every #'stringp (plist-get evidence :regions))))
      (format "%s's evidence names no processing or hosting region" slug))
     ((not (cl-subsetp (plist-get evidence :regions)
                       (plist-get wanted :regions) :test #'equal))
      (format "%s's regions (%s) are outside the regions the policy allows (%s)"
              slug (string-join (plist-get evidence :regions) ", ")
              (string-join (plist-get wanted :regions) ", ")))
     ((not (and (stringp (plist-get evidence :source))
                (not (string-empty-p (plist-get evidence :source)))))
      (format "%s's evidence cites no source" slug))
     ((not (numberp (plist-get evidence :checked-at)))
      (format "%s's evidence is not dated" slug))
     ((not (and (numberp (plist-get evidence :max-age))
                (> (plist-get evidence :max-age) 0)))
      (format "%s's evidence names no maximum age" slug))
     (t nil))))

(defun harness-openrouter--evidence-stale-error (endpoint evidence)
  "Return why ENDPOINT's EVIDENCE is too old to be trusted now, or nil.
This is the check a dispatch makes every time, not the policy's shape:
an endpoint whose evidence was inside its own age when the policy was
written and is not any more stops the request, with what to recheck."
  (let ((checked-at (plist-get evidence :checked-at))
        (max-age (plist-get evidence :max-age))
        (slug (plist-get endpoint :slug)))
    (when (and (numberp checked-at) (numberp max-age) (> max-age 0)
               (> (- (float-time) checked-at) max-age))
      (format "%s's privacy evidence was checked %d s ago; it is trusted for %s s, so recheck %s"
              slug (round (- (float-time) checked-at)) max-age
              (or (plist-get evidence :source) "its source")))))

(defun harness-openrouter--privacy-requirement-error (privacy)
  "Return why PRIVACY is not a machine-checkable requirement, or nil."
  (cond
   ((not (and (listp privacy) privacy)) "the policy states no privacy requirement")
   ((not (harness-json-true-p (plist-get privacy :no-training)))
    "the policy does not require that training on prompts is ruled out")
   ((not (member (plist-get privacy :retention) harness-openrouter--retention-classes))
    (format "the policy requires retention %s, which is not one this module can check"
            (or (plist-get privacy :retention) "none")))
   ((not (harness-json-true-p (plist-get privacy :zdr-eligible)))
    "the policy does not require ZDR eligibility")
   ((not (memq (plist-get privacy :safety-retention) '(:excluded :allowed)))
    "the policy does not say whether Safety Retention endpoints are acceptable")
   ((not (and (listp (plist-get privacy :regions)) (plist-get privacy :regions)
              (cl-every #'stringp (plist-get privacy :regions))))
    "the policy names no allowed processing region")))

(defun harness-openrouter--policy-error (policy)
  "Return why POLICY may not be used, a string, or nil when it is complete."
  (let ((problem nil)
        (model (plist-get policy :model))
        (endpoints (plist-get policy :endpoints))
        (freshness (plist-get policy :freshness))
        (owner (plist-get policy :owner-price))
        (retry (plist-get policy :retry)))
    (cond
     ((not (listp policy)) (setq problem "the policy is not a plist"))
     ((not (and (stringp model)
                (string-match-p "\\`[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\\'" model)))
      (setq problem "the policy names no exact model"))
     ((not (and (listp endpoints) endpoints))
      (setq problem "the policy names no endpoint"))
     ((not (and (numberp freshness) (>= freshness 0)))
      (setq problem "the policy names no freshness bound"))
     ((not (listp owner))
      (setq problem "the policy names no owner price to cap what it may pay"))
     ((cl-some (lambda (k) (not (harness-openrouter--decimal-p (plist-get owner k))))
               harness-openrouter--price-keys)
      (setq problem "the owner price is incomplete or not a plain decimal"))
     ((not (and (numberp (plist-get owner :read-at))
                (stringp (plist-get owner :source))
                (not (string-empty-p (plist-get owner :source)))))
      (setq problem "the owner price names no source or no date it was read"))
     ((not (and (numberp (plist-get owner :max-age))
                (> (plist-get owner :max-age) 0)))
      (setq problem "the owner price names no maximum age"))
     (t
      (setq problem (harness-openrouter--privacy-requirement-error
                     (plist-get policy :privacy)))))
    (unless problem
      (setq problem (harness-openrouter--retry-error retry)))
    (unless problem
      (let ((seen nil))
        (dolist (endpoint endpoints)
          (let ((key (plist-get endpoint :key))
                (slug (plist-get endpoint :slug)))
            (unless problem
              (cond
               ((not (and (stringp key) (not (string-empty-p key))))
                (setq problem "an endpoint has no key"))
               ((member key seen)
                (setq problem "an endpoint key is repeated"))
               ((not (and (stringp slug) (string-match-p "/" slug)))
                (setq problem (format "an endpoint names no exact slug (%s)" slug)))
               ((not (equal slug (plist-get endpoint :tag)))
                (setq problem (format "an endpoint's tag and slug differ (%s)" slug)))
               ((not (and (stringp (plist-get endpoint :provider))
                          (not (string-empty-p (plist-get endpoint :provider)))))
                (setq problem (format "an endpoint names no provider (%s)" slug)))
               ((and (plist-get endpoint :tier)
                     (not (equal (plist-get endpoint :tier) "flex")))
                (setq problem (format "an endpoint is not on the standard or flex tier (%s)" slug)))
               ((not (and (stringp (plist-get endpoint :host))
                          (not (string-empty-p (plist-get endpoint :host)))))
                (setq problem (format "an endpoint names no host (%s)" slug)))
               (t
                (setq problem (harness-openrouter--evidence-error
                               policy endpoint (plist-get endpoint :evidence))))))
            (push key seen)))))
    problem))

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
;;   * only the endpoints the policy names (the allowlist) are candidates;
;;   * any whose fresh listing is dearer than the model owner's own
;;     published price is dropped -- that is the most this policy pays;
;;   * the cheapest of what remains is chosen.
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

(defun harness-openrouter--owner-price (policy)
  "Return POLICY's owner price as exact per-token prices, or nil.
A plist of `:prompt', `:completion' and `:cache-read', each the exact
decimal US dollars per token the owner's published per-million figure
names.  The division is exact, so a price at the ceiling the owner
charges is not over it and a price above it is never admitted."
  (let ((owner (plist-get policy :owner-price)))
    (when (listp owner)
      (let ((prices (mapcar (lambda (key)
                              (harness-openrouter--ceiling-per-token (plist-get owner key)))
                            harness-openrouter--price-keys)))
        (and (cl-every #'consp prices)
             (list :prompt (nth 0 prices)
                   :completion (nth 1 prices)
                   :cache-read (nth 2 prices)))))))

(defun harness-openrouter--owner-price-error (policy)
  "Return why POLICY's owner price may not be trusted now, or nil."
  (let* ((owner (plist-get policy :owner-price))
         (read-at (plist-get owner :read-at))
         (max-age (plist-get owner :max-age)))
    (cond
     ((not (and (numberp read-at) (numberp max-age)))
      "the owner price is not dated")
     ((> (- (float-time) read-at) max-age)
      (format "the owner price was read %d s ago; the policy trusts it for %s s"
              (round (- (float-time) read-at)) max-age)))))

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

(defun harness-openrouter--slug-matches-p (slug record)
  "Non-nil when OpenRouter's SLUG selector would match RECORD.
OpenRouter documents a slug as `provider[/variant][/region][/tier]' and
matches it against every endpoint whose tag shares its segments, with
one exception: a slug that does not name a tier never matches a
tier endpoint.  So `deepinfra/fp8' selects `deepinfra/fp8' alone, not
its `flex' or `priority' siblings, while a later `deepinfra/fp8/us'
would be selected too -- which makes the slug ambiguous, and
`harness-openrouter--matching' refuses to pin an ambiguous one.  This is
that comparison: exact tag first, then a prefix at a segment boundary
unless the record is a tier endpoint."
  (let ((tag (plist-get record :tag)))
    (and (stringp slug) (stringp tag)
         (or (equal slug tag)
             (and (not (harness-openrouter--tier-endpoint-p record))
                  (string-prefix-p slug tag)
                  (> (length tag) (length slug))
                  (eq ?/ (aref tag (length slug))))))))

(defun harness-openrouter--match-set (policy records endpoint)
  "Return the records of RECORDS that ENDPOINT's slug would select.
Every record whose model is POLICY's and whose tag the slug matches, as
OpenRouter selects them (`harness-openrouter--slug-matches-p')."
  (let ((model (plist-get policy :model))
        (slug (plist-get endpoint :slug)))
    (cl-remove-if-not
     (lambda (record)
       (and (equal (plist-get record :model) model)
            (harness-openrouter--slug-matches-p slug record)))
     records)))

(defun harness-openrouter--matching (policy records endpoint)
  "Return the record of RECORDS that is exactly ENDPOINT, or nil.
Exactly means the slug selects exactly one record of this model, and
that record agrees on the tag, the provider name, the service tier and,
when the policy names one, the quantization.  Two records the slug
selects -- a new region or variant of the same endpoint -- make the
identity ambiguous, which returns nil as well: an ambiguous identity is
no identity, and blocking is what keeps a new regional variant from
joining the vetted set silently."
  (let ((matches (harness-openrouter--match-set policy records endpoint)))
    (when (and matches (null (cdr matches)))
      (let ((record (car matches)))
        (when (and (equal (plist-get record :tag) (plist-get endpoint :slug))
                   (equal (plist-get record :provider) (plist-get endpoint :provider))
                   (equal (plist-get record :tier) (plist-get endpoint :tier))
                   (or (null (plist-get endpoint :quantization))
                       (equal (plist-get record :quantization)
                              (plist-get endpoint :quantization))))
          record)))))

(defun harness-openrouter--prices-over (ceiling record)
  "Return the components of RECORD priced above CEILING, as strings.
A price the record does not give is over: unknown is not free, and it is
not a reading either, so it never earns a place in the sort.  Every
comparison is exact, so a price equal to the ceiling is not over it and
no rounding admits a price above it."
  (let (over)
    (dolist (key harness-openrouter--price-keys)
      (let ((most (plist-get ceiling key))
            (price (plist-get record key)))
        (when (or (null price) (harness-openrouter--decimal> price most))
          (push (format "%s %s > %s" (substring (symbol-name key) 1)
                        (or (harness-openrouter--usd-per-million price) "unknown")
                        (harness-openrouter--usd-per-million most))
                over))))
    (nreverse over)))

(defun harness-openrouter--unpriceable-components (record)
  "Return the billable components of RECORD this policy cannot weigh.
The policy compares prompt, completion and cache-read against the
owner's price.  A listing that also prices something else -- a
per-request fee, an image, audio, a cache write, internal reasoning --
charges for a component the ceiling does not bound, so it is not a
listing the policy can read as under the ceiling.  Nil when the listing
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
prices a component the ceiling does not cover, and one whose endpoint
the catalogue reports as unavailable (`:status' anything but zero)."
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
          (format "prices %s, which the owner price does not cover"
                  (string-join (harness-openrouter--unpriceable-components record) ", "))))))

(defun harness-openrouter--standing (policy records endpoint ceiling)
  "Return ENDPOINT's standing against POLICY from RECORDS and CEILING.
A plist with `:standing' one of:

  `eligible' -- its fresh listing is exact and no component is dearer
                than the owner price; `:order' is the sort key
  `out'      -- its fresh listing is exact and some component is dearer,
                so it is known not to qualify
  `unknown'  -- its listing cannot be read, which says nothing about its
                price, so it blocks rather than being dropped

and `:endpoint', `:record', `:reason' and `:detail'."
  (let* ((slug (plist-get endpoint :slug))
         (record (harness-openrouter--matching policy records endpoint))
         (unreadable (harness-openrouter--unreadable record))
         (stale (harness-openrouter--evidence-stale-error
                 endpoint (plist-get endpoint :evidence))))
    (cond
     ;; An endpoint whose evidence is too old to be trusted now is not one
     ;; this policy may send to, and it blocks rather than being dropped:
     ;; it could have been the one chosen.
     (stale
      (list :standing 'unknown :endpoint endpoint :record record
            :reason 'privacy-stale :detail stale))
     (unreadable
      (list :standing 'unknown :endpoint endpoint :record record
            :reason (car unreadable)
            :detail (format "%s %s" slug (cdr unreadable))))
     ((let ((over (harness-openrouter--prices-over ceiling record)))
        over)
      (list :standing 'out :endpoint endpoint :record record
            :reason 'over-owner-price
            :detail (format "%s over the owner price: %s"
                            slug (string-join (harness-openrouter--prices-over ceiling record)
                                              ", "))))
     (t
      (list :standing 'eligible :endpoint endpoint :record record
            ;; One input token and one output token, in the same unit, so
            ;; the sort needs no guess at the traffic's mix; the cache-read
            ;; price breaks a tie, and the key makes the order total.  The
            ;; prices stay exact decimals; `harness-openrouter--cheapest'
            ;; compares them exactly.
            :order (list (harness-openrouter--decimal-sum
                          (plist-get record :prompt) (plist-get record :completion))
                         (plist-get record :cache-read)
                         (plist-get endpoint :key)))))))

(defun harness-openrouter--decimal-sum (&rest values)
  "Return the exact sum of exact decimals VALUES, or nil if any is unreadable."
  (when (cl-every #'consp values)
    (let ((denominator (apply #'cl-lcm (mapcar #'cdr values))))
      (cons (cl-loop for value in values
                     sum (* (car value) (/ denominator (cdr value))))
            denominator))))

(defun harness-openrouter--order< (a b)
  "Non-nil when sort key A orders before sort key B, exactly.
A key is (EXACT-SUM EXACT-CACHE-READ KEY-STRING)."
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
  "Choose the cheapest endpoint POLICY allows among RECORDS read at READ-AT.
RECORDS are `harness-openrouter-parse-endpoints''s.  Return
\(:ok t :endpoint ENDPOINT :record RECORD :reading READ-AT) or
\(:ok nil :reason SYMBOL :detail STRING).

Only the policy's own endpoints are candidates.  One whose fresh listing
is dearer than the model owner's published price is dropped; the
cheapest of the rest is chosen.  One whose listing cannot be read blocks
the decision, because that is not evidence about its price."
  (let ((problem (harness-openrouter--policy-error policy)))
    (cond
     (problem (list :ok nil :reason 'policy-invalid :detail problem))
     ((harness-openrouter--owner-price-error policy)
      (list :ok nil :reason 'owner-price-stale
            :detail (harness-openrouter--owner-price-error policy)))
     ((not (harness-openrouter--fresh-p policy read-at))
      (list :ok nil :reason 'catalogue-stale
            :detail (format "the endpoint catalogue was read %d s ago; the policy allows %s s"
                            (round (- (float-time) (or read-at 0)))
                            (plist-get policy :freshness))))
     (t
      (let* ((ceiling (harness-openrouter--owner-price policy))
             (standings (mapcar (lambda (endpoint)
                                  (harness-openrouter--standing
                                   policy records endpoint ceiling))
                                (plist-get policy :endpoints)))
             (unknown (cl-find-if (lambda (s) (eq (plist-get s :standing) 'unknown))
                                  standings))
             (chosen (harness-openrouter--cheapest standings)))
        (cond
         ;; An unreadable candidate could have been the cheapest, so the
         ;; decision waits for a reading rather than picking around it.
         (unknown
          (list :ok nil :reason (plist-get unknown :reason)
                :detail (plist-get unknown :detail)
                :endpoint (plist-get unknown :endpoint)))
         (chosen
          (list :ok t :endpoint (plist-get chosen :endpoint)
                :record (plist-get chosen :record)
                :reading read-at))
         (t
          (list :ok nil :reason 'over-owner-price
                :detail (format "no vetted endpoint is under the owner price: %s"
                                (string-join (mapcar (lambda (s) (plist-get s :detail))
                                                     standings)
                                             "; "))))))))))

;;;; The pinned route

(defun harness-openrouter--route-of (session)
  "Return SESSION's pinned route, or nil."
  (when (listp session)
    (let ((ext (plist-get session :ext)))
      (when (listp ext) (plist-get ext harness-openrouter--route-key)))))

(defun harness-openrouter--route-plist (decision)
  "Return DECISION as the route stored on a session.
Every value survives the JSON store of a session record: strings,
numbers and t, no symbols and no structs."
  (let ((endpoint (plist-get decision :endpoint))
        (record (plist-get decision :record))
        (reading (plist-get decision :reading)))
    (list :model (plist-get record :model)
          :key (plist-get endpoint :key)
          :slug (plist-get endpoint :slug)
          :provider (plist-get endpoint :provider)
          :tier (or (plist-get endpoint :tier) "default")
          :quantization (plist-get endpoint :quantization)
          :prompt (harness-openrouter--usd-per-million (plist-get record :prompt))
          :completion (harness-openrouter--usd-per-million (plist-get record :completion))
          :cache-read (harness-openrouter--usd-per-million (plist-get record :cache-read))
          :discount (harness-openrouter--usd-per-million
                     (plist-get record :discount))
          :catalogue-at reading
          :selected-at (float-time)
          :basis "chosen")))

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

(defun harness-openrouter--choose-now (policy)
  "Fetch the catalogue of POLICY's model and choose for it; return a promise.
The promise resolves to the reading (`:at', `:endpoints') of the
catalogue; `harness-openrouter-select' then decides from it.  A fetch
that fails rejects."
  (harness-openrouter--catalogue (plist-get policy :model) t))

(defun harness-openrouter--select-decision (policy records read-at)
  "Return POLICY's decision for a brand new session from RECORDS read at READ-AT.
The privacy requirement and every endpoint's own dated evidence were
checked by `harness-openrouter--policy-error' before this: an endpoint
without evidence of its own is not in the allowlist `select' sees."
  (harness-openrouter-select policy records read-at))

;;;; Request fields

;;;; Request fields

(defconst harness-openrouter--legacy-fields
  '(:label :base-url :api-key :api-key-env :headers
    :models :tiers :default-context :capabilities)
  "Fields an `harness-openai-endpoints' entry of OpenRouter keeps here.
Before this module existed, an OpenRouter entry in that option was a
generic endpoint like any other, and every field it documented was read:
its label, URL, key, key variable and headers, and also its static
`models', its `tiers', its `default-context' and its `capabilities'.  All
of them are still honoured after the move to this module, so a
configuration made before it keeps working -- those four included, which
a static listing or a fixed tier set depends on.  Only the dialect, the
models function and the completion function are this module's: they are
what makes it OpenRouter's provider rather than the generic one.")

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
        :stream-state #'harness-openrouter--stream-state
        :chunk #'harness-openrouter--chunk
        :audit #'harness-openrouter--audit
        :error-detail #'harness-openrouter--error-detail))

(defun harness-openrouter--headers (_endpoint _key)
  "Return the OpenRouter-specific headers of a request.
The app title names this client (it is not a secret).  The router
metadata header is sent only when a policy is configured, so an
unconfigured provider sends exactly what it sent before."
  (append (list (cons "X-Title" "Emacs agent harness"))
          (when (harness-openrouter-routing-enabled-p)
            (list (cons "X-OpenRouter-Metadata" "enabled")))))

(defun harness-openrouter--session-id (request)
  "Return the sticky-session id for REQUEST, or nil.
It is the harness's session id, stable across turns, retries and a
restart.  It is not proof of a cache hit; the pin is the `provider'
object, and this only helps OpenRouter keep one session's cache warm
within the endpoint the pin names."
  (let ((id (plist-get (plist-get request :session) :id)))
    (and (stringp id) (<= (length id) 256) id)))

(defun harness-openrouter--max-price (policy route)
  "Return the request-level `max_price' for ROUTE under POLICY, or nil.
OpenRouter's `provider.max_price' takes prompt and completion prices in
USD per million tokens, and a `request' fee where an endpoint charges
per request.  Sending the owner price there is a second defence: the
router itself refuses an endpoint dearer than the ceiling, whatever this
module's own reading of the catalogue said.  It covers prompt and
completion only.  It says nothing about cache reads -- OpenRouter's
documentation does not offer a cache-read cap, and this module does not
assume one -- so the cache-read price is checked here
\(`harness-openrouter--prices-over') and never inferred to be protected
by the wire field.  A per-request fee is only bounded when the policy
sets `:request' in its owner price and the recorded endpoint charged
one; otherwise the endpoint that charges per request is not one this
policy can bound, and is refused before the request is made."
  (let* ((owner (plist-get policy :owner-price))
         (prompt (harness-openrouter--decimal (plist-get owner :prompt)))
         (completion (harness-openrouter--decimal (plist-get owner :completion)))
         (request-fee (harness-openrouter--decimal (plist-get owner :request)))
         (recorded-request (and (numberp (plist-get route :request))
                                (harness-openrouter--decimal
                                 (number-to-string (plist-get route :request))))))
    (when (and prompt completion)
      (append (list :prompt (float (/ (car prompt) (float (cdr prompt))))
                    :completion (float (/ (car completion) (float (cdr completion)))))
              (when (and request-fee recorded-request)
                (list :request (float (/ (car request-fee) (float (cdr request-fee))))))))))

(defun harness-openrouter--body-extra (_endpoint _name request)
  "Return the OpenRouter-only body fields for REQUEST.
Without an enabled policy this is the usage object OpenRouter always
got.  With one, the request is restricted to the session's pinned
endpoint -- its exact slug in `only' and `order', fallbacks off, the
standard tier -- carries the data-collection and retention controls, and
states the owner price as `max_price'.  A request with no pinned route
is never sent (`harness-openrouter--complete'); this function only
describes one that is."
  (let ((fields (list (cons :usage '(:include t))))
        (policy harness-openrouter-routing))
    (when (harness-openrouter-routing-enabled-p policy)
      (when-let* ((route (or (plist-get request :openrouter-route)
                             (harness-openrouter--route-of (plist-get request :session)))))
        (let ((slug (plist-get route :slug))
              (max-price (harness-openrouter--max-price policy route)))
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
          (setq fields (append fields (list (cons :session_id sid)))))))
    fields))

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
This is what makes an upstream HTTP 400 stop with a reason instead of
being tried again unchanged.")

(defun harness-openrouter--stream-state (request)
  "Return the dialect state a new stream for REQUEST starts with."
  (let ((session (plist-get request :session)))
    (list :route (and (harness-openrouter-routing-enabled-p)
                      (harness-openrouter--route-of session))
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
alone -- which is why `harness-openrouter--matching' refuses to pin a
slug more than one catalogue record selects, and why the pin also sends
`only' with the exact slug and `allow_fallbacks: false'."
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
     ((not (equal model (plist-get route :model)))
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
     ;; model, the answer came from somewhere else.
     ((let ((selected (cl-find-if (lambda (e) (plist-get e :selected)) available)))
        (and selected
             (or (not (harness-openrouter--same-provider-p
                       pinned-provider (plist-get selected :provider)))
                 (and (stringp (plist-get selected :model))
                      (not (equal (plist-get selected :model) (plist-get route :model)))))))
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

;;;; Dispatch: the pin, checked before every request

(defun harness-openrouter--pin-endpoint (policy route)
  "Return POLICY's endpoint for ROUTE, or nil when the pin is not vetted now.
The pin names an endpoint key; the policy's allowlist says whether that
key may serve the model, and the route's own model, slug, provider, tier
and quantization must agree with the endpoint it names.  A key the
policy no longer lists, or one whose identity changed, leaves the pin
unvetted."
  (when-let* ((key (plist-get route :key))
              (endpoint (cl-find key (plist-get policy :endpoints)
                                 :key (lambda (e) (plist-get e :key))
                                 :test #'equal)))
    (and (equal (plist-get endpoint :slug) (plist-get route :slug))
         (equal (plist-get endpoint :provider) (plist-get route :provider))
         (equal (or (plist-get endpoint :tier) "default")
                (or (plist-get route :tier) "default"))
         (or (null (plist-get endpoint :quantization))
             (equal (plist-get endpoint :quantization)
                    (plist-get route :quantization)))
         endpoint)))

(defun harness-openrouter--recorded-over (ceiling route)
  "Return the components of ROUTE's recorded price above CEILING, as strings.
The route records the price it was vetted at, for display; this reads
it back exactly, so a policy whose ceiling was lowered under a pin that
is still fresh stops the pin instead of sending at the old price."
  (let (over)
    (dolist (key harness-openrouter--price-keys)
      (let* ((most (plist-get ceiling key))
             (million (plist-get route key))
             (price (and (numberp million)
                         (harness-openrouter--ceiling-per-token
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
policy is still complete, that its owner price is still trusted, that
the pin is still in the allowlist and still the identity it was vetted
as, that the owner price still covers the price the pin recorded, and
that the pinned endpoint still states the privacy evidence the policy
requires.  When READING -- a catalogue reading, `:endpoints' and `:at'
-- is given it must be fresh, must list the pin exactly once, at a price
under the owner price and with no component the ceiling does not cover.

A READING that is nil, empty or unreadable is a refusal, never `no
refresh': `harness-openrouter--choose-now' rejects a failed fetch, so
nil here can only be a catalogue that says this model has no endpoints
at all, which is not evidence that the pin still exists."
  (let* ((problem (harness-openrouter--policy-error policy))
         (endpoint (and (not problem) (harness-openrouter--pin-endpoint policy route)))
         (owner-error (and (not problem) (harness-openrouter--owner-price-error policy)))
         (ceiling (and (not problem) (harness-openrouter--owner-price policy)))
         (freshness (plist-get policy :freshness)))
    (cond
     (problem (cons 'policy-invalid problem))
     ((not (equal (plist-get route :model) (plist-get policy :model)))
      (cons 'model-mismatch
            (format "the pin is for %s, the policy for %s"
                    (plist-get route :model) (plist-get policy :model))))
     ((null endpoint)
      (cons 'pin-not-vetted
            (format "the pinned endpoint %s%s is not vetted by the policy now"
                    (or (plist-get route :slug) (plist-get route :key) "?")
                    (if (equal (plist-get route :slug) (or (plist-get route :key) ""))
                        ""
                      (format " (key %s)" (or (plist-get route :key) "?"))))))
     (owner-error (cons 'owner-price-stale owner-error))
     ((harness-openrouter--recorded-over ceiling route)
      (cons 'over-owner-price
            (format "the pin's price is over the owner price now: %s"
                    (string-join (harness-openrouter--recorded-over ceiling route) ", "))))
     ;; The endpoint's own evidence, every dispatch: a policy edited to
     ;; drop an endpoint's evidence, or evidence that has expired since
     ;; the pin was made, stops the pin.
     ((harness-openrouter--evidence-error policy endpoint (plist-get endpoint :evidence))
      (cons 'privacy-stale
            (harness-openrouter--evidence-error policy endpoint
                                               (plist-get endpoint :evidence))))
     ((harness-openrouter--evidence-stale-error endpoint (plist-get endpoint :evidence))
      (cons 'privacy-stale
            (harness-openrouter--evidence-stale-error endpoint (plist-get endpoint :evidence))))
     ((null reading)
      (unless (harness-openrouter--fresh-p policy (plist-get route :catalogue-at))
        (cons 'catalogue-stale
              (format "the pin's catalogue reading is %d s old; the policy allows %s s"
                      (round (- (float-time) (or (plist-get route :catalogue-at) 0)))
                      freshness))))
     (reading
      (let ((records (plist-get reading :endpoints))
            (at (plist-get reading :at)))
        (cond
         ((not records)
          (cons 'catalogue-empty
                "the fresh catalogue lists no endpoint for this model at all"))
         ((null (harness-openrouter--match-set policy records endpoint))
          (cons 'unknown-endpoint
                (format "the pinned endpoint %s is no longer listed for %s"
                        (plist-get route :slug) (plist-get policy :model))))
         ((not (harness-openrouter--fresh-p policy at))
          (cons 'catalogue-stale
                (format "the endpoint catalogue was read %d s ago; the policy allows %s s"
                        (round (- (float-time) (or at 0))) freshness)))
         (t
          (let* ((standing (harness-openrouter--standing policy records endpoint ceiling))
                 (kind (plist-get standing :standing)))
            (cond
             ((eq kind 'unknown)
              (cons (plist-get standing :reason)
                    (format "the pinned endpoint %s can no longer be read: %s"
                            (plist-get route :slug) (plist-get standing :detail))))
             ((eq kind 'out)
              (cons 'over-owner-price
                    (format "the pinned endpoint %s is now dearer than the owner's own price: %s"
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
  "Send REQUEST through the shared transport, unless the check refuses it.
STATE is the dispatch's shared state (see `harness-openrouter--cancel-handle'),
SNAPSHOT what the dispatch was authorised with: its policy, its pinned
route and, when the catalogue was just read, that reading.  The checks
run again here, immediately before the body is built, so a policy
edited, an owner price expired or a pin whose evidence lapsed since the
check stops the request rather than slipping through."
  (let* ((policy (plist-get snapshot :policy))
         (route (plist-get snapshot :route))
         (refusal (harness-openrouter--pin-refusal policy route
                                                  (plist-get snapshot :reading))))
    (if refusal
        (progn
          (harness-openrouter--refuse (plist-get (plist-get request :session) :id)
                                      on-event refusal)
          (list :cancel #'ignore))
      (harness-openai--complete
       (harness-openrouter--endpoint)
       (plist-put (harness-openrouter--bounded-request request) :openrouter-route route)))))



(defun harness-openrouter--complete (request)
  "Send REQUEST to the session's pinned endpoint, or refuse to send it.
A request without an enabled policy is the generic completion,
unchanged.  With one: a session with no pin is a new session and gets
one chosen from a fresh catalogue; a pinned session is checked again --
model, policy, owner price, the pin's recorded price, the endpoint's
privacy evidence and the catalogue -- and refused with a stop reason
when the check fails.  Nothing is switched: a switch is the user's
\(`harness-openrouter-switch')."
  (let ((on-event (or (plist-get request :on-event) #'ignore))
        (policy harness-openrouter-routing)
        (session (plist-get request :session))
        (session-id (plist-get (plist-get request :session) :id)))
    (cond
     ;; No policy at all: the provider as it always was.
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
refusal stands."
  (let ((state (list nil nil)))
    (let ((refusal (harness-openrouter--pin-refusal policy route)))
      (cond
       ((and refusal (not (eq (car refusal) 'catalogue-stale)))
        (harness-openrouter--refuse session-id on-event refusal))
       ((and (null refusal) (harness-openrouter--fresh-p
                             policy (plist-get route :catalogue-at)))
        (harness-openrouter--start-pinned
         state (list :policy policy :route route) request on-event))
       (t
        (harness-then
         (harness-openrouter--choose-now policy)
         (lambda (reading)
           (unless (harness-openrouter--cancelled-p state)
             (let ((refusal (harness-openrouter--pin-refusal policy route reading)))
               (if refusal
                   (harness-openrouter--refuse session-id on-event refusal)
                 (harness-openrouter--start-pinned
                  state (list :policy policy :route route :reading reading)
                  request on-event)))))
         (lambda (err)
           (unless (harness-openrouter--cancelled-p state)
             (harness-openrouter--catalogue-failure session-id on-event err)))))))
    (harness-openrouter--cancel-handle state)))

(defun harness-openrouter--catalogue-failure (session-id on-event err)
  "End the request of SESSION-ID ON-EVENT because its catalogue could not be read."
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
     (harness-openrouter--choose-now policy)
     (lambda (reading)
       (unless (harness-openrouter--cancelled-p state)
         (let ((decision (harness-openrouter--select-decision
                          policy (plist-get reading :endpoints)
                          (plist-get reading :at))))
           (if (not (plist-get decision :ok))
               (harness-openrouter--refuse
                session-id on-event
                (cons (or (plist-get decision :reason) 'route-paused)
                      (plist-get decision :detail)))
             (let* ((route (harness-openrouter--store-route
                            session-id (harness-openrouter--route-plist decision)))
                    (snapshot (list :policy policy :route route)))
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
                on-event))))))
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

(defun harness-openrouter-switch (session-id endpoint-key &optional why)
  "Pin SESSION-ID to ENDPOINT-KEY, explicitly, and return the new route.
A switch starts a conversation the provider's cache does not hold, so it
is never automatic: the policy's price rule selects for a new session
only.  This is the one way a pin moves, and it is the user's.  It
refuses while the session has a turn at work, checks the whole policy
again -- the endpoint's own privacy evidence, its exact identity in a
fresh catalogue, its price under the current owner price -- and records
the route as `switched' with WHY.  An endpoint whose evidence is
missing or expired cannot be switched to: this call never relaxes the
vetted set."
  (unless (harness-openrouter-routing-enabled-p)
    (error "OpenRouter routing is not enabled"))
  (let* ((policy harness-openrouter-routing)
         (session (harness-call 'session/get session-id))
         (endpoint (cl-find (format "%s" endpoint-key) (plist-get policy :endpoints)
                            :key (lambda (e) (plist-get e :key))
                            :test #'equal)))
    (unless endpoint (error "No vetted endpoint %s in the policy" endpoint-key))
    (when (memq (plist-get session :status) '(running blocked))
      (error "Session %s is busy; stop its turn before switching endpoint" session-id))
    (when-let* ((problem (harness-openrouter--policy-error policy)))
      (error "Cannot switch: %s" problem))
    (when-let* ((problem (harness-openrouter--evidence-error
                          policy endpoint (plist-get endpoint :evidence))))
      (error "Cannot switch to %s: %s" endpoint-key problem))
    (harness-then
     (harness-openrouter--choose-now policy)
     (lambda (reading)
       (let* ((narrow (list :model (plist-get policy :model)
                            :endpoints (list endpoint)
                            :freshness (plist-get policy :freshness)
                            :owner-price (plist-get policy :owner-price)
                            :privacy (plist-get policy :privacy)
                            :retry (plist-get policy :retry)))
              (decision (harness-openrouter-select
                         narrow (plist-get reading :endpoints) (plist-get reading :at))))
         (unless (plist-get decision :ok)
           (error "Cannot switch to %s: %s" endpoint-key (plist-get decision :detail)))
         (let ((route (plist-put (harness-openrouter--route-plist decision) :basis "switched")))
           (setq route (plist-put route :why (or why "requested")))
           (harness-openrouter--store-route session-id route)
           (harness-openrouter--hint session-id
                                     (format "OpenRouter endpoint %s pinned by hand; its cache starts cold"
                                             (plist-get route :slug)))
           route))))))

;;;; Bounded retry, the same endpoint only
;;
;; A policy names three bounds for retrying the same pinned endpoint:
;; `:max-attempts', `:max-seconds' and `:max-output-tokens'.  This
;; module enforces all three for a session it routes, in the `agent/step-error'
;; chain, before `harness-retry' (priority 45 here, 60 there):
;;
;;   * a transient failure the transport or this module can name
;;     (`transport', `rate-limit', a 5xx, a timeout) is tried again only
;;     while the attempts and the elapsed time are inside the bounds;
;;     the wait and the count are this module's, so the bounds hold
;;     whatever `harness-retry-max-attempts' says;
;;   * a typed permanent failure stops at once, with `:final', so no
;;     later filter -- `harness-retry' after this one, a module loaded
;;     later with a lower priority number -- can turn it into a retry;
;;   * `:max-output-tokens' bounds the output the request asks for
;;     (`harness-openrouter--bounded-request'), so a request's own
;;     `:max-tokens' or a resumed session's never sends more.
;;
;; The count is per session and reset when a turn starts, like the
;; generic one, and a failure that is neither transient nor typed
;; permanent is left to the modules after this one.

(defvar harness-openrouter--attempts (make-hash-table :test 'equal)
  "Session id -> (:count N :since FLOAT) of the same-endpoint retries this turn.")

(defvar harness-openrouter--retrying (make-hash-table :test 'equal)
  "Session id -> t while a retry this module decided is being run.
This is what keeps a second round of `agent/step-error' from counting
the same failure twice: the retry that runs returns one step, and the
attempt it already counted is not counted again when it fails.")

(defconst harness-openrouter--transient-types
  '("rate_limit_exceeded" "rate_limit" "overloaded" "provider_unavailable"
    "server_error" "internal_error" "timeout" "upstream_timeout"
    "provider_timeout" "unavailable" "too_many_requests")
  "Typed codes a repeat of the same request can pass.
These are a provider's or a gateway's bad minute, not the request's
fault; they are tried again inside the policy's bounds.")

(defun harness-openrouter--failure-type (failure)
  "Return the typed OpenRouter error code FAILURE carries, or nil."
  (when-let* ((text (plist-get failure :error)))
    (when (string-match "error_type=\\([a-z_]+\\)" text)
      (match-string 1 text))))

(defun harness-openrouter--transient-failure-p (failure)
  "Non-nil when FAILURE is one a repeat of the same request may pass.
The transport's kind (`transport', `rate-limit') counts, and so does a
typed code in `harness-openrouter--transient-types' or an HTTP status
that a repeat can pass (408, 425, 429, 500, 502, 503, 504).  A typed
permanent code is not transient however its status read."
  (let* ((kind (plist-get failure :error-kind))
         (type (harness-openrouter--failure-type failure))
         (text (format "%s" (or (plist-get failure :error) ""))))
    (and (not (and type (member type harness-openrouter--permanent-types)))
         (or (memq kind '(transport rate-limit))
             (and type (member type harness-openrouter--transient-types))
             (string-match-p "\\b\\(?:HTTP \\)?\\(?:408\\|425\\|429\\|500\\|502\\|503\\|504\\)\\b"
                             text)))))

(defun harness-openrouter--bounded-request (request)
  "Return REQUEST with its output ceiling inside the policy's bound.
A policy's `:retry' `:max-output-tokens' is a ceiling on what a request
of the routed session may ask for, so a request that asks for more is
cut to it, and a request that asks for nothing is bounded by it too: a
model's own default output can be far larger.  This is what makes the
configured bound real, for a request of the harness's own and for a
resumed session whose last request asked for more.  Without a valid
policy or bound the request is returned unchanged."
  (let* ((policy harness-openrouter-routing)
         (bound (and (harness-openrouter-routing-enabled-p policy)
                     (plist-get (plist-get policy :retry) :max-output-tokens)))
         (asked (plist-get request :max-tokens)))
    (if (not (and (integerp bound) (> bound 0)))
        request
      (plist-put (copy-sequence request) :max-tokens
                 (if (and (integerp asked) (> asked 0)) (min asked bound) bound)))))

(defun harness-openrouter--retry-state (session-id &optional attempt)
  "Return the retry state of SESSION-ID's turn, made if absent.
A state that is made here counts ATTEMPT, the attempt that just failed:
the policy's `:max-attempts' is the most attempts of one endpoint in a
turn, the first included, so a policy of one attempt allows no retry at
all."
  (or (gethash session-id harness-openrouter--attempts)
      (puthash session-id (list :count (or attempt 1) :since (float-time))
               harness-openrouter--attempts)))

(defun harness-openrouter--retry-exhausted (policy session-id)
  "Return why SESSION-ID may not try the same endpoint again, or nil.
Both bounds are checked: the number of attempts this turn and the time
since its first one."
  (let* ((state (harness-openrouter--retry-state session-id))
         (retry (plist-get policy :retry))
         (most (plist-get retry :max-attempts))
         (seconds (plist-get retry :max-seconds))
         (count (plist-get state :count))
         (elapsed (- (float-time) (plist-get state :since))))
    (cond
     ((>= count most)
      (format "the policy allows %d attempt%s of the same endpoint, and %d %s made"
              most (if (= most 1) "" "s") count (if (= count 1) "was" "were")))
     ((>= elapsed seconds)
      (format "the policy allows %d s of retrying the same endpoint, and %d s passed"
              seconds (round elapsed))))))

(defun harness-openrouter--retry-delay (attempt failure)
  "Return how long to wait before ATTEMPT tries FAILURE's request again.
The generic backoff is used, so this module's waits read like the
transport's: a provider's Retry-After first, then a growing wait capped
at `harness-retry-max-delay'.  When `harness-retry' is not loaded, a
provider's own Retry-After, else one second."
  (if (fboundp 'harness-retry-backoff)
      (harness-retry-backoff attempt failure)
    (let ((asked (plist-get failure :retry-after)))
      (if (and (numberp asked) (>= asked 0)) asked 1.0))))

(defun harness-openrouter--routed-session-p (policy session)
  "Non-nil when SESSION is one POLICY routes."
  (and (harness-openrouter-routing-enabled-p policy)
       (equal (plist-get session :model)
              (format "openrouter:%s" (plist-get policy :model)))))

(defun harness-openrouter--bounded-stop (session reason)
  "Return a stop decision with REASON, leaving it as a hint on SESSION.
`:final' ends the filter chain, so a handler after this one -- whichever
priority it registered with -- cannot turn this stop into a retry."
  (harness-openrouter--hint (plist-get session :id) reason)
  (list :retry nil :stop t :final t :reason reason))

(defun harness-openrouter--step-error (value next session failure)
  "`agent/step-error' handler: bound retries of one pinned OpenRouter endpoint.
Only a session on the policy's model is handled, and only a failure no
handler before this one answered.  A typed permanent rejection stops at
once and ends the chain (`:final'), so no later filter retries it.  A
transient failure is tried again at the same endpoint only while the
policy's attempt and time bounds allow; past them it stops with the
reason.  An output ceiling is enforced when the request is made
\(`harness-openrouter--bounded-request')."
  (let ((policy harness-openrouter-routing))
    (if (not (and (harness-openrouter--routed-session-p policy session)
                  (not (plist-get value :retry))))
        (funcall next value)
      (let* ((type (harness-openrouter--failure-type failure))
             (decision
              (cond
               ((and type (member type harness-openrouter--permanent-types))
                (harness-openrouter--bounded-stop
                 session (format "OpenRouter error_type=%s; an identical retry cannot pass it"
                                 type)))
               ((harness-openrouter--transient-failure-p failure)
                (harness-openrouter--retry-decision
                 policy session failure type))
               (t value))))
        (funcall next decision))))
  nil)

(defun harness-openrouter--retry-decision (policy session failure type)
  "Return the decision for a transient FAILURE of SESSION under POLICY.
A retry stays at the same pinned endpoint and is allowed only while the
policy's attempts and elapsed seconds allow it; past either, the turn
stops with the reason."
  (let* ((session-id (plist-get session :id))
         (exhausted (harness-openrouter--retry-exhausted policy session-id)))
    (cond
     (exhausted
      (harness-openrouter--bounded-stop
       session
       (format "%s; not trying %s again"
               exhausted
               (or (plist-get (harness-openrouter--route-of session) :slug) "the endpoint"))))
     (t
      (let* ((state (harness-openrouter--retry-state session-id 1))
             (retry (plist-get policy :retry))
             (most (plist-get retry :max-attempts))
             (delay (harness-openrouter--retry-delay (plist-get state :count) failure))
             (count (1+ (plist-get state :count))))
        (setcar (cdr (plist-member state :count)) count)
        (harness-openrouter--hint
         session-id
         (format "OpenRouter %s; trying the same endpoint again in %s (%d of %d)"
                 (or type "transient failure")
                 (if (fboundp 'harness-retry-duration)
                     (harness-retry-duration delay)
                   (format "%.1f s" delay))
                 count most))
        (list :retry t :delay delay :reason "a transient failure"))))))

(defun harness-openrouter--forget-attempts (session-id &rest _)
  "Forget SESSION-ID's same-endpoint retry count, at a new turn."
  (remhash session-id harness-openrouter--attempts))

(defun harness-openrouter--guard (session target _why)
  "`harness-fallback-guard-functions' guard: keep a pinned session pinned.
A session this policy routes has one vetted endpoint and one model on
purpose; moving it to another model -- another provider, another host or
another checkpoint -- is not a fallback but a silent widening of the
vetted set, and it is the user's decision (`harness-openrouter-switch').
So a move is refused, with the reason and what to do about it, whether
the quota ran out, the budget did, or anything else did.  A session this
policy does not route is not guarded."
  (let ((policy harness-openrouter-routing))
    (when (and (harness-openrouter-routing-enabled-p policy)
               (equal (plist-get session :model)
                      (format "openrouter:%s" (plist-get policy :model)))
               (not (equal target (plist-get session :model))))
      (format (concat "session %s is pinned to OpenRouter endpoint %s for %s, and the policy allows no other; "
                      "stop it, top up or wait for the quota, or switch endpoint by hand with M-x harness-openrouter-switch")
              (or (plist-get session :id) "?")
              (or (plist-get (harness-openrouter--route-of session) :slug) "(none chosen yet)")
              (plist-get policy :model)))))

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
  "Register the provider, its retry bounds and its fallback guard.
The `agent/step-error' filter runs ahead of `harness-fallback' (50) and
`harness-retry' (60), so a typed permanent rejection is ended here
before either can retry it, and a transient one is bounded here before
the generic retry counts it.  The guard keeps a pinned session on its
pinned endpoint however it failed."
  (harness-openrouter-refresh)
  (harness-add-filter 'agent/step-error #'harness-openrouter--step-error 45)
  (harness-on 'agent/turn-started #'harness-openrouter--forget-attempts)
  (harness-on 'agent/turn-ended #'harness-openrouter--forget-attempts)
  (add-hook 'harness-fallback-guard-functions #'harness-openrouter--guard))

(defun harness-openrouter--shutdown ()
  "Drop this module's filters, its guard and its cached catalogues."
  (harness-remove-filter 'agent/step-error #'harness-openrouter--step-error)
  (harness-off (cons 'agent/turn-started #'harness-openrouter--forget-attempts))
  (harness-off (cons 'agent/turn-ended #'harness-openrouter--forget-attempts))
  (remove-hook 'harness-fallback-guard-functions #'harness-openrouter--guard)
  (clrhash harness-openrouter--catalogue)
  (clrhash harness-openrouter--fetching)
  (clrhash harness-openrouter--attempts))

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
