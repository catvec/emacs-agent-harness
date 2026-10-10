;;; harness-ui-cost-compare.el --- Compare recorded usage at other prices  -*- lexical-binding: t; -*-

;;; Commentary:

;; The cost page shows what was recorded.  This view answers the
;; question next to it: "how much would this have cost using a
;; different provider?"  It asks the harness (`usage/cost-compare', the
;; cost-compare module) to price exactly the tokens the cost page
;; recorded at another model's rates, and lists every priced model of
;; the catalogue cheapest first, each with how much more or less it is
;; than the same tokens at API prices -- what a plan covered, which is
;; the value the comparison is about.
;;
;; It is a buffer of its own, opened from the dashboard's `compare'
;; button or `C' (`harness-cost-compare').  Nothing is recorded or
;; changed: the recorded cost, the rows and the budgets stay as they
;; are.  The rates are the catalogue's; a model the catalogue does not
;; price cannot be compared and is not offered.  A model that prices no
;; cache read, or charges less for a cache write than for input, is
;; priced as that model would have billed the tokens: see the
;; cost-compare module.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-usage)

(defgroup harness-ui-cost-compare nil
  "Comparing the recorded usage at other models' prices." :group 'harness-ui)

(defconst harness-ui-cost-compare--buffer-name "*harness cost comparison*"
  "Name of the cost comparison buffer.")

(defvar-local harness-ui-cost-compare--period '7d
  "Period shown: a symbol of `harness-ui-usage--periods'.")

(defvar-local harness-ui-cost-compare--session nil
  "Session id the comparison covers, or nil for every session.")

(defvar-local harness-ui-cost-compare--reference nil
  "Model the recorded usage of `harness-ui-cost-compare--session' ran on, or nil.")

(defvar-local harness-ui-cost-compare--data nil
  "The `usage/cost-compare' answer last received, or nil while it is asked.")

(defvar-local harness-ui-cost-compare--error nil
  "Why the last comparison failed, or nil.")

(defvar-local harness-ui-cost-compare--generation 0
  "Counter to drop the answer of a comparison a later one replaced.")

;;;; The scope

(defun harness-ui-cost-compare--period-label (&optional period)
  "Return the label of PERIOD, the buffer's by default."
  (or (nth 1 (assq (or period harness-ui-cost-compare--period) harness-ui-usage--periods))
      "7 days"))

(defun harness-ui-cost-compare--period-default ()
  "Return the period to compare: the dashboard's, else the default."
  (let ((buffer (get-buffer harness-ui-usage--buffer-name)))
    (or (and buffer (buffer-local-value 'harness-ui-usage--period buffer))
        harness-ui-usage-default-period)))

(defun harness-ui-cost-compare--read-period ()
  "Ask which period to compare; return its symbol."
  (let* ((default (harness-ui-cost-compare--period-default))
         (table (mapcar (lambda (p) (cons (nth 1 p) (car p))) harness-ui-usage--periods))
         (choice (completing-read (format "Period (default %s): "
                                          (harness-ui-cost-compare--period-label default))
                                  table nil t nil nil
                                  (harness-ui-cost-compare--period-label default))))
    (cdr (assoc choice table))))

(defun harness-ui-cost-compare--scope ()
  "Return what the buffer covers, as \"7 days · all sessions\"."
  (let ((session (and harness-ui-cost-compare--session (harness-ui-session harness-ui-cost-compare--session))))
    (format "%s · %s"
            (harness-ui-cost-compare--period-label)
            (if session
                (format "session %s" (or (plist-get session :name) harness-ui-cost-compare--session))
              "all sessions"))))

(defun harness-ui-cost-compare--params (ids)
  "Return the `usage/cost-compare' parameters for this buffer and IDS."
  (append (list :models ids)
          (and harness-ui-cost-compare--session (list :session harness-ui-cost-compare--session))
          (and harness-ui-cost-compare--reference (list :reference-model harness-ui-cost-compare--reference))
          (when-let* ((since (harness-ui-usage--since harness-ui-cost-compare--period)))
            (list :since since))))

;;;; The models to compare

(defun harness-ui-cost-compare--priced-p (model)
  "Non-nil when MODEL's rates can price a call, as `usage/cost-compare' does.
A model the catalogue does not price, or prices with a negative rate
\(its provider does not know it), cannot answer the question."
  (let ((pricing (plist-get model :pricing)))
    (or (and (numberp (plist-get pricing :input)) (>= (plist-get pricing :input) 0)
             (numberp (plist-get pricing :output)) (>= (plist-get pricing :output) 0))
        (and (plist-get model :pricing-fn) t))))

(defun harness-ui-cost-compare--model-ids (models)
  "Return the ids of the priced MODELS."
  (delq nil (mapcar (lambda (m) (and (harness-ui-cost-compare--priced-p m) (plist-get m :id))) models)))

(defun harness-ui-cost-compare--cached-ids ()
  "Return the ids of the priced models the UI's catalogue cache holds, or nil."
  (let (ids)
    (maphash (lambda (id model)
               (when (harness-ui-cost-compare--priced-p model) (push id ids)))
             harness-ui--models)
    ids))

(defun harness-ui-cost-compare--candidates (callback)
  "Call CALLBACK with the model ids the comparison can answer for.
Those are the priced models of the catalogue the UI already cached;
when it holds none, the catalogue is fetched first (the cost page
fetches it on connect, so this is a cold-start case)."
  (let ((known (harness-ui-cost-compare--cached-ids)))
    (if known
        (funcall callback known)
      (harness-ui-refresh-models
       (lambda (models) (funcall callback (harness-ui-cost-compare--model-ids models)))))))

;;;; Asking and drawing

(defun harness-ui-cost-compare--load (buffer)
  "Ask for the comparison of BUFFER's scope and draw it when it arrives."
  (with-current-buffer buffer
    (let ((generation (cl-incf harness-ui-cost-compare--generation)))
      (setq harness-ui-cost-compare--data nil harness-ui-cost-compare--error nil)
      (harness-ui-cost-compare--render)
      (harness-ui-cost-compare--candidates
       (lambda (ids)
         (harness-ui-call
          "_harness/usage/cost-compare"
          (harness-ui-cost-compare--params ids)
          (lambda (answer)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (when (= generation harness-ui-cost-compare--generation)
                  (setq harness-ui-cost-compare--data answer)
                  (harness-ui-cost-compare--render)))))
          (lambda (err)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (when (= generation harness-ui-cost-compare--generation)
                  (setq harness-ui-cost-compare--error (harness-error-message err))
                  (harness-ui-cost-compare--render)))))))))))

(defun harness-ui-cost-compare--rate (rate)
  "Return RATE, a price per million tokens, in a few words."
  (if (numberp rate) (concat (harness-format-cost rate) "/M") "none"))

(defun harness-ui-cost-compare--delta-text (delta)
  "Return DELTA, a cost difference, with its sign: \"+$0.86\"."
  (cond ((zerop delta) "the same")
        ((> delta 0) (format "+%s" (harness-format-cost delta)))
        (t (format "-%s" (harness-format-cost (- delta))))))

(defun harness-ui-cost-compare--delta-words (delta)
  "Return DELTA, a cost difference, in words: \"$0.86 more\"."
  (if (> delta 0)
      (format "%s more" (harness-format-cost delta))
    (format "%s less" (harness-format-cost (- delta)))))

(defun harness-ui-cost-compare--help (row)
  "Return the one-line tooltip of a comparison ROW."
  (harness-ui-one-line
   (concat
    (if (plist-get row :cost)
        (format "%s at this model's prices" (harness-format-cost (plist-get row :cost)))
      "The catalogue does not price this model, so it cannot be compared")
    (when-let* ((pricing (plist-get row :pricing)))
      (format " (%s per million tokens in, %s out, %s cache read, %s cache write)"
              (harness-ui-cost-compare--rate (plist-get pricing :input))
              (harness-ui-cost-compare--rate (plist-get pricing :output))
              (harness-ui-cost-compare--rate (plist-get pricing :cache-read))
              (harness-ui-cost-compare--rate (plist-get pricing :cache-write))))
    (when-let* ((note (plist-get row :note))) (format "; %s" note))
    (when-let* ((delta (plist-get row :delta)))
      (format "; %s than the recorded tokens at API prices" (harness-ui-cost-compare--delta-words delta)))
    (if (plist-get row :reference) "; the model the recorded usage ran on" "")
    ".")))

(defun harness-ui-cost-compare--line (row)
  "Return the line of comparison ROW, with its tooltip."
  (let ((text (format "   %-9s  %-11s  %-30s  %s\n"
                      (if (plist-get row :cost) (harness-format-cost (plist-get row :cost)) "unknown")
                      (if (plist-get row :delta)
                          (harness-ui-cost-compare--delta-text (plist-get row :delta))
                        (propertize "—" 'face 'harness-dim-face))
                      (harness-truncate-end (or (plist-get row :label) (plist-get row :model) "?") 30)
                      (harness-truncate-end (or (plist-get row :provider-label) "") 16))))
    (propertize text 'help-echo (harness-ui-cost-compare--help row))))

(defun harness-ui-cost-compare--insert (data)
  "Insert the comparison DATA, as `usage/cost-compare' returned it."
  (let* ((totals (plist-get data :recorded))
         (list-cost (float (or (plist-get totals :list-cost) 0))))
    (insert " " (propertize (format "Recorded: %s billed" (harness-format-cost (plist-get totals :cost)))
                            'face 'harness-usage-heading-face)
            (propertize (format ", %s at API prices, %d calls\n"
                                (harness-format-cost list-cost) (or (plist-get totals :calls) 0))
                        'face 'harness-dim-face
                        'help-echo (harness-ui-one-line
                                    (concat "What was recorded: the billed cost, and the value of the same tokens"
                                            " at API prices, which the comparison below is against")))
            " " (propertize (format "Tokens: %s input, %s output, %s cache read, %s cache write\n\n"
                                    (harness-format-tokens (plist-get totals :input))
                                    (harness-format-tokens (plist-get totals :output))
                                    (harness-format-tokens (plist-get totals :cache-read))
                                    (harness-format-tokens (plist-get totals :cache-write)))
                            'face 'harness-dim-face))
    (insert " " (propertize (format "Cost at other prices  (the recorded tokens were worth %s at API prices)\n"
                                    (harness-format-cost list-cost))
                            'face 'harness-usage-heading-face))
    (insert (propertize (format "   %-9s  %-11s  %-30s  %s\n" "Cost" "vs recorded" "Model" "Provider")
                        'face 'harness-usage-table-header-face))
    (if (plist-get data :rows)
        (mapc (lambda (row) (insert (harness-ui-cost-compare--line row))) (plist-get data :rows))
      (insert (propertize "   no model in the catalogue can price these tokens\n" 'face 'harness-dim-face)))
    (insert "\n" (propertize " Nothing here is recorded or changed: budgets and the recorded cost stand as they are."
                             'face 'harness-dim-face)
            "\n")))

(defun harness-ui-cost-compare--header ()
  "Return the buffer's header line: its scope, and how to change it."
  (concat " Cost comparison  "
          (propertize (harness-ui-cost-compare--scope) 'face 'harness-usage-heading-face)
          (propertize "   g refresh   t period   q quit" 'face 'harness-dim-face)))

(defun harness-ui-cost-compare--render ()
  "Draw the buffer from `harness-ui-cost-compare--data'."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (erase-buffer)
    (setq header-line-format (harness-ui-cost-compare--header))
    (insert "\n")
    (cond
     (harness-ui-cost-compare--error
      (insert " " (propertize (format "Could not compare costs: %s" harness-ui-cost-compare--error)
                              'face 'error) "\n"))
     ((null harness-ui-cost-compare--data)
      (insert " " (propertize "Comparing costs…" 'face 'harness-dim-face) "\n"))
     (t (harness-ui-cost-compare--insert harness-ui-cost-compare--data)))
    (goto-char (point-min))
    (forward-line (1- (max 1 (min line (count-lines (point-min) (point-max))))))))

;;;; Commands and mode

(defun harness-ui-cost-compare-refresh ()
  "Ask for the comparison again."
  (interactive)
  (harness-ui-cost-compare--load (current-buffer)))

(defun harness-ui-cost-compare-cycle-period ()
  "Show the comparison over the next period."
  (interactive)
  (let* ((periods (mapcar #'car harness-ui-usage--periods))
         (next (or (cadr (memq harness-ui-cost-compare--period periods)) (car periods))))
    (setq harness-ui-cost-compare--period next)
    (harness-ui-cost-compare--load (current-buffer))))

(defvar harness-ui-cost-compare-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'harness-ui-cost-compare-refresh)
    (define-key map (kbd "t") #'harness-ui-cost-compare-cycle-period)
    map)
  "Keymap of `harness-ui-cost-compare-mode'.")

(define-derived-mode harness-ui-cost-compare-mode special-mode "Cost compare"
  "Major mode of the cost comparison buffer."
  (setq truncate-lines t
        buffer-read-only t))

;;;###autoload
(defun harness-cost-compare (&optional arg)
  "Show what the recorded usage would have cost at other models' prices.
The comparison re-prices the tokens the cost page recorded with the
rates the catalogue carries, and says how much more or less each model
would have cost than those tokens at API prices.  Nothing is recorded
or changed.

It covers the dashboard's period, and every session.  With prefix ARG,
ask which period; with a prefix of 16 or more (\\[universal-argument]
\\[universal-argument]), ask which session too."
  (interactive "p")
  (let* ((arg (or arg 1))
         (period (if (>= arg 4) (harness-ui-cost-compare--read-period) (harness-ui-cost-compare--period-default)))
         (session (and (>= arg 16) (harness-ui-read-session "Session: ")))
         (buffer (get-buffer-create harness-ui-cost-compare--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'harness-ui-cost-compare-mode)
        (harness-ui-cost-compare-mode))
      (setq harness-ui-cost-compare--period period
            harness-ui-cost-compare--session (and session (plist-get session :id))
            harness-ui-cost-compare--reference (and session (plist-get session :model))))
    (harness-ui-display-view buffer)
    (harness-ui-cost-compare--load buffer)))

(harness-define-module 'ui-cost-compare
  :doc "Compare what the recorded usage would have cost at other models' prices."
  :requires '(ui ui-usage))

(provide 'harness-ui-cost-compare)
;;; harness-ui-cost-compare.el ends here
