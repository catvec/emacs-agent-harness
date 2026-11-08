;;; harness-chatgpt-plan-test.el --- Tests for Sign in with ChatGPT  -*- lexical-binding: t; -*-

;;; Commentary:

;; Nothing here talks to OpenAI.  The authorization server is a fake:
;; `harness-http-request-json' is replaced by a function that records the
;; request and answers canned JSON, and the browser is replaced by an
;; opener that drives the loopback callback itself (so the listener, the
;; callback parsing and the whole sign-in are exercised over a real
;; socket on 127.0.0.1).  The credentials go to a temporary state
;; directory.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)
(require 'harness-chatgpt-plan)

;;;; The fake authorization server

(defvar harness-chatgpt-plan-test--requests nil
  "Requests the fake answered, newest first: (:url :args).")

(defvar harness-chatgpt-plan-test--answers nil
  "Alist of (REGEXP . ANSWER) the fake consults.
ANSWER is (STATUS . JSON-PLIST) for a token or discovery response, or a
function of the request returning one; a status of 400 or more rejects
with that JSON as the body.  A function is how an answer that depends on
the attempt in progress is made, such as an id token carrying the
attempt's nonce.")

(defun harness-chatgpt-plan-test--answer (url args)
  "Return the canned answer for URL and ARGS, as (STATUS . JSON-PLIST).
A test may write the answer either as (STATUS . JSON-PLIST) or as
(STATUS JSON-PLIST) -- the latter is what a body-building function
returns -- and both mean the same here.  Only the two forms can be told
apart without ambiguity: in (STATUS BODY) the element after the status
is the body itself, a cons; in (STATUS . BODY) the rest of the list is
the body's own contents, so a keyword comes there, or nothing."
  (let* ((answer (cdr (cl-find-if (lambda (cell) (string-match-p (car cell) url))
                                  harness-chatgpt-plan-test--answers)))
         (answer (if (functionp answer) (funcall answer url args) answer))
         (rest (cdr answer)))
    (cond
     ((null answer) (cons 200 nil))
     ((and (consp rest) (null (cddr answer))
           (or (null (car rest)) (consp (car rest))))
      (cons (car answer) (car rest)))
     (t answer))))

(defun harness-chatgpt-plan-test--fake-json (url &rest args)
  "Record a request to URL with ARGS and answer it with canned JSON."
  (push (list :url url :args args) harness-chatgpt-plan-test--requests)
  (pcase-let ((`(,status . ,json) (harness-chatgpt-plan-test--answer url args)))
    (if (and (numberp status) (< status 300))
        (harness-resolved json)
      (harness-rejected (list 'http-error status (harness-json-encode json))))))

(defmacro harness-chatgpt-plan-test-with-server (answers &rest body)
  "Run BODY with the fake authorization server answering ANSWERS."
  (declare (indent 1))
  `(let ((harness-chatgpt-plan-test--requests nil)
         (harness-chatgpt-plan-test--answers ,answers))
     (cl-letf (((symbol-function 'harness-http-request-json)
                #'harness-chatgpt-plan-test--fake-json))
       ,@body)))

(defun harness-chatgpt-plan-test--request-body (regexp)
  "Return the body of the last request whose URL matches REGEXP."
  (let ((entry (cl-find-if (lambda (r) (string-match-p regexp (plist-get r :url)))
                           harness-chatgpt-plan-test--requests)))
    (plist-get (plist-get entry :args) :body)))

(defun harness-chatgpt-plan-test--fields (regexp)
  "Return the form fields of the request whose URL matches REGEXP, as an alist.
The names and values are URL-decoded, which is how the authorization
server reads them."
  (let ((body (harness-chatgpt-plan-test--request-body regexp)))
    (and body
         (mapcar (lambda (field)
                   (cons (url-unhex-string (car (split-string field "=")))
                         (url-unhex-string (or (cadr (split-string field "=")) ""))))
                 (split-string body "&")))))

(defun harness-chatgpt-plan-test--request-fields (args)
  "Return the form fields of the request ARGS as an alist.
ARGS are the keyword arguments `harness-http-request-json' was called
with; the body is form-encoded, as both the token endpoint and the
authorization endpoint take it."
  (let ((body (plist-get args :body)))
    (when (and (stringp body) (not (string-empty-p body)))
      (mapcar (lambda (field)
                (cons (url-unhex-string (car (split-string field "=")))
                      (url-unhex-string (or (cadr (split-string field "=")) ""))))
              (split-string body "&")))))

(defun harness-chatgpt-plan-test--token-answer (&rest overrides)
  "Return an answer function for the token endpoint, with OVERRIDES applied.
The id token it answers with is for the client id the request named,
which is what a real token endpoint does: a token answers the attempt
that asked for it, and the audience check of a sign-in is what this
makes pass."
  (lambda (_url args)
    (let ((fields (harness-chatgpt-plan-test--request-fields args)))
      (list 200 (apply #'harness-chatgpt-plan-test--token-response
                       :id_token (harness-chatgpt-plan-test--id-token
                                  :aud (or (cdr (assoc "client_id" fields))
                                           "oaiapp_test"))
                       overrides)))))

(defun harness-chatgpt-plan-test--jwt (claims)
  "Return a JWT with CLAIMS as its payload, signed with nothing.
The signature is not checked by the harness (it trusts the TLS connection
it arrived over), so none is needed here."
  (let ((part (base64url-encode-string (encode-coding-string (harness-json-encode claims) 'utf-8) t)))
    (concat (base64url-encode-string (encode-coding-string "{\"alg\":\"none\"}" 'utf-8) t)
            "." part ".signature")))

(defun harness-chatgpt-plan-test--id-token (&rest overrides)
  "Return an id token for a valid sign-in, with OVERRIDES applied.
The issuer, the audience, the expiry, the subject and the email are
those a real token endpoint answers with.  The audience is the client
id the attempt is for, and the nonce the attempt sent, so a token
answering the attempt in progress is a valid one."
  (let ((claims (list :iss harness-chatgpt-plan-auth-base
                      :aud (or (plist-get harness-chatgpt-plan--pending :client-id)
                               "oaiapp_test")
                      :exp (+ (float-time) 3600)
                      :sub "user-123"
                      :email "user@example.com"
                      :nonce (plist-get harness-chatgpt-plan--pending :nonce))))
    (cl-loop for (key value) on overrides by #'cddr
             do (setq claims (plist-put claims key value)))
    (harness-chatgpt-plan-test--jwt claims)))

(defun harness-chatgpt-plan-test--token-response (&rest overrides)
  "Return a token response plist, with OVERRIDES applied.
The scope is the complete set a first sign-in grants, and the id token
answers the attempt in progress."
  (let ((response (list :access_token "access-token-1"
                        :refresh_token "refresh-token-1"
                        :id_token (harness-chatgpt-plan-test--id-token)
                        :token_type "Bearer"
                        :expires_in 3600
                        :scope "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")))
    (cl-loop for (key value) on overrides by #'cddr
             do (setq response (plist-put response key value)))
    response))

(defmacro harness-chatgpt-plan-test-with-state (&rest body)
  "Run BODY in a fresh state directory, in the chatgpt-plan defaults.
The module's own caches -- the discovery document and the refreshes in
flight -- are cleared too: both outlive a state directory, and a test
that inherited one would be answered from a run that is over."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (let ((harness-chatgpt-plan-credentials-file nil)
           (harness-chatgpt-plan-host-id-file nil)
           (harness-chatgpt-plan-auth-base "https://auth.openai.com")
           (harness-chatgpt-plan-api-base "https://api.openai.com/v1")
           (harness-chatgpt-plan--pending nil)
           (harness-chatgpt-plan--discovery nil)
           (harness-chatgpt-plan--refreshes (make-hash-table :test 'equal))
           (auth-sources nil))
       (unwind-protect (progn ,@body)
         (harness-chatgpt-plan--close-pending)))))

(defun harness-chatgpt-plan-test--close-pending ()
  "Close whatever sign-in attempt is in progress, so no listener is left."
  (when harness-chatgpt-plan--pending
    (harness-chatgpt-plan--fail harness-chatgpt-plan--pending "the test ended")))

;;;; PKCE and random values

(ert-deftest harness-chatgpt-plan-pkce-is-s256 ()
  "The challenge is the base64url SHA-256 of the verifier, without padding."
  (let* ((pair (harness-chatgpt-plan--pkce))
         (verifier (car pair))
         (challenge (cdr pair)))
    (should (> (length verifier) 40))
    (should-not (string-match-p "[=+/]" verifier))
    (should (equal challenge
                   (base64url-encode-string (secure-hash 'sha256 verifier nil nil t) t)))
    (should-not (string-match-p "=" challenge))))

(ert-deftest harness-chatgpt-plan-random-values-differ ()
  "Every state and nonce is fresh, and long enough to be unpredictable."
  (let ((seen (make-hash-table :test 'equal)))
    (dotimes (_ 20)
      (let ((value (harness-chatgpt-plan--random-string 24)))
        (should (> (length value) 24))
        (should-not (gethash value seen))
        (puthash value t seen)))))

;;;; The host id

(ert-deftest harness-chatgpt-plan-host-id-is-stable-and-persisted ()
  "A host id is a `urn:uuid:' generated once and read from its file afterwards."
  (harness-chatgpt-plan-test-with-state
    (let ((id (harness-chatgpt-plan-host-id)))
      (should (string-prefix-p "urn:uuid:" id))
      (should (equal id (harness-chatgpt-plan-host-id)))
      (should (equal (concat id "\n")
                     (harness-read-file (harness-chatgpt-plan-host-id-file))))
      ;; A different file gives a different host its own id.
      (let ((harness-chatgpt-plan-host-id-file (expand-file-name "other-host" harness-state-directory)))
        (should-not (equal id (harness-chatgpt-plan-host-id)))))))

;;;; The authorization URL

(ert-deftest harness-chatgpt-plan-authorize-url-registers ()
  "A first sign-in asks for a dynamic registration, with the host id and the app name."
  (harness-chatgpt-plan-test-with-state
    (let* ((pending (list :state "STATE" :nonce "NONCE" :verifier "VERIFIER"
                          :redirect-uri "http://127.0.0.1:12345/auth/callback"
                          :registration t))
           (url (harness-chatgpt-plan-authorize-url pending))
           (fields (harness-chatgpt-plan-test--fields-of url)))
      (should (string-prefix-p "https://auth.openai.com/api/accounts/authorize?" url))
      (should (equal "dynamic_agent_client" (cdr (assoc "client_id" fields))))
      (should (equal harness-chatgpt-plan-agent-name (cdr (assoc "agent_name_hint" fields))))
      (should (equal (harness-chatgpt-plan-host-id) (cdr (assoc "ext_agent_host_id" fields))))
      (should (equal "code" (cdr (assoc "response_type" fields))))
      (should (equal "http://127.0.0.1:12345/auth/callback" (cdr (assoc "redirect_uri" fields))))
      (should (equal "https://api.openai.com/v1" (cdr (assoc "resource" fields))))
      (should (equal "STATE" (cdr (assoc "state" fields))))
      (should (equal "NONCE" (cdr (assoc "nonce" fields))))
      (should (equal "S256" (cdr (assoc "code_challenge_method" fields))))
      (should (equal (base64url-encode-string (secure-hash 'sha256 "VERIFIER" nil nil t) t)
                     (cdr (assoc "code_challenge" fields))))
      (should (equal "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
                     (cdr (assoc "scope" fields))))
      ;; Nothing about a saved account is sent when registering one.
      (should-not (assoc "id_token_hint" fields))
      (should-not (assoc "login_hint" fields)))))

(ert-deftest harness-chatgpt-plan-authorize-url-reauthorizes ()
  "A later sign-in reuses the issued client id and sends the retained hints."
  (harness-chatgpt-plan-test-with-state
    (let* ((account (list :id "acct-1" :email "user@example.com" :client-id "oaiapp_saved"
                          :id-token "the-retained-id-token"))
           (pending (list :state "S" :nonce "N" :verifier "V"
                          :redirect-uri "http://127.0.0.1:1/auth/callback"
                          :registration nil :client-id "oaiapp_saved"))
           (fields (harness-chatgpt-plan-test--fields-of
                    (harness-chatgpt-plan-authorize-url pending account))))
      (should (equal "oaiapp_saved" (cdr (assoc "client_id" fields))))
      (should (equal "the-retained-id-token" (cdr (assoc "id_token_hint" fields))))
      (should (equal "user@example.com" (cdr (assoc "login_hint" fields))))
      (should (equal (harness-chatgpt-plan-host-id) (cdr (assoc "ext_agent_host_id" fields))))
      ;; The app name is display metadata for the registration only.
      (should-not (assoc "agent_name_hint" fields)))))

(defun harness-chatgpt-plan-test--fields-of (url)
  "Return URL's query parameters as an alist.
The query is put back into a request target, which is what
`harness-chatgpt-plan--query' reads."
  (harness-chatgpt-plan--query
   (concat "/authorize" (substring url (string-match "\\?" url)))))

;;;; Signing in

(ert-deftest harness-chatgpt-plan-sign-in-registers-and-stores ()
  "A registration saves the issued client id, the tokens and the scopes.
The whole flow runs over the real loopback listener, with the browser
and the authorization server faked."
  (harness-chatgpt-plan-test-with-state
    (harness-chatgpt-plan-test-with-server
        (list (cons "oauth/token" (harness-chatgpt-plan-test--token-answer)))
      (let ((opened nil))
        (let ((harness-chatgpt-plan--opener
               (lambda (url)
                 (setq opened url)
                 (should (string-match-p "client_id=dynamic_agent_client" url))
                 (should (string-match-p "agent_name_hint=" url))
                 (harness-chatgpt-plan-test--drive-callback
                  "code=THE-CODE&client_id=oaiapp_issued"))))
          (let ((status (harness-test-await (harness-chatgpt-plan-sign-in))))
            (should opened)
            (should (plist-get status :plan-usage))
            (let ((account (harness-chatgpt-plan-account (plist-get status :active))))
              (should (equal "oaiapp_issued" (plist-get account :client-id)))
              (should (equal "access-token-1" (plist-get account :access-token)))
              (should (equal "refresh-token-1" (plist-get account :refresh-token)))
              (should (equal "user@example.com" (plist-get account :email)))
              (should (member "chatgpt.tokens.use.direct" (plist-get account :scopes)))
              (should (numberp (plist-get account :expires-at))))))))))

(ert-deftest harness-chatgpt-plan-exchange-sends-the-issued-client-id ()
  "The code exchange is a form-encoded authorization_code grant, with no secret."
  (harness-chatgpt-plan-test-with-state
    (harness-chatgpt-plan-test-with-server
        (list (cons "oauth/token"
                    (lambda (&rest _)
                      (list 200 (harness-chatgpt-plan-test--token-response)))))
      (let* ((pending (list :state "S" :nonce "N" :verifier "THE-VERIFIER"
                            :redirect-uri "http://127.0.0.1:9/auth/callback"
                            :registration t :promise (harness-make-promise)
                            :client-id "oaiapp_issued"))
             (harness-chatgpt-plan--pending pending))
        (harness-test-await
         (harness-chatgpt-plan--finish-callback pending "THE-CODE" "oaiapp_issued"))
        (let ((fields (harness-chatgpt-plan-test--fields "oauth/token")))
          (should (equal "authorization_code" (cdr (assoc "grant_type" fields))))
          (should (equal "oaiapp_issued" (cdr (assoc "client_id" fields))))
          (should (equal "THE-CODE" (cdr (assoc "code" fields))))
          (should (equal "THE-VERIFIER" (cdr (assoc "code_verifier" fields))))
          (should (equal "http://127.0.0.1:9/auth/callback" (cdr (assoc "redirect_uri" fields))))
          (should (equal "https://api.openai.com/v1" (cdr (assoc "resource" fields))))
          (should-not (assoc "client_secret" fields))
          (should-not (assoc "ext_agent_host_id" fields)))))))

(ert-deftest harness-chatgpt-plan-registration-without-issued-id-fails ()
  "A registration callback that names no issued id means the registration is incomplete."
  (harness-chatgpt-plan-test-with-state
    (let* ((pending (list :state "S" :nonce "N" :verifier "V"
                          :redirect-uri "http://127.0.0.1:9/auth/callback"
                          :registration t :promise (harness-make-promise)))
           (harness-chatgpt-plan--pending pending))
      (harness-chatgpt-plan--finish-callback pending "CODE" nil)
      (should (harness-promise-settled-p (plist-get pending :promise)))
      (should (eq (harness-promise-state (plist-get pending :promise)) 'rejected))
      ;; `dynamic_agent_client' is the entrypoint, never a saved id.
      (let* ((pending2 (list :state "S" :nonce "N" :verifier "V"
                             :redirect-uri "http://127.0.0.1:9/auth/callback"
                             :registration t :promise (harness-make-promise)))
             (harness-chatgpt-plan--pending pending2))
        (harness-chatgpt-plan--finish-callback pending2 "CODE" "dynamic_agent_client")
        (should (eq (harness-promise-state (plist-get pending2 :promise)) 'rejected))))))

(ert-deftest harness-chatgpt-plan-reauthorization-refuses-another-client-id ()
  "A callback naming a different client id is refused, not stored."
  (harness-chatgpt-plan-test-with-state
    (let* ((pending (list :state "S" :nonce "N" :verifier "V"
                          :redirect-uri "http://127.0.0.1:9/auth/callback"
                          :registration nil :client-id "oaiapp_mine"
                          :promise (harness-make-promise)))
           (harness-chatgpt-plan--pending pending))
      (harness-chatgpt-plan--finish-callback pending "CODE" "oaiapp_somebody_else")
      (should (eq (harness-promise-state (plist-get pending :promise)) 'rejected)))))

(ert-deftest harness-chatgpt-plan-callback-checks-state ()
  "A callback with the wrong state is refused and the attempt goes on."
  (harness-chatgpt-plan-test-with-state
    (let* ((pending (list :state "RIGHT" :nonce "N" :verifier "V"
                          :redirect-uri "http://127.0.0.1:9/auth/callback"
                          :registration t :promise (harness-make-promise)
                          :listener nil))
           (harness-chatgpt-plan--pending pending)
           (answered nil))
      (cl-letf (((symbol-function 'harness-chatgpt-plan--respond)
                 (lambda (_process status _title _body) (setq answered status))))
        (harness-chatgpt-plan--callback nil '(("state" . "WRONG") ("code" . "C"))))
      (should (equal 400 answered))
      (should (eq harness-chatgpt-plan--pending pending))
      (should-not (harness-promise-settled-p (plist-get pending :promise))))))

(ert-deftest harness-chatgpt-plan-callback-reports-a-refusal ()
  "`error=access_denied' fails the attempt without exchanging anything."
  (harness-chatgpt-plan-test-with-state
    (let* ((pending (list :state "S" :nonce "N" :verifier "V"
                          :redirect-uri "http://127.0.0.1:9/auth/callback"
                          :registration nil :client-id "oaiapp_x"
                          :promise (harness-make-promise)))
           (harness-chatgpt-plan--pending pending))
      (cl-letf (((symbol-function 'harness-chatgpt-plan--respond) #'ignore))
        (harness-chatgpt-plan--callback nil '(("state" . "S") ("error" . "access_denied"))))
      (should (eq (harness-promise-state (plist-get pending :promise)) 'rejected))
      (should (string-match-p "access_denied"
                              (format "%s" (harness-promise-value (plist-get pending :promise))))))))

(ert-deftest harness-chatgpt-plan-full-loopback-sign-in ()
  "The whole flow over the real loopback listener on 127.0.0.1."
  (harness-chatgpt-plan-test-with-state
    (setq harness-chatgpt-plan-test--answers
          (list (cons "oauth/token"
                      (list 200 (harness-chatgpt-plan-test--token-response)))))
    (harness-chatgpt-plan-test-with-server harness-chatgpt-plan-test--answers
      (let ((opened nil) (redirect nil))
        (let ((harness-chatgpt-plan--opener
               (lambda (url)
                 (setq opened url
                       redirect (cdr (assoc "redirect_uri"
                                            (harness-chatgpt-plan-test--fields-of url))))
                 (should (string-prefix-p "http://127.0.0.1:" redirect))
                 (should (string-suffix-p "/auth/callback" redirect))
                 ;; The listener is up before the browser is opened, which
                 ;; is what makes this connect at all.
                 (harness-chatgpt-plan-test--visit
                  redirect
                  (format "code=THE-CODE&client_id=oaiapp_loopback&state=%s"
                          (plist-get harness-chatgpt-plan--pending :state))))))
          (let ((status (harness-test-await (harness-chatgpt-plan-sign-in))))
            (should opened)
            (should (plist-get status :plan-usage))
            (should (equal "oaiapp_loopback"
                           (plist-get (harness-chatgpt-plan-account (plist-get status :active))
                                      :client-id)))))))))

(defun harness-chatgpt-plan-test--visit (redirect-uri query)
  "Ask REDIRECT-URI, a loopback URL, with QUERY, as a browser would.
This does what the browser does after the user approves: a plain HTTP
request to the callback, whose answer is read and thrown away."
  (let* ((url (url-generic-parse-url (concat redirect-uri "?" query)))
         (client (open-network-stream "chatgpt-plan-test-browser" nil
                                      (url-host url) (url-port url))))
    (unwind-protect
        (progn
          (process-send-string
           client (format "GET %s?%s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"
                          (url-filename url) query (url-host url)))
          ;; Read the answer so the request is complete before the socket
          ;; closes under the listener.
          (let ((deadline (+ (float-time) 5)))
            (while (and (process-live-p client) (< (float-time) deadline))
              (accept-process-output client 0.02))
            (accept-process-output nil 0.1)))
      (when (process-live-p client) (delete-process client)))))

(defun harness-chatgpt-plan-test--drive-callback (query)
  "Send QUERY to the callback listener of the attempt in progress.
The port is the listener's, as `visit' finds it."
  (let* ((pending harness-chatgpt-plan--pending)
         (listener (plist-get pending :listener)))
    (harness-chatgpt-plan-test--visit
     (format "http://127.0.0.1:%d/auth/callback" (process-contact listener :service))
     (if (string-match-p "state=" query)
         query
       (concat query "&state=" (plist-get pending :state))))))

;;;; The ID token

(ert-deftest harness-chatgpt-plan-id-token-is-checked ()
  "Issuer, audience, expiry, nonce and subject are all checked."
  (harness-chatgpt-plan-test-with-state
    (let* ((pending (list :client-id "oaiapp_test" :nonce "the-nonce"))
           ;; The id token the helper makes is for the attempt in
           ;; progress: its audience and its nonce come from here.
           (harness-chatgpt-plan--pending pending))
      (cl-flet ((valid (token)
                  (harness-chatgpt-plan--validate-id-token
                   pending (list :id_token token))))
        (should (valid (harness-chatgpt-plan-test--id-token :nonce "the-nonce")))
        (should-not (valid (harness-chatgpt-plan-test--id-token :nonce "the-nonce"
                                                                :iss "https://auth.example.com")))
        (should-not (valid (harness-chatgpt-plan-test--id-token :nonce "the-nonce"
                                                                :aud "oaiapp_other")))
        (should-not (valid (harness-chatgpt-plan-test--id-token :nonce "the-nonce"
                                                                :exp (- (float-time) 10))))
        (should-not (valid (harness-chatgpt-plan-test--id-token :nonce "another-nonce")))
        (should-not (valid (harness-chatgpt-plan-test--id-token :nonce "the-nonce" :sub nil)))
        (should-not (valid "not-a-jwt"))
        (should-not (valid nil))))))

(ert-deftest harness-chatgpt-plan-scope-decides-plan-usage ()
  "A sign-in without `chatgpt.tokens.use.direct' is kept but cannot pay.
The granted scopes are what decides, not the ones that were asked for:
the account is signed in and its tokens are kept, and only the plan
being able to pay is withheld."
  (harness-chatgpt-plan-test-with-state
    (harness-chatgpt-plan-test-with-server
        (list (cons "oauth/token"
                    (lambda (&rest _)
                      (list 200 (harness-chatgpt-plan-test--token-response
                                 :scope "openid profile email")))))
      (let* ((pending (list :state "S" :nonce "N" :verifier "V"
                            :redirect-uri "http://127.0.0.1:9/auth/callback"
                            :registration t :promise (harness-make-promise)
                            :client-id "oaiapp_test"))
             (harness-chatgpt-plan--pending pending))
        (harness-test-await (harness-chatgpt-plan--finish-callback pending "CODE" "oaiapp_test"))
        (let* ((status (harness-chatgpt-plan-status))
               (account (harness-chatgpt-plan-account (plist-get status :active))))
          ;; The account exists, its tokens are stored, and it is signed in.
          (should account)
          (should (equal "access-token-1" (plist-get account :access-token)))
          (should (plist-get status :signed-in))
          ;; What it may not do is pay with the plan.
          (should-not (plist-get status :plan-usage))
          (should-not (plist-get (car (plist-get status :accounts)) :plan-usage)))))))

;;;; The credential file

(ert-deftest harness-chatgpt-plan-credentials-are-private ()
  "The file is written whole, atomically, readable only by its owner."
  (harness-chatgpt-plan-test-with-state
    (harness-chatgpt-plan--save
     (list :host-id "urn:uuid:x" :active "acct-1"
           :accounts (list (list :id "acct-1" :email "a@example.com"
                                 :access-token "at" :refresh-token "rt"
                                 :id-token "it" :client-id "oaiapp_x"
                                 :scopes '("openid" "chatgpt.tokens.use.direct")
                                 :expires-at 123.0))))
    (let ((file (harness-chatgpt-plan-credentials-file)))
      (should (file-exists-p file))
      (should (equal #o600 (file-modes file)))
      (let ((json (harness-json-parse (harness-read-file file))))
        ;; The host id written is this host's, whatever a caller passed:
        ;; it names the host, not the document.
        (should (equal (harness-chatgpt-plan-host-id) (plist-get json :host_id)))
        (should (string-prefix-p "urn:uuid:" (plist-get json :host_id)))
        (should (equal "acct-1" (plist-get json :active)))
        ;; The accounts are a JSON array of objects, each with the keys
        ;; the documentation spells (`access_token'), not the ones the
        ;; code uses internally.
        (should (equal "at" (plist-get (car (plist-get json :accounts)) :access_token)))
        (should (equal "rt" (plist-get (car (plist-get json :accounts)) :refresh_token)))
        (should (equal '("openid" "chatgpt.tokens.use.direct")
                       (append (plist-get (car (plist-get json :accounts)) :scopes) nil))))
      ;; No temporary file is left behind.
      (should-not (directory-files (file-name-directory file) nil "chatgpt-plan\\.json\\.tmp")))))

(ert-deftest harness-chatgpt-plan-accounts-are-separate ()
  "Two sign-ins are two account records, and a second one of one account replaces it."
  (harness-chatgpt-plan-test-with-state
    (harness-chatgpt-plan--put-account (list :id "acct-1" :email "a@example.com"
                                             :access-token "at1" :refresh-token "rt1"
                                             :client-id "oaiapp_1") t)
    (harness-chatgpt-plan--put-account (list :id "acct-2" :email "b@example.com"
                                             :access-token "at2" :refresh-token "rt2"
                                             :client-id "oaiapp_2") t)
    (should (equal '("acct-1" "acct-2")
                   (mapcar (lambda (a) (plist-get a :id)) (harness-chatgpt-plan-accounts))))
    (should (equal "acct-2" (plist-get (harness-chatgpt-plan-credentials) :active)))
    (harness-chatgpt-plan--put-account (list :id "acct-1" :email "a@example.com"
                                             :access-token "at1-new" :refresh-token "rt1-new"
                                             :client-id "oaiapp_1") nil)
    (should (equal '("acct-1" "acct-2")
                   (mapcar (lambda (a) (plist-get a :id)) (harness-chatgpt-plan-accounts))))
    (should (equal "at1-new" (plist-get (harness-chatgpt-plan-account "acct-1") :access-token)))
    ;; The status never carries a token.
    (let ((status (harness-chatgpt-plan-status)))
      (dolist (account (plist-get status :accounts))
        (should-not (plist-get account :access-token))
        (should-not (plist-get account :refresh-token))
        (should-not (plist-get account :id-token))))))

(ert-deftest harness-chatgpt-plan-unreadable-file-is-empty ()
  "A credential file that cannot be parsed reads as no accounts, not as an error."
  (harness-chatgpt-plan-test-with-state
    (write-region "this is not JSON\n" nil (harness-chatgpt-plan-credentials-file) nil 'silent)
    (should-not (harness-chatgpt-plan-credentials))
    (should-not (harness-chatgpt-plan-accounts))
    (should-not (harness-chatgpt-plan-account "acct-1"))))

;;;; Refreshing

(ert-deftest harness-chatgpt-plan-refreshes-near-expiry ()
  "A token close to expiring is refreshed before it is handed out."
  (harness-chatgpt-plan-test-with-state
    (setq harness-chatgpt-plan-test--answers
          (list (cons "oauth/token"
                      (list 200 (harness-chatgpt-plan-test--token-response
                                 :access_token "at-new" :refresh_token "rt-new")))))
    (harness-chatgpt-plan-test-with-server harness-chatgpt-plan-test--answers
      (harness-chatgpt-plan--save
       (list :host-id "urn:uuid:x" :active "acct-1"
             :accounts (list (list :id "acct-1" :email "a@example.com"
                                   :access-token "at-old" :refresh-token "rt-old"
                                   :client-id "oaiapp_x"
                                   :scopes '("openid" "chatgpt.tokens.use.direct")
                                   :expires-at (+ (float-time) 5)))))
      (let ((token (harness-test-await (harness-chatgpt-plan-access-token))))
        (should (equal "at-new" (plist-get token :token)))
        (should (plist-get token :plan-usage))
        (let ((account (harness-chatgpt-plan-account "acct-1")))
          (should (equal "at-new" (plist-get account :access-token)))
          ;; The replacement refresh token is stored with it.
          (should (equal "rt-new" (plist-get account :refresh-token)))
          (should (> (plist-get account :expires-at) (+ (float-time) 3000)))))
      ;; The refresh is the issued client id, never the entrypoint, with
      ;; no scope (the granted ones stay) and the same resource.
      (let ((fields (harness-chatgpt-plan-test--fields "oauth/token")))
        (should (equal "refresh_token" (cdr (assoc "grant_type" fields))))
        (should (equal "oaiapp_x" (cdr (assoc "client_id" fields))))
        (should (equal "rt-old" (cdr (assoc "refresh_token" fields))))
        (should (equal "https://api.openai.com/v1" (cdr (assoc "resource" fields))))
        (should-not (assoc "scope" fields))))))

(ert-deftest harness-chatgpt-plan-refreshes-once-per-account ()
  "Two callers asking at once share one refresh, so the rotating token is not raced."
  (harness-chatgpt-plan-test-with-state
    (setq harness-chatgpt-plan-test--answers
          (list (cons "oauth/token"
                      (list 200 (harness-chatgpt-plan-test--token-response
                                 :access_token "at-new" :refresh_token "rt-new")))))
    (harness-chatgpt-plan-test-with-server harness-chatgpt-plan-test--answers
      (harness-chatgpt-plan--save
       (list :host-id "urn:uuid:x" :active "acct-1"
             :accounts (list (list :id "acct-1" :email "a@example.com"
                                   :access-token "at-old" :refresh-token "rt-old"
                                   :client-id "oaiapp_x"
                                   :expires-at (+ (float-time) 5)))))
      (let ((first (harness-chatgpt-plan-access-token))
            (second (harness-chatgpt-plan-access-token)))
        (should (equal "at-new" (plist-get (harness-test-await first) :token)))
        (should (equal "at-new" (plist-get (harness-test-await second) :token)))
        (should (= 1 (length (cl-remove-if-not
                              (lambda (r) (string-match-p "oauth/token" (plist-get r :url)))
                              harness-chatgpt-plan-test--requests))))))))

(ert-deftest harness-chatgpt-plan-refresh-failure-clears-unusable-tokens ()
  "A refused refresh token clears the tokens but keeps the identity and client id."
  (harness-chatgpt-plan-test-with-state
    (setq harness-chatgpt-plan-test--answers
          (list (cons "oauth/token"
                      (list 400 (list :error "invalid_grant"
                                      :error_description "refresh token expired")))))
    (harness-chatgpt-plan-test-with-server harness-chatgpt-plan-test--answers
      (harness-chatgpt-plan--save
       (list :host-id "urn:uuid:x" :active "acct-1"
             :accounts (list (list :id "acct-1" :email "a@example.com" :subject "s"
                                   :access-token "at" :refresh-token "rt"
                                   :id-token "it" :client-id "oaiapp_x"
                                   :scopes '("openid" "chatgpt.tokens.use.direct")
                                   :expires-at (+ (float-time) 5)))))
      (should-error (harness-test-await (harness-chatgpt-plan-access-token)))
      (let ((account (harness-chatgpt-plan-account "acct-1")))
        (should-not (plist-get account :access-token))
        (should-not (plist-get account :refresh-token))
        (should-not (plist-get account :id-token))
        (should (plist-get account :needs-sign-in))
        ;; What a later sign-in reuses survives.
        (should (equal "oaiapp_x" (plist-get account :client-id)))
        (should (equal "a@example.com" (plist-get account :email))))
      (should (string-match-p "sign-in" (cadr (should-error
                                               (harness-test-await
                                                (harness-chatgpt-plan-access-token)))))))))

(ert-deftest harness-chatgpt-plan-invalid-client-forgets-the-registration ()
  "`invalid_client' clears the issued client id too, so the next sign-in registers."
  (harness-chatgpt-plan-test-with-state
    (setq harness-chatgpt-plan-test--answers
          (list (cons "oauth/token" (list 401 (list :error "invalid_client")))))
    (harness-chatgpt-plan-test-with-server harness-chatgpt-plan-test--answers
      (harness-chatgpt-plan--save
       (list :host-id "urn:uuid:x" :active "acct-1"
             :accounts (list (list :id "acct-1" :email "a@example.com"
                                   :access-token "at" :refresh-token "rt"
                                   :client-id "oaiapp_x"
                                   :expires-at (+ (float-time) 5)))))
      (should-error (harness-test-await (harness-chatgpt-plan-access-token)))
      (should-not (plist-get (harness-chatgpt-plan-account "acct-1") :client-id)))))

(ert-deftest harness-chatgpt-plan-transient-refresh-failure-keeps-the-tokens ()
  "A refresh that fails for another reason does not throw the credentials away."
  (harness-chatgpt-plan-test-with-state
    (setq harness-chatgpt-plan-test--answers
          (list (cons "oauth/token" (list 503 (list :error "server_error")))))
    (harness-chatgpt-plan-test-with-server harness-chatgpt-plan-test--answers
      (harness-chatgpt-plan--save
       (list :host-id "urn:uuid:x" :active "acct-1"
             :accounts (list (list :id "acct-1" :email "a@example.com"
                                   :access-token "at" :refresh-token "rt"
                                   :client-id "oaiapp_x"
                                   :expires-at (+ (float-time) 5)))))
      (should-error (harness-test-await (harness-chatgpt-plan-access-token)))
      (let ((account (harness-chatgpt-plan-account "acct-1")))
        (should (equal "rt" (plist-get account :refresh-token)))
        (should-not (plist-get account :needs-sign-in))))))

(ert-deftest harness-chatgpt-plan-token-not-needed-is-not-refreshed ()
  "A token that is valid now is handed out without a request."
  (harness-chatgpt-plan-test-with-state
    (harness-chatgpt-plan-test-with-server
        '(("oauth/token" . (500 . (:error "server_error"))))
      (harness-chatgpt-plan--save
       (list :host-id "urn:uuid:x" :active "acct-1"
             :accounts (list (list :id "acct-1" :email "a@example.com"
                                   :access-token "at" :refresh-token "rt"
                                   :client-id "oaiapp_x"
                                   :scopes '("openid" "chatgpt.tokens.use.direct")
                                   :expires-at (+ (float-time) 3600)))))
      (should (equal "at" (plist-get (harness-test-await (harness-chatgpt-plan-access-token)) :token)))
      (should-not harness-chatgpt-plan-test--requests))))

(ert-deftest harness-chatgpt-plan-no-account-is-refused ()
  "Asking for a token with nobody signed in says what to run."
  (harness-chatgpt-plan-test-with-state
    (let ((err (should-error (harness-test-await (harness-chatgpt-plan-access-token)))))
      (should (string-match-p "harness-chatgpt-plan-sign-in" (format "%s" err))))))

(ert-deftest harness-chatgpt-plan-refresh-lock-is-exclusive ()
  "The lock file keeps two refreshes apart, and is released afterwards."
  (harness-chatgpt-plan-test-with-state
    (let* ((file (harness-chatgpt-plan--refresh-lock-file))
           (held (harness-test-await (harness-chatgpt-plan--acquire-lock))))
      (should (equal file held))
      (should (file-exists-p file))
      (let ((harness-chatgpt-plan-lock-stale 1000))
        ;; A second attempt does not take it while it is held.
        (let ((second (harness-chatgpt-plan--acquire-lock)))
          (should-not (harness-promise-settled-p second))
          (harness-chatgpt-plan--release-lock held)
          (should (equal file (harness-test-await second)))
          (harness-chatgpt-plan--release-lock file))))))

(ert-deftest harness-chatgpt-plan-stale-lock-is-broken ()
  "A lock left behind by a process that died does not stop a refresh for good."
  (harness-chatgpt-plan-test-with-state
    (let* ((file (harness-chatgpt-plan--refresh-lock-file))
           (harness-chatgpt-plan-lock-stale 0))
      (harness-ensure-directory (file-name-directory file))
      (write-region "" nil file nil 'silent)
      ;; With the stale age at zero the lock is already old enough.
      (should (harness-chatgpt-plan--lock-free-p file))
      (should-not (file-exists-p file)))))

;;;; Signing out

(ert-deftest harness-chatgpt-plan-sign-out-revokes-then-clears ()
  "Signing out revokes at the discovery document's endpoint, then clears tokens."
  (harness-chatgpt-plan-test-with-state
    (setq harness-chatgpt-plan-test--answers
          (list (cons "openid-configuration"
                      (list 200 (list :revocation_endpoint
                                      "https://auth.openai.com/api/accounts/oauth/revoke")))
                (cons "revoke" (list 200 nil))))
    (harness-chatgpt-plan-test-with-server harness-chatgpt-plan-test--answers
      (harness-chatgpt-plan--save
       (list :host-id "urn:uuid:x" :active "acct-1"
             :accounts (list (list :id "acct-1" :email "a@example.com" :client-id "oaiapp_x"
                                   :access-token "at" :refresh-token "rt" :id-token "it"
                                   :scopes '("openid" "chatgpt.tokens.use.direct")
                                   :expires-at (+ (float-time) 3600)))))
      (let ((result (harness-test-await (harness-chatgpt-plan-sign-out))))
        (should-not (plist-get result :revocation)))
      (let ((fields (harness-chatgpt-plan-test--fields "revoke")))
        (should (equal "rt" (cdr (assoc "token" fields))))
        (should (equal "refresh_token" (cdr (assoc "token_type_hint" fields))))
        (should (equal "oaiapp_x" (cdr (assoc "client_id" fields)))))
      (let ((account (harness-chatgpt-plan-account "acct-1")))
        (should-not (plist-get account :refresh-token))
        (should-not (plist-get account :access-token))
        ;; The account mapping, the client id and the host id stay.
        (should (equal "oaiapp_x" (plist-get account :client-id)))
        (should (equal "a@example.com" (plist-get account :email))))
      ;; The token is nowhere in what the file holds.
      (should-not (string-match-p "rt" (harness-read-file (harness-chatgpt-plan-credentials-file)))))))

(ert-deftest harness-chatgpt-plan-sign-out-reports-unconfirmed-revocation ()
  "A revocation that cannot be confirmed is reported, and the tokens go anyway."
  (harness-chatgpt-plan-test-with-state
    (setq harness-chatgpt-plan-test--answers
          (list (cons "openid-configuration" (list 500 (list :error "server_error")))))
    (harness-chatgpt-plan-test-with-server harness-chatgpt-plan-test--answers
      (harness-chatgpt-plan--save
       (list :host-id "urn:uuid:x" :active "acct-1"
             :accounts (list (list :id "acct-1" :email "a@example.com"
                                   :access-token "at" :refresh-token "rt"
                                   :client-id "oaiapp_x"
                                   :expires-at (+ (float-time) 3600)))))
      (let ((result (harness-test-await (harness-chatgpt-plan-sign-out))))
        (should (stringp (plist-get result :revocation)))
        (should (string-match-p "not confirmed" (plist-get result :revocation))))
      (should-not (plist-get (harness-chatgpt-plan-account "acct-1") :refresh-token)))))

(ert-deftest harness-chatgpt-plan-sign-out-without-an-account-is-refused ()
  (harness-chatgpt-plan-test-with-state
    (should-error (harness-test-await (harness-chatgpt-plan-sign-out)))))

;;;; Secrets

(ert-deftest harness-chatgpt-plan-tokens-are-registered-as-secrets ()
  "The credential file is registered with the secrets module, by path and key."
  (harness-chatgpt-plan-test-with-state
    (harness-chatgpt-plan--save
     (list :host-id "urn:uuid:x" :active "acct-1"
           :accounts (list (list :id "acct-1" :access-token "access-token-value"
                                 :refresh-token "refresh-token-value"
                                 :id-token "id-token-value"))))
    (let ((added nil))
      (cl-letf (((symbol-function 'harness-method-exists-p)
                 (lambda (name) (memq name '(secrets/add-source))))
                ((symbol-function 'harness-call)
                 (lambda (name &rest args)
                   (when (eq name 'secrets/add-source)
                     (push (car args) added))
                   t)))
        (harness-chatgpt-plan--register-secrets))
      (should (= 3 (length added)))
      (dolist (ref added)
        (should (equal (harness-chatgpt-plan-credentials-file) (plist-get ref :file)))
        (should (string-match-p "accounts\\.\\*\\." (plist-get ref :json-path)))
        ;; A reference names where a token can be read, never its value.
        (should-not (string-match-p "access-token-value\\|refresh-token-value\\|id-token-value"
                                    (format "%S" ref)))))))

;;;; Commands and the bus

(ert-deftest harness-chatgpt-plan-status-command-says-what-is-signed-in ()
  "The commands report the state without ever naming a token."
  (harness-chatgpt-plan-test-with-state
    (let ((messages nil))
      (cl-letf (((symbol-function 'harness-chatgpt-plan--message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (harness-chatgpt-plan-status-interactive)
        (should (string-match-p "No ChatGPT account" (car messages)))
        (harness-chatgpt-plan--save
         (list :host-id "urn:uuid:x" :active "acct-1"
               :accounts (list (list :id "acct-1" :email "a@example.com"
                                     :access-token "at" :refresh-token "rt"
                                     :scopes '("openid" "chatgpt.tokens.use.direct")
                                     :expires-at (+ (float-time) 3600)))))
        (setq messages nil)
        (harness-chatgpt-plan-status-interactive)
        (should (string-match-p "a@example.com" (car messages)))
        (should (string-match-p "plan available" (car messages)))
        (should-not (string-match-p "\\bat\\b" (car messages)))))))

(ert-deftest harness-chatgpt-plan-methods-are-registered ()
  "The module provides the methods a UI or provider uses."
  (should (harness-method-exists-p 'chatgpt-plan/status))
  (should (harness-method-exists-p 'chatgpt-plan/sign-in))
  (should (harness-method-exists-p 'chatgpt-plan/sign-out))
  (should (harness-method-exists-p 'chatgpt-plan/access-token)))

(provide 'harness-chatgpt-plan-test)
;;; harness-chatgpt-plan-test.el ends here
