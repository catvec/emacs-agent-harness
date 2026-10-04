;;; harness-provider-openai-test.el --- Tests for the OpenAI-compatible provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests drive the provider through a fake `harness-http-request'
;; that records the request and replays canned SSE chunks.  Integration
;; tests (tag `integration', HARNESS_INTEGRATION=1) talk to OpenRouter.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-openai)

;;;; Fake HTTP layer

(defvar harness-openai-test--requests nil
  "Requests seen by the fake, newest first: (:url :method :headers :json :args).")

(defvar harness-openai-test--responses nil
  "Alist of (URL-REGEXP . RESPONSE) consulted by the fake.
RESPONSE is (:status N :chunks (STRING…)) for streamed replies or
\(:status N :body STRING) for plain ones; :hang t never answers.")

(defun harness-openai-test--fake-request (url &rest args)
  "Record a request to URL with ARGS and replay the matching canned response."
  (let* ((response (cdr (cl-find-if (lambda (cell) (string-match-p (car cell) url))
                                    harness-openai-test--responses)))
         (handle (make-harness-http-handle :url url :callback (plist-get args :callback)
                                           :on-chunk (plist-get args :on-chunk)
                                           :started (float-time))))
    (push (list :url url :method (or (plist-get args :method) "GET")
                :headers (plist-get args :headers) :json (plist-get args :json) :args args)
          harness-openai-test--requests)
    (unless (plist-get response :hang)
      (harness-run-soon
       (lambda ()
         (unless (harness-http-handle-cancelled handle)
           (let ((status (or (plist-get response :status) 200)))
             (when (plist-get args :on-headers)
               (funcall (plist-get args :on-headers) status nil))
             (if (plist-get args :on-chunk)
                 (progn
                   (dolist (chunk (or (plist-get response :chunks)
                                      (and (plist-get response :body) (list (plist-get response :body)))))
                     (funcall (plist-get args :on-chunk) chunk))
                   (funcall (plist-get args :callback) status nil "" nil))
               (funcall (plist-get args :callback) status nil (or (plist-get response :body) "") nil)))))))
    handle))

(defmacro harness-openai-test-with-fake (responses &rest body)
  "Run BODY with `harness-http-request' replaced by a fake serving RESPONSES."
  (declare (indent 1))
  `(let ((harness-openai-test--requests nil)
         (harness-openai-test--responses ,responses)
         (auth-sources nil))
     (cl-letf (((symbol-function 'harness-http-request) #'harness-openai-test--fake-request))
       ,@body)))

(defun harness-openai-test--sse (&rest payloads)
  "Return one SSE chunk string holding PAYLOADS (strings or plists)."
  (mapconcat (lambda (p) (format "data: %s\n\n" (if (stringp p) p (harness-json-encode p))))
             payloads ""))

(defvar harness-openai-test-endpoint
  '(:id testrouter :label "Test router" :base-url "https://openrouter.example/api/v1/"
    :api-key "sk-test-not-a-real-key")
  "An OpenRouter-flavoured endpoint with a literal key.")

(defvar harness-openai-test-openai-endpoint
  '(:id testopenai :label "Test OpenAI" :base-url "https://api.openai.example/v1"
    :api-key "sk-test-openai")
  "A plain OpenAI-flavoured endpoint.")

(defvar harness-openai-test-deepseek-endpoint
  '(:id testdeepseek :label "Test DeepSeek" :base-url "https://api.deepseek.example"
    :api-key "sk-test-deepseek" :flavor deepseek)
  "A DeepSeek-flavoured endpoint.")

(defvar harness-openai-test-deepseek-host-endpoint
  '(:id testdscompat :label "DeepSeek (OpenAI-compatible)"
    :base-url "https://api.deepseek.com/v1" :api-key "sk-test-deepseek-compat"
    :flavor openai)
  "An endpoint pointed at DeepSeek but labelled plain OpenAI.")

(defun harness-openai-test--complete (endpoint request)
  "Run REQUEST directly against ENDPOINT's complete function, collecting events.
Return (EVENTS . HANDLE) once `done' arrived; EVENTS are oldest first."
  (let* ((events nil)
         (request (plist-put (copy-sequence request) :on-event (lambda (e) (push e events))))
         (handle (harness-openai--complete endpoint request)))
    (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type)))) 5 "done event")
    (cons (reverse events) handle)))

(defun harness-openai-test--types (events)
  "Return the `:type' of every event in EVENTS."
  (mapcar (lambda (e) (plist-get e :type)) events))

(defun harness-openai-test--last-request-json ()
  "Return the JSON plist of the most recent fake request."
  (plist-get (car harness-openai-test--requests) :json))

(defun harness-openai-test--approx (a b)
  "Non-nil when numbers A and B agree to a millionth."
  (< (abs (- a b)) 1e-6))

;;;; Registration and configuration

(ert-deftest harness-provider-openai-registers-default-endpoints ()
  (should (harness-provider-get 'openrouter))
  (should (harness-provider-get 'openai))
  (should (equal "OpenRouter" (harness-provider-label (harness-provider-get 'openrouter))))
  (should (eq 'dynamic (plist-get (harness-provider-capabilities (harness-provider-get 'openrouter)) :pricing)))
  (should-not (plist-get (harness-provider-capabilities (harness-provider-get 'openai)) :pricing))
  (should (memq 'provider (harness-module-requires (harness-module-get 'provider-openai)))))

(ert-deftest harness-provider-openai-add-and-remove-endpoint ()
  (let ((saved harness-openai-endpoints))
    (unwind-protect
        (progn
          (harness-openai-add-endpoint :id 'local :label "Local" :base-url "http://localhost:8080/v1"
                                       :models '("llama" (:name "qwen" :context-window 32000))
                                       :default-context 4096)
          (should (harness-provider-get 'local))
          (should (equal "Local" (harness-provider-label (harness-provider-get 'local))))
          (let ((models (harness-test-await (funcall (harness-provider-models-fn (harness-provider-get 'local))))))
            (should (equal '("llama" "qwen") (mapcar (lambda (m) (plist-get m :name)) models)))
            (should (= 4096 (plist-get (car models) :context-window)))
            (should (= 32000 (plist-get (cadr models) :context-window))))
          ;; Setting the custom back through :set drops the provider again.
          (funcall (get 'harness-openai-endpoints 'custom-set) 'harness-openai-endpoints saved)
          (should-not (harness-provider-get 'local))
          (should (harness-provider-get 'openrouter)))
      (setq harness-openai-endpoints saved)
      (harness-openai--register-all))))

(ert-deftest harness-provider-openai-api-key-resolution ()
  (let ((auth-sources nil))
    (should (equal "lit" (harness-openai--api-key '(:id x :base-url "https://h.example/v1" :api-key "lit"
                                                        :api-key-env "HARNESS_TEST_NO_SUCH_VAR"))))
    (with-environment-variables (("HARNESS_TEST_KEY_VAR" "from-env"))
      (should (equal "from-env" (harness-openai--api-key '(:id x :base-url "https://h.example/v1"
                                                               :api-key-env "HARNESS_TEST_KEY_VAR")))))
    (with-environment-variables (("HARNESS_TEST_KEY_VAR" ""))
      (should-not (harness-openai--api-key '(:id x :base-url "https://h.example/v1"
                                                 :api-key-env "HARNESS_TEST_KEY_VAR"))))
    ;; auth-source is consulted last.
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest args)
                 (when (and (equal (plist-get args :host) "h.example") (equal (plist-get args :user) "apikey"))
                   (list (list :host "h.example" :secret (lambda () "from-auth-source")))))))
      (should (equal "from-auth-source" (harness-openai--api-key '(:id x :base-url "https://h.example/v1")))))))

;;;; Request body

(ert-deftest harness-provider-openai-request-body-shape ()
  (harness-openai-test-with-fake
      `(("chat/completions" . (:chunks (,(harness-openai-test--sse
                                          '(:choices ((:index 0 :delta (:content "ok") :finish_reason "stop")))
                                          "[DONE]")))))
    (let* ((img (make-temp-file "harness-openai-img" nil ".png"))
           (_ (with-temp-file img (set-buffer-multibyte nil) (insert "\211PNG\r\n")))
           (request
            (list :model "testrouter:vendor/model-1"
                  :system "Be terse."
                  :thinking "medium"
                  :max-tokens 321
                  :tools '((:name "echo" :description "Echo it."
                            :schema (:type "object" :properties (:value (:type "string")) :required ("value")))
                           (:name "noop"))
                  :messages `((:role user :content ((:type "text" :text "look")
                                                    (:type "image" :path ,img)
                                                    (:type "image" :mime "image/jpeg" :data "QUJD")))
                              (:role assistant :content ((:type "thinking" :text "hmm")
                                                         (:type "text" :text "calling")
                                                         (:type "tool_use" :id "call_1" :name "echo" :input (:value "a"))
                                                         (:type "tool_use" :id "call_2" :name "noop" :input nil)))
                              (:role tool :content ((:type "tool_result" :tool_use_id "call_1" :content "a!")
                                                    (:type "tool_result" :tool_use_id "call_2" :content "" :is_error t)))
                              (:role assistant :content ((:type "tool_use" :id "call_3" :name "echo" :input (:value "b"))))
                              (:role user :content ((:type "tool_result" :tool_use_id "call_3" :content "b!")
                                                    (:type "text" :text "and now?")))))))
      (harness-openai-test--complete harness-openai-test-endpoint request)
      (let* ((req (car harness-openai-test--requests))
             (body (plist-get req :json))
             (msgs (plist-get body :messages)))
        (should (equal "https://openrouter.example/api/v1/chat/completions" (plist-get req :url)))
        (should (equal "POST" (plist-get req :method)))
        (should (equal "Bearer sk-test-not-a-real-key" (cdr (assoc "Authorization" (plist-get req :headers)))))
        (should (equal "vendor/model-1" (plist-get body :model)))
        (should (eq t (plist-get body :stream)))
        (should (equal '(:include_usage t) (plist-get body :stream_options)))
        (should (equal '(:include t) (plist-get body :usage)))
        (should (equal '(:effort "medium") (plist-get body :reasoning)))
        (should (= 321 (plist-get body :max_tokens)))
        (should-not (plist-get body :reasoning_effort))
        ;; tools
        (should (equal '((:type "function"
                          :function (:name "echo" :description "Echo it."
                                     :parameters (:type "object" :properties (:value (:type "string")) :required ("value"))))
                         (:type "function"
                          :function (:name "noop" :description "" :parameters (:type "object" :properties :empty))))
                       (plist-get body :tools)))
        ;; messages
        (should (equal '("system" "user" "assistant" "tool" "tool" "assistant" "tool" "user")
                       (mapcar (lambda (m) (plist-get m :role)) msgs)))
        (should (equal '(:role "system" :content "Be terse.") (nth 0 msgs)))
        (let ((parts (plist-get (nth 1 msgs) :content)))
          (should (equal '(:type "text" :text "look") (nth 0 parts)))
          (should (equal (format "data:image/png;base64,%s" (base64-encode-string "\211PNG\r\n" t))
                         (harness-plist-get-in (nth 1 parts) '(:image_url :url))))
          (should (equal "data:image/jpeg;base64,QUJD" (harness-plist-get-in (nth 2 parts) '(:image_url :url)))))
        (should (equal '(:role "assistant" :content "calling"
                         :tool_calls ((:id "call_1" :type "function" :function (:name "echo" :arguments "{\"value\":\"a\"}"))
                                      (:id "call_2" :type "function" :function (:name "noop" :arguments "{}"))))
                       (nth 2 msgs)))
        (should (equal '(:role "tool" :tool_call_id "call_1" :content "a!") (nth 3 msgs)))
        (should (equal '(:role "tool" :tool_call_id "call_2" :content "") (nth 4 msgs)))
        ;; assistant with only a tool call has null content
        (should (equal '(:role "assistant" :content nil
                         :tool_calls ((:id "call_3" :type "function" :function (:name "echo" :arguments "{\"value\":\"b\"}"))))
                       (nth 5 msgs)))
        (should (equal '(:role "tool" :tool_call_id "call_3" :content "b!") (nth 6 msgs)))
        (should (equal '(:role "user" :content ((:type "text" :text "and now?"))) (nth 7 msgs)))
        ;; the encoded body is valid JSON with null where expected
        (should (string-match-p "\"content\":null" (harness-json-encode body))))
      (delete-file img))))

(ert-deftest harness-provider-openai-non-ascii-tool-arguments ()
  ;; Arguments are a string inside the body's JSON: as bytes they made the
  ;; body fail to encode once a call had non-ASCII input.
  (let* ((input (list :value "\N{U+2717} caf\N{U+E9} \N{U+2026}"))
         (msgs (harness-openai--messages
                (list :messages `((:role user :content "go")
                                  (:role assistant :content ((:type "tool_use" :id "call_1" :name "echo" :input ,input)))
                                  (:role user :content ((:type "tool_result" :tool_use_id "call_1" :content "ok")))))))
         (sent (harness-json-parse (harness-json-encode (list :messages msgs))))
         (call (car (plist-get (nth 1 (plist-get sent :messages)) :tool_calls))))
    (should (equal "echo" (harness-plist-get-in call '(:function :name))))
    (should (equal input (harness-json-parse (harness-plist-get-in call '(:function :arguments)))))))

(ert-deftest harness-provider-openai-request-body-plain-openai-dialect ()
  (harness-openai-test-with-fake
      `(("chat/completions" . (:chunks (,(harness-openai-test--sse
                                          '(:choices ((:index 0 :delta (:content "ok") :finish_reason "stop")))
                                          "[DONE]")))))
    (harness-openai-test--complete harness-openai-test-openai-endpoint
                                   '(:model "testopenai:gpt-x" :thinking "max" :max-tokens 10
                                     :messages ((:role user :content ((:type "text" :text "hi"))))))
    (let ((body (harness-openai-test--last-request-json)))
      (should (equal "high" (plist-get body :reasoning_effort)))
      (should-not (plist-get body :reasoning))
      (should-not (plist-get body :usage))
      (should-not (plist-get body :tools))
      (should (= 10 (plist-get body :max_completion_tokens)))
      (should-not (plist-get body :max_tokens))
      (should-not (assoc "X-Title" (plist-get (car harness-openai-test--requests) :headers))))))

(ert-deftest harness-provider-openai-deepseek-dialect-body ()
  (harness-openai-test-with-fake
      `(("chat/completions" . (:chunks (,(harness-openai-test--sse
                                          '(:choices ((:index 0 :delta (:content "ok") :finish_reason "stop")))
                                          "[DONE]")))))
    (harness-openai-test--complete harness-openai-test-deepseek-endpoint
                                   '(:model "testdeepseek:deepseek-flash" :thinking "max" :max-tokens 321
                                     :messages ((:role user :content ((:type "text" :text "hi"))))))
    (let ((body (harness-openai-test--last-request-json)))
      ;; DeepSeek takes max_tokens, and its own reasoning efforts.
      (should (= 321 (plist-get body :max_tokens)))
      (should-not (plist-get body :max_completion_tokens))
      (should (equal "max" (plist-get body :reasoning_effort)))
      (should-not (plist-get body :reasoning))
      (should-not (plist-get body :usage)))
    ;; A DeepSeek endpoint does not claim vision for every model.
    (should (equal '(:thinking t)
                   (harness-openai--capabilities harness-openai-test-deepseek-endpoint)))))

(ert-deftest harness-provider-openai-deepseek-effort-ladder ()
  ;; DeepSeek acts on three efforts, weakest first; the harness levels in
  ;; between collapse onto the effort DeepSeek's own mapping gives them,
  ;; so no level buys more (or less) thinking than its name promises.
  (should (equal '("low" "high" "max") harness-openai--deepseek-efforts))
  (should (equal "low" (harness-openai--deepseek-effort "minimal")))
  (should (equal "low" (harness-openai--deepseek-effort "low")))
  (should (equal "high" (harness-openai--deepseek-effort "medium")))
  (should (equal "high" (harness-openai--deepseek-effort "high")))
  (should (equal "high" (harness-openai--deepseek-effort "xhigh")))
  (should (equal "max" (harness-openai--deepseek-effort "max")))
  ;; Every effort of the ladder maps to itself, and only the ladder (plus
  ;; the off switch) can come out.
  (should (equal harness-openai--deepseek-efforts
                 (mapcar #'harness-openai--deepseek-effort harness-openai--deepseek-efforts)))
  (dolist (level '("low" "medium" "high" "xhigh" "max"))
    (should (member (harness-openai--deepseek-effort level)
                    (cons "none" harness-openai--deepseek-efforts))))
  ;; A level DeepSeek does not know sends no effort at all.
  (should-not (harness-openai--deepseek-effort "ultra"))
  (should-not (harness-openai--deepseek-effort nil))
  (should-not (harness-openai--deepseek-effort "bogus")))

(ert-deftest harness-provider-openai-deepseek-efforts-in-the-body ()
  "The ladder's ends, and a level collapsed between them, go out as such."
  (harness-openai-test-with-fake
      `(("chat/completions" . (:chunks (,(harness-openai-test--sse
                                          '(:choices ((:index 0 :delta (:content "ok") :finish_reason "stop")))
                                          "[DONE]")))))
    (dolist (case '(("low" . "low") ("medium" . "high") ("high" . "high")
                    ("xhigh" . "high") ("max" . "max")))
      (harness-openai-test--complete
       harness-openai-test-deepseek-endpoint
       `(:model "testdeepseek:deepseek-flash" :thinking ,(car case)
         :messages ((:role user :content ((:type "text" :text "hi"))))))
      (should (equal (cdr case) (plist-get (harness-openai-test--last-request-json)
                                            :reasoning_effort))))))

(ert-deftest harness-provider-openai-deepseek-replays-reasoning-content ()
  ;; DeepSeek's thinking mode rejects a tool-using history whose assistant
  ;; messages omit reasoning_content, so the recorded thinking goes back.
  (harness-openai-test-with-fake
      `(("chat/completions" . (:chunks (,(harness-openai-test--sse
                                          '(:choices ((:index 0 :delta (:content "ok") :finish_reason "stop")))
                                          "[DONE]")))))
    (harness-openai-test--complete
     harness-openai-test-deepseek-endpoint
     '(:model "testdeepseek:deepseek-flash" :thinking "high"
       :tools ((:name "echo"))
       :messages ((:role user :content ((:type "text" :text "go")))
                  (:role assistant :content ((:type "thinking" :text "first thought")
                                             (:type "thinking" :text "second thought")
                                             (:type "text" :text "checking")
                                             (:type "tool_use" :id "call_1" :name "echo" :input (:value "x"))))
                  (:role tool :content ((:type "tool_result" :tool_use_id "call_1" :content "x!")))
                  (:role assistant :content ((:type "tool_use" :id "call_2" :name "echo" :input nil))))))
    (let* ((msgs (plist-get (harness-openai-test--last-request-json) :messages))
           (first (nth 1 msgs)) (second (nth 3 msgs)))
      (should (equal "first thought\n\nsecond thought" (plist-get first :reasoning_content)))
      (should (equal "checking" (plist-get first :content)))
      (should (equal "call_1" (harness-plist-get-in (car (plist-get first :tool_calls)) '(:id))))
      ;; A turn whose thinking is gone still carries the key, empty.
      (should (equal "" (plist-get second :reasoning_content)))
      (should (equal "call_2" (harness-plist-get-in (car (plist-get second :tool_calls)) '(:id)))))
    ;; Other dialects drop thinking as before.
    (let* ((msgs (harness-openai--messages
                  '(:messages ((:role assistant :content ((:type "thinking" :text "hmm")
                                                           (:type "text" :text "ok")))))
                  harness-openai-test-endpoint)))
      (should-not (plist-get (car msgs) :reasoning_content)))))

(ert-deftest harness-provider-openai-deepseek-host-is-recognized ()
  ;; The dialect follows the host, not the label: an endpoint pointed at
  ;; DeepSeek but declared `:flavor openai' still gets DeepSeek handling,
  ;; or its tool loops would 400 for a missing reasoning_content.
  (should (harness-openai--deepseek-p harness-openai-test-deepseek-host-endpoint))
  (should (harness-openai--deepseek-p (list :base-url "https://api.deepseek.com")))
  ;; A look-alike host is not DeepSeek, and plain OpenAI stays plain.
  (should-not (harness-openai--deepseek-p (list :base-url "https://deepseek.com.evil.example/v1")))
  (should-not (harness-openai--deepseek-p (list :base-url "https://api.deepseek.example/v1" :flavor 'openai)))
  (should-not (harness-openai--deepseek-p harness-openai-test-openai-endpoint))
  (should-not (harness-openai--deepseek-p (list :base-url "https://api.openai.example/v1"))))

(ert-deftest harness-provider-openai-deepseek-host-replays-reasoning-content ()
  ;; An endpoint that only looks OpenAI-ish but talks to DeepSeek replays
  ;; the recorded thinking, the way a `:flavor deepseek' one does.
  (harness-openai-test-with-fake
      `(("chat/completions" . (:chunks (,(harness-openai-test--sse
                                          '(:choices ((:index 0 :delta (:content "ok") :finish_reason "stop")))
                                          "[DONE]")))))
    (harness-openai-test--complete
     harness-openai-test-deepseek-host-endpoint
     '(:model "testdscompat:deepseek-flash" :thinking "high" :max-tokens 321
       :tools ((:name "echo"))
       :messages ((:role user :content ((:type "text" :text "go")))
                  (:role assistant :content ((:type "thinking" :text "weigh it")
                                             (:type "tool_use" :id "call_1" :name "echo" :input (:value "x"))))
                  (:role tool :content ((:type "tool_result" :tool_use_id "call_1" :content "x!"))))))
    (let* ((body (harness-openai-test--last-request-json))
           (assistant (nth 1 (plist-get body :messages))))
      (should (equal "weigh it" (plist-get assistant :reasoning_content)))
      ;; DeepSeek's reasoning efforts and max_tokens follow the host too.
      (should (equal "high" (plist-get body :reasoning_effort)))
      (should-not (plist-get body :reasoning))
      (should (= 321 (plist-get body :max_tokens)))
      (should-not (plist-get body :max_completion_tokens)))))

;;;; Event streams

(ert-deftest harness-provider-openai-deepseek-reasoning-content-streams ()
  ;; DeepSeek streams its chain of thought as `reasoning_content'; the
  ;; agent records it as thinking, which the next request replays.
  (harness-openai-test-with-fake
      `(("chat/completions"
         . (:chunks (,(harness-openai-test--sse
                      '(:choices ((:index 0 :delta (:reasoning_content "weigh") :finish_reason nil)))
                      '(:choices ((:index 0 :delta (:reasoning_content " it") :finish_reason nil)))
                      '(:choices ((:index 0 :delta (:content "done") :finish_reason "stop")))
                      "[DONE]")))))
    (let* ((events (car (harness-openai-test--complete
                         harness-openai-test-deepseek-endpoint
                         '(:model "testdeepseek:deepseek-flash" :thinking "high"
                           :messages ((:role user :content ((:type "text" :text "go"))))))))
           (thought (mapconcat (lambda (e) (plist-get e :delta))
                               (cl-remove-if-not (lambda (e) (eq (plist-get e :type) 'thinking)) events)
                               "")))
      (should (equal '(start thinking thinking text done) (harness-openai-test--types events)))
      (should (equal "weigh it" thought)))))

(ert-deftest harness-provider-openai-deepseek-usage-splits-cache-tokens ()
  ;; DeepSeek's prompt_tokens includes cached tokens, which are billed
  ;; apart, so :input is the cache misses and :cache-read the hits.
  (harness-openai-test-with-fake
      `(("chat/completions"
         . (:chunks (,(harness-openai-test--sse
                      '(:choices ((:index 0 :delta (:content "ok") :finish_reason "stop")))
                      '(:choices () :usage (:prompt_tokens 100 :completion_tokens 7
                                            :prompt_cache_hit_tokens 80 :prompt_cache_miss_tokens 20))
                      "[DONE]")))))
    (let* ((events (car (harness-openai-test--complete
                         harness-openai-test-deepseek-endpoint
                         '(:model "testdeepseek:deepseek-flash" :max-tokens 10
                           :messages ((:role user :content ((:type "text" :text "hi"))))))))
           (usage (cl-find 'usage events :key (lambda (e) (plist-get e :type)))))
      (should (equal '(:type usage :input 20 :output 7 :cache-read 80 :cache-write 0
                       :cost nil :billing api :context 100)
                     usage)))))

(ert-deftest harness-provider-openai-deepseek-usage-splits-on-a-custom-host ()
  ;; DeepSeek's cache fields say prompt_tokens is hit + miss; billing must
  ;; split them even when the endpoint is not labelled DeepSeek, or the
  ;; cached input is charged at the cache-miss price.
  (harness-openai-test-with-fake
      `(("chat/completions"
         . (:chunks (,(harness-openai-test--sse
                      '(:choices ((:index 0 :delta (:content "ok") :finish_reason "stop")))
                      '(:choices () :usage (:prompt_tokens 1000 :completion_tokens 100
                                            :prompt_cache_hit_tokens 900 :prompt_cache_miss_tokens 100))
                      "[DONE]")))))
    (let* ((events (car (harness-openai-test--complete
                         harness-openai-test-deepseek-host-endpoint
                         '(:model "testdscompat:deepseek-flash" :max-tokens 10
                           :messages ((:role user :content ((:type "text" :text "hi"))))))))
           (usage (cl-find 'usage events :key (lambda (e) (plist-get e :type)))))
      (should (equal '(:type usage :input 100 :output 100 :cache-read 900 :cache-write 0
                       :cost nil :billing api :context 1000)
                     usage))))
  ;; A server that reports only the hits still splits: the misses are the rest.
  (let ((usage (harness-openai--usage-event
                '(:prompt_tokens 100 :completion_tokens 7 :prompt_cache_hit_tokens 80)
                '(:id proxy :base-url "https://llm.example/v1" :flavor openai))))
    (should (equal '(:type usage :input 20 :output 7 :cache-read 80 :cache-write 0
                     :cost nil :billing api :context 100)
                   usage))))

(ert-deftest harness-provider-openai-text-answer-with-usage ()
  (harness-openai-test-with-fake
      `(("chat/completions"
         . (:chunks
            ;; chunks split mid-event to exercise SSE buffering
            ("data: {\"id\":\"c1\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hel\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"think"
             "ing\"},\"finish_reason\":null}]}\n\n"
             ,(harness-openai-test--sse
               '(:choices ((:index 0 :delta (:content "lo") :finish_reason "stop")))
               '(:choices () :usage (:prompt_tokens 12 :completion_tokens 3 :total_tokens 15
                                     :prompt_tokens_details (:cached_tokens 5) :cost 0.00042))
               "[DONE]")))))
    (let ((events (car (harness-openai-test--complete
                        harness-openai-test-endpoint
                        '(:model "testrouter:m" :messages ((:role user :content ((:type "text" :text "hi")))))))))
      (should (equal '(start text thinking text usage done) (harness-openai-test--types events)))
      (should (equal "Hel" (plist-get (nth 1 events) :delta)))
      (should (equal "thinking" (plist-get (nth 2 events) :delta)))
      (should (equal "lo" (plist-get (nth 3 events) :delta)))
      (should (equal '(:type usage :input 12 :output 3 :cache-read 5 :cache-write 0 :cost 0.00042
                       :billing api :context 12)
                     (nth 4 events)))
      (should (equal '(:type done :stop-reason end-turn) (car (last events)))))))

(ert-deftest harness-provider-openai-tool-call-assembled-from-fragments ()
  (harness-openai-test-with-fake
      `(("chat/completions"
         . (:chunks
            (,(harness-openai-test--sse
               '(:choices ((:index 0 :delta (:role "assistant" :content nil
                                             :tool_calls ((:index 0 :id "call_abc" :type "function"
                                                           :function (:name "echo" :arguments ""))))
                            :finish_reason nil)))
               '(:choices ((:index 0 :delta (:tool_calls ((:index 0 :function (:arguments "{\"val")))) :finish_reason nil)))
               '(:choices ((:index 0 :delta (:tool_calls ((:index 1 :id "call_def" :type "function"
                                                           :function (:name "noop" :arguments "{}"))))
                            :finish_reason nil)))
               '(:choices ((:index 0 :delta (:tool_calls ((:index 0 :function (:arguments "ue\":\"x y\"}")))) :finish_reason nil)))
               '(:choices ((:index 0 :delta () :finish_reason "tool_calls")))
               '(:choices () :usage (:prompt_tokens 50 :completion_tokens 9))
               "[DONE]")))))
    (let* ((all (car (harness-openai-test--complete
                      harness-openai-test-endpoint
                      '(:model "testrouter:m" :messages ((:role user :content ((:type "text" :text "go"))))))))
           (activity (cl-remove-if-not (lambda (e) (eq (plist-get e :type) 'activity)) all))
           (events (cl-remove 'activity all :key (lambda (e) (plist-get e :type)))))
      ;; Each call is announced, with the size of its arguments so far, as
      ;; soon as its name streams; later fragments within the interval are not.
      (should (equal '((tool-input "echo" 0) (tool-input "noop" 2))
                     (mapcar (lambda (e) (list (plist-get e :phase) (plist-get e :tool) (plist-get e :chars)))
                             activity)))
      (should (< (cl-position (car activity) all) (cl-position 'usage all :key (lambda (e) (plist-get e :type)))))
      (should (equal '(start usage tool-call tool-call done) (harness-openai-test--types events)))
      (should (equal '(:type tool-call :id "call_abc" :name "echo" :input (:value "x y") :respond nil) (nth 2 events)))
      (should (equal '(:type tool-call :id "call_def" :name "noop" :input nil :respond nil) (nth 3 events)))
      (should (equal '(:type done :stop-reason tool-use) (nth 4 events)))
      (should (= 50 (plist-get (nth 1 events) :input)))
      (should-not (plist-get (nth 1 events) :cost)))))

(ert-deftest harness-provider-openai-length-and-stream-error ()
  (harness-openai-test-with-fake
      `(("chat/completions" . (:chunks (,(harness-openai-test--sse
                                          '(:choices ((:index 0 :delta (:content "partial") :finish_reason "length")))
                                          "[DONE]")))))
    (let ((events (car (harness-openai-test--complete
                        harness-openai-test-endpoint
                        '(:model "testrouter:m" :messages ((:role user :content ((:type "text" :text "go")))))))))
      (should (equal '(:type done :stop-reason max-tokens) (car (last events))))))
  ;; A 200 stream that carries an error object ends with an error.
  (harness-openai-test-with-fake
      `(("chat/completions" . (:chunks (,(harness-openai-test--sse
                                          '(:error (:message "Provider returned error" :code 502))
                                          "[DONE]")))))
    (let ((events (car (harness-openai-test--complete
                        harness-openai-test-endpoint
                        '(:model "testrouter:m" :messages ((:role user :content ((:type "text" :text "go")))))))))
      (should (equal '(start done) (harness-openai-test--types events)))
      (should (eq 'error (plist-get (cadr events) :stop-reason)))
      (should (equal "Provider returned error" (plist-get (cadr events) :error))))))

(ert-deftest harness-provider-openai-http-401-error ()
  (harness-openai-test-with-fake
      '(("chat/completions" . (:status 401 :chunks ("{\"error\":{\"message\":\"Invalid API key\",\"code\":401}}"))))
    (let ((events (car (harness-openai-test--complete
                        harness-openai-test-endpoint
                        '(:model "testrouter:m" :messages ((:role user :content ((:type "text" :text "hi")))))))))
      (should (equal '(start done) (harness-openai-test--types events)))
      (should (eq 'error (plist-get (cadr events) :stop-reason)))
      (should (string-match-p "Invalid API key" (plist-get (cadr events) :error)))
      (should (string-match-p "401" (plist-get (cadr events) :error))))))

(ert-deftest harness-provider-openai-http-errors-say-what-kind ()
  "HTTP failures carry what kind they are, so the fallback can act on them."
  (dolist (case '((402 "Insufficient Balance" billing)
                  (429 "Rate limit exceeded" rate-limit)
                  (401 "Invalid API key" auth)))
    (pcase-let ((`(,status ,message ,kind) case))
      (harness-openai-test-with-fake
          `(("chat/completions" . (:status ,status
                                    :body ,(format "{\"error\":{\"message\":%S}}" message))))
        (let* ((events (car (harness-openai-test--complete
                             harness-openai-test-endpoint
                             '(:model "testrouter:m" :messages ((:role user :content ((:type "text" :text "hi"))))))))
               (done (car (last events))))
          (should (eq 'error (plist-get done :stop-reason)))
          (should (eq kind (plist-get done :error-kind)))))))
  ;; A 429 whose body says the account's quota is used up is out of
  ;; money, the way DeepSeek answers a spent prepaid balance.
  (harness-openai-test-with-fake
      '(("chat/completions" . (:status 429
                               :body "{\"error\":{\"message\":\"Insufficient Balance\",\"type\":\"insufficient_quota\"}}")))
    (let ((events (car (harness-openai-test--complete
                        harness-openai-test-deepseek-endpoint
                        '(:model "testdeepseek:deepseek-flash"
                          :messages ((:role user :content ((:type "text" :text "hi")))))))))
      (should (eq 'billing (plist-get (car (last events)) :error-kind))))))

(ert-deftest harness-provider-openai-missing-key-and-transport-error ()
  (with-environment-variables (("HARNESS_TEST_MISSING_KEY" nil))
    (harness-openai-test-with-fake nil
      (let ((events (car (harness-openai-test--complete
                          '(:id nokey :base-url "https://nokey.example/v1" :api-key-env "HARNESS_TEST_MISSING_KEY")
                          '(:model "nokey:m" :messages ((:role user :content ((:type "text" :text "hi")))))))))
        (should (equal '(start done) (harness-openai-test--types events)))
        (should (eq 'error (plist-get (cadr events) :stop-reason)))
        (should (string-match-p "HARNESS_TEST_MISSING_KEY" (plist-get (cadr events) :error)))
        (should-not harness-openai-test--requests))))
  ;; A transport failure reported by the HTTP layer.
  (let ((events nil))
    (cl-letf (((symbol-function 'harness-http-request)
               (lambda (_url &rest args)
                 (harness-run-soon (plist-get args :callback) nil nil "" '(curl "curl exited 7: connection refused"))
                 (make-harness-http-handle :url "x"))))
      (harness-openai--complete harness-openai-test-endpoint
                                (list :model "testrouter:m"
                                      :messages '((:role user :content ((:type "text" :text "hi"))))
                                      :on-event (lambda (e) (push e events))))
      (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type)))) 5)
      (should (equal '(start done) (harness-openai-test--types (reverse events))))
      (should (string-match-p "connection refused" (plist-get (car events) :error))))))

(ert-deftest harness-provider-openai-cancel-emits-done-once ()
  (harness-openai-test-with-fake '(("chat/completions" . (:hang t)))
    (let* ((events nil)
           (handle (harness-openai--complete
                    harness-openai-test-endpoint
                    (list :model "testrouter:m"
                          :messages '((:role user :content ((:type "text" :text "hi"))))
                          :on-event (lambda (e) (push e events))))))
      (should (equal '(start) (harness-openai-test--types events)))
      (funcall (plist-get handle :cancel))
      (funcall (plist-get handle :cancel))
      (should (equal '(start done) (harness-openai-test--types (reverse events))))
      (should (equal '(:type done :stop-reason cancelled) (car events)))
      ;; Late data or a late callback from the transport is ignored.
      (let ((args (plist-get (car harness-openai-test--requests) :args)))
        (funcall (plist-get args :on-chunk) (harness-openai-test--sse '(:choices ((:index 0 :delta (:content "late"))))))
        (funcall (plist-get args :callback) 200 nil "" nil))
      (should (= 2 (length events))))))

(ert-deftest harness-provider-openai-through-bus ()
  (harness-openai-test-with-fake
      `(("chat/completions" . (:chunks (,(harness-openai-test--sse
                                          '(:choices ((:index 0 :delta (:content "via bus") :finish_reason "stop")))
                                          "[DONE]")))))
    (let ((saved harness-openai-endpoints) (events nil))
      (unwind-protect
          (progn
            (apply #'harness-openai-add-endpoint harness-openai-test-endpoint)
            (harness-call 'provider/complete
                          (list :model "testrouter:m"
                                :messages '((:role user :content ((:type "text" :text "hi"))))
                                :on-event (lambda (e) (push e events))))
            (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type)))) 5)
            (should (equal '(start text done) (harness-openai-test--types (reverse events)))))
        (setq harness-openai-endpoints saved)
        (harness-openai--register-all)))))

;;;; Models

(ert-deftest harness-provider-openai-models-openrouter-mapping ()
  (harness-openai-test-with-fake
      `(("/models"
         . (:body ,(harness-json-encode
                    '(:data ((:id "vendor/smart" :name "Vendor: Smart" :context_length 200000
                              :architecture (:input_modalities ("text" "image") :output_modalities ("text"))
                              :pricing (:prompt "0.0000001" :completion "0.0000004"
                                        :input_cache_read "0.000000025" :input_cache_write "0.000000125")
                              :top_provider (:max_completion_tokens 32000 :context_length 200000)
                              :supported_parameters ("tools" "reasoning" "temperature"))
                             (:id "vendor/plain" :context_length 8192
                              :pricing (:prompt "0.000001" :completion "0.000002")
                              :supported_parameters ("temperature"))))))))
    (harness-openai-clear-models-cache)
    (let* ((models (harness-test-await (harness-openai--models harness-openai-test-endpoint)))
           (smart (car models)) (plain (cadr models))
           (pricing (plist-get smart :pricing)))
      (should (equal "https://openrouter.example/api/v1/models" (plist-get (car harness-openai-test--requests) :url)))
      (should (equal "Bearer sk-test-not-a-real-key"
                     (cdr (assoc "Authorization" (plist-get (car harness-openai-test--requests) :headers)))))
      (should (= 2 (length models)))
      (should (equal "vendor/smart" (plist-get smart :name)))
      (should (equal "Vendor: Smart" (plist-get smart :label)))
      (should (= 200000 (plist-get smart :context-window)))
      (should (= 32000 (plist-get smart :max-output)))
      (should (equal '("text" "image") (plist-get smart :input-modalities)))
      (should (equal '("low" "medium" "high") (plist-get smart :thinking-levels)))
      (should (harness-openai-test--approx 0.1 (plist-get pricing :input)))
      (should (harness-openai-test--approx 0.4 (plist-get pricing :output)))
      (should (harness-openai-test--approx 0.025 (plist-get pricing :cache-read)))
      (should (harness-openai-test--approx 0.125 (plist-get pricing :cache-write)))
      (should (eq t (plist-get (plist-get smart :capabilities) :tools)))
      (should (eq t (plist-get (plist-get smart :capabilities) :thinking)))
      (should (eq t (plist-get (plist-get smart :capabilities) :vision)))
      ;; plain model: no caching prices fall back to the input price, no thinking
      (should (harness-openai-test--approx 1.0 (plist-get (plist-get plain :pricing) :input)))
      (should (harness-openai-test--approx 1.0 (plist-get (plist-get plain :pricing) :cache-read)))
      (should-not (plist-get plain :thinking-levels))
      (should-not (plist-get (plist-get plain :capabilities) :tools))
      ;; the second call is served from the cache
      (let ((n (length harness-openai-test--requests)))
        (should (= 2 (length (harness-test-await (harness-openai--models harness-openai-test-endpoint)))))
        (should (= n (length harness-openai-test--requests))))
      ;; and the provider normaliser produces full ids
      (should (equal "testrouter:vendor/smart"
                     (plist-get (harness-provider--normalise-model
                                 (make-harness-provider :id 'testrouter :label "T") smart)
                                :id))))
    (harness-openai-clear-models-cache)))

(ert-deftest harness-provider-openai-models-deepseek-effort-levels ()
  ;; DeepSeek reports the efforts it acts on; the catalogue offers exactly
  ;; those, so the menu and the request share the real low/high/max ladder
  ;; instead of a five-step one two of whose steps collapse.
  (harness-openai-test-with-fake
      `(("/models"
         . (:body ,(harness-json-encode
                    '(:object "list"
                      :data ((:id "deepseek-flash" :name "DeepSeek-V4.1-Flash"
                              :context_window 1048576
                              :effort (:supported_levels ("low" "high" "max")
                                       :default_level "high"))))))))
    (harness-openai-clear-models-cache)
    (let* ((models (harness-test-await
                    (harness-openai--models harness-openai-test-deepseek-host-endpoint)))
           (model (car models)))
      (should (equal '("low" "high" "max") (plist-get model :thinking-levels)))
      (should (eq t (plist-get (plist-get model :capabilities) :thinking)))
      ;; The whole ladder maps to itself, in the same order.
      (should (equal '("low" "high" "max")
                     (mapcar #'harness-openai--deepseek-effort
                             (plist-get model :thinking-levels)))))
    ;; An older or terser DeepSeek host that reports nothing about
    ;; reasoning still gets the ladder its models think at.
    (harness-openai-test-with-fake
        `(("/models" . (:body ,(harness-json-encode
                                '(:object "list" :data ((:id "deepseek-v4-pro")))))))
      (harness-openai-clear-models-cache)
      (let ((model (car (harness-test-await
                         (harness-openai--models harness-openai-test-deepseek-host-endpoint)))))
        (should (equal harness-openai--deepseek-efforts (plist-get model :thinking-levels)))
        (should (eq t (plist-get (plist-get model :capabilities) :thinking)))))
    (harness-openai-clear-models-cache)))

(ert-deftest harness-provider-openai-models-plain-and-failing ()
  ;; Plain OpenAI ids only.
  (harness-openai-test-with-fake
      `(("/models" . (:body ,(harness-json-encode '(:object "list" :data ((:id "gpt-x" :object "model" :owned_by "openai")))))))
    (harness-openai-clear-models-cache)
    (let ((models (harness-test-await (harness-openai--models
                                       (append harness-openai-test-openai-endpoint '(:default-context 400000))))))
      (should (equal '(:name "gpt-x" :label "gpt-x" :context-window 400000) (car models)))))
  ;; A failing endpoint resolves to an empty list with a warning, never rejects.
  (harness-openai-test-with-fake '(("/models" . (:status 401 :body "{\"error\":{\"message\":\"nope\"}}")))
    (harness-openai-clear-models-cache)
    (let ((warned nil))
      (add-hook 'harness-log-hook (lambda (level msg) (when (and (eq level 'warn) (string-match-p "nope" msg)) (setq warned t))))
      (unwind-protect
          (should (null (harness-test-await (harness-openai--models harness-openai-test-endpoint))))
        (setq harness-log-hook nil))
      (should warned)
      ;; failures are not cached
      (should-not (gethash 'testrouter harness-openai--models-cache))))
  (harness-openai-clear-models-cache))

;;;; Integration

(defconst harness-openai-test-integration-model "openrouter:openai/gpt-4.1-nano")

(defun harness-openai-test--run-live (request)
  "Send REQUEST through the bus and return its events oldest first."
  (let ((events nil))
    (harness-call 'provider/complete
                  (plist-put (copy-sequence request) :on-event (lambda (e) (push e events))))
    (harness-test-wait (lambda () (cl-find 'done events :key (lambda (e) (plist-get e :type)))) 90 "live done")
    (reverse events)))

(defun harness-openai-test--text (events)
  "Concatenate the text deltas in EVENTS."
  (mapconcat (lambda (e) (if (eq (plist-get e :type) 'text) (plist-get e :delta) "")) events ""))

(ert-deftest harness-provider-openai-integration-text ()
  :tags '(integration)
  (harness-test-skip-unless-integration)
  (skip-unless (getenv "OPENROUTER_API_KEY"))
  (let* ((events (harness-openai-test--run-live
                  (list :model harness-openai-test-integration-model
                        :system "You answer with a single word."
                        :max-tokens 20
                        :messages '((:role user :content ((:type "text" :text "Say the word pong.")))))))
         (done (car (last events)))
         (usage (cl-find 'usage events :key (lambda (e) (plist-get e :type)))))
    (should (eq 'start (plist-get (car events) :type)))
    (should (equal '(:type done :stop-reason end-turn) done))
    (should (string-match-p "pong" (downcase (harness-openai-test--text events))))
    (should usage)
    (should (> (plist-get usage :input) 0))
    (should (> (plist-get usage :output) 0))
    (should (numberp (plist-get usage :cost)))
    (should (= (plist-get usage :context) (plist-get usage :input)))))

(ert-deftest harness-provider-openai-integration-tool-round-trip ()
  :tags '(integration)
  (harness-test-skip-unless-integration)
  (skip-unless (getenv "OPENROUTER_API_KEY"))
  (let* ((tools '((:name "echo" :description "Echo VALUE back through the tool runtime."
                   :schema (:type "object" :properties (:value (:type "string" :description "Text to echo"))
                            :required ("value")))))
         (user '(:role user :content ((:type "text" :text "Call the echo tool with the value \"marble\". Then report the tool's exact output back to me."))))
         (first (harness-openai-test--run-live
                 (list :model harness-openai-test-integration-model :tools tools :max-tokens 200
                       :messages (list user))))
         (call (cl-find 'tool-call first :key (lambda (e) (plist-get e :type)))))
    (should call)
    (should (equal "echo" (plist-get call :name)))
    (should (equal "marble" (plist-get (plist-get call :input) :value)))
    (should (null (plist-get call :respond)))
    (should (equal '(:type done :stop-reason tool-use) (car (last first))))
    (let* ((assistant (list :role 'assistant
                            :content (append
                                      (let ((text (harness-openai-test--text first)))
                                        (unless (string-empty-p text) (list (list :type "text" :text text))))
                                      (list (list :type "tool_use" :id (plist-get call :id)
                                                  :name "echo" :input (plist-get call :input))))))
           (result (list :role 'tool
                         :content (list (list :type "tool_result" :tool_use_id (plist-get call :id)
                                              :content "ZEBRA-4242"))))
           (second (harness-openai-test--run-live
                    (list :model harness-openai-test-integration-model :tools tools :max-tokens 200
                          :messages (list user assistant result)))))
      (should (equal '(:type done :stop-reason end-turn) (car (last second))))
      (should (string-match-p "ZEBRA-4242" (harness-openai-test--text second)))
      (should (cl-find 'usage second :key (lambda (e) (plist-get e :type)))))))

;;;; Customize type

(ert-deftest harness-openai-endpoints-type-names-every-key ()
  "The settings page offers every key of an endpoint, with a value to start from."
  (let ((entry harness-openai--endpoint-type))
    ;; Every key the documentation lists, but the literal key it discourages.
    (should (equal '(:api-key) (cl-set-difference (harness-test-documented-keys 'harness-openai-endpoints)
                                                  (harness-test-option-keys entry))))
    (harness-test-check-record-type entry)
    (should (memq :tiers (harness-test-option-keys entry)))
    (should (harness-test-fits-p entry (plist-get (cdr entry) :value)))
    (should (harness-test-fits-p (get 'harness-openai-endpoints 'custom-type)
                                 (eval (car (get 'harness-openai-endpoints 'standard-value)) t)))
    ;; What the type does not name, or names with another kind of value,
    ;; still fits: nothing set in Lisp turns invalid.
    (should (harness-test-fits-p (get 'harness-openai-endpoints 'custom-type)
                                 '((:id "named-by-a-string" :api-key "sk-x" :weird 3
                                    :models ("a" (:name "b" :context-window 4096 :pricing (:input 1)))))))))

(provide 'harness-provider-openai-test)
;;; harness-provider-openai-test.el ends here
