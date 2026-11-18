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
           (harness-openrouter--catalogue-failures (make-hash-table :test 'equal))
           (harness-openrouter-test--requests nil)
           (harness-openrouter-test--responses nil)
           (harness-openrouter-test--catalogue-script nil)
           (harness-openrouter-test--catalogue-reads-served 0))
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
choice.  The bounds are the shared retry layer's -- one setting for
every provider -- and the hint says whose request was repeated."
  (harness-openrouter-test-with-chain
    (setq harness-retry-max-attempts 1)
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
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
      ;; The first retry is announced as the same endpoint, for OpenRouter.
      (should (cl-some (lambda (h) (string-match-p "OpenRouter: network error.*trying again" h))
                       (harness-openrouter-test--chain-hints sid)))
      ;; The pin did not move and no catalogue request was made.
      (should (equal "deepinfra/fp8"
                     (plist-get (harness-openrouter-test--chain-state sid) :slug))))))

(ert-deftest harness-provider-openrouter-attempt-bound-stops-the-retries ()
  "Past the shared attempts bound, the turn stops instead of trying again.
`harness-retry-max-attempts' 0 allows one request's first send and no
retry, so a provider that keeps failing is sent once and no more -- the
non-OpenRouter `harness-retry` module cannot send it again by itself,
because a send it made would be one this policy never authorised."
  (harness-openrouter-test-with-chain
    (setq harness-retry-max-attempts 0)
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (setq harness-openrouter-test--completion-script
          (lambda (_) (harness-openrouter-test--chain-http 503)))
    (let ((sid (harness-openrouter-test--chain-session)))
      (should (eq 'error (plist-get (harness-test-await
                                     (harness-call 'agent/prompt sid "go") 20)
                                    :stop-reason)))
      ;; One attempt, and no more.
      (should (= 1 (length (harness-openrouter-test--completion-requests)))))))

(ert-deftest harness-provider-openrouter-time-bound-stops-the-retries ()
  "A retry that cannot start inside the shared seconds bound is never sent.
The wait the backoff asks for is compared with what is left of
`harness-retry-max-seconds' when the retry is scheduled: a one-second
wait under a one-second bound would start the next attempt after the
bound, so the turn stops instead of sleeping first and finding out at
the next send."
  (harness-openrouter-test-with-chain
    (setq harness-retry-max-seconds 1)
    (setq harness-retry-max-attempts 5)
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (setq harness-openrouter-test--completion-script
          (lambda (_) (harness-openrouter-test--chain-error 'transport)))
    (let ((harness-retry-delay 1.0)
          (harness-retry-max-delay 5.0))
      (let ((sid (harness-openrouter-test--chain-session)))
        (should (eq 'error (plist-get (harness-test-await
                                       (harness-call 'agent/prompt sid "go") 20)
                                      :stop-reason)))
        (should (cl-some (lambda (h) (string-match-p "would start the next attempt after" h))
                         (harness-openrouter-test--chain-hints sid)))
        ;; The one attempt was made; the wait that would overrun the bound
        ;; was not spent, and nothing was sent after it.
        (should (= 1 (length (harness-openrouter-test--completion-requests))))))))

(ert-deftest harness-provider-openrouter-time-bound-counts-the-sent-time ()
  "Time spent making the first attempt is already inside the bound.
The clock starts at the request's first send, not at its first failure,
so an attempt that took a while leaves less than a full bound for a
retry: with the bound spent by the attempt, no retry is scheduled."
  (harness-openrouter-test-with-chain
    (setq harness-retry-max-seconds 1)
    (setq harness-retry-max-attempts 5)
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    ;; The fake spends the bound making the first attempt, as a slow
    ;; provider does, and then fails.
    (setq harness-openrouter-test--completion-script
          (lambda (_) (sleep-for 1.1) (harness-openrouter-test--chain-error 'transport)))
    (setq harness-retry-delay 0.01)
    (setq harness-retry-max-delay 0.05)
    (let ((sid (harness-openrouter-test--chain-session)))
      (should (eq 'error (plist-get (harness-test-await
                                     (harness-call 'agent/prompt sid "go") 20)
                                    :stop-reason)))
      ;; The bound is spent by the attempt itself; how many seconds the
      ;; answer says passed depends on the machine, so only that it is
      ;; past the one-second bound is asserted.
      (should (cl-some (lambda (h) (string-match-p
                                    "OpenRouter: one request and its retries may take 1 s, and [0-9]+ s passed"
                                    h))
                       (harness-openrouter-test--chain-hints sid)))
      (should (= 1 (length (harness-openrouter-test--completion-requests)))))))

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

;;;; A governed request is never handed to another host

(defun harness-openrouter-test--other-provider-sends ()
  "Return the requests the other provider was sent, newest first."
  (cl-remove-if-not (lambda (r) (equal "other-provider" (plist-get r :url)))
                    harness-openrouter-test--requests))

(defun harness-openrouter-test--during-failure (edit)
  "Return a completion script that makes a 402 fail while EDIT runs.
EDIT is called once, from inside the failed step, before the failure
reaches `agent/step-error' -- which is what an in-flight policy change
looks like to the fallback and the guard that then run."
  (lambda (_)
    (funcall edit)
    (harness-openrouter-test--chain-http
     402 (harness-json-encode '(:error (:code 402 :message "Insufficient credits."))))))

(ert-deftest harness-openrouter-a-disabled-policy-does-not-hand-a-request-on ()
  "Disabling the policy during an in-flight 402 sends nothing to another host.
This is the reported finding: the guard asked whether a policy was
*enabled* now, so disabling it mid-request read as permission to disclose
the request elsewhere, and the fallback moved the session to
`other-provider:other-model'.  What authorises a send is the request's
own record of what it was sent under, so the request stays pinned: the
turn fails, the session keeps its model, and the other provider is sent
nothing at all."
  (harness-openrouter-test-with-chain
    (setq harness-fallback-models '("other-provider:other-model"))
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (let* ((policy harness-openrouter-routing)
           (sends 0))
      (harness-on 'fallback/switched (lambda (&rest _) (cl-incf sends)))
      (setq harness-openrouter-test--completion-script
            (harness-openrouter-test--during-failure
             (lambda ()
               (setq harness-openrouter-routing
                     (plist-put (copy-sequence policy) :enabled nil)))))
      (let ((sid (harness-openrouter-test--chain-session)))
        (should (eq 'error (plist-get (harness-test-await
                                       (harness-call 'agent/prompt sid "go") 20)
                                      :stop-reason)))
        ;; Nothing was disclosed anywhere else, and the session did not move.
        (should (= 0 (length (harness-openrouter-test--other-provider-sends))))
        (should (= 0 sends))
        (should (equal (format "openrouter:%s" harness-openrouter-test-model)
                       (plist-get (harness-call 'session/get sid) :model)))
        ;; The one request went to the pinned endpoint, restricted.
        (should (= 1 (length (harness-openrouter-test--completion-requests))))
        (let ((body (plist-get (car (harness-openrouter-test--completion-requests)) :json)))
          (should (equal '("deepinfra/fp8")
                         (append (plist-get (plist-get body :provider) :only) nil))))
        (should (cl-some (lambda (h) (string-match-p "pinned" h))
                         (harness-openrouter-test--chain-hints sid)))))))

(ert-deftest harness-openrouter-a-removed-policy-does-not-hand-a-request-on ()
  "Rolling the policy back to nil during an in-flight 402 changes nothing either.
Nil is documented as the legacy pass-through for the *next* request; a
request already sent under the policy keeps its restrictions, so the
rollback cannot return a governed workload to unrestricted routing.  The
fallback is refused, no other provider is sent anything, and the next
turn is the operator's plain provider again."
  (harness-openrouter-test-with-chain
    (setq harness-fallback-models '("other-provider:other-model"))
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (setq harness-openrouter-test--completion-script
          (harness-openrouter-test--during-failure
           (lambda () (setq harness-openrouter-routing nil))))
    (let ((sid (harness-openrouter-test--chain-session)))
      (should (eq 'error (plist-get (harness-test-await
                                     (harness-call 'agent/prompt sid "go") 20)
                                    :stop-reason)))
      (should (= 0 (length (harness-openrouter-test--other-provider-sends))))
      (should (equal (format "openrouter:%s" harness-openrouter-test-model)
                     (plist-get (harness-call 'session/get sid) :model)))
      (should (= 1 (length (harness-openrouter-test--completion-requests)))))))

(ert-deftest harness-openrouter-a-lowered-policy-does-not-hand-a-request-on ()
  "Narrowing the policy during an in-flight 402 is a refusal, not a fallback.
Dropping the pinned provider, lowering the maximum and changing the
model are the edits that decide a request; the request that was sent
under the policy is disclosed nowhere else because of any of them."
  (harness-openrouter-test-with-chain
    (setq harness-fallback-models '("other-provider:other-model"))
    (dolist (edit '(drop-provider lower-limit narrow-model))
      ;; Each edit is one turn of one session: the marks a 402 leaves are
      ;; this iteration's, so the next starts with none.
      (clrhash harness-fallback--marks)
      (let ((harness-openrouter-test--completion-script nil))
        (setq harness-openrouter-routing (harness-openrouter-test-policy))
        (let ((policy harness-openrouter-routing))
          (setq harness-openrouter-test--completion-script
                (harness-openrouter-test--during-failure
                 (lambda ()
                   (setq harness-openrouter-routing
                         (pcase edit
                           ('drop-provider (plist-put (copy-sequence policy)
                                                      :providers (list "Cohere")))
                           ('lower-limit (plist-put (copy-sequence policy) :max-price
                                                    '(:prompt 0.01 :completion 0.01
                                                      :cache-read 0.0001)))
                           ('narrow-model (plist-put (copy-sequence policy)
                                                     :model "deepseek/deepseek-v3")))))))
          (let* ((before (length (harness-openrouter-test--completion-requests)))
                 (sid (harness-openrouter-test--chain-session)))
            (should (eq 'error (plist-get (harness-test-await
                                           (harness-call 'agent/prompt sid "go") 20)
                                          :stop-reason)))
            (should (= 0 (length (harness-openrouter-test--other-provider-sends))))
            (should (equal (format "openrouter:%s" harness-openrouter-test-model)
                           (plist-get (harness-call 'session/get sid) :model)))
            ;; One POST for this edit: the request failed once, and was
            ;; neither repeated nor re-pointed.
            (should (= (1+ before)
                       (length (harness-openrouter-test--completion-requests))))))))))

;;;; An outage is waited out inside a real turn

(ert-deftest harness-provider-openrouter-a-turn-waits-out-a-catalogue-outage ()
  "A real turn waits for a transient catalogue outage instead of failing.
This is the reported failure in its own terms: the turn's step found the
catalogue unreadable, and the turn ended `error' with
`catalogue-unavailable' -- every time, for nine tasks at once.  The step
now waits for the episode's own re-read, and when the catalogue comes
back the turn goes on and ends as any turn does.  No other provider is
asked, nothing is retried elsewhere, and the pin is the one the settled
reading allows."
  (harness-openrouter-test-with-chain
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (setq harness-openrouter-catalogue-wait 10)
    ;; The first catalogue read fails as the live one did; the re-read the
    ;; wait starts is answered from the fixture.
    ;; The first catalogue read stalls; the episode's own re-read answers.
    (setq harness-openrouter-test--catalogue-script
          (lambda (read)
            (if (= read 1)
                '(:error (http-error 200 (timeout "request timed out after 20s")))
              (list :body (harness-openrouter-test--catalogue-json)))))
    (let ((sid (harness-openrouter-test--chain-session)))
      ;; The pin the session already holds is outside the policy's bound,
      ;; so this step must read the catalogue, and it is out.
      (harness-call 'session/set-ext sid :openrouter-route
                    (harness-openrouter-test--route '(:catalogue-at 0.0)))
      (let ((result (harness-test-await (harness-call 'agent/prompt sid "go") 30)))
        (should (eq 'end-turn (plist-get result :stop-reason)))
        (should-not (plist-get result :error)))
      ;; One completion, to the pinned endpoint, after the catalogue came
      ;; back; nothing went to the other provider.
      (should (= 1 (length (harness-openrouter-test--completion-requests))))
      (should (= 0 (length (harness-openrouter-test--other-provider-sends))))
      (should (cl-some (lambda (h) (string-match-p "catalogue unavailable" h))
                       (harness-openrouter-test--chain-hints sid))))))

(ert-deftest harness-provider-openrouter-a-cancelled-turn-does-not-wait-out-an-outage ()
  "A turn cancelled while it waits for the catalogue is not sent afterwards.
The wait is the step's, and a cancelled turn stops waiting at once: when
the reading arrives nothing is sent for that turn, and no completion goes
out at all."
  (harness-openrouter-test-with-chain
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (setq harness-openrouter-catalogue-wait 10)
    (setq harness-openrouter-test--catalogue-script
          (lambda (read)
            (if (= read 1)
                '(:error (http-error 200 (timeout "request timed out after 20s")))
              ;; The re-read is held, so the turn is still waiting when it
              ;; is cancelled; the test answers it afterwards, and nothing
              ;; may be sent for the cancelled turn.
              :hold)))
    (let* ((sid (harness-openrouter-test--chain-session)))
      ;; The pin is stale before the turn starts, so the first step must
      ;; read the catalogue, and it is out.
      (harness-call 'session/set-ext sid :openrouter-route
                    (harness-openrouter-test--route '(:catalogue-at 0.0)))
      (let ((turn (harness-call 'agent/prompt sid "go")))
        (harness-test-wait
         (lambda () (> (plist-get (harness-openrouter-catalogue-status) :waiting) 0))
         10 "the turn to wait for the catalogue")
        (harness-call 'agent/cancel sid)
        (let ((result (harness-test-await turn 20)))
          (should (memq (plist-get result :stop-reason) '(cancelled error))))
        ;; The step left the wait when it was cancelled: nothing of it is
        ;; waiting, whatever the catalogue answers now.
        (should (zerop (plist-get (harness-openrouter-catalogue-status) :waiting)))
        (harness-test-wait (lambda () harness-openrouter-test--held-catalogues)
                           10 "the re-read the wait started")
        (harness-openrouter-test--answer-catalogue)
        (sit-for 0.2)
        ;; Nothing was sent for the cancelled turn.
        (should (= 0 (length (harness-openrouter-test--completion-requests))))))))

(provide 'harness-provider-openrouter-chain-test)
;;; harness-provider-openrouter-chain-test.el ends here
