;;; harness-provider.el --- Completion provider registry and canonical format -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; Providers are generic: each one translates its wire format into the
;; canonical shapes defined here, so the agent loop never learns
;; provider-specific details.
;;
;; Canonical model id:  "provider/model", e.g. "openai/gpt-5".
;;
;; Canonical message (plist): :role ("user" "assistant" "tool") and
;; :content (vector of parts).  Parts:
;;
;;   (:type "text"       :text "...")
;;   (:type "image"      :mime-type "image/png" :data "<base64>")
;;   (:type "audio"      :mime-type "audio/wav" :data "<base64>")
;;   (:type "thinking"   :text "...")
;;   (:type "tool-call"  :id "call_1" :name "read" :arguments <plist>)
;;   (:type "tool-result" :tool-call-id "call_1"
;;                        :content (vector parts) :is-error bool)
;;
;; Canonical tool spec: (:name :description :input-schema <JSON Schema>).
;;
;; Canonical completion result (the value `complete' resolves to):
;;
;;   (:text "..." :thinking "..." :tool-calls (vector (:id :name :arguments))
;;    :stop-reason "end_turn"|"tool_use"|"max_tokens"|"refusal"
;;    :usage (:input-tokens N :output-tokens N :cache-read N :cache-write N))
;;
;; Streaming is reported through the request's :on-text, :on-thought and
;; :on-tool-call callbacks while the deferred is pending.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'harness-core)

(define-error 'harness-provider-error "Completion provider error" 'harness-error)

(cl-defstruct (harness-provider (:constructor harness-provider--make))
  name
  description
  capabilities                ; list of symbols, informational
  models-fn                   ; &optional -> list or deferred of model plists
  complete-fn                 ; request plist -> deferred of result plist
  price-fn                    ; model + usage -> plist (:amount :currency) or nil
  token-fn                    ; model + text -> integer or nil
  config)

(defvar harness-provider--registry (make-hash-table :test #'equal)
  "Provider name (string) -> `harness-provider'.")

(defun harness-provider-register (name &rest properties)
  "Register provider NAME with PROPERTIES.

  :description  one line shown in model switchers
  :capabilities list of symbols: streaming, tool-calls, image-input,
                audio-input, thinking, models-list, pricing, token-count
  :models       function returning model plists, or a static list
  :complete     function taking a request plist, returning a deferred
  :price        function (MODEL USAGE) -> (:amount F :currency S)
  :tokens       function (MODEL TEXT) -> integer
  :config       arbitrary provider configuration

Returns the provider."
  (declare (indent 1))
  (let ((provider (harness-provider--make
                   :name name
                   :description (plist-get properties :description)
                   :capabilities (plist-get properties :capabilities)
                   :models-fn (plist-get properties :models)
                   :complete-fn (plist-get properties :complete)
                   :price-fn (plist-get properties :price)
                   :token-fn (plist-get properties :tokens)
                   :config (plist-get properties :config))))
    (when harness-core--current-module
      (harness-core-add-module-cleanup
       harness-core--current-module (lambda () (harness-provider-unregister name))))
    (puthash name provider harness-provider--registry)
    provider))

(defun harness-provider-unregister (name)
  "Remove provider NAME from the registry."
  (remhash name harness-provider--registry))

(defun harness-provider-get (name)
  "Return provider NAME, or nil."
  (gethash name harness-provider--registry))

(defun harness-provider-list ()
  "Return all registered providers, sorted by name."
  (sort (hash-table-values harness-provider--registry)
        (lambda (a b) (string< (harness-provider-name a) (harness-provider-name b)))))

(defun harness-provider-resolve (model-id)
  "Split MODEL-ID (\"provider/model\") into (PROVIDER-NAME . MODEL).
Signals `harness-user-error' when the id has no provider prefix."
  (let ((slash (string-match "/" (or model-id ""))))
    (unless slash
      (signal 'harness-user-error
              (list (format "Model id must be \"provider/model\": %s" model-id))))
    (cons (substring model-id 0 slash)
          (substring model-id (1+ slash)))))

(defun harness-provider-for-model (model-id)
  "Return the provider object for MODEL-ID or signal."
  (let* ((resolved (harness-provider-resolve model-id))
         (provider (harness-provider-get (car resolved))))
    (unless provider
      (signal 'harness-user-error
              (list (format "No provider named %s" (car resolved)))))
    provider))

(defun harness-provider-model-name (model-id)
  "Return the model part of MODEL-ID."
  (cdr (harness-provider-resolve model-id)))

;;; Model listing

(defun harness-provider--normalize-models (provider models)
  "Prefix MODELS from PROVIDER with the provider name and fill in defaults."
  (mapcar (lambda (model)
            (let* ((name (or (plist-get model :model) (plist-get model :name) "model"))
                   (id (or (plist-get model :id)
                           (format "%s/%s" (harness-provider-name provider) name))))
              (append (list :id id
                            :provider (harness-provider-name provider)
                            :name (or (plist-get model :name) name))
                      (harness-plist-omit-nil
                       (list :description (plist-get model :description)
                             :context-window (or (plist-get model :context-window)
                                                 (plist-get model :contextWindow))
                             :input-price (or (plist-get model :input-price)
                                              (plist-get model :inputPrice))
                             :output-price (or (plist-get model :output-price)
                                               (plist-get model :outputPrice))
                             :cache-read-price (plist-get model :cache-read-price)
                             :thinking (plist-get model :thinking))))))
          (append models nil)))

(defun harness-provider--models-of (provider)
  "Return a deferred resolving to PROVIDER's normalized model list."
  (let ((models (when (harness-provider-models-fn provider)
                  (let ((source (harness-provider-models-fn provider)))
                    (if (functionp source) (funcall source) source)))))
    (if (harness-deferred-p models)
        (harness-deferred-then
         models (lambda (value) (harness-provider--normalize-models provider value)))
      (let ((deferred (harness-deferred-new)))
        (harness-deferred-resolve deferred
                                  (harness-provider--normalize-models provider models))
        deferred))))

(defun harness-provider-models ()
  "Return a deferred resolving to the combined model list of all providers."
  (let ((deferreds (mapcar #'harness-provider--models-of (harness-provider-list))))
    (harness-deferred-then
     (harness-deferred-all deferreds)
     (lambda (lists)
       (vconcat (seq-mapcat #'identity lists))))))

;;; Completion

(defun harness-provider-complete (request)
  "Run REQUEST on the provider named by its :model.  Returns a deferred."
  (let* ((model-id (plist-get request :model))
         (provider (harness-provider-for-model model-id)))
    (unless (harness-provider-complete-fn provider)
      (signal 'harness-provider-error
              (list (format "Provider %s cannot complete" (harness-provider-name provider)))))
    (funcall (harness-provider-complete-fn provider) request)))

(defun harness-provider-price (model-id usage)
  "Return the cost plist for USAGE on MODEL-ID, or nil.
USAGE has :input-tokens, :output-tokens, :cache-read, :cache-write."
  (let* ((provider (harness-provider-for-model model-id))
         (model (harness-provider-model-name model-id)))
    (when (harness-provider-price-fn provider)
      (funcall (harness-provider-price-fn provider) model usage))))

(defun harness-provider-count-tokens (model-id text)
  "Count tokens of TEXT as MODEL-ID sees them.
Falls back to `harness-provider-estimate-tokens' when the provider has no
tokenizer."
  (let* ((provider (harness-provider-for-model model-id))
         (model (harness-provider-model-name model-id)))
    (if (and (harness-provider-token-fn provider) text)
        (or (funcall (harness-provider-token-fn provider) model text)
            (harness-provider-estimate-tokens text))
      (harness-provider-estimate-tokens text))))

(defun harness-provider-estimate-tokens (text)
  "Estimate the token count of TEXT (roughly four characters per token)."
  (if (or (null text) (string-empty-p text))
      0
    (max 1 (ceiling (/ (float (string-bytes text)) 4.0)))))

(defun harness-provider-cost-from-prices (prices usage)
  "Compute a cost plist from PRICES (per million tokens) and USAGE."
  (when prices
    (let ((amount
           (+ (* (or (plist-get usage :input-tokens) 0)
                 (/ (or (plist-get prices :input) 0) 1.0e6))
              (* (or (plist-get usage :output-tokens) 0)
                 (/ (or (plist-get prices :output) 0) 1.0e6))
              (* (or (plist-get usage :cache-read) 0)
                 (/ (or (plist-get prices :cache-read)
                        (or (plist-get prices :input) 0)) 1.0e6)))))
      (list :amount amount :currency "USD"))))

;;; Transcript to canonical messages

(defun harness-provider--parts-text (parts)
  "Concatenate the text of PARTS."
  (mapconcat (lambda (part) (or (plist-get part :text) "")) (append parts nil) ""))

(defun harness-provider-messages-from-entries (entries)
  "Convert harness transcript ENTRIES into canonical provider messages.
ENTRIES is a vector of ACP-shaped update plists.  Consecutive assistant
chunks merge; tool calls become assistant tool-call parts and the matching
tool_call_update becomes a tool result.  System hints, plans and usage
updates are not sent to the model."
  (let ((messages nil)
        (current-message nil))         ; (role . parts-list)
    (cl-labels ((flush ()
                  (when current-message
                    (push (list :role (car current-message)
                                :content (vconcat (nreverse (cdr current-message))))
                          messages)
                    (setq current-message nil)))
                (ensure (role)
                  (unless (and current-message (equal (car current-message) role))
                    (flush)
                    (setq current-message (cons role nil))))
                (add-part (part)
                  (push part (cdr current-message))))
      (dolist (entry (append entries nil))
        (let ((kind (plist-get entry :sessionUpdate))
              (content (plist-get entry :content)))
          (cond
           ((equal kind "user_message_chunk")
            (ensure "user")
            (dolist (part (if (vectorp content) (append content nil) (list content)))
              (when (and (listp part) (plist-get part :type))
                (add-part (copy-sequence part)))))
           ((equal kind "agent_message_chunk")
            (ensure "assistant")
            (add-part (if (vectorp content)
                          (or (car (append content nil)) (list :type "text" :text ""))
                        (copy-sequence content))))
           ((equal kind "agent_thought_chunk")
            (ensure "assistant")
            (add-part (list :type "thinking"
                            :text (harness-provider--parts-text
                                   (if (vectorp content) content (list content))))))
           ((equal kind "tool_call")
            (ensure "assistant")
            (add-part (list :type "tool-call"
                            :id (plist-get entry :toolCallId)
                            :name (or (plist-get entry :name) "")
                            :arguments (harness-provider--parse-arguments
                                        (plist-get entry :rawInput)))))
           ((equal kind "tool_call_update")
            (when (member (plist-get entry :status) '("completed" "failed"))
              (flush)
              (let ((call-id (plist-get entry :toolCallId)))
                (push (list :role "tool"
                            :content (vector (list :type "tool-result"
                                                   :tool-call-id call-id
                                                   :content (or (plist-get entry :content)
                                                                (vector (list :type "text"
                                                                              :text "")))
                                                   :is-error (equal (plist-get entry :status)
                                                                    "failed"))))
                      messages))))
           (t nil))))
      (flush))
    (vconcat (nreverse messages))))

(defun harness-provider--parse-arguments (raw)
  "Parse RAW tool arguments into a plist when possible."
  (cond
   ((null raw) nil)
   ((listp raw) raw)
   ((stringp raw)
    (condition-case nil
        (json-parse-string raw :object-type 'plist)
      (error raw)))
   (t raw)))

;;; Service

(defun harness-provider-service-list (&rest _args)
  "Service: list providers with their capabilities."
  (vconcat
   (mapcar (lambda (provider)
             (list :name (harness-provider-name provider)
                   :description (harness-provider-description provider)
                   :capabilities (vconcat (harness-provider-capabilities provider))))
           (harness-provider-list))))

(defun harness-provider-service-models (&rest _args)
  "Service: return all models."
  (harness-provider-models))

(defun harness-provider-service-complete (&rest args)
  "Service: run a completion.
The method takes a single request plist; keyword-style arguments are also
accepted for convenience."
  (harness-provider-complete
   (if (and (= (length args) 1) (listp (car args)))
       (car args)
     args)))

(defun harness-provider-service-price (&rest args)
  "Service: estimate a cost."
  (let ((args (if (and (= (length args) 1) (listp (car args))) (car args) args)))
    (harness-provider-price (plist-get args :model) (plist-get args :usage))))

(defun harness-provider-service-count-tokens (&rest args)
  "Service: count tokens."
  (let ((args (if (and (= (length args) 1) (listp (car args))) (car args) args)))
    (harness-provider-count-tokens (plist-get args :model) (plist-get args :text))))

(defun harness-provider-setup ()
  "Set up the provider module."
  (harness-service-register
   "provider"
   :module 'harness-provider
   :doc "Completion providers and model discovery."
   :methods '((list . harness-provider-service-list)
              (models . harness-provider-service-models)
              (complete . harness-provider-service-complete)
              (price . harness-provider-service-price)
              (count-tokens . harness-provider-service-count-tokens))))

(defun harness-provider-teardown ()
  "Tear down the provider module."
  (clrhash harness-provider--registry))

(harness-module-define 'harness-provider
  :version harness-version
  :description "Completion provider registry and canonical format."
  :requires '((harness-core "0.1.0"))
  :provides '(harness-provider)
  :setup #'harness-provider-setup
  :teardown #'harness-provider-teardown)

(provide 'harness-provider)
;;; harness-provider.el ends here
