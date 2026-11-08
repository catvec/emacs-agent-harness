;;; harness-ui-report-review-test.el --- The design and demo in a report  -*- lexical-binding: t; -*-

;;; Commentary:

;; The report draws the design document first, a section at a time, and
;; each section is a quote target: C-c > on it starts a thread on the
;; document and its lines.  A demo is drawn as the actions it offers,
;; and the walkthrough starts a presenter conversation from the report.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-ui)

(defconst harness-ui-report-review-test--design
  "# The parser design

It reads nested quotes.

## The error

It names the line the quote opened on.
")

(defconst harness-ui-report-review-test--walkthrough
  "You are presenting the finished work of the task to its reviewer."
  "The brief the report keeps for a presenter conversation.")

(defun harness-ui-report-review-test--report ()
  "Return a report with a design, a demo and a walkthrough."
  (list :problem "Nested quotes break the parser"
        :summary "# Done"
        :design (list :title "The parser design"
                      :name "docs/design/parser.md"
                      :path "/work/docs/design/parser.md"
                      :summary "What the parser decides."
                      :text harness-ui-report-review-test--design)
        :walkthrough harness-ui-report-review-test--walkthrough
        :evidence (list (list :kind "demo"
                              :title "Nested quotes"
                              :name "demo/index.html"
                              :path "/work/demo/index.html"
                              :url "http://localhost:8000"
                              :command '("python3" "-m" "http.server" "8000")
                              :cwd "/work/demo"
                              :cwd-name "demo"
                              :narration "Type a quote and watch the error."
                              :caption "The demo"))))

(defun harness-ui-report-review-test--task (&optional report)
  "Return a task whose report is REPORT, or the fixture's."
  (list :id "t1" :session "s1" :prompt "Fix the parser"
        :report (or report (harness-ui-report-review-test--report))))

(defmacro harness-ui-report-review-test-with (&rest body)
  "Run BODY with the UI modules loaded and a report drawn in a buffer."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tasks acp))
       (harness-test-load-module m))
     (dolist (m '(ui ui-compose ui-markdown ui-popout ui-tasks ui-report))
       (harness-test-load-module m))
     (clrhash harness-ui--sessions)
     (let ((default-directory dir))
       ,@body)))

(ert-deftest harness-ui-report-review-draws-the-design-first ()
  "The design is the first thing the report shows, with its title and path."
  (harness-ui-report-review-test-with
    (with-temp-buffer
      (let ((harness-ui-report--full t))
        (harness-ui-report--insert-report
         (harness-ui-report-review-test--report)
         (harness-ui-report-review-test--task)))
      (should (string-match-p "Design: The parser design" (buffer-string)))
      (should (string-match-p "docs/design/parser.md" (buffer-string)))
      (should (string-match-p "\\[Open design\\]" (buffer-string)))
      (should (string-match-p "What the parser decides" (buffer-string)))
      (should (string-match-p "It reads nested quotes" (buffer-string)))
      ;; The problem follows the design, not the other way round.
      (should (< (string-match-p "It reads nested quotes" (buffer-string))
                 (string-match-p "Nested quotes break the parser" (buffer-string)))))))

(ert-deftest harness-ui-report-review-design-sections-are-quote-targets ()
  "C-c > on a design section quotes the document and the lines it is on."
  (harness-ui-report-review-test-with
    (with-temp-buffer
      (let ((harness-ui-report--full t))
        (harness-ui-report--insert-report
         (harness-ui-report-review-test--report)
         (harness-ui-report-review-test--task)))
      (goto-char (point-min))
      (search-forward "It reads nested quotes")
      (let* ((pos (1- (point)))
             (function (get-text-property pos 'harness-quote-target)))
        (should (functionp function))
        (let* ((beg (line-beginning-position))
               (end (line-end-position))
               (refs (funcall function beg end))
               (ref (car refs)))
          (should (equal "buffer" (plist-get ref :kind)))
          (should (equal "docs/design/parser.md" (plist-get ref :file)))
          (should (= 1 (plist-get ref :line)))
          (should (= 4 (plist-get ref :end)))
          (should (string-match-p "nested quotes" (plist-get ref :text)))))
      ;; The second section is a quote target of its own, at its lines.
      (goto-char (point-min))
      (search-forward "It names the line")
      (let* ((function (get-text-property (1- (point)) 'harness-quote-target))
             (refs (and function (funcall function (line-beginning-position)
                                          (line-end-position)))))
        (should refs)
        (should (= 5 (plist-get (car refs) :line))))
      ;; The summary the hand-in wrote above the document can be quoted too,
      ;; as a message of the report.
      (goto-char (point-min))
      (search-forward "What the parser decides")
      (let* ((function (get-text-property (1- (point)) 'harness-quote-target))
             (refs (and function (funcall function (line-beginning-position)
                                          (line-end-position)))))
        (should refs)
        (should (equal "report" (plist-get (car refs) :kind)))
        (should (string-match-p "What the parser decides" (plist-get (car refs) :text)))))))

(ert-deftest harness-ui-report-review-draws-a-demo-and-its-actions ()
  "A demo is a line with Open, Run or Stop, Walkthrough and its narration."
  (harness-ui-report-review-test-with
    (with-temp-buffer
      (let ((harness-ui-report--full t))
        (harness-ui-report--insert-report
         (harness-ui-report-review-test--report)
         (harness-ui-report-review-test--task)))
      (should (string-match-p "demo Nested quotes" (buffer-string)))
      (should (string-match-p "\\[Open demo\\]" (buffer-string)))
      (should (string-match-p "\\[Run demo\\]" (buffer-string)))
      (should (string-match-p "\\[Walkthrough\\]" (buffer-string)))
      (should (string-match-p "python3 -m http.server 8000" (buffer-string)))
      (should (string-match-p "Narration" (buffer-string)))
      (should (string-match-p "Type a quote and watch the error" (buffer-string)))
      (should (string-match-p "The demo" (buffer-string)))))
  ;; Without a brief there is nothing to walk through, and no button for it.
  (harness-ui-report-review-test-with
    (with-temp-buffer
      (let* ((report (plist-put (harness-ui-report-review-test--report) :walkthrough nil))
             (harness-ui-report--full t))
        (harness-ui-report--insert-report
         report (harness-ui-report-review-test--task report)))
      (should-not (string-match-p "\\[Walkthrough\\]" (buffer-string))))))

(defun harness-ui-report-review-test--lines ()
  "Return the lines of this buffer without their text properties."
  (mapcar #'substring-no-properties (split-string (buffer-string) "\n")))

(defun harness-ui-report-review-test--help (label)
  "Return the tooltip on LABEL in this buffer."
  (goto-char (point-min))
  (search-forward label)
  (get-text-property (1- (point)) 'help-echo))

(ert-deftest harness-ui-report-review-draws-the-exact-copy ()
  "The design, the demo and the walkthrough say exactly what they should.
The labels are nouns and noun phrases; the tooltips name what a control
shows, not a sentence about it."
  (harness-ui-report-review-test-with
    (with-temp-buffer
      (let ((harness-ui-report--full t))
        (harness-ui-report--insert-report
         (harness-ui-report-review-test--report)
         (harness-ui-report-review-test--task)))
      (let ((lines (harness-ui-report-review-test--lines)))
        (should (member "▾ Design: The parser design" lines))
        (should (member "  docs/design/parser.md  [Open design]" lines))
        (should (member "What the parser decides." lines))
        (should (member "▾ Evidence (1)  [Collapse all] [Expand all]" lines))
        (should (member "▾   1. demo Nested quotes" lines))
        (should (member "  [Open demo] [Run demo] [Walkthrough]" lines))
        (should (member "  python3 -m http.server 8000" lines))
        (should (member "  Narration" lines))
        (should (member "Type a quote and watch the error." lines))
        (should (member "  The demo" lines)))
      (should (equal "The design document, in a window of its own"
                     (harness-ui-report-review-test--help "[Open design]")))
      (should (equal "The demo, in its window"
                     (harness-ui-report-review-test--help "[Open demo]")))
      (should (equal "The demo command, on this machine"
                     (harness-ui-report-review-test--help "[Run demo]")))
      (should (equal "A review conversation about the design and the demos"
                     (harness-ui-report-review-test--help "[Walkthrough]")))
      (goto-char (point-min))
      (search-forward "It reads nested quotes")
      (should (equal "C-c >: a thread on this section of the design"
                     (get-text-property (1- (point)) 'help-echo))))
    ;; A running demo swaps its action and says so, and nothing else moves.
    (with-temp-buffer
      (cl-letf (((symbol-function 'harness-ui-report--demo-running-p)
                 (lambda (&rest _) t)))
        (let ((harness-ui-report--full t))
          (harness-ui-report--insert-report
           (harness-ui-report-review-test--report)
           (harness-ui-report-review-test--task))))
      (let ((lines (harness-ui-report-review-test--lines)))
        (should (member "  [Open demo] [Stop demo] [Walkthrough]" lines))
        (should (member "  Demo running" lines)))
      (should (equal "The demo, where it runs"
                     (harness-ui-report-review-test--help "[Stop demo]"))))
    ;; Folded, the design keeps its title, its name and its way in.
    (with-temp-buffer
      (cl-letf (((symbol-function 'harness-ui-report--folded-p)
                 (lambda (_task key _default) (equal key "design"))))
        (let ((harness-ui-report--full t))
          (harness-ui-report--insert-report
           (harness-ui-report-review-test--report)
           (harness-ui-report-review-test--task))))
      (let ((lines (harness-ui-report-review-test--lines)))
        (should (member "▸ Design: The parser design" lines))
        (should (member "  docs/design/parser.md  [Open design]" lines))
        (should-not (member "It reads nested quotes." lines))))
    ;; Drawn from a task record without the report, as the transcript does,
    ;; the demo still offers its walkthrough: the report drawn has one.
    (with-temp-buffer
      (let ((harness-ui-report--full t))
        (harness-ui-report--insert-report
         (harness-ui-report-review-test--report)
         (list :id "t1" :session "s1")))
      (should (member "  [Open demo] [Run demo] [Walkthrough]"
                      (harness-ui-report-review-test--lines))))
    ;; A document longer than the report draws says where the rest is.
    (with-temp-buffer
      (let ((harness-ui-report--full t)
            (harness-ui-report-design-max-chars 10))
        (harness-ui-report--insert-report
         (harness-ui-report-review-test--report)
         (harness-ui-report-review-test--task)))
      (should (member "  More in docs/design/parser.md"
                      (harness-ui-report-review-test--lines))))))

(ert-deftest harness-ui-report-review-starts-a-demo-as-a-run ()
  "Start demo asks the harness to run this demo, and the row says what it got.
The run is the harness's (`demo/start'), bound to the report's session and
the demo's id, and stopping it names that run, not a process of ours."
  (harness-ui-report-review-test-with
    (let* ((demo-calls nil)
           (task (harness-ui-report-review-test--task))
           (item (plist-put (plist-put (copy-sequence
                                        (car (plist-get (harness-ui-report-review-test--report)
                                                        :evidence)))
                                       :id "demo-1")
                            :workspace "w-1"))
           (answer (list :state "running" :run "run-1" :demo "demo-1"
                         :task "t1" :title "Nested quotes"
                         :placement "workspace" :workspace "w-1"
                         :workspace-name "Kitchen" :commit "abc1234"
                         :control "agent"
                         :presenter (list :session "btw-1" :name "demo: Nested quotes")
                         :vnc (list :url "http://127.0.0.1:6080/vnc.html"
                                    :socket "ws://127.0.0.1:6080/websockify"
                                    :state "agent" :available t))))
      (harness-register-method 'demo/start (lambda (&rest _) nil))
      (harness-register-method 'demo/status (lambda (&rest _) nil))
      (harness-register-method 'demo/stop (lambda (&rest _) nil))
      (cl-letf (((symbol-function 'harness-ui-report--refresh) #'ignore)
                ((symbol-function 'harness-ui-display-session) #'ignore)
                ((symbol-function 'harness-call)
                 (lambda (name &rest args)
                   (pcase name
                     ('demo/start (push (cons name args) demo-calls) answer)
                     ('demo/status answer)
                     ('demo/stop (push (cons name args) demo-calls)
                                 (plist-put (copy-sequence answer) :state "stopped"))
                     (_ (apply (symbol-function 'harness-call) name args))))))
        (let ((harness-ui-report--full t))
          (harness-ui-report--start-demo task 1 item))
        (should (equal '(demo/start "s1" "demo-1") (car demo-calls)))
        (with-temp-buffer
          (let ((harness-ui-report--full t))
            (harness-ui-report--insert-report
             (plist-put (harness-ui-report-review-test--report) :evidence (list item))
             task))
          (let ((lines (harness-ui-report-review-test--lines)))
            (should (member "  [Open demo] [Stop demo] [Open VNC] [Walkthrough]" lines))
            (should (member "  In workspace w-1" lines))
            (should (member "  Demo running" lines))
            (should (member "  Commit abc1234" lines))))
        (let ((harness-ui-report--full t))
          (with-temp-buffer
            (harness-ui-report--insert-report
             (plist-put (harness-ui-report-review-test--report) :evidence (list item))
             task)
            (harness-ui-report--stop-demo-run task 1)))
        (should (equal '(demo/stop "run-1") (car demo-calls)))
        (with-temp-buffer
          (let ((harness-ui-report--full t))
            (harness-ui-report--insert-report
             (harness-ui-report-review-test--report) task))
          (should (member "  [Open demo] [Run demo] [Walkthrough]"
                          (harness-ui-report-review-test--lines)))))))
  ;; A start that did not run says why in the row, and offers Start again.
  (harness-ui-report-review-test-with
    (let* ((task (harness-ui-report-review-test--task))
           (item (plist-put (plist-put (copy-sequence
                                        (car (plist-get (harness-ui-report-review-test--report)
                                                        :evidence)))
                                       :id "demo-1")
                            :workspace "w-1"))
           (answer (list :state "not-ready" :run nil
                         :reason (list :code "box-methods-missing"
                                       :text "workspace box methods missing"))))
      (harness-register-method 'demo/start (lambda (&rest _) nil))
      (cl-letf (((symbol-function 'harness-ui-report--refresh) #'ignore)
                ((symbol-function 'harness-call) (lambda (&rest _) answer)))
        (harness-ui-report--start-demo task 1 item))
      (with-temp-buffer
        (let ((harness-ui-report--full t))
          (harness-ui-report--insert-report
           (plist-put (harness-ui-report-review-test--report) :evidence (list item))
           task))
        (let ((lines (harness-ui-report-review-test--lines)))
          (should (member "  workspace box methods missing" lines))
          (should (member "  In workspace w-1" lines)))))))

(ert-deftest harness-ui-report-review-runs-and-stops-a-demo ()
  "Run starts the demo's argv in its cwd, tracked; Stop ends it.
The command is a list, never a shell string, and the confirmation comes
before anything starts."
  (harness-ui-report-review-test-with
    (let* ((task (harness-ui-report-review-test--task))
           (item (list :kind "demo" :title "A sleep"
                       :command '("sleep" "30") :cwd dir)))
      (unwind-protect
          (progn
            ;; Declined, nothing runs.
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
              (harness-ui-report--run-demo task 1 item))
            (should-not (harness-ui-report--demo-running-p task 1))
            (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                      ((symbol-function 'harness-ui-report--refresh) #'ignore))
              (harness-ui-report--run-demo task 1 item))
            (should (harness-ui-report--demo-running-p task 1))
            (should (equal "$ sleep 30\n\n"
                           (with-current-buffer "*harness demo: A sleep*"
                             (buffer-string))))
            (cl-letf (((symbol-function 'harness-ui-report--refresh) #'ignore))
              (harness-ui-report--stop-demo task 1))
            (should-not (harness-ui-report--demo-running-p task 1))
            (should-not (harness-ui-report--demo-process task 1)))
        (let ((process (harness-ui-report--demo-process task 1)))
          (when (process-live-p process) (delete-process process)))))))

(ert-deftest harness-ui-report-review-says-what-it-cannot-show ()
  "A design or a demo that cannot be shown says why, in a noun phrase."
  (harness-ui-report-review-test-with
    (let ((design (plist-get (harness-ui-report-review-test--report) :design)))
      (should (equal "No design file here"
                     (error-message-string
                      (should-error (harness-ui-report--open-design
                                     (plist-put (copy-sequence design)
                                                :path "/work/docs/missing.md"))
                                    :type 'user-error)))))
    (should (equal "No demo to open"
                   (error-message-string
                    (should-error (harness-ui-report--open-demo nil)
                                  :type 'user-error))))
    (should (equal "No demo command"
                   (error-message-string
                    (should-error (harness-ui-report--run-demo
                                   (harness-ui-report-review-test--task)
                                   1 (list :kind "demo"))
                                  :type 'user-error))))
    (should (equal "No walkthrough here"
                   (error-message-string
                    (should-error (harness-ui-report--walkthrough
                                   (harness-ui-report-review-test--task
                                    (plist-put (harness-ui-report-review-test--report)
                                               :walkthrough nil)))
                                  :type 'user-error))))))

(ert-deftest harness-ui-report-review-walkthrough-asks-the-btw-to-present ()
  "A walkthrough makes a BTW on the task's session, then sends the brief."
  (harness-ui-report-review-test-with
    (let* ((task (harness-ui-report-review-test--task))
           (harness-ui-open-session-function (lambda (_id) (current-buffer)))
           (shown nil)
           (sent nil)
           (request nil))
      (cl-letf (((symbol-function 'harness-ui-session)
                 (lambda (_id) (list :id "s1" :model "demo:scripted")))
                ((symbol-function 'harness-ui-request)
                 (lambda (method params &rest _)
                   (setq request (cons method params))
                   (harness-resolved (list :id "btw1"))))
                ((symbol-function 'harness-ui-btw--show)
                 (lambda (id _over _about _question after)
                   (setq shown id)
                   (funcall after (current-buffer))))
                ((symbol-function 'harness-ui-call-turn)
                 (lambda (id method params _callback &optional _on-error)
                   (setq sent (list id method params)))))
        (should (harness-test-await (harness-ui-report--walkthrough task)))
        (should (equal "_harness/session/btw" (car request)))
        (should (equal "s1" (plist-get (cdr request) :id)))
        (should (equal "demo:scripted" (plist-get (cdr request) :model)))
        (should (equal "btw1" shown))
        (should (equal "btw1" (car sent)))
        (should (equal "session/prompt" (nth 1 sent)))
        (should (equal harness-ui-report-review-test--walkthrough
                       (plist-get (car (plist-get (nth 2 sent) :prompt)) :text)))))))

(provide 'harness-ui-report-review-test)
;;; harness-ui-report-review-test.el ends here
