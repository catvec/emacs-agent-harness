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
;; asks a provider whose models are not cached.  A provider that
;; answers at once (Claude Code's, from what its CLI last listed) has
;; its models found from the first lookup; nothing waits for a client
;; to ask `provider/models' first.  A provider that learns more later
;; (a new listing, the window a model really has) lists again with
;; `harness-provider-relist'.
;;
;; No model gets a context window silently.  One its provider sizes
;; has that size; one it does not (a listing of bare ids, a name it
;; does not list) gets an estimate, flagged `:context-window-estimated'
;; with what it is based on in `:context-window-basis': the same model
;; as another provider lists it, else the closest model of its own
;; provider, else the window its provider's models mostly have, else
;; `harness-provider-fallback-context-window'.  A provider can say
;; more about a name it does not list (an alias, a variant) through
;; its `:resolve' function.
;;
;; `harness-allowed-models' keeps the harness to some models, which an
;; administrator's policy may set (see docs/policy.md).  Every request
;; for another is refused here, where every request passes, whoever
;; made it: a session, a task, the auto-mode judge, naming or
;; compaction.  The catalogue clients get (`provider/models') lists
;; only the models allowed, and a tier's model is chosen among them.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)
(require 'harness-policy)

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

(defcustom harness-provider-fallback-context-window 200000
  "Context window, in tokens, of a model nothing else gives a size to.
A model whose provider does not say how large its window is gets the
window of the same model at another provider, else that of the closest
model its provider lists, else the window most of its provider's
models have; this is what is left when the harness knows none of
them.  Such a window is an estimate: the model says so with
`:context-window-estimated', and the harness logs it."
  :type '(integer :tag "Tokens") :group 'harness)

(defcustom harness-cache-ttl 300
  "Seconds a provider keeps a session's prompt cache after its last use.
Once a session has been idle for longer, its next request sends the
whole conversation again uncached, which costs more and takes longer,
and the chat warns above the compose box.  Five minutes is what
Anthropic's and OpenAI's caches keep by default.  This is the
fallback: a lifetime the provider reports for the request is believed
first (Claude Code says when it wrote to its one-hour cache), then
`harness-cache-ttl-overrides', then the `:cache-ttl' capability of
the model or its provider (see `harness-provider-cache-ttl')."
  :type '(integer :tag "Seconds") :group 'harness)

(defcustom harness-cache-ttl-overrides nil
  "Prompt cache lifetimes of particular providers or models.
Each entry is (REGEXP . SECONDS): a model whose id, \"provider:name\",
matches REGEXP keeps its cache SECONDS, whatever its provider
declares; the first entry that matches wins.  (\"\\\\`bedrock:\" .
3600), say, for Bedrock models asked for the one-hour cache.  A
lifetime the provider reports for a request still wins over these."
  :type '(alist :key-type (regexp :tag "Model id")
                :value-type (integer :tag "Seconds"))
  :group 'harness)

(defcustom harness-allowed-models nil
  "The models the harness may use, as patterns of model ids; nil allows any.
A model id is \"provider:name\", such as \"claude:opus\".  A pattern is
a glob: * stands for any run of characters and ? for one, so
\"claude:*\" allows every model of Claude Code's provider and
\"*:*sonnet*\" a Sonnet at any provider.  A pattern without a colon
names providers: \"claude\" is \"claude:*\".  A request for any other
model is refused before its provider sees it, the harness's own
requests (the auto-mode judge, naming, compaction) included, and the
model picker lists only models allowed.  An administrator's policy may
set this (see docs/policy.md)."
  :type '(repeat (string :tag "Provider, model or pattern" :names (provider model)))
  :group 'harness)

(defun harness-provider-model-allowed-p (model-id)
  "Non-nil when `harness-allowed-models' lets the harness use MODEL-ID."
  (let ((patterns (default-value 'harness-allowed-models)))
    (or (null patterns)
        (and (stringp model-id)
             (let ((provider (car (harness-provider-parse-model model-id)))
                   (case-fold-search nil))
               (cl-some (lambda (pattern)
                          (and (stringp pattern)
                               (if (string-search ":" pattern)
                                   (string-match-p (wildcard-to-regexp pattern) model-id)
                                 (and provider
                                      (string-match-p (wildcard-to-regexp pattern)
                                                      (symbol-name provider))))))
                        patterns))))))

(defun harness-provider-model-refusal (model-id)
  "Return why the harness may not use MODEL-ID, or nil when it may."
  (unless (harness-provider-model-allowed-p model-id)
    (format "Model %s is not allowed: harness-allowed-models%s allows only %s"
            (or model-id "(none)")
            (if (harness-policy-pinned-p 'harness-allowed-models)
                (format ", set by policy (%s)," (harness-policy-file-name))
              "")
            (mapconcat (lambda (p) (format "%s" p)) (default-value 'harness-allowed-models) ", "))))

(defun harness-provider--allowed (models)
  "Return those of MODELS, model plists, that `harness-allowed-models' allows."
  (if (default-value 'harness-allowed-models)
      (cl-remove-if-not (lambda (m) (harness-provider-model-allowed-p (plist-get m :id))) models)
    models))

;;;; Model catalogue cache

(defvar harness-provider--models nil
  "The cached models of every registered provider, in one list.")

(defvar harness-provider--models-promise nil "In-flight refresh, if any.")

(defvar harness-provider--models-by-provider (make-hash-table :test 'eq)
  "Provider id -> its normalised model list, filled as each provider answers.
A provider whose listing failed maps to nil; one not asked yet is absent.
A model its provider does not size has no window here; the catalogue
\(`harness-provider--catalogue') holds it with an estimate.")

(defvar harness-provider--catalogue (make-hash-table :test 'eq)
  "Provider id -> its models as the catalogue gives them, estimates filled in.
Rebuilt from `harness-provider--models-by-provider' whenever a listing
changes, so estimates follow what the other providers list.")

(defvar harness-provider--model-index (make-hash-table :test 'equal)
  "Model id -> its plist in `harness-provider--models'.")

(defvar harness-provider--fetching (make-hash-table :test 'eq)
  "Provider id -> promise of its model listing, while one is in flight.")

(defvar harness-provider--lookups (make-hash-table :test 'equal)
  "Model id -> the plist `provider/model' made for a model nobody lists.
Forgotten whenever the catalogue changes, as the estimate may change too.")

(defvar harness-provider--estimate-index nil
  "What estimates are drawn from, made once per catalogue: see
`harness-provider--estimate-index'.  Nil until needed after a change.")

(defvar harness-provider--warned (make-hash-table :test 'equal)
  "Keys of the estimates the log has already told about.")

(defun harness-provider--rebuild-cache ()
  "Rebuild `harness-provider--models' and its index from the cached listings.
A model without a window gets its estimate here, from every listing
cached now (see `harness-provider--estimate')."
  (setq harness-provider--estimate-index nil)
  (clrhash harness-provider--lookups)
  (clrhash harness-provider--catalogue)
  (let (all)
    (maphash (lambda (id models)
               (when (gethash id harness-providers)
                 (let ((filled (harness-provider--fill-windows id models)))
                   (puthash id filled harness-provider--catalogue)
                   (setq all (append all filled)))))
             harness-provider--models-by-provider)
    (setq harness-provider--models all)
    (clrhash harness-provider--model-index)
    (dolist (m all)
      (let ((id (plist-get m :id)))
        (unless (gethash id harness-provider--model-index)
          (puthash id m harness-provider--model-index))))))

;;;; Estimated context windows

(defun harness-provider--window-p (value)
  "Non-nil when VALUE is a usable context window: a positive number."
  (and (numberp value) (> value 0)))

(defun harness-provider--sized-p (model)
  "Non-nil when MODEL's window comes from its provider, not from an estimate."
  (and (harness-provider--window-p (plist-get model :context-window))
       (not (plist-get model :context-window-estimated))))

(defun harness-provider-model-key (name)
  "Return model NAME reduced to what names the model whoever serves it.
The vendor or region a provider puts before it goes (\"openai/\",
\"us.anthropic.\"), and so do a release date and a Bedrock version
\(\"-20251001\", \"@20251001\", \"-v1:0\"); dots become dashes, so
\"anthropic/claude-opus-4.5\" and \"claude-opus-4-5-20251101\" have one
key.  A variant suffix such as \"[1m]\" stays: it is another window."
  (let ((key (downcase (or name ""))))
    (setq key (replace-regexp-in-string "\\`.*/" "" key))
    (setq key (replace-regexp-in-string
               "\\`\\(?:\\(?:us\\|eu\\|apac\\|global\\|jp\\|au\\|ca\\|us-gov\\)\\.\\)?\\(?:[a-z0-9-]+\\.\\)?\\([a-z]\\)"
               "\\1" key))
    (setq key (replace-regexp-in-string "\\(?:-v[0-9]+\\)?:[0-9]+\\'" "" key))
    (setq key (replace-regexp-in-string "[-@]20[0-9][0-9]-?[01][0-9]-?[0-3][0-9]\\'" "" key))
    (setq key (replace-regexp-in-string "-latest\\'" "" key))
    (replace-regexp-in-string "[._ ]" "-" key)))

(defun harness-provider--key-words (key)
  "Return the words of model KEY, split at its dashes."
  (split-string key "-" t))

(defun harness-provider--most-common (windows)
  "Return the window most of WINDOWS have; the largest of the most common."
  (let ((counts nil))
    (dolist (w windows)
      (let ((cell (assoc w counts)))
        (if cell (cl-incf (cdr cell)) (push (cons w 1) counts))))
    (car (car (sort counts (lambda (a b) (or (> (cdr a) (cdr b))
                                             (and (= (cdr a) (cdr b)) (> (car a) (car b))))))))))

(defun harness-provider--estimate-index ()
  "Return what estimates are drawn from, made from the cached listings.
The value is (BY-KEY . BY-PROVIDER): BY-KEY maps a model key (see
`harness-provider-model-key') to the (WINDOW . ID) of the models with
that key, BY-PROVIDER a provider id to the (WORDS WINDOW ID) of its
models.  Only windows the providers gave count; no estimate is drawn
from another."
  (or harness-provider--estimate-index
      (let ((by-key (make-hash-table :test 'equal))
            (by-provider (make-hash-table :test 'eq)))
        (maphash (lambda (pid models)
                   (when (gethash pid harness-providers)
                     (dolist (m models)
                       (when (harness-provider--sized-p m)
                         (let ((key (harness-provider-model-key (plist-get m :name)))
                               (window (plist-get m :context-window))
                               (id (plist-get m :id)))
                           (push (cons window id) (gethash key by-key))
                           (push (list (harness-provider--key-words key) window id)
                                 (gethash pid by-provider)))))))
                 harness-provider--models-by-provider)
        (setq harness-provider--estimate-index (cons by-key by-provider)))))

(defun harness-provider--common-words (a b)
  "Return how many leading words the word lists A and B share."
  (let ((n 0))
    (while (and a b (equal (car a) (car b)))
      (setq n (1+ n) a (cdr a) b (cdr b)))
    n))

(defun harness-provider--same-model-window (pid name)
  "Return (WINDOW . BASIS) of model NAME of PID as other listings size it, or nil.
The models of the same key (see `harness-provider-model-key') that a
provider sizes count, PID's own first; of several, the window most of
them have wins, and BASIS is the id of one that has it."
  (when-let* ((same (gethash (harness-provider-model-key name) (car (harness-provider--estimate-index)))))
    (let* ((mine (cl-remove-if-not
                  (lambda (cell) (equal (car (harness-provider-parse-model (cdr cell))) pid))
                  same))
           (pool (or mine same))
           (window (harness-provider--most-common (mapcar #'car pool))))
      (cons window (cdr (cl-find window pool :key #'car))))))

(defun harness-provider--closest-window (pid name)
  "Return (WINDOW . BASIS) of the models of PID closest to NAME by name, or nil.
Closest are those sharing the most leading words with NAME's key, two
at least, so \"claude-opus-5-6\" takes after \"claude-opus-5-5\" but
not after \"claude-haiku-4-5\".  Only models PID sizes count; of
several as close, the window most of them have wins, and BASIS is the
id of one that has it."
  (let ((words (harness-provider--key-words (harness-provider-model-key name)))
        (best 1) pool)
    (dolist (entry (gethash pid (cdr (harness-provider--estimate-index))))
      (let ((n (harness-provider--common-words words (car entry))))
        (cond ((> n best) (setq best n pool (list entry)))
              ((and (= n best) (> n 1)) (push entry pool)))))
    (when pool
      (let ((window (harness-provider--most-common (mapcar #'cadr pool))))
        (cons window (nth 2 (cl-find window pool :key #'cadr)))))))

(defun harness-provider--estimate (pid name)
  "Return (WINDOW . BASIS), the context window to assume for model NAME of PID.
BASIS says what the window comes from: the id of the same model at a
provider that sizes it (its own first, see
`harness-provider--same-model-window'), else of the model of PID
closest to it by name (see `harness-provider--closest-window'), else
\"PID's models\" for the window most of PID's models have, else
\"default\" for `harness-provider-fallback-context-window'."
  (or (harness-provider--same-model-window pid name)
      (harness-provider--closest-window pid name)
      (when-let* ((own (gethash pid (cdr (harness-provider--estimate-index)))))
        (cons (harness-provider--most-common (mapcar #'cadr own)) (format "%s's models" pid)))
      (cons harness-provider-fallback-context-window "default")))

(defun harness-provider--with-estimate (pid model)
  "Return MODEL of provider PID with a context window: its own, else an estimate.
An estimated window comes with `:context-window-estimated' t and
`:context-window-basis', what it was drawn from.  A window PID itself
flags as an estimate (one it guessed from the model's family, say)
gives way to the window the same model has where it is sized, or else
to that of PID's models closest to it by name; a broader estimate does
not replace it."
  (let* ((window (plist-get model :context-window))
         (name (plist-get model :name))
         (estimate (cond ((not (harness-provider--window-p window))
                          (harness-provider--estimate pid name))
                         ((plist-get model :context-window-estimated)
                          (or (harness-provider--same-model-window pid name)
                              (harness-provider--closest-window pid name))))))
    (if (not estimate)
        model
      (append (list :context-window (car estimate) :context-window-estimated t
                    :context-window-basis (cdr estimate))
              (harness-plist-remove model :context-window :context-window-estimated
                                    :context-window-basis)))))

(defun harness-provider--fill-windows (pid models)
  "Return MODELS of provider PID, each with a context window.
Models PID lists without a size get an estimate, and those it sizes by
an estimate of its own may get a better one (see
`harness-provider--with-estimate'); how many came without a size is
logged when that number changes."
  (let ((unsized 0))
    (prog1 (mapcar (lambda (m)
                     (unless (harness-provider--window-p (plist-get m :context-window))
                       (cl-incf unsized))
                     (harness-provider--with-estimate pid m))
                   models)
      (let ((key (list 'unsized pid)))
        (unless (eql unsized (gethash key harness-provider--warned 0))
          (puthash key unsized harness-provider--warned)
          (when (> unsized 0)
            (harness-log 'info "provider %s: %d of its %d models come without a context window; estimated"
                         pid unsized (length models))))))))

(defun harness-provider--listed-p (id)
  "Non-nil when the models of provider ID are cached; a failed listing counts."
  (not (eq (gethash id harness-provider--models-by-provider 'unlisted) 'unlisted)))

(defun harness-provider--forget (id)
  "Forget the cached models of provider ID, so the next lookup asks it again."
  (remhash id harness-provider--models-by-provider)
  (remhash id harness-provider--fetching)
  (harness-provider--rebuild-cache))

(defvar harness-provider--lifecycle (make-hash-table :test 'eq)
  "Provider id -> (:warm FN :close FN :resolve FN).
These are the hooks `harness-define-provider' got, kept beside the
provider records rather than in them, so records made before a reload
need no slots they lack.")

(cl-defun harness-define-provider (id &key label doc models complete fork quota capabilities tiers
                                      warm close resolve)
  "Register provider ID.
LABEL and DOC describe it.  MODELS is a function returning a promise of
model plists; one that takes an argument is passed non-nil when a
refresh asks (`provider/models'), so it can ask its source again rather
than answer from a cache.  A model without `:context-window' is one the
provider does not size: the catalogue gives it an estimate (see
`harness-provider--estimate').  COMPLETE takes a request plist and
returns a handle plist with `:cancel'.  FORK, when given, takes
\(MODEL-ID STATE) and returns a promise of a new provider state.  QUOTA
takes an optional REFRESH flag and returns a promise of billing and
quota information \(see `provider/quota').  CAPABILITIES is the static
capability plist.  TIERS names a model per user-facing tier (see
`harness-model-tiers' and `harness-provider-tier-model') so the harness
can pick a model on its own.  WARM, when given, takes a request plist
without messages and prepares what such a request will need, a process
say, so it answers sooner (`provider/warm'); CLOSE takes a session id
and frees what the provider keeps for it (`provider/close').  RESOLVE,
when given, takes a model NAME its listing lacks (an alias, a variant,
a model it knows another way) and the provider's listed models, and
returns a model plist for it or nil (see `provider/model').  Defining ID
again replaces it and forgets the models it listed, which it is asked
for again when needed; other providers' models stay cached."
  (puthash id (make-harness-provider :id id :label (or label (symbol-name id)) :doc doc
                                     :models-fn models :complete-fn complete
                                     :fork-fn fork :quota-fn quota
                                     :capabilities capabilities :tiers tiers)
           harness-providers)
  (puthash id (list :warm warm :close close :resolve resolve) harness-provider--lifecycle)
  (harness-provider--forget id)
  id)

(defun harness-provider--hook (id key)
  "Return provider ID's hook KEY (`:warm', `:close' or `:resolve'), or nil."
  (plist-get (gethash id harness-provider--lifecycle) key))

(defun harness-provider-get (id)
  "Return provider ID or nil."
  (gethash id harness-providers))

(defun harness-provider-unregister (id)
  "Remove provider ID from the registry and forget its models.
Return non-nil when a provider was registered under ID."
  (prog1 (and (gethash id harness-providers) t)
    (remhash id harness-providers)
    (remhash id harness-provider--lifecycle)
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
  "Fill defaults into MODEL from PROVIDER.
A window that is not a positive number goes: the model is one its
provider does not size, which the catalogue gives an estimate."
  (let* ((name (plist-get model :name))
         (pid (harness-provider-id provider))
         (m (copy-sequence model)))
    (setq m (plist-put m :provider pid))
    (setq m (plist-put m :id (or (plist-get m :id) (format "%s:%s" pid name))))
    (setq m (plist-put m :label (or (plist-get m :label) name)))
    (setq m (plist-put m :provider-label (harness-provider-label provider)))
    (unless (harness-provider--window-p (plist-get m :context-window))
      (setq m (harness-plist-remove m :context-window)))
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

(defun harness-provider--list (p refresh)
  "Call provider P's models function, passing REFRESH when it takes an argument."
  (let ((fn (harness-provider-models-fn p)))
    (if (and refresh (harness-provider--accepts-arg-p fn))
        (funcall fn t)
      (funcall fn))))

(defun harness-provider--fetch (p &optional lookup refresh)
  "Ask provider P for its models; return a promise settled once they are cached.
A listing still in flight is shared, not asked for again.  A provider
that lists its models at once (a static catalogue) has them cached
before this returns.  The promise resolves to non-nil when they were
cached; see `harness-provider--settle'.  LOOKUP non-nil means a lookup
asks: one answered at once is then announced from the command loop, so
the lookup calls no subscriber.  REFRESH non-nil is passed on to a
models function that takes it (see `harness-define-provider')."
  (let ((id (harness-provider-id p)))
    (or (gethash id harness-provider--fetching)
        (let ((listing (condition-case err
                           (harness-as-promise (harness-provider--list p refresh))
                         (error (harness-rejected err)))))
          (if (harness-promise-settled-p listing)
              (harness-resolved (harness-provider--settle p listing lookup))
            (puthash id (harness-then listing
                                      (lambda (_) (harness-provider--settle p listing))
                                      (lambda (_) (harness-provider--settle p listing)))
                     harness-provider--fetching))))))

(defun harness-provider-relist (id)
  "Have provider ID list its models again, as it knows more now.
A provider calls this when it learned something its listing should
show: a new list from its source, the window a model really has.  What
it lists is cached and announced as `provider/models-updated' (from
the command loop when it answers at once), and the windows sessions
show follow.  Return a promise like `harness-provider--fetch', or nil
when ID is not registered or lists nothing."
  (when-let* ((p (harness-provider-get id)))
    (when (harness-provider-models-fn p)
      (harness-provider--fetch p t))))

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
slow endpoint never hides a fast one; REFRESH forces a new query, and
is passed on to the providers whose models function takes it.  A
provider that fails is logged and skipped.  Every model has a
`:context-window'; one its provider does not size has an estimate,
flagged `:context-window-estimated' (see `harness-provider--estimate').
Only the models `harness-allowed-models' allows are listed."
  (cond
   ((and (not refresh) (harness-provider--complete-p))
    (harness-resolved (harness-provider--allowed harness-provider--models)))
   ((and harness-provider--models-promise (not refresh)
         (not (harness-promise-settled-p harness-provider--models-promise)))
    harness-provider--models-promise)
   (t
    (let (promises)
      (maphash (lambda (id p)
                 (when (and (harness-provider-models-fn p)
                            (or refresh (not (harness-provider--listed-p id))))
                   (push (harness-provider--fetch p nil refresh) promises)))
               harness-providers)
      (setq harness-provider--models-promise
            (harness-then (harness-all (nreverse promises))
                          (lambda (_) (harness-provider--allowed harness-provider--models))))))))

(defun harness-provider--resolve (p name)
  "Return what provider P's `:resolve' function says of model NAME, or nil.
It is passed NAME and P's listed models when it takes both.  A failure
is logged and counts as nothing said."
  (when-let* ((fn (harness-provider--hook (harness-provider-id p) :resolve)))
    (condition-case err
        (let ((m (if (harness-provider--accepts-args-p fn 2)
                     (funcall fn name (gethash (harness-provider-id p) harness-provider--catalogue))
                   (funcall fn name))))
          (and (consp m) m))
      (error (harness-log 'warn "provider %s: resolving %s failed: %s"
                          (harness-provider-id p) name (harness-error-message err))
             nil))))

(defun harness-provider--unlisted (model-id pid name p)
  "Return the model plist for MODEL-ID, NAME of PID, which no listing holds.
P is the provider, nil when none is registered.  What P's `:resolve'
says of NAME comes first; a window still missing is estimated, and an
estimate for a model of a provider that has listed its models is
logged once, as it may well be wrong."
  (let* ((resolved (and p (harness-provider--resolve p name)))
         (m (if p
                (harness-provider--normalise-model
                 p (append (list :id model-id :name name) (harness-plist-remove resolved :id :name)))
              (list :id model-id :provider pid :name name :label (or name "?")
                    :input-modalities '("text") :capabilities nil)))
         (m (harness-provider--with-estimate pid m)))
    (when (and (plist-get m :context-window-estimated)
               (or (null p) (harness-provider--listed-p pid))
               (not (gethash model-id harness-provider--warned)))
      (puthash model-id t harness-provider--warned)
      (harness-log 'warn "provider/model: %s is %s; assuming a context window of %d tokens (from %s)"
                   model-id (if p (format "not in %s's catalogue" pid) "of no registered provider")
                   (plist-get m :context-window) (plist-get m :context-window-basis)))
    m))

(harness-defmethod provider/model (model-id)
  "Return the model plist for MODEL-ID from the catalogue, or one made for it.
A provider whose models are not cached is asked for them first.  One
that lists them at once has them cached before this returns, so its
models are found from the first lookup.  A model no listing holds (one
a provider answering later has not listed yet, an alias, a model of a
provider that is gone) gets a plist made for it: from what its
provider's `:resolve' says of it, with an estimated context window
when that says no size (see `harness-provider--estimate'), never a
silent small one."
  (or (gethash model-id harness-provider--model-index)
      (gethash model-id harness-provider--lookups)
      (pcase-let* ((`(,pid . ,name) (harness-provider-parse-model model-id))
                   (p (and pid (harness-provider-get pid))))
        (or (and p (harness-provider-models-fn p)
                 (not (harness-provider--listed-p pid))
                 (progn (harness-provider--fetch p t)
                        (gethash model-id harness-provider--model-index)))
            (puthash model-id (harness-provider--unlisted model-id pid name p)
                     harness-provider--lookups)))))

(harness-defmethod provider/capabilities (model-id)
  "Return the capability plist for MODEL-ID."
  (plist-get (harness-call 'provider/model model-id) :capabilities))

;;;; Prompt cache lifetime

(defun harness-provider--seconds (value)
  "Return VALUE when it is a positive number of seconds, else nil."
  (and (numberp value) (> value 0) value))

(defun harness-provider-cache-ttl (model-id &optional reported)
  "Return the seconds MODEL-ID's provider keeps a prompt cache after its use.
REPORTED is the lifetime the provider reported for the request that
last used the cache, and wins when it is a positive number.  Else the
first entry of `harness-cache-ttl-overrides' matching MODEL-ID gives
it, else the `:cache-ttl' capability of the model or its provider,
else `harness-cache-ttl'."
  (or (harness-provider--seconds reported)
      (and (stringp model-id)
           (harness-provider--seconds
            (cdr (cl-find-if (lambda (entry)
                               (and (consp entry) (stringp (car entry))
                                    (condition-case nil (string-match-p (car entry) model-id)
                                      (invalid-regexp nil))))
                             harness-cache-ttl-overrides))))
      (and (stringp model-id)
           (harness-provider--seconds
            (condition-case err
                (plist-get (harness-call 'provider/capabilities model-id) :cache-ttl)
              (error (harness-log 'debug "provider: no cache lifetime for %s: %S" model-id err)
                     nil))))
      harness-cache-ttl))

(harness-defmethod provider/cache-ttl (model-id &optional reported)
  "Return the seconds MODEL-ID keeps a prompt cache after its use.
REPORTED is the lifetime the provider reported for the last request;
see `harness-provider-cache-ttl'."
  (harness-provider-cache-ttl model-id reported))

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
Nil means the provider has not answered yet, or listed nothing.  Each
has a context window, estimated where the provider gave none."
  (gethash id harness-provider--catalogue))

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

(defun harness-provider--provider-id (id)
  "Return the provider id (a symbol) that ID names, or nil.
ID is a model id \"PROVIDER:MODEL\", a provider id alone, as a symbol
or a string, or nil."
  (cond ((null id) nil)
        ((symbolp id) id)
        ((not (stringp id)) nil)
        ((string-match-p "\\`[a-z0-9_-]+\\'" id) (intern id))
        (t (car (harness-provider-parse-model id)))))

(defun harness-provider--listed-models (pid)
  "Return the cached models of provider PID, asking it first when unlisted.
A static catalogue answers at once; nil comes back until a provider that
answers later has, or for an unknown provider."
  (when-let* ((provider (and pid (harness-provider-get pid))))
    (when (and (harness-provider-models-fn provider)
               (not (harness-provider--listed-p pid)))
      (harness-provider--fetch provider t))
    (harness-provider--cached-models pid)))

(harness-defmethod provider/cached-models (provider-id)
  "Return the models PROVIDER-ID has listed, from the cache, without waiting.
PROVIDER-ID is a symbol or its name.  A provider not listed yet is
asked first; a static catalogue answers at once, so its models come
back, while one that answers later gives nil until it has.  Unlike
`provider/models', no other provider holds the answer up."
  (harness-provider--listed-models (harness-provider--provider-id provider-id)))

(defun harness-provider-tier-model (model-id &optional tier)
  "Return the id of the TIER model of MODEL-ID's provider, or nil.
MODEL-ID may also be a provider id alone (a symbol, or a string
without a colon).  TIER defaults to `cheap'.  The provider's `:tiers'
names a model (a name, id or regexp) for it; a tier it does not name,
and a provider that declares none, takes the provider's models sorted
by price \(`cheap' the least expensive, `frontier' the most, `balanced'
the middle).  Models whose cost is unknown are never chosen by price.  A
provider not listed yet is asked for its models, which a static
catalogue answers at once; nil comes back until one that answers later
has."
  (let* ((tier (harness-provider--tier tier))
         (pid (harness-provider--provider-id model-id))
         (provider (and pid (harness-provider-get pid))))
    (when provider
      (let* ((models (harness-provider--allowed (harness-provider--listed-models pid)))
             (model (and models
                         (or (harness-provider--tier-match
                              models (plist-get (harness-provider-tiers provider) tier))
                             (harness-provider--by-price models tier)))))
        (and model (plist-get model :id))))))

(harness-defmethod provider/tier-model (model-id &optional tier)
  "Return the id of the TIER model of MODEL-ID's provider, or nil.
MODEL-ID may be a provider id alone.  TIER defaults to `cheap'; see
`harness-provider-tier-model'."
  (harness-provider-tier-model model-id tier))

(defconst harness-provider--tier-precedence '(:balanced :frontier :cheap)
  "The tier a model takes when its provider names it for several.
A provider that names one model for its cheap and balanced tiers (as
DeepSeek names Flash) makes it its everyday model, so balanced comes
first; frontier before cheap, as the model is the better of the two.")

(defun harness-provider--names-model-p (matcher model)
  "Non-nil when tier MATCHER (a name, id or regexp) names MODEL."
  (when (and (stringp matcher) model)
    (let ((name (plist-get model :name)) (id (plist-get model :id)))
      (or (equal matcher name) (equal matcher id)
          (ignore-errors
            (or (and (stringp name) (string-match-p matcher name))
                (and (stringp id) (string-match-p matcher id))))))))

(defun harness-provider--price-tier (models model)
  "Return the tier MODEL's price places it in among MODELS, or nil.
The distinct prices of the priced MODELS are ranked: the cheapest third
is `:cheap', the dearest third `:frontier', the rest `:balanced'.  Nil
when MODEL has no price; `:balanced' when every model costs the same."
  (when-let* ((score (harness-provider--price-score model)))
    (let* ((scores (sort (delete-dups
                          (delq nil (mapcar (lambda (m)
                                              (when-let* ((s (harness-provider--price-score m))) (float s)))
                                            models)))
                         #'<))
           (n (length scores))
           (rank (or (cl-position (float score) scores :test #'=) 0)))
      (if (< n 2)
          :balanced
        (let ((f (/ (float rank) (1- n))))
          (cond ((< f (/ 1.0 3)) :cheap)
                ((> f (/ 2.0 3)) :frontier)
                (t :balanced)))))))

(defun harness-provider-model-tier (model-id)
  "Return the tier of MODEL-ID within its provider.
That is `:cheap', `:balanced' or `:frontier': the tier the provider's
`:tiers' names the model for (when it names it for several, the first
of `harness-provider--tier-precedence'), else where the model's price
places it in the provider's catalogue (see
`harness-provider--price-tier'), else `:balanced'.  This is the
inverse of `harness-provider-tier-model': together they map a model to
a model of similar ability at another provider."
  (let* ((pid (harness-provider--provider-id model-id))
         (provider (and pid (harness-provider-get pid)))
         (models (and provider (harness-provider--listed-models pid)))
         (model (and models (cl-find model-id models :key (lambda (m) (plist-get m :id)) :test #'equal)))
         (tiers (and provider (harness-provider-tiers provider))))
    (or (and model
             (cl-find-if (lambda (tier) (harness-provider--names-model-p (plist-get tiers tier) model))
                         harness-provider--tier-precedence))
        (and model (harness-provider--price-tier models model))
        :balanced)))

(harness-defmethod provider/model-tier (model-id)
  "Return the tier of MODEL-ID within its provider.
That is `cheap', `balanced' or `frontier': the keyword
`harness-provider-model-tier' returns, without its colon, so it reads
the same over the wire."
  (intern (string-remove-prefix ":" (symbol-name (harness-provider-model-tier model-id)))))

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
`:stop-reason' error, and so is a model `harness-allowed-models' does
not allow, which no provider is asked for."
  (pcase-let* ((`(,pid . ,_) (harness-provider-parse-model (plist-get request :model)))
               (provider (and pid (harness-provider-get pid)))
               (on-event (harness-provider--guard-events (or (plist-get request :on-event) #'ignore)))
               (request (plist-put (copy-sequence request) :on-event on-event))
               (refusal (harness-provider-model-refusal (plist-get request :model))))
    (cond
     (refusal
      (harness-log 'warn "provider/complete: %s" refusal)
      (funcall on-event (list :type 'done :stop-reason 'error :error refusal))
      (list :cancel #'ignore))
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

(harness-defmethod provider/warm (request)
  "Have REQUEST's provider get ready for a request like it; non-nil if it did.
REQUEST is shaped like `provider/complete''s, without messages or
`:on-event': its `:model' picks the provider, and its `:session',
`:system' and `:thinking' say what the coming request will be.  A
provider that keeps a process per session (the Claude CLI) starts it
now, so a request that comes later with the same settings is answered
sooner; one with nothing to prepare does nothing.  A failure is
logged, never signalled: warming is only ever a head start.  A model
`harness-allowed-models' does not allow is not warmed."
  (pcase-let* ((`(,pid . ,_) (harness-provider-parse-model (plist-get request :model)))
               (warm (and pid (harness-provider-get pid)
                          (harness-provider-model-allowed-p (plist-get request :model))
                          (harness-provider--hook pid :warm))))
    (when warm
      (condition-case err
          (and (funcall warm request) t)
        (error (harness-log 'warn "provider %s: warming up failed: %s" pid (harness-error-message err))
               nil)))))

(harness-defmethod provider/close (model-id session-id)
  "Have MODEL-ID's provider free what it keeps for SESSION-ID: a process, say.
Requests made under ids of their own, such as a one-off question's,
have no session whose deletion would free it.  Return non-nil when the
provider had something to free.  A failure is logged, never signalled."
  (pcase-let* ((`(,pid . ,_) (harness-provider-parse-model model-id))
               (close (and pid (harness-provider-get pid) (harness-provider--hook pid :close))))
    (when (and close session-id)
      (condition-case err
          (and (funcall close session-id) t)
        (error (harness-log 'warn "provider %s: closing %s failed: %s" pid session-id (harness-error-message err))
               nil)))))

(harness-defmethod provider/fork (model-id state &optional checkpoint)
  "Ask MODEL-ID's provider to fork provider STATE.
Return a promise of the new state, or of nil when unsupported.  With
CHECKPOINT, a `:checkpoint' the provider put on a node, the fork holds
the conversation as it was at that node and nothing after it; a
provider that cannot cut its conversation there, or does not know the
checkpoint (another provider made it), gives nil, and the conversation
then starts anew from the transcript."
  (pcase-let* ((`(,pid . ,_) (harness-provider-parse-model model-id))
               (provider (and pid (harness-provider-get pid)))
               (fn (and provider (harness-provider-fork-fn provider))))
    (cond
     ((null fn) (harness-resolved nil))
     ;; A fork function of two arguments cannot cut the conversation.
     ((and checkpoint (not (harness-provider--accepts-args-p fn 3))) (harness-resolved nil))
     (t (condition-case err
            (harness-then
             (harness-as-promise (if checkpoint
                                     (funcall fn model-id state checkpoint)
                                   (funcall fn model-id state)))
             (lambda (new) (harness-tag-provider-state new model-id)))
          (error (harness-rejected err)))))))

(defun harness-provider--accepts-args-p (fn n)
  "Non-nil when function FN can be called with N arguments."
  (let ((arity (func-arity fn)))
    (and (<= (car arity) n) (or (eq (cdr arity) 'many) (>= (cdr arity) n)))))

;;;; Replaying a transcript into a new conversation

(defconst harness-provider-history-block-limit 20000
  "Characters of one tool input or result kept when a transcript is replayed.")

(defconst harness-provider-history-limit 400000
  "Characters of transcript kept when it is replayed into a new conversation.
Past it, the oldest messages go, all but the first.")

(defun harness-provider-split-history (messages)
  "Split provider MESSAGES into (HISTORY . TRAILING).
TRAILING is the run of user messages at the end, what a hosted loop
sends as the new message; HISTORY is everything before it, which a
conversation that continues it already holds."
  (let ((rest (reverse messages)) trailing)
    (while (and rest (equal (format "%s" (plist-get (car rest) :role)) "user"))
      (push (pop rest) trailing))
    (cons (nreverse rest) trailing)))

(defun harness-provider--history-clip (text)
  "Return TEXT cut to `harness-provider-history-block-limit' characters."
  (let ((text (or text "")))
    (if (<= (length text) harness-provider-history-block-limit) text
      (concat (substring text 0 harness-provider-history-block-limit)
              (format "\n[… %d more characters]" (- (length text) harness-provider-history-block-limit))))))

(defun harness-provider--history-message (message names)
  "Render provider MESSAGE as transcript text, or nil when it shows nothing.
NAMES maps tool_use ids to tool names, for the results."
  (let* ((role (format "%s" (plist-get message :role)))
         (parts
          (delq nil
                (mapcar
                 (lambda (b)
                   (pcase (plist-get b :type)
                     ("text" (let ((text (plist-get b :text)))
                               (unless (harness-string-blank-p text) text)))
                     ("tool_use"
                      (format "<tool_call name=\"%s\">\n%s\n</tool_call>" (plist-get b :name)
                              (harness-provider--history-clip
                               (harness-json-encode-text (or (plist-get b :input) :empty)))))
                     ("tool_result"
                      (format "<tool_result name=\"%s\"%s>\n%s\n</tool_result>"
                              (or (gethash (plist-get b :tool_use_id) names) "tool")
                              (if (harness-json-true-p (plist-get b :is_error)) " error=\"true\"" "")
                              (harness-provider--history-clip
                               (let ((c (plist-get b :content)))
                                 (if (stringp c) c
                                   (mapconcat (lambda (x) (or (plist-get x :text) "")) c "\n"))))))
                     ("image" "[image]")
                     ("audio" "[audio]")
                     ("file" (format "[attached file: %s]" (plist-get b :path)))
                     ;; Thinking is the model's own and its signature is for
                     ;; the conversation it was written in.
                     (_ nil)))
                 (plist-get message :content)))))
    (when parts
      (format "<%s>\n%s\n</%s>" role (string-join parts "\n\n") role))))

(defun harness-provider-history-text (history)
  "Return provider messages HISTORY as one text a new conversation opens with.
Nil when HISTORY shows nothing.  A hosted-loop provider that has to
start a new conversation for a transcript that already has messages
sends this before the new message, so the model knows what was said:
its own conversation was cut before any checkpoint, could not be
resumed, or another provider ran the turns before.  Tool inputs and
results longer than `harness-provider-history-block-limit' are cut,
and past `harness-provider-history-limit' the oldest messages but the
first go."
  (let ((names (make-hash-table :test 'equal)))
    (dolist (m history)
      (dolist (b (plist-get m :content))
        (when (equal (plist-get b :type) "tool_use")
          (puthash (plist-get b :id) (plist-get b :name) names))))
    (let* ((rendered (delq nil (mapcar (lambda (m) (harness-provider--history-message m names)) history)))
           (size (apply #'+ (mapcar #'length rendered)))
           (dropped 0))
      (when rendered
        (while (and (> size harness-provider-history-limit) (cddr rendered))
          (cl-decf size (length (cadr rendered)))
          (setcdr rendered (cddr rendered))
          (cl-incf dropped))
        (concat
         "This conversation continues an earlier one, which is reproduced below so that you know what"
         " was said; you wrote its assistant messages and made its tool calls.  Carry on from where it"
         " ends: the message after it is the new one.\n\n<conversation_history>\n"
         (car rendered)
         (if (zerop dropped) "" (format "\n\n[… %d earlier messages omitted …]" dropped))
         (mapconcat (lambda (r) (concat "\n\n" r)) (cdr rendered) "")
         "\n</conversation_history>")))))

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
