;;; harness-cost-compare.el --- What the recorded usage would cost elsewhere  -*- lexical-binding: t; -*-

;;; Commentary:

;; The harness records, for every model call, the tokens it sent and
;; received by kind: the input that was not cached, the output, the
;; tokens read from a provider's prompt cache and the ones written to
;; it.  This module re-prices exactly those recorded tokens at another
;; model's rates, to answer "how much would this have cost using a
;; different provider?" (see the usage dashboard's cost comparison).
;;
;; Nothing is written: the recorded rows, their cost and the budgets
;; stay as they are.  What a call was billed is the recorded `:cost'
;; (zero when a plan paid); the value of the same tokens at API prices
;; is `:list-cost', which is what the comparison compares with, since a
;; plan-covered call would otherwise look free.
;;
;; The rates are the ones the catalogue already carries -- each model's
;; `:pricing', or the plist its `:pricing-fn' answers for the clock in
;; effect (DeepSeek's peak and off-peak) -- and `usage/price' does the
;; arithmetic, so there is one rate source and one formula.  Two token
;; kinds need a word, because another provider may not bill them the
;; same way:
;;
;; - Tokens read from the source model's cache: a model that prices no
;;   cache read would have been sent them as ordinary input, and billed
;;   for them, so they are priced at that model's input rate.
;; - Tokens written to a cache: writing costs at least the input those
;;   tokens would otherwise be billed at, so a cache-write rate below
;;   the input rate (a provider that does not charge for writes, such
;;   as DeepSeek) does not undercount them.
;;
;; A model the catalogue does not price is reported as unpriced --
;; `:priced' nil and `:cost' nil -- never as a cost of zero.

;;; Code:

(require 'cl-lib)
(require 'harness-core)
(require 'harness-util)

(defun harness-cost-compare--int (value)
  "Return VALUE, a token count in USAGE, as an integer, 0 when it is not one."
  (if (numberp value) (truncate value) 0))

(defun harness-cost-compare--pricing (model usage at)
  "Return the pricing plist MODEL bills USAGE with at AT, or nil.
A model with a `:pricing-fn' -- the rates DeepSeek bills by the clock
-- is asked through it, exactly as `usage/price' asks it; any other
model uses its static `:pricing'."
  (let ((fn (plist-get model :pricing-fn)))
    (if (not (or (symbolp fn) (functionp fn)))
        (plist-get model :pricing)
      (condition-case err
          (or (funcall fn model usage at) (plist-get model :pricing))
        (error (harness-log 'debug "cost-compare: pricing %s failed: %s"
                            (plist-get model :id) (harness-error-message err))
               (plist-get model :pricing))))))

(defun harness-cost-compare--priced-p (pricing)
  "Non-nil when PRICING can price a call: input and output rates, both real.
A negative rate says the provider does not know its price (see
`harness-provider--price-score'), which counts as unpriced."
  (and (numberp (plist-get pricing :input)) (>= (plist-get pricing :input) 0)
       (numberp (plist-get pricing :output)) (>= (plist-get pricing :output) 0)))

(defun harness-cost-compare--usage (pricing usage)
  "Return (ADJUSTED . NOTE) for USAGE at PRICING's cache rates.
ADJUSTED is USAGE as `usage/price' takes it: the tokens PRICING does
not price as a cache read, or prices below its input rate as a cache
write, are put back among the input, where that model would have billed
them (see the commentary).  NOTE says in a few words what was done, or
nil when the recorded kinds price as they are."
  (let* ((input (plist-get pricing :input))
         (cache-read-rate (plist-get pricing :cache-read))
         (cache-write-rate (plist-get pricing :cache-write))
         (cache-read (harness-cost-compare--int (plist-get usage :cache-read)))
         (cache-write (harness-cost-compare--int (plist-get usage :cache-write)))
         (read-as-input (if (numberp cache-read-rate) 0 cache-read))
         (write-as-input (if (and (numberp cache-write-rate) (numberp input)
                                  (>= cache-write-rate input))
                             0 cache-write))
         (note (cond ((and (> read-as-input 0) (> write-as-input 0))
                      "cache reads and writes priced as input")
                     ((> read-as-input 0) "cache reads priced as input")
                     ((> write-as-input 0) "cache writes priced as input"))))
    (cons (if (and (zerop read-as-input) (zerop write-as-input))
              usage
            (harness-plist-merge
             usage
             (list :input (+ (harness-cost-compare--int (plist-get usage :input))
                             read-as-input write-as-input)
                   :cache-read (- cache-read read-as-input)
                   :cache-write (- cache-write write-as-input))))
          note)))

(defun harness-cost-compare--row (id usage list-cost at reference)
  "Return the comparison row for model ID over USAGE, priced at AT.
LIST-COST is the value of USAGE at API prices, which the row's
`:delta' compares its recomputed cost with.  REFERENCE non-nil marks
the row as the model the recorded usage ran on."
  (let* ((model (ignore-errors (harness-call 'provider/model id)))
         (pricing (and model (harness-cost-compare--pricing model usage at)))
         (priced (and pricing (harness-cost-compare--priced-p pricing)))
         (adjusted (and priced (harness-cost-compare--usage pricing usage)))
         (cost (and priced (harness-call 'usage/price id (car adjusted) at))))
    (list :model id
          :label (or (plist-get model :label) (plist-get model :name) id)
          :provider (plist-get model :provider)
          :provider-label (or (plist-get model :provider-label) (plist-get model :provider))
          :context-window (plist-get model :context-window)
          :pricing pricing
          :note (cdr adjusted)
          :priced (and priced t)
          :cost cost
          :delta (and cost (float (- cost list-cost)))
          :reference (and reference t))))

(defun harness-cost-compare--catalogue ()
  "Return the models the catalogue holds, without asking for more.
`provider/models' answers at once once every provider has listed them,
the usual case; while one is still listing, it contributes nothing, and
a caller that knows the models passes them as `:models'."
  (let ((promise (harness-call 'provider/models)))
    (and (harness-promise-p promise) (harness-promise-settled-p promise)
         (eq (harness-promise-state promise) 'resolved)
         (harness-promise-value promise))))

(defun harness-cost-compare--candidates (opts)
  "Return the model ids to compare for OPTS.
Those are `:models' when given, else every priced and unpriced model of
the catalogue.  The model named by `:reference-model' comes first even
when `:models' leaves it out, so the row the usage ran on is always
there; the rest sort by price when the rows are made."
  (let* ((given (plist-get opts :models))
         (given (and given (mapcar (lambda (id) (format "%s" id)) (append given nil))))
         (catalogue (unless given (harness-cost-compare--catalogue)))
         (ids (or given (mapcar (lambda (m) (plist-get m :id)) catalogue)))
         (reference (plist-get opts :reference-model)))
    (if (and reference (not (member reference ids)))
        (cons reference ids)
      ids)))

(defun harness-cost-compare--sorted (rows)
  "Return ROWS cheapest first, the unpriced ones last.
A row's `:cost' is nil when the catalogue does not price its model."
  (sort rows (lambda (a b)
               (let ((ca (plist-get a :cost)) (cb (plist-get b :cost)))
                 (cond ((and ca cb) (< ca cb))
                       (ca t)
                       (cb nil)
                       (t (string< (or (plist-get a :model) "") (or (plist-get b :model) ""))))))))

(defun harness-cost-compare--filters (opts)
  "Return the `usage/totals' filters in OPTS, leaving the rest out."
  (cl-loop for key in '(:since :until :project :projects :session :model :billing)
           when (plist-member opts key) append (list key (plist-get opts key))))

(defconst harness-cost-compare--empty
  (list :input 0 :output 0 :cache-read 0 :cache-write 0 :cost 0.0 :list-cost 0.0 :calls 0)
  "Totals of a scope with no recorded usage.")

(harness-defmethod usage/cost-compare (&rest opts)
  "Return what the recorded usage OPTS selects would have cost elsewhere.
OPTS are the filters `usage/totals' takes (`:since' `:until' `:project'
`:projects' `:session' `:model' `:billing'), plus:
  `:models'          the model ids to compare (default: the catalogue's),
  `:reference-model' the model the usage ran on, marked in the answer,
  `:at'              the time the rates are taken at (default: now).
The answer is a plist:
  (:recorded TOTALS :since F :until F :reference ID :at F :rows ROWS)
TOTALS is what `usage/totals' returned for the same filters, so it
carries what was billed (`:cost'), what the same tokens were worth at
API prices (`:list-cost') and the token counts by kind.  Each row is
\\='(:model ID :label STR :provider STR :provider-label STR
:context-window N :pricing PLIST :note STR|nil :priced BOOL
:cost F|nil :delta F|nil :reference BOOL), cheapest first with the
unpriced last.  `:pricing' is the rate plist the cost was computed
with, `:note' says when a token kind was priced as input (see the
commentary); `:cost' is the recomputed cost of the recorded tokens at
that model's rates, nil when the catalogue does not price it (never 0);
`:delta' is `:cost' less the recorded `:list-cost'.  Nothing is
recorded or changed."
  (let* ((totals (apply #'harness-call 'usage/totals (harness-cost-compare--filters opts)))
         (totals (or totals harness-cost-compare--empty))
         (usage (harness-plist-remove totals :calls))
         (at (or (plist-get opts :at) (float-time)))
         (reference (plist-get opts :reference-model))
         (list-cost (float (or (plist-get totals :list-cost) 0)))
         (rows (mapcar (lambda (id)
                         (harness-cost-compare--row id usage list-cost at
                                                    (and reference (equal id reference))))
                       (harness-cost-compare--candidates opts))))
    (list :recorded totals
          :since (plist-get opts :since) :until (plist-get opts :until)
          :reference reference :at at
          :rows (harness-cost-compare--sorted rows))))

(harness-define-module 'cost-compare
  :doc "What the recorded usage would have cost at other models' prices."
  :requires '(usage provider))

(provide 'harness-cost-compare)
;;; harness-cost-compare.el ends here
