;;; harness-ui-usage.el --- Usage and cost overview -*- lexical-binding: t; -*-

;; This file is part of Emacs Agent Harness.

;;; Commentary:

;; A full-window report of token and cost usage.  It shows totals, spend
;; for the day/week/month, budgets with graphical bars, breakdowns by
;; project and model, and a sortable table of every session.  All data
;; arrives over ACP (`_harness/usage/summary'); this module never reads
;; session storage directly.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)
(require 'harness-core)
(require 'harness-ui)

(defgroup harness-ui-usage nil
  "Harness usage overview."
  :group 'harness-ui)

(defcustom harness-ui-usage-bar-width 24
  "Width in characters of the usage bars."
  :type 'natnum)

(defface harness-ui-usage-bar-face
  '((t :inherit success))
  "Face for the filled part of a usage bar."
  :group 'harness-ui-usage)

(defface harness-ui-usage-bar-warning-face
  '((t :inherit warning))
  "Face for a usage bar close to its limit."
  :group 'harness-ui-usage)

(defface harness-ui-usage-bar-full-face
  '((t :inherit error))
  "Face for a usage bar over its limit."
  :group 'harness-ui-usage)

(defface harness-ui-usage-bar-track-face
  '((t :inherit shadow))
  "Face for the empty part of a usage bar."
  :group 'harness-ui-usage)

(defface harness-ui-usage-heading-face
  '((t :inherit bold :height 1.1))
  "Face for section headings in the report."
  :group 'harness-ui-usage)

(defvar-local harness-ui-usage--data nil
  "Last summary plist shown in this buffer.")

(defvar harness-ui-usage-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "g") #'harness-ui-usage-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `harness-ui-usage-mode'.")

;;; Formatting

(defun harness-ui-usage--money (amount &optional currency)
  "Format AMOUNT in CURRENCY."
  (let ((amount (or amount 0)))
    (format (if (< (abs amount) 0.01) "$%.4f" "$%.2f")
            amount)))

(defun harness-ui-usage--tokens (count)
  "Format token COUNT compactly."
  (let ((count (or count 0)))
    (cond ((>= count 1000000) (format "%.1fM" (/ count 1000000.0)))
          ((>= count 1000) (format "%.1fk" (/ count 1000.0)))
          (t (number-to-string count)))))

(defun harness-ui-usage--bar (fraction &optional width)
  "Insert a graphical bar for FRACTION (0-1+).
The fill takes its colour from the theme's success/warning/error faces,
so the bar follows any theme without hardcoded colours."
  (let* ((width (or width harness-ui-usage-bar-width))
         (filled (max 0 (min width (round (* fraction width)))))
         (severity (cond ((> fraction 1.0) 'error)
                         ((> fraction 0.8) 'warning)
                         (t 'success)))
         (fill-color (face-attribute severity :foreground nil t))
         (track-color (face-attribute 'secondary-selection :background nil t)))
    (insert (propertize (make-string filled ?\s)
                        'face (list :background fill-color :extend nil)))
    (insert (propertize (make-string (- width filled) ?\s)
                        'face (list :background track-color :extend nil)))))

(defun harness-ui-usage--row (label value &optional bar-fraction)
  "Insert a label/value row, optionally with BAR-FRACTION."
  (insert (propertize (format "  %-22s" label) 'face 'shadow))
  (when bar-fraction
    (harness-ui-usage--bar bar-fraction)
    (insert "  "))
  (insert (format "%s\n" value)))

(defun harness-ui-usage--insert-summary (totals periods)
  "Insert the totals and period spend of TOTALS and PERIODS."
  (insert (propertize "Usage\n" 'face 'harness-ui-usage-heading-face))
  (harness-ui-usage--row "sessions" (format "%d" (or (plist-get totals :sessions) 0)))
  (harness-ui-usage--row "input tokens" (harness-ui-usage--tokens (plist-get totals :input)))
  (harness-ui-usage--row "output tokens" (harness-ui-usage--tokens (plist-get totals :output)))
  (harness-ui-usage--row "cache read" (harness-ui-usage--tokens (plist-get totals :cache-read)))
  (let ((cost (plist-get totals :cost)))
    (harness-ui-usage--row "cost" (harness-ui-usage--money (plist-get cost :amount)
                                                           (plist-get cost :currency))))
  (insert "\n")
  (insert (propertize "Spend\n" 'face 'harness-ui-usage-heading-face))
  (dolist (period periods)
    (harness-ui-usage--row (format "%s" (plist-get period :period))
                           (harness-ui-usage--money (plist-get period :spent)))))

(defun harness-ui-usage--insert-budgets (budgets)
  "Insert the budget section for BUDGETS."
  (when budgets
    (insert "\n" (propertize "Budgets\n" 'face 'harness-ui-usage-heading-face))
    (dolist (budget budgets)
      (let* ((amount (or (plist-get budget :amount) 0))
             (spent (or (plist-get budget :spent) 0))
             (fraction (if (> amount 0) (/ spent amount) 0)))
        (insert (propertize (format "  %-22s" (plist-get budget :label))
                            'face (if (plist-get budget :over) 'error 'shadow)))
        (harness-ui-usage--bar fraction)
        (insert (format "  %s of %s%s\n"
                        (harness-ui-usage--money spent (plist-get budget :currency))
                        (harness-ui-usage--money amount (plist-get budget :currency))
                        (if (plist-get budget :hard) "  (hard)" "")))))))

(defun harness-ui-usage--insert-breakdown (heading rows)
  "Insert a breakdown HEADING with ROWS."
  (insert "\n" (propertize (format "%s\n" heading) 'face 'harness-ui-usage-heading-face))
  (if (null rows)
      (insert (propertize "  none yet\n" 'face 'shadow))
    (let ((max-cost (max 0.000001
                         (cl-loop for row in rows
                                  maximize (plist-get (plist-get row :cost) :amount)))))
      (dolist (row rows)
        (let* ((cost (plist-get row :cost))
               (amount (or (plist-get cost :amount) 0)))
          (insert (propertize (format "  %-30s" (truncate-string-to-width
                                                 (format "%s" (plist-get row :key))
                                                 30 nil nil "…"))
                              'face 'default))
          (harness-ui-usage--bar (/ amount max-cost) 16)
          (insert (format "  %8s  %s in / %s out\n"
                          (harness-ui-usage--money amount)
                          (harness-ui-usage--tokens (plist-get row :input))
                          (harness-ui-usage--tokens (plist-get row :output)))))))))

;;; Session table

(defun harness-ui-usage--session-entries (sessions)
  "Build tabulated-list entries for SESSIONS, costliest first."
  (mapcar
   (lambda (session)
     (let* ((usage (plist-get session :usage))
            (cost (plist-get session :cost))
            (id (or (plist-get session :sessionId) ""))
            (project (or (plist-get session :projectRoot) "")))
       (list id
             (vector (or (plist-get session :title)
                         (substring id 0 8))
                     (if (> (length project) 24)
                         (concat "…" (substring project (- (length project) 23)))
                       project)
                     (or (plist-get session :model) "")
                     (harness-ui-usage--tokens (plist-get usage :input))
                     (harness-ui-usage--tokens (plist-get usage :output))
                     (harness-ui-usage--money (plist-get cost :amount))
                     (format-time-string "%m-%d %H:%M"
                                         (seconds-to-time (or (plist-get session :updatedEpoch) 0)))))))
   (sort sessions
         (lambda (a b)
           (> (or (plist-get (plist-get a :cost) :amount) 0)
              (or (plist-get (plist-get b :cost) :amount) 0))))))

(define-derived-mode harness-ui-usage-mode tabulated-list-mode "Harness-Usage"
  "Major mode for the harness usage report."
  :group 'harness-ui-usage
  (setq-local truncate-lines t)
  (setq tabulated-list-format [("Session" 34 t)
                               ("Project" 24 t)
                               ("Model" 22 t)
                               ("In" 7 t)
                               ("Out" 7 t)
                               ("Cost" 8 t)
                               ("Updated" 12 t)])
  (setq tabulated-list-sort-key '("Cost" . t))
  (add-hook 'tabulated-list-revert-hook #'harness-ui-usage-refresh nil t))

(defun harness-ui-usage-refresh ()
  "Fetch the usage summary and redraw the report."
  (interactive)
  (let ((buffer (current-buffer)))
    (harness-deferred-then
     (harness-ui-request "_harness/usage/summary" (list))
     (lambda (data)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (setq harness-ui-usage--data data)
           (harness-ui-usage--render data))))
     (lambda (error)
       (message "Usage summary failed: %S" error)))))

(defun harness-ui-usage--render (data)
  "Render usage DATA in the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Harness usage\n\n" 'face 'harness-ui-usage-heading-face))
    (harness-ui-usage--insert-summary (plist-get data :totals)
                                      (plist-get data :periods))
    (harness-ui-usage--insert-budgets (plist-get data :budgets))
    (harness-ui-usage--insert-breakdown "By project" (plist-get data :projects))
    (harness-ui-usage--insert-breakdown "By model" (plist-get data :models))
    (insert "\n" (propertize "Sessions\n" 'face 'harness-ui-usage-heading-face))
    (let ((sessions (append (plist-get data :sessions) nil)))
      (setq tabulated-list-entries
            (harness-ui-usage--session-entries sessions))
      ;; `tabulated-list-print' would erase the report above, so write the
      ;; column header and rows ourselves with the same format.
      (insert (mapconcat (lambda (column)
                           (format (format "%%-%ds" (cadr column)) (car column)))
                         tabulated-list-format
                         "  ")
              "\n")
      (dolist (entry tabulated-list-entries)
        (tabulated-list-print-entry (car entry) (cadr entry)))
      (goto-char (point-min)))
    (harness-ui-usage--mark-read-only)))

(defun harness-ui-usage--mark-read-only ()
  "Mark the report read-only except the session table."
  (let ((inhibit-read-only t)
        (table-start (save-excursion
                       (goto-char (point-min))
                       (when (search-forward "Sessions\n" nil t)
                         (line-beginning-position)))))
    (when table-start
      (add-text-properties (point-min) table-start
                           '(read-only t front-sticky t rear-nonsticky t)))))

;;;###autoload
(defun harness-ui-usage ()
  "Open the usage and cost overview."
  (interactive)
  (let ((buffer (get-buffer-create "*harness-usage*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-usage-mode)
        (harness-ui-usage-mode))
      (harness-ui-usage-refresh))
    (switch-to-buffer buffer)
    buffer))

;;; The chat header can open the report.

(defun harness-ui-usage-open-from-chat ()
  "Open the usage report."
  (interactive)
  (harness-ui-usage))

(defun harness-ui-usage-setup ()
  "Set up the usage overview UI."
  (harness-on 'harness-ui-refresh-functions
              (lambda ()
                (when (get-buffer "*harness-usage*")
                  (with-current-buffer "*harness-usage*"
                    (harness-ui-usage-refresh))))
              :module 'harness-ui-usage))

(defun harness-ui-usage-teardown ()
  "Tear down the usage overview UI."
  (puthash 'harness-ui-refresh-functions
           (seq-remove (lambda (handler)
                         (eq (harness-event-handler-module handler) 'harness-ui-usage))
                       (gethash 'harness-ui-refresh-functions harness-core--event-handlers))
           harness-core--event-handlers))

(harness-module-define 'harness-ui-usage
  :version harness-version
  :description "Usage and cost overview buffer."
  :requires '((harness-core "0.1.0")
              (harness-ui "0.1.0"))
  :provides '(harness-ui-usage)
  :setup #'harness-ui-usage-setup
  :teardown #'harness-ui-usage-teardown)

(provide 'harness-ui-usage)
;;; harness-ui-usage.el ends here
