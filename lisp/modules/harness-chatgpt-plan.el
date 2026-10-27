;;; harness-chatgpt-plan.el --- Sign in with ChatGPT for plan-covered inference  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sign in with ChatGPT (SIWC) for open-source and locally run clients,
;; which lets an eligible ChatGPT Plus or Pro plan pay for inference
;; through the public Responses API -- no API key, no partner approval,
;; and no `codex' binary.  This module does the signing in and keeps the
;; credentials; the provider that speaks the Responses API to
;; api.openai.com is harness-provider-responses.el.
;;
;; The flow is the one OpenAI documents for open-source clients
;; (developers.openai.com/siwc/token-sharing-open-source).  It is
;; Authorization Code with PKCE, S256, with a loopback callback on
;; 127.0.0.1: the listener is started before the browser is opened, only
;; its port varies from one attempt to the next, and the same exact
;; redirect URI is sent to the authorization endpoint and to the token
;; endpoint.  There is no client secret and no API key anywhere.
;;
;; A client, an agent host.  Two identifiers matter, and neither is an
;; API key:
;;
;; - The client is the OAuth registration the user authorizes.  The
;;   first sign-in of a ChatGPT account registers dynamically: the
;;   authorization request carries `client_id=dynamic_agent_client'
;;   together with the app's `agent_name_hint', and the new-registration
;;   callback returns the client id that was issued for that account
;;   (`oaiapp_...').  That issued id is what is saved and reused, and
;;   `dynamic_agent_client' is never saved nor used for a token
;;   exchange.  A later sign-in of the same account reuses its issued
;;   client id and sends the retained id token as `id_token_hint' (and
;;   the saved email as `login_hint'), which skips the account picker;
;;   `agent_name_hint' is sent only when registering.
;; - The agent host is where this harness runs.  It is named by a
;;   stable `ext_agent_host_id', a `urn:uuid:...' generated once and
;;   kept in `harness-chatgpt-plan-host-id-file' for the life of this
;;   host.  Signing in again, or signing out, does not make a new one.
;;   OpenAI's own recommendation is a JWK thumbprint URI derived from a
;;   key pair; a UUIDv4 in `urn:uuid:' form is the documented
;;   alternative and is what this module uses, since the host id is an
;;   opaqued identifier and not a credential.  (If the harness is later
;;   given a key pair for this, the value may simply be replaced before
;;   the next sign-in.)
;;
;; What is asked for.  The authorization request asks for the identity
;; scopes `openid profile email' and the ChatGPT-plan scopes
;; `offline_access resource.invoke chatgpt.tokens.use.direct', with
;; `resource=https://api.openai.com/v1'.  The granted scopes come back
;; from the token response, which is what is trusted: a valid id token
;; without `chatgpt.tokens.use.direct' means the sign-in worked but the
;; plan cannot pay, and the account is kept and reported as such rather
;; than being used for inference.  A state, a nonce and a PKCE verifier
;; are fresh for every attempt, the state is checked on the callback
;; before anything else, and the nonce is checked against the id token.
;;
;; The id token.  Its signature is not verified here: it arrives over
;; TLS straight from the token endpoint, which OpenID Connect Core
;; 3.1.3.7 takes in place of a signature, and which is how the
;; harness's other OIDC flow reads its own (see harness-acp-remote.el).
;; What is checked is what the docs ask for: the issuer is the auth
;; host, the audience is the client id that was issued for this attempt,
;; the token is not expired, the nonce is the one of the attempt, the
;; subject is present (it is the account identity), and the email is
;; taken from it for display.  The subject -- not the email, which two
;; registrations may share -- is what names the account record.
;;
;; Credentials.  Each account's record is one entry of a JSON file,
;; `harness-chatgpt-plan-credentials-file' (by default
;; `chatgpt-plan.json' in `harness-state-directory'), written whole and
;; atomically with mode 0600: the access token, the refresh token, the
;; retained id token, the issued client id, the granted scopes, when the
;; access token expires and when the record was saved, the account's
;; email and subject, and the host id.  Tokens are never logged, never
;; put in a URL, and never returned by a method: `chatgpt-plan/status'
;; describes the accounts without them.  They are also registered as
;; secret sources (lisp/modules/harness-secrets.el), so a tool result or
;; a log line that happens to quote the credentials file, or a token
;; itself, is masked before anything keeps it.
;;
;; Refreshing.  An access token lasts an hour, a refresh token thirty
;; days, and each successful refresh replaces the refresh token, so two
;; processes refreshing at once would lose one of the grants.  A refresh
;; is therefore serialized both inside this Emacs (one refresh in flight
;; per account, and a caller that asks while one runs waits for its
;; result) and across processes, with an exclusive lock file beside the
;; credentials (a lock left by a process that died is broken after
;; `harness-chatgpt-plan-lock-stale').  The credentials are read again
;; once the lock is held: another process may have refreshed already.
;; A refresh failure the docs name as unusable -- `invalid_grant',
;; `invalid_refresh_token', `token_expired', `refresh_token_expired',
;; `refresh_token_invalidated', `refresh_token_reused' -- clears the
;; tokens of that account (keeping its identity, its issued client id
;; and the host id) and reports that it has to be signed in again; the
;; next sign-in reuses the saved client id.  `invalid_client' clears the
;; issued client id too, so the next sign-in registers anew.
;;
;; Signing out.  The renewable session is revoked at the
;; `revocation_endpoint' of https://auth.openai.com/.well-known/openid-configuration
;; with the refresh token, `token_type_hint=refresh_token' and the issued
;; client id, and the local tokens are cleared afterwards (the account
;; mapping, the client id and the host id stay, since a later sign-in is
;; meant to reuse them).  A revocation that cannot be confirmed -- the
;; network is down, the endpoint answers 5xx -- is reported rather than
;; silently assumed, and the tokens are cleared all the same, as the
;; docs ask.
;;
;; Getting an access token.  `chatgpt-plan/access-token' returns a
;; promise of a token that is valid now, refreshing it first when it is
;; close to expiry (`harness-chatgpt-plan-refresh-margin').  A caller
;; that cannot wait is not served: the provider starts its request when
;; the token arrives.
;;
;; Commands.  `harness-chatgpt-plan-sign-in' signs an account in (a new
;; registration, or again when one is named), `harness-chatgpt-plan-sign-out'
;; revokes and forgets its tokens, and `harness-chatgpt-plan-status'
;; says in a message what accounts exist and whether their plan may be
;; used.  A UI can be built on the same three methods; none of them
;; needs one.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)
(require 'url-parse)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)

(defvar harness-state-directory)

;;;; Settings

(defconst harness-chatgpt-plan-authorize-path "/api/accounts/authorize"
  "Path of the authorization endpoint below `harness-chatgpt-plan-auth-base'.")

(defconst harness-chatgpt-plan-token-path "/api/accounts/oauth/token"
  "Path of the token endpoint below `harness-chatgpt-plan-auth-base'.")

(defconst harness-chatgpt-plan-discovery-path "/.well-known/openid-configuration"
  "Path of the OpenID Connect discovery document below the auth base.")

(defconst harness-chatgpt-plan-host-id-prefix "urn:uuid:"
  "What this host's `ext_agent_host_id' starts with.
A UUIDv4 is one of the host-id formats OpenAI accepts for an
open-source client; a JWK thumbprint URI is the recommended one and
would go here instead, without the prefix.")

(defconst harness-chatgpt-plan-dynamic-client-id "dynamic_agent_client"
  "The `client_id' that asks OpenAI to register a new client.
It is the entrypoint of a first sign-in, never an issued client id,
never saved, and never used for a token exchange (see the Commentary).")

(defconst harness-chatgpt-plan-callback-path "/auth/callback"
  "Path of the loopback callback.  It may not vary between attempts.
Only the port may, so this is fixed and the redirect URI is built from
it for each attempt; `/callback' would not match it.")

(defcustom harness-chatgpt-plan-auth-base "https://auth.openai.com"
  "Base URL of OpenAI's authorization server.
Tests point it at a server of their own; it is not for other hosts."
  :type 'string :group 'harness)

(defcustom harness-chatgpt-plan-api-base "https://api.openai.com/v1"
  "Base URL of the Responses API that a ChatGPT plan pays for.
This is the `resource' of the OAuth grant and the root the provider of
harness-provider-responses.el sends its requests to."
  :type 'string :group 'harness)

(defcustom harness-chatgpt-plan-agent-name "Emacs agent harness"
  "The app name shown in ChatGPT while an account is being registered.
It is `agent_name_hint' of a first sign-in: the user sees it on the
consent screen and may edit it there, and it is display metadata rather
than identity.  Send it consistently across installations, and only
when registering: a later sign-in of a saved account omits it."
  :type 'string :group 'harness)

(defcustom harness-chatgpt-plan-scopes
  '("openid" "profile" "email" "offline_access" "resource.invoke" "chatgpt.tokens.use.direct")
  "Scopes to ask for when signing in.
`chatgpt.tokens.use.direct' is the one that lets this app use the
account's ChatGPT plan; `offline_access' is what a refresh token needs.
The granted scopes come back from the token response and are what the
harness trusts."
  :type '(repeat string) :group 'harness)

(defcustom harness-chatgpt-plan-refresh-margin 60
  "Seconds before expiry at which an access token is refreshed.
A token with less than this left is not handed to a caller: the
request about to be made would be sent with a token that expires while
it is in flight."
  :type 'natnum :group 'harness)

(defcustom harness-chatgpt-plan-sign-in-timeout 600
  "Seconds a sign-in may take from the browser opening to the callback.
The listener is closed and the attempt fails afterwards; the user can
start again, which is a fresh attempt with a fresh state, nonce, PKCE
verifier and port."
  :type 'natnum :group 'harness)

(defcustom harness-chatgpt-plan-lock-stale 60
  "Seconds after which a refresh lock is taken to be abandoned.
A process that dies holding the lock leaves the file behind, and no
later refresh would ever run.  A lock older than this is broken."
  :type 'natnum :group 'harness)

(defcustom harness-chatgpt-plan-credentials-file nil
  "File the ChatGPT credentials are kept in, or nil for the default.
The default is `chatgpt-plan.json' in `harness-state-directory'.  The
file holds the access, refresh and id tokens of every account, so it is
written atomically with mode 0600 and never logged; it is also a source
of the secrets that masking takes out of tool output."
  :type '(choice (const :tag "In the state directory" nil)
                 (file :tag "File"))
  :group 'harness)

(defcustom harness-chatgpt-plan-host-id-file nil
  "File this host's `ext_agent_host_id' is kept in, or nil for the default.
The default is `chatgpt-plan-host-id' beside the credentials file.  The
value is a `urn:uuid:' generated once and reused for every sign-in, and
it survives signing out: the host is the same host."
  :type '(choice (const :tag "Beside the credentials file" nil)
                 (file :tag "File"))
  :group 'harness)

;;;; State

(defvar harness-chatgpt-plan--pending nil
  "The sign-in attempt in progress, or nil.
A plist: `:state' `:nonce' `:verifier' `:redirect-uri' `:client-id'
\(the issued one, once a registration returned it) `:registration'
\(non-nil while this attempt registers a new client) `:account' (the
account record being reauthorized, if any), `:listener' (the loopback
process), `:promise' (what the caller waits on) and `:timer'.")

(defvar harness-chatgpt-plan--refreshes (make-hash-table :test 'equal)
  "Account id -> the promise of the refresh in flight for it.
A caller that asks for a token while a refresh runs waits for that
refresh rather than starting a second one, which would race the
rotating refresh token.")

(defvar harness-chatgpt-plan--discovery nil
  "The provider's discovery document, kept for an hour.
A plist (:fetched TIME :document PLIST).  It is what the
`revocation_endpoint' is read from, so it is asked for when signing
out and cached between sign-outs.")

(defvar harness-chatgpt-plan--opener #'browse-url
  "Function called with the authorization URL to open the browser.
A test binds it to something that drives the callback itself; there is
no other reason to change it.")

;;;; Random values and PKCE

(defconst harness-chatgpt-plan--fallback-note
  "chatgpt-plan: no system source of random bytes; values are weaker than they should be")

(defun harness-chatgpt-plan--random-bytes (n)
  "Return N random bytes, a unibyte string.
Read from /dev/urandom, else from openssl, else gathered from whatever
this Emacs can hash together.  A state, a nonce and a PKCE verifier
have to be unpredictable, so the last way is announced in the log."
  (or (condition-case nil
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally "/dev/urandom" nil 0 n)
            (and (= (buffer-size) n) (buffer-string)))
        (error nil))
      (and (executable-find "openssl")
           (condition-case nil
               (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (let ((coding-system-for-read 'binary))
                   (when (eq 0 (call-process "openssl" nil t nil "rand" (number-to-string n)))
                     (and (= (buffer-size) n) (buffer-string)))))
             (error nil)))
      (progn
        (harness-log 'warn "%s" harness-chatgpt-plan--fallback-note)
        (substring (secure-hash 'sha512 (format "%s %s %s %s" (random t) (float-time)
                                                (emacs-pid) (list (garbage-collect)))
                                nil nil t)
                   0 n))))

(defun harness-chatgpt-plan--random-string (&optional bytes)
  "Return a fresh random string of BYTES bytes (32) in base64url.
Base64url without padding is what OAuth wants in a `state', a `nonce'
and a PKCE verifier: URL-safe, and no `=' to be escaped."
  (base64url-encode-string (harness-chatgpt-plan--random-bytes (or bytes 32)) t))

(defun harness-chatgpt-plan--pkce ()
  "Return (VERIFIER . CHALLENGE) for a fresh PKCE pair.
VERIFIER is 32 random bytes in base64url; CHALLENGE is the base64url of
its SHA-256 without padding, which is the S256 method."
  (let ((verifier (harness-chatgpt-plan--random-string 32)))
    (cons verifier (base64url-encode-string (secure-hash 'sha256 verifier nil nil t) t))))

;;;; Where things are kept

(defun harness-chatgpt-plan-credentials-file ()
  "Return the file the ChatGPT credentials are kept in."
  (or harness-chatgpt-plan-credentials-file
      (expand-file-name "chatgpt-plan.json" harness-state-directory)))

(defun harness-chatgpt-plan-host-id-file ()
  "Return the file this host's `ext_agent_host_id' is kept in."
  (or harness-chatgpt-plan-host-id-file
      (expand-file-name "chatgpt-plan-host-id"
                        (file-name-directory (harness-chatgpt-plan-credentials-file)))))

(defun harness-chatgpt-plan-host-id ()
  "Return this host's `ext_agent_host_id', making and keeping one if needed.
The value is a `urn:uuid:' string written once to
`harness-chatgpt-plan-host-id-file' and read from there afterwards, so
every sign-in of this host sends the same id.  A host id is an opaque
identifier, not a credential, and it is not a secret: it holds nothing
about the user and is not masked."
  (let ((file (harness-chatgpt-plan-host-id-file)))
    (or (let ((text (harness-read-file file)))
          (let ((value (and text (string-trim text))))
            (and (not (string-empty-p value)) value)))
        (let ((value (concat harness-chatgpt-plan-host-id-prefix (harness-uuid))))
          (condition-case err
              (harness-write-file-atomically file (concat value "\n"))
            (error (harness-log 'warn "chatgpt-plan: cannot keep the host id in %s: %s"
                                file (harness-error-message err))))
          value))))

;;;; The credential record

(defconst harness-chatgpt-plan--account-keys
  '(:id :label :email :subject :issuer :client-id :host-id :id-token :access-token
        :refresh-token :token-type :scopes :expires-at :saved-at :needs-sign-in)
  "Keys of an account record, in the order they are written.
The code reads and writes them as hyphenated keywords; the file spells
them as OpenAI's documentation does (`client_id', `refresh_token'),
which `harness-chatgpt-plan--field-name' converts.")

(defun harness-chatgpt-plan--field-name (key)
  "Return KEY, a keyword of an account record, as the file spells it.
`:client-id' is \"client_id\", `:needs-sign-in' is \"needs_sign_in\"."
  (replace-regexp-in-string "-" "_" (string-remove-prefix ":" (symbol-name key))))

(defun harness-chatgpt-plan--read-record (json)
  "Return the account record at JSON, a plist as parsed from the file, or nil.
Only the keys of `harness-chatgpt-plan--account-keys' are read, and a
JSON `false' becomes nil."
  (let (out)
    (cl-loop for name in harness-chatgpt-plan--account-keys
             for stored = (harness-chatgpt-plan--field-name name)
             for value = (plist-get json (intern (concat ":" stored)))
             when (and value (not (eq value :false)))
             do (setq out (plist-put out name value)))
    (when (plist-get out :scopes)
      (setq out (plist-put out :scopes (delq nil (mapcar (lambda (s) (and (stringp s) s))
                                                         (plist-get out :scopes))))))
    (when (plist-get out :id) out)))

(defun harness-chatgpt-plan--record-json (record)
  "Return RECORD, an account plist, as the JSON plist the file holds.
A key with no value is left out, so the file says what is known and
nothing else."
  (let (out)
    (cl-loop for name in harness-chatgpt-plan--account-keys
             for value = (plist-get record name)
             when (and value (or (not (listp value)) value))
             do (setq out (plist-put out (intern (concat ":" (harness-chatgpt-plan--field-name name)))
                                     (if (and (listp value) (not (stringp value)))
                                         (harness-json-array value)
                                       value))))
    out))

(defun harness-chatgpt-plan-credentials ()
  "Return the whole credential document as a plist, or nil.
`:host-id', `:active' (the id of the selected account) and
`:accounts' (a list of account plists).  A file that is absent, empty,
or cannot be parsed reads as nil -- no document at all -- rather than
signalled: a file that cannot be parsed would otherwise make every
provider call fail, and nothing is known about it either way.  The
reason is logged, so a file the user expected to work is not silently
ignored."
  (let* ((file (harness-chatgpt-plan-credentials-file))
         (text (harness-read-file file))
         (json (and text (not (string-blank-p text))
                    (condition-case err
                        (harness-json-parse text)
                      (error (harness-log 'error "chatgpt-plan: %s is not readable JSON: %s"
                                          file (harness-error-message err))
                             nil)))))
    (when json
      (list :host-id (plist-get json :host_id)
            :active (plist-get json :active)
            :accounts (delq nil (mapcar #'harness-chatgpt-plan--read-record
                                        (append (plist-get json :accounts) nil)))))))

(defun harness-chatgpt-plan--save (credentials)
  "Write CREDENTIALS, a plist as `harness-chatgpt-plan-credentials' returns.
The file is written whole, atomically, and readable only by its owner.
The host id of the host is written with it, not one of the accounts.
Return CREDENTIALS."
  (let ((file (harness-chatgpt-plan-credentials-file)))
    (harness-ensure-directory (file-name-directory file))
    (let ((json (list :host_id (harness-chatgpt-plan-host-id)
                      :active (plist-get credentials :active)
                      :accounts (harness-json-array
                                 (mapcar #'harness-chatgpt-plan--record-json
                                         (plist-get credentials :accounts))))))
      (with-file-modes #o600
        (harness-write-file-atomically file (concat (harness-json-encode json) "\n")))
      ;; `with-file-modes' does not reach the file `rename-file' left there
      ;; on every system, so the mode is set on it as well.
      (ignore-errors (set-file-modes file #o600)))
    credentials))

(defun harness-chatgpt-plan-accounts ()
  "Return the account records, each as a plist without any token."
  (mapcar (lambda (a) (harness-plist-remove a :access-token :refresh-token :id-token))
          (plist-get (harness-chatgpt-plan-credentials) :accounts)))

(defun harness-chatgpt-plan-account (account)
  "Return the account record ACCOUNT names, or nil.
ACCOUNT may be an account id, an email address, a record plist, or nil
for the active account."
  (let* ((credentials (harness-chatgpt-plan-credentials))
         (accounts (plist-get credentials :accounts))
         (wanted (cond ((null account) (plist-get credentials :active))
                       ((stringp account) account)
                       ((consp account) (plist-get account :id)))))
    (cond
     ((null wanted) nil)
     ((cl-find wanted accounts :key (lambda (a) (plist-get a :id)) :test #'equal))
     ((cl-find wanted accounts :key (lambda (a) (plist-get a :email)) :test #'equal))
     ((cl-find (format "%s" wanted) accounts :key (lambda (a) (plist-get a :label)) :test #'equal))
     ;; With no selection yet, or a selection that is gone, the only account
     ;; there is is the one meant.
     ((and (null account) (= 1 (length accounts))) (car accounts)))))

(defun harness-chatgpt-plan--put-account (record &optional active)
  "Save RECORD among the accounts, selecting it when ACTIVE is non-nil.
An account with the record's id replaces the one stored, in the place
it already had, so a second sign-in of the same account updates its
tokens rather than adding a record or moving it to the end of the list."
  (let* ((credentials (harness-chatgpt-plan-credentials))
         (old (plist-get credentials :accounts))
         (id (plist-get record :id))
         (found nil)
         (accounts (mapcar (lambda (a)
                             (if (equal (plist-get a :id) id)
                                 (progn (setq found t) record)
                               a))
                           old)))
    (harness-chatgpt-plan--save
     (list :host-id (or (plist-get credentials :host-id) (harness-chatgpt-plan-host-id))
           :active (if active id (plist-get credentials :active))
           :accounts (if found accounts (append accounts (list record)))))))

(defun harness-chatgpt-plan--update-account (id fn)
  "Save the account ID with FN applied to its record; return the new record.
Return nil when no account has that id."
  (let* ((credentials (harness-chatgpt-plan-credentials))
         (record (cl-find id (plist-get credentials :accounts)
                          :key (lambda (a) (plist-get a :id)) :test #'equal))
         (new (and record (funcall fn record))))
    (when new
      (let ((accounts (mapcar (lambda (a) (if (equal (plist-get a :id) id) new a))
                              (plist-get credentials :accounts))))
        (harness-chatgpt-plan--save (plist-put (plist-put credentials :accounts accounts)
                                               :host-id (plist-get credentials :host-id))))
      new)))

(defun harness-chatgpt-plan-status (&optional account)
  "Return what is known about the signed-in accounts, without any token.
A plist:

  :host-id      this host's `ext_agent_host_id'
  :file         the credentials file
  :active       the id of the selected account, or nil
  :accounts     one plist per account: :id :label :email :subject
                :client-id :scopes :expires-at :saved-at :plan
                :signed-in (a usable access token is held)
                :plan-usage (the grant may pay for inference)
                :needs-sign-in (the tokens were refused and it must be
                signed in again)
  :signed-in    non-nil when at least one account has a usable token
  :plan-usage   non-nil when at least one account may pay

ACCOUNT, when given, lists only that one (and `:active' names it)."
  (let* ((credentials (harness-chatgpt-plan-credentials))
         (accounts (plist-get credentials :accounts))
         (accounts (if account
                       (let ((one (harness-chatgpt-plan-account account)))
                         (and one (list one)))
                     accounts)))
    (list :host-id (or (plist-get credentials :host-id) (harness-chatgpt-plan-host-id))
          :file (harness-chatgpt-plan-credentials-file)
          :active (or (and account (plist-get (car accounts) :id))
                      (plist-get credentials :active))
          :accounts (mapcar #'harness-chatgpt-plan--describe accounts)
          :signed-in (and (cl-some (lambda (a) (harness-chatgpt-plan--signed-in-p a)) accounts) t)
          :plan-usage (and (cl-some #'harness-chatgpt-plan--plan-usage-p accounts) t))))

(defun harness-chatgpt-plan--signed-in-p (record)
  "Non-nil when RECORD holds a usable access token and its refresh token."
  (and (harness-chatgpt-plan--token-string (plist-get record :access-token))
       (harness-chatgpt-plan--token-string (plist-get record :refresh-token))
       (not (harness-json-true-p (plist-get record :needs-sign-in)))))

(defun harness-chatgpt-plan--plan-usage-p (record)
  "Non-nil when RECORD's grant lets the ChatGPT plan pay for inference.
A valid id token alone is not enough; the granted scopes have to
contain `chatgpt.tokens.use.direct'."
  (and (member "chatgpt.tokens.use.direct" (plist-get record :scopes))
       (harness-chatgpt-plan--signed-in-p record)))

(defun harness-chatgpt-plan--describe (record)
  "Return RECORD as `harness-chatgpt-plan-status' lists an account."
  (list :id (plist-get record :id)
        :label (or (plist-get record :label) (plist-get record :email) (plist-get record :id))
        :email (plist-get record :email)
        :subject (plist-get record :subject)
        :client-id (plist-get record :client-id)
        :scopes (plist-get record :scopes)
        :expires-at (plist-get record :expires-at)
        :saved-at (plist-get record :saved-at)
        :signed-in (harness-chatgpt-plan--signed-in-p record)
        :plan-usage (harness-chatgpt-plan--plan-usage-p record)
        :needs-sign-in (and (harness-json-true-p (plist-get record :needs-sign-in)) t)))

(defun harness-chatgpt-plan--token-string (value)
  "Return VALUE when it is a non-empty string, else nil.
A token in the file may be a JSON string, and nothing else counts."
  (and (stringp value) (not (string-empty-p value)) value))

;;;; Secrets

(defun harness-chatgpt-plan--register-secrets ()
  "Have masking take this account's tokens out of what the harness keeps.
The tokens are named by where they can be read -- the credential file
and a JSON path into it -- never by their value, so registering them
keeps no copy of a token outside the file.  Nothing happens when the
secrets module is not loaded, or when the file does not exist yet; a
failure is logged and never signalled, since the sign-in itself is
done by then."
  (when (and (harness-method-exists-p 'secrets/add-source)
             (file-readable-p (harness-chatgpt-plan-credentials-file)))
    (dolist (key '(:access-token :refresh-token :id-token))
      (condition-case err
          (harness-call 'secrets/add-source
                        (list :file (harness-chatgpt-plan-credentials-file)
                              :json-path (format "accounts.*.%s" (harness-chatgpt-plan--field-name key))
                              :label (format "ChatGPT %s" (string-remove-prefix ":" (harness-chatgpt-plan--field-name key)))))
        (error (harness-log 'debug "chatgpt-plan: registering %s as a secret failed: %s"
                            key (harness-error-message err)))))))

;;;; Talking to the authorization server

(defun harness-chatgpt-plan--url (path)
  "Return PATH below `harness-chatgpt-plan-auth-base'."
  (concat (string-remove-suffix "/" harness-chatgpt-plan-auth-base) path))

(defun harness-chatgpt-plan--form-encode (fields)
  "Return FIELDS, an alist of (NAME . VALUE), as a form-encoded body."
  (mapconcat (lambda (field)
               (format "%s=%s" (url-hexify-string (car field))
                       (url-hexify-string (or (cdr field) ""))))
             fields "&"))

(defun harness-chatgpt-plan--post-form (url fields)
  "POST FIELDS, an alist, form-encoded to URL; return a promise of the JSON.
A failure rejects with (http-error STATUS BODY) or (json-error STATUS
MESSAGE), so a caller can read the OAuth error code out of BODY."
  (condition-case err
      (harness-http-request-json
       url
       :method "POST"
       :headers '(("Content-Type" . "application/x-www-form-urlencoded"))
       :body (harness-chatgpt-plan--form-encode fields)
       :timeout 60)
    (error (harness-rejected err))))

(defun harness-chatgpt-plan--error-response (err)
  "Return (STATUS . BODY) for ERR, a request rejection here, or nil.
`harness-http-request-json' rejects an HTTP failure with (http-error
STATUS BODY) and a body that would not parse with (json-error STATUS
MESSAGE); a transport failure has no body."
  (pcase err
    (`(http-error ,status ,body) (cons status (and (stringp body) body)))
    (`(json-error ,status ,message) (cons status (and (stringp message) message)))
    (_ nil)))

(defun harness-chatgpt-plan--error-info (err)
  "Return (CODE . MESSAGE) for ERR, a rejection of a request here, or nil.
The token endpoint answers a failure with a JSON object holding `error'
and `error_description', and nothing else is trusted: a body that is
not that object yields no code, so its text is only ever logged short.
No token can end up in the result, since only these two fields are
read out of the body."
  (let ((body (cdr (harness-chatgpt-plan--error-response err))))
    (when (stringp body)
      (let* ((json (ignore-errors (harness-json-parse body)))
             (code (plist-get json :error))
             (message (or (plist-get json :error_description) (plist-get json :message))))
        (when (or (stringp code) (stringp message))
          (cons (and (stringp code) code)
                (and (stringp message) (harness-first-line message 300))))))))

(defun harness-chatgpt-plan--describe-error (err &optional fallback)
  "Return ERR, a rejection of a request here, as a short message.
The OAuth error code names the failure, which is what a caller decides
on; FALLBACK is what to say when the body says nothing."
  (pcase-let ((`(,code . ,message) (harness-chatgpt-plan--error-info err)))
    (cond ((and code message) (format "%s: %s" code message))
          (code code)
          (message message)
          (t (or fallback
                 (let ((status (car (harness-chatgpt-plan--error-response err))))
                   (format "request failed%s"
                           (if (numberp status) (format " (HTTP %s)" status) ""))))))))

;;;; The authorization URL

(defun harness-chatgpt-plan-authorize-url (pending &optional account)
  "Return the authorization URL of the sign-in attempt PENDING.
PENDING is the attempt's plist, whose `:state', `:nonce', `:verifier'
and `:redirect-uri' go on the wire.  ACCOUNT, when given, is the record
being signed in again: its issued client id is used instead of the
registration entrypoint, its retained id token goes as `id_token_hint'
and its email as `login_hint', and `agent_name_hint' is left out.
Registering sends `agent_name_hint' and the host id."
  (let* ((registration (plist-get pending :registration))
         (client-id (if registration
                        harness-chatgpt-plan-dynamic-client-id
                      (or (plist-get pending :client-id)
                          (plist-get account :client-id)
                          harness-chatgpt-plan-dynamic-client-id)))
         (verifier (plist-get pending :verifier))
         (fields (append
                  (list (cons "client_id" client-id)
                        (cons "ext_agent_host_id" (harness-chatgpt-plan-host-id)))
                  (when registration
                    (list (cons "agent_name_hint" harness-chatgpt-plan-agent-name)))
                  (when-let* ((hint (plist-get account :id-token)))
                    (list (cons "id_token_hint" hint)))
                  (when-let* ((email (plist-get account :email)))
                    (list (cons "login_hint" email)))
                  (list (cons "response_type" "code")
                        (cons "redirect_uri" (plist-get pending :redirect-uri))
                        (cons "scope" (string-join harness-chatgpt-plan-scopes " "))
                        (cons "resource" harness-chatgpt-plan-api-base)
                        (cons "state" (plist-get pending :state))
                        (cons "nonce" (plist-get pending :nonce))
                        (cons "code_challenge_method" "S256")
                        (cons "code_challenge"
                              (base64url-encode-string (secure-hash 'sha256 verifier nil nil t) t))))))
    (concat (harness-chatgpt-plan--url harness-chatgpt-plan-authorize-path)
            "?" (harness-chatgpt-plan--form-encode fields))))

;;;; The loopback callback

(defun harness-chatgpt-plan--escape (text)
  "Return TEXT with the characters HTML needs escaped."
  (when (stringp text)
    (replace-regexp-in-string
     "[&<>\"']"
     (lambda (c) (pcase c ("&" "&amp;") ("<" "&lt;") (">" "&gt;")
                    ("\"" "&quot;") (_ "&#39;")))
     text t t)))

(defun harness-chatgpt-plan--page (title body)
  "Return a small HTML page with TITLE and BODY, as the callback answers."
  (concat
   "<!doctype html><html><head><meta charset=\"utf-8\"><title>"
   (harness-chatgpt-plan--escape title)
   "</title><style>body{font-family:system-ui,sans-serif;margin:4rem auto;max-width:32rem;"
   "line-height:1.5;color:#222}h1{font-size:1.4rem}</style></head><body><h1>"
   (harness-chatgpt-plan--escape title) "</h1><p>" (harness-chatgpt-plan--escape body)
   "</p></body></html>\n"))

(defun harness-chatgpt-plan--respond (process status title body)
  "Answer PROCESS with a small page: STATUS, TITLE and BODY."
  (let ((page (harness-chatgpt-plan--page title body)))
    (condition-case nil
        (process-send-string
         process (concat (format "HTTP/1.1 %d %s\r\n" status (if (< status 400) "OK" "Error"))
                         "Content-Type: text/html; charset=utf-8\r\n"
                         (format "Content-Length: %d\r\n" (string-bytes page))
                         "Connection: close\r\n\r\n" page))
      (error nil)))
  (ignore-errors (delete-process process)))

(defun harness-chatgpt-plan--request-line (text)
  "Return the request LINE of an HTTP request in TEXT, or nil."
  (when (string-match "\\`[A-Z]+ \\([^ ]+\\) " text)
    (match-string 1 text)))

(defun harness-chatgpt-plan--query (target)
  "Return the query parameters of TARGET, a request target, as an alist.
The values are URL-decoded; a parameter that appears twice keeps the
first."
  (let* ((query (and (string-match "\\?" target) (substring target (1+ (match-beginning 0)))))
         (fields (and query (url-parse-query-string query))))
    (mapcar (lambda (field) (cons (car field) (or (cadr field) ""))) fields)))

(defun harness-chatgpt-plan--listener-filter (process data)
  "Handle DATA, a piece of the HTTP request, on PROCESS, the callback listener.
The request line is what matters: the callback parameters are in its
target.  Anything else -- a favicon, a probe -- is answered 404 and
forgotten, and the attempt goes on waiting."
  (let ((text (concat (or (process-get process 'chatgpt-plan-request) "") data)))
    (process-put process 'chatgpt-plan-request text)
    (when (string-match "\r?\n\r?\n" text)
      (let ((target (harness-chatgpt-plan--request-line text)))
        (cond
         ((null target) (ignore-errors (delete-process process)))
         ((string-prefix-p harness-chatgpt-plan-callback-path
                           (car (split-string target "?")))
          (harness-chatgpt-plan--callback process (harness-chatgpt-plan--query target)))
         (t (harness-chatgpt-plan--respond process 404 "Nothing here"
                                            "This address is this sign-in's callback and nothing else.")))))))

(defun harness-chatgpt-plan--callback (process fields)
  "Handle the callback on PROCESS with FIELDS, an alist from its query.
Whatever happens, the browser is answered and the listener is closed;
the attempt is finished only when the state checks out, and the
attacker who guessed the port learns nothing from the answer."
  (let ((pending harness-chatgpt-plan--pending)
        (state (cdr (assoc "state" fields))))
    (cond
     ((null pending)
      (harness-chatgpt-plan--respond process 410 "This sign-in is over"
                                     "Start again from Emacs."))
     ((not (equal state (plist-get pending :state)))
      (harness-chatgpt-plan--respond process 400 "This sign-in was not started here"
                                     "The state does not match. Start again from Emacs.")
      (harness-log 'warn "chatgpt-plan: a callback arrived with the wrong state; ignored"))
     (t
      (harness-chatgpt-plan--respond process 200 "Signed in to ChatGPT"
                                     "You can close this window and return to Emacs.")
      (let ((code (cdr (assoc "code" fields)))
            (oauth-error (cdr (assoc "error" fields)))
            (issued (cdr (assoc "client_id" fields))))
        (cond
         (oauth-error
          (harness-chatgpt-plan--fail
           pending
           (format "the sign-in was refused (%s%s)" oauth-error
                   (if-let* ((description (cdr (assoc "error_description" fields))))
                       (concat ": " description)
                     ""))))
         ((or (null code) (string-empty-p code))
          (harness-chatgpt-plan--fail pending "the callback carried no authorization code"))
         (t (harness-chatgpt-plan--finish-callback pending code issued))))))))

(defun harness-chatgpt-plan--finish-callback (pending code issued)
  "Exchange CODE for tokens as the attempt PENDING describes.
ISSUED is the client id the new-registration callback returned, if any.
A registration that returns no issued client id is incomplete and
fails; a reauthorization keeps the client id it already has, and a
callback that names a different one is refused rather than silently
replacing the account's registration."
  (let ((registration (plist-get pending :registration))
        (known (plist-get pending :client-id)))
    (cond
     ((and registration (or (null issued) (string-empty-p issued)))
      (harness-chatgpt-plan--fail
       pending "the registration returned no client id, so it did not finish"))
     ((and registration (equal issued harness-chatgpt-plan-dynamic-client-id))
      (harness-chatgpt-plan--fail
       pending "the registration returned the entrypoint id instead of an issued one"))
     ((and (not registration) issued (not (string-empty-p issued)) known
           (not (equal issued known)))
      (harness-chatgpt-plan--fail
       pending "the callback named another client id than this account's registration"))
     (t
      (let* ((client-id (if registration issued known))
             (pending (plist-put (copy-sequence pending) :client-id client-id))
             (fields (list (cons "grant_type" "authorization_code")
                           (cons "client_id" client-id)
                           (cons "code" code)
                           (cons "code_verifier" (plist-get pending :verifier))
                           (cons "redirect_uri" (plist-get pending :redirect-uri))
                           (cons "resource" harness-chatgpt-plan-api-base))))
        (harness-then
         (harness-chatgpt-plan--post-form
          (harness-chatgpt-plan--url harness-chatgpt-plan-token-path) fields)
         (lambda (response) (harness-chatgpt-plan--accept-tokens pending response))
         (lambda (err)
           (harness-chatgpt-plan--fail
            pending (format "the code exchange failed (%s)"
                            (harness-chatgpt-plan--describe-error err "no answer"))))))))))

;;;; Finishing an attempt

(defun harness-chatgpt-plan--close-pending ()
  "Close the listener of the attempt in progress, if it has one."
  (when-let* ((pending harness-chatgpt-plan--pending))
    (when-let* ((timer (plist-get pending :timer))) (cancel-timer timer))
    (when-let* ((listener (plist-get pending :listener)))
      (when (process-live-p listener) (delete-process listener)))))

(defun harness-chatgpt-plan--fail (pending message)
  "Fail the attempt PENDING with MESSAGE, which carries no token.
The listener is closed, whatever waits is rejected, and the message is
logged once; a sign-in the user did not finish is a normal thing to
give up on, not an error of the harness."
  (setq harness-chatgpt-plan--pending nil)
  (harness-chatgpt-plan--close-pending-listener pending)
  (harness-log 'info "chatgpt-plan: sign-in did not finish: %s" message)
  (when-let* ((promise (plist-get pending :promise)))
    (harness-reject promise (list 'harness-error message))))

(defun harness-chatgpt-plan--close-pending-listener (pending)
  "Close PENDING's listener and stop its timer."
  (when-let* ((timer (plist-get pending :timer))) (cancel-timer timer))
  (when-let* ((listener (plist-get pending :listener)))
    (when (process-live-p listener) (delete-process listener))))

;;;; The ID token

(defun harness-chatgpt-plan--base64url-decode (string)
  "Return the bytes of STRING, base64url text, as a unibyte string.
Emacs's `base64-decode-string' reads the standard alphabet, so the
URL-safe characters are put back and the padding a JWT leaves out is
added before it is decoded."
  (let* ((text (string-replace "_" "/" (string-replace "-" "+" string)))
         (padded (concat text (make-string (mod (- 4 (mod (length text) 4)) 4) ?=))))
    (base64-decode-string padded)))

(defun harness-chatgpt-plan--jwt-claims (token)
  "Return the claims of the JWT TOKEN as a plist, or nil when it is not one.
The payload is base64url, and it is decoded, never verified: a signature
is not checked here (see the Commentary)."
  (when (and (stringp token) (string-match "\\`[^.]+\\.\\([^.]+\\)\\." token))
    (condition-case err
        (harness-json-parse
         (decode-coding-string
          (harness-chatgpt-plan--base64url-decode (match-string 1 token)) 'utf-8))
      (error (harness-log 'debug "chatgpt-plan: cannot read an id token payload: %s"
                          (harness-error-message err))
             nil))))

(defun harness-chatgpt-plan--validate-id-token (pending response)
  "Check the id token of RESPONSE against the attempt PENDING.
Return the claims when the token holds up, else nil; what is checked is
the issuer, the audience (the client id of this attempt), the expiry on
the clock, the nonce, and that a subject is there to name the account."
  (let* ((token (plist-get response :id_token))
         (claims (harness-chatgpt-plan--jwt-claims token))
         (issuer (string-remove-suffix "/" (or (plist-get claims :iss) "")))
         (audience (plist-get claims :aud))
         (audiences (if (listp audience) audience (list audience)))
         (expected (string-remove-suffix "/" harness-chatgpt-plan-auth-base)))
    (cond
     ((null claims)
      (harness-log 'warn "chatgpt-plan: the token response carried no readable id token")
      nil)
     ((not (equal issuer expected))
      (harness-log 'warn "chatgpt-plan: the id token came from %s, not %s" issuer expected)
      nil)
     ((not (cl-member (plist-get pending :client-id) audiences :test #'equal))
      (harness-log 'warn "chatgpt-plan: the id token is not for client id %s" (plist-get pending :client-id))
      nil)
     ((and (numberp (plist-get claims :exp))
           (<= (plist-get claims :exp) (float-time)))
      (harness-log 'warn "chatgpt-plan: the id token was already expired")
      nil)
     ((and (plist-get pending :nonce) (plist-get claims :nonce)
           (not (equal (plist-get claims :nonce) (plist-get pending :nonce))))
      (harness-log 'warn "chatgpt-plan: the id token's nonce is not the one this attempt sent")
      nil)
     ((not (harness-chatgpt-plan--token-string (plist-get claims :sub)))
      (harness-log 'warn "chatgpt-plan: the id token names no subject")
      nil)
     (t claims))))

;;;; Accepting a token response

(defun harness-chatgpt-plan--scopes (response)
  "Return the granted scopes of RESPONSE, a token response, as a list.
The token response says them as one space-separated string."
  (let ((scope (plist-get response :scope)))
    (cl-remove-if (lambda (s) (or (null s) (string-empty-p s)))
                  (if (stringp scope) (split-string scope "[ \t\n]+") scope))))

(defun harness-chatgpt-plan--accept-tokens (pending response)
  "Store the tokens of RESPONSE for the attempt PENDING; resolve its promise.
The granted scopes decide whether the plan may pay for inference: an
id token without `chatgpt.tokens.use.direct' is a successful sign-in
that cannot be used for ChatGPT-plan inference, which is kept and
reported rather than thrown away."
  (let* ((claims (harness-chatgpt-plan--validate-id-token pending response))
         (subject (plist-get claims :sub))
         (account (plist-get pending :account))
         (id (or (and subject (format "acct-%s" (substring (secure-hash 'sha256 subject) 0 12)))
                 (plist-get account :id)
                 (format "acct-%s" (harness-short-id 12))))
         (email (or (plist-get claims :email) (plist-get account :email)))
         (scopes (harness-chatgpt-plan--scopes response))
         (expires-in (plist-get response :expires_in))
         (record (list :id id
                       :label (or email (plist-get account :label) id)
                       :email email
                       :subject (or subject (plist-get account :subject))
                       :issuer (plist-get claims :iss)
                       :client-id (plist-get pending :client-id)
                       :host-id (harness-chatgpt-plan-host-id)
                       :id-token (plist-get response :id_token)
                       :access-token (plist-get response :access_token)
                       :refresh-token (plist-get response :refresh_token)
                       :token-type (or (plist-get response :token_type) "Bearer")
                       :scopes scopes
                       :expires-at (and (numberp expires-in) (+ (float-time) expires-in))
                       :saved-at (float-time))))
    (setq harness-chatgpt-plan--pending nil)
    (harness-chatgpt-plan--close-pending-listener pending)
    (harness-chatgpt-plan--put-account record t)
    (harness-chatgpt-plan--register-secrets)
    (harness-chatgpt-plan--announce)
    (when-let* ((promise (plist-get pending :promise)))
      (harness-resolve promise (harness-chatgpt-plan-status id)))
    (harness-log 'info "chatgpt-plan: signed in as %s%s" (or email id)
                 (if (member "chatgpt.tokens.use.direct" scopes)
                     ""
                   " (the grant does not include chatgpt.tokens.use.direct, so inference on the plan is not available)"))
    (when-let* ((promise (plist-get pending :promise)))
      (ignore promise))))

(defun harness-chatgpt-plan--announce ()
  "Emit `chatgpt-plan/accounts-changed' with what is known now.
The provider module of harness-provider-responses.el listens for it and
registers or removes its provider, so a sign-in takes effect at once."
  (harness-emit 'chatgpt-plan/accounts-changed (harness-chatgpt-plan-status)))

;;;; Signing in

(defun harness-chatgpt-plan--listen ()
  "Start a loopback listener on 127.0.0.1 and return it.
The port is chosen by the operating system (`:service t'), which is the
one part of the redirect URI that may vary from attempt to attempt."
  (make-network-process :name "chatgpt-plan-callback" :server t
                        :family 'ipv4 :host "127.0.0.1" :service t
                        :coding 'utf-8-unix :noquery t
                        :filter #'harness-chatgpt-plan--listener-filter))

(defun harness-chatgpt-plan--redirect-uri (listener)
  "Return the loopback redirect URI of LISTENER.
The host is 127.0.0.1, never `localhost', and the path is the fixed
callback path: only the port is this attempt's own."
  (format "http://127.0.0.1:%d%s"
          (process-contact listener :service) harness-chatgpt-plan-callback-path))

(defun harness-chatgpt-plan-sign-in (&optional account)
  "Sign in to ChatGPT, registering this harness or reauthorizing ACCOUNT.
Return a promise of `harness-chatgpt-plan-status' for the account.
ACCOUNT names an account already signed in (its id, its email, or a
record) whose issued client id and id token are reused, so the flow
goes straight through; with none, this is a first-time registration and
the issued client id it returns is saved for later sign-ins of that
ChatGPT account.

The listener is started before the browser is opened, and the attempt
fails after `harness-chatgpt-plan-sign-in-timeout' seconds, or at once
when the user refuses the request in the browser.  Only one attempt runs
at a time: one that is already waiting is failed rather than left
hanging.  The browser is opened by `harness-chatgpt-plan--opener'."
  (interactive)
  (when harness-chatgpt-plan--pending
    (harness-chatgpt-plan--fail harness-chatgpt-plan--pending
                                "another sign-in was started in its place"))
  (let* ((existing (harness-chatgpt-plan-account account))
         (promise (harness-make-promise))
         ;; The attempt, filled in below: the callback, the timeout and the
         ;; caller all work on this one record.
         (pending (list :state (harness-chatgpt-plan--random-string 24)
                        :nonce (harness-chatgpt-plan--random-string 24)
                        :account existing
                        :promise promise)))
    (condition-case err
        (let* ((pkce (harness-chatgpt-plan--pkce))
               (listener (harness-chatgpt-plan--listen)))
          (setq pending
                (plist-put pending :verifier (car pkce)))
          (setq pending
                ;; A registration is the flow with no issued client id yet;
                ;; an account that has one reauthorizes instead.
                (plist-put pending :registration (null (plist-get existing :client-id))))
          (setq pending (plist-put pending :client-id (plist-get existing :client-id)))
          (setq pending (plist-put pending :redirect-uri
                                   (harness-chatgpt-plan--redirect-uri listener)))
          (setq pending (plist-put pending :listener listener))
          (setq harness-chatgpt-plan--pending pending)
          (plist-put pending :timer
                     (run-at-time harness-chatgpt-plan-sign-in-timeout nil
                                  (lambda ()
                                    (when (eq pending harness-chatgpt-plan--pending)
                                      (harness-chatgpt-plan--fail
                                       pending
                                       (format "no callback arrived within %ds"
                                               harness-chatgpt-plan-sign-in-timeout))))))
          (harness-log 'info "chatgpt-plan: opening the browser to sign in%s"
                       (if existing (format " as %s" (plist-get existing :label)) ""))
          (funcall harness-chatgpt-plan--opener
                   (harness-chatgpt-plan-authorize-url pending existing)))
      (error
       (setq harness-chatgpt-plan--pending nil)
       (harness-chatgpt-plan--close-pending-listener pending)
       (harness-reject promise err)))
    promise))

;;;; Access tokens and refreshing

(defun harness-chatgpt-plan--refresh-error-fatal-p (code)
  "Non-nil when CODE says the refresh token can never be used again.
These are the codes OpenAI's documentation names as unusable; a token
they name has to be replaced by a fresh sign-in, not retried."
  (member code '("invalid_grant" "invalid_refresh_token" "token_expired"
                 "refresh_token_expired" "refresh_token_invalidated" "refresh_token_reused")))

(defun harness-chatgpt-plan--clear-tokens (record &optional client-too)
  "Return RECORD without its tokens, marked as needing a sign-in.
Its identity, its issued client id and its host id stay, so a later
sign-in reuses them.  CLIENT-TOO is for `invalid_client', where the
registration itself is refused: the issued client id goes as well, so
the next sign-in registers anew."
  (harness-plist-merge record
                       (list :access-token nil :refresh-token nil :id-token nil
                             :expires-at nil :needs-sign-in t
                             :client-id (if client-too nil (plist-get record :client-id)))))

(defun harness-chatgpt-plan--refresh (record)
  "Refresh the access token of RECORD; return a promise of the token response.
The issued client id is what is sent, never the registration
entrypoint, and no scope goes with the grant so the ones already
granted stay.  The replacement refresh token is saved with the new
access token, both at once."
  (let ((fields (list (cons "grant_type" "refresh_token")
                      (cons "client_id" (plist-get record :client-id))
                      (cons "refresh_token" (plist-get record :refresh-token))
                      (cons "resource" harness-chatgpt-plan-api-base))))
    (condition-case err
        (harness-chatgpt-plan--post-form
         (harness-chatgpt-plan--url harness-chatgpt-plan-token-path) fields)
      (error (harness-rejected err)))))

(defun harness-chatgpt-plan--accept-refresh (record response)
  "Return RECORD with the tokens of RESPONSE, a refresh response.
Every field a refresh may replace is replaced together: the access
token, its expiry, the granted scopes and the rotating refresh token."
  (let ((scopes (harness-chatgpt-plan--scopes response))
        (expires-in (plist-get response :expires_in)))
    (harness-plist-merge
     record
     (list :access-token (or (plist-get response :access_token) (plist-get record :access-token))
           :refresh-token (or (plist-get response :refresh_token) (plist-get record :refresh-token))
           :id-token (or (plist-get response :id_token) (plist-get record :id-token))
           :token-type (or (plist-get response :token_type) (plist-get record :token-type))
           :scopes (if scopes scopes (plist-get record :scopes))
           :expires-at (and (numberp expires-in) (+ (float-time) expires-in))
           :saved-at (float-time)
           :needs-sign-in nil))))

(defun harness-chatgpt-plan--on-refresh-failure (record err)
  "Handle a failed refresh of RECORD, ERR being the rejection.
Return a promise rejected with a message that names no token: the
account's tokens are cleared and it has to be signed in again, and the
issued client id survives unless the registration itself was refused."
  (pcase-let ((`(,code . ,_message) (harness-chatgpt-plan--error-info err)))
    (cond
     ((harness-chatgpt-plan--refresh-error-fatal-p code)
      (harness-chatgpt-plan--update-account (plist-get record :id)
                                            (lambda (r) (harness-chatgpt-plan--clear-tokens r)))
      (harness-chatgpt-plan--announce)
      (harness-log 'warn "chatgpt-plan: the refresh token of %s is no longer usable (%s); sign in again"
                   (plist-get record :id) code)
      (harness-rejected
       (list 'harness-error
             (format "The ChatGPT sign-in of %s has to be repeated (%s): run M-x harness-chatgpt-plan-sign-in"
                     (or (plist-get record :email) (plist-get record :id)) code))))
     ((equal code "invalid_client")
      (harness-chatgpt-plan--update-account (plist-get record :id)
                                            (lambda (r) (harness-chatgpt-plan--clear-tokens r t)))
      (harness-chatgpt-plan--announce)
      (harness-log 'warn "chatgpt-plan: the issued client id of %s was refused; the next sign-in registers anew"
                   (plist-get record :id))
      (harness-rejected
       (list 'harness-error
             (format "The ChatGPT registration of %s was refused (%s): run M-x harness-chatgpt-plan-sign-in"
                     (or (plist-get record :email) (plist-get record :id)) code))))
     (t
      (harness-rejected
       (list 'harness-error
             (format "Refreshing the ChatGPT access token of %s failed (%s)"
                     (or (plist-get record :email) (plist-get record :id))
                     (harness-chatgpt-plan--describe-error err "no answer"))))))))

(defun harness-chatgpt-plan--refresh-lock-file ()
  "Return the path of the lock file that serializes refreshing."
  (concat (harness-chatgpt-plan-credentials-file) ".lock"))

(defun harness-chatgpt-plan--lock-free-p (file)
  "Non-nil when the refresh lock FILE may be taken: it is absent, or stale.
A lock left behind by a process that died is removed here, so that one
lost refresh never stops every later one."
  (if (not (file-exists-p file))
      t
    (let ((age (ignore-errors
                 (float-time (time-since (file-attribute-modification-time
                                          (file-attributes file)))))))
      (and age (>= age harness-chatgpt-plan-lock-stale)
           (progn (harness-log 'warn "chatgpt-plan: breaking a refresh lock left behind by %s" file)
                  (ignore-errors (delete-file file))
                  t)))))

(defun harness-chatgpt-plan--acquire-lock ()
  "Return a promise resolved once this process holds the refresh lock.
The lock is an exclusively created file, which two processes cannot
both make.  A lock left by a process that died is broken after
`harness-chatgpt-plan-lock-stale'; a lock that cannot be taken by then
resolves with nil rather than reject, so a refresh goes ahead unguarded
instead of never happening at all.  It resolves with the lock file's
path, or with nil when no lock was taken."
  (let* ((file (harness-chatgpt-plan--refresh-lock-file))
         (deadline (+ (float-time) harness-chatgpt-plan-lock-stale)))
    (harness-with-promise (resolve reject)
      (cl-labels
          ((give-up ()
             (harness-log 'warn "chatgpt-plan: could not take the refresh lock %s; refreshing anyway" file)
             (funcall resolve nil))
           (take ()
             (harness-ensure-directory (file-name-directory file))
             (with-file-modes #o600
               (write-region "" nil file nil 'excl))
             (funcall resolve file))
           (attempt ()
             (cond
              ((not (harness-chatgpt-plan--lock-free-p file))
               (if (>= (float-time) deadline)
                   (give-up)
                 (run-at-time 0.2 nil #'attempt)))
              (t (condition-case nil
                     (take)
                   (file-already-exists (run-at-time 0.1 nil #'attempt))
                   (error (if (>= (float-time) deadline)
                              (give-up)
                            (run-at-time 0.2 nil #'attempt))))))))
        (attempt)))))

(defun harness-chatgpt-plan--release-lock (held)
  "Release the refresh lock HELD, if one was taken."
  (when held (ignore-errors (delete-file held))))

(defun harness-chatgpt-plan--with-lock (fn)
  "Call FN with the refresh lock held; return a promise of what FN returns.
The lock is released whatever happens, including an error, so one
failed refresh never stops the next."
  (harness-then
   (harness-chatgpt-plan--acquire-lock)
   (lambda (held)
     (harness-finally (harness-as-promise (funcall fn))
                      (lambda () (harness-chatgpt-plan--release-lock held))))))

(defun harness-chatgpt-plan--token-needed-p (record)
  "Non-nil when RECORD's access token is missing or close to expiring.
A token with less than `harness-chatgpt-plan-refresh-margin' seconds
left is refreshed before it is handed out, so the request about to be
made is not sent with one that expires while it is in flight.  A token
whose expiry is not known is used as it is: there is nothing to say it
has expired, and refreshing on every call would be worse."
  (let ((token (harness-chatgpt-plan--token-string (plist-get record :access-token)))
        (expires (plist-get record :expires-at)))
    (or (null token)
        (and (numberp expires)
             (> (+ (float-time) harness-chatgpt-plan-refresh-margin) expires)))))

(defun harness-chatgpt-plan--valid-record (account)
  "Return the account record ACCOUNT names when its tokens are usable, else nil.
A record marked as needing a sign-in is not usable, and neither is one
whose refresh token is gone: there is nothing to refresh with."
  (let ((record (and account (harness-chatgpt-plan-account account))))
    (and record
         (not (harness-json-true-p (plist-get record :needs-sign-in)))
         (harness-chatgpt-plan--token-string (plist-get record :refresh-token))
         record)))

(defun harness-chatgpt-plan--refresh-now (id)
  "Refresh the tokens of account ID, holding the lock; return a promise.
The credentials are read again once the lock is held: another process
may have refreshed while this one waited, in which case there is
nothing to do."
  (harness-chatgpt-plan--with-lock
   (lambda ()
     (let ((record (harness-chatgpt-plan-account id)))
       (cond
        ((null record)
         (harness-rejected (list 'harness-error
                                 (format "No ChatGPT account %s is signed in" id))))
        ((not (harness-chatgpt-plan--token-needed-p record))
         (harness-resolved record))
        ((null (harness-chatgpt-plan--token-string (plist-get record :refresh-token)))
         (harness-chatgpt-plan--update-account id (lambda (r) (harness-chatgpt-plan--clear-tokens r)))
         (harness-rejected
          (list 'harness-error
                (format "The ChatGPT account %s has no refresh token: run M-x harness-chatgpt-plan-sign-in"
                        (or (plist-get record :email) id)))))
        (t
         (harness-then
          (harness-chatgpt-plan--refresh record)
          (lambda (response)
            (harness-chatgpt-plan--update-account
             id (lambda (r) (harness-chatgpt-plan--accept-refresh r response))))
          (lambda (err) (harness-chatgpt-plan--on-refresh-failure record err)))))))))

(defun harness-chatgpt-plan-access-token (&optional account)
  "Return a promise of a valid access token for ACCOUNT, refreshing it if needed.
ACCOUNT names an account, or nil for the active one.  The promise
resolves to a plist `(:account ID :label LABEL :token TOKEN
:client-id ID :base-url URL :plan-usage BOOL)', where `:token' is the
bearer credential for the Responses API and nothing else.  It rejects
with a message that names no token when no account is signed in, when
the refresh token was refused (the account then has to be signed in
again), and when refreshing fails for any other reason.

Refreshes are serialized per account, here and across processes: a
caller that asks while one runs waits for its result instead of
starting a second one, which a rotating refresh token does not forgive."
  (let* ((id (or (plist-get (harness-chatgpt-plan-account account) :id)
                 (plist-get (harness-chatgpt-plan-credentials) :active)))
         (record (and id (harness-chatgpt-plan--valid-record id))))
    (cond
     ((null record)
      (harness-rejected
       (list 'harness-error
             (if id
                 (format "The ChatGPT account %s has to be signed in again: run M-x harness-chatgpt-plan-sign-in"
                         (or (plist-get (harness-chatgpt-plan-account id) :email) id))
               "No ChatGPT account is signed in: run M-x harness-chatgpt-plan-sign-in"))))
     ((not (harness-chatgpt-plan--token-needed-p record))
      (harness-resolved (harness-chatgpt-plan--token-info record)))
     (t
      (let ((in-flight (gethash id harness-chatgpt-plan--refreshes)))
        (if in-flight
            (harness-then in-flight #'harness-chatgpt-plan--token-info)
          (let ((refresh (harness-then (harness-chatgpt-plan--refresh-now id)
                                       #'harness-chatgpt-plan--token-info)))
            (puthash id refresh harness-chatgpt-plan--refreshes)
            (harness-finally refresh (lambda () (remhash id harness-chatgpt-plan--refreshes)))
            refresh)))))))

(defun harness-chatgpt-plan--token-info (record)
  "Return RECORD as `harness-chatgpt-plan-access-token' resolves it."
  (list :account (plist-get record :id)
        :label (or (plist-get record :email) (plist-get record :label) (plist-get record :id))
        :token (plist-get record :access-token)
        :client-id (plist-get record :client-id)
        :base-url harness-chatgpt-plan-api-base
        :plan-usage (harness-chatgpt-plan--plan-usage-p record)))

;;;; Signing out

(defun harness-chatgpt-plan--discovery ()
  "Return a promise of the provider's discovery document, a plist.
It is asked for at most once an hour; the `revocation_endpoint' is
read out of it when signing out."
  (let ((cached (plist-get harness-chatgpt-plan--discovery :document)))
    (if (and cached (< (- (float-time) (plist-get harness-chatgpt-plan--discovery :fetched)) 3600))
        (harness-resolved cached)
      (harness-then
       (harness-http-request-json (harness-chatgpt-plan--url harness-chatgpt-plan-discovery-path)
                                  :timeout 30)
       (lambda (document)
         (setq harness-chatgpt-plan--discovery (list :fetched (float-time) :document document))
         document)))))

(defun harness-chatgpt-plan--revoke (record)
  "Revoke RECORD's renewable session; return a promise.
The `revocation_endpoint' is read from the discovery document, and the
refresh token is revoked with `token_type_hint=refresh_token' and the
issued client id.  An empty 200 is success, including for a token that
was already invalid.  A discovery document without an endpoint, or a
failure of the request, rejects: the caller then says that the remote
revocation was not confirmed."
  (let ((token (harness-chatgpt-plan--token-string (plist-get record :refresh-token))))
    (if (null token)
        (harness-rejected (list 'harness-error "there is no refresh token to revoke"))
      (harness-then
       (harness-chatgpt-plan--discovery)
       (lambda (document)
         (let ((endpoint (plist-get document :revocation_endpoint)))
           (if (not (and (stringp endpoint) (not (string-empty-p endpoint))))
               (harness-rejected
                (list 'harness-error "the authorization server names no revocation endpoint"))
             (harness-chatgpt-plan--post-form
              endpoint
              (list (cons "token" token) (cons "token_type_hint" "refresh_token")
                    (cons "client_id" (plist-get record :client-id)))))))))))

(defun harness-chatgpt-plan-sign-out (&optional account)
  "Sign ACCOUNT out of ChatGPT; return a promise of the status left.
ACCOUNT names an account, or nil for the active one.  Its renewable
session is revoked at the authorization server, then its access, refresh
and id tokens are cleared; its identity, its issued client id and this
host's id stay, so signing in again reuses them.  A revocation that
cannot be confirmed is reported in the resolved plist as
`:revocation \"not confirmed: ...\"', and the tokens are cleared all the
same, as the documentation asks: the user can disconnect the app in
ChatGPT settings either way."
  (interactive)
  (let ((record (harness-chatgpt-plan-account account)))
    (cond
     ((null record)
      (harness-rejected (list 'harness-error "No ChatGPT account is signed in")))
     (t
      (let ((id (plist-get record :id)))
        (harness-finally
         (harness-catch
          (harness-chatgpt-plan--revoke record)
          (lambda (err)
            (harness-log 'warn "chatgpt-plan: revoking the session of %s failed: %s"
                         id (harness-error-message err))
            (harness-resolved (list :revocation
                                    (format "not confirmed: %s" (harness-error-message err))))))
         (lambda ()
           (harness-chatgpt-plan--update-account
            id (lambda (r) (harness-chatgpt-plan--clear-tokens r)))
           (harness-chatgpt-plan--announce))))))))

(defun harness-chatgpt-plan-sign-out-sync (&optional account)
  "Sign ACCOUNT out and wait for it; return what signing out resolved with.
This is what the command uses, which has nothing to do until it is over."
  (harness-await (harness-chatgpt-plan-sign-out account) 60))

;;;; Commands

(defun harness-chatgpt-plan--message (format-string &rest args)
  "Show FORMAT-STRING with ARGS in the echo area, unless nothing may be shown.
A harness process with no frame of its own logs instead."
  (let ((text (apply #'format format-string args)))
    (if (or noninteractive (null (frame-list)))
        (harness-log 'info "chatgpt-plan: %s" text)
      (message "%s" text))))

;;;###autoload
(defun harness-chatgpt-plan-sign-in-interactive ()
  "Sign in to ChatGPT, or sign another account in.
The browser is opened at OpenAI's authorization page; the account
being signed in registers this harness on first use, and later
sign-ins of the same account reuse what was issued.  Nothing is sent
anywhere else, and no API key is involved."
  (interactive)
  (let ((promise (harness-chatgpt-plan-sign-in)))
    (harness-chatgpt-plan--message
     "Opening the browser to sign in to ChatGPT; waiting up to %ds for the callback"
     harness-chatgpt-plan-sign-in-timeout)
    (harness-then
     promise
     (lambda (status)
       (harness-chatgpt-plan--message
        "%s"
        (if (plist-get status :plan-usage)
            (format "Signed in to ChatGPT as %s; the plan may pay for inference"
                    (plist-get (car (plist-get status :accounts)) :label))
          (format "Signed in to ChatGPT as %s, but the grant cannot use the plan: sign in again and allow it"
                  (plist-get (car (plist-get status :accounts)) :label)))))
     (lambda (err) (harness-chatgpt-plan--message "ChatGPT sign-in failed: %s"
                                                   (harness-error-message err))))))

;;;###autoload
(defun harness-chatgpt-plan-sign-out-interactive (&optional account)
  "Sign ACCOUNT out of ChatGPT (the active one by default) and revoke its session."
  (interactive)
  (harness-chatgpt-plan--message "Signing out of ChatGPT...")
  (let ((result (condition-case err (harness-chatgpt-plan-sign-out-sync account)
                  (error (harness-log 'warn "chatgpt-plan: signing out failed: %s"
                                      (harness-error-message err))
                         (list :error (harness-error-message err))))))
    (harness-chatgpt-plan--message
     "%s" (or (plist-get result :error)
              (let ((note (plist-get result :revocation)))
                (if (stringp note)
                    (format "Signed out locally; the remote revocation was %s" note)
                  "Signed out of ChatGPT; the session was revoked"))))))

;;;###autoload
(defun harness-chatgpt-plan-status-interactive ()
  "Show which ChatGPT accounts are signed in and whether their plans may pay."
  (interactive)
  (let ((status (harness-chatgpt-plan-status)))
    (if (null (plist-get status :accounts))
        (harness-chatgpt-plan--message
         "No ChatGPT account is signed in (credentials would be in %s)" (plist-get status :file))
      (harness-chatgpt-plan--message
       "%s"
       (mapconcat (lambda (account)
                    (format "%s: %s" (plist-get account :label)
                            (cond ((plist-get account :needs-sign-in) "must be signed in again")
                                  ((not (plist-get account :signed-in)) "no usable token")
                                  ((plist-get account :plan-usage) "plan available")
                                  (t "signed in, but the plan may not pay"))))
                    (plist-get status :accounts) "; ")))))

;;;; The bus

(harness-declare-event 'chatgpt-plan/accounts-changed
                       "(STATUS) after the signed-in ChatGPT accounts change.
STATUS is what `chatgpt-plan/status' returns, without any token.  The
provider of harness-provider-responses.el listens so that a sign-in or a
sign-out registers or removes it at once.")

(harness-defmethod chatgpt-plan/status (&optional account)
  "Return what is known about the signed-in ChatGPT accounts, without a token.
See `harness-chatgpt-plan-status'; ACCOUNT lists only that one."
  (harness-chatgpt-plan-status account))

(harness-defmethod chatgpt-plan/sign-in (&optional account)
  "Sign in to ChatGPT; return a promise of the status of the account.
See `harness-chatgpt-plan-sign-in'."
  (harness-chatgpt-plan-sign-in account))

(harness-defmethod chatgpt-plan/sign-out (&optional account)
  "Sign ACCOUNT out of ChatGPT and revoke its session; return a promise.
See `harness-chatgpt-plan-sign-out'."
  (harness-chatgpt-plan-sign-out account))

(harness-defmethod chatgpt-plan/access-token (&optional account)
  "Return a promise of a valid ChatGPT access token for ACCOUNT.
See `harness-chatgpt-plan-access-token'."
  (harness-chatgpt-plan-access-token account))

(defun harness-chatgpt-plan--init ()
  "Register the credentials of the accounts already signed in as secrets.
Doing it again at every reload is harmless: a source already registered
is left as it is."
  (harness-chatgpt-plan--register-secrets))

(harness-define-module 'chatgpt-plan
  :doc "Sign in with ChatGPT: OAuth for open-source clients, credentials and refreshing."
  :requires nil
  :init #'harness-chatgpt-plan--init)

(provide 'harness-chatgpt-plan)
;;; harness-chatgpt-plan.el ends here
