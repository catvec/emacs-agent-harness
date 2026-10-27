;;; harness-provider-responses.el --- OpenAI Responses API provider for a ChatGPT plan  -*- lexical-binding: t; -*-

;;; Commentary:

;; A native-loop provider for the Responses API at
;; https://api.openai.com/v1/responses, paid for by the ChatGPT plan of
;; an account signed in with `harness-chatgpt-plan' (Sign in with
;; ChatGPT).  There is no API key anywhere: the OAuth access token of
;; the signed-in account is the bearer credential.
;;
;; The agent runs the tool loop and the provider only turns a request
;; into a streamed sequence of events, sending the whole history every
;; time.  Every request sets `store: false' and `stream: true', as this
;; route requires, and asks for `reasoning.encrypted_content' so that
;; the model's reasoning can be replayed with the tool calls it made.
;;
;; What this route takes, and what it refuses.  The requirements are
;; OpenAI's for ChatGPT-plan usage through `POST /v1/responses' (see
;; developers.openai.com/siwc/token-sharing-open-source/preview-limitations);
;; each one is honoured below, in one place:
;;
;; - The system prompt goes in `instructions'.  An explicit
;;   `{type: "message", role: "system"}' item is rejected, so none is
;;   ever built; a system message that arrives among the request's
;;   messages is folded into `instructions' too.
;; - `temperature', `top_p', `top_logprobs', `metadata', `moderation',
;;   `prompt', `background', `conversation', `previous_response_id',
;;   `truncation', `user', `prompt_cache_retention', `safety_identifier'
;;   and `multi_agent' are never sent.  The harness asks for none of
;;   them; `:max-tokens' is the one it does ask for and cannot be sent,
;;   which is why the request's budget is dropped (see below).
;; - `max_output_tokens' may not be sent, so a request that carries a
;;   small budget (the harness names a session with 40 tokens, and a
;;   one-off judge call with a few hundred) cannot be capped on the
;;   wire.  The prompt is what keeps such an answer short -- the naming
;;   module's own instruction is to reply with the title and nothing
;;   else -- and the budget is documented rather than faked: a caller
;;   that needs a hard cap has to use a provider that takes one.  The
;;   budget is kept in the request for the log and dropped here.
;; - Tools: the harness's function tools are sent as one
;;   `additional_tools' input item (role `developer'), which is one of
;;   the two forms this route documents; the other, a namespace in the
;;   top-level `tools', would rename every call.  A tool call comes back
;;   as a completed `function_call` item and its result goes back as a
;;   `function_call_output' item, so the pairing is by `call_id'.
;; - Image generation, file search, Code Interpreter, computer use,
;;   hosted MCP and connectors, `tool_search' and audio/video input are
;;   not sent.  A file block becomes a text note, as it does for the
;;   OpenAI-compatible provider; the Files upload API is never called.
;;
;; Reasoning.  With `store: false' nothing is kept server-side, so the
;; reasoning items of a turn must be sent back with the tool calls of
;; that turn or the model loses what it was thinking.  They are
;; remembered as the response delivered them: the `response.completed'
;; output items (and each `response.output_item.done') are kept, keyed
;; by the call ids of the function calls they belong to, and an
;; assistant message whose calls are remembered is sent back as exactly
;; those items, in order, reasoning first.  That is what the Bedrock
;; provider does for the same reason, and unlike the OpenAI-compatible
;; one (which drops thinking for every dialect but DeepSeek) nothing is
;; dropped here.  A thinking block whose response is not remembered --
;; a session resumed in another Emacs, a checkpoint -- is sent back only
;; when it carries a `:signature', which is taken for its encrypted
;; content; otherwise it is left out, since a reasoning item without
;; one is not worth sending.
;;
;; Streaming.  The events are server-sent, and `harness-http-sse-parser'
;; hands each complete one here.  `response.output_text.delta' is text
;; and `response.reasoning_summary_text.delta' (the summary the model
;; wrote about its thinking) or `response.reasoning_text.delta' (the
;; reasoning itself, for a model that streams it) is thinking.  A
;; function call is known once its item is done, its input streams as
;; `response.function_call_arguments.delta' (reported as `tool-input'
;; activity, so a long input is visible), and `response.completed' ends
;; the request: the usage comes from the response object, then the tool
;; calls go out, then `done'.  `response.failed' is an error carrying
;; the structured `error.code' -- `subscription_sharing_usage_limit_exceeded'
;; and its family (see `harness-responses--error-kind') -- and
;; `response.incomplete' says why the answer stopped short.
;;
;; Money.  The plan pays, so a call is recorded with `:billing
;; subscription' and `:cost' 0.  This route lists no prices, so there is
;; nothing to put in `:list-cost' and nothing is invented: the session
;; prices the record from the model catalogue as it prices any other,
;; which is 0 for a model the catalogue has no rates for.  That is
;; honest -- what the plan paid is not what the tokens would cost at
;; API list prices, and this provider does not know those.
;;
;; The catalogue.  `GET /v1/models' with the same token answers the
;; account's own model list, an array of `models' whose entries carry
;; `slug', `display_name' and `visibility'; the entries with
;; `visibility' "list" are the ones meant for a picker, and they become
;; the catalogue with the slug as the name and the display name as the
;; label.  The list is asked again when the account changes, and cached
;; for `harness-responses-models-ttl' seconds otherwise.  The route
;; lists no context window and no price either, so a window is
;; estimated by the catalogue (as for any provider that does not size a
;; model) and `:tiers' is a setting rather than something to be read.
;;
;; Registration.  The provider is registered only while an account with
;; a usable credential is signed in, and removed again when the last one
;; signs out (`chatgpt-plan/accounts-changed'), so the model picker
;; never offers the plan's models before there is a credential to call
;; them with, and `M-x harness-describe-module' says as much.  Call
;; `harness-responses-refresh' after changing the credentials from
;; another Emacs.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-chatgpt-plan)

;;;; Customisation

(defconst harness-responses-provider-id 'chatgpt
  "Provider id of the ChatGPT plan, whose model ids are \"chatgpt:NAME\".")

(defconst harness-responses--request-timeout 1800
  "Maximum seconds one Responses request may take, including streaming.
A reasoning model on a hard task can think for a long while before its
first token, and the whole reasoning counts against the request.")

(defconst harness-responses--progress-interval 0.25
  "Seconds between reports of how much of a tool call's arguments has streamed.")

(defconst harness-responses--models-ttl 3600
  "Seconds a fetched model list stays cached for the account it was for.")

(defconst harness-responses--responses-max 200
  "Most remembered responses kept for replaying reasoning.")

(defcustom harness-responses-base-url "https://api.openai.com/v1"
  "Base URL of the Responses API a ChatGPT plan pays for.
It is `harness-chatgpt-plan-api-base' by default, and the `resource' the
OAuth grant was given for: another value is another grant, and the
access token would not be accepted.  A test points it elsewhere."
  :type 'string :group 'harness)

(defcustom harness-responses-tiers
  '(:simple "mini\\|nano\\|flash"
    :medium "sol\\|gpt-6\\|gpt-5\\|o4"
    :hard "sol\\|max\\|pro"
    :frontier nil)
  "Model names or id regexps the ChatGPT plan names for the tiers.
The plan's catalogue carries no prices, so nothing can be ranked by
price here: a tier no pattern matches has no model, and the harness
falls back to the session's own model for the calls it would have made
on it (`provider/tier-model-info' says `none').  The values are
regexps over the model slugs the account lists, and the defaults are
the families ChatGPT's models are named after; change them to name the
models your plan lists.  `:simple' is what names sessions and judges
permissions, and `:frontier' is never chosen on the harness's own."
  :type harness-provider-tiers-type :group 'harness)

(defun harness-responses--custom-set (symbol value)
  "Set SYMBOL to VALUE and refresh the registration."
  (set-default symbol value)
  (when (fboundp 'harness-responses-refresh)
    (harness-responses-refresh)))

(defvar harness-responses--registered nil
  "Non-nil while this module registered the provider.")

(defvar harness-responses--models-cache nil
  "Cached model list, as (:for ACCOUNT :at TIME :models MODELS).")

(defvar harness-responses--responses (make-hash-table :test 'equal)
  "Tool call id -> (TIME . ITEMS) of the response that made the call.
ITEMS are the response's output items, reasoning included, which must
go back unchanged while the tool loop continues.")

;;;; Talking to the plan's account

(defun harness-responses--status ()
  "Return what `chatgpt-plan/status' says, or nil when that module is not loaded."
  (and (harness-method-exists-p 'chatgpt-plan/status)
       (ignore-errors (harness-call 'chatgpt-plan/status))))

(defun harness-responses--available-p ()
  "Non-nil when an account of the ChatGPT plan is signed in here."
  (let ((status (harness-responses--status)))
    (and status (harness-json-true-p (plist-get status :signed-in)) t)))

(defun harness-responses-available-p ()
  "Non-nil when the ChatGPT plan provider can be used here.
That is when `harness-chatgpt-plan' is loaded and an account with a
usable credential is signed in; with none there is nothing to call the
plan's models with, and the provider is not registered."
  (harness-responses--available-p))

(defun harness-responses--access-token ()
  "Return a promise of the token info of the signed-in account.
It is what `chatgpt-plan/access-token' answers, with `:token' the
bearer credential and `:base-url' the API root; a module that is not
loaded, and an account that has to be signed in again, reject."
  (if (harness-method-exists-p 'chatgpt-plan/access-token)
      (harness-call-async 'chatgpt-plan/access-token)
    (harness-rejected
     (list 'harness-error
           "No ChatGPT account is signed in: run M-x harness-chatgpt-plan-sign-in"))))

;;;; The model catalogue

(defun harness-responses--list-url ()
  "Return the URL the account's model list is fetched from."
  (concat (string-remove-suffix "/" harness-responses-base-url) "/models"))

(defun harness-responses--entry-model (entry)
  "Return the model plist of one ENTRY of the account's model list, or nil.
The route lists each model with the `slug' that goes in a request and
the `display_name' to show; an entry without a slug is skipped.  An
entry marked with a `visibility' other than \"list\" is one the picker
is not meant to show and is skipped too."
  (let ((slug (or (plist-get entry :slug) (plist-get entry :id)))
        (visibility (plist-get entry :visibility)))
    (when (and (stringp slug) (not (string-empty-p slug))
               (or (null visibility) (equal (format "%s" visibility) "list")))
      (let ((label (or (plist-get entry :display_name) (plist-get entry :name)))
            (model (list :name slug
                         ;; The route says nothing about how the model thinks;
                         ;; these are the levels the reasoning effort takes, so
                         ;; a session's level can be fitted to the model.
                         :thinking-levels '("minimal" "low" "medium" "high" "xhigh" "max"))))
        (when (and (stringp label) (not (string-empty-p label)))
          (setq model (plist-put model :label label)))
        model))))

(defun harness-responses--parse-models (json)
  "Return the models of JSON, a model-list response, as model plists.
The route answers with a `models' array; OpenAI's own schema, a `data'
array of ids, is read too, so a test or another deployment of the same
API works as it is."
  (let* ((entries (or (plist-get json :models) (plist-get json :data)))
         (entries (append entries nil)))
    (delq nil (mapcar #'harness-responses--entry-model
                      (cl-remove-if-not #'listp entries)))))

(defun harness-responses--fetch-models (token)
  "Return a promise of the models the account behind TOKEN lists."
  (harness-then
   (condition-case err
       (harness-http-request-json
        (harness-responses--list-url)
        :headers (list (cons "Authorization" (concat "Bearer " token)))
        :timeout 60)
     (error (harness-rejected err)))
   #'harness-responses--parse-models
   (lambda (err)
     (error "Cannot list the ChatGPT plan's models: %s"
            (harness-responses--describe-error err)))))

(defun harness-responses--describe-error (err)
  "Return ERR, a rejection of a request here, as a short message without a token."
  (pcase err
    (`(http-error ,status ,body)
     (let* ((json (and (stringp body) (ignore-errors (harness-json-parse body))))
            (error (plist-get json :error))
            (message (or (and (listp error) (plist-get error :message))
                         (plist-get json :detail)
                         (plist-get json :message))))
       (format "HTTP %s: %s" (or status "?")
               (if (stringp message) (harness-first-line message 300)
                 (harness-responses--failure-text body)))))
    (`(json-error ,status ,message) (format "HTTP %s: bad JSON (%s)" status message))
    (_ (harness-error-message err))))

(defun harness-responses--failure-text (body)
  "Return BODY, a failed response body, as a short line.
Before a stream opens, this route may answer with a `detail' string
rather than the usual error object (OpenAI's documentation says so),
so what a body says is diagnostic text and never a code."
  (if (and (stringp body) (not (string-blank-p body)))
      (harness-first-line (string-trim body) 300)
    "the request failed"))

(defun harness-responses--models (&optional refresh)
  "Return a promise of the plan's models, cached for a while.
The cache lasts `harness-responses--models-ttl' seconds.  REFRESH asks
the account again however fresh the cache is, which an account switch
does as well: a listing is cached for the account it was made for, and
signing in as somebody else lists theirs."
  (let ((account (plist-get (harness-responses--status) :active))
        (cache harness-responses--models-cache))
    (cond
     ((and (not refresh) cache
           (equal (plist-get cache :for) account)
           (< (- (float-time) (plist-get cache :at)) harness-responses--models-ttl))
      (harness-resolved (plist-get cache :models)))
     (t
      (harness-then
       (harness-then (harness-responses--access-token)
                     (lambda (info) (harness-responses--fetch-models (plist-get info :token))))
       (lambda (models)
         (setq harness-responses--models-cache
               (list :for account :at (float-time) :models models))
         models)
       (lambda (err)
         ;; A listing that fails answers with what was listed before, when
         ;; there is any, rather than leaving the picker empty for good.
         (if cache
             (progn
               (harness-log 'warn "responses: listing models failed: %s; keeping the %d listed before"
                            (harness-error-message err) (length (plist-get cache :models)))
               (plist-get cache :models))
           (signal (car err) (cdr err)))))))))

;;;; Request body

(defun harness-responses--string (value)
  "Return VALUE as a string; symbols and keywords lose their punctuation."
  (cond ((null value) nil)
        ((stringp value) value)
        ((keywordp value) (substring (symbol-name value) 1))
        ((symbolp value) (symbol-name value))
        (t (format "%s" value))))

(defun harness-responses--block-type (block)
  "Return BLOCK's `:type' as a string."
  (harness-responses--string (plist-get block :type)))

(defvar harness-responses--mime-types
  '(("png" . "image/png") ("jpg" . "image/jpeg") ("jpeg" . "image/jpeg")
    ("gif" . "image/gif") ("webp" . "image/webp") ("bmp" . "image/bmp"))
  "File extension -> MIME type for an image read off disk.")

(defun harness-responses--file-base64 (path)
  "Return the contents of PATH base64 encoded without line breaks."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (base64-encode-string (buffer-string) t)))

(defun harness-responses--image-part (block)
  "Return an `input_image' part for the image BLOCK, or nil.
`:data' is taken as it is; a block with only a `:path' is read, and one
that cannot be read yields nil, which becomes a text note instead of
failing the whole request."
  (let* ((path (plist-get block :path))
         (mime (or (plist-get block :mime)
                   (and path (cdr (assoc (downcase (or (file-name-extension path) ""))
                                         harness-responses--mime-types)))
                   "image/png"))
         (data (or (plist-get block :data)
                   (and path (condition-case nil
                                 (harness-responses--file-base64 path)
                               (file-error nil))))))
    (when data
      (list :type "input_image"
            :image_url (format "data:%s;base64,%s" mime data)))))

(defun harness-responses--text-part (text)
  "Return TEXT as an `input_text' part."
  (list :type "input_text" :text (or text "")))

(defun harness-responses--content-parts (blocks)
  "Return the input content parts of user BLOCKS.
Text and images are the two this route takes; a file is a note naming it
\(the Files upload API is not supported here) and anything else is
dropped."
  (delq nil
        (mapcar (lambda (block)
                  (pcase (harness-responses--block-type block)
                    ("text" (harness-responses--text-part (plist-get block :text)))
                    ("image" (or (harness-responses--image-part block)
                                 (harness-responses--text-part "[an image could not be read]")))
                    ("file" (harness-responses--text-part
                             (format "[attached file: %s]"
                                     (or (plist-get block :path) (plist-get block :name) "?"))))
                    (_ nil)))
                blocks)))

(defun harness-responses--result-text (content)
  "Flatten a tool result CONTENT (string or list of blocks) into a string."
  (cond ((null content) "")
        ((stringp content) content)
        ((listp content)
         (mapconcat (lambda (b)
                      (if (stringp b) b
                        (or (plist-get b :text)
                            (and (equal (harness-responses--block-type b) "image") "[image]")
                            "")))
                    content "\n"))
        (t (format "%s" content))))

(defun harness-responses--tool-output (block)
  "Return the `output' of a `function_call_output' item for tool_result BLOCK.
It is the result's text, or -- when the result carries images, the ones
the model is to see -- an array of text and image content, which this
route takes in a `function_call_output' item where the OpenAI-compatible
one has to lift the images into a following user message."
  (let ((images (delq nil (mapcar #'harness-responses--image-part
                                  (append (plist-get block :images) nil)))))
    (if (null images)
        (harness-responses--result-text (plist-get block :content))
      (append (list (harness-responses--text-part
                     (harness-responses--result-text (plist-get block :content))))
              images))))

(defun harness-responses--function-call (block)
  "Return the `function_call' item for assistant tool_use BLOCK.
The harness pairs a result with its call by the call's id, so that id is
the item's `call_id': it is what `function_call_output' refers to."
  (list :type "function_call"
        :call_id (plist-get block :id)
        :name (plist-get block :name)
        :arguments (if (plist-get block :input)
                       (harness-json-encode-text (plist-get block :input))
                     "{}")))

(defun harness-responses--reasoning-item (block)
  "Return a `reasoning' item for thinking BLOCK, or nil to leave it out.
Only a block that carries a `:signature' can go back: with `store:
false' the encrypted content is what lets the model resume its own
reasoning, and a reasoning item without it says nothing useful."
  (let ((signature (plist-get block :signature)))
    (when (and (stringp signature) (not (string-empty-p signature)))
      (list :type "reasoning"
            :summary (harness-json-array
                      (list (list :type "summary_text" :text (or (plist-get block :text) ""))))
            :encrypted_content signature))))

;;;; Remembering a response, to replay its reasoning

(defun harness-responses--response-key (items)
  "Return the call ids of the function calls among ITEMS, or nil."
  (let ((ids (delq nil (mapcar (lambda (item)
                                 (and (equal (plist-get item :type) "function_call")
                                      (plist-get item :call_id)))
                               items))))
    (and ids (cons (car ids) ids))))

(defun harness-responses--remember (items)
  "Keep ITEMS, a response's output items, under the call ids they made.
Only a response that called a tool is kept: its reasoning has to go back
with those calls, and nothing else is ever replayed."
  (when-let* ((key (harness-responses--response-key items)))
    (when (> (hash-table-count harness-responses--responses) harness-responses--responses-max)
      (let (entries)
        (maphash (lambda (k v) (push (cons (car v) k) entries)) harness-responses--responses)
        (dolist (entry (seq-take (sort entries (lambda (a b) (< (car a) (car b))))
                                 (/ harness-responses--responses-max 2)))
          (remhash (cdr entry) harness-responses--responses))))
    (let ((entry (cons (float-time) items)))
      (dolist (id (cdr key))
        (puthash id entry harness-responses--responses)))))

(defun harness-responses--remembered (blocks)
  "Return the remembered output items for the calls in assistant BLOCKS, or nil.
The whole response is returned when every call id the message made is
one it was remembered under, so that a message half-remembered never
comes back as a mixture of what the model said and what the harness
made up."
  (let* ((ids (delq nil (mapcar (lambda (b) (and (equal (harness-responses--block-type b) "tool_use")
                                                 (plist-get b :id)))
                                blocks)))
         (entry (and ids (gethash (car ids) harness-responses--responses)))
         (kept (and entry (cdr entry))))
    (and kept
         (cl-every (lambda (id) (gethash id harness-responses--responses)) ids)
         (equal (harness-responses--response-key kept) (cons (car ids) ids))
         kept)))

(defun harness-responses--strip-item (item)
  "Return ITEM, an output item, as it is sent back in `input'.
The lifecycle `status' is a response's own bookkeeping and is dropped;
everything else -- the id, the reasoning's summary and encrypted
content, the call's name and arguments -- goes back as it came."
  (let (out)
    (cl-loop for (key value) on item by #'cddr
             unless (eq key :status)
             do (setq out (plist-put out key value)))
    out))

;;;; Input items

(defun harness-responses--tools (specs)
  "Return the harness tool SPECS as this route's function tools, or nil."
  (delq nil
        (mapcar (lambda (spec)
                  (when (plist-get spec :name)
                    (list :type "function"
                          :name (plist-get spec :name)
                          :description (or (plist-get spec :description) "")
                          :parameters (let ((schema (plist-get spec :schema)))
                                        (if (and (listp schema) (keywordp (car-safe schema)))
                                            schema
                                          '(:type "object" :properties :empty))))))
                specs)))

(defun harness-responses--additional-tools-item (tools)
  "Return the `additional_tools' input item that carries TOOLS.
This route takes the harness's function tools either grouped under a
namespace in its top-level `tools' or brought in by one of these items;
the item is used here because it keeps each tool's own name."
  (list :type "additional_tools" :role "developer" :tools (harness-json-array tools)))

(defun harness-responses--assistant-items (blocks)
  "Return the input items of an assistant message with BLOCKS.
A message whose calls are remembered goes back exactly as the response
delivered it -- reasoning items, function calls and the text -- so the
model keeps the chain of thought it had; otherwise its text and calls
are built from the blocks, and a thinking block only when it carries a
signature."
  (if-let* ((remembered (harness-responses--remembered blocks)))
      (mapcar #'harness-responses--strip-item remembered)
    (delq nil
          (mapcar (lambda (block)
                    (pcase (harness-responses--block-type block)
                      ("text" (when-let* ((text (plist-get block :text)))
                                (and (not (string-empty-p text))
                                     (list :role "assistant"
                                           :content (harness-json-array
                                                     (list (list :type "output_text" :text text)))))))
                      ("thinking" (harness-responses--reasoning-item block))
                      ("tool_use" (harness-responses--function-call block))
                      (_ nil)))
                  blocks))))

(defun harness-responses--message-items (msg)
  "Return the input items of one harness MSG.
An assistant message is its remembered response or its blocks rebuilt
\(see `harness-responses--assistant-items'); a system message yields
nothing, since the system prompt goes in `instructions'; anything else
is the conversation, and its tool results become items of their own."
  (let ((role (harness-responses--string (plist-get msg :role)))
        (blocks (let ((content (plist-get msg :content)))
                  (if (stringp content) (list (list :type "text" :text content)) content))))
    (pcase role
      ("assistant" (harness-responses--assistant-items blocks))
      ("system" nil)
      (_
       (let (items parts)
         (dolist (block blocks)
           (if (equal (harness-responses--block-type block) "tool_result")
               ;; A result is an item of its own, right after the call it
               ;; answers; the route pairs them by `call_id'.
               (push (list :type "function_call_output"
                           :call_id (plist-get block :tool_use_id)
                           :output (harness-responses--tool-output block))
                     items)
             (when-let* ((part (and (member (harness-responses--block-type block) '("text" "image" "file"))
                                    (car (harness-responses--content-parts (list block))))))
               (push part parts))))
         (when parts
           (push (list :role (if (equal role "tool") "user" role)
                       :content (harness-json-array (nreverse parts)))
                 items))
         (nreverse items))))))

(defun harness-responses--system-text (request)
  "Return the system prompt of REQUEST as one string, or nil.
The harness sends it as `:system', which goes in `instructions'; a
system message among the request's messages is folded in here as well,
since a `{type: \"message\", role: \"system\"}' item would be rejected."
  (let ((texts nil))
    (when-let* ((system (plist-get request :system)))
      (unless (string-blank-p system) (push system texts)))
    (dolist (msg (plist-get request :messages))
      (when (equal (harness-responses--string (plist-get msg :role)) "system")
        (let ((text (harness-responses--result-text (plist-get msg :content))))
          (unless (string-blank-p text) (push text texts)))))
    (and texts (string-join (nreverse texts) "\n\n"))))

(defun harness-responses--history-items (request)
  "Return the conversation items of REQUEST, oldest first."
  (apply #'append (mapcar #'harness-responses--message-items (plist-get request :messages))))

(defun harness-responses--input (request)
  "Return the `input' array of REQUEST.
It is the tool definitions, brought in by an `additional_tools' item,
followed by the whole history: this route takes no
`previous_response_id' and nothing is stored, so every request carries
what came before it."
  (let ((items (harness-responses--history-items request)))
    (if-let* ((tools (harness-responses--tools (plist-get request :tools))))
        (cons (harness-responses--additional-tools-item tools) items)
      items)))

(defconst harness-responses--efforts
  '("none" "minimal" "low" "medium" "high" "xhigh" "max")
  "Reasoning efforts this route accepts, weakest first.")

(defun harness-responses--effort (level)
  "Return the reasoning effort of the harness thinking LEVEL, or nil.
The levels are the same ladder; a level the route does not know yields
nil and no effort is asked for, which leaves the model's own default."
  (let ((name (harness-responses--string (and level (if (eq level 'none) "none" level)))))
    (and (member name harness-responses--efforts) name)))

(defun harness-responses--reasoning (request)
  "Return REQUEST's `reasoning' object, or nil for the model's default.
`:no-thinking' wins over `:thinking', as it does for the other providers,
and asks for the effort that turns reasoning off.  A summary is asked
for whenever thinking is not off, which is what the chat shows as
thinking: without it the model's reasoning never reaches the harness."
  (let* ((off (plist-get request :no-thinking))
         (level (if off "none" (harness-responses--effort (plist-get request :thinking)))))
    (cond
     (off (list :effort "none"))
     ((and level (equal level "none")) (list :effort "none"))
     (level (list :effort level :summary "auto"))
     (t (list :summary "auto")))))

(defun harness-responses--body (name request)
  "Build the Responses request body for model NAME from REQUEST.
`store: false' and `stream: true' are set on every request, as this
route requires, and so is asking for the encrypted reasoning.  A key the
route refuses is never written here; see the Commentary for the list,
and for why a request's `:max-tokens' does not reach the wire."
  (let ((body (list :model name
                    :input (harness-json-array (harness-responses--input request))
                    :store :false
                    :stream t
                    :include (harness-json-array '("reasoning.encrypted_content"))))
        (instructions (harness-responses--system-text request))
        (reasoning (harness-responses--reasoning request)))
    (when instructions
      (setq body (plist-put body :instructions instructions)))
    (when reasoning
      (setq body (plist-put body :reasoning reasoning)))
    ;; This route takes no `max_output_tokens', so a request's budget
    ;; cannot be enforced on the wire; it is logged, once per request,
    ;; so a caller that expected a cap can see that it is not there.
    (when-let* ((max (plist-get request :max-tokens)))
      (harness-log 'debug "responses: %s asked for at most %s tokens, which this route does not take"
                   name max))
    body))

;;;; Error codes

(defconst harness-responses--error-kinds
  '(("subscription_sharing_usage_limit_exceeded" . quota)
    ("subscription_sharing_user_not_eligible" . auth)
    ("subscription_sharing_usage_unavailable" . transport)
    ("subscription_sharing_unsupported_capability" . request)
    ("subscription_sharing_route_not_supported" . request)
    ("subscription_sharing_invalid_user" . auth)
    ("subscription_sharing_user_unavailable" . transport)
    ("chatpass_v2_scope_not_authorized" . auth)
    ("chatpass_v2_invalid_authorization_context" . auth)
    ("invalid_user" . auth)
    ("invalid_api_key" . auth)
    ("rate_limit_exceeded" . rate-limit)
    ("insufficient_quota" . billing)
    ("server_error" . transport))
  "Structured error codes of this route -> the kind the harness knows.
Each is what OpenAI documents for ChatGPT-plan usage through the
Responses API (`subscription_sharing_*`, `chatpass_v2_*`) or a code of
the Responses API itself.  A kind decides what happens next: `quota'
stops the provider for a while, `billing' takes it out of the running,
`auth' says the credential has to be looked at, `transport' and
`rate-limit' are worth trying again, and `request' says the body was
wrong and trying it again would not help.")

(defun harness-responses-error-kind (code status)
  "Return the kind of failure CODE, a structured error code, with STATUS.
The code decides when the route names one; a status is what is left
when it does not.  See `harness-responses--error-kinds' for the kinds."
  (or (cdr (assoc code harness-responses--error-kinds))
      (pcase status
        ((or 401 403) 'auth)
        (402 'billing)
        (429 'rate-limit)
        ((or 408 500 502 503 504) 'transport)
        (_ nil))))

(defun harness-responses--error-status-kind (status)
  "Return the kind of an HTTP failure STATUS with no code to read."
  (harness-responses-error-kind nil status))

;;;; Streaming

(cl-defstruct (harness-responses--stream (:copier nil))
  "Accumulated state of one streamed Responses request."
  on-event name http model finished (status nil) (raw "") (error nil) (error-kind nil)
  retry-after usage stop-reason calls items cancelled
  (progress (make-hash-table :test 'equal)))

(defun harness-responses--emit (stream event)
  "Send EVENT to STREAM's listener."
  (funcall (harness-responses--stream-on-event stream) event))

(defun harness-responses--call-slot (stream index)
  "Return the accumulator of function call INDEX of STREAM, making it once."
  (or (assoc index (harness-responses--stream-calls stream))
      (let ((slot (cons index (list :call-id nil :name nil :arguments ""))))
        (setf (harness-responses--stream-calls stream)
              (append (harness-responses--stream-calls stream) (list slot)))
        slot)))

(defun harness-responses--tool-input-progress (stream slot)
  "Report the size of the arguments STREAM has received for SLOT.
The calls themselves go out once the response is complete, so this is
all that shows a model writing a large input.  At most one report every
`harness-responses--progress-interval' seconds per call."
  (let ((call (cdr slot))
        (now (float-time)))
    (when (and (plist-get call :name)
               (let ((sent (plist-get call :sent-at)))
                 (or (null sent) (>= (- now sent) harness-responses--progress-interval))))
      (setcdr slot (plist-put call :sent-at now))
      (harness-responses--emit
       stream (list :type 'activity :phase 'tool-input :tool (plist-get call :name)
                    :chars (length (or (plist-get call :arguments) "")))))))

(defun harness-responses--item-done (stream index item)
  "Note the completed output ITEM at INDEX of STREAM.
A function call is kept with the id its result will answer, its name and
the arguments it made; the item's own `status' is bookkeeping and is
dropped with the rest of the item, which is kept whole for replaying."
  (when (and (listp item)
             (equal (harness-responses--string (plist-get item :type)) "function_call"))
    (let* ((index (or index (length (harness-responses--stream-calls stream))))
           (slot (harness-responses--call-slot stream index))
           (call (cdr slot)))
      (setcdr slot (plist-put call :call-id (or (plist-get item :call_id)
                                                (plist-get call :call-id))))
      (setcdr slot (plist-put (cdr slot) :name (or (plist-get item :name)
                                                   (plist-get call :name))))
      (when-let* ((arguments (plist-get item :arguments)))
        (setcdr slot (plist-put (cdr slot) :arguments arguments))))))

(defun harness-responses--note-item (stream item)
  "Keep ITEM, an output item of STREAM, in the order it arrived."
  (when (listp item)
    (setf (harness-responses--stream-items stream)
          (append (harness-responses--stream-items stream) (list item)))))

(defun harness-responses--event-failed (stream response)
  "End STREAM as failed, as the failed RESPONSE says.
The structured `error.code' is kept whole, both as the message and as
the kind of failure the harness decides on."
  (let* ((error (plist-get response :error))
         (code (and (listp error) (plist-get error :code)))
         (code (and code (format "%s" code)))
         (message (and (listp error) (plist-get error :message)))
         (text (format "%s%s" (or code "the request failed")
                       (if (and (stringp message) (not (string-empty-p message)))
                           (format ": %s" message)
                         ""))))
    (harness-responses--finish stream 'error text
                               (harness-responses-error-kind code nil))))

(defun harness-responses--event-incomplete (stream response)
  "End STREAM as the incomplete RESPONSE says.
A response cut off at the output limit is `max-tokens' for the harness
\(though no limit was asked for, a model's own ceiling can cut it off);
one stopped by the content filter is an error; anything else is an
answer that simply ended."
  (let* ((details (plist-get response :incomplete_details))
         (reason (harness-responses--string (plist-get details :reason))))
    (pcase reason
      ("max_output_tokens" (harness-responses--finish stream 'max-tokens))
      ("content_filter" (harness-responses--finish stream 'error
                                                   "the response was stopped by the content filter"))
      (_ (harness-responses--finish stream 'end-turn)))))

(defun harness-responses--event-completed (stream response)
  "End STREAM as the completed RESPONSE says, recording its usage and calls."
  (let ((usage (plist-get response :usage))
        (items (append (plist-get response :output) nil)))
    (when (listp usage) (setf (harness-responses--stream-usage stream) usage))
    ;; The completed response is the authority on its output items: what
    ;; arrived item by item is the same list, and this is what is replayed.
    (dolist (item items) (harness-responses--note-item--once stream item))
    (harness-responses--remember (harness-responses--stream-items stream))
    (harness-responses--finish stream
                               (if (harness-responses--stream-calls stream) 'tool-use 'end-turn))))

(defun harness-responses--note-item--once (stream item)
  "Keep ITEM in STREAM's items unless an item with its id is there already.
A response reports each output item both as it lands and again in the
completed response, and the id is what an item is, so one copy is kept."
  (let ((id (plist-get item :id))
        (kept (harness-responses--stream-items stream)))
    (unless (and (stringp id)
                 (cl-find id kept :key (lambda (i) (plist-get i :id)) :test #'equal))
      (harness-responses--note-item stream item))))

(defun harness-responses--sse (stream event data)
  "Handle one SSE EVENT with DATA for STREAM.
This is the whole mapping of the route's event stream onto the
harness's provider events; an event the harness has no use for (an
in-progress marker, a content part that is not text, an annotation) is
read and dropped."
  (when (and (stringp data) (not (string-empty-p data)))
    (let* ((json (condition-case err
                     (harness-json-parse data)
                   (error (harness-log 'warn "responses: unreadable event (%s): %s"
                                       (harness-error-message err)
                                       (harness-first-line data 200))
                          nil)))
           (type (harness-responses--string (or (plist-get json :type) event))))
      (when (listp json)
        (pcase type
          ((or "response.created" "response.in_progress" "response.queued") nil)
          ("response.output_item.added"
           (let ((item (plist-get json :item)))
             (when (and (listp item)
                        (equal (harness-responses--string (plist-get item :type)) "function_call"))
               (let* ((index (or (plist-get json :output_index)
                                 (length (harness-responses--stream-calls stream))))
                      (slot (harness-responses--call-slot stream index)))
                 (setcdr slot (plist-put (cdr slot) :name (plist-get item :name)))
                 (setcdr slot (plist-put (cdr slot) :call-id
                                         (or (plist-get item :call_id) (plist-get item :id))))
                 (harness-responses--tool-input-progress stream slot)))))
          ("response.function_call_arguments.delta"
           (let* ((index (or (plist-get json :output_index) 0))
                  (slot (harness-responses--call-slot stream index))
                  (delta (plist-get json :delta)))
             (when (stringp delta)
               (setcdr slot (plist-put (cdr slot) :arguments
                                       (concat (or (plist-get (cdr slot) :arguments) "") delta))))
             (unless (plist-get (cdr slot) :name)
               (setcdr slot (plist-put (cdr slot) :name (plist-get json :name))))
             (harness-responses--tool-input-progress stream slot)))
          ("response.function_call_arguments.done"
           (let* ((index (or (plist-get json :output_index) 0))
                  (slot (harness-responses--call-slot stream index)))
             (when-let* ((arguments (plist-get json :arguments)))
               (setcdr slot (plist-put (cdr slot) :arguments arguments)))))
          ("response.output_item.done"
           (harness-responses--item-done stream (plist-get json :output_index) (plist-get json :item))
           (harness-responses--note-item--once stream (plist-get json :item)))
          ("response.output_text.delta"
           (let ((delta (plist-get json :delta)))
             (when (and (stringp delta) (not (string-empty-p delta)))
               (harness-responses--emit stream (list :type 'text :delta delta)))))
          ("response.refusal.delta"
           (let ((delta (plist-get json :delta)))
             (when (and (stringp delta) (not (string-empty-p delta)))
               (harness-responses--emit stream (list :type 'text :delta delta)))))
          ((or "response.reasoning_summary_text.delta" "response.reasoning_text.delta")
           (let ((delta (plist-get json :delta)))
             (when (and (stringp delta) (not (string-empty-p delta)))
               (harness-responses--emit stream (list :type 'thinking :delta delta)))))
          ("response.completed" (harness-responses--event-completed stream (plist-get json :response)))
          ("response.failed" (harness-responses--event-failed stream (plist-get json :response)))
          ("response.incomplete" (harness-responses--event-incomplete stream (plist-get json :response)))
          ("error"
           (let ((code (plist-get json :code))
                 (message (plist-get json :message)))
             (harness-responses--finish
              stream 'error
              (format "%s%s" (or code "the request failed")
                      (if (stringp message) (format ": %s" message) ""))
              (harness-responses-error-kind (and code (format "%s" code)) nil))))
          (_ nil))))))

(defun harness-responses--usage-event (usage)
  "Build the usage event from a Responses USAGE object.
The plan pays, so the call is recorded as `subscription' with no cost;
the cache the prompt was read from is reported, since this route does
not bill it but the session's own accounting wants to know."
  (let ((input (or (plist-get usage :input_tokens) 0))
        (output (or (plist-get usage :output_tokens) 0))
        (cached (or (harness-plist-get-in usage '(:input_tokens_details :cached_tokens)) 0)))
    (list :type 'usage
          :input input
          :output output
          :cache-read cached
          :cache-write (or (harness-plist-get-in usage '(:input_tokens_details :cache_write_tokens)) 0)
          :cost 0.0
          ;; Nothing is invented for the list price: `session/usage-add'
          ;; prices the record from the model catalogue, which has no rates
          ;; for this route, and a plan-covered call is free either way.
          :billing 'subscription
          :context (+ input cached)
          :last-output output)))

(defun harness-responses--finish (stream reason &optional error kind)
  "End STREAM with stop REASON and optional ERROR of kind KIND, once.
The usage comes first, then the tool calls the response made, then the
`done' event: the same order the other providers use, so a turn that
ran tools records them before it is over."
  (unless (harness-responses--stream-finished stream)
    (setf (harness-responses--stream-finished stream) t)
    (when-let* ((usage (harness-responses--stream-usage stream)))
      (unless (eq reason 'cancelled)
        (harness-responses--emit stream (harness-responses--usage-event usage))))
    (when (eq reason 'tool-use)
      (dolist (slot (harness-responses--stream-calls stream))
        (let ((call (cdr slot)))
          (when (plist-get call :name)
            (harness-responses--emit
             stream (list :type 'tool-call
                          :id (or (plist-get call :call-id) (concat "call_" (harness-short-id)))
                          :name (plist-get call :name)
                          :input (harness-responses--parse-arguments (plist-get call :arguments))
                          :respond nil))))))
    (harness-responses--emit
     stream (if error
                (append (list :type 'done :stop-reason reason :error error)
                        (when-let* ((kind (or kind (harness-responses--stream-error-kind stream))))
                          (list :error-kind kind))
                        (when-let* ((after (harness-responses--stream-retry-after stream)))
                          (list :retry-after after)))
              (list :type 'done :stop-reason reason)))))

(defun harness-responses--parse-arguments (raw)
  "Parse tool call arguments RAW (a JSON string) into a plist."
  (if (or (null raw) (string-empty-p (string-trim raw)))
      nil
    (condition-case err
        (harness-json-parse raw)
      (error (harness-log 'warn "responses: unparsable tool arguments: %s"
                          (harness-error-message err))
             (list :raw raw)))))

;;;; One request

(defun harness-responses--headers (token)
  "Return the request headers authenticated with TOKEN.
The token goes in a header and nowhere else: never in the URL, never
in a body, and never in a log line."
  (list (cons "Authorization" (concat "Bearer " token))))

(defun harness-responses--pre-stream-error (stream status body)
  "End STREAM as failed, as the pre-stream BODY of STATUS says.
Before a stream opens this route may answer with the usual error object
or with a bare `detail' string, so both are read; the code is the
structured one when there is one, and the HTTP status decides the kind
otherwise."
  (let* ((json (and (stringp body) (not (string-blank-p body))
                    (ignore-errors (harness-json-parse body))))
         (error (and (listp json) (plist-get json :error)))
         (code (cond ((stringp error) error)
                     ((and (listp error) (plist-get error :code))
                      (format "%s" (plist-get error :code)))))
         (message (cond ((and (listp error) (plist-get error :message)) (plist-get error :message))
                        ((and (listp json) (stringp (plist-get json :detail))) (plist-get json :detail))
                        ((and (listp json) (stringp (plist-get json :message))) (plist-get json :message))))
         (text (format "%s%s" (or code (format "HTTP %s" (or status "?")))
                       (if (and (stringp message) (not (string-empty-p message)))
                           (format ": %s" (harness-first-line message 300))
                         (if code "" (format ": %s" (harness-responses--failure-text body)))))))
    (harness-responses--finish stream 'error text
                               (harness-responses-error-kind code status))))

(defun harness-responses--start (stream request info)
  "Send the request of STREAM, authenticated with the token in INFO.
REQUEST is the harness request it was built from."
  (if (harness-responses--stream-finished stream)
      nil
    (let* ((token (plist-get info :token))
           (sse (harness-http-sse-parser
                 (lambda (event data) (harness-responses--sse stream event data)))))
      (condition-case err
          (setf (harness-responses--stream-http stream)
                (harness-http-request
                 (concat (string-remove-suffix "/" harness-responses-base-url) "/responses")
                 :method "POST"
                 :headers (harness-responses--headers token)
                 :json (harness-responses--body (harness-responses--stream-name stream) request)
                 :timeout harness-responses--request-timeout
                 ;; A streaming completion is worth repeating when the
                 ;; connection failed before any of the answer arrived; the
                 ;; HTTP layer never repeats one that delivered bytes.
                 :retry t
                 :on-headers (lambda (status _headers)
                               (setf (harness-responses--stream-status stream) status))
                 :on-chunk (lambda (chunk)
                             (if (and (harness-responses--stream-status stream)
                                      (>= (harness-responses--stream-status stream) 300))
                                 (setf (harness-responses--stream-raw stream)
                                       (concat (harness-responses--stream-raw stream) chunk))
                               (funcall sse chunk)))
                 :callback (lambda (status _headers body err)
                             (let ((status (or status (harness-responses--stream-status stream))))
                               (cond
                                ((harness-responses--stream-finished stream) nil)
                                ((eq (car-safe err) 'cancelled)
                                 (harness-responses--finish stream 'cancelled))
                                (err (harness-responses--finish
                                      stream 'error (harness-error-message (cadr err))
                                      (and (harness-http-transient-error-p err) 'transport)))
                                ((and status (>= status 300))
                                 (harness-responses--pre-stream-error
                                  stream status
                                  (let ((raw (harness-responses--stream-raw stream)))
                                    (if (string-empty-p raw) (or body "") raw))))
                                ;; A stream that ended without any terminal
                                ;; event is a cut connection, not an answer.
                                ((not (harness-responses--terminal-p stream))
                                 (harness-responses--finish
                                  stream 'error "the stream ended without response.completed"
                                  'transport))
                                (t nil))))))
        (error (harness-responses--finish stream 'error (harness-error-message err)))))))

(defun harness-responses--terminal-p (stream)
  "Non-nil when STREAM saw a terminal event of its response.
`response.completed', `response.failed' and `response.incomplete' all
end a stream; this says whether one of them arrived, which is what
OpenAI's own example checks before treating inference as successful.  A
stream that ended without one is a connection cut in the middle."
  (harness-responses--stream-finished stream))

(defun harness-responses--complete (request)
  "Start a streamed Responses completion for REQUEST; return a handle.
The access token of the signed-in account is fetched first, refreshing
it if it is close to expiry; the request is sent when it arrives, so
nothing blocks.  A request whose account has to be signed in again
fails with a `done' event saying so."
  (let* ((on-event (or (plist-get request :on-event) #'ignore))
         (name (cdr (harness-provider-parse-model (plist-get request :model))))
         (stream (make-harness-responses--stream :on-event on-event :name name)))
    (harness-responses--emit stream (list :type 'start))
    (harness-then
     (harness-responses--access-token)
     (lambda (info) (harness-responses--start stream request info))
     (lambda (err)
       (harness-responses--finish stream 'error (harness-error-message err) 'auth)))
    (list :cancel (lambda ()
                    (unless (harness-responses--stream-finished stream)
                      (setf (harness-responses--stream-cancelled stream) t)
                      (when-let* ((http (harness-responses--stream-http stream)))
                        (harness-http-cancel http))
                      (harness-responses--finish stream 'cancelled))))))

;;;; Quota

(defun harness-responses--quota (&optional _refresh)
  "Return a promise of what is known about the account's billing.
The ChatGPT plan pays for these calls, so the billing is a subscription
and there is no balance to report; the account's email and the granted
scopes come from the sign-in, without any token."
  (let* ((status (harness-responses--status))
         (accounts (plist-get status :accounts))
         (account (cl-find-if (lambda (a) (plist-get a :plan-usage)) accounts)))
    (harness-resolved
     (when (or account accounts)
       (list :billing 'subscription
             :auth "chatgpt"
             :plan-label "ChatGPT plan"
             :account (list :email (plist-get (or account (car accounts)) :email))
             :available nil)))))

;;;; Registration

(defun harness-responses-refresh ()
  "Register the provider when an account is signed in, else remove it.
Called when the module starts, when the credentials in this Emacs
change (`chatgpt-plan/accounts-changed') and by `harness-responses-refresh'
after they change elsewhere.  Return the provider id when registered,
nil when there is nothing to call the plan's models with."
  (interactive)
  (if (harness-responses--available-p)
      (progn
        (harness-define-provider harness-responses-provider-id
          :label "ChatGPT plan"
          :doc "OpenAI's Responses API paid for by a ChatGPT plan (Sign in with ChatGPT)"
          :models #'harness-responses--models
          :complete #'harness-responses--complete
          :quota #'harness-responses--quota
          :capabilities '(:vision t :thinking t)
          :tiers harness-responses-tiers)
        (setq harness-responses--registered t)
        harness-responses-provider-id)
    (when harness-responses--registered
      (harness-provider-unregister harness-responses-provider-id))
    (setq harness-responses--registered nil)
    nil))

(defun harness-responses-status ()
  "Return a plist saying whether the provider is usable here, and why not.
`:available' is non-nil when it is registered, `:reason' says in a
sentence what is missing when it is not, and `:accounts' counts the
accounts of the ChatGPT plan signed in."
  (let* ((status (harness-responses--status))
         (accounts (plist-get status :accounts))
         (usable (cl-find-if #'harness-json-true-p
                             (mapcar (lambda (a) (plist-get a :plan-usage)) accounts))))
    (list :available (and harness-responses--registered t)
          :signed-in (and (harness-json-true-p (plist-get status :signed-in)) t)
          :accounts (length accounts)
          :base-url harness-responses-base-url
          :reason (cond
                   ((not (harness-method-exists-p 'chatgpt-plan/status))
                    "The chatgpt-plan module is not loaded.")
                   (usable nil)
                   ((plist-get status :signed-in)
                    "A ChatGPT account is signed in, but its grant does not include chatgpt.tokens.use.direct, so the plan cannot pay for inference. Sign in again and allow it.")
                   (t "No ChatGPT account is signed in: run M-x harness-chatgpt-plan-sign-in.")))))

(defun harness-responses--on-accounts-changed (&rest _)
  "Register or remove the provider when the ChatGPT accounts change."
  (harness-responses-refresh))

(defun harness-responses--init ()
  "Register the provider if an account is signed in, and listen for changes."
  (harness-responses-refresh)
  (harness-on 'chatgpt-plan/accounts-changed #'harness-responses--on-accounts-changed))

(harness-define-module 'provider-responses
  :doc "OpenAI Responses API paid for by a ChatGPT plan (Sign in with ChatGPT)."
  :requires '(provider chatgpt-plan)
  :init #'harness-responses--init)

(provide 'harness-provider-responses)
;;; harness-provider-responses.el ends here
