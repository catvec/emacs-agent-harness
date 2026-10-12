;;; harness-cache-dropped-test.el --- Tests for the prompt cache a redaction drops  -*- lexical-binding: t; -*-

;;; Commentary:

;; A redaction drops the provider conversation of a hosted-loop session
;; (`session/reset-provider'), and with it the provider's prompt cache of
;; that conversation: the new conversation opens with the redacted
;; transcript as text, a prefix the old cache does not hold.  The stamp
;; of the cache alone cannot say so, so the reset marks the usage
;; (`:cache-dropped'), the session's `:cache' reports the cache gone from
;; the drop on (`:dropped'), and everything that reads it -- the
;; cold-cache gate (harness-cowboy.el) first -- finds a cold cache
;; instead of one that is warm for minutes to come.
;;
;; The sessions here sit on `hosted', a fake hosted loop (Claude Code,
;; Copilot), or on `api', which is sent the whole transcript at every
;; request.  Times are made up (a cache stamped at 1000, lasting 300
;; seconds) or the clock's own; no secret is involved.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-providers)
(defvar harness-sessions)
(defvar harness-agent--turns)
(defvar harness-compaction--running)
(defvar harness-tools-agent--questions)
(defvar harness-cowboy--asking)
(defvar harness-cowboy-default)
(defvar harness-cowboy-ask)
(defvar harness-cowboy-min-context)
(defvar harness-non-interactive)
(defvar harness-cache-ttl)
(defvar harness-cache-ttl-overrides)
(defvar harness-compaction-brief-model)
(defvar harness-provider-demo--delay)
(defvar harness-provider-demo-script-override)
(declare-function harness-cowboy-cold-p "harness-cowboy" (session &optional now))
(declare-function harness-cowboy--clock "harness-cowboy" (time))
(declare-function harness-cowboy--question-text "harness-cowboy" (session estimate from &optional note))
(declare-function harness-cowboy--hint-text "harness-cowboy" (choice by session estimate &optional why))
(declare-function harness-cowboy--info "harness-cowboy" (session-id session estimate from default message))
(declare-function harness-provider--forget "harness-provider" (id))
(declare-function harness-session--load-all "harness-session" ())
(declare-function harness-session-flush "harness-session" (&optional id))

(defvar harness-cache-dropped-test--requests nil
  "The requests the fake hosted provider got, newest first.")

(defun harness-cache-dropped-test--define-providers ()
  "Define `hosted', a fake hosted loop, and `api', a provider sent everything.
`hosted' answers every request with a conversation state, a reply and
usage that wrote 400 tokens of cache."
  (harness-define-provider 'hosted
    :label "Hosted"
    :models (lambda ()
              (harness-resolved
               (list (list :name "m" :label "Hosted M" :context-window 200000
                           :pricing '(:input 4.0 :output 20.0 :cache-read 0.4 :cache-write 5.0)))))
    :complete (lambda (req)
                (push req harness-cache-dropped-test--requests)
                (let ((on-event (plist-get req :on-event)))
                  (run-at-time 0.005 nil
                               (lambda ()
                                 (funcall on-event '(:type provider-state :state (:conv "c1")))
                                 (funcall on-event '(:type text :delta "ok"))
                                 (funcall on-event '(:type usage :input 30 :output 5
                                                           :cache-write 400 :context 430))
                                 (funcall on-event '(:type done :stop-reason end-turn)))))
                (list :cancel #'ignore))
    :capabilities '(:hosted-loop t :resume t :fork t))
  (harness-define-provider 'api
    :label "API"
    :models (lambda ()
              (harness-resolved
               (list (list :name "m" :label "API M" :context-window 200000
                           :pricing '(:input 4.0 :output 20.0 :cache-read 0.4 :cache-write 5.0)))))
    :complete (lambda (req)
                (let ((on-event (plist-get req :on-event)))
                  (run-at-time 0.005 nil
                               (lambda ()
                                 (funcall on-event '(:type text :delta "ok"))
                                 (funcall on-event '(:type done :stop-reason end-turn)))))
                (list :cancel #'ignore))))

(defun harness-cache-dropped-test--summary (_request)
  "Answer a summary request, which nothing here asks for in earnest."
  '((:type text :delta "SUMMARY TEXT")
    (:type usage :input 50 :output 5)
    (:type done :stop-reason end-turn)))

(defmacro harness-cache-dropped-test-with (&rest body)
  "Load the modules the cold-cache gate needs, define the providers; run BODY.
Asking is on and the default is the brief summary, whatever the user's
settings say; a cache lasts 300 seconds."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent compaction
                  tools-agent tools-sessions cowboy))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (clrhash harness-tools-agent--questions)
     (clrhash harness-cowboy--asking)
     (setq harness-cache-dropped-test--requests nil)
     (unwind-protect
         (let ((harness-provider-demo--delay 0.005)
               (harness-provider-demo-script-override #'harness-cache-dropped-test--summary)
               (harness-compaction-brief-model "demo:scripted")
               (harness-cowboy-default 'brief)
               (harness-cowboy-ask t)
               (harness-cowboy-min-context 0)
               (harness-non-interactive nil)
               (harness-cache-ttl 300)
               (harness-cache-ttl-overrides nil)
               (default-directory dir))
           (harness-cache-dropped-test--define-providers)
           (harness-add-filter 'permission/decide
                               (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
           ,@body)
       (dolist (p '(hosted api))
         (remhash p harness-providers)
         (harness-provider--forget p)))))

(defun harness-cache-dropped-test-session (model at)
  "Create a session on MODEL with an answered exchange and a cache stamped at AT.
The stamp is of a request that read 3000 tokens of cache: the context
is 3020 tokens."
  (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model model) :id)))
    (harness-call 'session/append sid '(:kind user :content "please refactor the parser"))
    (harness-call 'session/append sid '(:kind assistant :content "Done: parser.el rewritten"))
    (harness-call 'session/usage-add sid (list :input 10 :output 10 :cache-read 3000 :context 3020
                                               :cache-at at))
    sid))

(defun harness-cache-dropped-test--cache (sid)
  "Return the prompt cache session SID reports."
  (plist-get (harness-call 'session/get sid) :cache))

(defun harness-cache-dropped-test--usage (sid)
  "Return the usage of session SID."
  (plist-get (harness-call 'session/get sid) :usage))

(defun harness-cache-dropped-test--reset-at (sid time)
  "Reset the provider conversation of session SID with the clock at TIME."
  (cl-letf (((symbol-function 'float-time) (lambda (&optional _) time)))
    (harness-call 'session/reset-provider sid)))

(defun harness-cache-dropped-test--question (sid)
  "Wait for the question SID's cold cache asks; return its pending item."
  (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "the cold-cache question")
  (car (harness-call 'question/pending sid)))

(defun harness-cache-dropped-test--hints (sid)
  "Return the hints in the transcript of session SID."
  (delq nil (mapcar (lambda (n) (and (eq (plist-get n :kind) 'hint) (plist-get n :content)))
                    (harness-call 'session/nodes sid))))

;;;; The reset

(ert-deftest harness-cache-dropped-a-reset-makes-a-warm-hosted-cache-cold ()
  "A reset of a hosted-loop session with a warm stamp drops the cache at once.
This is the bug: its cache was reported warm for the rest of its
lifetime, so the cold-cache gate asked nothing and the next message sent
the whole conversation as one uncached message.  Now `:cache' says it is
gone from the drop on -- `:expires' is the drop, `:dropped' says why --
and the gate finds it cold, though the clock of the stamp has 200
seconds to run."
  (harness-cache-dropped-test-with
    (let* ((sid (harness-cache-dropped-test-session "hosted:m" 1000.0))
           (cold (lambda (now) (harness-cowboy-cold-p (harness-call 'session/get sid) now))))
      ;; Warm: stamped at 1000, kept for 300 seconds.
      (should (equal '(:at 1000.0 :ttl 300 :expires 1300.0 :model "hosted:m")
                     (harness-cache-dropped-test--cache sid)))
      (should-not (funcall cold 1101.0))
      (should (eq t (harness-call 'session/reset-drops-cache-p sid)))
      ;; The reset says it dropped a cache.
      (should (equal '(:checkpoints 0 :cache-dropped t)
                     (harness-cache-dropped-test--reset-at sid 1100.0)))
      (should (= 1100.0 (plist-get (harness-cache-dropped-test--usage sid) :cache-dropped)))
      ;; The cache is gone from then on, whatever its clock says.
      (should (equal '(:at 1000.0 :ttl 300 :expires 1100.0 :model "hosted:m" :dropped 1100.0)
                     (harness-cache-dropped-test--cache sid)))
      (should (funcall cold 1101.0))
      ;; By the clock before the drop it was warm.
      (should-not (funcall cold 1099.0))
      ;; It is kept with the session.
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (equal '(:at 1000.0 :ttl 300 :expires 1100.0 :model "hosted:m" :dropped 1100.0)
                     (harness-cache-dropped-test--cache sid)))
      (should (funcall cold 1101.0)))))

(ert-deftest harness-cache-dropped-every-announcement-of-the-reset-says-so ()
  "What the reset announces already holds the cache as dropped.
The state going is announced before the rest is done: a client that
draws the cache from the first announcement must not see it warm."
  (harness-cache-dropped-test-with
    (let* ((sid (harness-cache-dropped-test-session "hosted:m" 1000.0))
           (seen nil))
      (harness-call 'session/set-provider-state sid '(:conv "c1" :provider "hosted"))
      (harness-on 'session/changed
                  (lambda (id plist) (when (equal id sid) (push (plist-get plist :cache) seen))))
      (harness-cache-dropped-test--reset-at sid 1100.0)
      (should seen)
      (dolist (cache seen)
        (should (= 1100.0 (plist-get cache :dropped)))
        (should (= 1100.0 (plist-get cache :expires)))))))

(ert-deftest harness-cache-dropped-a-session-sent-the-transcript-is-not-marked ()
  "A provider sent the whole transcript at every request rebuilds the next one.
Its next request is made from the redacted transcript and still reads
the cache up to the first spot that was redacted, so the cache is not
reported dropped and the reset says nothing of one."
  (harness-cache-dropped-test-with
    (let* ((sid (harness-cache-dropped-test-session "api:m" 1000.0))
           (before (harness-cache-dropped-test--cache sid)))
      (should (equal '(:at 1000.0 :ttl 300 :expires 1300.0 :model "api:m") before))
      (should-not (harness-call 'session/reset-drops-cache-p sid))
      (should (equal '(:checkpoints 0) (harness-cache-dropped-test--reset-at sid 1100.0)))
      (should (equal before (harness-cache-dropped-test--cache sid)))
      (should-not (plist-member (harness-cache-dropped-test--usage sid) :cache-dropped))
      (should-not (harness-cowboy-cold-p (harness-call 'session/get sid) 1101.0)))))

(ert-deftest harness-cache-dropped-a-cache-that-lapsed-before-the-reset-is-reported-as-it-was ()
  "A stamp that had run out before the reset keeps its old `:expires'.
There was nothing left to drop, and the cache panel's \"expired five
minutes after its last use\" stays true: no `:dropped'."
  (harness-cache-dropped-test-with
    (let ((sid (harness-cache-dropped-test-session "hosted:m" 1000.0)))
      (harness-cache-dropped-test--reset-at sid 1400.0)
      (should (equal '(:at 1000.0 :ttl 300 :expires 1300.0 :model "hosted:m")
                     (harness-cache-dropped-test--cache sid)))
      (should (harness-cowboy-cold-p (harness-call 'session/get sid) 1400.0)))))

(ert-deftest harness-cache-dropped-a-session-without-a-cache-or-a-context-is-not-marked ()
  "There is nothing to drop where no request used a cache, or nothing is held."
  (harness-cache-dropped-test-with
    (let ((fresh (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "hosted:m") :id))
          (uncached (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "hosted:m") :id))
          (empty (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "hosted:m") :id)))
      (harness-call 'session/usage-add uncached '(:input 100 :output 10 :context 110))
      ;; A stamp with no context: a request that counted nothing held.
      (harness-call 'session/usage-add empty '(:input 0 :output 0 :cache-read 10 :cache-at 1000.0))
      (dolist (sid (list fresh uncached empty))
        (should-not (harness-call 'session/reset-drops-cache-p sid))
        (should (equal '(:checkpoints 0) (harness-cache-dropped-test--reset-at sid 1100.0)))
        (should-not (plist-member (harness-cache-dropped-test--usage sid) :cache-dropped))
        (should-not (harness-cache-dropped-test--cache sid)))
      (should-error (harness-call 'session/reset-drops-cache-p "no-such-session") :type 'harness-error))))

(ert-deftest harness-cache-dropped-an-earlier-models-cache-is-not-dropped ()
  "A session switched to a hosted loop reports no cache, so none is dropped.
The stamp is the API model's, and the hosted loop starts a conversation
of its own at its next request, sent none of the old one, cached or
not: the reset has no cache to take away, and says none."
  (harness-cache-dropped-test-with
    (let ((sid (harness-cache-dropped-test-session "api:m" 1000.0)))
      (harness-call 'session/update sid :model "hosted:m" :silent t)
      (should-not (harness-cache-dropped-test--cache sid))
      (should-not (harness-call 'session/reset-drops-cache-p sid))
      (should (equal '(:checkpoints 0) (harness-cache-dropped-test--reset-at sid 1100.0)))
      (should-not (plist-member (harness-cache-dropped-test--usage sid) :cache-dropped))
      ;; Switched back, the cache is the API model's own again.
      (harness-call 'session/update sid :model "api:m" :silent t)
      (should (equal '(:at 1000.0 :ttl 300 :expires 1300.0 :model "api:m")
                     (harness-cache-dropped-test--cache sid))))))

(ert-deftest harness-cache-dropped-the-first-drop-is-the-one-that-counts ()
  "A second reset before any request stamped a cache again drops nothing more.
The cache went at the first; the mark keeps that moment, and a reset that
drops no cache says nothing of one."
  (harness-cache-dropped-test-with
    (let ((sid (harness-cache-dropped-test-session "hosted:m" 1000.0)))
      (should (equal '(:checkpoints 0 :cache-dropped t) (harness-cache-dropped-test--reset-at sid 1100.0)))
      (should-not (harness-call 'session/reset-drops-cache-p sid))
      (should (equal '(:checkpoints 0) (harness-cache-dropped-test--reset-at sid 1150.0)))
      (should (= 1100.0 (plist-get (harness-cache-dropped-test--cache sid) :dropped)))
      ;; A request that stamps a cache again lets the next reset drop it.
      (harness-call 'session/usage-add sid '(:input 10 :output 10 :cache-write 3000 :context 3020
                                                :cache-at 2000.0))
      (should (harness-call 'session/reset-drops-cache-p sid))
      (should (equal '(:checkpoints 0 :cache-dropped t) (harness-cache-dropped-test--reset-at sid 2100.0)))
      (should (= 2100.0 (plist-get (harness-cache-dropped-test--cache sid) :dropped))))))

(ert-deftest harness-cache-dropped-a-refused-reset-drops-nothing ()
  "A session that runs a turn is not reset, and its cache is not marked."
  (harness-cache-dropped-test-with
    (let* ((sid (harness-cache-dropped-test-session "hosted:m" 1000.0))
           (before (harness-call 'session/get sid)))
      (harness-register-method 'agent/running (lambda (&optional _sid) t))
      (should-error (harness-call 'session/reset-provider sid) :type 'harness-error)
      (should (equal before (harness-call 'session/get sid))))))

;;;; What clears the mark

(ert-deftest harness-cache-dropped-the-next-request-that-stamps-a-cache-clears-it ()
  "A request that read or wrote the cache stamps a new one, and nothing is dropped any more.
A record without tokens, a turn counted, leaves the mark where it is."
  (harness-cache-dropped-test-with
    (let ((sid (harness-cache-dropped-test-session "hosted:m" 1000.0)))
      (harness-cache-dropped-test--reset-at sid 1100.0)
      (harness-call 'session/usage-add sid '(:turns 1))
      (should (= 1100.0 (plist-get (harness-cache-dropped-test--usage sid) :cache-dropped)))
      (should (equal '(:at 1000.0 :ttl 300 :expires 1100.0 :model "hosted:m" :dropped 1100.0)
                     (harness-cache-dropped-test--cache sid)))
      ;; The new conversation's first request wrote the cache.
      (harness-call 'session/usage-add sid '(:input 3020 :output 10 :cache-write 3000 :context 3030
                                                :cache-at 2000.0))
      (should-not (plist-member (harness-cache-dropped-test--usage sid) :cache-dropped))
      (should (equal '(:at 2000.0 :ttl 300 :expires 2300.0 :model "hosted:m")
                     (harness-cache-dropped-test--cache sid)))
      ;; A turn counted after it changes nothing.
      (harness-call 'session/usage-add sid '(:turns 1))
      (should (equal '(:at 2000.0 :ttl 300 :expires 2300.0 :model "hosted:m")
                     (harness-cache-dropped-test--cache sid))))))

(ert-deftest harness-cache-dropped-a-request-that-used-no-cache-clears-it ()
  "A request that used no cache drops the stamp, and the mark has nothing left to say."
  (harness-cache-dropped-test-with
    (let ((sid (harness-cache-dropped-test-session "hosted:m" 1000.0)))
      (harness-cache-dropped-test--reset-at sid 1100.0)
      (harness-call 'session/usage-add sid '(:input 3020 :output 10 :context 3030))
      (should-not (harness-cache-dropped-test--cache sid))
      (should-not (plist-member (harness-cache-dropped-test--usage sid) :cache-dropped))
      (should-not (plist-member (harness-cache-dropped-test--usage sid) :cache-at)))))

(ert-deftest harness-cache-dropped-a-compaction-clears-it ()
  "A compaction (`:cache-reset') starts the conversation over: the mark goes with the stamp.
The conversation had a cache, so the first request that follows stamps
the new one even when its provider reports no cache tokens, and it
clears nothing it has not already."
  (harness-cache-dropped-test-with
    (let ((sid (harness-cache-dropped-test-session "hosted:m" 1000.0)))
      (harness-cache-dropped-test--reset-at sid 1100.0)
      (let ((u (harness-call 'session/usage-add sid '(:input 900 :output 200 :cache-read 900 :context 200
                                                         :cache-reset t))))
        (should-not (plist-member u :cache-dropped))
        (should-not (plist-member u :cache-at))
        (should (plist-get u :cache-pending)))
      (should-not (harness-cache-dropped-test--cache sid))
      ;; The first request after it stamps the new cache, with no cache tokens to say so.
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 5000.0)))
        (harness-call 'session/usage-add sid '(:input 200 :output 10 :context 210)))
      (should (equal '(:at 5000.0 :ttl 300 :expires 5300.0 :model "hosted:m")
                     (harness-cache-dropped-test--cache sid)))
      (should-not (plist-member (harness-cache-dropped-test--usage sid) :cache-dropped)))))

;;;; Saying so

(defconst harness-cache-dropped-test--session
  '(:id "s1" :model "hosted:m" :head "n1"
    :cache (:at 1000.0 :ttl 300 :expires 1100.0 :model "hosted:m" :dropped 1100.0)
    :usage (:context 3020))
  "A session whose cache a redaction dropped at 1100, 200 seconds early.")

(defconst harness-cache-dropped-test--lapsed
  '(:id "s1" :model "hosted:m" :head "n1"
    :cache (:at 1000.0 :ttl 300 :expires 1300.0 :model "hosted:m")
    :usage (:context 3020))
  "A session whose cache lapsed by itself at 1300.")

(ert-deftest harness-cache-dropped-the-question-says-a-redaction-dropped-the-cache ()
  "The question names the redaction and the time, and compares no cached price.
A cache a redaction dropped cannot be had, so \"about $X instead of
$Y\", what a lapsed one offers, is left out; the rest of the question
is the same."
  (harness-cache-dropped-test-with
    (let ((estimate '(:context 3020 :carry-on 0.5 :carry-on-cached 0.05)))
      (should (equal (concat "Your message waits: a redaction dropped this session's provider conversation at "
                             (harness-cowboy--clock 1100.0) ", so no prompt cache holds it."
                             "  Carrying on sends the whole conversation, ~3.0k tokens, uncached."
                             "  What goes first?  Answer \"always\" with a choice to make it the default"
                             " and stop asking.")
                     (harness-cowboy--question-text harness-cache-dropped-test--session estimate nil)))
      ;; Whoever sent the message is named as ever; so is a note.
      (should (string-prefix-p
               "“x” is not one of the choices.  A message from session \"Reviewer\" waits: a redaction dropped "
               (harness-cowboy--question-text harness-cache-dropped-test--session estimate
                                              '(:kind session :id "abc12345" :name "Reviewer")
                                              "“x” is not one of the choices.")))
      ;; Without an estimate: no tokens named, nothing to compare either.
      (should (string-match-p
               "so no prompt cache holds it\\.  Carrying on sends the whole conversation, ~3\\.0k tokens, uncached\\.  What"
               (harness-cowboy--question-text harness-cache-dropped-test--session nil nil)))
      ;; A cache that lapsed by itself is asked about as ever, with its comparison.
      (let ((text (harness-cowboy--question-text harness-cache-dropped-test--lapsed estimate nil)))
        (should (string-match-p "this session's prompt cache lapsed at .*, [0-9]+ days ago\\." text))
        (should (string-match-p "uncached: about \\$[0-9.]+ instead of \\$[0-9.]+\\." text))
        (should-not (string-match-p "redaction" text))))))

(ert-deftest harness-cache-dropped-the-hint-says-a-redaction-dropped-the-cache ()
  "The hint after the choice opens with the redaction and when it dropped the cache."
  (harness-cache-dropped-test-with
    (let ((clock (harness-cowboy--clock 1100.0)))
      (should (equal (format "Prompt cache dropped at %s by a redaction: carrying on with the whole conversation, ~3.0k tokens uncached, as you chose" clock)
                     (harness-cowboy--hint-text 'carry-on 'user harness-cache-dropped-test--session nil)))
      (should (equal (format "Prompt cache dropped at %s by a redaction: compacting into a brief summary first, the default, as asking is off (harness-cowboy-ask)" clock)
                     (harness-cowboy--hint-text 'brief 'default harness-cache-dropped-test--session nil)))
      ;; A caller's reason opens the hint as ever, and a lapsed cache is as it was.
      (should (string-prefix-p "Redacted: "
                               (harness-cowboy--hint-text 'brief 'cold-start harness-cache-dropped-test--session nil
                                                          "Redacted")))
      (should (string-prefix-p (format "Prompt cache cold since %s: " (harness-cowboy--clock 1300.0))
                               (harness-cowboy--hint-text 'brief 'user harness-cache-dropped-test--lapsed nil))))))

(ert-deftest harness-cache-dropped-a-cache-held-for-another-model-is-told-as-it-was ()
  "A cache held for a model the session no longer uses holds nothing for the new one.
That is what the question and the hint say whether or not a redaction
dropped it as well, and the question keeps the price it compares: the
stale-model texts are as they were."
  (harness-cache-dropped-test-with
    (let ((session (plist-put (copy-sequence harness-cache-dropped-test--session) :model "api:m"))
          (estimate '(:context 3020 :carry-on 0.5 :carry-on-cached 0.05)))
      (should (string-match-p
               (concat "\\`Your message waits: this session's prompt cache is cold\\.  It is held for Hosted M,"
                       " which this session no longer uses, so API M has none of it\\."
                       "  Carrying on sends the whole conversation, ~3\\.0k tokens, uncached"
                       ": about \\$0\\.500 instead of \\$0\\.050\\.")
               (harness-cowboy--question-text session estimate nil)))
      (should-not (string-match-p "redaction" (harness-cowboy--question-text session estimate nil)))
      (should (string-prefix-p "Prompt cache cold: held for Hosted M, not API M: "
                               (harness-cowboy--hint-text 'brief 'user session nil))))))

(ert-deftest harness-cache-dropped-the-payload-carries-the-drop ()
  "The `:cowboy' payload of the question gains `:dropped', the moment, else nil."
  (harness-cache-dropped-test-with
    (let ((sid (harness-cache-dropped-test-session "hosted:m" 1000.0)))
      (let ((info (harness-cowboy--info sid harness-cache-dropped-test--session nil nil 'brief nil)))
        (should (= 1100.0 (plist-get info :dropped)))
        (should (= 1100.0 (plist-get info :expires)))
        (should (= 1000.0 (plist-get info :at)))
        (should (equal "hosted:m" (plist-get info :cache-model))))
      (let ((info (harness-cowboy--info sid harness-cache-dropped-test--lapsed nil nil 'brief nil)))
        (should (plist-member info :dropped))
        (should-not (plist-get info :dropped))
        (should (= 1300.0 (plist-get info :expires)))))))

;;;; The gate

(ert-deftest harness-cache-dropped-the-gate-asks-before-a-reset-session-sends-everything-uncached ()
  "A message to a session whose provider conversation a redaction dropped asks first.
Within the lifetime of the cache the gate asked nothing, and the new
conversation was sent the whole transcript as one uncached message.
Now the question says what happened, the hint after the answer says it
again, and the turn's own usage stamps the new conversation's cache and
clears the mark."
  (harness-cache-dropped-test-with
    (let ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "hosted:m") :id)))
      ;; A first turn: the provider keeps the conversation, and cached it.
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "please refactor the parser") 10)
                                       :stop-reason)))
      (let ((session (harness-call 'session/get sid)))
        (should (plist-get session :provider-state))
        (should (plist-get session :cache))
        (should-not (plist-get (plist-get session :cache) :dropped))
        (should-not (harness-cowboy-cold-p session)))
      ;; A warm cache asks nothing: the next message goes on at once.
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "and the tests") 10)
                                       :stop-reason)))
      (should-not (harness-call 'question/pending sid))
      (should (plist-get (car harness-cache-dropped-test--requests) :provider-state))
      ;; A redaction takes a secret out of it: the provider conversation goes.
      (should (harness-call 'session/reset-drops-cache-p sid))
      (should (equal '(:checkpoints 0 :cache-dropped t) (harness-call 'session/reset-provider sid)))
      (let* ((dropped (plist-get (harness-cache-dropped-test--cache sid) :dropped))
             (clock (harness-cowboy--clock dropped))
             (p (harness-call 'agent/prompt sid "carry on")))
        (should (numberp dropped))
        (should (harness-cowboy-cold-p (harness-call 'session/get sid)))
        (let ((payload (plist-get (harness-cache-dropped-test--question sid) :payload)))
          (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status)))
          (should (equal (concat "Your message waits: a redaction dropped this session's provider conversation at "
                                 clock ", so no prompt cache holds it.  Carrying on sends the whole conversation, ~430 tokens, uncached."
                                 "  What goes first?  Answer \"always\" with a choice to make it the default and stop asking.")
                         (plist-get payload :question)))
          (should (= dropped (plist-get (plist-get payload :cowboy) :dropped))))
        (should-not (harness-promise-settled-p p))
        (harness-call 'question/answer sid (plist-get (harness-cache-dropped-test--question sid) :id)
                      (list :answer "carry on"))
        (should (eq 'end-turn (plist-get (harness-test-await p 10) :stop-reason)))
        (should (member (format "Prompt cache dropped at %s by a redaction: carrying on with the whole conversation, ~430 tokens uncached, as you chose"
                                clock)
                        (harness-cache-dropped-test--hints sid))))
      ;; The new conversation opened with no state of the old one ...
      (should-not (plist-get (car harness-cache-dropped-test--requests) :provider-state))
      ;; ... and its first request wrote a cache of its own: nothing is dropped any more.
      (let ((session (harness-call 'session/get sid)))
        (should (plist-get session :provider-state))
        (should (plist-get session :cache))
        (should-not (plist-get (plist-get session :cache) :dropped))
        (should-not (plist-member (plist-get session :usage) :cache-dropped))
        (should-not (harness-cowboy-cold-p session))))))

(ert-deftest harness-cache-dropped-an-unasked-session-takes-the-default-and-says-why ()
  "Where nobody is asked, the default goes first, and the hint says what dropped the cache."
  (harness-cache-dropped-test-with
    (let ((harness-cowboy-ask nil)
          (harness-cowboy-default 'carry-on)
          (sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "hosted:m") :id)))
      (harness-test-await (harness-call 'agent/prompt sid "please refactor the parser") 10)
      (harness-call 'session/reset-provider sid)
      (let ((clock (harness-cowboy--clock (plist-get (harness-cache-dropped-test--cache sid) :dropped))))
        (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt sid "carry on") 10)
                                         :stop-reason)))
        (should-not (harness-call 'question/pending sid))
        (should (member (format "Prompt cache dropped at %s by a redaction: carrying on with the whole conversation, ~430 tokens uncached, the default, as asking is off (harness-cowboy-ask)"
                                clock)
                        (harness-cache-dropped-test--hints sid)))))))

(provide 'harness-cache-dropped-test)
;;; harness-cache-dropped-test.el ends here
