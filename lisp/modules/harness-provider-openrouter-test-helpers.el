;;; harness-provider-openrouter-test-helpers.el --- Fixtures for the OpenRouter suites  -*- lexical-binding: t; -*-

;;; Commentary:

;; The fixtures two suites share: the fake HTTP layer that records every
;; request and replays a canned answer, the catalogue as OpenRouter
;; returns it, the policy a test starts from, and the session stubs the
;; dispatch tests use.  They live here rather than in one of the suites
;; so that the suite which runs a real turn (with the retry and fallback
;; modules loaded) can use the same fixtures without loading the other
;; suite's tests too.  This file defines no test, so `scripts/test.sh'
;; does not run it as a suite.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-provider-openrouter)
(require 'harness-session)

;;;; Fake HTTP layer

(defvar harness-openrouter-test--requests nil
  "Requests the fake saw, newest first: (:url :method :headers :json :args).")

(defvar harness-openrouter-test--responses nil
  "Alist of (URL-REGEXP . RESPONSE) the fake replays.
RESPONSE is (:status N :chunks (STRING…)) for a streamed reply,
\(:status N :body STRING) for a plain one, or (:error ERR).")

(defvar harness-openrouter-test--completion-script nil
  "Function of a completion's number returning its response, or nil.
When set, it answers the `chat/completions' requests instead of
`harness-openrouter-test--responses', so a test can make the first step
fail and the next answer.")

(defvar harness-openrouter-test--completions 0
  "How many completion requests the fake has served in this test.")

(defvar harness-openrouter-test--hold nil
  "URL regexps whose requests the fake starts but never answers.
A matching request is recorded and its handle returned, while its
callback and chunk reader stay in `harness-openrouter-test--requests'
for a test to call itself -- which is how a test cancels a request that
has reached the transport and has not been answered.")

(defvar harness-openrouter-test--hold-catalogue nil
  "When non-nil, catalogue requests are recorded but left unanswered.
The test then answers one with `harness-openrouter-test--answer-catalogue'
or fails it with `harness-openrouter-test--fail-catalogue', which call
the production callback.  That is how a test edits the policy while a
reading is genuinely in flight: the real completion callbacks run, with
no network.")

(defvar harness-openrouter-test--held-catalogues nil
  "The ARGS of the catalogue requests the fake is holding, oldest first.")

(defun harness-openrouter-test--fake-request (url &rest args)
  "Record a request to URL with ARGS and replay the matching canned response."
  (let* ((response (or (and harness-openrouter-test--completion-script
                            (string-match-p "chat/completions" url)
                            (funcall harness-openrouter-test--completion-script
                                     (cl-incf harness-openrouter-test--completions)))
                       (cdr (cl-find-if (lambda (cell) (string-match-p (car cell) url))
                                        harness-openrouter-test--responses))))
         (held (cl-find-if (lambda (pattern) (string-match-p pattern url))
                           harness-openrouter-test--hold))
         (handle (make-harness-http-handle :url url :callback (plist-get args :callback)
                                           :on-chunk (plist-get args :on-chunk)
                                           :started (float-time))))
    (push (list :url url :method (or (plist-get args :method) "GET")
                :headers (plist-get args :headers) :json (plist-get args :json) :args args)
          harness-openrouter-test--requests)
    (cond
     ((and harness-openrouter-test--hold-catalogue
           (string-match-p "/endpoints\\'" url))
      (setq harness-openrouter-test--held-catalogues
            (append harness-openrouter-test--held-catalogues (list args))))
     (held nil)
     (t
      (harness-run-soon
       (lambda ()
         (unless (harness-http-handle-cancelled handle)
           (let ((status (or (plist-get response :status) 200)))
             (when (plist-get args :on-headers)
               (funcall (plist-get args :on-headers) status (plist-get response :headers)))
             (cond
              ((plist-get response :error)
               (funcall (plist-get args :callback) nil nil "" (plist-get response :error)))
              ((plist-get args :on-chunk)
               (dolist (chunk (or (plist-get response :chunks)
                                  (and (plist-get response :body) (list (plist-get response :body)))))
                 (funcall (plist-get args :on-chunk) chunk))
               (funcall (plist-get args :callback) status nil "" nil))
              (t (funcall (plist-get args :callback) status nil
                          (or (plist-get response :body) "") nil)))))))))
    handle))

(defun harness-openrouter-test--take-held-catalogue ()
  "Return the ARGS of the oldest held catalogue request, and forget it."
  (let ((args (car harness-openrouter-test--held-catalogues)))
    (setq harness-openrouter-test--held-catalogues
          (cdr harness-openrouter-test--held-catalogues))
    args))

(defun harness-openrouter-test--answer-catalogue (&optional body)
  "Answer the oldest held catalogue request with BODY, from the fixture.
The production callback runs, as the HTTP layer would call it."
  (let ((args (harness-openrouter-test--take-held-catalogue)))
    (funcall (plist-get args :callback) 200 nil
             (or body (harness-openrouter-test--catalogue-json)) nil)))

(defun harness-openrouter-test--fail-catalogue (&optional error)
  "Fail the oldest held catalogue request with ERROR, as curl would."
  (let ((args (harness-openrouter-test--take-held-catalogue)))
    (funcall (plist-get args :callback) nil nil ""
             (or error (list 'error "connection reset by peer")))))

(defmacro harness-openrouter-test-with-fake (responses &rest body)
  "Run BODY with `harness-http-request' replaced by a fake serving RESPONSES.
Requests matching `harness-openrouter-test--hold' are started but left
unanswered, so a test can cancel one mid-transport."
  (declare (indent 1))
  `(let ((harness-openrouter-test--requests nil)
         (harness-openrouter-test--responses ,responses)
         (harness-openrouter-test--hold nil)
         (harness-openrouter-test--hold-catalogue nil)
         (harness-openrouter-test--held-catalogues nil)
         (auth-sources nil))
     (cl-letf (((symbol-function 'harness-http-request) #'harness-openrouter-test--fake-request))
       ,@body)))

(defun harness-openrouter-test--sse (&rest payloads)
  "Return one SSE chunk string holding PAYLOADS (strings or plists)."
  (mapconcat (lambda (p) (format "data: %s\n\n" (if (stringp p) p (harness-json-encode p))))
             payloads ""))

(defun harness-openrouter-test--approx (a b)
  "Non-nil when numbers A and B agree to a millionth."
  (< (abs (- a b)) 1e-6))

(defun harness-openrouter-test--done-events (events)
  "Return the `done' events of EVENTS."
  (cl-remove-if-not (lambda (e) (eq (plist-get e :type) 'done)) events))

(defun harness-openrouter-test--complete* (endpoint request)
  "Complete REQUEST directly at ENDPOINT, bypassing the provider bus.
Return its events, oldest first.  Used for endpoints that are not
OpenRouter's, where the generic transport is the thing under test."
  (let ((events nil))
    (harness-openai--complete
     endpoint (plist-put (copy-sequence request)
                         :on-event (lambda (e) (push e events))))
    (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type)))) 5 "done")
    (nreverse events)))

(defun harness-openrouter-test--run (request)
  "Complete REQUEST at the OpenRouter provider; return its events, oldest first."
  (let ((events nil))
    (harness-call 'provider/complete
                  (plist-put (copy-sequence request)
                             :on-event (lambda (e) (push e events))))
    (harness-test-wait (lambda () (harness-openrouter-test--done-events events)) 5 "done")
    (nreverse events)))

;;;; The catalogue, as OpenRouter returns it (2026-11-10, fetched, trimmed)

(defconst harness-openrouter-test-model "deepseek/deepseek-v4.1-flash-1017")

(defun harness-openrouter-test--endpoint-json (tag provider &rest overrides)
  "Return one catalogue endpoint as OpenRouter lists it.
TAG and PROVIDER are the endpoint's tag and provider name; OVERRIDES
replace the standard-tier default prices, discount and tier."
  (let ((pricing (or (plist-get overrides :pricing)
                     '(:prompt "0.000000098" :completion "0.000000294"
                       :input_cache_read "0.00000000294" :discount 0.51))))
    (list :name (format "%s | %s" provider harness-openrouter-test-model)
          :model_id (or (plist-get overrides :model) harness-openrouter-test-model)
          :provider_name provider
          :tag tag
          :service_tier (plist-get overrides :tier)
          :quantization (or (plist-get overrides :quantization) "fp8")
          :context_length 1048576
          ;; What the endpoint takes, as OpenRouter lists it: the ones
          ;; the tests' endpoints take unless OVERRIDES says otherwise
          ;; (`:supported-parameters' nil is an endpoint that lists none).
          :supported_parameters (if (plist-member overrides :supported-parameters)
                                    (plist-get overrides :supported-parameters)
                                  '("tools" "response_format" "structured_outputs"))
          :pricing pricing)))

(defun harness-openrouter-test--catalogue-json (&rest endpoints)
  "Return a catalogue answer holding ENDPOINTS (defaults: DeepInfra, Cohere)."
  (harness-json-encode
   (list :data
         (list :id harness-openrouter-test-model
               :name "DeepSeek: DeepSeek V4.1 Flash 1017"
               :endpoints
               (apply #'vector
                      (or endpoints
                          (list (harness-openrouter-test--endpoint-json
                                 "deepinfra/fp8" "DeepInfra")
                                (harness-openrouter-test--endpoint-json
                                 "cohere/fp8" "Cohere"
                                 :pricing '(:prompt "0.00000015" :completion "0.0000005"
                                            :input_cache_read "0.000000003"
                                            :discount 0)))))))))

(defun harness-openrouter-test--catalogue-url-regexp ()
  "Return a regexp matching this model's catalogue URL."
  (concat (regexp-quote harness-openrouter-test-model) "/endpoints\\'"))

(defconst harness-openrouter-test--max-price
  '(:prompt 0.15 :completion 0.60 :cache-read 0.003)
  "A test policy's spending limits, in USD per million tokens.
They are the most this policy pays per component; the prices they are
compared against come from the catalogue fixture, never from here.  The
numbers are the example configuration's, and a test value: no provider's
rate is written into a policy.")

(defun harness-openrouter-test-policy (&rest overrides)
  "Return a complete routing policy, with OVERRIDES applied.
The limits are `harness-openrouter-test--max-price', so both allowed
endpoints fit and the cheaper one is chosen.  OVERRIDES replace
top-level keys, so `:providers' and `:max-price' can be swapped
wholesale."
  (let ((policy (list :enabled t
                      :model harness-openrouter-test-model
                      :providers '("DeepInfra" "Cohere")
                      :max-price (copy-sequence harness-openrouter-test--max-price)
                      :freshness 300)))
    (while overrides
      (setq policy (plist-put policy (car overrides) (cadr overrides))
            overrides (cddr overrides)))
    policy))

(defmacro harness-openrouter-test-with-policy (policy &rest body)
  "Run BODY with the routing POLICY in place and the module's cache empty."
  (declare (indent 1))
  `(let ((harness-openrouter-routing ,policy)
         (harness-openrouter--catalogue (make-hash-table :test 'equal))
         (harness-openrouter--fetching (make-hash-table :test 'equal))
         (harness-openai--models-cache (make-hash-table :test 'eq)))
     ,@body))

(defun harness-openrouter-test--chain-answer ()
  "Return the fake response of a successful OpenRouter answer."
  (apply #'harness-openrouter-test--stream-body
         (harness-openrouter-test--answer-chunks)))

(defun harness-openrouter-test--chain-http (status &optional body)
  "Return the fake response of an HTTP STATUS with BODY."
  (list :status status
        :body (or body (harness-json-encode
                        (list :error (list :code status :message "failed"))))))

(defun harness-openrouter-test--chain-error (&optional _kind text)
  "Return the fake response of a transport failure, with TEXT.
KIND is accepted and ignored, so a test reads as what it means."
  (list :error (list 'error (or text "connection reset by peer"))))

(defun harness-openrouter-test--stream-body (&rest chunks)
  "Return a fake streamed completion response carrying CHUNKS.
Each chunk is a plist; a final usage chunk and `[DONE]' are added."
  `(:chunks (,(apply #'harness-openrouter-test--sse
                     (append chunks
                             (list '(:choices () :usage (:prompt_tokens 10 :completion_tokens 2))
                                   "[DONE]"))))))

(defun harness-openrouter-test--answer-chunks (&rest extra)
  "Return the chunks of a successful answer, with EXTRA plists appended.
The answer names its model, its provider and the standard tier, as
OpenRouter's answers do."
  (append (list (list :id "gen-1" :model harness-openrouter-test-model
                      :provider "DeepInfra" :service_tier "default"
                      :choices (vector (list :index 0 :delta (list :content "hello")
                                             :finish_reason nil))))
          extra
          (list (list :id "gen-1" :model harness-openrouter-test-model
                      :provider "DeepInfra" :service_tier "default"
                      :choices (vector (list :index 0 :delta (list) :finish_reason "stop"))))))

;;;; Dispatch: a new session, an existing pin, and refusals

(defmacro harness-openrouter-test-with-session (session &rest body)
  "Run BODY with the session bus answering for SESSION.
`session/get' answers SESSION, `session/set-ext' records what was set in
`harness-openrouter-test--stored', hints are collected in
`harness-openrouter-test--hints', and every other call goes to the real
bus, so `provider/complete' still works."
  (declare (indent 1))
  `(let ((harness-openrouter-test--stored nil)
         (harness-openrouter-test--hints nil)
         (harness-openrouter-test--session-value ,session)
         (real (symbol-function 'harness-call)))
     (cl-letf (((symbol-function 'harness-call)
                (lambda (method &rest args)
                  (pcase method
                    ('session/get harness-openrouter-test--session-value)
                    ('session/exists-p t)
                    ('session/set-ext
                     (setq harness-openrouter-test--stored (nth 2 args)
                           harness-openrouter-test--session-value
                           (plist-put (copy-sequence harness-openrouter-test--session-value)
                                      :ext (list :openrouter-route (nth 2 args))))
                     args)
                    ('session/hint
                     (push (nth 1 args) harness-openrouter-test--hints)
                     args)
                    (_ (apply real method args))))))
       ,@body)))

(defvar harness-openrouter-test--stored nil
  "The route a stubbed `session/set-ext' last recorded.")

(defvar harness-openrouter-test--hints nil
  "Hints a stubbed `session/hint' collected, newest first.")

(defvar harness-openrouter-test--session-value nil
  "The session a stubbed `session/get' answers.")

(defun harness-openrouter-test--session (id &optional ext)
  "Return a session plist with ID and EXT, as the bus would return one."
  (list :id id :name id :kind 'main
        :model (format "openrouter:%s" harness-openrouter-test-model)
        :status 'idle :ext ext))

(defun harness-openrouter-test--catalogue-response ()
  "Return the fake response serving this model's catalogue."
  `(,(harness-openrouter-test--catalogue-url-regexp)
    . (:body ,(harness-openrouter-test--catalogue-json))))

(defun harness-openrouter-test--completion-response ()
  "Return the fake response serving a successful pinned completion."
  (cons "chat/completions"
        (apply #'harness-openrouter-test--stream-body
               (harness-openrouter-test--answer-chunks))))

(defun harness-openrouter-test--answer-from (provider)
  "Return a completion response whose answer names PROVIDER as served it.
The chunks are `harness-openrouter-test--answer-chunks' with the
provider replaced, so a test can pin one provider and answer as it."
  (let* ((chunks (harness-openrouter-test--answer-chunks))
         (chunks (mapcar (lambda (chunk)
                           (if (plist-member chunk :provider)
                               (plist-put (copy-sequence chunk) :provider provider)
                             chunk))
                         chunks)))
    (cons "chat/completions"
          (apply #'harness-openrouter-test--stream-body chunks))))

(defun harness-openrouter-test--route (&optional overrides)
  "Return a pinned route for this model, with OVERRIDES applied."
  (let ((route (list :model harness-openrouter-test-model
                     :slug "deepinfra/fp8"
                     :provider "DeepInfra" :tier "default" :quantization "fp8"
                     :prompt 0.098 :completion 0.294 :cache-read 0.00294
                     :discount 0.51 :catalogue-at (float-time)
                     :selected-at (float-time) :basis "chosen")))
    (while overrides
      (setq route (plist-put route (car overrides) (cadr overrides))
            overrides (cddr overrides)))
    route))

(defun harness-openrouter-test--routed-body (policy route request)
  "Return REQUEST's wire body as `harness-openrouter--dispatch' would send it.
POLICY is the checked policy and ROUTE the pinned one; both are what the
dispatch binds around the transport, so the body is built exactly as it
is for a request that left the dispatch."
  (let ((harness-openrouter--sending policy))
    (harness-openai--body
     (harness-openrouter--endpoint) harness-openrouter-test-model
     (plist-put (copy-sequence request) :openrouter-route route))))

(defun harness-openrouter-test--request (&optional session)
  "Return a request for the policy's model in SESSION."
  (list :model (format "openrouter:%s" harness-openrouter-test-model)
        :session (or session (harness-openrouter-test--session "s-1"))
        :messages '((:role user :content ((:type "text" :text "hi"))))))

(provide 'harness-provider-openrouter-test-helpers)
;;; harness-provider-openrouter-test-helpers.el ends here
