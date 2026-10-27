;;; harness-small-test.el --- One-off model calls, tried again when they fail  -*- lexical-binding: t; -*-

;;; Commentary:

;; `harness-small-ask' sends one of the harness's own one-off calls and
;; tries it again when a provider fails transiently -- the 429 under load
;; that left a session unnamed and a prompt no judge could decide.  A stub
;; provider, `small-stub', answers each test's script: what it was sent,
;; how many times, and the events it plays back.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-small)

(defvar harness-small-test--requests nil
  "The requests the stub got, newest first.")

(defvar harness-small-test--replies nil
  "What the stub answers, one list of events per request, in order.
A request past the last gets the last list again.")

(defvar harness-small-test--cancelled 0
  "How many requests of the stub were cancelled.")

(defvar harness-small-test--events nil
  "Every event the caller was handed, newest first.")

(defun harness-small-test--says (&rest replies)
  "Have the stub answer REPLIES, one per request, in order."
  (setq harness-small-test--requests nil
        harness-small-test--replies replies
        harness-small-test--cancelled 0
        harness-small-test--events nil))

(defun harness-small-test--define-provider ()
  "Define the stub provider `small-stub', answered from the test's script."
  (harness-define-provider 'small-stub
    :label "Small stub"
    :complete (lambda (req)
                (push req harness-small-test--requests)
                (let ((events (or (pop harness-small-test--replies)
                                  (car (last harness-small-test--replies))))
                      (on-event (plist-get req :on-event))
                      (cancelled nil))
                  (run-at-time 0.01 nil
                               (lambda ()
                                 (unless cancelled
                                   (dolist (ev events) (funcall on-event ev)))))
                  (list :cancel (lambda () (setq cancelled t)
                                  (cl-incf harness-small-test--cancelled)))))))

(defmacro harness-small-test-with (&rest body)
  "Run BODY with the stub provider, the retry module and fast retries."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider retry small))
       (harness-test-load-module m))
     (harness-small-test--define-provider)
     (harness-small-test--says)
     (clrhash harness-retry--attempts)
     (let ((harness-retry-delay 0.01)
           (harness-retry-jitter 0))
       (unwind-protect (progn ,@body)
         (remhash 'small-stub harness-providers)
         (harness-provider--forget 'small-stub)))))

(defun harness-small-test--ask (&rest opts)
  "Ask the stub a one-off call with OPTS; return a promise of its text.
The caller's own `:on-event' gathers the reply's text, with a `restart'
event clearing it, so a test can see the retry dropping a half answer.
A `:retries' in OPTS joins the request's own keys, since it is the
caller's, and goes to `harness-small-ask' as an option instead."
  (let* ((text "")
         (promise (harness-make-promise))
         (opts (plist-put (copy-sequence opts) :on-event
                          (lambda (ev)
                            (push ev harness-small-test--events)
                            (pcase (plist-get ev :type)
                              ('restart (setq text ""))
                              ('text (setq text (concat text (or (plist-get ev :delta) ""))))
                              ('done (harness-resolve promise (list :text text :event ev))))))))
    (harness-small-ask
     (list :model "small-stub:m" :ephemeral t :tools nil :no-thinking t :max-tokens 40)
     opts)
    promise))

(defun harness-small-test--text (answer)
  "Return the text ANSWER gathered, or nil while it has not settled."
  (plist-get (harness-test-await answer) :text))

(defun harness-small-test--reply (text &optional stop-reason extra)
  "Return the events of a reply of TEXT ending at STOP-REASON, with EXTRA."
  (append (when text (list (list :type 'text :delta text)))
          (list (append (list :type 'done :stop-reason (or stop-reason 'end-turn)) extra))))

;;;; A transient failure is tried again

(ert-deftest harness-small-retries-a-rate-limit-and-answers ()
  "A 429 that names itself a rate limit is waited out and asked again.
The half a failed try wrote is dropped first: the caller is sent a
`restart' event, so it never reads a partial answer as the whole one."
  (harness-small-test-with
    (harness-small-test--says
     (harness-small-test--reply "I am a litt" 'error '(:error "HTTP 429: rate limit reached" :error-kind rate-limit))
     (harness-small-test--reply "Refactor the parser"))
    (should (equal "Refactor the parser" (harness-small-test--text (harness-small-test--ask))))
    ;; Two requests: the first was tried again.
    (should (= 2 (length harness-small-test--requests)))
    ;; The caller was told to forget what the failed try wrote.
    (should (cl-some (lambda (ev) (eq (plist-get ev :type) 'restart)) harness-small-test--events))))

(ert-deftest harness-small-retries-a-transport-failure-from-its-text ()
  "A provider that names no kind still gets a retry when the words say so."
  (harness-small-test-with
    (harness-small-test--says
     (harness-small-test--reply nil 'error
                                '(:error "curl exited 56 (exited abnormally with code 56): Recv failure: Connection reset by peer"))
     (harness-small-test--reply "a title"))
    (should (equal "a title" (harness-small-test--text (harness-small-test--ask))))
    (should (= 2 (length harness-small-test--requests)))))

(ert-deftest harness-small-retries-a-provider-process-that-died ()
  "A CLI provider's process killed mid-call is started again by the next try."
  (harness-small-test-with
    (harness-small-test--says
     (harness-small-test--reply nil 'error '(:error "claude exited with status 137: Killed"))
     (harness-small-test--reply "back"))
    (should (equal "back" (harness-small-test--text (harness-small-test--ask))))
    (should (= 2 (length harness-small-test--requests)))))

(ert-deftest harness-small-honours-a-retry-after ()
  "A rate limit that asked for a wait is waited for, its delay capped.
Never sooner than the backoff: the server's wait is a minimum."
  (should (= 3 (let ((harness-retry-delay 0.5) (harness-retry-jitter 0))
                 (harness-retry-backoff 1 '(:retry-after 3)))))
  (should (= 30.0 (let ((harness-retry-delay 1) (harness-retry-jitter 0)
                        (harness-retry-max-delay 30.0))
                    (harness-retry-backoff 1 '(:retry-after 600)))))
  (should (= 10.0 (let ((harness-retry-delay 10) (harness-retry-jitter 0))
                    (harness-retry-backoff 1 '(:retry-after 3)))))
  (should (= 4.0 (let ((harness-retry-delay 1) (harness-retry-jitter 0))
                   (harness-retry-backoff 3 '(:retry-after nil))))))

;;;; Bounded, and only what a retry gets past

(ert-deftest harness-small-gives-up-after-its-cap ()
  "A provider that stays down is tried at most `harness-retry-max-attempts'.
The last `done' is the one the caller reads, and no more is sent."
  (harness-small-test-with
    (let ((harness-retry-max-attempts 2))
      (harness-small-test--says
       (harness-small-test--reply "a" 'error '(:error "rate limited" :error-kind rate-limit))
       (harness-small-test--reply "b" 'error '(:error "rate limited" :error-kind rate-limit))
       (harness-small-test--reply "c" 'error '(:error "rate limited" :error-kind rate-limit)))
      (let ((answer (harness-test-await (harness-small-test--ask))))
        (should (eq 'error (plist-get (plist-get answer :event) :stop-reason)))
        ;; The first attempt and two retries, and no more.
        (should (= 3 (length harness-small-test--requests)))
        (should (equal "c" (plist-get answer :text)))))))

(ert-deftest harness-small-does-not-retry-a-failure-no-retry-gets-past ()
  "A refusal is the call's end: quota and login are another layer's business."
  (harness-small-test-with
    (harness-small-test--says
     (harness-small-test--reply nil 'error '(:error "invalid api key" :error-kind auth)))
    (let ((answer (harness-test-await (harness-small-test--ask))))
      (should (= 1 (length harness-small-test--requests)))
      (should (eq 'error (plist-get (plist-get answer :event) :stop-reason)))
      (should (equal "invalid api key" (plist-get (plist-get answer :event) :error))))))

(ert-deftest harness-small-does-not-retry-a-quota-failure ()
  "A provider out of quota is the fallback module's, never tried here."
  (harness-small-test-with
    (harness-small-test--says
     (harness-small-test--reply nil 'error '(:error "You have run out of credits" :error-kind billing)))
    (harness-test-await (harness-small-test--ask))
    (should (= 1 (length harness-small-test--requests)))))

(ert-deftest harness-small-leaves-a-success-alone ()
  "A call that goes well is sent once and settles at once."
  (harness-small-test-with
    (harness-small-test--says (harness-small-test--reply "the whole answer"))
    (should (equal "the whole answer" (harness-small-test--text (harness-small-test--ask))))
    (should (= 1 (length harness-small-test--requests)))))

;;;; What a caller controls

(ert-deftest harness-small-keeps-the-callers-request-keys ()
  "Every key of the request reaches the provider, `:on-event' the only one added.
The keys a call the harness makes on its own is recorded by (`:job' and
the rest, see `provider/complete') are the bus's, and are taken out
before a provider sees the request."
  (harness-small-test-with
    (harness-small-test--says (harness-small-test--reply "ok"))
    (let ((handle (harness-small-ask
                   (list :model "small-stub:m" :ephemeral t :tools nil
                         :system "Be brief." :messages (list (list :role 'user :content "hi"))
                         :max-tokens 40 :job "A job" :job-parent "s1")
                   (list :on-event #'ignore))))
      (should (functionp (plist-get handle :cancel)))
      (harness-test-wait (lambda () harness-small-test--requests) 5 "the request")
      (let ((req (car harness-small-test--requests)))
        (should (eq t (plist-get req :ephemeral)))
        (should-not (plist-get req :tools))
        (should (equal "Be brief." (plist-get req :system)))
        (should (equal 40 (plist-get req :max-tokens)))
        (should (functionp (plist-get req :on-event)))
        (should-not (plist-member req :job))
        (should-not (plist-member req :job-parent))))))

(ert-deftest harness-small-can-be-told-not-to-try-again ()
  "A caller that does its own trying asks for none here (`:retries' nil).
This is the cache warmer, which tries a refresh again on its own clock."
  (harness-small-test-with
    (harness-small-test--says
     (harness-small-test--reply nil 'error '(:error "rate limited" :error-kind rate-limit)))
    (let ((text (harness-small-test--text (harness-small-test--ask :retries 0))))
      (should (equal "" text))
      (should (= 1 (length harness-small-test--requests))))))

(ert-deftest harness-small-a-cancelled-call-tries-nothing-more ()
  "The handle's `:cancel' stops the call and the wait for a retry it left.
A caller that gives up on a slow call must not have a retry wake up
behind it and ask the provider again."
  (harness-small-test-with
    (let ((harness-retry-delay 0.3))
      (harness-small-test--says
       (harness-small-test--reply nil 'error '(:error "rate limited" :error-kind rate-limit)))
      (let ((handle (harness-small-ask
                     (list :model "small-stub:m" :ephemeral t)
                     (list :on-event #'ignore))))
        (harness-test-wait (lambda () harness-small-test--requests) 5 "the call")
        (funcall (plist-get handle :cancel))
        ;; Well past the retry the failure asked for.
        (accept-process-output nil 0.6)
        (should (= 1 (length harness-small-test--requests)))
        (should (= 1 harness-small-test--cancelled))))))

;;;; The field's failure, end to end: a real provider answering 429

(ert-deftest harness-small-recovers-from-a-real-429-with-a-retry-after ()
  "A real OpenAI-compatible provider answering 429 first is asked again.
This is the bug as it was reported: DeepSeek under load answers 429 with
a JSON body and a Retry-After, the answer begins (so the HTTP layer,
which only retries what never began, leaves it alone), and the one-off
call gave up.  A small call now waits the Retry-After out and is sent
again, and the answer comes from the second request."
  (skip-unless (executable-find "curl"))
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (let* ((attempts 0)
           (answer (concat "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"A title\"}}]}\n\n"
                           "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
                           "data: [DONE]\n\n"))
           (server (harness-test-http-serve
                    `(("/chat/completions"
                       . ,(lambda (attempt)
                            (setq attempts attempt)
                            (if (= attempt 1)
                                (list 429 '(("Content-Type" . "application/json")
                                            ("Retry-After" . "0"))
                                      "{\"error\":{\"message\":\"Rate limit reached\",\"type\":\"rate_limit_error\"}}")
                              (list 200 '(("Content-Type" . "text/event-stream")) answer)))))))
           (harness-retry-delay 0.01)
           (harness-retry-jitter 0))
      (unwind-protect
          (progn
            ;; The provider contract itself, whose `provider/complete' the
            ;; fresh bus has forgotten: a module is only initialised once
            ;; its requirements are, and the endpoint is registered by the
            ;; OpenAI provider's own start.
            (harness-test-load-module 'provider)
            (harness-test-load-module 'provider-openai)
            (harness-openai-register-endpoint
             (list :id 'smalllocal :label "Local test server"
                   :base-url (harness-test-http-url server "") :api-key "sk-test"))
            (let ((text "") (done nil))
              (harness-small-ask
               (list :model "smalllocal:local-model" :ephemeral t :no-thinking t
                     :system "Say a title." :messages (list (list :role 'user :content "name it"))
                     :max-tokens 20)
               (list :label "small test"
                     :on-event (lambda (ev)
                                 (pcase (plist-get ev :type)
                                   ('restart (setq text ""))
                                   ('text (setq text (concat text (or (plist-get ev :delta) ""))))
                                   ('done (setq done ev))))))
              (harness-test-wait (lambda () done) 10 "the answer")
              (should (equal "A title" text))
              (should (eq 'end-turn (plist-get done :stop-reason)))
              ;; Two requests: the 429 was waited out and asked again.
              (should (= 2 attempts))))
        (delete-process server)
        (remhash 'smalllocal harness-providers)
        (harness-provider--forget 'smalllocal)))))

(provide 'harness-small-test)
;;; harness-small-test.el ends here
