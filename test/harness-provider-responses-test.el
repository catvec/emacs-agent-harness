;;; harness-provider-responses-test.el --- Tests for the ChatGPT-plan Responses provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; Nothing here talks to OpenAI and nothing here needs a ChatGPT
;; account.  `harness-http-request' is replaced by a fake that records
;; the request and replays canned SSE chunks (or a plain body), and the
;; signed-in account is replaced by a canned `chatgpt-plan/status' and a
;; canned access token.  The suite is about the wire: what the provider
;; puts in a `/v1/responses' body, what it makes of the event stream
;; that comes back, and what it refuses to send at all -- the ChatGPT
;; plan's route rejects several request fields, and one of them
;; (`max_output_tokens') is documented rather than sent.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-responses)

;;;; The fake HTTP layer

(defvar harness-responses-test--requests nil
  "Requests seen by the fake, newest first: (:url :method :headers :json :args).")

(defvar harness-responses-test--responses nil
  "Alist of (URL-REGEXP . RESPONSE) the fake consults.
RESPONSE is (:status N :chunks (STRING…)) for a streamed reply, (:status N
:body STRING) for a plain one, or (:hang t) to answer nothing at all.")

(defvar harness-responses-test--status
  '(:host-id "urn:uuid:x" :active "acct-1" :signed-in t :plan-usage t
    :accounts ((:id "acct-1" :email "a@example.com" :signed-in t :plan-usage t)))
  "What `chatgpt-plan/status' answers in these tests.
A test that wants nobody signed in binds it to nil.")

(defconst harness-responses-test--token "test-access-token"
  "The bearer credential the fake account hands out.
It is a literal, not a credential, and the tests check it goes in the
`Authorization' header and nowhere else.")

(defun harness-responses-test--fake-request (url &rest args)
  "Record a request to URL with ARGS and replay the matching canned response.
A response that is `(:function FN)' is asked for the response to replay,
which lets a test answer differently on each request to the same URL."
  (let* ((response (cdr (cl-find-if (lambda (cell) (string-match-p (car cell) url))
                                    harness-responses-test--responses)))
         (response (if (plist-get response :function)
                       (funcall (plist-get response :function))
                     response))
         (handle (make-harness-http-handle :url url :callback (plist-get args :callback)
                                           :on-chunk (plist-get args :on-chunk)
                                           :started (float-time))))
    (push (list :url url :method (or (plist-get args :method) "GET")
                :headers (plist-get args :headers) :json (plist-get args :json) :args args)
          harness-responses-test--requests)
    (unless (plist-get response :hang)
      (harness-run-soon
       (lambda ()
         (unless (harness-http-handle-cancelled handle)
           (let ((status (or (plist-get response :status) 200)))
             (when (plist-get args :on-headers)
               (funcall (plist-get args :on-headers) status (plist-get response :headers)))
             (dolist (chunk (or (plist-get response :chunks)
                                (and (plist-get response :body) (list (plist-get response :body)))))
               (when (plist-get args :on-chunk) (funcall (plist-get args :on-chunk) chunk)))
             (when (plist-get args :callback)
               (funcall (plist-get args :callback) status nil
                        (or (plist-get response :body) "") nil)))))))
    handle))

(defmacro harness-responses-test-with-fake (responses &rest body)
  "Run BODY with the HTTP layer and the signed-in account faked.
RESPONSES is `harness-responses-test--responses'.  The remembered
responses and the model cache start empty, so nothing a test does
leaks into the next one."
  (declare (indent 1))
  `(let ((harness-responses-test--requests nil)
         (harness-responses-test--responses ,responses)
         (harness-responses-test--status harness-responses-test--status)
         (harness-responses--responses (make-hash-table :test 'equal))
         (harness-responses--models-cache nil)
         (harness-responses--efforts-by-model (make-hash-table :test 'equal))
         (harness-responses--efforts-account nil)
         (harness-provider--quota-status (make-hash-table :test 'eq))
         (auth-sources nil))
     (cl-letf (((symbol-function 'harness-http-request) #'harness-responses-test--fake-request)
               ((symbol-function 'harness-responses--status)
                (lambda () harness-responses-test--status))
               ((symbol-function 'harness-responses--access-token)
                (lambda ()
                  (if harness-responses-test--status
                      (harness-resolved (list :account "acct-1" :label "a@example.com"
                                              :token harness-responses-test--token
                                              :base-url "https://api.openai.com/v1"
                                              :plan-usage t))
                    (harness-rejected
                     (list 'harness-error
                           "No ChatGPT account is signed in: run M-x harness-chatgpt-plan-sign-in"))))))
       ,@body)))

(defmacro harness-responses-test-with-provider (&rest body)
  "Run BODY with the provider's registration cleaned up afterwards."
  (declare (indent 0))
  `(unwind-protect (progn ,@body)
     (harness-provider-unregister 'chatgpt)
     (setq harness-responses--registered nil)))

(defun harness-responses-test--sse (&rest payloads)
  "Return one SSE chunk string holding PAYLOADS (strings or plists)."
  (mapconcat (lambda (p) (format "data: %s\n\n" (if (stringp p) p (harness-json-encode p))))
             payloads ""))

(defun harness-responses-test--complete (request)
  "Run REQUEST through the provider, collecting events; return (EVENTS . HANDLE).
EVENTS are oldest first and end with the `done' event."
  (let* ((events nil)
         (request (plist-put (copy-sequence request) :on-event (lambda (e) (push e events))))
         (handle (harness-responses--complete request)))
    (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type))))
                       5 "done event")
    (cons (reverse events) handle)))

(defun harness-responses-test--types (events)
  "Return the `:type' of every event in EVENTS."
  (mapcar (lambda (e) (plist-get e :type)) events))

(defun harness-responses-test--event (events type)
  "Return the first event of EVENTS whose `:type' is TYPE."
  (cl-find type events :key (lambda (e) (plist-get e :type))))

(defun harness-responses-test--events (events type)
  "Return every event of EVENTS whose `:type' is TYPE."
  (cl-remove-if-not (lambda (e) (eq (plist-get e :type) type)) events))

(defun harness-responses-test--done (events)
  "Return the `done' event of EVENTS."
  (harness-responses-test--event events 'done))

(defun harness-responses-test--last-body ()
  "Return the JSON plist of the most recent request."
  (plist-get (car harness-responses-test--requests) :json))

(defun harness-responses-test--plain (value)
  "Return VALUE with JSON arrays as lists, so it compares as it is written.
The provider builds arrays as vectors (they have to encode as arrays
even when empty); comparing the body is easier when they read as the
lists an expected value is written with."
  (harness-json-parse (harness-json-encode value)))

(defun harness-responses-test--inputs ()
  "Return the `input' of the most recent request as a list."
  (append (plist-get (harness-responses-test--last-body) :input) nil))

(defconst harness-responses-test--refused-keys
  '(:temperature :top_p :max_output_tokens :metadata :moderation :prompt :background
    :conversation :previous_response_id :truncation :user :prompt_cache_retention
    :safety_identifier :max_tool_calls :multi_agent :max_tokens :top_logprobs)
  "Request keys this route refuses, which must never reach the wire.
Each is one OpenAI documents as unsupported for ChatGPT-plan usage
through the Responses API; a body that carried one would fail the whole
request rather than merely be ignored.  `:max_tokens' is the name a
harness request carries the budget under, and it must not reach the
body either, because this route takes no `max_output_tokens'.")

(defun harness-responses-test--streamed-response (&optional overrides)
  "Return the canned completed response of a turn that called `echo'.
OVERRIDES are plists merged into the response, last wins."
  (let ((response (list :id "resp_1" :object "response" :status "completed"
                        :output (list (list :type "reasoning" :id "rs_1" :summary (vector)
                                            :encrypted_content "ENCRYPTED-1")
                                      (list :type "function_call" :id "fc_1" :call_id "call_1"
                                            :name "echo" :arguments "{\"value\":\"a\"}"
                                            :status "completed"))
                        :usage (list :input_tokens 120 :output_tokens 30
                                     :input_tokens_details (list :cached_tokens 64)))))
    (cl-loop for (k v) on overrides by #'cddr do (setq response (plist-put response k v)))
    response))

(defun harness-responses-test--tool-call-events ()
  "Return the chunks of a turn that streams text and calls `echo'.
It is the shape the route really sends: the text and the summary
deltas, then the reasoning item's `done', the call's item and its
arguments, and finally the completed response."
  (list (harness-responses-test--sse
         '(:type "response.created" :response (:id "resp_1"))
         '(:type "response.output_text.delta" :delta "Looking")
         '(:type "response.reasoning_summary_text.delta" :delta "I should read it")
         ;; The reasoning item lands first, as the route reports it, with
         ;; the encrypted content that lets the model resume its thinking.
         '(:type "response.output_item.done" :output_index 0
           :item (:type "reasoning" :id "rs_1"
                        :summary ((:type "summary_text" :text "I should read it"))
                        :encrypted_content "ENCRYPTED-1"))
         '(:type "response.output_item.added" :output_index 1
           :item (:type "function_call" :id "fc_1" :call_id "call_1" :name "echo"))
         '(:type "response.function_call_arguments.delta" :output_index 1 :delta "{\"value\"")
         '(:type "response.function_call_arguments.delta" :output_index 1 :delta ":\"a\"}")
         '(:type "response.function_call_arguments.done" :output_index 1 :arguments "{\"value\":\"a\"}")
         '(:type "response.output_item.done" :output_index 1
           :item (:type "function_call" :id "fc_1" :call_id "call_1" :name "echo"
                        :arguments "{\"value\":\"a\"}" :status "completed"))
         (list :type "response.completed"
               :response (harness-responses-test--streamed-response)))))

;;;; Catalogue capabilities through the agent and serialized request

(ert-deftest harness-provider-responses-catalogue-controls-image-delivery ()
  "Only advertised image input survives the agent's preparation to the wire.
Exercise JSON catalogue parsing, provider normalization/lookup, attachments,
and read_file-style tool results, rather than bypassing the vision gate."
  (require 'harness-agent)
  (let* ((png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7l8AAAAASUVORK5CYII=")
         (image (make-temp-file "harness-responses-delivery-" nil ".png")))
    (unwind-protect
        (progn
          (with-temp-file image
            (set-buffer-multibyte nil)
            (insert (base64-decode-string png)))
          ;; Even a familiar vision model name must not invent capability.
          (dolist (metadata '((:input_modalities ("text" "image"))
                              (:input_modalities ("text"))
                              nil
                              (:input_modalities :null)
                              (:input_modalities [])
                              (:input_modalities :false)
                              (:input_modalities "image")
                              (:input_modalities ("image" 42))))
            (harness-responses-test-with-fake
                `(("/models" . (:body ,(harness-json-encode
                                       (list :models
                                             (vector (append '(:slug "gpt-4o") metadata))))))
                  ("/responses" . (:chunks ("data: [DONE]\n\n"))))
              (harness-responses-test-with-provider
                (harness-responses-refresh)
                (harness-test-await (harness-provider-relist 'chatgpt))
                (let* ((session '(:model "chatgpt:gpt-4o"))
                       (vision (equal metadata '(:input_modalities ("text" "image"))))
                       (model (harness-call 'provider/model "chatgpt:gpt-4o"))
                       (messages
                        `((:role user :content ((:type "image" :path ,image)))
                          (:role assistant :content
                                 ((:type "tool_use" :id "shot" :name "read_file"
                                         :input (:path ,image))))
                          (:role user :content
                                 ((:type "tool_result" :tool_use_id "shot" :content "Screenshot"
                                         :images ((:path ,image :mime "image/png")))))))
                       (prepared (harness-agent--prepare-messages session messages)))
                  (should (equal (plist-get model :input-modalities)
                                 (if vision '("text" "image") '("text"))))
                  (harness-responses-test--complete
                   (list :model "chatgpt:gpt-4o" :messages prepared))
                  ;; Round-trip the actual HTTP request JSON, not a helper's
                  ;; intermediate plist, and compare the delivered bytes.
                  (let* ((body (harness-responses-test--plain
                                (harness-responses-test--last-body)))
                         (items (plist-get body :input))
                         (attachment (car (plist-get (car items) :content)))
                         (result (plist-get (car (last items)) :output)))
                    (should (equal "gpt-4o" (plist-get body :model)))
                    (if vision
                        (progn
                          (should (equal "input_image" (plist-get attachment :type)))
                          (should (equal (concat "data:image/png;base64," png)
                                         (plist-get attachment :image_url)))
                          (should (equal (concat "data:image/png;base64," png)
                                         (plist-get (cadr result) :image_url))))
                      (should (equal "input_text" (plist-get attachment :type)))
                      (should (stringp result))
                      (should (string-match-p "This model does not read images" result))
                      (should-not (string-match-p "data:image" (harness-json-encode body))))))))))
      (delete-file image))))

;;;; Registration

(ert-deftest harness-provider-responses-registers-with-a-credential ()
  "With an account signed in, the plan's provider registers under `chatgpt'."
  (harness-responses-test-with-fake nil
    (harness-responses-test-with-provider
     (should (harness-responses-available-p))
     (should (equal 'chatgpt (harness-responses-refresh)))
     (should harness-responses--registered)
     (let ((provider (harness-provider-get 'chatgpt)))
       (should provider)
       (should (eq 'chatgpt (harness-provider-id provider)))
       (should (equal "ChatGPT plan" (harness-provider-label provider)))
       (should (eq t (plist-get (harness-provider-capabilities provider) :thinking)))
       (should (eq t (plist-get (harness-provider-capabilities provider) :vision)))
       (should (eq t (plist-get (harness-provider-capabilities provider) :quota)))
       ;; The plan's models are the provider's own listing, so the
       ;; tiers are what the setting names rather than a price.
       (should (harness-provider-tiers provider)))
     (should (equal "chatgpt:gpt-5"
                    (plist-get (harness-provider--normalise-model
                                (harness-provider-get 'chatgpt) '(:name "gpt-5"))
                               :id))))))

(ert-deftest harness-provider-responses-is-not-registered-without-a-credential ()
  "Nobody signed in means no provider at all.
The picker then offers no model that could only fail when called."
  (harness-responses-test-with-fake nil
    (harness-responses-test-with-provider
     (harness-responses-refresh)
     (should (harness-provider-get 'chatgpt))
     (let ((harness-responses-test--status nil))
       (should-not (harness-responses-available-p))
       (should-not (harness-responses-refresh))
       (should-not (harness-provider-get 'chatgpt))
       (should-not harness-responses--registered)))))

(ert-deftest harness-provider-responses-status-says-why-it-is-not-usable ()
  "The status names what is missing rather than only that nothing is there."
  (harness-responses-test-with-fake nil
    (harness-responses-test-with-provider
     (let ((harness-responses-test--status nil))
       (harness-responses-refresh)
       (let ((status (harness-responses-status)))
         (should-not (plist-get status :available))
         (should-not (plist-get status :signed-in))
         (should (string-match-p "harness-chatgpt-plan-sign-in" (plist-get status :reason)))))
     (harness-responses-refresh)
     (let ((status (harness-responses-status)))
       (should (plist-get status :available))
       (should (plist-get status :signed-in))
       (should (= 1 (plist-get status :accounts)))
       (should (equal "https://api.openai.com/v1" (plist-get status :base-url)))
       ;; Registered means there is nothing to complain about.
       (should-not (plist-get status :reason))))))

;;;; The request body

(ert-deftest harness-provider-responses-body-uses-instructions-and-omits-refused-keys ()
  "The system prompt goes in `instructions'; the route's refused fields are absent.
Every one of them is a field the ChatGPT-plan route rejects outright,
so a body that carried one would fail the whole request rather than
merely be ignored."
  (harness-responses-test-with-fake
      '(("/responses" . (:chunks ("data: [DONE]\n\n"))))
    (harness-responses-test--complete
     `(:model "chatgpt:gpt-5" :system "Be terse." :thinking "medium" :max-tokens 321
       :messages ((:role user :content ((:type "text" :text "hi"))))))
    (let ((body (harness-responses-test--last-body)))
      (should (equal "gpt-5" (plist-get body :model)))
      (should (equal "Be terse." (plist-get body :instructions)))
      ;; `store: false' and `stream: true' are required, not optional.
      (should (eq :false (plist-get body :store)))
      (should (eq t (plist-get body :stream)))
      (should (equal ["reasoning.encrypted_content"] (plist-get body :include)))
      ;; Thinking of medium is asked for as an effort, with a summary,
      ;; which is what reaches the chat as thinking.
      (should (equal '(:effort "medium" :summary "auto") (plist-get body :reasoning)))
      (dolist (key harness-responses-test--refused-keys)
        (should-not (plist-member body key)))
      ;; The budget is dropped, not faked: this route takes no cap.
      (should-not (plist-member body :max-tokens)))))

(ert-deftest harness-provider-responses-body-folds-a-system-message-into-instructions ()
  "A system message among the messages is instructions, not an input item.
The route rejects `{type: \"message\", role: \"system\"}' items, so one
that arrives that way has to be lifted instead of sent."
  (harness-responses-test-with-fake
      '(("/responses" . (:chunks ("data: [DONE]\n\n"))))
    (harness-responses-test--complete
     '(:model "chatgpt:gpt-5"
       :messages ((:role system :content "You are careful.")
                  (:role user :content ((:type "text" :text "hi"))))))
    (let ((body (harness-responses-test--last-body))
          (inputs (harness-responses-test--inputs)))
      (should (equal "You are careful." (plist-get body :instructions)))
      (should (= 1 (length inputs)))
      (should (equal '(:role "user" :content ((:type "input_text" :text "hi")))
                     (harness-responses-test--plain (car inputs)))))))

(ert-deftest harness-provider-responses-body-sends-tools-as-additional-tools ()
  "Tools go as one `additional_tools' developer item, keeping each tool's own name.
The other documented form, a namespace in `tools', would rename every
call, which the harness's own tool loop cannot follow."
  (harness-responses-test-with-fake
      '(("/responses" . (:chunks ("data: [DONE]\n\n"))))
    (harness-responses-test--complete
     `(:model "chatgpt:gpt-5"
       :tools ((:name "echo" :description "Echo it."
                :schema (:type "object" :properties (:value (:type "string"))
                         :required ("value")))
               (:name "noop"))
       :messages ((:role user :content ((:type "text" :text "hi"))))))
    (let* ((inputs (harness-responses-test--inputs))
           (item (car inputs)))
      (should (equal "additional_tools" (plist-get item :type)))
      (should (equal "developer" (plist-get item :role)))
      (should (equal '((:type "function" :name "echo" :description "Echo it."
                        :strict :false
                        :parameters (:type "object" :properties (:value (:type "string"))
                                     :required ("value")))
                       (:type "function" :name "noop" :description ""
                        :strict :false
                        :parameters (:type "object" :properties :empty)))
                     (append (plist-get item :tools) nil)))
      ;; Nothing is sent in the top-level `tools' beside the item.
      (should-not (plist-member (harness-responses-test--last-body) :tools)))))

(ert-deftest harness-provider-responses-body-carries-the-whole-history ()
  "Every request carries the whole conversation: there is no server state here.
Nothing is stored (`store: false'), so a request that sent only the new
message would arrive with no context at all."
  (harness-responses-test-with-fake
      '(("/responses" . (:chunks ("data: [DONE]\n\n"))))
    (harness-responses-test--complete
     `(:model "chatgpt:gpt-5" :system "Be terse."
       :messages ((:role user :content ((:type "text" :text "look")))
                  (:role assistant :content ((:type "text" :text "calling")
                                             (:type "tool_use" :id "call_1" :name "echo"
                                              :input (:value "a"))))
                  (:role tool :content ((:type "tool_result" :tool_use_id "call_1"
                                        :content "a!")))
                  (:role user :content ((:type "text" :text "and now?"))))))
    (let ((body (harness-responses-test--last-body))
          (inputs (harness-responses-test--inputs)))
      (should-not (plist-member body :previous_response_id))
      ;; user, assistant text, function_call, function_call_output, user
      (should (equal '(:role "user" :content ((:type "input_text" :text "look")))
                     (harness-responses-test--plain (nth 0 inputs))))
      (should (equal '(:role "assistant" :content ((:type "output_text" :text "calling")))
                     (harness-responses-test--plain (nth 1 inputs))))
      (should (equal '(:type "function_call" :call_id "call_1" :name "echo"
                       :arguments "{\"value\":\"a\"}")
                     (harness-responses-test--plain (nth 2 inputs))))
      (should (equal '(:type "function_call_output" :call_id "call_1" :output "a!")
                     (harness-responses-test--plain (nth 3 inputs))))
      (should (equal '(:role "user" :content ((:type "input_text" :text "and now?")))
                     (harness-responses-test--plain (nth 4 inputs))))
      (should (= 5 (length inputs))))))

(ert-deftest harness-provider-responses-body-drops-thinking-without-a-signature ()
  "A thinking block with no encrypted content is left out, not sent as empty reasoning.
With `store: false' only the encrypted content lets the model resume
its own reasoning, so a reasoning item without one is noise at best."
  (harness-responses-test-with-fake
      '(("/responses" . (:chunks ("data: [DONE]\n\n"))))
    (harness-responses-test--complete
     `(:model "chatgpt:gpt-5"
       :messages ((:role user :content ((:type "text" :text "go")))
                  (:role assistant :content ((:type "thinking" :text "hmm")
                                             (:type "text" :text "done"))))))
    (let ((inputs (harness-responses-test--inputs)))
      (should (= 2 (length inputs)))
      (should-not (cl-find "reasoning" inputs :key (lambda (i) (plist-get i :type)) :test #'equal))
      (should (equal '(:role "assistant" :content ((:type "output_text" :text "done")))
                     (harness-responses-test--plain (nth 1 inputs)))))))

(ert-deftest harness-provider-responses-body-replays-remembered-reasoning ()
  "A remembered tool call goes back exactly as it arrived, reasoning included.
The response's own output items are kept under the call ids they made,
so the second turn resends the reasoning item with its encrypted
content and the model keeps the chain of thought it had."
  (harness-responses-test-with-fake
      `(("/responses" . (:chunks ,(harness-responses-test--tool-call-events))))
    ;; The first turn calls `echo' and its reasoning is remembered.
    (harness-responses-test--complete
     `(:model "chatgpt:gpt-5" :system "Be terse."
       :messages ((:role user :content ((:type "text" :text "look"))))))
    (should (= 1 (hash-table-count harness-responses--responses)))
    ;; The second turn answers that call.
    (harness-responses-test--complete
     `(:model "chatgpt:gpt-5" :system "Be terse."
       :messages ((:role user :content ((:type "text" :text "look")))
                  (:role assistant :content ((:type "tool_use" :id "call_1" :name "echo"
                                              :input (:value "a"))))
                  (:role tool :content ((:type "tool_result" :tool_use_id "call_1"
                                        :content "a!"))))))
    (let ((inputs (harness-responses-test--inputs)))
      ;; user, reasoning, function_call, function_call_output
      (should (= 4 (length inputs)))
      (should (equal '(:role "user" :content ((:type "input_text" :text "look")))
                     (harness-responses-test--plain (nth 0 inputs))))
      (let ((reasoning (nth 1 inputs)))
        (should (equal "reasoning" (plist-get reasoning :type)))
        (should (equal "ENCRYPTED-1" (plist-get reasoning :encrypted_content)))
        (should (equal "I should read it"
                       (plist-get (car (plist-get reasoning :summary)) :text))))
      ;; The call goes back as it arrived, its own id included.
      (should (equal '(:type "function_call" :id "fc_1" :call_id "call_1" :name "echo"
                       :arguments "{\"value\":\"a\"}")
                     (harness-responses-test--plain (nth 2 inputs))))
      ;; The lifecycle status is a response's bookkeeping and is dropped.
      (should-not (plist-member (nth 2 inputs) :status)))))

(ert-deftest harness-provider-responses-replays-empty-reasoning-summary-as-array ()
  "An empty summary survives parsing and replay as an array on the wire."
  (harness-responses-test-with-fake
      `(("/responses" . (:chunks
                          (,(harness-responses-test--sse
                             (list :type "response.completed"
                                   :response (harness-responses-test--streamed-response)))))))
    (harness-responses-test--complete
     '(:model "chatgpt:gpt-5" :messages ((:role user :content "go"))))
    (harness-responses-test--complete
     '(:model "chatgpt:gpt-5"
       :messages ((:role user :content "go")
                  (:role assistant :content ((:type "tool_use" :id "call_1"
                                              :name "echo" :input (:value "a"))))
                  (:role tool :content ((:type "tool_result" :tool_use_id "call_1"
                                         :content "a!"))))))
    (let* ((json (harness-json-encode (harness-responses-test--last-body)))
           (body (json-parse-string json :object-type 'plist :array-type 'array))
           (reasoning (aref (plist-get body :input) 1)))
      (should (equal "reasoning" (plist-get reasoning :type)))
      (should (equal [] (plist-get reasoning :summary)))
      (should (equal "ENCRYPTED-1" (plist-get reasoning :encrypted_content))))))

(ert-deftest harness-provider-responses-replays-empty-annotations-as-array ()
  "An empty annotations list survives parsing and replay as an array on the wire.
The completed response's message content part carries `annotations: []',
which JSON parsing maps to nil; the route rejects the null it would
otherwise encode and names that content part in the error."
  (let* ((output (list (list :type "reasoning" :id "rs_1"
                             :summary (vector)
                             :encrypted_content "ENCRYPTED-1")
                       (list :type "message" :id "msg_1"
                             :role "assistant" :status "completed"
                             :content
                             (vector
                              (list :type "output_text"
                                    :text "Looking"
                                    :annotations (vector)
                                    :logprobs (vector))))
                       (list :type "function_call" :id "fc_1"
                             :call_id "call_1" :name "echo"
                             :arguments "{\"value\":\"a\"}"
                             :status "completed")))
         (event (harness-responses-test--sse
                 (list :type "response.completed"
                       :response (harness-responses-test--streamed-response
                                  (list :output output))))))
    (harness-responses-test-with-fake
        `(("/responses" . (:chunks (,event))))
      (harness-responses-test--complete
       '(:model "chatgpt:gpt-5" :messages ((:role user :content "go"))))
      (harness-responses-test--complete
       '(:model "chatgpt:gpt-5"
         :messages ((:role user :content "go")
                    (:role assistant :content ((:type "tool_use" :id "call_1"
                                                :name "echo" :input (:value "a"))))
                    (:role tool :content ((:type "tool_result" :tool_use_id "call_1"
                                           :content "a!"))))))
      (let* ((json (harness-json-encode (harness-responses-test--last-body)))
             (body (json-parse-string json :object-type 'plist :array-type 'array))
             (message (cl-find "message" (append (plist-get body :input) nil)
                               :key (lambda (item) (plist-get item :type)) :test #'equal))
             (part (and message (aref (plist-get message :content) 0))))
        (should message)
        (should (equal [] (plist-get part :annotations)))
        (should (equal [] (plist-get part :logprobs)))))))

(ert-deftest harness-provider-responses-body-rebuilds-a-half-remembered-message ()
  "A message only half remembered is rebuilt, not sent as a mixture.
Sending some of the response's items and making up the rest would tell
the model a story that never happened."
  (harness-responses-test-with-fake
      `(("/responses" . (:chunks ,(harness-responses-test--tool-call-events))))
    (harness-responses-test--complete
     `(:model "chatgpt:gpt-5" :messages ((:role user :content ((:type "text" :text "go"))))))
    (harness-responses-test--complete
     `(:model "chatgpt:gpt-5"
       :messages ((:role user :content ((:type "text" :text "go")))
                  (:role assistant :content ((:type "thinking" :text "hmm" :signature "SIG")
                                             (:type "tool_use" :id "call_1" :name "echo"
                                              :input (:value "a"))
                                             (:type "tool_use" :id "call_2" :name "noop"
                                              :input nil))))))
    (let ((inputs (harness-responses-test--inputs)))
      ;; call_2 was never remembered, so the whole message is rebuilt
      ;; from the blocks: a reasoning item from the signature, then both
      ;; calls, and nothing replayed from the response.
      (should (equal "reasoning" (plist-get (nth 1 inputs) :type)))
      (should (equal "SIG" (plist-get (nth 1 inputs) :encrypted_content)))
      (should (equal '("call_1" "call_2")
                     (mapcar (lambda (i) (plist-get i :call_id)) (nthcdr 2 inputs)))))))

(ert-deftest harness-provider-responses-reasoning-effort-follows-the-level ()
  "A thinking level becomes an effort; no thinking asks for none; an unknown level is the default.
The summary is what the chat shows as thinking, so it is asked for
whenever reasoning is not off."
  (harness-responses-test-with-fake nil
    (should (equal '(:effort "high" :summary "auto")
                   (harness-responses--reasoning '(:thinking "high"))))
    (should (equal '(:effort "none") (harness-responses--reasoning '(:no-thinking t))))
    (should (equal '(:summary "auto") (harness-responses--reasoning '(:thinking "not-a-level"))))
    (should (equal '(:summary "auto") (harness-responses--reasoning nil)))
    (should (equal "max" (harness-responses--effort "max")))
    (should-not (harness-responses--effort "ultra"))))

(ert-deftest harness-provider-responses-efforts-follow-the-model ()
  "A model's own efforts decide which reasoning effort a request asks for.
The documented models carry what their model page says; a model the
catalogue does not know offers `low' through `max', the ladder every
reasoning model of this generation takes.  No request asks for a value
the model rejects: `none' becomes the weakest effort a model without an
off switch takes, and an effort above a model's ceiling becomes the
ceiling."
  (harness-responses-test-with-fake nil
    (should (equal '("low" "medium" "high" "xhigh" "max")
                   (harness-responses--model-efforts "gpt-6-astra")))
    (should (equal '("none" "low" "medium" "high" "xhigh" "max")
                   (harness-responses--model-efforts "gpt-6-sol")))
    (should (equal '("none" "low" "medium" "high" "xhigh")
                   (harness-responses--model-efforts "gpt-5.5")))
    (should (equal '("minimal" "low" "medium" "high")
                   (harness-responses--model-efforts "gpt-5")))
    (should (equal '("low" "medium" "high" "xhigh" "max")
                   (harness-responses--model-efforts "an-unlisted-model")))
    ;; GPT-6 Astra takes no `none'; its least thinking is `low'.
    (should (equal '(:effort "low")
                   (harness-responses--reasoning
                    '(:no-thinking t) (harness-responses--model-efforts "gpt-6-astra"))))
    ;; A model with an off switch still gets it.
    (should (equal '(:effort "none")
                   (harness-responses--reasoning
                    '(:no-thinking t) (harness-responses--model-efforts "gpt-6-sol"))))
    ;; max survives where the model takes it, and is lowered where it does not.
    (should (equal '(:effort "max" :summary "auto")
                   (harness-responses--reasoning
                    '(:thinking "max") (harness-responses--model-efforts "gpt-6-astra"))))
    (should (equal '(:effort "xhigh" :summary "auto")
                   (harness-responses--reasoning
                    '(:thinking "max") (harness-responses--model-efforts "gpt-5.5"))))
    ;; minimal is not offered by Astra; low is the nearest it takes.
    (should (equal '(:effort "low" :summary "auto")
                   (harness-responses--reasoning
                    '(:thinking "minimal") (harness-responses--model-efforts "gpt-6-astra"))))
    ;; A model the listing has not named still says which levels it offers,
    ;; so a sub-agent's level is checked against what the model really takes.
    (should (equal '("low" "medium" "high" "xhigh" "max")
                   (plist-get (harness-responses--resolve "gpt-6-astra") :thinking-levels)))
    (should-not (harness-responses--resolve ""))))

(ert-deftest harness-provider-responses-body-asks-for-an-effort-the-model-takes ()
  "The body of a no-thinking request carries an effort the model takes.
GPT-6 Astra rejects `none', and a naming or judge request on it failed
with HTTP 400 before the body was fitted to the model."
  (harness-responses-test-with-fake nil
    (let ((request '(:no-thinking t
                     :messages ((:role user :content ((:type "text" :text "hi")))))))
      (should (equal '(:effort "low")
                     (plist-get (harness-responses--body "gpt-6-astra" request) :reasoning)))
      (should (equal '(:effort "none")
                     (plist-get (harness-responses--body "gpt-6-sol" request) :reasoning)))
      ;; An unknown model gets the safe ladder, not `none'.
      (should (equal '(:effort "low")
                     (plist-get (harness-responses--body "an-unlisted-model" request) :reasoning))))
    (should (equal '(:effort "max" :summary "auto")
                   (plist-get (harness-responses--body
                               "gpt-6-astra"
                               '(:thinking "max"
                                 :messages ((:role user :content ((:type "text" :text "hi"))))))
                              :reasoning)))))

(ert-deftest harness-provider-responses-models-take-the-efforts-they-advertise ()
  "The account's list can name a model's efforts as objects or as strings.
They win over the documented table, and are ordered weakest first as
the harness's thinking levels are."
  (harness-responses-test-with-fake nil
    (let ((harness-responses--efforts-by-model (make-hash-table :test 'equal)))
      (let ((model (harness-responses--entry-model
                    '(:slug "gpt-6-astra" :visibility "list"
                      :supported_reasoning_levels ((:effort "max" :description "Most")
                                                   (:effort "low" :description "Least"))))))
        (should (equal '("low" "max") (plist-get model :thinking-levels))))
      (let ((model (harness-responses--entry-model
                    '(:slug "gpt-5.6-luna" :visibility "list"
                      :supported_reasoning_efforts ["max" "none" "high" "low"]))))
        (should (equal '("none" "low" "high" "max") (plist-get model :thinking-levels)))))))

(ert-deftest harness-provider-responses-asks-again-with-an-effort-the-model-takes ()
  "A model that refuses an effort is asked once more with one it takes.
The values its answer names are remembered for later requests, so a
new model needs to say once what it supports."
  (let ((sent 0))
    (harness-responses-test-with-fake
        `(("/responses"
           . (:function
              ,(lambda ()
                 (if (= 1 (cl-incf sent))
                     (list :status 400
                           :body (harness-json-encode
                                  '(:error
                                    (:message "Unsupported value: 'max' is not supported with the 'mystery-model' model. Supported values are: 'low', 'medium', 'high'."
                                     :type "invalid_request_error" :param "reasoning.effort"
                                     :code "unsupported_value"))))
                   (list :chunks
                         (list (harness-responses-test--sse
                                (list :type "response.completed"
                                      :response (list :id "resp_1" :status "completed"
                                                      :output []
                                                      :usage (list :input_tokens 9 :output_tokens 2)))))))))))
      (let* ((events (car (harness-responses-test--complete
                           '(:model "chatgpt:mystery-model" :thinking "max"
                             :messages ((:role user :content ((:type "text" :text "hi"))))))))
             (requests (reverse harness-responses-test--requests)))
        (should (equal 2 (length requests)))
        (should (equal '(:effort "max" :summary "auto")
                       (plist-get (plist-get (car requests) :json) :reasoning)))
        (should (equal '(:effort "high" :summary "auto")
                       (plist-get (plist-get (cadr requests) :json) :reasoning)))
        (should (eq 'end-turn (plist-get (harness-responses-test--done events) :stop-reason)))
        (should (equal '("low" "medium" "high")
                       (harness-responses--model-efforts "mystery-model")))))))

(ert-deftest harness-provider-responses-learns-what-a-model-takes-when-it-refuses-none ()
  "A model whose table entry is wrong is corrected by its own answer.
GPT-6 Sol is documented to take `none'; a server that refuses it names
`low' through `max', and the request is sent again with `low' rather
than failing the turn."
  (let ((sent 0))
    (harness-responses-test-with-fake
        `(("/responses"
           . (:function
              ,(lambda ()
                 (if (= 1 (cl-incf sent))
                     (list :status 400
                           :body (harness-json-encode
                                  '(:error
                                    (:message "Unsupported value: 'none' is not supported with the 'gpt-6-sol' model. Supported values are: 'low', 'medium', 'high', 'xhigh', and 'max'."
                                     :type "invalid_request_error" :param "reasoning.effort"
                                     :code "unsupported_value"))))
                   (list :chunks
                         (list (harness-responses-test--sse
                                (list :type "response.completed"
                                      :response (list :id "resp_1" :status "completed"
                                                      :output []
                                                      :usage (list :input_tokens 9 :output_tokens 2)))))))))))
      (let* ((events (car (harness-responses-test--complete
                           '(:model "chatgpt:gpt-6-sol" :no-thinking t
                             :messages ((:role user :content ((:type "text" :text "hi"))))))))
             (requests (reverse harness-responses-test--requests)))
        (should (equal 2 (length requests)))
        (should (equal '(:effort "none")
                       (plist-get (plist-get (car requests) :json) :reasoning)))
        (should (equal '(:effort "low")
                       (plist-get (plist-get (cadr requests) :json) :reasoning)))
        (should (eq 'end-turn (plist-get (harness-responses-test--done events) :stop-reason)))
        (should (equal '("low" "medium" "high" "xhigh" "max")
                       (harness-responses--model-efforts "gpt-6-sol")))))))

;;;; The event stream

(ert-deftest harness-provider-responses-streams-text-thinking-and-a-tool-call ()
  "The SSE stream maps onto the harness's events in the order the loop needs.
Text and thinking reach the chat as they stream, a long tool input is
visible as activity, and the tool call goes out once the response says
it is complete."
  (harness-responses-test-with-fake
      `(("/responses" . (:chunks ,(harness-responses-test--tool-call-events))))
    (let* ((events (car (harness-responses-test--complete
                         `(:model "chatgpt:gpt-5" :thinking "medium" :tools ((:name "echo"))
                           :messages ((:role user :content ((:type "text" :text "go"))))))))
           (done (harness-responses-test--done events))
           (call (harness-responses-test--event events 'tool-call)))
      (should (equal 'start (car (harness-responses-test--types events))))
      (should (equal 'done (car (last (harness-responses-test--types events)))))
      (should (equal "Looking"
                     (plist-get (harness-responses-test--event events 'text) :delta)))
      (should (equal "I should read it"
                     (plist-get (harness-responses-test--event events 'thinking) :delta)))
      ;; A tool call's arguments streaming in is reported as activity,
      ;; which is all that shows a model writing a large input.
      (should (harness-responses-test--events events 'activity))
      (should (eq 'tool-input (plist-get (harness-responses-test--event events 'activity) :phase)))
      ;; The call is complete, with its arguments parsed.
      (should (equal "call_1" (plist-get call :id)))
      (should (equal "echo" (plist-get call :name)))
      (should (equal '(:value "a") (plist-get call :input)))
      (should-not (plist-get call :respond))
      (should (eq 'tool-use (plist-get done :stop-reason)))
      (should-not (plist-get done :error)))))

(ert-deftest harness-provider-responses-usage-is-a-subscription-with-no-cost ()
  "A plan-covered call is recorded as subscription billing at cost zero.
This route lists no prices, so nothing is invented: the session prices
the record from the catalogue, and a plan-covered call is free either way."
  (harness-responses-test-with-fake
      `(("/responses" . (:chunks ,(harness-responses-test--tool-call-events))))
    (let* ((events (car (harness-responses-test--complete
                         `(:model "chatgpt:gpt-5"
                           :messages ((:role user :content ((:type "text" :text "go"))))))))
           (usage (harness-responses-test--event events 'usage)))
      (should (eq 'subscription (plist-get usage :billing)))
      (should (= 0.0 (plist-get usage :cost)))
      (should (= 120 (plist-get usage :input)))
      (should (= 30 (plist-get usage :output)))
      (should (= 64 (plist-get usage :cache-read)))
      (should (= 184 (plist-get usage :context))))))

(ert-deftest harness-provider-responses-completed-without-a-call-ends-the-turn ()
  "A response that called nothing ends the turn, having streamed its text."
  (harness-responses-test-with-fake
      `(("/responses" . (:chunks (,(harness-responses-test--sse
                                    '(:type "response.output_text.delta" :delta "Hello")
                                    (list :type "response.completed"
                                          :response (list :usage (list :input_tokens 5 :output_tokens 1))))))))
    (let* ((events (car (harness-responses-test--complete
                         `(:model "chatgpt:gpt-5"
                           :messages ((:role user :content ((:type "text" :text "hi"))))))))
           (done (harness-responses-test--done events)))
      (should (equal "Hello" (plist-get (harness-responses-test--event events 'text) :delta)))
      (should (eq 'end-turn (plist-get done :stop-reason)))
      (should-not (harness-responses-test--event events 'tool-call)))))

(ert-deftest harness-provider-responses-failed-maps-the-structured-code ()
  "`response.failed' is an error whose kind comes from the route's own code.
The kind is what the harness decides on: a plan limit pauses the
provider, an ineligible account says to look at the credential, and a
wrong body says trying again would not help."
  (harness-responses-test-with-fake
      `(("/responses" . (:chunks (,(harness-responses-test--sse
                                    '(:type "response.failed"
                                      :response (:id "resp_1" :status "failed"
                                                 :error (:code "subscription_sharing_usage_limit_exceeded"
                                                         :message "The plan's limit was reached"))))))))
    (let* ((events (car (harness-responses-test--complete
                         `(:model "chatgpt:gpt-5"
                           :messages ((:role user :content ((:type "text" :text "hi"))))))))
           (done (harness-responses-test--done events)))
      (should (eq 'error (plist-get done :stop-reason)))
      (should (eq 'quota (plist-get done :error-kind)))
      (should (string-match-p "subscription_sharing_usage_limit_exceeded" (plist-get done :error)))
      (should (string-match-p "The plan's limit was reached" (plist-get done :error))))))

(ert-deftest harness-provider-responses-error-kinds ()
  "Every documented code, and the statuses, map to the harness's kinds."
  (dolist (case '(("subscription_sharing_usage_limit_exceeded" nil . quota)
                  ("subscription_sharing_user_not_eligible" nil . auth)
                  ("subscription_sharing_usage_unavailable" nil . transport)
                  ("subscription_sharing_unsupported_capability" nil . request)
                  ("subscription_sharing_route_not_supported" nil . request)
                  ("invalid_user" nil . auth)
                  (nil 401 . auth)
                  (nil 403 . auth)
                  (nil 402 . billing)
                  (nil 429 . rate-limit)
                  (nil 503 . transport)
                  (nil 400 . nil)))
    (should (eq (cddr case) (harness-responses-error-kind (car case) (cadr case))))))

(ert-deftest harness-provider-responses-pre-stream-error-reads-the-detail ()
  "A failure before the stream opens is an error event, code or status or detail.
This route may answer with the usual error object or with a bare
`detail' string before the stream begins, and both are read."
  (harness-responses-test-with-fake
      '(("/responses" . (:status 429
                        :body "{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"slow down\"}}"))
        ("/models" . (:status 200 :body "{}")))
    (let* ((events (car (harness-responses-test--complete
                         `(:model "chatgpt:gpt-5"
                           :messages ((:role user :content ((:type "text" :text "hi"))))))))
           (done (harness-responses-test--done events)))
      (should (eq 'error (plist-get done :stop-reason)))
      (should (eq 'quota (plist-get done :error-kind)))
      (should (string-match-p "slow down" (plist-get done :error)))))
  ;; A bare `detail' string, with no code, takes its kind from the status.
  (harness-responses-test-with-fake
      '(("/responses" . (:status 503 :body "{\"detail\":\"the upstream is unwell\"}")))
    (let* ((events (car (harness-responses-test--complete
                         `(:model "chatgpt:gpt-5"
                           :messages ((:role user :content ((:type "text" :text "hi"))))))))
           (done (harness-responses-test--done events)))
      (should (eq 'error (plist-get done :stop-reason)))
      (should (eq 'transport (plist-get done :error-kind)))
      (should (string-match-p "the upstream is unwell" (plist-get done :error))))))

(ert-deftest harness-provider-responses-incomplete-says-why ()
  "An incomplete response is an answer that stopped short, and why it did matters.
A cut at the model's own ceiling is `max-tokens' (which the harness can
act on); a content filter is an error; anything else simply ended."
  (dolist (case '(("max_output_tokens" . max-tokens)
                  ("content_filter" . error)
                  ("some_other_reason" . end-turn)))
    (harness-responses-test-with-fake
        `(("/responses" . (:chunks (,(harness-responses-test--sse
                                      (list :type "response.incomplete"
                                            :response (list :incomplete_details
                                                            (list :reason (car case)))))))))
      (let* ((events (car (harness-responses-test--complete
                           `(:model "chatgpt:gpt-5"
                             :messages ((:role user :content ((:type "text" :text "hi"))))))))
             (done (harness-responses-test--done events)))
        (should (eq (cdr case) (plist-get done :stop-reason)))))))

(ert-deftest harness-provider-responses-a-stream-without-a-terminal-event-is-an-error ()
  "A connection cut in the middle is not an answer, however much text arrived.
OpenAI's own example checks for a terminal event before treating
inference as successful, and so does this provider."
  (harness-responses-test-with-fake
      `(("/responses" . (:chunks (,(harness-responses-test--sse
                                    '(:type "response.output_text.delta" :delta "partial"))))))
    (let* ((events (car (harness-responses-test--complete
                         `(:model "chatgpt:gpt-5"
                           :messages ((:role user :content ((:type "text" :text "hi"))))))))
           (done (harness-responses-test--done events)))
      (should (equal "partial" (plist-get (harness-responses-test--event events 'text) :delta)))
      (should (eq 'error (plist-get done :stop-reason)))
      (should (eq 'transport (plist-get done :error-kind)))
      (should (string-match-p "response.completed" (plist-get done :error))))))

(ert-deftest harness-provider-responses-an-error-event-is-an-error ()
  "A bare `error' event on the stream ends the request with its code."
  (harness-responses-test-with-fake
      `(("/responses" . (:chunks (,(harness-responses-test--sse
                                    '(:type "error" :code "server_error" :message "boom"))))))
    (let* ((events (car (harness-responses-test--complete
                         `(:model "chatgpt:gpt-5"
                           :messages ((:role user :content ((:type "text" :text "hi"))))))))
           (done (harness-responses-test--done events)))
      (should (eq 'error (plist-get done :stop-reason)))
      (should (eq 'transport (plist-get done :error-kind)))
      (should (string-match-p "boom" (plist-get done :error))))))

(ert-deftest harness-provider-responses-nested-error-event-keeps-its-code-and-kind ()
  "The stream's `error' event nests the real code and message under `error'.
Reading only the top level turned the account's quota refusal into an
unexplained \"the request failed\", which the provider check reported as
a contract failure and the fallback could not classify."
  (harness-responses-test-with-fake
      `(("/responses"
         . (:chunks
            (,(harness-responses-test--sse
               '(:type "error"
                 :sequence_number 3
                 :error (:type "invalid_request_error"
                         :param :null
                         :code "subscription_sharing_usage_limit_exceeded"
                         :message "The ChatGPT user has reached their Subscription Sharing usage limit.")))))))
    (let* ((events (car (harness-responses-test--complete
                         `(:model "chatgpt:gpt-6-astra"
                           :messages ((:role user :content ((:type "text" :text "hi"))))))))
           (done (harness-responses-test--done events)))
      (should (eq 'error (plist-get done :stop-reason)))
      (should (eq 'quota (plist-get done :error-kind)))
      (should (string-match-p "subscription_sharing_usage_limit_exceeded"
                              (plist-get done :error)))
      (should (string-match-p "Subscription Sharing usage limit"
                              (plist-get done :error))))))

(ert-deftest harness-provider-responses-nested-error-wins-over-a-top-level-one ()
  "A nested error object is the route's own; a top-level copy does not hide it."
  (harness-responses-test-with-fake
      `(("/responses"
         . (:chunks
            (,(harness-responses-test--sse
               '(:type "error"
                 :code "server_error"
                 :message "outer"
                 :error (:code "subscription_sharing_user_not_eligible"
                         :message "inner")))))))
    (let* ((events (car (harness-responses-test--complete
                         `(:model "chatgpt:gpt-5"
                           :messages ((:role user :content ((:type "text" :text "hi"))))))))
           (done (harness-responses-test--done events)))
      (should (eq 'auth (plist-get done :error-kind)))
      (should (string-match-p "subscription_sharing_user_not_eligible"
                              (plist-get done :error)))
      (should (string-match-p "inner" (plist-get done :error)))
      (should-not (string-match-p "outer" (plist-get done :error))))))

(ert-deftest harness-provider-responses-cancel-ends-the-request-once ()
  "Cancelling a request in flight ends it as cancelled, and only once."
  (harness-responses-test-with-fake
      '(("/responses" . (:hang t)))
    (let* ((events nil)
           (handle (harness-responses--complete
                    (list :model "chatgpt:gpt-5"
                          :messages '((:role user :content ((:type "text" :text "hi"))))
                          :on-event (lambda (e) (push e events)))))
           (done nil))
      ;; A request that has not answered is neither finished nor cancelled.
      (should (plist-get handle :cancel))
      (should (cl-find 'start events :key (lambda (e) (plist-get e :type))))
      (cl-letf (((symbol-function 'harness-http-cancel) #'ignore))
        (funcall (plist-get handle :cancel))
        (funcall (plist-get handle :cancel)))
      (setq done (harness-responses-test--event events 'done))
      (should done)
      (should (eq 'cancelled (plist-get done :stop-reason)))
      (should (= 1 (length (harness-responses-test--events events 'done)))))))

(ert-deftest harness-provider-responses-unparsable-tool-arguments-are-kept-raw ()
  "Arguments the model made unparsable do not lose the request.
The raw text is kept so that a caller can see what the model actually
wrote instead of the call being dropped."
  (let* ((call-item (list :type "function_call" :id "fc_1" :call_id "call_1"
                          :name "echo" :arguments "{not json"))
         (chunk (harness-responses-test--sse
                 (list :type "response.output_item.added" :output_index 0 :item call-item)
                 (list :type "response.function_call_arguments.done"
                       :output_index 0 :arguments "{not json")
                 (list :type "response.completed"
                       :response (list :output (list call-item))))))
    (harness-responses-test-with-fake
        (list (cons "/responses" (list :chunks (list chunk))))
      (let* ((events (car (harness-responses-test--complete
                           `(:model "chatgpt:gpt-5" :tools ((:name "echo"))
                             :messages ((:role user :content ((:type "text" :text "go"))))))))
             (call (harness-responses-test--event events 'tool-call)))
        (should (equal "{not json" (harness-plist-get-in call '(:input :raw))))))))

(ert-deftest harness-provider-responses-images-go-as-input-image-parts ()
  "An image is an `input_image' part, from disk or from data already read.
The route takes images inline; a block whose file cannot be read
becomes a note rather than failing the whole request."
  (let* ((img (make-temp-file "harness-responses-img" nil ".png"))
         (_ (with-temp-file img (set-buffer-multibyte nil) (insert "\211PNG\r\n"))))
    (harness-responses-test-with-fake
        `(("/responses" . (:chunks ,(harness-responses-test--tool-call-events))))
      (harness-responses-test--complete
       `(:model "chatgpt:gpt-5"
         :messages ((:role user :content ((:type "text" :text "look")
                                          (:type "image" :path ,img)
                                          (:type "image" :mime "image/jpeg" :data "QUJD")
                                          (:type "image" :path "/nonexistent/x.png")
                                          (:type "file" :path "/tmp/report.pdf"))))))
      (let ((parts (harness-responses-test--plain
                    (plist-get (car (harness-responses-test--inputs)) :content))))
        (should (equal '(:type "input_text" :text "look") (nth 0 parts)))
        (should (equal (format "data:image/png;base64,%s" (base64-encode-string "\211PNG\r\n" t))
                       (plist-get (nth 1 parts) :image_url)))
        (should (equal "data:image/jpeg;base64,QUJD" (plist-get (nth 2 parts) :image_url)))
        (should (equal "[an image could not be read]" (plist-get (nth 3 parts) :text)))
        ;; The Files upload API is unsupported here, so a file is named.
        (should (equal "[attached file: /tmp/report.pdf]" (plist-get (nth 4 parts) :text)))))))

(ert-deftest harness-provider-responses-tool-result-images-stay-in-the-result ()
  "Images a tool returned are sent inside the function_call_output item.
The OpenAI-compatible provider has to lift them into a following user
message; this route takes them where the result belongs."
  (let ((block (list :type "tool_result" :tool_use_id "call_1" :content "shot"
                     :images (list (list :type "image" :mime "image/png" :data "QUJD")))))
    (let ((output (harness-responses-test--plain (harness-responses--tool-output block))))
      (should (equal '(:type "input_text" :text "shot") (car output)))
      (should (equal "data:image/png;base64,QUJD" (plist-get (cadr output) :image_url))))
    ;; A result with no images is the plain text the model reads.
    (should (equal "shot"
                   (harness-responses--tool-output
                    (list :type "tool_result" :tool_use_id "call_1" :content "shot"))))))

(ert-deftest harness-provider-responses-token-goes-in-the-header-only ()
  "The access token is a bearer header and is nowhere else in the request.
It must not reach a URL, a body or a log line: the header is the one
place a credential belongs."
  (harness-responses-test-with-fake
      `(("/responses" . (:chunks ,(harness-responses-test--tool-call-events))))
    (harness-responses-test--complete
     `(:model "chatgpt:gpt-5" :tools ((:name "echo"))
       :messages ((:role user :content ((:type "text" :text "go"))))))
    (let* ((request (car harness-responses-test--requests))
           (body (plist-get request :json)))
      (should (equal (concat "Bearer " harness-responses-test--token)
                     (cdr (assoc "Authorization" (plist-get request :headers)))))
      (should (equal "POST" (plist-get request :method)))
      (should (equal "https://api.openai.com/v1/responses" (plist-get request :url)))
      (should-not (string-match-p (regexp-quote harness-responses-test--token)
                                  (harness-json-encode body))))))

;;;; The model catalogue

(ert-deftest harness-provider-responses-models-keep-only-the-listable-ones ()
  "The account's own listing becomes the catalogue, hiding what it marks hidden.
The slug is the name that goes in a request and the display name is
what a picker shows; a window is estimated, since this route lists none.
The efforts the listing names, or the ones its model is known to take,
become the model's thinking levels."
  (harness-responses-test-with-fake
      `(("/models" . (:body ,(harness-json-encode
                              '(:models ((:slug "gpt-5" :display_name "GPT-5" :visibility "list")
                                         (:slug "internal-1" :display_name "Internal" :visibility "hidden")
                                         (:slug "gpt-6-astra" :display_name "GPT-6 Astra" :visibility "list"
                                           :supported_reasoning_levels ((:effort "max" :description "Most")
                                                                        (:effort "xhigh" :description "More")
                                                                        (:effort "high" :description "Hard")
                                                                        (:effort "medium" :description "Everyday")
                                                                        (:effort "low" :description "Least")))
                                         (:slug "gpt-4o" :display_name "GPT-4o" :visibility "list")))))))
    (let* ((models (harness-test-await (harness-responses--models)))
           (first (car models))
           (astra (nth 1 models)))
      (should (equal "https://api.openai.com/v1/models" (plist-get (car harness-responses-test--requests) :url)))
      (should (equal (concat "Bearer " harness-responses-test--token)
                     (cdr (assoc "Authorization" (plist-get (car harness-responses-test--requests) :headers)))))
      (should (equal '("gpt-5" "gpt-6-astra" "gpt-4o") (mapcar (lambda (m) (plist-get m :name)) models)))
      (should (equal "GPT-5" (plist-get first :label)))
      ;; The catalogue knows the efforts of the models OpenAI documents;
      ;; gpt-5 takes minimal, GPT-6 Astra does not take none or minimal.
      (should (equal '("minimal" "low" "medium" "high")
                     (plist-get first :thinking-levels)))
      (should (equal '("low" "medium" "high" "xhigh" "max")
                     (plist-get astra :thinking-levels)))
      (should (equal "GPT-6 Astra" (plist-get astra :label)))
      ;; A model the catalogue says nothing about offers the safe ladder.
      (should (equal '("low" "medium" "high" "xhigh" "max")
                     (plist-get (nth 2 models) :thinking-levels))))))

(ert-deftest harness-provider-responses-models-are-cached-until-refreshed ()
  "A listing is cached, and a refresh is what asks the account again.
A picker that reopened would otherwise list the models on every keystroke."
  (harness-responses-test-with-fake
      `(("/models" . (:body ,(harness-json-encode
                              '(:models ((:slug "gpt-5" :display_name "GPT-5" :visibility "list")))))))
    (harness-test-await (harness-responses--models))
    (let ((n (length harness-responses-test--requests)))
      (harness-test-await (harness-responses--models))
      (should (= n (length harness-responses-test--requests)))
      (harness-test-await (harness-responses--models t))
      (should (= (1+ n) (length harness-responses-test--requests))))))

(ert-deftest harness-provider-responses-models-fall-back-to-what-was-listed ()
  "A listing that fails answers with the last one rather than nothing.
An account whose listing is briefly unavailable should not empty the
picker that was working a moment ago."
  (harness-responses-test-with-fake
      `(("/models" . (:body ,(harness-json-encode
                              '(:data ((:id "gpt-5" :display_name "GPT-5")))))))
    (should (equal '("gpt-5")
                   (mapcar (lambda (m) (plist-get m :name))
                           (harness-test-await (harness-responses--models)))))
    ;; Now the account answers with a failure, and the old models stay.
    (setq harness-responses-test--responses '(("/models" . (:status 500 :body "nope"))))
    (should (equal '("gpt-5")
                   (mapcar (lambda (m) (plist-get m :name))
                           (harness-test-await (harness-responses--models t)))))))

(ert-deftest harness-provider-responses-tier-model-is-chosen-from-the-catalogue ()
  "A tier names a model the account lists, so the harness can pick one on its own.
The plan's catalogue carries no prices, so nothing can be ranked by
price here; a tier is a name pattern or nothing."
  (harness-responses-test-with-fake
      `(("/models" . (:body ,(harness-json-encode
                              '(:models ((:slug "o4" :display_name "o4" :visibility "list")
                                         (:slug "gpt-5-mini" :display_name "GPT-5 mini" :visibility "list")))))))
    (harness-responses-test-with-provider
     (harness-responses-refresh)
     ;; The catalogue has to be listed before a tier can choose from it.
     (harness-test-await (funcall (harness-provider-models-fn (harness-provider-get 'chatgpt)) t))
     (should (equal "chatgpt:gpt-5-mini" (harness-provider-tier-model 'chatgpt :simple)))
     (should (equal "chatgpt:o4" (harness-provider-tier-model 'chatgpt :medium)))
     ;; `:frontier' is nil in the tiers, so there is no model for it.
     (should-not (harness-provider-tier-model 'chatgpt :frontier)))))

;;;; Quota

(ert-deftest harness-provider-responses-codex-quota-requires-explicit-account ()
  "No CLI is run before opt-in; an unrelated account cannot expose numbers."
  (harness-responses-test-with-fake nil
    (let ((harness-responses-codex-quota-account nil)
          (reads 0))
      (cl-letf (((symbol-function 'harness-codex-quota-read)
                 (lambda () (cl-incf reads) (harness-resolved nil))))
        (should-not (plist-get (harness-test-await (harness-responses--quota)) :windows))
        (should (= 0 reads))
        (let ((harness-responses-codex-quota-account "other@example.com"))
          (should-not (plist-get (harness-test-await (harness-responses--quota)) :windows))
          (should (= 0 reads)))))))

(ert-deftest harness-provider-responses-codex-quota-is-informational ()
  "Even a full Codex window is only a reference for a separately logged-in app."
  (harness-responses-test-with-fake nil
    (let ((harness-responses-codex-quota-account "a@example.com")
          (harness-responses--codex-quota-cache nil)
          (harness-responses--codex-quota-fetching nil)
          (reads 0))
      (cl-letf (((symbol-function 'harness-codex-quota-read)
                 (lambda ()
                   (cl-incf reads)
                   (harness-resolved
                    '(:status ok :email "a@example.com"
                      :quota (:source "codex-cli" :windows ((:name "5h" :used 1.0
                                                            :resets 2000000000.0))
                              :informational t :plan "plus" :plan-label "ChatGPT Plus"))))))
        (let ((quota (harness-test-await (harness-responses--quota))))
          (should (equal "ChatGPT Plus" (plist-get quota :plan-label)))
          (should (equal "codex-cli" (plist-get quota :source)))
          (should (plist-get quota :informational))
          (should-not (plist-get quota :limit-status))
          (should (string-match-p "may have a separate" (plist-get quota :quota-note)))
          (should (= 1 reads))
          (harness-test-await (harness-responses--quota))
          (should (= 1 reads))
          (harness-test-await (harness-responses--quota t))
          (should (= 2 reads)))
        (let ((harness-responses-test--status
               '(:active "acct-2" :accounts ((:id "acct-2" :email "other@example.com"
                                              :plan-usage t)))))
          (let ((quota (harness-test-await (harness-responses--quota))))
            (should-not (plist-get quota :windows))
            (should (string-match-p "differs" (plist-get quota :quota-note)))))))))

(ert-deftest harness-provider-responses-codex-quota-rejects-mismatched-cli-account ()
  "Matching the configured SIWC email is not enough: check Codex too."
  (harness-responses-test-with-fake nil
    (let ((harness-responses-codex-quota-account "a@example.com")
          (harness-responses--codex-quota-cache nil)
          (harness-responses--codex-quota-fetching nil))
      (cl-letf (((symbol-function 'harness-codex-quota-read)
                 (lambda ()
                   (harness-resolved
                    '(:status ok :email "stranger@example.com"
                      :quota (:windows ((:name "5h" :used 0.5))))))))
        (let ((quota (harness-test-await (harness-responses--quota))))
          (should-not (plist-get quota :windows))
          (should (string-match-p "different ChatGPT account"
                                  (plist-get quota :quota-note))))))))

(ert-deftest harness-provider-responses-quota-is-a-subscription ()
  "The plan is the billing; there is no balance and no invented cost."
  (harness-responses-test-with-fake nil
    (let ((quota (harness-test-await (harness-responses--quota))))
      (should (eq 'subscription (plist-get quota :billing)))
      (should (equal "chatgpt" (plist-get quota :auth)))
      (should (equal "ChatGPT plan" (plist-get quota :plan-label)))
      (should (equal "a@example.com" (harness-plist-get-in quota '(:account :email))))
      (should-not (plist-get quota :cost))
      (should-not (plist-get quota :available))
      ;; SIWC does not provide numerical quota; a simulated response with
      ;; Codex headers is not what real SIWC replies presently send.
      (should (string-match-p "OpenAI does not report" (plist-get quota :quota-note)))
      (should (equal "https://chatgpt.com/settings/usage" (plist-get quota :quota-url))))
    ;; With nobody signed in there is nothing to report at all.
    (let ((harness-responses-test--status nil))
      (should-not (harness-test-await (harness-responses--quota))))))

(ert-deftest harness-provider-responses-plan-headers-become-quota ()
  "The plan windows the route sends with every answer are the account's quota.
They are published through the generic interface, so the plan reads the
same in a chat header, the usage dashboard and the fallback list as a
Claude plan does, and the running turn hears of them once."
  (harness-provider-quota-forget 'chatgpt)
  (harness-responses-test-with-fake
      `(("/responses"
         . (:headers (("x-codex-primary-used-percent" . "41")
                      ("x-codex-primary-window-minutes" . "300")
                      ("x-codex-primary-reset-at" . "2000000000")
                      ("x-codex-secondary-used-percent" . "12")
                      ("x-codex-secondary-window-minutes" . "10080")
                      ("x-codex-secondary-reset-at" . "2000600000")
                      ("x-codex-plan-type" . "plus"))
            :chunks (,(harness-responses-test--sse
                       '(:type "response.output_text.delta" :delta "ok")
                       (list :type "response.completed"
                             :response (harness-responses-test--streamed-response)))))))
    (harness-responses-test-with-provider
     (harness-responses-refresh)
     (let (updates)
       (harness-on 'provider/quota-updated
                   (lambda (pid quota) (push (cons pid quota) updates)))
       (let* ((events (car (harness-responses-test--complete
                            '(:model "chatgpt:gpt-5"
                              :messages ((:role user :content ((:type "text" :text "hi"))))))))
              (quota (harness-test-await (harness-call 'provider/quota 'chatgpt)))
              (heard (harness-responses-test--events events 'quota)))
         ;; The turn heard the windows, once, before it was over.
         (should (= 1 (length heard)))
         (should (equal '("5h" "7d")
                        (mapcar (lambda (w) (plist-get w :name)) (plist-get (car heard) :windows))))
         ;; The announcement carries the same plan as the generic method.
         (should (= 1 (length updates)))
         (should (eq 'chatgpt (caar updates)))
         (should (equal (plist-get quota :windows) (plist-get (cdar updates) :windows)))
         ;; The account is the plan's, the windows named as every plan's.
         (should (eq 'subscription (plist-get quota :billing)))
         (should (equal "chatgpt" (plist-get quota :auth)))
         (should (equal "plus" (plist-get quota :plan)))
         (should (equal "ChatGPT Plus" (plist-get quota :plan-label)))
         (should (equal "a@example.com" (harness-plist-get-in quota '(:account :email))))
         (should (plist-get quota :available))
         (should (equal '("5h" "7d")
                        (mapcar (lambda (w) (plist-get w :name)) (plist-get quota :windows))))
         (should (= 0.41 (plist-get (car (plist-get quota :windows)) :used)))
         (should (= 2000000000.0 (plist-get (car (plist-get quota :windows)) :resets)))
         (should (equal "allowed" (plist-get quota :limit-status))))))))

(ert-deftest harness-provider-responses-rate-limits-event-becomes-quota ()
  "A `codex.rate_limits' event reports the plan's windows as the headers do.
The stream carries the same windows as a JSON object; a turn whose
answer brings no such header still reports its plan, and the windows
are named by how long they last rather than by the server's slot names."
  (harness-provider-quota-forget 'chatgpt)
  (harness-responses-test-with-fake
      `(("/responses"
         . (:chunks (,(harness-responses-test--sse
                       '(:type "codex.rate_limits"
                         :rate_limits
                         (:primary (:used_percent 92
                                    :window_minutes 300
                                    :resets_at 2000000000)
                          :secondary (:used_percent 12
                                      :limit_window_seconds 604800
                                      :resets_at 2000600000)
                          :plan_type "plus"
                          :credits (:has_credits t :unlimited :false
                                                 :balance "62500.0")))
                       (list :type "response.completed"
                             :response (harness-responses-test--streamed-response)))))))
    (harness-responses-test-with-provider
     (harness-responses-refresh)
     (let* ((events (car (harness-responses-test--complete
                          '(:model "chatgpt:gpt-5"
                            :messages ((:role user :content ((:type "text" :text "hi"))))))))
            (quota (harness-test-await (harness-call 'provider/quota 'chatgpt)))
            (heard (harness-responses-test--events events 'quota))
            (windows (plist-get quota :windows)))
       (should (= 1 (length heard)))
       (should (equal '("5h" "7d") (mapcar (lambda (w) (plist-get w :name)) windows)))
       (should (= 0.92 (plist-get (car windows) :used)))
       (should (= 10080 (plist-get (cadr windows) :minutes)))
       (should (= 0.12 (plist-get (cadr windows) :used)))
       ;; A warning window is what the plan's limit status follows.
       (should (equal "allowed_warning" (plist-get quota :limit-status)))
       (should (equal "plus" (plist-get quota :plan)))
       (should (equal "ChatGPT Plus" (plist-get quota :plan-label)))
       (should (equal '(:has-credits t :unlimited nil :balance "62500.0")
                      (plist-get quota :credits)))))))

(ert-deftest harness-provider-responses-own-windows-win-over-in-flight-codex ()
  "The app's own response supersedes a late, full Codex CLI reference."
  (harness-responses-test-with-fake nil
    (let ((harness-responses-codex-quota-account "a@example.com")
          (harness-responses--codex-quota-cache nil)
          (harness-responses--codex-quota-fetching nil)
          (read (harness-make-promise)))
      (cl-letf (((symbol-function 'harness-codex-quota-read) (lambda () read)))
        (let ((waiting (harness-responses--quota)))
          (harness-responses--publish-own-quota
           '(:windows ((:name "5h" :used 0.22 :resets 2000000000.0))))
          (harness-resolve read
                           '(:status ok :email "a@example.com"
                             :quota (:source "codex-cli" :informational t
                                     :windows ((:name "5h" :used 1.0)))))
          (let ((quota (harness-test-await waiting)))
            (should (equal "responses" (plist-get quota :source)))
            (should-not (plist-get quota :informational))
            (should (= 0.22 (plist-get (car (plist-get quota :windows)) :used)))
            (should (equal "responses" (plist-get (harness-provider-quota-status 'chatgpt)
                                                    :source)))))))))

(ert-deftest harness-provider-responses-discard-in-flight-reads-on-account-change ()
  "An old read must not reattach to a new account or poison its cache."
  (harness-responses-test-with-fake nil
    (let ((harness-responses-codex-quota-account "a@example.com")
          (harness-responses--codex-quota-cache nil)
          (harness-responses--codex-quota-fetching nil)
          (harness-responses--codex-quota-generation 0)
          (old (harness-make-promise)) (new (harness-make-promise))
          (reads 0))
      (harness-responses-test-with-provider
        (cl-letf (((symbol-function 'harness-codex-quota-read)
                   (lambda () (cl-incf reads) (if (= reads 1) old new))))
          (let ((waiting (harness-responses--quota)))
            (setq harness-responses-test--status
                  '(:active "acct-2" :accounts ((:id "acct-2" :email "b@example.com"
                                                :plan-usage t)))
                  harness-responses-codex-quota-account "b@example.com")
            (harness-responses--on-accounts-changed)
            (let ((next (harness-responses--quota)))
              (harness-resolve old '(:status ok :email "a@example.com"
                                     :quota (:windows ((:name "5h" :used 0.8)))))
              (should-not (harness-provider-quota-status 'chatgpt))
              (harness-resolve new '(:status ok :email "b@example.com"
                                     :quota (:windows ((:name "5h" :used 0.3)))))
              (dolist (promise (list waiting next))
                (let ((quota (harness-test-await promise)))
                  (should (equal "b@example.com" (harness-plist-get-in quota '(:account :email))))
                  (should (= 0.3 (plist-get (car (plist-get quota :windows)) :used)))))
              (should (= 2 reads))
              (should (equal "b@example.com" (plist-get harness-responses--codex-quota-cache :for))))))))))

(ert-deftest harness-provider-responses-failed-refresh-removes-old-codex-windows ()
  "A failed fresh read must not leave yesterday's Codex figures on display."
  (harness-responses-test-with-fake nil
    (let ((harness-responses-codex-quota-account "a@example.com")
          (harness-responses--codex-quota-cache nil)
          (harness-responses--codex-quota-fetching nil)
          (reads 0))
      (cl-letf (((symbol-function 'harness-codex-quota-read)
                 (lambda () (cl-incf reads)
                   (harness-resolved (if (= reads 1)
                                         '(:status ok :email "a@example.com"
                                           :quota (:windows ((:name "5h" :used 0.5))))
                                       '(:status no-quota))))))
        (should (plist-get (harness-test-await (harness-responses--quota)) :windows))
        (let ((quota (harness-test-await (harness-responses--quota t))))
          (should-not (plist-get quota :windows))
          (should-not (plist-get (harness-provider-quota-status 'chatgpt) :windows))
          (should (string-match-p "did not report" (plist-get quota :quota-note))))))))

(ert-deftest harness-provider-responses-opt-in-change-keeps-own-quota ()
  "Changing Codex association cannot remove the app's authoritative windows."
  (harness-responses-test-with-fake nil
    (harness-responses--publish-own-quota '(:windows ((:name "5h" :used 0.4))))
    (harness-responses--on-config-changed 'harness-responses-codex-quota-account)
    (let ((quota (harness-test-await (harness-responses--quota))))
      (should (= 0.4 (plist-get (car (plist-get quota :windows)) :used)))
      (should-not (plist-get quota :informational)))))

(provide 'harness-provider-responses-test)
;;; harness-provider-responses-test.el ends here
