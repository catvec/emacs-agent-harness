;;; harness-acp-tcp-test.el --- Tests for the ACP TCP transport  -*- lexical-binding: t; -*-

;;; Commentary:

;; The same core scenario as harness-acp-test.el, but over a real TCP
;; socket to a server started with `acp/start' on an ephemeral port in
;; this very Emacs, plus token authentication and line framing.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-acp)

(defvar harness-acp-tcp-test-messages nil
  "Every (METHOD PARAMS RESPOND) the TCP connection's handler received, newest first.")

(defmacro harness-acp-tcp-test-with (&rest body)
  "Load the state layer and start the ACP server on port 0, run BODY, stop it."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (setq harness-acp--clients nil
           harness-acp-tcp-test-messages nil)
     (let* ((harness-provider-demo--delay 0.005)
            (harness-acp-token nil)
            (default-directory dir)
            (contact (harness-call 'acp/start :port 0))
            (port (plist-get contact :port)))
       (ignore port)
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (harness-define-tool "list_dir" :label "List directory" :description "list" :kind 'read
                            :handler (lambda (input _ctx) (format "listing of %s" (plist-get input :path))))
       (unwind-protect
           (progn ,@body)
         (harness-call 'acp/stop)
         (dolist (c (copy-sequence harness-acp--clients))
           (harness-acp--drop-client c))))))

(defun harness-acp-tcp-test-connect (port)
  "Return an open TCP connection to PORT whose handler records messages."
  (let ((conn (harness-acp-connect (format "127.0.0.1:%d" port))))
    (harness-acp-set-handler conn (lambda (method params respond)
                                    (push (list method params respond) harness-acp-tcp-test-messages)))
    (harness-test-wait (lambda () (harness-acp-connected-p conn)) 5 "tcp connect")
    conn))

(defun harness-acp-tcp-test-request (conn method params)
  "Await METHOD with PARAMS over CONN."
  (harness-test-await (harness-acp-request conn method params)))

(defun harness-acp-tcp-test-error (conn method params)
  "Return the (CODE MESSAGE DATA) rejection of METHOD over CONN, or nil."
  (condition-case err
      (progn (harness-acp-tcp-test-request conn method params) nil)
    (acp-error (cdr err))))

(defun harness-acp-tcp-test-kinds ()
  "Return the sessionUpdate kinds received, oldest first."
  (let (out)
    (dolist (m harness-acp-tcp-test-messages out)
      (when (equal (car m) "session/update")
        (push (plist-get (plist-get (cadr m) :update) :sessionUpdate) out)))))

(ert-deftest harness-acp-tcp-core-scenario ()
  (harness-acp-tcp-test-with
    (should (equal "127.0.0.1" (plist-get contact :host)))
    (should (> port 0))
    (should (equal (format "127.0.0.1:%d" port) (harness-acp-server-address)))
    (let* ((conn (harness-acp-tcp-test-connect port))
           (init (harness-test-await (harness-acp-initialize conn))))
      (should (equal (format "127.0.0.1:%d" port) (harness-acp-connection-address conn)))
      (should (= 1 (plist-get init :protocolVersion)))
      (should (member "session/get" (plist-get (plist-get init :_harness) :methods)))
      (should (= 1 (plist-get (harness-call 'acp/status) :tcp-clients)))
      (let* ((r (harness-acp-tcp-test-request conn "session/new"
                                              (list :cwd (harness-test-temp-dir)
                                                    :_harness (list :model "demo:scripted"))))
             (sid (plist-get r :sessionId)))
        (should (stringp sid))
        (should (equal "ask" (plist-get (plist-get r :modes) :currentModeId)))
        (let ((result (harness-acp-tcp-test-request
                       conn "session/prompt"
                       (list :sessionId sid :prompt (list (list :type "text" :text "give me the tour"))))))
          (should (equal "end_turn" (plist-get result :stopReason))))
        (harness-test-wait (lambda () (member "_harness/session" (harness-acp-tcp-test-kinds))) 5 "_harness/session")
        (let* ((kinds (harness-acp-tcp-test-kinds))
               (pos (lambda (k) (cl-position k kinds :test #'equal))))
          (should (< (funcall pos "agent_thought_chunk") (funcall pos "agent_message_chunk")))
          (should (< (funcall pos "agent_message_chunk") (funcall pos "tool_call")))
          (should (< (funcall pos "tool_call") (funcall pos "tool_call_update")))
          (should (member "_harness/node" kinds)))
        (let ((call (cl-find-if (lambda (m) (and (equal (car m) "session/update")
                                                 (equal "tool_call" (plist-get (plist-get (cadr m) :update) :sessionUpdate))))
                                harness-acp-tcp-test-messages)))
          (should (equal "demo-1" (plist-get (plist-get (cadr call) :update) :toolCallId)))
          (should (equal "read" (plist-get (plist-get (cadr call) :update) :kind))))
        ;; Extension call over JSON: enums come back as strings.
        (let ((s (harness-acp-tcp-test-request conn "_harness/session/get" (list :id sid))))
          (should (equal sid (plist-get s :id)))
          (should (equal "idle" (plist-get s :status)))
          (should (equal "demo:scripted" (plist-get s :model))))
        (should (equal "Renamed" (plist-get (harness-acp-tcp-test-request conn "_harness/session/update"
                                                                          (list :id sid :name "Renamed"))
                                            :name)))
        ;; Errors.
        (should (= -32601 (car (harness-acp-tcp-test-error conn "nope/x" nil))))
        (should (= -32602 (car (harness-acp-tcp-test-error conn "_harness/session/get" nil))))
        ;; Permission round trip through the socket.
        (let ((recorded nil))
          (harness-register-method 'permission/answer
                                   (lambda (s pid answer) (push (list s pid answer) recorded) answer))
          (harness-emit 'permission/requested sid
                        (list :id "p1" :kind 'permission
                              :payload (list :tool "bash" :input '(:command "ls") :kind 'exec
                                             :title "bash ls" :call-id "c1")))
          (harness-test-wait (lambda () (cl-find "session/request_permission" harness-acp-tcp-test-messages
                                                 :key #'car :test #'equal)))
          (let* ((m (cl-find "session/request_permission" harness-acp-tcp-test-messages :key #'car :test #'equal))
                 (params (nth 1 m)))
            (should (equal "c1" (plist-get (plist-get params :toolCall) :toolCallId)))
            (should (equal "execute" (plist-get (plist-get params :toolCall) :kind)))
            (should (equal "p1" (plist-get (plist-get params :_harness) :pendingId)))
            (should (= 5 (length (plist-get params :options))))
            (funcall (nth 2 m) (list :outcome (list :outcome "selected" :optionId "allow-once"))))
          (harness-test-wait (lambda () recorded))
          (should (equal (list (list sid "p1" '(:behavior allow :scope once))) recorded))))
      (let ((closed nil))
        (harness-acp-on-close conn (lambda () (setq closed t)))
        (harness-acp-close conn)
        (harness-test-wait (lambda () closed))
        (should-not (harness-acp-connected-p conn))
        (harness-test-wait (lambda () (= 0 (plist-get (harness-call 'acp/status) :tcp-clients))) 5 "client dropped")))))

(defvar harness-provider-demo-script-override)

(ert-deftest harness-acp-tcp-queue-while-running ()
  "What `harness-chat-queue' sends survives JSON: during a turn it only queues."
  (harness-acp-tcp-test-with
    (let* ((gate (harness-make-promise))
           (harness-provider-demo-script-override
            '((:type tool-call :id "w1" :name "hold" :input (:n 1))
              (:type text :delta "Done.")
              (:type done :stop-reason end-turn)))
           (conn (harness-acp-tcp-test-connect port))
           (sid (progn (harness-test-await (harness-acp-initialize conn))
                       (plist-get (harness-acp-tcp-test-request conn "session/new"
                                                                (list :cwd (harness-test-temp-dir)
                                                                      :_harness (list :model "demo:scripted")))
                                  :sessionId)))
           (p (progn
                ;; The turn waits in this tool until the test lets it go.
                (harness-define-tool "hold" :label "Hold" :description "hold" :kind 'read
                                     :handler (lambda (_input _ctx) (harness-then gate (lambda (_) "held"))))
                (harness-acp-request conn "session/prompt"
                                     (list :sessionId sid :prompt (list (list :type "text" :text "tour")))))))
      (harness-test-wait (lambda () (memq 'tool-call (mapcar (lambda (n) (plist-get n :kind))
                                                             (harness-call 'session/nodes sid))))
                         5 "the turn in its tool")
      (should (eq t (plist-get (harness-acp-tcp-test-request
                                conn "_harness/agent/prompt"
                                (list :session-id sid :blocks (list (list :type "text" :text "for later"))
                                      :opts (list :queue t :attachments nil)))
                               :queued)))
      (should (equal '("for later") (mapcar (lambda (it) (plist-get it :text))
                                            (plist-get (harness-call 'session/get sid) :queue))))
      (should-not (cl-find-if (lambda (n) (plist-get (plist-get n :meta) :steering)) (harness-call 'session/nodes sid)))
      ;; A JSON false sends instead: the message steers the running turn
      ;; (and the answer, the turn's result, comes when the turn ends).
      (let ((steered (harness-acp-request conn "_harness/agent/prompt"
                                          (list :session-id sid :blocks "steer now" :opts (list :queue :false)))))
        ;; It waits for the turn's next step, listed on the session and no
        ;; node of the transcript until the turn takes it.
        (harness-test-wait (lambda () (plist-get (harness-call 'session/get sid) :steering))
                           5 "the steering message")
        (should (equal '("steer now") (mapcar (lambda (it) (plist-get it :text))
                                              (plist-get (harness-call 'session/get sid) :steering))))
        (should-not (cl-find-if (lambda (n) (plist-get (plist-get n :meta) :steering)) (harness-call 'session/nodes sid)))
        (should (= 1 (length (plist-get (harness-call 'session/get sid) :queue))))
        (should (harness-agent-running-p sid))
        (harness-resolve gate t)
        (should (equal "end_turn" (plist-get (harness-test-await p) :stopReason)))
        (should (equal "end-turn" (plist-get (harness-test-await steered) :stop-reason))))
      (harness-test-wait (lambda () (and (null (plist-get (harness-call 'session/get sid) :queue))
                                         (not (harness-agent-running-p sid))))
                         10 "the queued turn")
      (let ((users (cl-remove-if-not (lambda (n) (eq (plist-get n :kind) 'user)) (harness-call 'session/nodes sid))))
        (should (equal '("tour" "steer now" "for later") (mapcar (lambda (n) (plist-get n :content)) users)))
        (should (equal '(nil t nil) (mapcar (lambda (n) (and (plist-get (plist-get n :meta) :steering) t)) users)))))))

(ert-deftest harness-acp-tcp-server-closes-connections ()
  (harness-acp-tcp-test-with
    (let* ((conn (harness-acp-tcp-test-connect port))
           (closed nil)
           (p (progn (harness-acp-on-close conn (lambda () (setq closed t)))
                     (harness-test-await (harness-acp-initialize conn))
                     (harness-call 'acp/stop)
                     (harness-test-wait (lambda () closed) 5 "close from server")
                     (harness-acp-request conn "_harness/harness/version" nil))))
      (should (= -32003 (car (condition-case err (progn (harness-test-await p) nil) (acp-error (cdr err))))))
      (should (eq :false (plist-get (harness-call 'acp/status) :running))))))

(ert-deftest harness-acp-tcp-token-authentication ()
  (harness-acp-tcp-test-with
    (let ((saved harness-acp-token))
      (unwind-protect
          (progn
            ;; Connect without the automatic authenticate by hiding the token from the client.
            (setq harness-acp-token nil)
            (let ((conn (harness-acp-tcp-test-connect port)))
              (setq harness-acp-token "s3cret")
              (should (= 1 (plist-get (harness-test-await (harness-acp-initialize conn)) :protocolVersion)))
              ;; ACP's auth_required, which clients answer by authenticating.
              (should (= -32000 (car (harness-acp-tcp-test-error conn "_harness/harness/version" nil))))
              (should (= -32000 (car (harness-acp-tcp-test-error conn "session/new" (list :cwd dir)))))
              ;; It names the ways in, as some agents do, for a client that shows them to its user.
              (should (equal '("token") (mapcar (lambda (m) (plist-get m :id))
                                                (plist-get (nth 2 (harness-acp-tcp-test-error conn "session/new" (list :cwd dir)))
                                                           :authMethods))))
              (should (= -32000 (car (condition-case err
                                         (progn (harness-test-await (harness-acp-authenticate conn "wrong")) nil)
                                       (acp-error (cdr err))))))
              (should (= -32000 (car (harness-acp-tcp-test-error conn "_harness/harness/version" nil))))
              ;; Until it authenticates it hears nothing of the sessions.
              (harness-acp--broadcast-update "s1" '(:sessionUpdate "agent_message_chunk"
                                                    :content (:type "text" :text "secret")))
              (accept-process-output nil 0.2)
              (should-not (harness-acp-tcp-test-kinds))
              (should (null (harness-test-await (harness-acp-authenticate conn "s3cret"))))
              (should (equal harness-version (plist-get (harness-acp-tcp-test-request conn "_harness/harness/version" nil)
                                                        :version)))
              (harness-acp--broadcast-update "s1" '(:sessionUpdate "agent_message_chunk"
                                                    :content (:type "text" :text "hi")))
              (harness-test-wait (lambda () (harness-acp-tcp-test-kinds)) 5 "the update")
              (harness-acp-close conn))
            ;; A connection made while the token is set authenticates by itself.
            (let ((conn (harness-acp-tcp-test-connect port)))
              (should (equal harness-version (plist-get (harness-acp-tcp-test-request conn "_harness/harness/version" nil)
                                                        :version)))
              (harness-acp-close conn)))
        (setq harness-acp-token saved)))))

(ert-deftest harness-acp-tcp-a-client-that-has-not-authenticated-hears-nothing ()
  "What the harness sends its clients, and asks of them, is for those that may call methods."
  (harness-acp-tcp-test-with
    (let ((saved harness-acp-token))
      (unwind-protect
          (progn
            (setq harness-acp-token nil)
            (let ((conn (harness-acp-tcp-test-connect port)))
              (setq harness-acp-token "s3cret")
              (harness-test-await (harness-acp-initialize conn))
              (should (null (harness-acp--serving-clients)))
              (harness-acp--broadcast "_test/note" (list :n 1))
              (harness-acp--request-clients "_test/ask" nil #'ignore)
              (sleep-for 0.2)
              (should (null (harness-acp-tcp-test-notes)))
              (should (null (cl-find "_test/ask" harness-acp-tcp-test-messages :key #'car :test #'equal)))
              ;; Once it authenticated, it is one of the clients a message is for.
              (should (null (harness-test-await (harness-acp-authenticate conn "s3cret"))))
              (should (= 1 (length (harness-acp--serving-clients))))
              (harness-acp--broadcast "_test/note" (list :n 2))
              (harness-test-wait (lambda () (equal '(2) (harness-acp-tcp-test-notes))) 5 "the note")
              (harness-acp-close conn)))
        (setq harness-acp-token saved)))))

(ert-deftest harness-acp-authenticate-may-answer-with-more-than-nothing ()
  "A function that signs a client in can hand it something in the answer's `_meta'."
  (harness-acp-tcp-test-with
    (let ((harness-acp-authenticate-functions
           (list (lambda (_c method _params)
                   (and (equal method "extra") (list :_meta (list :harness (list :session (list :token "hs1_x")))))))))
      (let* ((saved harness-acp-token))
        (unwind-protect
            (progn
              (setq harness-acp-token nil)
              (let ((conn (harness-acp-tcp-test-connect port)))
                (setq harness-acp-token "s3cret")
                (harness-test-await (harness-acp-initialize conn))
                (let ((result (harness-test-await (harness-acp-request conn "authenticate" '(:methodId "extra")))))
                  (should (equal "hs1_x" (plist-get (plist-get (plist-get (plist-get result :_meta) :harness) :session) :token))))
                (harness-acp-close conn)))
          (setq harness-acp-token saved))))))

(defun harness-acp-tcp-test-raw-client (port)
  "Return (PROC . LINES-CELL): a raw socket to PORT collecting response lines."
  (let* ((lines (list nil))
         (buf "")
         (proc (make-network-process
                :name "acp-raw" :host "127.0.0.1" :service port :noquery t :coding 'utf-8-unix
                :filter (lambda (_p chunk)
                          (setq buf (concat buf chunk))
                          (let (nl)
                            (while (setq nl (string-search "\n" buf))
                              (push (harness-json-parse (substring buf 0 nl)) (car lines))
                              (setq buf (substring buf (1+ nl)))))))))
    (cons proc lines)))

(ert-deftest harness-acp-tcp-line-framing ()
  (harness-acp-tcp-test-with
    ;; This test is about the framing; the token has its own tests below.
    (setq harness-acp-token nil)
    (pcase-let* ((`(,proc . ,lines) (harness-acp-tcp-test-raw-client port))
                 (msg (lambda (id) (format "{\"jsonrpc\":\"2.0\",\"id\":%d,\"method\":\"_harness/harness/version\",\"params\":{}}" id))))
      (unwind-protect
          (progn
            ;; Two messages in one chunk.
            (process-send-string proc (concat (funcall msg 1) "\n" (funcall msg 2) "\r\n"))
            (harness-test-wait (lambda () (= 2 (length (car lines)))) 5 "two responses")
            ;; One message split across chunks.
            (let* ((whole (concat (funcall msg 3) "\n"))
                   (cut (/ (length whole) 2)))
              (process-send-string proc (substring whole 0 cut))
              (accept-process-output nil 0.05)
              (should (= 2 (length (car lines))))
              (process-send-string proc (substring whole cut)))
            (harness-test-wait (lambda () (= 3 (length (car lines)))) 5 "third response")
            ;; Garbage gets a parse error with a null id, and the connection survives.
            (process-send-string proc "this is not json\n")
            (harness-test-wait (lambda () (= 4 (length (car lines)))) 5 "parse error")
            (process-send-string proc (concat (funcall msg 4) "\n"))
            (harness-test-wait (lambda () (= 5 (length (car lines)))) 5 "after parse error")
            (let ((responses (reverse (car lines))))
              (should (equal '(1 2 3) (mapcar (lambda (r) (plist-get r :id)) (seq-take responses 3))))
              (dolist (r (seq-take responses 3))
                (should (equal harness-version (plist-get (plist-get r :result) :version))))
              (should (null (plist-get (nth 3 responses) :id)))
              (should (= -32700 (plist-get (plist-get (nth 3 responses) :error) :code)))
              (should (= 4 (plist-get (nth 4 responses) :id)))))
        (delete-process proc)))))

(ert-deftest harness-acp-tcp-a-listener-with-no-token-makes-one ()
  "`acp/start' gives an instance a secret when none is configured, and requires it."
  (harness-acp-tcp-test-with
    (should (stringp harness-acp-token))
    (should (harness-instance-token-p harness-acp-token))
    ;; It is delivered out of band, in the 0600 file the stdio bridge reads.
    (should (equal (concat harness-acp-token "\n")
                   (harness-read-file (expand-file-name "acp-token" harness-state-directory))))
    (let ((mode (file-modes (expand-file-name "acp-token" harness-state-directory))))
      (should (zerop (logand #o077 mode))))
    ;; A raw client that does not authenticate learns nothing.
    (pcase-let ((`(,proc . ,lines) (harness-acp-tcp-test-raw-client port))
                 (version "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"_harness/harness/version\",\"params\":{}}"))
      (unwind-protect
          (progn
            (process-send-string proc (concat version "\n"))
            (harness-test-wait (lambda () (car lines)) 5 "the refusal")
            (should (= -32000 (plist-get (plist-get (car (car lines)) :error) :code)))
            ;; Another harness instance's token is no better.
            (process-send-string
             proc (format "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"authenticate\",\"params\":{\"token\":\"%s\"}}\n"
                          (harness-instance-credential "another-acp")))
            (harness-test-wait (lambda () (= 2 (length (car lines)))) 5 "the wrong-token refusal")
            (should (= -32000 (plist-get (plist-get (car (car lines)) :error) :code)))
            ;; This instance's own token works, and then so does the request.
            (process-send-string
             proc (format "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"authenticate\",\"params\":{\"token\":\"%s\"}}\n"
                          harness-acp-token))
            (harness-test-wait (lambda () (= 3 (length (car lines)))) 5 "the authentication")
            (should-not (plist-get (car (car lines)) :error))
            (process-send-string proc (concat version "\n"))
            (harness-test-wait (lambda () (= 4 (length (car lines)))) 5 "the version")
            (should (equal harness-version
                           (plist-get (plist-get (car (car lines)) :result) :version))))
        (delete-process proc)))))

(ert-deftest harness-acp-tcp-slow-client-gets-sends-in-line ()
  "What is sent to a client that does not read waits in line, not nested.
`process-send-string' runs the timers due while it waits for room in
the socket, and each of them sending to the same client used to wait
inside the one before: a UI busy for a while, with sessions streaming
to it, made the harness process exceed `max-lisp-eval-depth'."
  (harness-acp-tcp-test-with
    (let* ((conn (harness-acp-tcp-test-connect port))
           (client (progn (harness-test-await (harness-acp-initialize conn))
                          (cl-find 'tcp harness-acp--clients :key #'harness-acp-client-kind)))
           (socket (harness-acp-connection-process conn))
           (pad (make-string 1000000 ?x))
           (n 30)
           (sending 0)
           (deepest 0)
           (received (lambda ()
                       (let (out)
                         (dolist (m harness-acp-tcp-test-messages out)
                           (when (equal (car m) "_test/pad")
                             (push (plist-get (cadr m) :n) out)))))))
      ;; The client stops reading, as a busy UI does, while the server
      ;; sends it far more than its socket holds.
      (stop-process socket)
      (dotimes (i n)
        (run-at-time 0 nil (lambda ()
                             (setq deepest (max deepest (cl-incf sending)))
                             (unwind-protect
                                 (harness-acp--client-notify client "_test/pad" (list :n i :pad pad))
                               (cl-decf sending)))))
      (run-at-time 1 nil #'continue-process socket)
      (harness-test-wait (lambda () (= n (length (funcall received)))) 30 "the notifications")
      (should (equal (number-sequence 0 (1- n)) (funcall received)))
      ;; One send waited for room; the timers run meanwhile queued theirs.
      (should (<= deepest 2))
      (should (memq client harness-acp--clients))
      (should-not (harness-process-sending-p (harness-acp-client-process client))))))

(ert-deftest harness-acp-tcp-non-reader-isolated-from-healthy-rpc ()
  "A stopped socket holds no dispatch open; healthy RPC runs in its owner.
The deadline needs no subsequent send, rejects pending requests once,
and releases the FIFO, timer and writer thread."
  (harness-acp-tcp-test-with
    (let* ((slow (harness-acp-tcp-test-connect port))
           (_ (harness-test-await (harness-acp-initialize slow)))
           (client (cl-find 'tcp harness-acp--clients :key #'harness-acp-client-kind))
           (proc (harness-acp-client-process client))
           (socket (harness-acp-connection-process slow))
           (healthy (harness-acp-tcp-test-connect port))
           (_ (harness-test-await (harness-acp-initialize healthy)))
           (harness-process-send-timeout 0.6)
           (owner (current-thread))
           (pad (make-string (* 16 1024 1024) ?x))
           (rejected 0)
           callback-thread sentinel-thread rpc-thread tick-threads state safety tick)
      (unwind-protect
          (progn
            (should (eq owner (process-thread proc)))
            (let ((sentinel (process-sentinel proc)))
              (set-process-sentinel proc (lambda (p e)
                                           (setq sentinel-thread (current-thread))
                                           (funcall sentinel p e))))
            (stop-process socket)
            ;; This request cannot be answered by the non-reading client.
            (harness-acp--client-request
             client "_test/owed" nil
             (lambda (_result error)
               (setq callback-thread (current-thread))
               (cl-incf rejected)
               (should (= harness-acp-error-transport (plist-get error :code)))))
            ;; Safe even against the old indefinitely-blocking implementation.
            (setq safety (run-at-time 2 nil #'harness-acp--drop-client client)
                  tick (run-at-time 0.03 0.03 (lambda () (push (current-thread) tick-threads))))
            (let ((start (float-time)))
              (harness-acp--client-notify client "_test/pad" (list :pad pad))
              (should (< (- (float-time) start) 0.5)))
            (setq state (process-get proc 'harness--async-send))
            (harness-test-wait (lambda () (harness--async-send-active state)) 1 "blocked socket")
            (should (process-live-p proc))
            (should (eq t (harness-process-sending-p proc)))
            ;; A real independent RPC, while the slow socket is still blocked.
            (harness-register-method 'session/test-transport-owner
                                     (lambda ()
                                       (setq rpc-thread (current-thread))
                                       (list :version harness-version)))
            (let* ((start (float-time))
                   (result (harness-acp-tcp-test-request healthy "_harness/session/test-transport-owner" nil)))
              (should (equal harness-version (plist-get result :version)))
              (should (< (- (float-time) start) 0.5)))
            (should (process-live-p proc))
            (harness-test-wait (lambda () (not (memq client harness-acp--clients))) 2 "slow peer deadline")
            (harness-test-wait (lambda () (not (thread-live-p (harness--async-send-thread state))))
                               2 "writer exit")
            (should (= 1 rejected))
            (should (= 0 (hash-table-count (harness-acp-client-pending client))))
            (should-not (process-get proc 'harness--async-send))
            (should-not (harness--async-send-timer state))
            (should-not (harness--async-send-queue state))
            (should (= 0 (harness--async-send-bytes state)))
            (should (eq owner callback-thread))
            (should (eq owner sentinel-thread))
            (should (eq owner rpc-thread))
            (should tick-threads)
            (should (cl-every (lambda (thread) (eq owner thread)) tick-threads))
            ;; A repeated disconnect does not reject anything twice.
            (harness-acp--drop-client client)
            (should (= 1 rejected))
            (should (harness-acp-connected-p healthy)))
        (when safety (cancel-timer safety))
        (when tick (cancel-timer tick))
        (harness-acp-close healthy)
        (harness-acp-close slow)))))

(ert-deftest harness-acp-tcp-refuses-non-loopback-without-opt-in ()
  (harness-acp-tcp-test-with
    (harness-call 'acp/stop)
    (let ((harness-acp-allow-remote nil))
      (should-error (harness-call 'acp/start :host "0.0.0.0" :port 0) :type 'harness-error))
    (should (eq :false (plist-get (harness-call 'acp/status) :running)))))

(ert-deftest harness-acp-tcp-corporate-mode-stays-on-this-machine ()
  "Corporate mode ignores `harness-acp-allow-remote' and connects nowhere else."
  (harness-acp-tcp-test-with
    (harness-call 'acp/stop)
    (let ((harness-corporate-mode t)
          (harness-acp-allow-remote t))
      (let ((err (should-error (harness-call 'acp/start :host "0.0.0.0" :port 0) :type 'harness-error)))
        (should (string-match-p "corporate mode" (cadr err))))
      (should (eq :false (plist-get (harness-call 'acp/status) :running)))
      (let ((err (should-error (harness-acp-connect "192.0.2.1:9") :type 'acp-error)))
        (should (string-match-p "Corporate mode" (nth 2 err))))
      ;; This machine's own harness stays reachable.
      (let* ((contact (harness-call 'acp/start :port 0))
             (conn (harness-acp-tcp-test-connect (plist-get contact :port))))
        (should (equal harness-version
                       (plist-get (harness-acp-tcp-test-request conn "_harness/harness/version" nil) :version)))
        (harness-acp-close conn)))))

(ert-deftest harness-acp-tcp-ignores-dollar-notifications ()
  "`$/ping' heartbeats get no answer and leave nothing in the log."
  (harness-acp-tcp-test-with
    (pcase-let ((`(,proc . ,lines) (harness-acp-tcp-test-raw-client port)))
      (unwind-protect
          (let ((logged (with-current-buffer (get-buffer-create harness-log-buffer-name) (buffer-size))))
            (process-send-string proc "{\"jsonrpc\":\"2.0\",\"method\":\"$/ping\"}\n")
            (process-send-string proc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"_harness/harness/version\",\"params\":{}}\n")
            (harness-test-wait (lambda () (car lines)) 5 "the version")
            (should (= 1 (length (car lines))))
            (should-not (string-match-p "\\$/ping"
                                        (with-current-buffer harness-log-buffer-name
                                          (buffer-substring-no-properties (1+ logged) (point-max))))))
        (delete-process proc)))))

(defun harness-acp-tcp-test-add-client (address)
  "Register a client of a test transport from ADDRESS; return (CLIENT . SENT-CELL).
SENT-CELL's car collects the parsed messages the server writes, newest first."
  (let* ((sent (list nil))
         (client (harness-acp-add-client
                  'test :writer (lambda (_c text) (push (harness-json-parse text) (car sent)))
                  :remote (list :address address))))
    (cons client sent)))

(defun harness-acp-tcp-test-answer (sent client id method &optional params)
  "Send request ID METHOD PARAMS as CLIENT and return the answer from SENT."
  (harness-acp-client-receive client (harness-json-encode (list :jsonrpc "2.0" :id id :method method
                                                                :params (or params :empty))))
  (harness-test-wait (lambda () (cl-find id (car sent) :key (lambda (m) (plist-get m :id)))) 5 method)
  (cl-find id (car sent) :key (lambda (m) (plist-get m :id))))

(ert-deftest harness-acp-other-transport-clients ()
  "A client from another device authenticates even without a token."
  (harness-acp-tcp-test-with
    (pcase-let ((`(,client . ,sent) (harness-acp-tcp-test-add-client "192.0.2.7"))
                (harness-acp-authorize-functions nil))
      (should (equal '(:address "192.0.2.7") (harness-acp-client-remote-info client)))
      (should (= 1 (plist-get (plist-get (harness-acp-tcp-test-answer sent client 1 "initialize"
                                                                      '(:protocolVersion 1))
                                         :result)
                              :protocolVersion)))
      (let ((answer (harness-acp-tcp-test-answer sent client 2 "_harness/harness/version")))
        (should (= -32000 (plist-get (plist-get answer :error) :code))))
      ;; A function of `harness-acp-authorize-functions' lets it in.
      (let ((harness-acp-authorize-functions (list (lambda (c) (eq c client)))))
        (should (equal harness-version
                       (plist-get (plist-get (harness-acp-tcp-test-answer sent client 3 "_harness/harness/version")
                                             :result)
                                  :version)))
        ;; Corporate mode refuses it all the same, and drops it once turned on.
        (let ((harness-corporate-mode t))
          (should (= -32000 (plist-get (plist-get (harness-acp-tcp-test-answer
                                                   sent client 4 "_harness/harness/version")
                                                  :error)
                                       :code)))
          (harness-acp--on-corporate-mode)
          (should-not (memq client harness-acp--clients)))))))

;; A client on another device is let in by the authorizing functions and
;; by nothing else, asked at every request.

(ert-deftest harness-acp-other-device-clients-answer-to-the-authorizers-alone ()
  "Neither `harness-acp-token' nor a flag set on the client lets one in."
  (harness-acp-tcp-test-with
    (pcase-let ((`(,client . ,sent) (harness-acp-tcp-test-add-client "192.0.2.8"))
                (harness-acp-authorize-functions nil)
                (harness-acp-token "a-shared-secret-of-this-machine"))
      (let ((code (lambda (id method &optional params)
                    (plist-get (plist-get (harness-acp-tcp-test-answer sent client id method params) :error) :code))))
        ;; The secret of this machine's own proves nothing from there.
        (should (= -32000 (funcall code 1 "authenticate"
                                   '(:methodId "token" :token "a-shared-secret-of-this-machine"))))
        (should (= -32000 (funcall code 2 "_harness/harness/version")))
        ;; Nor does a flag: only what the authorizers say now.
        (setf (harness-acp-client-authenticated client) t)
        (should (= -32000 (funcall code 3 "_harness/harness/version")))
        (let* ((allowed t)
               (harness-acp-authorize-functions (list (lambda (c) (and allowed (eq c client))))))
          (should (null (funcall code 4 "_harness/harness/version")))
          (setq allowed nil)
          (should (= -32000 (funcall code 5 "_harness/harness/version"))))
        ;; The shared secret is not offered to it as a way in, and until it is in
        ;; it is told nothing about the harness.
        (let ((init (plist-get (harness-acp-tcp-test-answer sent client 6 "initialize" '(:protocolVersion 1)) :result)))
          (should (= 1 (plist-get init :protocolVersion)))
          (should (null (plist-get init :authMethods)))
          (should-not (plist-member init :_harness))
          (should-not (plist-get (plist-get init :agentInfo) :version))
          (should (equal "emacs-agent-harness" (plist-get (plist-get init :agentInfo) :name))))
        ;; A client on this machine is offered it, and is told everything.
        (let ((conn (harness-acp-connect nil)))
          (unwind-protect
              (let ((init (harness-test-await (harness-acp-initialize conn))))
                (should (equal '("token") (mapcar (lambda (m) (plist-get m :id)) (plist-get init :authMethods))))
                (should (plist-get init :_harness)))
            (harness-acp-close conn)))))))

(ert-deftest harness-acp-initialize-hooks-add-to-the-answer ()
  "Functions of the two hooks add capabilities and `_harness' data; a broken one is skipped."
  (harness-acp-tcp-test-with
    (let ((harness-acp-agent-capabilities-functions
           (list (lambda (_c) (list :auth (list :logout :empty)))
                 (lambda (_c) (error "broken"))))
          (harness-acp-initialize-extras-functions
           (list (lambda (_c) (list :session (list :token "hs1_x")))
                 (lambda (_c) (error "broken")))))
      (let* ((conn (harness-acp-tcp-test-connect port))
             (init (harness-test-await (harness-acp-initialize conn))))
        (unwind-protect
            (progn
              (should (plist-member (plist-get (plist-get init :agentCapabilities) :auth) :logout))
              (should (plist-get (plist-get init :agentCapabilities) :loadSession))
              (should (equal "hs1_x" (plist-get (plist-get (plist-get init :_harness) :session) :token)))
              (should (plist-get (plist-get init :_harness) :methods)))
          (harness-acp-close conn))))))

;;;; Waiting for one answer

(defun harness-acp-tcp-test-notes ()
  "Return the N of each `_test/note' the connection's handler got, oldest first."
  (let (out)
    (dolist (m harness-acp-tcp-test-messages out)
      (when (equal (car m) "_test/note")
        (push (plist-get (cadr m) :n) out)))))

(ert-deftest harness-acp-tcp-call-sync-waits-for-its-answer ()
  "`harness-acp-call-sync' returns the answer before it returns, also where
nothing may wait for input; it signals an error answer as the request's
promise rejects, and gives up in time."
  (harness-acp-tcp-test-with
    (let* ((conn (harness-acp-tcp-test-connect port))
           (session (progn (harness-test-await (harness-acp-initialize conn))
                           (harness-call 'session/create :cwd (harness-test-temp-dir)
                                         :name "Listed" :model "demo:scripted"))))
      (should (equal (list (plist-get session :id))
                     (mapcar (lambda (s) (plist-get s :id))
                             (harness-acp-call-sync conn "_harness/session/list" nil))))
      (let ((inhibit-interaction t))
        (should (equal "Listed" (plist-get (car (harness-acp-call-sync conn "_harness/session/list" nil))
                                           :name))))
      (let ((err (should-error (harness-acp-call-sync conn "_harness/nope/x" nil) :type 'acp-error)))
        (should (= -32601 (nth 1 err))))
      ;; A method that never answers: the wait ends on time, and the
      ;; request is forgotten.
      (harness-register-method 'session/test-never (lambda () (harness-make-promise)))
      (let* ((start (float-time))
             (err (should-error (harness-acp-call-sync conn "_harness/session/test-never" nil 0.3)
                                :type 'harness-error)))
        (should (equal "The harness did not answer _harness/session/test-never within 0.3s" (cadr err)))
        (should (< (- (float-time) start) 2)))
      (should (zerop (hash-table-count (harness-acp-connection-pending conn))))
      (should-not harness-acp--inbox-held)
      (harness-acp-close conn))))

(ert-deftest harness-acp-tcp-call-sync-handles-the-rest-after ()
  "What arrives while `harness-acp-call-sync' waits is handled once the
wait is over, in the order it came, and none of it before."
  (harness-acp-tcp-test-with
    (let ((conn (harness-acp-tcp-test-connect port)))
      (harness-test-await (harness-acp-initialize conn))
      ;; Two notes before the answer is under way, one as it goes out.
      (harness-register-method
       'session/test-notify
       (lambda ()
         (harness-acp--broadcast "_test/note" (list :n 1))
         (harness-acp--broadcast "_test/note" (list :n 2))
         (harness-with-promise (resolve reject)
           (run-at-time 0.1 nil (lambda ()
                                  (harness-acp--broadcast "_test/note" (list :n 3))
                                  (funcall resolve (list :done t)))))))
      (should (equal '(:done t) (harness-acp-call-sync conn "_harness/session/test-notify" nil)))
      (should-not (harness-acp-tcp-test-notes))
      (should harness-acp--inbox)
      (harness-test-wait (lambda () (= 3 (length (harness-acp-tcp-test-notes)))) 5 "the notes")
      (should (equal '(1 2 3) (harness-acp-tcp-test-notes)))
      ;; A wait left by a throw, as an evaluation's timer stops one, leaves
      ;; what came meanwhile to be handled all the same.
      (setq harness-acp-tcp-test-messages nil)
      (harness-register-method
       'session/test-late
       (lambda ()
         (harness-acp--broadcast "_test/note" (list :n 4))
         (harness-with-promise (resolve reject)
           (run-at-time 0.5 nil resolve t))))
      (should (eq 'stopped (catch 'stop
                             (run-at-time 0.2 nil (lambda () (throw 'stop 'stopped)))
                             (harness-acp-call-sync conn "_harness/session/test-late" nil))))
      (should-not harness-acp--inbox-held)
      (harness-test-wait (lambda () (equal '(4) (harness-acp-tcp-test-notes))) 5 "the note after the throw")
      (harness-acp-close conn))))

(ert-deftest harness-acp-tcp-no-client-can-call-a-method-with-lisp-arguments ()
  "`_harness/harness/call', which took a method's arguments as printed Lisp
for an Emacs that evaluated a model's code, is gone: it is no method, and
no client can call it, from this machine or from another device.  Its
neighbours answer as before."
  (harness-acp-tcp-test-with
    (should-not (harness-method-exists-p 'harness/call))
    (should-not (member "harness/call" harness-acp-extension-prefixes))
    (should-not (fboundp 'harness-acp-call-lisp))
    (let ((conn (harness-acp-tcp-test-connect port)))
      (harness-test-await (harness-acp-initialize conn))
      (let ((err (should-error (harness-acp-call-sync conn "_harness/harness/call"
                                                      '(:method "session/list" :args "()"))
                               :type 'acp-error)))
        (should (= -32601 (nth 1 err))))
      (should (plist-get (harness-acp-call-sync conn "_harness/harness/version" nil) :version))
      (harness-acp-close conn))
    (pcase-let ((`(,client . ,sent) (harness-acp-tcp-test-add-client "192.0.2.9"))
                (harness-acp-authorize-functions nil))
      (let ((harness-acp-authorize-functions (list (lambda (c) (eq c client)))))
        (harness-acp-tcp-test-answer sent client 1 "initialize" '(:protocolVersion 1))
        (should (listp (plist-get (harness-acp-tcp-test-answer sent client 2 "_harness/session/list") :result)))
        (let ((e (plist-get (harness-acp-tcp-test-answer sent client 3 "_harness/harness/call"
                                                         '(:method "session/list" :args "()"))
                            :error)))
          (should (= -32601 (plist-get e :code))))
        (should-not harness-acp--calling-client)))))

;;;; The accept queue

(defun harness-acp-tcp-test-listen-backlog (port)
  "Return (RECV-Q . BACKLOG) of the kernel's socket listening on PORT, or nil.
The pair is read from `ss', which reports the queue of connections the
kernel has accepted and Emacs has not, and the length that queue may
grow to.  A backlog of 5 is Emacs's own default (`:server t'), and it is
what a busy event loop overflows: the connections past it are not
refused but left waiting, so a client hangs for the kernel's SYN
retransmits and then fails, and every attempt after that waits again."
  (with-temp-buffer
    (when (eq 0 (ignore-errors (call-process "ss" nil t nil "-ltn")))
      (goto-char (point-min))
      ;; `ss' prints State, Recv-Q, Send-Q, Local Address, Peer Address, so
      ;; the two queue numbers come before the address that names the port.
      (when (re-search-forward (format "LISTEN\\s-+\\([0-9]+\\)\\s-+\\([0-9]+\\)\\s-+\\S-*:%d\\s-+" port)
                               nil t)
        (cons (string-to-number (match-string 1))
              (string-to-number (match-string 2)))))))

(ert-deftest harness-acp-tcp-the-accept-queue-is-deeper-than-emacs-default ()
  "The listener queues more than Emacs's default five pending connections.
Five is not a queue but a race.  A client whose SYN arrives while the
event loop is busy is left in a queue that is already full, and the
kernel retransmits its SYN for about two minutes before the connect
fails: that is a client that cannot connect in under a minute and takes
minutes to reconnect, on a harness that is merely busy.  The queue is
what `harness-listen-backlog' is for, and every listener the harness
serves clients from takes it."
  (harness-acp-tcp-test-with
    (let ((q (harness-acp-tcp-test-listen-backlog port)))
      (unless q
        (ert-skip "ss cannot report the socket's queue here"))
      (should (>= (cdr q) harness-listen-backlog))
      (should (> (cdr q) 5)))))

(ert-deftest harness-acp-tcp-every-listener-takes-the-deep-queue ()
  "No listener in the tree is left on Emacs's default five.
A listener written later with `:server t' reintroduces the hang this
module's queue was made deep to avoid, and it is invisible: the server
starts, binds, and looks healthy while its queue is one connection
deep.  The five listeners here serve ACP on this machine and to other
devices, the Claude plugin, the ChatGPT plan callback and the
workspace box's port probe."
  (let ((root (expand-file-name "lisp" harness-test-root))
        (found 0))
    (dolist (file (directory-files-recursively root "\\.el\\'"))
      (unless (string-match-p "-test\\.el\\'" file)
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (re-search-forward ":server\\s-+\\([^ \t\n)]+\\)" nil t)
            (cl-incf found)
            (should-not (equal (match-string 1) "t"))))))
    (should (> found 0))))

(provide 'harness-acp-tcp-test)
;;; harness-acp-tcp-test.el ends here
