;;; harness-ui-usage.el --- Cost and usage dashboard  -*- lexical-binding: t; -*-

;;; Commentary:

;; One buffer, "*harness usage*", laid out top to bottom:
;;
;;   header line   period selector [Today] [7 days] [30 days] [All] and
;;                 the group-by selector [Project] [Model] [Session] [Day]
;;                 [Billing]
;;   totals strip  billed cost, what a plan covered, input, output,
;;                 cache read, cache write and calls
;;   chart         an SVG column chart of cost per day (per hour for
;;                 Today) with an image map so hovering a column shows
;;                 its date, cost and calls; what a subscription covered
;;                 stacks on top in a lighter shade
;;   table         `_harness/usage/summary' rows sorted by their value at
;;                 API prices, with the billed cost, what a plan covered
;;                 and a share bar
;;   plan          how each provider bills (per token, or a plan such as
;;                 Claude Max) and the plan's quota windows as meters
;;                 with their reset times, plus its extra usage
;;   fallback      the providers and models to carry on with when one
;;                 runs out of quota or money, in order, each with its
;;                 state and [up] [down] [try now] [remove], and [add];
;;                 edits `harness-fallback-models' (see the fallback
;;                 module), saved through `config/set' at the global
;;                 scope
;;   budgets       every budget with a meter coloured by how much of it
;;                 is spent, including any baseline (what was spent
;;                 outside the harness, set by hand), plus [Add budget]
;;                 [Baseline] [Remove] [Plan]; with an Anthropic Admin
;;                 API key, I offers the month's API cost as a month
;;                 budget's baseline
;;
;; Cost always means money billed.  A call a subscription pays for costs
;; nothing; its value at API prices shows as covered by the plan.
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
;; the first paint.  The plan section comes from the UI's quota cache
;; and redraws whenever a provider reports new quota.  Charts and meters
;; are SVG (`svg.el') with text fallbacks for terminals; colours are
;; read from the current theme.

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

(defconst harness-ui-usage--buffer-name "*harness usage*"
  "Name of the dashboard buffer.")

(defconst harness-ui-usage--chart-height 150
  "Pixel height of the cost chart.")

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
  '((project "Project") (model "Model") (session "Session") (day "Day") (billing "Billing"))
  "Groupings as (SYMBOL LABEL).")

(defconst harness-ui-usage--billing-labels
  '(("api" . "API, billed per token")
    ("subscription" . "Subscription, covered by the plan")
    ("extra-usage" . "Extra usage, billed beyond the plan")
    ("" . "Not recorded"))
  "Table labels of the billing keys of `usage/summary'.")

;;;; Colours

(defun harness-ui-usage--dark-p ()
  "Non-nil when the current theme has a dark background."
  (eq (frame-parameter nil 'background-mode) 'dark))

(defun harness-ui-usage--color (role)
  "Return the colour for ROLE in the current theme.
ROLE is `accent', `plan' (a light accent for what a plan covered),
`warning', `danger', `text', `muted' or `grid'."
  (let ((dark (harness-ui-usage--dark-p)))
    (pcase role
      ('accent (if dark "#3987e5" "#2a78d6"))
      ('plan (if dark "#2b4a70" "#a9c9ef"))
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
(defvar-local harness-ui-usage--api-cost nil
  "This month's API cost fetched for a budget, offered as its baseline.
The answer of `_harness/usage/fetch-api-cost' plus :budget-id, or nil.")

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
      ;; Plan quota arrives through the UI's cache and redraws on its own.
      (harness-ui-refresh-quotas)
      (harness-then
       (harness-all (list (harness-ui-request "_harness/usage/totals" filters)
                          (harness-ui-request "_harness/usage/series" (append (list :bucket bucket) filters))
                          (harness-ui-request "_harness/usage/summary" (append (list :group-by group) filters))
                          (harness-ui-request "_harness/usage/budgets" nil)
                          ;; The fallback module may not be loaded; its
                          ;; section is then left out.
                          (harness-catch (harness-ui-request "_harness/fallback/status" nil)
                                         (lambda (_) nil))))
       (lambda (results)
         (pcase-let ((`(,totals ,series ,summary ,budgets ,fallback) results))
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
                                  :budgets budgets :statuses (delq nil statuses)
                                  :fallback fallback)
                            harness-ui-usage--loading nil)
                      (harness-ui-usage--render)))))
              fail))))
       fail))))

;;;; SVG pieces

(defun harness-ui-usage--rounded-top (svg x y w h r &rest props)
  "Draw on SVG a bar at X Y of size W by H with top corners rounded by R.
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

(defun harness-ui-usage--money-text (point)
  "Describe what series or table POINT cost, and what a plan paid for."
  (let ((covered (harness-usage-covered point)))
    (if (> covered 0)
        (format "%s billed, %s covered by plan"
                (harness-format-cost (plist-get point :cost)) (harness-format-cost covered))
      (harness-format-cost (plist-get point :cost)))))

(defun harness-ui-usage--bar-help (point bucket)
  "Return the tooltip of POINT's chart column for BUCKET.
One line: hovering a column must not grow the echo area, or the chart
would move under the mouse."
  (harness-ui-one-line
   (format "%s\n%s, %d calls, %s in / %s out"
           (harness-ui-usage--bucket-label (plist-get point :key) bucket t)
           (harness-ui-usage--money-text point) (or (plist-get point :calls) 0)
           (harness-format-tokens (plist-get point :input))
           (harness-format-tokens (plist-get point :output)))))

(defun harness-ui-usage--nice-max (value)
  "Return a round number at or above VALUE for the top of the y axis."
  (if (<= value 0) 1.0
    (let* ((mag (expt 10.0 (floor (log value 10))))
           (norm (/ value mag)))
      (* mag (cond ((<= norm 1) 1) ((<= norm 2) 2) ((<= norm 2.5) 2.5) ((<= norm 5) 5) (t 10))))))

(defun harness-ui-usage--chart (series bucket width)
  "Return an SVG image of cost per BUCKET (day or hour) for SERIES.
The image is WIDTH pixels wide.  A column is the bucket's usage at API
prices: the billed part in the accent colour, what a subscription
covered stacked on top in the lighter plan colour."
  (let* ((height harness-ui-usage--chart-height)
         (left 52) (right 8) (top 10) (bottom 22)
         (plot-w (- width left right))
         (plot-h (- height top bottom))
         (n (max 1 (length series)))
         (slot (/ (float plot-w) n))
         (gap (max 2 (min 6 (* slot 0.25))))
         (bar-w (max 1 (min 24 (- slot gap))))
         (max-cost (apply #'max 0.0 (mapcar #'harness-usage-list-cost series)))
         (top-value (harness-ui-usage--nice-max max-cost))
         (svg (svg-create width height))
         (font (harness-ui-usage--font))
         (muted (harness-ui-usage--color 'muted))
         (grid (harness-ui-usage--color 'grid))
         (accent (harness-ui-usage--color 'accent))
         (plan (harness-ui-usage--color 'plan))
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
                    (value (max cost (harness-usage-list-cost p)))
                    (x0 (+ left (* i slot)))
                    (bx (+ x0 (/ (- slot bar-w) 2)))
                    (bh (if (> top-value 0) (* plot-h (/ value top-value)) 0))
                    (by (+ top (- plot-h bh)))
                    (ch (if (> top-value 0) (* plot-h (/ cost top-value)) 0))
                    (label (harness-ui-usage--bucket-label (plist-get p :key) bucket))
                    (tip (harness-ui-usage--bar-help p bucket)))
               (cond
                ((<= bh 0))
                ((> value cost)
                 ;; The whole column in the plan colour, the billed part over its foot.
                 (harness-ui-usage--rounded-top svg bx by bar-w (max bh 1.5) 4 :fill plan)
                 (when (> ch 0)
                   (svg-rectangle svg bx (+ top (- plot-h ch)) bar-w ch :fill accent)))
                (t (harness-ui-usage--rounded-top svg bx by bar-w (max bh 1.5) 4 :fill accent)))
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
  (let ((cell (lambda (value label &optional help)
                (concat (propertize value 'face 'harness-usage-total-face 'help-echo help)
                        " " (propertize label 'face 'harness-dim-face 'help-echo help) "    ")))
        (covered (harness-usage-covered totals)))
    (insert "\n "
            (funcall cell (harness-format-cost (plist-get totals :cost)) "cost"
                     "Billed: per-token calls and a plan's extra usage")
            (if (> covered 0)
                (funcall cell (harness-format-cost covered) "covered by plan"
                         "What a subscription paid for, at API prices; not billed")
              "")
            (funcall cell (harness-format-tokens (plist-get totals :input)) "input")
            (funcall cell (harness-format-tokens (plist-get totals :output)) "output")
            (funcall cell (harness-format-tokens (plist-get totals :cache-read)) "cache read")
            (funcall cell (harness-format-tokens (plist-get totals :cache-write)) "cache write")
            (funcall cell (format "%d" (or (plist-get totals :calls) 0)) "calls")
            "\n\n")))

(defun harness-ui-usage--chart-image (series bucket)
  "Return the chart of SERIES per BUCKET, sized for the buffer's window.
Images with a map are measured on the selected frame, so the frame that
shows the buffer is selected while it is made: a refresh run from a
timer in a daemon may otherwise find a terminal frame selected."
  (let ((win (get-buffer-window (current-buffer) t)))
    (with-selected-frame (if win (window-frame win) (selected-frame))
      (harness-ui-usage--chart series bucket (harness-ui-usage--chart-width)))))

(defun harness-ui-usage--chart-width ()
  "Return the pixel width available for the chart."
  (let ((win (get-buffer-window (current-buffer) t)))
    (max 320 (min 960 (- (if win (window-body-width win t) 800) 24)))))

(defun harness-ui-usage--insert-chart (series)
  "Insert the cost chart for SERIES, with a legend when a plan covered some."
  (let ((bucket (if (eq harness-ui-usage--period 'today) 'hour 'day)))
    (insert " " (propertize (format "Cost per %s" bucket) 'face 'harness-usage-heading-face))
    (when (cl-some (lambda (p) (> (harness-usage-covered p) 0)) series)
      (insert "   " (propertize "■" 'face (list :foreground (harness-ui-usage--color 'accent)))
              (propertize " billed   " 'face 'harness-dim-face)
              (propertize "■" 'face (list :foreground (harness-ui-usage--color 'plan)))
              (propertize " covered by plan, at API prices" 'face 'harness-dim-face)))
    (insert "\n")
    (if (harness-ui-usage--graphic-p)
        (insert " " (propertize " " 'display (harness-ui-usage--chart-image series bucket)
                                'help-echo "Hover a column for its cost")
                "\n\n")
      ;; Text fallback: one line per bucket with a bar for its value at API prices.
      (let ((max-value (apply #'max 0.0 (mapcar #'harness-usage-list-cost series))))
        (dolist (p (last series 14))
          (let ((value (harness-usage-list-cost p))
                (covered (harness-usage-covered p)))
            (insert (format "  %-8s %8s  " (harness-ui-usage--bucket-label (plist-get p :key) bucket)
                            (harness-format-cost (plist-get p :cost)))
                    (harness-ui-usage--meter-string (if (> max-value 0) (/ value max-value) 0)
                                                    (harness-ui-usage--color 'accent) 200 30)
                    (if (> covered 0)
                        (propertize (format "  +%s covered by plan" (harness-format-cost covered))
                                    'face 'harness-dim-face)
                      "")
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
    ('billing (let ((k (format "%s" (or key ""))))
                (or (cdr (assoc k harness-ui-usage--billing-labels)) k)))
    (_ (format "%s" key))))

(defun harness-ui-usage--insert-table (summary)
  "Insert the summary table for SUMMARY rows.
Cost is what was billed and Plan what a subscription covered, at API
prices; rows sort by, and Share divides, their value at API prices."
  (let* ((rows (sort (copy-sequence summary)
                     (lambda (a b) (> (harness-usage-list-cost a) (harness-usage-list-cost b)))))
         (total (apply #'+ (mapcar #'harness-usage-list-cost rows)))
         (labels (mapcar (lambda (r) (harness-ui-usage--row-label (plist-get r :key))) rows))
         (kw (max 8 (apply #'max 0 (mapcar #'string-width labels))))
         (fmt (format " %%-%ds  %%8s  %%8s  %%-14s %%8s %%8s %%9s %%9s %%6s\n" kw)))
    (insert " " (propertize (format "By %s" (downcase (nth 1 (assq harness-ui-usage--group harness-ui-usage--groups))))
                            'face 'harness-usage-heading-face)
            "\n")
    (insert (propertize (format fmt (nth 1 (assq harness-ui-usage--group harness-ui-usage--groups))
                                "Cost" "Plan" "Share" "Input" "Output" "Cache r" "Cache w" "Calls")
                        'face 'harness-usage-table-header-face
                        'help-echo "Cost: billed.  Plan: what a subscription covered, at API prices.  Share: of the usage at API prices."))
    (cl-loop for r in rows for label in labels do
             (let* ((cost (float (or (plist-get r :cost) 0)))
                    (covered (harness-usage-covered r))
                    (share (if (> total 0) (/ (harness-usage-list-cost r) total) 0))
                    (start (point)))
               (insert (format fmt
                               (if (eq harness-ui-usage--group 'session)
                                   (propertize label 'face 'button 'harness-ui-usage-session (plist-get r :key)
                                               'help-echo "RET / mouse-1: open this session")
                                 label)
                               (harness-format-cost cost)
                               (if (> covered 0) (harness-format-cost covered) "")
                               (concat (harness-ui-usage--meter-string share (harness-ui-usage--color 'accent) 64 8
                                                                       (format "%.0f%% of the period's usage" (* 100 share)))
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

(defun harness-ui-usage--provider-label (provider)
  "Return the display name of PROVIDER, an id string, from the model catalogue."
  (or (cl-some (lambda (m) (and (equal (format "%s" (plist-get m :provider)) provider)
                                (plist-get m :provider-label)))
               (hash-table-values harness-ui--models))
      (capitalize provider)))

(defun harness-ui-usage--insert-window (window)
  "Insert a meter line for the plan quota WINDOW."
  (let* ((used (float (or (plist-get window :used) 0)))
         (role (cond ((>= used 0.95) 'danger) ((>= used 0.8) 'warning) (t 'accent)))
         (reset (harness-ui-format-reset (plist-get window :resets))))
    (insert (format "  %-28s " (harness-truncate-end (or (plist-get window :label) (plist-get window :name) "") 28))
            (harness-ui-usage--meter-string used (harness-ui-usage--color role) 120 15
                                            (harness-ui-describe-window window))
            (propertize (format " %3.0f%%" (* 100 used)) 'face (if (>= used 0.8) 'warning 'default))
            (propertize (if reset (concat "  resets " reset) "") 'face 'harness-dim-face)
            "\n")))

(defun harness-ui-usage--insert-plan (provider quota)
  "Insert how PROVIDER bills and, when a subscription pays, its QUOTA."
  (let ((label (propertize (harness-ui-usage--provider-label provider) 'face 'bold))
        (email (harness-plist-get-in quota '(:account :email))))
    (pcase (harness-billing-of quota)
      ('api
       (insert "  " label
               (propertize (format " bills per token%s: the costs above are what you pay.\n"
                                   (if-let* ((auth (plist-get quota :auth))) (format " (%s)" auth) ""))
                           'face 'harness-dim-face)))
      ((or 'subscription 'extra-usage)
       (insert "  " label "  "
               (propertize (or (plist-get quota :plan-label) "Subscription") 'face 'harness-plan-face)
               (if email (propertize (concat "  " email) 'face 'harness-dim-face) "")
               "\n"
               (propertize "  Calls the plan covers are not billed; their value at API prices shows as covered by plan.\n"
                           'face 'harness-dim-face))
       (pcase (plist-get quota :limit-status)
         ("rejected" (insert (propertize "  The plan's limit is reached: calls fail until it resets.\n" 'face 'error)))
         ("allowed_warning" (insert (propertize "  Close to the plan's limit.\n" 'face 'warning))))
       (when (harness-json-true-p (plist-get quota :using-extra))
         (insert (propertize "  Calls are drawing on extra usage, billed at API prices.\n" 'face 'warning)))
       (if (plist-get quota :windows)
           (mapc #'harness-ui-usage--insert-window (plist-get quota :windows))
         (insert (propertize "  no quota reported yet\n" 'face 'harness-dim-face)))
       (when-let* ((extra (harness-ui-describe-extra (plist-get quota :extra))))
         (insert "  " (propertize extra 'face 'harness-dim-face) "\n"))
       (when-let* ((updated (plist-get quota :updated)))
         (insert (propertize (format "  updated %s\n" (harness-relative-time updated)) 'face 'harness-dim-face))))
      (_ (insert "  " label (propertize " has not said how it bills yet.\n" 'face 'harness-dim-face))))))

(defun harness-ui-usage--insert-plans ()
  "Insert the plan section: how each provider bills, and its plan's quota."
  (when-let* ((quotas (harness-ui-quotas)))
    (insert " " (propertize "Plan" 'face 'harness-usage-heading-face) "  ")
    (harness-ui-button "[refresh]" #'harness-ui-usage-refresh-plan :help "Ask for the plan's quota again (r)")
    (insert "\n")
    (dolist (q quotas) (harness-ui-usage--insert-plan (car q) (cdr q)))
    (insert "\n")))

;;;; Fallback list

(defun harness-ui-usage--fallback-entry-label (entry)
  "Return how fallback ENTRY reads: its model, or its provider and tiers."
  (let ((label (or (plist-get entry :label) (plist-get entry :entry))))
    (if (plist-get entry :model)
        (format "%s (%s)" label (or (plist-get entry :provider-label) (plist-get entry :provider)))
      (let ((tiers (delq nil (mapcar (lambda (tier)
                                       (let ((m (plist-get tier :model)))
                                         (and m (format "%s %s" (plist-get tier :tier)
                                                        (or (plist-get tier :label) m)))))
                                     (plist-get entry :tiers)))))
        (concat label (if tiers (concat "  " (string-join tiers " · ")) ""))))))

(defun harness-ui-usage--fallback-mark-text (mark)
  "Describe MARK, what ran out and until when, as the fallback would."
  (let ((kind (format "%s" (plist-get mark :kind)))
        (until (plist-get mark :until))
        (guess (harness-json-true-p (plist-get mark :guess))))
    (concat (if (equal kind "billing") "out of money" "out of quota")
            (cond ((and (numberp until) (not guess))
                   (format " until %s"
                           (if (< (- until (float-time)) 72000)
                               (format-time-string "%H:%M" until)
                             (format-time-string "%a %b %-d, %H:%M" until))))
                  (guess " — trying again soon")
                  (t "")))))

(defun harness-ui-usage--fallback-state (entry)
  "Return (TEXT . HELP) saying how fallback ENTRY stands."
  (let ((mark (plist-get entry :mark)))
    (cond
     (mark (cons (harness-ui-usage--fallback-mark-text mark)
                 (or (plist-get mark :reason) "ran out of quota or money")))
     ((not (harness-json-true-p (plist-get entry :registered)))
      (cons "provider not set up" nil))
     ((and (plist-get entry :model) (not (harness-json-true-p (plist-get entry :known))))
      (cons "not in the provider's catalogue" nil))
     (t (cons "available" nil)))))

(defun harness-ui-usage--insert-fallback (fallback)
  "Insert the fallback section for FALLBACK, the `fallback/status' answer.
Nothing is inserted when FALLBACK is nil, the fallback module being
absent."
  (when fallback
    (insert " " (propertize "Fallback" 'face 'harness-usage-heading-face) "  ")
    (harness-ui-button "[add]" #'harness-ui-usage-add-fallback
                       :help "Add a provider or model to fall back to (f)")
    (insert " ")
    (harness-ui-button "[refresh]" #'harness-ui-usage-refresh :help "Reload the dashboard (g)")
    (insert "\n")
    (let ((entries (plist-get fallback :models))
          (number 0))
      (insert (propertize
               (if entries
                   "  sessions carry on with the first entry that has not run out; their own model comes first\n"
                 "  sessions stop when their provider runs out — add where to carry on\n")
               'face 'harness-dim-face))
      (dolist (entry entries)
        (let* ((start (point))
               (state (harness-ui-usage--fallback-state entry)))
          (insert (format "  %2d. " (cl-incf number)))
          (insert (format "%-36s " (harness-truncate-end (harness-ui-usage--fallback-entry-label entry) 36)))
          (insert (propertize (car state)
                              'face (if (plist-get entry :mark) 'warning 'harness-dim-face)
                              'help-echo (or (cdr state) nil)))
          (insert "  ")
          (harness-ui-usage--fallback-button "[up]" entry #'harness-ui-usage--fallback-move-one -1
                                             :help "Use this entry earlier in the list (M-<up>)")
          (insert " ")
          (harness-ui-usage--fallback-button "[down]" entry #'harness-ui-usage--fallback-move-one 1
                                             :help "Use this entry later in the list (M-<down>)")
          (insert " ")
          (when (plist-get entry :mark)
            (harness-ui-usage--fallback-button "[try now]" entry #'harness-ui-usage--fallback-try-entry
                                               :help "Forget that it ran out and try it again (c)")
            (insert " "))
          (harness-ui-usage--fallback-button "[remove]" entry #'harness-ui-usage--fallback-remove-entry
                                             :help "Remove this entry (d)")
          (insert "\n")
          (add-text-properties start (point) (list 'harness-ui-usage-fallback entry)))))
    ;; What ran out without being in the list still says why sessions move.
    (let* ((covered (mapcar (lambda (e) (or (plist-get e :model) (plist-get e :entry)))
                            (plist-get fallback :models)))
           (extra (cl-remove-if (lambda (m) (member (plist-get m :key) covered))
                                (plist-get fallback :marks))))
      (dolist (mark extra)
        (insert "  " (propertize (format "%s — %s" (or (plist-get mark :label) (plist-get mark :key))
                                          (harness-ui-usage--fallback-mark-text mark))
                                 'face 'warning)
                (propertize "  (not in the list)\n" 'face 'harness-dim-face))))
    (when-let* ((moved (plist-get fallback :moved)))
      (insert (propertize (format "  %d session%s now on another model\n"
                                  (length moved) (if (eql 1 (length moved)) "" "s"))
                          'face 'harness-dim-face)))
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
         (baseline (float (or (plist-get status :baseline) 0)))
         (baseline-text (and (> baseline 0) (format "incl. %s baseline" (harness-format-cost baseline))))
         (start (point)))
    (insert (format "  %-28s " (harness-truncate-end (harness-ui-usage--budget-label budget) 28))
            (harness-ui-usage--meter-string fraction color 120 15
                                            (concat (format "%s of %s spent" (harness-format-cost (plist-get status :spent))
                                                            (harness-format-cost (plist-get status :amount)))
                                                    (if baseline-text (concat ", " baseline-text) "")))
            (propertize (format " %3.0f%%" (* 100 fraction)) 'face (if (>= fraction 0.8) 'warning 'default))
            (propertize (format "  %s / %s" (harness-format-cost (plist-get status :spent))
                                (harness-format-cost (plist-get status :amount)))
                        'face 'default)
            (if baseline-text
                (propertize (concat "  " baseline-text) 'face 'harness-dim-face
                            'help-echo "Spent outside the harness, set by hand (s)")
              "")
            (propertize (format "  %s left" (harness-format-cost (max 0 (or (plist-get status :remaining) 0)))) 'face 'harness-dim-face)
            (if (plist-get status :per-day)
                (propertize (format "  %s/day · %s day%s left" (harness-format-cost (plist-get status :per-day))
                                    (or (plist-get status :days-left) "?")
                                    (if (eql (plist-get status :days-left) 1) "" "s"))
                            'face 'harness-dim-face)
              "")
            (propertize (if hard "  hard" "  soft") 'face (if hard 'warning 'harness-dim-face)
                        'help-echo (if hard "Turns are blocked once this budget is spent"
                                     "Warnings only at 80% and 100%"))
            "  ")
    (unless (plist-get budget :implicit)
      (harness-ui-button "[baseline]" #'harness-ui-usage-set-baseline
                         :help "Set what was already spent outside the harness (s)")
      (insert " ")
      (harness-ui-button "[remove]" #'harness-ui-usage-remove-budget :help "Remove this budget (d)"))
    (insert " ")
    (harness-ui-button "[plan]" #'harness-ui-usage-plan :help "Split this budget over its period per day (P)")
    (insert "\n")
    (harness-ui-usage--insert-api-cost-offer budget)
    (add-text-properties start (point) (list 'harness-ui-usage-budget status))))

(defun harness-ui-usage--insert-api-cost-offer (budget)
  "Insert the API cost fetched for BUDGET with buttons to use it, if any."
  (let ((offer harness-ui-usage--api-cost))
    (when (and offer (equal (plist-get offer :budget-id) (plist-get budget :id)))
      (insert "    "
              (propertize (concat (format "Anthropic billed %s this month" (harness-format-cost (plist-get offer :amount)))
                                  (if (> (or (plist-get offer :recorded) 0) 0)
                                      (format ", %s of it for calls recorded here"
                                              (harness-format-cost (plist-get offer :recorded)))
                                    ""))
                          'face 'harness-dim-face)
              "  ")
      (harness-ui-button (format "[use %s as baseline]" (harness-format-cost (plist-get offer :outside)))
                         #'harness-ui-usage-use-api-cost
                         :help "Count what Anthropic billed outside the harness this month in this budget")
      (insert " ")
      (harness-ui-button "[dismiss]" #'harness-ui-usage-dismiss-api-cost :help "Forget the fetched cost")
      (insert "\n"))))

(defun harness-ui-usage--insert-budgets (statuses)
  "Insert the budgets section for STATUSES."
  (insert " " (propertize "Budgets" 'face 'harness-usage-heading-face) "  ")
  (harness-ui-button "[add budget]" #'harness-ui-usage-add-budget :help "Create a session, project or period budget (a)")
  (insert " ")
  (harness-ui-button "[plan]" #'harness-ui-usage-plan :help "Split an amount over a period by day (P)")
  (insert "\n")
  (when (cl-some (lambda (q) (memq (harness-billing-of (cdr q)) '(subscription extra-usage)))
                 (harness-ui-quotas))
    (insert (propertize "  budgets count billed cost; calls a plan covers do not spend them\n"
                        'face 'harness-dim-face)))
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
      (harness-ui-usage--insert-plans)
      (harness-ui-usage--insert-fallback (plist-get data :fallback))
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
    (define-key map (kbd "d") #'harness-ui-usage-remove)
    (define-key map (kbd "f") #'harness-ui-usage-add-fallback)
    (define-key map (kbd "c") #'harness-ui-usage-fallback-try)
    (define-key map (kbd "M-<up>") #'harness-ui-usage-fallback-up)
    (define-key map (kbd "M-<down>") #'harness-ui-usage-fallback-down)
    (define-key map (kbd "s") #'harness-ui-usage-set-baseline)
    (define-key map (kbd "I") #'harness-ui-usage-import-api-cost)
    (define-key map (kbd "P") #'harness-ui-usage-plan)
    (define-key map (kbd "r") #'harness-ui-usage-refresh-plan)
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

;; The dashboard's keys in the harness menu, behind `.'.
(put 'harness-ui-usage-mode 'harness-menu-group
     '("Usage & cost"
       ["View"
        (". t" "Next period" harness-ui-usage-cycle-period)
        (". b" "Group by next" harness-ui-usage-cycle-group)
        (". RET" "Open at point" harness-ui-usage-open)
        (". g" "Refresh" harness-ui-usage-refresh)]
       ["Budgets and plan"
        (". a" "Add budget" harness-ui-usage-add-budget)
        (". s" "Already spent (baseline)" harness-ui-usage-set-baseline)
        (". I" "Import API cost (Anthropic)" harness-ui-usage-import-api-cost)
        (". d" "Remove fallback entry or budget" harness-ui-usage-remove)
        (". P" "Plan a budget" harness-ui-usage-plan)
        (". r" "Refresh plan quota" harness-ui-usage-refresh-plan)]
       ["Fallback"
        (". f" "Add fallback model" harness-ui-usage-add-fallback)
        (". c" "Try the fallback at point again" harness-ui-usage-fallback-try)
        (". M-<up>" "Move it earlier" harness-ui-usage-fallback-up)
        (". M-<down>" "Move it later" harness-ui-usage-fallback-down)]))

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
  (let ((buf (get-buffer-create harness-ui-usage--buffer-name)))
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

(defun harness-ui-usage-refresh-plan ()
  "Ask every provider that reports quota for fresh billing and quota data.
The plan section redraws when the answers arrive."
  (interactive)
  (harness-ui-refresh-quotas t)
  (message "Asking for the plan's quota"))

(defun harness-ui-usage-set-period (period)
  "Show PERIOD (`today', `7d', `30d' or `all')."
  (interactive (list (intern (completing-read "Period: " (mapcar (lambda (p) (symbol-name (car p))) harness-ui-usage--periods) nil t))))
  (setq harness-ui-usage--period period)
  (harness-ui-usage--load (current-buffer)))

(defun harness-ui-usage-set-group (group)
  "Group the table by GROUP (`project', `model', `session', `day' or `billing')."
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

;;;; Fallback commands
;;
;; The list lives in the harness (a defcustom the settings page also
;; shows), so every edit goes through `config/set' at the global scope
;; and the dashboard redraws from `fallback/status' afterwards.

(defun harness-ui-usage--fallback-button (label entry function &rest props)
  "Insert a button LABEL that calls FUNCTION on fallback ENTRY."
  (apply #'harness-ui-button label (lambda (_button) (funcall function entry)) props))

(defun harness-ui-usage--fallback-at-point ()
  "Return the fallback entry plist on the current line, or nil."
  (get-text-property (point) 'harness-ui-usage-fallback))

(defun harness-ui-usage--fallback-status ()
  "Return the last `fallback/status' answer, or nil when there was none."
  (plist-get harness-ui-usage--data :fallback))

(defun harness-ui-usage--fallback-models ()
  "Return the fallback list as entries (strings) in order."
  (mapcar (lambda (e) (plist-get e :entry)) (plist-get (harness-ui-usage--fallback-status) :models)))

(defun harness-ui-usage--fallback-save (models &optional done)
  "Save MODELS as `harness-fallback-models' and reload the dashboard.
DONE is a message shown once the save arrived."
  (let ((buf (current-buffer)))
    (harness-ui-call
     "_harness/config/set"
     (list :key "harness-fallback-models"
           :value (let ((print-length nil) (print-level nil)) (prin1-to-string models))
           :printed t :scope "global")
     (lambda (_)
       (when done (message "%s" done))
       (when (buffer-live-p buf) (with-current-buffer buf (harness-ui-usage--load buf))))
     (lambda (e) (message "Could not save the fallback list: %s" (harness-error-message e))))))

(defun harness-ui-usage--fallback-candidates (models)
  "Return completion candidates (LABEL . ENTRY) for adding to the fallback list.
MODELS are the entries already in it, left out.  Providers come from
the quota cache and the model catalogue; models from the catalogue."
  (let (ids)
    (maphash (lambda (id _) (push id ids)) harness-ui--models)
    (let ((providers (delete-dups
                      (append (mapcar #'car (harness-ui-quotas))
                              (delq nil (mapcar (lambda (id)
                                                  (and (string-match "\\`\\([^:]+\\):" id)
                                                       (match-string 1 id)))
                                                ids))
                              (mapcar (lambda (e) (plist-get e :provider))
                                      (plist-get (harness-ui-usage--fallback-status) :models))))))
      (append
       (cl-loop for pid in (sort (delete-dups providers) #'string<)
                unless (member pid models)
                collect (cons (format "%s  (its model of similar ability)" pid) pid))
       (cl-loop for id in (sort (delete-dups ids) #'string<)
                unless (member id models)
                collect (cons (format "%s  (%s)" (harness-ui-model-label id) id) id))))))

(defun harness-ui-usage-add-fallback ()
  "Add a provider or model to the end of the fallback list."
  (interactive)
  (let* ((models (harness-ui-usage--fallback-models))
         (candidates (harness-ui-usage--fallback-candidates models))
         (input (if candidates
                    (completing-read "Fall back to: " candidates nil nil)
                  (read-string "Fall back to (provider or provider:model): ")))
         (cell (assoc input candidates))
         (entry (or (cdr cell) input)))
    (when (or (null entry) (string-blank-p entry)) (user-error "No provider or model given"))
    (when (member entry models) (user-error "%s is already in the fallback list" entry))
    (harness-ui-usage--fallback-save (append models (list entry))
                                     (format "%s is now where sessions carry on" entry))))

(defun harness-ui-usage--fallback-move-one (entry delta)
  "Move fallback ENTRY DELTA places in the list, then save it."
  (let* ((models (harness-ui-usage--fallback-models))
         (key (plist-get entry :entry))
         (pos (cl-position key models :test #'equal))
         (new (and pos (+ pos delta))))
    (unless pos (user-error "That entry is no longer in the fallback list"))
    (when (or (< new 0) (>= new (length models)))
      (user-error "%s is already %s in the fallback list" key (if (< delta 0) "first" "last")))
    (let ((moved (copy-sequence models)))
      (cl-rotatef (nth pos moved) (nth new moved))
      (harness-ui-usage--fallback-save moved (format "%s is now %d in the fallback list" key (1+ new))))))

(defun harness-ui-usage-fallback-up ()
  "Move the fallback entry on the current line earlier in the list."
  (interactive)
  (harness-ui-usage--fallback-move-one
   (or (harness-ui-usage--fallback-at-point) (user-error "No fallback entry on this line")) -1))

(defun harness-ui-usage-fallback-down ()
  "Move the fallback entry on the current line later in the list."
  (interactive)
  (harness-ui-usage--fallback-move-one
   (or (harness-ui-usage--fallback-at-point) (user-error "No fallback entry on this line")) 1))

(defun harness-ui-usage--fallback-try-entry (entry)
  "Forget that fallback ENTRY ran out, so it is tried again."
  (let ((key (or (plist-get entry :model) (plist-get entry :entry)))
        (label (harness-ui-usage--fallback-entry-label entry))
        (buf (current-buffer)))
    (harness-ui-call "_harness/fallback/clear" (list :key key)
                     (lambda (_)
                       (message "%s will be tried again" label)
                       (when (buffer-live-p buf) (with-current-buffer buf (harness-ui-usage--load buf))))
                     (lambda (e) (message "Could not clear the mark: %s" (harness-error-message e))))))

(defun harness-ui-usage-fallback-try ()
  "Forget that the fallback entry on the current line ran out."
  (interactive)
  (harness-ui-usage--fallback-try-entry
   (or (harness-ui-usage--fallback-at-point) (user-error "No fallback entry on this line"))))

(defun harness-ui-usage--fallback-remove-entry (entry)
  "Remove fallback ENTRY from the list."
  (let ((key (plist-get entry :entry)))
    (harness-ui-usage--fallback-save (delete key (harness-ui-usage--fallback-models))
                                     (format "%s removed from the fallback list" key))))

(defun harness-ui-usage-remove ()
  "Remove the fallback entry or the budget on the current line."
  (interactive)
  (cond
   ((harness-ui-usage--fallback-at-point)
    (harness-ui-usage--fallback-remove-entry (harness-ui-usage--fallback-at-point)))
   ((harness-ui-usage--budget-at-point) (harness-ui-usage-remove-budget))
   (t (user-error "No fallback entry or budget on this line"))))

(defun harness-ui-usage--budget-at-point ()
  "Return the budget status plist on the current line, or nil."
  (get-text-property (point) 'harness-ui-usage-budget))

(defun harness-ui-usage--baseline-prompt (period)
  "Return the prompt asking what a budget with PERIOD already spent."
  (format "Already spent %s outside the harness (USD, 0 for none): "
          (pcase (and period (format "%s" period))
            ("day" "today") ("week" "this week") ("month" "this month") (_ "so far"))))

(defun harness-ui-usage--read-baseline (period &optional default)
  "Read what a budget with PERIOD already spent outside the harness.
DEFAULT is offered (0 when nil); a negative amount is refused."
  (let ((amount (read-number (harness-ui-usage--baseline-prompt period) (or default 0))))
    (when (< amount 0) (user-error "An amount spent cannot be negative"))
    amount))

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
         ;; A session spends only through the harness, which records it all.
         (baseline (unless (equal scope "session") (harness-ui-usage--read-baseline period)))
         (hard (y-or-n-p "Hard budget (block the next turn once it is spent)? "))
         (label (read-string "Label (optional): ")))
    (append (list :scope scope :amount amount :hard (if hard t :false))
            (and target (list :target target))
            (and period (list :period period))
            (and days (list :days days))
            (and baseline (> baseline 0) (list :baseline baseline))
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

(defun harness-ui-usage--save-baseline (budget amount buffer &optional period-start)
  "Make AMOUNT the baseline of BUDGET, then reload BUFFER.
AMOUNT 0 clears it.  A period budget's baseline counts in the period
starting on PERIOD-START (YYYY-MM-DD); without one the harness takes
the period containing now, so a stale period start is dropped."
  (harness-ui-call "_harness/usage/set-budget"
                   (list :budget (harness-plist-merge budget (list :baseline (and (> amount 0) amount)
                                                                   :baseline-period-start period-start)))
                   (lambda (_)
                     (message (if (> amount 0) (format "Baseline set to %s" (harness-format-cost amount))
                                "Baseline cleared"))
                     (when (buffer-live-p buffer) (harness-ui-usage--load buffer)))))

(defun harness-ui-usage-set-baseline ()
  "Set or clear the baseline of the budget on the current line.
The baseline is what was spent that the harness did not record, such
as calls made in other tools.  It counts toward the budget like
recorded spending.  A day, week or month budget's baseline counts in
the current period only and stops counting when the period rolls
over.  0 clears it."
  (interactive)
  (let* ((status (or (harness-ui-usage--budget-at-point) (user-error "No budget on this line")))
         (budget (plist-get status :budget)))
    (when (plist-get budget :implicit)
      (user-error "This is the session's own budget; change it on the session"))
    (harness-ui-usage--save-baseline
     budget
     (harness-ui-usage--read-baseline (plist-get budget :period) (plist-get status :baseline))
     (current-buffer))))

(defun harness-ui-usage-import-api-cost ()
  "Fetch this month's Anthropic API cost for the month budget at point.
Anthropic's Admin API reports what the organisation was billed per
token this month.  Once it arrives it shows under the budget, less what
the harness recorded itself for Claude calls billed per token, with a
button that makes it the budget's baseline.  The harness needs an Admin
API key: `harness-anthropic-admin-api-key', the ANTHROPIC_ADMIN_KEY
environment variable or an auth-source entry for api.anthropic.com
with user admin.  Without one nothing is fetched; subscriptions such as
Pro or Max have no cost report."
  (interactive)
  (let* ((status (or (harness-ui-usage--budget-at-point) (user-error "No budget on this line")))
         (budget (plist-get status :budget))
         (id (plist-get budget :id))
         (buf (current-buffer)))
    (when (plist-get budget :implicit)
      (user-error "This is the session's own budget; change it on the session"))
    (unless (equal (format "%s" (plist-get budget :period)) "month")
      (user-error "Anthropic reports the cost of a calendar month: pick a month budget"))
    (message "Asking Anthropic for this month's API cost...")
    (harness-ui-call "_harness/usage/fetch-api-cost" nil
                     (lambda (result)
                       (cond
                        ((not (harness-json-true-p (plist-get result :available)))
                         (message "%s" (plist-get result :reason)))
                        ((buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-ui-usage--api-cost (append (list :budget-id id) result))
                           (harness-ui-usage--render))
                         (message "Anthropic billed %s this month" (harness-format-cost (plist-get result :amount)))))))))

(defun harness-ui-usage-use-api-cost ()
  "Make the fetched API cost its budget's baseline.
The baseline is what Anthropic billed this month less what the harness
recorded itself for Claude calls billed per token."
  (interactive)
  (let* ((offer (or harness-ui-usage--api-cost (user-error "Nothing fetched: press I on a month budget")))
         (status (cl-find (plist-get offer :budget-id) (plist-get harness-ui-usage--data :statuses)
                          :key (lambda (s) (plist-get (plist-get s :budget) :id)) :test #'equal)))
    (unless status (user-error "That budget is gone"))
    (setq harness-ui-usage--api-cost nil)
    (harness-ui-usage--save-baseline (plist-get status :budget) (float (or (plist-get offer :outside) 0))
                                     (current-buffer) (plist-get offer :period-start))))

(defun harness-ui-usage-dismiss-api-cost ()
  "Forget the fetched API cost."
  (interactive)
  (setq harness-ui-usage--api-cost nil)
  (harness-ui-usage--render))

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
  (when-let* ((buf (get-buffer harness-ui-usage--buffer-name)))
    (harness-debounce 'harness-ui-usage 1.0
                      (lambda () (when (buffer-live-p buf) (harness-ui-usage--load buf))))))

(defun harness-ui-usage--on-event (event args)
  "Refresh after EVENT changed spending, budgets or the fallback list."
  (cond
   ((member event '("usage/budget-warning" "agent/turn-ended" "usage/budgets-changed" "usage/recorded"
                    "fallback/changed" "fallback/switched"))
    (harness-ui-usage--refresh-soon))
   ((and (equal event "config/changed")
         (equal (format "%s" (car args)) "harness-fallback-models"))
    (harness-ui-usage--refresh-soon))))

(defun harness-ui-usage--on-quota (_provider _quota)
  "Redraw the dashboard, whose plan section shows the providers' quota."
  (when-let* ((buf (get-buffer harness-ui-usage--buffer-name)))
    (with-current-buffer buf
      (when (and (derived-mode-p 'harness-ui-usage-mode) harness-ui-usage--data)
        (harness-ui-usage--render)))))

(defun harness-ui-usage--redraw ()
  "Rebuild the dashboard after a reload or reconnect."
  (when-let* ((buf (get-buffer harness-ui-usage--buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-usage-mode)
        (harness-ui-usage-mode)
        (setq harness-ui-usage--period harness-ui-usage-default-period harness-ui-usage--group 'project)))
    (harness-ui-usage--load buf)))

;;;; Module

(defun harness-ui-usage--init ()
  "Wire the dashboard into the UI."
  (add-hook 'harness-ui-event-functions #'harness-ui-usage--on-event)
  (add-hook 'harness-ui-quota-functions #'harness-ui-usage--on-quota)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-usage--redraw)
  (define-key harness-ui-map (kbd "u") #'harness-usage))

(harness-define-module 'ui-usage
  :doc "Usage and cost dashboard with charts, plan quota and budgets."
  :requires '(ui)
  :init #'harness-ui-usage--init)

(provide 'harness-ui-usage)
;;; harness-ui-usage.el ends here
