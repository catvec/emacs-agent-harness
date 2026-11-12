;;; harness-provider-openrouter-output-bound-test.el --- Whose output limit  -*- lexical-binding: t; -*-

;;; Commentary:

;; A routing policy does not say how much a model may write: its subject
;; is who serves a request and what it may cost.  What a request asks a
;; model to write is the request's `:max-tokens', and a ceiling on that
;; is the generic request layer's (`harness-provider-max-output-tokens'),
;; off by default.  This suite checks both halves where it matters: in
;; the body the transport is handed, for a request that names no limit,
;; one that names its own, and one over the layer's ceiling.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-provider)
(require 'harness-provider-openrouter)
(require 'harness-provider-openrouter-test-helpers)

(defun harness-provider-openrouter-output-bound--routed-body (request)
  "Return the body a routed OpenRouter request builds, for REQUEST.
The policy is the test one and the pin its DeepInfra endpoint, so the
request is the one a session's step makes."
  (let ((policy (harness-openrouter-test-policy))
        (route (harness-openrouter-test--route)))
    (harness-openrouter-test--routed-body policy route request)))

(ert-deftest harness-provider-openrouter-policy-sets-no-output-limit ()
  "A routed request carries the output limit the request itself named.
The policy has no field for one, and the module adds none: a request
that asks for 900 sends 900, and a request that asks for nothing sends
no `max_tokens' at all, so OpenRouter's endpoint answers with the
model's own default -- as every other provider of the harness does."
  (let* ((named (harness-provider-openrouter-output-bound--routed-body
                 (plist-put (harness-openrouter-test--request) :max-tokens 900)))
         (silent (harness-provider-openrouter-output-bound--routed-body
                  (harness-openrouter-test--request)))
         (large (harness-provider-openrouter-output-bound--routed-body
                 (plist-put (harness-openrouter-test--request) :max-tokens 9000))))
    (should (= 900 (plist-get named :max_tokens)))
    (should (= 9000 (plist-get large :max_tokens)))
    (should-not (plist-member silent :max_tokens))
    ;; And no policy field could have supplied one.
    (should-not (plist-member (harness-openrouter-test-policy) :retry))
    (should-not (plist-member (harness-openrouter-test-policy) :max-output-tokens))))

(ert-deftest harness-provider-openrouter-a-generic-ceiling-bounds-every-provider ()
  "A user-chosen output ceiling is the request layer's, and cuts every provider.
It is off by default: with it nil, a request is handed on exactly as it
came.  A number cuts a larger request to it and bounds one that named
nothing, which is the one place every provider's request passes."
  (let ((request (list :model "x:m" :messages '((:role user :content "hi")))))
    ;; Off by default: nothing is added, nothing is cut.
    (should-not harness-provider-max-output-tokens)
    (should (equal request (harness-provider-bound-output request)))
    (should-not (plist-member (harness-provider-bound-output request) :max-tokens))
    ;; A ceiling cuts a larger limit and a missing one alike.
    (should (= 4096 (plist-get (harness-provider-bound-output
                                (plist-put (copy-sequence request) :max-tokens 9000)
                                4096)
                               :max-tokens)))
    (should (= 4096 (plist-get (harness-provider-bound-output request 4096) :max-tokens)))
    ;; A request below the ceiling keeps its own smaller figure.
    (should (= 900 (plist-get (harness-provider-bound-output
                               (plist-put (copy-sequence request) :max-tokens 900)
                               4096)
                              :max-tokens)))
    ;; The option is the default when no ceiling is passed.
    (let ((harness-provider-max-output-tokens 2048))
      (should (= 2048 (plist-get (harness-provider-bound-output request) :max-tokens))))))

(ert-deftest harness-provider-openrouter-a-cut-tool-call-is-not-a-clean-call ()
  "Output cut at `max_tokens' is reported as cut, and a partial call is not run as one.
A limit that is too low truncates the arguments of a tool call, not
just a reply: the answer then ends at `max-tokens' when the model wrote
no call, and when it wrote one that did not finish, the call it did
write is passed on with its unparsable arguments as `(\:raw ...)' rather
than silently dropped or invented -- so what a caller sees is a call
that cannot run, not a clean answer.  Nothing here repeats the request
on the guess that a second one would fit inside the limit."
  ;; No call at all, cut at the limit: the answer ends at `max-tokens'.
  (let* ((events nil)
         (stream (make-harness-openai--stream :on-event (lambda (e) (push e events)))))
    (harness-openai--stream-chunk
     stream (harness-json-encode
             '(:choices ((:index 0 :delta (:content "half a thought") :finish_reason "length")))))
    (harness-openai--stream-complete stream)
    (should (eq 'max-tokens (plist-get (car events) :stop-reason)))
    (should-not (cl-find 'tool-call events :key (lambda (e) (plist-get e :type)))))
  ;; A call whose arguments were cut: the answer is a tool call, and the
  ;; arguments are what arrived -- unparsable, and marked so.
  (let* ((events nil)
         (stream (make-harness-openai--stream :on-event (lambda (e) (push e events)))))
    (harness-openai--stream-chunk
     stream (harness-json-encode
             '(:choices ((:index 0
                          :delta (:tool_calls ((:index 0 :id "call_1"
                                                :function (:name "echo" :arguments "{\"val"))))
                          :finish_reason "length")))))
    (harness-openai--stream-complete stream)
    (let ((call (cl-find 'tool-call events :key (lambda (e) (plist-get e :type)))))
      (should call)
      (should (equal "call_1" (plist-get call :id)))
      (should (equal '(:raw "{\"val") (plist-get call :input))))
    (should (eq 'tool-use (plist-get (car events) :stop-reason))))
  ;; A call whose arguments arrived whole and the limit besides: as before.
  (let* ((events nil)
         (stream (make-harness-openai--stream :on-event (lambda (e) (push e events)))))
    (harness-openai--stream-chunk
     stream (harness-json-encode
             '(:choices ((:index 0
                          :delta (:tool_calls ((:index 0 :id "call_1"
                                                :function (:name "echo" :arguments "{\"value\":\"a\"}"))))
                          :finish_reason "length")))))
    (harness-openai--stream-complete stream)
    (should (equal '(:value "a")
                   (plist-get (cl-find 'tool-call events :key (lambda (e) (plist-get e :type)))
                              :input)))))

(provide 'harness-provider-openrouter-output-bound-test)
;;; harness-provider-openrouter-output-bound-test.el ends here
