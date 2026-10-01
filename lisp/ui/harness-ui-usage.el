;;; harness-ui-usage.el --- Cost and usage dashboard  -*- lexical-binding: t; -*-

;;; Commentary:

;; One buffer, "*harness usage*", laid out top to bottom:
;;
;;   header line   period selector [Today] [7 days] [30 days] [All] and
;;                 the group-by selector [Project] [Model] [Session] [Day]
;;   totals strip  cost · input · output · cache read · cache write · calls
;;   chart         an SVG column chart of cost per day (per hour for
;;                 Today) with an image map so hovering a column shows
;;                 its date, cost and calls
;;   table         `_harness/usage/summary' rows sorted by cost with a
;;                 cost share bar
;;   budgets       every budget with a meter coloured by how much of it
;;                 is spent, plus [Add budget] [Remove] [Plan]
;;
;; Why one buffer rather than a chart window stacked over a
;; `tabulated-list-mode' window: the dashboard is read as a whole and
;; scrolled as a whole; a split would leave the chart pinned while the
;; table scrolls, needs two quit keys and two redraw paths, and the
;; table here is small and fixed (sorted by cost) so the sorting and
;; column machinery of `tabulated-list-mode' would buy nothing.  The
;; table is drawn with `format' in aligned columns under a header row.
;;
;; Everything arrives through ACP and is drawn only when all requests
;; of a refresh have settled; the buffer shows a loading line before
;; the first paint.  Charts and meters are SVG (`svg.el') with text
;; fallbacks for terminals; colours are read from the current theme.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'svg)
(require 'button)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defgroup harness-ui-usage nil
  "The usage and cost dashboard." :group 'harness-ui)

(defcustom harness-ui-usage-buffer-name "*harness usage*"
  "Name of the dashboard buffer."
  :type 'string :group 'harness-ui-usage)

(defcustom harness-ui-usage-chart-height 150
  "Pixel height of the cost chart."
  :type 'integer :group 'harness-ui-usage)

(defcustom harness-ui-usage-default-period '7d
  "Period shown when the dashboard opens: `today', `7d', `30d' or `all'."
  :type '(choice (const today) (const 7d) (const 30d) (const all))
  :group 'harness-ui-usage)

(defface harness-usage-total-face '((t :inherit bold :height 1.3))
  "The headline figures of the totals strip." :group 'harness-ui-usage)
(defface harness-usage-heading-face '((t :inherit bold :height 1.05))
  "Section headings." :group 'harness-ui-usage)
(defface harness-usage-table-header-face '((t :inherit (bold shadow) :underline t))
  "The header row of the table." :group 'harness-ui-usage)
(defface harness-usage-selected-face '((t :inherit (bold highlight)))
  "The selected period or grouping in the header line." :group 'harness-ui-usage)

(defconst harness-ui-usage--periods
  '((today "Today" "Since midnight, per hour")
    (7d "7 days" "The last seven days")
    (30d "30 days" "The last thirty days")
    (all "All" "Everything ever recorded"))
  "Periods as (SYMBOL LABEL HELP).")

(defconst harness-ui-usage--groups
  '((project "Project") (model "Model") (session "Session") (day "Day"))
  "Groupings as (SYMBOL LABEL).")

;;;; Colours

(defun harness-ui-usage--dark-p ()
  "Non-nil when the current theme has a dark background."
  (eq (frame-parameter nil 'background-mode) 'dark))

(defun harness-ui-usage--color (role)
  "Return the colour for ROLE in the current theme.
ROLE is `accent', `warning', `danger', `text', `muted' or `grid'."
  (let ((dark (harness-ui-usage--dark-p)))
    (pcase role
      ('accent (if dark "#3987e5" "#2a78d6"))
      ('warning (if dark "#c98500" "#eda100"))
      ('danger (if dark "#e66767" "#e34948"))
      ('text (or (face-attribute 'default :foreground nil t) (if dark "white" "black")))
      ('muted (let ((c (face-attribute 'shadow :foreground nil t)))
                (if (and (stringp c) (not (equal c "unspecified"))) c (if dark "#a0a0a0" "#707070"))))
      ('grid (let ((c (face-attribute 'shadow :foreground nil t)))
               (if (and (stringp c) (not (equal c "unspecified"))) c (if dark "#606060" "#c0c0c0")))))))

(defun harness-ui-usage--font ()
  "Return the font family for SVG text."
  (let ((f (face-attribute 'default :family nil t)))
    (if (and (stringp f) (not (equal f "unspecified"))) f "sans-serif")))

(defun harness-ui-usage--graphic-p ()
  "Non-nil when SVG can be shown in the buffer's frame."
  (let ((win (get-buffer-window (current-buffer) t)))
    (and (display-graphic-p (if win (window-frame win) (selected-frame)))
         (image-type-available-p 'svg))))

;;;; Buffer state

(defvar-local harness-ui-usage--period nil "Selected period symbol.")
(defvar-local harness-ui-usage--group nil "Selected group-by symbol.")
(defvar-local harness-ui-usage--data nil "Last results: (:totals :series :summary :budgets :statuses).")
(defvar-local harness-ui-usage--loading nil "Non-nil while requests are in flight.")
(defvar-local harness-ui-usage--error nil "Last error message.")
(defvar-local harness-ui-usage--generation 0 "Counter to drop stale responses.")

;;;; Periods

(defun harness-ui-usage--midnight (days-ago)
  "Return the float time of local midnight DAYS-AGO days before today."
  (let* ((now (decode-time))
         (today (encode-time (list 0 0 0 (decoded-time-day now) (decoded-time-month now)
                                   (decoded-time-year now) nil -1 nil))))
    (- (float-time today) (* days-ago 86400))))

(defun harness-ui-usage--since (period)
  "Return the start time of PERIOD, or nil for all time."
  (pcase period
    ('today (harness-ui-usage--midnight 0))
    ('7d (harness-ui-usage--midnight 6))
    ('30d (harness-ui-usage--midnight 29))
    (_ nil)))

(defun harness-ui-usage--filters ()
  "Return the request filters for the selected period."
  (when-let* ((since (harness-ui-usage--since harness-ui-usage--period)))
    (list :since since)))

;;;; Data

(defun harness-ui-usage--implicit-budget-ids ()
  "Return \"session:SID\" ids of cached sessions that carry a budget."
  (mapcar (lambda (s) (concat "session:" (plist-get s :id)))
          (harness-ui-sessions (lambda (s) (let ((b (plist-get s :budget)))
                                             (and (listp b) (numberp (plist-get b :amount))))))))

(defun harness-ui-usage--load (buffer)
  "Request everything the dashboard shows and render BUFFER when it arrives."
  (with-current-buffer buffer
    (let* ((gen (cl-incf harness-ui-usage--generation))
           (filters (harness-ui-usage--filters))
           (bucket (if (eq harness-ui-usage--period 'today) "hour" "day"))
           (group (symbol-name harness-ui-usage--group))
           (fail (lambda (e)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (when (= gen harness-ui-usage--generation)
                         (setq harness-ui-usage--loading nil
                               harness-ui-usage--error (harness-error-message e))
                         (harness-ui-usage--render)))))))
      (setq harness-ui-usage--loading t harness-ui-usage--error nil)
      (setq header-line-format (harness-ui-usage--header))
      (harness-then
       (harness-all (list (harness-ui-request "_harness/usage/totals" filters)
                          (harness-ui-request "_harness/usage/series" (append (list :bucket bucket) filters))
                          (harness-ui-request "_harness/usage/summary" (append (list :group-by group) filters))
                          (harness-ui-request "_harness/usage/budgets" nil)))
       (lambda (results)
         (pcase-let ((`(,totals ,series ,summary ,budgets) results))
           (let ((ids (append (mapcar (lambda (b) (plist-get b :id)) budgets)
                              (harness-ui-usage--implicit-budget-ids))))
             (harness-then
              (harness-all (mapcar (lambda (id)
                                     (harness-catch (harness-ui-request "_harness/usage/budget-status" (list :id id))
                                                    (lambda (_) nil)))
                                   ids))
              (lambda (statuses)
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (when (= gen harness-ui-usage--generation)
                      (setq harness-ui-usage--data
                            (list :totals totals :series series :summary summary
                                  :budgets budgets :statuses (delq nil statuses))
                            harness-ui-usage--loading nil)
                      (harness-ui-usage--render)))))
              fail))))
       fail))))

;;;; SVG pieces

(defun harness-ui-usage--rounded-top (svg x y w h r &rest props)
  "Draw on SVG a bar at X Y of size W×H with top corners rounded by R.
PROPS are passed to `svg-node'."
  (let ((r (min r (/ w 2.0) h)))
    (apply #'svg-node svg 'path
           :d (format "M %s %s v %s a %s %s 0 0 1 %s %s h %s a %s %s 0 0 1 %s %s v %s z"
                      x (+ y h) (- (- h r)) r r r (- r) (- w (* 2 r)) r r r r (- h r))
           props)))

(defun harness-ui-usage--bucket-label (key bucket &optional long)
  "Return a short axis label for series KEY of BUCKET; LONG for tooltips."
  (cond
   ((eq bucket 'hour)
    (if (string-match "\\([0-9][0-9]\\):00\\'" key)
        (if long (format "%s:00" (match-string 1 key)) (format "%sh" (match-string 1 key)))
      key))
   ((string-match "\\`\\([0-9]+\\)-\\([0-9]+\\)-\\([0-9]+\\)" key)
    (let* ((m (string-to-number (match-string 2 key)))
           (d (string-to-number (match-string 3 key)))
           (month (aref ["Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"] (1- (max 1 (min 12 m))))))
      (if long (format "%s %d, %s" month d (match-string 1 key)) (format "%s %d" month d))))
   (t key)))

(defun harness-ui-usage--nice-max (value)
  "Return a round number at or above VALUE for the top of the y axis."
  (if (<= value 0) 1.0
    (let* ((mag (expt 10.0 (floor (log value 10))))
           (norm (/ value mag)))
      (* mag (cond ((<= norm 1) 1) ((<= norm 2) 2) ((<= norm 2.5) 2.5) ((<= norm 5) 5) (t 10))))))

(defun harness-ui-usage--chart (series bucket width)
  "Return an SVG image of cost per BUCKET (day or hour) for SERIES.
The image is WIDTH pixels wide."
  (let* ((height harness-ui-usage-chart-height)
         (left 52) (right 8) (top 10) (bottom 22)
         (plot-w (- width left right))
         (plot-h (- height top bottom))
         (n (max 1 (length series)))
         (slot (/ (float plot-w) n))
         (gap (max 2 (min 6 (* slot 0.25))))
         (bar-w (max 1 (min 24 (- slot gap))))
         (max-cost (apply #'max 0.0 (mapcar (lambda (p) (float (or (plist-get p :cost) 0))) series)))
         (top-value (harness-ui-usage--nice-max max-cost))
         (svg (svg-create width height))
         (font (harness-ui-usage--font))
         (muted (harness-ui-usage--color 'muted))
         (grid (harness-ui-usage--color 'grid))
         (accent (harness-ui-usage--color 'accent))
         (label-every (max 1 (ceiling (* n 44) (max 1 plot-w))))
         (map nil))
    ;; Gridlines and y labels at 0, 1/2 and the top.
    (dolist (frac '(0 0.5 1))
      (let ((y (+ top (* plot-h (- 1 frac)))))
        (svg-line svg left y (+ left plot-w) y :stroke-color grid :stroke-width 1 :opacity 0.35)
        (svg-text svg (harness-format-cost (* frac top-value))
                  :x (- left 6) :y (+ y 4) :text-anchor "end" :font-family font :font-size 11 :fill muted)))
    ;; Bars, each with an image-map area covering its whole slot.
    (cl-loop for p in series for i from 0 do
             (let* ((cost (float (or (plist-get p :cost) 0)))
                    (x0 (+ left (* i slot)))
                    (bx (+ x0 (/ (- slot bar-w) 2)))
                    (bh (if (> top-value 0) (* plot-h (/ cost top-value)) 0))
                    (by (+ top (- plot-h bh)))
                    (label (harness-ui-usage--bucket-label (plist-get p :key) bucket))
                    (tip (format "%s\n%s · %d calls · %s in / %s out"
                                 (harness-ui-usage--bucket-label (plist-get p :key) bucket t)
                                 (harness-format-cost cost) (or (plist-get p :calls) 0)
                                 (harness-format-tokens (plist-get p :input))
                                 (harness-format-tokens (plist-get p :output)))))
               (when (> bh 0)
                 (harness-ui-usage--rounded-top svg bx by bar-w (max bh 1.5) 4 :fill accent))
               (when (zerop (mod i label-every))
                 (svg-text svg label :x (+ x0 (/ slot 2)) :y (- height 6) :text-anchor "middle"
                           :font-family font :font-size 11 :fill muted))
               (push (list (cons 'rect (cons (cons (round x0) top) (cons (round (+ x0 slot)) (+ top plot-h))))
                           (intern (format "bar-%d" i))
                           (list 'help-echo tip 'pointer 'hand))
                     map)))
    (svg-line svg left (+ top plot-h) (+ left plot-w) (+ top plot-h) :stroke-color grid :stroke-width 1)
    (svg-image svg :ascent 'center :scale 1 :map (nreverse map))))

(defun harness-ui-usage--bar (fraction width color &optional track)
  "Return a small SVG bar image showing FRACTION of WIDTH filled with COLOR.
TRACK is the colour of the unfilled part (default COLOR at low opacity)."
  (let* ((h 9)
         (svg (svg-create width h))
         (fill-w (max 0 (min width (* width (max 0.0 (min 1.0 fraction)))))))
    (if track
        (svg-rectangle svg 0 0 width h :rx 3 :fill track)
      (svg-rectangle svg 0 0 width h :rx 3 :fill color :fill-opacity 0.2))
    (when (> fill-w 0)
      (svg-rectangle svg 0 0 (max fill-w 3) h :rx 3 :fill color))
    (svg-image svg :ascent 'center :scale 1)))

(defun harness-ui-usage--meter-string (fraction color width-px cols &optional help)
  "Return a meter for FRACTION: an SVG of WIDTH-PX pixels or COLS text cells.
COLOR is the fill colour and HELP the tooltip."
  (if (harness-ui-usage--graphic-p)
      (propertize (make-string cols ?\s) 'display (harness-ui-usage--bar fraction width-px color)
                  'help-echo help)
    (let* ((filled (round (* cols (max 0.0 (min 1.0 fraction))))))
      (concat (propertize (make-string filled ?█) 'face (list :foreground color) 'help-echo help)
              (propertize (make-string (- cols filled) ?░) 'face 'harness-dim-face 'help-echo help)))))

;;;; Rendering

(defun harness-ui-usage--segment (label command selected help)
  "Return a header-line segment LABEL running COMMAND with tooltip HELP.
SELECTED highlights it."
  (propertize (format " %s " label)
              'face (if selected 'harness-usage-selected-face 'harness-label-face)
              'mouse-face 'mode-line-highlight
              'help-echo help
              'local-map (harness-ui-mouse-keymap command)))

(defun harness-ui-usage--header ()
  "Return the header line with the period and grouping selectors."
  (append
   (list (propertize " Usage " 'face 'harness-usage-heading-face))
   (mapcar (lambda (p)
             (harness-ui-usage--segment (nth 1 p) (harness-ui-usage--period-command (car p))
                                        (eq (car p) harness-ui-usage--period) (nth 2 p)))
           harness-ui-usage--periods)
   (list (propertize "  by" 'face 'harness-dim-face))
   (mapcar (lambda (g)
             (harness-ui-usage--segment (nth 1 g) (harness-ui-usage--group-command (car g))
                                        (eq (car g) harness-ui-usage--group)
                                        (format "Group the table by %s" (downcase (nth 1 g)))))
           harness-ui-usage--groups)
   (list "  "
         (cond (harness-ui-usage--loading (propertize "loading… " 'face 'harness-dim-face))
               (harness-ui-usage--error (propertize (format "error: %s " harness-ui-usage--error) 'face 'error))
               (t ""))
         (harness-ui-usage--segment "g" #'harness-ui-usage-refresh nil "Refresh")
         (harness-ui-usage--segment "q" #'quit-window nil "Quit"))))

(defun harness-ui-usage--period-command (period)
  "Return a command selecting PERIOD."
  (lambda () (interactive) (harness-ui-usage-set-period period)))

(defun harness-ui-usage--group-command (group)
  "Return a command selecting GROUP."
  (lambda () (interactive) (harness-ui-usage-set-group group)))

(defun harness-ui-usage--insert-totals (totals)
  "Insert the totals strip for TOTALS."
  (let ((cell (lambda (value label)
                (concat (propertize value 'face 'harness-usage-total-face)
                        " " (propertize label 'face 'harness-dim-face) "    "))))
    (insert "\n "
            (funcall cell (harness-format-cost (plist-get totals :cost)) "cost")
            (funcall cell (harness-format-tokens (plist-get totals :input)) "input")
            (funcall cell (harness-format-tokens (plist-get totals :output)) "output")
            (funcall cell (harness-format-tokens (plist-get totals :cache-read)) "cache read")
            (funcall cell (harness-format-tokens (plist-get totals :cache-write)) "cache write")
            (funcall cell (format "%d" (or (plist-get totals :calls) 0)) "calls")
            "\n\n")))

(defun harness-ui-usage--chart-width ()
  "Return the pixel width available for the chart."
  (let ((win (get-buffer-window (current-buffer) t)))
    (max 320 (min 960 (- (if win (window-body-width win t) 800) 24)))))

(defun harness-ui-usage--insert-chart (series)
  "Insert the cost chart for SERIES."
  (let ((bucket (if (eq harness-ui-usage--period 'today) 'hour 'day)))
    (insert " " (propertize (format "Cost per %s" bucket) 'face 'harness-usage-heading-face) "\n")
    (if (harness-ui-usage--graphic-p)
        (insert " " (propertize " " 'display (harness-ui-usage--chart series bucket (harness-ui-usage--chart-width))
                                'help-echo "Hover a column for its cost")
                "\n\n")
      ;; Text fallback: one line per bucket with a proportional bar.
      (let ((max-cost (apply #'max 0.0 (mapcar (lambda (p) (float (or (plist-get p :cost) 0))) series))))
        (dolist (p (last series 14))
          (let ((cost (float (or (plist-get p :cost) 0))))
            (insert (format "  %-8s %8s  " (harness-ui-usage--bucket-label (plist-get p :key) bucket)
                            (harness-format-cost cost))
                    (harness-ui-usage--meter-string (if (> max-cost 0) (/ cost max-cost) 0)
                                                    (harness-ui-usage--color 'accent) 200 30)
                    "\n")))
        (insert "\n")))))

(defun harness-ui-usage--row-label (key)
  "Return the display label of table row KEY for the current grouping."
  (pcase harness-ui-usage--group
    ('project (let ((p (abbreviate-file-name (or key ""))))
                (harness-truncate-middle (if (string-empty-p p) "(no project)" p) 40)))
    ('model (harness-ui-model-label key))
    ('session (let ((s (harness-ui-session key)))
                (if s (harness-truncate-end (or (plist-get s :name) (format "unnamed (%s)" (substring key 0 (min 8 (length key))))) 40)
                  (format "%s" (harness-truncate-end (or key "?") 40)))))
    ('day (harness-ui-usage--bucket-label key 'day t))
    (_ (format "%s" key))))

(defun harness-ui-usage--insert-table (summary)
  "Insert the summary table for SUMMARY rows."
  (let* ((rows (sort (copy-sequence summary)
                     (lambda (a b) (> (or (plist-get a :cost) 0) (or (plist-get b :cost) 0)))))
         (total (apply #'+ (mapcar (lambda (r) (float (or (plist-get r :cost) 0))) rows)))
         (labels (mapcar (lambda (r) (harness-ui-usage--row-label (plist-get r :key))) rows))
         (kw (max 8 (apply #'max 0 (mapcar #'string-width labels))))
         (fmt (format " %%-%ds  %%8s  %%-14s %%8s %%8s %%9s %%9s %%6s\n" kw)))
    (insert " " (propertize (format "By %s" (downcase (nth 1 (assq harness-ui-usage--group harness-ui-usage--groups))))
                            'face 'harness-usage-heading-face)
            "\n")
    (insert (propertize (format fmt (nth 1 (assq harness-ui-usage--group harness-ui-usage--groups))
                                "Cost" "Share" "Input" "Output" "Cache r" "Cache w" "Calls")
                        'face 'harness-usage-table-header-face))
    (cl-loop for r in rows for label in labels do
             (let* ((cost (float (or (plist-get r :cost) 0)))
                    (share (if (> total 0) (/ cost total) 0))
                    (start (point)))
               (insert (format fmt
                               (if (eq harness-ui-usage--group 'session)
                                   (propertize label 'face 'button 'harness-ui-usage-session (plist-get r :key)
                                               'help-echo "RET / mouse-1: open this session")
                                 label)
                               (harness-format-cost cost)
                               (concat (harness-ui-usage--meter-string share (harness-ui-usage--color 'accent) 64 8
                                                                       (format "%.0f%% of the period's cost" (* 100 share)))
                                       (propertize (format " %3.0f%%" (* 100 share)) 'face 'harness-dim-face))
                               (harness-format-tokens (plist-get r :input))
                               (harness-format-tokens (plist-get r :output))
                               (harness-format-tokens (plist-get r :cache-read))
                               (harness-format-tokens (plist-get r :cache-write))
                               (format "%d" (or (plist-get r :calls) 0))))
               (add-text-properties start (point) (list 'harness-ui-usage-row r 'mouse-face 'highlight))))
    (when (null rows)
      (insert (propertize "  nothing in this period\n" 'face 'harness-dim-face)))
    (insert "\n")))

(defun harness-ui-usage--budget-label (budget)
  "Return a label for BUDGET."
  (or (plist-get budget :label)
      (let* ((scope (format "%s" (plist-get budget :scope)))
             (period (plist-get budget :period))
             (target (plist-get budget :target))
             (subject (pcase scope
                        ("session" (let ((s (harness-ui-session target)))
                                     (or (and s (plist-get s :name)) (format "session %s" (substring (or target "?") 0 (min 8 (length (or target "?"))))))))
                        ("project" (file-name-nondirectory (directory-file-name (or target "?"))))
                        (_ "everything"))))
        (string-trim (format "%s %s" (pcase (format "%s" period)
                                       ("day" "daily") ("week" "weekly") ("month" "monthly") (_ ""))
                             subject)))))

(defun harness-ui-usage--insert-budget (status)
  "Insert one budget line for STATUS."
  (let* ((budget (plist-get status :budget))
         (fraction (float (or (plist-get status :fraction) 0)))
         (color (harness-ui-usage--color (cond ((>= fraction 1) 'danger) ((>= fraction 0.8) 'warning) (t 'accent))))
         (hard (harness-json-true-p (plist-get status :hard)))
         (start (point)))
    (insert (format "  %-28s " (harness-truncate-end (harness-ui-usage--budget-label budget) 28))
            (harness-ui-usage--meter-string fraction color 120 15
                                            (format "%s of %s spent" (harness-format-cost (plist-get status :spent))
                                                    (harness-format-cost (plist-get status :amount))))
            (propertize (format " %3.0f%%" (* 100 fraction)) 'face (if (>= fraction 0.8) 'warning 'default))
            (propertize (format "  %s / %s" (harness-format-cost (plist-get status :spent))
                                (harness-format-cost (plist-get status :amount)))
                        'face 'default)
            (propertize (format "  %s left" (harness-format-cost (max 0 (or (plist-get status :remaining) 0)))) 'face 'harness-dim-face)
            (if (plist-get status :per-day)
                (propertize (format "  %s/day · %s days left" (harness-format-cost (plist-get status :per-day))
                                    (or (plist-get status :days-left) "?"))
                            'face 'harness-dim-face)
              "")
            (propertize (if hard "  hard" "  soft") 'face (if hard 'warning 'harness-dim-face)
                        'help-echo (if hard "Turns are blocked once this budget is spent"
                                     "Warnings only at 80% and 100%"))
            "  ")
    (unless (plist-get budget :implicit)
      (harness-ui-button "[remove]" #'harness-ui-usage-remove-budget :help "Remove this budget (d)"))
    (insert " ")
    (harness-ui-button "[plan]" #'harness-ui-usage-plan :help "Split this budget over its period per day (P)")
    (insert "\n")
    (add-text-properties start (point) (list 'harness-ui-usage-budget status))))

(defun harness-ui-usage--insert-budgets (statuses)
  "Insert the budgets section for STATUSES."
  (insert " " (propertize "Budgets" 'face 'harness-usage-heading-face) "  ")
  (harness-ui-button "[add budget]" #'harness-ui-usage-add-budget :help "Create a session, project or period budget (a)")
  (insert " ")
  (harness-ui-button "[plan]" #'harness-ui-usage-plan :help "Split an amount over a period by day (P)")
  (insert "\n")
  (if statuses
      (dolist (st (sort (copy-sequence statuses)
                        (lambda (a b) (> (or (plist-get a :fraction) 0) (or (plist-get b :fraction) 0)))))
        (harness-ui-usage--insert-budget st))
    (insert (propertize "  no budgets yet — a budget warns at 80% and 100%, a hard one stops the next turn\n"
                        'face 'harness-dim-face)))
  (insert "\n"))

(defun harness-ui-usage--render ()
  "Redraw the dashboard from `harness-ui-usage--data', keeping the line."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos))
        (data harness-ui-usage--data))
    (erase-buffer)
    (setq header-line-format (harness-ui-usage--header))
    (cond
     ((and (null data) harness-ui-usage--loading)
      (insert "\n " (propertize "Loading usage…" 'face 'harness-dim-face) "\n"))
     ((and (null data) harness-ui-usage--error)
      (insert "\n " (propertize (format "Could not load usage: %s" harness-ui-usage--error) 'face 'error) "\n"))
     (t
      (let ((totals (plist-get data :totals)))
        (harness-ui-usage--insert-totals totals)
        (if (zerop (or (plist-get totals :calls) 0))
            (insert " " (propertize (format "No usage recorded %s. Costs appear here after the first model call.\n\n"
                                            (if (eq harness-ui-usage--period 'all) "yet"
                                              (concat "in this period (" (downcase (nth 1 (assq harness-ui-usage--period harness-ui-usage--periods))) ")")))
                                    'face 'harness-dim-face))
          (harness-ui-usage--insert-chart (plist-get data :series))
          (harness-ui-usage--insert-table (plist-get data :summary))))
      (harness-ui-usage--insert-budgets (plist-get data :statuses))))
    (goto-char (point-min))
    (forward-line (1- line))))

;;;; Mode and commands

(defvar harness-ui-usage-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'harness-ui-usage-refresh)
    (define-key map (kbd "t") #'harness-ui-usage-cycle-period)
    (define-key map (kbd "b") #'harness-ui-usage-cycle-group)
    (define-key map (kbd "a") #'harness-ui-usage-add-budget)
    (define-key map (kbd "d") #'harness-ui-usage-remove-budget)
    (define-key map (kbd "P") #'harness-ui-usage-plan)
    (define-key map (kbd "RET") #'harness-ui-usage-open)
    (define-key map [mouse-1] #'harness-ui-usage-mouse-open)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-usage-mode'.")

(define-derived-mode harness-ui-usage-mode special-mode "Usage"
  "Major mode of the usage and cost dashboard."
  (setq truncate-lines t
        buffer-read-only t)
  (add-hook 'window-configuration-change-hook #'harness-ui-usage--on-resize nil t))

(defun harness-ui-usage--on-resize ()
  "Redraw so the chart fits the new window width."
  (when harness-ui-usage--data
    (let ((b (current-buffer)))
      (harness-debounce (list 'harness-ui-usage-resize b) 0.2
                        (lambda () (when (buffer-live-p b) (with-current-buffer b (harness-ui-usage--render))))))))

;;;###autoload
(defun harness-usage ()
  "Show the usage and cost dashboard."
  (interactive)
  (let ((buf (get-buffer-create harness-ui-usage-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-usage-mode)
        (harness-ui-usage-mode)
        (setq harness-ui-usage--period harness-ui-usage-default-period
              harness-ui-usage--group 'project))
      (harness-ui-usage--render))
    (harness-ui-display-view buf)
    (harness-ui-usage--load buf)))

(defun harness-ui-usage-refresh ()
  "Reload the dashboard."
  (interactive)
  (harness-ui-usage--load (current-buffer)))

(defun harness-ui-usage-set-period (period)
  "Show PERIOD (`today', `7d', `30d' or `all')."
  (interactive (list (intern (completing-read "Period: " (mapcar (lambda (p) (symbol-name (car p))) harness-ui-usage--periods) nil t))))
  (setq harness-ui-usage--period period)
  (harness-ui-usage--load (current-buffer)))

(defun harness-ui-usage-set-group (group)
  "Group the table by GROUP (`project', `model', `session' or `day')."
  (interactive (list (intern (completing-read "Group by: " (mapcar (lambda (g) (symbol-name (car g))) harness-ui-usage--groups) nil t))))
  (setq harness-ui-usage--group group)
  (harness-ui-usage--load (current-buffer)))

(defun harness-ui-usage--cycle (current items)
  "Return the item after CURRENT in ITEMS (a list of lists keyed by car)."
  (let ((keys (mapcar #'car items)))
    (or (cadr (memq current keys)) (car keys))))

(defun harness-ui-usage-cycle-period ()
  "Show the next period."
  (interactive)
  (harness-ui-usage-set-period (harness-ui-usage--cycle harness-ui-usage--period harness-ui-usage--periods)))

(defun harness-ui-usage-cycle-group ()
  "Group the table by the next dimension."
  (interactive)
  (harness-ui-usage-set-group (harness-ui-usage--cycle harness-ui-usage--group harness-ui-usage--groups)))

(defun harness-ui-usage--open-session (sid)
  "Open session SID where the dashboard is, as it is (an inactive one stays so).
Usage outlives deleted sessions, so the session is looked up first."
  (let ((open (harness-ui-session-opener)))
    (harness-ui-call "_harness/session/get" (list :id sid)
                     (lambda (_) (funcall open sid)))))

(defun harness-ui-usage-open ()
  "Open the session of the table row at point, or press the button at point."
  (interactive)
  (cond
   ((get-text-property (point) 'harness-ui-usage-session)
    (harness-ui-usage--open-session (get-text-property (point) 'harness-ui-usage-session)))
   ((button-at (point)) (push-button))
   ((and (eq harness-ui-usage--group 'session) (get-text-property (point) 'harness-ui-usage-row))
    (harness-ui-usage--open-session (plist-get (get-text-property (point) 'harness-ui-usage-row) :key)))
   (t (user-error "Nothing to open here"))))

(defun harness-ui-usage-mouse-open (event)
  "Open what was clicked in EVENT."
  (interactive "e")
  (mouse-set-point event)
  (harness-ui-usage-open))

(defun harness-ui-usage--budget-at-point ()
  "Return the budget status plist on the current line, or nil."
  (get-text-property (point) 'harness-ui-usage-budget))

(defun harness-ui-usage--read-budget ()
  "Interactively build a budget plist."
  (let* ((scope (cadr (read-multiple-choice "Budget scope"
                                            '((?s "session" "One session's spending")
                                              (?p "project" "All sessions of a project")
                                              (?t "period" "Everything within a calendar period")))))
         (target (pcase scope
                   ("session" (plist-get (harness-ui-read-session "Session: ") :id))
                   ("project" (expand-file-name (read-directory-name "Project root: " (harness-ui--default-directory) nil t)))
                   (_ nil)))
         (amount (read-number "Amount (USD): "))
         (period (if (equal scope "period")
                     (cadr (read-multiple-choice "Period" '((?d "day") (?w "week") (?m "month"))))
                   (let ((p (cadr (read-multiple-choice "Reset every" '((?n "none" "The budget covers all time")
                                                                        (?d "day") (?w "week") (?m "month"))))))
                     (unless (equal p "none") p))))
         (days (when period (if (y-or-n-p "Plan over business days only? ") "business" "all")))
         (hard (y-or-n-p "Hard budget (block the next turn once it is spent)? "))
         (label (read-string "Label (optional): ")))
    (append (list :scope scope :amount amount :hard (if hard t :false))
            (and target (list :target target))
            (and period (list :period period))
            (and days (list :days days))
            (and (not (string-empty-p label)) (list :label label)))))

(defun harness-ui-usage-add-budget ()
  "Create a budget through a short series of prompts."
  (interactive)
  (let ((budget (harness-ui-usage--read-budget))
        (buf (current-buffer)))
    (harness-ui-call "_harness/usage/set-budget" (list :budget budget)
                     (lambda (b)
                       (message "Budget %s created" (or (plist-get b :label) (plist-get b :id)))
                       (when (buffer-live-p buf) (harness-ui-usage--load buf))))))

(defun harness-ui-usage-remove-budget ()
  "Remove the budget on the current line."
  (interactive)
  (let* ((status (or (harness-ui-usage--budget-at-point) (user-error "No budget on this line")))
         (budget (plist-get status :budget))
         (buf (current-buffer)))
    (when (plist-get budget :implicit)
      (user-error "This is the session's own budget; change it on the session"))
    (when (yes-or-no-p (format "Remove budget %s? " (harness-ui-usage--budget-label budget)))
      (harness-ui-call "_harness/usage/remove-budget" (list :id (plist-get budget :id))
                       (lambda (_) (message "Budget removed") (when (buffer-live-p buf) (harness-ui-usage--load buf)))))))

(defun harness-ui-usage-plan ()
  "Show how an amount splits over a period, day by day.
Defaults come from the budget on the current line when there is one."
  (interactive)
  (let* ((status (harness-ui-usage--budget-at-point))
         (budget (plist-get status :budget))
         (amount (read-number "Amount (USD): " (or (plist-get budget :amount) 10)))
         (period (let ((default (format "%s" (or (plist-get budget :period) "month"))))
                   (completing-read (format "Period (default %s): " default) '("day" "week" "month") nil t nil nil default)))
         (days (if (y-or-n-p "Business days only? ") "business" "all")))
    (harness-ui-call "_harness/usage/plan-budget" (list :amount amount :period period :days days)
                     (lambda (plan) (harness-ui-usage--show-plan plan amount period days)))))

(defun harness-ui-usage--show-plan (plan amount period days)
  "Display PLAN (a list of (:date :allowance)) for AMOUNT over PERIOD and DAYS."
  (let ((buf (get-buffer-create "*harness budget plan*"))
        (inhibit-read-only t))
    (with-current-buffer buf
      (special-mode)
      (erase-buffer)
      (insert (propertize (format " %s over this %s" (harness-format-cost amount) period) 'face 'harness-usage-heading-face)
              (propertize (format "  (%s days, %d entries)\n\n" days (length plan)) 'face 'harness-dim-face))
      (insert (propertize (format " %-12s %-4s %10s\n" "Date" "Day" "Allowance") 'face 'harness-usage-table-header-face))
      (dolist (p plan)
        (let* ((date (plist-get p :date))
               (allowance (float (or (plist-get p :allowance) 0)))
               (weekday (condition-case nil
                            (format-time-string "%a" (encode-time (parse-time-string (concat date " 12:00:00"))))
                          (error "")))
               (today (equal date (format-time-string "%Y-%m-%d"))))
          (insert (propertize (format " %-12s %-4s %10s%s\n" date weekday (harness-format-cost allowance)
                                      (if today "  ← today" ""))
                              'face (cond (today 'bold) ((zerop allowance) 'harness-dim-face) (t 'default))))))
      (insert "\n" (propertize " q closes this window" 'face 'harness-dim-face) "\n")
      (goto-char (point-min)))
    (pop-to-buffer buf)))

;;;; Live refresh

(defun harness-ui-usage--refresh-soon ()
  "Reload the dashboard buffer if it exists, debounced."
  (when-let* ((buf (get-buffer harness-ui-usage-buffer-name)))
    (harness-debounce 'harness-ui-usage 1.0
                      (lambda () (when (buffer-live-p buf) (harness-ui-usage--load buf))))))

(defun harness-ui-usage--on-event (event _args)
  "Refresh after EVENT changed spending or budgets."
  (when (member event '("usage/budget-warning" "agent/turn-ended" "usage/budgets-changed" "usage/recorded"))
    (harness-ui-usage--refresh-soon)))

(defun harness-ui-usage--redraw ()
  "Rebuild the dashboard after a reload or reconnect."
  (when-let* ((buf (get-buffer harness-ui-usage-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-usage-mode)
        (harness-ui-usage-mode)
        (setq harness-ui-usage--period harness-ui-usage-default-period harness-ui-usage--group 'project)))
    (harness-ui-usage--load buf)))

;;;; Module

(defun harness-ui-usage--init ()
  "Wire the dashboard into the UI."
  (add-hook 'harness-ui-event-functions #'harness-ui-usage--on-event)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-usage--redraw)
  (define-key harness-ui-map (kbd "u") #'harness-usage))

(harness-define-module 'ui-usage
  :doc "Usage and cost dashboard with charts and budgets."
  :requires '(ui)
  :init #'harness-ui-usage--init)

(provide 'harness-ui-usage)
;;; harness-ui-usage.el ends here
