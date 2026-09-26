;;; harness-usage-test.el --- Tests for usage accounting -*- lexical-binding: t; -*-

;;; Commentary:

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-session)
(require 'harness-usage)
(require 'harness-test-helpers)

(harness-module-load 'harness-session)
(harness-module-load 'harness-usage)

(defun harness-usage-test--setup ()
  "Isolate session storage and reset budgets."
  (let ((harness-session-storage-directory (make-temp-file "harness-usage-" t)))
    (clrhash harness-session--active)
    (clrhash harness-session--project-ids)
    (setq harness-session--by-project nil
          harness-usage-budgets nil)
    harness-session-storage-directory))

(defun harness-usage-test--session (directory &optional title)
  "Create a session in DIRECTORY with TITLE."
  (let ((session (harness-session-create :cwd directory :title title)))
    (harness-session-set-config session "model" "test/model")
    session))

(defun harness-usage-test--cost (session amount)
  "Add a costed usage entry to SESSION."
  (harness-session-append
   session
   (list :sessionUpdate "usage_update"
         :model (harness-session-model session)
         :usage '(:input 100 :output 20 :cache-read 0 :cache-write 0)
         :cost (list :amount amount :currency "USD")))
  (harness-session-add-usage session :input 100 :output 20)
  (harness-session-add-cost session amount "USD"))

(ert-deftest harness-usage-period-starts ()
  ;; 2026-09-26 is a Saturday.
  (let ((now (float-time (encode-time (list 10 30 0 26 9 2026 nil -1 nil)))))
    (should (= (harness-usage-period-start 'all now) 0))
    (should (= (harness-usage-period-start 'daily now)
               (float-time (encode-time (list 0 0 0 26 9 2026 nil -1 nil)))))
    ;; The week starts on Monday by default.
    (should (= (harness-usage-period-start 'weekly now)
               (float-time (encode-time (list 0 0 0 21 9 2026 nil -1 nil)))))
    (should (= (harness-usage-period-start 'monthly now)
               (float-time (encode-time (list 0 0 0 1 9 2026 nil -1 nil)))))))

(ert-deftest harness-usage-session-usage-entries-read-transcripts ()
  (setq harness-session-storage-directory (harness-usage-test--setup))
  (let* ((directory (make-temp-file "harness-usage-proj-" t))
         (session (harness-usage-test--session directory "One")))
    (harness-usage-test--cost session 0.25)
    (harness-session-save session)
    ;; A fresh call reads the transcript from disk.
    (let ((entries (append (harness-session-usage-entries) nil)))
      (should (= (length entries) 1))
      (should (equal (plist-get (car entries) :sessionId) (harness-session-id session)))
      (should (equal (plist-get (car entries) :projectRoot)
                     (harness-session-project-root session)))
      (should (equal (plist-get (plist-get (car entries) :cost) :amount) 0.25))
      (should (plist-get (car entries) :time)))
    ;; Filtering by since excludes older sessions.
    (should (null (append (harness-session-usage-entries (+ (float-time) 100)) nil)))))

(ert-deftest harness-usage-summary-aggregates ()
  (setq harness-session-storage-directory (harness-usage-test--setup))
  (let* ((project-a (make-temp-file "harness-usage-a-" t))
         (project-b (make-temp-file "harness-usage-b-" t))
         (s1 (harness-usage-test--session project-a "A one"))
         (s2 (harness-usage-test--session project-a "A two"))
         (s3 (harness-usage-test--session project-b "B one")))
    (harness-usage-test--cost s1 0.10)
    (harness-usage-test--cost s2 0.20)
    (harness-usage-test--cost s3 0.40)
    (dolist (session (list s1 s2 s3))
      (harness-session-save session))
    (let* ((summary (harness-usage-summary))
           (totals (plist-get summary :totals))
           (projects (plist-get summary :projects))
           (sessions (append (plist-get summary :sessions) nil)))
      (should (= (plist-get totals :sessions) 3))
      (should (= (plist-get totals :input) 300))
      (should (= (plist-get totals :output) 60))
      (should (< (abs (- (plist-get (plist-get totals :cost) :amount) 0.70)) 0.0001))
      ;; Projects are sorted by cost, highest first.
      (should (= (length projects) 2))
      (should (equal (plist-get (car projects) :key) (file-name-as-directory project-b)))
      (should (< (abs (- (plist-get (plist-get (car projects) :cost) :amount) 0.40)) 0.0001))
      ;; Models group under the configured model.
      (should (equal (plist-get (car (plist-get summary :models)) :key) "test/model"))
      ;; Every session appears with its cost.
      (should (= (length sessions) 3))
      (should (cl-some (lambda (entry)
                         (and (equal (plist-get entry :title) "B one")
                              (numberp (plist-get (plist-get entry :cost) :amount))))
                       sessions)))))

(ert-deftest harness-usage-budgets-report-over-spend ()
  (setq harness-session-storage-directory (harness-usage-test--setup))
  (let* ((project (make-temp-file "harness-usage-budget-" t))
         (session (harness-usage-test--session project "Budgeted")))
    (harness-usage-test--cost session 0.50)
    (harness-session-save session)
    (setq harness-usage-budgets
          (list (list :scope 'project :project project :period 'all
                      :amount 0.40 :hard t :currency "USD")))
    (let* ((summary (harness-usage-summary))
           (budget (car (plist-get summary :budgets))))
      (should (plist-get budget :over))
      (should (plist-get budget :hard))
      (should (> (plist-get budget :spent) (plist-get budget :amount)))
      (should (< (plist-get budget :remaining) 0)))
    ;; A hard budget blocks the session's turns.
    (let ((check (harness-usage-service-budget-check :session-id (harness-session-id session))))
      (should (plist-get check :blocked))
      (should (string-match-p "over budget" (plist-get check :reason))))
    ;; An informational budget only reports.
    (setq harness-usage-budgets
          (list (list :scope 'project :project project :period 'all
                      :amount 0.40 :hard nil)))
    (should-not (harness-usage-service-budget-check :session-id (harness-session-id session)))))

(ert-deftest harness-usage-budget-period-ignores-old-spend ()
  (setq harness-session-storage-directory (harness-usage-test--setup))
  (let* ((project (make-temp-file "harness-usage-period-" t))
         (session (harness-usage-test--session project "Period"))
         (old-time (harness-iso-time (- (float-time) (* 200 86400)))))
    (harness-session-append
     session
     (list :sessionUpdate "usage_update" :time old-time
           :model "test/model"
           :usage '(:input 100 :output 10)
           :cost (list :amount 5.0 :currency "USD")))
    (harness-session-save session)
    (should (< (harness-usage--period-spend 'monthly) 5.0))
    (should (= (harness-usage--period-spend 'all) 0.0))))

(ert-deftest harness-usage-per-session-budgets ()
  (setq harness-session-storage-directory (harness-usage-test--setup))
  (let* ((project (make-temp-file "harness-usage-session-" t))
         (one (harness-usage-test--session project "One"))
         (two (harness-usage-test--session project "Two"))
         (one-id (harness-session-id one)))
    (harness-usage-test--cost one 0.30)
    (harness-usage-test--cost two 0.50)
    (harness-session-save one)
    (harness-session-save two)
    (setq harness-usage-budgets
          (list (list :scope 'session :session-id one-id :period 'all :amount 0.20 :hard t)))
    (let* ((summary (harness-usage-summary))
           (budget (car (plist-get summary :budgets))))
      (should (plist-get budget :over))
      (should (< (abs (- (plist-get budget :spent) 0.30)) 0.0001))
      (should (string-match-p "session" (plist-get budget :label))))
    ;; The budget only blocks its own session.
    (should (plist-get (harness-usage-service-budget-check :session-id one-id) :blocked))
    (should-not (harness-usage-service-budget-check
                 :session-id (harness-session-id two)))))

(provide 'harness-usage-test)
;;; harness-usage-test.el ends here
