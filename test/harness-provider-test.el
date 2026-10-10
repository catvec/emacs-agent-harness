;;; harness-provider-test.el --- Tests for the provider registry and catalogue  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-providers)
(defvar harness-provider-fallback-context-window)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-provider--forget "harness-provider")
(declare-function harness-provider-relist "harness-provider")
(declare-function harness-provider-model-key "harness-provider")

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
      ;; list gets an estimate without asking it again: the window its
      ;; models have, flagged as an estimate.
      (let ((other (harness-call 'provider/model "test-static:other")))
        (should (= 1000000 (plist-get other :context-window)))
        (should (plist-get other :context-window-estimated)))
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
      (should (= harness-provider-fallback-context-window (harness-provider-test-window "test-remote:m")))
      (should (= harness-provider-fallback-context-window (harness-provider-test-window "test-remote:m")))
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
      (should (= harness-provider-fallback-context-window (harness-provider-test-window "test-flaky:m")))
      (should (= harness-provider-fallback-context-window (harness-provider-test-window "test-flaky:m")))
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
      (should (= harness-provider-fallback-context-window (harness-provider-test-window "test-swap:m")))
      (harness-provider-test-static 'test-swap '(("m" . 500000)))
      (should (= 500000 (harness-provider-test-window "test-swap:m")))
      (harness-resolve old '((:name "m" :context-window 1000)))
      (should (= 500000 (harness-provider-test-window "test-swap:m"))))))

(ert-deftest harness-provider-model-key-names-a-model-wherever-it-is-served ()
  "Vendor and region prefixes, release dates, versions and dots make no key of their own."
  (dolist (case '(("us.anthropic.claude-haiku-4-5-20251001-v1:0" . "claude-haiku-4-5")
                  ("global.anthropic.claude-sonnet-4-5-20250929-v1:0" . "claude-sonnet-4-5")
                  ("anthropic/claude-opus-4.5" . "claude-opus-4-5")
                  ("claude-opus-4-5@20251101" . "claude-opus-4-5")
                  ("claude-haiku-4-5-20251001" . "claude-haiku-4-5")
                  ("Claude-Opus-4-5" . "claude-opus-4-5")
                  ("gpt-4.1" . "gpt-4-1")
                  ("gpt-5-latest" . "gpt-5")
                  ("o3" . "o3")
                  ("meta.llama3-1-70b-instruct-v1:0" . "llama3-1-70b-instruct")
                  ;; A variant is another window: its suffix stays.
                  ("claude-opus-4-5[1m]" . "claude-opus-4-5[1m]")))
    (should (equal (cdr case) (harness-provider-model-key (car case))))))

(ert-deftest harness-provider-unsized-model-takes-the-window-of-the-same-model ()
  "A model a provider lists without a window gets the one another provider gives it.
It is flagged as an estimate, with what it was drawn from."
  (harness-provider-test-with (test-sized test-bare)
    (harness-provider-test-static 'test-sized '(("claude-opus-4-5-20251101" . 200000) ("gpt-5" . 400000)))
    (harness-define-provider 'test-bare
      :complete #'ignore
      :models (lambda () (harness-resolved '((:name "anthropic/claude-opus-4.5") (:name "openai/gpt-5")
                                             (:name "mystery") (:name "sized" :context-window 64000)))))
    (let* ((models (harness-test-await (harness-call 'provider/models)))
           (by-id (lambda (id) (cl-find id models :key (lambda (m) (plist-get m :id)) :test #'equal))))
      ;; Every model has a window.
      (should (cl-every (lambda (m) (integerp (plist-get m :context-window))) models))
      (let ((opus (funcall by-id "test-bare:anthropic/claude-opus-4.5")))
        (should (= 200000 (plist-get opus :context-window)))
        (should (plist-get opus :context-window-estimated))
        (should (equal "test-sized:claude-opus-4-5-20251101" (plist-get opus :context-window-basis))))
      (should (= 400000 (plist-get (funcall by-id "test-bare:openai/gpt-5") :context-window)))
      ;; Nothing like it anywhere: the provider's own sized models decide.
      (let ((mystery (funcall by-id "test-bare:mystery")))
        (should (= 64000 (plist-get mystery :context-window)))
        (should (equal "test-bare's models" (plist-get mystery :context-window-basis))))
      ;; What the provider sizes is no estimate.
      (let ((sized (funcall by-id "test-bare:sized")))
        (should (= 64000 (plist-get sized :context-window)))
        (should-not (plist-get sized :context-window-estimated)))
      ;; The window a provider gives wins over one drawn from elsewhere.
      (should-not (plist-get (funcall by-id "test-sized:gpt-5") :context-window-estimated)))))

(ert-deftest harness-provider-unlisted-model-takes-after-its-family ()
  "A model its provider does not list takes after the listed one closest in name.
Failing that it gets the window most of the provider's models have, and
a model of no provider the fallback; all flagged, none of them silently
small."
  (harness-provider-test-with (test-family)
    (harness-provider-test-static 'test-family '(("claude-opus-5-5" . 1000000) ("claude-haiku-4-5" . 200000)
                                                  ("claude-sonnet-5" . 1000000)))
    (let ((opus (harness-call 'provider/model "test-family:claude-opus-5-6"))
          (haiku (harness-call 'provider/model "test-family:claude-haiku-5"))
          (other (harness-call 'provider/model "test-family:gemini-3"))
          (nobody (harness-call 'provider/model "nobody:m")))
      (should (= 1000000 (plist-get opus :context-window)))
      (should (equal "test-family:claude-opus-5-5" (plist-get opus :context-window-basis)))
      (should (= 200000 (plist-get haiku :context-window)))
      (should (equal "test-family:claude-haiku-4-5" (plist-get haiku :context-window-basis)))
      (should (= 1000000 (plist-get other :context-window)))
      (should (equal "test-family's models" (plist-get other :context-window-basis)))
      (should (= harness-provider-fallback-context-window (plist-get nobody :context-window)))
      (should (equal "default" (plist-get nobody :context-window-basis)))
      (dolist (m (list opus haiku other nobody))
        (should (plist-get m :context-window-estimated)))
      ;; The provider, its label and its capabilities are those of the model's own.
      (should (eq 'test-family (plist-get opus :provider)))
      (should (equal "claude-opus-5-6" (plist-get opus :name))))))

(ert-deftest harness-provider-estimate-is-logged-once ()
  "An estimate for a model its listed provider lacks is logged, once per model."
  (harness-provider-test-with (test-logged)
    (let* ((warnings nil)
           (harness-log-hook (list (lambda (level msg) (when (eq level 'warn) (push msg warnings))))))
      (harness-provider-test-static 'test-logged '(("a" . 300000)))
      (harness-call 'provider/model "test-logged:b")
      (harness-call 'provider/model "test-logged:b")
      (should (= 1 (length (cl-remove-if-not (lambda (w) (string-match-p "test-logged:b" w)) warnings))))
      (should (string-match-p "300000" (car warnings))))))

(ert-deftest harness-provider-resolve-sizes-a-model-the-listing-lacks ()
  "A provider's `:resolve' turns a name its listing lacks into a model.
It gets the listed models when it takes them; what it says nothing of,
or fails on, is estimated."
  (harness-provider-test-with (test-alias test-alias1)
    (let ((warnings nil))
      (harness-define-provider 'test-alias
        :complete #'ignore
        :models (lambda () (harness-resolved '((:name "model-a" :context-window 300000 :label "Model A"))))
        :resolve (lambda (name models)
                   (pcase name
                     ("best" (let ((a (car models)))
                               (list :label "Best" :context-window (plist-get a :context-window)
                                     :resolved-name (plist-get a :name))))
                     ("broken" (error "Cannot resolve"))
                     (_ nil))))
      (harness-define-provider 'test-alias1
        :complete #'ignore
        :models (lambda () (harness-resolved nil))
        :resolve (lambda (name) (when (string-suffix-p "[1m]" name) (list :context-window 1000000))))
      (let ((best (harness-call 'provider/model "test-alias:best")))
        (should (equal "test-alias:best" (plist-get best :id)))
        (should (equal "best" (plist-get best :name)))
        (should (equal "Best" (plist-get best :label)))
        (should (eq 'test-alias (plist-get best :provider)))
        (should (= 300000 (plist-get best :context-window)))
        (should-not (plist-get best :context-window-estimated))
        (should (equal "model-a" (plist-get best :resolved-name))))
      (let ((harness-log-hook (list (lambda (level msg) (when (eq level 'warn) (push msg warnings))))))
        (let ((broken (harness-call 'provider/model "test-alias:broken")))
          (should (plist-get broken :context-window-estimated))
          (should (cl-some (lambda (w) (string-match-p "Cannot resolve" w)) warnings))))
      (should (= 1000000 (harness-provider-test-window "test-alias1:x[1m]")))
      (should (plist-get (harness-call 'provider/model "test-alias1:x") :context-window-estimated)))))

(ert-deftest harness-provider-guessed-window-gives-way-to-a-sized-one ()
  "A window a provider flags as its own guess yields to the same model sized elsewhere.
Or to the provider's model closest by name that it sizes.  It stays
flagged, now drawn from that model; with nothing so close to go by,
the provider's guess stands."
  (harness-provider-test-with (test-sizer test-guesser)
    (harness-provider-test-static 'test-sizer '(("claude-opus-9" . 2000000)))
    (harness-define-provider 'test-guesser
      :complete #'ignore
      :models (lambda () (harness-resolved
                          '((:name "us.anthropic.claude-opus-9-v1:0" :context-window 200000
                             :context-window-estimated t :context-window-basis "family")
                            (:name "anthropic.claude-zeta-1-v1:0" :context-window 200000
                             :context-window-estimated t :context-window-basis "family")
                            (:name "mistral.mistral-large-2407-v1:0" :context-window 128000)
                            (:name "mistral.mistral-large-3-675b-instruct" :context-window 32000
                             :context-window-estimated t :context-window-basis "family")
                            (:name "mistral.mistral-7b-instruct-v0:2" :context-window 32000
                             :context-window-estimated t :context-window-basis "family"))))
      :resolve (lambda (_name) (list :context-window 200000 :context-window-estimated t
                                     :context-window-basis "family")))
    (let* ((models (harness-test-await (harness-call 'provider/models)))
           (by-id (lambda (id) (cl-find id models :key (lambda (m) (plist-get m :id)) :test #'equal))))
      (let ((opus (funcall by-id "test-guesser:us.anthropic.claude-opus-9-v1:0")))
        (should (= 2000000 (plist-get opus :context-window)))
        (should (plist-get opus :context-window-estimated))
        (should (equal "test-sizer:claude-opus-9" (plist-get opus :context-window-basis))))
      (let ((zeta (funcall by-id "test-guesser:anthropic.claude-zeta-1-v1:0")))
        (should (= 200000 (plist-get zeta :context-window)))
        (should (equal "family" (plist-get zeta :context-window-basis))))
      ;; Nor elsewhere, but the provider sizes one of its kind: that one.
      (let ((large (funcall by-id "test-guesser:mistral.mistral-large-3-675b-instruct")))
        (should (= 128000 (plist-get large :context-window)))
        (should (plist-get large :context-window-estimated))
        (should (equal "test-guesser:mistral.mistral-large-2407-v1:0" (plist-get large :context-window-basis))))
      ;; Only one word in common: the provider's guess stands, not the
      ;; window most of its models have.
      (let ((small (funcall by-id "test-guesser:mistral.mistral-7b-instruct-v0:2")))
        (should (= 32000 (plist-get small :context-window)))
        (should (equal "family" (plist-get small :context-window-basis))))
      ;; What `:resolve' guesses for a name the listing lacks, likewise.
      (let ((global (harness-call 'provider/model "test-guesser:global.anthropic.claude-opus-9-v1:0"))
            (other (harness-call 'provider/model "test-guesser:anthropic.claude-omega-2-v1:0")))
        (should (= 2000000 (plist-get global :context-window)))
        (should (equal "test-sizer:claude-opus-9" (plist-get global :context-window-basis)))
        (should (= 200000 (plist-get other :context-window)))
        (should (equal "family" (plist-get other :context-window-basis))))
      ;; A guess is no source for another estimate.
      (should (= harness-provider-fallback-context-window
                 (harness-provider-test-window "nobody:claude-zeta-1"))))))

(ert-deftest harness-provider-relist-picks-up-what-a-provider-learned ()
  "`harness-provider-relist' caches and announces a provider's new listing.
A models function that takes an argument is told when a refresh asks."
  (harness-provider-test-with (test-learns)
    (let ((window 200000) (refreshes nil) (announced 0))
      (harness-on 'provider/models-updated (lambda (_) (cl-incf announced)))
      (harness-define-provider 'test-learns
        :complete #'ignore
        :models (lambda (&optional refresh)
                  (push refresh refreshes)
                  (harness-resolved (list (list :name "m" :context-window window)))))
      (should (= 200000 (harness-provider-test-window "test-learns:m")))
      (should (equal '(nil) refreshes))
      ;; The provider learned the model's real window.
      (setq window 1000000)
      (should (= 200000 (harness-provider-test-window "test-learns:m")))
      (harness-test-await (harness-provider-relist 'test-learns))
      (should (= 1000000 (harness-provider-test-window "test-learns:m")))
      (should (equal '(nil nil) refreshes))
      (harness-test-wait (lambda () (>= announced 2)) 2 "provider/models-updated")
      ;; A refresh asks the source again.
      (harness-test-await (harness-call 'provider/models t))
      (should (equal '(t nil nil) refreshes))
      ;; Nothing to relist for a provider that is not there.
      (should-not (harness-provider-relist 'test-nobody)))))

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

(ert-deftest harness-provider-tier-model-info-says-which-model-or-why-not ()
  "The info answers with the model of a tier, else why there is none.
`unknown' is a provider nobody registered, `unlisted' a catalogue not
there (yet, or a listing that answered nothing), `none' a catalogue
with nothing for the tier."
  (harness-provider-test-with (test-priced test-late test-unpriced)
    (harness-define-provider 'test-priced
      :complete #'ignore
      :models (lambda () (harness-resolved
                          (list (list :name "small" :pricing '(:input 1.0 :output 5.0))
                                (list :name "big" :pricing '(:input 10.0 :output 50.0))))))
    (should (equal (cons "test-priced:small" nil)
                   (harness-call 'provider/tier-model-info "test-priced:big" :cheap)))
    (should (equal (cons "test-priced:big" nil)
                   (harness-call 'provider/tier-model-info "test-priced" :frontier)))
    ;; A provider that has not listed its models yet says so rather than
    ;; answer that it has none.
    (harness-define-provider 'test-late :complete #'ignore
                             :models (lambda () (harness-make-promise)))
    (should (equal (cons nil 'unlisted)
                   (harness-call 'provider/tier-model-info "test-late:m" :cheap)))
    ;; A catalogue with no price to rank and no `:tiers' names no model.
    (harness-define-provider 'test-unpriced :complete #'ignore
                             :models (lambda () (harness-resolved '((:name "m")))))
    (should (equal (cons nil 'none)
                   (harness-call 'provider/tier-model-info "test-unpriced:m" :cheap)))
    ;; The id alone is enough to name the provider, and an unknown one
    ;; cannot even be asked.
    (should (equal (cons nil 'unknown)
                   (harness-call 'provider/tier-model-info "nobody:m" :cheap)))
    (should (equal (cons nil 'unknown)
                   (harness-call 'provider/tier-model-info nil :cheap)))))

(ert-deftest harness-provider-tier-model-async-waits-for-a-late-catalogue ()
  "A provider that answers late gives the tier its model to a caller that can wait.
`provider/tier-model-info' reading meanwhile says the catalogue is not
there; a listing that fails settles as `unlisted', never rejected."
  (harness-provider-test-with (test-slow test-broken)
    (let ((answer (harness-make-promise)))
      (harness-define-provider 'test-slow
        :complete #'ignore
        :models (lambda ()
                  (run-at-time 0.05 nil
                               (lambda ()
                                 (harness-resolve
                                  answer '((:name "small" :pricing (:input 1.0 :output 5.0))
                                           (:name "big" :pricing (:input 10.0 :output 50.0))))))
                  answer))
      ;; Before it answers, a lookup that cannot wait is told so.
      (should (equal (cons nil 'unlisted)
                     (harness-call 'provider/tier-model-info "test-slow:big" :cheap)))
      (should (equal (cons "test-slow:small" nil)
                     (harness-test-await (harness-call 'provider/tier-model-async "test-slow:big" :cheap))))
      (should (equal (cons "test-slow:big" nil)
                     (harness-test-await (harness-call 'provider/tier-model-async "test-slow:big" :frontier))))
      ;; Answered once: the next lookup needs no wait.
      (should (equal (cons "test-slow:small" nil)
                     (harness-call 'provider/tier-model-info "test-slow:big" :cheap))))
    (harness-define-provider 'test-broken :complete #'ignore
                             :models (lambda () (harness-rejected '(error "offline"))))
    (should (equal (cons nil 'unlisted)
                   (harness-test-await (harness-call 'provider/tier-model-async "test-broken:m" :cheap))))
    (should (equal (cons nil 'unknown)
                   (harness-test-await (harness-call 'provider/tier-model-async "nobody:m" :cheap))))))

(ert-deftest harness-provider-tiers-type-names-the-tiers ()
  "The settings page offers each tier of a provider by name."
  (let ((type harness-provider-tiers-type))
    (should (equal '(:cheap :balanced :frontier) (harness-test-option-keys type)))
    (harness-test-check-record-type type)
    (should (harness-test-fits-p type (plist-get (cdr type) :value)))
    ;; A tier with no name of its own still fits, as a key it does not name.
    (should (harness-test-fits-p type '(:cheap "haiku" :my-tier "other")))))

(ert-deftest harness-provider-warm-and-close-reach-the-provider ()
  "`provider/warm' and `provider/close' call the hooks of the request's
provider; a provider without them, an unknown one and a hook that fails
make no difference to the caller."
  (harness-provider-test-with (test-warm test-plain)
    (let (warmed closed)
      (harness-define-provider 'test-warm
        :complete #'ignore
        :warm (lambda (request) (push request warmed) t)
        :close (lambda (sid) (push sid closed) (equal sid "s-1")))
      (harness-define-provider 'test-plain :complete #'ignore)
      (let ((request (list :model "test-warm:m" :session '(:id "s-1") :system "S")))
        (should (harness-call 'provider/warm request))
        (should (equal (list request) warmed)))
      (should (harness-call 'provider/close "test-warm:m" "s-1"))
      (should-not (harness-call 'provider/close "test-warm:m" "s-2"))
      (should (equal '("s-2" "s-1") closed))
      ;; Nothing to prepare or free.
      (should-not (harness-call 'provider/warm '(:model "test-plain:m" :session (:id "s-1"))))
      (should-not (harness-call 'provider/close "test-plain:m" "s-1"))
      (should-not (harness-call 'provider/warm '(:model "nobody:m")))
      (should-not (harness-call 'provider/close "nobody:m" "s-1"))
      ;; A hook that fails is logged, not signalled.
      (harness-define-provider 'test-warm
        :complete #'ignore
        :warm (lambda (_) (error "No CLI"))
        :close (lambda (_) (error "No CLI")))
      (should-not (harness-call 'provider/warm '(:model "test-warm:m")))
      (should-not (harness-call 'provider/close "test-warm:m" "s-1"))
      ;; Defined again without them, it has none.
      (harness-define-provider 'test-warm :complete #'ignore)
      (should-not (harness-call 'provider/warm '(:model "test-warm:m"))))))

;;;; Prompt cache lifetime

(defvar harness-cache-ttl)
(defvar harness-cache-ttl-overrides)

(ert-deftest harness-provider-cache-ttl-resolves-in-order ()
  "How long a model keeps its prompt cache: what its provider reported
for the request, else the first override matching its id, else the
`:cache-ttl' capability of the model or its provider, else
`harness-cache-ttl'."
  (harness-provider-test-with (test-cache test-plain)
    (let ((harness-cache-ttl 300)
          (harness-cache-ttl-overrides nil))
      (harness-define-provider 'test-cache
        :complete #'ignore :capabilities '(:cache-ttl 10800)
        :models (lambda ()
                  (harness-resolved (list (list :name "long" :context-window 1000)
                                          (list :name "short" :context-window 1000
                                                :capabilities '(:cache-ttl 60))))))
      (harness-provider-test-static 'test-plain '(("m" . 1000)))
      ;; Nothing said: the default, also for a model nobody knows.
      (should (= 300 (harness-call 'provider/cache-ttl "test-plain:m")))
      (should (= 300 (harness-call 'provider/cache-ttl "nobody:m")))
      (should (= 300 (harness-call 'provider/cache-ttl nil)))
      ;; The provider's capability, which a model's own wins over.
      (should (= 10800 (harness-call 'provider/cache-ttl "test-cache:long")))
      (should (= 60 (harness-call 'provider/cache-ttl "test-cache:short")))
      ;; The first override that matches wins over both; a broken regexp
      ;; is passed over.
      (let ((harness-cache-ttl-overrides '(("[" . 5) ("\\`test-cache:" . 3600) ("long" . 7))))
        (should (= 3600 (harness-call 'provider/cache-ttl "test-cache:long")))
        (should (= 3600 (harness-call 'provider/cache-ttl "test-cache:short")))
        (should (= 300 (harness-call 'provider/cache-ttl "test-plain:m")))
        ;; What the provider reported for the request wins over all.
        (should (= 900 (harness-call 'provider/cache-ttl "test-cache:long" 900)))
        ;; Unless it reported nothing usable.
        (should (= 3600 (harness-call 'provider/cache-ttl "test-cache:long" 0)))
        (should (= 3600 (harness-call 'provider/cache-ttl "test-cache:long" "1h"))))
      ;; The default follows the option.
      (let ((harness-cache-ttl 2))
        (should (= 2 (harness-call 'provider/cache-ttl "test-plain:m")))))))

;;;; Forks at a checkpoint and replayed transcripts

(defvar harness-provider-history-limit)
(defvar harness-provider-history-block-limit)
(declare-function harness-provider-split-history "harness-provider")
(declare-function harness-provider-history-text "harness-provider")

(ert-deftest harness-provider-fork-passes-a-checkpoint-only-to-who-takes-one ()
  "A checkpoint goes to a fork function of three arguments; one of two gives nil."
  (harness-provider-test-with (test-cuts test-whole)
    (harness-define-provider 'test-cuts :complete #'ignore
                             :fork (lambda (_m state &optional checkpoint) (list state checkpoint)))
    (harness-define-provider 'test-whole :complete #'ignore
                             :fork (lambda (_m state) (list :whole state)))
    (should (equal '(s nil :provider "test-cuts") (harness-test-await (harness-call 'provider/fork "test-cuts:m" 's))))
    (should (equal '(s c :provider "test-cuts") (harness-test-await (harness-call 'provider/fork "test-cuts:m" 's 'c))))
    (should (equal '(:whole s :provider "test-whole") (harness-test-await (harness-call 'provider/fork "test-whole:m" 's))))
    (should-not (harness-test-await (harness-call 'provider/fork "test-whole:m" 's 'c)))))

(ert-deftest harness-provider-history-renders-what-was-said ()
  "A transcript replayed into a new conversation shows each message, oldest first.
The trailing user messages are the new message and stay out; tool
results are named after their calls, thinking is left out, and long
tool output is cut."
  (harness-test-reset-bus)
  (harness-test-load-module 'provider)
  (let* ((harness-provider-history-block-limit 40)
         (long (make-string (+ 10 harness-provider-history-block-limit) ?x))
         (messages (list '(:role user :content ((:type "text" :text "list the files")))
                         '(:role assistant :content ((:type "thinking" :text "secret musing" :signature "s")
                                                     (:type "text" :text "Looking.")
                                                     (:type "tool_use" :id "t1" :name "list_dir" :input (:path "/"))))
                         (list :role 'user :content (list (list :type "tool_result" :tool_use_id "t1"
                                                                :content long :is_error :false)))
                         '(:role assistant :content ((:type "text" :text "Two files.")))
                         '(:role user :content ((:type "text" :text "now what?")))))
         (split (harness-provider-split-history messages))
         (text (harness-provider-history-text (car split))))
    (should (= 4 (length (car split))))
    (should (equal '((:role user :content ((:type "text" :text "now what?")))) (cdr split)))
    (should (string-match-p "<user>\nlist the files\n</user>" text))
    (should (string-match-p "<assistant>\nLooking\\.\n\n<tool_call name=\"list_dir\">\n{\"path\":\"/\"}\n</tool_call>\n</assistant>"
                            text))
    (should (string-match-p "<tool_result name=\"list_dir\">\nx+\n\\[… 10 more characters\\]\n</tool_result>" text))
    (should (string-match-p "<assistant>\nTwo files\\.\n</assistant>\n</conversation_history>\\'" text))
    (should-not (string-match-p "secret musing" text))
    (should-not (string-match-p (regexp-quote "now what?") text))
    ;; Nothing before the new message: nothing to replay.
    (should-not (harness-provider-history-text (car (harness-provider-split-history (last messages)))))
    ;; Past the limit, the oldest messages but the first go.
    (let* ((harness-provider-history-limit 60)
           (many (cl-loop for i below 6 collect (list :role (if (cl-evenp i) 'user 'assistant)
                                                      :content (list (list :type "text" :text (format "message %d" i))))))
           (text (harness-provider-history-text many)))
      (should (string-match-p "message 0" text))
      (should (string-match-p "message 5" text))
      (should-not (string-match-p "message 1" text))
      (should (string-match-p "\\[… [0-9]+ earlier messages omitted …\\]" text)))))

;;;; Models allowed

(defvar harness-allowed-models)
(declare-function harness-provider-model-allowed-p "harness-provider")

(ert-deftest harness-provider-allowed-models-are-globs-of-model-ids ()
  "A pattern is a glob of a model id; one without a colon names providers."
  (harness-provider-test-with ()
    (let ((harness-allowed-models nil))
      (should (harness-provider-model-allowed-p "anything:at-all")))
    (let ((harness-allowed-models '("claude" "openai:gpt-5*" "*:*sonnet*")))
      (dolist (id '("claude:opus" "claude:claude-fable-5-1" "openai:gpt-5" "openai:gpt-5-mini"
                    "bedrock:anthropic.claude-sonnet-4" "deepseek:sonnet"))
        (should (harness-provider-model-allowed-p id)))
      (dolist (id '("claudex:opus" "openai:gpt-4o" "OPENAI:gpt-5" "deepseek:deepseek-flash"
                    "no-provider" nil))
        (should-not (harness-provider-model-allowed-p id))))))

(ert-deftest harness-provider-policy-keeps-requests-to-models-allowed ()
  "No provider is asked for a model the policy does not allow, whoever
asks; the catalogue lists only the models allowed, and a tier's model is
one of them."
  (harness-provider-test-with (test-allowed test-other)
    (let ((completed nil) (warmed nil))
      (harness-define-provider 'test-allowed
        :complete (lambda (request) (push (plist-get request :model) completed) (list :cancel #'ignore))
        :warm (lambda (request) (push (plist-get request :model) warmed) t)
        :models (lambda () (harness-resolved
                            (list (list :name "small" :pricing '(:input 1.0 :output 5.0))
                                  (list :name "big" :pricing '(:input 10.0 :output 50.0))))))
      (harness-provider-test-static 'test-other '(("m" . 100000)))
      (harness-test-with-policy '((harness-allowed-models "test-allowed:big"))
        (let ((events nil))
          (harness-call 'provider/complete
                        (list :model "test-allowed:small" :on-event (lambda (e) (push e events))))
          (should-not completed)
          (should (= 1 (length events)))
          (should (eq 'done (plist-get (car events) :type)))
          (should (eq 'error (plist-get (car events) :stop-reason)))
          (should (string-match-p "test-allowed:small is not allowed: harness-allowed-models, set by policy"
                                  (plist-get (car events) :error)))
          (harness-call 'provider/complete (list :model "test-allowed:big" :on-event #'ignore))
          (should (equal '("test-allowed:big") completed)))
        (should-not (harness-call 'provider/warm (list :model "test-allowed:small")))
        (should (harness-call 'provider/warm (list :model "test-allowed:big")))
        (should (equal '("test-allowed:big") warmed))
        (should (equal '("test-allowed:big")
                       (mapcar (lambda (m) (plist-get m :id))
                               (harness-test-await (harness-call 'provider/models)))))
        ;; The cheap model is the cheapest allowed.
        (should (equal "test-allowed:big" (harness-call 'provider/tier-model "test-allowed" :cheap)))
        (should-not (harness-call 'provider/tier-model "test-other" :cheap)))
      (should (= 3 (length (harness-test-await (harness-call 'provider/models)))))
      (should (equal "test-allowed:small" (harness-call 'provider/tier-model "test-allowed" :cheap))))))

(provide 'harness-provider-test)
;;; harness-provider-test.el ends here
