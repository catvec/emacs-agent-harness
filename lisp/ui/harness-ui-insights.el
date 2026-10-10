;;; harness-ui-insights.el --- The Insights report  -*- lexical-binding: t; -*-

;;; Commentary:

;; One buffer, "*harness insights*" (M-x harness-insights, A in the
;; harness keys and menu): how a period of work with the agents went,
;; as Claude Code's /insights has it, but drawn from the harness's own
;; records, so it reads the same whatever the provider.  Top to bottom:
;;
;;   header line   the period [Today] [7 days] [30 days] [All] -- the
;;                 usage dashboard's periods, so the usage figures are
;;                 the dashboard's -- and the scope, every project or one
;;   totals strip  sessions, messages you wrote, active time, cost, tool
;;                 calls and tasks done
;;   summary       what a model of your provider wrote from the figures:
;;                 the gist, what you worked on, how you work, where
;;                 things went wrong and what to try next; n writes it
;;                 again (see `harness-insights-narrative')
;;   activity      the messages you wrote by hour of day and by weekday,
;;                 the days you worked and your streaks
;;   usage         the dashboard's cost chart, then cost by model and by
;;                 provider, with share meters
;;   projects      each project's sessions, time and cost (every project)
;;   sessions      the sessions that worked, by kind, and the busiest
;;   tools         calls of each tool, how many failed or were denied,
;;                 and the time they took
;;   permissions   how often you were asked and what you answered
;;   tasks         submitted, done, merged, sent back, failed, merge
;;                 conflicts, the board now, and the tasks worth a look
;;
;; RET (or a click) on a session or task line opens its session; t
;; cycles the period, p narrows the report to a project, g computes it
;; again.  The report is computed in the harness process, whose child
;; Emacs reads the transcripts: this Emacs only asks for it and draws
;; it, and shows a placeholder until it arrives.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'svg)
(require 'button)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-usage)

(defgroup harness-ui-insights nil
  "The Insights report." :group 'harness-ui)

(defconst harness-ui-insights--buffer-name "*harness insights*"
  "Name of the report buffer.")

(defcustom harness-ui-insights-default-period '30d
  "Period the report covers when it opens: `today', `7d', `30d' or `all'.
They are the usage dashboard's periods, so the report's usage figures
are the dashboard's for the same period."
  :type '(choice (const today) (const 7d) (const 30d) (const all))
  :group 'harness-ui-insights)

(defcustom harness-ui-insights-default-scope 'all
  "Projects the report covers when it opens.
`all' covers every project; `current' the project of the session or
directory it is opened from, with its git worktrees.  p in the report
changes it."
  :type '(choice (const :tag "Every project" all) (const :tag "The current project" current))
  :group 'harness-ui-insights)

(defconst harness-ui-insights--activity-height 92
  "Pixel height of the activity charts.")

(defconst harness-ui-insights--weekdays '("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun")
  "Weekday labels, in the order of the report's weekday counts.")

(defconst harness-ui-insights--kind-labels
  '(("main" "chat" "chats") ("task" "task" "tasks") ("fork" "fork" "forks")
    ("subagent" "sub-agent" "sub-agents") ("btw" "BTW" "BTW"))
  "How session kinds read in the report: (KIND SINGULAR PLURAL).")

;;;; Buffer state

(defvar-local harness-ui-insights--period nil "Selected period symbol.")
(defvar-local harness-ui-insights--project nil
  "Project the report covers, a directory, or nil for every project.")
(defvar-local harness-ui-insights--here nil
  "Project of the buffer the report was opened from, or nil.")
(defvar-local harness-ui-insights--projects nil
  "Projects the report can be narrowed to, as the harness lists them.")
(defvar-local harness-ui-insights--data nil "The report, as `insights/compute' returns it.")
(defvar-local harness-ui-insights--narrative nil
  "The written summary shown, as `insights/narrative' returns it.")
(defvar-local harness-ui-insights--writing nil "Non-nil while a summary is being written.")
(defvar-local harness-ui-insights--loading nil "Non-nil while the report is computed.")
(defvar-local harness-ui-insights--error nil "Why the report could not be computed.")
(defvar-local harness-ui-insights--generation 0 "Counter to drop stale responses.")

;;;; Data

(defun harness-ui-insights--params (&rest extra)
  "Return the request parameters of the report shown, with EXTRA added."
  (append (list :since (harness-ui-usage--since harness-ui-insights--period)
                :period (symbol-name harness-ui-insights--period)
                :project harness-ui-insights--project)
          extra))

(defun harness-ui-insights--active-p (data)
  "Non-nil when anything happened in the period of report DATA."
  (or (> (or (plist-get (plist-get data :sessions) :active) 0) 0)
      (> (or (plist-get (plist-get (plist-get data :usage) :totals) :calls) 0) 0)))

(defun harness-ui-insights--auto-write-p (data)
  "Non-nil when the summary of report DATA should be written now.
That is when summaries are written as the report opens (`auto'), the
period had something in it and no recent summary is kept."
  (let ((kept (plist-get data :narrative)))
    (and (equal (format "%s" (plist-get data :narrative-mode)) "auto")
         (or (null kept) (harness-json-true-p (plist-get kept :stale)))
         (harness-ui-insights--active-p data))))

(defun harness-ui-insights--load (buffer)
  "Ask for the report BUFFER shows and draw it when it arrives."
  (with-current-buffer buffer
    (let ((gen (cl-incf harness-ui-insights--generation)))
      (setq harness-ui-insights--loading t
            harness-ui-insights--error nil
            harness-ui-insights--writing nil)
      (harness-ui-insights--render)
      (harness-ui-call "_harness/insights/projects" nil
                       (lambda (projects)
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (setq harness-ui-insights--projects projects))))
                       #'ignore)
      (harness-ui-call
       "_harness/insights/compute" (harness-ui-insights--params)
       (lambda (data)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= gen harness-ui-insights--generation)
               (setq harness-ui-insights--data data
                     harness-ui-insights--narrative (plist-get data :narrative)
                     harness-ui-insights--loading nil)
               (harness-ui-insights--render)
               (when (harness-ui-insights--auto-write-p data)
                 (harness-ui-insights--write buffer nil))))))
       (lambda (e)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (= gen harness-ui-insights--generation)
               (setq harness-ui-insights--loading nil
                     harness-ui-insights--error (harness-error-message e))
               (harness-ui-insights--render)))))))))

(defun harness-ui-insights--write (buffer refresh)
  "Have the summary of the report BUFFER shows written; REFRESH writes a new one."
  (with-current-buffer buffer
    (let* ((gen harness-ui-insights--generation)
           (done (lambda (narrative)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (when (= gen harness-ui-insights--generation)
                         (setq harness-ui-insights--writing nil
                               harness-ui-insights--narrative narrative)
                         (harness-ui-insights--render)))))))
      (setq harness-ui-insights--writing t)
      (harness-ui-insights--render)
      (harness-ui-call "_harness/insights/narrative"
                       (harness-ui-insights--params :refresh (if refresh t :false))
                       done
                       (lambda (e)
                         (funcall done (list :skipped (harness-error-message e) :error t)))))))

;;;; Small pieces

(defun harness-ui-insights--count (n singular &optional plural)
  "Return N followed by SINGULAR, or PLURAL (default SINGULAR plus s)."
  (format "%s %s" (harness-ui-insights--number n) (if (eql n 1) singular (or plural (concat singular "s")))))

(defun harness-ui-insights--number (n)
  "Return N with thousands separated."
  (let ((s (format "%d" (round (or n 0)))))
    (while (string-match "\\([0-9]\\)\\([0-9]\\{3\\}\\)\\(,\\|\\'\\)" s)
      (setq s (replace-match "\\1,\\2\\3" t nil s)))
    s))

(defun harness-ui-insights--percent (part whole)
  "Return PART of WHOLE as a percentage string, \"–\" when WHOLE is nothing.
A share under one percent keeps a decimal, so it does not read as none."
  (if (and (numberp whole) (> whole 0))
      (let ((pct (* 100.0 (/ (float (or part 0)) whole))))
        (if (and (> pct 0) (< pct 0.95))
            (format "%.1f%%" pct)
          (format "%d%%" (round pct))))
    "–"))

(defun harness-ui-insights--times (n)
  "Say N times in words: once, twice, 3 times."
  (pcase n (1 "once") (2 "twice") (_ (format "%s times" n))))

(defun harness-ui-insights--duration (seconds)
  "Return SECONDS as hours and minutes, the way the report says time."
  (let ((s (round (or seconds 0))))
    (cond ((< s 60) (format "%ds" s))
          ((< s 3600) (format "%dm" (/ s 60)))
          (t (format "%dh%02dm" (/ s 3600) (/ (mod s 3600) 60))))))

(defun harness-ui-insights--date (time &optional year)
  "Return TIME as a short date, with the YEAR when asked."
  (format-time-string (if year "%b %-d, %Y" "%b %-d") time))

(defun harness-ui-insights--ago (time)
  "Say how long ago TIME was."
  (let ((s (- (float-time) (or time 0))))
    (cond ((< s 90) "just now")
          ((< s 3600) (format "%d minutes ago" (round s 60)))
          ((< s 172800) (format "%s ago" (harness-ui-insights--count (round s 3600) "hour")))
          (t (format "%d days ago" (round s 86400))))))

(defun harness-ui-insights--project-name (root)
  "Return a short name of project ROOT."
  (if (or (null root) (string-empty-p root))
      "(no project)"
    (let ((name (file-name-nondirectory (directory-file-name root))))
      (if (string-empty-p name) (abbreviate-file-name root) name))))

(defun harness-ui-insights--heading (title &optional note)
  "Insert section heading TITLE, with NOTE dimmed after it."
  (insert "\n " (propertize title 'face 'harness-usage-heading-face))
  (when (and note (not (string-empty-p note)))
    (insert "   " (propertize note 'face 'harness-dim-face)))
  (insert "\n"))

(defun harness-ui-insights--dim (text)
  "Insert TEXT dimmed, indented, as a line."
  (insert "   " (propertize text 'face 'harness-dim-face) "\n"))

(defun harness-ui-insights--fill-width ()
  "Return the column paragraphs fill to in the report's window."
  (let ((win (get-buffer-window (current-buffer) t)))
    (max 40 (min 100 (- (if win (window-body-width win) 80) 4)))))

(defun harness-ui-insights--paragraph (text indent &optional first face)
  "Insert TEXT filled to the window, INDENT spaces in.
FIRST, when given, starts the first line instead of the indentation
\(a bullet); FACE is the text's face."
  (let ((start (point))
        (prefix (make-string indent ?\s)))
    (insert (or first prefix) (if face (propertize text 'face face) text) "\n")
    (let ((fill-column (harness-ui-insights--fill-width))
          (fill-prefix prefix))
      (fill-region-as-paragraph start (point)))
    (unless (bolp) (insert "\n"))))

(defun harness-ui-insights--parts (parts indent &optional face)
  "Insert PARTS, strings, joined with dots and INDENT spaces in.
Lines break between parts only, at the paragraphs' width; FACE is
their face."
  (let ((width (harness-ui-insights--fill-width))
        (prefix (make-string indent ?\s))
        (column indent)
        (first t))
    (insert prefix)
    (dolist (part (delq nil parts))
      (let ((w (string-width part)))
        (cond (first (setq first nil))
              ((> (+ column 3 w) width)
               (insert "\n" prefix)
               (setq column indent))
              (t (insert (propertize " · " 'face (or face 'harness-dim-face)))
                 (cl-incf column 3)))
        (insert (if face (propertize part 'face face) part))
        (cl-incf column w)))
    (insert "\n")))

(defun harness-ui-insights--day (day)
  "Return DAY, a \"YYYY-MM-DD\" string, as a short date."
  (if (and (stringp day) (string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)-\\([0-9]+\\)\\'" day))
      (let ((year (string-to-number (match-string 1 day))))
        (harness-ui-insights--date (encode-time (list 0 0 12 (string-to-number (match-string 3 day))
                                                      (string-to-number (match-string 2 day)) year nil -1 nil))
                                   (/= year (decoded-time-year (decode-time)))))
    (format "%s" day)))

(defun harness-ui-insights--meter (fraction &optional role help)
  "Return a share meter of FRACTION in the colour of ROLE, with tooltip HELP."
  (harness-ui-usage--meter-string (max 0.0 (min 1.0 (or fraction 0)))
                                  (harness-ui-usage--color (or role 'accent)) 64 8 help))

(defun harness-ui-insights--table (columns rows &optional line-props)
  "Insert a table of ROWS under COLUMNS.
COLUMNS are (TITLE ALIGN), ALIGN `left' or `right'; ROWS lists of
cells, strings.  LINE-PROPS, a function of a row's index, returns the
text properties its line gets."
  (let* ((widths (cl-loop for col in columns for i from 0
                          collect (apply #'max (string-width (car col))
                                         (mapcar (lambda (r) (string-width (nth i r))) rows))))
         (line (lambda (cells)
                 (concat "   "
                         (string-join
                          (cl-loop for cell in cells for col in columns for w in widths
                                   collect (let ((pad (make-string (max 0 (- w (string-width cell))) ?\s)))
                                             (if (eq (nth 1 col) 'right) (concat pad cell) (concat cell pad))))
                          "  ")))))
    (insert (propertize (funcall line (mapcar #'car columns)) 'face 'harness-usage-table-header-face) "\n")
    (cl-loop for r in rows for i from 0 do
             (let ((start (point)))
               (insert (funcall line r) "\n")
               (when line-props
                 (add-text-properties start (1- (point)) (funcall line-props i)))))))

(defun harness-ui-insights--spark (values)
  "Return VALUES as a text sparkline."
  (let ((top (apply #'max 1 values))
        (ticks "▁▂▃▄▅▆▇█"))
    (mapconcat (lambda (v)
                 (if (zerop v) "·" (string (aref ticks (min 7 (floor (* 8 (/ (float v) top))))))))
               values "")))

(defun harness-ui-insights--columns (values labels width tips)
  "Return an SVG column chart of VALUES, WIDTH pixels wide.
LABELS name the columns (nil leaves one out) and TIPS are their tooltips."
  (let* ((height harness-ui-insights--activity-height)
         (top 6) (bottom 18) (left 2) (right 2)
         (plot-w (- width left right))
         (plot-h (- height top bottom))
         (n (max 1 (length values)))
         (slot (/ (float plot-w) n))
         (bar-w (max 2 (- slot (max 2 (min 6 (* slot 0.25))))))
         (top-value (float (apply #'max 1 values)))
         (svg (svg-create width height))
         (font (harness-ui-usage--font))
         (muted (harness-ui-usage--color 'muted))
         (grid (harness-ui-usage--color 'grid))
         (accent (harness-ui-usage--color 'accent))
         (map nil))
    (cl-loop for v in values for label in labels for tip in tips for i from 0 do
             (let* ((x0 (+ left (* i slot)))
                    (bh (* plot-h (/ v top-value))))
               (when (> v 0)
                 (harness-ui-usage--rounded-top svg (+ x0 (/ (- slot bar-w) 2)) (+ top (- plot-h bh))
                                                bar-w (max bh 1.5) 3 :fill accent))
               (when label
                 (svg-text svg label :x (+ x0 (/ slot 2)) :y (- height 4) :text-anchor "middle"
                           :font-family font :font-size 10 :fill muted))
               (push (list (cons 'rect (cons (cons (round x0) top) (cons (round (+ x0 slot)) (+ top plot-h))))
                           (intern (format "column-%d" i))
                           (list 'help-echo tip))
                     map)))
    (svg-line svg left (+ top plot-h) (+ left plot-w) (+ top plot-h) :stroke-color grid :stroke-width 1)
    (svg-image svg :ascent 'center :scale 1 :map (nreverse map))))

(defun harness-ui-insights--columns-image (values labels width tips)
  "Return the column chart of VALUES, made on the frame that shows the buffer.
LABELS, WIDTH and TIPS are as `harness-ui-insights--columns' takes them.
Images with a map are measured on the selected frame; see
`harness-ui-usage--chart-image'."
  (let ((win (get-buffer-window (current-buffer) t)))
    (with-selected-frame (if win (window-frame win) (selected-frame))
      (harness-ui-insights--columns values labels width tips))))

;;;; Sections

(defun harness-ui-insights--period-label ()
  "Return the selected period's label, as the header line has it."
  (nth 1 (assq harness-ui-insights--period harness-ui-usage--periods)))

(defun harness-ui-insights--insert-title (data)
  "Insert what report DATA covers, and how it was made."
  (let* ((since (plist-get data :since))
         (until (plist-get data :until))
         (project (plist-get data :project))
         (scan (plist-get data :scan)))
    (insert "\n " (propertize "Insights" 'face 'harness-usage-total-face) "   "
            (propertize (if since
                            (format "%s – %s" (harness-ui-insights--date since)
                                    (harness-ui-insights--date until t))
                          (format "everything until %s" (harness-ui-insights--date until t)))
                        'face 'harness-usage-heading-face)
            (propertize (format "  ·  %s" (if project (abbreviate-file-name project) "every project"))
                        'face 'harness-dim-face)
            "\n")
    (insert " " (propertize
                 (concat (format "Made %s from the harness's own records" (format-time-string "%H:%M" (plist-get data :generated)))
                         (if scan
                             (format ": %s, read in %.1fs" (harness-ui-insights--count (plist-get scan :files) "transcript")
                                     (or (plist-get scan :seconds) 0))
                           "")
                         ".  They read the same for every provider.")
                 'face 'harness-dim-face)
            "\n")
    (when-let* ((problem (plist-get data :scan-error)))
      (insert " " (propertize (format "The transcripts could not be read (%s): sessions, tools and activity are missing." problem)
                              'face 'warning)
              "\n"))
    (when-let* ((problem (plist-get (plist-get data :usage) :error)))
      (insert " " (propertize (format "Usage could not be read: %s" problem) 'face 'warning) "\n"))))

(defun harness-ui-insights--insert-totals (data)
  "Insert the headline figures of report DATA."
  (let* ((sessions (plist-get data :sessions))
         (totals (plist-get (plist-get data :usage) :totals))
         (tasks (plist-get data :tasks))
         (cell (lambda (value label &optional help)
                 (concat (propertize value 'face 'harness-usage-total-face 'help-echo help)
                         " " (propertize label 'face 'harness-dim-face 'help-echo help) "    ")))
         (counted (lambda (n singular plural &optional help)
                    (funcall cell (harness-ui-insights--number n) (if (eql n 1) singular plural) help)))
         (done (and tasks (plist-get tasks :completed))))
    (insert "\n "
            (funcall counted (plist-get sessions :active) "session" "sessions"
                     "Sessions that worked in the period, of every kind")
            (funcall counted (plist-get sessions :messages) "message" "messages"
                     "Messages you wrote; the harness's and other agents' are not counted")
            (funcall cell (harness-ui-insights--duration (plist-get sessions :active-seconds)) "active"
                     "Time sessions were working, without the pauses longer than ten minutes")
            (funcall cell (harness-format-cost (plist-get totals :cost)) "cost"
                     "Billed, as the usage dashboard counts it")
            (funcall counted (plist-get (plist-get data :tool-totals) :calls) "tool call" "tool calls")
            (if (and done (> done 0)) (funcall counted done "task done" "tasks done") "")
            "\n")))

(defun harness-ui-insights--write-button (label)
  "Insert a button LABEL that writes the summary again."
  (harness-ui-button label #'harness-ui-insights-write :help "Write the summary again (n)"))

(defun harness-ui-insights--insert-items (title items)
  "Insert the list ITEMS of the summary under TITLE, when there are any."
  (when items
    (insert "\n   " (propertize title 'face 'bold) "\n")
    (dolist (item items)
      (harness-ui-insights--paragraph item 5 "   • "))))

(defun harness-ui-insights--insert-summary (data)
  "Insert the written summary of report DATA, or why there is none."
  (let* ((n harness-ui-insights--narrative)
         (mode (format "%s" (plist-get data :narrative-mode)))
         (written (and n (plist-get n :summary) n)))
    (harness-ui-insights--heading
     "Summary"
     (and written (format "by %s, %s%s" (harness-ui-model-label (plist-get written :model))
                          (harness-ui-insights--ago (plist-get written :at))
                          (if (harness-json-true-p (plist-get written :stale)) " (old)" ""))))
    (cond
     (harness-ui-insights--writing
      (harness-ui-insights--dim "Writing the summary with your model…"))
     (written
      (harness-ui-insights--paragraph (plist-get written :summary) 3)
      (harness-ui-insights--insert-items "What you worked on" (plist-get written :themes))
      (harness-ui-insights--insert-items "How you work" (plist-get written :patterns))
      (harness-ui-insights--insert-items "Where things went wrong" (plist-get written :friction))
      (harness-ui-insights--insert-items "Things to try" (plist-get written :suggestions))
      (insert "   ")
      (harness-ui-insights--write-button "[write again]")
      (insert "\n"))
     ((equal mode "nil")
      (harness-ui-insights--dim
       "Written summaries are off: the figures below never leave the harness.  Set harness-insights-narrative to have one."))
     ((not (harness-ui-insights--active-p data))
      (harness-ui-insights--dim "Nothing happened in this period to write about."))
     ((plist-get n :skipped)
      (insert "   " (propertize (plist-get n :skipped) 'face (if (plist-get n :error) 'warning 'harness-dim-face)) "  ")
      (harness-ui-insights--write-button "[try again]")
      (insert "\n"))
     (t
      (insert "   " (propertize "No summary yet; one is written by your model from these figures.  " 'face 'harness-dim-face))
      (harness-ui-insights--write-button "[write one]")
      (insert "\n")))))

(defun harness-ui-insights--usage-rows (rows label total)
  "Return the table cells of usage ROWS, LABEL naming each.
TOTAL is the usage at API prices the share meters divide."
  (mapcar (lambda (r)
            (let ((share (if (> total 0) (/ (harness-usage-list-cost r) total) 0)))
              (list (funcall label r)
                    (harness-format-cost (plist-get r :cost))
                    (concat (harness-ui-insights--meter share 'accent (format "%.0f%% of the usage at API prices" (* 100 share)))
                            (propertize (format " %3.0f%%" (* 100 share)) 'face 'harness-dim-face))
                    (harness-ui-insights--number (plist-get r :calls))
                    (harness-format-tokens (plist-get r :input))
                    (harness-format-tokens (plist-get r :output)))))
          rows))

(defconst harness-ui-insights--usage-columns
  '(("Cost" right) ("Share" left) ("Calls" right) ("Input" right) ("Output" right))
  "Columns of the usage tables after the first.")

(defun harness-ui-insights--insert-usage (data)
  "Insert the usage of report DATA: the cost chart, by model and by provider."
  (let* ((usage (plist-get data :usage))
         (totals (plist-get usage :totals))
         (all (harness-usage-list-cost totals))
         (covered (harness-usage-covered totals)))
    (harness-ui-insights--heading
     "Usage"
     (format "%s billed%s · %s · %s in, %s out"
             (harness-format-cost (plist-get totals :cost))
             (if (> covered 0) (format ", %s covered by a plan" (harness-format-cost covered)) "")
             (harness-ui-insights--count (plist-get totals :calls) "model call")
             (harness-format-tokens (plist-get totals :input)) (harness-format-tokens (plist-get totals :output))))
    (if (zerop (or (plist-get totals :calls) 0))
        (harness-ui-insights--dim "No model calls recorded in this period.")
      (insert "\n")
      ;; The dashboard's chart, per hour for today.
      (let ((harness-ui-usage--period harness-ui-insights--period))
        (harness-ui-usage--insert-chart (plist-get usage :series)))
      (insert "   " (propertize "By model" 'face 'bold) "\n")
      (harness-ui-insights--table (cons '("Model" left) harness-ui-insights--usage-columns)
                                  (harness-ui-insights--usage-rows
                                   (seq-take (plist-get usage :by-model) 8)
                                   (lambda (r) (harness-ui-model-label (plist-get r :key))) all))
      (when (cdr (plist-get usage :by-provider))
        (insert "\n   " (propertize "By provider" 'face 'bold) "\n")
        (harness-ui-insights--table (cons '("Provider" left) harness-ui-insights--usage-columns)
                                    (harness-ui-insights--usage-rows
                                     (plist-get usage :by-provider)
                                     (lambda (r) (harness-ui-usage--provider-label (plist-get r :key))) all))))))

(defun harness-ui-insights--insert-projects (data)
  "Insert the projects of report DATA: their sessions, time and cost.
Only for a report of every project."
  (unless (plist-get data :project)
    (let* ((activity (plist-get data :projects))
           (usage (plist-get (plist-get data :usage) :projects))
           (mains (delete-dups (append (mapcar (lambda (p) (plist-get p :main)) activity)
                                       (mapcar (lambda (r) (plist-get r :key)) usage))))
           (rows (mapcar (lambda (main)
                           (list main
                                 (cl-find main activity :key (lambda (p) (plist-get p :main)) :test #'equal)
                                 (cl-find main usage :key (lambda (r) (plist-get r :key)) :test #'equal)))
                         mains))
           (rows (sort rows (lambda (a b)
                              (> (or (plist-get (nth 1 a) :active) 0) (or (plist-get (nth 1 b) :active) 0)))))
           (most (apply #'max 1.0 (mapcar (lambda (r) (float (or (plist-get (nth 1 r) :active) 0))) rows))))
      (when rows
        (harness-ui-insights--heading "Projects" (harness-ui-insights--count (length rows) "project"))
        (harness-ui-insights--table
         '(("Project" left) ("Sessions" right) ("Active" right) ("" left) ("Messages" right) ("Cost" right))
         (mapcar (lambda (r)
                   (let ((act (nth 1 r)) (use (nth 2 r)))
                     (list (propertize (harness-truncate-end (harness-ui-insights--project-name (car r)) 32)
                                       'help-echo (abbreviate-file-name (car r)))
                           (harness-ui-insights--number (plist-get act :sessions))
                           (harness-ui-insights--duration (plist-get act :active))
                           (harness-ui-insights--meter (/ (or (plist-get act :active) 0) most))
                           (harness-ui-insights--number (plist-get act :messages))
                           (harness-format-cost (plist-get use :cost)))))
                 (seq-take rows 10)))))))

(defun harness-ui-insights--kinds-text (sessions)
  "Describe SESSIONS by kind, as \"12 chats · 3 tasks\"."
  (mapconcat (lambda (k)
               (let* ((kind (plist-get k :kind))
                      (n (plist-get k :sessions))
                      (label (cdr (assoc kind harness-ui-insights--kind-labels))))
                 (format "%s %s" n (cond ((null label) kind) ((eql n 1) (car label)) (t (cadr label))))))
             (plist-get sessions :by-kind) " · "))

(defun harness-ui-insights--insert-sessions (data)
  "Insert the sessions of report DATA and the busiest of them."
  (let* ((sessions (plist-get data :sessions))
         (n (or (plist-get sessions :active) 0))
         (rows (plist-get data :busiest-sessions)))
    (harness-ui-insights--heading "Sessions" (and (> n 0) (harness-ui-insights--kinds-text sessions)))
    (if (zerop n)
        (harness-ui-insights--dim "No session worked in this period.")
      (harness-ui-insights--dim
       (format "%s and %s active per session on average; you wrote %s."
               (format "%.1f turns" (/ (float (or (plist-get sessions :turns) 0)) n))
               (harness-ui-insights--duration (/ (or (plist-get sessions :active-seconds) 0) n))
               (harness-ui-insights--count (plist-get sessions :messages) "message")))
      (when rows
        (insert "\n   " (propertize "Busiest" 'face 'bold) (propertize "   RET opens one" 'face 'harness-dim-face) "\n")
        (harness-ui-insights--table
         '(("Session" left) ("Kind" left) ("Project" left) ("Turns" right) ("Active" right) ("Tools" right) ("Failed" right))
         (mapcar (lambda (r)
                   (list (propertize (harness-truncate-end (or (plist-get r :name) "unnamed") 36) 'face 'button)
                         (or (cdr (assoc (plist-get r :kind) '(("main" . "chat") ("subagent" . "sub-agent") ("btw" . "BTW"))))
                             (plist-get r :kind))
                         (harness-truncate-end (harness-ui-insights--project-name (plist-get r :main)) 20)
                         (harness-ui-insights--number (plist-get r :turns))
                         (harness-ui-insights--duration (plist-get r :active))
                         (harness-ui-insights--number (plist-get r :tools))
                         (let ((e (+ (or (plist-get r :errors) 0) (or (plist-get r :denied) 0))))
                           (if (> e 0) (propertize (format "%d" e) 'face 'warning) ""))))
                 rows)
         (lambda (i)
           (let ((r (nth i rows)))
             (list 'harness-ui-insights-session (plist-get r :id)
                   'mouse-face 'highlight
                   'help-echo (format "RET / mouse-1: open this session%s"
                                      (if (plist-get r :prompt) (concat "\n" (plist-get r :prompt)) ""))))))))))

(defun harness-ui-insights--insert-tools (data)
  "Insert the tool calls of report DATA, by tool."
  (let* ((totals (plist-get data :tool-totals))
         (calls (or (plist-get totals :calls) 0))
         (tools (plist-get data :tools))
         (shown (seq-take tools 12))
         (most (float (apply #'max 1 (mapcar (lambda (tl) (plist-get tl :calls)) tools)))))
    (harness-ui-insights--heading
     "Tools"
     (and (> calls 0)
          (format "%s · %s failed · %s denied"
                  (harness-ui-insights--count calls "call")
                  (harness-ui-insights--percent (plist-get totals :errors) calls)
                  (harness-ui-insights--percent (plist-get totals :denied) calls))))
    (if (zerop calls)
        (harness-ui-insights--dim "No tool calls in this period.")
      (harness-ui-insights--table
       '(("Tool" left) ("Calls" right) ("" left) ("Failed" right) ("Denied" right) ("Total time" right))
       (mapcar (lambda (tl)
                 (let* ((n (plist-get tl :calls))
                        (errors (plist-get tl :errors))
                        (rate (if (> n 0) (/ (float errors) n) 0)))
                   (list (harness-truncate-end (plist-get tl :tool) 28)
                         (harness-ui-insights--number n)
                         (harness-ui-insights--meter (/ n most))
                         (propertize (harness-ui-insights--percent errors n)
                                     'face (if (and (>= errors 2) (>= rate 0.1)) 'warning 'default))
                         (if (> (plist-get tl :denied) 0) (harness-ui-insights--number (plist-get tl :denied)) "")
                         (harness-ui-insights--duration (plist-get tl :seconds)))))
               shown))
      (when (> (length tools) (length shown))
        (let ((more (- (length tools) (length shown))))
          (harness-ui-insights--dim (format "and %d more %s" more (if (= more 1) "tool" "tools"))))))))

(defun harness-ui-insights--insert-permissions (data)
  "Insert the permission decisions of report DATA."
  (let* ((perms (plist-get data :permissions))
         (decisions (or (plist-get perms :decisions) 0))
         (denied-calls (or (plist-get (plist-get data :tool-totals) :denied) 0)))
    (harness-ui-insights--heading "Permissions")
    (cond
     ((> decisions 0)
      (let ((asked (or (plist-get perms :asked) 0)))
        (harness-ui-insights--paragraph
         (concat (format "%s on tool calls.  " (harness-ui-insights--count decisions "permission decision"))
                 (if (> asked 0)
                     (format "You were asked about %s and allowed %s of them; "
                             (harness-ui-insights--count asked "call")
                             (harness-ui-insights--percent (plist-get perms :asked-allowed) asked))
                   "You were never asked; ")
                 (format "%s %s settled by a rule or the permission mode%s."
                         (harness-ui-insights--number (- decisions asked))
                         (if (= (- decisions asked) 1) "was" "were")
                         (let ((auto-denied (- (or (plist-get perms :denied) 0) (or (plist-get perms :asked-denied) 0))))
                           (if (> auto-denied 0) (format ", %d of them denied" auto-denied) ""))))
         3)
        (when-let* ((asked-tools (seq-take (cl-remove-if-not (lambda (tl) (> (plist-get tl :asked) 0))
                                                             (sort (copy-sequence (plist-get perms :tools))
                                                                   (lambda (a b) (> (plist-get a :asked) (plist-get b :asked)))))
                                           5)))
          (harness-ui-insights--dim
           (concat "Asked most about: "
                   (mapconcat (lambda (tl) (format "%s %d×%s" (plist-get tl :tool) (plist-get tl :asked)
                                                   (if (> (plist-get tl :asked-denied) 0)
                                                       (format " (%d denied)" (plist-get tl :asked-denied))
                                                     "")))
                              asked-tools ", "))))))
     ((> denied-calls 0)
      (harness-ui-insights--dim (format "%s denied.  Decisions are logged from now on, which says how often you are asked."
                                        (harness-ui-insights--count denied-calls "tool call"))))
     (t (harness-ui-insights--dim "No permission decisions logged in this period.")))))

(defconst harness-ui-insights--why
  '(("failed" "✗" error) ("sent-back" "↩" warning) ("review" "◆" harness-dim-face) ("done" "✓" success))
  "Why a task is worth a look: (WHY ICON FACE).")

(defun harness-ui-insights--column-text (column)
  "Say where a task in COLUMN of the board is, as \"in review\"."
  (pcase (format "%s" column)
    ("active" "at work")
    ("review" "in review")
    ("needs-input" "waiting for input")
    ("backlog" "in the backlog")
    (name name)))

(defun harness-ui-insights--task-detail (task)
  "Describe notable TASK in a few words."
  (let ((why (plist-get task :why))
        (rounds (or (plist-get task :feedback) 0))
        (column (plist-get task :column))
        (done-at (plist-get task :done-at)))
    (string-join
     (delq nil
           (list (pcase why
                   ("failed" (format "stopped with an error%s"
                                     (if (plist-get task :outcome) (format " (%s)" (plist-get task :outcome)) "")))
                   ("sent-back" (format "sent back %s" (harness-ui-insights--times (max 1 rounds))))
                   ("review" "waits for your review")
                   (_ (concat "done" (if done-at (concat " " (harness-ui-insights--ago done-at)) ""))))
                 (and (equal why "sent-back") column (not (member (format "%s" column) '("done" "")))
                      (concat "now " (harness-ui-insights--column-text column)))
                 (and (member why '("review" "done")) (> rounds 0)
                      (format "after being sent back %s" (harness-ui-insights--times rounds)))
                 (and (harness-json-true-p (plist-get task :conflict)) "met a merge conflict")))
     ", ")))

(defun harness-ui-insights--open-text (column)
  "Describe COLUMN of the task board, (:column :count), as \"2 in review\"."
  (format "%s %s" (plist-get column :count) (harness-ui-insights--column-text (plist-get column :column))))

(defun harness-ui-insights--insert-tasks (data)
  "Insert the task board's figures of report DATA."
  (let* ((tasks (plist-get data :tasks))
         (open (plist-get tasks :open))
         (notable (plist-get tasks :notable)))
    (harness-ui-insights--heading "Tasks")
    (if (and (zerop (+ (or (plist-get tasks :submitted) 0) (or (plist-get tasks :completed) 0)
                       (or (plist-get tasks :sent-back) 0) (or (plist-get tasks :failed) 0)))
             (null open))
        (harness-ui-insights--dim "No tasks in this period.")
      (let ((done (or (plist-get tasks :completed) 0))
            (merged (or (plist-get tasks :merged) 0))
            (rounds (or (plist-get tasks :feedback-rounds) 0)))
        (harness-ui-insights--parts
         (list (format "%s submitted" (harness-ui-insights--number (plist-get tasks :submitted)))
               (format "%s done (%s merged)" (harness-ui-insights--number done) (harness-ui-insights--number merged))
               (and (> done 0)
                    (format "%s accepted the first time"
                            (harness-ui-insights--percent (plist-get tasks :first-try) done)))
               (format "%s sent back%s" (harness-ui-insights--number (plist-get tasks :sent-back))
                       (if (> rounds 0) (format " (%s of feedback)" (harness-ui-insights--count rounds "round")) ""))
               (format "%s stopped with an error" (harness-ui-insights--number (plist-get tasks :failed)))
               (and (> (or (plist-get tasks :cancelled) 0) 0)
                    (format "%s cancelled" (harness-ui-insights--number (plist-get tasks :cancelled)))))
         3)
        (when (> merged 0)
          (harness-ui-insights--parts
           (list (format "%s of %s merges met a conflict (%s)" (plist-get tasks :conflicted) merged
                         (harness-ui-insights--percent (plist-get tasks :conflicted) merged))
                 (and (plist-get tasks :median-time)
                      (format "the median task took %s from start to done"
                              (harness-ui-insights--duration (plist-get tasks :median-time)))))
           3 'harness-dim-face)))
      (when open
        (harness-ui-insights--parts
         (cons (format "On the board now: %s" (harness-ui-insights--open-text (car open)))
               (mapcar #'harness-ui-insights--open-text (cdr open)))
         3 'harness-dim-face))
      (when notable
        (insert "\n   " (propertize "Worth a look" 'face 'bold) (propertize "   RET opens a task's session" 'face 'harness-dim-face) "\n")
        (dolist (task notable)
          (let* ((why (assoc (plist-get task :why) harness-ui-insights--why))
                 (start (point)))
            (insert "   " (propertize (or (nth 1 why) "·") 'face (or (nth 2 why) 'default)) " "
                    (propertize (harness-truncate-end (or (plist-get task :title) (plist-get task :id)) 56) 'face 'button)
                    "  " (propertize (harness-ui-insights--task-detail task) 'face 'harness-dim-face))
            (add-text-properties start (point)
                                 (list 'harness-ui-insights-task (plist-get task :id)
                                       'harness-ui-insights-session (plist-get task :session)
                                       'mouse-face 'highlight
                                       'help-echo (if (plist-get task :session) "RET / mouse-1: open this task's session"
                                                    "This task has no session to open")))
            (insert "\n")))))))

(defun harness-ui-insights--insert-activity (data)
  "Insert when the user of report DATA wrote: by hour, by weekday, and streaks."
  (let* ((activity (plist-get data :activity))
         (hours (or (plist-get activity :hours) (make-list 24 0)))
         (weekdays (or (plist-get activity :weekdays) (make-list 7 0)))
         (messages (apply #'+ hours))
         (busiest (plist-get activity :busiest-day)))
    (harness-ui-insights--heading "Activity" "the messages you wrote")
    (if (zerop messages)
        (harness-ui-insights--dim "You wrote no messages in this period.")
      (if (harness-ui-usage--graphic-p)
          (let* ((width (harness-ui-usage--chart-width))
                 (hour-w (round (* 0.62 width)))
                 (day-w (- width hour-w 24)))
            (insert "   " (propertize "By hour of day" 'face 'bold)
                    (make-string (max 2 (- (/ hour-w (max 1 (frame-char-width))) 12)) ?\s)
                    (propertize "By weekday" 'face 'bold) "\n")
            (insert "   "
                    (propertize " " 'display
                                (harness-ui-insights--columns-image
                                 hours
                                 (cl-loop for h below 24 collect (and (zerop (mod h 3)) (format "%d" h)))
                                 hour-w
                                 (cl-loop for h below 24 for v in hours
                                          collect (format "%02d:00–%02d:59: %s" h h (harness-ui-insights--count v "message"))))
                                'help-echo "Hover a column for its messages")
                    "   "
                    (propertize " " 'display
                                (harness-ui-insights--columns-image
                                 weekdays harness-ui-insights--weekdays day-w
                                 (cl-loop for d in harness-ui-insights--weekdays for v in weekdays
                                          collect (format "%s: %s" d (harness-ui-insights--count v "message"))))
                                'help-echo "Hover a column for its messages")
                    "\n"))
        (insert "   " (propertize "By hour" 'face 'bold) "  " (harness-ui-insights--spark hours)
                (propertize "  0h–23h" 'face 'harness-dim-face) "\n"
                "   " (propertize "By day " 'face 'bold) "  " (harness-ui-insights--spark weekdays)
                (propertize "  Mon–Sun" 'face 'harness-dim-face) "\n"))
      (harness-ui-insights--parts
       (list (format "Active on %s" (harness-ui-insights--count (plist-get activity :active-days) "day"))
             (and (> (or (plist-get activity :longest-streak) 0) 1)
                  (format "longest streak %s%s"
                          (harness-ui-insights--count (plist-get activity :longest-streak) "day")
                          (if (plist-get activity :longest-streak-end)
                              (format " (to %s)" (harness-ui-insights--day (plist-get activity :longest-streak-end)))
                            "")))
             (and (> (or (plist-get activity :current-streak) 0) 0)
                  (format "current streak %s" (harness-ui-insights--count (plist-get activity :current-streak) "day")))
             (and busiest (format "busiest day %s, %s" (harness-ui-insights--day (plist-get busiest :day))
                                  (harness-ui-insights--count (plist-get busiest :messages) "message"))))
       3 'harness-dim-face))))

(defun harness-ui-insights--line-start (line)
  "Return the position where LINE starts, or the last line's start."
  (save-excursion (goto-char (point-min)) (forward-line (1- line)) (line-beginning-position)))

(defun harness-ui-insights--render ()
  "Draw the report from the buffer's state, keeping each window's lines."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (windows (mapcar (lambda (w) (list w (line-number-at-pos (window-start w))
                                           (line-number-at-pos (window-point w))))
                         (get-buffer-window-list nil nil t)))
        (data harness-ui-insights--data))
    (erase-buffer)
    (setq header-line-format (harness-ui-insights--header))
    (cond
     ((and (null data) harness-ui-insights--error)
      (insert "\n " (propertize (format "The report could not be made: %s" harness-ui-insights--error) 'face 'error) "\n"))
     ((null data)
      (insert "\n " (propertize "Gathering insights…" 'face 'harness-usage-heading-face) "\n\n "
              (propertize "The harness reads the period's transcripts, usage and tasks in the background;\n Emacs stays yours meanwhile."
                          'face 'harness-dim-face)
              "\n"))
     (t
      (harness-ui-insights--insert-title data)
      (harness-ui-insights--insert-totals data)
      (harness-ui-insights--insert-summary data)
      (harness-ui-insights--insert-activity data)
      (harness-ui-insights--insert-usage data)
      (harness-ui-insights--insert-projects data)
      (harness-ui-insights--insert-sessions data)
      (harness-ui-insights--insert-tools data)
      (harness-ui-insights--insert-permissions data)
      (harness-ui-insights--insert-tasks data)
      (insert "\n")))
    (goto-char (harness-ui-insights--line-start line))
    (pcase-dolist (`(,window ,start ,point) windows)
      (set-window-start window (harness-ui-insights--line-start start) t)
      (set-window-point window (harness-ui-insights--line-start point)))))

;;;; Header line

(defun harness-ui-insights--period-command (period)
  "Return a command showing PERIOD."
  (lambda () (interactive) (harness-ui-insights-set-period period)))

(defun harness-ui-insights--project-command (project)
  "Return a command narrowing the report to PROJECT (nil: every project)."
  (lambda () (interactive) (harness-ui-insights-set-project project)))

(defun harness-ui-insights--header (&optional width)
  "Return the header line with the period and scope selectors, fitted to WIDTH."
  (let ((project harness-ui-insights--project)
        (here harness-ui-insights--here))
    (harness-ui-fit-header
     (append
      (list (propertize " Insights " 'face 'harness-usage-heading-face))
      (mapcar (lambda (p)
                (let ((chosen (eq (car p) harness-ui-insights--period)))
                  (list (harness-ui-usage--segment (nth 1 p) (harness-ui-insights--period-command (car p)) chosen (nth 2 p))
                        (if chosen 90 50))))
              harness-ui-usage--periods)
      (list (list (propertize "  ·" 'face 'harness-dim-face) 45)
            (list (harness-ui-usage--segment "All projects" (harness-ui-insights--project-command nil)
                                             (null project) "Every project")
                  (if (null project) 85 48))
            (when (or here project)
              (let ((shown (or project here)))
                (list (harness-ui-usage--segment (harness-ui-insights--project-name shown)
                                                 (harness-ui-insights--project-command shown)
                                                 (and project t)
                                                 (format "Only %s, with its git worktrees" (abbreviate-file-name shown)))
                      (if project 85 47))))
            (cond (harness-ui-insights--loading (list (propertize "  computing…" 'face 'harness-dim-face) 95))
                  (harness-ui-insights--error
                   (list (concat "  " (propertize "error" 'face 'error)) 95)))
            (list (concat "  " (harness-ui-usage--segment "p" #'harness-ui-insights-set-project nil "Choose a project")) 55)
            (list (harness-ui-usage--segment "n" #'harness-ui-insights-write nil "Write the summary again") 58)
            (list (harness-ui-usage--segment "g" #'harness-ui-insights-refresh nil "Compute the report again") 60)
            (list (harness-ui-usage--segment "q" #'quit-window nil "Quit") 65)))
     width)))

;;;; Mode and commands

(defvar harness-ui-insights-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'harness-ui-insights-refresh)
    (define-key map (kbd "t") #'harness-ui-insights-cycle-period)
    (define-key map (kbd "p") #'harness-ui-insights-set-project)
    (define-key map (kbd "n") #'harness-ui-insights-write)
    (define-key map (kbd "RET") #'harness-ui-insights-open)
    (define-key map [mouse-1] #'harness-ui-insights-mouse-open)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-insights-mode'.")

(define-derived-mode harness-ui-insights-mode special-mode "Insights"
  "Major mode of the Insights report.
\\{harness-ui-insights-mode-map}"
  (setq truncate-lines t
        buffer-read-only t)
  (add-hook 'window-configuration-change-hook #'harness-ui-insights--on-resize nil t))

;; The report's keys in the harness menu, behind `.'.
(put 'harness-ui-insights-mode 'harness-menu-group
     '("Insights"
       ["View"
        (". t" "Next period" harness-ui-insights-cycle-period)
        (". p" "Project…" harness-ui-insights-set-project)
        (". RET" "Open the session at point" harness-ui-insights-open)
        (". g" "Compute again" harness-ui-insights-refresh)]
       ["Summary"
        (". n" "Write it again" harness-ui-insights-write)]))

(defun harness-ui-insights--on-resize ()
  "Draw the report again so the charts and paragraphs fit the window."
  (when harness-ui-insights--data
    (let ((b (current-buffer)))
      (harness-debounce (list 'harness-ui-insights-resize b) 0.2
                        (lambda () (when (buffer-live-p b) (with-current-buffer b (harness-ui-insights--render))))))))

(defvar harness-ui-tasks--project)

(defun harness-ui-insights--current-project ()
  "Return the project of the current buffer, a directory, or nil.
That is its session's project, the task board's, or its directory."
  (or (when-let* ((sid harness-ui-session-id)
                  (session (harness-ui-session sid)))
        (plist-get session :project))
      (bound-and-true-p harness-ui-tasks--project)
      (and (stringp default-directory) (not (file-remote-p default-directory))
           (expand-file-name default-directory))))

;;;###autoload
(defun harness-insights ()
  "Show the Insights report: how your work with the agents went.
Figures from the harness's own records -- sessions, usage, tasks and
permission decisions -- over a period, and a summary your model writes
from them; the same for every provider."
  (interactive)
  (let ((here (harness-ui-insights--current-project))
        (buf (get-buffer-create harness-ui-insights--buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-insights-mode)
        (harness-ui-insights-mode)
        (setq harness-ui-insights--period harness-ui-insights-default-period
              harness-ui-insights--project (and (eq harness-ui-insights-default-scope 'current) here)))
      (setq harness-ui-insights--here here)
      (harness-ui-insights--render))
    (harness-ui-display-view buf)
    (harness-ui-insights--load buf)))

(defun harness-ui-insights-refresh ()
  "Compute the report again."
  (interactive)
  (harness-ui-insights--load (current-buffer)))

(defun harness-ui-insights-set-period (period)
  "Show the report of PERIOD (`today', `7d', `30d' or `all')."
  (interactive (list (intern (completing-read "Period: " (mapcar (lambda (p) (symbol-name (car p))) harness-ui-usage--periods)
                                              nil t))))
  (setq harness-ui-insights--period period)
  (harness-ui-insights--load (current-buffer)))

(defun harness-ui-insights-cycle-period ()
  "Show the report of the next period."
  (interactive)
  (harness-ui-insights-set-period (harness-ui-usage--cycle harness-ui-insights--period harness-ui-usage--periods)))

(defun harness-ui-insights--read-project ()
  "Read the project to narrow the report to; nil for every project."
  (let* ((all "Every project")
         (here (and harness-ui-insights--here
                    (format "This project (%s)" (abbreviate-file-name harness-ui-insights--here))))
         (choices (delete-dups (append (list all) (and here (list here))
                                       (mapcar #'abbreviate-file-name harness-ui-insights--projects))))
         (choice (completing-read "Insights for: " choices nil nil nil nil all)))
    (cond ((or (string-empty-p choice) (equal choice all)) nil)
          ((equal choice here) harness-ui-insights--here)
          (t (file-name-as-directory (expand-file-name choice))))))

(defun harness-ui-insights-set-project (project)
  "Narrow the report to PROJECT, a directory with its git worktrees.
nil covers every project.  Interactively, read it with completion."
  (interactive (list (harness-ui-insights--read-project)))
  (setq harness-ui-insights--project project)
  (harness-ui-insights--load (current-buffer)))

(defun harness-ui-insights-write ()
  "Have your model write the summary of the report again."
  (interactive)
  (let ((data harness-ui-insights--data))
    (cond ((null data) (user-error "The report is still being computed"))
          ((equal (format "%s" (plist-get data :narrative-mode)) "nil")
           (user-error "Written summaries are off (harness-insights-narrative)"))
          ((not (harness-ui-insights--active-p data))
           (user-error "Nothing happened in this period to write about"))
          (harness-ui-insights--writing (message "The summary is being written"))
          (t (harness-ui-insights--write (current-buffer) t)))))

(defun harness-ui-insights-open ()
  "Open the session of the session or task line at point, or press its button."
  (interactive)
  (let ((sid (get-text-property (point) 'harness-ui-insights-session))
        (task (get-text-property (point) 'harness-ui-insights-task)))
    (cond (sid (harness-ui-usage--open-session sid))
          (task (user-error "Task %s has no session to open" task))
          ((button-at (point)) (push-button))
          (t (user-error "Nothing to open here")))))

(defun harness-ui-insights-mouse-open (event)
  "Open what was clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (harness-ui-insights-open))

;;;; Live refresh

(defun harness-ui-insights--redraw ()
  "Compute the report again after a reload or reconnect."
  (when-let* ((buf (get-buffer harness-ui-insights--buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-insights-mode)
        (harness-ui-insights-mode)
        (setq harness-ui-insights--period harness-ui-insights-default-period)))
    (harness-ui-insights--load buf)))

;;;; Module

(defun harness-ui-insights--init ()
  "Wire the report into the UI."
  (add-hook 'harness-ui-redraw-hook #'harness-ui-insights--redraw)
  ;; A, not I: I is non-interactive mode for every session, beside i
  ;; for one.
  (define-key harness-ui-map (kbd "A") #'harness-insights))

(harness-define-module 'ui-insights
		       :doc "The Insights report: figures and a written summary of your work with the agents, for any provider."
		       :requires '(ui ui-usage)
		       :init #'harness-ui-insights--init)

(provide 'harness-ui-insights)
;;; harness-ui-insights.el ends here
