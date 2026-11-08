;;; harness-cache-warm-test.el --- Tests for keeping a prompt cache warm  -*- lexical-binding: t; -*-

;;; Commentary:

;; While the user is around, the cache of a session is read once more
;; just before it would lapse.  The providers here are fakes that keep the
;; requests they get: `api' is sent the whole conversation at every
;; request, `hosted' holds the conversation itself (Claude Code), and says
;; a message sent to it only keeps the cache warm; `stubborn' is a hosted
;; loop that does not say so.  A cache stamped just now lasts 300 seconds,
;; so the watcher's own event, ten seconds before the lapse, does not
;; come in the middle of a test: the tests send the event themselves.  The
;; last tests let the watcher do it, with a cache that lasts two seconds.
;; What a refresh costs against sending the conversation again comes from
;; prices the tests give (`compaction/resend-cost' is theirs): a refresh
;; of $0.30 and $3.75 for the conversation uncached, as for Claude's cache,
;; unless a test says otherwise.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-providers)
(defvar harness-cache--lead-min)
(defvar harness-cache--lead-max)
(defvar harness-cache--too-late)
(defvar harness-cache--grace-min)
(defvar harness-cache--watched)
(defvar harness-cache--fired)
(defvar harness-cache--claims)
(defvar harness-cache--presence)
(defvar harness-cache--announced)
(defvar harness-cache--ends)
(defvar harness-cache-warm)
(defvar harness-cache-warm--timeout)
(defvar harness-cache-warm--retry-delay)
(defvar harness-cache-warm--refreshing)
(defvar harness-cache-warm--counts)
(defvar harness-cache-warm--blocked)
(defvar harness-cache-warm--failures)
(defvar harness-cache-warm--published)
(defvar harness-cache-warm--capped)
(defvar harness-cache-warm--prices)
(defvar harness-cache-warm--tooling)
(defvar harness-cache-warm-message)
(defvar harness-provider-demo--delay)
(defvar harness-cache-ttl)
(defvar harness-cache-ttl-overrides)
(declare-function harness-cache-warm--on-pre-expire "harness-cache-warm" (sid info))
(declare-function harness-agent-step-request "harness-agent" (session-id state on-event))
(declare-function harness-provider--forget "harness-provider" (id))

(defvar harness-cache-warm-test--requests nil
  "The requests the fake providers got, newest first.")

(defvar harness-cache-warm-test--reply nil
  "A function of a request returning the events the fake providers answer with.")

(defvar harness-cache-warm-test--delay 0.01
  "Seconds the fake providers take to answer.")

(defvar harness-cache-warm-test--cancelled nil
  "The number of requests the fake providers were told to cancel.")

(defvar harness-cache-warm-test--changes nil
  "The `cache/warm-changed' events heard, oldest first: (SESSION-ID STATE).")

(defvar harness-cache-warm-test--budget nil
  "The reason a hard budget forbids another request, or nil.")

(defvar harness-cache-warm-test--prices '(0.30 . 3.75)
  "What reading the context from the cache costs, and sending it uncached.")

(defun harness-cache-warm-test--hit (_request)
  "Answer a refresh with the events of one that read the cache."
  '((:type usage :input 12 :output 2 :cache-read 3000 :cache-write 0 :cost 0.0012)
    (:type done :stop-reason end-turn)))

(defun harness-cache-warm-test--complete (request)
  "Answer REQUEST, kept, with `harness-cache-warm-test--reply''s events."
  (push request harness-cache-warm-test--requests)
  (let ((on-event (plist-get request :on-event))
        (events (funcall harness-cache-warm-test--reply request)))
    (when (and events harness-cache-warm-test--delay)
      (run-at-time harness-cache-warm-test--delay nil
                   (lambda () (dolist (ev events) (funcall on-event ev)))))
    (list :cancel (lambda () (cl-incf harness-cache-warm-test--cancelled)))))

(defun harness-cache-warm-test--define-providers ()
  "Define the fake providers."
  (let ((models (lambda ()
                  (harness-resolved
                   (list (list :name "m" :label "Fake M" :context-window 200000
                               :pricing '(:input 4.0 :output 20.0 :cache-read 0.4 :cache-write 5.0)))))))
    (harness-define-provider 'api :label "API" :models models
      :complete #'harness-cache-warm-test--complete)
    (harness-define-provider 'hosted :label "Hosted" :models models
      :complete #'harness-cache-warm-test--complete
      :capabilities '(:hosted-loop t :resume t :fork t :cache-refresh t))
    (harness-define-provider 'stubborn :label "Stubborn" :models models
      :complete #'harness-cache-warm-test--complete
      :capabilities '(:hosted-loop t :resume t :fork t))))

(defmacro harness-cache-warm-test-with (&rest body)
  "Run BODY with the watcher and the keep-warm module started, and fake providers.
Keeping caches warm is on, a cache lasts 300 seconds unless a stamp says
otherwise, and the fake providers answer every request as a hit."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent cache cache-warm))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-tools)
     (dolist (table (list harness-cache--watched harness-cache--fired harness-cache--claims
                          harness-cache--presence harness-cache--announced harness-cache--ends
                          harness-cache-warm--refreshing harness-cache-warm--counts
                          harness-cache-warm--blocked harness-cache-warm--failures
                          harness-cache-warm--published harness-cache-warm--capped
                          harness-cache-warm--prices harness-cache-warm--tooling))
       (clrhash table))
     (setq harness-cache-warm-test--requests nil
           harness-cache-warm-test--reply #'harness-cache-warm-test--hit
           harness-cache-warm-test--delay 0.01
           harness-cache-warm-test--cancelled 0
           harness-cache-warm-test--changes nil
           harness-cache-warm-test--budget nil
           harness-cache-warm-test--prices '(0.30 . 3.75))
     (harness-cache-warm-test--define-providers)
     (harness-register-method 'usage/budget-block (lambda (_sid) harness-cache-warm-test--budget))
     (harness-register-method 'compaction/resend-cost
                              (lambda (_sid) (list :context 3020 :cached (car harness-cache-warm-test--prices)
                                                   :uncached (cdr harness-cache-warm-test--prices))))
     (harness-add-filter 'permission/decide
                         (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
     (harness-on 'cache/warm-changed
                 (lambda (sid state)
                   (setq harness-cache-warm-test--changes
                         (append harness-cache-warm-test--changes (list (list sid state))))))
     (unwind-protect
         (let ((harness-cache-warm t)
               (harness-cache-ttl 300)
               (harness-cache-ttl-overrides nil)
               (harness-cache-warm--retry-delay 0.05)
               (default-directory dir))
           ,@body)
       (maphash (lambda (_ entry) (when (timerp (plist-get entry :timer)) (cancel-timer (plist-get entry :timer))))
                harness-cache--watched)
       (maphash (lambda (_ timer) (cancel-timer timer)) harness-cache--ends)
       (dolist (p '(api hosted stubborn))
         (remhash p harness-providers)
         (harness-provider--forget p)))))

(defun harness-cache-warm-test-session (model &optional ttl from-now)
  "Create a session on MODEL with an answered exchange and a cache stamped FROM-NOW.
The cache lasts TTL seconds (300) and was stamped FROM-NOW seconds from
now (0), by a request that read 3000 tokens of it: the context is 3020
tokens.  A hosted model holds a conversation of its own.  Return the id."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model model) :id)))
    (harness-call 'session/append sid '(:kind user :content "please refactor the parser"))
    (harness-call 'session/append sid '(:kind assistant :content "Done: parser.el rewritten"))
    (when (string-match-p "\\`\\(hosted\\|stubborn\\):" model)
      (harness-call 'session/set-provider-state sid
                    (list :conv "c1" :provider (car (split-string model ":")))))
    (harness-call 'session/usage-add sid (list :input 10 :output 10 :cache-read 3000 :context 3020
                                               :cache-at (+ (float-time) (or from-now 0))
                                               :cache-ttl (or ttl 300)))
    sid))

(defun harness-cache-warm-test--info (sid &rest overrides)
  "Return the INFO of `cache/pre-expire' for SID's cache as it is, with OVERRIDES."
  (let* ((session (harness-call 'session/get sid))
         (cache (plist-get session :cache)))
    (harness-plist-merge
     (list :expires (plist-get cache :expires) :ttl (plist-get cache :ttl) :lead 10.0
           :at (plist-get cache :at) :model (plist-get cache :model)
           :context (plist-get (plist-get session :usage) :context)
           :status 'idle :running nil)
     overrides)))

(defun harness-cache-warm-test--event (sid &rest overrides)
  "Emit `cache/pre-expire' for session SID, with INFO as OVERRIDES change it."
  (harness-emit 'cache/pre-expire sid (apply #'harness-cache-warm-test--info sid overrides)))

(defun harness-cache-warm-test--wait-idle (&optional requests)
  "Wait until no refresh is under way, and REQUESTS (1) were made."
  (harness-test-wait (lambda ()
                       (and (>= (length harness-cache-warm-test--requests) (or requests 1))
                            (zerop (hash-table-count harness-cache-warm--refreshing))))
                     5 "a refresh to end"))

(defun harness-cache-warm-test--nodes (sid)
  "Return the number of nodes in the transcript of session SID."
  (length (harness-call 'session/nodes sid)))

(defun harness-cache-warm-test--hints (sid)
  "Return the texts of the hints in the transcript of session SID."
  (delq nil (mapcar (lambda (n) (and (eq (plist-get n :kind) 'hint) (plist-get n :content)))
                    (harness-call 'session/nodes sid))))

;;;; The refresh

(ert-deftest harness-cache-warm-reads-the-cache-again-for-a-user-who-is-around ()
  "When the cache is about to lapse and the user is around, the conversation
is sent once more -- the agent's own request with a short message at the end --
the cache is stamped anew, what it cost is recorded, and nothing is written
into the transcript."
  (harness-cache-warm-test-with
    (let* ((sid (harness-cache-warm-test-session "api:m"))
           (nodes (harness-cache-warm-test--nodes sid))
           (before (plist-get (harness-call 'session/get sid) :usage))
           (expires (plist-get (plist-get (harness-call 'session/get sid) :cache) :expires)))
      (harness-call 'cache/active sid)
      (harness-cache-warm-test--event sid)
      ;; The cache is claimed at once, so that nothing else acts on it.
      (should (eq 'warm (harness-call 'cache/claimed sid)))
      (harness-cache-warm-test--wait-idle)
      (should (equal 1 (length harness-cache-warm-test--requests)))
      (let* ((request (car harness-cache-warm-test--requests))
             (step (harness-agent-step-request sid nil #'ignore))
             (messages (plist-get request :messages)))
        ;; The request the agent would make for its next step, but for
        ;; the end: the same model, system prompt, tools and thinking level
        ;; -- what a cache reads a request by -- and the conversation.
        (should (equal "api:m" (plist-get request :model)))
        (should (equal (plist-get step :system) (plist-get request :system)))
        (should (equal (plist-get step :tools) (plist-get request :tools)))
        (should (equal (plist-get step :thinking) (plist-get request :thinking)))
        (should (equal (butlast messages) (plist-get step :messages)))
        (let ((ping (car (last messages))))
          (should (eq 'user (plist-get ping :role)))
          (should (equal harness-cache-warm-message (plist-get (car (plist-get ping :content)) :text))))
        (should (= 16 (plist-get request :max-tokens)))
        (should (eq t (plist-get request :cache-refresh)))
        (should (equal sid (plist-get (plist-get request :session) :id))))
      ;; The cache was read: its lapse moved on, by the whole lifetime.
      (let ((cache (plist-get (harness-call 'session/get sid) :cache)))
        (should (> (plist-get cache :expires) expires))
        (should (= 300 (plist-get cache :ttl))))
      ;; The cost is the session's, the context is not touched.
      (let ((usage (plist-get (harness-call 'session/get sid) :usage)))
        (should (= 6000 (plist-get usage :cache-read)))
        (should (= 22 (plist-get usage :input)))
        (should (= (plist-get before :context) (plist-get usage :context)))
        (should (= 0.0012 (- (plist-get usage :cost) (or (plist-get before :cost) 0)))))
      ;; Nothing is written into the conversation.
      (should (= nodes (harness-cache-warm-test--nodes sid)))
      (should-not (harness-cache-warm-test--hints sid))
      ;; The refresh was counted, and said.
      (let ((state (harness-call 'cache/warm sid)))
        (should (eq t (plist-get state :warming)))
        (should (= 1 (plist-get state :refreshes))))
      ;; The claim was for the lapse it was made for.
      (should-not (harness-call 'cache/claimed sid)))))

(ert-deftest harness-cache-warm-the-new-stamp-sets-the-watcher-for-the-next-lapse ()
  "A refresh stamps the cache, and the watcher is set for the lapse after it:
that is what makes the chain go on, a refresh at every lapse, until the user
is gone."
  (harness-cache-warm-test-with
    (let ((sid (harness-cache-warm-test-session "api:m" 300 -200)))
      (harness-call 'cache/active sid)
      (let ((first (plist-get (harness-call 'cache/watching sid) :expires)))
        (harness-cache-warm-test--event sid)
        (harness-cache-warm-test--wait-idle)
        (let ((next (harness-call 'cache/watching sid)))
          (should (> (plist-get next :expires) first))
          (should (= (- (plist-get next :expires) 10.0) (plist-get next :fire-at))))))))

(ert-deftest harness-cache-warm-leaves-a-user-who-is-gone-alone ()
  "With no sign of life, or one older than the warm period, the cache is left
to lapse; so it is when keeping caches warm is off."
  (harness-cache-warm-test-with
    (let ((sid (harness-cache-warm-test-session "api:m")))
      ;; Never a sign of life.
      (harness-cache-warm-test--event sid)
      (should-not harness-cache-warm-test--requests)
      (should-not (harness-call 'cache/claimed sid))
      ;; One that is over.
      (harness-call 'cache/active sid)
      (cl-letf (((symbol-function 'harness-cache-around-p) (lambda (&rest _) nil)))
        (harness-cache-warm-test--event sid))
      (should-not harness-cache-warm-test--requests)
      ;; Off.
      (let ((harness-cache-warm nil))
        (harness-cache-warm-test--event sid)
        (should-not harness-cache-warm-test--requests)
        (should (eq :false (plist-get (harness-call 'cache/warm sid) :warming))))
      ;; On again.
      (harness-cache-warm-test--event sid)
      (harness-cache-warm-test--wait-idle))))

(ert-deftest harness-cache-warm-leaves-a-session-that-is-busy-alone ()
  "A session running a turn uses its cache itself, one that is not idle or one
a refresh is under way for is left to it, and so is one that records a call."
  (harness-cache-warm-test-with
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'cache/active sid)
      (harness-cache-warm-test--event sid :running t)
      (harness-call 'session/set-status sid 'inactive)
      (harness-cache-warm-test--event sid)
      (harness-call 'session/set-status sid 'idle)
      (puthash sid (list :promise (harness-make-promise) :started (float-time)) harness-cache-warm--refreshing)
      (harness-cache-warm-test--event sid)
      (remhash sid harness-cache-warm--refreshing)
      (should-not harness-cache-warm-test--requests)
      (harness-cache-warm-test--event sid)
      (harness-cache-warm-test--wait-idle))))

(ert-deftest harness-cache-warm-does-not-spend-past-a-hard-budget ()
  "A refresh is a request like any other: a hard budget that is spent forbids it."
  (harness-cache-warm-test-with
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'cache/active sid)
      (setq harness-cache-warm-test--budget "Budget all exhausted: spent $5.00 of $5.00")
      (harness-cache-warm-test--event sid)
      (should-not harness-cache-warm-test--requests)
      (should-not (harness-call 'cache/claimed sid))
      (setq harness-cache-warm-test--budget nil)
      (harness-cache-warm-test--event sid)
      (harness-cache-warm-test--wait-idle))))

;;;; Providers that hold the conversation

(ert-deftest harness-cache-warm-sends-a-hosted-loop-the-short-message-alone ()
  "A provider that holds the conversation itself is sent the short message
alone, with the provider state the session carries, and told it is a refresh;
the rest of the request is the agent's."
  (harness-cache-warm-test-with
    (let ((sid (harness-cache-warm-test-session "hosted:m")))
      (harness-call 'cache/active sid)
      (should (eq t (plist-get (harness-call 'cache/warm sid) :supported)))
      (harness-cache-warm-test--event sid)
      (harness-cache-warm-test--wait-idle)
      (let ((request (car harness-cache-warm-test--requests))
            (step (harness-agent-step-request sid (harness-call 'session/provider-state sid "hosted:m") #'ignore)))
        (should (equal 1 (length (plist-get request :messages))))
        (should (equal harness-cache-warm-message
                       (plist-get (car (plist-get (car (plist-get request :messages)) :content)) :text)))
        (should (equal '(:conv "c1" :provider "hosted") (plist-get request :provider-state)))
        (should (equal (plist-get step :system) (plist-get request :system)))
        (should (eq t (plist-get request :cache-refresh)))))))

(ert-deftest harness-cache-warm-leaves-a-hosted-loop-that-does-not-say-it-can-alone ()
  "A hosted loop whose capabilities do not say a message sent to it only keeps
the cache warm is left alone, and the state says it cannot be kept warm."
  (harness-cache-warm-test-with
    (let ((sid (harness-cache-warm-test-session "stubborn:m")))
      (harness-call 'cache/active sid)
      (harness-cache-warm-test--event sid)
      (should-not harness-cache-warm-test--requests)
      (let ((state (harness-call 'cache/warm sid)))
        (should (eq :false (plist-get state :supported)))
        (should (eq :false (plist-get state :warming)))))))

(ert-deftest harness-cache-warm-needs-the-conversation-of-a-hosted-loop ()
  "A hosted loop that holds none of the session's conversation would start one,
which no cache has: it is not asked."
  (harness-cache-warm-test-with
    (let ((sid (harness-cache-warm-test-session "hosted:m")))
      (harness-call 'session/set-provider-state sid nil)
      (harness-call 'cache/active sid)
      (harness-cache-warm-test--event sid)
      (should-not harness-cache-warm-test--requests))))

;;;; When a refresh does not go well

(ert-deftest harness-cache-warm-stops-when-the-cache-was-not-read ()
  "A refresh that wrote the cache instead of reading it would do so at every
lapse for nothing: keeping the session warm stops, the transcript says why, the
state says so, and no more refreshes come until the user asks for a period."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--reply
          (lambda (_) '((:type usage :input 12 :output 2 :cache-read 0 :cache-write 3000 :cost 0.015)
                        (:type done :stop-reason end-turn))))
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'cache/active sid)
      (harness-cache-warm-test--event sid)
      (harness-cache-warm-test--wait-idle)
      (let ((state (harness-call 'cache/warm sid)))
        (should (eq :false (plist-get state :warming)))
        (should (string-match-p "did not read" (plist-get state :blocked))))
      (let ((hints (harness-cache-warm-test--hints sid)))
        (should (equal 1 (length hints)))
        (should (string-prefix-p "Stopped keeping the prompt cache warm: " (car hints))))
      ;; Not again, however many lapses.
      (harness-cache-warm-test--event sid)
      (harness-cache-warm-test--event sid)
      (should (equal 1 (length harness-cache-warm-test--requests)))
      ;; Asking for a period tries again.
      (setq harness-cache-warm-test--reply #'harness-cache-warm-test--hit)
      (let ((state (harness-call 'cache/keep-warm sid 600)))
        (should-not (plist-get state :blocked))
        (should (eq t (plist-get state :warming))))
      (harness-cache-warm-test--event sid)
      (harness-cache-warm-test--wait-idle 2))))

(ert-deftest harness-cache-warm-does-not-drop-the-stamp-of-a-request-without-cache ()
  "A refresh whose usage shows no cache at all stops the warming, but does not
take the cache stamp away: that is not its to drop.  Its cost is recorded."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--reply
          (lambda (_) '((:type usage :input 3000 :output 2 :cache-read 0 :cache-write 0 :cost 0.012)
                        (:type done :stop-reason end-turn))))
    (let* ((sid (harness-cache-warm-test-session "api:m"))
           (cache (plist-get (harness-call 'session/get sid) :cache))
           (cost (or (plist-get (plist-get (harness-call 'session/get sid) :usage) :cost) 0)))
      (harness-call 'cache/active sid)
      (harness-cache-warm-test--event sid)
      (harness-cache-warm-test--wait-idle)
      (should (equal cache (plist-get (harness-call 'session/get sid) :cache)))
      (should (= 0.012 (- (plist-get (plist-get (harness-call 'session/get sid) :usage) :cost) cost)))
      (should (plist-get (harness-call 'cache/warm sid) :blocked)))))

(ert-deftest harness-cache-warm-tries-a-refresh-that-failed-again ()
  "A refresh that fails is tried again while the cache lasts, three times at most;
a failure that goes on is said once in the transcript, not at every lapse."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--reply
          (lambda (_) '((:type done :stop-reason error :error "overloaded"))))
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'cache/active sid)
      (harness-cache-warm-test--event sid)
      (harness-cache-warm-test--wait-idle 3)
      (harness-test-wait (lambda () (harness-cache-warm-test--hints sid)) 5 "the failure to be said")
      (should (equal 3 (length harness-cache-warm-test--requests)))
      (should (equal '("Could not keep the prompt cache warm: overloaded")
                     (harness-cache-warm-test--hints sid)))
      ;; Not blocked: the next lapse tries again, without saying it again.
      (should-not (plist-get (harness-call 'cache/warm sid) :blocked))
      (setq harness-cache-warm-test--requests nil)
      (harness-cache-warm-test--event sid)
      (harness-cache-warm-test--wait-idle 3)
      (sit-for 0.2)
      (should (equal 1 (length (harness-cache-warm-test--hints sid)))))))

(ert-deftest harness-cache-warm-succeeds-on-a-retry ()
  "A refresh that fails once and then reads the cache counts as one."
  (harness-cache-warm-test-with
    (let ((attempts 0))
      (setq harness-cache-warm-test--reply
            (lambda (request)
              (if (= 1 (cl-incf attempts))
                  '((:type done :stop-reason error :error "reset by peer"))
                (harness-cache-warm-test--hit request))))
      (let ((sid (harness-cache-warm-test-session "api:m")))
        (harness-call 'cache/active sid)
        (harness-cache-warm-test--event sid)
        (harness-cache-warm-test--wait-idle 2)
        (harness-test-wait (lambda () (eql 1 (plist-get (harness-call 'cache/warm sid) :refreshes))) 5
                           "the refresh to count")
        (should-not (harness-cache-warm-test--hints sid))))))

(ert-deftest harness-cache-warm-gives-up-on-a-refresh-that-takes-too-long ()
  "A provider that never answers is told to stop after a while, and the
refresh ends as a failure."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--reply (lambda (_) nil))
    (let ((harness-cache-warm--timeout 0.2)
          (sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'cache/active sid)
      (harness-cache-warm-test--event sid)
      (harness-test-wait (lambda () (>= harness-cache-warm-test--cancelled 1)) 5 "the cancel")
      (harness-test-wait (lambda () (zerop (hash-table-count harness-cache-warm--refreshing))) 5
                         "the refresh to end")
      (should (>= (length harness-cache-warm-test--requests) 1)))))

(ert-deftest harness-cache-warm-does-not-run-a-tool-the-model-asks-for ()
  "Whatever the model answers a refresh with, no tool is run: the request is
cancelled and the refresh fails."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--reply
          (lambda (_) '((:type tool-call :id "t1" :name "bash" :input (:command "rm -rf /")))))
    (let ((sid (harness-cache-warm-test-session "api:m"))
          (harness-cache-warm--retry-delay 30))
      (harness-call 'cache/active sid)
      (harness-cache-warm-test--event sid)
      (harness-test-wait (lambda () (>= harness-cache-warm-test--cancelled 1)) 5 "the cancel")
      (should-not (cl-find 'tool (harness-call 'session/nodes sid) :key (lambda (n) (plist-get n :kind)))))))

(ert-deftest harness-cache-warm-waits-for-the-switch-of-model ()
  "A block lasts as long as the cache it was about: switching models ends it."
  (harness-cache-warm-test-with
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (puthash sid "it stopped" harness-cache-warm--blocked)
      (harness-call 'session/update sid :model "hosted:m" :silent t)
      (should-not (gethash sid harness-cache-warm--blocked)))))

;;;; A user's message

(ert-deftest harness-cache-warm-holds-a-turn-while-a-refresh-is-under-way ()
  "A message the user sends while the cache is being read again waits for it:
a provider that holds the conversation in a process would take the message
for the refresh's own."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--delay 0.4)
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'cache/active sid)
      (harness-cache-warm-test--event sid)
      (let ((gate (harness-run-filter-async 'agent/before-turn (list :proceed t :message '(:text "hi"))
                                            (harness-call 'session/get sid))))
        (should-not (harness-promise-settled-p gate))
        (harness-test-wait (lambda () (harness-promise-settled-p gate)) 5 "the turn to go on")
        (should (plist-get (harness-promise-value gate) :proceed))
        (should (zerop (hash-table-count harness-cache-warm--refreshing))))
      ;; With none under way, nothing waits.
      (let ((gate (harness-run-filter-async 'agent/before-turn (list :proceed t :message '(:text "hi"))
                                            (harness-call 'session/get sid))))
        (should (harness-promise-settled-p gate))))))

;;;; The state

(ert-deftest harness-cache-warm-says-whether-the-cache-is-being-kept-warm ()
  "The state of a session's period says whether its cache is being kept alive,
until when, the next refresh and how many were made; it is announced when it
changes and nil once the period is over."
  (harness-cache-warm-test-with
    (let ((harness-cache--grace-min 0.2))
      (let ((sid (harness-cache-warm-test-session "api:m" 1.0 0)))
        (should-not (harness-call 'cache/warm sid))
        (should-not (harness-call 'cache/warm-list))
        (let ((state (harness-call 'cache/active sid)))
          (should (plist-get state :around)))
        (let ((state (harness-call 'cache/warm sid)))
          (should (eq t (plist-get state :warming)))
          (should (eq t (plist-get state :supported)))
          (should (= 0 (plist-get state :refreshes)))
          (should (= 1.0 (plist-get state :ttl)))
          (should (= (plist-get state :expires) (+ (plist-get state :next) (harness-cache-lead 1.0))))
          (should (> (plist-get state :until) (float-time))))
        (should (equal (list sid) (mapcar (lambda (s) (plist-get s :session-id)) (harness-call 'cache/warm-list))))
        ;; Announced once, with the state.
        (should (equal sid (car (car harness-cache-warm-test--changes))))
        (should (eq t (plist-get (cadr (car harness-cache-warm-test--changes)) :warming)))
        ;; The period ends by itself.
        (harness-test-wait (lambda () (null (cadr (car (last harness-cache-warm-test--changes))))) 5
                           "the end of the period")
        (should-not (harness-call 'cache/warm sid))
        (should-not (harness-call 'cache/warm-list))))))

(ert-deftest harness-cache-warm-does-not-say-it-keeps-a-cache-that-is-gone-warm ()
  "A user is around, but there is no cache to keep warm: the session has not
used one, or it lapsed, or a compaction took it away."
  (harness-cache-warm-test-with
    (let ((fresh (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "api:m") :id))
          (lapsed (harness-cache-warm-test-session "api:m" 300 -400))
          (compacted (harness-cache-warm-test-session "api:m")))
      (harness-call 'session/usage-add compacted (list :context 100 :cache-reset t))
      (dolist (sid (list fresh lapsed compacted))
        (let ((state (harness-call 'cache/active sid)))
          (should (plist-get state :around)))
        (let ((state (harness-call 'cache/warm sid)))
          (should (eq :false (plist-get state :warming)))
          (should-not (plist-get state :next)))))))

(ert-deftest harness-cache-warm-announces-only-what-changed ()
  "Signs of life that come often announce nothing while the end of the period
has hardly moved, and a refresh announces the count."
  (harness-cache-warm-test-with
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'cache/active sid)
      (let ((n (length harness-cache-warm-test--changes)))
        (should (>= n 1))
        (harness-call 'cache/active sid)
        (harness-call 'cache/active sid)
        (should (= n (length harness-cache-warm-test--changes)))
        (harness-cache-warm-test--event sid)
        (harness-cache-warm-test--wait-idle)
        (should (> (length harness-cache-warm-test--changes) n))
        (should (= 1 (plist-get (cadr (car (last harness-cache-warm-test--changes))) :refreshes)))))))

(ert-deftest harness-cache-warm-keeps-a-period-the-user-asked-for ()
  "A period asked for by hand holds without any other sign of life: the cache is
kept warm until it ends, then left to lapse.  0 takes it away."
  (harness-cache-warm-test-with
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (let ((state (harness-call 'cache/keep-warm sid 1800)))
        (should (eq t (plist-get state :warming)))
        (should (< (abs (- 1800.0 (- (plist-get state :manual-until) (float-time)))) 2))
        (should (>= (- (plist-get state :until) (float-time)) 1799)))
      (let ((state (harness-call 'cache/keep-warm sid 0)))
        (should-not (plist-get state :manual-until))
        (should (< (- (plist-get state :until) (float-time)) 400)))
      ;; Over wires seconds are numbers or text; a session that is gone has no state.
      (should (plist-get (harness-call 'cache/keep-warm sid "600") :manual-until))
      (should-not (harness-call 'cache/keep-warm "no-such-session" 600)))))

(ert-deftest harness-cache-warm-forgets-a-session-that-is-deleted ()
  "Deleting a session takes what is kept of it away, and says its period is over."
  (harness-cache-warm-test-with
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'cache/active sid)
      (puthash sid "stopped" harness-cache-warm--blocked)
      (puthash sid 2 harness-cache-warm--counts)
      (harness-call 'session/delete sid)
      (dolist (table (list harness-cache-warm--blocked harness-cache-warm--counts harness-cache-warm--published))
        (should-not (gethash sid table)))
      (should (equal (list sid nil) (car (last harness-cache-warm-test--changes)))))))

;;;; Costs against sending the conversation again

(defun harness-cache-warm-test--refresh-n (sid n)
  "Make N refreshes of session SID, one after the other, each at its lapse."
  (dotimes (i n)
    (setq harness-cache-warm-test--requests nil)
    (harness-cache-warm-test--event sid)
    (harness-test-wait (lambda () (eql (1+ i) (gethash sid harness-cache-warm--counts 0))) 5
                       (format "refresh %d to count" (1+ i)))
    (harness-cache-warm-test--wait-idle)))

(ert-deftest harness-cache-warm-stops-when-it-costs-as-much-as-sending-it-again ()
  "Refreshes are made while they cost less than the conversation sent uncached.
At $1 a refresh and $2.50 for the conversation, two of them (Claude's cache,
read at a tenth of the input price and written at 1.25 times it, is 12;
one that reads at half price, two); then the cache is left to lapse, the
state and the transcript say why, and nothing more is sent."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--prices '(1.0 . 2.5))
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'cache/active sid 3600)
      (let ((state (harness-call 'cache/warm sid)))
        (should (= 2 (plist-get state :max-refreshes)))
        (should (= 1.0 (plist-get state :refresh-cost)))
        (should (= 2.5 (plist-get state :resend-cost)))
        (should (eq t (plist-get state :warming))))
      (harness-cache-warm-test--refresh-n sid 2)
      (should-not (harness-cache-warm-test--hints sid))
      ;; The third lapse is left alone.
      (setq harness-cache-warm-test--requests nil)
      (harness-cache-warm-test--event sid)
      (should-not harness-cache-warm-test--requests)
      (let ((state (harness-call 'cache/warm sid)))
        (should (eq :false (plist-get state :warming)))
        (should (= 2 (plist-get state :refreshes)))
        (should (string-match-p "after 2 refreshes (~\\$1\\.00 each)" (plist-get state :blocked))))
      (let ((hints (harness-cache-warm-test--hints sid)))
        (should (equal 1 (length hints)))
        (should (string-match-p "\\`Stopped keeping the prompt cache warm: after 2 refreshes (~\\$1\\.00 each) keeping it warm costs about what sending the conversation again, uncached, does (~\\$2\\.50): the cache is left to lapse\\'"
                                (car hints))))
      ;; Not said again at the lapses after.
      (harness-cache-warm-test--event sid)
      (harness-cache-warm-test--event sid)
      (should-not harness-cache-warm-test--requests)
      (should (equal 1 (length (harness-cache-warm-test--hints sid)))))))

(ert-deftest harness-cache-warm-a-request-of-the-conversations-own-starts-the-count-afresh ()
  "The count is of refreshes since the last request the conversation made
itself; one that does starts it afresh, and the cache is kept warm again."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--prices '(1.0 . 2.5))
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'cache/active sid 3600)
      (harness-cache-warm-test--refresh-n sid 2)
      (harness-cache-warm-test--event sid)
      (should (gethash sid harness-cache-warm--capped))
      ;; The user's message: a request of its own.
      (harness-call 'session/usage-add sid (list :input 30 :output 5 :cache-read 3000 :context 3040
                                                 :cache-at (float-time) :cache-ttl 300))
      (should-not (gethash sid harness-cache-warm--capped))
      (should (= 0 (plist-get (harness-call 'cache/warm sid) :refreshes)))
      (setq harness-cache-warm-test--requests nil)
      (harness-cache-warm-test--event sid)
      (harness-cache-warm-test--wait-idle)
      (should (= 1 (plist-get (harness-call 'cache/warm sid) :refreshes))))))

(ert-deftest harness-cache-warm-the-refreshes-that-pay-end-the-period ()
  "The end of the period is the user's, or that of the refreshes that pay,
whichever is first: a user around for hours, a cache that pays twice."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--prices '(1.0 . 2.5))
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (let ((state (harness-call 'cache/keep-warm sid 7200)))
        ;; Two refreshes: the one at the lapse, and the one after it.
        (should (< (abs (- (plist-get state :until)
                           (+ (plist-get state :expires) (- 300 10.0))))
                   1))
        (should (< (plist-get state :until) (+ (float-time) 7200)))
        (should (= 7200 (round (- (plist-get state :manual-until) (float-time)))))))))

(ert-deftest harness-cache-warm-does-not-keep-a-cache-that-saves-nothing ()
  "A cache that reads for as much as the conversation costs uncached is not
worth keeping, however long the user is around; and says nothing of it."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--prices '(2.5 . 2.5))
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'cache/active sid)
      (harness-cache-warm-test--event sid)
      (should-not harness-cache-warm-test--requests)
      (should-not (harness-cache-warm-test--hints sid))
      (should (eq :false (plist-get (harness-call 'cache/warm sid) :warming)))
      (should (= 0 (plist-get (harness-call 'cache/warm sid) :max-refreshes))))))

(ert-deftest harness-cache-warm-counts-twelve-where-the-catalogue-has-no-price ()
  "Without prices the Claude ratio is assumed: 12 refreshes."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--prices '(nil . nil))
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'cache/active sid)
      (let ((state (harness-call 'cache/warm sid)))
        (should (= 12 (plist-get state :max-refreshes)))
        (should-not (plist-get state :refresh-cost))
        (should (eq t (plist-get state :warming)))))))

;;;; A turn that waits on a tool

(defun harness-cache-warm-test--tool-turn (sid &optional from)
  "Start a turn in SID whose model calls the slow tool; return the function that ends it.
The turn waits on the tool until that function is called.  FROM is who sent
the message, nil for the user."
  (let ((finish nil) (steps 0))
    (harness-define-tool "slow" :label "Slow job" :description "slow" :kind 'exec
                         :handler (lambda (_input _ctx)
                                    (harness-with-promise (resolve reject)
                                      (ignore reject)
                                      (setq finish (lambda () (funcall resolve "done"))))))
    (setq harness-cache-warm-test--reply
          (lambda (request)
            (cond ((plist-get request :cache-refresh) (harness-cache-warm-test--hit request))
                  ((= 1 (cl-incf steps))
                   (list '(:type tool-call :id "t1" :name "slow" :input (:what "smoke"))
                         (list :type 'usage :input 20 :output 5 :cache-read 3000 :cache-write 0
                               :context 3040 :cache-at (float-time) :cache-ttl 300)
                         '(:type done :stop-reason tool-use)))
                  (t '((:type text :delta "all good")
                       (:type usage :input 20 :output 5 :cache-read 3040 :context 3070)
                       (:type done :stop-reason end-turn))))))
    (let ((turn (harness-call 'agent/prompt sid "run the smoke test" (and from (list :from from)))))
      (harness-test-wait (lambda () (and finish (eq 'tool (plist-get (harness-call 'agent/activity sid) :phase))))
                         5 "the tool to run")
      (lambda () (funcall finish) (harness-test-await turn 10)))))

(ert-deftest harness-cache-warm-keeps-the-cache-warm-while-a-tool-runs ()
  "A turn that waits on a long tool lets its cache lapse as surely as a user who
is away: the request of its latest step is sent again, which reads the cache
that step wrote, whoever is around.  The state says the turn waits on a tool,
and nothing is written into the transcript."
  (harness-cache-warm-test-with
    (let* ((sid (harness-cache-warm-test-session "api:m"))
           (end (harness-cache-warm-test--tool-turn sid (harness-sender-system "tasks"))))
      (should-not (harness-cache-around-p sid))
      (should (harness-cache-warm--tool-wait-p sid))
      (let ((state (harness-call 'cache/warm sid)))
        (should (eq t (plist-get state :tool)))
        (should (eq t (plist-get state :warming)))
        (should (> (plist-get state :until) (float-time))))
      (let ((step (car harness-cache-warm-test--requests))
            (nodes (harness-cache-warm-test--nodes sid)))
        (setq harness-cache-warm-test--requests nil)
        (harness-cache-warm-test--event sid :running t)
        (harness-cache-warm-test--wait-idle)
        (let ((refresh (car harness-cache-warm-test--requests)))
          (should (eq t (plist-get refresh :cache-refresh)))
          ;; The step's own request, to the letter, but for the end of it.
          (should (equal (plist-get step :messages) (plist-get refresh :messages)))
          (should (equal (plist-get step :system) (plist-get refresh :system)))
          (should (equal (plist-get step :tools) (plist-get refresh :tools)))
          (should (equal (plist-get step :model) (plist-get refresh :model)))
          (should (= 16 (plist-get refresh :max-tokens))))
        (should (= nodes (harness-cache-warm-test--nodes sid))))
      (should (= 1 (plist-get (harness-call 'cache/warm sid) :refreshes)))
      (funcall end)
      ;; The turn is over; its own request began the count afresh.
      (should (= 0 (plist-get (or (harness-call 'cache/warm sid) '(:refreshes 0)) :refreshes))))))

(ert-deftest harness-cache-warm-leaves-a-turn-alone-while-its-model-works ()
  "The turn's own request uses the cache while its model thinks and writes."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--reply (lambda (_) nil))
    (let ((sid (harness-cache-warm-test-session "api:m")))
      (harness-call 'agent/prompt sid "think about it" (list :from (harness-sender-system "tasks")))
      (harness-test-wait (lambda () (and harness-cache-warm-test--requests (harness-call 'agent/running sid))) 5
                         "the turn to wait for its model")
      (should-not (harness-cache-warm--tool-wait-p sid))
      (setq harness-cache-warm-test--requests nil)
      (harness-cache-warm-test--event sid :running t)
      (should-not harness-cache-warm-test--requests)
      (harness-call 'agent/cancel sid))))

(ert-deftest harness-cache-warm-keeps-a-cache-for-a-tool-only-for-what-it-saves ()
  "A tool that runs for hours is not worth it: the refreshes stop at the cost of
sending the conversation again, and the cache lapses.  The turn goes on all
the same."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--prices '(1.0 . 2.5))
    (let* ((sid (harness-cache-warm-test-session "api:m"))
           (end (harness-cache-warm-test--tool-turn sid (harness-sender-system "tasks"))))
      (harness-cache-warm-test--refresh-n sid 2)
      (setq harness-cache-warm-test--requests nil)
      (harness-cache-warm-test--event sid :running t)
      (should-not harness-cache-warm-test--requests)
      (should (cl-some (lambda (h) (string-prefix-p "Stopped keeping the prompt cache warm: after 2 refreshes" h))
                       (harness-cache-warm-test--hints sid)))
      (should (eq :false (plist-get (harness-call 'cache/warm sid) :warming)))
      (funcall end)
      (should (equal "all good"
                     (plist-get (car (last (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'assistant))
                                                             (harness-call 'session/nodes sid))))
                                :content))))))

(ert-deftest harness-cache-warm-keeps-a-cheap-cache-for-a-tool-for-a-day-at-most ()
  "Refreshes that pay for days do not make a tool wait warm for days.
DeepSeek's cache reads for a fiftieth of the input price, so 49 refreshes
of a three-hour cache cost less than sending the conversation again --
nearly a week of them.  A tool waits for a day at most, however cheap a
refresh is."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--prices '(0.003 . 0.15))
    (let* ((now (float-time))
           (sid (harness-cache-warm-test-session "api:m" 10800)))
      (cl-letf (((symbol-function 'harness-cache-warm--tool-wait-p) (lambda (_) t)))
        (let ((state (harness-call 'cache/warm sid)))
          (should (= 49 (plist-get state :max-refreshes)))
          (should (eq t (plist-get state :tool)))
          (should (eq t (plist-get state :warming)))
          ;; The end of the period is a day from the conversation's last
          ;; own request, not the six days 49 three-hour refreshes span.
          (should (<= (- (plist-get state :until) now) (+ (* 24 3600) 1)))
          (should (> (- (plist-get state :until) now) (- (* 24 3600) 60))))))))

(ert-deftest harness-cache-warm-leaves-a-tool-that-outlasts-a-day-to-lapse ()
  "A turn that has waited on a tool for longer than a day gets no more refreshes.
Its period is over, and a period the user asks for then is kept all the
same: the day is the tool's limit, not the user's."
  (harness-cache-warm-test-with
    (setq harness-cache-warm-test--prices '(0.003 . 0.15))
    ;; Three hours of cache, stamped 1.8 hours ago, with 8 refreshes
    ;; (each adds 2.9 hours): the period began 25 hours ago.
    (let* ((sid (harness-cache-warm-test-session "api:m" 10800 -6480)))
      (puthash sid 8 harness-cache-warm--counts)
      (cl-letf (((symbol-function 'harness-cache-warm--tool-wait-p) (lambda (_) t)))
        (let ((state (harness-call 'cache/warm sid)))
          (should (eq t (plist-get state :tool)))
          (should (eq :false (plist-get state :warming)))
          (should-not (plist-get state :until)))
        ;; The period began 25 hours ago, so its day is over: the lapse is
        ;; left alone while the turn waits on the tool.
        (setq harness-cache-warm-test--requests nil)
        (harness-cache-warm-test--event sid :running t)
        (should-not harness-cache-warm-test--requests)
        ;; The user asks for a period of their own: that is kept.
        (should (plist-get (harness-call 'cache/keep-warm sid 1800) :manual-until))
        (setq harness-cache-warm-test--requests nil)
        (harness-cache-warm-test--event sid :running t)
        (harness-cache-warm-test--wait-idle)
        (should (= 1 (length harness-cache-warm-test--requests)))
        (should (eq t (plist-get (harness-call 'cache/warm sid) :warming)))))))

(ert-deftest harness-cache-warm-announces-when-a-turn-waits-on-a-tool ()
  "The chat hears when a turn starts to wait on a tool, and when it stops."
  (harness-cache-warm-test-with
    (let* ((sid (harness-cache-warm-test-session "api:m"))
           (end (harness-cache-warm-test--tool-turn sid (harness-sender-system "tasks"))))
      (should (cl-some (lambda (change) (and (equal sid (car change))
                                             (eq t (plist-get (cadr change) :tool))))
                       harness-cache-warm-test--changes))
      (should (equal (list sid) (mapcar (lambda (s) (plist-get s :session-id)) (harness-call 'cache/warm-list))))
      (funcall end)
      (harness-test-wait (lambda () (null (cadr (car (last harness-cache-warm-test--changes))))) 5
                         "the end of the period")
      (should-not (harness-call 'cache/warm-list)))))

(ert-deftest harness-cache-warm-leaves-a-hosted-loop-alone-while-its-turn-runs ()
  "A hosted loop's process is busy with the turn: its cache is read again when it
waits for the user, not while a tool runs."
  (harness-cache-warm-test-with
    (let ((sid (harness-cache-warm-test-session "hosted:m")))
      (should (harness-cache-warm--supported-p (harness-call 'session/get sid)))
      (cl-letf (((symbol-function 'harness-cache-warm--running-p) (lambda (_) t)))
        (should-not (harness-cache-warm--supported-p (harness-call 'session/get sid)))))))

(ert-deftest harness-cache-warm-says-why-a-cache-cannot-be-kept-warm ()
  "A state that says its cache cannot be kept warm says why.
A hosted loop's cache is not kept warm while its turn runs, and the
reason is not that its provider cannot: the turn's own requests read the
cache, and the process that holds the conversation is busy with them.
Another says it has no way, another that it holds no conversation of
the session's yet; a cache that can be kept warm has no reason."
  (harness-cache-warm-test-with
    (let ((hosted (harness-cache-warm-test-session "hosted:m"))
          (stubborn (harness-cache-warm-test-session "stubborn:m"))
          (api (harness-cache-warm-test-session "api:m"))
          (empty (harness-cache-warm-test-session "hosted:m")))
      (harness-call 'session/set-provider-state empty nil)
      (dolist (sid (list hosted stubborn api empty))
        (harness-call 'cache/active sid))
      (let ((why (lambda (sid) (plist-get (harness-call 'cache/warm sid) :unsupported))))
        (dolist (sid (list hosted api))
          (should (eq t (plist-get (harness-call 'cache/warm sid) :supported)))
          (should-not (funcall why sid)))
        (should (eq :false (plist-get (harness-call 'cache/warm stubborn) :supported)))
        (should (string-match-p "no way to refresh" (funcall why stubborn)))
        (should (string-match-p "holds no conversation" (funcall why empty)))
        ;; While its turn runs.
        (cl-letf (((symbol-function 'harness-cache-warm--running-p) (lambda (sid) (equal sid hosted))))
          (should (eq :false (plist-get (harness-call 'cache/warm hosted) :supported)))
          (let ((text (funcall why hosted)))
            (should (string-match-p "turn is running" text))
            (should (string-match-p "requests read the prompt cache" text))
            (should-not (string-match-p "no way" text))))
        ;; Where it can again, nothing is said.
        (should-not (funcall why hosted))
        ;; A provider that is sent the conversation every time can be asked
        ;; while its turn waits on a tool, but not before the turn sent a request.
        (cl-letf (((symbol-function 'harness-cache-warm--running-p) (lambda (sid) (equal sid api)))
                  ((symbol-function 'harness-agent-last-request) (lambda (_sid) nil)))
          (should (string-match-p "sent no request yet" (funcall why api)))
          (should (eq :false (plist-get (harness-call 'cache/warm api) :supported))))
        (cl-letf (((symbol-function 'harness-cache-warm--running-p) (lambda (sid) (equal sid api)))
                  ((symbol-function 'harness-agent-last-request) (lambda (_sid) '(:model "api:m"))))
          (should-not (funcall why api))
          (should (eq t (plist-get (harness-call 'cache/warm api) :supported))))))))

(ert-deftest harness-cache-warm-the-demo-provider-reads-the-cache-for-a-refresh ()
  "The demo provider answers a refresh as one that caches the conversation would:
it reads all of it from the cache, so a demo session is kept warm like any."
  (harness-cache-warm-test-with
    (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id)))
      (harness-call 'session/append sid '(:kind user :content "hello"))
      (harness-call 'session/append sid '(:kind assistant :content "hi"))
      (harness-call 'session/usage-add sid (list :input 10 :output 10 :cache-read 1500 :context 1600
                                                 :cache-at (float-time) :cache-ttl 300))
      (harness-call 'cache/active sid)
      (let ((harness-provider-demo--delay 0.01))
        (harness-cache-warm-test--event sid)
        (harness-test-wait (lambda () (eql 1 (plist-get (harness-call 'cache/warm sid) :refreshes))) 5
                           "the refresh to count"))
      (should (= 3100 (plist-get (plist-get (harness-call 'session/get sid) :usage) :cache-read)))
      (should-not (plist-get (harness-call 'cache/warm sid) :blocked)))))

;;;; All of it, by the watcher

(defun harness-cache-warm-test--fire-watcher (sid)
  "Advance the test clock to SID's next watcher and fire its real timer."
  (let ((watch (gethash sid harness-cache--watched)))
    (should watch)
    (harness-test-clock-fire (plist-get watch :timer) (plist-get watch :fire))))

(ert-deftest harness-cache-warm-goes-on-until-the-user-is-gone ()
  "The watcher says the cache is about to lapse, the module reads it again, the
new stamp sets the watcher for the next lapse; and at that lapse the user has
been gone for the warm period, so the cache is left to lapse.  A cache that
lasts two seconds, a lead of 0.4 and a grace of 1.5 stand for five minutes,
ten seconds and six."
  (harness-cache-warm-test-with
   (harness-test-with-clock
    (let ((harness-cache--lead-min 0.4) (harness-cache--lead-max 0.4)
          (harness-cache--too-late 0.1) (harness-cache--grace-min 1.5))
      (let ((sid (harness-cache-warm-test-session "api:m" 2.0 0)))
        ;; Active 0.4 seconds, kept warm 1.5 more: until 1.9 s after, past
        ;; the first lapse, at 1.6 s.
        (harness-call 'cache/active sid)
        (harness-cache-warm-test--fire-watcher sid)
        (harness-cache-warm-test--wait-idle)
        (should (= 1 (gethash sid harness-cache-warm--counts 0)))
        ;; The lapse after that, 1.6 seconds on, is past the period.
        (harness-cache-warm-test--fire-watcher sid)
        (should (equal 1 (length harness-cache-warm-test--requests)))
        (should-not (harness-call 'cache/claimed sid))
        (should-not (harness-call 'cache/warm sid)))))))

(ert-deftest harness-cache-warm-goes-on-while-the-user-keeps-showing-signs-of-life ()
  "A user who keeps typing keeps the cache warm through several lapses."
  (harness-cache-warm-test-with
   (harness-test-with-clock
    (let ((harness-cache--lead-min 0.4) (harness-cache--lead-max 0.4)
          (harness-cache--too-late 0.1) (harness-cache--grace-min 0.1))
      (let ((sid (harness-cache-warm-test-session "api:m" 2.0 0)))
        (dotimes (i 3)
          ;; The latest sign of life is just before this cache's lapse.
          (let ((watch (gethash sid harness-cache--watched)))
            (cl-incf harness-test-clock-offset
                     (max 0 (- (plist-get watch :fire) (float-time) 0.05))))
          (harness-call 'cache/active sid)
          (harness-cache-warm-test--fire-watcher sid)
          (harness-cache-warm-test--wait-idle (1+ i)))
        (should (>= (length harness-cache-warm-test--requests) 3))
        ;; Every refresh came ahead of the lapse it was for.
        (should (> (plist-get (harness-call 'cache/warm sid) :refreshes) 2)))))))

(provide 'harness-cache-warm-test)
;;; harness-cache-warm-test.el ends here
