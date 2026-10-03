;;; harness-provider.el --- Completion provider contract and registry  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider turns a request into a stream of events (see
;; docs/architecture.md, "provider").  This module holds the registry,
;; the model catalogue and the small amount of glue that keeps every
;; provider honest: a request always ends with exactly one `done'
;; event, and callbacks never see each other's errors.
;;
;; The catalogue is cached per provider.  Defining a provider again, as
;; every reload does, forgets that provider's models and no other's,
;; and the harness asks for them again on its own: `provider/model'
;; asks a provider whose models are not cached.  A static catalogue
;; (Claude Code's, say) answers at once, so its models are always
;; found; nothing waits for a client to ask `provider/models' first.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)

;;;; Customize types of model plists
;;
;; Options that describe models by hand (an endpoint's `:models',
;; Bedrock's model defaults) share these types.  Every key has a name,
;; a value of its own type, help, and the value it starts from, so the
;; settings page and customize can offer each key without anyone
;; having to know it.

(defconst harness-provider-pricing-type
  '(plist :tag "Price"
          :doc "US dollars per million tokens; a part left out costs nothing."
          :value (:input 0.0 :output 0.0)
          :options ((:input (number :tag "Input" :value 0.0))
                    (:output (number :tag "Output" :value 0.0))
                    (:cache-read (number :tag "Cache read" :value 0.0
                                         :doc "Input read back from the prompt cache."))
                    (:cache-write (number :tag "Cache write" :value 0.0
                                          :doc "Input written to the prompt cache."))))
  "Customize type of a model's `:pricing'.")

(defconst harness-provider-modalities-type
  '(choice :tag "Input" :value ("text" "image")
           :doc "What a prompt may hold besides text."
           (const :tag "Text" ("text"))
           (const :tag "Text and images" ("text" "image"))
           (repeat :tag "Other" (string :tag "Modality")))
  "Customize type of a model's `:input-modalities'.")

(defconst harness-provider-thinking-levels-type
  '(set :tag "Thinking levels" :format "%{%t%}: %v\n" :entry-format "%b %v"
        :value ("low" "medium" "high")
        :doc "Levels the model thinks at, for the session's thinking menu."
        (const :format "%t  " "low") (const :format "%t  " "medium") (const :format "%t  " "high")
        (const :format "%t  " "xhigh") (const :format "%t" "max"))
  "Customize type of a model's `:thinking-levels'.")

(defconst harness-provider-tiers-type
  '(plist :tag "Tiers"
          :value (:cheap "haiku" :balanced "sonnet" :frontier "opus")
          :options
          ((:cheap (string :tag "Cheap" :value "haiku"
                           :doc "Model for work that just has to be cheap: the auto-mode judge, say."))
           (:balanced (string :tag "Balanced" :value "sonnet"
                              :doc "Model for everyday work: capable, at a fair price."))
           (:frontier (string :tag "Frontier" :value "opus"
                              :doc "The most capable model, for the hardest work."))))
  "Customize type of the models a provider names for the common tiers
\(see `harness-provider-tier-model').  A model name or id regexp of
the provider's catalogue, e.g. \"haiku\"; `:tiers' in
`harness-define-provider' and in a provider's endpoints takes the same.")

(defun harness-provider-model-type (&rest options)
  "Return the customize type of a model plist, with OPTIONS added.
OPTIONS are more `:options' entries of the plist, for keys a provider
reads besides those of every model."
  `(plist :tag "Model"
          :value (:name "model-name")
          :options ((:name (string :tag "Name" :value "model-name"
                                   :doc "The id the API knows the model by."))
                    (:label (string :tag "Label" :value "Model"
                                    :doc "Shown in the model picker instead of the name."))
                    (:context-window (integer :tag "Context window" :value 128000
                                              :doc "Tokens the model holds: input and output."))
                    (:max-output (integer :tag "Max output" :value 8192
                                          :doc "Most tokens of one reply."))
                    (:input-modalities ,harness-provider-modalities-type)
                    (:thinking-levels ,harness-provider-thinking-levels-type)
                    (:pricing ,harness-provider-pricing-type)
                    ,@options)))

(cl-defstruct (harness-provider (:copier nil))
  id label doc models-fn complete-fn fork-fn quota-fn capabilities tiers)

(defvar harness-providers (make-hash-table :test 'eq)
  "Provider id -> `harness-provider'.")

;;;; Model catalogue cache

(defvar harness-provider--models nil
  "The cached models of every registered provider, in one list.")

(defvar harness-provider--models-promise nil "In-flight refresh, if any.")

(defvar harness-provider--models-by-provider (make-hash-table :test 'eq)
  "Provider id -> its normalised model list, filled as each provider answers.
A provider whose listing failed maps to nil; one not asked yet is absent.")

(defvar harness-provider--model-index (make-hash-table :test 'equal)
  "Model id -> its plist in `harness-provider--models'.")

(defvar harness-provider--fetching (make-hash-table :test 'eq)
  "Provider id -> promise of its model listing, while one is in flight.")

(defun harness-provider--rebuild-cache ()
  "Rebuild `harness-provider--models' and its index from the cached listings."
  (let (all)
    (maphash (lambda (id models)
               (when (gethash id harness-providers)
                 (setq all (append all models))))
             harness-provider--models-by-provider)
    (setq harness-provider--models all)
    (clrhash harness-provider--model-index)
    (dolist (m all)
      (let ((id (plist-get m :id)))
        (unless (gethash id harness-provider--model-index)
          (puthash id m harness-provider--model-index))))))

(defun harness-provider--listed-p (id)
  "Non-nil when the models of provider ID are cached; a failed listing counts."
  (not (eq (gethash id harness-provider--models-by-provider 'unlisted) 'unlisted)))

(defun harness-provider--forget (id)
  "Forget the cached models of provider ID, so the next lookup asks it again."
  (remhash id harness-provider--models-by-provider)
  (remhash id harness-provider--fetching)
  (harness-provider--rebuild-cache))

(cl-defun harness-define-provider (id &key label doc models complete fork quota capabilities tiers)
  "Register provider ID.
LABEL and DOC describe it.  MODELS is a function returning a promise of
model plists.  COMPLETE takes a request plist and returns a handle
plist with `:cancel'.  FORK, when given, takes (MODEL-ID STATE) and
returns a promise of a new provider state.  QUOTA takes an optional
REFRESH flag and returns a promise of billing and quota information
\(see `provider/quota').  CAPABILITIES is the static capability plist.
TIERS names a model per user-facing tier (see `harness-model-tiers'
and `harness-provider-tier-model') so the harness can pick a model on
its own.  Defining ID again replaces it and forgets the models it
listed, which it is asked for again when needed; other providers'
models stay cached."
  (puthash id (make-harness-provider :id id :label (or label (symbol-name id)) :doc doc
                                     :models-fn models :complete-fn complete
                                     :fork-fn fork :quota-fn quota
                                     :capabilities capabilities :tiers tiers)
           harness-providers)
  (harness-provider--forget id)
  id)

(defun harness-provider-get (id)
  "Return provider ID or nil."
  (gethash id harness-providers))

(defun harness-provider-unregister (id)
  "Remove provider ID from the registry and forget its models.
Return non-nil when a provider was registered under ID."
  (prog1 (and (gethash id harness-providers) t)
    (remhash id harness-providers)
    (harness-provider--forget id)))

(defun harness-provider-parse-model (model-id)
  "Split MODEL-ID \"provider:name\" into (PROVIDER-SYMBOL . NAME)."
  (if (and model-id (string-match "\\`\\([a-z0-9_-]+\\):\\(.+\\)\\'" model-id))
      (cons (intern (match-string 1 model-id)) (match-string 2 model-id))
    (cons nil model-id)))

(harness-defmethod provider/list ()
  "Return registered providers as (:id :label :doc :capabilities :tiers) plists."
  (let (out)
    (maphash (lambda (id p)
               (push (list :id id :label (harness-provider-label p)
                           :doc (harness-provider-doc p)
                           :capabilities (harness-provider-capabilities p)
                           :tiers (harness-provider-tiers p))
                     out))
             harness-providers)
    (sort out (lambda (a b) (string< (symbol-name (plist-get a :id)) (symbol-name (plist-get b :id)))))))

(defun harness-provider--normalise-model (provider model)
  "Fill defaults into MODEL from PROVIDER."
  (let* ((name (plist-get model :name))
         (pid (harness-provider-id provider))
         (m (copy-sequence model)))
    (setq m (plist-put m :provider pid))
    (setq m (plist-put m :id (or (plist-get m :id) (format "%s:%s" pid name))))
    (setq m (plist-put m :label (or (plist-get m :label) name)))
    (setq m (plist-put m :provider-label (harness-provider-label provider)))
    (setq m (plist-put m :context-window (or (plist-get m :context-window) 128000)))
    (setq m (plist-put m :input-modalities (or (plist-get m :input-modalities) '("text"))))
    (setq m (plist-put m :capabilities (harness-plist-merge (harness-provider-capabilities provider)
                                                            (plist-get m :capabilities))))
    m))

(defun harness-provider--settle (p listing &optional later)
  "Cache what LISTING, the settled promise of provider P's models, holds.
Nothing is cached when P was defined again or removed meanwhile.  A
failed listing is logged; it leaves models P listed before in place,
else caches P as listing nothing, so lookups do not ask it again
before a refresh.  Every change is announced as
`provider/models-updated', from the command loop when LATER is
non-nil.  Return non-nil when models were cached."
  (let* ((id (harness-provider-id p))
         (current (eq (gethash id harness-providers) p))
         (ok (eq (harness-promise-state listing) 'resolved))
         (value (harness-promise-value listing)))
    (when current
      (remhash id harness-provider--fetching))
    (unless ok
      (harness-log 'warn "provider %s: listing models failed: %s" id (harness-error-message value)))
    (when (and current (or ok (not (harness-provider--listed-p id))))
      (puthash id (and ok (mapcar (lambda (m) (harness-provider--normalise-model p m)) value))
               harness-provider--models-by-provider)
      (harness-provider--rebuild-cache)
      (if later
          (harness-emit-later 'provider/models-updated harness-provider--models)
        (harness-emit 'provider/models-updated harness-provider--models)))
    (and current ok)))

(defun harness-provider--fetch (p &optional lookup)
  "Ask provider P for its models; return a promise settled once they are cached.
A listing still in flight is shared, not asked for again.  A provider
that lists its models at once (a static catalogue) has them cached
before this returns.  The promise resolves to non-nil when they were
cached; see `harness-provider--settle'.  LOOKUP non-nil means a lookup
asks: one answered at once is then announced from the command loop, so
the lookup calls no subscriber."
  (let ((id (harness-provider-id p)))
    (or (gethash id harness-provider--fetching)
        (let ((listing (condition-case err
                           (harness-as-promise (funcall (harness-provider-models-fn p)))
                         (error (harness-rejected err)))))
          (if (harness-promise-settled-p listing)
              (harness-resolved (harness-provider--settle p listing lookup))
            (puthash id (harness-then listing
                                      (lambda (_) (harness-provider--settle p listing))
                                      (lambda (_) (harness-provider--settle p listing)))
                     harness-provider--fetching))))))

(defun harness-provider--complete-p ()
  "Non-nil when every registered provider that lists models has them cached."
  (catch 'incomplete
    (maphash (lambda (id p)
               (when (and (harness-provider-models-fn p) (not (harness-provider--listed-p id)))
                 (throw 'incomplete nil)))
             harness-providers)
    t))

(harness-defmethod provider/models (&optional refresh)
  "Return a promise of every model from every provider.
Results are cached per provider as soon as that provider answers, so a
slow endpoint never hides a fast one; REFRESH forces a new query.  A
provider that fails is logged and skipped."
  (cond
   ((and (not refresh) (harness-provider--complete-p))
    (harness-resolved harness-provider--models))
   ((and harness-provider--models-promise (not refresh)
         (not (harness-promise-settled-p harness-provider--models-promise)))
    harness-provider--models-promise)
   (t
    (let (promises)
      (maphash (lambda (id p)
                 (when (and (harness-provider-models-fn p)
                            (or refresh (not (harness-provider--listed-p id))))
                   (push (harness-provider--fetch p) promises)))
               harness-providers)
      (setq harness-provider--models-promise
            (harness-then (harness-all (nreverse promises))
                          (lambda (_) harness-provider--models)))))))

(harness-defmethod provider/model (model-id)
  "Return the model plist for MODEL-ID from the catalogue, or a minimal one.
A provider whose models are not cached is asked for them first.  One
that lists them at once (a static catalogue) has them cached before
this returns, so its models are always found.  Until one that answers
later has, and for a model its provider does not list, a minimal plist
stands in, with a context window of 128000."
  (or (gethash model-id harness-provider--model-index)
      (pcase-let* ((`(,pid . ,name) (harness-provider-parse-model model-id))
                   (p (and pid (harness-provider-get pid))))
        (cond
         ((null p)
          (list :id model-id :provider pid :name name :label (or name "?")
                :context-window 128000 :input-modalities '("text") :capabilities nil))
         ((and (harness-provider-models-fn p)
               (not (harness-provider--listed-p pid))
               (progn (harness-provider--fetch p t)
                      (gethash model-id harness-provider--model-index))))
         (t (harness-provider--normalise-model p (list :name name)))))))

(harness-defmethod provider/capabilities (model-id)
  "Return the capability plist for MODEL-ID."
  (plist-get (harness-call 'provider/model model-id) :capabilities))

;;;; Model tiers

(defconst harness-model-tiers '(:cheap :balanced :frontier)
  "Tiers a provider can name a model for.
`cheap' is for the calls the harness makes on its own, such as the
auto-mode permission judge; `balanced' and `frontier' are a middle and
top model a user might pick for their own work.  A provider names a
model per tier with `:tiers' in `harness-define-provider'; a tier it
does not name is taken from its own models sorted by price.")

(defun harness-provider--cached-models (id)
  "Return the models cached for provider ID, or nil.
Nil means the provider has not answered yet, or listed nothing."
  (gethash id harness-provider--models-by-provider))

(defun harness-provider--price-score (model)
  "Return a comparable price for MODEL, or nil without a usable one.
The score is its input plus output price per million tokens, the two
numbers a call is billed by.  A model with no price, or one a provider
marks unknown (a negative rate), has no score and is never chosen over
one whose cost is known."
  (let* ((p (plist-get model :pricing))
         (in (plist-get p :input))
         (out (plist-get p :output)))
    (when (and (numberp in) (numberp out) (>= in 0) (>= out 0))
      (+ in out))))

(defun harness-provider--models-by-price (models)
  "Return MODELS sorted by price, cheapest first; unpriced models last."
  (sort (copy-sequence models)
        (lambda (a b)
          (let ((pa (harness-provider--price-score a))
                (pb (harness-provider--price-score b)))
            (cond ((and pa pb) (< pa pb))
                  (pa t)
                  (pb nil)
                  (t (string< (or (plist-get a :id) "") (or (plist-get b :id) ""))))))))

(defun harness-provider--by-price (models tier)
  "Return the MODEL of MODELS that TIER names by price, or nil.
The cheapest is `:cheap', the dearest `:frontier', the middle
`:balanced'.  Models without `:pricing' are left out."
  (let* ((priced (cl-remove-if-not #'harness-provider--price-score models))
         (sorted (harness-provider--models-by-price priced))
         (n (length sorted)))
    (when (> n 0)
      (pcase tier
        (:cheap (car sorted))
        (:frontier (car (last sorted)))
        (:balanced (nth (/ (1- n) 2) sorted))
        (_ nil)))))

(defun harness-provider--tier-match (models matcher)
  "Return the model in MODELS that MATCHER names, or nil.
MATCHER is a model name or id, exactly or as a regexp."
  (when (and matcher (stringp matcher))
    (or (cl-find matcher models :key (lambda (m) (plist-get m :name)) :test #'equal)
        (cl-find matcher models :key (lambda (m) (plist-get m :id)) :test #'equal)
        (cl-find-if (lambda (m)
                      (let ((name (plist-get m :name)) (id (plist-get m :id)))
                        (ignore-errors
                          (or (and (stringp name) (string-match-p matcher name))
                              (and (stringp id) (string-match-p matcher id))))))
                    models))))

(defun harness-provider--tier (value)
  "Return VALUE as a tier keyword, defaulting to `:cheap'.
A provider names its tiers with keywords, so `cheap', `:cheap' and
\":cheap\" all stand for the same one."
  (cond ((null value) :cheap)
        ((keywordp value) value)
        ((symbolp value) (intern (concat ":" (symbol-name value))))
        ((stringp value) (intern (concat ":" (string-remove-prefix ":" value))))
        (t :cheap)))

(defun harness-provider-tier-model (model-id &optional tier)
  "Return the id of the TIER model of MODEL-ID's provider, or nil.
TIER defaults to `cheap'.  The provider's `:tiers' names a model (a
name, id or regexp) for it; a tier it does not name, and a provider
that declares none, takes the provider's models sorted by price
\(`cheap' the least expensive, `frontier' the most, `balanced' the
middle).  Models whose cost is unknown are never chosen by price.  A
provider not listed yet is asked for its models, which a static
catalogue answers at once; nil comes back until one that answers later
has."
  (let* ((tier (harness-provider--tier tier))
         (pid (car (harness-provider-parse-model model-id)))
         (provider (and pid (harness-provider-get pid))))
    (when provider
      (when (and (harness-provider-models-fn provider)
                 (not (harness-provider--listed-p pid)))
        (harness-provider--fetch provider t))
      (let* ((models (harness-provider--cached-models pid))
             (model (and models
                         (or (harness-provider--tier-match
                              models (plist-get (harness-provider-tiers provider) tier))
                             (harness-provider--by-price models tier)))))
        (and model (plist-get model :id))))))

(harness-defmethod provider/tier-model (model-id &optional tier)
  "Return the id of the TIER model of MODEL-ID's provider, or nil.
TIER defaults to `cheap'; see `harness-provider-tier-model'."
  (harness-provider-tier-model model-id tier))

(defun harness-provider--guard-events (on-event)
  "Wrap ON-EVENT so errors are contained and `done' is delivered once."
  (let ((done nil))
    (lambda (event)
      (unless done
        (when (eq (plist-get event :type) 'done) (setq done t))
        (condition-case err
            (funcall on-event event)
          (error (harness-log 'error "provider event handler failed on %S: %S"
                              (plist-get event :type) err)))))))

(harness-defmethod provider/complete (request)
  "Start a completion for REQUEST; return a handle plist with `:cancel'.
The provider is chosen from the request's `:model'.  Errors in setup
are reported through the `:on-event' callback as a `done' event with
`:stop-reason' error."
  (pcase-let* ((`(,pid . ,_) (harness-provider-parse-model (plist-get request :model)))
               (provider (and pid (harness-provider-get pid)))
               (on-event (harness-provider--guard-events (or (plist-get request :on-event) #'ignore)))
               (request (plist-put (copy-sequence request) :on-event on-event)))
    (cond
     ((null provider)
      (funcall on-event (list :type 'done :stop-reason 'error
                              :error (format "No provider for model %s" (plist-get request :model))))
      (list :cancel #'ignore))
     (t
      (condition-case err
          (let ((handle (funcall (harness-provider-complete-fn provider) request)))
            (harness-emit 'provider/request-started pid request)
            (or handle (list :cancel #'ignore)))
        (error
         (funcall on-event (list :type 'done :stop-reason 'error :error (harness-error-message err)))
         (list :cancel #'ignore)))))))

(harness-defmethod provider/fork (model-id state)
  "Ask MODEL-ID's provider to fork provider STATE.
Return a promise of the new state, or of nil when unsupported.  The
new state names the provider it belongs to (`:provider', see
`harness-tag-provider-state')."
  (pcase-let* ((`(,pid . ,_) (harness-provider-parse-model model-id))
               (provider (and pid (harness-provider-get pid))))
    (if (and provider (harness-provider-fork-fn provider))
        (condition-case err
            (harness-then (harness-as-promise (funcall (harness-provider-fork-fn provider) model-id state))
                          (lambda (new) (harness-tag-provider-state new model-id)))
          (error (harness-rejected err)))
      (harness-resolved nil))))

(defun harness-provider--accepts-arg-p (fn)
  "Non-nil when function FN can be called with one argument."
  (let ((arity (func-arity fn)))
    (or (eq (cdr arity) 'many) (>= (cdr arity) 1))))

(harness-defmethod provider/quota (provider-id &optional refresh)
  "Return a promise of PROVIDER-ID's billing and quota information, or of nil.
PROVIDER-ID is a symbol or its name.  REFRESH non-nil asks the provider
to fetch fresh data first.  The value is (:billing api|subscription|nil
:plan ID :plan-label LABEL :windows ((:name :label :used FRACTION
:resets FLOAT ...) ...) :extra PLIST :updated FLOAT ...); see
docs/architecture.md."
  (let* ((p (harness-provider-get (if (stringp provider-id) (intern provider-id) provider-id)))
         (fn (and p (harness-provider-quota-fn p))))
    (cond ((null fn) (harness-resolved nil))
          ((and (harness-json-true-p refresh) (harness-provider--accepts-arg-p fn))
           (harness-as-promise (funcall fn t)))
          (t (harness-as-promise (funcall fn))))))

(harness-declare-event 'provider/models-updated
                       "(MODELS) after a provider's models were cached; MODELS is the whole catalogue.")
(harness-declare-event 'provider/request-started "(PROVIDER-ID REQUEST) when a completion starts.")
(harness-declare-event 'provider/quota-updated
                       "(PROVIDER-ID QUOTA) when a provider learns new billing or quota information.")

(defun harness-provider--init ()
  "Warm the model catalogue in the background."
  (harness-run-soon (lambda () (ignore-errors (harness-call 'provider/models)))))

(harness-define-module 'provider
  :doc "Provider contract, registry and model catalogue."
  :init #'harness-provider--init)

(provide 'harness-provider)
;;; harness-provider.el ends here
