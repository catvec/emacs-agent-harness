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

(defun harness-openrouter-test--over-p (price ceiling-per-million)
  "Non-nil when PRICE (USD per token, a string) is over CEILING-PER-MILLION.
CEILING-PER-MILLION is a policy figure in USD per million tokens."
  (harness-openrouter--decimal>
   (harness-openrouter-test--usd price)
   (harness-openrouter--ceiling-per-token ceiling-per-million)))

(ert-deftest harness-provider-openrouter-prices-compare-exactly ()
  "Catalogue prices and policy ceilings compare exactly, at any precision.
The values are the ones the live catalogue returned on 2026-11-10, and
the long ones are the case that a fixed 1e-12 scale rounded wrongly: a
price of 0.0000000980001 USD per token is 0.0980001 per million, just
over a 0.098 ceiling, and reading it must say so rather than round it
to 0.098."
  ;; Exact reading: the number the text names, at any number of places.
  (should (equal '(98 . 1000000000) (harness-openrouter--decimal "0.000000098")))
  (should (equal '(98 . 1000000000) (harness-openrouter--decimal "9.8e-08")))
  (should (equal '(15 . 100) (harness-openrouter--decimal "0.15")))
  (should (equal '(15 . 100) (harness-openrouter--decimal 0.15)))
  (should (equal '(0 . 1) (harness-openrouter--decimal "0")))
  (should (equal '(300 . 1) (harness-openrouter--decimal "300")))
  ;; A per-million ceiling is divided exactly, so the boundary is exact.
  (should (= 0 (harness-openrouter--decimal-compare
                (harness-openrouter-test--usd "0.000000098")
                (harness-openrouter--ceiling-per-token "0.098"))))
  (should (= 1 (harness-openrouter--decimal-compare
                (harness-openrouter-test--usd "0.0000000980001")
                (harness-openrouter--ceiling-per-token "0.098"))))
  (should (= -1 (harness-openrouter--decimal-compare
                 (harness-openrouter-test--usd "0.0000000979999")
                 (harness-openrouter--ceiling-per-token "0.098"))))
  ;; The reported bug: a long fractional price was scaled to about 980
  ;; dollars per million rather than 0.000000098, which is 0.098 per
  ;; million.  It still compares correctly, and it is over the ceiling.
  (should (harness-openrouter-test--over-p "0.0000000980001" "0.098"))
  (should-not (harness-openrouter-test--over-p "0.0000000980001" "0.099"))
  (should-not (harness-openrouter-test--over-p "0.000000098" "0.098"))
  ;; A ceiling is never rounded up into accepting a price above it: 0.15
  ;; per million is 0.00000015 per token, over a 0.149999 per-million
  ;; ceiling by a hair, and under a 0.15 ceiling exactly.
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
                      (list :freshness nil "freshness")
                      (list :privacy (list :retention "none" :regions '("US")
                                           :checked-at (float-time) :source "x")
                            "training")))
    (let ((policy (apply #'harness-openrouter-test-policy case)))
      (should (string-match-p (nth 2 case) (harness-openrouter-routing-validate policy)))))
  ;; A base slug, a mismatched tag and a non-standard tier are each
  ;; refused.  There is no per-endpoint ceiling to leave out: the only
  ;; price filter is the owner's own published rate.
  (let* ((policy (harness-openrouter-test-policy))
         (endpoint (car (plist-get policy :endpoints)))
         (cohere (cadr (plist-get policy :endpoints))))
    (dolist (case
             (list
              (cons "no exact slug"
                    (plist-put (copy-sequence endpoint) :slug "deepinfra"))
              (cons "tag and slug differ"
                    (plist-put (copy-sequence endpoint) :tag "deepinfra/turbo"))
              (cons "standard or flex"
                    (plist-put (copy-sequence endpoint) :tier "priority"))))
      (should (string-match-p (car case)
                              (harness-openrouter-routing-validate
                               (plist-put policy :endpoints (list (cdr case) cohere)))))))
  ;; The owner price is the filter, so a hole in it blocks too.
  (let* ((policy (harness-openrouter-test-policy))
         (owner (plist-get policy :owner-price)))
    (dolist (case (list (cons "incomplete"
                              (plist-put (copy-sequence owner) :prompt nil))
                        (cons "source or no date"
                              (plist-put (copy-sequence owner) :read-at nil))
                        (cons "maximum age"
                              (plist-put (copy-sequence owner) :max-age 0))))
      (should (string-match-p (car case)
                              (harness-openrouter-routing-validate
                               (plist-put policy :owner-price (cdr case)))))))
  ;; The policy's privacy statement must be machine-checkable: a
  ;; retention claim, a region set and a Safety Retention choice, each of
  ;; which this module compares against every endpoint's own evidence.
  (should (string-match-p
           "privacy requirement"
           (harness-openrouter-routing-validate
            (harness-openrouter-test-policy :privacy nil))))
  (should (string-match-p
           "training"
           (harness-openrouter-routing-validate
            (harness-openrouter-test-policy
             :privacy (list :retention "zero" :zdr-eligible t :safety-retention :excluded
                            :regions '("US"))))))
  ;; "30 days" is not a retention this module can check, and saying it
  ;; must block rather than be read as some non-null statement.
  (should (string-match-p
           "retention"
           (harness-openrouter-routing-validate
            (harness-openrouter-test-policy
             :privacy (list :no-training t :retention "30 days"
                            :zdr-eligible t :safety-retention :excluded
                            :regions '("US"))))))
  (should (string-match-p
           "region"
           (harness-openrouter-routing-validate
            (harness-openrouter-test-policy
             :privacy (list :no-training t :retention "zero" :zdr-eligible t
                            :safety-retention :excluded :regions '("CN"))))))
  ;; A policy that does not say whether Safety Retention endpoints are
  ;; acceptable cannot be checked either.
  (should (string-match-p
           "Safety Retention"
           (harness-openrouter-routing-validate
            (harness-openrouter-test-policy
             :privacy (list :no-training t :retention "zero" :zdr-eligible t
                            :regions '("US"))))))
  ;; A configured policy that is not enabled routes nothing.
  (should-not (harness-openrouter-routing-enabled-p
               (harness-openrouter-test-policy :enabled nil)))
  (should (harness-openrouter-routing-enabled-p (harness-openrouter-test-policy))))

;;;; Selection

(defun harness-openrouter-test--select (records &optional policy at)
  "Select from RECORDS with POLICY read at AT; return the decision."
  (harness-openrouter-select (or policy (harness-openrouter-test-policy)) records
                             (or at (float-time))))

(ert-deftest harness-provider-openrouter-selects-the-cheapest-vetted-endpoint ()
  "Of the vetted endpoints under the owner price, the cheapest is chosen.
The price sort reads the catalogue's own per-token prices, so a
promotional rate already reflected there is what it compares."
  (let* ((records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (decision (harness-openrouter-test--select records)))
    (should (plist-get decision :ok))
    (should (equal "deepinfra/fp8" (plist-get (plist-get decision :endpoint) :slug)))
    (should (equal '(98 . 1000000000) (plist-get (plist-get decision :record) :prompt)))
    (should (equal '(51 . 100) (plist-get (plist-get decision :record) :discount)))))

(ert-deftest harness-provider-openrouter-sorts-by-price-not-by-list-order ()
  "The cheaper endpoint wins even when the policy lists it second."
  (let* ((policy (harness-openrouter-test-policy))
         (endpoints (plist-get policy :endpoints))
         ;; Cohere first in the allowlist, DeepInfra still cheaper.
         (policy (plist-put policy :endpoints (list (cadr endpoints) (car endpoints))))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (decision (harness-openrouter-test--select records policy)))
    (should (plist-get decision :ok))
    (should (equal "deepinfra/fp8" (plist-get (plist-get decision :endpoint) :slug)))))

(ert-deftest harness-provider-openrouter-a-dearer-endpoint-is-filtered-out ()
  "A vetted endpoint dearer than the owner's own price is dropped, not chosen.
The owner price is the most the policy pays, so the next vetted endpoint
under it takes the session."
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
    (should (equal "cohere/fp8" (plist-get (plist-get decision :endpoint) :slug)))
    ;; And the dropped one is not quietly re-added by a stale pin.
    (should (equal '(15 . 100000000)
                   (plist-get (plist-get decision :record) :prompt)))))

(ert-deftest harness-provider-openrouter-the-owner-price-filters-every-component ()
  "A candidate over the owner price in one component alone is dropped.
The cache-read rate counts: an endpoint that costs more per cached token
is dearer for a long session, whatever its prompt price."
  (let* ((policy (harness-openrouter-test-policy))
         ;; DeepInfra's cache-read is 0.00294 per million and fits under
         ;; this; Cohere's 0.003 does not, and only that component excludes it.
         (owner (plist-put (copy-sequence (plist-get policy :owner-price))
                           :cache-read 0.00295))
         (policy (plist-put policy :owner-price owner))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (decision (harness-openrouter-test--select records policy)))
    (should (plist-get decision :ok))
    (should (equal "deepinfra/fp8" (plist-get (plist-get decision :endpoint) :slug)))
    ;; Cohere is excluded by its cache-read rate alone, though its prompt
    ;; and completion prices fit under the same owner price.
    (let ((cohere (plist-get (cadr (plist-get policy :endpoints)) :slug)))
      (should-not (equal cohere (plist-get (plist-get decision :endpoint) :slug))))))

(ert-deftest harness-provider-openrouter-nothing-under-the-owner-price-blocks ()
  "When every vetted endpoint is dearer than the owner price, nothing is sent.
Blocking is the honest answer: the alternative is paying more than the
model owner itself charges, which the policy exists to prevent."
  (let* ((policy (harness-openrouter-test-policy))
         (owner (plist-put (plist-put (copy-sequence (plist-get policy :owner-price))
                                      :prompt 0.01)
                           :completion 0.02))
         (policy (plist-put policy :owner-price owner))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (decision (harness-openrouter-test--select records policy)))
    (should-not (plist-get decision :ok))
    (should (eq 'over-owner-price (plist-get decision :reason)))
    (should (string-match-p "deepinfra/fp8" (plist-get decision :detail)))
    (should (string-match-p "cohere/fp8" (plist-get decision :detail)))))

(ert-deftest harness-provider-openrouter-a-stale-owner-price-blocks ()
  "An owner price past its own maximum age is no ceiling at all.
It is a claim about someone else's price list, so it is dated and it
expires; a stale one blocks rather than being trusted."
  (let* ((policy (harness-openrouter-test-policy))
         (owner (plist-put (plist-put (copy-sequence (plist-get policy :owner-price))
                                      :max-age 60)
                           :read-at (- (float-time) 600)))
         (policy (plist-put policy :owner-price owner))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (decision (harness-openrouter-test--select records policy)))
    (should-not (plist-get decision :ok))
    (should (eq 'owner-price-stale (plist-get decision :reason)))
    (should (string-match-p "600" (plist-get decision :detail)))))

(ert-deftest harness-provider-openrouter-unknown-prices-block-rather-than-switch ()
  "Anything short of a fresh, exact, well-formed reading blocks.
A listing that cannot be read is not a price that is too high, so none
of these may fall through to Cohere; each case is a new session that is
told why it cannot send."
  (let* ((policy (harness-openrouter-test-policy))
         (deepinfra (car (plist-get policy :endpoints)))
         (cohere (cadr (plist-get policy :endpoints)))
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
    (ignore deepinfra cohere)
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
The live catalogue has 51 endpoints for this model; the policy names
two exact ones, and the rest -- including a cheaper one, a flex one and
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

(ert-deftest harness-provider-openrouter-expired-endpoint-evidence-pauses-the-pin ()
  "A pinned session whose endpoint evidence expired is paused, not moved.
The policy selects for a new session only: a later switch is the user's,
so a session already pinned stops instead of silently changing endpoint
and losing its cache.  The evidence is asked of every dispatch, not once
when the pin was made.  A pause sends nothing at all."
  (let* ((policy (harness-openrouter-test-policy))
         (endpoints (plist-get policy :endpoints))
         ;; DeepInfra's own evidence is dated far enough back that its own
         ;; max age has passed; Cohere's is not.
         (endpoints (list (plist-put (copy-sequence (car endpoints)) :evidence
                                     (harness-openrouter-test--evidence
                                      :checked-at (- (float-time) 600) :max-age 60))
                          (cadr endpoints)))
         (policy (plist-put policy :endpoints endpoints))
         (route (harness-openrouter-test--route '(:catalogue-at (float-time))))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session session
        (harness-openrouter-test-with-fake
            (list (cons "chat/completions" '(:body "{}")))
          (let ((events (harness-openrouter-test--run
                         (list :model (format "openrouter:%s" harness-openrouter-test-model)
                               :session session
                               :messages '((:role user :content ((:type "text" :text "hi"))))))))
            (should (eq 'error (plist-get (car (last events)) :stop-reason)))
            (should (eq 'privacy-stale (plist-get (car (last events)) :error-kind)))
            (should (cl-find-if (lambda (h) (string-match-p "evidence" h))
                                harness-openrouter-test--hints))
            ;; Nothing was sent, and the guessable alternative (Cohere) was
            ;; not tried either.
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions" (plist-get r :url)))
                                    harness-openrouter-test--requests))
            (should-not (cl-find-if (lambda (r) (string-match-p "/endpoints" (plist-get r :url)))
                                    harness-openrouter-test--requests))))))))

;;;; Privacy: each endpoint's own evidence, not one statement for all

(defun harness-openrouter-test--with-evidence (evidence)
  "Return a policy whose DeepInfra endpoint carries EVIDENCE.
Cohere keeps its own complete evidence, so a test sees one endpoint
blocked by its own facts rather than the whole policy being invalid."
  (let* ((policy (harness-openrouter-test-policy))
         (endpoints (plist-get policy :endpoints)))
    (plist-put policy :endpoints
               (list (plist-put (copy-sequence (car endpoints)) :evidence evidence)
                     (cadr endpoints)))))

(ert-deftest harness-provider-openrouter-each-endpoint-needs-its-own-evidence ()
  "One endpoint's evidence does not stand for another's.
The example's DeepInfra evidence says nothing about Cohere: another
provider, another host, another data policy.  An endpoint with no
evidence of its own is not in the allowlist, and the policy says which
endpoint is missing it."
  (let* ((policy (harness-openrouter-test-policy))
         (endpoints (plist-get policy :endpoints))
         (policy (plist-put policy :endpoints
                            (list (car endpoints)
                                  (plist-put (copy-sequence (cadr endpoints))
                                             :evidence nil)))))
    (should (string-match-p "cohere/fp8 has no privacy evidence"
                            (harness-openrouter-routing-validate policy)))))

(ert-deftest harness-provider-openrouter-evidence-about-another-host-is-refused ()
  "Evidence that names another host does not cover this endpoint.
The data policy that matters is the one for the host that serves the
request; a DeepInfra policy pasted onto Cohere's endpoint names a host
that is not the one the pin sends to, and is refused."
  (let ((policy (harness-openrouter-test--with-evidence
                 (harness-openrouter-test--evidence :host "cohere.com"))))
    (should (string-match-p
             "names host cohere\\.com, not the vetted deepinfra\\.com"
             (harness-openrouter-routing-validate policy)))))

(ert-deftest harness-provider-openrouter-unknown-retention-is-refused ()
  "A retention statement this module cannot read blocks the endpoint.
\"30 days\", \"safety only\", or any free text is not a retention class
the policy compares; reading it as `some non-null statement' is how an
endpoint with retention slips through a policy that requires none."
  (dolist (retention '("30 days" "unknown" "safety only" ""))
    (let ((policy (harness-openrouter-test--with-evidence
                   (harness-openrouter-test--evidence :retention retention))))
      (should (string-match-p
               "retention"
               (harness-openrouter-routing-validate policy))))))

(ert-deftest harness-provider-openrouter-retention-nobody-required-is-refused ()
  "An endpoint that keeps data is refused when the policy requires none.
The comparison is exact and machine-checkable: the endpoint's class must
be the class the policy requires, and \"zero\" is the only class this
module knows."
  (let* ((policy (harness-openrouter-test-policy))
         (endpoints (plist-get policy :endpoints))
         ;; The policy now requires a class this module does not know.
         (policy (plist-put policy :privacy
                            (plist-put (copy-sequence harness-openrouter-test--privacy)
                                       :retention "30 days"))))
    (should (string-match-p "retention 30 days"
                            (harness-openrouter-routing-validate policy)))
    ;; And the endpoint's regions must be inside the policy's.
    (should (string-match-p
             "regions"
             (harness-openrouter-routing-validate
              (harness-openrouter-test--with-evidence
               (harness-openrouter-test--evidence :regions '("CN"))))))))

(ert-deftest harness-provider-openrouter-safety-retention-is-a-separate-fact ()
  "ZDR eligibility, Safety Retention, no-training and regions are separate.
`zdr: true' on a request can still route to a Safety Retention endpoint
when the account or guardrail allows it, so it is not proof of strict
zero retention.  The policy must say whether Safety Retention is
acceptable, and an endpoint whose evidence says something else is
refused rather than assumed to be the same thing."
  (let* ((policy (harness-openrouter-test-policy))
         (endpoints (plist-get policy :endpoints))
         ;; The endpoint's evidence says Safety Retention is allowed; the
         ;; policy requires endpoints that exclude it.
         (policy (plist-put policy :endpoints
                            (list (plist-put (copy-sequence (car endpoints))
                                             :evidence
                                             (harness-openrouter-test--evidence
                                              :safety-retention :allowed))
                                  (cadr endpoints)))))
    (should (string-match-p "Safety Retention"
                            (harness-openrouter-routing-validate policy)))
    ;; And an evidence that claims zero retention while allowing Safety
    ;; Retention is exactly the confusion this check exists for.
    (should (string-match-p
             "Safety Retention"
             (harness-openrouter-routing-validate
              (harness-openrouter-test--with-evidence
               (harness-openrouter-test--evidence :safety-retention :allowed)))))))

(ert-deftest harness-provider-openrouter-evidence-without-a-date-or-source-is-refused ()
  "Evidence must be dated and cited; an undated claim is not evidence.
A statement about a provider's data policy changes when the provider
changes it, so it needs the source it was read from and the time it was
checked, and a maximum age of its own."
  (dolist (case (list (list :checked-at nil "not dated")
                      (list :checked-at "2026-11-10" "not dated")
                      (list :source nil "cites no source")
                      (list :source "" "cites no source")
                      (list :max-age nil "no maximum age")
                      (list :max-age 0 "no maximum age")))
    (let ((policy (harness-openrouter-test--with-evidence
                   (apply #'harness-openrouter-test--evidence case))))
      (should (string-match-p
               (nth 2 case)
               (harness-openrouter-routing-validate policy))))))

(ert-deftest harness-provider-openrouter-expired-evidence-blocks-that-endpoint ()
  "Evidence past the age it names blocks its endpoint, not the whole policy.
The policy is still complete; what changed is that one endpoint's
evidence is no longer trusted, and that endpoint is not selected."
  (let* ((policy (harness-openrouter-test--with-evidence
                  (harness-openrouter-test--evidence
                   :checked-at (- (float-time) 600) :max-age 60)))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse (harness-openrouter-test--catalogue-json))))
         (decision (harness-openrouter-test--select records policy)))
    ;; DeepInfra's evidence lapsed; it blocks rather than being dropped,
    ;; and the other endpoint is not sent in its place.
    (should-not (plist-get decision :ok))
    (should (eq 'privacy-stale (plist-get decision :reason)))
    (should (string-match-p "recheck" (plist-get decision :detail)))))

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
                      :key "deepinfra-standard" :slug "deepinfra/fp8"
                      :provider "DeepInfra" :tier "default" :quantization "fp8"
                      :prompt 0.098 :completion 0.294 :cache-read 0.00294
                      :discount 0.51 :catalogue-at 0.0 :basis "chosen"))
             (request (plist-put (copy-sequence request) :session
                                 (list :id "session-1"
                                       :ext (list :openrouter-route route))))
             (body (harness-openai--body
                    (harness-openrouter--endpoint) harness-openrouter-test-model request))
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
      (let ((openrouter (harness-openai--body (harness-openrouter--endpoint) "m" request))
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
The block names the endpoint it could not verify, and it never falls
through to the other vetted endpoint."
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
            (should (string-match-p "deepinfra/fp8" (plist-get (car (last events)) :error)))
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
  "A pinned endpoint whose fresh price is over the owner price pauses.
It is not moved to the cheaper endpoint and it is not sent anyway: a
switch is cache-cold and the user's decision, so the session waits."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route '(:catalogue-at 0.0)))
         (session (harness-openrouter-test--session
                   "s-pinned" (list :openrouter-route route)))
         ;; DeepInfra's price has risen past the owner price; Cohere's has not.
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
            (should (eq 'over-owner-price (plist-get (car (last events)) :error-kind)))
            ;; Nothing was sent, and the pin was not moved to Cohere.
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                (plist-get r :url)))
                                    harness-openrouter-test--requests))
            (should-not harness-openrouter-test--stored)
            (should (cl-find-if (lambda (h) (string-match-p "dearer" h))
                                harness-openrouter-test--hints))))))))

(ert-deftest harness-provider-openrouter-a-pin-the-policy-dropped-pauses ()
  "A pin whose endpoint key the policy no longer lists is not sent.
The endpoint was vetted once; a policy that no longer names it says the
pin is no longer vetted, and the request waits rather than going to an
endpoint the allowlist dropped."
  (let* ((policy (harness-openrouter-test-policy))
         (route (harness-openrouter-test--route '(:key "retired-standard"
                                                  :catalogue-at (float-time))))
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

(ert-deftest harness-provider-openrouter-a-lowered-ceiling-stops-a-fresh-pin ()
  "A pin whose recorded price is over the owner price now is not sent.
The policy's ceiling is checked against the price the pin recorded on
every dispatch, not only when the catalogue is read again, so lowering
the owner price under a pin that is still fresh stops it.  The session
does not move to the other vetted endpoint: a switch is the user's."
  (let* ((policy (harness-openrouter-test-policy))
         ;; The owner's prompt ceiling is now under the pin's own price.
         (owner (plist-put (copy-sequence (plist-get policy :owner-price))
                           :prompt 0.001))
         (policy (plist-put policy :owner-price owner))
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
            (should (eq 'over-owner-price (plist-get (car (last events)) :error-kind)))
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                (plist-get r :url)))
                                    harness-openrouter-test--requests))
            ;; And it was not re-pinned to the other endpoint.
            (should-not harness-openrouter-test--stored)))))))

(ert-deftest harness-provider-openrouter-an-expired-owner-price-stops-a-pin ()
  "A pin is not sent once the owner price it was vetted against expires.
The price is a claim about someone else's price list with a date on it;
past that date it is no longer evidence, and the session waits for a
fresh reading rather than sending at a price nobody can vouch for."
  (let* ((policy (harness-openrouter-test-policy))
         (owner (plist-put (plist-put (copy-sequence (plist-get policy :owner-price))
                                      :read-at (- (float-time) 7200))
                           :max-age 60))
         (policy (plist-put policy :owner-price owner))
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
            (should (eq 'owner-price-stale (plist-get (car (last events)) :error-kind)))
            (should-not (cl-find-if (lambda (r) (string-match-p "chat/completions"
                                                                (plist-get r :url)))
                                    harness-openrouter-test--requests))))))))

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
The other vetted endpoint is still there and cheaper than nothing; it is
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
  "A listing that prices a component the owner price does not cover blocks.
The ceiling bounds prompt, completion and cache-read; a per-request fee,
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
  "A routed request states the owner price as `max_price' on the wire.
It is a second defence: OpenRouter's own router refuses an endpoint
dearer than the ceiling in prompt or completion, whatever this module
read.  It covers nothing else -- the documentation offers no cache-read
cap -- so cache-read is checked here and never assumed covered."
  (let* ((policy (harness-openrouter-test-policy))
         (session (list :id "session-1"
                        :ext (list :openrouter-route
                                   (harness-openrouter-test--route))))
         (request (list :model (format "openrouter:%s" harness-openrouter-test-model)
                        :session session
                        :messages '((:role user :content ((:type "text" :text "hi"))))))
         (body (let ((harness-openrouter-routing policy))
                 (harness-openai--body (harness-openrouter--endpoint)
                                       harness-openrouter-test-model request)))
         (max-price (plist-get (plist-get body :provider) :max_price)))
    (should max-price)
    (should (harness-openrouter-test--approx 0.30 (plist-get max-price :prompt)))
    (should (harness-openrouter-test--approx 1.20 (plist-get max-price :completion)))
    ;; No cache-read cap is sent, because the API has none: this module
    ;; never claims one protects a cache read.
    (should-not (plist-member max-price :cache-read))
    (should-not (plist-member max-price :input_cache_read))))

(ert-deftest harness-provider-openrouter-an-unbounded-request-fee-blocks ()
  "A per-request fee the owner price does not bound is refused before sending.
OpenRouter's `max_price' accepts a `request' fee, and this module sends
one only when the policy bounds it and the pinned endpoint charges one.
An endpoint that charges a fee no ceiling covers is not one this policy
can send to."
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
never reached, so there is no request to a second host to retry."
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
                  (harness-openrouter-test--completion-response))
          (harness-openrouter-test--run (harness-openrouter-test--request session))
          (should (= 1 (length harness-openrouter-test--requests)))
          (should (string-match-p "/endpoints\\'"
                                  (plist-get (car harness-openrouter-test--requests) :url))))))))

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
                 (cadr (should-error (harness-openrouter-switch "s-1" "cohere-standard")))))))))

(ert-deftest harness-provider-openrouter-switch-checks-the-endpoint-it-moves-to ()
  "A switch verifies the endpoint exactly as a new session does.
The route records that it was switched, and why."
  (let ((policy (harness-openrouter-test-policy))
        (harness-openrouter-routing (harness-openrouter-test-policy)))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-1")
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--catalogue-response))
          (harness-test-await
           (harness-openrouter-switch "s-1" "cohere-standard" "cheaper"))
          (should (equal "cohere/fp8" (plist-get harness-openrouter-test--stored :slug)))
          (should (equal "switched" (plist-get harness-openrouter-test--stored :basis)))
          (should (equal "cheaper" (plist-get harness-openrouter-test--stored :why))))))))

(ert-deftest harness-provider-openrouter-switch-refuses-an-unverified-endpoint ()
  "An endpoint that cannot be verified now is not switched to."
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
                         (harness-openrouter-switch "s-1" "cohere-standard")))
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

(ert-deftest harness-provider-openrouter-a-regional-variant-makes-the-slug-ambiguous ()
  "A slug two catalogue records select is not pinned; the identity is not exact.
OpenRouter matches a slug against every endpoint that shares its
segments, so a new regional variant of the same endpoint -- a tag the
policy never vetted -- would receive requests the policy did not allow.
The endpoint blocks instead, and the decision says why."
  (let* ((policy (harness-openrouter-test-policy))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse
                    (harness-openrouter-test--catalogue-json
                     ;; The vetted endpoint, and a new region of it.
                     (harness-openrouter-test--endpoint-json
                      "deepinfra/fp8" "DeepInfra")
                     (harness-openrouter-test--endpoint-json
                      "deepinfra/fp8/us" "DeepInfra")
                     (harness-openrouter-test--endpoint-json
                      "cohere/fp8" "Cohere"
                      :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                 :input_cache_read "0.000000003" :discount 0))))))
         (decision (harness-openrouter-test--select records policy)))
    ;; The ambiguous endpoint blocks; it is not dropped for the other one.
    (should-not (plist-get decision :ok))
    (should (eq 'unknown-endpoint (plist-get decision :reason)))
    (should (string-match-p "deepinfra/fp8" (plist-get decision :detail)))))

(ert-deftest harness-provider-openrouter-a-flex-or-priority-sibling-is-not-selected ()
  "A standard endpoint's slug does not select its tier siblings.
OpenRouter documents the one exception to prefix matching: a slug that
names no tier never matches a tier endpoint.  So `deepinfra/fp8' selects
the standard endpoint alone, not its `flex' or `priority' sibling, and
the pin stays exact on a catalogue that lists all three."
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
    ;; The flex endpoint is cheaper, and is not what the standard slug
    ;; selects; a tier endpoint is pinned only by naming it as one.
    (should (equal "deepinfra/fp8" (plist-get (plist-get decision :record) :tag)))))

(ert-deftest harness-provider-openrouter-a-tier-slug-is-pinned-only-as-a-tier ()
  "A policy may name a tier endpoint, and then its tier must match the catalogue.
The tier is part of the vetted identity: an endpoint vetted at the flex
tier is not served by its standard sibling's listing, and a catalogue
that calls the same tag a different tier is an identity that changed."
  (let* ((policy (harness-openrouter-test-policy))
         (flex (list :key "deepinfra-flex" :slug "deepinfra/fp8/flex"
                     :tag "deepinfra/fp8/flex" :provider "DeepInfra"
                     :tier "flex" :quantization "fp8"
                     :host "deepinfra.com"
                     :evidence (harness-openrouter-test--evidence)))
         (policy (plist-put policy :endpoints (list flex)))
         (records (harness-openrouter-parse-endpoints
                   (harness-json-parse
                    (harness-openrouter-test--catalogue-json
                     (harness-openrouter-test--endpoint-json
                      "deepinfra/fp8/flex" "DeepInfra" :tier "flex"
                      :pricing '(:prompt "0.0000000784" :completion "0.0000002352"
                                 :input_cache_read "0.000000002352" :discount 0.51))))))
         (decision (harness-openrouter-test--select records policy)))
    (should (plist-get decision :ok))
    (should (equal "deepinfra/fp8/flex" (plist-get (plist-get decision :endpoint) :slug)))
    ;; The same tag, served at another tier, is not this endpoint.
    (let ((moved (harness-openrouter-parse-endpoints
                  (harness-json-parse
                   (harness-openrouter-test--catalogue-json
                    (harness-openrouter-test--endpoint-json
                     "deepinfra/fp8/flex" "DeepInfra" :tier "priority"
                     :pricing '(:prompt "0.0000000784" :completion "0.0000002352"
                                :input_cache_read "0.000000002352" :discount 0.51)))))))
      (should-not (plist-get (harness-openrouter-select policy moved (float-time)) :ok)))))

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

(provide 'harness-provider-openrouter-test)
;;; harness-provider-openrouter-test.el ends here
