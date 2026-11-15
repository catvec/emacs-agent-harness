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

(ert-deftest harness-provider-openrouter-sorts-by-price-not-by-list-order ()
  "The cheaper provider wins even when the policy names it second."
  (let* ((policy (harness-openrouter-test-policy
                  :providers '("Cohere" "DeepInfra")))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (decision (harness-openrouter-test--select records policy)))
    (should (plist-get decision :ok))
    (should (equal "DeepInfra" (plist-get decision :provider)))
    (should (equal "deepinfra/fp8" (plist-get (plist-get decision :endpoint) :slug)))))

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
    ;; The same two the other way round in the policy: still the cheaper.
    (should (equal "deepinfra/fp8"
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
             (format (plist-get (harness-openai--body (harness-openrouter--endpoint) "m" pinned)
                                :response_format)))
        (should (equal "json_schema" (plist-get format :type)))
        (should (equal "verdict" (plist-get (plist-get format :json_schema) :name)))
        (should (equal schema (plist-get (plist-get format :json_schema) :schema))))
      ;; An endpoint that listed no structured outputs gets no schema.
      (let ((unlisted (plist-put (copy-sequence request) :session
                                 (list :id "s" :ext (list :openrouter-route
                                                          (harness-openrouter-test--route))))))
        (should-not (plist-get (harness-openai--body (harness-openrouter--endpoint) "m" unlisted)
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
             (routed (plist-put (copy-sequence request)
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
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-new")
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
  "A new session whose catalogue cannot be read sends no completion at all."
  (let ((policy (harness-openrouter-test-policy)))
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

(ert-deftest harness-provider-openrouter-an-absent-pinned-endpoint-is-unavailable ()
  "An endpoint the catalogue marks unavailable is refused, not used.
OpenRouter's own endpoint listing carries a status for each endpoint; a
non-zero one is the catalogue saying it is not serving requests, which
is not a price and not something to send to."
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
    (should-not (plist-get decision :ok))
    (should (eq 'endpoint-unavailable (plist-get decision :reason)))))

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
is a new fetch, and it succeeds."
  (let ((policy (harness-openrouter-test-policy))
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
          (let ((third (harness-openrouter--choose-now policy)))
            (should (= 1 (length harness-openrouter-test--held-catalogues)))
            (harness-openrouter-test--answer-catalogue)
            (let ((reading (harness-await third 5)))
              (should (numberp (plist-get reading :at)))
              (should (= 2 (length (plist-get reading :endpoints))))
              (should (= 1 (hash-table-count harness-openrouter--catalogue))))))))))

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

(provide 'harness-provider-openrouter-test)
;;; harness-provider-openrouter-test.el ends here
