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
     (clrhash harness-usage--meters)
     (clrhash harness-usage--calls)
     (clrhash harness-usage--rates)
     (let ((harness-provider-demo--delay 0.005)
           ;; A budget over everything fetches Anthropic's cost report in
           ;; the background: no key may reach a real one.
           (harness-anthropic-admin-api-key nil)
           (auth-sources nil)
           (process-environment (cons "ANTHROPIC_ADMIN_KEY" process-environment))
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

(defun harness-usage-test--git (dir &rest args)
  "Run git ARGS in DIR; signal on failure."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string))))))

(ert-deftest harness-usage-summary-by-project-names-the-main-checkout ()
  "A worktree's rows, a task's, say which main checkout they belong to,
also once the worktree is gone; other groupings have no `:main'."
  (harness-usage-test-with
    (let* ((base (harness-test-temp-dir))
           (root (file-name-as-directory (expand-file-name "repo" base)))
           (live (file-name-as-directory (expand-file-name ".worktrees/task-live" root)))
           (gone (file-name-as-directory (expand-file-name ".worktrees/task-gone" root)))
           (plain (harness-test-temp-dir))
           (remote "/ssh:nobody@example.invalid:/srv/x/"))
      (make-directory root t)
      (harness-usage-test--git root "init" "-q" "-b" "main")
      (harness-usage-test--git root "-c" "user.name=t" "-c" "user.email=t@example.invalid" "-c" "commit.gpgsign=false"
                               "commit" "-q" "--allow-empty" "-m" "initial")
      (harness-usage-test--git root "worktree" "add" "-q" "-b" "task/live" live)
      (harness-usage-test--git root "worktree" "add" "-q" "-b" "task/gone" gone)
      (harness-usage-test--git root "worktree" "remove" gone)
      (cl-loop for (project cost) in (list (list root 4.0) (list live 2.0) (list gone 1.0) (list plain 8.0)
                                           (list remote 0.5) (list nil 0.25))
               do (harness-call 'usage/record (list :ts (float-time) :session "s" :project project
                                                    :model "demo:scripted" :cost cost)))
      (let ((by-project (harness-call 'usage/summary :group-by 'project))
            ;; git writes the paths it resolved: compare those.
            (true (lambda (p) (if (or (string-empty-p p) (file-remote-p p)) p
                                (file-name-as-directory (file-truename p))))))
        (should (equal (list plain root live gone remote "")
                       (mapcar (lambda (r) (plist-get r :key)) by-project)))
        (should (equal (mapcar true (list plain root root root remote ""))
                       (mapcar (lambda (r) (funcall true (plist-get r :main))) by-project))))
      (dolist (group '(model session day billing))
        (should-not (cl-some (lambda (r) (plist-member r :main))
                             (harness-call 'usage/summary :group-by group)))))))

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

(ert-deftest harness-usage-baseline-counts-in-its-period-only ()
  "A month budget made mid-month counts what was spent before it, that month only."
  (harness-usage-test-with
    (let* ((now (harness-usage-test-ts 2026 9 16))
           (budget (harness-call 'usage/set-budget '(:scope period :period month :days all :amount 100
                                                     :baseline 20 :baseline-period-start "2026-09-01")))
           (id (plist-get budget :id)))
      (harness-call 'usage/record (list :ts (harness-usage-test-ts 2026 9 10) :session "s" :project "/p/" :model "m" :cost 5.0))
      ;; September: $20 spent before plus $5 recorded, over the 16th to the 30th.
      (let ((st (harness-call 'usage/budget-status id :now now)))
        (should (= 25.0 (plist-get st :spent)))
        (should (= 20.0 (plist-get st :baseline)))
        (should (= 75.0 (plist-get st :remaining)))
        (should (harness-usage-test-near 0.25 (plist-get st :fraction)))
        (should (= 15 (plist-get st :days-left)))
        (should (= 5.0 (plist-get st :per-day))))
      ;; October: the baseline was September's, so only October's rows count.
      (harness-call 'usage/record (list :ts (harness-usage-test-ts 2026 10 5) :session "s" :project "/p/" :model "m" :cost 3.0))
      (let ((st (harness-call 'usage/budget-status id :now (harness-usage-test-ts 2026 10 14))))
        (should (= 3.0 (plist-get st :spent)))
        (should (= 0.0 (plist-get st :baseline)))
        (should (= 97.0 (plist-get st :remaining)))
        (should (harness-usage-test-near 0.03 (plist-get st :fraction)))
        (should (= 18 (plist-get st :days-left)))
        (should (harness-usage-test-near (/ 97.0 18) (plist-get st :per-day))))
      ;; Any date or time inside the period names it; week budgets start on Monday.
      (let ((mid (harness-call 'usage/set-budget '(:scope period :period month :amount 50 :baseline 10
                                                   :baseline-period-start "2026-09-23")))
            (week (harness-call 'usage/set-budget (list :scope 'period :period 'week :amount 50 :baseline 10
                                                        :baseline-period-start now))))
        (should (equal "2026-09-01" (plist-get mid :baseline-period-start)))
        (should (equal "2026-09-14" (plist-get week :baseline-period-start)))
        (should (= 10.0 (plist-get (harness-call 'usage/budget-status (plist-get week :id) :now now) :baseline)))
        (should (= 0.0 (plist-get (harness-call 'usage/budget-status (plist-get week :id)
                                                :now (harness-usage-test-ts 2026 9 21))
                                  :baseline))))
      ;; Without a period the baseline always counts.
      (let ((st (harness-call 'usage/budget-status '(:scope project :target "/p/" :amount 40 :baseline 12)
                              :now (harness-usage-test-ts 2027 1 1))))
        (should (= 20.0 (plist-get st :spent)))
        (should (= 12.0 (plist-get st :baseline)))
        (should (harness-usage-test-near 0.5 (plist-get st :fraction))))
      ;; Budgets without a baseline report none.
      (should (= 0.0 (plist-get (harness-call 'usage/budget-status '(:scope period :period day :amount 1) :now now)
                                :baseline))))))

(ert-deftest harness-usage-baseline-persists-and-validates ()
  (harness-usage-test-with
    (let ((b (harness-call 'usage/set-budget '(:scope period :period month :amount 100 :baseline 20
                                               :baseline-period-start "2026-09-01"))))
      (should (= 20.0 (plist-get b :baseline)))
      (should (equal "2026-09-01" (plist-get b :baseline-period-start)))
      ;; Stored in budgets.json as given, and read back unchanged.
      (let ((on-disk (car (harness-call 'store/load "budgets.json"))))
        (should (= 20.0 (plist-get on-disk :baseline)))
        (should (equal "2026-09-01" (plist-get on-disk :baseline-period-start))))
      (setq harness-usage-budgets nil)
      (harness-usage--load-budgets)
      (should (equal b (car harness-usage-budgets)))
      ;; A baseline set without a period start is this period's.
      (let ((this-month (harness-usage--date-key (car (harness-usage-period-bounds 'month))))
            (b2 (harness-call 'usage/set-budget (harness-plist-merge b '(:baseline 7 :baseline-period-start nil)))))
        (should (= 1 (length (harness-call 'usage/budgets))))
        (should (= 7.0 (plist-get b2 :baseline)))
        (should (equal this-month (plist-get b2 :baseline-period-start)))
        (should (= 7.0 (plist-get (harness-call 'usage/budget-status (plist-get b2 :id)) :baseline))))
      ;; 0, nil or false clears it, leaving no baseline keys behind.
      (dolist (none '(0 nil :false))
        (harness-call 'usage/set-budget (harness-plist-merge b (list :baseline none)))
        (let ((stored (car (harness-call 'usage/budgets)))
              (on-disk (car (harness-call 'store/load "budgets.json"))))
          (should-not (plist-member stored :baseline))
          (should-not (plist-member stored :baseline-period-start))
          (should-not (plist-member on-disk :baseline))
          (should (= 0.0 (plist-get (harness-call 'usage/budget-status (plist-get b :id)) :baseline))))))
    ;; A budget without a period keeps no period start: its baseline always counts.
    (let ((p (harness-call 'usage/set-budget '(:scope project :target "/p/" :amount 10 :baseline 4
                                               :baseline-period-start "2026-09-01"))))
      (should (= 4.0 (plist-get p :baseline)))
      (should-not (plist-member p :baseline-period-start)))
    (should-error (harness-call 'usage/set-budget '(:scope period :period month :amount 10 :baseline -1)))
    (should-error (harness-call 'usage/set-budget '(:scope period :period month :amount 10 :baseline "20")))
    (should-error (harness-call 'usage/set-budget '(:scope period :period month :amount 10 :baseline 5
                                                    :baseline-period-start "September")))
    (should-error (harness-call 'usage/set-budget '(:scope period :period month :amount 10 :baseline 5
                                                    :baseline-period-start "2026-02-30")))
    (should (= 2 (length (harness-call 'usage/budgets))))))

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

(defvar harness-budget)

(ert-deftest harness-usage-budget-setting-is-one-budget-for-all-sessions ()
  "The Budget setting is one budget that every session spends from.
Sessions in two projects count toward it together, and a hard one,
once spent, stops them all; no session has a budget of its own."
  (harness-usage-test-with
    (let* ((harness-budget '(:amount 0.001 :hard t))
           (a (harness-usage-test-session))
           (b (harness-usage-test-session))
           (ids (lambda (sid) (mapcar (lambda (st) (plist-get (plist-get st :budget) :id))
                                      (harness-call 'usage/session-budgets sid)))))
      (should-not (equal (plist-get (harness-call 'session/get a) :project)
                         (plist-get (harness-call 'session/get b) :project)))
      (should (equal '("settings") (funcall ids a)))
      (should (equal '("settings") (funcall ids b)))
      ;; $0.0008 a turn: one each fits, and together they spend it.
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt a "hello")) :stop-reason)))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt b "hello")) :stop-reason)))
      (let ((st (harness-call 'usage/budget-status "settings")))
        (should (harness-usage-test-near 0.0016 (plist-get st :spent)))
        (should (= 0.001 (plist-get st :amount)))
        (should (plist-get st :hard))
        (should (plist-get (plist-get st :budget) :implicit)))
      (dolist (sid (list a b))
        (let ((r (harness-await (harness-call 'agent/prompt sid "again"))))
          (should (eq 'blocked (plist-get r :stop-reason)))
          (should (string-match-p "Budget all sessions (setting) exhausted" (plist-get r :error)))))
      ;; It is no explicit budget, and without the setting there is none.
      (should-not (harness-call 'usage/budgets))
      (let ((harness-budget nil))
        (should-error (harness-call 'usage/budget-status "settings"))
        (should-not (funcall ids a))
        (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt a "again")) :stop-reason)))))))

(ert-deftest harness-usage-baseline-counts-toward-hard-budgets ()
  "What was spent before the harness counted can exhaust a hard budget."
  (harness-usage-test-with
    (let* ((id (harness-usage-test-session))
           (project (plist-get (harness-call 'session/get id) :project)))
      (harness-call 'usage/set-budget (list :scope 'project :target project :amount 10 :hard t :baseline 10))
      (let ((r (harness-await (harness-call 'agent/prompt id "hello"))))
        (should (eq 'blocked (plist-get r :stop-reason)))
        (should (string-match-p "exhausted: spent \\$10\\.00 (incl\\. \\$10\\.00 baseline) of \\$10\\.00"
                                (plist-get r :error))))
      (should (= 0 (plist-get (harness-call 'usage/totals :session id) :calls)))
      ;; Without the baseline the turn runs.
      (harness-call 'usage/set-budget (harness-plist-merge (car (harness-call 'usage/budgets)) '(:baseline nil)))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "hello")) :stop-reason))))))

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

;;;; This month's API cost

(defconst harness-usage-test-cost-pages
  '((:data ((:starting_at "2026-09-01T00:00:00Z" :ending_at "2026-09-02T00:00:00Z"
             :results ((:amount "123.78912" :currency "USD" :description "Claude Opus 5 Usage - Input Tokens")
                       (:amount "500" :currency "USD")
                       (:amount "999" :currency "EUR"))))
     :has_more t :next_page "page_2")
    (:data ((:starting_at "2026-09-02T00:00:00Z" :ending_at "2026-09-03T00:00:00Z"
             :results ((:amount "376.21088" :currency "USD"))))
     :has_more :false :next_page nil))
  "Two pages of an Anthropic cost report: 1000 US cents, $10.00, in all.")

(ert-deftest harness-usage-fetch-api-cost-from-the-admin-cost-report ()
  "The month's cost comes from Anthropic's Admin API, less what the harness recorded."
  (harness-usage-test-with
    (let ((requests nil)
          (pages (copy-tree harness-usage-test-cost-pages)))
      (cl-letf (((symbol-function 'harness-http-request-json)
                 (lambda (url &rest args) (push (cons url args) requests) (harness-resolved (pop pages))))
                ((symbol-function 'auth-source-search) (lambda (&rest _) nil)))
        ;; Without a key anywhere nothing is fetched.
        (let ((harness-anthropic-admin-api-key nil)
              (process-environment (cons "ANTHROPIC_ADMIN_KEY" process-environment)))
          (let ((r (harness-await (harness-call 'usage/fetch-api-cost))))
            (should-not (plist-get r :available))
            (should (string-match-p "harness-anthropic-admin-api-key" (plist-get r :reason))))
          (should-not requests))
        (let ((harness-anthropic-admin-api-key " sk-ant-admin01-test "))
          ;; Claude calls billed per token are in the report already; the rest are not.
          (dolist (row (list (list :ts (harness-usage-test-ts 2026 9 10) :model "claude:claude-opus-5-5" :cost 2.5 :billing 'api)
                             (list :ts (harness-usage-test-ts 2026 9 20) :model "claude:claude-opus-5-5" :cost 0.5)
                             (list :ts (harness-usage-test-ts 2026 9 11) :model "claude:claude-opus-5-5" :cost 0.0
                                   :list-cost 4.0 :billing 'subscription)
                             (list :ts (harness-usage-test-ts 2026 9 12) :model "claude:claude-opus-5-5" :cost 1.0
                                   :billing 'extra-usage)
                             (list :ts (harness-usage-test-ts 2026 9 13) :model "demo:scripted" :cost 1.0)
                             (list :ts (harness-usage-test-ts 2026 8 30) :model "claude:claude-opus-5-5" :cost 5.0 :billing 'api)))
            (harness-call 'usage/record (append (list :session "s" :project "/p/") row)))
          (let ((r (harness-await (harness-call 'usage/fetch-api-cost :now (harness-usage-test-ts 2026 9 16)))))
            (should (eq t (plist-get r :available)))
            (should (harness-usage-test-near 10.0 (plist-get r :amount)))
            (should (harness-usage-test-near 3.0 (plist-get r :recorded)))
            (should (harness-usage-test-near 7.0 (plist-get r :outside)))
            (should (equal "2026-09-01" (plist-get r :period-start))))
          ;; The whole UTC month, a page at a time, with the key in a header.
          (should (= 2 (length requests)))
          (pcase-let ((`(,url . ,args) (car (last requests))))
            (should (equal (concat "https://api.anthropic.com/v1/organizations/cost_report?starting_at=2026-09-01T00:00:00Z"
                                   "&ending_at=2026-10-01T00:00:00Z&bucket_width=1d&limit=31")
                           url))
            (should (equal "sk-ant-admin01-test" (cdr (assoc "x-api-key" (plist-get args :headers)))))
            (should (equal "2023-06-01" (cdr (assoc "anthropic-version" (plist-get args :headers))))))
          (should (string-suffix-p "&page=page_2" (car (car requests)))))))
    ;; The key comes from the environment, then from auth-source.
    (let ((harness-anthropic-admin-api-key nil)
          (process-environment (cons "ANTHROPIC_ADMIN_KEY=sk-ant-admin01-env" process-environment)))
      (should (equal "sk-ant-admin01-env" (harness-usage--admin-key))))
    (let ((harness-anthropic-admin-api-key "")
          (process-environment (cons "ANTHROPIC_ADMIN_KEY" process-environment)))
      (cl-letf (((symbol-function 'auth-source-search)
                 (lambda (&rest spec)
                   (and (equal "api.anthropic.com" (plist-get spec :host)) (equal "admin" (plist-get spec :user))
                        (list (list :secret (lambda () "sk-ant-admin01-auth")))))))
        (should (equal "sk-ant-admin01-auth" (harness-usage--admin-key)))))
    ;; A refusal reads as Anthropic's own message.
    (cl-letf (((symbol-function 'harness-http-request-json)
               (lambda (&rest _)
                 (harness-rejected
                  (list 'http-error 401
                        "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}")))))
      (let* ((harness-anthropic-admin-api-key "sk-ant-api03-not-an-admin-key")
             (err (should-error (harness-await (harness-call 'usage/fetch-api-cost)) :type 'harness-error)))
        (should (string-match-p "(HTTP 401): invalid x-api-key; it takes an Admin API key" (cadr err)))))))

;;;; Spending providers report

(defun harness-usage-test-source (status kind)
  "Return the source of KIND (a symbol) in budget STATUS, or nil."
  (cl-find kind (plist-get status :sources) :key (lambda (s) (plist-get s :kind))))

(ert-deftest harness-usage-budgets-over-everything-count-extra-usage-reported ()
  "A plan's extra usage this month counts in month budgets over everything,
less the calls the harness recorded as drawing on it before the report."
  (harness-usage-test-with
    (let* ((events nil)
           (month (harness-call 'usage/set-budget '(:scope period :period month :amount 20 :label "month")))
           (week (harness-call 'usage/set-budget '(:scope period :period week :amount 20)))
           (project (harness-call 'usage/set-budget '(:scope project :target "/p/" :amount 20)))
           (mine (harness-call 'usage/set-budget '(:scope period :target "/p/" :period month :amount 20)))
           (status (lambda (budget &optional now)
                     (harness-call 'usage/budget-status (plist-get budget :id)
                                   :now (or now (harness-usage-test-ts 2026 9 20)))))
           (quota (lambda (used &optional updated currency)
                    (list :billing 'subscription :plan "max"
                          :extra (list :enabled t :used used :limit 50.0 :currency (or currency "USD"))
                          :updated (or updated (harness-usage-test-ts 2026 9 16))))))
      (harness-on 'usage/reported-changed (lambda (report) (push report events)))
      (dolist (row (list
                    ;; Drew on Claude's extra usage before the report: in it already.
                    (list :ts (harness-usage-test-ts 2026 9 10) :model "claude:claude-opus-5-5" :cost 1.0 :billing 'extra-usage)
                    ;; After the report: not in it yet.
                    (list :ts (harness-usage-test-ts 2026 9 18) :model "claude:claude-opus-5-5" :cost 0.5 :billing 'extra-usage)
                    ;; Another provider's extra usage, and calls the plan covered.
                    (list :ts (harness-usage-test-ts 2026 9 12) :model "copilot:gpt-5" :cost 2.0 :billing 'extra-usage)
                    (list :ts (harness-usage-test-ts 2026 9 11) :model "claude:claude-opus-5-5" :cost 0.0
                          :list-cost 3.0 :billing 'subscription)))
        (harness-call 'usage/record (append (list :session "s" :project "/p/") row)))
      ;; Before any report, only what was recorded counts.
      (let ((st (funcall status month)))
        (should (harness-usage-test-near 3.5 (plist-get st :spent)))
        (should (= 0.0 (plist-get st :reported)))
        (should-not (plist-get st :sources)))
      ;; Claude Code reports $8.00 of extra usage this month.
      (harness-emit 'provider/quota-updated 'claude (funcall quota 8.0))
      (should (= 1 (length events)))
      (should (equal '(:source claude :amount 8.0 :month "2026-09-01") (car events)))
      (let* ((st (funcall status month))
             (source (harness-usage-test-source st 'extra-usage)))
        (should (harness-usage-test-near 7.0 (plist-get st :reported)))
        (should (harness-usage-test-near 10.5 (plist-get st :spent)))
        (should (harness-usage-test-near 9.5 (plist-get st :remaining)))
        (should (= 1 (length (plist-get st :sources))))
        (should (eq 'claude (plist-get source :source)))
        (should (equal "Claude" (plist-get source :label)))
        (should (= 8.0 (plist-get source :amount)))
        (should (harness-usage-test-near 1.0 (plist-get source :recorded)))
        (should (harness-usage-test-near 7.0 (plist-get source :outside)))
        (should (= (harness-usage-test-ts 2026 9 16) (plist-get source :at)))
        (should (string-match-p "\\`Claude reports \\$8\\.00 billed beyond the plan this month, as of Sep 16 12:00; \\$1\\.00 of it was recorded here, so \\$7\\.00 more counts\\'"
                                (plist-get source :detail)))
        (should (equal "incl. $7.00 reported by Claude" (harness-budget-outside-text st))))
      ;; The report covers the calendar month only: not a week, nor one
      ;; project, nor another month.
      (should-not (plist-get (funcall status week) :sources))
      (should-not (plist-get (funcall status project) :sources))
      (should-not (plist-get (funcall status mine) :sources))
      (should-not (plist-get (funcall status month (harness-usage-test-ts 2026 10 3)) :sources))
      ;; The same report again changes nothing; a report less than what was
      ;; recorded counts nothing.
      (harness-emit 'provider/quota-updated 'claude (funcall quota 8.0))
      (should (= 1 (length events)))
      (harness-emit 'provider/quota-updated 'claude (funcall quota 0.5))
      (should (= 2 (length events)))
      (let ((st (funcall status month)))
        (should (= 0.0 (plist-get st :reported)))
        (should (harness-usage-test-near 3.5 (plist-get st :spent)))
        (should (equal "incl. $0 reported by Claude" (harness-budget-outside-text st t)))
        (should-not (harness-budget-outside-text st)))
      ;; Next month's report replaces this one.
      (harness-emit 'provider/quota-updated 'claude (funcall quota 1.25 (harness-usage-test-ts 2026 10 2)))
      (should (equal "2026-10-01" (plist-get (car events) :month)))
      (should-not (plist-get (funcall status month) :sources))
      (should (harness-usage-test-near 1.25 (plist-get (funcall status month (harness-usage-test-ts 2026 10 3)) :reported)))
      ;; Money in another currency, and billing per token, report nothing.
      (harness-emit 'provider/quota-updated 'claude (funcall quota 9.0 nil "EUR"))
      (should-not harness-usage--extra-spend)
      (harness-emit 'provider/quota-updated 'claude (funcall quota 8.0))
      (harness-emit 'provider/quota-updated 'claude '(:billing api :auth "ANTHROPIC_API_KEY"))
      (should-not harness-usage--extra-spend)
      (should (null (plist-get (car events) :amount)))
      (should-not (plist-get (funcall status month) :sources))
      ;; Two providers' reports add up.
      (harness-emit 'provider/quota-updated 'claude (funcall quota 8.0))
      (harness-emit 'provider/quota-updated 'copilot (funcall quota 5.0))
      (let ((st (funcall status month)))
        (should (= 2 (length (plist-get st :sources))))
        (should (harness-usage-test-near 10.0 (plist-get st :reported)))
        (should (equal "incl. $10.00 reported by Claude and Copilot" (harness-budget-outside-text st)))))))

(ert-deftest harness-usage-budgets-over-everything-count-the-anthropic-cost-report ()
  "With an Admin API key, Anthropic's cost report counts in day, week and
month budgets over everything, fetched in the background when due."
  (harness-usage-test-with
    (let* ((requests nil)
           (cents "1234")
           (fail nil)
           (events 0)
           (harness-anthropic-admin-api-key "sk-ant-admin01-test")
           (month (harness-call 'usage/set-budget '(:scope period :period month :amount 100)))
           (week (harness-call 'usage/set-budget '(:scope period :period week :amount 100)))
           (project (harness-call 'usage/set-budget '(:scope project :target "/p/" :amount 100)))
           (status (lambda (budget &rest opts)
                     (apply #'harness-call 'usage/budget-status (plist-get budget :id) opts))))
      (harness-on 'usage/reported-changed (lambda (_) (cl-incf events)))
      (cl-letf (((symbol-function 'harness-http-request-json)
                 (lambda (url &rest _)
                   (push url requests)
                   (if fail
                       (harness-rejected (list 'http-error 500 "{\"error\":{\"message\":\"overloaded\"}}"))
                     (harness-resolved (list :data (list (list :results (list (list :amount cents :currency "USD"))))
                                             :has_more :false))))))
        ;; A week's report covers the UTC days of its local dates.
        (let ((r (harness-await (harness-call 'usage/fetch-api-cost :period "week"
                                              :now (harness-usage-test-ts 2026 9 16)))))
          (should (harness-usage-test-near 12.34 (plist-get r :amount)))
          (should (eq 'week (plist-get r :period)))
          (should (equal "2026-09-14" (plist-get r :period-start))))
        (should (string-match-p "starting_at=2026-09-14T00:00:00Z&ending_at=2026-09-21T00:00:00Z" (car requests)))
        (should (= 1 events))
        ;; ...and from then on the week budget counts it, the project budget not.
        (let ((st (funcall status week :now (harness-usage-test-ts 2026 9 16)))
              (other (funcall status week :now (harness-usage-test-ts 2026 9 23))))
          (should (harness-usage-test-near 12.34 (plist-get st :reported)))
          (should (eq 'anthropic (plist-get (harness-usage-test-source st 'cost-report) :source)))
          (should (equal "Anthropic" (plist-get (harness-usage-test-source st 'cost-report) :label)))
          (should-not (plist-get other :sources)))
        (should-not (plist-get (funcall status project :now (harness-usage-test-ts 2026 9 16)) :sources))
        ;; A day's.
        (harness-await (harness-call 'usage/fetch-api-cost :period 'day :now (harness-usage-test-ts 2026 9 16)))
        (should (string-match-p "starting_at=2026-09-16T00:00:00Z&ending_at=2026-09-17T00:00:00Z" (car requests)))
        (setq requests nil)
        ;; Looking at the current month fetches its report in the background,
        ;; once: Claude calls billed per token before it are in it already
        ;; (a call made in the hours before the first UTC day, too early for
        ;; the report, is not).
        (let* ((window (harness-usage--utc-window (harness-usage-period-bounds 'month)))
               (entry (lambda () (gethash window harness-usage--cost-reports)))
               (ts (- (float-time) 1))
               (in-report (if (>= ts (car window)) 2.0 0.0)))
          (harness-call 'usage/record (list :ts ts :session "s" :project "/p/"
                                            :model "claude:claude-opus-5-5" :cost 2.0 :billing 'api))
          (let ((st (funcall status month)))
            (should (harness-usage-test-near 2.0 (plist-get st :spent)))
            (should-not (plist-get st :sources)))
          (funcall status month)
          (harness-test-wait (lambda () (= 3 events)) 5 "the month's report")
          (should (= 1 (length requests)))
          (let* ((st (funcall status month))
                 (source (harness-usage-test-source st 'cost-report)))
            (should (harness-usage-test-near 12.34 (plist-get source :amount)))
            (should (harness-usage-test-near in-report (plist-get source :recorded)))
            (should (harness-usage-test-near (- 12.34 in-report) (plist-get st :reported)))
            (should (harness-usage-test-near (- 14.34 in-report) (plist-get st :spent))))
          (should (= 1 (length requests)))
          ;; A failure says why and keeps what was reported before.
          (let ((harness-usage-cost-report-interval -1))
            (setq fail t)
            (funcall status month)
            (harness-test-wait (lambda () (plist-get (funcall entry) :error)) 5 "a failed fetch")
            (should (= 2 (length requests)))
            (should (string-match-p "HTTP 500" (plist-get (funcall entry) :error)))
            (should (harness-usage-test-near (- 12.34 in-report)
                                             (plist-get (funcall status month :now (float-time)) :reported))))
          ;; Without a key nothing is asked for.
          (let ((harness-anthropic-admin-api-key nil)
                (harness-usage-cost-report-interval -1))
            (clrhash harness-usage--cost-reports)
            (setq requests nil)
            (funcall status month)
            (harness-test-wait (lambda () (plist-get (funcall entry) :error)) 5 "no key")
            (should (string-match-p "No Anthropic Admin API key" (plist-get (funcall entry) :error)))
            (should-not requests)
            (should-not (plist-get (funcall status month :now (float-time)) :sources))))))))

(ert-deftest harness-usage-cost-report-fetches-share-one-request ()
  "Asking for a period's cost report while a request for it is out shares that request."
  (harness-usage-test-with
    (let* ((harness-anthropic-admin-api-key "sk-ant-admin01-test")
           (pending (harness-make-promise))
           (requests 0)
           (window (harness-usage--utc-window (harness-usage-period-bounds 'day))))
      (cl-letf (((symbol-function 'harness-http-request-json)
                 (lambda (&rest _) (cl-incf requests) pending)))
        (let ((first (harness-usage--fetch-cost-report window))
              (second (harness-usage--fetch-cost-report window)))
          (should (eq first second))
          (should (= 1 requests))
          (harness-resolve pending '(:data ((:results ((:amount "250" :currency "USD")))) :has_more :false))
          (should (harness-usage-test-near 2.5 (harness-await first)))
          (should-not (gethash window harness-usage--cost-report-fetches))
          (should (harness-usage-test-near 2.5 (plist-get (gethash window harness-usage--cost-reports) :amount)))
          ;; The next one asks again.
          (harness-usage--fetch-cost-report window)
          (should (= 2 requests))))
      ;; A request that cannot even start is noted like one that failed.
      (cl-letf (((symbol-function 'harness-http-request-json) (lambda (&rest _) (error "No network"))))
        (let ((window (harness-usage--utc-window (harness-usage-period-bounds 'week))))
          (should-error (harness-await (harness-usage--fetch-cost-report window)) :type 'harness-error)
          (should (string-match-p "failed: No network" (plist-get (gethash window harness-usage--cost-reports) :error)))
          (should-not (gethash window harness-usage--cost-report-fetches)))))))

(ert-deftest harness-usage-reported-spending-and-baseline-stop-a-hard-budget ()
  "What providers report counts toward a hard budget over everything, besides its baseline."
  (harness-usage-test-with
    (let* ((now (float-time))
           (id (harness-usage-test-session))
           (budget (harness-call 'usage/set-budget
                                 '(:scope period :period month :amount 10 :hard t :label "monthly cap"))))
      (should-not (harness-usage--check (harness-call 'session/get id) now))
      (harness-emit 'provider/quota-updated 'claude
                    (list :billing 'subscription :extra (list :enabled t :used 6.0 :currency "USD") :updated now))
      (should-not (harness-usage--check (harness-call 'session/get id) now))
      (harness-call 'usage/set-budget (append (list :baseline 4.0) budget))
      (let ((st (harness-call 'usage/budget-status (plist-get budget :id) :now now)))
        (should (= 10.0 (plist-get st :spent)))
        (should (= 6.0 (plist-get st :reported)))
        (should (= 4.0 (plist-get st :baseline))))
      (should (string-match-p
               "\\`Budget monthly cap exhausted: spent \\$10\\.00 (incl\\. \\$6\\.00 reported by Claude, \\$4\\.00 baseline) of \\$10\\.00\\'"
               (harness-usage--check (harness-call 'session/get id) now))))))

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

;;;; Output rate

(defvar harness-usage-test--now 1000.0
  "What `float-time' answers inside `harness-usage-test-clock'.")

(defmacro harness-usage-test-clock (&rest body)
  "Run BODY with `float-time' answering `harness-usage-test--now', from 1000."
  (declare (indent 0))
  `(let ((harness-usage-test--now 1000.0))
     (cl-letf (((symbol-function 'float-time) (lambda (&optional _) harness-usage-test--now)))
       ,@body)))

(defun harness-usage-test-at (seconds)
  "Set the clock of `harness-usage-test-clock' SECONDS after it started."
  (setq harness-usage-test--now (+ 1000.0 seconds)))

(defun harness-usage-test-phase (id phase)
  "Announce that session ID's turn is in activity PHASE; nil once it ended."
  (harness-emit 'agent/activity-changed id (and phase (list :phase phase))))

(ert-deftest harness-usage-rate-counts-streaming-time-only ()
  "Output over the seconds the model streamed, not waited or ran tools."
  (harness-usage-test-with
    (harness-usage-test-clock
      (let ((id (harness-usage-test-session)) (announced nil))
        (harness-on 'usage/rate-updated (lambda (sid rate) (push (cons sid rate) announced)))
        (harness-emit 'agent/turn-started id)
        (harness-usage-test-phase id 'waiting)
        (harness-usage-test-at 2)         ; the first token after 2 s
        (harness-usage-test-phase id 'thinking)
        (harness-usage-test-at 3)
        (harness-usage-test-phase id 'writing)
        (harness-usage-test-at 4)
        (harness-usage-test-phase id 'tool)
        (harness-usage-test-at 9)         ; 5 s of tools
        (harness-usage-test-phase id 'tool-input)
        (harness-usage-test-at 10)
        (harness-call 'session/usage-add id '(:input 10 :output 300))
        (let ((rate (harness-call 'usage/rate id)))
          (should (harness-usage-test-near 100.0 (plist-get rate :rate)))
          (should (= 300 (plist-get rate :output)))
          (should (harness-usage-test-near 3.0 (plist-get rate :seconds)))
          (should (= 1 (plist-get rate :calls)))
          (should (equal "demo:scripted" (plist-get rate :model)))
          (should (harness-usage-test-near 1010.0 (plist-get rate :at)))
          (should (equal (list (cons id rate)) announced)))
        ;; The stream still open counts on for the next call, from now.
        (harness-usage-test-at 12)
        (harness-call 'session/usage-add id '(:input 10 :output 100))
        (let ((rate (harness-call 'usage/rate id)))
          (should (harness-usage-test-near 80.0 (plist-get rate :rate)))
          (should (= 400 (plist-get rate :output)))
          (should (= 2 (plist-get rate :calls))))
        ;; The rows are the accounting's as ever.
        (should (= 2 (plist-get (harness-call 'usage/totals :session id) :calls)))))))

(ert-deftest harness-usage-rate-leaves-out-unmeasurable-calls ()
  "Output that came at once, no output, and usage outside a turn give no rate."
  (harness-usage-test-with
    (harness-usage-test-clock
      (let ((id (harness-usage-test-session)) (announced 0))
        (harness-on 'usage/rate-updated (lambda (&rest _) (cl-incf announced)))
        (harness-emit 'agent/turn-started id)
        (harness-usage-test-phase id 'writing)
        (harness-usage-test-at 0.1)
        (harness-call 'session/usage-add id '(:input 10 :output 500))
        (should-not (harness-call 'usage/rate id))
        (harness-usage-test-at 2)
        (harness-call 'session/usage-add id '(:input 10 :output 0))
        (should-not (harness-call 'usage/rate id))
        (harness-usage-test-phase id nil)
        (harness-emit 'agent/turn-ended id 'end-turn)
        ;; Compaction records usage between turns.
        (harness-usage-test-at 30)
        (harness-call 'session/usage-add id '(:input 1000 :output 200))
        (should-not (harness-call 'usage/rate id))
        (should-not (harness-call 'usage/rates))
        (should (= 0 announced))))))

(ert-deftest harness-usage-rate-follows-hosted-calls ()
  "A hosted loop's calls are measured one by one; its turn's total is not measured again."
  (harness-usage-test-with
    (harness-usage-test-clock
      (let ((id (harness-usage-test-session)) (announced 0))
        (harness-on 'usage/rate-updated (lambda (&rest _) (cl-incf announced)))
        (harness-emit 'agent/turn-started id)
        (harness-usage-test-phase id 'waiting)
        (harness-usage-test-at 1)
        (harness-usage-test-phase id 'writing)
        (harness-usage-test-at 3)
        (harness-emit 'agent/call-usage id '(:output 100))
        (should (harness-usage-test-near 50.0 (plist-get (harness-call 'usage/rate id) :rate)))
        (harness-usage-test-phase id 'tool)
        (harness-usage-test-at 20)
        (harness-usage-test-phase id 'thinking)
        (harness-usage-test-at 21)
        (harness-emit 'agent/call-usage id '(:output 80))
        ;; The turn's total, which may count sub-agents too, at its end.
        (harness-usage-test-at 22)
        (harness-call 'session/usage-add id '(:input 900 :output 9000))
        (let ((rate (harness-call 'usage/rate id)))
          (should (harness-usage-test-near 60.0 (plist-get rate :rate)))
          (should (= 180 (plist-get rate :output)))
          (should (harness-usage-test-near 3.0 (plist-get rate :seconds)))
          (should (= 2 (plist-get rate :calls))))
        (should (= 2 announced))
        (should (= 9000 (plist-get (harness-call 'usage/totals :session id) :output)))
        ;; The next turn's calls are measured afresh.
        (harness-usage-test-phase id nil)
        (harness-emit 'agent/turn-ended id 'end-turn)
        (harness-emit 'agent/turn-started id)
        (harness-usage-test-phase id 'writing)
        (harness-usage-test-at 24)
        (harness-emit 'agent/call-usage id '(:output 120))
        (should (= 3 (plist-get (harness-call 'usage/rate id) :calls)))
        (should (harness-usage-test-near 60.0 (plist-get (harness-call 'usage/rate id) :rate)))))))

(ert-deftest harness-usage-rate-averages-the-latest-calls ()
  "The rate is over the newest calls that fill the window, on the current model."
  (harness-usage-test-with
    (harness-usage-test-clock
      (let ((id (harness-usage-test-session))
            (harness-usage-rate-window 5))
        (harness-emit 'agent/turn-started id)
        (harness-usage-test-phase id 'writing)
        ;; Calls of 4 s each, at 10, 20 and 30 tokens per second.
        (cl-loop for output in '(40 80 120) for at from 4 by 4
                 do (harness-usage-test-at at)
                    (harness-call 'session/usage-add id (list :input 1 :output output)))
        ;; The newest two fill the 5 s window: (120 + 80) / 8.
        (let ((rate (harness-call 'usage/rate id)))
          (should (harness-usage-test-near 25.0 (plist-get rate :rate)))
          (should (= 2 (plist-get rate :calls)))
          (should (harness-usage-test-near 8.0 (plist-get rate :seconds))))
        ;; Calls on another model than the session's are dropped.
        (puthash id (list (list 1000 1.0 "demo:other")) harness-usage--calls)
        (harness-usage-test-at 14)
        (harness-call 'session/usage-add id '(:input 1 :output 20))
        (let ((rate (harness-call 'usage/rate id)))
          (should (harness-usage-test-near 10.0 (plist-get rate :rate)))
          (should (= 1 (plist-get rate :calls))))))))

(ert-deftest harness-usage-rate-outlives-the-turn ()
  "An idle session keeps its last rate; a deleted one loses it."
  (harness-usage-test-with
    (harness-usage-test-clock
      (let ((a (harness-usage-test-session)) (b (harness-usage-test-session)))
        (dolist (id (list a b))
          (harness-emit 'agent/turn-started id)
          (harness-usage-test-phase id 'writing))
        (harness-usage-test-at 2)
        (harness-call 'session/usage-add a '(:input 1 :output 100))
        (harness-usage-test-at 4)
        (harness-call 'session/usage-add b '(:input 1 :output 100))
        (dolist (id (list a b))
          (harness-usage-test-phase id nil)
          (harness-emit 'agent/turn-ended id 'end-turn))
        (should-not (gethash a harness-usage--meters))
        (harness-usage-test-at 600)
        (should (harness-usage-test-near 50.0 (plist-get (harness-call 'usage/rate a) :rate)))
        (should (harness-usage-test-near 25.0 (plist-get (harness-call 'usage/rate b) :rate)))
        (let ((rates (harness-call 'usage/rates)))
          (should (equal (list b a) (mapcar (lambda (r) (plist-get r :session)) rates)))
          (should (equal (harness-call 'usage/rate b) (harness-plist-remove (car rates) :session))))
        (harness-call 'session/delete a)
        (should-not (harness-call 'usage/rate a))
        (should (equal (list b) (mapcar (lambda (r) (plist-get r :session)) (harness-call 'usage/rates))))))))

(ert-deftest harness-usage-rate-of-a-streamed-turn ()
  "A turn the demo provider streams gets its rate from the turn's usage."
  (harness-usage-test-with
    (let* ((id (harness-usage-test-session))
           (harness-provider-demo--delay 0.05)
           (harness-provider-demo-script-override
            (append (make-list 8 '(:type text :delta "word "))
                    '((:type usage :input 100 :output 40 :cost 0.0001 :context 100)
                      (:type done :stop-reason end-turn)))))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "hello")) :stop-reason)))
      (let ((rate (harness-call 'usage/rate id)))
        (should rate)
        (should (= 40 (plist-get rate :output)))
        (should (= 1 (plist-get rate :calls)))
        ;; Eight deltas 0.05 s apart, then the usage: about 0.4 s.
        (should (< 0.3 (plist-get rate :seconds) 5.0))
        (should (harness-usage-test-near (plist-get rate :rate) (/ 40 (plist-get rate :seconds)))))
      ;; The turn is over: the meter is gone, the rate stays.
      (should-not (gethash id harness-usage--meters))
      (should (harness-call 'usage/rate id)))))

(ert-deftest harness-usage-rate-of-a-hosted-turn ()
  "A provider's `call-usage' events give the rate; the turn's usage the accounting."
  (harness-usage-test-with
    (let* ((id (harness-usage-test-session))
           (calls nil)
           (words (make-list 8 '(:type text :delta "word ")))
           (harness-provider-demo--delay 0.05)
           (harness-provider-demo-script-override
            (append words '((:type call-usage :output 24))
                    words '((:type call-usage :output 16))
                    ;; The turn's total, with a sub-agent's output in it.
                    '((:type usage :input 100 :output 9000 :cost 0.0001 :context 100)
                      (:type done :stop-reason end-turn)))))
      (harness-on 'agent/call-usage (lambda (sid usage) (push (cons sid usage) calls)))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "hello")) :stop-reason)))
      (should (equal (list (cons id '(:output 24)) (cons id '(:output 16))) (reverse calls)))
      (let ((rate (harness-call 'usage/rate id)))
        (should (= 40 (plist-get rate :output)))
        (should (= 2 (plist-get rate :calls)))
        (should (< 0.6 (plist-get rate :seconds) 10.0)))
      ;; The calls were announced, not recorded: the turn is one row.
      (let ((totals (harness-call 'usage/totals :session id)))
        (should (= 1 (plist-get totals :calls)))
        (should (= 9000 (plist-get totals :output)))))))

(provide 'harness-usage-test)
;;; harness-usage-test.el ends here
