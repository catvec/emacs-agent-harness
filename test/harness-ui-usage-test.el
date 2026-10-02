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

(defun harness-ui-usage-test-line-help (regexp)
  "Non-nil when a tooltip on the current line matches REGEXP."
  (let ((pos (line-beginning-position)) (end (line-end-position)) found)
    (while (and (not found) (< pos end))
      (let ((help (get-text-property pos 'help-echo)))
        (when (and (stringp help) (string-match-p regexp help)) (setq found t)))
      (setq pos (1+ pos)))
    found))

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
        (should (string-match-p "scripted (Demo)" text))
        (should (string-match-p "other (Demo)" text)))
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
              ((symbol-function 'read-number)
               (lambda (prompt &rest _) (if (string-match-p "Already spent this week" prompt) 12 42)))
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
      (should (equal "weekly cap" (plist-get b :label)))
      ;; What was already spent this week counts from now on, this week only.
      (should (= 12.0 (plist-get b :baseline)))
      (should (equal (harness-usage--date-key (car (harness-usage-period-bounds 'week)))
                     (plist-get b :baseline-period-start))))
    (with-current-buffer harness-ui-usage-buffer-name
      (harness-test-wait (lambda () (string-match-p "weekly cap" (harness-ui-usage-test-text))) 5 "budget shown")
      (should (string-match-p "/day" (harness-ui-usage-test-text)))
      (should (string-match-p "\\$12\\.00 / \\$42\\.00  incl\\. \\$12\\.00 baseline" (harness-ui-usage-test-text)))
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

(ert-deftest harness-ui-usage-baseline-shows-in-the-meter ()
  "What was spent outside the harness is set on a budget's line and counted in its meter."
  (harness-ui-usage-test-with
    (let ((asked nil))
      (harness-ui-usage-test-record (float-time) (file-name-as-directory dir) "demo:scripted" 5.0)
      (harness-ui-usage-test-request "_harness/usage/set-budget"
                                     (list :budget (list :scope "period" :period "month" :amount 100 :label "monthly cap")))
      (harness-ui-usage-test-open)
      (with-current-buffer harness-ui-usage-buffer-name
        (should (string-match-p "\\$5\\.00 / \\$100\\.00" (harness-ui-usage-test-text)))
        (should-not (string-match-p "incl\\." (harness-ui-usage-test-text)))
        (goto-char (point-min))
        (search-forward "monthly cap")
        (cl-letf (((symbol-function 'read-number)
                   (lambda (prompt &optional default) (setq asked (list prompt default)) 20)))
          (harness-ui-usage-set-baseline))
        (should (string-match-p "Already spent this month outside the harness" (car asked)))
        (should (= 0 (cadr asked)))
        (harness-test-wait (lambda () (string-match-p "incl\\. \\$20\\.00 baseline" (harness-ui-usage-test-text)))
                           5 "baseline in the meter")
        (let ((text (harness-ui-usage-test-text)))
          (should (string-match-p "monthly cap .* 25%  \\$25\\.00 / \\$100\\.00  incl\\. \\$20\\.00 baseline  \\$75\\.00 left" text)))
        ;; Set through usage/set-budget, for this month.
        (let ((b (car (harness-call 'usage/budgets))))
          (should (= 20.0 (plist-get b :baseline)))
          (should (equal (harness-usage--date-key (car (harness-usage-period-bounds 'month)))
                         (plist-get b :baseline-period-start)))
          (should (equal "monthly cap" (plist-get b :label))))
        (goto-char (point-min))
        (search-forward "monthly cap")
        (should (= 20.0 (plist-get (harness-ui-usage--budget-at-point) :baseline)))
        (should (harness-ui-usage-test-line-help "\\$25\\.00 of \\$100\\.00 spent, incl\\. \\$20\\.00 baseline"))
        ;; The current baseline is the default; 0 clears it.
        (cl-letf (((symbol-function 'read-number)
                   (lambda (prompt &optional default) (setq asked (list prompt default)) 0)))
          (harness-ui-usage-set-baseline))
        (should (= 20.0 (cadr asked)))
        (harness-test-wait (lambda () (not (string-match-p "incl\\." (harness-ui-usage-test-text)))) 5 "baseline cleared")
        (should (string-match-p "\\$5\\.00 / \\$100\\.00" (harness-ui-usage-test-text)))
        (should-not (plist-member (car (harness-call 'usage/budgets)) :baseline))
        ;; Negative amounts are refused before anything is sent.
        (goto-char (point-min))
        (search-forward "monthly cap")
        (cl-letf (((symbol-function 'read-number) (lambda (&rest _) -3)))
          (should-error (harness-ui-usage-set-baseline) :type 'user-error))))))

(defun harness-ui-usage-test-max-quota (now)
  "Return a Claude Max quota plist as the provider reports it at NOW."
  (list :billing "subscription" :plan "max" :plan-label "Claude Max"
        :account '(:email "user@example.com") :auth "claude.ai"
        :windows (list (list :name "5h" :label "Current session (5 hours)" :used 0.09 :resets (+ now 3600))
                       (list :name "7d" :label "This week, all models" :used 0.57 :resets (+ now 200000))
                       (list :name "7d Fable" :label "This week, Fable" :used 0.5 :resets (+ now 200000)))
        :extra '(:enabled :false :used 0.0 :limit 50.0 :disabled-reason "out_of_credits")
        :updated now))

(ert-deftest harness-ui-usage-plan-section-and-covered-cost ()
  "A subscription's usage shows as covered by the plan, beside its quota."
  (harness-ui-usage-test-with
    (clrhash harness-ui--quotas)
    (let* ((now (float-time))
           (project (file-name-as-directory dir)))
      (harness-ui-usage-test-request
       "_harness/usage/record"
       (list :row (list :ts now :session "s1" :project project :model "claude:claude-fable-5-1"
                        :input 1000 :output 100 :cost 0 :list-cost 3.25 :billing "subscription")))
      (harness-ui-usage-test-record now project "demo:scripted" 1.0)
      (harness-ui--store-quota "claude" (harness-ui-usage-test-max-quota now))
      (let ((text (harness-ui-usage-test-open)))
        (should (string-match-p "\\$1\\.00 cost" text))
        (should (string-match-p "\\$3\\.25 covered by plan" text))
        (should (string-match-p "covered by plan, at API prices" text))
        (should (string-match-p "Plan +\\[refresh\\]" text))
        (should (string-match-p "Claude Max" text))
        (should (string-match-p "user@example\\.com" text))
        (should (string-match-p "Current session (5 hours)" text))
        (should (string-match-p " 9%  resets in " text))
        (should (string-match-p "57%" text))
        (should (string-match-p "This week, Fable" text))
        (should (string-match-p "Extra usage: off (out of credits), \\$0 used of \\$50\\.00" text))
        (should (string-match-p "budgets count billed cost" text))
        ;; The table: the plan's row first, by its value at API prices.
        (should (string-match-p "Cost +Plan +Share" text))
        (should (< (string-match "harness-tmp\\|harness-test" text) (length text))))
      ;; Grouped by billing.
      (harness-ui-usage-set-group 'billing)
      (harness-test-wait (lambda () (not harness-ui-usage--loading)) 5)
      (let ((text (harness-ui-usage-test-text)))
        (should (string-match-p "Subscription, covered by the plan" text))
        (should (string-match-p "Not recorded" text))
        (should (< (string-match "Subscription, covered" text) (string-match "Not recorded" text))))
      ;; An API account says it bills per token.
      (harness-ui--store-quota "claude" '(:billing "api" :auth "ANTHROPIC_API_KEY"))
      (with-current-buffer harness-ui-usage-buffer-name
        (let ((text (harness-ui-usage-test-text)))
          (should (string-match-p "bills per token (ANTHROPIC_API_KEY)" text))
          (should-not (string-match-p "budgets count billed cost" text)))))))

(ert-deftest harness-ui-spend-says-who-pays ()
  "Session costs read as prices when billed per token and as the plan otherwise."
  (harness-ui-usage-test-with
    (clrhash harness-ui--quotas)
    (let* ((now (float-time))
           (api (list :model "demo:scripted" :usage '(:cost 1.2 :list-cost 1.2 :billing "api")))
           (plan (list :model "claude:claude-opus-5-5"
                       :usage '(:cost 0.0 :list-cost 3.4 :billing "subscription" :plan "max")))
           (mixed (list :model "claude:claude-opus-5-5"
                        :usage '(:cost 0.4 :list-cost 3.8 :billing "extra-usage" :plan "max")))
           (fresh (list :model "claude:claude-opus-5-5" :usage '(:cost 0.0)))
           (old (list :model "claude:claude-opus-5-5" :usage '(:cost 2.0)))
           (text (lambda (s &optional quota) (substring-no-properties (harness-ui-format-spend s quota)))))
      (should (equal "$1.20" (funcall text api)))
      (should (equal "Max" (funcall text plan)))
      (should (equal "$0.400+Max" (funcall text mixed)))
      (should (equal "$0" (funcall text fresh)))
      (should (equal "$2.00" (funcall text old)))
      (should (string-match-p "billed per token" (get-text-property 0 'help-echo (harness-ui-format-spend api))))
      ;; Before its first call a session goes by its provider's account.
      (harness-ui--store-quota "claude" (harness-ui-usage-test-max-quota now))
      (should (equal "Max" (funcall text fresh)))
      (should (equal "$2.00" (funcall text old)))
      ;; The header form adds the session and weekly windows, not the quiet Fable one.
      (should (equal "Max · 5h 9% · 7d 57%" (funcall text plan t)))
      (let ((help (get-text-property 0 'help-echo (harness-ui-format-spend plan t))))
        (should (string-match-p "Covered by Claude Max, not billed per token" help))
        (should (string-match-p "at API prices: \\$3\\.40" help))
        (should (string-match-p "Current session (5 hours): 9% used, resets in " help))
        (should (string-match-p "Extra usage: off" help)))
      (let ((help (get-text-property 0 'help-echo (harness-ui-format-spend mixed))))
        (should (string-match-p "\\$0\\.400 billed as extra usage" help))
        (should (string-match-p "\\$3\\.40 more at API prices covered by Claude Max" help)))
      ;; A window close to its limit joins the header.
      (harness-ui--store-quota "claude" (plist-put (harness-ui-usage-test-max-quota now) :windows
                                                   '((:name "5h" :used 0.2) (:name "7d Fable" :used 0.96))))
      (should (equal "Max · 5h 20% · 7d Fable 96%" (funcall text plan t)))
      (should (eq 'harness-context-critical-face
                  (get-text-property (1- (length (harness-ui-format-spend plan t))) 'face
                                     (harness-ui-format-spend plan t)))))))

(ert-deftest harness-ui-model-label-is-readable ()
  "Labels read \"model (provider)\", from the catalogue when it knows the model."
  (harness-ui-usage-test-with
    (clrhash harness-ui--models)
    (should (equal "Opus 5.5 (Claude)" (harness-ui-model-label "claude:claude-opus-5-5")))
    (should (equal "Haiku 4.5 (Claude)" (harness-ui-model-label "claude:claude-haiku-4-5-20251001")))
    (should (equal "Sonnet 5 (Claude)" (harness-ui-model-label "claude:claude-sonnet-5")))
    (should (equal "scripted (Demo)" (harness-ui-model-label "demo:scripted")))
    (should (equal "?" (harness-ui-model-label nil)))
    (puthash "openai:gpt-x" (list :id "openai:gpt-x" :label "GPT X" :provider-label "OpenAI") harness-ui--models)
    (should (equal "GPT X (OpenAI)" (harness-ui-model-label "openai:gpt-x")))
    (puthash "claude:claude-opus-5-5" (list :label "Claude Opus 5.5" :provider-label "Claude Code") harness-ui--models)
    (should (equal "Opus 5.5 (Claude)" (harness-ui-model-label "claude:claude-opus-5-5")))))

(provide 'harness-ui-usage-test)
;;; harness-ui-usage-test.el ends here
