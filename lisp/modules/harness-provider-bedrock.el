;;; harness-provider-bedrock.el --- AWS Bedrock provider (Converse API)  -*- lexical-binding: t; -*-

;;; Commentary:

;; A native-loop provider for models hosted on Amazon Bedrock.  It
;; speaks the Converse API: each model call is one ConverseStream
;; request (POST /model/MODEL-ID/converse-stream) whose binary event
;; stream (application/vnd.amazon.eventstream) is decoded as it arrives
;; and turned into harness events.  The agent runs the tool loop.
;;
;; Models come from ListFoundationModels and ListInferenceProfiles,
;; cached for `harness-bedrock--models-ttl'; a refresh lists them
;; again, and a listing that fails keeps the models listed before.
;; Bedrock reports neither context windows nor prices, so
;; `harness-bedrock--model-defaults' supplies them by model family.  A
;; family's catch-all window is flagged as an estimate, which the window
;; another provider lists for the same model replaces, or else that of
;; the endpoint's closest model by name that the defaults size (see
;; `harness-provider--with-estimate'); a model no default knows gets
;; the endpoint's `:default-context', else the catalogue's estimate.  A model the
;; listing lacks (an application inference profile ARN, say) is still
;; described from the defaults when a session names it.
;;
;; Claude and Nova requests carry prompt cache points.  Claude thinks
;; adaptively or within a token budget, by model, at the session's
;; thinking level; the reasoning it returns with tool calls goes back
;; with them, signed, while the tool loop lasts.  A model that rejects
;; cache points, streamed tool use or tools is asked again without
;; them, and that is remembered.  Throttling is retried with backoff
;; while nothing has been streamed yet.  Nothing here blocks.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'parse-time)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)
(require 'harness-provider)

;;;; Customisation

(defconst harness-bedrock--models-ttl 3600
  "Seconds a listed model catalogue stays cached per endpoint.")

(defconst harness-bedrock--request-timeout 900
  "Maximum seconds a completion request may take, including streaming.")

(defconst harness-bedrock--default-max-tokens 32000
  "Output token limit sent with each request.
It is lowered to the model's own limit when
`harness-bedrock--model-defaults' knows it.  For a model whose limit is
unknown no limit is sent, so the model's default applies, unless the
endpoint sets `:max-tokens'.  nil sends the model's own limit.")

(defconst harness-bedrock--prompt-caching t
  "Whether requests carry prompt cache points.
t places them for the models `harness-bedrock--model-defaults' marks
`:prompt-caching' (Claude, Nova), `always' for every model, nil never.
An endpoint's `:prompt-caching' overrides this.")

(defconst harness-bedrock--thinking-budgets
  '(("low" . 4000) ("medium" . 10000) ("high" . 20000) ("xhigh" . 32000) ("max" . 48000))
  "Thinking token budget per thinking level, for models that take a budget.
Claude 3.7 to 4.5 think within a fixed budget; newer Claude models
think adaptively at an effort level named like the thinking level.")

(defconst harness-bedrock--max-retries 3
  "Times a throttled or unavailable request is retried before it fails.
Only a request that has not streamed anything yet is retried.")

(defcustom harness-bedrock-tiers
  '(:cheap "haiku" :balanced "sonnet" :frontier "opus")
  "Model names or id regexps Bedrock names for the common tiers.
A model of the endpoint's catalogue matching the value is used: the
cheapest `haiku', say, for `cheap'.  The auto-mode judge runs on the
`cheap' one.  A tier nothing matches falls back to the catalogue's
prices."
  :type harness-provider-tiers-type :group 'harness)

(defconst harness-bedrock--model-defaults-type
  `(repeat
    (cons :tag "Model family"
          ;; A new family starts small; its regexp is for the user to write.
          :value ("model-id-regexp" :context-window 128000 :max-output 8192)
          (regexp :tag "Model ids matching" :value "model-id-regexp")
          (plist :tag "Defaults"
                 :options
                 ((:context-window (integer :tag "Context window" :value 128000
                                            :doc "Tokens the model accepts: input plus output."))
                  (:context-window-estimated
                   (const :tag "The window is a guess for the family" t
                          :doc "The same model's window elsewhere, or a close model's, replaces it."))
                  (:max-output (integer :tag "Max output" :value 8192
                                        :doc "Most output tokens per request."))
                  (:input-modalities ,harness-provider-modalities-type)
                  (:thinking (choice :tag "Thinking" :value adaptive
                                     :doc "How the model thinks at the session's thinking level."
                                     (const :tag "Adaptive" :menu-tag "Adaptive: at an effort level" adaptive)
                                     (const :tag "Adaptive only"
                                            :menu-tag "Adaptive only: always thinks, at an effort level"
                                            adaptive-only)
                                     (const :tag "Budget" :menu-tag "Budget: within a token budget (Thinking budgets)"
                                            budget)))
                  (:thinks-by-default (const :tag "Thinks unless told not to (adaptive models)" t))
                  (:thinking-levels ,harness-provider-thinking-levels-type)
                  (:prompt-caching (const :tag "Takes prompt cache points" t))
                  (:pricing ,harness-provider-pricing-type)
                  (:request-fields (plist :tag "Request fields"
                                          :key-type (symbol :tag "Field" :value :field)
                                          :value-type (sexp :tag "Value")
                                          :doc "Merged into each request's additionalModelRequestFields."))))))
  "Customize type of `harness-bedrock--model-defaults'.")

(defconst harness-bedrock--model-defaults
  '(("claude-fable-5" :context-window 1000000 :max-output 128000 :thinking adaptive-only
     :thinking-levels ("low" "medium" "high" "xhigh" "max") :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 10.0 :output 50.0 :cache-read 0.25 :cache-write 12.5))
    ("claude-mythos-5" :context-window 1000000 :max-output 128000 :thinking adaptive-only
     :thinking-levels ("low" "medium" "high" "xhigh" "max") :prompt-caching t
     :input-modalities ("text" "image"))
    ("claude-opus-5" :context-window 1000000 :max-output 128000 :thinking adaptive
     :thinks-by-default t
     :thinking-levels ("low" "medium" "high" "xhigh" "max") :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 4.0 :output 20.0 :cache-read 0.2 :cache-write 5.0))
    ("claude-sonnet-5" :context-window 1000000 :max-output 64000 :thinking adaptive
     :thinks-by-default t
     :thinking-levels ("low" "medium" "high" "xhigh" "max") :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 2.0 :output 10.0 :cache-read 0.2 :cache-write 2.5))
    ("claude-opus-4-[6-9]" :context-window 200000 :max-output 128000 :thinking adaptive
     :thinking-levels ("low" "medium" "high" "max") :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 5.0 :output 25.0 :cache-read 0.5 :cache-write 6.25))
    ("claude-sonnet-4-[6-9]" :context-window 200000 :max-output 64000 :thinking adaptive
     :thinking-levels ("low" "medium" "high" "max") :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 3.0 :output 15.0 :cache-read 0.3 :cache-write 3.75))
    ("claude-opus-4-5" :context-window 200000 :max-output 64000 :thinking budget
     :thinking-levels ("low" "medium" "high") :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 5.0 :output 25.0 :cache-read 0.5 :cache-write 6.25))
    ("claude-opus-4" :context-window 200000 :max-output 32000 :thinking budget
     :thinking-levels ("low" "medium" "high") :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 15.0 :output 75.0 :cache-read 1.5 :cache-write 18.75))
    ("claude-sonnet-4" :context-window 200000 :max-output 64000 :thinking budget
     :thinking-levels ("low" "medium" "high") :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 3.0 :output 15.0 :cache-read 0.3 :cache-write 3.75))
    ("claude-haiku-4" :context-window 200000 :max-output 64000 :thinking budget
     :thinking-levels ("low" "medium" "high") :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 1.0 :output 5.0 :cache-read 0.1 :cache-write 1.25))
    ("claude-3-7-sonnet" :context-window 200000 :max-output 64000 :thinking budget
     :thinking-levels ("low" "medium" "high") :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 3.0 :output 15.0 :cache-read 0.3 :cache-write 3.75))
    ("claude-3-5-haiku" :context-window 200000 :max-output 8192 :prompt-caching t
     :pricing (:input 0.8 :output 4.0 :cache-read 0.08 :cache-write 1.0))
    ("claude-3-5-sonnet-20241022" :context-window 200000 :max-output 8192 :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 3.0 :output 15.0 :cache-read 0.3 :cache-write 3.75))
    ("claude-3-5-sonnet" :context-window 200000 :max-output 8192
     :input-modalities ("text" "image")
     :pricing (:input 3.0 :output 15.0 :cache-read 3.0 :cache-write 3.0))
    ("claude-3-haiku" :context-window 200000 :max-output 4096
     :input-modalities ("text" "image")
     :pricing (:input 0.25 :output 1.25 :cache-read 0.25 :cache-write 0.25))
    ("claude-3-opus" :context-window 200000 :max-output 4096
     :input-modalities ("text" "image")
     :pricing (:input 15.0 :output 75.0 :cache-read 15.0 :cache-write 15.0))
    ("anthropic\\.claude" :context-window 200000 :context-window-estimated t :max-output 32000
     :prompt-caching t :input-modalities ("text" "image"))
    ("nova-premier" :context-window 1000000 :max-output 32000 :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 2.5 :output 12.5 :cache-read 0.625 :cache-write 2.5))
    ("nova-pro" :context-window 300000 :max-output 10000 :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 0.8 :output 3.2 :cache-read 0.2 :cache-write 0.8))
    ("nova-lite" :context-window 300000 :max-output 10000 :prompt-caching t
     :input-modalities ("text" "image")
     :pricing (:input 0.06 :output 0.24 :cache-read 0.015 :cache-write 0.06))
    ("nova-micro" :context-window 128000 :max-output 10000 :prompt-caching t
     :pricing (:input 0.035 :output 0.14 :cache-read 0.00875 :cache-write 0.035))
    ("amazon\\.nova" :context-window 300000 :context-window-estimated t :max-output 10000
     :prompt-caching t)
    ("meta\\.llama4" :context-window 128000 :context-window-estimated t :max-output 8192)
    ("meta\\.llama3" :context-window 128000 :context-window-estimated t :max-output 2048)
    ("mistral\\.\\(mistral-large-2407\\|pixtral\\)" :context-window 128000 :max-output 8192)
    ("mistral\\." :context-window 32000 :context-window-estimated t :max-output 8192)
    ("deepseek\\." :context-window 128000 :context-window-estimated t :max-output 32768)
    ("openai\\.gpt-oss" :context-window 128000 :max-output 32768))
  "What Bedrock does not report about its models, by model family.
Each entry is (REGEXP . PLIST); the first REGEXP matching a model id
\(or the id of the model behind an inference profile) wins.  PLIST
keys:

  :context-window   input plus output tokens the model accepts
  :context-window-estimated non-nil when that window is a guess for the
                    family rather than the model's own; the window
                    another provider lists for the same model replaces
                    it, or else that of the closest model by name
                    sized here (see `harness-provider--with-estimate')
  :max-output       most output tokens per request
  :input-modalities (\"text\") or (\"text\" \"image\")
  :thinking         `adaptive' (effort levels), `adaptive-only' (the
                    model always thinks adaptively) or `budget' (a
                    token budget, see `harness-bedrock--thinking-budgets')
  :thinks-by-default non-nil when an `adaptive' model thinks unless told
                    otherwise
  :thinking-levels  levels the model accepts
  :prompt-caching   non-nil when the model takes cache points
  :pricing          (:input :output :cache-read :cache-write) in USD
                    per million tokens; approximate list prices
  :request-fields   plist merged into additionalModelRequestFields

Models nothing matches get the endpoint's `:default-context', else a
window the catalogue estimates (see `harness-provider--estimate'), and
no price, so their calls are recorded without a cost.")

(defvar harness-bedrock--registered nil
  "Provider ids registered from `harness-bedrock-endpoints'.")

(defvar harness-bedrock--models-cache (make-hash-table :test 'eq)
  "Endpoint id -> (FETCHED-AT . MODELS).")

(defvar harness-bedrock--quirks (make-hash-table :test 'equal)
  "\"ENDPOINT/MODEL\" -> plist of what the model was found to reject.
Keys: `:no-cache' (cache points), `:no-stream' (streamed tool use),
`:no-tools' (tools).")

(defvar harness-bedrock--responses (make-hash-table :test 'equal)
  "Tool use id -> (TIME . CONTENT) of the response that made the call.
CONTENT is the response's Converse content, reasoning included, which
must go back unchanged while the tool loop continues.")

(defconst harness-bedrock--responses-max 200
  "Most responses kept in `harness-bedrock--responses'.")

(defun harness-bedrock--custom-set (symbol value)
  "Set SYMBOL to VALUE and re-register the endpoint providers."
  (set-default symbol value)
  (when (fboundp 'harness-bedrock--register-all)
    (harness-bedrock--register-all)))

(defconst harness-bedrock--endpoint-type
  `(plist
    :tag "Endpoint"
    ;; A new endpoint starts as a second AWS profile.
    :value (:id bedrock-work :label "AWS Bedrock (work)" :profile "work")
    :options
    ((:id (symbol :tag "ID" :value bedrock-work
                  :doc "Names the provider: its models are ID:MODEL-ID.
Lower-case letters, digits, - and _."))
     (:label (string :tag "Label" :value "AWS Bedrock"
                     :doc "Name of the provider in the model picker."))
     (:region (string :tag "Region" :value "us-east-1"
                      :doc "AWS region.  When not set: AWS_REGION, AWS_DEFAULT_REGION, the
profile's region, then us-east-1."))
     (:profile (string :tag "Profile" :value "default"
                       :doc "AWS profile that holds the keys.  When not set: AWS_PROFILE, then
\"default\".  Naming one here wins over the environment."))
     (:auth (choice :tag "Authentication" :value sigv4
                    :doc "Which keys requests are signed with."
                    (const :tag "Automatic" :menu-tag "Automatic: an API key, else AWS keys" nil)
                    (const :tag "AWS keys" :menu-tag "AWS keys (Signature Version 4)" sigv4)
                    (const :tag "API key" :menu-tag "Bedrock API key (bearer token)" bearer)
                    (const :tag "None" :menu-tag "None: the gateway authenticates (see Headers)" none)))
     (:bearer-token-env (string :tag "API key variable" :value "AWS_BEARER_TOKEN_BEDROCK"
                                :doc "Environment variable that holds the API key: a Bedrock API key, or
a gateway's.  AWS_BEARER_TOKEN_BEDROCK when not set, unless an API key
command is."))
     (:bearer-token-command (string :tag "API key command" :value "print-gateway-token"
                                    :doc "Shell command that prints the API key, a gateway's token say, on
its last line.  The key is kept until it expires (a JWT's exp claim)
or for an hour, and asked for again when a request is refused."))
     (:bearer-token-header (string :tag "API key header" :value "x-api-key"
                                   :doc "Header the API key goes in instead of Authorization (which
carries \"Bearer KEY\"), for a gateway that wants it elsewhere: this
header carries the key alone."))
     (:endpoint-url (string :tag "Runtime URL" :value "https://bedrock-runtime.us-east-1.amazonaws.com"
                            :doc "For a gateway, proxy or VPC endpoint: where requests go instead
of https://bedrock-runtime.REGION.amazonaws.com.  A path prefix and a
query are kept.  AWS_ENDPOINT_URL_BEDROCK_RUNTIME when not set."))
     (:control-url (string :tag "Listing URL" :value "https://bedrock.us-east-1.amazonaws.com"
                           :doc "Where models are listed instead of
https://bedrock.REGION.amazonaws.com.  When not set: the runtime URL
when that is a gateway's (its host is not AWS's), else
AWS_ENDPOINT_URL_BEDROCK."))
     (:headers (alist :tag "Headers" :key-type (string :tag "Header") :value-type (string :tag "Value")
                      :doc "Extra request headers.  They replace headers of the same name and
are not signed.  ${NAME} in a value stands for environment variable
NAME, so a gateway's key need not be written here."))
     (:auth-source-host (string :tag "auth-source host" :value "bedrock-runtime.us-east-1.amazonaws.com"
                                :doc "Host the keys are looked up under in auth-source; the runtime URL's
host when not set."))
     (:credentials (function :tag "Credentials function"
                             :doc "A function of no arguments returning, or returning a promise of,
(:access-key-id :secret-access-key :session-token :expiration)
or (:bearer-token TOKEN)."))
     (:signing-service (string :tag "Signing service" :value "bedrock"
                               :doc "Service name of Signature Version 4."))
     (:signing-region (string :tag "Signing region" :value "us-east-1"
                              :doc "Region of Signature Version 4; the endpoint's region when not set."))
     (:sign-for-aws (const :tag "Sign for Bedrock's own URL (a gateway that passes requests on unchanged)" t))
     (:models (repeat :tag "Models"
                      :doc "Models to offer instead of listing the account's: model ids,
inference profile ids or ARNs."
                      (choice :tag "Model" :value "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
                              (string :tag "Model id")
                              ,(harness-provider-model-type
                                '(:base (string :tag "Foundation model" :value "anthropic.claude-sonnet-4-5-20250929-v1:0"
                                                :doc "Id of the model behind an inference profile, to find its defaults."))))))
     (:tiers ,harness-provider-tiers-type)
     (:list-models (const :tag "Never list the account's models (offer only Models)" nil))
     (:inference-profiles (const :tag "Leave inference profiles out of the list" nil))
     (:default-context (integer :tag "Default context" :value 128000
                                :doc "Context window of the models the model defaults do not know."))
     (:max-tokens (integer :tag "Max output" :value 32000
                           :doc "Output token limit of each request; overrides Max tokens."))
     (:prompt-caching (choice :tag "Prompt caching" :value t
                              :doc "Replaces the global Prompt caching for this endpoint."
                              (const :tag "Models that support it" t)
                              (const :tag "Every model" always)
                              (const :tag "Never" nil)))
     (:request-fields (plist :tag "Request fields"
                             :key-type (symbol :tag "Field" :value :field)
                             :value-type (sexp :tag "Value")
                             :doc "Merged into each request's additionalModelRequestFields."))
     (:capabilities (plist :tag "Capabilities" :value (:vision t :thinking t)
                           :doc "What the models can do, when the model list does not say."
                           :options ((:vision (const :tag "Images" t))
                                     (:thinking (const :tag "Thinking" t)))))))
  "Customize type of an entry of `harness-bedrock-endpoints'.")

(defcustom harness-bedrock-endpoints
  '((:id bedrock :label "AWS Bedrock"))
  "AWS Bedrock endpoints, each registered as a provider.
Every entry is a plist with these keys, all optional but `:id':

  :id               provider id symbol (lower-case letters, digits, - and _);
                    model ids are \"ID:MODEL-ID\", for example
                    \"bedrock:us.anthropic.claude-sonnet-4-5-20250929-v1:0\"
  :label            display name
  :region           AWS region; default AWS_REGION, AWS_DEFAULT_REGION, the
                    profile's region, then us-east-1
  :profile          AWS profile; default AWS_PROFILE, then \"default\".
                    Naming one here makes it win over the environment
  :endpoint-url     runtime URL used instead of
                    https://bedrock-runtime.REGION.amazonaws.com, for a
                    gateway, proxy or VPC endpoint; a path prefix and a
                    query are kept.  AWS_ENDPOINT_URL_BEDROCK_RUNTIME is
                    the default
  :control-url      URL for listing models instead of
                    https://bedrock.REGION.amazonaws.com; by default the
                    runtime URL when that is a gateway's (its host is not
                    AWS's), else AWS_ENDPOINT_URL_BEDROCK
  :auth             nil (automatic), `sigv4', `bearer' or `none' (the
                    gateway authenticates some other way, see :headers)
  :bearer-token-env environment variable holding the API key, a Bedrock
                    API key or a gateway's; default AWS_BEARER_TOKEN_BEDROCK
                    unless there is an API key command
  :bearer-token-command shell command printing the API key on its last
                    line, a gateway's token say; the key is kept until it
                    expires (a JWT's exp claim) or for an hour, and asked
                    for again when a request is refused
  :bearer-token-header header the API key goes in instead of Authorization
                    (which carries \"Bearer KEY\"), \"x-api-key\" say; it
                    carries the key alone
  :auth-source-host host looked up in auth-source; default the runtime host
  :credentials      function returning, or returning a promise of, a plist
                    (:access-key-id :secret-access-key :session-token
                    :expiration) or (:bearer-token TOKEN)
  :signing-service  Signature Version 4 service name; default \"bedrock\"
  :signing-region   Signature Version 4 region; default the region
  :sign-for-aws     non-nil to sign for Bedrock's own URL rather than the
                    gateway's, for a gateway that passes requests on to
                    Bedrock unchanged
  :headers          extra request headers, an alist of (NAME . VALUE); they
                    replace headers of the same name and are not signed.
                    ${NAME} in a value stands for environment variable NAME
  :models           model ids or model plists offered instead of listing
                    the account's models, for example
                    (\"us.anthropic.claude-sonnet-4-5-20250929-v1:0\"
                     (:name \"ARN\" :label \"Mine\" :context-window 200000))
  :list-models      nil to never call the listing APIs
  :inference-profiles nil to leave inference profiles out of the listing
  :default-context  context window of models the defaults do not know
  :max-tokens       output token limit, nil for the model's own; by default
                    32000, lowered to the model's limit where known
  :prompt-caching   t (the default) places cache points for the models known
                    to take them, `always' for every model, nil never
  :request-fields   plist merged into additionalModelRequestFields
  :capabilities     static capability plist

A gateway that takes a key of its own in an x-api-key header, the key
read from the environment, and lists models under the same prefix:

  (:id gateway :label \"Gateway\" :auth bearer
   :endpoint-url \"https://gateway.example.com/bedrock\"
   :bearer-token-env \"GATEWAY_API_KEY\" :bearer-token-header \"x-api-key\")

One whose token a command prints, with its models named:

  (:id gateway :label \"Gateway\" :auth bearer
   :endpoint-url \"https://gateway.example.com/bedrock\"
   :bearer-token-command \"gateway-login --print-token\"
   :models (\"us.anthropic.claude-sonnet-4-5-20250929-v1:0\"))

And a proxy or VPC endpoint that takes the AWS keys of a profile:

  (:id proxy :label \"Proxy\" :region \"us-east-1\" :profile \"work\"
   :endpoint-url \"https://bedrock.proxy.example.com/runtime\"
   :models (\"us.anthropic.claude-sonnet-4-5-20250929-v1:0\"))

Keys and tokens never go in this variable: the provider reads them from
the environment, the AWS profile, auth-source, a command or
`:credentials'.  Changing it through customize re-registers the
providers and forgets what was learnt about the endpoints changed."
  :type `(repeat ,harness-bedrock--endpoint-type)
  :set #'harness-bedrock--custom-set
  ;; Loading the file again (a reload) keeps the value; the file
  ;; registers the providers itself at its end.
  :initialize #'custom-initialize-default
  :group 'harness)

;;;; Small helpers

(defun harness-bedrock--env (name)
  "Return environment variable NAME unless it is unset or empty."
  (let ((value (and name (getenv name))))
    (and value (not (string-empty-p value)) value)))

(defun harness-bedrock--nonempty (value)
  "Return VALUE trimmed when it is a non-empty string."
  (and (stringp value) (not (string-empty-p (string-trim value))) (string-trim value)))

(defun harness-bedrock--string (value)
  "Return VALUE as a string; symbols and keywords lose their punctuation."
  (cond ((null value) nil)
        ((stringp value) value)
        ((keywordp value) (substring (symbol-name value) 1))
        ((symbolp value) (symbol-name value))
        (t (format "%s" value))))

(defun harness-bedrock--bytes (string)
  "Return STRING as a unibyte string of its UTF-8 bytes."
  (if (multibyte-string-p string) (encode-coding-string string 'utf-8 t) string))

(defun harness-bedrock--text (bytes)
  "Return BYTES, UTF-8, decoded as text."
  (if (multibyte-string-p bytes) bytes (decode-coding-string bytes 'utf-8 t)))

(defun harness-bedrock--hex (bytes)
  "Return BYTES as lower-case hexadecimal."
  (mapconcat (lambda (b) (format "%02x" b)) bytes ""))

(defun harness-bedrock--sha256 (string &optional binary)
  "Return the SHA-256 of STRING's UTF-8 bytes, in hex or, with BINARY, raw."
  (secure-hash 'sha256 (harness-bedrock--bytes string) nil nil binary))

(defun harness-bedrock--xor (bytes pad)
  "Return BYTES with every byte exclusive-ored with PAD."
  (apply #'unibyte-string (mapcar (lambda (b) (logxor b pad)) bytes)))

(defun harness-bedrock--hmac (key data)
  "Return HMAC-SHA256 of DATA under KEY as raw bytes."
  (let* ((key (harness-bedrock--bytes key))
         (key (if (> (length key) 64) (secure-hash 'sha256 key nil nil t) key))
         (key (concat key (make-string (- 64 (length key)) 0))))
    (secure-hash 'sha256
                 (concat (harness-bedrock--xor key #x5c)
                         (secure-hash 'sha256 (concat (harness-bedrock--xor key #x36)
                                                      (harness-bedrock--bytes data))
                                      nil nil t))
                 nil nil t)))

(defconst harness-bedrock--crc32-table
  (let ((table (make-vector 256 0)))
    (dotimes (i 256)
      (let ((c i))
        (dotimes (_ 8)
          (setq c (if (= 1 (logand c 1)) (logxor #xEDB88320 (ash c -1)) (ash c -1))))
        (aset table i c)))
    table)
  "Lookup table of the CRC-32 (IEEE 802.3) polynomial.")

(defun harness-bedrock--crc32 (bytes &optional start end)
  "Return the CRC-32 of the unibyte string BYTES between START and END."
  (let ((crc #xFFFFFFFF)
        (table harness-bedrock--crc32-table)
        (i (or start 0))
        (end (or end (length bytes))))
    (while (< i end)
      (setq crc (logxor (aref table (logand (logxor crc (aref bytes i)) #xFF)) (ash crc -8))
            i (1+ i)))
    (logxor crc #xFFFFFFFF)))

(defun harness-bedrock--int (bytes pos size &optional signed)
  "Read a big-endian integer of SIZE bytes at POS in BYTES.
With SIGNED, read it as two's complement."
  (let ((value 0))
    (dotimes (i size)
      (setq value (logior (ash value 8) (aref bytes (+ pos i)))))
    (if (and signed (>= value (ash 1 (1- (* 8 size)))))
        (- value (ash 1 (* 8 size)))
      value)))

(defun harness-bedrock--parse-time (value)
  "Return the float time of the ISO 8601 string VALUE, or nil."
  (and (stringp value)
       (ignore-errors (float-time (parse-iso8601-time-string value)))))

;;;; URLs

(defun harness-bedrock--split-url (url)
  "Return (SCHEME HOST PORT PATH QUERY) of URL.
PORT is nil unless URL names one; QUERY is nil without a `?'."
  (unless (string-match "\\`\\([A-Za-z][A-Za-z0-9+.-]*\\)://\\([^/?#]*\\)\\([^?#]*\\)\\(?:\\?\\([^#]*\\)\\)?"
                        url)
    (error "Not a URL: %s" url))
  (let* ((scheme (downcase (match-string 1 url)))
         (authority (match-string 2 url))
         (path (match-string 3 url))
         (query (match-string 4 url))
         (hostport (if (string-match "@\\([^@]*\\)\\'" authority) (match-string 1 authority) authority))
         (host hostport)
         (port nil))
    (when (string-match "\\`\\(\\[[^]]*\\]\\|[^:]*\\):\\([0-9]+\\)\\'" hostport)
      (setq host (match-string 1 hostport)
            port (string-to-number (match-string 2 hostport))))
    (list scheme (downcase host) port path query)))

(defun harness-bedrock--host-header (url)
  "Return the Host header of URL: its host, with a port that is not the default."
  (pcase-let ((`(,scheme ,host ,port . ,_) (harness-bedrock--split-url url)))
    (if (and port (/= port (if (equal scheme "http") 80 443)))
        (format "%s:%d" host port)
      host)))

(defun harness-bedrock--host-of (url)
  "Return the host name of URL, or nil."
  (ignore-errors (nth 1 (harness-bedrock--split-url url))))

(defconst harness-bedrock--aws-host-regexp
  "\\(?:\\`\\|\\.\\)\\(?:amazonaws\\.com\\(?:\\.cn\\)?\\|api\\.aws\\)\\'"
  "Matches the host names of AWS's own endpoints, VPC endpoints included.")

(defun harness-bedrock--aws-url-p (url)
  "Non-nil when URL's host is one of AWS's own, not a gateway's."
  (let ((host (harness-bedrock--host-of url)))
    (and host (string-match-p harness-bedrock--aws-host-regexp host))))

(defun harness-bedrock--url (base path)
  "Return the URL of PATH under BASE.
PATH starts with a slash and may carry a query.  A query BASE carries,
a gateway's say, stays, its parameters before PATH's."
  (let* ((q (string-search "?" base))
         (root (string-remove-suffix "/" (if q (substring base 0 q) base)))
         (p (string-search "?" path))
         (query (string-join (delq nil (list (and q (harness-bedrock--nonempty (substring base (1+ q))))
                                             (and p (harness-bedrock--nonempty (substring path (1+ p))))))
                             "&")))
    (concat root (if p (substring path 0 p) path)
            (if (string-empty-p query) "" (concat "?" query)))))

;;;; Signature Version 4

(defun harness-bedrock--uri-encode (string &optional keep-slash)
  "Percent-encode STRING the way Signature Version 4 does.
Letters, digits and - _ . ~ stay, and / too with KEEP-SLASH; every
other byte of the UTF-8 encoding becomes %XX."
  (mapconcat (lambda (b)
               (if (or (and (>= b ?a) (<= b ?z)) (and (>= b ?A) (<= b ?Z))
                       (and (>= b ?0) (<= b ?9)) (memq b '(?- ?_ ?. ?~))
                       (and keep-slash (eq b ?/)))
                   (char-to-string b)
                 (format "%%%02X" b)))
             (harness-bedrock--bytes string) ""))

(defun harness-bedrock--uri-decode (string)
  "Return the bytes STRING stands for, with %XX escapes decoded, unibyte."
  (let* ((bytes (harness-bedrock--bytes string))
         (n (length bytes))
         (i 0)
         (out nil))
    (while (< i n)
      (let ((c (aref bytes i)))
        (if (and (eq c ?%) (< (+ i 2) n)
                 (string-match-p "\\`[0-9A-Fa-f][0-9A-Fa-f]\\'" (substring bytes (1+ i) (+ i 3))))
            (progn (push (string-to-number (substring bytes (1+ i) (+ i 3)) 16) out)
                   (setq i (+ i 3)))
          (push c out)
          (setq i (1+ i)))))
    (apply #'unibyte-string (nreverse out))))

(defun harness-bedrock--normalize-path (path)
  "Return PATH without dot segments and empty segments, as AWS signs it."
  (if (or (null path) (string-empty-p path))
      "/"
    (let (out)
      (dolist (segment (split-string path "/"))
        (cond ((member segment '("" ".")))
              ((equal segment "..") (pop out))
              (t (push segment out))))
      (concat (if (string-prefix-p "/" path) "/" "")
              (string-join (nreverse out) "/")
              (if (and out (string-suffix-p "/" path)) "/" "")))))

(defun harness-bedrock--canonical-uri (path)
  "Return the canonical URI of PATH as it is sent.
The path is encoded once more, so the %3A of a model id signs as %253A,
which is what AWS expects of every service but S3."
  (harness-bedrock--uri-encode (harness-bedrock--normalize-path path) t))

(defun harness-bedrock--canonical-query (query)
  "Return the canonical form of QUERY, the part of a URL after `?'."
  (if (or (null query) (string-empty-p query))
      ""
    (let ((pairs (mapcar (lambda (param)
                           (let* ((i (string-search "=" param))
                                  (key (if i (substring param 0 i) param))
                                  (value (if i (substring param (1+ i)) "")))
                             (cons (harness-bedrock--uri-encode (harness-bedrock--uri-decode key))
                                   (harness-bedrock--uri-encode (harness-bedrock--uri-decode value)))))
                         (split-string query "&" t))))
      (mapconcat (lambda (p) (concat (car p) "=" (cdr p)))
                 (sort pairs (lambda (a b)
                               (or (string< (car a) (car b))
                                   (and (string= (car a) (car b)) (string< (cdr a) (cdr b))))))
                 "&"))))

(defun harness-bedrock--canonical-headers (headers)
  "Return (CANONICAL-HEADERS . SIGNED-HEADERS) for the alist HEADERS.
Names are lower-cased, values trimmed with inner whitespace collapsed,
and repeated headers joined with commas in the order given."
  (let (table)
    (dolist (h headers)
      (let* ((name (downcase (string-trim (car h))))
             (value (string-trim (replace-regexp-in-string "[ \t\r\n]+" " " (or (cdr h) ""))))
             (cell (assoc name table)))
        (if cell
            (setcdr cell (concat (cdr cell) "," value))
          (push (cons name value) table))))
    (setq table (sort table (lambda (a b) (string< (car a) (car b)))))
    (cons (mapconcat (lambda (c) (concat (car c) ":" (cdr c) "\n")) table "")
          (mapconcat #'car table ";"))))

(defun harness-bedrock--signing-key (secret date region service)
  "Derive the Signature Version 4 key of SECRET for DATE, REGION and SERVICE."
  (harness-bedrock--hmac
   (harness-bedrock--hmac
    (harness-bedrock--hmac (harness-bedrock--hmac (concat "AWS4" secret) date) region)
    service)
   "aws4_request"))

(cl-defun harness-bedrock-sigv4 (&key (method "GET") url headers body access-key-id
                                      secret-access-key session-token region service
                                      time sign-body)
  "Sign a request with AWS Signature Version 4.
METHOD and URL (path as sent, query included) describe the request,
HEADERS (an alist) are its headers, all of them signed, and BODY its
payload.  ACCESS-KEY-ID, SECRET-ACCESS-KEY and SESSION-TOKEN are the
credentials, REGION and SERVICE the scope, TIME the signing time
\(default now).  SIGN-BODY adds an X-Amz-Content-Sha256 header.

Return a plist: `:headers', the headers to add (Host unless HEADERS
has one, X-Amz-Date, X-Amz-Security-Token with a session token,
X-Amz-Content-Sha256 with SIGN-BODY, then Authorization), and
`:canonical-request', `:string-to-sign' and `:signature'."
  (pcase-let* ((`(,_ ,_ ,_ ,path ,query) (harness-bedrock--split-url url))
               (amz-date (format-time-string "%Y%m%dT%H%M%SZ" (or time (current-time)) t))
               (date (substring amz-date 0 8))
               (payload-hash (harness-bedrock--sha256 (or body "")))
               (added nil))
    (unless (cl-find "host" headers :key (lambda (h) (downcase (car h))) :test #'equal)
      (push (cons "Host" (harness-bedrock--host-header url)) added))
    (push (cons "X-Amz-Date" amz-date) added)
    (when session-token (push (cons "X-Amz-Security-Token" session-token) added))
    (when sign-body (push (cons "X-Amz-Content-Sha256" payload-hash) added))
    (setq added (nreverse added))
    (pcase-let* ((`(,canonical-headers . ,signed) (harness-bedrock--canonical-headers (append headers added)))
                 (scope (format "%s/%s/%s/aws4_request" date region service))
                 (canonical (concat (upcase method) "\n"
                                    (harness-bedrock--canonical-uri path) "\n"
                                    (harness-bedrock--canonical-query query) "\n"
                                    canonical-headers "\n"
                                    signed "\n"
                                    payload-hash))
                 (to-sign (concat "AWS4-HMAC-SHA256\n" amz-date "\n" scope "\n"
                                  (harness-bedrock--sha256 canonical)))
                 (signature (harness-bedrock--hex
                             (harness-bedrock--hmac
                              (harness-bedrock--signing-key secret-access-key date region service)
                              to-sign))))
      (list :headers (append added
                             (list (cons "Authorization"
                                         (format "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s"
                                                 access-key-id scope signed signature))))
            :canonical-request canonical
            :string-to-sign to-sign
            :signature signature))))

;;;; Event streams

(define-error 'harness-bedrock-eventstream-error "Corrupt AWS event stream" 'harness-error)

(defconst harness-bedrock--max-message (* 24 1024 1024)
  "Largest event stream message accepted, in bytes.")

(defun harness-bedrock--eventstream-headers (bytes start end)
  "Decode the event stream header block of BYTES from START to END.
Return an alist of (NAME . VALUE): strings for strings, unibyte strings
for byte arrays and UUIDs, integers for numbers and timestamps (in
milliseconds), and t or `:false' for booleans."
  (let ((pos start) out)
    (while (< pos end)
      (let* ((nlen (aref bytes pos))
             (name (decode-coding-string (substring bytes (1+ pos) (+ pos 1 nlen)) 'utf-8 t))
             (type (aref bytes (+ pos 1 nlen)))
             (p (+ pos 2 nlen))
             (value nil))
        (pcase type
          (0 (setq value t))
          (1 (setq value :false))
          (2 (setq value (harness-bedrock--int bytes p 1 t) p (+ p 1)))
          (3 (setq value (harness-bedrock--int bytes p 2 t) p (+ p 2)))
          (4 (setq value (harness-bedrock--int bytes p 4 t) p (+ p 4)))
          ((or 5 8) (setq value (harness-bedrock--int bytes p 8 t) p (+ p 8)))
          ((or 6 7)
           (let ((len (harness-bedrock--int bytes p 2)))
             (setq value (substring bytes (+ p 2) (+ p 2 len)) p (+ p 2 len))
             (when (= type 7) (setq value (decode-coding-string value 'utf-8 t)))))
          (9 (setq value (substring bytes p (+ p 16)) p (+ p 16)))
          (_ (signal 'harness-bedrock-eventstream-error
                     (list (format "unknown header value type %d" type)))))
        (when (> p end)
          (signal 'harness-bedrock-eventstream-error '("header runs past the header block")))
        (push (cons name value) out)
        (setq pos p)))
    (nreverse out)))

(defun harness-bedrock-eventstream-decode (bytes)
  "Decode BYTES, one complete AWS event stream message.
Return (:headers ALIST :payload BYTES).  Signal
`harness-bedrock-eventstream-error' when a checksum or a length is
wrong."
  (let ((bytes (harness-bedrock--bytes bytes)))
    (when (< (length bytes) 16)
      (signal 'harness-bedrock-eventstream-error '("Message shorter than its prelude")))
    (let ((total (harness-bedrock--int bytes 0 4))
          (hlen (harness-bedrock--int bytes 4 4)))
      (unless (= (harness-bedrock--int bytes 8 4) (harness-bedrock--crc32 bytes 0 8))
        (signal 'harness-bedrock-eventstream-error '("Prelude checksum mismatch")))
      (unless (and (= total (length bytes)) (<= (+ hlen 16) total))
        (signal 'harness-bedrock-eventstream-error '("Message length mismatch")))
      (unless (= (harness-bedrock--int bytes (- total 4) 4) (harness-bedrock--crc32 bytes 0 (- total 4)))
        (signal 'harness-bedrock-eventstream-error '("Message checksum mismatch")))
      (list :headers (condition-case nil
                         (harness-bedrock--eventstream-headers bytes 12 (+ 12 hlen))
                       (args-out-of-range
                        (signal 'harness-bedrock-eventstream-error '("Malformed header block"))))
            :payload (substring bytes (+ 12 hlen) (- total 4))))))

(defun harness-bedrock-eventstream-decoder (on-message)
  "Return a function that takes the bytes of an AWS event stream as they come.
ON-MESSAGE is called with each complete message, decoded by
`harness-bedrock-eventstream-decode'.  Messages may be split across
chunks anywhere.  The function signals
`harness-bedrock-eventstream-error' on corrupt data."
  (let ((buffer ""))
    (lambda (chunk)
      (setq buffer (concat buffer (harness-bedrock--bytes chunk)))
      (let ((pos 0) (n (length buffer)) (more t))
        (while (and more (>= (- n pos) 12))
          (let ((total (harness-bedrock--int buffer pos 4)))
            (unless (= (harness-bedrock--int buffer (+ pos 8) 4) (harness-bedrock--crc32 buffer pos (+ pos 8)))
              (signal 'harness-bedrock-eventstream-error '("Prelude checksum mismatch")))
            (when (or (< total 16) (> total harness-bedrock--max-message))
              (signal 'harness-bedrock-eventstream-error (list (format "bad message length %d" total))))
            (if (> (+ pos total) n)
                (setq more nil)
              (let ((message (substring buffer pos (+ pos total))))
                (setq pos (+ pos total))
                (funcall on-message (harness-bedrock-eventstream-decode message))))))
        (setq buffer (substring buffer pos))))))

;;;; Endpoints and regions

(defun harness-bedrock-endpoint (id)
  "Return the endpoint plist for provider ID, or nil."
  (cl-find id harness-bedrock-endpoints :key (lambda (e) (plist-get e :id))))

(defun harness-bedrock--config-file ()
  "Return the path of the AWS shared config file."
  (expand-file-name (or (harness-bedrock--env "AWS_CONFIG_FILE") "~/.aws/config")))

(defun harness-bedrock--shared-file ()
  "Return the path of the AWS shared credentials file."
  (expand-file-name (or (harness-bedrock--env "AWS_SHARED_CREDENTIALS_FILE") "~/.aws/credentials")))

(defun harness-bedrock--ini (file)
  "Parse FILE, an AWS shared config or credentials file.
Return an alist of (SECTION . ((KEY . VALUE) ...)) with lower-case
keys, or nil when FILE is unreadable.  Indented lines (settings nested
under a key) and comments are skipped."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file))
      (let (sections current)
        (goto-char (point-min))
        (while (not (eobp))
          (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
            (cond
             ((string-match "\\`[ \t]*\\[[ \t]*\\([^]]*?\\)[ \t]*\\]" line)
              (setq current (list (match-string 1 line)))
              (push current sections))
             ((and current (string-match "\\`\\([^ \t#;][^=]*?\\)[ \t]*=[ \t]*\\(.*?\\)[ \t\r]*\\'" line))
              (setcdr current (append (cdr current)
                                      (list (cons (downcase (match-string 1 line)) (match-string 2 line))))))))
          (forward-line 1))
        (nreverse sections)))))

(defun harness-bedrock--profile-name (endpoint)
  "Return the name of the AWS profile ENDPOINT uses."
  (or (harness-bedrock--nonempty (plist-get endpoint :profile))
      (harness-bedrock--env "AWS_PROFILE")
      (harness-bedrock--env "AWS_DEFAULT_PROFILE")
      "default"))

(defun harness-bedrock--profile (name)
  "Return the settings of AWS profile NAME as an alist, or nil.
Settings of the shared credentials file come before those of the
config file, so they win."
  (let* ((config (harness-bedrock--ini (harness-bedrock--config-file)))
         (shared (harness-bedrock--ini (harness-bedrock--shared-file)))
         (from-config (or (cdr (assoc (concat "profile " name) config))
                          (and (equal name "default") (cdr (assoc "default" config)))))
         (from-shared (cdr (assoc name shared))))
    (append from-shared from-config)))

(defun harness-bedrock--profile-value (endpoint key)
  "Return setting KEY of ENDPOINT's AWS profile, or nil."
  (harness-bedrock--nonempty
   (cdr (assoc key (harness-bedrock--profile (harness-bedrock--profile-name endpoint))))))

(defun harness-bedrock--region (endpoint)
  "Return the AWS region of ENDPOINT."
  (or (harness-bedrock--nonempty (plist-get endpoint :region))
      (harness-bedrock--env "AWS_REGION")
      (harness-bedrock--env "AWS_DEFAULT_REGION")
      (ignore-errors (harness-bedrock--profile-value endpoint "region"))
      "us-east-1"))

(defun harness-bedrock--dns-suffix (region)
  "Return the domain of AWS endpoints in REGION."
  (if (string-prefix-p "cn-" region) "amazonaws.com.cn" "amazonaws.com"))

(defun harness-bedrock--runtime-url (endpoint &optional region)
  "Return the runtime URL of ENDPOINT, without a trailing slash.
REGION, when given, saves looking it up."
  (string-remove-suffix
   "/" (or (harness-bedrock--nonempty (plist-get endpoint :endpoint-url))
           (harness-bedrock--env "AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
           (let ((region (or region (harness-bedrock--region endpoint))))
             (format "https://bedrock-runtime.%s.%s" region (harness-bedrock--dns-suffix region))))))

(defun harness-bedrock--control-url (endpoint &optional region)
  "Return the URL ENDPOINT lists models at, without a trailing slash.
That is its `:control-url'; else its `:endpoint-url' when that is a
gateway's (not an AWS host), so a gateway's keys and headers go to the
gateway alone; else AWS_ENDPOINT_URL_BEDROCK; else
AWS_ENDPOINT_URL_BEDROCK_RUNTIME, when the runtime URL comes from it
and is a gateway's; else Bedrock's regional URL.  REGION, when given,
saves looking it up."
  (let ((own (harness-bedrock--nonempty (plist-get endpoint :endpoint-url)))
        (env-runtime (harness-bedrock--env "AWS_ENDPOINT_URL_BEDROCK_RUNTIME")))
    (string-remove-suffix
     "/" (or (harness-bedrock--nonempty (plist-get endpoint :control-url))
             (and own (not (harness-bedrock--aws-url-p own)) own)
             (harness-bedrock--env "AWS_ENDPOINT_URL_BEDROCK")
             (and (not own) env-runtime (not (harness-bedrock--aws-url-p env-runtime)) env-runtime)
             (let ((region (or region (harness-bedrock--region endpoint))))
               (format "https://bedrock.%s.%s" region (harness-bedrock--dns-suffix region)))))))

(defun harness-bedrock--aws-url (endpoint plane region)
  "Return Bedrock's own URL of PLANE for ENDPOINT in REGION.
PLANE is `runtime' or `control'; the region is the endpoint's signing
region when it names one."
  (let ((region (or (harness-bedrock--nonempty (plist-get endpoint :signing-region)) region)))
    (format "https://%s.%s.%s" (if (eq plane 'control) "bedrock" "bedrock-runtime")
            region (harness-bedrock--dns-suffix region))))

(defun harness-bedrock--sign-for-aws-p (endpoint)
  "Non-nil when ENDPOINT's requests are signed for Bedrock's own URL."
  (not (memq (plist-get endpoint :sign-for-aws) '(nil :false))))

(defun harness-bedrock--signing-url (endpoint url path plane region)
  "Return the URL a request to URL, for PATH of PLANE, is signed for.
That is URL, unless ENDPOINT is signed for AWS (`:sign-for-aws'), for
a gateway that passes requests on to Bedrock unchanged: then PATH under
Bedrock's own URL of PLANE (see `harness-bedrock--aws-url') in REGION."
  (if (harness-bedrock--sign-for-aws-p endpoint)
      (harness-bedrock--url (harness-bedrock--aws-url endpoint plane region) path)
    url))

;;;; Credentials
;;
;; Requests are authenticated by the first of these that yields
;; anything:
;;
;; 1. a Bedrock API key in AWS_BEARER_TOKEN_BEDROCK (or the endpoint's
;;    `:bearer-token-env'), sent as a bearer token;
;; 2. the API key the endpoint's `:bearer-token-command' prints, a
;;    gateway's token say (with such a command, AWS_BEARER_TOKEN_BEDROCK
;;    is only read when `:bearer-token-env' names it);
;; 3. the endpoint's `:credentials' function;
;; 4. AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN,
;;    unless the endpoint names a `:profile';
;; 5. the keys of the AWS profile, in the shared credentials file or
;;    the config file;
;; 6. auth-source, for the runtime host: user "apikey" (or "bearer")
;;    holds an API key, any other user is an access key id whose
;;    password is the secret key;
;; 7. the profile's `credential_process';
;; 8. `aws configure export-credentials' for the profile (see
;;    `harness-bedrock--aws-program').
;;
;; Commands run asynchronously, at most one at a time per endpoint,
;; and what they print is kept until it expires.  An API key goes in
;; the endpoint's `:bearer-token-header' (Authorization by default);
;; the other keys sign with Signature Version 4, for the URL a request
;; goes to or, with `:sign-for-aws', for Bedrock's own.  The
;; endpoint's `:auth' restricts the choice to `bearer' or `sigv4', or
;; turns authentication off (`none').

(declare-function auth-source-search "auth-source")

(define-error 'harness-bedrock-no-credentials "No AWS credentials" 'harness-error)

(defun harness-bedrock--api-key-variable (endpoint)
  "Return the environment variable ENDPOINT's API key is read from, or nil.
That is its `:bearer-token-env', else AWS_BEARER_TOKEN_BEDROCK unless
an API key command (`:bearer-token-command') takes its place: an AWS
key meant for Bedrock itself is not sent to a gateway that has a key
of its own."
  (or (harness-bedrock--nonempty (plist-get endpoint :bearer-token-env))
      (unless (harness-bedrock--nonempty (plist-get endpoint :bearer-token-command))
        "AWS_BEARER_TOKEN_BEDROCK")))

(defun harness-bedrock--bearer-env (endpoint)
  "Return (VARIABLE . TOKEN) when ENDPOINT's API key variable is set."
  (let* ((var (harness-bedrock--api-key-variable endpoint))
         (token (harness-bedrock--env var)))
    (and token (cons var token))))

(defun harness-bedrock--api-key-header (endpoint token)
  "Return the header (NAME . VALUE) that carries the API key TOKEN for ENDPOINT.
The header is its `:bearer-token-header', Authorization by default,
which carries \"Bearer TOKEN\"; any other header carries TOKEN alone."
  (let ((name (or (harness-bedrock--nonempty (plist-get endpoint :bearer-token-header)) "Authorization")))
    (cons name (if (string-equal-ignore-case name "authorization") (concat "Bearer " token) token))))

(defun harness-bedrock--env-keys ()
  "Return keys from the AWS_* environment variables, or nil."
  (let ((id (harness-bedrock--env "AWS_ACCESS_KEY_ID"))
        (secret (harness-bedrock--env "AWS_SECRET_ACCESS_KEY")))
    (when (and id secret)
      (list :type 'sigv4 :access-key-id id :secret-access-key secret
            :session-token (harness-bedrock--env "AWS_SESSION_TOKEN") :source "the environment"))))

(defun harness-bedrock--profile-keys (endpoint)
  "Return the keys of ENDPOINT's AWS profile, or nil."
  (let* ((name (harness-bedrock--profile-name endpoint))
         (profile (harness-bedrock--profile name))
         (id (harness-bedrock--nonempty (cdr (assoc "aws_access_key_id" profile))))
         (secret (harness-bedrock--nonempty (cdr (assoc "aws_secret_access_key" profile)))))
    (when (and id secret)
      (list :type 'sigv4 :access-key-id id :secret-access-key secret
            :session-token (or (harness-bedrock--nonempty (cdr (assoc "aws_session_token" profile)))
                               (harness-bedrock--nonempty (cdr (assoc "aws_security_token" profile))))
            :source (format "profile %s" name)))))

(defun harness-bedrock--auth-source-host (endpoint)
  "Return the host ENDPOINT's keys are looked up under in auth-source."
  (or (harness-bedrock--nonempty (plist-get endpoint :auth-source-host))
      (harness-bedrock--host-of (harness-bedrock--runtime-url endpoint))))

(defun harness-bedrock--auth-source (endpoint mode)
  "Return keys for ENDPOINT from auth-source, or nil.
MODE `bearer' or `sigv4' accepts only that kind of entry."
  (let ((host (harness-bedrock--auth-source-host endpoint)))
    (when host
      (require 'auth-source)
      (condition-case err
          (cl-loop for found in (auth-source-search :host host :max 10)
                   for user = (plist-get found :user)
                   for secret = (let ((s (plist-get found :secret))) (if (functionp s) (funcall s) s))
                   for bearer = (or (null user) (member user '("apikey" "bearer" "token")))
                   when (and (stringp secret) (not (string-empty-p secret))
                             (if bearer (not (eq mode 'sigv4)) (not (eq mode 'bearer))))
                   return (if bearer
                              (list :type 'bearer :token secret :source (format "auth-source (%s)" host))
                            (list :type 'sigv4 :access-key-id user :secret-access-key secret
                                  :source (format "auth-source (%s)" host))))
        (error (harness-log 'warn "bedrock %s: auth-source lookup failed: %s"
                            (plist-get endpoint :id) (car-safe err))
               nil)))))

(defun harness-bedrock--normalise-keys (value source)
  "Turn VALUE, what an endpoint's `:credentials' function returned, into keys.
SOURCE says where they came from."
  (cond
   ((null value) nil)
   ((plist-get value :type) value)
   ((plist-get value :bearer-token)
    (list :type 'bearer :token (plist-get value :bearer-token) :source source))
   ((and (plist-get value :access-key-id) (plist-get value :secret-access-key))
    (list :type 'sigv4 :access-key-id (plist-get value :access-key-id)
          :secret-access-key (plist-get value :secret-access-key)
          :session-token (plist-get value :session-token)
          :expires (let ((e (plist-get value :expiration)))
                     (if (numberp e) (float e) (harness-bedrock--parse-time e)))
          :source source))
   (t (error "%s returned no usable keys" source))))

(defconst harness-bedrock--aws-program (executable-find "aws")
  "AWS command line program, the last place keys come from.
When nothing else yields keys, `aws configure export-credentials'
runs (asynchronously) for the endpoint's profile; that covers SSO
logins, assumed roles and instance roles.  nil never runs it.")

(defconst harness-bedrock--credential-timeout 60
  "Seconds a command that prints keys may run.")

(defvar harness-bedrock--kept-keys (make-hash-table :test 'equal)
  "Keys a command printed, kept until `:expires'.
AWS keys are under \"ENDPOINT/PROFILE\", an API key under
\"ENDPOINT/api-key/HASH\" (see `harness-bedrock--api-key-cache-key').")

(defvar harness-bedrock--command-pending (make-hash-table :test 'equal)
  "\"CACHE-KEY/SOURCE\" -> promise of a command still running.")

(defconst harness-bedrock--api-key-ttl 3600
  "Seconds an API key that `:bearer-token-command' printed is kept.
A key that is a JWT naming its expiry is kept until then instead, and
a key a request is refused with is dropped at once.")

(defun harness-bedrock--keys-cache-key (endpoint)
  "Return the key ENDPOINT's command keys are kept under."
  (format "%s/%s" (plist-get endpoint :id) (harness-bedrock--profile-name endpoint)))

(defun harness-bedrock--api-key-cache-key (endpoint)
  "Return the key the API key ENDPOINT's command printed is kept under.
It names the command, so a key printed by a command since replaced is
never used."
  (format "%s/api-key/%s" (plist-get endpoint :id)
          (secure-hash 'sha1 (or (plist-get endpoint :bearer-token-command) ""))))

(defun harness-bedrock--fresh-p (keys)
  "Non-nil when KEYS do not expire within five minutes."
  (let ((expires (plist-get keys :expires)))
    (or (null expires) (> (- expires (float-time)) 300))))

(defun harness-bedrock--process-keys (stdout source)
  "Return the AWS keys in STDOUT, JSON in the credential_process format, or nil.
SOURCE names the command that printed it."
  (let ((json (ignore-errors (harness-json-parse stdout))))
    (when (and (listp json) (plist-get json :AccessKeyId) (plist-get json :SecretAccessKey))
      (list :type 'sigv4
            :access-key-id (plist-get json :AccessKeyId)
            :secret-access-key (plist-get json :SecretAccessKey)
            :session-token (plist-get json :SessionToken)
            :expires (or (harness-bedrock--parse-time (plist-get json :Expiration))
                         (+ (float-time) 3600))
            :source source :command t))))

(defun harness-bedrock--jwt-expiry (token)
  "Return the expiry of TOKEN as a float time when it is a JWT naming one.
That is the `exp' claim of its payload; any other TOKEN gives nil."
  (let ((parts (split-string token "\\.")))
    (when (= (length parts) 3)
      (let* ((json (ignore-errors
                     (harness-json-parse
                      (decode-coding-string (base64-decode-string (nth 1 parts) t) 'utf-8))))
             (exp (and (listp json) (plist-get json :exp))))
        (and (numberp exp) (float exp))))))

(defun harness-bedrock--printed-api-key (stdout source)
  "Return the API key in STDOUT, what an API key command printed, or nil.
The key is the last line that is not blank, without a leading
\"Bearer \".  It is kept until it expires when it is a JWT, else for
`harness-bedrock--api-key-ttl'.  SOURCE names the command."
  (let* ((line (car (last (split-string stdout "[\r\n]+" t "[ \t]+"))))
         (token (and line (replace-regexp-in-string "\\`[Bb]earer[ \t]+" "" line))))
    (when (and token (not (string-empty-p token)))
      (list :type 'bearer :token token
            :expires (or (harness-bedrock--jwt-expiry token) (+ (float-time) harness-bedrock--api-key-ttl))
            :source source :command t))))

(defun harness-bedrock--command-keys (endpoint source command &optional parse cache-key)
  "Return a promise of the keys COMMAND (a list) prints for ENDPOINT.
PARSE, a function of the output and SOURCE, returns the keys printed,
or nil when there are none; by default it reads the credential_process
format (`harness-bedrock--process-keys').  SOURCE names the command in
messages.  At most one such command runs per CACHE-KEY (by default the
endpoint's profile, see `harness-bedrock--keys-cache-key') and source
at a time, and the keys it prints are kept under CACHE-KEY until they
expire.  The output never reaches a message or the log."
  (let* ((key (or cache-key (harness-bedrock--keys-cache-key endpoint)))
         (pending-key (concat key "/" source))
         (pending (gethash pending-key harness-bedrock--command-pending)))
    (or (and pending (not (harness-promise-settled-p pending)) pending)
        (let ((promise
               (harness-then
                (harness-run-command command :cwd (expand-file-name "~/")
                                     :timeout harness-bedrock--credential-timeout
                                     :name "harness-bedrock-keys")
                (lambda (result)
                  (remhash pending-key harness-bedrock--command-pending)
                  (let* ((exit (plist-get result :exit))
                         (keys (and (eq exit 0)
                                    (funcall (or parse #'harness-bedrock--process-keys)
                                             (or (plist-get result :stdout) "") source))))
                    (cond
                     ((not (eq exit 0))
                      (harness-rejected
                       (list 'error (format "%s %s: %s" source
                                            (if (eq exit 'timeout) "timed out" (format "failed (exit %s)" exit))
                                            (harness-truncate-end
                                             (string-trim (or (plist-get result :stderr) "")) 300)))))
                     ((null keys)
                      (harness-rejected (list 'error (format "%s printed no keys" source))))
                     (t
                      (puthash key keys harness-bedrock--kept-keys)
                      keys))))
                (lambda (err)
                  (remhash pending-key harness-bedrock--command-pending)
                  (harness-rejected err)))))
          (puthash pending-key promise harness-bedrock--command-pending)
          promise))))

(defun harness-bedrock--api-key-from-command (endpoint)
  "Return ENDPOINT's kept API key, or a promise of what its command prints.
The command is the endpoint's `:bearer-token-command', run by the shell."
  (let* ((key (harness-bedrock--api-key-cache-key endpoint))
         (kept (gethash key harness-bedrock--kept-keys)))
    (if (and kept (harness-bedrock--fresh-p kept))
        kept
      (harness-bedrock--command-keys
       endpoint "the API key command"
       (list shell-file-name shell-command-switch (plist-get endpoint :bearer-token-command))
       #'harness-bedrock--printed-api-key key))))

(defun harness-bedrock--configured-p (endpoint)
  "Non-nil when anything says ENDPOINT should have AWS keys.
Without that, listing models in the background stays quiet."
  (or (plist-get endpoint :profile)
      (plist-get endpoint :credentials)
      (harness-bedrock--nonempty (plist-get endpoint :bearer-token-command))
      (harness-bedrock--nonempty (plist-get endpoint :bearer-token-env))
      (memq (plist-get endpoint :auth) '(sigv4 bearer none))
      (harness-bedrock--env "AWS_PROFILE")
      (harness-bedrock--env "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")
      (harness-bedrock--env "AWS_CONTAINER_CREDENTIALS_FULL_URI")
      (harness-bedrock--env "AWS_WEB_IDENTITY_TOKEN_FILE")
      (file-exists-p (harness-bedrock--config-file))
      (file-exists-p (harness-bedrock--shared-file))))

(defun harness-bedrock--key-sources (endpoint quiet)
  "Return ENDPOINT's sources of keys, in order, as functions.
Each returns keys, nil, or a promise of keys.  With QUIET, the AWS
command line runs only when ENDPOINT looks configured."
  (let* ((mode (plist-get endpoint :auth))
         (sigv4 (memq mode '(nil sigv4)))
         (bearer (memq mode '(nil bearer)))
         (cache-key (harness-bedrock--keys-cache-key endpoint))
         (profile (harness-bedrock--profile-name endpoint)))
    (delq nil
          (list
           (and bearer
                (lambda ()
                  (when-let* ((found (harness-bedrock--bearer-env endpoint)))
                    (list :type 'bearer :token (cdr found) :source (car found)))))
           (and bearer (harness-bedrock--nonempty (plist-get endpoint :bearer-token-command))
                (lambda () (harness-bedrock--api-key-from-command endpoint)))
           (when-let* ((fn (plist-get endpoint :credentials)))
             (lambda ()
               (let ((value (funcall fn)))
                 (if (harness-promise-p value)
                     (harness-then value (lambda (v) (harness-bedrock--normalise-keys v "the :credentials function")))
                   (harness-bedrock--normalise-keys value "the :credentials function")))))
           (and sigv4 (not (plist-get endpoint :profile)) #'harness-bedrock--env-keys)
           (and sigv4
                (lambda ()
                  (let ((kept (gethash cache-key harness-bedrock--kept-keys)))
                    (and kept (harness-bedrock--fresh-p kept) kept))))
           (and sigv4 (lambda () (harness-bedrock--profile-keys endpoint)))
           (lambda () (harness-bedrock--auth-source endpoint mode))
           (and sigv4
                (lambda ()
                  (when-let* ((command (harness-bedrock--nonempty
                                        (cdr (assoc "credential_process" (harness-bedrock--profile profile))))))
                    (harness-bedrock--command-keys
                     endpoint (format "credential_process of profile %s" profile)
                     (list shell-file-name shell-command-switch command)))))
           (and sigv4 harness-bedrock--aws-program
                (or (not quiet) (harness-bedrock--configured-p endpoint))
                (lambda ()
                  (harness-bedrock--command-keys
                   endpoint "aws configure export-credentials"
                   (list harness-bedrock--aws-program "configure" "export-credentials"
                         "--profile" profile "--format" "process"))))))))

(defun harness-bedrock--try-sources (sources errors)
  "Return a promise of the first keys SOURCES yield.
ERRORS collects why sources failed, newest first."
  (if (null sources)
      (harness-rejected (list 'harness-bedrock-no-credentials (reverse errors)))
    (let ((value (condition-case err
                     (funcall (car sources))
                   (error (push (harness-error-message err) errors) nil))))
      (cond
       ((harness-promise-p value)
        (harness-then value
                      (lambda (v) (or v (harness-bedrock--try-sources (cdr sources) errors)))
                      (lambda (e) (harness-bedrock--try-sources
                                   (cdr sources) (cons (harness-bedrock--describe-error e) errors)))))
       (value (harness-resolved value))
       (t (harness-bedrock--try-sources (cdr sources) errors))))))

(defun harness-bedrock--no-keys-message (endpoint errors)
  "Explain that ENDPOINT has no keys; ERRORS are what the sources said.
The ways named are those the endpoint's `:auth' allows: its API key
variable, AWS keys, and auth-source."
  (let* ((mode (plist-get endpoint :auth))
         (variable (harness-bedrock--api-key-variable endpoint))
         (settable (append (and (memq mode '(nil bearer)) variable (list variable))
                           (and (memq mode '(nil sigv4))
                                (list "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
                                      (format "AWS_PROFILE (now profile %s)"
                                              (harness-bedrock--profile-name endpoint))))))
         (ways (append (and settable (list (concat "set " (string-join settable ", or "))))
                       (list (format "add an auth-source entry for %s%s"
                                     (or (harness-bedrock--auth-source-host endpoint) "the runtime host")
                                     (if (eq mode 'bearer) " (user apikey)" ""))))))
    (format "no %s for %s: %s%s"
            (if (eq mode 'bearer) "API key" "AWS credentials") (plist-get endpoint :id)
            (string-join ways ", or ")
            (if errors (concat " (" (string-join errors "; ") ")") ""))))

(defun harness-bedrock--auth (endpoint &optional quiet)
  "Return a promise of the keys ENDPOINT's requests are authenticated with.
They are (:type bearer :token TOKEN), (:type sigv4 :access-key-id ID
:secret-access-key SECRET :session-token TOKEN) or (:type none).  With
QUIET (listing models in the background), an endpoint nothing
configures resolves to nil instead of rejecting."
  (if (eq (plist-get endpoint :auth) 'none)
      (harness-resolved (list :type 'none :source "none"))
    (harness-then
     (harness-bedrock--try-sources (harness-bedrock--key-sources endpoint quiet) nil)
     #'identity
     (lambda (err)
       (if (and quiet (not (harness-bedrock--configured-p endpoint)))
           nil
         (harness-rejected
          (list 'error (harness-bedrock--no-keys-message
                        endpoint (and (eq (car-safe err) 'harness-bedrock-no-credentials) (cadr err))))))))))

(defun harness-bedrock--forget-keys (endpoint)
  "Drop the command keys kept for ENDPOINT: its AWS keys and its API key."
  (remhash (harness-bedrock--keys-cache-key endpoint) harness-bedrock--kept-keys)
  (remhash (harness-bedrock--api-key-cache-key endpoint) harness-bedrock--kept-keys))

(defun harness-bedrock-forget-credentials ()
  "Forget every key a command printed, so the next request runs it again."
  (interactive)
  (clrhash harness-bedrock--kept-keys))

(defconst harness-bedrock--header-variable-regexp "\\${\\([A-Za-z_][A-Za-z0-9_]*\\)}"
  "Matches ${NAME}, a reference to an environment variable in a header value.")

(defun harness-bedrock--header-variables (endpoint)
  "Return the environment variables ENDPOINT's `:headers' refer to as ${NAME}."
  (let (names)
    (dolist (h (plist-get endpoint :headers))
      (let ((value (cdr-safe h)) (start 0))
        (while (and (stringp value) (string-match harness-bedrock--header-variable-regexp value start))
          (cl-pushnew (match-string 1 value) names :test #'equal)
          (setq start (match-end 0)))))
    (nreverse names)))

(defun harness-bedrock--expand-headers (endpoint)
  "Return ENDPOINT's `:headers' with every ${NAME} replaced by variable NAME.
So a gateway's key can sit in the environment rather than in the
setting.  Signal an error naming the variable, never a value, when one
is unset."
  (mapcar (lambda (h)
            (if (not (stringp (cdr-safe h)))
                h
              (cons (car h)
                    (replace-regexp-in-string
                     harness-bedrock--header-variable-regexp
                     (lambda (match)
                       (let ((var (match-string 1 match)))
                         (or (harness-bedrock--env var)
                             (error "Header %s of %s needs environment variable %s, which is not set"
                                    (car h) (plist-get endpoint :id) var))))
                     (cdr h) t t))))
          (plist-get endpoint :headers)))

(defun harness-bedrock--redact (text auth &optional endpoint)
  "Return TEXT with the secrets of AUTH replaced by [redacted].
With ENDPOINT, so are the values of the environment variables its
`:headers' refer to."
  (let ((text (or text "")))
    (dolist (secret (append (list (plist-get auth :secret-access-key) (plist-get auth :session-token)
                                  (plist-get auth :token))
                            (mapcar #'harness-bedrock--env (harness-bedrock--header-variables endpoint)))
                    text)
      (when (and (stringp secret) (>= (length secret) 8))
        (setq text (string-replace secret "[redacted]" text))))))

(defun harness-bedrock--request-headers (endpoint auth method url payload region &optional headers signing-url)
  "Return the headers of a METHOD request to URL with PAYLOAD for ENDPOINT.
AUTH are the keys, REGION the region, HEADERS the request's own
headers, signed along with Host and X-Amz-Date.  SIGNING-URL, when it
differs from URL, is the URL the request is signed for (see
`harness-bedrock--signing-url'): its host is signed but not sent, so
the gateway at URL gets a Host of its own.  An API key goes in the
header `harness-bedrock--api-key-header' names.  The endpoint's
`:headers' come last, their ${NAME} references expanded, and replace
headers of the same name."
  (let* ((sigv4 (eq (plist-get auth :type) 'sigv4))
         (signing-url (or signing-url url))
         (passthrough (not (equal signing-url url)))
         (own (if (and sigv4 (not passthrough))
                  (cons (cons "Host" (harness-bedrock--host-header url)) headers)
                headers))
         (auth-headers
          (pcase (plist-get auth :type)
            ('bearer (list (harness-bedrock--api-key-header endpoint (plist-get auth :token))))
            ('sigv4
             (let ((signed (plist-get
                            (harness-bedrock-sigv4
                             :method method :url signing-url :headers own :body payload
                             :access-key-id (plist-get auth :access-key-id)
                             :secret-access-key (plist-get auth :secret-access-key)
                             :session-token (plist-get auth :session-token)
                             :region (or (harness-bedrock--nonempty (plist-get endpoint :signing-region)) region)
                             :service (or (harness-bedrock--nonempty (plist-get endpoint :signing-service))
                                          "bedrock"))
                            :headers)))
               (if passthrough
                   (cl-remove-if (lambda (h) (string-equal-ignore-case (car h) "host")) signed)
                 signed)))
            (_ nil)))
         (custom (harness-bedrock--expand-headers endpoint)))
    (append (cl-remove-if (lambda (h) (assoc-string (car h) custom t)) (append own auth-headers))
            custom)))

;;;; Model catalogue

(defun harness-bedrock--defaults-for (&rest ids)
  "Return the defaults of the first of IDS that matches.
They come from `harness-bedrock--model-defaults'."
  (cl-loop for id in ids
           thereis (and (stringp id)
                        (cl-loop for (re . plist) in harness-bedrock--model-defaults
                                 when (string-match-p re id) return plist))))

(defun harness-bedrock--modalities (values)
  "Map Bedrock modality VALUES such as (\"TEXT\" \"IMAGE\") to harness ones."
  (let ((out nil))
    (dolist (v values)
      (let ((m (downcase (format "%s" v))))
        (when (member m '("text" "image")) (cl-pushnew m out :test #'equal))))
    (and out (if (member "text" out) (cons "text" (delete "text" out)) out))))

(defun harness-bedrock--model-entry (endpoint id &optional label base modalities)
  "Return the model plist of model ID at ENDPOINT.
LABEL names it, BASE is the id of the foundation model behind an
inference profile and MODALITIES the input modalities Bedrock lists."
  (let* ((defaults (harness-bedrock--defaults-for id base))
         (modalities (or modalities (plist-get defaults :input-modalities) '("text")))
         (style (plist-get defaults :thinking))
         (model (list :name id :label (or label id))))
    (cond ((plist-get defaults :context-window)
           (setq model (plist-put model :context-window (plist-get defaults :context-window)))
           (when (plist-get defaults :context-window-estimated)
             (setq model (plist-put (plist-put model :context-window-estimated t)
                                    :context-window-basis "Bedrock's defaults for the model's family"))))
          ((plist-get endpoint :default-context)
           (setq model (plist-put model :context-window (plist-get endpoint :default-context)))))
    (dolist (key '(:max-output :pricing :request-fields :thinks-by-default))
      (when (plist-get defaults key)
        (setq model (plist-put model key (plist-get defaults key)))))
    (setq model (plist-put model :input-modalities modalities))
    (when style
      (setq model (plist-put model :thinking-levels
                             (or (plist-get defaults :thinking-levels) '("low" "medium" "high")))))
    (setq model (plist-put model :thinking-style style))
    (when (and base (not (equal base id)))
      (setq model (plist-put model :base base)))
    (plist-put model :capabilities
               (list :tools t
                     :vision (and (member "image" modalities) t)
                     :thinking (and style t)
                     :prompt-caching (and (plist-get defaults :prompt-caching) t)))))

(defun harness-bedrock--static-models (endpoint)
  "Return ENDPOINT's `:models' as model plists, filled in from the defaults."
  (mapcar (lambda (m)
            (let* ((plist (if (stringp m) (list :name m) m))
                   (entry (harness-bedrock--model-entry endpoint (plist-get plist :name)
                                                        (plist-get plist :label) (plist-get plist :base))))
              ;; A window given here is the model's own, not a family's guess.
              (when (plist-get plist :context-window)
                (setq entry (harness-plist-remove entry :context-window-estimated :context-window-basis)))
              (harness-plist-merge entry
                                   (harness-plist-remove plist :capabilities)
                                   (list :capabilities (harness-plist-merge (plist-get entry :capabilities)
                                                                            (plist-get plist :capabilities))))))
          (plist-get endpoint :models)))

(defun harness-bedrock--arn-model-id (arn)
  "Return the foundation model id at the end of ARN."
  (if (and (stringp arn) (string-match "foundation-model/\\(.+\\)\\'" arn)) (match-string 1 arn) arn))

(defun harness-bedrock--catalogue (endpoint foundation profiles)
  "Build ENDPOINT's model plists from FOUNDATION and PROFILES.
FOUNDATION is the ListFoundationModels answer and PROFILES a list of
inference profile summaries.  A model that only runs through inference
profiles appears as its profiles."
  (let ((by-id (make-hash-table :test 'equal))
        (models nil))
    (dolist (s (plist-get foundation :modelSummaries))
      (puthash (plist-get s :modelId) s by-id))
    (dolist (s (plist-get foundation :modelSummaries))
      (when (and (member "TEXT" (plist-get s :outputModalities))
                 (not (eq (plist-get s :responseStreamingSupported) :false))
                 (or (null (plist-get s :inferenceTypesSupported))
                     (member "ON_DEMAND" (plist-get s :inferenceTypesSupported))))
        (push (harness-bedrock--model-entry endpoint (plist-get s :modelId) (plist-get s :modelName) nil
                                            (harness-bedrock--modalities (plist-get s :inputModalities)))
              models)))
    (dolist (p profiles)
      (let* ((bases (mapcar (lambda (m) (harness-bedrock--arn-model-id (plist-get m :modelArn)))
                            (plist-get p :models)))
             (summary (cl-some (lambda (b) (gethash b by-id)) bases))
             (id (if (equal (plist-get p :type) "APPLICATION")
                     (plist-get p :inferenceProfileArn)
                   (plist-get p :inferenceProfileId))))
        (when (and id (or (null summary) (member "TEXT" (plist-get summary :outputModalities))))
          (push (harness-bedrock--model-entry endpoint id (plist-get p :inferenceProfileName) (car bases)
                                              (and summary (harness-bedrock--modalities
                                                            (plist-get summary :inputModalities))))
                models))))
    (sort (nreverse models) (lambda (a b) (string< (downcase (plist-get a :label))
                                                   (downcase (plist-get b :label)))))))

(defun harness-bedrock--get-json (endpoint auth path region)
  "Return a promise of the JSON answer to ENDPOINT's GET of PATH.
PATH, with its query, is under ENDPOINT's control URL.  AUTH are the
keys the request is authenticated with and REGION the region."
  (let* ((url (harness-bedrock--url (harness-bedrock--control-url endpoint region) path))
         (signing-url (harness-bedrock--signing-url endpoint url path 'control region)))
    (condition-case err
        (harness-http-request-json
         url :headers (harness-bedrock--request-headers endpoint auth "GET" url "" region
                                                        '(("Accept" . "application/json"))
                                                        signing-url)
         :timeout 60)
      (error (harness-rejected err)))))

(defun harness-bedrock--list-profiles (endpoint auth region type &optional token acc pages)
  "Return a promise of every inference profile of TYPE at ENDPOINT.
AUTH and REGION authenticate the requests; TOKEN, ACC and PAGES carry
the pagination."
  (let ((path (concat "/inference-profiles?maxResults=1000&type=" type
                      (if token (concat "&nextToken=" (harness-bedrock--uri-encode token)) ""))))
    (harness-then (harness-bedrock--get-json endpoint auth path region)
                  (lambda (json)
                    (let ((acc (append acc (plist-get json :inferenceProfileSummaries)))
                          (next (plist-get json :nextToken)))
                      (if (and (stringp next) (not (string-empty-p next)) (< (or pages 1) 20))
                          (harness-bedrock--list-profiles endpoint auth region type next acc (1+ (or pages 1)))
                        acc))))))

(defun harness-bedrock--error-text (body)
  "Return the error message in BODY, a JSON or plain error response."
  (let* ((text (string-trim (harness-bedrock--text (or body ""))))
         (json (ignore-errors (harness-json-parse text)))
         (msg (and (listp json)
                   (or (plist-get json :message) (plist-get json :Message)
                       (and (stringp (plist-get json :error)) (plist-get json :error))
                       (harness-plist-get-in json '(:error :message))))))
    (cond ((stringp msg) msg)
          ((not (string-empty-p text)) (harness-truncate-end text 300))
          (t "no details"))))

(defun harness-bedrock--describe-error (err)
  "Return a short description of a rejection ERR, without secrets."
  (pcase err
    (`(http-error ,status ,body)
     (format "HTTP %s: %s" (or status "?")
             (if (stringp body) (harness-bedrock--error-text body) (harness-error-message body))))
    (`(json-error ,status ,msg) (format "HTTP %s: bad JSON (%s)" status msg))
    (`(harness-bedrock-no-credentials ,errors) (string-join (or errors '("no credentials")) "; "))
    (_ (harness-error-message err))))

(defun harness-bedrock--refused-p (err)
  "Non-nil when ERR, a rejected request, was refused for its keys."
  (pcase err (`(http-error ,status . ,_) (memql status '(401 403)))))

(defun harness-bedrock--fetch-models (endpoint &optional refreshed)
  "List ENDPOINT's models through the Bedrock API.
Return a promise of model plists, nil when there are no credentials to
list with.  A failure resolves to `failed' after a warning, so one bad
endpoint never hides the others.  When every listing is refused with
keys a command printed, they are forgotten and the listing asked for
once more, unless REFRESHED."
  (let ((id (plist-get endpoint :id))
        (region (harness-bedrock--region endpoint)))
    (harness-then
     (harness-bedrock--auth endpoint t)
     (lambda (auth)
       (if (null auth)
           (progn (harness-log 'debug "bedrock %s: no credentials configured; no models listed" id)
                  nil)
         (let* ((call (lambda (what promise)
                        (harness-then promise
                                      (lambda (value) (list 'ok value))
                                      (lambda (err) (list 'failed what err)))))
                (foundation (funcall call "ListFoundationModels"
                                     (harness-bedrock--get-json
                                      endpoint auth "/foundation-models?byOutputModality=TEXT" region)))
                (profiles (unless (and (plist-member endpoint :inference-profiles)
                                       (memq (plist-get endpoint :inference-profiles) '(nil :false)))
                            (list (funcall call "ListInferenceProfiles"
                                           (harness-bedrock--list-profiles
                                            endpoint auth region "SYSTEM_DEFINED"))
                                  (funcall call "ListInferenceProfiles (application)"
                                           (harness-bedrock--list-profiles
                                            endpoint auth region "APPLICATION"))))))
           (harness-then
            (harness-all (cons foundation profiles))
            (lambda (results)
              (let ((failures (cl-remove-if-not (lambda (r) (eq (car r) 'failed)) results)))
                (if (and (= (length failures) (length results)) (not refreshed)
                         (plist-get auth :command)
                         (cl-some (lambda (f) (harness-bedrock--refused-p (nth 2 f))) failures))
                    (progn (harness-bedrock--forget-keys endpoint)
                           (harness-bedrock--fetch-models endpoint t))
                  (dolist (f failures)
                    (harness-log 'warn "bedrock %s: %s failed: %s" id (nth 1 f)
                                 (harness-bedrock--redact (harness-bedrock--describe-error (nth 2 f))
                                                          auth endpoint)))
                  (if (= (length failures) (length results))
                      (let ((url (harness-bedrock--control-url endpoint region)))
                        (unless (harness-bedrock--aws-url-p url)
                          (harness-log 'warn "bedrock %s: %s lists no models; when the gateway does not list them, name them in Models (:models), or set its Listing URL (:control-url)"
                                       id url))
                        'failed)
                    (harness-bedrock--catalogue
                     endpoint
                     (and (eq (car (car results)) 'ok) (nth 1 (car results)))
                     (cl-loop for r in (cdr results) when (eq (car r) 'ok) append (nth 1 r)))))))))))
     (lambda (err)
       (harness-log 'warn "bedrock %s: listing models failed: %s" id
                    (harness-bedrock--redact (harness-bedrock--describe-error err) nil endpoint))
       'failed))))

(defun harness-bedrock--models (endpoint &optional refresh)
  "Return a promise of ENDPOINT's models, cached for `harness-bedrock--models-ttl'.
REFRESH non-nil lists them again however fresh the cache is.  When the
listing fails the models listed before stay, if there are any."
  (let* ((id (plist-get endpoint :id))
         (cached (gethash id harness-bedrock--models-cache)))
    (cond
     ((and cached (not refresh) (< (- (float-time) (car cached)) harness-bedrock--models-ttl))
      (harness-resolved (cdr cached)))
     ((or (plist-get endpoint :models)
          (and (plist-member endpoint :list-models)
               (memq (plist-get endpoint :list-models) '(nil :false))))
      (let ((models (harness-bedrock--static-models endpoint)))
        (puthash id (cons (float-time) models) harness-bedrock--models-cache)
        (harness-resolved models)))
     (t
      (harness-then (harness-bedrock--fetch-models endpoint)
                    (lambda (models)
                      (cond ((not (eq models 'failed))
                             (when models
                               (puthash id (cons (float-time) models) harness-bedrock--models-cache))
                             models)
                            ((cdr cached)
                             (harness-log 'warn "bedrock %s: keeping the %d models listed before"
                                          id (length (cdr cached)))
                             (cdr cached)))))))))

(defun harness-bedrock-clear-models-cache ()
  "Forget every listed model catalogue so the next listing asks Bedrock again."
  (interactive)
  (clrhash harness-bedrock--models-cache))

(defun harness-bedrock--model-info (endpoint name)
  "Return the model plist of model NAME at ENDPOINT.
The listed catalogue is used when it knows the model, else the defaults.
It is also the provider's `:resolve', which describes a model the
listing lacks."
  (or (cl-find name (cdr (gethash (plist-get endpoint :id) harness-bedrock--models-cache))
               :key (lambda (m) (plist-get m :name)) :test #'equal)
      (cl-find name (harness-bedrock--static-models endpoint)
               :key (lambda (m) (plist-get m :name)) :test #'equal)
      (harness-bedrock--model-entry endpoint name)))

;;;; Converse request body

(defvar harness-bedrock--image-formats
  '(("image/png" . "png") ("image/jpeg" . "jpeg") ("image/jpg" . "jpeg")
    ("image/gif" . "gif") ("image/webp" . "webp"))
  "MIME type -> Converse image format.")

(defvar harness-bedrock--image-extensions
  '(("png" . "image/png") ("jpg" . "image/jpeg") ("jpeg" . "image/jpeg")
    ("gif" . "image/gif") ("webp" . "image/webp"))
  "File extension -> MIME type of images read from a path.")

(defun harness-bedrock--block-type (block)
  "Return BLOCK's `:type' as a string."
  (harness-bedrock--string (plist-get block :type)))

(defun harness-bedrock--file-base64 (path)
  "Return the contents of PATH, base64 encoded on one line."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (base64-encode-string (buffer-string) t)))

(defun harness-bedrock--tool-id (id)
  "Return tool use ID as Converse accepts it: [a-zA-Z0-9_.:-], at most 64."
  (let ((clean (replace-regexp-in-string "[^a-zA-Z0-9_.:-]" "_" (or (harness-bedrock--string id) ""))))
    (cond ((string-empty-p clean) "tool_call")
          ((> (length clean) 64) (concat (substring clean 0 55) "_" (substring (secure-hash 'sha1 clean) 0 8)))
          (t clean))))

(defun harness-bedrock--result-text (content)
  "Flatten a tool result CONTENT (string or blocks) into text."
  (let ((text (cond ((null content) "")
                    ((stringp content) content)
                    ((listp content)
                     (mapconcat (lambda (b)
                                  (if (stringp b) b
                                    (or (plist-get b :text)
                                        (and (equal (harness-bedrock--block-type b) "image") "[image]")
                                        "")))
                                content "\n"))
                    (t (format "%s" content)))))
    (if (string-blank-p text) "(no output)" text)))

(defun harness-bedrock--image (block)
  "Return the Converse image block for an image BLOCK, or a text block."
  (let* ((path (plist-get block :path))
         (mime (or (plist-get block :mime)
                   (and path (cdr (assoc (downcase (or (file-name-extension path) ""))
                                         harness-bedrock--image-extensions)))))
         (format (cdr (assoc (and mime (downcase mime)) harness-bedrock--image-formats)))
         (data (and format (or (plist-get block :data)
                               (and path (file-readable-p path) (harness-bedrock--file-base64 path))))))
    (if (and format data)
        (list :image (list :format format :source (list :bytes data)))
      (list :text (format "[image attached: %s]" (or path mime "unsupported format"))))))

(defun harness-bedrock--user-content (block)
  "Map a user BLOCK to a Converse content block, or nil to drop it."
  (pcase (harness-bedrock--block-type block)
    ("text" (let ((text (plist-get block :text)))
              (and (stringp text) (not (string-blank-p text)) (list :text text))))
    ("image" (harness-bedrock--image block))
    ("audio" (list :text (format "[audio attached: %s]" (or (plist-get block :path) "clip"))))
    ("file" (list :text (format "[attached file: %s]"
                                (or (plist-get block :path) (plist-get block :name) "?"))))
    ("tool_result"
     (list :toolResult (list :toolUseId (harness-bedrock--tool-id (plist-get block :tool_use_id))
                             :content (list (list :text (harness-bedrock--result-text (plist-get block :content))))
                             :status (if (harness-json-true-p (plist-get block :is_error)) "error" "success"))))
    (_ nil)))

(defun harness-bedrock--tool-input (input)
  "Return tool INPUT as a JSON object for Converse."
  (if (and input (listp input) (keywordp (car input))) input :empty))

(defun harness-bedrock--assistant-content (block)
  "Map an assistant BLOCK to a Converse content block, or nil to drop it.
Thinking without a signature cannot be sent back and is dropped."
  (pcase (harness-bedrock--block-type block)
    ("text" (let ((text (plist-get block :text)))
              (and (stringp text) (not (string-blank-p text)) (list :text text))))
    ("thinking" (let ((signature (plist-get block :signature)))
                  (and (stringp signature) (not (string-empty-p signature))
                       (list :reasoningContent
                             (list :reasoningText (list :text (or (plist-get block :text) "")
                                                        :signature signature))))))
    ("tool_use" (list :toolUse (list :toolUseId (harness-bedrock--tool-id (plist-get block :id))
                                     :name (plist-get block :name)
                                     :input (harness-bedrock--tool-input (plist-get block :input)))))
    (_ nil)))

(defun harness-bedrock--message-blocks (msg)
  "Return MSG's content as a list of blocks, wrapping a bare string."
  (let ((c (plist-get msg :content)))
    (if (stringp c) (list (list :type "text" :text c)) c)))

(defun harness-bedrock--tool-use-ids (content)
  "Return the tool use ids in Converse CONTENT, in order."
  (delq nil (mapcar (lambda (b) (harness-plist-get-in b '(:toolUse :toolUseId))) content)))

(defun harness-bedrock--remembered-content (content)
  "Return the response assistant CONTENT came from, reasoning included, or nil.
That is what `harness-bedrock--remember-response' kept for the same
tool calls."
  (let* ((ids (harness-bedrock--tool-use-ids content))
         (entry (and ids (gethash (car ids) harness-bedrock--responses))))
    (and entry (equal ids (harness-bedrock--tool-use-ids (cdr entry))) (cdr entry))))

(defun harness-bedrock--strip-reasoning (content)
  "Return CONTENT without reasoning blocks."
  (cl-remove-if (lambda (b) (plist-get b :reasoningContent)) content))

(defun harness-bedrock--tool-result-first (content)
  "Return user CONTENT with its tool results first, as Claude requires."
  (append (cl-remove-if-not (lambda (b) (plist-get b :toolResult)) content)
          (cl-remove-if (lambda (b) (plist-get b :toolResult)) content)))

(defun harness-bedrock--flatten-tools (content)
  "Return CONTENT with tool calls and results turned into text."
  (mapcar (lambda (b)
            (cond
             ((plist-get b :toolUse)
              (let ((use (plist-get b :toolUse)))
                (list :text (format "[called tool %s with %s]" (plist-get use :name)
                                    (harness-json-encode-text (plist-get use :input))))))
             ((plist-get b :toolResult)
              (let ((result (plist-get b :toolResult)))
                (list :text (format "[result of tool call %s%s]\n%s" (plist-get result :toolUseId)
                                    (if (equal (plist-get result :status) "error") ", an error" "")
                                    (mapconcat (lambda (c) (or (plist-get c :text) ""))
                                               (plist-get result :content) "\n")))))
             (t b)))
          content))

(defun harness-bedrock--pair-tools (messages)
  "Return MESSAGES with every tool call answered and every result asked for.
A call without a result gets an error result; a result without its
call becomes text.  Converse rejects either."
  (let ((out nil) (prev nil))
    (dolist (m messages)
      (let ((content (plist-get m :content)))
        (when (equal (plist-get m :role) "user")
          (let* ((asked (and prev (equal (plist-get prev :role) "assistant")
                             (harness-bedrock--tool-use-ids (plist-get prev :content))))
                 (answered (delq nil (mapcar (lambda (b) (harness-plist-get-in b '(:toolResult :toolUseId)))
                                             content))))
            (setq content
                  (harness-bedrock--tool-result-first
                   (append
                    (mapcar (lambda (id)
                              (list :toolResult (list :toolUseId id
                                                      :content '((:text "No result was recorded for this call."))
                                                      :status "error")))
                            (cl-set-difference asked answered :test #'equal))
                    (mapcar (lambda (b)
                              (let ((id (harness-plist-get-in b '(:toolResult :toolUseId))))
                                (if (and id (not (member id asked)))
                                    (car (harness-bedrock--flatten-tools (list b)))
                                  b)))
                            content))))))
        (let ((m (list :role (plist-get m :role) :content content)))
          (push m out)
          (setq prev m))))
    (nreverse out)))

(cl-defun harness-bedrock--messages (request &key (reasoning t) (tools t))
  "Return (:messages MESSAGES :system TEXTS) for REQUEST in Converse form.
Roles alternate starting with the user, tool results ride in user
messages and blank text is dropped.  With REASONING, an assistant
message that made tool calls goes back as the model produced it,
reasoning included, when that response is remembered; without it,
reasoning is left out.  Without TOOLS, calls and results become text."
  (let (merged system)
    (dolist (msg (plist-get request :messages))
      (let* ((role (harness-bedrock--string (plist-get msg :role)))
             (blocks (harness-bedrock--message-blocks msg)))
        (if (equal role "system")
            (let ((text (harness-bedrock--result-text blocks)))
              (unless (equal text "(no output)") (push text system)))
          (let* ((role (if (equal role "assistant") "assistant" "user"))
                 (content (delq nil (mapcar (if (equal role "assistant")
                                                #'harness-bedrock--assistant-content
                                              #'harness-bedrock--user-content)
                                            blocks))))
            (when (equal role "assistant")
              (let ((remembered (and reasoning (harness-bedrock--remembered-content content))))
                (setq content (cond (remembered (copy-sequence remembered))
                                    (reasoning content)
                                    (t (harness-bedrock--strip-reasoning content))))))
            (unless tools (setq content (harness-bedrock--flatten-tools content)))
            (when content
              (if (equal (plist-get (car merged) :role) role)
                  (setcar merged (list :role role :content (append (plist-get (car merged) :content) content)))
                (push (list :role role :content content) merged)))))))
    (setq merged (nreverse merged))
    (when (equal (plist-get (car merged) :role) "assistant")
      (push (list :role "user" :content '((:text "(The conversation continues.)"))) merged))
    (list :messages (if tools (harness-bedrock--pair-tools merged) merged)
          :system (nreverse system))))

(defun harness-bedrock--tools (specs)
  "Map harness tool SPECS to Converse tool specifications."
  (mapcar (lambda (spec)
            (let ((tool (list :name (plist-get spec :name)
                              :inputSchema (list :json (or (plist-get spec :schema)
                                                           '(:type "object" :properties :empty)))))
                  (description (plist-get spec :description)))
              (when (and (stringp description) (not (string-blank-p description)))
                (setq tool (plist-put tool :description description)))
              (list :toolSpec tool)))
          specs))

(defconst harness-bedrock--levels '("low" "medium" "high" "xhigh" "max")
  "Thinking levels from weakest to strongest.")

(defun harness-bedrock--clamp-level (level levels)
  "Return LEVEL when LEVELS offer it, else the strongest of LEVELS below it."
  (if (or (null levels) (member level levels))
      level
    (let ((rank (lambda (l) (or (cl-position l harness-bedrock--levels :test #'equal) -1)))
          (best nil))
      (dolist (l levels)
        (when (and (<= (funcall rank l) (funcall rank level))
                   (or (null best) (> (funcall rank l) (funcall rank best))))
          (setq best l)))
      (or best (car levels)))))

(defun harness-bedrock--thinking (info level max-tokens)
  "Return (FIELDS . MAX-TOKENS) that ask model INFO to think at LEVEL.
FIELDS go into additionalModelRequestFields; a thinking budget raises
the output limit MAX-TOKENS above it."
  (let ((level (harness-bedrock--string level)))
    (pcase (and level (plist-get info :thinking-style))
      ((or 'adaptive 'adaptive-only)
       (cons (list :thinking '(:type "adaptive")
                   :output_config (list :effort (harness-bedrock--clamp-level
                                                 level (plist-get info :thinking-levels))))
             max-tokens))
      ('budget
       (let* ((budget (or (cdr (assoc level harness-bedrock--thinking-budgets)) 10000))
              (cap (plist-get info :max-output))
              (limit (max (or max-tokens 0) (+ budget 4096)))
              (limit (if cap (min limit cap) limit))
              (budget (max 1024 (min budget (- limit 1024)))))
         (cons (list :thinking (list :type "enabled" :budget_tokens budget)) limit)))
      (_ (cons nil max-tokens)))))

(defun harness-bedrock--max-tokens (endpoint info request)
  "Return the output token limit of REQUEST for model INFO at ENDPOINT, or nil."
  (let ((explicit (or (plist-get request :max-tokens) (plist-get endpoint :max-tokens)))
        (cap (plist-get info :max-output)))
    (if cap
        (min (or explicit harness-bedrock--default-max-tokens cap) cap)
      explicit)))

(defun harness-bedrock--caching-p (endpoint info)
  "Non-nil when requests for model INFO at ENDPOINT carry cache points."
  (let ((setting (if (plist-member endpoint :prompt-caching)
                     (plist-get endpoint :prompt-caching)
                   harness-bedrock--prompt-caching)))
    (cond ((memq setting '(nil :false)) nil)
          ((eq setting 'always) t)
          (t (plist-get (plist-get info :capabilities) :prompt-caching)))))

(defconst harness-bedrock--cache-point '(:cachePoint (:type "default"))
  "A Converse cache point.")

(defun harness-bedrock--add-cache-points (body)
  "Return BODY with cache points for an agent loop.
One follows the system prompt (or the tools, without one) and one ends
each of the last two user messages, so every call reads from the cache
what the call before it wrote."
  (let ((system (plist-get body :system))
        (tools (harness-plist-get-in body '(:toolConfig :tools)))
        (messages (copy-sequence (plist-get body :messages)))
        (marked 0))
    (cond (system
           (setq body (plist-put body :system (append system (list harness-bedrock--cache-point)))))
          (tools
           (setq body (plist-put body :toolConfig
                                 (plist-put (copy-sequence (plist-get body :toolConfig))
                                            :tools (append tools (list harness-bedrock--cache-point)))))))
    (cl-loop for i downfrom (1- (length messages)) to 0
             while (< marked 2)
             for m = (nth i messages)
             when (equal (plist-get m :role) "user")
             do (setf (nth i messages)
                      (list :role "user"
                            :content (append (plist-get m :content) (list harness-bedrock--cache-point))))
             (cl-incf marked))
    (plist-put body :messages messages)))

(defun harness-bedrock--thinks-p (info level)
  "Non-nil when model INFO thinks in a request at thinking LEVEL.
Reasoning may only go back to a model that thinks: Claude rejects it
in a tool loop when thinking is off."
  (and (plist-get info :thinking-style)
       (or level
           (eq (plist-get info :thinking-style) 'adaptive-only)
           (plist-get info :thinks-by-default))
       t))

(defun harness-bedrock--body (endpoint info request &optional options)
  "Build the Converse request body for model INFO at ENDPOINT from REQUEST.
OPTIONS is a plist: `:no-cache' leaves out cache points, `:no-tools'
the tools."
  (let* ((level (plist-get request :thinking))
         (tools (and (not (plist-get options :no-tools))
                     (harness-bedrock--tools (plist-get request :tools))))
         (converted (harness-bedrock--messages
                     request
                     :reasoning (or (harness-bedrock--thinks-p info level)
                                    ;; Unknown models: send back what they gave.
                                    (null (plist-get info :thinking-style)))
                     :tools (and tools t)))
         (system (delq nil (cons (let ((text (plist-get request :system)))
                                   (and (stringp text) (not (string-blank-p text)) text))
                                 (plist-get converted :system))))
         (thinking (harness-bedrock--thinking info level (harness-bedrock--max-tokens endpoint info request)))
         (fields (harness-plist-merge (plist-get endpoint :request-fields)
                                      (plist-get info :request-fields)
                                      (car thinking)))
         (body (list :messages (plist-get converted :messages))))
    (when system
      (setq body (plist-put body :system (list (list :text (string-join system "\n\n"))))))
    (when tools
      (setq body (plist-put body :toolConfig (list :tools tools))))
    (when (cdr thinking)
      (setq body (plist-put body :inferenceConfig (list :maxTokens (cdr thinking)))))
    (when fields
      (setq body (plist-put body :additionalModelRequestFields fields)))
    (if (and (not (plist-get options :no-cache)) (harness-bedrock--caching-p endpoint info))
        (harness-bedrock--add-cache-points body)
      body)))

;;;; Responses

(cl-defstruct (harness-bedrock--stream (:copier nil))
  "State of one completion request, across its attempts."
  on-event endpoint name request info region
  options auth http timer
  (retries 0) (refreshed nil)
  ;; Per attempt.
  status content-type (raw "") (cached nil) (tools-sent nil) (streaming t)
  blocks stop-reason usage error error-type
  ;; For the whole request.
  (emitted nil) (finished nil))

(defun harness-bedrock--quirk-key (stream)
  "Return the key STREAM's model is remembered under in `harness-bedrock--quirks'."
  (format "%s/%s" (plist-get (harness-bedrock--stream-endpoint stream) :id)
          (harness-bedrock--stream-name stream)))

(defun harness-bedrock--emit (stream event)
  "Send EVENT to STREAM's listener."
  (funcall (harness-bedrock--stream-on-event stream) event))

(defun harness-bedrock--block (stream index &optional init)
  "Return the cell (INDEX . PLIST) of content block INDEX of STREAM.
A missing block is created from INIT."
  (or (assq index (harness-bedrock--stream-blocks stream))
      (let ((cell (cons index (copy-sequence init))))
        (push cell (harness-bedrock--stream-blocks stream))
        cell)))

(defun harness-bedrock--block-put (cell key value)
  "Set KEY of the block in CELL to VALUE."
  (setcdr cell (plist-put (cdr cell) key value)))

(defun harness-bedrock--add-text (stream index text)
  "Append TEXT to text block INDEX of STREAM and emit it."
  (when (and (stringp text) (not (string-empty-p text)))
    (let ((cell (harness-bedrock--block stream index '(:type text :text ""))))
      (harness-bedrock--block-put cell :text (concat (plist-get (cdr cell) :text) text)))
    (setf (harness-bedrock--stream-emitted stream) t)
    (harness-bedrock--emit stream (list :type 'text :delta text))))

(defun harness-bedrock--add-reasoning (stream index reasoning)
  "Merge the REASONING delta into block INDEX of STREAM, emitting its text."
  (let ((cell (harness-bedrock--block stream index '(:type reasoning :text "")))
        (text (plist-get reasoning :text))
        (signature (plist-get reasoning :signature))
        (redacted (plist-get reasoning :redactedContent)))
    (when (and (stringp text) (not (string-empty-p text)))
      (harness-bedrock--block-put cell :text (concat (plist-get (cdr cell) :text) text))
      (setf (harness-bedrock--stream-emitted stream) t)
      (harness-bedrock--emit stream (list :type 'thinking :delta text)))
    (when (stringp signature)
      (harness-bedrock--block-put cell :signature (concat (or (plist-get (cdr cell) :signature) "") signature)))
    (when (stringp redacted)
      (harness-bedrock--block-put cell :redacted (concat (or (plist-get (cdr cell) :redacted) "") redacted)))))

(defun harness-bedrock--on-stream-event (stream event payload)
  "Handle a ConverseStream EVENT with its PAYLOAD for STREAM."
  (let ((index (or (plist-get payload :contentBlockIndex) 0)))
    (pcase event
      ("contentBlockStart"
       (when-let* ((tool (harness-plist-get-in payload '(:start :toolUse))))
         (harness-bedrock--block stream index
                                 (list :type 'tool :id (plist-get tool :toolUseId)
                                       :name (plist-get tool :name) :json ""))))
      ("contentBlockDelta"
       (let ((delta (plist-get payload :delta)))
         (cond
          ((stringp (plist-get delta :text))
           (harness-bedrock--add-text stream index (plist-get delta :text)))
          ((plist-get delta :toolUse)
           (let ((cell (harness-bedrock--block stream index '(:type tool :json ""))))
             (harness-bedrock--block-put
              cell :json (concat (or (plist-get (cdr cell) :json) "")
                                 (or (harness-plist-get-in delta '(:toolUse :input)) "")))))
          ((plist-get delta :reasoningContent)
           (harness-bedrock--add-reasoning stream index (plist-get delta :reasoningContent))))))
      ("messageStop"
       (setf (harness-bedrock--stream-stop-reason stream) (plist-get payload :stopReason)))
      ("metadata"
       (when (listp (plist-get payload :usage))
         (setf (harness-bedrock--stream-usage stream) (plist-get payload :usage))))
      (_ nil))))

(defun harness-bedrock--payload-json (bytes)
  "Parse the JSON payload BYTES of an event, or return nil."
  (let ((text (harness-bedrock--text (or bytes ""))))
    (unless (string-blank-p text)
      (condition-case nil (harness-json-parse text) (error nil)))))

(defun harness-bedrock--on-message (stream message)
  "Handle one decoded event stream MESSAGE for STREAM."
  (let* ((headers (plist-get message :headers))
         (kind (cdr (assoc ":message-type" headers)))
         (payload (harness-bedrock--payload-json (plist-get message :payload))))
    (pcase kind
      ("event"
       (harness-bedrock--on-stream-event stream (cdr (assoc ":event-type" headers)) payload))
      ("exception"
       (unless (harness-bedrock--stream-error stream)
         (let ((type (cdr (assoc ":exception-type" headers))))
           (setf (harness-bedrock--stream-error-type stream) type
                 (harness-bedrock--stream-error stream)
                 (format "%s: %s" (or type "exception")
                         (or (plist-get payload :message) (plist-get payload :Message)
                             (plist-get payload :originalMessage) "the model stream failed"))))))
      ("error"
       (unless (harness-bedrock--stream-error stream)
         (setf (harness-bedrock--stream-error-type stream) (cdr (assoc ":error-code" headers))
               (harness-bedrock--stream-error stream)
               (format "%s: %s" (or (cdr (assoc ":error-code" headers)) "error")
                       (or (cdr (assoc ":error-message" headers)) "the stream failed")))))
      (_ nil))))

(defun harness-bedrock--apply-response (stream json)
  "Fill STREAM from JSON, a whole (not streamed) Converse response.
Text and reasoning are emitted as if they had been streamed."
  (let ((index 0))
    (dolist (block (harness-plist-get-in json '(:output :message :content)))
      (cond
       ((stringp (plist-get block :text))
        (harness-bedrock--add-text stream index (plist-get block :text)))
       ((plist-get block :reasoningContent)
        (let ((r (plist-get block :reasoningContent)))
          (harness-bedrock--add-reasoning
           stream index
           (list :text (harness-plist-get-in r '(:reasoningText :text))
                 :signature (harness-plist-get-in r '(:reasoningText :signature))
                 :redactedContent (plist-get r :redactedContent)))))
       ((plist-get block :toolUse)
        (let ((use (plist-get block :toolUse)))
          (harness-bedrock--block stream index
                                  (list :type 'tool :id (plist-get use :toolUseId) :name (plist-get use :name)
                                        :input (plist-get use :input) :parsed t)))))
      (cl-incf index)))
  (setf (harness-bedrock--stream-stop-reason stream) (plist-get json :stopReason))
  (when (listp (plist-get json :usage))
    (setf (harness-bedrock--stream-usage stream) (plist-get json :usage))))

(defun harness-bedrock--blocks (stream)
  "Return STREAM's content blocks in order, as plists."
  (mapcar #'cdr (sort (copy-sequence (harness-bedrock--stream-blocks stream))
                      (lambda (a b) (< (car a) (car b))))))

(defun harness-bedrock--parse-input (block)
  "Return the input of tool BLOCK as a plist."
  (if (plist-get block :parsed)
      (plist-get block :input)
    (let ((raw (plist-get block :json)))
      (if (or (null raw) (string-blank-p raw))
          nil
        (condition-case err
            (harness-json-parse raw)
          (error (harness-log 'warn "bedrock: unparsable tool input: %s" (harness-error-message err))
                 (list :raw raw)))))))

(defun harness-bedrock--tool-calls (stream)
  "Return the tool-call events of STREAM's response."
  (cl-loop for block in (harness-bedrock--blocks stream)
           when (eq (plist-get block :type) 'tool)
           collect (list :type 'tool-call
                         :id (or (plist-get block :id) (concat "tooluse_" (harness-short-id 12)))
                         :name (plist-get block :name)
                         :input (harness-bedrock--parse-input block)
                         :respond nil)))

(defun harness-bedrock--response-content (stream calls)
  "Return STREAM's response as Converse content, with CALLS for its tool uses."
  (let ((calls (copy-sequence calls)))
    (delq nil
          (mapcar (lambda (block)
                    (pcase (plist-get block :type)
                      ('text (and (not (string-empty-p (plist-get block :text)))
                                  (list :text (plist-get block :text))))
                      ('reasoning
                       (cond ((plist-get block :signature)
                              (list :reasoningContent
                                    (list :reasoningText (list :text (plist-get block :text)
                                                               :signature (plist-get block :signature)))))
                             ((plist-get block :redacted)
                              (list :reasoningContent (list :redactedContent (plist-get block :redacted))))))
                      ('tool (let ((call (pop calls)))
                               (list :toolUse
                                     (list :toolUseId (harness-bedrock--tool-id (plist-get call :id))
                                           :name (plist-get call :name)
                                           :input (harness-bedrock--tool-input (plist-get call :input))))))))
                  (harness-bedrock--blocks stream)))))

(defun harness-bedrock--remember-response (stream calls)
  "Keep STREAM's response under the ids of its tool CALLS, when it reasoned.
The next request of the tool loop must send that reasoning back."
  (let ((content (harness-bedrock--response-content stream calls)))
    (when (and calls (cl-some (lambda (b) (plist-get b :reasoningContent)) content))
      (when (> (hash-table-count harness-bedrock--responses) harness-bedrock--responses-max)
        (let (entries)
          (maphash (lambda (k v) (push (cons (car v) k) entries)) harness-bedrock--responses)
          (dolist (e (seq-take (sort entries (lambda (a b) (< (car a) (car b))))
                               (/ harness-bedrock--responses-max 2)))
            (remhash (cdr e) harness-bedrock--responses))))
      (let ((entry (cons (float-time) content)))
        (dolist (call calls)
          (puthash (harness-bedrock--tool-id (plist-get call :id)) entry harness-bedrock--responses))))))

(defun harness-bedrock--usage-event (usage)
  "Build the usage event from a Converse USAGE object.
Bedrock bills per token; its input count leaves out cached tokens."
  (let ((input (or (plist-get usage :inputTokens) 0))
        (cache-read (or (plist-get usage :cacheReadInputTokens) 0))
        (cache-write (or (plist-get usage :cacheWriteInputTokens) 0)))
    (list :type 'usage
          :input input
          :output (or (plist-get usage :outputTokens) 0)
          :cache-read cache-read
          :cache-write cache-write
          :cost nil
          :billing 'api
          :context (+ input cache-read cache-write))))

(defun harness-bedrock--finish (stream reason &optional error)
  "End STREAM with stop REASON and optional ERROR text, emitting once.
Usage comes first, then the tool calls, then `done'."
  (unless (harness-bedrock--stream-finished stream)
    (setf (harness-bedrock--stream-finished stream) t)
    (when-let* ((timer (harness-bedrock--stream-timer stream)))
      (cancel-timer timer))
    (let ((usage (harness-bedrock--stream-usage stream)))
      (when (and usage (not (eq reason 'cancelled)))
        (harness-bedrock--emit stream (harness-bedrock--usage-event usage))))
    (when (eq reason 'tool-use)
      (let ((calls (harness-bedrock--tool-calls stream)))
        (condition-case err
            (harness-bedrock--remember-response stream calls)
          (error (harness-log 'warn "bedrock: keeping the response failed: %S" err)))
        (dolist (call calls) (harness-bedrock--emit stream call))))
    (harness-bedrock--emit stream (if error
                                      (list :type 'done :stop-reason reason
                                            :error (harness-bedrock--redact
                                                    error (harness-bedrock--stream-auth stream)
                                                    (harness-bedrock--stream-endpoint stream)))
                                    (list :type 'done :stop-reason reason)))))

(defconst harness-bedrock--stop-errors
  '(("guardrail_intervened" . "a guardrail intervened and stopped the response")
    ("content_filtered" . "the response was stopped by the content filter")
    ("malformed_model_output" . "the model produced malformed output")
    ("malformed_tool_use" . "the model produced a malformed tool call")
    ("model_context_window_exceeded" . "the conversation no longer fits the model's context window"))
  "Stop reasons that end a turn with an error, with what to tell the user.")

(defun harness-bedrock--complete-response (stream)
  "Finish STREAM once its response is complete, choosing the stop reason."
  (let* ((stop (harness-bedrock--stream-stop-reason stream))
         (tools (cl-find 'tool (harness-bedrock--blocks stream) :key (lambda (b) (plist-get b :type)))))
    (cond
     ((harness-bedrock--stream-error stream)
      (unless (harness-bedrock--maybe-retry stream (harness-bedrock--stream-error-type stream) nil
                                            (harness-bedrock--stream-error stream))
        (harness-bedrock--finish stream 'error (harness-bedrock--stream-error stream))))
     ;; A tool_use stop without a call would loop the agent on nothing.
     ((member stop '("tool_use" "end_turn" "stop_sequence"))
      (harness-bedrock--finish stream (if tools 'tool-use 'end-turn)))
     ((equal stop "max_tokens") (harness-bedrock--finish stream 'max-tokens))
     ((assoc stop harness-bedrock--stop-errors)
      (harness-bedrock--finish stream 'error (cdr (assoc stop harness-bedrock--stop-errors))))
     ((null stop) (harness-bedrock--finish stream 'error "the response ended before the model finished"))
     (t (harness-bedrock--finish stream (if tools 'tool-use 'end-turn))))))

;;;; Errors and retries

(defun harness-bedrock--error-type (headers body)
  "Return the AWS error type of a response from its HEADERS and BODY, or nil."
  (let ((header (cdr (assoc "x-amzn-errortype" headers)))
        (json (ignore-errors (harness-json-parse (harness-bedrock--text (or body ""))))))
    (or (and header (car (split-string header ":")))
        (and (listp json) (stringp (plist-get json :__type))
             (car (last (split-string (plist-get json :__type) "#")))))))

(defconst harness-bedrock--retryable
  '("ThrottlingException" "throttlingException" "ServiceUnavailableException"
    "serviceUnavailableException" "InternalServerException" "internalServerException"
    "ModelNotReadyException" "modelStreamErrorException")
  "Error types worth retrying after a pause.")

(defun harness-bedrock--retry-delay (retry)
  "Seconds to wait before RETRY, counting from 1."
  (min 30 (* 2 (expt 2 (1- retry)))))

(defun harness-bedrock--maybe-retry (stream type status message)
  "Retry STREAM after error TYPE or HTTP STATUS with MESSAGE, when that helps.
Only a request that streamed nothing yet is retried, at most
`harness-bedrock--max-retries' times.  Return non-nil when a retry was
scheduled."
  (when (and (not (harness-bedrock--stream-emitted stream))
             (< (harness-bedrock--stream-retries stream) harness-bedrock--max-retries)
             (or (member type harness-bedrock--retryable)
                 (memq status '(429 500 502 503 504))))
    (let* ((retry (cl-incf (harness-bedrock--stream-retries stream)))
           (delay (harness-bedrock--retry-delay retry)))
      (harness-bedrock--emit
       stream (list :type 'hint
                    :text (format "Bedrock: %s; retrying in %d s (%d of %d)"
                                  (harness-truncate-end
                                   (harness-bedrock--redact message (harness-bedrock--stream-auth stream)
                                                            (harness-bedrock--stream-endpoint stream))
                                   200)
                                  delay retry harness-bedrock--max-retries)))
      (setf (harness-bedrock--stream-timer stream)
            (run-at-time delay nil (lambda ()
                                     (setf (harness-bedrock--stream-timer stream) nil)
                                     (unless (harness-bedrock--stream-finished stream)
                                       (harness-bedrock--attempt stream)))))
      t)))

(defun harness-bedrock--adjustment (stream status message)
  "Return the option that works around a rejection of STREAM's request, or nil.
STATUS and MESSAGE describe the rejection: a model that takes no cache
points (`:no-cache'), no streamed tool use (`:no-stream') or no tools
at all (`:no-tools')."
  (when (eql status 400)
    (let ((options (harness-bedrock--stream-options stream))
          (case-fold-search t))
      (cond
       ((and (harness-bedrock--stream-cached stream) (not (plist-get options :no-cache))
             (string-match-p "cach" message))
        :no-cache)
       ((and (harness-bedrock--stream-tools-sent stream) (harness-bedrock--stream-streaming stream)
             (not (plist-get options :no-stream))
             (string-match-p "stream" message) (string-match-p "tool" message))
        :no-stream)
       ((and (harness-bedrock--stream-tools-sent stream) (not (plist-get options :no-tools))
             (string-match-p "tool" message)
             (string-match-p "support\\|not allowed\\|not enabled" message))
        :no-tools)))))

(defun harness-bedrock--http-error (stream status headers body)
  "Handle the error response STATUS with HEADERS and BODY to STREAM's request."
  (let* ((message (harness-bedrock--error-text body))
         (type (harness-bedrock--error-type headers body))
         (description (format "HTTP %s%s: %s" status (if type (concat " " type) "") message))
         (adjust (harness-bedrock--adjustment stream status message))
         (auth (harness-bedrock--stream-auth stream))
         (case-fold-search t))
    (cond
     (adjust
      (let ((key (harness-bedrock--quirk-key stream)))
        (puthash key (plist-put (copy-sequence (gethash key harness-bedrock--quirks)) adjust t)
                 harness-bedrock--quirks)
        (harness-log 'info "bedrock: %s rejected the request (%s); asking again with %s"
                     (harness-bedrock--stream-name stream)
                     (harness-truncate-end
                      (harness-bedrock--redact message auth (harness-bedrock--stream-endpoint stream))
                      200)
                     adjust)
        (setf (harness-bedrock--stream-options stream)
              (plist-put (copy-sequence (harness-bedrock--stream-options stream)) adjust t))
        (harness-bedrock--attempt stream)))
     ((and (not (harness-bedrock--stream-refreshed stream))
           (plist-get auth :command)
           ;; A command's keys may have gone stale before their time:
           ;; ask once more with fresh ones.  A gateway's refusal of
           ;; its token says little, so any 401 or 403 counts.
           (or (and (eq (plist-get auth :type) 'bearer) (memql status '(401 403)))
               (and (memql status '(400 401 403))
                    (string-match-p "expired\\|security token included in the request is invalid"
                                    message))))
      (setf (harness-bedrock--stream-refreshed stream) t)
      (harness-bedrock--forget-keys (harness-bedrock--stream-endpoint stream))
      (harness-bedrock--start stream))
     ((harness-bedrock--maybe-retry stream type status description))
     (t (harness-bedrock--finish stream 'error description)))))

;;;; Requests

(defun harness-bedrock--reset-attempt (stream)
  "Clear what the previous attempt of STREAM gathered."
  (setf (harness-bedrock--stream-status stream) nil
        (harness-bedrock--stream-content-type stream) nil
        (harness-bedrock--stream-raw stream) ""
        (harness-bedrock--stream-blocks stream) nil
        (harness-bedrock--stream-stop-reason stream) nil
        (harness-bedrock--stream-usage stream) nil
        (harness-bedrock--stream-error stream) nil
        (harness-bedrock--stream-error-type stream) nil))

(defun harness-bedrock--event-stream-p (stream)
  "Non-nil when STREAM's response is an event stream, not one JSON document."
  (let ((type (harness-bedrock--stream-content-type stream)))
    (and (harness-bedrock--stream-streaming stream)
         (or (null type) (string-match-p "eventstream" type)))))

(defun harness-bedrock--on-chunk (stream decoder chunk)
  "Feed CHUNK of STREAM's response to DECODER, or keep it when it is not a stream."
  (unless (harness-bedrock--stream-finished stream)
    (let ((status (harness-bedrock--stream-status stream)))
      (if (and status (>= status 200) (< status 300) (harness-bedrock--event-stream-p stream))
          (condition-case err
              (funcall decoder chunk)
            (harness-bedrock-eventstream-error
             (let ((http (harness-bedrock--stream-http stream)))
               (harness-bedrock--finish stream 'error
                                        (format "unreadable response stream: %s"
                                                (if (stringp (cadr err)) (cadr err) (harness-error-message err))))
               (when http (harness-http-cancel http)))))
        (setf (harness-bedrock--stream-raw stream)
              (concat (harness-bedrock--stream-raw stream) chunk))))))

(defun harness-bedrock--attempt (stream)
  "Send STREAM's request, with its current options."
  (unless (harness-bedrock--stream-finished stream)
    (condition-case err
        (let* ((endpoint (harness-bedrock--stream-endpoint stream))
               (options (harness-bedrock--stream-options stream))
               (body (harness-bedrock--body endpoint (harness-bedrock--stream-info stream)
                                            (harness-bedrock--stream-request stream) options))
               (streaming (not (plist-get options :no-stream)))
               (region (harness-bedrock--stream-region stream))
               (path (concat "/model/" (harness-bedrock--uri-encode (harness-bedrock--stream-name stream))
                             (if streaming "/converse-stream" "/converse")))
               (url (harness-bedrock--url (harness-bedrock--runtime-url endpoint region) path))
               (payload (harness-bedrock--bytes (harness-json-encode body)))
               (headers (harness-bedrock--request-headers
                         endpoint (harness-bedrock--stream-auth stream) "POST" url payload region
                         '(("Content-Type" . "application/json"))
                         (harness-bedrock--signing-url endpoint url path 'runtime region)))
               (decoder (harness-bedrock-eventstream-decoder
                         (lambda (message) (harness-bedrock--on-message stream message)))))
          (harness-bedrock--reset-attempt stream)
          (setf (harness-bedrock--stream-streaming stream) streaming
                (harness-bedrock--stream-tools-sent stream) (and (plist-get body :toolConfig) t)
                (harness-bedrock--stream-cached stream) (and (string-search "\"cachePoint\"" payload) t))
          (setf (harness-bedrock--stream-http stream)
                (harness-http-request
                 url :method "POST" :headers headers :body payload :binary t
                 :timeout harness-bedrock--request-timeout
                 :on-headers (lambda (status response-headers)
                               (setf (harness-bedrock--stream-status stream) status
                                     (harness-bedrock--stream-content-type stream)
                                     (cdr (assoc "content-type" response-headers))))
                 :on-chunk (lambda (chunk) (harness-bedrock--on-chunk stream decoder chunk))
                 :callback (lambda (status response-headers body err)
                             (harness-bedrock--on-done
                              stream (or status (harness-bedrock--stream-status stream))
                              response-headers body err)))))
      (error (harness-bedrock--finish stream 'error (harness-error-message err))))))

(defun harness-bedrock--on-done (stream status headers body err)
  "Handle the end of an attempt of STREAM: STATUS, HEADERS, BODY and transport ERR."
  (unless (harness-bedrock--stream-finished stream)
    (let ((raw (concat (harness-bedrock--stream-raw stream) (or body ""))))
      (cond
       ((eq (car-safe err) 'cancelled) (harness-bedrock--finish stream 'cancelled))
       (err (let ((message (harness-error-message (cadr err))))
              (unless (harness-bedrock--maybe-retry stream nil nil message)
                (harness-bedrock--finish stream 'error message))))
       ((or (null status) (< status 200) (>= status 300))
        (harness-bedrock--http-error stream status headers raw))
       ((harness-bedrock--event-stream-p stream)
        (harness-bedrock--complete-response stream))
       (t
        (let ((json (ignore-errors (harness-json-parse (harness-bedrock--text raw)))))
          (if (and (listp json) (plist-get json :output))
              (progn (harness-bedrock--apply-response stream json)
                     (harness-bedrock--complete-response stream))
            (harness-bedrock--finish
             stream 'error (format "unexpected response: %s" (harness-bedrock--error-text raw))))))))))

(defun harness-bedrock--start (stream)
  "Resolve the keys of STREAM's endpoint, then send its request."
  (harness-then (harness-bedrock--auth (harness-bedrock--stream-endpoint stream))
                (lambda (auth)
                  (unless (harness-bedrock--stream-finished stream)
                    (setf (harness-bedrock--stream-auth stream) auth)
                    (harness-bedrock--attempt stream))
                  nil)
                (lambda (err)
                  (harness-bedrock--finish stream 'error (harness-bedrock--describe-error err))
                  nil)))

(defun harness-bedrock--complete (endpoint request)
  "Start a ConverseStream completion for REQUEST at ENDPOINT; return a handle."
  (pcase-let* ((`(,_ . ,name) (harness-provider-parse-model (plist-get request :model)))
               (stream (make-harness-bedrock--stream
                        :on-event (or (plist-get request :on-event) #'ignore)
                        :endpoint endpoint :name name :request request)))
    (harness-bedrock--emit stream '(:type start))
    (condition-case err
        (progn
          (setf (harness-bedrock--stream-info stream) (harness-bedrock--model-info endpoint name)
                (harness-bedrock--stream-region stream) (harness-bedrock--region endpoint)
                (harness-bedrock--stream-options stream)
                (copy-sequence (gethash (harness-bedrock--quirk-key stream) harness-bedrock--quirks)))
          (harness-bedrock--start stream))
      (error (harness-bedrock--finish stream 'error (harness-error-message err))))
    (list :cancel (lambda ()
                    (unless (harness-bedrock--stream-finished stream)
                      (when-let* ((http (harness-bedrock--stream-http stream)))
                        (harness-http-cancel http))
                      (harness-bedrock--finish stream 'cancelled))))))

;;;; Registration

(defun harness-bedrock--register (endpoint)
  "Register the provider described by ENDPOINT."
  (let ((id (plist-get endpoint :id)))
    (harness-define-provider id
      :label (or (plist-get endpoint :label) (symbol-name id))
      :doc (format "AWS Bedrock Converse API at %s"
                   (or (ignore-errors (harness-bedrock--runtime-url endpoint)) "?"))
      :models (lambda (&optional refresh) (harness-bedrock--models (harness-bedrock-endpoint id) refresh))
      :resolve (lambda (name) (harness-bedrock--model-info (harness-bedrock-endpoint id) name))
      :complete (lambda (request) (harness-bedrock--complete (harness-bedrock-endpoint id) request))
      :capabilities (or (plist-get endpoint :capabilities) '(:vision t :thinking t))
      :tiers (or (plist-get endpoint :tiers) harness-bedrock-tiers))
    id))

(defvar harness-bedrock--registered-entries (make-hash-table :test 'eq)
  "Endpoint id -> the entry of `harness-bedrock-endpoints' it was registered from.")

(defun harness-bedrock--forget-endpoint (id)
  "Forget what was learnt about endpoint ID: its models, quirks and kept keys.
So an endpoint set up anew, with another gateway URL or other models
say, is asked again rather than answered from its old setup."
  (remhash id harness-bedrock--models-cache)
  (let ((prefix (format "%s/" id)))
    (dolist (table (list harness-bedrock--quirks harness-bedrock--kept-keys))
      (let (stale)
        (maphash (lambda (key _) (when (and (stringp key) (string-prefix-p prefix key)) (push key stale)))
                 table)
        (dolist (key stale) (remhash key table))))))

(defun harness-bedrock--register-all ()
  "Register a provider for every endpoint; drop providers of removed ones.
What was learnt about an endpoint whose entry changed, or that is gone,
is forgotten (see `harness-bedrock--forget-endpoint')."
  (let ((ids nil))
    (dolist (endpoint harness-bedrock-endpoints)
      (let ((id (plist-get endpoint :id)))
        (cond
         ((not (and id (symbolp id)))
          (harness-log 'warn "bedrock: ignoring endpoint without :id: %S"
                       (harness-plist-remove endpoint :headers :credentials)))
         ((not (string-match-p "\\`[a-z0-9_-]+\\'" (symbol-name id)))
          (harness-log 'warn "bedrock: endpoint id %s must be lower-case letters, digits, - or _" id))
         ((and (harness-provider-get id) (not (memq id harness-bedrock--registered)))
          (harness-log 'warn "bedrock: endpoint id %s is already another provider's" id))
         (t
          (unless (equal (gethash id harness-bedrock--registered-entries) endpoint)
            (harness-bedrock--forget-endpoint id)
            (puthash id endpoint harness-bedrock--registered-entries))
          (push (harness-bedrock--register endpoint) ids)))))
    (dolist (old harness-bedrock--registered)
      (unless (memq old ids)
        (harness-provider-unregister old)
        (harness-bedrock--forget-endpoint old)
        (remhash old harness-bedrock--registered-entries)))
    (setq harness-bedrock--registered ids)))

(harness-bedrock--register-all)

(harness-define-module 'provider-bedrock
  :doc "AWS Bedrock provider: the Converse API, signed with SigV4 or an API key."
  :requires '(provider)
  :init #'harness-bedrock--register-all)

(provide 'harness-provider-bedrock)
;;; harness-provider-bedrock.el ends here
