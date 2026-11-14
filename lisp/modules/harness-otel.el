;;; harness-otel.el --- Opt-in OpenTelemetry export of model and tool calls  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; A small, opt-in exporter of what sessions do -- their turns, their model
;; requests and their tool calls -- to an OpenTelemetry collector the user
;; runs, over OTLP/HTTP with JSON bodies.  It is off until it is turned on
;; twice, in its own way: `harness-otel-enabled' and `harness-otel-endpoint'
;; must both be set.  Loading the harness, starting it, or running its
;; tests therefore sends nothing anywhere.
;;
;; What it exports is one trace per turn, with a client inference span for
;; each model request of the turn and an internal span for each tool the
;; turn runs, plus the inference duration histogram and the input and output
;; token counters.  The conventions are the GenAI client inference ones of
;; `open-telemetry/semantic-conventions-genai', pinned to the revision named
;; in docs/otel.md: they are Development there, and they move.  Their names
;; are used as they stand where they fit; what they have no place for --
;; which session, which turn, how many attempts a step took -- is the
;; harness's own, under a `harness.' prefix, on spans only, never on a
;; metric dimension.
;;
;; Privacy.  Nothing a model or a tool says is exported: not a prompt, not
;; an answer, not a tool's arguments or output, not a path, not an account.
;; A span says what the operation was and how it ended; a failure carries
;; `error.type', a low-cardinality kind the harness names, and never the
;; provider's error text, which can hold a whole prompt.  The content
;; attributes the conventions mark Opt-In (`gen_ai.input.messages' and its
;; kin) are not written at all: this version has no switch for them.
;;
;; Reliability.  Exporting happens on a timer, off the event that announced
;; the work, from a queue with a bound: a collector that is slow,
;; unreachable or wrong never makes a turn wait, never raises into one, and
;; its failures are counted and logged once.  Shutting the module down stops
;; collecting and sends what is queued, once; after that it sends nothing.
;;
;; The exporter is OTLP/HTTP JSON -- the resourceSpans/resourceMetrics
;; shape, `Content-Type: application/json' -- which needs no library the
;; harness does not already have: `harness-http' posts it.  Spans go to
;; `<endpoint>/v1/traces' and metrics to `<endpoint>/v1/metrics'.
;;
;; docs/otel.md is the design and the setup: the revision adopted and what
;; an upgrade would change, every name emitted and every one deliberately
;; not, the token rules across providers, the privacy and reliability
;; promises.  demo/otel-export/ runs one real turn against a stand-in
;; collector on this machine, for trying it without one to install.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)
(require 'harness-provider)

;;;; Settings

(defcustom harness-otel-enabled nil
  "Export OpenTelemetry telemetry of sessions' turns, model requests and tools.
Nil, the default, exports nothing, whatever the endpoint says: the
module collects nothing and starts no timer.  Non-nil exports to the
collector `harness-otel-endpoint' names, and it takes both this and an
endpoint to send anything at all.

The module itself is not one the harness starts unless it is asked for
\(see `harness-enabled-modules'); the harness's own tests never load it.
What is exported, and in which shape, is in docs/otel.md.  Nothing a
model or a tool says is exported: no prompt, no answer, no argument, no
output, no path, no account."
  :type 'boolean :group 'harness)

(defcustom harness-otel-endpoint nil
  "Base URL of the OpenTelemetry collector, such as \"http://localhost:4318\".
Nil, the default, exports nothing, whatever `harness-otel-enabled' says.
The OTLP/HTTP signal paths are appended to it: `/v1/traces' and
`/v1/metrics'.  A URL that already ends in one of them is used for that
signal as it stands, so a gateway with its own paths can be given the
full address.

Only http and https are used.  A URL the exporter will not use is logged
once, and nothing is sent."
  :type '(choice (const :tag "No collector" nil)
                 (string :tag "Collector URL"))
  :group 'harness)

(defcustom harness-otel-headers nil
  "Headers every OTLP request carries, an alist of (NAME . VALUE).
For a collector behind an authenticating proxy: ((\"Authorization\" .
\"Bearer ...\")).  They are never logged, and never exported.

The OTLP specification's `OTEL_EXPORTER_OTLP_HEADERS' -- a
comma-separated list of `name=value' pairs -- is read when this is nil."
  :type '(alist :key-type string :value-type string) :group 'harness)

(defcustom harness-otel-service-name "emacs-agent-harness"
  "The `service.name' of the resource every exported signal carries.
It is how a collector, and the backend behind it, tells this harness's
telemetry from another's."
  :type 'string :group 'harness)

(defcustom harness-otel-export-interval 15
  "Seconds between exports of what the module has collected.
Each export sends the spans and metrics gathered since the one before,
so a collector receives each signal once.  A shutdown sends what is left
at once."
  :type 'number :group 'harness)

(defcustom harness-otel-max-queue 1024
  "Most items the exporter keeps while it has not sent them.
A span and a metric record are one item each.  Once the queue is full
the oldest items are dropped and counted (`otel/status'); the queue never
grows, so a harness left running with no collector in reach sets no more
memory aside for telemetry than this."
  :type 'integer :group 'harness)

(defcustom harness-otel-timeout 10
  "Seconds one OTLP request may take before it is given up on.
A slow collector therefore costs a request's wait at most, and no turn
waits for one: an export never runs on a turn's behalf."
  :type 'number :group 'harness)

(defconst harness-otel--queue-limit-floor 16
  "Least the export queue holds, whatever `harness-otel-max-queue' says.")

;;;; The conventions this module follows
;;
;; Pinned to open-telemetry/semantic-conventions-genai, commit
;; e6658f14c9d9ea0760825f029cb82e7673f48fab (2026-11-06), the head of
;; `main' when this was written.  The repository publishes no releases yet,
;; so a commit is what there is to pin.  These conventions are Development
;; and will move: docs/otel.md names each of the names below with its
;; source, says what an upgrade would change, and says why the older
;; semantic-conventions v1.x spellings are not used at all:
;;
;; - `gen_ai.client.operation.duration' and `gen_ai.client.token.usage',
;;   with `gen_ai.token.type' and `gen_ai.system', are superseded by the
;;   client inference names below, and are not emitted;
;; - nothing is emitted with `gen_ai.system'.

(defconst harness-otel--operation-inference "chat"
  "`gen_ai.operation.name' of a model request.
`chat' is the well-known value for a chat completion, which is what
every provider of the harness makes, hosted loops and API calls alike.")

(defconst harness-otel--span-inference "gen_ai.client.inference"
  "Span type of a model request (docs/gen-ai/client-inference.md).")

(defconst harness-otel--span-agent "gen_ai.invoke_agent"
  "Span type of a turn (docs/gen-ai/gen-ai-agent-spans.md).")

(defconst harness-otel--span-tool "gen_ai.execute_tool"
  "Span type of a tool call (docs/gen-ai/execute-tool.md).")

(defconst harness-otel--metric-duration "gen_ai.client.inference.duration"
  "Histogram of a model request's duration, in seconds.")

(defconst harness-otel--metric-input-tokens
  "gen_ai.client.inference.usage.input_tokens"
  "Counter of the input tokens of model requests.
The count includes the tokens the provider served from its cache, as
docs/gen-ai/gen-ai-token-metrics.md requires.")

(defconst harness-otel--metric-output-tokens
  "gen_ai.client.inference.usage.output_tokens"
  "Counter of the output tokens of model requests.")

(defconst harness-otel--duration-buckets
  [0.01 0.02 0.04 0.08 0.16 0.32 0.64 1.28 2.56 5.12 10.24 20.48 40.96 81.92]
  "Explicit bucket boundaries the inference duration convention names, in seconds.")

(defconst harness-otel--provider-names
  '((claude . "anthropic")
    (chatgpt . "openai")
    (openai . "openai")
    (deepseek . "deepseek")
    (bedrock . "aws.bedrock")
    (copilot . "github.copilot")
    (demo . "harness.demo")
    (gremlin . "harness.gremlin"))
  "Harness provider id -> `gen_ai.provider.name'.
A provider the registry has a well-known value for is mapped to it
\(`anthropic', `openai', `deepseek', `aws.bedrock'); one it has none for
gets a dot-namespaced name of this harness's own, which the convention
allows when no well-known value applies.")

(defconst harness-otel--error-types
  '(rate-limit quota billing auth transport process timeout error denied tool-error)
  "The `error.type' values this module reports, and no others.
The conventions want a low-cardinality class, not the provider's error
text: a provider's own kind is mapped to one of these, and one that is
none of them becomes `error'.")

;;;; State

(cl-defstruct (harness-otel--span (:copier nil))
  "A span the module is building or has finished.
TRACE-ID and SPAN-ID are the 32- and 16-hex-digit ids W3C trace context
has; PARENT is the parent span's id, or nil for a root.  START is the
`current-time' the span began, END when it ended.  ATTRIBUTES is an alist
of string keys to values, STATUS a plist of `:code' and `:message',
SESSION the session whose turn opened it."
  name trace-id span-id parent start end attributes status kind session)

(cl-defstruct (harness-otel--metric (:copier nil))
  "A metric record waiting to be exported.
NAME is the instrument's name, VALUE its number, ATTRIBUTES an alist of
labels, KIND `histogram' or `counter', UNIT its unit as the convention
spells it, and TIME when it was recorded."
  name value attributes kind unit time)

(defvar harness-otel--queue nil
  "Items waiting to be exported, oldest last.
Each is a `harness-otel--span' or a `harness-otel--metric'.")

(defvar harness-otel--dropped 0
  "How many items were dropped because the queue was full.")

(defvar harness-otel--sent 0
  "How many OTLP requests succeeded.")

(defvar harness-otel--failed 0
  "How many OTLP requests failed, at the transport or with a status.")

(defvar harness-otel--timer nil
  "The timer that exports the queue, or nil when nothing is being collected.")

(defvar harness-otel--inflight 0
  "How many OTLP requests are on the wire now.")

(defvar harness-otel--stopped nil
  "Non-nil once the module shut down, until it starts again.
A handler called after that -- a closure an event still held -- collects
nothing: shutting down is final until the module starts.")

(defvar harness-otel--warned nil
  "Non-nil once the exporter has said what is wrong with it.
An endpoint it will not use, or a request it cannot make, is logged once
rather than at every export; the counters say how often it happened.")

(defvar harness-otel--spans (make-hash-table :test 'equal)
  "Key -> `harness-otel--span' for a span still open.
The keys are the module's own: `turn/SESSION', `request/SESSION' and
`tool/CALL-ID'.")

(defvar harness-otel--open-by-session (make-hash-table :test 'equal)
  "Session id -> the span keys its running turn opened.
A turn that ends with a call still running -- a cancellation, say -- has
no end event for it: these are closed with the turn.")

(defvar harness-otel--tree (make-hash-table :test 'equal)
  "Session id -> (TRACE-ID . SPAN-ID) of its running turn.")

(defvar harness-otel--turn-info (make-hash-table :test 'equal)
  "Session id -> what its running turn has done so far.
`:requests', how many model requests it made.  The harness's own count,
never a token reading.")

;;;; Identifiers

(defun harness-otel--random-hex (digits)
  "Return DIGITS random lowercase hexadecimal digits.
The ids a trace context needs are odds in a huge space, not secrets: the
generator `random' already uses, seeded by Emacs, is enough here, and
this asks no network or filesystem for entropy."
  (let ((chars "0123456789abcdef") (out ""))
    (dotimes (_ digits out)
      (setq out (concat out (string (aref chars (random 16))))))))

(defun harness-otel--new-trace-id ()
  "Return a new 32-hex-digit trace id, never all zeros."
  (let ((id (harness-otel--random-hex 32)))
    (if (string-match-p "\\`0+\\'" id) (harness-otel--new-trace-id) id)))

(defun harness-otel--new-span-id ()
  "Return a new 16-hex-digit span id, never all zeros."
  (let ((id (harness-otel--random-hex 16)))
    (if (string-match-p "\\`0+\\'" id) (harness-otel--new-span-id) id)))

(defun harness-otel--nanos (&optional time)
  "Return TIME, or now, in nanoseconds since the epoch, as a string.
OTLP takes a 64-bit unsigned count and Emacs's time is exact to the
nanosecond, so the value is exact.  It is a string because the JSON
encoding of a 64-bit integer in OTLP is a string: a JSON number is a
double, which loses the last digits of these."
  (let* ((cell (time-convert (or time (current-time)) t)))
    (format "%d" (+ (* (/ (car cell) (cdr cell)) 1000000000)
                    (/ (* (% (car cell) (cdr cell)) 1000000000) (cdr cell))))))

;;;; Attribute values
;;
;; OTLP JSON spells a typed value as a one-key object: a string is
;; {"stringValue": "..."}, an integer {"intValue": "42"} (a string, for the
;; same reason the timestamps are), a double {"doubleValue": 0.5} and a
;; boolean {"boolValue": true}.  Attributes are an alist of string keys, so
;; that two attributes with the same name merge by `assoc' and never by
;; identity: two strings with the same characters are not `eq'.

(defun harness-otel--text (value)
  "Return VALUE as a string fit for an attribute, or nil.
Nil stays nil; a symbol becomes its name; a number its printed form.
Anything else is dropped rather than formatted: no error object's text
can reach a collector through a slot the caller meant to describe."
  (cond ((null value) nil)
        ((stringp value) value)
        ((eq value t) "true")
        ((symbolp value) (symbol-name value))
        ((numberp value) (number-to-string value))
        (t nil)))

(defun harness-otel--attribute (key value)
  "Return the OTLP JSON attribute of KEY with VALUE, or nil for no value."
  (when (and key value)
    (list :key key
          :value (cond ((stringp value) (list :stringValue value))
                       ((eq value t) (list :boolValue t))
                       ((integerp value) (list :intValue (number-to-string value)))
                       ((numberp value) (list :doubleValue (float value)))
                       (t (list :stringValue (format "%s" value)))))))

(defun harness-otel--attributes (alist)
  "Return ALIST as an OTLP JSON attributes array.
A pair whose value is nil is left out: an attribute that is not known is
absent, which is not the same as empty."
  (apply #'vector
         (delq nil (mapcar (lambda (cell) (harness-otel--attribute (car cell) (cdr cell)))
                           alist))))

(defun harness-otel--attrs (&rest pairs)
  "Return PAIRS, flat KEY VALUE KEY VALUE, as an attribute alist.
A KEY is a string, or a symbol whose name is used; a pair whose VALUE is
nil leaves the attribute out, since an attribute that is not known is
absent rather than empty."
  (let (out)
    (cl-loop for (key value) on pairs by #'cddr
             for name = (if (stringp key) key (and key (symbol-name key)))
             when (and name value)
             do (push (cons name value) out))
    (nreverse out)))

(defun harness-otel--merge-attrs (&rest alists)
  "Merge ALISTS of attributes left to right; a later value wins.
Nil values are dropped, so a call can say that an attribute is not known
this time without saying it twice."
  (let (out)
    (dolist (alist alists)
      (dolist (cell alist)
        (when (and (car cell) (cdr cell))
          (setf (alist-get (car cell) out nil nil #'equal) (cdr cell)))))
    (nreverse out)))

;;;; Provider and model names

(defun harness-otel--provider (model)
  "Return `gen_ai.provider.name' for MODEL, a \"provider:name\" id.
The registry's name for the provider when it has one, else a
harness-namespaced name; nil when MODEL names no provider."
  (when-let* ((provider (car (harness-provider-parse-model model))))
    (or (cdr (assq provider harness-otel--provider-names))
        (format "harness.%s" provider))))

(defun harness-otel--request-model (model)
  "Return what `gen_ai.request.model' should say for MODEL, or nil.
The harness names a model `provider:name'; a collector wants the vendor's
name, which is the part after the colon, the vendor being in
`gen_ai.provider.name'."
  (let ((name (cdr (harness-provider-parse-model model))))
    (and (stringp name) (not (string-empty-p name)) name)))

(defun harness-otel--error-type (kind)
  "Return the `error.type' of failure KIND, a bounded name.
A kind outside `harness-otel--error-types' is reported as `error', so a
provider's own word can never split a metric's dimension."
  (let ((kind (if (stringp kind) (intern kind) kind)))
    (symbol-name (if (memq kind harness-otel--error-types) kind 'error))))

;;;; Spans

(defun harness-otel--collecting-p ()
  "Non-nil when the module is on, running, and has a collector to export to."
  (and harness-otel-enabled harness-otel-endpoint (not harness-otel--stopped) t))

(defun harness-otel--open-span (key name &rest args)
  "Open the span KEY names, called NAME, under ARGS; return it, or nil.
KEY is the symbol the span is found by when it ends.  ARGS are `:kind'
\(`client' or `internal'), `:trace-id' and `:parent' (the ids to hang the
span under; a trace of its own when the trace id is nil), `:attributes'
\(an alist) and `:session'.  A span whose key is open already is returned
as it is, so a repeated call never opens two.  Return nil when nothing is
being collected: the caller need not ask."
  (when (harness-otel--collecting-p)
    (or (gethash key harness-otel--spans)
        (let* ((trace-id (or (plist-get args :trace-id) (harness-otel--new-trace-id)))
               (span (make-harness-otel--span
                      :name name
                      :trace-id trace-id
                      :span-id (harness-otel--new-span-id)
                      :parent (plist-get args :parent)
                      :kind (or (plist-get args :kind) "internal")
                      :start (current-time)
                      :session (plist-get args :session)
                      :attributes (plist-get args :attributes))))
          (puthash key span harness-otel--spans)
          (when-let* ((session (harness-otel--span-session span)))
            (setf (gethash session harness-otel--open-by-session)
                  (cons key (gethash session harness-otel--open-by-session))))
          span))))

(defun harness-otel--end-span (key &optional extra status)
  "End the span KEY names with EXTRA attributes and STATUS; return it, or nil.
EXTRA is an attribute alist merged into the span's.  STATUS is nil for a
span that ended as it should, else (KIND . MESSAGE): KIND is `error' or
`ok', and MESSAGE is a short word, never a provider's error text.  The
span is queued for the next export and its key forgotten."
  (when-let* ((span (gethash key harness-otel--spans)))
    (remhash key harness-otel--spans)
    (when-let* ((session (harness-otel--span-session span)))
      (setf (gethash session harness-otel--open-by-session)
            (delq key (gethash session harness-otel--open-by-session))))
    (setf (harness-otel--span-end span) (current-time)
          (harness-otel--span-attributes span)
          (harness-otel--merge-attrs (harness-otel--span-attributes span) extra))
    (when status
      (setf (harness-otel--span-status span)
            (list :code (if (eq (car status) 'error) 2 1)
                  :message (cdr status))))
    (harness-otel--enqueue span)
    span))

(defun harness-otel--span-otlp (span)
  "Return SPAN as the OTLP JSON object the exporter sends."
  (list :traceId (harness-otel--span-trace-id span)
        :spanId (harness-otel--span-span-id span)
        :parentSpanId (or (harness-otel--span-parent span) "")
        :name (harness-otel--span-name span)
        :kind (if (equal (harness-otel--span-kind span) "client") 3 1)
        :startTimeUnixNano (harness-otel--nanos (harness-otel--span-start span))
        :endTimeUnixNano (harness-otel--nanos
                          (or (harness-otel--span-end span) (current-time)))
        :attributes (harness-otel--attributes (harness-otel--span-attributes span))
        :status (or (harness-otel--span-status span) (list :code 0))
        :droppedAttributesCount 0))

;;;; Metrics

(defun harness-otel--enqueue (item)
  "Add ITEM to the export queue, dropping the oldest while it is full."
  (let ((limit (max harness-otel--queue-limit-floor (or harness-otel-max-queue 0))))
    (push item harness-otel--queue)
    (while (> (length harness-otel--queue) limit)
      (setq harness-otel--queue (butlast harness-otel--queue))
      (cl-incf harness-otel--dropped))))

(defun harness-otel--record (metric)
  "Queue METRIC, a `harness-otel--metric', when something is collected."
  (when (harness-otel--collecting-p)
    (harness-otel--enqueue metric)))

(defun harness-otel--counter (name value attributes &optional unit)
  "Record VALUE, an integer, as counter NAME with ATTRIBUTES and UNIT.
A value that is not a positive integer records nothing: the convention's
counters are sums of known contributions, so a missing reading stays
missing, and is never made a zero that would read as one."
  (when (and (integerp value) (> value 0))
    (harness-otel--record (make-harness-otel--metric
                           :name name :value value :attributes attributes
                           :kind 'counter :unit (or unit "{token}")
                           :time (current-time)))))

(defun harness-otel--histogram (name value attributes &optional unit)
  "Record VALUE, a number in UNIT, as histogram NAME with ATTRIBUTES."
  (when (and (numberp value) (>= value 0))
    (harness-otel--record (make-harness-otel--metric
                           :name name :value (float value) :attributes attributes
                           :kind 'histogram :unit (or unit "s")
                           :time (current-time)))))

(defun harness-otel--bucket (value bounds)
  "Return the index in BOUNDS of the bucket VALUE falls in.
BOUNDS is a vector of ascending numbers.  A bucket counts the values in
\(BOUNDS[i-1], BOUNDS[i]], so the result is the length of BOUNDS for a
value above them all, as an OTLP histogram has one more bucket than it
has explicit bounds."
  (let ((i 0) (n (length bounds)))
    (while (and (< i n) (> value (aref bounds i)))
      (cl-incf i))
    i))

(defun harness-otel--metric-otlp (metric)
  "Return METRIC as the OTLP JSON instrument the exporter sends.
Each record is one data point of its instrument, so the sum and the
histogram say exactly what that record said: a counter's `asInt' is its
value, and a histogram's count is 1 with its value in the one bucket the
value falls in.  Both are DELTA, which is what one export carries: only
what happened since the export before."
  (let ((attributes (harness-otel--attributes
                     (harness-otel--metric-attributes metric)))
        (start (harness-otel--nanos (harness-otel--metric-time metric)))
        (time (harness-otel--nanos (harness-otel--metric-time metric))))
    (pcase (harness-otel--metric-kind metric)
      ('counter
       (list :name (harness-otel--metric-name metric)
             :unit (harness-otel--metric-unit metric)
             :sum (list :dataPoints
                        (vector (list :attributes attributes
                                      :startTimeUnixNano start
                                      :timeUnixNano time
                                      :asInt (number-to-string
                                              (harness-otel--metric-value metric))))
                        :aggregationTemporality 1
                        :isMonotonic t)))
      (_
       (let* ((value (harness-otel--metric-value metric))
              (bounds harness-otel--duration-buckets)
              (index (harness-otel--bucket value bounds))
              (counts (make-vector (1+ (length bounds)) 0)))
         (aset counts index 1)
         (list :name (harness-otel--metric-name metric)
               :unit (harness-otel--metric-unit metric)
               :histogram (list :dataPoints
                                (vector (list :attributes attributes
                                              :startTimeUnixNano start
                                              :timeUnixNano time
                                              :count 1
                                              :sum value
                                              :bucketCounts (apply #'vector (append counts nil))
                                              :explicitBounds bounds
                                              :min value
                                              :max value))
                                :aggregationTemporality 1)))))))

;;;; OTLP bodies

(defun harness-otel--version ()
  "Return the harness's version, as the resource reports it."
  (if (bound-and-true-p harness-version) harness-version "unknown"))

(defun harness-otel--resource ()
  "Return the OTLP resource, a plist, shared by spans and metrics.
`telemetry.sdk.name' is this harness's identifier, not `opentelemetry',
which that attribute reserves for OpenTelemetry SDKs: a plain exporter is
none, and says so.  `telemetry.sdk.language' is `elisp', a value the
registry has none for, which it allows."
  (list :attributes
        (harness-otel--attributes
         (list (cons "service.name" harness-otel-service-name)
               (cons "service.version" (harness-otel--version))
               (cons "telemetry.sdk.name" "emacs-agent-harness")
               (cons "telemetry.sdk.language" "elisp")))))

(defun harness-otel--scope ()
  "Return the instrumentation scope of every signal."
  (list :name "harness-otel" :version (harness-otel--version)))

(defun harness-otel--traces-body (spans)
  "Return the OTLP/HTTP JSON body that exports SPANS."
  (list :resourceSpans
        (vector (list :resource (harness-otel--resource)
                      :scopeSpans
                      (vector (list :scope (harness-otel--scope)
                                    :spans (apply #'vector
                                                  (mapcar #'harness-otel--span-otlp spans))))))))

(defun harness-otel--metrics-body (metrics)
  "Return the OTLP/HTTP JSON body that exports METRICS."
  (list :resourceMetrics
        (vector (list :resource (harness-otel--resource)
                      :scopeMetrics
                      (vector (list :scope (harness-otel--scope)
                                    :metrics (apply #'vector
                                                    (mapcar #'harness-otel--metric-otlp
                                                            metrics))))))))

;;;; The collector

(defun harness-otel--base-url ()
  "Return the collector's base URL without a trailing slash, or nil."
  (when (stringp harness-otel-endpoint)
    (let ((url (string-trim harness-otel-endpoint)))
      (unless (string-empty-p url)
        (string-remove-suffix "/" url)))))

(defun harness-otel--url (signal)
  "Return the URL SIGNAL (`traces' or `metrics') is sent to, or nil.
A base URL that ends in the signal's own path is used as it stands."
  (when-let* ((base (harness-otel--base-url)))
    (if (string-match-p (format "/v1/%s\\'" (regexp-quote signal)) base)
        base
      (concat base "/v1/" signal))))

(defun harness-otel--usable-url-p (url)
  "Non-nil when URL is one this exporter may post telemetry to.
It must be http or https with a host that could work, and curl, which the
HTTP layer runs, must be there."
  (and (stringp url)
       (string-match-p "\\`https?://" url)
       (harness-http-link-p url)
       (executable-find "curl")))

(defun harness-otel--headers ()
  "Return the HTTP headers every OTLP request carries."
  (append '(("Content-Type" . "application/json"))
          (or (and harness-otel-headers (copy-sequence harness-otel-headers))
              (harness-otel--headers-from-environment))))

(defun harness-otel--headers-from-environment ()
  "Return `OTEL_EXPORTER_OTLP_HEADERS' as an alist, or nil.
The specification's form is \"name=value,name=value\"."
  (when-let* ((text (getenv "OTEL_EXPORTER_OTLP_HEADERS")))
    (delq nil
          (mapcar (lambda (pair)
                    (let ((eq (string-match "=" pair)))
                      (when eq
                        (cons (string-trim (substring pair 0 eq))
                              (string-trim (substring pair (1+ eq)))))))
                  (split-string text "," t)))))

;;;; Export

(defun harness-otel--warn (format-string &rest args)
  "Log a warning once, with FORMAT-STRING and ARGS.
The exporter's own trouble must not fill the harness's log: one line says
what is wrong, and the counters say how often it went wrong after that."
  (unless harness-otel--warned
    (setq harness-otel--warned t)
    (apply #'harness-log 'warn (concat "otel: " format-string) args)))

(defun harness-otel--post (url body what)
  "Post BODY, an OTLP JSON body, to URL; return the request's handle.
WHAT names the signal for the log.  A request that cannot even start is
counted and logged once, and never raises into its caller."
  (condition-case err
      (progn
        (cl-incf harness-otel--inflight)
        (harness-http-request
         url
         :method "POST"
         :headers (harness-otel--headers)
         :json body
         :timeout harness-otel-timeout
         ;; A retry would send the same spans twice, and OTLP has no
         ;; deduplication: one try, and the next export carries on.
         :retry 0
         :callback (lambda (status _headers _body request-error)
                     (cl-decf harness-otel--inflight)
                     (cond
                      (request-error
                       (cl-incf harness-otel--failed)
                       (harness-otel--warn "exporting %s failed: %s" what (car request-error)))
                      ((not (and status (>= status 200) (< status 300)))
                       (cl-incf harness-otel--failed)
                       (harness-otel--warn "exporting %s was refused with HTTP %s" what status))
                      (t (cl-incf harness-otel--sent))))))
    (error
     (cl-decf harness-otel--inflight)
     (cl-incf harness-otel--failed)
     (harness-otel--warn "exporting %s failed: %s" what (harness-error-short-message err))
     nil)))

(defun harness-otel--flush ()
  "Send what the queue holds now, one request per signal.
Spans and metrics are taken from the queue first and each sent as one
OTLP request, so nothing is sent twice.  Nothing is sent when the module
is off, no endpoint can be used, or the queue is empty.  A failed request
is counted and logged, and what it carried is gone, as it would be in any
exporter whose queue is bounded; the next export carries on with what
comes after it."
  (when (harness-otel--collecting-p)
    (let* ((items (nreverse harness-otel--queue))
           (spans (cl-remove-if-not #'harness-otel--span-p items))
           (metrics (cl-remove-if-not #'harness-otel--metric-p items)))
      (setq harness-otel--queue nil)
      (when (or spans metrics)
        (let ((traces (and spans (harness-otel--url "traces")))
              (measurements (and metrics (harness-otel--url "metrics"))))
          (when spans
            (if (harness-otel--usable-url-p traces)
                (harness-otel--post traces (harness-otel--traces-body spans) "traces")
              (harness-otel--warn "no usable traces endpoint: %S" traces)))
          (when metrics
            (if (harness-otel--usable-url-p measurements)
                (harness-otel--post measurements (harness-otel--metrics-body metrics) "metrics")
              (harness-otel--warn "no usable metrics endpoint: %S" measurements)))
          t)))))

(defun harness-otel--export-now ()
  "Export what is queued; never raise out of a timer."
  (condition-case err
      (harness-otel--flush)
    (error (harness-log 'warn "otel: export failed: %s" (harness-error-short-message err)))))

;;;; Instrumentation: turns

(defun harness-otel--turn-attributes (session)
  "Return the attributes of the agent span of a turn of SESSION.
`gen_ai.agent.name' has to be low-cardinality: the agent is the harness,
so it says that, and never the session's name, which is the user's words.
A sub-agent's turn names the session that started it, and nothing else of
it.  The session id is a harness attribute on this span and on the request
and tool spans under it, and on no metric: a metric's dimensions must not
grow with use."
  (harness-otel--attrs
   "gen_ai.operation.name" "invoke_agent"
   "gen_ai.provider.name" (harness-otel--provider (plist-get session :model))
   "gen_ai.request.model" (harness-otel--request-model (plist-get session :model))
   "gen_ai.agent.name" "emacs-agent-harness"
   "gen_ai.conversation.id" (plist-get session :id)
   "harness.session.id" (plist-get session :id)
   "harness.session.kind" (harness-otel--text (plist-get session :kind))
   "harness.session.parent_id" (plist-get session :parent-id)))

(defun harness-otel--on-turn-started (session-id)
  "Open the agent span of SESSION-ID's turn, and remember its trace.
A turn another turn started -- a sub-agent's, whose parent is running --
hangs under the parent's turn span, in the parent's trace: one logical
operation, one trace."
  (when (harness-otel--collecting-p)
    (let* ((session (ignore-errors (harness-call 'session/get session-id)))
           (parent-turn (and (plist-get session :parent-id)
                             (gethash (plist-get session :parent-id) harness-otel--tree)))
           (span (harness-otel--open-span
                  (intern (format "turn/%s" session-id))
                  (concat harness-otel--span-agent " emacs-agent-harness")
                  :kind "internal"
                  :session session-id
                  :trace-id (car parent-turn)
                  :parent (cdr parent-turn)
                  :attributes (harness-otel--turn-attributes session))))
      (when span
        (puthash session-id (cons (harness-otel--span-trace-id span)
                                  (harness-otel--span-span-id span))
                 harness-otel--tree)
        (remhash session-id harness-otel--turn-info)))))

(defun harness-otel--on-turn-ended (session-id reason)
  "Close the agent span of SESSION-ID's turn, which ended for REASON.
A turn that failed carries `error.type' `error': its provider's kind
belongs to the step that failed, which reported it.  A cancellation is no
error, and says so in a harness attribute instead."
  (when (harness-otel--collecting-p)
    (let* ((key (intern (format "turn/%s" session-id)))
           (info (gethash session-id harness-otel--turn-info))
           (failed (eq reason 'error)))
      (when (gethash key harness-otel--spans)
        (harness-otel--end-span
         key
         (harness-otel--merge-attrs
          (harness-otel--attrs "harness.turn.stop_reason" (harness-otel--text reason)
                               "harness.turn.requests" (plist-get info :requests)
                               "harness.cancelled" (and (eq reason 'cancelled) t))
          (and failed (harness-otel--attrs "error.type" "error")))
         (and failed (cons 'error nil))))
      ;; A call the turn left running has no end of its own: it is closed
      ;; with the turn, as cancelled, so no span is kept for ever.
      (dolist (span-key (gethash session-id harness-otel--open-by-session))
        (harness-otel--end-span span-key
                                (harness-otel--attrs "harness.cancelled" t)
                                (cons 'ok nil)))
      (remhash session-id harness-otel--open-by-session)
      (remhash session-id harness-otel--turn-info)
      (remhash session-id harness-otel--tree)
      (harness-otel--ensure-timer))))

;;;; Instrumentation: model requests

(defun harness-otel--on-step-started (session-id step)
  "Open the inference span of SESSION-ID's next model request, the STEPth.
The span is named from the operation and the model that was requested, as
the convention has it.  A request made outside a turn -- the harness's own
small calls have none -- opens a trace of its own rather than dangling
under no parent.  A step tried again after a transient failure is the same
logical request: while its span is open it stays, and the retry adds to
it, so one operation is one span however many attempts it took."
  (when (harness-otel--collecting-p)
    (let* ((key (intern (format "request/%s" session-id)))
           (session (ignore-errors (harness-call 'session/get session-id)))
           (turn (gethash session-id harness-otel--tree))
           (model (plist-get session :model))
           (requested (harness-otel--request-model model)))
      (harness-otel--open-span
       key
       (concat harness-otel--operation-inference (if requested (concat " " requested) ""))
       :kind "client"
       :session session-id
       :trace-id (car turn)
       :parent (cdr turn)
       :attributes
       (harness-otel--attrs
        "gen_ai.operation.name" harness-otel--operation-inference
        "gen_ai.provider.name" (harness-otel--provider model)
        "gen_ai.request.model" requested
        "gen_ai.request.stream" t
        "harness.session.id" session-id
        "harness.step" (and (integerp step) (number-to-string step)))))))

(defun harness-otel--step-usage (info)
  "Return the token attributes of a step that ended with INFO.
INFO is `agent/step-ended', which carries this step's own counts, added up
over its attempts, and never a session total.  The input count includes
what the provider served from its cache, as the convention requires; the
cache reading is named apart as the subset it is, and is left out when
the provider gave none, rather than made zero."
  (let* ((cache-read (and (plist-get info :cache-read-known)
                          (plist-get info :cache-read)))
         (cache-write (plist-get info :cache-write))
         ;; The convention wants a cache attribute when its reading is
         ;; available and non-zero, so a zero stays absent: it says nothing
         ;; the absent attribute does not, and a zero on every request would
         ;; be noise in a backend's series.
         (count-text (lambda (n) (and (numberp n) (> n 0) (number-to-string n))))
         (input (or (plist-get info :context)
                    (and (or (numberp (plist-get info :input)) cache-read cache-write)
                         (+ (or (plist-get info :input) 0)
                            (or cache-read 0)
                            (or cache-write 0))))))
    (harness-otel--attrs
     "gen_ai.usage.input_tokens" (and input (number-to-string input))
     "gen_ai.usage.output_tokens" (let ((out (plist-get info :output)))
                                    (and (numberp out) (number-to-string out)))
     "gen_ai.usage.cache_read.input_tokens" (funcall count-text cache-read)
     "gen_ai.usage.cache_write.input_tokens" (funcall count-text cache-write)
     "harness.step.attempt" (let ((attempt (plist-get info :attempt)))
                              (and (integerp attempt) (number-to-string attempt))))))

(defun harness-otel--total-input (info)
  "Return the cache-inclusive input tokens of the step that ended with INFO.
The convention counts a prompt's tokens with those served from a cache,
and providers differ: some count the cached tokens in the input they
report, some apart.  The harness's `:context' is the whole prompt for
every provider, so it is used when the provider reported one; otherwise
the counts the provider split are added back together."
  (let* ((cache-read (and (plist-get info :cache-read-known)
                          (plist-get info :cache-read)))
         (cache-write (plist-get info :cache-write))
         (context (plist-get info :context)))
    (cond ((and (numberp context) (>= context 0)) context)
          ((or (numberp (plist-get info :input)) cache-read cache-write)
           (+ (or (plist-get info :input) 0) (or cache-read 0) (or cache-write 0)))
          (t nil))))

(defun harness-otel--metric-labels (info)
  "Return the labels of the metrics of a step that ended with INFO.
Only what the convention names, and only low-cardinality values: no
session, no turn, nothing that grows with use."
  (let ((model (plist-get info :model)))
    (harness-otel--attrs
     "gen_ai.operation.name" harness-otel--operation-inference
     "gen_ai.provider.name" (harness-otel--provider model)
     "gen_ai.request.model" (harness-otel--request-model model))))

(defun harness-otel--on-step-ended (session-id info)
  "Close SESSION-ID's open inference span with what INFO says of the step.
The information is the step's own: how long it took, what its provider
reported for it, and how it ended.  A failed step carries its failure's
kind as `error.type' and its status; a cancelled one is no error, and is
marked in a harness attribute instead.  The same counts go to the
convention's duration histogram and token counters."
  (when (harness-otel--collecting-p)
    (let* ((key (intern (format "request/%s" session-id)))
           (span (gethash key harness-otel--spans))
           (model (plist-get info :model))
           (requested (harness-otel--request-model model))
           (reason (plist-get info :reason))
           (failed (eq reason 'error))
           (kind (and failed (or (plist-get info :error-kind) 'error))))
      (when span
        ;; The step's own model is the surest source for both: a request
        ;; opened before its session was read has neither yet, and the
        ;; span is named from what was requested, as the convention has it.
        (when requested
          (setf (harness-otel--span-name span)
                (concat harness-otel--operation-inference " " requested)))
        (harness-otel--end-span
         key
         (harness-otel--merge-attrs
          (harness-otel--step-usage info)
          (and requested (harness-otel--attrs "gen_ai.request.model" requested))
          (harness-otel--attrs "harness.stop_reason" (harness-otel--text reason)
                               "harness.cancelled" (and (plist-get info :cancelled) t))
          (and kind (harness-otel--attrs "error.type" (harness-otel--error-type kind))))
         (and failed (cons 'error nil))))
      (let ((labels (harness-otel--metric-labels info)))
        (harness-otel--histogram harness-otel--metric-duration
                                 (plist-get info :duration) labels "s")
        ;; The convention counts what failed too, when its provider said
        ;; what it used; a step with no reading has none, and nothing is
        ;; invented for it.
        (harness-otel--counter harness-otel--metric-input-tokens
                               (harness-otel--total-input info)
                               (append labels (harness-otel--attrs
                                               "gen_ai.token.modality" "unknown")))
        (harness-otel--counter harness-otel--metric-output-tokens
                               (let ((out (plist-get info :output)))
                                 (and (integerp out) out))
                               (append labels (harness-otel--attrs
                                               "gen_ai.token.modality" "unknown"))))
      ;; The turn's own count of requests, which it reports when it ends.
      (when (gethash session-id harness-otel--tree)
        (let ((info (gethash session-id harness-otel--turn-info)))
          (setf (gethash session-id harness-otel--turn-info)
                (plist-put info :requests (1+ (or (plist-get info :requests) 0))))))
      (harness-otel--ensure-timer))))

;;;; Instrumentation: tools

(defun harness-otel--on-tool-started (session-id call)
  "Open a tool span for CALL of SESSION-ID, under its turn's span.
Only the call's id and the tool's name are read: its arguments are not,
and could hold anything."
  (when (harness-otel--collecting-p)
    (let* ((call-id (harness-otel--text (plist-get call :id)))
           (name (harness-otel--text (plist-get call :name)))
           (turn (gethash session-id harness-otel--tree)))
      (when (and call-id name)
        (harness-otel--open-span
         (intern (format "tool/%s" call-id))
         (concat harness-otel--span-tool " " name)
         :kind "internal"
         :session session-id
         :trace-id (car turn)
         :parent (cdr turn)
         :attributes (harness-otel--attrs
                      "gen_ai.operation.name" "execute_tool"
                      "gen_ai.tool.name" name
                      "gen_ai.tool.call.id" call-id
                      "harness.session.id" session-id))))))

(defun harness-otel--on-tool-finished (session-id call result)
  "Close the tool span of CALL of SESSION-ID, which ended with RESULT.
RESULT's `:is-error' and `:denied' are read.  Its content, the tool's
output, is not: it can hold a file, a credential, or whatever the user
asked the tool to find."
  (when (harness-otel--collecting-p)
    (let* ((call-id (harness-otel--text (plist-get call :id)))
           (key (and call-id (intern (format "tool/%s" call-id))))
           (denied (plist-get result :denied))
           (failed (and (or (plist-get result :is-error) denied) t)))
      (when (and key (gethash key harness-otel--spans))
        (harness-otel--end-span
         key
         (harness-otel--merge-attrs
          (and denied (harness-otel--attrs "harness.tool.denied" t))
          (and failed (harness-otel--attrs
                       "error.type" (if denied "denied" "tool-error"))))
         (and failed
              (cons 'error (if denied "denied" "tool-error"))))
        (harness-otel--ensure-timer)))
    (ignore session-id)))

;;;; The timer

(defun harness-otel--ensure-timer ()
  "Start the export timer when it does not run, and something is collected."
  (when (and (harness-otel--collecting-p) (null harness-otel--timer))
    (let ((seconds (max 0.05 (or harness-otel-export-interval 15))))
      (setq harness-otel--timer (run-at-time seconds seconds #'harness-otel--export-now)))))

(defun harness-otel--stop-timer ()
  "Stop the export timer, when one runs."
  (when harness-otel--timer
    (cancel-timer harness-otel--timer)
    (setq harness-otel--timer nil)))

;;;; Module

(defun harness-otel--reset ()
  "Forget everything the exporter holds.
Used when the module starts and stops, and by tests that want a clean
exporter without reloading the module."
  (harness-otel--stop-timer)
  (setq harness-otel--queue nil
        harness-otel--dropped 0
        harness-otel--sent 0
        harness-otel--failed 0
        harness-otel--inflight 0
        harness-otel--warned nil
        harness-otel--stopped nil)
  (clrhash harness-otel--spans)
  (clrhash harness-otel--open-by-session)
  (clrhash harness-otel--tree)
  (clrhash harness-otel--turn-info))

(harness-defmethod otel/status ()
  "Return what the exporter is doing, as a plist.
`:enabled' and `:endpoint' are the settings; `:collecting' says whether
anything is exported now, which takes both; `:queued', `:dropped',
`:sent', `:failed' and `:inflight' count what the exporter did since the
module started, and `:open-spans' is how many spans are open now."
  (list :enabled (and harness-otel-enabled t)
        :endpoint harness-otel-endpoint
        :collecting (harness-otel--collecting-p)
        :queued (length harness-otel--queue)
        :dropped harness-otel--dropped
        :sent harness-otel--sent
        :failed harness-otel--failed
        :inflight harness-otel--inflight
        :open-spans (hash-table-count harness-otel--spans)))

(harness-defmethod otel/flush ()
  "Export what the queue holds now; return non-nil when something was sent."
  (harness-otel--flush))

(defun harness-otel--subscribe ()
  "Subscribe to the events the exporter follows.  Idempotent."
  (harness-on 'agent/turn-started #'harness-otel--on-turn-started)
  (harness-on 'agent/turn-ended #'harness-otel--on-turn-ended)
  (harness-on 'agent/step-started #'harness-otel--on-step-started)
  (harness-on 'agent/step-ended #'harness-otel--on-step-ended)
  (harness-on 'tools/started #'harness-otel--on-tool-started)
  (harness-on 'tools/finished #'harness-otel--on-tool-finished))

(defun harness-otel--unsubscribe ()
  "Forget the events the exporter followed.  Idempotent."
  (harness-off (cons 'agent/turn-started #'harness-otel--on-turn-started))
  (harness-off (cons 'agent/turn-ended #'harness-otel--on-turn-ended))
  (harness-off (cons 'agent/step-started #'harness-otel--on-step-started))
  (harness-off (cons 'agent/step-ended #'harness-otel--on-step-ended))
  (harness-off (cons 'tools/started #'harness-otel--on-tool-started))
  (harness-off (cons 'tools/finished #'harness-otel--on-tool-finished)))

(defun harness-otel--init ()
  "Start collecting, when the module is on and a collector is configured.
Initialising again, as a reload does, keeps a running exporter's queue and
counters: what it collected is still owed to the collector."
  (setq harness-otel--stopped nil)
  (when (harness-otel--collecting-p)
    (harness-otel--subscribe)
    (harness-otel--ensure-timer)))

(defun harness-otel--shutdown ()
  "Stop collecting, and send what is still queued once.
Nothing is subscribed afterwards, no timer runs, and the queue is empty.
The last request is made, not waited for: stopping the harness never
hangs on a collector that does not answer."
  (harness-otel--unsubscribe)
  (harness-otel--stop-timer)
  ;; The queue is sent once, and nothing is collected after: `--flush' asks
  ;; `--collecting-p', which is false from here on.
  (when (and harness-otel-enabled harness-otel-endpoint
             (not harness-otel--stopped))
    (harness-otel--flush))
  (setq harness-otel--stopped t))

(harness-define-module 'otel
  :doc "Opt-in OpenTelemetry export of turns, model requests and tool calls, over OTLP/HTTP."
  :requires '(agent tools)
  :init #'harness-otel--init
  :shutdown #'harness-otel--shutdown)

(provide 'harness-otel)
;;; harness-otel.el ends here
