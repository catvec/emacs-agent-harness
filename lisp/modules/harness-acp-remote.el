;;; harness-acp-remote.el --- ACP for phones and other devices, signed in with a session secret  -*- lexical-binding: t; -*-

;;; Commentary:

;; The ACP server of harness-acp.el listens on this machine only.  This
;; module lets a phone (or any other device) on the network drive the
;; harness with an ACP client of its own.
;;
;; ACP gives a remote client no field to put a password in, but it does
;; say where signing in happens: the agent lists `authMethods' in its
;; answer to `initialize', the client shows them to its user, and the one
;; chosen is sent to `authenticate', which the agent answers once it has
;; signed the user in itself (ACP UI does this in a dialog of its own,
;; when `session/new' says authentication is required).  So a device
;; signs in without leaving its ACP client, and that is the way here.
;; docs/remote-auth.md has the research and its sources.
;;
;; - One listener (`harness-acp-remote-host', `harness-acp-remote-port')
;;   speaks ACP over WebSocket (`ws://ADDRESS:PORT/acp'), the transport
;;   ACP's draft for remote agents asks of clients, and also ACP's own
;;   line framing for clients that use plain TCP.  It is off until the
;;   user turns it on (`harness-acp-remote').
;; - A connection that has no session may call `initialize' (answered
;;   with what any ACP agent says of itself and the methods below, and
;;   nothing of the harness) and `authenticate'.  Anything else is ACP's
;;   `auth_required' (-32000), and nothing the harness sends to its
;;   clients, nor any request it makes of them, reaches the connection.
;; - "Approve in Emacs" is the method for a device in your hand: it asks
;;   the person at this Emacs, who compares a short code with the one the
;;   client shows, and presses Approve.  Nothing to type, nothing to copy.
;; - OpenID Connect (authentik, say) is the method for when nobody is at
;;   this Emacs: the browser of the device signs in at the provider
;;   (`/login'), and the connection waiting for it is signed in.
;; - A session secret (`hs1_…', 256 random bits) is what a device that can
;;   keep one presents the next time, as `Authorization: Bearer', as the
;;   WebSocket subprotocol `bearer.SECRET' or as `?token=', so that it
;;   needs no approval again.  The harness's own app is handed one when it
;;   signs in; any other client signs in again each time it connects,
;;   unless it is given a secret to keep (`acp/remote-create-token').  The
;;   secret is checked on every request, and again on every ACP message:
;;   a session that was revoked or ended stops its device at once.  Only
;;   its SHA-256 is kept, with the device's name and times, in the state
;;   directory.  The device's network address is shown and never trusted.
;; - Nothing else answers without a session secret: `GET /' and the rest
;;   get a bare 401.  `/login' and `/oidc/callback' each need a sign-in at
;;   the provider to do anything.
;; - `logout' (ACP's, announced as `agentCapabilities.auth.logout' to a
;;   client that has a session) and `DELETE /session' end the session.
;; - Corporate mode (`harness-corporate-mode') refuses all of it.
;;
;; The connection is not encrypted by this module: Emacs has no TLS
;; server.  Serve it over a VPN such as Tailscale, or put a TLS proxy in
;; front and set `harness-acp-remote-public-url'.
;;
;; The WebSocket protocol (RFC 6455) is implemented here on strings:
;; Emacs has no WebSocket server.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)
(require 'url-parse)
(require 'harness-core)
(require 'harness-util)
(require 'harness-acp)
(require 'harness-policy)

(declare-function harness-http-request "harness-http")

;;;; WebSocket: bytes

(defconst harness-acp-remote--ws-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  "The GUID RFC 6455 appends to a client's key to make the accept value.")

(defconst harness-acp-remote--ws-opcodes
  '((continuation . 0) (text . 1) (binary . 2) (close . 8) (ping . 9) (pong . 10))
  "WebSocket frame opcodes by name.")

(defconst harness-acp-remote-max-header 16384
  "Most bytes an HTTP request's header block may take before it is refused.")

(defun harness-acp-remote--unibyte (string)
  "Return STRING as a unibyte string of its bytes.
A multibyte string of raw bytes, as a process filter with `binary'
coding may deliver, keeps its bytes; one with characters is encoded as
UTF-8."
  (cond ((not (multibyte-string-p string)) string)
        ((condition-case nil (string-to-unibyte string) (error nil)))
        (t (encode-coding-string string 'utf-8 t))))

(defun harness-acp-remote--mask (data key)
  "Return the unibyte DATA masked (or unmasked) with the 4-byte KEY."
  (let* ((n (length data))
         (out (make-string n 0))
         (k0 (aref key 0)) (k1 (aref key 1)) (k2 (aref key 2)) (k3 (aref key 3))
         (i 0))
    (while (< i n)
      (aset out i (logxor (aref data i)
                          (pcase (logand i 3) (0 k0) (1 k1) (2 k2) (_ k3))))
      (setq i (1+ i)))
    out))

;;;; WebSocket: the opening handshake

(defun harness-acp-remote-ws-accept-key (key)
  "Return the Sec-WebSocket-Accept value answering the client's KEY."
  (base64-encode-string (secure-hash 'sha1 (concat key harness-acp-remote--ws-guid) nil nil t)))

(defun harness-acp-remote--parse-query (query)
  "Return QUERY, the part of a target after `?', as ((NAME . VALUE) ...)."
  (let (out)
    (dolist (pair (split-string query "&" t) (nreverse out))
      (let* ((eq (string-search "=" pair))
             (name (if eq (substring pair 0 eq) pair))
             (value (if eq (substring pair (1+ eq)) "")))
        (push (cons (decode-coding-string (url-unhex-string name) 'utf-8)
                    (decode-coding-string (url-unhex-string value) 'utf-8))
              out)))))

(defun harness-acp-remote--header-line (line)
  "Return (NAME . VALUE) for the header LINE, NAME downcased; nil when malformed."
  (when (string-match "\\`\\([!#$%&'*+.^_`|~0-9A-Za-z-]+\\):[ \t]*\\(.*?\\)[ \t]*\\'" line)
    (cons (downcase (match-string 1 line)) (match-string 2 line))))

(defun harness-acp-remote-parse-request (bytes)
  "Parse the HTTP request at the start of BYTES, a unibyte string.
Return nil while the header block has not ended yet; (:error 431)
once more than `harness-acp-remote-max-header' bytes came without its
end; (:error 400) when the request line is malformed.  Otherwise
return (:method M :target T :path P :query ((NAME . VALUE) ...)
:version V :headers ((NAME . VALUE) ...) :rest BYTES), header names
downcased, query names and values percent-decoded, and REST the bytes
after the header block."
  (let ((end (string-search "\r\n\r\n" bytes)))
    (cond
     ((null end) (and (> (length bytes) harness-acp-remote-max-header) (list :error 431)))
     ((> end harness-acp-remote-max-header) (list :error 431))
     (t
      (let* ((lines (split-string (substring bytes 0 end) "\r\n"))
             (request-line (car lines)))
        (if (not (string-match "\\`\\([A-Z]+\\) \\([^ ]+\\) \\(HTTP/[0-9]\\.[0-9]\\)\\'" request-line))
            (list :error 400)
          (let* ((target (match-string 2 request-line))
                 (q (string-search "?" target)))
            (list :method (match-string 1 request-line)
                  :target target
                  :path (if q (substring target 0 q) target)
                  :query (and q (harness-acp-remote--parse-query (substring target (1+ q))))
                  :version (match-string 3 request-line)
                  :headers (delq nil (mapcar #'harness-acp-remote--header-line (cdr lines)))
                  :rest (substring bytes (+ end 4))))))))))

(defun harness-acp-remote-header (request name)
  "Return the value of header NAME in REQUEST, or nil.
Several headers of that name are joined with commas, as HTTP allows."
  (let ((values (cl-loop for (n . v) in (plist-get request :headers)
                         when (string= n (downcase name)) collect v)))
    (and values (string-join values ", "))))

(defun harness-acp-remote--tokens (value)
  "Return the comma-separated tokens of header VALUE, trimmed, in order."
  (and value (cl-remove-if #'string-empty-p (mapcar #'string-trim (split-string value ",")))))

(defun harness-acp-remote-ws-upgrade-p (request)
  "Non-nil when REQUEST asks to open a WebSocket (RFC 6455 §4.2.1)."
  (let ((key (harness-acp-remote-header request "sec-websocket-key")))
    (and (equal (plist-get request :method) "GET")
         (member "websocket" (mapcar #'downcase (harness-acp-remote--tokens
                                                 (harness-acp-remote-header request "upgrade"))))
         (member "upgrade" (mapcar #'downcase (harness-acp-remote--tokens
                                               (harness-acp-remote-header request "connection"))))
         (equal "13" (string-trim (or (harness-acp-remote-header request "sec-websocket-version") "")))
         key (not (string-empty-p (string-trim key)))
         t)))

(defun harness-acp-remote-ws-offered-protocols (request)
  "Return the WebSocket subprotocols REQUEST offers, in order."
  (harness-acp-remote--tokens (harness-acp-remote-header request "sec-websocket-protocol")))

(defun harness-acp-remote-ws-handshake (request &optional protocol extra-headers)
  "Return the 101 response accepting the WebSocket REQUEST asks for.
PROTOCOL is the subprotocol chosen, or nil; EXTRA-HEADERS an alist of
\(NAME . VALUE) to add."
  (concat "HTTP/1.1 101 Switching Protocols\r\n"
          "Upgrade: websocket\r\n"
          "Connection: Upgrade\r\n"
          "Sec-WebSocket-Accept: "
          (harness-acp-remote-ws-accept-key
           (string-trim (harness-acp-remote-header request "sec-websocket-key")))
          "\r\n"
          (if protocol (format "Sec-WebSocket-Protocol: %s\r\n" protocol) "")
          (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) extra-headers "")
          "\r\n"))

;;;; WebSocket: frames out

(defun harness-acp-remote--ws-opcode (opcode)
  "Return the number of OPCODE, a number or a name of an opcode."
  (cond ((integerp opcode) opcode)
        ((alist-get opcode harness-acp-remote--ws-opcodes))
        (t (error "Unknown WebSocket opcode %S" opcode))))

(defun harness-acp-remote-ws-frame (opcode payload &optional mask-key)
  "Return the bytes of one final WebSocket frame of OPCODE carrying PAYLOAD.
OPCODE is text, binary, close, ping, pong, continuation or a number.
A multibyte PAYLOAD is sent as UTF-8.  A server sends frames unmasked;
a client passes MASK-KEY, 4 bytes, to mask its frame."
  (let* ((op (harness-acp-remote--ws-opcode opcode))
         (data (harness-acp-remote--unibyte (or payload "")))
         (len (length data))
         (mask (if mask-key #x80 0))
         (header (cond
                  ((< len 126) (unibyte-string (logior #x80 op) (logior mask len)))
                  ((< len 65536) (unibyte-string (logior #x80 op) (logior mask 126)
                                                 (ash len -8) (logand len 255)))
                  (t (apply #'unibyte-string (logior #x80 op) (logior mask 127)
                            (cl-loop for shift from 56 downto 0 by 8
                                     collect (logand (ash len (- shift)) 255)))))))
    (if mask-key
        (concat header mask-key (harness-acp-remote--mask data mask-key))
      (concat header data))))

(defun harness-acp-remote-ws-close-frame (code &optional reason)
  "Return a WebSocket close frame with the status CODE and REASON.
REASON is cut, between two characters, to fit the 125 bytes of a
control frame."
  (let* ((bytes (harness-acp-remote--unibyte (or reason "")))
         (cut (min (length bytes) 123)))
    ;; Never cut inside a UTF-8 sequence: back off continuation bytes.
    (while (and (< cut (length bytes)) (> cut 0) (= #x80 (logand (aref bytes cut) #xc0)))
      (setq cut (1- cut)))
    (harness-acp-remote-ws-frame 'close (concat (unibyte-string (ash code -8) (logand code 255))
                                                (substring bytes 0 cut)))))

;;;; WebSocket: frames in

(cl-defstruct (harness-acp-remote-decoder (:constructor harness-acp-remote--make-decoder)
                                          (:copier nil))
  "The state of one incoming WebSocket stream."
  buffer                                ; unibyte buffer of the bytes not decoded yet
  require-mask max-message
  (state 'open)                         ; open, failed or freed
  message                               ; opcode of the fragmented message in progress
  parts                                 ; its payloads so far, newest first
  (size 0))                             ; their total size

(cl-defun harness-acp-remote-decoder (&key (require-mask t) (max-message (* 64 1024 1024)))
  "Return a decoder for the bytes of one WebSocket stream.
REQUIRE-MASK, the default, refuses unmasked frames, as a server must.
A message longer than MAX-MESSAGE bytes is refused with status 1009.
The decoder keeps the bytes it waits on in a unibyte buffer, so a
message of several megabytes arriving in small chunks costs linear
time; free it with `harness-acp-remote-decoder-free'."
  (let ((buffer (generate-new-buffer " *harness-acp-remote-ws*" t)))
    (with-current-buffer buffer (set-buffer-multibyte nil))
    (harness-acp-remote--make-decoder :buffer buffer :require-mask require-mask
                                      :max-message max-message)))

(defun harness-acp-remote-decoder-free (decoder)
  "Release DECODER's buffer.  Decoding with it afterwards signals an error."
  (let ((buffer (harness-acp-remote-decoder-buffer decoder)))
    (when (buffer-live-p buffer) (kill-buffer buffer)))
  (setf (harness-acp-remote-decoder-state decoder) 'freed
        (harness-acp-remote-decoder-parts decoder) nil))

(defun harness-acp-remote--ws-fail (decoder code message)
  "Mark DECODER failed with close status CODE and MESSAGE; return the error event."
  (setf (harness-acp-remote-decoder-state decoder) 'failed
        (harness-acp-remote-decoder-parts decoder) nil)
  (erase-buffer)
  (list (cons 'error (cons code message))))

(defun harness-acp-remote--integer (start count)
  "Return the big-endian integer of the COUNT bytes at START in this buffer."
  (let ((n 0))
    (dotimes (i count)
      (setq n (logior (ash n 8) (char-after (+ start i)))))
    n))

(defun harness-acp-remote--ws-message (decoder op payload)
  "Return the event of the whole message of opcode OP whose bytes are PAYLOAD.
The fragments DECODER gathered are forgotten."
  (setf (harness-acp-remote-decoder-message decoder) nil
        (harness-acp-remote-decoder-parts decoder) nil
        (harness-acp-remote-decoder-size decoder) 0)
  (if (= op 1)
      (cons 'text (decode-coding-string payload 'utf-8))
    (cons 'binary payload)))

(defun harness-acp-remote--ws-control (decoder op payload)
  "Return the events of DECODER's control frame of opcode OP with PAYLOAD."
  (pcase op
    (9 (list (cons 'ping payload)))
    (10 (list (cons 'pong payload)))
    (_ (cond
        ((= (length payload) 0) (list (cons 'close (cons nil ""))))
        ((= (length payload) 1)
         (harness-acp-remote--ws-fail decoder 1002 "close frame with a one-byte payload"))
        (t (list (cons 'close (cons (logior (ash (aref payload 0) 8) (aref payload 1))
                                    (decode-coding-string (substring payload 2) 'utf-8)))))))))

(defun harness-acp-remote--ws-next (decoder)
  "Decode the frame at the start of the current buffer, DECODER's.
Return `incomplete' while its bytes have not all arrived, else the
list of events it gives, possibly empty, its bytes deleted.  A frame
breaking the rules of RFC 6455 §5 fails DECODER; a message announced
longer than allowed fails it before its bytes are kept."
  (let ((avail (- (point-max) (point-min)))
        (beg (point-min)))
    (if (< avail 2)
        'incomplete
      (let* ((b0 (char-after beg))
             (b1 (char-after (1+ beg)))
             (fin (/= 0 (logand b0 #x80)))
             (op (logand b0 #x0f))
             (masked (/= 0 (logand b1 #x80)))
             (len7 (logand b1 #x7f))
             (ext (pcase len7 (126 2) (127 8) (_ 0)))
             (message (harness-acp-remote-decoder-message decoder)))
        (if (< avail (+ 2 ext))
            'incomplete
          (let ((len (if (= ext 0) len7 (harness-acp-remote--integer (+ beg 2) ext))))
            (cond
             ((/= 0 (logand b0 #x70)) (harness-acp-remote--ws-fail decoder 1002 "reserved bits set"))
             ((not (memq op '(0 1 2 8 9 10)))
              (harness-acp-remote--ws-fail decoder 1002 (format "unknown opcode %d" op)))
             ((and (harness-acp-remote-decoder-require-mask decoder) (not masked))
              (harness-acp-remote--ws-fail decoder 1002 "client frames must be masked"))
             ((and (= ext 8) (/= 0 (logand (char-after (+ beg 2)) #x80)))
              (harness-acp-remote--ws-fail decoder 1002 "frame length out of range"))
             ((and (>= op 8) (or (not fin) (> len 125)))
              (harness-acp-remote--ws-fail decoder 1002 "control frames are final and at most 125 bytes"))
             ((and (= op 0) (null message))
              (harness-acp-remote--ws-fail decoder 1002 "continuation frame without a message"))
             ((and (memq op '(1 2)) message)
              (harness-acp-remote--ws-fail decoder 1002 "new message inside a fragmented one"))
             ((and (< op 8) (> (+ (harness-acp-remote-decoder-size decoder) len)
                               (harness-acp-remote-decoder-max-message decoder)))
              (harness-acp-remote--ws-fail decoder 1009 "message too big"))
             ((< avail (+ 2 ext (if masked 4 0) len)) 'incomplete)
             (t
              (let* ((key-start (+ beg 2 ext))
                     (start (+ key-start (if masked 4 0)))
                     (payload (buffer-substring-no-properties start (+ start len))))
                (when masked
                  (setq payload (harness-acp-remote--mask
                                 payload (buffer-substring-no-properties key-start start))))
                (delete-region beg (+ start len))
                (cond
                 ((>= op 8) (harness-acp-remote--ws-control decoder op payload))
                 ((and fin (/= op 0)) (list (harness-acp-remote--ws-message decoder op payload)))
                 (t
                  (unless message (setf (harness-acp-remote-decoder-message decoder) op))
                  (push payload (harness-acp-remote-decoder-parts decoder))
                  (cl-incf (harness-acp-remote-decoder-size decoder) len)
                  (when fin
                    (let ((whole (apply #'concat (nreverse (harness-acp-remote-decoder-parts decoder)))))
                      (list (harness-acp-remote--ws-message
                             decoder (harness-acp-remote-decoder-message decoder) whole)))))))))))))))

(defun harness-acp-remote-decode (decoder chunk)
  "Feed CHUNK, bytes of DECODER's stream, and return the events it completes.
Events, in order: (text . STRING) a whole text message, decoded;
\(binary . BYTES); (ping . BYTES); (pong . BYTES); (close CODE . REASON),
CODE nil when the frame had no status; (error CODE . MESSAGE) a
protocol violation, CODE the close status to send back, after which
DECODER gives nothing more."
  (pcase (harness-acp-remote-decoder-state decoder)
    ('freed (error "The WebSocket decoder of harness-acp-remote was freed"))
    ('failed nil)
    (_
     (with-current-buffer (harness-acp-remote-decoder-buffer decoder)
       (goto-char (point-max))
       (insert (harness-acp-remote--unibyte chunk))
       (let (events done)
         (while (not done)
           (let ((got (harness-acp-remote--ws-next decoder)))
             (if (eq got 'incomplete)
                 (setq done t)
               (setq events (nconc events got))
               (when (eq (harness-acp-remote-decoder-state decoder) 'failed)
                 (setq done t)))))
         events)))))


;;;; Customisation

(defcustom harness-acp-remote nil
  "Non-nil serves ACP to phones and other devices on the network.
The harness then listens on `harness-acp-remote-host' and
`harness-acp-remote-port' for ACP over WebSocket (and ACP's own line
framing).  A device signs in from its ACP client, by an approval in
Emacs or an OpenID Connect login, or presents a session secret it was
given.  The remote control page (`harness-remote-control') turns it on
and off.  Corporate mode refuses it."
  :type 'boolean :group 'harness)

(defcustom harness-acp-remote-host "0.0.0.0"
  "Address the listener for other devices binds; \"0.0.0.0\" is every IPv4 interface."
  :type 'string :group 'harness)

(defcustom harness-acp-remote-port 4276
  "TCP port of the listener for other devices.
A fixed port lets a phone's ACP client keep the address it saved
across restarts of the harness."
  :type 'integer :group 'harness)

(defcustom harness-acp-remote-address nil
  "Address of this machine that the ACP address and sign-in links carry, or nil.
nil picks one: that of a local network interface (Wi-Fi, Ethernet),
else of a VPN such as Tailscale.  Set it when other devices reach this
machine at another address."
  :type '(choice (const :tag "Detect" nil) string) :group 'harness)

(defcustom harness-acp-remote-public-url nil
  "URL that other devices reach this harness at, or nil.
Set it when something in front of the listener answers for it: a TLS
proxy (Caddy, nginx, Tailscale Serve), say, which gives devices
`https://' and `wss://' and lets the listener bind 127.0.0.1.  The ACP
address and the OpenID Connect links then carry it.
nil means http://ADDRESS:PORT of this machine (see
`harness-acp-remote-address'), which nothing encrypts."
  :type '(choice (const :tag "This machine's own address" nil) string) :group 'harness)

(defcustom harness-acp-remote-approval t
  "Non-nil lets a device ask to be signed in by an approval in Emacs.
The ACP client of the device shows \"Approve in Emacs\" among its
sign-in methods; choosing it asks the person at this Emacs, who sees
what device asks and a code that must match the one the client shows.
Turn it off on a harness nobody watches: there nobody could approve."
  :type 'boolean :group 'harness)

(defcustom harness-acp-remote-approval-timeout 50
  "Seconds a device's request to sign in waits to be approved in Emacs.
ACP UI gives up on `authenticate' after 60 seconds, so more than that
cannot be waited for."
  :type 'integer :group 'harness)

(defcustom harness-acp-remote-idle-timeout (* 30 24 3600)
  "Seconds a device may leave its session unused before it must pair again.
A session in use, or with a connection open, does not run out."
  :type 'integer :group 'harness)
(harness-renew-default 'harness-acp-remote-idle-timeout (* 8 3600))

(defcustom harness-acp-remote-session-lifetime (* 90 24 3600)
  "Seconds after which a session secret ends however it is used.
Counted from when the secret was issued: at pairing, or when it was last
replaced (see `harness-acp-remote-rotate-after').  A device that takes
replacements is given a new secret long before, and pairs once; any other
must pair again after this, so a secret that leaked long ago does not
keep working for ever."
  :type 'integer :group 'harness)

(defcustom harness-acp-remote-rotate-after (* 7 24 3600)
  "Seconds after which a device that can take one gets a new session secret.
Only a client that says it can (`_harness.sessionRefresh' among its
`clientCapabilities' in `initialize') is offered a new secret, which
comes in the answer to that `initialize' as `_harness.session.token'.
The client then keeps the new secret in place of the old; the old one
stops working the moment the new one is used, or after
`harness-acp-remote-rotation-grace'.  A secret that someone else holds
too is thus useless to them soon, and a client that finds its own
refused knows the session was used elsewhere.  nil never replaces one.
Other clients keep their secret until the session ends."
  :type '(choice (const :tag "Never" nil) integer) :group 'harness)

(defcustom harness-acp-remote-rotation-grace 3600
  "Seconds the secret being replaced stays valid once the new one is issued.
A device that never got the new secret (the connection broke before it
could keep it) is thus not locked out."
  :type 'integer :group 'harness)

(defcustom harness-acp-remote-max-message (* 64 1024 1024)
  "Largest message, in bytes, a device may send."
  :type 'integer :group 'harness)

;;;; State

(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-acp-error-unauthenticated)
(defvar harness-state-directory)
(defvar harness-acp-remote--logins)     ; Below, with OpenID Connect.

(defvar harness-acp-remote--server nil "The listening process, or nil.")

(defvar harness-acp-remote--approvals nil
  "Devices waiting to be approved in Emacs, newest first.
Each is a plist (:id :code :client :name :address :origin :method :expires
:promise :timer): the promise is what the device's `authenticate' waits
for, resolved by an approval and rejected by a refusal or a timeout.")

(defvar harness-acp-remote--requests (make-hash-table :test 'equal)
  "Address -> times its devices asked to be approved lately, newest first.")

(defvar harness-acp-remote--max-requests 6
  "Approvals one address may ask for within `harness-acp-remote--request-window'.")

(defvar harness-acp-remote--request-window 60
  "Seconds `harness-acp-remote--max-requests' is counted over.")

(defvar harness-acp-remote--max-waiting 5
  "Devices that may wait to be approved at once.")

(defvar harness-acp-remote--max-preauth 16
  "Connections that have no session at once; more are refused.")

(defvar harness-acp-remote--max-preauth-per-address 4
  "Connections of one address that have no session at once.")

(defvar harness-acp-remote--preauth-timeout 120
  "Seconds a connection may go without a session, counted from its start or
its last `authenticate', before it is closed.")

(defvar harness-acp-remote--sessions nil
  "Signed-in devices, newest first.
Each is a plist (:id :hash :name :agent :address :method :subject
:created :seen :rotated :previous-hash :previous-until): :hash is the
SHA-256 of its session secret, which is kept nowhere else; :method says
how it signed in (pairing, shared-secret or oidc), :subject who the
OpenID provider said it was, :address where it connected from last
\(shown, never trusted).  :created is when the device signed in and
:rotated when the current secret was issued (the same, until it is
replaced), which is what `harness-acp-remote-session-lifetime' counts
from; :previous-hash is the hash of the secret it replaced, good until
:previous-until.")

(defvar harness-acp-remote--sessions-loaded nil
  "Non-nil once the sessions saved by an earlier run were read.")

(defvar harness-acp-remote--save-timer nil "Timer that writes the sessions soon, or nil.")

(defvar harness-acp-remote--sweep-timer nil
  "Timer that drops the connections of sessions that ended, or nil.")

(defvar harness-acp-remote--failures (make-hash-table :test 'equal)
  "Address -> (COUNT . SINCE): secrets and codes refused from it lately.")

(defvar harness-acp-remote--max-failures 5
  "Refused secrets or codes after which an address waits.")

(defvar harness-acp-remote--failure-window 60
  "Seconds an address waits after `harness-acp-remote--max-failures' refusals.")

(defvar harness-acp-remote--request-timeout 30
  "Seconds a connection may take to send its request before it is closed.")

(defvar harness-acp-remote--max-connections 64
  "Most connections from other devices at once; more are closed at once.")

(defvar harness-acp-remote-max-body 8192
  "Most bytes an HTTP request's body may take before it is refused.")

(defconst harness-acp-remote--virtual-interfaces
  "\\`\\(?:docker\\|br-\\|veth\\|virbr\\|vnet\\|lxc\\|lxd\\|cni\\|flannel\\|podman\\|vmnet\\|vboxnet\\|kube\\)"
  "Interfaces of containers and virtual machines, whose addresses no phone reaches.")

(harness-declare-event 'acp/remote-changed
                       "(PLIST) when serving other devices changed: (:what WHAT :address A).
WHAT is started, stopped, connected, disconnected, paired, revoked,
expired, address or corporate.")

(defun harness-acp-remote--changed (what &optional address)
  "Announce WHAT happened, about ADDRESS when given."
  (harness-emit 'acp/remote-changed (list :what what :address address)))

;;;; Addresses

(defun harness-acp-remote--address-of (proc)
  "Return the address the peer of socket PROC connects from, as text."
  (let ((contact (process-contact proc :remote)))
    (cond
     ;; An IPv4 peer of an IPv6 socket: ::ffff:a.b.c.d.
     ((and (vectorp contact) (= (length contact) 9)
           (cl-every #'zerop (append (substring contact 0 5) nil))
           (= (aref contact 5) #xffff))
      (format "%d.%d.%d.%d" (ash (aref contact 6) -8) (logand (aref contact 6) 255)
              (ash (aref contact 7) -8) (logand (aref contact 7) 255)))
     ((vectorp contact) (format-network-address contact t))
     ((stringp contact) contact)
     (t "unknown"))))

(defun harness-acp-remote--loopback-p (address)
  "Non-nil when ADDRESS belongs to this machine's loopback interface."
  (or (string-prefix-p "127." address)
      (member address '("::1" "0:0:0:0:0:0:0:1" "localhost"))))

(defun harness-acp-remote--private-p (vec)
  "Non-nil when the IPv4 address VEC lies in a private range."
  (let ((a (aref vec 0)) (b (aref vec 1)))
    (or (= a 10) (and (= a 172) (<= 16 b 31)) (and (= a 192) (= b 168)))))

(defun harness-acp-remote--candidates ()
  "Return this machine's addresses other devices may reach, best first.
Each is (:address A :interface NAME :kind K), K being lan for a local
network, vpn for Tailscale and the like, other for the rest.  Loopback,
link-local and container or virtual machine interfaces are left out."
  (let (out)
    (dolist (iface (ignore-errors (network-interface-list nil 'ipv4)))
      (let* ((name (car iface))
             (vec (cdr iface))
             (address (format-network-address vec t)))
        (unless (or (harness-acp-remote--loopback-p address)
                    (string-prefix-p "169.254." address)
                    (string-match-p harness-acp-remote--virtual-interfaces name))
          (push (list :address address :interface name
                      :kind (cond ((or (string-match-p "\\`\\(?:tailscale\\|tun\\|tap\\|wg\\|zt\\|utun\\)" name)
                                       (and (= (aref vec 0) 100) (<= 64 (aref vec 1) 127)))
                                   "vpn")
                                  ((harness-acp-remote--private-p vec) "lan")
                                  (t "other")))
                out))))
    (let ((rank (lambda (c) (pcase (plist-get c :kind) ("lan" 0) ("vpn" 1) (_ 2)))))
      (sort (nreverse out) (lambda (a b) (< (funcall rank a) (funcall rank b)))))))

(defun harness-acp-remote--advertised-address ()
  "Return the address pairing links carry: see `harness-acp-remote-address'."
  (or (and (stringp harness-acp-remote-address)
           (not (string-blank-p harness-acp-remote-address))
           (string-trim harness-acp-remote-address))
      (and (stringp harness-acp-remote-host)
           (not (member harness-acp-remote-host '("0.0.0.0" "::" "")))
           harness-acp-remote-host)
      (plist-get (car (harness-acp-remote--candidates)) :address)
      "127.0.0.1"))

(defun harness-acp-remote--running-p ()
  "Non-nil while the listener for other devices runs."
  (and harness-acp-remote--server (process-live-p harness-acp-remote--server)))

(defun harness-acp-remote--port ()
  "Return the port the listener has, else the one it would take."
  (if (harness-acp-remote--running-p)
      (process-contact harness-acp-remote--server :service)
    harness-acp-remote-port))

(defun harness-acp-remote--authority ()
  "Return ADDRESS:PORT of the listener as other devices reach it."
  (let ((address (harness-acp-remote--advertised-address)))
    (format (if (string-search ":" address) "[%s]:%s" "%s:%s") address (harness-acp-remote--port))))

(defun harness-acp-remote--public-url ()
  "Return `harness-acp-remote-public-url' without a trailing slash, or nil."
  (let ((url (and (stringp harness-acp-remote-public-url) (string-trim harness-acp-remote-public-url))))
    (and url (string-match-p "\\`https?://[^/[:space:]]+" url)
         (string-remove-suffix "/" url))))

(defun harness-acp-remote--base-url ()
  "Return the URL the pages and the ACP address of the listener hang from."
  (or (harness-acp-remote--public-url)
      (concat "http://" (harness-acp-remote--authority))))

(defun harness-acp-remote--ws-url ()
  "Return the address an ACP client on another device connects to."
  (let ((base (harness-acp-remote--base-url)))
    (concat (if (string-prefix-p "https://" base) "wss://" "ws://")
            (substring base (if (string-prefix-p "https://" base) 8 7))
            "/acp")))

(defun harness-acp-remote--secure-p ()
  "Non-nil when what devices send travels encrypted on its way here.
That is so behind an https `harness-acp-remote-public-url', and over a
VPN address (Tailscale, WireGuard); a local network is not."
  (or (let ((url (harness-acp-remote--public-url)))
        (and url (string-prefix-p "https://" url)))
      (equal "vpn"
             (plist-get (cl-find (harness-acp-remote--advertised-address)
                                 (harness-acp-remote--candidates)
                                 :key (lambda (c) (plist-get c :address)) :test #'equal)
                        :kind))))

;;;; Secrets

;; A session secret is 256 random bits, `hs1_' and 43 characters of
;; base64url: long enough that nothing guesses it, and a prefix that
;; secret scanners and people can tell.  Only its SHA-256 is kept, which
;; needs no slow hash: there is nothing to brute-force in 256 random bits.

(defconst harness-acp-remote--secret-prefix "hs1_"
  "What every session secret starts with.")

(defun harness-acp-remote--random-bytes (n)
  "Return N random bytes: from /dev/urandom when it can be read."
  (or (condition-case nil
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally "/dev/urandom" nil 0 n)
            (and (= (buffer-size) n) (buffer-string)))
        (error nil))
      ;; No such device (Windows): OpenSSL's, then whatever this Emacs can gather.
      (and (executable-find "openssl")
           (condition-case nil
               (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (let ((coding-system-for-read 'binary))
                   (when (eq 0 (call-process "openssl" nil t nil "rand" (number-to-string n)))
                     (and (= (buffer-size) n) (buffer-string)))))
             (error nil)))
      (progn
        (harness-log 'warn "acp-remote: no system source of random bytes; secrets are weaker than they should be")
        (substring (secure-hash 'sha512 (format "%s %s %s %s %s" (random t) (float-time) (emacs-pid)
                                               (current-time) (list (garbage-collect)))
                                nil nil t)
                   0 n))))

(defun harness-acp-remote--new-secret ()
  "Return a new session secret."
  (concat harness-acp-remote--secret-prefix
          (base64url-encode-string (harness-acp-remote--random-bytes 32) t)))

(defun harness-acp-remote--hash (secret)
  "Return the SHA-256 of the string SECRET, as hex."
  (secure-hash 'sha256 (encode-coding-string secret 'utf-8 t)))

(defun harness-acp-remote--equal-p (a b)
  "Non-nil when the strings A and B are equal.
It takes as long when they differ at the first character as at the last."
  (and (stringp a) (stringp b)
       (= (length a) (length b))
       (let ((diff 0))
         (dotimes (i (length a))
           (setq diff (logior diff (logxor (aref a i) (aref b i)))))
         (zerop diff))))

(defun harness-acp-remote--new-connection-code ()
  "Return a code of four digits for a connection that has no session.
It is shown on the device and in Emacs, so that the person approving can
tell which device asks.  No other connection waiting has the same."
  (let ((taken (delq nil (mapcar (lambda (c) (plist-get (harness-acp-client-remote-info c) :code))
                                 harness-acp--clients)))
        code)
    (while (or (null code) (member code taken))
      (let ((n 0))
        (dolist (byte (append (harness-acp-remote--random-bytes 4) nil))
          (setq n (logior (ash n 8) byte)))
        (setq code (format "%04d" (mod n 10000)))))
    code))

(defun harness-acp-remote--connection-code (client)
  "Return the code of CLIENT, a connection that has no session; make it once."
  (or (plist-get (harness-acp-client-remote-info client) :code)
      (let ((code (harness-acp-remote--new-connection-code)))
        (harness-acp-client-set-remote-info
         client (plist-put (copy-sequence (harness-acp-client-remote-info client)) :code code))
        code)))

(defun harness-acp-remote--standing-secret-p (secret)
  "Non-nil when SECRET is `harness-acp-token', which can be exchanged.
A token shorter than 16 characters is no secret worth the name and
cannot."
  (and (stringp secret) (stringp harness-acp-token)
       (>= (length harness-acp-token) 16)
       (harness-acp-remote--equal-p (harness-acp-remote--hash (string-trim secret))
                                    (harness-acp-remote--hash harness-acp-token))))

;;;; Refused secrets

(defun harness-acp-remote--throttled (address)
  "Return the seconds ADDRESS must wait before trying again, or nil.
It must after `harness-acp-remote--max-failures' secrets or codes of
its were refused within `harness-acp-remote--failure-window'."
  (when-let* ((entry (gethash address harness-acp-remote--failures)))
    (let ((left (- (+ (cdr entry) harness-acp-remote--failure-window) (float-time))))
      (cond ((<= left 0) (remhash address harness-acp-remote--failures) nil)
            ((>= (car entry) harness-acp-remote--max-failures) (ceiling left))))))

(defun harness-acp-remote--note-failure (address)
  "Note that a secret or a code from ADDRESS was refused."
  (let ((now (float-time))
        (entry (gethash address harness-acp-remote--failures)))
    (when (> (hash-table-count harness-acp-remote--failures) 512)
      (clrhash harness-acp-remote--failures))
    (puthash address
             (if (and entry (< (- now (cdr entry)) harness-acp-remote--failure-window))
                 (cons (1+ (car entry)) (cdr entry))
               (cons 1 now))
             harness-acp-remote--failures)))

;;;; Sessions

(defun harness-acp-remote--clients (&optional session-id)
  "Return the clients this module serves.
With SESSION-ID, only those of that session."
  (cl-remove-if-not (lambda (c)
                      (let ((remote (harness-acp-client-remote-info c)))
                        (and remote (plist-member remote :transport)
                             (or (null session-id) (equal (plist-get remote :session-id) session-id)))))
                    harness-acp--clients))

(defun harness-acp-remote--issued (session)
  "Return when the current secret of SESSION was issued."
  (or (plist-get session :rotated) (plist-get session :created)))

(defun harness-acp-remote--ended-p (session &optional now)
  "Non-nil when SESSION ran out.
Its secret is too old (`harness-acp-remote-session-lifetime'), or it is
unused and has no connection open."
  (let ((now (or now (float-time))))
    (or (> (- now (harness-acp-remote--issued session)) harness-acp-remote-session-lifetime)
        (and (> (- now (plist-get session :seen)) harness-acp-remote-idle-timeout)
             (null (harness-acp-remote--clients (plist-get session :id)))))))

(defun harness-acp-remote--sessions-file ()
  "Return the file the sessions are kept in."
  (expand-file-name "acp-remote-sessions.eld" harness-state-directory))

(defun harness-acp-remote--save-sessions ()
  "Write the sessions to their file, readable by this user only.
The file holds the hash of every secret and nothing that is one."
  (when harness-acp-remote--save-timer
    (cancel-timer harness-acp-remote--save-timer)
    (setq harness-acp-remote--save-timer nil))
  (condition-case err
      (let ((print-length nil) (print-level nil) (print-circle nil))
        (with-file-modes #o600
          (harness-write-file-atomically
           (harness-acp-remote--sessions-file)
           (concat ";; Devices signed in to the harness: the SHA-256 of each session secret, never the secret.\n"
                   (prin1-to-string (list :version 1
                                          :sessions (cl-remove-if (lambda (s) (plist-get s :ephemeral))
                                                                  harness-acp-remote--sessions)))
                   "\n"))))
    (error (harness-log 'warn "acp-remote: could not save the sessions: %s" (harness-error-message err)))))

(defun harness-acp-remote--save-soon ()
  "Write the sessions within a minute: a session in use is touched often."
  (unless harness-acp-remote--save-timer
    (setq harness-acp-remote--save-timer
          (run-at-time 60 nil #'harness-acp-remote--save-sessions))))

(defun harness-acp-remote--session-valid-p (session)
  "Non-nil when SESSION, read from the file, has what a session needs."
  (and (consp session)
       (stringp (plist-get session :id))
       (stringp (plist-get session :hash))
       (= 64 (length (plist-get session :hash)))
       (numberp (plist-get session :created))
       (numberp (plist-get session :seen))))

(defun harness-acp-remote--load-sessions ()
  "Read the sessions an earlier run saved, once."
  (unless harness-acp-remote--sessions-loaded
    (setq harness-acp-remote--sessions-loaded t)
    (let ((file (harness-acp-remote--sessions-file)))
      (when (file-readable-p file)
        (condition-case err
            (let* ((data (with-temp-buffer
                           (insert-file-contents file)
                           (goto-char (point-min))
                           (let ((read-circle nil)) (read (current-buffer)))))
                   (sessions (and (eq 1 (plist-get data :version))
                                  (cl-remove-if-not #'harness-acp-remote--session-valid-p
                                                    (plist-get data :sessions)))))
              (setq harness-acp-remote--sessions
                    (cl-remove-if (lambda (s) (harness-acp-remote--ended-p s)) sessions)))
          (error (harness-log 'warn "acp-remote: ignoring the saved sessions: %s"
                              (harness-error-message err))))))))

(defun harness-acp-remote--expire ()
  "Forget the sessions that ran out, and drop their connections."
  (let* ((now (float-time))
         (dead (cl-remove-if-not (lambda (s) (harness-acp-remote--ended-p s now))
                                 harness-acp-remote--sessions)))
    (when dead
      (setq harness-acp-remote--sessions
            (cl-remove-if (lambda (s) (memq s dead)) harness-acp-remote--sessions))
      (dolist (s dead)
        (dolist (c (harness-acp-remote--clients (plist-get s :id)))
          (harness-acp-drop-client c))
        (harness-log 'info "acp-remote: the session of %s ran out" (plist-get s :name)))
      (harness-acp-remote--save-soon)
      (harness-acp-remote--changed "expired"))
    dead))

(defun harness-acp-remote--session (id)
  "Return the live session ID, or nil."
  (harness-acp-remote--expire)
  (cl-find id harness-acp-remote--sessions :key (lambda (s) (plist-get s :id)) :test #'equal))

(defun harness-acp-remote--match-secret (secret)
  "Return (SESSION . WHICH) for the live session SECRET belongs to, or nil.
SECRET is a string.  WHICH is `current' for the session's secret and
`previous' for the one a rotation is replacing, which still works until
the new one is used or `harness-acp-remote-rotation-grace' passes.  Every
session is compared, whichever is the one, so how long it takes says
nothing about which."
  (when (and (stringp secret) (<= (length secret) 200)
             (string-prefix-p harness-acp-remote--secret-prefix secret))
    (harness-acp-remote--expire)
    (let ((hash (harness-acp-remote--hash secret))
          (now (float-time))
          found)
      (dolist (s harness-acp-remote--sessions)
        (when (harness-acp-remote--equal-p hash (plist-get s :hash))
          (setq found (cons s 'current)))
        (when (and (plist-get s :previous-hash)
                   (< now (or (plist-get s :previous-until) 0))
                   (harness-acp-remote--equal-p hash (plist-get s :previous-hash))
                   (null found))
          (setq found (cons s 'previous))))
      found)))

(defun harness-acp-remote--secret-match (secret)
  "Return (SESSION . WHICH) for SECRET as `harness-acp-remote--match-secret' does.
Presenting the secret a rotation issued ends the one it replaced: the
device has it, so the old one is of no use to anybody else."
  (when-let* ((match (harness-acp-remote--match-secret secret)))
    (let ((session (car match)))
      (when (and (eq (cdr match) 'current) (plist-get session :previous-hash))
        (plist-put session :previous-hash nil)
        (plist-put session :previous-until nil)
        (harness-acp-remote--save-soon)))
    match))

(defun harness-acp-remote--session-for-secret (secret)
  "Return the live session that SECRET, a string, belongs to, or nil."
  (car (harness-acp-remote--secret-match secret)))

(defun harness-acp-remote--touch (session &optional address)
  "Note that SESSION is in use, from ADDRESS when given."
  (plist-put session :seen (float-time))
  (when address (plist-put session :address address))
  (harness-acp-remote--save-soon))

(defun harness-acp-remote--device-name (agent)
  "Return a short name for the device whose client said AGENT, a User-Agent."
  (if (not (and (stringp agent) (not (string-blank-p agent))))
      "unknown device"
    (let ((os (cond ((string-match-p "iPhone" agent) "iPhone")
                    ((string-match-p "iPad" agent) "iPad")
                    ((string-match-p "Android" agent) "Android")
                    ((string-match-p "Mac OS X\\|Macintosh" agent) "Mac")
                    ((string-match-p "Windows" agent) "Windows")
                    ((string-match-p "Linux" agent) "Linux")))
          (browser (cond ((string-match-p "Edg/" agent) "Edge")
                         ((string-match-p "Firefox/\\|FxiOS/" agent) "Firefox")
                         ((string-match-p "Chrome/\\|CriOS/" agent) "Chrome")
                         ((string-match-p "Safari/" agent) "Safari"))))
      (cond ((and os browser) (format "%s · %s" os browser))
            ((or os browser))
            (t (harness-truncate-end agent 40))))))

(defun harness-acp-remote--clean-name (name fallback)
  "Return NAME as a device name: no control characters, at most 60 long.
FALLBACK is returned when nothing is left."
  (let ((clean (and (stringp name)
                    (string-trim (replace-regexp-in-string "[[:cntrl:]]+" " " name)))))
    (if (or (null clean) (string-empty-p clean))
        fallback
      (harness-truncate-end clean 60))))

(defun harness-acp-remote--mint (name agent address method &optional subject ephemeral)
  "Sign a device in: make its session, keep it, and return (SESSION . SECRET).
NAME is what the device is called, AGENT what its client said it is,
ADDRESS where it connects from and METHOD how it proved itself.  With
EPHEMERAL the secret is given to nobody: the session is its connection's
alone, and ends with it (`harness-acp-remote--end-ephemeral')."
  (let* ((secret (harness-acp-remote--new-secret))
         (now (float-time))
         (session (list :id (harness-short-id 8) :hash (harness-acp-remote--hash secret)
                        :name (harness-acp-remote--clean-name name (harness-acp-remote--device-name agent))
                        :agent agent :address address :method method :subject subject
                        :ephemeral (and ephemeral t)
                        :created now :seen now :rotated now)))
    (push session harness-acp-remote--sessions)
    (unless ephemeral (harness-acp-remote--save-sessions))
    (harness-log 'info "acp-remote: signed in %s from %s (%s)" (plist-get session :name) address method)
    (harness-acp-remote--changed "signed-in" address)
    (cons session secret)))

(defun harness-acp-remote--end-ephemeral (id)
  "Forget the session ID of a connection that is closed, if it was its own."
  (when-let* ((session (cl-find id harness-acp-remote--sessions
                                :key (lambda (s) (plist-get s :id)) :test #'equal))
              ((plist-get session :ephemeral)))
    (setq harness-acp-remote--sessions (delq session harness-acp-remote--sessions))
    (harness-acp-remote--changed "disconnected" (plist-get session :address))))

(defun harness-acp-remote--revoke (id)
  "End the session ID and close its connections; return its record, or nil."
  (when-let* ((session (cl-find id harness-acp-remote--sessions
                                :key (lambda (s) (plist-get s :id)) :test #'equal)))
    (setq harness-acp-remote--sessions (delq session harness-acp-remote--sessions))
    (dolist (client (harness-acp-remote--clients id))
      (harness-acp-drop-client client))
    (harness-acp-remote--save-sessions)
    (harness-log 'info "acp-remote: ended the session of %s" (plist-get session :name))
    (harness-acp-remote--changed "revoked" (plist-get session :address))
    session))

;;;; Signing in

;; A connection signs in when `harness-acp-remote--attach' gives it a
;; session, by one of the methods of `authenticate': a secret it already
;; holds, the shared secret `harness-acp-token' traded for a new one, an
;; approval given in Emacs, or an OpenID Connect login of its browser.

(defun harness-acp-remote--ours-p (client)
  "Non-nil when CLIENT reached the server through this module."
  (let ((remote (harness-acp-client-remote-info client)))
    (and remote (plist-member remote :transport) t)))

(defun harness-acp-remote--client-session (client)
  "Return the live session CLIENT signed in with, or nil."
  (and (harness-acp-remote--ours-p client)
       (not (harness-corporate-p))
       (when-let* ((id (plist-get (harness-acp-client-remote-info client) :session-id)))
         (harness-acp-remote--session id))))

(defun harness-acp-remote--refresh-asked-p (client)
  "Non-nil when CLIENT said in `initialize' that it can keep a session secret."
  (harness-json-true-p
   (plist-get (plist-get (harness-acp-client-capabilities client) :_harness) :sessionRefresh)))

(defun harness-acp-remote--attach (client session &optional matched-previous)
  "Make SESSION the one CLIENT is signed in with.
MATCHED-PREVIOUS is non-nil when it came in with the secret a rotation
replaced.  The connection may now send what a session may."
  (let ((proc (harness-acp-client-process client)))
    (harness-acp-client-set-remote-info
     client (plist-put (plist-put (copy-sequence (harness-acp-client-remote-info client))
                                  :session-id (plist-get session :id))
                       :matched-previous (and matched-previous t)))
    (when-let* ((decoder (and proc (process-get proc 'harness-acp-remote-decoder))))
      (setf (harness-acp-remote-decoder-max-message decoder) harness-acp-remote-max-message))
    (harness-acp-remote--touch session (plist-get (harness-acp-client-remote-info client) :address))))

(defun harness-acp-remote--session-meta (session secret)
  "Return the `_meta' of an `authenticate' answer that hands over SESSION's SECRET."
  (list :_meta (list :harness
                     (list :session (list :token secret :deviceId (plist-get session :id)
                                          :idleTimeout harness-acp-remote-idle-timeout
                                          :lifetime harness-acp-remote-session-lifetime
                                          :expires (harness-iso-time (+ (harness-acp-remote--issued session)
                                                                        harness-acp-remote-session-lifetime)))))))

(defun harness-acp-remote--client-label (client)
  "Say what CLIENT, a connection that has no session, is, for whoever approves it.
It is what the client says of itself, which proves nothing, and what its
connection shows."
  (let* ((remote (harness-acp-client-remote-info client))
         (info (harness-acp-client-info client))
         (text (lambda (value) (and (stringp value) value)))
         (app (string-trim (string-join
                            (delq nil (list (or (funcall text (plist-get info :title))
                                                (funcall text (plist-get info :name)))
                                            (funcall text (plist-get info :version))))
                            " ")))
         (device (harness-acp-remote--device-name (plist-get remote :agent))))
    (harness-acp-remote--clean-name
     (string-join (delq nil (list (and (not (string-empty-p app)) app)
                                  (and (not (equal device "unknown device")) device)))
                  " · ")
     "unknown device")))

(defun harness-acp-remote--sign-in (client method &optional subject who)
  "Sign CLIENT in by METHOD: make its session and attach it.
SUBJECT is who the OpenID provider said it was, and WHO how it names them.
Return what the answer
to `authenticate' holds besides {}: for a client that said it can keep a
secret (the harness's own app), the secret of a session that outlives the
connection; any other gets a session of its connection alone."
  (let* ((remote (harness-acp-client-remote-info client))
         (keeps (harness-acp-remote--refresh-asked-p client))
         (label (harness-acp-remote--client-label client))
         (pair (harness-acp-remote--mint (if who (format "%s · %s" who label) label)
                                         (plist-get remote :agent) (plist-get remote :address)
                                         method subject (not keeps))))
    (harness-acp-remote--attach client (car pair))
    (and keeps (harness-acp-remote--session-meta (car pair) (cdr pair)))))

(defun harness-acp-remote--authorize (client)
  "Let CLIENT in when its session is live; for `harness-acp-authorize-functions'.
Asked at every request, so a session that was revoked or ran out stops
its device at once; the session counts as in use, unless this only
decides who a message is for."
  (when-let* ((session (harness-acp-remote--client-session client)))
    (unless harness-acp--fanout (harness-acp-remote--touch session))
    t))

(defun harness-acp-remote--approval-method (client)
  "Return the ACP auth method that asks the person at this Emacs about CLIENT."
  (list :id "emacs-approval" :name "Approve in Emacs"
        :description (format "Asks the person at this harness's Emacs to approve this device. Check that Emacs shows the code %s, and press Approve there. It waits %d seconds."
                             (harness-acp-remote--connection-code client)
                             harness-acp-remote-approval-timeout)))

(defun harness-acp-remote--auth-methods (client)
  "Offer a CLIENT that has no session the ways to sign in.
For `harness-acp-auth-methods-functions'.  A client is shown these by
`initialize' and by the `auth_required' error, and picks one for
`authenticate'.  Approval in Emacs is for any client; OpenID Connect when
a provider is set up; a secret only to a client that can send it, which
plain TCP and a client that keeps one can."
  (when (and (harness-acp-remote--ours-p client)
             (not (harness-corporate-p))
             (not (harness-acp-remote--client-session client)))
    (append
     (and harness-acp-remote-approval (list (harness-acp-remote--approval-method client)))
     (harness-acp-remote--oidc-methods client)
     (and (or (equal (plist-get (harness-acp-client-remote-info client) :transport) "tcp")
              (harness-acp-remote--refresh-asked-p client))
          (list (list :id "token" :name "Session secret"
                      :description "Call authenticate with {\"methodId\": \"token\", \"token\": SECRET}: a session secret this harness gave this device, or its shared secret."))))))

(defun harness-acp-remote--refuse (message)
  "Signal ACP's `auth_required' with MESSAGE."
  (signal 'acp-error (list harness-acp-error-unauthenticated message nil)))

(defun harness-acp-remote--authenticate (client method params)
  "Sign in a CLIENT that has no session, by METHOD, the id it chose.
For `harness-acp-authenticate-functions'.  Return nil for a method that
is not this module's, else what `authenticate' answers with, or a
promise of it.  PARAMS are those of the request."
  (when (and (harness-acp-remote--ours-p client)
             (not (harness-corporate-p)))
    (harness-acp-remote--watch client)
    (pcase method
      ((or 'nil "token") (harness-acp-remote--authenticate-token client (plist-get params :token)))
      ("emacs-approval" (harness-acp-remote--request-approval client))
      ("oidc" (harness-acp-remote--await-login client))
      (_ nil))))

(defun harness-acp-remote--authenticate-token (client token)
  "Sign CLIENT in with TOKEN: a session secret, or the shared secret traded.
A token that is neither counts against the address it came from."
  (let* ((address (plist-get (harness-acp-client-remote-info client) :address))
         (wait (harness-acp-remote--throttled address))
         (match (and (not wait) (harness-acp-remote--secret-match token))))
    (cond
     (wait (harness-acp-remote--refuse (format "Too many refused secrets: wait %d s" wait)))
     (match
      (remhash address harness-acp-remote--failures)
      (harness-acp-remote--attach client (car match) (eq (cdr match) 'previous))
      t)
     ((harness-acp-remote--standing-secret-p token)
      (remhash address harness-acp-remote--failures)
      (or (harness-acp-remote--sign-in client "shared-secret") t))
     (t (harness-acp-remote--note-failure address)
        (harness-acp-remote--refuse "Invalid session secret")))))

;;;; Approval in Emacs

(defun harness-acp-remote--approval (id)
  "Return the approval ID, waiting for an answer, or nil."
  (cl-find id harness-acp-remote--approvals :key (lambda (a) (plist-get a :id)) :test #'equal))

(defun harness-acp-remote--approval-of (client)
  "Return the approval CLIENT waits on, or nil."
  (cl-find client harness-acp-remote--approvals :key (lambda (a) (plist-get a :client))))

(defun harness-acp-remote--approval-view (approval)
  "Return what the remote control page shows of APPROVAL."
  (list :id (plist-get approval :id) :code (plist-get approval :code)
        :name (plist-get approval :name) :address (plist-get approval :address)
        :origin (plist-get approval :origin) :method (plist-get approval :method)
        :expires (plist-get approval :expires)))

(defun harness-acp-remote--request-wait (address)
  "Return the seconds ADDRESS must wait before asking to be approved again, or nil."
  (let* ((now (float-time))
         (times (cl-remove-if (lambda (time) (> (- now time) harness-acp-remote--request-window))
                              (gethash address harness-acp-remote--requests))))
    (if times (puthash address times harness-acp-remote--requests) (remhash address harness-acp-remote--requests))
    (and (>= (length times) harness-acp-remote--max-requests)
         (ceiling (- (+ (car (last times)) harness-acp-remote--request-window) now)))))

(defun harness-acp-remote--note-request (address)
  "Note that a device of ADDRESS asked to be approved."
  (when (> (hash-table-count harness-acp-remote--requests) 512)
    (clrhash harness-acp-remote--requests))
  (push (float-time) (gethash address harness-acp-remote--requests)))

(defun harness-acp-remote--forget-approval (approval)
  "Stop waiting for APPROVAL, the timer included."
  (when-let* ((timer (plist-get approval :timer))) (cancel-timer timer))
  (setq harness-acp-remote--approvals (delq approval harness-acp-remote--approvals)))

(defun harness-acp-remote--approval-over (approval message)
  "End APPROVAL without a session: the device's `authenticate' fails with MESSAGE."
  (harness-acp-remote--forget-approval approval)
  (harness-reject (plist-get approval :promise)
                  (list 'acp-error harness-acp-error-unauthenticated message nil))
  (harness-acp-remote--changed "approval"))

(defun harness-acp-remote--request-approval (client)
  "Ask the person at this Emacs to approve CLIENT, which asked to sign in.
Return a promise the `authenticate' of the device waits for."
  (let* ((remote (harness-acp-client-remote-info client))
         (address (plist-get remote :address))
         (wait (harness-acp-remote--request-wait address)))
    (cond
     ((not harness-acp-remote-approval)
      (harness-acp-remote--refuse "Approval in Emacs is turned off on this harness"))
     ((harness-acp-remote--approval-of client)
      (harness-acp-remote--refuse "This device already waits to be approved"))
     (wait (harness-acp-remote--refuse (format "Too many requests from this address: wait %d seconds" wait)))
     ((>= (length harness-acp-remote--approvals) harness-acp-remote--max-waiting)
      (harness-acp-remote--refuse "Too many devices wait to be approved: try again in a minute"))
     (t
      (let* ((id (harness-short-id 6))
             (approval (list :id id :code (harness-acp-remote--connection-code client) :client client
                             :name (harness-acp-remote--client-label client) :address address
                             :origin (harness-acp-remote--clean-name (plist-get remote :origin) nil)
                             :method "approval"
                             :expires (+ (float-time) harness-acp-remote-approval-timeout)
                             :promise (harness-make-promise))))
        (plist-put approval :timer (run-at-time harness-acp-remote-approval-timeout nil
                                                (lambda ()
                                                  (when-let* ((a (harness-acp-remote--approval id)))
                                                    (harness-acp-remote--approval-over
                                                     a "Nobody approved this device in Emacs in time")))))
        (push approval harness-acp-remote--approvals)
        (harness-acp-remote--note-request address)
        (harness-log 'info "acp-remote: %s at %s asks to be approved (code %s)"
                     (plist-get approval :name) address (plist-get approval :code))
        (harness-acp-remote--announce approval)
        (plist-get approval :promise))))))

(defun harness-acp-remote--announce (approval)
  "Tell the user that a device waits for APPROVAL: the page, and a notification."
  (harness-acp-remote--changed "approval" (plist-get approval :address))
  (when (harness-method-exists-p 'notification/send)
    (condition-case err
        (harness-call 'notification/send
                      (list :title "A device asks to sign in to the harness"
                            :body (format "%s (%s%s) shows the code %s.  Approve it in Emacs only if the code is the one on your device: C-c h P."
                                          (plist-get approval :name) (plist-get approval :address)
                                          (if-let* ((origin (plist-get approval :origin)))
                                              (format ", from the page %s" origin)
                                            "")
                                          (plist-get approval :code))
                            :source "acp-remote" :kind "approval"))
      (error (harness-log 'debug "acp-remote: no notification: %s" (harness-error-message err))))))

(defun harness-acp-remote--approve (id)
  "Sign in the device whose approval is ID; return t."
  (let ((approval (or (harness-acp-remote--approval id)
                      (signal 'harness-error (list "No device waits for that approval: it may have run out of time")))))
    (let* ((client (plist-get approval :client))
           (proc (harness-acp-client-process client)))
      (harness-acp-remote--forget-approval approval)
      (unless (and (memq client harness-acp--clients) proc (process-live-p proc))
        (harness-acp-remote--changed "approval")
        (signal 'harness-error (list "The device left before it could be approved")))
      ;; A device that signed in some other way meanwhile is signed in already.
      (let ((extras (and (not (harness-acp-remote--client-session client))
                         (harness-acp-remote--sign-in client "approval"))))
        (harness-log 'info "acp-remote: approved %s at %s" (plist-get approval :name) (plist-get approval :address))
        (harness-resolve (plist-get approval :promise) (or extras t))))
    t))

(defun harness-acp-remote--deny (id)
  "Refuse the device whose approval is ID; return t."
  (let ((approval (or (harness-acp-remote--approval id)
                      (signal 'harness-error (list "No device waits for that approval: it may have run out of time")))))
    (harness-log 'info "acp-remote: refused %s at %s" (plist-get approval :name) (plist-get approval :address))
    ;; A refusal counts: whoever is refused again and again waits.
    (harness-acp-remote--note-request (plist-get approval :address))
    (harness-acp-remote--approval-over approval "The person at the harness's Emacs refused this device")
    t))

(defun harness-acp-remote--drop-approvals (client)
  "Forget what CLIENT waits for: it is gone."
  (when-let* ((approval (harness-acp-remote--approval-of client)))
    (harness-acp-remote--approval-over approval "The connection closed")))

;;;; Connections that have no session

(defconst harness-acp-remote--pre-auth-max-line 65536
  "Most bytes a client that has no session may send in one line or message.
It may send `initialize' and `authenticate' and nothing else.")

(defun harness-acp-remote--preauth-clients (&optional address)
  "Return the connections that have no session, those of ADDRESS when given."
  (cl-remove-if-not (lambda (c)
                      (and (harness-acp-remote--ours-p c)
                           (null (plist-get (harness-acp-client-remote-info c) :session-id))
                           (or (null address)
                               (equal address (plist-get (harness-acp-client-remote-info c) :address)))))
                    harness-acp--clients))

(defun harness-acp-remote--preauth-full-p (address)
  "Non-nil when a connection of ADDRESS that has no session must be refused."
  (or (>= (length (harness-acp-remote--preauth-clients)) harness-acp-remote--max-preauth)
      (>= (length (harness-acp-remote--preauth-clients address)) harness-acp-remote--max-preauth-per-address)))

(defun harness-acp-remote--watch (client)
  "Note that CLIENT, which has no session, did something to get one.
A connection that does nothing of the kind is closed in time."
  (when-let* ((proc (harness-acp-client-process client)))
    (process-put proc 'harness-acp-remote-preauth-since (float-time))))

(defun harness-acp-remote--close-idle ()
  "Close the connections that have had no session for too long."
  (let ((now (float-time)))
    (dolist (client (harness-acp-remote--preauth-clients))
      (let* ((proc (harness-acp-client-process client))
             (since (and proc (process-get proc 'harness-acp-remote-preauth-since))))
        (when (and proc (process-live-p proc) since
                   (> (- now since) harness-acp-remote--preauth-timeout))
          (harness-log 'debug "acp-remote: closing a connection of %s that never signed in"
                       (plist-get (harness-acp-client-remote-info client) :address))
          (harness-acp-remote--close proc))))))

;;;; Logout, and a secret that is replaced

(defun harness-acp-remote--capabilities (client)
  "Announce `logout' to CLIENT when it has a session to end.
For `harness-acp-agent-capabilities-functions'."
  (when (and (harness-acp-remote--ours-p client) (harness-acp-remote--client-session client))
    (list :auth (list :logout :empty))))

(defun harness-acp-remote--rotation-due-p (session client)
  "Non-nil when SESSION, which CLIENT is connected with, is due a new secret.
It is when the secret is older than `harness-acp-remote-rotate-after', and
when CLIENT came in with the secret a rotation replaced: the device never
got the new one, so it is sent another."
  (and harness-acp-remote-rotate-after
       (or (plist-get (harness-acp-client-remote-info client) :matched-previous)
           (> (- (float-time) (harness-acp-remote--issued session))
              harness-acp-remote-rotate-after))))

(defun harness-acp-remote--rotate (session)
  "Give SESSION a new secret, and return it.
The one it replaces stays good for `harness-acp-remote-rotation-grace'
seconds, or until the new one is used."
  (let ((secret (harness-acp-remote--new-secret))
        (now (float-time)))
    ;; A secret nobody used is not kept: the one the device holds is.
    (unless (plist-get session :previous-hash)
      (plist-put session :previous-hash (plist-get session :hash)))
    (plist-put session :previous-until (+ now harness-acp-remote-rotation-grace))
    (plist-put session :hash (harness-acp-remote--hash secret))
    (plist-put session :rotated now)
    (harness-acp-remote--save-sessions)
    secret))

(defun harness-acp-remote--initialize-extras (client)
  "Hand CLIENT a new session secret when it asked for one and is due it.
For `harness-acp-initialize-extras-functions': it comes in the answer to
`initialize' as `_harness.session'."
  (when-let* ((session (harness-acp-remote--client-session client))
              ((harness-acp-remote--refresh-asked-p client))
              ((harness-acp-remote--rotation-due-p session client)))
    (let ((secret (harness-acp-remote--rotate session)))
      (harness-acp-client-set-remote-info
       client (plist-put (copy-sequence (harness-acp-client-remote-info client)) :matched-previous nil))
      (harness-log 'info "acp-remote: issued %s a new session secret" (plist-get session :name))
      (list :session (list :token secret :deviceId (plist-get session :id)
                           :idleTimeout harness-acp-remote-idle-timeout
                           :lifetime harness-acp-remote-session-lifetime
                           :expires (harness-iso-time (+ (harness-acp-remote--issued session)
                                                         harness-acp-remote-session-lifetime)))))))

(harness-acp--define-standard "logout" (client _params)
  (let ((id (plist-get (harness-acp-client-remote-info client) :session-id)))
    (unless (and id (harness-acp-remote--ours-p client))
      (signal 'harness-no-such-method (list "logout")))
    ;; After the answer is out: ending the session closes the connection.
    (run-at-time 0.1 nil (lambda () (harness-acp-remote--revoke id)))
    :empty))

;;;; Connections

(defvar harness-acp-remote--write-limit 120
  "Seconds a device may leave what is sent to it unread before it is dropped.
Internal, not an option.  A phone put away stops reading without
closing its connection; everything sent to it meanwhile would pile up
behind the write that waits for it (see `harness-process-send').  A
device dropped reconnects when it wakes, and reads the sessions again.")

(defun harness-acp-remote--send (proc bytes)
  "Write BYTES to the socket PROC, if it is still open.
In line behind a write that waits for the device to read, never inside
it: a device that stopped reading must not nest every write the harness
makes meanwhile until Lisp nesting overflows."
  (when (process-live-p proc)
    (condition-case err
        (harness-process-send proc bytes harness-acp-remote--write-limit)
      (error (harness-log 'debug "acp-remote: writing to %s failed: %s"
                          (process-name proc) (harness-error-message err))))))

(defun harness-acp-remote--close (proc)
  "Close the socket PROC and drop its client."
  (process-put proc 'harness-acp-remote-state 'closing)
  (when-let* ((client (process-get proc 'harness-acp-remote-client)))
    (harness-acp-drop-client client))
  (when (process-live-p proc) (delete-process proc)))

(defun harness-acp-remote--write-ws (client text)
  "Send TEXT, a JSON-RPC message, to CLIENT as a WebSocket text frame."
  (harness-acp-remote--send (harness-acp-client-process client) (harness-acp-remote-ws-frame 'text text)))

(defun harness-acp-remote--write-line (client text)
  "Send TEXT, a JSON-RPC message, to CLIENT as one line."
  (harness-acp-remote--send (harness-acp-client-process client)
                            (concat (encode-coding-string text 'utf-8 t) "\n")))

;;;; Pages

;; The pages are small and static but for what they quote, which is
;; escaped.  Their script and style are constants and the policy that
;; comes with them names those by hash, so nothing a page quotes could
;; run: no inline handler, no other script, no frame, no form to anywhere
;; else.

(defconst harness-acp-remote--page-style
  (concat
   "body{font:17px/1.5 system-ui,sans-serif;margin:0;padding:1.5rem;color:#1d1f21;background:#fafafa}"
   "main{max-width:34rem;margin:auto}h1{font-size:1.4rem}label{display:block;margin-top:1rem;font-weight:600}"
   "input{font:inherit;width:100%;box-sizing:border-box;padding:.5rem;margin:.25rem 0}"
   ".row{display:flex;gap:.5rem;align-items:center}.row input{flex:1;min-width:0}"
   "button{font:inherit;padding:.5rem 1rem;cursor:pointer}button.primary{font-weight:600}"
   ".note{color:#666;font-size:.9rem}.warn{color:#a15c00}code{word-break:break-all}"
   "@media (prefers-color-scheme:dark){body{color:#e6e6e6;background:#1e2127}.note{color:#aaa}.warn{color:#e5a13a}"
   "input{background:#2c313c;color:#e6e6e6;border:1px solid #555}}")
  "The style of every page.")

(defconst harness-acp-remote--page-script
  (concat
   "document.addEventListener('click',function(e){"
   "var b=e.target.closest&&e.target.closest('[data-copy]');if(!b)return;"
   "var i=document.getElementById(b.getAttribute('data-copy'));if(!i)return;i.select();"
   "try{navigator.clipboard.writeText(i.value).catch(function(){document.execCommand('copy')})}"
   "catch(x){document.execCommand('copy')}});"
   "document.addEventListener('focusin',function(e){"
   "if(e.target.matches&&e.target.matches('input[readonly]'))e.target.select()});")
  "The script of every page: its Copy buttons select and copy the field they name.")

(defun harness-acp-remote--csp ()
  "Return the Content-Security-Policy of the pages."
  (format "default-src 'none'; style-src 'sha256-%s'; script-src 'sha256-%s'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
          (base64-encode-string (secure-hash 'sha256 harness-acp-remote--page-style nil nil t))
          (base64-encode-string (secure-hash 'sha256 harness-acp-remote--page-script nil nil t))))

(defun harness-acp-remote--escape (text)
  "Return TEXT escaped for HTML."
  (replace-regexp-in-string
   "[&<>\"']" (lambda (c) (pcase c ("&" "&amp;") ("<" "&lt;") (">" "&gt;") ("\"" "&quot;") (_ "&#39;")))
   (format "%s" text) t t))

(defun harness-acp-remote--page (title &rest paragraphs)
  "Return a small HTML page titled TITLE with PARAGRAPHS of HTML."
  (concat
   "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
   "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
   "<meta name=\"robots\" content=\"noindex\">"
   "<title>" (harness-acp-remote--escape title) "</title><style>"
   harness-acp-remote--page-style
   "</style></head><body><main><h1>" (harness-acp-remote--escape title) "</h1>"
   (mapconcat (lambda (p) (concat "<p>" p "</p>")) paragraphs "")
   "</main><script>" harness-acp-remote--page-script "</script></body></html>"))

(defun harness-acp-remote--copy-field (id label value)
  "Return a read-only field ID labelled LABEL holding VALUE, with a Copy button."
  (format "<label for=\"%s\">%s</label><span class=\"row\"><input id=\"%s\" readonly value=\"%s\"><button type=\"button\" data-copy=\"%s\">Copy</button></span>"
          id (harness-acp-remote--escape label) id (harness-acp-remote--escape value) id))

(defun harness-acp-remote--span (seconds)
  "Say SECONDS in words a person reads: \"30 days\", \"8 hours\", \"90 minutes\".
The largest unit it is a whole number of."
  (let ((seconds (max 1 (round seconds))))
    (catch 'span
      (dolist (unit '((86400 "day") (3600 "hour") (60 "minute") (1 "second")))
        (when (zerop (% seconds (car unit)))
          (let ((n (/ seconds (car unit))))
            (throw 'span (format "%d %s%s" n (cadr unit) (if (= n 1) "" "s")))))))))

(defun harness-acp-remote--signed-in-page (session secret)
  "Return the page a browser sees once it signed SESSION in with the provider.
SECRET is the session secret of a session that outlives it: the page
shows it once, for a client that wants one in its settings."
  (let ((ws (harness-acp-remote--ws-url)))
    (harness-acp-remote--page
     "Signed in"
     (format "This device is signed in to the Emacs Agent Harness on %s as <b>%s</b>."
             (harness-acp-remote--escape (system-name))
             (harness-acp-remote--escape (plist-get session :name)))
     "In your ACP client, add a remote agent with this address. It carries the session secret, so one paste is all it takes:"
     (harness-acp-remote--copy-field "u" "ACP address" (format "%s?token=%s" ws secret))
     "A client with a field of its own for the token takes the address and the secret apart:"
     (harness-acp-remote--copy-field "a" "Address" ws)
     (harness-acp-remote--copy-field "t" "Session secret (Authorization: Bearer)" secret)
     (format "<span class=\"warn\">This is shown once.</span> <span class=\"note\">Whoever has the secret can drive the harness until you end the session in Emacs (remote control page, C-c h P) or it goes unused for %s. %s</span>"
             (harness-acp-remote--span harness-acp-remote-idle-timeout)
             (if (harness-acp-remote--secure-p)
                 ""
               "The connection is not encrypted: use it on a network you trust, or over a VPN such as Tailscale.")))))

(defun harness-acp-remote--login-done-page (session)
  "Return the page a browser sees once it signed the connection of its app in.
SESSION is the session the app now has."
  (harness-acp-remote--page
   "Signed in"
   (format "<b>%s</b> is signed in to the Emacs Agent Harness on %s."
           (harness-acp-remote--escape (plist-get session :name))
           (harness-acp-remote--escape (system-name)))
   "You can close this page and go back to the app."))

(cl-defun harness-acp-remote--respond (proc status body &key headers (type "text/html; charset=utf-8"))
  "Answer the HTTP request on PROC with STATUS and BODY, then close.
TYPE is the Content-Type of BODY; HEADERS an alist of extra (NAME .
VALUE) header fields."
  (let ((bytes (encode-coding-string body 'utf-8 t))
        (reason (pcase status (200 "OK") (204 "No Content") (302 "Found") (400 "Bad Request")
                       (401 "Unauthorized") (403 "Forbidden") (404 "Not Found")
                       (405 "Method Not Allowed") (411 "Length Required") (413 "Payload Too Large")
                       (429 "Too Many Requests") (431 "Request Header Fields Too Large")
                       (502 "Bad Gateway") (_ "Error"))))
    (process-put proc 'harness-acp-remote-state 'closing)
    (harness-acp-remote--send
     proc (concat (encode-coding-string
                   (concat (format "HTTP/1.1 %d %s\r\n" status reason)
                           (if (eq status 204) "" (format "Content-Type: %s\r\n" type))
                           (format "Content-Length: %d\r\n" (length bytes))
                           "Connection: close\r\nCache-Control: no-store\r\n"
                           "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n"
                           "X-Frame-Options: DENY\r\n"
                           (format "Content-Security-Policy: %s\r\n" (harness-acp-remote--csp))
                           (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) headers "")
                           "\r\n")
                   'utf-8 t)
                  bytes))
    (when (process-live-p proc)
      (ignore-errors (harness-process-send-eof proc))
      (run-at-time 5 nil (lambda () (when (process-live-p proc) (delete-process proc)))))))

(defun harness-acp-remote--respond-json (proc status object &optional headers)
  "Answer the request on PROC with STATUS and OBJECT as JSON, with HEADERS besides.
Any origin may read it: it takes a session secret to ask, and no cookie
or other ambient authority is involved."
  (harness-acp-remote--respond proc status (harness-json-encode object)
                               :type "application/json"
                               :headers (append headers '(("Access-Control-Allow-Origin" . "*")))))

(defun harness-acp-remote--respond-text (proc status text &optional headers)
  "Answer the request on PROC with STATUS and the plain TEXT, with HEADERS besides."
  (harness-acp-remote--respond proc status (concat text "\n") :type "text/plain; charset=utf-8" :headers headers))

;;;; Requests

(defun harness-acp-remote--web-origin-p (origin)
  "Non-nil when ORIGIN, an Origin header, names a web page.
An app's own web view (Tauri, Capacitor, a page on localhost) is not
one; neither is a missing header, as native clients send none."
  (and origin
       (not (string-match-p "\\`\\(?:tauri\\|capacitor\\|ionic\\|app\\|file\\)://" origin))
       (not (string-match-p "\\`https?://\\(?:localhost\\|tauri\\.localhost\\|127\\.0\\.0\\.1\\)\\(?::[0-9]+\\)?\\'"
                            origin))))

(defun harness-acp-remote--request-secrets (request offered)
  "Return the secrets REQUEST holds out, from OFFERED subprotocols and elsewhere.
The `bearer.SECRET' subprotocols come first (a browser can send no
header), then `Authorization: Bearer', then the `token' of the query."
  (delq nil
        (append
         (mapcar (lambda (p) (and (string-prefix-p "bearer." p) (substring p (length "bearer."))))
                 offered)
         (list (let ((auth (harness-acp-remote-header request "authorization")))
                 (and auth (string-match "\\`[Bb]earer[ \t]+\\(.+?\\)[ \t]*\\'" auth) (match-string 1 auth)))
               (cdr (assoc "token" (plist-get request :query)))))))

(defun harness-acp-remote--request-session (request)
  "Return the live session REQUEST proves, or nil.
It proves one by a secret in the way a WebSocket does."
  (cl-some #'harness-acp-remote--session-for-secret
           (harness-acp-remote--request-secrets
            request (harness-acp-remote-ws-offered-protocols request))))

(defun harness-acp-remote--unauthorized (proc request)
  "Answer the request on PROC with a 401: it brought no live session secret.
REQUEST says whether it brought one that is no good, and whether it was
the shared secret itself, which only `authenticate' takes."
  (let* ((secrets (harness-acp-remote--request-secrets
                   request (harness-acp-remote-ws-offered-protocols request)))
         (standing (cl-some #'harness-acp-remote--standing-secret-p secrets)))
    (harness-acp-remote--respond-text
     proc 401
     (cond (standing "Not a session secret: the shared secret is traded for one by authenticate, method token.")
           (secrets "The session secret is not valid: it was revoked or ran out. Sign this device in again.")
           (t "Authentication required: send a session secret (Authorization: Bearer, the bearer.SECRET WebSocket subprotocol or ?token=), or open the WebSocket and sign in with ACP's authenticate."))
     (list (cons "WWW-Authenticate"
                 (if secrets
                     "Bearer realm=\"Emacs Agent Harness\", error=\"invalid_token\""
                   "Bearer realm=\"Emacs Agent Harness\""))))))

(defun harness-acp-remote--form-fields (request)
  "Return the fields of REQUEST's body, a form, as an alist of strings."
  (harness-acp-remote--parse-query
   (replace-regexp-in-string "\\+" " " (decode-coding-string (or (plist-get request :body) "") 'utf-8) t t)))

;;;; Session

(defun harness-acp-remote--route-session (proc request)
  "Answer the request for `/session' on PROC.
It ends the session whose secret REQUEST holds, as a WebSocket does."
  (let ((session (harness-acp-remote--request-session request)))
    (pcase (plist-get request :method)
      ("OPTIONS" (harness-acp-remote--respond
                  proc 204 "" :headers '(("Access-Control-Allow-Origin" . "*")
                                         ("Access-Control-Allow-Methods" . "DELETE, GET, OPTIONS")
                                         ("Access-Control-Allow-Headers" . "Authorization")
                                         ("Access-Control-Max-Age" . "600"))))
      (_ (cond
          ((null session) (harness-acp-remote--unauthorized proc request))
          ((equal (plist-get request :method) "DELETE")
           (harness-acp-remote--respond proc 204 "")
           (harness-acp-remote--revoke (plist-get session :id)))
          ((equal (plist-get request :method) "GET")
           (harness-acp-remote--respond-json
            proc 200 (list :deviceId (plist-get session :id) :name (plist-get session :name)
                           :issued (harness-iso-time (plist-get session :created)))))
          (t (harness-acp-remote--respond-text proc 405 "Use GET or DELETE." '(("Allow" . "GET, DELETE")))))))))

;;;; WebSocket and plain TCP

(defun harness-acp-remote--upgrade (proc request)
  "Turn the socket PROC into a WebSocket for ACP, as REQUEST asks.
A request that holds a live session secret opens a connection that is
signed in.  Any other opens one that has no session, which may only
`initialize' and `authenticate' (see the commentary): that is how ACP
lets a device sign in from its own client.  A secret that was sent and
is no good counts against the address it came from."
  (let* ((offered (harness-acp-remote-ws-offered-protocols request))
         (secrets (harness-acp-remote--request-secrets request offered))
         (match (cl-some #'harness-acp-remote--secret-match secrets))
         (session (car match))
         (address (process-get proc 'harness-acp-remote-address))
         (wait (harness-acp-remote--throttled address)))
    (cond
     (wait
      (harness-acp-remote--respond-text
       proc 429 (format "Too many refused secrets: wait %d seconds." wait)
       (list (cons "Retry-After" (number-to-string wait)))))
     ((and (null session) (harness-acp-remote--preauth-full-p address))
      (harness-acp-remote--respond-text
       proc 429 "Too many devices are signing in at once: try again in a minute."
       '(("Retry-After" . "60"))))
     (t
      (when (and secrets (null session))
        (harness-acp-remote--note-failure address))
      (let* ((protocol (or (car (member "acp.v1" offered))
                           (cl-find-if-not (lambda (p) (string-prefix-p "bearer." p)) offered)
                           (car offered)))
             (origin (harness-acp-remote-header request "origin"))
             (client (harness-acp-add-client
                      'websocket :process proc :writer #'harness-acp-remote--write-ws
                      :remote (list :address address :transport "websocket"
                                    :agent (harness-acp-remote-header request "user-agent")
                                    :origin origin
                                    :web (and (harness-acp-remote--web-origin-p origin) t)
                                    :session-id (and session (plist-get session :id))
                                    :matched-previous (and session (eq (cdr match) 'previous))))))
        (process-put proc 'harness-acp-remote-client client)
        (process-put proc 'harness-acp-remote-decoder
                     (harness-acp-remote-decoder
                      :max-message (if session harness-acp-remote-max-message
                                     harness-acp-remote--pre-auth-max-line)))
        (process-put proc 'harness-acp-remote-state 'ws)
        (process-put proc 'harness-acp-remote-preauth-since (float-time))
        (harness-acp-remote--send proc (harness-acp-remote-ws-handshake
                                        request protocol (list (cons "Acp-Connection-Id" (harness-uuid)))))
        (when session (harness-acp-remote--touch session address))
        (harness-acp-remote--changed "connected" address)
        (let ((rest (plist-get request :rest)))
          (unless (string-empty-p rest) (harness-acp-remote--ws-input proc rest))))))))

(defun harness-acp-remote--serve-lines (proc bytes)
  "Serve ACP's own line framing on the socket PROC, which sent BYTES so far.
The client has no session until it signs in with `authenticate', and is
closed if it has none in time (`harness-acp-remote--preauth-timeout'), or
at once when too many connections have none."
  (let ((address (process-get proc 'harness-acp-remote-address)))
    (if (harness-acp-remote--preauth-full-p address)
        (harness-acp-remote--close proc)
      (let ((client (harness-acp-add-client 'remote-tcp :process proc :writer #'harness-acp-remote--write-line
                                            :remote (list :address address :transport "tcp"))))
        (process-put proc 'harness-acp-remote-client client)
        (process-put proc 'harness-acp-remote-state 'lines)
        (process-put proc 'harness-acp-remote-pending "")
        (process-put proc 'harness-acp-remote-preauth-since (float-time))
        (harness-acp-remote--changed "connected" address)
        (harness-acp-remote--line-input proc bytes)))))

(defun harness-acp-remote--line-input (proc chunk)
  "Hand every complete line of CHUNK, read from PROC, to its client."
  (let ((bytes (concat (process-get proc 'harness-acp-remote-pending) (harness-acp-remote--unibyte chunk)))
        (client (process-get proc 'harness-acp-remote-client))
        (start 0)
        nl)
    (while (setq nl (string-search "\n" bytes start))
      (let ((line (string-trim (decode-coding-string (substring bytes start nl) 'utf-8))))
        (unless (string-empty-p line) (harness-acp-client-receive client line)))
      (setq start (1+ nl)))
    (if (> (- (length bytes) start)
           (if (harness-acp-remote--client-session client)
               harness-acp-remote-max-message
             harness-acp-remote--pre-auth-max-line))
        (harness-acp-remote--close proc)
      (process-put proc 'harness-acp-remote-pending (substring bytes start)))))

(defun harness-acp-remote--ws-input (proc chunk)
  "Handle CHUNK, bytes of the WebSocket on PROC."
  (let ((client (process-get proc 'harness-acp-remote-client))
        (decoder (process-get proc 'harness-acp-remote-decoder)))
    (dolist (event (harness-acp-remote-decode decoder chunk))
      (pcase event
        (`(text . ,text)
         ;; One message per frame, though some clients end it with a
         ;; newline and bridges forward several lines at once.
         (dolist (line (split-string text "\n" t "[ \t\r]+"))
           (harness-acp-client-receive client line)))
        (`(binary . ,_) (harness-log 'debug "acp-remote: binary WebSocket message ignored"))
        (`(ping . ,payload) (harness-acp-remote--send proc (harness-acp-remote-ws-frame 'pong payload)))
        (`(pong . ,_) nil)
        (`(close . ,_)
         (harness-acp-remote--send proc (harness-acp-remote-ws-close-frame 1000))
         (harness-acp-remote--close proc))
        (`(error ,code . ,message)
         (harness-log 'info "acp-remote: closing the WebSocket of %s: %s"
                      (process-get proc 'harness-acp-remote-address) message)
         (harness-acp-remote--send proc (harness-acp-remote-ws-close-frame code message))
         (harness-acp-remote--close proc))))))

;;;; Routing

(defun harness-acp-remote--route (proc request)
  "Answer the HTTP REQUEST read from PROC.
Only the sign-in at the provider answers without a session secret, to a
login at the provider; everything else is a 401 to a request that holds
none, whatever it asks for.  (A WebSocket is let in, to sign in with ACP.)"
  (let ((path (plist-get request :path))
        (method (plist-get request :method)))
    (cond
     ((harness-corporate-p)
      (harness-acp-remote--respond
       proc 403 (harness-acp-remote--page "Not available"
                                          "Corporate mode is on: this harness serves no other device.")))
     ((harness-acp-remote-ws-upgrade-p request) (harness-acp-remote--upgrade proc request))
     ((and (equal path "/login") (harness-acp-remote--oidc-configured-p))
      (harness-acp-remote--oidc-login proc request))
     ((and (equal path "/oidc/callback") (harness-acp-remote--oidc-configured-p))
      (harness-acp-remote--oidc-callback proc request))
     ((equal path "/session") (harness-acp-remote--route-session proc request))
     (t
      (let ((session (harness-acp-remote--request-session request)))
        (cond
         ((null session) (harness-acp-remote--unauthorized proc request))
         ((not (member method '("GET" "HEAD")))
          (harness-acp-remote--respond-text proc 405 "Use WebSocket." '(("Allow" . "GET"))))
         ((member path '("/" "/acp"))
          (harness-acp-remote--respond-text
           proc 200 (format "Signed in as %s. Connect an ACP client to %s with this session secret."
                            (plist-get session :name) (harness-acp-remote--ws-url))))
         (t (harness-acp-remote--respond-text proc 404 "Nothing here."))))))))

(defun harness-acp-remote--content-length (request)
  "Return the number of body bytes REQUEST announces.
`bad' when the Content-Length is not a number."
  (let ((value (harness-acp-remote-header request "content-length")))
    (cond ((null value) 0)
          ((string-match-p "\\`[0-9]\\{1,9\\}\\'" (string-trim value)) (string-to-number value))
          (t 'bad))))

(defun harness-acp-remote--head-input (proc chunk)
  "Read the start of what PROC sends: an HTTP request, or ACP lines.
CHUNK, the bytes PROC sent last, is added to the bytes it sent before.
A request with a body waits for all of it, up to `harness-acp-remote-max-body'
bytes."
  (let* ((bytes (concat (or (process-get proc 'harness-acp-remote-pending) "")
                        (harness-acp-remote--unibyte chunk)))
         (start (string-match-p "[^ \t\r\n]" bytes)))
    (process-put proc 'harness-acp-remote-pending bytes)
    (cond
     ((null start)
      (when (> (length bytes) harness-acp-remote-max-header) (harness-acp-remote--close proc)))
     ((eq (aref bytes start) ?{) (harness-acp-remote--serve-lines proc bytes))
     (t
      (let ((request (harness-acp-remote-parse-request bytes)))
        (cond
         ((null request))
         ((plist-get request :error)
          (harness-acp-remote--respond proc (plist-get request :error)
                                       (harness-acp-remote--page "Bad request" "The request could not be read.")))
         ((harness-acp-remote-header request "transfer-encoding")
          (harness-acp-remote--respond proc 411 (harness-acp-remote--page "Length required" "Send a Content-Length.")))
         (t
          (let ((need (harness-acp-remote--content-length request)))
            (cond
             ((eq need 'bad)
              (harness-acp-remote--respond proc 400 (harness-acp-remote--page "Bad request" "The Content-Length is not a number.")))
             ((> need harness-acp-remote-max-body)
              (harness-acp-remote--respond proc 413 (harness-acp-remote--page "Too big" "The request body is too big.")))
             ((< (length (plist-get request :rest)) need))
             (t
              (process-put proc 'harness-acp-remote-pending nil)
              (harness-acp-remote--route
               proc (plist-put (copy-sequence request) :body (substring (plist-get request :rest) 0 need)))))))))))))

(defun harness-acp-remote--filter (proc chunk)
  "Handle CHUNK, bytes the socket PROC received."
  (condition-case err
      (pcase (process-get proc 'harness-acp-remote-state)
        ('ws (harness-acp-remote--ws-input proc chunk))
        ('lines (harness-acp-remote--line-input proc chunk))
        ('closing nil)
        (_ (harness-acp-remote--head-input proc chunk)))
    (error (harness-log 'warn "acp-remote: %s: %s" (process-get proc 'harness-acp-remote-address)
                        (harness-error-message err))
           (harness-acp-remote--close proc))))

(defun harness-acp-remote--sentinel (proc _event)
  "Clean up after the socket PROC once it closed."
  (unless (process-live-p proc)
    (if (eq proc harness-acp-remote--server)
        (progn (setq harness-acp-remote--server nil)
               (harness-acp-remote--changed "stopped"))
      (when-let* ((timer (process-get proc 'harness-acp-remote-timer)))
        (cancel-timer timer))
      (when-let* ((decoder (process-get proc 'harness-acp-remote-decoder)))
        (process-put proc 'harness-acp-remote-decoder nil)
        (harness-acp-remote-decoder-free decoder))
      (when-let* ((client (process-get proc 'harness-acp-remote-client)))
        (process-put proc 'harness-acp-remote-client nil)
        (harness-acp-remote--drop-approvals client)
        (harness-acp-remote--drop-logins client)
        (harness-acp-drop-client client)
        (when-let* ((id (plist-get (harness-acp-client-remote-info client) :session-id))
                    (session (cl-find id harness-acp-remote--sessions
                                      :key (lambda (s) (plist-get s :id)) :test #'equal)))
          (if (plist-get session :ephemeral)
              (harness-acp-remote--end-ephemeral id)
            (harness-acp-remote--touch session)))
        (harness-acp-remote--changed "disconnected" (process-get proc 'harness-acp-remote-address))))))

(defun harness-acp-remote--connections ()
  "Return the open sockets the listener accepted."
  (cl-remove-if-not (lambda (p) (and (process-get p 'harness-acp-remote-address) (process-live-p p)))
                    (process-list)))

(defun harness-acp-remote--accept (_server proc _message)
  "Set up the socket PROC the listener just accepted.
It must send its request within `harness-acp-remote--request-timeout'
seconds, and is closed at once in corporate mode or past
`harness-acp-remote--max-connections'."
  (set-process-query-on-exit-flag proc nil)
  (set-process-coding-system proc 'binary 'binary)
  (set-process-filter proc #'harness-acp-remote--filter)
  (set-process-sentinel proc #'harness-acp-remote--sentinel)
  (process-put proc 'harness-acp-remote-address (harness-acp-remote--address-of proc))
  (cond
   ((harness-corporate-p) (delete-process proc))
   ((> (length (harness-acp-remote--connections)) harness-acp-remote--max-connections)
    (harness-log 'warn "acp-remote: too many connections; closing the one from %s"
                 (process-get proc 'harness-acp-remote-address))
    (delete-process proc))
   (t
    (process-put proc 'harness-acp-remote-timer
                 (run-at-time harness-acp-remote--request-timeout nil
                              (lambda ()
                                (when (and (process-live-p proc)
                                           (null (process-get proc 'harness-acp-remote-state)))
                                  (delete-process proc))))))))

;;;; Serving

(defun harness-acp-remote--refuse-in-corporate-mode ()
  "Signal when corporate mode is on."
  (when (harness-corporate-p)
    (signal 'harness-error (list "Corporate mode is on: the harness serves no other device"))))

(defun harness-acp-remote--sweep ()
  "Drop the connections of sessions that ended.
The sign-ins nobody finished are forgotten as well."
  (harness-acp-remote--expire)
  ;; A connection whose session ended is dropped; one that never had a
  ;; session waits to sign in, for a while.
  (dolist (client (harness-acp-remote--clients))
    (unless (or (harness-acp-remote--client-session client)
                (null (plist-get (harness-acp-client-remote-info client) :session-id)))
      (harness-acp-drop-client client)))
  (harness-acp-remote--close-idle)
  (harness-acp-remote--forget-logins))

(defun harness-acp-remote--listen ()
  "Start the listener for other devices."
  (harness-acp-remote--refuse-in-corporate-mode)
  (harness-acp-remote--load-sessions)
  (setq harness-acp-remote--server
        (make-network-process :name "harness-acp-remote" :server t
                              :host harness-acp-remote-host :service harness-acp-remote-port
                              :coding 'binary :noquery t
                              :filter #'harness-acp-remote--filter
                              :sentinel #'harness-acp-remote--sentinel
                              :log #'harness-acp-remote--accept))
  (unless harness-acp-remote--sweep-timer
    (setq harness-acp-remote--sweep-timer (run-at-time 30 30 #'harness-acp-remote--sweep)))
  (harness-log 'info "acp-remote: serving other devices on %s:%s; they connect to %s"
               harness-acp-remote-host (harness-acp-remote--port) (harness-acp-remote--ws-url)))

(defun harness-acp-remote--stop ()
  "Stop serving other devices: close the listener and their connections.
The devices waiting to be approved and the sign-ins under way are forgotten;
the sessions of devices that keep a secret are not, so they stay signed in
for the next time."
  (let ((server harness-acp-remote--server))
    (setq harness-acp-remote--server nil)
    (when (and server (process-live-p server)) (delete-process server)))
  (dolist (client (harness-acp-remote--clients))
    (harness-acp-drop-client client))
  (when harness-acp-remote--sweep-timer
    (cancel-timer harness-acp-remote--sweep-timer)
    (setq harness-acp-remote--sweep-timer nil))
  (dolist (approval (copy-sequence harness-acp-remote--approvals))
    (harness-acp-remote--approval-over approval "The harness stopped serving other devices"))
  (when harness-acp-remote--save-timer (harness-acp-remote--save-sessions))
  (setq harness-acp-remote--logins nil))

;;;; OpenID Connect

;; ACP has no OpenID Connect: its URL elicitation says it is "not a
;; substitute for authorizing the Client's access to the Agent", and no
;; client sends a token it got from a provider.  What a person's login at
;; an identity provider (authentik, Keycloak, Google ...) can do is be
;; one of the ways the agent signs a user in itself, which is what ACP's
;; `authenticate' leaves to the agent.  The method "oidc" is offered to a
;; connection with a code; the person opens `/login?c=CODE' in a browser
;; (the app does it for its user), is asked to confirm which device it
;; is, is sent to the provider, and `/oidc/callback' takes the browser
;; back.  When the provider vouches for someone
;; `harness-acp-remote-oidc-allowed' lets in, the connection that code
;; belongs to is signed in.  A `/login' without a code signs the browser
;; in and shows it a session secret, for a client that is given one by
;; hand.  The authorization code flow with PKCE, a state bound to the
;; browser by a cookie, a nonce, and an id token checked for issuer,
;; audience and expiry; it arrives from the token endpoint over TLS,
;; which OpenID Connect Core 3.1.3.7 takes in place of a signature.

(defcustom harness-acp-remote-oidc-issuer nil
  "Issuer URL of the OpenID Connect provider that may sign devices in, or nil.
nil leaves `/login' off.  For authentik it is the issuer of the
application's provider, such as
\"https://auth.example.com/application/o/harness/\".  It must be https:
the id token is trusted for coming from it over TLS."
  :type '(choice (const :tag "Off" nil) string) :group 'harness)

(defcustom harness-acp-remote-oidc-client-id nil
  "Client id the provider gave this harness, or nil.
Register the redirect URI the remote control page shows (the public URL
or ADDRESS:PORT of the listener, then /oidc/callback) with the provider."
  :type '(choice (const :tag "None" nil) string) :group 'harness)

(defcustom harness-acp-remote-oidc-client-secret nil
  "Client secret of a confidential client, a string or a function returning one.
nil for a public client, which needs none: the PKCE verifier keeps the
code from being used by anyone else.  A public client is the better choice,
since there is no secret to keep."
  :type '(choice (const :tag "None (public client)" nil) string function) :group 'harness)

(defcustom harness-acp-remote-oidc-scopes '("openid" "profile" "email")
  "Scopes asked of the provider; \"openid\" must be among them."
  :type '(repeat string) :group 'harness)

(defcustom harness-acp-remote-oidc-allowed nil
  "Who the provider may sign in.
A list of strings, each matched, ignoring case, against the e-mail address
\(only when the provider says it is verified), the `preferred_username' and
the `sub' of the id token, and every entry of its `groups'.  nil lets
nobody in; t lets in everyone the provider authenticates, which is for a
provider that limits the application itself (authentik's policy bindings
do)."
  :type '(choice (const :tag "Nobody" nil)
                 (const :tag "Anyone the provider lets in" t)
                 (repeat :tag "These e-mail addresses, users and groups" string))
  :group 'harness)

(defvar harness-acp-remote--logins nil
  "Sign-ins sent to the provider and not finished.
Each is a plist (:state :nonce :verifier :browser :expires), and :client
when it signs a connection in, which it waits for.")

(defvar harness-acp-remote--login-waits nil
  "Connections that were told to sign in at the provider, newest first.
Each is a plist (:client :expires), with :promise and :timer while its
`authenticate' waits, and :subject and :who once the provider vouched
for someone allowed, which a later `authenticate' then finds.")

(defconst harness-acp-remote--login-wait-lifetime 300
  "Seconds a sign-in at the provider may take, and then keeps for the connection.")

(defconst harness-acp-remote--login-timeout 55
  "Seconds an `authenticate' by the provider's login waits: ACP UI gives up at 60.")

(defvar harness-acp-remote--oidc-config nil
  "The provider's discovery document, kept for an hour.
A plist (:for ISSUER :fetched TIME :issuer :authorization :token :userinfo).")

(defconst harness-acp-remote--login-lifetime 600
  "Seconds a person has to finish a sign-in at the provider.")

(defun harness-acp-remote--oidc-configured-p ()
  "Non-nil when `/login' can send a browser to a provider."
  (and (not (harness-corporate-p))
       (stringp harness-acp-remote-oidc-issuer)
       (not (string-blank-p harness-acp-remote-oidc-issuer))
       (stringp harness-acp-remote-oidc-client-id)
       (not (string-blank-p harness-acp-remote-oidc-client-id))))

(defun harness-acp-remote--oidc-redirect-uri ()
  "Return the address the provider sends the browser back to."
  (concat (harness-acp-remote--base-url) "/oidc/callback"))

(defun harness-acp-remote--oidc-login-url ()
  "Return the address a device opens to sign in with the provider, or nil."
  (and (harness-acp-remote--oidc-configured-p)
       (concat (harness-acp-remote--base-url) "/login")))

(defun harness-acp-remote--oidc-url-ok-p (url)
  "Non-nil when URL may be spoken to.
That is https, or http on this machine (a test provider), and it holds
no control character or space: it ends up in a header and in a request."
  (and (stringp url)
       (not (string-match-p "[[:cntrl:][:space:]]" url))
       (or (string-prefix-p "https://" url)
           (string-match-p "\\`http://\\(?:127\\.0\\.0\\.1\\|localhost\\|\\[::1\\]\\)\\(?::[0-9]+\\)?/" url))))

(defun harness-acp-remote--b64url (bytes)
  "Return the unibyte BYTES in base64url without padding."
  (base64url-encode-string bytes t))

(defun harness-acp-remote--form-encode (alist)
  "Return ALIST of (NAME . VALUE) strings as a form body.
The body is application/x-www-form-urlencoded."
  (mapconcat (lambda (cell)
               (concat (url-hexify-string (car cell)) "=" (url-hexify-string (cdr cell))))
             alist "&"))

(defun harness-acp-remote--forget-logins ()
  "Forget the sign-ins that nobody finished in time."
  (let ((now (float-time)))
    (setq harness-acp-remote--logins
          (cl-remove-if (lambda (l) (< (plist-get l :expires) now)) harness-acp-remote--logins))
    (dolist (wait (copy-sequence harness-acp-remote--login-waits))
      (when (< (plist-get wait :expires) now)
        (harness-acp-remote--forget-login-wait wait "The sign-in at the provider took too long")))))

(defun harness-acp-remote--oidc-discover (callback)
  "Call CALLBACK with the provider's configuration.
On failure it gets nil and what went wrong.  The configuration is kept
for an hour."
  (let ((issuer (string-remove-suffix "/" (string-trim harness-acp-remote-oidc-issuer)))
        (cached harness-acp-remote--oidc-config))
    (cond
     ((and cached (equal (plist-get cached :for) issuer)
           (< (- (float-time) (plist-get cached :fetched)) 3600))
      (funcall callback cached nil))
     ((not (harness-acp-remote--oidc-url-ok-p (concat issuer "/")))
      (funcall callback nil "The issuer must be an https:// URL"))
     (t
      (require 'harness-http)
      (harness-http-request
       (concat issuer "/.well-known/openid-configuration")
       :headers '(("Accept" . "application/json")) :timeout 20
       :callback
       (lambda (status _headers body err)
         (let* ((doc (and (not err) (eql status 200)
                          (condition-case nil (harness-json-parse body) (error nil))))
                (config (and (consp doc)
                             (list :for issuer :fetched (float-time)
                                   :issuer (plist-get doc :issuer)
                                   :authorization (plist-get doc :authorization_endpoint)
                                   :token (plist-get doc :token_endpoint)
                                   ;; The access token goes there: not over plain http.
                                   :userinfo (let ((url (plist-get doc :userinfo_endpoint)))
                                               (and (harness-acp-remote--oidc-url-ok-p url) url))))))
           (cond
            ((null config)
             (funcall callback nil (format "The provider's configuration could not be read (%s)"
                                           (or (and err (harness-error-message err)) status))))
            ((not (equal (string-remove-suffix "/" (or (plist-get config :issuer) "")) issuer))
             (funcall callback nil "The provider names another issuer than the one configured"))
            ((not (and (harness-acp-remote--oidc-url-ok-p (plist-get config :authorization))
                       (harness-acp-remote--oidc-url-ok-p (plist-get config :token))))
             (funcall callback nil "The provider's endpoints are not https URLs"))
            (t (setq harness-acp-remote--oidc-config config)
               (funcall callback config nil))))))))))

(defun harness-acp-remote--cookie (request name)
  "Return the value of cookie NAME in REQUEST, or nil."
  (when-let* ((header (harness-acp-remote-header request "cookie")))
    (cl-some (lambda (part)
               (let ((cell (string-trim part)))
                 (and (string-prefix-p (concat name "=") cell)
                      (substring cell (1+ (length name))))))
             (split-string header ";" t))))

(defun harness-acp-remote--waiting-client (code)
  "Return the connection that has no session and shows CODE, or nil."
  (and (stringp code)
       (cl-find-if (lambda (c) (equal code (plist-get (harness-acp-client-remote-info c) :code)))
                   (harness-acp-remote--preauth-clients))))

(defun harness-acp-remote--oidc-methods (client)
  "Return the auth methods that sign CLIENT in at the provider.
CLIENT has no session.  Nothing when no provider is set up, or nobody is
allowed to use it."
  (when (and (harness-acp-remote--oidc-configured-p) harness-acp-remote-oidc-allowed)
    (let* ((code (harness-acp-remote--connection-code client))
           (url (format "%s/login?c=%s" (harness-acp-remote--base-url) code))
           (host (or (ignore-errors (url-host (url-generic-parse-url harness-acp-remote-oidc-issuer)))
                     "the provider")))
      (list (list :id "oidc" :name (format "Sign in with %s" host)
                  :description (format "Open %s in a browser, sign in, and confirm the code %s. This connection signs in once you have."
                                       url code)
                  :_meta (list :harness (list :url url)))))))

(defun harness-acp-remote--oidc-login (proc request)
  "Answer the browser on PROC, which asked REQUEST for `/login'.
With `c', the code of a connection that waits to sign in, it is asked to
confirm which device that is first; without, it signs in for itself."
  (let ((address (process-get proc 'harness-acp-remote-address))
        (method (plist-get request :method)))
    (harness-acp-remote--forget-logins)
    (cond
     ((not (member method '("GET" "POST")))
      (harness-acp-remote--respond-text proc 405 "Use GET." '(("Allow" . "GET, POST"))))
     ((null harness-acp-remote-oidc-allowed)
      ;; Deny by default: no round trip to the provider to be refused after it.
      (harness-acp-remote--respond
       proc 403 (harness-acp-remote--page
                 "Not set up"
                 "OpenID Connect sign-in is on, but nobody is allowed to use it yet: the owner of this harness sets `harness-acp-remote-oidc-allowed'.")))
     ((harness-acp-remote--throttled address)
      (harness-acp-remote--respond proc 429 (harness-acp-remote--page "Too many tries" "Wait a minute and try again.")))
     ((> (length harness-acp-remote--logins) 20)
      (harness-acp-remote--respond proc 429 (harness-acp-remote--page "Too many sign-ins" "Wait a few minutes and try again.")))
     ((equal method "POST") (harness-acp-remote--oidc-confirmed proc request))
     ((cdr (assoc "c" (plist-get request :query)))
      (harness-acp-remote--oidc-confirm proc (cdr (assoc "c" (plist-get request :query)))))
     (t (harness-acp-remote--oidc-start proc nil)))))

(defun harness-acp-remote--oidc-confirm (proc code)
  "Ask the browser on PROC to confirm that the device that shows CODE is its own.
Signing a device in at the provider is what whoever opens a link can make
a person do; so the person is told which device it is, and presses a
button that only this page has, before the provider is asked anything."
  (let ((client (harness-acp-remote--waiting-client code)))
    (if (null client)
        (harness-acp-remote--respond
         proc 404 (harness-acp-remote--page
                   "Nothing waits for this code"
                   "No device waits to sign in with that code. It may have timed out: start again in the app."))
      (let ((token (harness-acp-remote--b64url (harness-acp-remote--random-bytes 24)))
            (remote (harness-acp-client-remote-info client)))
        (harness-acp-remote--respond
         proc 200
         (harness-acp-remote--page
          "Sign in a device"
          (format "A device asks to be signed in to the harness on %s with your account at the provider: <b>%s</b>, connecting from %s, showing the code <b>%s</b>."
                  (harness-acp-remote--escape (system-name))
                  (harness-acp-remote--escape (harness-acp-remote--client-label client))
                  (harness-acp-remote--escape (plist-get remote :address))
                  (harness-acp-remote--escape code))
          "Continue only if that is your device and it shows that code."
          (format "<form method=\"post\" action=\"/login\"><input type=\"hidden\" name=\"c\" value=\"%s\"><input type=\"hidden\" name=\"t\" value=\"%s\"><button class=\"primary\" type=\"submit\">Continue to the provider</button></form>"
                  (harness-acp-remote--escape code) token))
         :headers (list (cons "Set-Cookie" (format "harness_confirm=%s; Path=/login; HttpOnly; SameSite=Strict; Max-Age=%d%s"
                                                   token harness-acp-remote--login-lifetime
                                                   (if (string-prefix-p "https://" (harness-acp-remote--base-url))
                                                       "; Secure" "")))))))))

(defun harness-acp-remote--oidc-confirmed (proc request)
  "Send the browser on PROC to the provider for the device it confirmed in REQUEST."
  (let* ((fields (harness-acp-remote--form-fields request))
         (token (cdr (assoc "t" fields)))
         (cookie (harness-acp-remote--cookie request "harness_confirm"))
         (client (harness-acp-remote--waiting-client (cdr (assoc "c" fields)))))
    (cond
     ((not (and (stringp token) (not (string-empty-p token)) cookie
                (harness-acp-remote--equal-p (harness-acp-remote--hash token) (harness-acp-remote--hash cookie))))
      (harness-acp-remote--note-failure (process-get proc 'harness-acp-remote-address))
      (harness-acp-remote--oidc-failure proc 400 "This page was not opened in this browser. Start again from the app."))
     ((null client)
      (harness-acp-remote--oidc-failure proc 404 "That device does not wait to sign in any more. Start again in the app."))
     (t (harness-acp-remote--oidc-start proc client)))))

(defun harness-acp-remote--oidc-start (proc client)
  "Send the browser on PROC to the provider.
CLIENT, when given, is the connection its sign-in is for."
  (harness-acp-remote--oidc-discover
   (lambda (config why)
     (if (null config)
         (harness-acp-remote--respond
          proc 502 (harness-acp-remote--page "Sign-in unavailable" (harness-acp-remote--escape why)))
       (let* ((state (harness-acp-remote--b64url (harness-acp-remote--random-bytes 24)))
              (nonce (harness-acp-remote--b64url (harness-acp-remote--random-bytes 24)))
              (verifier (harness-acp-remote--b64url (harness-acp-remote--random-bytes 32)))
              (browser (harness-acp-remote--b64url (harness-acp-remote--random-bytes 24)))
              (challenge (harness-acp-remote--b64url (secure-hash 'sha256 verifier nil nil t)))
              (url (concat (plist-get config :authorization)
                           (if (string-search "?" (plist-get config :authorization)) "&" "?")
                           (harness-acp-remote--form-encode
                            `(("response_type" . "code")
                              ("client_id" . ,harness-acp-remote-oidc-client-id)
                              ("redirect_uri" . ,(harness-acp-remote--oidc-redirect-uri))
                              ("scope" . ,(string-join harness-acp-remote-oidc-scopes " "))
                              ("state" . ,state) ("nonce" . ,nonce)
                              ("code_challenge" . ,challenge)
                              ("code_challenge_method" . "S256"))))))
         (push (list :state state :nonce nonce :verifier verifier :client client
                     :browser (harness-acp-remote--hash browser)
                     :expires (+ (float-time) harness-acp-remote--login-lifetime))
               harness-acp-remote--logins)
         (let ((secure (if (string-prefix-p "https://" (harness-acp-remote--base-url)) "; Secure" "")))
           (harness-acp-remote--respond
            proc 302 ""
            :headers (list (cons "Location" url)
                           (cons "Set-Cookie"
                                 (format "harness_login=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d%s"
                                         browser harness-acp-remote--login-lifetime secure))
                           ;; The confirmation is used up.
                           (cons "Set-Cookie" (format "harness_confirm=; Path=/login; Max-Age=0%s" secure))))))))))

;;;; Connections that wait for a sign-in at the provider

(defun harness-acp-remote--login-wait (client)
  "Return the record of CLIENT's wait for the provider, made when it has none."
  (or (cl-find client harness-acp-remote--login-waits :key (lambda (w) (plist-get w :client)))
      (let ((wait (list :client client
                        :expires (+ (float-time) harness-acp-remote--login-wait-lifetime))))
        (push wait harness-acp-remote--login-waits)
        wait)))

(defun harness-acp-remote--forget-login-wait (wait &optional why)
  "Forget WAIT; its `authenticate', if it waits, fails with WHY, text."
  (when-let* ((timer (plist-get wait :timer))) (cancel-timer timer))
  (setq harness-acp-remote--login-waits (delq wait harness-acp-remote--login-waits))
  (when-let* ((promise (plist-get wait :promise)))
    (plist-put wait :promise nil)
    (harness-reject promise (list 'acp-error harness-acp-error-unauthenticated
                                  (or why "The sign-in at the provider was not finished") nil))))

(defun harness-acp-remote--finish-login (wait)
  "Sign in the connection of WAIT, whom the provider vouched for.
Return what its `authenticate' answers with."
  (let* ((client (plist-get wait :client))
         (promise (plist-get wait :promise))
         (extras (and (not (harness-acp-remote--client-session client))
                      (harness-acp-remote--sign-in client "oidc" (plist-get wait :subject) (plist-get wait :who)))))
    (when-let* ((timer (plist-get wait :timer))) (cancel-timer timer))
    (setq harness-acp-remote--login-waits (delq wait harness-acp-remote--login-waits))
    (plist-put wait :promise nil)
    (when promise (harness-resolve promise (or extras t)))
    (or extras t)))

(defun harness-acp-remote--await-login (client)
  "Answer CLIENT's `authenticate' by the provider's login: when it was done.
It is, or waits a while for the person to finish at the provider."
  (let ((wait (harness-acp-remote--login-wait client)))
    (cond
     ((plist-get wait :subject) (harness-acp-remote--finish-login wait))
     ((plist-get wait :promise)
      (harness-acp-remote--refuse "This connection already waits for the sign-in at the provider"))
     (t
      (let ((promise (harness-make-promise)))
        (plist-put wait :promise promise)
        (plist-put wait :timer
                   (run-at-time harness-acp-remote--login-timeout nil
                                (lambda ()
                                  (when (eq (plist-get wait :promise) promise)
                                    (plist-put wait :promise nil)
                                    (plist-put wait :timer nil)
                                    (harness-reject promise
                                                    (list 'acp-error harness-acp-error-unauthenticated
                                                          "The sign-in at the provider was not finished in time: finish it, then choose this method again."
                                                          nil))))))
        promise)))))

(defun harness-acp-remote--drop-logins (client)
  "Forget what CLIENT, which is gone, waited for at the provider."
  (when-let* ((wait (cl-find client harness-acp-remote--login-waits :key (lambda (w) (plist-get w :client)))))
    (harness-acp-remote--forget-login-wait wait "The connection closed")))

(defun harness-acp-remote--oidc-claims (token)
  "Return the claims of the id token TOKEN, a JWT, as a plist.
Nil when it is not one.  The signature is not checked here: the token
came from the token endpoint over TLS (see the commentary above)."
  (let ((parts (and (stringp token) (split-string token "\\."))))
    (when (= (length parts) 3)
      (condition-case nil
          (let ((claims (harness-json-parse
                         (decode-coding-string (base64-decode-string (nth 1 parts) t) 'utf-8))))
            (and (consp claims) (keywordp (car claims)) claims))
        (error nil)))))

(defun harness-acp-remote--oidc-claims-problem (claims nonce issuer)
  "Return why the id token CLAIMS cannot be trusted for NONCE and ISSUER, or nil."
  (let* ((now (float-time))
         (aud (plist-get claims :aud))
         (auds (if (stringp aud) (list aud) (and (listp aud) aud)))
         (exp (plist-get claims :exp))
         (iat (plist-get claims :iat)))
    (cond
     ((not (equal (string-remove-suffix "/" (or (plist-get claims :iss) "")) issuer))
      "The id token comes from another issuer")
     ((not (member harness-acp-remote-oidc-client-id auds))
      "The id token is for another client")
     ((and (cdr auds) (not (equal (plist-get claims :azp) harness-acp-remote-oidc-client-id)))
      "The id token was issued to another party")
     ((not (numberp exp)) "The id token has no expiry")
     ((< exp (- now 60)) "The id token has expired")
     ((and (numberp iat) (> iat (+ now 300))) "The id token is from the future")
     ((not (equal (plist-get claims :nonce) nonce)) "The id token answers another sign-in")
     ((let ((sub (plist-get claims :sub))) (or (not (stringp sub)) (string-empty-p sub)))
      "The id token names no subject"))))

(defun harness-acp-remote--email-verified-p (claims)
  "Non-nil when the provider says the e-mail address of CLAIMS is verified.
OpenID Connect makes `email_verified' optional, and some providers send
the text \"true\": anything but a plain yes counts as no, for an address a
user could type in themselves proves nobody."
  (and (member (plist-get claims :email_verified) '(t "true")) t))

(defun harness-acp-remote--oidc-allowed-p (claims)
  "Non-nil when `harness-acp-remote-oidc-allowed' lets CLAIMS in.
CLAIMS are those of the id token, describing who signed in."
  (pcase harness-acp-remote-oidc-allowed
    ('t t)
    ((pred consp)
     (let ((names (delq nil
                        (append
                         (and (stringp (plist-get claims :email))
                              (harness-acp-remote--email-verified-p claims)
                              (list (plist-get claims :email)))
                         (list (plist-get claims :preferred_username) (plist-get claims :sub))
                         (let ((groups (plist-get claims :groups)))
                           (if (stringp groups) (list groups) (and (listp groups) groups)))))))
       (cl-some (lambda (allowed)
                  (cl-some (lambda (name) (and (stringp name) (string-equal-ignore-case allowed name))) names))
                harness-acp-remote-oidc-allowed)))
    (_ nil)))

(defun harness-acp-remote--oidc-failure (proc status text)
  "Answer the browser on PROC that the sign-in failed with STATUS: TEXT says why."
  (when (process-live-p proc)
    (harness-acp-remote--respond
     proc status
     (harness-acp-remote--page "Could not sign in" (harness-acp-remote--escape text)
                               "Start again from the pairing page or the sign-in link."))))

(defun harness-acp-remote--oidc-callback (proc request)
  "Finish the sign-in of the browser on PROC.
The provider sent it back with REQUEST."
  (let* ((query (plist-get request :query))
         (state (cdr (assoc "state" query)))
         (code (cdr (assoc "code" query)))
         (error-code (cdr (assoc "error" query)))
         (address (process-get proc 'harness-acp-remote-address))
         (agent (harness-acp-remote-header request "user-agent"))
         (login (progn (harness-acp-remote--forget-logins)
                       (cl-find state harness-acp-remote--logins
                                :key (lambda (l) (plist-get l :state)) :test #'equal))))
    ;; A sign-in is finished once, by the browser that began it.
    (when login (setq harness-acp-remote--logins (delq login harness-acp-remote--logins)))
    (cond
     ((not (equal (plist-get request :method) "GET"))
      (harness-acp-remote--respond-text proc 405 "Use GET." '(("Allow" . "GET"))))
     ((harness-acp-remote--throttled address)
      (harness-acp-remote--respond proc 429 (harness-acp-remote--page "Too many tries" "Wait a minute and try again.")))
     ((or (null login)
          (not (let ((cookie (harness-acp-remote--cookie request "harness_login")))
                 (and cookie (harness-acp-remote--equal-p (harness-acp-remote--hash cookie)
                                                          (plist-get login :browser))))))
      (harness-acp-remote--note-failure address)
      (harness-acp-remote--oidc-failure
       proc 400 "This sign-in was not started in this browser, or it took too long."))
     (error-code
      (harness-acp-remote--oidc-failure
       proc 403 (format "The provider refused the sign-in (%s)" error-code)))
     ((not (stringp code))
      (harness-acp-remote--oidc-failure proc 400 "The provider sent no code."))
     (t
      (harness-acp-remote--oidc-discover
       (lambda (config why)
         (if (null config)
             (harness-acp-remote--oidc-failure proc 502 why)
           (harness-acp-remote--oidc-token proc login config code address agent))))))))

(defun harness-acp-remote--oidc-secret ()
  "Return the client secret, or nil for a public client."
  (let ((secret harness-acp-remote-oidc-client-secret))
    (if (functionp secret) (funcall secret) secret)))

(defun harness-acp-remote--oidc-token (proc login config code address agent)
  "Exchange CODE for the tokens of LOGIN, and finish the sign-in.
CONFIG describes the provider.  PROC is the browser's socket, ADDRESS
where it is and AGENT what it says it is."
  (require 'harness-http)
  (harness-http-request
   (plist-get config :token) :method "POST" :timeout 30
   :headers '(("Content-Type" . "application/x-www-form-urlencoded") ("Accept" . "application/json"))
   :body (harness-acp-remote--form-encode
          (append `(("grant_type" . "authorization_code")
                    ("code" . ,code)
                    ("redirect_uri" . ,(harness-acp-remote--oidc-redirect-uri))
                    ("client_id" . ,harness-acp-remote-oidc-client-id)
                    ("code_verifier" . ,(plist-get login :verifier)))
                  (when-let* ((secret (harness-acp-remote--oidc-secret)))
                    `(("client_secret" . ,secret)))))
   :callback
   (lambda (status _headers body err)
     (let* ((tokens (and (not err) (eql status 200)
                         (condition-case nil (harness-json-parse body) (error nil))))
            (claims (and (consp tokens) (harness-acp-remote--oidc-claims (plist-get tokens :id_token))))
            (problem (and claims (harness-acp-remote--oidc-claims-problem
                                  claims (plist-get login :nonce)
                                  (string-remove-suffix "/" harness-acp-remote-oidc-issuer)))))
       (cond
        ((null claims)
         (harness-acp-remote--oidc-failure proc 502 "The provider gave no id token for that sign-in."))
        (problem (harness-acp-remote--oidc-failure proc 403 problem))
        ((and (plist-get config :userinfo)
              (consp harness-acp-remote-oidc-allowed)
              (not (plist-get claims :groups))
              (stringp (plist-get tokens :access_token)))
         ;; The id token left out what the allow-list asks for: the
         ;; provider's userinfo has it, for the same subject.
         (harness-http-request
          (plist-get config :userinfo) :timeout 20
          :headers `(("Authorization" . ,(concat "Bearer " (plist-get tokens :access_token)))
                     ("Accept" . "application/json"))
          :callback
          (lambda (ustatus _uh ubody uerr)
            (let ((info (and (not uerr) (eql ustatus 200)
                             (condition-case nil (harness-json-parse ubody) (error nil)))))
              (harness-acp-remote--oidc-finish
               proc (if (and (consp info) (equal (plist-get info :sub) (plist-get claims :sub)))
                        (let ((merged (copy-sequence claims)))
                          (cl-loop for (k v) on info by #'cddr
                                   unless (plist-get merged k)
                                   do (setq merged (plist-put merged k v)))
                          merged)
                      claims)
               address agent login)))))
        (t (harness-acp-remote--oidc-finish proc claims address agent login)))))))

(defun harness-acp-remote--oidc-finish (proc claims address agent login)
  "Sign the browser on PROC in, if the provider vouched for someone allowed.
CLAIMS are the id token's, ADDRESS and AGENT describe the browser, and
LOGIN is the sign-in this finishes: for a connection that waits for it
when it has a client, else for the browser's own session."
  (let ((who (or (plist-get claims :email) (plist-get claims :preferred_username) (plist-get claims :sub))))
    (cond
     ((not (process-live-p proc)) nil)
     ((not (harness-acp-remote--oidc-allowed-p claims))
      (harness-log 'info "acp-remote: refused the sign-in of %s: not in harness-acp-remote-oidc-allowed" who)
      (harness-acp-remote--oidc-failure
       proc 403 "You signed in, but you are not allowed to use this harness."))
     ((plist-get login :client)
      (let ((client (plist-get login :client)))
        (if (not (memq client (harness-acp-remote--preauth-clients)))
            (harness-acp-remote--oidc-failure
             proc 410 "The device that asked is not waiting any more. Start again in the app.")
          (let ((wait (harness-acp-remote--login-wait client)))
            (plist-put wait :subject (plist-get claims :sub))
            (plist-put wait :who who)
            ;; Signed in now when its `authenticate' waits; else when it comes.
            (when (plist-get wait :promise) (harness-acp-remote--finish-login wait))
            (harness-acp-remote--respond
             proc 200 (harness-acp-remote--page
                       "Signed in"
                       (format "You signed in as <b>%s</b>. Go back to the app: the device you confirmed signs in there."
                               (harness-acp-remote--escape who)))
             :headers '(("Set-Cookie" . "harness_login=; Path=/; Max-Age=0")))))))
     (t
      (let ((pair (harness-acp-remote--mint
                   (format "%s · %s" who (harness-acp-remote--device-name agent))
                   agent address "oidc" (plist-get claims :sub))))
        (harness-acp-remote--respond proc 200 (harness-acp-remote--signed-in-page (car pair) (cdr pair))
                                     :headers '(("Set-Cookie" . "harness_login=; Path=/; Max-Age=0"))))))))

;;;; Methods

;; Serving other devices is managed from the Emacs on this machine: a
;; device that is signed in may drive the harness, not hand out more
;; access (approve another device, make a token, revoke the others, move
;; the listener).

(defvar harness-acp--calling-client)

(defun harness-acp-remote--local-caller-only ()
  "Signal unless the client whose request is being served is on this machine."
  (let ((client harness-acp--calling-client))
    (when (and client (harness-acp-client-remote-info client))
      (signal 'harness-error
              (list "Serving other devices is managed from the Emacs on this machine, not by a device it serves")))))

(harness-defmethod acp/remote-status ()
  "Describe serving other devices, for the remote control page.
Return (:running :enabled :corporate :host :port :address :address-set
:addresses ((:address :interface :kind) ...) :ws-url :base-url :secure
:approval :approvals ((:id :code :name :address :origin :expires) ...)
:oidc (:configured :issuer :login-url :allowed)
:devices ((:id :name :agent :address :method :subject :paired :seen
:expires :ephemeral :connected) ...) :clients)."
  (harness-acp-remote--local-caller-only)
  (harness-acp-remote--load-sessions)
  (harness-acp-remote--expire)
  (list :running (if (harness-acp-remote--running-p) t :false)
        :enabled (if harness-acp-remote t :false)
        :corporate (if (harness-corporate-p) t :false)
        :host harness-acp-remote-host
        :port (harness-acp-remote--port)
        :address (harness-acp-remote--advertised-address)
        :address-set (if (and harness-acp-remote-address (not (string-blank-p harness-acp-remote-address)))
                         t :false)
        :addresses (harness-acp-remote--candidates)
        :ws-url (harness-acp-remote--ws-url)
        :base-url (harness-acp-remote--base-url)
        :public-url-set (if (harness-acp-remote--public-url) t :false)
        :secure (if (harness-acp-remote--secure-p) t :false)
        :approval (if harness-acp-remote-approval t :false)
        :approvals (mapcar #'harness-acp-remote--approval-view harness-acp-remote--approvals)
        :oidc (list :configured (if (harness-acp-remote--oidc-configured-p) t :false)
                    :issuer harness-acp-remote-oidc-issuer
                    :login-url (harness-acp-remote--oidc-login-url)
                    :allowed (if harness-acp-remote-oidc-allowed t :false))
        :devices (mapcar (lambda (s)
                           (list :id (plist-get s :id) :name (plist-get s :name)
                                 :agent (plist-get s :agent) :address (plist-get s :address)
                                 :method (plist-get s :method) :subject (plist-get s :subject)
                                 :paired (plist-get s :created) :seen (plist-get s :seen)
                                 :ephemeral (if (plist-get s :ephemeral) t :false)
                                 :expires (and (not (plist-get s :ephemeral))
                                               (min (+ (harness-acp-remote--issued s) harness-acp-remote-session-lifetime)
                                                    (+ (plist-get s :seen) harness-acp-remote-idle-timeout)))
                                 :connected (length (harness-acp-remote--clients (plist-get s :id)))))
                         harness-acp-remote--sessions)
        :clients (length (harness-acp-remote--clients))))

(harness-defmethod acp/remote-start ()
  "Serve other devices, now and whenever the harness starts.
Saves `harness-acp-remote'.  Corporate mode refuses, and so does a
policy that turns `harness-acp-remote' off.  Return the status."
  (harness-acp-remote--local-caller-only)
  (harness-acp-remote--refuse-in-corporate-mode)
  ;; Before anything listens: the save would refuse too, too late.
  (unless harness-acp-remote
    (harness-policy-refuse 'harness-acp-remote))
  (unless (harness-acp-remote--running-p)
    (harness-acp-remote--listen))
  (unless harness-acp-remote
    (harness-save-user-option 'harness-acp-remote t))
  (harness-acp-remote--changed "started")
  (harness-call 'acp/remote-status))

(harness-defmethod acp/remote-stop ()
  "Stop serving other devices, now and at the next starts.
Their connections close; the devices stay signed in for the next time.
Saves `harness-acp-remote'; a policy that turns it on refuses.  Return
the status."
  (harness-acp-remote--local-caller-only)
  (when harness-acp-remote
    (harness-policy-refuse 'harness-acp-remote))
  (harness-acp-remote--stop)
  (when harness-acp-remote
    (harness-save-user-option 'harness-acp-remote nil))
  (harness-acp-remote--changed "stopped")
  (harness-call 'acp/remote-status))

(harness-defmethod acp/remote-approve (id)
  "Sign in the device whose request to sign in has the id ID.  Return t.
The device is described by the status (`:approvals'), with the code its
client shows.  Only the Emacs on this machine may call it: it is what
\"Approve in Emacs\" asks."
  (harness-acp-remote--local-caller-only)
  (harness-acp-remote--refuse-in-corporate-mode)
  (harness-acp-remote--approve id))

(harness-defmethod acp/remote-deny (id)
  "Refuse the device whose request to sign in has the id ID.  Return t."
  (harness-acp-remote--local-caller-only)
  (harness-acp-remote--deny id))

(harness-defmethod acp/remote-create-token (&optional name)
  "Make a session secret for a device that is given one by hand; return it.
NAME is what the device is called.  Return (:token SECRET :id ID :name
NAME :ws-url ADDRESS :url ADDRESS-WITH-SECRET :expires TIME): the secret is
in no other answer and is not kept, only its hash, so it is shown once.
A client that has a field for it sends it as `Authorization: Bearer', or
takes URL as its address, and then needs no approval.  The harness must
be serving other devices.  Corporate mode refuses."
  (harness-acp-remote--local-caller-only)
  (harness-acp-remote--refuse-in-corporate-mode)
  (unless (harness-acp-remote--running-p)
    (signal 'harness-error (list "The harness is not serving other devices; start it first")))
  (let* ((pair (harness-acp-remote--mint (or name "Token") nil nil "token"))
         (session (car pair))
         (secret (cdr pair)))
    (list :token secret :id (plist-get session :id) :name (plist-get session :name)
          :ws-url (harness-acp-remote--ws-url)
          :url (format "%s?token=%s" (harness-acp-remote--ws-url) secret)
          :expires (+ (harness-acp-remote--issued session) harness-acp-remote-session-lifetime))))

(harness-defmethod acp/remote-revoke (id)
  "End the session of device ID and close its connections.  Return t."
  (harness-acp-remote--local-caller-only)
  (unless (harness-acp-remote--revoke id)
    (signal 'harness-error (list (format "No signed-in device %s" id))))
  t)

(harness-defmethod acp/remote-revoke-all ()
  "End every session and close every connection.  Return how many there were."
  (harness-acp-remote--local-caller-only)
  (let ((ids (mapcar (lambda (s) (plist-get s :id)) harness-acp-remote--sessions)))
    (mapc #'harness-acp-remote--revoke ids)
    (length ids)))

(harness-defmethod acp/remote-set-address (address)
  "Put ADDRESS in the ACP address and links; nil or \"\" detects it again.
Saves `harness-acp-remote-address'.  Return the status."
  (harness-acp-remote--local-caller-only)
  (let ((value (and (stringp address) (not (string-blank-p address)) (string-trim address))))
    (harness-save-user-option 'harness-acp-remote-address value)
    (harness-acp-remote--changed "address")
    (harness-call 'acp/remote-status)))

;;;; Module

(defun harness-acp-remote--on-corporate-mode ()
  "Stop serving other devices once corporate mode turns on."
  (when (harness-corporate-p)
    (harness-acp-remote--stop)
    (harness-acp-remote--changed "corporate")))

(defun harness-acp-remote--hook ()
  "Join the hooks of the acp module and of corporate mode (idempotent)."
  (add-hook 'harness-acp-authorize-functions #'harness-acp-remote--authorize)
  (add-hook 'harness-acp-auth-methods-functions #'harness-acp-remote--auth-methods)
  (add-hook 'harness-acp-authenticate-functions #'harness-acp-remote--authenticate)
  (add-hook 'harness-acp-agent-capabilities-functions #'harness-acp-remote--capabilities)
  (add-hook 'harness-acp-initialize-extras-functions #'harness-acp-remote--initialize-extras)
  (add-hook 'harness-corporate-mode-change-hook #'harness-acp-remote--on-corporate-mode))

(defun harness-acp-remote--init ()
  "Join the hooks, and serve other devices when `harness-acp-remote' is on."
  (harness-acp-remote--hook)
  (harness-acp-remote--load-sessions)
  (when (and harness-acp-remote (not (harness-corporate-p)) (not (harness-acp-remote--running-p)))
    (condition-case err
        (harness-acp-remote--listen)
      (error (harness-log 'warn "acp-remote: not serving other devices: %s" (harness-error-message err))))))

(defun harness-acp-remote--shutdown ()
  "Stop serving other devices and leave the hooks; the sessions are kept."
  (harness-acp-remote--stop)
  (harness-acp-remote--save-sessions)
  (remove-hook 'harness-acp-authorize-functions #'harness-acp-remote--authorize)
  (remove-hook 'harness-acp-auth-methods-functions #'harness-acp-remote--auth-methods)
  (remove-hook 'harness-acp-authenticate-functions #'harness-acp-remote--authenticate)
  (remove-hook 'harness-acp-agent-capabilities-functions #'harness-acp-remote--capabilities)
  (remove-hook 'harness-acp-initialize-extras-functions #'harness-acp-remote--initialize-extras)
  (remove-hook 'harness-corporate-mode-change-hook #'harness-acp-remote--on-corporate-mode))

(harness-define-module 'acp-remote
  :doc "ACP for phones and other devices on the network: WebSocket, sign-in by approval in Emacs or OpenID Connect, session secrets."
  :requires '(acp)
  :init #'harness-acp-remote--init
  :shutdown #'harness-acp-remote--shutdown)

(provide 'harness-acp-remote)
;;; harness-acp-remote.el ends here
