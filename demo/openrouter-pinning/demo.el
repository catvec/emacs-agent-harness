;;; demo.el --- Show price-aware OpenRouter selection  -*- lexical-binding: t; -*-

;;; Commentary:

;; Prints what the policy decides for this checkpoint under Noah's rule --
;; sort by increasing price, drop anything dearer than DeepSeek's own
;; published peak rate, never leave the vetted pair -- in six situations:
;;
;;   1. today, from the live catalogue (read-only: the endpoints
;;      listing, no completion request, no credential);
;;   2. the same catalogue with DeepInfra's 51% promo ended;
;;   3. both endpoints above the owner price;
;;   4. an endpoint whose rate varies by the window of the week;
;;   5. a session already pinned when the ceiling is lowered under it;
;;   6. a session already pinned when the fresh catalogue is empty.
;;
;; Cases 5 and 6 are the ones that used to slip through: a pinned session
;; was checked for a new selection but dispatched anyway.  They now stop
;; with the reason, which is what the last two blocks print.
;;
;; Run it with demo/openrouter-pinning/demo.sh.  It never sends a
;; completion and never sets `harness-openrouter-routing': it calls the
;; selector and the dispatch check directly, so it changes nothing in a
;; Harness.  The privacy evidence below is a labelled placeholder, not
;; evidence: this demo is about price, and a real policy needs Noah's own
;; dated, cited evidence per endpoint.

;;; Code:

(add-to-list 'load-path (expand-file-name "../../lisp"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path (expand-file-name "../../lisp/modules"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(require 'harness-util)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-provider-openrouter)

(defconst demo-model "deepseek/deepseek-v4.1-flash-1017"
  "The exact checkpoint the policy is for.")

(defconst demo-catalogue-url
  (concat "https://openrouter.ai/api/v1/models/" demo-model "/endpoints")
  "Read-only listing of the endpoints that serve DEMO-MODEL.")

(defconst demo-endpoints
  '(("deepinfra-standard" "deepinfra/fp8" "DeepInfra" "deepinfra.com")
    ("cohere-standard" "cohere/fp8" "Cohere" "cohere.com"))
  "The vetted pair: key, exact tag, provider name and host.")

(defun demo-evidence (host)
  "Return placeholder privacy evidence for HOST.
Every fact a policy requires is stated, and the source says what it is:
a placeholder, so this demo never passes as evidence for a real policy."
  (list :no-training t
        :retention "zero"
        :zdr-eligible t
        :safety-retention :excluded
        :regions '("US")
        :host host
        :checked-at (float-time)
        :source "placeholder for the price demo, not evidence"
        :max-age 86400))

(defun demo-policy (&rest overrides)
  "Return the documented policy with OVERRIDES, dated now.
The owner price is DeepSeek's own peak rate; the privacy requirement is
the strictest machine-checkable one.  The values are dated now because a
policy whose evidence has gone stale blocks by design."
  (let ((now (float-time)))
    (cl-flet ((endpoint (key slug provider host tier)
                (list :key key :slug slug :tag slug :provider provider
                      :host host :tier tier :quantization "fp8"
                      :evidence (demo-evidence host))))
      (let ((policy (list :enabled t
                          :model demo-model
                          :freshness 900
                          :owner-price (list :prompt 0.30 :completion 1.20
                                             :cache-read 0.006
                                             :source "https://api-docs.deepseek.com/quick_start/pricing"
                                             :read-at now :max-age 604800)
                          :privacy (list :no-training t
                                         :retention "zero"
                                         :zdr-eligible t
                                         :safety-retention :excluded
                                         :regions '("US"))
                          :retry '(:max-attempts 2 :max-seconds 60
                                   :max-output-tokens 4096)
                          :endpoints
                          (mapcar (lambda (e)
                                    (apply #'endpoint (append e (list nil))))
                                  demo-endpoints))))
        (while overrides
          (setq policy (plist-put policy (car overrides) (cadr overrides))
                overrides (cddr overrides)))
        policy))))

(defun demo--per-million (price)
  "Return PRICE, an exact per-token decimal, as US dollars per million."
  (when (consp price) (harness-openrouter--usd-per-million price)))

(defun demo-show (label policy records)
  "Print what POLICY decides from RECORDS, under LABEL."
  (let ((decision (harness-openrouter-select policy records (float-time)))
        (ceiling (harness-openrouter--owner-price policy)))
    (princ (format "\n=== %s\n" label))
    (dolist (endpoint (plist-get policy :endpoints))
      (let* ((standing (harness-openrouter--standing policy records endpoint ceiling))
             (record (plist-get standing :record)))
        (princ (format "  %-14s %-9s %s\n"
                       (plist-get endpoint :slug)
                       (plist-get standing :standing)
                       (if record
                           (format "prompt %7.4f  completion %7.4f  cache-read %.6f  (USD/1M)"
                                   (or (demo--per-million (plist-get record :prompt)) 0)
                                   (or (demo--per-million (plist-get record :completion)) 0)
                                   (or (demo--per-million (plist-get record :cache-read)) 0))
                         (plist-get standing :detail))))))
    (princ (format "  -> %s\n"
                   (if (plist-get decision :ok)
                       (format "PIN %s"
                               (plist-get (plist-get decision :endpoint) :slug))
                     (format "SEND NOTHING: %s -- %s"
                             (plist-get decision :reason)
                             (plist-get decision :detail)))))))

(defun demo-show-pin (label policy route reading)
  "Print what POLICY decides about an existing pin ROUTE under LABEL.
READING is the fresh catalogue reading the dispatch would check against,
or nil for a dispatch that reuses the pin's own reading."
  (let ((refusal (harness-openrouter--pin-refusal policy route reading)))
    (princ (format "\n=== %s\n" label))
    (princ (format "  pin: %s at %s USD/1M prompt\n"
                   (plist-get route :slug) (plist-get route :prompt)))
    (princ (format "  -> %s\n"
                   (if refusal
                       (format "STOP (%s): %s" (car refusal) (cdr refusal))
                     "SEND on the same endpoint")))))

(defun demo-route (policy slug)
  "Return the route a pin on SLUG would have recorded under POLICY.
It is what `harness-openrouter--route-plist' stores, read back from the
decision, so the demo's pin is the shape the module really keeps."
  (let* ((records (demo-stock))
         (narrow (plist-put (copy-sequence policy) :endpoints
                            (cl-remove-if-not (lambda (e) (equal (plist-get e :slug) slug))
                                              (plist-get policy :endpoints))))
         (decision (harness-openrouter-select narrow records (float-time))))
    (when (plist-get decision :ok)
      (harness-openrouter--route-plist decision))))

(defun demo-stock-records (prompt completion cache-read for)
  "Return a catalogue record for FOR at PROMPT, COMPLETION and CACHE-READ.
The prices are the decimal strings a catalogue carries and go through
the module's own record reader, so the demo shows the exact decimals the
selector compares rather than a test shortcut."
  (harness-openrouter--endpoint-record
   (list :name for
         :model_id demo-model
         :provider_name for
         :tag (nth 1 (cl-find-if (lambda (e) (equal (nth 2 e) for)) demo-endpoints))
         :quantization "fp8"
         :context_length 1048576
         :pricing (list :prompt prompt
                        :completion completion
                        :input_cache_read cache-read
                        :discount 0))))

(defun demo-stock ()
  "Return the two vetted endpoints at the rates published on 2026-11-10.
DeepInfra is at its 51%-off promotional rate and Cohere at its list rate."
  (list (demo-stock-records "0.000000098" "0.000000294" "0.00000000294" "DeepInfra")
        (demo-stock-records "0.00000015" "0.0000005" "0.000000003" "Cohere")))

(defun demo-reprice (records tag prices)
  "Return RECORDS with TAG's prices replaced by PRICES.
PRICES is (PROMPT COMPLETION CACHE-READ) as the catalogue would write
them, in USD per token."
  (mapcar (lambda (record)
            (if (equal (plist-get record :tag) tag)
                (let ((copy (copy-sequence record)))
                  (setq copy (plist-put copy :prompt
                                        (harness-openrouter--price-per-token (nth 0 prices))))
                  (setq copy (plist-put copy :completion
                                        (harness-openrouter--price-per-token (nth 1 prices))))
                  (plist-put copy :cache-read
                             (harness-openrouter--price-per-token (nth 2 prices))))
              record))
          records))

(defun demo--live-records ()
  "Return the endpoint records of the live catalogue, read-only.
`HARNESS_DEMO_OFFLINE' in the environment skips the network."
  (unless (getenv "HARNESS_DEMO_OFFLINE")
    (with-temp-buffer
      (url-insert-file-contents demo-catalogue-url)
      (harness-openrouter-parse-endpoints
       (json-parse-string (buffer-string) :object-type 'plist
                          :array-type 'list :null-object nil)))))

(defun demo-run ()
  "Print every situation, live where it can be and stock otherwise."
  (let ((live (ignore-errors (demo--live-records)))
        (policy (demo-policy)))
    (if live
        (princ (format "live catalogue: %d endpoints for %s\n" (length live) demo-model))
      (princ "live catalogue unreadable; the offline cases follow\n"))
    ;; 1. Today, as published.
    (when live (demo-show "1. today, as published (live catalogue)" policy live))
    ;; The rest run on a stock catalogue, so the demo says the same thing
    ;; with no network: DeepInfra at its promo and at its 51%-off list.
    (let ((stock (demo-stock)))
      (demo-show "2. DeepInfra's 51% promo ended (list rate)" policy
                 (demo-reprice stock "deepinfra/fp8" '("0.0000002" "0.0000006" "0.000000006")))
      (demo-show "3. both vetted endpoints above the owner price" policy
                 (demo-reprice (demo-reprice stock "cohere/fp8"
                                             '("0.0000004" "0.0000015" "0.000000008"))
                               "deepinfra/fp8" '("0.00000035" "0.0000014" "0.000000007")))
      (demo-show "4. DeepInfra priced by the window of the week" policy
                 (mapcar (lambda (record)
                           (if (equal (plist-get record :tag) "deepinfra/fp8")
                               (plist-put (copy-sequence record) :overrides
                                          '((:utc_start 100 :utc_end 400
                                                       :prompt "0.0000002"
                                                       :completion "0.0000006")))
                             record))
                         stock))
      ;; 5. A pin made under the peak ceiling, then the policy's ceiling
      ;; lowered under it.  The pin is still fresh and still listed; what
      ;; changed is the price the policy allows, and that is enough.
      (let ((pinned (demo-route policy "deepinfra/fp8")))
        (demo-show-pin "5. ceiling lowered to 0.001 under an existing pin"
                       (demo-policy :owner-price
                                    (plist-put (copy-sequence (plist-get policy :owner-price))
                                               :prompt 0.001))
                       pinned nil)
        ;; 6. A refresh that lists nothing at all: not "no refresh", but a
        ;; catalogue saying this model has no endpoints, which cannot be
        ;; evidence that the pinned endpoint still exists.
        (demo-show-pin "6. the fresh catalogue lists no endpoint at all"
                       policy pinned (list :at (float-time) :endpoints nil))))))

(provide 'demo)
;;; demo.el ends here
