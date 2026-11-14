;;; harness-usage-history.el --- Historical token mix and price evidence -*- lexical-binding: t; -*-

;;; Commentary:

;; Read-only accounting over the usage ledger and usage metadata reconstructed
;; from session logs.  Counter presence and provenance matter here: unlike the
;; budget summaries, an absent counter or price is never a zero.
;;
;; `usage/history' reconstructs disjoint cache-read, separately reported
;; cache-write, uncached input and output categories, grouped overall, by
;; owning project, recorded workspace or local calendar day.  The usage
;; ledger wins over logs for an overlapping session.  A background worker
;; projects only usage metadata from sessions/ID.nodes.jsonl; it never
;; exports conversation contents.  Old zero-filled counters remain unknown.
;;
;; Observed bills are not allocated to categories.  Category contributions
;; are reconstructed with recorded rate snapshots or explicitly labelled
;; current-catalogue estimates evaluated at the record's timestamp.  The
;; report identifies USD-per-million rates and token/money denominators.
;; A cache-read-majority finding applies only to its fully classified,
;; fully priced non-subscription cohort, never to all recurring invoices.
;; See docs/design/historical-token-mix.md for coverage and confidence.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-usage)
(require 'harness-usage-history-scan)

(defvar harness-state-directory)

(defconst harness-usage-history--categories '(:cache-read :cache-write :input :output)
  "Disjoint token categories, in presentation order.")

(defun harness-usage-history--number (value)
  "Return nonnegative finite VALUE, or nil for an unknown amount."
  (and (numberp value) (>= value 0) (< value 1.0e100) value))

(defun harness-usage-history--enum (value)
  "Return VALUE as a string, or nil."
  (and value (format "%s" value)))

(defun harness-usage-history--legacy (row)
  "Return conservative metadata for a legacy ledger ROW.
Old ledger zeros were manufactured for absent counters.  They cannot
establish a cache miss or an observed free call."
  (append (harness-usage-history-scan-normalize row (plist-get row :model) "unknown" "ledger")
          (list :legacy t)))

(defun harness-usage-history--ledger-sample (row)
  "Return a metadata sample of ROW, without private session contents."
  (let* ((details (or (plist-get row :details) (harness-usage-history--legacy row))))
    (append
     (list :id (plist-get row :id) :source "ledger"
           :ts (plist-get row :ts) :session (plist-get row :session)
           :project (plist-get row :project) :main (plist-get row :main)
           :model (plist-get row :model) :billing (harness-usage-history--enum (plist-get row :billing))
           :recorded-cost (harness-usage-history--number (plist-get row :cost)))
     ;; Only whitelisted evidence leaves the ledger conversion.
     (cl-loop for key in '(:usage :input-semantics :cache-write-status :cost-source
                          :observed-cost :pricing :currency :priced-at :legacy)
              append (list key (plist-get details key))))))

(defun harness-usage-history--partition (sample)
  "Return disjoint counters and completeness for SAMPLE.
An unavailable separate write counter is not a zero observation.  On
such providers the non-read input includes any inseparable writes."
  (let* ((usage (plist-get sample :usage))
         (semantics (harness-usage-history--enum (plist-get sample :input-semantics)))
         (write-status (harness-usage-history--enum (plist-get sample :cache-write-status)))
         (input (harness-usage-history--number (plist-get usage :input)))
         (read (harness-usage-history--number (plist-get usage :cache-read)))
         (write (unless (equal write-status "not-reported")
                  (harness-usage-history--number (plist-get usage :cache-write))))
         (output (harness-usage-history--number (plist-get usage :output)))
         (inconsistent (and (equal semantics "inclusive") input read
                            (or write (equal write-status "not-reported"))
                            (> (+ read (or write 0)) input)))
         (uncached (cond ((equal semantics "exclusive") input)
                         ((and (equal semantics "inclusive") input read
                               (or write (equal write-status "not-reported"))
                               (>= input (+ read (or write 0))))
                          (- input read (or write 0))))))
    ;; Contradictory inclusive totals do not identify which cache counter
    ;; was wrong.  Keep none as category evidence; no negative/clamped input.
    (when inconsistent (setq read nil write nil))
    (list :tokens (list :input uncached :output output :cache-read read :cache-write write)
          :unclassified-input (and input (null uncached) input)
          :write-unavailable (equal write-status "not-reported")
          :complete (and uncached read output (or write (equal write-status "not-reported")) t))))

(defun harness-usage-history--price (sample models)
  "Return SAMPLE's rate evidence, using MODELS only without a snapshot."
  (let* ((snapshot (plist-get sample :pricing))
         (model (cl-find (plist-get sample :model) models :key (lambda (m) (plist-get m :id)) :test #'equal))
         (at (plist-get sample :ts))
         (pricing (or snapshot
                      (and model (condition-case nil
                                     (harness-usage--pricing-at model (plist-get sample :usage) at)
                                   (error nil)))))
         (rates (cl-loop for key in harness-usage-history--categories
                         for rate = (harness-usage-history--number (plist-get pricing key))
                         when rate append (list key rate))))
    (list :pricing rates :source (if snapshot "snapshot" "catalogue")
          :currency (or (plist-get sample :currency) "USD")
          :priced-at (if snapshot (plist-get sample :priced-at) at))))

(defun harness-usage-history--evidence (sample models)
  "Return sanitized, partitioned and priced SAMPLE with MODELS' fallback rates."
  (let* ((partition (harness-usage-history--partition sample))
         (price (harness-usage-history--price sample models))
         (tokens (plist-get partition :tokens))
         (usd (equal (plist-get price :currency) "USD"))
         (costs nil))
    (dolist (key harness-usage-history--categories)
      (let ((n (plist-get tokens key)) (rate (plist-get (plist-get price :pricing) key)))
        (setq costs (plist-put costs key (and usd n (cond ((zerop n) 0.0)
                                                         (rate (/ (* n rate) 1000000.0))))))))
    (append sample partition (list :price price :costs costs
                                   :comparable (and usd (plist-get partition :complete)
                                                    (member (plist-get sample :billing) '("api" "extra-usage"))
                                                    (cl-every (lambda (key)
                                                                (or (and (eq key :cache-write)
                                                                         (plist-get partition :write-unavailable))
                                                                    (numberp (plist-get costs key))))
                                                              harness-usage-history--categories))))))

(defun harness-usage-history--subtotal (samples key field)
  "Sum known KEY values of SAMPLES' FIELD, nil when none are known."
  (let ((values (delq nil (mapcar (lambda (s) (plist-get (plist-get s field) key)) samples))))
    (and values (apply #'+ values))))

(defun harness-usage-history--sum-known (samples key)
  "Sum known KEY values of SAMPLES, nil when none are known."
  (let ((values (delq nil (mapcar (lambda (s) (harness-usage-history--number (plist-get s key))) samples))))
    (and values (apply #'+ values))))

(defun harness-usage-history--price-matrix (samples)
  "Group SAMPLES by actual model and rate evidence, without mixing prices."
  (let ((table (make-hash-table :test 'equal)) order)
    (dolist (sample samples)
      (let* ((price (plist-get sample :price))
             (key (list (plist-get sample :model) (plist-get price :source)
                        (plist-get price :currency) (plist-get price :pricing))))
        (unless (gethash key table) (push key order))
        (push sample (gethash key table))))
    (mapcar
     (lambda (key)
       (let* ((rows (gethash key table))
              (dates (delq nil (mapcar (lambda (s) (plist-get (plist-get s :price) :priced-at)) rows))))
         (list :model (car key) :source (nth 1 key) :currency (nth 2 key) :pricing (nth 3 key)
               :records (length rows) :price-since (and dates (apply #'min dates))
               :price-until (and dates (apply #'max dates))
               :price-since-label (and dates (format-time-string "%Y-%m-%d %H:%M" (apply #'min dates)))
               :price-until-label (and dates (format-time-string "%Y-%m-%d %H:%M" (apply #'max dates)))
               :categories (mapcar (lambda (k)
                                     (list :key (substring (symbol-name k) 1)
                                           :tokens (harness-usage-history--subtotal rows k :tokens)
                                           :cost (harness-usage-history--subtotal rows k :costs)
                                           :known (cl-count-if (lambda (s) (numberp (plist-get (plist-get s :tokens) k))) rows)
                                           :priced (cl-count-if (lambda (s) (numberp (plist-get (plist-get s :costs) k))) rows)
                                           :records (length rows)
                                           :unavailable (and (eq k :cache-write)
                                                             (cl-every (lambda (s) (plist-get s :write-unavailable)) rows))))
                                   harness-usage-history--categories))))
     (nreverse order))))

(defun harness-usage-history--aggregate (samples key)
  "Aggregate evidence SAMPLES under KEY with explicit coverage and denominators."
  (let* ((count (length samples))
         (token-total (apply #'+ (mapcar (lambda (k) (or (harness-usage-history--subtotal samples k :tokens) 0))
                                        harness-usage-history--categories)))
         (money-total (apply #'+ (mapcar (lambda (k) (or (harness-usage-history--subtotal samples k :costs) 0))
                                        harness-usage-history--categories)))
         (known-tokens (cl-some (lambda (s) (cl-some (lambda (k) (numberp (plist-get (plist-get s :tokens) k)))
                                                                    harness-usage-history--categories)) samples))
         (known-money (cl-some (lambda (s) (cl-some (lambda (k) (numberp (plist-get (plist-get s :costs) k)))
                                                                   harness-usage-history--categories)) samples))
         (comparable (cl-remove-if-not (lambda (s) (plist-get s :comparable)) samples))
         (cohort-cost (apply #'+ (mapcar (lambda (s) (apply #'+ (delq nil (mapcar (lambda (k) (plist-get (plist-get s :costs) k))
                                                                                          harness-usage-history--categories)))) comparable)))
         (cohort-read (or (harness-usage-history--subtotal comparable :cache-read :costs) 0))
         (observed (cl-remove-if-not (lambda (s) (and (equal (plist-get s :cost-source) "observed")
                                                      (equal (or (plist-get s :currency) "USD") "USD")
                                                      (numberp (plist-get s :observed-cost)))) samples))
         (unknown-origin (cl-remove-if-not (lambda (s) (and (member (plist-get s :cost-source) '(nil "unknown" "legacy"))
                                                            (equal (or (plist-get s :currency) "USD") "USD"))) samples)))
    (list :key key :records count
          :token-denominator (and known-tokens token-total) :money-denominator (and known-money money-total)
          :observed-cost (harness-usage-history--sum-known observed :observed-cost) :observed-records (length observed)
          :recorded-unknown (harness-usage-history--sum-known unknown-origin :recorded-cost)
          :plan-records (cl-count-if (lambda (s) (or (equal (plist-get s :billing) "subscription")
                                                    (equal (plist-get s :cost-source) "subscription"))) samples)
          :legacy-records (cl-count-if (lambda (s) (plist-get s :legacy)) samples)
          :unclassified-input (harness-usage-history--sum-known samples :unclassified-input)
          :ledger-records (cl-count "ledger" samples :key (lambda (s) (plist-get s :source)) :test #'equal)
          :log-records (cl-count "session-log" samples :key (lambda (s) (plist-get s :source)) :test #'equal)
          :complete-records (cl-count-if (lambda (s) (plist-get s :complete)) samples)
          :categories
          (mapcar
           (lambda (k)
             (let* ((tokens (harness-usage-history--subtotal samples k :tokens))
                    (cost (harness-usage-history--subtotal samples k :costs))
                    (known (cl-count-if (lambda (s) (numberp (plist-get (plist-get s :tokens) k))) samples))
                    (priced (cl-count-if (lambda (s) (numberp (plist-get (plist-get s :costs) k))) samples))
                    (unavailable (if (eq k :cache-write) (cl-count-if (lambda (s) (plist-get s :write-unavailable)) samples) 0)))
               (list :key (substring (symbol-name k) 1) :tokens tokens :cost cost
                     :known known :priced priced :unavailable unavailable :records count
                     :state (cond ((= known count) (if (> count 0) "complete" "unknown"))
                                  ((and (> count 0) (= unavailable count)) "not-reported")
                                  ((> known 0) "partial") (t "unknown"))
                     :token-share (and tokens (> token-total 0) (/ (float tokens) token-total))
                     :cost-share (and cost (> money-total 0) (/ (float cost) money-total)))))
           harness-usage-history--categories)
          :cohort (list :records (length comparable) :cost (and comparable cohort-cost)
                        :cache-read-cost (and comparable cohort-read)
                        :share (and (> cohort-cost 0) (/ cohort-read cohort-cost))
                        :verdict (cond ((<= cohort-cost 0) "undetermined")
                                       ((> cohort-read (/ cohort-cost 2)) "majority") (t "not-majority")))
          :prices (harness-usage-history--price-matrix samples))))

(defun harness-usage-history--matches (sample opts)
  "Non-nil when dated SAMPLE matches the scope and half-open period OPTS."
  (let ((ts (plist-get sample :ts)))
    (and (numberp ts)
         (or (null (plist-get opts :since)) (>= ts (plist-get opts :since)))
         (or (null (plist-get opts :until)) (< ts (plist-get opts :until)))
         (or (null (plist-get opts :project)) (equal (plist-get opts :project) (plist-get sample :main)))
         (or (null (plist-get opts :workspace)) (equal (plist-get opts :workspace) (plist-get sample :project)))
         (or (null (plist-get opts :session)) (equal (plist-get opts :session) (plist-get sample :session))))))

(defun harness-usage-history-compute (rows log-samples models opts &optional scan-coverage)
  "Compute a privacy-safe report from ledger ROWS, LOG-SAMPLES and MODELS.
OPTS selects a period and :group-by overall/project/workspace/day.
SCAN-COVERAGE describes gaps, not extra usage.  This pure accounting
entry point is also used by the synthetic demo and regression tests."
  (let ((sessions (make-hash-table :test 'equal)) (seen (make-hash-table :test 'equal))
        (groups (make-hash-table :test 'equal)) order samples (duplicates 0) (overlap 0) (undated 0)
        (group (intern (or (harness-usage-history--enum (plist-get opts :group-by)) "overall"))))
    (unless (memq group '(overall project workspace day)) (error "Unknown history grouping"))
    ;; Precedence is session-wide, before period filtering, so a turn cannot
    ;; be counted from both its log timestamp and its later ledger timestamp.
    (dolist (row rows)
      (when (plist-get row :session) (puthash (plist-get row :session) t sessions)))
    (dolist (sample (append (mapcar #'harness-usage-history--ledger-sample rows) log-samples))
      (let ((id (and (plist-get sample :id) (list (plist-get sample :source) (plist-get sample :id)))))
        (cond
         ((and (equal (plist-get sample :source) "session-log") (gethash (plist-get sample :session) sessions))
          (cl-incf overlap))
         ((and id (gethash id seen)) (cl-incf duplicates))
         (t
          (when id (puthash id t seen))
          (if (not (numberp (plist-get sample :ts))) (cl-incf undated)
            (when (harness-usage-history--matches sample opts)
              (push (harness-usage-history--evidence sample models) samples)))))))
    (setq samples (nreverse samples))
    (dolist (sample samples)
      (let ((key (pcase group
                   ('overall "Overall") ('project (or (plist-get sample :main) ""))
                   ('workspace (or (plist-get sample :project) ""))
                   ('day (harness-usage-day-key (plist-get sample :ts))))))
        (unless (gethash key groups) (push key order))
        (push sample (gethash key groups))))
    (list :version 1 :currency "USD" :since (plist-get opts :since) :until (plist-get opts :until)
          :since-label (and (plist-get opts :since) (format-time-string "%Y-%m-%d %H:%M" (plist-get opts :since)))
          :until-label (and (plist-get opts :until) (format-time-string "%Y-%m-%d %H:%M" (plist-get opts :until)))
          :timezone (format-time-string "%Z") :group-by (symbol-name group)
          :totals (harness-usage-history--aggregate samples "Overall")
          :groups (mapcar (lambda (key) (harness-usage-history--aggregate (nreverse (gethash key groups)) key))
                          (sort order #'string<))
          :coverage (append (list :duplicates duplicates :overlap overlap :undated undated)
                            ;; Per-session diagnostics stay in the worker; only
                            ;; aggregate coverage crosses the presentation API.
                            (harness-plist-remove scan-coverage :sessions)))))

(defun harness-usage-history--scopes (rows sessions)
  "Add owning-checkout attribution to ROWS and safe SESSIONS, once per path."
  (let ((memo (make-hash-table :test 'equal)))
    (cl-labels ((main (path)
                  (or (gethash path memo)
                      (puthash path (if (and path (not (equal path ""))) (harness-usage--main path) "") memo))))
      (list (mapcar (lambda (r) (plist-put (copy-sequence r) :main (main (plist-get r :project)))) rows)
            (mapcar (lambda (s) (list :id (plist-get s :id) :project (plist-get s :project)
                                      :main (main (plist-get s :project))
                                      ;; Worktree sessions cannot move.  A plain
                                      ;; session's current root is not history.
                                      :scope-stable (and (plist-get s :worktree) t))) sessions)))))

(defun harness-usage-history--period-opts (opts &optional now)
  "Resolve OPTS' calendar :period at NOW in the harness's own time zone."
  (let* ((opts (copy-sequence opts))
         (period (harness-usage-history--enum (plist-get opts :period)))
         (now (or now (float-time))))
    (when period
      (unless (member period '("today" "7d" "30d" "all")) (error "Unknown history period"))
      (setq opts (harness-plist-remove opts :since))
      (unless (equal period "all")
        (let* ((days (pcase period ("7d" 6) ("30d" 29) (_ 0)))
               (date (harness-usage--add-days (harness-usage--date now) (- days))))
          (setq opts (plist-put opts :since (harness-usage--day-start date))))))
    (plist-put opts :until (or (plist-get opts :until) now))))

(harness-defmethod usage/history (&rest opts)
  "Return a promise of historical token and spend evidence for OPTS.
`:group-by' is overall, project, workspace or day; optional :since
(inclusive), :until (exclusive), :project (owning checkout), :workspace
(recorded root), and :session filter the report.  The ledger wins over
session logs.  Only whitelisted aggregate metadata crosses ACP."
  (let* ((opts (harness-usage-history--period-opts opts))
         (rows (harness-call 'usage/rows))
         (sessions (harness-call 'session/list))
         (scopes (harness-usage-history--scopes rows sessions))
         (rows (car scopes))
         (recorded (delete-dups (delq nil (mapcar (lambda (r) (plist-get r :session)) rows))))
         (excluded (cl-count-if (lambda (s) (member (plist-get s :id) recorded)) (cadr scopes)))
         (sessions (cl-remove-if (lambda (s) (member (plist-get s :id) recorded)) (cadr scopes)))
         ;; Only the explicitly non-fetching lookup: provider/model can
         ;; fetch a cold catalogue, launch a CLI or ask for authentication.
         (model-ids (delete-dups (delq nil (mapcar (lambda (r) (plist-get r :model)) rows)))))
    (harness-then
     (harness-usage-history-scan-run
      (list :sessions-dir (expand-file-name "sessions/" harness-state-directory)
            :sessions sessions :since (plist-get opts :since) :until (plist-get opts :until)))
     (lambda (scan)
       (let* ((samples (car (harness-usage-history--scopes (plist-get scan :samples) nil)))
              (ids (delete-dups (append model-ids (delq nil (mapcar (lambda (s) (plist-get s :model)) samples)))))
              (models (delq nil (mapcar (lambda (id) (ignore-errors (harness-call 'provider/model-cached id))) ids))))
         (let ((coverage (copy-sequence (plist-get scan :coverage))))
           (when (equal (plist-get coverage :status) "empty")
             (setq coverage (plist-put coverage :gaps nil)))
           (setq coverage (plist-put coverage :ledger-session-exclusions excluded))
           (harness-usage-history-compute rows samples models opts coverage)))))))

(harness-define-module 'usage-history
  :doc "Historical token mix, coverage and reconstructed monetary contributions."
  :requires '(usage provider session))

(provide 'harness-usage-history)
;;; harness-usage-history.el ends here
