;;; harness-ui-usage-test.el --- Tests for the usage dashboard  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defmacro harness-ui-usage-test-with (&rest body)
  "Load the state layer, ACP, the UI foundation and the dashboard, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent usage worktree acp ui ui-usage))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-ui--sessions)
     (setq harness-usage-budgets nil)
     (let ((harness-provider-demo-delay 0.005)
           (harness-acp-token nil)
           (default-directory dir))
       (unwind-protect
           (progn ,@body)
         (when (get-buffer harness-ui-usage-buffer-name) (kill-buffer harness-ui-usage-buffer-name))
         (when (get-buffer "*harness budget plan*") (kill-buffer "*harness budget plan*"))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-ui-usage-test-request (method params)
  "Await METHOD with PARAMS over the UI connection."
  (harness-test-await (harness-ui-request method params)))

(defun harness-ui-usage-test-record (ts project model cost &optional input output)
  "Record one usage row at TS for PROJECT and MODEL costing COST."
  (harness-ui-usage-test-request
   "_harness/usage/record"
   (list :row (list :ts ts :session "s1" :project project :model model
                    :input (or input 1000) :output (or output 100) :cost cost))))

(defun harness-ui-usage-test-open ()
  "Open the dashboard and wait for its data."
  (harness-usage)
  (set-buffer harness-ui-usage-buffer-name)
  (harness-test-wait (lambda () (and harness-ui-usage--data (not harness-ui-usage--loading))) 5 "usage data")
  (buffer-substring-no-properties (point-min) (point-max)))

(defun harness-ui-usage-test-text ()
  "Return the dashboard text."
  (with-current-buffer harness-ui-usage-buffer-name
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-usage-test-has-svg-p ()
  "Non-nil when the buffer holds an SVG display property."
  (with-current-buffer harness-ui-usage-buffer-name
    (let ((pos (point-min)) (found nil))
      (while (and (not found) pos)
        (let ((d (get-text-property pos 'display)))
          (when (and (consp d) (eq (car d) 'image) (eq (plist-get (cdr d) :type) 'svg))
            (setq found t)))
        (setq pos (next-single-property-change pos 'display)))
      found)))

(ert-deftest harness-ui-usage-empty-state ()
  (harness-ui-usage-test-with
    (let ((text (harness-ui-usage-test-open)))
      (should (string-match-p "No usage recorded" text))
      (should (string-match-p "no budgets yet" text))
      (should (string-match-p "\\$0 cost" text)))))

(ert-deftest harness-ui-usage-totals-chart-table-and-budget ()
  (harness-ui-usage-test-with
    (let* ((now (float-time))
           (project (file-name-as-directory dir))
           (other "/tmp/harness-usage-other/"))
      (harness-ui-usage-test-record now project "demo:scripted" 1.5)
      (harness-ui-usage-test-record (- now 3600) project "demo:other" 0.5 200 20)
      (harness-ui-usage-test-record (- now (* 2 86400)) other "demo:scripted" 2.0)
      (harness-ui-usage-test-record (- now (* 40 86400)) other "demo:scripted" 9.0)
      (let ((text (harness-ui-usage-test-open)))
        ;; Totals for the default 7-day period exclude the 40-day-old row.
        (should (eq 'project harness-ui-usage--group))
        (should (string-match-p "\\$4\\.00 cost" text))
        (should (string-match-p "3 calls" text))
        (should (string-match-p "2\\.2k input" text))
        (should (string-match-p "Cost per day" text))
        ;; Table rows sorted by cost: the temp project ($2.00) before the other ($2.00)? Both present.
        (should (string-match-p (regexp-quote (harness-truncate-middle (abbreviate-file-name project) 40)) text))
        (should (string-match-p "harness-usage-other" text))
        (should (string-match-p "50%" text))
        ;; The chart is SVG on a graphic display, a text bar otherwise.
        (if (and (display-graphic-p) (image-type-available-p 'svg))
            (should (harness-ui-usage-test-has-svg-p))
          (should (string-match-p "[█░]" text))))
      ;; Group by model and by day.
      (harness-ui-usage-set-group 'model)
      (harness-test-wait (lambda () (not harness-ui-usage--loading)) 5)
      (let ((text (harness-ui-usage-test-text)))
        (should (string-match-p "demo · scripted" text))
        (should (string-match-p "demo · other" text)))
      (harness-ui-usage-set-group 'day)
      (harness-test-wait (lambda () (not harness-ui-usage--loading)) 5)
      (should (string-match-p (format-time-string "%b %-d, %Y") (harness-ui-usage-test-text)))
      ;; All time includes the old row; Today only the last two.
      (harness-ui-usage-set-period 'all)
      (harness-test-wait (lambda () (not harness-ui-usage--loading)) 5)
      (should (string-match-p "\\$13\\.00 cost" (harness-ui-usage-test-text)))
      (harness-ui-usage-set-period 'today)
      (harness-test-wait (lambda () (not harness-ui-usage--loading)) 5)
      (should (string-match-p "Cost per hour" (harness-ui-usage-test-text)))
      ;; A project budget shows up as a meter with its fraction.
      (harness-ui-usage-test-request "_harness/usage/set-budget"
                                     (list :budget (list :scope "project" :target project :amount 8 :hard t)))
      (harness-ui-usage-refresh)
      (harness-test-wait (lambda () (not harness-ui-usage--loading)) 5)
      (let ((text (harness-ui-usage-test-text)))
        (should (string-match-p "25%" text))
        (should (string-match-p "\\$2\\.00 / \\$8\\.00" text))
        (should (string-match-p "hard" text))
        (if (and (display-graphic-p) (image-type-available-p 'svg))
            (should (harness-ui-usage-test-has-svg-p))
          (should (string-match-p "███░" text))))
      (with-current-buffer harness-ui-usage-buffer-name
        (goto-char (point-min))
        (should (search-forward "[remove]" nil t))
        (let ((status (harness-ui-usage--budget-at-point)))
          (should status)
          (should (= 8.0 (plist-get status :amount)))
          (should (< (abs (- 0.25 (plist-get status :fraction))) 1e-6)))
        ;; Removing through the command asks, then calls the method.
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (harness-ui-usage-remove-budget))
        (harness-test-wait (lambda () (null (harness-call 'usage/budgets))) 5 "budget removed")))))

(ert-deftest harness-ui-usage-add-budget-wizard-and-plan ()
  (harness-ui-usage-test-with
    (harness-ui-usage-test-open)
    (cl-letf (((symbol-function 'read-multiple-choice)
               (lambda (prompt choices &rest _)
                 (cond ((string-match-p "scope" prompt) (assq ?t choices))
                       ((string-match-p "Period" prompt) (assq ?w choices))
                       (t (car choices)))))
              ((symbol-function 'read-number) (lambda (&rest _) 42))
              ((symbol-function 'y-or-n-p) (lambda (prompt) (string-match-p "business" prompt)))
              ((symbol-function 'read-string) (lambda (&rest _) "weekly cap")))
      (harness-ui-usage-add-budget))
    (harness-test-wait (lambda () (harness-call 'usage/budgets)) 5 "budget created")
    (let ((b (car (harness-call 'usage/budgets))))
      (should (eq 'period (plist-get b :scope)))
      (should (eq 'week (plist-get b :period)))
      (should (eq 'business (plist-get b :days)))
      (should (= 42.0 (plist-get b :amount)))
      (should-not (plist-get b :hard))
      (should (equal "weekly cap" (plist-get b :label))))
    (with-current-buffer harness-ui-usage-buffer-name
      (harness-test-wait (lambda () (string-match-p "weekly cap" (harness-ui-usage-test-text))) 5 "budget shown")
      (should (string-match-p "/day" (harness-ui-usage-test-text)))
      (goto-char (point-min))
      (search-forward "weekly cap")
      ;; The plan uses the budget at point for its defaults.
      (cl-letf (((symbol-function 'read-number) (lambda (_p default) default))
                ((symbol-function 'completing-read) (lambda (_p _c &rest args) (car (last args))))
                ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (harness-ui-usage-plan)))
    (harness-test-wait (lambda () (get-buffer "*harness budget plan*")) 5 "plan buffer")
    (with-current-buffer "*harness budget plan*"
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (should (string-match-p "\\$42\\.00 over this week" text))
        (should (string-match-p "Allowance" text))
        (should (string-match-p (format-time-string "%Y-%m-%d") text))
        (should (= 7 (cl-count-if (lambda (l) (string-match-p "\\` [0-9]\\{4\\}-" l)) (split-string text "\n"))))))))

(provide 'harness-ui-usage-test)
;;; harness-ui-usage-test.el ends here
