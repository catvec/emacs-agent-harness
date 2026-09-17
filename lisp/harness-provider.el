;;; harness-provider.el --- Pluggable inference provider API -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Noah Huppert

;; Author: Noah Huppert <contact@noahh.io>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
;; URL: https://github.com/noahhuppert/emacs-agent-harness

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A provider is anything that can run an inference request and stream the
;; result back, and that can report stats (id, context window, price) about the
;; models it serves.  The OpenAI-compatible HTTP provider in
;; `harness-provider-openai' is the reference implementation; a provider that
;; shells out to a CLI and speaks JSON-RPC over stdio is equally first-class
;; (see `harness-provider-process' for the transport).
;;
;; Plugins implement the `cl-defgeneric's below on their own struct type and
;; register an instance with `harness-provider-register'; nothing else in the
;; harness knows what a provider is.  See DESIGN.md section 5.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)

(defcustom harness-providers nil
  "Configured inference providers.

Each element is a plist.  `:name' is a symbol identifying the provider,
`:kind' selects the implementing module (see `harness-provider-kinds') and the
rest is passed to that kind's constructor.  For the built-in OpenAI-compatible
kind:

  (:name local :kind openai :label \"LiteLLM\"
   :base-url \"http://127.0.0.1:4000/v1\"
   :api-key-env \"LITELLM_API_KEY\"
   :headers ((\"X-Team\" . \"infra\")))

`:api-key' may be given literally instead of `:api-key-env'."
  :type '(repeat plist)
  :group 'harness-providers)

(defcustom harness-models nil
  "Static model table, used for display, selection and cost accounting.

Each element is a plist:

  (:provider local :id \"deepseek-chat\" :label \"DeepSeek Chat\"
   :context-window 128000 :max-output 8192
   :price-in 0.27 :price-out 1.10
   :price-cache-read 0.07 :price-cache-write 0
   :capabilities (:tools t :reasoning t))

Prices are per million tokens.  A model with no prices simply reports tokens.
Models discovered by `harness-provider-models' fill in what is missing."
  :type '(repeat plist)
  :group 'harness-providers)

(defcustom harness-default-model nil
  "Model id used for new sessions.
May be nil, in which case `harness-select-model' asks the first time."
  :type '(choice (const :tag "Ask" nil) string)
  :group 'harness-providers)

(defcustom harness-default-provider nil
  "Provider name used when a model's provider cannot be determined.
Defaults to the first configured provider."
  :type '(choice (const :tag "First configured" nil) symbol)
  :group 'harness-providers)

(defcustom harness-system-prompt
  "You are a coding agent running inside Emacs.

You help with software engineering tasks in the user's current project.  Be
concise and direct.  Use the tools available to you to inspect and change
code rather than guessing.  Prefer small, reviewable changes and explain
anything the user could not have predicted.

The user sees your output in a plain text buffer, so use short paragraphs and
simple lists rather than elaborate markdown."
  "Base system prompt for every session.
`harness-system-prompt-functions' can append context (project files, git
status, editor state) to it."
  :type 'string
  :group 'harness-providers)

(defvar harness-system-prompt-functions nil
  "Abnormal hook run to build a session's system prompt.
Each function is called with the session and must return a string, which is
appended to `harness-system-prompt' as a new paragraph.  Returning nil is
allowed.  This is the supported way to inject context cheaply per request.")

(defcustom harness-temperature nil
  "Sampling temperature sent with requests, or nil to omit it."
  :type '(choice (const :tag "Provider default" nil) number)
  :group 'harness-providers)

(defcustom harness-max-tokens nil
  "Maximum output tokens sent with requests, or nil to omit it."
  :type '(choice (const :tag "Provider default" nil) integer)
  :group 'harness-providers)

(defcustom harness-model-cache-file
  (expand-file-name "agent-harness/models.json" user-emacs-directory)
  "Where models discovered from providers are cached, or nil to not cache."
  :type '(choice (const :tag "Do not cache" nil) file)
  :group 'harness-providers)


;;; Model stats

(cl-defstruct (harness-model-stats (:constructor harness--make-model-stats)
                                   (:copier nil))
  "What the harness knows about one model.

Prices are per million tokens in CURRENCY.  SOURCE is `static' (from
`harness-models'), `discovered' (from a provider) or `default'."
  (provider nil)
  (id nil)
  (label nil)
  (context-window nil)
  (max-output nil)
  (price-in nil)
  (price-out nil)
  (price-cache-read nil)
  (price-cache-write nil)
  (currency "USD")
  (caps nil)
  (source 'static))

(defvar harness--model-cache (make-hash-table :test 'equal)
  "Models discovered from providers, keyed by \"PROVIDER/ID\".")

(defun harness-model-stats (provider-id model-id)
  "Return `harness-model-stats' for MODEL-ID served by PROVIDER-ID.
Static configuration wins over discovered data; unknown models get a default
record with no prices so the rest of the harness never has to check."
  (let* ((key (format "%s/%s" provider-id model-id))
         (configured (cl-find-if
                      (lambda (spec)
                        (and (equal (harness-plist-or-alist-get :provider spec)
                                    provider-id)
                             (equal (harness-plist-or-alist-get :id spec) model-id)))
                      harness-models))
         (discovered (gethash key harness--model-cache))
         (merged (append configured discovered)))
    (if (null merged)
        (harness--make-model-stats :provider provider-id :id model-id
                                   :label model-id :source 'default)
      (harness--make-model-stats
       :provider provider-id
       :id model-id
       :label (or (harness-plist-or-alist-get :label merged) model-id)
       :context-window (harness-plist-or-alist-get :context-window merged)
       :max-output (harness-plist-or-alist-get :max-output merged)
       :price-in (harness-plist-or-alist-get :price-in merged)
       :price-out (harness-plist-or-alist-get :price-out merged)
       :price-cache-read (harness-plist-or-alist-get :price-cache-read merged)
       :price-cache-write (harness-plist-or-alist-get :price-cache-write merged)
       :currency (or (harness-plist-or-alist-get :currency merged) "USD")
       :caps (harness-plist-or-alist-get :capabilities merged)
       :source (if configured 'static 'discovered)))))

(defun harness-model-stats-price-p (stats)
  "Return non-nil when STATS carries usable pricing."
  (or (harness-model-stats-price-in stats)
      (harness-model-stats-price-out stats)))

(defun harness-usage-cost (usage stats)
  "Return the money spent by USAGE according to STATS.
USAGE is a plist with `:in', `:out', `:cache-read' and `:cache-write' token
counts.  Cached input tokens are billed at the cache price instead of the
input price."
  (if (not (harness-model-stats-price-p stats))
      0.0
    (let* ((in (or (plist-get usage :in) 0))
           (out (or (plist-get usage :out) 0))
           (cache-read (or (plist-get usage :cache-read) 0))
           (cache-write (or (plist-get usage :cache-write) 0))
           (fresh-in (max 0 (- in cache-read)))
           (per-million 1.0e-6))
      (+ (* fresh-in per-million (or (harness-model-stats-price-in stats) 0))
         (* cache-read per-million
            (or (harness-model-stats-price-cache-read stats)
                (harness-model-stats-price-in stats) 0))
         (* cache-write per-million (or (harness-model-stats-price-cache-write stats) 0))
         (* out per-million (or (harness-model-stats-price-out stats) 0))))))

(defun harness-model-stats-describe (stats)
  "Return a one line description of STATS for completion and tooltips."
  (concat (or (harness-model-stats-label stats)
              (harness-model-stats-id stats))
          (when-let* ((provider (harness-model-stats-provider stats)))
            (format " [%s]" provider))
          (when-let* ((window (harness-model-stats-context-window stats)))
            (format " %s ctx" (harness-format-count window)))
          (when (harness-model-stats-price-p stats)
            (format " %s/%s per Mtok"
                    (harness-format-cost (harness-model-stats-price-in stats))
                    (harness-format-cost (harness-model-stats-price-out stats))))))

(defun harness-model-cache-load ()
  "Load discovered models from `harness-model-cache-file'."
  (when (and harness-model-cache-file (file-readable-p harness-model-cache-file))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents harness-model-cache-file)
          (let ((data (harness-json-read (buffer-string))))
            (when (listp data)
              (clrhash harness--model-cache)
              (dolist (spec data)
                (puthash (format "%s/%s"
                                 (harness-plist-or-alist-get :provider spec)
                                 (harness-plist-or-alist-get :id spec))
                         spec harness--model-cache)))))
      (error (harness--log "could not read the model cache: %s"
                           (error-message-string err))))))

(defun harness-model-cache-save ()
  "Persist discovered models to `harness-model-cache-file'."
  (when harness-model-cache-file
    (condition-case err
        (let (specs)
          (maphash (lambda (_key spec) (push spec specs)) harness--model-cache)
          (make-directory (file-name-directory harness-model-cache-file) t)
          (let ((write-region-inhibit-fsync t))
            (with-temp-file harness-model-cache-file
              (insert (harness-json-write (nreverse specs) t)))))
      (error (harness--log "could not write the model cache: %s"
                           (error-message-string err))))))

(defun harness-refresh-models (&optional callback)
  "Asynchronously ask every provider for its model list.
CALLBACK is called with the number of models discovered, once every provider
has answered.  Never blocks."
  (interactive)
  (let* ((providers (harness-provider-all))
         (remaining (length providers))
         (total 0))
    (if (null providers)
        (when callback (funcall callback 0))
      (dolist (provider providers)
        (harness-provider-models
         provider
         (lambda (models)
           (dolist (spec models)
             (let ((key (format "%s/%s"
                                (harness-plist-or-alist-get :provider spec)
                                (harness-plist-or-alist-get :id spec))))
               (puthash key spec harness--model-cache)))
           (setq total (+ total (length models)))
           (when (<= (cl-decf remaining) 0)
             (harness-model-cache-save)
             (run-hooks 'harness-models-refreshed-hook)
             (when callback (funcall callback total)))))))))

(defvar harness-models-refreshed-hook nil
  "Hook run after `harness-refresh-models' finishes.")

(defun harness-model-search (&optional predicate)
  "Return every known model as `harness-model-stats', newest source last.
PREDICATE, when non-nil, filters on the stats record."
  (let (models)
    (dolist (spec harness-models)
      (let ((stats (harness-model-stats
                    (harness-plist-or-alist-get :provider spec)
                    (harness-plist-or-alist-get :id spec))))
        (when (or (null predicate) (funcall predicate stats))
          (push stats models))))
    (maphash (lambda (_key spec)
               (let ((stats (harness-model-stats
                             (harness-plist-or-alist-get :provider spec)
                             (harness-plist-or-alist-get :id spec))))
                 (when (and (eq (harness-model-stats-source stats) 'discovered)
                            (or (null predicate) (funcall predicate stats)))
                   (push stats models))))
             harness--model-cache)
    (sort (delete-dups models)
          (lambda (a b) (string-lessp (harness-model-stats-id a)
                                      (harness-model-stats-id b))))))


;;; Provider objects

(cl-defstruct (harness-provider (:constructor harness--make-provider)
                                (:copier nil))
  "Base configuration shared by every provider.

Plugin providers use `:include' to inherit these slots, or define a struct of
their own and implement the generics below from scratch."
  (name nil)
  (kind nil)
  (label nil)
  (base-url nil)
  (api-key nil)
  (api-key-env nil)
  (headers nil)
  (caps nil)
  (options nil))

(cl-defgeneric harness-provider-capabilities (provider)
  "Return a plist describing what PROVIDER supports.

Recognised keys: `:streaming', `:tools', `:reasoning', `:images',
`:usage-in-stream' and `:system-role' (the role name used for the system
prompt, default `system').  Unsupported features degrade gracefully: the
agent loop renders tool results as text for a provider without `:tools'.")

(cl-defmethod harness-provider-capabilities ((provider harness-provider))
  "Default capabilities: streaming text, no tools, no reasoning.
Provider-specific capabilities come first so that they win."
  (append (harness-provider-caps provider)
          '(:streaming t :tools nil :reasoning nil :images nil
            :usage-in-stream nil :system-role system)))

(cl-defgeneric harness-provider-chat (provider request callbacks)
  "Start an inference request on PROVIDER.

REQUEST is a `harness-provider-request'.  CALLBACKS is a plist of closures:
`:on-delta' (kind text), `:on-tool-call' (index tool-call), `:on-usage'
(plist), `:on-done' (finish-reason usage) and `:on-error' (error-symbol
message).  Return an opaque handle suitable for `harness-provider-cancel'.
Must return without blocking; implementations must call exactly one of
`:on-done' or `:on-error' unless cancelled.")

(cl-defgeneric harness-provider-cancel (provider handle)
  "Abandon an in-flight request started by `harness-provider-chat'.")

(cl-defgeneric harness-provider-models (provider callback)
  "Report the models PROVIDER serves by calling CALLBACK with a list.
Each element is a plist in the shape of `harness-models' entries.  This must
be asynchronous; call CALLBACK with nil when discovery is impossible.")

(defvar harness-provider-kinds (make-hash-table :test 'eq)
  "Registry mapping a `:kind' symbol to a constructor function.
The constructor receives the provider's configuration plist and returns a
provider object.  `harness-provider-openai' registers `openai'.")

(defun harness-register-provider-kind (kind constructor)
  "Register CONSTRUCTOR as the implementation of providers of KIND.

A plugin calls this with its kind symbol and a function that turns a provider
configuration plist into a provider object."
  (puthash kind constructor harness-provider-kinds)
  kind)

(defun harness-provider-kind-registered-p (kind)
  "Return non-nil when KIND has a registered constructor."
  (gethash kind harness-provider-kinds))

(defvar harness--providers (make-hash-table :test 'eq)
  "Live provider objects keyed by name.")

(defun harness-provider-register (provider)
  "Add PROVIDER to the registry, replacing any provider with the same name."
  (puthash (harness-provider-name provider) provider harness--providers)
  provider)

(defun harness-provider-get (name)
  "Return the provider named NAME, or nil."
  (gethash name harness--providers))

(defun harness-provider-all ()
  "Return every registered provider, in configuration order."
  (let (providers)
    (dolist (spec harness-providers)
      (let ((provider (harness-provider-get
                       (harness-plist-or-alist-get :name spec))))
        (when provider (push provider providers))))
    (nreverse providers)))

(defun harness-provider-resolve-api-key (provider)
  "Return PROVIDER's API key, reading the environment when configured that way."
  (or (harness-provider-api-key provider)
      (when-let* ((variable (harness-provider-api-key-env provider)))
        (getenv (if (symbolp variable) (symbol-name variable) variable)))))

(defun harness-provider-default ()
  "Return the default provider, or the first configured one."
  (or (and harness-default-provider
           (harness-provider-get harness-default-provider))
      (car (harness-provider-all))))

(defun harness-provider-for-model (model-id)
  "Return the provider that serves MODEL-ID."
  (or (when model-id
        (let ((spec (cl-find-if
                     (lambda (spec)
                       (equal (harness-plist-or-alist-get :id spec) model-id))
                     harness-models)))
          (when spec
            (harness-provider-get (harness-plist-or-alist-get :provider spec)))))
      (harness-provider-default)))

(defun harness-provider-setup ()
  "Instantiate the providers in `harness-providers' and load the model cache.
Called by `harness-setup'; safe to call repeatedly."
  (clrhash harness--providers)
  (dolist (spec harness-providers)
    (let* ((kind (or (harness-plist-or-alist-get :kind spec) 'openai))
           (constructor (gethash kind harness-provider-kinds)))
      (cond
       (constructor
        (condition-case err
            (harness-provider-register (funcall constructor spec))
          (error (harness--log "provider %s (%s) failed to load: %s"
                               (harness-plist-or-alist-get :name spec) kind
                               (error-message-string err)))))
       (t (harness--log "no provider kind registered for %s" kind)))))
  (harness-model-cache-load))


;;; Requests

(cl-defstruct (harness-provider-request (:constructor harness-provider--make-request)
                                        (:copier nil))
  "One inference request.

MESSAGES is the transcript as `harness-message' structs; each provider
converts them to its own wire format.  SYSTEM is the system prompt string."
  (model nil)
  (messages nil)
  (system nil)
  (tools nil)
  (temperature nil)
  (max-tokens nil)
  (stream t)
  (metadata nil))

(defun harness-provider-system-prompt (session)
  "Return SESSION's system prompt, running `harness-system-prompt-functions'."
  (let ((parts (list harness-system-prompt)))
    (dolist (function harness-system-prompt-functions)
      (condition-case err
          (let ((extra (funcall function session)))
            (when (and (stringp extra) (not (string-empty-p extra)))
              (push extra parts)))
        (error (harness--log "system prompt function %s failed: %s"
                             function (error-message-string err)))))
    (string-join (nreverse parts) "\n\n")))

(cl-defun harness-provider-build-request (session &key messages tools system)
  "Build a `harness-provider-request' for SESSION.

MESSAGES defaults to the session transcript, TOOLS to the registered tool
specifications (the caller passes them so this module does not depend on
`harness-tools'), and SYSTEM to the assembled system prompt."
  (harness-provider--make-request
   :model (harness-session-model session)
   :messages (or messages (harness-session-messages session))
   :system (or system (harness-provider-system-prompt session))
   :tools tools
   :temperature harness-temperature
   :max-tokens harness-max-tokens
   :stream t))

(defun harness-provider--once (callbacks)
  "Return CALLBACKS guarded so terminal callbacks run at most once.
Providers are allowed to be sloppy; the agent loop must not be."
  (let ((finished nil))
    (list :on-delta (plist-get callbacks :on-delta)
          :on-tool-call (plist-get callbacks :on-tool-call)
          :on-usage (plist-get callbacks :on-usage)
          :on-done (let ((fn (plist-get callbacks :on-done)))
                     (lambda (&rest args)
                       (unless finished
                         (setq finished t)
                         (when fn (apply fn args)))))
          :on-error (let ((fn (plist-get callbacks :on-error)))
                      (lambda (&rest args)
                        (unless finished
                          (setq finished t)
                          (when fn (apply fn args))))))))

(defun harness-provider-chat-async (session callbacks &optional request-args)
  "Start a chat request for SESSION, reporting through CALLBACKS.

CALLBACKS is as in `harness-provider-chat'.  REQUEST-ARGS may override parts
of the request (`:messages', `:tools', `:system').  Returns a handle for
`harness-provider-cancel-handle', or nil when no provider or model is
configured (in which case `:on-error' is called immediately)."
  (let* ((model (harness-session-model session))
         (provider (or (and (harness-session-provider session)
                            (harness-provider-get (harness-session-provider session)))
                       (harness-provider-for-model model))))
    (cond
     ((null provider)
      (when-let* ((fn (plist-get callbacks :on-error)))
        (funcall fn 'harness-no-provider
                 "No inference provider is configured; set `harness-providers'"))
      nil)
     ((null model)
      (when-let* ((fn (plist-get callbacks :on-error)))
        (funcall fn 'harness-no-model
                 "No model selected; run M-x harness-select-model"))
      nil)
     (t
      (setf (harness-session-provider session) (harness-provider-name provider))
      (cons provider
            (harness-provider-chat
             provider
             (harness-provider-build-request
              session
              :messages (plist-get request-args :messages)
              :tools (plist-get request-args :tools)
              :system (plist-get request-args :system))
             (harness-provider--once callbacks)))))))

(defun harness-provider-cancel-handle (handle)
  "Cancel HANDLE, which came from `harness-provider-chat'.
Handles are `(PROVIDER . INNER)'; nil is ignored."
  (when (consp handle)
    (harness-provider-cancel (car handle) (cdr handle))))

(provide 'harness-provider)
;;; harness-provider.el ends here
