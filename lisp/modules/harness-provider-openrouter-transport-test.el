;;; harness-provider-openrouter-transport-test.el --- The wire, not a fake  -*- lexical-binding: t; -*-

;;; Commentary:

;; The other OpenRouter suites replace `harness-http-request' itself, so
;; they see one request per call that the transport makes.  This one
;; replaces nothing: a real Emacs HTTP server on 127.0.0.1 answers, and
;; the requests are real curl processes through the real
;; `harness-http-request'.  What it counts is what actually went on the
;; wire, which is the only way to see the failure this suite exists for:
;; the shared transport used to replay a failed completion itself, up to
;; `harness-http-max-retries' times, inside one call -- so a policy that
;; allowed one attempt still posted four times, after a policy change or
;; a bound had already stopped authorising it.
;;
;; Every test here is offline: the server is this Emacs, the addresses
;; are 127.0.0.1, and no request leaves the machine.  A test counts
;; completions the server received, records the bodies curl sent, and
;; makes the server fail the way a lost connection or a rate limit does.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)
(require 'harness-provider)
(require 'harness-provider-openai)
(require 'harness-provider-openrouter)
(require 'harness-session)
(require 'harness-provider-openrouter-test-helpers)
;; The harness's own one-off calls are requests of their own, and their
;; retry is the same shared one (`harness-small-ask').
(require 'harness-small)

;;;; A recording server

(cl-defstruct (harness-openrouter-test--wire (:copier nil))
  server url
  (posts 0)                     ; completions received
  (reads 0)                     ; catalogue reads served
  (bodies nil)                  ; request bodies, newest first
  (texts (make-hash-table :test 'eq))   ; connection -> bytes so far
  script)                       ; function of the post's number -> behaviour

(defun harness-openrouter-test--wire-start (&optional script)
  "Start a server for the catalogue and completions; return its wire.
SCRIPT is a function of a completion's number (1 the first) returning
what the server does with it: `reset' (cut the connection with a reset),
`slow-reset' (the same after a second), `answer' (a streamed answer), or
a plist (:status N :headers ALIST :body TEXT) answered as it says."
  (let ((wire (make-harness-openrouter-test--wire :script script)))
    (setf (harness-openrouter-test--wire-server wire)
          (make-network-process
           :name "openrouter-test-wire" :server t :host "127.0.0.1" :service t
           :family 'ipv4 :coding 'binary :noquery t
           :log (lambda (_s connection _m)
                  (set-process-query-on-exit-flag connection nil))
           :filter (lambda (proc data)
                     (harness-openrouter-test--wire-filter wire proc data))))
    (setf (harness-openrouter-test--wire-url wire)
          (format "http://127.0.0.1:%d"
                  (process-contact (harness-openrouter-test--wire-server wire) :service)))
    wire))

(defun harness-openrouter-test--wire-stop (wire)
  "Stop WIRE's server."
  (when-let* ((server (harness-openrouter-test--wire-server wire)))
    (delete-process server)
    (setf (harness-openrouter-test--wire-server wire) nil)))

(defun harness-openrouter-test--wire-request (text)
  "Return (METHOD PATH BODY) when TEXT holds a whole HTTP request, else nil.
The body is cut to its Content-Length, so a request whose body is still
arriving is not answered before curl sent it."
  (when-let* ((split (string-match "\r\n\r\n" text)))
    (let* ((head (substring text 0 split))
           (body (substring text (+ split 4)))
           (lines (split-string head "\r\n" t))
           (wanted
            (let ((length 0))
              (dolist (line lines length)
                (when (string-match "\\`[Cc]ontent-[Ll]ength:[ \t]*\\([0-9]+\\)" line)
                  (setq length (string-to-number (match-string 1 line))))))))
      (when (and (>= (length body) wanted) (nth 1 (split-string (car lines) " " t)))
        (let ((line (split-string (car lines) " " t)))
          (list (nth 0 line) (nth 1 line) (substring body 0 wanted)))))))

(defun harness-openrouter-test--wire-filter (wire proc data)
  "Add DATA to WIRE's connection PROC, and answer it once whole."
  (let ((text (concat (or (gethash proc (harness-openrouter-test--wire-texts wire)) "") data)))
    (puthash proc text (harness-openrouter-test--wire-texts wire))
    (when-let* ((request (harness-openrouter-test--wire-request text)))
      (remhash proc (harness-openrouter-test--wire-texts wire))
      (pcase-let* ((`(,_method ,path ,body) request))
        (cond
         ((string-match-p "/endpoints\\'" path)
          (cl-incf (harness-openrouter-test--wire-reads wire))
          (harness-openrouter-test--wire-send
           proc 200 '(("Content-Type" . "application/json"))
           (harness-openrouter-test--catalogue-json)))
         ((string-suffix-p "/chat/completions" path)
          (cl-incf (harness-openrouter-test--wire-posts wire))
          (push body (harness-openrouter-test--wire-bodies wire))
          (harness-openrouter-test--wire-answer wire proc))
         (t (harness-openrouter-test--wire-send proc 404 nil "not found")))))))

(defun harness-openrouter-test--wire-answer (wire proc)
  "Answer PROC, a completion WIRE has received, as WIRE's script says."
  (let* ((number (harness-openrouter-test--wire-posts wire))
         (what (if (harness-openrouter-test--wire-script wire)
                   (funcall (harness-openrouter-test--wire-script wire) number)
                 'answer)))
    (pcase what
      ('reset (harness-test--http-reset proc))
      ('slow-reset (run-at-time 1.1 nil
                                (lambda () (when (process-live-p proc)
                                             (harness-test--http-reset proc)))))
      ('answer
       (harness-openrouter-test--wire-send
        proc 200 '(("Content-Type" . "text/event-stream"))
        (apply #'harness-openrouter-test--sse
               (append (harness-openrouter-test--answer-chunks)
                       (list '(:choices () :usage (:prompt_tokens 10 :completion_tokens 2))
                             "[DONE]")))))
      (_ (harness-openrouter-test--wire-send
          proc (or (plist-get what :status) 200)
          (plist-get what :headers) (or (plist-get what :body) ""))))))

(defun harness-openrouter-test--wire-send (proc status headers body)
  "Answer PROC with STATUS, HEADERS and BODY, and close the connection."
  (when (process-live-p proc)
    (ignore-errors (set-network-process-option proc :nodelay t))
    (process-send-string
     proc (concat (format "HTTP/1.1 %d %s\r\n" status (if (= status 200) "OK" "Error"))
                  (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) headers "")
                  (format "Content-Length: %d\r\n" (string-bytes body))
                  "Connection: close\r\n\r\n"
                  body))
    (ignore-errors (process-send-eof proc))))

(defun harness-openrouter-test--wire-hints (sid)
  "Return the hint texts of session SID, oldest first."
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'hint))
                            (harness-call 'session/nodes sid))))

(defun harness-openrouter-test--wire-pinned-session (&optional route)
  "Create a session pinned to this model's DeepInfra endpoint, and return its id.
ROUTE, when given, is the pin to store instead of a fresh one."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                      :model (format "openrouter:%s"
                                                     harness-openrouter-test-model))
                        :id)))
    (harness-call 'session/set-ext sid :openrouter-route
                  (or route (harness-openrouter-test--route)))
    sid))

(defun harness-openrouter-test--wire-wait-retrying (sid)
  "Wait until SESSION SID's next send is scheduled as a retry.
The retry is the shared layer's, and what it leaves as it decides one is
the hint that says so: the request's own state travels with the request,
so nothing about it is visible from the session."
  (harness-test-wait (lambda ()
                       (cl-some (lambda (h) (string-match-p "trying again in" h))
                                (harness-openrouter-test--wire-hints sid)))
                     5 "the retry to be scheduled"))

(defmacro harness-openrouter-test-with-wire (script &rest body)
  "Run BODY with the modules loaded and a recording server for SCRIPT.
The OpenRouter endpoint points at the server, a session made in BODY is
pinned to the DeepInfra endpoint of the catalogue, and every request
goes through the real `harness-http-request'.  The server's wire is
bound as `wire', its URL as `url'."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider tools session agent retry fallback))
       (harness-test-load-module m))
     (harness-test-load-module 'provider-openai)
     (harness-test-load-module 'provider-openrouter)
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-retry--attempts)
     (let* ((wire (harness-openrouter-test--wire-start ,script))
            (url (harness-openrouter-test--wire-url wire))
            (default-directory dir)
            (auth-sources nil)
            (harness-retry-delay 0.01)
            (harness-retry-jitter 0)
            (harness-retry-max-delay 5.0)
            (harness-retry-max-attempts 3)
            (harness-retry-max-seconds nil)
            (harness-http-retry-delay 0.01)
            (harness-http-retry-jitter 0)
            (harness-http-max-retries 3)
            (harness-openrouter-routing nil)
            (harness-openrouter-base-url url)
            (harness-openai--models-cache (make-hash-table :test 'eq))
            (harness-openai-endpoints
             (list (list :id 'openrouter :label "OpenRouter"
                         :base-url url :api-key "test-key"
                         :models (list harness-openrouter-test-model))))
            (harness-openrouter--catalogue (make-hash-table :test 'equal))
            (harness-openrouter--fetching (make-hash-table :test 'equal)))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (harness-openrouter-refresh)
       (unwind-protect
           (progn ,@body)
         (harness-fallback--shutdown)
         (harness-retry--shutdown)
         (harness-openrouter--shutdown)
         (harness-provider-unregister 'openrouter)
         (harness-openai--register-all)
         (harness-openrouter-test--wire-stop wire)))))

;;;; One budget on the wire

(ert-deftest harness-provider-openrouter-transport-one-attempt-is-one-post ()
  "A policy of one attempt sends one POST, whatever the transport would do.
`harness-http-max-retries' is left at its default 3 and the connection
is reset before any of the answer arrives -- the failure the HTTP layer
used to replay by itself.  The server receives exactly one completion,
and the reason names the policy's attempt bound."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire (lambda (_) 'reset)
    (let ((harness-retry-max-attempts 0))
      (setq harness-openrouter-routing (harness-openrouter-test-policy))
      (let ((sid (harness-openrouter-test--wire-pinned-session)))
        (should (eq 'error (plist-get (harness-test-await
                                       (harness-call 'agent/prompt sid "go") 30)
                                      :stop-reason)))
        (should (= 1 (harness-openrouter-test--wire-posts wire)))
        (should (= 3 harness-http-max-retries))
        (should (cl-some (lambda (h) (string-match-p "not trying again (`harness-retry-max-attempts' is 0)" h))
                         (harness-openrouter-test--wire-hints sid)))))))

(ert-deftest harness-provider-openrouter-transport-one-budget-for-every-failure ()
  "A reset and a 503 share the policy's budget, not a lower layer's each.
The first attempt's connection is reset (a transport failure) and the
second is refused with 503 (an HTTP failure): two attempts under a
policy of two, then the turn stops.  A third POST would mean a second
budget somewhere."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire
      (lambda (n)
        (if (= n 1) 'reset
          (list :status 503 :headers '(("Content-Type" . "application/json"))
                :body "{\"error\":{\"code\":503,\"message\":\"busy\"}}")))
    (let ((harness-retry-max-attempts 1))
      (setq harness-openrouter-routing (harness-openrouter-test-policy))
      (let ((sid (harness-openrouter-test--wire-pinned-session)))
      (should (eq 'error (plist-get (harness-test-await
                                     (harness-call 'agent/prompt sid "go") 30)
                                    :stop-reason)))
      (should (= 2 (harness-openrouter-test--wire-posts wire)))
      (should (cl-some (lambda (h) (string-match-p "OpenRouter: network error: .*; trying again" h))
                       (harness-openrouter-test--wire-hints sid)))
      (should (cl-some (lambda (h) (string-match-p "giving up after 1 try" h))
                       (harness-openrouter-test--wire-hints sid)))
      ;; Both attempts were the pinned endpoint, and both were restricted.
      (should (= 2 (length (harness-openrouter-test--wire-bodies wire))))
      (dolist (body (harness-openrouter-test--wire-bodies wire))
        (let* ((json (harness-json-parse body))
               (provider (plist-get json :provider)))
          (should (equal (list "deepinfra/fp8") (append (plist-get provider :only) nil)))
          (should (eq :false (plist-get provider :allow_fallbacks)))
          (should (equal "deny" (plist-get provider :data_collection)))
          (should (eq t (plist-get provider :zdr)))
          (should (equal "default" (plist-get json :service_tier)))))))))

(ert-deftest harness-provider-openrouter-transport-retry-after-is-not-slept ()
  "A Retry-After longer than the policy's seconds stops the turn at once.
The provider asks for an hour; the generic backoff caps it at a minute;
the policy allows one second.  The wait is compared with what is left
when the retry is scheduled, so the turn stops immediately and the
second attempt is never sent -- rather than sleeping a minute and
discovering the bound at the next send."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire
      (lambda (n)
        (if (= n 1)
            (list :status 429 :headers '(("Retry-After" . "3600")
                                         ("Content-Type" . "application/json"))
                  :body "{\"error\":{\"code\":429,\"message\":\"slow down\"}}")
          'answer))
    (setq harness-retry-delay 1.0)
    (setq harness-retry-max-delay 60.0)
    (setq harness-retry-max-attempts 4)
    (setq harness-retry-max-seconds 1)
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (let* ((sid (harness-openrouter-test--wire-pinned-session))
           (started (float-time))
           (result (harness-test-await (harness-call 'agent/prompt sid "go") 30)))
      (should (eq 'error (plist-get result :stop-reason)))
      (should (= 1 (harness-openrouter-test--wire-posts wire)))
      ;; It stopped instead of waiting out the provider's hour.
      (should (< (- (float-time) started) 10))
      (should (cl-some (lambda (h) (string-match-p "would start the next attempt after" h))
                       (harness-openrouter-test--wire-hints sid))))))

(ert-deftest harness-provider-openrouter-transport-first-attempt-time-counts ()
  "The time an attempt took is inside the policy's seconds.
The clock starts when the request is sent, not when it failed: an
attempt that took longer than the whole bound leaves no time for a
retry, so the turn stops after it."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire (lambda (_) 'slow-reset)
    (setq harness-retry-max-attempts 4)
    (setq harness-retry-max-seconds 1)
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (let ((sid (harness-openrouter-test--wire-pinned-session)))
      (should (eq 'error (plist-get (harness-test-await
                                     (harness-call 'agent/prompt sid "go") 30)
                                    :stop-reason)))
      (should (= 1 (harness-openrouter-test--wire-posts wire)))
      (should (cl-some (lambda (h) (string-match-p
                                    "OpenRouter: one request and its retries may take 1 s, and [0-9]+ s passed"
                                    h))
                       (harness-openrouter-test--wire-hints sid))))))

;;;; A retry repeats the request it was authorised for, under that policy

(ert-deftest harness-provider-openrouter-transport-changed-policy-stops-a-waiting-retry ()
  "A policy edited while a retry waits stops that retry before it is sent.
Disabling it, removing it, dropping the pinned provider, lowering the
maximum, narrowing the model and shortening the freshness bound are the
edits that decide a request; each is made after the first failure and
while the backoff waits, and each ends with exactly one POST.  The retry
is a repeat of the request that failed, so it is sent under the policy
that authorised it or not at all: a policy changed meanwhile refuses it,
and never re-selects under the new one."
  (skip-unless (executable-find "curl"))
  (dolist (edit '(disable remove drop-provider lower-limit narrow-model fresh))
    (harness-openrouter-test-with-wire (lambda (_) 'reset)
      (setq harness-retry-delay 0.4)
      (setq harness-openrouter-routing (harness-openrouter-test-policy :freshness 300))
      (let* ((sid (harness-openrouter-test--wire-pinned-session))
             (policy harness-openrouter-routing)
             (promise (harness-call 'agent/prompt sid "go")))
        (harness-openrouter-test--wire-wait-retrying sid)
        (pcase edit
          ('disable (setq harness-openrouter-routing (plist-put (copy-sequence policy)
                                                               :enabled nil)))
          ('remove (setq harness-openrouter-routing nil))
          ('drop-provider (setq harness-openrouter-routing
                                (plist-put (copy-sequence policy) :providers (list "Cohere"))))
          ('lower-limit (setq harness-openrouter-routing
                              (plist-put (copy-sequence policy) :max-price
                                         '(:prompt 0.01 :completion 0.01 :cache-read 0.0001))))
          ('narrow-model (setq harness-openrouter-routing
                               (plist-put (copy-sequence policy) :model "deepseek/deepseek-v3")))
          ('fresh (setq harness-openrouter-routing
                        (plist-put (copy-sequence policy) :freshness 0))))
        (should (eq 'error (plist-get (harness-test-await promise 30) :stop-reason)))
        (should (= 1 (harness-openrouter-test--wire-posts wire)))
        ;; The refusal says the policy that authorised the request is not
        ;; the one in force, and names the field when it is an edit.
        (should (cl-some (lambda (h) (string-match-p "routing paused (policy-changed)" h))
                         (harness-openrouter-test--wire-hints sid)))
        (should (cl-some (lambda (h) (string-match-p
                                      (if (eq edit 'remove) "not sent unrestricted" "now differ")
                                      h))
                         (harness-openrouter-test--wire-hints sid)))))))

(ert-deftest harness-provider-openrouter-transport-a-retry-repeats-its-own-endpoint ()
  "A retry goes back to the endpoint of the request that failed, not the pin.
The session is switched to the other allowed endpoint between the failed
attempt and the waiting retry -- a person's decision, made by hand -- and
the retry still goes to the endpoint that carried the request it
repeats: the request is disclosed where it was disclosed, or not at all,
and the switch starts a fresh request rather than rewiring this one.
Both POSTs are restricted to the endpoint the first one was authorised
for."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire
      (lambda (n) (if (= n 1) 'reset 'answer))
    (setq harness-retry-delay 0.4)
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (let* ((sid (harness-openrouter-test--wire-pinned-session))
           (promise (harness-call 'agent/prompt sid "go")))
      (harness-openrouter-test--wire-wait-retrying sid)
      (harness-call 'session/set-ext sid :openrouter-route
                    (plist-put (plist-put (harness-openrouter-test--route)
                                          :slug "cohere/fp8")
                               :provider "Cohere"))
      (should (eq 'end-turn (plist-get (harness-test-await promise 30) :stop-reason)))
      (should (= 2 (harness-openrouter-test--wire-posts wire)))
      (dolist (body (harness-openrouter-test--wire-bodies wire))
        (let ((provider (plist-get (harness-json-parse body) :provider)))
          (should (equal '("deepinfra/fp8") (append (plist-get provider :only) nil)))
          (should (eq :false (plist-get provider :allow_fallbacks)))))
      ;; And the pin the person made is the one the session keeps.
      (should (equal "cohere/fp8"
                     (plist-get (harness-openrouter--route-of
                                 (harness-call 'session/get sid))
                                :slug))))))

(ert-deftest harness-provider-openrouter-transport-stale-pin-is-rechecked-at-the-price ()
  "A stale pin is re-read, and a dearer cache read stops it before any POST.
The pin records a cache-read price inside the maximum, but its catalogue
reading is older than the policy allows, so the catalogue is read again
and the current price -- over the maximum -- refuses the request.  The
same pin with a maximum that covers the current price is sent, so the
refusal is the price and not the refresh."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire (lambda (_) 'answer)
    ;; The recorded price is under the limit; the catalogue's is 0.00294.
    (let ((route (harness-openrouter-test--route
                  '(:cache-read 0.0005 :catalogue-at 0))))
      (setq harness-openrouter-routing
            (harness-openrouter-test-policy
             :freshness 1
             :max-price '(:prompt 0.15 :completion 0.60 :cache-read 0.001)))
      (let ((sid (harness-openrouter-test--wire-pinned-session route)))
        (should (eq 'error (plist-get (harness-test-await
                                       (harness-call 'agent/prompt sid "go") 30)
                                      :stop-reason)))
        (should (= 1 (harness-openrouter-test--wire-reads wire)))
        (should (= 0 (harness-openrouter-test--wire-posts wire)))
        (should (cl-some (lambda (h) (string-match-p "dearer than the maximum price" h))
                         (harness-openrouter-test--wire-hints sid)))))
    ;; The same stale pin, with a maximum that covers the current price:
    ;; it is read again and sent, so the refusal above was the price.
    (setq harness-openrouter-routing
          (harness-openrouter-test-policy
           :freshness 1
           :max-price '(:prompt 0.15 :completion 0.60 :cache-read 0.003)))
    (let* ((reads (harness-openrouter-test--wire-reads wire))
           (posts (harness-openrouter-test--wire-posts wire))
           (sid (harness-openrouter-test--wire-pinned-session
                 (harness-openrouter-test--route '(:cache-read 0.0005 :catalogue-at 0)))))
      (should (eq 'end-turn (plist-get (harness-test-await
                                        (harness-call 'agent/prompt sid "go") 30)
                                       :stop-reason)))
      (should (= (1+ reads) (harness-openrouter-test--wire-reads wire)))
      (should (= (1+ posts) (harness-openrouter-test--wire-posts wire))))))

(ert-deftest harness-provider-openrouter-transport-cancel-during-a-backoff-sends-nothing ()
  "Cancelling while a retry waits sends nothing and ends the turn once.
The first attempt failed and the retry is waiting; cancelling the turn
then stops it, and the callback the backoff would have run after it
sends nothing: one POST, one `done' event, and no more."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire (lambda (_) 'reset)
    (setq harness-retry-delay 1.0)
    (setq harness-retry-max-attempts 4)
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (let* ((sid (harness-openrouter-test--wire-pinned-session))
           (events 0)
           (promise (harness-call 'agent/prompt sid "go")))
      (harness-on 'agent/stream (lambda (&rest _) (cl-incf events)))
      (harness-on 'agent/tool-call (lambda (&rest _) (cl-incf events)))
      (harness-openrouter-test--wire-wait-retrying sid)
      (harness-call 'agent/cancel sid)
      ;; The turn ends, without the waiting retry.  A turn cancelled
      ;; while a filter is still waiting on the retry it decided ends as
      ;; the agent ends such a turn, an error; what matters here is that
      ;; the wait does not turn into a send.
      (let ((result (harness-test-await promise 30)))
        (should (memq (plist-get result :stop-reason) '(cancelled error)))
        (should (= 1 (harness-openrouter-test--wire-posts wire)))
        (let ((after events))
          ;; The backoff settles a second later; nothing may be sent or shown.
          (accept-process-output nil 1.5)
          (should (= 1 (harness-openrouter-test--wire-posts wire)))
          (should (= after events)))))))

(ert-deftest harness-provider-openrouter-transport-retry-rechecks-a-stale-pin ()
  "A retry whose pin went stale is re-read and refused at the current price.
The pin records a cache-read price inside the maximum, and its reading
is made older than the policy allows between the failed attempt and the
waiting retry.  The retry reads the catalogue again, finds the current
cache-read price over the lowered maximum, and sends nothing: one POST,
one catalogue read, and the refusal names the component."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire (lambda (_) 'reset)
    (setq harness-retry-delay 0.4)
    ;; The reading is fresh when the request goes out and stale when it
    ;; waits to be repeated, which is what makes the retry read again.
    (setq harness-openrouter-routing
          (harness-openrouter-test-policy
           :freshness 0.2
           :max-price '(:prompt 0.15 :completion 0.60 :cache-read 0.001)))
    (let* ((sid (harness-openrouter-test--wire-pinned-session
                 (harness-openrouter-test--route '(:cache-read 0.0005))))
           (promise (harness-call 'agent/prompt sid "go")))
      (harness-openrouter-test--wire-wait-retrying sid)
      ;; The reading the request was authorised at is no longer evidence of
      ;; its price, so the retry reads the catalogue again -- and the price
      ;; it finds (cache read 0.00294) is over the maximum that authorised
      ;; the request (0.001), so nothing is sent.  The policy in force is
      ;; the one that authorised it, unchanged: the refusal is the price.
      (should (eq 'error (plist-get (harness-test-await promise 30) :stop-reason)))
      (should (= 1 (harness-openrouter-test--wire-posts wire)))
      (should (= 1 (harness-openrouter-test--wire-reads wire)))
      (should (cl-some (lambda (h) (string-match-p "dearer than the maximum price.*cache-read 0.00294 > 0.001" h))
                       (harness-openrouter-test--wire-hints sid))))))

;;;; A failure OpenRouter's own fields say no identical request passes

(ert-deftest harness-provider-openrouter-transport-a-typed-rejection-is-not-repeated ()
  "An HTTP 400 carries its typed code, and the turn stops without a second POST.
OpenRouter names the reason in `error.metadata.error_type' and the
module appends it to the message (`invalid_request').  The dialect hook
reads it as the shared kind `permanent', so the shared retry layer ends
the turn at once: one POST, one catalogue read, and a hint that says an
identical retry cannot pass it.  Retrying the identical request would
only spend again."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire
      (lambda (_)
        (list :status 400 :headers '(("Content-Type" . "application/json"))
              :body (harness-json-encode
                     '(:error (:code 400
                               :message "Upstream error from OpenInference: Upstream returned HTTP 400"
                               :metadata (:error_type "invalid_request"
                                          :provider_name "OpenInference"))
                       :id "gen-400"))))
    ;; A handler after the shared one that would retry anything.
    (harness-add-filter 'agent/step-error
                        (lambda (_v next &rest _) (funcall next (list :retry t))) 90)
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (let ((sid (harness-openrouter-test--wire-pinned-session)))
      (should (eq 'error (plist-get (harness-test-await
                                     (harness-call 'agent/prompt sid "go") 30)
                                    :stop-reason)))
      (should (= 1 (harness-openrouter-test--wire-posts wire)))
      (should (cl-some (lambda (h) (string-match-p "identical retry cannot pass it" h))
                       (harness-openrouter-test--wire-hints sid))))))

(ert-deftest harness-provider-openrouter-transport-a-typed-transient-code-is-tried ()
  "A typed transient code is a repeat's to pass, and the shared layer decides.
A 503 whose body names `provider_unavailable' is one attempt's bad
minute: the shared bounds allow one retry, and the second POST is the
same pinned endpoint with the same restriction."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire
      (lambda (n)
        (if (= n 1)
            (list :status 503 :headers '(("Content-Type" . "application/json"))
                  :body (harness-json-encode
                         '(:error (:code 503 :message "busy"
                                   :metadata (:error_type "provider_unavailable")))))
          'answer))
    (let ((harness-retry-max-attempts 1))
      (setq harness-openrouter-routing (harness-openrouter-test-policy))
      (let ((sid (harness-openrouter-test--wire-pinned-session)))
        (should (eq 'end-turn (plist-get (harness-test-await
                                          (harness-call 'agent/prompt sid "go") 30)
                                         :stop-reason)))
        (should (= 2 (harness-openrouter-test--wire-posts wire)))
        (dolist (body (harness-openrouter-test--wire-bodies wire))
          (let* ((json (harness-json-parse body))
                 (provider (plist-get json :provider)))
            (should (equal (list "deepinfra/fp8") (append (plist-get provider :only) nil)))
            (should (eq :false (plist-get provider :allow_fallbacks)))))))))

;;;; What must not change

(ert-deftest harness-provider-openrouter-transport-plain-openai-still-retries ()
  "A plain OpenAI endpoint is still replayed by the transport itself.
It has no dialect and no policy, so `harness-http-request' keeps its
default: a reset before any of the answer arrived is tried again, and
the second attempt answers.  Two POSTs, one answer."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire
      (lambda (n) (if (= n 1) 'reset 'answer))
    (let* ((endpoint (list :id 'plain :label "Plain" :base-url url
                           :api-key "test-key" :models '("m")))
           (events (harness-openrouter-test--complete*
                    endpoint (list :model "plain:m" :session (list :id "s-plain")
                                   :messages '((:role user :content "hi"))))))
      (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
      (should (= 2 (harness-openrouter-test--wire-posts wire))))))

(ert-deftest harness-provider-openrouter-transport-ungoverned-openrouter-still-retries ()
  "OpenRouter without a policy is still the provider it always was.
No policy is configured, so the request is not governed: the transport
replays the reset request as it does for any other endpoint, and the
second attempt answers."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire
      (lambda (n) (if (= n 1) 'reset 'answer))
    (let* ((events (harness-openrouter-test--complete*
                    (harness-openrouter--endpoint)
                    (list :model (format "openrouter:%s" harness-openrouter-test-model)
                          :session (list :id "s-plain")
                          :messages '((:role user :content "hi"))))))
      (should (eq 'end-turn (plist-get (car (last events)) :stop-reason)))
      (should (= 2 (harness-openrouter-test--wire-posts wire)))
      ;; And it sent no provider restriction, as before the policy existed.
      (let ((body (harness-json-parse (car (harness-openrouter-test--wire-bodies wire)))))
        (should-not (plist-get body :provider))
        (should-not (plist-get body :service_tier))))))

;;;; A request's restrictions and its budget belong to the request

(defun harness-openrouter-test--wire-small-call (sid &rest opts)
  "Ask one of the harness's small calls for SID over the wire; return its promise.
The call is a recap's shape: the pinned session, a prompt from the
registry and a short output budget.  It settles with the last `done'
event and the text gathered before it, and every event it was handed."
  (let ((text "") (events nil) (promise (harness-make-promise)))
    (harness-small-ask
     (list :model (format "openrouter:%s" harness-openrouter-test-model)
           :session (harness-call 'session/get sid)
           :ephemeral t :tools nil :no-thinking t :max-tokens 40
           :system "You write one dry line about the work so far."
           :messages (list (list :role 'user
                                 :content (list (list :type "text" :text "summarise this"))))
           :prompts '(recap-system))
     (list :label "recap"
           :on-event (lambda (ev)
                       (push ev events)
                       (pcase (plist-get ev :type)
                         ('restart (setq text ""))
                         ('text (setq text (concat text (or (plist-get ev :delta) ""))))
                         ('done (harness-resolve promise (list :event ev :text text
                                                               :events (nreverse events))))))))
    promise))

(ert-deftest harness-openrouter-transport-a-small-call-keeps-its-restrictions ()
  "A recap's retry repeats the restricted request, or stops; it never widens.
This is the reported finding: a small call has its own retry loop rather
than a step's `agent/step-error', so a policy removed while it waited was
not seen, and its second POST went out with no `provider' object at all
-- after a first one pinned to `deepinfra/fp8'.  The retry now carries
the request's own record of what authorised it, so a policy removed or
disabled while it waits refuses the repeat: exactly one POST, restricted,
and nothing sent unrestricted."
  (skip-unless (executable-find "curl"))
  (dolist (edit '(remove disable))
    (harness-openrouter-test-with-wire (lambda (n) (if (= n 1) 'reset 'answer))
      (setq harness-retry-delay 0.4)
      (setq harness-openrouter-routing (harness-openrouter-test-policy))
      (let* ((sid (harness-openrouter-test--wire-pinned-session))
             (policy harness-openrouter-routing)
             (promise (harness-openrouter-test--wire-small-call sid)))
        ;; The shared layer leaves the hint that says a retry was decided,
        ;; and that is where the edit is made: while it waits.
        (harness-test-wait (lambda ()
                             (cl-some (lambda (h) (string-match-p "trying again in" h))
                                      (harness-openrouter-test--wire-hints sid)))
                           5 "the small call's retry")
        (pcase edit
          ('remove (setq harness-openrouter-routing nil))
          ('disable (setq harness-openrouter-routing
                          (plist-put (copy-sequence policy) :enabled nil))))
        (let ((answer (harness-test-await promise 20)))
          (should (eq 'error (plist-get (plist-get answer :event) :stop-reason)))
          (should (string-match-p "routing paused (policy-changed)"
                                  (or (plist-get (plist-get answer :event) :error) "")))
          ;; One POST, and it was restricted.
          (should (= 1 (harness-openrouter-test--wire-posts wire)))
          (dolist (body (harness-openrouter-test--wire-bodies wire))
            (let ((provider (plist-get (harness-json-parse body) :provider)))
              (should (equal '("deepinfra/fp8") (append (plist-get provider :only) nil)))
              (should (eq :false (plist-get provider :allow_fallbacks)))
              (should (equal "deny" (plist-get provider :data_collection)))
              (should (eq t (plist-get provider :zdr)))
              (should (equal '(:prompt 0.15 :completion 0.6)
                             (plist-get provider :max_price))))))))))

(ert-deftest harness-openrouter-transport-a-small-call-keeps-the-elapsed-bound ()
  "A small call's retry is inside the same elapsed bound a step's is.
This is the reported finding: `harness-small' kept its own retry loop,
so the second send found no retry pending and started a fresh clock --
two POSTs and 1.14 s under a `harness-retry-max-seconds' of 0.1.  The
budget now travels with the request, so the clock that measures the
first try measures the retry too: one POST, and the stop names the
bound."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire (lambda (_) 'slow-reset)
    (let* ((harness-retry-max-seconds 0.1)
           (harness-retry-max-attempts 2)
           (harness-retry-delay 0.01)
           (harness-openrouter-routing (harness-openrouter-test-policy))
           (sid (harness-openrouter-test--wire-pinned-session))
           (started (float-time))
           (answer (harness-test-await (harness-openrouter-test--wire-small-call sid) 20)))
      (should (eq 'error (plist-get (plist-get answer :event) :stop-reason)))
      (should (= 1 (harness-openrouter-test--wire-posts wire)))
      (should (< (- (float-time) started) 5))
      ;; The bound is the shared one, and it is what stopped the repeat.
      (should (cl-some (lambda (h) (string-match-p
                                    "OpenRouter: one request and its retries may take 0.1 s, and [0-9]+ s passed"
                                    h))
                       (harness-openrouter-test--wire-hints sid)))
      ;; No hint says a retry was scheduled: none was.
      (should-not (cl-some (lambda (h) (string-match-p "trying again in" h))
                           (harness-openrouter-test--wire-hints sid))))))

(ert-deftest harness-openrouter-transport-two-requests-do-not-share-a-budget ()
  "A main step and a recap of one session are two requests, budgeted apart.
The recap is in flight beside the turn, and each carries its own count
and clock: the recap's retry neither spends the turn's attempts nor
restarts them, and the turn's retry is still its own.  Both are
restricted, and each goes to its own request's endpoint."
  (skip-unless (executable-find "curl"))
  (harness-openrouter-test-with-wire
      (lambda (n) (if (memq n '(1 2)) 'reset 'answer))
    (setq harness-retry-delay 0.4)
    (setq harness-retry-max-attempts 2)
    (setq harness-openrouter-routing (harness-openrouter-test-policy))
    (let* ((sid (harness-openrouter-test--wire-pinned-session))
           (turn (harness-call 'agent/prompt sid "go"))
           (recap (harness-openrouter-test--wire-small-call sid)))
      (harness-test-wait (lambda () (>= (harness-openrouter-test--wire-posts wire) 2))
                         10 "both requests")
      ;; A policy edit now refuses both repeats: neither request's budget
      ;; was consumed, reset or borrowed by the other to get here.
      (setq harness-openrouter-routing
            (plist-put (copy-sequence harness-openrouter-routing) :enabled nil))
      (should (eq 'error (plist-get (harness-test-await turn 20) :stop-reason)))
      (should (eq 'error (plist-get (plist-get (harness-test-await recap 20) :event)
                                    :stop-reason)))
      (should (= 2 (harness-openrouter-test--wire-posts wire)))
      (dolist (body (harness-openrouter-test--wire-bodies wire))
        (should (plist-get (plist-get (harness-json-parse body) :provider) :only))))))

(provide 'harness-provider-openrouter-transport-test)
;;; harness-provider-openrouter-transport-test.el ends here
