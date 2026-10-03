;;; harness-compaction-test.el --- Tests for compaction  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo--delay)
(defvar harness-compaction--context-reserve)
(defvar harness-sessions)
(defvar harness-tools)
(defvar harness-agent--turns)
(defvar harness-compaction--running)
(declare-function harness-define-provider "harness-provider")
(declare-function harness-compaction-needed-p "harness-compaction")
(declare-function harness-compaction-hosted-p "harness-compaction")

(defmacro harness-compaction-test-with (&rest body)
  "Load the state layer with the demo provider and compaction, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent compaction))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-compaction--running)
     (let ((harness-provider-demo--delay 0.005)
           (harness-provider-demo-script-override nil)
           (harness-compaction--context-reserve 1000)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defconst harness-compaction-test-script
  '((:type text :delta "SUMMARY ") (:type text :delta "TEXT") (:type done :stop-reason end-turn)))

(defun harness-compaction-test-session (&rest plist)
  "Create a demo session (window 8000) with one answered exchange."
  (let ((id (plist-get (apply #'harness-call 'session/create :cwd (harness-test-temp-dir)
                              :model "demo:scripted" :context-window 8000 plist)
                       :id)))
    (harness-call 'session/append id '(:kind user :content "please refactor the parser"))
    (harness-call 'session/append id '(:kind assistant :content "Done: parser.el rewritten"))
    id))

(defun harness-compaction-test-kinds (id)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

(defun harness-compaction-test-hints (id)
  (mapcar (lambda (n) (plist-get n :content))
          (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'hint)) (harness-call 'session/nodes id))))

(defun harness-compaction-test-first-text (id)
  (plist-get (car (plist-get (car (harness-call 'session/messages id)) :content)) :text))

(ert-deftest harness-compaction-compact-appends-summary-node ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (old-head (plist-get (harness-call 'session/get id) :head))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (requests nil) (done nil))
      (harness-on 'compaction/done (lambda (sid node) (push (list sid (plist-get node :id)) done)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (let ((node (harness-await (harness-call 'compaction/compact id))))
          (should (eq 'compaction (plist-get node :kind)))
          (should (equal "SUMMARY TEXT" (plist-get node :content)))
          (should (equal old-head (plist-get (plist-get node :meta) :compacted-head)))
          (should (equal "demo:scripted" (plist-get (plist-get node :meta) :model)))
          (should (numberp (plist-get (plist-get node :meta) :input-tokens)))
          (should (equal (list (list id (plist-get node :id))) done))))
      ;; The request: no tools, no provider state, transcript then the ask.
      (should (= 1 (length requests)))
      (let* ((req (car requests))
             (last (car (last (plist-get req :messages)))))
        (should (null (plist-get req :tools)))
        (should (null (plist-get req :provider-state)))
        (should (string-match-p "handoff summary" (plist-get req :system)))
        (should (eq 'user (plist-get last :role)))
        (should (string-match-p "Summarize the conversation above"
                                (plist-get (car (last (plist-get last :content))) :text)))
        (should (= 3 (length (plist-get req :messages)))))
      ;; Transcript: hints around the node, messages restart at the summary.
      (should (equal '(user assistant hint compaction hint) (harness-compaction-test-kinds id)))
      (should (equal "Compacting context…" (car (harness-compaction-test-hints id))))
      (should (string-match-p "\\`Compacted: [0-9.k]+ tokens → summary\\'" (cadr (harness-compaction-test-hints id))))
      (should (= 1 (length (harness-call 'session/messages id))))
      (should (string-prefix-p "Summary of the conversation so far:\n\nSUMMARY TEXT"
                               (harness-compaction-test-first-text id)))
      (should (= (harness-estimate-tokens "SUMMARY TEXT")
                 (plist-get (plist-get (harness-call 'session/get id) :usage) :context)))
      (should (zerop (hash-table-count harness-compaction--running))))))

(ert-deftest harness-compaction-compact-error-rejects ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override '((:type done :stop-reason error :error "boom")))
           (failed nil))
      (harness-on 'compaction/failed (lambda (sid msg) (push (list sid msg) failed)))
      (should-error (harness-await (harness-call 'compaction/compact id)))
      (should (equal '(user assistant hint hint) (harness-compaction-test-kinds id)))
      (should (equal "Compaction failed: boom" (cadr (harness-compaction-test-hints id))))
      (should (equal (list (list id "boom")) failed))
      (should (zerop (hash-table-count harness-compaction--running))))))

(ert-deftest harness-compaction-compact-runs-once-per-session ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (calls 0))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (cl-incf calls) (funcall orig req))))
        (let ((p1 (harness-call 'compaction/compact id))
              (p2 (harness-call 'compaction/compact id)))
          (should (eq p1 p2))
          (harness-await p1)))
      (should (= 1 calls))
      (should (= 1 (cl-count 'compaction (harness-compaction-test-kinds id)))))))

(ert-deftest harness-compaction-status-levels ()
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (cl-flet ((status-at (context)
                  (harness-call 'session/usage-add id (list :context context))
                  (harness-call 'compaction/status id)))
        (let ((s (status-at 1000)))
          (should (= 8000 (plist-get s :window)))
          (should (= 1000 (plist-get s :reserve)))
          (should (= 7000 (plist-get s :usable)))
          (should (= 1000 (plist-get s :context)))
          (should (< (abs (- (plist-get s :fraction) (/ 1000.0 7000))) 1e-6))
          (should (eq 'ok (plist-get s :level))))
        (should (eq 'warning (plist-get (status-at 5000) :level)))
        (should (eq 'urgent (plist-get (status-at 6000) :level)))
        (should (eq 'critical (plist-get (status-at 6900) :level)))
        (should (eq 'critical (plist-get (status-at 9000) :level)))))))

(ert-deftest harness-compaction-status-caps-reserve-for-small-windows ()
  (harness-compaction-test-with
    (let* ((harness-compaction--context-reserve 20000)
           (id (harness-compaction-test-session))
           (s (harness-call 'compaction/status id)))
      (should (= 4000 (plist-get s :usable)))
      (should (eq 'ok (plist-get s :level)))
      (should-not (harness-compaction-needed-p (harness-call 'session/get id))))))

(ert-deftest harness-compaction-context-fraction-shortens-the-window ()
  "A session on a context fraction compacts at that part of its window."
  (harness-compaction-test-with
    (let* ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                        :model "demo:scripted" :context-fraction 0.5)
                          :id))
           (harness-provider-demo-script-override harness-compaction-test-script))
      (harness-call 'session/append id '(:kind user :content "please refactor the parser"))
      (harness-call 'session/append id '(:kind assistant :content "Done: parser.el rewritten"))
      ;; Half of the demo model's 8000, less the test's 1000-token reserve.
      (let ((s (harness-call 'compaction/status id)))
        (should (= 4000 (plist-get s :window)))
        (should (= 3000 (plist-get s :usable))))
      ;; 3500 tokens compacts on half the window, where a session with
      ;; the whole one would not.
      (harness-call 'session/usage-add id '(:context 3500))
      (should (harness-compaction-needed-p (harness-call 'session/get id)))
      (harness-await (harness-call 'agent/prompt id "carry on"))
      (should (member 'compaction (harness-compaction-test-kinds id))))))

(ert-deftest harness-compaction-auto-compacts-before-turn ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override harness-compaction-test-script)
           (requests nil))
      (harness-call 'session/usage-add id '(:context 7500))
      (should (harness-compaction-needed-p (harness-call 'session/get id)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (push req requests) (funcall orig req))))
        (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "next question"))
                                         :stop-reason))))
      (setq requests (nreverse requests))
      (should (= 2 (length requests)))
      ;; First the summariser, then the turn, whose transcript starts at the summary
      ;; and still carries the user's new message.
      (should (null (plist-get (car requests) :tools)))
      (let* ((turn (cadr requests))
             (first (car (plist-get turn :messages)))
             (texts (mapcar (lambda (b) (plist-get b :text)) (plist-get first :content))))
        (should (eq 'user (plist-get first :role)))
        (should (string-prefix-p "Summary of the conversation so far:\n\nSUMMARY TEXT" (car texts)))
        (should (member "next question" texts)))
      (should (equal '(user assistant hint compaction hint user assistant)
                     (harness-compaction-test-kinds id)))
      ;; The user's message follows the compaction node exactly once.
      (should (equal "next question" (plist-get (nth 5 (harness-call 'session/nodes id)) :content)))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status)))
      (should (< (plist-get (plist-get (harness-call 'session/get id) :usage) :context) 7000)))))

(ert-deftest harness-compaction-auto-idle-below-threshold ()
  (harness-compaction-test-with
    (let ((id (harness-compaction-test-session)))
      (harness-call 'session/usage-add id '(:context 6999))
      (harness-await (harness-call 'agent/prompt id "hello"))
      (should-not (memq 'compaction (harness-compaction-test-kinds id))))))

(ert-deftest harness-compaction-auto-skips-hosted-providers ()
  (harness-compaction-test-with
    (let ((completes 0))
      (harness-define-provider 'hostedfake
        :label "Hosted fake"
        :complete (lambda (req)
                    (cl-incf completes)
                    (let ((on-event (plist-get req :on-event)))
                      (run-at-time 0.005 nil
                                   (lambda ()
                                     (funcall on-event '(:type text :delta "ok"))
                                     (funcall on-event '(:type done :stop-reason end-turn)))))
                    (list :cancel #'ignore))
        :capabilities '(:hosted-loop t :compaction hosted))
      (let ((id (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                         :model "hostedfake:m" :context-window 8000)
                           :id)))
        (harness-call 'session/usage-add id '(:context 7500))
        (should (harness-compaction-needed-p (harness-call 'session/get id)))
        (should (harness-compaction-hosted-p (harness-call 'session/get id)))
        (harness-await (harness-call 'agent/prompt id "hello"))
        (should (= 1 completes))
        (should (equal '(user assistant) (harness-compaction-test-kinds id)))))))

(ert-deftest harness-compaction-auto-proceeds-when-compaction-fails ()
  (harness-compaction-test-with
    (let* ((id (harness-compaction-test-session))
           (harness-provider-demo-script-override '((:type done :stop-reason error :error "boom")))
           (started 0))
      (harness-on 'agent/turn-started (lambda (_) (cl-incf started)))
      (harness-call 'session/usage-add id '(:context 7500))
      (harness-await (harness-call 'agent/prompt id "hello"))
      (should (= 1 started))
      (should (member "Compaction failed: boom" (harness-compaction-test-hints id)))
      (should-not (memq 'compaction (harness-compaction-test-kinds id))))))

(provide 'harness-compaction-test)
;;; harness-compaction-test.el ends here
