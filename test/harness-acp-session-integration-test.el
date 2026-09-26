;;; harness-acp-session-integration-test.el --- ACP over real sessions -*- lexical-binding: t; -*-

;;; Commentary:

;; Cross-module check: the ACP agent table talking to the real session
;; service over the in-process transport.  The unit tests for ACP use fake
;; services and the session tests call the service directly; this is where
;; the seam between the two is exercised.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-core)
(require 'harness-acp)
(require 'harness-acp-inprocess)
(require 'harness-session)
(require 'harness-test-helpers)

(harness-module-load 'harness-acp)
(harness-module-load 'harness-session)

(defvar harness-acp-session-integration-test--storage nil
  "Isolated storage directory for one test.")

(defvar harness-acp-session-integration-test--updates nil
  "session/update params captured by the test client, oldest first.")

(defvar harness-acp-session-integration-test--statuses nil
  "Extension status notifications captured by the test client.")

(defun harness-acp-session-integration-test--setup ()
  "Prepare isolated storage and return an (AGENT . CLIENT) pair."
  (setq harness-acp-session-integration-test--storage
        (make-temp-file "harness-int-" t)
        harness-acp-session-integration-test--updates nil
        harness-acp-session-integration-test--statuses nil)
  (clrhash harness-session--active)
  (clrhash harness-session--project-ids)
  ;; Agents from earlier tests still broadcast status; close them.
  (dolist (connection harness-acp--agent-connections)
    (harness-acp-connection-close connection "test cleanup"))
  (setq harness-acp--agent-connections nil)
  (let* ((pair (harness-acp-inprocess-pair))
         (client (cdr pair)))
    (harness-acp-connection-register-method
     client "session/update"
     (lambda (_connection params)
       (setq harness-acp-session-integration-test--updates
             (append harness-acp-session-integration-test--updates (list params)))))
    (harness-acp-connection-register-method
     client "_harness/session_status"
     (lambda (_connection params)
       (setq harness-acp-session-integration-test--statuses
             (append harness-acp-session-integration-test--statuses (list params)))))
    pair))

(defmacro harness-acp-session-integration-test--with-pair (client-symbol &rest body)
  "Run BODY with CLIENT-SYMBOL bound to a client connection."
  (declare (indent 1))
  `(let* (;; Setup creates the isolated storage directory, so it must run
          ;; before `harness-session-storage-directory' is bound to it.
          (pair (harness-acp-session-integration-test--setup))
          (harness-session-storage-directory
           harness-acp-session-integration-test--storage)
          (,client-symbol (cdr pair)))
     ,@body))

(defun harness-acp-session-integration-test--request (client method &optional params)
  "Send METHOD to CLIENT and return the settled result value."
  (let ((deferred (harness-acp-connection-request client method params)))
    (harness-test-settle deferred)
    (when (harness-deferred-rejected-p deferred)
      (signal 'harness-error (list (format "ACP request %s failed: %S"
                                           method (harness-deferred-value deferred)))))
    (harness-deferred-value deferred)))

(defun harness-acp-session-integration-test--new-session (client &optional directory)
  "Create a session on CLIENT and return its result plist."
  (harness-acp-session-integration-test--request
   client "session/new"
   (list :cwd (or directory (make-temp-file "harness-int-project-" t))
         :mcpServers [])))

(ert-deftest harness-acp-session-new-creates-a-real-session ()
  (harness-acp-session-integration-test--with-pair client
    (let ((directory (make-temp-file "harness-int-project-" t))
          (result nil))
      (setq result (harness-acp-session-integration-test--new-session client directory))
      (should (plist-get result :sessionId))
      (should (harness-session-active (plist-get result :sessionId)))
      (should (equal (harness-session-cwd (harness-session-active (plist-get result :sessionId)))
                     (file-name-as-directory directory)))
      (let ((model-option (aref (plist-get result :configOptions) 0)))
        (should (equal (plist-get model-option :category) "model"))))))

(ert-deftest harness-acp-session-prompt-without-agent-is-method-not-found ()
  (harness-acp-session-integration-test--with-pair client
    (let* ((created (harness-acp-session-integration-test--new-session client))
           (deferred (harness-acp-connection-request
                      client "session/prompt"
                      (list :sessionId (plist-get created :sessionId)
                            :prompt (vector (list :type "text" :text "hi"))))))
      (harness-test-settle deferred)
      (should (harness-deferred-rejected-p deferred))
      (should (eq (nth 0 (cdr (harness-deferred-value deferred))) -32601)))))

(ert-deftest harness-acp-session-append-streams-updates ()
  (harness-acp-session-integration-test--with-pair client
    (let* ((created (harness-acp-session-integration-test--new-session client))
           (session-id (plist-get created :sessionId))
           (session (harness-session-active session-id)))
      (harness-session-append
       session
       (list :sessionUpdate "user_message_chunk"
             :content (list :type "text" :text "hello from the service")))
      (should (= (length harness-acp-session-integration-test--updates) 1))
      (let* ((params (car harness-acp-session-integration-test--updates))
             (update (plist-get params :update)))
        (should (equal (plist-get params :sessionId) session-id))
        (should (equal (plist-get update :sessionUpdate) "user_message_chunk"))
        ;; Root-level bookkeeping fields are stripped; ids travel in _meta.
        (should-not (plist-member update :id))
        (should (plist-get (plist-get (plist-get update :_meta) :harness) :entryId))))))

(ert-deftest harness-acp-session-load-replays-the-transcript ()
  (harness-acp-session-integration-test--with-pair client
    (let* ((created (harness-acp-session-integration-test--new-session client))
           (session-id (plist-get created :sessionId))
           (session (harness-session-active session-id)))
      (harness-session-append session (list :sessionUpdate "user_message_chunk"
                                            :content (list :type "text" :text "one")))
      (harness-session-append session (list :sessionUpdate "agent_message_chunk"
                                            :content (list :type "text" :text "two")))
      (harness-session-save session)
      (setq harness-acp-session-integration-test--updates nil)
      ;; Reload from disk in a second client, as a fresh UI would.
      (clrhash harness-session--active)
      (let ((pair (harness-acp-inprocess-pair)))
        ;; Re-register capture on the second client.
        (harness-acp-connection-register-method
         (cdr pair) "session/update"
         (lambda (_connection params)
           (setq harness-acp-session-integration-test--updates
                 (append harness-acp-session-integration-test--updates (list params)))))
        (harness-acp-session-integration-test--request
         (cdr pair) "session/load"
         (list :sessionId session-id :cwd (harness-session-cwd session) :mcpServers [])))
      (let ((kinds (mapcar (lambda (params)
                             (plist-get (plist-get params :update) :sessionUpdate))
                           harness-acp-session-integration-test--updates)))
        (should (member "user_message_chunk" kinds))
        (should (member "agent_message_chunk" kinds))
        (should (member "config_option_update" kinds))))))

(ert-deftest harness-acp-session-list-reports-scoped-sessions ()
  (harness-acp-session-integration-test--with-pair client
    (let* ((project (make-temp-file "harness-int-project-" t))
           (other (make-temp-file "harness-int-other-" t))
           (created (harness-acp-session-integration-test--new-session client project)))
      (harness-acp-session-integration-test--new-session client other)
      (let ((result (harness-acp-session-integration-test--request
                     client "session/list" (list :cwd project))))
        (should (= (length (plist-get result :sessions)) 1))
        (let ((info (aref (plist-get result :sessions) 0)))
          (should (equal (plist-get info :sessionId) (plist-get created :sessionId)))
          (should (equal (plist-get info :cwd) (file-name-as-directory project)))
          (should (plist-get (plist-get info :_meta) :harness)))))))

(ert-deftest harness-acp-session-rename-and-delete ()
  (harness-acp-session-integration-test--with-pair client
    (let* ((created (harness-acp-session-integration-test--new-session client))
           (session-id (plist-get created :sessionId)))
      (harness-service-call "session" 'rename :session-id session-id :title "renamed")
      (should (equal (plist-get (harness-service-call "session" 'info :session-id session-id)
                                :title)
                     "renamed"))
      (harness-acp-session-integration-test--request
       client "session/delete" (list :sessionId session-id))
      (should-not (harness-session-active session-id))
      (should-error (harness-service-call "session" 'info :session-id session-id)
                    :type 'harness-session-not-found))))

(ert-deftest harness-acp-session-status-extension ()
  (harness-acp-session-integration-test--with-pair client
    (let* ((created (harness-acp-session-integration-test--new-session client))
           (session-id (plist-get created :sessionId)))
      (harness-session-set-status (harness-session-active session-id) 'running)
      (harness-session-set-status (harness-session-active session-id) 'idle)
      (should (= (length harness-acp-session-integration-test--statuses) 2))
      (should (equal (plist-get (car harness-acp-session-integration-test--statuses) :status)
                     "running"))
      (should (equal (plist-get (car (last harness-acp-session-integration-test--statuses))
                                :status)
                     "idle")))))

(provide 'harness-acp-session-integration-test)
;;; harness-acp-session-integration-test.el ends here
