;;; harness-agent-test.el --- Tests for the turn loop  -*- lexical-binding: t; -*-
;;; Code:

(require 'harness-test-helpers)

(declare-function harness-define-provider "harness-provider")

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
     (let ((harness-provider-demo--delay 0.005)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (harness-define-tool "list_dir" :label "List directory" :description "list" :kind 'read
                            :handler (lambda (input _ctx) (format "listing of %s" (plist-get input :path))))
       (harness-define-tool "ask_user" :label "Question" :description "ask" :kind 'meta
                            :handler (lambda (input _ctx) (format "answer to %s: red" (plist-get input :question))))
       ,@body)))

(defun harness-agent-test-session ()
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "demo:scripted") :id))

(defun harness-agent-test-kinds (id)
  (mapcar (lambda (n) (plist-get n :kind)) (harness-call 'session/nodes id)))

(defun harness-agent-test-steering-nodes (id)
  "Return the steering messages recorded in session ID."
  (cl-remove-if-not (lambda (n) (plist-get (plist-get n :meta) :steering)) (harness-call 'session/nodes id)))

;;;; A hosted loop

(defvar harness-agent-test-prompts nil
  "What each request to the `hosted' provider sent, oldest first.")

(defvar harness-agent-test-results nil
  "The tool result contents the agent answered `hosted' with, oldest first.")

(defvar harness-agent-test-decisions nil
  "The permission decisions the agent answered `hosted' with, oldest first.")

(defvar harness-agent-test-requests nil
  "The requests `hosted' was sent, oldest first.")

(defun harness-agent-test-trailing-text (request)
  "Return the text a hosted loop sends for REQUEST, or nil.
That is the user messages after its last assistant message, like the
Claude provider does; tool results do not count."
  (let (texts)
    (dolist (m (plist-get request :messages))
      (pcase (plist-get m :role)
        ('assistant (setq texts nil))
        ('user (dolist (b (plist-get m :content))
                 (when (equal (plist-get b :type) "text") (push (plist-get b :text) texts))))))
    (and texts (string-join (nreverse texts) "\n"))))

(defun harness-agent-test-define-hosted (script &optional fork)
  "Define `hosted', a provider running its own tool loop from SCRIPT.
SCRIPT gets the text each request sends and returns its steps: event
plists or functions, called for their side effects, such as a message
the user sends mid-step.  A tool call waits for the agent's answer,
unless it is a call of the provider's own tool (`:builtin'); a
`tool-permission' waits for the agent's decision.  A request with
nothing to send fails like the Claude provider's.  The provider has
its own web_search, as Claude Code does.  FORK, when given, is its
`:fork' function."
  (setq harness-agent-test-prompts nil harness-agent-test-results nil
        harness-agent-test-decisions nil harness-agent-test-requests nil)
  (harness-define-provider 'hosted
    :label "Hosted"
    :complete
    (lambda (request)
      (let ((on-event (plist-get request :on-event))
            (prompt (harness-agent-test-trailing-text request))
            (cancelled nil))
        (setq harness-agent-test-prompts (append harness-agent-test-prompts (list prompt))
              harness-agent-test-requests (append harness-agent-test-requests (list request)))
        (cl-labels ((play (steps)
                      (let ((step (car steps)))
                        (cond
                         ((or cancelled (null steps)) nil)
                         ((functionp step) (funcall step) (run-at-time 0.005 nil #'play (cdr steps)))
                         ((and (eq (plist-get step :type) 'tool-call) (not (plist-get step :builtin)))
                          (funcall on-event
                                   (append step
                                           (list :respond
                                                 (lambda (result)
                                                   (setq harness-agent-test-results
                                                         (append harness-agent-test-results
                                                                 (list (plist-get result :content))))
                                                   (run-at-time 0.005 nil #'play (cdr steps)))))))
                         ((eq (plist-get step :type) 'tool-permission)
                          (funcall on-event
                                   (append step
                                           (list :respond
                                                 (lambda (decision)
                                                   (setq harness-agent-test-decisions
                                                         (append harness-agent-test-decisions (list decision)))
                                                   (run-at-time 0.005 nil #'play (cdr steps)))))))
                         (t (funcall on-event step)
                            (run-at-time 0.005 nil #'play (cdr steps)))))))
          (funcall on-event '(:type start))
          (if prompt
              (run-at-time 0.005 nil #'play (funcall script prompt))
            (funcall on-event '(:type done :stop-reason error :error "No user message to send"))))
        (list :cancel (lambda ()
                        (setq cancelled t)
                        (funcall on-event '(:type done :stop-reason cancelled))))))
    :fork fork
    :capabilities '(:hosted-loop t :builtin-tools ("web_search"))))

(defun harness-agent-test-hosted-session ()
  (plist-get (harness-call 'session/create :cwd (harness-test-temp-dir) :model "hosted:loop") :id))

;;;; Provider state

(ert-deftest harness-agent-provider-state-is-its-providers ()
  "A provider's state is recorded as its own and given to it alone.
A step on another provider drops it: that provider's turns are ones the
state's conversation never saw, so switching back must not look as if
it could carry on."
  (harness-agent-test-with
    (harness-agent-test-define-hosted
     (lambda (_prompt) '((:type provider-state :state (:conv "c1"))
                         (:type text :delta "hi")
                         (:type done :stop-reason end-turn))))
    (let ((id (harness-agent-test-hosted-session))
          (state '(:conv "c1" :provider "hosted")))
      (harness-await (harness-call 'agent/prompt id "hello"))
      (should (equal state (plist-get (harness-call 'session/get id) :provider-state)))
      (harness-await (harness-call 'agent/prompt id "again"))
      (should (equal state (plist-get (cadr harness-agent-test-requests) :provider-state)))
      ;; Switched away, the state stays until a step runs elsewhere...
      (harness-call 'session/update id :model "demo:scripted" :silent t)
      (should (equal state (plist-get (harness-call 'session/get id) :provider-state)))
      (let ((requests nil))
        (cl-letf* ((orig (symbol-function 'harness-method/provider/complete))
                   ((symbol-function 'harness-method/provider/complete)
                    (lambda (req) (push req requests) (funcall orig req))))
          (harness-await (harness-call 'agent/prompt id "on demo")))
        ;; ...which is not sent it, and drops it.
        (should-not (plist-get (car requests) :provider-state))
        (should-not (plist-get (plist-get (car requests) :session) :provider-state)))
      (should-not (plist-get (harness-call 'session/get id) :provider-state))
      ;; Back on the hosted provider, its next step starts afresh.
      (harness-call 'session/update id :model "hosted:loop" :silent t)
      (harness-await (harness-call 'agent/prompt id "back"))
      (should-not (plist-get (car (last harness-agent-test-requests)) :provider-state)))))

(ert-deftest harness-agent-step-writes-under-its-own-model ()
  "What a step reports belongs to the model it went to, though the session switched meanwhile.
A switch applies from the next step: the reply names the model that
wrote it, and the provider state is the old provider's."
  (harness-agent-test-with
    (let ((id nil))
      (harness-agent-test-define-hosted
       (lambda (_prompt)
         (list (lambda () (harness-call 'session/update id :model "demo:scripted" :silent t))
               '(:type provider-state :state (:conv "c2"))
               '(:type text :delta "still hosted")
               '(:type done :stop-reason end-turn))))
      (setq id (harness-agent-test-hosted-session))
      (harness-await (harness-call 'agent/prompt id "hello"))
      (let ((reply (cl-find 'assistant (harness-call 'session/nodes id) :key (lambda (n) (plist-get n :kind)))))
        (should (equal "still hosted" (plist-get reply :content)))
        (should (equal "hosted:loop" (plist-get (plist-get reply :meta) :model))))
      (should (equal '(:conv "c2" :provider "hosted") (plist-get (harness-call 'session/get id) :provider-state)))
      (should (equal "demo:scripted" (plist-get (harness-call 'session/get id) :model))))))

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
      (should (equal '(user assistant user assistant) (harness-agent-test-kinds id)))
      (should-not (harness-agent-test-steering-nodes id)))))

(ert-deftest harness-agent-message-filters-see-each-delivered-message ()
  "`agent/message' filters see a message as it is delivered; what they return goes out.
A message is delivered when it starts a turn or steers one, a queued
one when its queue goes out, never while it waits there.  Task mode
sends a task waiting for review back this way."
  (harness-agent-test-with
    (let ((id (harness-agent-test-session))
          (seen nil)
          (ended 0))
      (harness-on 'agent/turn-ended (lambda (&rest _) (cl-incf ended)))
      (harness-add-filter 'agent/message
                          (lambda (blocks sid info)
                            (push (list (equal sid id) (plist-get (car blocks) :text)
                                        (and (plist-get info :steering) t)
                                        (harness-sender-kind (plist-get info :from)))
                                  seen)
                            (cons (list :type "text" :text "[seen]") blocks)))
      (harness-call 'agent/prompt id "first")
      (harness-call 'agent/prompt id "steer it" (list :from (harness-sender-system "test")))
      (harness-call 'agent/prompt id "queued one" '(:queue t))
      (should (equal '((t "steer it" t system) (t "first" nil nil)) seen))
      (should (equal '("queued one") (mapcar (lambda (it) (plist-get it :text))
                                             (plist-get (harness-call 'session/get id) :queue))))
      (harness-test-wait (lambda () (= ended 2)) 5 "the queued turn")
      (should (equal '((t "queued one" nil nil) (t "steer it" t system) (t "first" nil nil)) seen))
      ;; What the filter returned is what each message became.
      (should (equal '("[seen] first" "[seen] queued one" "[seen] steer it")
                     (sort (mapcar (lambda (n) (plist-get n :content)) (harness-agent-test-user-nodes id))
                           #'string<))))))

(ert-deftest harness-agent-queue-during-turn-is-not-steering ()
  "A message queued while a turn runs waits for it to end, then is a turn of its own.
It is never added to the running turn: no steering node, no
<user_message> in a tool result."
  (harness-agent-test-with
    (let* ((id (harness-agent-test-hosted-session))
           (started 0)
           (queued-meanwhile nil))
      (harness-on 'agent/turn-started (lambda (_) (cl-incf started)))
      (harness-agent-test-define-hosted
       (lambda (prompt)
         (if (equal prompt "go")
             `((:type tool-call :id "h1" :name "list_dir" :input (:path "/a"))
               ,(lambda ()
                  (harness-await (harness-call 'agent/prompt id "queued one" '(:queue t)))
                  (setq queued-meanwhile (mapcar (lambda (it) (plist-get it :text))
                                                 (plist-get (harness-call 'session/get id) :queue))))
               (:type tool-call :id "h2" :name "list_dir" :input (:path "/b"))
               (:type text :delta "Done.")
               (:type done :stop-reason end-turn))
           '((:type text :delta "Got it.") (:type done :stop-reason end-turn)))))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt id "go")) :stop-reason)))
      (should (equal '("queued one") queued-meanwhile))
      (harness-test-wait (lambda () (and (= started 2) (not (harness-agent-running-p id)))) 5 "the queued turn")
      (should (equal '("go" "queued one") harness-agent-test-prompts))
      (should (= 2 (length harness-agent-test-results)))
      (should-not (cl-some (lambda (c) (string-match-p "user_message" c)) harness-agent-test-results))
      (should-not (harness-agent-test-steering-nodes id))
      (should (null (plist-get (harness-call 'session/get id) :queue)))
      (should (equal '(user tool-call tool-result tool-call tool-result assistant user assistant)
                     (harness-agent-test-kinds id))))))

(ert-deftest harness-agent-send-queue-with-nothing-to-send ()
  "Sending an empty queue, or one of empty items, starts no turn."
  (harness-agent-test-with
    (let ((id (harness-agent-test-session))
          (started 0))
      (harness-on 'agent/turn-started (lambda (_) (cl-incf started)))
      (should (eq 'nothing-queued (plist-get (harness-test-await (harness-call 'agent/send-queue id)) :stop-reason)))
      (harness-call 'session/queue id "" nil)
      (harness-call 'session/queue id " \n" nil)
      (should (eq 'nothing-queued (plist-get (harness-test-await (harness-call 'agent/send-queue id)) :stop-reason)))
      (should (null (plist-get (harness-call 'session/get id) :queue)))
      (accept-process-output nil 0.05)
      (should (= 0 started))
      (should-not (harness-agent-running-p id))
      (should (null (harness-call 'session/nodes id))))))

(ert-deftest harness-agent-send-queue-joins-messages ()
  "Queued messages go out as one turn, each its own paragraph; empty ones are dropped."
  (harness-agent-test-with
    (let ((id (harness-agent-test-session)))
      (harness-call 'session/queue id "first" nil)
      (harness-call 'session/queue id "" nil)
      (harness-call 'session/queue id "second" nil)
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/send-queue id)) :stop-reason)))
      (should (equal "first\n\nsecond" (plist-get (car (harness-call 'session/nodes id)) :content))))))

(defun harness-agent-test-user-nodes (id)
  "Return the user messages of session ID, oldest first."
  (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes id)))

(ert-deftest harness-agent-prompt-records-who-sent-it ()
  "A message the user did not write keeps its sender, as a turn or as steering.
The model gets it as a user message all the same."
  (harness-agent-test-with
    (let ((id (harness-agent-test-session))
          (system (harness-sender-system "tasks"))
          (other (harness-sender-session '(:id "s-other" :name "Other"))))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt id "carry on" (list :from system)))
                                       :stop-reason)))
      (harness-test-await (harness-call 'agent/prompt id "thanks"))
      (let ((p (harness-call 'agent/prompt id "tour")))
        (harness-test-wait (lambda () (harness-agent-running-p id)) 5 "the turn")
        (harness-call 'agent/prompt id "also this" (list :from other))
        (harness-test-await p))
      (pcase-let ((`(,carry ,thanks ,tour ,also) (harness-agent-test-user-nodes id)))
        (should (equal system (harness-node-sender carry)))
        ;; The user's own messages name no sender.
        (should-not (harness-node-sender thanks))
        (should-not (plist-get tour :meta))
        ;; Steering keeps its own marks beside the sender.
        (should (equal "also this" (plist-get also :content)))
        (should (plist-get (plist-get also :meta) :steering))
        (should (equal other (harness-node-sender also))))
      (let ((first (car (harness-call 'session/messages id))))
        (should (eq 'user (plist-get first :role)))
        (should (equal "carry on" (plist-get (car (plist-get first :content)) :text)))))))

(ert-deftest harness-agent-send-queue-keeps-the-sender ()
  "Queued messages keep their sender; sent as one, they are the user's when any is."
  (harness-agent-test-with
    (let ((id (harness-agent-test-session))
          (other (harness-sender-session '(:id "s-other" :name "Other"))))
      (harness-test-await (harness-call 'agent/prompt id "from elsewhere" (list :queue t :from other)))
      (should (equal other (plist-get (car (plist-get (harness-call 'session/get id) :queue)) :from)))
      (harness-test-await (harness-call 'agent/send-queue id))
      (should (equal other (harness-node-sender (car (harness-agent-test-user-nodes id)))))
      ;; With one of the user's own among them, the message is the user's.
      (harness-call 'session/queue id "from elsewhere again" nil other)
      (harness-call 'session/queue id "and mine" nil)
      (harness-test-await (harness-call 'agent/send-queue id))
      (let ((joined (car (last (harness-agent-test-user-nodes id)))))
        (should (equal "from elsewhere again\n\nand mine" (plist-get joined :content)))
        (should-not (harness-node-sender joined)))
      ;; An empty item of the user's does not take the message over.
      (harness-call 'session/queue id "" nil)
      (harness-call 'session/queue id "only theirs" nil other)
      (harness-test-await (harness-call 'agent/send-queue id))
      (should (equal other (harness-node-sender (car (last (harness-agent-test-user-nodes id)))))))))

(ert-deftest harness-agent-prompt-refuses-empty-messages ()
  "Nothing to send starts no turn and queues nothing; a JSON false does not queue."
  (harness-agent-test-with
    (let ((id (harness-agent-test-session)))
      (should-error (harness-call 'agent/prompt id "") :type 'harness-error)
      (should-error (harness-call 'agent/prompt id (list (list :type "text" :text " \n"))) :type 'harness-error)
      (should-error (harness-call 'agent/prompt id "  " '(:queue t)) :type 'harness-error)
      (should-not (harness-agent-running-p id))
      (should (null (harness-call 'session/nodes id)))
      (should (null (plist-get (harness-call 'session/get id) :queue)))
      ;; An attachment alone is worth queueing.
      (harness-test-await (harness-call 'agent/prompt id ""
                                        (list :queue t :attachments (list (list :path "/tmp/a.txt" :mime "text/plain"
                                                                                :name "a.txt" :size 1)))))
      (should (= 1 (length (plist-get (harness-call 'session/get id) :queue))))
      (harness-call 'session/queue-take id)
      ;; `:queue' false, as JSON sends it, sends.
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt id "hello" '(:queue :false)))
                                       :stop-reason)))
      (should (null (plist-get (harness-call 'session/get id) :queue))))))

(ert-deftest harness-agent-queue-waits-for-a-turn-started-meanwhile ()
  "The queue sent at the end of a turn never steers a turn that started since."
  (harness-agent-test-with
    (let ((id (harness-agent-test-session)))
      (harness-call 'session/queue id "queued one" nil)
      (let ((p (harness-call 'agent/prompt id "tour")))
        (harness-test-wait (lambda () (harness-agent-running-p id)) 5 "the turn")
        ;; What the end of an earlier turn scheduled, running late.
        (harness-agent--send-queued id)
        (should (equal '("queued one") (mapcar (lambda (it) (plist-get it :text))
                                               (plist-get (harness-call 'session/get id) :queue))))
        (harness-test-await p))
      ;; This turn's end sends it, as a turn of its own.
      (harness-test-wait (lambda () (null (plist-get (harness-call 'session/get id) :queue))) 5 "the queue sent")
      (harness-test-wait (lambda () (not (harness-agent-running-p id))) 5 "the queued turn")
      (should-not (harness-agent-test-steering-nodes id))
      (should (equal "queued one" (plist-get (car (last (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user))
                                                                           (harness-call 'session/nodes id))))
                                             :content))))))

(ert-deftest harness-agent-steering-during-last-step-is-sent-once ()
  "Steering that arrives after the last tool call gets one more step, then the turn ends.
It used to stay pending, so every later stop stepped the provider again."
  (harness-agent-test-with
    (let ((id (harness-agent-test-session))
          (harness-provider-demo--delay 0.05)
          (steps 0))
      (harness-on 'agent/step-started (lambda (_ n) (setq steps n)))
      (let ((p (harness-call 'agent/prompt id "hello")))
        (harness-test-wait (lambda () (memq 'assistant (harness-agent-test-kinds id))) 5 "the reply")
        (harness-call 'agent/prompt id "also this")
        (should (eq 'end-turn (plist-get (harness-test-await p) :stop-reason))))
      (should (= 2 steps))
      (should (equal '(user assistant user assistant) (harness-agent-test-kinds id)))
      (should (string-match-p "also this" (plist-get (car (last (harness-call 'session/nodes id))) :content))))))

(ert-deftest harness-agent-turn-has-no-step-limit ()
  "A turn is not capped: it runs until the model stops, however many steps that takes.
The harness is for long unattended runs, so a step cap must not cut one
short (this would have ended at 200 steps before)."
  (harness-agent-test-with
    (let ((id (harness-agent-test-session))
          (rounds 210)
          (harness-provider-demo--delay 0.0005)
          (steps 0))
      (setq harness-provider-demo-script-override
            (append (cl-loop for i from 1 to rounds
                             collect (list :type 'tool-call :id (format "c%d" i)
                                           :name "list_dir" :input (list :path ".")))
                    '((:type done :stop-reason end-turn))))
      (harness-on 'agent/step-started (lambda (_ n) (setq steps n)))
      (let ((result (harness-test-await (harness-call 'agent/prompt id "keep going") 60)))
        (should (eq 'end-turn (plist-get result :stop-reason)))
        ;; One step per tool round, then the step the model ends on.
        (should (= (1+ rounds) steps))
        (should (= rounds (cl-count 'tool-call (harness-agent-test-kinds id))))))))

(ert-deftest harness-agent-steering-after-last-tool-call-hosted ()
  "A hosted loop gets steering sent after its last tool call once, as its next message.
Sent while the model was thinking, the message lands before the answer
in the transcript.  It used to stay pending, so the next request had no
user message after that answer: \"No user message to send\"."
  (harness-agent-test-with
    (let ((id (harness-agent-test-hosted-session)))
      (harness-agent-test-define-hosted
       (lambda (prompt)
         (pcase prompt
           ("start"
            `((:type tool-call :id "h1" :name "list_dir" :input (:path "/a"))
              (:type thinking :delta "Reading the listing.")
              ,(lambda () (harness-call 'agent/prompt id "also check b"))
              (:type text :delta "Here is the listing.")
              (:type done :stop-reason end-turn)))
           ("also check b"
            '((:type tool-call :id "h2" :name "list_dir" :input (:path "/b"))
              (:type text :delta "b is fine.")
              (:type done :stop-reason end-turn)))
           (_ '((:type text :delta "?") (:type done :stop-reason end-turn))))))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt id "start")) :stop-reason)))
      (should (equal '("start" "also check b") harness-agent-test-prompts))
      (should (= 2 (length harness-agent-test-results)))
      (should-not (cl-some (lambda (c) (string-match-p "user_message" c)) harness-agent-test-results))
      (should-not (cl-find-if (lambda (n) (and (eq (plist-get n :kind) 'hint)
                                               (string-match-p "No user message" (plist-get n :content))))
                              (harness-call 'session/nodes id)))
      ;; The transcript keeps the order things happened in...
      (should (equal '(user tool-call tool-result thinking user assistant tool-call tool-result assistant)
                     (harness-agent-test-kinds id)))
      ;; ...while the model reads the message after the answer it interrupted.
      (let ((msgs (harness-call 'session/messages id)))
        (should (equal '(user assistant user assistant user assistant user assistant)
                       (mapcar (lambda (m) (plist-get m :role)) msgs)))
        (should (equal '("thinking" "text") (mapcar (lambda (b) (plist-get b :type)) (plist-get (nth 3 msgs) :content))))
        (should (equal "also check b" (plist-get (car (plist-get (nth 4 msgs) :content)) :text)))))))

(ert-deftest harness-agent-steering-rides-on-one-tool-result-hosted ()
  "Steering sent while a tool runs goes out with that tool's result, and only there."
  (harness-agent-test-with
    (let ((id (harness-agent-test-hosted-session)))
      (harness-define-tool "slow" :label "Slow" :description "slow" :kind 'read
                           :handler (lambda (_input _ctx)
                                      (harness-call 'agent/prompt id "change of plan")
                                      "slow output"))
      (harness-agent-test-define-hosted
       (lambda (_prompt)
         '((:type tool-call :id "h1" :name "slow" :input (:n 1))
           (:type tool-call :id "h2" :name "list_dir" :input (:path "/b"))
           (:type text :delta "Done.")
           (:type done :stop-reason end-turn))))
      (should (eq 'end-turn (plist-get (harness-test-await (harness-call 'agent/prompt id "go")) :stop-reason)))
      (should (equal '("go") harness-agent-test-prompts))
      (should (equal "slow output\n\n<user_message>\nchange of plan\n</user_message>" (nth 0 harness-agent-test-results)))
      (should-not (string-match-p "user_message" (nth 1 harness-agent-test-results)))
      (should (= 1 (length (harness-agent-test-steering-nodes id))))
      ;; The model's view: the message follows the result that carried it.
      (let ((msgs (harness-call 'session/messages id)))
        (should (equal '("tool_result" "text") (mapcar (lambda (b) (plist-get b :type)) (plist-get (nth 2 msgs) :content))))
        (should (equal "change of plan" (plist-get (cadr (plist-get (nth 2 msgs) :content)) :text)))))))

(ert-deftest harness-agent-cancel ()
  (harness-agent-test-with
    (let* ((id (harness-agent-test-session))
           (harness-provider-demo--delay 0.2)
           (p (harness-call 'agent/prompt id "tour")))
      (harness-test-wait (lambda () (harness-agent-running-p id)))
      (should (harness-call 'agent/cancel id))
      (should (eq 'cancelled (plist-get (harness-await p) :stop-reason)))
      (should-not (harness-agent-running-p id))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status))))))

(defvar harness-provider-demo-script-override)

(ert-deftest harness-agent-streamed-text-saved-on-exit ()
  "Text a running turn has streamed is written when the harness exits."
  (harness-agent-test-with
    (let* ((id (harness-agent-test-session))
           (harness-provider-demo--delay 0.3)
           (harness-provider-demo-script-override
            '((:type text :delta "Hello") (:type text :delta ", world")
              (:type text :delta "!") (:type done :stop-reason end-turn)))
           (log (format "sessions/%s.nodes.jsonl" id)))
      (should (memq #'harness-agent--save-live kill-emacs-hook))
      (harness-call 'agent/prompt id "hi")
      (harness-test-wait (lambda () (equal "Hello, world" (plist-get (car (last (harness-call 'session/nodes id))) :content)))
                         5 "two chunks")
      ;; Streamed chunks stay in memory: only the first one is on disk.
      (should-not (cl-find "Hello, world" (harness-call 'store/read-all log)
                           :key (lambda (r) (plist-get r :content)) :test #'equal))
      ;; What the exit hooks do, then a fresh start.
      (harness-agent--save-live)
      (harness-session-flush)
      (clrhash harness-sessions)
      (harness-session--load-all)
      (should (equal "Hello, world"
                     (plist-get (cl-find 'assistant (harness-call 'session/nodes id) :key (lambda (n) (plist-get n :kind)))
                                :content)))
      (harness-call 'agent/cancel id)
      (harness-test-wait (lambda () (not (harness-agent-running-p id))) 5 "the turn to stop"))))

(defun harness-agent-test-record-activity (id)
  "Return a cell whose car collects ID's activity changes, oldest first."
  (let ((cell (list nil)))
    (harness-on 'agent/activity-changed
                (lambda (sid activity)
                  (when (equal sid id) (setcar cell (append (car cell) (list activity))))))
    cell))

(defun harness-agent-test-phases (activities)
  "Return the phases of ACTIVITIES with repeats of one phase merged."
  (let (out)
    (dolist (a activities (nreverse out))
      (let ((phase (plist-get a :phase)))
        (unless (and out (eq phase (car out)))
          (push phase out))))))

(ert-deftest harness-agent-activity-follows-the-turn ()
  "Every gap of a turn says what the agent is doing, and nothing is left after."
  (harness-agent-test-with
    (let* ((id (harness-agent-test-session))
           (seen (harness-agent-test-record-activity id))
           (harness-provider-demo-script-override
            '((:type activity :phase thinking)
              (:type thinking :delta "Let me look.")
              (:type activity :phase writing)
              (:type text :delta "\n\n")
              (:type activity :phase tool-input :tool "list_dir" :chars 0)
              (:type activity :phase tool-input :tool "list_dir" :chars 12)
              (:type tool-call :id "t1" :name "list_dir" :input (:path "/tmp"))
              (:type text :delta "\n\n")
              (:type text :delta "Done.")
              (:type done :stop-reason end-turn))))
      (harness-await (harness-call 'agent/prompt id "go"))
      (let ((activities (car seen)))
        (should (equal '(waiting thinking writing tool-input tool waiting writing nil)
                       (harness-agent-test-phases activities)))
        ;; A tool-input phase grows in place: it keeps when it began.
        (let ((inputs (cl-remove-if-not (lambda (a) (eq (plist-get a :phase) 'tool-input)) activities)))
          (should (equal '(0 12) (mapcar (lambda (a) (plist-get a :chars)) inputs)))
          (should (equal "list_dir" (plist-get (car inputs) :tool)))
          (should (= (plist-get (car inputs) :since) (plist-get (cadr inputs) :since))))
        ;; The call shows with its title while it runs.
        (let ((tool (cl-find 'tool activities :key (lambda (a) (plist-get a :phase)))))
          (should (equal "list_dir" (plist-get tool :tool)))
          (should (stringp (plist-get tool :title)))
          (should (numberp (plist-get tool :since))))
        (should (null (car (last activities)))))
      (should-not (harness-call 'agent/activity id))
      ;; The whitespace before the call opened no message; the one after
      ;; leads the message it belongs to.
      (should (equal '(user thinking tool-call tool-result assistant) (harness-agent-test-kinds id)))
      (should (equal "\n\nDone." (plist-get (car (last (harness-call 'session/nodes id))) :content))))))

(ert-deftest harness-agent-activity-shows-tool-progress ()
  "A running tool's progress and its permission decision show in the activity."
  (harness-agent-test-with
    (let* ((id (harness-agent-test-session))
           (seen (harness-agent-test-record-activity id))
           (harness-agent--progress-interval 0.2)
           (finish nil)
           (decide nil)
           (harness-provider-demo-script-override
            '((:type tool-call :id "s1" :name "slow" :input (:what "tests"))
              (:type text :delta "ok")
              (:type done :stop-reason end-turn))))
      (harness-add-filter 'permission/decide
                          (lambda (_d next &rest _) (setq decide (lambda () (funcall next '(:behavior allow))))) 5)
      (harness-define-tool "slow" :label "Slow job" :description "slow" :kind 'exec
                           :subject (lambda (input) (plist-get input :what))
                           :handler (lambda (_input ctx)
                                      (let ((report (plist-get ctx :report)))
                                        (funcall report "compiling\n")
                                        (funcall report "\e[32mPASS\e[0m a.test\nPASS b.test\n")
                                        (harness-with-promise (resolve reject)
                                          (ignore reject)
                                          (setq finish (lambda () (funcall resolve "done")))))))
      (let ((p (harness-call 'agent/prompt id "go")))
        ;; While the permission chain decides, the call is being checked.
        (harness-test-wait (lambda () decide) 5 "the permission check")
        (let ((a (harness-call 'agent/activity id)))
          (should (eq 'tool (plist-get a :phase)))
          ;; Titled with the tool's label, then what the call is about.
          (should (equal "Slow job: tests" (plist-get a :title)))
          (should (plist-get a :checking)))
        (let ((asked (plist-get (harness-call 'agent/activity id) :since)))
          (sleep-for 0.05)
          (funcall decide)
          ;; From the decision on it runs; its time counts from then.
          (harness-test-wait (lambda () finish) 5 "the tool to start")
          (harness-test-wait (lambda () (equal "PASS b.test" (plist-get (harness-call 'agent/activity id) :detail)))
                             5 "the latest progress line")
          (let ((a (harness-call 'agent/activity id)))
            (should-not (plist-get a :checking))
            (should (> (plist-get a :since) asked))))
        (funcall finish)
        (harness-await p))
      (should (null (car (last (car seen)))))
      (should-not (harness-call 'agent/activity id)))))

(ert-deftest harness-agent-reload-subscribes-new-handlers ()
  "A reload does not initialise a running module again, yet its new handlers run."
  (harness-agent-test-with
    (let ((subscribed (lambda (event fn) (cl-find fn (gethash event harness--subscribers) :key #'cdr))))
      (should (funcall subscribed 'tools/progress #'harness-agent--on-tool-progress))
      ;; As if the running harness predated them.
      (harness-off (cons 'tools/progress #'harness-agent--on-tool-progress))
      (harness-off (cons 'permission/decided #'harness-agent--on-permission-decided))
      (should-not (funcall subscribed 'tools/progress #'harness-agent--on-tool-progress))
      (let ((harness--defining-module 'agent))
        (harness-load-compiled (expand-file-name "lisp/modules/harness-agent.el" harness-test-root)))
      (should (funcall subscribed 'tools/progress #'harness-agent--on-tool-progress))
      (should (funcall subscribed 'permission/decided #'harness-agent--on-permission-decided))
      ;; Subscribing is idempotent: one handler, however often loaded.
      (should (= 1 (cl-count #'harness-agent--on-tool-progress (gethash 'tools/progress harness--subscribers)
                             :key #'cdr))))))

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
      (should (equal '("list_dir") seen-tools))
      ;; The Environment names the session's own temporary directory, which exists.
      (let ((tmp (harness-call 'session/tmp-dir id)))
        (should (string-match-p (concat "^- Temporary directory: " (regexp-quote tmp) " (") seen-system))
        (delete-directory tmp t)
        (harness-await (harness-call 'agent/prompt id "again"))
        (should (file-directory-p tmp))))))

(ert-deftest harness-agent-prompt-resumes-inactive-session ()
  (harness-agent-test-with
    (let* ((id (harness-agent-test-session))
           (resumed nil))
      (harness-on 'session/resumed (lambda (sid) (push sid resumed)))
      (harness-call 'session/deactivate id)
      ;; Queueing only queues: the session stays closed.
      (harness-await (harness-call 'agent/prompt id "later" '(:queue t)))
      (should (eq 'inactive (plist-get (harness-call 'session/get id) :status)))
      (should-not resumed)
      (harness-call 'session/queue-take id)
      ;; Sending brings it back: resumed, a turn, then idle like any session.
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "hello again")) :stop-reason)))
      (should (equal (list id) resumed))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status)))
      (should (equal '(user assistant) (harness-agent-test-kinds id)))
      ;; Closed mid-turn, a steering message revives it as running.
      (let ((p (harness-call 'agent/prompt id "tour")))
        (harness-test-wait (lambda () (harness-agent-running-p id)))
        (harness-call 'session/deactivate id)
        (harness-call 'agent/prompt id "and the tests")
        (should (eq 'running (plist-get (harness-call 'session/get id) :status)))
        (harness-await p))
      (should (eq 'idle (plist-get (harness-call 'session/get id) :status))))))

;;;; Tools the provider runs itself

(defmacro harness-agent-test-with-builtin-search (&rest body)
  "Run BODY where the `hosted' provider's own search stands in for web_search.
The harness has a web_search tool that must never run; a filter on
`agent/builtin-tools' picks the provider's search whenever it offers one."
  (declare (indent 0))
  `(harness-agent-test-with
     (harness-define-tool "web_search" :label "Web search" :description "search" :kind 'net
                          :subject (lambda (input) (plist-get input :query))
                          :handler (lambda (&rest _) (error "The harness ran web_search")))
     (harness-add-filter 'agent/builtin-tools
                         (lambda (names _session offered)
                           (if (member "web_search" offered) (cons "web_search" names) names)))
     ,@body))

(defun harness-agent-test--node (id kind)
  "Return the first node of KIND in session ID."
  (cl-find kind (harness-call 'session/nodes id) :key (lambda (n) (plist-get n :kind))))

(ert-deftest harness-agent-builtin-call-is-recorded ()
  "A call the provider runs itself is decided by the harness and recorded with its result."
  (harness-agent-test-with-builtin-search
    (let ((id (harness-agent-test-hosted-session))
          (decided nil)
          (activity nil))
      (harness-on 'permission/decided (lambda (_sid request decision) (push (cons request decision) decided)))
      (harness-agent-test-define-hosted
       (lambda (_prompt)
         (list '(:type tool-call :id "ws1" :name "web_search" :input (:query "emacs") :builtin t)
               (lambda () (setq activity (harness-call 'agent/activity id)))
               '(:type tool-permission :id "ws1" :name "web_search" :input (:query "emacs"))
               '(:type tool-result :id "ws1" :content "1. GNU Emacs" :is-error nil)
               '(:type text :delta "Found it.")
               '(:type done :stop-reason end-turn))))
      (should (eq 'end-turn (plist-get (harness-await (harness-call 'agent/prompt id "search")) :stop-reason)))
      ;; The provider was asked to search itself, and not given web_search.
      (let ((request (car harness-agent-test-requests)))
        (should (equal '("web_search") (plist-get request :builtin-tools)))
        (should-not (member "web_search" (mapcar (lambda (s) (plist-get s :name)) (plist-get request :tools)))))
      ;; The harness's permission chain decided the call, as web_search's.
      (should (= 1 (length decided)))
      (let ((request (caar decided)))
        (should (equal "web_search" (plist-get request :tool)))
        (should (eq 'net (plist-get request :kind)))
        (should (equal "ws1" (plist-get request :call-id))))
      (should (eq 'allow (plist-get (car harness-agent-test-decisions) :behavior)))
      ;; While it ran the turn said so.
      (should (eq 'tool (plist-get activity :phase)))
      (should (equal "Web search: emacs" (plist-get activity :title)))
      ;; The call and its result, in order, as web_search's.
      (should (equal '(user tool-call tool-result assistant) (harness-agent-test-kinds id)))
      (let ((call (harness-agent-test--node id 'tool-call))
            (result (harness-agent-test--node id 'tool-result)))
        (should (equal "web_search" (plist-get call :tool)))
        (should (equal "ws1" (plist-get call :call-id)))
        (should (equal "Web search: emacs" (plist-get call :title)))
        (should (plist-get (plist-get call :meta) :builtin))
        (should (equal "ws1" (plist-get result :call-id)))
        (should (equal "1. GNU Emacs" (plist-get result :output)))
        (should-not (plist-get result :is-error))
        (should-not (plist-get (plist-get result :meta) :denied)))
      ;; The transcript pairs them for providers that replay it.
      (let ((blocks (cl-loop for m in (harness-call 'session/messages id) append (plist-get m :content))))
        (should (equal "ws1" (plist-get (cl-find "tool_use" blocks :key (lambda (b) (plist-get b :type)) :test #'equal) :id)))
        (should (equal "ws1" (plist-get (cl-find "tool_result" blocks :key (lambda (b) (plist-get b :type)) :test #'equal)
                                        :tool_use_id))))
      (should-not (harness-call 'agent/activity id)))))

(ert-deftest harness-agent-builtin-call-denied ()
  "A call the permission chain refuses is refused to the provider, with what to tell the model."
  (harness-agent-test-with-builtin-search
    (let ((id (harness-agent-test-hosted-session)))
      (harness-add-filter 'permission/decide
                          (lambda (_d next request)
                            (funcall next (if (equal "web_search" (plist-get request :tool))
                                              '(:behavior deny :reason "no searching today" :final t)
                                            '(:behavior allow))))
                          5)
      (harness-agent-test-define-hosted
       (lambda (_prompt)
         (list '(:type tool-call :id "ws2" :name "web_search" :input (:query "emacs") :builtin t)
               '(:type tool-permission :id "ws2" :name "web_search" :input (:query "emacs"))
               ;; The provider tells its model what the harness said.
               '(:type tool-result :id "ws2" :content "Denied: no searching today" :is-error t)
               '(:type done :stop-reason end-turn))))
      (harness-await (harness-call 'agent/prompt id "search"))
      (let ((decision (car harness-agent-test-decisions)))
        (should (eq 'deny (plist-get decision :behavior)))
        (should (equal "Denied: no searching today" (plist-get decision :message))))
      (let ((result (harness-agent-test--node id 'tool-result)))
        (should (plist-get result :is-error))
        (should (equal "Denied: no searching today" (plist-get result :output)))
        (should (plist-get (plist-get result :meta) :denied))))))

(ert-deftest harness-agent-builtin-call-without-result-is-closed ()
  "A call the provider never reports a result for gets one when it is done."
  (harness-agent-test-with-builtin-search
    (let ((id (harness-agent-test-hosted-session)))
      ;; Reported only when asked about, and never finished.
      (harness-agent-test-define-hosted
       (lambda (prompt)
         (if (equal prompt "stop")
             (list '(:type tool-permission :id "ws3" :name "web_search" :input (:query "emacs"))
                   '(:type done :stop-reason end-turn))
           (list '(:type tool-call :id "ws4" :name "web_search" :input (:query "lisp") :builtin t)
                 (lambda () (harness-call 'agent/cancel id))))))
      (harness-await (harness-call 'agent/prompt id "stop"))
      (should (equal '(user tool-call tool-result) (harness-agent-test-kinds id)))
      (let ((result (harness-agent-test--node id 'tool-result)))
        (should (equal "ws3" (plist-get result :call-id)))
        (should (plist-get result :is-error))
        (should (string-match-p "stopped before this call returned a result" (plist-get result :output)))
        (should (plist-get (plist-get result :meta) :interrupted)))
      ;; Cancelled mid-call.
      (should (eq 'cancelled (plist-get (harness-await (harness-call 'agent/prompt id "cancel")) :stop-reason)))
      (let ((result (car (last (harness-call 'session/nodes id)))))
        (should (eq 'tool-result (plist-get result :kind)))
        (should (equal "ws4" (plist-get result :call-id)))
        (should (string-match-p "Cancelled before" (plist-get result :output))))
      ;; A result reported after the turn is not recorded twice.
      (should (= 2 (cl-count 'tool-result (harness-agent-test-kinds id)))))))

;;;; Provider checkpoints and the head

(ert-deftest harness-agent-records-provider-checkpoints ()
  "A hosted provider's checkpoints land on the nodes holding what they mark.
One without a call id marks the text the turn wrote last, unless a tool
call came after it; a tool call brings its own; one with a call id marks
that call's result.  The turn's end records where the conversation got."
  (harness-agent-test-with
    (harness-agent-test-define-hosted
     (lambda (_prompt)
       (list '(:type text :delta "Let me look")
             '(:type checkpoint :checkpoint (:at "c-text"))
             '(:type tool-call :id "t1" :name "list_dir" :input (:path "/") :checkpoint (:at "c-call"))
             '(:type checkpoint :checkpoint (:at "c-result") :call-id "t1")
             '(:type checkpoint :checkpoint (:at "c-nowhere"))
             '(:type text :delta "Done")
             '(:type checkpoint :checkpoint (:at "c-done"))
             '(:type done :stop-reason end-turn))))
    (let ((id (harness-agent-test-hosted-session)))
      (harness-await (harness-call 'agent/prompt id "go"))
      (let ((nodes (harness-call 'session/nodes id)))
        (should (equal '(user assistant tool-call tool-result assistant) (mapcar (lambda (n) (plist-get n :kind)) nodes)))
        (should (equal '(nil (:at "c-text") (:at "c-call") (:at "c-result") (:at "c-done"))
                       (mapcar (lambda (n) (plist-get n :checkpoint)) nodes)))
        (should (equal (plist-get (car (last nodes)) :id)
                       (plist-get (harness-call 'session/get id) :provider-node)))))))

(ert-deftest harness-agent-rewinds-the-provider-conversation-to-the-head ()
  "A turn after a checkout gets the provider conversation cut at the head.
The head moved back to the first reply: the next request brings the
provider's fork of its conversation at that reply's checkpoint, which
the session keeps.  At the first message, before any checkpoint, the
request brings no state at all: the provider starts anew."
  (harness-agent-test-with
    (harness-agent-test-define-hosted
     (lambda (prompt)
       (list (list :type 'provider-state :state (list :conv prompt))
             '(:type text :delta "ok")
             (list :type 'checkpoint :checkpoint (list :at prompt))
             '(:type done :stop-reason end-turn)))
     (lambda (_model _state &optional checkpoint) (harness-resolved (and checkpoint (list :cut checkpoint)))))
    (let* ((id (harness-agent-test-hosted-session))
           (states nil)
           (watch (harness-on 'session/provider-state-changed (lambda (_sid state) (push state states))))
           (state-sent (lambda () (plist-get (car (last harness-agent-test-requests)) :provider-state))))
      (harness-await (harness-call 'agent/prompt id "one"))
      (let ((u1 (plist-get (car (harness-call 'session/nodes id)) :id))
            (a1 (plist-get (cadr (harness-call 'session/nodes id)) :id)))
        (harness-await (harness-call 'agent/prompt id "two"))
        (should (equal '(:conv "one" :provider "hosted") (funcall state-sent)))
        ;; Back to the first reply.
        (harness-call 'session/set-head id a1)
        (setq states nil)
        (harness-await (harness-call 'agent/prompt id "three"))
        (should (equal '(:cut (:at "one") :provider "hosted") (funcall state-sent)))
        (should (equal "three" (car (last harness-agent-test-prompts))))
        (should (equal (list '(:conv "three" :provider "hosted") '(:cut (:at "one") :provider "hosted")) states))
        ;; The next turn goes on in the conversation the last one left.
        (harness-await (harness-call 'agent/prompt id "four"))
        (should (equal '(:conv "three" :provider "hosted") (funcall state-sent)))
        ;; Back to the first message: nothing to cut at.
        (harness-call 'session/set-head id u1)
        (harness-await (harness-call 'agent/prompt id "five"))
        (should-not (funcall state-sent))
        (should (equal "one\nfive" (car (last harness-agent-test-prompts))))
        (should (equal (plist-get (harness-call 'session/get id) :head)
                       (plist-get (harness-call 'session/get id) :provider-node))))
      (harness-off watch))))

(provide 'harness-agent-test)
;;; harness-agent-test.el ends here
