;;; harness-cache-test.el --- Tests for the prompt cache watcher  -*- lexical-binding: t; -*-

;;; Commentary:

;; The watcher says when a session's prompt cache is about to lapse
;; (`cache/pre-expire'), once for each moment a cache lapses, from the
;; cache the session reports (`:cache'), and knows whether the user is
;; around.  The periods are generic in the cache's lifetime: they are
;; checked at the lifetimes the feature was described with (five
;; minutes, an hour) and at two a provider could offer (37 minutes, an
;; hour and a half).  The timers are checked with caches that last a
;; couple of seconds and a lead of a fraction of one; everything else
;; reads what the watcher holds (`cache/watching') instead of waiting.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-sessions)
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
(defvar harness-cache-ttl)
(defvar harness-cache-ttl-overrides)
(defvar harness-providers)
(declare-function harness-cache-lead "harness-cache" (ttl))
(declare-function harness-cache-active-window "harness-cache" (ttl))
(declare-function harness-cache-grace "harness-cache" (ttl))
(declare-function harness-cache-warm-period "harness-cache" (ttl))
(declare-function harness-cache-around-p "harness-cache" (sid &optional session now))
(declare-function harness-cache--schedule "harness-cache" (sid session))
(declare-function harness-provider--forget "harness-provider" (id))

(defvar harness-cache-test--events nil
  "The `cache/pre-expire' events heard, oldest first: (SESSION-ID INFO).")

(defvar harness-cache-test--presence nil
  "The `cache/presence-changed' events heard, oldest first: (SESSION-ID PRESENCE).")

(defmacro harness-cache-test-with (&rest body)
  "Run BODY with the watcher started on a fresh bus, and a provider to name.
Caches last what the test says.  Events are collected in
`harness-cache-test--events' and `harness-cache-test--presence'."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session cache))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-cache--watched)
     (clrhash harness-cache--fired)
     (clrhash harness-cache--claims)
     (clrhash harness-cache--presence)
     (clrhash harness-cache--announced)
     (clrhash harness-cache--ends)
     (setq harness-cache-test--events nil
           harness-cache-test--presence nil)
     (harness-define-provider 'fake
       :label "Fake"
       :models (lambda () (harness-resolved (list (list :name "m" :label "Fake M" :context-window 200000))))
       :complete (lambda (_req) (list :cancel #'ignore)))
     (harness-on 'cache/pre-expire
                 (lambda (sid info) (setq harness-cache-test--events
                                          (append harness-cache-test--events (list (list sid info))))))
     (harness-on 'cache/presence-changed
                 (lambda (sid presence) (setq harness-cache-test--presence
                                              (append harness-cache-test--presence (list (list sid presence))))))
     (unwind-protect
         (let ((harness-cache-ttl 300)
               (harness-cache-ttl-overrides nil)
               (default-directory dir))
           ,@body)
       (maphash (lambda (_ entry) (when (timerp (plist-get entry :timer)) (cancel-timer (plist-get entry :timer))))
                harness-cache--watched)
       (maphash (lambda (_ timer) (cancel-timer timer)) harness-cache--ends)
       (remhash 'fake harness-providers)
       (harness-provider--forget 'fake))))

(defun harness-cache-test-session (ttl from-now &optional model)
  "Create a session on MODEL whose cache lasts TTL seconds and was stamped FROM-NOW.
FROM-NOW is added to the current time, so a negative one stamps the cache
in the past: it lapses at the time plus FROM-NOW plus TTL.  Return the
session's id."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model (or model "fake:m")) :id)))
    (harness-call 'session/append sid '(:kind user :content "please refactor the parser"))
    (harness-call 'session/append sid '(:kind assistant :content "Done: parser.el rewritten"))
    (harness-call 'session/usage-add sid (list :input 10 :output 10 :cache-read 3000 :context 3020
                                               :cache-at (+ (float-time) from-now) :cache-ttl ttl))
    sid))

(defun harness-cache-test-stamp (sid ttl from-now)
  "Stamp session SID's cache again: a request FROM-NOW that kept it TTL seconds."
  (harness-call 'session/usage-add sid (list :input 10 :output 10 :cache-read 3000 :context 3020
                                             :cache-at (+ (float-time) from-now) :cache-ttl ttl)))

(defun harness-cache-test--expires (sid)
  "Return when session SID's cache lapses, or nil."
  (plist-get (plist-get (harness-call 'session/get sid) :cache) :expires))

;;;; The periods

(ert-deftest harness-cache-periods-follow-the-lifetime-of-the-cache ()
  "The lead, the active window, the grace and the warm period are formulas of
the cache's lifetime T, so a provider keeping its cache 37 minutes or an
hour and a half gets the behaviour a five-minute or an hour's does.
At five minutes: a lead of 10 seconds, an active window of a minute, a
grace of five minutes.  At an hour: a minute, 12 minutes (the 5 to 15 the
feature was described with) and 20."
  (harness-cache-test-with
    (dolist (case '((300  10.0 60.0   300.0  360.0)
                    (3600 60.0 720.0  1200.0 1920.0)
                    ;; 37 minutes
                    (2220 60.0 444.0  740.0  1184.0)
                    ;; An hour and a half
                    (5400 60.0 1080.0 1800.0 2880.0)
                    ;; A cache that lasts hardly any time at all.
                    (60   10.0 12.0   300.0  312.0)))
      (pcase-let ((`(,ttl ,lead ,active ,grace ,warm) case))
        (should (= lead (harness-cache-lead ttl)))
        (should (= active (harness-cache-active-window ttl)))
        (should (= grace (harness-cache-grace ttl)))
        (should (= warm (harness-cache-warm-period ttl)))
        (should (equal (list :ttl ttl :lead lead :active active :grace grace :warm warm)
                       (harness-call 'cache/periods ttl)))))
    ;; The lead is never over half of a cache that lasts hardly any time.
    (should (= 4.0 (harness-cache-lead 8)))
    ;; No lifetime: the setting's.
    (should (equal 300 (plist-get (harness-call 'cache/periods nil) :ttl)))
    (let ((harness-cache-ttl 3600))
      (should (= 60.0 (plist-get (harness-call 'cache/periods nil) :lead))))))

;;;; The event

(ert-deftest harness-cache-watcher-is-set-for-the-lead-before-the-lapse ()
  "A session whose cache is stamped is watched for the moment `lead' seconds
before it lapses, whatever the lifetime."
  (harness-cache-test-with
    (let ((short (harness-cache-test-session 300 0))
          (long (harness-cache-test-session 3600 0)))
      (let ((a (harness-call 'cache/watching short)))
        (should (= 10.0 (plist-get a :lead)))
        (should (= (- (harness-cache-test--expires short) 10.0) (plist-get a :fire-at)))
        (should (= (harness-cache-test--expires short) (plist-get a :expires))))
      (let ((b (harness-call 'cache/watching long)))
        (should (= 60.0 (plist-get b :lead)))
        (should (= (- (harness-cache-test--expires long) 60.0) (plist-get b :fire-at)))))))

(ert-deftest harness-cache-watcher-says-so-just-before-the-lapse ()
  "`cache/pre-expire' comes once, ahead of the lapse, with what the handlers
need: when it lapses, the lifetime, the lead, the model and the context."
  (harness-cache-test-with
    (let ((harness-cache--lead-min 0.5) (harness-cache--lead-max 0.5) (harness-cache--too-late 0.1))
      (let* ((sid (harness-cache-test-session 2.0 0))
             (expires (harness-cache-test--expires sid)))
        (should-not harness-cache-test--events)
        (harness-test-wait (lambda () harness-cache-test--events) 5 "the event")
        (should (< (float-time) expires))
        (should (equal 1 (length harness-cache-test--events)))
        (pcase-let ((`(,heard ,info) (car harness-cache-test--events)))
          (should (equal sid heard))
          (should (= expires (plist-get info :expires)))
          (should (= 2.0 (plist-get info :ttl)))
          (should (= 0.5 (plist-get info :lead)))
          (should (equal "fake:m" (plist-get info :model)))
          (should (= 3020 (plist-get info :context)))
          (should (eq 'idle (plist-get info :status)))
          (should-not (plist-get info :running)))
        ;; Not again for the same moment, though the session changes.
        (harness-call 'session/hint sid "something happened")
        (sit-for 0.3)
        (should (equal 1 (length harness-cache-test--events)))
        (should-not (harness-call 'cache/watching sid))))))

(ert-deftest harness-cache-a-request-that-read-the-cache-moves-the-moment-on ()
  "A request that reads the cache moves the lapse, and the event with it: the
one set for the earlier moment never comes, and the one for the new moment
does.  This is what makes a refresh go on by itself."
  (harness-cache-test-with
    (let ((harness-cache--lead-min 0.4) (harness-cache--lead-max 0.4) (harness-cache--too-late 0.1))
      (let* ((sid (harness-cache-test-session 1.6 0))
             (first (harness-cache-test--expires sid)))
        (sit-for 0.5)
        ;; A request at 0.5 s keeps the cache another 1.6 s.
        (harness-cache-test-stamp sid 1.6 0)
        (let ((second (harness-cache-test--expires sid)))
          (should (> second first))
          (should (= second (plist-get (harness-call 'cache/watching sid) :expires)))
          (harness-test-wait (lambda () harness-cache-test--events) 5 "the event")
          (should (equal 1 (length harness-cache-test--events)))
          (should (= second (plist-get (cadr (car harness-cache-test--events)) :expires)))
          (should (>= (float-time) (- second 0.5)))
          ;; Stamped again after the event: a new moment, a new event.
          (setq harness-cache-test--events nil)
          (harness-cache-test-stamp sid 1.6 0)
          (should (> (harness-cache-test--expires sid) second))
          (harness-test-wait (lambda () harness-cache-test--events) 5 "the next event")
          (should (equal 1 (length harness-cache-test--events))))))))

(ert-deftest harness-cache-watcher-has-nothing-to-say-for-a-cache-that-is-gone ()
  "No timer is set for a session without a cache, one that lapsed, one with
too little time left to act on, a cache held for another model, a cache a
redaction dropped; and the timer goes when the cache does."
  (harness-cache-test-with
    (let ((harness-cache--too-late 2))
      (let ((none (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "fake:m") :id))
            (lapsed (harness-cache-test-session 300 -400))
            (late (harness-cache-test-session 300 -298.5))
            (other (harness-cache-test-session 300 0))
            (live (harness-cache-test-session 300 0)))
        (dolist (sid (list none lapsed late))
          (should-not (harness-call 'cache/watching sid)))
        (should (harness-call 'cache/watching live))
        ;; A model switched to: the cache serves the old one only.
        (should (harness-call 'cache/watching other))
        (harness-call 'session/update other :model "fake:other" :silent t)
        (should-not (harness-call 'cache/watching other))
        ;; A compaction takes the stamp away.
        (harness-call 'session/usage-add live (list :context 100 :cache-reset t))
        (should-not (harness-call 'cache/watching live))
        ;; So does a deleted session.
        (let ((gone (harness-cache-test-session 300 0)))
          (should (harness-call 'cache/watching gone))
          (harness-call 'session/delete gone)
          (should-not (harness-call 'cache/watching gone)))))))

(ert-deftest harness-cache-watcher-says-nothing-after-a-sleep ()
  "A machine that slept through the moment says nothing when it wakes: the
event is for a cache that still lasts long enough to act on."
  (harness-cache-test-with
    (let* ((harness-cache--too-late 2)
           (sid (harness-cache-test-session 300 0))
           (expires (harness-cache-test--expires sid)))
      ;; The timer fires after the cache has lapsed.
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) (+ expires 5))))
        (harness-cache--fire sid expires))
      (should-not harness-cache-test--events)
      ;; With time left it says so.
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) (- expires 8))))
        (harness-cache--fire sid expires))
      (should (equal 1 (length harness-cache-test--events)))
      ;; Only once for that moment.
      (harness-cache--fire sid expires)
      (should (equal 1 (length harness-cache-test--events))))))

(ert-deftest harness-cache-watcher-tells-a-running-session-from-an-idle-one ()
  "INFO says whether a turn runs, so a handler can leave the session alone."
  (harness-cache-test-with
    (let* ((harness-cache--too-late 0.1)
           (sid (harness-cache-test-session 300 0))
           (expires (harness-cache-test--expires sid)))
      (harness-call 'session/set-status sid 'running)
      (harness-cache--fire sid expires)
      (should (plist-get (cadr (car harness-cache-test--events)) :running))
      (should (eq 'running (plist-get (cadr (car harness-cache-test--events)) :status))))))

(ert-deftest harness-cache-watcher-follows-the-sessions-there-already-at-a-reload ()
  "A module that starts, or starts again at a reload, sets the timers of the
sessions that exist; a timer set for the moment stays."
  (harness-cache-test-with
    (let ((sid (harness-cache-test-session 300 0)))
      (let ((timer (plist-get (gethash sid harness-cache--watched) :timer)))
        (should (timerp timer))
        (harness-module-start 'cache)
        (should (eq timer (plist-get (gethash sid harness-cache--watched) :timer))))
      (clrhash harness-cache--watched)
      (harness-module-start 'cache)
      (should (harness-call 'cache/watching sid)))))

;;;; Claiming a lapse

(ert-deftest harness-cache-the-first-claim-on-a-lapse-wins ()
  "A handler that acts on the cache claims it; the ones after it find it taken.
The claim is for the moment the cache lapses: a request that reads the
cache moves the moment and ends it."
  (harness-cache-test-with
    (let ((sid (harness-cache-test-session 300 0)))
      (should-not (harness-call 'cache/claimed sid))
      (should (harness-call 'cache/claim sid 'warm))
      (should (eq 'warm (harness-call 'cache/claimed sid)))
      ;; The same one again still holds it; another does not get it.
      (should (harness-call 'cache/claim sid 'warm))
      (should-not (harness-call 'cache/claim sid 'compact))
      (should (eq 'warm (harness-call 'cache/claimed sid)))
      ;; A request that read the cache.
      (harness-cache-test-stamp sid 300 1)
      (should-not (harness-call 'cache/claimed sid))
      (should (harness-call 'cache/claim sid 'compact))
      (should (eq 'compact (harness-call 'cache/claimed sid)))
      ;; No cache, no claim.
      (harness-call 'session/usage-add sid (list :context 100 :cache-reset t))
      (should-not (harness-call 'cache/claim sid 'warm))
      (should-not (harness-call 'cache/claimed sid)))))

;;;; The user

(ert-deftest harness-cache-a-sign-of-life-makes-the-user-around-for-the-warm-period ()
  "After a sign of life the user is around for the warm period of the cache's
lifetime, counted from the sign: six minutes for a five-minute cache, 32
for an hour's.  A later sign moves it on; none, or an old one, leaves the
user not around."
  (harness-cache-test-with
    (let* ((short (harness-cache-test-session 300 0))
           (long (harness-cache-test-session 3600 0)))
      (should-not (harness-call 'cache/presence short))
      (should-not (harness-cache-around-p short))
      (let ((presence (harness-call 'cache/active short)))
        (should (equal short (plist-get presence :session-id)))
        (should (plist-get presence :around))
        (should (= 360.0 (- (plist-get presence :until) (plist-get presence :active-at))))
        (should-not (plist-get presence :manual-until)))
      (should (= 1920.0 (let ((p (harness-call 'cache/active long)))
                          (- (plist-get p :until) (plist-get p :active-at)))))
      (should (harness-cache-around-p short))
      (let ((until (plist-get (harness-call 'cache/presence short) :until)))
        (should-not (harness-cache-around-p short nil (+ until 1)))
        (should (harness-cache-around-p short nil (- until 1))))
      ;; Announced when it begins.
      (should (equal (list short long) (mapcar #'car harness-cache-test--presence)))
      ;; A session that is gone has no presence.
      (should-not (harness-call 'cache/active "no-such-session")))))

(ert-deftest harness-cache-the-user-can-ask-to-be-around-for-a-while ()
  "A period asked for holds whatever the user does: the later of it and the
warm period after their last sign of life is when they stop counting as
around.  0 takes it away again, leaving the other, and no period at all
leaves nothing."
  (harness-cache-test-with
    (let ((sid (harness-cache-test-session 300 0)))
      (let ((presence (harness-call 'cache/active sid 1800)))
        (should (= 1800.0 (- (plist-get presence :until) (plist-get presence :active-at))))
        (should (= (plist-get presence :until) (plist-get presence :manual-until))))
      ;; Further signs of life do not shorten it.
      (let ((presence (harness-call 'cache/active sid)))
        (should (> (- (plist-get presence :until) (plist-get presence :active-at)) 1700))
        (should (plist-get presence :manual-until)))
      ;; Taking it away leaves the period the signs of life made.
      (let ((presence (harness-call 'cache/active sid 0)))
        (should-not (plist-get presence :manual-until))
        (should (= 360.0 (- (plist-get presence :until) (plist-get presence :active-at)))))
      ;; A day at most.
      (let ((presence (harness-call 'cache/active sid (* 10 24 3600))))
        (should (<= (- (plist-get presence :manual-until) (float-time)) (+ (* 24 3600) 1))))
      ;; Seconds may come as text, over a wire.
      (should (< (abs (- 900 (- (plist-get (harness-call 'cache/active sid "900") :manual-until) (float-time)))) 5))
      ;; Asking to stop, with nothing else, leaves no one around.
      (let ((other (harness-cache-test-session 300 0)))
        (should-not (harness-call 'cache/active other 0))
        (should-not (harness-cache-around-p other))))))

(ert-deftest harness-cache-the-user-stops-being-around-when-the-period-is-over ()
  "The period ends by itself: the presence is announced as gone, and the
session forgotten."
  (harness-cache-test-with
    (let ((harness-cache--grace-min 0.2))
      (let ((sid (harness-cache-test-session 1.0 0)))
        ;; A second's cache: active for 0.2 s, kept warm for 0.33 s more.
        (harness-call 'cache/active sid)
        (should (harness-cache-around-p sid))
        (harness-test-wait (lambda ()
                             (let ((last (car (last harness-cache-test--presence))))
                               (and last (null (cadr last)))))
                           4 "the end of the period")
        (should-not (harness-cache-around-p sid))
        (should-not (harness-call 'cache/presence sid))
        (should (equal (list sid nil) (car (last harness-cache-test--presence))))
        (should-not (gethash sid harness-cache--presence))))))

(ert-deftest harness-cache-messages-and-answers-are-signs-of-life ()
  "A message the user sends is a sign of life; so is the answer to a question.
A message another session or the harness sends is not, and neither is one the
queue sends out."
  (harness-cache-test-with
    (let ((sid (harness-cache-test-session 300 0)))
      (should (equal '((:type "text" :text "hi")) (harness-run-filter 'agent/message '((:type "text" :text "hi")) sid
                                                                      (list :from nil :steering nil :queued nil))))
      (should (harness-cache-around-p sid))
      (let ((other (harness-cache-test-session 300 0))
            (queued (harness-cache-test-session 300 0)))
        (harness-run-filter 'agent/message '((:type "text" :text "hi")) other
                            (list :from (harness-sender-system "tasks") :steering nil :queued nil))
        (harness-run-filter 'agent/message '((:type "text" :text "hi")) queued
                            (list :from nil :steering nil :queued t))
        (should-not (harness-cache-around-p other))
        (should-not (harness-cache-around-p queued))
        (harness-emit 'question/answered other "p1" "yes")
        (should (harness-cache-around-p other))))))

(ert-deftest harness-cache-forgets-a-session-that-is-deleted ()
  "Deleting a session takes its timers, claim and presence away, and says the user is gone."
  (harness-cache-test-with
    (let ((sid (harness-cache-test-session 300 0)))
      (harness-call 'cache/active sid)
      (harness-call 'cache/claim sid 'warm)
      (should (gethash sid harness-cache--ends))
      (harness-call 'session/delete sid)
      (dolist (table (list harness-cache--watched harness-cache--ends harness-cache--presence
                           harness-cache--claims harness-cache--fired))
        (should-not (gethash sid table)))
      (should (equal (list sid nil) (car (last harness-cache-test--presence)))))))

(ert-deftest harness-cache-reaches-clients ()
  "Clients ask the watcher's questions and hear when the user's presence changes."
  (harness-test-load-module 'acp)
  (should (harness-acp--extension-allowed-p "cache/active"))
  (should (harness-acp--extension-allowed-p "cache/presence"))
  (should (harness-acp--extension-allowed-p "cache/keep-warm"))
  (should (harness-acp--extension-allowed-p "cache/warm-list"))
  (should (harness-acp--extension-allowed-p "cache/periods"))
  (should (memq 'cache/warm-changed harness-acp--forwarded-events)))

(provide 'harness-cache-test)
;;; harness-cache-test.el ends here
