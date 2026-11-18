;;; harness-provider-system-one-test.el --- System One decisions: the contract, its failures, its cleanup  -*- lexical-binding: t; -*-

;;; Commentary:

;; The System One capability is part of the provider interface, and these
;; tests hold it to that: a model declares it through its provider's
;; `:system-one' hook, `provider/system-one-p' says which models have it,
;; a request is checked against what the model declares before the
;; provider is called, every answer is checked against the question it
;; answers before a caller reads it, a decision is asynchronous and
;; cancellable, an abstention is explicit, and an artifact says what
;; training and inference agree on.
;;
;; The contract is the System One one -- a state and named, typed
;; questions, answered with typed values -- and the tests are written in
;; those terms: a noul is a probability, a choice is one option with the
;; probabilities of all of them, a score is a position on its levels.
;;
;; Two providers are held to it.  The fixture answers from
;; `test/fixtures/system-one', the same directory the training side
;; writes, so the tests also show one artifact read by both sides.  The
;; Jev adapter is asked against a stub transport, which is how the wire
;; format -- the published `POST /v1/systemone' request and its answer --
;; is checked without a network.
;;
;; A model that completes and answers System One questions is a test of
;; its own: the capability is one a provider may declare, not a kind of
;; provider it must be.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-provider-system-one)
(require 'harness-provider)

(defvar harness-provider-system-one-test--requests nil
  "The requests the stub System One providers got, newest first.")

(defvar harness-provider-system-one-test--completion-requests nil
  "The completion requests the stub provider got, newest first.")

(defvar harness-provider-system-one-test--wire nil
  "The (URL . ARGS) of each request the stub System One transport got, newest first.")

(defvar harness-provider-system-one-test--wire-answers nil
  "What the stub System One transport answers: a list of (STATUS . BODY).")

(defconst harness-provider-system-one-test--fixture
  (expand-file-name "test/fixtures/system-one/" harness-test-root)
  "The fixture directory the training side and the inference side share.")

(defconst harness-provider-system-one-test--state
  "Yes, run it, and tell me when the migration finishes."
  "The state of case c3 of the fixture.")

(defconst harness-provider-system-one-test--questions
  '(:same-thread (:type "noul"
                 :instructions "Is the message a continuation of the thread?")
    :next-step (:type "choice"
                :instructions "What should the harness do with this message?"
                :criteria (:continue "The thread carries on."
                           :new "The message starts something else."))
    :topic-cue (:type "score"
                :instructions "How strongly does the topic match?"
                :criteria ("no topic in common" "one topic in common" "the same topic")))
  "The three questions the fixture's artifact says its model answers.")

;;;; Harness

(defmacro harness-provider-system-one-test--with (&rest body)
  "Run BODY with a fresh bus and the modules a System One model needs."
  (declare (indent 0))
  `(progn
     (harness-test-reset-bus)
     (dolist (m '(project config provider provider-system-one))
       (harness-test-load-module m))
     (setq harness-provider-system-one-test--requests nil
           harness-provider-system-one-test--completion-requests nil
           harness-provider-system-one-test--wire nil
           harness-provider-system-one-test--wire-answers nil)
     (unwind-protect
         (harness-test-with-temp-state
           (clrhash harness-providers)
           (clrhash harness-provider--lifecycle)
           (clrhash harness-provider-system-one--calls)
           ,@body)
       (dolist (id (hash-table-keys harness-providers))
         (harness-provider-unregister id))
       (clrhash harness-provider-system-one--calls))))

(defun harness-provider-system-one-test--request (&rest args)
  "Return a sound request to model fixture:fixture, with ARGS over its keys."
  (harness-plist-merge (list :model "fixture:fixture"
                             :state harness-provider-system-one-test--state
                             :questions harness-provider-system-one-test--questions)
                       args))

(defun harness-provider-system-one-test--settled (handle &optional timeout)
  "Return (STATE . VALUE) of HANDLE's promise once it settles."
  (let ((promise (plist-get handle :promise))
        (deadline (+ (float-time) (or timeout 5))))
    (while (and (not (harness-promise-settled-p promise)) (< (float-time) deadline))
      (accept-process-output nil 0.02)
      (sit-for 0.005))
    (cons (harness-promise-state promise) (harness-promise-value promise))))

(defun harness-provider-system-one-test--rejected (handle &optional timeout)
  "Return the message HANDLE rejected with; fail when it resolved."
  (let ((settled (harness-provider-system-one-test--settled handle timeout)))
    (should (eq 'rejected (car settled)))
    (harness-error-message (cdr settled))))

(defun harness-provider-system-one-test--resolved (handle &optional timeout)
  "Return the result HANDLE resolved with; fail when it rejected."
  (let ((settled (harness-provider-system-one-test--settled handle timeout)))
    (should (eq 'resolved (car settled)))
    (cdr settled)))

(defun harness-provider-system-one-test--all-questions ()
  "Return the capabilities a model answering the fixture's questions declares."
  '(:noul t :choice t :score t :abstain t :confidence t))

(defun harness-provider-system-one-test--register (id &rest args)
  "Register provider ID with a System One model.
ARGS are `harness-define-provider''s.  A `:system-one' given is used;
without one the model never answers, and records what it was asked."
  (let ((system-one (plist-get args :system-one))
        (models (plist-get args :models)))
    (apply #'harness-define-provider id
           :models (or models
                       (lambda ()
                         (harness-resolved
                          (list (list :name "fixture" :label "Fixture" :context-window 1
                                      :capabilities (or (plist-get args :capabilities)
                                                        (harness-provider-system-one-test--all-questions)))))))
           :system-one (or system-one
                           (lambda (_name request)
                             (push request harness-provider-system-one-test--requests)
                             (harness-make-promise)))
           (harness-plist-remove args :capabilities :system-one :models))))

;;;; The capability on the provider interface

(ert-deftest harness-provider-system-one-is-a-provider-capability ()
  "A provider declares System One, and `provider/system-one-p' says which models have it."
  (harness-provider-system-one-test--with
    ;; A provider that only completes does not answer System One
    ;; questions: it is the same interface, another capability.
    (harness-define-provider
     'completer
     :models (lambda () (harness-resolved (list (list :name "chat" :context-window 1))))
     :complete (lambda (_request) (list :cancel #'ignore)))
    (should-not (harness-call 'provider/system-one-p "completer:chat"))
    (harness-provider-system-one-test--register 'fixture)
    (should (harness-call 'provider/system-one-p "fixture:fixture"))
    ;; A model of no provider, and a provider that does not answer System
    ;; One questions, are neither of them System One models.
    (should-not (harness-call 'provider/system-one-p "nobody:model"))
    ;; Asking a provider that does not answer them says so, and it is
    ;; never called.
    (let ((handle (harness-call 'provider/system-one
                                "completer:chat"
                                (harness-provider-system-one-test--request :model "completer:chat"))))
      (should (string-match-p "does not answer System One"
                              (harness-provider-system-one-test--rejected handle))))
    (should-not harness-provider-system-one-test--requests)))

(ert-deftest harness-provider-system-one-one-model-may-do-both ()
  "A model that completes and answers System One questions declares both.
The capability is a property of the model, not a kind of provider, so
nothing here forbids a model that does both -- which is what a future
model that predicts tokens and answers System One questions would be."
  (harness-provider-system-one-test--with
    (let ((completed nil))
      (harness-define-provider
       'both
       :models (lambda ()
                 (harness-resolved
                  (list (list :name "dual" :context-window 1
                              :capabilities (harness-provider-system-one-test--all-questions)))))
       :complete (lambda (_request) (setq completed t) (list :cancel #'ignore))
       :system-one (lambda (_name _request)
                     (harness-resolved
                      (list :provider 'both
                            :answers '(:same-thread (:type "noul" :noul 0.9))))))
      ;; Both capabilities answer, on the one model.
      (should (harness-call 'provider/system-one-p "both:dual"))
      (should (equal "dual" (plist-get (harness-call 'provider/model "both:dual") :name)))
      (let ((result (harness-provider-system-one-test--resolved
                     (harness-call 'provider/system-one
                                   "both:dual"
                                   (harness-provider-system-one-test--request
                                    :model "both:dual"
                                    :questions '(:same-thread (:type "noul" :instructions "Same?")))))))
        (should (= 0.9 (harness-provider-system-one-answer-value
                        (harness-provider-system-one-answer result "same-thread")))))
      ;; And the completion path is untouched by it.
      (harness-call 'provider/complete (list :model "both:dual" :messages nil :on-event #'ignore))
      (should completed))))

(ert-deftest harness-provider-system-one-a-model-lists-its-capabilities ()
  "The capabilities a System One model declares are read from its catalogue entry."
  (harness-provider-system-one-test--with
    (harness-provider-system-one-test--register
     'fixture :capabilities '(:noul t :choice t :calibrated t :vision t))
    (should (equal '(:noul t :choice t :score nil :box nil :images nil :long-context nil
                     :confidence nil :calibrated t :abstain nil :stream nil :audio nil
                     :embeddings nil :carried-state nil :schema nil)
                   (harness-provider-system-one-capabilities "fixture:fixture")))
    ;; A capability this contract does not know is not read, and the
    ;; completion capability beside it is untouched.
    (should (harness-provider-system-one-can-p "fixture:fixture" :calibrated))
    (should-not (harness-provider-system-one-can-p "fixture:fixture" :box))
    (should (plist-get (harness-call 'provider/model "fixture:fixture") :capabilities))))

;;;; The request

(ert-deftest harness-provider-system-one-request-is-validated ()
  "A request names a model, content to judge, and at least one typed question."
  (harness-provider-system-one-test--with
    (harness-provider-system-one-test--register 'fixture)
    (should-not (harness-provider-system-one-validate
                 (harness-provider-system-one-test--request)))
    ;; No model, and a model that is not one.
    (should (string-match-p "names its model"
                            (string-join
                             (harness-provider-system-one-validate
                              (harness-provider-system-one-test--request :model nil))
                             " ")))
    (should (string-match-p "not a System One model"
                            (string-join
                             (harness-provider-system-one-validate
                              (harness-provider-system-one-test--request :model "nobody:x"))
                             " ")))
    ;; No content, empty content, and content that is neither text nor a
    ;; JSON value.
    (dolist (state (list nil "   " 42))
      (should (string-match-p "content to judge\\|:state is"
                              (string-join
                               (harness-provider-system-one-validate
                                (harness-provider-system-one-test--request :state state))
                               " "))))
    ;; A request with no questions, a question with no type, and two
    ;; questions of one name.
    (should (string-match-p "at least one question"
                            (string-join
                             (harness-provider-system-one-validate
                              (harness-provider-system-one-test--request :questions nil))
                             " ")))
    (should (string-match-p "names its type"
                            (string-join
                             (harness-provider-system-one-validate
                              (harness-provider-system-one-test--request
                               :questions '(:q (:instructions "Which?"))))
                             " ")))
    (should (string-match-p "Two questions are named q"
                            (string-join
                             (harness-provider-system-one-validate
                              (harness-provider-system-one-test--request
                               :questions (list :q (list :type "noul" :instructions "Same?")
                                                :q (list :type "noul" :instructions "Again?"))))
                             " ")))
    ;; A choice needs its options, a score its levels, a box nothing but
    ;; its instructions.
    (should (string-match-p "names the options"
                            (string-join
                             (harness-provider-system-one-validate
                              (harness-provider-system-one-test--request
                               :questions '(:q (:type "choice" :instructions "Which?"))))
                             " ")))
    (should (string-match-p "ordered levels"
                            (string-join
                             (harness-provider-system-one-validate
                              (harness-provider-system-one-test--request
                               :questions '(:q (:type "score" :instructions "How much?"))))
                             " ")))
    ;; A schema version this module does not speak.
    (should (string-match-p "Schema version 2"
                            (string-join
                             (harness-provider-system-one-validate
                              (harness-provider-system-one-test--request :schema-version 2))
                             " ")))))

(ert-deftest harness-provider-system-one-question-types-are-capabilities ()
  "A question type a model does not answer is refused before it is called."
  (harness-provider-system-one-test--with
    (harness-provider-system-one-test--register 'fixture :capabilities '(:noul t :abstain t))
    ;; A choice is not a noul: the model says so, and is never asked.
    (let ((problems (harness-provider-system-one-validate
                     (harness-provider-system-one-test--request
                      :questions '(:same-thread (:type "noul" :instructions "Same?")
                                   :next-step (:type "choice"
                                               :instructions "What next?"
                                               :criteria (:a "A" :b "B")))))))
      (should (string-match-p "does not answer choice" (string-join problems " ")))
      (should (string-match-p "next-step" (string-join problems " "))))
    (let ((handle (harness-call 'provider/system-one
                                "fixture:fixture"
                                (harness-provider-system-one-test--request
                                 :questions '(:q (:type "score" :instructions "How?"
                                                 :criteria ("low" "high")))))))
      (should (string-match-p "does not answer score"
                              (harness-provider-system-one-test--rejected handle)))
      (should-not harness-provider-system-one-test--requests))
    ;; A box question needs a model that reads images.
    (harness-provider-system-one-test--register 'fixture :capabilities '(:box t))
    (should (string-match-p "does not read images"
                            (string-join (harness-provider-system-one-validate
                                          (harness-provider-system-one-test--request
                                           :questions '(:where (:type "box"
                                                                :instructions "Where?"))))
                                         " ")))))

(ert-deftest harness-provider-system-one-optional-capabilities-are-gated ()
  "A request for a capability the model does not declare is refused before it is called."
  (harness-provider-system-one-test--with
    (harness-provider-system-one-test--register
     'fixture :capabilities (harness-provider-system-one-test--all-questions))
    (dolist (gate '((:assets (:where (:type "image" :data_base64 "AAA")) "images")
                    (:long-context t "long context")
                    (:audio t "audio")
                    (:embeddings t "embeddings")
                    (:carried-state t "carried-over state")
                    (:response-schema (:type "object") "a response schema")
                    (:on-partial #'ignore "streaming")))
      (let ((problems (harness-provider-system-one-validate
                       (harness-provider-system-one-test--request (car gate) (cadr gate)))))
        (should (string-match-p (regexp-quote (caddr gate)) (string-join problems " ")))))
    ;; A model that declares them is asked.
    (harness-provider-system-one-test--register
     'fixture :capabilities (append (harness-provider-system-one-test--all-questions)
                                    '(:images t :long-context t :audio t :embeddings t
                                      :carried-state t :schema t :stream t)))
    (should-not (harness-provider-system-one-validate
                 (harness-provider-system-one-test--request
                  :long-context t :on-partial #'ignore)))))

;;;; The result

(ert-deftest harness-provider-system-one-result-is-validated ()
  "A result answers every question once, of its type; anything else is refused."
  (harness-provider-system-one-test--with
    (harness-provider-system-one-test--register 'fixture)
    (let ((request (harness-provider-system-one-test--request))
          (base (list :provider 'fixture :schema-version 1
                      :answers '(:same-thread (:type "noul" :noul 0.9)
                                 :next-step (:type "choice" :choice "continue"
                                             :probabilities (:continue 0.9 :new 0.1)
                                             :confidence 0.9)
                                 :topic-cue (:type "score" :score 1.4
                                             :legend (:0 "a" :1 "b" :2 "c")
                                             :probabilities (:0 0.1 :1 0.4 :2 0.5)
                                             :confidence 0.7)))))
      (should-not (harness-provider-system-one-result-problems "fixture:fixture" request base))
      ;; A question nobody answered.
      (should (string-match-p "Nothing answers"
                              (string-join
                               (harness-provider-system-one-result-problems
                                "fixture:fixture" request
                                (plist-put (copy-sequence base) :answers
                                           '(:same-thread (:type "noul" :noul 0.9))))
                               " ")))
      ;; An answer to a question nobody asked.
      (should (string-match-p "not a question"
                              (string-join
                               (harness-provider-system-one-result-problems
                                "fixture:fixture" request
                                (plist-put (copy-sequence base) :answers
                                           (append (plist-get base :answers)
                                                   '(:extra (:type "noul" :noul 0.5)))))
                               " ")))
      ;; Neither answers nor an abstention.
      (should (string-match-p "not neither"
                              (string-join
                               (harness-provider-system-one-result-problems
                                "fixture:fixture" request
                                (harness-plist-remove base :answers))
                               " ")))
      ;; Another provider's answer.
      (should (string-match-p "not fixture"
                              (string-join
                               (harness-provider-system-one-result-problems
                                "fixture:fixture" request
                                (plist-put (copy-sequence base) :provider 'elsewhere))
                               " "))))))

(ert-deftest harness-provider-system-one-answer-is-typed ()
  "Every answer type says what its question asked, and nothing it did not offer."
  (harness-provider-system-one-test--with
    (let ((noul '(:type "noul" :instructions "Same?"))
          (choice '(:type "choice" :instructions "Which?"
                    :criteria (:continue "The thread carries on." :new "Something else.")))
          (score '(:type "score" :instructions "How much?"
                   :criteria ("low" "middle" "high")))
          (box '(:type "box" :instructions "Where?")))
      ;; A noul is a probability.
      (should-not (harness-provider-system-one-answer-problems noul '(:type "noul" :noul 0.5)))
      (should (string-match-p "from 0 to 1"
                              (string-join (harness-provider-system-one-answer-problems
                                            noul '(:type "noul" :noul 1.5))
                                           " ")))
      ;; A choice is one of the options, with the probability of each.
      (should-not (harness-provider-system-one-answer-problems
                   choice '(:type "choice" :choice "continue"
                            :probabilities (:continue 0.8 :new 0.2) :confidence 0.8)))
      (should (string-match-p "not one of the question's options"
                              (string-join (harness-provider-system-one-answer-problems
                                            choice '(:type "choice" :choice "maybe"
                                                     :probabilities (:continue 0.5 :new 0.5)))
                                           " ")))
      (should (string-match-p "names other"
                              (string-join (harness-provider-system-one-answer-problems
                                            choice '(:type "choice" :choice "continue"
                                                     :probabilities (:continue 0.5 :other 0.5)))
                                           " ")))
      ;; A score lies on its levels, and its legend names them.
      (should-not (harness-provider-system-one-answer-problems
                   score '(:type "score" :score 1.5 :legend (:0 "low" :1 "middle" :2 "high")
                           :probabilities (:0 0.1 :1 0.3 :2 0.6) :confidence 0.6)))
      (should (string-match-p "outside the question's levels"
                              (string-join (harness-provider-system-one-answer-problems
                                            score '(:type "score" :score 4
                                                    :legend (:0 "low" :1 "middle" :2 "high")
                                                    :probabilities (:0 0.1 :1 0.3 :2 0.6)))
                                           " ")))
      (should (string-match-p "legend names its levels"
                              (string-join (harness-provider-system-one-answer-problems
                                            score '(:type "score" :score 1
                                                    :legend (:0 "low" :1 "middle")
                                                    :probabilities (:0 0.5 :1 0.5)))
                                           " ")))
      ;; A box's edges are fractions in order.
      (should-not (harness-provider-system-one-answer-problems
                   box '(:type "box" :box (:top 0.1 :bottom 0.9 :left 0.2 :right 0.8)
                         :confidence 0.9)))
      (should (string-match-p ":top is above its :bottom"
                              (string-join (harness-provider-system-one-answer-problems
                                            box '(:type "box"
                                                  :box (:top 0.9 :bottom 0.1 :left 0.2 :right 0.8)))
                                           " ")))
      ;; The type of the answer is the type of its question.
      (should (string-match-p "the question asks a noul question"
                              (string-join (harness-provider-system-one-answer-problems
                                            noul '(:type "score" :score 1 :legend (:0 "a")
                                                   :probabilities (:0 1.0)))
                                           " "))))))

(ert-deftest harness-provider-system-one-confidence-is-not-calibration ()
  "A confidence is read as a probability of being right only with both halves."
  (harness-provider-system-one-test--with
    (let ((request (harness-provider-system-one-test--request
                    :questions '(:same-thread (:type "noul" :instructions "Same?"))))
          (artifact (list :schema-version 1
                          :artifact (list :id "m" :version "1")
                          :model (list :id "m" :version "1")
                          :questions '(:same-thread (:type "noul" :instructions "Same?"))
                          :dataset (list :name "d" :version "1" :provenance "synthetic" :splits nil)
                          :evaluation (list :split "eval" :metrics nil
                                            :calibration (list :method "none"))
                          :runtime (list :kind "local"))))
      ;; A model that declares no calibration cannot claim one.
      (harness-provider-system-one-test--register 'fixture)
      (should (string-match-p "does not declare its confidences calibrated"
                              (string-join
                               (harness-provider-system-one-result-problems
                                "fixture:fixture" request
                                (list :provider 'fixture :schema-version 1 :calibrated t
                                      :artifact artifact
                                      :answers '(:same-thread (:type "noul" :noul 0.9))))
                               " ")))
      ;; Declaring it is not enough: the artifact has to say how.
      (harness-provider-system-one-test--register 'fixture :capabilities '(:noul t :calibrated t))
      (should (string-match-p "says how it was fitted"
                              (string-join
                               (harness-provider-system-one-result-problems
                                "fixture:fixture" request
                                (list :provider 'fixture :schema-version 1 :calibrated t
                                      :artifact artifact
                                      :answers '(:same-thread (:type "noul" :noul 0.9))))
                               " ")))
      ;; With both, it is a calibration, and the artifact is valid.
      (should-not (harness-provider-system-one-artifact-problems artifact))
      (let ((fitted (harness-plist-merge
                     artifact (list :evaluation
                                    (list :split "eval" :metrics nil
                                          :calibration (list :method "platt"
                                                             :source "docs/calibration.md"))))))
        (should-not (harness-provider-system-one-result-problems
                     "fixture:fixture" request
                     (list :provider 'fixture :schema-version 1 :calibrated t
                           :artifact fitted
                           :answers '(:same-thread (:type "noul" :noul 0.9)))))))))

(ert-deftest harness-provider-system-one-abstains-wholesale ()
  "A model that will not answer says so once, with a reason, and answers nothing."
  (harness-provider-system-one-test--with
    (let ((request (harness-provider-system-one-test--request
                    :questions '(:same-thread (:type "noul" :instructions "Same?")))))
      ;; Without the capability, an abstention is refused.
      (harness-provider-system-one-test--register 'fixture :capabilities '(:noul t))
      (should (string-match-p "does not declare that it may abstain"
                              (string-join
                               (harness-provider-system-one-result-problems
                                "fixture:fixture" request
                                (list :provider 'fixture :schema-version 1
                                      :abstained t :reason "not enough context"))
                               " ")))
      ;; With it, an abstention is a result.
      (harness-provider-system-one-test--register 'fixture :capabilities '(:noul t :abstain t))
      (should-not (harness-provider-system-one-result-problems
                   "fixture:fixture" request
                   (list :provider 'fixture :schema-version 1
                         :abstained t :reason "not enough context")))
      ;; An abstention says why, and does not also answer.
      (should (string-match-p "says why"
                              (string-join
                               (harness-provider-system-one-result-problems
                                "fixture:fixture" request
                                (list :provider 'fixture :schema-version 1 :abstained t))
                               " ")))
      (should (string-match-p "one or the other"
                              (string-join
                               (harness-provider-system-one-result-problems
                                "fixture:fixture" request
                                (list :provider 'fixture :schema-version 1 :abstained t
                                      :reason "not enough context"
                                      :answers '(:same-thread (:type "noul" :noul 0.5))))
                               " "))))))

;;;; Deciding

(ert-deftest harness-provider-system-one-decides-asynchronously ()
  "`provider/system-one' returns before the model answers, and settles once."
  (harness-provider-system-one-test--with
    (let ((promise (harness-make-promise)))
      (harness-provider-system-one-test--register
       'fixture
       :system-one (lambda (_name request)
                     (push request harness-provider-system-one-test--requests)
                     (run-at-time 0.05 nil
                                  (lambda ()
                                    (harness-resolve
                                     promise
                                     (list :provider 'fixture :schema-version 1
                                           :answers '(:same-thread (:type "noul" :noul 0.75))))))
                     (list :promise promise :cancel #'ignore)))
      (let ((handle (harness-call 'provider/system-one
                                  "fixture:fixture"
                                  (harness-provider-system-one-test--request
                                   :questions '(:same-thread (:type "noul" :instructions "Same?"))))))
        ;; The call returns a handle before the answer arrives.
        (should (plist-get handle :promise))
        (should-not (harness-promise-settled-p (plist-get handle :promise)))
        (should (equal "fixture:fixture" (plist-get handle :model)))
        (should (eq 'fixture (plist-get handle :provider)))
        (let ((result (harness-provider-system-one-test--resolved handle)))
          (should (= 0.75 (harness-provider-system-one-answer-value
                           (harness-provider-system-one-answer result "same-thread"))))
          ;; The provider was asked once, and the model is filled in.
          (should (= 1 (length harness-provider-system-one-test--requests)))
          (should (equal 'fixture (plist-get result :provider))))))))

(ert-deftest harness-provider-system-one-cancels-a-running-decision ()
  "A decision is cancelled through its handle, and a late answer is dropped."
  (harness-provider-system-one-test--with
    (let ((cancelled nil)
          (promise (harness-make-promise)))
      (harness-provider-system-one-test--register
       'fixture
       :system-one (lambda (_name _request)
                     (list :promise promise
                           :cancel (lambda () (setq cancelled t)))))
      (let* ((handle (harness-call 'provider/system-one
                                   "fixture:fixture"
                                   (harness-provider-system-one-test--request
                                    :questions '(:same-thread (:type "noul" :instructions "Same?")))))
             (call (plist-get handle :call)))
        (should (harness-provider-system-one-cancel handle))
        (should cancelled)
        (should (string-match-p "cancelled"
                                (harness-provider-system-one-test--rejected handle)))
        ;; Cancelling again, and cancelling a settled call, change nothing.
        (should-not (harness-provider-system-one-cancel call))
        ;; The provider answering afterwards is dropped, not read.
        (harness-resolve promise (list :provider 'fixture :schema-version 1
                                       :answers '(:same-thread (:type "noul" :noul 0.5))))
        (should (eq 'rejected (harness-promise-state (plist-get handle :promise))))))))

(ert-deftest harness-provider-system-one-times-out-a-decision ()
  "A decision past its deadline is cancelled and rejects."
  (harness-provider-system-one-test--with
    (let ((cancelled nil))
      (harness-provider-system-one-test--register
       'fixture
       :system-one (lambda (_name _request)
                     (list :promise (harness-make-promise)
                           :cancel (lambda () (setq cancelled t)))))
      (let ((handle (harness-call 'provider/system-one
                                  "fixture:fixture"
                                  (harness-provider-system-one-test--request
                                   :deadline 0.1
                                   :questions '(:same-thread (:type "noul" :instructions "Same?"))))))
        (should (string-match-p "took longer than"
                                (harness-provider-system-one-test--rejected handle 5)))
        (should cancelled)))))

(ert-deftest harness-provider-system-one-drops-stale-and-concurrent-answers ()
  "An answer that arrives after the call settled is dropped, and one settles once."
  (harness-provider-system-one-test--with
    (let ((promise (harness-make-promise)))
      (harness-provider-system-one-test--register
       'fixture
       :system-one (lambda (_name _request) (list :promise promise)))
      (let* ((handle (harness-call 'provider/system-one
                                   "fixture:fixture"
                                   (harness-provider-system-one-test--request
                                    :questions '(:same-thread (:type "noul" :instructions "Same?")))))
             (call (plist-get handle :call)))
        (harness-resolve promise (list :provider 'fixture :schema-version 1
                                       :answers '(:same-thread (:type "noul" :noul 0.25))))
        (let ((result (harness-provider-system-one-test--resolved handle)))
          (should (= 0.25 (harness-provider-system-one-answer-value
                           (harness-provider-system-one-answer result "same-thread")))))
        ;; The call is settled, so a second answer to it is not read: the
        ;; handle is no longer the one the registry holds.
        (should-not (gethash call harness-provider-system-one--calls))
        (should-not (harness-provider-system-one-cancel call))))))

(ert-deftest harness-provider-system-one-a-late-answer-after-cancel-is-dropped ()
  "A provider that answers after its call was cancelled does not settle it."
  (harness-provider-system-one-test--with
    (let ((promise (harness-make-promise)))
      (harness-provider-system-one-test--register
       'fixture
       :system-one (lambda (_name _request) (list :promise promise :cancel #'ignore)))
      (let ((handle (harness-call 'provider/system-one
                                  "fixture:fixture"
                                  (harness-provider-system-one-test--request
                                   :questions '(:same-thread (:type "noul" :instructions "Same?"))))))
        (should (harness-provider-system-one-cancel handle))
        ;; The answer arrives afterwards, and is not read.
        (harness-resolve promise (list :provider 'fixture :schema-version 1
                                       :answers '(:same-thread (:type "noul" :noul 0.99))))
        (should (string-match-p "cancelled"
                                (harness-provider-system-one-test--rejected handle)))))))

(ert-deftest harness-provider-system-one-failing-provider-is-no-decision ()
  "A provider that signals, or answers with no promise, gives no decision."
  (harness-provider-system-one-test--with
    (harness-provider-system-one-test--register
     'fixture
     :system-one (lambda (_name _request) (error "the model is unavailable")))
    (let ((handle (harness-call 'provider/system-one
                                "fixture:fixture"
                                (harness-provider-system-one-test--request
                                 :questions '(:same-thread (:type "noul" :instructions "Same?"))))))
      (should (string-match-p "unavailable"
                              (harness-provider-system-one-test--rejected handle))))
    (harness-provider-system-one-test--register
     'fixture
     :system-one (lambda (_name _request) nil))
    (let ((handle (harness-call 'provider/system-one
                                "fixture:fixture"
                                (harness-provider-system-one-test--request
                                 :questions '(:same-thread (:type "noul" :instructions "Same?"))))))
      (should (string-match-p "returned no promise"
                              (harness-provider-system-one-test--rejected handle))))))

(ert-deftest harness-provider-system-one-a-malformed-answer-is-refused ()
  "An answer the contract refuses never reaches the caller."
  (harness-provider-system-one-test--with
    (harness-provider-system-one-test--register
     'fixture
     :system-one (lambda (_name _request)
                   (harness-resolved
                    (list :provider 'fixture :schema-version 1
                          :answers '(:same-thread (:type "noul" :noul 7))))))
    (let ((handle (harness-call 'provider/system-one
                                "fixture:fixture"
                                (harness-provider-system-one-test--request
                                 :questions '(:same-thread (:type "noul" :instructions "Same?"))))))
      (should (string-match-p "malformed result"
                              (harness-provider-system-one-test--rejected handle))))))

(ert-deftest harness-provider-system-one-refuses-a-model-not-allowed ()
  "A model `harness-allowed-models' does not allow is not asked."
  (harness-provider-system-one-test--with
    (harness-provider-system-one-test--register 'fixture)
    (let ((harness-allowed-models '("other:*")))
      (let ((handle (harness-call 'provider/system-one
                                  "fixture:fixture"
                                  (harness-provider-system-one-test--request
                                   :questions '(:same-thread (:type "noul" :instructions "Same?"))))))
        (should (string-match-p "not allowed"
                                (harness-provider-system-one-test--rejected handle)))
        (should-not harness-provider-system-one-test--requests)))))

;;;; The artifact

(ert-deftest harness-provider-system-one-artifact-is-validated ()
  "The artifact says what training and inference must agree on."
  (harness-provider-system-one-test--with
    (let ((artifact (list :schema-version 1
                          :artifact (list :id "thread-continuation-fixture" :version "2.0.0")
                          :model (list :id "fixture-logreg" :version "0.2.0")
                          :questions harness-provider-system-one-test--questions
                          :dataset (list :name "thread-continuation-cases" :version "2.0.0"
                                         :provenance "synthetic cases; no transcript"
                                         :splits (list (list :name "train" :count 4)
                                                       (list :name "eval" :count 2)))
                          :evaluation (list :split "eval"
                                            :metrics (list (list :name "accuracy" :value 1.0))
                                            :calibration (list :method "none"))
                          :runtime (list :kind "local" :requires (list "the fixture directory")))))
      (should-not (harness-provider-system-one-artifact-problems artifact))
      ;; Every part it must name.
      (dolist (key '(:artifact :model :questions :dataset :evaluation :runtime))
        (should (string-match-p (regexp-quote (substring (symbol-name key) 1))
                                (string-join
                                 (harness-provider-system-one-artifact-problems
                                  (harness-plist-remove artifact key))
                                 " "))))
      ;; A version it does not speak.
      (should (string-match-p "Schema version 2"
                              (string-join
                               (harness-provider-system-one-artifact-problems
                                (plist-put (copy-sequence artifact) :schema-version 2))
                               " ")))
      ;; A calibration that was fitted says where it is documented.
      (should (string-match-p "where that is documented"
                              (string-join
                               (harness-provider-system-one-artifact-problems
                                (plist-put (copy-sequence artifact) :evaluation
                                           (list :split "eval" :metrics nil
                                                 :calibration (list :method "platt"))))
                               " ")))
      ;; A split the dataset does not have.
      (should (string-match-p "not one the dataset has"
                              (string-join
                               (harness-provider-system-one-artifact-problems
                                (plist-put (copy-sequence artifact) :evaluation
                                           (list :split "test" :metrics nil
                                                 :calibration (list :method "none"))))
                               " ")))
      ;; A runtime that is neither local nor remote.
      (should (string-match-p "local or remote"
                              (string-join
                               (harness-provider-system-one-artifact-problems
                                (plist-put (copy-sequence artifact) :runtime (list :kind "cloud")))
                               " "))))))

(ert-deftest harness-provider-system-one-artifact-agrees-with-a-request ()
  "A request that asks what the artifact was not made for is refused."
  (harness-provider-system-one-test--with
    (let ((artifact (list :schema-version 1
                          :artifact (list :id "a" :version "1")
                          :model (list :id "m" :version "1")
                          :questions harness-provider-system-one-test--questions
                          :dataset (list :name "d" :version "1" :provenance "p" :splits nil)
                          :evaluation (list :split "eval" :metrics nil
                                            :calibration (list :method "none"))
                          :runtime (list :kind "local"))))
      ;; The request it was made for.
      (should-not (harness-provider-system-one-artifact-agrees-p
                   artifact (harness-provider-system-one-test--request)))
      ;; A question it does not ask.
      (should (string-match-p "does not ask next-step"
                              (string-join
                               (harness-provider-system-one-artifact-agrees-p
                                artifact
                                (harness-provider-system-one-test--request
                                 :questions '(:same-thread (:type "noul" :instructions "Same?"))))
                               " ")))
      ;; Another type for one of them.
      (should (string-match-p "asks topic-cue as a noul question"
                              (string-join
                               (harness-provider-system-one-artifact-agrees-p
                                artifact
                                (harness-provider-system-one-test--request
                                 :questions '(:same-thread (:type "noul" :instructions "Same?")
                                              :next-step (:type "choice" :instructions "What?"
                                                          :criteria (:continue "a" :new "b"))
                                              :topic-cue (:type "noul" :instructions "Same topic?"))))
                               " ")))
      ;; Another option set.
      (should (string-match-p "to choose among"
                              (string-join
                               (harness-provider-system-one-artifact-agrees-p
                                artifact
                                (harness-provider-system-one-test--request
                                 :questions '(:same-thread (:type "noul" :instructions "Same?")
                                              :next-step (:type "choice" :instructions "What?"
                                                          :criteria (:continue "a" :other "b"))
                                              :topic-cue (:type "score" :instructions "How?"
                                                          :criteria ("a" "b" "c")))))
                               " "))))))

;;;; The fixture provider

(ert-deftest harness-provider-system-one-fixture-answers-from-the-shared-artifact ()
  "The fixture answers a case's state with the case's answers, and abstains otherwise."
  (harness-provider-system-one-test--with
    (harness-provider-system-one-register-fixture 'fixture harness-provider-system-one-test--fixture)
    (should (harness-call 'provider/system-one-p "fixture:fixture"))
    ;; The artifact travels with the model, and it is the one the training
    ;; side wrote.
    (let* ((model (harness-call 'provider/model "fixture:fixture"))
           (artifact (plist-get model :artifact)))
      (should (equal "thread-continuation-fixture"
                     (plist-get (plist-get artifact :artifact) :id)))
      (should-not (harness-provider-system-one-artifact-problems artifact))
      (should-not (harness-provider-system-one-artifact-agrees-p
                   artifact (harness-provider-system-one-test--request))))
    ;; The state of case c3 is answered with c3's answers.
    (let ((result (harness-provider-system-one-test--resolved
                   (harness-call 'provider/system-one
                                 "fixture:fixture"
                                 (harness-provider-system-one-test--request)))))
      (should (equal "continue" (harness-provider-system-one-answer-value
                                 (harness-provider-system-one-answer result "next-step"))))
      (should (= 0.99 (harness-provider-system-one-answer-value
                       (harness-provider-system-one-answer result "same-thread"))))
      ;; The model that answered is the fixture's.
      (should (equal "fixture:fixture" (plist-get result :model))))
    ;; A state no case has is abstained from, saying so.
    (let ((result (harness-provider-system-one-test--resolved
                   (harness-call 'provider/system-one
                                 "fixture:fixture"
                                 (harness-provider-system-one-test--request
                                  :state "A state no case has.")))))
      (should (harness-json-true-p (plist-get result :abstained)))
      (should (string-match-p "no case" (plist-get result :reason))))))

(ert-deftest harness-provider-system-one-fixture-needs-its-artifact ()
  "A fixture directory without a sound artifact is not a provider."
  (harness-provider-system-one-test--with
    (let ((directory (make-temp-file "system-one-fixture-" t)))
      (unwind-protect
          (progn
            ;; No artifact at all.
            (should-error (harness-provider-system-one-register-fixture 'broken directory))
            ;; An artifact that names no questions.
            (with-temp-file (expand-file-name "artifact.json" directory)
              (insert (harness-json-encode
                       (list :schema-version 1
                             :artifact (list :id "a" :version "1")
                             :model (list :id "m" :version "1")
                             :questions nil
                             :dataset (list :name "d" :version "1" :provenance "p" :splits nil)
                             :evaluation (list :split "eval" :metrics nil
                                               :calibration (list :method "none"))
                             :runtime (list :kind "local")))))
            (with-temp-file (expand-file-name "cases.jsonl" directory) (insert ""))
            (should-error (harness-provider-system-one-register-fixture 'broken directory)))
        (delete-directory directory t)))))

;;;; The System One API

(defconst harness-provider-system-one-test--jev-answer
  (list :model "jev-1.14.0"
        :answers (list :same-thread (list :type "noul" :noul 0.96)
                       :next-step (list :type "choice"
                                        :choice "continue"
                                        :confidence 0.91
                                        :probabilities (list :continue 0.91
                                                             :new 0.09))
                       :topic-cue (list :type "score"
                                        :score 1.7
                                        :confidence 0.6
                                        :legend (list :0 "no topic in common"
                                                      :1 "one topic in common"
                                                      :2 "the same topic")
                                        :probabilities (list :0 0.05
                                                             :1 0.2
                                                             :2 0.75)))
        :usage (list :input_tokens 349 :output_tokens 39))
  "What the System One API answers the fixture's three questions.")

(defun harness-provider-system-one-test--says (status body)
  "Return a transport that answers STATUS with BODY and records the request.
BODY is a plist, encoded as the API encodes an object, or a string sent
as it is."
  (lambda (url &rest args)
    (push (cons url args) harness-provider-system-one-test--wire)
    (run-at-time 0.01 nil
                 (lambda ()
                   (funcall (plist-get args :callback) status nil
                            (if (stringp body) body (harness-json-encode body))
                            nil)))
    (lambda () (push :cancelled harness-provider-system-one-test--wire))))

(defmacro harness-provider-system-one-test--with-jev (&rest body)
  "Run BODY with a Jev provider registered against a stub transport.
The provider declares every capability a hosted System One model does,
which is what `harness-provider-system-one-register-jev' does by default."
  (declare (indent 0))
  `(harness-provider-system-one-test--with
     (harness-provider-system-one-register-jev
      'jev
      :model "jev-latest"
      :api-key "test-key"
      :base-url "https://api.example.test"
      :questions harness-provider-system-one-test--questions
      :transport (harness-provider-system-one-test--says 200
                                                          harness-provider-system-one-test--jev-answer))
     ,@body))
(ert-deftest harness-provider-system-one-jev-sends-the-published-request ()
  "A Jev decision is one POST /v1/systemone in the contract's own shape."
  (harness-provider-system-one-test--with-jev
    (harness-provider-system-one-test--resolved
     (harness-call 'provider/system-one
                   "jev:jev-latest"
                   (harness-provider-system-one-test--request :model "jev:jev-latest")))
    (let* ((wire (car harness-provider-system-one-test--wire))
           (url (car wire))
           (args (cdr wire))
           (body (plist-get args :json)))
      ;; The endpoint, the method and the key.
      (should (equal "https://api.example.test/v1/systemone" url))
      (should (equal "POST" (plist-get args :method)))
      (should (equal "Bearer test-key"
                     (cdr (assoc "Authorization" (plist-get args :headers)))))
      ;; The body is `model', `state' and `questions', with the question
      ;; types spelled as the API spells them.
      (should (equal "jev-latest" (harness-provider-system-one--field body "model")))
      (should (equal harness-provider-system-one-test--state
                     (harness-provider-system-one--field body "state")))
      (let ((questions (harness-provider-system-one--field body "questions")))
        (should (equal '("next-step" "same-thread" "topic-cue")
                       (sort (mapcar #'symbol-name (mapcar #'car
                                                           (harness-provider-system-one--pairs questions)))
                             (lambda (a b) (string< a b)))))
        (should (equal "noul" (harness-provider-system-one--field
                               (harness-provider-system-one--field questions "same-thread") "type")))
        (should (equal "choice" (harness-provider-system-one--field
                                 (harness-provider-system-one--field questions "next-step") "type")))
        ;; A score's levels are a JSON array, whatever their number.
        (should (vectorp (harness-provider-system-one--field
                          (harness-provider-system-one--field questions "topic-cue") "criteria"))))
      ;; No danger-zone header is sent for a request that needs none.
      (should-not (assoc "TypeSafe-Danger-Zone-Images" (plist-get args :headers)))
      (should-not (assoc "TypeSafe-Danger-Zone-Long-Context" (plist-get args :headers))))))

(ert-deftest harness-provider-system-one-jev-reads-the-published-answer ()
  "The answers, the model that answered and the usage come back as they were sent."
  (harness-provider-system-one-test--with-jev
    (let ((result (harness-provider-system-one-test--resolved
                   (harness-call 'provider/system-one
                                 "jev:jev-latest"
                                 (harness-provider-system-one-test--request :model "jev:jev-latest")))))
      ;; The model is the version that answered, not the alias asked for.
      (should (equal "jev-1.14.0" (plist-get result :model)))
      (should (equal "jev-latest" (plist-get result :requested-model)))
      ;; Every answer is reachable, of its own type.
      (should (= 0.96 (harness-provider-system-one-answer-value
                       (harness-provider-system-one-answer result "same-thread"))))
      (should (equal "continue" (harness-provider-system-one-answer-value
                                 (harness-provider-system-one-answer result "next-step"))))
      (should (= 0.91 (harness-provider-system-one-answer-confidence
                       (harness-provider-system-one-answer result "next-step"))))
      (should (= 1.7 (harness-provider-system-one-answer-value
                      (harness-provider-system-one-answer result "topic-cue"))))
      (should (= 0.75 (harness-provider-system-one-answer-probability
                       (harness-provider-system-one-answer result "topic-cue"))))
      ;; The usage the API reports is kept as it sent it.
      (should (= 349 (plist-get (plist-get result :usage) (intern "input_tokens"))))
      ;; And the provider's artifact travels with it.
      (should (equal "typesafe-system-one"
                     (plist-get (harness-provider-system-one--artifact-part
                                 (plist-get result :artifact) :artifact)
                                :id))))))

(ert-deftest harness-provider-system-one-jev-sends-the-danger-zone-headers-when-asked ()
  "Images and long context are the API's own switches, sent only when asked for."
  (harness-provider-system-one-test--with
    ;; A model whose artifact is the one question the stub answers.
    (harness-provider-system-one-register-jev
     'jev :model "jev-latest" :api-key "test-key" :base-url "https://api.example.test"
     :questions '(:same-thread (:type "noul" :instructions "Same?"))
     :transport (harness-provider-system-one-test--says 200
                                                         (list :model "jev-1.14.0"
                                                               :answers (list :same-thread
                                                                              (list :type "noul" :noul 0.96)))))
    (harness-provider-system-one-test--resolved
     (harness-call 'provider/system-one
                   "jev:jev-latest"
                   (harness-provider-system-one-test--request
                    :model "jev:jev-latest"
                    :long-context t
                    :questions '(:same-thread (:type "noul" :instructions "Same?")))))
    (let* ((args (cdr (car harness-provider-system-one-test--wire)))
           (headers (plist-get args :headers)))
      (should (equal "true" (cdr (assoc "TypeSafe-Danger-Zone-Long-Context" headers))))
      ;; A request with no image asks for no image header.
      (should-not (assoc "TypeSafe-Danger-Zone-Images" headers)))
    ;; An image request sends the images header, and its assets.
    (harness-provider-system-one-test--resolved
     (harness-call 'provider/system-one
                   "jev:jev-latest"
                   (harness-provider-system-one-test--request
                    :model "jev:jev-latest"
                    :assets '(:photo (:type "image" :data_base64 "AAA"))
                    :questions '(:same-thread (:type "noul" :instructions "Same?")))))
    (let* ((args (cdr (car harness-provider-system-one-test--wire)))
           (headers (plist-get args :headers))
           (body (plist-get args :json)))
      (should (equal "true" (cdr (assoc "TypeSafe-Danger-Zone-Images" headers))))
      (should (harness-provider-system-one--field body "assets")))))

(ert-deftest harness-provider-system-one-jev-refuses-a-bad-answer ()
  "A status other than 200, or a body with no answers, is no decision."
  (harness-provider-system-one-test--with
    (harness-provider-system-one-register-jev
     'jev :model "jev-latest" :api-key "test-key" :base-url "https://api.example.test"
     :transport (harness-provider-system-one-test--says
                 429 (list :detail "slow down")))
    (should (string-match-p "answered 429: slow down"
                            (harness-provider-system-one-test--rejected
                             (harness-call 'provider/system-one
                                           "jev:jev-latest"
                                           (harness-provider-system-one-test--request
                                            :model "jev:jev-latest")))))
    (harness-provider-system-one-register-jev
     'jev :model "jev-latest" :api-key "test-key" :base-url "https://api.example.test"
     :transport (harness-provider-system-one-test--says 200 (list :model "jev-1.14.0")))
    (should (string-match-p "no answers"
                            (harness-provider-system-one-test--rejected
                             (harness-call 'provider/system-one
                                           "jev:jev-latest"
                                           (harness-provider-system-one-test--request
                                            :model "jev:jev-latest")))))))

(ert-deftest harness-provider-system-one-jev-needs-a-key ()
  "A provider with no key says so instead of sending an unauthenticated call."
  (harness-provider-system-one-test--with
    (let ((harness-provider-system-one-jev-api-key-env "HARNESS_TEST_NO_SUCH_KEY"))
      (harness-provider-system-one-register-jev
       'jev :model "jev-latest" :base-url "https://api.example.test"
       :transport (harness-provider-system-one-test--says 200
                                                           harness-provider-system-one-test--jev-answer))
      (should (string-match-p "No System One API key"
                              (harness-provider-system-one-test--rejected
                               (harness-call 'provider/system-one
                                             "jev:jev-latest"
                                             (harness-provider-system-one-test--request
                                              :model "jev:jev-latest")))))
      ;; And nothing was sent.
      (should-not harness-provider-system-one-test--wire))))

(ert-deftest harness-provider-system-one-jev-cancels-its-request ()
  "Cancelling a decision cancels the HTTP request under it."
  (harness-provider-system-one-test--with
    (let ((cancelled nil))
      (harness-provider-system-one-register-jev
       'jev :model "jev-latest" :api-key "test-key" :base-url "https://api.example.test"
       :transport (lambda (_url &rest _args)
                    (lambda () (setq cancelled t))))
      (let ((handle (harness-call 'provider/system-one
                                  "jev:jev-latest"
                                  (harness-provider-system-one-test--request
                                   :model "jev:jev-latest"))))
        (should (harness-provider-system-one-cancel handle))
        (should cancelled)))))

(ert-deftest harness-provider-system-one-jev-artifact-records-its-calibration ()
  "The hosted model's artifact says how its calibration was fitted, and where."
  (harness-provider-system-one-test--with-jev
    (let* ((artifact (plist-get (harness-call 'provider/model "jev:jev-latest") :artifact))
           (calibration (plist-get (plist-get artifact :evaluation) :calibration)))
      (should-not (harness-provider-system-one-artifact-problems artifact))
      (should (equal "rlcd" (plist-get calibration :method)))
      (should (string-match-p "docs.typesafe.ai" (plist-get calibration :source)))
      ;; A model that says it is calibrated is believed only with that.
      (should (harness-provider-system-one-can-p "jev:jev-latest" :calibrated)))))

;;;; Reading answers

(ert-deftest harness-provider-system-one-answer-readers ()
  "An answer is read as its value, its probability and its confidence."
  (harness-provider-system-one-test--with
    ;; A noul's value and probability are the same number.
    (let ((noul '(:type "noul" :noul 0.8)))
      (should (= 0.8 (harness-provider-system-one-answer-value noul)))
      (should (= 0.8 (harness-provider-system-one-answer-probability noul)))
      (should-not (harness-provider-system-one-answer-confidence noul)))
    ;; A choice's value is the option, its probability the one it gave it.
    (let ((choice '(:type "choice" :choice :continue :confidence 0.7
                    :probabilities (:continue 0.7 :new 0.3))))
      (should (equal "continue" (harness-provider-system-one-answer-value choice)))
      (should (= 0.7 (harness-provider-system-one-answer-probability choice)))
      (should (= 0.7 (harness-provider-system-one-answer-confidence choice))))
    ;; A score's value is its position, its probability the nearest level's.
    (let ((score '(:type "score" :score 1.8 :confidence 0.6
                   :legend (:0 "a" :1 "b" :2 "c")
                   :probabilities (:0 0.05 :1 0.15 :2 0.8))))
      (should (= 1.8 (harness-provider-system-one-answer-value score)))
      (should (= 0.8 (harness-provider-system-one-answer-probability score)))
      (should (= 0.6 (harness-provider-system-one-answer-confidence score))))
    ;; A box's value is its edges, and it has no probability of its own.
    (let ((box '(:type "box" :box (:top 0.1 :bottom 0.9 :left 0.2 :right 0.8) :confidence 0.9)))
      (should (equal '(:top 0.1 :bottom 0.9 :left 0.2 :right 0.8)
                     (harness-provider-system-one-answer-value box)))
      (should-not (harness-provider-system-one-answer-probability box)))
    ;; An answer a result does not carry is nil, not an error.
    (should-not (harness-provider-system-one-answer '(:answers (:a (:type "noul" :noul 1))) "b"))
    (should (= 1 (harness-provider-system-one-answer-value
                  (harness-provider-system-one-answer '(:answers (:a (:type "noul" :noul 1))) :a))))))

;;;; Lifecycle

(ert-deftest harness-provider-system-one-unregister-cleans-up ()
  "Unregistering a provider takes its System One capability with it."
  (harness-provider-system-one-test--with
    (harness-provider-system-one-register-fixture 'fixture harness-provider-system-one-test--fixture)
    (should (harness-call 'provider/system-one-p "fixture:fixture"))
    (should (harness-provider-unregister 'fixture))
    (should-not (harness-call 'provider/system-one-p "fixture:fixture"))
    ;; A request naming it is refused, and nothing is sent.
    (should (string-match-p "not a System One model"
                            (string-join
                             (harness-provider-system-one-validate
                              (harness-provider-system-one-test--request))
                             " ")))
    (should (string-match-p "No provider for model"
                            (harness-provider-system-one-test--rejected
                             (harness-call 'provider/system-one
                                           "fixture:fixture"
                                           (harness-provider-system-one-test--request)))))))

(provide 'harness-provider-system-one-test)
;;; harness-provider-system-one-test.el ends here
