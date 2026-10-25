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
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (clrhash harness-acp--virtual-state)
     (setq harness-acp--clients nil
           harness-acp-test-messages nil)
     (let ((harness-provider-demo--delay 0.005)
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
      ;; ACP's own session/list is offered: `list' is there, an empty
      ;; object on the wire and so nil in-process.
      (let ((capabilities (plist-get (plist-get r :agentCapabilities) :sessionCapabilities)))
        (should (plist-member capabilities :list))
        (should (null (plist-get capabilities :list))))
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
(defvar harness-provider-demo--delay)

(ert-deftest harness-acp-local-activity-updates ()
  "What a running turn does reaches clients as it changes, and can be asked."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (harness-provider-demo--delay 0.2)
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
           (harness-provider-demo--delay 0.2)
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

(ert-deftest harness-acp-local-set-all-sessions-model ()
  "One call retargets every session and can set the default for new ones."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (one (harness-acp-test-new-session conn))
           (two (harness-acp-test-new-session conn)))
      ;; A session already on the model is left alone, so it is not in the answer.
      (harness-acp-test-request conn "session/set_model" (list :sessionId two :modelId "demo:other"))
      (let ((changed (harness-acp-test-request conn "_harness/session/set-all"
                                               (list :settings (list :model "demo:other")))))
        (should (equal (list one) changed))
        (should (equal "demo:other" (plist-get (harness-call 'session/get one) :model)))
        (should (equal "demo:other" (plist-get (harness-call 'session/get two) :model))))
      ;; The default for sessions created without an explicit model.
      (harness-acp-test-request conn "_harness/config/set"
                                (list :key "harness-model" :value "demo:other" :scope "global"))
      (should (equal "demo:other" harness-model))
      (let ((fresh (plist-get (harness-acp-test-request conn "session/new"
                                                        (list :cwd (harness-test-temp-dir)))
                              :sessionId)))
        (should (equal "demo:other" (plist-get (harness-call 'session/get fresh) :model)))))))

(ert-deftest harness-acp-local-user-chunk-says-who-sent-it ()
  "A user message the user did not write carries its sender in its chunk's
extension data, for a client that reads chunks rather than nodes."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn)))
      (harness-acp-test-request conn "_harness/session/append"
                                (list :id sid :node (list :kind "user" :content "carry on"
                                                          :meta (list :from (harness-sender-system "tasks")))))
      (let* ((chunk (cl-find "user_message_chunk" (harness-acp-test-updates)
                             :key (lambda (u) (plist-get u :sessionUpdate)) :test #'equal))
             (got (plist-get (plist-get chunk :_harness) :from)))
        (should (eq 'system (harness-sender-kind got)))
        (should (equal "tasks" (plist-get got :source))))
      ;; The user's own message carries no sender.
      (harness-acp-test-request conn "_harness/session/append"
                                (list :id sid :node (list :kind "user" :content "mine")))
      (let* ((chunks (cl-remove-if-not (lambda (u) (equal (plist-get u :sessionUpdate) "user_message_chunk"))
                                       (harness-acp-test-updates)))
             (mine (car (last chunks))))
        (should (equal "mine" (plist-get (plist-get mine :content) :text)))
        (should-not (plist-get (plist-get mine :_harness) :from))))))

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

;;;; What is made while a session loads

;; The replay of a long session to a client that reads slowly waits for room
;; in the socket, and Emacs runs its timers and filters meanwhile: what they
;; write to the client comes between two lines of the replay.  A client of
;; another transport has a writer called for each message, and the writer is
;; where these tests make the changes, as a timer would make them.  Such a
;; client is made after the conversation it loads, so that it is sent the
;; replay and not the nodes as they were appended.

(defun harness-acp-test-wire-client (&optional on-message)
  "Return (CLIENT . LOG): a client of another transport and the texts it was sent.
LOG is a cons whose car is those texts, newest first.  ON-MESSAGE, when
non-nil, is called with each text as it goes out."
  (let* ((log (list nil))
         (client (harness-acp-add-client
                  'test :writer (lambda (_client text)
                                  (push text (car log))
                                  (when on-message (funcall on-message text))))))
    (cons client log)))

(defun harness-acp-test-wire-messages (wire)
  "Return what WIRE, a `harness-acp-test-wire-client', was sent, as plists, oldest first."
  (mapcar #'harness-json-parse (reverse (car (cdr wire)))))

(defun harness-acp-test-wire-load (wire sid)
  "Have the client of WIRE load session SID, and wait for the answer.
Return what it was sent, as `harness-acp-test-wire-messages' says."
  (harness-acp-client-receive
   (car wire) (harness-json-encode (list :jsonrpc "2.0" :id 7 :method "session/load"
                                         :params (list :sessionId sid))))
  (harness-test-wait (lambda () (cl-some (lambda (m) (equal 7 (plist-get m :id)))
                                         (harness-acp-test-wire-messages wire)))
                     5 "the answer to session/load")
  (harness-acp-test-wire-messages wire))

(defun harness-acp-test-wire-trace (messages)
  "Return what MESSAGES say of the transcript, oldest first, a string each.
A node update is \"node TEXT\", TEXT the node's content or tool, the
record of the session is \"session\" and the answer to a request is
\"answer\"; the chunks that go with the nodes are left out."
  (cl-loop for m in messages
           for update = (plist-get (plist-get m :params) :update)
           for kind = (plist-get update :sessionUpdate)
           when (equal kind "_harness/node")
           collect (let ((node (plist-get update :node)))
                     (format "node %s" (or (plist-get node :content) (plist-get node :tool))))
           else when (equal kind "_harness/session") collect "session"
           else when (and (not (plist-get m :method)) (plist-member m :result)) collect "answer"))

(ert-deftest harness-acp-load-sends-what-is-made-while-it-replays-after-it ()
  "A mode toggled while a session's replay goes out is announced after the replay.
Written into the middle of the replay it would stand among nodes older
than it, which a client that takes updates as they come shows there."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (fired nil))
      (harness-call 'session/append sid (list :kind 'user :content "first"))
      (harness-call 'session/hint sid "a note from before")
      (harness-call 'session/append sid (list :kind 'assistant :content "second"))
      (let* ((wire (harness-acp-test-wire-client
                    (lambda (text)
                      ;; Written while the first node goes out: the toggles of
                      ;; a timer that runs while that write waits for room.
                      (when (and (not fired)
                                 (string-match-p "\"content\":\"first\"" text)
                                 (string-match-p "_harness/node" text))
                        (setq fired t)
                        (harness-call 'session/update sid :non-interactive t)
                        (harness-call 'session/update sid :non-interactive :false)))))
             (messages (harness-acp-test-wire-load wire sid))
             (trace (harness-acp-test-wire-trace messages)))
        (should fired)
        ;; The replay in the order of the transcript, the record it ends
        ;; with, then what was made during it in the order it was made, and
        ;; the answer last.
        (should (equal '("node first" "node a note from before" "node second" "session"
                         "node non-interactive on" "node non-interactive off" "answer")
                       trace))
        ;; The transcript has them where they were made: after the rest.
        (should (equal '("first" "a note from before" "second" "non-interactive on" "non-interactive off")
                       (mapcar (lambda (n) (plist-get n :content)) (harness-call 'session/nodes sid))))
        ;; Nothing is held for good: what is made afterwards goes out at once.
        (harness-call 'session/hint sid "after the load")
        (should (equal "node after the load"
                       (car (last (harness-acp-test-wire-trace (harness-acp-test-wire-messages wire))))))))))

(ert-deftest harness-acp-load-holds-back-only-the-session-it-replays-for-that-client ()
  "Another session's updates, and other clients', do not wait for a replay."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (other (harness-acp-test-new-session conn))
           (fired nil))
      (harness-call 'session/append sid (list :kind 'user :content "first"))
      (harness-call 'session/append sid (list :kind 'assistant :content "second"))
      (let* ((bystander (harness-acp-test-wire-client))
             (wire (harness-acp-test-wire-client
                    (lambda (text)
                      (when (and (not fired)
                                 (string-match-p "\"content\":\"first\"" text)
                                 (string-match-p "_harness/node" text))
                        (setq fired t)
                        (harness-call 'session/hint other "elsewhere")
                        (harness-call 'session/hint sid "here")))))
             (messages (harness-acp-test-wire-load wire sid)))
        (should fired)
        ;; The other session's note went out at once, in the middle of the
        ;; replay; this session's came after it.
        (should (equal '("node first" "node elsewhere" "node second" "session" "node here" "answer")
                       (harness-acp-test-wire-trace messages)))
        ;; A client that was not loading got both as they were made.
        (should (equal '("node elsewhere" "node here")
                       (harness-acp-test-wire-trace (harness-acp-test-wire-messages bystander))))))))

(ert-deftest harness-acp-load-lets-go-of-what-it-holds-when-the-replay-fails ()
  "A replay that goes wrong still sends what was held, and holds nothing after."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn)))
      (harness-call 'session/append sid (list :kind 'user :content "first"))
      (let* ((wire (harness-acp-test-wire-client))
             (updates (symbol-function 'harness-acp--node-updates)))
        (cl-letf (((symbol-function 'harness-acp--node-updates)
                   (lambda (node live)
                     (if live
                         (funcall updates node live)
                       ;; Made during the replay, which then fails.
                       (harness-call 'session/hint sid "made during it")
                       (error "No replay today")))))
          (should-error (funcall (gethash "session/load" harness-acp--standard-methods)
                                 (car wire) (list :sessionId sid))))
        (should (equal '("node made during it")
                       (harness-acp-test-wire-trace (harness-acp-test-wire-messages wire))))
        (should-not (harness-acp--client-get (car wire) 'replaying))
        (harness-call 'session/hint sid "later")
        (should (equal '("node made during it" "node later")
                       (harness-acp-test-wire-trace (harness-acp-test-wire-messages wire))))))))

;;;; ACP's session/list

;; The standard method, which a client written for ACP calls; the harness's
;; own `_harness/session/list' is tested with the extension methods.

(defvar harness-sessions)

(defun harness-acp-test-make-session (updated &rest props)
  "Make a session from PROPS, as `session/create' takes them; return its id.
It last changed at UPDATED, a time in seconds: sessions made one after
the other differ only by the microseconds between them, and a test of
their order says which is newer."
  (let ((sid (plist-get (apply #'harness-call 'session/create :model "demo:scripted" props) :id)))
    ;; The record is a struct this file cannot name while it loads: the
    ;; session module is not loaded then.
    (aset (gethash sid harness-sessions) (cl-struct-slot-offset 'harness-session 'updated) updated)
    sid))

(defun harness-acp-test-list (conn &optional params)
  "Return the answer to ACP's `session/list' with PARAMS over CONN."
  (harness-acp-test-request conn "session/list" params))

(defun harness-acp-test-all-listed (result)
  "Return the ids of every session RESULT, an answer to `session/list', lists."
  (mapcar (lambda (info) (plist-get info :sessionId)) (plist-get result :sessions)))

(defun harness-acp-test-listed (result)
  "Return the ids of the real sessions RESULT, an answer to `session/list', lists.
The virtual sessions a first page ends with are left out."
  (cl-remove-if #'harness-acp--virtual-session-p (harness-acp-test-all-listed result)))

(ert-deftest harness-acp-session-list-empty ()
  "With no session the answer lists only the virtual sessions, as an array,
and has no next page; a page past the last session lists none."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (result (harness-acp-test-list conn))
           (virtual (mapcar #'car harness-acp--virtual-sessions))
           (other (harness-test-temp-dir)))
      (should (plist-member result :sessions))
      (should (null (harness-acp-test-listed result)))
      (should (equal virtual (harness-acp-test-all-listed result)))
      (should-not (plist-member result :nextCursor))
      ;; The virtual sessions are in the directory a client asks about.
      (should (equal (list other other)
                     (mapcar (lambda (info) (plist-get info :cwd))
                             (plist-get (harness-acp-test-list conn (list :cwd (directory-file-name other)))
                                        :sessions))))
      ;; Parameters it does not know are ignored.
      (should-not (plist-member (harness-acp-test-list conn '(:_meta (:x 1) :other t)) :nextCursor))
      ;; On the wire an empty list is [], not null, which a client would
      ;; take for no list: a page past the last session, which the
      ;; virtual sessions are not on either, is one.
      (should (equal "{\"sessions\":[]}"
                     (harness-json-encode
                      (funcall (gethash "session/list" harness-acp--standard-methods) nil
                               (list :cursor (harness-acp--list-cursor '(0 . "s"))))))))))

(ert-deftest harness-acp-session-list-describes-the-sessions-newest-first ()
  "Each session is a SessionInfo, the newest first; the rest is in `_meta'."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (dir (harness-test-temp-dir))
           (other (harness-test-temp-dir))
           (old (harness-acp-test-make-session 1790000000 :cwd dir :name "Old one"))
           (new (harness-acp-test-make-session 1790003600 :cwd other))
           (child (harness-acp-test-make-session 1790001800 :cwd dir :name "  "
                                                 :kind 'subagent :parent-id old))
           (result (harness-acp-test-list conn))
           (infos (plist-get result :sessions)))
      (should (equal (list new child old) (harness-acp-test-listed result)))
      (should-not (plist-member result :nextCursor))
      (let ((info (nth 2 infos)))
        (should (equal dir (plist-get info :cwd)))
        (should (equal "Old one" (plist-get info :title)))
        ;; ISO 8601, in UTC.
        (should (equal "2026-09-21T14:13:20Z" (plist-get info :updatedAt)))
        (should (equal "idle" (plist-get (plist-get info :_meta) :status)))
        (should (equal "main" (plist-get (plist-get info :_meta) :kind)))
        (should (equal "demo:scripted" (plist-get (plist-get info :_meta) :model)))
        (should (equal (plist-get (harness-call 'session/get old) :project)
                       (plist-get (plist-get info :_meta) :project)))
        (should-not (plist-member (plist-get info :_meta) :parentId)))
      ;; A session with no name (a blank one is none) has no title; one a
      ;; session made names it.
      (let ((info (nth 1 infos)))
        (should-not (plist-member info :title))
        (should (equal "2026-09-21T14:43:20Z" (plist-get info :updatedAt)))
        (should (equal "subagent" (plist-get (plist-get info :_meta) :kind)))
        (should (equal old (plist-get (plist-get info :_meta) :parentId))))
      (should (equal other (plist-get (car infos) :cwd)))
      (should (equal "2026-09-21T15:13:20Z" (plist-get (car infos) :updatedAt)))
      (should (equal '(:sessionId :cwd :updatedAt :_meta) (harness-plist-keys (car infos)))))))

(ert-deftest harness-acp-session-list-includes-the-inactive-and-loading-one-wakes-it ()
  "A session that is not open anywhere is listed, for `session/load' to resume."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-make-session 100 :cwd (harness-test-temp-dir)))
           (status (lambda ()
                     (plist-get (plist-get (car (plist-get (harness-acp-test-list conn) :sessions)) :_meta)
                                :status))))
      (harness-call 'session/deactivate sid)
      (should (equal sid (car (harness-acp-test-listed (harness-acp-test-list conn)))))
      (should (equal "inactive" (funcall status)))
      (harness-acp-test-request conn "session/load" (list :sessionId sid))
      (should (equal "idle" (funcall status))))))

(ert-deftest harness-acp-session-list-filters-by-cwd ()
  "Only the sessions of the directory `cwd' names are listed, slash or not."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (dir (harness-test-temp-dir))
           (other (harness-test-temp-dir))
           (a (harness-acp-test-make-session 300 :cwd dir))
           (b (harness-acp-test-make-session 200 :cwd other))
           (c (harness-acp-test-make-session 100 :cwd dir))
           (listed (lambda (cwd) (harness-acp-test-listed (harness-acp-test-list conn (list :cwd cwd))))))
      (should (equal (list a b c) (harness-acp-test-listed (harness-acp-test-list conn))))
      (should (equal (list a c) (funcall listed dir)))
      ;; Clients mostly name a directory without its slash.
      (should (equal (list a c) (funcall listed (directory-file-name dir))))
      (should (equal (list b) (funcall listed (directory-file-name other))))
      ;; The same directory under another name.
      (should (equal (list b) (funcall listed (concat (directory-file-name other) "/./"))))
      ;; The directory holding theirs is not theirs.
      (should (null (funcall listed (file-name-directory (directory-file-name dir)))))
      (should (null (funcall listed (expand-file-name "nothing-here" dir))))
      ;; An empty cwd filters by nothing, as none does.
      (should (equal (list a b c) (funcall listed "")))
      (should (equal (list a c) (harness-acp-test-listed
                                 (harness-acp-test-list conn (list :cwd dir :_meta '(:x 1) :other 2))))))))

(ert-deftest harness-acp-session-list-refuses-a-cwd-that-is-not-absolute ()
  (harness-acp-test-with
    (let ((conn (harness-acp-test-connect)))
      (dolist (cwd '("relative/dir" "./here" ".." "~/project" "~"))
        (let ((e (harness-acp-test-error conn "session/list" (list :cwd cwd))))
          (should (= -32602 (car e)))
          (should (equal "Invalid params: cwd must be an absolute path" (cadr e)))))
      (let ((e (harness-acp-test-error conn "session/list" (list :cwd 42))))
        (should (= -32602 (car e)))
        (should (equal "Invalid params: cwd must be a string" (cadr e)))))))

(ert-deftest harness-acp-session-list-pages ()
  "A page holds `harness-acp-session-list-page-size' sessions, and `nextCursor' is there while more are left."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (dir (harness-test-temp-dir))
           (ids (cl-loop for n from 5 downto 1
                         collect (harness-acp-test-make-session (* n 100) :cwd dir)))
           (harness-acp-session-list-page-size 2)
           (one (harness-acp-test-list conn))
           (two (harness-acp-test-list conn (list :cursor (plist-get one :nextCursor))))
           (three (harness-acp-test-list conn (list :cursor (plist-get two :nextCursor)))))
      (should (equal (seq-subseq ids 0 2) (harness-acp-test-listed one)))
      (should (stringp (plist-get one :nextCursor)))
      (should (equal (seq-subseq ids 2 4) (harness-acp-test-listed two)))
      (should (stringp (plist-get two :nextCursor)))
      ;; The last page has what is left, and no cursor.
      (should (equal (seq-subseq ids 4) (harness-acp-test-listed three)))
      (should-not (plist-member three :nextCursor))
      ;; The virtual sessions end the first page, and only that one.
      (should (equal (append (seq-subseq ids 0 2) (mapcar #'car harness-acp--virtual-sessions))
                     (harness-acp-test-all-listed one)))
      (should (equal (seq-subseq ids 2 4) (harness-acp-test-all-listed two)))
      (should (equal (seq-subseq ids 4) (harness-acp-test-all-listed three)))
      ;; A cursor is text a client can carry: opaque, and plain.
      (should (string-match-p "\\`[A-Za-z0-9_-]+\\'" (plist-get one :nextCursor)))
      (should-not (equal (plist-get one :nextCursor) (plist-get two :nextCursor)))
      ;; A page that ends where the list does has none either, and a
      ;; larger one holds everything.
      (let ((harness-acp-session-list-page-size 5))
        (should (equal ids (harness-acp-test-listed (harness-acp-test-list conn))))
        (should-not (plist-member (harness-acp-test-list conn) :nextCursor)))
      (let* ((harness-acp-session-list-page-size 3)
             (head (harness-acp-test-list conn))
             (tail (harness-acp-test-list conn (list :cursor (plist-get head :nextCursor)))))
        (should (equal (seq-subseq ids 3) (harness-acp-test-listed tail)))
        (should-not (plist-member tail :nextCursor))))))

(ert-deftest harness-acp-session-list-pages-of-a-directory ()
  "The filter holds for every page: the cursor only says where the page begins."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (dir (harness-test-temp-dir))
           (other (harness-test-temp-dir))
           (mine (cl-loop for n in '(600 400 200)
                          collect (harness-acp-test-make-session n :cwd dir)))
           (harness-acp-session-list-page-size 2))
      (dolist (n '(500 300 100)) (harness-acp-test-make-session n :cwd other))
      (let* ((one (harness-acp-test-list conn (list :cwd dir)))
             (two (harness-acp-test-list conn (list :cwd (directory-file-name dir)
                                                    :cursor (plist-get one :nextCursor)))))
        (should (equal (seq-subseq mine 0 2) (harness-acp-test-listed one)))
        (should (equal (seq-subseq mine 2) (harness-acp-test-listed two)))
        (should-not (plist-member two :nextCursor))))))

(ert-deftest harness-acp-session-list-orders-the-same-time-by-id ()
  "Sessions that last changed together are listed by id, so pages of them repeat and skip none."
  (harness-acp-test-with
    (let ((conn (harness-acp-test-connect))
          (dir (harness-test-temp-dir))
          (harness-acp-session-list-page-size 2)
          (seen nil) (cursor nil))
      (dolist (id '("s-c" "s-a" "s-e" "s-b" "s-d"))
        (harness-acp-test-make-session 1000 :cwd dir :id id))
      (dotimes (_ 3)
        (let ((page (harness-acp-test-list conn (and cursor (list :cursor cursor)))))
          (setq seen (append seen (harness-acp-test-listed page))
                cursor (plist-get page :nextCursor))))
      (should (equal '("s-a" "s-b" "s-c" "s-d" "s-e") seen))
      (should-not cursor))))

(ert-deftest harness-acp-session-list-pages-keep-their-place ()
  "A cursor is a place in the list, not a count: sessions that come or go between two pages repeat and skip none."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (dir (harness-test-temp-dir))
           (ids (cl-loop for n from 5 downto 1
                         collect (harness-acp-test-make-session (* n 100) :cwd dir)))
           (harness-acp-session-list-page-size 2)
           (one (harness-acp-test-list conn)))
      (should (equal (seq-subseq ids 0 2) (harness-acp-test-listed one)))
      ;; The session the first page ended with goes, and a newer one than
      ;; any comes: neither moves the second page.
      (harness-call 'session/delete (cadr ids))
      (let* ((fresh (harness-acp-test-make-session 900 :cwd dir))
             (two (harness-acp-test-list conn (list :cursor (plist-get one :nextCursor))))
             (three (harness-acp-test-list conn (list :cursor (plist-get two :nextCursor)))))
        (should (equal (seq-subseq ids 2 4) (harness-acp-test-listed two)))
        (should (equal (seq-subseq ids 4) (harness-acp-test-listed three)))
        (should-not (plist-member three :nextCursor))
        ;; Listing again begins again, with what is there now.
        (should (equal (list fresh (car ids)) (harness-acp-test-listed (harness-acp-test-list conn))))))))

(ert-deftest harness-acp-session-list-refuses-a-cursor-it-did-not-make ()
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-make-session 100 :cwd (harness-test-temp-dir))))
      (dolist (cursor (list "not a cursor!"                       ; not base64url
                            "bm9wZQ"                              ; "nope": no time and no id
                            (base64url-encode-string "abc def" t) ; the time is no number
                            (base64url-encode-string "12 " t)     ; no id
                            (base64url-encode-string "12" t)
                            42))
        (let ((e (harness-acp-test-error conn "session/list" (list :cursor cursor))))
          (should (= -32602 (car e)))
          (should (equal "Invalid params: invalid cursor" (cadr e)))))
      ;; An empty one is none.
      (should (equal (list sid) (harness-acp-test-listed (harness-acp-test-list conn (list :cursor ""))))))))

(ert-deftest harness-acp-session-list-needs-the-session-module ()
  "Without a bus method `session/list' ACP's is not offered, and not found."
  (harness-acp-test-with
    (harness-unregister-method 'session/list)
    (let* ((conn (harness-acp-test-connect))
           (r (harness-test-await (harness-acp-initialize conn))))
      (should (eq t (plist-get (plist-get r :agentCapabilities) :loadSession)))
      (should-not (plist-member (plist-get r :agentCapabilities) :sessionCapabilities))
      (let ((e (harness-acp-test-error conn "session/list" nil)))
        (should (= -32601 (car e)))
        (should (equal "Method not found: No such harness method: session/list" (cadr e)))))))

(ert-deftest harness-acp-bare-bus-method-says-it-is-under-_harness ()
  "A bus method a client calls by its bare name is not an ACP method, and the error says where it is."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn)))
      (dolist (name '("session/get" "agent/prompt" "tools/list"))
        (let ((e (harness-acp-test-error conn name (list :id sid))))
          (should (= -32601 (car e)))
          (should (equal (format "Method not found: No such ACP method %s; the harness's own method is _harness/%s"
                                 name name)
                         (cadr e)))))
      ;; A bus method no client may call, one that does not exist, and a
      ;; name nothing has: not found, with nothing to point to.
      (dolist (name '("store/save" "session/not-a-method" "nope/x"))
        (let ((e (harness-acp-test-error conn name nil)))
          (should (= -32601 (car e)))
          (should (equal (format "Method not found: No such harness method: %S" name) (cadr e)))))
      ;; Where it points to is there.
      (should (equal sid (plist-get (harness-acp-test-request conn "_harness/session/get" (list :id sid)) :id))))))

;;;; Extension methods

(ert-deftest harness-acp-session-image-gives-a-client-the-pictures-a-transcript-shows ()
  "A client that cannot open a path asks for the picture a tool result or a
hand-in names: `initialize' lists `session/image', `_harness/session/image'
answers with the bytes in base64, and refuses what the transcript does not
show, with words for the person."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (init (harness-test-await (harness-acp-initialize conn)))
           (sid (harness-acp-test-new-session conn))
           (cwd (plist-get (harness-call 'session/get sid) :cwd))
           (shot (expand-file-name "shot.png" cwd))
           (other (expand-file-name "other.png" cwd)))
      (should (member "session/image" (append (plist-get (plist-get init :_harness) :methods) nil)))
      (let ((coding-system-for-write 'no-conversion))
        (write-region harness-test-png nil shot nil 'silent)
        (write-region harness-test-png nil other nil 'silent))
      (harness-call 'session/append sid (list :kind 'tool-result :call-id "c1" :output "Image shot.png"
                                              :attachments (list (list :path shot :mime "image/png"
                                                                       :size (length harness-test-png)
                                                                       :name "shot.png"))))
      (let ((answer (harness-acp-test-request conn "_harness/session/image" (list :id sid :path shot))))
        (should (equal "image/png" (plist-get answer :mime)))
        (should (equal "shot.png" (plist-get answer :name)))
        (should (= (length harness-test-png) (plist-get answer :size)))
        (should (equal harness-test-png (base64-decode-string (plist-get answer :data)))))
      ;; A file the transcript does not show is not given, however real.
      (let ((e (harness-acp-test-error conn "_harness/session/image" (list :id sid :path other))))
        (should (= -32603 (car e)))
        (should (string-match-p (format "Session %s shows no file %s" sid (regexp-quote other)) (cadr e))))
      ;; Nor with a missing parameter: that is the client's mistake.
      (should (= -32602 (car (harness-acp-test-error conn "_harness/session/image" (list :id sid))))))))

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
      ;; The apps fold a run of calls under one summary line the way the
      ;; Emacs chat does, and take the allow list of the tools that fold from
      ;; this answer, so it is an array of specs on the wire, each saying
      ;; whether its calls fold: `true' or null, never missing.
      (harness-define-tool "peek" :label "Peek" :description "peek" :kind 'read :coalescable t
                           :handler #'ignore)
      (let* ((specs (harness-json-parse
                     (harness-json-encode
                      (harness-acp-test-request conn "_harness/tools/list" nil))))
             (spec (lambda (name) (cl-find name specs :key (lambda (s) (plist-get s :name))
                                           :test #'equal))))
        (should (equal '("list_dir" "peek") (sort (mapcar (lambda (s) (plist-get s :name)) specs)
                                                  #'string<)))
        (should (eq t (plist-get (funcall spec "peek") :coalescable)))
        (should (plist-member (funcall spec "list_dir") :coalescable))
        (should-not (plist-get (funcall spec "list_dir") :coalescable)))
      (let ((api (harness-acp-test-request conn "_harness/harness/api" nil)))
        (should (member "session/get" (mapcar (lambda (m) (plist-get m :name)) (plist-get api :methods))))
        (should (cl-every #'stringp (plist-get api :filters))))
      (should (equal harness-version (plist-get (harness-acp-test-request conn "_harness/harness/version" nil) :version)))
      (should (eq t (plist-get (harness-acp-test-request conn "_harness/agent/prompt"
                                                          (list :sessionId sid :blocks "hello" :opts '(:queue t)))
                               :queued)))
      (should (= 1 (length (plist-get (harness-call 'session/get sid) :queue)))))))

(ert-deftest harness-acp-reaches-the-supervisor-and-seed-plugins ()
  "The methods of the supervisor and cache-seed plugins are callable as
_harness/NAME, and clients hear the events they follow them by: a
supervisor's change, and a module-owned setting of a session."
  (harness-acp-test-with
    ;; Any method of the two plugins, and only theirs.
    (dolist (name '("supervisor/plan" "supervisor/status" "seed/start" "seed/status"))
      (should (harness-acp--extension-allowed-p name)))
    (dolist (name '("supervisors/plan" "supervise/x" "seeds/start" "seed" "store/save"))
      (should-not (harness-acp--extension-allowed-p name)))
    (should (memq 'session/ext-changed harness-acp--forwarded-events))
    (should (memq 'supervisor/changed harness-acp--forwarded-events))
    (harness-register-method 'supervisor/ping (lambda (x) (list :pong x)))
    (harness-register-method 'seed/ping (lambda () "seeded"))
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (listed (plist-get (plist-get (harness-test-await (harness-acp-initialize conn)) :_harness) :methods))
           (heard (lambda (event)
                    (cl-find-if (lambda (m) (and (equal (car m) "_harness/event")
                                                 (equal event (plist-get (cadr m) :event))))
                                harness-acp-test-messages))))
      (should (member "supervisor/ping" listed))
      (should (member "seed/ping" listed))
      (should (member "session/set-ext" listed))
      (should (equal '(:pong "x") (harness-acp-test-request conn "_harness/supervisor/ping" '(:x "x"))))
      (should (equal "seeded" (harness-acp-test-request conn "_harness/seed/ping" nil)))
      ;; A plugin's own event.
      (harness-emit 'supervisor/changed sid)
      (harness-test-wait (lambda () (funcall heard "supervisor/changed")) 5 "supervisor/changed")
      (should (equal (list sid) (plist-get (cadr (funcall heard "supervisor/changed")) :args)))
      ;; The setting a module keeps for a session, set over ACP.
      (let ((s (harness-acp-test-request conn "_harness/session/set-ext"
                                         (list :id sid :key "supervisor" :value t))))
        (should (equal t (plist-get (plist-get s :ext) :supervisor))))
      (harness-test-wait (lambda () (funcall heard "session/ext-changed")) 5 "session/ext-changed")
      (should (equal (list sid ":supervisor" t)
                     (plist-get (cadr (funcall heard "session/ext-changed")) :args))))))

(defun harness-acp-test-events (event)
  "Return the args of each `_harness/event' EVENT the primary connection got, oldest first."
  (let (out)
    (dolist (m harness-acp-test-messages out)
      (when (and (equal (car m) "_harness/event")
                 (equal event (plist-get (cadr m) :event)))
        (push (plist-get (cadr m) :args) out)))))

(ert-deftest harness-acp-local-extra-methods-and-events ()
  "A module of the user's own offers clients its methods and events.
Its methods are callable as `_harness/NAME' once their prefix is in
`harness-acp-extra-method-prefixes', and its events reach clients once
they are in `harness-acp-extra-events'.  `harness/modules' lists every
module."
  (harness-acp-test-with
    (let ((conn (harness-acp-test-connect))
          (harness-acp-extra-method-prefixes harness-acp-extra-method-prefixes)
          (harness-acp-extra-events harness-acp-extra-events))
      (harness-register-method 'hello/greet
                               (lambda (name)
                                 (harness-emit 'hello/greeted name)
                                 (format "hello, %s" name)))
      (should (= -32601 (car (harness-acp-test-error conn "_harness/hello/greet" '(:name "you")))))
      (push "hello/" harness-acp-extra-method-prefixes)
      (should (equal "hello, you" (harness-acp-test-request conn "_harness/hello/greet" '(:name "you"))))
      (should (member "hello/greet" (harness-acp--extension-methods)))
      (should-not (harness-acp-test-events "hello/greeted"))
      (push 'hello/greeted harness-acp-extra-events)
      (should (equal "hello, me" (harness-acp-test-request conn "_harness/hello/greet" '(:name "me"))))
      (harness-test-wait (lambda () (harness-acp-test-events "hello/greeted")) 5 "the event")
      (should (equal '(("me")) (harness-acp-test-events "hello/greeted")))
      (let ((modules (harness-acp-test-request conn "_harness/harness/modules" nil)))
        (should (equal (mapcar (lambda (m) (symbol-name (harness-module-name m))) (harness-modules))
                       (mapcar (lambda (m) (plist-get m :name)) modules)))
        (should (equal "ready" (plist-get (cl-find "acp" modules :key (lambda (m) (plist-get m :name))
                                                   :test #'equal)
                                          :state)))))))

(ert-deftest harness-acp-handle-request-always-answers ()
  "A request always gets an answer, even when sending the real one fails.
`harness-acp--client-send' can fail -- JSON encoding rejects a value it
cannot represent, such as a raw byte deep in a session's transcript, or
the transport itself breaks -- which used to leave the caller's request
waiting on its id for good, with no answer ever coming (see
`harness-acp--handle-request').  A short error replaces it instead,
rather than nothing at all."
  (harness-acp-test-with
    (let ((conn (harness-acp-test-connect))
          (orig (symbol-function 'harness-acp--client-send)))
      ;; The real reply (a `:result') fails to send, as a broken
      ;; transport or an unencodable value would; the fallback (an
      ;; `:error') goes out as it always did.
      (cl-letf (((symbol-function 'harness-acp--client-send)
                 (lambda (client msg)
                   (if (plist-member msg :result)
                       (error "pipe closed")
                     (funcall orig client msg)))))
        (let ((err (harness-acp-test-error conn "_harness/harness/version" nil)))
          (should err)
          (should (= harness-acp-error-method (car err)))
          (should (string-match-p "could not send the answer" (cadr err))))))))

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

(ert-deftest harness-acp-local-send-one-queued-message-now ()
  "What `harness-chat-send-queued' sends steers the running turn with that message alone.
`:qids' names the queued messages to send; the others stay queued.  The
message waits for the turn's next step, listed on the session and no
node of the transcript; the client hears it as a message of the user's
when the turn takes it, which is where the transcript has it."
  (harness-acp-test-with
    (let* ((gate (harness-make-promise))
           (harness-provider-demo-script-override
            '((:type tool-call :id "w1" :name "hold" :input (:n 1))
              (:type text :delta "Done.")
              (:type done :stop-reason end-turn)))
           (conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (queue (lambda (text)
                    (harness-acp-test-request
                     conn "_harness/agent/prompt"
                     (list :session-id sid :blocks (list (list :type "text" :text text))
                           :opts (list :queue t)))))
           (p (progn
                (harness-define-tool "hold" :label "Hold" :description "hold" :kind 'read
                                     :handler (lambda (_input _ctx) (harness-then gate (lambda (_) "held"))))
                (harness-acp-request conn "session/prompt"
                                     (list :sessionId sid :prompt (list (list :type "text" :text "tour")))))))
      (harness-test-wait (lambda () (memq 'tool-call (mapcar (lambda (n) (plist-get n :kind))
                                                             (harness-call 'session/nodes sid))))
                         5 "the turn in its tool")
      (funcall queue "for later")
      (funcall queue "right now")
      (let* ((items (plist-get (harness-call 'session/get sid) :queue))
             (qid (plist-get (cadr items) :id))
             (send (harness-acp-request conn "_harness/agent/send-queue"
                                        (list :session-id sid :qids (list qid)))))
        (harness-test-wait (lambda () (plist-get (harness-call 'session/get sid) :steering))
                           5 "the message waiting for the turn")
        (should (equal '("for later")
                       (mapcar (lambda (it) (plist-get it :text)) (plist-get (harness-call 'session/get sid) :queue))))
        (should (equal '("right now")
                       (mapcar (lambda (it) (plist-get it :text)) (plist-get (harness-call 'session/get sid) :steering))))
        ;; No node of it yet: the model has not read it.
        (should-not (cl-find-if (lambda (n) (plist-get (plist-get n :meta) :steering))
                                (harness-call 'session/nodes sid)))
        (should-not (cl-some (lambda (u) (equal "right now" (plist-get (plist-get u :content) :text)))
                             (harness-acp-test-updates)))
        (harness-resolve gate t)
        (should (equal "end-turn" (plist-get (harness-test-await send) :stop-reason)))
        (should (equal "end_turn" (plist-get (harness-test-await p) :stopReason))))
      ;; The turn took the message, and the client heard it as a message of
      ;; the user's, once, as the turn read it.
      (harness-test-wait
       (lambda ()
         (cl-some (lambda (u) (and (equal (plist-get u :sessionUpdate) "user_message_chunk")
                                   (equal (plist-get (plist-get u :content) :text) "right now")))
                  (harness-acp-test-updates)))
       5 "the update with the message")
      (should (= 1 (cl-count-if (lambda (u) (and (equal (plist-get u :sessionUpdate) "user_message_chunk")
                                                 (equal (plist-get (plist-get u :content) :text) "right now")))
                                (harness-acp-test-updates))))
      (should-not (plist-get (harness-call 'session/get sid) :steering))
      ;; The one left in the queue goes out as a turn of its own.
      (harness-test-wait (lambda () (and (null (plist-get (harness-call 'session/get sid) :queue))
                                         (not (harness-agent-running-p sid))))
                         10 "the queued turn")
      (should (equal '("tour" "right now" "for later")
                     (mapcar (lambda (n) (plist-get n :content))
                             (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user))
                                               (harness-call 'session/nodes sid))))))))

(ert-deftest harness-acp-text-block-keeps-the-mark-of-an-attachments-text ()
  "A text block marked `_harness.attached' stays marked in the harness.
The compose box marks the text of a task it attaches that way; the
transcript then sets it apart from the user's words.  A mark that is
false, or none, leaves a text block as it was."
  (harness-acp-test-with
    (should (equal '(:type "text" :text "words") (harness-acp--block-from-acp '(:type "text" :text "words"))))
    (should (equal '(:type "text" :text "Task t-1" :attached t)
                   (harness-acp--block-from-acp '(:type "text" :text "Task t-1" :_harness (:attached t)))))
    (should (equal '(:type "text" :text "words")
                   (harness-acp--block-from-acp '(:type "text" :text "words" :_harness (:attached :false)))))
    ;; Over the wire, as the chat sends it.
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn)))
      (harness-acp-test-request
       conn "session/prompt"
       (list :sessionId sid
             :prompt (list (list :type "text" :text "see @task:t-1")
                           (list :type "text" :text "Task t-1, attached: Fix" :_harness (list :attached t)))))
      (let ((node (car (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user))
                                         (harness-call 'session/nodes sid)))))
        (should (equal "see @task:t-1\n\nTask t-1, attached: Fix" (plist-get node :content)))))))

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

(ert-deftest harness-acp-local-prompt-image-keeps-its-label ()
  "An image block's `_harness.label', its token in the text, reaches the transcript.
The compose box sends it, [image 1] in the text naming the image
labelled image 1; an image without one, from any other client, has none."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (data (base64-encode-string harness-test-png t)))
      (harness-acp-test-request conn "session/prompt"
                                (list :sessionId sid
                                      :prompt (list (list :type "text" :text "look at [image 1]")
                                                    (list :type "image" :mimeType "image/png" :data data
                                                          :_harness (list :label "image 1"))
                                                    (list :type "image" :mimeType "image/png" :data data))))
      (let ((node (car (harness-call 'session/nodes sid))))
        (should (equal "look at [image 1] [image]" (plist-get node :content)))
        (should (equal '(("text" nil) ("image" "image 1") ("image" nil))
                       (mapcar (lambda (b) (list (plist-get b :type) (plist-get b :label)))
                               (plist-get node :blocks))))))))

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
      ;; A failing method is an internal error: -32000 is ACP's
      ;; auth_required, which would send clients to authenticate.
      (let ((e (harness-acp-test-error conn "_harness/session/get" '(:id "missing"))))
        (should (= -32603 (car e)))
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

(ert-deftest harness-acp-local-permission-request-carries-its-summary ()
  "A request says in `_harness' that a summary of its call is on its way, or
carries the one already written, and the update that brings it is a
forwarded event; a request made without one has the keys empty."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (extra-of (lambda (pid)
                       (harness-test-wait
                        (lambda () (cl-find-if (lambda (m) (and (equal (car m) "session/request_permission")
                                                                (equal pid (plist-get (plist-get (nth 1 m) :_harness)
                                                                                      :pendingId))))
                                               harness-acp-test-messages)))
                       (plist-get (nth 1 (cl-find-if (lambda (m) (equal pid (plist-get (plist-get (nth 1 m) :_harness)
                                                                                      :pendingId)))
                                                     harness-acp-test-messages))
                                  :_harness))))
      (harness-emit 'permission/requested sid
                    (list :id "s1" :kind 'permission
                          :payload (list :tool "bash" :kind 'exec :input '(:command "make") :summarizing t)))
      (let ((extra (funcall extra-of "s1")))
        (should (eq t (plist-get extra :summarizing)))
        (should-not (plist-get extra :summary)))
      (harness-emit 'permission/requested sid
                    (list :id "s2" :kind 'permission
                          :payload (list :tool "bash" :kind 'exec :input '(:command "make")
                                         :summary "Runs make." :summary-model "claude:haiku")))
      (let ((extra (funcall extra-of "s2")))
        (should (equal "Runs make." (plist-get extra :summary)))
        (should (equal "claude:haiku" (plist-get extra :summaryModel)))
        (should-not (plist-get extra :summarizing)))
      (harness-emit 'permission/requested sid
                    (list :id "s3" :kind 'permission :payload (list :tool "bash" :kind 'exec)))
      (let ((extra (funcall extra-of "s3")))
        (should-not (plist-get extra :summary))
        (should-not (plist-get extra :summarizing)))
      ;; The update is forwarded as an event, with what was merged in.
      (harness-emit 'session/pending-updated sid "s1" '(:summary "Runs make." :summary-model "claude:haiku" :summarizing nil))
      (harness-test-wait (lambda () (harness-acp-test-events "session/pending-updated")) 5 "the update")
      (should (equal (list (list sid "s1" '(:summary "Runs make." :summary-model "claude:haiku" :summarizing nil)))
                     (harness-acp-test-events "session/pending-updated"))))))

(ert-deftest harness-acp-local-directory-permission-options ()
  "Every request is offered the same options, under the same names.
A tool prompt, the jail's prompt about a directory and an agent's own
request for one alike; a payload listing fewer narrows them."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (five '(allow-once allow-session allow-always deny-once deny-always))
           (message-of (lambda (pid)
                         (harness-test-wait
                          (lambda () (cl-find-if (lambda (m) (and (equal (car m) "session/request_permission")
                                                                  (equal pid (plist-get (plist-get (nth 1 m) :_harness)
                                                                                        :pendingId))))
                                                 harness-acp-test-messages)))
                         (cl-find-if (lambda (m) (equal pid (plist-get (plist-get (nth 1 m) :_harness) :pendingId)))
                                     harness-acp-test-messages)))
           (options (lambda (pid)
                      (mapcar (lambda (o) (list (plist-get o :optionId) (plist-get o :name) (plist-get o :kind)))
                              (plist-get (nth 1 (funcall message-of pid)) :options)))))
      (dolist (r (list (list "t1" (list :tool "bash" :kind 'exec :input '(:command "ls")))
                       (list "j1" (list :tool "read_file" :kind 'read :dir "/srv/data/" :pattern "/srv/data/**"
                                        :options five))
                       (list "r1" (list :tool "request_directory_access" :kind 'meta :dir "/srv/data/"
                                        :pattern "/srv/data/**" :reason "The agent asks for access: read the data"
                                        :options five))))
        (harness-emit 'permission/requested sid (list :id (car r) :kind 'permission :payload (cadr r)))
        (should (equal '(("allow-once" "Allow" "allow_once")
                         ("allow-session" "Allow for session" "allow_always")
                         ("allow-always" "Always allow" "allow_always")
                         ("deny-once" "Deny" "reject_once")
                         ("deny-always" "Always deny" "reject_always"))
                       (funcall options (car r)))))
      ;; The names are the UI's own button labels.
      (should (equal (mapcar (lambda (a) (nth 1 a)) harness-acp-permission-answers)
                     (mapcar #'cadr (funcall options "r1"))))
      ;; A payload offering fewer answers narrows them, names unchanged.
      (harness-emit 'permission/requested sid
                    (list :id "n1" :kind 'permission
                          :payload (list :tool "read_file" :kind 'read :dir "/srv/data/"
                                         :options '(allow-session deny-once))))
      (should (equal '(("allow-session" "Allow for session" "allow_always") ("deny-once" "Deny" "reject_once"))
                     (funcall options "n1")))
      ;; The request's directory and the agent's reason go along.
      (let ((m (funcall message-of "r1")))
        (should (equal "/srv/data/" (plist-get (plist-get (nth 1 m) :_harness) :dir)))
        (should (equal "request_directory_access" (plist-get (plist-get (nth 1 m) :_harness) :tool)))
        (should (string-match-p "read the data" (plist-get (plist-get (nth 1 m) :_harness) :reason)))))))

(ert-deftest harness-acp-local-permission-pattern-round-trip ()
  "A request about paths carries its pattern; an answer for another one passes it on."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (recorded nil)
           (request (lambda (pid)
                      (harness-emit 'permission/requested sid
                                    (list :id pid :kind 'permission
                                          :payload (list :tool "read_file" :kind 'read :dir "/srv/data/"
                                                         :pattern "/srv/data/**" :paths '("/srv/data/a.csv")
                                                         :options '(allow-once allow-session allow-always
                                                                    deny-once deny-always))))
                      (harness-test-wait
                       (lambda () (cl-find-if (lambda (m) (equal pid (plist-get (plist-get (nth 1 m) :_harness) :pendingId)))
                                              harness-acp-test-messages))))))
      (harness-register-method 'permission/answer
                               (lambda (s pid answer) (push (list s pid answer) recorded) answer))
      (let ((m (funcall request "j1")))
        (should (equal "/srv/data/**" (plist-get (plist-get (nth 1 m) :_harness) :pattern)))
        (should (equal "Always deny" (plist-get (car (last (plist-get (nth 1 m) :options))) :name)))
        (funcall (nth 2 m) (list :outcome (list :outcome "selected" :optionId "allow-session")
                                 :_harness (list :pattern "/srv/data/*.csv"))))
      (harness-test-wait (lambda () recorded))
      (should (equal (list sid "j1" '(:behavior allow :scope session :pattern "/srv/data/*.csv")) (car recorded)))
      ;; A client that does not edit it answers for the request's own.
      (funcall (nth 2 (funcall request "j2")) (list :outcome (list :outcome "selected" :optionId "deny-always")))
      (harness-test-wait (lambda () (= 2 (length recorded))))
      (should (equal (list sid "j2" '(:behavior deny :scope always)) (car recorded))))))

(ert-deftest harness-acp-local-permission-cover-round-trip ()
  "A request about a call carries the covers its lasting answers can hold for.
They go in `_harness.ladder', narrowest first, with the step the answers
start on in `_harness.cover'; a client that lets the user choose names
the step in `_harness.cover' of its result, and the answer carries it.
One that does not, answers as before."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (recorded nil)
           (ladder '((:id "exact" :label "every bash call whose command is exactly \"ls -la\"")
                     (:id "programs" :label "every ls call (any arguments)")
                     (:id "tool" :label "every bash call (any command)")))
           (request (lambda (pid)
                      (harness-emit 'permission/requested sid
                                    (list :id pid :kind 'permission
                                          :payload (list :tool "bash" :kind 'exec :input '(:command "ls -la")
                                                         :commands '(("ls")) :covers "ls"
                                                         :ladder ladder :cover "programs")))
                      (harness-test-wait
                       (lambda () (cl-find-if (lambda (m) (equal pid (plist-get (plist-get (nth 1 m) :_harness) :pendingId)))
                                              harness-acp-test-messages))))))
      (harness-register-method 'permission/answer
                               (lambda (s pid answer) (push (list s pid answer) recorded) answer))
      (let* ((m (funcall request "c1"))
             (extra (plist-get (nth 1 m) :_harness)))
        (should (equal ladder (plist-get extra :ladder)))
        (should (equal "programs" (plist-get extra :cover)))
        ;; What it said before stays.
        (should (equal "ls" (plist-get extra :covers)))
        (funcall (nth 2 m) (list :outcome (list :outcome "selected" :optionId "allow-always")
                                 :_harness (list :cover "exact"))))
      (harness-test-wait (lambda () recorded))
      (should (equal (list sid "c1" '(:behavior allow :scope always :cover "exact")) (car recorded)))
      ;; A client that does not choose answers for the step the request started on.
      (funcall (nth 2 (funcall request "c2")) (list :outcome (list :outcome "selected" :optionId "allow-session")))
      (harness-test-wait (lambda () (= 2 (length recorded))))
      (should (equal (list sid "c2" '(:behavior allow :scope session)) (car recorded)))
      ;; A cover and a pattern together, and a blank cover, which names none.
      (funcall (nth 2 (funcall request "c3"))
               (list :outcome (list :outcome "selected" :optionId "deny-always")
                     :_harness (list :cover "tool" :pattern "/srv/**")))
      (harness-test-wait (lambda () (= 3 (length recorded))))
      (should (equal (list sid "c3" '(:behavior deny :scope always :pattern "/srv/**" :cover "tool")) (car recorded)))
      (funcall (nth 2 (funcall request "c4"))
               (list :outcome (list :outcome "selected" :optionId "deny-always") :_harness (list :cover " ")))
      (harness-test-wait (lambda () (= 4 (length recorded))))
      (should (equal (list sid "c4" '(:behavior deny :scope always)) (car recorded))))))

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
        (should-not (plist-member params :diagrams))
        ;; An ordinary question says nothing of several options.
        (should-not (plist-member params :allowMultiple))
        (funcall (nth 2 m) (list :answer "green")))
      (harness-test-wait (lambda () recorded))
      (should (equal (list (list sid "q1" "green")) recorded))
      ;; A question whose options may be ticked together says so, and
      ;; its answer, the picked options one to a line, goes back as text.
      (harness-emit 'question/asked sid
                    (list :id "q3" :kind 'question
                          :payload (list :question "Which features?" :options '("dark" "sync" "push")
                                         :allow-multiple t)))
      (harness-test-wait (lambda () (cl-find-if (lambda (m) (equal "q3" (plist-get (nth 1 m) :requestId)))
                                                harness-acp-test-messages)))
      (let ((m (cl-find-if (lambda (m) (equal "q3" (plist-get (nth 1 m) :requestId)))
                           harness-acp-test-messages)))
        (should (eq t (plist-get (nth 1 m) :allowMultiple)))
        (should (equal '("dark" "sync" "push") (plist-get (nth 1 m) :options)))
        (funcall (nth 2 m) (list :answer "dark\npush")))
      (harness-test-wait (lambda () (cl-find "q3" recorded :key #'cadr :test #'equal)))
      (should (equal (list sid "q3" "dark\npush") (cl-find "q3" recorded :key #'cadr :test #'equal)))
      ;; A flag the JSON false stands for is no flag.
      (harness-emit 'question/asked sid
                    (list :id "q4" :kind 'question
                          :payload (list :question "Which one?" :options '("a" "b") :allow-multiple :false)))
      (harness-test-wait (lambda () (cl-find-if (lambda (m) (equal "q4" (plist-get (nth 1 m) :requestId)))
                                                harness-acp-test-messages)))
      (should-not (plist-member (nth 1 (cl-find-if (lambda (m) (equal "q4" (plist-get (nth 1 m) :requestId)))
                                                   harness-acp-test-messages))
                                :allowMultiple))
      ;; Diagrams of the options go along, one per option.
      (let ((diagrams '((:type "ascii" :text "[A]") (:type "image" :path "/tmp/b.png" :mime "image/png"))))
        (harness-emit 'question/asked sid
                      (list :id "q2" :kind 'question
                            :payload (list :question "Which layout?" :options '("A" "B") :diagrams diagrams)))
        (harness-test-wait (lambda () (cl-find-if (lambda (m) (equal "q2" (plist-get (nth 1 m) :requestId)))
                                                  harness-acp-test-messages)))
        (let ((params (nth 1 (cl-find-if (lambda (m) (equal "q2" (plist-get (nth 1 m) :requestId)))
                                         harness-acp-test-messages))))
          (should (equal '("A" "B") (plist-get params :options)))
          (should (equal diagrams (plist-get params :diagrams))))))))

(ert-deftest harness-acp-local-ask-user-answer-carries-attachments ()
  "A reply to `_harness/ask_user' with attachments answers with them.
They are ACP content blocks, as a prompt's are, an image with its data
and its token's label; `question/answer' gets (:answer TEXT :blocks
BLOCKS), the harness's blocks of them, which it sends the model.  A
reply with none answers with the text alone, as before."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (recorded nil)
           (atts (list (list :type "image" :mimeType "image/png" :data "iVBO" :_harness (list :label "image 1"))
                       "junk"
                       (list :type "resource_link" :uri "file:///tmp/notes.txt" :name "notes.txt"
                             :size 5 :mimeType "text/plain")))
           (blocks (list (list :type "image" :mime "image/png" :data "iVBO" :label "image 1")
                         (list :type "file" :path "/tmp/notes.txt" :size 5 :mime "text/plain" :name "notes.txt"))))
      (should (equal blocks (harness-acp-blocks-from-acp atts)))
      (harness-register-method 'question/answer
                               (lambda (s pid answer) (push (list s pid answer) recorded) t))
      (dolist (case (list (list "q1" (list :answer "like [image 1]" :attachments atts)
                                (list :answer "like [image 1]" :blocks blocks))
                          (list "q2" (list :answer "plain" :attachments nil) "plain")
                          (list "q3" (list :answer "plain" :attachments []) "plain")))
        (harness-emit 'question/asked sid
                      (list :id (car case) :kind 'question
                            :payload (list :question "Which one?" :options '("a" "b"))))
        (harness-test-wait (lambda () (cl-find-if (lambda (m) (equal (car case) (plist-get (nth 1 m) :requestId)))
                                                  harness-acp-test-messages)))
        (funcall (nth 2 (cl-find-if (lambda (m) (equal (car case) (plist-get (nth 1 m) :requestId)))
                                    harness-acp-test-messages))
                 (nth 1 case))
        (harness-test-wait (lambda () (assoc-default (car case) (mapcar #'cdr recorded))))
        (should (equal (list sid (car case) (nth 2 case))
                       (cl-find (car case) recorded :key #'cadr :test #'equal)))))))

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

(ert-deftest harness-acp-local-close-says-why-and-answers-say-if-they-went ()
  "A connection closed on purpose rejects what still waits on it with
the reason it was given, and RESPOND reports whether an answer went
out: one to a request that came on a closed connection cannot, and the
harness never hears it."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (sid (harness-acp-test-new-session conn))
           (recorded nil)
           (request (lambda (pid)
                      (harness-emit 'permission/requested sid
                                    (list :id pid :kind 'permission :payload (list :tool "bash" :kind 'exec)))
                      (harness-test-wait (lambda () (cl-find-if (lambda (m) (equal pid (plist-get (plist-get (nth 1 m) :_harness) :pendingId)))
                                                                harness-acp-test-messages)))
                      (nth 2 (cl-find-if (lambda (m) (equal pid (plist-get (plist-get (nth 1 m) :_harness) :pendingId)))
                                         harness-acp-test-messages))))
           (allow (list :outcome (list :outcome "selected" :optionId "allow-once"))))
      (harness-register-method 'permission/answer
                               (lambda (s pid answer) (push (list s pid answer) recorded) answer))
      (harness-register-method 'session/test-hang (lambda () (harness-make-promise)))
      ;; Answered while the connection is open: it goes out, once.
      (let ((respond (funcall request "p1")))
        (should (eq t (funcall respond allow)))
        (should-not (funcall respond allow))
        (harness-test-wait (lambda () recorded))
        (should (equal "p1" (nth 1 (car recorded)))))
      (let ((respond (funcall request "p2"))
            (rejection nil))
        (harness-catch (harness-acp-request conn "_harness/session/test-hang" nil)
                       (lambda (e) (setq rejection e)))
        (harness-acp-close conn "replaced")
        (harness-test-wait (lambda () rejection))
        (should (equal "replaced" (harness-acp-closed-reason rejection)))
        (should (equal "connection replaced" (harness-error-message rejection)))
        ;; Too late to answer here.
        (should-not (funcall respond allow))
        (accept-process-output nil 0.05)
        (should (= 1 (length recorded))))
      ;; A failure of another kind has no reason to give.
      (should-not (harness-acp-closed-reason '(acp-error -32603 "boom" nil)))
      (should-not (harness-acp-closed-reason '(error "boom"))))))

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

;;;; Receiving: lines and slices

(ert-deftest harness-acp-split-lines-joins-what-chunks-cut ()
  "Lines come out whole and in order however the chunks cut them; blank
lines are dropped, a \"\\r\" before a newline too, and an unended line
waits for the chunk that ends it."
  (let ((pending "") (lines nil))
    (dolist (chunk '("{\"a\":" "1}\r\n\n  \n{\"b\"" ":2}\n{\"c\":3" "}\n" "{\"d\""))
      (let ((split (harness-acp--split-lines pending chunk)))
        (setq lines (append lines (car split))
              pending (cdr split))))
    (should (equal '("{\"a\":1}" "{\"b\":2}" "{\"c\":3}") lines))
    (should (equal "{\"d\"" (apply #'concat (reverse pending))))
    ;; What a connection made before the change holds: a string.
    (should (equal '(("{\"d\":4}") . nil) (harness-acp--split-lines "{\"d\"" ":4}\n")))))

(ert-deftest harness-acp-split-lines-costs-what-the-line-is-long ()
  "A line in many chunks is joined once, when it ends: the text made is in
proportion to its length.  Joining the unended line to each chunk, as
before, made text in proportion to its length times its chunks: a
300 KB tool result in 64 KB reads, and the tail of each read after it."
  (let* ((n 500)
         (chunk (make-string 2000 ?x))
         (pending nil)
         (before (nth 4 (memory-use-counts))))
    (dotimes (_ n)
      (setq pending (cdr (harness-acp--split-lines pending chunk))))
    (let ((split (harness-acp--split-lines pending "}\n")))
      (should (= 1 (length (car split))))
      (should (= (1+ (* n 2000)) (length (caar split))))
      (should-not (cdr split)))
    ;; About the line twice over (its pieces, then itself), not 250 MB.
    (should (< (- (nth 4 (memory-use-counts)) before) (* 4 n 2000)))))

(defvar harness-acp-test-on-message #'ignore
  "Called with the PARAMS of each message `harness-acp-test-with-inbox' handles.")

(defmacro harness-acp-test-with-inbox (&rest body)
  "Run BODY with an inbox of its own, CONN a local connection to fill it.
CONN's handler calls `harness-acp-test-on-message' with the PARAMS of
each message."
  (declare (indent 0))
  `(let* ((harness-acp--inbox nil)
          (harness-acp--inbox-tail nil)
          (harness-acp--inbox-timer nil)
          (harness-acp--once-received nil)
          (harness-acp-received-hook nil)
          (conn (harness-acp--make-connection :kind 'local)))
     (harness-acp-set-handler conn (lambda (_method params _respond)
                                     (funcall harness-acp-test-on-message params)))
     (unwind-protect (progn ,@body)
       (when (timerp harness-acp--inbox-timer) (cancel-timer harness-acp--inbox-timer)))))

(defun harness-acp-test-busy (seconds)
  "Keep Emacs busy for SECONDS, as a slow handler would."
  (let ((end (+ (float-time) seconds)))
    (while (< (float-time) end))))

(ert-deftest harness-acp-receiving-lets-emacs-in-between-slices ()
  "A burst of messages is handled in order, a slice at a time, and what
else is due runs between slices: a timer here, as redisplay and input
do in a UI.  With a timer per message, as before, Emacs ran every
message of the burst first: a UI that fell behind froze for as long."
  (harness-acp-test-with-inbox
    (let* ((harness-acp-receive-slice 0.05)
           (seen nil) (slices 0) (ticks nil)
           (harness-acp-test-on-message (lambda (params)
                                          (harness-acp-test-busy 0.01)
                                          (push (plist-get params :n) seen)))
           (ticker nil))
      (add-hook 'harness-acp-received-hook (lambda () (cl-incf slices)))
      (unwind-protect
          (progn
            (setq ticker (run-at-time 0 0.02 (lambda () (push (float-time) ticks))))
            ;; 60 messages taking 0.6 s, all at once.
            (dotimes (i 60)
              (harness-acp--enqueue conn (list :jsonrpc "2.0" :method "x" :params (list :n i))))
            (harness-test-wait (lambda () (= 60 (length seen))) 10 "every message handled"))
        (cancel-timer ticker))
      (should (equal (number-sequence 0 59) (nreverse seen)))
      (should (>= slices 6))
      (let ((gaps (cl-loop for (a b) on (nreverse ticks) while b collect (- b a))))
        (should (> (length gaps) 6))
        (should (< (apply #'max gaps) 0.3))))))

(ert-deftest harness-acp-receiving-parses-lines-as-it-handles-them ()
  "A TCP connection's lines are parsed in the slice that handles them;
one that is no JSON is logged and skipped; a closed connection's are
dropped unread."
  (harness-acp-test-with-inbox
    (let* ((seen nil) (warned nil)
           (harness-acp-test-on-message (lambda (params) (push (plist-get params :n) seen)))
           (log (lambda (level msg) (when (eq level 'warn) (push msg warned)))))
      (add-hook 'harness-log-hook log)
      (unwind-protect
          (progn
            (harness-acp--enqueue conn "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":{\"n\":1}}")
            (harness-acp--enqueue conn "not json")
            (harness-acp--enqueue conn "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":{\"n\":2}}")
            (harness-test-wait (lambda () (null harness-acp--inbox)) 5 "the lines handled")
            (should (equal '(2 1) seen))
            (should (cl-some (lambda (m) (string-match-p "unparsable line.*not json" m)) warned))
            (harness-acp--enqueue conn "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":{\"n\":3}}")
            (setf (harness-acp-connection-open conn) nil)
            (harness-test-wait (lambda () (null harness-acp--inbox)) 5 "the line dropped")
            (should (equal '(2 1) seen)))
        (remove-hook 'harness-log-hook log)))))

(ert-deftest harness-acp-receiving-keeps-behind-timers-due ()
  "A message is handled after the timers due when it came, as with a timer
of its own: one that came while the slice for others waited got ahead
of them, as the answers of a new connection did of the rejections of
the requests of the one it replaced, and an error stayed on show."
  (harness-acp-test-with-inbox
    (let* ((order nil)
           (harness-acp-test-on-message (lambda (params) (push (plist-get params :n) order))))
      (harness-acp--enqueue conn (list :jsonrpc "2.0" :method "x" :params (list :n 1)))
      (run-at-time 0 nil (lambda () (push 'timer order)))
      (harness-acp--enqueue-all conn (list (list :jsonrpc "2.0" :method "x" :params (list :n 2))
                                           (list :jsonrpc "2.0" :method "x" :params (list :n 3))))
      (harness-test-wait (lambda () (= 4 (length order))) 5 "the messages and the timer")
      (setq order (nreverse order))
      (should (equal '(1 2 3) (remq 'timer order)))
      (should (< (cl-position 'timer order) (cl-position 2 order)))
      ;; One timer for all of them still.
      (should-not harness-acp--inbox-timer)
      ;; A timer of the inbox cancelled behind its back is started anew.
      (harness-acp--enqueue conn (list :jsonrpc "2.0" :method "x" :params (list :n 4)))
      (cancel-timer harness-acp--inbox-timer)
      (harness-acp--enqueue conn (list :jsonrpc "2.0" :method "x" :params (list :n 5)))
      (harness-test-wait (lambda () (memq 5 order)) 5 "the messages after a cancelled timer")
      (should (equal '(5 4) (take 2 order))))))

(ert-deftest harness-acp-once-received-runs-once-a-slice ()
  "Work handlers leave for the end of the slice runs once for all of them,
before the received hook; outside a slice it runs at once."
  (harness-acp-test-with-inbox
    (let* ((harness-acp-receive-slice 10)
           (order nil)
           (redraw (lambda () (push 'redraw order)))
           (harness-acp-test-on-message (lambda (params)
                                          (push (plist-get params :n) order)
                                          (harness-acp-once-received redraw))))
      (add-hook 'harness-acp-received-hook (lambda () (push 'hook order)))
      (dotimes (i 3)
        (harness-acp--enqueue conn (list :jsonrpc "2.0" :method "x" :params (list :n i))))
      (harness-test-wait (lambda () (memq 'hook order)) 5 "the slice handled")
      (should (equal '(0 1 2 redraw hook) (reverse order)))
      (setq order nil)
      (harness-acp-once-received redraw)
      (should (equal '(redraw) order)))))

(ert-deftest harness-acp-local-virtual-sessions-advertised ()
  "The ACP session list advertises the two virtual sessions; loading the
project list and refreshing it rewrites its first message in place."
  (harness-acp-test-with
    (let* ((conn (harness-acp-test-connect))
           (init (harness-test-await (harness-acp-initialize conn)))
           (listed (harness-acp-test-request conn "session/list" nil))
           (second (make-temp-file "harness-acp-virtual-" t)))
      (unwind-protect
          (progn
            (should (plist-member (plist-get init :agentCapabilities) :sessionCapabilities))
            (let* ((sessions (plist-get listed :sessions))
                   (ids (mapcar (lambda (s) (plist-get s :sessionId)) sessions))
                   (projects (cl-find "harness:projects" sessions :key (lambda (s) (plist-get s :sessionId)) :test #'equal))
                   (task (cl-find "harness:new-task" sessions :key (lambda (s) (plist-get s :sessionId)) :test #'equal)))
              (should (member "harness:projects" ids))
              (should (member "harness:new-task" ids))
              (should (equal "Projects" (plist-get projects :title)))
              (should (equal "New task" (plist-get task :title)))
              (should (stringp (plist-get projects :cwd)))
              (should (stringp (plist-get task :cwd))))
            ;; The extension still lists only real sessions.
            (should-not (cl-some (lambda (s) (member (plist-get s :id) '("harness:projects" "harness:new-task")))
                                 (harness-acp-test-request conn "_harness/session/list" nil)))
            (harness-acp-test-request conn "session/load" (list :sessionId "harness:projects"))
            (let* ((chunk (cl-find "user_message_chunk" (harness-acp-test-updates)
                                   :key (lambda (u) (plist-get u :sessionUpdate)) :test #'equal))
                   (node-id (plist-get (plist-get chunk :_harness) :nodeId))
                   (before (plist-get (plist-get chunk :content) :text)))
              (should chunk)
              (should (stringp node-id))
              (should (stringp before))
              ;; A session in a second directory makes that directory a project.
              (harness-acp-test-request conn "session/new"
                                        (list :cwd second :_harness (list :model "demo:scripted")))
              (harness-acp-test-request conn "session/prompt"
                                        (list :sessionId "harness:projects"
                                              :prompt (list (list :type "text" :text "refresh"))))
              (let ((refreshed (cl-find-if
                                (lambda (u)
                                  (and (equal "user_message_chunk" (plist-get u :sessionUpdate))
                                       (equal node-id (plist-get (plist-get u :_harness) :nodeId))
                                       (not (equal before (plist-get (plist-get u :content) :text)))))
                                (harness-acp-test-updates))))
                (should refreshed)
                (should (string-match-p (regexp-quote (file-name-as-directory second))
                                        (plist-get (plist-get refreshed :content) :text))))))
        (ignore-errors (delete-directory second t))))))

(ert-deftest harness-acp-virtual-project-list-is-of-main-checkouts ()
  "Without the insights module the project list is of checkouts, not worktrees.
A session in a git worktree, a sub-agent's say, is filed under the
worktree; the list names the checkout each worktree was made from, also
for one made beside the repository.  A sub-agent's scratch directory in
its parent's temporary directory is no project of its own either."
  (harness-acp-test-with
    (let* ((base (harness-test-temp-dir))
           (main (file-name-as-directory (expand-file-name "repo" base)))
           (inside (file-name-as-directory (expand-file-name ".worktrees/task-a" main)))
           (beside (file-name-as-directory (expand-file-name "repo-worktrees/task-b" base)))
           (other (file-name-as-directory (expand-file-name "other" base))))
      (unwind-protect
          (progn
            (should-not (harness-method-exists-p 'insights/projects))
            (make-directory (expand-file-name ".git" main) t)
            (make-directory other t)
            ;; Worktrees as git leaves them: a .git file naming the gitdir
            ;; the repository keeps for each.
            (dolist (tree (list inside beside))
              (make-directory tree t)
              (with-temp-file (expand-file-name ".git" tree)
                (insert (format "gitdir: %s\n"
                                (expand-file-name
                                 (concat ".git/worktrees/" (file-name-nondirectory (directory-file-name tree)))
                                 main)))))
            (dolist (dir (list main inside beside other))
              (harness-call 'session/create :cwd dir :project dir
                            :id (and (equal dir main) "6f2c1a90-0001-4000-8000-000000000001")))
            ;; A sub-agent works in a scratch directory in its parent's
            ;; temporary directory, whose session may be gone: no project.
            (dolist (scratch (list (expand-file-name
                                    "harness-1000/6f2c1a90-0001-4000-8000-000000000001/q13b-1/" base)
                                   (expand-file-name
                                    "harness-1000/6f2c1a90-0002-4000-8000-000000000002/wt/core/" base)))
              (harness-call 'session/create :cwd scratch :project scratch :kind 'subagent))
            (should (equal (list other main) (harness-acp--virtual-projects)))
            (let ((text (harness-acp--projects-text)))
              (should (string-match-p (regexp-quote main) text))
              (should (string-match-p (regexp-quote other) text))
              (should-not (string-match-p (regexp-quote inside) text))
              (should-not (string-match-p (regexp-quote beside) text))
              (should-not (string-match-p "harness-1000" text))))
        (ignore-errors (delete-directory base t))))))

(ert-deftest harness-acp-local-virtual-task-submit ()
  "Prompting the new-task virtual session submits a task for its project."
  (harness-acp-test-with
    (harness-test-load-module 'priority)
    (harness-test-load-module 'tasks)
    (clrhash harness-tasks--table)
    (clrhash harness-tasks--starting)
    (clrhash harness-tasks--naming)
    (harness-tasks--forget-stores)
    (setq harness-tasks--loaded t
          harness-tasks--dirty nil
          harness-tasks--naming-queue nil)
    (let* ((harness-tasks-max-running 0)
           (harness-naming-auto nil)
           (conn (harness-acp-test-connect))
           (dir (make-temp-file "harness-acp-task-" t))
           (prompt "Add a --verbose flag to the CLI"))
      (unwind-protect
          (progn
            (harness-acp-test-request conn "session/load"
                                      (list :sessionId "harness:new-task" :cwd dir))
            (let ((r (harness-acp-test-request conn "session/prompt"
                                               (list :sessionId "harness:new-task"
                                                     :prompt (list (list :type "text" :text prompt))))))
              (should (equal "end_turn" (plist-get r :stopReason)))
              (let ((task-id (plist-get (plist-get r :_harness) :taskId)))
                (should (stringp task-id))
                (should (cl-find prompt (harness-call 'task/list dir)
                                 :key (lambda (t) (plist-get t :prompt)) :test #'equal))
                (let ((confirm (cl-find-if
                                (lambda (u)
                                  (and (equal "agent_message_chunk" (plist-get u :sessionUpdate))
                                       (string-match-p (regexp-quote task-id)
                                                       (plist-get (plist-get u :content) :text))))
                                (harness-acp-test-updates))))
                  (should confirm)))))
        (ignore-errors (delete-directory dir t))))))

(ert-deftest harness-acp-local-virtual-task-submit-with-pictures ()
  "A picture sent with the prompt of the new-task session is attached to the task it submits.
A standard ACP client composes the task there: what it attaches must not be dropped."
  (harness-acp-test-with
    (harness-test-load-module 'priority)
    (harness-test-load-module 'tasks)
    (clrhash harness-tasks--table)
    (clrhash harness-tasks--starting)
    (clrhash harness-tasks--naming)
    (harness-tasks--forget-stores)
    (setq harness-tasks--loaded t
          harness-tasks--dirty nil
          harness-tasks--naming-queue nil)
    (let* ((harness-tasks-max-running 0)
           (harness-naming-auto nil)
           (conn (harness-acp-test-connect))
           (project (make-temp-file "harness-acp-task-" t))
           (png (base64-decode-string
                 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
           (prompt "Make the button look like this"))
      (unwind-protect
          (progn
            (harness-acp-test-request conn "session/load"
                                      (list :sessionId "harness:new-task" :cwd project))
            (let* ((r (harness-acp-test-request
                       conn "session/prompt"
                       (list :sessionId "harness:new-task"
                             :prompt (list (list :type "text" :text prompt)
                                           (list :type "image" :mimeType "image/png"
                                                 :data (base64-encode-string png t)
                                                 :_harness (list :label "button.png"))))))
                   (task (harness-call 'task/get (plist-get (plist-get r :_harness) :taskId)))
                   (att (car (plist-get task :attachments))))
              (should (equal prompt (plist-get task :prompt)))
              (should (= 1 (length (plist-get task :attachments))))
              (should (equal "button.png" (plist-get att :name)))
              (should (equal "image/png" (plist-get att :mime)))
              (should (file-in-directory-p (plist-get att :path) (expand-file-name "attachments" harness-state-directory)))
              (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert-file-contents-literally (plist-get att :path))
                (should (equal png (buffer-string))))))
        (ignore-errors (delete-directory project t))))))

;;;; Polling the TCP sockets

;; GUI Emacs on macOS can leave a socket unread until the next input event
;; (see "Client: polling the sockets" in harness-acp.el).  These tests
;; connect to a listener of their own, a bare socket to write into as the
;; harness would, so that nothing but the client side is at work, and some
;; make the event loop blind to sockets, as it is there.

(defvar harness-acp-test-peers nil
  "The sockets the test listener accepted, newest first.
That is the listener of `harness-acp-test-with-listener'.  Writing into
one is the harness sending its connection something.")

(defvar harness-acp-test-port nil
  "The port of the listener of `harness-acp-test-with-listener'.")

(defmacro harness-acp-test-with-listener (&rest body)
  "Run BODY with a listener on loopback for TCP client connections to reach.
`harness-acp-test-connect-tcp' connects to it.  The polling state is
BODY's own, with no poll timer and the counters at zero, and whatever
BODY leaves open is closed."
  (declare (indent 0))
  (let ((listener (make-symbol "listener")))
    `(let* ((harness-acp-test-peers nil)
            (,listener (make-network-process
                        :name "harness-acp-test-listener" :server t
                        :host "127.0.0.1" :service t :family 'ipv4
                        :coding 'utf-8-unix :noquery t
                        :log (lambda (_server peer _message)
                               (set-process-query-on-exit-flag peer nil)
                               (push peer harness-acp-test-peers))))
            (harness-acp-test-port (process-contact ,listener :service))
            (harness-acp-token nil)
            (harness-acp--poll-timer nil)
            (harness-acp--poll-timer-interval nil)
            (harness-acp--poll-reads 0)
            (harness-acp--loop-reads 0)
            (harness-acp--poll-failure nil)
            (harness-acp--inbox nil)
            (harness-acp--inbox-tail nil)
            (harness-acp--inbox-timer nil))
       (unwind-protect (progn ,@body)
         (dolist (conn (harness-acp--tcp-connections))
           (harness-acp-close conn))
         (harness-acp--poll-stop)
         (when (timerp harness-acp--inbox-timer) (cancel-timer harness-acp--inbox-timer))
         (mapc #'delete-process harness-acp-test-peers)
         (delete-process ,listener)))))

(defun harness-acp-test-connect-tcp ()
  "Connect to the test listener and return the connection.
That is the listener of `harness-acp-test-with-listener'.  It returns
once the connection is established and the listener has accepted it, so
the newest of `harness-acp-test-peers' is the other end."
  (let* ((accepted (length harness-acp-test-peers))
         (conn (harness-acp-connect (format "127.0.0.1:%d" harness-acp-test-port))))
    (harness-test-wait (lambda () (and (harness-acp-connected-p conn)
                                       (> (length harness-acp-test-peers) accepted)))
                       5 "the connection to open")
    conn))

(defun harness-acp-test-line (n)
  "Return the JSON line of a notification `x' whose :n is N."
  (format "{\"jsonrpc\":\"2.0\",\"method\":\"x\",\"params\":{\"n\":%d}}" n))

(defun harness-acp-test-poll-until (pred)
  "Poll as the timer does until PRED holds, with no event loop run in between.
Error after five seconds.  Return PRED's value."
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (harness-acp--poll))
    (or (funcall pred) (error "Timed out polling"))))

(defun harness-acp-test-spin (pred &optional seconds)
  "Wait with `accept-process-output' alone until PRED holds, or SECONDS pass.
SECONDS defaults to 5.  Return PRED's value.  Timers run; unlike
`harness-test-wait' it calls no `sit-for', whose `sleep-for' would read
sockets too."
  (let ((deadline (+ (float-time) (or seconds 5))) (result nil))
    (while (and (not (setq result (funcall pred))) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    result))

(defmacro harness-acp-test-with-blind-select (&rest body)
  "Run BODY with an event loop blind to sockets, as a UI can have.
Timers run, the screen updates, and nothing reads a socket until an
input event: so it is while a timer keeps setting itself ripe (Emacs
runs the timers due and redisplays, again and again, and never gets to
its select), and so GUI Emacs on macOS may be, where the select that
hands descriptors to a helper thread can lose its wake-up.
Here `accept-process-output' waits as asked, with timers running and a
pipe nobody writes to standing in for what it would wait on, and reads no
socket, but when JUST-THIS-ONE is an integer: that is a select of its
own, as the poll and `harness-acp-call-sync' use.  Wait in BODY with
`harness-acp-test-spin'."
  (declare (indent 0))
  (let ((real (make-symbol "real")) (idle (make-symbol "idle")))
    `(let ((,real (symbol-function 'accept-process-output))
           (,idle (make-pipe-process :name "harness-acp-test-idle" :noquery t)))
       (unwind-protect
           (cl-letf (((symbol-function 'accept-process-output)
                      (lambda (&optional proc seconds millisec just-this-one)
                        (if (integerp just-this-one)
                            (funcall ,real proc seconds millisec just-this-one)
                          (funcall ,real ,idle (or seconds 0.01) millisec t)))))
             ,@body)
         (delete-process ,idle)))))

(ert-deftest harness-acp-poll-timer-runs-while-a-tcp-connection-is-open ()
  "With an interval set, one repeating timer polls the TCP client connections.
It starts with the first, serves the others, and stops with the last,
whether that one is closed or its socket dies.  A local connection has no
socket and starts none."
  (harness-acp-test-with-listener
    (let ((harness-acp-client-poll-interval 0.05))
      (should-not harness-acp--poll-timer)
      (harness-acp-close (harness-acp-connect))
      (should-not harness-acp--poll-timer)
      ;; Closed: the timer stops with its only connection.
      (let* ((conn (harness-acp-test-connect-tcp))
             (timer harness-acp--poll-timer))
        (should (timerp timer))
        (should (memq timer timer-list))
        (should (eq #'harness-acp--poll (timer--function timer)))
        (should (eql 0.05 (timer--repeat-delay timer)))
        (harness-acp-close conn)
        (should-not harness-acp--poll-timer)
        (should-not (memq timer timer-list)))
      ;; Two connections share one timer, which goes with the last of them,
      ;; here when its socket dies and the sentinel says so.
      (let* ((first (harness-acp-test-connect-tcp))
             (timer harness-acp--poll-timer)
             (second (harness-acp-test-connect-tcp))
             (second-peer (car harness-acp-test-peers)))
        (should (eq timer harness-acp--poll-timer))
        (should (= 1 (cl-count #'harness-acp--poll timer-list :key #'timer--function)))
        (harness-acp-close first)
        (should (eq timer harness-acp--poll-timer))
        (should (memq timer timer-list))
        (delete-process second-peer)
        (harness-test-wait (lambda () (not (harness-acp-connection-open second))) 5
                           "the death of the socket noticed")
        (should-not harness-acp--poll-timer)
        (should-not (memq timer timer-list))
        (should-not (cl-find #'harness-acp--poll timer-list :key #'timer--function))))))

(ert-deftest harness-acp-poll-is-off-without-an-interval ()
  "No timer polls when the interval is nil, or is not a positive number.
It is on by default, on every system: a timer that keeps setting itself
ripe starves the event loop of its reads wherever Emacs runs."
  (should (eql 0.1 (eval (car (get 'harness-acp-client-poll-interval 'standard-value)) t)))
  (harness-acp-test-with-listener
    (dolist (interval '(nil 0 -1 "0.1"))
      (let* ((harness-acp-client-poll-interval interval)
             (conn (harness-acp-test-connect-tcp)))
        (should-not harness-acp--poll-timer)
        (should-not (cl-find #'harness-acp--poll timer-list :key #'timer--function))
        (harness-acp-close conn)))))

(ert-deftest harness-acp-poll-follows-the-option ()
  "A change of `harness-acp-client-poll-interval' applies from the next poll.
Another number restarts the timer at that interval and nil stops it; a
connection made after nil was set starts it again."
  (harness-acp-test-with-listener
    (let* ((harness-acp-client-poll-interval 0.05)
           (conn (harness-acp-test-connect-tcp))
           (timer harness-acp--poll-timer))
      (should timer)
      (setq harness-acp-client-poll-interval 0.2)
      (harness-acp--poll)
      (should-not (eq timer harness-acp--poll-timer))
      (should-not (memq timer timer-list))
      (should (memq harness-acp--poll-timer timer-list))
      (should (eql 0.2 (timer--repeat-delay harness-acp--poll-timer)))
      (should (= 1 (cl-count #'harness-acp--poll timer-list :key #'timer--function)))
      (setq harness-acp-client-poll-interval nil)
      (harness-acp--poll)
      (should-not harness-acp--poll-timer)
      (should-not (cl-find #'harness-acp--poll timer-list :key #'timer--function))
      (setq harness-acp-client-poll-interval 0.05)
      (let ((other (harness-acp-test-connect-tcp)))
        (should (memq harness-acp--poll-timer timer-list))
        (harness-acp-close other))
      (should (memq harness-acp--poll-timer timer-list))
      (harness-acp-close conn)
      (should-not harness-acp--poll-timer))))

(ert-deftest harness-acp-poll-setopt-applies-at-once ()
  "`setopt' (and so Customize) starts, retimes and stops the poll timer
for the connections that are open, without waiting for the next poll or
the next connection."
  (harness-acp-test-with-listener
    (let ((original (default-toplevel-value 'harness-acp-client-poll-interval)))
      (unwind-protect
          (progn
            (setopt harness-acp-client-poll-interval nil)
            (let ((conn (harness-acp-test-connect-tcp)))
              (should-not harness-acp--poll-timer)
              (setopt harness-acp-client-poll-interval 0.05)
              (should (memq harness-acp--poll-timer timer-list))
              (should (eql 0.05 (timer--repeat-delay harness-acp--poll-timer)))
              (setopt harness-acp-client-poll-interval 0.5)
              (should (eql 0.5 (timer--repeat-delay harness-acp--poll-timer)))
              (should (= 1 (cl-count #'harness-acp--poll timer-list :key #'timer--function)))
              (setopt harness-acp-client-poll-interval nil)
              (should-not harness-acp--poll-timer)
              (should-not (cl-find #'harness-acp--poll timer-list :key #'timer--function))
              (harness-acp-close conn)))
        (setopt harness-acp-client-poll-interval original)))))

(ert-deftest harness-acp-poll-reads-the-socket-without-the-event-loop ()
  "A poll reads what waits in the socket, and the message reaches the inbox.
Nothing here runs the event loop: the poll reads on its own and runs no
timer, so the message is queued but not handled until the loop runs."
  (harness-acp-test-with-listener
    (let* ((harness-acp-client-poll-interval 60) ; its own timer stays out of this
           (seen nil)
           (canary nil)
           (conn (harness-acp-test-connect-tcp))
           (peer (car harness-acp-test-peers)))
      (harness-acp-set-handler conn (lambda (_method params _respond)
                                      (push (plist-get params :n) seen)))
      (process-send-string peer (concat (harness-acp-test-line 1) "\n"))
      (run-at-time 0 nil (lambda () (setq canary t)))
      (harness-acp-test-poll-until (lambda () (> harness-acp--poll-reads 0)))
      (should (equal (list (cons conn (harness-acp-test-line 1))) harness-acp--inbox))
      (should (= 1 harness-acp--poll-reads))
      (should (= 0 harness-acp--loop-reads))
      ;; It only read: the timers due, a canary and the inbox's own, have not run.
      (should-not canary)
      (should-not seen)
      ;; The event loop then handles what was queued, as it always does.
      (harness-test-wait (lambda () (and canary seen)) 5 "the message handled")
      (should (equal '(1) seen))
      (should-not harness-acp--inbox)
      (harness-acp-close conn))))

(ert-deftest harness-acp-poll-delivers-what-the-event-loop-does-not ()
  "With the event loop blind to sockets, the poll timer is what delivers.
A message the harness sends is never read without it, and handled soon
with it: the situation of a UI whose timers never let Emacs reach its
select, and the way out of it."
  (harness-acp-test-with-listener
    (let* ((harness-acp-client-poll-interval nil)
           (seen nil)
           (conn (harness-acp-test-connect-tcp))
           (peer (car harness-acp-test-peers)))
      (harness-acp-set-handler conn (lambda (_method params _respond)
                                      (push (plist-get params :n) seen)))
      (harness-acp-test-with-blind-select
        ;; Nothing polls: the message sits in the socket.
        (process-send-string peer (concat (harness-acp-test-line 1) "\n"))
        (should-not (harness-acp-test-spin (lambda () seen) 0.3))
        (should-not harness-acp--inbox)
        (should (= 0 harness-acp--loop-reads))
        ;; The option set: the poll reads it and the inbox's timer handles it.
        (setq harness-acp-client-poll-interval 0.02)
        (harness-acp--poll-sync)
        (should harness-acp--poll-timer)
        (should (harness-acp-test-spin (lambda () seen)))
        (should (equal '(1) seen))
        (process-send-string peer (concat (harness-acp-test-line 2) "\n"))
        (should (harness-acp-test-spin (lambda () (equal '(2 1) seen))))
        (should (= 2 harness-acp--poll-reads))
        (should (= 0 harness-acp--loop-reads)))
      (harness-acp-close conn)
      (should-not harness-acp--poll-timer))))

(ert-deftest harness-acp-poll-and-event-loop-share-the-line-buffer ()
  "A line cut between a poll's read and the event loop's is joined, and handled once."
  (harness-acp-test-with-listener
    (let* ((harness-acp-client-poll-interval 60)
           (seen nil)
           (line (harness-acp-test-line 7))
           (conn (harness-acp-test-connect-tcp))
           (peer (car harness-acp-test-peers)))
      (harness-acp-set-handler conn (lambda (_method params _respond)
                                      (push (plist-get params :n) seen)))
      (process-send-string peer (substring line 0 20))
      (harness-acp-test-poll-until (lambda () (= 1 harness-acp--poll-reads)))
      (should-not harness-acp--inbox)
      (process-send-string peer (concat (substring line 20) "\n"))
      (harness-test-wait (lambda () seen) 5 "the line handled")
      (should (equal '(7) seen))
      (should (= 1 harness-acp--loop-reads))
      (harness-acp-close conn))))

(ert-deftest harness-acp-poll-says-once-per-connection-that-it-read ()
  "The poll's reads are counted apart from the event loop's, and the first
poll to read on a connection says in the log that it read what the event
loop had not delivered, naming the option."
  (harness-acp-test-with-listener
    (let* ((harness-acp-client-poll-interval 60)
           (harness-log-level 'info)
           (infos nil)
           (log (lambda (level msg)
                  (when (and (eq level 'info) (string-match-p "had not delivered" msg))
                    (push msg infos))))
           (first (harness-acp-test-connect-tcp))
           (first-peer (car harness-acp-test-peers))
           (second (harness-acp-test-connect-tcp))
           (second-peer (car harness-acp-test-peers)))
      (add-hook 'harness-log-hook log)
      (unwind-protect
          (progn
            ;; The event loop's read is counted as such, and says nothing.
            (process-send-string first-peer (concat (harness-acp-test-line 1) "\n"))
            (harness-test-wait (lambda () (and (= 1 harness-acp--loop-reads)
                                               (null harness-acp--inbox)))
                               5 "the event loop's read handled")
            (should (= 0 harness-acp--poll-reads))
            (should-not infos)
            ;; A poll's read is counted, and the log says so, once for the connection.
            (process-send-string first-peer (concat (harness-acp-test-line 2) "\n"))
            (harness-acp-test-poll-until (lambda () (= 1 harness-acp--poll-reads)))
            (should (= 1 (length infos)))
            (should (string-match-p "event loop had not delivered" (car infos)))
            (should (string-match-p "harness-acp-client-poll-interval" (car infos)))
            (should (string-match-p (regexp-quote (harness-acp-connection-address first)) (car infos)))
            (process-send-string first-peer (concat (harness-acp-test-line 3) "\n"))
            (harness-acp-test-poll-until (lambda () (= 2 harness-acp--poll-reads)))
            (should (= 1 (length infos)))
            ;; Another connection is told once of its own.
            (process-send-string second-peer (concat (harness-acp-test-line 4) "\n"))
            (harness-acp-test-poll-until (lambda () (= 3 harness-acp--poll-reads)))
            (should (= 2 (length infos)))
            (should (= 1 harness-acp--loop-reads)))
        (remove-hook 'harness-log-hook log))
      (harness-acp-close first)
      (harness-acp-close second))))

(ert-deftest harness-acp-poll-never-signals ()
  "An error in a poll is logged, once while it repeats, and does not escape."
  (harness-acp-test-with-listener
    (let* ((harness-acp-client-poll-interval 60)
           (harness-log-level 'info)
           (warned nil)
           (log (lambda (level msg) (when (eq level 'warn) (push msg warned))))
           (conn (harness-acp-test-connect-tcp)))
      (add-hook 'harness-log-hook log)
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'harness-acp--poll-sockets)
                       (lambda () (error "Boom"))))
              (harness-acp--poll)
              (harness-acp--poll))
            (should (= 1 (length warned)))
            (should (string-match-p "Boom" (car warned)))
            ;; A poll that works forgets it, so the same error is logged again.
            (harness-acp--poll)
            (should-not harness-acp--poll-failure)
            (cl-letf (((symbol-function 'harness-acp--poll-sockets)
                       (lambda () (error "Boom"))))
              (harness-acp--poll))
            (should (= 2 (length warned))))
        (remove-hook 'harness-log-hook log))
      (harness-acp-close conn))))

(ert-deftest harness-acp-call-sync-reads-the-socket-before-it-waits ()
  "An answer already in the socket is found by `harness-acp-call-sync' at once.
The event loop's select never reports the socket here, as in GUI Emacs
on macOS when its wake-up is lost: the timed wait reads nothing, the
zero-timeout read before it does."
  (harness-acp-test-with-listener
    (let* ((harness-acp-client-poll-interval nil) ; the poll would read it first
           (conn (harness-acp-test-connect-tcp))
           (peer (car harness-acp-test-peers)))
      ;; The answer to the first request, whose id will be 1, waits before it is asked for.
      (process-send-string peer "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"answer\":42}}\n")
      (harness-acp-test-with-blind-select
        ;; The simulation reads nothing, however long it waits ...
        (should-not (accept-process-output (harness-acp-connection-process conn) 0.1))
        (should-not harness-acp--inbox)
        ;; ... and still the answer comes within a slice, not after the timeout.
        (let ((start (float-time)))
          (should (equal '(:answer 42) (harness-acp-call-sync conn "x" nil 5)))
          (should (< (- (float-time) start) 1)))
        (should-not harness-acp--inbox)
        (should (= 1 harness-acp--poll-reads)))
      (harness-acp-close conn))))

(provide 'harness-acp-test)
;;; harness-acp-test.el ends here
