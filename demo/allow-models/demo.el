;;; demo.el --- Show a provider narrowing itself with :allow-models  -*- lexical-binding: t; -*-

;;; Commentary:

;; Shows what one endpoint's `:allow-models' does, from the outside: what
;; the catalogue lists, what a tier picks, what a lookup finds, and what a
;; request for a model left out is told.  Everything here goes through the
;; calls a client makes -- `provider/models', `provider/model',
;; `provider/tier-model', `provider/complete' -- so it shows the surfaces
;; reading one narrowed set, not the filter function.
;;
;; Four providers, all made up, so nothing leaves the machine:
;;
;;   openrouter  three hundred models, narrowed to two globs.  This is the
;;               motivating case: an operator who wants three of
;;               OpenRouter's several hundred, without a harness-wide
;;               allowlist that would constrain every other provider.
;;   gemini      the same provider, unnarrowed, to show the narrowing is
;;               that provider's own: its models all stay listed.
;;   broken      a pattern that matches none of its models.  It offers
;;               nothing, the log says once which pattern did it, and the
;;               picker is told there is no model rather than being left
;;               with a provider that looks broken.
;;   static      a provider whose models are a fixed list rather than a
;;               /models route, narrowed the same way.
;;
;; It also prints what a request for a model left out is refused with, and
;; that nothing reached the provider's transport, and it shows the two
;; allowlists together: a model must pass its provider's own and
;; `harness-allowed-models' alike, and neither widens the other.
;;
;; Run it with demo/allow-models/demo.sh.  It sends no request to any
;; server, needs no credential, and sets no policy.

;;; Code:

(add-to-list 'load-path (expand-file-name "../../lisp"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(add-to-list 'load-path (expand-file-name "../../lisp/modules"
                                         (file-name-directory
                                          (or load-file-name buffer-file-name))))
(require 'cl-lib)
(require 'harness-core)
(require 'harness-provider)

(defconst demo-openrouter-models
  (append (mapcar (lambda (n) (format "deepseek/deepseek-v4.1-flash-%s" n))
                  '("20261017" "20260910" "1017"))
          (mapcar (lambda (n) (format "qwen/qwen3-coder-%s" n)) '("480b" "32b" "7b"))
          (mapcar (lambda (n) (format "meta-llama/llama-4-maverick-%s" n))
                  '("128e" "17b-128e"))
          (mapcar (lambda (n) (format "google/gemini-2.5-pro-%s" n)) '("preview" "stable"))
          (mapcar (lambda (n) (format "mistralai/mistral-large-%s" n)) '("2411" "2501")))
  "Model names the demo's openrouter provider lists, standing in for its hundreds.")

(defconst demo-gemini-models '("gemini-2.5-pro" "gemini-2.5-flash" "gemini-2.0-flash")
  "Model names the demo's gemini provider lists, so the narrowing shows as one provider's.")

(defun demo-models (names)
  "Return a models function listing NAMES, each with a window and a price.
The price rises with the name's length, so a price-ranked tier has an
order to find and the demo can show a tier picking inside the narrowed
set rather than outside it."
  (lambda ()
    (harness-resolved
     (mapcar (lambda (name)
               (list :name name
                     :context-window 128000
                     :pricing (list :input (/ (float (length name)) 100)
                                    :output (/ (float (length name)) 50))))
             names))))

(defun demo-register ()
  "Register the demo's four providers."
  ;; The motivating case: two globs, one of them by id and one by family.
  (harness-define-provider 'openrouter
    :label "OpenRouter (three models)"
    :allow-models '("openrouter:deepseek/deepseek-v4.1-flash-20261017"
                    "openrouter:qwen/*")
    :models (demo-models demo-openrouter-models))
  ;; The same kind of provider without the key: every model stays listed.
  (harness-define-provider 'gemini
    :label "Gemini (every model)"
    :models (demo-models demo-gemini-models))
  ;; A pattern that matches none of what it lists.
  (harness-define-provider 'broken
    :label "Broken (matches nothing)"
    :allow-models '("broken:nothing-*")
    :models (demo-models '("a-model" "another-model")))
  ;; A fixed list rather than a /models route.
  (harness-define-provider 'static
    :label "Static (fixed list)"
    :allow-models '("static:qwen*")
    :models (demo-models '("qwen-3" "qwen-4" "llama-4"))))

(defun demo-ids (models)
  "Return the ids of MODELS, the model plists of a listing."
  (mapcar (lambda (m) (plist-get m :id)) models))

(defun demo-say (format-string &rest args)
  "Print a line of the demo, FORMAT-STRING with ARGS."
  (princ (apply #'format format-string args))
  (princ "\n"))

(defun demo-heading (text)
  "Print TEXT as a heading of the demo."
  (princ "\n")
  (demo-say "== %s" text)
  (demo-say "%s" (make-string (+ 3 (length text)) ?-)))

(defun demo-refusal (model-id)
  "Return what the harness refuses MODEL-ID with, or nil when it offers it."
  (harness-provider-model-refusal model-id))

(defun demo-run ()
  "Register the demo's providers and print what the narrowing decides."
  (demo-register)
  (demo-heading "The provider narrows itself")
  (demo-say "openrouter lists %d models and offers %d of them:"
            (length demo-openrouter-models)
            (length (harness-provider--offered
                     (harness-provider-get 'openrouter)
                     (mapcar (lambda (name) (list :id (format "openrouter:%s" name)))
                             demo-openrouter-models))))
  (demo-say "  :allow-models %S"
            (harness-provider-allow-models (harness-provider-get 'openrouter)))
  (demo-say "  left out: %s"
            (mapconcat #'identity
                       (seq-take (seq-difference
                                  (mapcar (lambda (name) (format "openrouter:%s" name))
                                          demo-openrouter-models)
                                  (demo-ids (harness-await (harness-call 'provider/models))))
                                6)
                       ", "))
  (demo-say "  ... and the rest of the %d" (length demo-openrouter-models))

  (demo-heading "The catalogue every surface reads")
  (demo-say "provider/models: %s"
            (mapconcat #'identity
                       (demo-ids (harness-await (harness-call 'provider/models)))
                       "\n                 "))

  (demo-heading "It narrows that provider only")
  (demo-say "gemini, which names no patterns, still lists all %d:"
            (length demo-gemini-models))
  (demo-say "  %s"
            (mapconcat #'identity
                       (seq-filter (lambda (id) (string-prefix-p "gemini:" id))
                                   (demo-ids (harness-await (harness-call 'provider/models))))
                       ", "))

  (demo-heading "A static listing is narrowed the same way")
  (demo-say "static lists qwen-3, qwen-4 and llama-4, offers %s"
            (mapconcat #'identity
                       (seq-filter (lambda (id) (string-prefix-p "static:" id))
                                   (demo-ids (harness-await (harness-call 'provider/models))))
                       ", "))

  (demo-heading "A pattern that matches nothing offers nothing")
  (demo-say "broken's models: %S"
            (harness-call 'provider/cached-models 'broken))
  (demo-say "broken's tier:     %S"
            (harness-call 'provider/tier-model-info "broken" :simple))

  (demo-heading "A tier picks inside the narrowed set")
  (dolist (tier '(:simple :frontier))
    (demo-say "openrouter %s: %s" tier
              (harness-call 'provider/tier-model "openrouter" tier)))
  (demo-say "The prices are made up and rise with the name's length, so the
cheapest model of the whole listing (deepseek-v4.1-flash-1017) and its
dearest (llama-4-maverick-17b-128e) are both left out: a price-ranked
tier can only pick from the four the endpoint offers.")

  (demo-heading "A request for a model left out is refused, not sent")
  (let ((sent nil))
    (cl-letf (((symbol-function 'harness-provider--complete-send)
               (lambda (&rest _) (setq sent t) nil)))
      (let ((events nil))
        (harness-call 'provider/complete
                      (list :model "openrouter:meta-llama/llama-4-maverick-128e"
                            :on-event (lambda (e) (push e events))))
        (demo-say "refused: %s" (plist-get (car events) :error))
        (demo-say "reached the provider's transport: %s" (if sent "yes" "no")))))

  (demo-heading "Both allowlists apply, and neither widens the other")
  (let ((harness-allowed-models '("openrouter:qwen/*" "gemini")))
    (demo-say "harness-allowed-models: %S" harness-allowed-models)
    (demo-say "catalogue: %s"
              (mapconcat #'identity
                         (demo-ids (harness-await (harness-call 'provider/models)))
                         ", "))
    (demo-say "openrouter:qwen/qwen3-coder-480b -> %s"
              (or (demo-refusal "openrouter:qwen/qwen3-coder-480b") "offered"))
    (demo-say "openrouter:deepseek/deepseek-v4.1-flash-20261017 -> %s"
              (or (demo-refusal "openrouter:deepseek/deepseek-v4.1-flash-20261017")
                  "offered"))
    (demo-say "gemini:gemini-2.5-flash -> %s"
              (or (demo-refusal "gemini:gemini-2.5-flash") "offered")))
  (demo-say "\nThe provider offers the deepseek model, but the global list does
not, so the global one refuses it.  The global list allowing every
openrouter model would still leave the endpoint's own narrowing in
force, which the first section shows.")

  (demo-heading "One pattern, several, and none at all")
  (dolist (case '(("none" . nil)
                  ("one" . ("openrouter:qwen/qwen3-coder-32b"))
                  ("several" . ("openrouter:qwen/*" "openrouter:google/*"))
                  ("the provider's name" . ("openrouter"))))
    (harness-define-provider 'openrouter
      :label "OpenRouter"
      :allow-models (cdr case)
      :models (demo-models demo-openrouter-models))
    (demo-say "%-22s offers %d" (car case)
              (length (harness-call 'provider/cached-models 'openrouter))))
  (demo-say "\nNo patterns offers every model the provider lists: the key is a
narrowing, never a widening.")

  (demo-heading "What the endpoint editor shows")
  (demo-say "Allowed models -- the key's label")
  (demo-say "Provider, model or pattern -- a pattern's label, as the global
option labels one")
  (demo-say "The key's description is a setting description, the one place the
copy rule allows prose."))

(provide 'demo)
;;; demo.el ends here
