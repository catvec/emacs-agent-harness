;;; harness-ui-usage-history-test.el --- Historical view and exact copy -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui-usage-history)

(defmacro harness-history-ui-test-with (&rest body)
  "Run BODY in a fresh historical view with a deterministic width."
  (declare (indent 0))
  `(with-temp-buffer
     (harness-ui-usage-history-mode)
     (cl-letf (((symbol-function 'harness-ui-usage-history--room) (lambda () 120)))
       ,@body)))

(defun harness-history-ui-test-text ()
  "Return the rendered text without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun harness-history-ui-test-tooltips (text)
  "Return sorted distinct tooltips in TEXT."
  (let ((pos 0) values)
    (while (< pos (length text))
      (when-let* ((value (get-text-property pos 'help-echo text))) (push value values))
      (setq pos (or (next-single-property-change pos 'help-echo text) (length text))))
    (sort (delete-dups values) #'string<)))

(defconst harness-history-ui-test-partial
  '(:since nil :until 0.0 :timezone "UTC" :group-by "project"
    :coverage (:overlap 1 :duplicates 2 :gaps ("missing-file"))
    :totals (:key "Overall" :records 2 :token-denominator 1000 :money-denominator 0.002
             :observed-cost 0.5 :observed-records 1 :recorded-unknown 0.25 :plan-records 0
             :complete-records 1 :ledger-records 1 :log-records 1 :legacy-records 1
             :cohort (:records 1 :cost 0.002 :cache-read-cost 0.0001 :share 0.05 :verdict "not-majority")
             :categories ((:key "cache-read" :tokens 900 :cost 0.0001 :token-share 0.9 :cost-share 0.05 :known 1 :priced 1 :records 2 :state "partial")
                          (:key "cache-write" :tokens nil :cost nil :known 0 :priced 0 :records 2 :state "not-reported")
                          (:key "input" :tokens 100 :cost 0.0019 :token-share 0.1 :cost-share 0.95 :known 2 :priced 2 :records 2 :state "complete")
                          (:key "output" :tokens nil :cost nil :known 0 :priced 0 :records 2 :state "unknown")))
    :groups ((:key "/example/project/" :records 2 :token-denominator 1000 :money-denominator 0.002))))

(ert-deftest harness-history-ui-navigation-and-tooltip-copy-inventory ()
  (harness-history-ui-test-with
    (let ((header (harness-ui-usage-history--header 2000)))
      (should (equal (substring-no-properties header)
                     " Usage  Token mix  Today  7 days  30 days  All  Overall  Project  Workspace  Day  Help  Refresh  Close "))
      (should (equal (harness-history-ui-test-tooltips header)
                     (sort '("Usage and cost dashboard" "Local calendar day" "Last seven calendar days"
                             "Last thirty calendar days" "All available history" "Overall breakdown" "Project breakdown"
                             "Workspace breakdown" "Daily breakdown" "Accounting and coverage help" "Usage refresh" "View closure") #'string<)))
      (should (eq (lookup-key harness-ui-usage-mode-map (kbd "H")) #'harness-usage-history)))
    (let ((harness-ui-usage--period '7d) (harness-ui-usage--group 'project))
      (should (string-match-p "Token mix" (harness-ui-usage--header 2000))))))

(ert-deftest harness-history-ui-loading-empty-and-failure-copy-inventory ()
  (harness-history-ui-test-with
    (setq harness-ui-usage-history--loading t)
    (harness-ui-usage-history--render)
    (should (equal (harness-history-ui-test-text) "\n Historical token mix\n Loading history…\n"))
    (setq harness-ui-usage-history--loading nil harness-ui-usage-history--error "transport-data")
    (harness-ui-usage-history--render)
    (should (equal (harness-history-ui-test-text) "\n Historical token mix\n History unavailable\n transport-data\n"))
    (setq harness-ui-usage-history--error nil
          harness-ui-usage-history--data '(:totals (:records 0) :coverage nil))
    (harness-ui-usage-history--render)
    (should (equal (harness-history-ui-test-text)
                   (concat "\n Historical token mix\n Period All — Unknown · Local time Unknown\n"
                           "\n No historical usage\n\n Coverage\n Historical coverage · recorded metadata\n"
                           " Complete 0/0 records · Ledger records 0 · Log records 0\n"
                           " Overlap exclusions 0 · Duplicate exclusions 0\n Help\n")))
    (should-not (string-match-p "Observed billed USD 0" (harness-history-ui-test-text)))))

(ert-deftest harness-history-ui-partial-rendered-copy-and-category-tooltips ()
  (harness-history-ui-test-with
    (setq harness-ui-usage-history--data harness-history-ui-test-partial harness-ui-usage-history--group 'project)
    (let ((old-zone (getenv "TZ")))
      (unwind-protect
          (progn (set-time-zone-rule "UTC") (harness-ui-usage-history--render))
        (set-time-zone-rule old-zone)))
    (let ((lines (split-string (harness-history-ui-test-text) "\n" t)))
      (should (equal (cl-subseq lines 0 5)
                     '(" Historical token mix" " Period All — 1970-01-01 00:00 · Local time UTC"
                       " Token categories" " Known category tokens 1000" " Known reconstructed USD 0.002")))
      (should (equal (cl-remove-if-not (lambda (s) (or (string-match-p "Observed billed\\|Recorded USD\\|Plan-covered\\|majority\\|Comparable records\\|Cache read ·" s))) lines)
                     '(" Observed billed USD 0.5 · 1/2 records" " Recorded USD · origin unknown 0.25"
                       " Plan-covered records 0" " No cache-read majority" " Reconstructed spending · comparable records"
                       " Comparable records 1/2 · USD 0.002"
                       " Cache read · USD 0.0001 · 5.0%")))
      (should (equal (cl-remove-if-not (lambda (s) (string-match-p "Historical coverage\\|Complete 1/2\\|Overlap exclusions\\|Source gaps" s)) lines)
                     '(" Historical coverage · partial" " Complete 1/2 records · Ledger records 1 · Log records 1"
                       " Overlap exclusions 1 · Duplicate exclusions 2" " Source gaps missing-file"))))
    (should (equal (harness-history-ui-test-tooltips (buffer-string))
                   (sort '("Known disjoint category tokens" "Share of known category tokens"
                           "Token-count × rate estimate · not an invoice allocation" "Share of known reconstructed USD"
                           "Known records / selected records" "Accounting and coverage help" "Source gaps missing-file"
                           "Historical token mix and spend · /example/project/") #'string<)))
    (should (string-match-p "Cache write +Not reported +Not reported +Not reported +Not reported +0/2 +Not reported" (harness-history-ui-test-text)))
    (should (string-match-p "Output +Unknown +Unknown +Unknown +Unknown +0/2 +Unknown" (harness-history-ui-test-text)))))

(ert-deftest harness-history-ui-narrow-copy-and-no-overflow ()
  (harness-history-ui-test-with
    (setq harness-ui-usage-history--data harness-history-ui-test-partial)
    (cl-letf (((symbol-function 'harness-ui-usage-history--room) (lambda () 54)))
      (harness-ui-usage-history--render)
      (dolist (line (split-string (harness-history-ui-test-text) "\n"))
        (should (<= (string-width line) 55)))
      (should (string-match-p (regexp-quote "Cache read · Partial · 1/2 records\n   Tokens 900 · 90.0%\n   Reconstructed USD 0.0001 · 5.0%")
                             (harness-history-ui-test-text)))
      (should (string-match-p (regexp-quote "Cache write · Not reported · 0/2 records\n   Tokens Not reported · Not reported\n   Reconstructed USD Not reported · Not reported")
                             (harness-history-ui-test-text))))))

(ert-deftest harness-history-ui-stale-async-results-and-validation ()
  (harness-history-ui-test-with
    (let (requests)
      (cl-letf (((symbol-function 'harness-ui-call)
                 (lambda (method params success failure)
                   (push (list method params success failure) requests))))
        (harness-ui-usage-history-set-period 'all)
        (should (equal (caar requests) "_harness/usage/history"))
        (should-not (plist-get (cadar requests) :since))
        (harness-ui-usage-history-set-group 'day)
        (should (equal (plist-get (cadar requests) :group-by) "day"))
        (funcall (nth 2 (cadr requests)) harness-history-ui-test-partial)
        (should harness-ui-usage-history--loading)
        (funcall (nth 2 (car requests)) '(:totals (:records 0)))
        (should-not harness-ui-usage-history--loading)
        (should (= 0 (plist-get (plist-get harness-ui-usage-history--data :totals) :records)))
        (funcall (nth 3 (cadr requests)) "old-failure")
        (should-not harness-ui-usage-history--error)))
    (should (equal (cdr (should-error (harness-ui-usage-history-set-period 'invalid) :type 'user-error)) '("Unknown history period")))
    (should (equal (cdr (should-error (harness-ui-usage-history-set-group 'invalid) :type 'user-error)) '("Unknown history grouping")))
    (should (equal (cdr (should-error (harness-ui-usage-history-open) :type 'user-error)) '("No group at point")))))

(ert-deftest harness-history-ui-group-drilldown-and-return ()
  (harness-history-ui-test-with
    (setq harness-ui-usage-history--data harness-history-ui-test-partial harness-ui-usage-history--group 'project)
    (harness-ui-usage-history--render)
    (goto-char (point-min))
    (search-forward "/example/project/")
    (harness-ui-usage-history-open)
    (should (equal harness-ui-usage-history--selected "/example/project/"))
    (let ((header (harness-ui-usage-history--header 2000)))
      (should (string-match-p " Back " header))
      (should (member "All groups" (harness-history-ui-test-tooltips header))))
    (harness-ui-usage-history-back)
    (should-not harness-ui-usage-history--selected)))

(ert-deftest harness-history-ui-help-and-menu-copy-inventory ()
  (harness-history-ui-test-with
    (save-window-excursion
      (harness-ui-usage-history-help)
      (with-current-buffer "*harness token mix help*"
        (should word-wrap)
        (should (string-prefix-p "Accounting and coverage help\n\nSources and confidence\n" (buffer-string)))
        (dolist (phrase '("not invoice contributions" "not a historical price archive" "greater than half" "not a zero-spend day" "No prompts, responses"))
          (should (string-match-p (regexp-quote phrase) (buffer-string)))))
      (kill-buffer "*harness token mix help*")))
  (should (equal (get 'harness-ui-usage-history-mode 'harness-menu-group)
                 '("Token mix"
                   ["View" (". t" "Next period" harness-ui-usage-history-cycle-period)
                    (". b" "Grouping" harness-ui-usage-history-cycle-group)
                    (". RET" "Group details" harness-ui-usage-history-open)
                    (". l" "All groups" harness-ui-usage-history-back)
                    (". g" "Refresh" harness-ui-usage-history-refresh)
                    (". h" "Accounting help" harness-ui-usage-history-help)
                    (". u" "Usage" harness-usage)]))))

(ert-deftest harness-history-ui-calendar-midnight-across-dst ()
  (let* ((process-environment (cons "TZ=America/New_York" process-environment))
         (now (encode-time 0 0 12 9 3 2026))
         (decoded (decode-time now)))
    (cl-letf (((symbol-function 'decode-time) (lambda (&rest _) decoded)))
      ;; Six calendar days earlier, not 6 * 24 hours through the DST jump.
      (should (= (float-time (encode-time 0 0 0 3 3 2026)) (harness-ui-usage--midnight 6))))))

(ert-deftest harness-history-ui-real-acp-aggregate-roundtrip ()
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (let ((harness-acp--server-enabled nil))
      (dolist (m '(store config provider provider-demo tools session agent usage usage-history acp ui ui-usage ui-usage-history))
        (harness-test-load-module m)))
    (let ((harness-acp-token nil))
      (unwind-protect
          (progn
            (harness-call 'usage/record
                          '(:id "fixture" :ts 100 :session "fixture" :project "/example/" :model "demo:scripted" :billing api
                            :cost 0.5 :details (:version 1 :usage (:input 1000 :cache-read 900 :output 100)
                                                       :input-semantics "inclusive" :cache-write-status "not-reported"
                                                       :cost-source "observed" :observed-cost 0.5 :currency "USD"
                                                       :pricing (:input 2 :cache-read 0.2 :output 10) :priced-at 100)))
            (let* ((report (harness-test-await
                            (harness-ui-request "_harness/usage/history" '(:since 0 :until 200 :group-by "workspace"))))
                   (totals (plist-get report :totals)))
              (should (= 1 (plist-get totals :records)))
              (should (= 1100 (plist-get totals :token-denominator)))
              (should (= 0.5 (plist-get totals :observed-cost)))
              (should (equal "/example/" (plist-get (car (plist-get report :groups)) :key)))
              (should-not (plist-member report :samples))
              (should-not (plist-member totals :usage))))
        (dolist (client (copy-sequence harness-acp--clients)) (harness-acp--drop-client client))))))

(ert-deftest harness-history-ui-price-matrix-copy-and-remote-date-labels ()
  (harness-history-ui-test-with
    (let ((inhibit-read-only t))
      (harness-ui-usage-history--prices
       '(:prices ((:model "example:model" :source "snapshot" :currency "USD" :records 2
                   :price-since 0 :price-until 0 :price-since-label "Server start" :price-until-label "Server end"
                   :pricing (:input 2.0)
                   :categories ((:key "input" :tokens 100 :cost 0.0002 :known 1 :records 2)
                                (:key "cache-write" :unavailable t)))))))
    (should (equal (harness-history-ui-test-text)
                   (concat "\n Pricing matrix\n example:model · Snapshot · Records 2\n"
                           "   Rates · USD / million tokens\n   Price date Server start — Server end\n"
                           "   Uncached input 2 · 100 tokens · USD 0.0002 · 1/2 records\n"
                           "   Cache write    Not reported\n")))
    (should (equal (harness-history-ui-test-tooltips (buffer-string))
                   '("Cache write Not reported" "Uncached input 2 · 100 tokens · USD 0.0002 · 1/2 records")))
    (setq harness-ui-usage-history--data '(:since 0 :until 0 :since-label "Server start" :until-label "Server end"
                                               :timezone "SERVER" :totals (:records 0)))
    (harness-ui-usage-history--render)
    (should (string-match-p (regexp-quote "Period Server start — Server end · Local time SERVER") (harness-history-ui-test-text)))))

(ert-deftest harness-history-ui-selected-group-disappearance-stays-empty ()
  (harness-history-ui-test-with
    (setq harness-ui-usage-history--group 'project
          harness-ui-usage-history--selected "/project/a/"
          harness-ui-usage-history--data harness-history-ui-test-partial)
    (harness-ui-usage-history--render)
    (should (string-match-p (regexp-quote "/project/a/") (harness-history-ui-test-text)))
    (should (string-match-p "No historical usage" (harness-history-ui-test-text)))
    (should-not (string-match-p "Token categories\\|Observed billed USD 0.5" (harness-history-ui-test-text)))
    (should (equal harness-ui-usage-history--selected "/project/a/"))
    (harness-ui-usage-history-back)
    (should (string-match-p "Observed billed USD 0.5" (harness-history-ui-test-text)))))

(ert-deftest harness-history-ui-source-coverage-copy-inventory ()
  (harness-history-ui-test-with
    (let ((inhibit-read-only t))
      (harness-ui-usage-history--coverage
       '(:records 2 :complete-records 1 :ledger-records 2 :log-records 0 :unclassified-input 20)
       '(:coverage (:overlap 3 :duplicates 1 :ledger-session-exclusions 4
                    :files-read 2 :files-requested 3 :files-missing 1 :files-unreadable 0
                    :ambiguous-samples 2 :undated-samples 1 :undated 2 :gaps ("missing-files")))))
    (should (equal (harness-history-ui-test-text)
                   (concat "\n Coverage\n Historical coverage · partial\n"
                           " Complete 1/2 records · Ledger records 2 · Log records 0\n"
                           " Unclassified input 20\n Overlap exclusions 3 · Duplicate exclusions 1\n"
                           " Ledger-precedence sessions 4\n Metadata files 2/3 · Missing 1 · Unreadable 0\n"
                           " Ambiguous records 2 · Undated records 3\n Source gaps missing-files\n Help\n")))
    (let ((harness-ui-usage-history--group 'workspace)
          (key "/long/example/project/.worktrees/a-distinct-workspace/"))
      (cl-letf (((symbol-function 'harness-ui-usage-history--room) (lambda () 32)))
        (should (string-suffix-p "workspace/" (harness-ui-usage-history--scope-label key)))
        (should (<= (string-width (harness-ui-usage-history--scope-label key)) 32))))))

(provide 'harness-ui-usage-history-test)
;;; harness-ui-usage-history-test.el ends here
