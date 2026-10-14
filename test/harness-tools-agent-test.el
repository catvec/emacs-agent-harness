;;; harness-tools-agent-test.el --- Tests for spawn_agent and the Planning section  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(defvar harness-provider-demo--delay)
(defvar harness-provider-demo-script-override)
(defvar harness-agent--cancel-grace)
(defvar harness-tools-agent-planning-section)
(defvar harness-tools-agent--children)
(defvar harness-tools--watchers)
(declare-function harness-provider-demo--last-user-text "harness-provider-demo")

(defmacro harness-tools-agent-test-with (&rest body)
  "Load the state layer with the demo provider and spawn_agent, run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config provider provider-demo tools session agent tools-agent tools-question priority))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-agent--turns)
     (let ((harness-provider-demo--delay 0.005)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       ,@body)))

(defun harness-tools-agent-test-session ()
  "Create a demo session and return its id."
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))

(defun harness-tools-agent-test-run (sid name input &optional call-id)
  "Execute tool NAME with INPUT in SID; return the promise.
CALL-ID, when given, is the call's id: the one a call node the session
recorded for it carries.  Otherwise the call gets a fresh one."
  (harness-call 'tools/execute sid (list :id (or call-id (harness-short-id)) :name name :input input)))

(defun harness-tools-agent-test-kinds (id)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

(ert-deftest harness-tools-agent-registers-tools ()
  (harness-tools-agent-test-with
    (should (harness-call 'tools/get "spawn_agent"))))

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
      (should (string-match-p "never blocks" prompt))
      (should (string-match-p "message of its own" prompt))
      (should (string-match-p "same step run at once" prompt))
      (should (string-match-p "`plan` tool" prompt)))
    ;; The same section reaches the provider through the agent.
    (let ((sid (harness-tools-agent-test-session)) (seen nil))
      (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                 ((symbol-function 'harness-method/provider/complete)
                  (lambda (req) (setq seen (plist-get req :system)) (funcall orig req))))
        (harness-test-await (harness-call 'agent/prompt sid "hello")))
      (should (string-match-p "## Planning" seen)))))

(ert-deftest harness-tools-agent-spawn-fresh-child ()
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (spawned nil))
      (harness-on 'agent/spawned (lambda (p c) (push (cons p c) spawned)))
      (let* ((result (harness-test-await
                      (harness-tools-agent-test-run sid "spawn_agent"
                                                    '(:prompt "give me the tour" :name "explorer"))))
             (cid (plist-get (plist-get result :meta) :child-id)))
        (should-not (plist-get result :is-error))
        ;; The call returns at once, naming the child; the answer comes
        ;; later, in a report of the harness's own.
        (should (string-match-p (regexp-quote cid) (plist-get result :content)))
        (should (string-match-p "runs in the background" (plist-get result :content)))
        (let ((child (harness-call 'session/get cid)))
          (should (equal (list (cons sid cid)) spawned))
          (should (equal sid (plist-get child :parent-id)))
          (should (eq 'subagent (plist-get child :kind)))
          (should (equal "explorer" (plist-get child :name)))
          (should (equal "demo:scripted" (plist-get child :model)))
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
          ;; The parent lists it as a child, and its answer reaches the
          ;; parent in a message of the harness's.
          (should (equal (list cid) (mapcar (lambda (s) (plist-get s :id))
                                            (harness-call 'session/list (list :parent-id sid)))))
          (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 15 "the report")
          (let ((report (plist-get (car (harness-tools-agent-test-reports sid)) :content)))
            (should (string-match-p "# Tour" report))
            (should (string-match-p "\\[sub-agent session: [-0-9a-f]+, 1 tool calls, cost \\$" report)))
          (should (eq 'idle (plist-get (harness-call 'session/get cid) :status))))))))

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
        ;; The call returns at once, naming the child.
        (should (string-match-p "started (session" (plist-get result :content)))
        (should (eq 'subagent (plist-get child :kind)))
        (should (equal sid (plist-get child :parent-id)))
        (should (equal (plist-get (car (last parent-nodes)) :id) (plist-get child :fork-node)))
        ;; The child's transcript starts with the parent's nodes, same ids.
        (should (equal (mapcar (lambda (n) (plist-get n :id)) parent-nodes)
                       (mapcar (lambda (n) (plist-get n :id)) (seq-take child-nodes (length parent-nodes)))))
        (should (> (length child-nodes) (length parent-nodes)))
        ;; Its new message is the parent's, and holds its prompt; the
        ;; copied one stays the user's.
        (should-not (harness-node-sender (car child-nodes)))
        (let ((new (cl-find 'user (nthcdr (length parent-nodes) child-nodes)
                            :key (lambda (n) (plist-get n :kind)))))
          (should (string-match-p "carry on" (plist-get new :content)))
          (should (equal sid (plist-get (harness-node-sender new) :id))))
        ;; The parent's own transcript keeps its nodes: the child's turn
        ;; writes to it only through the report it sends.
        (should (equal (mapcar (lambda (n) (plist-get n :id)) parent-nodes)
                       (mapcar (lambda (n) (plist-get n :id))
                               (seq-take (harness-call 'session/nodes sid) (length parent-nodes)))))))))

(ert-deftest harness-tools-agent-spawn-needs-a-prompt ()
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (result (harness-test-await (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "  ")))))
      (should (plist-get result :is-error))
      (should (string-match-p "needs a prompt" (plist-get result :content))))))

(ert-deftest harness-tools-agent-spawn-priority ()
  "The spawn_agent tool gives the child session a priority of its own.
A level no level has is refused before any child is made; without the
option the child works at what it inherits."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (children (lambda () (harness-call 'session/list (list :parent-id sid))))
           (spawn (lambda (&rest plist)
                    (plist-get (plist-get (harness-test-await
                                           (harness-tools-agent-test-run
                                            sid "spawn_agent"
                                            (append '(:prompt "hi" :name "kid") plist)))
                                          :meta)
                               :child-id))))
      ;; The parent works at high; a child without a priority of its own
      ;; inherits it (see `harness-priority-session').
      (harness-call 'priority/set sid "high")
      (let ((cid (funcall spawn)))
        (should (eq 'high (harness-priority-of cid)))
        (should-not (harness-priority-of-ext (plist-get (harness-call 'session/get cid) :ext))))
      ;; Its own, whatever the parent works at, in any case.
      (let ((cid (funcall spawn :priority "LOW")))
        (should (eq 'low (harness-priority-of cid)))
        (should (eq 'low (harness-priority-of-ext (plist-get (harness-call 'session/get cid) :ext)))))
      ;; A level no level has is refused, and no child is made.
      (let ((r (harness-test-await (harness-tools-agent-test-run sid "spawn_agent"
                                                                 '(:prompt "hi" :priority "urgent")))))
        (should (plist-get r :is-error))
        (should (string-match-p "Unknown priority" (plist-get r :content))))
      (should (= 2 (length (funcall children)))))))

;;;; The thinking level of a sub-agent

(defvar harness-providers)

(defmacro harness-tools-agent-test-with-thinker (&rest body)
  "Run BODY in `harness-tools-agent-test-with' with a provider `test-think'.
Its model `thinker' offers the thinking levels low, medium and high; its
model `plain' offers none."
  (declare (indent 0))
  `(harness-tools-agent-test-with
     (unwind-protect
         (progn
           (harness-define-provider 'test-think
             :complete #'ignore
             :models (lambda ()
                       (harness-resolved (list (list :name "thinker" :thinking-levels '("low" "medium" "high"))
                                               (list :name "plain")))))
           ,@body)
       (remhash 'test-think harness-providers)
       (harness-provider--forget 'test-think))))

(defun harness-tools-agent-test-thinking (sid level)
  "Give SID the thinking level LEVEL, with no hint."
  (harness-call 'session/update sid :thinking level :silent t))

(defun harness-tools-agent-test-spawned (sid input)
  "Spawn INPUT in SID, and return the child session plist."
  (harness-call 'session/get (harness-tools-agent-test-spawn sid input)))

(ert-deftest harness-tools-agent-spawn-child-thinks-at-its-parents-level ()
  "Without `:thinking' a child thinks at its parent's level, fresh and forked."
  (harness-tools-agent-test-with
    (let ((sid (harness-tools-agent-test-session)))
      (harness-tools-agent-test-thinking sid "high")
      (should (equal "high" (plist-get (harness-tools-agent-test-spawned sid '(:prompt "hi")) :thinking)))
      (should (equal "high" (plist-get (harness-tools-agent-test-spawned
                                        sid '(:prompt "carry on" :fork t))
                                       :thinking)))
      (should (equal "high" (plist-get (harness-call 'session/get sid) :thinking))))))

(ert-deftest harness-tools-agent-spawn-child-thinks-at-the-level-it-is-asked-for ()
  "An explicit `:thinking' is the child's level, fresh and forked, and
the fork's is the level it was asked for rather than its parent's."
  (harness-tools-agent-test-with
    (let ((sid (harness-tools-agent-test-session)))
      (harness-tools-agent-test-thinking sid "low")
      (let ((fresh (harness-tools-agent-test-spawned sid '(:prompt "hi" :thinking "high"))))
        (should (eq 'subagent (plist-get fresh :kind)))
        (should (equal "high" (plist-get fresh :thinking))))
      (let ((forked (harness-tools-agent-test-spawned
                     sid '(:prompt "carry on" :fork t :thinking "high"))))
        (should (equal "high" (plist-get forked :thinking)))
        ;; The fork shares the parent's conversation, its own thinking aside.
        (should (equal (plist-get (harness-call 'session/get sid) :id)
                       (plist-get forked :parent-id))))
      ;; The parent keeps the level it had.
      (should (equal "low" (plist-get (harness-call 'session/get sid) :thinking))))))

(ert-deftest harness-tools-agent-spawn-thinking-is-checked-against-the-childs-model ()
  "A level is checked against the model the child will run on: the
parent's, or the `:model' the call gives it."
  (harness-tools-agent-test-with-thinker
    (let ((sid (harness-tools-agent-test-session)))
      (harness-tools-agent-test-thinking sid "high")
      ;; The child's model offers the level, the parent's does not.
      (let ((child (harness-tools-agent-test-spawned
                    sid '(:prompt "hi" :model "test-think:thinker" :thinking "medium"))))
        (should (equal "test-think:thinker" (plist-get child :model)))
        (should (equal "medium" (plist-get child :thinking))))
      ;; A fork on another model takes the level the same way.
      (let ((child (harness-tools-agent-test-spawned
                    sid '(:prompt "carry on" :fork t :model "test-think:thinker"
                          :thinking "medium"))))
        (should (equal "test-think:thinker" (plist-get child :model)))
        (should (equal "medium" (plist-get child :thinking))))
      ;; Without a level the parent's stands, even one the child's model
      ;; does not list: only a level the call asked for is checked.
      (let ((child (harness-tools-agent-test-spawned
                    sid '(:prompt "hi" :model "test-think:plain"))))
        (should (equal "test-think:plain" (plist-get child :model)))
        (should (equal "high" (plist-get child :thinking)))))))

(ert-deftest harness-tools-agent-spawn-refuses-a-thinking-level-the-model-lacks ()
  "A level the child's model does not offer fails the call, naming the
levels it does, and no child starts."
  (harness-tools-agent-test-with-thinker
    (let* ((sid (harness-tools-agent-test-session))
           (try (lambda (input)
                  (harness-test-await (harness-tools-agent-test-run sid "spawn_agent" input)))))
      ;; The demo model offers low and high, not medium.
      (let ((result (funcall try '(:prompt "hi" :thinking "medium"))))
        (should (plist-get result :is-error))
        (should (string-match-p "Model demo:scripted does not offer the thinking level medium"
                                (plist-get result :content)))
        (should (string-match-p "it offers low, high" (plist-get result :content)))
        (should (string-match-p "Leave :thinking out" (plist-get result :content))))
      ;; A fork is refused the same way.
      (should (plist-get (funcall try '(:prompt "hi" :fork t :thinking "max")) :is-error))
      ;; A model the catalogue gives no levels at all.
      (let ((result (funcall try '(:prompt "hi" :model "test-think:plain" :thinking "low"))))
        (should (plist-get result :is-error))
        (should (string-match-p "Model test-think:plain does not offer the thinking level low"
                                (plist-get result :content)))
        (should (string-match-p "it offers none" (plist-get result :content))))
      ;; The model the check names is the child's, `:model' included: this
      ;; level is one the parent's model lists.
      (let ((result (funcall try '(:prompt "hi" :model "test-think:thinker" :thinking "max"))))
        (should (plist-get result :is-error))
        (should (string-match-p "Model test-think:thinker does not offer the thinking level max"
                                (plist-get result :content))))
      (should-not (harness-call 'session/list (list :parent-id sid)))
      (should-not (harness-call 'agent/outstanding sid)))))

(defun harness-tools-agent-test-record-call (sid call-id input)
  "Record a spawn_agent call CALL-ID with INPUT in SID, as the agent does."
  (harness-call 'session/append sid
                (list :kind 'tool-call :tool "spawn_agent" :call-id call-id
                      :title (harness-tool-title "spawn_agent" input)
                      :input input
                      :meta (list :model (plist-get (harness-call 'session/get sid) :model)))))

(ert-deftest harness-tools-agent-spawn-names-the-child-on-its-call ()
  "The spawn_agent call links its sub-agent from the moment it exists,
not only once the call returns and its result names the child.  The
call's own meta -- the model -- is kept."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (call-id "call-1")
           (input '(:prompt "give me the tour" :name "explorer")))
      (harness-tools-agent-test-record-call sid call-id input)
      (let ((harness-provider-demo--delay 0.1)
            (p (harness-tools-agent-test-run sid "spawn_agent" input call-id)))
        ;; While the call runs the child exists, and the call names it.
        (harness-test-wait (lambda () (harness-call 'session/list (list :parent-id sid)))
                           5 "the child session")
        (let* ((cid (plist-get (car (harness-call 'session/list (list :parent-id sid))) :id))
               (node (harness-tools-agent--call-node sid call-id)))
          (should (stringp cid))
          (should (equal cid (plist-get (plist-get node :meta) :child-id)))
          (should (equal "demo:scripted" (plist-get (plist-get node :meta) :model)))
          (should-not (plist-get (plist-get node :meta) :from)))
        (let* ((result (harness-test-await p))
               (result-cid (plist-get (plist-get result :meta) :child-id)))
          (should-not (plist-get result :is-error))
          (should (stringp result-cid))
          (should (equal result-cid
                         (plist-get (plist-get (harness-tools-agent--call-node sid call-id) :meta)
                                    :child-id))))))))

(ert-deftest harness-tools-agent-spawn-names-its-child-on-a-call-that-failed ()
  "A call whose child could not finish still names the child it created,
so the chat can open it from the call however the call ended."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (call-id "call-2")
           (input '(:prompt "hi" :name "doomed")))
      (harness-tools-agent-test-record-call sid call-id input)
      ;; Only the sub-agent fails; the parent still hears its report.
      (let ((harness-provider-demo-script-override
             (lambda (request)
               (if (eq 'subagent (plist-get (plist-get request :session) :kind))
                   '((:type done :stop-reason error :error "boom"))
                 (let ((harness-provider-demo-script-override nil))
                   (harness-provider-demo--script request))))))
        (let* ((result (harness-test-await (harness-tools-agent-test-run sid "spawn_agent" input call-id)))
               (cid (plist-get (plist-get result :meta) :child-id))
               (node (harness-tools-agent--call-node sid call-id)))
          ;; The call returned while the child ran, and it names the child.
          (should-not (plist-get result :is-error))
          (should (stringp cid))
          (should (equal cid (plist-get (plist-get node :meta) :child-id)))
          ;; The child's first turn fails; the call goes on naming it.
          (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 10 "the failure report")
          (should (string-match-p "boom"
                                  (plist-get (car (harness-tools-agent-test-reports sid)) :content)))
          (should (equal cid (plist-get (plist-get (harness-tools-agent--call-node sid call-id) :meta)
                                        :child-id))))))))

(ert-deftest harness-tools-agent-no-call-node-nothing-to-name ()
  "A spawn run without a call node -- `tools/execute' from outside an
agent turn -- runs as it always did: there is no call to name."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (result (harness-test-await (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "hi")))))
      (should-not (plist-get result :is-error))
      (should (stringp (plist-get (plist-get result :meta) :child-id)))
      (should-not (cl-find-if (lambda (n) (eq (plist-get n :kind) 'tool-call))
                              (harness-call 'session/nodes sid))))))

(ert-deftest harness-tools-agent-spawn-note-shows-the-child ()
  "The notes of a spawn_agent call say what the child is doing.
The call returns as soon as the child starts; while the child works,
the note under it is made of the child -- its tool call, the tokens it
holds against its window, and what it has done -- and stops when the
child is reported."
  (harness-tools-agent-test-with
    (harness-test-load-module 'tools-shell)
    (let* ((sid (harness-tools-agent-test-session))
           (notes nil))
      (harness-on 'tools/note (lambda (_s _c text) (push text notes)))
      (let ((harness-provider-demo-script-override
             (lambda (_request)
               `((:type text :delta "The child works.\n")
                 (:type tool-call :id "c1" :name "bash"
                        :input (:command "sleep 0.3; echo child done"))
                 (:type usage :input 900 :output 60 :context 12300)
                 (:type done :stop-reason end-turn)))))
        (let* ((result (harness-test-await
                        (harness-tools-agent-test-run sid "spawn_agent"
                                                      '(:prompt "child work" :name "helper"))))
               (cid (plist-get (plist-get result :meta) :child-id)))
          (should-not (plist-get result :is-error))
          ;; The call returns at once, and the child works on.
          (should (string-match-p "runs in the background" (plist-get result :content)))
          (harness-test-wait (lambda () (not (gethash cid harness-tools-agent--children)))
                             10 "the child's report")
          ;; The child's session is the one the notes are about: its
          ;; command ran there.
          (should (cl-some (lambda (node) (string-match-p "child done" (or (plist-get node :output) "")))
                           (harness-call 'session/nodes cid)))
          ;; It starts with the child starting...
          (should (cl-some (lambda (n) (string-prefix-p "starting" n)) notes))
          ;; ... shows the call it runs...
          (should (cl-some (lambda (n) (string-match-p "running Bash: sleep 0.3" n)) notes))
          ;; ... counts its tool call and its tokens against the window
          ;; it compacts at.
          (should (cl-some (lambda (n) (string-match-p "1 tool call" n)) notes))
          (should (cl-some (lambda (n) (string-match-p "before compact" n)) notes))
          ;; Nothing is watched once the child has been reported: the
          ;; note does not keep a session alive, and no more of it is made.
          (should-not (gethash cid harness-tools--watchers))
          (let ((before (length notes)))
            (harness-emit 'agent/activity-changed cid nil)
            (should (= before (length notes)))))))))

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
     ((string-match-p "Sub-agent report" (harness-tools-agent-test--text-of last))
      (cons 200 (funcall text "Noted.")))
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
              ;; The spawn returned at once, naming the child for the chat
              ;; to link; the fork's finding arrives later as a report.
              (should-not (plist-get result :is-error))
              (should (equal cid (plist-get (plist-get result :meta) :child-id)))
              ;; And so does the call itself, from the moment the child
              ;; exists: the chat links it while the call still runs.
              (let ((call (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'tool-call)
                                                       (equal (plist-get n :call-id) "call_spawn")))
                                      (harness-call 'session/nodes sid))))
                (should (equal cid (plist-get (plist-get call :meta) :child-id))))
              (should (string-match-p "started (session" (plist-get result :output)))
              (should (eq 'subagent (plist-get (harness-call 'session/get cid) :kind)))
              (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 20 "the fork's report")
              (should (string-match-p "Found it"
                                      (plist-get (car (harness-tools-agent-test-reports sid)) :content)))
              ;; Every request was a valid one: the fork answered the
              ;; copied call itself before its task.
              (dolist (body bodies)
                (should-not (harness-tools-agent-test--strict-error (plist-get body :messages))))
              ;; The sub-agent's request: the parent's transcript, the call
              ;; that forked it answered, then its task.
              (let* ((body (cl-find-if (lambda (b)
                                         (cl-some (lambda (m)
                                                    (equal "investigate the bug"
                                                           (harness-tools-agent-test--text-of m)))
                                                  (plist-get b :messages)))
                                       bodies))
                     (messages (cdr (plist-get body :messages))) ; after the system prompt
                     (tool (cl-find "tool" messages :key (lambda (m) (plist-get m :role)) :test #'equal)))
                (should body)
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
  "A hint is a courtesy: a child whose hint fails still starts and answers."
  (harness-tools-agent-test-with
    (let ((sid (harness-tools-agent-test-session)))
      (harness-register-method 'session/hint (lambda (&rest _) (error "No hints today")))
      (let* ((result (harness-test-await (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "hi"))))
             (cid (plist-get (plist-get result :meta) :child-id)))
        (should-not (plist-get result :is-error))
        (should cid)
        (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 15 "the report")
        (should (string-match-p "sub-agent session" (plist-get (car (harness-tools-agent-test-reports sid)) :content)))))))

;;;; Running several sub-agents at once

(defun harness-tools-agent-test-reports (sid)
  "Return the sub-agent report nodes of SID, oldest first."
  (cl-remove-if-not
   (lambda (node)
     (and (eq (plist-get node :kind) 'user)
          (equal '(:kind system :source "sub-agent") (harness-node-sender node))))
   (harness-call 'session/nodes sid)))

(ert-deftest harness-tools-agent-spawn-returns-at-once ()
  "A spawn returns while the child runs, whatever the call asks for.
The child's answer is reported to the parent later, in a message of the
harness's own; a spawn never blocks the conversation."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (harness-provider-demo--delay 0.1)
           (result (harness-test-await
                    (harness-tools-agent-test-run
                     sid "spawn_agent"
                     '(:prompt "give me the tour" :name "explorer"))))
           (cid (plist-get (plist-get result :meta) :child-id)))
      (should-not (plist-get result :is-error))
      (should cid)
      (should (string-match-p "started (session" (plist-get result :content)))
      (should (string-match-p "runs in the background" (plist-get result :content)))
      (should (string-match-p "explorer" (plist-get result :content)))
      (should (string-match-p (regexp-quote cid) (plist-get result :content)))
      (should (eq 'subagent (plist-get (harness-call 'session/get cid) :kind)))
      (should (equal sid (plist-get (harness-call 'session/get cid) :parent-id)))
      ;; The call is over while the child still works, and the parent
      ;; counts it as work it has outstanding.
      (harness-test-wait (lambda () (eq 'running (plist-get (harness-call 'session/get cid) :status)))
                         5 "the child to run")
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

(ert-deftest harness-tools-agent-spawn-two-at-once ()
  "Two sub-agents run at the same time, and each one reports."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (harness-provider-demo--delay 0.15)
           (a (harness-test-await
               (harness-tools-agent-test-run sid "spawn_agent"
                                             '(:prompt "first job" :name "first"))))
           (aid (plist-get (plist-get a :meta) :child-id)))
      (should-not (plist-get a :is-error))
      (should aid)
      (harness-test-wait (lambda () (eq 'running (plist-get (harness-call 'session/get aid) :status)))
                         5 "the first child to run")
      (let* ((b (harness-test-await
                 (harness-tools-agent-test-run sid "spawn_agent"
                                               '(:prompt "second job" :name "second"))))
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

(ert-deftest harness-tools-agent-spawn-failure-is-reported ()
  "A child that fails is reported as stopped, not as an answer."
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
                                                  '(:prompt "doomed" :name "doomed"))))
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
Its branch comes back through the merge queue when the merge module
runs, else by hand.  A long answer is cut in the middle, pointing at the
child's session."
  (harness-tools-agent-test-with
    (let* ((sid (harness-tools-agent-test-session))
           (result (harness-test-await (harness-tools-agent-test-run sid "spawn_agent" '(:prompt "hi"))))
           (cid (plist-get (plist-get result :meta) :child-id))
           (entry (list :parent sid :name "kid" :worktree "/tmp/kid" :branch "harness/kid")))
      (let ((text (harness-tools-agent--child-report-text cid entry '(:stop-reason cancelled))))
        (should (string-match-p (format "Sub-agent report: kid (session %s) stopped: its turn was cancelled\\."
                                        (regexp-quote cid))
                                text))
        (should (string-match-p "It worked in worktree /tmp/kid on branch harness/kid" text))
        (should (string-match-p "no merge queue (the merge module), so the branch stays there" text)))
      (let ((exists (symbol-function 'harness-method-exists-p)))
        (cl-letf (((symbol-function 'harness-method-exists-p)
                   (lambda (method) (or (eq method 'merge/enqueue) (funcall exists method)))))
          (let ((text (harness-tools-agent--child-report-text cid entry '(:stop-reason end-turn))))
            (should (string-match-p "its branch merges back into this session's working directory" text))
            (should-not (string-match-p "no merge queue" text)))))
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

(ert-deftest harness-tools-agent-spawn-two-calls-in-one-step ()
  "Two spawn_agent calls made in one step run their children at once.
Each call returns at once (a spawn never blocks), so the children
overlap even though the model made the calls together."
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

;;;; A child in a worktree

(defun harness-tools-agent-test--git (dir &rest args)
  "Run git ARGS synchronously in DIR; signal on failure, return stdout."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string)))
      (buffer-string))))

(ert-deftest harness-tools-agent-spawn-worktree-reports-branch ()
  "A child in a worktree is reported with where it worked.
The worktree step of the call keeps the branch, which the report names."
  (harness-tools-agent-test-with
    (harness-test-load-module 'worktree)
    (let* ((base (harness-test-temp-dir))
           (root (file-name-as-directory (expand-file-name "repo" base))))
      (unwind-protect
          (progn
            (make-directory root t)
            (harness-tools-agent-test--git root "init" "-q" "-b" "main")
            (harness-tools-agent-test--git root "config" "user.name" "Harness Test")
            (harness-tools-agent-test--git root "config" "user.email" "test@example.invalid")
            (harness-tools-agent-test--git root "config" "commit.gpgsign" "false")
            (with-temp-file (expand-file-name "README" root) (insert "hello\n"))
            (harness-tools-agent-test--git root "add" "README")
            (harness-tools-agent-test--git root "commit" "-q" "-m" "initial")
            (let* ((sid (plist-get (harness-call 'session/create :cwd root
                                                            :model "demo:scripted")
                                   :id))
                   (result (harness-test-await
                            (harness-tools-agent-test-run
                             sid "spawn_agent"
                             '(:prompt "hi" :name "kid" :worktree t))))
                   (cid (plist-get (plist-get result :meta) :child-id))
                   (child (harness-call 'session/get cid)))
              (should-not (plist-get result :is-error))
              (should (plist-get child :worktree))
              (should (file-directory-p (plist-get child :worktree)))
              (harness-test-wait (lambda () (harness-tools-agent-test-reports sid))
                                 15 "the worktree child's report")
              (let ((report (plist-get (car (harness-tools-agent-test-reports sid)) :content)))
                (should (string-match-p "It worked in worktree" report))
                (should (string-match-p (regexp-quote (abbreviate-file-name (plist-get child :worktree)))
                                        report))
                (should (string-match-p "on branch harness/" report)))))
        (ignore-errors (delete-directory base t))))))

;;;; A sub-agent that registers a wait

(defvar harness-tools-agent-test--target nil
  "The session a sub-agent of the waiting-spawn test waits for.")

(defun harness-tools-agent-test--waiting-script (request)
  "Return the demo script of the waiting-spawn test for REQUEST.
The parent spawns a waiter; the waiter registers a session_wait on
`harness-tools-agent-test--target', ends its turn while it waits, is
woken when the target stops, answers, and only then is reported."
  (let ((text (downcase (harness-provider-demo--last-user-text request))))
    (cond
     ;; The waiter, woken by its wait: it is done.  This comes before the
     ;; target's own branch: the wake report cites the target's reply.
     ((string-match-p "done waiting" text)
      '((:type text :delta "all done") (:type done :stop-reason end-turn)))
     ;; The target stays busy long enough for the waiter to register its
     ;; wait on it (the parent spawns it, then the waiter's first call).
     ((string-match-p "long job" text)
      '((:type wait :seconds 2.5)
        (:type text :delta "the long job is done")
        (:type done :stop-reason end-turn)))
     ((string-match-p "sub-agent report" text)
      '((:type text :delta "noted") (:type done :stop-reason end-turn)))
     ((string-match-p "wait for the target" text)
      `((:type tool-call :id "demo-wait" :name "session_wait"
                         :input (:session_id ,harness-tools-agent-test--target))
        (:type text :delta "waiting for the target")
        (:type done :stop-reason end-turn)))
     ((string-match-p "delegate the waiting" text)
      `((:type tool-call :id "demo-spawn" :name "spawn_agent"
                         :input (:prompt "wait for the target" :name "waiter"))
        (:type text :delta "delegated")
        (:type done :stop-reason end-turn)))
     (t '((:type text :delta "ok") (:type done :stop-reason end-turn))))))

(ert-deftest harness-tools-agent-a-waiting-sub-agent-is-reported-when-it-is-done ()
  "A sub-agent that registered a wait is not reported when its turn ends.
It ends the turn while it waits, so the parent still counts it as work
outstanding; its report comes once the wait wakes it and its next turn
ends."
  (harness-tools-agent-test-with
    (harness-test-load-module 'tools-sessions)
    (let* ((harness-provider-demo-script-override #'harness-tools-agent-test--waiting-script)
           (target (harness-tools-agent-test-session)))
      (setq harness-tools-agent-test--target target)
      (setq harness-provider-demo--delay 0.5)
      (harness-call 'agent/prompt target "long job")
      (let* ((sid (harness-tools-agent-test-session))
             (turn (harness-test-await (harness-call 'agent/prompt sid "delegate the waiting") 30))
             (cid (plist-get (car (harness-call 'session/list (list :parent-id sid))) :id)))
        (should (eq 'end-turn (plist-get turn :stop-reason)))
        (should cid)
        ;; The waiter's turn ends while it waits for the target.
        (harness-test-wait (lambda () (and (not (harness-call 'agent/running cid))
                                           (eq 'idle (plist-get (harness-call 'session/get cid) :status))))
                           10 "the waiting sub-agent")
        ;; ... so it is not reported, and both sessions count it as work.
        (should-not (harness-tools-agent-test-reports sid))
        (should (string-match-p "Sub-agent waiter running" (harness-call 'agent/outstanding sid)))
        (should (string-match-p "Waiting on" (harness-call 'agent/outstanding cid)))
        ;; The target stops: the wait wakes the waiter, which answers, and
        ;; only then does the report reach the parent.
        (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 20 "the report")
        (should (string-match-p "all done"
                                (plist-get (car (harness-tools-agent-test-reports sid)) :content)))
        (should-not (harness-call 'agent/outstanding sid))))))

;;;; Stopping what a session runs outside its turn

(defun harness-tools-agent-test--stop-script (request)
  "Return the demo script of the stop-outstanding tests for REQUEST.
A \"long job\" runs on until its turn is cancelled; \"delegate the long
job\" starts one in a sub-agent of its own, named grandkid, and ends its
turn, while \"delegate and carry on\" starts it and runs on; \"ask me\"
blocks the turn on a question; anything else, a sub-agent's report say,
is answered at once."
  (let ((text (downcase (harness-provider-demo--last-user-text request))))
    (cond
     ((string-match-p "delegate the long job" text)
      '((:type tool-call :id "demo-spawn" :name "spawn_agent"
               :input (:prompt "long job" :name "grandkid"))
        (:type text :delta "delegated")
        (:type done :stop-reason end-turn)))
     ((string-match-p "delegate and carry on" text)
      '((:type tool-call :id "demo-spawn" :name "spawn_agent"
               :input (:prompt "long job" :name "grandkid"))
        (:type wait :seconds 30)
        (:type text :delta "all done")
        (:type done :stop-reason end-turn)))
     ((string-match-p "long job" text)
      '((:type wait :seconds 30)))
     ((string-match-p "ask me" text)
      '((:type tool-call :id "demo-ask" :name "ask_user"
               :input (:question "Which colour?" :options ("red" "green")))
        (:type text :delta "thanks")
        (:type done :stop-reason end-turn)))
     (t '((:type text :delta "ok") (:type done :stop-reason end-turn))))))

(ert-deftest harness-tools-agent-stop-outstanding-cancels-a-running-sub-agent ()
  "Stopping what a session runs outside its turn cancels its running sub-agent.
The session is told as for any cancelled sub-agent, with the reason it
was stopped for, and counts nothing outstanding once the child's turn
has ended.  With nothing running there is nothing to stop."
  (harness-tools-agent-test-with
    (let* ((harness-agent--cancel-grace 0.05)
           (harness-provider-demo-script-override #'harness-tools-agent-test--stop-script)
           (why "its task was returned to the queue")
           (sid (harness-tools-agent-test-session))
           (cid (harness-tools-agent-test-spawn sid '(:prompt "long job" :name "kid"))))
      (harness-test-wait (lambda () (eq 'running (plist-get (harness-call 'session/get cid) :status)))
                         5 "the child to run")
      (should (string-match-p "Sub-agent kid running" (harness-call 'agent/outstanding sid)))
      (should (equal "Sub-agent kid stopped" (harness-call 'agent/stop-outstanding sid why)))
      ;; Its turn is cancelled, and its session hears of that as of any
      ;; cancelled sub-agent, with why.
      (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 5 "the report")
      (should-not (harness-call 'agent/running cid))
      (let ((reports (harness-tools-agent-test-reports sid)))
        (should (= 1 (length reports)))
        (should (string-match-p
                 (format "\\`Sub-agent report: kid (session %s) stopped: its turn was cancelled (%s)\\."
                         (regexp-quote cid) (regexp-quote why))
                 (plist-get (car reports) :content))))
      ;; Nothing is outstanding any more, and nothing is left to stop.
      (should-not (harness-call 'agent/outstanding sid))
      (should-not (gethash cid harness-tools-agent--children))
      (should-not (harness-call 'agent/stop-outstanding sid why))
      (should-not (harness-call 'agent/stop-outstanding (harness-tools-agent-test-session) why)))))

(ert-deftest harness-tools-agent-stop-outstanding-stops-only-the-sessions-own-sub-agents ()
  "Every sub-agent of the session that still runs is stopped, and no one else's.
They are named in the order they were spawned; without a reason the
reports say none, and stopping again finds nothing."
  (harness-tools-agent-test-with
    (let* ((harness-agent--cancel-grace 0.05)
           (harness-provider-demo-script-override #'harness-tools-agent-test--stop-script)
           (sid (harness-tools-agent-test-session))
           (other (harness-tools-agent-test-session))
           (first (harness-tools-agent-test-spawn sid '(:prompt "long job" :name "first")))
           (second (harness-tools-agent-test-spawn sid '(:prompt "long job" :name "second")))
           (bystander (harness-tools-agent-test-spawn other '(:prompt "long job" :name "bystander"))))
      (harness-test-wait (lambda () (cl-every (lambda (id) (harness-call 'agent/running id))
                                              (list first second bystander)))
                         5 "the sub-agents to run")
      (should (equal "Sub-agents first, second stopped" (harness-call 'agent/stop-outstanding sid)))
      (harness-test-wait (lambda () (= 2 (length (harness-tools-agent-test-reports sid))))
                         5 "both reports")
      (dolist (report (harness-tools-agent-test-reports sid))
        (should (string-match-p "stopped: its turn was cancelled\\.\n" (plist-get report :content))))
      (should-not (harness-call 'agent/outstanding sid))
      (should-not (harness-call 'agent/stop-outstanding sid))
      ;; The other session's sub-agent was left alone.
      (should (harness-call 'agent/running bystander))
      (should (string-match-p "Sub-agent bystander running" (harness-call 'agent/outstanding other)))
      (harness-call 'agent/cancel bystander)
      (harness-test-wait (lambda () (harness-tools-agent-test-reports other)) 5 "the bystander's report"))))

(ert-deftest harness-tools-agent-stop-outstanding-does-not-stop-a-sub-agent-twice ()
  "A sub-agent whose cancelled turn is still ending is not stopped again.
One blocked on a question takes a moment to end its turn.  Meanwhile its
session still counts it, a second stop finds it stopped already and
says nothing, and it is reported once, when its turn has ended."
  (harness-tools-agent-test-with
    (let* ((harness-agent--cancel-grace 0.5)
           (harness-provider-demo-script-override #'harness-tools-agent-test--stop-script)
           (why "its task was returned to the queue")
           (sid (harness-tools-agent-test-session))
           (cid (harness-tools-agent-test-spawn sid '(:prompt "ask me" :name "kid"))))
      (harness-test-wait (lambda () (harness-call 'question/pending cid)) 5 "the question")
      (should (equal "Sub-agent kid stopped" (harness-call 'agent/stop-outstanding sid why)))
      (should (harness-call 'agent/running cid))
      (should (string-match-p "Sub-agent kid running" (harness-call 'agent/outstanding sid)))
      (should-not (harness-call 'agent/stop-outstanding sid why))
      ;; Once its turn has ended, it is reported, once.
      (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 5 "the report")
      (should-not (harness-call 'agent/running cid))
      (should (= 1 (length (harness-tools-agent-test-reports sid))))
      (should-not (harness-call 'agent/outstanding sid))
      (should-not (harness-call 'agent/stop-outstanding sid why)))))

(ert-deftest harness-tools-agent-stop-outstanding-stops-the-work-of-an-idle-sub-agent ()
  "A sub-agent whose turn ended with a sub-agent of its own at work is stopped with it.
It stays outstanding for its session while that one runs, though its
own turn is over.  The stop goes down to what it started, which is
cancelled; the sub-agent that started it hears so, with the reason, as
any session does.  The report wakes it, and that turn is cancelled as
the stop's own: once it has ended, its session hears it was stopped."
  (harness-tools-agent-test-with
    (let* ((harness-agent--cancel-grace 0.05)
           (harness-provider-demo-script-override #'harness-tools-agent-test--stop-script)
           (why "its task was returned to the queue")
           (sid (harness-tools-agent-test-session))
           (cid (harness-tools-agent-test-spawn sid '(:prompt "delegate the long job" :name "kid")))
           (gid nil))
      ;; The child ends its turn with its own sub-agent at work.
      (harness-test-wait (lambda ()
                           (and (not (harness-call 'agent/running cid))
                                (setq gid (plist-get (car (harness-call 'session/list (list :parent-id cid))) :id))
                                (harness-call 'agent/running gid)))
                         10 "the grandchild to run")
      (should (string-match-p "Sub-agent grandkid running" (harness-call 'agent/outstanding cid)))
      (should (string-match-p "Sub-agent kid running" (harness-call 'agent/outstanding sid)))
      (should-not (harness-tools-agent-test-reports sid))
      (should (equal "Sub-agent kid stopped" (harness-call 'agent/stop-outstanding sid why)))
      ;; What it started was cancelled, and it heard so, with the reason.
      (should-not (harness-call 'agent/running gid))
      (harness-test-wait (lambda () (harness-tools-agent-test-reports cid)) 5 "the grandchild's report")
      (should (string-match-p
               (format "Sub-agent report: grandkid (session %s) stopped: its turn was cancelled (%s)\\."
                       (regexp-quote gid) (regexp-quote why))
               (plist-get (car (harness-tools-agent-test-reports cid)) :content)))
      ;; Its own session hears it was stopped, as of a cancelled sub-agent.
      (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 5 "the report")
      (should (string-match-p
               (format "Sub-agent report: kid (session %s) stopped: its turn was cancelled (%s)\\."
                       (regexp-quote cid) (regexp-quote why))
               (plist-get (car (harness-tools-agent-test-reports sid)) :content)))
      (should-not (harness-call 'agent/running cid))
      (should-not (harness-call 'agent/outstanding sid))
      (should-not (harness-call 'agent/outstanding cid))
      (should-not (gethash cid harness-tools-agent--children))
      (should-not (gethash gid harness-tools-agent--children)))))

(ert-deftest harness-tools-agent-stop-outstanding-stops-the-work-of-a-running-sub-agent ()
  "A sub-agent that runs a turn with a sub-agent of its own at work is stopped with it.
Cancelling its turn alone would leave what it started running on, and it
outstanding for its session: the stop goes down to that sub-agent too.
Both are cancelled, and its session hears it was stopped, once."
  (harness-tools-agent-test-with
    (let* ((harness-agent--cancel-grace 0.05)
           (harness-provider-demo-script-override #'harness-tools-agent-test--stop-script)
           (why "its task was returned to the queue")
           (sid (harness-tools-agent-test-session))
           (cid (harness-tools-agent-test-spawn sid '(:prompt "delegate and carry on" :name "kid")))
           (gid nil))
      (harness-test-wait (lambda ()
                           (and (harness-call 'agent/running cid)
                                (setq gid (plist-get (car (harness-call 'session/list (list :parent-id cid))) :id))
                                (harness-call 'agent/running gid)))
                         10 "both to run")
      (should (equal "Sub-agent kid stopped" (harness-call 'agent/stop-outstanding sid why)))
      (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 5 "the report")
      (should-not (harness-call 'agent/running cid))
      (should-not (harness-call 'agent/running gid))
      (should (= 1 (length (harness-tools-agent-test-reports sid))))
      (should (string-match-p
               (format "Sub-agent report: kid (session %s) stopped: its turn was cancelled (%s)\\."
                       (regexp-quote cid) (regexp-quote why))
               (plist-get (car (harness-tools-agent-test-reports sid)) :content)))
      (should-not (harness-call 'agent/outstanding sid))
      (should-not (harness-call 'agent/outstanding cid))
      (should-not (gethash cid harness-tools-agent--children))
      (should-not (gethash gid harness-tools-agent--children)))))

(ert-deftest harness-tools-agent-marking-a-reported-sub-agent-makes-no-entry ()
  "A sub-agent reported meanwhile has no entry, and being marked as stopped makes none.
It would count as outstanding for its session, and be reported again,
from then on."
  (harness-tools-agent-test-with
    (puthash "child" (list :parent "parent" :name "kid" :result nil :stopped nil)
             harness-tools-agent--children)
    (should (string-match-p "Sub-agent kid running" (harness-call 'agent/outstanding "parent")))
    (harness-tools-agent--forget-child "child")
    (harness-tools-agent--mark-stopped "child" "its task was returned to the queue")
    (should-not (gethash "child" harness-tools-agent--children))
    (should-not (harness-call 'agent/outstanding "parent"))))

(ert-deftest harness-tools-agent-stop-outstanding-leaves-a-waiting-sub-agent-alone ()
  "A sub-agent that only waits for something is not stopped.
Its wait (`session_wait') is a cheap registration a stop leaves alone:
nothing is said to be stopped, the sub-agent stays outstanding, and its
report comes once the wait wakes it, as it does without a stop."
  (harness-tools-agent-test-with
    (harness-test-load-module 'tools-sessions)
    (let* ((harness-provider-demo-script-override #'harness-tools-agent-test--waiting-script)
           (target (harness-tools-agent-test-session)))
      (setq harness-tools-agent-test--target target)
      (setq harness-provider-demo--delay 0.5)
      (harness-call 'agent/prompt target "long job")
      (let* ((sid (harness-tools-agent-test-session))
             (turn (harness-test-await (harness-call 'agent/prompt sid "delegate the waiting") 30))
             (cid (plist-get (car (harness-call 'session/list (list :parent-id sid))) :id)))
        (should (eq 'end-turn (plist-get turn :stop-reason)))
        (harness-test-wait (lambda () (and (not (harness-call 'agent/running cid))
                                           (eq 'idle (plist-get (harness-call 'session/get cid) :status))))
                           10 "the waiting sub-agent")
        (should-not (harness-call 'agent/stop-outstanding sid "its task was returned to the queue"))
        ;; It goes on waiting, outstanding, and is not marked as stopped.
        (should (string-match-p "Sub-agent waiter running" (harness-call 'agent/outstanding sid)))
        (should (string-match-p "Waiting on" (harness-call 'agent/outstanding cid)))
        (should-not (plist-get (gethash cid harness-tools-agent--children) :stopped))
        (should-not (harness-tools-agent-test-reports sid))
        ;; The wait wakes it, and it is reported as having finished.
        (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 20 "the report")
        (let ((content (plist-get (car (harness-tools-agent-test-reports sid)) :content)))
          (should (string-match-p "\\`Sub-agent report: waiter (session [^)]+) finished\\." content))
          (should (string-match-p "all done" content)))
        (should-not (harness-call 'agent/outstanding sid))))))

(ert-deftest harness-tools-agent-stop-outstanding-does-not-merge-a-worktree-sub-agent ()
  "A stopped sub-agent in its own worktree is not merged back as finished work.
It is reported as any cancelled sub-agent is, which says where it
worked; the merge queue is not asked for its branch, which stays, with
its worktree, for the session or the user to merge."
  (harness-tools-agent-test-with
    (harness-test-load-module 'worktree)
    (harness-test-load-module 'merge)
    (let* ((base (harness-test-temp-dir))
           (root (file-name-as-directory (expand-file-name "repo" base))))
      (unwind-protect
          (progn
            (make-directory root t)
            (harness-tools-agent-test--git root "init" "-q" "-b" "main")
            (harness-tools-agent-test--git root "config" "user.name" "Harness Test")
            (harness-tools-agent-test--git root "config" "user.email" "test@example.invalid")
            (harness-tools-agent-test--git root "config" "commit.gpgsign" "false")
            (with-temp-file (expand-file-name "README" root) (insert "hello\n"))
            (harness-tools-agent-test--git root "add" "README")
            (harness-tools-agent-test--git root "commit" "-q" "-m" "initial")
            (let* ((harness-agent--cancel-grace 0.05)
                   (harness-provider-demo-script-override #'harness-tools-agent-test--stop-script)
                   (sid (plist-get (harness-call 'session/create :cwd root :model "demo:scripted") :id))
                   (cid (harness-tools-agent-test-spawn
                         sid '(:prompt "long job" :name "kid" :worktree t)))
                   (worktree (plist-get (harness-call 'session/get cid) :worktree)))
              (should (file-directory-p worktree))
              (harness-test-wait (lambda () (harness-call 'agent/running cid)) 5 "the child to run")
              (should (equal "Sub-agent kid stopped"
                             (harness-call 'agent/stop-outstanding sid "its task was returned to the queue")))
              (harness-test-wait (lambda () (harness-tools-agent-test-reports sid)) 10 "the report")
              (let ((report (plist-get (car (harness-tools-agent-test-reports sid)) :content)))
                (should (string-match-p "stopped: its turn was cancelled" report))
                (should (string-match-p "It worked in worktree" report))
                (should (string-match-p "on branch harness/" report)))
              ;; Nothing was queued for a merge; the branch and worktree are still there.
              (should-not (harness-call 'merge/status cid))
              (should-not (harness-call 'merge/queue sid))
              (should (file-directory-p worktree))
              (should (string-match-p "harness/"
                                      (harness-tools-agent-test--git root "branch" "--list" "harness/*")))))
        (ignore-errors (delete-directory base t))))))

(provide 'harness-tools-agent-test)
;;; harness-tools-agent-test.el ends here
