;;; harness-ui-usage-history.el --- Historical token mix and spend view -*- lexical-binding: t; -*-

;;; Commentary:

;; A read-only companion of the usage dashboard.  All accounting and private
;; log reading stays in the harness; this UI consumes usage/history over ACP.
;; The two denominators are displayed explicitly, and category estimates never
;; pretend to allocate observed bills.  See docs/design/historical-token-mix.md.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'button)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-usage)

(defconst harness-ui-usage-history--buffer "*harness token mix*")
(defconst harness-ui-usage-history--periods
  '((today "Today" "Local calendar day") (7d "7 days" "Last seven calendar days")
    (30d "30 days" "Last thirty calendar days") (all "All" "All available history")))
(defconst harness-ui-usage-history--groups
  '((overall "Overall" "Overall breakdown") (project "Project" "Project breakdown")
    (workspace "Workspace" "Workspace breakdown") (day "Day" "Daily breakdown")))
(defconst harness-ui-usage-history--labels
  '(("cache-read" . "Cache read") ("cache-write" . "Cache write")
    ("input" . "Uncached input") ("output" . "Output")))

(defvar-local harness-ui-usage-history--period '7d)
(defvar-local harness-ui-usage-history--group 'overall)
(defvar-local harness-ui-usage-history--selected nil)
(defvar-local harness-ui-usage-history--data nil)
(defvar-local harness-ui-usage-history--loading nil)
(defvar-local harness-ui-usage-history--error nil)
(defvar-local harness-ui-usage-history--generation 0)

(defun harness-ui-usage-history--action (label command help &optional selected)
  "Return a header LABEL with COMMAND, HELP and SELECTED appearance."
  (harness-ui-usage--segment label command selected help))

(defun harness-ui-usage-history--header (&optional width)
  "Return the fitted navigation header for WIDTH with overflow actions."
  (harness-ui-fit-header
   (append
    (list (list (harness-ui-usage-history--action "Usage" #'harness-usage "Usage and cost dashboard") 90 nil #'harness-usage)
          (list (propertize " Token mix " 'face 'harness-usage-heading-face) 100))
    (mapcar (lambda (p)
              (let* ((period (car p))
                     (command (lambda () (interactive) (harness-ui-usage-history-set-period period))))
                (list (harness-ui-usage-history--action (nth 1 p) command (nth 2 p)
                                                       (eq period harness-ui-usage-history--period))
                      (if (eq period harness-ui-usage-history--period) 95 45) nil command)))
            harness-ui-usage-history--periods)
    (mapcar (lambda (g)
              (let* ((group (car g))
                     (command (lambda () (interactive) (harness-ui-usage-history-set-group group))))
                (list (harness-ui-usage-history--action (nth 1 g) command (nth 2 g)
                                                       (eq group harness-ui-usage-history--group))
                      (if (eq group harness-ui-usage-history--group) 85 40) nil command)))
            harness-ui-usage-history--groups)
    (when harness-ui-usage-history--selected
      (list (list (harness-ui-usage-history--action "Back" #'harness-ui-usage-history-back "All groups")
                  95 nil #'harness-ui-usage-history-back)))
    (list (list (harness-ui-usage-history--action "Help" #'harness-ui-usage-history-help "Accounting and coverage help")
                90 nil #'harness-ui-usage-history-help)
          (list (harness-ui-usage-history--action "Refresh" #'harness-ui-usage-history-refresh "Usage refresh")
                75 nil #'harness-ui-usage-history-refresh)
          (list (harness-ui-usage-history--action "Close" #'harness-ui-quit-view "View closure")
                90 nil #'harness-ui-quit-view)))
   width t))

(defun harness-ui-usage-history--room ()
  "Return the content width of the narrowest window showing this view."
  (max 20 (- (let ((windows (get-buffer-window-list nil nil t)))
               (if windows (apply #'min (mapcar #'window-body-width windows)) (window-body-width))) 2)))

(defun harness-ui-usage-history--line (text &optional face help)
  "Insert TEXT fitted to the window, with FACE and one-line HELP."
  (let ((text (truncate-string-to-width text (harness-ui-usage-history--room) nil nil "…")))
    (when face (setq text (propertize text 'face face)))
    (when help (setq text (propertize text 'help-echo (harness-ui-one-line help))))
    (insert " " text "\n")))

(defun harness-ui-usage-history--retry-line ()
  "Insert the line under a failure that offers [Retry].
Its own line, not `harness-ui-usage-history--line': the button keeps
its width however narrow the window is."
  (insert " " (harness-ui-retry #'harness-ui-usage-history-refresh "Load the history again") "\n"))

(defun harness-ui-usage-history--heading (text)
  "Insert section heading TEXT."
  (insert "\n")
  (harness-ui-usage-history--line text 'harness-usage-heading-face))

(defun harness-ui-usage-history--number (n)
  "Format known token count N without rounding, or an unknown state."
  (if (numberp n) (format "%.0f" n) "Unknown"))

(defun harness-ui-usage-history--money (n)
  "Format known USD amount N, or an unknown state."
  (cond ((not (numberp n)) "Unknown")
        ((and (> n 0) (< n 0.000001)) (format "%.6g" n))
        (t (let ((s (format "%.6f" n)))
             (replace-regexp-in-string "\\.?0+\\'" "" s)))))

(defun harness-ui-usage-history--share (n)
  "Format a known fraction N, or an unknown state."
  (if (numberp n) (format "%.1f%%" (* 100 n)) "Unknown"))

(defun harness-ui-usage-history--state (category)
  "Return the coverage qualifier of CATEGORY."
  (pcase (plist-get category :state)
    ("complete" (if (< (or (plist-get category :priced) 0) (or (plist-get category :known) 0)) "Partial" "Complete"))
    ("partial" "Partial") ("not-reported" "Not reported") (_ "Unknown")))

(defun harness-ui-usage-history--category (category wide)
  "Insert CATEGORY, in a table when WIDE, with exact coverage otherwise."
  (let* ((label (cdr (assoc (plist-get category :key) harness-ui-usage-history--labels)))
         (unavailable (equal (plist-get category :state) "not-reported"))
         (tokens (if unavailable "Not reported" (harness-ui-usage-history--number (plist-get category :tokens))))
         (cost (if unavailable "Not reported" (harness-ui-usage-history--money (plist-get category :cost))))
         (token-share (if unavailable "Not reported" (harness-ui-usage-history--share (plist-get category :token-share))))
         (cost-share (if unavailable "Not reported" (harness-ui-usage-history--share (plist-get category :cost-share))))
         (records (format "%d/%d" (or (plist-get category :known) 0) (or (plist-get category :records) 0)))
         (state (harness-ui-usage-history--state category))
         (cell (lambda (text help) (propertize text 'help-echo help))))
    (if wide
        (harness-ui-usage-history--line
         (concat (format "%-16s" label)
                 (funcall cell (format "%14s" tokens) "Known disjoint category tokens")
                 (funcall cell (format "%14s" token-share) "Share of known category tokens")
                 (funcall cell (format "%20s" cost) "Token-count × rate estimate · not an invoice allocation")
                 (funcall cell (format "%14s" cost-share) "Share of known reconstructed USD")
                 (funcall cell (format "%10s" records) "Known records / selected records")
                 (format "  %s" state)))
      (harness-ui-usage-history--line (format "%s · %s · %s records" label state records) 'bold)
      (harness-ui-usage-history--line (format "  Tokens %s · %s" tokens token-share) nil "Share of known category tokens")
      (harness-ui-usage-history--line (format "  Reconstructed USD %s · %s" cost cost-share) nil "Share of known reconstructed USD"))))

(defun harness-ui-usage-history--categories (aggregate)
  "Insert token and monetary contributions of AGGREGATE."
  (let ((wide (>= (harness-ui-usage-history--room) 112)))
    (harness-ui-usage-history--heading "Token categories")
    (harness-ui-usage-history--line
     (format "Known category tokens %s" (harness-ui-usage-history--number (plist-get aggregate :token-denominator)))
     'harness-dim-face "Known disjoint category tokens")
    (harness-ui-usage-history--line
     (format "Known reconstructed USD %s" (harness-ui-usage-history--money (plist-get aggregate :money-denominator)))
     'harness-dim-face "Token-count × rate estimate · not an invoice allocation")
    (when wide
      (harness-ui-usage-history--line
       (format "%-16s%14s%14s%20s%14s%10s  %s" "" "Tokens" "Token share" "Reconstructed USD" "Spend share" "Records" "Coverage")
       'harness-usage-table-header-face))
    (dolist (category (plist-get aggregate :categories))
      (harness-ui-usage-history--category category wide))))

(defun harness-ui-usage-history--spending (aggregate)
  "Insert non-allocated billed amounts and the empirical cohort of AGGREGATE."
  (harness-ui-usage-history--heading "Spending")
  (harness-ui-usage-history--line
   (format "Observed billed USD %s · %d/%d records"
           (harness-ui-usage-history--money (plist-get aggregate :observed-cost))
           (or (plist-get aggregate :observed-records) 0) (or (plist-get aggregate :records) 0)))
  (when (numberp (plist-get aggregate :recorded-unknown))
    (harness-ui-usage-history--line
     (format "Recorded USD · origin unknown %s" (harness-ui-usage-history--money (plist-get aggregate :recorded-unknown)))))
  (harness-ui-usage-history--line (format "Plan-covered records %d" (or (plist-get aggregate :plan-records) 0)))
  (let* ((cohort (plist-get aggregate :cohort))
         (verdict (pcase (plist-get cohort :verdict)
                    ("majority" "Cache-read majority") ("not-majority" "No cache-read majority") (_ "No comparable spending"))))
    (harness-ui-usage-history--line verdict 'harness-usage-heading-face)
    (harness-ui-usage-history--line "Reconstructed spending · comparable records" 'harness-dim-face)
    (harness-ui-usage-history--line
     (format "Comparable records %d/%d · USD %s"
             (or (plist-get cohort :records) 0) (or (plist-get aggregate :records) 0)
             (harness-ui-usage-history--money (plist-get cohort :cost))))
    (harness-ui-usage-history--line
     (format "Cache read · USD %s · %s" (harness-ui-usage-history--money (plist-get cohort :cache-read-cost))
             (harness-ui-usage-history--share (plist-get cohort :share))))))

(defun harness-ui-usage-history--coverage (aggregate report)
  "Insert record coverage of AGGREGATE and source gaps from REPORT."
  (let* ((coverage (plist-get report :coverage))
         (records (or (plist-get aggregate :records) 0))
         (complete (or (plist-get aggregate :complete-records) 0)))
    (harness-ui-usage-history--heading "Coverage")
    (harness-ui-usage-history--line
     (if (or (< complete records) (plist-get coverage :gaps) (> (or (plist-get aggregate :legacy-records) 0) 0))
         "Historical coverage · partial" "Historical coverage · recorded metadata")
     'harness-dim-face)
    (harness-ui-usage-history--line (format "Complete %d/%d records · Ledger records %d · Log records %d"
                                            complete records (or (plist-get aggregate :ledger-records) 0)
                                            (or (plist-get aggregate :log-records) 0)))
    (when (numberp (plist-get aggregate :unclassified-input))
      (harness-ui-usage-history--line (format "Unclassified input %s" (harness-ui-usage-history--number (plist-get aggregate :unclassified-input)))))
    (harness-ui-usage-history--line
     (format "Overlap exclusions %d · Duplicate exclusions %d"
             (or (plist-get coverage :overlap) 0)
             (+ (or (plist-get coverage :duplicates) 0) (or (plist-get coverage :duplicate-samples) 0))))
    (when (plist-member coverage :ledger-session-exclusions)
      (harness-ui-usage-history--line (format "Ledger-precedence sessions %d" (plist-get coverage :ledger-session-exclusions))))
    (when (plist-member coverage :files-requested)
      (harness-ui-usage-history--line
       (format "Metadata files %d/%d · Missing %d · Unreadable %d"
               (or (plist-get coverage :files-read) 0) (plist-get coverage :files-requested)
               (or (plist-get coverage :files-missing) 0) (or (plist-get coverage :files-unreadable) 0)))
      (harness-ui-usage-history--line
       (format "Ambiguous records %d · Undated records %d"
               (or (plist-get coverage :ambiguous-samples) 0)
               (+ (or (plist-get coverage :undated-samples) 0) (or (plist-get coverage :undated) 0)))))
    (when (plist-get coverage :gaps)
      (let ((text (format "Source gaps %s" (string-join (mapcar (lambda (s) (format "%s" s)) (plist-get coverage :gaps)) ", "))))
        (harness-ui-usage-history--line text 'harness-caution-face text)))
    (insert " ")
    (insert-text-button "Help" 'action (lambda (_) (harness-ui-usage-history-help))
                        'follow-link t 'help-echo "Accounting and coverage help")
    (insert "\n")))

(defun harness-ui-usage-history--prices (aggregate)
  "Insert the price matrix applied to AGGREGATE's actual workload."
  (harness-ui-usage-history--heading "Pricing matrix")
  (if (not (plist-get aggregate :prices))
      (harness-ui-usage-history--line "No price evidence" 'harness-dim-face)
    (dolist (row (plist-get aggregate :prices))
      (harness-ui-usage-history--line
       (format "%s · %s · Records %d" (or (plist-get row :model) "Unknown")
               (if (equal (plist-get row :source) "snapshot") "Snapshot" "Catalogue estimate")
               (plist-get row :records)) 'bold)
      (harness-ui-usage-history--line
       (format "  Rates · %s / million tokens" (or (plist-get row :currency) "Unknown")) 'harness-dim-face)
      (when (numberp (plist-get row :price-since))
        (harness-ui-usage-history--line
         (format "  Price date %s — %s"
                 (or (plist-get row :price-since-label) (format-time-string "%Y-%m-%d %H:%M" (plist-get row :price-since)))
                 (or (plist-get row :price-until-label) (format-time-string "%Y-%m-%d %H:%M" (plist-get row :price-until)))) 'harness-dim-face))
      (dolist (category (plist-get row :categories))
        (let* ((key (plist-get category :key))
               (rate (plist-get (plist-get row :pricing) (intern (concat ":" key)))))
          (let ((text (if (plist-get category :unavailable)
                          (format "  %-14s Not reported" (cdr (assoc key harness-ui-usage-history--labels)))
                        (format "  %-14s %s · %s tokens · USD %s · %d/%d records"
                                (cdr (assoc key harness-ui-usage-history--labels))
                                (harness-ui-usage-history--money rate)
                                (harness-ui-usage-history--number (plist-get category :tokens))
                                (harness-ui-usage-history--money (plist-get category :cost))
                                (or (plist-get category :known) 0) (or (plist-get category :records) 0)))))
            (harness-ui-usage-history--line text nil text)))))))

(defun harness-ui-usage-history--scope-label (key)
  "Return a fitted label for scope KEY with distinguishable directory ends."
  (cond ((equal key "") "Unknown")
        ((memq harness-ui-usage-history--group '(project workspace))
         (harness-truncate-middle (abbreviate-file-name key) (harness-ui-usage-history--room)))
        (t key)))

(defun harness-ui-usage-history--group-at-point ()
  "Return the aggregate key on the current line."
  (get-text-property (line-beginning-position) 'harness-history-group))

(defun harness-ui-usage-history--insert-groups (groups)
  "Insert navigable summary rows for GROUPS."
  (harness-ui-usage-history--heading "Groups")
  (if (null groups) (harness-ui-usage-history--line "No groups" 'harness-dim-face)
    (dolist (row groups)
      (let ((start (point)) (key (plist-get row :key)))
        (harness-ui-usage-history--line (harness-ui-usage-history--scope-label key) 'harness-label-face key)
        (harness-ui-usage-history--line
         (format "  Records %d · %s tokens · Reconstructed USD %s"
                 (plist-get row :records) (harness-ui-usage-history--number (plist-get row :token-denominator))
                 (harness-ui-usage-history--money (plist-get row :money-denominator))))
        (add-text-properties start (point)
                             (list 'harness-history-group key 'mouse-face 'highlight
                                   'help-echo (harness-ui-one-line (format "Historical token mix and spend · %s" key))
                                   'keymap (let ((map (make-sparse-keymap)))
                                             (define-key map [mouse-1] #'harness-ui-usage-history-mouse-open)
                                             (define-key map (kbd "RET") #'harness-ui-usage-history-open) map)))))))

(defun harness-ui-usage-history--render ()
  "Draw the current report, keeping the user's buffer position."
  (let ((inhibit-read-only t) (line (line-number-at-pos))
        (report harness-ui-usage-history--data))
    (erase-buffer)
    (setq header-line-format '(:eval (harness-ui-usage-history--header)))
    (harness-ui-usage-history--heading "Historical token mix")
    (cond
     (harness-ui-usage-history--loading (harness-ui-usage-history--line "Loading history…" 'harness-dim-face))
     (harness-ui-usage-history--error
      (harness-ui-usage-history--line "History unavailable" 'harness-failure-face)
      (harness-ui-usage-history--retry-line)
      (harness-ui-usage-history--line harness-ui-usage-history--error 'harness-dim-face))
     (report
      (let ((aggregate (if harness-ui-usage-history--selected
                           (or (cl-find harness-ui-usage-history--selected (plist-get report :groups)
                                        :key (lambda (r) (plist-get r :key)) :test #'equal)
                               (list :key harness-ui-usage-history--selected :records 0))
                         (plist-get report :totals))))
        (harness-ui-usage-history--line
         (format "Period %s — %s · Local time %s"
                 (or (plist-get report :since-label)
                     (if (plist-get report :since) (format-time-string "%Y-%m-%d %H:%M" (plist-get report :since)) "All"))
                 (or (plist-get report :until-label)
                     (if (plist-get report :until) (format-time-string "%Y-%m-%d %H:%M" (plist-get report :until)) "Unknown"))
                 (or (plist-get report :timezone) "Unknown")) 'harness-dim-face)
        (when harness-ui-usage-history--selected
          (harness-ui-usage-history--line (harness-ui-usage-history--scope-label harness-ui-usage-history--selected)
                                           'bold harness-ui-usage-history--selected))
        (if (zerop (or (plist-get aggregate :records) 0))
            (progn (harness-ui-usage-history--heading "No historical usage")
                   (harness-ui-usage-history--coverage aggregate report))
          (harness-ui-usage-history--categories aggregate)
          (harness-ui-usage-history--spending aggregate)
          (harness-ui-usage-history--coverage aggregate report)
          (unless (or harness-ui-usage-history--selected (eq harness-ui-usage-history--group 'overall))
            (harness-ui-usage-history--insert-groups (plist-get report :groups)))
          (harness-ui-usage-history--prices aggregate))))
     (t (harness-ui-usage-history--line "No historical usage" 'harness-dim-face)))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun harness-ui-usage-history--load (buffer)
  "Load BUFFER's report asynchronously, ignoring superseded responses."
  (with-current-buffer buffer
    (let ((generation (cl-incf harness-ui-usage-history--generation))
          (params (list :group-by (symbol-name harness-ui-usage-history--group)
                        :period (symbol-name harness-ui-usage-history--period))))
      (setq harness-ui-usage-history--loading t harness-ui-usage-history--error nil)
      (harness-ui-usage-history--render)
      (harness-ui-call
       "_harness/usage/history" params
       (lambda (report)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= generation harness-ui-usage-history--generation)
               (setq harness-ui-usage-history--loading nil harness-ui-usage-history--data report)
               (harness-ui-usage-history--render)))))
       (lambda (err)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= generation harness-ui-usage-history--generation)
               (setq harness-ui-usage-history--loading nil harness-ui-usage-history--data nil
                     harness-ui-usage-history--error (harness-error-message err))
               (harness-ui-usage-history--render)))))))))

;;;###autoload
(defun harness-usage-history ()
  "Show historical token mix and monetary evidence, without a model call."
  (interactive)
  (let* ((period (if (derived-mode-p 'harness-ui-usage-mode) harness-ui-usage--period
                   harness-ui-usage-default-period))
         (buffer (get-buffer-create harness-ui-usage-history--buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-usage-history-mode) (harness-ui-usage-history-mode))
      (setq harness-ui-usage-history--period period))
    (harness-ui-display-view buffer)
    (harness-ui-usage-history--load buffer)))

(defun harness-ui-usage-history-set-period (period)
  "Select PERIOD and refresh the report."
  (unless (assq period harness-ui-usage-history--periods) (user-error "Unknown history period"))
  (setq harness-ui-usage-history--period period)
  (harness-ui-usage-history--load (current-buffer)))

(defun harness-ui-usage-history-set-group (group)
  "Select GROUP and refresh its aggregate rows."
  (unless (assq group harness-ui-usage-history--groups) (user-error "Unknown history grouping"))
  (setq harness-ui-usage-history--group group harness-ui-usage-history--selected nil)
  (harness-ui-usage-history--load (current-buffer)))

(defun harness-ui-usage-history-cycle-period ()
  "Select the next historical period."
  (interactive)
  (harness-ui-usage-history-set-period
   (or (cadr (memq harness-ui-usage-history--period (mapcar #'car harness-ui-usage-history--periods))) 'today)))

(defun harness-ui-usage-history-cycle-group ()
  "Select the next historical grouping."
  (interactive)
  (harness-ui-usage-history-set-group
   (or (cadr (memq harness-ui-usage-history--group (mapcar #'car harness-ui-usage-history--groups))) 'overall)))

(defun harness-ui-usage-history-refresh ()
  "Refresh historical usage evidence."
  (interactive)
  (harness-ui-usage-history--load (current-buffer)))

(defun harness-ui-usage-history-open ()
  "Show category and pricing details for the group at point."
  (interactive)
  (let ((key (harness-ui-usage-history--group-at-point)))
    (unless key (user-error "No group at point"))
    (setq harness-ui-usage-history--selected key)
    (goto-char (point-min))
    (harness-ui-usage-history--render)))

(defun harness-ui-usage-history-mouse-open (event)
  "Show the historical group clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (harness-ui-usage-history-open))

(defun harness-ui-usage-history-back ()
  "Return to the totals and all groups."
  (interactive)
  (setq harness-ui-usage-history--selected nil)
  (goto-char (point-min))
  (harness-ui-usage-history--render))

(defun harness-ui-usage-history-help ()
  "Show explicit accounting and coverage explanations."
  (interactive)
  (with-help-window "*harness token mix help*"
    (princ "Accounting and coverage help\n\n")
    (princ "Sources and confidence\nThe usage ledger wins over session-log reconstructions for the same session. Logs supplement sessions without ledger rows; they do not fill arbitrary holes inside an overlapping session. Duplicate identities, inherited fork nodes, replaced nodes and repeated snapshots are excluded. Missing files, ambiguous snapshots and malformed records reduce coverage. A missing day is not a zero-spend day. Session lifetime totals are never spread over days. Coverage counts records, which may be calls or hosted-provider turn totals, not a guaranteed count of all provider requests. Complete records have a disjoint available token partition; source, price or workspace gaps can still remain.\n\n")
    (princ "Tokens and percentages\nInclusive input subtracts reported cached tokens once; exclusive input already excludes them. Unknown cache portions leave input unclassified. Not reported means a provider offers no separate write counter: any inseparable writes remain in non-read input. Unknown means insufficient evidence, not zero. Partial means a known subtotal with missing observations, even when that subtotal is zero. Legacy ledger zeros were synthesized for missing counters and cannot establish zero use. Token shares divide by the displayed sum of known, disjoint category tokens, not by all historical tokens or the current conversation's prompt.\n\n")
    (princ "Prices and money\nObserved billed USD contains only provider-reported amounts with supported provenance. Recorded USD with unknown origin may include estimates. Neither is allocated to categories. Reconstructed amounts multiply category tokens by USD-per-million rates; they are not invoice contributions. Snapshot means rates saved with the record. Catalogue estimate means the locally available model catalogue, evaluated at the record's timestamp (including time-sensitive rate functions), not a historical price archive. The matrix identifies rate sources and evaluation dates. Missing prices stay unknown. Spend shares divide by the displayed known reconstructed USD, potentially a partial subtotal. API-equivalent values of subscription records are estimates, not plan spending.\n\n")
    (princ "Cache-read finding\nThe majority finding uses only fully partitioned and fully priced records explicitly billed as API or extra usage. Separate writes unavailable from the provider do not become zero observations; their inseparable input remains in that provider's non-read category. Cache-read cost greater than half the comparable reconstructed USD is a majority. The displayed cohort and denominator limit this finding: incomplete history or pricing cannot establish the mix of all recurring invoices.\n\n")
    (princ "Scope and privacy\nProjects fold recorded workspaces under their owning checkout. Workspace means the recorded working-directory root; day means the harness's local calendar day. Reconstructed log events without a workspace stamp stay unattributed unless a worktree session's scope cannot move. A session's current directory does not rewrite past usage. Periods include their start and exclude their end. Source-gap diagnostics describe the whole scan, even inside a selected group. Only usage metadata is reconstructed locally. No prompts, responses, session names, tool inputs or credentials appear in aggregate responses, and this view makes no model call.\n")
    (with-current-buffer standard-output (visual-line-mode 1))))

(defvar harness-ui-usage-history-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-view-map)
    (define-key map (kbd "g") #'harness-ui-usage-history-refresh)
    (define-key map (kbd "t") #'harness-ui-usage-history-cycle-period)
    (define-key map (kbd "b") #'harness-ui-usage-history-cycle-group)
    (define-key map (kbd "RET") #'harness-ui-usage-history-open)
    (define-key map (kbd "l") #'harness-ui-usage-history-back)
    (define-key map (kbd "h") #'harness-ui-usage-history-help)
    (define-key map (kbd "u") #'harness-usage)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "?") #'harness-ui-menu)
    map))

(define-derived-mode harness-ui-usage-history-mode special-mode "Token mix"
  "Historical token and price evidence, through ACP only."
  (setq truncate-lines t)
  (add-hook 'window-configuration-change-hook #'harness-ui-usage-history--resize nil t))

(put 'harness-ui-usage-history-mode 'harness-menu-group
     '("Token mix"
       ["View" (". t" "Next period" harness-ui-usage-history-cycle-period)
        (". b" "Grouping" harness-ui-usage-history-cycle-group)
        (". RET" "Group details" harness-ui-usage-history-open)
        (". l" "All groups" harness-ui-usage-history-back)
        (". g" "Refresh" harness-ui-usage-history-refresh)
        (". h" "Accounting help" harness-ui-usage-history-help)
        (". u" "Usage" harness-usage)]))

(defun harness-ui-usage-history--resize (&rest _)
  "Redraw responsive historical rows after a window resize."
  (when (derived-mode-p 'harness-ui-usage-history-mode) (harness-ui-usage-history--render)))

(defun harness-ui-usage-history--redraw ()
  "Reload an existing historical view after reconnect or code reload."
  (when-let* ((buffer (get-buffer harness-ui-usage-history--buffer)))
    (harness-ui-usage-history--load buffer)))

(defun harness-ui-usage-history--event (event _args)
  "Refresh after EVENT changes recorded history."
  (when (and (equal event "agent/turn-ended") (get-buffer harness-ui-usage-history--buffer))
    (harness-debounce 'harness-ui-usage-history 1 #'harness-ui-usage-history--redraw)))

(defun harness-ui-usage-history--init ()
  "Wire historical navigation and refresh into the UI."
  (add-hook 'harness-ui-redraw-hook #'harness-ui-usage-history--redraw)
  (add-hook 'harness-ui-event-functions #'harness-ui-usage-history--event))

(harness-define-module 'ui-usage-history
  :doc "Historical token mix, spend contributions, pricing evidence and coverage."
  :requires '(ui-usage)
  :init #'harness-ui-usage-history--init)

(provide 'harness-ui-usage-history)
;;; harness-ui-usage-history.el ends here
