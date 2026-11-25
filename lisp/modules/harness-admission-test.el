;;; harness-admission-test.el --- One provider account's work, let in a piece at a time  -*- lexical-binding: t; -*-

;;; Commentary:

;; The pools are the thing under test, so most of these call
;; `harness-admission-admit' directly with a stub that records what it was
;; sent and when.  The rest go through `provider/complete' with a stub
;; provider, which is how a turn's step, a one-off call and a cache warmer
;; actually reach a pool.
;;
;; The clocks are the real ones, with waits of a few hundredths of a
;; second, because what a pool does is wait: a fake clock would test the
;; timer calls rather than the queue.  `harness-test-wait' spins the event
;; loop the way the harness process does.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-admission)

(defvar harness-admission-test--sent nil
  "What the stub was sent, oldest first, as (:request REQUEST :at FLOAT).")

(defvar harness-admission-test--replies nil
  "What the stub answers, one list of events per request, in order.
A request past the last gets the last list again.")

(defvar harness-admission-test--cancelled 0
  "How many requests of the stub were cancelled before they answered.")

(defun harness-admission-test--reply (stop-reason &optional extra)
  "Return the events of a reply ending at STOP-REASON, with EXTRA."
  (list (append (list :type 'done :stop-reason stop-reason) extra)))

(defun harness-admission-test--says (&rest replies)
  "Have the stub answer REPLIES, one per request, in order."
  (setq harness-admission-test--sent nil
        harness-admission-test--replies replies
        harness-admission-test--cancelled 0))

(defun harness-admission-test--stub (request)
  "Answer REQUEST from the script; return a handle that can stop it."
  (let ((events (or (pop harness-admission-test--replies)
                    (car (last harness-admission-test--replies))))
        (on-event (or (plist-get request :on-event) #'ignore))
        (cancelled nil))
    (push (list :request request :at (float-time)) harness-admission-test--sent)
    (run-at-time 0.01 nil
                 (lambda ()
                   (unless cancelled
                     (dolist (event events) (funcall on-event event)))))
    (list :cancel (lambda () (setq cancelled t)
                    (cl-incf harness-admission-test--cancelled)))))

(defun harness-admission-test--request (&optional overrides)
  "Return a request for the stub, with OVERRIDES applied."
  (append overrides
          (list :model "admission-stub:m" :session (list :id "s1")
                :messages (list (list :role 'user :content "hi")))))

(defmacro harness-admission-test-with (&rest body)
  "Run BODY with the admission module started, no pools, and short waits."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider retry admission))
       (harness-test-load-module m))
     (harness-admission-reset)
     (harness-admission-test--says)
     (let ((harness-admission t)
           (harness-admission-delay 0.02)
           (harness-admission-jitter 0)
           (harness-admission-max-delay 0.2)
           (harness-admission-max-wait 5.0)
           (harness-admission-release-spacing 0.02)
           (harness-admission-max-concurrent nil)
           (harness-admission-pool-functions nil)
           (harness-retry-delay 0.01)
           (harness-retry-jitter 0))
       (unwind-protect (progn ,@body)
         (harness-admission-reset)))))

(defun harness-admission-test--pool (&optional key)
  "Return the state of the pool KEY names, `admission-stub' by default."
  (setq key (or key "admission-stub"))
  (cl-find key (harness-call 'admission/state)
           :key (lambda (p) (plist-get p :key))
           :test (lambda (a b) (string-prefix-p a b))))

(defun harness-admission-test--at (n)
  "Return the moment the Nth request of the stub was sent, from 1."
  (plist-get (nth (1- n) (reverse harness-admission-test--sent)) :at))

(defun harness-admission-test--order ()
  "Return the session ids of the stub's requests, oldest first."
  (mapcar (lambda (sent)
            (plist-get (plist-get (plist-get sent :request) :session) :id))
          (reverse harness-admission-test--sent)))

(defun harness-admission-test--sent-count ()
  "Return how many requests the stub was sent."
  (length harness-admission-test--sent))

(defun harness-admission-test--admit (&optional overrides)
  "Admit a request for the stub with OVERRIDES; return the handle."
  (harness-admission-admit (harness-admission-test--request overrides)
                           #'harness-admission-test--stub))

;;;; An ordinary provider is not made to wait

(ert-deftest harness-admission-an-open-pool-sends-at-once ()
  "A pool that is not resting lets work in at once, with no queue at all.
This is what every provider that is not rate limiting sees, which is the
whole of the harness's ordinary traffic: the request is started in the
call that made it, and the pool has no entry left behind."
  (harness-admission-test-with
    (harness-admission-test--says (harness-admission-test--reply 'end-turn))
    (let ((handle (harness-admission-test--admit)))
      ;; Started in the admitting call, not later.
      (should (= 1 (harness-admission-test--sent-count)))
      (should (functionp (plist-get handle :cancel)))
      (should-not (plist-get (plist-get handle :admission) :waiting))
      (harness-test-wait (lambda () (zerop (plist-get (harness-admission-test--pool) :busy)))
                         5 "the request to finish")
      (should (= 0 (plist-get (harness-admission-test--pool) :queued))))))

(ert-deftest harness-admission-off-sends-everything-at-once ()
  "With `harness-admission' off a rate limit stops nothing: the harness
sends exactly what it sent before this module existed."
  (harness-admission-test-with
    (let ((harness-admission nil))
      (harness-admission-test--says
       (harness-admission-test--reply 'error '(:error "HTTP 429: slow down" :error-kind rate-limit))
       (harness-admission-test--reply 'end-turn))
      (harness-admission-test--admit)
      ;; Both are sent in the admitting calls themselves: nothing is
      ;; queued, so the rate limit the first one met holds nobody.
      (harness-admission-test--admit)
      (should (= 2 (harness-admission-test--sent-count)))
      (should-not (harness-call 'admission/state)))))

;;;; A rate limit rests the pool every request of the account shares

(ert-deftest harness-admission-a-rate-limit-holds-every-request-of-the-pool ()
  "A 429 on one request holds the next one of the same account, and the
pool's own state says how long it rests and who waits."
  (harness-admission-test-with
    (harness-admission-test--says
     (harness-admission-test--reply 'error '(:error "HTTP 429: slow down" :error-kind rate-limit
                                             :retry-after 0.3))
     (harness-admission-test--reply 'end-turn)
     (harness-admission-test--reply 'end-turn))
    (harness-admission-test--admit)
    (harness-test-wait (lambda () (harness-admission-test--pool))
                       5 "the pool")
    (harness-test-wait (lambda () (< 0 (plist-get (harness-admission-test--pool) :until)))
                       5 "the pool to rest")
    (let* ((pool (harness-admission-test--pool))
           (until (plist-get pool :until)))
      (should (> until (float-time)))
      ;; The next request of the same provider waits for it.
      (harness-admission-test--admit)
      (should (= 1 (harness-admission-test--sent-count)))
      (should (= 1 (plist-get (harness-admission-test--pool) :queued)))
      (should (equal "s1" (plist-get (car (plist-get (harness-admission-test--pool) :waiting))
                                       :session)))
      ;; It goes once the rest is over, without anyone asking again.
      (harness-test-wait (lambda () (= 2 (harness-admission-test--sent-count)))
                         5 "the second request after the rest"))))

(ert-deftest harness-admission-a-retry-after-in-seconds-is-waited-as-asked ()
  "A wait the provider names is never shortened, however long it is.
`harness-admission-max-delay' caps the harness's own backoff and nothing
else: a provider that says an hour gets an hour, and the pool says so."
  (harness-admission-test-with
    (let ((harness-admission-max-delay 0.2))
      (harness-admission-test--says
       (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit
                                               :retry-after 3600)))
      (harness-admission-test--admit)
      (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                         5 "the pool to rest")
      (should (> (- (plist-get (harness-admission-test--pool) :until) (float-time)) 3500)))))

(ert-deftest harness-admission-a-retry-after-as-a-date-is-waited-as-asked ()
  "An HTTP-date is read as the wait it names, from now.
The header form is a time rather than a count, and a pool that could
not read it would rest for its own guess instead of the provider's word."
  (harness-admission-test-with
    (harness-admission-test--says
     (harness-admission-test--reply 'error
                                    (list :error "HTTP 429" :error-kind 'rate-limit
                                          :retry-after (format-time-string
                                                        "%a, %d %b %Y %H:%M:%S GMT"
                                                        (time-add nil 600) t))))
    (harness-admission-test--admit)
    (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                       5 "the pool to rest")
    (let ((wait (- (plist-get (harness-admission-test--pool) :until) (float-time))))
      ;; Ten minutes, less the moment it took to get here.
      (should (> wait 550))
      (should (<= wait 601)))))

(ert-deftest harness-admission-a-second-limit-never-shortens-the-first ()
  "A pool already resting stays rested for the longer wait.
Two requests in flight together may meet the same limit, and each says
how long to wait; the shorter answer must not open the pool early for
everybody, so the longer rest stands."
  (harness-admission-test-with
    (let ((pool (harness-admission--pool-of "admission-stub")))
      (harness-admission--rest pool (list :stop-reason 'error :error-kind 'rate-limit
                                          :retry-after 60))
      (let ((first (harness-admission--pool-until pool)))
        (harness-admission--rest pool (list :stop-reason 'error :error-kind 'rate-limit
                                            :retry-after 1))
        (should (>= (harness-admission--pool-until pool) first))
        (should (> (- (harness-admission--pool-until pool) (float-time)) 50))
        ;; A longer second answer does move the rest further out.
        (harness-admission--rest pool (list :stop-reason 'error :error-kind 'rate-limit
                                            :retry-after 120))
        (should (> (- (harness-admission--pool-until pool) (float-time)) 110))))))
;;;; One account's limit does not stop another's work

(ert-deftest harness-admission-pools-are-independent ()
  "A rate limit on one provider stops that provider's work only.
Another provider's pool is open, and its requests are sent at once."
  (harness-admission-test-with
    (harness-admission-test--says
     (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 60))
     (harness-admission-test--reply 'end-turn))
    (harness-admission-test--admit)
    (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                       5 "the stub's pool to rest")
    ;; Another provider: a pool of its own, open, and sent at once.
    (let ((other (harness-admission-admit
                  (harness-admission-test--request
                   '(:model "other-stub:m" :session (:id "s2")))
                  #'harness-admission-test--stub)))
      (should (functionp (plist-get other :cancel)))
      (should (= 2 (harness-admission-test--sent-count)))
      (should (equal "other-stub" (plist-get (plist-get other :admission) :pool)))
      (let ((pools (harness-call 'admission/state)))
        (should (= 2 (length pools)))
        (should (equal '("admission-stub" "other-stub")
                       (mapcar (lambda (p) (plist-get p :key)) pools)))))))

(ert-deftest harness-admission-a-provider-can-name-its-own-pool ()
  "`harness-admission-pool-functions' splits an account by what it serves.
A provider that serves several endpoints splits them, so one endpoint's
limit does not stop work bound for another; the account is what they
share, and a limit the account itself announced rests both."
  (harness-admission-test-with
    (let ((harness-admission-pool-functions
           (list (lambda (request)
                   (when-let* ((route (plist-get request :test-route)))
                     (list :pool (format "admission-stub/%s" route)
                           :account "admission-stub"))))))
      (harness-admission-test--says
       (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 60))
       (harness-admission-test--reply 'end-turn))
      (harness-admission-test--admit '(:test-route "fp8"))
      (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool "admission-stub/fp8") '()) :until)))
                         5 "the fp8 pool to rest")
      (should (equal "admission-stub/fp8" (plist-get (harness-admission-test--pool "admission-stub/fp8") :key)))
      (should (equal "admission-stub" (plist-get (harness-admission-test--pool "admission-stub/fp8") :account)))
      ;; The other endpoint of the same account is not held by an
      ;; endpoint's limit.
      (let ((other (harness-admission-test--admit '(:test-route "bf16"))))
        (should (equal "admission-stub/bf16" (plist-get (plist-get other :admission) :pool)))
        (should (= 2 (harness-admission-test--sent-count)))))))

(ert-deftest harness-admission-a-limit-the-account-announced-rests-every-pool ()
  "A limit the provider says is the account's holds every endpoint of it.
The failure carries `:limit-scope' `account' only when the provider could
tell that apart from one endpoint's bad minute; then the pools of the
account rest, including one first used after the fact, and another
account's work is untouched."
  (harness-admission-test-with
    (let ((harness-admission-pool-functions
           (list (lambda (request)
                   (when-let* ((route (plist-get request :test-route)))
                     (list :pool (format "%s/%s"
                                         (or (plist-get request :test-account) "admission-stub")
                                         route)
                           :account (or (plist-get request :test-account) "admission-stub")))))))
      (harness-admission-test--says
       (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit
                                               :retry-after 0.3 :limit-scope account))
       (harness-admission-test--reply 'end-turn)
       (harness-admission-test--reply 'end-turn))
      (harness-admission-test--admit '(:test-route "fp8"))
      (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool "admission-stub/fp8") '()) :until)))
                         5 "the account to rest")
      ;; Another endpoint of the same account waits, and so does one this
      ;; account had not used yet: the rest is the account's, not the
      ;; endpoint's.
      (harness-admission-test--admit '(:test-route "bf16"))
      (harness-admission-test--admit '(:test-route "int8"))
      (should (= 1 (harness-admission-test--sent-count)))
      ;; Another account is open, and its request goes at once.
      (harness-admission-test--admit '(:test-route "fp8" :test-account "other-account"))
      (should (= 2 (harness-admission-test--sent-count)))
      ;; Another account's pool is open: it is not its limit.
      (should (= 0 (plist-get (harness-admission-test--pool "other-account/fp8") :until)))
      ;; The account's pools all go once the rest ends.
      (harness-test-wait (lambda () (= 4 (harness-admission-test--sent-count)))
                         10 "the account's queues to go"))))

(ert-deftest harness-admission-a-pool-identity-never-carries-a-credential ()
  "A pool key is a published name, and a provider's own answer is used.
The method `provider/admission-identity' is asked before the hook, so a
provider that knows its accounts answers in its own module; neither the
hook nor the method is asked to put a key, a token or any other secret
into a pool key."
  (harness-admission-test-with
    (let ((asked nil)
          (harness-admission-pool-functions
           (list (lambda (request)
                   (push 'hook asked)
                   (when-let* ((account (plist-get request :test-account)))
                     (list :pool (format "%s/%s" account (plist-get request :test-route))
                           :account account))))))
      (harness-register-method
       'provider/admission-identity
       (lambda (request)
         (push 'method asked)
         (when-let* ((account (plist-get request :test-account)))
           (list :pool (format "%s/%s" account (plist-get request :test-route))
                 :account account))))
      (unwind-protect
          (let ((identity (harness-admission-identity
                           (harness-admission-test--request
                            '(:test-account "acct-a" :test-route "fp8")))))
            (should (equal "acct-a/fp8" (plist-get identity :pool)))
            (should (equal "acct-a" (plist-get identity :account)))
            ;; The provider's own module answered; the hook was not
            ;; needed and nothing else was asked.
            (should (equal '(method) asked)))
        (harness-unregister-method 'provider/admission-identity)))))

(ert-deftest harness-admission-a-callback-sees-the-pool-closed ()
  "A terminal callback that starts another request finds the pool closed.
The callback of a request that met a rate limit is an ordinary place to
start the next one from, so the pool is told first and the callback
runs afterwards.  Accounting afterwards would let the callback send into
a pool this very event should have closed."
  (harness-admission-test-with
    (harness-admission-test--says
     (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit
                                             :retry-after 0.3))
     (harness-admission-test--reply 'end-turn))
    (let ((inside nil) (sent-inside nil))
      (harness-admission-test--admit
       (list :on-event
             (lambda (event)
               (when (eq (plist-get event :type) 'done)
                 (setq inside (plist-get (or (harness-admission-test--pool) '()) :until))
                 ;; A reentrant callback starts the next request here.
                 (harness-admission-test--admit)
                 (setq sent-inside (harness-admission-test--sent-count))))))
      (harness-test-wait (lambda () (and inside sent-inside)) 5 "the callback")
      ;; The pool was already resting when the callback ran, and the
      ;; request it started did not go.
      (should (> inside (float-time)))
      (should (= 1 sent-inside)))))

(ert-deftest harness-admission-a-callback-that-signals-still-frees-the-place ()
  "A terminal callback that signals does not leak the pool's place.
The place is given back in an unwind, so a caller's failed callback ends
its request and the next one goes; nothing waits on a callback that
could not finish.  The request here answers from its own `start', so the
failure is the callback's and reaches the caller as it would."
  (harness-admission-test-with
    (harness-admission-test--says
     (harness-admission-test--reply 'end-turn))
    (let ((start (lambda (request)
                   (funcall (plist-get request :on-event)
                            (list :type 'done :stop-reason 'end-turn))
                   (list :cancel #'ignore))))
      ;; The callback's failure reaches whoever started the request.
      (should-error
       (harness-admission-admit
        (harness-admission-test--request
         (list :on-event (lambda (event)
                           (when (eq (plist-get event :type) 'done)
                             (error "the caller's callback failed")))))
        start))
      ;; The place is back, and the pool lets the next request in.
      (should (= 0 (plist-get (harness-admission-test--pool) :busy)))
      (let ((started 0))
        (harness-admission-admit
         (harness-admission-test--request (list :on-event (lambda (_event) nil)))
         (lambda (_request) (cl-incf started) (list :cancel #'ignore)))
        (should (= 1 started))
        (should (= 1 (plist-get (harness-admission-test--pool) :busy)))))))

(ert-deftest harness-admission-a-recovering-pool-spaces-a-request-that-arrives ()
  "The spacing of a recovering pool is the pool's, not the timer's.
A request that arrives in the moment a rest ends is spaced like the
ones that waited: every path through the pool decides it the same way,
so a timer that has not run yet cannot let a burst out."
  (harness-admission-test-with
    (let ((harness-admission-release-spacing 0.15))
      (harness-admission-test--says
       (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 0.05))
       (harness-admission-test--reply 'end-turn))
      (harness-admission-test--admit)
      (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                         5 "the pool to rest")
      (harness-admission-test--admit)
      (harness-admission-test--admit)
      ;; Wait until the rest has ended but before the pool's own timer
      ;; can have drained the queue, then arrive with a third request.
      (harness-test-wait (lambda () (>= (float-time) (plist-get (harness-admission-test--pool) :until)))
                         5 "the rest to end")
      (harness-admission-test--admit)
      (harness-test-wait (lambda () (= 4 (harness-admission-test--sent-count)))
                         10 "the queue to go")
      ;; Four requests, the first of which met the limit: the three that
      ;; waited are at least two spacings apart.
      (should (>= (- (harness-admission-test--at 4) (harness-admission-test--at 2)) 0.29)))))

;;;; Coming back gradually, in the order that matters

(ert-deftest harness-admission-a-recovering-pool-releases-one-at-a-time ()
  "Work that waited out a rate limit goes back a piece at a time.
The queue is not sent as the burst that caused the limit: with a
spacing of a tenth of a second, four requests take at least three
spacings to go, and they all go."
  (harness-admission-test-with
    (let ((harness-admission-release-spacing 0.1))
      (harness-admission-test--says
       (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 0.05))
       (harness-admission-test--reply 'end-turn))
      (harness-admission-test--admit)
      (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                         5 "the pool to rest")
      (dotimes (_ 4) (harness-admission-test--admit))
      (should (= 1 (harness-admission-test--sent-count)))
      (harness-test-wait (lambda () (= 5 (harness-admission-test--sent-count)))
                         10 "the queue to go")
      ;; One when the rest ended, and one per spacing after it: the
      ;; four that waited take at least three spacings to go.
      (should (>= (- (harness-admission-test--at 5) (harness-admission-test--at 2)) 0.29))
      (should (<= (- (harness-admission-test--at 5) (harness-admission-test--at 2)) 1.0)))))

(ert-deftest harness-admission-a-pool-that-has-recovered-lets-work-in-at-once ()
  "Once a rest is over and its queue gone, the pool is open again.
The spacing is for the work that waited out a rest, not for every
request the pool ever sees afterwards: a queue that forms after the
recovered one has gone is let in at once, as an open pool does."
  (harness-admission-test-with
    (let ((harness-admission-release-spacing 0.2))
      (harness-admission-test--says
       (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 0.05))
       (harness-admission-test--reply 'end-turn)
       (harness-admission-test--reply 'end-turn))
      (harness-admission-test--admit)
      (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                         5 "the pool to rest")
      (harness-admission-test--admit)
      ;; Both go: the one that waited, and the one that did not.
      (harness-test-wait (lambda () (= 2 (harness-admission-test--sent-count)))
                         10 "the queue to go")
      (should-not (plist-get (harness-admission-test--pool) :recovering))
      ;; A request arriving now is sent in the admitting call itself.
      (harness-admission-test--admit)
      (should (= 3 (harness-admission-test--sent-count))))))

(ert-deftest harness-admission-a-turn-goes-before-a-one-off-call-and-a-warmer ()
  "A recovering pool lets a turn in before a one-off call, and one before a warmer.
A warmer exists to save money later; it must never make a person wait.
Within one rank the order is first come first served."
  (harness-admission-test-with
    (let ((harness-admission-release-spacing 0.1))
      (harness-admission-test--says
       (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 0.05))
       (harness-admission-test--reply 'end-turn))
      (harness-admission-test--admit)
      (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                         5 "the pool to rest")
      ;; Queued worst first, so that only the rank can explain the order.
      (harness-admission-test--admit '(:cache-refresh t :session (:id "warmer")))
      (harness-admission-test--admit '(:ephemeral t :session (:id "judge")))
      (harness-admission-test--admit '(:session (:id "turn")))
      (harness-test-wait (lambda () (= 4 (harness-admission-test--sent-count)))
                         10 "the queue to go")
      (should (equal '("s1" "turn" "judge" "warmer") (harness-admission-test--order))))))

(ert-deftest harness-admission-first-come-first-served-within-a-rank ()
  "Two turns waiting for one pool go in the order they asked."
  (harness-admission-test-with
    (let ((harness-admission-release-spacing 0.1))
      (harness-admission-test--says
       (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 0.05))
       (harness-admission-test--reply 'end-turn))
      (harness-admission-test--admit)
      (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                         5 "the pool to rest")
      (harness-admission-test--admit '(:session (:id "first")))
      (harness-admission-test--admit '(:session (:id "second")))
      (harness-test-wait (lambda () (= 3 (harness-admission-test--sent-count)))
                         10 "the queue to go")
      (should (equal '("s1" "first" "second") (harness-admission-test--order))))))

;;;; Cancelling, and giving up

(ert-deftest harness-admission-a-waiting-request-can-be-cancelled ()
  "A request that waited can be stopped before it is sent, and the pool
has its place back: nothing is sent for it, its caller is told it ended
as cancelled, and the next request is not held behind it."
  (harness-admission-test-with
    (harness-admission-test--says
     (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 0.3))
     (harness-admission-test--reply 'end-turn)
     (harness-admission-test--reply 'end-turn))
    (harness-admission-test--admit)
    (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                       5 "the pool to rest")
    (let* ((events nil)
           (handle (harness-admission-test--admit
                    (list :on-event (lambda (event) (push event events))))))
      (should (= 1 (harness-admission-test--sent-count)))
      (funcall (plist-get handle :cancel))
      (should (equal '(done) (mapcar (lambda (e) (plist-get e :type)) events)))
      (should (eq 'cancelled (plist-get (car events) :stop-reason)))
      (should (= 1 (harness-admission-test--sent-count)))
      (should (= 0 (plist-get (harness-admission-test--pool) :queued))))))

(ert-deftest harness-admission-a-cancelled-request-in-flight-frees-the-pool ()
  "Cancelling a request already sent frees its place at once.
A provider that never answers must not keep the pool's concurrency held."
  (harness-admission-test-with
    (let ((harness-admission-max-concurrent 1)
          (harness-admission-test--replies nil))
      (let ((handle (harness-admission-test--admit)))
        (should (= 1 (plist-get (harness-admission-test--pool) :busy)))
        (funcall (plist-get handle :cancel))
        (should (= 0 (plist-get (harness-admission-test--pool) :busy)))))))

(ert-deftest harness-admission-a-request-waits-at-most-what-it-is-given ()
  "A pool closed for longer than `harness-admission-max-wait' ends the request.
The failure says what the pool owes as `:retry-after', so the shared
retry waits at least that long rather than trying into a closed pool,
and the wait still owed is the provider's own word, not a guess."
  (harness-admission-test-with
    (let ((harness-admission-max-wait 0.1))
      (harness-admission-test--says
       (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 60)))
      (harness-admission-test--admit)
      (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                         5 "the pool to rest")
      (let ((events nil)
            (started (float-time)))
        (harness-admission-test--admit (list :on-event (lambda (event) (push event events))))
        (harness-test-wait (lambda () events) 5 "the wait to end")
        (should (< (- (float-time) started) 2))
        (let ((done (car events)))
          (should (eq 'error (plist-get done :stop-reason)))
          (should (eq 'rate-limit (plist-get done :error-kind)))
          (should (> (plist-get done :retry-after) 50)))
        (should (= 1 (harness-admission-test--sent-count)))
        (should (= 0 (plist-get (harness-admission-test--pool) :queued)))))))

;;;; The way every request of the harness actually arrives

(ert-deftest harness-admission-provider-complete-goes-through-the-pool ()
  "`provider/complete' asks the pool, so a turn, a one-off call and a
warmer are all held by the same rate limit of the same account."
  (harness-admission-test-with
    (harness-define-provider 'admission-stub
      :label "Admission stub"
      :complete #'harness-admission-test--stub)
    (harness-admission-test--says
     (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 0.3))
     (harness-admission-test--reply 'end-turn)
     (harness-admission-test--reply 'end-turn))
    (let ((first-done nil))
      (harness-call 'provider/complete
                    (harness-admission-test--request
                     (list :on-event (lambda (event)
                                       (when (eq (plist-get event :type) 'done)
                                         (setq first-done event))))))
      (harness-test-wait (lambda () first-done) 5 "the first request")
      (should (eq 'error (plist-get first-done :stop-reason)))
      (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                         5 "the pool to rest")
      ;; A one-off call of the same provider waits, and the handle it was
      ;; given stops it before anything is sent.
      (let* ((events nil)
             (handle (harness-call 'provider/complete
                                   (harness-admission-test--request
                                    (list :ephemeral t
                                          :on-event (lambda (event) (push event events)))))))
        (should (= 1 (harness-admission-test--sent-count)))
        (should (plist-get (plist-get handle :admission) :waiting))
        (funcall (plist-get handle :cancel))
        (should (eq 'cancelled (plist-get (car events) :stop-reason)))
        (should (= 1 (harness-admission-test--sent-count)))))))

(ert-deftest harness-admission-a-provider-without-a-model-is-sent-as-it-was ()
  "A model that names no provider has no pool, so it is sent untouched.
Nothing is known about who would serve it, so nothing is assumed."
  (harness-admission-test-with
    (harness-admission-test--says (harness-admission-test--reply 'end-turn))
    (let ((handle (harness-admission-admit (list :model "no-provider-here"
                                                 :session (list :id "s1"))
                                           #'harness-admission-test--stub)))
      (should (functionp (plist-get handle :cancel)))
      (should-not (plist-get handle :admission))
      (should (= 1 (harness-admission-test--sent-count))))))

;;;; What a pool tells a client

(ert-deftest harness-admission-state-says-what-every-pool-is-doing ()
  "`admission/state' reports the pools, in key order, with their queues.
A client shows a session waiting on its provider from this."
  (harness-admission-test-with
    (harness-admission-test--says
     (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 0.3)))
    (harness-admission-test--admit)
    (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                       5 "the pool to rest")
    (harness-admission-test--admit '(:session (:id "waiting-session")))
    (let ((pool (harness-admission-test--pool)))
      (should (equal "admission-stub" (plist-get pool :key)))
      (should (= 1 (plist-get pool :queued)))
      (should (> (plist-get pool :until) (float-time)))
      (should (equal '("waiting-session")
                     (mapcar (lambda (w) (plist-get w :session)) (plist-get pool :waiting))))
      (should (>= (plist-get (car (plist-get pool :waiting)) :wait) 0)))))

(ert-deftest harness-admission-a-waiting-session-is-told-why ()
  "A session whose request waits out a rate limit is left a hint saying so.
What a person reads names the provider, how long, and how many wait."
  (harness-admission-test-with
    (harness-admission-test--says
     (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 0.3)))
    (harness-admission-test--admit)
    (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                       5 "the pool to rest")
    (let ((hints nil)
          (real (symbol-function 'harness-admission--hint)))
      (cl-letf (((symbol-function 'harness-admission--hint)
                 (lambda (session-id text) (push (cons session-id text) hints))))
        (harness-admission-test--admit '(:session (:id "waiting-session")))
        (let ((hint (cdr (cl-find "waiting-session" hints :key #'car :test #'equal))))
          (should (stringp hint))
          (should (string-match-p "admission-stub: rate limited; waiting [0-9.]* s" hint)))))))

;;;; Across sessions, over a real wire

(ert-deftest harness-admission-a-429-holds-another-sessions-step-and-the-warmer ()
  "One session's 429 holds another session's step and a cache warmer.
This is the field's shape: a provider rate limits one request, and the
harness's other work against the same account must not be sent into the
closed pool.  Two providers are served by one local server, so the wire
count is the whole of what went out: the first session's step is
answered 429 with a Retry-After, the second session's step and a warmer
wait for it, and all three go once the pool opens -- the warmer last.
No pool of the other provider is touched."
  (skip-unless (executable-find "curl"))
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider provider-openai retry admission small))
      (harness-test-load-module m))
    (harness-admission-reset)
    (let* ((answer (concat "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"ok\"}}]}\n\n"
                           "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
                           "data: [DONE]\n\n"))
           (attempts 0)
           (server (harness-test-http-serve
                    `(("/chat/completions"
                       . ,(lambda (n)
                            (setq attempts n)
                            (if (= n 1)
                                (list 429 '(("Content-Type" . "application/json")
                                            ("Retry-After" . "0.3"))
                                      "{\"error\":{\"message\":\"Rate limit reached\",\"type\":\"rate_limit_error\"}}")
                              (list 200 '(("Content-Type" . "text/event-stream")) answer)))))))
           (harness-admission t)
           (harness-admission-delay 0.01)
           (harness-admission-jitter 0)
           (harness-admission-max-delay 0.05)
           (harness-admission-release-spacing 0.05)
           (harness-admission-max-wait 5.0)
           (harness-retry-delay 0.01)
           (harness-retry-jitter 0))
      (unwind-protect
          (progn
            (harness-openai-register-endpoint
             (list :id 'admission-local :label "Local"
                   :base-url (harness-test-http-url server "") :api-key "sk-test"))
            (harness-admission-test--says)
            (let ((first-done nil))
              ;; One session's step.
              (harness-call 'provider/complete
                            (list :model "admission-local:m" :session (list :id "a")
                                  :messages (list (list :role 'user :content "hi"))
                                  :on-event (lambda (event)
                                              (when (eq (plist-get event :type) 'done)
                                                (setq first-done event)))))
              (harness-test-wait (lambda () first-done) 10 "the 429")
              (should (eq 'error (plist-get first-done :stop-reason)))
              (harness-test-wait
               (lambda () (< 0 (plist-get (or (harness-admission-test--pool "admission-local") '()) :until)))
               5 "the pool to rest")
              ;; Another session's step, and a warmer, both of the same
              ;; provider: neither may be sent while the pool is closed.
              (let ((second-done nil) (warm-done nil))
                (harness-call 'provider/complete
                              (list :model "admission-local:m" :session (list :id "b")
                                    :messages (list (list :role 'user :content "hi"))
                                    :on-event (lambda (event)
                                                (when (eq (plist-get event :type) 'done)
                                                  (setq second-done event)))))
                (harness-call 'provider/complete
                              (list :model "admission-local:m" :session (list :id "c")
                                    :cache-refresh t :messages (list (list :role 'user :content "ping"))
                                    :on-event (lambda (event)
                                                (when (eq (plist-get event :type) 'done)
                                                  (setq warm-done event)))))
                (should (= 1 attempts))
                (harness-test-wait (lambda () (and second-done warm-done)) 10 "both")
                ;; All three went, in the order the pool let them.
                (should (= 3 attempts))
                (should (eq 'end-turn (plist-get second-done :stop-reason)))
                (should (eq 'end-turn (plist-get warm-done :stop-reason))))))
        (delete-process server)
        (remhash 'admission-local harness-providers)
        (harness-provider--forget 'admission-local)))))

;;;; A replay the transport decides on is a send like any other

(ert-deftest harness-admission-a-transport-replay-waits-for-the-pool ()
  "A replay of another request's limit does not go into the cooldown.
`harness-http' replays a connection that failed before anything reached
the caller, inside the admitted request.  That replay is a send: it asks
the pool first, waits the rest out, and only then goes.  The first
attempt is the caller's and is never gated, so nothing is counted twice,
and a pool that is open changes nothing at all."
  (skip-unless (executable-find "curl"))
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider retry admission))
      (harness-test-load-module m))
    (harness-admission-reset)
    (let* ((attempts 0)
           (gate-calls 0)
           (server (harness-test-http-serve
                    `(("/a" . ,(lambda (_n)
                                   (list 200 '(("Content-Type" . "text/plain")) "a")))
                      ("/b" . ,(lambda (n)
                                   (setq attempts n)
                                   (if (= n 1)
                                       ;; Nothing answered, the connection
                                       ;; dropped: the transport's own case.
                                       'reset
                                     (list 200 '(("Content-Type" . "text/plain")) "b")))))))
           (harness-admission t)
           (harness-admission-delay 0.01)
           (harness-admission-jitter 0)
           (harness-admission-max-delay 0.05)
           (harness-admission-release-spacing 0.02)
           (harness-admission-max-wait 5.0)
           (harness-http-retry-delay 0.02)
           (harness-http-retry-jitter 0)
           (harness-http-max-retries 3)
           (results nil)
           (sent nil))
      (unwind-protect
          (progn
            ;; Request A establishes a cooldown for the pool.
            (let ((pool (harness-admission--pool-of "admission-wire" "admission-wire")))
              (harness-admission--rest pool (list :stop-reason 'error
                                                  :error-kind 'rate-limit
                                                  :retry-after 0.4))
              (should (> (- (harness-admission--pool-until pool) (float-time)) 0.2)))
            ;; Request B is admitted, meets a dropped connection, and is
            ;; about to be replayed by the transport.  The gate holds it.
            (let* ((entry (make-harness-admission--entry
                           :key "admission-wire" :account "admission-wire"))
                   (pool (harness-admission--pool-of "admission-wire" "admission-wire")))
              (setf (harness-admission--entry-pool entry) pool)
              (let ((gate (harness-admission--transport-gate entry)))
                (setq gate-calls (1+ gate-calls))
                (let ((answer (funcall gate)))
                  ;; It waits for the rest, and says so.
                  (should (eq :wait (car answer)))
                  (should (> (nth 1 answer) 0.2)))))
            ;; Over a real wire: the same, through `harness-http' itself.
            (harness-http-request
             (harness-test-http-url server "/b") :method "POST" :body "q" :retry t
             :gate (lambda ()
                     (let* ((pool (harness-admission--pool-of "admission-wire" "admission-wire"))
                            (left (- (harness-admission--pool-until pool) (float-time))))
                       (when (> left 0) (list :wait left))))
             :callback (lambda (status _headers body err)
                         (push (list :status status :body body :err err) results)))
            ;; The first attempt is the caller's and goes at once.
            (harness-test-wait (lambda () (= 1 attempts)) 10 "the first attempt")
            ;; The replay waits out the rest the other request established:
            ;; the wire sees nothing more while the pool is closed.
            (let ((deadline (+ (float-time) 0.25)))
              (while (< (float-time) deadline)
                (accept-process-output nil 0.02)
                (sit-for 0.005)))
            (should (= 1 attempts))
            ;; The pool opens and the replay goes by itself, once.
            (harness-test-wait (lambda () results) 10 "the replay")
            (should (= 2 attempts))
            (should (equal "b" (plist-get (car results) :body))))
        (delete-process server)))))


;;;; A replay that would wait past the bound is refused

(ert-deftest harness-admission-a-transport-replay-past-the-bound-is-refused ()
  "A pool closed longer than the request may wait ends the replay.
A transport replay is not held behind a pool for ever: past
`harness-admission-max-wait' the gate refuses, the request ends with a
rate limit naming the pool, and the retry layer decides what to do with
it.  Nothing is sent for the replay."
  (skip-unless (executable-find "curl"))
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (m '(store project config provider retry admission))
      (harness-test-load-module m))
    (harness-admission-reset)
    (let* ((attempts 0)
           (server (harness-test-http-serve
                    `(("/b" . ,(lambda (n)
                                   (setq attempts n)
                                   (if (= n 1) 'reset
                                     (list 200 '(("Content-Type" . "text/plain")) "b")))))))
           (harness-admission t)
           (harness-admission-max-wait 0.1)
           (harness-http-retry-delay 0.01)
           (harness-http-retry-jitter 0)
           (harness-http-max-retries 3)
           (results nil))
      (unwind-protect
          (progn
            ;; A pool closed for an hour, and a request admitted by it.
            (let* ((entry (make-harness-admission--entry
                           :key "admission-wire" :account "admission-wire"))
                   (pool (harness-admission--pool-of "admission-wire" "admission-wire")))
              (setf (harness-admission--entry-pool entry) pool)
              (harness-admission--rest pool (list :stop-reason 'error
                                                  :error-kind 'rate-limit
                                                  :retry-after 3600))
              (let ((gate (harness-admission--transport-gate entry)))
                ;; The pool will not open before the request's bound, so
                ;; the replay is refused now rather than slept past it.
                (let ((answer (funcall gate)))
                  (should (eq :refuse (car answer)))
                  (should (string-match-p "rate limited" (nth 1 answer))))
                ;; A rest shorter than the bound is waited, not refused.
                (let* ((soon (make-harness-admission--entry
                              :key "admission-soon" :account "admission-soon"))
                       (soon-pool (harness-admission--pool-of "admission-soon" "admission-soon")))
                  (setf (harness-admission--entry-pool soon) soon-pool)
                  (harness-admission--rest soon-pool (list :stop-reason 'error
                                                           :error-kind 'rate-limit
                                                           :retry-after 0.02))
                  (should (eq :wait (car (funcall (harness-admission--transport-gate soon))))))))
            ;; Over a real wire: the transport's replay is refused, and
            ;; nothing is sent a second time.
            (harness-admission--rest (harness-admission--pool-of "admission-wire" "admission-wire")
                                     (list :stop-reason 'error
                                           :error-kind 'rate-limit
                                           :retry-after 3600))
            (let* ((entry (make-harness-admission--entry
                           :key "admission-wire" :account "admission-wire"))
                   (pool (harness-admission--pool-of "admission-wire" "admission-wire")))
              (setf (harness-admission--entry-pool entry) pool)
              (harness-http-request
               (harness-test-http-url server "/b") :method "POST" :body "q" :retry t
               :gate (harness-admission--transport-gate entry)
               :callback (lambda (status _headers body err)
                           (push (list :status status :body body :err err) results))))
            (harness-test-wait (lambda () results) 10 "the refusal")
            (should (= 1 attempts))
            (should (eq 'rate-limit (car (plist-get (car results) :err)))))
        (delete-process server)))))

;;;; A reload keeps the work that waits, and a bound on concurrency

(ert-deftest harness-admission-a-reload-keeps-the-requests-that-wait ()
  "A reload initialises the module again and must not drop its queue.
The pools are the harness process's, and a request waiting out a rate
limit has no other copy: clearing them would send nothing and tell
nobody."
  (harness-admission-test-with
    (harness-admission-test--says
     (harness-admission-test--reply 'error '(:error "HTTP 429" :error-kind rate-limit :retry-after 0.3)))
    (harness-admission-test--admit)
    (harness-test-wait (lambda () (< 0 (plist-get (or (harness-admission-test--pool) '()) :until)))
                       5 "the pool to rest")
    (harness-admission-test--admit)
    (should (= 1 (plist-get (harness-admission-test--pool) :queued)))
    ;; The module is ready, so this is a reload's initialisation again.
    (should (harness-module-ready-p 'admission))
    (harness-module-start 'admission)
    (should (= 1 (plist-get (harness-admission-test--pool) :queued)))))

(ert-deftest harness-admission-a-pool-holds-to-its-concurrency-bound ()
  "`harness-admission-max-concurrent' holds a pool to that many in flight.
A provider that refuses concurrent requests can be held to one, and the
next goes when the first is done."
  (harness-admission-test-with
    (let ((harness-admission-max-concurrent 1)
          (harness-admission-release-spacing 0))
      (harness-admission-test--says
       (harness-admission-test--reply 'end-turn)
       (harness-admission-test--reply 'end-turn))
      (harness-admission-test--admit)
      (harness-admission-test--admit)
      ;; The second waits for the first to finish, not for a rate limit.
      (should (= 1 (harness-admission-test--sent-count)))
      (should (= 1 (plist-get (harness-admission-test--pool) :queued)))
      (harness-test-wait (lambda () (= 2 (harness-admission-test--sent-count)))
                         5 "the second request"))))


;;;; Failure ownership across queued and cancelled requests

(ert-deftest harness-admission-terminal-accounting-cannot-strand-its-caller ()
  (harness-admission-test-with
    (let (emit events)
      (harness-admission-admit
       (harness-admission-test--request (list :on-event (lambda (e) (push e events))))
       (lambda (request) (setq emit (plist-get request :on-event)) (list :cancel #'ignore)))
      (cl-letf (((symbol-function 'harness-admission--note)
                 (lambda (&rest _) (error "accounting unavailable"))))
        (funcall emit '(:type done :stop-reason end-turn)))
      (should (= 1 (length events)))
      (should (= 0 (plist-get (harness-admission-test--pool) :busy))))))

(ert-deftest harness-admission-cancellation-settles-and-fences-a-silent-producer ()
  (harness-admission-test-with
    (let (emit events (cancelled 0))
      (let ((handle (harness-admission-admit
                     (harness-admission-test--request (list :on-event (lambda (e) (push e events))))
                     (lambda (request)
                       (setq emit (plist-get request :on-event))
                       (list :cancel (lambda () (cl-incf cancelled)))))))
        (funcall (plist-get handle :cancel))
        (funcall (plist-get handle :cancel))
        (funcall emit '(:type text :delta "late"))
        (funcall emit '(:type done :stop-reason error :error-kind rate-limit :retry-after 99))
        (should (= 1 cancelled))
        (should (equal '((:type done :stop-reason cancelled)) events))
        (should (= 0 (plist-get (harness-admission-test--pool) :busy)))))))

(ert-deftest harness-admission-cancellation-reaches-a-queued-starts-late-handle ()
  (harness-admission-test-with
    (let ((harness-admission-max-concurrent 1) first queued (cancelled 0) events)
      (harness-admission-admit
       (harness-admission-test--request)
       (lambda (request) (setq first (plist-get request :on-event)) (list :cancel #'ignore)))
      (setq queued
            (harness-admission-admit
             (harness-admission-test--request (list :on-event (lambda (e) (push e events))))
             (lambda (_request)
               ;; The request already returned its queue handle.  A callback
               ;; cancels it while the provider is still constructing its handle.
               (funcall (plist-get queued :cancel))
               (list :cancel (lambda () (cl-incf cancelled))))))
      (funcall first '(:type done :stop-reason end-turn))
      (should (= 1 cancelled))
      (should (equal '((:type done :stop-reason cancelled)) events))
      (should (= 0 (plist-get (harness-admission-test--pool) :busy))))))

(ert-deftest harness-admission-start-failure-after-terminal-cannot-redeliver ()
  (harness-admission-test-with
    (let (events)
      (harness-admission-admit
       (harness-admission-test--request (list :on-event (lambda (e) (push e events))))
       (lambda (request)
         (funcall (plist-get request :on-event) '(:type done :stop-reason end-turn))
         (error "producer failed after its terminal callback")))
      (should (equal '((:type done :stop-reason end-turn)) events)))))

(ert-deftest harness-admission-reset-isolates-callbacks-and-reentrant-successors ()
  (harness-admission-test-with
    (let ((harness-admission-max-concurrent 0) events successor)
      (harness-admission-admit
       (harness-admission-test--request (list :on-event (lambda (_) (push 'healthy events)))) #'ignore)
      (harness-admission-admit
       (harness-admission-test--request
        (list :on-event (lambda (_)
                          (setq successor (harness-admission-admit
                                           (harness-admission-test--request
                                            (list :on-event (lambda (_) (push 'successor events)))) #'ignore))
                          (error "broken cancelled caller")))) #'ignore)
      (harness-admission-reset)
      (should (memq 'healthy events))
      (should successor)
      ;; Reset cannot erase a new queue created by a cancellation observer.
      (should (= 1 (plist-get (harness-admission-test--pool) :queued)))
      (funcall (plist-get successor :cancel))
      (should (memq 'successor events)))))

(ert-deftest harness-admission-counted-requests-cannot-retry-unsent-waits-forever ()
  (harness-admission-test-with
    (dolist (module '(tools session agent)) (harness-test-load-module module))
    (harness-module-start 'retry)
    (let* ((default-directory dir)
           (harness-retry-policy-functions
            (list (lambda (_) '(:owner "Counted fixture" :count-sends t))))
           (harness-retry-max-attempts 2) (harness-retry-max-delay 0.001)
           (harness-admission-max-wait 0.005)
           (wait-failures 0) (give-up (symbol-function 'harness-admission--give-up))
           (sid (plist-get (harness-call 'session/create :cwd dir :model "admission-stub:m") :id)))
      (harness-define-provider 'admission-stub :complete #'harness-admission-test--stub)
      (let ((pool (harness-admission--pool-of "admission-stub")))
        (setf (harness-admission--pool-until pool) (+ (float-time) 1000)))
      (let ((result
             (cl-letf (((symbol-function 'harness-admission--give-up)
                        (lambda (entry) (cl-incf wait-failures) (funcall give-up entry))))
               (harness-test-await (harness-call 'agent/prompt sid "ordinary work") 2))))
        (should (= 3 wait-failures))
        (should (eq 'error (plist-get result :stop-reason)))
        (should (string-match-p "rate limited" (or (plist-get result :error) "")))
        (should-not (harness-agent-running-p sid))
        (should (= 0 (harness-admission-test--sent-count)))
        (should (= 0 (plist-get (harness-admission-test--pool) :queued)))))))

(ert-deftest harness-admission-reload-keeps-live-queue-and-cancel-ownership ()
  (harness-admission-test-with
    (let ((harness-admission-max-concurrent 0) events)
      (let ((handle (harness-admission-admit
                     (harness-admission-test--request (list :on-event (lambda (e) (push e events)))) #'ignore)))
        (harness-test-load-module 'admission)
        (should (= 1 (plist-get (harness-admission-test--pool) :queued)))
        (funcall (plist-get handle :cancel))
        (should (equal '((:type done :stop-reason cancelled)) events))
        (should (= 0 (plist-get (harness-admission-test--pool) :queued)))))))

(ert-deftest harness-admission-a-protocol-terminal-can-still-stop-its-producer ()
  (harness-admission-test-with
    (let ((cancelled 0) events)
      (let ((handle (harness-admission-admit
                     (harness-admission-test--request (list :on-event (lambda (event) (push event events))))
                     (lambda (request)
                       (funcall (plist-get request :on-event) '(:type done :stop-reason error :error-kind protocol))
                       (list :cancel (lambda () (cl-incf cancelled)))))))
        (funcall (plist-get handle :cancel))
        (should (= 1 cancelled))
        (should (= 1 (length events)))))))

(ert-deftest harness-admission-counted-one-off-calls-exhaust-the-unsent-budget ()
  (harness-admission-test-with
    (require 'harness-small)
    (dolist (module '(tools session agent)) (harness-test-load-module module))
    (harness-module-start 'retry)
    (let* ((default-directory dir)
           (harness-retry-policy-functions (list (lambda (_) '(:owner "fixture" :count-sends t))))
           (harness-retry-max-attempts 2) (harness-retry-max-delay 0.001)
           (harness-admission-max-wait 0.005)
           (sid (plist-get (harness-call 'session/create :cwd dir :model "admission-stub:m") :id))
           (promise (harness-make-promise)) handle)
      (harness-define-provider 'admission-stub :complete #'harness-admission-test--stub)
      (setf (harness-admission--pool-until (harness-admission--pool-of "admission-stub"))
            (+ (float-time) 1000))
      (unwind-protect
          (progn
            (setq handle (harness-small-ask
                          (list :model "admission-stub:m" :session (harness-call 'session/get sid)
                                :ephemeral t :prompts '(recap-system))
                          (list :on-event (lambda (event)
                                            (when (eq 'done (plist-get event :type))
                                              (harness-resolve promise event))))))
            (should (eq 'error (plist-get (harness-test-await promise 0.3) :stop-reason)))
            (should (= 0 (harness-admission-test--sent-count)))
            (should (= 0 (plist-get (harness-admission-test--pool) :queued))))
        (when handle (funcall (plist-get handle :cancel)))))))

(ert-deftest harness-admission-queue-cancellation-is-not-provider-recovery ()
  (harness-admission-test-with
    (let ((pool (harness-admission--pool-of "admission-stub")))
      (setf (harness-admission--pool-until pool) (+ (float-time) 10)
            (harness-admission--pool-streak pool) 3)
      (let ((handle (harness-admission-test--admit)))
        (funcall (plist-get handle :cancel))
        (should (= 3 (harness-admission--pool-streak pool)))))))

(provide 'harness-admission-test)
;;; harness-admission-test.el ends here
