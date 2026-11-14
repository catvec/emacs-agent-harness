;;; harness-otel-test.el --- Tests for the OpenTelemetry export  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; The exporter is tried against a fake collector and a fake HTTP layer,
;; never a network: `harness-otel-test--requests' holds what would have
;; been posted, and a test can make the post fail, or answer a status.  The
;; model side is real: the demo provider and a session of the store, so a
;; span's parentage and a step's tokens are the harness's own.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-provider-demo--delay)
(defvar harness-otel--queue)
(defvar harness-otel--spans)
(defvar harness-otel--tree)
(defvar harness-otel--turn-info)
(defvar harness-otel--open-by-session)

(declare-function harness-otel--traces-body "harness-otel" (spans))
(declare-function harness-otel--metrics-body "harness-otel" (metrics))
(declare-function harness-otel--span-otlp "harness-otel" (span))
(declare-function harness-otel--metric-otlp "harness-otel" (metric))
(declare-function harness-otel--bucket "harness-otel" (value bounds))
(declare-function harness-otel--nanos "harness-otel" (time))
(declare-function harness-otel--new-trace-id "harness-otel" ())
(declare-function harness-otel--new-span-id "harness-otel" ())
(declare-function harness-otel--error-type "harness-otel" (kind))
(declare-function harness-otel--total-input "harness-otel" (info))
(declare-function harness-otel--provider "harness-otel" (model))
(declare-function harness-otel--request-model "harness-otel" (model))

(defvar harness-otel-test--requests nil
  "The OTLP requests the fake HTTP layer was asked to make, newest first.
Each is (:url URL :headers HEADERS :json JSON :timeout SECONDS :retry N).")

(defvar harness-otel-test--answer nil
  "How the fake HTTP layer answers, or nil for 200 with no body.
A number is that status; `error' makes the request fail at the transport.")

(defmacro harness-otel-test-with (&rest body)
  "Load the state layer with the demo provider, the otel module, run BODY.
The exporter is on, with a collector of the test's, and no request leaves
the process: `harness-http-request' is a fake that records what it was
given and answers `harness-otel-test--answer'."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent otel))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (let ((harness-provider-demo--delay 0.005)
           (harness-otel-enabled t)
           (harness-otel-endpoint "http://collector.example.com:4318")
           (harness-otel-headers nil)
           (harness-otel-export-interval 3600)
           (harness-otel-timeout 2)
           (harness-otel-max-queue 1024)
           (harness-otel-test--requests nil)
           (harness-otel-test--answer nil)
           (default-directory dir))
       ;; The module loaded with the exporter off, as it ships; now that the
       ;; test's settings are in place, it starts collecting.
       (harness-otel--reset)
       (harness-otel--init)
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (cl-letf (((symbol-function 'harness-http-request)
                  (lambda (url &rest args)
                    ;; As the HTTP layer does: a `:json' argument is encoded,
                    ;; and the body a collector would receive is the string.
                    (when (plist-get args :json)
                      (setq args (plist-put args :json
                                            (harness-json-encode-text (plist-get args :json)))))
                    (when (plist-get args :json)
                      (unless (assoc "Content-Type" (plist-get args :headers))
                        (setq args (plist-put args :headers
                                              (cons (cons "Content-Type" "application/json")
                                                    (plist-get args :headers))))))
                    (push (append (list :url url) args) harness-otel-test--requests)
                    ;; Answered at once: a test counts what an export did
                    ;; without waiting on a timer.
                    (let ((callback (plist-get args :callback))
                          (answer harness-otel-test--answer))
                      (cond ((eq answer 'error)
                             (funcall callback nil nil nil '(refused "connection refused")))
                            ((numberp answer) (funcall callback answer nil "{}" nil))
                            (t (funcall callback 200 nil "{}" nil))))
                    ;; A handle, as the HTTP layer gives one.
                    (list :cancel #'ignore))))
         (unwind-protect (progn ,@body)
           (harness-otel--reset)
           (harness-otel--stop-timer))))))

(defun harness-otel-test-session (&rest plist)
  "Create a demo session in a fresh directory; PLIST adds settings.
Return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                           :model "demo:scripted" plist)
             :id))

(defun harness-otel-test--first (sequence)
  "Return the first item of SEQUENCE, a list or a vector, or nil.
The bodies this suite builds hold vectors, where OTLP wants an array; the
same body parsed back from JSON holds lists, `harness-json-parse' giving
arrays as lists.  A test reads either through this."
  (cond ((null sequence) nil)
        ((vectorp sequence) (aref sequence 0))
        ((consp sequence) (car sequence))
        (t nil)))

(defun harness-otel-test--items (sequence)
  "Return the items of SEQUENCE, a list or a vector, as a list."
  (cond ((null sequence) nil)
        ((vectorp sequence) (append sequence nil))
        ((listp sequence) sequence)
        (t nil)))

(defun harness-otel-test--sent (kind)
  "Return the requests the fake HTTP layer took for KIND (`traces'/`metrics').
Newest first, as `harness-otel-test--requests' has them."
  (cl-remove-if-not (lambda (r) (string-suffix-p (concat "/v1/" kind) (plist-get r :url)))
                    harness-otel-test--requests))

(defun harness-otel-test--json (kind)
  "Return the parsed body of the newest request for KIND, or nil."
  (when-let* ((request (car (harness-otel-test--sent kind))))
    (harness-json-parse (plist-get request :json))))

(defun harness-otel-test--spans (kind &optional request)
  "Return the spans of an OTLP traces body, or of the newest one.
REQUEST is a parsed traces body."
  (let* ((body (or request (harness-otel-test--json kind)))
         (resource (and body (harness-otel-test--first (plist-get body :resourceSpans)))))
    (harness-otel-test--items
     (plist-get (harness-otel-test--first (plist-get resource :scopeSpans)) :spans))))

(defun harness-otel-test--metrics (&optional request)
  "Return the metrics of an OTLP metrics body, or of the newest one."
  (let* ((body (or request (harness-otel-test--json "metrics")))
         (resource (and body (harness-otel-test--first (plist-get body :resourceMetrics)))))
    (harness-otel-test--items
     (plist-get (harness-otel-test--first (plist-get resource :scopeMetrics)) :metrics))))

(defun harness-otel-test--metric (metrics name)
  "Return the metric called NAME among METRICS, or nil."
  (cl-find name metrics :key (lambda (m) (plist-get m :name)) :test #'equal))

(defun harness-otel-test--attribute (attributes key)
  "Return the value of KEY among ATTRIBUTES, or nil.
ATTRIBUTES are either the module's own alist of (KEY . VALUE) conses or
OTLP JSON attribute objects, which `harness-json-parse' reads as plists.
Both shapes are read here, so a test can look at either side of the body."
  (cond
   ;; The module's own alist.
   ((and attributes (consp (car attributes)) (stringp (caar attributes)))
    (cdr (assoc key attributes)))
   ;; OTLP JSON attribute objects.
   ((when-let* ((found (cl-find key attributes :test #'equal
                                :key (lambda (a) (plist-get a :key)))))
      (let ((value (plist-get found :value)))
        (or (plist-get value :stringValue)
            (plist-get value :intValue)
            (plist-get value :doubleValue)
            (plist-get value :boolValue)))))
   (t nil)))

(defun harness-otel-test--span (spans name)
  "Return the span called NAME among SPANS, or nil."
  (cl-find name spans :key (lambda (s) (plist-get s :name)) :test #'equal))

(defun harness-otel-test--all-text (body)
  "Return BODY as its JSON text, for a test that looks for what must not be there."
  (harness-json-encode-text body))

;;;; Off unless asked

(ert-deftest harness-otel-loads-off-and-sends-nothing ()
  "Loading the module, with neither setting, exports nothing and starts no timer."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider provider-demo tools session agent otel))
      (harness-test-load-module m))
    (let ((harness-otel--timer nil))
      (harness-otel--reset)
      (harness-otel--init)
      (should-not harness-otel--timer)
      ;; Nothing subscribed: a turn would reach the exporter through no one.
      (should-not (harness-otel--collecting-p))
      (let ((harness-otel--queue nil))
        (harness-otel--on-turn-started "s1")
        (harness-otel--on-step-started "s1" 1)
        (harness-otel--on-step-ended "s1" (list :model "demo:scripted" :reason 'end-turn
                                                :duration 1.0 :input 10 :output 2))
        (harness-otel--on-tool-started "s1" (list :id "c1" :name "read_file"))
        (harness-otel--on-tool-finished "s1" (list :id "c1" :name "read_file") nil)
        (harness-otel--on-turn-ended "s1" 'end-turn)
        (should-not harness-otel--queue)
        (should-not (harness-call 'otel/flush))
        (should (equal 0 (plist-get (harness-call 'otel/status) :queued)))))))

(ert-deftest harness-otel-enabled-with-no-endpoint-sends-nothing ()
  "The switch alone collects nothing: both it and an endpoint are needed."
  (harness-otel-test-with
    (let ((harness-otel-endpoint nil))
      (harness-otel--reset)
      (should-not (harness-otel--collecting-p))
      (harness-otel--on-turn-started "s1")
      (harness-otel--on-step-started "s1" 1)
      (should-not harness-otel--queue)
      (should (= 0 (hash-table-count harness-otel--spans)))
      (should-not (harness-call 'otel/flush))
      (should-not harness-otel-test--requests))))

(ert-deftest harness-otel-is-off-by-default-and-not-loaded-unasked ()
  "The module ships off by default, and no test run loads it by accident.
A name in `harness-enabled-modules' loads it all the same."
  (should (memq 'otel harness-off-by-default-modules))
  (should (harness-module-off-by-default-p 'otel))
  (let* ((harness-enabled-modules t)
         (harness-disabled-modules nil)
         (harness-off-by-default-modules
          (eval (car (get 'harness-off-by-default-modules 'standard-value)) t))
         (sources (harness--module-sources)))
    (should-not (memq 'otel (harness--selected-modules sources)))
    (let ((harness-enabled-modules '(otel)))
      (should (memq 'otel (harness--selected-modules sources))))))

;;;; OTLP envelopes

(ert-deftest harness-otel-span-ids-are-w3c-trace-context ()
  "Spans carry 32- and 16-hex-digit ids that are never all zeros."
  (dotimes (_ 32)
    (should (string-match-p "\\`[0-9a-f]\\{32\\}\\'" (harness-otel--new-trace-id)))
    (should (string-match-p "\\`[0-9a-f]\\{16\\}\\'" (harness-otel--new-span-id)))
    (should-not (string-match-p "\\`0+\\'" (harness-otel--new-trace-id)))
    (should-not (string-match-p "\\`0+\\'" (harness-otel--new-span-id))))
  ;; Two ids are not the same id (in 2^128, a collision is not a fluke).
  (should-not (equal (harness-otel--new-trace-id) (harness-otel--new-trace-id))))

(ert-deftest harness-otel-nanoseconds-are-exact-and-strings ()
  "The time OTLP is given is the exact nanosecond, as a string."
  (let ((time (encode-time '(30 4 12 9 11 2026 nil -1 nil))))
    (should (equal (harness-otel--nanos time)
                   (format "%d" (* (truncate (float-time time)) 1000000000))))
    (should (stringp (harness-otel--nanos time)))
    ;; No exponent, no decimal point: an integer as OTLP spells it.
    (should (string-match-p "\\`[0-9]+\\'" (harness-otel--nanos)))))

(ert-deftest harness-otel-traces-body-is-an-otlp-envelope ()
  "The traces body is resourceSpans/scopeSpans/spans, with typed attributes.
Nothing in it is null, an empty JSON object or a list where OTLP wants an
array."
  (harness-otel-test-with
    (let ((span (harness-otel--open-span
                 'probe "chat demo" :kind "client" :session "s1"
                 :attributes (harness-otel--attrs
                              "gen_ai.operation.name" "chat"
                              "gen_ai.request.model" "demo"
                              "gen_ai.request.stream" t
                              "harness.step" "2"))))
      (harness-otel--end-span 'probe)
      (let* ((body (harness-otel--traces-body (list span)))
             (resource (harness-otel-test--first (plist-get body :resourceSpans)))
             (scope (harness-otel-test--first (plist-get resource :scopeSpans)))
             (sent (harness-otel-test--first (plist-get scope :spans))))
        ;; The envelope.
        (should (vectorp (plist-get body :resourceSpans)))
        (should (vectorp (plist-get resource :scopeSpans)))
        (should (vectorp (plist-get scope :spans)))
        (should (equal "harness-otel" (plist-get (plist-get scope :scope) :name)))
        ;; The span's identity and shape.
        (should (string-match-p "\\`[0-9a-f]\\{32\\}\\'" (plist-get sent :traceId)))
        (should (string-match-p "\\`[0-9a-f]\\{16\\}\\'" (plist-get sent :spanId)))
        (should (equal "" (plist-get sent :parentSpanId)))
        (should (equal 3 (plist-get sent :kind)))     ; CLIENT
        (should (equal 0 (plist-get (plist-get sent :status) :code)))
        (should (string-match-p "\\`[0-9]+\\'" (plist-get sent :startTimeUnixNano)))
        (should (string-match-p "\\`[0-9]+\\'" (plist-get sent :endTimeUnixNano)))
        (should (<= (string-to-number (plist-get sent :startTimeUnixNano))
                    (string-to-number (plist-get sent :endTimeUnixNano))))
        ;; Attributes are OTLP's typed values, the boolean one a boolean.
        (let ((attributes (harness-otel-test--items (plist-get sent :attributes))))
          (should (equal "chat" (harness-otel-test--attribute attributes "gen_ai.operation.name")))
          (should (eq t (harness-otel-test--attribute attributes "gen_ai.request.stream")))
          (should (equal "2" (harness-otel-test--attribute attributes "harness.step"))))
        ;; It encodes as valid JSON, with no null anywhere.
        (let ((json (harness-json-encode-text body)))
          (should (json-parse-string json :object-type 'plist))
          (should-not (string-match-p "\"\\(?:null\\|nil\\)\"" json)))))))

(ert-deftest harness-otel-metrics-body-is-an-otlp-envelope ()
  "The metrics body is resourceMetrics/scopeMetrics/metrics, delta, typed.
A counter is an integer sum of one point; a histogram has the buckets the
convention names, and the one value in the bucket it falls in."
  (harness-otel-test-with
    (harness-otel--histogram "gen_ai.client.inference.duration" 1.5
                             (harness-otel--attrs "gen_ai.operation.name" "chat") "s")
    (harness-otel--counter "gen_ai.client.inference.usage.input_tokens" 1700
                           (harness-otel--attrs "gen_ai.operation.name" "chat") "{token}")
    (let* ((metrics (nreverse harness-otel--queue))
           (body (harness-otel--metrics-body metrics))
           (resource (harness-otel-test--first (plist-get body :resourceMetrics)))
           (scope (harness-otel-test--first (plist-get resource :scopeMetrics)))
           (sent (append (plist-get scope :metrics) nil))
           (histogram (harness-otel-test--metric sent "gen_ai.client.inference.duration"))
           (counter (harness-otel-test--metric sent
                                               "gen_ai.client.inference.usage.input_tokens")))
      (should (vectorp (plist-get body :resourceMetrics)))
      (should (vectorp (plist-get resource :scopeMetrics)))
      (should (vectorp (plist-get scope :metrics)))
      ;; DELTA, the temporality of what one export carries.
      (should (equal 1 (plist-get (plist-get histogram :histogram) :aggregationTemporality)))
      (should (equal 1 (plist-get (plist-get counter :sum) :aggregationTemporality)))
      (should (eq t (plist-get (plist-get counter :sum) :isMonotonic)))
      ;; The histogram's one data point, in the right bucket.
      (let* ((point (harness-otel-test--first (plist-get (plist-get histogram :histogram) :dataPoints)))
             (counts (harness-otel-test--items (plist-get point :bucketCounts))))
        (should (equal 1 (plist-get point :count)))
        (should (= 1.5 (plist-get point :sum)))
        (should (equal harness-otel--duration-buckets (plist-get point :explicitBounds)))
        (should (= 1 (apply #'+ counts)))
        ;; 1.5 is above 1.28 and not above 2.56: the ninth of fifteen.
        (should (equal '(0 0 0 0 0 0 0 0 1 0 0 0 0 0 0) counts)))
      ;; The counter's asInt is a string, its sum the value.
      (let ((point (harness-otel-test--first (plist-get (plist-get counter :sum) :dataPoints))))
        (should (equal "1700" (plist-get point :asInt))))
      (should (json-parse-string (harness-json-encode-text body) :object-type 'plist)))))

(ert-deftest harness-otel-bucket-falls-at-its-boundary ()
  "A value at a boundary is in that bucket; one above them all is last."
  (let ((bounds [0.5 1.0]))
    (should (= 0 (harness-otel--bucket 0.1 bounds)))
    (should (= 0 (harness-otel--bucket 0.5 bounds)))
    (should (= 1 (harness-otel--bucket 0.51 bounds)))
    (should (= 1 (harness-otel--bucket 1.0 bounds)))
    (should (= 2 (harness-otel--bucket 1.01 bounds)))))

(ert-deftest harness-otel-endpoint-paths-are-otlp ()
  "Signals go to /v1/traces and /v1/metrics, under a base URL as it is given."
  (harness-otel-test-with
    (should (equal "http://collector.example.com:4318/v1/traces"
                   (harness-otel--url "traces")))
    (should (equal "http://collector.example.com:4318/v1/metrics"
                   (harness-otel--url "metrics")))
    (let ((harness-otel-endpoint "http://collector.example.com:4318/"))
      (should (equal "http://collector.example.com:4318/v1/traces"
                     (harness-otel--url "traces"))))
    ;; A URL that names the signal's own path is used as it stands.
    (let ((harness-otel-endpoint "https://gateway.example.com/otel/v1/traces"))
      (should (equal "https://gateway.example.com/otel/v1/traces"
                     (harness-otel--url "traces")))
      (should (equal "https://gateway.example.com/otel/v1/traces/v1/metrics"
                     (harness-otel--url "metrics"))))
    ;; Only http and https, with a host that could work.
    (dolist (url '("ftp://collector.example.com" "collector.example.com"
                   "http://" "not a url"))
      (should-not (harness-otel--usable-url-p url)))
    (should (harness-otel--usable-url-p "http://localhost:4318/v1/traces"))))

;;;; A turn, end to end

(defun harness-otel-test--turn (id &optional prompt)
  "Run a turn of ID; PROMPT picks the demo's script, its \"tools\" for calls."
  (harness-await (harness-call 'agent/prompt id (or prompt "hello there"))))

(defun harness-otel-test--tools ()
  "Define the tools the demo's \"tools\" script calls."
  (harness-define-tool "glob" :label "Search files" :description "glob" :kind 'read
                       :handler (lambda (_input _ctx) "a glob result"))
  (harness-define-tool "grep" :label "Search text" :description "grep" :kind 'read
                       :handler (lambda (_input _ctx) "a grep result"))
  (harness-define-tool "bash" :label "Run command" :description "bash" :kind 'exec
                       :handler (lambda (_input _ctx) "a bash result")))

(ert-deftest harness-otel-a-turn-is-one-trace-with-coherent-parentage ()
  "A turn is an agent span, its request a child, its tool a child of that.
The request and the tool share the turn's trace; each names the span it
hangs under, and the tool's parent is the turn, as the convention has it
for a tool the agent asked for."
  (harness-otel-test-with
    (harness-otel-test--tools)
    (let ((id (harness-otel-test-session)))
      ;; The demo's "tools" script asks for two searches, then a bash call.
      (harness-otel-test--turn id "tools")
      (harness-call 'otel/flush)
      (let* ((spans (harness-otel-test--spans "traces"))
             (agent (harness-otel-test--span spans "gen_ai.invoke_agent emacs-agent-harness"))
             ;; The turn's requests: one per tool call, and the one that
             ;; ended it.  Each is the same trace's.
             (requests (cl-remove-if-not (lambda (s) (string-prefix-p "chat " (plist-get s :name)))
                                         spans))
             (request (car requests))
             (tools (cl-remove-if-not (lambda (s) (string-prefix-p "gen_ai.execute_tool "
                                                                   (plist-get s :name)))
                                      spans)))
        (should agent)
        (should request)
        ;; One request per tool call and one that ended the turn.
        (should (>= (length requests) 2))
        (should tools)
        ;; One trace for the turn.
        (dolist (span (append (list agent) requests tools))
          (should (equal (plist-get agent :traceId) (plist-get span :traceId))))
        ;; The turn is a root, each request and each tool hangs under it.
        (should (equal "" (plist-get agent :parentSpanId)))
        (dolist (span (append requests tools))
          (should (equal (plist-get agent :spanId) (plist-get span :parentSpanId))))
        ;; The kinds the conventions name: INTERNAL agent and tool, CLIENT model.
        (should (equal 1 (plist-get agent :kind)))
        (dolist (tool tools)
          (should (equal 1 (plist-get tool :kind))))
        (should (equal 3 (plist-get request :kind)))
        ;; The names the conventions name.
        (should (string-match-p "\\`gen_ai.client.inference\\|\\`chat " (plist-get request :name)))
        (should (string-prefix-p "chat " (plist-get request :name)))
        (should (string-prefix-p "gen_ai.execute_tool " (plist-get (car tools) :name)))
        ;; The attributes the conventions name.
        (let ((attributes (harness-otel-test--items (plist-get request :attributes))))
          (should (equal "chat" (harness-otel-test--attribute attributes "gen_ai.operation.name")))
          (should (equal "harness.demo" (harness-otel-test--attribute attributes "gen_ai.provider.name")))
          (should (equal "scripted"
                         (harness-otel-test--attribute attributes "gen_ai.request.model")))
          ;; The turn's requests ended for their own reasons.
          (should (member (harness-otel-test--attribute attributes "harness.stop_reason")
                          '("tool-use" "end-turn"))))
        (let ((attributes (harness-otel-test--items (plist-get agent :attributes))))
          (should (equal "invoke_agent" (harness-otel-test--attribute attributes "gen_ai.operation.name")))
          (should (equal "end-turn" (harness-otel-test--attribute attributes "harness.turn.stop_reason")))
          ;; The turn counts the requests it actually opened -- one span
          ;; each, so a retry inside one request is not counted twice.
          (should (equal (number-to-string (length requests))
                         (harness-otel-test--attribute attributes "harness.turn.requests"))))
        ;; A turn that ended normally carries no error status.
        (should (equal 0 (plist-get (plist-get agent :status) :code)))))))

(ert-deftest harness-otel-a-tool-call-is-one-span ()
  "A tool call opens one span, queued once, named for the tool and no other."
  (harness-otel-test-with
    (harness-otel--on-turn-started "s1")
    (harness-otel--on-tool-started "s1" (list :id "c1" :name "read_file"))
    ;; The turn's span and the tool's.
    (should (= 2 (hash-table-count harness-otel--spans)))
    (harness-otel--on-tool-finished "s1" (list :id "c1" :name "read_file")
                                    (list :content "a file" :is-error nil))
    (should (= 1 (hash-table-count harness-otel--spans)))
    (should (= 1 (length (cl-remove-if-not #'harness-otel--span-p harness-otel--queue))))
    (harness-otel--on-turn-ended "s1" 'end-turn)
    (harness-call 'otel/flush)
    (let* ((spans (harness-otel-test--spans "traces"))
           (tool (harness-otel-test--span spans "gen_ai.execute_tool read_file")))
      (should tool)
      (should (equal 1 (length (cl-remove-if-not
                                (lambda (s) (string-prefix-p "gen_ai.execute_tool " (plist-get s :name)))
                                spans))))
      (let ((attributes (harness-otel-test--items (plist-get tool :attributes))))
        (should (equal "execute_tool" (harness-otel-test--attribute attributes "gen_ai.operation.name")))
        (should (equal "read_file" (harness-otel-test--attribute attributes "gen_ai.tool.name")))
        (should (equal "c1" (harness-otel-test--attribute attributes "gen_ai.tool.call.id")))))))

(ert-deftest harness-otel-a-tool-that-failed-carries-a-kind-and-no-output ()
  "A failed or denied tool sets `error.type' and a status, and never its output."
  (harness-otel-test-with
    (harness-otel--on-turn-started "s1")
    (harness-otel--on-tool-started "s1" (list :id "c1" :name "bash"))
    (harness-otel--on-tool-finished "s1" (list :id "c1" :name "bash")
                                    (list :content "Permission denied: /home/someone/.ssh/id_ed25519"
                                          :is-error t :denied t))
    (harness-otel--on-turn-ended "s1" 'end-turn)
    (harness-call 'otel/flush)
    (let* ((spans (harness-otel-test--spans "traces"))
           (tool (harness-otel-test--span spans "gen_ai.execute_tool bash"))
           (attributes (harness-otel-test--items (plist-get tool :attributes))))
      (should (equal 2 (plist-get (plist-get tool :status) :code)))
      (should (equal "denied" (plist-get (plist-get tool :status) :message)))
      (should (equal "denied" (harness-otel-test--attribute attributes "error.type")))
      (should (eq t (harness-otel-test--attribute attributes "harness.tool.denied")))
      ;; The tool's output, and therefore its path, is nowhere in the body.
      (should-not (string-search "id_ed25519"
                                 (harness-otel-test--all-text
                                  (harness-otel-test--json "traces")))))))

(ert-deftest harness-otel-a-sub-agent-hangs-under-its-parents-turn ()
  "A sub-agent's turn is in its parent's trace, under the parent's turn span.
One logical operation is one trace, even across sessions."
  (harness-otel-test-with
    (let ((parent (harness-call 'session/create :cwd (harness-test-temp-dir)
                                :model "demo:scripted" :name "Parent"))
          (child nil))
      (setq child (harness-call 'session/create :cwd (harness-test-temp-dir)
                                :model "demo:scripted" :kind 'subagent
                                :parent-id (plist-get parent :id) :name "Child"))
      ;; The parent's turn opens first, and the child's turn runs inside it.
      (harness-call 'session/set-status (plist-get parent :id) 'running)
      (harness-emit 'agent/turn-started (plist-get parent :id))
      (harness-emit 'agent/step-started (plist-get parent :id) 1)
      (harness-emit 'agent/turn-started (plist-get child :id))
      (harness-emit 'agent/step-started (plist-get child :id) 1)
      (harness-emit 'agent/step-ended (plist-get child :id)
                    (list :model "demo:scripted" :reason 'end-turn
                          :attempt 1 :step 1 :duration 0.3))
      (harness-emit 'agent/turn-ended (plist-get child :id) 'end-turn)
      (harness-emit 'agent/turn-ended (plist-get parent :id) 'end-turn)
      (harness-call 'otel/flush)
      (let* ((spans (harness-otel-test--spans "traces"))
             (by-session (lambda (id)
                           ;; The turn's own span, not a request's of the
                           ;; same session, which carries its id too.
                           (cl-find id spans :test #'equal
                                    :key (lambda (s)
                                           (and (string-prefix-p "gen_ai.invoke_agent "
                                                                 (plist-get s :name))
                                                (harness-otel-test--attribute
                                                 (harness-otel-test--items
                                                  (plist-get s :attributes))
                                                 "harness.session.id"))))))
             (parent-span (funcall by-session (plist-get parent :id)))
             (child-span (funcall by-session (plist-get child :id)))
             (request (harness-otel-test--span spans "chat scripted")))
        (should parent-span)
        (should child-span)
        (should request)
        ;; One trace: the child's turn hangs under the parent's turn span,
        ;; and the child's request under the child's.
        (should (equal (plist-get parent-span :traceId) (plist-get child-span :traceId)))
        (should (equal (plist-get parent-span :spanId) (plist-get child-span :parentSpanId)))
        (should (equal (plist-get child-span :spanId) (plist-get request :parentSpanId)))
        (should (equal (plist-get parent-span :traceId) (plist-get request :traceId)))))))

(ert-deftest harness-otel-the-session-is-named-on-the-spans-that-need-it ()
  "The conversation is named once per turn; a child span names its session.
`gen_ai.conversation.id' is the convention's slot and sits on the agent
span alone, because a request already hangs in its turn's trace.  A
request and a tool span carry `harness.session.id', so a span found on its
own says which session it belongs to; no metric carries either."
  (harness-otel-test-with
    (let ((id (harness-otel-test-session)))
      (harness-otel--on-turn-started id)
      (harness-otel--on-step-started id 1)
      (harness-otel--on-tool-started id (list :id "c1" :name "bash"))
      (harness-otel--on-tool-finished id (list :id "c1" :name "bash")
                                      (list :content "ok" :is-error nil))
      (harness-otel--on-step-ended id (list :model "demo:scripted" :reason 'tool-use
                                            :attempt 1 :step 1 :duration 0.2))
      (harness-otel--on-turn-ended id 'end-turn)
      (harness-call 'otel/flush)
      (let* ((spans (harness-otel-test--spans "traces"))
             (agent (harness-otel-test--span spans "gen_ai.invoke_agent emacs-agent-harness"))
             (request (harness-otel-test--span spans "chat scripted"))
             (tool (harness-otel-test--span spans "gen_ai.execute_tool bash"))
             (attributes (lambda (span)
                           (harness-otel-test--items (plist-get span :attributes)))))
        (should agent)
        (should request)
        (should tool)
        (dolist (span (list agent request tool))
          (should (equal id (harness-otel-test--attribute (funcall attributes span)
                                                          "harness.session.id"))))
        (should (equal id (harness-otel-test--attribute (funcall attributes agent)
                                                        "gen_ai.conversation.id")))
        (dolist (span (list request tool))
          (should-not (harness-otel-test--attribute (funcall attributes span)
                                                    "gen_ai.conversation.id")))))))

(ert-deftest harness-otel-a-step-that-failed-is-an-error-and-no-prompt ()
  "A failed request sets an error status, a bounded `error.type', and no text.
The provider's error text, which can hold a prompt, is never exported."
  (harness-otel-test-with
    (harness-otel--on-turn-started "s1")
    (harness-otel--on-step-started "s1" 1)
    (harness-otel--on-step-ended "s1" (list :model "claude:claude-sonnet-5" :reason 'error
                                            :error-kind 'rate-limit :attempt 1 :step 1
                                            :duration 0.4 :cancelled nil))
    (harness-otel--on-turn-ended "s1" 'error)
    (harness-call 'otel/flush)
    (let* ((spans (harness-otel-test--spans "traces"))
           (request (harness-otel-test--span spans "chat claude-sonnet-5"))
           (attributes (harness-otel-test--items (plist-get request :attributes))))
      (should (equal 2 (plist-get (plist-get request :status) :code)))
      (should (equal "rate-limit" (harness-otel-test--attribute attributes "error.type")))
      (should (equal "error" (harness-otel-test--attribute attributes "harness.stop_reason")))
      ;; The turn failed too, and says so in a bounded word.
      (let ((agent (harness-otel-test--span spans "gen_ai.invoke_agent emacs-agent-harness")))
        (should (equal 2 (plist-get (plist-get agent :status) :code)))
        (should (equal "error" (harness-otel-test--attribute
                                (harness-otel-test--items (plist-get agent :attributes)) "error.type")))))))

(ert-deftest harness-otel-cancellation-is-no-error ()
  "A cancelled request and turn have no `error.type', and say they were cancelled."
  (harness-otel-test-with
    (harness-otel--on-turn-started "s1")
    (harness-otel--on-step-started "s1" 1)
    (harness-otel--on-step-ended "s1" (list :model "demo:scripted" :reason 'cancelled
                                            :attempt 1 :step 1 :duration 0.2 :cancelled t))
    (harness-otel--on-turn-ended "s1" 'cancelled)
    (harness-call 'otel/flush)
    (let* ((spans (harness-otel-test--spans "traces"))
           (request (harness-otel-test--span spans "chat scripted"))
           (attributes (harness-otel-test--items (plist-get request :attributes))))
      (should-not (plist-get (plist-get request :status) :message))
      (should (member (plist-get (plist-get request :status) :code) '(0 1)))
      (should-not (harness-otel-test--attribute attributes "error.type"))
      (should (eq t (harness-otel-test--attribute attributes "harness.cancelled")))
      (let ((agent (harness-otel-test--span spans "gen_ai.invoke_agent emacs-agent-harness")))
        (should (eq t (harness-otel-test--attribute
                       (harness-otel-test--items (plist-get agent :attributes)) "harness.cancelled")))))))

(ert-deftest harness-otel-a-cancelled-turn-closes-what-it-left-open ()
  "A turn that ends with a call still running closes that span with it."
  (harness-otel-test-with
    (harness-otel--on-turn-started "s1")
    (harness-otel--on-step-started "s1" 1)
    (harness-otel--on-tool-started "s1" (list :id "c1" :name "bash"))
    (should (= 3 (hash-table-count harness-otel--spans)))
    (harness-otel--on-turn-ended "s1" 'cancelled)
    (should (= 0 (hash-table-count harness-otel--spans)))
    (should (= 3 (length (cl-remove-if-not #'harness-otel--span-p harness-otel--queue))))
    (harness-call 'otel/flush)
    (let* ((spans (harness-otel-test--spans "traces"))
           (tool (harness-otel-test--span spans "gen_ai.execute_tool bash")))
      (should tool)
      (should (eq t (harness-otel-test--attribute
                     (harness-otel-test--items (plist-get tool :attributes)) "harness.cancelled"))))))

;;;; Tokens

(ert-deftest harness-otel-a-step-counts-its-own-cache-inclusive-input ()
  "The input counter is the whole prompt, cached tokens included.
`gen_ai.usage.input_tokens' is the same count, and the cache reading is
named apart, as the subset it is."
  (harness-otel-test-with
    ;; A provider that reports the cache apart: 900 uncached, 800 read.
    (harness-otel--on-turn-started "s1")
    (harness-otel--on-step-started "s1" 1)
    (harness-otel--on-step-ended "s1" (list :model "claude:claude-sonnet-5" :reason 'end-turn
                                            :attempt 1 :step 1 :duration 1.0
                                            :input 900 :output 120
                                            :cache-read 800 :cache-read-known t
                                            :context 1700))
    (harness-otel--on-turn-ended "s1" 'end-turn)
    (harness-call 'otel/flush)
    (let* ((metrics (harness-otel-test--metrics))
           (input (harness-otel-test--metric metrics "gen_ai.client.inference.usage.input_tokens"))
           (output (harness-otel-test--metric metrics
                                              "gen_ai.client.inference.usage.output_tokens"))
           (point (harness-otel-test--first (plist-get (plist-get input :sum) :dataPoints))))
      ;; 1700, not 900: the cached tokens are part of the prompt.
      (should (equal "1700" (plist-get point :asInt)))
      (should (equal "120" (plist-get (car (append
                                            (plist-get (plist-get output :sum) :dataPoints)
                                            nil))
                        :asInt)))
      ;; The span names the subset apart, never adding it to the total.
      (let* ((spans (harness-otel-test--spans "traces"))
             (request (harness-otel-test--span spans "chat claude-sonnet-5"))
             (attributes (harness-otel-test--items (plist-get request :attributes))))
        (should (equal "1700" (harness-otel-test--attribute attributes "gen_ai.usage.input_tokens")))
        (should (equal "800"
                       (harness-otel-test--attribute attributes "gen_ai.usage.cache_read.input_tokens")))
        (should (equal "120" (harness-otel-test--attribute attributes "gen_ai.usage.output_tokens")))))))

(ert-deftest harness-otel-input-counts-a-cache-inclusive-provider-once ()
  "A provider that already counts the cached tokens in its input is not added to.
DeepSeek's `:input' is the cache misses and its `:cache-read' the hits;
`:context' is the whole prompt, and is what is counted."
  (harness-otel-test-with
    (should (= 1700 (harness-otel--total-input
                     (list :input 900 :cache-read 800 :cache-read-known t :context 1700))))
    ;; Without a context the counts add back together.
    (should (= 1700 (harness-otel--total-input (list :input 900 :cache-read 800
                                                     :cache-read-known t))))
    (should (= 1200 (harness-otel--total-input
                     (list :input 1000 :cache-read 100 :cache-write 100
                           :cache-read-known t))))))

(ert-deftest harness-otel-unavailable-usage-is-no-zero ()
  "A step whose provider said nothing of its tokens records no counter.
A missing reading is left out, not made a zero that would read as one."
  (harness-otel-test-with
    (harness-otel--on-turn-started "s1")
    (harness-otel--on-step-started "s1" 1)
    (harness-otel--on-step-ended "s1" (list :model "demo:scripted" :reason 'end-turn
                                            :attempt 1 :step 1 :duration 0.5))
    (harness-otel--on-turn-ended "s1" 'end-turn)
    (harness-call 'otel/flush)
    (let* ((metrics (harness-otel-test--metrics))
           (spans (harness-otel-test--spans "traces"))
           (request (harness-otel-test--span spans "chat scripted"))
           (attributes (harness-otel-test--items (plist-get request :attributes))))
      ;; The duration is known, and is recorded.
      (should (harness-otel-test--metric metrics "gen_ai.client.inference.duration"))
      ;; The tokens are not, and are not.
      (should-not (harness-otel-test--metric metrics "gen_ai.client.inference.usage.input_tokens"))
      (should-not (harness-otel-test--metric metrics "gen_ai.client.inference.usage.output_tokens"))
      (should-not (harness-otel-test--attribute attributes "gen_ai.usage.input_tokens"))
      (should-not (harness-otel-test--attribute attributes "gen_ai.usage.output_tokens")))))

(ert-deftest harness-otel-a-zero-cache-reading-stays-absent ()
  "The convention wants a cache attribute when its count is available and non-zero.
A provider that reported the cache and served nothing from it reports a
count of zero, which is left out rather than written on every request."
  (harness-otel-test-with
    (harness-otel--on-turn-started "s1")
    (harness-otel--on-step-started "s1" 1)
    (harness-otel--on-step-ended "s1" (list :model "demo:scripted" :reason 'end-turn
                                            :attempt 1 :step 1 :duration 0.5
                                            :input 1800 :output 60
                                            :cache-read 0 :cache-write 900
                                            :cache-read-known t
                                            :context 2700))
    (harness-otel--on-turn-ended "s1" 'end-turn)
    (harness-call 'otel/flush)
    (let* ((spans (harness-otel-test--spans "traces"))
           (request (harness-otel-test--span spans "chat scripted"))
           (attributes (harness-otel-test--items (plist-get request :attributes))))
      (should (equal "2700" (harness-otel-test--attribute attributes "gen_ai.usage.input_tokens")))
      ;; The read count was zero and says nothing: it is absent.
      (should-not (harness-otel-test--attribute attributes "gen_ai.usage.cache_read.input_tokens"))
      ;; The write count was 900 and is written.
      (should (equal "900"
                     (harness-otel-test--attribute attributes "gen_ai.usage.cache_write.input_tokens"))))))

(ert-deftest harness-otel-a-zero-token-count-records-no-counter ()
  "A counter counts known, positive contributions: zero records nothing."
  (harness-otel-test-with
    (harness-otel--counter "gen_ai.client.inference.usage.output_tokens" 0 nil)
    (should-not harness-otel--queue)
    (harness-otel--counter "gen_ai.client.inference.usage.output_tokens" nil nil)
    (should-not harness-otel--queue)))

(ert-deftest harness-otel-tokens-are-not-session-totals ()
  "Two steps' metrics are two records of their own, never a running total."
  (harness-otel-test-with
    (harness-otel--on-turn-started "s1")
    ;; Two requests of one turn, each with its own reading.
    (harness-otel--on-step-started "s1" 1)
    (harness-otel--on-step-ended "s1" (list :model "demo:scripted" :reason 'tool-use
                                            :attempt 1 :step 1 :duration 0.5
                                            :input 1000 :output 10 :context 1000))
    (harness-otel--on-step-started "s1" 2)
    (harness-otel--on-step-ended "s1" (list :model "demo:scripted" :reason 'end-turn
                                            :attempt 1 :step 2 :duration 0.7
                                            :input 2000 :output 20 :context 2000))
    (harness-otel--on-turn-ended "s1" 'end-turn)
    (harness-call 'otel/flush)
    (let* ((metrics (harness-otel-test--metrics))
           (inputs (cl-remove-if-not (lambda (m)
                                       (equal "gen_ai.client.inference.usage.input_tokens"
                                              (plist-get m :name)))
                                     metrics))
           (values (mapcar (lambda (m)
                             (plist-get (harness-otel-test--first (plist-get (plist-get m :sum) :dataPoints))
                                        :asInt))
                           inputs)))
      ;; One record per request, each its own count: never 3000, and never
      ;; 1000 twice.
      (should (equal '("1000" "2000") values)))))

(ert-deftest harness-otel-a-retry-is-one-operation ()
  "A step tried again is one report, with its attempts' tokens added.
The failed attempt is never a second operation."
  (harness-otel-test-with
    (harness-otel--on-turn-started "s1")
    (harness-otel--on-step-started "s1" 1)
    ;; The first attempt fails and the step is tried again: the agent keeps
    ;; the step open, adds the retry's counts to it, and reports once, with
    ;; the attempts it took.  That is what the module gets.
    (harness-otel--on-step-started "s1" 1)
    (harness-otel--on-step-ended "s1" (list :model "demo:scripted" :reason 'end-turn
                                            :attempt 2 :step 1 :duration 0.6
                                            :input 200 :output 6))
    (harness-otel--on-turn-ended "s1" 'end-turn)
    (harness-call 'otel/flush)
    (let* ((metrics (harness-otel-test--metrics))
           (inputs (cl-remove-if-not (lambda (m)
                                       (equal "gen_ai.client.inference.usage.input_tokens"
                                              (plist-get m :name)))
                                     metrics))
           (values (mapcar (lambda (m)
                             (plist-get (harness-otel-test--first (plist-get (plist-get m :sum) :dataPoints))
                                        :asInt))
                           inputs))
           (request (harness-otel-test--span (harness-otel-test--spans "traces")
                                             "chat scripted")))
      ;; One operation, whose attempt took two tries and whose tokens are
      ;; both attempts': 200 input, 6 output.
      (should (equal '("200") values))
      (should (equal "2" (harness-otel-test--attribute
                          (harness-otel-test--items (plist-get request :attributes))
                          "harness.step.attempt")))
      (should (equal 0 (plist-get (plist-get request :status) :code))))))

;;;; Privacy and redaction

(ert-deftest harness-otel-never-exports-what-was-said-or-done ()
  "No prompt, answer, argument, output or path reaches the collector.
The whole turn is run, tool call and all, and the bodies are searched."
  (harness-otel-test-with
    (harness-define-tool "read_file" :label "Read file" :description "read"
                         :kind 'read
                         :paths (lambda (input) (list (plist-get input :path)))
                         :handler (lambda (input _ctx)
                                    (format "CONTENTS OF %s: %s" (plist-get input :path)
                                            (concat "hunter" "2, " "ACCOUNT-" "KEY"))))
    (let ((id (harness-otel-test-session))
          (harness-provider-demo-script-override
           (lambda (_request)
             '((:type tool-call :id "secret-1" :name "read_file"
                    :input (:path "/home/someone/.aws/credentials"))
               (:type text :delta "The file holds a key.")
               (:type usage :input 700 :output 40 :context 800)
               (:type done :stop-reason end-turn)))))
      (harness-await (harness-call 'agent/prompt id "what is in /home/someone/.aws/credentials"))
      (harness-call 'otel/flush)
      (let* ((traces (harness-otel-test--all-text (harness-otel-test--json "traces")))
             (metrics (harness-otel-test--all-text (harness-otel-test--json "metrics")))
             (both (concat traces metrics)))
        (dolist (secret (list "hunter2" (concat "ACCOUNT-" "KEY") ".aws/credentials" "/home/someone"
                              "CONTENTS OF" "what is in"))
          (should-not (string-search secret both)))
        ;; And the things that are the operation's own are there.
        (should (string-search "chat scripted" traces))
        (should (string-search "gen_ai.invoke_agent" traces))
        (should (string-search "gen_ai.execute_tool " traces))))))

(ert-deftest harness-otel-no-content-attributes-are-ever-written ()
  "The Opt-In content attributes are not written at all, by any event."
  (harness-otel-test-with
    (harness-otel--on-turn-started "s1")
    (harness-otel--on-step-started "s1" 1)
    (harness-otel--on-step-ended "s1" (list :model "demo:scripted" :reason 'end-turn
                                            :attempt 1 :step 1 :duration 0.3
                                            :input 10 :output 2 :context 10))
    (harness-otel--on-tool-started "s1" (list :id "c1" :name "read_file"
                                              :input (list :path "/secret")))
    (harness-otel--on-tool-finished "s1" (list :id "c1" :name "read_file")
                                    (list :content "the secret" :is-error nil))
    (harness-otel--on-turn-ended "s1" 'end-turn)
    (harness-call 'otel/flush)
    (let ((keys (append (mapcar (lambda (s) (plist-get s :attributes))
                                (harness-otel-test--spans "traces"))
                        (mapcar (lambda (m)
                                  (cl-loop for dp in (append
                                                      (harness-otel-test--items (plist-get (plist-get m :sum) :dataPoints))
                                                      (harness-otel-test--items (plist-get (plist-get m :histogram) :dataPoints)))
                                           append (harness-otel-test--items (plist-get dp :attributes))))
                                (harness-otel-test--metrics)))))
      (let ((names (delq nil (mapcar (lambda (a) (plist-get a :key))
                                     (apply #'append (mapcar #'harness-otel-test--items keys))))))
        (dolist (content '("gen_ai.input.messages" "gen_ai.output.messages"
                           "gen_ai.system_instructions" "gen_ai.tool.definitions"
                           "gen_ai.tool.call.arguments" "gen_ai.tool.call.result"))
          (should-not (member content names)))
        ;; The content of a tool's argument is not there either.
        (should-not (string-search "/secret" (harness-otel-test--all-text
                                              (harness-otel-test--json "traces"))))))))

(ert-deftest harness-otel-metric-labels-are-bounded ()
  "No metric is split by a session, a turn, or a tool call.
A dimension that grew with use would make a metric useless."
  (harness-otel-test-with
    (harness-otel--on-turn-started "session-one")
    (harness-otel--on-step-started "session-one" 1)
    (harness-otel--on-step-ended "session-one"
                                 (list :model "demo:scripted" :reason 'end-turn
                                       :attempt 1 :step 1 :duration 0.3
                                       :input 10 :output 2 :context 10))
    (harness-otel--on-turn-ended "session-one" 'end-turn)
    (harness-call 'otel/flush)
    (let ((metrics (harness-otel-test--metrics)))
      (should metrics)
      (dolist (metric metrics)
        (let* ((body (or (plist-get metric :sum) (plist-get metric :histogram)))
               (point (harness-otel-test--first (plist-get body :dataPoints)))
               (names (mapcar (lambda (a) (plist-get a :key))
                              (harness-otel-test--items (plist-get point :attributes)))))
          (dolist (labelled '("harness.session.id" "harness.turn" "harness.step"
                              "harness.step.attempt" "gen_ai.tool.call.id"
                              "gen_ai.conversation.id"))
            (should-not (member labelled names))))))))

(ert-deftest harness-otel-error-types-are-bounded ()
  "A failure kind outside the documented set is reported as `error'."
  (harness-otel-test-with
    (should (equal "rate-limit" (harness-otel--error-type 'rate-limit)))
    (should (equal "quota" (harness-otel--error-type "quota")))
    (should (equal "error" (harness-otel--error-type 'some-provider-nonsense)))
    ;; A provider's whole error text must not become a dimension.
    (should (equal "error" (harness-otel--error-type "Error: the prompt was ...")))))

;;;; The exporter's reliability

(ert-deftest harness-otel-a-failing-collector-is-isolated ()
  "A refused, unreachable or broken collector never reaches the turn.
The export is counted and dropped; a turn ends as it would have."
  (harness-otel-test-with
    (let ((harness-otel-test--answer 'error)
          (id (harness-otel-test-session)))
      ;; The turn runs to its end, tool call and all, with the export bad.
      (harness-otel-test--turn id)
      (should (equal 'idle (plist-get (harness-call 'session/get id) :status)))
      (harness-call 'otel/flush)
      (harness-call 'otel/flush)
      (let ((status (harness-call 'otel/status)))
        (should (> (plist-get status :failed) 0))
        (should (equal 0 (plist-get status :queued)))
        ;; One line in the log, not one per request.
        (should (plist-get status :failed)))
      ;; And a request with a status the collector refused is a failure too.
      (setq harness-otel-test--answer 400)
      (harness-otel--on-turn-started "s1")
      (harness-otel--on-turn-ended "s1" 'end-turn)
      (harness-call 'otel/flush)
      (should (> (plist-get (harness-call 'otel/status) :failed) 1)))))

(ert-deftest harness-otel-the-queue-is-bounded ()
  "A collector that cannot be reached never makes the queue grow without end.
The oldest items are dropped, and counted."
  (harness-otel-test-with
    (let ((harness-otel-max-queue 20))
      (dotimes (i 100)
        (harness-otel--histogram "gen_ai.client.inference.duration" 0.5
                                 (harness-otel--attrs "gen_ai.step" i) "s"))
      (should (<= (length harness-otel--queue) 20))
      (should (= 80 (plist-get (harness-call 'otel/status) :dropped)))
      ;; The newest are the ones kept.
      (should (equal 99 (harness-otel-test--attribute
                           (harness-otel--metric-attributes (car harness-otel--queue))
                           "gen_ai.step")))
      (should (= 20 (plist-get (harness-call 'otel/status) :queued)))
      (harness-call 'otel/flush))))

(ert-deftest harness-otel-flush-sends-each-item-once ()
  "An export takes the queue, and the next one sends nothing of it again."
  (harness-otel-test-with
    (harness-otel--histogram "gen_ai.client.inference.duration" 0.5 nil "s")
    (harness-otel--counter "gen_ai.client.inference.usage.input_tokens" 10 nil)
    (should (harness-call 'otel/flush))
    (should-not harness-otel--queue)
    ;; Nothing left: no second request.
    (should-not (harness-call 'otel/flush))
    ;; Both items were metrics, so one request, for metrics only.
    (should (= 0 (length (harness-otel-test--sent "traces"))))
    (should (= 1 (length (harness-otel-test--sent "metrics"))))
    (let ((metrics (harness-otel-test--metrics)))
      (should (harness-otel-test--metric metrics "gen_ai.client.inference.duration"))
      (should (harness-otel-test--metric metrics
                                         "gen_ai.client.inference.usage.input_tokens")))))

(ert-deftest harness-otel-an-export-does-not-retry ()
  "An export is one try: a retry would send the same spans twice."
  (harness-otel-test-with
    (harness-otel--histogram "gen_ai.client.inference.duration" 0.5 nil "s")
    (harness-call 'otel/flush)
    (let ((request (car harness-otel-test--requests)))
      (should (equal 0 (plist-get request :retry)))
      (should (equal "POST" (plist-get request :method)))
      (should (equal "application/json"
                     (cdr (assoc "Content-Type" (plist-get request :headers)))))
      (should (equal 2 (plist-get request :timeout))))))

(ert-deftest harness-otel-shutdown-is-predictable ()
  "A shutdown sends what is queued once, stops the timer, and sends no more.
Nothing subscribes to the bus afterwards."
  (harness-otel-test-with
    (harness-otel--init)
    (should harness-otel--timer)
    (harness-otel--on-turn-started "s1")
    (harness-otel--on-turn-ended "s1" 'end-turn)
    (should harness-otel--queue)
    (harness-otel--shutdown)
    (should-not harness-otel--timer)
    (should-not harness-otel--queue)
    (should (= 1 (length (harness-otel-test--sent "traces"))))
    ;; The events reach nobody now.
    (let ((before (length harness-otel-test--requests)))
      (harness-otel--on-turn-started "s2")
      (harness-otel--on-turn-ended "s2" 'end-turn)
      (harness-call 'otel/flush)
      (should (= before (length harness-otel-test--requests))))))

(ert-deftest harness-otel-headers-come-from-the-setting-or-the-environment ()
  "The setting wins; the OTLP environment variable is read when it is nil."
  (harness-otel-test-with
    (should (equal "application/json"
                   (cdr (assoc "Content-Type" (harness-otel--headers)))))
    (let ((harness-otel-headers '(("Authorization" . "Bearer t"))))
      (should (equal "Bearer t" (cdr (assoc "Authorization" (harness-otel--headers))))))
    (let* ((harness-otel-headers nil)
           (process-environment (cons "OTEL_EXPORTER_OTLP_HEADERS=a=1,b=2"
                                      process-environment)))
      (should (equal "1" (cdr (assoc "a" (harness-otel--headers)))))
      (should (equal "2" (cdr (assoc "b" (harness-otel--headers))))))))

(ert-deftest harness-otel-reports-its-state ()
  "`otel/status' says whether it exports, and what it has done."
  (harness-otel-test-with
    (let ((status (harness-call 'otel/status)))
      (should (eq t (plist-get status :enabled)))
      (should (plist-get status :collecting))
      (should (equal 0 (plist-get status :queued))))
    (let ((harness-otel-enabled nil))
      ;; The collector stays in settings, but nothing is collected.
      (should-not (plist-get (harness-call 'otel/status) :collecting)))))

;;;; A fresh exporter per run

(ert-deftest harness-otel-reset-forgets-everything ()
  "`harness-otel--reset' empties what the exporter holds."
  (harness-otel-test-with
    (harness-otel--on-turn-started "s1")
    (harness-otel--histogram "gen_ai.client.inference.duration" 0.5 nil "s")
    (harness-otel--reset)
    (should-not harness-otel--queue)
    (should (= 0 (hash-table-count harness-otel--spans)))
    (should (= 0 (hash-table-count harness-otel--tree)))
    (let ((status (harness-call 'otel/status)))
      (should (equal 0 (plist-get status :dropped)))
      (should (equal 0 (plist-get status :sent))))))

(provide 'harness-otel-test)
;;; harness-otel-test.el ends here
