;;; harness-tools-agent-test.el --- Tests for the meta tools  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)
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
     (let ((harness-provider-demo--delay 0.005)
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

(defun harness-tools-agent-test-asked (sid input)
  "Ask INPUT in SID; return the pending question's payload once it waits."
  (harness-tools-agent-test-run sid "ask_user" input)
  (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "pending question")
  (plist-get (car (harness-call 'question/pending sid)) :payload))

(ert-deftest harness-tools-agent-ask-user-options-with-diagrams ()
  "Options may each carry an ASCII diagram or an image; the question keeps
the labels as its options and the diagrams beside them, one per option."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (cwd (plist-get (harness-call 'session/get sid) :cwd)))
      (make-directory (expand-file-name "img" cwd) t)
      (write-region "not really a png" nil (expand-file-name "img/top.png" cwd) nil 'silent)
      (let ((payload (harness-tools-agent-test-asked
                      sid `(:question "Which layout?"
                            :options ((:label "Sidebar" :diagram "\n```text\n+--+----+\n|  |    |\n+--+----+\n```\n")
                                      (:label "Tabs" :image "img/top.png"))))))
        (should (equal '("Sidebar" "Tabs") (plist-get payload :options)))
        (should (equal `((:type "ascii" :text "+--+----+\n|  |    |\n+--+----+")
                         (:type "image" :path ,(expand-file-name "img/top.png" cwd) :mime "image/png"))
                       (plist-get payload :diagrams)))
        (let ((pid (plist-get (car (harness-call 'question/pending sid)) :id)))
          ;; The answer is the label.
          (should (harness-call 'question/answer sid pid "Tabs"))))
      ;; Without diagrams nothing changes: no `:diagrams', strings as they were.
      (let ((payload (harness-tools-agent-test-asked
                      sid '(:question "Which colour?" :options ("red" (:label "green") 7)))))
        (should (equal '("red" "green") (plist-get payload :options)))
        (should-not (plist-member payload :diagrams))))))

(ert-deftest harness-tools-agent-ask-user-diagrams-all-or-none ()
  "A call where only some options have a diagram, or with a malformed
option, is an error saying what to fix, and asks nothing."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (cwd (plist-get (harness-call 'session/get sid) :cwd))
           (try (lambda (options)
                  (let ((result (harness-test-await
                                 (harness-tools-agent-test-run sid "ask_user"
                                                               (list :question "Which?" :options options)))))
                    (should (plist-get result :is-error))
                    (should-not (harness-call 'question/pending sid))
                    (plist-get result :content)))))
      (write-region "x" nil (expand-file-name "notes.txt" cwd) nil 'silent)
      (should (string-match-p "Every option needs a diagram once one has: options 2 and 3 have none"
                              (funcall try '((:label "A" :diagram "[A]") "B" (:label "C")))))
      (should (string-match-p "option 1 has none"
                              (funcall try '("A" (:label "B" :diagram "[B]")))))
      ;; A blank diagram is none.
      (should (string-match-p "option 2 has none"
                              (funcall try '((:label "A" :diagram "[A]") (:label "B" :diagram " \n ")))))
      (should (string-match-p "Option 1 has both a diagram and an image"
                              (funcall try '((:label "A" :diagram "[A]" :image "a.png")))))
      (should (string-match-p "Option 2 needs a label"
                              (funcall try '((:label "A" :diagram "[A]") (:diagram "[B]")))))
      (should (string-match-p "Option 1: image missing.png not found"
                              (funcall try '((:label "A" :image "missing.png") (:label "B" :diagram "[B]")))))
      (should (string-match-p "Option 1: notes.txt is not an image file"
                              (funcall try '((:label "A" :image "notes.txt") (:label "B" :diagram "[B]")))))
      ;; A full page's screenshot, 1400x12000: too large to show; crop it.
      (let ((coding-system-for-write 'no-conversion))
        (write-region (unibyte-string #x89 ?P ?N ?G ?\r ?\n #x1a ?\n 0 0 0 13 ?I ?H ?D ?R
                                      0 0 5 120 0 0 46 224 8 6 0 0 0)
                      nil (expand-file-name "page.png" cwd) nil 'silent))
      (should (string-match-p "Option 2: image page.png is 1400x12000 pixels, too large to show; crop it"
                              (funcall try '((:label "A" :diagram "[A]") (:label "B" :image "page.png")))))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status))))))

(defvar harness-tools-agent-image-max-bytes)

(ert-deftest harness-tools-agent-question-image-gives-the-file ()
  "`question/image' gives an option's image, read where the harness runs,
for a client that cannot read the path; it says why when it cannot."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (cwd (plist-get (harness-call 'session/get sid) :cwd))
           (bytes harness-test-png))
      (let ((coding-system-for-write 'no-conversion))
        (write-region bytes nil (expand-file-name "a.png" cwd) nil 'silent)
        (write-region "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"/>" nil
                      (expand-file-name "b.svg" cwd) nil 'silent))
      (harness-tools-agent-test-asked sid '(:question "Which?" :options ((:label "A" :image "a.png")
                                                                         (:label "B" :image "b.svg"))))
      (let ((pid (plist-get (car (harness-call 'question/pending sid)) :id)))
        (let ((image (harness-call 'question/image sid pid 0)))
          (should (equal "image/png" (plist-get image :mime)))
          (should (equal bytes (base64-decode-string (plist-get image :data)))))
        (should (equal "image/svg+xml" (plist-get (harness-call 'question/image sid pid 1) :mime)))
        (should (string-match-p "Option 2 of question .* shows no image"
                                (cadr (should-error (harness-call 'question/image sid pid 2)))))
        (should (string-match-p "No question nope waits"
                                (cadr (should-error (harness-call 'question/image sid "nope" 0)))))
        (let ((harness-tools-agent-image-max-bytes 8))
          (should (string-match-p "a\\.png is larger than 8"
                                  (cadr (should-error (harness-call 'question/image sid pid 0))))))
        (delete-file (expand-file-name "a.png" cwd))
        (should (string-match-p "a\\.png cannot be read any more"
                                (cadr (should-error (harness-call 'question/image sid pid 0)))))
        ;; Over ACP too, by the names a client gives.
        (harness-test-load-module 'acp)
        (should (equal "image/svg+xml"
                       (plist-get (harness-acp--call-extension "question/image"
                                                               (list :sessionId sid :pid pid :index 1))
                                  :mime)))
        ;; Once answered, it is no longer given.
        (harness-call 'question/answer sid pid "A")
        (should-error (harness-call 'question/image sid pid 1))))))

(ert-deftest harness-tools-agent-demo-images-script ()
  "The demo provider's `images' script draws SVG mockups in the session's
temporary directory and asks with one per option, as a model is told to."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (tmp (harness-call 'session/tmp-dir sid))
           (p (harness-call 'agent/prompt sid "Show me the layouts as images")))
      (harness-test-wait (lambda () (harness-call 'question/pending sid)) 5 "the question with images")
      (let* ((item (car (harness-call 'question/pending sid)))
             (payload (plist-get item :payload))
             (diagrams (plist-get payload :diagrams)))
        (should (equal '("Sidebar on the left" "Sidebar on the right" "Tabs across the top")
                       (plist-get payload :options)))
        (should (= 3 (length diagrams)))
        (dolist (d diagrams)
          (should (equal "image" (plist-get d :type)))
          (should (equal "image/svg+xml" (plist-get d :mime)))
          (should (file-in-directory-p (plist-get d :path) tmp))
          (with-temp-buffer
            (insert-file-contents (plist-get d :path))
            (should (looking-at-p "<svg [^>]*viewBox=\"0 0 600 400\""))))
        ;; Three drawings, not one thrice.
        (should (= 3 (length (delete-dups (mapcar (lambda (d) (with-temp-buffer
                                                                (insert-file-contents (plist-get d :path))
                                                                (buffer-string)))
                                                  diagrams)))))
        (harness-call 'question/answer sid (plist-get item :id) "Tabs across the top"))
      (should (eq 'end-turn (plist-get (harness-test-await p) :stop-reason))))))

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

(ert-deftest harness-tools-agent-question-ask-for-the-harness ()
  "`question/ask' asks the user a question with no tool call behind it:
the session is blocked on it, its payload carries what the caller adds,
and the caller hears the answer, or that it was dismissed."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (heard nil)
           (asked nil)
           (pid (progn
                  (harness-on 'question/asked (lambda (s item) (push (cons s (plist-get item :id)) asked)))
                  (harness-call 'question/ask sid
                                '(:question "Which way?" :options ["Left" "Right"] :extra (:a 1))
                                (lambda (text dismissed) (push (list text dismissed) heard))))))
      (should (equal (list (cons sid pid)) asked))
      (should (eq 'blocked (plist-get (harness-call 'session/get sid) :status)))
      (let ((payload (plist-get (car (harness-call 'question/pending sid)) :payload)))
        (should (equal "Which way?" (plist-get payload :question)))
        (should (equal '("Left" "Right") (plist-get payload :options)))
        (should (eq t (plist-get payload :allow-free-text)))
        (should (equal '(:a 1) (plist-get payload :extra)))
        (should-not (plist-get payload :call-id)))
      (should (harness-call 'question/answer sid pid '(:answer "Right")))
      (should (equal '(("Right" nil)) heard))
      (should-not (harness-call 'question/pending sid))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))
      ;; Asked again, then dismissed; free text off.
      (let ((pid (harness-call 'question/ask sid '(:question "Sure?" :allow-free-text nil)
                               (lambda (text dismissed) (push (list text dismissed) heard)))))
        (should-not (plist-get (plist-get (car (harness-call 'question/pending sid)) :payload) :allow-free-text))
        (should (harness-call 'question/cancel sid pid))
        (should (equal '("The user dismissed the question" t) (car heard)))
        (should-not (harness-call 'question/answer sid pid "late"))
        (should (= 2 (length heard)))))))

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
      (should (string-match-p "background=true" prompt))
      (should (string-match-p "same step run at once" prompt))
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
          ;; A fresh child starts from the prompt only, which the parent's
          ;; agent wrote, not the user, after the hint that says its
          ;; window is capped.
          (let ((nodes (harness-call 'session/nodes cid)))
            (should (eq 'hint (plist-get (car nodes) :kind)))
            (should (string-match-p "\\`Context window capped at 256k tokens" (plist-get (car nodes) :content)))
            (should (eq 'user (plist-get (cadr nodes) :kind)))
            (should (string-match-p "give me the tour" (plist-get (cadr nodes) :content)))
            (should (equal (list :kind 'session :id sid :name nil)
                           (harness-node-sender (cadr nodes)))))
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
        ;; Its new message is the parent's; the copied one stays the user's.
        (should-not (harness-node-sender (car child-nodes)))
        (should (equal sid (plist-get (harness-node-sender
                                       (cl-find 'user (nthcdr (length parent-nodes) child-nodes)
                                                :key (lambda (n) (plist-get n :kind))))
                                      :id)))
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
        (should (string-match-p (concat "^Temporary directory: " (regexp-quote (harness-call 'session/tmp-dir sid)) "$")
                                text))
        (should (string-match-p "Permission mode: ask" text))
        (should (string-match-p "^Non-interactive: off$" text))
        (should (string-match-p "Status: idle" text))
        (should (string-match-p "Parent: none" text))
        (should (string-match-p (concat "Children: " cid) text)))
      (harness-call 'session/update sid :non-interactive t :silent t)
      (should (string-match-p "^Non-interactive: on (the user is away"
                              (plist-get (harness-test-await (harness-tools-agent-test-run sid "session_info" nil))
                                         :content))))))

(ert-deftest harness-tools-agent-spawn-cwd-is-jailed ()
  "A sub-agent works where it starts, so the jail checks its cwd as it
checks bash's: one outside the allowed directories needs the user,
and with the user away the call is denied and no child starts."
  (harness-tools-agent-test-with
    (harness-test-load-module 'perms)
    (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"
                                         :non-interactive t)
                           :id))
           (cwd (plist-get (harness-call 'session/get sid) :cwd))
           (outside (harness-test-temp-dir))
           (tool (harness-tool-get "spawn_agent")))
      (should (equal (list (expand-file-name "." cwd)) (harness-tools--paths tool '(:prompt "hi") (list :cwd cwd))))
      (should (equal (list outside) (harness-tools--paths tool (list :prompt "hi" :cwd outside) (list :cwd cwd))))
      (let ((r (harness-test-await (harness-tools-agent-test-run sid "spawn_agent" (list :prompt "hi" :cwd outside)))))
        (should (plist-get r :denied))
        (should (string-match-p "outside the allowed directories" (plist-get r :content))))
      (should-not (harness-call 'session/list (list :parent-id sid))))))

;;;; A sub-agent forked mid-turn, against a strict OpenAI-compatible server

(require 'harness-http)
(require 'harness-provider-openai)

(defconst harness-tools-agent-test--unanswered-error
  "An assistant message with 'tool_calls' must be followed by tool messages responding to each 'tool_call_id'. (insufficient tool messages following tool_calls message)"
  "What DeepSeek answers a request with a tool call left unanswered.")

(defconst harness-tools-agent-test--orphan-error
  "Messages with role 'tool' must be a response to a preceding message with 'tool_calls'"
  "What DeepSeek answers a request with a tool message that answers no call.")

(defvar harness-tools-agent-test--strict-endpoint
  '(:id teststrict :label "Strict" :base-url "https://api.deepseek.example"
    :api-key "sk-test-strict" :flavor deepseek)
  "A DeepSeek endpoint served by `harness-tools-agent-test--strict-request'.")

(defvar harness-tools-agent-test--bodies nil
  "The chat completion bodies the strict server got, newest first.")

(defun harness-tools-agent-test--strict-error (messages)
  "Return the error a strict OpenAI-compatible server gives MESSAGES, or nil.
Like DeepSeek, it wants the tool messages right after an assistant
message with tool_calls to answer each of its calls, and each tool
message to answer a call of the assistant message before it."
  (let ((open nil))
    (catch 'invalid
      (dolist (m messages)
        (if (equal (plist-get m :role) "tool")
            (if (member (plist-get m :tool_call_id) open)
                (setq open (remove (plist-get m :tool_call_id) open))
              (throw 'invalid harness-tools-agent-test--orphan-error))
          (when open (throw 'invalid harness-tools-agent-test--unanswered-error))
          (setq open (mapcar (lambda (c) (plist-get c :id)) (plist-get m :tool_calls)))))
      (and open harness-tools-agent-test--unanswered-error))))

(defun harness-tools-agent-test--text-of (message)
  "Return the text of OpenAI MESSAGE, whose content is a string or parts."
  (let ((content (plist-get message :content)))
    (if (listp content)
        (mapconcat (lambda (part) (or (plist-get part :text) "")) content " ")
      (or content ""))))

(defun harness-tools-agent-test--sse (&rest payloads)
  "Return one SSE chunk holding PAYLOADS, strings or plists."
  (mapconcat (lambda (p) (format "data: %s\n\n" (if (stringp p) p (harness-json-encode p))))
             payloads ""))

(defun harness-tools-agent-test--strict-reply (body)
  "Return (STATUS . BODY-TEXT), the strict server's answer to chat BODY.
An invalid request gets DeepSeek's HTTP 400.  Otherwise a request that
brings tool results gets a closing answer, one whose last message asks
to investigate gets the sub-agent's finding, and any other one gets a
spawn_agent call forking the session."
  (let* ((messages (plist-get body :messages))
         (last (car (last messages)))
         (text (lambda (s)
                 (harness-tools-agent-test--sse
                  (list :choices (list (list :index 0 :delta (list :content s) :finish_reason "stop")))
                  "[DONE]")))
         (err (harness-tools-agent-test--strict-error messages)))
    (cond
     (err (cons 400 (harness-json-encode (list :error (list :message err :type "invalid_request_error")))))
     ((equal (plist-get last :role) "tool") (cons 200 (funcall text "The sub-agent reported back.")))
     ((string-match-p "investigate" (harness-tools-agent-test--text-of last))
      (cons 200 (funcall text "Found it: the fork lost its tool results.")))
     (t (cons 200 (harness-tools-agent-test--sse
                   (list :choices
                         (list (list :index 0
                                     :delta (list :tool_calls
                                                  (list (list :index 0 :id "call_spawn" :type "function"
                                                              :function (list :name "spawn_agent"
                                                                              :arguments "{\"prompt\":\"investigate the bug\",\"fork\":true}"))))
                                     :finish_reason "tool_calls")))
                   "[DONE]"))))))

(defun harness-tools-agent-test--strict-request (url &rest args)
  "Answer the request to URL with ARGS as the strict server would, soon.
The model list is empty; chat completions are recorded and answered by
`harness-tools-agent-test--strict-reply'."
  (let ((handle (make-harness-http-handle :url url :callback (plist-get args :callback)
                                          :on-chunk (plist-get args :on-chunk) :started (float-time))))
    (harness-run-soon
     (lambda ()
       (unless (harness-http-handle-cancelled handle)
         (pcase-let ((`(,status . ,text)
                      (if (string-match-p "/models\\'" url)
                          (cons 200 "{\"data\":[]}")
                        (push (plist-get args :json) harness-tools-agent-test--bodies)
                        (harness-tools-agent-test--strict-reply (plist-get args :json)))))
           (when (plist-get args :on-headers) (funcall (plist-get args :on-headers) status nil))
           (if (plist-get args :on-chunk)
               (progn (funcall (plist-get args :on-chunk) text)
                      (funcall (plist-get args :callback) status nil "" nil))
             (funcall (plist-get args :callback) status nil text nil))))))
    handle))

(ert-deftest harness-tools-agent-spawn-fork-mid-turn-strict-server ()
  "A sub-agent forked in the middle of a turn makes a first request that a
strict OpenAI-compatible server accepts.  The transcript it copies ends
with the spawn_agent call forking it, whose result only ever reaches
the parent: left unanswered in the fork, DeepSeek refused the fork's
first request with HTTP 400 and the sub-agent died before doing
anything.  The fork answers that call itself, saying it is the
sub-agent the call started."
  (harness-tools-agent-test-with
    (let ((harness-tools-agent-test--bodies nil))
      (unwind-protect
          (cl-letf (((symbol-function 'harness-http-request) #'harness-tools-agent-test--strict-request))
            (harness-openai-register-endpoint harness-tools-agent-test--strict-endpoint)
            (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                                 :model "teststrict:deepseek-flash")
                                   :id))
                   (turn (harness-test-await (harness-call 'agent/prompt sid "Please delegate this") 20))
                   (result (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-result)
                                                        (equal (plist-get n :call-id) "call_spawn")))
                                       (harness-call 'session/nodes sid)))
                   (cid (plist-get (car (harness-call 'session/list (list :parent-id sid))) :id))
                   (bodies (reverse harness-tools-agent-test--bodies)))
              (should (eq 'end-turn (plist-get turn :stop-reason)))
              ;; The sub-agent did its work, and the parent got its answer.
              (should-not (plist-get result :is-error))
              (should (string-match-p "Found it" (plist-get result :output)))
              (should (eq 'subagent (plist-get (harness-call 'session/get cid) :kind)))
              ;; The result names the session it ran, for the chat to link.
              (should (equal cid (plist-get (plist-get result :meta) :child-id)))
              ;; Parent, sub-agent, parent again: each request a valid one.
              (should (= 3 (length bodies)))
              (should (equal '(nil nil nil)
                             (mapcar (lambda (b) (harness-tools-agent-test--strict-error (plist-get b :messages)))
                                     bodies)))
              ;; The sub-agent's request: the parent's transcript, the call
              ;; that forked it answered, then its task.
              (let* ((messages (cdr (plist-get (nth 1 bodies) :messages))) ; after the system prompt
                     (tool (cl-find "tool" messages :key (lambda (m) (plist-get m :role)) :test #'equal)))
                (should (equal '("user" "assistant" "tool" "user")
                               (mapcar (lambda (m) (plist-get m :role)) messages)))
                (should (equal "Please delegate this" (harness-tools-agent-test--text-of (nth 0 messages))))
                (should (equal "call_spawn" (plist-get (car (plist-get (nth 1 messages) :tool_calls)) :id)))
                (should (equal "call_spawn" (plist-get tool :tool_call_id)))
                (should (string-match-p "sub-agent" (plist-get tool :content)))
                (should (equal "investigate the bug" (harness-tools-agent-test--text-of (nth 3 messages)))))))
        (harness-provider-unregister 'teststrict)))))

(defvar harness-non-interactive)

(ert-deftest harness-tools-agent-children-keep-the-parents-switch ()
  "A sub-agent is as non-interactive as its parent, whatever the setting says."
  (harness-tools-agent-test-with
    (let ((harness-non-interactive t))
      (dolist (on '(nil t))
        (dolist (fork '(nil t))
          (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted"
                                               :non-interactive (if on t :false))
                                 :id))
                 (result (harness-test-await (harness-tools-agent-test-run sid "spawn_agent"
                                                                           (list :prompt "hi" :fork fork))))
                 (cid (plist-get (plist-get result :meta) :child-id)))
            (ert-info ((format "parent non-interactive %s, fork %s" on fork))
              (should (eq on (plist-get (harness-call 'session/get cid) :non-interactive))))))))))

;;;; The context cap

(defvar harness-subagent-context-limit)
(declare-function harness-tools-agent-context-limit "harness-tools-agent")

(ert-deftest harness-tools-agent-context-limit-fresh-is-the-cap ()
  "A fresh sub-agent's window is the cap, whatever the parent has used."
  (harness-tools-agent-test-with
    (should (= 256000 harness-subagent-context-limit))
    (let ((sid (harness-tools-agent-test-session)))
      (should (= 256000 (harness-tools-agent-context-limit sid nil)))
      (harness-call 'session/usage-add sid '(:input 10 :output 40 :context 3020))
      (should (= 256000 (harness-tools-agent-context-limit sid nil)))
      (let ((harness-subagent-context-limit 5000))
        (should (= 5000 (harness-tools-agent-context-limit sid nil)))))))

(ert-deftest harness-tools-agent-context-limit-fork-adds-what-it-inherits ()
  "A fork gets the parent's context and last output on top of the cap."
  (harness-tools-agent-test-with
    (let ((sid (harness-tools-agent-test-session)))
      ;; Nothing known about the parent's context: it inherits nothing.
      (should (= 256000 (harness-tools-agent-context-limit sid t)))
      (harness-call 'session/usage-add sid '(:input 10 :output 40 :context 3020))
      (should (= (+ 256000 3020 40) (harness-tools-agent-context-limit sid t)))
      ;; Only the last request's output counts, not the totals.
      (harness-call 'session/usage-add sid '(:input 10 :output 60 :context 4000))
      (should (= (+ 256000 4000 60) (harness-tools-agent-context-limit sid t)))
      (let ((harness-subagent-context-limit 1000))
        (should (= (+ 1000 4000 60) (harness-tools-agent-context-limit sid t))))
      ;; A flag that came over JSON counts as the boolean it is.
      (should (= 256000 (harness-tools-agent-context-limit sid :false)))
      (should (= (+ 256000 4000 60) (harness-tools-agent-context-limit sid 'yes))))))

(ert-deftest harness-tools-agent-context-limit-never-above-the-parents ()
  "The parent's own limit caps the child's, a fork's included."
  (harness-tools-agent-test-with
    (let ((sid (harness-tools-agent-test-session)))
      (harness-call 'session/update sid :context-window-limit 50000 :silent t)
      (harness-call 'session/usage-add sid '(:input 10 :output 40 :context 3020))
      (should (= 50000 (harness-tools-agent-context-limit sid nil)))
      (should (= 50000 (harness-tools-agent-context-limit sid t)))
      (let ((harness-subagent-context-limit 10000))
        (should (= 10000 (harness-tools-agent-context-limit sid nil)))
        (should (= 13060 (harness-tools-agent-context-limit sid t)))))))

(ert-deftest harness-tools-agent-context-limit-a-256k-parent-keeps-its-child-at-256k ()
  "A sub-agent of a session capped at 256000 gets 256000, as a task session's does."
  (harness-tools-agent-test-with
    (let ((sid (harness-tools-agent-test-session)))
      (harness-call 'session/update sid :context-window-limit 256000 :silent t)
      (harness-call 'session/usage-add sid '(:input 10 :output 40 :context 3020))
      (should (= 256000 (harness-tools-agent-context-limit sid nil)))
      (should (= 256000 (harness-tools-agent-context-limit sid t))))))

(ert-deftest harness-tools-agent-context-limit-nil-is-no-cap ()
  "Without a cap there is no limit to give, an unknown parent included."
  (harness-tools-agent-test-with
    (let ((sid (harness-tools-agent-test-session))
          (harness-subagent-context-limit nil))
      (should-not (harness-tools-agent-context-limit sid nil))
      (should-not (harness-tools-agent-context-limit sid t)))
    ;; A parent nobody knows inherits nothing and limits nothing.
    (should (= 256000 (harness-tools-agent-context-limit "no-such-session" t)))))

(ert-deftest harness-tools-agent-spawn-fresh-child-has-the-cap ()
  "A fresh child of spawn_agent gets the cap, and never more than the parent has."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (cid (plist-get (plist-get (harness-test-await
                                       (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "hi")))
                                      :meta)
                           :child-id)))
      (should (= 256000 (plist-get (harness-call 'session/get cid) :context-window-limit))))
    (let* ((sid (harness-tools-agent-test-session))
           (harness-subagent-context-limit 90000)
           (cid (plist-get (plist-get (harness-test-await
                                       (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "hi")))
                                      :meta)
                           :child-id)))
      (should (= 90000 (plist-get (harness-call 'session/get cid) :context-window-limit)))
      ;; A sub-agent that spawns one passes the cap on, not more.
      (let* ((harness-subagent-context-limit 200000)
             (grand (plist-get (plist-get (harness-test-await
                                           (harness-tools-agent-test-run cid "spawn_agent" '(:prompt "hi")))
                                          :meta)
                               :child-id)))
        (should (= 90000 (plist-get (harness-call 'session/get grand) :context-window-limit)))))))

(ert-deftest harness-tools-agent-spawn-fork-has-the-inherited-context-plus-the-cap ()
  "A forked child's window is its inherited context plus the cap."
  (harness-tools-agent-test-with
    (let ((sid (harness-tools-agent-test-session)))
      (harness-test-await (harness-call 'agent/prompt sid "hello there"))
      (let* ((usage (plist-get (harness-call 'session/get sid) :usage))
             (inherited (+ (or (plist-get usage :context) 0) (or (plist-get usage :last-output) 0)))
             (result (harness-test-await
                      (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "carry on" :fork t))))
             (cid (plist-get (plist-get result :meta) :child-id)))
        (should (> inherited 0))
        (should (= (+ 256000 inherited)
                   (plist-get (harness-call 'session/get cid) :context-window-limit)))))
    ;; The parent's own limit still bounds it.
    (let ((sid (harness-tools-agent-test-session)))
      (harness-call 'session/update sid :context-window-limit 60000 :silent t)
      (harness-test-await (harness-call 'agent/prompt sid "hello there"))
      (let* ((result (harness-test-await
                      (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "carry on" :fork t))))
             (cid (plist-get (plist-get result :meta) :child-id)))
        (should (= 60000 (plist-get (harness-call 'session/get cid) :context-window-limit)))))))

(ert-deftest harness-tools-agent-spawn-without-a-cap-leaves-limits-alone ()
  "With no cap a fresh child has no limit and a fork keeps its parent's."
  (harness-tools-agent-test-with
    (let* ((harness-subagent-context-limit nil)
           (sid (harness-tools-agent-test-session)))
      (let ((cid (plist-get (plist-get (harness-test-await
                                        (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "hi")))
                                       :meta)
                            :child-id)))
        (should-not (plist-get (harness-call 'session/get cid) :context-window-limit)))
      (harness-call 'session/update sid :context-window-limit 70000 :silent t)
      (let ((cid (plist-get (plist-get (harness-test-await
                                        (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "hi" :fork t)))
                                       :meta)
                            :child-id)))
        (should (= 70000 (plist-get (harness-call 'session/get cid) :context-window-limit)))))))

;;;; The hint that says the cap

(declare-function harness-tools-agent-context-limit-hint "harness-tools-agent")
(declare-function harness-tools-agent-inherited-context "harness-tools-agent")

(defun harness-tools-agent-test-hints (id)
  "Return the texts of the hints in the transcript of session ID, oldest first."
  (cl-loop for n in (harness-call 'session/nodes id)
           when (eq (plist-get n :kind) 'hint) collect (plist-get n :content)))

(defun harness-tools-agent-test-spawn (sid input)
  "Run spawn_agent with INPUT in session SID; return the child's id."
  (plist-get (plist-get (harness-test-await (harness-tools-agent-test-run sid "spawn_agent" input))
                        :meta)
             :child-id))

(ert-deftest harness-tools-agent-context-limit-hint-says-what-the-window-is ()
  "The text names the cap, what a fork starts with and a parent's lower limit; no cap, no text."
  (harness-tools-agent-test-with
    (should-not (harness-tools-agent-context-limit-hint nil nil))
    (should-not (harness-tools-agent-context-limit-hint nil t 90000))
    ;; A fresh sub-agent's window is the cap.
    (should (equal "Context window capped at 256k tokens, as a sub-agent's is (harness-subagent-context-limit)"
                   (harness-tools-agent-context-limit-hint 256000 nil)))
    ;; A fork's is what it starts with and the cap on top of that.
    (should (equal "Context window capped at 346k tokens: the 90k it starts with plus 256k of its own, as a sub-agent's is (harness-subagent-context-limit)"
                   (harness-tools-agent-context-limit-hint 346000 t 90000)))
    (should (equal "Context window capped at 259k tokens: the 3.1k it starts with plus 256k of its own, as a sub-agent's is (harness-subagent-context-limit)"
                   (harness-tools-agent-context-limit-hint 259060 t 3060)))
    ;; A fork that starts with nothing, and a flag that came over JSON as false, are as a fresh one.
    (should (equal (harness-tools-agent-context-limit-hint 256000 nil)
                   (harness-tools-agent-context-limit-hint 256000 t)))
    (should (equal (harness-tools-agent-context-limit-hint 256000 nil)
                   (harness-tools-agent-context-limit-hint 256000 t 0)))
    (should (equal (harness-tools-agent-context-limit-hint 256000 nil)
                   (harness-tools-agent-context-limit-hint 256000 :false 90000)))
    ;; The cap in the text is the setting's.
    (let ((harness-subagent-context-limit 5000))
      (should (equal "Context window capped at 5k tokens, as a sub-agent's is (harness-subagent-context-limit)"
                     (harness-tools-agent-context-limit-hint 5000 nil)))
      (should (equal "Context window capped at 8.1k tokens: the 3.1k it starts with plus 5k of its own, as a sub-agent's is (harness-subagent-context-limit)"
                     (harness-tools-agent-context-limit-hint 8060 t 3060))))
    ;; A limit the parent's own holds below what the cap allows says so.
    (should (equal "Context window capped at 60k tokens, as a sub-agent's is (harness-subagent-context-limit), and no higher than the limit of the session that started it"
                   (harness-tools-agent-context-limit-hint 60000 nil)))
    (should (equal "Context window capped at 60k tokens, as a sub-agent's is (harness-subagent-context-limit), and no higher than the limit of the session that started it"
                   (harness-tools-agent-context-limit-hint 60000 t 3060)))))

(ert-deftest harness-tools-agent-inherited-context-is-what-the-parent-holds ()
  "A fork starts with the parent's context and last output; an unknown parent holds nothing."
  (harness-tools-agent-test-with
    (let ((sid (harness-tools-agent-test-session)))
      (should (= 0 (harness-tools-agent-inherited-context sid)))
      (harness-call 'session/usage-add sid '(:input 10 :output 40 :context 3020))
      (should (= 3060 (harness-tools-agent-inherited-context sid)))
      (should (= 0 (harness-tools-agent-inherited-context "no-such-session")))
      (should (= 0 (harness-tools-agent-inherited-context nil))))))

(ert-deftest harness-tools-agent-spawn-says-the-cap-in-a-fresh-childs-transcript ()
  "The hint is the first thing in the child's transcript, and the parent's has none."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (cid (harness-tools-agent-test-spawn sid '(:prompt "hi"))))
      (should (equal '("Context window capped at 256k tokens, as a sub-agent's is (harness-subagent-context-limit)")
                     (harness-tools-agent-test-hints cid)))
      (should (eq 'hint (plist-get (car (harness-call 'session/nodes cid)) :kind)))
      (should-not (harness-tools-agent-test-hints sid)))
    ;; The number is the setting's, whatever the parent has used.
    (let* ((sid (harness-tools-agent-test-session))
           (harness-subagent-context-limit 90000))
      (harness-call 'session/usage-add sid '(:input 10 :output 40 :context 3020))
      (should (equal '("Context window capped at 90k tokens, as a sub-agent's is (harness-subagent-context-limit)")
                     (harness-tools-agent-test-hints (harness-tools-agent-test-spawn sid '(:prompt "hi"))))))))

(ert-deftest harness-tools-agent-spawn-says-the-cap-in-a-forks-transcript ()
  "A fork's hint has what it starts with and the cap on top, and comes after what it copied."
  (harness-tools-agent-test-with
    (let ((sid (harness-tools-agent-test-session)))
      (harness-test-await (harness-call 'agent/prompt sid "hello there"))
      (harness-call 'session/usage-add sid '(:input 10 :output 40 :context 3020))
      (let* ((parent-nodes (harness-call 'session/nodes sid))
             (usage (plist-get (harness-call 'session/get sid) :usage))
             (inherited (+ (plist-get usage :context) (plist-get usage :last-output)))
             (cid (harness-tools-agent-test-spawn sid '(:prompt "carry on" :fork t)))
             (nodes (harness-call 'session/nodes cid)))
        (should (> inherited 0))
        (should (equal (list (format "Context window capped at %s tokens: the %s it starts with plus 256k of its own, as a sub-agent's is (harness-subagent-context-limit)"
                                     (harness-format-tokens (+ 256000 inherited))
                                     (harness-format-tokens inherited)))
                       (harness-tools-agent-test-hints cid)))
        ;; It follows the parent's nodes the fork copied and comes before the prompt.
        (should (eq 'hint (plist-get (nth (length parent-nodes) nodes) :kind)))
        (should (eq 'user (plist-get (nth (1+ (length parent-nodes)) nodes) :kind)))
        (should-not (harness-tools-agent-test-hints sid))))
    ;; The parent's own limit still bounds it, and the hint says so.
    (let ((sid (harness-tools-agent-test-session)))
      (harness-call 'session/update sid :context-window-limit 60000 :silent t)
      (harness-test-await (harness-call 'agent/prompt sid "hello there"))
      (should (equal '("Context window capped at 60k tokens, as a sub-agent's is (harness-subagent-context-limit), and no higher than the limit of the session that started it")
                     (harness-tools-agent-test-hints
                      (harness-tools-agent-test-spawn sid '(:prompt "carry on" :fork t))))))))

(ert-deftest harness-tools-agent-spawn-says-nothing-when-there-is-no-cap ()
  "Without a cap, a fresh child and a fork get no hint."
  (harness-tools-agent-test-with
    (let* ((harness-subagent-context-limit nil)
           (sid (harness-tools-agent-test-session)))
      (harness-test-await (harness-call 'agent/prompt sid "hello there"))
      (dolist (fork '(nil t))
        (let ((cid (harness-tools-agent-test-spawn sid (list :prompt "hi" :fork fork))))
          (ert-info ((format "fork %s" fork))
            (should-not (harness-tools-agent-test-hints cid))
            (should-not (cl-find 'hint (harness-call 'session/nodes cid)
                                 :key (lambda (n) (plist-get n :kind)))))))
      ;; A fresh child starts with the prompt, as it always did.
      (let ((cid (harness-tools-agent-test-spawn sid '(:prompt "hi"))))
        (should (eq 'user (plist-get (car (harness-call 'session/nodes cid)) :kind)))))))

(ert-deftest harness-tools-agent-spawn-goes-on-when-the-hint-cannot-be-added ()
  "A hint is a courtesy: a child whose hint fails still runs and answers."
  (harness-tools-agent-test-with
    (let ((sid (harness-tools-agent-test-session)))
      (harness-register-method 'session/hint (lambda (&rest _) (error "No hints today")))
      (let ((result (harness-test-await (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "hi")))))
        (should-not (plist-get result :is-error))
        (should (string-match-p "sub-agent session" (plist-get result :content)))))))

;;;; Running several sub-agents at once

(defun harness-tools-agent-test-reports (sid)
  "Return the background sub-agent report nodes of SID, oldest first."
  (cl-remove-if-not
   (lambda (node)
     (and (eq (plist-get node :kind) 'user)
          (equal '(:kind system :source "sub-agent") (harness-node-sender node))))
   (harness-call 'session/nodes sid)))

(ert-deftest harness-tools-agent-spawn-background-returns-at-once ()
  "A background spawn returns while the child runs.
The child's answer is reported to the parent later, in a message of the
harness's own."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (harness-provider-demo--delay 0.1)
           (result (harness-test-await
                    (harness-tools-agent-test-run
                     sid "spawn_agent"
                     '(:prompt "give me the tour" :name "explorer" :background t))))
           (cid (plist-get (plist-get result :meta) :child-id)))
      (should-not (plist-get result :is-error))
      (should cid)
      (should (string-match-p "started in the background" (plist-get result :content)))
      (should (string-match-p "explorer" (plist-get result :content)))
      (should (string-match-p (regexp-quote cid) (plist-get result :content)))
      (should (eq 'subagent (plist-get (harness-call 'session/get cid) :kind)))
      (should (equal sid (plist-get (harness-call 'session/get cid) :parent-id)))
      ;; The call is over while the child still works, and the parent
      ;; counts it as work it has outstanding.
      (harness-test-wait (lambda () (eq 'running (plist-get (harness-call 'session/get cid) :status)))
                         5 "the background child to run")
      (should (string-match-p "Sub-agent explorer running"
                              (harness-call 'agent/outstanding sid)))
      ;; Its answer comes later, as one message of the harness's own.
      (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 15 "the sub-agent report")
      (let ((reports (harness-tools-agent-test-reports sid)))
        (should (= 1 (length reports)))
        (should (string-match-p (format "Sub-agent report: explorer (session %s) finished\\."
                                        (regexp-quote cid))
                                (plist-get (car reports) :content)))
        (should (string-match-p "# Tour" (plist-get (car reports) :content)))
        (should (string-match-p ", cost \\$" (plist-get (car reports) :content))))
      (should-not (harness-call 'agent/outstanding sid)))))

(ert-deftest harness-tools-agent-spawn-background-two-at-once ()
  "Two background sub-agents run at the same time, and each one reports."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (harness-provider-demo--delay 0.15)
           (a (harness-test-await
               (harness-tools-agent-test-run sid "spawn_agent"
                                             '(:prompt "first job" :name "first" :background t))))
           (aid (plist-get (plist-get a :meta) :child-id)))
      (should-not (plist-get a :is-error))
      (should aid)
      (harness-test-wait (lambda () (eq 'running (plist-get (harness-call 'session/get aid) :status)))
                         5 "the first child to run")
      (let* ((b (harness-test-await
                 (harness-tools-agent-test-run sid "spawn_agent"
                                               '(:prompt "second job" :name "second" :background t))))
             (bid (plist-get (plist-get b :meta) :child-id)))
        (should-not (plist-get b :is-error))
        (should bid)
        (harness-test-wait (lambda () (and (harness-call 'agent/running aid)
                                           (harness-call 'agent/running bid)))
                           5 "both children to run at once")
        (let ((out (harness-call 'agent/outstanding sid)))
          (should (string-match-p "\\`Sub-agents " out))
          (should (string-match-p "first" out))
          (should (string-match-p "second" out)))
        (harness-test-wait (lambda () (= 2 (length (harness-tools-agent-test-reports sid))))
                           15 "both reports")
        (let ((reports (harness-tools-agent-test-reports sid)))
          (should (cl-some (lambda (n) (and (string-match-p (regexp-quote aid) (plist-get n :content))
                                            (string-match-p "first job" (plist-get n :content))))
                           reports))
          (should (cl-some (lambda (n) (and (string-match-p (regexp-quote bid) (plist-get n :content))
                                            (string-match-p "second job" (plist-get n :content))))
                           reports))
          (dolist (n reports)
            (should (string-match-p ", cost \\$" (plist-get n :content)))))
        (should-not (harness-call 'agent/outstanding sid))))))

(ert-deftest harness-tools-agent-spawn-background-failure-is-reported ()
  "A background child that fails is reported as stopped, not as an answer."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (harness-provider-demo--delay 0.02)
           (harness-provider-demo-script-override
            (lambda (request)
              (if (eq 'subagent (plist-get (plist-get request :session) :kind))
                  '((:type text :delta "starting") (:type done :stop-reason error :error "boom"))
                (let ((harness-provider-demo-script-override nil))
                  (harness-provider-demo--script request)))))
           (result (harness-test-await
                    (harness-tools-agent-test-run sid "spawn_agent"
                                                  '(:prompt "doomed" :name "doomed" :background t))))
           (cid (plist-get (plist-get result :meta) :child-id)))
      (should-not (plist-get result :is-error))
      (should cid)
      (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 10 "the failure report")
      (let ((content (plist-get (car (harness-tools-agent-test-reports sid)) :content)))
        (should (string-match-p "stopped" content))
        (should (string-match-p "boom" content))
        (should (string-match-p (regexp-quote cid) content))))))

(ert-deftest harness-tools-agent-child-report-text-names-worktree-and-cuts ()
  "The report of a child that stopped names where it worked.
A long answer is cut in the middle, pointing at the child's session."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (result (harness-test-await (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "hi"))))
           (cid (plist-get (plist-get result :meta) :child-id))
           (entry (list :parent sid :name "kid" :worktree "/tmp/kid" :branch "harness/kid")))
      (let ((text (harness-tools-agent--child-report-text cid entry '(:stop-reason cancelled))))
        (should (string-match-p (format "Sub-agent report: kid (session %s) stopped: its turn was cancelled\\."
                                        (regexp-quote cid))
                                text))
        (should (string-match-p "It worked in worktree /tmp/kid on branch harness/kid" text)))
      (let ((harness-tools-max-output-chars 40))
        (should (string-match-p "session_read on .* shows the rest"
                                (harness-tools-agent--child-report-text cid entry '(:stop-reason end-turn))))))))

;;;; Two spawn_agent calls in one step, against a strict server

(defvar harness-tools-agent-test--parallel-bodies nil
  "The chat completion bodies the parallel-spawn strict server got, newest first.")

(defun harness-tools-agent-test--parallel-reply (body)
  "Return (STATUS . BODY-TEXT), this strict server's answer for BODY.
The first request gets two spawn_agent calls in one assistant message;
the request that carries their results gets a closing answer."
  (let* ((messages (plist-get body :messages))
         (last (car (last messages)))
         (text (lambda (s)
                 (harness-tools-agent-test--sse
                  (list :choices (list (list :index 0 :delta (list :content s) :finish_reason "stop")))
                  "[DONE]")))
         (err (harness-tools-agent-test--strict-error messages)))
    (cond
     (err (cons 400 (harness-json-encode (list :error (list :message err :type "invalid_request_error")))))
     ((equal (plist-get last :role) "tool")
      (cons 200 (funcall text "Both sub-agents reported back.")))
     (t (cons 200 (harness-tools-agent-test--sse
                   (list :choices
                         (list (list :index 0
                                     :delta (list :tool_calls
                                                  (list (list :index 0 :id "call_a" :type "function"
                                                              :function (list :name "spawn_agent"
                                                                              :arguments "{\"prompt\":\"first job\",\"name\":\"first\",\"model\":\"demo:scripted\"}"))
                                                        (list :index 1 :id "call_b" :type "function"
                                                              :function (list :name "spawn_agent"
                                                                              :arguments "{\"prompt\":\"second job\",\"name\":\"second\",\"model\":\"demo:scripted\"}"))))
                                           :finish_reason "tool_calls")))
                   "[DONE]"))))))

(defun harness-tools-agent-test--parallel-request (url &rest args)
  "Answer the request to URL with ARGS as the parallel-spawn server would, soon.
Chat completion bodies are recorded in `harness-tools-agent-test--parallel-bodies'."
  (let ((handle (make-harness-http-handle :url url :callback (plist-get args :callback)
                                          :on-chunk (plist-get args :on-chunk) :started (float-time))))
    (harness-run-soon
     (lambda ()
       (unless (harness-http-handle-cancelled handle)
         (pcase-let ((`(,status . ,text)
                      (if (string-match-p "/models\\'" url)
                          (cons 200 "{\"data\":[]}")
                        (push (plist-get args :json) harness-tools-agent-test--parallel-bodies)
                        (harness-tools-agent-test--parallel-reply (plist-get args :json)))))
           (when (plist-get args :on-headers) (funcall (plist-get args :on-headers) status nil))
           (if (plist-get args :on-chunk)
               (progn (funcall (plist-get args :on-chunk) text)
                      (funcall (plist-get args :callback) status nil "" nil))
             (funcall (plist-get args :callback) status nil text nil))))))
    handle))

(ert-deftest harness-tools-agent-spawn-two-blocking-calls-in-one-step ()
  "Two spawn_agent calls made in one step run their children at once."
  (harness-tools-agent-test-with
    (let ((harness-tools-agent-test--parallel-bodies nil))
      (unwind-protect
          (cl-letf (((symbol-function 'harness-http-request) #'harness-tools-agent-test--parallel-request))
            (harness-openai-register-endpoint harness-tools-agent-test--strict-endpoint)
            (let* ((sid (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir)
                                                 :model "teststrict:deepseek-flash")
                                   :id))
                   (harness-provider-demo--delay 0.15)
                   (running (make-hash-table :test 'equal))
                   (both nil)
                   (watch (harness-on
                           'session/status
                           (lambda (id status)
                             (let ((child (ignore-errors
                                           (plist-get (harness-call 'session/get id) :parent-id))))
                               (when (equal sid child)
                                 (if (eq status 'running)
                                     (progn
                                       (puthash id t running)
                                       (when (>= (hash-table-count running) 2)
                                         (setq both t)))
                                   (remhash id running))))))))
              (unwind-protect
                  (let ((turn (harness-test-await (harness-call 'agent/prompt sid "delegate two things") 30)))
                    (should (eq 'end-turn (plist-get turn :stop-reason)))
                    ;; Both children ran before either had finished.
                    (should both)
                    (should (= 2 (length (harness-call 'session/list (list :parent-id sid)))))
                    (let ((results (cl-remove-if-not
                                    (lambda (n) (eq (plist-get n :kind) 'tool-result))
                                    (harness-call 'session/nodes sid))))
                      (should (equal '("call_a" "call_b")
                                     (sort (mapcar (lambda (n) (plist-get n :call-id)) results) #'string<)))
                      (dolist (r results)
                        (should-not (plist-get r :is-error))
                        (should (plist-get (plist-get r :meta) :child-id))))
                    ;; The two requests the strict server saw were both valid.
                    (should (= 2 (length harness-tools-agent-test--parallel-bodies)))
                    (dolist (body harness-tools-agent-test--parallel-bodies)
                      (should-not (harness-tools-agent-test--strict-error (plist-get body :messages)))))
                (harness-off watch))))
        (harness-provider-unregister 'teststrict)))))

(provide 'harness-tools-agent-test)
;;; harness-tools-agent-test.el ends here
