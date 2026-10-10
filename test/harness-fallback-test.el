;;; harness-fallback-test.el --- Tests for carrying on with another provider  -*- lexical-binding: t; -*-

;;; Commentary:

;; Scripted providers stand in for real ones: `alpha' runs out of money
;; or quota on cue, `beta' carries on, `hosted' runs its own loop the way
;; Claude Code does.  The turn loop, the sessions and the tools are the
;; real ones, so these tests see what a user would: the turn that failed
;; carries on elsewhere, the hints, the marks and the way back.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-openai-endpoints)
(defvar harness-deepseek-always-register)
(declare-function harness-define-provider "harness-provider")

(defvar harness-fallback-test-requests nil
  "Every request the scripted providers got, oldest first.")

(defvar harness-fallback-test-scripts nil
  "Provider id -> function of a request returning its events.")

(defun harness-fallback-test-provider (id models &rest props)
  "Define scripted provider ID listing MODELS.
PROPS: `:tiers', `:capabilities'.  Each request is answered by the
function `harness-fallback-test-scripts' holds for ID, which returns
the events to send, `start' aside."
  (harness-define-provider id
    :label (capitalize (symbol-name id))
    :models (lambda () (harness-resolved models))
    :tiers (plist-get props :tiers)
    :capabilities (plist-get props :capabilities)
    :complete (lambda (request)
                (setq harness-fallback-test-requests (append harness-fallback-test-requests (list request)))
                (let ((on-event (plist-get request :on-event))
                      (events (funcall (alist-get id harness-fallback-test-scripts) request))
                      (cancelled nil))
                  (funcall on-event '(:type start))
                  (run-at-time 0.005 nil (lambda ()
                                           (unless cancelled
                                             (dolist (ev events) (funcall on-event ev)))))
                  (list :cancel (lambda ()
                                  (setq cancelled t)
                                  (funcall on-event '(:type done :stop-reason cancelled))))))))

(defun harness-fallback-test-tool-results-p (request)
  "Non-nil when REQUEST ends with tool results."
  (cl-some (lambda (b) (equal (plist-get b :type) "tool_result"))
           (plist-get (car (last (plist-get request :messages))) :content)))

(defun harness-fallback-test-say (text)
  "Return the events of a reply TEXT that ends the turn."
  (list (list :type 'text :delta text)
        '(:type usage :input 100 :output 10 :cost 0.001)
        '(:type done :stop-reason end-turn)))

(defun harness-fallback-test-fail (text &rest props)
  "Return the events of a request that fails with TEXT and PROPS (`:error-kind' ...)."
  (list (append (list :type 'done :stop-reason 'error :error text) props)))

(defmacro harness-fallback-test-with (&rest body)
  "Run BODY with the state layer, the fallback and the scripted providers.
`alpha' lists a-tiny, a-mid, a-top (its frontier) and a-super (dearer,
named by no tier); `beta' lists b-mini, b-flash and b-pro; `hosted'
runs its own loop.  Each answers \"ok\" until a test scripts it."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider tools session agent fallback))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-fallback--marks)
     (clrhash harness-fallback--moved)
     (clrhash harness-fallback--quotas)
     (clrhash harness-fallback--notified)
     (setq harness-fallback-test-requests nil)
     (let ((harness-fallback-models nil)
           (default-directory dir)
           (harness-fallback-test-scripts
            (list (cons 'alpha (lambda (_) (harness-fallback-test-say "ok from alpha")))
                  (cons 'beta (lambda (_) (harness-fallback-test-say "ok from beta")))
                  (cons 'hosted (lambda (_) (harness-fallback-test-say "ok from hosted"))))))
       (harness-fallback-test-provider
        'alpha '((:name "a-tiny" :pricing (:input 1.0 :output 2.0))
                 (:name "a-mid" :pricing (:input 3.0 :output 6.0))
                 (:name "a-top" :label "Alpha Top" :pricing (:input 5.0 :output 10.0))
                 (:name "a-super" :label "Alpha Super" :pricing (:input 10.0 :output 50.0)))
        :tiers '(:balanced "a-mid" :frontier "a-top"))
       (harness-fallback-test-provider
        'beta '((:name "b-mini" :pricing (:input 0.1 :output 0.2))
                (:name "b-flash" :label "Beta Flash" :pricing (:input 0.2 :output 0.4))
                (:name "b-pro" :label "Beta Pro" :pricing (:input 0.6 :output 1.2)))
        :tiers '(:cheap "b-mini" :balanced "b-flash" :frontier "b-pro"))
       (harness-fallback-test-provider
        'hosted '((:name "h-one" :label "Hosted One" :pricing (:input 1.0 :output 2.0)))
        :capabilities '(:hosted-loop t))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (harness-define-tool "list_dir" :label "List directory" :description "list" :kind 'read
                            :handler (lambda (input _ctx) (format "listing of %s" (plist-get input :path))))
       (unwind-protect (progn ,@body)
         (harness-fallback--shutdown)))))

(defun harness-fallback-test-session (model)
  "Create a session on MODEL and return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model model) :id))

(defun harness-fallback-test-prompt (sid text)
  "Send TEXT to session SID and return how its turn ended."
  (harness-test-await (harness-call 'agent/prompt sid text) 10))

(defun harness-fallback-test-hints (sid)
  "Return the hint texts of session SID, oldest first."
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'hint)) (harness-call 'session/nodes sid))))

(defun harness-fallback-test-models-asked ()
  "Return the model of every request so far, oldest first."
  (mapcar (lambda (r) (plist-get r :model)) harness-fallback-test-requests))

;;;; Telling a failure apart

(ert-deftest harness-fallback-error-kind-reads-providers-and-text ()
  "A provider's own kind decides; otherwise the error's text, conservatively."
  (cl-flet ((kind (&rest failure) (harness-fallback-error-kind failure)))
    (should (eq 'quota (kind :error-kind 'quota :error "whatever")))
    (should (eq 'billing (kind :error-kind "billing")))
    ;; The provider says it is something else: the text does not overrule it.
    (should-not (kind :error-kind 'rate-limit :error "Claude AI usage limit reached|1760000000"))
    (should-not (kind :error-kind "auth" :error "HTTP 402: Insufficient Balance"))
    ;; Running out of money.
    (should (eq 'billing (kind :error "HTTP 402: Insufficient Balance")))
    (should (eq 'billing (kind :error "HTTP 429: You exceeded your current quota, please check your plan and billing details.")))
    (should (eq 'billing (kind :error "Your credit balance is too low to access the Anthropic API.")))
    (should (eq 'billing (kind :error "HTTP 402: Insufficient credits. Add more using https://openrouter.ai/settings/credits")))
    (should (eq 'billing (kind :error "Copilot: You have no AI credits left")))
    ;; A used-up quota.
    (should (eq 'quota (kind :error "Claude AI usage limit reached|1760000000")))
    (should (eq 'quota (kind :error "You've hit your limit · resets 3pm (Europe/Berlin)")))
    (should (eq 'quota (kind :error "5-hour limit reached ∙ resets 3pm")))
    (should (eq 'quota (kind :error "Weekly limit reached ∙ resets Oct 9, 3pm")))
    (should (eq 'quota (kind :error "ThrottlingException: Too many tokens per day, please wait before trying again.")))
    ;; Not running out: a short-term rate limit, an outage, a long prompt.
    (should-not (kind :error "HTTP 429: Rate limit reached for gpt-5 in organization org-x on tokens per min (TPM)"))
    (should-not (kind :error "API Error: 529 Overloaded"))
    (should-not (kind :error "prompt is too long: 210000 tokens > 200000 maximum"))
    (should-not (kind :error "claude exited with status 1"))
    (should-not (kind :error nil))))

;;;; Models of similar ability

(ert-deftest harness-fallback-tiers-map-models-across-providers ()
  "A model's tier is the one its provider names it for, else its price's."
  (harness-fallback-test-with
    (should (eq :frontier (harness-provider-model-tier "alpha:a-top")))
    (should (eq :balanced (harness-provider-model-tier "alpha:a-mid")))
    ;; Named by no tier: the dearest third is frontier, the cheapest cheap.
    (should (eq :frontier (harness-provider-model-tier "alpha:a-super")))
    (should (eq :cheap (harness-provider-model-tier "alpha:a-tiny")))
    (should (eq :balanced (harness-provider-model-tier "nowhere:model")))
    (should (eq 'frontier (harness-call 'provider/model-tier "alpha:a-super")))
    ;; A provider id stands for the provider.
    (should (equal "beta:b-pro" (harness-call 'provider/tier-model "beta" 'frontier)))
    (should (equal "beta:b-mini" (harness-provider-tier-model 'beta)))
    (should (equal "beta:b-pro" (harness-fallback--entry-model "beta" "alpha:a-super")))
    (should (equal "beta:b-flash" (harness-fallback--entry-model "beta" "alpha:a-mid")))
    (should (equal "beta:b-mini" (harness-fallback--entry-model "beta" "alpha:a-tiny")))
    ;; A model id is itself.
    (should (equal "beta:b-mini" (harness-fallback--entry-model "beta:b-mini" "alpha:a-super")))))

(ert-deftest harness-fallback-claude-maps-to-deepseek ()
  "The real catalogues: Claude's models land on DeepSeek's of the same tier."
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (let ((harness-openai-endpoints nil)
          (harness-deepseek-always-register t))
      (dolist (m '(store provider provider-claude provider-openai provider-deepseek fallback))
        (harness-test-load-module m))
      (unwind-protect
          (progn
            (should (eq :frontier (harness-provider-model-tier "claude:claude-fable-5-1")))
            (should (eq :frontier (harness-provider-model-tier "claude:claude-opus-5-5")))
            (should (eq :balanced (harness-provider-model-tier "claude:claude-sonnet-5")))
            (should (eq :cheap (harness-provider-model-tier "claude:claude-haiku-4-5-20251001")))
            (should (eq :balanced (harness-provider-model-tier "deepseek:deepseek-flash")))
            (should (equal "deepseek:deepseek-v4-pro" (harness-fallback--entry-model "deepseek" "claude:claude-fable-5-1")))
            (should (equal "deepseek:deepseek-flash" (harness-fallback--entry-model "deepseek" "claude:claude-sonnet-5")))
            (should (equal "claude:claude-sonnet-5" (harness-fallback--entry-model "claude" "deepseek:deepseek-flash"))))
        (harness-provider-unregister 'deepseek)
        (harness-fallback--shutdown)))))

;;;; Carrying on

(ert-deftest harness-fallback-failed-step-carries-on-elsewhere ()
  "A provider out of money mid-turn: the turn carries on with the next one.
The fallback gets the whole transcript, the tool result included, and
the session remembers its own model."
  (harness-fallback-test-with
    (setq harness-fallback-models '("beta"))
    (setf (alist-get 'alpha harness-fallback-test-scripts)
          (lambda (request)
            (if (harness-fallback-test-tool-results-p request)
                (harness-fallback-test-fail "HTTP 402: Insufficient Balance")
              (list '(:type text :delta "Looking first.")
                    (list :type 'tool-call :id "t1" :name "list_dir" :input (list :path "."))
                    '(:type done :stop-reason tool-use)))))
    (let* ((sid (harness-fallback-test-session "alpha:a-super"))
           (switched nil))
      (harness-on 'fallback/switched (lambda (&rest args) (push args switched)))
      (should (eq 'end-turn (plist-get (harness-fallback-test-prompt sid "look around") :stop-reason)))
      ;; Two steps on alpha, then its frontier's match at beta.
      (should (equal '("alpha:a-super" "alpha:a-super" "beta:b-pro") (harness-fallback-test-models-asked)))
      (should (equal "beta:b-pro" (plist-get (harness-call 'session/get sid) :model)))
      (should (equal (list (list sid "alpha:a-super" "beta:b-pro" 'out)) switched))
      ;; beta saw the tool call alpha made and its result.
      (let ((sent (plist-get (car (last harness-fallback-test-requests)) :messages)))
        (should (harness-fallback-test-tool-results-p (car (last harness-fallback-test-requests))))
        (should (cl-some (lambda (m) (cl-some (lambda (b) (equal (plist-get b :name) "list_dir"))
                                              (plist-get m :content)))
                         sent)))
      (let ((hints (harness-fallback-test-hints sid)))
        (should (cl-some (lambda (h) (string-match-p "Error: HTTP 402" h)) hints))
        (should (cl-some (lambda (h) (string-match-p "Alpha is out of money, so this session carries on with Beta Pro" h))
                         hints))
        ;; The switch is the fallback's own hint, not the generic "model →" one.
        (should-not (cl-some (lambda (h) (string-prefix-p "model →" h)) hints)))
      (let ((status (harness-call 'fallback/status)))
        (should (eq t (plist-get status :enabled)))
        (should (equal '("alpha") (mapcar (lambda (m) (plist-get m :key)) (plist-get status :marks))))
        (should (eq 'billing (plist-get (car (plist-get status :marks)) :kind)))
        (should (eq t (plist-get (car (plist-get status :marks)) :guess)))
        (should (equal (list (list :session sid :original "alpha:a-super" :model "beta:b-pro"))
                       (plist-get status :moved))))
      ;; The next turn stays on beta: alpha is still out.
      (setq harness-fallback-test-requests nil)
      (should (eq 'end-turn (plist-get (harness-fallback-test-prompt sid "more") :stop-reason)))
      (should (equal '("beta:b-pro") (harness-fallback-test-models-asked))))))

(ert-deftest harness-fallback-out-provider-is-skipped-before-the-turn ()
  "A model known to be out never gets the request: the turn starts elsewhere."
  (harness-fallback-test-with
    (setq harness-fallback-models '("beta:b-flash"))
    (harness-call 'fallback/mark "alpha" :until (+ (float-time) 3600) :reason "5h window used up")
    (let ((sid (harness-fallback-test-session "alpha:a-mid")))
      (should (eq 'end-turn (plist-get (harness-fallback-test-prompt sid "hello") :stop-reason)))
      (should (equal '("beta:b-flash") (harness-fallback-test-models-asked)))
      (should (cl-some (lambda (h) (string-match-p "Alpha is out of quota until [0-9]+:[0-9]+, so this session carries on with Beta Flash" h))
                       (harness-fallback-test-hints sid))))))

(ert-deftest harness-fallback-goes-back-once-its-own-model-works ()
  "A moved session returns to its own model when that works again,
and forgets it when someone picks a model by hand."
  (harness-fallback-test-with
    (setq harness-fallback-models '("beta"))
    (setf (alist-get 'alpha harness-fallback-test-scripts)
          (lambda (_) (harness-fallback-test-fail "Claude AI usage limit reached" :error-kind 'quota
                                                 :resets (+ (float-time) 600))))
    (let ((sid (harness-fallback-test-session "alpha:a-mid")))
      (harness-fallback-test-prompt sid "one")
      (should (equal "beta:b-flash" (plist-get (harness-call 'session/get sid) :model)))
      ;; The reset time the provider gave is the mark's end.
      (let ((mark (car (plist-get (harness-call 'fallback/status) :marks))))
        (should (eq :false (plist-get mark :guess)))
        (should (< (abs (- (plist-get mark :until) (+ (float-time) 600))) 5)))
      ;; Alpha works again.
      (setf (alist-get 'alpha harness-fallback-test-scripts)
            (lambda (_) (harness-fallback-test-say "alpha is back")))
      (should (harness-call 'fallback/clear "alpha"))
      (should-not (harness-call 'fallback/clear "alpha"))
      (setq harness-fallback-test-requests nil)
      (harness-fallback-test-prompt sid "two")
      (should (equal '("alpha:a-mid") (harness-fallback-test-models-asked)))
      (should (equal "alpha:a-mid" (plist-get (harness-call 'session/get sid) :model)))
      (should (cl-some (lambda (h) (string-match-p "Alpha works again, so this session goes back to a-mid" h))
                       (harness-fallback-test-hints sid)))
      (should-not (plist-get (harness-call 'fallback/status) :moved))
      ;; Moved again, then a model chosen by hand: that one sticks.
      (harness-call 'fallback/mark "alpha")
      (harness-fallback-test-prompt sid "three")
      (should (equal "beta:b-flash" (plist-get (harness-call 'session/get sid) :model)))
      (should (plist-get (harness-call 'fallback/status) :moved))
      (harness-call 'session/update sid :model "beta:b-mini")
      (should-not (plist-get (harness-call 'fallback/status) :moved))
      (harness-call 'fallback/clear "alpha")
      (setq harness-fallback-test-requests nil)
      (harness-fallback-test-prompt sid "four")
      (should (equal '("beta:b-mini") (harness-fallback-test-models-asked))))))

(ert-deftest harness-fallback-prefers-the-first-entry-that-works ()
  "The list is an order of preference: a session on a lower entry runs on
the first entry that works, goes back to its own model when that entry
runs out, and moves up again once the entry comes back."
  (harness-fallback-test-with
    (setq harness-fallback-models '("beta" "alpha"))
    (let ((sid (harness-fallback-test-session "alpha:a-mid"))
          (switched nil))
      (harness-on 'fallback/switched (lambda (&rest args) (push args switched)))
      ;; beta is the first entry, so the turn runs there, not on alpha.
      (should (eq 'end-turn (plist-get (harness-fallback-test-prompt sid "one") :stop-reason)))
      (should (equal '("beta:b-flash") (harness-fallback-test-models-asked)))
      (should (equal "beta:b-flash" (plist-get (harness-call 'session/get sid) :model)))
      (should (equal (list (list sid "alpha:a-mid" "beta:b-flash" 'up)) (nreverse switched)))
      (should (cl-some (lambda (h) (string-match-p "Beta works again, so this session goes back up to Beta Flash" h))
                       (harness-fallback-test-hints sid)))
      ;; beta runs out: its own model carries on, and says why.
      (harness-call 'fallback/mark "beta" :kind 'billing :reason "Insufficient Balance")
      (setq harness-fallback-test-requests nil)
      (should (eq 'end-turn (plist-get (harness-fallback-test-prompt sid "two") :stop-reason)))
      (should (equal '("alpha:a-mid") (harness-fallback-test-models-asked)))
      (should (equal "alpha:a-mid" (plist-get (harness-call 'session/get sid) :model)))
      (should (cl-some (lambda (h) (string-match-p "Beta is out of money, so this session carries on with a-mid" h))
                       (harness-fallback-test-hints sid)))
      ;; beta works again: the next turn moves up, and stays there.
      (should (harness-call 'fallback/clear "beta"))
      (setq harness-fallback-test-requests nil)
      (should (eq 'end-turn (plist-get (harness-fallback-test-prompt sid "three") :stop-reason)))
      (should (equal '("beta:b-flash") (harness-fallback-test-models-asked)))
      (should (equal (list (list sid "alpha:a-mid" "beta:b-flash" 'up)
                           (list sid "beta:b-flash" "alpha:a-mid" 'out)
                           (list sid "alpha:a-mid" "beta:b-flash" 'up))
                     (nreverse switched))))))

(ert-deftest harness-fallback-goes-back-up-once-a-quota-comes-back ()
  "A mark that ends on its own lets the session move back up: the
preferred entry is used again on the turn after its quota resets."
  (harness-fallback-test-with
    (setq harness-fallback-models '("beta" "alpha"))
    (harness-call 'fallback/mark "beta" :until (+ (float-time) 1.2) :reason "5h window used up")
    (let ((sid (harness-fallback-test-session "alpha:a-mid")))
      ;; The first entry is out, so its own model runs and nothing moves.
      (should (eq 'end-turn (plist-get (harness-fallback-test-prompt sid "one") :stop-reason)))
      (should (equal '("alpha:a-mid") (harness-fallback-test-models-asked)))
      (should (equal "alpha:a-mid" (plist-get (harness-call 'session/get sid) :model)))
      ;; The window resets: the mark ends on its own, and the turn after
      ;; it goes back up without anyone clearing it.
      (harness-test-wait (lambda () (not (gethash "beta" harness-fallback--marks))) 5 "the mark to end")
      (setq harness-fallback-test-requests nil)
      (should (eq 'end-turn (plist-get (harness-fallback-test-prompt sid "two") :stop-reason)))
      (should (equal '("beta:b-flash") (harness-fallback-test-models-asked)))
      (should (equal "beta:b-flash" (plist-get (harness-call 'session/get sid) :model)))
      (should (cl-some (lambda (h) (string-match-p "Beta works again, so this session goes back up to Beta Flash" h))
                       (harness-fallback-test-hints sid))))))

(ert-deftest harness-fallback-unlisted-provider-keeps-its-own-model-first ()
  "A session whose provider the list does not name runs on its own model
first, the list behind it: the order is a preference among the providers
it names, a fallback for the rest."
  (harness-fallback-test-with
    (setq harness-fallback-models '("beta"))
    (let ((sid (harness-fallback-test-session "alpha:a-mid"))
          (switched nil))
      (harness-on 'fallback/switched (lambda (&rest args) (push args switched)))
      (should (eq 'end-turn (plist-get (harness-fallback-test-prompt sid "hello") :stop-reason)))
      (should (equal '("alpha:a-mid") (harness-fallback-test-models-asked)))
      (should (equal "alpha:a-mid" (plist-get (harness-call 'session/get sid) :model)))
      (should-not switched)
      (should-not (plist-get (harness-call 'fallback/status) :moved)))))

(ert-deftest harness-fallback-stops-when-nothing-is-left ()
  "Every provider out: the turn ends with its error and says what is out."
  (harness-fallback-test-with
    (setq harness-fallback-models '("alpha" "beta"))
    (setf (alist-get 'alpha harness-fallback-test-scripts)
          (lambda (_) (harness-fallback-test-fail "usage limit reached" :error-kind 'quota)))
    (setf (alist-get 'beta harness-fallback-test-scripts)
          (lambda (_) (harness-fallback-test-fail "HTTP 402: Insufficient Balance" :error-kind 'billing)))
    (let ((sid (harness-fallback-test-session "alpha:a-top")))
      (let ((result (harness-fallback-test-prompt sid "go")))
        (should (eq 'error (plist-get result :stop-reason)))
        (should (string-match-p "402" (plist-get result :error))))
      ;; alpha's own model, then beta; alpha's entry adds nothing once alpha is out.
      (should (equal '("alpha:a-top" "beta:b-pro") (harness-fallback-test-models-asked)))
      (should (cl-some (lambda (h) (string-match-p "\\`Nothing left to carry on with: .*Alpha is out of quota.*Beta is out of money" h))
                       (harness-fallback-test-hints sid)))
      (should (equal '("alpha" "beta")
                     (sort (mapcar (lambda (m) (plist-get m :key)) (plist-get (harness-call 'fallback/status) :marks))
                           #'string<))))))

(ert-deftest harness-fallback-off-still-notices-and-says-where-to-turn-it-on ()
  "Without a fallback list the session stays put, its provider is marked
and the hint points at the dashboard."
  (harness-fallback-test-with
    (setf (alist-get 'alpha harness-fallback-test-scripts)
          (lambda (_) (harness-fallback-test-fail "You've hit your limit · resets 3pm")))
    (let ((sid (harness-fallback-test-session "alpha:a-mid")))
      (should (eq 'error (plist-get (harness-fallback-test-prompt sid "go") :stop-reason)))
      (should (equal '("alpha:a-mid") (harness-fallback-test-models-asked)))
      (should (equal "alpha:a-mid" (plist-get (harness-call 'session/get sid) :model)))
      (should (eq :false (plist-get (harness-call 'fallback/status) :enabled)))
      (should (equal '("alpha") (mapcar (lambda (m) (plist-get m :key))
                                        (plist-get (harness-call 'fallback/status) :marks))))
      (should (cl-some (lambda (h) (string-match-p "usage dashboard" h)) (harness-fallback-test-hints sid))))))

(ert-deftest harness-fallback-other-failures-end-the-turn-as-before ()
  "A failure that is not running out is not retried anywhere."
  (harness-fallback-test-with
    (setq harness-fallback-models '("beta"))
    (setf (alist-get 'alpha harness-fallback-test-scripts)
          (lambda (_) (harness-fallback-test-fail "API Error: 529 Overloaded")))
    (let ((sid (harness-fallback-test-session "alpha:a-mid")))
      (should (eq 'error (plist-get (harness-fallback-test-prompt sid "go") :stop-reason)))
      (should (equal '("alpha:a-mid") (harness-fallback-test-models-asked)))
      (should-not (plist-get (harness-call 'fallback/status) :marks)))))

;;;; Quota reports

(ert-deftest harness-fallback-quota-reports-mark-and-unmark ()
  "A used-up plan window marks its provider until it resets; extra usage
paying for calls, or the window coming back, lifts the mark."
  (harness-fallback-test-with
    (let ((reset (+ (float-time) 900)))
      (harness-emit 'provider/quota-updated 'alpha
                    (list :billing 'subscription
                          :windows (list (list :name "5h" :label "Current session (5 hours)" :used 1.0 :resets reset)
                                         (list :name "7d" :used 0.4 :resets (+ reset 86400)))))
      (let ((mark (gethash "alpha" harness-fallback--marks)))
        (should mark)
        (should (eq 'quota (plist-get mark :source)))
        (should (= reset (plist-get mark :until)))
        (should (string-match-p "Current session (5 hours) is used up" (plist-get mark :reason))))
      (should (harness-fallback-out-p "alpha:a-mid"))
      ;; Extra usage pays for calls past the window: nothing is out.
      (harness-emit 'provider/quota-updated 'alpha
                    (list :windows (list (list :name "5h" :used 1.0 :resets reset))
                          :extra (list :enabled t :used 3.0 :limit 50.0)))
      (should-not (harness-fallback-out-p "alpha:a-mid"))
      ;; Extra usage spent too: out again.
      (harness-emit 'provider/quota-updated 'alpha
                    (list :windows (list (list :name "5h" :used 1.0 :resets reset))
                          :extra (list :enabled t :used 50.0 :limit 50.0)))
      (should (harness-fallback-out-p "alpha:a-mid"))
      ;; The window came back.
      (harness-emit 'provider/quota-updated 'alpha (list :windows (list (list :name "5h" :used 0.02 :resets reset))))
      (should-not (harness-fallback-out-p "alpha:a-mid"))
      ;; A window that has reset already says nothing.
      (harness-emit 'provider/quota-updated 'alpha
                    (list :windows (list (list :name "5h" :used 1.0 :resets (- (float-time) 10)))))
      (should-not (harness-fallback-out-p "alpha:a-mid")))))

(ert-deftest harness-fallback-window-scoped-to-a-model-marks-that-model ()
  "A used-up window of one model leaves the provider's others: the
provider's entry carries on with its other model of the same tier."
  (harness-fallback-test-with
    (setq harness-fallback-models '("alpha" "beta"))
    (harness-emit 'provider/quota-updated 'alpha
                  (list :windows (list (list :name "7d Super" :label "This week, Super" :model "Super"
                                             :used 1.0 :resets (+ (float-time) 3600))
                                       (list :name "7d" :used 0.6 :resets (+ (float-time) 3600)))))
    (should (gethash "alpha:a-super" harness-fallback--marks))
    (should-not (gethash "alpha" harness-fallback--marks))
    (should (harness-fallback-out-p "alpha:a-super"))
    (should-not (harness-fallback-out-p "alpha:a-top"))
    (let ((sid (harness-fallback-test-session "alpha:a-super")))
      (harness-fallback-test-prompt sid "hello")
      ;; a-super is frontier by price; alpha's named frontier is a-top.
      (should (equal '("alpha:a-top") (harness-fallback-test-models-asked)))
      (should (cl-some (lambda (h) (string-match-p "Alpha Super is out of quota until" h))
                       (harness-fallback-test-hints sid))))))

(ert-deftest harness-fallback-failure-reset-comes-from-the-quota-report ()
  "A quota failure without a reset time takes the report's, and a report
scoping the used-up window to one model narrows a whole-provider mark."
  (harness-fallback-test-with
    (let ((reset (+ (float-time) 1200)))
      (harness-emit 'provider/quota-updated 'alpha
                    (list :windows (list (list :name "5h" :used 1.0 :resets reset))))
      (harness-call 'fallback/clear "alpha")
      (harness-fallback--record-failure "alpha:a-mid" 'quota '(:error "usage limit reached"))
      (let ((mark (gethash "alpha" harness-fallback--marks)))
        (should (= reset (plist-get mark :until)))
        (should-not (plist-get mark :guess))
        (should (eq 'error (plist-get mark :source))))
      ;; A later report: only a window scoped to a-super is used up.
      (harness-emit 'provider/quota-updated 'alpha
                    (list :windows (list (list :name "5h" :used 0.5 :resets reset)
                                         (list :name "7d Super" :model "Super" :used 1.0 :resets reset))))
      (should-not (gethash "alpha" harness-fallback--marks))
      (should (gethash "alpha:a-super" harness-fallback--marks)))))

;;;; Marks

(ert-deftest harness-fallback-marks-persist-and-expire ()
  "Marks survive a restart until they end; ending one is announced."
  (harness-fallback-test-with
    (harness-call 'fallback/mark "alpha" :kind "billing" :reason "Insufficient Balance")
    (harness-call 'fallback/mark "beta:b-pro" :until (+ (float-time) 1.2))
    (puthash "gone" (list :key "gone" :until (- (float-time) 1)) harness-fallback--marks)
    (let ((sid (harness-fallback-test-session "alpha:a-mid")))
      (puthash sid (list :original "alpha:a-mid" :since (float-time)) harness-fallback--moved)
      (harness-fallback--save)
      (clrhash harness-fallback--marks)
      (clrhash harness-fallback--moved)
      (harness-fallback--load)
      (should (eq 'billing (plist-get (gethash "alpha" harness-fallback--marks) :kind)))
      (should (eq 'error (plist-get (gethash "alpha" harness-fallback--marks) :source)))
      (should (plist-get (gethash "alpha" harness-fallback--marks) :guess))
      (should (gethash "beta:b-pro" harness-fallback--marks))
      (should-not (gethash "gone" harness-fallback--marks))
      (should (equal "alpha:a-mid" (plist-get (gethash sid harness-fallback--moved) :original))))
    ;; The short mark ends on its own, and says so.
    (let ((changed 0))
      (harness-on 'fallback/changed (lambda () (cl-incf changed)))
      (harness-fallback--schedule)
      (harness-test-wait (lambda () (not (gethash "beta:b-pro" harness-fallback--marks))) 5 "the mark to end")
      (should (> changed 0))
      (should (gethash "alpha" harness-fallback--marks)))
    ;; A provider's clear takes its models' marks along.
    (harness-call 'fallback/mark "alpha:a-top")
    (harness-call 'fallback/clear "alpha")
    (should-not (gethash "alpha:a-top" harness-fallback--marks))))

(ert-deftest harness-fallback-status-describes-entries ()
  "The status names each entry, what it stands for and whether it is out."
  (harness-fallback-test-with
    (setq harness-fallback-models '("beta" "alpha:a-top" "nowhere:model" "alpha:no-such"))
    (harness-call 'fallback/mark "beta" :kind 'billing)
    (let* ((status (harness-call 'fallback/status))
           (entries (plist-get status :models))
           (beta (nth 0 entries)) (top (nth 1 entries)) (nowhere (nth 2 entries)) (typo (nth 3 entries)))
      (should (equal "Beta" (plist-get beta :label)))
      (should (null (plist-get beta :model)))
      (should (eq 'billing (plist-get (plist-get beta :mark) :kind)))
      (should (equal '("cheap" "balanced" "frontier")
                     (mapcar (lambda (tier) (plist-get tier :tier)) (plist-get beta :tiers))))
      (should (equal "beta:b-pro" (plist-get (nth 2 (plist-get beta :tiers)) :model)))
      (should (equal "Alpha Top" (plist-get top :label)))
      (should (eq t (plist-get top :registered)))
      (should-not (plist-get top :mark))
      (should (eq :false (plist-get nowhere :registered)))
      (should (eq :false (plist-get typo :known))))))

;;;; Forks

(ert-deftest harness-fallback-fork-keeps-its-parents-own-model ()
  (harness-fallback-test-with
    (setq harness-fallback-models '("beta"))
    (harness-call 'fallback/mark "alpha")
    (let ((sid (harness-fallback-test-session "alpha:a-mid")))
      (harness-fallback-test-prompt sid "hello")
      (let ((child (plist-get (harness-test-await (harness-call 'session/fork sid)) :id)))
        (should (equal "alpha:a-mid" (plist-get (gethash child harness-fallback--moved) :original)))
        (harness-call 'fallback/clear "alpha")
        (setq harness-fallback-test-requests nil)
        (harness-fallback-test-prompt child "and you")
        (should (equal '("alpha:a-mid") (harness-fallback-test-models-asked)))))))

;;;; Handing a conversation to a hosted loop

(ert-deftest harness-fallback-hosted-loop-gets-what-it-missed ()
  "A provider running its own loop is told what another model did meanwhile."
  (harness-fallback-test-with
    (setf (alist-get 'alpha harness-fallback-test-scripts)
          (lambda (request)
            (if (harness-fallback-test-tool-results-p request)
                (harness-fallback-test-say "The project has three files.")
              (list (list :type 'tool-call :id "t1" :name "list_dir" :input (list :path "src"))
                    '(:type done :stop-reason tool-use)))))
    (let ((sid (harness-fallback-test-session "hosted:h-one"))
          (outside (lambda (sid call-id)
                     ;; Work the harness ran and recorded on its own (the
                     ;; merge queue's resolver): no model's, never handed over.
                     (let ((from (harness-sender-system "merge queue")))
                       (harness-call 'session/append sid (list :kind 'tool-call :tool "spawn_agent" :call-id call-id
                                                               :input '(:name "Merge child" :prompt "resolve it")
                                                               :meta (list :from from :child-id "r1")))
                       (harness-call 'session/append sid (list :kind 'tool-result :call-id call-id
                                                               :output "Resolved the merge."
                                                               :meta (list :from from :child-id "r1")))))))
      (harness-fallback-test-prompt sid "first, on hosted")
      ;; By hand to alpha, then back to hosted.
      (harness-call 'session/update sid :model "alpha:a-mid")
      (harness-fallback-test-prompt sid "look at src")
      (funcall outside sid "m1")
      (harness-call 'session/update sid :model "hosted:h-one")
      (setq harness-fallback-test-requests nil)
      (harness-fallback-test-prompt sid "what did you find?")
      (let* ((messages (plist-get (car harness-fallback-test-requests) :messages))
             (blocks (plist-get (car messages) :content))
             (text (plist-get (car blocks) :text)))
        (should (= 1 (length messages)))
        (should (string-match-p "went on with alpha:a-mid" text))
        (should (string-match-p "User: look at src" text))
        (should (string-match-p "Tool call list_dir: {\"path\":\"src\"}" text))
        (should (string-match-p "Tool result: listing of src" text))
        (should (string-match-p "Assistant (alpha:a-mid): The project has three files\\." text))
        (should (string-match-p "The newest message follows" text))
        ;; Its own earlier turn is not repeated; the new message comes as it is.
        (should-not (string-match-p "first, on hosted" text))
        (should-not (string-match-p "spawn_agent\\|Resolved the merge" text))
        (should (equal "what did you find?" (plist-get (cadr blocks) :text))))
      ;; Caught up: the next request carries the new message only, even
      ;; after more of the harness's own work.
      (funcall outside sid "m2")
      (setq harness-fallback-test-requests nil)
      (harness-fallback-test-prompt sid "thanks")
      (let ((messages (plist-get (car harness-fallback-test-requests) :messages)))
        (should-not (string-match-p "unavailable" (format "%S" messages)))))))

(ert-deftest harness-fallback-into-a-hosted-loop-mid-turn ()
  "A step that fails mid-turn retried on a hosted loop: the tool calls so
far are handed over and the model is asked to carry on."
  (harness-fallback-test-with
    (setq harness-fallback-models '("hosted"))
    (setf (alist-get 'alpha harness-fallback-test-scripts)
          (lambda (request)
            (if (harness-fallback-test-tool-results-p request)
                (harness-fallback-test-fail "HTTP 402: Insufficient Balance")
              (list (list :type 'tool-call :id "t1" :name "list_dir" :input (list :path "lib"))
                    '(:type done :stop-reason tool-use)))))
    (let ((sid (harness-fallback-test-session "alpha:a-mid")))
      (should (eq 'end-turn (plist-get (harness-fallback-test-prompt sid "survey lib") :stop-reason)))
      (should (equal '("alpha:a-mid" "alpha:a-mid" "hosted:h-one") (harness-fallback-test-models-asked)))
      (let* ((messages (plist-get (car (last harness-fallback-test-requests)) :messages))
             (blocks (plist-get (car messages) :content))
             (text (plist-get (car blocks) :text)))
        (should (= 1 (length messages)))
        (should (= 1 (length blocks)))
        (should (string-match-p "User: survey lib" text))
        (should (string-match-p "Tool result: listing of lib" text))
        (should (string-match-p "Carry on with the task from where it stopped" text))))))

(ert-deftest harness-fallback-handoff-is-bounded ()
  "Long items are cut, and the oldest go when the whole would be too long."
  (harness-fallback-test-with
    (let* ((harness-agent--handoff-item-chars 50)
           (harness-agent--handoff-max-chars 300)
           (nodes (cl-loop for i from 1 to 20
                           collect (list :kind 'user :content (format "message %d %s" i (make-string 80 ?x)))))
           (text (harness-agent--handoff-text nodes '("alpha:a-mid") t)))
      (should (string-match-p "earlier items left out" text))
      (should (string-match-p "message 20" text))
      (should-not (string-match-p "message 1 " text))
      (should (string-match-p "more characters" text)))))

;;;; The agent's retry

(ert-deftest harness-fallback-agent-retries-are-capped ()
  "A handler that always asks for another try cannot loop forever."
  (harness-fallback-test-with
    (harness-remove-filter 'agent/step-error #'harness-fallback--step-error)
    (harness-add-filter 'agent/step-error (lambda (_v next &rest _) (funcall next '(:retry t))))
    (setf (alist-get 'alpha harness-fallback-test-scripts)
          (lambda (_) (harness-fallback-test-fail "API Error: 500")))
    (let ((sid (harness-fallback-test-session "alpha:a-mid")))
      (should (eq 'error (plist-get (harness-fallback-test-prompt sid "go") :stop-reason)))
      (should (= (1+ harness-agent--max-error-retries) (length harness-fallback-test-requests))))))

(provide 'harness-fallback-test)
;;; harness-fallback-test.el ends here
