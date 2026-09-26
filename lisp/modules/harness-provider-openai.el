;;; harness-provider-openai.el --- OpenAI-compatible provider -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; A provider for the OpenAI chat-completions API and everything that
;; speaks it (OpenAI itself, OpenRouter, DeepSeek, Ollama, vLLM, ...).
;; Instances are customizable, so several endpoints can be registered side
;; by side and show up independently in model switchers.
;;
;; Streaming is SSE: each `data:' line is parsed as it arrives and mapped
;; onto the canonical provider callbacks.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'harness-core)
(require 'harness-http)
(require 'harness-provider)

(defgroup harness-provider-openai nil
  "OpenAI-compatible completion providers."
  :group 'harness)

(defcustom harness-provider-openai-instances
  '((:name "openai"
     :base-url "https://api.openai.com/v1"
     :api-key-env "OPENAI_API_KEY"
     :fetch-models t
     :thinking-param "reasoning_effort"
     :models (("gpt-5" :context-window 400000 :input-price 1.25 :output-price 10.0
               :cache-read-price 0.125 :thinking t)
              ("gpt-5-mini" :context-window 400000 :input-price 0.25 :output-price 2.0
               :cache-read-price 0.025 :thinking t)
              ("gpt-4o" :context-window 128000 :input-price 2.5 :output-price 10.0
               :cache-read-price 1.25)
              ("gpt-4o-mini" :context-window 128000 :input-price 0.15 :output-price 0.6
               :cache-read-price 0.075))))
  "OpenAI-compatible endpoints to register.

Each entry is a plist:

  :name          provider name, the prefix of model ids
  :base-url      API root, e.g. https://api.openai.com/v1
  :api-key       literal key (discouraged)
  :api-key-env   environment variable holding the key
  :headers       extra headers as an alist
  :models        list of (MODEL . CONFIG); CONFIG may hold :name,
                 :context-window, :input-price, :output-price,
                 :cache-read-price (prices are USD per million tokens),
                 :thinking (model accepts a reasoning level)
  :fetch-models  when non-nil, GET /models and merge with :models
  :thinking-param  request parameter carrying the thinking level
  :max-tokens-param  defaults to max_completion_tokens
  :stream-options    include stream_options for usage; default t
  :timeout       request timeout in seconds"
  :type '(repeat plist))

(defvar harness-provider-openai--model-cache (make-hash-table :test #'equal)
  "Provider name -> fetched model list.")

;;; Configuration helpers

(defun harness-provider-openai--api-key (instance)
  "Return the API key for INSTANCE, or nil."
  (or (plist-get instance :api-key)
      (let ((variable (plist-get instance :api-key-env)))
        (and variable (getenv variable)))))

(defun harness-provider-openai--endpoint (instance path)
  "Return INSTANCE's URL for PATH."
  (concat (string-trim-right (plist-get instance :base-url) "/") path))

(defun harness-provider-openai--headers (instance &optional key)
  "Return request headers for INSTANCE, authenticating with KEY."
  (append (list (cons "Content-Type" "application/json"))
          (when key (list (cons "Authorization" (concat "Bearer " key))))
          (plist-get instance :headers)))

(defun harness-provider-openai--model-config (instance model)
  "Return the static configuration of MODEL on INSTANCE."
  (cdr (assoc model (plist-get instance :models))))

(defun harness-provider-openai--static-models (instance)
  "Return INSTANCE's configured models as model plists."
  (mapcar (lambda (entry)
            (let ((config (cdr entry)))
              (append (list :model (car entry)
                            :name (or (plist-get config :name) (car entry)))
                      config)))
          (plist-get instance :models)))

(defun harness-provider-openai--price (instance model usage)
  "Return the cost of USAGE for MODEL on INSTANCE, or nil."
  (let ((config (harness-provider-openai--model-config instance model)))
    (when config
      (harness-provider-cost-from-prices
       (list :input (plist-get config :input-price)
             :output (plist-get config :output-price)
             :cache-read (plist-get config :cache-read-price))
       usage))))

;;; Model listing

(defun harness-provider-openai--fetch-models (instance)
  "Fetch INSTANCE's model list.  Returns a deferred."
  (let* ((deferred (harness-deferred-new))
         (key (harness-provider-openai--api-key instance)))
    (harness-deferred-then
     (harness-http-fetch (harness-provider-openai--endpoint instance "/models")
                         :headers (harness-provider-openai--headers instance key)
                         :timeout 20)
     (lambda (response)
       (let* ((body (harness-http-response-body response))
              (json (ignore-errors (json-parse-string body :object-type 'plist)))
              (data (and json (plist-get json :data))))
         (harness-deferred-resolve
          deferred
          (mapcar (lambda (entry) (list :model (plist-get entry :id)))
                  (append data nil)))))
     (lambda (error) (harness-deferred-reject deferred error)))
    deferred))

(defun harness-provider-openai--models (instance)
  "Return INSTANCE's model list, fetching and caching when configured."
  (let ((name (plist-get instance :name)))
    (cond
     ((gethash name harness-provider-openai--model-cache)
      (let ((deferred (harness-deferred-new)))
        (harness-deferred-resolve deferred
                                  (gethash name harness-provider-openai--model-cache))
        deferred))
     ((and (plist-get instance :fetch-models)
           (harness-provider-openai--api-key instance))
      (harness-deferred-then
       (harness-provider-openai--fetch-models instance)
       (lambda (models)
         (let ((merged (if models
                           (append models (harness-provider-openai--static-models instance))
                         (harness-provider-openai--static-models instance))))
           (puthash name merged harness-provider-openai--model-cache)
           merged))
       (lambda (_error) (harness-provider-openai--static-models instance))))
     (t (harness-provider-openai--static-models instance)))))

;;; Request conversion

(defun harness-provider-openai--arguments-json (arguments)
  "Serialize ARGUMENTS for the wire."
  (cond
   ((stringp arguments) arguments)
   ((null arguments) "{}")
   (t (json-serialize arguments))))

(defun harness-provider-openai--tool-result-text (content)
  "Flatten canonical tool-result CONTENT into text."
  (mapconcat
   (lambda (part)
     (pcase (plist-get part :type)
       ("content" (harness-provider-openai--tool-result-text
                   (let ((inner (plist-get part :content)))
                     (if (vectorp inner) inner (vector inner)))))
       ("text" (or (plist-get part :text) ""))
       ("diff" (format "--- %s\n%s\n+++ %s\n%s"
                       (plist-get part :path) (or (plist-get part :oldText) "")
                       (plist-get part :path) (or (plist-get part :newText) "")))
       (_ "")))
   (append content nil) "\n"))

(defun harness-provider-openai--message (message)
  "Convert canonical MESSAGE into one or more OpenAI messages."
  (let ((role (plist-get message :role))
        (content (plist-get message :content)))
    (pcase role
      ("tool"
       (mapcar (lambda (part)
                 (list :role "tool"
                       :tool_call_id (plist-get part :tool-call-id)
                       :content (harness-provider-openai--tool-result-text
                                 (plist-get part :content))))
               (append content nil)))
      ("assistant"
       (let ((text-parts nil)
             (tool-calls nil))
         (dolist (part (append content nil))
           (pcase (plist-get part :type)
             ("text" (push (or (plist-get part :text) "") text-parts))
             ("tool-call"
              (push (list :id (plist-get part :id)
                          :type "function"
                          :function (list :name (plist-get part :name)
                                          :arguments (harness-provider-openai--arguments-json
                                                      (plist-get part :arguments))))
                    tool-calls))))
         (list (harness-plist-omit-nil
                (list :role "assistant"
                      :content (when text-parts (mapconcat #'identity (nreverse text-parts) "\n"))
                      :tool_calls (when tool-calls (vconcat (nreverse tool-calls))))))))
      (_
       (let* ((parts (append content nil))
              (has-image (seq-some (lambda (part)
                                     (member (plist-get part :type) '("image" "audio")))
                                   parts)))
         (list
          (if has-image
              (list :role role
                    :content
                    (vconcat
                     (mapcar (lambda (part)
                               (pcase (plist-get part :type)
                                 ("text" (list :type "text" :text (plist-get part :text)))
                                 ("image" (list :type "image_url"
                                                :image_url (list :url (format "data:%s;base64,%s"
                                                                              (plist-get part :mime-type)
                                                                              (plist-get part :data)))))
                                 ("audio" (list :type "input_audio"
                                                :input_audio (list :data (plist-get part :data)
                                                                   :format (or (plist-get part :format)
                                                                               "wav"))))
                                 (_ nil)))
                             (seq-remove (lambda (part)
                                           (null (plist-get part :type)))
                                         parts))))
            (list :role role
                  :content (mapconcat (lambda (part) (or (plist-get part :text) ""))
                                      parts "\n")))))))))

(defun harness-provider-openai--messages (messages)
  "Convert canonical MESSAGES into the OpenAI messages vector."
  (vconcat (seq-mapcat #'harness-provider-openai--message (append messages nil))))

(defun harness-provider-openai--tools (tools)
  "Convert canonical TOOLS into the OpenAI tools vector."
  (vconcat
   (mapcar (lambda (tool)
             (list :type "function"
                   :function
                   (harness-plist-omit-nil
                    (list :name (plist-get tool :name)
                          :description (plist-get tool :description)
                          :parameters (or (plist-get tool :input-schema)
                                          (list :type "object"
                                                :properties (make-hash-table)))))))
           (append tools nil))))

(defun harness-provider-openai--request-body (instance request model)
  "Build the chat-completions body for REQUEST on INSTANCE."
  (let ((body (list :model model
                    :messages (harness-provider-openai--messages
                               (plist-get request :messages))
                    :stream t)))
    (when (or (null (plist-member instance :stream-options))
              (plist-get instance :stream-options))
      (setq body (plist-put body :stream_options (list :include_usage t))))
    (when-let* ((max (plist-get request :max-output-tokens)))
      (setq body (plist-put body
                            (intern (concat ":" (or (plist-get instance :max-tokens-param)
                                                    "max_completion_tokens")))
                            max)))
    (let ((tools (plist-get request :tools)))
      (when (and tools (> (length tools) 0))
        (setq body (plist-put body :tools (harness-provider-openai--tools tools)))))
    (when-let* ((thinking (plist-get request :thinking))
                (param (plist-get instance :thinking-param)))
      (setq body (plist-put body (intern (concat ":" param))
                            (cond ((stringp thinking) thinking)
                                  ((symbolp thinking) (symbol-name thinking))
                                  (t thinking)))))
    (when-let* ((system (plist-get request :system)))
      (setq body (plist-put body :messages
                            (vconcat (vector (list :role "system" :content system))
                                     (plist-get body :messages)))))
    body))

;;; Stream parsing

(cl-defstruct (harness-provider-openai--stream
               (:constructor harness-provider-openai--stream-create))
  (text "")
  (thinking "")
  (tool-calls (make-hash-table :test #'eql)) ; index -> (:id :name :arguments "json")
  (call-order nil)
  (finish-reason nil)
  usage
  error-message)

(defun harness-provider-openai--handle-line (state line request)
  "Parse one SSE LINE into STATE, firing REQUEST's callbacks."
  (when (string-match "\\`data:?[ \t]*\\(.*\\)\\'" line)
    (let ((payload (match-string 1 line)))
      (cond
       ((string-empty-p payload) nil)
       ((string= payload "[DONE]") nil)
       (t
        (condition-case err
            (harness-provider-openai--handle-chunk
             state (json-parse-string payload :object-type 'plist) request)
          (error (harness-log "openai: bad SSE payload: %S (%S)" payload err))))))))

(defun harness-provider-openai--handle-chunk (state chunk request)
  "Merge one parsed CHUNK into STATE, calling REQUEST callbacks."
  (when-let* ((error (plist-get chunk :error)))
    (setf (harness-provider-openai--stream-error-message state)
          (or (plist-get error :message) (format "%S" error))))
  (when-let* ((usage (plist-get chunk :usage)))
    (setf (harness-provider-openai--stream-usage state) usage))
  (let* ((choices (plist-get chunk :choices))
         (choice (and choices (> (length choices) 0) (aref choices 0)))
         (delta (and choice (plist-get choice :delta))))
    (when choice
      (when-let* ((reason (plist-get choice :finish_reason)))
        (setf (harness-provider-openai--stream-finish-reason state) reason)))
    (when delta
      (when-let* ((content (plist-get delta :content)))
        (setf (harness-provider-openai--stream-text state)
              (concat (harness-provider-openai--stream-text state) content))
        (when-let* ((callback (plist-get request :on-text)))
          (funcall callback content)))
      (when-let* ((reasoning (or (plist-get delta :reasoning_content)
                                 (plist-get delta :reasoning))))
        (setf (harness-provider-openai--stream-thinking state)
              (concat (harness-provider-openai--stream-thinking state) reasoning))
        (when-let* ((callback (plist-get request :on-thought)))
          (funcall callback reasoning)))
      (dolist (tool-delta (append (plist-get delta :tool_calls) nil))
        (let* ((index (or (plist-get tool-delta :index) 0))
               (function (plist-get tool-delta :function))
               (call (or (gethash index (harness-provider-openai--stream-tool-calls state))
                         (progn
                           (push index (harness-provider-openai--stream-call-order state))
                           (let ((new (list :id nil :name nil :arguments "")))
                             (puthash index new
                                      (harness-provider-openai--stream-tool-calls state))
                             new)))))
          (when-let* ((id (plist-get tool-delta :id)))
            (plist-put call :id id))
          (when-let* ((name (plist-get function :name)))
            (plist-put call :name name))
          (when-let* ((arguments (plist-get function :arguments)))
            (plist-put call :arguments (concat (plist-get call :arguments) arguments)))
          (when-let* ((callback (plist-get request :on-tool-call)))
            (funcall callback (list :id (plist-get call :id)
                                    :name (plist-get call :name)
                                    :arguments (plist-get call :arguments)))))))))

(defun harness-provider-openai--stop-reason (raw)
  "Map RAW finish reason to a canonical stop reason."
  (pcase raw
    ("tool_calls" "tool_use")
    ("function_call" "tool_use")
    ("length" "max_tokens")
    ("content_filter" "refusal")
    (_ "end_turn")))

(defun harness-provider-openai--stream-result (state)
  "Build the canonical completion result from STATE."
  (let* ((usage (harness-provider-openai--stream-usage state))
         (calls (mapcar
                 (lambda (index)
                   (let* ((call (gethash index (harness-provider-openai--stream-tool-calls state)))
                          (raw (or (plist-get call :arguments) "")))
                     (list :id (or (plist-get call :id) (harness-uuid))
                           :name (or (plist-get call :name) "")
                           :arguments (condition-case nil
                                          (json-parse-string raw :object-type 'plist)
                                        (error raw)))))
                 (reverse (harness-provider-openai--stream-call-order state)))))
    (harness-plist-omit-nil
     (list :text (harness-provider-openai--stream-text state)
           :thinking (let ((thinking (harness-provider-openai--stream-thinking state)))
                       (unless (string-empty-p thinking) thinking))
           :tool-calls (vconcat calls)
           :stop-reason (harness-provider-openai--stop-reason
                         (harness-provider-openai--stream-finish-reason state))
           :usage (when usage
                    (list :input-tokens (or (plist-get usage :prompt_tokens) 0)
                          :output-tokens (or (plist-get usage :completion_tokens) 0)
                          :cache-read (or (plist-get (plist-get usage :prompt_tokens_details)
                                                     :cached_tokens)
                                          0)
                          :cache-write 0))))))

(defun harness-provider-openai--error-message (response)
  "Extract a human-readable error from RESPONSE."
  (let ((body (harness-http-response-body response)))
    (or (condition-case nil
            (let ((json (json-parse-string body :object-type 'plist)))
              (or (plist-get (plist-get json :error) :message) body))
          (error body))
        (format "HTTP %s" (harness-http-response-status response)))))

;;; Completion

(defun harness-provider-openai--complete (instance request)
  "Run REQUEST against INSTANCE.  Returns a deferred of the result."
  (let* ((model (harness-provider-model-name (plist-get request :model)))
         (result (harness-deferred-new))
         (key (harness-provider-openai--api-key instance)))
    (if (null key)
        (harness-deferred-reject
         result
         (cons 'harness-provider-error
               (list (format "No API key for provider %s%s"
                             (plist-get instance :name)
                             (if (plist-get instance :api-key-env)
                                 (format " (set %s)" (plist-get instance :api-key-env))
                               "")))))
      (let* ((stream (harness-provider-openai--stream-create))
             (body (harness-provider-openai--request-body instance request model))
             (http-deferred
              (harness-http-fetch
               (harness-provider-openai--endpoint instance "/chat/completions")
               :method "POST"
               :headers (harness-provider-openai--headers instance key)
               :body (json-serialize body)
               :timeout (or (plist-get request :timeout)
                            (plist-get instance :timeout)
                            300)
               :on-line (lambda (line)
                          (harness-provider-openai--handle-line stream line request)))))
        (harness-deferred-on-cancel result
                                    (lambda ()
                                      (harness-deferred-cancel http-deferred)))
        (harness-deferred-then
         http-deferred
         (lambda (response)
           (let ((status (harness-http-response-status response)))
             (cond
              ((and status (>= status 200) (< status 300))
               (if (harness-provider-openai--stream-error-message stream)
                   (harness-deferred-reject
                    result
                    (cons 'harness-provider-error
                          (list (harness-provider-openai--stream-error-message stream))))
                 (harness-deferred-resolve result
                                           (harness-provider-openai--stream-result stream))))
              (t
               (harness-deferred-reject
                result
                (cons 'harness-provider-error
                      (list (format "Provider %s returned HTTP %s: %s"
                                    (plist-get instance :name) status
                                    (harness-provider-openai--error-message response)))))))))
         (lambda (error)
           (harness-deferred-reject result error)))))
    result))

;;; Registration

(defun harness-provider-openai-register-instance (instance)
  "Register INSTANCE as a completion provider."
  (harness-provider-register
   (plist-get instance :name)
   :description (or (plist-get instance :description)
                    (format "OpenAI-compatible endpoint at %s" (plist-get instance :base-url)))
   :capabilities '(streaming tool-calls image-input models-list pricing)
   :models (lambda () (harness-provider-openai--models instance))
   :complete (lambda (request) (harness-provider-openai--complete instance request))
   :price (lambda (model usage) (harness-provider-openai--price instance model usage))
   :config instance))

(defun harness-provider-openai-setup ()
  "Register every configured instance."
  (dolist (instance harness-provider-openai-instances)
    (harness-provider-openai-register-instance instance)))

(defun harness-provider-openai-teardown ()
  "Unregister the instances this module registered."
  (dolist (instance harness-provider-openai-instances)
    (harness-provider-unregister (plist-get instance :name)))
  (clrhash harness-provider-openai--model-cache))

(harness-module-define 'harness-provider-openai
  :version harness-version
  :description "OpenAI-compatible completion provider."
  :requires '((harness-core "0.1.0")
              (harness-http "0.1.0")
              (harness-provider "0.1.0"))
  :provides '(harness-provider-openai)
  :setup #'harness-provider-openai-setup
  :teardown #'harness-provider-openai-teardown)

(provide 'harness-provider-openai)
;;; harness-provider-openai.el ends here
