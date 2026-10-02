;;; harness-acp-test.el --- Tests for the ACP local transport  -*- lexical-binding: t; -*-

;;; Commentary:

;; Drives the in-process ACP connection end to end against the real
;; state layer with the demo provider: standard methods, streaming
;; updates, extension calls, error codes, wire normalisation and the
;; permission / ask-user round trips.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-acp-test-messages nil
  "Every (METHOD PARAMS RESPOND) the primary connection's handler received, newest first.")

(defmacro harness-acp-test-with (&rest body)
  "Load the state layer, the demo provider and the ACP module, then run BODY."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (setq harness-acp--clients nil
           harness-acp-test-messages nil)
     (let ((harness-provider-demo-delay 0.005)
           (harness-acp-token nil)
           (default-directory dir))
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (harness-define-tool "list_dir" :label "List directory" :description "list" :kind 'read
                            :handler (lambda (input _ctx) (format "listing of %s" (plist-get input :path))))
       (unwind-protect
           (progn ,@body)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-acp-test-connect ()
  "Return a local connection whose handler records into `harness-acp-test-messages'."
  (let ((conn (harness-acp-connect)))
    (harness-acp-set-handler conn (lambda (method params respond)
                                    (push (list method params respond) harness-acp-test-messages)))
    conn))

(defun harness-acp-test-request (conn method params)
  "Await the result of METHOD with PARAMS over CONN."
  (harness-test-await (harness-acp-request conn method params)))

(defun harness-acp-test-error (conn method params)
  "Return the (CODE MESSAGE DATA) rejection of METHOD with PARAMS over CONN."
  (condition-case err
      (progn (harness-acp-test-request conn method params) nil)
    (acp-error (cdr err))))

(defun harness-acp-test-updates (&optional messages)
  "Return the session/update objects in MESSAGES (default the primary log), oldest first."
  (let (out)
    (dolist (m (or messages harness-acp-test-messages) out)
      (when (equal (car m) "session/update")
        (push (plist-get (cadr m) :update) out)))))

(defun harness-acp-test-kinds (&optional messages)
  "Return the sessionUpdate kinds seen, oldest first."
  (mapcar (lambda (u) (plist-get u :sessionUpdate)) (harness-acp-test-updates messages)))

(defun harness-acp-test-new-session (conn)
  "Create a demo session over CONN and return its id."
  (plist-get (harness-acp-test-request conn "session/new"
                                       (list :cwd (harness-test-temp-dir)
                                             :_harness (list :model "demo:scripted")))
             :sessionId))

(defun harness-acp-test-prompt (conn sid text)
  "Prompt session SID with TEXT over CONN and return the result."
  (harness-acp-test-request conn "session/prompt"
                            (list :sessionId sid :prompt (list (list :type "text" :text text)))))

;;;; Handshake and session lifecycle

(ert-deftest harness-acp-local-initialize ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (r (harness-test-await (harness-acp-initialize conn))))
      (should (harness-acp-connection-p conn))
      (should (harness-acp-connected-p conn))
      (should-not (harness-acp-connection-address conn))
      (should (= 1 (plist-get r :protocolVersion)))
      (should (equal "emacs-agent-harness" (plist-get (plist-get r :agentInfo) :name)))
      (should (eq t (plist-get (plist-get r :agentCapabilities) :loadSession)))
      (let ((methods (plist-get (plist-get r :_harness) :methods)))
        (should (member "session/list" methods))
        (should (member "agent/prompt" methods))
        (should (member "harness/api" methods))
        (should-not (member "store/save" methods))
        (should-not (member "acp/stop" methods)))
      (should (member "session/node-added" (plist-get (plist-get r :_harness) :events)))
      (should (equal '(:running :false) (seq-take (harness-call 'acp/status) 2))))))

(ert-deftest harness-acp-local-session-new-prompt-streams ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (r (harness-acp-test-request conn "session/new"
                                        (list :cwd (harness-test-temp-dir)
                                              :_harness (list :model "demo:scripted" :name "Tour"))))
           (sid (plist-get r :sessionId)))
      (should (stringp sid))
      (should (equal "ask" (plist-get (plist-get r :modes) :currentModeId)))
      (should (equal '("ask" "accept-edits" "auto" "yolo")
                     (mapcar (lambda (m) (plist-get m :id)) (plist-get (plist-get r :modes) :availableModes))))
      (should (equal "Tour" (plist-get (harness-call 'session/get sid) :name)))
      (should (equal "demo:scripted" (plist-get (harness-call 'session/get sid) :model)))
      (let ((result (harness-acp-test-prompt conn sid "give me the tour")))
        (should (equal "end_turn" (plist-get result :stopReason)))
        (should (equal "end-turn" (plist-get (plist-get result :_harness) :reason))))
      ;; The debounced session push and the queued notifications land shortly after.
      (harness-test-wait (lambda () (cl-some (lambda (u) (and (equal (plist-get u :sessionUpdate) "_harness/session")
                                                              (equal "idle" (plist-get (plist-get u :session) :status))))
                                             (harness-acp-test-updates)))
                         5 "_harness/session idle")
      (let* ((kinds (harness-acp-test-kinds))
             (pos (lambda (k &optional from-end)
                    (if from-end (cl-position k kinds :test #'equal :from-end t)
                      (cl-position k kinds :test #'equal)))))
        (dolist (k '("agent_thought_chunk" "agent_message_chunk" "tool_call" "tool_call_update"
                     "_harness/node" "_harness/session" "user_message_chunk"))
          (should (member k kinds)))
        (should (< (funcall pos "user_message_chunk") (funcall pos "agent_thought_chunk")))
        (should (< (funcall pos "agent_thought_chunk") (funcall pos "agent_message_chunk")))
        (should (< (funcall pos "agent_message_chunk") (funcall pos "tool_call")))
        (should (< (funcall pos "tool_call") (funcall pos "tool_call_update")))
        (should (< (funcall pos "tool_call_update") (funcall pos "agent_message_chunk" t))))
      (let* ((updates (harness-acp-test-updates))
             (call (cl-find "tool_call" updates :key (lambda (u) (plist-get u :sessionUpdate)) :test #'equal))
             (done (cl-find "tool_call_update" updates :key (lambda (u) (plist-get u :sessionUpdate)) :test #'equal))
             (thought (cl-find "agent_thought_chunk" updates :key (lambda (u) (plist-get u :sessionUpdate)) :test #'equal)))
        (should (equal "demo-1" (plist-get call :toolCallId)))
        (should (equal "read" (plist-get call :kind)))
        (should (equal "in_progress" (plist-get call :status)))
        (should (stringp (plist-get call :title)))
        (should (stringp (plist-get (plist-get call :_harness) :nodeId)))
        (should (equal "demo-1" (plist-get done :toolCallId)))
        (should (equal "completed" (plist-get done :status)))
        (should (string-match-p "listing of" (plist-get done :rawOutput)))
        (should (equal "text" (plist-get (plist-get (car (plist-get done :content)) :content) :type)))
        (should (equal "text" (plist-get (plist-get thought :content) :type)))
        (should (string-match-p "tour" (plist-get (plist-get thought :content) :text))))
      ;; Every session/update names the session; the user node arrived as a wire-shaped node.
      (dolist (m harness-acp-test-messages)
        (when (equal (car m) "session/update")
          (should (equal sid (plist-get (cadr m) :sessionId)))))
      (let ((first-node (cl-find "_harness/node" (harness-acp-test-updates)
                                 :key (lambda (u) (plist-get u :sessionUpdate)) :test #'equal)))
        (should (equal "user" (plist-get (plist-get first-node :node) :kind))))
      ;; Bus events are forwarded as _harness/event.
      (let ((events (mapcar (lambda (m) (plist-get (cadr m) :event))
                            (cl-remove-if-not (lambda (m) (equal (car m) "_harness/event")) harness-acp-test-messages))))
        (should (member "session/created" events))
        (should (member "agent/turn-started" events))
        (should (member "agent/turn-ended" events))
        (should-not (member "session/node-added" events)))
      (let ((ended (cl-find-if (lambda (m) (and (equal (car m) "_harness/event")
                                                (equal "agent/turn-ended" (plist-get (cadr m) :event))))
                               harness-acp-test-messages)))
        (should (equal (list sid "end-turn") (plist-get (cadr ended) :args)))))))

(defvar harness-provider-demo-script-override)
(defvar harness-provider-demo-delay)

(ert-deftest harness-acp-local-activity-updates ()
  "What a running turn does reaches clients as it changes, and can be asked."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (harness-provider-demo-delay 0.2)
           (harness-provider-demo-script-override
            '((:type activity :phase thinking)
              (:type text :delta "Looking.")
              (:type tool-call :id "a1" :name "list_dir" :input (:path "/tmp"))
              (:type text :delta "Done.")
              (:type done :stop-reason end-turn)))
           (activities (lambda ()
                         (mapcar (lambda (u) (plist-get u :activity))
                                 (cl-remove-if-not (lambda (u) (equal (plist-get u :sessionUpdate) "_harness/activity"))
                                                   (harness-acp-test-updates))))))
      (harness-acp-request conn "session/prompt" (list :sessionId sid :prompt '((:type "text" :text "go"))))
      (harness-test-wait (lambda () (cl-find "thinking" (funcall activities) :key (lambda (a) (plist-get a :phase))
                                             :test #'equal))
                         5 "thinking")
      ;; A client that opens now asks what the turn does.
      (let ((now (harness-acp-test-request conn "_harness/agent/activity" (list :session-id sid))))
        (should (equal "thinking" (plist-get now :phase)))
        (should (numberp (plist-get now :since))))
      (harness-test-wait (lambda () (let ((all (funcall activities))) (and all (null (car (last all))))))
                         10 "the turn's end")
      (let* ((all (funcall activities))
             (phases (mapcar (lambda (a) (plist-get a :phase)) all))
             (tool (cl-find "tool" all :key (lambda (a) (plist-get a :phase)) :test #'equal)))
        ;; Wire shape: phases are strings, the tool is named.
        (should (equal "waiting" (car phases)))
        (dolist (p '("thinking" "writing" "tool"))
          (should (member p phases)))
        (should (equal "list_dir" (plist-get tool :tool))))
      (should-not (harness-acp-test-request conn "_harness/agent/activity" (list :session-id sid))))))

(ert-deftest harness-acp-local-cancel ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (harness-provider-demo-delay 0.2)
           (p (harness-acp-request conn "session/prompt"
                                   (list :sessionId sid :prompt (list (list :type "text" :text "tour"))))))
      (harness-test-wait (lambda () (harness-agent-running-p sid)))
      (harness-acp-notify conn "session/cancel" (list :sessionId sid))
      (should (equal "cancelled" (plist-get (harness-test-await p) :stopReason)))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status))))))

(ert-deftest harness-acp-local-set-mode-and-model ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn)))
      (should (null (harness-acp-test-request conn "session/set_mode" (list :sessionId sid :modeId "accept-edits"))))
      (should (eq 'accept-edits (plist-get (harness-call 'session/get sid) :permission-mode)))
      (harness-test-wait (lambda () (member "current_mode_update" (harness-acp-test-kinds))))
      (let ((u (cl-find "current_mode_update" (harness-acp-test-updates)
                        :key (lambda (u) (plist-get u :sessionUpdate)) :test #'equal)))
        (should (equal "accept-edits" (plist-get u :currentModeId))))
      (should (= -32602 (car (harness-acp-test-error conn "session/set_mode" (list :sessionId sid :modeId "chaos")))))
      (harness-acp-test-request conn "session/set_model" (list :sessionId sid :modelId "demo:other"))
      (should (equal "demo:other" (plist-get (harness-call 'session/get sid) :model))))))

(ert-deftest harness-acp-local-load-replays-transcript ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn)))
      (harness-acp-test-prompt conn sid "give me the tour")
      (let* ((seen nil)
             (other (harness-acp-connect)))
        (harness-acp-set-handler other (lambda (method params _respond) (push (list method params) seen)))
        (should (null (harness-acp-test-request other "session/load" (list :sessionId sid))))
        (let* ((nodes (harness-call 'session/nodes sid))
               (kinds (harness-acp-test-kinds seen)))
          (should (equal '(user thinking assistant tool-call tool-result assistant)
                         (mapcar (lambda (n) (plist-get n :kind)) nodes)))
          (should (equal '("user_message_chunk" "_harness/node"
                           "agent_thought_chunk" "_harness/node"
                           "agent_message_chunk" "_harness/node"
                           "tool_call" "_harness/node"
                           "tool_call_update" "_harness/node"
                           "agent_message_chunk" "_harness/node"
                           "_harness/session")
                         kinds))
          (let ((chunk (nth 4 (harness-acp-test-updates seen))))
            (should (string-match-p "look at the project" (plist-get (plist-get chunk :content) :text)))))
        (harness-acp-close other)))))

;;;; Extension methods

(ert-deftest harness-acp-local-extension-calls ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn)))
      (should (equal (list sid) (mapcar (lambda (s) (plist-get s :id))
                                        (harness-acp-test-request conn "_harness/session/list" nil))))
      ;; Enum values arrive as strings and are interned before the bus sees them.
      (should (= 1 (length (harness-acp-test-request conn "_harness/session/list" '(:filter (:status "idle"))))))
      (should (= 0 (length (harness-acp-test-request conn "_harness/session/list" '(:filter (:status "running"))))))
      (should (equal sid (plist-get (harness-acp-test-request conn "_harness/session/get" (list :id sid)) :id)))
      ;; Explicit positional form.
      (should (equal sid (plist-get (harness-acp-test-request conn "_harness/session/get" (list :args (list sid))) :id)))
      ;; &rest plist mapping: every remaining key goes to the method's plist.
      (let ((s (harness-acp-test-request conn "_harness/session/update" (list :id sid :name "Renamed" :silent t))))
        (should (equal "Renamed" (plist-get s :name)))
        (should (equal "Renamed" (plist-get (harness-call 'session/get sid) :name))))
      ;; camelCase keys map onto kebab-case argument names.
      (let ((tools (harness-acp-test-request conn "_harness/tools/list" (list :sessionId sid))))
        (should (equal '("list_dir") (mapcar (lambda (tl) (plist-get tl :name)) tools)))
        (should (equal "read" (plist-get (car tools) :kind)))
        ;; With the name people read, which UIs show for it.
        (should (equal "List directory" (plist-get (car tools) :label))))
      (let ((api (harness-acp-test-request conn "_harness/harness/api" nil)))
        (should (member "session/get" (mapcar (lambda (m) (plist-get m :name)) (plist-get api :methods))))
        (should (cl-every #'stringp (plist-get api :filters))))
      (should (equal harness-version (plist-get (harness-acp-test-request conn "_harness/harness/version" nil) :version)))
      (should (eq t (plist-get (harness-acp-test-request conn "_harness/agent/prompt"
                                                          (list :sessionId sid :blocks "hello" :opts '(:queue t)))
                               :queued)))
      (should (= 1 (length (plist-get (harness-call 'session/get sid) :queue)))))))

(defvar harness-provider-demo-script-override)

(ert-deftest harness-acp-local-queue-while-running ()
  "What `harness-chat-queue' sends while a turn runs only queues: it never steers.
Once the turn ends the message runs as a turn of its own."
  (harness-acp-test-with
    (let* ((gate (harness-make-promise))
           (harness-provider-demo-script-override
            '((:type tool-call :id "w1" :name "hold" :input (:n 1))
              (:type text :delta "Done.")
              (:type done :stop-reason end-turn)))
           (conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (file (make-temp-file "harness-acp-queued" nil ".txt" "x"))
           (p (progn
                ;; The turn waits in this tool until the test lets it go.
                (harness-define-tool "hold" :label "Hold" :description "hold" :kind 'read
                                     :handler (lambda (_input _ctx) (harness-then gate (lambda (_) "held"))))
                (harness-acp-request conn "session/prompt"
                                     (list :sessionId sid :prompt (list (list :type "text" :text "tour")))))))
      (harness-test-wait (lambda () (memq 'tool-call (mapcar (lambda (n) (plist-get n :kind))
                                                             (harness-call 'session/nodes sid))))
                         5 "the turn in its tool")
      (should (eq t (plist-get (harness-acp-test-request
                                conn "_harness/agent/prompt"
                                (list :session-id sid :blocks (list (list :type "text" :text "for later"))
                                      :opts (list :queue t :attachments (list (list :path file :size 1 :mime "text/plain"
                                                                                    :name "notes.txt")))))
                               :queued)))
      (let ((queue (plist-get (harness-call 'session/get sid) :queue)))
        (should (equal '("for later") (mapcar (lambda (it) (plist-get it :text)) queue)))
        (should (equal (list file) (mapcar (lambda (a) (plist-get a :path)) (plist-get (car queue) :attachments)))))
      (should (harness-agent-running-p sid))
      (should-not (cl-find-if (lambda (n) (plist-get (plist-get n :meta) :steering)) (harness-call 'session/nodes sid)))
      (harness-resolve gate t)
      (should (equal "end_turn" (plist-get (harness-test-await p) :stopReason)))
      (harness-test-wait (lambda () (and (null (plist-get (harness-call 'session/get sid) :queue))
                                         (not (harness-agent-running-p sid))))
                         10 "the queued turn")
      (let ((users (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes sid))))
        (should (equal (list "tour" (concat "for later @" (file-name-nondirectory file)))
                       (mapcar (lambda (n) (plist-get n :content)) users)))
        (should-not (cl-some (lambda (n) (plist-get (plist-get n :meta) :steering)) users)))
      ;; Sending the queue with nothing in it is a no-op.
      (should (equal "nothing-queued" (plist-get (harness-acp-test-request conn "_harness/agent/send-queue"
                                                                           (list :session-id sid))
                                                 :stop-reason)))
      (should-not (harness-agent-running-p sid)))))

(ert-deftest harness-acp-local-wire-normalisation ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (s (harness-acp-test-request conn "_harness/session/get" (list :id sid))))
      (should (eq 'idle (plist-get (harness-call 'session/get sid) :status)))
      (should (equal "idle" (plist-get s :status)))
      (should (equal "main" (plist-get s :kind)))
      (should (equal "ask" (plist-get s :permission-mode)))
      (should (numberp (plist-get (plist-get s :usage) :input)))
      (harness-call 'session/hint sid "a hint")
      (harness-test-wait (lambda () (member "_harness/node" (harness-acp-test-kinds))))
      (let ((node (plist-get (car (last (harness-acp-test-updates))) :node)))
        (should (equal "hint" (plist-get node :kind)))
        (should (equal "a hint" (plist-get node :content)))
        (should (equal sid (plist-get node :session)))))))

(ert-deftest harness-acp-local-errors ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn)))
      (should (= -32601 (car (harness-acp-test-error conn "nope/x" nil))))
      (should (= -32601 (car (harness-acp-test-error conn "_harness/store/save" '(:name "x" :obj nil)))))
      (should (= -32601 (car (harness-acp-test-error conn "_harness/session/not-a-method" nil))))
      (let ((e (harness-acp-test-error conn "_harness/session/get" nil)))
        (should (= -32602 (car e)))
        (should (string-match-p "id" (cadr e))))
      (should (= -32602 (car (harness-acp-test-error conn "_harness/session/get" (list :id sid :bogus 1)))))
      (should (= -32602 (car (harness-acp-test-error conn "session/new" nil))))
      (should (= -32602 (car (harness-acp-test-error conn "session/prompt" '(:prompt nil)))))
      (let ((e (harness-acp-test-error conn "_harness/session/get" '(:id "missing"))))
        (should (= -32000 (car e)))
        (should (string-match-p "No session" (cadr e)))))))

;;;; Requests from the agent to the client

(ert-deftest harness-acp-local-permission-round-trip ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (recorded nil)
           (second-respond nil)
           (other (harness-acp-connect)))
      (harness-register-method 'permission/answer
                               (lambda (s pid answer) (push (list s pid answer) recorded) answer))
      ;; A second client receives the same request; it answers later and must be ignored.
      (harness-acp-set-handler other (lambda (method _params respond)
                                       (when (equal method "session/request_permission")
                                         (setq second-respond respond))))
      (harness-emit 'permission/requested sid
                    (list :id "p1" :kind 'permission
                          :payload (list :tool "bash" :input '(:command "ls") :kind 'exec
                                         :title "bash ls" :call-id "c1" :paths '("/tmp"))))
      (harness-test-wait (lambda () (cl-find "session/request_permission" harness-acp-test-messages :key #'car :test #'equal)))
      (let* ((m (cl-find "session/request_permission" harness-acp-test-messages :key #'car :test #'equal))
             (params (nth 1 m)) (respond (nth 2 m)))
        (should (functionp respond))
        (should (equal sid (plist-get params :sessionId)))
        (should (equal "c1" (plist-get (plist-get params :toolCall) :toolCallId)))
        (should (equal "execute" (plist-get (plist-get params :toolCall) :kind)))
        (should (equal "bash ls" (plist-get (plist-get params :toolCall) :title)))
        (should (equal '(:command "ls") (plist-get (plist-get params :toolCall) :rawInput)))
        (should (equal '("allow-once" "allow-session" "allow-always" "deny-once" "deny-always")
                       (mapcar (lambda (o) (plist-get o :optionId)) (plist-get params :options))))
        (should (equal "p1" (plist-get (plist-get params :_harness) :pendingId)))
        (should (equal '("/tmp") (plist-get (plist-get params :_harness) :paths)))
        (funcall respond (list :outcome (list :outcome "selected" :optionId "allow-session"))))
      (harness-test-wait (lambda () recorded))
      (should (equal (list (list sid "p1" '(:behavior allow :scope session))) recorded))
      (harness-test-wait (lambda () second-respond))
      (funcall second-respond (list :outcome (list :outcome "selected" :optionId "deny-always")))
      (accept-process-output nil 0.05)
      (should (= 1 (length recorded)))
      (harness-acp-close other)
      ;; A cancelled outcome denies once.
      (harness-emit 'permission/requested sid (list :id "p2" :kind 'permission :payload (list :tool "bash" :kind 'exec)))
      (harness-test-wait (lambda () (= 2 (cl-count "session/request_permission" harness-acp-test-messages :key #'car :test #'equal))))
      (funcall (nth 2 (car harness-acp-test-messages)) (list :outcome (list :outcome "cancelled")))
      (harness-test-wait (lambda () (= 2 (length recorded))))
      (should (equal (list sid "p2" '(:behavior deny :scope once)) (car recorded))))))

(ert-deftest harness-acp-local-directory-permission-options ()
  "A directory prompt is worded for directories and offers only the payload's options."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (option-ids (lambda (pid)
                         (harness-test-wait
                          (lambda () (cl-find-if (lambda (m) (and (equal (car m) "session/request_permission")
                                                                  (equal pid (plist-get (plist-get (nth 1 m) :_harness)
                                                                                        :pendingId))))
                                                 harness-acp-test-messages)))
                         (let ((m (cl-find-if (lambda (m) (equal pid (plist-get (plist-get (nth 1 m) :_harness) :pendingId)))
                                              harness-acp-test-messages)))
                           (mapcar (lambda (o) (plist-get o :optionId)) (plist-get (nth 1 m) :options))))))
      ;; The jail's prompt: every directory option.
      (harness-emit 'permission/requested sid
                    (list :id "j1" :kind 'permission
                          :payload (list :tool "read_file" :kind 'read :dir "/srv/data/"
                                         :options '(allow-once allow-session allow-always deny-once))))
      (should (equal '("allow-once" "allow-session" "allow-always" "deny-once") (funcall option-ids "j1")))
      ;; An agent's own request has no "allow once".
      (harness-emit 'permission/requested sid
                    (list :id "r1" :kind 'permission
                          :payload (list :tool "request_directory_access" :kind 'meta :dir "/srv/data/"
                                         :reason "The agent asks for access: read the data"
                                         :options '(allow-session allow-always deny-once))))
      (should (equal '("allow-session" "allow-always" "deny-once") (funcall option-ids "r1")))
      (let ((m (cl-find-if (lambda (m) (equal "r1" (plist-get (plist-get (nth 1 m) :_harness) :pendingId)))
                           harness-acp-test-messages)))
        (should (equal "Allow directory for this session"
                       (plist-get (car (plist-get (nth 1 m) :options)) :name)))
        (should (equal "/srv/data/" (plist-get (plist-get (nth 1 m) :_harness) :dir)))
        (should (string-match-p "read the data" (plist-get (plist-get (nth 1 m) :_harness) :reason)))))))

(ert-deftest harness-acp-local-ask-user-round-trip ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (recorded nil))
      (harness-register-method 'question/answer
                               (lambda (s pid answer) (push (list s pid answer) recorded) answer))
      (harness-emit 'question/asked sid
                    (list :id "q1" :kind 'question
                          :payload (list :question "Which colour?" :options '("red" "green"))))
      (harness-test-wait (lambda () (cl-find "_harness/ask_user" harness-acp-test-messages :key #'car :test #'equal)))
      (let* ((m (cl-find "_harness/ask_user" harness-acp-test-messages :key #'car :test #'equal))
             (params (nth 1 m)))
        (should (equal sid (plist-get params :sessionId)))
        (should (equal "q1" (plist-get params :requestId)))
        (should (equal "Which colour?" (plist-get params :question)))
        (should (equal '("red" "green") (plist-get params :options)))
        (funcall (nth 2 m) (list :answer "green")))
      (harness-test-wait (lambda () recorded))
      (should (equal (list (list sid "q1" "green")) recorded)))))

(ert-deftest harness-acp-local-request-without-client-stays-pending ()
  (harness-acp-test-with
    (let* ((warned nil)
           (hook (lambda (level msg) (when (eq level 'warn) (push msg warned)))))
      (add-hook 'harness-log-hook hook)
      (unwind-protect
          (progn
            (harness-emit 'permission/requested "s" (list :id "p" :kind 'permission :payload (list :tool "bash")))
            (should (cl-some (lambda (m) (string-match-p "no client" m)) warned)))
        (remove-hook 'harness-log-hook hook)))))

;;;; Connection lifecycle

(ert-deftest harness-acp-local-close ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (closed nil))
      (harness-acp-on-close conn (lambda () (setq closed t)))
      (should (= 1 (length harness-acp--clients)))
      (harness-acp-close conn)
      (should-not (harness-acp-connected-p conn))
      (should (= 0 (length harness-acp--clients)))
      (harness-test-wait (lambda () closed))
      (should (= -32003 (car (harness-acp-test-error conn "_harness/harness/version" nil))))
      ;; A closed client no longer receives anything.
      (setq harness-acp-test-messages nil)
      (harness-call 'session/create :cwd (harness-test-temp-dir))
      (accept-process-output nil 0.05)
      (should (null harness-acp-test-messages)))))

(ert-deftest harness-acp-local-callbacks-are-deferred ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (settled-inside nil)
           (p (harness-acp-request conn "_harness/harness/version" nil)))
      (harness-then p (lambda (_) (setq settled-inside t)))
      ;; The method ran synchronously but the promise settles from the command loop.
      (should-not settled-inside)
      (harness-test-await p)
      (should settled-inside))))

(provide 'harness-acp-test)
;;; harness-acp-test.el ends here
