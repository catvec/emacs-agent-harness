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
;; The models are what the server lists at /models, asked again once
;; the listing is older than `harness-openai--models-ttl' or a refresh
;; asks.  OpenRouter's schema (pricing, context length, modalities,
;; supported parameters) is mapped onto the harness model plist so the
;; catalogue carries live prices, and so are the windows other servers
;; give under their own names (vLLM, Groq, Mistral, LM Studio,
;; LiteLLM).  Plain OpenAI only gives ids: a model without a window
;; gets an estimate from the catalogue (the same model as another
;; provider lists it, say), unless the endpoint names one with
;; `:default-context'.  Endpoints without a /models route can list
;; their models statically with `:models'.
;;
;; The reasoning effort is model-specific too.  OpenRouter's model list
;; names the efforts a model takes in its `reasoning' object
;; (`supported_efforts', with `mandatory' saying that `none' is not
;; one), and they become the model's `:thinking-levels'; the body fits
;; the harness level asked for to them, so `max' and `xhigh' go out
;; where the model takes them and a model that refuses `none' is asked
;; for its weakest effort instead.  A server that names no efforts keeps
;; the conservative mapping: high, medium and low as they are, `max'
;; asked for as `high', and the values older models do not take left
;; out, which asks for no effort at all.
;;
;; A tool message holds text only, so the images a tool returned (the
;; `:images' of a tool_result block, each with `:data' or a `:path') go
;; in the user message after the tool messages
;; (`harness-openai--tool-image-parts').  The DeepSeek provider builds
;; its messages here too.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)
(require 'harness-provider)

;;;; Customisation

(defconst harness-openai--models-ttl 3600
  "Seconds a fetched model list stays cached per endpoint.
A refresh (`provider/models' with REFRESH) asks the server again
however fresh it is.")

(defconst harness-openai--request-timeout 600
  "Maximum seconds a completion request may take, including streaming.")

(defconst harness-openai--progress-interval 0.25
  "Seconds between reports of how much of a tool call's arguments has streamed.")

(defvar harness-openai--registered nil
  "Provider ids registered from `harness-openai-endpoints'.")

(defvar harness-openai--models-cache (make-hash-table :test 'eq)
  "Endpoint id -> (FETCHED-AT . MODELS).")

(defun harness-openai--custom-set (symbol value)
  "Set SYMBOL to VALUE and re-register the endpoint providers."
  (set-default symbol value)
  (when (fboundp 'harness-openai--register-all)
    (harness-openai--register-all)))

(defconst harness-openai--endpoint-type
  `(plist
    :tag "Endpoint"
    ;; A new endpoint starts as a local server.
    :value (:id local :label "Local server" :base-url "http://localhost:11434/v1")
    :options
    ((:id (symbol :tag "ID" :value local
                  :doc "Names the provider: its models are ID:MODEL.
Lower-case letters, digits, - and _."))
     (:label (string :tag "Label" :value "Local server"
                     :doc "Name of the provider in the model picker."))
     (:base-url (string :tag "Base URL" :value "http://localhost:11434/v1"
                        :doc "Root of the API, the part before /chat/completions.  For a local
server: Ollama http://localhost:11434/v1, llama.cpp
http://localhost:8080/v1, vLLM http://localhost:8000/v1, LM Studio
http://localhost:1234/v1."))
     (:api-key-env (string :tag "API key variable" :value "OPENAI_API_KEY"
                           :doc "Environment variable that holds the API key.  Without a key,
auth-source is searched for the URL's host and the user \"apikey\"."))
     (:headers (alist :tag "Headers" :key-type (string :tag "Header") :value-type (string :tag "Value")
                      :doc "Extra request headers."))
     (:models (repeat :tag "Models"
                      :doc "Models to offer instead of those the server lists at /models."
                      (choice :tag "Model" :value "model-name"
                              (string :tag "Name")
                              ,(harness-provider-model-type))))
     (:default-context (integer :tag "Default context" :value 128000
                                :doc "Context window of the models the server does not size.  Without
it such a model's window is estimated: the same model's at another
provider, else that of the endpoint's models most like it."))
     (:tiers ,harness-provider-tiers-type)
     (:flavor (choice :tag "Flavor" :value openai
                      :doc "Dialect of the API; guessed from the URL when not set.  DeepSeek
is never guessed, so name it for an endpoint that needs it."
                      (const :tag "OpenAI" openai)
                      (const :tag "OpenRouter" :menu-tag "OpenRouter: prices come with the model list"
                             openrouter)
                      (const :tag "DeepSeek" deepseek)))
     (:capabilities (plist :tag "Capabilities" :value (:vision t :thinking t)
                           :doc "What the models can do, replacing what the flavor says: images
and thinking, and for OpenRouter prices and costs too."
                           :options ((:vision (const :tag "Images" t))
                                     (:thinking (const :tag "Thinking" t))
                                     (:pricing (const :tag "Prices come from the model list" dynamic))
                                     (:cost-reported (const :tag "Replies say what they cost" t)))))))
  "Customize type of an entry of `harness-openai-endpoints'.")

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
  :default-context context window used for models that do not report one;
                   without it their window is an estimate (see
                   `harness-provider-fallback-context-window')
  :flavor          `openrouter', `openai' or `deepseek'; guessed from
                   the URL when absent (`deepseek' is never guessed, but
                   an official DeepSeek host gets its handling anyway;
                   see `harness-openai--deepseek-p')
  :capabilities    static capability plist overriding the flavor default
  :tiers           a model name per tier (:simple :medium :hard
                   :frontier), perhaps with a thinking level, as
                   `harness-define-provider' takes them (see
                   `harness-provider-tiers-type'); without one the
                   tier comes from the catalogue's prices

When neither :api-key nor :api-key-env yields a key, auth-source is
searched with the URL's host and user \"apikey\".  Changing this
variable through customize re-registers the providers."
  :type `(repeat ,harness-openai--endpoint-type)
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
  "Return `openrouter' or `openai' for ENDPOINT.
An explicit `:flavor' of `deepseek' is possible too, but the DeepSeek
handling does not depend on it: an official DeepSeek host is recognized
by its URL (see `harness-openai--deepseek-p')."
  (or (plist-get endpoint :flavor)
      (if (string-match-p "openrouter" (harness-openai--base-url endpoint))
          'openrouter
        'openai)))

(defun harness-openai--openrouter-p (endpoint)
  "Non-nil when ENDPOINT speaks the OpenRouter dialect."
  (eq (harness-openai--flavor endpoint) 'openrouter))

(defun harness-openai--deepseek-p (endpoint)
  "Non-nil when ENDPOINT speaks the DeepSeek dialect.
DeepSeek differs from plain OpenAI in how it reports cached input (its
`prompt_tokens' includes the cached tokens, which are billed apart), in
the reasoning efforts it accepts, and in requiring a tool-using
history to carry the thinking of earlier assistant turns back as
`reasoning_content'.  The dialect follows the host, so an official
DeepSeek host counts even when the endpoint names another flavor."
  (or (eq (harness-openai--flavor endpoint) 'deepseek)
      (harness-openai--deepseek-host-p endpoint)))

(defconst harness-openai-deepseek-cache-ttl 10800
  "Seconds DeepSeek's context cache is taken to last once unused.
DeepSeek clears an unused cache \"usually within a few hours to a few
days\" rather than after a set time; this is the low end, its models'
`:cache-ttl' capability (see `harness-provider-cache-ttl').")

(defun harness-openai--capabilities (endpoint)
  "Return the static capability plist for ENDPOINT.
`:quota' says the endpoint reports a plan's quota, which a server that
spends a ChatGPT plan does in its answers (see \"Plan quota\" below).
An endpoint may replace all of this with its own `:capabilities'."
  (or (plist-get endpoint :capabilities)
      (pcase (harness-openai--flavor endpoint)
        ('openrouter '(:vision t :thinking t :pricing dynamic :cost-reported t))
        ;; DeepSeek reports vision per model, so the endpoint does not claim it.
        ('deepseek (list :thinking t :cache-ttl harness-openai-deepseek-cache-ttl))
        (_ '(:vision t :thinking t :quota t)))))

(defun harness-openai--host (endpoint)
  "Return the host part of ENDPOINT's base URL."
  (url-host (url-generic-parse-url (harness-openai--base-url endpoint))))

(defconst harness-openai--deepseek-host-regexp
  "\\`\\(.*\\.\\)?deepseek\\.com\\'"
  "Hosts that speak the DeepSeek dialect, whatever an endpoint calls itself.")

(defun harness-openai--deepseek-host-p (endpoint)
  "Non-nil when ENDPOINT's base URL points at an official DeepSeek host.
DeepSeek's rules (the reasoning replay, the reasoning efforts and how
cached input is reported) follow the server rather than the endpoint's
label, so an endpoint that declares another flavor but talks to
DeepSeek still gets them."
  (let ((host (harness-openai--host endpoint)))
    (and (stringp host)
         (not (string-empty-p host))
         (and (string-match-p harness-openai--deepseek-host-regexp host) t))))

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

(defun harness-openai--effort-levels (value &optional mandatory)
  "Return the effort names in VALUE, weakest first, or nil.
VALUE is a JSON array of names, or of objects with an `effort' field,
as OpenRouter's `reasoning' object and a model list may give them.
MANDATORY non-nil removes `none', which such a model refuses."
  (let* ((items (cond ((stringp value) (list value))
                      ((and (consp value) (keywordp (car value))) (list value))
                      ((sequencep value) (append value nil))
                      (t nil)))
         (levels (delq nil (mapcar (lambda (item)
                                     (let ((name (cond ((stringp item) item)
                                                       ((consp item) (plist-get item :effort))
                                                       (t nil))))
                                       (and (stringp name)
                                            (member name harness-thinking-level-order)
                                            name)))
                                   items))))
    (when mandatory
      (setq levels (cl-remove "none" levels :test #'equal)))
    (when levels
      (sort (delete-dups (copy-sequence levels))
            (lambda (a b) (< (harness-thinking-level-rank a)
                             (harness-thinking-level-rank b)))))))

(defun harness-openai--entry-efforts (endpoint entry)
  "Return the reasoning levels ENTRY advertises for ENDPOINT, or nil.
DeepSeek lists them in `effort.supported_levels', the ladder its
`reasoning_effort' really acts on.  OpenRouter lists them in its
`reasoning' object: `supported_efforts' is the ladder, null there
means every value is taken, and `mandatory' says `none' is not.  An
entry that reasons but does not list any gets its host's ladder:
DeepSeek's low/high/max on a DeepSeek host, the levels a plain OpenAI
reasoning model has otherwise.  A DeepSeek model that says nothing
about reasoning still gets that ladder, since its thinking mode is on
by default."
  (let* ((levels (plist-get (plist-get entry :effort) :supported_levels))
         (reasoning (plist-get entry :reasoning))
         (listing (and (listp reasoning) (plist-member reasoning :supported_efforts)))
         (mandatory (and (listp reasoning)
                         (harness-json-true-p (plist-get reasoning :mandatory))))
         (supported (and listing
                         (harness-openai--effort-levels
                          (plist-get reasoning :supported_efforts) mandatory)))
         (advertised (harness-openai--effort-levels
                      (or (plist-get entry :supported_reasoning_levels)
                          (plist-get entry :supported_reasoning_efforts)))))
    (cond ((and (listp levels) levels (cl-every #'stringp levels))
           (copy-sequence levels))
          (supported supported)
          (advertised advertised)
          (listing
           (harness-openai--effort-levels
            harness-thinking-level-order mandatory))
          ((harness-openai--deepseek-p endpoint)
           (copy-sequence harness-openai--deepseek-efforts))
          ((member "reasoning" (plist-get entry :supported_parameters))
           '("low" "medium" "high"))
          (t nil))))

(defconst harness-openai--window-fields
  '((:context_length) (:top_provider :context_length) (:context_window)
    (:max_context_length) (:max_model_len) (:max_input_tokens))
  "Where servers give a model's context window in a /models entry.
OpenRouter, Together and Fireworks say `context_length', Groq
`context_window', Mistral and LM Studio `max_context_length', vLLM
`max_model_len', LiteLLM `max_input_tokens'.  The first that holds a
positive number counts.")

(defconst harness-openai--output-fields
  '((:top_provider :max_completion_tokens) (:max_completion_tokens) (:max_output_tokens))
  "Where servers give the most tokens of a reply in a /models entry.")

(defun harness-openai--entry-count (entry fields)
  "Return the first positive number of ENTRY at one of FIELDS, or nil.
Each of FIELDS is a key path; a number in a string counts too."
  (cl-loop for path in fields
           for v = (harness-plist-get-in entry path)
           for n = (cond ((numberp v) v)
                         ((and (stringp v) (string-match-p "\\`[0-9]+\\'" v)) (string-to-number v)))
           when (and n (> n 0)) return (round n)))

(defun harness-openai--model-from-entry (endpoint entry)
  "Build a model plist from a /models ENTRY of ENDPOINT.
OpenRouter fields are mapped when present, and the windows other
servers give (`harness-openai--window-fields'); plain OpenAI entries
only carry an id, and get the endpoint's `:default-context' if any."
  (let* ((name (plist-get entry :id))
         (context (or (harness-openai--entry-count entry harness-openai--window-fields)
                      (plist-get endpoint :default-context)))
         (max-output (harness-openai--entry-count entry harness-openai--output-fields))
         ;; OpenRouter says them under `architecture', DeepSeek at the top.
         (modalities (cl-find-if (lambda (m) (and (consp m) (cl-every #'stringp m)))
                                 (list (harness-plist-get-in entry '(:architecture :input_modalities))
                                       (plist-get entry :input_modalities))))
         (params (plist-get entry :supported_parameters))
         (efforts (harness-openai--entry-efforts endpoint entry))
         (pricing (harness-openai--pricing (plist-get entry :pricing)))
         (model (list :name name :label (or (plist-get entry :name) name))))
    (when context (setq model (plist-put model :context-window context)))
    (when max-output (setq model (plist-put model :max-output max-output)))
    (when modalities (setq model (plist-put model :input-modalities modalities)))
    (when efforts
      (setq model (plist-put model :thinking-levels efforts)))
    (when pricing (setq model (plist-put model :pricing pricing)))
    (let (caps)
      (when (member "tools" params) (setq caps (plist-put caps :tools t)))
      (when efforts (setq caps (plist-put caps :thinking t)))
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
A failure rejects it with an error that says what went wrong, without
secrets."
  (let* ((url (concat (harness-openai--base-url endpoint) "/models"))
         (key (harness-openai--api-key endpoint))
         (promise (condition-case err
                      (harness-http-request-json url :headers (harness-openai--headers endpoint key)
                                                 :timeout 60)
                    (error (harness-rejected err)))))
    (harness-then promise
                  (lambda (json)
                    (condition-case err
                        (let ((data (plist-get json :data)))
                          (unless (listp data) (error "No list of models"))
                          (delq nil
                                (mapcar (lambda (e)
                                          (and (consp e) (plist-get e :id)
                                               (harness-openai--model-from-entry endpoint e)))
                                        data)))
                      (error (error "Cannot read /models: %s" (harness-error-message err)))))
                  (lambda (err)
                    (error "%s" (harness-openai--describe-error err))))))

(defun harness-openai--describe-error (err)
  "Return a short description of a request rejection ERR without secrets."
  (pcase err
    (`(http-error ,status ,body)
     (format "HTTP %s: %s" (or status "?")
             (if (stringp body) (harness-openai--error-message body status) (harness-error-message body))))
    (`(json-error ,status ,msg) (format "HTTP %s: bad JSON (%s)" status msg))
    (_ (harness-error-message err))))

(defun harness-openai--models (endpoint &optional refresh)
  "Return a promise of ENDPOINT's models, cached for `harness-openai--models-ttl'.
REFRESH asks the server again however fresh the cache is.  A listing
that fails answers with the models listed before, when there are any,
and is logged; else the promise is rejected, which the catalogue logs,
and nothing is cached."
  (let* ((id (plist-get endpoint :id))
         (cached (gethash id harness-openai--models-cache)))
    (cond
     ((plist-get endpoint :models)
      (let ((models (harness-openai--static-models endpoint)))
        (puthash id (cons (float-time) models) harness-openai--models-cache)
        (harness-resolved models)))
     ((and cached (not refresh) (< (- (float-time) (car cached)) harness-openai--models-ttl))
      (harness-resolved (cdr cached)))
     (t
      (harness-then (harness-openai--fetch-models endpoint)
                    (lambda (models)
                      (when models
                        (puthash id (cons (float-time) models) harness-openai--models-cache))
                      models)
                    (lambda (err)
                      (if (not cached)
                          (signal (car err) (cdr err))
                        (harness-log 'warn "openai %s: listing models failed: %s; keeping the %d listed before"
                                     id (harness-error-message err) (length (cdr cached)))
                        (cdr cached))))))))

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
  "Map a tool_result BLOCK to a {\"role\":\"tool\"} message.
The message is text: chat completions take nothing else in a tool
message, so the images of BLOCK go elsewhere (see
`harness-openai--tool-image-parts')."
  (list :role "tool"
        :tool_call_id (plist-get block :tool_use_id)
        :content (harness-openai--result-text (plist-get block :content))))

(defun harness-openai--tool-image-parts (block)
  "Return the user content parts for the images of tool_result BLOCK, or nil.
An image of BLOCK's `:images' is a block (:type \"image\" :mime MIME)
with `:data' (base64) or only a `:path' to read.  Each becomes a text
part naming the tool call it came from, then the image itself as
`harness-openai--content-part' maps it, since a tool message cannot
carry one.  An image that cannot be read is replaced by a text part
saying so rather than failing the request: its path stays in the
transcript, so a request that failed on it would fail on every turn
after it, whether the file was deleted or just not there any more."
  (let ((id (plist-get block :tool_use_id)))
    (apply #'append
           (mapcar (lambda (image)
                     (let ((part (and (consp image)
                                      (condition-case nil
                                          (harness-openai--content-part
                                           (plist-put (copy-sequence image) :type "image"))
                                        (file-error nil)))))
                       (if part
                           (list (list :type "text" :text (format "[Image returned by tool call %s]" id))
                                 part)
                         (list (list :type "text"
                                     :text (format "[Image returned by tool call %s is not available]" id))))))
                   (plist-get block :images)))))

(defun harness-openai--assistant-message (blocks &optional reasoning)
  "Map assistant content BLOCKS to one assistant message.
Thinking is dropped unless REASONING is non-nil: DeepSeek's thinking
mode requires the reasoning of earlier assistant turns to be sent back
as `reasoning_content' when the request carries tools.  With REASONING
the key is always set, empty when the message has no thinking, because
DeepSeek rejects a tool-using history whose assistant messages omit it."
  (let (texts calls thoughts)
    (dolist (b blocks)
      (pcase (harness-openai--block-type b)
        ("text" (push (or (plist-get b :text) "") texts))
        ("thinking" (when reasoning (push (or (plist-get b :text) "") thoughts)))
        ("tool_use"
         (push (list :id (plist-get b :id)
                     :type "function"
                     :function (list :name (plist-get b :name)
                                     ;; A string inside the body's JSON: text, not bytes.
                                     :arguments (if (plist-get b :input)
                                                    (harness-json-encode-text (plist-get b :input))
                                                  "{}")))
               calls))))
    (let ((text (string-join (nreverse texts) ""))
          (msg (list :role "assistant")))
      (setq msg (plist-put msg :content (cond ((not (string-empty-p text)) text)
                                              (calls nil)
                                              (t ""))))
      (when calls (setq msg (plist-put msg :tool_calls (nreverse calls))))
      (when reasoning
        (setq msg (plist-put msg :reasoning_content
                             (string-join (nreverse thoughts) "\n\n"))))
      msg)))

(defun harness-openai--message-blocks (msg)
  "Return MSG's content as a list of blocks, wrapping a bare string."
  (let ((c (plist-get msg :content)))
    (if (stringp c) (list (list :type "text" :text c)) c)))

(defun harness-openai--messages (request &optional endpoint)
  "Build the OpenAI messages array for REQUEST at ENDPOINT.
DeepSeek endpoints get the thinking of assistant messages back as
`reasoning_content'; every other dialect drops it.

The images a tool returned (the `:images' of a tool_result block) cannot
ride in its tool message, which is text.  They go in the user message
that follows the tool messages of the same harness message, before its
other content: every tool message must come right after the assistant
message that made the calls, so nothing may be put between them."
  (let ((reasoning (and endpoint (harness-openai--deepseek-p endpoint)))
        out)
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
           (push (harness-openai--assistant-message blocks reasoning) out))
          (_
           ;; user or tool: tool results become their own messages first
           ;; (they must follow the assistant call), the rest is user content.
           ;; The images the tools returned lead that content.
           (let (parts images)
             (dolist (b blocks)
               (if (equal (harness-openai--block-type b) "tool_result")
                   (progn
                     (push (harness-openai--tool-message b) out)
                     (setq images (append images (harness-openai--tool-image-parts b))))
                 (when-let* ((part (harness-openai--content-part b)))
                   (push part parts))))
             (when (or images parts)
               (push (list :role "user" :content (append images (nreverse parts))) out)))))))
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

(defun harness-openai--model-efforts (endpoint name)
  "Return the reasoning efforts ENDPOINT's listing gives model NAME, or nil.
A listing that has not arrived, and a model it does not name, yield
nil, which leaves `harness-openai--effort' its old mapping."
  (when-let* ((cached (gethash (plist-get endpoint :id) harness-openai--models-cache))
              (model (cl-find name (cdr cached) :key (lambda (m) (plist-get m :name))
                              :test #'equal)))
    (plist-get model :thinking-levels)))

(defun harness-openai--effort (level &optional levels)
  "Map the harness thinking LEVEL onto an OpenAI reasoning effort.
LEVELS are the efforts the model takes, weakest first, when its
listing names them: LEVEL is fitted to them
\(`harness-thinking-level-fit'), so a model that does not take `none'
is asked for its weakest effort and one that does not take `max' for
the strongest it has.  Without LEVELS the conservative mapping is
kept: `max' and `high' are asked for as `high', and the values older
models do not take are left out, which asks for no effort at all."
  (let ((name (harness-openai--string level)))
    (cond
     ((not (member name harness-thinking-level-order)) nil)
     (levels (harness-thinking-level-fit name levels))
     ((member name '("max" "high")) "high")
     ((equal name "medium") "medium")
     ((equal name "low") "low")
     (t nil))))

(defconst harness-openai--deepseek-efforts '("low" "high" "max")
  "DeepSeek's reasoning efforts, weakest first.
These are the only values DeepSeek acts on, so a DeepSeek model offers
exactly them as its `:thinking-levels'; the harness levels between them
take the effort DeepSeek's own server-side mapping gives them (see
`harness-openai--deepseek-effort').")

(defconst harness-openai--deepseek-effort-map
  '(("minimal" . "low") ("low" . "low")
    ("medium" . "high") ("high" . "high") ("xhigh" . "high")
    ("max" . "max")
    ("none" . "none") ("off" . "none") ("disabled" . "none"))
  "Harness thinking level -> the effort DeepSeek acts on.
DeepSeek collapses the levels it cannot tell apart itself: minimal is
low, and medium and xhigh are high.  Every value but `none' is one of
`harness-openai--deepseek-efforts'.")

(defun harness-openai--deepseek-effort (level)
  "Map the harness thinking LEVEL onto a DeepSeek reasoning effort, or nil.
The levels in between DeepSeek's own ladder take the effort DeepSeek
itself gives them (see `harness-openai--deepseek-effort-map'), so asking
for one never sends a stronger effort than DeepSeek would; a level
DeepSeek does not know at all yields nil and no `reasoning_effort' is
sent."
  (cdr (assoc (harness-openai--string level) harness-openai--deepseek-effort-map)))

(defun harness-openai--body (endpoint name request)
  "Build the chat completions body for model NAME at ENDPOINT from REQUEST.
A request that asks for no thinking with `:no-thinking' says so on the
wire: `:no-thinking' wins over `:thinking', as it does for the Claude
provider (`harness-provider-claude--effort'), and a DeepSeek endpoint
gets `reasoning_effort' \"none\", its off switch.  Without it a model
whose thinking is on by default spends a short output budget on the
reasoning and stops at `max-tokens' with no text, as a naming request's
40 tokens did.  A model whose listing names the efforts it takes is
asked for one of those (`harness-openai--effort'): a model that does
not take `none' gets its weakest effort instead, and one that takes
`max' or `xhigh' gets it.  An endpoint with no such listing sends no
effort when it knows no off switch, as before."
  (let* ((openrouter (harness-openai--openrouter-p endpoint))
         (deepseek (harness-openai--deepseek-p endpoint))
         (level (if (plist-get request :no-thinking) "none" (plist-get request :thinking)))
         (effort (if deepseek
                     (harness-openai--deepseek-effort level)
                   (harness-openai--effort level (harness-openai--model-efforts endpoint name))))
         (tools (harness-openai--tools (plist-get request :tools)))
         (body (list :model name
                     :messages (harness-openai--messages request endpoint)
                     :stream t
                     :stream_options '(:include_usage t))))
    (when tools (setq body (plist-put body :tools tools)))
    (when-let* ((max (plist-get request :max-tokens)))
      (setq body (plist-put body (if (or openrouter deepseek) :max_tokens :max_completion_tokens) max)))
    ;; OpenRouter reports the cost of each call when asked.
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
  on-event calls finish-reason usage error (finished nil) http endpoint
  ;; Slots added later go last, though only a request in flight holds one.
  status                 ; HTTP status of the response, once headers arrived
  error-kind             ; transport failure the HTTP layer reported
  retry-after)           ; seconds a rate limit asked the caller to wait

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
                              (concat (plist-get (cdr slot) :arguments) args))))
    (harness-openai--tool-input-progress stream slot)))

(defun harness-openai--tool-input-progress (stream slot)
  "Report the size of the arguments STREAM has received for the call in SLOT.
The calls themselves go out once the response ends, so this is all that
shows a model writing a large input.  At most one report every
`harness-openai--progress-interval' seconds per call."
  (let ((call (cdr slot))
        (now (float-time)))
    (when (and (plist-get call :name)
               (let ((sent (plist-get call :sent-at)))
                 (or (null sent) (>= (- now sent) harness-openai--progress-interval))))
      (setcdr slot (plist-put call :sent-at now))
      (funcall (harness-openai--stream-on-event stream)
               (list :type 'activity :phase 'tool-input :tool (plist-get call :name)
                     :chars (length (plist-get call :arguments)))))))

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

(defun harness-openai--deepseek-usage-p (usage)
  "Non-nil when USAGE carries DeepSeek's own cache-token fields.
DeepSeek reports `prompt_tokens' as the sum of
`prompt_cache_hit_tokens' and `prompt_cache_miss_tokens' and bills the
two apart.  A server that reports those fields is billed that way
whatever the endpoint calls itself, so the split must not depend on
the endpoint's label alone."
  (and (listp usage)
       (or (plist-member usage :prompt_cache_miss_tokens)
           (plist-member usage :prompt_cache_hit_tokens))))

(defun harness-openai--usage-event (usage endpoint)
  "Build the usage event from an OpenAI USAGE object for ENDPOINT.
An endpoint that bills per token says `api'; one whose answers carry a
ChatGPT plan's windows is paid by that plan, so its calls cost nothing
and say `subscription', as Claude Code's do
\(`harness-openai--plan-status').  DeepSeek's `prompt_tokens' includes
the cached tokens, so they are split: `:input' counts the cache misses,
`:cache-read' the hits, and `:context' both.  A DeepSeek endpoint is
recognized by its flavor, by an official host, or by the cache fields
the server reports."
  (let* ((input (or (plist-get usage :prompt_tokens) 0))
         (hit (or (plist-get usage :prompt_cache_hit_tokens)
                  (harness-plist-get-in usage '(:prompt_tokens_details :cached_tokens))
                  0))
         (miss (or (plist-get usage :prompt_cache_miss_tokens)
                   (max 0 (- input hit))))
         (cost (plist-get usage :cost))
         (plan (harness-openai--plan-status endpoint))
         (deepseek (or (harness-openai--deepseek-p endpoint)
                       (harness-openai--deepseek-usage-p usage))))
    (append
     (list :type 'usage
           :input (if deepseek miss input)
           :output (or (plist-get usage :completion_tokens) 0)
           :cache-read (if deepseek hit (or (harness-plist-get-in usage '(:prompt_tokens_details :cached_tokens)) 0))
           :cache-write 0)
     (if plan
         ;; The plan pays, as it does for Claude Code: the call is not
         ;; billed, and its value at API prices is priced from the
         ;; catalogue (`session/usage-add').
         (list :cost 0.0 :billing 'subscription :plan (plist-get plan :plan))
       (list :cost (and (numberp cost) cost) :billing 'api))
     (list :context (if deepseek (+ miss hit) input)))))

(defconst harness-openai--transport-patterns
  (concat "connection reset\\|recv failure\\|send failure\\|empty reply\\|broken pipe"
          "\\|could not connect\\|connection refused\\|connection timed out\\|timed out"
          "\\|no response headers"
          "\\|could not resolve\\|name or service not known\\|temporary failure in name resolution"
          "\\|ssl connect error\\|tls\\|eof occurred\\|network is unreachable\\|transport")
  "Regexps in an error's text that say the transport, not the request, failed.
A provider that goes on another host, or a gateway answering for one,
may report a connection failure in words rather than as an HTTP status;
a step that failed that way is worth trying again.")

(defun harness-openai--failure-kind (stream error)
  "Return the kind of failure STREAM ended with ERROR, or nil.
An HTTP 402 is out of money, a 401 or 403 a refused login, a 429 a
short-term rate limit unless its body says the account's quota is used
up (`insufficient_quota', DeepSeek's \"Insufficient Balance\"), and a
5xx or a connection-level failure (`transport') one another try may get
past.  Without a status, the error's text is read the same way."
  (let ((status (harness-openai--stream-status stream))
        (text (downcase (or error "")))
        (reported (harness-openai--stream-error-kind stream)))
    (cond
     ((and (eq reported 'transport) 'transport))
     ((and (integerp status) (or (= status 408) (<= 500 status 599))) 'transport)
     ((equal status 402) 'billing)
     ((member status '(401 403)) 'auth)
     ((equal status 429)
      (if (string-match-p "insufficient[ _-]quota\\|insufficient[ _-]balance" text)
          'billing
        'rate-limit))
     ((string-match-p "insufficient[ _-]quota" text) 'billing)
     ((string-match-p "insufficient[ _-]\\(balance\\|credits\\|funds\\)\\|no \\(?:ai \\)?credits\\|out of credits" text)
      'billing)
     ((string-match-p "rate[ _-]limit\\|too many requests" text) 'rate-limit)
     ((string-match-p harness-openai--transport-patterns text) 'transport)
     (t nil))))

(defun harness-openai--stream-finish (stream reason &optional error)
  "End STREAM with stop REASON and optional ERROR text, emitting once."
  (unless (harness-openai--stream-finished stream)
    (setf (harness-openai--stream-finished stream) t)
    (let ((on-event (harness-openai--stream-on-event stream))
          (calls (harness-openai--stream-calls stream)))
      (when-let* ((usage (harness-openai--stream-usage stream)))
        (unless (eq reason 'cancelled)
          (funcall on-event (harness-openai--usage-event usage (harness-openai--stream-endpoint stream)))))
      (when (eq reason 'tool-use)
        (dolist (slot calls)
          (let ((call (cdr slot)))
            (funcall on-event (list :type 'tool-call
                                    :id (or (plist-get call :id) (concat "call_" (harness-short-id)))
                                    :name (plist-get call :name)
                                    :input (harness-openai--parse-arguments (plist-get call :arguments))
                                    :respond nil)))))
      (funcall on-event (if error
                            (append (list :type 'done :stop-reason reason :error error)
                                    (when-let* ((kind (harness-openai--failure-kind stream error)))
                                      (list :error-kind kind))
                                    (when-let* ((after (harness-openai--stream-retry-after stream)))
                                      (list :retry-after after)))
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
               (stream (make-harness-openai--stream :on-event on-event :endpoint endpoint))
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
                 :timeout harness-openai--request-timeout
                 ;; A completion is worth repeating: a connection reset
                 ;; before any of the answer arrived is tried again by the
                 ;; HTTP layer, and one that got further is retried as a
                 ;; step, with the partial answer discarded (see
                 ;; `harness-retry').
                 :retry t
                 :on-headers (lambda (s headers)
                               (setq status s)
                               (setf (harness-openai--stream-status stream) s)
                               (when-let* ((after (harness-http-retry-after headers)))
                                 (setf (harness-openai--stream-retry-after stream) after))
                               ;; A refused answer carries the plan's windows
                               ;; too, which is how a turn learns when the
                               ;; limit it ran into resets.
                               (harness-openai--note-plan-headers endpoint on-event headers))
                 :on-chunk (lambda (chunk)
                             (if (and status (or (< status 200) (>= status 300)))
                                 (setq raw (concat raw chunk))
                               (funcall sse chunk)))
                 :callback (lambda (s _headers body err)
                             (let ((s (or s status)))
                               (setf (harness-openai--stream-status stream) s)
                               (cond
                                ((harness-openai--stream-finished stream) nil)
                                ((eq (car-safe err) 'cancelled)
                                 (harness-openai--stream-finish stream 'cancelled))
                                (err
                                 ;; What the HTTP layer says of the failure, not
                                 ;; what curl happened to print with it: the words
                                 ;; (`harness-openai--transport-patterns') come from
                                 ;; curl's standard error, which can still be on its
                                 ;; way when the process ends, and a reset that
                                 ;; reads "(curl 56)" alone was never tried again.
                                 (when (harness-http-transient-error-p err)
                                   (setf (harness-openai--stream-error-kind stream) 'transport))
                                 (harness-openai--stream-finish
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

;;;; Plan quota
;;
;; An OpenAI-compatible endpoint may spend somebody's ChatGPT plan: the
;; Codex route and the servers that front it answer with the plan's
;; windows in `x-codex-*' response headers, and an answer that reached a
;; limit says so in the error it fails with.  Those windows are reported
;; through `provider/quota', in the shape the other plans use (see
;; \"Plan quota\" in harness-provider.el), and a turn is told of them as
;; it runs, so a session's header shows them and the fallback module
;; moves off a provider whose plan is used up.
;;
;; Nothing is asked for here: the headers come with answers the harness
;; makes anyway, so reporting costs no request.  An endpoint whose
;; answers never carry them reports nothing, which is what
;; `provider/quota' answers nil for.

(defun harness-openai--plan-changes (headers)
  "Return the plan quota changes response HEADERS report, or nil.
A server that reports a plan's windows spends a plan, so the calls are
a subscription's: that is said here, with what the headers name.  The
headers are read whatever the endpoint claims, since it is they that
show the plan being spent."
  (when-let* ((changes (harness-provider-plan-rate-limit-headers headers)))
    (append changes (harness-openai--subscription-status))))

(defun harness-openai--publish-plan (endpoint changes)
  "Publish CHANGES about ENDPOINT's plan quota under what it knows.
Return the new status.  Nothing is emitted for an endpoint whose quota
did not change, which is every ordinary answer."
  (harness-provider-quota-publish
   (plist-get endpoint :id)
   (harness-openai--subscription-status)
   changes))

(defun harness-openai--subscription-status ()
  "Return what an endpoint that spends a ChatGPT plan says about billing.
Its answers cover the calls, so they are a subscription's rather than
per-token ones.  The plan's own name, when the server reports one,
comes with the windows and wins over this."
  (list :billing 'subscription
        :auth "chatgpt-plan"))

(defun harness-openai--plan-status (endpoint)
  "Return ENDPOINT's plan status when its calls are a subscription's, or nil.
An endpoint whose answers carried a plan's windows spends a plan, so
its calls are covered rather than billed, exactly as Claude Code's
are."
  (let ((status (harness-provider-quota-status (plist-get endpoint :id))))
    (when (eq (harness-billing-of status) 'subscription)
      status)))

(defun harness-openai--note-plan-headers (endpoint on-event headers)
  "Note the plan windows ENDPOINT's response HEADERS carry.
ON-EVENT, a stream's listener, hears the new windows as a `quota' event
when they changed, which is how a running turn learns of them."
  (when-let* ((changes (harness-openai--plan-changes headers)))
    (let* ((before (harness-provider-quota-status (plist-get endpoint :id)))
           (status (harness-openai--publish-plan endpoint changes))
           (windows (plist-get status :windows)))
      (when (and on-event windows
                 (not (equal windows (plist-get before :windows))))
        (funcall on-event (list :type 'quota :windows windows))))))

(defun harness-openai--quota (endpoint &optional refresh)
  "Return a promise of ENDPOINT's billing and quota, as `provider/quota' documents.
The plan's windows are the ones its answers last carried; REFRESH makes
no request, since an OpenAI-compatible server has no route to ask for
them, and is accepted for the interface's sake.  Nil until an answer
reports a plan."
  (ignore refresh)
  (harness-resolved
   (when-let* ((status (harness-provider-quota-status (plist-get endpoint :id))))
     (harness-provider-quota-update (harness-openai--subscription-status) status))))

;;;; Embeddings

(defun harness-openai--local-p (endpoint)
  "Non-nil when ENDPOINT's server runs on this machine: its host is a loopback one."
  (let ((host (downcase (or (harness-openai--host endpoint) ""))))
    (or (member host '("localhost" "::1" "[::1]"))
        (string-prefix-p "127." host)
        (string-suffix-p ".localhost" host))))

(defun harness-openai--embed (endpoint name texts opts)
  "Have model NAME of ENDPOINT embed TEXTS; return a promise.
It resolves to (:vectors VECTORS :usage (:input N)), one vector per
text in order, as `provider/embed' documents; OPTS `:dimensions' asks
for vectors that long.  The request is POST /embeddings, which OpenAI,
OpenRouter, Ollama, LM Studio, llama.cpp and vLLM answer.  In corporate
mode only a server on this machine is asked: the text would leave it
otherwise."
  (let ((key (harness-openai--api-key endpoint))
        (url (concat (harness-openai--base-url endpoint) "/embeddings"))
        (dims (plist-get opts :dimensions)))
    (cond
     ((and (harness-corporate-p) (not (harness-openai--local-p endpoint)))
      (harness-rejected
       (list 'error (format "corporate mode embeds text only on this machine, and %s is at %s"
                            (plist-get endpoint :id) (harness-openai--host endpoint)))))
     ((and (null key) (plist-get endpoint :api-key-env))
      (harness-rejected
       (list 'error (format "no API key for %s: set %s or add an auth-source entry for %s"
                            (plist-get endpoint :id) (plist-get endpoint :api-key-env)
                            (harness-openai--host endpoint)))))
     (t
      (harness-then
       (condition-case err
           (harness-http-request-json url :method "POST" :headers (harness-openai--headers endpoint key)
                                      :json (append (list :model name :input (vconcat texts))
                                                    (and dims (list :dimensions dims)))
                                      :timeout 120)
         (error (harness-rejected err)))
       (lambda (json)
         (let* ((data (plist-get json :data))
                (rows (and (listp data) (cl-every #'consp data)
                           (sort (copy-sequence data)
                                 (lambda (a b) (< (or (plist-get a :index) 0) (or (plist-get b :index) 0))))))
                (vectors (mapcar (lambda (row) (plist-get row :embedding)) rows))
                (usage (plist-get json :usage)))
           (if (and (= (length vectors) (length texts))
                    (cl-every (lambda (v) (and (consp v) (numberp (car v)))) vectors))
               (list :vectors vectors
                     :usage (list :input (or (and (consp usage)
                                                  (or (plist-get usage :prompt_tokens) (plist-get usage :total_tokens)))
                                             0)))
             (harness-rejected
              (list 'error (format "%s answered %d embeddings for %d texts"
                                   (plist-get endpoint :id) (length vectors) (length texts)))))))
       ;; Returned, not signalled: a server that is down fails every
       ;; request the background makes, and each would log an error.
       (lambda (err) (harness-rejected (list 'error (harness-openai--describe-error err)))))))))

;;;; Registration

(defun harness-openai-register-endpoint (endpoint)
  "Register ENDPOINT as an OpenAI-compatible provider and return its id.
ENDPOINT is a plist as described by `harness-openai-endpoints'.  It
is captured as it is, not looked up by id, so a module can register an
endpoint of its own without adding it to that option; call this again
to pick up a changed plist.  Such an endpoint may list its models its
own way with `:models-fn', a function that takes an optional REFRESH
flag and returns a promise of model plists, as the models function of
`harness-define-provider' does."
  (let ((id (plist-get endpoint :id)))
    (harness-define-provider id
      :label (or (plist-get endpoint :label) (symbol-name id))
      :doc (format "OpenAI-compatible endpoint at %s" (harness-openai--base-url endpoint))
      :models (or (plist-get endpoint :models-fn)
                  (lambda (&optional refresh) (harness-openai--models endpoint refresh)))
      :complete (lambda (request) (harness-openai--complete endpoint request))
      :quota (lambda (&optional refresh) (harness-openai--quota endpoint refresh))
      :embed (lambda (name texts opts) (harness-openai--embed endpoint name texts opts))
      :capabilities (harness-openai--capabilities endpoint)
      :tiers (plist-get endpoint :tiers))
    id))

(defun harness-openai--register (endpoint)
  "Register the provider described by ENDPOINT."
  (harness-openai-register-endpoint endpoint))

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
