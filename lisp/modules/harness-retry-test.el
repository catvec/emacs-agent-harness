;;; harness-retry-test.el --- Tests for retrying transiently failed steps  -*- lexical-binding: t; -*-

;;; Commentary:

;; The module answers `agent/step-error' for a failure a connection or a
;; rate limit caused, so the step runs again on the same provider after a
;; wait, and the agent drops the partial answer the failed step streamed
;; (`harness-agent--rewind-step').  One test runs the real OpenAI provider
;; against a server in this Emacs that resets a stream in the middle and
;; then answers, the way a proxy dropped the connection in the field.
;;
;; It is also the one place the retry bounds live, for every provider:
;; how many times a request may be sent (`harness-retry-max-attempts'),
;; how long it and its retries may take (`harness-retry-max-seconds'),
;; and how long a retry waits.  The waits are drawn here once and the
;; value drawn is the value waited (`harness-retry-wait-plan'), which the
;; deterministic jitter test below pins: a jittered wait checked as one
;; delay and spent as another could be admitted under a bound and then
;; sleep past it.

;;; Code:

(require 'harness-test-helpers)
;; Some tests below read the module's own functions without starting a
;; turn, so they need it loaded before the first one runs.
(require 'harness-retry)

(defvar harness-retry-test-requests nil
  "The requests the scripted provider was sent, oldest first.")

(defmacro harness-retry-test-with (&rest body)
  "Load the state layer with a scripted provider, the retry module, and run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider tools session agent retry))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-retry--attempts)
     (let ((default-directory dir)
           (harness-retry-delay 0.01)
           (harness-retry-jitter 0))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-retry-test-define-provider (script)
  "Define provider `scripted-retry' whose completion SCRIPT answers each step.
SCRIPT is called with the number of the step (1 the first) and returns
the events to send, as a list of plists, the last of them a `done'."
  (setq harness-retry-test-requests nil)
  (harness-define-provider 'scripted-retry
    :label "Scripted retry"
    :complete
    (lambda (request)
      (let ((on-event (or (plist-get request :on-event) #'ignore))
            (step (1+ (length harness-retry-test-requests)))
            (cancelled nil))
        (push request harness-retry-test-requests)
        (harness-run-soon
         (lambda ()
           (unless cancelled
             (funcall on-event '(:type start))
             (dolist (ev (funcall script step))
               (funcall on-event ev)))))
        (list :cancel (lambda ()
                        (setq cancelled t)
                        (funcall on-event '(:type done :stop-reason cancelled))))))))

(defun harness-retry-test-session ()
  "Make a session on the scripted provider."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "scripted-retry:m") :id))

(defun harness-retry-test-nodes (id &optional kind)
  "Return the transcript nodes of session ID, of KIND when given."
  (let ((nodes (harness-call 'session/nodes id)))
    (if kind (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) kind)) nodes) nodes)))

(defun harness-retry-test-hints (id)
  "Return the hint texts of session ID, oldest first."
  (mapcar (lambda (n) (plist-get n :content)) (harness-retry-test-nodes id 'hint)))

(defun harness-retry-test--sent (request &optional state)
  "Return REQUEST as a provider sends it, carrying STATE (a fresh one by default)."
  (let ((state (or state (make-harness-retry--request))))
    (setf (harness-retry--request-count state) 1
          (harness-retry--request-since state) (float-time))
    (harness-retry-attach request state)))

(defun harness-retry-test--failed (request text kind)
  "Return the `done' FAILURE of REQUEST, saying TEXT of KIND."
  (harness-retry--carry (list :type 'done :stop-reason 'error :error text :error-kind kind)
                        request))

(ert-deftest harness-retry-tries-a-transport-failure-again ()
  "A step whose stream was cut is run again, and its partial answer dropped.
The retry must not leave the half answer the failed step streamed in
the transcript, where the model would read it as its own words twice."
  (harness-retry-test-with
    (harness-retry-test-define-provider
     (lambda (step)
       (if (= step 1)
           '((:type thinking :delta "thinking out loud")
             (:type text :delta "half an answer")
             (:type done :stop-reason error
                    :error "the connection was reset by the peer" :error-kind transport))
         '((:type text :delta "the whole answer")
           (:type done :stop-reason end-turn)))))
    (let ((id (harness-retry-test-session)))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
      (should (= 2 (length harness-retry-test-requests)))
      ;; Only the retried answer remains: no partial text, no partial thinking.
      (should (equal '("the whole answer")
                     (mapcar (lambda (n) (plist-get n :content))
                             (harness-retry-test-nodes id 'assistant))))
      (should-not (harness-retry-test-nodes id 'thinking))
      (should (cl-some (lambda (h) (string-match-p "trying again" h)) (harness-retry-test-hints id))))))

(ert-deftest harness-retry-gives-up-after-its-cap ()
  "A provider that stays down ends the turn, with the tries bounded and said."
  (harness-retry-test-with
    (let ((harness-retry-max-attempts 2))
      (harness-retry-test-define-provider
       (lambda (_step)
         '((:type text :delta "a last attempt")
           (:type done :stop-reason error
                  :error "the connection was reset by the peer" :error-kind transport))))
      (let ((id (harness-retry-test-session)))
        (should (eq 'error (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
        ;; The first attempt and two retries, and no more.
        (should (= 3 (length harness-retry-test-requests)))
        (should (cl-some (lambda (h) (string-match-p "giving up after 2 tries" h))
                         (harness-retry-test-hints id)))
        ;; Nothing was tried after that: the turn is over.
        (should (equal '("a last attempt")
                       (mapcar (lambda (n) (plist-get n :content))
                               (harness-retry-test-nodes id 'assistant))))))))

(ert-deftest harness-retry-leaves-quota-and-billing-to-the-fallback ()
  "A failure another handler's business ends the turn here, not another step."
  (harness-retry-test-with
    (harness-retry-test-define-provider
     (lambda (_step)
       '((:type done :stop-reason error
              :error "You've hit your limit · resets 3pm" :error-kind quota))))
    (let ((id (harness-retry-test-session)))
      (should (eq 'error (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
      (should (= 1 (length harness-retry-test-requests))))))

(ert-deftest harness-retry-reads-a-transport-failure-from-its-text ()
  "A provider that names no kind still gets a retry when the words say so."
  (harness-retry-test-with
    (harness-retry-test-define-provider
     (lambda (step)
       (if (= step 1)
           '((:type done :stop-reason error
                  :error "curl exited 56 (exited abnormally with code 56): Recv failure: Connection reset by peer"))
         '((:type text :delta "back") (:type done :stop-reason end-turn)))))
    (let ((id (harness-retry-test-session)))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
      (should (= 2 (length harness-retry-test-requests))))))

(ert-deftest harness-retry-tries-again-when-the-provider-process-died ()
  "A CLI provider's process killed mid-turn is started again by the next try.
An exit the program chose, with a message, ends the turn as before."
  (harness-retry-test-with
    (harness-retry-test-define-provider
     (lambda (step)
       (if (= step 1)
           '((:type done :stop-reason error :error "claude exited with status 9"))
         '((:type text :delta "back") (:type done :stop-reason end-turn)))))
    (let ((id (harness-retry-test-session)))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
      (should (= 2 (length harness-retry-test-requests)))
      (should (cl-some (lambda (h) (string-match-p "\\`the provider's process died: claude exited with status 9; trying again" h))
                       (harness-retry-test-hints id)))))
  (should (eq 'process (harness-retry-kind '(:error "claude exited with status 137: Killed"))))
  (should-not (harness-retry-kind '(:error "claude exited with status 1: Invalid API key")))
  (should-not (harness-retry-kind '(:error "claude exited with status 90"))))

(ert-deftest harness-retry-honours-retry-after ()
  "A rate limit that asked for a wait is waited for, its delay capped."
  (should (= 3 (let ((harness-retry-delay 0.5) (harness-retry-jitter 0))
                 (harness-retry-backoff 1 '(:retry-after 3)))))
  (should (= 30.0 (let ((harness-retry-delay 1) (harness-retry-jitter 0)
                        (harness-retry-max-delay 30.0))
                    (harness-retry-backoff 1 '(:retry-after 600)))))
  ;; Never sooner than the backoff: a server's wait is a minimum.
  (should (= 10.0 (let ((harness-retry-delay 10) (harness-retry-jitter 0))
                    (harness-retry-backoff 1 '(:retry-after 3)))))
  (should (= 4.0 (let ((harness-retry-delay 1) (harness-retry-jitter 0))
                   (harness-retry-backoff 3 '(:retry-after nil))))) ; 1, 2, 4
  (harness-retry-test-with
    (let ((harness-retry-delay 0.05))
      (harness-retry-test-define-provider
       (lambda (step)
         (if (= step 1)
             '((:type done :stop-reason error :error "Rate limit exceeded"
                    :error-kind rate-limit :retry-after 0.01))
           '((:type text :delta "after the wait") (:type done :stop-reason end-turn)))))
      (let ((id (harness-retry-test-session)))
        (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
        (should (= 2 (length harness-retry-test-requests)))
        (should (cl-some (lambda (h) (string-match-p "rate limited" h)) (harness-retry-test-hints id)))))))

(ert-deftest harness-retry-does-not-retry-a-cancelled-turn ()
  "A turn cancelled while it waits to try again tries nothing."
  (harness-retry-test-with
    (let ((harness-retry-delay 0.3))
      (harness-retry-test-define-provider
       (lambda (_step)
         '((:type text :delta "cut off")
           (:type done :stop-reason error
                  :error "the connection was reset by the peer" :error-kind transport))))
      (let* ((id (harness-retry-test-session))
             (turn (harness-call 'agent/prompt id "go")))
        (harness-test-wait (lambda () (= 1 (length harness-retry-test-requests))) 5 "the first step")
        (harness-call 'agent/cancel id)
        (should (eq 'cancelled (plist-get (harness-await turn) :stop-reason)))
        (accept-process-output nil 0.5)      ; well past the retry delay
        (should (= 1 (length harness-retry-test-requests)))))))

;;;; A real provider against a server that drops the stream

(ert-deftest harness-retry-drops-a-stream-cut-in-the-middle ()
  "The OpenAI provider's stream reset mid-answer is retried, without the partial text.
This is the failure the field reported: a session on a DeepSeek model,
a connection reset, and a turn that ended with curl's exit code."
  (skip-unless (executable-find "curl"))
  (harness-retry-test-with
    (let* ((partial (concat "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}\n\n"
                            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo the\"}}]}\n\n"))
           (full (concat "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello there\"}}]}\n\n"
                         "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
                         "data: [DONE]\n\n"))
           (server (harness-test-http-serve
                    `(("/chat/completions" .
                       ,(lambda (attempt)
                          (if (= attempt 1)
                              (list 200 '(("Content-Type" . "text/event-stream"))
                                    partial :chunks 4 :reset-after 1)
                            (list 200 '(("Content-Type" . "text/event-stream")) full)))))))
           (endpoint (list :id 'testlocal :label "Local test server"
                           :base-url (harness-test-http-url server "") :api-key "sk-test")))
      (unwind-protect
          (progn
            (harness-test-load-module 'provider-openai)
            (harness-openai-register-endpoint endpoint)
            (let* ((session (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                                     :model "testlocal:local-model")
                                       :id)))
              (harness-await (harness-call 'agent/prompt session "hi"))
              (should (equal '("Hello there")
                             (mapcar (lambda (n) (plist-get n :content))
                                     (harness-retry-test-nodes session 'assistant))))
              (should (cl-some (lambda (h) (string-match-p "trying again" h))
                               (harness-retry-test-hints session)))))
        (delete-process server)))))

;;;; One wait, drawn once, and the value checked is the value waited

(defvar harness-retry-test-draws nil
  "How many times the mocked `random' was called, for the jitter tests.")

(defun harness-retry-test--draws (values)
  "Make each `random' call return the next of VALUES, in order, and count it.
A call past the last value errors rather than reading as a pass, and
`harness-retry-test-draws' says how many were made: a delay drawn and
not checked is exactly the bug the tests below exist for."
  (let ((left (copy-sequence values)))
    (setq harness-retry-test-draws 0)
    (lambda (&optional _limit)
      (unless left (error "a delay was drawn more often than the test planned"))
      (setq harness-retry-test-draws (1+ harness-retry-test-draws))
      (pop left))))

(ert-deftest harness-retry-a-jittered-wait-is-checked-as-it-is-spent ()
  "The wait a bound admits is the wait that is taken, jitter included.
The reported bug: a retry computed a randomised delay for its time-fit
check and computed it again for the wait it scheduled, so a wait could
be admitted as one value and spent as a longer one.  Here the two draws
are 0 and 999 -- 0.9 s then 1.08 s at a delay of 0.9 and jitter of 0.2
-- under a one-second bound with nothing elapsed yet: the plan must
validate 0.9 s and mean 0.9 s, and the same plan's `:delay' is what a
caller waits."
  (let* ((harness-retry-delay 0.9)
         (harness-retry-jitter 0.2)
         (harness-retry-max-delay 30.0)
         (harness-retry-max-seconds 1)
         (draws (harness-retry-test--draws '(0 999)))
         (plan nil))
    (cl-letf (((symbol-function 'random) draws))
      (setq plan (harness-retry-wait-plan 1 '(:error "reset") 0)))
    (should (equal 0.9 (plist-get plan :delay)))
    ;; 0.9 s of wait starts the next attempt at 0.9 s, inside the second.
    (should (plist-get plan :fit))
    ;; And only one draw was made: the value above is the one checked.
    (should (= 1 harness-retry-test-draws))))

(ert-deftest harness-retry-a-jittered-wait-past-the-bound-does-not-fit ()
  "A wait whose random spread puts it past the bound does not fit.
The same delay and jitter, but the draw is the larger one: 1.08 s at
nothing elapsed is not inside a one-second bound, so the plan says so
and the value it refused is the value it reports -- a caller stops
rather than sleeping it."
  (let* ((harness-retry-delay 0.9)
         (harness-retry-jitter 0.2)
         (harness-retry-max-delay 30.0)
         (harness-retry-max-seconds 1)
         (plan nil))
    (cl-letf (((symbol-function 'random) (harness-retry-test--draws '(999))))
      (setq plan (harness-retry-wait-plan 1 '(:error "reset") 0)))
    (should (< 1 (plist-get plan :delay)))
    (should-not (plist-get plan :fit))))

(ert-deftest harness-retry-a-wait-past-the-bound-stops-without-waiting ()
  "A wait that cannot fit inside the bound ends the request, not the clock.
The decision carries no `:delay', so the filter hands it on at once:
nothing sleeps the wait it refused."
  (let* ((harness-retry-policy-functions
          (list (lambda (session)
                  (when (equal (plist-get session :id) "s-counted")
                    (list :owner "Test" :count-sends t)))))
         (harness-retry-max-seconds 1)
         (harness-retry-max-attempts 5)
         (harness-retry-delay 5.0)
         (harness-retry-jitter 0)
         (session (list :id "s-counted" :model "p:m"))
         (request (harness-retry-test--sent
                   (list :session session) (make-harness-retry--request)))
         (failure (harness-retry-test--failed request "reset" 'transport))
         (started (float-time))
         (decision (harness-retry-attempt-plan
                    session failure 'transport
                    (harness-retry-request-attempts session request failure)
                    (harness-retry-request-elapsed session request failure)
                    request)))
    (should-not (plist-get decision :delay))
    (should (plist-get decision :final))
    (should (string-match-p "would start the next attempt after" (plist-get decision :reason)))
    ;; Nothing waited.
    (should (< (- (float-time) started) 1))))

(ert-deftest harness-retry-the-bound-is-one-request-and-its-retries ()
  "Two tries are one request and the retry after it, not two requests.
With `harness-retry-max-attempts' 1 a failure is tried once more and no
more, whatever `harness-agent--max-error-retries' would allow."
  (harness-retry-test-with
    (let ((harness-retry-max-attempts 1))
      (harness-retry-test-define-provider
       (lambda (_step)
         '((:type done :stop-reason error
                :error "the connection was reset by the peer" :error-kind transport))))
      (let ((id (harness-retry-test-session)))
        (should (eq 'error (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
        (should (= 2 (length harness-retry-test-requests)))
        (should (cl-some (lambda (h) (string-match-p "giving up after 1 try" h))
                         (harness-retry-test-hints id)))))))

;;;; A kind a provider decoded from its own fields

(ert-deftest harness-retry-a-permanent-rejection-ends-the-turn-at-once ()
  "A failure a provider decoded as permanent is not tried again.
The provider has said an identical request cannot pass it, so repeating
it would only spend again.  The stop is `:final', so a handler after
this one -- whatever its priority -- cannot turn it into a retry."
  (harness-retry-test-with
    (harness-retry-test-define-provider
     (lambda (_step)
       '((:type done :stop-reason error :error-kind permanent
              :error "HTTP 400: upstream rejected the request (error_type=invalid_request)"))))
    (harness-add-filter 'agent/step-error
                        (lambda (_v next &rest _) (funcall next (list :retry t))) 90)
    (let ((id (harness-retry-test-session)))
      (should (eq 'error (plist-get (harness-await (harness-call 'agent/prompt id "go")) :stop-reason)))
      (should (= 1 (length harness-retry-test-requests)))
      (should (cl-some (lambda (h) (string-match-p "identical retry cannot pass it" h))
                       (harness-retry-test-hints id))))))

(ert-deftest harness-retry-reads-a-kind-a-provider-named ()
  "A provider's own kind is used as it is, and only a retry's is retried."
  (should (eq 'transport (harness-retry-failure-kind '(:error-kind transport :error "x"))))
  (should (eq 'rate-limit (harness-retry-failure-kind '(:error-kind rate-limit :error "x"))))
  (should (eq 'permanent (harness-retry-failure-kind '(:error-kind permanent :error "x"))))
  (should (eq 'quota (harness-retry-failure-kind '(:error-kind quota :error "x"))))
  (should-not (harness-retry-kind '(:error-kind permanent :error "x")))
  (should-not (harness-retry-kind '(:error-kind quota :error "x")))
  (should (eq 'transport (harness-retry-kind '(:error-kind transport :error "x")))))

;;;; What a provider's requests need

(defun harness-retry-test--counted-session (&optional id)
  "Make a session whose provider says its sends are counted, and return it."
  (list :id (or id "s-counted") :model "scripted-retry:m"))

(ert-deftest harness-retry-a-counted-provider-gets-no-transport-replay ()
  "A session whose sends a provider counts is replayed by nothing below it.
The shared layer says 0 for it, so the transport's own count is not a
second budget; an ordinary session gets no answer here and the transport
keeps its own."
  (let ((harness-retry-policy-functions
         (list (lambda (session)
                 (when (equal (plist-get session :id) "s-counted")
                   (list :owner "Test" :count-sends t))))))
    (should (= 0 (harness-retry-transport-retries
                  (list :session (harness-retry-test--counted-session)))))
    (should-not (harness-retry-transport-retries
                 (list :session (list :id "s-ordinary" :model "x:y"))))
    (should (harness-retry-counted-p (harness-retry-test--counted-session)))
    (should-not (harness-retry-counted-p (list :id "s-ordinary")))
    (should (equal "Test" (harness-retry-owner (harness-retry-test--counted-session))))))

(ert-deftest harness-retry-counts-a-counted-providers-sends ()
  "A counted provider's sends are bounded here, where they are counted.
The first request may make the first send and `harness-retry-max-attempts'
more; a send past that is refused with the bound, and the reason says
whose request it was.  The count is the request's: a second request of
the same session starts with none of the first one's."
  (let ((harness-retry-policy-functions
         (list (lambda (session)
                 (when (equal (plist-get session :id) "s-counted")
                   (list :owner "Test" :count-sends t))))))
    (let* ((harness-retry-max-attempts 1)
           (session (harness-retry-test--counted-session))
           (first (list :session session)))
      (should-not (plist-get (harness-retry-send first) :refusal))
      (setq first (plist-get (harness-retry-send first) :request))
      ;; A retry of it, as the decision marks one, is the second send.
      (setf (harness-retry--request-retrying (harness-retry-state-of first)) t)
      (let ((second (harness-retry-send first)))
        (should-not (plist-get second :refusal))
        (setq first (plist-get second :request)))
      ;; And a third is past what one request may make.
      (setf (harness-retry--request-retrying (harness-retry-state-of first)) t)
      (let ((refusal (plist-get (harness-retry-send first) :refusal)))
        (should (eq 'retry-budget (car refusal)))
        (should (string-match-p "Test: one request may make 2 sends" (cdr refusal)))
        (should (= 2 (harness-retry--request-count (harness-retry-state-of first)))))
      ;; A different request of the same session is charged none of it.
      (let ((other (harness-retry-send (list :session session))))
        (should-not (plist-get other :refusal))
        (should (= 1 (harness-retry--request-count
                      (harness-retry-state-of (plist-get other :request)))))))))

(ert-deftest harness-retry-counts-the-clock-from-the-first-send ()
  "`harness-retry-max-seconds' starts at the first send, not at the failure.
A counted request that took longer than the whole bound leaves no room
for a retry, so the next send is refused."
  (let ((harness-retry-policy-functions
         (list (lambda (session)
                 (when (equal (plist-get session :id) "s-counted")
                   (list :owner "Test" :count-sends t))))))
    (let* ((harness-retry-max-attempts 5)
           (harness-retry-max-seconds 1)
           (session (harness-retry-test--counted-session))
           (request (plist-get (harness-retry-send (list :session session)) :request)))
      (setf (harness-retry--request-since (harness-retry-state-of request))
            (- (float-time) 1.2))
      (setf (harness-retry--request-retrying (harness-retry-state-of request)) t)
      (let ((refusal (plist-get (harness-retry-send request) :refusal)))
        (should (eq 'retry-budget (car refusal)))
        (should (string-match-p "may take 1 s" (cdr refusal)))))))

(ert-deftest harness-retry-two-requests-of-one-session-do-not-share-a-budget ()
  "A step and a recap of the same session are two requests, budgeted apart.
Each carries its own count and clock, so a small call in flight beside a
step neither spends the step's attempts nor restarts them -- the bug a
session-wide budget had, where one reset the other."
  (let ((harness-retry-policy-functions
         (list (lambda (session)
                 (when (equal (plist-get session :id) "s-counted")
                   (list :owner "Test" :count-sends t))))))
    (let* ((harness-retry-max-attempts 1)
           (session (harness-retry-test--counted-session))
           (step (plist-get (harness-retry-send (list :session session)) :request))
           (recap (plist-get (harness-retry-send (list :session session)) :request)))
      ;; The step's retry is its own second send, not the recap's.
      (setf (harness-retry--request-retrying (harness-retry-state-of step)) t)
      (setq step (plist-get (harness-retry-send step) :request))
      (should (= 2 (harness-retry--request-count (harness-retry-state-of step))))
      ;; The recap has sent nothing since, and still may send its retry.
      (should (= 1 (harness-retry--request-count (harness-retry-state-of recap))))
      (setf (harness-retry--request-retrying (harness-retry-state-of recap)) t)
      (let ((again (harness-retry-send recap)))
        (should-not (plist-get again :refusal))
        (should (= 2 (harness-retry--request-count
                      (harness-retry-state-of (plist-get again :request))))))
      ;; And the step is still past its bound.
      (setf (harness-retry--request-retrying (harness-retry-state-of step)) t)
      (should (plist-get (harness-retry-send step) :refusal)))))

(ert-deftest harness-retry-carries-the-authority-of-a-request-to-its-done ()
  "What authorised a send comes back in its `done', for a layer above to read.
A provider records it with `harness-retry-authorise', the transport hands
the request's state back in the `done' event, and every other event is
left exactly as the provider made it -- an ordinary request's events are
changed by nothing here."
  (let* ((harness-retry-policy-functions
          (list (lambda (session)
                  (when (equal (plist-get session :id) "s-counted")
                    (list :owner "Test" :count-sends t)))))
         (session (list :id "s-counted" :model "p:m"))
         (request (plist-get (harness-retry-send (list :session session)) :request))
         (request (harness-retry-authorise request (list :policy '(:model "m") :route '(:slug "a/b"))))
         (sent (harness-retry--carry (list :type 'done :stop-reason 'error) request)))
    (should (equal '(:slug "a/b") (plist-get (harness-retry-authority-of sent) :route)))
    (should (equal '(:slug "a/b") (plist-get (harness-retry-authority-of request) :route)))
    ;; A request carrying no state is unchanged, event and all.
    (should-not (plist-member (harness-retry--carry (list :type 'done :stop-reason 'error)
                                                    (list :model "m"))
                              harness-retry--request-key))
    ;; And nothing but the last event is touched.
    (should-not (plist-member (harness-retry--carry (list :type 'text :delta "hi") request)
                              harness-retry--request-key))))

(ert-deftest harness-retry-an-ordinary-provider-is-not-counted-here ()
  "A session no policy answers for is not counted by this module at all.
Its request is returned as it was, so nothing about an ordinary provider
-- how many times it is tried, or how long -- changed."
  (let ((harness-retry-policy-functions nil))
    (let ((request (list :session (list :id "s-ordinary" :model "x:y"))))
      (should (equal request (plist-get (harness-retry-send request) :request)))
      (should-not (plist-get (harness-retry-send request) :refusal))
      (should-not (harness-retry-state-of (plist-get (harness-retry-send request) :request)))
      (should-not (harness-retry-request-elapsed
                   (list :id "s-ordinary") request request)))))

(ert-deftest harness-retry-a-retried-step-keeps-one-request-budget ()
  "The step that follows a retry repeats the request that failed, budget and all.
A provider that counts its sends sees the second attempt carry the
first one's state: its count is two, its clock is the one that started
at the first send, and what authorised the first attempt came back in
the `done' event.  The turn's request is a request, not a session
budget: nothing about it is kept by session."
  (harness-retry-test-with
    (let ((harness-retry-max-attempts 1)
          (harness-retry-delay 0.01)
          (seen nil)
          (harness-retry-policy-functions
           nil))
      ;; A counted provider, which is what a governed one answers.
      (setq harness-retry-policy-functions
            (list (lambda (session)
                    (when (equal (plist-get session :model) "scripted-retry:m")
                      (list :owner "Test" :count-sends t)))))
      (harness-retry-test-define-provider
       (lambda (step)
         ;; A counted provider authorises and counts each send where it
         ;; happens, which is what the transport's dispatch does.
         (let* ((given (nth (1- step) (reverse harness-retry-test-requests)))
                (request (plist-get (harness-retry-send given) :request))
                (state (harness-retry-state-of request)))
           (push (list :step step
                       :count (and state (harness-retry--request-count state))
                       :since (and state (harness-retry--request-since state))
                       :authority (and state (harness-retry-authority-of request)))
                 seen)
           (if (= step 1)
               (list (harness-retry--carry
                      (list :type 'done :stop-reason 'error
                            :error "the connection was reset by the peer"
                            :error-kind 'transport)
                      request))
             '((:type text :delta "the answer") (:type done :stop-reason end-turn))))))
      (let ((id (harness-retry-test-session)))
        (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "go"))
                                         :stop-reason)))
        (should (= 2 (length harness-retry-test-requests)))
        ;; The first attempt was counted at its send; the retry continued it.
        (should (= 1 (plist-get (nth 0 (reverse seen)) :count)))
        (should (= 2 (plist-get (nth 1 (reverse seen)) :count)))
        (should (numberp (plist-get (nth 1 (reverse seen)) :since)))
        ;; Nothing about a request is kept by session.
        (should-not (harness-retry-state-of (harness-call 'session/get id)))))))

(ert-deftest harness-retry-admission-failures-share-a-request-budget-not-a-session ()
  (let* ((harness-retry-policy-functions (list (lambda (_) '(:owner "fixture" :count-sends t))))
         (request '(:session (:id "same" :model "fixture:m")))
         (first (harness-retry-prepare request))
         (second (harness-retry-prepare request))
         (state (harness-retry-state-of first))
         failure)
    (funcall (harness-retry-observe first (lambda (event) (setq failure event)))
             '(:type done :stop-reason error))
    (should-not (eq state (harness-retry-state-of second)))
    (should (eq state (harness-retry-state-of failure)))
    (should (= 0 (harness-retry--request-count state)))
    (should (= 1 (harness-retry-request-attempts (plist-get request :session) first failure)))
    (should (= 0 (harness-retry-request-attempts (plist-get request :session) second nil)))))

(ert-deftest harness-retry-a-queued-request-cannot-start-its-clock-over-at-first-send ()
  (let* ((harness-retry-policy-functions (list (lambda (_) '(:owner "fixture" :count-sends t))))
         (harness-retry-max-seconds 3) (now 100.0)
         (request (harness-retry-prepare '(:session (:id "s" :model "fixture:m")))))
    (cl-letf (((symbol-function 'float-time) (lambda (&rest _) now)))
      (should-not (harness-retry-elapsed (harness-retry-state-of request)))
      (harness-retry-note-wait request)
      (setq now 104.0)
      (let* ((send (harness-retry-send request)) (state (harness-retry-state-of (plist-get send :request))))
        (should (eq 'retry-budget (car (plist-get send :refusal))))
        (should (= 0 (harness-retry--request-count state)))
        (should (= 4 (harness-retry-elapsed state)))))))

(ert-deftest harness-retry-terminal-accounting-cannot-suppress-delivery ()
  (let* ((harness-retry-policy-functions (list (lambda (_) '(:count-sends t))))
         (request (harness-retry-prepare '(:session (:id "s")))) events
         (observe (harness-retry-observe request (lambda (event) (push event events)))))
    (cl-letf (((symbol-function 'harness-retry-attempts) (lambda (_) (error "accounting failed"))))
      (funcall observe '(:type done :stop-reason error :error "original failure")))
    (should (= 1 (length events)))
    (should (equal "original failure" (plist-get (car events) :error)))))

(provide 'harness-retry-test)
;;; harness-retry-test.el ends here
