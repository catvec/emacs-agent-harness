;;; harness-provider-system-one.el --- System One decisions through the provider interface  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness.

;;; Commentary:

;; A completion model answers with text: it is given a conversation and
;; writes the next thing to say.  A *System One* model answers with
;; decisions: it is given a `state' -- the content to judge, once -- and
;; named, typed questions about it, and it answers each one with a typed
;; value instead of prose.  A noul is the probability that a yes/no
;; statement is true, a choice is one option out of a closed set with the
;; probabilities of all of them, a score is a position along ordered
;; levels with the probability of each level, and a box is where
;; something is in an image.
;;
;; The two are not the same capability and neither is a kind of the
;; other.  A completion model cannot answer a noul at all -- it writes a
;; sentence where a probability belongs -- and the harness's own small
;; calls (the permission judge, naming a session, a recap) are
;; completions by design, asked through `provider/complete' like every
;; other request.  They do not want a second interface; they already
;; have one.
;;
;; So this is a capability of the existing provider interface, as
;; embedding text is.  `harness-define-provider' takes `:system-one',
;; `provider/system-one-p' says whether a model has it, and
;; `provider/system-one' asks for decisions.  A provider is registered
;; once and may declare any of them: the day a model both completes and
;; answers System One questions, it declares both, and nothing here
;; forbids it.
;;
;; This module owns the contract of that capability: the question types,
;; the capability gate, the request and answer validators, the artifact
;; that records what a model was trained and evaluated on, the deadline
;; and cancellation, and two providers that declare it -- the System One
;; API (TypeSafe's Jev, whose published OpenAPI document is the
;; authority for the shape) and a deterministic fixture.
;;
;; What this module does not own: the safety model and its data, the
;; workspace's thread router, the audio pipeline.  They register a
;; provider or consume this one; they keep their own datasets, question
;; sets, thresholds and fallbacks.  Nothing here trains a model, uploads
;; anything, or decides anything on a caller's behalf.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)
(require 'harness-provider)

(defgroup harness-provider-system-one nil
  "System One decision models, as a capability of the provider interface."
  :prefix "harness-provider-system-one-"
  :group 'harness)

(define-error 'harness-provider-system-one-error "System One provider error")

(defconst harness-provider-system-one-schema-version 1
  "The version of the request and result schemas this module speaks.
A provider declares the versions it serves; a request or result in
another version is refused rather than read as if the shapes agreed.")

(defconst harness-provider-system-one-question-types
  '((:noul . "Is this true?  The answer is the probability that it is, from 0 to 1.")
    (:choice . "Which of these options?  The answer is one option, a probability for every option, and a confidence.")
    (:score . "Which level of this ordered scale?  The answer is a position on the scale, the legend that names the levels, a probability for each and a confidence.")
    (:box . "Where is this in the image?  The answer is the box's four edges, each a fraction of the image, and a confidence."))
  "The question types a System One model answers, and what each answer is.
These are the types the contract knows; a model declares the ones it
serves in its `:capabilities', and a request for any other is refused
before it is sent.")

(defconst harness-provider-system-one-capability-keys
  '((:noul . "It answers noul questions: the probability that a statement is true.")
    (:choice . "It answers choice questions: one option out of a closed set.")
    (:score . "It answers score questions: a position on an ordered scale.")
    (:box . "It answers box questions: where something is in an image.")
    (:images . "It reads images, as request assets or as the criteria of a box question.")
    (:long-context . "It accepts a larger context than its default limit.")
    (:confidence . "Its choice, score and box answers carry a confidence.")
    (:calibrated . "Its confidences were fitted against held-out data, and its artifact says how.")
    (:abstain . "It may decline to answer at all, saying why.")
    (:stream . "It reports partial answers before it finishes.")
    (:audio . "It accepts audio features in the state.")
    (:embeddings . "It accepts embedding vectors in the state.")
    (:carried-state . "It accepts state that carries over from the decision before.")
    (:schema . "It accepts a response schema for its own transport."))
  "The capabilities a System One model may declare, and what each promises.
These live in the same `:capabilities' plist as `:vision' or `:thinking',
so one model declares all of what it can do in one place.  An optional
capability is never required: a request that asks for one its model does
not declare is refused, so no model has to read images, stream, take
audio, carry state or accept a schema to be usable.")

;;;; Names and keys

(defun harness-provider-system-one--key-name (key)
  "Return KEY, a plist key or a string, as a string name.
`:calm' and \"calm\" both name the option \"calm\", and `:0' names the
level \"0\", so a question written in Lisp and an answer read from JSON
compare alike."
  (cond ((stringp key) key)
        ((keywordp key) (substring (symbol-name key) 1))
        ((symbolp key) (symbol-name key))
        ((numberp key) (number-to-string key))))

(defun harness-provider-system-one--type-name (value)
  "Return VALUE, a question or answer type, as its name, or nil.
`:noul', \"noul\" and \"NOUL\" all name the noul type."
  (when-let* ((name (harness-provider-system-one--key-name value)))
    (let ((name (downcase (string-trim name))))
      (and (member name (mapcar (lambda (pair)
                                  (harness-provider-system-one--key-name (car pair)))
                                harness-provider-system-one-question-types))
           name))))

(defun harness-provider-system-one--name (value)
  "Return VALUE as a trimmed, non-empty string, or nil."
  (when (stringp value)
    (let ((trimmed (string-trim value)))
      (and (not (string-empty-p trimmed)) trimmed))))

(defun harness-provider-system-one--field (object name)
  "Return OBJECT's value for NAME, whatever form its key takes.
NAME is a string; the object may hold it as `:model', `model' or
\"model\", as a plist written in Lisp or one read from JSON does."
  (let ((wanted (downcase (string-remove-prefix ":" (string-trim name)))))
    (cdr (cl-find-if (lambda (cell)
                       (equal (downcase (harness-provider-system-one--key-name (car cell))) wanted))
                     (harness-provider-system-one--pairs object)))))

(defun harness-provider-system-one--object-p (value)
  "Non-nil when VALUE is a plist, the harness's JSON object.
JSON is read with the plist object type, so an object's keys are
keywords and an array is a list of values: the keyword key is what tells
them apart."
  (and (listp value) (keywordp (car-safe value))))

(defun harness-provider-system-one--pairs (value)
  "Return VALUE, a plist or an alist, as an alist of (KEY . VALUE).
A plist keeps its keys as they are and an alist keeps its own.  A JSON
object read from the wire has keyword keys; one this module builds for a
transport may have plain symbols, which a key that is not a cons tells
apart from an alist's cells."
  (cond
   ((null value) nil)
   ((harness-provider-system-one--object-p value)
    (cl-loop for (key val) on value by #'cddr collect (cons key val)))
   ((and (listp value) (symbolp (car-safe value)))
    ;; A plist whose keys are plain symbols, as a body written for a
    ;; transport has them.
    (cl-loop for (key val) on value by #'cddr collect (cons key val)))
   ((listp value)
    (cl-remove-if-not #'consp value))))

(defun harness-provider-system-one--number-p (value)
  "Non-nil when VALUE is a number between 0 and 1."
  (and (numberp value) (>= value 0) (<= value 1)))

;;;; The model's capabilities

(defun harness-provider-system-one--symbol (value)
  "Return VALUE, a symbol or its name, as a symbol, or nil."
  (cond ((and (stringp value) (not (string-empty-p value))) (intern value))
        ((and value (symbolp value) (not (memq value '(t :false :null)))) value)))

(defun harness-provider-system-one-model (model-id)
  "Return the model plist of MODEL-ID, or nil when it is not a System One model.
A model declares the capability through its provider's `:system-one' hook
(see `harness-define-provider'), and the questions it answers in the
`:capabilities' of its catalogue entry, beside `:vision' and `:thinking'."
  (when (harness-call 'provider/system-one-p model-id)
    (harness-call 'provider/model model-id)))

(defun harness-provider-system-one-capabilities (model-id)
  "Return the System One capabilities MODEL-ID declares, as a plist.
Only the keys this contract knows are kept, so a typo in a declaration
cannot silently unlock a feature nothing reads."
  (let* ((declared (plist-get (harness-call 'provider/model model-id) :capabilities))
         (out nil))
    (dolist (key harness-provider-system-one-capability-keys out)
      (setq out (plist-put out (car key)
                           (and (harness-json-true-p (plist-get declared (car key))) t))))))

(defun harness-provider-system-one-can-p (model-id capability)
  "Non-nil when MODEL-ID declares CAPABILITY, a keyword of its capabilities."
  (and model-id
       (harness-json-true-p
        (plist-get (plist-get (harness-call 'provider/model model-id) :capabilities) capability))))

;;;; Questions

(defun harness-provider-system-one--questions (value)
  "Return VALUE, a question set, as an alist of (NAME . QUESTION).
NAME is a string.  VALUE is a plist of keyword names or an alist of
string names, as `harness-json-parse' reads a JSON object."
  (mapcar (lambda (cell)
            (cons (harness-provider-system-one--key-name (car cell)) (cdr cell)))
          (harness-provider-system-one--pairs value)))

(defun harness-provider-system-one-question-type (question)
  "Return QUESTION's type as its name, or nil."
  (and (listp question)
       (harness-provider-system-one--type-name (plist-get question :type))))

(defun harness-provider-system-one-question-problems (question)
  "Return what is wrong with QUESTION, a System One question, as strings.
Nil when it may be asked: a type this contract knows, instructions that
are text or structured data, and the criteria its type requires -- a
choice's options, a score's ordered levels."
  (let* ((problems nil)
         (add (lambda (fmt &rest args) (push (apply #'format fmt args) problems)))
         (type (harness-provider-system-one-question-type question))
         (criteria (plist-get question :criteria))
         (instructions (plist-get question :instructions)))
    (cond
     ((not (listp question))
      (funcall add "A question is a plist"))
     ((null type)
      (funcall add "A question names its type in :type, one of %s"
               (string-join (mapcar (lambda (pair)
                                      (harness-provider-system-one--key-name (car pair)))
                                    harness-provider-system-one-question-types)
                            ", ")))
     (t
      (when (and instructions (not (or (stringp instructions)
                                       (harness-provider-system-one--object-p instructions)
                                       (and (listp instructions) (not (consp (car instructions)))))))
        (funcall add "The %s question's :instructions are text or structured data" type))
      (pcase type
        ("choice"
         (let ((names (harness-provider-system-one--choice-names criteria)))
           (cond ((null names)
                  (funcall add "A choice question names the options it chooses between in :criteria"))
                 ((cl-some #'null names)
                  (funcall add "Every option of a choice question has a name"))
                 ((> (length names) 255)
                  (funcall add "A choice question offers at most 255 options")))))
        ("score"
         (let ((levels (and (listp criteria) (not (harness-provider-system-one--object-p criteria))
                            criteria)))
           (cond ((null levels)
                  (funcall add "A score question names its ordered levels in :criteria"))
                 ((> (length levels) 10)
                  (funcall add "A score question has at most 10 levels"))
                 ((cl-some (lambda (level)
                             (not (or (stringp level)
                                      (harness-provider-system-one--object-p level)
                                      (and (listp level) (not (consp (car level)))))))
                           levels)
                  (funcall add "Every level of a score question is text or structured data")))))
        ("noul"
         (when (and criteria (not (or (harness-provider-system-one--object-p criteria)
                                      (stringp criteria))))
           (funcall add "A noul question's :criteria, when it gives them, say what yes and no mean")))
        ("box"
         (when criteria
           (funcall add "A box question takes no :criteria; its instructions say what to find"))))))
    (nreverse problems)))

(defun harness-provider-system-one--choice-names (criteria)
  "Return the option names of a choice question's CRITERIA, as strings.
A choice's criteria are a JSON object of option name to what it means."
  (when (harness-provider-system-one--object-p criteria)
    (mapcar (lambda (cell) (harness-provider-system-one--key-name (car cell)))
            (harness-provider-system-one--pairs criteria))))

(defun harness-provider-system-one--score-levels (criteria)
  "Return the level names of a score question's CRITERIA, as strings.
A score's criteria are an ordered JSON array; a level is named by its
position, starting at zero, which is what the answer's legend keys."
  (when (and (listp criteria) (not (harness-provider-system-one--object-p criteria)))
    (cl-loop for _ in criteria for index from 0 collect (number-to-string index))))

;;;; The request

(defcustom harness-provider-system-one-timeout 10
  "Seconds a System One decision may take before it gives no answer.
A request's `:deadline' overrides it.  A System One model answers in well
under a second, so this is generous; a decision that takes longer is
cancelled and its promise rejects, and a provider that answers after that
is not read."
  :type 'number :group 'harness-provider-system-one)

(defun harness-provider-system-one--deadline (request)
  "Return the seconds REQUEST may take before it gives no decision."
  (let ((asked (plist-get request :deadline)))
    (if (and (numberp asked) (> asked 0)) (float asked) (float harness-provider-system-one-timeout))))

(defun harness-provider-system-one--state-problems (state)
  "Return what is wrong with STATE, the content questions are judged against."
  (cond
   ((null state) (list "A request gives the content to judge in :state"))
   ((stringp state)
    (if (string-empty-p (string-trim state))
        (list "The :state is an empty string")
      nil))
   ((harness-provider-system-one--object-p state) nil)
   ((listp state) nil)
   (t (list "The :state is text, a JSON object or a JSON array"))))

(defun harness-provider-system-one-request-problems (model-id request)
  "Return what is wrong with REQUEST for MODEL-ID, as a list of strings.
Nil when the request may be sent.  The checks are the contract: a schema
version this module does not speak, content to judge, at least one named
question whose type the model answers, the capabilities a request asks
for, and nothing it asks of a model that does not declare it."
  (let* ((problems nil)
         (add (lambda (fmt &rest args) (push (apply #'format fmt args) problems))))
    (unless (listp request)
      (funcall add "A request is a plist"))
    (let ((version (or (plist-get request :schema-version) harness-provider-system-one-schema-version)))
      (unless (equal version harness-provider-system-one-schema-version)
        (funcall add "Schema version %s is not one this harness speaks (%s)"
                 version harness-provider-system-one-schema-version)))
    (dolist (problem (harness-provider-system-one--state-problems (plist-get request :state)))
      (funcall add "%s" problem))
    (let* ((questions (harness-provider-system-one--questions (plist-get request :questions)))
           (seen nil))
      (cond
       ((null questions)
        (funcall add "A request asks at least one question in :questions"))
       (t
        (dolist (cell questions)
          (let ((name (car cell))
                (question (cdr cell)))
            (cond
             ((member name seen)
              (funcall add "Two questions are named %s; a name is how its answer is found" name))
             ((string-empty-p name)
              (funcall add "Every question has a name in :questions"))
             (t
              (push name seen)
              (dolist (problem (harness-provider-system-one-question-problems question))
                (funcall add "Question %s: %s" name problem))
              ;; A question type is a capability: a model that cannot
              ;; answer a score is not asked to guess one.
              (let ((type (harness-provider-system-one-question-type question)))
                (when (and type (not (harness-provider-system-one-can-p
                                      model-id (intern (concat ":" type)))))
                  (funcall add "The model does not answer %s questions, which question %s asks"
                           type name)))
              (when (and (equal "box" (harness-provider-system-one-question-type question))
                         (not (harness-provider-system-one-can-p model-id :images)))
                (funcall add "Question %s is a box question, and the model does not read images"
                         name)))))))))
    ;; What a request asks for is gated on the capability that promises
    ;; it, which is not always the key the request spells: partial results
    ;; are `:stream' and a response schema is `:schema'.
    (dolist (gate '((:assets :images "images")
                    (:long-context :long-context "long context")
                    (:audio :audio "audio")
                    (:embeddings :embeddings "embeddings")
                    (:carried-state :carried-state "carried-over state")
                    (:response-schema :schema "a response schema")
                    (:on-partial :stream "streaming")))
      (when (and (harness-json-true-p (plist-get request (car gate)))
                 (not (harness-provider-system-one-can-p model-id (cadr gate))))
        (funcall add "The model does not declare %s, which the request asks for"
                 (caddr gate))))
    (when (and (plist-get request :on-partial)
               (not (functionp (plist-get request :on-partial))))
      (funcall add ":on-partial is a function of one partial result"))
    (when (and (plist-member request :deadline)
               (not (and (numberp (plist-get request :deadline))
                         (> (plist-get request :deadline) 0))))
      (funcall add ":deadline is a positive number of seconds"))
    (when (plist-member request :assets)
      (dolist (cell (harness-provider-system-one--pairs (plist-get request :assets)))
        (let ((asset (cdr cell)))
          (unless (equal "image"
                         (harness-provider-system-one--key-name (plist-get asset :type)))
            (funcall add "The asset %s is not an image" (car cell)))
          (unless (or (harness-provider-system-one--name (plist-get asset :data_base64))
                      (harness-provider-system-one--name (plist-get asset :part)))
            (funcall add "The asset %s carries its bytes or names its part"
                     (car cell))))))
    (nreverse problems)))

(defun harness-provider-system-one-validate (request)
  "Return what is wrong with REQUEST, as a list of strings; nil when it is sound.
The model is REQUEST's `:model', a PROVIDER:NAME id; a request naming
none, or one whose provider does not answer System One decisions, says
so."
  (let ((model-id (plist-get request :model)))
    (cond
     ((not (harness-provider-system-one--name model-id))
      (list "A request names its model in :model, as PROVIDER:NAME"))
     ((not (harness-call 'provider/system-one-p model-id))
      (list (format "%s is not a System One model: its provider does not answer System One decisions"
                    model-id)))
     (t (harness-provider-system-one-request-problems model-id request)))))

(harness-defmethod provider/system-one-validate (model-id request)
  "Return what is wrong with REQUEST for MODEL-ID, as a list of strings.
The funnel `provider/system-one' asks this before it calls a provider, so
no provider has to check the contract again; a request that names no
model is checked against REQUEST's own `:model'."
  (harness-provider-system-one-request-problems
   (or model-id (plist-get request :model)) request))

;;;; The result

(defun harness-provider-system-one--distribution-problems (value allowed what)
  "Return what is wrong with VALUE, a probability distribution, given ALLOWED.
WHAT names the thing the distribution is over, for the message.  Every
name in ALLOWED is present, nothing else is, and every probability is a
number between 0 and 1."
  (let ((problems nil))
    (cond
     ((null value)
      (push (format "An answer gives the probability of each %s in :probabilities" what) problems))
     ((not (harness-provider-system-one--object-p value))
      (push (format ":probabilities is an object of %s to probability" what) problems))
     (t
      (let* ((pairs (harness-provider-system-one--pairs value))
             (names (mapcar (lambda (cell) (harness-provider-system-one--key-name (car cell)))
                            pairs))
             (missing (cl-set-difference allowed names :test #'equal))
             (extra (cl-set-difference names allowed :test #'equal)))
        (when missing
          (push (format ":probabilities says nothing of %s, which the question offered"
                        (string-join missing ", "))
                problems))
        (when extra
          (push (format ":probabilities names %s, which the question did not offer"
                        (string-join extra ", "))
                problems))
        (dolist (cell pairs)
          (unless (harness-provider-system-one--number-p (cdr cell))
            (push (format "The probability of %s is a number between 0 and 1"
                          (harness-provider-system-one--key-name (car cell)))
                  problems))))))
    (nreverse problems)))

(defun harness-provider-system-one--box-problems (box)
  "Return what is wrong with BOX, a box answer's four edges."
  (if (not (harness-provider-system-one--object-p box))
      (list "A box answer gives the box's :top :bottom :left :right in :box")
    (let ((problems nil)
          (edges (list (cons :top "top") (cons :bottom "bottom")
                       (cons :left "left") (cons :right "right"))))
      (dolist (edge edges)
        (unless (harness-provider-system-one--number-p (plist-get box (car edge)))
          (push (format "The box's %s is a fraction between 0 and 1" (cdr edge)) problems)))
      (let ((top (plist-get box :top)) (bottom (plist-get box :bottom))
            (left (plist-get box :left)) (right (plist-get box :right)))
        (when (and (numberp top) (numberp bottom) (> top bottom))
          (push "The box's :top is above its :bottom" problems))
        (when (and (numberp left) (numberp right) (> left right))
          (push "The box's :left is left of its :right" problems)))
      (nreverse problems))))

(defun harness-provider-system-one-answer-problems (question answer)
  "Return what is wrong with ANSWER, the answer to QUESTION, as strings.
Nil when the answer is the type the question asked for and says something
that type can say: a noul probability, a choice among the options the
question offered, a score on its levels, a box inside the image.  A
probability or a legend that names something the question did not offer
is refused."
  (let* ((problems nil)
         (add (lambda (fmt &rest args) (push (apply #'format fmt args) problems)))
         (type (harness-provider-system-one-question-type question))
         (criteria (plist-get question :criteria)))
    (cond
     ((not (listp answer))
      (funcall add "An answer is a plist"))
     ((not (equal type (harness-provider-system-one--type-name (plist-get answer :type))))
      (funcall add "The answer is a %s answer; the question asks a %s question"
               (or (harness-provider-system-one--type-name (plist-get answer :type)) "nameless")
               (or type "nameless")))
     (t
      (pcase type
        ("noul"
         (unless (harness-provider-system-one--number-p (plist-get answer :noul))
           (funcall add "A noul answer gives the probability that the statement is true in :noul, from 0 to 1")))
        ("choice"
         (let* ((names (harness-provider-system-one--choice-names criteria))
                (choice (plist-get answer :choice))
                (choice (and choice (harness-provider-system-one--key-name choice))))
           (cond ((null (harness-provider-system-one--name choice))
                  (funcall add "A choice answer names the option it chose in :choice"))
                 ((not (member choice names))
                  (funcall add "The answer chose %S, which is not one of the question's options (%s)"
                           choice (string-join names ", "))))
           (dolist (problem (harness-provider-system-one--distribution-problems
                             (plist-get answer :probabilities) names "option"))
             (funcall add "%s" problem))))
        ("score"
         (let* ((levels (harness-provider-system-one--score-levels criteria))
                (score (plist-get answer :score))
                (highest (1- (length levels))))
           (cond ((not (numberp score))
                  (funcall add "A score answer gives its position on the levels in :score"))
                 ;; A score is the probability-weighted average of the
                 ;; levels, so it falls between two of them: the bounds are
                 ;; the levels' own, from the lowest to the highest.
                 ((or (< score 0) (> score highest))
                  (funcall add "The score %s is outside the question's levels, 0 to %s"
                           score highest)))
           (let ((legend (plist-get answer :legend)))
             (unless (equal (sort (mapcar (lambda (cell)
                                            (harness-provider-system-one--key-name (car cell)))
                                          (harness-provider-system-one--pairs legend))
                                  #'string<)
                            (sort (copy-sequence levels) #'string<))
               (funcall add "A score answer's :legend names its levels, one for each of %s"
                        (string-join levels ", "))))
           (dolist (problem (harness-provider-system-one--distribution-problems
                             (plist-get answer :probabilities) levels "level"))
             (funcall add "%s" problem))))
        ("box"
         (dolist (problem (harness-provider-system-one--box-problems (plist-get answer :box)))
           (funcall add "%s" problem))))
      (when (and (plist-member answer :confidence)
                 (not (harness-provider-system-one--number-p (plist-get answer :confidence))))
        (funcall add "A confidence is a number between 0 and 1"))))
    (nreverse problems)))

(defun harness-provider-system-one--artifact-part (artifact key)
  "Return ARTIFACT's KEY as a plist, or nil."
  (let ((value (plist-get artifact key)))
    (and (listp value) (keywordp (car-safe value)) value)))

(defun harness-provider-system-one--calibration-method (artifact)
  "Return how ARTIFACT says the model's confidences were fitted, or nil.
A method of \"none\" is no calibration at all, which is what an artifact
that was never fitted says."
  (let* ((evaluation (harness-provider-system-one--artifact-part artifact :evaluation))
         (method (plist-get (plist-get evaluation :calibration) :method))
         (method (and (stringp method) (downcase (string-trim method)))))
    (and method (not (string-empty-p method)) (not (member method '("none" "uncalibrated")))
         method)))

(defun harness-provider-system-one-result-problems (model-id request result)
  "Return what is wrong with RESULT, the answers to REQUEST from MODEL-ID.
Nil when the result is a set of answers this module can hand to a caller:
one answer per question, keyed by the question's name, of the type that
question asked for, with no answer to a question nobody asked.  A
confidence the model does not declare, or a calibration neither it nor
its artifact claims, is refused, so nothing reads as more than the model
said."
  (let* ((problems nil)
         (add (lambda (fmt &rest args) (push (apply #'format fmt args) problems)))
         (questions (harness-provider-system-one--questions (plist-get request :questions))))
    (unless (listp result)
      (funcall add "A result is a plist"))
    (let ((version (plist-get result :schema-version)))
      (unless (equal version (or (plist-get request :schema-version)
                                 harness-provider-system-one-schema-version))
        (funcall add "The result is in schema version %s, not the request's %s"
                 version (or (plist-get request :schema-version)
                             harness-provider-system-one-schema-version))))
    (let ((provider-id (plist-get result :provider)))
      (unless (equal provider-id (car (harness-provider-parse-model model-id)))
        (funcall add "The result says provider %s, not %s"
                 provider-id (car (harness-provider-parse-model model-id)))))
    (let ((answers (harness-provider-system-one--pairs (plist-get result :answers)))
          (abstained (harness-json-true-p (plist-get result :abstained)))
          (reason (plist-get result :reason)))
      (cond
       ((and abstained answers)
        (funcall add "A result answers and abstains; it is one or the other"))
       ((and (null answers) (not abstained))
        (funcall add "A result answers the questions or abstains with a reason, not neither"))
       ((and abstained (not (harness-provider-system-one-can-p model-id :abstain)))
        (funcall add "The model does not declare that it may abstain"))
       (abstained
        (unless (harness-provider-system-one--name reason)
          (funcall add "An abstention says why in :reason")))
       (t
        (let* ((asked (mapcar #'car questions))
               (answered (mapcar (lambda (cell) (harness-provider-system-one--key-name (car cell)))
                                 answers))
               (missing (cl-set-difference asked answered :test #'equal))
               (extra (cl-set-difference answered asked :test #'equal)))
          (when missing
            (funcall add "Nothing answers the question%s %s"
                     (if (cdr missing) "s" "") (string-join missing ", ")))
          (when extra
            (funcall add "An answer names %s, which is not a question the request asked"
                     (string-join extra ", ")))
          (dolist (cell answers)
            (let* ((name (harness-provider-system-one--key-name (car cell)))
                   (question (cdr (assoc name questions))))
              (when question
                (dolist (problem (harness-provider-system-one-answer-problems
                                  question (cdr cell)))
                  (funcall add "Answer %s: %s" name problem))
                (let ((confidence (plist-get (cdr cell) :confidence)))
                  (when (and (plist-member (cdr cell) :confidence)
                             confidence
                             (not (harness-provider-system-one-can-p model-id :confidence)))
                    (funcall add "Answer %s gives a confidence, which the model does not declare" name))))))))))
    (when (harness-json-true-p (plist-get result :calibrated))
      (unless (harness-provider-system-one-can-p model-id :calibrated)
        (funcall add "The model does not declare its confidences calibrated, which the result claims"))
      ;; A calibration is a fact about a model that was fitted against
      ;; held-out data, so the claim needs the artifact that says how: a
      ;; model cannot make a number a probability by declaring it one.
      (unless (harness-provider-system-one--calibration-method (plist-get result :artifact))
        (funcall add "A result that claims a calibration names an artifact whose evaluation says how it was fitted")))
    (when-let* ((artifact (plist-get result :artifact)))
      (dolist (problem (harness-provider-system-one-artifact-problems artifact))
        (funcall add "The result's artifact: %s" problem)))
    (nreverse problems)))

;;;; The artifact

(defun harness-provider-system-one-artifact-problems (artifact)
  "Return what is wrong with ARTIFACT, the metadata a System One model ships.
Nil when it says what a consumer and a trainer must agree on: the schema
version, the artifact and model versions, the questions the model
answers, the dataset and its splits, the evaluation and its calibration,
and what the model needs at run time."
  (let* ((problems nil)
         (add (lambda (fmt &rest args) (push (apply #'format fmt args) problems))))
    (if (not (and (listp artifact) (keywordp (car-safe artifact))))
        (funcall add "The artifact is a plist")
      (unless (equal (plist-get artifact :schema-version) harness-provider-system-one-schema-version)
        (funcall add "Schema version %s is not %s"
                 (plist-get artifact :schema-version) harness-provider-system-one-schema-version))
      (dolist (pair '((:artifact . "artifact") (:model . "model")
                      (:questions . "questions") (:dataset . "dataset")
                      (:evaluation . "evaluation") (:runtime . "runtime")))
        (let ((part (harness-provider-system-one--artifact-part artifact (car pair))))
          (if (not part)
              (funcall add "The artifact names its %s as a plist" (cdr pair))
            (pcase (car pair)
              (:artifact
               (unless (harness-provider-system-one--name (plist-get part :id))
                 (funcall add "The artifact needs an :id"))
               (unless (harness-provider-system-one--name (plist-get part :version))
                 (funcall add "The artifact needs a :version")))
              (:model
               (unless (harness-provider-system-one--name (plist-get part :id))
                 (funcall add "The model needs an :id"))
               (unless (harness-provider-system-one--name (plist-get part :version))
                 (funcall add "The model needs a :version")))
              (:questions
               (let ((questions (harness-provider-system-one--questions part)))
                 (cond ((null questions)
                        (funcall add "The artifact names the questions the model answers"))
                       (t
                        (dolist (cell questions)
                          (dolist (problem (harness-provider-system-one-question-problems
                                            (cdr cell)))
                            (funcall add "The artifact's question %s: %s" (car cell) problem)))))))
              (:dataset
               (unless (harness-provider-system-one--name (plist-get part :name))
                 (funcall add "The dataset needs a :name"))
               (unless (harness-provider-system-one--name (plist-get part :version))
                 (funcall add "The dataset needs a :version"))
               (unless (harness-provider-system-one--name (plist-get part :provenance))
                 (funcall add "The dataset says where it came from in :provenance"))
               (let ((splits (plist-get part :splits)))
                 (if (not (listp splits))
                     (funcall add "The dataset lists its :splits")
                   (dolist (split splits)
                     (unless (and (harness-provider-system-one--name (plist-get split :name))
                                  (numberp (plist-get split :count)))
                       (funcall add "Every split has a :name and a :count"))))))
              (:evaluation
               (unless (harness-provider-system-one--name (plist-get part :split))
                 (funcall add "The evaluation names the split it was measured on"))
               (let ((splits (plist-get (harness-provider-system-one--artifact-part artifact :dataset)
                                        :splits)))
                 (when (and (harness-provider-system-one--name (plist-get part :split))
                            splits
                            (not (member (plist-get part :split)
                                         (mapcar (lambda (s) (plist-get s :name)) splits))))
                   (funcall add "The evaluation's split %s is not one the dataset has"
                            (plist-get part :split))))
               (unless (listp (plist-get part :metrics))
                 (funcall add "The evaluation lists its :metrics"))
               (let ((calibration (plist-get part :calibration)))
                 (unless (and (harness-provider-system-one--object-p calibration)
                              (harness-provider-system-one--name (plist-get calibration :method)))
                   (funcall add "The evaluation says how the confidences were fitted in :calibration, or that they were not")))
               (let ((calibration (plist-get part :calibration)))
                 (when (and (harness-provider-system-one--name (plist-get calibration :method))
                            (not (member (downcase (string-trim (plist-get calibration :method)))
                                         '("none" "uncalibrated")))
                            (not (harness-provider-system-one--name (plist-get calibration :source))))
                   (funcall add "A calibration that was fitted says where that is documented in :source"))))
              (:runtime
               (let ((kind (plist-get part :kind)))
                 (unless (member kind '("local" "remote"))
                   (funcall add "The runtime is :kind local or remote")))))))))
    (nreverse problems)))

(defun harness-provider-system-one--same-options-p (asked question)
  "Return what differs between ASKED and QUESTION's options, or nil.
Both are choice questions: the same options, whatever their order, or a
sentence saying how they differ."
  (let ((asked-options (harness-provider-system-one--choice-names (plist-get asked :criteria)))
        (want-options (harness-provider-system-one--choice-names
                       (plist-get question :criteria))))
    (when (and (or asked-options want-options)
               (not (equal (sort (copy-sequence asked-options) #'string<)
                           (sort (copy-sequence want-options) #'string<))))
      (format "among %s rather than %s"
              (string-join (or asked-options (list "none")) ", ")
              (string-join (or want-options (list "none")) ", ")))))

(defun harness-provider-system-one--same-levels-p (asked question)
  "Return what differs between ASKED and QUESTION's score levels, or nil.
Both are score questions: the same number of levels, or a sentence saying
how they differ."
  (let ((asked-levels (harness-provider-system-one--score-levels (plist-get asked :criteria)))
        (want-levels (harness-provider-system-one--score-levels
                      (plist-get question :criteria))))
    (when (and (or asked-levels want-levels)
               (not (equal (length asked-levels) (length want-levels))))
      (format "on %d levels rather than %d" (length asked-levels) (length want-levels)))))

(defun harness-provider-system-one-artifact-agrees-p (artifact request)
  "Return what in REQUEST is not the shape ARTIFACT was made for, as strings.
The request in front of a model must ask the questions its artifact says
the model answers, of the same type and with the same options or levels:
a model asked something it was not made for answers confidently and
wrongly, so the disagreement is refused rather than sent."
  (let* ((problems nil)
         (add (lambda (fmt &rest args) (push (apply #'format fmt args) problems)))
         (want (harness-provider-system-one--questions
                (harness-provider-system-one--artifact-part artifact :questions)))
         (have (harness-provider-system-one--questions (plist-get request :questions))))
    (if (not (equal (plist-get artifact :schema-version) harness-provider-system-one-schema-version))
        (list (format "The artifact is in schema version %s, not %s"
                      (plist-get artifact :schema-version)
                      harness-provider-system-one-schema-version))
      (progn
        (dolist (cell want)
          (let ((asked (cdr (assoc (car cell) have))))
            (if (null asked)
                (funcall add "The request does not ask %s, which the artifact says the model answers"
                         (car cell))
              (let ((asked-type (harness-provider-system-one-question-type asked))
                    (want-type (harness-provider-system-one-question-type (cdr cell))))
                (unless (equal asked-type want-type)
                  (funcall add "The request asks %s as a %s question; the artifact's is a %s question"
                           (car cell)
                           (or asked-type "nameless") (or want-type "nameless")))
                ;; Only a question of the same type has options or levels
                ;; to compare: another type is already the disagreement.
                (when (equal asked-type want-type)
                  (when-let* ((difference (harness-provider-system-one--same-options-p
                                           asked (cdr cell))))
                    (funcall add "The request asks %s to choose %s" (car cell) difference))
                  (when-let* ((difference (harness-provider-system-one--same-levels-p
                                           asked (cdr cell))))
                    (funcall add "The request asks %s %s" (car cell) difference)))))))
        (dolist (cell have)
          (unless (assoc (car cell) want)
            (funcall add "The request asks %s, which the artifact does not say the model answers"
                     (car cell))))
        (nreverse problems)))))

;;;; Deciding

(defvar harness-provider-system-one--calls (make-hash-table :test 'equal)
  "Call id -> the handle of a decision that has not settled yet.")

(defun harness-provider-system-one--cancel-calls-of (provider-id)
  "Cancel every running decision PROVIDER-ID is making; return how many."
  (let ((count 0))
    (dolist (call (hash-table-keys harness-provider-system-one--calls))
      (let ((handle (gethash call harness-provider-system-one--calls)))
        (when (eq (plist-get handle :provider) provider-id)
          (cl-incf count)
          (ignore-errors (funcall (plist-get handle :cancel))))))
    count))

(defun harness-provider-system-one--promise-of (answer)
  "Return ANSWER, a provider's answer, as a plist holding its promise, or nil.
ANSWER is a promise, or a plist holding one in `:promise'."
  (cond ((harness-promise-p answer) (list :promise answer))
        ((and (listp answer) (harness-promise-p (plist-get answer :promise))) answer)))

(defun harness-provider-system-one--fill-result (model-id request result)
  "Return RESULT with what the caller is owed filled in.
MODEL-ID and REQUEST say what the provider left out: the provider's id,
the schema version, and the artifact the model carries.  A `:model' the
provider named is kept as it is: a hosted model reports the version that
actually answered, which may be newer than the alias that was asked for."
  (let* ((result (copy-sequence result))
         (pid (car (harness-provider-parse-model model-id)))
         (model (plist-get (harness-call 'provider/model model-id) :artifact)))
    (unless (plist-member result :provider)
      (setq result (plist-put result :provider pid)))
    (unless (plist-member result :model)
      (setq result (plist-put result :model model-id)))
    (unless (plist-member result :schema-version)
      (setq result (plist-put result :schema-version
                              (or (plist-get request :schema-version)
                                  harness-provider-system-one-schema-version))))
    (when (and (not (plist-member result :artifact)) model)
      (setq result (plist-put result :artifact model)))
    result))

(defun harness-provider-system-one--start (model-id request)
  "Ask MODEL-ID to answer REQUEST.  Return the handle of the call.
The model's promise settles the caller's, unless the call was cancelled,
timed out or settled already: an answer that arrives after that is
dropped, and so is a partial result it reports then.  This is the
`provider/system-one-dispatch' the funnel `provider/system-one' calls, so
every decision has the same deadline, cancellation and settle-once guard
whatever provider answers it."
  (let* ((call (format "so-%s" (harness-short-id 10)))
         (promise (harness-make-promise))
         (seconds (harness-provider-system-one--deadline request))
         (pid (car (harness-provider-parse-model model-id)))
         (hook (harness-provider--hook pid :system-one))
         (name (cdr (harness-provider-parse-model model-id)))
         (timer nil)
         (cancel-fn nil)
         (settled nil)
         (caller-partial (plist-get request :on-partial))
         (partial (and (functionp caller-partial)
                       (lambda (value)
                         (if settled
                             (harness-log 'debug "system one %s: dropped a partial result after it settled" call)
                           (condition-case err
                               (funcall caller-partial value)
                             (error (harness-log 'warn "system one %s: the partial-result handler failed: %s"
                                                 call (harness-error-message err))))))))
         (finish (lambda (state value)
                   (unless settled
                     (setq settled t)
                     (when timer (cancel-timer timer) (setq timer nil))
                     (remhash call harness-provider-system-one--calls)
                     (if (eq state 'resolved)
                         (harness-resolve promise value)
                       (harness-reject promise value)))))
         (cancel (lambda ()
                   (unless settled
                     (when cancel-fn (ignore-errors (funcall cancel-fn)))
                     (funcall finish 'rejected
                              (list 'harness-error
                                    (format "The decision was cancelled (%s)" call)))))))
    (setq timer (run-at-time
                 seconds nil
                 (lambda ()
                   (unless settled
                     (when cancel-fn (ignore-errors (funcall cancel-fn)))
                     (funcall finish 'rejected
                              (list 'harness-error
                                    (format "The decision took longer than %ss" seconds)))))))
    (puthash call (list :call call :provider pid :model model-id
                        :promise promise :cancel cancel)
             harness-provider-system-one--calls)
    (let ((sent (if partial (plist-put (copy-sequence request) :on-partial partial) request)))
      (condition-case err
          (let* ((answer (funcall hook name sent))
                 (inner (harness-provider-system-one--promise-of answer)))
            (cond
             ((null inner)
              (funcall finish 'rejected
                       (list 'harness-error
                             (format "The provider of %s returned no promise of a decision" model-id))))
             (t
              (when (functionp (plist-get answer :cancel))
                (setq cancel-fn (plist-get answer :cancel)))
              (harness-then
               (plist-get inner :promise)
               (lambda (result)
                 (if settled
                     (harness-log 'debug "system one %s: dropped an answer that arrived after it settled" call)
                   (let* ((result (harness-provider-system-one--fill-result model-id request result))
                          (problems (harness-provider-system-one-result-problems
                                     model-id request result)))
                     (if problems
                         (funcall finish 'rejected
                                  (list 'harness-error
                                        (format "The provider of %s gave a malformed result: %s"
                                                model-id (string-join problems "; "))))
                       (harness-emit 'provider/system-one-decided request result)
                       (funcall finish 'resolved result))))
                 nil)
               (lambda (failure)
                 (if settled
                     (harness-log 'debug "system one %s: dropped a failure that arrived after it settled" call)
                   (funcall finish 'rejected failure))
                 nil)))))
        (error (funcall finish 'rejected err))))
    (list :call call
          :provider pid
          :model model-id
          :promise promise
          :cancel cancel
          :deadline (harness-provider-system-one--deadline request))))

(harness-defmethod provider/system-one-dispatch (model-id request)
  "Answer REQUEST with MODEL-ID's provider, under the contract's guard.
The funnel `provider/system-one' has already checked the request against
the model's capabilities, so this asks the provider and bounds the call:
the deadline, the cancellation, the settle-once rule and the validation
of the answer are the same for every provider."
  (harness-provider-system-one--start model-id request))

(defun harness-provider-system-one-decide (request)
  "Ask REQUEST's model for System One decisions; return its handle.
The handle is `(:call ID :provider ID :model MODEL-ID :promise PROMISE
:cancel FN :deadline SECONDS)'.  PROMISE resolves with the result plist
and rejects with a `harness-error' when there is no answer: a model whose
provider does not answer System One decisions, a request the model's
capabilities do not cover, a malformed or failed answer, a timeout, or a
cancellation.  Nothing is settled twice and nothing is settled after the
call ended, so a late answer from a provider, a partial result or a
second reply is dropped.

The request is `(:model PROVIDER:NAME :state STATE :questions QUESTIONS
:schema-version N)' and optionally `:deadline', `:assets',
`:long-context', `:audio', `:embeddings', `:carried-state',
`:response-schema' and `:on-partial'.  STATE is the content the questions
are judged against, sent once.  QUESTIONS maps a name to a question
`(:type \"noul\"|\"choice\"|\"score\"|\"box\" :instructions ...
:criteria ...)'.  The result carries one answer per question, keyed by
the same name, or abstains wholesale with a `:reason'.
`harness-provider-system-one-validate' says what is wrong with a request
before it is sent.

A decision is asynchronous: this returns before the provider answers, and
never blocks the command loop.  Cancel it with
`harness-provider-system-one-cancel', which the handle's `:cancel' does
too."
  (let ((model-id (plist-get request :model)))
    (if (harness-provider-system-one--name model-id)
        ;; Through the funnel, so the policy and the contract are checked
        ;; in the one place every System One request passes, and the
        ;; deadline, cancellation and settle-once guard are the same for
        ;; every provider.
        (harness-call 'provider/system-one model-id request)
      (list :call nil :provider nil :model nil
            :promise (harness-rejected
                      (list 'harness-error "A request names its model in :model, as PROVIDER:NAME"))
            :cancel #'ignore
            :deadline (harness-provider-system-one--deadline request)))))

(defun harness-provider-system-one-cancel (handle)
  "Cancel the decision HANDLE, or the one named by its call id.
Return non-nil when a decision that was still running was cancelled, and
nil when it had already settled: cancelling twice, or cancelling one that
answered, changes nothing."
  (let* ((handle (if (stringp handle) (gethash handle harness-provider-system-one--calls) handle))
         (cancel (and (listp handle) (plist-get handle :cancel)))
         (call (and (listp handle) (plist-get handle :call))))
    (when (and cancel call (gethash call harness-provider-system-one--calls))
      (funcall cancel)
      t)))

;;;; Reading answers

(defun harness-provider-system-one-answer (result name)
  "Return RESULT's answer to the question NAME, or nil when it has none.
NAME is a string or a keyword, as the question was named."
  (let ((wanted (harness-provider-system-one--key-name name)))
    (cdr (cl-find-if (lambda (cell)
                       (equal (harness-provider-system-one--key-name (car cell)) wanted))
                     (harness-provider-system-one--pairs (plist-get result :answers))))))

(defun harness-provider-system-one-answer-value (answer)
  "Return ANSWER's decision as one value, or nil when it gives none.
A noul is its probability, a choice the option it chose, a score its
position on the levels, and a box the plist of its four edges."
  (when (listp answer)
    (pcase (harness-provider-system-one--type-name (plist-get answer :type))
      ("noul" (plist-get answer :noul))
      ("choice" (let ((choice (plist-get answer :choice)))
                  (and choice (harness-provider-system-one--key-name choice))))
      ("score" (plist-get answer :score))
      ("box" (plist-get answer :box)))))

(defun harness-provider-system-one-answer-probability (answer)
  "Return the model's own probability for the decision ANSWER made, or nil.
A noul's answer is the probability itself; a choice's is the probability
it gave the option it chose; a score's is the probability of the level it
is nearest.  A box has none: its confidence is what it says."
  (when (listp answer)
    (pcase (harness-provider-system-one--type-name (plist-get answer :type))
      ("noul" (plist-get answer :noul))
      ("choice"
       (let ((choice (harness-provider-system-one-answer-value answer)))
         (and choice
              (cdr (cl-find-if (lambda (cell)
                                 (equal (harness-provider-system-one--key-name (car cell)) choice))
                               (harness-provider-system-one--pairs
                                (plist-get answer :probabilities)))))))
      ("score"
       (let* ((score (plist-get answer :score))
              (level (and (numberp score) (round score))))
         (and level
              (cdr (cl-find-if
                    (lambda (cell)
                      (equal (harness-provider-system-one--key-name (car cell))
                             (number-to-string level)))
                    (harness-provider-system-one--pairs
                     (plist-get answer :probabilities))))))))))

(defun harness-provider-system-one-answer-confidence (answer)
  "Return the confidence ANSWER carries, or nil when it carries none.
A confidence is the model's own number about how peaked its answer was;
it is a probability of being right only when the model's artifact records
a calibration (see `harness-provider-system-one-result-problems')."
  (and (listp answer) (plist-get answer :confidence)))

;;;; A provider that answers from a directory of fixtures

(defun harness-provider-system-one--read-file (file)
  "Return the JSON value FILE holds, as the harness's plist convention has it."
  (with-temp-buffer
    (insert-file-contents file)
    (harness-json-parse (buffer-string))))

(defun harness-provider-system-one--read-cases (file)
  "Return the cases in FILE, one JSON object per line.
A blank line is skipped.  A line that is not a JSON object signals."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (cases)
      (while (< (point) (point-max))
        (let ((line (buffer-substring-no-properties (point) (line-end-position))))
          (unless (string-empty-p (string-trim line))
            (let ((case (harness-json-parse line)))
              (unless (and (listp case) (keywordp (car-safe case)))
                (signal 'harness-provider-system-one-error
                        (list (format "%s: a case is a JSON object" file))))
              (push case cases))))
        (forward-line 1))
      (nreverse cases))))

(defun harness-provider-system-one--same-state-p (a b)
  "Non-nil when states A and B are the same content.
Text compares as text, and a structured state compares as JSON does:
the same keys, whatever their order, and the same values."
  (cond
   ((and (stringp a) (stringp b)) (equal a b))
   ((and (harness-provider-system-one--object-p a) (harness-provider-system-one--object-p b))
    (equal (harness-json-encode (harness-provider-system-one--sort-object a))
           (harness-json-encode (harness-provider-system-one--sort-object b))))
   ((and (listp a) (listp b) (not (harness-provider-system-one--object-p a))
         (not (harness-provider-system-one--object-p b)))
    (equal (harness-json-encode a) (harness-json-encode b)))
   (t (equal a b))))

(defun harness-provider-system-one--sort-object (object)
  "Return OBJECT, a plist, with its keys in order, so two compare by value."
  (let ((pairs (harness-provider-system-one--pairs object)))
    (cl-loop for (key . value) in (sort pairs (lambda (x y) (string< (symbol-name (car x))
                                                                     (symbol-name (car y)))))
             append (list key (if (harness-provider-system-one--object-p value)
                                  (harness-provider-system-one--sort-object value)
                                value)))))

(defun harness-provider-system-one--question-capabilities (questions)
  "Return the capabilities a model answering QUESTIONS must declare."
  (let (capabilities)
    (dolist (cell questions)
      (when-let* ((type (harness-provider-system-one-question-type (cdr cell))))
        (setq capabilities (plist-put capabilities (intern (concat ":" type)) t))))
    capabilities))

(defun harness-provider-system-one-register-fixture (id directory &rest args)
  "Register provider ID with a System One model answering from DIRECTORY.
DIRECTORY holds `artifact.json' and `cases.jsonl'.  A case is
`(:state STATE :answers ANSWERS)'; a request whose `:state' is a case's
is answered with that case's answers, and a request no case matches is
abstained from, saying so.  Nothing is sent anywhere: this is the local
model the tests and the demo use to show that one request is served
without a model call, and the same provider may also complete or embed.

ARGS: `:model' (the model name it reports, \"fixture\" by default),
`:capabilities' what it can do beyond the default (the question types its
artifact names, `:abstain' and `:confidence'), `:label' and `:doc'.  The
provider is registered with `harness-define-provider', so its `:models'
are its catalogue and its `:system-one' hook is this contract."
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (artifact (harness-provider-system-one--read-file
                    (expand-file-name "artifact.json" directory)))
         (cases (harness-provider-system-one--read-cases
                 (expand-file-name "cases.jsonl" directory)))
         (questions (harness-provider-system-one--questions
                     (harness-provider-system-one--artifact-part artifact :questions)))
         (model (or (plist-get args :model) "fixture"))
         (capabilities (harness-plist-merge
                        (harness-provider-system-one--question-capabilities questions)
                        (list :abstain t :confidence t))))
    (unless questions
      (signal 'harness-provider-system-one-error
              (list (format "%s: the artifact names no questions" directory))))
    (dolist (problem (harness-provider-system-one-artifact-problems artifact))
      (harness-log 'warn "system one fixture %s: %s" directory problem))
    (harness-define-provider
     id
     :label (or (plist-get args :label) (format "Fixture (%s)" id))
     :doc (or (plist-get args :doc)
              (format "Answers System One questions from the deterministic cases in %s." directory))
     :models (lambda ()
               (harness-resolved
                (list (list :name model :label "Deterministic fixture"
                            :context-window 1
                            :capabilities (harness-plist-merge capabilities
                                                               (plist-get args :capabilities))
                            :artifact artifact))))
     :system-one
     (lambda (_name request)
       (let ((case (cl-find-if (lambda (c)
                                 (harness-provider-system-one--same-state-p
                                  (plist-get c :state) (plist-get request :state)))
                               cases)))
         (harness-resolved
          (if (not case)
              (list :abstained t
                    :reason "no case in the fixture has this state")
            (list :answers (plist-get case :answers)
                  :reason (format "the case %s says so" (or (plist-get case :id) "?"))))))))
    id))

;;;; A provider that speaks the System One API (TypeSafe's Jev)

(defcustom harness-provider-system-one-jev-base-url "https://api.typesafe.ai"
  "Where the System One API lives.
The published service is TypeSafe's; a reseller or a gateway that serves
the same contract is named here instead, which is why the base URL is a
setting rather than a constant.  See docs/provider-system-one.md."
  :type 'string :group 'harness-provider-system-one)

(defcustom harness-provider-system-one-jev-api-key-env "TYPESAFE_API_KEY"
  "The environment variable a System One API key is read from."
  :type 'string :group 'harness-provider-system-one)

(defcustom harness-provider-system-one-jev-model "jev-latest"
  "The System One model a Jev provider asks for when a request names none.
An alias moves when a release ships, so the model field of the answer
names the version that answered; a caller that tuned a threshold against
one version asks for that version by name."
  :type '(string :tag "Model" :names model)
  :group 'harness-provider-system-one)

(defconst harness-provider-system-one-jev-models
  '(("jev-latest" . "The most recent stable Jev release (an alias).")
    ("jev-preview" . "The most recent Jev release, official or not (an alias).")
    ("jev-1.14.0" . "Jev 1.14: choice, score, noul and box questions.")
    ("jev-1.13.0" . "Jev 1.13: choice, score and noul questions."))
  "The System One models this module knows of, and what each serves.
`GET /v1/models' lists what an account may actually send; this is the
fallback when it cannot be read, so a provider still names its models.")

(defun harness-provider-system-one--jev-api-key (configured)
  "Return the System One API key: CONFIGURED, the environment's, or auth-source's."
  (let ((usable (lambda (key)
                  (and (stringp key)
                       (let ((key (string-trim key)))
                         (and (not (string-empty-p key)) key))))))
    (or (funcall usable configured)
        (funcall usable (getenv harness-provider-system-one-jev-api-key-env))
        (ignore-errors
          (require 'auth-source)
          (when-let* ((found (car (auth-source-search :host "api.typesafe.ai"
                                                      :user "apikey" :max 1)))
                      (secret (plist-get found :secret)))
            (funcall usable (if (functionp secret) (funcall secret) secret)))))))

(defun harness-provider-system-one--jev-artifact (&rest args)
  "Return the artifact a System One model ships, built from ARGS.
The model is hosted and its weights are the vendor's, so the dataset and
evaluation are the vendor's published ones rather than this repository's:
the artifact records where they are documented, and the calibration
method the vendor states.  A model fitted by a consumer passes its own
artifact instead."
  (let ((model (or (plist-get args :model) harness-provider-system-one-jev-model))
        (questions (plist-get args :questions))
        (calibration (or (plist-get args :calibration)
                         (list :method "rlcd"
                               :source "https://docs.typesafe.ai/models#data-handling"))))
    (list :schema-version harness-provider-system-one-schema-version
          :artifact (list :id "typesafe-system-one" :version model)
          :model (list :id "typesafe-jev" :version model)
          :questions questions
          :dataset (list :name "vendor-published" :version "as of 2026-10"
                         :provenance "https://docs.typesafe.ai/models"
                         :splits nil)
          :evaluation (list :split "vendor-published"
                            :metrics nil
                            :calibration calibration)
          :runtime (list :kind "remote"
                         :requires (list harness-provider-system-one-jev-api-key-env)))))

(defun harness-provider-system-one--http-transport (url &rest args)
  "Send one request to URL with `harness-http-request'; return its cancel.
ARGS are `harness-http-request''s keywords: `:method', `:headers', `:json'
and `:callback'.  This is the transport a hosted provider uses unless it
is given another, which is how a test drives the wire format without a
network."
  (let ((handle (apply #'harness-http-request url args)))
    (lambda () (harness-http-cancel handle))))

(defun harness-provider-system-one--jev-wire-questions (questions)
  "Return QUESTIONS as the System One API's JSON object of named questions.
Each question is the plist the request gave, minus what the wire does not
carry; a score's levels are an array, whatever the length."
  (let (out)
    (dolist (cell questions out)
      (let* ((question (cdr cell))
             (type (harness-provider-system-one-question-type question))
             (criteria (plist-get question :criteria))
             (sent (list (intern "type") type)))
        (when-let* ((instructions (plist-get question :instructions)))
          (setq sent (plist-put sent (intern "instructions") instructions)))
        (when criteria
          (setq sent (plist-put sent (intern "criteria")
                                (if (equal type "score")
                                    (harness-json-array (copy-sequence criteria))
                                  criteria))))
        (setq out (plist-put out (intern (harness-provider-system-one--key-name (car cell))) sent))))))

(defun harness-provider-system-one--jev-wire-request (request model)
  "Return REQUEST as the JSON body the System One API takes, for MODEL."
  (let* ((questions (harness-provider-system-one--questions (plist-get request :questions)))
         (body (list (intern "model") model
                     (intern "state") (plist-get request :state)
                     (intern "questions") (harness-provider-system-one--jev-wire-questions questions)))
         (assets (plist-get request :assets)))
    (when assets
      (setq body (plist-put body (intern "assets")
                            (harness-provider-system-one--jev-wire-assets assets))))
    body))

(defun harness-provider-system-one--jev-wire-assets (assets)
  "Return ASSETS as the System One API's JSON object of named assets."
  (let (out)
    (dolist (cell (harness-provider-system-one--pairs assets) out)
      (let ((asset (cdr cell))
            (sent nil))
        (dolist (key '(:type :format :data_base64 :part))
          (when-let* ((value (plist-get asset key)))
            (setq sent (plist-put sent (intern (harness-provider-system-one--key-name key)) value))))
        (setq out (plist-put out (intern (harness-provider-system-one--key-name (car cell))) sent))))))

(defun harness-provider-system-one--jev-headers (api-key request)
  "Return the headers a System One request with REQUEST is sent with.
The danger-zone headers are the API's own switch for images and for the
larger context, and are sent only when the request asks for them."
  (let ((headers (list (cons "Authorization" (format "Bearer %s" api-key)))))
    (when (or (plist-get request :assets)
              (cl-some (lambda (cell)
                         (equal "box" (harness-provider-system-one-question-type (cdr cell))))
                       (harness-provider-system-one--questions (plist-get request :questions))))
      (push (cons "TypeSafe-Danger-Zone-Images" "true") headers))
    (when (harness-json-true-p (plist-get request :long-context))
      (push (cons "TypeSafe-Danger-Zone-Long-Context" "true") headers))
    headers))

(defun harness-provider-system-one--jev-read-answers (answers)
  "Return ANSWERS, the API's, as this module's.
The API names each answer by its question and types it the same way; a
field it does not send is left out rather than invented, so a malformed
answer is refused by the contract rather than repaired here.  The
answers come back as an alist of question name to a plist whose keys are
keywords, which is how the rest of this module reads one."
  (let (out)
    (dolist (cell (harness-provider-system-one--pairs answers) out)
      (let* ((name (harness-provider-system-one--key-name (car cell)))
             (answer (cdr cell))
             (type (harness-provider-system-one--type-name
                    (harness-provider-system-one--field answer "type")))
             (read (list :type type)))
        (dolist (key '(:noul :choice :confidence :score :legend :probabilities :box))
          (let ((wire (harness-provider-system-one--key-name key)))
            (let ((value (harness-provider-system-one--field answer wire)))
              (unless (null value)
                (setq read (plist-put read key value))))))
        (setq out (plist-put out (intern name) read))))))

(defun harness-provider-system-one--parse-body (body)
  "Return BODY as a JSON object, whether it came parsed or as text.
A transport that already parsed the answer hands it over as a plist; one
that hands over the bytes has them parsed here.  Text that is not JSON is
nil."
  (cond
   ((harness-provider-system-one--object-p body) body)
   ((stringp body) (condition-case nil (harness-json-parse body) (error nil)))
   (t nil)))

(defun harness-provider-system-one--jev-read-usage (usage)
  "Return USAGE, the API's token counts, as the harness's plist convention."
  (when (harness-provider-system-one--object-p usage)
    (list (intern "input_tokens")
          (harness-provider-system-one--field usage "input_tokens")
          (intern "output_tokens")
          (harness-provider-system-one--field usage "output_tokens"))))

(defun harness-provider-system-one--jev-answer-problems (status body)
  "Return what is wrong with a System One response, STATUS and BODY, or nil.
A status other than 200 says what the service said; a 200 that does not
carry answers and the model that gave them is malformed."
  (cond
   ((not (integerp status)) (list "The System One API gave no HTTP status"))
   ((not (and (>= status 200) (< status 300)))
    (let* ((error-body (and (harness-provider-system-one--object-p body) body))
           (detail (harness-provider-system-one--field error-body "detail"))
           (detail (cond ((stringp detail) detail)
                         ((harness-provider-system-one--object-p detail)
                          (or (harness-provider-system-one--field detail "msg")
                              (harness-provider-system-one--field detail "message")
                              (harness-json-encode-text detail)))
                         ((listp detail)
                          (string-join
                           (delq nil (mapcar (lambda (one)
                                               (and (harness-provider-system-one--object-p one)
                                                    (harness-provider-system-one--field one "msg")))
                                             detail))
                           "; ")))))
      (list (format "The System One API answered %s%s"
                    status (if (and detail (not (string-empty-p detail)))
                               (format ": %s" detail) "")))))
   ((not (harness-provider-system-one--object-p body))
    (list "The System One API answered with no JSON object"))
   ((not (harness-provider-system-one--object-p (harness-provider-system-one--field body "answers")))
    (list "The System One API answered with no answers"))
   ((not (harness-provider-system-one--name (harness-provider-system-one--field body "model")))
    (list "The System One API answered without naming the model that did"))))

(defun harness-provider-system-one--jev-decide (request registration &optional name)
  "Ask the System One API REGISTRATION names to answer REQUEST.
NAME is the model the caller asked for, as the provider's hook receives
it, and wins over the provider's default.  Return the handle
`provider/system-one' wants: a promise of the result and a function that
cancels the call.  The call is one `POST /v1/systemone', and the model
field of the answer is kept, because it names the version that actually
answered rather than the alias asked for."
  (let* ((model (or (and (stringp name) (not (string-empty-p name)) name)
                    (plist-get registration :model)))
         (api-key (plist-get registration :api-key))
         (promise (harness-make-promise))
         (settled nil)
         (cancel-request nil)
         (base (string-remove-suffix "/" (plist-get registration :base-url)))
         (transport (plist-get registration :transport))
         (finish (lambda (state value)
                   (unless settled
                     (setq settled t)
                     (if (eq state 'resolved)
                         (harness-resolve promise value)
                       (harness-reject promise value))))))
    (cond
     ((null api-key)
      (funcall finish 'rejected
               (list 'harness-error
                     (format "No System One API key: set %s or configure one for provider %s"
                             harness-provider-system-one-jev-api-key-env
                             (plist-get registration :provider)))))
     (t
      (condition-case err
          (setq cancel-request
                (funcall transport
                         (format "%s/v1/systemone" base)
                         :method "POST"
                         :headers (harness-provider-system-one--jev-headers api-key request)
                         :json (harness-provider-system-one--jev-wire-request request model)
                         :timeout (ceiling (harness-provider-system-one--deadline request))
                         :callback
                         (lambda (status _headers body error)
                           (cond
                            (error
                             (funcall finish 'rejected
                                      (list 'harness-error
                                            (format "The System One API call failed: %s"
                                                    (harness-error-message error)))))
                            (t
                             (let* ((parsed (harness-provider-system-one--parse-body body))
                                    (problems (harness-provider-system-one--jev-answer-problems
                                               status parsed)))
                               (if problems
                                   (funcall finish 'rejected
                                            (list 'harness-error
                                                  (string-join problems "; ")))
                                 (let* ((answers (harness-provider-system-one--jev-read-answers
                                                  (harness-provider-system-one--field parsed "answers")))
                                        (usage (harness-provider-system-one--jev-read-usage
                                                (harness-provider-system-one--field parsed "usage")))
                                        (result (list :provider (plist-get registration :provider)
                                                      :model (harness-provider-system-one--field parsed "model")
                                                      :requested-model model
                                                      :answers answers
                                                      :schema-version harness-provider-system-one-schema-version)))
                                   (when usage (setq result (plist-put result :usage usage)))
                                   (funcall finish 'resolved result)))))))))
        (error (funcall finish 'rejected err)))))
    (list :promise promise
          :cancel (lambda () (when cancel-request (ignore-errors (funcall cancel-request)))))))

(defun harness-provider-system-one-register-jev (id &rest args)
  "Register provider ID with a System One model served by the API over HTTP.
This speaks the published contract -- `POST /v1/systemone' with `model',
`state' and `questions', answered with `answers', `model' and `usage' --
so a hosted System One model is one `:model' away, and a reseller or
gateway that serves the same contract is the same adapter with another
`:base-url'.  The provider is registered with `harness-define-provider',
so it may declare other capabilities too.

ARGS: `:model' the model or alias to ask for (a request may name
another), `:base-url' (`harness-provider-system-one-jev-base-url'),
`:api-key' (read from `harness-provider-system-one-jev-api-key-env' when
not given), `:models' the model names it serves, `:capabilities' what it
can do beyond the default (the four question types, `:images',
`:long-context', `:confidence', `:calibrated', `:abstain' and `:schema'),
`:questions' the questions its artifact says the model answers,
`:artifact' an artifact to use instead of the vendor's, `:transport' the
function that sends a request (see
`harness-provider-system-one--http-transport'), `:label' and `:doc'.

The model it reports as having answered is the one the service names,
which is the version an alias resolved to: a caller that logged the alias
can still tell which model decided."
  (let* ((model (or (plist-get args :model) harness-provider-system-one-jev-model))
         (api-key (harness-provider-system-one--jev-api-key (plist-get args :api-key)))
         (artifact (or (plist-get args :artifact)
                       (harness-provider-system-one--jev-artifact
                        :model model :questions (plist-get args :questions))))
         (models (or (plist-get args :models)
                     (mapcar #'car harness-provider-system-one-jev-models)))
         (capabilities (harness-plist-merge
                        '(:noul t :choice t :score t :box t :images t :long-context t
                          :confidence t :calibrated t :abstain t :schema t)
                        (plist-get args :capabilities)))
         (registration (list :model model
                             :provider id
                             :base-url (or (plist-get args :base-url)
                                           harness-provider-system-one-jev-base-url)
                             :api-key api-key
                             :transport (or (plist-get args :transport)
                                            #'harness-provider-system-one--http-transport))))
    (unless (harness-provider-system-one--name model)
      (signal 'harness-provider-system-one-error
              (list (format "System One provider %s needs a :model" id))))
    (harness-define-provider
     id
     :label (or (plist-get args :label) (format "System One (%s)" id))
     :doc (or (plist-get args :doc)
              (format "Answers System One questions with %s." model))
     :models (lambda ()
               (harness-resolved
                (mapcar (lambda (name)
                          (list :name name :label name
                                :context-window 1
                                :capabilities (harness-plist-merge capabilities
                                                                   (plist-get args :capabilities))
                                :artifact artifact))
                        models)))
     :system-one (lambda (name request)
                   (harness-provider-system-one--jev-decide request registration name)))
    id))

(defun harness-provider-system-one-jev-refresh-models (id)
  "Ask `GET /v1/models' what provider ID may send, and keep it.
Return a promise of the model names, or a rejected promise when the
service or the key cannot be read.  The catalogue is what an account may
actually send, which is more than the module knows of on its own; it is
read on request rather than on every listing, so a provider's models are
always available without a network round trip.  The provider's models are
then its own listing again, which the catalogue caches."
  (let ((id (harness-provider-system-one--symbol id)))
    (cond
     ((not (harness-provider-get id))
      (harness-rejected
       (list 'harness-error
             (format "No provider is registered as %s" id))))
     ((null (harness-provider-system-one--jev-api-key nil))
      (harness-rejected
       (list 'harness-error
             (format "No System One API key: set %s"
                     harness-provider-system-one-jev-api-key-env))))
     (t
      (let* ((api-key (harness-provider-system-one--jev-api-key nil))
             (base (string-remove-suffix "/" harness-provider-system-one-jev-base-url))
             (promise (harness-make-promise)))
        (harness-http-request
         (format "%s/v1/models" base)
         :headers (list (cons "Authorization" (format "Bearer %s" api-key)))
         :callback
         (lambda (status _headers body error)
           (cond
            (error
             (harness-reject promise
                             (list 'harness-error
                                   (format "Listing the System One models failed: %s"
                                           (harness-error-message error)))))
            ((not (and (integerp status) (>= status 200) (< status 300)))
             (harness-reject promise
                             (list 'harness-error
                                   (format "The System One API answered %s listing its models"
                                           status))))
            (t
             (let* ((parsed (condition-case nil (harness-json-parse body) (error nil)))
                    (entries (plist-get parsed (intern "models")))
                    (names (delq nil (mapcar (lambda (entry)
                                               (harness-provider-system-one--name
                                                (plist-get entry (intern "name"))))
                                             entries))))
               (if (null names)
                   (harness-reject promise
                                   (list 'harness-error
                                         "The System One API listed no models"))
                 (harness-provider-relist id)
                 (harness-resolve promise names)))))))
        promise)))))

;;;; The module

(harness-declare-event 'provider/system-one-decided
  "A System One model answered: (REQUEST RESULT), after the result was validated.")

(defconst harness-provider-system-one t
  "Whether the System One contract is loaded.
`provider/system-one' asks `provider/system-one-validate' when it is
bound, so a harness without this module asks its providers exactly what
it always asked.")

(harness-define-module 'provider-system-one
  :doc "System One decision models: typed questions and answers, as a capability of the provider interface."
  :requires '(provider))

(provide 'harness-provider-system-one)
;;; harness-provider-system-one.el ends here
