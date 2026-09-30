;;; harness-agent-test.el --- Tests for the turn loop  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defmacro harness-agent-test-with (&rest body)
  "Load the state layer with the demo provider and permissive tools, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (let ((harness-provider-demo-delay 0.005)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (harness-define-tool "list_dir" :description "list" :kind 'read
                            :handler (lambda (input _ctx) (format "listing of %s" (plist-get input :path))))
       (harness-define-tool "ask_user" :description "ask" :kind 'meta
                            :handler (lambda (input _ctx) (format "answer to %s: red" (plist-get input :question))))
       ,@body)))

(defun harness-agent-test-session ()
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))

(defun harness-agent-test-kinds (id)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

(ert-deftest harness-agent-text-turn ()
  (harness-agent-test-with
    (let* ((id (harness-agent-test-session))
           (events nil))
      (harness-on 'agent/turn-started (lambda (sid) (push (list 'started sid) events)))
      (harness-on 'agent/turn-ended (lambda (sid r) (push (list 'ended sid r) events)))
      (harness-on 'agent/stream (lambda (_sid _nid kind _d) (push (list 'stream kind) events)))
      (let ((result (harness-await (harness-call 'agent/prompt id "hello there"))))
        (should (eq 'end-turn (plist-get result :stop-reason))))
      (should (equal '(user assistant) (harness-agent-test-kinds id)))
      (let ((s (harness-call 'session/get id)))
        (should (eq 'idle (plist-get s :status)))
        (should (= 400 (plist-get (plist-get s :usage) :input)))
        (should (= 1 (plist-get (plist-get s :usage) :turns)))
        (should (string-match-p "hello there" (plist-get (cadr (harness-call 'session/nodes id)) :content))))
      (should (equal (list 'started id) (car (last events))))
      (should (equal (list 'ended id 'end-turn) (car events)))
      (should (memq 'assistant (mapcar #'cadr (cl-remove-if-not (lambda (e) (eq (car e) 'stream)) events)))))))

(ert-deftest harness-agent-tool-turn-native-loop ()
  (harness-agent-test-with
    (let* ((id (harness-agent-test-session))
           (calls nil))
      (harness-on 'agent/tool-call (lambda (_ n) (push (plist-get n :tool) calls)))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "give me the tour")) :stop-reason)))
      (should (equal '("list_dir") calls))
      (let ((kinds (harness-agent-test-kinds id)))
        (should (equal '(user thinking assistant tool-call tool-result assistant) kinds)))
      (let* ((nodes (harness-call 'session/nodes id))
             (result (nth 4 nodes)))
        (should (string-match-p "listing of" (plist-get result :output)))
        (should-not (plist-get result :is-error))
        (should (string-match-p "# Tour" (plist-get (nth 5 nodes) :content))))
      ;; One turn, two provider steps: usage from both steps accumulates.
      (should (= 1 (plist-get (plist-get (harness-call 'session/get id) :usage) :turns)))
      (should (= 1200 (plist-get (plist-get (harness-call 'session/get id) :usage) :input))))))

(ert-deftest harness-agent-denied-tool-is-reported ()
  (harness-agent-test-with
    (let ((id (harness-agent-test-session)))
      (harness-add-filter 'permission/decide
                          (lambda (_d next &rest _) (funcall next (list :behavior 'deny :reason "nope" :final t))) 5)
      (harness-await (harness-call 'agent/prompt id "tour please"))
      (let ((result (nth 4 (harness-call 'session/nodes id))))
        (should (eq 'tool-result (plist-get result :kind)))
        (should (plist-get result :is-error))
        (should (string-match-p "Denied: nope" (plist-get result :output)))))))

(ert-deftest harness-agent-steering-during-turn ()
  (harness-agent-test-with
    (let* ((id (harness-agent-test-session))
           (p1 (harness-call 'agent/prompt id "tour"))
           (p2 (progn (harness-test-wait (lambda () (harness-agent-running-p id)))
                      (harness-call 'agent/prompt id "also check the tests"))))
      (should (eq p1 p2))
      (harness-await p1)
      (let ((users (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes id))))
        (should (= 2 (length users)))
        (should (plist-get (plist-get (cadr users) :meta) :steering)))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status))))))

(ert-deftest harness-agent-queue-flushes-after-turn ()
  (harness-agent-test-with
    (let* ((id (harness-agent-test-session))
           (ended 0))
      (harness-on 'agent/turn-ended (lambda (&rest _) (cl-incf ended)))
      (harness-call 'agent/prompt id "first")
      (harness-await (harness-call 'agent/prompt id "queued one" '(:queue t)))
      (should (= 1 (length (plist-get (harness-call 'session/get id) :queue))))
      (harness-test-wait (lambda () (= ended 2)) 5 "second turn")
      (should (null (plist-get (harness-call 'session/get id) :queue)))
      (should (equal '(user assistant user assistant) (harness-agent-test-kinds id))))))

(ert-deftest harness-agent-cancel ()
  (harness-agent-test-with
    (let* ((id (harness-agent-test-session))
           (harness-provider-demo-delay 0.2)
           (p (harness-call 'agent/prompt id "tour")))
      (harness-test-wait (lambda () (harness-agent-running-p id)))
      (should (harness-call 'agent/cancel id))
      (should (eq 'cancelled (plist-get (harness-await p) :stop-reason)))
      (should-not (harness-agent-running-p id))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status))))))

(ert-deftest harness-agent-before-turn-gate ()
  (harness-agent-test-with
    (let ((id (harness-agent-test-session)))
      (harness-add-filter 'agent/before-turn
                          (lambda (_v next _session) (funcall next (list :proceed nil :reason "budget exhausted"))))
      (let ((r (harness-await (harness-call 'agent/prompt id "hi"))))
        (should (eq 'blocked (plist-get r :stop-reason))))
      (should (equal '(user hint) (harness-agent-test-kinds id)))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status))))))

(ert-deftest harness-agent-system-prompt-filter-and-tools-filter ()
  (harness-agent-test-with
    (let* ((id (harness-agent-test-session))
           (seen-system nil) (seen-tools nil))
      (harness-add-filter 'agent/system-prompt (lambda (v _s) (concat v "\nEXTRA SECTION")))
      (harness-add-filter 'agent/tools (lambda (names _s) (remove "ask_user" names)))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req)
                    (setq seen-system (plist-get req :system)
                          seen-tools (mapcar (lambda (s) (plist-get s :name)) (plist-get req :tools)))
                    (funcall orig req))))
        (harness-await (harness-call 'agent/prompt id "hi")))
      (should (string-match-p "EXTRA SECTION" seen-system))
      (should (string-match-p "Working directory" seen-system))
      (should (equal '("list_dir") seen-tools)))))

(provide 'harness-agent-test)
;;; harness-agent-test.el ends here
