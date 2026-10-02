;;; harness-acp-remote.el --- ACP for phones and other devices, paired by QR code  -*- lexical-binding: t; -*-

;;; Commentary:

;; The ACP server of harness-acp.el listens on this machine only.  This
;; module lets a phone (or any other device) on the network drive the
;; harness with an ACP client of its own, however that client
;; authenticates: no client needs to know about QR codes.
;;
;; - One listener (`harness-acp-remote-host', `harness-acp-remote-port')
;;   speaks ACP over WebSocket, the transport ACP's draft for remote
;;   agents asks of clients (`ws://ADDRESS:PORT/acp'), and also ACP's
;;   own line framing for clients that use plain TCP.  It is off until
;;   the user turns it on (`harness-acp-remote').
;; - Pairing: the UI shows a QR code of `http://ADDRESS:PORT/pair?code=C',
;;   C a one-time code that expires.  Opening it on the phone pairs the
;;   phone: its address may call ACP while it keeps using it.  The page
;;   it opens gives the address to add in the phone's ACP client.
;; - A client that has not paired is refused with ACP's auth_required
;;   and offered the auth method `pair'; `authenticate' with it waits for
;;   the QR code to be opened from the same address, then answers, which
;;   tells the client it may go on.
;; - Corporate mode (`harness-corporate-mode') refuses all of it.
;;
;; The WebSocket protocol (RFC 6455) is implemented here on strings:
;; Emacs has no WebSocket server.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)
(require 'harness-core)
(require 'harness-util)
(require 'harness-acp)

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
    ('freed (error "harness-acp-remote: the WebSocket decoder was freed"))
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
framing), and a device may use it once it paired by opening the link
of a QR code the remote control page shows (`harness-remote-control').
That page turns it on and off.  Corporate mode refuses it."
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
  "Address of this machine that pairing links and QR codes carry, or nil.
nil picks one: that of a local network interface (Wi-Fi, Ethernet),
else of a VPN such as Tailscale.  Set it when other devices reach this
machine at another address."
  :type '(choice (const :tag "Detect" nil) string) :group 'harness)

(defcustom harness-acp-remote-code-lifetime 600
  "Seconds a pairing code stays valid, and an `authenticate' waits for one."
  :type 'integer :group 'harness)

(defcustom harness-acp-remote-idle-timeout (* 8 3600)
  "Seconds after which a paired device that stopped connecting must pair again.
A pairing is tied to the device's network address, which another
device may get later."
  :type 'integer :group 'harness)

(defcustom harness-acp-remote-max-message (* 64 1024 1024)
  "Largest message, in bytes, a device may send."
  :type 'integer :group 'harness)

;;;; State

(defvar harness-acp--clients)
(defvar harness-acp-token)
(defvar harness-acp-error-unauthenticated)

(defvar harness-acp-remote--server nil "The listening process, or nil.")

(defvar harness-acp-remote--code nil
  "The pairing code in force as (:code STRING :expires TIME), or nil.")

(defvar harness-acp-remote--devices nil
  "Paired devices, newest first: (:id :address :agent :paired :seen) plists.")

(defvar harness-acp-remote--waiting nil
  "`authenticate' requests waiting for their device to pair.
Each is a plist (:client :address :resolve :reject :timer).")

(defvar harness-acp-remote--allow-loopback nil
  "Non-nil lets this machine's own addresses pair; for tests.")

(defconst harness-acp-remote--virtual-interfaces
  "\\`\\(?:docker\\|br-\\|veth\\|virbr\\|vnet\\|lxc\\|lxd\\|cni\\|flannel\\|podman\\|vmnet\\|vboxnet\\|kube\\)"
  "Interfaces of containers and virtual machines, whose addresses no phone reaches.")

(harness-declare-event 'acp/remote-changed
                       "(PLIST) when serving other devices changed: (:what WHAT :address A).
WHAT is started, stopped, connected, disconnected, paired, revoked,
address or corporate.")

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

(defun harness-acp-remote--port ()
  "Return the port the listener has, else the one it would take."
  (if (harness-acp-remote--running-p)
      (process-contact harness-acp-remote--server :service)
    harness-acp-remote-port))

(defun harness-acp-remote--authority ()
  "Return ADDRESS:PORT of the listener as other devices reach it."
  (let ((address (harness-acp-remote--advertised-address)))
    (format (if (string-search ":" address) "[%s]:%s" "%s:%s") address (harness-acp-remote--port))))

(defun harness-acp-remote--ws-url ()
  "Return the address an ACP client on another device connects to."
  (format "ws://%s/acp" (harness-acp-remote--authority)))

;;;; Pairing

(defun harness-acp-remote--random-bytes (n)
  "Return N random bytes, from /dev/urandom when it can be read."
  (condition-case nil
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally "/dev/urandom" nil 0 n)
        (if (= (buffer-size) n) (buffer-string) (error "Short read")))
    (error (substring (secure-hash 'sha512 (format "%s %s %s %s" (random t) (float-time) (emacs-pid)
                                                  (current-time))
                                   nil nil t)
                      0 n))))

(defun harness-acp-remote--new-code ()
  "Return a pairing code: 20 base32 characters, 100 random bits."
  (let ((alphabet "abcdefghijklmnopqrstuvwxyz234567")
        (n 0))
    (dolist (byte (append (harness-acp-remote--random-bytes 13) nil))
      (setq n (logior (ash n 8) byte)))
    (apply #'string (cl-loop repeat 20
                             collect (aref alphabet (logand n 31))
                             do (setq n (ash n -5))))))

(defun harness-acp-remote--code-valid-p (code)
  "Non-nil when CODE is the pairing code in force and has not expired."
  (let ((current harness-acp-remote--code))
    (and current (stringp code)
         (< (float-time) (plist-get current :expires))
         (string= code (plist-get current :code)))))

(defun harness-acp-remote--clients (&optional address)
  "Return the connected clients on other devices, those of ADDRESS when given."
  (cl-remove-if-not (lambda (c)
                      (let ((remote (harness-acp-client-remote-info c)))
                        (and remote (or (null address) (equal (plist-get remote :address) address)))))
                    harness-acp--clients))

(defun harness-acp-remote--expire ()
  "Forget the paired devices unused for `harness-acp-remote-idle-timeout'."
  (let ((now (float-time)))
    (setq harness-acp-remote--devices
          (cl-remove-if (lambda (d)
                          (and (null (harness-acp-remote--clients (plist-get d :address)))
                               (> (- now (plist-get d :seen)) harness-acp-remote-idle-timeout)))
                        harness-acp-remote--devices))))

(defun harness-acp-remote--device (address)
  "Return the live pairing of ADDRESS, or nil."
  (harness-acp-remote--expire)
  (cl-find address harness-acp-remote--devices
           :key (lambda (d) (plist-get d :address)) :test #'equal))

(defun harness-acp-remote--touch (address)
  "Note that the device at ADDRESS is in use."
  (when-let* ((device (cl-find address harness-acp-remote--devices
                               :key (lambda (d) (plist-get d :address)) :test #'equal)))
    (plist-put device :seen (float-time))))

(defun harness-acp-remote--grant (address agent)
  "Pair the device at ADDRESS, whose browser says it is AGENT; return its record."
  (let ((now (float-time)))
    (setq harness-acp-remote--devices
          (cons (list :id (harness-short-id 8) :address address :agent agent :paired now :seen now)
                (cl-remove address harness-acp-remote--devices
                           :key (lambda (d) (plist-get d :address)) :test #'equal)))
    (car harness-acp-remote--devices)))

(defun harness-acp-remote--settle-waiting (address)
  "Let the `authenticate' requests waiting for ADDRESS to pair go on."
  (dolist (entry (copy-sequence harness-acp-remote--waiting))
    (when (equal (plist-get entry :address) address)
      (setq harness-acp-remote--waiting (delq entry harness-acp-remote--waiting))
      (when (plist-get entry :timer) (cancel-timer (plist-get entry :timer)))
      (funcall (plist-get entry :resolve) t))))

(defun harness-acp-remote--forget-waiting (&optional client)
  "Drop the waiting `authenticate' requests of CLIENT, or all of them."
  (dolist (entry (copy-sequence harness-acp-remote--waiting))
    (when (or (null client) (eq client (plist-get entry :client)))
      (setq harness-acp-remote--waiting (delq entry harness-acp-remote--waiting))
      (when (plist-get entry :timer) (cancel-timer (plist-get entry :timer)))
      (funcall (plist-get entry :reject)
               (list 'acp-error harness-acp-error-unauthenticated "Pairing stopped" nil)))))

;;;; Who may call ACP

(defun harness-acp-remote--pairable-p (client)
  "Non-nil when CLIENT, on another device, may be let in by its pairing.
A WebSocket opened by a web page (an Origin header that is not an
app's own) may not: any page the paired phone shows could open one."
  (let ((remote (harness-acp-client-remote-info client)))
    (and remote
         (not (plist-get remote :web))
         (not (harness-corporate-p))
         (or harness-acp-remote--allow-loopback
             (not (harness-acp-remote--loopback-p (plist-get remote :address)))))))

(defun harness-acp-remote--authorize (client)
  "Let CLIENT in when its device is paired; for `harness-acp-authorize-functions'."
  (when (harness-acp-remote--pairable-p client)
    (let ((address (plist-get (harness-acp-client-remote-info client) :address)))
      (when (harness-acp-remote--device address)
        (harness-acp-remote--touch address)
        t))))

(defun harness-acp-remote--auth-methods (client)
  "Offer CLIENT the `pair' method; for `harness-acp-auth-methods-functions'."
  (when (harness-acp-remote--pairable-p client)
    (list (list :id "pair" :name "Pair with a QR code"
                :description "In Emacs, open the harness's remote control page (C-c h P), show its pairing QR code and scan it with this device. Authenticating with this method waits until the code is scanned."))))

(defun harness-acp-remote--authenticate (client method _params)
  "Answer `authenticate' with METHOD `pair' for CLIENT once its device pairs.
For `harness-acp-authenticate-functions'.  The answer waits at most
`harness-acp-remote-code-lifetime' seconds."
  (when (and (equal method "pair") (harness-acp-remote--pairable-p client))
    (let ((address (plist-get (harness-acp-client-remote-info client) :address)))
      (if (harness-acp-remote--device address)
          t
        (harness-with-promise (resolve reject)
          (let ((entry (list :client client :address address :resolve resolve :reject reject :timer nil)))
            (plist-put entry :timer
                       (run-at-time harness-acp-remote-code-lifetime nil
                                    (lambda ()
                                      (when (memq entry harness-acp-remote--waiting)
                                        (setq harness-acp-remote--waiting (delq entry harness-acp-remote--waiting))
                                        (funcall reject (list 'acp-error harness-acp-error-unauthenticated
                                                              "No pairing QR code was opened on this device in time"
                                                              nil))))))
            (push entry harness-acp-remote--waiting)))))))

;;;; Connections

(defun harness-acp-remote--send (proc bytes)
  "Write BYTES to the socket PROC, if it is still open."
  (when (process-live-p proc)
    (condition-case err
        (process-send-string proc bytes)
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
   "<title>" (harness-acp-remote--escape title) "</title><style>"
   "body{font:17px/1.5 system-ui,sans-serif;margin:0;padding:1.5rem;color:#1d1f21;background:#fafafa}"
   "main{max-width:34rem;margin:auto}h1{font-size:1.4rem}"
   "input{font:inherit;width:100%;box-sizing:border-box;padding:.5rem;margin:.25rem 0}"
   "button{font:inherit;padding:.4rem 1rem}.note{color:#666;font-size:.9rem}"
   "@media (prefers-color-scheme:dark){body{color:#e6e6e6;background:#1e2127}.note{color:#aaa}"
   "input{background:#2c313c;color:#e6e6e6;border:1px solid #555}}"
   "</style></head><body><main><h1>" (harness-acp-remote--escape title) "</h1>"
   (mapconcat (lambda (p) (concat "<p>" p "</p>")) paragraphs "")
   "</main></body></html>"))

(defun harness-acp-remote--paired-page ()
  "Return the page a device sees once it paired."
  (concat
   (harness-acp-remote--page
    "Paired"
    (format "This device may now use the Emacs Agent Harness on %s."
            (harness-acp-remote--escape (system-name)))
    "In your ACP client, add a remote agent with this address:"
    (format "<input id=\"a\" readonly value=\"%s\" onclick=\"this.select()\"> <button onclick=\"copyAddress()\">Copy</button>"
            (harness-acp-remote--escape (harness-acp-remote--ws-url)))
    (format "<span class=\"note\">The pairing lasts while this device uses it, until it goes unused for %s or you unpair it in Emacs. The connection is not encrypted: use it on a network you trust, or over a VPN such as Tailscale.</span>"
            (harness-format-duration harness-acp-remote-idle-timeout)))
   "<script>function copyAddress(){var i=document.getElementById('a');i.select();"
   "try{navigator.clipboard.writeText(i.value).catch(function(){document.execCommand('copy')})}"
   "catch(e){document.execCommand('copy')}}</script>"))

(cl-defun harness-acp-remote--respond (proc status body &key headers)
  "Answer the HTTP request on PROC with STATUS and the HTML BODY, then close."
  (let ((bytes (encode-coding-string body 'utf-8 t))
        (reason (pcase status (200 "OK") (400 "Bad Request") (403 "Forbidden") (404 "Not Found")
                       (405 "Method Not Allowed") (431 "Request Header Fields Too Large") (_ "Error"))))
    (process-put proc 'harness-acp-remote-state 'closing)
    (harness-acp-remote--send
     proc (concat (encode-coding-string
                   (concat (format "HTTP/1.1 %d %s\r\n" status reason)
                           "Content-Type: text/html; charset=utf-8\r\n"
                           (format "Content-Length: %d\r\n" (length bytes))
                           "Connection: close\r\nCache-Control: no-store\r\n"
                           "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n"
                           (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) headers "")
                           "\r\n")
                   'utf-8 t)
                  bytes))
    (when (process-live-p proc)
      (ignore-errors (process-send-eof proc))
      (run-at-time 5 nil (lambda () (when (process-live-p proc) (delete-process proc)))))))

(defun harness-acp-remote--web-origin-p (origin)
  "Non-nil when ORIGIN, an Origin header, names a web page.
An app's own web view (Tauri, Capacitor, a page on localhost) is not
one; neither is a missing header, as native clients send none."
  (and origin
       (not (string-match-p "\\`\\(?:tauri\\|capacitor\\|ionic\\|app\\|file\\)://" origin))
       (not (string-match-p "\\`https?://\\(?:localhost\\|tauri\\.localhost\\|127\\.0\\.0\\.1\\)\\(?::[0-9]+\\)?\\'"
                            origin))))

(defun harness-acp-remote--request-token (request offered)
  "Return the bearer token REQUEST carries, from OFFERED subprotocols or elsewhere."
  (or (cl-some (lambda (p) (and (string-prefix-p "bearer." p) (substring p (length "bearer.")))) offered)
      (let ((auth (harness-acp-remote-header request "authorization")))
        (and auth (string-match "\\`[Bb]earer[ \t]+\\(.+\\)\\'" auth) (match-string 1 auth)))
      (cdr (assoc "token" (plist-get request :query)))))

(defun harness-acp-remote--upgrade (proc request)
  "Turn the socket PROC into a WebSocket for ACP, as REQUEST asks."
  (let* ((offered (harness-acp-remote-ws-offered-protocols request))
         (protocol (or (car (member "acp.v1" offered))
                       (cl-find-if-not (lambda (p) (string-prefix-p "bearer." p)) offered)
                       (car offered)))
         (token (harness-acp-remote--request-token request offered))
         (address (process-get proc 'harness-acp-remote-address))
         (origin (harness-acp-remote-header request "origin"))
         (client (harness-acp-add-client
                  'websocket :process proc :writer #'harness-acp-remote--write-ws
                  :remote (list :address address :transport "websocket"
                                :agent (harness-acp-remote-header request "user-agent")
                                :origin origin
                                :web (and (harness-acp-remote--web-origin-p origin) t)))))
    (when (and token harness-acp-token (string= token harness-acp-token))
      (setf (harness-acp-client-authenticated client) t))
    (process-put proc 'harness-acp-remote-client client)
    (process-put proc 'harness-acp-remote-decoder
                 (harness-acp-remote-decoder :max-message harness-acp-remote-max-message))
    (process-put proc 'harness-acp-remote-state 'ws)
    (harness-acp-remote--send proc (harness-acp-remote-ws-handshake
                                    request protocol (list (cons "Acp-Connection-Id" (harness-uuid)))))
    (harness-acp-remote--touch address)
    (harness-acp-remote--changed "connected" address)
    (let ((rest (plist-get request :rest)))
      (unless (string-empty-p rest) (harness-acp-remote--ws-input proc rest)))))

(defun harness-acp-remote--serve-lines (proc bytes)
  "Serve ACP's own line framing on the socket PROC, which sent BYTES so far."
  (let* ((address (process-get proc 'harness-acp-remote-address))
         (client (harness-acp-add-client 'remote-tcp :process proc :writer #'harness-acp-remote--write-line
                                         :remote (list :address address :transport "tcp"))))
    (process-put proc 'harness-acp-remote-client client)
    (process-put proc 'harness-acp-remote-state 'lines)
    (process-put proc 'harness-acp-remote-pending "")
    (harness-acp-remote--touch address)
    (harness-acp-remote--changed "connected" address)
    (harness-acp-remote--line-input proc bytes)))

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
    (if (> (- (length bytes) start) harness-acp-remote-max-message)
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

(defun harness-acp-remote--pair-visit (proc request)
  "Pair the device that opened the pairing link of REQUEST on PROC."
  (let ((code (cdr (assoc "code" (plist-get request :query))))
        (address (process-get proc 'harness-acp-remote-address)))
    (cond
     ((and (harness-acp-remote--loopback-p address) (not harness-acp-remote--allow-loopback))
      (harness-acp-remote--respond
       proc 403 (harness-acp-remote--page
                 "Open this link on the device to pair"
                 "This page was opened on the machine the harness runs on, which needs no pairing. Scan the QR code with the phone or other device that should connect; the code is still valid.")))
     ((not (harness-acp-remote--code-valid-p code))
      (harness-acp-remote--respond
       proc 403 (harness-acp-remote--page
                 "This pairing link is not valid any more"
                 "A pairing link works once and expires after a few minutes. Show a new QR code on the remote control page in Emacs (C-c h P) and scan it again.")))
     (t
      (setq harness-acp-remote--code nil)
      (harness-acp-remote--grant address (harness-acp-remote-header request "user-agent"))
      (harness-log 'info "acp-remote: paired %s" address)
      (harness-acp-remote--settle-waiting address)
      (harness-acp-remote--changed "paired" address)
      (harness-acp-remote--respond proc 200 (harness-acp-remote--paired-page))))))

(defun harness-acp-remote--route (proc request)
  "Answer the HTTP REQUEST read from PROC."
  (let ((path (plist-get request :path)))
    (cond
     ((harness-corporate-p)
      (harness-acp-remote--respond
       proc 403 (harness-acp-remote--page "Not available"
                                          "Corporate mode is on: this harness serves no other device.")))
     ((harness-acp-remote-ws-upgrade-p request) (harness-acp-remote--upgrade proc request))
     ((not (equal (plist-get request :method) "GET"))
      (harness-acp-remote--respond
       proc 405 (harness-acp-remote--page "Use WebSocket"
                                          "This harness serves ACP over WebSocket only.")
       :headers '(("Allow" . "GET"))))
     ((equal path "/pair") (harness-acp-remote--pair-visit proc request))
     ((member path '("/" "/acp"))
      (harness-acp-remote--respond
       proc 200 (harness-acp-remote--page
                 "Emacs Agent Harness"
                 (format "Phones and other devices connect here to the harness on %s, with an ACP client."
                         (harness-acp-remote--escape (system-name)))
                 "To pair a device, open the remote control page in Emacs (C-c h P), show its pairing QR code and scan it with the device's camera."
                 (format "ACP address: <code>%s</code>" (harness-acp-remote--escape (harness-acp-remote--ws-url))))))
     (t (harness-acp-remote--respond proc 404 (harness-acp-remote--page "Not found" "Nothing here."))))))

(defun harness-acp-remote--head-input (proc chunk)
  "Read the start of what PROC sends: an HTTP request, or ACP lines."
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
         (t (process-put proc 'harness-acp-remote-pending nil)
            (harness-acp-remote--route proc request))))))))

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
      (when-let* ((decoder (process-get proc 'harness-acp-remote-decoder)))
        (process-put proc 'harness-acp-remote-decoder nil)
        (harness-acp-remote-decoder-free decoder))
      (when-let* ((client (process-get proc 'harness-acp-remote-client)))
        (process-put proc 'harness-acp-remote-client nil)
        (harness-acp-remote--forget-waiting client)
        (harness-acp-drop-client client)
        (harness-acp-remote--touch (process-get proc 'harness-acp-remote-address))
        (harness-acp-remote--changed "disconnected" (process-get proc 'harness-acp-remote-address))))))

(defun harness-acp-remote--accept (_server proc _message)
  "Set up the socket PROC the listener just accepted."
  (set-process-query-on-exit-flag proc nil)
  (set-process-coding-system proc 'binary 'binary)
  (set-process-filter proc #'harness-acp-remote--filter)
  (set-process-sentinel proc #'harness-acp-remote--sentinel)
  (process-put proc 'harness-acp-remote-address (harness-acp-remote--address-of proc))
  (when (harness-corporate-p) (delete-process proc)))

;;;; Serving

(defun harness-acp-remote--running-p ()
  "Non-nil while the listener for other devices runs."
  (and harness-acp-remote--server (process-live-p harness-acp-remote--server)))

(defun harness-acp-remote--refuse-in-corporate-mode ()
  "Signal when corporate mode is on."
  (when (harness-corporate-p)
    (signal 'harness-error (list "Corporate mode is on: the harness serves no other device"))))

(defun harness-acp-remote--listen ()
  "Start the listener for other devices."
  (harness-acp-remote--refuse-in-corporate-mode)
  (setq harness-acp-remote--server
        (make-network-process :name "harness-acp-remote" :server t
                              :host harness-acp-remote-host :service harness-acp-remote-port
                              :coding 'binary :noquery t
                              :filter #'harness-acp-remote--filter
                              :sentinel #'harness-acp-remote--sentinel
                              :log #'harness-acp-remote--accept))
  (harness-log 'info "acp-remote: serving other devices on %s:%s; they connect to %s"
               harness-acp-remote-host (harness-acp-remote--port) (harness-acp-remote--ws-url)))

(defun harness-acp-remote--stop ()
  "Stop serving other devices: close the listener and their connections.
Pairings and the pairing code are forgotten."
  (let ((server harness-acp-remote--server))
    (setq harness-acp-remote--server nil)
    (when (and server (process-live-p server)) (delete-process server)))
  (dolist (client (harness-acp-remote--clients))
    (harness-acp-drop-client client))
  (harness-acp-remote--forget-waiting)
  (setq harness-acp-remote--code nil
        harness-acp-remote--devices nil))

;;;; Methods

(harness-defmethod acp/remote-status ()
  "Describe serving other devices, for the remote control page.
Return (:running :enabled :corporate :host :port :address :address-set
:addresses ((:address :interface :kind) ...) :ws-url :code-expires
:devices ((:id :address :agent :paired :seen :connected) ...) :clients)."
  (harness-acp-remote--expire)
  (let ((code harness-acp-remote--code))
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
          :code-expires (and code (< (float-time) (plist-get code :expires)) (plist-get code :expires))
          :devices (mapcar (lambda (d)
                             (append d (list :connected (length (harness-acp-remote--clients
                                                                 (plist-get d :address))))))
                           harness-acp-remote--devices)
          :clients (length (harness-acp-remote--clients)))))

(harness-defmethod acp/remote-start ()
  "Serve other devices, now and whenever the harness starts.
Saves `harness-acp-remote'.  Corporate mode refuses.  Return the status."
  (harness-acp-remote--refuse-in-corporate-mode)
  (unless (harness-acp-remote--running-p)
    (harness-acp-remote--listen))
  (unless harness-acp-remote
    (harness-save-user-option 'harness-acp-remote t))
  (harness-acp-remote--changed "started")
  (harness-call 'acp/remote-status))

(harness-defmethod acp/remote-stop ()
  "Stop serving other devices, now and at the next starts.
Their connections close and every pairing is forgotten.  Saves
`harness-acp-remote'.  Return the status."
  (harness-acp-remote--stop)
  (when harness-acp-remote
    (harness-save-user-option 'harness-acp-remote nil))
  (harness-acp-remote--changed "stopped")
  (harness-call 'acp/remote-status))

(harness-defmethod acp/remote-pair ()
  "Make a one-time pairing code, replacing any other, and return its link.
Return (:url URL :ws-url WS-URL :address A :port P :expires TIME
:lifetime SECONDS): URL, `http://A:P/pair?code=…', is what a QR code
carries; the device that opens it first pairs, before TIME.  WS-URL is
the address its ACP client connects to.  Corporate mode refuses, and
so does a harness that is not serving other devices."
  (harness-acp-remote--refuse-in-corporate-mode)
  (unless (harness-acp-remote--running-p)
    (signal 'harness-error (list "The harness is not serving other devices; start it first")))
  (let ((code (harness-acp-remote--new-code))
        (expires (+ (float-time) harness-acp-remote-code-lifetime)))
    (setq harness-acp-remote--code (list :code code :expires expires))
    (list :url (format "http://%s/pair?code=%s" (harness-acp-remote--authority) code)
          :ws-url (harness-acp-remote--ws-url)
          :address (harness-acp-remote--advertised-address)
          :port (harness-acp-remote--port)
          :expires expires
          :lifetime harness-acp-remote-code-lifetime)))

(harness-defmethod acp/remote-revoke (id)
  "Unpair the device ID and close its connections.  Return t."
  (let ((device (cl-find id harness-acp-remote--devices
                         :key (lambda (d) (plist-get d :id)) :test #'equal)))
    (unless device
      (signal 'harness-error (list (format "No paired device %s" id))))
    (setq harness-acp-remote--devices (delq device harness-acp-remote--devices))
    (dolist (client (harness-acp-remote--clients (plist-get device :address)))
      (harness-acp-drop-client client))
    (harness-log 'info "acp-remote: unpaired %s" (plist-get device :address))
    (harness-acp-remote--changed "revoked" (plist-get device :address))
    t))

(harness-defmethod acp/remote-set-address (address)
  "Put ADDRESS in pairing links and QR codes; nil or \"\" detects it again.
Saves `harness-acp-remote-address' and drops the pairing code in force,
whose link named the old address.  Return the status."
  (let ((value (and (stringp address) (not (string-blank-p address)) (string-trim address))))
    (harness-save-user-option 'harness-acp-remote-address value)
    (setq harness-acp-remote--code nil)
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
  (add-hook 'harness-corporate-mode-change-hook #'harness-acp-remote--on-corporate-mode))

(defun harness-acp-remote--init ()
  "Join the hooks, and serve other devices when `harness-acp-remote' is on."
  (harness-acp-remote--hook)
  (when (and harness-acp-remote (not (harness-corporate-p)) (not (harness-acp-remote--running-p)))
    (condition-case err
        (harness-acp-remote--listen)
      (error (harness-log 'warn "acp-remote: not serving other devices: %s" (harness-error-message err))))))

(defun harness-acp-remote--shutdown ()
  "Stop serving other devices and leave the hooks."
  (harness-acp-remote--stop)
  (remove-hook 'harness-acp-authorize-functions #'harness-acp-remote--authorize)
  (remove-hook 'harness-acp-auth-methods-functions #'harness-acp-remote--auth-methods)
  (remove-hook 'harness-acp-authenticate-functions #'harness-acp-remote--authenticate)
  (remove-hook 'harness-corporate-mode-change-hook #'harness-acp-remote--on-corporate-mode))

(harness-define-module 'acp-remote
  :doc "ACP for phones and other devices on the network: WebSocket, QR code pairing."
  :requires '(acp)
  :init #'harness-acp-remote--init
  :shutdown #'harness-acp-remote--shutdown)

;; A reload does not initialise a running module again.
(when (harness-module-ready-p 'acp-remote)
  (harness-acp-remote--hook))

(provide 'harness-acp-remote)
;;; harness-acp-remote.el ends here
