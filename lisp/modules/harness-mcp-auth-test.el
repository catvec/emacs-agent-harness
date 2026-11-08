;;; harness-mcp-auth-test.el --- Per-instance authentication of the MCP transports  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; The harness's MCP servers are its own instance's, not every local
;; process's: this suite checks the identity and secret of one harness
;; process, that the dispatcher refuses an `initialize' without the
;; credential, and that a real file-tools worker refuses an
;; unauthenticated client while the harness's own host still serves its
;; calls.  The listener and relay have their own suite
;; (lisp/harness-claude-plugin-test.el), and the ACP token has
;; lisp/modules/harness-acp-tcp-test.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'harness-test-helpers)
(require 'harness-instance)
(require 'harness-mcp-protocol)
(require 'harness-tools-fs)

(defun harness-mcp-auth-test--hex (bytes)
  "Return BYTES as lower-case hexadecimal."
  (mapconcat (lambda (b) (format "%02x" b)) bytes ""))

(defun harness-mcp-auth-test--server (&optional auth)
  "Return a server named \"auth\" with one echo tool, expecting AUTH."
  (harness-mcp-make-server
   :name "auth" :version "1"
   :auth auth
   :tools (list (harness-mcp-make-tool
                 :name "echo" :schema '(:type "object")
                 :handler (lambda (args _ctx)
                            (format "echo: %s" (plist-get args :text)))))))

(defun harness-mcp-auth-test--serve (server method &optional params)
  "Send METHOD with PARAMS to SERVER as request 1; return the response."
  (let ((response (harness-mcp-serve server (harness-mcp-request 1 method params))))
    (if (harness-promise-p response) (harness-test-await response) response)))

(defun harness-mcp-auth-test--initialize (&optional auth)
  "Return initialize params carrying AUTH."
  (append (list :protocolVersion harness-mcp-protocol-version
                :capabilities :empty
                :clientInfo (list :name "test" :version "1"))
          (when auth (list :_meta (harness-mcp-auth-meta auth)))))

(defun harness-mcp-auth-test--error-code (response)
  "Return the JSON-RPC error code of RESPONSE, or nil."
  (plist-get (plist-get response :error) :code))

;;;; The instance and its credentials

(ert-deftest harness-instance-is-random-and-shaped ()
  "An instance has a random id and a 256-bit token, neither shared with another."
  (should (harness-instance-id-p harness-instance-id))
  (should (harness-instance-token-p harness-instance-token))
  (should-not (equal harness-instance-id (harness-instance--new-id)))
  (should-not (equal harness-instance-token (harness-instance--new-token)))
  (should (> (length harness-instance-token) 40))
  (should (string-match-p "\\`[A-Za-z0-9_-]\\{20,\\}" (harness-instance-random-string 16))))

(ert-deftest harness-instance-credentials-are-per-label-and-hide-the-token ()
  "A credential names one purpose, is stable for it, and is not the instance token."
  (let* ((one (harness-instance-credential "server:fs:s1"))
         (same (harness-instance-credential "server:fs:s1"))
         (other (harness-instance-credential "server:fs:s2")))
    (should (equal one same))
    (should-not (equal one other))
    (should (harness-instance-token-p one))
    (should-not (equal one harness-instance-token))
    (should-not (string-search harness-instance-token one))
    (should-not (harness-instance-equal-p one other))
    (should (harness-instance-equal-p one same))
    (should-not (harness-instance-equal-p one (substring one 0 (1- (length one)))))
    (should-not (harness-instance-equal-p "abc" "abcd"))))

(ert-deftest harness-instance-hmac-sha256-is-the-standard-one ()
  "The keyed hash is HMAC-SHA256, so a credential cannot be guessed or extended."
  ;; RFC 4231, test case 2.
  (should (equal "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
                 (harness-mcp-auth-test--hex
                  (harness-instance-hmac-sha256 "Jefe" "what do ya want for nothing?")))))

(ert-deftest harness-instance-the-status-view-never-shows-the-token ()
  (let ((state (harness-instance-id-state)))
    (should (equal harness-instance-id (plist-get state :id)))
    (should (eq t (plist-get state :token-set)))
    (should-not (string-search harness-instance-token (format "%S" state)))))

;;;; The dispatcher

(ert-deftest harness-mcp-auth-a-dispatcher-refuses-everything-until-initialized ()
  "A server with an expected credential runs no tool before `initialize' proves it."
  (let* ((auth (list :instance harness-instance-id
                     :token (harness-instance-credential "dispatcher-test")))
         (server (harness-mcp-auth-test--server auth))
         (wrong-instance (list :instance "hi1_anotherinstanceid000000" :token (plist-get auth :token)))
         (wrong-token (list :instance (plist-get auth :instance)
                            :token (harness-instance-credential "another")))
         (initialize (harness-mcp-auth-test--initialize))
         (call (list :name "echo" :arguments (list :text "hi"))))
    ;; Nothing is served before the credential.
    (should (= harness-mcp-error-unauthenticated
               (harness-mcp-auth-test--error-code
                (harness-mcp-auth-test--serve server "tools/list"))))
    (should (= harness-mcp-error-unauthenticated
               (harness-mcp-auth-test--error-code
                (harness-mcp-auth-test--serve server "tools/call" call))))
    ;; A plain initialize has no credential.
    (should (= harness-mcp-error-unauthenticated
               (harness-mcp-auth-test--error-code
                (harness-mcp-auth-test--serve server "initialize" initialize))))
    (should-not (harness-mcp-server-authenticated server))
    ;; Another instance's id or another credential is refused.
    (should (= harness-mcp-error-unauthenticated
               (harness-mcp-auth-test--error-code
                (harness-mcp-auth-test--serve
                 server "initialize" (harness-mcp-auth-test--initialize wrong-instance)))))
    (should (= harness-mcp-error-unauthenticated
               (harness-mcp-auth-test--error-code
                (harness-mcp-auth-test--serve
                 server "initialize" (harness-mcp-auth-test--initialize wrong-token)))))
    (should-not (harness-mcp-server-authenticated server))
    ;; This instance's credential is accepted, and then its tools work.
    (let ((ready (harness-mcp-auth-test--serve
                  server "initialize" (harness-mcp-auth-test--initialize auth))))
      (should-not (harness-mcp-auth-test--error-code ready))
      (should (harness-mcp-server-authenticated server))
      (should (equal (plist-get (plist-get ready :result) :protocolVersion)
                     harness-mcp-protocol-version)))
    (let ((tools (harness-mcp-auth-test--serve server "tools/list")))
      (should (equal '("echo") (mapcar (lambda (tool) (plist-get tool :name))
                                       (plist-get (plist-get tools :result) :tools)))))
    (let ((result (harness-mcp-auth-test--serve server "tools/call" call)))
      (should (equal "echo: hi"
                     (plist-get (car (plist-get (plist-get result :result) :content)) :text))))))

(ert-deftest harness-mcp-auth-a-server-with-no-credential-serves-as-before ()
  "A server made without `:auth' is not changed by the authentication code."
  (let ((server (harness-mcp-auth-test--server)))
    (should (plist-get (harness-mcp-auth-test--serve
                        server "initialize" (harness-mcp-auth-test--initialize))
                       :result))
    (let ((tools (harness-mcp-auth-test--serve server "tools/list")))
      (should (equal '("echo") (mapcar (lambda (tool) (plist-get tool :name))
                                       (plist-get (plist-get tools :result) :tools)))))))

;;;; A real worker

(defun harness-mcp-auth-test--worker (auth &optional directory)
  "Start the real file-tools worker in DIRECTORY with AUTH in its environment.
AUTH is a plist, or nil for no environment at all.  Return (PROCESS .
TEXT-CELL), where TEXT-CELL's car collects everything it writes."
  (let* ((dir (or directory (harness-test-temp-dir)))
         (text (list ""))
         (command (harness-tools-fs--worker-command nil))
         (process-environment
          (append (when auth
                    (list (concat harness-mcp-auth-instance-variable "="
                                  (plist-get auth :instance))
                          (concat harness-mcp-auth-token-variable "="
                                  (plist-get auth :token))))
                  process-environment))
         (proc (make-process
                :name "harness-mcp-auth-worker" :command command :connection-type 'pipe
                :coding 'utf-8-unix :noquery t
                :stderr (generate-new-buffer " *worker-stderr*")
                :filter (lambda (_proc chunk)
                          (setcar text (concat (car text) chunk))))))
    (process-put proc 'harness-mcp-auth-test-dir dir)
    (cons proc text)))

(defun harness-mcp-auth-test--messages (text-cell)
  "Return the complete messages in TEXT-CELL, oldest first."
  (let* ((text (car text-cell))
         (lines (split-string text "\n"))
         (complete (butlast lines)))
    (mapcar #'harness-mcp-decode-line complete)))

(defun harness-mcp-auth-test--wait-message (text-cell n)
  "Wait for the Nth (0-based) message in TEXT-CELL and return it."
  (harness-test-wait (lambda () (nth n (harness-mcp-auth-test--messages text-cell)))
                     10 "the worker's message")
  (nth n (harness-mcp-auth-test--messages text-cell)))

(defun harness-mcp-auth-test--send (proc message)
  "Send MESSAGE to PROC as one line."
  (process-send-string proc (harness-mcp-encode-line message)))

(ert-deftest harness-mcp-auth-a-real-worker-refuses-an-unauthenticated-client ()
  "The file tools' worker runs no tool for a client without its credential."
  (let* ((auth (list :instance harness-instance-id
                     :token (harness-instance-credential "worker-test")))
         (worker (harness-mcp-auth-test--worker auth))
         (proc (car worker))
         (text (cdr worker)))
    (unwind-protect
        (progn
          ;; No credential at all.
          (harness-mcp-auth-test--send
           proc (harness-mcp-request 1 "initialize" (harness-mcp-auth-test--initialize)))
          (should (= harness-mcp-error-unauthenticated
                     (harness-mcp-auth-test--error-code
                      (harness-mcp-auth-test--wait-message text 0))))
          ;; The right token under another instance's id.
          (harness-mcp-auth-test--send
           proc (harness-mcp-request
                 2 "initialize"
                 (harness-mcp-auth-test--initialize
                  (list :instance "hi1_anotherinstanceid000000"
                        :token (plist-get auth :token)))))
          (should (= harness-mcp-error-unauthenticated
                     (harness-mcp-auth-test--error-code
                      (harness-mcp-auth-test--wait-message text 1))))
          ;; A tool call before authentication is refused, not run.
          (harness-mcp-auth-test--send
           proc (harness-mcp-request 3 "tools/list"))
          (should (= harness-mcp-error-unauthenticated
                     (harness-mcp-auth-test--error-code
                      (harness-mcp-auth-test--wait-message text 2))))
          ;; The instance's own credential is accepted, then tools work.
          (harness-mcp-auth-test--send
           proc (harness-mcp-request 4 "initialize" (harness-mcp-auth-test--initialize auth)))
          (should (plist-get (harness-mcp-auth-test--wait-message text 3) :result))
          (harness-mcp-auth-test--send proc (harness-mcp-request 5 "tools/list"))
          (let ((tools (plist-get (harness-mcp-auth-test--wait-message text 4) :result)))
            (should (member "read_file" (mapcar (lambda (tool) (plist-get tool :name))
                                                (plist-get tools :tools)))))
          (harness-mcp-auth-test--send
           proc (harness-mcp-request
                 6 "tools/call"
                 (list :name "file_info"
                       :arguments (list :path (process-get proc 'harness-mcp-auth-test-dir))
                       :_meta (list harness-mcp-context-key
                                    (list :sessionId "auth-test"
                                          :cwd (process-get proc 'harness-mcp-auth-test-dir))))))
          (let* ((response (harness-mcp-auth-test--wait-message text 5))
                 (result (plist-get response :result)))
            (should-not (harness-mcp-result-error-p result))
            (should (string-search "type: directory" (harness-mcp-result-text result)))))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest harness-mcp-auth-a-worker-without-a-credential-does-not-serve ()
  "A worker started without the environment refuses to run, rather than serve anyone."
  (let* ((worker (harness-mcp-auth-test--worker nil))
         (proc (car worker)))
    (unwind-protect
        (progn
          (harness-test-wait (lambda () (not (process-live-p proc))) 10 "the worker to refuse")
          (should (= 1 (process-exit-status proc))))
      (when (process-live-p proc) (delete-process proc)))))

(provide 'harness-mcp-auth-test)
;;; harness-mcp-auth-test.el ends here
