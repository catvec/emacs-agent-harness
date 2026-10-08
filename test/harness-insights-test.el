;;; harness-insights-test.el --- Tests for the Insights report  -*- lexical-binding: t; -*-

;;; Commentary:

;; The Insights report on a small fixture: sessions of three kinds and a
;; fork, with user messages, steering, messages from the harness, tool
;; calls that work, fail, are denied, interrupted or never answered,
;; merge hints and a node before the period.  The transcripts are read
;; by the child Emacs, as in use.  Then the usage figures against the
;; usage queries, a project with a git worktree, the task board, the
;; permission decision log, the written summary with the demo model
;; (kept, refused when off, given up offline) and a scan that fails.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-sessions)
(defvar harness-tasks--table)
(defvar harness-tasks--loaded)
(defvar harness-tasks--dirty)
(defvar harness-model)
(defvar harness-naming-auto)
(defvar harness-provider-demo--delay)
(defvar harness-provider-demo-script-override)
(defvar harness-insights-model)
(defvar harness-insights-narrative)
(defvar harness-insights-record-permissions)
(defvar harness-insights--running)
(defvar harness-insights--memo)
(defvar harness-insights--narrating)
(defvar harness-insights--failed)
(defvar harness-insights--asked)
(declare-function harness-insights--digest "harness-insights")
(declare-function harness-insights--permissions-name "harness-insights")
(declare-function harness-insights--parse-narrative "harness-insights")
(declare-function harness-insights--streaks "harness-insights")

(defmacro harness-insights-test-with (&rest body)
  "Load the state layer with the demo provider, usage, tasks and insights; run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent usage tasks insights))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tasks--table)
     (setq harness-tasks--loaded t harness-tasks--dirty nil)
     (clrhash harness-insights--running)
     (clrhash harness-insights--narrating)
     (clrhash harness-insights--failed)
     (clrhash harness-insights--asked)
     (setq harness-insights--memo nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (harness-naming-auto nil)
           (harness-model "demo:scripted")
           (harness-insights-model "demo:scripted")
           (harness-insights-narrative 'auto)
           (harness-insights-record-permissions t)
           (default-directory dir))
       ,@body)))

(defun harness-insights-test-ts (days-ago hour &optional minute second)
  "Return the time DAYS-AGO days before today at HOUR:MINUTE:SECOND, local time."
  (let ((today (decode-time)))
    (float-time (encode-time (list (or second 0) (or minute 0) hour
                                   (- (decoded-time-day today) days-ago)
                                   (decoded-time-month today) (decoded-time-year today)
                                   nil -1 nil)))))

(defun harness-insights-test-since ()
  "The start of the fixture's period: a week ago, at midnight."
  (harness-insights-test-ts 7 0))

(defun harness-insights-test-node (sid kind ts &rest plist)
  "Append a KIND node at TS with PLIST to session SID; return it."
  (harness-call 'session/append sid (append (list :kind kind :ts ts) plist)))

(defun harness-insights-test-call (sid tool call-id ts &rest result)
  "Append a TOOL call CALL-ID at TS to SID, and RESULT, its result's plist, a few seconds later.
RESULT nil leaves the call unanswered."
  (harness-insights-test-node sid 'tool-call ts :tool tool :call-id call-id :input (list :x 1))
  (when result
    (apply #'harness-insights-test-node sid 'tool-result (+ ts 5) :call-id call-id result)))

(defun harness-insights-test-session (cwd name &rest plist)
  "Create a demo session in CWD named NAME, PLIST added; return its id."
  (plist-get (apply #'harness-call 'session/create :cwd cwd :model "demo:scripted" :name name plist) :id))

(defun harness-insights-test-fixture ()
  "Make the sessions of the fixture; return a plist of their ids and projects."
  (let* ((pa (harness-test-temp-dir))
         (pb (harness-test-temp-dir))
         (s0 (harness-insights-test-session pa "Old work"))
         (s1 (harness-insights-test-session pa "Parser work"))
         (t1 (harness-insights-test-session pa "Implement X"))
         (s2 (harness-insights-test-session pb "Quick question"))
         (tasks (harness-sender-system "tasks")))
    ;; Before the period: nothing of it counts.
    (harness-insights-test-node s0 'user (harness-insights-test-ts 20 9) :content "Long ago")
    (harness-insights-test-node s0 'assistant (harness-insights-test-ts 20 9 1) :content "Done")
    ;; A main session over two days.
    (harness-insights-test-node s1 'user (harness-insights-test-ts 5 9) :content "Fix the parser,\n  please")
    (harness-insights-test-node s1 'assistant (harness-insights-test-ts 5 9 1) :content "Looking")
    (harness-insights-test-call s1 "read_file" "c1" (harness-insights-test-ts 5 9 2)
                                :output "text" :meta (list :duration 0.5))
    (harness-insights-test-call s1 "bash" "c2" (harness-insights-test-ts 5 9 3)
                                :output "boom" :is-error t :meta (list :duration 2.0))
    (harness-insights-test-call s1 "bash" "c3" (harness-insights-test-ts 5 9 4)
                                :output "Denied" :is-error t :meta (list :denied t))
    (harness-insights-test-node s1 'user (harness-insights-test-ts 5 9 5) :content "also the tests"
                                :meta (list :steering t))
    (harness-insights-test-node s1 'assistant (harness-insights-test-ts 5 9 6) :content "Fixed")
    (harness-insights-test-node s1 'user (harness-insights-test-ts 1 14) :content "Now the docs")
    (harness-insights-test-call s1 "edit_file" "c4" (harness-insights-test-ts 1 14 1))
    (harness-insights-test-call s1 "bash" "c5" (harness-insights-test-ts 1 14 2)
                                :output "stopped" :meta (list :interrupted t))
    (harness-insights-test-node s1 'user (harness-insights-test-ts 1 14 30) :content "From the board"
                                :meta (list :from tasks))
    ;; A task's session: its prompt comes from the board, and its merge met a conflict.
    (harness-insights-test-node t1 'user (harness-insights-test-ts 3 11) :content "Implement X" :meta (list :from tasks))
    (harness-insights-test-node t1 'assistant (harness-insights-test-ts 3 11 5) :content "Implemented")
    (harness-insights-test-node t1 'tool-call (harness-insights-test-ts 3 11 6) :tool "bash" :call-id "m1"
                                :input (list :command "git status") :meta (list :from (harness-sender-system "merge queue")))
    (harness-insights-test-node t1 'hint (harness-insights-test-ts 3 12)
                                :content "Merge into main has conflicts in a.el; session x resolves them in this worktree")
    (harness-insights-test-node t1 'hint (harness-insights-test-ts 3 12 30) :content "Merge into main finished: merged")
    ;; Another project.
    (harness-insights-test-node s2 'user (harness-insights-test-ts 2 22) :content "Quick question")
    (harness-insights-test-node s2 'assistant (harness-insights-test-ts 2 22 1) :content "Answer")
    ;; A fork of the main session: its parent's path is not its work.
    (let ((f1 (plist-get (harness-test-await (harness-call 'session/fork s1 :name "Parser, take two")) :id)))
      (harness-insights-test-node f1 'user (harness-insights-test-ts 2 10) :content "Try another approach")
      (harness-insights-test-call f1 "grep" "c6" (harness-insights-test-ts 2 10 1) :output "hits")
      (list :pa (file-name-as-directory (expand-file-name pa)) :pb (file-name-as-directory (expand-file-name pb))
            :s0 s0 :s1 s1 :t1 t1 :s2 s2 :f1 f1))))

(defun harness-insights-test-compute (&rest opts)
  "Compute the report of OPTS (default: the fixture's week); return it."
  (harness-test-await (apply #'harness-call 'insights/compute
                             (or opts (list :since (harness-insights-test-since) :period '7d)))
                      60))

(defun harness-insights-test-find (key value list)
  "Return the plist of LIST whose KEY is VALUE."
  (cl-find value list :key (lambda (p) (plist-get p key)) :test #'equal))

;;;; The transcripts

(ert-deftest harness-insights-counts-the-transcripts ()
  "Sessions, turns, messages, tools and activity of the fixture's week,
each node counted once and by the session that wrote it."
  (harness-insights-test-with
    (let* ((fx (harness-insights-test-fixture))
           (s1 (plist-get fx :s1)) (t1 (plist-get fx :t1)) (f1 (plist-get fx :f1)))
      (puthash "t-1" (list :id "t-1" :project (plist-get fx :pa) :prompt "Implement X" :session t1
                           :state 'done :merged t :created (harness-insights-test-ts 3 10)
                           :started (harness-insights-test-ts 3 11) :finished (harness-insights-test-ts 3 12 30))
               harness-tasks--table)
      (let* ((report (harness-insights-test-compute))
             (sessions (plist-get report :sessions))
             (rows (plist-get report :session-list)))
        (should-not (plist-get report :scan-error))
        ;; Four sessions worked: two main ones, the task's and the fork.
        (should (= 4 (plist-get sessions :active)))
        (should (equal '(("fork" . 1) ("main" . 2) ("task" . 1))
                       (sort (mapcar (lambda (k) (cons (plist-get k :kind) (plist-get k :sessions)))
                                     (plist-get sessions :by-kind))
                             (lambda (a b) (string< (car a) (car b))))))
        (should (equal "main" (plist-get (car (plist-get sessions :by-kind)) :kind)))
        (should-not (harness-insights-test-find :id (plist-get fx :s0) rows))
        ;; Turns: not the steering; messages: only what the user wrote.
        (should (= 6 (plist-get sessions :turns)))
        (should (= 5 (plist-get sessions :messages)))
        (let ((row (harness-insights-test-find :id s1 rows)))
          (should (equal "Parser work" (plist-get row :name)))
          (should (equal "Fix the parser, please" (plist-get row :prompt)))
          (should (= 3 (plist-get row :turns)))
          (should (= 3 (plist-get row :messages)))
          (should (= 5 (plist-get row :tools)))
          (should (= 1 (plist-get row :errors)))
          (should (= 1 (plist-get row :denied)))
          ;; 09:00 to 09:06 and 14:00 to 14:02:05; the half hour before
          ;; the board's message was idle.
          (should (< (abs (- 485 (plist-get row :active))) 1e-6)))
        (let ((row (harness-insights-test-find :id t1 rows)))
          (should (equal "task" (plist-get row :kind)))
          (should (equal "t-1" (plist-get row :task)))
          (should (equal "Implement X" (plist-get row :prompt)))
          (should (= 0 (plist-get row :messages)))
          ;; The merge queue's own call is not the model's.
          (should (= 0 (plist-get row :tools))))
        (let ((row (harness-insights-test-find :id f1 rows)))
          (should (equal "fork" (plist-get row :kind)))
          (should (equal "Try another approach" (plist-get row :prompt)))
          (should (= 1 (plist-get row :tools))))
        ;; Newest first; the busiest by active time.
        (should (equal s1 (plist-get (car rows) :id)))
        (should (equal s1 (plist-get (car (plist-get report :busiest-sessions)) :id)))
        ;; Tools.
        (let ((bash (harness-insights-test-find :tool "bash" (plist-get report :tools))))
          (should (equal "bash" (plist-get (car (plist-get report :tools)) :tool)))
          (should (equal '(3 1 1 1 0) (mapcar (lambda (k) (plist-get bash k))
                                                '(:calls :errors :denied :interrupted :unanswered))))
          (should (= 2.0 (plist-get bash :seconds))))
        (should (= 1 (plist-get (harness-insights-test-find :tool "edit_file" (plist-get report :tools)) :unanswered)))
        (should (equal '(:calls 6 :errors 1 :denied 1 :interrupted 1) (plist-get report :tool-totals)))
        ;; Activity: the hours and days the user wrote.
        (let* ((activity (plist-get report :activity))
               (hours (plist-get activity :hours))
               (weekday (lambda (days-ago)
                          (mod (+ 6 (decoded-time-weekday (decode-time (harness-insights-test-ts days-ago 12)))) 7)))
               (expected (make-list 7 0)))
          (should (equal '(2 1 1 1) (list (nth 9 hours) (nth 10 hours) (nth 14 hours) (nth 22 hours))))
          (should (= 5 (apply #'+ hours)))
          (dolist (d '(5 5 2 2 1)) (cl-incf (nth (funcall weekday d) expected)))
          (should (equal expected (plist-get activity :weekdays)))
          (should (= 3 (plist-get activity :active-days)))
          (should (= 2 (plist-get activity :longest-streak)))
          (should (equal (format-time-string "%Y-%m-%d" (harness-insights-test-ts 1 12))
                         (plist-get activity :longest-streak-end)))
          (should (= 2 (plist-get activity :current-streak))))
        ;; Projects, by main checkout.
        (let ((pa (harness-insights-test-find :main (plist-get fx :pa) (plist-get report :projects))))
          (should (= 3 (plist-get pa :sessions))))
        ;; The merge hints of the task's session say its merge met a conflict.
        (should (= 1 (plist-get (plist-get report :tasks) :conflicted)))))))

(ert-deftest harness-insights-streaks ()
  "The longest run of days, when it ended, and the run up to today or yesterday."
  (require 'harness-insights)
  (let ((days (make-hash-table)))
    (dolist (d '(10 11 12 20 21 29 30)) (puthash d t days))
    (should (equal '(3 12 2) (harness-insights--streaks days 30)))
    (should (equal '(3 12 2) (harness-insights--streaks days 31)))
    (should (equal '(3 12 0) (harness-insights--streaks days 32)))
    (should (equal '(0 nil 0) (harness-insights--streaks (make-hash-table) 30)))))

(ert-deftest harness-insights-a-failed-scan-leaves-the-rest ()
  "When the transcripts cannot be read, the report still has usage and tasks."
  (harness-insights-test-with
    (harness-insights-test-fixture)
    (harness-call 'usage/record (list :ts (float-time) :session "s" :project dir :model "demo:scripted" :cost 1.5))
    (cl-letf (((symbol-function 'harness-insights--scan-file) (lambda () "/nonexistent/harness-insights.elc")))
      (let ((report (harness-insights-test-compute)))
        (should (stringp (plist-get report :scan-error)))
        (should (= 0 (plist-get (plist-get report :sessions) :active)))
        (should (= 1.5 (plist-get (plist-get (plist-get report :usage) :totals) :cost)))
        (should (plist-get report :tasks))))))

(ert-deftest harness-insights-shares-a-report-being-computed ()
  "Asked twice while it is computed, the report is computed once."
  (harness-insights-test-with
    (let* ((since (harness-insights-test-since))
           (a (harness-call 'insights/compute :since since :period '7d))
           (b (harness-call 'insights/compute :since since :period '7d))
           (other (harness-call 'insights/compute :since since :period '30d)))
      (should (eq a b))
      (should-not (eq a other))
      (should (equal (plist-get (harness-test-await a 60) :generated)
                     (plist-get (harness-test-await b 60) :generated)))
      (harness-test-await other 60)
      (should (= 0 (hash-table-count harness-insights--running))))))

;;;; Usage

(ert-deftest harness-insights-usage-is-the-dashboards ()
  "The usage figures are the usage queries' for the same period."
  (harness-insights-test-with
    (let* ((since (harness-insights-test-since))
           (pa (file-name-as-directory (harness-test-temp-dir)))
           (pb (file-name-as-directory (harness-test-temp-dir))))
      (cl-loop for (project model days cost) in `((,pa "demo:scripted" 2 1.0) (,pa "openai:gpt-x" 1 2.0)
                                                  (,pb "deepseek:chat" 3 4.0) (,pa "demo:scripted" 30 8.0))
               do (harness-call 'usage/record (list :ts (harness-insights-test-ts days 12) :session "s"
                                                    :project project :model model :input 100 :output 10
                                                    :cost cost)))
      (let* ((report (harness-insights-test-compute))
             (usage (plist-get report :usage)))
        (should (equal (harness-call 'usage/totals :since since) (plist-get usage :totals)))
        (should (= 7.0 (plist-get (plist-get usage :totals) :cost)))
        (should (equal (harness-call 'usage/summary :group-by 'model :since since) (plist-get usage :by-model)))
        (should (equal (harness-call 'usage/series :bucket 'day :since since) (plist-get usage :series)))
        (should (eq 'day (plist-get usage :bucket)))
        (should (equal '(("deepseek" . 4.0) ("openai" . 2.0) ("demo" . 1.0))
                       (mapcar (lambda (r) (cons (plist-get r :key) (plist-get r :cost)))
                               (plist-get usage :by-provider))))
        (should (equal (list (cons pb 4.0) (cons pa 3.0))
                       (mapcar (lambda (r) (cons (plist-get r :key) (plist-get r :cost)))
                               (plist-get usage :projects)))))
      ;; A project without usage has none, rather than everyone's.
      (let ((usage (plist-get (harness-insights-test-compute :since since :project (harness-test-temp-dir)) :usage)))
        (should (= 0 (plist-get (plist-get usage :totals) :calls)))
        (should-not (plist-get usage :series)))
      ;; Today goes by the hour.
      (should (eq 'hour (plist-get (plist-get (harness-insights-test-compute :since (harness-insights-test-ts 0 0)
                                                                              :period 'today)
                                              :usage)
                                   :bucket))))))

(defun harness-insights-test--git (dir &rest args)
  "Run git ARGS in DIR; signal on failure."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string))))))

(ert-deftest harness-insights-a-project-counts-its-worktrees ()
  "Narrowed to a project, the report counts its git worktrees' sessions,
usage and decisions, and the worktree's own report is the project's."
  (harness-insights-test-with
    (let* ((base (file-truename (harness-test-temp-dir)))
           (root (file-name-as-directory (expand-file-name "repo" base)))
           (wt (file-name-as-directory (expand-file-name ".worktrees/task-a" root)))
           (other (harness-test-temp-dir))
           (since (harness-insights-test-since)))
      (make-directory root t)
      (harness-insights-test--git root "init" "-q" "-b" "main")
      (harness-insights-test--git root "-c" "user.name=t" "-c" "user.email=t@example.invalid" "-c" "commit.gpgsign=false"
                                  "commit" "-q" "--allow-empty" "-m" "initial")
      (harness-insights-test--git root "worktree" "add" "-q" "-b" "task/a" wt)
      (let ((main (harness-insights-test-session root "In the checkout"))
            (task (harness-insights-test-session wt "In the worktree"))
            (elsewhere (harness-insights-test-session other "Elsewhere")))
        (dolist (sid (list main task elsewhere))
          (harness-insights-test-node sid 'user (harness-insights-test-ts 2 10) :content "Work")
          (harness-insights-test-call sid "bash" (concat "c-" sid) (harness-insights-test-ts 2 10 1) :output "ok"))
        (cl-loop for (project cost) in `((,root 1.0) (,wt 2.0) (,other 4.0))
                 do (harness-call 'usage/record (list :ts (harness-insights-test-ts 2 12) :session "s"
                                                      :project project :model "demo:scripted" :cost cost)))
        (harness-emit 'permission/decided task (list :tool "bash" :call-id "x1") (list :behavior 'deny))
        (harness-emit 'permission/decided elsewhere (list :tool "bash" :call-id "x2") (list :behavior 'deny))
        ;; The worktree is no project of its own.
        (should (equal (sort (list root (file-name-as-directory (expand-file-name other))) #'string<)
                       (harness-call 'insights/projects)))
        (let ((report (harness-insights-test-compute :since since :project wt :period '7d)))
          (should (equal root (plist-get report :project)))
          (should (= 2 (plist-get (plist-get report :sessions) :active)))
          (should (= 3.0 (plist-get (plist-get (plist-get report :usage) :totals) :cost)))
          (should (equal (list wt root)
                         (sort (mapcar (lambda (r) (plist-get r :key)) (plist-get (plist-get report :usage) :projects))
                               #'string>)))
          (should (= 1 (plist-get (plist-get report :permissions) :decisions))))
        (let ((all (harness-insights-test-compute)))
          (should (= 3 (plist-get (plist-get all :sessions) :active)))
          (should (= 7.0 (plist-get (plist-get (plist-get all :usage) :totals) :cost)))
          (should (equal 3.0 (plist-get (harness-insights-test-find :key root (plist-get (plist-get all :usage) :projects))
                                        :cost)))
          (should (= 2 (plist-get (plist-get all :permissions) :decisions))))))))

;;;; Tasks

(ert-deftest harness-insights-task-figures ()
  "Submitted, completed, merged, sent back, failed, accepted the first
time, merges that met a conflict, and the tasks worth a look."
  (harness-insights-test-with
    (let ((p (file-name-as-directory (harness-test-temp-dir)))
          (q (file-name-as-directory (harness-test-temp-dir)))
          (ts #'harness-insights-test-ts))
      (dolist (task
               (list (list :id "t-a" :project p :prompt "First try" :state 'done :merged t :conflicts '("a.el")
                           :created (funcall ts 4 9) :started (funcall ts 4 10) :finished (funcall ts 4 11))
                     (list :id "t-b" :project p :prompt "Sent back once" :state 'done :merged t
                           :feedback (list (list :text "Fix the tests" :at (funcall ts 3 9)))
                           :created (funcall ts 4 9) :started (funcall ts 4 9) :finished (funcall ts 2 9))
                     (list :id "t-c" :project p :prompt "In review\nmore" :state 'review :outcome 'end-turn
                           :created (funcall ts 1 9) :started (funcall ts 1 9))
                     (list :id "t-d" :project p :prompt "Failed" :state 'active :outcome 'error
                           :created (funcall ts 2 9) :started (funcall ts 2 9))
                     (list :id "t-e" :project p :prompt "Old" :state 'done :finished (funcall ts 30 9)
                           :created (funcall ts 31 9) :started (funcall ts 31 9))
                     (list :id "t-f" :project q :prompt "Elsewhere" :state 'done :verified-at (funcall ts 1 9)
                           :created (funcall ts 2 9) :started (funcall ts 2 10) :finished (funcall ts 1 8))
                     (list :id "t-g" :project p :prompt "Waiting" :state 'pending :created (- (float-time) 60))))
        (puthash (plist-get task :id) task harness-tasks--table))
      (let ((tasks (plist-get (harness-insights-test-compute) :tasks)))
        (should (equal '(6 3 2 2 1 1 1 1)
                       (mapcar (lambda (k) (plist-get tasks k))
                               '(:submitted :completed :merged :first-try :sent-back :feedback-rounds
                                 :failed :conflicted))))
        ;; Done minus started: 1h, 2 days, 23h.
        (should (= (* 23 3600) (plist-get tasks :median-time)))
        (should (equal '("t-d" "t-b" "t-c" "t-f" "t-a")
                       (mapcar (lambda (n) (plist-get n :id)) (plist-get tasks :notable))))
        (should (equal "In review" (plist-get (harness-insights-test-find :id "t-c" (plist-get tasks :notable)) :title)))
        (should (equal '(("needs-input" . 1) ("pending" . 1) ("review" . 1))
                       (sort (mapcar (lambda (c) (cons (plist-get c :column) (plist-get c :count))) (plist-get tasks :open))
                             (lambda (a b) (string< (car a) (car b)))))))
      ;; Narrowed to Q.
      (let ((tasks (plist-get (harness-insights-test-compute :since (harness-insights-test-since) :project q) :tasks)))
        (should (equal '(1 1 0) (mapcar (lambda (k) (plist-get tasks k)) '(:submitted :completed :merged))))))))

;;;; Permissions

(ert-deftest harness-insights-logs-permission-decisions ()
  "Each decision is logged with whether the user was asked; the log can be off."
  (harness-insights-test-with
    (let* ((sid (harness-insights-test-session dir "Asking"))
           (log (harness-insights--permissions-name (float-time))))
      (harness-emit 'permission/requested sid (list :kind 'permission :id "q1"
                                                    :payload (list :tool "bash" :call-id "c1")))
      (harness-emit 'permission/decided sid (list :tool "bash" :call-id "c1") (list :behavior 'allow))
      (harness-emit 'permission/requested sid (list :kind 'permission :id "q2"
                                                    :payload (list :tool "write_file" :call-id "c2")))
      (harness-emit 'permission/decided sid (list :tool "write_file" :call-id "c2") (list :behavior 'deny))
      ;; Decided by a rule, without asking.
      (harness-emit 'permission/decided sid (list :tool "read_file" :call-id "c3") (list :behavior 'allow))
      (harness-emit 'permission/decided sid (list :tool "bash" :call-id "c4") (list :behavior 'deny))
      (let ((records (harness-call 'store/read-all log)))
        (should (= 4 (length records)))
        (should (equal '(("bash" "allow" t) ("write_file" "deny" t) ("read_file" "allow" :false) ("bash" "deny" :false))
                       (mapcar (lambda (r) (list (plist-get r :tool) (plist-get r :behavior) (plist-get r :asked)))
                               records)))
        (should (cl-every (lambda (r) (equal sid (plist-get r :session))) records)))
      (should (= 0 (hash-table-count harness-insights--asked)))
      (let ((harness-insights-record-permissions nil))
        (harness-emit 'permission/decided sid (list :tool "bash" :call-id "c5") (list :behavior 'allow))
        (should (= 4 (length (harness-call 'store/read-all log)))))
      (let ((perms (plist-get (harness-insights-test-compute) :permissions)))
        (should (equal '(4 2 2 2 1 1)
                       (mapcar (lambda (k) (plist-get perms k))
                               '(:decisions :allowed :denied :asked :asked-allowed :asked-denied))))
        (should (equal "bash" (plist-get (car (plist-get perms :tools)) :tool)))))))

;;;; The written summary

(defmacro harness-insights-test-counting-requests (var &rest body)
  "Run BODY with VAR counting the requests made to providers."
  (declare (indent 1))
  `(let ((,var 0))
     (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                ((symbol-function 'harness-method/provider/complete)
                 (lambda (req) (cl-incf ,var) (funcall orig req))))
       ,@body)))

(defun harness-insights-test-narrative (&rest opts)
  "Ask for the summary of the fixture's week with OPTS added; return it."
  (harness-test-await (apply #'harness-call 'insights/narrative :since (harness-insights-test-since) :period '7d opts)
                      60))

(ert-deftest harness-insights-writes-and-keeps-a-summary ()
  "The configured model writes the summary from the figures; it is kept
for the period and shown in the report, and written again on request."
  (harness-insights-test-with
    (harness-insights-test-fixture)
    (harness-insights-test-counting-requests requests
      (let ((entry (harness-insights-test-narrative)))
        (should (= 1 requests))
        (should (equal "demo:scripted" (plist-get entry :model)))
        (should (string-match-p "\\`You ran 4 sessions" (plist-get entry :summary)))
        (should (member "Parser, take two: Try another approach" (plist-get entry :themes)))
        (should (string-match-p "bash" (car (plist-get entry :friction))))
        (should (= 2 (length (plist-get entry :suggestions))))
        ;; Kept: asked again, no new call.
        (should (equal (plist-get entry :at) (plist-get (harness-insights-test-narrative) :at)))
        (should (= 1 requests))
        (should (equal (plist-get entry :summary)
                       (plist-get (plist-get (harness-insights-test-compute) :narrative) :summary)))
        (should-not (plist-get (plist-get (harness-insights-test-compute) :narrative) :stale))
        ;; Another period has its own.
        (should-not (plist-get (harness-insights-test-compute :since (harness-insights-test-ts 30 0) :period '30d)
                               :narrative))
        ;; Written again on request.
        (should (plist-get (harness-insights-test-narrative :refresh t) :summary))
        (should (= 2 requests))
        ;; Old, it is shown as stale.
        (let ((harness-insights-narrative-max-age 0))
          (should (plist-get (plist-get (harness-insights-test-compute) :narrative) :stale))))
      ;; Its cost is recorded like any other.
      (should (cl-some (lambda (r) (equal "demo:scripted" (plist-get r :key)))
                       (harness-call 'usage/summary :group-by 'model))))))

(ert-deftest harness-insights-summary-off-or-offline ()
  "Off, nothing is asked; offline, the report has no summary and the
failure is not tried again at once."
  (harness-insights-test-with
    (harness-insights-test-fixture)
    (harness-insights-test-counting-requests requests
      (let ((harness-insights-narrative nil))
        (should (plist-get (harness-insights-test-narrative) :skipped))
        (should (plist-get (harness-insights-test-narrative :refresh t) :skipped))
        (should (= 0 requests)))
      (let ((harness-provider-demo-script-override '((:type done :stop-reason error :error "offline"))))
        (let ((skipped (harness-insights-test-narrative)))
          (should (plist-get skipped :error))
          (should (string-match-p "offline" (plist-get skipped :skipped))))
        (should (= 1 requests))
        (should (plist-get (harness-insights-test-narrative) :error))
        (should (= 1 requests))
        (should (plist-get (harness-insights-test-narrative :refresh t) :error))
        (should (= 2 requests))
        ;; The figures are all there.
        (should (= 4 (plist-get (plist-get (harness-insights-test-compute) :sessions) :active))))
      ;; No model at all.
      (let ((harness-model nil) (harness-insights-model nil))
        (should (plist-get (harness-insights-test-narrative :refresh t) :skipped))
        (should (= 2 requests))))))

(ert-deftest harness-insights-summary-of-a-quiet-period ()
  "A period with nothing in it gets no summary, and no model is asked."
  (harness-insights-test-with
    (harness-insights-test-counting-requests requests
      (should (string-match-p "Nothing happened" (plist-get (harness-insights-test-narrative) :skipped)))
      (should (= 0 requests)))))

(ert-deftest harness-insights-reads-what-models-answer ()
  "The JSON asked for, with a fence or items as objects; or plain text."
  (require 'harness-insights)
  (let ((parsed (harness-insights--parse-narrative
                 "```json\n{\"summary\": \" A week. \", \"themes\": [\"Parser\", {\"title\": \"Docs\", \"detail\": \"rewrote them\"}],
 \"friction\": [], \"suggestions\": [\"Try tasks\"]}\n```")))
    (should (equal "A week." (plist-get parsed :summary)))
    (should (equal '("Parser" "Docs: rewrote them") (plist-get parsed :themes)))
    (should (equal '("Try tasks") (plist-get parsed :suggestions))))
  (should (equal '(:summary "Just words.") (harness-insights--parse-narrative "  Just words. ")))
  (should-not (harness-insights--parse-narrative "  ")))

(ert-deftest harness-insights-digest-names-the-work ()
  "What the model reads: the figures in words and the sessions' requests."
  (harness-insights-test-with
    (harness-insights-test-fixture)
    (let ((digest (harness-insights--digest (harness-insights-test-compute))))
      (should (string-match-p "^Sessions: 4 worked in the period" digest))
      (should (string-match-p "^Tools: 6 calls, 17% failed, 17% denied\\. Most used: bash 3" digest))
      (should (string-match-p "^- main, Parser work: Fix the parser, please$" digest))
      (should (string-match-p "^- main, Implement X: Implement X$" digest))
      ;; Without tasks, no word of them.
      (should-not (string-match-p "^Tasks:" digest))
      ;; Newest work first; a fork's is its own, not its making.
      (should (string-match-p (concat "^- main, Parser work: .*\n- main, Quick question: .*\n"
                                      "- fork, Parser, take two: .*\n- main, Implement X: ")
                              digest)))))

(provide 'harness-insights-test)
;;; harness-insights-test.el ends here
