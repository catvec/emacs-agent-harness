;;; harness-tools-agent-test.el --- Tests for the meta tools  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo-delay)
(defvar harness-tools-agent--questions)
(defvar harness-tools-agent-planning-section)

(defmacro harness-tools-agent-test-with (&rest body)
  "Load the state layer with the demo provider and the meta tools, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tools-agent))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (clrhash harness-tools-agent--questions)
     (let ((harness-provider-demo-delay 0.005)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-tools-agent-test-session ()
  "Create a demo session and return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))

(defun harness-tools-agent-test-run (sid name input)
  "Execute tool NAME with INPUT in SID; return the promise."
  (harness-call 'tools/execute sid (list :id (harness-short-id) :name name :input input)))

(defun harness-tools-agent-test-kinds (id)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

(ert-deftest harness-tools-agent-registers-tools ()
  (harness-tools-agent-test-with
    (let ((names (mapcar (lambda (s) (plist-get s :name)) (harness-call 'tools/list))))
      (dolist (n '("ask_user" "plan" "todo_write" "spawn_agent" "session_info"))
        (should (member n names))))
    (should (eq 'meta (plist-get (harness-call 'tools/get "ask_user") :kind)))
    (should (eq 'read (plist-get (harness-call 'tools/get "session_info") :kind)))))

(ert-deftest harness-tools-agent-ask-user-blocks-and-answers ()
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (asked nil)
           (p (progn
                (harness-on 'question/asked (lambda (s item) (push (cons s item) asked)))
                (harness-tools-agent-test-run sid "ask_user"
                                              '(:question "Which colour?" :options ("red" "green"))))))
      (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "pending question")
      (should-not (harness-promise-settled-p p))
      (let* ((pending (harness-call 'question/pending sid))
             (item (car pending))
             (payload (plist-get item :payload)))
        (should (= 1 (length pending)))
        (should (eq 'question (plist-get item :kind)))
        (should (equal "Which colour?" (plist-get payload :question)))
        (should (equal '("red" "green") (plist-get payload :options)))
        (should (plist-get payload :call-id))
        (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status)))
        (should (= 1 (length asked)))
        (should (equal sid (caar asked)))
        (should (equal (plist-get item :id) (plist-get (cdar asked) :id)))
        (should (harness-call 'question/answer sid (plist-get item :id) '(:answer "green"))))
      (let ((result (harness-test-await p)))
        (should (equal "green" (plist-get result :content)))
        (should-not (plist-get result :is-error)))
      (should (null (harness-call 'session/pending sid)))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status))))))

(ert-deftest harness-tools-agent-ask-user-string-answer-and-cancel ()
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (p1 (harness-tools-agent-test-run sid "ask_user" '(:question "One?")))
           (p2 (harness-tools-agent-test-run sid "ask_user" '(:question "Two?"))))
      (harness-test-wait (lambda () (= 2 (length (harness-call 'question/pending sid)))) 5 "two questions")
      (let ((ids (mapcar (lambda (it) (plist-get it :id)) (harness-call 'question/pending sid))))
        (should (harness-call 'question/answer sid (car ids) "yes please"))
        (should (equal "yes please" (plist-get (harness-test-await p1) :content)))
        (should (harness-call 'question/cancel sid (cadr ids)))
        (should (equal "The user dismissed the question" (plist-get (harness-test-await p2) :content)))
        ;; Answering again is a no-op.
        (should-not (harness-call 'question/answer sid (car ids) "again")))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status))))))

(ert-deftest harness-tools-agent-ask-user-inside-a-turn ()
  "The demo `ask' script calls ask_user; the turn blocks until the UI answers."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (p (harness-call 'agent/prompt sid "ask me")))
      (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "question during turn")
      (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status)))
      (let ((pid (plist-get (car (harness-call 'question/pending sid)) :id)))
        (harness-call 'question/answer sid pid "blue"))
      (should (eq 'end-turn (plist-get (harness-test-await p) :stop-reason)))
      (let ((result (cl-find-if (lambda (n) (eq (plist-get n :kind) 'tool-result)) (harness-call 'session/nodes sid))))
        (should (equal "blue" (plist-get result :output))))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status))))))

(ert-deftest harness-tools-agent-plan-records-and-hints ()
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (plans nil))
      (harness-on 'session/plan (lambda (s text) (push (cons s text) plans)))
      (let ((result (harness-test-await
                     (harness-tools-agent-test-run sid "plan" '(:plan "1. read\n2. edit" :title "Fix it")))))
        (should-not (plist-get result :is-error))
        (should (string-match-p "Plan recorded" (plist-get result :content))))
      (should (equal "1. read\n2. edit" (plist-get (harness-call 'session/get sid) :plan)))
      (should (equal '(plan hint) (harness-tools-agent-test-kinds sid)))
      (let ((node (car (harness-call 'session/nodes sid))))
        (should (equal "Fix it" (plist-get node :title)))
        (should (equal "1. read\n2. edit" (plist-get node :content))))
      (should (equal "Plan updated" (plist-get (cadr (harness-call 'session/nodes sid)) :content)))
      (should (equal (list (cons sid "1. read\n2. edit")) plans)))))

(ert-deftest harness-tools-agent-system-prompt-mentions-forks-worktrees-merge ()
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (prompt (harness-run-filter 'agent/system-prompt "BASE" (harness-call 'session/get sid))))
      (should (string-prefix-p "BASE" prompt))
      (should (string-match-p "## Planning" prompt))
      (should (string-match-p "fork" prompt))
      (should (string-match-p "worktree" prompt))
      (should (string-match-p "merge queue" prompt))
      (should (string-match-p "spawn_agent" prompt))
      (should (string-match-p "`plan` tool" prompt)))
    ;; The same section reaches the provider through the agent.
    (let ((sid (harness-tools-agent-test-session)) (seen nil))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (setq seen (plist-get req :system)) (funcall orig req))))
        (harness-test-await (harness-call 'agent/prompt sid "hello")))
      (should (string-match-p "## Planning" seen)))))

(ert-deftest harness-tools-agent-todo-write ()
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (result (harness-test-await
                    (harness-tools-agent-test-run
                     sid "todo_write"
                     '(:todos ((:id "a" :text "Read the code" :status "done")
                               (:id "b" :text "Edit it" :status "in-progress")
                               "Run the tests"))))))
      (should-not (plist-get result :is-error))
      (should (string-match-p "\\[x\\] Read the code" (plist-get result :content)))
      (should (string-match-p "\\[~\\] Edit it" (plist-get result :content)))
      (should (string-match-p "\\[ \\] Run the tests" (plist-get result :content)))
      (should (string-match-p "3 todos: 1 done, 1 in progress, 1 pending" (plist-get result :content)))
      (let ((todos (plist-get (harness-call 'session/get sid) :todos)))
        (should (= 3 (length todos)))
        (should (equal '("a" "b" "t3") (mapcar (lambda (td) (plist-get td :id)) todos)))
        (should (equal '(done in-progress pending) (mapcar (lambda (td) (plist-get td :status)) todos)))
        (should (equal "Run the tests" (plist-get (nth 2 todos) :text)))))))

(ert-deftest harness-tools-agent-spawn-fresh-child ()
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (spawned nil) (progress nil))
      (harness-on 'agent/spawned (lambda (p c) (push (cons p c) spawned)))
      (harness-on 'tools/progress (lambda (_s _c text) (push text progress)))
      (let ((result (harness-test-await
                     (harness-tools-agent-test-run sid "spawn_agent"
                                                   '(:prompt "give me the tour" :name "explorer")))))
        (should-not (plist-get result :is-error))
        (should (string-match-p "# Tour" (plist-get result :content)))
        (should (string-match-p "\\[sub-agent session: [-0-9a-f]+, 1 tool calls, cost \\$" (plist-get result :content)))
        (let* ((cid (plist-get (plist-get result :meta) :child-id))
               (child (harness-call 'session/get cid)))
          (should (equal (list (cons sid cid)) spawned))
          (should (equal sid (plist-get child :parent-id)))
          (should (eq 'subagent (plist-get child :kind)))
          (should (equal "explorer" (plist-get child :name)))
          (should (equal "demo:scripted" (plist-get child :model)))
          (should (eq 'idle (plist-get child :status)))
          ;; A fresh child starts from the prompt only.
          (should (eq 'user (plist-get (car (harness-call 'session/nodes cid)) :kind)))
          (should (string-match-p "give me the tour" (plist-get (car (harness-call 'session/nodes cid)) :content)))
          ;; The parent lists it as a child.
          (should (equal (list cid) (mapcar (lambda (s) (plist-get s :id))
                                            (harness-call 'session/list (list :parent-id sid)))))))
      ;; Progress was reported as the child's tool calls happened.
      (should (cl-some (lambda (p) (string-match-p "list_dir" p)) progress))
      (should (cl-some (lambda (p) (string-match-p "started" p)) progress)))))

(ert-deftest harness-tools-agent-spawn-forked-child-shares-history ()
  (harness-tools-agent-test-with
    (let ((sid (harness-tools-agent-test-session)))
      (harness-test-await (harness-call 'agent/prompt sid "hello there"))
      (let* ((parent-nodes (harness-call 'session/nodes sid))
             (result (harness-test-await
                      (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "carry on" :fork t))))
             (cid (plist-get (plist-get result :meta) :child-id))
             (child (harness-call 'session/get cid))
             (child-nodes (harness-call 'session/nodes cid)))
        (should-not (plist-get result :is-error))
        (should (string-match-p "carry on" (plist-get result :content)))
        (should (eq 'subagent (plist-get child :kind)))
        (should (equal sid (plist-get child :parent-id)))
        (should (equal (plist-get (car (last parent-nodes)) :id) (plist-get child :fork-node)))
        ;; The child's transcript starts with the parent's nodes, same ids.
        (should (equal (mapcar (lambda (n) (plist-get n :id)) parent-nodes)
                       (mapcar (lambda (n) (plist-get n :id)) (seq-take child-nodes (length parent-nodes)))))
        (should (> (length child-nodes) (length parent-nodes)))
        ;; The parent's own transcript is untouched by the child's turn.
        (should (equal (length parent-nodes) (length (harness-call 'session/nodes sid))))))))

(ert-deftest harness-tools-agent-spawn-needs-a-prompt ()
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (result (harness-test-await (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "  ")))))
      (should (plist-get result :is-error))
      (should (string-match-p "needs a prompt" (plist-get result :content))))))

(ert-deftest harness-tools-agent-session-info ()
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session)))
      (harness-call 'session/update sid :name "main work" :silent t)
      (harness-test-await (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "hi" :name "kid")))
      (let ((text (plist-get (harness-test-await (harness-tools-agent-test-run sid "session_info" nil)) :content))
            (cid (plist-get (car (harness-call 'session/list (list :parent-id sid))) :id)))
        (should (string-match-p (concat "Session: " sid) text))
        (should (string-match-p "Name: main work" text))
        (should (string-match-p "Model: demo:scripted" text))
        (should (string-match-p "Permission mode: ask" text))
        (should (string-match-p "Status: idle" text))
        (should (string-match-p "Parent: none" text))
        (should (string-match-p (concat "Children: " cid) text))))))

(provide 'harness-tools-agent-test)
;;; harness-tools-agent-test.el ends here
