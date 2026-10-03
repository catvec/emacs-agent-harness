;;; harness-provider-deepseek.el --- DeepSeek provider with peak pricing  -*- lexical-binding: t; -*-

;;; Commentary:

;; DeepSeek speaks the OpenAI chat completions API, so the streaming and
;; the tool loop come from harness-provider-openai.el with `:flavor
;; deepseek'.  What this module adds is registration and money.
;;
;; Registration follows the API key: the provider is created when
;; `harness-deepseek-api-key', DEEPSEEK_API_KEY or auth-source yields a
;; key, and removed again when none is found, so the model picker never
;; offers models that cannot be called.  Set
;; `harness-deepseek-always-register' to keep it regardless.
;;
;; DeepSeek prices by the clock.  Peak hours are 01:00-04:00 and
;; 06:00-10:00 UTC, Monday to Friday, excluding Chinese public holidays;
;; every other hour is off-peak.  Off-peak is exactly half of peak.
;; Off-peak it bills cached input, cache-miss input and output
;; separately, and does not charge for writing the cache.  The catalogue
;; therefore carries both tiers, `:pricing' (off-peak) and
;; `:peak-pricing', and `harness-deepseek-rates-at' picks between them so
;; `usage/price' records the cost that was actually incurred.  When peak
;; pricing applies, the session is told once per peak window, as a hint,
;; so a user can choose to wait; nothing is blocked.
;;
;; The legacy model names deepseek-v4-flash and
;; deepseek-v4-flash-vision-exp are still accepted and are served by
;; DeepSeek-V4.1-Flash at the Flash price, so they are listed too.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-provider)
(require 'harness-provider-openai)

;;;; Customisation

(defun harness-deepseek--custom-set (symbol value)
  "Set SYMBOL to VALUE and refresh the provider registration."
  (set-default symbol value)
  (when (fboundp 'harness-deepseek-refresh)
    (harness-deepseek-refresh)))

(defcustom harness-deepseek-api-key nil
  "DeepSeek API key.
When nil the DEEPSEEK_API_KEY environment variable and then auth-source
\(host api.deepseek.com, user \"apikey\") are consulted.  Its value never
leaves the harness."
  :type '(choice (const :tag "None" nil) (string :tag "Key"))
  :set #'harness-deepseek--custom-set :group 'harness)

(defcustom harness-deepseek-base-url "https://api.deepseek.com"
  "Base URL of the DeepSeek OpenAI-compatible API."
  :type 'string :set #'harness-deepseek--custom-set :group 'harness)

(defcustom harness-deepseek-always-register nil
  "Register the DeepSeek provider even when no API key is configured.
nil (the default) registers it only once a key is found, so the model
picker does not offer models that cannot be called."
  :type 'boolean :set #'harness-deepseek--custom-set :group 'harness)

(defcustom harness-deepseek-warn-on-peak t
  "Whether to hint in a session when DeepSeek peak pricing applies.
The hint is added once per peak window per session; it never blocks."
  :type 'boolean :group 'harness)

(defcustom harness-deepseek-pricing
  '((flash :off-peak (:input 0.15 :output 0.60 :cache-read 0.003 :cache-write 0.0)
           :peak     (:input 0.30 :output 1.20 :cache-read 0.006 :cache-write 0.0))
    (pro   :off-peak (:input 0.66 :output 1.98 :cache-read 0.022 :cache-write 0.0)
           :peak     (:input 1.32 :output 3.96 :cache-read 0.044 :cache-write 0.0)))
  "DeepSeek rates in USD per million tokens, by tier.
Each entry is (TIER :off-peak PLIST :peak PLIST); a model names its
tier.  DeepSeek changes these from time to time, so update them from
https://api-docs.deepseek.com/quick_start/pricing when it does."
  :type '(alist :key-type symbol :value-type sexp)
  :set #'harness-deepseek--custom-set :group 'harness)

(defcustom harness-deepseek-peak-windows '((1 . 4) (6 . 10))
  "DeepSeek's peak windows in UTC, as half-open (START . END) hours.
A window runs from START:00 up to but not including END:00, Monday to
Friday.  Everything else is off-peak, including all weekend."
  :type '(repeat (cons (integer 0 23) (integer 1 24))) :group 'harness)

(defcustom harness-deepseek-off-peak-dates
  ;; Chinese public holidays, which DeepSeek bills as off-peak all day.
  '("2026-01-01" "2026-01-02" "2026-01-03"
    "2026-02-15" "2026-02-16" "2026-02-17" "2026-02-18" "2026-02-19" "2026-02-20"
    "2026-02-21" "2026-02-22" "2026-02-23"
    "2026-04-04" "2026-04-05" "2026-04-06"
    "2026-05-01" "2026-05-02" "2026-05-03" "2026-05-04" "2026-05-05"
    "2026-06-19" "2026-06-20" "2026-06-21"
    "2026-09-25" "2026-09-26" "2026-09-27"
    "2026-10-01" "2026-10-02" "2026-10-03" "2026-10-04" "2026-10-05" "2026-10-06" "2026-10-07")
  "Chinese public holidays (Beijing date, YYYY-MM-DD) that are off-peak.
DeepSeek bills these days as off-peak whatever the hour.  The list is
per year and must be extended when a new holiday calendar is published."
  :type '(repeat string) :group 'harness)

(defcustom harness-deepseek-model-specs
  '((:name "deepseek-flash" :label "DeepSeek-V4.1-Flash" :tier flash :vision t
           :thinking-levels ("low" "high" "max"))
    (:name "deepseek-v4-flash" :label "DeepSeek V4 Flash (legacy name)" :tier flash :vision t
           :thinking-levels ("low" "high" "max"))
    (:name "deepseek-v4-flash-vision-exp" :label "DeepSeek V4 Flash Vision (legacy name)"
           :tier flash :vision t :thinking-levels ("low" "high" "max"))
    (:name "deepseek-v4-pro" :label "DeepSeek-V4-Pro" :tier pro
           :thinking-levels ("low" "high" "max")))
  "DeepSeek models the provider lists, in order.
Each entry: (:name NAME :label LABEL :tier flash|pro :vision BOOL
:thinking-levels LEVELS), with the shared context window and output
limit filled in.  The tier names the rates in
`harness-deepseek-pricing'."
  :type '(repeat (plist :key-type symbol :value-type sexp))
  :set #'harness-deepseek--custom-set :group 'harness)

(defcustom harness-deepseek-tiers
  '(:cheap "deepseek-flash" :balanced "deepseek-flash" :frontier "deepseek-v4-pro")
  "DeepSeek models named for the common tiers.
The auto-mode judge, for one, runs on the `cheap' one."
  :type '(plist :key-type symbol :value-type string)
  :set #'harness-deepseek--custom-set :group 'harness)

(defconst harness-deepseek-host "api.deepseek.com"
  "Host of the DeepSeek API; also the auth-source host of the key.")

(defconst harness-deepseek-context-window 1048576
  "Context window of every current DeepSeek model (1M tokens).")

(defconst harness-deepseek-max-output 393216
  "Maximum output tokens of every current DeepSeek model (384K).")

(defvar harness-deepseek--registered nil
  "Non-nil once this module registered the deepseek provider.")

(defvar harness-deepseek--warned (make-hash-table :test 'equal)
  "\"SESSION/WINDOW\" keys whose peak-pricing hint was already added.")

;;;; The API key

(defun harness-deepseek--usable (value)
  "Return VALUE when it is a non-blank string, else nil."
  (and (stringp value) (not (string-blank-p value)) (string-trim value)))

(defun harness-deepseek--auth-source-key ()
  "Look the DeepSeek API key up in auth-source; return it or nil."
  (require 'auth-source)
  (ignore-errors
    (when-let* ((found (car (auth-source-search :host harness-deepseek-host :user "apikey" :max 1)))
                (secret (plist-get found :secret)))
      (harness-deepseek--usable (if (functionp secret) (funcall secret) secret)))))

(defun harness-deepseek-api-key ()
  "Return the DeepSeek API key, or nil when none is configured.
`harness-deepseek-api-key' comes first, then DEEPSEEK_API_KEY, then
auth-source."
  (or (harness-deepseek--usable harness-deepseek-api-key)
      (harness-deepseek--usable (getenv "DEEPSEEK_API_KEY"))
      (harness-deepseek--auth-source-key)))

;;;; Peak and off-peak

(defun harness-deepseek-off-peak-date-p (&optional at)
  "Non-nil when the Beijing date of AT (default now) is a holiday.
See `harness-deepseek-off-peak-dates'."
  (member (format-time-string "%Y-%m-%d" (or at (float-time)) 28800)
          harness-deepseek-off-peak-dates))

(defun harness-deepseek-peak-window (&optional at)
  "Return the (START . END) UTC peak window containing AT, or nil.
AT defaults to now."
  (when (harness-deepseek-peak-p at)
    (let ((hour (decoded-time-hour (decode-time (or at (float-time)) t))))
      (cl-find-if (lambda (w) (and (>= hour (car w)) (< hour (cdr w))))
                  harness-deepseek-peak-windows))))

(defun harness-deepseek-peak-p (&optional at)
  "Non-nil when DeepSeek peak pricing applies at AT (default now).
Peak is Monday to Friday, in `harness-deepseek-peak-windows' UTC, and
never on a date in `harness-deepseek-off-peak-dates'."
  (let* ((utc (decode-time (or at (float-time)) t))
         (weekday (decoded-time-weekday utc))
         (hour (decoded-time-hour utc)))
    (and (<= 1 weekday 5)
         (not (harness-deepseek-off-peak-date-p at))
         (cl-some (lambda (w) (and (>= hour (car w)) (< hour (cdr w))))
                  harness-deepseek-peak-windows))))

(defun harness-deepseek-rates-at (model _usage &optional at)
  "Return MODEL's DeepSeek rates in effect at AT (default now).
Off-peak rates are MODEL's `:pricing'; during a peak window the rates
from `:peak-pricing' apply.  This is the model's `:pricing-fn', which
`usage/price' calls, so costs follow the clock."
  (if (harness-deepseek-peak-p at)
      (or (plist-get model :peak-pricing) (plist-get model :pricing))
    (plist-get model :pricing)))

;;;; The catalogue

(defun harness-deepseek--rates (tier)
  "Return the pricing plist TIER names, or nil."
  (cdr (assq tier harness-deepseek-pricing)))

(defun harness-deepseek--model (spec)
  "Build a model plist from SPEC, an entry of `harness-deepseek-model-specs'."
  (let* ((tier (plist-get spec :tier))
         (rates (harness-deepseek--rates tier))
         (caps (when (plist-get spec :vision) (list :vision t))))
    (append
     (list :name (plist-get spec :name)
           :label (or (plist-get spec :label) (plist-get spec :name))
           :context-window (or (plist-get spec :context-window) harness-deepseek-context-window)
           :max-output (or (plist-get spec :max-output) harness-deepseek-max-output)
           :input-modalities (or (plist-get spec :input-modalities)
                                 (if (plist-get spec :vision) '("text" "image") '("text")))
           :thinking-levels (or (plist-get spec :thinking-levels) '("high" "max"))
           :pricing (plist-get rates :off-peak)
           :peak-pricing (plist-get rates :peak)
           ;; Called by `usage/price' with (MODEL USAGE AT).
           :pricing-fn 'harness-deepseek-rates-at)
     (when caps (list :capabilities caps)))))

(defun harness-deepseek--models ()
  "Return the model plists the provider lists."
  (mapcar #'harness-deepseek--model harness-deepseek-model-specs))

(defun harness-deepseek--endpoint ()
  "Return the endpoint plist the DeepSeek provider is registered from."
  (list :id 'deepseek
        :label "DeepSeek"
        :base-url harness-deepseek-base-url
        :api-key-env "DEEPSEEK_API_KEY"
        :flavor 'deepseek
        :models (harness-deepseek--models)
        :tiers harness-deepseek-tiers
        :capabilities '(:thinking t)))

;;;; Registration

(defun harness-deepseek-refresh ()
  "Register or remove the DeepSeek provider, following the API key.
With a key, or `harness-deepseek-always-register', the provider is
registered; without one it is removed, so the model picker never offers
models that cannot be called.  Return the provider id when registered,
nil otherwise."
  (interactive)
  (if (or harness-deepseek-always-register (harness-deepseek-api-key))
      (progn
        (harness-openai-register-endpoint (harness-deepseek--endpoint))
        (setq harness-deepseek--registered t)
        'deepseek)
    ;; Remove only a provider this module made; a deepseek endpoint of the
    ;; user's own in `harness-openai-endpoints' is left alone.
    (when (and (harness-provider-get 'deepseek)
               (or harness-deepseek--registered
                   (not (harness-openai-endpoint 'deepseek))))
      (harness-provider-unregister 'deepseek))
    (setq harness-deepseek--registered nil)
    nil))

;;;; Peak-pricing notice

(defun harness-deepseek--peak-key (&optional at)
  "Return a key naming the peak window containing AT, for deduplication."
  (let ((at (or at (float-time))))
    (format "%s-%s" (format-time-string "%Y-%m-%d" at t)
            (car (harness-deepseek-peak-window at)))))

(defun harness-deepseek-peak-notice (&optional at)
  "Return the one-line notice that peak pricing applies at AT, or nil.
AT defaults to now."
  (when-let* ((window (harness-deepseek-peak-window at)))
    (format "DeepSeek peak pricing in effect until %02d:00 UTC: rates are double the off-peak price."
            (cdr window))))

(defun harness-deepseek--on-request-started (provider-id request &optional at)
  "Add the peak-pricing hint to REQUEST's session, once per peak window.
PROVIDER-ID is the provider a completion started for, AT the time to
judge (default now).  Emits `provider/pricing-warning' when the hint is
new."
  (when (and (eq provider-id 'deepseek)
             harness-deepseek-warn-on-peak
             (harness-deepseek-peak-p at))
    (let* ((session (plist-get request :session))
           (sid (plist-get session :id))
           (key (and sid (format "%s/%s" sid (harness-deepseek--peak-key at)))))
      (when (and key (not (gethash key harness-deepseek--warned)))
        (puthash key t harness-deepseek--warned)
        (harness-emit 'provider/pricing-warning 'deepseek 'peak
                      (harness-deepseek-peak-window at))
        (harness-log 'info "deepseek: %s" (harness-deepseek-peak-notice at))
        (when (and (harness-method-exists-p 'session/hint)
                   (or (not (harness-method-exists-p 'session/exists-p))
                       ;; The session may have gone while the turn started.
                       (harness-call 'session/exists-p sid)))
          (harness-call 'session/hint sid (harness-deepseek-peak-notice at)))))))

;;;; Module

(defun harness-deepseek--init ()
  "Register the provider from the configured key and subscribe to requests."
  (harness-deepseek-refresh)
  (harness-on 'provider/request-started #'harness-deepseek--on-request-started))

(harness-declare-event 'provider/pricing-warning
                       "(PROVIDER-ID TIER WINDOW) when a provider's rates are higher now.
TIER is `peak' and WINDOW its (START . END) UTC hours, so a UI can warn
that a call costs more.")

(harness-define-module 'provider-deepseek
  :doc "DeepSeek provider (OpenAI-compatible) with peak and off-peak pricing."
  :requires '(provider provider-openai)
  :init #'harness-deepseek--init)

(provide 'harness-provider-deepseek)
;;; harness-provider-deepseek.el ends here
