;;; harness-cost-compare-test.el --- Tests for the cost comparison  -*- lexical-binding: t; -*-

;;; Commentary:

;; The cost comparison answers "how much would this have cost using a
;; different provider?" by re-pricing the recorded tokens at another
;; model's rates.  The unit tests fix the rates: a hand-computed figure,
;; a model that prices no cache read and one that charges nothing for
;; writes (its tokens are input), and a model the catalogue does not
;; price (unknown, never zero).  The others run the method and the view
;; over ACP against the demo provider, and check that nothing recorded
;; changes.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-ui--models)
(defvar harness-ui-cost-compare--data)
(defvar harness-ui-cost-compare--error)
(defvar harness-usage-budgets)
(defvar harness-provider-demo--delay)
(defvar harness-agent--turns)
(defvar harness-ui--sessions)
(defvar harness-tools)
(defvar harness-sessions)
(defvar harness-ui-cost-compare--buffer-name)
(defvar harness-ui-usage--data)
(defvar harness-ui-usage--loading)
(defvar harness-ui-usage-mode-map)
(declare-function harness-usage "harness-ui-usage")
(declare-function harness-cost-compare "harness-ui-cost-compare")
(declare-function harness-ui-usage-compare-costs "harness-ui-usage")

(defmacro harness-cost-compare-test-with (&rest body)
  "Load the state layer, ACP, the UI, the dashboard and the comparison, then BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent usage
                          cost-compare fallback worktree acp ui ui-usage ui-cost-compare))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-ui--sessions)
     (setq harness-usage-budgets nil)
     (let ((harness-provider-demo--delay 0.005)
           (harness-acp-token nil)
           (default-directory dir))
       (unwind-protect
           (progn ,@body)
         (when (get-buffer harness-ui-cost-compare--buffer-name)
           (kill-buffer harness-ui-cost-compare--buffer-name))
         (when (get-buffer harness-ui-usage--buffer-name)
           (kill-buffer harness-ui-usage--buffer-name))
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-cost-compare-test--record (plist)
  "Record a usage row from PLIST and return it."
  (harness-call 'usage/record plist))

(defun harness-cost-compare-test--rich (id)
  "Return a model plist for ID with rates of $3/$15 in and out."
  (list :id id :name "Rich" :label "Rich model" :provider "test" :provider-label "Test"
        :pricing '(:input 3.0 :output 15.0 :cache-read 0.3 :cache-write 3.75)))

(defun harness-cost-compare-test--plain (id)
  "Return a model plist for ID that prices no cache write."
  (list :id id :name "Plain" :label "Plain model" :provider "test" :provider-label "Test"
        :pricing '(:input 2.0 :output 8.0 :cache-read 0.5)))

(defun harness-cost-compare-test--unpriced (id)
  "Return a model plist for ID the catalogue does not price."
  (list :id id :name "Mystery" :label "Mystery model" :provider "test" :provider-label "Test"))

(defmacro harness-cost-compare-test-with-models (models &rest body)
  "Stub `provider/model' from MODELS, an alist of id to plist, and run BODY."
  (declare (indent 1))
  `(let ((harness-cost-compare-test--models ,models))
     (cl-letf* ((orig (symbol-function 'harness-method/provider/model))
                ((symbol-function 'harness-method/provider/model)
                 (lambda (id)
                   (or (cdr (assoc id harness-cost-compare-test--models))
                       (funcall orig id)))))
       ,@body)))

(defun harness-cost-compare-test--row (answer model)
  "Return the row for MODEL in ANSWER, or nil."
  (cl-find model (plist-get answer :rows) :key (lambda (r) (plist-get r :model)) :test #'equal))

(defun harness-cost-compare-test--totals ()
  "Return the recorded totals, for comparing before and after."
  (harness-call 'usage/totals))

;;;; The recomputed cost

(ert-deftest harness-cost-compare-prices-the-recorded-tokens ()
  "The comparison prices the recorded tokens at the model's rates.
A million input, half a million output, two million cache reads and a
hundred thousand cache writes, at $3, $15, $0.30 and $3.75 per
million, come to $11.475; nothing recorded changes."
  (harness-cost-compare-test-with
    (harness-cost-compare-test--record
     (list :ts 1000.0 :session "s1" :project (file-name-as-directory dir) :model "demo:scripted"
           :input 1000000 :output 500000 :cache-read 2000000 :cache-write 100000
           :cost 4.0 :list-cost 4.0))
    (let ((before (harness-cost-compare-test--totals)))
      (harness-cost-compare-test-with-models
          (list (cons "test:rich" (harness-cost-compare-test--rich "test:rich")))
        (let* ((answer (harness-call 'usage/cost-compare :models '("test:rich") :at 2000.0))
               (row (harness-cost-compare-test--row answer "test:rich"))
               (recorded (plist-get answer :recorded)))
          (should (= 11.475 (plist-get row :cost)))
          (should (= 7.475 (plist-get row :delta)))
          (should (plist-get row :priced))
          (should (equal "Rich model" (plist-get row :label)))
          (should (equal "Test" (plist-get row :provider-label)))
          ;; The token basis the row was computed from.
          (should (= 1000000 (plist-get recorded :input)))
          (should (= 500000 (plist-get recorded :output)))
          (should (= 2000000 (plist-get recorded :cache-read)))
          (should (= 100000 (plist-get recorded :cache-write)))
          (should (= 4.0 (plist-get recorded :cost)))
          (should (= 4.0 (plist-get recorded :list-cost)))))
      ;; Read-only: the rows and their cost are what they were.
      (should (equal before (harness-cost-compare-test--totals))))))

(ert-deftest harness-cost-compare-prices-cache-writes-as-input ()
  "A model that charges nothing for cache writes pays input for them.
A model that prices no cache read pays input for the tokens that were
read from the source model's cache."
  (harness-cost-compare-test-with
    (harness-cost-compare-test--record
     (list :ts 1000.0 :session "s1" :project (file-name-as-directory dir) :model "demo:scripted"
           :input 1000000 :output 500000 :cache-read 2000000 :cache-write 100000
           :cost 4.0 :list-cost 4.0))
    (harness-cost-compare-test-with-models
        (list (cons "test:plain" (harness-cost-compare-test--plain "test:plain"))
              (cons "test:nocache" '(:id "test:nocache" :name "No cache" :label "No cache" :provider "test"
                                         :provider-label "Test" :pricing (:input 2.0 :output 8.0))))
      (let* ((answer (harness-call 'usage/cost-compare :models '("test:plain" "test:nocache") :at 2000.0))
             (plain (harness-cost-compare-test--row answer "test:plain"))
             (nocache (harness-cost-compare-test--row answer "test:nocache")))
        ;; (1000000*2 + 500000*8 + 2000000*0.5 + 100000*2) / 1e6 = 7.2
        (should (= 7.2 (plist-get plain :cost)))
        (should (equal "cache writes priced as input" (plist-get plain :note)))
        ;; No cache read either: those tokens are input too.
        ;; (1000000*2 + 500000*8 + 2000000*2 + 100000*2) / 1e6 = 10.2
        (should (= 10.2 (plist-get nocache :cost)))
        (should (equal "cache reads and writes priced as input" (plist-get nocache :note)))
        ;; Cheapest first.
        (should (equal '("test:plain" "test:nocache") (mapcar (lambda (r) (plist-get r :model))
                                                              (plist-get answer :rows))))))))

(ert-deftest harness-cost-compare-an-unpriced-model-is-unknown ()
  "A model the catalogue does not price has no cost, not one of zero."
  (harness-cost-compare-test-with
    (harness-cost-compare-test--record
     (list :ts 1000.0 :session "s1" :project (file-name-as-directory dir) :model "demo:scripted"
           :input 1000000 :output 500000 :cache-read 2000000 :cache-write 100000
           :cost 4.0 :list-cost 4.0))
    (harness-cost-compare-test-with-models
        (list (cons "test:mystery" (harness-cost-compare-test--unpriced "test:mystery")))
      (let* ((answer (harness-call 'usage/cost-compare :models '("test:mystery") :at 2000.0))
             (row (car (plist-get answer :rows))))
        (should-not (plist-get row :priced))
        (should-not (plist-get row :cost))
        (should-not (plist-get row :delta))
        (should (equal "Mystery model" (plist-get row :label)))))))

(ert-deftest harness-cost-compare-marks-the-recorded-model ()
  "The model the usage ran on is marked, and included when `:models' omits it."
  (harness-cost-compare-test-with
    (harness-cost-compare-test--record
     (list :ts 1000.0 :session "s1" :project (file-name-as-directory dir) :model "demo:scripted"
           :input 1000000 :output 500000 :cache-read 0 :cache-write 0 :cost 4.0 :list-cost 4.0))
    (harness-cost-compare-test-with-models
        (list (cons "test:rich" (harness-cost-compare-test--rich "test:rich"))
              (cons "test:plain" (harness-cost-compare-test--plain "test:plain")))
      (let ((answer (harness-call 'usage/cost-compare
                                  :models '("test:plain") :reference-model "test:rich" :at 2000.0)))
        (should (= 2 (length (plist-get answer :rows))))
        (should (plist-get (harness-cost-compare-test--row answer "test:rich") :reference))
        (should-not (plist-get (harness-cost-compare-test--row answer "test:plain") :reference))))))

(ert-deftest harness-cost-compare-filters-the-recorded-usage ()
  "The comparison prices the rows the filters select, and no others."
  (harness-cost-compare-test-with
    (harness-cost-compare-test--record
     (list :ts 1000.0 :session "s1" :project (file-name-as-directory dir) :model "demo:scripted"
           :input 1000000 :output 0 :cache-read 0 :cache-write 0 :cost 1.0 :list-cost 1.0))
    (harness-cost-compare-test--record
     (list :ts 2000.0 :session "s2" :project (file-name-as-directory dir) :model "demo:scripted"
           :input 3000000 :output 0 :cache-read 0 :cache-write 0 :cost 3.0 :list-cost 3.0))
    (harness-cost-compare-test-with-models
        (list (cons "test:rich" (harness-cost-compare-test--rich "test:rich")))
      (let* ((answer (harness-call 'usage/cost-compare :models '("test:rich") :session "s2" :at 2000.0))
             (recorded (plist-get answer :recorded)))
        (should (= 3000000 (plist-get recorded :input)))
        (should (= 3.0 (plist-get recorded :list-cost)))
        ;; 3000000 input at $3/M = $9.
        (should (= 9.0 (plist-get (car (plist-get answer :rows)) :cost)))))))

;;;; The view

(defun harness-cost-compare-test--text ()
  "Return the comparison buffer's text."
  (with-current-buffer harness-ui-cost-compare--buffer-name
    (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-cost-compare-test--ready-p ()
  "Non-nil when the comparison buffer has an answer to draw."
  (let ((buffer (get-buffer harness-ui-cost-compare--buffer-name)))
    (and buffer (buffer-local-value 'harness-ui-cost-compare--data buffer) t)))

(ert-deftest harness-ui-cost-compare-shows-the-table ()
  "The cost page opens the comparison, and the buffer lists the recorded
totals and each priced model with its cost.  The recorded cost and the
budgets are untouched."
  (harness-cost-compare-test-with
    (let ((project (file-name-as-directory dir)))
      (harness-cost-compare-test--record
       (list :ts (float-time) :session "s1" :project project :model "demo:scripted"
             :input 1000000 :output 100000 :cache-read 0 :cache-write 100000
             :cost 0.0 :list-cost 0.5))
      (harness-call 'usage/set-budget '(:scope period :period month :amount 10 :days all))
      (harness-test-wait (lambda () (> (hash-table-count harness-ui--models) 0)) 5 "model catalogue")
      ;; The cost page offers the comparison: `C' and a header button.
      (harness-usage)
      (harness-test-wait (lambda () (and harness-ui-usage--data (not harness-ui-usage--loading))) 5 "dashboard")
      (should (eq 'harness-ui-usage-compare-costs (lookup-key harness-ui-usage-mode-map (kbd "C"))))
      (should (string-match-p "compare" (harness-ui-usage--header 200)))
      ;; Opened from there, the comparison fills its own buffer.
      (harness-ui-usage-compare-costs)
      (harness-test-wait #'harness-cost-compare-test--ready-p 5 "comparison")
      (let ((text (harness-cost-compare-test--text)))
        (should (string-match-p "Cost at other prices" text))
        (should (string-match-p "vs recorded" text))
        (should (string-match-p "Recorded: \\$0 billed, \\$0\\.500 at API prices, 1 calls" text))
        (should (string-match-p "1\\.00M input" text))
        ;; The demo model: 1000000*1 + 100000*2 + 100000*1.25 over 1e6 = 1.325,
        ;; against the recorded $0.500 at API prices.
        (should (string-match-p "Demo scripted" text))
        (should (string-match-p "\\+\\$0\\.825" text)))
      ;; Read-only: the recorded usage and the budgets stand as they were.
      (should (= 0.0 (plist-get (harness-cost-compare-test--totals) :cost)))
      (should (= 0.5 (plist-get (harness-cost-compare-test--totals) :list-cost)))
      (should (= 1 (length (harness-call 'usage/budgets)))))))

(provide 'harness-cost-compare-test)
;;; harness-cost-compare-test.el ends here
