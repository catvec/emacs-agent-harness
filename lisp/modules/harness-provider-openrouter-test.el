;;; harness-provider-openrouter-test.el --- Tests for the OpenRouter provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything here is offline.  `harness-http-request' is replaced by a
;; fake that records the request and replays a canned answer, so a test
;; can say exactly what OpenRouter's catalogue returned and when, and
;; what a completion was sent.
;;
;; The negative tests at the end are the point of the module boundary:
;; a plain OpenAI endpoint, a custom OpenAI-compatible endpoint and an
;; OpenRouter endpoint with the policy off must be sent the body they
;; were sent before, must never reach OpenRouter's catalogue, and must
;; not gain a pin.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-provider-openrouter)
(require 'harness-provider-openrouter-test-helpers)

;;;; Prices and policy validation

(defun harness-openrouter-test--usd (text)
  "Return TEXT, USD per token, as the exact decimal it names."
  (harness-openrouter--decimal text))

(defun harness-openrouter-test--over-p (price limit-per-million)
  "Non-nil when PRICE (USD per token, a string) is over LIMIT-PER-MILLION.
LIMIT-PER-MILLION is a policy figure in USD per million tokens."
  (harness-openrouter--decimal>
   (harness-openrouter-test--usd price)
   (harness-openrouter--limit-per-token limit-per-million)))

(ert-deftest harness-provider-openrouter-prices-compare-exactly ()
  "Catalogue prices and a policy's maximum compare exactly, at any precision.
The values are the ones the live catalogue returned on 2026-11-10, and
the long ones are the case that a fixed 1e-12 scale rounded wrongly: a
price of 0.0000000980001 USD per token is 0.0980001 per million, just
over a 0.098 limit, and reading it must say so rather than round it to
0.098."
  ;; Exact reading: the number the text names, at any number of places.
  (should (equal '(98 . 1000000000) (harness-openrouter--decimal "0.000000098")))
  (should (equal '(98 . 1000000000) (harness-openrouter--decimal "9.8e-08")))
  (should (equal '(15 . 100) (harness-openrouter--decimal "0.15")))
  (should (equal '(15 . 100) (harness-openrouter--decimal 0.15)))
  (should (equal '(0 . 1) (harness-openrouter--decimal "0")))
  (should (equal '(300 . 1) (harness-openrouter--decimal "300")))
  ;; A per-million limit is divided exactly, so the boundary is exact.
  (should (= 0 (harness-openrouter--decimal-compare
                (harness-openrouter-test--usd "0.000000098")
                (harness-openrouter--limit-per-token "0.098"))))
  (should (= 1 (harness-openrouter--decimal-compare
                (harness-openrouter-test--usd "0.0000000980001")
                (harness-openrouter--limit-per-token "0.098"))))
  (should (= -1 (harness-openrouter--decimal-compare
                 (harness-openrouter-test--usd "0.0000000979999")
                 (harness-openrouter--limit-per-token "0.098"))))
  ;; The reported bug: a long fractional price was scaled to about 980
  ;; dollars per million rather than 0.000000098, which is 0.098 per
  ;; million.  It still compares correctly, and it is over the limit.
  (should (harness-openrouter-test--over-p "0.0000000980001" "0.098"))
  (should-not (harness-openrouter-test--over-p "0.0000000980001" "0.099"))
  (should-not (harness-openrouter-test--over-p "0.000000098" "0.098"))
  ;; A limit is never rounded up into accepting a price above it: 0.15 per
  ;; million is 0.00000015 per token, over a 0.149999 per-million limit by
  ;; a hair, and under a 0.15 limit exactly.
  (should (harness-openrouter-test--over-p "0.00000015" "0.149999"))
  (should-not (harness-openrouter-test--over-p "0.00000015" "0.15"))
  ;; An exponent form is read for what it says, and a malformed,
  ;; negative, empty or unsupported value is no price at all.
  (should-not (harness-openrouter--decimal "-1"))
  (should-not (harness-openrouter--decimal "abc"))
  (should-not (harness-openrouter--decimal ""))
  (should-not (harness-openrouter--decimal nil))
  (should-not (harness-openrouter--decimal "1e999"))
  (should-not (harness-openrouter--decimal "1e-999"))
  ;; A display figure is the float a hint shows, and says what it is.
  (should (harness-openrouter-test--approx
           0.098 (harness-openrouter--usd-per-million
                  (harness-openrouter-test--usd "0.000000098")))))

(ert-deftest harness-provider-openrouter-policy-validation-blocks-holes ()
  "A policy missing any field a check needs is refused, not guessed at."
  (should-not (harness-openrouter-routing-validate (harness-openrouter-test-policy)))
  ;; No policy at all is simply off, never "invalid".
  (should-not (harness-openrouter-routing-validate nil))
  (dolist (case (list (list :model nil "names no exact model")
                      (list :model "deepseek" "names no exact model")
                      (list :freshness nil "freshness")
                      (list :providers nil "names no provider")
                      (list :providers '() "names no provider")
                      (list :providers '("DeepInfra" "DeepInfra") "named twice")
                      (list :providers '(DeepInfra) "not a string")))
    (let ((policy (apply #'harness-openrouter-test-policy case)))
      (should (string-match-p (nth 2 case) (harness-openrouter-routing-validate policy)))))
  ;; The maximum price is the filter, so a hole in it blocks too, and it
  ;; names only the components the policy compares.
  (let* ((policy (harness-openrouter-test-policy))
         (limits (plist-get policy :max-price)))
    (dolist (case (list (cons "no maximum price" nil)
                        (cons "incomplete"
                              (plist-put (copy-sequence limits) :prompt nil))
                        (cons "plain decimal"
                              (plist-put (copy-sequence limits) :completion "1.20 USD"))))
      ;; A fresh copy each time: `plist-put' edits the list it is given.
      (should (string-match-p
               (car case)
               (harness-openrouter-routing-validate
                (plist-put (copy-sequence policy) :max-price (cdr case)))))))
  ;; Retry bounds are not the policy's: how often a request is tried
  ;; again is the shared retry layer's, one setting for every provider,
  ;; so a policy that carries a `:retry' of its own is a policy with a
  ;; field the harness does not know -- it is still valid, and it changes
  ;; nothing.
  (let ((with-retry (harness-openrouter-test-policy
                     :retry '(:max-attempts 1 :max-seconds 1))))
    (should-not (harness-openrouter-routing-validate with-retry))
    (should-not (member :retry harness-openrouter--policy-keys)))
  ;; A configured policy that is not enabled routes nothing.
  (should-not (harness-openrouter-routing-enabled-p
               (harness-openrouter-test-policy :enabled nil)))
  (should (harness-openrouter-routing-enabled-p (harness-openrouter-test-policy))))

(ert-deftest harness-provider-openrouter-the-simple-policy-is-a-plist-of-providers-and-limits ()
  "The whole policy is a short plist: providers, limits and freshness.
There is no per-endpoint entry, no evidence record, no source or date to
maintain, and no retry budget or output limit of its own -- retrying is
the shared layer's and output is the request's.  The endpoints and
their prices are the catalogue's; the policy names only who may serve
the model and what may be spent."
  (let ((policy (harness-openrouter-test-policy)))
    (should (equal '(:enabled :model :providers :max-price :freshness)
                   (cl-loop for (key _value) on policy by #'cddr collect key)))
    (should (equal '("DeepInfra" "Cohere") (plist-get policy :providers)))
    (should (equal '(0.15 0.60 0.003)
                   (list (plist-get (plist-get policy :max-price) :prompt)
                         (plist-get (plist-get policy :max-price) :completion)
                         (plist-get (plist-get policy :max-price) :cache-read))))
    ;; Nothing in it pretends to be a provider's own price list.
    (should-not (plist-member (plist-get policy :max-price) :source))
    (should-not (plist-member (plist-get policy :max-price) :read-at))
    (should-not (plist-member policy :endpoints))
    (should-not (plist-member policy :owner-price))
    (should-not (plist-member policy :privacy))
    (should-not (plist-member policy :evidence))))

;;;; Selection

(defun harness-openrouter-test--select (records &optional policy at)
  "Select from RECORDS with POLICY read at AT; return the decision."
  (harness-openrouter-select (or policy (harness-openrouter-test-policy)) records
                             (or at (float-time))))

(ert-deftest harness-provider-openrouter-selects-the-cheapest-allowed-endpoint ()
  "Of the allowed providers whose catalogue price is within the limits,
the cheapest is chosen.  The price sort reads the catalogue's own
per-token prices, so a promotional rate already reflected there is what
it compares."
  (let* ((records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (decision (harness-openrouter-test--select records)))
    (should (plist-get decision :ok))
    (should (equal "DeepInfra" (plist-get decision :provider)))
    (should (equal "deepinfra/fp8" (plist-get (plist-get decision :endpoint) :slug)))
    (should (equal '(98 . 1000000000) (plist-get (plist-get decision :record) :prompt)))
    (should (equal '(51 . 100) (plist-get (plist-get decision :record) :discount)))))

(ert-deftest harness-provider-openrouter-follows-qualified-provider-preference ()
  "The first qualified provider wins, independent of catalogue ordering."
  (let* ((policy (harness-openrouter-test-policy
                  :providers '("Cohere" "DeepInfra")))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (decision (harness-openrouter-test--select records policy)))
    (should (plist-get decision :ok))
    (should (equal "Cohere" (plist-get decision :provider)))
    (should (equal "cohere/fp8" (plist-get (plist-get decision :endpoint) :slug)))))

(ert-deftest harness-provider-openrouter-the-example-ceilings-admit-both-and-pick-the-cheaper ()
  "The example's ceilings filter by price, and the sort orders the rest.
The ceilings are 0.15 per million for prompt, 0.60 for completion and
0.003 for cache-read.  Both allowed endpoints are inside them -- Cohere's
prompt and cache-read rates are exactly at the ceiling, and a price equal
to the limit is not over it -- so the decision is the cheaper of the two
and nothing else.  DeepInfra's list rate is over the ceiling in prompt
and cache-read and under it in completion, so it is dropped by the
components that are over, not by the one that is not."
  (let* ((records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (policy (harness-openrouter-test-policy))
         (decision (harness-openrouter-test--select records policy))
         (limits (harness-openrouter--limits policy))
         (most (plist-get policy :max-price))
         (deepinfra (cl-find-if (lambda (r) (equal (plist-get r :tag) "deepinfra/fp8"))
                                records))
         (cohere (cl-find-if (lambda (r) (equal (plist-get r :tag) "cohere/fp8"))
                             records)))
    ;; The example's limits are the configured figures, to the digit, and
    ;; each divides exactly into the per-token bound it is compared as.
    (should (equal '(0.15 0.60 0.003)
                   (list (plist-get most :prompt)
                         (plist-get most :completion)
                         (plist-get most :cache-read))))
    ;; Each per-million ceiling is exactly the per-token figure the
    ;; catalogue quotes at the boundary, so 0.15 and 0.003 admit Cohere.
    (should (= 0 (harness-openrouter--decimal-compare
                  (plist-get limits :prompt)
                  (harness-openrouter-test--usd "0.00000015"))))
    (should (= 0 (harness-openrouter--decimal-compare
                  (plist-get limits :completion)
                  (harness-openrouter-test--usd "0.0000006"))))
    (should (= 0 (harness-openrouter--decimal-compare
                  (plist-get limits :cache-read)
                  (harness-openrouter-test--usd "0.000000003"))))
    ;; Both are inside: neither is over in any component.
    (should-not (harness-openrouter--prices-over limits deepinfra))
    (should-not (harness-openrouter--prices-over limits cohere))
    (should (plist-get decision :ok))
    (should (equal "DeepInfra" (plist-get decision :provider)))
    (should (equal "deepinfra/fp8" (plist-get (plist-get decision :endpoint) :slug)))
    ;; The policy order is the preference among price-qualified providers.
    (should (equal "cohere/fp8"
                   (plist-get (plist-get (harness-openrouter-test--select
                                          records
                                          (harness-openrouter-test-policy
                                           :providers '("Cohere" "DeepInfra")))
                                         :endpoint)
                              :slug)))
    ;; When the promo ends, DeepInfra's listed rate is over the ceiling in
    ;; prompt and cache-read, so it is not a candidate and Cohere is chosen
    ;; by the same rule -- no promo code, no priority order.
    (let* ((listed (harness-openrouter--endpoint-record
                    (harness-openrouter-test--endpoint-json
                     "deepinfra/fp8" "DeepInfra"
                     :pricing '(:prompt "0.0000002" :completion "0.0000006"
                                :input_cache_read "0.000000006" :discount 0))))
           (over (harness-openrouter--prices-over limits listed))
           (after (harness-openrouter-test--select
                   (list listed cohere) policy)))
      ;; Completion is exactly at the ceiling and is not named; the two
      ;; components that are over are.
      (should (= 2 (length over)))
      (should (cl-every (lambda (component)
                          (or (string-prefix-p "prompt " component)
                              (string-prefix-p "cache-read " component)))
                        over))
      (should-not (cl-some (lambda (component)
                             (string-prefix-p "completion " component))
                           over))
      (should (plist-get after :ok))
      (should (equal "Cohere" (plist-get after :provider)))
      (should (equal "cohere/fp8" (plist-get (plist-get after :endpoint) :slug))))))

(ert-deftest harness-provider-openrouter-a-dearer-endpoint-is-filtered-out ()
  "An allowed provider dearer than the maximum price is dropped, not chosen.
The limits are the most the policy spends, so the next allowed provider
under them takes the session."
  (let* ((records
          (harness-openrouter-parse-endpoints
           (harness-json-parse
            (harness-openrouter-test--catalogue-json
             (harness-openrouter-test--endpoint-json
              "deepinfra/fp8" "DeepInfra"
              :pricing '(:prompt "0.00000035" :completion "0.0000014"
                         :input_cache_read "0.0000000035" :discount 0))
             (harness-openrouter-test--endpoint-json
              "cohere/fp8" "Cohere"
              :pricing '(:prompt "0.00000015" :completion "0.0000005"
                         :input_cache_read "0.000000003" :discount 0))))))
         (decision (harness-openrouter-test--select records)))
    (should (plist-get decision :ok))
    (should (equal "Cohere" (plist-get decision :provider)))
    (should (equal "cohere/fp8" (plist-get (plist-get decision :endpoint) :slug)))
    ;; And the dropped one is not quietly re-added by a stale pin.
    (should (equal '(15 . 100000000)
                   (plist-get (plist-get decision :record) :prompt)))))

(ert-deftest harness-provider-openrouter-only-the-named-providers-are-candidates ()
  "A provider the policy does not name is never chosen, however cheap.
The catalogue lists every provider OpenRouter routes this model to; the
policy's `:providers' is the whole allowlist, so dropping one from it is
enough to keep that provider out of a session -- no per-endpoint entry,
no price of its own to compare."
  (let* ((cohere-only (harness-openrouter-parse-endpoints
                       (harness-json-parse
                        (harness-openrouter-test--catalogue-json))))
         (policy (harness-openrouter-test-policy :providers '("Cohere")))
         (decision (harness-openrouter-test--select cohere-only policy)))
    (should (plist-get decision :ok))
    (should (equal "Cohere" (plist-get decision :provider)))
    (should (equal "cohere/fp8" (plist-get (plist-get decision :endpoint) :slug)))
    ;; And the cheaper allowed one is still chosen when both are allowed.
    (should (equal "DeepInfra"
                   (plist-get (harness-openrouter-test--select cohere-only) :provider)))))

(ert-deftest harness-provider-openrouter-a-missing-provider-blocks-instead-of-falling-through ()
  "A named provider the catalogue does not list blocks, rather than spent on another.
An allowed provider that cannot be resolved is not a price that is too
high: it is a reading this decision cannot make, and picking the next
provider would be the silent switch the policy exists to prevent."
  (let* ((records (harness-openrouter-parse-endpoints
                   (harness-json-parse
                    (harness-openrouter-test--catalogue-json
                     ;; Only Cohere is listed; DeepInfra is allowed but absent.
                     (harness-openrouter-test--endpoint-json
                      "cohere/fp8" "Cohere"
                      :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                 :input_cache_read "0.000000003" :discount 0))))))
         (decision (harness-openrouter-test--select records)))
    (should-not (plist-get decision :ok))
    (should (eq 'unknown-endpoint (plist-get decision :reason)))
    (should (string-match-p "DeepInfra" (plist-get decision :detail)))
    (should-not (equal "Cohere" (plist-get (plist-get decision :endpoint) :provider)))))

(ert-deftest harness-provider-openrouter-the-wire-price-follows-the-limits ()
  "`max_price' on the wire is the policy's limit, not a provider's rate.
Two policies that differ only in their maximum send different wire
prices for the same pinned endpoint, which no manual record of what a
provider charges could do.  The privacy controls do not depend on the
limits and stay on the request either way."
  (let* ((route (harness-openrouter-test--route))
         (session (list :id "session-1" :ext (list :openrouter-route route)))
         (request (list :model (format "openrouter:%s" harness-openrouter-test-model)
                        :session session
                        :messages '((:role user :content ((:type "text" :text "hi"))))))
         (wire (lambda (limits)
                 (let ((harness-openrouter-routing
                        (harness-openrouter-test-policy :max-price limits)))
                   (plist-get (plist-get (harness-openrouter-test--routed-body
                                          harness-openrouter-routing route request)
                                         :provider)
                              :max_price)))))
    (should (harness-openrouter-test--approx 0.15 (plist-get (funcall wire '(:prompt 0.15 :completion 0.60 :cache-read 0.003)) :prompt)))
    (should (harness-openrouter-test--approx 0.25 (plist-get (funcall wire '(:prompt 0.25 :completion 0.90 :cache-read 0.004)) :prompt)))
    ;; The controls that must not depend on the limits.
    (let* ((harness-openrouter-routing
            (harness-openrouter-test-policy :max-price '(:prompt 0.25 :completion 0.90 :cache-read 0.004)))
           (provider (plist-get (harness-openrouter-test--routed-body
                                 harness-openrouter-routing route request)
                                :provider)))
      (should (equal "deny" (plist-get provider :data_collection)))
      (should (eq t (plist-get provider :zdr)))
      (should (eq :false (plist-get provider :allow_fallbacks)))
      (should (equal '("deepinfra/fp8") (append (plist-get provider :only) nil))))))

(ert-deftest harness-provider-openrouter-the-max-price-filters-every-component ()
  "A candidate over the maximum in one component alone is dropped.
The cache-read rate counts: an endpoint that costs more per cached token
is dearer for a long session, whatever its prompt price."
  (let* ((policy (harness-openrouter-test-policy))
         ;; DeepInfra's cache-read is 0.00294 per million and fits under
         ;; this; Cohere's 0.003 does not, and only that component excludes it.
         (limits (plist-put (copy-sequence (plist-get policy :max-price))
                            :cache-read 0.00295))
         (policy (plist-put policy :max-price limits))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (decision (harness-openrouter-test--select records policy)))
    (should (plist-get decision :ok))
    (should (equal "DeepInfra" (plist-get decision :provider)))
    (let ((cohere (plist-get (cadr (plist-get (plist-get decision :record) :entry)) :tag)))
      (ignore cohere))
    ;; Cohere is excluded by its cache-read rate alone, though its prompt
    ;; and completion prices fit under the same limits.
    (let ((cohere (harness-openrouter-test--endpoint-json
                   "cohere/fp8" "Cohere"
                   :pricing '(:prompt "0.00000015" :completion "0.0000005"
                              :input_cache_read "0.000000003" :discount 0))))
      (should (equal "cohere/fp8" (plist-get cohere :tag)))
      (should-not (equal "cohere/fp8" (plist-get (plist-get decision :endpoint) :slug))))))

(ert-deftest harness-provider-openrouter-nothing-under-the-max-price-blocks ()
  "When every allowed provider is dearer than the maximum, nothing is sent.
Blocking is the honest answer: the alternative is spending more than the
operator said they would, which the policy exists to prevent."
  (let* ((policy (harness-openrouter-test-policy))
         (limits (plist-put (plist-put (copy-sequence (plist-get policy :max-price))
                                       :prompt 0.01)
                            :completion 0.02))
         (policy (plist-put policy :max-price limits))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (decision (harness-openrouter-test--select records policy)))
    (should-not (plist-get decision :ok))
    (should (eq 'over-max-price (plist-get decision :reason)))
    (should (string-match-p "DeepInfra" (plist-get decision :detail)))
    (should (string-match-p "Cohere" (plist-get decision :detail)))))

(ert-deftest harness-provider-openrouter-the-limits-are-the-only-prices-in-the-policy ()
  "What a provider charges is the catalogue's; the policy only says a maximum.
The same catalogue records, unchanged, decide both ways when the limits
move: inside them the cheaper endpoint is chosen, and under every
endpoint's price the decision blocks.  Nothing in the policy is read as
a provider's rate, so there is no manual price to keep current or to
disagree with the catalogue."
  (let* ((records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (tight (harness-openrouter-test--select
                 records
                 (harness-openrouter-test-policy
                  :max-price '(:prompt 0.09 :completion 0.29 :cache-read 0.0029))))
         (fitting (harness-openrouter-test--select
                   records
                   (harness-openrouter-test-policy
                    :max-price '(:prompt 0.10 :completion 0.31 :cache-read 0.00295)))))
    ;; Under DeepInfra's own catalogue prompt price, nothing may be sent.
    (should-not (plist-get tight :ok))
    (should (eq 'over-max-price (plist-get tight :reason)))
    ;; At or over it, the catalogue's own figure is compared and the
    ;; cheaper endpoint wins; Cohere's higher price keeps it out.
    (should (plist-get fitting :ok))
    (should (equal "DeepInfra" (plist-get fitting :provider)))
    (should (equal "deepinfra/fp8" (plist-get (plist-get fitting :endpoint) :slug)))
    ;; The record is the catalogue's, untouched by either decision.
    (should (equal '(98 . 1000000000)
                   (plist-get (cl-find-if (lambda (r) (equal (plist-get r :tag) "deepinfra/fp8"))
                                          records)
                              :prompt)))))

(ert-deftest harness-provider-openrouter-unknown-prices-block-rather-than-switch ()
  "Anything short of a fresh, exact, well-formed reading blocks.
A listing that cannot be read is not a price that is too high, so none
of these may fall through to Cohere; each case is a new session that is
told why it cannot send."
  (let* ((policy (harness-openrouter-test-policy))
         (cases
          (list
           ;; Not listed at all.
           (cons "ambiguous"
                 (list (harness-openrouter-test--endpoint-json
                        "cohere/fp8" "Cohere"
                        :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                   :input_cache_read "0.000000003" :discount 0))))
           ;; The tag is there but the provider name is another's.
           (cons "another provider"
                 (list (harness-openrouter-test--endpoint-json
                        "deepinfra/fp8" "NotDeepInfra"
                        :pricing '(:prompt "0.000000098" :completion "0.000000294"
                                   :input_cache_read "0.00000000294" :discount 0))
                       (harness-openrouter-test--endpoint-json
                        "cohere/fp8" "Cohere"
                        :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                   :input_cache_read "0.000000003" :discount 0))))
           ;; The listing names another model.
           (cons "another model"
                 (list (harness-openrouter-test--endpoint-json
                        "deepinfra/fp8" "DeepInfra" :model "deepseek/deepseek-v4.1-flash"
                        :pricing '(:prompt "0.000000098" :completion "0.000000294"
                                   :input_cache_read "0.00000000294" :discount 0))
                       (harness-openrouter-test--endpoint-json
                        "cohere/fp8" "Cohere"
                        :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                   :input_cache_read "0.000000003" :discount 0))))
           ;; No cache-read price: unknown, and unknown is not a reading.
           (cons "no cache price"
                 (list (harness-openrouter-test--endpoint-json
                        "deepinfra/fp8" "DeepInfra"
                        :pricing '(:prompt "0.000000098" :completion "0.000000294" :discount 0))
                       (harness-openrouter-test--endpoint-json
                        "cohere/fp8" "Cohere"
                        :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                   :input_cache_read "0.000000003" :discount 0))))
           ;; The rate depends on the window of the week it is asked in,
           ;; so the top-level price is not this request's price.
           (cons "varies by time"
                 (list (harness-openrouter-test--endpoint-json
                        "deepinfra/fp8" "DeepInfra"
                        :pricing '(:prompt "0.000000098" :completion "0.000000294"
                                   :input_cache_read "0.00000000294" :discount 0
                                   :overrides [(:utc_start 0 :utc_end 100
                                                :prompt "0.000000098"
                                                :completion "0.000000294")]))
                       (harness-openrouter-test--endpoint-json
                        "cohere/fp8" "Cohere"
                        :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                   :input_cache_read "0.000000003" :discount 0))))
           ;; Two records claim the same exact endpoint.
           (cons "duplicate"
                 (list (harness-openrouter-test--endpoint-json
                        "deepinfra/fp8" "DeepInfra"
                        :pricing '(:prompt "0.000000098" :completion "0.000000294"
                                   :input_cache_read "0.00000000294" :discount 0))
                       (harness-openrouter-test--endpoint-json
                        "deepinfra/fp8" "DeepInfra"
                        :pricing '(:prompt "0.000000098" :completion "0.000000294"
                                   :input_cache_read "0.00000000294" :discount 0.4))
                       (harness-openrouter-test--endpoint-json
                        "cohere/fp8" "Cohere"
                        :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                   :input_cache_read "0.000000003" :discount 0)))))))
    (dolist (case cases)
      (ert-info ((car case) :prefix "case: ")
        (let* ((records (harness-openrouter-parse-endpoints
                         (harness-json-parse
                          (apply #'harness-openrouter-test--catalogue-json (cdr case)))))
               (decision (harness-openrouter-test--select records policy)))
          (should-not (plist-get decision :ok))
          ;; Never Cohere: an unreadable listing is not a dear one.
          (should-not (equal "cohere/fp8" (plist-get (plist-get decision :endpoint) :slug))))))))

(ert-deftest harness-provider-openrouter-a-time-varying-price-is-no-one-price ()
  "A listing priced by a window of the week is not one fixed rate.
The top-level figure is only the rate outside its windows, so reading it
as this request's price would pay a rate the listing does not promise.
It blocks, naming why, rather than being dropped for the next provider."
  (let* ((policy (harness-openrouter-test-policy))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse
                    (harness-openrouter-test--catalogue-json
                     (harness-openrouter-test--endpoint-json
                      "deepinfra/fp8" "DeepInfra"
                      :pricing '(:prompt "0.000000098" :completion "0.000000294"
                                 :input_cache_read "0.00000000294" :discount 0
                                 :overrides [(:utc_start 100 :utc_end 400
                                              :utc_days ["monday" "tuesday"]
                                              :prompt "0.0000002"
                                              :completion "0.0000006")]))
                     (harness-openrouter-test--endpoint-json
                      "cohere/fp8" "Cohere"
                      :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                 :input_cache_read "0.000000003" :discount 0))))))
         (detail (harness-openrouter--unreadable (car records)))
         (decision (harness-openrouter-test--select records policy)))
    (should (eq 'price-varies-by-time (car detail)))
    (should (string-match-p "window of the week" (cdr detail)))
    ;; The windowed record carries its overrides through the parser.
    (should (plist-get (car records) :overrides))
    ;; And the whole decision blocks: the fixed-price Cohere is not chosen.
    (should-not (plist-get decision :ok))
    (should (eq 'price-varies-by-time (plist-get decision :reason)))))

(ert-deftest harness-provider-openrouter-stale-catalogue-blocks ()
  "A reading older than the freshness bound is no reading at all."
  (let* ((records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (decision (harness-openrouter-test--select records nil (- (float-time) 600))))
    (should-not (plist-get decision :ok))
    (should (eq 'catalogue-stale (plist-get decision :reason)))
    (should (string-match-p "600" (plist-get decision :detail)))))

(ert-deftest harness-provider-openrouter-unrelated-endpoints-are-never-candidates ()
  "Another provider, version, host, tier or quantization cannot be chosen.
The live catalogue has 50 endpoints for this model; the policy names
two providers, and the rest -- including a cheaper one, a flex one and
the same provider's priority tier -- must never be selected."
  (let* ((records
          (harness-openrouter-parse-endpoints
           (harness-json-parse
            (harness-openrouter-test--catalogue-json
             ;; Cheaper than the chosen one and not on the allowlist.
             (harness-openrouter-test--endpoint-json
              "relace/fp4" "Relace"
              :quantization "fp4"
              :pricing '(:prompt "0.000000006" :completion "0.0000005"
                         :input_cache_read "0.000000005" :discount 0))
             ;; The same provider, another tier: not the standard endpoint.
             (harness-openrouter-test--endpoint-json
              "deepinfra/fp8/priority" "DeepInfra" :tier "priority"
              :pricing '(:prompt "0.000000147" :completion "0.000000441"
                         :input_cache_read "0.00000000441" :discount 0.51))
             ;; The same provider, a flex endpoint.
             (harness-openrouter-test--endpoint-json
              "deepinfra/fp8/flex" "DeepInfra" :tier "flex"
              :pricing '(:prompt "0.0000000784" :completion "0.0000002352"
                         :input_cache_read "0.000000002352" :discount 0.51))
             ;; Another model version.
             (harness-openrouter-test--endpoint-json
              "deepseek" "DeepSeek" :model "deepseek/deepseek-v4.1-flash"
              :pricing '(:prompt "0.0000003" :completion "0.0000012"
                         :input_cache_read "0.000000006" :discount 0))
             (harness-openrouter-test--endpoint-json
              "deepinfra/fp8" "DeepInfra")
             (harness-openrouter-test--endpoint-json
              "cohere/fp8" "Cohere"
              :pricing '(:prompt "0.00000015" :completion "0.0000005"
                         :input_cache_read "0.000000003" :discount 0))))))
         (decision (harness-openrouter-test--select records)))
    (should (plist-get decision :ok))
    (should (equal "deepinfra/fp8" (plist-get (plist-get decision :endpoint) :slug)))
    (should (equal "deepinfra/fp8" (plist-get (plist-get decision :record) :tag)))))

(ert-deftest harness-provider-openrouter-an-unavailable-pinned-endpoint-pauses-the-pin ()
  "A pinned endpoint the fresh catalogue marks unavailable pauses the session.
The policy selects for a new session only: a later switch is the user's,
so a session already pinned stops instead of silently changing endpoint
and losing its cache.  The catalogue is asked at dispatch, not once when
the pin was made.  A pause sends nothing at all, and does not move the
session to the other allowed provider."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route '(:catalogue-at 0.0)))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons (harness-openrouter-test--catalogue-url-regexp)
                        `(:body ,(harness-json-encode
                                  (list :data
                                        (list :id harness-openrouter-test-model
                                              :endpoints
                                              (vector
                                               (plist-put
                                                (harness-openrouter-test--endpoint-json
                                                 "deepinfra/fp8" "DeepInfra")
                                                :status 1)
                                               (harness-openrouter-test--endpoint-json
                                                "cohere/fp8" "Cohere"
                                                :pricing '(:prompt "0.00000015"
                                                           :completion "0.0000005"
                                                           :input_cache_read "0.000000003"
                                                           :discount 0))))))))
                  (harness-openrouter-test--completion-response))
          (let ((events (harness-openrouter-test--run
                         (list :model (format "openrouter:%s" harness-openrouter-test-model)
                               :session session
                               :messages '((:role user :content ((:type "text" :text "hi"))))))))
            (should (eq 'error (plist-get (car (last events)) :stop-reason)))
            (should (eq 'endpoint-unavailable (plist-get (car (last events)) :error-kind)))
            ;; Nothing was sent, and the guessable alternative (Cohere) was
            ;; not tried either.
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                (plist-get r :url)))
                                    harness-openrouter-test--requests))
            (should-not harness-openrouter-test--stored)))))))

;;;; Body: the pin on the wire

(ert-deftest harness-provider-openrouter-body-restricts-to-the-pinned-endpoint ()
  "With a policy the body names one exact endpoint and no fallback.
The cache and privacy controls are per request; the tier is pinned to
default so a priority endpoint cannot take the traffic."
  (let* ((policy (harness-openrouter-test-policy))
         (request (list :model (format "openrouter:%s" harness-openrouter-test-model)
                        :session (list :id "session-1" :ext nil)
                        :messages '((:role user :content ((:type "text" :text "hi")))))))
    (let ((harness-openrouter-routing policy))
      ;; Pretend the session is already pinned.
      (let* ((route '(:model "deepseek/deepseek-v4.1-flash-1017"
                      :slug "deepinfra/fp8"
                      :provider "DeepInfra" :tier "default" :quantization "fp8"
                      :prompt 0.098 :completion 0.294 :cache-read 0.00294
                      :discount 0.51 :catalogue-at 0.0 :basis "chosen"))
             (request (plist-put (copy-sequence request) :session
                                 (list :id "session-1"
                                       :ext (list :openrouter-route route))))
             (body (harness-openrouter-test--routed-body policy route request))
             (provider (plist-get body :provider)))
        (should (equal '("deepinfra/fp8") (append (plist-get provider :only) nil)))
        (should (equal '("deepinfra/fp8") (append (plist-get provider :order) nil)))
        (should (eq :false (plist-get provider :allow_fallbacks)))
        (should (eq t (plist-get provider :require_parameters)))
        (should (equal "deny" (plist-get provider :data_collection)))
        (should (eq t (plist-get provider :zdr)))
        (should (equal "default" (plist-get body :service_tier)))
        (should (equal "session-1" (plist-get body :session_id)))
        (should (equal '(:include t) (plist-get body :usage)))
        ;; One exact slug, never a base provider slug: a base slug would
        ;; also match the flex and priority endpoints of that provider.
        (should-not (member "deepinfra" (append (plist-get provider :only) nil)))
        (should-not (member "deepinfra" (append (plist-get provider :order) nil)))))))

(ert-deftest harness-provider-openrouter-schema-only-where-the-endpoint-takes-one ()
  "A verdict schema goes only to a pinned endpoint that says it takes one.
OpenRouter passes `response_format' on to the endpoint, and only some
endpoints take a JSON schema: the pin records what the chosen endpoint
listed (`supported_parameters'), and a session with a pin whose endpoint
said nothing of one sends no schema rather than a field that would fail
the call.  Without routing there is no pin, and no schema."
  (let* ((policy (harness-openrouter-test-policy))
         (schema '(:type "object" :properties (:decision (:type "string"))
                   :required ["decision"]))
         (request (list :model (format "openrouter:%s" harness-openrouter-test-model)
                        :messages '((:role user :content ((:type "text" :text "hi"))))
                        :response-schema schema :response-schema-name "verdict")))
    (let ((harness-openrouter-routing policy))
      (let* ((pinned (plist-put (copy-sequence request) :session
                                (list :id "s" :ext (list :openrouter-route
                                                         (harness-openrouter-test--route
                                                          '(:structured-outputs t))))))
             (format (plist-get (harness-openrouter-test--routed-body
                                policy (plist-get (plist-get (plist-get pinned :session) :ext)
                                                  :openrouter-route) pinned)
                                :response_format)))
        (should (equal "json_schema" (plist-get format :type)))
        (should (equal "verdict" (plist-get (plist-get format :json_schema) :name)))
        (should (equal schema (plist-get (plist-get format :json_schema) :schema))))
      ;; An endpoint that listed no structured outputs gets no schema.
      (let ((unlisted (plist-put (copy-sequence request) :session
                                 (list :id "s" :ext (list :openrouter-route
                                                          (harness-openrouter-test--route))))))
        (should-not (plist-get (harness-openrouter-test--routed-body
                               policy (plist-get (plist-get (plist-get unlisted :session) :ext)
                                                 :openrouter-route) unlisted)
                               :response_format)))
      ;; A session with no pin yet is not sent one either: nothing has
      ;; said the endpoint it will be pinned to takes one.
      (should-not (plist-get (harness-openai--body (harness-openrouter--endpoint) "m" request)
                             :response_format)))
    ;; A new session's pin records what its endpoint listed, so a later
    ;; request of the same session carries the schema.
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-new")
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--catalogue-response)
                  (harness-openrouter-test--completion-response))
          (let* ((req (plist-put (copy-sequence request) :session (harness-openrouter-test--session "s-new")))
                 (events (harness-openrouter-test--run req)))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
            (should (eq t (plist-get harness-openrouter-test--stored :structured-outputs)))
            (should (plist-get (plist-get (car harness-openrouter-test--requests) :json)
                               :response_format))))))))

(ert-deftest harness-provider-openrouter-schema-withheld-from-an-endpoint-that-lists-none ()
  "An endpoint that lists no `structured_outputs' is pinned without it.
The catalogue's `supported_parameters' is what the pin records; an
endpoint that takes none gets a verdict request with no schema, and the
reply is read strictly as before."
  (let ((policy (harness-openrouter-test-policy)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-new")
        (harness-openrouter-test-with-fake
            (list (cons (harness-openrouter-test--catalogue-url-regexp)
                        `(:body ,(harness-openrouter-test--catalogue-json
                                  (harness-openrouter-test--endpoint-json
                                   "deepinfra/fp8" "DeepInfra"
                                   :supported-parameters '("tools"))
                                  (harness-openrouter-test--endpoint-json
                                   "cohere/fp8" "Cohere"
                                   :supported-parameters '("tools")
                                   :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                              :input_cache_read "0.000000003" :discount 0)))))
                  (harness-openrouter-test--completion-response))
          (let* ((req (harness-openrouter-test--request
                       (harness-openrouter-test--session "s-new")))
                 (req (plist-put req :response-schema '(:type "object")))
                 (req (plist-put req :response-schema-name "verdict"))
                 (events (harness-openrouter-test--run req)))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
            (should (equal "deepinfra/fp8" (plist-get harness-openrouter-test--stored :slug)))
            (should-not (plist-get harness-openrouter-test--stored :structured-outputs))
            (should-not (plist-get (plist-get (car harness-openrouter-test--requests) :json)
                                   :response_format))))))))

(ert-deftest harness-provider-openrouter-openrouter-fields-stay-openrouter-only ()
  "The dialect's fields go to an OpenRouter endpoint, and nowhere else.
This is the body assertion for the boundary: the same request sent to a
plain OpenAI endpoint and to a custom compatible one carries neither the
provider object, the tier, the sticky session nor OpenRouter's spelling
of the effort and the output limit."
  (let* ((policy (harness-openrouter-test-policy))
         (session (list :id "session-1"
                        :ext (list :openrouter-route
                                   '(:model "deepseek/deepseek-v4.1-flash-1017"
                                     :slug "deepinfra/fp8" :provider "DeepInfra"
                                     :tier "default" :basis "chosen"))))
         (request (list :model "x:y" :session session :thinking "medium" :max-tokens 100
                        :messages '((:role user :content ((:type "text" :text "hi")))))))
    (let ((harness-openrouter-routing policy))
      ;; The routed body is the one the dispatch builds: `x:y' would never
      ;; reach a dispatch, so this only asks the dialect what it adds.
      (let* ((harness-openrouter--sending policy)
             (routed (plist-put
                      (plist-put (copy-sequence request) :openrouter-policy policy)
                      :openrouter-route (plist-get (plist-get session :ext)
                                                   :openrouter-route)))
             (openrouter (harness-openai--body (harness-openrouter--endpoint) "m" routed))
             (plain (harness-openai--body
                     '(:id plain :base-url "https://api.openai.example/v1") "m" request))
             (custom (harness-openai--body
                      '(:id custom :base-url "https://custom.example/v1") "m" request)))
        (should (plist-get openrouter :provider))
        (should (equal "default" (plist-get openrouter :service_tier)))
        (should (equal "session-1" (plist-get openrouter :session_id)))
        (dolist (body (list plain custom))
          (should-not (plist-get body :provider))
          (should-not (plist-get body :service_tier))
          (should-not (plist-get body :session_id))
          (should-not (plist-get body :usage))
          (should-not (plist-get body :reasoning))
          (should (equal "medium" (plist-get body :reasoning_effort)))
          (should (= 100 (plist-get body :max_completion_tokens)))
          (should-not (plist-get body :max_tokens)))))))

(ert-deftest harness-provider-openrouter-new-session-is-pinned-then-sent ()
  "A new session's first request reads the catalogue, pins, and is sent.
The pin is stored on the session before the request goes out, so every
later request of the same session is restricted to it."
  (let ((policy (harness-openrouter-test-policy)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-1")
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--catalogue-response)
                  (harness-openrouter-test--completion-response))
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request))))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
            ;; The catalogue was read, once, for this exact model.
            (should (equal (format "https://openrouter.ai/api/v1/models/%s/endpoints"
                                   harness-openrouter-test-model)
                           (plist-get (car (last harness-openrouter-test--requests)) :url)))
            ;; The pin was stored before the completion was sent.
            (should (equal "deepinfra/fp8" (plist-get harness-openrouter-test--stored :slug)))
            (should (equal "chosen" (plist-get harness-openrouter-test--stored :basis)))
            (should (cl-find-if (lambda (h) (string-match-p "pinned" h))
                                harness-openrouter-test--hints))
            ;; The completion carried it.
            (let* ((sent (car harness-openrouter-test--requests))
                   (provider (plist-get (plist-get sent :json) :provider)))
              (should (equal '("deepinfra/fp8")
                             (append (plist-get provider :only) nil)))
              (should (eq :false (plist-get provider :allow_fallbacks))))))))))

(ert-deftest harness-provider-openrouter-refused-new-session-sends-nothing ()
  "A new session whose catalogue cannot be read sends no completion at all.
The 503 is an outage, so a step would wait for it; the wait is off here
(`harness-openrouter-catalogue-wait' 0) because what is under test is that
nothing is sent -- that a step waits instead is
`harness-provider-openrouter-a-transient-outage-is-waited-out'."
  (let ((policy (harness-openrouter-test-policy))
        (harness-openrouter-catalogue-wait 0))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-new")
        (harness-openrouter-test-with-fake
            (list (cons (harness-openrouter-test--catalogue-url-regexp)
                        '(:error (http-error 503 "unavailable"))))
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request))))
            (should (eq 'error (plist-get (car (last events)) :stop-reason)))
            (should (eq 'catalogue-unavailable (plist-get (car (last events)) :error-kind)))
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                (plist-get r :url)))
                                    harness-openrouter-test--requests))))))))

(ert-deftest harness-provider-openrouter-catalogue-failure-says-what-failed ()
  "A catalogue read that failed pauses with the reason, not with its shape.
`harness-http-request-json' rejects with (http-error STATUS BODY), a
tagged tuple and no defined error type.  Passing it on by signalling its
car used to replace the whole failure with \"Invalid error symbol:
http-error\", so a server that was briefly unavailable read as a bug in
the harness and the status was lost.  The pause names the status and what
the provider said."
  (let ((policy (harness-openrouter-test-policy))
        ;; The message a failure ends with, not the wait a step may spend
        ;; on one (`harness-provider-openrouter-a-transient-outage-is-waited-out').
        (harness-openrouter-catalogue-wait 0))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-new")
        (harness-openrouter-test-with-fake
            (list (cons (harness-openrouter-test--catalogue-url-regexp)
                        `(:body ,(harness-json-encode
                                  (list :error (list :message "upstream unavailable"))))))
          ;; A 200 whose body is an error object is a refusal to read too.
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request))))
            (should (eq 'catalogue-unavailable
                        (plist-get (car (last events)) :error-kind)))
            (should (equal (concat "OpenRouter routing paused: the endpoint catalogue"
                                   " could not be read: OpenRouter catalogue error: upstream unavailable")
                           (plist-get (car (last events)) :error)))))))))

(ert-deftest harness-provider-openrouter-a-refused-catalogue-names-the-status ()
  "A catalogue the server refused is reported by its HTTP status.
This is the failure that was reported as \"Invalid error symbol:
http-error\": the transport's own rejection, passed on by the shared
fetch and read by the pause.  What the session is told names the status
and what the provider said, and never an error symbol."
  (let ((policy (harness-openrouter-test-policy))
        ;; The message a failure ends with, not the wait a step may spend
        ;; on one (`harness-provider-openrouter-a-transient-outage-is-waited-out').
        (harness-openrouter-catalogue-wait 0))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-new")
        (harness-openrouter-test-with-fake
            (list (cons (harness-openrouter-test--catalogue-url-regexp)
                        '(:error (http-error 503 "unavailable"))))
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request))))
            (should (equal "OpenRouter routing paused: the endpoint catalogue could not be read: HTTP 503: unavailable"
                           (plist-get (car (last events)) :error)))
            (should-not (string-match-p "Invalid error symbol"
                                        (plist-get (car (last events)) :error)))))))))

(ert-deftest harness-provider-openrouter-unknown-prices-send-nothing ()
  "A fresh catalogue that cannot identify the endpoint sends no completion.
The block names the provider it could not resolve, and it never falls
through to the other allowed one."
  (let ((policy (harness-openrouter-test-policy)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-new")
        (harness-openrouter-test-with-fake
            (list (cons (harness-openrouter-test--catalogue-url-regexp)
                        `(:body ,(harness-openrouter-test--catalogue-json
                                  ;; Only Cohere is listed; the preferred
                                  ;; endpoint cannot be read at all.
                                  (harness-openrouter-test--endpoint-json
                                   "cohere/fp8" "Cohere"
                                   :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                              :input_cache_read "0.000000003"
                                              :discount 0)))))
                  (harness-openrouter-test--completion-response))
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request))))
            (should (eq 'error (plist-get (car (last events)) :stop-reason)))
            (should (eq 'unknown-endpoint (plist-get (car (last events)) :error-kind)))
            (should (string-match-p "DeepInfra" (plist-get (car (last events)) :error)))
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                (plist-get r :url)))
                                    harness-openrouter-test--requests))))))))

(ert-deftest harness-provider-openrouter-a-pinned-session-reuses-its-endpoint ()
  "An existing pin is used across turns and requests, without a new fetch."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route (harness-openrouter-test--route)))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--catalogue-response)
                  (harness-openrouter-test--completion-response))
          (dotimes (_ 2)
            (harness-openrouter-test--run (harness-openrouter-test--request session)))
          (should-not (cl-find-if (lambda (r) (string-match-p "/endpoints" (plist-get r :url)))
                                  harness-openrouter-test--requests))
          (let ((completions
                 (cl-remove-if-not
                  (lambda (r) (string-match-p "chat/completions" (plist-get r :url)))
                  harness-openrouter-test--requests)))
            (should (= 2 (length completions)))
            (dolist (completion completions)
              (should (equal '("deepinfra/fp8")
                             (append (plist-get (plist-get (plist-get completion :json) :provider)
                                                :only)
                                     nil))))))))))

(ert-deftest harness-provider-openrouter-a-stale-pin-is-revalidated-before-dispatch ()
  "A pin whose reading is too old is checked against a fresh catalogue first.
The reading is refreshed and the request still goes to the same
endpoint; revalidating is not switching."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route '(:catalogue-at 0.0)))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--catalogue-response)
                  (harness-openrouter-test--completion-response))
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request session))))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
            ;; The catalogue was read again, because the pin's own reading
            ;; was 0.0 -- older than the policy's freshness bound.
            (should (cl-find-if (lambda (r) (string-match-p "/endpoints" (plist-get r :url)))
                                harness-openrouter-test--requests))
            ;; Still the same endpoint, and the pin was not rewritten.
            (should-not harness-openrouter-test--stored)
            (let ((sent (car harness-openrouter-test--requests)))
              (should (equal '("deepinfra/fp8")
                             (append (plist-get (plist-get (plist-get sent :json) :provider)
                                                :only)
                                     nil))))))))))

(ert-deftest harness-provider-openrouter-a-pin-that-no-longer-qualifies-pauses ()
  "A pinned endpoint whose fresh price is over the maximum pauses.
It is not moved to the cheaper provider and it is not sent anyway: a
switch is cache-cold and the user's decision, so the session waits."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route '(:catalogue-at 0.0)))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route)))
         ;; DeepInfra's price has risen past the maximum; Cohere's has not.
         (risen (harness-openrouter-test--catalogue-json
                 (harness-openrouter-test--endpoint-json
                  "deepinfra/fp8" "DeepInfra"
                  :pricing '(:prompt "0.00000035" :completion "0.0000014"
                             :input_cache_read "0.0000000035" :discount 0))
                 (harness-openrouter-test--endpoint-json
                  "cohere/fp8" "Cohere"
                  :pricing '(:prompt "0.00000015" :completion "0.0000005"
                             :input_cache_read "0.000000003" :discount 0)))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons (harness-openrouter-test--catalogue-url-regexp)
                        `(:body ,risen))
                  (harness-openrouter-test--completion-response))
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request session))))
            (should (eq 'error (plist-get (car (last events)) :stop-reason)))
            (should (eq 'over-max-price (plist-get (car (last events)) :error-kind)))
            ;; Nothing was sent, and the pin was not moved to Cohere.
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                (plist-get r :url)))
                                    harness-openrouter-test--requests))
            (should-not harness-openrouter-test--stored)
            (should (cl-find-if (lambda (h) (string-match-p "dearer" h))
                                harness-openrouter-test--hints))))))))

(ert-deftest harness-provider-openrouter-a-pin-the-policy-dropped-pauses ()
  "A pin whose provider the policy no longer allows is not sent.
The provider was allowed once; a policy that no longer names it says the
pin is no longer allowed, and the request waits rather than going to an
endpoint the allowlist dropped -- or to the other provider."
  (let* ((policy (harness-openrouter-test-policy :providers '("Cohere")))
         (route (harness-openrouter-test--route '(:catalogue-at (float-time))))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request session))))
            (should (eq 'error (plist-get (car (last events)) :stop-reason)))
            (should (eq 'pin-not-vetted (plist-get (car (last events)) :error-kind)))
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                (plist-get r :url)))
                                    harness-openrouter-test--requests))))))))

(ert-deftest harness-provider-openrouter-a-lowered-limit-stops-a-fresh-pin ()
  "A pin whose recorded price is over the maximum now is not sent.
The limit is checked against the price the pin recorded on every
dispatch, not only when the catalogue is read again, so lowering it
under a pin that is still fresh stops the session.  It does not move to
the other allowed provider: a switch is the user's."
  (let* ((policy (harness-openrouter-test-policy))
         ;; The prompt limit is now under the pin's own recorded price.
         (limits (plist-put (copy-sequence (plist-get policy :max-price))
                            :prompt 0.001))
         (policy (plist-put policy :max-price limits))
         ;; The pin is fresh, so a catalogue would not be read at all.
         (route (harness-openrouter-test--route '(:catalogue-at (float-time))))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--catalogue-response)
                  (harness-openrouter-test--completion-response))
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request session))))
            (should (eq 'error (plist-get (car (last events)) :stop-reason)))
            (should (eq 'over-max-price (plist-get (car (last events)) :error-kind)))
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                (plist-get r :url)))
                                    harness-openrouter-test--requests))
            ;; And it was not re-pinned to the other endpoint.
            (should-not harness-openrouter-test--stored)))))))

(ert-deftest harness-provider-openrouter-an-empty-catalogue-stops-a-stale-pin ()
  "A refreshed catalogue that lists nothing stops the pin; it is not `no refresh'.
The pin's reading is too old, so the catalogue is read again; the answer
has no endpoint for this model at all, which is not evidence that the
pinned one still exists, and nothing is sent."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route '(:catalogue-at 0.0)))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons (harness-openrouter-test--catalogue-url-regexp)
                        `(:body ,(harness-json-encode
                                  (list :data (list :id harness-openrouter-test-model
                                                    :endpoints [])))))
                  (harness-openrouter-test--completion-response))
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request session))))
            (should (eq 'error (plist-get (car (last events)) :stop-reason)))
            (should (eq 'catalogue-empty (plist-get (car (last events)) :error-kind)))
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                (plist-get r :url)))
                                    harness-openrouter-test--requests))))))))

(ert-deftest harness-provider-openrouter-a-removed-endpoint-stops-a-stale-pin ()
  "A refreshed catalogue that no longer lists the pin stops it, and does not reselect.
The other allowed endpoint is still there and cheaper than nothing; it is
not chosen, because a pin that stops qualifying pauses the session."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route '(:catalogue-at 0.0)))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons (harness-openrouter-test--catalogue-url-regexp)
                        `(:body ,(harness-openrouter-test--catalogue-json
                                  (harness-openrouter-test--endpoint-json
                                   "cohere/fp8" "Cohere"
                                   :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                              :input_cache_read "0.000000003" :discount 0)))))
                  (harness-openrouter-test--completion-response))
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request session))))
            (should (eq 'error (plist-get (car (last events)) :stop-reason)))
            (should (eq 'unknown-endpoint (plist-get (car (last events)) :error-kind)))
            (should-not harness-openrouter-test--stored)
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                (plist-get r :url)))
                                    harness-openrouter-test--requests))))))))

(ert-deftest harness-provider-openrouter-an-unknown-price-component-blocks ()
  "A listing that prices a component the maximum does not cover blocks.
The limit bounds prompt, completion and cache-read; a per-request fee,
an image charge or a cache-write rate is a billable component nobody
compared, so an endpoint that charges one is not one this policy can
send to, whatever its prompt price says."
  (let* ((policy (harness-openrouter-test-policy))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse
                    (harness-openrouter-test--catalogue-json
                     (harness-openrouter-test--endpoint-json
                      "deepinfra/fp8" "DeepInfra"
                      :pricing '(:prompt "0.000000098" :completion "0.000000294"
                                 :input_cache_read "0.00000000294"
                                 :input_cache_write "0.0000002"
                                 :discount 0.51))
                     (harness-openrouter-test--endpoint-json
                      "cohere/fp8" "Cohere"
                      :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                 :input_cache_read "0.000000003" :discount 0))))))
         (decision (harness-openrouter-test--select records policy)))
    ;; The endpoint that charges a cache write blocks the decision, rather
    ;; than being read as if the write cost nothing.
    (should-not (plist-get decision :ok))
    (should (eq 'price-component-unknown (plist-get decision :reason)))
    (should (string-match-p "input_cache_write" (plist-get decision :detail)))))

(ert-deftest harness-provider-openrouter-an-unhealthy-new-candidate-is-not-unknown-policy ()
  "Reported nonzero health excludes a candidate, without inventing its cause.
A new session may select qualified Cohere; an existing pin still requires
separate transition evidence and authorization."
  (let* ((policy (harness-openrouter-test-policy))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse
                    (harness-openrouter-test--catalogue-json
                     (append (harness-openrouter-test--endpoint-json
                              "deepinfra/fp8" "DeepInfra")
                             (list :status -5))
                     (harness-openrouter-test--endpoint-json
                      "cohere/fp8" "Cohere"
                      :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                 :input_cache_read "0.000000003" :discount 0))))))
         (decision (harness-openrouter-test--select records policy)))
    (should (plist-get decision :ok))
    (should (equal "Cohere" (plist-get decision :provider)))))

(ert-deftest harness-provider-openrouter-the-wire-carries-a-max-price ()
  "A routed request states the configured maximum as `max_price' on the wire.
It is a second defence: OpenRouter's own router refuses an endpoint
dearer than the limit in prompt or completion, whatever this module
read.  It covers nothing else -- the documentation offers no cache-read
cap -- so cache-read is checked here and never assumed covered, and no
per-request fee is bounded by it."
  (let* ((policy (harness-openrouter-test-policy))
         (session (list :id "session-1"
                        :ext (list :openrouter-route
                                   (harness-openrouter-test--route))))
         (request (list :model (format "openrouter:%s" harness-openrouter-test-model)
                        :session session
                        :messages '((:role user :content ((:type "text" :text "hi"))))))
         (body (let ((harness-openrouter-routing policy))
                 (harness-openrouter-test--routed-body
                  policy (harness-openrouter-test--route) request)))
         (max-price (plist-get (plist-get body :provider) :max_price)))
    (should max-price)
    (should (harness-openrouter-test--approx 0.15 (plist-get max-price :prompt)))
    (should (harness-openrouter-test--approx 0.60 (plist-get max-price :completion)))
    ;; No cache-read cap is sent, because the API has none: this module
    ;; never claims one protects a cache read.
    (should-not (plist-member max-price :cache-read))
    (should-not (plist-member max-price :input_cache_read))))

(ert-deftest harness-provider-openrouter-an-unbounded-request-fee-blocks ()
  "A per-request fee no limit bounds is refused before sending.
OpenRouter's `max_price' accepts a `request' fee, and the policy's
maximum is prompt, completion and cache-read only; an endpoint that
charges a fee no limit covers is not one this policy can send to."
  (let* ((policy (harness-openrouter-test-policy))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse
                    (harness-openrouter-test--catalogue-json
                     (harness-openrouter-test--endpoint-json
                      "deepinfra/fp8" "DeepInfra"
                      :pricing '(:prompt "0.000000098" :completion "0.000000294"
                                 :input_cache_read "0.00000000294"
                                 :request "0.005"
                                 :discount 0.51))
                     (harness-openrouter-test--endpoint-json
                      "cohere/fp8" "Cohere"
                      :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                 :input_cache_read "0.000000003" :discount 0))))))
         (decision (harness-openrouter-test--select records policy)))
    (should-not (plist-get decision :ok))
    (should (eq 'price-component-unknown (plist-get decision :reason)))))

(ert-deftest harness-provider-openrouter-a-pin-is-never-retried-elsewhere ()
  "A refused pin stops; no retry is ever sent to another host.
The fake serves the completion, and the catalogue says the pinned
endpoint is gone: the turn ends with an error and the completion URL is
never reached, so there is no request to a second host to retry.

The pin here was written before this module recorded canonical slugs, so
its model record is read once, too -- a read, on the endpoint's own host,
with no completion in it.  What the test holds to is that nothing is ever
sent to a completion URL, and to no host but the one the pin names."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route '(:catalogue-at 0.0)))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons (harness-openrouter-test--catalogue-url-regexp)
                        `(:body ,(harness-openrouter-test--catalogue-json
                                  (harness-openrouter-test--endpoint-json
                                   "cohere/fp8" "Cohere"))))
                  (cons "/model/" `(:body ,(harness-json-encode
                                            (list :data (list :id harness-openrouter-test-model
                                                              :canonical_slug
                                                              "deepseek/deepseek-v4.1-flash-20261017")))))
                  (harness-openrouter-test--completion-response))
          (harness-openrouter-test--run (harness-openrouter-test--request session))
          ;; Two reads and no send: the catalogue, and the model record
          ;; that the slug-less pin needs before it can be audited.
          (should (= 2 (length harness-openrouter-test--requests)))
          (should-not (cl-find-if (lambda (r) (string-match-p "/chat/completions\\'"
                                                              (plist-get r :url)))
                                  harness-openrouter-test--requests))
          ;; Both read from OpenRouter itself, and nowhere else.
          (dolist (request harness-openrouter-test--requests)
            (should (string-match-p "\\`https://openrouter\\.ai/" (plist-get request :url)))))))))

(ert-deftest harness-provider-openrouter-a-pin-from-before-slugs-is-upgraded ()
  "A pin with no recorded slug is completed before it is sent, once.
A session pinned by a build that did not record canonical slugs keeps
its route: the same endpoint, the same prices.  What it lacks is the slug
OpenRouter's summary will name, so without it every answer such a
session gets is refused by the audit, after a request that worked.  The
dispatch reads the model record, records the slug on the pin, and the
turn ends `end-turn' -- and the next dispatch spends no such read again."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route))   ; no :canonical-slug
         (session (harness-openrouter-test--session
                   "s-old" (list :openrouter-route route))))
    (should-not (plist-get route :canonical-slug))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons "/model/"
                        `(:body ,(harness-json-encode
                                  (list :data (list :id harness-openrouter-test-model
                                                    :canonical_slug
                                                    "deepseek/deepseek-v4.1-flash-20261017")))))
                  (harness-openrouter-test--catalogue-response)
                  ;; The answer's summary names the slug, as the live API
                  ;; does for an aliased model.
                  (harness-openrouter-test--answer-from-summary
                   "DeepInfra" "deepseek/deepseek-v4.1-flash-20261017"))
          (let ((events (harness-openrouter-test--run
                         (harness-openrouter-test--request session))))
            ;; The turn survived: this is Noah's session, on the next send.
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
            (should-not (cl-find 'response-mismatch events :key (lambda (e) (plist-get e :type))))
            ;; The slug was recorded on the pin, endpoint and price unchanged.
            (should (equal "deepseek/deepseek-v4.1-flash-20261017"
                           (plist-get harness-openrouter-test--stored :canonical-slug)))
            (should (equal "deepinfra/fp8"
                           (plist-get harness-openrouter-test--stored :slug)))
            (should (equal (plist-get route :prompt)
                           (plist-get harness-openrouter-test--stored :prompt)))
            ;; A second dispatch of the now-completed pin reads no model
            ;; record: the one request it spends is the completion.
            (let ((before (length harness-openrouter-test--requests)))
              (harness-openrouter-test--run (harness-openrouter-test--request session))
              (let ((made (cl-remove-if-not
                           (lambda (r) (string-match-p "/model/" (plist-get r :url)))
                           (take (- (length harness-openrouter-test--requests) before)
                                 harness-openrouter-test--requests))))
                (should-not made)))))))))

(ert-deftest harness-provider-openrouter-a-pin-that-knows-its-slug-spends-no-read ()
  "A pin already carrying its canonical slug makes no model-record request.
The slug is a property of the model, read once when the pin was made, so
every later dispatch of that pin is the one request it means to send."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route
                 '(:canonical-slug "deepseek/deepseek-v4.1-flash-20261017")))
         (session (harness-openrouter-test--session
                   "s-new" (list :openrouter-route route))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons "/model/"
                        `(:body ,(harness-json-encode
                                  (list :data (list :id harness-openrouter-test-model
                                                    :canonical_slug
                                                    "deepseek/deepseek-v4.1-flash-20261017")))))
                  (harness-openrouter-test--catalogue-response)
                  (harness-openrouter-test--answer-from-summary
                   "DeepInfra" "deepseek/deepseek-v4.1-flash-20261017"))
          (let ((events (harness-openrouter-test--run
                         (harness-openrouter-test--request session))))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
            (should-not (cl-find-if (lambda (r) (string-match-p "/model/" (plist-get r :url)))
                                    harness-openrouter-test--requests))))))))

(ert-deftest harness-provider-openrouter-a-failed-slug-read-is-not-remembered ()
  "A model record that could not be read is read again, not remembered as nil.
The slug is a property of the model, so a reading of it is kept for the
process.  A *failure* is not a reading: caching its nil would leave a pin
with no slug for the rest of the process, and the audit would then refuse
every turn of that session after a request that worked -- the same
fail-forever shape as storing no slug at all, reached by a different
door.  One transient failure must cost one retry, not the session."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route))   ; no :canonical-slug
         (session (harness-openrouter-test--session
                   "s-old" (list :openrouter-route route)))
         (reads 0)
         (model-body (harness-json-encode
                      (list :data (list :id harness-openrouter-test-model
                                        :canonical_slug
                                        "deepseek/deepseek-v4.1-flash-20261017")))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons "/model/" `(:body ,model-body))
                  (harness-openrouter-test--catalogue-response)
                  (harness-openrouter-test--answer-from-summary
                   "DeepInfra" "deepseek/deepseek-v4.1-flash-20261017"))
          ;; The first model read fails, as one transport error does; every
          ;; later one is answered by the fake above.
          (cl-letf* ((real (symbol-function 'harness-http-request))
                     ((symbol-function 'harness-http-request)
                      (lambda (url &rest args)
                        (if (and (string-match-p "/model/" url) (zerop reads))
                            (progn
                              (cl-incf reads)
                              ;; No status, no body, an error: a transport
                              ;; failure, which is not a reading of the model.
                              (when (plist-get args :callback)
                                (funcall (plist-get args :callback)
                                         nil nil ""
                                         (list 'error "connection reset by peer")))
                              (make-harness-http-handle :url url :started (float-time)))
                          (when (string-match-p "/model/" url) (cl-incf reads))
                          (apply real url args)))))
            ;; First dispatch: the read fails, so the pin gains no slug and
            ;; nothing is remembered about the model.
            (let ((events (harness-openrouter-test--run
                           (harness-openrouter-test--request session))))
              (should (= 1 reads))
              (should-not (plist-get harness-openrouter-test--stored :canonical-slug))
              (should-not (gethash harness-openrouter-test-model
                                   harness-openrouter--canonical)))
            ;; Second dispatch: it reads again rather than reusing the
            ;; failure, records the slug, and that turn survives its audit.
            (let ((events (harness-openrouter-test--run
                           (harness-openrouter-test--request session))))
              (should (= 2 reads))
              (should (equal "deepseek/deepseek-v4.1-flash-20261017"
                             (plist-get harness-openrouter-test--stored :canonical-slug)))
              (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
              (should-not (cl-find 'response-mismatch events
                                   :key (lambda (e) (plist-get e :type)))))))))))

(ert-deftest harness-provider-openrouter-response-from-another-provider-is-refused ()
  "An answer that names another provider is a failed answer, with no reply."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route (harness-openrouter-test--route)))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons "chat/completions"
                        (apply #'harness-openrouter-test--stream-body
                               (list (list :id "gen-2" :model harness-openrouter-test-model
                                           :provider "OpenInference" :service_tier "default"
                                           :choices (vector
                                                     (list :index 0
                                                           :delta (list :content "wrong host")
                                                           :finish_reason "stop")))))))
          (let* ((events (harness-openrouter-test--run (harness-openrouter-test--request session)))
                 (done (car (last events))))
            (should (eq 'error (plist-get done :stop-reason)))
            (should (string-match-p "OpenInference" (plist-get done :error)))
            (should (string-match-p "DeepInfra" (plist-get done :error)))
            ;; The answer's tools are not run, and the step is a failure the
            ;; agent rewinds (harness-agent--rewind-step) rather than a reply:
            ;; text that already streamed cannot be unsent, and this is what
            ;; stops it from being taken as the model's answer.
            (should-not (cl-find-if (lambda (e) (eq (plist-get e :type) 'tool-call)) events))))))))

(ert-deftest harness-provider-openrouter-a-mismatch-is-announced ()
  "A refused answer leaves an event naming what it claimed and what was pinned.
The session's own log then says the provider answered that it did not
pin, without the harness having to infer it from the error text."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route (harness-openrouter-test--route))))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (cl-letf (((symbol-function 'harness-emit)
                   (lambda (type &rest args)
                     (when (eq type 'openrouter/response-mismatch)
                       (push (cons type args) events))
                     (when (fboundp 'harness--emit-original)
                       (apply #'harness--emit-original type args)))))
          (harness-openrouter-test-with-fake
              (list (cons "chat/completions"
                          (apply #'harness-openrouter-test--stream-body
                                 (list (list :id "gen-4" :model harness-openrouter-test-model
                                             :provider "OpenInference" :service_tier "default"
                                             :choices (vector
                                                       (list :index 0
                                                             :delta (list :content "wrong host")
                                                             :finish_reason "stop")))))))
            (let ((done (car (last (harness-openrouter-test--run
                                    (harness-openrouter-test--request session))))))
              (should (eq 'error (plist-get done :stop-reason)))
              (should (equal "s-pinned" (cadr (car events))))
              (should (string-match-p "OpenInference" (caddr (car events))))
              (should (string-match-p "DeepInfra" (caddr (car events)))))))))))

(ert-deftest harness-provider-openrouter-response-without-provider-is-refused ()
  "A routed answer that names no provider is refused, not assumed."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route (harness-openrouter-test--route)))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons "chat/completions"
                        (apply #'harness-openrouter-test--stream-body
                               (list (list :id "gen-3" :model harness-openrouter-test-model
                                           :choices (vector
                                                     (list :index 0
                                                           :delta (list :content "unattributed")
                                                           :finish_reason "stop")))))))
          (let* ((events (harness-openrouter-test--run (harness-openrouter-test--request session)))
                 (done (car (last events))))
            (should (eq 'error (plist-get done :stop-reason)))
            (should (string-match-p "named no provider" (plist-get done :error)))))))))

(ert-deftest harness-provider-openrouter-model-mismatch-is-refused-before-sending ()
  "A request for another model is refused before anything is sent.
The policy is for one exact checkpoint; another version, or a direct
provider, is not routed by it and is not sent unrestricted either."
  (let ((policy (harness-openrouter-test-policy)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-1")
        (harness-openrouter-test-with-fake
            (list (cons "chat/completions" '(:body "{}")))
          (dolist (model '("openrouter:deepseek/deepseek-v4.1-flash"
                           "openrouter:deepseek/deepseek-v4.1-flash-1017:free"
                           "openrouter:cohere/command-a"))
            (let* ((request (plist-put (harness-openrouter-test--request) :model model))
                   (events (harness-openrouter-test--run request)))
              (should (eq 'error (plist-get (car (last events)) :stop-reason)))
              (should (eq 'route-paused (plist-get (car (last events)) :error-kind)))))
          (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                              (plist-get r :url)))
                                  harness-openrouter-test--requests)))))))

;;;; Errors: the OpenInference HTTP 400

(ert-deftest harness-provider-openrouter-error-detail-is-kept-and-content-free ()
  "An upstream error keeps its code, provider and generation, and no prompt.
The body below is the shape OpenRouter documents for a provider error;
what the harness keeps is the identity of the failure, never the request."
  (let* ((body (harness-json-encode
                '(:error (:code 400
                          :message "Upstream error from OpenInference: Upstream returned HTTP 400"
                          :metadata (:error_type "invalid_request"
                                     :provider_name "OpenInference"
                                     :provider_code "invalid_payload"))
                  :id "gen-abc123")))
         (detail (harness-openrouter--error-detail body 400)))
    (should (string-match-p "error_type=invalid_request" detail))
    (should (string-match-p "provider=OpenInference" detail))
    (should (string-match-p "provider_code=invalid_payload" detail))
    (should (string-match-p "generation=gen-abc123" detail))
    ;; Nothing of a prompt can be in it: the fixture has none to leak, and
    ;; the function only reads the fields above.
    (should-not (string-match-p "Upstream returned" detail))))

(ert-deftest harness-provider-openrouter-error-detail-appears-in-the-stop-reason ()
  "The transport appends the dialect's detail to a failed request's error."
  (let ((body (harness-json-encode
               '(:error (:code 400 :message "Upstream error from OpenInference: Upstream returned HTTP 400"
                         :metadata (:error_type "invalid_request" :provider_name "OpenInference"))))))
    (harness-openrouter-test-with-fake
        `(("chat/completions" . (:status 400 :body ,body)))
      (let* ((events (harness-openrouter-test--run
                      (list :model "openrouter:x"
                            :messages '((:role user :content ((:type "text" :text "hi")))))))
             (done (car (last events))))
        (should (eq 'error (plist-get done :stop-reason)))
        (should (string-match-p "HTTP 400" (plist-get done :error)))
        (should (string-match-p "error_type=invalid_request" (plist-get done :error)))
        (should (string-match-p "provider=OpenInference" (plist-get done :error)))))))

(ert-deftest harness-provider-openrouter-an-ephemeral-request-sends-without-storing ()
  "A one-off call's request is routed and sent, and no pin is stored.
The judge names a session of its own, which no session record holds.
Routing must not store a pin under that id: `session/set-ext' signals
`No session' before anything is sent, and the caller is left waiting for
its deadline.  The route is still chosen and applied, and the request
goes out exactly once, to the selected endpoint."
  (let ((policy (harness-openrouter-test-policy)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-1")
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--catalogue-response)
                  (harness-openrouter-test--completion-response))
          (let* ((req (plist-put (copy-sequence (harness-openrouter-test--request))
                                 :ephemeral t))
                 (events (harness-openrouter-test--run req))
                 (completions
                  (cl-remove-if-not
                   (lambda (r) (string-match-p "chat/completions" (plist-get r :url)))
                   harness-openrouter-test--requests)))
            ;; One completion was sent, and the call ended as the fixture says.
            (should (= 1 (length completions)))
            (should (= 1 (length (harness-openrouter-test--done-events events))))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
            ;; It went to the endpoint routing selected, and no other.
            (should (equal '("deepinfra/fp8")
                           (append (plist-get (plist-get (plist-get (car completions) :json)
                                                         :provider)
                                              :only)
                                   nil)))
            (should (eq :false (plist-get (plist-get (plist-get (car completions) :json)
                                                     :provider)
                                          :allow_fallbacks)))
            ;; Nothing was pinned under the one-off session's id.
            (should-not harness-openrouter-test--stored)))))))

(defun harness-openrouter-test--routing-failure (failure)
  "Run a request that is not ephemeral and cannot be pinned, for FAILURE.
FAILURE is `:no-session' -- the registry does not hold the session -- or
`:store-refused' -- the registry refuses the write.  Return the events
the caller saw, oldest first, with the fake transport in place.  The
session is a real `harness-sessions' entry, which `session/exists-p'
reads; no store is loaded in this suite, so the record is made directly
rather than through `session/create'."
  (let* ((cwd (harness-test-temp-dir))
         (parent (format "s-real-%s" (harness-short-id)))
         (real (symbol-function 'harness-call))
         (events nil))
    (unwind-protect
        (progn
          (puthash parent
                   (make-harness-session :id parent :name parent :cwd cwd
                                         :kind 'main :status 'idle)
                   harness-sessions)
          (cl-letf (((symbol-function 'harness-call)
                     (lambda (method &rest args)
                       (pcase method
                         ('session/exists-p
                          (if (eq failure :no-session)
                              nil
                            (apply real method args)))
                         ('session/set-ext
                          (if (eq failure :store-refused)
                              (signal 'harness-error (list "the store refused it"))
                            (apply real method args)))
                         (_ (apply real method args))))))
            (harness-call 'provider/complete
                          (plist-put (copy-sequence
                                      (harness-openrouter-test--request
                                       (list :id (format "%s-perms" parent)
                                             :cwd cwd :host nil)))
                                     :on-event (lambda (e) (push e events)))))
          (harness-test-wait
           (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type))))
           5 "done"))
      (remhash parent harness-sessions))
    (nreverse events)))

(defun harness-openrouter-test--assert-routing-failed (events)
  "Assert EVENTS say the call failed without reaching the transport."
  ;; Nothing was sent: no completion reached the fake.
  (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                     (plist-get r :url)))
                          harness-openrouter-test--requests))
  ;; The caller was told, once, rather than left waiting for its deadline.
  (let ((done (harness-openrouter-test--done-events events)))
    (should (= 1 (length done)))
    (should (eq 'error (plist-get (car done) :stop-reason)))
    (should (equal 'routing-failed (plist-get (car done) :error-kind)))))

(ert-deftest harness-provider-openrouter-a-missing-session-fails-closed ()
  "A request that is not ephemeral and names no known session sends nothing.
The ephemeral skip must not weaken an ordinary request: a session the
registry does not hold is an error, raised before anything is sent, and
the caller hears it as a `done'."
  (let ((policy (harness-openrouter-test-policy)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--catalogue-response)
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test--assert-routing-failed
         (harness-openrouter-test--routing-failure :no-session))))))

(ert-deftest harness-provider-openrouter-a-refused-pin-fails-closed ()
  "A request that is not ephemeral and cannot store its pin sends nothing.
A registry that refuses the write is an error, raised before anything is
sent, and the caller hears it as a `done'."
  (let ((policy (harness-openrouter-test-policy)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--catalogue-response)
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test--assert-routing-failed
         (harness-openrouter-test--routing-failure :store-refused))))))

(defun harness-openrouter-test--repeat-of (route request)
  "Return REQUEST as a repeat of a send authorised by ROUTE.
A repeat carries, in its own state, what authorised the send it repeats
\(`harness-retry-authorise'): the policy and the route.  That is the path
`harness-openrouter--complete''s `repeat' branch takes, which is where a
one-off call's second attempt goes."
  (let ((state (make-harness-retry--request)))
    (setf (harness-retry--request-retrying state) t)
    (harness-retry-authorise
     (harness-retry-attach request state)
     (list :policy harness-openrouter-routing :route route))))

(ert-deftest harness-provider-openrouter-a-repeat-of-a-one-off-call-stores-no-pin ()
  "A one-off call's repeat completes a slugless pin without storing it.
A repeat goes to `harness-openrouter--complete-pinned', whose canonical
slug repair stores the completed route.  For a one-off call that id is
the call's own (`SESSION-perms'), which no session record holds, so the
store raised `No session' inside a promise callback: nothing was sent and
the caller never heard anything, which is the deadline it then sat out.
The repair is told the call is a one-off, so it announces the route and
stores nothing -- and the request still goes out."
  (let* ((policy (harness-openrouter-test-policy))
         (judge (harness-openrouter-test--session "s-judge")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session judge
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (harness-openrouter-test--seed-reading 5)
          ;; The pin has no slug, and the model record answers now, as a
          ;; repeat's re-read would.
          (cl-letf (((symbol-function 'harness-openrouter--fetch-canonical-slug)
                     (lambda (_model)
                       (harness-resolved "deepseek/deepseek-v4.1-flash-20261017"))))
            (let* ((request (harness-openrouter-test--repeat-of
                             (harness-openrouter-test--route)
                             (plist-put (harness-openrouter-test--request judge)
                                        :ephemeral t)))
                   (events (harness-openrouter-test--run request)))
              ;; The call went out and ended, rather than sitting out a
              ;; deadline it could never beat.
              (should (= 1 (length (harness-openrouter-test--done-events events))))
              (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
              ;; Nothing was pinned under the one-off session's id.
              (should-not harness-openrouter-test--stored))))))))

(ert-deftest harness-provider-openrouter-a-repeat-of-a-session-call-still-stores ()
  "An ordinary request's repeat still records the completed pin.
The one-off skip must not be widened: a repeat of a real session's
request stores its completed route as it always did, so the pin the next
dispatch reads carries the slug the audit needs."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-real")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (harness-openrouter-test--seed-reading 5)
          (cl-letf (((symbol-function 'harness-openrouter--fetch-canonical-slug)
                     (lambda (_model)
                       (harness-resolved "deepseek/deepseek-v4.1-flash-20261017"))))
            (let ((events (harness-openrouter-test--run
                           ;; The same repeat path, for a real session: no
                           ;; `:ephemeral', so its pin is stored.
                           (harness-openrouter-test--repeat-of
                            (harness-openrouter-test--route)
                            (harness-openrouter-test--request session)))))
              (should (= 1 (length (harness-openrouter-test--done-events events))))
              (should (eq 'end-turn (plist-get (car (last events)) :stop-reason))))))
        ;; Stored under the session's own id, with the slug recorded.
        (should harness-openrouter-test--stored)
        (should (equal "deepseek/deepseek-v4.1-flash-20261017"
                       (plist-get harness-openrouter-test--stored :canonical-slug)))))))

(ert-deftest harness-provider-openrouter-fork-does-not-inherit-a-pin ()
  "A fork starts unpinned; the parent's pin is never copied to it.
The pin lives in the session's `ext', which `session/fork' does not copy,
so a fork chooses for itself -- a fresh decision for a fresh
conversation, not the parent's mutable state."
  (let* ((policy (harness-openrouter-test-policy))
         (parent (harness-openrouter-test--session
                  "s-parent" (list :openrouter-route (harness-openrouter-test--route))))
         (fork (harness-openrouter-test--session "s-fork")))
    (harness-openrouter-test-with-policy policy
      (should (harness-openrouter--route-of parent))
      (should-not (harness-openrouter--route-of fork))
      ;; And a fork's request is refused until it has a pin of its own --
      ;; which is what the catalogue step above is for.
      (let ((seen nil))
        (harness-openrouter-test-with-session fork
          (harness-openrouter-test-with-fake
              (list (harness-openrouter-test--catalogue-response)
                    (harness-openrouter-test--completion-response))
            (setq seen (harness-openrouter-test--run (harness-openrouter-test--request fork)))
            (should (equal "deepinfra/fp8"
                           (plist-get harness-openrouter-test--stored :slug)))
            (should (eq 'end-turn (plist-get (car (last seen)) :stop-reason)))))))))

(ert-deftest harness-provider-openrouter-switch-is-refused-while-busy ()
  "A switch is a cache-cold transition, so it is never automatic or mid-turn."
  (let ((policy (harness-openrouter-test-policy)))
    (harness-openrouter-test-with-policy policy
      (cl-letf (((symbol-function 'harness-call)
                 (lambda (method &rest args)
                   (pcase method
                     ('session/get (plist-put (harness-openrouter-test--session (car args))
                                              :status 'running))
                     (_ nil)))))
        (should (string-match-p
                 "busy"
                 (cadr (should-error (harness-openrouter-switch "s-1" "Cohere")))))))))

(ert-deftest harness-provider-openrouter-switch-checks-the-endpoint-it-moves-to ()
  "A switch resolves the provider exactly as a new session does.
The price is the catalogue's, the route records that it was switched and
why, and a provider the policy does not name is refused outright."
  (let ((policy (harness-openrouter-test-policy))
        (harness-openrouter-routing (harness-openrouter-test-policy)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-1")
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--catalogue-response))
          (harness-test-await
           (harness-openrouter-switch "s-1" "Cohere" "cheaper"))
          (should (equal "cohere/fp8" (plist-get harness-openrouter-test--stored :slug)))
          (should (equal "switched" (plist-get harness-openrouter-test--stored :basis)))
          (should (equal "cheaper" (plist-get harness-openrouter-test--stored :why)))
          ;; A provider the policy does not name is never a switch target.
          (should (string-match-p
                   "No allowed provider"
                   (cadr (should-error
                          (harness-openrouter-switch "s-1" "OpenAI"))))))))))

(ert-deftest harness-provider-openrouter-switch-refuses-an-unverified-endpoint ()
  "A provider whose endpoint cannot be read now is not switched to."
  (let ((policy (harness-openrouter-test-policy)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-1")
        (harness-openrouter-test-with-fake
            (list (cons (harness-openrouter-test--catalogue-url-regexp)
                        `(:body ,(harness-openrouter-test--catalogue-json
                                  ;; Cohere absent: the switch target cannot be read.
                                  (harness-openrouter-test--endpoint-json
                                   "deepinfra/fp8" "DeepInfra")))))
          ;; The switch checks the catalogue as a new session does, and a
          ;; promise that rejects is the refusal.
          (should-error (harness-test-await
                         (harness-openrouter-switch "s-1" "Cohere")))
          (should-not harness-openrouter-test--stored))))))

;;;; Cancellation

(ert-deftest harness-provider-openrouter-a-routing-error-is-delivered-once ()
  "A routing error ends the call exactly once, and a later cancel adds nothing.
The pin cannot be stored, so the success handler signals.  That is
delivered as one `done' with `routing-failed' -- not left to the caller's
deadline -- and cancelling afterwards, twice, emits nothing further.
Nothing reaches the transport."
  (let ((policy (harness-openrouter-test-policy))
        (session (harness-openrouter-test--session "s-new"))
        (events nil)
        (handle nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        ;; Captured inside `with-session', so the stubs it installs stay in
        ;; the chain: only `session/set-ext' is overridden, and every other
        ;; call reaches them.
        (let ((real (symbol-function 'harness-call)))
          (harness-openrouter-test-with-fake
              (list (harness-openrouter-test--catalogue-response)
                    (harness-openrouter-test--completion-response))
            (cl-letf (((symbol-function 'harness-call)
                       (lambda (method &rest args)
                         (pcase method
                           ('session/set-ext
                            (signal 'harness-error (list "the store refused it")))
                           (_ (apply real method args))))))
              (setq handle (harness-call 'provider/complete
                                         (plist-put (harness-openrouter-test--request session)
                                                    :on-event (lambda (e) (push e events)))))
              (harness-test-wait
               (lambda () (harness-openrouter-test--done-events events)) 5 "done"))
            ;; All request assertions inside `with-fake', where the fake's
            ;; own record of what it served is still bound.
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                               (plist-get r :url)))
                                    harness-openrouter-test--requests))
            (let ((done (harness-openrouter-test--done-events events)))
              (should (= 1 (length done)))
              (should (eq 'error (plist-get (car done) :stop-reason)))
              (should (equal 'routing-failed (plist-get (car done) :error-kind))))
            ;; Cancelling afterwards is harmless and announces nothing more.
            (funcall (plist-get handle :cancel))
            (funcall (plist-get handle :cancel))
            (should (= 1 (length (harness-openrouter-test--done-events events))))))))))

(ert-deftest harness-provider-openrouter-cancel-before-the-catalogue-resolves ()
  "Cancelling before the catalogue answers stops the request and sends nothing.
The handle is a real cancel closure in both phases, so this is the bug
that signalled `void-function :cancel': the cancel before a pin exists
must work, must not send the completion, and must not emit a done event."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (events nil)
         (handle nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        ;; A fake whose catalogue never answers: the request is cancelled
        ;; while it waits.
        (let ((harness-openrouter-test--requests nil)
              (harness-openrouter-test--responses
               (list (cons (harness-openrouter-test--catalogue-url-regexp) '(:hang t)))))
          (cl-letf (((symbol-function 'harness-http-request)
                     (lambda (url &rest args)
                       (push (list :url url :args args) harness-openrouter-test--requests)
                       (make-harness-http-handle :url url :started (float-time)))))
            (setq handle (harness-call 'provider/complete
                                       (plist-put (harness-openrouter-test--request session)
                                                  :on-event (lambda (e) (push e events))))))
          (should (functionp (plist-get handle :cancel)))
          ;; Before the catalogue resolves: this used to be `void-function :cancel'.
          (plist-get handle :cancel)
          (funcall (plist-get handle :cancel))
          ;; Repeated cancel is harmless.
          (funcall (plist-get handle :cancel))
          ;; Nothing was sent and no answer was announced.
          (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                              (plist-get r :url)))
                                  harness-openrouter-test--requests))
          (should-not (cl-find-if (lambda (e) (eq (plist-get e :type) 'done)) events))
          (should-not harness-openrouter-test--stored))))))

(ert-deftest harness-provider-openrouter-a-cancelled-judge-call-leaves-no-running-record ()
  "The cancel that leaves no `done' still ends the internal session of the call.
This is the hang the harness had: the permission judge asks OpenRouter,
its deadline cancels the handle, and the provider -- which emits nothing
for a cancel -- used to leave the internal session `running' for good.
Through the real provider path, the record is finished once, as
cancelled, and the provider's own cancel still reaches the transport.
The record's own methods are stubs, so what is checked is the provider's
obligation to end the call, not the session store's."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (events nil)
         (handle nil)
         (finished nil)
         (started nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (unwind-protect
            (progn
              (harness-register-method 'session/internal-start
                                       (lambda (&rest plist)
                                         (setq started plist) "s-internal-1"))
              (harness-register-method 'session/usage-add (lambda (&rest _) nil))
              (harness-register-method 'session/internal-finish
                                       (lambda (id &rest plist)
                                         (push (cons id plist) finished) id))
              (harness-openrouter-test-with-fake
                  (list (harness-openrouter-test--catalogue-response)
                        (harness-openrouter-test--completion-response))
                (setq harness-openrouter-test--hold '("chat/completions"))
                (setq handle (harness-call 'provider/complete
                                           (plist-put
                                            (plist-put (harness-openrouter-test--request session)
                                                       :job "Permission judge")
                                            :on-event (lambda (e) (push e events)))))
                ;; The call is recorded, and the handle names its record.
                (should started)
                (should (equal "Permission judge" (plist-get started :job)))
                (should (equal "s-internal-1" (plist-get handle :session)))
                (harness-test-wait
                 (lambda () (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                    (plist-get r :url)))
                                        harness-openrouter-test--requests))
                 5 "the completion to be sent")
                (let* ((request (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                        (plist-get r :url)))
                                            harness-openrouter-test--requests))
                       (chunk (plist-get (plist-get request :args) :on-chunk)))
                  ;; The model had written something before the cancel came.
                  (when chunk (funcall chunk (harness-openrouter-test--sse
                                              '(:choices ((:index 0 :delta (:content "Allow")))))))
                  (funcall (plist-get handle :cancel))
                  ;; The record is ended once, as cancelled, with what the
                  ;; model had written kept as the reply.
                  (should (= 1 (length finished)))
                  (should (equal "s-internal-1" (caar finished)))
                  (should (eq 'cancelled (plist-get (cdar finished) :stop-reason)))
                  (should (equal "Allow" (plist-get (cdar finished) :reply)))
                  ;; A repeated cancel records nothing more, and a late
                  ;; answer from the transport does not either.
                  (funcall (plist-get handle :cancel))
                  (when chunk (funcall chunk (harness-openrouter-test--sse
                                              '(:choices ((:index 0 :delta (:content " more")))))))
                  (should (= 1 (length finished)))
                  (should (equal "Allow" (plist-get (cdar finished) :reply)))
                  ;; The cancel reached the transport: one done, as cancelled.
                  (should (= 1 (length (cl-remove-if-not
                                        (lambda (e) (eq (plist-get e :type) 'done)) events)))))))
          (harness-unregister-method 'session/internal-start)
          (harness-unregister-method 'session/usage-add)
          (harness-unregister-method 'session/internal-finish))))))

(ert-deftest harness-provider-openrouter-cancel-during-the-transport-cleans-up ()
  "Cancelling while a pinned request is in flight cancels the transport.
The catalogue has answered and the completion has reached the fake HTTP
layer but not answered.  The cancel reaches that request: the turn ends
once, as `cancelled`, no answer is announced, a callback that arrives
afterwards emits nothing more, and a second cancel does nothing.  No
completion is retried and no other request is made."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (events nil)
         (handle nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--catalogue-response)
                  (harness-openrouter-test--completion-response))
          ;; The completion is sent but never answered by the fake.
          (setq harness-openrouter-test--hold '("chat/completions"))
          (setq handle (harness-call 'provider/complete
                                     (plist-put (harness-openrouter-test--request session)
                                                :on-event (lambda (e) (push e events)))))
          ;; Wait for the pin to be chosen and the completion to be sent.
          (harness-test-wait
           (lambda () (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                              (plist-get r :url)))
                                  harness-openrouter-test--requests))
           5 "the completion to be sent")
          (let* ((request (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                  (plist-get r :url)))
                                      harness-openrouter-test--requests))
                 (args (plist-get request :args))
                 (callback (plist-get args :callback))
                 (chunk (plist-get args :on-chunk)))
            (should (functionp (plist-get handle :cancel)))
            (funcall (plist-get handle :cancel))
            ;; The transport was cancelled and the turn ended once, as a
            ;; cancellation -- not as an answer and not as an error.
            (let ((done (cl-remove-if-not (lambda (e) (eq (plist-get e :type) 'done))
                                          events)))
              (should (= 1 (length done)))
              (should (eq 'cancelled (plist-get (car done) :stop-reason)))
              (should-not (plist-get (car done) :error)))
            (should-not (cl-find-if (lambda (e) (eq (plist-get e :type) 'text)) events))
            ;; The answer the fake would have given, delivered after the
            ;; cancel: nothing more is emitted for it.
            (let ((before (length events)))
              (when chunk (funcall chunk (harness-openrouter-test--sse
                                          '(:choices () :usage (:prompt_tokens 4
                                                                :completion_tokens 1)))))
              (funcall callback 200 nil "" nil)
              (should (= before (length events))))
            ;; A second cancel is harmless and nothing was retried.
            (funcall (plist-get handle :cancel))
            (should (= 1 (length (cl-remove-if-not
                                  (lambda (r) (string-match-p "chat/completions"
                                                              (plist-get r :url)))
                                  harness-openrouter-test--requests))))))))))

(ert-deftest harness-provider-openrouter-cancel-of-a-refused-request-is-a-no-op ()
  "A request the policy refuses returns a cancel handle that does nothing.
A refusal never reaches a transport, so its handle must still be one a
caller can safely cancel -- before, during or after nothing happened."
  (let* ((policy (harness-openrouter-test-policy :enabled nil))
         (session (harness-openrouter-test--session "s-1")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake nil
          (let* ((handle (harness-call 'provider/complete
                                       (plist-put (harness-openrouter-test--request session)
                                                  :on-event #'ignore))))
            (should (functionp (plist-get handle :cancel)))
            (funcall (plist-get handle :cancel))
            (funcall (plist-get handle :cancel))
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                (plist-get r :url)))
                                    harness-openrouter-test--requests))))))))

;;;; Boundary: what must not change

(ert-deftest harness-provider-openrouter-plain-openai-is-untouched ()
  "A plain OpenAI endpoint is sent its old body and no OpenRouter request.
The policy is on, and none of it may reach an endpoint that is not
OpenRouter's: no catalogue read, no provider object, no pin."
  (let ((policy (harness-openrouter-test-policy))
        (endpoint '(:id plain :label "Plain" :base-url "https://api.openai.example/v1"
                    :api-key "sk-test")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons "chat/completions"
                      (apply #'harness-openrouter-test--stream-body
                             (list '(:model "gpt-x" :choices
                                     ((:index 0 :delta (:content "ok") :finish_reason "stop")))))))
        (let* ((events (harness-openrouter-test--complete*
                        endpoint
                        (list :model "plain:gpt-x" :thinking "medium" :max-tokens 64
                              :session (list :id "s-1")
                              :messages '((:role user :content ((:type "text" :text "hi"))))))))
          (should (equal '(done) (last (mapcar (lambda (e) (plist-get e :type)) events))))
          (let* ((sent (car harness-openrouter-test--requests))
                 (body (plist-get sent :json)))
            (should-not (plist-get body :provider))
            (should-not (plist-get body :service_tier))
            (should-not (plist-get body :session_id))
            (should-not (plist-get body :usage))
            (should-not (plist-get body :reasoning))
            (should (equal "medium" (plist-get body :reasoning_effort)))
            (should (= 64 (plist-get body :max_completion_tokens)))
            ;; No OpenRouter catalogue request, and no metadata header.
            (should-not (cl-find-if (lambda (r) (string-match-p "openrouter" (plist-get r :url)))
                                    harness-openrouter-test--requests))
            (should-not (assoc "X-OpenRouter-Metadata" (plist-get sent :headers)))))))))

(ert-deftest harness-provider-openrouter-custom-compatible-endpoint-is-untouched ()
  "A custom OpenAI-compatible server keeps its body, key and retry policy."
  (let ((policy (harness-openrouter-test-policy))
        (endpoint '(:id custom :label "Custom" :base-url "http://localhost:8080/v1"
                    :models ("local-model"))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons "chat/completions"
                      (apply #'harness-openrouter-test--stream-body
                             (list '(:choices ((:index 0 :delta (:content "ok")
                                                :finish_reason "stop")))))))
        (harness-openrouter-test--complete*
         endpoint
         (list :model "custom:local-model" :session (list :id "s-1")
               :messages '((:role user :content ((:type "text" :text "hi"))))))
        (let* ((sent (car harness-openrouter-test--requests))
               (body (plist-get sent :json))
               (args (plist-get sent :args)))
          (should (equal "http://localhost:8080/v1/chat/completions" (plist-get sent :url)))
          (should-not (plist-get body :provider))
          (should-not (assoc "X-OpenRouter-Metadata" (plist-get sent :headers)))
          (should-not (assoc "X-Title" (plist-get sent :headers)))
          ;; The step-level retry contract is the transport's, unchanged.
          (should (eq t (plist-get args :retry))))))))

(ert-deftest harness-provider-openrouter-policy-off-is-the-old-provider ()
  "With no policy, OpenRouter sends what it always sent: usage and nothing else.
There is no catalogue request, no provider object, no tier, no pin, and
no metadata header -- the module is loaded and does nothing."
  (let ((harness-openrouter-routing nil))
    (harness-openrouter-test-with-policy nil
      (harness-openrouter-test-with-fake
          (list (cons "chat/completions"
                      (apply #'harness-openrouter-test--stream-body
                             (list '(:model harness-openrouter-test-model :provider "DeepInfra"
                                     :choices ((:index 0 :delta (:content "ok")
                                                :finish_reason "stop")))))))
        (let ((events (harness-openrouter-test--run
                       (list :model (format "openrouter:%s" harness-openrouter-test-model)
                             :session (list :id "s-1")
                             :messages '((:role user :content ((:type "text" :text "hi"))))))))
          (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
          (should-not (cl-find-if (lambda (r) (string-match-p "/endpoints" (plist-get r :url)))
                                  harness-openrouter-test--requests))
          (let* ((sent (car harness-openrouter-test--requests))
                 (body (plist-get sent :json)))
            (should (equal '(:include t) (plist-get body :usage)))
            (should-not (plist-get body :provider))
            (should-not (plist-get body :service_tier))
            (should-not (plist-get body :session_id))
            (should-not (assoc "X-OpenRouter-Metadata" (plist-get sent :headers)))
            ;; And no pin was stored on the session.
            (should-not (plist-get body :session))))))))

(ert-deftest harness-provider-openrouter-disabled-policy-sends-nothing ()
  "A configured but disabled policy routes nothing and says so.
A policy is not an activation: without `:enabled' the session pauses
rather than sending an unrestricted request."
  (let ((policy (harness-openrouter-test-policy :enabled nil)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-1")
        (harness-openrouter-test-with-fake
            (list (cons "chat/completions" '(:body "{}")))
          (let* ((events (harness-openrouter-test--run
                          (harness-openrouter-test--request))))
            (should (eq 'error (plist-get (car (last events)) :stop-reason)))
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions" (plist-get r :url)))
                                    harness-openrouter-test--requests))))))))

(ert-deftest harness-provider-openrouter-lists-no-models-without-a-key ()
  "OpenRouter's endpoint needs a key to advertise models, as before.
The generic module used to know OpenRouter's host by name; the dialect's
`:key-needed' flag is how this module says it now, and an unconfigured
OpenRouter endpoint lists nothing rather than advertising models no
request could run."
  (let ((endpoint (harness-openrouter--endpoint))
        (auth-sources nil))
    (should (eq 'openrouter (plist-get endpoint :id)))
    (should (plist-get (harness-openai--dialect endpoint) :key-needed))
    (cl-letf (((symbol-function 'harness-openai--api-key) (lambda (_) nil))
              ((symbol-function 'getenv) (lambda (_) nil))
              ((symbol-function 'harness-openai--fetch-models)
               (lambda (_) (ert-fail "No listing without a key"))))
      (should-not (harness-openai--configured-p endpoint)))
    ;; With a key it is configured, and the endpoint reads the user's own
    ;; configuration for its URL, key and headers.
    (should (harness-openai--configured-p (plist-put (copy-sequence endpoint)
                                                     :api-key "sk-test")))
    (let ((harness-openai-endpoints
           '((:id openrouter :label "Mine" :base-url "https://router.example/v1"
             :headers (("X-Custom" . "1"))))))
      (let ((mine (harness-openrouter--endpoint)))
        (should (equal "https://router.example/v1" (plist-get mine :base-url)))
        (should (equal "Mine" (plist-get mine :label)))
        (should (equal '(("X-Custom" . "1")) (plist-get mine :headers)))
        ;; The dialect is this module's whatever the entry says.
        (should (eq 'openrouter (plist-get (plist-get mine :dialect) :flavor)))))))

(ert-deftest harness-provider-openrouter-legacy-endpoint-overrides-are-kept ()
  "An old OpenRouter entry in `harness-openai-endpoints' keeps every field.
Before this module existed the entry was the generic module's, and every
key it documents was read: the static `models', the fixed `tiers', the
`default-context' and the `capabilities', beside its label, URL, key and
headers.  Moving the provider here must not silently drop them: a
configuration that listed models or set a tier by hand still gets them."
  (let ((harness-openai-endpoints
         '((:id openrouter :label "Mine" :base-url "https://router.example/v1"
            :api-key "sk-legacy" :api-key-env "MY_ROUTER_KEY"
            :headers (("X-Custom" . "1"))
            :models ("my-model" "other-model")
            :tiers (:medium "my-model" :hard "other-model")
            :default-context 200000
            :allow-models ("openrouter:my-*")
            :capabilities (:vision t :thinking nil :pricing dynamic)))))
    (let ((endpoint (harness-openrouter--endpoint)))
      (should (equal "Mine" (plist-get endpoint :label)))
      (should (equal "https://router.example/v1" (plist-get endpoint :base-url)))
      (should (equal "sk-legacy" (plist-get endpoint :api-key)))
      (should (equal "MY_ROUTER_KEY" (plist-get endpoint :api-key-env)))
      (should (equal '(("X-Custom" . "1")) (plist-get endpoint :headers)))
      ;; The four that used to be dropped.
      (should (equal '("my-model" "other-model") (plist-get endpoint :models)))
      (should (equal '(:medium "my-model" :hard "other-model") (plist-get endpoint :tiers)))
      (should (equal 200000 (plist-get endpoint :default-context)))
      ;; The narrowing an entry states is kept too: OpenRouter lists
      ;; several hundred models, and this is the case it is for.
      (should (equal '("openrouter:my-*") (plist-get endpoint :allow-models)))
      (should (equal '(:vision t :thinking nil :pricing dynamic)
                     (plist-get endpoint :capabilities)))
      ;; And the transport reads them: a static listing is offered without
      ;; a key, with the endpoint's own context window.
      (let ((harness-openai--models-cache (make-hash-table :test 'eq))
            (auth-sources nil))
        (let ((models (harness-test-await (harness-openai--models endpoint))))
          (should (equal '("my-model" "other-model")
                         (mapcar (lambda (m) (plist-get m :name)) models)))
          (should (equal 200000 (plist-get (car models) :context-window))))
        (should (equal '(:vision t :thinking nil :pricing dynamic)
                       (harness-openai--capabilities endpoint)))))))

(ert-deftest harness-provider-openrouter-plain-openai-keeps-no-openrouter-fields ()
  "The legacy fields are read for OpenRouter's entry only.
A plain OpenAI entry and a custom compatible one gain nothing of
OpenRouter's: no provider object, no tier, no pin, no dialect, and their
own static models and tiers are still the generic module's."
  (let ((harness-openai-endpoints
         '((:id openai :label "OpenAI" :base-url "https://api.openai.com/v1"
            :models ("gpt-x") :tiers (:hard "gpt-x") :default-context 128000)
           (:id custom :label "Custom" :base-url "http://localhost:8080/v1"
            :models ("local") :capabilities (:vision t)))))
    (let ((openrouter (harness-openrouter--endpoint)))
      (should (eq 'openrouter (plist-get openrouter :id)))
      (should-not (plist-get openrouter :models)))
    (let ((plain (harness-openai-endpoint 'openai))
          (custom (harness-openai-endpoint 'custom)))
      (should (equal '("gpt-x") (plist-get plain :models)))
      (should (equal '(:hard "gpt-x") (plist-get plain :tiers)))
      (should (equal 128000 (plist-get plain :default-context)))
      (should-not (plist-get plain :dialect))
      (should-not (plist-get custom :dialect))
      (should-not (plist-get plain :flavor))
      ;; And the generic module still registers them as its own.
      (let ((harness-openai-endpoint-owners nil))
        (should-not (harness-openai--owned-p 'openai))
        (should-not (harness-openai--owned-p 'custom))))))

(ert-deftest harness-provider-openrouter-a-regional-variant-makes-the-endpoint-ambiguous ()
  "A provider listed at two standard endpoints is not pinned at all.
OpenRouter can serve one endpoint from several regions under tags that
share a prefix, so a second regional record of the same provider is not
the endpoint the policy allowed: it could receive requests the operator
never chose.  The provider blocks instead, naming which one, and the
other allowed provider is not sent in its place."
  (let* ((policy (harness-openrouter-test-policy))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse
                    (harness-openrouter-test--catalogue-json
                     ;; The pinned endpoint, and a new region of it.
                     (harness-openrouter-test--endpoint-json
                      "deepinfra/fp8" "DeepInfra")
                     (harness-openrouter-test--endpoint-json
                      "deepinfra/fp8/us" "DeepInfra")
                     (harness-openrouter-test--endpoint-json
                      "cohere/fp8" "Cohere"
                      :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                 :input_cache_read "0.000000003" :discount 0))))))
         (decision (harness-openrouter-test--select records policy)))
    ;; The ambiguous provider blocks; it is not dropped for the other one.
    (should-not (plist-get decision :ok))
    (should (eq 'unknown-endpoint (plist-get decision :reason)))
    (should (string-match-p "DeepInfra" (plist-get decision :detail)))))

(ert-deftest harness-provider-openrouter-a-flex-or-priority-sibling-is-not-selected ()
  "A provider's tier endpoints do not take its standard endpoint's traffic.
The catalogue can list `deepinfra/fp8/flex' and `deepinfra/fp8/priority'
beside `deepinfra/fp8'.  The policy buys the standard endpoint, so the
tier records are not candidates -- and the cheaper flex one is not chosen
just because it is cheaper."
  (let* ((policy (harness-openrouter-test-policy))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse
                    (harness-openrouter-test--catalogue-json
                     (harness-openrouter-test--endpoint-json
                      "deepinfra/fp8" "DeepInfra")
                     (harness-openrouter-test--endpoint-json
                      "deepinfra/fp8/flex" "DeepInfra" :tier "flex"
                      :pricing '(:prompt "0.0000000784" :completion "0.0000002352"
                                 :input_cache_read "0.000000002352" :discount 0.51))
                     (harness-openrouter-test--endpoint-json
                      "deepinfra/fp8/priority" "DeepInfra" :tier "priority"
                      :pricing '(:prompt "0.000000147" :completion "0.000000441"
                                 :input_cache_read "0.00000000441" :discount 0.51))
                     (harness-openrouter-test--endpoint-json
                      "cohere/fp8" "Cohere"
                      :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                 :input_cache_read "0.000000003" :discount 0))))))
         (decision (harness-openrouter-test--select records policy)))
    (should (plist-get decision :ok))
    (should (equal "deepinfra/fp8" (plist-get (plist-get decision :endpoint) :slug)))
    ;; The flex endpoint is cheaper, and is not what the provider's name
    ;; selects.
    (should (equal "deepinfra/fp8" (plist-get (plist-get decision :record) :tag)))
    (should (equal "default" (plist-get (plist-get decision :endpoint) :tier)))))

(ert-deftest harness-provider-openrouter-a-tier-only-provider-is-not-pinned ()
  "A provider the catalogue lists only at a tier endpoint is not pinned.
The policy buys the standard endpoint; when no standard record exists
there is no endpoint it may use, and the provider blocks rather than
being sent to at whatever tier the catalogue happens to offer."
  (let* ((policy (harness-openrouter-test-policy))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse
                    (harness-openrouter-test--catalogue-json
                     (harness-openrouter-test--endpoint-json
                      "deepinfra/fp8/flex" "DeepInfra" :tier "flex"
                      :pricing '(:prompt "0.0000000784" :completion "0.0000002352"
                                 :input_cache_read "0.000000002352" :discount 0.51))
                     (harness-openrouter-test--endpoint-json
                      "cohere/fp8" "Cohere"
                      :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                 :input_cache_read "0.000000003" :discount 0))))))
         (decision (harness-openrouter-test--select records policy)))
    (should-not (plist-get decision :ok))
    (should (eq 'unknown-endpoint (plist-get decision :reason)))
    (should (string-match-p "DeepInfra" (plist-get decision :detail)))))

(ert-deftest harness-provider-openrouter-an-answer-from-another-region-is-refused ()
  "An answer that names another region than the pin's is refused.
OpenRouter's routing summary can name the region it served from, and a
routed session's answer is audited for it when both the pin and the
answer name one.  A field the answer does not carry proves nothing, and
the documentation says so rather than claiming certainty."
  (let* ((route (harness-openrouter-test--route '(:region "us")))
         (state (list :route route :model harness-openrouter-test-model
                      :provider "DeepInfra" :service-tier "default"
                      :region "eu"))
         (stream (make-harness-openai--stream :dialect-state state)))
    (should (string-match-p "region eu"
                            (harness-openrouter--audit stream 'end-turn)))
    ;; The same region, or an answer that names none, is not a mismatch.
    (should-not (harness-openrouter--audit
                 (make-harness-openai--stream
                  :dialect-state (plist-put (copy-sequence state) :region "us"))
                 'end-turn))
    (should-not (harness-openrouter--audit
                 (make-harness-openai--stream
                  :dialect-state (plist-put (copy-sequence state) :region nil))
                 'end-turn))))

(ert-deftest harness-provider-openrouter-a-selected-endpoint-in-the-summary-is-audited ()
  "A routing summary that names another endpoint as selected is refused.
The metadata header asks for the routing summary, which lists the
endpoints that were available and marks the one chosen.  A summary that
marks a different provider, or a different model, as selected is
evidence the answer came from somewhere the pin did not allow."
  (let* ((route (harness-openrouter-test--route))
         (base (list :route route :model harness-openrouter-test-model
                     :provider "DeepInfra" :service-tier "default"))
         (audit (lambda (available)
                  (harness-openrouter--audit
                   (make-harness-openai--stream
                    :dialect-state (plist-put (copy-sequence base)
                                              :available-endpoints available))
                   'end-turn))))
    (should-not (funcall audit
                         '((:provider "DeepInfra" :model harness-openrouter-test-model
                            :selected t)
                           (:provider "Cohere" :model harness-openrouter-test-model
                            :selected nil))))
    (should (string-match-p "selected"
                            (funcall audit
                                     '((:provider "Cohere" :model harness-openrouter-test-model
                                        :selected t)))))
    (should (string-match-p "selected"
                            (funcall audit
                                     '((:provider "DeepInfra" :model "other/model"
                                        :selected t)))))))

(ert-deftest harness-provider-openrouter-the-summary-canonical-slug-is-not-another-model ()
  "A summary naming the pin's canonical slug is the pinned model served.
OpenRouter's routing summary names the model the request resolved to,
and for an aliased model that is not the string the request asked for:
a request for `deepseek/deepseek-v4.1-flash-1017' is served as
`deepseek/deepseek-v4.1-flash-20261017' (live, 2026-11-12).  Comparing
the two as strings refused every answer such a session ever got, with
\"the routing summary names ... as selected, not the pinned ...\".  The
slug the pin recorded is therefore accepted, and nothing else is: the
same shape under another snapshot is still a mismatch."
  (let* ((route (harness-openrouter-test--route
                 '(:canonical-slug "deepseek/deepseek-v4.1-flash-20261017")))
         (base (list :route route :model harness-openrouter-test-model
                     :provider "DeepInfra" :service-tier "default"))
         (audit (lambda (state)
                  (harness-openrouter--audit
                   (make-harness-openai--stream :dialect-state state)
                   'end-turn)))
         (state (lambda (model)
                  (plist-put (plist-put (copy-sequence base) :model harness-openrouter-test-model)
                             :available-endpoints
                             (list (list :provider "DeepInfra" :model model :selected t))))))
    ;; The canonical slug the pin recorded: the pinned model, served.
    (should-not (funcall audit (funcall state "deepseek/deepseek-v4.1-flash-20261017")))
    ;; The pinned model itself, as the answer's own field names it.
    (should-not (funcall audit (funcall state harness-openrouter-test-model)))
    ;; Another snapshot of the same alias, and another model: mismatches.
    (should (string-match-p "selected"
                            (funcall audit (funcall state "deepseek/deepseek-v4.1-flash-20260910"))))
    (should (string-match-p "selected"
                            (funcall audit (funcall state "deepseek/deepseek-v4.1-chat-1017"))))
    ;; A pin with no recorded slug accepts the model it asked for only, so
    ;; a summary naming the resolved slug is refused rather than assumed.
    (let ((bare (funcall state "deepseek/deepseek-v4.1-flash-20261017")))
      (setq bare (plist-put bare :route (harness-openrouter-test--route)))
      (should (string-match-p "selected" (funcall audit bare))))))

(ert-deftest harness-provider-openrouter-an-alias-pin-records-the-canonical-slug ()
  "Pinning records the canonical slug OpenRouter reports for the model.
The slug comes from the provider's own model record (`canonical_slug'),
so no rule about how a slug is spelled decides which model is which.  A
model whose slug is its own canonical one records nothing, and a record
that cannot be read leaves the pin as it was rather than refusing."
  (let* ((policy (harness-openrouter-test-policy))
         (model harness-openrouter-test-model))
    (harness-openrouter-test-with-policy policy
      (let ((harness-openrouter--canonical (make-hash-table :test 'equal)))
        (harness-openrouter-test-with-fake
            (list (cons "/model/" `(:body ,(harness-json-encode
                                            (list :data (list :id model
                                                              :canonical_slug
                                                              "deepseek/deepseek-v4.1-flash-20261017"))))))
          (should (equal "deepseek/deepseek-v4.1-flash-20261017"
                         (harness-test-await
                          (harness-openrouter--fetch-canonical-slug model)))))
        ;; Read once: the slug is a property of the model, not the request.
        (let ((count (cl-count-if (lambda (r) (string-match-p "/model/" (plist-get r :url)))
                                  harness-openrouter-test--requests)))
          (harness-openrouter--fetch-canonical-slug model)
          (should (= count (cl-count-if (lambda (r) (string-match-p "/model/" (plist-get r :url)))
                                        harness-openrouter-test--requests))))
        ;; A model that is its own canonical slug records nothing.
        (let ((harness-openrouter--canonical (make-hash-table :test 'equal)))
          (harness-openrouter-test-with-fake
              (list (cons "/model/" `(:body ,(harness-json-encode
                                              (list :data (list :id model
                                                                :canonical_slug model))))))
            (should-not (harness-test-await
                         (harness-openrouter--fetch-canonical-slug model)))))
        ;; A record that cannot be read is no reason to refuse anything.
        (let ((harness-openrouter--canonical (make-hash-table :test 'equal)))
          (harness-openrouter-test-with-fake
              (list (cons "/model/" '(:error (http-error 503 "unavailable"))))
            (should-not (harness-test-await
                         (harness-openrouter--fetch-canonical-slug model)))))))))

(ert-deftest harness-provider-openrouter-a-pinned-answer-naming-the-slug-is-accepted ()
  "A whole routed turn whose summary names the canonical slug succeeds.
This is the integration proof of the fix above: the pin is made for an
aliased model, the answer's summary names the resolved slug, and the
turn ends `end-turn' rather than failing its audit."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new")))
    (harness-openrouter-test-with-policy policy
      (let ((harness-openrouter--canonical (make-hash-table :test 'equal)))
        (harness-openrouter-test-with-session session
          (harness-openrouter-test-with-fake
              (list (cons "/model/"
                          `(:body ,(harness-json-encode
                                    (list :data (list :id harness-openrouter-test-model
                                                      :canonical_slug
                                                      "deepseek/deepseek-v4.1-flash-20261017")))))
                    (harness-openrouter-test--catalogue-response)
                    (harness-openrouter-test--answer-from-summary
                     "DeepInfra" "deepseek/deepseek-v4.1-flash-20261017"))
            (let ((events (harness-openrouter-test--run
                           (harness-openrouter-test--request session))))
              (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
              ;; The pin recorded the slug the summary will name.
              (should (equal "deepseek/deepseek-v4.1-flash-20261017"
                             (plist-get harness-openrouter-test--stored :canonical-slug))))))))))

(defun harness-openrouter-test--demo-fake (url &rest args)
  "Call the demo's own fake transport for URL with ARGS.
The demo is loaded from the repository rather than from the load path,
because it is not a module: it is the artifact `demo.sh' runs."
  (require 'demo
           (expand-file-name "demo/openrouter-pinning/demo.el" harness-test-root))
  (apply (symbol-function 'demo--fake-http) url args))

(ert-deftest harness-provider-openrouter-the-demo-answers-every-read-the-pin-makes ()
  "The demo's fake transport answers every URL a new-session pin reads.
A pin reads the endpoint listing, and -- for the canonical slug it
records -- the model record.  The demo's transport must answer both.
When the slug read was added, that transport did not know it: the read
never completed, cases 7 and 8 printed SEND, and the committed picture
beside them said STOP.  No suite noticed, because nothing ran the demo.

So the URLs a pin actually asks for are read from a real dispatch here,
and the demo's transport is asked for each of them: one it does not
answer, or answers as something else, fails this test rather than
quietly changing what the demo prints."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-demo"))
         (urls nil))
    (harness-openrouter-test-with-policy policy
      (let ((harness-openrouter--canonical (make-hash-table :test 'equal)))
        (harness-openrouter-test-with-session session
          (harness-openrouter-test-with-fake
              (list (cons "/model/"
                          `(:body ,(harness-json-encode
                                    (list :data (list :id harness-openrouter-test-model
                                                      :canonical_slug
                                                      "deepseek/deepseek-v4.1-flash-20261017")))))
                    (harness-openrouter-test--catalogue-response)
                    (harness-openrouter-test--answer-from-summary "DeepInfra" nil))
            (harness-openrouter-test--run (harness-openrouter-test--request session))
            (setq urls (delete-dups
                        (mapcar (lambda (r) (plist-get r :url))
                                harness-openrouter-test--requests)))))))
    ;; The reads a pin makes, named: a new one is a change to this list.
    (should (= 1 (length (cl-remove-if-not
                          (lambda (url) (string-match-p "/endpoints\\'" url)) urls))))
    (should (= 1 (length (cl-remove-if-not
                          (lambda (url) (string-match-p "/model/" url)) urls))))
    ;; The demo answers every read, and counts no read as a completion to
    ;; send.  A completion it is asked for is recorded and not sent, which
    ;; is the other half of what the in-flight cases print.
    (let ((reads (cl-remove-if (lambda (url)
                                 (string-match-p "/chat/completions\\'" url))
                               urls)))
      (should (= 2 (length reads)))
      (dolist (url reads)
        (let ((callback nil))
          (harness-openrouter-test--demo-fake
           url :callback (lambda (_status _headers _body _err) (setq callback t)))
          ;; The listing is held, for a case to answer; the model record is
          ;; answered at once, with the slug OpenRouter reports.
          (should (equal callback (and (string-match-p "/model/" url) t)))))
      (should-not demo--sent))
    ;; And a URL it does not know is an error, never a quiet completion.
    (should-error (harness-openrouter-test--demo-fake
                   "https://openrouter.ai/api/v1/something-new" :callback #'ignore))))

(ert-deftest harness-provider-openrouter-other-modules-keep-their-endpoints ()
  "Claiming OpenRouter leaves every other endpoint in the generic module.
The ownership registry is what moves one provider out and leaves the
rest of the shared transport alone."
  (let ((harness-openai-endpoint-owners nil)
        (harness-openai-endpoints
         '((:id openai :base-url "https://api.openai.com/v1")
           (:id custom :base-url "https://custom.example/v1"))))
    (should-not (harness-openai--owned-p 'openai))
    (should-not (harness-openai--owned-p 'custom))
    (cl-letf (((symbol-function 'harness-define-provider) (lambda (&rest _) nil)))
      ;; Claiming as this module would leaves its id alone from then on.
      (let ((harness--defining-module 'provider-openrouter))
        (harness-openai-claim-endpoint 'openrouter))
      (should (harness-openai--owned-p 'openrouter))
      (should-not (harness-openai--owned-p 'openai)))
    ;; The generic defaults still register OpenAI and a custom endpoint,
    ;; and never OpenRouter.
    (harness-openai--register-all)
    (should (harness-provider-get 'openai))
    (should (harness-provider-get 'custom))))

;;;; P1: the policy may not change under a request that is in flight
;;
;; A request is prepared under one policy and sent after an asynchronous
;; catalogue read.  Each test below starts with a valid enabled policy,
;; holds the catalogue unanswered with the production callbacks, edits
;; the configured policy, and only then lets the reading resolve.  What
;; matters is that the transport is not called: a helper reporting a
;; refusal is not the property, sending nothing is.

(defun harness-openrouter-test--completion-request-p (request)
  "Non-nil when REQUEST, a recorded fake request, is a completion."
  (string-match-p "chat/completions" (plist-get request :url)))

(defun harness-openrouter-test--sent-completions ()
  "Return the completion requests the fake served, newest first."
  (cl-remove-if-not #'harness-openrouter-test--completion-request-p
                    harness-openrouter-test--requests))

(defun harness-openrouter-test--newest-done (events)
  "Return the newest done event of EVENTS, which are newest first."
  (car (harness-openrouter-test--done-events events)))

(defun harness-openrouter-test--paused-kind (events)
  "Return the error kind of the newest done EVENT of EVENTS."
  (plist-get (harness-openrouter-test--newest-done events) :error-kind))

(ert-deftest harness-provider-openrouter-a-policy-disabled-mid-fetch-sends-nothing ()
  "Disabling the policy while the catalogue is in flight refuses the request.
The request was prepared under an enabled policy; with the policy turned
off before the reading resolves, the completion is not sent at all --
least of all with no restriction fields, which is what reading the
variable instead of the checked policy did."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (setq harness-openrouter-test--hold-catalogue t)
          (let ((handle (harness-call 'provider/complete
                                      (plist-put (harness-openrouter-test--request session)
                                                 :on-event (lambda (e) (push e events))))))
            ;; The catalogue is in flight; the policy is turned off.
            (should (functionp (plist-get handle :cancel)))
            (should (= 1 (length harness-openrouter-test--held-catalogues)))
            (setq harness-openrouter-routing (plist-put (copy-sequence policy) :enabled nil))
            (harness-openrouter-test--answer-catalogue)
            (harness-test-wait (lambda () (harness-openrouter-test--done-events events))
                               5 "the refusal")
            (should (eq 'error (plist-get (harness-openrouter-test--newest-done events) :stop-reason)))
            (should (eq 'disabled (harness-openrouter-test--paused-kind events)))
            ;; Nothing reached the transport, and no pin was stored.
            (should-not (harness-openrouter-test--sent-completions))
            (should-not harness-openrouter-test--stored)))))))

(ert-deftest harness-provider-openrouter-a-policy-removed-mid-fetch-sends-nothing ()
  "Removing the policy while the catalogue is in flight refuses the request.
nil is the legacy pass-through for a request that was never governed; a
request already prepared under a policy is not sent unrestricted when
that policy is deleted."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e events))))
          (setq harness-openrouter-routing nil)
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait (lambda () (harness-openrouter-test--done-events events))
                             5 "the refusal")
          (should (eq 'error (plist-get (harness-openrouter-test--newest-done events) :stop-reason)))
          (should (eq 'policy-changed (harness-openrouter-test--paused-kind events)))
          (should-not (harness-openrouter-test--sent-completions))
          (should-not harness-openrouter-test--stored))))))

(ert-deftest harness-provider-openrouter-a-provider-removed-mid-fetch-is-not-chosen ()
  "A provider removed while the catalogue is in flight is never pinned.
DeepInfra is the cheaper endpoint and would be chosen; the policy no
longer names it by the time the reading resolves, so the decision is
refused and nothing is sent -- the new policy's Cohere is not silently
chosen in its place either, because the request was prepared for the
old one."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e events))))
          (setq harness-openrouter-routing
                (harness-openrouter-test-policy :providers '("Cohere")))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait (lambda () (harness-openrouter-test--done-events events))
                             5 "the refusal")
          (should (eq 'error (plist-get (harness-openrouter-test--newest-done events) :stop-reason)))
          (should (eq 'policy-changed (harness-openrouter-test--paused-kind events)))
          (should-not (harness-openrouter-test--sent-completions))
          (should-not harness-openrouter-test--stored)
          ;; And no other provider was chosen instead.
          (should-not (cl-find-if
                       (lambda (r) (string-match-p "cohere" (format "%s" (plist-get r :json))))
                       harness-openrouter-test--requests)))))))

(ert-deftest harness-provider-openrouter-a-cache-read-maximum-lowered-mid-fetch-stops-it ()
  "A cache-read maximum lowered below the API's rate while in flight stops it.
The wire's `max_price' bounds prompt and completion only, so no
request-level field could have caught this after the fact: the reading
is compared with the limits in force at dispatch, and the request is
not sent above them."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e events))))
          ;; The catalogue's cache-read rate for DeepInfra is 0.00294 per
          ;; million; the new maximum is below it.
          (setq harness-openrouter-routing
                (harness-openrouter-test-policy
                 :max-price '(:prompt 0.15 :completion 0.60 :cache-read 0.002)))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait (lambda () (harness-openrouter-test--done-events events))
                             5 "the refusal")
          (should (eq 'error (plist-get (harness-openrouter-test--newest-done events) :stop-reason)))
          (should (eq 'policy-changed (harness-openrouter-test--paused-kind events)))
          (should-not (harness-openrouter-test--sent-completions)))))))

(ert-deftest harness-provider-openrouter-a-model-change-mid-fetch-sends-nothing ()
  "A policy pointed at another checkpoint while in flight sends nothing.
The catalogue was read for the model the policy named; it is not a
reading of another model, and the endpoint it lists is not one the new
policy vetted."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e events))))
          (setq harness-openrouter-routing
                (harness-openrouter-test-policy :model "deepseek/deepseek-v4.1-flash"))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait (lambda () (harness-openrouter-test--done-events events))
                             5 "the refusal")
          (should (eq 'error (plist-get (harness-openrouter-test--newest-done events) :stop-reason)))
          (should (eq 'policy-changed (harness-openrouter-test--paused-kind events)))
          (should-not (harness-openrouter-test--sent-completions))
          (should-not harness-openrouter-test--stored))))))

(ert-deftest harness-provider-openrouter-a-valid-policy-replaced-mid-fetch-refuses ()
  "A valid replacement policy during the wait refuses the prepared request.
The operator has replaced the authority the request was prepared under;
sending the old request would send under a policy already gone, and
choosing again under the new one would be a fallback to a provider the
old policy did not authorise.  The next request is prepared afresh."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e events))))
          (setq harness-openrouter-routing
                (harness-openrouter-test-policy
                 :max-price '(:prompt 0.20 :completion 0.80 :cache-read 0.005)))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait (lambda () (harness-openrouter-test--done-events events))
                             5 "the refusal")
          (should (eq 'error (plist-get (harness-openrouter-test--newest-done events) :stop-reason)))
          (should (eq 'policy-changed (harness-openrouter-test--paused-kind events)))
          (should (string-match-p ":max-price" (plist-get (harness-openrouter-test--newest-done events) :error)))
          (should-not (harness-openrouter-test--sent-completions)))))))

(ert-deftest harness-provider-openrouter-an-unchanged-policy-is-not-a-change ()
  "An equal policy during the wait is not a change, and the request goes out.
Only a field that decides a request makes it a different authority, and
an equal replacement carries all the restriction fields: the pin, no
fallback, the privacy controls, the tier, the session and the maximum.
The catalogue had to be read before anything could be chosen, yet the
restrictions are on the request that was sent -- not on nothing."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e events))))
          ;; An equal policy, freshly built: nothing that decides changes.
          (setq harness-openrouter-routing (harness-openrouter-test-policy))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait (lambda () (harness-openrouter-test--done-events events))
                             5 "the answer")
          (should (eq 'end-turn (plist-get (harness-openrouter-test--newest-done events) :stop-reason)))
          (let* ((sent (car (harness-openrouter-test--sent-completions)))
                 (body (plist-get sent :json))
                 (provider (plist-get body :provider))
                 (max-price (plist-get provider :max_price)))
            (should sent)
            (should (equal '("deepinfra/fp8") (append (plist-get provider :only) nil)))
            (should (equal '("deepinfra/fp8") (append (plist-get provider :order) nil)))
            (should (eq :false (plist-get provider :allow_fallbacks)))
            (should (eq t (plist-get provider :require_parameters)))
            (should (equal "deny" (plist-get provider :data_collection)))
            (should (eq t (plist-get provider :zdr)))
            (should (equal "default" (plist-get body :service_tier)))
            (should (equal "s-new" (plist-get body :session_id)))
            (should (harness-openrouter-test--approx 0.15 (plist-get max-price :prompt)))
            (should (harness-openrouter-test--approx 0.60 (plist-get max-price :completion)))
            (should (assoc "X-OpenRouter-Metadata" (plist-get sent :headers)))
            ;; The policy sets no output limit: a request that named none
            ;; asks for none, and the provider's own default applies, as
            ;; it does for every other provider of the harness.
            (should-not (plist-member body :max_tokens))))))))

(ert-deftest harness-provider-openrouter-a-refused-mid-fetch-request-is-retried-afresh ()
  "A request refused for a mid-flight policy change does not wedge the session.
The next request is prepared under the policy in force, reads the
catalogue again, and pins what that policy allows -- so a refusal is a
stop for one request, not a session that can never send."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (first-events nil)
         (second-events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--catalogue-response)
                  (harness-openrouter-test--completion-response))
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e first-events))))
          (setq harness-openrouter-routing
                (harness-openrouter-test-policy :providers '("Cohere")))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait (lambda () (harness-openrouter-test--done-events first-events))
                             5 "the refusal")
          (should (eq 'policy-changed (harness-openrouter-test--paused-kind first-events)))
          (should-not (harness-openrouter-test--sent-completions))
          ;; The next request is prepared under the new policy: the
          ;; catalogue is read again (from the fake's canned response now)
          ;; and Cohere -- the only provider the new policy names -- is
          ;; pinned and sent.
          (setq harness-openrouter-test--hold-catalogue nil)
          (setq harness-openrouter-test--requests nil)
          (setq harness-openrouter-test--responses
                (list (harness-openrouter-test--catalogue-response)
                      (harness-openrouter-test--answer-from "Cohere")))
          (setq second-events (harness-openrouter-test--run
                               (harness-openrouter-test--request session)))
          (should (eq 'end-turn (plist-get (harness-openrouter-test--newest-done second-events)
                                           :stop-reason)))
          (should (= 1 (length (harness-openrouter-test--sent-completions))))
          (should (equal "cohere/fp8" (plist-get harness-openrouter-test--stored :slug)))
          (let ((provider (plist-get (plist-get (car (harness-openrouter-test--sent-completions))
                                                :json)
                                     :provider)))
            (should (equal '("cohere/fp8") (append (plist-get provider :only) nil)))
            (should (eq :false (plist-get provider :allow_fallbacks)))))))))

;;;; P1: the same, for a pinned session whose reading is refreshed

(ert-deftest harness-provider-openrouter-a-stale-pin-refuses-a-changed-policy ()
  "A pinned session whose reading is refreshed stops if the policy changed.
The session's pin is unchanged; the authority that may send it is not.
The refreshed reading is not used to send, and the pin is not moved to
the other allowed provider."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route '(:catalogue-at 0.0)))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route)))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e events))))
          ;; The pin's reading is stale, so a fresh one is in flight.
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          (setq harness-openrouter-routing
                (harness-openrouter-test-policy :providers '("Cohere")))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait (lambda () (harness-openrouter-test--done-events events))
                             5 "the refusal")
          (should (eq 'error (plist-get (harness-openrouter-test--newest-done events) :stop-reason)))
          (should (eq 'policy-changed (harness-openrouter-test--paused-kind events)))
          (should-not (harness-openrouter-test--sent-completions))
          ;; The pin is still the one it was, not re-stored.
          (should-not harness-openrouter-test--stored))))))

(ert-deftest harness-provider-openrouter-a-stale-pin-refuses-a-disabled-policy ()
  "A pinned session whose reading is refreshed stops if the policy is disabled.
The refresh is not a reason to send: the policy that authorises the
request is read again at dispatch, and it authorises nothing."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route '(:catalogue-at 0.0)))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route)))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e events))))
          (setq harness-openrouter-routing
                (plist-put (copy-sequence policy) :enabled nil))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait (lambda () (harness-openrouter-test--done-events events))
                             5 "the refusal")
          (should (eq 'error (plist-get (harness-openrouter-test--newest-done events) :stop-reason)))
          (should (eq 'disabled (harness-openrouter-test--paused-kind events)))
          (should-not (harness-openrouter-test--sent-completions)))))))

(ert-deftest harness-provider-openrouter-a-fresh-pin-refuses-a-policy-disabled-before-dispatch ()
  "Even a fresh pin does not send once the policy is disabled.
No catalogue read separates preparation from dispatch here: the whole
check runs immediately before the body is built, so the change is seen
and the request is refused rather than sent with its restrictions."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route)))
         (events nil)
         ;; Not `real': the session fixture binds that name to the bus.
         (real-dispatch (symbol-function 'harness-openrouter--dispatch)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          ;; The policy is turned off after the dispatch was authorised and
          ;; before its check runs: exactly the window a synchronous path
          ;; has, and it must close the same way.
          (cl-letf (((symbol-function 'harness-openrouter--dispatch)
                     (lambda (snapshot request on-event)
                       (setq harness-openrouter-routing
                             (plist-put (copy-sequence policy) :enabled nil))
                       (funcall real-dispatch snapshot request on-event))))
            (setq events (harness-openrouter-test--run
                          (harness-openrouter-test--request session))))
          (should (eq 'error (plist-get (harness-openrouter-test--newest-done events) :stop-reason)))
          (should (eq 'disabled (harness-openrouter-test--paused-kind events)))
          (should-not (harness-openrouter-test--sent-completions)))))))

(ert-deftest harness-provider-openrouter-authority-snapshot-owns-its-strings ()
  "Destructive source edits cannot change a dispatched authority snapshot."
  (let* ((source (list :policy (list :providers (list (copy-sequence "DeepInfra")))
                       :route (list :slug (copy-sequence "deepinfra/fp8"))))
         (snapshot (harness-openrouter--copy-authority source)))
    (aset (car (plist-get (plist-get source :policy) :providers)) 0 ?X)
    (aset (plist-get (plist-get source :route) :slug) 0 ?X)
    (should (equal (car (plist-get (plist-get snapshot :policy) :providers)) "DeepInfra"))
    (should (equal (plist-get (plist-get snapshot :route) :slug) "deepinfra/fp8"))))

(ert-deftest harness-provider-openrouter-overlapping-uncounted-sends-own-their-request ()
  "A reused uncounted request cannot overwrite an earlier send's snapshot."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route))
         (request (append (harness-openrouter-test--request)
                          (list :ephemeral t :openrouter-route nil :openrouter-policy nil)))
         (sent nil))
    (harness-openrouter-test-with-policy policy
      (cl-letf (((symbol-function 'harness-retry-send)
                 (lambda (req) (list :request req)))
                ((symbol-function 'harness-retry-authorise)
                 (lambda (req _authority) req))
                ((symbol-function 'harness-openai--complete)
                 (lambda (_endpoint req) (push req sent) nil)))
        (harness-openrouter--dispatch (list :policy policy :route route) request #'ignore)
        (setq harness-openrouter-routing (copy-tree policy))
        (setf (plist-get (plist-get harness-openrouter-routing :max-price) :prompt) 0.25)
        (harness-openrouter--dispatch (list :policy harness-openrouter-routing :route route)
                                      request #'ignore)
        (should (= 2 (length sent)))
        (should-not (eq (car sent) (cadr sent)))
        (should-not (plist-get request :openrouter-policy))
        (should (= 0.15 (plist-get (plist-get (plist-get (cadr sent) :openrouter-policy)
                                               :max-price) :prompt)))
        (should (= 0.25 (plist-get (plist-get (plist-get (car sent) :openrouter-policy)
                                               :max-price) :prompt)))))))

(ert-deftest harness-provider-openrouter-delayed-headers-keep-the-sent-policy ()
  "Delayed response headers retain the sent policy and expose HTTP errors.
Rebuilding the replay body after dispatch must not depend on a dynamic
binding which has ended, or a policy or pin edited since the send."
  (dolist (status '(200 400 429))
    (let* ((policy (harness-openrouter-test-policy))
           (route (plist-put (harness-openrouter-test--route) :structured-outputs t))
           (session (harness-openrouter-test--session
                     "s-delayed-headers" (list :openrouter-route route)))
           (events nil)
           (kept nil))
      (harness-openrouter-test-with-policy policy
        (harness-openrouter-test-with-session session
          (harness-openrouter-test-with-fake nil
            (setq harness-openrouter-test--hold '("chat/completions"))
            ;; Install the replay seam's keep hook: without replay loaded
            ;; production skips frozen-keep, which hid this bug in tests.
            (cl-letf (((symbol-function 'harness-replay-route)
                       (lambda (_request _endpoint) "test-route"))
                      ((symbol-function 'harness-replay-seam-keep)
                       (lambda (_request _model _route body) (setq kept body))))
              (harness-call 'provider/complete
                            (plist-put (plist-put (harness-openrouter-test--request session)
                                                  :response-schema '(:type "object"))
                                       :on-event (lambda (e) (push e events))))
              (harness-test-wait #'harness-openrouter-test--sent-completions 5 "dispatch")
              (let* ((sent (car (harness-openrouter-test--sent-completions)))
                     (args (plist-get sent :args)))
                (should sent)
                (should-not harness-openrouter--sending)
                ;; Destructive edits must not change the snapshot either.
                (setf (plist-get (plist-get policy :max-price) :prompt) 99)
                (setf (plist-get route :slug) "other/provider")
                (setq harness-openrouter-routing nil)
                (funcall (plist-get args :on-headers) status nil)
                (should (plist-get kept :response_format))
                (should (equal (harness-json-encode kept) (plist-get sent :body)))
                (should (equal (plist-get kept :service_tier) "default"))
                (should (equal (plist-get kept :session_id) "s-delayed-headers"))
                (if (>= status 400)
                    (progn
                      (funcall (plist-get args :on-chunk)
                               "{\"error\":{\"message\":\"upstream quota exhausted\"}}")
                      (funcall (plist-get args :callback) status nil "" nil)
                      (let ((done (harness-openrouter-test--newest-done events)))
                        (should (eq (plist-get done :stop-reason) 'error))
                        (should (string-match-p (format "HTTP %s: upstream quota exhausted" status)
                                                (plist-get done :error)))))
                  (funcall (plist-get args :on-chunk)
                           (harness-openrouter-test--sse
                            `(:model ,harness-openrouter-test-model :provider "DeepInfra"
                              :choices ((:index 0 :delta (:content "ok") :finish_reason "stop")))))
                  (funcall (plist-get args :callback) 200 nil "" nil)
                  (should (eq 'end-turn
                              (plist-get (harness-openrouter-test--newest-done events)
                                         :stop-reason))))))))))))

;;;; P2: one catalogue reading, shared by concurrent callers

(ert-deftest harness-provider-openrouter-concurrent-callers-share-one-reading ()
  "Two callers waiting on one catalogue fetch get the same reading shape.
The first and the second both get `:at' and `:endpoints', with one
timestamp and one endpoint list; only one fetch was made.  Before, the
second caller got the bare endpoint records and failed its checks for
no reason."
  (let ((policy (harness-openrouter-test-policy))
        (readings nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons (harness-openrouter-test--catalogue-url-regexp)
                      `(:body ,(harness-openrouter-test--catalogue-json))))
        (setq harness-openrouter-test--hold-catalogue t)
        (let ((first (harness-openrouter--choose-now policy))
              (second (harness-openrouter--choose-now policy)))
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          (harness-openrouter-test--answer-catalogue)
          (setq readings (list (harness-await first 5) (harness-await second 5)))
          ;; One fetch, not two.
          (should (= 1 (length (cl-remove-if-not
                                (lambda (r) (string-match-p "/endpoints" (plist-get r :url)))
                                harness-openrouter-test--requests))))
          (dolist (reading readings)
            (should (numberp (plist-get reading :at)))
            (should (listp (plist-get reading :endpoints)))
            (should (= 2 (length (plist-get reading :endpoints)))))
          ;; The same reading, not two equal ones.
          (should (equal (plist-get (car readings) :at) (plist-get (cadr readings) :at)))
          (should (eq (car readings) (cadr readings))))))))

(ert-deftest harness-provider-openrouter-a-failed-shared-fetch-cleans-up-and-retries ()
  "A failed shared fetch rejects both callers, and a later call fetches again.
The in-flight promise is not left behind settled, so the next attempt
is a new fetch, and it succeeds.  The wait a step may spend on an outage
is off here (`harness-openrouter-catalogue-wait' 0): what is under test
is the fetch's own bookkeeping and the read an outage costs, not the
wait (`harness-provider-openrouter-a-transient-outage-is-waited-out')."
  (let ((policy (harness-openrouter-test-policy))
        (harness-openrouter-catalogue-wait 0)
        (errors nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons (harness-openrouter-test--catalogue-url-regexp)
                      `(:body ,(harness-openrouter-test--catalogue-json))))
        (setq harness-openrouter-test--hold-catalogue t)
        (let ((first (harness-openrouter--choose-now policy))
              (second (harness-openrouter--choose-now policy)))
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          (should (= 0 (hash-table-count harness-openrouter--catalogue)))
          (harness-openrouter-test--fail-catalogue)
          (dolist (promise (list first second))
            (let ((err (condition-case err (harness-await promise 5)
                         (error err))))
              (push err errors)))
          (should (cl-every #'consp errors))
          ;; The in-flight entry is cleaned up, so the next call fetches.
          (should (= 0 (hash-table-count harness-openrouter--fetching)))
          (should (= 0 (hash-table-count harness-openrouter--catalogue)))
          ;; The episode is live, so a caller asking now is answered the
          ;; failure already found rather than adding a read to the outage:
          ;; an outage costs one failed read, not one per caller
          ;; (`harness-openrouter--reading-for').  The bounded background
          ;; re-reads are the only ones that read again.
          (should-error (harness-await (harness-openrouter--choose-now policy) 5))
          (should (= 0 (length harness-openrouter-test--held-catalogues)))
          (should (= 1 (harness-openrouter-test--catalogue-reads)))
          ;; A background re-read that succeeds ends the episode, and the
          ;; next lookup is answered from the reading it made.
          (setq harness-openrouter-test--hold-catalogue nil)
          (harness-openrouter--catalogue-retry harness-openrouter-test-model)
          (harness-test-wait
           (lambda () (zerop (hash-table-count harness-openrouter--fetching)))
           5 "the background re-read to settle")
          (let ((reading (harness-await (harness-openrouter--choose-now policy) 5)))
            (should (numberp (plist-get reading :at)))
            (should (= 2 (length (plist-get reading :endpoints))))
            (should (= 1 (hash-table-count harness-openrouter--catalogue)))))))))

(ert-deftest harness-provider-openrouter-cancelling-one-consumer-keeps-the-reading ()
  "Cancelling one session's wait does not cancel another's catalogue reading.
Two sessions on one model share the fetch; the first is cancelled before
the reading resolves.  The second still gets its reading and is pinned
and sent, and cancelling the first sent nothing for it."
  (let* ((policy (harness-openrouter-test-policy))
         (first-session (harness-openrouter-test--session "s-first"))
         (second-session (harness-openrouter-test--session "s-second"))
         (first-events nil)
         (second-events nil)
         (handle nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session first-session
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (setq harness-openrouter-test--hold-catalogue t)
          (setq handle (harness-call 'provider/complete
                                     (plist-put (harness-openrouter-test--request first-session)
                                                :on-event (lambda (e) (push e first-events)))))
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          ;; A second session asks for the same model while it is in flight.
          (harness-openrouter-test-with-session second-session
            (harness-call 'provider/complete
                          (plist-put (harness-openrouter-test--request second-session)
                                     :on-event (lambda (e) (push e second-events))))
            ;; Still one fetch: the second wait shares it.
            (should (= 1 (length harness-openrouter-test--held-catalogues)))
            ;; The first session's wait is cancelled, not the reading.
            (funcall (plist-get handle :cancel))
            (harness-openrouter-test--answer-catalogue)
            (harness-test-wait (lambda () (harness-openrouter-test--done-events second-events))
                               5 "the second session's answer")
            (should (eq 'end-turn (plist-get (harness-openrouter-test--newest-done second-events) :stop-reason)))
            (should-not (cl-find-if (lambda (e) (eq (plist-get e :type) 'done)) first-events))
            ;; Exactly one completion was sent, for the second session.
            (should (= 1 (length (harness-openrouter-test--sent-completions)))
                    )))))))

;;;; Which pool a pinned request belongs to

(ert-deftest harness-provider-openrouter-each-pinned-endpoint-has-its-own-pool ()
  "Two sessions pinned to two upstream endpoints are two pools of one account.
The pool is the exact endpoint the session is pinned to, so a limit
DeepInfra answers holds the work bound for DeepInfra and not the work
bound for Cohere; the account is OpenRouter itself, which is what a limit
OpenRouter imposed is about.  Every part of the key is a name OpenRouter
publishes, and no credential is in it."
  (let* ((policy (harness-openrouter-test-policy))
         (deepinfra (harness-openrouter-test--session
                     "s-deepinfra"
                     (list :openrouter-route
                           (harness-openrouter-test--route
                            '(:slug "deepinfra/fp8" :provider "DeepInfra")))))
         (cohere (harness-openrouter-test--session
                  "s-cohere"
                  (list :openrouter-route
                        (harness-openrouter-test--route
                         '(:slug "cohere/fp8" :provider "Cohere"
                           :prompt 0.15 :completion 0.5 :cache-read 0.003
                           :discount 0))))))
    (harness-openrouter-test-with-policy policy
      (let* ((first (harness-method/provider/admission-identity
                     (harness-openrouter-test--request deepinfra)))
             (second (harness-method/provider/admission-identity
                      (harness-openrouter-test--request cohere))))
        (should (equal "openrouter" (plist-get first :account)))
        (should (equal "openrouter/deepinfra/fp8" (plist-get first :pool)))
        (should (equal "openrouter" (plist-get second :account)))
        (should (equal "openrouter/cohere/fp8" (plist-get second :pool)))
        ;; Two pools of one account: a limit on one is not the other's.
        (should-not (equal (plist-get first :pool) (plist-get second :pool)))
        ;; No credential, and no request's body, is in a key.
        (dolist (identity (list first second))
          (let ((pool (plist-get identity :pool)))
            (should-not (string-match-p "sk-\\|Bearer\\|api.key" pool))
            (should-not (string-match-p "hi" pool))))))))

(ert-deftest harness-provider-openrouter-a-repeat-keeps-the-pool-it-was-sent-to ()
  "A request being retried belongs to the endpoint it was authorised for.
The session may have been switched since; the repeat is the request it
repeats, so it waits for the pool of the endpoint it will actually be
sent to, not for the pool of a pin chosen afterwards."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-1"))
         (repeat (harness-openrouter-test--request session)))
    (harness-openrouter-test-with-policy policy
      ;; What `harness-openrouter--dispatch' records on a request it sent:
      ;; the authority travels on the request's retry state, which is the
      ;; request's own and is read back from it.
      (let ((state (make-harness-retry--request)))
        (setf (harness-retry--request-count state) 1
              (harness-retry--request-since state) (float-time))
        (setq repeat (harness-retry-authorise
                      (harness-retry-attach repeat state)
                      (list :policy policy
                            :route (harness-openrouter-test--route
                                    '(:slug "cohere/fp8" :provider "Cohere"))))))
      (should (equal "openrouter/cohere/fp8"
                     (plist-get (harness-method/provider/admission-identity repeat) :pool)))
      ;; The same request without the record is unpinned, and belongs to
      ;; the account until a pin is chosen for it.
      (should (equal "openrouter"
                     (plist-get (harness-method/provider/admission-identity
                                 (harness-openrouter-test--request session))
                                :pool))))))

(ert-deftest harness-provider-openrouter-a-pinned-limit-is-that-endpoints ()
  "A 429 that names the upstream endpoint is that endpoint's limit.
The failure's own fields say which endpoint declined, so the pool that
rests is the pinned one; the other endpoint of the same account keeps
sending."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session
                   "s-1" (list :openrouter-route
                                 (harness-openrouter-test--route)))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons "chat/completions"
                        (harness-openrouter-test--chain-http
                         429 (harness-json-encode
                              (list :error
                                    (list :code 429 :message "rate limited"
                                          :metadata (list :error_type "rate_limit_exceeded"
                                                          :provider_name "DeepInfra")))))))
          (let* ((request (harness-openrouter-test--request session))
                 (events nil))
            (harness-call 'provider/complete
                          (plist-put request :on-event (lambda (e) (push e events))))
            (harness-test-wait (lambda () (harness-openrouter-test--done-events events))
                               5 "the refusal")
            (let ((done (harness-openrouter-test--newest-done events)))
              (should (eq 'rate-limit (plist-get done :error-kind)))
              ;; The endpoint that declined is named, so the pool is it.
              (should (eq 'pool (plist-get done :limit-scope))))))))))

(ert-deftest harness-provider-openrouter-a-limit-with-no-upstream-is-the-accounts ()
  "A 429 that names no upstream endpoint is the account's limit.
OpenRouter's own limit applies to the key that sent the request, and
every endpoint of that account is held by it; resting only the pinned
one would keep sending into a limit that is not about it."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session
                   "s-1" (list :openrouter-route
                                 (harness-openrouter-test--route)))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons "chat/completions"
                        (harness-openrouter-test--chain-http
                         429 (harness-json-encode
                              (list :error (list :code 429 :message "Rate limit exceeded"))))))
          (let* ((request (harness-openrouter-test--request session))
                 (events nil))
            (harness-call 'provider/complete
                          (plist-put request :on-event (lambda (e) (push e events))))
            (harness-test-wait (lambda () (harness-openrouter-test--done-events events))
                               5 "the refusal")
            (let ((done (harness-openrouter-test--newest-done events)))
              (should (eq 'rate-limit (plist-get done :error-kind)))
              (should (eq 'account (plist-get done :limit-scope))))))))))

(ert-deftest harness-provider-openrouter-an-ordinary-request-is-not-given-a-scope ()
  "A request this module did not route keeps the generic reading.
Without a policy there is no pin and nothing to split, so no limit scope
is claimed on its failure: an ordinary provider's pool rests on its own
provider's answer alone."
  (let* ((session (harness-openrouter-test--session "s-1")))
    (harness-openrouter-test-with-policy nil
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons "chat/completions"
                        (harness-openrouter-test--chain-http
                         429 (harness-json-encode
                              (list :error (list :code 429 :message "rate limited"))))))
          (let ((request (harness-openrouter-test--request session))
                (events nil))
            (harness-call 'provider/complete
                          (plist-put request :on-event (lambda (e) (push e events))))
            (harness-test-wait (lambda () (harness-openrouter-test--done-events events))
                               5 "the refusal")
            (let ((done (harness-openrouter-test--newest-done events)))
              (should (eq 'rate-limit (plist-get done :error-kind)))
              (should-not (plist-get done :limit-scope)))))))))


;;;; The catalogue is the model's, and an outage does not stop a session
;;
;; These are the behaviours the reported pause was about: a session stopped
;; because a catalogue read failed while a perfectly usable reading of the
;; same model was already in the process.  The reading is the model's, not a
;; session's, and these tests hold it to that -- without ever letting a
;; reading the policy does not admit decide a price.

(ert-deftest harness-provider-openrouter-a-new-session-reuses-a-recent-reading ()
  "A second session of the same model spends no catalogue request.
The first session's reading is the model's, and a reading younger than
`harness-openrouter-catalogue-ttl' answers the next session as it is.  The
reported failure was the opposite: every new session forced a fetch, so a
momentary failure stopped a session that had nothing to learn."
  (let ((policy (harness-openrouter-test-policy))
        (first (harness-openrouter-test--session "s-first"))
        (second (harness-openrouter-test--session "s-second")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--catalogue-response)
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session first
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request first))))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))))
        (should (= 1 (harness-openrouter-test--catalogue-reads)))
        ;; The second session, started beside it, is answered from the same
        ;; reading: no second request, and the same endpoint pinned.
        (harness-openrouter-test-with-session second
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request second))))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
            (should (= 1 (harness-openrouter-test--catalogue-reads)))
            (should (equal "deepinfra/fp8" (plist-get harness-openrouter-test--stored :slug)))
            ;; A reused reading is not a degraded one: nothing is said about
            ;; a failed refresh that did not happen.
            (should-not (cl-find-if (lambda (h) (string-match-p "degraded" h))
                                    harness-openrouter-test--hints))))))))

(ert-deftest harness-provider-openrouter-a-burst-of-new-sessions-reads-once ()
  "Five sessions started together share one catalogue read.
They are started while the fetch is genuinely in flight, so the assertion
is about coalescing as well as about the reading that follows it: one
request, five pins, five sends."
  (let ((policy (harness-openrouter-test-policy))
        (sessions (mapcar (lambda (n) (harness-openrouter-test--session (format "s-%d" n)))
                          (number-sequence 1 5)))
        (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-sessions sessions
          (setq harness-openrouter-test--hold-catalogue t)
          (dolist (session sessions)
            (harness-call 'provider/complete
                          (plist-put (harness-openrouter-test--request session)
                                     :on-event (lambda (e) (push e events)))))
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait (lambda () (= 5 (length (harness-openrouter-test--done-events events))))
                             5 "five answers")
          (should (= 1 (harness-openrouter-test--catalogue-reads)))
          (ert-info ((format "events: %S" events))
            (should (= 5 (length (harness-openrouter-test--sent-completions))))))))))

(ert-deftest harness-provider-openrouter-a-failed-refresh-uses-the-last-reading ()
  "A refresh that fails serves the last reading, while the policy admits it.
The reading is two minutes old and the policy allows five: past the shared
refresh interval, so the first dispatch is served it while the catalogue
is read again behind it.  That read answers a 503, and the next dispatch
still runs -- on the older reading, which the hint and the degraded event
name as such, with what the refresh said.  Before, the 503 stopped it."
  (let* ((policy (harness-openrouter-test-policy :freshness 3600))
         (first (harness-openrouter-test--session "s-first"))
         (second (harness-openrouter-test--session "s-second")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons (harness-openrouter-test--catalogue-url-regexp)
                      '(:error (http-error 503 "upstream unavailable")))
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session first
          (harness-openrouter-test--seed-reading 1000)
          ;; Served at once, and the refresh starts behind the dispatch.
          (let ((events (harness-openrouter-test--run
                         (harness-openrouter-test--request first))))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason))))
          (harness-test-wait
           (lambda () (zerop (hash-table-count harness-openrouter--fetching)))
           5 "the refresh to settle"))
        (should (= 1 (harness-openrouter-test--catalogue-reads)))
        (harness-openrouter-test-with-session second
          (let ((events (harness-openrouter-test--run
                         (harness-openrouter-test--request second))))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
            ;; No read of its own: the episode's re-reads own the next one.
            (should (= 1 (harness-openrouter-test--catalogue-reads)))
            (should (= 2 (length (harness-openrouter-test--sent-completions))))
            ;; The hint says the reading is an older one, and says how old.
            (should (cl-find-if
                     (lambda (h) (string-match-p
                                  "using the reading 1000 s old, inside the policy's freshness bound" h))
                     harness-openrouter-test--hints))
            ;; The dispatch says what failed, once, and does not pause.
            (should (= 1 (length (harness-openrouter-test--degraded-notes))))
            (should (string-match-p "HTTP 503: upstream unavailable"
                                    (car (harness-openrouter-test--degraded-notes))))
            (should-not (cl-find-if (lambda (h) (string-match-p "paused" h))
                                    harness-openrouter-test--hints))))))))


(ert-deftest harness-provider-openrouter-a-reading-inside-the-interval-spends-no-read ()
  "A reading younger than the shared interval is answered with no request.
Two sessions of the same model, one after the other: the second spends
nothing, because the reading the first made is inside
`harness-openrouter-catalogue-ttl'.  Nothing about the second session's
send is degraded either -- no refresh was owed, so none failed."
  (let ((policy (harness-openrouter-test-policy))
        (first (harness-openrouter-test--session "s-first"))
        (second (harness-openrouter-test--session "s-second")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session first
          (harness-openrouter-test--seed-reading 5)
          (let ((events (harness-openrouter-test--run
                         (harness-openrouter-test--request first))))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))))
        (harness-openrouter-test-with-session second
          (let ((events (harness-openrouter-test--run
                         (harness-openrouter-test--request second))))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))))
        (should (= 0 (harness-openrouter-test--catalogue-reads)))
        (should-not (harness-openrouter-test--degraded-notes))
        (should-not (cl-find-if (lambda (h) (string-match-p "revalidating" h))
                                harness-openrouter-test--hints))))))

(ert-deftest harness-provider-openrouter-a-judge-within-the-interval-spends-no-read ()
  "A permission judge started beside a session shares the session's reading.
The judge is a one-off call (`:ephemeral'), and its budget is about the
answer it asks for.  Within the interval it neither waits for a catalogue
nor spends a request: it is answered from the reading the session just
made, and its own answer goes out."
  (let ((policy (harness-openrouter-test-policy))
        (session (harness-openrouter-test--session "s-first"))
        (judge (harness-openrouter-test--session "s-judge")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          (harness-openrouter-test--seed-reading 5)
          (harness-openrouter-test--run (harness-openrouter-test--request session)))
        (should (= 0 (harness-openrouter-test--catalogue-reads)))
        (harness-openrouter-test-with-session judge
          (let* ((request (plist-put (harness-openrouter-test--request judge)
                                     :ephemeral t))
                 (events (harness-openrouter-test--run request)))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))))
        (should (= 0 (harness-openrouter-test--catalogue-reads)))
        (should (= 2 (length (harness-openrouter-test--sent-completions))))))))

(ert-deftest harness-provider-openrouter-many-sessions-and-judges-share-one-read ()
  "Sessions and judges started together within the interval share one fetch.
Five sessions and three one-off calls are started while a single
catalogue fetch is genuinely in flight, then the fetch is answered.  All
eight are answered, and the whole burst -- sessions and judges alike --
spent one catalogue request, not eight.  A judge that started a read of
its own would be the reported failure in its own right: the catalogue is
read once per the shared interval, by whoever gets there first."
  (let* ((policy (harness-openrouter-test-policy))
         (sessions (mapcar (lambda (n) (harness-openrouter-test--session (format "s-%d" n)))
                           (number-sequence 1 5)))
         (judges (mapcar (lambda (n) (harness-openrouter-test--session (format "j-%d" n)))
                         (number-sequence 1 3)))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-sessions sessions
          (setq harness-openrouter-test--hold-catalogue t)
          (dolist (session (append sessions judges))
            (harness-call 'provider/complete
                          (plist-put (plist-put (harness-openrouter-test--request session)
                                                :on-event (lambda (e) (push e events)))
                                     :ephemeral (and (memq session judges) t))))
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait
           (lambda () (= 8 (length (harness-openrouter-test--done-events events))))
           10 "eight answers, sessions and judges")
          (should (= 1 (harness-openrouter-test--catalogue-reads)))
          (should (= 8 (length (harness-openrouter-test--sent-completions)))))))))

(ert-deftest harness-provider-openrouter-a-reading-past-the-interval-is-served-while-revalidated ()
  "A reading past the interval is answered at once, and revalidated behind it.
The policy allows an hour and the reading is a quarter of an hour old: it
is past the shared refresh interval but well inside the bound the
operator set for a price decision, so the session does not wait for a
read.  It sends on the reading in hand, the read is started behind it,
and the dispatch says the catalogue is being brought up to date."
  (let* ((policy (harness-openrouter-test-policy :freshness 3600))
         (session (harness-openrouter-test--session "s-new"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          (harness-openrouter-test--seed-reading 900)
          (setq harness-openrouter-test--hold-catalogue t)
          (setq events (harness-openrouter-test--run
                        (harness-openrouter-test--request session)))
          (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
          ;; Answered from the reading, and the shared read was started.
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          (should (= 1 (length (harness-openrouter-test--sent-completions))))
          (should (cl-find-if (lambda (h) (string-match-p "catalogue revalidating" h))
                              harness-openrouter-test--hints))
          (should-not (harness-openrouter-test--degraded-notes))
          ;; The status says what it is: being read again, and still usable.
          (let ((status (harness-openrouter-catalogue-status)))
            (should (eq 'revalidating (plist-get status :state)))
            (should (eq 'usable (plist-get status :reading))))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait
           (lambda () (eq 'fresh (plist-get (harness-openrouter-catalogue-status) :state)))
           5 "the revalidating read to settle"))))))

(ert-deftest harness-provider-openrouter-a-judge-does-not-start-a-revalidation ()
  "A one-off call past the interval is answered without starting a read.
The reading is the session's, and it is past the shared interval but
inside the policy's bound.  A judge asking now is answered from it at
once, and starts no read of its own: the catalogue is read by work that
can wait for it, never by the judge whose budget is the call it is
deciding."
  (let ((policy (harness-openrouter-test-policy :freshness 3600))
        (judge (harness-openrouter-test--session "s-judge")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session judge
          (harness-openrouter-test--seed-reading 900)
          (let* ((request (plist-put (harness-openrouter-test--request judge)
                                     :ephemeral t))
                 (events (harness-openrouter-test--run request)))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))))
        (should (= 0 (harness-openrouter-test--catalogue-reads)))))))

(ert-deftest harness-provider-openrouter-callers-past-the-interval-share-the-read ()
  "Callers past the interval share the one read that brings the reading up to date.
Two callers ask while the revalidating read is in flight: it is the same
read, so the catalogue is read once for both of them, not once each."
  (let ((policy (harness-openrouter-test-policy :freshness 3600)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--catalogue-response))
        (harness-openrouter-test--seed-reading 900)
        (setq harness-openrouter-test--hold-catalogue t)
        (let ((first (harness-openrouter--choose-now policy))
              (second (harness-openrouter--choose-now policy)))
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          (harness-openrouter-test--answer-catalogue)
          (harness-await first 5)
          (harness-await second 5)
          (should (= 1 (harness-openrouter-test--catalogue-reads))))))))

(ert-deftest harness-provider-openrouter-an-outage-costs-one-read-not-one-per-session ()
  "A second session during the same outage is answered without a new read.
The first session's reading is outside the policy's bound, so its failed
refresh pauses it; the second is started a moment later and is answered
from the failure the first one left, without spending another failing
request.  While an episode is live an ordinary lookup never adds a read:
the bounded background re-reads are the only ones.

The wait a step may spend on an outage is off here
\(`harness-openrouter-catalogue-wait' 0), so both pauses happen at once;
that a step waits instead is
`harness-provider-openrouter-a-transient-outage-is-waited-out'."
  (let* ((policy (harness-openrouter-test-policy))
         (harness-openrouter-catalogue-wait 0)
         (first (harness-openrouter-test--session "s-first"))
         (second (harness-openrouter-test--session "s-second")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons (harness-openrouter-test--catalogue-url-regexp)
                      '(:error (http-error 503 "upstream unavailable"))))
        (harness-openrouter-test-with-session first
          (harness-openrouter-test--seed-reading 3600)
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request first))))
            (should (eq 'catalogue-unavailable
                        (plist-get (car (last events)) :error-kind)))))
        (should (= 1 (harness-openrouter-test--catalogue-reads)))
        (harness-openrouter-test-with-session second
          (let ((events (harness-openrouter-test--run
                         (harness-openrouter-test--request second))))
            ;; Still one read: the episode is live, so the answer is the
            ;; same pause without another request.
            (should (= 1 (harness-openrouter-test--catalogue-reads)))
            (should (eq 'catalogue-unavailable
                        (plist-get (car (last events)) :error-kind)))
            (should-not (harness-openrouter-test--sent-completions))))))))

(ert-deftest harness-provider-openrouter-background-retries-are-a-burst-then-a-heartbeat ()
  "A failure episode retries fast at first, then slowly, and never stops.
The first `harness-openrouter-catalogue-retry-attempts' re-reads double
from `harness-openrouter-catalogue-retry-delay' up to
`harness-openrouter-catalogue-retry-max-delay'; after them the episode
keeps one slow probe at that longest delay until a read settles, so a
catalogue that was unreachable for an hour is read again by itself
instead of staying broken until a person asks.  The bound is on the
burst, not on the recovery."
  (let* ((policy (harness-openrouter-test-policy :freshness 3600))
         (harness-openrouter-catalogue-retry-attempts 2)
         (harness-openrouter-catalogue-retry-delay 5)
         (harness-openrouter-catalogue-retry-max-delay 300)
         (session (harness-openrouter-test--session "s-first")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons (harness-openrouter-test--catalogue-url-regexp)
                      '(:error (http-error 503 "upstream unavailable"))))
        (harness-openrouter-test-with-session session
          ;; Past the shared interval, so the refresh really is attempted.
          (harness-openrouter-test--seed-reading 1000)
          (harness-openrouter-test--run (harness-openrouter-test--request session))
          ;; The first failure schedules the burst's first re-read.
          (should (= 0 (plist-get (harness-openrouter-catalogue-status) :attempts)))
          (should (numberp (plist-get (harness-openrouter-catalogue-status) :next-at)))
          ;; The burst, one re-read at a time, each settling before the next.
          (dotimes (_ 3)
            (harness-openrouter--catalogue-retry harness-openrouter-test-model)
            (harness-test-wait (lambda () (zerop (hash-table-count
                                                  harness-openrouter--fetching)))
                               5 "the re-read to settle"))
          ;; Every attempt of the episode is counted, the probes included,
          ;; and the episode is still live: it has not given up.
          (should (= 3 (plist-get (harness-openrouter-catalogue-status) :attempts)))
          (should (numberp (plist-get (harness-openrouter-catalogue-status) :next-at)))
          (should (= 4 (harness-openrouter-test--catalogue-reads)))
          ;; A probe is still scheduled: the recovery is slow, not
          ;; abandoned.  The wait grows with the attempts spent and is
          ;; capped at `harness-openrouter-catalogue-retry-max-delay'.
          (let* ((episode (gethash harness-openrouter-test-model
                                   harness-openrouter--catalogue-failures))
                 (next-at (plist-get episode :next-at))
                 (wait (- next-at (float-time))))
            (should (numberp next-at))
            (should (<= 5 wait))
            (should (<= wait harness-openrouter-catalogue-retry-max-delay))
            (should (timerp (plist-get episode :timer)))))))))


(ert-deftest harness-provider-openrouter-a-degraded-reading-keeps-every-limit ()
  "An older reading still has to pass the price, provider and privacy checks.
The reading is inside the policy's freshness bound and its refresh failed,
so the session runs; what it may spend, whom it may use and what it must
not disclose are the ones the policy named, unchanged by the reuse."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons (harness-openrouter-test--catalogue-url-regexp)
                      '(:error (http-error 503 "upstream unavailable")))
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          (harness-openrouter-test--seed-reading 120)
          (harness-openrouter-test--run (harness-openrouter-test--request session))
          (let* ((sent (car (harness-openrouter-test--sent-completions)))
                 (body (plist-get sent :json))
                 (provider (plist-get body :provider)))
            (should sent)
            (should (equal '("deepinfra/fp8") (append (plist-get provider :only) nil)))
            (should (equal '("deepinfra/fp8") (append (plist-get provider :order) nil)))
            (should (eq :false (plist-get provider :allow_fallbacks)))
            (should (eq t (plist-get provider :require_parameters)))
            (should (equal "deny" (plist-get provider :data_collection)))
            (should (eq t (plist-get provider :zdr)))
            (should (harness-openrouter-test--approx
                     0.15 (plist-get (plist-get provider :max_price) :prompt)))
            (should (harness-openrouter-test--approx
                     0.60 (plist-get (plist-get provider :max_price) :completion)))
            ;; The price recorded on the pin is the reading's, not a new one.
            (should (harness-openrouter-test--approx
                     0.098 (plist-get harness-openrouter-test--stored :prompt)))))))))

(ert-deftest harness-provider-openrouter-a-degraded-read-refuses-a-dearer-old-price ()
  "An older reading whose price is over the maximum refuses, as a fresh one would.
Reuse does not relax the price rule: the reading is inside the freshness
bound, so it may decide, and what it says is that the endpoint is dearer
than the maximum.  Nothing is sent and nothing is reselected."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (dearer (harness-openrouter-test--catalogue-json
                  (harness-openrouter-test--endpoint-json
                   "deepinfra/fp8" "DeepInfra"
                   :pricing '(:prompt "0.00000035" :completion "0.0000014"
                              :input_cache_read "0.0000000035" :discount 0))
                  (harness-openrouter-test--endpoint-json
                   "cohere/fp8" "Cohere"
                   :pricing '(:prompt "0.00000015" :completion "0.0000005"
                              :input_cache_read "0.000000003" :discount 0)))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons (harness-openrouter-test--catalogue-url-regexp)
                      '(:error (http-error 503 "upstream unavailable")))
                (harness-openrouter-test--answer-from "Cohere"))
        (harness-openrouter-test-with-session session
          (puthash harness-openrouter-test-model
                   (list :at (- (float-time) 120)
                         :endpoints (harness-openrouter-parse-endpoints
                                     (harness-json-parse dearer)))
                   harness-openrouter--catalogue)
          (let ((events (harness-openrouter-test--run
                         (harness-openrouter-test--request session))))
            ;; DeepInfra is now over the maximum, so Cohere is the cheaper
            ;; endpoint that fits -- the ordinary price rule, on an older
            ;; reading.  What matters here is that the reading was used and
            ;; the rule still applied: the dear endpoint was not pinned.
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
            (should (equal "cohere/fp8" (plist-get harness-openrouter-test--stored :slug)))
            (let ((provider (plist-get (plist-get (car (harness-openrouter-test--sent-completions))
                                                  :json)
                                       :provider)))
              (should (equal '("cohere/fp8") (append (plist-get provider :only) nil)))
              (should (harness-openrouter-test--approx
                       0.15 (plist-get harness-openrouter-test--stored :prompt))))))))))

(ert-deftest harness-provider-openrouter-a-failed-refresh-retries-in-the-background ()
  "A failed refresh schedules a re-read, and a good one ends the episode.
The first session's read fails; the background re-read then succeeds, and
the next session is answered from it without a read of its own.  The
episode is over, so the status says fresh rather than stale."
  (let* ((policy (harness-openrouter-test-policy :freshness 3600))
         (first (harness-openrouter-test--session "s-first"))
         (second (harness-openrouter-test--session "s-second")))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons (harness-openrouter-test--catalogue-url-regexp)
                      '(:error (http-error 503 "upstream unavailable")))
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session first
          ;; Past the shared interval, so the refresh is really attempted.
          (harness-openrouter-test--seed-reading 1000)
          (harness-openrouter-test--run (harness-openrouter-test--request first))
          (harness-test-wait
           (lambda () (zerop (hash-table-count harness-openrouter--fetching)))
           5 "the failed refresh to settle")
          (let ((status (harness-openrouter-catalogue-status)))
            (should (eq 'stale (plist-get status :state)))
            (should (string-match-p "HTTP 503" (plist-get status :error)))
            (should (numberp (plist-get status :next-at)))))
        ;; The re-read is due; the fake answers this one.
        (setq harness-openrouter-test--responses
              (list (harness-openrouter-test--catalogue-response)
                    (harness-openrouter-test--completion-response)))
        (harness-openrouter--catalogue-retry harness-openrouter-test-model)
        (should (= 2 (harness-openrouter-test--catalogue-reads)))
        (harness-test-wait (lambda () (eq 'fresh
                                          (plist-get (harness-openrouter-catalogue-status) :state)))
                           5 "the background re-read")
        (harness-openrouter-test-with-session second
          (let ((events (harness-openrouter-test--run
                         (harness-openrouter-test--request second))))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
            (should (= 2 (harness-openrouter-test--catalogue-reads)))
            (should-not (cl-find-if (lambda (h) (string-match-p "stale reading" h))
                                    harness-openrouter-test--hints))))))))

(ert-deftest harness-provider-openrouter-a-degraded-dispatch-that-is-cancelled-sends-nothing ()
  "Cancelling a dispatch on an older reading sends no completion.
The reading is served after a failed refresh, and the session is cancelled
before the send: the degraded notice is not a licence to send a request
the session no longer wants."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-new"))
         (handle nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons (harness-openrouter-test--catalogue-url-regexp)
                      '(:error (http-error 503 "upstream unavailable")))
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          ;; Past the interval, so the dispatch is served the reading and the
          ;; refresh is started behind it: the send is waiting on nothing.
          (harness-openrouter-test--seed-reading 1000)
          (setq harness-openrouter-test--hold-catalogue t)
          (setq handle (harness-call 'provider/complete
                                     (plist-put (harness-openrouter-test--request session)
                                                :on-event #'ignore)))
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          ;; Cancelled before the shared read settles: the failed refresh and
          ;; the degraded reading it would leave are no licence to send.
          (funcall (plist-get handle :cancel))
          (harness-openrouter-test--fail-catalogue (list 'http-error 503 "upstream unavailable"))
          (sit-for 0.05)
          (should-not (harness-openrouter-test--sent-completions)))))))

(ert-deftest harness-provider-openrouter-the-status-says-what-the-catalogue-is ()
  "The status reports absent, fresh, stale and expired, and never decides.
A reading inside the TTL is fresh; one whose refresh failed and is inside
the policy's bound is stale; one outside it is expired; no reading at all
is absent.  Each is what the catalogue is, not what a policy would do."
  (let ((policy (harness-openrouter-test-policy)))
    (harness-openrouter-test-with-policy policy
      (should (eq 'absent (plist-get (harness-openrouter-catalogue-status) :state)))
      (should-not (plist-get (harness-openrouter-catalogue-status) :at))
      (harness-openrouter-test--seed-reading 5)
      (let ((status (harness-openrouter-catalogue-status)))
        (should (eq 'fresh (plist-get status :state)))
        (should (= 2 (plist-get status :endpoints)))
        (should (numberp (plist-get status :age))))
      ;; A failure noted for a reading inside the bound reads as stale.
      (puthash harness-openrouter-test-model
               (list :at (float-time) :error '(http-error 503 "unavailable") :attempts 1)
               harness-openrouter--catalogue-failures)
      (should (eq 'stale (plist-get (harness-openrouter-catalogue-status) :state)))
      (should (string-match-p "HTTP 503" (plist-get (harness-openrouter-catalogue-status) :error)))
      ;; The same failure with a reading outside the bound reads as expired.
      (harness-openrouter-test--seed-reading 3600)
      (should (eq 'expired (plist-get (harness-openrouter-catalogue-status) :state)))
      ;; The status reports the shared interval it is judged against.
      (should (= harness-openrouter-catalogue-ttl
                 (plist-get (harness-openrouter-catalogue-status) :ttl)))
      (should (eq 'expired (plist-get (harness-openrouter-catalogue-status) :state))))))

(ert-deftest harness-provider-openrouter-a-reused-reading-is-not-a-switch ()
  "Reusing a reading keeps the pin, and never reselects or moves it.
A pinned session whose reading is refreshed from the shared catalogue
still sends to the same endpoint; the reading being shared does not make
the choice again."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route '(:catalogue-at 0.0)))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--catalogue-response)
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          (harness-openrouter-test--seed-reading 5)
          (let ((events (harness-openrouter-test--run (harness-openrouter-test--request session))))
            (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
            ;; The reading is recent, so no request of the session's own.
            (should (= 0 (harness-openrouter-test--catalogue-reads)))
            (should-not harness-openrouter-test--stored)
            (let ((provider (plist-get (plist-get (car (harness-openrouter-test--sent-completions))
                                                  :json)
                                       :provider)))
              (should (equal '("deepinfra/fp8") (append (plist-get provider :only) nil))))))))))

(ert-deftest harness-provider-openrouter-a-watchdog-timeout-says-it-is-one ()
  "`request timed out after 20s' is the harness's watchdog, not the server.
The transport ends a request whose curl is alive and silent with that
text, and when the response had begun the status is the last one received
-- so a stalled transfer reads as \"HTTP 200: request timed out after
20s\".  A catalogue read that ends so pauses with that reason, and the
message does not pretend the server refused anything.

It is an outage, so a step would wait for it; the wait is off here
\(`harness-openrouter-catalogue-wait' 0), because what is under test is
the wording a failure ends with -- that a step waits instead is
`harness-provider-openrouter-a-transient-outage-is-waited-out'."
  (let* ((policy (harness-openrouter-test-policy))
         (harness-openrouter-catalogue-wait 0)
         (session (harness-openrouter-test--session "s-new"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons (harness-openrouter-test--catalogue-url-regexp)
                      '(:error (http-error 200 (timeout "request timed out after 20s")))))
        (harness-openrouter-test-with-session session
          (setq events (harness-openrouter-test--run (harness-openrouter-test--request session)))
          (should (eq 'error (plist-get (car (last events)) :stop-reason)))
          (should (eq 'catalogue-unavailable (plist-get (car (last events)) :error-kind)))
          (should (equal (concat "OpenRouter routing paused: the endpoint catalogue"
                                 " could not be read: HTTP 200: request timed out after 20s")
                         (plist-get (car (last events)) :error)))
          (should-not (harness-openrouter-test--sent-completions))
          ;; It is reported as a timeout, never as a refusal by the server.
          (should-not (string-match-p "Invalid error symbol"
                                      (plist-get (car (last events)) :error))))))))

(ert-deftest harness-provider-openrouter-invalidation-forces-one-read-and-keeps-it ()
  "An explicit invalidation drops the reading and reads it again at once.
The reading is well inside the interval, so no ordinary lookup would read
at all.  The invalidation is the one path that does: it drops what was in
hand, spends exactly one request, and the reading that settles replaces
the dropped one."
  (let ((policy (harness-openrouter-test-policy))
        ;; The message a failure ends with, not the wait a step may spend
        ;; on one (`harness-provider-openrouter-a-transient-outage-is-waited-out').
        (harness-openrouter-catalogue-wait 0))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--catalogue-response))
        (harness-openrouter-test--seed-reading 5)
        (should (= 0 (harness-openrouter-test--catalogue-reads)))
        (harness-openrouter-catalogue-invalidate harness-openrouter-test-model)
        (harness-test-wait
         (lambda () (zerop (hash-table-count harness-openrouter--fetching)))
         5 "the invalidation's read to settle")
        (should (= 1 (harness-openrouter-test--catalogue-reads)))
        (should (= 1 (hash-table-count harness-openrouter--catalogue)))
        ;; The reading is the new one, and it is usable again.
        (should (< (harness-openrouter--reading-age
                    (gethash harness-openrouter-test-model
                             harness-openrouter--catalogue))
                   60))
        (should (eq 'fresh (plist-get (harness-openrouter-catalogue-status) :state)))))))

(ert-deftest harness-provider-openrouter-a-slow-read-cannot-undo-an-invalidation ()
  "A read that began before an invalidation does not overwrite what it asked for.
A read is started, and the reading it was started against is invalidated
while it is in flight: the invalidation starts its own read, which
answers first.  The older read settling late answers its own callers and
is not stored over the newer reading.
"
  (let ((policy (harness-openrouter-test-policy))
        (old nil)
        (new nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--catalogue-response))
        (harness-openrouter-test--seed-reading 5)
        (setq harness-openrouter-test--hold-catalogue t)
        ;; A read begins, as a background revalidation would.
        (setq old (harness-openrouter--reading-of harness-openrouter-test-model))
        (should (= 1 (length harness-openrouter-test--held-catalogues)))
        ;; The person invalidates while it is still in flight: a second read
        ;; is started, because the one in flight is a reading of the
        ;; catalogue that was replaced.
        (harness-openrouter-catalogue-invalidate harness-openrouter-test-model)
        (should (= 2 (length harness-openrouter-test--held-catalogues)))
        ;; The read that began before the invalidation settles first, and is
        ;; answered to its own caller -- but is not stored: it is a reading
        ;; of the catalogue that was replaced.
        (harness-openrouter-test--answer-catalogue)
        (harness-await old 5)
        (should (= 0 (hash-table-count harness-openrouter--catalogue)))
        ;; The read the invalidation asked for settles, and is stored.
        (harness-openrouter-test--answer-catalogue)
        (harness-test-wait (lambda () (= 1 (hash-table-count harness-openrouter--catalogue)))
                           5 "the invalidation's reading")
        (setq new (gethash harness-openrouter-test-model harness-openrouter--catalogue))
        (should (listp (plist-get new :endpoints)))))))

(ert-deftest harness-provider-openrouter-invalidation-does-not-reset-the-retry-bound ()
  "Invalidating during an outage does not make the re-reads unbounded.
The episode has already spent its attempts; an invalidation adds one read
and keeps the count, so the burst and heartbeat stay bounded however often
a person asks for a fresh reading."
  (let ((policy (harness-openrouter-test-policy :freshness 3600))
        (harness-openrouter-catalogue-retry-attempts 2))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (cons (harness-openrouter-test--catalogue-url-regexp)
                      '(:error (http-error 503 "upstream unavailable"))))
        (harness-openrouter-test--seed-reading 1000)
        (let ((session (harness-openrouter-test--session "s-first")))
          (harness-openrouter-test-with-session session
            (harness-openrouter-test--run (harness-openrouter-test--request session))))
        (harness-test-wait
         (lambda () (zerop (hash-table-count harness-openrouter--fetching)))
         5 "the first failure")
        (let ((spent (plist-get (harness-openrouter-catalogue-status) :attempts)))
          (harness-openrouter-catalogue-invalidate harness-openrouter-test-model)
          (harness-test-wait
           (lambda () (zerop (hash-table-count harness-openrouter--fetching)))
           5 "the invalidation's read")
          ;; The invalidation spent one read of its own, and left the
          ;; episode's count exactly where it was: it drops the reading,
          ;; never the bound, so the burst and heartbeat stay bounded
          ;; however often a person asks for a fresh reading.
          (should (= spent (plist-get (harness-openrouter-catalogue-status)
                                      :attempts)))
          (should (= 2 (harness-openrouter-test--catalogue-reads)))
          (should (<= (plist-get (harness-openrouter-catalogue-status) :attempts)
                      harness-openrouter-catalogue-retry-attempts)))))))

(ert-deftest harness-provider-openrouter-a-cold-start-reads-once-for-everyone ()
  "With no cache at all, the first read is shared and stored for the rest.
The reported first-run case: nothing in hand, so a read is needed.  Every
caller that arrives while it is in flight shares it, and the reading it
leaves answers the next caller with no request at all."
  (let* ((policy (harness-openrouter-test-policy))
         (sessions (mapcar (lambda (n) (harness-openrouter-test--session (format "s-%d" n)))
                           (number-sequence 1 3)))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-sessions sessions
          (should (eq 'absent (plist-get (harness-openrouter-catalogue-status) :state)))
          (setq harness-openrouter-test--hold-catalogue t)
          (dolist (session sessions)
            (harness-call 'provider/complete
                          (plist-put (harness-openrouter-test--request session)
                                     :on-event (lambda (e) (push e events)))))
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait
           (lambda () (= 3 (length (harness-openrouter-test--done-events events))))
           5 "three answers")
          (should (= 1 (harness-openrouter-test--catalogue-reads)))
          (should (= 1 (hash-table-count harness-openrouter--catalogue)))
          ;; A fourth caller, cold-start over, spends nothing.
          (harness-openrouter-test-with-session (harness-openrouter-test--session "s-4")
            (harness-openrouter-test--run
             (harness-openrouter-test--request (harness-openrouter-test--session "s-4"))))
          (should (= 1 (harness-openrouter-test--catalogue-reads))))))))

;;;; A one-off call does not spend its budget on the catalogue
;;
;; The reported cross-symptom: the permission judge reported
;; \"no verdict\" after 30 s, and the session's log named a catalogue
;; read that timed out.  The judge's budget is about the answer it asks
;; for; a catalogue read that stalls can take longer than the whole of
;; it (`harness-openrouter-catalogue-timeout' plus the transport's 5 s
;; watchdog), so the judge was answered \"no verdict\" for something
;; that was never about the call it was asked to decide.

(ert-deftest harness-provider-openrouter-a-judge-call-does-not-wait-out-a-stalled-catalogue ()
  "A one-off call is refused rather than spending its budget on a read.
The catalogue read is held, as a stalled one is, and the judge's request
carries `:ephemeral'.  It ends inside
`harness-openrouter-catalogue-ephemeral-wait', with the catalogue
refusal -- never by sending the call the judge was asked to decide, and
never by waiting the read out."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-judge"))
         (events nil)
         (started (float-time)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          (setq harness-openrouter-test--hold-catalogue t)
          (let ((request (harness-openrouter-test--request session)))
            (setq request (plist-put request :ephemeral t))
            (harness-call 'provider/complete
                          (plist-put request :on-event
                                     (lambda (e) (push e events))))
            (should (= 1 (length harness-openrouter-test--held-catalogues)))
            (harness-test-wait
             (lambda () (harness-openrouter-test--done-events events))
             (+ harness-openrouter-catalogue-ephemeral-wait 5)
             "the one-off call to give up on the catalogue")
            (should (< (- (float-time) started)
                       (+ harness-openrouter-catalogue-ephemeral-wait 5)))
            (let ((done (car (last events))))
              (should (eq 'error (plist-get done :stop-reason)))
              (should (eq 'catalogue-unavailable (plist-get done :error-kind)))
              (should (string-match-p "still being read"
                                      (plist-get done :error))))
            ;; Nothing was sent to the endpoint the judge would have judged,
            ;; and nothing was pinned: a refusal is not a permission.
            (should-not (harness-openrouter-test--sent-completions))
            (should-not harness-openrouter-test--stored)
            ;; The read carries on, so the next caller is answered.
            (harness-openrouter-test--answer-catalogue)
            (harness-test-wait
             (lambda () (zerop (hash-table-count harness-openrouter--fetching)))
             5 "the shared read to settle")))))))

(ert-deftest harness-provider-openrouter-a-step-still-waits-for-the-catalogue ()
  "A step of a turn waits for the catalogue, as it always did.
The one-off wait is for the harness's own small calls; a request
without `:ephemeral' is a step, its catalogue read is part of preparing
it, and it is answered from the reading when the read settles -- however
long that takes, within the transport's own bounds."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-step"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e events))))
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          ;; Held past the one-off wait: a step does not give up.
          (sit-for (+ harness-openrouter-catalogue-ephemeral-wait 0.5))
          (should-not (harness-openrouter-test--done-events events))
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait
           (lambda () (harness-openrouter-test--done-events events))
           5 "the step's answer")
          (should (eq 'end-turn (plist-get (harness-openrouter-test--newest-done events)
                                           :stop-reason))))))))

;;;; A catalogue outage is waited out, not turned into a failure

(defun harness-openrouter-test--outage-response ()
  "Return the fake response of a catalogue read that timed out, as curl 28 is.
This is the failure that stopped nine tasks on 2026-11-17: the transport
received a 200, the transfer stalled, and the harness's own watchdog
ended it."
  (cons (harness-openrouter-test--catalogue-url-regexp)
        '(:error (http-error 200 (timeout "request timed out after 20s")))))

(defun harness-openrouter-test--refusal-response (&optional status)
  "Return the fake response of a catalogue the server refused, STATUS or 401."
  (cons (harness-openrouter-test--catalogue-url-regexp)
        `(:body ,(harness-json-encode
                  (list :error (list :code (or status 401)
                                     :message "No auth credentials found"))))))

(ert-deftest harness-provider-openrouter-a-transient-outage-is-waited-out ()
  "A step with no reading waits for an outage, then sends on the reading.
This is the reported failure: the shared catalogue read timed out with
nothing inside the policy's freshness bound, and every session ended with
`catalogue-unavailable'.  A step now waits for the episode's own bounded
re-read instead, and the reading that settles is what its request is
checked against -- the pin, the price, the provider and the privacy
fields, exactly as any dispatch.  Nothing is decided from the failure, and
no request is sent before a reading is back."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-waits"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--catalogue-response)
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e events))))
          ;; The first read fails as the live one did: a stalled transfer.
          (harness-openrouter-test--fail-catalogue
           (list 'http-error 200 (list 'timeout "request timed out after 20s")))
          ;; The step waits: no done event yet, and the wait is announced.
          (harness-test-wait
           (lambda () (cl-find-if (lambda (h) (string-match-p "catalogue unavailable" h))
                                  harness-openrouter-test--hints))
           5 "the wait to be announced")
          (should-not (harness-openrouter-test--done-events events))
          (should (plist-get (harness-openrouter-catalogue-status) :transient))
          (should (= 1 (plist-get (harness-openrouter-catalogue-status) :waiting)))
          ;; The episode's own re-read is what a waiter triggers; it is
          ;; answered with the catalogue, and the step goes on to send.
          (harness-test-wait (lambda () harness-openrouter-test--held-catalogues)
                             5 "the re-read the wait started")
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait
           (lambda () (harness-openrouter-test--done-events events))
           5 "the step's answer")
          (should (eq 'end-turn (plist-get (harness-openrouter-test--newest-done events)
                                           :stop-reason)))
          ;; Exactly one completion was sent, after the reading settled, and
          ;; the pin came from that reading.
          (should (= 1 (length (harness-openrouter-test--sent-completions))))
          (should (equal "deepinfra/fp8" (plist-get harness-openrouter-test--stored :slug)))
          ;; No step is left waiting once it is answered.
          (should (zerop (plist-get (harness-openrouter-catalogue-status) :waiting))))))))

(ert-deftest harness-provider-openrouter-many-waiting-steps-share-one-outage-read ()
  "Five sessions waiting out one outage cost one re-read and one pin each.
The wait is the model's, not a session's: the first step to find the
catalogue out starts the episode's re-read, and the other four join the
same wait.  When it settles every one of them is answered from that one
reading and sends, so an outage that ends costs one read for the whole
harness -- never one per session, and never a session's own."
  (let* ((policy (harness-openrouter-test-policy))
         (sessions (mapcar (lambda (n) (harness-openrouter-test--session
                                        (format "s-%d" n)))
                           (number-sequence 1 5)))
         (events (make-hash-table :test 'equal)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--catalogue-response)
                (harness-openrouter-test--completion-response))
        ;; The first read stalls, as the live one did.  The episode's own
        ;; re-read is held, so the wait is observable while every step
        ;; joins it; the test answers it below, which is the outage ending.
        (setq harness-openrouter-test--catalogue-script
              (lambda (read)
                (if (= read 1)
                    '(:error (http-error 200 (timeout "request timed out after 20s")))
                  :hold)))
        ;; Five steps, each its own session, all finding the catalogue out.
        ;; The sessions are stubbed for the whole test: the answer to the
        ;; shared wait arrives after every step started, and each one's
        ;; dispatch must still find its own session.
        (harness-openrouter-test-with-sessions sessions
          (dolist (session sessions)
            (harness-call 'provider/complete
                          (plist-put (harness-openrouter-test--request session)
                                     :on-event (lambda (e)
                                                 (push e (gethash (plist-get session :id)
                                                                  events))))))
          ;; One wait, held by all five, and no completion sent yet.
          (harness-test-wait
           (lambda () (= 5 (plist-get (harness-openrouter-catalogue-status) :waiting)))
           10 "five steps waiting")
          (should-not (harness-openrouter-test--sent-completions))
          ;; One re-read, the wait's own, is in flight for all five.
          (harness-test-wait (lambda () harness-openrouter-test--held-catalogues)
                             10 "the re-read the wait started")
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          ;; It answers, and every waiting step is answered from it.
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait
           (lambda ()
             (cl-every (lambda (s)
                         (harness-openrouter-test--done-events
                          (gethash (plist-get s :id) events)))
                       sessions))
           20 "every waiting step to be answered")
          (dolist (session sessions)
            (should (eq 'end-turn
                        (plist-get (harness-openrouter-test--newest-done
                                    (gethash (plist-get session :id) events))
                                   :stop-reason))))
          ;; Five completions, one each, and the outage cost one failed read
          ;; and the one re-read that ended it.
          (should (= 5 (length (harness-openrouter-test--sent-completions))))
          (should (= 2 (harness-openrouter-test--catalogue-reads)))
          (should (zerop (plist-get (harness-openrouter-catalogue-status) :waiting))))))))

(ert-deftest harness-provider-openrouter-a-wait-outlasted-fails-closed ()
  "An outage that outlasts the wait ends the step with the failure, as before.
The wait is bounded: with nothing readable inside it, the step ends with
`catalogue-unavailable' and what failed, no completion is sent, and the
episode's own re-reads carry on for the next turn.  Nothing is decided
from a reading the policy does not admit, and no reading is invented."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-bounded"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--outage-response)
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          (let ((harness-openrouter-catalogue-wait 0.2))
            (setq events (harness-openrouter-test--run
                          (harness-openrouter-test--request session))))
          (should (eq 'error (plist-get (harness-openrouter-test--newest-done events)
                                        :stop-reason)))
          (should (eq 'catalogue-unavailable
                      (harness-openrouter-test--paused-kind events)))
          (should (string-match-p "still unavailable after"
                                  (plist-get (harness-openrouter-test--newest-done events)
                                             :error)))
          ;; Nothing was sent, and nothing is left waiting.
          (should-not (harness-openrouter-test--sent-completions))
          (should (zerop (plist-get (harness-openrouter-catalogue-status) :waiting)))
          ;; The episode carries on: a re-read is still due.
          (should (numberp (plist-get (harness-openrouter-catalogue-status) :next-at))))))))

(ert-deftest harness-provider-openrouter-a-refusal-is-not-waited-for ()
  "An auth refusal ends the step at once; waiting would only meet it again.
The catalogue answered: it will answer the same way to a read a second
later, so no wait is spent on it and the session is told what the
catalogue said.  A task can then wait for a person, which is the right
thing to do about a refused key, instead of for a catalogue that will
never come back by itself."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-refused"))
         (events nil)
         (started (float-time)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--refusal-response 401))
        (harness-openrouter-test-with-session session
          (setq events (harness-openrouter-test--run
                        (harness-openrouter-test--request session))))
        (should (eq 'catalogue-unavailable (harness-openrouter-test--paused-kind events)))
        ;; No wait was spent: the step ended as soon as the refusal came.
        (should (< (- (float-time) started) 2))
        (should-not (plist-get (harness-openrouter-catalogue-status) :transient))
        ;; What the catalogue said is what the status says: it answered.
        (should (string-match-p "No auth credentials found"
                                (or (plist-get (harness-openrouter-catalogue-status) :error)
                                    "")))
        (should (zerop (plist-get (harness-openrouter-catalogue-status) :waiting)))
        (should-not (harness-openrouter-test--sent-completions))))))

(ert-deftest harness-provider-openrouter-a-judge-never-waits-for-an-outage ()
  "A one-off call is refused at once while a step waits on the same outage.
The judge's budget is about the answer it asks for, so it keeps its own
short bound and is answered from the failure rather than waiting for the
catalogue: nothing is allowed by that, the call stays undecided, and the
step beside it goes on waiting."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-step"))
         (judge (harness-openrouter-test--session "s-judge"))
         (step-events nil)
         (judge-events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--outage-response)
                (harness-openrouter-test--catalogue-response)
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          (setq harness-openrouter-test--hold-catalogue t)
          ;; The step waits for the catalogue.
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e step-events))))
          (harness-openrouter-test--fail-catalogue
           (list 'http-error 200 (list 'timeout "request timed out after 20s")))
          (harness-test-wait
           (lambda () (= 1 (plist-get (harness-openrouter-catalogue-status) :waiting)))
           5 "the step to wait")
          ;; A judge asks beside it: it is refused at once, not made to wait.
          (harness-openrouter-test-with-session judge
            (let ((request (plist-put (harness-openrouter-test--request judge)
                                      :ephemeral t)))
              (setq judge-events (harness-openrouter-test--run request))))
          (should (eq 'catalogue-unavailable
                      (harness-openrouter-test--paused-kind judge-events)))
          (should-not (harness-openrouter-test--sent-completions))
          ;; The step is still waiting, and the judge never joined its wait.
          (should (= 1 (plist-get (harness-openrouter-catalogue-status) :waiting)))
          (should-not (harness-openrouter-test--done-events step-events))
          ;; A reading comes back; the step is answered and sends.
          (harness-test-wait (lambda () harness-openrouter-test--held-catalogues)
                             5 "the re-read the wait started")
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait (lambda () (harness-openrouter-test--done-events step-events))
                             5 "the step's answer")
          (should (eq 'end-turn (plist-get (harness-openrouter-test--newest-done
                                            step-events)
                                           :stop-reason))))))))

(ert-deftest harness-provider-openrouter-a-cancelled-step-stops-waiting ()
  "Cancelling a step that waits for an outage ends it and leaves no timer.
The user cancelled the turn, so it must not be sent when a reading comes
back, and it must not hold the wait open: the model's wait is dropped
with it.  Nothing is sent, no pin is stored, and the reading the episode's
re-read produces answers the next caller, not this one."
  (let* ((policy (harness-openrouter-test-policy))
         (session (harness-openrouter-test--session "s-cancelled"))
         (events nil)
         (handle nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--outage-response)
                (harness-openrouter-test--catalogue-response)
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          (setq harness-openrouter-test--hold-catalogue t)
          (setq handle (harness-call 'provider/complete
                                     (plist-put (harness-openrouter-test--request session)
                                                :on-event (lambda (e) (push e events)))))
          (harness-openrouter-test--fail-catalogue
           (list 'http-error 200 (list 'timeout "request timed out after 20s")))
          (harness-test-wait
           (lambda () (= 1 (plist-get (harness-openrouter-catalogue-status) :waiting)))
           5 "the step to wait")
          (funcall (plist-get handle :cancel))
          ;; The wait is over at once, and the step emits nothing more.
          (should (zerop (plist-get (harness-openrouter-catalogue-status) :waiting)))
          ;; Nothing of the wait is left behind: no entry, no timer, and
          ;; no promise that could only settle into nothing.
          (should (= 0 (hash-table-count harness-openrouter--catalogue-waiters)))
          (should (= 0 (hash-table-count harness-openrouter--catalogue-tokens)))
          (let ((before (length events)))
            (harness-test-wait (lambda () harness-openrouter-test--held-catalogues)
                               5 "the re-read the wait started")
            (harness-openrouter-test--answer-catalogue)
            (sit-for 0.2)
            (should (= before (length events))))
          (should-not (harness-openrouter-test--sent-completions))
          (should-not harness-openrouter-test--stored)
          ;; The reading settled for the next caller all the same.
          (should (eq 'resolved
                      (harness-promise-state
                       (harness-resolved (gethash harness-openrouter-test-model
                                                  harness-openrouter--catalogue))))))))))

(ert-deftest harness-provider-openrouter-a-recovered-reading-keeps-every-limit ()
  "A reading that ends an outage decides a pin like any other reading.
The wait does not relax anything: the provider allowlist, the maximum
price, the freshness bound and the exact endpoint are checked against the
reading that settled, and a reading that would not pass is refused rather
than waited for again.  Here the settled catalogue is dearer than the
maximum, so the step pauses with the price it read."
  (let* ((policy (harness-openrouter-test-policy
                  :max-price '(:prompt 0.0000001 :completion 0.0000002
                               :cache-read 0.000000002)))
         (session (harness-openrouter-test--session "s-dear"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--outage-response)
                (harness-openrouter-test--catalogue-response)
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e events))))
          (harness-openrouter-test--fail-catalogue
           (list 'http-error 200 (list 'timeout "request timed out after 20s")))
          (harness-test-wait (lambda () harness-openrouter-test--held-catalogues)
                             5 "the re-read the wait started")
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait
           (lambda () (harness-openrouter-test--done-events events))
           5 "the step's answer")
          ;; The settled reading was checked, and it is over the maximum.
          (should (eq 'error (plist-get (harness-openrouter-test--newest-done events)
                                        :stop-reason)))
          (should (memq (harness-openrouter-test--paused-kind events)
                        '(over-max-price nothing-under-max-price)))
          (should-not (harness-openrouter-test--sent-completions))
          (should-not harness-openrouter-test--stored))))))

(ert-deftest harness-provider-openrouter-a-recovered-pin-keeps-its-endpoint ()
  "A pinned session that waits out an outage sends to the same endpoint.
The wait changes nothing about a pin: the session's endpoint, tier and
recorded price are the ones it was pinned at, the reading that settled
lists it exactly once at a price inside the limits, and the request goes
there -- never to another endpoint of the catalogue."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route '(:catalogue-at 0.0)))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route)))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--outage-response)
                (harness-openrouter-test--catalogue-response)
                (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-session session
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--request session)
                                   :on-event (lambda (e) (push e events))))
          (harness-openrouter-test--fail-catalogue
           (list 'http-error 200 (list 'timeout "request timed out after 20s")))
          (harness-test-wait (lambda () harness-openrouter-test--held-catalogues)
                             5 "the re-read the wait started")
          (harness-openrouter-test--answer-catalogue)
          (harness-test-wait
           (lambda () (harness-openrouter-test--done-events events))
           5 "the step's answer")
          (should (eq 'end-turn (plist-get (harness-openrouter-test--newest-done events)
                                           :stop-reason)))
          (let ((sent (car (harness-openrouter-test--sent-completions))))
            (should sent)
            (should (equal '("deepinfra/fp8")
                           (append (plist-get (plist-get (plist-get sent :json) :provider)
                                              :only)
                                   nil))))
          ;; The pin did not move, and nothing was chosen again.
          (should (equal "deepinfra/fp8"
                         (plist-get (plist-get (plist-get harness-openrouter-test--session-value
                                                          :ext)
                                               :openrouter-route)
                                    :slug))))))))

;;;; A one-off call rides its session's pin when the catalogue cannot be read
;;
;; The reported failure: a 600 s request timeout stalled the catalogue, and
;; the permission judge -- a one-off call with a budget of its own -- was
;; refused for it, which non-interactive mode read as "no verdict" and
;; denied every tool call of the session.  A judge decides a call the
;; session it is made for is about to send, on the endpoint that session is
;; already pinned to, so its own answer may go to the same place.  These
;; tests are that fallback: it is taken only when there is no reading, and
;; every check the pin's own record can answer is still made.

(defun harness-openrouter-test--judge-request (parent judge)
  "Return a one-off request for JUDGE, made for PARENT, as a judge's is.
The session is the judge's own, and `:pin-from' names the session it
decides a call for -- which is what the fallback rides."
  (plist-put (plist-put (harness-openrouter-test--request judge)
                        :ephemeral t)
             :pin-from (plist-get parent :id)))

(defmacro harness-openrouter-test-with-pinned-parent (parent &rest body)
  "Run BODY with PARENT's pin answering `session/get' for the fallback.
The judge's own session is not a record, as `:ephemeral' says: a request
for it is answered by the real bus, and PARENT's by this stub.  Hints are
collected as `harness-openrouter-test-with-session' collects them."
  (declare (indent 1))
  `(let ((harness-openrouter-test--stored nil)
         (harness-openrouter-test--hints nil)
         (real (symbol-function 'harness-call)))
     (cl-letf (((symbol-function 'harness-call)
                (lambda (method &rest args)
                  (pcase method
                    ('session/get
                     (if (equal (nth 0 args) (plist-get ,parent :id))
                         ,parent
                       (apply real method args)))
                    ('session/exists-p
                     (if (equal (nth 0 args) (plist-get ,parent :id))
                         t
                       (apply real method args)))
                    ('session/hint
                     (push (nth 1 args) harness-openrouter-test--hints)
                     args)
                    (_ (apply real method args))))))
       ,@body)))

(ert-deftest harness-provider-openrouter-a-judge-rides-its-sessions-pin-when-the-catalogue-stalls ()
  "A judge whose catalogue cannot be read is answered on its session's pin.
The reported denial was \"the auto-mode judge gave no verdict\", because a
bookkeeping read stalled; the call it was deciding was on a pinned session
whose endpoint was already known.  So the one-off call goes to that same
endpoint, inside the ephemeral wait, and the verdict can be given.  It is
marked for what it is -- no reading was made -- and nothing is stored: a
one-off call pins nothing."
  (let* ((policy (harness-openrouter-test-policy))
         (parent (harness-openrouter-test--session
                  "s-parent" (list :openrouter-route (harness-openrouter-test--route))))
         (judge (harness-openrouter-test--session "s-parent-perms"))
         (events nil)
         (started (float-time)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-pinned-parent parent
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--judge-request parent judge)
                                   :on-event (lambda (e) (push e events))))
          ;; Nothing is read to completion: the catalogue stalls, as it did.
          (should (= 1 (length harness-openrouter-test--held-catalogues)))
          (harness-test-wait
           (lambda () (harness-openrouter-test--done-events events))
           (+ harness-openrouter-catalogue-ephemeral-wait 5)
           "the judge's answer")
          (should (< (- (float-time) started)
                     (+ harness-openrouter-catalogue-ephemeral-wait 5)))
          (let ((done (car (harness-openrouter-test--done-events events))))
            (should (eq 'end-turn (plist-get done :stop-reason)))
            (should-not (plist-get done :error)))
          ;; Sent to the endpoint the session is pinned to, and nothing was
          ;; pinned for the one-off call itself.
          (should (= 1 (length (harness-openrouter-test--sent-completions))))
          (should-not harness-openrouter-test--stored)
          ;; The session says the price was not re-read for that call.
          (should (cl-find-if (lambda (h) (string-match-p "catalogue unread" h))
                              harness-openrouter-test--hints)))))))

(ert-deftest harness-provider-openrouter-a-judge-with-no-pin-still-refuses ()
  "A one-off call made for a session with no pin is refused, as it was.
There is nothing to send it on: the catalogue is the only way to choose an
endpoint, and choosing one for a call that is not a step of a turn is
exactly what the policy reserves for a session's own selection."
  (let* ((policy (harness-openrouter-test-policy))
         (parent (harness-openrouter-test--session "s-parent"))
         (judge (harness-openrouter-test--session "s-parent-perms"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-pinned-parent parent
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--judge-request parent judge)
                                   :on-event (lambda (e) (push e events))))
          (harness-test-wait
           (lambda () (harness-openrouter-test--done-events events))
           (+ harness-openrouter-catalogue-ephemeral-wait 5)
           "the refusal")
          (let ((done (car (last events))))
            (should (eq 'error (plist-get done :stop-reason)))
            (should (eq 'catalogue-unavailable (plist-get done :error-kind))))
          (should-not (harness-openrouter-test--sent-completions)))))))

(ert-deftest harness-provider-openrouter-a-judge-does-not-ride-a-pin-the-policy-refuses ()
  "The fallback is not a way around the policy.
A pin whose provider the policy no longer allows, or whose recorded price
is over the limit, refuses the one-off call exactly as a dispatch of that
pin refuses a step: the age of a reading is the one check that cannot be
made without one, and it is the only one that is not made."
  (let* ((policy (harness-openrouter-test-policy))
         (parent (harness-openrouter-test--session
                  "s-parent"
                  (list :openrouter-route
                        (harness-openrouter-test--route '(:provider "Someone Else")))))
         (judge (harness-openrouter-test--session "s-parent-perms"))
         (events nil))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-fake
          (list (harness-openrouter-test--completion-response))
        (harness-openrouter-test-with-pinned-parent parent
          (setq harness-openrouter-test--hold-catalogue t)
          (harness-call 'provider/complete
                        (plist-put (harness-openrouter-test--judge-request parent judge)
                                   :on-event (lambda (e) (push e events))))
          (harness-test-wait
           (lambda () (harness-openrouter-test--done-events events))
           (+ harness-openrouter-catalogue-ephemeral-wait 5)
           "the refusal")
          (let ((done (car (last events))))
            (should (eq 'error (plist-get done :stop-reason)))
            (should (eq 'pin-not-vetted (plist-get done :error-kind))))
          (should-not (harness-openrouter-test--sent-completions)))))
    ;; A pin whose recorded price is over the limit now: a maximum lowered
    ;; under a pin stops the one-off call too, as it stops a step.
    (let* ((policy (harness-openrouter-test-policy :max-price '(:prompt 0.01 :completion 0.01
                                                               :cache-read 0.0001)))
           (parent (harness-openrouter-test--session
                    "s-parent" (list :openrouter-route (harness-openrouter-test--route))))
           (judge (harness-openrouter-test--session "s-parent-perms"))
           (events nil))
      (harness-openrouter-test-with-policy policy
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--completion-response))
          (harness-openrouter-test-with-pinned-parent parent
            (setq harness-openrouter-test--hold-catalogue t)
            (harness-call 'provider/complete
                          (plist-put (harness-openrouter-test--judge-request parent judge)
                                     :on-event (lambda (e) (push e events))))
            (harness-test-wait
             (lambda () (harness-openrouter-test--done-events events))
             (+ harness-openrouter-catalogue-ephemeral-wait 5)
             "the refusal")
            (let ((done (car (last events))))
              (should (eq 'error (plist-get done :stop-reason)))
              (should (eq 'over-max-price (plist-get done :error-kind))))
            (should-not (harness-openrouter-test--sent-completions))))))))

(provide 'harness-provider-openrouter-test)
