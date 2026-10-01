;;; harness-usage-test.el --- Tests for cost accounting and budgets  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defmacro harness-usage-test-with (&rest body)
  "Load the state layer with the demo provider and the usage module, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent usage))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-usage--warned)
     (let ((harness-provider-demo-delay 0.005)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ;; Warm the model catalogue so the demo model's pricing is known.
       (harness-await (harness-call 'provider/models t))
       ,@body)))

(defun harness-usage-test-session (&rest plist)
  "Create a demo session in a fresh directory; PLIST adds settings.  Return its id."
  (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted" plist) :id))

(defun harness-usage-test-ts (year month day &optional hour)
  "Return the float time of YEAR MONTH DAY at HOUR (default 12) local time."
  (float-time (encode-time (list 0 0 (or hour 12) day month year nil -1 nil))))

(defun harness-usage-test-near (a b)
  "Non-nil when floats A and B are equal within rounding."
  (< (abs (- a b)) 1e-9))

(defun harness-usage-test-seed ()
  "Record a fixed set of rows across two projects, two models and three days.
Return (PROJECT-A PROJECT-B)."
  (let ((pa "/tmp/harness-usage-a/") (pb "/tmp/harness-usage-b/"))
    (harness-call 'usage/record (list :ts (harness-usage-test-ts 2026 9 1) :session "s1" :project pa
                                      :model "demo:scripted" :input 100 :output 10 :cost 1.0))
    (harness-call 'usage/record (list :ts (harness-usage-test-ts 2026 9 1 15) :session "s1" :project pa
                                      :model "demo:other" :input 200 :output 20 :cache-read 50 :cost 2.0))
    (harness-call 'usage/record (list :ts (harness-usage-test-ts 2026 9 3) :session "s2" :project pb
                                      :model "demo:scripted" :input 300 :output 30 :cache-write 5 :cost 4.0))
    (list pa pb)))

;;;; Recording and pricing

(ert-deftest harness-usage-records-and-prices ()
  (harness-usage-test-with
    (let* ((id (harness-usage-test-session))
           (recorded nil))
      (harness-on 'usage/recorded (lambda (row) (push row recorded)))
      ;; No cost from the provider: priced from the demo model's pricing.
      (harness-call 'session/usage-add id '(:input 1000 :output 500 :cache-read 2000 :cache-write 100 :cost nil :context 3000))
      ;; A provider-reported cost is kept as is.
      (harness-call 'session/usage-add id '(:input 10 :output 1 :cost 0.01))
      ;; Turn counters alone are not calls.
      (harness-call 'session/usage-add id '(:turns 1))
      (should (= 2 (length recorded)))
      (let ((first (car (last recorded))) (second (car recorded)))
        (should (harness-usage-test-near (plist-get first :cost) 0.002325))
        (should (= 2000 (plist-get first :cache-read)))
        (should (equal id (plist-get first :session)))
        (should (equal "demo:scripted" (plist-get first :model)))
        (should (plist-get first :id))
        (should (= 0.01 (plist-get second :cost))))
      (let ((rows (harness-call 'usage/summary :group-by 'session)))
        (should (= 1 (length rows)))
        (should (equal id (plist-get (car rows) :key)))
        (should (= 2 (plist-get (car rows) :calls)))
        (should (= 1010 (plist-get (car rows) :input)))
        (should (harness-usage-test-near (plist-get (car rows) :cost) 0.012325)))
      (should (= 0.0 (harness-call 'usage/price "nobody:unknown" '(:input 100))))
      (should (harness-usage-test-near 0.0000031 (harness-call 'usage/price "demo:scripted" '(:input 1 :output 1 :cache-read 1)))))))

(ert-deftest harness-usage-agent-turn-records-row ()
  (harness-usage-test-with
    (let ((id (harness-usage-test-session)))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "hello")) :stop-reason)))
      (let ((totals (harness-call 'usage/totals :session id)))
        (should (= 1 (plist-get totals :calls)))
        (should (= 400 (plist-get totals :input)))
        (should (= 30 (plist-get totals :output)))
        (should (harness-usage-test-near 0.0008 (plist-get totals :cost))))
      (should (equal (plist-get (harness-call 'session/get id) :project)
                     (plist-get (car (harness-call 'usage/summary :group-by 'project)) :key))))))

;;;; Summaries, totals, series

(ert-deftest harness-usage-summaries-and-totals ()
  (harness-usage-test-with
    (pcase-let ((`(,pa ,pb) (harness-usage-test-seed)))
      (let ((by-project (harness-call 'usage/summary :group-by 'project)))
        (should (equal (list pb pa) (mapcar (lambda (r) (plist-get r :key)) by-project)))
        (should (= 4.0 (plist-get (car by-project) :cost)))
        (should (= 3.0 (plist-get (cadr by-project) :cost)))
        (should (= 2 (plist-get (cadr by-project) :calls)))
        (should (= 300 (plist-get (cadr by-project) :input)))
        (should (= 50 (plist-get (cadr by-project) :cache-read))))
      (let ((by-model (harness-call 'usage/summary :group-by "model")))
        (should (equal '("demo:scripted" "demo:other") (mapcar (lambda (r) (plist-get r :key)) by-model)))
        (should (= 5.0 (plist-get (car by-model) :cost))))
      (let ((by-day (harness-call 'usage/summary :group-by 'day)))
        (should (equal (list (harness-usage-day-key (harness-usage-test-ts 2026 9 1))
                             (harness-usage-day-key (harness-usage-test-ts 2026 9 3)))
                       (mapcar (lambda (r) (plist-get r :key)) by-day)))
        (should (= 2 (plist-get (car by-day) :calls))))
      ;; Filters: project, session, time window (until is exclusive).
      (should (= 1 (length (harness-call 'usage/summary :group-by 'model :project pb))))
      (should (= 3.0 (plist-get (harness-call 'usage/totals :project pa) :cost)))
      (should (= 2.0 (plist-get (harness-call 'usage/totals :session "s1" :model "demo:other") :cost)))
      (should (= 1 (plist-get (harness-call 'usage/totals
                                            :since (harness-usage-test-ts 2026 9 1 13)
                                            :until (harness-usage-test-ts 2026 9 3))
                              :calls)))
      (let ((all (harness-call 'usage/totals)))
        (should (= 3 (plist-get all :calls)))
        (should (= 600 (plist-get all :input)))
        (should (= 60 (plist-get all :output)))
        (should (= 7.0 (plist-get all :cost)))
        (should-not (plist-member all :key)))
      (should (= 0 (plist-get (harness-call 'usage/totals :project "/nowhere/") :calls))))))

(ert-deftest harness-usage-series-fills-gaps ()
  (harness-usage-test-with
    (harness-usage-test-seed)
    (let ((series (harness-call 'usage/series :bucket 'day
                                :since (harness-usage-test-ts 2026 9 1 0)
                                :until (harness-usage-test-ts 2026 9 4))))
      (should (= 4 (length series)))
      (should (equal '("2026-09-01" "2026-09-02" "2026-09-03" "2026-09-04")
                     (mapcar (lambda (p) (plist-get p :key)) series)))
      (should (equal '(3.0 0.0 4.0 0.0) (mapcar (lambda (p) (plist-get p :cost)) series)))
      (should (equal '(300 0 300 0) (mapcar (lambda (p) (plist-get p :input)) series))))
    ;; Without :since the series starts at the first row.
    (let ((series (harness-call 'usage/series :bucket 'day :until (harness-usage-test-ts 2026 9 2))))
      (should (equal '("2026-09-01" "2026-09-02") (mapcar (lambda (p) (plist-get p :key)) series))))
    (let ((hours (harness-call 'usage/series :bucket 'hour
                               :since (harness-usage-test-ts 2026 9 1 12)
                               :until (+ 1800 (harness-usage-test-ts 2026 9 1 15)))))
      (should (= 4 (length hours)))
      (should (equal '(1.0 0.0 0.0 2.0) (mapcar (lambda (p) (plist-get p :cost)) hours))))
    ;; No rows and no window: nothing to draw.
    (should (null (harness-call 'usage/series :bucket 'day :project "/nowhere/")))))

;;;; Budgets

(ert-deftest harness-usage-budgets-crud-persist ()
  (harness-usage-test-with
    (let* ((changes 0)
           (root (harness-test-temp-dir)))
      (harness-on 'usage/budgets-changed (lambda (_) (cl-incf changes)))
      (let ((b (harness-call 'usage/set-budget (list :scope "project" :target (directory-file-name root)
                                                     :amount 50 :hard t))))
        (should (stringp (plist-get b :id)))
        (should (numberp (plist-get b :created)))
        (should (eq 'project (plist-get b :scope)))
        (should (equal root (plist-get b :target)))
        (should (= 50.0 (plist-get b :amount)))
        (should (= 1 (length (harness-call 'usage/budgets))))
        ;; Persisted as JSON and reloaded with symbols restored.
        (let ((on-disk (harness-call 'store/load "budgets.json")))
          (should (= 1 (length on-disk)))
          (should (equal "project" (plist-get (car on-disk) :scope))))
        (setq harness-usage-budgets nil)
        (harness-usage--load-budgets)
        (should (equal b (car harness-usage-budgets)))
        ;; Replace by id.
        (harness-call 'usage/set-budget (plist-put (copy-sequence b) :amount 75))
        (should (= 1 (length (harness-call 'usage/budgets))))
        (should (= 75.0 (plist-get (car (harness-call 'usage/budgets)) :amount)))
        (harness-call 'usage/set-budget '(:scope period :period month :amount 10))
        (should (= 2 (length (harness-call 'usage/budgets))))
        (should (harness-call 'usage/remove-budget (plist-get b :id)))
        (should-not (harness-call 'usage/remove-budget "missing"))
        (should (= 1 (length (harness-call 'store/load "budgets.json"))))
        (should (= 4 changes)))
      (should-error (harness-call 'usage/set-budget '(:scope period :amount 1)))
      (should-error (harness-call 'usage/set-budget '(:scope session :amount 1)))
      (should-error (harness-call 'usage/set-budget '(:scope global :amount 1)))
      (should-error (harness-call 'usage/budget-status "missing")))))

(ert-deftest harness-usage-period-budget-status-business-days ()
  (harness-usage-test-with
    ;; Wednesday 2026-09-16 at noon.  Rows: Tue 15th (this week) and Sat 12th (last week).
    (let* ((now (harness-usage-test-ts 2026 9 16))
           (budget (harness-call 'usage/set-budget '(:scope period :period week :days business :amount 100)))
           (id (plist-get budget :id)))
      (should (= 3 (harness-usage--weekday (list 2026 9 16))))
      (harness-call 'usage/record (list :ts (harness-usage-test-ts 2026 9 15) :session "s" :project "/p/" :model "m" :cost 10.0))
      (harness-call 'usage/record (list :ts (harness-usage-test-ts 2026 9 12) :session "s" :project "/p/" :model "m" :cost 50.0))
      (let ((st (harness-call 'usage/budget-status id :now now)))
        (should (= 10.0 (plist-get st :spent)))
        (should (= 100.0 (plist-get st :amount)))
        (should (= 90.0 (plist-get st :remaining)))
        (should (harness-usage-test-near 0.1 (plist-get st :fraction)))
        (should (= 3 (plist-get st :days-left)))        ; Wed, Thu, Fri
        (should (= 30.0 (plist-get st :per-day)))
        (should (= (harness-usage-test-ts 2026 9 14 0) (plist-get st :period-start)))
        (should (= (harness-usage-test-ts 2026 9 21 0) (plist-get st :period-end)))
        (should-not (plist-get st :hard))
        (should (equal budget (plist-get st :budget))))
      ;; All days of the month: 16th through 30th remain.
      (let* ((mb (harness-call 'usage/set-budget '(:scope period :period month :days all :amount 120)))
             (st (harness-call 'usage/budget-status (plist-get mb :id) :now now)))
        (should (= 60.0 (plist-get st :spent)))
        (should (= 15 (plist-get st :days-left)))
        (should (= 4.0 (plist-get st :per-day)))
        (should (= (harness-usage-test-ts 2026 9 1 0) (plist-get st :period-start)))
        (should (= (harness-usage-test-ts 2026 10 1 0) (plist-get st :period-end))))
      ;; A day budget on a Saturday still counts its one day.
      (let ((st (harness-call 'usage/budget-status '(:scope period :period day :days business :amount 8)
                              :now (harness-usage-test-ts 2026 9 12))))
        (should (= 50.0 (plist-get st :spent)))
        (should (= 1 (plist-get st :days-left)))
        (should (= 0.0 (plist-get st :per-day)))
        (should (= 1 (plist-get st :days-left))))
      ;; Non-period budgets have no window.
      (let ((st (harness-call 'usage/budget-status '(:scope project :target "/p/" :amount 100) :now now)))
        (should (= 60.0 (plist-get st :spent)))
        (should-not (plist-get st :period-start))
        (should-not (plist-get st :days-left))
        (should-not (plist-get st :per-day)))
      ;; Planning table for September 2026: 30 dates, 22 business days.
      (let ((plan (harness-call 'usage/plan-budget 220 'month 'business now)))
        (should (= 30 (length plan)))
        (should (equal "2026-09-01" (plist-get (car plan) :date)))
        (should (equal "2026-09-30" (plist-get (car (last plan)) :date)))
        (should (= 22 (cl-count-if (lambda (p) (> (plist-get p :allowance) 0)) plan)))
        (should (= 10.0 (plist-get (car plan) :allowance)))
        (should (= 0.0 (plist-get (nth 4 plan) :allowance)))   ; Saturday the 5th
        (should (harness-usage-test-near 220.0 (apply #'+ (mapcar (lambda (p) (plist-get p :allowance)) plan)))))
      (let ((plan (harness-call 'usage/plan-budget 70 "week" "all" now)))
        (should (= 7 (length plan)))
        (should (equal "2026-09-14" (plist-get (car plan) :date)))
        (should (cl-every (lambda (p) (= 10.0 (plist-get p :allowance))) plan))))))

;;;; Enforcement

(defun harness-usage-test-hints (id)
  "Return the hint texts of session ID."
  (cl-loop for n in (harness-call 'session/nodes id)
           when (eq (plist-get n :kind) 'hint) collect (plist-get n :content)))

(ert-deftest harness-usage-hard-session-budget-blocks ()
  (harness-usage-test-with
    (let ((id (harness-usage-test-session :budget '(:amount 0.0005 :hard t))))
      ;; Nothing spent yet: the first turn runs and costs $0.0008.
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "hello")) :stop-reason)))
      (let ((r (harness-await (harness-call 'agent/prompt id "again"))))
        (should (eq 'blocked (plist-get r :stop-reason)))
        (should (string-match-p "Budget session exhausted" (plist-get r :error))))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status)))
      (should (cl-some (lambda (h) (string-match-p "Turn not started: Budget session exhausted: spent \\$0.0008 of \\$0.0005" h))
                       (harness-usage-test-hints id)))
      (let ((st (car (harness-call 'usage/session-budgets id))))
        (should (plist-get st :hard))
        (should (> (plist-get st :fraction) 1.0))
        (should (equal (concat "session:" id) (plist-get (plist-get st :budget) :id))))
      ;; A hard project budget blocks a fresh session in the same project.
      (let* ((project (plist-get (harness-call 'session/get id) :project))
             (other (plist-get (harness-call 'session/create :cwd project :model "demo:scripted") :id)))
        (harness-call 'usage/set-budget (list :scope 'project :target project :amount 0.0001 :hard t))
        (should (eq 'blocked (plist-get (harness-await (harness-call 'agent/prompt other "hello")) :stop-reason)))
        (should (= 0 (plist-get (harness-call 'usage/totals :session other) :calls)))))))

(ert-deftest harness-usage-soft-budget-warns-once ()
  (harness-usage-test-with
    (let ((id (harness-usage-test-session :budget '(:amount 0.0005)))
          (warnings nil))
      (harness-on 'usage/budget-warning (lambda (sid b st) (push (list sid b st) warnings)))
      (harness-await (harness-call 'agent/prompt id "hello"))
      (should (= 1 (length warnings)))
      (should (equal id (car (car warnings))))
      (should (eq 'session (plist-get (cadr (car warnings)) :scope)))
      (should (> (plist-get (caddr (car warnings)) :fraction) 1.0))
      ;; A soft budget never blocks, and the warning is not repeated.
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "hello")) :stop-reason)))
      (should (= 1 (length warnings)))
      (should (= 1 (cl-count-if (lambda (h) (string-match-p "Budget session exceeded" h))
                                (harness-usage-test-hints id))))
      ;; An 80% crossing warns separately from the 100% one.
      (let ((wid (harness-usage-test-session :budget '(:amount 0.002))))
        (harness-await (harness-call 'agent/prompt wid "hello"))  ; 0.0008 → 40%
        (should (= 1 (length warnings)))
        (harness-await (harness-call 'agent/prompt wid "hello"))  ; 0.0016 → 80%
        (should (= 2 (length warnings)))
        (should (cl-some (lambda (h) (string-match-p "Budget session at 80%" h)) (harness-usage-test-hints wid)))
        (harness-await (harness-call 'agent/prompt wid "hello"))  ; 0.0024 → 120%
        (should (= 3 (length warnings)))
        (harness-await (harness-call 'agent/prompt wid "hello"))
        (should (= 3 (length warnings)))))))

;;;; Billing

(ert-deftest harness-usage-subscription-calls-cost-nothing ()
  "Calls a plan pays for are free; their API price is kept as list cost."
  (harness-usage-test-with
    (let* ((id (harness-usage-test-session :budget '(:amount 0.005 :hard t)))
           (price (harness-call 'usage/price "demo:scripted" '(:input 100000 :output 50000))))
      (harness-call 'session/usage-add id
                    '(:input 100000 :output 50000 :cost 0.0 :billing subscription :plan "max"))
      (let ((u (plist-get (harness-call 'session/get id) :usage)))
        (should (= 0.0 (plist-get u :cost)))
        (should (harness-usage-test-near price (plist-get u :list-cost)))
        (should (eq 'subscription (plist-get u :billing)))
        (should (equal "max" (plist-get u :plan))))
      ;; The plan's call spends none of the hard budget, so the next turn may run.
      (should-not (harness-usage--check (harness-call 'session/get id)))
      (harness-call 'session/usage-add id '(:input 10 :output 1 :cost 0.01 :billing api))
      (let ((u (plist-get (harness-call 'session/get id) :usage)))
        (should (harness-usage-test-near 0.01 (plist-get u :cost)))
        (should (harness-usage-test-near (+ price 0.01) (plist-get u :list-cost)))
        (should (eq 'api (plist-get u :billing))))
      (should (harness-usage--check (harness-call 'session/get id)))
      ;; Rows keep both figures and group by who paid.
      (let* ((rows (harness-call 'usage/summary :group-by 'billing))
             (sub (cl-find "subscription" rows :key (lambda (r) (plist-get r :key)) :test #'equal))
             (api (cl-find "api" rows :key (lambda (r) (plist-get r :key)) :test #'equal)))
        (should (= 2 (length rows)))
        (should (equal sub (car rows)))
        (should (= 0.0 (plist-get sub :cost)))
        (should (harness-usage-test-near price (plist-get sub :list-cost)))
        (should (harness-usage-test-near 0.01 (plist-get api :cost)))
        (should (harness-usage-test-near 0.01 (plist-get api :list-cost))))
      (let ((totals (harness-call 'usage/totals :session id)))
        (should (harness-usage-test-near 0.01 (plist-get totals :cost)))
        (should (harness-usage-test-near (+ price 0.01) (plist-get totals :list-cost))))
      (should (= 1 (plist-get (harness-call 'usage/totals :billing "subscription") :calls)))
      (should (= 0 (plist-get (harness-call 'usage/totals :billing "") :calls)))
      (let ((day (car (last (harness-call 'usage/series :bucket 'day :since (- (float-time) 60))))))
        (should (harness-usage-test-near (+ price 0.01) (plist-get day :list-cost)))))))

(ert-deftest harness-usage-old-database-gains-billing-columns ()
  "A usage table from before billing was kept is migrated in place."
  (harness-usage-test-with
    (when-let* ((db (harness-call 'store/sqlite)))
      (sqlite-execute db "DROP TABLE usage")
      (sqlite-execute db "CREATE TABLE usage (id INTEGER PRIMARY KEY, ts REAL, session TEXT, project TEXT, model TEXT, input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER, cost REAL, turn INTEGER)")
      (sqlite-execute db "INSERT INTO usage (ts, session, project, model, input, output, cache_read, cache_write, cost, turn) VALUES (?, 's0', '/p/', 'm', 1, 1, 0, 0, 2.5, 1)"
                      (list (float-time)))
      ;; As after a reload of the module with an older schema in use.
      (setq harness-usage--schema-db db)
      (harness-call 'usage/record '(:session "s1" :project "/p/" :model "m" :input 1
                                    :cost 0.0 :list-cost 1.0 :billing subscription))
      (let ((columns (mapcar #'cadr (sqlite-select db "PRAGMA table_info(usage)"))))
        (should (member "list_cost" columns))
        (should (member "billing" columns)))
      (let ((totals (harness-call 'usage/totals :project "/p/")))
        (should (= 2 (plist-get totals :calls)))
        (should (= 2.5 (plist-get totals :cost)))
        (should (= 3.5 (plist-get totals :list-cost))))
      (should (equal '("" "subscription")
                     (sort (mapcar (lambda (r) (plist-get r :key))
                                   (harness-call 'usage/summary :group-by 'billing :project "/p/"))
                           #'string<))))))

;;;; JSONL fallback

(ert-deftest harness-usage-jsonl-fallback-matches-sqlite ()
  (harness-usage-test-with
    (harness-usage-test-seed)
    (let ((expected-project (harness-call 'usage/summary :group-by 'project))
          (expected-day (harness-call 'usage/summary :group-by 'day))
          (expected-series (harness-call 'usage/series :bucket 'day :since (harness-usage-test-ts 2026 9 1 0)
                                         :until (harness-usage-test-ts 2026 9 3)))
          (expected-totals (harness-call 'usage/totals :project "/tmp/harness-usage-a/")))
      (cl-letf (((symbol-function 'harness-method/store/sqlite) (lambda () nil)))
        (should (= 0 (plist-get (harness-call 'usage/totals) :calls)))
        (harness-usage-test-seed)
        (should (file-exists-p (harness-store-path "usage/records.jsonl")))
        (should (= 3 (length (harness-call 'store/read-all "usage/records.jsonl"))))
        (should (equal expected-project (harness-call 'usage/summary :group-by 'project)))
        (should (equal expected-day (harness-call 'usage/summary :group-by 'day)))
        (should (equal expected-series (harness-call 'usage/series :bucket 'day :since (harness-usage-test-ts 2026 9 1 0)
                                                     :until (harness-usage-test-ts 2026 9 3))))
        (should (equal expected-totals (harness-call 'usage/totals :project "/tmp/harness-usage-a/")))
        ;; Budgets are evaluated over the same rows.
        (let ((st (harness-call 'usage/budget-status '(:scope project :target "/tmp/harness-usage-b/" :amount 5))))
          (should (= 4.0 (plist-get st :spent)))
          (should (= 1.0 (plist-get st :remaining))))
        ;; The live path still records through the session event.
        (let ((id (harness-usage-test-session)))
          (harness-call 'session/usage-add id '(:input 1000 :output 0))
          (should (harness-usage-test-near 0.001 (plist-get (harness-call 'usage/totals :session id) :cost)))
          (should (= 4 (length (harness-call 'store/read-all "usage/records.jsonl")))))))))

(provide 'harness-usage-test)
;;; harness-usage-test.el ends here
