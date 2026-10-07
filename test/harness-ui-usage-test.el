;;; harness-ui-usage-test.el --- Tests for the usage dashboard  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defmacro harness-ui-usage-test-with (&rest body)
  "Load the state layer, ACP, the UI foundation and the dashboard, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent usage fallback worktree acp ui ui-usage))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-ui--sessions)
     (setq harness-usage-budgets nil)
     ;; The fallback list is a global option; a test that edits it must not
     ;; change what the next one renders.
     (setq harness-fallback-models nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-acp-token nil)
           (default-directory dir))
       (unwind-protect
           (progn ,@body)
         (when (get-buffer harness-ui-usage--buffer-name) (kill-buffer harness-ui-usage--buffer-name))
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
  (set-buffer harness-ui-usage--buffer-name)
  (harness-test-wait (lambda () (and harness-ui-usage--data (not harness-ui-usage--loading))) 5 "usage data")
  (buffer-substring-no-properties (point-min) (point-max)))

(defun harness-ui-usage-test-text ()
  "Return the dashboard text."
  (with-current-buffer harness-ui-usage--buffer-name
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-usage-test-has-svg-p ()
  "Non-nil when the buffer holds an SVG display property."
  (with-current-buffer harness-ui-usage--buffer-name
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

(defun harness-ui-usage-test--git (dir &rest args)
  "Run git ARGS in DIR; signal on failure."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string))))))

(defun harness-ui-usage-test--repo (base)
  "Make BASE/acme a git repository with one commit; return its root."
  (let ((root (file-name-as-directory (expand-file-name "acme" base))))
    (make-directory root t)
    (harness-ui-usage-test--git root "init" "-q" "-b" "main")
    (harness-ui-usage-test--git root "-c" "user.name=t" "-c" "user.email=t@example.invalid" "-c" "commit.gpgsign=false"
                                "commit" "-q" "--allow-empty" "-m" "initial")
    root))

(defun harness-ui-usage-test-lines ()
  "Return the lines of the dashboard's table, from its header to its end."
  (let ((text (harness-ui-usage-test-text)))
    (string-match "^ Project .*\n\\(\\(?:.+\n\\)*\\)" text)
    (split-string (match-string 1 text) "\n" t)))

(defun harness-ui-usage-test-goto (regexp)
  "Move to the start of the first dashboard line matching REGEXP."
  (goto-char (point-min))
  (re-search-forward regexp)
  (goto-char (line-beginning-position)))

(defun harness-ui-usage-test-cost-end (line)
  "Return the column where the Cost cell of table LINE ends."
  (and (string-match "\\$[0-9.]+ " line) (match-end 0)))

(ert-deftest harness-ui-usage-worktrees-fold-under-their-project ()
  "By project, a project's worktrees, its tasks', fold into one line with
their sum; TAB, RET, w and the heading's button show and hide them."
  (harness-ui-usage-test-with
    (let* ((base (file-name-as-directory (file-truename (harness-test-temp-dir))))
           (root (harness-ui-usage-test--repo base))
           (fast (file-name-as-directory (expand-file-name ".worktrees/task-fast" root)))
           (slow (file-name-as-directory (expand-file-name ".worktrees/task-slow" root)))
           (gone (file-name-as-directory (expand-file-name ".worktrees/task-archived" root)))
           (other (file-name-as-directory (expand-file-name "other" base)))
           (label (harness-truncate-middle (abbreviate-file-name root) 40))
           (now (float-time)))
      (make-directory other)
      (harness-ui-usage-test--git root "worktree" "add" "-q" "-b" "task/fast" fast)
      (harness-ui-usage-test--git root "worktree" "add" "-q" "-b" "task/slow" slow)
      (harness-ui-usage-test-record now root "demo:scripted" 1.0)
      (harness-ui-usage-test-record now fast "demo:scripted" 0.5)
      (harness-ui-usage-test-record now slow "demo:scripted" 2.25)
      ;; An archived task's worktree is gone from disk; its usage stays.
      (harness-ui-usage-test-record now gone "demo:scripted" 0.25)
      (harness-ui-usage-test-record now other "demo:scripted" 3.0)
      (harness-ui-usage-test-open)
      (with-current-buffer harness-ui-usage--buffer-name
        ;; Folded: the project's line has the sum and how many worktrees.
        (let ((lines (harness-ui-usage-test-lines)))
          (should (= 2 (length lines)))
          (should (string-match-p (concat "\\` . " (regexp-quote label) "  3 worktrees +\\$4\\.00 .* 4\\'")
                                  (car lines)))
          (should (string-match-p (concat "\\`   " (regexp-quote (harness-truncate-middle (abbreviate-file-name other) 40))
                                          " +\\$3\\.00 ")
                                  (cadr lines)))
          ;; The fold icon's gutter ends at one column for every line.
          (should (= (harness-ui-usage-test-cost-end (car lines)) (harness-ui-usage-test-cost-end (cadr lines)))))
        (should (string-match-p "By project  \\[show worktrees\\]" (harness-ui-usage-test-text)))
        (should-not (string-match-p "main checkout\\|task-" (harness-ui-usage-test-text)))
        (harness-ui-usage-test-goto (regexp-quote label))
        (should (equal '(space :align-to 3) (get-text-property (+ (point) 2) 'display)))
        (should (harness-ui-usage-test-line-help "show its 3 worktrees"))
        ;; TAB unfolds it: its main checkout first, then its worktrees by cost.
        (forward-char 10)
        (harness-ui-usage-tab)
        (let ((lines (harness-ui-usage-test-lines)))
          (should (equal '("main checkout" "task-slow" "task-fast" "task-archived")
                         (mapcar (lambda (l) (and (string-match "\\`     \\([^ ]+\\(?: [^ $]+\\)*\\) " l)
                                                  (match-string 1 l)))
                                 (seq-subseq lines 1 5))))
          (should (string-match-p "\\$1\\.00 " (nth 1 lines)))
          (should (string-match-p "\\$2\\.25 " (nth 2 lines)))
          (should (= 6 (length lines)))
          (should (cl-every (lambda (l) (= (harness-ui-usage-test-cost-end (car lines)) (harness-ui-usage-test-cost-end l)))
                            lines)))
        (should (string-match-p "\\[hide worktrees\\]" (harness-ui-usage-test-text)))
        (should (equal root (get-text-property (point) 'harness-ui-usage-fold)))
        (harness-ui-usage-test-goto "task-slow")
        (should (harness-ui-usage-test-line-help (regexp-quote (abbreviate-file-name slow))))
        ;; A refresh keeps it unfolded.
        (harness-ui-usage-refresh)
        (harness-test-wait (lambda () (not harness-ui-usage--loading)) 5)
        (should (string-match-p "main checkout" (harness-ui-usage-test-text)))
        ;; TAB on one of its worktrees folds it, and goes to its line.
        (harness-ui-usage-test-goto "task-fast")
        (harness-ui-usage-tab)
        (should-not (string-match-p "main checkout" (harness-ui-usage-test-text)))
        (should (equal root (get-text-property (point) 'harness-ui-usage-fold)))
        ;; RET on its line unfolds it, and again folds it.
        (harness-ui-usage-open)
        (should (string-match-p "main checkout" (harness-ui-usage-test-text)))
        (harness-ui-usage-open)
        (should-not (string-match-p "main checkout" (harness-ui-usage-test-text)))
        ;; w, or the heading's button, shows every project's; again hides them.
        (harness-ui-usage-toggle-worktrees)
        (should (string-match-p "main checkout" (harness-ui-usage-test-text)))
        (harness-ui-usage-test-goto "\\[hide worktrees\\]")
        (search-forward "[hide")
        (push-button)
        (should-not (string-match-p "main checkout" (harness-ui-usage-test-text)))
        ;; Elsewhere TAB moves to the next button.
        (goto-char (point-min))
        (harness-ui-usage-tab)
        (should (button-at (point)))
        ;; Other groupings have no worktrees to fold.
        (harness-ui-usage-set-group 'model)
        (harness-test-wait (lambda () (not harness-ui-usage--loading)) 5)
        (should-not (string-match-p "worktrees" (harness-ui-usage-test-text)))
        (should-error (harness-ui-usage-toggle-worktrees) :type 'user-error)))))

(ert-deftest harness-ui-usage-redraw-keeps-the-view ()
  "A redraw, from a refresh or a fold, scrolls no window showing the dashboard."
  (harness-ui-usage-test-with
    (let ((now (float-time)))
      (dotimes (i 12)
        (harness-ui-usage-test-record now (format "/tmp/harness-usage-p%d/" i) "demo:scripted" (+ 1.0 i)))
      (harness-ui-usage-test-open)
      (let ((window (get-buffer-window harness-ui-usage--buffer-name t)))
        (should window)
        (with-current-buffer harness-ui-usage--buffer-name
          (set-window-start window (harness-ui-usage--line-start 6))
          (set-window-point window (harness-ui-usage--line-start 9))
          (harness-ui-usage--render)
          (should (= 6 (line-number-at-pos (window-start window))))
          (should (= 9 (line-number-at-pos (window-point window)))))))))

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
      (with-current-buffer harness-ui-usage--buffer-name
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

(defvar harness-budget)

(ert-deftest harness-ui-usage-budget-setting-is-one-line ()
  "The Budget setting shows as one budget for all sessions, however many
there are, and d on it says where to change it."
  (harness-ui-usage-test-with
    (let ((harness-budget '(:amount 10 :hard t)))
      (dotimes (_ 3)
        (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"))
      (harness-test-wait (let (done) (harness-ui-refresh-sessions (lambda (_) (setq done t))) (lambda () done))
                         5 "sessions cached")
      (should (= 3 (length (harness-ui-sessions))))
      (harness-ui-usage-test-record (float-time) (file-name-as-directory dir) "demo:scripted" 2.5)
      (harness-ui-usage-test-open)
      (with-current-buffer harness-ui-usage--buffer-name
        (let ((lines (split-string (harness-ui-usage-test-text) "\n")))
          (should (= 1 (cl-count-if (lambda (l) (string-match-p "all sessions (setting)" l)) lines)))
          (should (cl-some (lambda (l) (string-match-p "all sessions (setting) .* 25%  \\$2\\.50 / \\$10\\.00" l))
                           lines))
          (should-not (cl-some (lambda (l) (string-match-p "\\`  session " l)) lines)))
        (harness-ui-usage-test-goto "all sessions (setting)")
        (should (string-match-p "M-x harness-settings"
                                (cadr (should-error (harness-ui-usage-remove-budget) :type 'user-error))))))
    ;; Unset, it is gone.
    (with-current-buffer harness-ui-usage--buffer-name
      (harness-ui-usage-refresh)
      (harness-test-wait (lambda () (not harness-ui-usage--loading)) 5)
      (should-not (string-match-p "all sessions" (harness-ui-usage-test-text))))))

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
    (with-current-buffer harness-ui-usage--buffer-name
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
      (with-current-buffer harness-ui-usage--buffer-name
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

(ert-deftest harness-ui-usage-import-api-cost-offers-a-baseline ()
  "With an Admin API key, the month's Anthropic cost is offered as a month budget's baseline."
  (harness-ui-usage-test-with
    (let ((harness-anthropic-admin-api-key nil)
          (process-environment (cons "ANTHROPIC_ADMIN_KEY" process-environment))
          (messages nil)
          (requests 0))
      (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) nil))
                ((symbol-function 'harness-http-request-json)
                 (lambda (&rest _)
                   (cl-incf requests)
                   (harness-resolved '(:data ((:results ((:amount "1234" :currency "USD")))) :has_more :false))))
                ((symbol-function 'message)
                 (lambda (format &rest args) (when format (push (apply #'format-message format args) messages)))))
        (harness-ui-usage-test-request "_harness/usage/set-budget"
                                       (list :budget (list :scope "period" :period "month" :amount 100 :label "monthly cap")))
        (harness-ui-usage-test-request "_harness/usage/set-budget"
                                       (list :budget (list :scope "period" :period "week" :amount 30 :label "weekly cap")))
        (harness-ui-usage-test-open)
        (with-current-buffer harness-ui-usage--buffer-name
          ;; Only a month budget can take a month's cost.
          (goto-char (point-min))
          (search-forward "weekly cap")
          (should-error (harness-ui-usage-import-api-cost) :type 'user-error)
          ;; Without a key the step is skipped and says why.
          (goto-char (point-min))
          (search-forward "monthly cap")
          (harness-ui-usage-import-api-cost)
          (harness-test-wait (lambda () (cl-some (lambda (m) (string-match-p "No Anthropic Admin API key" m)) messages))
                             5 "no key")
          (should (= 0 requests))
          (should-not harness-ui-usage--api-cost)
          ;; With one, the cost shows under the budget with a button.
          (setq harness-anthropic-admin-api-key "sk-ant-admin01-test")
          (goto-char (point-min))
          (search-forward "monthly cap")
          (harness-ui-usage-import-api-cost)
          (harness-test-wait (lambda () (string-match-p "Anthropic billed \\$12\\.34 this month" (harness-ui-usage-test-text)))
                             5 "offer shown")
          (should (= 1 requests))
          (should (string-match-p "monthly cap.*\n +Anthropic billed \\$12\\.34 this month  \\[use \\$12\\.34 as baseline\\] \\[dismiss\\]"
                                  (harness-ui-usage-test-text)))
          (goto-char (point-min))
          (search-forward "[use $12.34")
          (push-button)
          (harness-test-wait (lambda () (string-match-p "incl\\. \\$12\\.34 baseline" (harness-ui-usage-test-text)))
                             5 "baseline from the API cost")
          (should-not (string-match-p "Anthropic billed" (harness-ui-usage-test-text)))
          (let ((b (cl-find "monthly cap" (harness-call 'usage/budgets) :key (lambda (b) (plist-get b :label)) :test #'equal)))
            (should (< (abs (- 12.34 (or (plist-get b :baseline) 0))) 1e-9))
            (should (equal (harness-usage--date-key (car (harness-usage-period-bounds 'month)))
                           (plist-get b :baseline-period-start))))
          ;; An offer can be dismissed.
          (goto-char (point-min))
          (search-forward "monthly cap")
          (harness-ui-usage-import-api-cost)
          (harness-test-wait (lambda () (string-match-p "\\[dismiss\\]" (harness-ui-usage-test-text))) 5 "offer again")
          (harness-ui-usage-dismiss-api-cost)
          (should-not (string-match-p "Anthropic billed" (harness-ui-usage-test-text))))))))

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
      (with-current-buffer harness-ui-usage--buffer-name
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
      (should-not (string-match-p "\n" (get-text-property 0 'help-echo (harness-ui-format-spend api))))
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
        (should (string-match-p "Extra usage: off" help))
        ;; One line, or showing it in the echo area moves the button.
        (should-not (string-match-p "\n" help)))
      (let ((help (get-text-property 0 'help-echo (harness-ui-format-spend mixed))))
        (should (string-match-p "\\$0\\.400 billed as extra usage" help))
        (should (string-match-p "\\$3\\.40 more at API prices covered by Claude Max" help))
        (should-not (string-match-p "\n" help)))
      ;; A window close to its limit joins the header.
      (harness-ui--store-quota "claude" (plist-put (harness-ui-usage-test-max-quota now) :windows
                                                   '((:name "5h" :used 0.2) (:name "7d Fable" :used 0.96))))
      (should (equal "Max · 5h 20% · 7d Fable 96%" (funcall text plan t)))
      (should (eq 'harness-context-critical-face
                  (get-text-property (1- (length (harness-ui-format-spend plan t))) 'face
                                     (harness-ui-format-spend plan t)))))))

(ert-deftest harness-ui-sessions-total-reads-as-one-session ()
  "Several sessions together cost what they add up to, paid as the latest says.
Their usage sums; its billing and plan are those of the one updated
last that recorded a billing; MODEL, else the first one's, names the
provider whose account and quota stand for them all."
  (harness-ui-usage-test-with
    (clrhash harness-ui--quotas)
    (let* ((dot (string #xb7))
           (api (list :model "demo:scripted" :updated 1 :usage '(:input 10 :cost 1.2 :list-cost 1.2 :billing "api")))
           (old (list :model "demo:scripted" :updated 3 :usage '(:input 5 :cost 0.3)))
           (plan (list :model "claude:claude-opus-5-5" :updated 2
                       :usage '(:input 20 :cost 0.0 :list-cost 3.4 :billing "subscription" :plan "max")))
           (text (lambda (s &optional quota) (substring-no-properties (harness-ui-format-spend s quota "These tasks")))))
      (let ((total (harness-ui-sessions-total (list api old))))
        (should (equal "demo:scripted" (plist-get total :model)))
        (should (= 15 (plist-get (plist-get total :usage) :input)))
        (should (equal "$1.50" (funcall text total)))
        (should (string-match-p "\\`These tasks cost \\$1\\.50, billed per token\\."
                                (get-text-property 0 'help-echo (harness-ui-format-spend total nil "These tasks")))))
      (harness-ui--store-quota "claude" (harness-ui-usage-test-max-quota (float-time)))
      (let ((total (harness-ui-sessions-total (list api plan old) "claude:claude-opus-5-5")))
        (should (equal "subscription" (plist-get (plist-get total :usage) :billing)))
        (should (< (abs (- 4.9 (harness-usage-list-cost (plist-get total :usage)))) 1e-9))
        (should (equal (format "$1.50+Max %s 5h 9%% %s 7d 57%%" dot dot) (funcall text total t)))
        ;; Billed per token and covered by the plan, not extra usage.
        (should (string-match-p "\\`\\$1\\.50 billed; \\$3\\.40 more at API prices covered by Claude Max\\."
                                (get-text-property 0 'help-echo (harness-ui-format-spend total t "These tasks")))))
      ;; Before any call the provider's account says who will pay.
      (should (equal "Max" (funcall text (harness-ui-sessions-total nil "claude:claude-opus-5-5")))))))

(ert-deftest harness-ui-format-budgets-shows-the-fullest ()
  "Budgets read \"budget N%\" for the fullest one; the tooltip describes each.
The tooltip is one line, a sentence per budget, as hover help must be."
  (harness-ui-usage-test-with
    (let* ((dot (string #xb7))
           (month (list :budget '(:id "m" :scope period :period month :label "monthly cap")
                        :spent 25.0 :amount 100.0 :remaining 75.0 :fraction 0.25
                        :per-day 3.75 :days-left 20 :baseline 20.0))
           (week (list :budget '(:id "w" :scope project :target "/src/acme-api/" :period week)
                       :spent 45.0 :amount 50.0 :remaining 5.0 :fraction 0.9 :hard t
                       :per-day 5.0 :days-left 1 :baseline 0.0))
           (text (harness-ui-format-budgets (list month week))))
      (should-not (harness-ui-format-budgets nil))
      (should (equal "budget 90%" (substring-no-properties text)))
      (should (eq 'harness-context-urgent-face (get-text-property 0 'face text)))
      (should (equal (concat "weekly acme-api: $45.00 of $50.00 spent; $5.00 left, $5.00/day " dot " 1 day left (hard). "
                             "monthly cap: $25.00 of $100.00 spent, incl. $20.00 baseline; $75.00 left, $3.75/day "
                             dot " 20 days left. "
                             "mouse-1: usage and budgets")
                     (get-text-property 0 'help-echo text))))))

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

(ert-deftest harness-ui-usage-chart-tooltip-is-one-line ()
  "A chart column's tooltip stays on one line.
Two lines would grow the echo area and move the chart under the mouse."
  (harness-ui-usage-test-with
    (dolist (bucket '(hour day))
      (let* ((key (if (eq bucket 'hour) "2026-10-03 14:00" "2026-10-03"))
             (help (harness-ui-usage--bar-help
                    (list :key key :cost 1.5 :list-cost 2.0 :calls 3
                          :input 1200 :output 345)
                    bucket)))
        (should (string-match-p (if (eq bucket 'hour) "14:00" "Oct 3, 2026") help))
        (should (string-match-p "3 calls" help))
        (should (string-match-p "1\\.2k in / 345 out" help))
        (should-not (string-match-p "\n" help))))))

(ert-deftest harness-ui-usage-dashboard-tooltips-are-one-line ()
  "Every tooltip of the rendered dashboard fits one echo-area line."
  (harness-ui-usage-test-with
    (let* ((now (float-time))
           (project (file-name-as-directory dir)))
      (harness-ui-usage-test-record now project "demo:scripted" 1.5)
      (harness-ui-usage-test-request "_harness/usage/set-budget"
                                     (list :budget (list :scope "project" :target project :amount 8 :hard t)))
      (harness-ui-usage-test-open)
      (with-current-buffer harness-ui-usage--buffer-name
        (let ((pos (point-min)) (found nil) (offenders nil))
          (while (< pos (point-max))
            (when-let* ((help (get-text-property pos 'help-echo)))
              (setq found t)
              (when (and (stringp help) (string-match-p "\n" help))
                (push help offenders)))
            (setq pos (1+ pos)))
          (should found)
          (should-not offenders))))))

(ert-deftest harness-ui-usage-fallback-section-shows-and-clears-marks ()
  "The fallback section lists the entries and says what ran out."
  (harness-ui-usage-test-with
    (setq harness-fallback-models '("demo"))
    (let ((text (harness-ui-usage-test-open)))
      (should (string-match-p "Fallback" text))
      (should (string-match-p "1\\. Demo" text))
      (should (string-match-p "available" text))
      (should-not (string-match-p "out of quota" text)))
    ;; A mark shows what ran out, and [try now] clears it.
    (harness-call 'fallback/mark "demo" :kind 'quota :reason "hit the limit")
    (harness-ui-usage-refresh)
    (harness-test-wait (lambda () (not harness-ui-usage--loading)) 5 "reloaded")
    (let ((text (harness-ui-usage-test-text)))
      (should (string-match-p "out of quota" text))
      (should (string-match-p "\\[try now\\]" text)))
    (with-current-buffer harness-ui-usage--buffer-name
      (goto-char (point-min))
      (search-forward "Demo")
      (harness-ui-usage-fallback-try))
    (harness-test-wait (lambda () (null (plist-get (harness-call 'fallback/status) :marks))) 5 "mark cleared")
    (harness-ui-usage-refresh)
    (harness-test-wait (lambda () (not harness-ui-usage--loading)) 5 "reloaded")
    (let ((text (harness-ui-usage-test-text)))
      (should (string-match-p "available" text))
      (should-not (string-match-p "out of quota" text)))))

(ert-deftest harness-ui-usage-fallback-add-move-and-remove ()
  "Adding, moving and removing entries saves the option through config/set."
  (harness-ui-usage-test-with
    (setq harness-fallback-models '("demo:scripted"))
    (harness-ui-usage-test-open)
    ;; Add a provider through the prompt: it lands at the end.
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "demo")))
      (harness-ui-usage-add-fallback))
    (harness-test-wait (lambda () (equal '("demo:scripted" "demo") harness-fallback-models)) 5 "added")
    (harness-test-wait (lambda () (string-match-p "2\\. Demo  " (harness-ui-usage-test-text))) 5 "shown last")
    ;; Move it to the front with M-<up> (the command behind the key).
    (with-current-buffer harness-ui-usage--buffer-name
      (goto-char (point-min))
      (search-forward "2. Demo")
      (harness-ui-usage-fallback-up))
    (harness-test-wait (lambda () (equal '("demo" "demo:scripted") harness-fallback-models)) 5 "moved")
    (harness-test-wait (lambda () (string-match-p "1\\. Demo  " (harness-ui-usage-test-text))) 5 "shown first")
    ;; Remove it again through `d': the provider entry, then the model one.
    (with-current-buffer harness-ui-usage--buffer-name
      (goto-char (point-min))
      (search-forward "1. Demo")
      (harness-ui-usage-remove))
    (harness-test-wait (lambda () (equal '("demo:scripted") harness-fallback-models)) 5 "removed")
    (harness-test-wait (lambda () (string-match-p "1\\. Demo scripted" (harness-ui-usage-test-text))) 5 "shown alone")
    (should-not (string-match-p "2\\." (harness-ui-usage-test-text)))
    (with-current-buffer harness-ui-usage--buffer-name
      (goto-char (point-min))
      (search-forward "1. Demo scripted")
      (harness-ui-usage-remove))
    (harness-test-wait (lambda () (null harness-fallback-models)) 5 "empty")
    (harness-test-wait (lambda () (string-match-p "sessions stop when their provider runs out"
                                                  (harness-ui-usage-test-text)))
                       5 "empty list shown")))

(provide 'harness-ui-usage-test)
;;; harness-ui-usage-test.el ends here
