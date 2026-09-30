;;; harness-provider-openai.el --- OpenAI-compatible chat completions provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; A native-loop provider for every server that speaks the OpenAI chat
;; completions API: OpenAI itself, OpenRouter, and local servers such
;; as llama.cpp, vLLM or Ollama.  The agent runs the tool loop; this
;; module only turns a request into a streamed sequence of events.
;;
;; Each entry of `harness-openai-endpoints' becomes its own provider,
;; so model ids look like "openrouter:openai/gpt-4.1-nano" or
;; "openai:gpt-4.1".  Keys come from the endpoint plist, an environment
;; variable, or auth-source, and are never logged.
;;
;; OpenRouter's /models schema (pricing, context length, modalities,
;; supported parameters) is mapped onto the harness model plist so the
;; catalogue carries live prices; plain OpenAI endpoints only give ids
;; and get defaults.  Endpoints without a /models route can list their
;; models statically with `:models'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)
(require 'harness-provider)

;;;; Customisation

(defcustom harness-openai-models-ttl 3600
  "Seconds a fetched model list stays cached per endpoint."
  :type 'integer :group 'harness)

(defcustom harness-openai-request-timeout 600
  "Maximum seconds a completion request may take, including streaming."
  :type 'integer :group 'harness)

(defvar harness-openai--registered nil
  "Provider ids registered from `harness-openai-endpoints'.")

(defvar harness-openai--models-cache (make-hash-table :test 'eq)
  "Endpoint id -> (FETCHED-AT . MODELS).")

(defun harness-openai--custom-set (symbol value)
  "Set SYMBOL to VALUE and re-register the endpoint providers."
  (set-default symbol value)
  (when (fboundp 'harness-openai--register-all)
    (harness-openai--register-all)))

(defcustom harness-openai-endpoints
  '((:id openrouter :label "OpenRouter"
     :base-url "https://openrouter.ai/api/v1" :api-key-env "OPENROUTER_API_KEY")
    (:id openai :label "OpenAI"
     :base-url "https://api.openai.com/v1" :api-key-env "OPENAI_API_KEY"))
  "OpenAI-compatible endpoints, each registered as a provider.
Every entry is a plist with these keys:

  :id              provider id symbol (lower-case letters, digits, - and _);
                   model ids are \"ID:MODEL-NAME\"
  :label           display name
  :base-url        API root, for example \"https://api.openai.com/v1\"
  :api-key         literal key (discouraged: prefer the two below)
  :api-key-env     environment variable that holds the key
  :headers         extra request headers, an alist of (NAME . VALUE)
  :models          static list of model names or model plists, for servers
                   without a /models route
  :default-context context window used for models that do not report one
  :flavor          `openrouter' or `openai'; guessed from the URL when absent
  :capabilities    static capability plist overriding the flavor default

When neither :api-key nor :api-key-env yields a key, auth-source is
searched with the URL's host and user \"apikey\".  Changing this
variable through customize re-registers the providers."
  :type '(repeat (plist :key-type symbol :value-type sexp))
  :set #'harness-openai--custom-set
  :group 'harness)

;;;; Endpoints

(defun harness-openai-endpoint (id)
  "Return the endpoint plist for provider ID, or nil."
  (cl-find id harness-openai-endpoints :key (lambda (e) (plist-get e :id))))

(defun harness-openai--base-url (endpoint)
  "Return ENDPOINT's base URL without a trailing slash."
  (string-remove-suffix "/" (or (plist-get endpoint :base-url) "")))

(defun harness-openai--flavor (endpoint)
  "Return `openrouter' or `openai' for ENDPOINT."
  (or (plist-get endpoint :flavor)
      (if (string-match-p "openrouter" (harness-openai--base-url endpoint))
          'openrouter
        'openai)))

(defun harness-openai--openrouter-p (endpoint)
  "Non-nil when ENDPOINT speaks the OpenRouter dialect."
  (eq (harness-openai--flavor endpoint) 'openrouter))

(defun harness-openai--capabilities (endpoint)
  "Return the static capability plist for ENDPOINT."
  (or (plist-get endpoint :capabilities)
      (if (harness-openai--openrouter-p endpoint)
          '(:vision t :thinking t :pricing dynamic :cost-reported t)
        '(:vision t :thinking t))))

(defun harness-openai--host (endpoint)
  "Return the host part of ENDPOINT's base URL."
  (url-host (url-generic-parse-url (harness-openai--base-url endpoint))))

(defun harness-openai--auth-source-key (host)
  "Look HOST up in auth-source with user \"apikey\"; return the secret or nil."
  (when (and host (not (string-empty-p host)))
    (require 'auth-source)
    (ignore-errors
      (when-let* ((found (car (auth-source-search :host host :user "apikey" :max 1)))
                  (secret (plist-get found :secret)))
        (if (functionp secret) (funcall secret) secret)))))

(defun harness-openai--api-key (endpoint)
  "Resolve the API key for ENDPOINT: literal, environment, then auth-source."
  (let ((literal (plist-get endpoint :api-key))
        (env (plist-get endpoint :api-key-env)))
    (or (and literal (not (string-empty-p literal)) literal)
        (and env (let ((v (getenv env))) (and v (not (string-empty-p v)) v)))
        (harness-openai--auth-source-key (harness-openai--host endpoint)))))

(defun harness-openai--headers (endpoint key)
  "Return the request header alist for ENDPOINT authenticated with KEY."
  (append (when key (list (cons "Authorization" (concat "Bearer " key))))
          (when (harness-openai--openrouter-p endpoint)
            (list (cons "X-Title" "Emacs agent harness")))
          (plist-get endpoint :headers)))

(defun harness-openai-add-endpoint (&rest plist)
  "Add or replace the endpoint described by PLIST (keyed by its :id).
See `harness-openai-endpoints' for the keys.  The provider is
registered immediately."
  (let ((id (plist-get plist :id)))
    (unless (and id (symbolp id)) (error "harness-openai-add-endpoint: :id is required"))
    (setq harness-openai-endpoints
          (append (cl-remove id harness-openai-endpoints :key (lambda (e) (plist-get e :id)))
                  (list plist)))
    (harness-openai--register-all)
    id))

(defun harness-openai-clear-models-cache ()
  "Forget every cached model list so the next listing refetches."
  (interactive)
  (clrhash harness-openai--models-cache))

;;;; Models

(defun harness-openai--price (value)
  "Convert VALUE (USD per token, string or number) to USD per million tokens."
  (let ((n (cond ((numberp value) value)
                 ((stringp value) (string-to-number value))
                 (t nil))))
    (and n (>= n 0) (* n 1e6))))

(defun harness-openai--pricing (pricing)
  "Map an OpenRouter PRICING object onto the harness pricing plist, or nil."
  (when-let* ((input (harness-openai--price (plist-get pricing :prompt)))
              (output (harness-openai--price (plist-get pricing :completion))))
    (list :input input :output output
          :cache-read (or (harness-openai--price (plist-get pricing :input_cache_read)) input)
          :cache-write (or (harness-openai--price (plist-get pricing :input_cache_write)) input))))

(defun harness-openai--model-from-entry (endpoint entry)
  "Build a model plist from a /models ENTRY of ENDPOINT.
OpenRouter fields are mapped when present; plain OpenAI entries only
carry an id."
  (let* ((name (plist-get entry :id))
         (context (or (plist-get entry :context_length)
                      (harness-plist-get-in entry '(:top_provider :context_length))
                      (plist-get endpoint :default-context)))
         (max-output (harness-plist-get-in entry '(:top_provider :max_completion_tokens)))
         (modalities (harness-plist-get-in entry '(:architecture :input_modalities)))
         (params (plist-get entry :supported_parameters))
         (pricing (harness-openai--pricing (plist-get entry :pricing)))
         (model (list :name name :label (or (plist-get entry :name) name))))
    (when context (setq model (plist-put model :context-window context)))
    (when max-output (setq model (plist-put model :max-output max-output)))
    (when modalities (setq model (plist-put model :input-modalities modalities)))
    (when (member "reasoning" params)
      (setq model (plist-put model :thinking-levels '("low" "medium" "high"))))
    (when pricing (setq model (plist-put model :pricing pricing)))
    (let (caps)
      (when (member "tools" params) (setq caps (plist-put caps :tools t)))
      (when (member "reasoning" params) (setq caps (plist-put caps :thinking t)))
      (when modalities (setq caps (plist-put caps :vision (and (member "image" modalities) t))))
      (when caps (setq model (plist-put model :capabilities caps))))
    model))

(defun harness-openai--static-models (endpoint)
  "Return ENDPOINT's `:models' entries as model plists."
  (mapcar (lambda (m)
            (let ((m (if (stringp m) (list :name m) (copy-sequence m))))
              (when (and (plist-get endpoint :default-context) (not (plist-get m :context-window)))
                (setq m (plist-put m :context-window (plist-get endpoint :default-context))))
              m))
          (plist-get endpoint :models)))

(defun harness-openai--fetch-models (endpoint)
  "GET /models from ENDPOINT; return a promise of model plists.
Failures resolve to nil after a warning so one bad endpoint never
hides the others."
  (let* ((id (plist-get endpoint :id))
         (url (concat (harness-openai--base-url endpoint) "/models"))
         (key (harness-openai--api-key endpoint))
         (promise (condition-case err
                      (harness-http-request-json url :headers (harness-openai--headers endpoint key)
                                                 :timeout 60)
                    (error (harness-rejected err)))))
    (harness-then promise
                  (lambda (json)
                    (condition-case err
                        (delq nil
                              (mapcar (lambda (e)
                                        (and (plist-get e :id)
                                             (harness-openai--model-from-entry endpoint e)))
                                      (plist-get json :data)))
                      (error (harness-log 'warn "openai %s: cannot read /models: %s"
                                          id (harness-error-message err))
                             nil)))
                  (lambda (err)
                    (harness-log 'warn "openai %s: listing models failed: %s"
                                 id (harness-openai--describe-error err))
                    nil))))

(defun harness-openai--describe-error (err)
  "Return a short description of a request rejection ERR without secrets."
  (pcase err
    (`(http-error ,status ,body)
     (format "HTTP %s: %s" (or status "?")
             (if (stringp body) (harness-openai--error-message body status) (harness-error-message body))))
    (`(json-error ,status ,msg) (format "HTTP %s: bad JSON (%s)" status msg))
    (_ (harness-error-message err))))

(defun harness-openai--models (endpoint)
  "Return a promise of ENDPOINT's models, cached for `harness-openai-models-ttl'."
  (let* ((id (plist-get endpoint :id))
         (cached (gethash id harness-openai--models-cache)))
    (cond
     ((and cached (< (- (float-time) (car cached)) harness-openai-models-ttl))
      (harness-resolved (cdr cached)))
     ((plist-get endpoint :models)
      (let ((models (harness-openai--static-models endpoint)))
        (puthash id (cons (float-time) models) harness-openai--models-cache)
        (harness-resolved models)))
     (t
      (harness-then (harness-openai--fetch-models endpoint)
                    (lambda (models)
                      (when models
                        (puthash id (cons (float-time) models) harness-openai--models-cache))
                      models))))))

;;;; Request body

(defun harness-openai--string (value)
  "Return VALUE as a string; symbols and keywords lose their punctuation."
  (cond ((null value) nil)
        ((stringp value) value)
        ((keywordp value) (substring (symbol-name value) 1))
        ((symbolp value) (symbol-name value))
        (t (format "%s" value))))

(defun harness-openai--block-type (block)
  "Return BLOCK's `:type' as a string."
  (harness-openai--string (plist-get block :type)))

(defvar harness-openai--mime-types
  '(("png" . "image/png") ("jpg" . "image/jpeg") ("jpeg" . "image/jpeg")
    ("gif" . "image/gif") ("webp" . "image/webp") ("bmp" . "image/bmp")
    ("wav" . "audio/wav") ("mp3" . "audio/mpeg"))
  "File extension -> MIME type for lazily read attachments.")

(defun harness-openai--file-base64 (path)
  "Return the contents of PATH base64 encoded without line breaks."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (base64-encode-string (buffer-string) t)))

(defun harness-openai--block-data (block)
  "Return (MIME . BASE64) for an image or audio BLOCK, reading `:path' lazily."
  (let* ((path (plist-get block :path))
         (mime (or (plist-get block :mime)
                   (and path (cdr (assoc (downcase (or (file-name-extension path) ""))
                                         harness-openai--mime-types)))
                   "application/octet-stream"))
         (data (or (plist-get block :data)
                   (and path (harness-openai--file-base64 path)))))
    (cons mime data)))

(defun harness-openai--content-part (block)
  "Map a user content BLOCK to an OpenAI content part, or nil to drop it."
  (pcase (harness-openai--block-type block)
    ("text" (list :type "text" :text (or (plist-get block :text) "")))
    ("image"
     (pcase-let ((`(,mime . ,data) (harness-openai--block-data block)))
       (when data
         (list :type "image_url"
               :image_url (list :url (format "data:%s;base64,%s" mime data))))))
    ("audio"
     (pcase-let ((`(,mime . ,data) (harness-openai--block-data block)))
       (when data
         (list :type "input_audio"
               :input_audio (list :data data
                                  :format (if (string-match-p "mpeg\\|mp3" mime) "mp3" "wav"))))))
    ("file"
     (list :type "text"
           :text (format "[attached file: %s]" (or (plist-get block :path) (plist-get block :name) "?"))))
    (_ nil)))

(defun harness-openai--result-text (content)
  "Flatten a tool result CONTENT (string or list of blocks) into a string."
  (cond ((null content) "")
        ((stringp content) content)
        ((listp content)
         (mapconcat (lambda (b)
                      (if (stringp b) b
                        (or (plist-get b :text)
                            (and (equal (harness-openai--block-type b) "image") "[image]")
                            "")))
                    content "\n"))
        (t (format "%s" content))))

(defun harness-openai--tool-message (block)
  "Map a tool_result BLOCK to a {\"role\":\"tool\"} message."
  (list :role "tool"
        :tool_call_id (plist-get block :tool_use_id)
        :content (harness-openai--result-text (plist-get block :content))))

(defun harness-openai--assistant-message (blocks)
  "Map assistant content BLOCKS to one assistant message; thinking is dropped."
  (let (texts calls)
    (dolist (b blocks)
      (pcase (harness-openai--block-type b)
        ("text" (push (or (plist-get b :text) "") texts))
        ("tool_use"
         (push (list :id (plist-get b :id)
                     :type "function"
                     :function (list :name (plist-get b :name)
                                     :arguments (if (plist-get b :input)
                                                    (harness-json-encode (plist-get b :input))
                                                  "{}")))
               calls))))
    (let ((text (string-join (nreverse texts) ""))
          (msg (list :role "assistant")))
      (setq msg (plist-put msg :content (cond ((not (string-empty-p text)) text)
                                              (calls nil)
                                              (t ""))))
      (when calls (setq msg (plist-put msg :tool_calls (nreverse calls))))
      msg)))

(defun harness-openai--message-blocks (msg)
  "Return MSG's content as a list of blocks, wrapping a bare string."
  (let ((c (plist-get msg :content)))
    (if (stringp c) (list (list :type "text" :text c)) c)))

(defun harness-openai--messages (request)
  "Build the OpenAI messages array for REQUEST."
  (let (out)
    (when-let* ((system (plist-get request :system)))
      (unless (string-empty-p system)
        (push (list :role "system" :content system) out)))
    (dolist (msg (plist-get request :messages))
      (let ((role (harness-openai--string (plist-get msg :role)))
            (blocks (harness-openai--message-blocks msg)))
        (pcase role
          ("system"
           (push (list :role "system" :content (harness-openai--result-text blocks)) out))
          ("assistant"
           (push (harness-openai--assistant-message blocks) out))
          (_
           ;; user or tool: tool results become their own messages first
           ;; (they must follow the assistant call), the rest is user content.
           (let (parts)
             (dolist (b blocks)
               (if (equal (harness-openai--block-type b) "tool_result")
                   (push (harness-openai--tool-message b) out)
                 (when-let* ((part (harness-openai--content-part b)))
                   (push part parts))))
             (when parts
               (push (list :role "user" :content (nreverse parts)) out)))))))
    (nreverse out)))

(defun harness-openai--tools (specs)
  "Map tool SPECS to the OpenAI tools array, or nil."
  (mapcar (lambda (spec)
            (list :type "function"
                  :function (list :name (plist-get spec :name)
                                  :description (or (plist-get spec :description) "")
                                  :parameters (or (plist-get spec :schema)
                                                  '(:type "object" :properties :empty)))))
          specs))

(defun harness-openai--effort (level)
  "Map the harness thinking LEVEL onto an OpenAI reasoning effort."
  (pcase (harness-openai--string level)
    ((or "max" "high") "high")
    ("medium" "medium")
    ("low" "low")
    (_ nil)))

(defun harness-openai--body (endpoint name request)
  "Build the chat completions body for model NAME at ENDPOINT from REQUEST."
  (let* ((openrouter (harness-openai--openrouter-p endpoint))
         (effort (harness-openai--effort (plist-get request :thinking)))
         (tools (harness-openai--tools (plist-get request :tools)))
         (body (list :model name
                     :messages (harness-openai--messages request)
                     :stream t
                     :stream_options '(:include_usage t))))
    (when tools (setq body (plist-put body :tools tools)))
    (when-let* ((max (plist-get request :max-tokens)))
      (setq body (plist-put body (if openrouter :max_tokens :max_completion_tokens) max)))
    (when openrouter (setq body (plist-put body :usage '(:include t))))
    (when effort
      (setq body (if openrouter
                     (plist-put body :reasoning (list :effort effort))
                   (plist-put body :reasoning_effort effort))))
    body))

;;;; Streaming

(defun harness-openai--error-message (body &optional status)
  "Extract a human readable error from a response BODY (string) with STATUS."
  (let* ((json (ignore-errors (harness-json-parse body)))
         (err (and (listp json) (plist-get json :error)))
         (msg (cond ((stringp err) err)
                    ((and (listp err) (plist-get err :message)) (plist-get err :message))
                    ((and (listp json) (stringp (plist-get json :message))) (plist-get json :message))
                    ((and body (not (string-empty-p (string-trim body))))
                     (harness-truncate-end (string-trim body) 300))
                    (t nil))))
    (or msg (format "request failed%s" (if status (format " with HTTP %s" status) "")))))

(defun harness-openai--parse-arguments (raw)
  "Parse tool call arguments RAW (a JSON string) into a plist."
  (if (or (null raw) (string-empty-p (string-trim raw)))
      nil
    (condition-case err
        (harness-json-parse raw)
      (error (harness-log 'warn "openai: unparsable tool arguments: %s" (harness-error-message err))
             (list :raw raw)))))

(cl-defstruct (harness-openai--stream (:copier nil))
  "Accumulated state of one streamed completion."
  on-event calls finish-reason usage error (finished nil) http)

(defun harness-openai--stream-tool-call (stream index call)
  "Merge fragment CALL at INDEX into STREAM's accumulated tool calls."
  (let* ((slot (assoc index (harness-openai--stream-calls stream)))
         (fn (plist-get call :function)))
    (unless slot
      (setq slot (list index :id nil :name nil :arguments ""))
      (setf (harness-openai--stream-calls stream)
            (append (harness-openai--stream-calls stream) (list slot))))
    (when-let* ((id (plist-get call :id)))
      (unless (string-empty-p id) (setcdr slot (plist-put (cdr slot) :id id))))
    (when-let* ((name (plist-get fn :name)))
      (unless (string-empty-p name) (setcdr slot (plist-put (cdr slot) :name name))))
    (when-let* ((args (plist-get fn :arguments)))
      (setcdr slot (plist-put (cdr slot) :arguments
                              (concat (plist-get (cdr slot) :arguments) args))))))

(defun harness-openai--stream-chunk (stream data)
  "Handle one SSE DATA payload for STREAM."
  (unless (or (harness-openai--stream-finished stream) (equal (string-trim data) "[DONE]"))
    (let* ((json (harness-json-parse data))
           (on-event (harness-openai--stream-on-event stream))
           (err (and (listp json) (plist-get json :error))))
      (when (and err (not (harness-openai--stream-error stream)))
        (setf (harness-openai--stream-error stream)
              (cond ((stringp err) err)
                    ((plist-get err :message))
                    (t (format "%S" err)))))
      (when-let* ((usage (plist-get json :usage)))
        (when (listp usage) (setf (harness-openai--stream-usage stream) usage)))
      (let* ((choice (car (plist-get json :choices)))
             (delta (plist-get choice :delta))
             (finish (plist-get choice :finish_reason)))
        (when-let* ((text (plist-get delta :content)))
          (when (and (stringp text) (not (string-empty-p text)))
            (funcall on-event (list :type 'text :delta text))))
        (when-let* ((thought (or (plist-get delta :reasoning) (plist-get delta :reasoning_content))))
          (when (and (stringp thought) (not (string-empty-p thought)))
            (funcall on-event (list :type 'thinking :delta thought))))
        (let ((i 0))
          (dolist (call (plist-get delta :tool_calls))
            (harness-openai--stream-tool-call stream (or (plist-get call :index) i) call)
            (cl-incf i)))
        (when (and finish (stringp finish))
          (setf (harness-openai--stream-finish-reason stream) finish))))))

(defun harness-openai--usage-event (usage)
  "Build the usage event from an OpenAI USAGE object."
  (let ((input (or (plist-get usage :prompt_tokens) 0))
        (cost (plist-get usage :cost)))
    (list :type 'usage
          :input input
          :output (or (plist-get usage :completion_tokens) 0)
          :cache-read (or (harness-plist-get-in usage '(:prompt_tokens_details :cached_tokens)) 0)
          :cache-write 0
          :cost (and (numberp cost) cost)
          :context input)))

(defun harness-openai--stream-finish (stream reason &optional error)
  "End STREAM with stop REASON and optional ERROR text, emitting once."
  (unless (harness-openai--stream-finished stream)
    (setf (harness-openai--stream-finished stream) t)
    (let ((on-event (harness-openai--stream-on-event stream))
          (calls (harness-openai--stream-calls stream)))
      (when-let* ((usage (harness-openai--stream-usage stream)))
        (unless (eq reason 'cancelled)
          (funcall on-event (harness-openai--usage-event usage))))
      (when (eq reason 'tool-use)
        (dolist (slot calls)
          (let ((call (cdr slot)))
            (funcall on-event (list :type 'tool-call
                                    :id (or (plist-get call :id) (concat "call_" (harness-short-id)))
                                    :name (plist-get call :name)
                                    :input (harness-openai--parse-arguments (plist-get call :arguments))
                                    :respond nil)))))
      (funcall on-event (if error
                            (list :type 'done :stop-reason reason :error error)
                          (list :type 'done :stop-reason reason))))))

(defun harness-openai--stream-complete (stream)
  "Finish STREAM after a successful response, choosing the stop reason."
  (let ((finish (harness-openai--stream-finish-reason stream))
        (calls (harness-openai--stream-calls stream))
        (err (harness-openai--stream-error stream)))
    (cond
     (err (harness-openai--stream-finish stream 'error err))
     ((or calls (equal finish "tool_calls") (equal finish "function_call"))
      (harness-openai--stream-finish stream 'tool-use))
     ((equal finish "length") (harness-openai--stream-finish stream 'max-tokens))
     ((equal finish "content_filter")
      (harness-openai--stream-finish stream 'error "response stopped by the content filter"))
     (t (harness-openai--stream-finish stream 'end-turn)))))

(defun harness-openai--complete (endpoint request)
  "Start a streamed chat completion for REQUEST at ENDPOINT; return a handle."
  (pcase-let* ((`(,_ . ,name) (harness-provider-parse-model (plist-get request :model)))
               (on-event (or (plist-get request :on-event) #'ignore))
               (stream (make-harness-openai--stream :on-event on-event))
               (key (harness-openai--api-key endpoint))
               (url (concat (harness-openai--base-url endpoint) "/chat/completions"))
               (status nil) (raw "")
               (sse (harness-http-sse-parser
                     (lambda (_event data) (harness-openai--stream-chunk stream data)))))
    (funcall on-event (list :type 'start))
    (cond
     ((and (null key) (plist-get endpoint :api-key-env))
      (harness-openai--stream-finish
       stream 'error (format "no API key for %s: set %s or add an auth-source entry for %s"
                             (plist-get endpoint :id) (plist-get endpoint :api-key-env)
                             (harness-openai--host endpoint))))
     (t
      (condition-case err
          (setf (harness-openai--stream-http stream)
                (harness-http-request
                 url
                 :method "POST"
                 :headers (harness-openai--headers endpoint key)
                 :json (harness-openai--body endpoint name request)
                 :timeout harness-openai-request-timeout
                 :on-headers (lambda (s _headers) (setq status s))
                 :on-chunk (lambda (chunk)
                             (if (and status (or (< status 200) (>= status 300)))
                                 (setq raw (concat raw chunk))
                               (funcall sse chunk)))
                 :callback (lambda (s _headers body err)
                             (let ((s (or s status)))
                               (cond
                                ((harness-openai--stream-finished stream) nil)
                                ((eq (car-safe err) 'cancelled)
                                 (harness-openai--stream-finish stream 'cancelled))
                                (err (harness-openai--stream-finish
                                      stream 'error (harness-error-message (cadr err))))
                                ((or (null s) (< s 200) (>= s 300))
                                 (harness-openai--stream-finish
                                  stream 'error
                                  (format "HTTP %s: %s" (or s "?")
                                          (harness-openai--error-message
                                           (if (string-empty-p raw) (or body "") raw) s))))
                                (t (harness-openai--stream-complete stream)))))))
        (error (harness-openai--stream-finish stream 'error (harness-error-message err))))))
    (list :cancel (lambda ()
                    (unless (harness-openai--stream-finished stream)
                      (when-let* ((h (harness-openai--stream-http stream)))
                        (harness-http-cancel h))
                      (harness-openai--stream-finish stream 'cancelled))))))

;;;; Registration

(defun harness-openai--register (endpoint)
  "Register the provider described by ENDPOINT."
  (let ((id (plist-get endpoint :id)))
    (harness-define-provider id
      :label (or (plist-get endpoint :label) (symbol-name id))
      :doc (format "OpenAI-compatible endpoint at %s" (harness-openai--base-url endpoint))
      :models (lambda () (harness-openai--models (harness-openai-endpoint id)))
      :complete (lambda (request) (harness-openai--complete (harness-openai-endpoint id) request))
      :capabilities (harness-openai--capabilities endpoint))
    id))

(defun harness-openai--register-all ()
  "Register a provider for every endpoint; drop providers of removed ones."
  (let ((ids nil))
    (dolist (endpoint harness-openai-endpoints)
      (let ((id (plist-get endpoint :id)))
        (cond
         ((not (and id (symbolp id) (plist-get endpoint :base-url)))
          (harness-log 'warn "openai: ignoring endpoint without :id and :base-url: %S"
                       (harness-plist-remove endpoint :api-key :headers)))
         ((not (string-match-p "\\`[a-z0-9_-]+\\'" (symbol-name id)))
          (harness-log 'warn "openai: endpoint id %s must be lower-case letters, digits, - or _" id))
         (t (push (harness-openai--register endpoint) ids)))))
    (dolist (old harness-openai--registered)
      (unless (memq old ids)
        (remhash old harness-providers)
        (remhash old harness-openai--models-cache)))
    (setq harness-openai--registered ids)))

(harness-openai--register-all)

(harness-define-module 'provider-openai
  :doc "OpenAI-compatible chat completions provider (OpenAI, OpenRouter, local servers)."
  :requires '(provider)
  :init #'harness-openai--register-all)

(provide 'harness-provider-openai)
;;; harness-provider-openai.el ends here
