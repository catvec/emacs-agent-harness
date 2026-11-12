;;; harness-provider-openrouter-chain-test.el --- The routing policy in a real turn  -*- lexical-binding: t; -*-

;;; Commentary:

;; The other suite drives the provider directly.  This one runs it inside
;; a real turn, with the retry and fallback modules loaded beside it, so
;; the tests see the filter chains as they are at start: which module
;; decided, in which order, whether a step was sent again, and where the
;; session ended up.  Every request goes to a fake HTTP layer -- no test
;; here makes a live call -- and the state layer is a fresh temporary
;; directory per test.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-provider-openrouter)
(require 'harness-session)
(require 'harness-provider-openrouter-test-helpers)

;;;; Bounded retry: the integrated chain, with the retry and fallback modules loaded

(defun harness-openrouter-test--chain-failure (text &rest props)
  "Return the events of a step that fails with TEXT and PROPS."
  (list (append (list :type 'done :stop-reason 'error :error text) props)))

(defun harness-openrouter-test--completion-requests ()
  "Return the completion requests the fake served, newest first."
  (cl-remove-if-not (lambda (r) (string-match-p "chat/completions" (plist-get r :url)))
                    harness-openrouter-test--requests))

(defun harness-openrouter-test--chain-hints (sid)
  "Return the hint texts of session SID, oldest first."
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'hint))
                            (harness-call 'session/nodes sid))))

(defun harness-openrouter-test--chain-session ()
  "Create a session pinned to this model's DeepInfra endpoint, and return its id.
The pin is the one a first request would have chosen, stored as that
request stores it."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                      :model (format "openrouter:%s"
                                                     harness-openrouter-test-model))
                        :id)))
    (harness-call 'session/set-ext sid :openrouter-route (harness-openrouter-test--route))
    sid))

(defun harness-openrouter-test--chain-state (sid)
  "Return SESSION SID's pinned route as the store has it."
  (harness-openrouter--route-of (harness-call 'session/get sid)))

(defmacro harness-openrouter-test-with-chain (&rest body)
  "Run BODY with the retry and fallback modules loaded and a real turn.
The OpenRouter provider is registered as it is in a Harness, with a
static listing so a session can be made on it without a key, and every
request it makes goes to the fake HTTP layer: the endpoint catalogue,
then a completion per step, answered by
`harness-openrouter-test--completion-script' (or a plain answer).  The
real `agent/step-error' and `agent/before-turn' chains run, so a test
sees what a real turn does: which module decided, in which order, and
whether the step was sent again."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider tools session agent retry fallback))
       (harness-test-load-module m))
     ;; The generic transport is started first, as at a real start, then the
     ;; module that builds on it; its own step-error filter lands in the
     ;; chain beside the retry and fallback modules'.
     (harness-test-load-module 'provider-openai)
     (harness-test-load-module 'provider-openrouter)
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-retry--attempts)
     ;; The module's own attempt counter exists only where its retry bounds
     ;; are enforced; a test run against a tree without it still runs.
     (when (boundp 'harness-openrouter--attempts)
       (clrhash harness-openrouter--attempts))
     (clrhash harness-fallback--marks)
     (clrhash harness-fallback--moved)
     (setq harness-openrouter-test--completion-script nil
           harness-openrouter-test--completions 0)
     (let ((default-directory dir)
           (harness-retry-delay 0.01)
           (harness-retry-jitter 0)
           (harness-retry-max-delay 0.05)
           (harness-fallback-models nil)
           (harness-openrouter-routing nil)
           (harness-openai--models-cache (make-hash-table :test 'eq))
           (harness-openai-endpoints
            (list (list :id 'openrouter :label "OpenRouter"
                        :base-url "https://openrouter.ai/api/v1"
                        :models (list harness-openrouter-test-model))))
           (harness-openrouter--catalogue (make-hash-table :test 'equal))
           (harness-openrouter--fetching (make-hash-table :test 'equal))
           (harness-openrouter-test--requests nil)
           (harness-openrouter-test--responses nil))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ;; Somewhere for a fallback to go, so a test can prove it does not:
       ;; a real second provider, which records what it is asked.
       (harness-define-provider 'other-provider
         :label "Other"
         :models (lambda () (harness-resolved
                             (list (list :name "other-model"
                                         :pricing '(:input 3.0 :output 6.0)))))
         :complete
         (lambda (request)
           (let ((on-event (or (plist-get request :on-event) #'ignore)))
             (push (list :url "other-provider" :json request)
                   harness-openrouter-test--requests)
             (harness-run-soon
              (lambda ()
                (funcall on-event '(:type start))
                (funcall on-event '(:type text :delta "ok elsewhere"))
                (funcall on-event '(:type done :stop-reason end-turn))))
             (list :cancel #'ignore))))
       (harness-openrouter-refresh)
       ;; The fake is installed around BODY itself, not around a form that
       ;; binds its own copy of the request list, so the assertions in BODY
       ;; read the same binding the fake records into.
       (unwind-protect
           (let ((auth-sources nil))
             (cl-letf (((symbol-function 'harness-http-request)
                        #'harness-openrouter-test--fake-request))
               (setq harness-openrouter-test--responses
                     (list (cons (harness-openrouter-test--catalogue-url-regexp)
                                 (list :body (harness-openrouter-test--catalogue-json)))
                           (cons "chat/completions"
                                 (harness-openrouter-test--chain-answer))))
               ,@body))
         (harness-fallback--shutdown)
         (harness-retry--shutdown)
         (harness-openrouter--shutdown)
         (harness-provider-unregister 'openrouter)
         (harness-openai--register-all)))))

(ert-deftest harness-provider-openrouter-permanent-rejection-stops-the-chain ()
  "A typed permanent rejection is not retried, whatever the modules say.
The retry and fallback modules are loaded, and a handler after this one
answers `:retry t' for everything: the `:final' on this module's stop is
what keeps that from turning a rejection an identical request cannot
pass into a retry.  Nothing is sent a second time."
  (harness-openrouter-test-with-chain
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (setq harness-openrouter-test--completion-script
          (lambda (_)
            (harness-openrouter-test--chain-http
             400 (harness-json-encode
                  '(:error (:code 400
                            :message "Upstream error from OpenInference: Upstream returned HTTP 400"
                            :metadata (:error_type "invalid_request"
                                       :provider_name "OpenInference"))
                    :id "gen-400")))))
    ;; A filter after this module that would retry anything.
    (harness-add-filter 'agent/step-error
                        (lambda (_v next &rest _) (funcall next (list :retry t))) 90)
    (let ((sid (harness-openrouter-test--chain-session)))
      (should (eq 'error (plist-get (harness-test-await
                                     (harness-call 'agent/prompt sid "go") 20)
                                    :stop-reason)))
      (should (= 1 (length (harness-openrouter-test--completion-requests))))
      (should (cl-some (lambda (h) (string-match-p "error_type=invalid_request" h))
                       (harness-openrouter-test--chain-hints sid)))
      (should-not (cl-some (lambda (h) (string-match-p "trying again" h))
                           (harness-openrouter-test--chain-hints sid))))))

(ert-deftest harness-provider-openrouter-retryable-failure-is-tried-again ()
  "A transient failure is retried on the same endpoint, inside the bounds.
Every request of the turn goes to the pinned OpenRouter endpoint, and the
catalogue is not read again: a retry is the same endpoint, not a new
choice."
  (harness-openrouter-test-with-chain
    (setq harness-openrouter-routing
          (harness-openrouter-test-policy :retry '(:max-attempts 2 :max-seconds 30
                                                   :max-output-tokens 4096)))
    (setq harness-openrouter-test--completion-script
          (lambda (step)
            (if (= step 1)
                (harness-openrouter-test--chain-error 'transport)
              (harness-openrouter-test--chain-answer))))
    (let ((sid (harness-openrouter-test--chain-session)))
      (should (eq 'end-turn (plist-get (harness-test-await
                                        (harness-call 'agent/prompt sid "go") 20)
                                       :stop-reason)))
      (should (= 2 (length (harness-openrouter-test--completion-requests))))
      (dolist (request (harness-openrouter-test--completion-requests))
        (should (equal "https://openrouter.ai/api/v1/chat/completions"
                       (plist-get request :url))))
      ;; The first retry is announced as the same endpoint.
      (should (cl-some (lambda (h) (string-match-p "same endpoint" h))
                       (harness-openrouter-test--chain-hints sid)))
      ;; The pin did not move and no catalogue request was made.
      (should (equal "deepinfra/fp8"
                     (plist-get (harness-openrouter-test--chain-state sid) :slug))))))

(ert-deftest harness-provider-openrouter-attempt-bound-stops-the-retries ()
  "Past the policy's attempts, the turn stops instead of trying again.
The bound is the policy's, not `harness-retry-max-attempts': a policy of
one attempt stops after the first failure however high the generic
setting is, and the reason says which bound was reached."
  (harness-openrouter-test-with-chain
    (setq harness-retry-max-attempts 9)
    (setq harness-openrouter-routing
          (harness-openrouter-test-policy :retry '(:max-attempts 1 :max-seconds 60
                                                   :max-output-tokens 4096)))
    (setq harness-openrouter-test--completion-script
          (lambda (_) (harness-openrouter-test--chain-http 503)))
    (let ((sid (harness-openrouter-test--chain-session)))
      (should (eq 'error (plist-get (harness-test-await
                                     (harness-call 'agent/prompt sid "go") 20)
                                    :stop-reason)))
      ;; One attempt, and no more: the failure that follows it reaches the
      ;; bound before it is ever sent again.
      (should (= 1 (length (harness-openrouter-test--completion-requests))))
      (should (cl-some (lambda (h) (string-match-p "allows 1 attempt" h))
                       (harness-openrouter-test--chain-hints sid))))))

(ert-deftest harness-provider-openrouter-time-bound-stops-the-retries ()
  "Past the policy's elapsed seconds, the turn stops instead of trying again.
A first attempt that was waited out counts against the time bound: the
second failure, with no time left in the policy, is where it ends."
  (harness-openrouter-test-with-chain
    (setq harness-openrouter-routing
          (harness-openrouter-test-policy :retry '(:max-attempts 5 :max-seconds 1
                                                   :max-output-tokens 4096)))
    (setq harness-openrouter-test--completion-script
          (lambda (_) (harness-openrouter-test--chain-error 'transport)))
    ;; The waits between attempts are the policy's own bound: a first wait
    ;; of a second takes the elapsed time past `:max-seconds', so the
    ;; failure after it is not tried again.
    (let ((harness-retry-delay 1.0)
          (harness-retry-max-delay 5.0))
      (let ((sid (harness-openrouter-test--chain-session)))
        (should (eq 'error (plist-get (harness-test-await
                                       (harness-call 'agent/prompt sid "go") 20)
                                      :stop-reason)))
        (should (cl-some (lambda (h) (string-match-p "allows 1 s of retrying" h))
                         (harness-openrouter-test--chain-hints sid)))
        (should (= 2 (length (harness-openrouter-test--completion-requests))))))))

;;;; Nothing implicit may move a pinned session off its endpoint

(ert-deftest harness-provider-openrouter-fallback-never-moves-a-pinned-session ()
  "A pinned session stops when its provider runs out; it does not move.
The fallback module is loaded with a list to carry on with, and the
provider answers 402, which the fallback reads as out of money.  The
guard keeps the session on OpenRouter: the step is not retried, the
session's model does not change, no other provider is asked, and the
hint says what a person can do about it."
  (harness-openrouter-test-with-chain
    (setq harness-fallback-models '("other-provider:other-model"))
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (setq harness-openrouter-test--completion-script
          (lambda (_)
            (harness-openrouter-test--chain-http
             402 (harness-json-encode
                  '(:error (:code 402 :message "Insufficient credits."))))))
    (let ((sid (harness-openrouter-test--chain-session))
          (switched nil))
      (harness-on 'fallback/switched (lambda (&rest args) (push args switched)))
      (should (eq 'error (plist-get (harness-test-await
                                     (harness-call 'agent/prompt sid "go") 20)
                                    :stop-reason)))
      ;; The session is still on its pinned model, and nothing else ran.
      (should (equal (format "openrouter:%s" harness-openrouter-test-model)
                     (plist-get (harness-call 'session/get sid) :model)))
      (should-not switched)
      (should (= 1 (length (harness-openrouter-test--completion-requests))))
      (dolist (request (harness-openrouter-test--completion-requests))
        (should (equal "https://openrouter.ai/api/v1/chat/completions"
                       (plist-get request :url))))
      ;; And the hint says the pin is why, and what a person can do.
      (should (cl-some (lambda (h) (and (string-match-p "pinned" h)
                                        (string-match-p "harness-openrouter-switch" h)))
                       (harness-openrouter-test--chain-hints sid))))))

(ert-deftest harness-provider-openrouter-guard-stops-a-turn-before-it-starts ()
  "A session whose own provider is marked out does not start on another.
The fallback's before-turn hook would carry the turn on with its list;
the guard refuses, the turn does not start, and the reason is recorded."
  (harness-openrouter-test-with-chain
    (setq harness-fallback-models '("other-provider:other-model"))
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (let ((sid (harness-openrouter-test--chain-session)))
      (harness-call 'fallback/mark (format "openrouter:%s" harness-openrouter-test-model)
                    :until (+ (float-time) 3600) :reason "used up")
      (let ((result (harness-test-await (harness-call 'agent/prompt sid "go") 20)))
        (should (eq 'blocked (plist-get result :stop-reason)))
        (should (string-match-p "pinned" (or (plist-get result :error) ""))))
      (should (equal (format "openrouter:%s" harness-openrouter-test-model)
                     (plist-get (harness-call 'session/get sid) :model)))
      (should-not (harness-openrouter-test--completion-requests)))))

(provide 'harness-provider-openrouter-chain-test)
;;; harness-provider-openrouter-chain-test.el ends here
