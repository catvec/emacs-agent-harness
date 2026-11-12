;;; harness-provider-openrouter-output-bound-test.el --- The output ceiling on the wire  -*- lexical-binding: t; -*-

;;; Commentary:

;; A policy's `:retry' `:max-output-tokens' is a ceiling on what a routed
;; request may ask a model to write.  This suite checks it where it
;; matters: in the body the transport is handed, for a request of the
;; harness's own, one that asks for more, and one that asks for nothing.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-provider-openrouter)
(require 'harness-provider-openrouter-test-helpers)

(ert-deftest harness-provider-openrouter-output-bound-is-sent-on-the-wire ()
  "A request that asks for more output than the policy allows is cut to it.
The policy's `:max-output-tokens' is sent as `max_tokens' on the wire
whatever the request or a resumed session asked for, and a request that
asks for less keeps its own smaller figure."
  (let ((policy (harness-openrouter-test-policy
                 :retry '(:max-attempts 2 :max-seconds 30 :max-output-tokens 4096))))
    (harness-openrouter-test-with-policy policy
      (harness-openrouter-test-with-session (harness-openrouter-test--session "s-1")
        (harness-openrouter-test-with-fake
            (list (harness-openrouter-test--catalogue-response)
                  (harness-openrouter-test--completion-response))
          ;; A request that asks for 9000 is cut to the policy's 4096.
          (harness-openrouter-test--run
           (plist-put (harness-openrouter-test--request) :max-tokens 9000))
          (should (= 4096 (plist-get (plist-get (car harness-openrouter-test--requests) :json)
                                     :max_tokens)))
          ;; A request that asks for 900 keeps its own 900.
          (setq harness-openrouter-test--requests nil)
          (harness-openrouter-test--run
           (plist-put (harness-openrouter-test--request) :max-tokens 900))
          (should (= 900 (plist-get (plist-get (car harness-openrouter-test--requests) :json)
                                    :max_tokens)))
          ;; A request that asks for nothing is bounded too: the model's own
          ;; default output is otherwise far larger.
          (setq harness-openrouter-test--requests nil)
          (harness-openrouter-test--run (harness-openrouter-test--request))
          (should (= 4096 (plist-get (plist-get (car harness-openrouter-test--requests) :json)
                                     :max_tokens))))))))

(ert-deftest harness-provider-openrouter-retry-bounds-must-be-present-and-sane ()
  "A policy whose retry bounds are missing or malformed routes nothing.
The bounds are enforced, so a policy that does not say them cannot be
checked and is refused before a request is sent."
  (dolist (retry (list nil
                       '(:max-attempts 0 :max-seconds 30 :max-output-tokens 4096)
                       '(:max-attempts 2 :max-seconds "30" :max-output-tokens 4096)
                       '(:max-attempts 2 :max-seconds 30)
                       '(:max-attempts 2.5 :max-seconds 30 :max-output-tokens 4096)
                       '(:max-attempts -1 :max-seconds 30 :max-output-tokens 4096)))
    (should (string-match-p "retry"
                            (harness-openrouter-routing-validate
                             (harness-openrouter-test-policy :retry retry))))))

(provide 'harness-provider-openrouter-output-bound-test)
;;; harness-provider-openrouter-output-bound-test.el ends here
