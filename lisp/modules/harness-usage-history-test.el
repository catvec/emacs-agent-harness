;;; harness-usage-history-test.el --- Historical accounting regression tests -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)
(require 'harness-usage-history)

(defun harness-history-test-row (id usage &rest props)
  "Return a ledger row ID with presence-preserving USAGE and PROPS."
  (harness-plist-merge
   (list :id id :ts 100.0 :session (format "s%s" id) :project "/project/.worktrees/a/" :main "/project/"
         :model "fixture:model" :billing "api" :cost 9.0
         :details (list :version 1 :usage usage :input-semantics "exclusive" :cache-write-status "reported"
                        :cost-source "observed" :observed-cost 9.0 :currency "USD" :priced-at 100.0
                        :pricing '(:input 2.0 :output 10.0 :cache-read 0.2 :cache-write 3.0))) props))

(defun harness-history-test-category (aggregate key)
  "Return category KEY from AGGREGATE."
  (cl-find key (plist-get aggregate :categories) :key (lambda (c) (plist-get c :key)) :test #'equal))

(defun harness-history-test-totals (rows &optional samples models opts)
  "Compute totals of ROWS and SAMPLES with MODELS and OPTS."
  (plist-get (harness-usage-history-compute rows samples models opts) :totals))

(ert-deftest harness-history-inclusive-exclusive-mixed-providers ()
  (let* ((inclusive (harness-history-test-row 1 '(:input 1000 :output 100 :cache-read 900)))
         (exclusive (harness-history-test-row 2 '(:input 100 :output 20 :cache-read 1000 :cache-write 200)))
         (_ (setf (plist-get (plist-get inclusive :details) :input-semantics) "inclusive"
                  (plist-get (plist-get inclusive :details) :cache-write-status) "not-reported"
                  (plist-get inclusive :model) "openai:model"
                  (plist-get exclusive :model) "claude:model"))
         (totals (harness-history-test-totals (list inclusive exclusive))))
    (should (= 200 (plist-get (harness-history-test-category totals "input") :tokens)))
    (should (= 1900 (plist-get (harness-history-test-category totals "cache-read") :tokens)))
    (should (= 200 (plist-get (harness-history-test-category totals "cache-write") :tokens)))
    (should (= 120 (plist-get (harness-history-test-category totals "output") :tokens)))
    (should (= 2420 (plist-get totals :token-denominator)))
    (should (= 18.0 (plist-get totals :observed-cost)))
    ;; Invoice dollars are never apportioned to token kinds.
    (should (< (plist-get totals :money-denominator) 0.01))
    (should (equal "not-majority" (plist-get (plist-get totals :cohort) :verdict)))
    (should (= 2 (plist-get (plist-get totals :cohort) :records)))))

(ert-deftest harness-history-inclusive-separate-writes-no-double-count ()
  (let* ((row (harness-history-test-row 1 '(:input 1000 :cache-read 600 :cache-write 200 :output 10)))
         (_ (setf (plist-get (plist-get row :details) :input-semantics) "inclusive"))
         (totals (harness-history-test-totals (list row))))
    (should (= 200 (plist-get (harness-history-test-category totals "input") :tokens)))
    (should (= 1010 (plist-get totals :token-denominator)))
    (should (= 1 (plist-get totals :complete-records)))))

(ert-deftest harness-history-unknown-zero-and-partial-are-distinct ()
  (let* ((zero (harness-history-test-row 1 '(:input 0 :output 0 :cache-read 0 :cache-write 0)))
         (missing (harness-history-test-row 2 '(:output 30)))
         (_ (setf (plist-get (plist-get missing :details) :input-semantics) "unknown"))
         (totals (harness-history-test-totals (list zero missing)))
         (read (harness-history-test-category totals "cache-read")))
    (should (= 0 (plist-get read :tokens)))
    (should (equal "partial" (plist-get read :state)))
    (should (= 1 (plist-get read :known)))
    (should (= 2 (plist-get read :records)))
    (should (= 0.0 (plist-get read :cost)))
    (should (= 30 (plist-get totals :token-denominator)))
    (let* ((unknown (harness-history-test-totals (list missing)))
           (read (harness-history-test-category unknown "cache-read")))
      (should-not (plist-get read :tokens))
      (should-not (plist-get read :cost))
      (should-not (plist-get read :token-share))
      (should (equal "unknown" (plist-get read :state))))
    (let ((all-zero (harness-history-test-totals (list zero))))
      (should (= 0 (plist-get all-zero :token-denominator)))
      (should-not (plist-get (harness-history-test-category all-zero "output") :token-share)))))

(ert-deftest harness-history-partial-inclusive-input-remains-unclassified ()
  (dolist (usage '((:input 100 :output 10) (:input 40 :cache-read 60 :output 10)
                   (:input 100 :cache-read 20 :output 10 :cache-write -1)))
    (let* ((row (harness-history-test-row 1 usage))
           (_ (setf (plist-get (plist-get row :details) :input-semantics) "inclusive"))
           (totals (harness-history-test-totals (list row))))
      (should-not (plist-get (harness-history-test-category totals "input") :tokens))
      (should (> (plist-get totals :unclassified-input) 0))
      (should (= 0 (plist-get (plist-get totals :cohort) :records))))))

(ert-deftest harness-history-contradictory-inclusive-cache-counters-not-priced ()
  (let* ((row (harness-history-test-row 1 '(:input 40 :cache-read 60 :cache-write 10 :output 5)))
         (_ (setf (plist-get (plist-get row :details) :input-semantics) "inclusive"))
         (totals (harness-history-test-totals (list row))))
    (dolist (key '("input" "cache-read" "cache-write"))
      (should-not (plist-get (harness-history-test-category totals key) :tokens))
      (should-not (plist-get (harness-history-test-category totals key) :cost)))
    (should (= 5 (plist-get totals :token-denominator)))
    (should (= 0 (plist-get totals :complete-records)))))

(ert-deftest harness-history-unavailable-writes-never-zero ()
  (let* ((row (harness-history-test-row 1 '(:input 100 :output 10 :cache-read 900 :cache-write 0)))
         (_ (setf (plist-get (plist-get row :details) :cache-write-status) "not-reported"))
         (totals (harness-history-test-totals (list row)))
         (write (harness-history-test-category totals "cache-write")))
    (should (equal "not-reported" (plist-get write :state)))
    (should-not (plist-get write :tokens))
    (should-not (plist-get write :cost))
    (should-not (plist-get write :token-share))
    (should (= 1 (plist-get totals :complete-records)))))

(ert-deftest harness-history-observed-estimated-subscription-and-legacy-spending ()
  (let* ((observed (harness-history-test-row 1 '(:input 20 :output 10 :cache-read 10000 :cache-write 0)))
         (estimated (harness-history-test-row 2 '(:input 20 :output 10 :cache-read 0 :cache-write 0)))
         (plan (harness-history-test-row 3 '(:input 20 :output 10 :cache-read 99999999 :cache-write 0)))
         (legacy (list :id 4 :ts 100.0 :session "s4" :model "openai:m" :project "/p/" :main "/p/"
                       :input 0 :output 0 :cache-read 0 :cache-write 0 :cost 4.5))
         (_ (setf (plist-get (plist-get estimated :details) :cost-source) "estimated"
                  (plist-get (plist-get estimated :details) :observed-cost) nil
                  (plist-get plan :billing) "subscription"
                  (plist-get (plist-get plan :details) :cost-source) "subscription"))
         (totals (harness-history-test-totals (list observed estimated plan legacy))))
    (should (= 9.0 (plist-get totals :observed-cost)))
    (should (= 1 (plist-get totals :observed-records)))
    (should (= 4.5 (plist-get totals :recorded-unknown)))
    (should (= 1 (plist-get totals :plan-records)))
    (should (= 2 (plist-get (plist-get totals :cohort) :records)))
    (should (equal "majority" (plist-get (plist-get totals :cohort) :verdict)))
    (should (= 1 (plist-get totals :legacy-records)))
    ;; The legacy zeros cannot turn three known records into four.
    (should (= 3 (plist-get (harness-history-test-category totals "cache-read") :known)))))

(ert-deftest harness-history-missing-prices-and-currency-exclusions ()
  (let* ((row (harness-history-test-row 1 '(:input 100 :output 10 :cache-read 100 :cache-write 20)))
         (_ (setf (plist-get (plist-get row :details) :pricing) '(:input 2.0 :cache-read 0.0)))
         (totals (harness-history-test-totals (list row))))
    (should (= 0.0 (plist-get (harness-history-test-category totals "cache-read") :cost)))
    (should-not (plist-get (harness-history-test-category totals "output") :cost))
    (should-not (plist-get (harness-history-test-category totals "cache-write") :cost))
    (should (= 0 (plist-get (plist-get totals :cohort) :records)))
    (setf (plist-get (plist-get row :details) :currency) "EUR")
    (let ((foreign (harness-history-test-totals (list row))))
      (should-not (plist-get foreign :observed-cost))
      (should-not (plist-get foreign :money-denominator)))))

(ert-deftest harness-history-snapshot-and-clock-pricing-matrix ()
  (let* ((snap (harness-history-test-row 1 '(:input 100 :output 10 :cache-read 100 :cache-write 1)))
         (catalogue (harness-history-test-row 2 '(:input 100 :output 10 :cache-read 100 :cache-write 1) :ts 200.0))
         (_ (setf (plist-get (plist-get catalogue :details) :pricing) nil))
         (models (list (list :id "fixture:model" :pricing-fn
                             (lambda (_model _usage at) (list :input at :output 1 :cache-read 1 :cache-write 1)))))
         (totals (harness-history-test-totals (list snap catalogue) nil models))
         (matrix (plist-get totals :prices)))
    (should (= 2 (length matrix)))
    (should (equal '("snapshot" "catalogue") (mapcar (lambda (r) (plist-get r :source)) matrix)))
    (should (= 2 (plist-get (plist-get (car matrix) :pricing) :input)))
    (should (= 200 (plist-get (plist-get (cadr matrix) :pricing) :input)))))

(ert-deftest harness-history-precedence-duplicates-and-half-open-boundaries ()
  (let* ((row (harness-history-test-row 1 '(:input 10 :output 1 :cache-read 0 :cache-write 0)))
         (sample '(:id "log1" :source "session-log" :session "s1" :ts 100 :usage (:output 900)))
         (other '(:id "log2" :source "session-log" :session "s2" :ts 200 :usage (:output 20)))
         (report (harness-usage-history-compute (list row row) (list sample other other) nil '(:since 100 :until 200)))
         (totals (plist-get report :totals)))
    (should (= 1 (plist-get totals :records)))
    (should (= 1 (plist-get (harness-history-test-category totals "output") :tokens)))
    (should (= 2 (plist-get (plist-get report :coverage) :duplicates)))
    (should (= 1 (plist-get (plist-get report :coverage) :overlap)))
    ;; Ledger precedence is decided before filtering the ledger's timestamp.
    (should (= 0 (plist-get (harness-history-test-totals (list row) (list sample) nil '(:until 100)) :records)))))

(ert-deftest harness-history-project-workspace-overall-and-local-day ()
  (let* ((day1 (float-time (encode-time 0 0 12 1 6 2026)))
         (day2 (float-time (encode-time 0 0 12 2 6 2026)))
         (usage '(:input 10 :output 2 :cache-read 3 :cache-write 4))
         (rows (list (harness-history-test-row 1 usage :ts day1)
                     (harness-history-test-row 2 usage :ts day2 :project "/project/.worktrees/b/")
                     (harness-history-test-row 3 usage :ts day2 :project "/other/" :main "/other/"))))
    (dolist (group '(overall project workspace day))
      (let* ((report (harness-usage-history-compute rows nil nil (list :group-by group)))
             (groups (plist-get report :groups)))
        (should (= (pcase group ('overall 1) ('workspace 3) (_ 2)) (length groups)))
        (should (= 3 (apply #'+ (mapcar (lambda (r) (plist-get r :records)) groups))))
        (should (= 57 (apply #'+ (mapcar (lambda (r) (plist-get r :token-denominator)) groups))))))
    (should (= 2 (plist-get (harness-history-test-totals rows nil nil '(:project "/project/")) :records)))
    (should (= 1 (plist-get (harness-history-test-totals rows nil nil '(:workspace "/project/.worktrees/a/")) :records)))))

(ert-deftest harness-history-aggregate-privacy-and-empty-unknown ()
  (let* ((row (harness-history-test-row 1 '(:output 10 :prompt "PRIVATE_PROMPT" :api-key "PRIVATE_SECRET")
                                      :content "PRIVATE_BODY" :session-name "PRIVATE_NAME"))
         (report (harness-usage-history-compute (list row) nil nil nil)))
    (should-not (string-match-p "PRIVATE_" (prin1-to-string report))))
  (let ((empty (harness-history-test-totals nil)))
    (should (= 0 (plist-get empty :records)))
    (should-not (plist-get empty :observed-cost))
    (should-not (plist-get empty :token-denominator))
    (should-not (plist-get empty :money-denominator))))

(ert-deftest harness-history-currency-provenance-and-coverage-privacy ()
  (let* ((details (harness-usage--clean-details '(:version 1 :currency "EUR" :usage (:output 10))))
         (report (harness-usage-history-compute nil nil nil nil '(:sessions ((:session "private-id")) :files-read 0))))
    (should (equal "EUR" (plist-get details :currency)))
    (should-not (string-match-p "private-id" (prin1-to-string report)))
    (should-not (plist-member (plist-get report :coverage) :sessions))))

(ert-deftest harness-history-old-copilot-conversion-is-not-observed ()
  (let ((sample (harness-usage-history-scan-normalize '(:cost 0.5 :billing "extra-usage") "copilot:model" "turn" "session-log")))
    (should (equal "estimated" (plist-get sample :cost-source)))
    (should-not (plist-get sample :observed-cost))))

(ert-deftest harness-history-periods-use-harness-calendar-and-half-open-now ()
  (let ((old-zone (getenv "TZ")))
    (unwind-protect
        (progn
          (set-time-zone-rule "America/New_York")
          (let* ((now (float-time (encode-time 0 0 12 9 3 2026)))
                 (opts (harness-usage-history--period-opts '(:period "7d") now)))
            (should (= (float-time (encode-time 0 0 0 3 3 2026)) (plist-get opts :since)))
            (should (= now (plist-get opts :until)))
            (should-not (plist-get (harness-usage-history--period-opts '(:period "all" :since 1) now) :since))
            (should-error (harness-usage-history--period-opts '(:period "invalid") now))))
      (set-time-zone-rule old-zone))))

(ert-deftest harness-history-cold-provider-inspection-without-fetch-or-auth ()
  (harness-test-with-temp-state
    (harness-test-reset-bus)
    (dolist (module '(store provider tools session usage usage-history)) (harness-test-load-module module))
    (let ((calls 0))
      (unwind-protect
          (progn
            (harness-define-provider 'history-cold :complete #'ignore
              :models (lambda () (cl-incf calls) (error "Unexpected provider fetch")))
            (harness-call 'usage/record
                          '(:session "fixture" :model "history-cold:example" :ts 100 :billing api :cost 0.5
                            :details (:version 1 :usage (:input 100 :output 10 :cache-read 50)
                                               :input-semantics "exclusive" :cache-write-status "not-reported"
                                               :cost-source "observed" :observed-cost 0.5 :pricing nil :currency "USD")))
            (cl-letf (((symbol-function 'harness-usage-history-scan-run)
                       (lambda (_) (harness-resolved '(:samples nil :coverage (:status "empty"))))))
              (let* ((report (harness-test-await (harness-call 'usage/history :since 0 :until 200)))
                     (totals (plist-get report :totals)))
                (should (= 0 calls))
                (should (= 0.5 (plist-get totals :observed-cost)))
                (should-not (plist-get totals :money-denominator)))))
        (remhash 'history-cold harness-providers)
        (harness-provider--forget 'history-cold)))))

(provide 'harness-usage-history-test)
;;; harness-usage-history-test.el ends here
