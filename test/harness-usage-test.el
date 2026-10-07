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
     (let ((harness-provider-demo--delay 0.005)
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

(ert-deftest harness-usage-project-budgets ()
  "A project's budgets are its project budgets and the period budgets of
everything or of it; another project's and a session's are not."
  (harness-usage-test-with
    ;; Wednesday 2026-09-16 at noon; both rows fall in its week and month.
    (let* ((now (harness-usage-test-ts 2026 9 16))
           (root (harness-test-temp-dir))
           (other (harness-test-temp-dir))
           (sid (harness-usage-test-session))
           (labels (lambda (statuses) (mapcar (lambda (st) (plist-get (plist-get st :budget) :label)) statuses))))
      (harness-call 'usage/record (list :ts (harness-usage-test-ts 2026 9 15) :session "s" :project root
                                        :model "m" :cost 3.0))
      (harness-call 'usage/record (list :ts (harness-usage-test-ts 2026 9 15) :session "t" :project other
                                        :model "m" :cost 5.0))
      (harness-call 'usage/set-budget (list :scope 'project :target (directory-file-name root) :amount 10 :label "mine"))
      (harness-call 'usage/set-budget '(:scope period :period month :amount 100 :label "everything"))
      (harness-call 'usage/set-budget (list :scope 'period :period 'week :target root :amount 20 :label "weekly mine"))
      (harness-call 'usage/set-budget (list :scope 'project :target other :amount 10 :label "theirs"))
      (harness-call 'usage/set-budget (list :scope 'session :target sid :amount 1 :label "a session's"))
      ;; The root names the project however it is written.
      (let ((statuses (harness-call 'usage/project-budgets (directory-file-name root) :now now)))
        (should (equal '("mine" "everything" "weekly mine") (funcall labels statuses)))
        (should (harness-usage-test-near 3.0 (plist-get (nth 0 statuses) :spent)))
        (should (harness-usage-test-near 8.0 (plist-get (nth 1 statuses) :spent)))
        (should (harness-usage-test-near 0.15 (plist-get (nth 2 statuses) :fraction))))
      ;; Without a project only the budgets of everything apply.
      (should (equal '("everything") (funcall labels (harness-call 'usage/project-budgets nil :now now))))
      ;; A session in the project gets the same ones, and its own.
      (let ((in-root (plist-get (harness-call 'session/create :cwd root :model "demo:scripted") :id)))
        (harness-call 'usage/set-budget (list :scope 'session :target in-root :amount 2 :label "own"))
        (should (equal '("mine" "everything" "weekly mine" "own")
                       (funcall labels (harness-call 'usage/session-budgets in-root :now now))))
        ;; The Budget setting applies to them all, after the explicit ones.
        (let ((harness-budget '(:amount 50)))
          (should (equal '("mine" "everything" "weekly mine" "all sessions (setting)")
                         (funcall labels (harness-call 'usage/project-budgets root :now now))))
          (should (equal '("mine" "everything" "weekly mine" "own" "all sessions (setting)")
                         (funcall labels (harness-call 'usage/session-budgets in-root :now now)))))))))

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
