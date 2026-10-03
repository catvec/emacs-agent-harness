;;; harness-provider-test.el --- Tests for the provider registry and catalogue  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-providers)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-provider--forget "harness-provider")

(defmacro harness-provider-test-with (providers &rest body)
  "Load the provider module into a fresh bus, run BODY, then drop PROVIDERS.
PROVIDERS lists the ids of the providers BODY defines."
  (declare (indent 1))
  `(progn
     (harness-test-reset-bus)
     (harness-test-load-module 'provider)
     (unwind-protect (progn ,@body)
       (dolist (id ',providers)
         (remhash id harness-providers)
         (harness-provider--forget id)))))

(defun harness-provider-test-static (id windows &optional calls)
  "Define provider ID, listing at once a model per (NAME . WINDOW) in WINDOWS.
When CALLS, a cons, is given, its car counts how often ID is asked."
  (harness-define-provider id
    :complete #'ignore
    :models (lambda ()
              (when calls (cl-incf (car calls)))
              (harness-resolved (mapcar (lambda (w) (list :name (car w) :context-window (cdr w)))
                                        windows)))))

(defun harness-provider-test-window (model-id)
  "Return the context window `provider/model' gives MODEL-ID."
  (plist-get (harness-call 'provider/model model-id) :context-window))

(ert-deftest harness-provider-model-asks-a-provider-not-listed-yet ()
  "A model is found with its window before anyone asked for the catalogue.
The harness once answered the 128000 stand-in until a client asked
`provider/models', and sessions created meanwhile kept that window."
  (harness-provider-test-with (test-static)
    (let ((calls (list 0)) (announced nil))
      (harness-on 'provider/models-updated
                  (lambda (models)
                    (when (member "test-static:big" (mapcar (lambda (m) (plist-get m :id)) models))
                      (setq announced t))))
      (harness-provider-test-static 'test-static '(("big" . 1000000)) calls)
      (let ((m (harness-call 'provider/model "test-static:big")))
        (should (equal "test-static:big" (plist-get m :id)))
        (should (= 1000000 (plist-get m :context-window))))
      ;; Asked once: what it listed is cached, and a model it does not
      ;; list gets the stand-in without asking it again.
      (should (= 128000 (harness-provider-test-window "test-static:other")))
      (should (= 1000000 (harness-provider-test-window "test-static:big")))
      (should (= 1 (car calls)))
      ;; The new models are announced, from the command loop.
      (should-not announced)
      (harness-test-wait (lambda () announced) 2 "provider/models-updated"))))

(ert-deftest harness-provider-defining-one-again-keeps-the-others ()
  "Defining a provider again, as every reload does, forgets its models only.
Its new models are used from the next lookup on."
  (harness-provider-test-with (test-a test-b)
    (let ((b-calls (list 0)))
      (harness-provider-test-static 'test-a '(("m" . 200000)))
      (harness-provider-test-static 'test-b '(("m" . 1000000)) b-calls)
      (harness-test-await (harness-call 'provider/models))
      (should (= 1 (car b-calls)))
      (harness-provider-test-static 'test-a '(("m" . 400000)))
      (should (= 1000000 (harness-provider-test-window "test-b:m")))
      (should (= 400000 (harness-provider-test-window "test-a:m")))
      (should (member "test-b:m" (mapcar (lambda (m) (plist-get m :id))
                                         (harness-test-await (harness-call 'provider/models)))))
      (should (= 1 (car b-calls))))))

(ert-deftest harness-provider-model-stands-in-until-a-slow-provider-answers ()
  "A provider that answers later is asked once; its answer replaces the stand-in."
  (harness-provider-test-with (test-remote)
    (let ((calls 0) (answer (harness-make-promise)))
      (harness-define-provider 'test-remote :complete #'ignore
                               :models (lambda () (cl-incf calls) answer))
      (should (= 128000 (harness-provider-test-window "test-remote:m")))
      (should (= 128000 (harness-provider-test-window "test-remote:m")))
      (should (= 1 calls))
      (harness-resolve answer '((:name "m" :context-window 262144)))
      (should (= 262144 (harness-provider-test-window "test-remote:m")))
      (should (= 1 calls)))))

(ert-deftest harness-provider-failed-listing-is-not-asked-on-every-lookup ()
  "A provider whose listing fails is asked again on a refresh, not per lookup.
A failed refresh keeps what it listed before."
  (harness-provider-test-with (test-flaky)
    (let ((calls 0) (answer (harness-rejected '(error "offline"))))
      (harness-define-provider 'test-flaky :complete #'ignore
                               :models (lambda () (cl-incf calls) answer))
      (should (= 128000 (harness-provider-test-window "test-flaky:m")))
      (should (= 128000 (harness-provider-test-window "test-flaky:m")))
      (should (= 1 calls))
      (setq answer (harness-resolved '((:name "m" :context-window 300000))))
      (harness-test-await (harness-call 'provider/models t))
      (should (= 2 calls))
      (should (= 300000 (harness-provider-test-window "test-flaky:m")))
      (setq answer (harness-rejected '(error "offline again")))
      (harness-test-await (harness-call 'provider/models t))
      (should (= 3 calls))
      (should (= 300000 (harness-provider-test-window "test-flaky:m"))))))

(ert-deftest harness-provider-late-answer-of-a-replaced-provider-is-dropped ()
  "An answer that arrives after its provider was defined again is not cached."
  (harness-provider-test-with (test-swap)
    (let ((old (harness-make-promise)))
      (harness-define-provider 'test-swap :complete #'ignore :models (lambda () old))
      (should (= 128000 (harness-provider-test-window "test-swap:m")))
      (harness-provider-test-static 'test-swap '(("m" . 500000)))
      (should (= 500000 (harness-provider-test-window "test-swap:m")))
      (harness-resolve old '((:name "m" :context-window 1000)))
      (should (= 500000 (harness-provider-test-window "test-swap:m"))))))

(ert-deftest harness-provider-tier-model-prefers-declared-tiers ()
  "A provider's `:tiers' names the model each tier uses, over its price."
  (harness-provider-test-with (test-tiered)
    (harness-define-provider 'test-tiered
      :complete #'ignore
      :models (lambda () (harness-resolved
                          (list (list :name "big" :pricing '(:input 10.0 :output 50.0))
                                (list :name "small" :pricing '(:input 1.0 :output 5.0))
                                (list :name "mid" :pricing '(:input 3.0 :output 15.0)))))
      ;; Deliberately not the price order, so the declaration is what decides.
      :tiers '(:cheap "mid" :balanced "big" :frontier "small"))
    (should (equal "test-tiered:mid" (harness-call 'provider/tier-model "test-tiered:big" :cheap)))
    (should (equal "test-tiered:big" (harness-call 'provider/tier-model "test-tiered:big" :balanced)))
    (should (equal "test-tiered:small" (harness-call 'provider/tier-model "test-tiered:big" :frontier)))
    ;; The tier defaults to cheap, and an unknown provider has none.
    (should (equal "test-tiered:mid" (harness-call 'provider/tier-model "test-tiered:big")))
    (should-not (harness-call 'provider/tier-model "nobody:m" :cheap))))

(ert-deftest harness-provider-tier-model-falls-back-to-price ()
  "Without `:tiers', a tier is the provider's models sorted by price.
A model whose cost is unknown is never chosen over one that is priced."
  (harness-provider-test-with (test-sorted)
    (harness-define-provider 'test-sorted
      :complete #'ignore
      :models (lambda () (harness-resolved
                          (list (list :name "free" :pricing nil)
                                (list :name "big" :pricing '(:input 10.0 :output 50.0))
                                (list :name "small" :pricing '(:input 1.0 :output 5.0))
                                (list :name "mid" :pricing '(:input 3.0 :output 15.0))))))
    (should (equal "test-sorted:small" (harness-call 'provider/tier-model "test-sorted:x" :cheap)))
    (should (equal "test-sorted:mid" (harness-call 'provider/tier-model "test-sorted:x" :balanced)))
    (should (equal "test-sorted:big" (harness-call 'provider/tier-model "test-sorted:x" :frontier)))
    (should-not (equal "test-sorted:free" (harness-call 'provider/tier-model "test-sorted:x" :cheap)))))

(ert-deftest harness-provider-tier-model-matches-a-regexp ()
  "A tier names its model by a name a catalogue id matches as a regexp.
Bedrock and Copilot model ids carry a vendor prefix, so their tiers are
family names rather than whole ids."
  (harness-provider-test-with (test-regexp)
    (harness-define-provider 'test-regexp
      :complete #'ignore
      :models (lambda () (harness-resolved
                          (list (list :name "us.anthropic.claude-haiku-4-5" :pricing '(:input 1.0 :output 5.0))
                                (list :name "us.anthropic.claude-sonnet-5" :pricing '(:input 3.0 :output 15.0))
                                (list :name "us.anthropic.claude-opus-5" :pricing '(:input 5.0 :output 25.0)))))
      ;; The regexp wins over the price: sonnet, not the cheaper haiku.
      :tiers '(:cheap "sonnet" :frontier "opus"))
    (should (equal "test-regexp:us.anthropic.claude-sonnet-5"
                   (harness-call 'provider/tier-model "test-regexp:x" :cheap)))
    (should (equal "test-regexp:us.anthropic.claude-opus-5"
                   (harness-call 'provider/tier-model "test-regexp:x" :frontier)))))

(provide 'harness-provider-test)
;;; harness-provider-test.el ends here
