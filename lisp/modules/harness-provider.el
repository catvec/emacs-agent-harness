;;; harness-provider.el --- Completion provider contract and registry  -*- lexical-binding: t; -*-

;;; Commentary:

;; A provider turns a request into a stream of events (see
;; docs/architecture.md, "provider").  This module holds the registry,
;; the model catalogue and the small amount of glue that keeps every
;; provider honest: a request always ends with exactly one `done'
;; event, and callbacks never see each other's errors.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)

(defcustom harness-default-model "claude:claude-fable-5-1"
  "Model used when nothing more specific is configured, as PROVIDER:NAME."
  :type 'string :group 'harness)

(cl-defstruct (harness-provider (:copier nil))
  id label doc models-fn complete-fn fork-fn quota-fn capabilities)

(defvar harness-providers (make-hash-table :test 'eq)
  "Provider id -> `harness-provider'.")

(cl-defun harness-define-provider (id &key label doc models complete fork quota capabilities)
  "Register provider ID.
LABEL and DOC describe it.  MODELS is a function returning a promise of
model plists.  COMPLETE takes a request plist and returns a handle
plist with `:cancel'.  FORK, when given, takes (MODEL-ID STATE) and
returns a promise of a new provider state.  QUOTA takes an optional
REFRESH flag and returns a promise of billing and quota information
\(see `provider/quota').  CAPABILITIES is the static capability plist."
  (puthash id (make-harness-provider :id id :label (or label (symbol-name id)) :doc doc
                                     :models-fn models :complete-fn complete
                                     :fork-fn fork :quota-fn quota
                                     :capabilities capabilities)
           harness-providers)
  (setq harness-provider--models nil)
  (when (boundp 'harness-provider--models-by-provider)
    (remhash id harness-provider--models-by-provider))
  id)

(defun harness-provider-get (id)
  "Return provider ID or nil."
  (gethash id harness-providers))

(defun harness-provider-parse-model (model-id)
  "Split MODEL-ID \"provider:name\" into (PROVIDER-SYMBOL . NAME)."
  (if (and model-id (string-match "\\`\\([a-z0-9_-]+\\):\\(.+\\)\\'" model-id))
      (cons (intern (match-string 1 model-id)) (match-string 2 model-id))
    (cons nil model-id)))

(defvar harness-provider--models nil "Cached list of model plists, or nil.")
(defvar harness-provider--models-promise nil "In-flight refresh, if any.")

(harness-defmethod provider/list ()
  "Return registered providers as (:id :label :doc :capabilities) plists."
  (let (out)
    (maphash (lambda (id p)
               (push (list :id id :label (harness-provider-label p)
                           :doc (harness-provider-doc p)
                           :capabilities (harness-provider-capabilities p))
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

(defvar harness-provider--models-by-provider (make-hash-table :test 'eq)
  "Provider id -> its normalised model list, filled as each provider answers.")

(defun harness-provider--rebuild-cache ()
  (let (all)
    (maphash (lambda (_ models) (setq all (append all models))) harness-provider--models-by-provider)
    (setq harness-provider--models all)))

(harness-defmethod provider/models (&optional refresh)
  "Return a promise of every model from every provider.
Results are cached per provider as soon as that provider answers, so a
slow endpoint never hides a fast one; REFRESH forces a new query.  A
provider that fails is logged and skipped."
  (cond
   ((and harness-provider--models (not refresh)
         (= (hash-table-count harness-provider--models-by-provider) (hash-table-count harness-providers)))
    (harness-resolved harness-provider--models))
   ((and harness-provider--models-promise (not refresh)
         (not (harness-promise-settled-p harness-provider--models-promise)))
    harness-provider--models-promise)
   (t
    (let (promises)
      (maphash (lambda (id p)
                 (when (harness-provider-models-fn p)
                   (push (harness-then
                          (condition-case err
                              (harness-as-promise (funcall (harness-provider-models-fn p)))
                            (error (harness-rejected err)))
                          (lambda (models)
                            (puthash id (mapcar (lambda (m) (harness-provider--normalise-model p m)) models)
                                     harness-provider--models-by-provider)
                            (harness-provider--rebuild-cache)
                            (harness-emit 'provider/models-updated harness-provider--models)
                            t)
                          (lambda (e)
                            (harness-log 'warn "provider %s: listing models failed: %s"
                                         id (harness-error-message e))
                            (unless (gethash id harness-provider--models-by-provider)
                              (puthash id nil harness-provider--models-by-provider))
                            nil))
                         promises)))
               harness-providers)
      (setq harness-provider--models-promise
            (harness-then (harness-all (nreverse promises))
                          (lambda (_) harness-provider--models)))))))

(harness-defmethod provider/model (model-id)
  "Return the model plist for MODEL-ID from the cache, or a minimal one."
  (or (cl-find model-id harness-provider--models :key (lambda (m) (plist-get m :id)) :test #'equal)
      (pcase-let ((`(,pid . ,name) (harness-provider-parse-model model-id)))
        (let ((p (and pid (harness-provider-get pid))))
          (if p
              (harness-provider--normalise-model p (list :name name))
            (list :id model-id :provider pid :name name :label (or name "?")
                  :context-window 128000 :input-modalities '("text") :capabilities nil))))))

(harness-defmethod provider/capabilities (model-id)
  "Return the capability plist for MODEL-ID."
  (plist-get (harness-call 'provider/model model-id) :capabilities))

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
Return a promise of the new state, or of nil when unsupported."
  (pcase-let* ((`(,pid . ,_) (harness-provider-parse-model model-id))
               (provider (and pid (harness-provider-get pid))))
    (if (and provider (harness-provider-fork-fn provider))
        (condition-case err
            (harness-as-promise (funcall (harness-provider-fork-fn provider) model-id state))
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

(harness-declare-event 'provider/models-updated "(MODELS) after the catalogue refreshes.")
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
