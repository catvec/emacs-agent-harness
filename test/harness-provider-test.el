;;; harness-provider-test.el --- Tests for the provider registry and catalogue  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-providers)
(defvar harness-provider-fallback-context-window)
(defvar harness-policy-file)
(defvar harness-allowed-models)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-provider--forget "harness-provider")
(declare-function harness-provider-relist "harness-provider")
(declare-function harness-provider-model-key "harness-provider")
(declare-function harness-provider-normalize-tiers "harness-provider" (tiers))

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
      :tiers '(:simple "mid" :medium "big" :hard "small" :frontier "mid"))
    (should (equal "test-tiered:mid" (harness-call 'provider/tier-model "test-tiered:big" :simple)))
    (should (equal "test-tiered:big" (harness-call 'provider/tier-model "test-tiered:big" :medium)))
    (should (equal "test-tiered:small" (harness-call 'provider/tier-model "test-tiered:big" :hard)))
    (should (equal "test-tiered:mid" (harness-call 'provider/tier-model "test-tiered:big" :frontier)))
    ;; A tier is named by a symbol or a string just as well.
    (should (equal "test-tiered:small" (harness-call 'provider/tier-model "test-tiered:big" 'hard)))
    (should (equal "test-tiered:small" (harness-call 'provider/tier-model "test-tiered:big" "hard")))
    ;; The tier defaults to simple, and an unknown provider has none.
    (should (equal "test-tiered:mid" (harness-call 'provider/tier-model "test-tiered:big")))
    (should-not (harness-call 'provider/tier-model "nobody:m" :simple))))

(ert-deftest harness-provider-tier-model-reads-the-tiers-of-old ()
  "A `:tiers' plist in the three tiers of old reads as it was meant.
Cheap is simple and balanced medium, and its frontier, the strongest
model the harness picked then, is hard: the frontier of now is left to
the prices, the dearest model.  The names of old still ask for theirs."
  (harness-provider-test-with (test-old)
    (harness-define-provider 'test-old
      :complete #'ignore
      :models (lambda () (harness-resolved
                          (list (list :name "haiku" :pricing '(:input 1.0 :output 5.0))
                                (list :name "sonnet" :pricing '(:input 2.0 :output 10.0))
                                (list :name "opus" :pricing '(:input 4.0 :output 20.0))
                                (list :name "fable" :pricing '(:input 10.0 :output 50.0)))))
      :tiers '(:cheap "haiku" :balanced "sonnet" :frontier "opus"))
    (should (equal "test-old:haiku" (harness-call 'provider/tier-model "test-old:x" :simple)))
    (should (equal "test-old:sonnet" (harness-call 'provider/tier-model "test-old:x" :medium)))
    (should (equal "test-old:opus" (harness-call 'provider/tier-model "test-old:x" :hard)))
    (should (equal "test-old:fable" (harness-call 'provider/tier-model "test-old:x" :frontier)))
    (should (equal "test-old:haiku" (harness-call 'provider/tier-model "test-old:x" 'cheap)))
    (should (equal "test-old:sonnet" (harness-call 'provider/tier-model "test-old:x" :balanced)))
    (should (eq 'hard (harness-call 'provider/model-tier "test-old:opus")))
    (should (eq 'frontier (harness-call 'provider/model-tier "test-old:fable")))))

(ert-deftest harness-provider-normalize-tiers-renames-the-tiers-of-old ()
  "A plist of old is renamed key by key; a plist of now stays as it is.
Its `:frontier' is hard only in a plist of old, a key of now wins over
the old one for the same tier, and anything else is kept."
  (should (equal '(:simple "h" :medium "s" :hard "o")
                 (harness-provider-normalize-tiers '(:cheap "h" :balanced "s" :frontier "o"))))
  (should (equal '(:simple "h" :medium "s" :hard "o" :frontier "f")
                 (harness-provider-normalize-tiers '(:simple "h" :medium "s" :hard "o" :frontier "f"))))
  ;; Mixed: the new key wins, and frontier keeps its meaning of now.
  (should (equal '(:simple "new" :frontier "f" :medium "s")
                 (harness-provider-normalize-tiers '(:simple "new" :cheap "old" :balanced "s" :frontier "f"))))
  (should (equal '(:simple (:model "m" :thinking "low") :frontier nil)
                 (harness-provider-normalize-tiers '(:simple (:model "m" :thinking "low") :frontier nil))))
  (should-not (harness-provider-normalize-tiers nil)))

(ert-deftest harness-provider-tier-named-nil-has-no-model ()
  "A tier the provider names as nil has no model: no price picks one.
Its model-tier is then the nearest tier the provider has a model for,
and a tier it does not name at all still goes by price."
  (harness-provider-test-with (test-nofrontier)
    (harness-define-provider 'test-nofrontier
      :complete #'ignore
      :models (lambda () (harness-resolved
                          (list (list :name "flash" :pricing '(:input 0.1 :output 0.4))
                                (list :name "pro" :pricing '(:input 1.0 :output 4.0)))))
      :tiers '(:simple "flash" :medium "flash" :frontier nil))
    (should (equal (cons nil 'none)
                   (harness-call 'provider/tier-model-info "test-nofrontier:flash" :frontier)))
    (should-not (harness-call 'provider/tier-model "test-nofrontier:flash" 'frontier))
    ;; Hard is not named: the prices place the dearer model there.
    (should (equal "test-nofrontier:pro" (harness-call 'provider/tier-model "test-nofrontier:flash" 'hard)))
    ;; Flash is named medium (and simple): medium comes first.
    (should (eq 'medium (harness-call 'provider/model-tier "test-nofrontier:flash")))
    ;; Pro's price makes it frontier, which the provider has no model for.
    (should (eq 'hard (harness-call 'provider/model-tier "test-nofrontier:pro")))))

(ert-deftest harness-provider-tier-model-falls-back-to-price ()
  "Without `:tiers', a tier is the provider's models sorted by price.
The four tiers spread over them, cheapest first; a model whose cost is
unknown is never chosen over one that is priced."
  (harness-provider-test-with (test-sorted)
    (harness-define-provider 'test-sorted
      :complete #'ignore
      :models (lambda () (harness-resolved
                          (list (list :name "free" :pricing nil)
                                (list :name "big" :pricing '(:input 10.0 :output 50.0))
                                (list :name "small" :pricing '(:input 1.0 :output 5.0))
                                (list :name "large" :pricing '(:input 5.0 :output 25.0))
                                (list :name "mid" :pricing '(:input 3.0 :output 15.0))))))
    (should (equal "test-sorted:small" (harness-call 'provider/tier-model "test-sorted:x" :simple)))
    (should (equal "test-sorted:mid" (harness-call 'provider/tier-model "test-sorted:x" :medium)))
    (should (equal "test-sorted:large" (harness-call 'provider/tier-model "test-sorted:x" :hard)))
    (should (equal "test-sorted:big" (harness-call 'provider/tier-model "test-sorted:x" :frontier)))
    (should-not (equal "test-sorted:free" (harness-call 'provider/tier-model "test-sorted:x" :simple)))
    ;; And back: a model's price places it in its tier.
    (should (eq 'simple (harness-call 'provider/model-tier "test-sorted:small")))
    (should (eq 'medium (harness-call 'provider/model-tier "test-sorted:mid")))
    (should (eq 'hard (harness-call 'provider/model-tier "test-sorted:large")))
    (should (eq 'frontier (harness-call 'provider/model-tier "test-sorted:big")))))

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
      :tiers '(:simple "sonnet" :hard "opus"))
    (should (equal "test-regexp:us.anthropic.claude-sonnet-5"
                   (harness-call 'provider/tier-model "test-regexp:x" :simple)))
    (should (equal "test-regexp:us.anthropic.claude-opus-5"
                   (harness-call 'provider/tier-model "test-regexp:x" :hard)))))

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
                   (harness-call 'provider/tier-model-info "test-priced:big" :simple)))
    (should (equal (cons "test-priced:big" nil)
                   (harness-call 'provider/tier-model-info "test-priced" :frontier)))
    ;; A provider that has not listed its models yet says so rather than
    ;; answer that it has none.
    (harness-define-provider 'test-late :complete #'ignore
                             :models (lambda () (harness-make-promise)))
    (should (equal (cons nil 'unlisted)
                   (harness-call 'provider/tier-model-info "test-late:m" :simple)))
    ;; A catalogue with no price to rank and no `:tiers' names no model.
    (harness-define-provider 'test-unpriced :complete #'ignore
                             :models (lambda () (harness-resolved '((:name "m")))))
    (should (equal (cons nil 'none)
                   (harness-call 'provider/tier-model-info "test-unpriced:m" :simple)))
    ;; The id alone is enough to name the provider, and an unknown one
    ;; cannot even be asked.
    (should (equal (cons nil 'unknown)
                   (harness-call 'provider/tier-model-info "nobody:m" :simple)))
    (should (equal (cons nil 'unknown)
                   (harness-call 'provider/tier-model-info nil :simple)))))

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
                     (harness-call 'provider/tier-model-info "test-slow:big" :simple)))
      (should (equal (cons "test-slow:small" nil)
                     (harness-test-await (harness-call 'provider/tier-model-async "test-slow:big" :simple))))
      (should (equal (cons "test-slow:big" nil)
                     (harness-test-await (harness-call 'provider/tier-model-async "test-slow:big" :frontier))))
      ;; Answered once: the next lookup needs no wait.
      (should (equal (cons "test-slow:small" nil)
                     (harness-call 'provider/tier-model-info "test-slow:big" :simple))))
    (harness-define-provider 'test-broken :complete #'ignore
                             :models (lambda () (harness-rejected '(error "offline"))))
    (should (equal (cons nil 'unlisted)
                   (harness-test-await (harness-call 'provider/tier-model-async "test-broken:m" :simple))))
    (should (equal (cons nil 'unknown)
                   (harness-test-await (harness-call 'provider/tier-model-async "nobody:m" :simple))))))

(ert-deftest harness-provider-tier-thinking-is-the-level-a-tier-names ()
  "A tier given as (:model :thinking) runs its model at that level.
The model is found as for a name alone; a tier with no level, an unknown
provider and one that names nothing give no level.  It needs no catalogue."
  (harness-provider-test-with (test-levels)
    (harness-define-provider 'test-levels
      :complete #'ignore
      :models (lambda () (harness-make-promise))
      :tiers '(:simple (:model "flash" :thinking "low")
               :medium (:model "flash" :thinking high)
               :hard "flash"
               :frontier nil))
    ;; Never listed, and still the levels are known.
    (should (equal "low" (harness-call 'provider/tier-thinking "test-levels:flash" 'simple)))
    (should (equal "high" (harness-call 'provider/tier-thinking "test-levels:flash" :medium)))
    (should (equal "low" (harness-call 'provider/tier-thinking "test-levels")))
    (should-not (harness-call 'provider/tier-thinking "test-levels:flash" 'hard))
    (should-not (harness-call 'provider/tier-thinking "test-levels:flash" 'frontier))
    (should-not (harness-call 'provider/tier-thinking "nobody:m" 'simple)))
  (harness-provider-test-with (test-plist)
    (harness-define-provider 'test-plist
      :complete #'ignore
      :models (lambda () (harness-resolved
                          (list (list :name "flash" :pricing '(:input 0.1 :output 0.4))
                                (list :name "pro" :pricing '(:input 1.0 :output 4.0)))))
      :tiers '(:simple (:model "flash" :thinking "low") :hard (:model "pro" :thinking "max")))
    (should (equal "test-plist:flash" (harness-call 'provider/tier-model "test-plist:pro" 'simple)))
    (should (equal "test-plist:pro" (harness-call 'provider/tier-model "test-plist:flash" 'hard)))
    (should (eq 'simple (harness-call 'provider/model-tier "test-plist:flash")))
    (should (eq 'hard (harness-call 'provider/model-tier "test-plist:pro")))))

(ert-deftest harness-provider-fit-thinking-keeps-a-level-within-the-model ()
  "A level above or below what a model offers is brought within it.
A level the model offers, one between two it offers, an unknown level
and a model with no levels keep the level as it is."
  (harness-provider-test-with (test-fit)
    (harness-define-provider 'test-fit
      :complete #'ignore
      :models (lambda () (harness-resolved
                          (list (list :name "small" :thinking-levels '("low" "medium" "high"))
                                (list :name "sparse" :thinking-levels '("low" "high" "max"))
                                (list :name "plain")))))
    (should (equal "high" (harness-call 'provider/fit-thinking "test-fit:small" "max")))
    (should (equal "high" (harness-call 'provider/fit-thinking "test-fit:small" "xhigh")))
    (should (equal "low" (harness-call 'provider/fit-thinking "test-fit:small" "minimal")))
    (should (equal "medium" (harness-call 'provider/fit-thinking "test-fit:small" "medium")))
    ;; Between two levels: the provider maps it as it does.
    (should (equal "medium" (harness-call 'provider/fit-thinking "test-fit:sparse" "medium")))
    (should (equal "max" (harness-call 'provider/fit-thinking "test-fit:plain" "max")))
    (should (equal "none" (harness-call 'provider/fit-thinking "test-fit:small" "none")))
    (should (equal "max" (harness-call 'provider/fit-thinking "nobody:m" "max")))
    (should-not (harness-call 'provider/fit-thinking "test-fit:small" nil))))

(ert-deftest harness-provider-tiers-type-names-the-tiers ()
  "The settings page offers each tier of a provider by name.
A tier is a model, a model at a thinking level, or none."
  (let ((type harness-provider-tiers-type))
    (should (equal '(:simple :medium :hard :frontier) (harness-test-option-keys type)))
    (harness-test-check-record-type type)
    (should (harness-test-fits-p type (plist-get (cdr type) :value)))
    (should (harness-test-fits-p type '(:simple (:model "flash" :thinking "low")
                                        :medium (:model "flash" :thinking "high")
                                        :hard (:model "flash" :thinking "max")
                                        :frontier nil)))
    ;; A tier with no name of its own still fits, as a key it does not name.
    (should (harness-test-fits-p type '(:simple "haiku" :my-tier "other")))
    ;; A tier named as nil reads as none on the settings page, whose menu
    ;; shows the first of the tier's types that fits: an empty plist fits
    ;; nil too, so none comes before it.
    (dolist (key '(:simple :medium :hard :frontier))
      (let* ((tier (cadr (assq key (plist-get (cdr type) :options))))
             (fits (cl-find-if (lambda (w) (widget-apply w :match nil))
                               (widget-get (widget-convert tier) :args))))
        (should (equal "None: no model of the provider is for it" (widget-get fits :tag)))))))

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

(ert-deftest harness-provider-embed-reaches-a-provider-that-embeds ()
  "`provider/embed' calls the embed hook of the model's provider with the
model's name, the texts and the options; it rejects a provider without
one, an unknown provider, a model the policy does not allow and a hook
that fails, and `provider/embeds-p' says which embed."
  (harness-provider-test-with (test-embed test-plain)
    (let (asked)
      (harness-define-provider 'test-embed
        :complete #'ignore
        :embed (lambda (name texts opts)
                 (push (list name texts opts) asked)
                 (if (equal name "broken")
                     (error "No such model")
                   (harness-resolved (list :vectors (mapcar (lambda (text) (list (float (length text)) 1.0)) texts)
                                           :usage '(:input 3))))))
      (harness-define-provider 'test-plain :complete #'ignore)
      (should (harness-call 'provider/embeds-p "test-embed:small"))
      (should-not (harness-call 'provider/embeds-p "test-plain:small"))
      (should-not (harness-call 'provider/embeds-p "nobody:small"))
      (should (equal '(:vectors ((2.0 1.0) (5.0 1.0)) :usage (:input 3))
                     (harness-test-await (harness-call 'provider/embed "test-embed:small" '("ab" "cdefg")
                                                       '(:dimensions 2)))))
      (should (equal '(("small" ("ab" "cdefg") (:dimensions 2))) asked))
      (cl-flet ((refused (model)
                  (cadr (should-error (harness-test-await (harness-call 'provider/embed model '("x")))))))
        (should (string-match-p "cannot embed text" (refused "test-plain:small")))
        (should (string-match-p "No provider for model nobody:small" (refused "nobody:small")))
        (should (string-match-p "No such model" (refused "test-embed:broken")))
        (let ((harness-allowed-models '("test-plain")))
          (setq asked nil)
          (should (string-match-p "test-embed:small is not allowed" (refused "test-embed:small")))
          (should-not asked))))))

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
        ;; The simple model is the cheapest allowed.
        (should (equal "test-allowed:big" (harness-call 'provider/tier-model "test-allowed" :simple)))
        (should-not (harness-call 'provider/tier-model "test-other" :simple)))
      (should (= 3 (length (harness-test-await (harness-call 'provider/models)))))
      (should (equal "test-allowed:small" (harness-call 'provider/tier-model "test-allowed" :simple))))))

;;;; Internal calls

(defvar harness-sessions)

(defmacro harness-provider-test-with-sessions (providers &rest body)
  "Like `harness-provider-test-with', with the session module loaded too.
The state is a temporary directory, DIR, which is also BODY's
`default-directory'."
  (declare (indent 1))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider session)) (harness-test-load-module m))
     (clrhash harness-sessions)
     (let ((default-directory dir))
       (unwind-protect (progn ,@body)
         (dolist (id ',providers)
           (remhash id harness-providers)
           (harness-provider--forget id))))))

(defvar harness-provider-test-requests nil
  "The requests the `test-job' provider was sent, newest first.")

(defun harness-provider-test-job-provider ()
  "Define the provider `test-job', which keeps its requests and answers nothing.
A test answers through the `:on-event' of the request the provider got."
  (setq harness-provider-test-requests nil)
  (harness-define-provider 'test-job
    :complete (lambda (request) (push request harness-provider-test-requests) (list :cancel #'ignore))
    :models (lambda () (harness-resolved (list (list :name "judge" :pricing '(:input 1.0 :output 5.0)))))))

(defun harness-provider-test-answer (&rest events)
  "Send EVENTS to the newest request `test-job' got, as its provider would."
  (let ((on-event (plist-get (car harness-provider-test-requests) :on-event)))
    (dolist (e events) (funcall on-event e))))

(defun harness-provider-test-internal ()
  "Return the plists of the internal sessions, oldest first."
  (sort (harness-call 'session/list (list :kind 'internal))
        (lambda (a b) (< (plist-get a :created) (plist-get b :created)))))

(defun harness-provider-test-last-node (id)
  "Return the content of the last node of session ID."
  (plist-get (car (last (harness-call 'session/nodes id))) :content))

(ert-deftest harness-provider-job-records-one-internal-session ()
  "A request naming its job is recorded as one internal session: its
prompt, the reply, the usage and its end.  The provider never sees the
job, and the caller gets every event as it came."
  (harness-provider-test-with-sessions (test-job)
    (harness-provider-test-job-provider)
    (let* ((cwd (harness-test-temp-dir))
           (parent (plist-get (harness-call 'session/create :cwd cwd :model "test-job:judge") :id))
           (events (list (list :type 'start)
                         (list :type 'text :delta "Al")
                         (list :type 'thinking :delta "hmm")
                         (list :type 'text :delta "low")
                         (list :type 'usage :input 100 :output 4 :cost 0.25)
                         (list :type 'done :stop-reason 'end-turn)))
           (sent (copy-tree events))
           (got nil))
      (harness-call 'provider/complete
                    (list :model "test-job:judge" :job "Permission judge" :job-parent parent
                          :session (list :id (format "%s-perms" parent) :cwd cwd)
                          :messages (list (list :role 'user :content (list (list :type "text" :text "earlier")))
                                          (list :role 'assistant :content (list (list :type "text" :text "ok")))
                                          (list :role 'user
                                                :content (list (list :type "text" :text "Is it safe?")
                                                               (list :type "image" :data "AAAA")
                                                               (list :type "text" :text "Answer ALLOW or DENY."))))
                          :on-event (lambda (e) (push e got))))
      (should (= 1 (length harness-provider-test-requests)))
      (dolist (k '(:job :job-parent :job-project))
        (should-not (plist-member (car harness-provider-test-requests) k)))
      (let* ((internal (harness-provider-test-internal))
             (id (plist-get (car internal) :id)))
        (should (= 1 (length internal)))
        (should (equal "Permission judge" (plist-get (car internal) :name)))
        (should (equal parent (plist-get (car internal) :parent-id)))
        (should (equal "test-job:judge" (plist-get (car internal) :model)))
        (should (equal cwd (plist-get (car internal) :cwd)))
        (should (eq 'running (plist-get (car internal) :status)))
        (should (equal "Is it safe?\n\nAnswer ALLOW or DENY."
                       (plist-get (car (harness-call 'session/nodes id)) :content)))
        (apply #'harness-provider-test-answer events)
        ;; Every event reached the caller, the very one, unchanged.
        (should (= (length events) (length got)))
        (should (cl-every #'eq events (reverse got)))
        (should (equal sent events))
        (let* ((s (harness-call 'session/get id))
               (usage (plist-get s :usage)))
          (should (eq 'idle (plist-get s :status)))
          (should (= 100 (plist-get usage :input)))
          (should (= 4 (plist-get usage :output)))
          (should (= 0.25 (plist-get usage :cost))))
        (should (equal '(user assistant) (mapcar (lambda (n) (plist-get n :kind))
                                                 (harness-call 'session/nodes id))))
        (should (equal "Allow" (harness-provider-test-last-node id)))
        ;; A second `done' records nothing more.
        (harness-provider-test-answer (list :type 'done :stop-reason 'error :error "late"))
        (should (= 2 (length (harness-call 'session/nodes id))))
        ;; The parent and the record, nothing else; the parent is as it was.
        (should (= 2 (length (harness-call 'session/list))))
        (should-not (harness-call 'session/nodes parent))
        (should (= 0 (plist-get (plist-get (harness-call 'session/get parent) :usage) :input)))))))

(ert-deftest harness-provider-job-usage-leaves-the-parents-cache-stamp ()
  "A call made for a session is no request of its conversation.
Its usage counts toward its own internal session, cache tokens and the
time and lifetime it reports included, and the session it was made for
keeps the prompt cache stamp its last request left: neither moved to the
call's time or model, nor dropped."
  (harness-provider-test-with-sessions (test-job)
    (harness-provider-test-job-provider)
    (let* ((cwd (harness-test-temp-dir))
           (parent (plist-get (harness-call 'session/create :cwd cwd :model "test-job:judge") :id))
           (stamp (lambda ()
                    (let ((s (harness-call 'session/get parent)))
                      (list (plist-get s :cache)
                            (plist-get (plist-get s :usage) :cache-at)
                            (plist-get (plist-get s :usage) :cache-model)
                            (plist-get (plist-get s :usage) :input))))))
      (harness-call 'session/usage-add parent '(:input 10 :output 10 :cache-read 900 :context 920
                                                :cache-at 1000.0 :cache-ttl 300))
      (let ((before (funcall stamp)))
        (should (equal 1000.0 (plist-get (car before) :at)))
        (should (equal "test-job:judge" (plist-get (car before) :model)))
        (dolist (usage '((:input 100 :output 4 :cache-read 800 :cache-write 50 :cost 0.25
                          :cache-at 5000.0 :cache-ttl 3600 :model "test-job:other")
                         (:input 100 :output 4 :cost 0.25)))
          (harness-call 'provider/complete
                        (list :model "test-job:judge" :job "Auto-name" :job-parent parent
                              :session (list :id parent :cwd cwd)
                              :messages (list (list :role 'user :content "name it"))
                              :on-event #'ignore))
          (harness-provider-test-answer (append (list :type 'usage) usage)
                                        (list :type 'done :stop-reason 'end-turn))
          (should (equal before (funcall stamp))))
        ;; The calls' usage is theirs: two internal sessions, each with its own.
        (let ((internal (harness-provider-test-internal)))
          (should (equal '(100 100) (mapcar (lambda (s) (plist-get (plist-get s :usage) :input))
                                            internal)))
          (should (= 800 (plist-get (plist-get (car internal) :usage) :cache-read))))))))

(ert-deftest harness-provider-job-finishes-however-the-request-ends ()
  "An error, a cancel, a model the policy refuses, no provider, or a
provider that fails at once: the internal session finishes, idle,
saying why, and the caller hears of it as before."
  (harness-provider-test-with-sessions (test-job test-broken)
    (harness-provider-test-job-provider)
    (harness-define-provider 'test-broken
      :complete (lambda (_request) (error "Cannot connect"))
      :models (lambda () (harness-resolved (list (list :name "m")))))
    (let ((ask (lambda (model)
                 (let ((got nil))
                   (harness-call 'provider/complete
                                 (list :model model :job "Recap" :job-project "/proj/"
                                       :messages (list (list :role 'user :content "recap it"))
                                       :on-event (lambda (e) (push e got))))
                   (list :got got :id (plist-get (car (last (harness-provider-test-internal))) :id)))))
          (finished (lambda (id hint)
                      (let ((s (harness-call 'session/get id)))
                        (should (eq 'idle (plist-get s :status)))
                        (should (equal "/proj/" (plist-get s :project)))
                        (should (equal hint (harness-provider-test-last-node id)))))))
      ;; The provider ends it with an error, or it is cancelled.
      (let ((call (funcall ask "test-job:judge")))
        (harness-provider-test-answer (list :type 'done :stop-reason 'error :error "overloaded"))
        (funcall finished (plist-get call :id) "Error: overloaded"))
      (let ((call (funcall ask "test-job:judge")))
        (harness-provider-test-answer (list :type 'done :stop-reason 'cancelled))
        (funcall finished (plist-get call :id) "The call was cancelled."))
      ;; Refused by the policy: the provider is never asked.
      (harness-test-with-policy '((harness-allowed-models "test-job:other"))
        (let ((call (funcall ask "test-job:judge")))
          (should (= 2 (length harness-provider-test-requests)))
          (should (= 1 (length (plist-get call :got))))
          (should (eq 'error (plist-get (car (plist-get call :got)) :stop-reason)))
          (should (string-match-p "not allowed" (harness-provider-test-last-node (plist-get call :id))))
          (should (eq 'idle (plist-get (harness-call 'session/get (plist-get call :id)) :status)))))
      ;; No provider for the model.
      (let ((call (funcall ask "nope:model")))
        (should (eq 'error (plist-get (car (plist-get call :got)) :stop-reason)))
        (funcall finished (plist-get call :id) "Error: No provider for model nope:model"))
      ;; A provider that fails as it is asked.
      (let ((call (funcall ask "test-broken:m")))
        (should (equal "Cannot connect" (plist-get (car (plist-get call :got)) :error)))
        (funcall finished (plist-get call :id) "Error: Cannot connect"))
      (should (= 5 (length (harness-provider-test-internal)))))))

(ert-deftest harness-provider-without-a-job-records-nothing ()
  "A request that names no job, or a blank one, makes no session."
  (harness-provider-test-with-sessions (test-job)
    (harness-provider-test-job-provider)
    (let ((got nil))
      (harness-call 'provider/complete (list :model "test-job:judge"
                                             :messages (list (list :role 'user :content "hi"))
                                             :on-event (lambda (e) (push e got))))
      (harness-provider-test-answer (list :type 'usage :input 1 :output 1)
                                    (list :type 'done :stop-reason 'end-turn))
      (harness-call 'provider/complete (list :model "test-job:judge" :job "  " :on-event #'ignore))
      (harness-provider-test-answer (list :type 'done :stop-reason 'end-turn))
      (should (= 2 (length got)))
      (should-not (harness-call 'session/list))
      (should-not (plist-member (cadr harness-provider-test-requests) :job)))))

(ert-deftest harness-provider-job-record-and-caller-fail-apart ()
  "A caller whose handler fails does not keep the call from being
recorded, and a record that cannot start keeps no event from the caller."
  (harness-provider-test-with-sessions (test-job)
    (harness-provider-test-job-provider)
    (harness-call 'provider/complete (list :model "test-job:judge" :job "Pet"
                                           :messages (list (list :role 'user :content "hi"))
                                           :on-event (lambda (_) (error "Caller broke"))))
    (let ((id (plist-get (car (harness-provider-test-internal)) :id)))
      (harness-provider-test-answer (list :type 'text :delta "Hello")
                                    (list :type 'done :stop-reason 'end-turn))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status)))
      (should (equal "Hello" (harness-provider-test-last-node id))))
    (harness-register-method 'session/internal-start (lambda (&rest _) (error "Disk full")))
    (let ((got nil))
      (harness-call 'provider/complete (list :model "test-job:judge" :job "Pet"
                                             :on-event (lambda (e) (push e got))))
      (should (= 2 (length harness-provider-test-requests)))
      (should-not (plist-member (car harness-provider-test-requests) :job))
      (harness-provider-test-answer (list :type 'done :stop-reason 'end-turn))
      (should (equal (list (list :type 'done :stop-reason 'end-turn)) got))
      (should (= 1 (length (harness-provider-test-internal)))))))

(provide 'harness-provider-test)
;;; harness-provider-test.el ends here
