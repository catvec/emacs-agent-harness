;;; harness-provider-test.el --- Tests for the provider layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 the emacs-agent-harness authors

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The provider interface is exercised two ways: unit tests on the pure
;; helpers (stats, cost, wire format) and an end-to-end streaming test against
;; the local HTTP server in `harness-test-util', which sends real SSE frames.

;;; Code:

(require 'ert)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-test-util)

(defun harness-provider-test--sse (object)
  "Return OBJECT as one server-sent event."
  (concat "data: " (harness-json-write object) "\n\n"))

(defun harness-provider-test--delta (delta)
  "Return an SSE event carrying a `choices' delta of DELTA."
  (harness-provider-test--sse
   (list (cons 'choices (list (list (cons 'delta delta)))))))

(defun harness-provider-test--finish (reason)
  "Return an SSE event with finish reason REASON."
  (harness-provider-test--sse
   (list (cons 'choices (list (list (cons 'delta nil) (cons 'finish_reason reason)))))))


;;; Model stats and cost

(ert-deftest harness-provider-test-model-stats-static ()
  "Static configuration is reported with prices and context window."
  (let ((harness-models '((:provider acme :id "big" :label "Big"
                            :context-window 128000 :price-in 3.0 :price-out 15.0
                            :price-cache-read 0.3))))
    (let ((stats (harness-model-stats 'acme "big")))
      (should (equal (harness-model-stats-label stats) "Big"))
      (should (equal (harness-model-stats-context-window stats) 128000))
      (should (eq (harness-model-stats-source stats) 'static))
      (should (harness-model-stats-price-p stats)))))

(ert-deftest harness-provider-test-model-stats-unknown ()
  "An unknown model still yields a usable record, without prices."
  (let ((harness-models nil))
    (let ((stats (harness-model-stats 'acme "mystery")))
      (should (equal (harness-model-stats-id stats) "mystery"))
      (should (equal (harness-model-stats-label stats) "mystery"))
      (should-not (harness-model-stats-price-p stats))
      (should (= (harness-usage-cost '(:in 1000 :out 1000) stats) 0.0)))))

(ert-deftest harness-provider-test-usage-cost ()
  "Cost is computed per million tokens, with cache reads discounted."
  (let* ((harness-models '((:provider acme :id "m" :price-in 1.0 :price-out 10.0
                             :price-cache-read 0.1 :price-cache-write 2.0)))
         (stats (harness-model-stats 'acme "m"))
         (usage '(:in 1000000 :out 1000 :cache-read 400000 :cache-write 1000)))
    ;; fresh input 600000 * 1.0 + cached 400000 * 0.1 + write 1000 * 2.0
    ;; + output 1000 * 10.0, all per million tokens = 0.652.
    (should (< (abs (- (harness-usage-cost usage stats) 0.652)) 1e-9))))

(ert-deftest harness-provider-test-capabilities ()
  "Provider capabilities come first so a provider can override defaults."
  (let ((provider (harness-provider-openai-create '(:name x :base-url "http://x"))))
    (let ((caps (harness-provider-capabilities provider)))
      (should (plist-get caps :streaming))
      (should (plist-get caps :tools))))
  (let ((plain (harness--make-provider :name 'p :caps '(:tools t))))
    (let ((caps (harness-provider-capabilities plain)))
      (should (plist-get caps :tools))
      (should (plist-get caps :streaming)))))

(ert-deftest harness-provider-test-registry ()
  "Providers are instantiated from `harness-providers' and keyed by name."
  (let ((harness-providers '((:name one :kind openai :base-url "http://one/v1")
                             (:name two :kind openai :base-url "http://two/v1"))))
    (harness-provider-setup)
    (should (harness-provider-get 'one))
    (should (harness-provider-get 'two))
    (should (equal (mapcar #'harness-provider-name (harness-provider-all))
                   '(one two)))
    (should (equal (harness-provider-resolve-api-key
                    (harness-provider-get 'one))
                   nil))))

(ert-deftest harness-provider-test-unknown-kind-is-ignored ()
  "A provider whose kind has no implementation is skipped, not fatal."
  (let ((harness-providers '((:name broken :kind nonexistent))))
    (harness-provider-setup)
    (should-not (harness-provider-get 'broken))))


;;; Wire format

(ert-deftest harness-provider-test-wire-message ()
  "Messages convert to the OpenAI shape, and reasoning is never echoed back."
  (let* ((session (harness--make-session :id "s" :name "s"))
         (assistant (harness-message-create session 'assistant "hi")))
    (setf (harness-message-thinking assistant) "secret reasoning")
    (setf (harness-message-tool-calls assistant)
          (list (harness-tool-call-create :id "c1" :name "bash"
                                          :args-string "{\"command\":\"ls\"}")))
    (harness-message-finalize assistant)
    (let ((wire (harness-provider-openai--wire-message assistant)))
      (should (equal (harness-alist-get :role wire) "assistant"))
      (should (equal (harness-alist-get :content wire) "hi"))
      (should-not (harness-alist-get :reasoning_content wire))
      (let ((calls (harness-alist-get :tool_calls wire)))
        ;; Tool calls serialise as a vector because `json-encode' cannot tell a
        ;; one element array of objects from an object.
        (should (vectorp calls))
        (should (equal (length calls) 1))
        (should (equal (harness-alist-get :id (aref calls 0)) "c1"))
        (should (equal (harness-alist-get :name
                                          (harness-alist-get :function (aref calls 0)))
                       "bash"))))))

(ert-deftest harness-provider-test-wire-skips-empty-assistant ()
  "An assistant message with no content and no tool calls is not sent."
  (let* ((session (harness--make-session :id "s2" :name "s2"))
         (message (harness-message-create session 'assistant "")))
    (should-not (harness-provider-openai--wire-message message))))

(ert-deftest harness-provider-test-tool-message ()
  "Tool results carry the matching tool_call_id, and never an empty body."
  (let* ((session (harness--make-session :id "s3" :name "s3"))
         (message (harness-message-create session 'tool "")))
    (setf (harness-message-tool-call-id message) "c9")
    (let ((wire (harness-provider-openai--wire-message message)))
      (should (equal (harness-alist-get :role wire) "tool"))
      (should (equal (harness-alist-get :tool_call_id wire) "c9"))
      (should (equal (harness-alist-get :content wire) "(no output)")))))

(ert-deftest harness-provider-test-request-body ()
  "The request body is valid JSON with the expected fields."
  (let* ((session (harness--make-session :id "s4" :name "s4" :model "m"))
         (message (harness-message-create session 'user "hello")))
    (harness-message-finalize message)
    (let* ((request (harness-provider--make-request
                     :model "m"
                     :messages (list message)
                     :system "be nice"
                     :tools '(((type . "function")
                               (function . ((name . "bash")
                                            (description . "run")
                                            (parameters . ((type . "object")))))))))
           (body (harness-provider-openai--request-body request))
           (parsed (harness-json-read body)))
      (should (equal (harness-alist-get :model parsed) "m"))
      (should (eq (harness-alist-get :stream parsed) t))
      (should (harness-alist-get :stream_options parsed))
      (let ((messages (harness-alist-get :messages parsed)))
        (should (equal (length messages) 2))
        (should (equal (harness-alist-get :role (car messages)) "system"))
        (should (equal (harness-alist-get :content (cadr messages)) "hello")))
      (should (equal (length (harness-alist-get :tools parsed)) 1)))))

(ert-deftest harness-provider-test-message-json-cache ()
  "Finished messages cache their wire JSON; unfinished ones do not."
  (let* ((session (harness--make-session :id "s5" :name "s5"))
         (message (harness-message-create session 'user "cache me")))
    (setf (harness-message-status message) 'streaming)
    (should-not (plist-get (harness-message-meta message) :wire-json))
    (let ((first (harness-provider-openai--message-json message)))
      (should-not (plist-get (harness-message-meta message) :wire-json))
      (harness-message-finalize message)
      (should (equal (harness-provider-openai--message-json message) first))
      (should (equal (plist-get (harness-message-meta message) :wire-json) first))
      (should (equal (harness-provider-openai--message-json message) first)))))

(ert-deftest harness-provider-test-message-json-skips-empty-assistant ()
  "A skipped message is nil, not the JSON string \"null\".
`harness-json-write' turns nil into \"null\", so dropping the wire form has to
happen before it is encoded, or the request body carries a null element and
the provider rejects it."
  (let* ((session (harness--make-session :id "s5b" :name "s5b"))
         (message (harness-message-create session 'assistant "")))
    (harness-message-finalize message)
    (should-not (harness-provider-openai--message-json message))))

(ert-deftest harness-provider-test-request-body-drops-empty-assistant ()
  "An empty assistant message never reaches the wire as a JSON null."
  (let* ((session (harness--make-session :id "s5c" :name "s5c" :model "m"))
         (empty (harness-message-create session 'assistant ""))
         (user (harness-message-create session 'user "hello")))
    (harness-message-finalize empty)
    (harness-message-finalize user)
    (let* ((request (harness-provider--make-request
                     :model "m" :messages (list empty user)))
           (body (harness-provider-openai--request-body request))
           (messages (harness-alist-get :messages (harness-json-read body))))
      (should-not (string-match-p "null" body))
      (should (= 1 (length messages)))
      (should (equal (harness-alist-get :role (car messages)) "user")))))

(ert-deftest harness-provider-test-parse-usage ()
  "Usage maps to the harness plist, including cached input tokens."
  (let ((usage (harness-provider-openai--parse-usage
                '((prompt_tokens . 100)
                  (completion_tokens . 20)
                  (prompt_tokens_details . ((cached_tokens . 40)))))))
    (should (equal (plist-get usage :in) 100))
    (should (equal (plist-get usage :out) 20))
    (should (equal (plist-get usage :cache-read) 40)))
  (let ((deepseek (harness-provider-openai--parse-usage
                   '((prompt_tokens . 10) (completion_tokens . 1)
                     (prompt_cache_hit_tokens . 4)))))
    (should (equal (plist-get deepseek :cache-read) 4))))


;;; End to end streaming

(defun harness-provider-test--stream (chunks &optional model)
  "Run one streaming request against a server returning CHUNKS.
Return a plist of what the callbacks observed."
  (let ((seen (list :deltas nil :tool-calls nil :usage nil :done nil
                    :error nil :request nil))
        (harness-models (list (list :provider 'test :id (or model "test-model")
                                    :price-in 1.0 :price-out 2.0))))
    (harness-http-test-with-server
     (lambda (request)
       (setq seen (plist-put seen :request request))
       (list :headers '(("Content-Type" . "text/event-stream"))
             :chunks chunks))
     (let ((harness-providers (list (list :name 'test :kind 'openai
                                          :base-url (format "http://127.0.0.1:%d/v1" port)))))
       (harness-provider-setup)
       (let* ((session (harness--make-session :id "stream" :name "stream"
                                              :model (or model "test-model")))
              (message (harness-message-create session 'user "hi")))
         (harness-message-finalize message)
         (harness-session-append-message session message)
         (harness-provider-chat-async
          session
          (list :on-delta (lambda (kind text)
                            (setq seen (plist-put seen :deltas
                                                  (cons (cons kind text)
                                                        (plist-get seen :deltas)))))
                :on-tool-call (lambda (_index call)
                                (setq seen (plist-put seen :tool-calls
                                                      (cons (harness-tool-call-copy call)
                                                            (plist-get seen :tool-calls)))))
                :on-usage (lambda (usage) (setq seen (plist-put seen :usage usage)))
                :on-done (lambda (reason usage)
                           (setq seen (plist-put seen :done (list reason usage))))
                :on-error (lambda (symbol message)
                            (setq seen (plist-put seen :error (list symbol message))))))
         (harness-test-wait-for
          (lambda () (or (plist-get seen :done) (plist-get seen :error))) 10))))
    (plist-put seen :deltas (nreverse (plist-get seen :deltas)))
    seen))

(ert-deftest harness-provider-openai-test-streams-text-and-reasoning ()
  "Text and reasoning deltas arrive in order, with a terminal callback."
  (let ((seen (harness-provider-test--stream
               (list (harness-provider-test--delta
                      (list (cons 'reasoning_content "thinking ")))
                     (harness-provider-test--delta (list (cons 'content "Hel")))
                     (harness-provider-test--delta (list (cons 'content "lo")))
                     (harness-provider-test--finish "stop")
                     "data: [DONE]\n\n"))))
    (should-not (plist-get seen :error))
    (should (equal (car (plist-get seen :done)) "stop"))
    (should (equal (plist-get seen :deltas)
                   '((thinking . "thinking ") (text . "Hel") (text . "lo"))))
    (should (string-match-p "/v1/chat/completions" (plist-get seen :request)))
    (should (string-match-p "\"stream\":true" (plist-get seen :request)))))

(ert-deftest harness-provider-openai-test-streams-tool-calls ()
  "Tool call fragments accumulate into one call with parseable arguments."
  (let ((seen (harness-provider-test--stream
               (list (harness-provider-test--delta
                      (list (cons 'tool_calls
                                  (list (list (cons 'index 0)
                                              (cons 'id "call_1")
                                              (cons 'function
                                                    (list (cons 'name "bash")
                                                          (cons 'arguments "{\"comm"))))))))
                     (harness-provider-test--delta
                      (list (cons 'tool_calls
                                  (list (list (cons 'index 0)
                                              (cons 'function
                                                    (list (cons 'arguments "and\":\"ls\"}"))))))))
                     (harness-provider-test--finish "tool_calls")
                     (harness-provider-test--sse
                      (list (cons 'choices nil)
                            (cons 'usage (list (cons 'prompt_tokens 10)
                                               (cons 'completion_tokens 5)))))
                     "data: [DONE]\n\n"))))
    (should-not (plist-get seen :error))
    (should (equal (car (plist-get seen :done)) "tool_calls"))
    (should (equal (plist-get seen :usage) '(:in 10 :out 5 :cache-read 0 :cache-write 0)))
    (let ((call (car (plist-get seen :tool-calls))))
      (should (equal (harness-tool-call-id call) "call_1"))
      (should (equal (harness-tool-call-name call) "bash"))
      (should (equal (harness-tool-call-args-string call) "{\"command\":\"ls\"}"))
      (harness-tool-call-parse-args call)
      (should (equal (harness-tool-call-arg call :command) "ls")))))

(ert-deftest harness-provider-openai-test-http-error ()
  "A non-2xx response surfaces as a readable error, not an exception."
  (let ((seen (list :error nil)))
    (harness-http-test-with-server
     (lambda (_request)
       (list :status 401 :reason "Unauthorized"
             :body "{\"error\":{\"message\":\"bad key\"}}"))
     (let ((harness-providers (list (list :name 'test :kind 'openai
                                          :base-url (format "http://127.0.0.1:%d/v1" port)))))
       (harness-provider-setup)
       (let ((session (harness--make-session :id "err" :name "err" :model "m")))
         (harness-provider-chat-async
          session
          (list :on-error (lambda (symbol message)
                            (setq seen (plist-put seen :error (list symbol message))))
                :on-done (lambda (&rest _) (setq seen (plist-put seen :error 'unexpected)))))
         (harness-test-wait-for (lambda () (plist-get seen :error)) 10))))
    (should (plist-get seen :error))
    (should (eq (car (plist-get seen :error)) 'harness-http))
    (should (string-match-p "401" (cadr (plist-get seen :error))))
    (should (string-match-p "bad key" (cadr (plist-get seen :error))))))

(ert-deftest harness-provider-test-no-provider ()
  "With no provider configured the error callback fires immediately."
  (let ((harness-providers nil)
        (seen nil))
    (harness-provider-setup)
    (let ((session (harness--make-session :id "n" :name "n" :model "m")))
      (harness-provider-chat-async
       session
       (list :on-error (lambda (symbol message) (setq seen (list symbol message)))))
      (should (eq (car seen) 'harness-no-provider))
      (should (string-match-p "harness-providers" (cadr seen))))))

(ert-deftest harness-provider-test-no-model ()
  "With a provider but no model the error callback fires immediately."
  (let ((harness-providers '((:name solo :kind openai :base-url "http://127.0.0.1:1/v1")))
        (harness-models nil)
        (harness-default-model nil)
        (seen nil))
    (harness-provider-setup)
    (let ((session (harness--make-session :id "nm" :name "nm" :model nil)))
      (harness-provider-chat-async
       session
       (list :on-error (lambda (symbol message) (setq seen (list symbol message)))))
      (should (eq (car seen) 'harness-no-model)))))

(ert-deftest harness-provider-openai-test-model-discovery ()
  "The `/models' endpoint is parsed into `harness-models' shaped plists."
  (let ((models nil))
    (harness-http-test-with-server
     (lambda (_request)
       (list :headers '(("Content-Type" . "application/json"))
             :body "{\"data\":[{\"id\":\"a\"},{\"id\":\"b\"}]}"))
     (let ((provider (harness-provider-openai-create
                      (list :name 'test :base-url (format "http://127.0.0.1:%d/v1" port)))))
       (harness-provider-models provider (lambda (result) (setq models result)))
       (harness-test-wait-for (lambda () models) 10)))
    (should (equal (mapcar (lambda (spec) (harness-plist-or-alist-get :id spec)) models)
                   '("a" "b")))
    (should (equal (harness-plist-or-alist-get :provider (car models)) 'test))))

(provide 'harness-provider-test)
;;; harness-provider-test.el ends here
