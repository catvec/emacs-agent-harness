;;; harness-ui-insights-test.el --- Tests for the Insights report buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; The report buffer over the in-process harness: a placeholder at once,
;; then every section from the figures; the summary written by the demo
;; model as the report opens, refused when summaries are off; usage
;; figures that are the usage dashboard's for the same period; the
;; period and project keys; RET on a session or task line; and the keys
;; that open it.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-ui--sessions)
(defvar harness-tasks--table)
(defvar harness-tasks--loaded)
(defvar harness-tasks--dirty)
(defvar harness-usage-budgets)
(defvar harness-fallback-models)
(defvar harness-model)
(defvar harness-naming-auto)
(defvar harness-provider-demo--delay)
(defvar harness-provider-demo-script-override)
(defvar harness-insights-model)
(defvar harness-insights-narrative)
(defvar harness-insights--running)
(defvar harness-insights--memo)
(defvar harness-insights--narrating)
(defvar harness-insights--failed)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-ui-map)
(defvar harness-ui-insights-mode-map)
(defvar harness-ui-insights--buffer-name)
(defvar harness-ui-insights--data)
(defvar harness-ui-insights--loading)
(defvar harness-ui-insights--writing)
(defvar harness-ui-insights--narrative)
(defvar harness-ui-insights--period)
(defvar harness-ui-insights--project)
(defvar harness-ui-insights--error)
(defvar harness-ui-usage--buffer-name)
(defvar harness-ui-usage--data)
(defvar harness-ui-usage--loading)
(defvar harness-ui-insights-default-period)
(declare-function harness-insights "harness-ui-insights")
(declare-function harness-usage "harness-ui-usage")
(declare-function harness-ui-insights-open "harness-ui-insights")
(declare-function harness-ui-insights-cycle-period "harness-ui-insights")
(declare-function harness-ui-insights-set-project "harness-ui-insights")
(declare-function harness-ui-insights-write "harness-ui-insights")
(declare-function harness-ui-insights--percent "harness-ui-insights")
(declare-function harness-ui-insights--number "harness-ui-insights")
(declare-function harness-ui-insights--duration "harness-ui-insights")
(declare-function harness-ui-insights--day "harness-ui-insights")
(declare-function harness-ui-insights--task-detail "harness-ui-insights")
(declare-function harness-ui-insights--parts "harness-ui-insights")
(declare-function harness-acp--drop-client "harness-acp")

(defmacro harness-ui-insights-test-with (&rest body)
  "Load the state layer, insights, ACP, the UI and the report, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent usage tasks insights
                          acp ui ui-usage ui-insights))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-ui--sessions)
     (clrhash harness-tasks--table)
     (clrhash harness-insights--running)
     (clrhash harness-insights--narrating)
     (clrhash harness-insights--failed)
     (setq harness-insights--memo nil
           harness-tasks--loaded t
           harness-tasks--dirty nil
           harness-usage-budgets nil
           harness-fallback-models nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (harness-naming-auto nil)
           (harness-acp-token nil)
           (harness-model "demo:scripted")
           (harness-insights-model "demo:scripted")
           (harness-insights-narrative 'auto)
           (harness-ui-insights-default-period '30d)
           (default-directory dir))
       (unwind-protect
           (progn ,@body)
         (dolist (name (list harness-ui-insights--buffer-name harness-ui-usage--buffer-name))
           (when (get-buffer name) (kill-buffer name)))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-insights-test-ts (days-ago hour &optional minute)
  "Return the time DAYS-AGO days before today at HOUR:MINUTE, local time."
  (let ((today (decode-time)))
    (float-time (encode-time (list 0 (or minute 0) hour (- (decoded-time-day today) days-ago)
                                   (decoded-time-month today) (decoded-time-year today) nil -1 nil)))))

(defun harness-ui-insights-test-fixture ()
  "Make two sessions with work in the last days, usage and a task; return the sessions' ids."
  (let* ((project (file-name-as-directory (harness-test-temp-dir)))
         (a (plist-get (harness-call 'session/create :cwd project :model "demo:scripted" :name "Parser work") :id))
         (b (plist-get (harness-call 'session/create :cwd project :model "demo:scripted" :name "Docs pass") :id))
         (node (lambda (sid kind ts &rest plist)
                 (harness-call 'session/append sid (append (list :kind kind :ts ts) plist)))))
    (funcall node a 'user (harness-ui-insights-test-ts 2 9) :content "Fix the parser")
    (funcall node a 'tool-call (harness-ui-insights-test-ts 2 9 1) :tool "bash" :call-id "c1" :input '(:command "make"))
    (funcall node a 'tool-result (harness-ui-insights-test-ts 2 9 2) :call-id "c1" :output "error" :is-error t)
    (funcall node a 'assistant (harness-ui-insights-test-ts 2 9 5) :content "Fixed")
    (funcall node b 'user (harness-ui-insights-test-ts 1 15) :content "Rewrite the docs")
    (funcall node b 'assistant (harness-ui-insights-test-ts 1 15 3) :content "Rewritten")
    (dolist (row `((2 ,project "demo:scripted" 1.25) (1 ,project "demo:other" 0.5) (45 ,project "demo:scripted" 9.0)))
      (harness-call 'usage/record (list :ts (harness-ui-insights-test-ts (nth 0 row) 12) :session a
                                        :project (nth 1 row) :model (nth 2 row) :input 1000 :output 100
                                        :cost (nth 3 row))))
    (puthash "t-1" (list :id "t-1" :project project :prompt "Tidy the docs" :session b :state 'review
                         :outcome 'end-turn :created (harness-ui-insights-test-ts 1 14)
                         :started (harness-ui-insights-test-ts 1 14))
             harness-tasks--table)
    (list :a a :b b :project project)))

(defun harness-ui-insights-test-open ()
  "Open the report and wait for its figures; return its text."
  (harness-insights)
  (set-buffer harness-ui-insights--buffer-name)
  (harness-test-wait (lambda () (and harness-ui-insights--data (not harness-ui-insights--loading))) 60 "the report")
  (harness-ui-insights-test-text))

(defun harness-ui-insights-test-text ()
  "Return the report's text."
  (with-current-buffer harness-ui-insights--buffer-name
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-insights-test-goto (regexp)
  "Move point in the report to the start of the line matching REGEXP."
  (goto-char (point-min))
  (should (re-search-forward regexp nil t))
  (goto-char (line-beginning-position)))

(ert-deftest harness-ui-insights-placeholder-then-every-section ()
  "The buffer shows at once with a placeholder; the figures and the summary follow."
  (harness-ui-insights-test-with
    (harness-ui-insights-test-fixture)
    (harness-insights)
    (with-current-buffer harness-ui-insights--buffer-name
      (should (derived-mode-p 'harness-ui-insights-mode))
      (should buffer-read-only)
      (should (string-match-p "Gathering insights" (harness-ui-insights-test-text)))
      (should harness-ui-insights--loading))
    (let ((text (harness-ui-insights-test-open)))
      (dolist (heading '("Summary" "Usage" "Projects" "Sessions" "Tools" "Permissions" "Tasks" "Activity"))
        (should (string-match-p (concat "^ " heading) text)))
      (should (string-match-p "2 sessions" text))
      (should (string-match-p "Parser work" text))
      (should (string-match-p "bash +1 .* 100%" text))
      (should (string-match-p "◆ Docs pass +waits for your review" text))
      (should (string-match-p "1 chat · 1 task$" text))
      (should (string-match-p "1 tool call " text))
      (should (string-match-p "On the board now: 1 in review" text))
      (should (string-match-p "Active on 2 days" text)))
    ;; The demo model writes the summary as the report opens.
    (with-current-buffer harness-ui-insights--buffer-name
      (harness-test-wait (lambda () (and (not harness-ui-insights--writing) harness-ui-insights--narrative)) 30 "the summary")
      (let ((text (harness-ui-insights-test-text)))
        (should (string-match-p "You ran 2 sessions" text))
        (should (string-match-p "What you worked on" text))
        (should (string-match-p "Things to try" text))
        (should (string-match-p "\\[write again\\]" text))))))

(ert-deftest harness-ui-insights-usage-is-the-dashboards ()
  "For the same period the report's usage figures are the usage dashboard's."
  (harness-ui-insights-test-with
    (harness-ui-insights-test-fixture)
    (let ((harness-insights-narrative nil))
      (harness-ui-insights-test-open)
      (harness-usage)
      (with-current-buffer harness-ui-usage--buffer-name
        (harness-ui-usage-set-period '30d)
        (harness-test-wait (lambda () (and harness-ui-usage--data (not harness-ui-usage--loading))) 10 "usage"))
      (let ((dashboard (plist-get (buffer-local-value 'harness-ui-usage--data (get-buffer harness-ui-usage--buffer-name))
                                  :totals))
            (report (plist-get (plist-get (buffer-local-value 'harness-ui-insights--data
                                                              (get-buffer harness-ui-insights--buffer-name))
                                          :usage)
                               :totals)))
        (should (equal dashboard report))
        (should (= 1.75 (plist-get report :cost))))
      (should (string-match-p "\\$1\\.75 cost" (harness-ui-insights-test-text)))
      ;; All time includes the older row, as the dashboard's All does.
      (with-current-buffer harness-ui-insights--buffer-name
        (harness-ui-insights-cycle-period)
        (should (eq 'all harness-ui-insights--period))
        (harness-test-wait (lambda () (and harness-ui-insights--data (not harness-ui-insights--loading))) 60 "all time")
        (should (= 10.75 (plist-get (plist-get (plist-get harness-ui-insights--data :usage) :totals) :cost)))))))

(ert-deftest harness-ui-insights-summary-off ()
  "With summaries off, no model is asked and the report says so."
  (harness-ui-insights-test-with
    (harness-ui-insights-test-fixture)
    (let ((harness-insights-narrative nil)
          (asked 0))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (cl-incf asked) (funcall orig req))))
        (let ((text (harness-ui-insights-test-open)))
          (should (string-match-p "Written summaries are off" text))
          (with-current-buffer harness-ui-insights--buffer-name
            (should-error (harness-ui-insights-write) :type 'user-error))
          (should (= 0 asked)))))))

(ert-deftest harness-ui-insights-summary-offline ()
  "When the model cannot be reached the report stands, saying so."
  (harness-ui-insights-test-with
    (harness-ui-insights-test-fixture)
    (let ((harness-provider-demo-script-override '((:type done :stop-reason error :error "offline"))))
      (harness-ui-insights-test-open)
      (with-current-buffer harness-ui-insights--buffer-name
        (harness-test-wait (lambda () (and (not harness-ui-insights--writing) harness-ui-insights--narrative)) 30 "the summary")
        (let ((text (harness-ui-insights-test-text)))
          (should (string-match-p "could not be written.*offline" text))
          (should (string-match-p "\\[try again\\]" text))
          (should (string-match-p "Parser work" text)))))))

(ert-deftest harness-ui-insights-ret-opens-sessions-and-tasks ()
  "RET on a session line opens it; on a task line, its session."
  (harness-ui-insights-test-with
    (let* ((fx (harness-ui-insights-test-fixture))
           (opened nil)
           (harness-insights-narrative nil))
      (harness-ui-insights-test-open)
      (cl-letf (((symbol-function 'harness-ui-usage--open-session) (lambda (sid) (push sid opened))))
        (with-current-buffer harness-ui-insights--buffer-name
          (harness-ui-insights-test-goto "^ +Parser work ")
          (harness-ui-insights-open)
          (harness-ui-insights-test-goto "◆ Docs pass")
          (harness-ui-insights-open)
          (harness-ui-insights-test-goto "^ Tools")
          (should-error (harness-ui-insights-open) :type 'user-error)))
      (should (equal (list (plist-get fx :b) (plist-get fx :a)) opened)))))

(ert-deftest harness-ui-insights-narrows-to-a-project ()
  "p narrows the report to a project, nil to every project again."
  (harness-ui-insights-test-with
    (let* ((fx (harness-ui-insights-test-fixture))
           (harness-insights-narrative nil))
      (harness-ui-insights-test-open)
      (with-current-buffer harness-ui-insights--buffer-name
        (harness-ui-insights-set-project (harness-test-temp-dir))
        (harness-test-wait (lambda () (and harness-ui-insights--data (not harness-ui-insights--loading))) 60 "elsewhere")
        (should (= 0 (plist-get (plist-get harness-ui-insights--data :sessions) :active)))
        (should (string-match-p "No session worked in this period" (harness-ui-insights-test-text)))
        (harness-ui-insights-set-project (plist-get fx :project))
        (harness-test-wait (lambda () (and harness-ui-insights--data (not harness-ui-insights--loading))) 60 "the project")
        (should (= 2 (plist-get (plist-get harness-ui-insights--data :sessions) :active)))
        (should (equal (plist-get fx :project) (plist-get harness-ui-insights--data :project)))
        (harness-ui-insights-set-project nil)
        (harness-test-wait (lambda () (and harness-ui-insights--data (not harness-ui-insights--loading))) 60 "every project")
        (should-not (plist-get harness-ui-insights--data :project))))))

(ert-deftest harness-ui-insights-error-shows ()
  "A report that cannot be made says why."
  (harness-ui-insights-test-with
    (cl-letf (((symbol-function 'harness-method/insights/compute)
               (lambda (&rest _) (error "No transcripts here"))))
      (harness-insights)
      (with-current-buffer harness-ui-insights--buffer-name
        (harness-test-wait (lambda () harness-ui-insights--error) 10 "the error")
        (should (string-match-p "could not be made: No transcripts here" (harness-ui-insights-test-text)))))))

(ert-deftest harness-ui-insights-words ()
  "Shares, counts and tasks read as sentences."
  (harness-ui-insights-test-with
    (should (equal "–" (harness-ui-insights--percent 3 0)))
    (should (equal "0%" (harness-ui-insights--percent 0 236)))
    (should (equal "0.4%" (harness-ui-insights--percent 1 236)))
    (should (equal "97%" (harness-ui-insights--percent 36 37)))
    (should (equal "1,234,567" (harness-ui-insights--number 1234567)))
    (should (equal "1h05m" (harness-ui-insights--duration 3900)))
    (should (equal "Oct 6" (harness-ui-insights--day (format-time-string "%Y-10-06"))))
    (should (equal "sent back twice, now in review"
                   (harness-ui-insights--task-detail '(:why "sent-back" :feedback 2 :column "review"))))
    (should (equal "done just now, after being sent back once, met a merge conflict"
                   (harness-ui-insights--task-detail
                    (list :why "done" :feedback 1 :conflict t :done-at (float-time)))))
    (should (equal "stopped with an error (merge-failed)"
                   (harness-ui-insights--task-detail '(:why "failed" :outcome "merge-failed"))))
    (with-temp-buffer
      ;; Out of a window, lines are 76 columns at most.
      (harness-ui-insights--parts (list "one" nil "two" (make-string 70 ?x)) 3)
      (should (equal (format "   one · two\n   %s\n" (make-string 70 ?x)) (buffer-string))))))

(ert-deftest harness-ui-insights-keys ()
  "I opens the report from the harness keys; the report has its own."
  (harness-ui-insights-test-with
    (should (eq #'harness-insights (lookup-key harness-ui-map (kbd "I"))))
    (dolist (binding '(("g" . harness-ui-insights-refresh) ("t" . harness-ui-insights-cycle-period)
                       ("p" . harness-ui-insights-set-project) ("n" . harness-ui-insights-write)
                       ("RET" . harness-ui-insights-open) ("q" . quit-window)))
      (should (eq (cdr binding) (lookup-key harness-ui-insights-mode-map (kbd (car binding))))))))

(provide 'harness-ui-insights-test)
;;; harness-ui-insights-test.el ends here
