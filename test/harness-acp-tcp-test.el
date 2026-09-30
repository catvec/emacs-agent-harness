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
     (let ((harness-acp-server-enabled nil))
       (dolist (m '(store project config provider provider-demo tools session agent acp))
         (harness-test-load-module m)))
     (clrhash harness-sessions)
     (clrhash harness-tools)
     (clrhash harness-agent--turns)
     (setq harness-acp--clients nil
           harness-acp-tcp-test-messages nil)
     (let* ((harness-provider-demo-delay 0.005)
            (harness-acp-token nil)
            (default-directory dir)
            (contact (harness-call 'acp/start :port 0))
            (port (plist-get contact :port)))
       (ignore port)
       (harness-add-filter 'permission/decide
                           (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
       (harness-define-tool "list_dir" :description "list" :kind 'read
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
              (should (= -32001 (car (harness-acp-tcp-test-error conn "_harness/harness/version" nil))))
              (should (= -32001 (car (harness-acp-tcp-test-error conn "session/new" (list :cwd dir)))))
              (should (= -32001 (car (condition-case err
                                         (progn (harness-test-await (harness-acp-authenticate conn "wrong")) nil)
                                       (acp-error (cdr err))))))
              (should (= -32001 (car (harness-acp-tcp-test-error conn "_harness/harness/version" nil))))
              (should (null (harness-test-await (harness-acp-authenticate conn "s3cret"))))
              (should (equal harness-version (plist-get (harness-acp-tcp-test-request conn "_harness/harness/version" nil)
                                                        :version)))
              (harness-acp-close conn))
            ;; A connection made while the token is set authenticates by itself.
            (let ((conn (harness-acp-tcp-test-connect port)))
              (should (equal harness-version (plist-get (harness-acp-tcp-test-request conn "_harness/harness/version" nil)
                                                        :version)))
              (harness-acp-close conn)))
        (setq harness-acp-token saved)))))

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

(ert-deftest harness-acp-tcp-refuses-non-loopback-without-opt-in ()
  (harness-acp-tcp-test-with
    (harness-call 'acp/stop)
    (let ((harness-acp-allow-remote nil))
      (should-error (harness-call 'acp/start :host "0.0.0.0" :port 0) :type 'harness-error))
    (should (eq :false (plist-get (harness-call 'acp/status) :running)))))

(provide 'harness-acp-tcp-test)
;;; harness-acp-tcp-test.el ends here
