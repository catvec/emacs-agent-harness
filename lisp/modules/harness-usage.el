;;; harness-usage.el --- Cost accounting and budgets  -*- lexical-binding: t; -*-

;;; Commentary:

;; Every model call ends in a `session/usage' event.  This module prices
;; it when the provider did not, writes one row per call to the `usage'
;; table of usage.db (or to usage/records.jsonl when Emacs lacks
;; SQLite), and answers questions about spending: summaries grouped by
;; project, model, day, hour, session or billing; totals; and
;; continuous time series for charts.
;;
;; A row's cost is what was billed.  Its list cost is what the call
;; costs at API prices, and its billing says who paid: `api' (per
;; token), `subscription' (a plan such as Claude Max paid, so the cost is
;; 0) or `extra-usage' (a plan's extra usage, billed at API prices).
;; Budgets count the cost, so usage a subscription covers spends none.
;;
;; Budgets live in budgets.json.  A budget has a scope (one session,
;; one project, or a calendar period across everything), an amount and
;; a hardness.  Period budgets know how much of the period is left and
;; split the remainder across the remaining days, business days or all.
;; A budget may carry a baseline: what was already spent that the
;; harness never recorded (in other tools, or before it kept usage),
;; set by hand so a budget made mid-period does not start at $0.  A
;; period budget's baseline counts only in the period it was set for;
;; one without a period always counts it.
;; A session's own `:budget' plist is an implicit hard-or-soft budget
;; with scope session.  Hard budgets stop the next turn through the
;; `agent/before-turn' filter; every budget warns once at 80% and soft
;; ones once more at 100%, as an event and as a session hint.
;;
;; Storage is one code path: rows are loaded from whichever backend is
;; in use into plists and aggregated in Lisp.  SQLite only narrows the
;; rows it returns; the Lisp filter and aggregation are the reference.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(declare-function sqlite-execute "sqlite.c")
(declare-function sqlite-select "sqlite.c")

(defcustom harness-usage-warn-fraction 0.8
  "Fraction of a budget at which the first warning is issued."
  :type 'number :group 'harness)

(defconst harness-usage-jsonl-name "usage/records.jsonl"
  "JSONL log of usage rows, used when SQLite is unavailable.")

(defconst harness-usage-budgets-name "budgets.json"
  "Store name of the budget list.")

(defvar harness-usage-budgets nil
  "Budgets as a list of plists, loaded from budgets.json.
Each budget: (:id STRING :scope session|project|period :target
SESSION-ID|ROOT|nil :amount USD :hard BOOL :period nil|day|week|month
:days business|all :created FLOAT :label STRING-OR-NIL), plus, when
something was spent that the harness never recorded, :baseline USD
and, for a period budget, :baseline-period-start \"YYYY-MM-DD\": the
start of the one period the baseline counts in.")

(defvar harness-usage--warned (make-hash-table :test 'equal)
  "\"SESSION/BUDGET/PERIOD-START\" -> thresholds already warned about.")

(defvar harness-usage--schema-db nil
  "(DB . SCHEMA-VERSION) for the SQLite handle whose schema was ensured last.")

(defconst harness-usage--schema-version 2
  "Bumped whenever the schema gains columns, so open databases migrate.")

(defvar harness-usage--refreshed-models nil
  "Non-nil once a catalogue refresh was requested because pricing was missing.")

(defconst harness-usage--columns
  '(:id :ts :session :project :model :input :output :cache-read :cache-write :cost :turn
    :list-cost :billing)
  "Row keys, in the order of the SELECT below.")

(defconst harness-usage--select
  "SELECT id, ts, session, project, model, input, output, cache_read, cache_write, cost, turn, list_cost, billing FROM usage"
  "Projection matching `harness-usage--columns'.")

(defconst harness-usage--schema
  '("CREATE TABLE IF NOT EXISTS usage (id INTEGER PRIMARY KEY, ts REAL, session TEXT, project TEXT, model TEXT, input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER, cost REAL, turn INTEGER, list_cost REAL, billing TEXT)"
    "CREATE INDEX IF NOT EXISTS usage_ts ON usage (ts)"
    "CREATE INDEX IF NOT EXISTS usage_session ON usage (session)"
    "CREATE INDEX IF NOT EXISTS usage_project ON usage (project)")
  "Statements that create the usage table and its indexes idempotently.")

(defconst harness-usage--added-columns
  '(("list_cost" . "REAL") ("billing" . "TEXT"))
  "Columns added since the first schema, as (NAME . TYPE), for older databases.")

;;;; Small helpers

(defun harness-usage--sym (value)
  "Return VALUE interned when it is a string, else VALUE."
  (if (stringp value) (intern value) value))

(defun harness-usage--root (path)
  "Normalise project root PATH for comparison."
  (and path (file-name-as-directory (expand-file-name path))))

(defun harness-usage--int (value)
  "Return VALUE as an integer token count, 0 when absent."
  (if (numberp value) (truncate value) 0))

(defun harness-usage--empty-aggregate (key)
  "Return a zero aggregate plist for KEY."
  (list :key key :input 0 :output 0 :cache-read 0 :cache-write 0 :cost 0.0 :list-cost 0.0 :calls 0))

;;;; Dates (local time)

(defun harness-usage--date (time)
  "Return TIME as a (YEAR MONTH DAY) list in local time."
  (let ((d (decode-time time)))
    (list (decoded-time-year d) (decoded-time-month d) (decoded-time-day d))))

(defun harness-usage--encode (date &optional hour)
  "Return the Lisp time of DATE (YEAR MONTH DAY) at HOUR (default 0).
Out-of-range days and months are normalised by date arithmetic."
  (encode-time (list 0 0 (or hour 0) (nth 2 date) (nth 1 date) (nth 0 date) nil -1 nil)))

(defun harness-usage--day-start (date)
  "Return the float time at which DATE starts."
  (float-time (harness-usage--encode date)))

(defun harness-usage--add-days (date n)
  "Return DATE moved forward by N days."
  (harness-usage--date (harness-usage--encode (list (nth 0 date) (nth 1 date) (+ (nth 2 date) n)) 12)))

(defun harness-usage--weekday (date)
  "Return the weekday of DATE, 0 being Sunday."
  (decoded-time-weekday (decode-time (harness-usage--encode date 12))))

(defun harness-usage--business-day-p (date)
  "Non-nil when DATE is a Monday to Friday."
  (<= 1 (harness-usage--weekday date) 5))

(defun harness-usage--date-key (date)
  "Format DATE as YYYY-MM-DD."
  (format "%04d-%02d-%02d" (nth 0 date) (nth 1 date) (nth 2 date)))

(defun harness-usage--parse-date (string)
  "Return the (YEAR MONTH DAY) that STRING names as YYYY-MM-DD.
Return nil when STRING is not such a date, or names none (2026-02-30)."
  (when (and (stringp string)
             (string-match "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\'" string))
    (let ((date (mapcar (lambda (i) (string-to-number (match-string i string))) '(1 2 3))))
      (and (equal (harness-usage--date (harness-usage--encode date 12)) date) date))))

(defun harness-usage-day-key (time)
  "Return the day bucket key of TIME, YYYY-MM-DD in local time."
  (format-time-string "%Y-%m-%d" time))

(defun harness-usage-hour-key (time)
  "Return the hour bucket key of TIME, \"YYYY-MM-DD HH:00\" in local time."
  (format-time-string "%Y-%m-%d %H:00" time))

(defun harness-usage--hour-start (time)
  "Return the float time of the hour containing TIME."
  (let ((d (decode-time time)))
    (float-time (encode-time (list 0 0 (decoded-time-hour d) (decoded-time-day d)
                                   (decoded-time-month d) (decoded-time-year d) nil -1 nil)))))

(defun harness-usage--dates-between (start end)
  "Return the dates from START up to but excluding END."
  (let ((limit (harness-usage--day-start end)) (date start) out)
    (while (< (harness-usage--day-start date) limit)
      (push date out)
      (setq date (harness-usage--add-days date 1)))
    (nreverse out)))

(defun harness-usage-period-bounds (period &optional now)
  "Return (START-DATE . END-DATE) of the calendar PERIOD containing NOW.
PERIOD is `day', `week' (starting Monday) or `month'; END is exclusive."
  (let* ((today (harness-usage--date (or now (float-time)))))
    (pcase (harness-usage--sym period)
      ('day (cons today (harness-usage--add-days today 1)))
      ('week (let ((start (harness-usage--add-days today (- (mod (- (harness-usage--weekday today) 1) 7)))))
               (cons start (harness-usage--add-days start 7))))
      ('month (let ((start (list (nth 0 today) (nth 1 today) 1)))
                (cons start (harness-usage--date (harness-usage--encode (list (nth 0 today) (1+ (nth 1 today)) 1) 12)))))
      (other (error "Unknown budget period %s" other)))))

(defun harness-usage--period-start-key (value period)
  "Return the start of the calendar PERIOD containing VALUE, as YYYY-MM-DD.
VALUE is a float time or a YYYY-MM-DD date.  Any other VALUE, or a
PERIOD other than day, week or month, is returned unchanged."
  (let ((time (if (numberp value) value
                (when-let* ((date (harness-usage--parse-date value)))
                  (float-time (harness-usage--encode date 12))))))
    (if (and time (memq period '(day week month)))
        (harness-usage--date-key (car (harness-usage-period-bounds period time)))
      value)))

(defun harness-usage--counted-day-p (date period days)
  "Non-nil when DATE counts for planning a PERIOD budget split by DAYS.
A day budget always counts its one day; otherwise weekends are skipped
when DAYS is `business'."
  (or (eq period 'day) (not (eq days 'business)) (harness-usage--business-day-p date)))

;;;; Pricing

(harness-defmethod usage/price (model-id usage)
  "Return the USD cost of USAGE on MODEL-ID.
USAGE has :input :output :cache-read :cache-write token counts; the
model's `:pricing' is USD per million tokens.  A model without pricing
costs 0 (logged at debug level) and a catalogue refresh is requested
once so later calls can be priced."
  (let* ((model (and (harness-method-exists-p 'provider/model)
                     (harness-call 'provider/model model-id)))
         (pricing (plist-get model :pricing)))
    (if (null pricing)
        (progn
          (harness-log 'debug "usage: no pricing for %s; cost recorded as 0" model-id)
          (unless harness-usage--refreshed-models
            (setq harness-usage--refreshed-models t)
            (when (harness-method-exists-p 'provider/models)
              (ignore-errors (harness-call-async 'provider/models t))))
          0.0)
      (/ (+ (* (harness-usage--int (plist-get usage :input)) (or (plist-get pricing :input) 0))
            (* (harness-usage--int (plist-get usage :output)) (or (plist-get pricing :output) 0))
            (* (harness-usage--int (plist-get usage :cache-read)) (or (plist-get pricing :cache-read) 0))
            (* (harness-usage--int (plist-get usage :cache-write)) (or (plist-get pricing :cache-write) 0)))
         1000000.0))))

;;;; Storage

(defun harness-usage--ensure-schema (db)
  "Create the usage table and indexes in DB if missing, adding newer columns."
  (dolist (sql harness-usage--schema) (sqlite-execute db sql))
  (let ((have (mapcar #'cadr (sqlite-select db "PRAGMA table_info(usage)"))))
    (dolist (col harness-usage--added-columns)
      (unless (member (car col) have)
        (sqlite-execute db (format "ALTER TABLE usage ADD COLUMN %s %s" (car col) (cdr col)))))))

(defun harness-usage--db ()
  "Return the SQLite handle with the usage schema in place, or nil."
  (let ((db (and (harness-method-exists-p 'store/sqlite)
                 (condition-case err (harness-call 'store/sqlite)
                   (error (harness-log 'warn "usage: sqlite unavailable: %S" err) nil)))))
    (when db
      ;; Keyed by schema version too, so a reload that adds columns migrates.
      (unless (equal (cons db harness-usage--schema-version) harness-usage--schema-db)
        (harness-usage--ensure-schema db)
        (setq harness-usage--schema-db (cons db harness-usage--schema-version)))
      db)))

(defun harness-usage--make-row (plist)
  "Return a fresh, fully keyed usage row built from PLIST.
A missing `:list-cost' is the cost; `:billing' is stored as a string."
  (let* ((cost (plist-get plist :cost))
         (cost (float (if (numberp cost) cost 0)))
         (list-cost (plist-get plist :list-cost))
         (billing (harness-billing-of plist))
         (turn (plist-get plist :turn)))
    (list :id (plist-get plist :id)
          :ts (float (or (plist-get plist :ts) (float-time)))
          :session (plist-get plist :session)
          :project (harness-usage--root (plist-get plist :project))
          :model (plist-get plist :model)
          :input (harness-usage--int (plist-get plist :input))
          :output (harness-usage--int (plist-get plist :output))
          :cache-read (harness-usage--int (plist-get plist :cache-read))
          :cache-write (harness-usage--int (plist-get plist :cache-write))
          :cost cost
          :turn (and (numberp turn) (truncate turn))
          :list-cost (if (numberp list-cost) (float list-cost) cost)
          :billing (and billing (symbol-name billing)))))

(defun harness-usage--insert (row)
  "Persist ROW in SQLite or the JSONL log; return it with `:id' filled."
  (let ((db (harness-usage--db)))
    (if db
        (progn
          (sqlite-execute db "INSERT INTO usage (ts, session, project, model, input, output, cache_read, cache_write, cost, turn, list_cost, billing) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                          (list (plist-get row :ts) (plist-get row :session) (plist-get row :project)
                                (plist-get row :model) (plist-get row :input) (plist-get row :output)
                                (plist-get row :cache-read) (plist-get row :cache-write)
                                (plist-get row :cost) (plist-get row :turn)
                                (plist-get row :list-cost) (plist-get row :billing)))
          (plist-put row :id (caar (sqlite-select db "SELECT last_insert_rowid()"))))
      (plist-put row :id (or (plist-get row :id) (harness-short-id)))
      (harness-call 'store/append harness-usage-jsonl-name row)
      row)))

(defun harness-usage--row-matches-p (row opts)
  "Non-nil when ROW satisfies the filters in OPTS.
Filters: `:since' (inclusive), `:until' (exclusive), `:project',
`:session', `:model' and `:billing' (\"\" selects rows without one)."
  (let ((ts (plist-get row :ts)))
    (and (or (null (plist-get opts :since)) (>= ts (plist-get opts :since)))
         (or (null (plist-get opts :until)) (< ts (plist-get opts :until)))
         (or (null (plist-get opts :project))
             (equal (harness-usage--root (plist-get opts :project)) (plist-get row :project)))
         (or (null (plist-get opts :session)) (equal (plist-get opts :session) (plist-get row :session)))
         (or (null (plist-get opts :model)) (equal (plist-get opts :model) (plist-get row :model)))
         (or (null (plist-get opts :billing))
             (equal (format "%s" (plist-get opts :billing)) (harness-usage--row-billing row))))))

(defun harness-usage--row-billing (row)
  "Return ROW's billing as a string, \"\" when it was not recorded."
  (let ((b (harness-billing-of row))) (if b (symbol-name b) "")))

(defun harness-usage--rows-sqlite (db opts)
  "Return rows from DB narrowed by the filters in OPTS."
  (let (where args)
    (when-let* ((v (plist-get opts :since))) (push "ts >= ?" where) (push v args))
    (when-let* ((v (plist-get opts :until))) (push "ts < ?" where) (push v args))
    (when-let* ((v (plist-get opts :project))) (push "project = ?" where) (push (harness-usage--root v) args))
    (when-let* ((v (plist-get opts :session))) (push "session = ?" where) (push v args))
    (when-let* ((v (plist-get opts :model))) (push "model = ?" where) (push v args))
    (mapcar (lambda (values)
              (cl-loop for k in harness-usage--columns for v in values append (list k v)))
            (sqlite-select db (concat harness-usage--select
                                      (if where (concat " WHERE " (string-join (nreverse where) " AND ")) "")
                                      " ORDER BY ts, id")
                           (nreverse args)))))

(defun harness-usage--rows-jsonl (_opts)
  "Return every row of the JSONL log."
  (harness-call 'store/read-all harness-usage-jsonl-name))

(defun harness-usage--rows (&rest opts)
  "Return usage rows matching OPTS, oldest first.
OPTS: `:since' `:until' (floats) `:project' ROOT `:session' ID `:model' ID
`:billing' NAME.
Rows come from SQLite when available, else from the JSONL log; the
Lisp filter applies to both."
  (let* ((db (harness-usage--db))
         (rows (if db (harness-usage--rows-sqlite db opts) (harness-usage--rows-jsonl opts)))
         (rows (cl-remove-if-not (lambda (r) (harness-usage--row-matches-p r opts)) rows)))
    (sort rows (lambda (a b) (< (plist-get a :ts) (plist-get b :ts))))))

(defun harness-usage--key (row group-by)
  "Return the GROUP-BY key of ROW."
  (pcase group-by
    ('project (or (plist-get row :project) ""))
    ('model (or (plist-get row :model) ""))
    ('session (or (plist-get row :session) ""))
    ('day (harness-usage-day-key (plist-get row :ts)))
    ('hour (harness-usage-hour-key (plist-get row :ts)))
    ('billing (harness-usage--row-billing row))
    (other (error "Unknown usage grouping %s" other))))

(defun harness-usage--aggregate (rows group-by)
  "Sum ROWS per GROUP-BY key (nil for one aggregate); first-seen order.
Rows recorded before list costs were kept count their cost as list cost."
  (let ((table (make-hash-table :test 'equal)) order)
    (dolist (r rows)
      (let* ((key (and group-by (harness-usage--key r group-by)))
             (agg (gethash key table)))
        (unless agg
          (setq agg (harness-usage--empty-aggregate key))
          (puthash key agg table)
          (push key order))
        (dolist (k '(:input :output :cache-read :cache-write :cost))
          (plist-put agg k (+ (plist-get agg k) (or (plist-get r k) 0))))
        (plist-put agg :list-cost (+ (plist-get agg :list-cost) (harness-usage-list-cost r)))
        (plist-put agg :calls (1+ (plist-get agg :calls)))))
    (mapcar (lambda (k) (gethash k table)) (nreverse order))))

(defun harness-usage--bucket-keys (bucket since until)
  "Return every BUCKET key from the bucket of SINCE through that of UNTIL."
  (let (keys)
    (pcase bucket
      ('day (let ((date (harness-usage--date since)) (last (harness-usage-day-key until)))
              (cl-loop repeat 100000
                       for key = (harness-usage--date-key date)
                       do (push key keys)
                       until (not (string< key last))
                       do (setq date (harness-usage--add-days date 1)))))
      ('hour (let ((ts (harness-usage--hour-start since)) (last (harness-usage-hour-key until)))
               (cl-loop repeat 1000000
                        for key = (harness-usage-hour-key ts)
                        do (unless (equal key (car keys)) (push key keys))
                        until (not (string< key last))
                        do (setq ts (+ ts 3600)))))
      (other (error "Unknown series bucket %s" other)))
    (nreverse keys)))

;;;; Recording

(defun harness-usage--countable-p (record)
  "Non-nil when RECORD carries tokens or a cost, not just a turn count."
  (cl-some (lambda (k) (numberp (plist-get record k)))
           '(:input :output :cache-read :cache-write :cost)))

(harness-defmethod usage/record (row)
  "Persist usage ROW and return it with `:id' set.
ROW: (:ts FLOAT :session ID :project ROOT :model ID :input N :output N
:cache-read N :cache-write N :cost F :list-cost F :billing NAME :turn N);
`:ts' defaults to now, `:list-cost' to the cost.  Event `usage/recorded'
ROW."
  (let ((row (harness-usage--insert (harness-usage--make-row row))))
    (harness-emit 'usage/recorded row)
    row))

(defun harness-usage--on-session-usage (id totals record)
  "Record RECORD of session ID; TOTALS supplies the turn counter.
Records that only carry `:turns' or `:context' are ignored.  A missing
cost is computed from the model's pricing, and so is a missing list
cost when a subscription paid.  Budgets are checked after."
  (when (and (harness-usage--countable-p record)
             (harness-call 'session/exists-p id))
    (let* ((session (harness-call 'session/get id))
           (model (plist-get session :model))
           (cost (plist-get record :cost))
           (cost (if (numberp cost) cost (harness-call 'usage/price model record)))
           (list-cost (plist-get record :list-cost))
           (billing (harness-billing-of record)))
      (harness-call 'usage/record
                    (list :session id :project (plist-get session :project) :model model
                          :input (plist-get record :input) :output (plist-get record :output)
                          :cache-read (plist-get record :cache-read) :cache-write (plist-get record :cache-write)
                          :cost cost
                          :list-cost (cond ((numberp list-cost) list-cost)
                                           ((eq billing 'subscription) (harness-call 'usage/price model record))
                                           (t cost))
                          :billing billing
                          :turn (plist-get totals :turns)))
      (harness-usage--check session))))

;;;; Queries

(harness-defmethod usage/summary (&rest opts)
  "Return usage aggregated by OPTS `:group-by'.
The grouping is project, model, day, session, hour or billing.
Other OPTS filter rows: `:since' `:until' (floats, until exclusive)
`:project' ROOT `:session' ID `:model' ID `:billing' NAME.  Each row is
\(:key STRING :input N :output N :cache-read N :cache-write N :cost F
:list-cost F :calls N), cost being what was billed and list cost the
same usage at API prices; billing keys are \"api\", \"subscription\",
\"extra-usage\", or \"\" when no billing was recorded.  Rows are sorted
by list cost descending, or by key ascending for day and hour."
  (let* ((group-by (harness-usage--sym (or (plist-get opts :group-by) 'project)))
         (aggs (harness-usage--aggregate (apply #'harness-usage--rows opts) group-by)))
    (if (memq group-by '(day hour))
        (sort aggs (lambda (a b) (string< (plist-get a :key) (plist-get b :key))))
      (sort aggs (lambda (a b)
                   (let ((la (plist-get a :list-cost)) (lb (plist-get b :list-cost)))
                     (or (> la lb) (and (= la lb) (> (plist-get a :cost) (plist-get b :cost))))))))))

(harness-defmethod usage/totals (&rest opts)
  "Return one aggregate of every row the filters in OPTS select.
The aggregate is (:input :output :cache-read :cache-write :cost
:list-cost :calls); OPTS are the filters of `usage/summary'."
  (harness-plist-remove (or (car (harness-usage--aggregate (apply #'harness-usage--rows opts) nil))
                            (harness-usage--empty-aggregate nil))
                        :key))

(harness-defmethod usage/series (&rest opts)
  "Return a continuous time series of usage per OPTS `:bucket' (day|hour).
Buckets run from `:since' (default: the first row) through `:until'
\(default: now) with empty buckets filled in, so charts are continuous.
The other filters of `usage/summary' apply.  Each point is
\(:key STRING :cost F :list-cost F :input N :output N :cache-read N
:cache-write N :calls N).
Return nil when there are no rows and no `:since'."
  (let* ((bucket (harness-usage--sym (or (plist-get opts :bucket) 'day)))
         (rows (apply #'harness-usage--rows opts))
         (since (or (plist-get opts :since) (and rows (plist-get (car rows) :ts))))
         (until (or (plist-get opts :until) (float-time)))
         (table (make-hash-table :test 'equal)))
    (when since
      (dolist (a (harness-usage--aggregate rows bucket))
        (puthash (plist-get a :key) a table))
      (mapcar (lambda (key) (or (gethash key table) (harness-usage--empty-aggregate key)))
              (harness-usage--bucket-keys bucket since until)))))

;;;; Budgets

(defun harness-usage--normalise-budget (budget)
  "Return a fresh copy of BUDGET with symbols interned and defaults filled.
A `:baseline' of nil, false or 0 is none, so both baseline keys go; a
budget without a period keeps no `:baseline-period-start', and a period
budget's one becomes the start date of the period it falls in."
  (let* ((scope (harness-usage--sym (plist-get budget :scope)))
         (target (plist-get budget :target))
         (amount (plist-get budget :amount))
         (period (harness-usage--sym (plist-get budget :period)))
         (baseline (plist-get budget :baseline))
         (since (plist-get budget :baseline-period-start))
         (b (harness-plist-merge
             budget
             (list :scope scope
                   :period period
                   :days (or (harness-usage--sym (plist-get budget :days)) 'all)
                   :hard (harness-json-true-p (plist-get budget :hard))
                   :target (if (and target (memq scope '(project period))) (harness-usage--root target) target)
                   :amount (float (if (numberp amount) amount 0))))))
    (cond
     ((or (not (harness-json-true-p baseline)) (and (numberp baseline) (zerop baseline)))
      (harness-plist-remove b :baseline :baseline-period-start))
     ((or (null period) (null since))
      (harness-plist-remove (plist-put b :baseline (if (numberp baseline) (float baseline) baseline))
                            :baseline-period-start))
     (t (plist-put (plist-put b :baseline (if (numberp baseline) (float baseline) baseline))
                   :baseline-period-start (harness-usage--period-start-key since period))))))

(defun harness-usage--validate-budget (budget)
  "Signal an error when BUDGET is malformed."
  (unless (memq (plist-get budget :scope) '(session project period))
    (error "Budget scope must be session, project or period"))
  (unless (numberp (plist-get budget :amount)) (error "Budget needs a numeric :amount"))
  (unless (memq (plist-get budget :period) '(nil day week month))
    (error "Budget period must be day, week or month"))
  (unless (memq (plist-get budget :days) '(all business))
    (error "Budget :days must be all or business"))
  (when (and (eq (plist-get budget :scope) 'period) (null (plist-get budget :period)))
    (error "A period budget needs a :period"))
  (when (and (memq (plist-get budget :scope) '(session project)) (null (plist-get budget :target)))
    (error "A %s budget needs a :target" (plist-get budget :scope)))
  (let ((baseline (plist-get budget :baseline))
        (since (plist-get budget :baseline-period-start)))
    (unless (or (null baseline) (and (numberp baseline) (>= baseline 0)))
      (error "Budget :baseline must be an amount of at least 0"))
    (unless (or (null since) (harness-usage--parse-date since))
      (error "Budget :baseline-period-start must be a YYYY-MM-DD date"))))

(defun harness-usage--save-budgets ()
  "Write `harness-usage-budgets' to budgets.json."
  (harness-call 'store/save harness-usage-budgets-name (harness-json-array harness-usage-budgets)))

(defun harness-usage--load-budgets ()
  "Load budgets.json into `harness-usage-budgets'."
  (setq harness-usage-budgets
        (mapcar #'harness-usage--normalise-budget
                (cl-remove-if-not #'listp (harness-call 'store/load harness-usage-budgets-name)))))

(defun harness-usage--implicit-budget (session)
  "Return SESSION's own `:budget' as a budget plist, or nil."
  (let ((b (plist-get session :budget)))
    (when (and (listp b) (numberp (plist-get b :amount)))
      (list :id (concat "session:" (plist-get session :id)) :scope 'session
            :target (plist-get session :id) :amount (float (plist-get b :amount))
            :hard (harness-json-true-p (plist-get b :hard)) :days 'all
            :label "session" :implicit t))))

(defun harness-usage--find-budget (id)
  "Return the budget with ID: an explicit one, or a session's implicit one."
  (cond
   ((and (listp id) (plist-get id :scope)) (harness-usage--normalise-budget id))
   ((cl-find id harness-usage-budgets :key (lambda (b) (plist-get b :id)) :test #'equal))
   ((and (stringp id) (string-prefix-p "session:" id) (harness-method-exists-p 'session/exists-p))
    (let ((sid (string-remove-prefix "session:" id)))
      (and (harness-call 'session/exists-p sid)
           (harness-usage--implicit-budget (harness-call 'session/get sid)))))))

(defun harness-usage--budget-filter (budget)
  "Return the row filters that select BUDGET's spending."
  (let ((target (plist-get budget :target)))
    (pcase (plist-get budget :scope)
      ('session (list :session target))
      ('project (list :project target))
      ('period (and target (list :project target))))))

(defun harness-usage--project-name (root)
  "Return a display name for project ROOT."
  (if (harness-method-exists-p 'project/name) (harness-call 'project/name root) root))

(defun harness-usage-budget-label (budget)
  "Return a short human label for BUDGET."
  (or (plist-get budget :label)
      (let ((period (pcase (plist-get budget :period)
                      ('day "daily") ('week "weekly") ('month "monthly") (_ nil)))
            (target (plist-get budget :target)))
        (pcase (plist-get budget :scope)
          ('session (string-join (delq nil (list "session" period)) " "))
          ('project (string-join (delq nil (list "project" (harness-usage--project-name target) period)) " "))
          ('period (concat (or period "period")
                           (if target (format " for %s" (harness-usage--project-name target)) "")))
          (_ (or (plist-get budget :id) "budget"))))))

(defun harness-usage--applied-baseline (budget bounds)
  "Return how much of BUDGET's `:baseline' counts in the period BOUNDS.
BOUNDS is (START-DATE . END-DATE), or nil for a budget without a
period, whose baseline always counts.  A period budget's baseline
counts only in the period starting on its `:baseline-period-start'."
  (let ((baseline (plist-get budget :baseline)))
    (if (and (numberp baseline) (> baseline 0)
             (or (null bounds)
                 (equal (plist-get budget :baseline-period-start)
                        (harness-usage--date-key (car bounds)))))
        (float baseline)
      0.0)))

(defun harness-usage--budget-status (budget &optional now)
  "Compute the status plist of BUDGET as of NOW (default: current time).
What was spent is the cost of the rows the budget selects plus the
baseline that counts in the current period."
  (let* ((now (or now (float-time)))
         (period (plist-get budget :period))
         (bounds (and period (harness-usage-period-bounds period now)))
         (start (and bounds (harness-usage--day-start (car bounds))))
         (end (and bounds (harness-usage--day-start (cdr bounds))))
         (rows (apply #'harness-usage--rows
                      (append (harness-usage--budget-filter budget)
                              (and bounds (list :since start :until end)))))
         (baseline (harness-usage--applied-baseline budget bounds))
         (spent (+ baseline
                   (plist-get (or (car (harness-usage--aggregate rows nil))
                                  (harness-usage--empty-aggregate nil))
                              :cost)))
         (amount (float (or (plist-get budget :amount) 0)))
         (remaining (max 0.0 (- amount spent)))
         (days-left (and bounds
                         (cl-count-if (lambda (d) (harness-usage--counted-day-p d period (plist-get budget :days)))
                                      (harness-usage--dates-between (harness-usage--date now) (cdr bounds))))))
    (list :budget budget :spent spent :amount amount :remaining remaining
          :fraction (if (> amount 0) (/ spent amount) 1.0)
          :hard (harness-json-true-p (plist-get budget :hard))
          :per-day (and days-left (if (> days-left 0) (/ remaining days-left) 0.0))
          :days-left days-left :period-start start :period-end end
          :baseline baseline)))

(harness-defmethod usage/budgets ()
  "Return every explicit budget plist."
  harness-usage-budgets)

(harness-defmethod usage/set-budget (budget)
  "Add BUDGET, or replace the budget with the same `:id'.  Return it.
BUDGET: (:id :scope session|project|period :target SESSION-ID|ROOT|nil
:amount USD :hard BOOL :period day|week|month :days business|all
:label :baseline USD :baseline-period-start DATE).  A missing `:id' and
`:created' are generated.  `:baseline' is what was spent that the
harness did not record; nil or 0 clears it.  A period budget's baseline
counts only in the period starting on `:baseline-period-start' (a
YYYY-MM-DD date or a float time, moved to the start of its period),
which defaults to the period containing now; without a period it
always counts.  Event `usage/budgets-changed' BUDGETS."
  (let* ((b (harness-usage--normalise-budget budget))
         (id (or (plist-get b :id) (harness-short-id))))
    (harness-usage--validate-budget b)
    (setq b (plist-put b :id id))
    (setq b (plist-put b :created (or (plist-get b :created) (float-time))))
    (when (and (plist-get b :baseline) (plist-get b :period) (null (plist-get b :baseline-period-start)))
      (setq b (plist-put b :baseline-period-start
                         (harness-usage--period-start-key (float-time) (plist-get b :period)))))
    (setq harness-usage-budgets
          (append (cl-remove id harness-usage-budgets :key (lambda (x) (plist-get x :id)) :test #'equal)
                  (list b)))
    (harness-usage--save-budgets)
    (harness-emit 'usage/budgets-changed harness-usage-budgets)
    b))

(harness-defmethod usage/remove-budget (id)
  "Remove the budget ID.  Return non-nil when one was removed."
  (let ((before (length harness-usage-budgets)))
    (setq harness-usage-budgets
          (cl-remove id harness-usage-budgets :key (lambda (x) (plist-get x :id)) :test #'equal))
    (when (< (length harness-usage-budgets) before)
      (harness-usage--save-budgets)
      (harness-emit 'usage/budgets-changed harness-usage-budgets)
      t)))

(harness-defmethod usage/budget-status (id &rest opts)
  "Return the status of budget ID (or of a BUDGET plist passed as ID).
\"session:SID\" names the implicit budget of session SID.  OPTS `:now'
fixes the reference time.  Result: (:budget B :spent F :amount F
:remaining F :fraction F :hard BOOL :per-day F :days-left N
:period-start FLOAT :period-end FLOAT :baseline F); the period fields
are nil for budgets without a `:period'.  Period budgets count spending
inside the current calendar day, week (from Monday) or month and split
the remainder over the remaining days (Monday to Friday when `:days' is
`business').  `:spent' includes `:baseline', the part of the budget's
baseline that counts now: all of it in the period it was set for, or
always for a budget without a period; 0 otherwise."
  (let ((budget (harness-usage--find-budget id)))
    (unless budget (error "No budget %s" id))
    (harness-usage--budget-status budget (plist-get opts :now))))

(harness-defmethod usage/plan-budget (amount period days &optional now)
  "Split AMOUNT over the calendar PERIOD (day|week|month) containing NOW.
Return ((:date \"YYYY-MM-DD\" :allowance F) …) for every date of the
period; when DAYS is `business' weekends get an allowance of 0."
  (let* ((period (harness-usage--sym period))
         (days (or (harness-usage--sym days) 'all))
         (bounds (harness-usage-period-bounds period now))
         (dates (harness-usage--dates-between (car bounds) (cdr bounds)))
         (counted (cl-count-if (lambda (d) (harness-usage--counted-day-p d period days)) dates))
         (each (if (> counted 0) (/ (float amount) counted) 0.0)))
    (mapcar (lambda (d)
              (list :date (harness-usage--date-key d)
                    :allowance (if (harness-usage--counted-day-p d period days) each 0.0)))
            dates)))

;;;; Enforcement

(defun harness-usage--session-budgets (session)
  "Return every budget that applies to SESSION, implicit one last."
  (let ((sid (plist-get session :id))
        (project (plist-get session :project))
        out)
    (dolist (b harness-usage-budgets)
      (let ((target (plist-get b :target)))
        (when (pcase (plist-get b :scope)
                ('session (equal target sid))
                ('project (equal target project))
                ('period (or (null target) (equal target project))))
          (push b out))))
    (let ((implicit (harness-usage--implicit-budget session)))
      (when implicit (push implicit out)))
    (nreverse out)))

(harness-defmethod usage/session-budgets (session-id &rest opts)
  "Return the status of every budget applying to SESSION-ID.
OPTS `:now' fixes the reference time."
  (mapcar (lambda (b) (harness-usage--budget-status b (plist-get opts :now)))
          (harness-usage--session-budgets (harness-call 'session/get session-id))))

(defun harness-usage--warn (sid budget status threshold text)
  "Warn once per period about BUDGET reaching THRESHOLD for session SID.
Emits `usage/budget-warning' with STATUS and adds TEXT as a hint."
  (let* ((key (format "%s/%s/%s" sid (plist-get budget :id) (or (plist-get status :period-start) 0)))
         (done (gethash key harness-usage--warned)))
    (unless (member threshold done)
      (dolist (th (list harness-usage-warn-fraction 1.0))
        (when (<= th threshold) (cl-pushnew th done :test #'equal)))
      (puthash key done harness-usage--warned)
      (harness-emit 'usage/budget-warning sid budget status)
      (when (harness-method-exists-p 'session/hint)
        (harness-call 'session/hint sid text)))))

(defun harness-usage--check (session &optional now)
  "Evaluate SESSION's budgets as of NOW; warn on crossings.
Return the reason a hard budget blocks the next turn, or nil."
  (let ((sid (plist-get session :id)) reason)
    (dolist (b (harness-usage--session-budgets session))
      (let* ((st (harness-usage--budget-status b now))
             (fraction (plist-get st :fraction))
             (label (harness-usage-budget-label b))
             (spent (concat (harness-format-cost (plist-get st :spent))
                            (if (> (plist-get st :baseline) 0)
                                (format " (incl. %s baseline)" (harness-format-cost (plist-get st :baseline)))
                              "")))
             (amount (harness-format-cost (plist-get st :amount))))
        (cond
         ((and (plist-get st :hard) (>= fraction 1.0))
          (unless reason
            (setq reason (format "Budget %s exhausted: spent %s of %s" label spent amount))))
         ((>= fraction 1.0)
          (harness-usage--warn sid b st 1.0 (format "Budget %s exceeded: spent %s of %s" label spent amount)))
         ((>= fraction harness-usage-warn-fraction)
          (harness-usage--warn sid b st harness-usage-warn-fraction
                               (format "Budget %s at %d%%: spent %s of %s"
                                       label (round (* 100 fraction)) spent amount))))))
    reason))

(defun harness-usage--before-turn (value next session)
  "`agent/before-turn' handler: refuse the turn when a hard budget is spent.
VALUE is the gate so far, NEXT continues the chain, SESSION is the plist."
  (if (not (plist-get value :proceed))
      (funcall next value)
    (let ((reason (condition-case err (harness-usage--check session)
                    (error (harness-log 'error "usage: budget check failed: %S" err) nil))))
      (funcall next (if reason (list :proceed nil :reason reason) value)))))

;;;; Module

(defun harness-usage--init ()
  "Create the schema, load budgets and hook into the bus."
  (harness-usage--db)
  (harness-usage--load-budgets)
  (harness-on 'session/usage #'harness-usage--on-session-usage)
  (harness-add-filter 'agent/before-turn #'harness-usage--before-turn 30))

(harness-declare-event 'usage/recorded "(ROW) after a usage row is stored.")
(harness-declare-event 'usage/budget-warning "(SESSION-ID BUDGET STATUS) when a budget crosses 80% or 100%.")
(harness-declare-event 'usage/budgets-changed "(BUDGETS) after a budget is added, replaced or removed.")

(harness-define-module 'usage
  :doc "Cost accounting, usage summaries and budgets."
  :requires '(store session provider)
  :init #'harness-usage--init)

(provide 'harness-usage)
;;; harness-usage.el ends here
