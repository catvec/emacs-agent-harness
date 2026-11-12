;;; demo.el --- Show price-aware OpenRouter selection  -*- lexical-binding: t; -*-

;;; Commentary:

;; Prints what the policy decides for this checkpoint under Noah's rule --
;; sort by increasing price, drop anything dearer than the configured
;; maximum, never leave the allowed providers -- in six situations:
;;
;;   1. today, from the live catalogue (read-only: the endpoints
;;      listing, no completion request, no credential);
;;   2. the same catalogue with DeepInfra's 51% promo ended;
;;   3. both endpoints above the configured maximum price;
;;   4. an endpoint whose rate varies by the window of the week;
;;   5. a session already pinned when the maximum is lowered under it;
;;   6. a session already pinned when the fresh catalogue is empty;
;;   7. a policy disabled while a request waits for the catalogue;
;;   8. a cache-read maximum lowered while a request waits for it;
;;   9. the attempt budget and the time bound, which used to be counted
;;      in the wrong place -- a policy of one attempt made four requests,
;;      and a one-second bound slept a minute before sending again.
;;
;; Cases 5 and 6 are the ones that used to slip through: a pinned session
;; was checked for a new selection but dispatched anyway.  Cases 7 and 8
;; are the same shape across the asynchronous catalogue read: the request
;; was prepared under one policy and the policy changed before the answer
;; arrived.  They now stop with the reason, and nothing reaches the
;; transport, which is what the blocks print.
;;
;; Run it with demo/openrouter-pinning/demo.sh.  It never sends a
;; completion and never sets `harness-openrouter-routing': it calls the
;; selector and the dispatch check directly, so it changes nothing in a
;; Harness.  Every price it compares comes from the catalogue; the
;; policy below holds only the spending limits, and where their figures
;; come from is the operator's comment in config.el, not something the
;; harness reads.  Its retry numbers are not a policy's either: they are
;; the shared retry layer's options, which one place sets for every
;; provider.

;;; Code:

(add-to-list 'load-path (expand-file-name "../../lisp"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path (expand-file-name "../../lisp/modules"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(require 'cl-lib)
(require 'harness-util)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-provider-openrouter)

(defconst demo-model "deepseek/deepseek-v4.1-flash-1017"
  "The exact checkpoint the policy is for.")

(defconst demo-catalogue-url
  (concat "https://openrouter.ai/api/v1/models/" demo-model "/endpoints")
  "Read-only listing of the endpoints that serve DEMO-MODEL.")

(defconst demo-providers '("DeepInfra" "Cohere")
  "The providers the demo's policy allows, by their catalogue names.")

(defun demo-policy (&rest overrides)
  "Return the documented policy with OVERRIDES, dated now.
It is the simple plist: the allowed providers, the most the operator is
willing to pay per component, and a freshness bound.  Nothing in it
claims what a provider charges, and nothing in it decides how a request
is retried: that is the shared retry layer's, one place for every
provider."
  (let ((policy (list :enabled t
                      :model demo-model
                      :providers (copy-sequence demo-providers)
                      :max-price (list :prompt 0.15 :completion 0.60
                                       :cache-read 0.003)
                      :freshness 900)))
    (while overrides
      (setq policy (plist-put policy (car overrides) (cadr overrides))
            overrides (cddr overrides)))
    policy))

(defun demo--per-million (price)
  "Return PRICE, an exact per-token decimal, as US dollars per million."
  (when (consp price) (harness-openrouter--usd-per-million price)))

(defun demo-show (label policy records)
  "Print what POLICY decides from RECORDS, under LABEL."
  (let ((decision (harness-openrouter-select policy records (float-time)))
        (limits (harness-openrouter--limits policy)))
    (princ (format "\n=== %s\n" label))
    (dolist (candidate (harness-openrouter--candidates policy records))
      (let* ((standing (harness-openrouter--standing candidate limits))
             (record (plist-get standing :record)))
        (princ (format "  %-10s %-9s %s\n"
                       (plist-get candidate :provider)
                       (plist-get standing :standing)
                       (if record
                           (format "%s  prompt %7.4f  completion %7.4f  cache-read %.6f  (USD/1M)"
                                   (plist-get record :tag)
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

(defun demo-route (policy provider)
  "Return the route a pin on PROVIDER would have recorded under POLICY.
It is what `harness-openrouter--route-plist' stores, read back from the
decision, so the demo's pin is the shape the module really keeps."
  (let* ((records (demo-stock))
         (narrow (plist-put (copy-sequence policy) :providers (list provider)))
         (decision (harness-openrouter-select narrow records (float-time))))
    (when (plist-get decision :ok)
      (harness-openrouter--route-plist decision))))

(defun demo-stock-records (prompt completion cache-read provider tag)
  "Return a catalogue record for PROVIDER at PROMPT, COMPLETION and CACHE-READ.
TAG is the endpoint's catalogue tag.  The prices are the decimal strings
a catalogue carries and go through the module's own record reader, so the
demo shows the exact decimals the selector compares rather than a test
shortcut."
  (harness-openrouter--endpoint-record
   (list :name provider
         :model_id demo-model
         :provider_name provider
         :tag tag
         :quantization "fp8"
         :context_length 1048576
         :pricing (list :prompt prompt
                        :completion completion
                        :input_cache_read cache-read
                        :discount 0))))

(defun demo-stock ()
  "Return the two allowed endpoints at the rates published on 2026-11-10.
DeepInfra is at its 51%-off promotional rate and Cohere at its list rate.
The figures are the catalogue's, and the demo's policy never restates
them."
  (list (demo-stock-records "0.000000098" "0.000000294" "0.00000000294"
                            "DeepInfra" "deepinfra/fp8")
        (demo-stock-records "0.00000015" "0.0000005" "0.000000003"
                            "Cohere" "cohere/fp8")))

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

;;;; An in-flight request whose policy changes

(defvar demo--sent nil
  "What the demo's fake transport was asked to send, newest first.")

(defvar demo--held nil
  "The completion callback of the catalogue request the fake is holding.")

(defun demo--fake-http (url &rest args)
  "Record a request to URL; hold the catalogue's, refuse to send completions.
This is a transport that cannot reach anything: the demo's point is what
the module decides before a transport is called at all."
  (if (string-match-p "/endpoints\\'" url)
      (setq demo--held (plist-get args :callback))
    (push (list :url url :json (plist-get args :json)) demo--sent))
  (make-harness-http-handle :url url :started (float-time)))

(defun demo--in-flight (label change)
  "Print whether a new session's request survives CHANGE while in flight.
CHANGE is a function of no arguments that edits the configured policy
after the catalogue request is made and before it answers.  The request
goes through the real completion callbacks and a fake transport; the
count printed is what reached the transport."
  (setq demo--sent nil
        demo--held nil)
  (let* ((harness-openrouter-routing (demo-policy))
         (harness-openrouter--catalogue (make-hash-table :test 'equal))
         (harness-openrouter--fetching (make-hash-table :test 'equal))
         (session (list :id "demo-session" :name "demo-session" :kind 'main
                        :status 'idle
                        :model (format "openrouter:%s" demo-model)))
         (events nil)
         (real (symbol-function 'harness-call)))
    (princ (format "\n=== %s\n" label))
    (cl-letf (((symbol-function 'harness-http-request) #'demo--fake-http)
              ((symbol-function 'harness-call)
               (lambda (method &rest args)
                 (pcase method
                   ('session/get session)
                   ('session/set-ext (plist-put (copy-sequence session)
                                                :ext (list :openrouter-route (nth 2 args))))
                   ('session/hint args)
                   ('session/exists-p t)
                   (_ (apply real method args))))))
      (harness-openrouter--complete
       (list :model (format "openrouter:%s" demo-model)
             :session session
             :messages '((:role user :content ((:type "text" :text "hi"))))
             :on-event (lambda (e) (push e events))))
      (princ "  request prepared under the enabled policy; catalogue in flight\n")
      (unless demo--held
        (error "the demo's fake transport was not asked for the catalogue"))
      (funcall change)
      (princ "  policy edited; the catalogue answers now\n")
      (funcall demo--held 200 nil (demo-catalogue-json) nil))
    (let ((done (car (cl-remove-if-not (lambda (e) (eq (plist-get e :type) 'done))
                                       events))))
      (princ (format "  -> %s\n"
                     (if done
                         (format "STOP (%s): %s" (plist-get done :error-kind)
                                 (plist-get done :error))
                       "SEND")))
      (princ (format "  completions that reached the transport: %d\n"
                     (length demo--sent))))))

;;;; One attempt budget, on the wire

(defun demo-show-retry-budget ()
  "Print what the shared retry layer decides, and where it is enforced.
Two numbers decide a repeat: how many sends the request has made and how
long ago its first one started.  Both are the shared layer's, and both
are counted where the request is sent, so the demo reads them where the
dispatch does."
  (let* ((seconds 1)
         (most 1)
         (asked 3600)
         (session (list :id "demo" :model (format "openrouter:%s" demo-model))))
    (princ "\n=== 9. one attempt budget, and a wait that cannot fit in it\n")
    (princ (format "  shared bounds: harness-retry-max-attempts %d, harness-retry-max-seconds %d\n"
                   most seconds))
    ;; One request may make its first send and `most' more; a send past
    ;; that is refused before it is made, whatever the transport's own
    ;; retry count would have done.
    (let* ((harness-retry-max-attempts most)
           (harness-retry-max-seconds seconds)
           (harness-retry-policy-functions
            (list (lambda (s) (when (equal (plist-get s :id) "demo")
                                (list :owner "OpenRouter" :count-sends t)))))
           (request (list :session session)))
      (let ((first (harness-retry-send request)))
        (princ (format "  the first send: %s\n"
                       (or (cdr (plist-get first :refusal)) "allowed")))
        (setq request (plist-get first :request)))
      ;; A retry of it, which is a send of the same request.
      (setf (harness-retry--request-retrying (harness-retry-state-of request)) t)
      (let ((again (harness-retry-send request)))
        (princ (format "  the retry after it: %s\n"
                       (or (cdr (plist-get again :refusal)) "allowed")))
        (setq request (plist-get again :request)))
      ;; And one more: past what one request may send.
      (setf (harness-retry--request-retrying (harness-retry-state-of request)) t)
      (princ (format "  the next: %s\n"
                     (or (cdr (plist-get (harness-retry-send request) :refusal)) "allowed")))
      ;; And a second request of the same session -- a recap beside the
      ;; step -- has a budget of its own, untouched by the first one's.
      (let ((recap (harness-retry-send (list :session session))))
        (princ (format "  a recap of the same session starts at: %d send(s) of its own\n"
                       (harness-retry--request-count
                        (harness-retry-state-of (plist-get recap :request))))))
      ;; A Retry-After of an hour under a one-second bound: the wait is
      ;; compared with what is left before it is taken.
      (let* ((harness-retry-delay 1.0)
             (harness-retry-max-delay 30.0)
             (harness-retry-jitter 0)
             (plan (harness-retry-wait-plan 1 (list :retry-after asked) 0)))
        (princ (format "  the provider asks for %d s, the bound allows %d s from the first send\n"
                       asked seconds))
        (princ (format "  a retry after the %s it would wait: %s\n"
                       (harness-retry-duration (plist-get plan :delay))
                       (if (plist-get plan :fit)
                           "allowed"
                         "STOP before waiting, and before sending"))))
      ;; And the lower layer is asked for nothing of its own for this
      ;; session, so the shared count is the only one.
      (princ (format "  the transport's own replays for this session: %d\n"
                     (harness-retry-transport-retries (list :session session))))
      ;; A wait is drawn once: the value checked is the value waited.
      (let ((draws 0))
        (cl-letf (((symbol-function 'random) (lambda (&optional _) (cl-incf draws) 0)))
          (harness-retry-wait-plan 1 (list :error "reset") 0))
        (princ (format "  random draws to decide and take one wait: %d\n" draws))))))

(defun demo-catalogue-json ()
  "Return a catalogue answer for the demo's two endpoints, at stock rates."
  (harness-json-encode
   (list :data
         (list :id demo-model
               :endpoints (vector
                           (list :name "DeepInfra"
                                 :model_id demo-model
                                 :provider_name "DeepInfra"
                                 :tag "deepinfra/fp8"
                                 :quantization "fp8"
                                 :pricing '(:prompt "0.000000098"
                                            :completion "0.000000294"
                                            :input_cache_read "0.00000000294"))
                           (list :name "Cohere"
                                 :model_id demo-model
                                 :provider_name "Cohere"
                                 :tag "cohere/fp8"
                                 :quantization "fp8"
                                 :pricing '(:prompt "0.00000015"
                                            :completion "0.0000005"
                                            :input_cache_read "0.000000003")))))))

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
      (demo-show "3. both allowed endpoints above the maximum price" policy
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
      ;; 5. A pin made within the limits, then the limit lowered under it.
      ;; The pin is still fresh and still listed; what changed is what the
      ;; policy is willing to pay, and that is enough.
      (let ((pinned (demo-route policy "DeepInfra")))
        (demo-show-pin "5. prompt limit lowered to 0.001 under an existing pin"
                       (demo-policy :max-price
                                    (plist-put (copy-sequence (plist-get policy :max-price))
                                               :prompt 0.001))
                       pinned nil)
        ;; 6. A refresh that lists nothing at all: not "no refresh", but a
        ;; catalogue saying this model has no endpoints, which cannot be
        ;; evidence that the pinned endpoint still exists.
        (demo-show-pin "6. the fresh catalogue lists no endpoint at all"
                       policy pinned (list :at (float-time) :endpoints nil))))
    ;; 7 and 8. The policy changes while a request waits for the catalogue.
    ;; These go through the real completion callbacks and a transport that
    ;; records instead of sending.
    (demo--in-flight
     "7. the policy disabled while the catalogue is in flight"
     (lambda ()
       (setq harness-openrouter-routing
             (plist-put (copy-sequence harness-openrouter-routing) :enabled nil))))
    (demo--in-flight
     "8. the cache-read maximum lowered below the API's rate while in flight"
     (lambda ()
       (setq harness-openrouter-routing
             (plist-put (copy-sequence harness-openrouter-routing) :max-price
                        '(:prompt 0.15 :completion 0.60 :cache-read 0.002)))))
    (demo-show-retry-budget)))

(provide 'demo)
;;; demo.el ends here
