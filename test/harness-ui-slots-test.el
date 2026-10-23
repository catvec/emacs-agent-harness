;;; harness-ui-slots-test.el --- Tests for the task slots page  -*- lexical-binding: t; -*-

;;; Commentary:

;; The page is checked from what the harness would say: stubbed answers
;; of `task/slots' go in through `harness-ui-slots--fetch', and no
;; harness, connection or task board is needed.  Where things sit is
;; told with `(space :align-to COLUMN)', so a rendering is read the way
;; the display draws it: `harness-ui-slots-test--visual' writes every
;; stretch out as spaces.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)
(require 'harness-ui-slots)

(defvar harness-ui-tasks--dir)
(defvar harness-ui--sessions)
(declare-function harness-ui-pending--forget-all "harness-ui-pending")
(declare-function harness-module-requires "harness-core")
(declare-function harness-module-init-fn "harness-core")
(declare-function harness-module-shutdown-fn "harness-core")

(defvar harness-ui-slots-test--now 1000000.0
  "The time the data of a test is made for, and the pure renderings are of.
Tests that draw the page in its buffer, which reads the clock, run with
the time of their start (`harness-ui-slots-test-with').")

(defvar harness-ui-slots-test--requests nil
  "The requests the page made, newest first: (DIR CALLBACK ON-ERROR).")

(defvar harness-ui-slots-test--answer nil
  "What the harness answers a request with: (data PLIST), (fail MESSAGE) or `hold'.
`hold' keeps the request, to answer it later by hand.")

(defvar harness-ui-slots-test--displayed nil
  "The buffers `harness-ui-display-view' was asked to show, newest first.")

(defvar harness-ui-slots-test--opened nil
  "The sessions the page opened, newest first: (ID . POSITION).")

(defun harness-ui-slots-test--fetch (dir callback on-error)
  "Stand in for `harness-ui-slots--fetch': answer as the test says."
  (push (list dir callback on-error) harness-ui-slots-test--requests)
  (pcase harness-ui-slots-test--answer
    (`(data ,data) (funcall callback data))
    (`(fail ,message) (funcall on-error message))
    (_ nil)))

(defmacro harness-ui-slots-test-with (&rest body)
  "Run BODY with the page's request answered by the test, nothing displayed.
The opener of sessions only records what it was asked to open."
  (declare (indent 0))
  `(let ((harness-ui-slots-test--now (float-time))
         (harness-ui-slots-test--requests nil)
         (harness-ui-slots-test--answer nil)
         (harness-ui-slots-test--displayed nil)
         (harness-ui-slots-test--opened nil))
     (clrhash harness-ui--sessions)
     (cl-letf (((symbol-function 'harness-ui-slots--fetch) #'harness-ui-slots-test--fetch)
               ((symbol-function 'harness-ui-display-view)
                (lambda (buffer &optional _position) (push buffer harness-ui-slots-test--displayed)))
               ((symbol-function 'harness-ui-session-opener)
                (lambda (&optional position)
                  (lambda (id) (push (cons id position) harness-ui-slots-test--opened)))))
       (unwind-protect (progn ,@body)
         (clrhash harness-ui--sessions)
         (harness-ui-pending--forget-all)
         (when-let* ((buffer (get-buffer harness-ui-slots--buffer-name)))
           (kill-buffer buffer))))))

;;;; Data and readings

(defun harness-ui-slots-test--holder (id title priority state ago &rest props)
  "A holder entry of `task/slots': task ID, called TITLE, at PRIORITY in STATE.
It began AGO seconds before `harness-ui-slots-test--now'; its session is
\"s-ID\" unless PROPS say otherwise."
  (let ((holder (list :id id :title title :session (concat "s-" id) :priority priority :state state
                      :since (- harness-ui-slots-test--now ago) :sent-back :false)))
    (while props (setq holder (plist-put holder (pop props) (pop props))))
    holder))

(defun harness-ui-slots-test--queued (id title priority ago &optional reason)
  "A queue entry of `task/slots': task ID, TITLE, at PRIORITY, waiting AGO seconds."
  (list :id id :title title :priority priority
        :since (- harness-ui-slots-test--now ago) :reason reason))

(defun harness-ui-slots-test--wait (priority seconds)
  "A recorded wait of `task/slots': a task of PRIORITY waited SECONDS."
  (list :id (format "t-w%s" (random 100000)) :priority priority :seconds (float seconds)
        :at (- harness-ui-slots-test--now 100)))

(defun harness-ui-slots-test--busy ()
  "The holders of a busy project: high, medium and low, oldest first."
  (list (harness-ui-slots-test--holder "t-low" "Add secret redaction tools" "low" "blocked" 4680.0)
        (harness-ui-slots-test--holder "t-high" "Fix stuck model responses" "high" "running" 2460.0)
        (harness-ui-slots-test--holder "t-mid" "Plan task board polish" "medium" "running" 150.0)))

(defun harness-ui-slots-test--busy-queue ()
  "A queue of two high, one medium and one low task, with distinct waits."
  (list (harness-ui-slots-test--queued "t-q1" "Session list rework" "high" 3900.0)
        (harness-ui-slots-test--queued "t-q2" "Compose box bundle" "high" 3480.0 "sent-back")
        (harness-ui-slots-test--queued "t-q3" "Fullscreen layout fix" "medium" 720.0)
        (harness-ui-slots-test--queued "t-q4" "Pet commentary overhaul" "low" 180.0 "preempted")))

(defun harness-ui-slots-test--data (&rest props)
  "An answer of `task/slots' for a project with 4 slots, nothing in them.
PROPS replace the keys they name."
  (let ((data (list :project "/home/me/src/acme/" :limit 4 :suspended :false :days 7
                    :holders nil :queue nil :waits nil)))
    (while props (setq data (plist-put data (pop props) (pop props))))
    data))

(defun harness-ui-slots-test--visual (text)
  "Return TEXT as the display draws it: each `(space :align-to N)' written out.
The lines come out as long as their columns say, so what the display
aligns is aligned here; text is counted by its width in columns.  A
string a run of text is displayed as (the ellipsis a cell is cut with)
stands for the whole run."
  (let ((column 0) (out nil) (i 0))
    (while (< i (length text))
      (let ((char (aref text i))
            (display (get-text-property i 'display text)))
        (cond
         ((and (consp display) (eq (car display) 'space) (plist-get (cdr display) :align-to))
          (let ((to (plist-get (cdr display) :align-to)))
            (when (> to column)
              (push (make-string (- to column) ?\s) out)
              (setq column to))))
         ((stringp display)
          (unless (and (> i 0) (eq display (get-text-property (1- i) 'display text)))
            (push display out)
            (setq column (+ column (string-width display)))))
         ((eq char ?\n) (push "\n" out) (setq column 0))
         (t (push (string char) out) (setq column (+ column (char-width char))))))
      (setq i (1+ i)))
    (apply #'concat (nreverse out))))

(defun harness-ui-slots-test--lines (text)
  "Return the lines of TEXT as drawn (see `harness-ui-slots-test--visual')."
  (split-string (harness-ui-slots-test--visual text) "\n"))

(defun harness-ui-slots-test--page (data &optional width)
  "Return the page for DATA as lines, drawn for WIDTH (100) columns."
  (harness-ui-slots-test--lines
   (harness-ui-slots--text data (or width 100) harness-ui-slots-test--now "/home/me/src/acme/")))

(defun harness-ui-slots-test--line-with (lines regexp)
  "Return the first of LINES matching REGEXP, or nil."
  (cl-find-if (lambda (line) (string-match-p regexp line)) lines))

(defun harness-ui-slots-test--section (lines)
  "Return the lines of the In use section of LINES, the page.
They follow its heading, up to the blank line that ends it."
  (let ((rest (cdr (member " In use" lines))))
    (seq-take-while (lambda (line) (not (string-empty-p line))) rest)))

(defun harness-ui-slots-test--cache (id &rest props)
  "Cache the session ID as the UI would know it, with PROPS; return it.
It is named ID, idle, on a model with a context window, unless PROPS
say otherwise."
  (let ((session (append props (list :id id :name id :status "idle" :kind "task"
                                     :model "demo:scripted" :context-window 200000
                                     :usage (list :cost 0 :context 0)))))
    (puthash id session harness-ui--sessions)
    session))

(defun harness-ui-slots-test--count (regexp lines)
  "Return how many times REGEXP matches in LINES, one line at a time."
  (cl-loop for line in lines
           sum (let ((n 0) (at 0))
                 (while (string-match regexp line at)
                   (cl-incf n)
                   (setq at (max (1+ at) (match-end 0))))
                 n)))

(defun harness-ui-slots-test--cells (line)
  "Return the cells of LINE, a table row: its words, split on runs of two spaces.
The arrow of a priority is left out of its label."
  (let ((cells (split-string line "  +" t "[ ]+")))
    (cons (replace-regexp-in-string "\\`[^ ]+ \\(high\\|low\\)\\'" "\\1" (car cells))
          (cdr cells))))

(defun harness-ui-slots-test--arrow (priority)
  "Return the arrow of PRIORITY as the page draws it."
  (substring-no-properties (harness-ui-icon (if (equal priority "high")
                                                'harness-icon-priority-high
                                              'harness-icon-priority-low))))

(defun harness-ui-slots-test--open (data &optional dir)
  "Open the page for DIR with DATA as the harness's answer; return its buffer."
  (setq harness-ui-slots-test--answer (list 'data data))
  (harness-slots (or dir "/home/me/src/acme/")))

(defun harness-ui-slots-test--first (key)
  "Return where the text of the box or row KEY starts in the buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward 'harness-slot-key key #'equal)))
      (prop-match-beginning match))))

(defun harness-ui-slots-test--goto (key &optional lines offset)
  "In the page, go to the box or row KEY, LINES down from its first line, OFFSET in."
  (goto-char (or (harness-ui-slots-test--first key) (error "No %s on the page" key)))
  (forward-line (or lines 0))
  (while (not (equal (get-text-property (point) 'harness-slot-key) key)) (forward-char 1))
  (forward-char (or offset 0)))

;;;; Small pieces

(ert-deftest harness-ui-slots-duration-reads-as-the-board-does ()
  (should (equal "0s" (harness-ui-slots--duration 0)))
  (should (equal "40s" (harness-ui-slots--duration 40.7)))
  (should (equal "12m" (harness-ui-slots--duration 725)))
  (should (equal "59m" (harness-ui-slots--duration 3599)))
  (should (equal "1h00m" (harness-ui-slots--duration 3600)))
  (should (equal "2h05m" (harness-ui-slots--duration 7500)))
  (should (equal "26h30m" (harness-ui-slots--duration (+ (* 26 3600) 1800))))
  ;; A clock that runs behind never shows a negative time.
  (should (equal "0s" (harness-ui-slots--duration -30)))
  (should (equal "0s" (harness-ui-slots--duration nil))))

(ert-deftest harness-ui-slots-is-a-module-found-in-lisp-ui ()
  (let ((module (gethash 'ui-slots harness--modules)))
    (should module)
    ;; The board's module: its events, its clock, its limit button.
    (should (equal '(ui ui-tasks) (harness-module-requires module)))
    (should (eq #'harness-ui-slots--init (harness-module-init-fn module)))
    (should (eq #'harness-ui-slots--shutdown (harness-module-shutdown-fn module))))
  (let ((file (expand-file-name "lisp/ui/harness-ui-slots.el" harness-test-root))
        (harness-enabled-modules t)
        (harness-disabled-modules nil))
    (should (file-exists-p file))
    (should (member file (harness--module-files)))
    (should (eq 'ui-slots (harness--file-module-name file)))
    (should (harness--ui-module-p 'ui-slots)))
  ;; The command is an autoload cookie away from M-x.
  (should (commandp 'harness-slots))
  (with-temp-buffer
    (insert-file-contents (expand-file-name "lisp/ui/harness-ui-slots.el" harness-test-root))
    (should (re-search-forward "^;;;###autoload\n(defun harness-slots " nil t))))

;;;; What the page shows

(ert-deftest harness-ui-slots-all-free ()
  (let* ((lines (harness-ui-slots-test--page (harness-ui-slots-test--data)))
         (first (car lines)))
    (should (string-match-p "\\` Task slots" first))
    (should (string-match-p "acme" first))
    (should (string-match-p "0 of 4 in use · 4 free · 0 waiting" first))
    ;; Nothing at work: a line says so, and how many slots are free.
    (should (equal '("   nothing holds a slot" "   4 free") (harness-ui-slots-test--section lines)))
    (should-not (harness-ui-slots-test--line-with lines "Name +Status"))
    ;; The queue shows its three priorities, all empty.
    (should (harness-ui-slots-test--line-with lines "Queue · 0 waiting"))
    (dolist (priority '("high" "medium" "low"))
      (should (equal (list priority "–" "–" "–")
                     (harness-ui-slots-test--cells
                      (car (cl-remove-if-not
                            (lambda (line) (string-match-p (format "\\`   [^ ]* *%s +–" priority) line))
                            lines))))))
    (should (harness-ui-slots-test--line-with lines "nobody waits for a slot"))))

(ert-deftest harness-ui-slots-first-line-counts-the-slots ()
  (let ((first (lambda (&rest props)
                 (car (harness-ui-slots-test--page (apply #'harness-ui-slots-test--data props))))))
    (should (string-match-p "3 of 4 in use · 1 free · 4 waiting"
                            (funcall first :holders (harness-ui-slots-test--busy)
                                     :queue (harness-ui-slots-test--busy-queue))))
    (should (string-match-p "4 of 4 in use · 0 free · 0 waiting"
                            (funcall first :holders (append (harness-ui-slots-test--busy)
                                                            (list (harness-ui-slots-test--holder
                                                                   "t-4" "Fourth" "medium" "running" 60.0))))))
    (should (string-match-p "3 in use · no limit"
                            (funcall first :limit nil :holders (harness-ui-slots-test--busy))))
    (should-not (string-match-p "waiting" (funcall first :limit nil :holders (harness-ui-slots-test--busy))))
    (should (string-match-p "3 in use · no limit · 2 waiting"
                            (funcall first :limit nil :holders (harness-ui-slots-test--busy)
                                     :queue (seq-take (harness-ui-slots-test--busy-queue) 2))))
    (should (string-match-p "limit 0: nothing starts by itself · 4 waiting"
                            (funcall first :limit 0 :queue (harness-ui-slots-test--busy-queue))))
    (should (string-match-p "queue suspended"
                            (funcall first :suspended t :queue (harness-ui-slots-test--busy-queue))))
    (should-not (string-match-p "queue suspended" (funcall first)))))

(ert-deftest harness-ui-slots-lists-the-tasks-at-work-in-a-table ()
  (let* ((data (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)))
         (lines (harness-ui-slots-test--page data))
         (section (harness-ui-slots-test--section lines)))
    (should (string-match-p "3 of 4 in use · 1 free · 0 waiting" (car lines)))
    ;; The section has its heading, then a header row with the session list's
    ;; columns and At work, the slots' own.
    (should (equal " In use" (nth (1- (cl-position " In use" lines :test #'equal)) (cdr lines))))
    (should (string-match-p "\\` +Name +Status +At work +Priority +Context +Cost +Last msg\\'"
                            (nth 0 section)))
    ;; One row for each task, the longest at work first; the arrow of a high or
    ;; a low priority, none for the default.
    (should (string-match-p (format "Add secret redaction tools +blocked +1h18m +%s"
                                    (regexp-quote (harness-ui-slots-test--arrow "low")))
                            (nth 1 section)))
    (should (string-match-p (format "Fix stuck model responses +running +41m +%s"
                                    (regexp-quote (harness-ui-slots-test--arrow "high")))
                            (nth 2 section)))
    (should (string-match-p "Plan task board polish +running +2m *\\'" (nth 3 section)))
    ;; Then how many slots are free.
    (should (equal "   1 free" (nth 4 section)))
    (should (= 5 (length section)))
    ;; Nothing on the page is a box.
    (should-not (cl-some (lambda (line) (string-match-p "[╭╮╰╯│]" line)) lines))))

(ert-deftest harness-ui-slots-says-the-state-of-each-task ()
  (let* ((holders (list (harness-ui-slots-test--holder "t-a" "Running one" "medium" "running" 150.0)
                        (harness-ui-slots-test--holder "t-b" "Blocked one" "medium" "blocked" 4680.0)
                        (harness-ui-slots-test--holder "t-c" "Starting one" "medium" "starting" 10.0
                                                       :session nil)
                        (harness-ui-slots-test--holder "t-d" "Waiting one" "medium" "waiting" 725.0)
                        (harness-ui-slots-test--holder "t-e" "Sent back one" "medium" "running" 40.0
                                                       :sent-back t)))
         (rows (cdr (harness-ui-slots-test--section
                     (harness-ui-slots-test--page
                      (harness-ui-slots-test--data :limit 5 :holders holders) 140)))))
    ;; The longest at work first; what a row cannot say goes on a line under it.
    (should (= 7 (length rows)))
    (should (string-match-p "Blocked one +blocked +1h18m" (nth 0 rows)))
    (should (string-match-p "Waiting one +waiting +12m" (nth 1 rows)))
    (should (string-match-p "\\` +waits on its workers\\'" (nth 2 rows)))
    (should (string-match-p "Running one +running +2m" (nth 3 rows)))
    (should (string-match-p "Sent back one +running +40s" (nth 4 rows)))
    (should (string-match-p "\\` +sent back\\'" (nth 5 rows)))
    ;; A task that starts has no time at work yet.
    (should (string-match-p "Starting one +starting *\\'" (nth 6 rows)))))

(ert-deftest harness-ui-slots-cuts-a-long-title-to-its-column ()
  (let* ((title "A title far longer than any column can hold, even a wide one, and then some")
         (holders (list (harness-ui-slots-test--holder "t-a" title "high" "running" 725.0)))
         (lines (harness-ui-slots-test--page (harness-ui-slots-test--data :holders holders)))
         (row (harness-ui-slots-test--line-with lines "A title far")))
    ;; Cut with an ellipsis, the state where it is in every row.
    (should (string-match-p "\\` .  A title far longer than any[a-z ]*… running +12m" row))
    (should (< (string-width row) 100))
    ;; Wide enough for it, it is not cut.
    (let ((row (harness-ui-slots-test--line-with
                (harness-ui-slots-test--page (harness-ui-slots-test--data :holders holders) 200)
                "A title far")))
      (should (string-match-p "A title far longer than any column can … +running" row)))
    ;; Newlines and tabs in a title are spaces.
    (let ((lines (harness-ui-slots-test--page
                  (harness-ui-slots-test--data
                   :holders (list (harness-ui-slots-test--holder "t-b" "Two\nlines\tand a tab" "medium"
                                                                 "running" 60.0))))))
      (should (harness-ui-slots-test--line-with lines "Two lines and a tab +running +1m")))))

(ert-deftest harness-ui-slots-fits-the-table-to-the-window ()
  (let ((data (harness-ui-slots-test--data :limit 9 :holders (harness-ui-slots-test--busy))))
    (dolist (width '(40 50 63 80 100 140))
      (let* ((section (harness-ui-slots-test--section (harness-ui-slots-test--page data width)))
             (header (car section))
             (rows (seq-take (cdr section) 3))
             (status (string-match "Status" header))
             (work-end (+ (string-match "At work" header) (length "At work"))))
        ;; No line of the table is as wide as the window.
        (dolist (line section)
          (should (< (string-width line) width)))
        (dolist (row rows)
          ;; Status starts under its label, whatever the name before it.
          (should (= status (string-match "blocked\\|running" row)))
          ;; The times at work are right-aligned, and end under At work.
          (string-match "[0-9]+[hm]\\(?:[0-9]+m\\)?" row status)
          (should (= work-end (match-end 0)))))))
  ;; A narrow window leaves out the columns the table needs least, the last
  ;; first, and keeps the name its room.
  (let ((header (lambda (width)
                  (harness-ui-slots-test--line-with
                   (harness-ui-slots-test--page
                    (harness-ui-slots-test--data :limit 9 :holders (harness-ui-slots-test--busy)) width)
                   "Name +Status"))))
    (dolist (case '((100 "Last msg" "Cost" "Context" "Priority")
                    (80 "Cost" "Context" "Priority")
                    (70 "Context" "Priority")
                    (55 "Priority")
                    (45)))
      (let ((shown (funcall header (car case))))
        (dolist (name '("Last msg" "Cost" "Context" "Priority"))
          (if (member name (cdr case))
              (should (string-match-p name shown))
            (should-not (string-match-p name shown))))
        (should (string-match-p "Status +At work" shown))))))

(ert-deftest harness-ui-slots-no-limit-shows-only-the-slots-in-use ()
  (let* ((data (harness-ui-slots-test--data :limit nil :holders (harness-ui-slots-test--busy)))
         (lines (harness-ui-slots-test--page data))
         (section (harness-ui-slots-test--section lines)))
    (should (string-match-p "3 in use · no limit" (car lines)))
    ;; The header row and three rows, and no word of free slots.
    (should (= 4 (length section)))
    (should-not (harness-ui-slots-test--line-with lines "free"))
    ;; Nothing at work and no limit: the section says so.
    (should (equal '("   nothing holds a slot")
                   (harness-ui-slots-test--section
                    (harness-ui-slots-test--page (harness-ui-slots-test--data :limit nil)))))))

(ert-deftest harness-ui-slots-limit-zero-has-no-slots ()
  (let* ((data (harness-ui-slots-test--data :limit 0 :queue (harness-ui-slots-test--busy-queue)))
         (lines (harness-ui-slots-test--page data)))
    (should (string-match-p "limit 0: nothing starts by itself" (car lines)))
    (should (equal '("   nothing holds a slot") (harness-ui-slots-test--section lines)))
    (should (harness-ui-slots-test--line-with lines "Queue · 4 waiting"))
    ;; Tasks still at work when it was lowered to 0 keep their rows, all over it.
    (let ((lines (harness-ui-slots-test--page
                  (harness-ui-slots-test--data :limit 0 :holders (harness-ui-slots-test--busy)))))
      (should (string-match-p "3 still at work" (car lines)))
      (should (= 7 (length (harness-ui-slots-test--section lines))))
      (should (= 3 (cl-count-if (lambda (line) (string-match-p "\\`  +over the limit\\'" line)) lines))))))

(ert-deftest harness-ui-slots-holders-over-the-limit-are-marked ()
  ;; The limit was lowered to 2 under three tasks at work: the newest is over.
  (let* ((data (harness-ui-slots-test--data :limit 2 :holders (harness-ui-slots-test--busy)))
         (lines (harness-ui-slots-test--page data))
         (section (harness-ui-slots-test--section lines)))
    (should (string-match-p "3 of 2 in use · 0 free · 1 over the limit" (car lines)))
    ;; Its row, the third, has the note under it; the others none; and no slot is free.
    (should (= 5 (length section)))
    (should (string-match-p "Plan task board polish" (nth 3 section)))
    (should (string-match-p "\\`  +over the limit\\'" (nth 4 section)))
    (should (= 1 (cl-count-if (lambda (line) (string-match-p "over the limit" line)) (cdr lines))))
    (should-not (harness-ui-slots-test--line-with lines "\\`   [0-9]+ free\\'"))))

(ert-deftest harness-ui-slots-counts-the-free-slots-in-a-line ()
  ;; A limit of 40 with two tasks at work: their rows, and one line for the rest.
  (let* ((holders (seq-take (harness-ui-slots-test--busy) 2))
         (section (harness-ui-slots-test--section
                   (harness-ui-slots-test--page (harness-ui-slots-test--data :limit 40 :holders holders) 140))))
    (should (= 4 (length section)))
    (should (equal "   38 free" (car (last section))))))

(ert-deftest harness-ui-slots-says-a-suspended-queue ()
  (let ((lines (harness-ui-slots-test--page
                (harness-ui-slots-test--data :suspended t :queue (harness-ui-slots-test--busy-queue)))))
    (should (string-match-p "queue suspended" (car lines)))
    (should (harness-ui-slots-test--line-with lines "Queue · 4 waiting · suspended"))))

;;;; The session list's rows

(ert-deftest harness-ui-slots-rows-are-the-session-lists ()
  (harness-ui-slots-test-with
    ;; The UI knows the session of the high priority task: its figures are the
    ;; list's cells for it, not a rendering of the page's own.
    (let ((session (harness-ui-slots-test--cache "s-t-high" :context-window 200000
                                                 :usage (list :cost 1.25 :context 52000)
                                                 :last-message (- harness-ui-slots-test--now 90))))
      (let* ((lines (harness-ui-slots-test--page
                     (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy))))
             (row (harness-ui-slots-test--line-with lines "Fix stuck model responses")))
        (dolist (column '("Context" "Cost" "Last msg"))
          (let ((cell (substring-no-properties
                       (funcall (plist-get (harness-ui-sessions-column column) :cell) session 0))))
            (should (string-match-p (regexp-quote cell) row))))
        (should (string-match-p "52.0k/200k" row))
        (should (string-match-p "\\$1.25" row))
        (should (string-match-p "1m ago" row))
        ;; The session list's own row, cell for cell: the same text under the same labels.
        (let ((list-row (with-temp-buffer
                          (harness-ui-sessions-insert-row
                           (harness-ui-sessions-format
                            (list (harness-ui-sessions-column "Context")))
                           (harness-ui-sessions-cells (list (harness-ui-sessions-column "Context")) session))
                          (string-trim (harness-ui-slots-test--visual (buffer-string))))))
          (should (equal "52.0k/200k" list-row))))
      ;; The tasks whose session it does not know show no figures, not zeros.
      (let ((row (harness-ui-slots-test--line-with
                  (harness-ui-slots-test--page (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)))
                  "Plan task board polish")))
        (should-not (string-match-p "/\\|\\$\\|ago" row))))))

(ert-deftest harness-ui-slots-the-line-of-a-request-fits-the-window ()
  ;; A long question is cut to what the buttons leave of the window, so the
  ;; line does not wrap in a narrow one.
  (harness-ui-slots-test-with
    (harness-ui-slots-test--cache "s-t-low" :status "blocked"
                                  :pending (list (list :id "q-1" :kind "question"
                                                       :payload (list :question "Should /health check the database, or only the process?"
                                                                      :options '("both" "process")))))
    (dolist (width '(60 80 140))
      (let* ((lines (harness-ui-slots-test--page
                     (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)) width))
             (request (harness-ui-slots-test--line-with lines "\\[Answer…\\]")))
        (should request)
        (should (< (string-width request) width))
        (should (string-match-p "has a question for you · Should /health" request))))
    ;; Wide enough, the question is whole.
    (should (string-match-p "or only the process\\?"
                            (harness-ui-slots-test--line-with
                             (harness-ui-slots-test--page
                              (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)) 200)
                             "\\[Answer…\\]")))))

(ert-deftest harness-ui-slots-a-blocked-task-shows-what-it-waits-on ()
  (harness-ui-slots-test-with
    (harness-ui-slots-test--cache "s-t-low" :status "blocked"
                                  :pending (list (list :id "p-1" :kind "permission"
                                                       :payload (list :title "Bash: rm -rf build/" :tool "bash"
                                                                      :options '("allow-once" "allow-session"
                                                                                 "deny-once")))))
    (let* ((buffer (harness-ui-slots-test--open
                    (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy))))
           (answers nil))
      (with-current-buffer buffer
        (let* ((lines (harness-ui-slots-test--lines (buffer-string)))
               (at (cl-position-if (lambda (line) (string-match-p "Add secret redaction tools" line)) lines))
               (request (nth (1+ at) lines)))
          ;; Under the row, as under the session list's: the buttons that answer, what it is.
          (should (string-match-p "\\[Allow\\].*\\[Deny\\].*needs your permission.*Bash" request))
          ;; The line is the task's: its keys, and the permission keys of the session list.
          (harness-ui-slots-test--goto "task:t-low" 1 6)
          (should (equal "s-t-low" (get-text-property (point) 'harness-slot-session)))
          (should (equal "s-t-low" (harness-ui-session-at-point)))
          (should (eq #'harness-ui-sessions-allow (key-binding "y")))
          (should (eq #'harness-ui-sessions-deny (key-binding "n")))
          (cl-letf (((symbol-function 'harness-ui-pending-answer-first-permission)
                     (lambda (id option) (push (list id option) answers))))
            (call-interactively (key-binding "y"))
            (call-interactively (key-binding "n")))
          (should (equal '(("s-t-low" "allow-once") ("s-t-low" "deny-once")) (nreverse answers)))
          ;; A task that waits on nothing has no such line.
          (should (string-match-p "Fix stuck model responses" (nth (+ at 2) lines)))
          ;; The request's buttons are drawn the same again: nothing to redraw.
          (should-not (harness-ui-slots--render)))))))

;;;; The queue and the waits

(ert-deftest harness-ui-slots-queue-by-priority ()
  (let* ((data (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)
                                            :queue (harness-ui-slots-test--busy-queue)))
         (lines (harness-ui-slots-test--page data))
         (row (lambda (priority)
                (harness-ui-slots-test--cells
                 (car (cl-remove-if-not
                       (lambda (line) (string-match-p (format "\\`   [^ ]* *%s +[0-9–]" priority) line))
                       (seq-take (cdr (member (harness-ui-slots-test--line-with lines "Queue ") lines)) 5)))))))
    (should (harness-ui-slots-test--line-with lines "Queue · 4 waiting"))
    (should (harness-ui-slots-test--line-with lines "priority +waiting +longest +average"))
    ;; Two high waited 65m and 58m: the longest so far 1h05m, the average 61.5m.
    (should (equal '("high" "2" "1h05m" "1h01m") (funcall row "high")))
    (should (equal '("medium" "1" "12m" "12m") (funcall row "medium")))
    (should (equal '("low" "1" "3m" "3m") (funcall row "low")))))

(ert-deftest harness-ui-slots-queue-columns-end-together ()
  ;; The numbers are right-aligned: each column ends in the same place on every row.
  (let* ((data (harness-ui-slots-test--data :queue (harness-ui-slots-test--busy-queue)))
         (lines (harness-ui-slots-test--page data))
         (start (cl-position-if (lambda (line) (string-match-p "priority +waiting" line)) lines))
         (rows (seq-take (nthcdr start lines) 4)))
    (should (= 4 (length rows)))
    ;; A column ends where its last character is.
    (dolist (end harness-ui-slots--table-ends)
      (dolist (row rows)
        (should (>= (length row) end))
        (should-not (eq ?\s (aref row (1- end))))
        (should (or (= (length row) end) (eq ?\s (aref row end))))))
    ;; The same in the table of the waits.
    (let* ((lines (harness-ui-slots-test--page
                   (harness-ui-slots-test--data :waits (list (harness-ui-slots-test--wait "high" 90)))))
           (start (cl-position-if (lambda (line) (string-match-p "priority +started" line)) lines))
           (rows (seq-take (nthcdr start lines) 4)))
      (dolist (end harness-ui-slots--table-ends)
        (dolist (row rows)
          (should (>= (length row) end))
          (should-not (eq ?\s (aref row (1- end)))))))))

(ert-deftest harness-ui-slots-next-in-line-follows-the-queue ()
  (let* ((queue (append (harness-ui-slots-test--busy-queue)
                        (list (harness-ui-slots-test--queued "t-q5" "Fifth" "medium" 100.0)
                              (harness-ui-slots-test--queued "t-q6" "Sixth" "low" 90.0)
                              (harness-ui-slots-test--queued "t-q7" "Seventh" "low" 80.0))))
         (lines (harness-ui-slots-test--page (harness-ui-slots-test--data :queue queue)))
         (next (cdr (member (harness-ui-slots-test--line-with lines "Next in line") lines))))
    ;; The first five, in the order they start, with how long each waited.
    (should (string-match-p "\\` +1\\. +[^ ]* *Session list rework +1h05m\\'" (nth 0 next)))
    (should (string-match-p "\\` +2\\. +[^ ]* *Compose box bundle · sent back +58m\\'" (nth 1 next)))
    (should (string-match-p "\\` +3\\. +Fullscreen layout fix +12m\\'" (nth 2 next)))
    (should (string-match-p "\\` +4\\. +[^ ]* *Pet commentary overhaul · pre-empted +3m\\'" (nth 3 next)))
    (should (string-match-p "\\` +5\\. +Fifth +1m\\'" (nth 4 next)))
    (should (string-match-p "… and 2 more" (nth 5 next)))
    (should-not (harness-ui-slots-test--line-with lines "Sixth"))
    ;; The arrow of a priority is there, medium has none.
    (should (string-match-p (regexp-quote (harness-ui-slots-test--arrow "high")) (nth 0 next)))
    (should (string-match-p (regexp-quote (harness-ui-slots-test--arrow "low")) (nth 3 next)))
    ;; Titles start in one column whether or not they have an arrow.
    (let ((columns (mapcar (lambda (line) (string-match "[A-Z][a-z]" line (string-match "\\." line)))
                           (seq-take next 5))))
      (should (apply #'= columns)))))

(ert-deftest harness-ui-slots-waits-by-priority ()
  (let* ((waits (list (harness-ui-slots-test--wait "high" 60) (harness-ui-slots-test--wait "high" 720)
                      (harness-ui-slots-test--wait "medium" 2460) (harness-ui-slots-test--wait "medium" 30)
                      (harness-ui-slots-test--wait "medium" 90)
                      (harness-ui-slots-test--wait "low" 1500)))
         (lines (harness-ui-slots-test--page (harness-ui-slots-test--data :waits waits :days 7)))
         (section (cdr (member (harness-ui-slots-test--line-with lines "Waited for a slot") lines)))
         (row (lambda (priority)
                (harness-ui-slots-test--cells
                 (car (cl-remove-if-not (lambda (line) (string-match-p (format "\\`   [^ ]* *%s +[0-9–]" priority) line))
                                        (seq-take section 5)))))))
    (should (harness-ui-slots-test--line-with lines "Waited for a slot · last 7 days"))
    (should (harness-ui-slots-test--line-with lines "priority +started +average +longest"))
    ;; How many started, the average wait and the longest.
    (should (equal '("high" "2" "6m" "12m") (funcall row "high")))
    (should (equal '("medium" "3" "14m" "41m") (funcall row "medium")))
    (should (equal '("low" "1" "25m" "25m") (funcall row "low")))
    ;; Without a wait of a priority: dashes.  And the days it counts are the answer's.
    (let ((lines (harness-ui-slots-test--page (harness-ui-slots-test--data :days 1 :waits nil))))
      (should (harness-ui-slots-test--line-with lines "Waited for a slot · last day"))
      (should (= 3 (cl-count-if (lambda (line) (string-match-p "–  +–  +–" line))
                                (cdr (member (harness-ui-slots-test--line-with lines "Waited for a slot")
                                             lines))))))
    (should (harness-ui-slots-test--line-with
             (harness-ui-slots-test--page (harness-ui-slots-test--data :days 30))
             "Waited for a slot · last 30 days"))))

(ert-deftest harness-ui-slots-queue-waits-grow-with-the-clock ()
  (let* ((data (harness-ui-slots-test--data :queue (list (harness-ui-slots-test--queued "t-q" "Waiter" "high" 30.0))))
         (at (lambda (seconds) (harness-ui-slots--text data 100 (+ harness-ui-slots-test--now seconds) nil))))
    (should (string-match-p "Waiter +30s" (harness-ui-slots-test--visual (funcall at 0))))
    (should (string-match-p "Waiter +5m" (harness-ui-slots-test--visual (funcall at 270))))
    (should (string-match-p "Waiter +1h00m" (harness-ui-slots-test--visual (funcall at 3570))))))

;;;; The command, the buffer, the answers

(ert-deftest harness-ui-slots-command-opens-the-page ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)))))
      (should (equal harness-ui-slots--buffer-name (buffer-name buffer)))
      (should (equal (list buffer) harness-ui-slots-test--displayed))
      (with-current-buffer buffer
        (should (derived-mode-p 'harness-ui-slots-mode))
        (should (derived-mode-p 'special-mode))
        (should buffer-read-only)
        (should (eq t buffer-undo-list))
        (should-not (buffer-modified-p))
        (should (equal "/home/me/src/acme/" harness-ui-slots--dir))
        (should (equal (list "/home/me/src/acme/")
                       (mapcar #'car harness-ui-slots-test--requests)))
        (should (string-match-p "3 of 4 in use" (buffer-string)))
        ;; Read only: no key types into it, and a redraw is no change of the buffer.
        (should-error (insert "x") :type 'buffer-read-only)))))

(ert-deftest harness-ui-slots-asks-for-the-project-of-the-board-it-is-opened-from ()
  (harness-ui-slots-test-with
    (setq harness-ui-slots-test--answer (list 'data (harness-ui-slots-test--data)))
    (with-temp-buffer
      (setq-local harness-ui-tasks--dir "/home/me/src/board/")
      (harness-slots))
    (should (equal "/home/me/src/board/" (car (car harness-ui-slots-test--requests))))
    ;; Outside a board it is the project of the current directory.
    (let ((default-directory temporary-file-directory))
      (cl-letf (((symbol-function 'harness-ui--default-directory) (lambda () "/home/me/src/here/")))
        (with-temp-buffer (harness-slots))))
    (should (equal "/home/me/src/here/" (car (car harness-ui-slots-test--requests))))
    ;; And for another project the first one's answer is not kept while it comes.
    (setq harness-ui-slots-test--answer 'hold)
    (harness-slots "/home/me/src/other/")
    (with-current-buffer harness-ui-slots--buffer-name
      (should-not harness-ui-slots--data)
      (should (string-match-p "loading…" (buffer-string))))))

(ert-deftest harness-ui-slots-says-loading-until-the-first-answer ()
  (harness-ui-slots-test-with
    (setq harness-ui-slots-test--answer 'hold)
    (let ((buffer (harness-slots "/home/me/src/acme/")))
      (with-current-buffer buffer
        (should harness-ui-slots--loading)
        (should (string-match-p "Task slots +acme" (buffer-string)))
        (should (string-match-p "loading…" (buffer-string)))
        (should-not (string-match-p "Queue" (buffer-string))))
      (funcall (nth 1 (car harness-ui-slots-test--requests)) (harness-ui-slots-test--data))
      (with-current-buffer buffer
        (should-not harness-ui-slots--loading)
        (should-not (string-match-p "loading" (buffer-string)))
        (should (string-match-p "0 of 4 in use" (buffer-string)))))))

(ert-deftest harness-ui-slots-drops-answers-to-an-older-request ()
  (harness-ui-slots-test-with
    (setq harness-ui-slots-test--answer 'hold)
    (let ((buffer (harness-slots "/home/me/src/acme/")))
      (harness-ui-slots-refresh)
      (with-current-buffer buffer (harness-ui-slots-refresh))
      (should (= 3 (length harness-ui-slots-test--requests)))
      (let ((first (nth 1 (nth 2 harness-ui-slots-test--requests)))
            (last (nth 1 (nth 0 harness-ui-slots-test--requests)))
            (old (harness-ui-slots-test--data :limit 2))
            (new (harness-ui-slots-test--data :limit 6)))
        ;; The newest answers first, and a slow older one comes after it.
        (funcall last new)
        (funcall first old)
        (with-current-buffer buffer
          (should (equal 6 (plist-get harness-ui-slots--data :limit)))
          (should (string-match-p "0 of 6 in use" (buffer-string)))
          (should-not (string-match-p "0 of 2 in use" (buffer-string))))))
    ;; A failure of an older request is dropped as well.
    (let ((buffer (get-buffer harness-ui-slots--buffer-name)))
      (with-current-buffer buffer (harness-ui-slots-refresh) (harness-ui-slots-refresh))
      (let ((old (nth 2 (nth 1 harness-ui-slots-test--requests))))
        (funcall old "too late")
        (with-current-buffer buffer
          (should-not harness-ui-slots--error))))))

(ert-deftest harness-ui-slots-answer-to-a-killed-page-is-ignored ()
  (harness-ui-slots-test-with
    (setq harness-ui-slots-test--answer 'hold)
    (let ((buffer (harness-slots "/home/me/src/acme/")))
      (kill-buffer buffer)
      (funcall (nth 1 (car harness-ui-slots-test--requests)) (harness-ui-slots-test--data))
      (funcall (nth 2 (car harness-ui-slots-test--requests)) "nobody listens")
      (should-not (get-buffer harness-ui-slots--buffer-name)))))

(ert-deftest harness-ui-slots-shows-a-failure-in-the-page ()
  (harness-ui-slots-test-with
    (setq harness-ui-slots-test--answer '(fail "Method not found: task/slots"))
    (let ((buffer (harness-slots "/home/me/src/acme/")))
      (with-current-buffer buffer
        (should-not harness-ui-slots--loading)
        (should (string-match-p "Could not load the task slots: Method not found: task/slots"
                                (buffer-string)))
        (should-not (string-match-p "loading…" (buffer-string))))
      ;; A later answer replaces it.
      (setq harness-ui-slots-test--answer (list 'data (harness-ui-slots-test--data)))
      (with-current-buffer buffer (harness-ui-slots-refresh))
      (with-current-buffer buffer
        (should-not harness-ui-slots--error)
        (should-not (string-match-p "Could not" (buffer-string)))
        (should (string-match-p "0 of 4 in use" (buffer-string))))
      ;; A failure after an answer keeps the answer on the page, and says so above it.
      (setq harness-ui-slots-test--answer '(fail "the harness went away"))
      (with-current-buffer buffer (harness-ui-slots-refresh))
      (with-current-buffer buffer
        (should (string-match-p "Could not refresh: the harness went away" (buffer-string)))
        (should (string-match-p "0 of 4 in use" (buffer-string)))
        (should (< (string-match "Could not refresh" (buffer-string))
                   (string-match "Queue" (buffer-string))))))))

(ert-deftest harness-ui-slots-a-replaced-connection-is-no-failure ()
  (harness-ui-slots-test-with
    (setq harness-ui-slots-test--answer 'hold)
    (let ((buffer (harness-slots "/home/me/src/acme/")))
      (cl-letf (((symbol-function 'harness-ui-connection-replaced-p) (lambda (_err) t)))
        (funcall (nth 2 (car harness-ui-slots-test--requests)) "replaced"))
      (with-current-buffer buffer
        (should-not harness-ui-slots--error)))))

;;;; Drawing

(ert-deftest harness-ui-slots-skips-a-redraw-that-changes-nothing ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open
                   (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)))))
      (with-current-buffer buffer
        (let ((tick (buffer-chars-modified-tick))
              (draws 0))
          (cl-letf* ((draw (symbol-function 'harness-ui-slots--draw))
                     ((symbol-function 'harness-ui-slots--draw)
                      (lambda (text) (cl-incf draws) (funcall draw text))))
            ;; The same data, width and clock: the same text, nothing drawn.
            (should-not (harness-ui-slots--render))
            (should-not (harness-ui-slots--render))
            (should (= 0 draws))
            (should (= tick (buffer-chars-modified-tick)))
            ;; Forced, it is drawn.
            (should (harness-ui-slots--render t))
            (should (= 1 draws))
            ;; New data that reads otherwise is drawn.
            (setq harness-ui-slots--data
                  (harness-ui-slots-test--data :limit 5 :holders (harness-ui-slots-test--busy)))
            (should (harness-ui-slots--render))
            (should (= 2 draws))
            (should (string-match-p "3 of 5 in use" (buffer-string)))
            (should-not (buffer-modified-p))
            (should (eq t buffer-undo-list))))))))

(ert-deftest harness-ui-slots-redraws-for-the-clock ()
  (harness-ui-slots-test-with
    (let* ((holder (harness-ui-slots-test--holder "t-a" "Waiter" "medium" "running" 30.0))
           (buffer (harness-ui-slots-test--open (harness-ui-slots-test--data :holders (list holder))))
           (real-float-time (symbol-function 'float-time)))
      (with-current-buffer buffer
        (should (string-match-p "Waiter +running +30s" (harness-ui-slots-test--visual (buffer-string))))
        ;; The same answer, a moment later: the same text, nothing drawn.
        (should-not (harness-ui-slots--render))
        ;; Later, the time on the row reads otherwise: it is drawn.
        (cl-letf (((symbol-function 'float-time)
                   (lambda (&optional time)
                     (if time (funcall real-float-time time) (+ (funcall real-float-time) 400.0)))))
          (should (harness-ui-slots--render))
          (should-not (harness-ui-slots--render)))
        (should (string-match-p "Waiter +running +7m" (harness-ui-slots-test--visual (buffer-string))))))))

(ert-deftest harness-ui-slots-redraws-for-the-width ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open
                   (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)))))
      (with-current-buffer buffer
        (let ((header (lambda ()
                        (harness-ui-slots-test--line-with
                         (harness-ui-slots-test--lines (buffer-string)) "Name +Status"))))
          (should (string-match-p "Cost +Last msg" (funcall header)))
          (cl-letf (((symbol-function 'harness-ui-slots--width) (lambda () 40)))
            (should (harness-ui-slots--render))
            (should-not (string-match-p "Last msg\\|Cost\\|Context" (funcall header)))
            (should-not (harness-ui-slots--render)))
          (should (harness-ui-slots--render))
          (should (string-match-p "Cost +Last msg" (funcall header))))))))

(ert-deftest harness-ui-slots-width-is-the-widest-window-showing-the-page ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open (harness-ui-slots-test--data))))
      (should (equal 100 (with-current-buffer buffer (harness-ui-slots--width))))
      (save-window-excursion
        (set-window-buffer (selected-window) buffer)
        (should (= (window-body-width (selected-window))
                   (with-current-buffer buffer (harness-ui-slots--width))))))))

(ert-deftest harness-ui-slots-keeps-point-on-its-row ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open
                   (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)
                                                :queue (harness-ui-slots-test--busy-queue)))))
      (with-current-buffer buffer
        ;; In the high priority task's row, 8 characters in.
        (harness-ui-slots-test--goto "task:t-high" 0 8)
        (let ((around (buffer-substring-no-properties (- (point) 4) (+ (point) 3))))
          (should (equal "task:t-high" (get-text-property (point) 'harness-slot-key)))
          ;; Another task becomes the oldest: the rows change places, and the line
          ;; the row is on.
          (setq harness-ui-slots--data
                (harness-ui-slots-test--data
                 :holders (cons (harness-ui-slots-test--holder "t-new" "Newcomer" "medium" "running" 9000.0)
                                (harness-ui-slots-test--busy))
                 :limit 5
                 :queue (harness-ui-slots-test--busy-queue)))
          (let ((line (line-number-at-pos)))
            (should (harness-ui-slots--render))
            (should (equal "task:t-high" (get-text-property (point) 'harness-slot-key)))
            ;; The same place in the same row, a line further down.
            (should (= (1+ line) (line-number-at-pos)))
            (should (= 0 (count-lines (harness-ui-slots-test--first "task:t-high") (line-beginning-position))))
            (should (equal around (buffer-substring-no-properties (- (point) 4) (+ (point) 3))))))
        ;; The row goes: point stays on the line it was on.
        (let ((line (line-number-at-pos)))
          (setq harness-ui-slots--data (harness-ui-slots-test--data))
          (should (harness-ui-slots--render))
          (should (= line (line-number-at-pos))))))))

(ert-deftest harness-ui-slots-keeps-point-on-its-queue-row-and-line ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open
                   (harness-ui-slots-test--data :queue (harness-ui-slots-test--busy-queue)))))
      (with-current-buffer buffer
        ;; On a row of the next-in-line list: it follows its task when the queue changes.
        (goto-char (point-min))
        (search-forward "Fullscreen layout fix")
        (let ((line (line-number-at-pos)))
          (setq harness-ui-slots--data
                (harness-ui-slots-test--data
                 :queue (cons (harness-ui-slots-test--queued "t-q0" "Newer high" "high" 10.0)
                              (harness-ui-slots-test--busy-queue))))
          (should (harness-ui-slots--render))
          (should (string-match-p "Fullscreen layout fix" (buffer-substring (line-beginning-position)
                                                                            (line-end-position))))
          ;; The newcomer is a line above it now.
          (should (= (1+ line) (line-number-at-pos))))
        ;; On a line that belongs to no box, it is the same line.
        (goto-char (point-min))
        (search-forward "Next in line")
        (let ((line (line-number-at-pos)))
          (setq harness-ui-slots--data (harness-ui-slots-test--data :queue (harness-ui-slots-test--busy-queue)
                                                                    :days 3))
          (harness-ui-slots--render)
          (should (= line (line-number-at-pos))))))))

(ert-deftest harness-ui-slots-rows-have-keys-of-their-own ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open
                   (harness-ui-slots-test--data :limit 6 :holders (harness-ui-slots-test--busy)))))
      (with-current-buffer buffer
        ;; One key and one index to a row, each different from the others.
        (let (keys indexes)
          (dolist (start (harness-ui-slots--row-starts))
            (push (get-text-property (cdr start) 'harness-slot-key) keys)
            (push (car start) indexes))
          (should (equal '("task:t-high" "task:t-low" "task:t-mid") (sort keys #'string<)))
          (should (equal '(0 1 2) (sort indexes #'<))))
        ;; Point in a row stays in it when the rows before it change.
        (harness-ui-slots-test--goto "task:t-high" 0 9)
        (setq harness-ui-slots--data
              (harness-ui-slots-test--data
               :limit 6 :holders (cons (harness-ui-slots-test--holder "t-new" "Newcomer" "medium" "running" 9000.0)
                                       (cdr (harness-ui-slots-test--busy)))))
        (should (harness-ui-slots--render))
        (should (equal "task:t-high" (get-text-property (point) 'harness-slot-key)))
        (should (= 9 (- (point) (harness-ui-slots--run-start "task:t-high" (line-beginning-position)
                                                            (line-end-position)))))))))

(ert-deftest harness-ui-slots-keeps-the-windows-where-they-were ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open
                   (harness-ui-slots-test--data :limit 9 :holders (harness-ui-slots-test--busy)
                                                :queue (harness-ui-slots-test--busy-queue)))))
      (save-window-excursion
        (delete-other-windows)
        (set-window-buffer (selected-window) buffer)
        (with-current-buffer buffer
          (harness-ui-slots--render t)
          (goto-char (point-min))
          (search-forward "Compose box bundle")
          (set-window-point (selected-window) (point))
          (let ((line (line-number-at-pos (point))))
            (setq harness-ui-slots--data
                  (harness-ui-slots-test--data :limit 9 :holders (harness-ui-slots-test--busy)
                                               :queue (harness-ui-slots-test--busy-queue)
                                               :days 2))
            (harness-ui-slots--render)
            (should (= line (line-number-at-pos (window-point (selected-window)))))
            (should (string-match-p "Compose box bundle"
                                    (save-excursion (goto-char (window-point (selected-window)))
                                                    (buffer-substring (line-beginning-position)
                                                                      (line-end-position)))))))))))

;;;; Opening a session, moving between boxes

(ert-deftest harness-ui-slots-key-opens-the-session-of-the-row ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open
                   (harness-ui-slots-test--data
                    :holders (list (harness-ui-slots-test--holder "t-low" "Add secret redaction tools" "low"
                                                                  "blocked" 4680.0)
                                   (harness-ui-slots-test--holder "t-high" "Fix stuck model responses" "high"
                                                                  "running" 2460.0 :sent-back t))))))
      (with-current-buffer buffer
        (should (eq #'harness-ui-slots-open (lookup-key harness-ui-slots-mode-map (kbd "RET"))))
        ;; In any line of the row, the cells and the note under them, anywhere on them.
        (dolist (where '((0 3) (0 20) (0 60) (1 8)))
          (setq harness-ui-slots-test--opened nil)
          (harness-ui-slots-test--goto "task:t-high" (car where) (cadr where))
          (harness-ui-slots-open)
          (should (equal '(("s-t-high")) (mapcar (lambda (o) (list (car o))) harness-ui-slots-test--opened))))
        (setq harness-ui-slots-test--opened nil)
        (harness-ui-slots-test--goto "task:t-low" 0 3)
        (harness-ui-slots-open)
        (should (equal "s-t-low" (car (car harness-ui-slots-test--opened))))
        ;; It takes the page's position, as a card of the board does: none asked for.
        (should-not (cdr (car harness-ui-slots-test--opened)))
        (harness-ui-slots-open 'right)
        (should (eq 'right (cdr (car harness-ui-slots-test--opened))))
        ;; The session at point is the row's, for the commands that act on it.
        (should (equal "s-t-low" (harness-ui-session-at-point)))))))

(ert-deftest harness-ui-slots-key-off-the-rows-opens-nothing ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open
                   (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)))))
      (with-current-buffer buffer
        ;; On the line that counts the free slot, and on the first line.
        (goto-char (point-min))
        (search-forward "1 free")
        (should-error (harness-ui-slots-open) :type 'user-error)
        (goto-char (point-min))
        (should-error (harness-ui-slots-open) :type 'user-error)
        (should-not harness-ui-slots-test--opened)
        (should-not (harness-ui-slots--session-at-point))))))

(ert-deftest harness-ui-slots-row-of-a-starting-task-has-no-session-yet ()
  (harness-ui-slots-test-with
    (let* ((holder (harness-ui-slots-test--holder "t-s" "Just starting" "medium" "starting" 3.0 :session nil))
           (buffer (harness-ui-slots-test--open (harness-ui-slots-test--data :holders (list holder)))))
      (with-current-buffer buffer
        (harness-ui-slots-test--goto "task:t-s" 0 3)
        (should (equal "t-s" (get-text-property (point) 'harness-slot-task)))
        (should-not (get-text-property (point) 'harness-slot-session))
        (should-error (harness-ui-slots-open) :type 'user-error)
        (should-not harness-ui-slots-test--opened)
        ;; Its name says so on hover.
        (goto-char (text-property-any (point-min) (point-max) 'harness-slot-top 0))
        (should (string-match-p "its session has not started yet" (get-text-property (point) 'help-echo)))))))

(ert-deftest harness-ui-slots-click-opens-the-session-of-the-row ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open
                   (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)))))
      (save-window-excursion
        (delete-other-windows)
        (set-window-buffer (selected-window) buffer)
        (with-current-buffer buffer
          (should (eq #'harness-ui-slots-mouse-open (lookup-key harness-ui-slots-mode-map [mouse-1])))
          (let* ((pos (progn (harness-ui-slots-test--goto "task:t-mid" 0 6) (point)))
                 (event (list 'mouse-1 (list (selected-window) pos '(0 . 0) 0))))
            (goto-char (point-min))
            (harness-ui-slots-mouse-open event)
            (should (equal "s-t-mid" (car (car harness-ui-slots-test--opened))))
            (should (= pos (point))))
          ;; A click off the rows opens nothing.
          (setq harness-ui-slots-test--opened nil)
          (harness-ui-slots-mouse-open (list 'mouse-1 (list (selected-window) (point-min) '(0 . 0) 0)))
          (should-not harness-ui-slots-test--opened))))))

(ert-deftest harness-ui-slots-name-is-a-link-to-its-session ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open
                   (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)))))
      (with-current-buffer buffer
        ;; The name of a row is where it is highlighted and keyed.
        (goto-char (text-property-any (point-min) (point-max) 'harness-slot-top 2))
        (should (looking-at "Plan task board polish"))
        (should (eq 'highlight (get-text-property (point) 'mouse-face)))
        (let ((help (get-text-property (point) 'help-echo)))
          (should (string-match-p "Plan task board polish" help))
          (should (string-match-p "mouse-1, RET: open its session" help))
          (should-not (string-match-p "\n" help)))
        (should (equal "t-mid" (get-text-property (point) 'harness-slot-task)))
        (should (equal "s-t-mid" (get-text-property (point) 'harness-slot-session)))
        ;; The keys are on the name itself, not only on the page's map.
        (let ((map (get-text-property (point) 'keymap)))
          (should (eq map harness-ui-slots-row-map))
          (should (eq #'harness-ui-slots-open (lookup-key map (kbd "RET"))))
          (should (eq #'harness-ui-slots-mouse-open (lookup-key map [mouse-1]))))
        ;; The other cells are the session list's: they have their own tooltips.
        (search-forward "running")
        (should (equal "running" (get-text-property (1- (point)) 'help-echo)))
        (should-not (get-text-property (1- (point)) 'keymap))
        ;; The row's keys are still there, for a click anywhere on it.
        (should (equal "s-t-mid" (get-text-property (1- (point)) 'harness-slot-session)))))))

(ert-deftest harness-ui-slots-arrow-of-a-row-asks-for-its-sessions-priority ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open
                   (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)
                                                :queue (harness-ui-slots-test--busy-queue)))))
      (with-current-buffer buffer
        (goto-char (harness-ui-slots-test--first "task:t-high"))
        (let ((arrow (progn (search-forward (harness-ui-slots-test--arrow "high"))
                            (1- (point)))))
          ;; The arrow is the one of every view: a click on it asks for that session's priority.
          (should (equal "s-t-high" (get-text-property arrow harness-ui-priority-arrow-property)))
          (should (eq harness-ui-priority-arrow-map (get-text-property arrow 'keymap)))
          ;; It is still in the row: the row's task is on it.
          (should (equal "task:t-high" (get-text-property arrow 'harness-slot-key))))
        ;; A queued task's arrow asks for nothing: its session is not listed.
        (goto-char (point-min))
        (search-forward "Session list rework")
        (let ((arrow (save-excursion (search-backward (harness-ui-slots-test--arrow "high"))
                                     (point))))
          (should-not (get-text-property arrow harness-ui-priority-arrow-property))
          (should-not (get-text-property arrow 'keymap)))))))

(ert-deftest harness-ui-slots-moves-from-row-to-row ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open
                   (harness-ui-slots-test--data :limit 5 :holders (harness-ui-slots-test--busy)))))
      (with-current-buffer buffer
        (should (eq #'harness-ui-slots-next-row (lookup-key harness-ui-slots-mode-map (kbd "TAB"))))
        (should (eq #'harness-ui-slots-previous-row (lookup-key harness-ui-slots-mode-map (kbd "<backtab>"))))
        ;; Not n and p: on the lines of a task waiting on a permission request n denies it.
        (should-not (lookup-key harness-ui-slots-mode-map (kbd "n")))
        (should-not (lookup-key harness-ui-slots-mode-map (kbd "p")))
        (let ((index-at-point (lambda () (get-text-property (point) 'harness-slot-index)))
              (name-p (lambda () (get-text-property (point) 'harness-slot-top))))
          ;; From the top of the page, the first row, then each in turn, to the last and around.
          (goto-char (point-min))
          (harness-ui-slots-next-row)
          (should (equal '(0 0) (list (funcall index-at-point) (funcall name-p))))
          (should (looking-at "Add secret redaction tools"))
          (let (seen)
            (dotimes (_ 3) (harness-ui-slots-next-row) (push (funcall index-at-point) seen))
            (should (equal '(1 2 0) (nreverse seen))))
          ;; Backwards, and from inside a row, which goes by the row's number, not its place.
          (harness-ui-slots-previous-row)
          (should (= 2 (funcall index-at-point)))
          (harness-ui-slots-test--goto "task:t-high" 0 30)
          (harness-ui-slots-next-row)
          (should (equal '(2 2) (list (funcall index-at-point) (funcall name-p))))
          (harness-ui-slots-test--goto "task:t-high" 0 30)
          (harness-ui-slots-previous-row)
          (should (= 0 (funcall index-at-point))))))))

(ert-deftest harness-ui-slots-row-keys-need-rows ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open (harness-ui-slots-test--data :limit nil))))
      (with-current-buffer buffer
        (should-error (harness-ui-slots-next-row) :type 'user-error)
        (should-error (harness-ui-slots-previous-row) :type 'user-error)))))

(ert-deftest harness-ui-slots-keys ()
  (dolist (binding '(("g" . harness-ui-slots-refresh) ("q" . harness-ui-quit-view)
                     ("RET" . harness-ui-slots-open) ("TAB" . harness-ui-slots-next-row)
                     ("<backtab>" . harness-ui-slots-previous-row) ("l" . harness-ui-slots-set-limit)
                     ("SPC" . harness-ui-sessions-requests)
                     ("?" . harness-menu) ("C-c C-z" . harness-ui-bury)))
    (should (eq (cdr binding) (lookup-key harness-ui-slots-mode-map (kbd (car binding))))))
  ;; The menu lists them for the buffer.
  (let ((group (get 'harness-ui-slots-mode 'harness-menu-group)))
    (should (equal "Task slots" (car group)))
    (dolist (command '(harness-ui-slots-open harness-ui-slots-next-row
                       harness-ui-sessions-requests harness-ui-slots-set-limit harness-ui-slots-refresh))
      (should (cl-some (lambda (column)
                         (cl-some (lambda (item) (and (consp item) (eq command (nth 2 item)))) (append column nil)))
                       (cdr group))))))

;;;; Odd answers

(ert-deftest harness-ui-slots-tolerates-what-the-harness-leaves-out ()
  ;; Nothing is known of when a task began: no wait is made up for it.
  (let* ((data (harness-ui-slots-test--data
                :holders (list (list :id "t-x" :title "No times" :session "s-x" :priority "medium" :state "running"))
                :queue (list (list :id "t-y" :title "Queued without a time" :priority "high"))))
         (lines (harness-ui-slots-test--page data)))
    (should (harness-ui-slots-test--line-with lines "No times +running *\\'"))
    (should-not (harness-ui-slots-test--line-with lines "running +[0-9]"))
    (should (harness-ui-slots-test--line-with lines "Queued without a time +0s"))
    (should (equal '("high" "1" "0s" "0s")
                   (harness-ui-slots-test--cells
                    (harness-ui-slots-test--line-with lines "\\`   [^ ]* *high +1")))))
  ;; A limit that came as a float is a limit all the same; a null one is none.
  (should (string-match-p "0 of 3 in use · 3 free"
                          (car (harness-ui-slots-test--page (harness-ui-slots-test--data :limit 3.0)))))
  (should (string-match-p "no limit"
                          (car (harness-ui-slots-test--page (harness-ui-slots-test--data :limit :null)))))
  ;; An unknown priority is the default, a missing title is a name that is not given.
  (let ((lines (harness-ui-slots-test--page
                (harness-ui-slots-test--data
                 :holders (list (harness-ui-slots-test--holder "t-z" nil "urgent" "running" 60.0))))))
    (should (harness-ui-slots-test--line-with lines "unnamed +running +1m *\\'"))))

(ert-deftest harness-ui-slots-opens-the-same-page-for-the-same-project ()
  (harness-ui-slots-test-with
    (setq harness-ui-slots-test--answer (list 'data (harness-ui-slots-test--data :limit 6)))
    (harness-slots "/home/me/src/acme")
    (with-current-buffer harness-ui-slots--buffer-name
      ;; A directory with or without its slash is the same one: its answer stays while the next comes.
      (should (equal "/home/me/src/acme/" harness-ui-slots--dir))
      (setq harness-ui-slots-test--answer 'hold)
      (harness-slots "/home/me/src/acme/")
      (should (equal 6 (plist-get harness-ui-slots--data :limit)))
      (should-not (string-match-p "loading" (buffer-string)))
      (should (equal '("/home/me/src/acme/" "/home/me/src/acme/")
                     (mapcar #'car harness-ui-slots-test--requests)))
      (should (equal (list (current-buffer)) (harness-ui-slots--buffers))))))

;;;; The limit

(ert-deftest harness-ui-slots-offers-the-limit-button-once-it-knows-the-limit ()
  (harness-ui-slots-test-with
    (let* ((data (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy)))
           (text (harness-ui-slots--text data 100 harness-ui-slots-test--now nil))
           (first (car (harness-ui-slots-test--lines text))))
      (should (string-match-p "3 of 4 in use · 1 free · 0 waiting +\\[Set limit\\]" first))
      (let ((button (text-property-any 0 (length text) 'harness-ui-action #'harness-ui-slots-set-limit text)))
        (should button)
        (should (get-text-property button 'help-echo text))))
    ;; Until the harness says what the limit is, there is none to change.
    (setq harness-ui-slots-test--answer 'hold)
    (with-current-buffer (harness-slots "/home/me/src/acme/")
      (should (string-match-p "loading…" (buffer-string)))
      (should-not (string-match-p "Set limit" (buffer-string))))))

(ert-deftest harness-ui-slots-limit-button-sets-the-limit ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open (harness-ui-slots-test--data :limit 3)))
          (set nil))
      (cl-letf (((symbol-function 'harness-ui-tasks-set-max-running) (lambda (n) (push n set)))
                ((symbol-function 'harness-ui-tasks--read-max-running) (lambda (_current) 8)))
        (with-current-buffer buffer
          (harness-ui-slots--render t)
          (goto-char (point-min))
          (search-forward "[Set limit]")
          (backward-char 3)
          ;; RET on the button, as a click on it does.
          (should (eq #'harness-ui-action-push (lookup-key (get-text-property (point) 'keymap) (kbd "RET"))))
          (harness-ui-action-push)
          (should (equal '(8) set)))))))

(ert-deftest harness-ui-slots-sets-the-limit-through-the-board ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open (harness-ui-slots-test--data :limit 3)))
          (harness-ui-slots--refetch-delay 0.01)
          (read nil) (set nil))
      (cl-letf (((symbol-function 'harness-ui-tasks--read-max-running)
                 (lambda (current) (setq read current) 6))
                ((symbol-function 'harness-ui-tasks-set-max-running)
                 (lambda (n) (push n set))))
        (with-current-buffer buffer
          (let ((requests (length harness-ui-slots-test--requests)))
            (setq harness-ui-slots-test--answer (list 'data (harness-ui-slots-test--data :limit 6)))
            (harness-ui-slots-set-limit)
            ;; The reader got the limit now, from the page's answer; the board's command what it read.
            (should (equal 3 read))
            (should (equal '(6) set))
            ;; The page asks again shortly: the harness has the new limit by then.
            (harness-test-wait (lambda () (> (length harness-ui-slots-test--requests) requests))
                               3 "the page to ask again")
            (should (string-match-p "0 of 6 in use" (buffer-string))))))
      ;; No limit is a limit nil, the reader's answer for it.
      (let (read set)
        (cl-letf (((symbol-function 'harness-ui-tasks--read-max-running)
                   (lambda (current) (setq read current) nil))
                  ((symbol-function 'harness-ui-tasks-set-max-running)
                   (lambda (n) (push (list 'set n) set))))
          (with-current-buffer buffer
            (setq harness-ui-slots--data (harness-ui-slots-test--data :limit nil))
            (harness-ui-slots-set-limit)
            (should-not read)
            (should (equal '((set nil)) set))))))))

(ert-deftest harness-ui-slots-refetches-once-for-a-burst ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open (harness-ui-slots-test--data)))
          (before nil))
      (setq before (length harness-ui-slots-test--requests))
      (dotimes (_ 5) (harness-ui-slots--refetch-soon buffer 0.05))
      (should (= before (length harness-ui-slots-test--requests)))
      (harness-test-wait (lambda () (> (length harness-ui-slots-test--requests) before)) 3
                         "the page to ask again")
      (sleep-for 0.15)
      (should (= (1+ before) (length harness-ui-slots-test--requests)))
      ;; A page killed meanwhile asks for nothing.
      (harness-ui-slots--refetch-soon buffer 0.05)
      (kill-buffer buffer)
      (sleep-for 0.15)
      (should (= (1+ before) (length harness-ui-slots-test--requests))))))

(ert-deftest harness-ui-slots-redraws-every-page-after-a-reload ()
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open (harness-ui-slots-test--data)))
          (draws 0))
      (unwind-protect
          (progn
            ;; The module's init hangs it on the UI's redraw, which a reload runs.
            (harness-ui-slots--init)
            (should (memq #'harness-ui-slots--redraw-all (default-value 'harness-ui-redraw-hook)))
            (cl-letf* ((draw (symbol-function 'harness-ui-slots--draw))
                       ((symbol-function 'harness-ui-slots--draw)
                        (lambda (text) (cl-incf draws) (funcall draw text))))
              (run-hooks 'harness-ui-redraw-hook)
              (should (= 1 draws))
              ;; Events may have gone by meanwhile (a reconnect): hidden, the
              ;; page asks again when it shows.
              (should (buffer-local-value 'harness-ui-slots--stale buffer))))
        (harness-ui-slots--shutdown)))))

;;;; Keeping up

(defmacro harness-ui-slots-test-shown (buffer &rest body)
  "Run BODY in BUFFER, shown in the selected window; the windows come back after.
Batch Emacs runs no window change functions: a test that needs one runs
it by hand, as redisplay would."
  (declare (indent 1))
  `(save-window-excursion
     (delete-other-windows)
     (set-window-buffer (selected-window) ,buffer)
     (with-current-buffer ,buffer ,@body)))

(defun harness-ui-slots-test--asked-again (before)
  "Wait until the page made a request after the BEFORE it had made; settle.
Return how many it made since, once a little more time brought none."
  (harness-test-wait (lambda () (> (length harness-ui-slots-test--requests) before)) 3
                     "the page to ask again")
  (sleep-for 0.15)
  (- (length harness-ui-slots-test--requests) before))

(ert-deftest harness-ui-slots-live-a-burst-of-events-asks-once ()
  "The events that move tasks in and out of slots have a shown page ask again.
Once for a burst of them, a moment after the last; others ask nothing."
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open (harness-ui-slots-test--data)))
          (harness-ui-slots--refetch-delay 0.05))
      (harness-ui-slots-test-shown buffer
        (let ((before (length harness-ui-slots-test--requests)))
          ;; A turn's output rate, another key of a session: nothing to do with slots.
          (harness-ui-slots--on-event "usage/rate-updated" '("s-1" (:rate 3.0)))
          (harness-ui-slots--on-event "session/ext-changed" '("s-1" ":pet"))
          (sleep-for 0.15)
          (should (= before (length harness-ui-slots-test--requests)))
          ;; A task moves, its session starts, the queue and a priority change.
          (dolist (event '(("task/changed" (:id "t-1")) ("agent/turn-started" ("s-1"))
                           ("session/status" ("s-1" "running")) ("task/queue" nil)
                           ("session/ext-changed" ("s-2" ":priority")) ("task/deleted" ("t-2"))))
            (harness-ui-slots--on-event (car event) (cadr event)))
          ;; Not at once: when the burst settles.
          (should (= before (length harness-ui-slots-test--requests)))
          (should (= 1 (harness-ui-slots-test--asked-again before)))
          (should-not (buffer-local-value 'harness-ui-slots--stale buffer)))
        ;; Each event the board reloads after is one of them, and so is a
        ;; change of a session's priority (its task's), but no other key.
        (dolist (event harness-ui-tasks--refresh-events)
          (should (harness-ui-slots--event-p event nil)))
        (should (harness-ui-slots--event-p "session/ext-changed" '("s-2" ":priority")))
        (should (harness-ui-slots--event-p "session/ext-changed" '("s-2" "priority")))
        (should-not (harness-ui-slots--event-p "session/ext-changed" '("s-2" ":pet")))
        (should-not (harness-ui-slots--event-p "usage/rate-updated" '("s-2" (:rate 1.0))))))))

(ert-deftest harness-ui-slots-live-a-hidden-page-asks-when-it-shows ()
  "A page no window shows asks nothing for events; it notes them, and asks once shown."
  (harness-ui-slots-test-with
    (let ((buffer (harness-ui-slots-test--open (harness-ui-slots-test--data)))
          (harness-ui-slots--refetch-delay 0.05))
      (should-not (get-buffer-window buffer t))
      (let ((before (length harness-ui-slots-test--requests)))
        (dotimes (_ 3) (harness-ui-slots--on-event "task/changed" '((:id "t-1"))))
        (sleep-for 0.2)
        (should (= before (length harness-ui-slots-test--requests)))
        (should (buffer-local-value 'harness-ui-slots--stale buffer))
        ;; The page says it is suspended, as every such view does.
        (should (equal "[Suspended: resume]"
                       (substring-no-properties (with-current-buffer buffer (harness-ui-view-indicator)))))
        ;; The page watches for a window to show it.
        (should (memq #'harness-ui-slots--on-window-change
                      (buffer-local-value 'window-buffer-change-functions buffer)))
        (harness-ui-slots-test-shown buffer
          (harness-ui-slots--on-window-change (selected-window))
          (should (= 1 (harness-ui-slots-test--asked-again before)))
          (should-not (buffer-local-value 'harness-ui-slots--stale buffer))
          (should (equal "" (with-current-buffer buffer (harness-ui-view-indicator))))
          ;; Shown again with nothing missed, it asks nothing.
          (harness-ui-slots--on-window-change (selected-window))
          (sleep-for 0.2)
          (should (= (1+ before) (length harness-ui-slots-test--requests))))))))

(ert-deftest harness-ui-slots-live-times-run-on-the-boards-clock ()
  "The board's tick redraws a shown page whose times read otherwise, and nothing else.
It asks the harness for nothing: the times run from the answer it has."
  (harness-ui-slots-test-with
    (let* ((holder (harness-ui-slots-test--holder "t-a" "Waiter" "medium" "running" 150.0))
           (buffer (harness-ui-slots-test--open (harness-ui-slots-test--data :holders (list holder))))
           (real-float-time (symbol-function 'float-time))
           (later 0.0)
           (draws 0)
           (ticks 0))
      ;; The board's clock runs the hook after its own boards.
      (let ((harness-ui-tasks-tick-hook (list (lambda () (cl-incf ticks)))))
        (harness-ui-tasks--tick)
        (should (= 1 ticks)))
      (cl-letf* ((draw (symbol-function 'harness-ui-slots--draw))
                 ((symbol-function 'harness-ui-slots--draw)
                  (lambda (text) (cl-incf draws) (funcall draw text)))
                 ((symbol-function 'float-time)
                  (lambda (&optional time)
                    (if time (funcall real-float-time time) (+ (funcall real-float-time) later)))))
        (harness-ui-slots-test-shown buffer
          ;; Shown, it is drawn for its window's width, as
          ;; `harness-ui-slots--on-resize' has it as it shows.
          (harness-ui-slots--render)
          (setq draws 0)
          (should (string-match-p "Waiter +running +2m" (harness-ui-slots-test--visual (buffer-string))))
          ;; A tick that changes no time on it draws nothing.
          (harness-ui-slots--on-tick)
          (should (= 0 draws))
          ;; Minutes later the row reads otherwise: drawn once.
          (setq later 400.0)
          (harness-ui-slots--on-tick)
          (harness-ui-slots--on-tick)
          (should (= 1 draws))
          (should (string-match-p "Waiter +running +9m" (harness-ui-slots-test--visual (buffer-string))))
          (should (= 1 (length harness-ui-slots-test--requests))))
        ;; Hidden, the clock draws nothing, however late it is.
        (setq later 4000.0)
        (harness-ui-slots--on-tick)
        (should (= 1 draws))))))

(ert-deftest harness-ui-slots-live-a-request-a-task-waits-on-draws-the-page-again ()
  "A request that comes or is answered changes the line under its task's row at once.
A shown page draws again soon, once for a burst, asking the harness for
nothing; a hidden one is left alone, drawn when it shows."
  (harness-ui-slots-test-with
    (let* ((buffer (harness-ui-slots-test--open
                    (harness-ui-slots-test--data :holders (harness-ui-slots-test--busy))))
           (harness-ui-slots--pending-delay 0.02)
           ;; The module's init is what hooks the page to the requests.
           (harness-ui-pending-changed-hook (list #'harness-ui-slots--on-pending))
           (draws 0)
           (waits (lambda ()
                    (with-current-buffer buffer
                      (string-match-p "\\[Allow\\]" (harness-ui-slots-test--visual (buffer-string)))))))
      (cl-letf* ((draw (symbol-function 'harness-ui-slots--draw))
                 ((symbol-function 'harness-ui-slots--draw)
                  (lambda (text) (cl-incf draws) (funcall draw text))))
        (harness-ui-slots-test-shown buffer
          (harness-ui-slots--render)
          (setq draws 0)
          (should-not (funcall waits))
          ;; The task that is blocked is asked a permission: its request is in the UI.
          (harness-ui-slots-test--cache "s-t-low" :status "blocked"
                                        :pending (list (list :id "p-1" :kind "permission"
                                                             :payload (list :title "Bash: ls" :tool "bash"
                                                                            :options '("allow-once" "deny-once")))))
          (dotimes (_ 3) (run-hook-with-args 'harness-ui-pending-changed-hook "s-t-low"))
          (harness-test-wait waits 3 "the request to show under its task")
          (should (= 1 draws))
          (should (= 1 (length harness-ui-slots-test--requests))))
        ;; A page nothing shows is not drawn for it.
        (setq draws 0)
        (run-hook-with-args 'harness-ui-pending-changed-hook "s-t-low")
        (sleep-for 0.1)
        (should (= 0 draws))))))

(ert-deftest harness-ui-slots-live-module-follows-the-events-and-the-clock ()
  (unwind-protect
      (progn
        (harness-ui-slots--init)
        (should (memq #'harness-ui-slots--on-event harness-ui-event-functions))
        (should (memq #'harness-ui-slots--on-pending harness-ui-pending-changed-hook))
        (should (memq #'harness-ui-slots--on-tick harness-ui-tasks-tick-hook))
        (should (memq #'harness-ui-slots--redraw-all (default-value 'harness-ui-redraw-hook)))
        ;; C-c h Q, the queue, as Q in the harness menu.
        (should (eq #'harness-slots (lookup-key harness-ui-map (kbd "Q"))))
        ;; Started twice, as a reload may, it follows them once.
        (harness-ui-slots--init)
        (should (= 1 (cl-count #'harness-ui-slots--on-event harness-ui-event-functions)))
        (harness-ui-slots--shutdown)
        (should-not (memq #'harness-ui-slots--on-event harness-ui-event-functions))
        (should-not (memq #'harness-ui-slots--on-pending harness-ui-pending-changed-hook))
        (should-not (memq #'harness-ui-slots--on-tick harness-ui-tasks-tick-hook))
        (should-not (memq #'harness-ui-slots--redraw-all (default-value 'harness-ui-redraw-hook)))
        (should-not (lookup-key harness-ui-map (kbd "Q"))))
    (harness-ui-slots--shutdown)))

(ert-deftest harness-ui-slots-live-board-key-and-menu-open-the-page ()
  "S on a task board opens the page for the board's project; so does the menu's Q.
A board without the page's module says what is missing."
  (should (eq #'harness-ui-tasks-slots (lookup-key harness-ui-tasks-board-map (kbd "S"))))
  (harness-ui-slots-test-with
    (setq harness-ui-slots-test--answer (list 'data (harness-ui-slots-test--data)))
    (with-temp-buffer
      (setq-local harness-ui-tasks--dir "/home/me/src/board/")
      (use-local-map harness-ui-tasks-board-map)
      (call-interactively (key-binding (kbd "S"))))
    (should (equal '("/home/me/src/board/") (mapcar #'car harness-ui-slots-test--requests))))
  (cl-letf (((symbol-function 'harness-slots) nil))
    (should (string-match-p "(ui-slots) is not loaded"
                            (cadr (should-error (harness-ui-tasks-slots) :type 'user-error)))))
  ;; The board lists the key with its own in the harness menu.
  (should (cl-some (lambda (column)
                     (cl-some (lambda (item) (and (consp item) (equal ". S" (car item))
                                                  (eq 'harness-ui-tasks-slots (nth 2 item))))
                              (append column nil)))
                   (cdr (get 'harness-ui-tasks-mode 'harness-menu-group))))
  ;; The harness menu's Tools, behind Q as in `harness-ui-map', which no
  ;; other command of the menu takes.
  (let* ((plist (lambda (suffix) (if (keywordp (cadr suffix)) (cdr suffix) (car (last suffix)))))
         (column (transient-get-suffix 'harness-menu '(0 3)))
         (entry (cl-find "Q" (aref column (1- (length column)))
                         :key (lambda (suffix) (plist-get (funcall plist suffix) :key)) :test #'equal))
         (keys (cl-loop for n from 0 below 4
                        append (let ((column (transient-get-suffix 'harness-menu (list 0 n))))
                                 (mapcar (lambda (suffix) (plist-get (funcall plist suffix) :key))
                                         (aref column (1- (length column))))))))
    (should (equal "Tools" (plist-get (aref column (- (length column) 2)) :description)))
    (should entry)
    (should (eq 'harness-slots (plist-get (funcall plist entry) :command)))
    (should (equal "Task slots" (plist-get (funcall plist entry) :description)))
    (should (= 1 (cl-count "Q" keys :test #'equal)))))

;;;; With the harness

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-naming-auto)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-tasks--table)
(defvar harness-tasks--starting)
(defvar harness-tasks--loaded)
(defvar harness-tasks-max-running)
(defvar harness-tasks-require-verification)
(defvar harness-tasks-model)
(defvar harness-tasks-worktrees)
(defvar harness-ui-default-position)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-anthropic-admin-api-key)
(defvar auth-sources)
(defvar harness-ui--sessions)
(defvar harness-ui-tasks--loading)
(declare-function harness-acp--drop-client "harness-acp")

(defmacro harness-ui-slots-test-with-harness (&rest body)
  "Run BODY against the harness: the tasks, the in-process ACP connection, a board.
It is set up as `harness-ui-tasks-test-with' sets the board's tests up
\(test/harness-ui-tasks-test.el), with this page's module too, two slots
a project, and turns that hold until stopped: a task that starts keeps
its slot.  BODY runs with `board', the board of `dir', open.  The
module registry is the test's own, so the other tests of this file find
the page's module as they loaded it."
  (declare (indent 0))
  `(let ((harness--modules (make-hash-table :test 'eq)))
     (harness-test-with-temp-state
       (harness-test-reset-bus)
       (let ((harness-acp--server-enabled nil))
         (dolist (m '(store project config provider provider-demo tools session agent priority tasks acp))
           (harness-test-load-module m)))
       (clrhash harness-sessions)
       (clrhash harness-tools)
       (clrhash harness-agent--turns)
       (clrhash harness-tasks--table)
       (clrhash harness-tasks--starting)
       (setq harness-tasks--loaded t harness-acp--clients nil)
       (let ((harness-provider-demo--delay 0.005)
             ;; No end: a turn holds its slot until it is stopped.
             (harness-provider-demo-script-override '((:type text :delta "Working on it.")))
             (harness-naming-auto nil)
             (harness-tasks-max-running 2)
             (harness-tasks-require-verification nil)
             (harness-tasks-model "demo:scripted")
             (harness-tasks-worktrees nil)
             (harness-ui-default-position 'full)
             (harness-acp-token nil)
             (harness-anthropic-admin-api-key nil)
             (auth-sources nil)
             (process-environment (cons "ANTHROPIC_ADMIN_KEY" process-environment))
             (harness-ui-slots--refetch-delay 0.05)
             (default-directory dir))
         (harness-add-filter 'permission/decide
                             (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
         (dolist (m '(ui ui-tasks ui-slots)) (harness-test-load-module m))
         (clrhash harness-ui--sessions)
         (let ((board (harness-tasks dir)))
           (unwind-protect
               (progn
                 (harness-test-wait (lambda () (not (buffer-local-value 'harness-ui-tasks--loading board)))
                                    5 "the board to load")
                 ,@body)
             (dolist (task (ignore-errors (harness-call 'task/list dir)))
               (ignore-errors (harness-call 'task/cancel (plist-get task :id))))
             (when-let* ((page (get-buffer harness-ui-slots--buffer-name)))
               (kill-buffer page))
             (kill-buffer board)
             (dolist (c (copy-sequence harness-acp--clients))
               (harness-acp--drop-client c))))))))

(ert-deftest harness-ui-slots-live-with-the-harness ()
  "Against the tasks module, through the in-process ACP connection.
Two slots, and three tasks whose turns hold: the first two take the
slots and the third, high priority, waits.  S on the board opens the
page for its project, with both slots in use and the third task next in
line.  Once a task at work is done the third takes its slot, and the
page shows it unasked, its wait counted with the high ones.  [Set
limit] there sets the board's limit, which the page shows too."
  (harness-ui-slots-test-with-harness
    (let* ((first (plist-get (harness-call 'task/submit dir "Held task one") :id))
           (second (plist-get (harness-call 'task/submit dir "Held task two") :id))
           (third (plist-get (harness-call 'task/submit dir "Urgent task three" '(:priority "high")) :id))
           (page nil)
           (high (regexp-quote (harness-ui-slots-test--arrow "high")))
           (text (lambda () (with-current-buffer page (harness-ui-slots-test--visual (buffer-string)))))
           (shows (lambda (regexp)
                    (harness-test-wait (lambda () (string-match-p regexp (funcall text)))
                                       5 (format "the page to show %s, it shows\n%s"
                                                 regexp (funcall text)))))
           (saved nil))
      (should (cl-every #'stringp (list first second third)))
      (harness-test-wait (lambda () (= 2 (length (plist-get (harness-call 'task/slots dir) :holders))))
                         5 "two tasks at work")
      ;; S, on the board, opens the page for the board's project.
      (with-current-buffer board
        (goto-char (point-min))
        (should (eq #'harness-ui-tasks-slots (key-binding (kbd "S"))))
        (setq page (call-interactively (key-binding (kbd "S")))))
      (should (eq page (get-buffer harness-ui-slots--buffer-name)))
      (should (get-buffer-window page t))
      (should (equal (file-name-as-directory dir) (buffer-local-value 'harness-ui-slots--dir page)))
      (funcall shows "2 of 2 in use · 0 free · 1 waiting")
      (let* ((lines (split-string (funcall text) "\n"))
             (section (harness-ui-slots-test--section lines)))
        ;; Two rows, both at work and running, at the default priority; none free.
        (should (= 3 (length section)))
        (should (harness-ui-slots-test--line-with section "Held task one +running"))
        (should (harness-ui-slots-test--line-with section "Held task two +running"))
        (should-not (harness-ui-slots-test--line-with lines "\\`   [0-9]+ free\\'"))
        (should-not (cl-some (lambda (line) (string-match-p high line)) section))
        ;; The third waits, high: first in line.
        (should (harness-ui-slots-test--line-with lines "Queue · 1 waiting"))
        (should (equal '("high" "1") (seq-take (harness-ui-slots-test--cells
                                                 (harness-ui-slots-test--line-with
                                                  lines (concat "\\`   " high " high +1 ")))
                                                2)))
        (should (harness-ui-slots-test--line-with lines (concat "1\\. +" high " +Urgent task three"))))
      ;; The first is done: the third takes its slot, and the page follows
      ;; by itself, from the events, with the wait it had.
      (harness-call 'task/complete first)
      (funcall shows "2 of 2 in use · 0 free · 0 waiting")
      (funcall shows (concat "Urgent task three +[a-z]+ .*" high))
      (funcall shows "nobody waits for a slot")
      (let* ((lines (split-string (funcall text) "\n"))
             (waited (cdr (member (harness-ui-slots-test--line-with lines "Waited for a slot") lines))))
        (should-not (harness-ui-slots-test--line-with lines "Held task one"))
        (should (harness-ui-slots-test--line-with (harness-ui-slots-test--section lines) "Urgent task three"))
        (should (equal '("high" "1") (seq-take (harness-ui-slots-test--cells
                                                 (harness-ui-slots-test--line-with
                                                  waited (concat "\\`   " high " high ")))
                                                2)))
        ;; The first two waited too, for no time: they were queued as they
        ;; were submitted, and started at once.
        (should (equal '("medium" "2" "0s" "0s")
                       (harness-ui-slots-test--cells
                        (harness-ui-slots-test--line-with waited "\\`     medium ")))))
      ;; [Set limit] is the board's: saved as the option, and the page shows it.
      (cl-letf (((symbol-function 'harness-save-user-option)
                 (lambda (symbol value) (set symbol value) (push (cons symbol value) saved)))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) "3")))
        (with-current-buffer page
          (goto-char (point-min))
          (search-forward "[Set limit]")
          (backward-char 3)
          (harness-ui-action-push)))
      (harness-test-wait (lambda () (equal '((harness-tasks-max-running . 3)) saved)) 5 "the limit to be saved")
      (funcall shows "2 of 3 in use · 1 free · 0 waiting")
      (should (harness-ui-slots-test--line-with (split-string (funcall text) "\n") "\\`   1 free\\'")))))

(provide 'harness-ui-slots-test)
;;; harness-ui-slots-test.el ends here
