;;; harness-usage.el --- Cost and usage accounting -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; Aggregates token and cost usage across sessions, projects and models
;; from session metadata plus the timestamped `usage_update` entries the
;; agent writes for every model call.  Also evaluates budgets (per
;; session, project or global; per day, week, month or all time) and can
;; enforce hard quotas before a turn starts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-session)

(defcustom harness-usage-budgets nil
  "Budgets to track and optionally enforce.

Each entry is a plist:
  :scope    `global' or `project'
  :project  project root when :scope is `project'
  :period   `daily', `weekly', `monthly' or `all'
  :amount   budget in the currency below
  :currency currency, default \"USD\"
  :hard     when non-nil, refuse to start turns while over budget"
  :type '(repeat (plist :key-type symbol :value-type sexp)))

(defcustom harness-usage-week-starts-on 1
  "Day a usage week starts on (0 = Sunday, 1 = Monday)."
  :type 'natnum)

(defcustom harness-usage-transcript-scan-days 40
  "How far back period reports read transcripts."
  :type 'natnum)

(defun harness-usage--infos ()
  "Return every session info plist."
  (if (harness-service-available-p "session" 'infos)
      (append (harness-service-call "session" 'infos) nil)
    nil))

(defun harness-usage--usage-totals (&optional infos)
  "Sum INFOS' all-time usage and cost."
  (let ((infos (or infos (harness-usage--infos)))
        (input 0) (output 0) (cache-read 0) (cache-write 0) (amount 0.0)
        (currency "USD") (sessions 0))
    (dolist (info infos)
      (cl-incf sessions)
      (let ((usage (plist-get info :usage)))
        (cl-incf input (or (plist-get usage :input) 0))
        (cl-incf output (or (plist-get usage :output) 0))
        (cl-incf cache-read (or (plist-get usage :cache-read) 0))
        (cl-incf cache-write (or (plist-get usage :cache-write) 0)))
      (let ((cost (plist-get info :cost)))
        (when (and cost (numberp (plist-get cost :amount)))
          (cl-incf amount (plist-get cost :amount))
          (setq currency (or (plist-get cost :currency) currency)))))
    (list :sessions sessions :input input :output output
          :cache-read cache-read :cache-write cache-write
          :cost (list :amount amount :currency currency))))

(defun harness-usage--group (infos key-function)
  "Group INFOS by KEY-FUNCTION into a list of aggregated plists."
  (let ((groups (make-hash-table :test #'equal)))
    (dolist (info infos)
      (let* ((key (funcall key-function info))
             (entry (gethash key groups)))
        (unless entry
          (setq entry (list :key key :sessions 0 :input 0 :output 0
                            :cost (list :amount 0.0 :currency "USD")))
          (puthash key entry groups))
        (setf (plist-get entry :sessions) (1+ (plist-get entry :sessions)))
        (let ((usage (plist-get info :usage)))
          (setf (plist-get entry :input) (+ (plist-get entry :input)
                                            (or (plist-get usage :input) 0)))
          (setf (plist-get entry :output) (+ (plist-get entry :output)
                                             (or (plist-get usage :output) 0))))
        (let ((cost (plist-get info :cost)))
          (when (and cost (numberp (plist-get cost :amount)))
            (setf (plist-get entry :cost)
                  (list :amount (+ (plist-get (plist-get entry :cost) :amount)
                                   (plist-get cost :amount))
                        :currency (or (plist-get cost :currency) "USD")))))))
    (sort (hash-table-values groups)
          (lambda (a b) (> (plist-get (plist-get a :cost) :amount)
                           (plist-get (plist-get b :cost) :amount))))))

;;; Periods

(defun harness-usage-period-start (period &optional now)
  "Return the epoch at the start of PERIOD relative to NOW."
  (let* ((now (or now (float-time)))
         (decoded (decode-time now))
         (start-of-day (let ((copy (copy-sequence decoded)))
                         (setf (decoded-time-hour copy) 0
                               (decoded-time-minute copy) 0
                               (decoded-time-second copy) 0)
                         (float-time (encode-time copy)))))
    (cond
     ((or (null period) (eq period 'all)) 0)
     ((eq period 'daily) start-of-day)
     ((eq period 'weekly) (let* ((weekday (nth 6 decoded))
                                 (shift (mod (- weekday harness-usage-week-starts-on) 7)))
                            (- start-of-day (* shift 86400))))
     ((eq period 'monthly) (let ((copy (copy-sequence decoded)))
                             (setf (decoded-time-day copy) 1
                                   (decoded-time-hour copy) 0
                                   (decoded-time-minute copy) 0
                                   (decoded-time-second copy) 0)
                             (float-time (encode-time copy))))
     (t start-of-day))))

(defun harness-usage--entry-time (entry)
  "Epoch of ENTRY's :time, or nil."
  (let ((time (plist-get entry :time)))
    (when (and time (stringp time))
      (ignore-errors (float-time (date-to-time time))))))

(defun harness-usage--entry-cost (entry)
  "Cost amount of ENTRY."
  (let ((cost (plist-get entry :cost)))
    (if (and cost (numberp (plist-get cost :amount)))
        (plist-get cost :amount)
      0.0)))

(defun harness-usage--scanned-entries (&optional since)
  "Usage entries since SINCE (default: scan window)."
  (let ((since (or since
                   (- (float-time) (* 86400 harness-usage-transcript-scan-days)))))
    (if (harness-service-available-p "session" 'usage-entries)
        (append (harness-service-call "session" 'usage-entries :since since) nil)
      nil)))

(defun harness-usage--period-spend (period &optional entries project)
  "Sum cost of ENTRIES inside PERIOD, optionally for PROJECT only."
  (let ((start (harness-usage-period-start period))
        (amount 0.0))
    (dolist (entry (or entries (harness-usage--scanned-entries start)))
      (let ((time (harness-usage--entry-time entry)))
        (when (and time (>= time start)
                   (or (null project)
                       (harness-usage--same-project-p
                        (plist-get entry :projectRoot) project)))
          (cl-incf amount (harness-usage--entry-cost entry)))))
    amount))

(defun harness-usage--same-project-p (a b)
  "Whether A and B name the same project directory."
  (and a b
       (equal (file-name-as-directory (expand-file-name a))
              (file-name-as-directory (expand-file-name b)))))

(defun harness-usage--budget-label (budget)
  "Human label for BUDGET."
  (format "%s budget (%s)"
          (if (eq (plist-get budget :scope) 'project)
              (or (plist-get budget :project) "project")
            "global")
          (or (plist-get budget :period) "all")))

;;; Summary

(defun harness-usage-summary ()
  "Return the complete usage report as a plist."
  (let* ((infos (harness-usage--infos))
         (entries (harness-usage--scanned-entries))
         (projects (harness-usage--group infos (lambda (info)
                                                 (or (plist-get info :projectRoot)
                                                     "(none)"))))
         (models (harness-usage--group
                  infos (lambda (info) (or (plist-get info :model) "(no model)"))))
         (budgets
          (mapcar
           (lambda (budget)
             (let* ((period (or (plist-get budget :period) 'all))
                    (project (and (eq (plist-get budget :scope) 'project)
                                  (plist-get budget :project)))
                    (spent (if (eq period 'all)
                               (cl-loop for info in infos
                                        when (or (null project)
                                                 (harness-usage--same-project-p
                                                  (plist-get info :projectRoot) project))
                                        sum (let ((cost (plist-get info :cost)))
                                              (if (and cost (numberp (plist-get cost :amount)))
                                                  (plist-get cost :amount)
                                                0.0)))
                             (harness-usage--period-spend period entries project)))
                    (amount (or (plist-get budget :amount) 0)))
               (list :label (harness-usage--budget-label budget)
                     :scope (or (plist-get budget :scope) 'global)
                     :project project
                     :period period
                     :amount amount
                     :spent spent
                     :remaining (- amount spent)
                     :hard (and (plist-get budget :hard) t)
                     :over (> spent amount)
                     :currency (or (plist-get budget :currency) "USD"))))
           harness-usage-budgets))
         ;; Per-period spend table for the overview.
         (periods (mapcar (lambda (period)
                            (list :period period
                                  :spent (harness-usage--period-spend period entries)))
                          '(daily weekly monthly))))
    (list :totals (harness-usage--usage-totals infos)
          :projects projects
          :models models
          :sessions (vconcat (mapcar (lambda (info)
                                       (list :sessionId (plist-get info :sessionId)
                                             :title (plist-get info :title)
                                             :projectRoot (plist-get info :projectRoot)
                                             :model (plist-get info :model)
                                             :status (plist-get info :status)
                                             :updatedEpoch (or (plist-get info :updatedEpoch) 0)
                                             :usage (plist-get info :usage)
                                             :cost (plist-get info :cost)))
                                     infos))
          :periods periods
          :budgets budgets)))

;;; Service

(defun harness-usage-service-summary (&rest _args)
  "Service: the usage report."
  (harness-usage-summary))

(defun harness-usage-service-budget-check (&rest args)
  "Service: check hard budgets before a turn of :session-id.
Returns nil when allowed, or a plist (:blocked t :reason STRING)."
  (let* ((session-id (plist-get args :session-id))
         (session (and session-id (harness-session-load session-id)))
         (project (and session (harness-session-project-root session))))
    (catch 'blocked
      (dolist (budget harness-usage-budgets)
        (when (plist-get budget :hard)
          (let* ((period (or (plist-get budget :period) 'all))
                 (scope-project (and (eq (plist-get budget :scope) 'project)
                                     (plist-get budget :project)))
                 (applies (or (null scope-project)
                              (harness-usage--same-project-p scope-project project)))
                 (amount (or (plist-get budget :amount) 0)))
            (when applies
              (let ((spent (harness-usage--period-spend period nil scope-project)))
                (when (> spent amount)
                  (throw 'blocked
                         (list :blocked t
                               :reason (format "%s is over budget (%.4f of %.4f %s); raise it or start a new period."
                                               (harness-usage--budget-label budget)
                                               spent amount
                                               (or (plist-get budget :currency) "USD"))))))))))
      nil)))

(defun harness-usage-setup ()
  "Set up the usage module."
  (harness-service-register
   "usage"
   :module 'harness-usage
   :doc "Token and cost accounting, periods and budgets."
   :methods '((summary . harness-usage-service-summary)
              (budget-check . harness-usage-service-budget-check))))

(defun harness-usage-teardown ()
  "Tear down the usage module."
  (harness-service-unregister "usage"))

(harness-module-define 'harness-usage
  :version harness-version
  :description "Usage and cost aggregation, periods and budgets."
  :requires '((harness-core "0.1.0")
              (harness-session "0.1.0"))
  :provides '(harness-usage)
  :setup #'harness-usage-setup
  :teardown #'harness-usage-teardown)

(provide 'harness-usage)
;;; harness-usage.el ends here
