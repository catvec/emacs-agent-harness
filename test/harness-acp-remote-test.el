;;; harness-acp-remote-test.el --- Tests for ACP served to other devices  -*- lexical-binding: t; -*-

;;; Commentary:

;; The WebSocket framing on strings, the HTTP request parser, and the
;; whole path a phone takes, end to end over real sockets on 127.0.0.1:
;; a connection with no session may only `initialize' and `authenticate'
;; and hears nothing of the harness (and the address a device connects
;; from is no credential), signing in from the client by an approval in
;; Emacs, the ways a secret is carried, a secret checked on every
;; message, revoking, expiry, persistence, plain TCP, logout, OpenID
;; Connect against a provider that is a stub, and corporate mode.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)

;; Bound before the modules that define them load.
(defvar harness-acp--server-enabled)
(defvar harness-acp-remote)

(defun harness-acp-remote-test-load ()
  "Load the acp and acp-remote modules, the TCP server off."
  (let ((harness-acp--server-enabled nil)
        (harness-acp-remote nil))
    (harness-test-load-module 'acp)
    (harness-test-load-module 'acp-remote)))

(harness-acp-remote-test-load)

(defun harness-acp-remote-test-bytes (&rest bytes)
  "Return BYTES as a unibyte string."
  (apply #'unibyte-string bytes))

;;;; Framing

(ert-deftest harness-acp-remote-ws-accept-key ()
  (should (equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
                 (harness-acp-remote-ws-accept-key "dGhlIHNhbXBsZSBub25jZQ=="))))

(ert-deftest harness-acp-remote-ws-rfc-frames ()
  "The examples of RFC 6455 §5.7, out and in."
  (let ((hello (harness-acp-remote-test-bytes #x81 #x05 #x48 #x65 #x6c #x6c #x6f))
        (masked (harness-acp-remote-test-bytes #x81 #x85 #x37 #xfa #x21 #x3d #x7f #x9f #x4d #x51 #x58))
        (key (harness-acp-remote-test-bytes #x37 #xfa #x21 #x3d)))
    (should (equal hello (harness-acp-remote-ws-frame 'text "Hello")))
    (should (equal masked (harness-acp-remote-ws-frame 'text "Hello" key)))
    (should (equal (harness-acp-remote-test-bytes #x89 #x05 #x48 #x65 #x6c #x6c #x6f)
                   (harness-acp-remote-ws-frame 'ping "Hello")))
    (should (equal (harness-acp-remote-test-bytes #x82 #x7e #x01 #x00)
                   (substring (harness-acp-remote-ws-frame 'binary (make-string 256 ?x)) 0 4)))
    (should (equal (harness-acp-remote-test-bytes #x82 #x7f 0 0 0 0 0 1 0 0)
                   (substring (harness-acp-remote-ws-frame 'binary (make-string 65536 ?x)) 0 10)))
    (let ((d (harness-acp-remote-decoder)))
      (unwind-protect (should (equal '((text . "Hello")) (harness-acp-remote-decode d masked)))
        (harness-acp-remote-decoder-free d)))
    ;; Fragments, unmasked, with a ping between them.
    (let ((d (harness-acp-remote-decoder :require-mask nil)))
      (unwind-protect
          (progn
            (should (null (harness-acp-remote-decode d (harness-acp-remote-test-bytes #x01 #x03 #x48 #x65 #x6c))))
            (should (equal '((ping . ""))
                           (harness-acp-remote-decode d (harness-acp-remote-test-bytes #x89 #x00))))
            (should (equal '((text . "Hello"))
                           (harness-acp-remote-decode d (harness-acp-remote-test-bytes #x80 #x02 #x6c #x6f))))
            (should (equal (list (cons 'binary (make-string 65536 ?x)))
                           (harness-acp-remote-decode d (harness-acp-remote-ws-frame 'binary (make-string 65536 ?x))))))
        (harness-acp-remote-decoder-free d)))))

(defun harness-acp-remote-test-chunked (bytes sizes)
  "Return the events of decoding BYTES, masked frames, fed in chunks of SIZES (cycled)."
  (let ((d (harness-acp-remote-decoder)) (events nil) (pos 0) (sizes (copy-sequence sizes)))
    (setcdr (last sizes) sizes)
    (unwind-protect
        (progn
          (while (< pos (length bytes))
            (let ((end (min (length bytes) (+ pos (pop sizes)))))
              (setq events (append events (harness-acp-remote-decode d (substring bytes pos end))))
              (setq pos end)))
          events)
      (harness-acp-remote-decoder-free d))))

(ert-deftest harness-acp-remote-ws-round-trips ()
  "Masked frames decode back however the bytes are split."
  (let* ((key (harness-acp-remote-test-bytes 1 2 3 4))
         (text "héllo ✓ {\"jsonrpc\":\"2.0\"}")
         (big (make-string 70000 ?y))
         (bytes (concat (harness-acp-remote-ws-frame 'text text key)
                        (harness-acp-remote-ws-frame 'binary (harness-acp-remote-test-bytes 0 255 7) key)
                        (harness-acp-remote-ws-frame 'ping "p" key)
                        (harness-acp-remote-ws-frame 'text big key)
                        (harness-acp-remote-ws-close-frame-masked-for-test 1000 "bye" key)))
         (expected (list (cons 'text text)
                         (cons 'binary (harness-acp-remote-test-bytes 0 255 7))
                         (cons 'ping "p")
                         (cons 'text big)
                         (cons 'close (cons 1000 "bye")))))
    (should (equal expected (harness-acp-remote-test-chunked bytes (list (length bytes)))))
    (should (equal expected (harness-acp-remote-test-chunked bytes '(1))))
    (should (equal expected (harness-acp-remote-test-chunked bytes '(3 7 1 4096 2 13))))
    ;; A chunk as a process filter with `binary' coding may give it.
    (let ((d (harness-acp-remote-decoder)))
      (unwind-protect
          (should (equal (list (cons 'text text))
                         (harness-acp-remote-decode
                          d (decode-coding-string (harness-acp-remote-ws-frame 'text text key) 'binary))))
        (harness-acp-remote-decoder-free d)))))

(defun harness-acp-remote-ws-close-frame-masked-for-test (code reason key)
  "Return a masked close frame with CODE and REASON, KEY its mask."
  (harness-acp-remote-ws-frame 'close (concat (unibyte-string (ash code -8) (logand code 255)) reason) key))

(defun harness-acp-remote-test-error (bytes &rest decoder-args)
  "Return the close code of the error decoding BYTES gives, or nil."
  (let ((d (apply #'harness-acp-remote-decoder decoder-args)))
    (unwind-protect
        (let ((events (harness-acp-remote-decode d bytes)))
          (prog1 (cadr (assq 'error events))
            ;; Nothing comes after an error.
            (should (null (harness-acp-remote-decode d (harness-acp-remote-ws-frame
                                                        'text "x" (unibyte-string 1 2 3 4)))))))
      (harness-acp-remote-decoder-free d))))

(ert-deftest harness-acp-remote-ws-protocol-errors ()
  (let ((key (harness-acp-remote-test-bytes 9 9 9 9)))
    ;; A server refuses unmasked frames.
    (should (= 1002 (harness-acp-remote-test-error (harness-acp-remote-ws-frame 'text "a"))))
    ;; Reserved bits, an unknown opcode.
    (should (= 1002 (harness-acp-remote-test-error (harness-acp-remote-test-bytes #xc1 #x80 9 9 9 9))))
    (should (= 1002 (harness-acp-remote-test-error (harness-acp-remote-test-bytes #x83 #x80 9 9 9 9))))
    ;; Control frames: final, and at most 125 bytes.
    (should (= 1002 (harness-acp-remote-test-error (harness-acp-remote-test-bytes #x09 #x80 9 9 9 9))))
    (should (= 1002 (harness-acp-remote-test-error (harness-acp-remote-ws-frame 'ping (make-string 126 ?a) key))))
    ;; A continuation without a message, a message inside another.
    (should (= 1002 (harness-acp-remote-test-error (harness-acp-remote-ws-frame 'continuation "a" key))))
    (should (= 1002 (harness-acp-remote-test-error
                     (concat (harness-acp-remote-test-bytes #x01 #x81 9 9 9 9 ?a)
                             (harness-acp-remote-ws-frame 'text "b" key)))))
    ;; Too big, judged from the announced length alone.
    (should (= 1009 (harness-acp-remote-test-error (harness-acp-remote-ws-frame 'text "eleven byte" key)
                                                   :max-message 10)))
    (should (= 1009 (harness-acp-remote-test-error (harness-acp-remote-test-bytes #x82 #xff 0 0 0 1 0 0 0 0)
                                                   :max-message 1000)))
    ;; A 64-bit length with its top bit set.
    (should (= 1002 (harness-acp-remote-test-error (harness-acp-remote-test-bytes #x82 #xff #x80 0 0 0 0 0 0 1))))
    ;; A close frame with a one-byte payload.
    (should (= 1002 (harness-acp-remote-test-error (harness-acp-remote-ws-frame 'close "x" key))))
    ;; A freed decoder signals.
    (let ((d (harness-acp-remote-decoder)))
      (harness-acp-remote-decoder-free d)
      (should-error (harness-acp-remote-decode d "x")))))

(ert-deftest harness-acp-remote-ws-close-frames ()
  (let ((d (harness-acp-remote-decoder :require-mask nil)))
    (unwind-protect
        (progn
          (should (equal '((close 1001 . "going")) (harness-acp-remote-decode d (harness-acp-remote-ws-close-frame 1001 "going"))))
          (should (equal '((close nil . "")) (harness-acp-remote-decode d (harness-acp-remote-ws-frame 'close "")))))
      (harness-acp-remote-decoder-free d)))
  ;; A long reason is cut between characters, to 125 bytes at most.
  (let ((frame (harness-acp-remote-ws-close-frame 1000 (make-string 200 ?é))))
    (should (<= (aref frame 1) 125))
    (should (cl-evenp (- (aref frame 1) 2)))))

(ert-deftest harness-acp-remote-ws-large-message-is-linear ()
  "Five megabytes in 4 KB chunks decode quickly."
  (let* ((text (make-string (* 5 1024 1024) ?z))
         (bytes (harness-acp-remote-ws-frame 'text text (harness-acp-remote-test-bytes 7 7 7 7)))
         (start (float-time))
         (events (harness-acp-remote-test-chunked bytes '(4096))))
    (should (equal (list (cons 'text text)) events))
    (should (< (- (float-time) start) 5))))

;;;; HTTP requests

(defconst harness-acp-remote-test-upgrade
  (concat "GET /acp?token=a%20b&x HTTP/1.1\r\nHost: h:4276\r\nUpgrade: websocket\r\n"
          "Connection: keep-alive, Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
          "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: acp.v1, bearer.abc\r\n\r\n")
  "An upgrade request as a browser sends it.")

(ert-deftest harness-acp-remote-parse-request ()
  (should (null (harness-acp-remote-parse-request "GET / HTTP/1.1\r\nHost: h\r\n")))
  (let ((r (harness-acp-remote-parse-request (concat harness-acp-remote-test-upgrade "\x81\x80"))))
    (should (equal "GET" (plist-get r :method)))
    (should (equal "/acp" (plist-get r :path)))
    (should (equal '(("token" . "a b") ("x" . "")) (plist-get r :query)))
    (should (equal "\x81\x80" (plist-get r :rest)))
    (should (equal "websocket" (harness-acp-remote-header r "Upgrade")))
    (should (harness-acp-remote-ws-upgrade-p r))
    (should (equal '("acp.v1" "bearer.abc") (harness-acp-remote-ws-offered-protocols r)))
    (should (equal (concat "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
                           "Sec-WebSocket-Protocol: acp.v1\r\nAcp-Connection-Id: c1\r\n\r\n")
                   (harness-acp-remote-ws-handshake r "acp.v1" '(("Acp-Connection-Id" . "c1"))))))
  (should-not (harness-acp-remote-ws-upgrade-p
               (harness-acp-remote-parse-request "GET /acp HTTP/1.1\r\nHost: h\r\n\r\n")))
  (should-not (harness-acp-remote-ws-upgrade-p
               (harness-acp-remote-parse-request
                (replace-regexp-in-string "Version: 13" "Version: 8" harness-acp-remote-test-upgrade))))
  (should (equal '(:error 400) (harness-acp-remote-parse-request "nonsense\r\n\r\n")))
  (should (equal '(:error 431) (harness-acp-remote-parse-request (make-string 17000 ?a)))))


;;;; End to end

(defvar harness-acp-remote-test-port nil "Port of the listener in the test.")

(defmacro harness-acp-remote-test-with (&rest body)
  "Run BODY with a listener for other devices on 127.0.0.1."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (harness-acp-remote-test-load)
     (setq harness-acp--clients nil)
     (let ((harness-acp-token nil)
           (harness-acp-remote nil)
           (harness-acp-remote-host "127.0.0.1")
           (harness-acp-remote-port 0)
           (harness-acp-remote-address nil)
           (harness-acp-remote-public-url nil)
           (harness-acp-remote-approval t)
           (harness-acp-remote-approval-timeout 30)
           (harness-acp-remote--max-preauth 1000)
           (harness-acp-remote--max-preauth-per-address 1000)
           (harness-acp-remote-idle-timeout 3600)
           (harness-acp-remote-session-lifetime 86400)
           (harness-acp-remote-oidc-issuer nil)
           (harness-acp-remote-oidc-client-id nil)
           (harness-acp-remote-oidc-client-secret nil)
           (harness-acp-remote-oidc-allowed nil)
           (harness-corporate-mode nil))
       (setq harness-acp-remote--sessions nil harness-acp-remote--sessions-loaded nil
             harness-acp-remote--approvals nil harness-acp-remote--login-waits nil
             harness-acp-remote--logins nil harness-acp-remote--oidc-config nil)
       (clrhash harness-acp-remote--failures)
       (clrhash harness-acp-remote--requests)
       (harness-acp-remote--listen)
       (let ((harness-acp-remote-test-port (harness-acp-remote--port)))
         (unwind-protect (progn ,@body)
           (harness-acp-remote--stop)
           (dolist (c (copy-sequence harness-acp--clients)) (harness-acp-drop-client c)))))))

(cl-defstruct (harness-acp-remote-test-ws (:constructor harness-acp-remote-test--ws) (:copier nil))
  "A WebSocket client for the tests."
  proc (head "") status headers decoder messages events closed)

(defun harness-acp-remote-test--ws-feed (c chunk)
  "Decode CHUNK the server sent to C."
  (dolist (event (harness-acp-remote-decode (harness-acp-remote-test-ws-decoder c) chunk))
    (push event (harness-acp-remote-test-ws-events c))
    (when (eq (car event) 'text)
      (push (harness-json-parse (cdr event)) (harness-acp-remote-test-ws-messages c)))))

(cl-defun harness-acp-remote-test-connect (&key secret protocols headers (path "/acp"))
  "Open a WebSocket to the test listener; return the client once it answered.
SECRET, a session secret, is offered as the subprotocol bearer.SECRET
beside `acp.v1'; PROTOCOLS are offered as given; HEADERS, an alist, are
sent besides.  The answer is the status the server gave: 101 when the
WebSocket is open."
  (let* ((protocols (append (cond (protocols protocols) (secret '("acp.v1")))
                            (and secret (list (concat "bearer." secret)))))
         (c (harness-acp-remote-test--ws :decoder (harness-acp-remote-decoder :require-mask nil)))
         (proc (make-network-process
                :name "acp-remote-test-ws" :host "127.0.0.1" :service harness-acp-remote-test-port
                :coding 'binary :noquery t
                :filter (lambda (_p chunk)
                          (if (harness-acp-remote-test-ws-status c)
                              (harness-acp-remote-test--ws-feed c chunk)
                            (let* ((bytes (concat (harness-acp-remote-test-ws-head c) chunk))
                                   (end (string-search "\r\n\r\n" bytes)))
                              (if (null end)
                                  (setf (harness-acp-remote-test-ws-head c) bytes)
                                (let ((lines (split-string (substring bytes 0 end) "\r\n")))
                                  (string-match "\\`HTTP/1.1 \\([0-9]+\\)" (car lines))
                                  (setf (harness-acp-remote-test-ws-headers c) (cdr lines)
                                        (harness-acp-remote-test-ws-status c)
                                        (string-to-number (match-string 1 (car lines))))
                                  (harness-acp-remote-test--ws-feed c (substring bytes (+ end 4))))))))
                :sentinel (lambda (p _e) (unless (process-live-p p) (setf (harness-acp-remote-test-ws-closed c) t))))))
    (setf (harness-acp-remote-test-ws-proc c) proc)
    (process-send-string
     proc (concat (format "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\n" path)
                  "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                  "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
                  (if protocols (format "Sec-WebSocket-Protocol: %s\r\n" (string-join protocols ", ")) "")
                  (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) headers "")
                  "\r\n"))
    (harness-test-wait (lambda () (harness-acp-remote-test-ws-status c)) 15 "the handshake")
    c))

(defun harness-acp-remote-test-send (c object)
  "Send OBJECT, JSON-RPC, over C's WebSocket, masked as a client must."
  (process-send-string (harness-acp-remote-test-ws-proc c)
                       (harness-acp-remote-ws-frame 'text (concat (harness-json-encode object) "\n")
                                                    (unibyte-string 11 22 33 44))))

(defun harness-acp-remote-test-answer (c id)
  "Return the answer C received to request ID, or nil."
  (cl-find-if (lambda (m) (and (equal (plist-get m :id) id) (not (plist-get m :method))))
              (harness-acp-remote-test-ws-messages c)))

(defun harness-acp-remote-test-call (c id method &optional params)
  "Send request ID METHOD PARAMS over C and return the answer."
  (harness-acp-remote-test-send c (list :jsonrpc "2.0" :id id :method method :params (or params :empty)))
  (harness-test-wait (lambda () (harness-acp-remote-test-answer c id)) 15 method)
  (harness-acp-remote-test-answer c id))

(defun harness-acp-remote-test-code (answer)
  "Return the error code of ANSWER, or nil."
  (plist-get (plist-get answer :error) :code))

(defun harness-acp-remote-test-raw (c id)
  "Return the JSON text C received as the answer to request ID, or nil.
It is the text as it came, to see what a parsed answer cannot tell: an
empty array from null, an empty object from nothing."
  (cl-some (lambda (event)
             (and (eq (car event) 'text)
                  (string-prefix-p (format "{\"jsonrpc\":\"2.0\",\"id\":%d," id) (cdr event))
                  (cdr event)))
           (harness-acp-remote-test-ws-events c)))

(defun harness-acp-remote-test--http-complete-p (out)
  "Non-nil when OUT, bytes of an HTTP response, holds all of it."
  (let ((end (string-search "\r\n\r\n" out)))
    (and end
         (let ((len (and (string-match "Content-Length: \\([0-9]+\\)" out)
                         (string-to-number (match-string 1 out)))))
           (or (null len) (>= (- (length out) (+ end 4)) len))))))

(defun harness-acp-remote-test-http (text &optional chunks)
  "Send the request TEXT to the test listener; return (STATUS HEAD BODY).
CHUNKS, a list of strings, are sent after TEXT, a little apart."
  (let* ((out "") (done nil)
         (proc (make-network-process
                :name "acp-remote-test-http" :host "127.0.0.1" :service harness-acp-remote-test-port
                :coding 'binary :noquery t
                :filter (lambda (_p chunk) (setq out (concat out chunk)))
                :sentinel (lambda (p _e) (unless (process-live-p p) (setq done t))))))
    (ignore-errors (process-send-string proc text))
    (dolist (chunk chunks)
      (accept-process-output nil 0.1)
      (ignore-errors (process-send-string proc chunk)))
    (harness-test-wait (lambda () (or done (harness-acp-remote-test--http-complete-p out))) 15 "the response")
    (delete-process proc)
    (let ((end (string-search "\r\n\r\n" out)))
      (if (not (and end (string-match "\\`HTTP/1\\.[01] \\([0-9]+\\)" out)))
          ;; Closed without an answer.
          (list 0 "" "")
        (list (string-to-number (match-string 1 out)) (substring out 0 end)
              (decode-coding-string (substring out (+ end 4)) 'utf-8))))))

(defun harness-acp-remote-test-get (target &optional headers)
  "GET TARGET from the test listener; return (STATUS HEAD BODY).
HEADERS, an alist, are sent besides."
  (harness-acp-remote-test-http
   (format "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: test-phone\r\n%s\r\n" target
           (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) headers ""))))

(defun harness-acp-remote-test-post (target type body &optional headers)
  "POST BODY, of content type TYPE, to TARGET; return (STATUS HEAD BODY).
HEADERS, an alist, are sent besides."
  (harness-acp-remote-test-http
   (format "POST %s HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: test-phone\r\nContent-Type: %s\r\nContent-Length: %d\r\n%s\r\n%s"
           target type (string-bytes body)
           (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h))) headers "")
           (encode-coding-string body 'utf-8 t))))

(defun harness-acp-remote-test-post-json (target object)
  "POST OBJECT as JSON to TARGET; return (STATUS HEAD BODY)."
  (harness-acp-remote-test-post target "application/json" (harness-json-encode object)))

(defun harness-acp-remote-test-token (&optional name)
  "Make a session secret the way the Emacs on this machine does; return the answer."
  (harness-call 'acp/remote-create-token name))

(defun harness-acp-remote-test-secret (&optional name)
  "Make a device's session secret and return it.  NAME is what it is called."
  (plist-get (harness-acp-remote-test-token name) :token))

(defvar harness-acp-remote-test--id 1000 "The id of the last request `harness-acp-remote-test-ask' made.")

(defun harness-acp-remote-test-ask (c method &optional params)
  "Call METHOD with PARAMS over the WebSocket C, with an id of its own; return the answer."
  (harness-acp-remote-test-call c (cl-incf harness-acp-remote-test--id) method params))

(defun harness-acp-remote-test-signed-in-p (c)
  "Non-nil when the WebSocket C is open and may call the harness's methods."
  (and (eql 101 (harness-acp-remote-test-ws-status c))
       (not (harness-acp-remote-test-ws-closed c))
       (plist-get (harness-acp-remote-test-ask c "_harness/harness/version") :result)
       t))

(defun harness-acp-remote-test-devices ()
  "Return the devices the status lists."
  (plist-get (harness-call 'acp/remote-status) :devices))

(ert-deftest harness-acp-remote-answers-nothing-without-a-secret ()
  "A connection with no session may `initialize' and `authenticate', and nothing else."
  (harness-acp-remote-test-with
    ;; The WebSocket is let in, so that the client can sign in; that is all it can do.
    (let ((c (harness-acp-remote-test-connect :protocols '("acp.v1"))))
      (should (= 101 (harness-acp-remote-test-ws-status c)))
      (let ((init (plist-get (harness-acp-remote-test-ask c "initialize" '(:protocolVersion 1)) :result)))
        ;; What any ACP agent says of itself, the ways to sign in, and nothing of the harness.
        (should (= 1 (plist-get init :protocolVersion)))
        (should (equal "emacs-agent-harness" (plist-get (plist-get init :agentInfo) :name)))
        (should-not (plist-get (plist-get init :agentInfo) :version))
        (should-not (plist-member init :_harness))
        (should (plist-get (plist-get init :agentCapabilities) :loadSession))
        (should-not (plist-member (plist-get init :agentCapabilities) :auth))
        (should (equal '("emacs-approval") (mapcar (lambda (m) (plist-get m :id)) (plist-get init :authMethods)))))
      ;; Everything else is ACP's `auth_required', which lists the methods again.
      (dolist (method '("_harness/harness/version" "session/new" "session/list" "_harness/acp/remote-status"
                        "logout" "nothing/such"))
        (let ((e (plist-get (harness-acp-remote-test-ask c method '(:cwd "/tmp")) :error)))
          (should (= -32000 (plist-get e :code)))
          (should (string-search "Authentication required" (plist-get e :message)))
          (should (equal '("emacs-approval") (mapcar (lambda (m) (plist-get m :id))
                                                     (plist-get (plist-get e :data) :authMethods))))))
      ;; Heartbeats get no answer, and no session came of it.
      (harness-acp-remote-test-send c '(:jsonrpc "2.0" :method "$/ping"))
      (should (null (harness-acp-remote-test-devices)))
      (should-not (harness-acp-remote-test-signed-in-p c)))
    ;; Nothing else answers: no page, and none says what this is.
    (dolist (target '("/" "/acp" "/anything" "/session" "/pair" "/pair?code=abc" "/login" "/oidc/callback?code=x&state=y"))
      (pcase-let ((`(,status ,head ,body) (harness-acp-remote-test-get target)))
        (should (= 401 status))
        (should (string-match-p "WWW-Authenticate: Bearer" head))
        (should-not (string-search "ws://" body))
        (should-not (string-search (system-name) body))))
    (should (= 401 (car (harness-acp-remote-test-http
                         "POST /acp HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n"))))
    (should (= 401 (car (harness-acp-remote-test-http "POST /pair HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n"))))
    (should (= 401 (car (harness-acp-remote-test-http "DELETE /session HTTP/1.1\r\nHost: h\r\n\r\n"))))
    (should (null (harness-acp-remote-test-devices)))))

(ert-deftest harness-acp-remote-an-address-is-no-credential ()
  "A device is known by its secret, not by where it connects from.
Another app on the same device, at the same address, holds no secret."
  (harness-acp-remote-test-with
    (let ((secret (harness-acp-remote-test-secret)))
      (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
      (dolist (c (list (harness-acp-remote-test-connect)
                       (harness-acp-remote-test-connect :protocols '("acp.v1"))
                       (harness-acp-remote-test-connect :secret "hs1_nothing")
                       (harness-acp-remote-test-connect :secret "")
                       (harness-acp-remote-test-connect :path "/acp?token=nope")
                       (harness-acp-remote-test-connect :headers '(("Authorization" . "Bearer nope")))
                       (harness-acp-remote-test-connect :headers '(("Authorization" . "Basic dGVzdDp0ZXN0")))))
        (should-not (harness-acp-remote-test-signed-in-p c)))
      ;; The address is shown, and trusted with nothing.
      (should (equal "127.0.0.1" (plist-get (car (harness-acp-remote-test-devices)) :address)))
      (should (= 401 (car (harness-acp-remote-test-get "/")))))))

(ert-deftest harness-acp-remote-span-is-said-in-words ()
  (should (equal "30 days" (harness-acp-remote--span (* 30 86400))))
  (should (equal "1 day" (harness-acp-remote--span 86400)))
  (should (equal "36 hours" (harness-acp-remote--span (* 36 3600))))
  (should (equal "8 hours" (harness-acp-remote--span (* 8 3600))))
  (should (equal "90 minutes" (harness-acp-remote--span 5400)))
  (should (equal "45 seconds" (harness-acp-remote--span 45.2)))
  (should (equal "1 second" (harness-acp-remote--span 0))))

(ert-deftest harness-acp-remote-create-token-gives-a-secret ()
  "A token made in Emacs is a session secret, shown once, for a client that has a field for it."
  (harness-acp-remote-test-with
    (let ((token (harness-acp-remote-test-token "Pixel 8")))
      (should (string-match-p "\\`hs1_[A-Za-z0-9_-]\\{43\\}\\'" (plist-get token :token)))
      (should (equal "Pixel 8" (plist-get token :name)))
      (should (equal (format "ws://127.0.0.1:%d/acp" harness-acp-remote-test-port) (plist-get token :ws-url)))
      (should (equal (format "%s?token=%s" (plist-get token :ws-url) (plist-get token :token)) (plist-get token :url)))
      (should (numberp (plist-get token :expires)))
      ;; Only its hash is kept, and the status says who has one.
      (let ((device (car (harness-acp-remote-test-devices))))
        (should (equal (plist-get token :id) (plist-get device :id)))
        (should (equal "token" (plist-get device :method)))
        (should (eq :false (plist-get device :ephemeral)))
        (should-not (string-search (plist-get token :token) (format "%S" (harness-call 'acp/remote-status)))))
      ;; It opens the WebSocket as a header, a subprotocol or an address would.
      (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret (plist-get token :token))))
      (should (harness-acp-remote-test-signed-in-p
               (harness-acp-remote-test-connect :path (format "/acp?token=%s" (plist-get token :token)))))
      (let ((c (harness-acp-remote-test-connect :secret (plist-get token :token))))
        (should (equal "Pixel 8" (plist-get (car (harness-acp-remote-test-devices)) :name)))
        (should (plist-get (harness-acp-remote-test-ask c "initialize" '(:protocolVersion 1)) :result))))
    ;; A name is optional, and the harness must be serving.
    (should (equal "Token" (plist-get (harness-acp-remote-test-token) :name)))
    (harness-acp-remote--stop)
    (should-error (harness-acp-remote-test-token) :type 'harness-error)))

;;;; Signing in from the client

;; The client opens the WebSocket with nothing, `initialize's, is told
;; `auth_required' by `session/new', shows the methods to its user, and
;; calls `authenticate' with the one chosen: the flow of ACP UI.

(defun harness-acp-remote-test-start-sign-in (c &optional capabilities)
  "Make the client C, which has no session, call `initialize' and ask to be approved.
CAPABILITIES are its `clientCapabilities'.  Return the id of its `authenticate'
request, which is left waiting, and the waiting approval (a plist the status gives)."
  (harness-acp-remote-test-ask c "initialize"
                               (list :protocolVersion 1 :clientCapabilities (or capabilities '(:fs (:readTextFile :false)))
                                     :clientInfo '(:name "acp-ui" :title "ACP UI" :version "0.9.1")))
  (let ((id (cl-incf harness-acp-remote-test--id))
        (before (length harness-acp-remote--approvals)))
    (harness-acp-remote-test-send c (list :jsonrpc "2.0" :id id :method "authenticate"
                                          :params '(:methodId "emacs-approval")))
    (harness-test-wait (lambda () (> (length harness-acp-remote--approvals) before)) 15 "the approval")
    (cons id (car (plist-get (harness-call 'acp/remote-status) :approvals)))))

(ert-deftest harness-acp-remote-the-client-signs-in-by-an-approval-in-emacs ()
  "The user taps \"Approve in Emacs\" in the client and presses Approve in Emacs."
  (harness-acp-remote-test-with
    (let* ((c (harness-acp-remote-test-connect :protocols '("acp.v1")))
           (init (plist-get (harness-acp-remote-test-ask c "initialize"
                                                         '(:protocolVersion 1 :clientInfo (:name "acp-ui" :title "ACP UI" :version "0.9.1")))
                            :result))
           (method (car (plist-get init :authMethods))))
      ;; The client shows the method and its description, which holds the code to compare.
      (should (equal "Approve in Emacs" (plist-get method :name)))
      (should (string-match "code \\([0-9]\\{4\\}\\)" (plist-get method :description)))
      (let ((code (match-string 1 (plist-get method :description)))
            (id (cl-incf harness-acp-remote-test--id)))
        ;; `session/new' is refused until it signs in.
        (should (= -32000 (plist-get (plist-get (harness-acp-remote-test-ask c "session/new" '(:cwd "/tmp")) :error) :code)))
        ;; It asks; the request waits for the person at Emacs.
        (harness-acp-remote-test-send c (list :jsonrpc "2.0" :id id :method "authenticate"
                                              :params '(:methodId "emacs-approval")))
        (harness-test-wait (lambda () (plist-get (harness-call 'acp/remote-status) :approvals)) 15 "the approval")
        (let ((approval (car (plist-get (harness-call 'acp/remote-status) :approvals))))
          ;; Emacs shows what asks, and the code that must match the client's.
          (should (equal code (plist-get approval :code)))
          (should (equal "ACP UI 0.9.1" (plist-get approval :name)))
          (should (equal "127.0.0.1" (plist-get approval :address)))
          (should (numberp (plist-get approval :expires)))
          (should-not (harness-acp-remote-test-answer c id))
          (should-not (harness-acp-remote-test-signed-in-p c))
          (should (eq t (harness-call 'acp/remote-approve (plist-get approval :id))))
          (harness-test-wait (lambda () (harness-acp-remote-test-answer c id)) 15 "the answer to authenticate")
          (should (equal "{}" (substring (harness-acp-remote-test-raw c id) -3 -1)))
          (should-not (plist-get (harness-acp-remote-test-answer c id) :error)))
        ;; Now it is signed in: sessions may be made, and the status shows a device of its connection.
        (should (harness-acp-remote-test-signed-in-p c))
        (let ((device (car (harness-acp-remote-test-devices))))
          (should (equal "approval" (plist-get device :method)))
          (should (eq t (plist-get device :ephemeral)))
          (should (equal "ACP UI 0.9.1" (plist-get device :name)))
          (should (= 1 (plist-get device :connected)))
          (should-not (plist-get device :expires)))
        (should (null (plist-get (harness-call 'acp/remote-status) :approvals)))
        ;; A new `initialize' now gives the full answer, and `logout' to end it.
        (let ((init (plist-get (harness-acp-remote-test-ask c "initialize" '(:protocolVersion 1)) :result)))
          (should (plist-get init :_harness))
          (should (null (plist-get init :authMethods)))
          (should (plist-member (plist-get init :agentCapabilities) :auth)))
        ;; The secret of such a session is given to nobody, and the session ends with the connection.
        (should-not (plist-member (plist-get (harness-acp-remote-test-answer c id) :result) :_meta))
        (delete-process (harness-acp-remote-test-ws-proc c))
        (harness-test-wait (lambda () (null (harness-acp-remote-test-devices))) 15 "the session to end")))))

(ert-deftest harness-acp-remote-an-approval-can-be-refused-or-run-out ()
  (harness-acp-remote-test-with
    ;; Refused in Emacs.
    (let* ((c (harness-acp-remote-test-connect))
           (started (harness-acp-remote-test-start-sign-in c)))
      (should (eq t (harness-call 'acp/remote-deny (plist-get (cdr started) :id))))
      (harness-test-wait (lambda () (harness-acp-remote-test-answer c (car started))) 15 "the answer")
      (let ((e (plist-get (harness-acp-remote-test-answer c (car started)) :error)))
        (should (= -32000 (plist-get e :code)))
        (should (string-search "refused" (plist-get e :message))))
      (should (null (plist-get (harness-call 'acp/remote-status) :approvals)))
      (should-not (harness-acp-remote-test-signed-in-p c))
      (should-error (harness-call 'acp/remote-approve (plist-get (cdr started) :id)) :type 'harness-error)
      (should-error (harness-call 'acp/remote-deny "nobody") :type 'harness-error))
    ;; Nobody answered in time.
    (let ((harness-acp-remote-approval-timeout 0.3)
          (c (harness-acp-remote-test-connect)))
      (let ((started (harness-acp-remote-test-start-sign-in c)))
        (harness-test-wait (lambda () (harness-acp-remote-test-answer c (car started))) 15 "the answer")
        (let ((e (plist-get (harness-acp-remote-test-answer c (car started)) :error)))
          (should (= -32000 (plist-get e :code)))
          (should (string-search "in time" (plist-get e :message))))
        (should (null (plist-get (harness-call 'acp/remote-status) :approvals)))
        ;; It may ask again.
        (let ((again (harness-acp-remote-test-start-sign-in c)))
          (should (plist-get (cdr again) :id)))))
    ;; The device left before anybody answered: the request goes, and cannot be approved.
    (let* ((c (harness-acp-remote-test-connect))
           (started (harness-acp-remote-test-start-sign-in c)))
      (delete-process (harness-acp-remote-test-ws-proc c))
      (harness-test-wait (lambda () (null (plist-get (harness-call 'acp/remote-status) :approvals))) 15
                         "the request to go")
      (should-error (harness-call 'acp/remote-approve (plist-get (cdr started) :id)) :type 'harness-error)
      (should (null (harness-acp-remote-test-devices))))))

(ert-deftest harness-acp-remote-approval-asks-little-of-emacs ()
  "A device may not flood the person at Emacs with requests."
  (harness-acp-remote-test-with
    ;; One request at a time from a connection.
    (let* ((c (harness-acp-remote-test-connect))
           (_ (harness-acp-remote-test-start-sign-in c))
           (e (plist-get (harness-acp-remote-test-ask c "authenticate" '(:methodId "emacs-approval")) :error)))
      (should (string-search "already waits" (plist-get e :message))))
    ;; Only so many wait together.
    (let ((harness-acp-remote--max-waiting 2))
      (harness-acp-remote-test-start-sign-in (harness-acp-remote-test-connect))
      (should (= 2 (length harness-acp-remote--approvals)))
      (let ((e (plist-get (harness-acp-remote-test-ask (harness-acp-remote-test-connect) "authenticate"
                                                       '(:methodId "emacs-approval"))
                          :error)))
        (should (string-search "Too many devices" (plist-get e :message)))))
    (dolist (a (copy-sequence harness-acp-remote--approvals))
      (harness-call 'acp/remote-deny (plist-get a :id)))
    ;; And an address may ask only so often: a request counts, and so does a refusal of it.
    (let ((harness-acp-remote--max-requests 4))
      (clrhash harness-acp-remote--requests)
      (dotimes (_ 2)
        (let* ((c (harness-acp-remote-test-connect))
               (started (harness-acp-remote-test-start-sign-in c)))
          (harness-call 'acp/remote-deny (plist-get (cdr started) :id))))
      (let ((e (plist-get (harness-acp-remote-test-ask (harness-acp-remote-test-connect) "authenticate"
                                                       '(:methodId "emacs-approval"))
                          :error)))
        (should (string-search "Too many requests" (plist-get e :message)))))
    ;; Turned off, it is not offered and not done.
    (clrhash harness-acp-remote--requests)
    (let ((harness-acp-remote-approval nil)
          (c (harness-acp-remote-test-connect)))
      (should (null (plist-get (plist-get (harness-acp-remote-test-ask c "initialize" '(:protocolVersion 1)) :result)
                               :authMethods)))
      (should (string-search "turned off"
                             (plist-get (plist-get (harness-acp-remote-test-ask c "authenticate"
                                                                                '(:methodId "emacs-approval"))
                                                   :error)
                                        :message))))))

(ert-deftest harness-acp-remote-the-user-is-told-that-a-device-asks ()
  (harness-acp-remote-test-with
    (let ((sent nil)
          (events nil))
      (harness-register-method 'notification/send (lambda (notification &optional _providers) (push notification sent) t))
      (unwind-protect
          (progn
            (harness-on 'acp/remote-changed (lambda (e) (push (plist-get e :what) events)))
            (let* ((c (harness-acp-remote-test-connect))
                   (started (harness-acp-remote-test-start-sign-in c)))
              (should (member "approval" events))
              (should (= 1 (length sent)))
              (let ((n (car sent)))
                (should (equal "acp-remote" (plist-get n :source)))
                (should (equal "approval" (plist-get n :kind)))
                (should (string-search (plist-get (cdr started) :code) (plist-get n :body)))
                (should (string-search "ACP UI" (plist-get n :body))))))
        (harness-unregister-method 'notification/send)))))

(ert-deftest harness-acp-remote-what-a-device-says-of-itself-is-shown-as-words ()
  "Whatever a client puts in `clientInfo' or in its headers, Emacs shows the user plain, short text."
  (harness-acp-remote-test-with
    (let ((sent nil))
      (harness-register-method 'notification/send (lambda (notification &optional _providers) (push notification sent) t))
      (unwind-protect
          (let* ((c (harness-acp-remote-test-connect
                     :headers `(("Origin" . ,(concat "https://pages.example/\a\t" (make-string 200 ?x)))
                                ("User-Agent" . "Test/1.0"))))
                 (id (cl-incf harness-acp-remote-test--id)))
            ;; Neither number, object nor list is a name: the label falls back to the connection's.
            (harness-acp-remote-test-ask c "initialize"
                                         '(:protocolVersion 1 :clientInfo (:name 12 :title (:a 1) :version ["x"])))
            (harness-acp-remote-test-send c (list :jsonrpc "2.0" :id id :method "authenticate"
                                                  :params '(:methodId "emacs-approval")))
            (harness-test-wait (lambda () harness-acp-remote--approvals) 15 "the approval")
            (let ((approval (car (plist-get (harness-call 'acp/remote-status) :approvals))))
              (should (equal "Test/1.0" (plist-get approval :name)))
              (should (string-prefix-p "https://pages.example/ " (plist-get approval :origin)))
              (should (<= (length (plist-get approval :origin)) 60))
              (should-not (string-match-p "[[:cntrl:]]" (plist-get approval :origin)))
              ;; The notification names the page too.
              (should (string-search (format "from the page %s" (plist-get approval :origin))
                                     (plist-get (car sent) :body)))))
        (harness-unregister-method 'notification/send)))))

(ert-deftest harness-acp-remote-approving-a-device-that-got-in-meanwhile-makes-no-second-session ()
  "The device signed in with a secret while its request waited: the person's approval adds nothing."
  (harness-acp-remote-test-with
    (let* ((secret (harness-acp-remote-test-secret "phone"))
           (c (harness-acp-remote-test-connect))
           (started (harness-acp-remote-test-start-sign-in c)))
      (should-not (plist-get (harness-acp-remote-test-ask c "authenticate" (list :methodId "token" :token secret))
                             :error))
      (should (harness-acp-remote-test-signed-in-p c))
      (should (= 1 (length (harness-acp-remote-test-devices))))
      (harness-call 'acp/remote-approve (plist-get (cdr started) :id))
      (harness-test-wait (lambda () (harness-acp-remote-test-answer c (car started))) 15 "the answer")
      (should-not (plist-get (harness-acp-remote-test-answer c (car started)) :error))
      (should (harness-acp-remote-test-signed-in-p c))
      (let ((devices (harness-acp-remote-test-devices)))
        (should (= 1 (length devices)))
        (should (equal "phone" (plist-get (car devices) :name)))))))

(ert-deftest harness-acp-remote-a-client-that-keeps-secrets-is-handed-one ()
  "The harness's own app can keep a secret: it is given one, and signs in with it next time."
  (harness-acp-remote-test-with
    (let* ((c (harness-acp-remote-test-connect))
           (started (harness-acp-remote-test-start-sign-in c '(:_harness (:sessionRefresh t)))))
      (harness-call 'acp/remote-approve (plist-get (cdr started) :id))
      (harness-test-wait (lambda () (harness-acp-remote-test-answer c (car started))) 15 "the answer")
      (let* ((result (plist-get (harness-acp-remote-test-answer c (car started)) :result))
             (session (plist-get (plist-get (plist-get result :_meta) :harness) :session))
             (secret (plist-get session :token)))
        (should (string-match-p "\\`hs1_[A-Za-z0-9_-]\\{43\\}\\'" secret))
        (should (= 3600 (plist-get session :idleTimeout)))
        (should (= 86400 (plist-get session :lifetime)))
        (should (stringp (plist-get session :expires)))
        (should (equal "approval" (plist-get (car (harness-acp-remote-test-devices)) :method)))
        (should (eq :false (plist-get (car (harness-acp-remote-test-devices)) :ephemeral)))
        (should (equal (plist-get session :deviceId) (plist-get (car (harness-acp-remote-test-devices)) :id)))
        ;; Only its hash is kept, in a file that survives the connection.
        (let ((text (with-temp-buffer (insert-file-contents (harness-acp-remote--sessions-file)) (buffer-string))))
          (should-not (string-search secret text))
          (should (string-search (harness-acp-remote--hash secret) text)))
        ;; It is no longer asked: the next connection signs in with the secret.
        (delete-process (harness-acp-remote-test-ws-proc c))
        (should (= 1 (length (harness-acp-remote-test-devices))))
        (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
        (should (null (plist-get (harness-call 'acp/remote-status) :approvals)))))))

(ert-deftest harness-acp-remote-the-token-method-takes-a-secret-or-the-shared-secret ()
  "A client that can send a secret in `authenticate' is offered `token'; plain TCP always is."
  (harness-acp-remote-test-with
    (let ((harness-acp-token "a-shared-secret-of-some-length")
          (secret (harness-acp-remote-test-secret)))
      ;; Not offered to a client that cannot send one ...
      (let ((c (harness-acp-remote-test-connect)))
        (should (equal '("emacs-approval")
                       (mapcar (lambda (m) (plist-get m :id))
                               (plist-get (plist-get (harness-acp-remote-test-ask c "initialize" '(:protocolVersion 1)) :result)
                                          :authMethods)))))
      ;; ... but to one that says it keeps secrets.
      (let* ((c (harness-acp-remote-test-connect))
             (init (plist-get (harness-acp-remote-test-ask
                               c "initialize" '(:protocolVersion 1 :clientCapabilities (:_harness (:sessionRefresh t))))
                              :result)))
        (should (equal '("emacs-approval" "token") (mapcar (lambda (m) (plist-get m :id)) (plist-get init :authMethods))))
        ;; A session secret it holds signs it in; one that is no session's does not.
        (should (plist-get (harness-acp-remote-test-ask c "authenticate" '(:methodId "token" :token "hs1_nothing")) :error))
        (should-not (plist-get (harness-acp-remote-test-ask c "authenticate" (list :methodId "token" :token secret)) :error))
        (should (harness-acp-remote-test-signed-in-p c)))
      ;; The shared secret is traded for a session of its own, whose secret the client keeps.
      (let ((c (harness-acp-remote-test-connect)))
        (harness-acp-remote-test-ask c "initialize" '(:protocolVersion 1 :clientCapabilities (:_harness (:sessionRefresh t))))
        (let* ((answer (harness-acp-remote-test-ask c "authenticate" (list :methodId "token" :token harness-acp-token)))
               (session (plist-get (plist-get (plist-get (plist-get answer :result) :_meta) :harness) :session)))
          (should-not (plist-get answer :error))
          (should (string-prefix-p "hs1_" (plist-get session :token)))
          (should-not (equal harness-acp-token (plist-get session :token)))
          (should (harness-acp-remote-test-signed-in-p c))
          (should (cl-find "shared-secret" (harness-acp-remote-test-devices)
                           :key (lambda (d) (plist-get d :method)) :test #'equal))
          (should (harness-acp-remote-test-signed-in-p
                   (harness-acp-remote-test-connect :secret (plist-get session :token))))))
      ;; Over the WebSocket's own address the shared secret is no bearer.
      (should-not (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret harness-acp-token)))
      (should-not (harness-acp-remote-test-signed-in-p
                   (harness-acp-remote-test-connect :path (format "/acp?token=%s" harness-acp-token))))
      (pcase-let ((`(,status ,head ,body)
                   (harness-acp-remote-test-get "/" `(("Authorization" . ,(concat "Bearer " harness-acp-token))))))
        (should (= 401 status))
        (should (string-match-p "invalid_token" head))
        (should (string-search "shared secret" body)))
      ;; One too short to be a secret trades for nothing.
      (let ((harness-acp-token "short")
            (c (harness-acp-remote-test-connect)))
        (harness-acp-remote-test-ask c "initialize" '(:protocolVersion 1 :clientCapabilities (:_harness (:sessionRefresh t))))
        (should (plist-get (harness-acp-remote-test-ask c "authenticate" '(:methodId "token" :token "short")) :error))))))

(ert-deftest harness-acp-remote-refused-secrets-make-an-address-wait ()
  (harness-acp-remote-test-with
    (let ((secret (harness-acp-remote-test-secret)))
      (dotimes (_ harness-acp-remote--max-failures)
        (should-not (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret "hs1_wrong"))))
      ;; Even the right secret is not looked at while the address waits.
      (let ((c (harness-acp-remote-test-connect :secret secret)))
        (should (= 429 (harness-acp-remote-test-ws-status c)))
        (should (cl-some (lambda (h) (string-prefix-p "Retry-After: " h)) (harness-acp-remote-test-ws-headers c))))
      (should (= 1 (length (harness-acp-remote-test-devices))))
      ;; The wait ends.
      (let ((harness-acp-remote--failure-window 0))
        (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))))))

(ert-deftest harness-acp-remote-connections-with-no-session-are-few-and-short ()
  "They may not take the harness's connections, or its memory, or stay for ever."
  (harness-acp-remote-test-with
    ;; So many together, of one address and of all.
    (let ((harness-acp-remote--max-preauth-per-address 2)
          (open nil))
      (dotimes (_ 2) (push (harness-acp-remote-test-connect) open))
      (should (= 429 (harness-acp-remote-test-ws-status (harness-acp-remote-test-connect))))
      ;; A device that signs in with its secret takes no place of theirs.
      (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret (harness-acp-remote-test-secret))))
      (mapc (lambda (c) (delete-process (harness-acp-remote-test-ws-proc c))) open))
    (harness-test-wait (lambda () (null (harness-acp-remote--preauth-clients))) 15 "the connections to go")
    (let ((harness-acp-remote--max-preauth 1)
          (c (harness-acp-remote-test-connect)))
      (should (= 429 (harness-acp-remote-test-ws-status (harness-acp-remote-test-connect))))
      (delete-process (harness-acp-remote-test-ws-proc c)))
    (harness-test-wait (lambda () (null (harness-acp-remote--preauth-clients))) 15 "the connection to go")
    ;; A message of a connection with no session stays small; with a session it need not.
    (let ((c (harness-acp-remote-test-connect)))
      (process-send-string (harness-acp-remote-test-ws-proc c)
                           (harness-acp-remote-ws-frame 'text (concat "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"x\":\""
                                                                      (make-string 70000 ?a) "\"}}")
                                                        (unibyte-string 1 2 3 4)))
      (harness-test-wait (lambda () (harness-acp-remote-test-ws-closed c)) 15 "the connection to close")
      (should (equal 1009 (cadr (assq 'close (harness-acp-remote-test-ws-events c))))))
    (let ((c (harness-acp-remote-test-connect :secret (harness-acp-remote-test-secret))))
      (harness-acp-remote-test-send c (list :jsonrpc "2.0" :method "$/ping" :params (list :x (make-string 70000 ?a))))
      (should (harness-acp-remote-test-signed-in-p c)))
    ;; And one that does nothing to sign in is closed in time.
    (harness-test-with-clock
      (let ((harness-acp-remote--preauth-timeout 30)
            (c (harness-acp-remote-test-connect)))
        (cl-incf harness-test-clock-offset 31)
        (harness-acp-remote--close-idle)
        (harness-test-wait (lambda () (harness-acp-remote-test-ws-closed c)) 15 "the connection to close")))
    ;; One that asks to sign in has the time it takes, from its last try.
    (harness-test-with-clock
      (let ((harness-acp-remote--preauth-timeout 30)
            (c (harness-acp-remote-test-connect)))
        (cl-incf harness-test-clock-offset 25)
        (harness-acp-remote-test-start-sign-in c)
        (cl-incf harness-test-clock-offset 10)
        (harness-acp-remote--close-idle)
        (should-not (harness-acp-remote-test-ws-closed c))))))

(ert-deftest harness-acp-remote-a-connection-with-no-session-hears-nothing-of-the-harness ()
  "No session update, event or request reaches a client that has not signed in, and it answers for nothing."
  (harness-acp-remote-test-with
    (let ((in (harness-acp-remote-test-connect :secret (harness-acp-remote-test-secret)))
          (out (harness-acp-remote-test-connect)))
      (harness-acp-remote-test-ask in "initialize" '(:protocolVersion 1))
      (harness-acp-remote-test-ask out "initialize" '(:protocolVersion 1))
      (harness-acp--broadcast "_harness/event" (list :event "secret/event" :args (list "private")))
      (harness-acp--broadcast-update "s-1" (list :sessionUpdate "agent_message_chunk"
                                                 :content (list :type "text" :text "from a private session")))
      (harness-test-wait (lambda () (cl-find "_harness/event" (harness-acp-remote-test-ws-messages in)
                                             :key (lambda (m) (plist-get m :method)) :test #'equal))
                         15 "the event")
      (harness-test-wait (lambda () (cl-find "session/update" (harness-acp-remote-test-ws-messages in)
                                             :key (lambda (m) (plist-get m :method)) :test #'equal))
                         15 "the update")
      (sleep-for 0.2)
      (should-not (cl-find-if (lambda (m) (plist-get m :method)) (harness-acp-remote-test-ws-messages out)))
      ;; A request the harness makes of its clients, a permission request, goes to the one that signed in.
      (let ((answers nil))
        (harness-acp--request-clients "session/request_permission" (list :sessionId "s-1")
                                      (lambda (result) (push result answers)))
        (harness-test-wait (lambda () (cl-find "session/request_permission" (harness-acp-remote-test-ws-messages in)
                                               :key (lambda (m) (plist-get m :method)) :test #'equal))
                           15 "the request")
        (sleep-for 0.2)
        (should-not (cl-find-if (lambda (m) (plist-get m :method)) (harness-acp-remote-test-ws-messages out)))
        ;; What the one that signed in answers counts; an answer from the other would not.
        (let ((request (cl-find "session/request_permission" (harness-acp-remote-test-ws-messages in)
                                :key (lambda (m) (plist-get m :method)) :test #'equal)))
          (harness-acp-remote-test-send out (list :jsonrpc "2.0" :id (plist-get request :id) :result '(:outcome "x")))
          (sleep-for 0.2)
          (should (null answers)))))
    ;; Nor does it count among the clients a UI chore is asked of.
    (should (= 1 (length (harness-acp--serving-clients))))))

(ert-deftest harness-acp-remote-secret-carriers ()
  "The secret is read from the subprotocol, the Authorization header or the query."
  (harness-acp-remote-test-with
    (let ((secret (harness-acp-remote-test-secret)))
      (dolist (c (list (harness-acp-remote-test-connect :secret secret)
                       (harness-acp-remote-test-connect :protocols (list (concat "bearer." secret)))
                       (harness-acp-remote-test-connect :path (format "/acp?token=%s" secret))
                       (harness-acp-remote-test-connect :headers `(("Authorization" . ,(concat "Bearer " secret))))
                       (harness-acp-remote-test-connect :headers `(("authorization" . ,(concat "bearer " secret))))))
        (should (= 101 (harness-acp-remote-test-ws-status c)))
        (should (plist-get (harness-acp-remote-test-call c 1 "_harness/harness/version") :result)))
      ;; A good secret among bad ones is found.
      (should (= 101 (harness-acp-remote-test-ws-status
                      (harness-acp-remote-test-connect :protocols (list "acp.v1" "bearer.junk"
                                                                        (concat "bearer." secret))))))
      ;; The page of a client that has one.
      (pcase-let ((`(,status ,_ ,body) (harness-acp-remote-test-get
                                        "/" `(("Authorization" . ,(concat "Bearer " secret))))))
        (should (= 200 status))
        (should (string-search "Signed in as Token" body)))
      (should (= 404 (car (harness-acp-remote-test-get "/nothing" `(("Authorization" . ,(concat "Bearer " secret))))))))))

(ert-deftest harness-acp-remote-secret-is-checked-at-every-message ()
  "A session that is gone stops its connection at the next message."
  (harness-acp-remote-test-with
    (let* ((secret (harness-acp-remote-test-secret))
           (c (harness-acp-remote-test-connect :secret secret)))
      (should (plist-get (harness-acp-remote-test-call c 1 "_harness/harness/version") :result))
      ;; Ended behind the connection's back: the next message is refused.
      (let ((sessions harness-acp-remote--sessions))
        (setq harness-acp-remote--sessions nil)
        (should (= -32000 (harness-acp-remote-test-code (harness-acp-remote-test-call c 2 "_harness/harness/version"))))
        (setq harness-acp-remote--sessions sessions))
      (should (plist-get (harness-acp-remote-test-call c 3 "_harness/harness/version") :result)))))

(ert-deftest harness-acp-remote-revoking-ends-connections ()
  (harness-acp-remote-test-with
    (let* ((secret (harness-acp-remote-test-secret))
           (other (harness-acp-remote-test-secret))
           (c1 (harness-acp-remote-test-connect :secret secret))
           (c2 (harness-acp-remote-test-connect :secret secret))
           (c3 (harness-acp-remote-test-connect :secret other)))
      (should (= 2 (length (harness-acp-remote-test-devices))))
      (let ((device (cl-find (harness-acp-remote--hash secret) harness-acp-remote--sessions
                             :key (lambda (s) (plist-get s :hash)) :test #'equal)))
        (should (eq t (harness-call 'acp/remote-revoke (plist-get device :id)))))
      (harness-test-wait (lambda () (and (harness-acp-remote-test-ws-closed c1)
                                         (harness-acp-remote-test-ws-closed c2)))
                         15 "the connections to close")
      (should-not (harness-acp-remote-test-ws-closed c3))
      (should (= 1 (length (harness-acp-remote-test-devices))))
      (should-not (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
      (should (plist-get (harness-acp-remote-test-call c3 1 "_harness/harness/version") :result))
      (should-error (harness-call 'acp/remote-revoke "nobody") :type 'harness-error)
      ;; All at once.
      (should (= 1 (harness-call 'acp/remote-revoke-all)))
      (harness-test-wait (lambda () (harness-acp-remote-test-ws-closed c3)) 15 "the last connection to close")
      (should (null (harness-acp-remote-test-devices))))))

(ert-deftest harness-acp-remote-sessions-persist-as-hashes ()
  "A restart leaves devices signed in; the file holds no secret."
  (harness-acp-remote-test-with
    (let* ((secret (harness-acp-remote-test-secret "Kept"))
           (file (harness-acp-remote--sessions-file)))
      (should (file-exists-p file))
      (should (= #o600 (logand #o777 (file-modes file))))
      (let ((text (with-temp-buffer (insert-file-contents file) (buffer-string))))
        (should-not (string-search secret text))
        (should-not (string-search (substring secret 4) text))
        (should (string-search (harness-acp-remote--hash secret) text))
        (should (string-search "\"Kept\"" text)))
      ;; Stopping serving keeps them; so does starting again.
      (harness-acp-remote--stop)
      (should (= 1 (length harness-acp-remote--sessions)))
      (setq harness-acp-remote--sessions nil harness-acp-remote--sessions-loaded nil)
      (harness-acp-remote--listen)
      (setq harness-acp-remote-test-port (harness-acp-remote--port))
      (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
      (should (equal "Kept" (plist-get (car (harness-acp-remote-test-devices)) :name)))
      ;; A file that is not ours is ignored, not trusted.
      (dolist (junk '("(:version 2 :sessions nil)" "garbage ((" "(:version 1 :sessions ((:id 1)))" ""))
        (write-region junk nil file nil 'quiet)
        (setq harness-acp-remote--sessions nil harness-acp-remote--sessions-loaded nil)
        (harness-acp-remote--load-sessions)
        (should (null harness-acp-remote--sessions)))
      ;; Sessions that ran out while the harness was off are not loaded.
      (setq harness-acp-remote--sessions (list (list :id "old" :hash (make-string 64 ?a) :name "Old" :created 1.0 :seen 1.0)))
      (harness-acp-remote--save-sessions)
      (setq harness-acp-remote--sessions nil harness-acp-remote--sessions-loaded nil)
      (harness-acp-remote--load-sessions)
      (should (null harness-acp-remote--sessions)))))

(ert-deftest harness-acp-remote-sessions-run-out ()
  (harness-acp-remote-test-with
    ;; Unused for too long, with nothing connected.
    (let ((secret (harness-acp-remote-test-secret)))
      (plist-put (car harness-acp-remote--sessions) :seen (- (float-time) 7200))
      (should-not (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
      (should (null (harness-acp-remote-test-devices))))
    ;; In use, a connection open: idleness does not end it ...
    (let* ((secret (harness-acp-remote-test-secret))
           (c (harness-acp-remote-test-connect :secret secret)))
      (plist-put (car harness-acp-remote--sessions) :seen (- (float-time) 7200))
      (should (= 1 (length (harness-acp-remote-test-devices))))
      (should (plist-get (harness-acp-remote-test-call c 1 "_harness/harness/version") :result))
      ;; ... but the age of its secret does, whatever it does.
      (plist-put (car harness-acp-remote--sessions) :rotated (- (float-time) 100000))
      (harness-acp-remote-test-send c '(:jsonrpc "2.0" :id 2 :method "_harness/harness/version" :params (:x 1)))
      (harness-test-wait (lambda () (harness-acp-remote-test-ws-closed c)) 15 "the connection to close")
      (should (null (harness-acp-remote-test-devices)))
      (should-not (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret))))
    ;; The sweep closes connections of sessions that ended, without a message.
    (let* ((secret (harness-acp-remote-test-secret))
           (c (harness-acp-remote-test-connect :secret secret)))
      (plist-put (car harness-acp-remote--sessions) :rotated (- (float-time) 100000))
      (harness-acp-remote--sweep)
      (harness-test-wait (lambda () (harness-acp-remote-test-ws-closed c)) 15 "the connection to close"))))

(ert-deftest harness-acp-remote-lifetime-counts-from-the-current-secret ()
  "A device that takes replacements pairs once; one that does not pairs again."
  (harness-acp-remote-test-with
    (let ((harness-acp-remote-rotate-after 100))
      ;; Signed in long ago, its secret replaced a moment ago: nothing ends.
      (let* ((secret (harness-acp-remote-test-secret))
             (session (car harness-acp-remote--sessions)))
        (plist-put session :created (- (float-time) 1000000))
        (plist-put session :rotated (- (float-time) 1000))
        (plist-put session :seen (float-time))
        (let ((new (harness-acp-remote-test-refresh-token (harness-acp-remote-test-connect :secret secret) 1)))
          (should (stringp new))
          (should (< (abs (- (plist-get session :rotated) (float-time))) 5))
          (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret new)))
          (should (= 1 (length (harness-acp-remote-test-devices))))
          ;; Its lifetime is counted from the new secret, not from when it signed in.
          (should-not (harness-acp-remote--ended-p session (+ (float-time) 80000)))
          (should (harness-acp-remote--ended-p session (+ (float-time) 90000)))))
      ;; The same age, never replaced: its one secret ran out.
      (let* ((secret (harness-acp-remote-test-secret))
             (session (car harness-acp-remote--sessions)))
        (plist-put session :created (- (float-time) 1000000))
        (plist-put session :rotated (- (float-time) 1000000))
        (should-not (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
        (should (= 1 (length (harness-acp-remote-test-devices))))))))

(ert-deftest harness-acp-remote-init-resumes-serving-and-the-sessions-of-an-earlier-run ()
  "`harness-acp-remote' on: the module starts listening by itself, devices still signed in."
  (harness-acp-remote-test-with
    (let ((secret (harness-acp-remote-test-secret "Before")))
      ;; The harness goes away and comes back.
      (harness-acp-remote--stop)
      (setq harness-acp-remote--sessions nil harness-acp-remote--sessions-loaded nil)
      (should-not (harness-acp-remote--running-p))
      (let ((harness-acp-remote t))
        (harness-acp-remote--init))
      (should (harness-acp-remote--running-p))
      (setq harness-acp-remote-test-port (harness-acp-remote--port))
      (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
      (should (equal "Before" (plist-get (car (harness-acp-remote-test-devices)) :name)))
      ;; With the option off it does not listen, and keeps the sessions for when it is.
      (harness-acp-remote--stop)
      (setq harness-acp-remote--sessions nil harness-acp-remote--sessions-loaded nil)
      (let ((harness-acp-remote nil))
        (harness-acp-remote--init))
      (should-not (harness-acp-remote--running-p))
      (should (= 1 (length harness-acp-remote--sessions))))))

(ert-deftest harness-acp-remote-web-pages-need-the-secret-too ()
  "A page the device shows cannot sign in without the secret, and is shown to whoever approves."
  (harness-acp-remote-test-with
    (let ((secret (harness-acp-remote-test-secret)))
      (let ((c (harness-acp-remote-test-connect :headers '(("Origin" . "https://evil.example")))))
        (should-not (harness-acp-remote-test-signed-in-p c))
        (should (plist-get (harness-acp-client-remote-info (car harness-acp--clients)) :web))
        ;; The person asked to approve it is told which page it is.
        (harness-acp-remote-test-send c '(:jsonrpc "2.0" :id 5 :method "authenticate" :params (:methodId "emacs-approval")))
        (harness-test-wait (lambda () (plist-get (harness-call 'acp/remote-status) :approvals)) 15 "the approval")
        (should (equal "https://evil.example" (plist-get (car (plist-get (harness-call 'acp/remote-status) :approvals))
                                                         :origin)))
        (harness-call 'acp/remote-deny (plist-get (car (plist-get (harness-call 'acp/remote-status) :approvals)) :id)))
      ;; An app's own web view, or a page that was given the secret, is let in.
      (let ((c (harness-acp-remote-test-connect :secret secret :headers '(("Origin" . "http://tauri.localhost")))))
        (should (= 101 (harness-acp-remote-test-ws-status c)))
        (should (plist-get (harness-acp-remote-test-call c 1 "_harness/harness/version") :result))
        (should-not (plist-get (harness-acp-client-remote-info (car harness-acp--clients)) :web)))
      (let ((c (harness-acp-remote-test-connect :secret secret :headers '(("Origin" . "https://acp-ui.github.io")))))
        (should (= 101 (harness-acp-remote-test-ws-status c)))
        (should (plist-get (harness-acp-remote-test-call c 1 "_harness/harness/version") :result))
        (should (plist-get (harness-acp-client-remote-info (car harness-acp--clients)) :web))))))

(defun harness-acp-remote-test-tcp (port)
  "Open ACP's line framing to PORT; return (PROC . LINES-CELL), the lines parsed, newest first."
  (let* ((cell (list nil)) (buf "")
         (proc (make-network-process
                :name "acp-remote-test-tcp" :host "127.0.0.1" :service port
                :coding 'binary :noquery t
                :filter (lambda (_p chunk)
                          (setq buf (concat buf chunk))
                          (let (nl)
                            (while (setq nl (string-search "\n" buf))
                              (push (harness-json-parse (decode-coding-string (substring buf 0 nl) 'utf-8)) (car cell))
                              (setq buf (substring buf (1+ nl)))))))))
    (cons proc cell)))

(defun harness-acp-remote-test-tcp-ask (conn id method &optional params)
  "Send request ID METHOD PARAMS over CONN, from `harness-acp-remote-test-tcp'; return the answer."
  (process-send-string (car conn) (concat (harness-json-encode (list :jsonrpc "2.0" :id id :method method
                                                                      :params (or params :empty)))
                                          "\n"))
  (harness-test-wait (lambda () (cl-find id (car (cdr conn)) :key (lambda (m) (plist-get m :id)))) 15 method)
  (cl-find id (car (cdr conn)) :key (lambda (m) (plist-get m :id))))

(ert-deftest harness-acp-remote-plain-tcp ()
  "ACP's own line framing: nothing but `initialize' and `authenticate' before a secret."
  (harness-acp-remote-test-with
    (let ((secret (harness-acp-remote-test-secret))
          (conn (harness-acp-remote-test-tcp harness-acp-remote-test-port)))
      (unwind-protect
          (progn
            ;; The reduced `initialize': that it must authenticate, and with what.
            (let ((init (plist-get (harness-acp-remote-test-tcp-ask conn 1 "initialize" '(:protocolVersion 1)) :result)))
              (should (= 1 (plist-get init :protocolVersion)))
              (should (equal '("emacs-approval" "token") (mapcar (lambda (m) (plist-get m :id)) (plist-get init :authMethods))))
              (should-not (plist-member init :_harness))
              (should-not (plist-get (plist-get init :agentInfo) :version)))
            (should (= -32000 (harness-acp-remote-test-code (harness-acp-remote-test-tcp-ask conn 2 "_harness/harness/version"))))
            (should (= -32000 (harness-acp-remote-test-code (harness-acp-remote-test-tcp-ask conn 3 "session/new" '(:cwd "/tmp")))))
            ;; The address is not the secret; nor is the shared secret, nor a wrong one.
            (should (= -32000 (harness-acp-remote-test-code
                               (harness-acp-remote-test-tcp-ask conn 4 "authenticate" '(:methodId "token" :token "hs1_wrong")))))
            (should (= -32000 (harness-acp-remote-test-code
                               (harness-acp-remote-test-tcp-ask conn 5 "authenticate" '(:methodId "pair")))))
            (should (= -32000 (harness-acp-remote-test-code (harness-acp-remote-test-tcp-ask conn 6 "_harness/harness/version"))))
            (should-not (plist-get (harness-acp-remote-test-tcp-ask conn 7 "authenticate" (list :methodId "token" :token secret))
                                   :error))
            (should (plist-get (harness-acp-remote-test-tcp-ask conn 8 "_harness/harness/version") :result))
            (should (plist-member (harness-acp-remote-test-tcp-ask conn 9 "initialize" '(:protocolVersion 1)) :result))
            (let ((init (plist-get (harness-acp-remote-test-tcp-ask conn 10 "initialize" '(:protocolVersion 1)) :result)))
              (should (plist-get init :_harness))
              (should (null (plist-get init :authMethods))))
            (should (= 1 (length (cl-remove-if-not (lambda (c) (eq (harness-acp-client-kind c) 'remote-tcp))
                                                   harness-acp--clients)))))
        (delete-process (car conn))))
    ;; Wrong secrets make the address wait.
    (let ((conn (harness-acp-remote-test-tcp harness-acp-remote-test-port)))
      (unwind-protect
          (progn
            (dotimes (i harness-acp-remote--max-failures)
              (harness-acp-remote-test-tcp-ask conn (+ 100 i) "authenticate" '(:methodId "token" :token "hs1_x")))
            (let ((answer (harness-acp-remote-test-tcp-ask conn 200 "authenticate" '(:methodId "token" :token "hs1_x"))))
              (should (string-search "wait" (plist-get (plist-get answer :error) :message)))))
        (delete-process (car conn))))))

(ert-deftest harness-acp-remote-plain-tcp-must-authenticate-in-time ()
  (harness-acp-remote-test-with
    (let ((harness-acp-remote--preauth-timeout 0.3)
          (conn (harness-acp-remote-test-tcp harness-acp-remote-test-port)))
      (unwind-protect
          (progn
            (process-send-string (car conn) "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}\n")
            (harness-test-wait (lambda () (car (cdr conn))) 15 "the answer")
            (sleep-for 0.4)
            (harness-acp-remote--close-idle)
            (harness-test-wait (lambda () (not (process-live-p (car conn)))) 15 "the close")
            (harness-test-wait (lambda () (null harness-acp--clients)) 15 "the client to go"))
        (when (process-live-p (car conn)) (delete-process (car conn)))))))

(ert-deftest harness-acp-remote-plain-tcp-signs-in-by-an-approval-too ()
  (harness-acp-remote-test-with
    (let ((conn (harness-acp-remote-test-tcp harness-acp-remote-test-port)))
      (unwind-protect
          (progn
            (harness-acp-remote-test-tcp-ask conn 1 "initialize" '(:protocolVersion 1))
            (process-send-string (car conn) "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"authenticate\",\"params\":{\"methodId\":\"emacs-approval\"}}\n")
            (harness-test-wait (lambda () (plist-get (harness-call 'acp/remote-status) :approvals)) 15 "the approval")
            (harness-call 'acp/remote-approve (plist-get (car (plist-get (harness-call 'acp/remote-status) :approvals)) :id))
            (harness-test-wait (lambda () (cl-find 2 (car (cdr conn)) :key (lambda (m) (plist-get m :id)))) 15 "the answer")
            (should-not (plist-get (cl-find 2 (car (cdr conn)) :key (lambda (m) (plist-get m :id))) :error))
            (should (plist-get (harness-acp-remote-test-tcp-ask conn 3 "_harness/harness/version") :result)))
        (delete-process (car conn))))))

(ert-deftest harness-acp-remote-plain-tcp-before-a-secret-is-small ()
  "A connection with no session may not hold the harness's memory: a line stays small."
  (harness-acp-remote-test-with
    (let ((conn (harness-acp-remote-test-tcp harness-acp-remote-test-port)))
      (unwind-protect
          (progn
            (process-send-string
             (car conn) (concat "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"x\":\""
                                (make-string 70000 ?a)))
            (harness-test-wait (lambda () (not (process-live-p (car conn)))) 15 "the close")
            (harness-test-wait (lambda () (null harness-acp--clients)) 15 "the client to go"))
        (when (process-live-p (car conn)) (delete-process (car conn)))))
    ;; With a session the line may be as long as a message may.
    (let* ((secret (harness-acp-remote-test-secret))
           (conn (harness-acp-remote-test-tcp harness-acp-remote-test-port)))
      (unwind-protect
          (progn
            (should-not (plist-get (harness-acp-remote-test-tcp-ask conn 1 "authenticate" (list :methodId "token" :token secret))
                                   :error))
            (process-send-string
             (car conn) (concat "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"_harness/harness/version\",\"params\":{\"x\":\""
                                (make-string 70000 ?a) "\"}}\n"))
            (harness-test-wait (lambda () (cl-find 2 (car (cdr conn)) :key (lambda (m) (plist-get m :id)))) 15 "the answer")
            (should (process-live-p (car conn))))
        (when (process-live-p (car conn)) (delete-process (car conn)))))))

(ert-deftest harness-acp-remote-logout-ends-the-session ()
  "ACP's `logout' and DELETE /session end the session whose secret they come with."
  (harness-acp-remote-test-with
    (let* ((secret (harness-acp-remote-test-secret))
           (c (harness-acp-remote-test-connect :secret secret)))
      (harness-acp-remote-test-call c 1 "initialize" '(:protocolVersion 1))
      (should-not (plist-get (harness-acp-remote-test-call c 2 "logout") :error))
      (harness-test-wait (lambda () (harness-acp-remote-test-ws-closed c)) 15 "the connection to close")
      (should (null (harness-acp-remote-test-devices)))
      (should-not (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret))))
    (let ((secret (harness-acp-remote-test-secret))
          (other (harness-acp-remote-test-secret)))
      (let ((c (harness-acp-remote-test-connect :secret secret)))
        (should (= 401 (car (harness-acp-remote-test-http "DELETE /session HTTP/1.1\r\nHost: h\r\n\r\n"))))
        (pcase-let ((`(,status ,_ ,body) (harness-acp-remote-test-get
                                          "/session" `(("Authorization" . ,(concat "Bearer " secret))))))
          (should (= 200 status))
          (should (equal "Token" (plist-get (harness-json-parse body) :name))))
        (should (= 204 (car (harness-acp-remote-test-http
                             (format "DELETE /session HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer %s\r\n\r\n" secret)))))
        (harness-test-wait (lambda () (harness-acp-remote-test-ws-closed c)) 15 "the connection to close"))
      (should-not (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
      (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret other))))
    ;; A client of this machine has no session to end, and is told there is no such method.
    (let ((local (harness-acp-connect nil)))
      (unwind-protect
          (should (= -32601 (car (condition-case err
                                     (progn (harness-test-await (harness-acp-request local "logout" nil)) nil)
                                   (acp-error (cdr err))))))
        (harness-acp-close local)))))

;;;; Replacing a session secret

(defun harness-acp-remote-test-refresh-token (c id &optional capabilities)
  "Initialize C, request ID, as a client that can keep a new secret; return the one it is given.
CAPABILITIES are the `clientCapabilities' to send instead."
  (plist-get
   (plist-get
    (plist-get
     (plist-get (harness-acp-remote-test-call
                 c id "initialize"
                 (list :protocolVersion 1
                       :clientCapabilities (or capabilities '(:_harness (:sessionRefresh t)))))
                :result)
     :_harness)
    :session)
   :token))

(ert-deftest harness-acp-remote-rotation-offers-a-new-secret-only-to-those-who-ask ()
  (harness-acp-remote-test-with
    (let* ((harness-acp-remote-rotate-after 100)
           (secret (harness-acp-remote-test-secret))
           (session (car harness-acp-remote--sessions)))
      ;; Not due.
      (should-not (harness-acp-remote-test-refresh-token (harness-acp-remote-test-connect :secret secret) 1))
      (plist-put session :rotated (- (float-time) 1000))
      ;; Due, and the client did not say it can keep one, or said it cannot.
      (let ((c (harness-acp-remote-test-connect :secret secret)))
        (should-not (harness-acp-remote-test-refresh-token c 1 '(:fs (:readTextFile :false))))
        (should-not (harness-acp-remote-test-refresh-token c 2 '(:_harness (:sessionRefresh :false))))
        (should-not (harness-acp-remote-test-refresh-token c 3 '(:_harness (:emacs (:pid 1))))))
      (let ((harness-acp-remote-rotate-after nil))
        (should-not (harness-acp-remote-test-refresh-token (harness-acp-remote-test-connect :secret secret) 1)))
      (should (equal (harness-acp-remote--hash secret) (plist-get session :hash)))
      ;; Due and asked.
      (let* ((c (harness-acp-remote-test-connect :secret secret))
             (new (harness-acp-remote-test-refresh-token c 1)))
        (should (string-match-p "\\`hs1_[A-Za-z0-9_-]\\{43\\}\\'" new))
        (should-not (equal new secret))
        (should (string-search new (harness-acp-remote-test-raw c 1)))
        (should (string-search "\"idleTimeout\":3600" (harness-acp-remote-test-raw c 1)))
        (should (equal (harness-acp-remote--hash new) (plist-get session :hash)))
        (should (equal (harness-acp-remote--hash secret) (plist-get session :previous-hash)))
        ;; Once is enough on a connection, and for a while.
        (should-not (harness-acp-remote-test-refresh-token c 2))
        (should-not (harness-acp-remote-test-refresh-token (harness-acp-remote-test-connect :secret new) 1))
        ;; The file holds hashes, of both, and no secret.
        (let ((text (with-temp-buffer (insert-file-contents (harness-acp-remote--sessions-file)) (buffer-string))))
          (should-not (string-search new text))
          (should-not (string-search secret text)))))))

(ert-deftest harness-acp-remote-rotation-the-old-secret-ends-when-the-new-is-used ()
  (harness-acp-remote-test-with
    (let* ((harness-acp-remote-rotate-after 100)
           (secret (harness-acp-remote-test-secret))
           (session (car harness-acp-remote--sessions)))
      (plist-put session :rotated (- (float-time) 1000))
      (let ((new (harness-acp-remote-test-refresh-token (harness-acp-remote-test-connect :secret secret) 1)))
        ;; Both work until the device shows it has the new one ...
        (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
        (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret new)))
        ;; ... and then only that one does: anything else that held the old one is out.
        (should-not (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
        (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret new)))
        (should (null (plist-get session :previous-hash)))
        (should (= 1 (length (harness-acp-remote-test-devices))))))))

(ert-deftest harness-acp-remote-rotation-grace-ends ()
  (harness-acp-remote-test-with
    (let* ((harness-acp-remote-rotate-after 100)
           (secret (harness-acp-remote-test-secret))
           (session (car harness-acp-remote--sessions)))
      (plist-put session :rotated (- (float-time) 1000))
      (let ((new (harness-acp-remote-test-refresh-token (harness-acp-remote-test-connect :secret secret) 1)))
        (plist-put session :previous-until (- (float-time) 1))
        (should-not (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
        (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret new)))))))

(ert-deftest harness-acp-remote-rotation-sends-another-secret-to-a-device-that-lost-the-last ()
  "A device that comes in with the old secret never got the new one: it gets another."
  (harness-acp-remote-test-with
    (let* ((harness-acp-remote-rotate-after 100)
           (secret (harness-acp-remote-test-secret))
           (session (car harness-acp-remote--sessions)))
      (plist-put session :rotated (- (float-time) 1000))
      (let ((lost (harness-acp-remote-test-refresh-token (harness-acp-remote-test-connect :secret secret) 1))
            (c (harness-acp-remote-test-connect :secret secret)))
        (let ((again (harness-acp-remote-test-refresh-token c 1)))
          (should (string-prefix-p "hs1_" again))
          (should-not (equal again lost))
          (should-not (equal again secret))
          ;; The one that was lost works no more; the old one still does, for the grace.
          (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
          (should-not (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret lost)))
          (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret again)))
          (should-not (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret))))))))

(ert-deftest harness-acp-remote-rotation-over-plain-tcp ()
  (harness-acp-remote-test-with
    (let* ((harness-acp-remote-rotate-after 100)
           (secret (harness-acp-remote-test-secret))
           (session (car harness-acp-remote--sessions))
           (conn (harness-acp-remote-test-tcp harness-acp-remote-test-port)))
      (plist-put session :rotated (- (float-time) 1000))
      (unwind-protect
          (progn
            (harness-acp-remote-test-tcp-ask conn 1 "initialize" '(:protocolVersion 1))
            (should-not (plist-get (harness-acp-remote-test-tcp-ask conn 2 "authenticate" (list :methodId "token" :token secret))
                                   :error))
            (let ((new (plist-get (plist-get (plist-get (plist-get
                                                         (harness-acp-remote-test-tcp-ask
                                                          conn 3 "initialize"
                                                          '(:protocolVersion 1 :clientCapabilities (:_harness (:sessionRefresh t))))
                                                         :result)
                                                        :_harness)
                                             :session)
                                  :token)))
              (should (string-prefix-p "hs1_" new))
              (should (equal (harness-acp-remote--hash new) (plist-get session :hash)))))
        (delete-process (car conn))))))

(ert-deftest harness-acp-remote-ping-pong-and-close ()
  (harness-acp-remote-test-with
    (let ((c (harness-acp-remote-test-connect :secret (harness-acp-remote-test-secret))))
      (process-send-string (harness-acp-remote-test-ws-proc c)
                           (harness-acp-remote-ws-frame 'ping "hi" (unibyte-string 1 1 1 1)))
      (harness-test-wait (lambda () (assq 'pong (harness-acp-remote-test-ws-events c))) 15 "the pong")
      (should (equal '(pong . "hi") (assq 'pong (harness-acp-remote-test-ws-events c))))
      ;; An unmasked frame is a protocol error: the server closes with 1002.
      (process-send-string (harness-acp-remote-test-ws-proc c) (harness-acp-remote-ws-frame 'text "{}"))
      (harness-test-wait (lambda () (harness-acp-remote-test-ws-closed c)) 15 "the close")
      (should (equal 1002 (cadr (assq 'close (harness-acp-remote-test-ws-events c)))))
      (harness-test-wait (lambda () (null (harness-acp-remote--clients))) 15 "the client to go"))))

(ert-deftest harness-acp-remote-methods-over-acp ()
  "The UI reaches the methods as `_harness/acp/remote-…' over its own connection."
  (harness-acp-remote-test-with
    (let ((conn (harness-acp-connect nil)))
      (unwind-protect
          (let ((status (harness-test-await (harness-acp-request conn "_harness/acp/remote-status" nil))))
            (should (eq t (plist-get status :running)))
            (should (equal (format "ws://127.0.0.1:%d/acp" harness-acp-remote-test-port) (plist-get status :ws-url)))
            (should (equal (format "http://127.0.0.1:%d" harness-acp-remote-test-port) (plist-get status :base-url)))
            (should (eq :false (plist-get status :secure)))
            (should (eq :false (plist-get (plist-get status :oidc) :configured)))
            (should (eq t (plist-get status :approval)))
            (should (null (plist-get status :approvals)))
            (let ((token (harness-test-await (harness-acp-request conn "_harness/acp/remote-create-token" '(:name "Tablet")))))
              (should (string-prefix-p "hs1_" (plist-get token :token)))
              (should (equal "Tablet" (plist-get token :name)))
              (should (string-prefix-p "ws://127.0.0.1:" (plist-get token :url))))
            (let ((set (harness-test-await (harness-acp-request conn "_harness/acp/remote-set-address"
                                                                '(:address "192.0.2.5")))))
              (should (equal "192.0.2.5" (plist-get set :address)))
              (should (equal "ws://192.0.2.5:%d/acp" (replace-regexp-in-string "[0-9]+/acp\\'" "%d/acp" (plist-get set :ws-url)))))
            (should (equal "127.0.0.1" (plist-get (harness-test-await (harness-acp-request conn "_harness/acp/remote-set-address"
                                                                                           '(:address "")))
                                                  :address))))
        (harness-acp-close conn)))))

(ert-deftest harness-acp-remote-devices-do-not-manage-access ()
  "A device that is signed in drives the harness; it hands out no more access."
  (harness-acp-remote-test-with
    (let* ((secret (harness-acp-remote-test-secret))
           (other (harness-acp-remote-test-secret))
           (c (harness-acp-remote-test-connect :secret secret))
           (id 0))
      (dolist (method '("_harness/acp/remote-status" "_harness/acp/remote-create-token"
                        "_harness/acp/remote-revoke-all" "_harness/acp/remote-stop" "_harness/acp/remote-start"))
        (let ((e (plist-get (harness-acp-remote-test-call c (cl-incf id) method) :error)))
          (should (string-search "managed from the Emacs on this machine" (plist-get e :message)))))
      (should (plist-get (harness-acp-remote-test-call c (cl-incf id) "_harness/acp/remote-revoke"
                                                       (list :id (plist-get (car harness-acp-remote--sessions) :id)))
                         :error))
      (should (plist-get (harness-acp-remote-test-call c (cl-incf id) "_harness/acp/remote-set-address"
                                                       '(:address "192.0.2.1"))
                         :error))
      ;; Nor may it approve another device, or refuse one.
      (should (string-search "managed from the Emacs on this machine"
                             (plist-get (plist-get (harness-acp-remote-test-call c (cl-incf id) "_harness/acp/remote-approve"
                                                                                 '(:id "x"))
                                                   :error)
                                        :message)))
      (should (string-search "managed from the Emacs on this machine"
                             (plist-get (plist-get (harness-acp-remote-test-call c (cl-incf id) "_harness/acp/remote-deny"
                                                                                 '(:id "x"))
                                                   :error)
                                        :message)))
      ;; Nothing happened.
      (should (= 2 (length harness-acp-remote--sessions)))
      (should (harness-acp-remote--running-p))
      (should (null harness-acp-remote-address))
      (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret other))))))

;;;; Sessions over a device's connection

;; A device calls the same methods as a client in this Emacs: its
;; connection goes through the same dispatch, and what it may call is
;; what the bus has, so a method the bus gains (`session/list' once the
;; session module is there) is on offer to it at once.

(defvar harness-sessions)

(defun harness-acp-remote-test-load-sessions ()
  "Load the session module, and what it needs, next to acp and acp-remote.
No session is known then.  Only the tests of the session list need it,
and loading it costs a compile in each."
  (dolist (m '(store project session)) (harness-test-load-module m))
  (clrhash harness-sessions))

(ert-deftest harness-acp-remote-offers-what-a-local-client-is-offered ()
  "A device's `initialize' lists the methods and capabilities a client here gets.
Both come from the one registry: ACP's `session/list' is offered over
the network because the bus has it, not because a table of the
device's names it."
  (harness-acp-remote-test-with
    (harness-acp-remote-test-load-sessions)
    (let ((c (harness-acp-remote-test-connect :secret (harness-acp-remote-test-secret)))
          (local (harness-acp-connect nil)))
      (unwind-protect
          (let* ((init (plist-get (harness-acp-remote-test-call c 1 "initialize" '(:protocolVersion 1)) :result))
                 (here (harness-test-await (harness-acp-initialize local)))
                 (methods (plist-get (plist-get init :_harness) :methods)))
            ;; `list' is an empty object: the capability ACP's page shows.
            (should (plist-member (plist-get (plist-get init :agentCapabilities) :sessionCapabilities) :list))
            (should (string-search "\"sessionCapabilities\":{\"list\":{}}" (harness-acp-remote-test-raw c 1)))
            (should (equal (plist-get (plist-get here :agentCapabilities) :sessionCapabilities)
                           (plist-get (plist-get init :agentCapabilities) :sessionCapabilities)))
            ;; The same methods, in the same order, as a client here is
            ;; offered, and as the bus has them to offer.
            (should (member "session/list" methods))
            (should (equal (plist-get (plist-get here :_harness) :methods) methods))
            (should (equal (harness-acp--extension-methods) methods))
            ;; `logout' is for a device with a session to end, and for none here.
            (should (plist-member (plist-get (plist-get init :agentCapabilities) :auth) :logout))
            (should-not (plist-member (plist-get here :agentCapabilities) :auth))
            ;; A method the bus gains is offered to the device the next time it asks.
            (harness-register-method 'session/offered-at-once (lambda () t))
            (should (member "session/offered-at-once"
                            (plist-get (plist-get (plist-get (harness-acp-remote-test-call c 2 "initialize" '(:protocolVersion 1))
                                                             :result)
                                                  :_harness)
                                       :methods)))
            (harness-unregister-method 'session/offered-at-once)
            ;; And one it loses, the next time.
            (harness-unregister-method 'session/list)
            (let ((init (plist-get (harness-acp-remote-test-call c 3 "initialize" '(:protocolVersion 1)) :result)))
              (should-not (member "session/list" (plist-get (plist-get init :_harness) :methods)))
              (should-not (plist-member (plist-get init :agentCapabilities) :sessionCapabilities))))
        (harness-acp-close local)))))

(ert-deftest harness-acp-remote-lists-sessions ()
  "A signed-in device lists sessions with ACP's `session/list' and the harness's own.
Without a secret it cannot connect to ask."
  (harness-acp-remote-test-with
    (harness-acp-remote-test-load-sessions)
    (let* ((dir (harness-test-temp-dir))
           (session (harness-call 'session/create :cwd dir :name "From the desk" :model "demo:scripted"))
           (sid (plist-get session :id))
           (c (harness-acp-remote-test-connect :secret (harness-acp-remote-test-secret)))
           (ids (lambda (result key) (mapcar (lambda (s) (plist-get s key)) result))))
      (unwind-protect
          (progn
            (should (= -32000 (harness-acp-remote-test-code
                               (harness-acp-remote-test-ask (harness-acp-remote-test-connect) "session/list"))))
            (harness-acp-remote-test-call c 1 "initialize" '(:protocolVersion 1))
            ;; ACP's: SessionInfo of every session, over JSON, and the
            ;; virtual sessions after them.
            (let* ((result (plist-get (harness-acp-remote-test-call c 5 "session/list") :result))
                   (info (car (plist-get result :sessions))))
              (should (equal (cons sid (mapcar #'car harness-acp--virtual-sessions))
                             (funcall ids (plist-get result :sessions) :sessionId)))
              (should (equal dir (plist-get info :cwd)))
              (should (equal "From the desk" (plist-get info :title)))
              (should (equal (harness-iso-time (plist-get (harness-call 'session/get sid) :updated))
                             (plist-get info :updatedAt)))
              (should (equal "idle" (plist-get (plist-get info :_meta) :status)))
              (should-not (plist-member result :nextCursor)))
            ;; Its cwd filter, with or without the slash, and an answer of
            ;; no sessions, a page past the last one: an array, not null.
            (should (equal (cons sid (mapcar #'car harness-acp--virtual-sessions))
                           (funcall ids (plist-get (plist-get (harness-acp-remote-test-call
                                                               c 6 "session/list" (list :cwd (directory-file-name dir)))
                                                              :result)
                                                   :sessions)
                                    :sessionId)))
            (let ((result (plist-get (harness-acp-remote-test-call
                                      c 7 "session/list" (list :cwd (harness-test-temp-dir)
                                                               :cursor (harness-acp--list-cursor '(0 . "s"))))
                                     :result)))
              (should (plist-member result :sessions))
              (should (null (plist-get result :sessions)))
              (should (string-search "\"result\":{\"sessions\":[]}" (harness-acp-remote-test-raw c 7))))
            ;; Mistakes in the request are the device's to read.
            (should (= -32602 (harness-acp-remote-test-code
                               (harness-acp-remote-test-call c 8 "session/list" '(:cwd "relative")))))
            (should (= -32602 (harness-acp-remote-test-code
                               (harness-acp-remote-test-call c 9 "session/list" '(:cursor "not a cursor!")))))
            ;; The harness's own, with its filter.
            (should (equal (list sid)
                           (funcall ids (plist-get (harness-acp-remote-test-call
                                                    c 10 "_harness/session/list" '(:filter (:status "idle")))
                                                   :result)
                                    :id)))
            (should (null (plist-get (harness-acp-remote-test-call
                                      c 11 "_harness/session/list" '(:filter (:status "running")))
                                     :result)))
            ;; A bus method asked for by its bare name says where it is.
            (let ((e (plist-get (harness-acp-remote-test-call c 12 "session/get" (list :id sid)) :error)))
              (should (= -32601 (plist-get e :code)))
              (should (equal "Method not found: No such ACP method session/get; the harness's own method is _harness/session/get"
                             (plist-get e :message))))
            (should (equal sid (plist-get (plist-get (harness-acp-remote-test-call
                                                      c 13 "_harness/session/get" (list :id sid))
                                                     :result)
                                          :id))))
        (clrhash harness-sessions)))))

(ert-deftest harness-acp-remote-start-and-stop ()
  (harness-acp-remote-test-with
    (let ((secret (harness-acp-remote-test-secret)))
      (harness-acp-remote--stop)
      (should (eq :false (plist-get (harness-call 'acp/remote-status) :running)))
      (let ((status (harness-call 'acp/remote-start)))
        (should (eq t (plist-get status :running)))
        (should (eq t (plist-get status :enabled))))
      (setq harness-acp-remote-test-port (harness-acp-remote--port))
      (should (= 401 (car (harness-acp-remote-test-get "/"))))
      ;; A device waiting to be approved when serving stops is turned away.
      (let* ((c (harness-acp-remote-test-connect))
             (started (harness-acp-remote-test-start-sign-in c)))
        (should (plist-get (cdr started) :id))
        (let ((status (harness-call 'acp/remote-stop)))
          (should (eq :false (plist-get status :running)))
          (should (eq :false (plist-get status :enabled)))
          ;; Stopping closes the connections and what waits, and keeps the
          ;; devices signed in for the next time.
          (should (= 1 (length (plist-get status :devices))))
          (should (null (plist-get status :approvals)))))
      (should-error (harness-call 'acp/remote-create-token "x") :type 'harness-error)
      (harness-call 'acp/remote-start)
      (setq harness-acp-remote-test-port (harness-acp-remote--port))
      (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret))))))

(ert-deftest harness-acp-remote-corporate-mode ()
  (harness-acp-remote-test-with
    (let* ((secret (harness-acp-remote-test-secret))
           (c (harness-acp-remote-test-connect :secret secret)))
      (should (plist-get (harness-acp-remote-test-call c 1 "_harness/harness/version") :result))
      (let ((harness-corporate-mode t))
        ;; Everything is refused while it is on: calls on an open
        ;; connection, and new connections, closed unanswered.
        (should (= -32000 (harness-acp-remote-test-code (harness-acp-remote-test-call c 2 "_harness/harness/version"))))
        (should (= 0 (car (harness-acp-remote-test-get "/"))))
        (should-error (harness-call 'acp/remote-create-token "x") :type 'harness-error)
        (should-error (harness-call 'acp/remote-approve "x") :type 'harness-error)
        ;; Turning it on stops the listener and closes the connections.
        (run-hooks 'harness-corporate-mode-change-hook)
        (harness-test-wait (lambda () (harness-acp-remote-test-ws-closed c)) 15 "the connection to close")
        (should (eq :false (plist-get (harness-call 'acp/remote-status) :running)))
        (should-error (harness-call 'acp/remote-start) :type 'harness-error)
        ;; And the module does not start serving with it.
        (let ((harness-acp-remote t))
          (harness-acp-remote--init)
          (should-not (harness-acp-remote--running-p))))
      ;; The sessions are not forgotten, but no secret works while it is on.
      (should (= 1 (length harness-acp-remote--sessions)))
      (let ((harness-corporate-mode t))
        (should-not (harness-acp-remote--authorize
                     (harness-acp-add-client 'test :writer #'ignore
                                             :remote (list :transport "websocket" :session-id
                                                           (plist-get (car harness-acp-remote--sessions) :id)))))))))

(ert-deftest harness-acp-remote-policy-decides-whether-it-serves ()
  "A policy that turns `harness-acp-remote' off refuses `acp/remote-start'
before anything listens; one that turns it on refuses `acp/remote-stop'
before the listener stops."
  (harness-acp-remote-test-with
    (harness-acp-remote--stop)
    (harness-test-with-policy '((harness-acp-remote . nil))
      (should (string-match-p "harness-acp-remote is set by policy"
                              (error-message-string (should-error (harness-call 'acp/remote-start)))))
      (should-not (harness-acp-remote--running-p))
      ;; Stopping what does not run changes nothing the policy fixes.
      (should (eq :false (plist-get (harness-call 'acp/remote-stop) :running))))
    (harness-acp-remote--listen)
    (harness-test-with-policy '((harness-acp-remote . t))
      (should (string-match-p "harness-acp-remote is set by policy"
                              (error-message-string (should-error (harness-call 'acp/remote-stop)))))
      (should (harness-acp-remote--running-p))
      (should (eq t (plist-get (harness-call 'acp/remote-start) :running))))))

;;;; Serving carries on across restarts

(defmacro harness-acp-remote-test-with-held-port (&rest body)
  "Run BODY with the option on, the listener not running, and its port held.
`squatter' is the process that holds it, `harness-acp-remote-port' its
port, and the tries to start the listener come within a tenth of a second."
  (declare (indent 0))
  `(harness-acp-remote-test-with
     (harness-acp-remote--stop)
     (let* ((squatter (make-network-process :name "squatter" :server t :host "127.0.0.1"
                                            :service t :noquery t))
            (harness-acp-remote t)
            (harness-acp-remote-port (process-contact squatter :service))
            (harness-acp-remote--resume-delays '(0.05 0.1)))
       (unwind-protect (progn ,@body)
         (when (process-live-p squatter) (delete-process squatter))
         (harness-acp-remote--resume-cancel)))))

(ert-deftest harness-acp-remote-serves-again-when-the-harness-starts ()
  "With the option on, a harness that starts serves again, and a device signed in before is still in."
  (harness-acp-remote-test-with
    (let ((secret (harness-acp-remote-test-secret "Kept")))
      ;; The harness goes; another starts with the option saved on, and
      ;; nothing of the devices in memory.
      (harness-acp-remote--shutdown)
      (should-not (harness-acp-remote--running-p))
      (setq harness-acp-remote--sessions nil harness-acp-remote--sessions-loaded nil)
      (let ((harness-acp-remote t))
        (harness-acp-remote--init)
        (should (harness-acp-remote--running-p))
        (should (eq t (plist-get (harness-call 'acp/remote-status) :enabled))))
      (setq harness-acp-remote-test-port (harness-acp-remote--port))
      (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))
      (should (equal "Kept" (plist-get (car (harness-acp-remote-test-devices)) :name))))
    ;; With the option off, it does not.
    (harness-acp-remote--shutdown)
    (let ((harness-acp-remote nil))
      (harness-acp-remote--init)
      (should-not (harness-acp-remote--running-p))
      (should-not harness-acp-remote--resume-timer))))

(ert-deftest harness-acp-remote-tries-again-when-it-cannot-start ()
  "A listener that cannot start is tried again while the option is on, and the status says why."
  (harness-acp-remote-test-with-held-port
    (let ((changes nil))
      (harness-on 'acp/remote-changed (lambda (e) (push (plist-get e :what) changes)))
      (harness-acp-remote--init)
      (should-not (harness-acp-remote--running-p))
      (let ((status (harness-call 'acp/remote-status)))
        (should (eq :false (plist-get status :running)))
        (should (eq t (plist-get status :enabled)))
        (should (eq t (plist-get status :resuming)))
        (should (string-match-p "in use" (plist-get status :resume-error))))
      (should (member "waiting" changes))
      ;; Still held: tried again, and again, and nothing else changes.
      (harness-test-wait (lambda () (>= harness-acp-remote--resume-attempts 3)) 10 "three failed tries")
      (should harness-acp-remote--resume-timer)
      (should-not (harness-acp-remote--running-p))
      ;; Let go of the port: the next try serves, and what was said is gone.
      (delete-process squatter)
      (harness-test-wait #'harness-acp-remote--running-p 10 "the listener to start")
      (setq harness-acp-remote-test-port (harness-acp-remote--port))
      (let ((status (harness-call 'acp/remote-status)))
        (should (eq t (plist-get status :running)))
        (should (eq :false (plist-get status :resuming)))
        (should-not (plist-get status :resume-error)))
      (should-not harness-acp-remote--resume-timer)
      (should (= 0 harness-acp-remote--resume-attempts))
      (should (member "started" changes))
      (should (= 401 (car (harness-acp-remote-test-get "/")))))))

(ert-deftest harness-acp-remote-waits-longer-between-tries ()
  "The first try again comes after 2 seconds, the next after 5, and so on up to a minute."
  (let ((waits nil)
        (harness-acp-remote--resume-timer nil))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (time &rest _) (push time waits) nil)))
      (dotimes (tries 8)
        (let ((harness-acp-remote--resume-attempts tries))
          (harness-acp-remote--resume-later))))
    (should (equal '(2 5 15 30 60 60 60 60) (nreverse waits)))))

(ert-deftest harness-acp-remote-stopping-ends-the-tries ()
  "Turning serving off, from the page or by the policy of corporate mode, ends the tries."
  (harness-acp-remote-test-with-held-port
    (harness-acp-remote--init)
    (should harness-acp-remote--resume-timer)
    (let ((status (harness-call 'acp/remote-stop)))
      (should (eq :false (plist-get status :resuming)))
      (should (eq :false (plist-get status :enabled)))
      (should-not (plist-get status :resume-error)))
    (should-not harness-acp-remote--resume-timer)
    (delete-process squatter)
    (sleep-for 0.4)
    (should-not (harness-acp-remote--running-p))
    ;; Corporate mode: what was planned is dropped, nothing starts.
    (setq harness-acp-remote t)
    (setq squatter (make-network-process :name "squatter" :server t :host "127.0.0.1"
                                         :service harness-acp-remote-port :noquery t))
    (harness-acp-remote--init)
    (should harness-acp-remote--resume-timer)
    (let ((harness-corporate-mode t))
      (should-not (harness-acp-remote--resume))
      (should-not harness-acp-remote--resume-timer)
      (should-not harness-acp-remote--resume-error))
    ;; The same once the option is off, whoever turned it off.
    (harness-acp-remote--resume)
    (should harness-acp-remote--resume-timer)
    (setq harness-acp-remote nil)
    (should-not (harness-acp-remote--resume))
    (should-not harness-acp-remote--resume-timer)))

(ert-deftest harness-acp-remote-start-ends-the-tries-too ()
  "Starting serving from the page, while it is tried again, serves at once and plans nothing."
  (harness-acp-remote-test-with-held-port
    (harness-acp-remote--init)
    (should harness-acp-remote--resume-timer)
    (delete-process squatter)
    (let ((status (harness-call 'acp/remote-start)))
      (should (eq t (plist-get status :running)))
      (should (eq :false (plist-get status :resuming)))
      (should-not (plist-get status :resume-error)))
    (should-not harness-acp-remote--resume-timer)
    (should (harness-acp-remote--running-p))))

(ert-deftest harness-acp-remote-starts-a-listener-that-ended-on-its-own ()
  "A listener that ends without being stopped is started again while the option is on."
  (harness-acp-remote-test-with
    (let ((harness-acp-remote t)
          (harness-acp-remote--resume-delays '(0.05)))
      (should (harness-acp-remote--running-p))
      (delete-process harness-acp-remote--server)
      (should-not (harness-acp-remote--running-p))
      (harness-test-wait #'harness-acp-remote--running-p 10 "the listener to start again")
      (setq harness-acp-remote-test-port (harness-acp-remote--port))
      (should (= 401 (car (harness-acp-remote-test-get "/"))))
      ;; Stopped on purpose, it stays stopped.
      (harness-acp-remote--stop)
      (sleep-for 0.3)
      (should-not (harness-acp-remote--running-p))
      (should-not harness-acp-remote--resume-timer))))

(defun harness-acp-remote-test-idle-socket ()
  "Open a socket to the test listener that sends nothing; return (PROC . CLOSED-CELL)."
  (let* ((closed (list nil))
         (proc (make-network-process
                :name "acp-remote-test-idle" :host "127.0.0.1" :service harness-acp-remote-test-port
                :coding 'binary :noquery t
                :sentinel (lambda (p _e) (unless (process-live-p p) (setcar closed t))))))
    (cons proc closed)))

(ert-deftest harness-acp-remote-limits ()
  "Silent connections time out, and too many are refused."
  (harness-acp-remote-test-with
    (let ((harness-acp-remote--request-timeout 0.3))
      (pcase-let ((`(,proc . ,closed) (harness-acp-remote-test-idle-socket)))
        (harness-test-wait (lambda () (car closed)) 15 "the silent connection to close")
        (delete-process proc)))
    (let ((harness-acp-remote--max-connections 2)
          (sockets nil))
      (unwind-protect
          (progn
            (dotimes (_ 3) (push (harness-acp-remote-test-idle-socket) sockets))
            (harness-test-wait (lambda () (car (cdr (car sockets)))) 15 "the third connection to close")
            (accept-process-output nil 0.2)
            (should-not (car (cdr (nth 1 sockets))))
            (should-not (car (cdr (nth 2 sockets)))))
        (dolist (s sockets) (delete-process (car s)))))))

(ert-deftest harness-acp-remote-addresses ()
  (dolist (c (harness-acp-remote--candidates))
    (should (stringp (plist-get c :address)))
    (should-not (string-prefix-p "127." (plist-get c :address)))
    (should (member (plist-get c :kind) '("lan" "vpn" "other"))))
  (let ((harness-acp-remote-address "  192.0.2.9 ")
        (harness-acp-remote-host "0.0.0.0"))
    (should (equal "192.0.2.9" (harness-acp-remote--advertised-address))))
  (let ((harness-acp-remote-address nil)
        (harness-acp-remote-host "10.1.2.3"))
    (should (equal "10.1.2.3" (harness-acp-remote--advertised-address))))
  (let ((harness-acp-remote-address "fd00::1")
        (harness-acp-remote-port 4276)
        (harness-acp-remote-public-url nil))
    (should (equal "ws://[fd00::1]:4276/acp" (harness-acp-remote--ws-url)))
    (should (equal "http://[fd00::1]:4276" (harness-acp-remote--base-url)))))

(ert-deftest harness-acp-remote-public-url ()
  "Behind a TLS proxy, links and addresses carry the proxy's URL."
  (harness-acp-remote-test-with
    (let ((harness-acp-remote-public-url " https://harness.example.com/ "))
      (should (equal "https://harness.example.com" (harness-acp-remote--public-url)))
      (should (equal "wss://harness.example.com/acp" (harness-acp-remote--ws-url)))
      (should (harness-acp-remote--secure-p))
      (let ((token (harness-acp-remote-test-token)))
        (should (equal "wss://harness.example.com/acp" (plist-get token :ws-url)))
        (should (string-prefix-p "wss://harness.example.com/acp?token=hs1_" (plist-get token :url))))
      (let ((status (harness-call 'acp/remote-status)))
        (should (eq t (plist-get status :secure)))
        (should (eq t (plist-get status :public-url-set))))
      ;; The page a sign-in ends with tells a device the address it was reached at,
      ;; with no warning of an open network.
      (let* ((pair (harness-acp-remote--mint "Page" "test" "127.0.0.1" "oidc"))
             (body (harness-acp-remote--signed-in-page (car pair) (cdr pair))))
        (should (string-search "wss://harness.example.com/acp?token=hs1_" body))
        (should-not (string-search "not encrypted" body))))
    (let ((harness-acp-remote-public-url "http://harness.example.com"))
      (should (equal "ws://harness.example.com/acp" (harness-acp-remote--ws-url)))
      (should-not (harness-acp-remote--secure-p)))
    ;; Anything that is no URL is ignored.
    (let ((harness-acp-remote-public-url "harness.example.com"))
      (should (null (harness-acp-remote--public-url)))
      (should (string-prefix-p "ws://" (harness-acp-remote--ws-url))))
    ;; Without it, a page says that nothing encrypts what it asks of the device.
    (let* ((pair (harness-acp-remote--mint "Page" "test" "127.0.0.1" "oidc"))
           (body (harness-acp-remote--signed-in-page (car pair) (cdr pair))))
      (should (string-search "not encrypted" body)))))

(ert-deftest harness-acp-remote-secrets-are-random-and-compared-in-full ()
  (let ((a (harness-acp-remote--new-secret))
        (b (harness-acp-remote--new-secret)))
    (should (string-match-p "\\`hs1_[A-Za-z0-9_-]\\{43\\}\\'" a))
    (should-not (equal a b))
    (should (= 64 (length (harness-acp-remote--hash a))))
    (should (harness-acp-remote--equal-p a (copy-sequence a)))
    (should-not (harness-acp-remote--equal-p a b))
    (should-not (harness-acp-remote--equal-p a (substring a 0 10)))
    (should-not (harness-acp-remote--equal-p a nil)))
  ;; The code of a connection is four digits, and no two connections have one alike.
  (let ((code (harness-acp-remote--new-connection-code)))
    (should (string-match-p "\\`[0-9]\\{4\\}\\'" code))))

(ert-deftest harness-acp-remote-device-names ()
  (should (equal "Android · Chrome"
                 (harness-acp-remote--device-name
                  "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/129.0 Mobile Safari/537.36")))
  (should (equal "iPhone · Safari"
                 (harness-acp-remote--device-name
                  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1")))
  (should (equal "Dart/3.13 (dart:io)" (harness-acp-remote--device-name "Dart/3.13 (dart:io)")))
  (should (equal "unknown device" (harness-acp-remote--device-name nil)))
  (should (equal "Name" (harness-acp-remote--clean-name "  Name\n\t" "x")))
  (should (equal "x" (harness-acp-remote--clean-name " \n " "x")))
  (should (= 60 (length (harness-acp-remote--clean-name (make-string 200 ?a) "x")))))

;;;; OpenID Connect

;; The provider is a stub: `harness-http-request' answers what authentik
;; would, from `harness-acp-remote-test-idp', so the checks the module
;; makes are the ones under test.  The browser is the test: it follows
;; the redirect by reading the address, and comes back with the cookie.

(defvar harness-acp-remote-test-idp nil
  "The stub provider's settings during a test: a plist.
:claims is a function of the nonce and the plist of what the provider
issues, returning the id token's claims; :userinfo the userinfo answer;
:token-status the status of the token endpoint.")

(defvar harness-acp-remote-test-idp-requests nil "What the stub provider was asked, newest first.")

(defconst harness-acp-remote-test-issuer "https://idp.example/application/o/harness/")

(defun harness-acp-remote-test--b64 (text)
  "Return TEXT in base64url, as a JWT part."
  (base64url-encode-string (encode-coding-string text 'utf-8 t) t))

(defun harness-acp-remote-test-jwt (claims)
  "Return an id token holding CLAIMS, signed with nothing: nothing checks that."
  (concat (harness-acp-remote-test--b64 "{\"alg\":\"RS256\",\"typ\":\"JWT\"}") "."
          (harness-acp-remote-test--b64 (harness-json-encode claims)) ".c2ln"))

(defun harness-acp-remote-test-idp-claims (nonce &rest overrides)
  "Return the claims a provider issues for a sign-in with NONCE, OVERRIDES applied."
  (let ((claims (list :iss harness-acp-remote-test-issuer :aud "harness-client" :sub "u-1"
                      :exp (+ (float-time) 3600) :iat (float-time) :nonce nonce
                      :email "me@example.com" :email_verified t :preferred_username "me"
                      :groups '("everyone"))))
    (cl-loop for (k v) on overrides by #'cddr do (setq claims (plist-put claims k v)))
    claims))

(defun harness-acp-remote-test--idp-request (url &rest args)
  "Stand in for `harness-http-request': answer as the provider would."
  (let ((callback (plist-get args :callback))
        (idp harness-acp-remote-test-idp))
    (push (list url args) harness-acp-remote-test-idp-requests)
    (cond
     ((string-suffix-p "/.well-known/openid-configuration" url)
      (funcall callback (or (plist-get idp :discovery-status) 200) nil
               (harness-json-encode
                (list :issuer (or (plist-get idp :issuer) harness-acp-remote-test-issuer)
                      :authorization_endpoint (or (plist-get idp :authorization)
                                                  "https://idp.example/application/o/authorize/")
                      :token_endpoint "https://idp.example/application/o/token/"
                      :userinfo_endpoint (or (plist-get idp :userinfo-endpoint)
                                             "https://idp.example/application/o/userinfo/")))
               nil))
     ((string-suffix-p "/token/" url)
      (let* ((form (harness-acp-remote--parse-query (plist-get args :body)))
             (verifier (cdr (assoc "code_verifier" form)))
             (challenge (plist-get idp :challenge)))
        (cond
         ((not (equal "POST" (plist-get args :method))) (funcall callback 405 nil "" nil))
         ((not (equal "good-code" (cdr (assoc "code" form))))
          (funcall callback 400 nil "{\"error\":\"invalid_grant\"}" nil))
         ((not (and verifier challenge
                    (equal challenge (base64url-encode-string (secure-hash 'sha256 verifier nil nil t) t))))
          (funcall callback 400 nil "{\"error\":\"invalid_grant\",\"error_description\":\"PKCE\"}" nil))
         ((not (equal "authorization_code" (cdr (assoc "grant_type" form))))
          (funcall callback 400 nil "{\"error\":\"unsupported_grant_type\"}" nil))
         ((not (equal (cdr (assoc "redirect_uri" form)) (plist-get idp :redirect)))
          (funcall callback 400 nil "{\"error\":\"invalid_request\"}" nil))
         (t (funcall callback (or (plist-get idp :token-status) 200) nil
                     (harness-json-encode
                      (list :access_token "at-1" :token_type "Bearer"
                            :id_token (or (plist-get idp :id-token)
                                          (harness-acp-remote-test-jwt
                                           (funcall (or (plist-get idp :claims) #'harness-acp-remote-test-idp-claims)
                                                    (plist-get idp :nonce))))))
                     nil)))))
     ((string-suffix-p "/userinfo/" url)
      (funcall callback 200 nil (harness-json-encode (or (plist-get idp :userinfo) (list :sub "u-1"))) nil))
     (t (funcall callback 404 nil "" nil)))))

(defmacro harness-acp-remote-test-with-idp (settings &rest body)
  "Run BODY, in a listener of its own, with a stub OpenID provider set up as SETTINGS say."
  (declare (indent 1))
  `(harness-acp-remote-test-with
     (let ((harness-acp-remote-oidc-issuer harness-acp-remote-test-issuer)
           (harness-acp-remote-oidc-client-id "harness-client")
           (harness-acp-remote-oidc-allowed '("me@example.com"))
           (harness-acp-remote-test-idp (list :init t ,@settings))
           (harness-acp-remote-test-idp-requests nil))
       (cl-letf (((symbol-function 'harness-http-request) #'harness-acp-remote-test--idp-request))
         ,@body))))

(defun harness-acp-remote-test-confirm-login (code)
  "Do what a browser does for the device that shows CODE, up to the provider.
Return (STATUS HEAD BODY) of the request that sends it there."
  (pcase-let ((`(,status ,_ ,body) (harness-acp-remote-test-get (format "/login?c=%s" code))))
    (should (= 200 status))
    (should (string-match "name=\"t\" value=\"\\([^\"]+\\)\"" body))
    (let ((token (match-string 1 body)))
      (harness-acp-remote-test-post "/login" "application/x-www-form-urlencoded"
                                    (format "c=%s&t=%s" code token)
                                    `(("Cookie" . ,(format "harness_confirm=%s" token)))))))

(defun harness-acp-remote-test-start-login (&optional code)
  "Begin a sign-in as a browser does; return (:state :nonce :query :cookie :location).
With CODE, that of a device that waits to sign in, the browser confirms it first."
  (pcase-let ((`(,status ,head ,_) (if code (harness-acp-remote-test-confirm-login code)
                                     (harness-acp-remote-test-get "/login"))))
    (should (= 302 status))
    (should (string-match "Location: \\([^\r\n]+\\)" head))
    (let* ((location (match-string 1 head))
           (query (harness-acp-remote--parse-query (cadr (split-string location "?")))))
      (should (string-match "Set-Cookie: harness_login=\\([^;]+\\); Path=/; HttpOnly; SameSite=Lax" head))
      (let ((cookie (match-string 1 head)))
        ;; What the provider is asked, and what the stub then checks the token request against.
        (plist-put harness-acp-remote-test-idp :nonce (cdr (assoc "nonce" query)))
        (plist-put harness-acp-remote-test-idp :challenge (cdr (assoc "code_challenge" query)))
        (plist-put harness-acp-remote-test-idp :redirect (cdr (assoc "redirect_uri" query)))
        (list :state (cdr (assoc "state" query)) :nonce (cdr (assoc "nonce" query))
              :query query :cookie cookie :location location)))))

(defun harness-acp-remote-test-finish-login (login &optional code cookie)
  "Come back from the provider with CODE (default a good one) as the browser of LOGIN."
  (harness-acp-remote-test-get
   (format "/oidc/callback?code=%s&state=%s" (or code "good-code") (plist-get login :state))
   `(("Cookie" . ,(format "harness_login=%s" (or cookie (plist-get login :cookie)))))))

(ert-deftest harness-acp-remote-oidc-off-unless-configured ()
  (harness-acp-remote-test-with
    (should-not (harness-acp-remote--oidc-configured-p))
    (should-not (plist-get (plist-get (harness-call 'acp/remote-status) :oidc) :login-url))
    (let ((harness-acp-remote-oidc-issuer harness-acp-remote-test-issuer))
      (should-not (harness-acp-remote--oidc-configured-p))
      (let ((harness-acp-remote-oidc-client-id "harness-client"))
        (should (harness-acp-remote--oidc-configured-p))
        (should (equal (format "http://127.0.0.1:%d/login" harness-acp-remote-test-port)
                       (plist-get (plist-get (harness-call 'acp/remote-status) :oidc) :login-url)))
        (let ((harness-corporate-mode t))
          (should-not (harness-acp-remote--oidc-configured-p)))))))

(ert-deftest harness-acp-remote-oidc-sign-in ()
  "A person the provider vouches for signs in the connection that waits for them."
  (harness-acp-remote-test-with-idp ()
    (let ((login (harness-acp-remote-test-start-login)))
      ;; The authorization request: code flow, PKCE, a state and a nonce of its own.
      (let ((query (plist-get login :query)))
        (should (string-prefix-p "https://idp.example/application/o/authorize/?" (plist-get login :location)))
        (should (equal "code" (cdr (assoc "response_type" query))))
        (should (equal "harness-client" (cdr (assoc "client_id" query))))
        (should (equal "openid profile email" (cdr (assoc "scope" query))))
        (should (equal "S256" (cdr (assoc "code_challenge_method" query))))
        (should (equal (format "http://127.0.0.1:%d/oidc/callback" harness-acp-remote-test-port)
                       (cdr (assoc "redirect_uri" query))))
        (should (>= (length (plist-get login :state)) 30))
        (should (>= (length (plist-get login :nonce)) 30))
        (should-not (equal (plist-get login :state) (plist-get login :nonce)))
        (should (>= (length (cdr (assoc "code_challenge" query))) 40)))
      (should (null (harness-acp-remote-test-devices)))
      (pcase-let ((`(,status ,head ,body) (harness-acp-remote-test-finish-login login)))
        (should (= 200 status))
        (should (string-match-p "no-store" head))
        (should (string-match-p "Set-Cookie: harness_login=; Path=/; Max-Age=0" head))
        (should (string-match "value=\"ws://127\\.0\\.0\\.1:[0-9]+/acp\\?token=\\(hs1_[A-Za-z0-9_-]\\{43\\}\\)\"" body))
        (let ((secret (match-string 1 body))
              (device (car (harness-acp-remote-test-devices))))
          (should (equal "oidc" (plist-get device :method)))
          (should (equal "u-1" (plist-get device :subject)))
          (should (string-prefix-p "me@example.com · " (plist-get device :name)))
          (should (harness-acp-remote-test-signed-in-p (harness-acp-remote-test-connect :secret secret)))))
      ;; A sign-in finishes once, whatever comes back.
      (should (= 400 (car (harness-acp-remote-test-finish-login login))))
      (should (= 1 (length (harness-acp-remote-test-devices))))
      ;; The token request carried the verifier, the code and no client secret.
      (let ((token-request (cl-find-if (lambda (r) (string-suffix-p "/token/" (car r)))
                                       harness-acp-remote-test-idp-requests)))
        (should token-request)
        (let ((form (harness-acp-remote--parse-query (plist-get (cadr token-request) :body))))
          (should (equal "authorization_code" (cdr (assoc "grant_type" form))))
          (should (equal "harness-client" (cdr (assoc "client_id" form))))
          (should (>= (length (cdr (assoc "code_verifier" form))) 40))
          (should-not (assoc "client_secret" form))))
      ;; The provider's configuration is asked for once, then kept.
      (should (= 1 (cl-count-if (lambda (r) (string-suffix-p "/.well-known/openid-configuration" (car r)))
                                harness-acp-remote-test-idp-requests)))
      (harness-acp-remote-test-finish-login (harness-acp-remote-test-start-login))
      (should (= 1 (cl-count-if (lambda (r) (string-suffix-p "/.well-known/openid-configuration" (car r)))
                                harness-acp-remote-test-idp-requests))))))

(ert-deftest harness-acp-remote-oidc-confidential-client ()
  (harness-acp-remote-test-with-idp ()
    (let ((harness-acp-remote-oidc-client-secret (lambda () "the-client-secret")))
      (harness-acp-remote-test-finish-login (harness-acp-remote-test-start-login))
      (let* ((token-request (cl-find-if (lambda (r) (string-suffix-p "/token/" (car r)))
                                        harness-acp-remote-test-idp-requests))
             (form (harness-acp-remote--parse-query (plist-get (cadr token-request) :body))))
        (should (equal "the-client-secret" (cdr (assoc "client_secret" form))))))))

(ert-deftest harness-acp-remote-oidc-binds-the-sign-in-to-its-browser ()
  (harness-acp-remote-test-with-idp ()
    (let ((login (harness-acp-remote-test-start-login)))
      ;; Another browser, or none, with the state and the code of this one.
      (should (= 400 (car (harness-acp-remote-test-get
                           (format "/oidc/callback?code=good-code&state=%s" (plist-get login :state))))))
      ;; Using a state up (it is used even when refused), so this one is gone.
      (should (= 400 (car (harness-acp-remote-test-finish-login login))))
      (should (null (harness-acp-remote-test-devices))))
    (clrhash harness-acp-remote--failures)
    (let ((login (harness-acp-remote-test-start-login))
          (other (harness-acp-remote-test-start-login)))
      (should (= 400 (car (harness-acp-remote-test-finish-login login nil (plist-get other :cookie)))))
      (should (= 400 (car (harness-acp-remote-test-finish-login login nil "junk"))))
      (should (null (harness-acp-remote-test-devices))))
    ;; A state nobody issued.
    (clrhash harness-acp-remote--failures)
    (should (= 400 (car (harness-acp-remote-test-get "/oidc/callback?code=good-code&state=made-up"
                                                     '(("Cookie" . "harness_login=x"))))))
    (should (= 400 (car (harness-acp-remote-test-get "/oidc/callback"))))
    ;; Too late.
    (clrhash harness-acp-remote--failures)
    (let ((login (harness-acp-remote-test-start-login)))
      (plist-put (car harness-acp-remote--logins) :expires (- (float-time) 1))
      (should (= 400 (car (harness-acp-remote-test-finish-login login)))))))

(ert-deftest harness-acp-remote-oidc-checks-the-id-token ()
  (harness-acp-remote-test-with-idp ()
    (dolist (overrides '((:nonce "another-nonce")
                         (:aud "another-client")
                         (:aud ("another-client" "second"))
                         (:iss "https://evil.example/")
                         (:exp 1.0)
                         (:sub "")
                         (:azp "someone-else" :aud ("harness-client" "second"))))
      (let ((claims (lambda (nonce) (apply #'harness-acp-remote-test-idp-claims nonce overrides))))
        (plist-put harness-acp-remote-test-idp :claims claims)
        (let ((login (harness-acp-remote-test-start-login)))
          (should (= 403 (car (harness-acp-remote-test-finish-login login))))
          (should (null (harness-acp-remote-test-devices))))))
    ;; An audience list that names this client, issued to it, is fine.
    (plist-put harness-acp-remote-test-idp :claims
               (lambda (nonce) (harness-acp-remote-test-idp-claims
                                nonce :aud '("harness-client" "second") :azp "harness-client")))
    (should (= 200 (car (harness-acp-remote-test-finish-login (harness-acp-remote-test-start-login)))))
    ;; The issuer may differ from the configured one in a trailing slash only.
    (plist-put harness-acp-remote-test-idp :claims
               (lambda (nonce) (harness-acp-remote-test-idp-claims
                                nonce :iss (string-remove-suffix "/" harness-acp-remote-test-issuer))))
    (should (= 200 (car (harness-acp-remote-test-finish-login (harness-acp-remote-test-start-login)))))
    (should (= 2 (length (harness-acp-remote-test-devices))))
    ;; No id token, a broken one, one that holds no claims.
    (plist-put harness-acp-remote-test-idp :claims nil)
    (dolist (token (list "junk" "a.b.c" "a.e30.c" (harness-acp-remote-test-jwt nil)))
      (plist-put harness-acp-remote-test-idp :id-token token)
      (should (= 502 (car (harness-acp-remote-test-finish-login (harness-acp-remote-test-start-login))))))
    (should (= 2 (length (harness-acp-remote-test-devices)))))
  (harness-acp-remote-test-with-idp ()
    ;; The provider refuses the code, or fails.
    (let ((login (harness-acp-remote-test-start-login)))
      (should (= 502 (car (harness-acp-remote-test-finish-login login "bad-code")))))
    (plist-put harness-acp-remote-test-idp :token-status 500)
    (let ((login (harness-acp-remote-test-start-login)))
      (should (= 502 (car (harness-acp-remote-test-finish-login login)))))
    ;; The provider sends the person back with an error.
    (plist-put harness-acp-remote-test-idp :token-status 200)
    (let ((login (harness-acp-remote-test-start-login)))
      (pcase-let ((`(,status ,_ ,body)
                   (harness-acp-remote-test-get
                    (format "/oidc/callback?error=access_denied&state=%s" (plist-get login :state))
                    `(("Cookie" . ,(format "harness_login=%s" (plist-get login :cookie)))))))
        (should (= 403 status))
        (should (string-search "access_denied" body))))
    (should (null (harness-acp-remote-test-devices)))))

(ert-deftest harness-acp-remote-oidc-allow-list ()
  "Nobody is let in by default; the list names e-mail addresses, users and groups."
  (harness-acp-remote-test-with-idp ()
    (let ((attempt (lambda ()
                     (car (harness-acp-remote-test-finish-login (harness-acp-remote-test-start-login))))))
      ;; Nobody is allowed by default: said at once, before the provider is asked.
      (let ((harness-acp-remote-oidc-allowed nil)
            (before (length harness-acp-remote-test-idp-requests)))
        (pcase-let ((`(,status ,_ ,body) (harness-acp-remote-test-get "/login")))
          (should (= 403 status))
          (should (string-search "nobody is allowed" body)))
        (should (= before (length harness-acp-remote-test-idp-requests)))
        (should (null harness-acp-remote--logins))
        (should (eq :false (plist-get (plist-get (harness-call 'acp/remote-status) :oidc) :allowed))))
      (let ((harness-acp-remote-oidc-allowed '("someone-else@example.com" "admins")))
        (should (= 403 (funcall attempt))))
      (should (null (harness-acp-remote-test-devices)))
      (let ((harness-acp-remote-oidc-allowed '("ME@Example.com")))
        (should (= 200 (funcall attempt))))
      (let ((harness-acp-remote-oidc-allowed '("me")))
        (should (= 200 (funcall attempt))))
      (let ((harness-acp-remote-oidc-allowed '("u-1")))
        (should (= 200 (funcall attempt))))
      (let ((harness-acp-remote-oidc-allowed t))
        (should (= 200 (funcall attempt))))
      (should (= 4 (length (harness-acp-remote-test-devices))))
      ;; A group of the id token.
      (plist-put harness-acp-remote-test-idp :claims
                 (lambda (nonce) (harness-acp-remote-test-idp-claims nonce :groups '("everyone" "harness-users"))))
      (let ((harness-acp-remote-oidc-allowed '("harness-users")))
        (should (= 200 (funcall attempt))))
      ;; An e-mail address the provider calls unverified is no name to go by.
      (plist-put harness-acp-remote-test-idp :claims
                 (lambda (nonce) (harness-acp-remote-test-idp-claims nonce :email_verified :false :groups nil
                                                                     :preferred_username "nobody" :sub "x")))
      (let ((harness-acp-remote-oidc-allowed '("me@example.com")))
        (should (= 403 (funcall attempt))))
      ;; Nor is one it says nothing about: the claim is optional, and an
      ;; address a user typed in proves nobody.
      (plist-put harness-acp-remote-test-idp :claims
                 (lambda (nonce) (harness-acp-remote-test-idp-claims nonce :email_verified nil :groups nil
                                                                     :preferred_username "nobody" :sub "x")))
      (let ((harness-acp-remote-oidc-allowed '("me@example.com")))
        (should (= 403 (funcall attempt))))
      ;; A provider that sends the claim as the text "true" is believed.
      (plist-put harness-acp-remote-test-idp :claims
                 (lambda (nonce) (harness-acp-remote-test-idp-claims nonce :email_verified "true" :groups nil
                                                                     :preferred_username "nobody" :sub "x")))
      (let ((harness-acp-remote-oidc-allowed '("me@example.com")))
        (should (= 200 (funcall attempt))))
      (plist-put harness-acp-remote-test-idp :claims
                 (lambda (nonce) (harness-acp-remote-test-idp-claims nonce :email_verified "false" :groups nil
                                                                     :preferred_username "nobody" :sub "x")))
      (let ((harness-acp-remote-oidc-allowed '("me@example.com")))
        (should (= 403 (funcall attempt)))))))

(ert-deftest harness-acp-remote-oidc-groups-from-userinfo ()
  "An id token without groups: the provider's userinfo, for the same subject, has them."
  (harness-acp-remote-test-with-idp ()
    (plist-put harness-acp-remote-test-idp :claims
               (lambda (nonce) (let ((c (harness-acp-remote-test-idp-claims nonce :email "x@example.com")))
                                 (plist-put c :groups nil))))
    (plist-put harness-acp-remote-test-idp :userinfo '(:sub "u-1" :groups ("harness-users")))
    (let ((harness-acp-remote-oidc-allowed '("harness-users")))
      (should (= 200 (car (harness-acp-remote-test-finish-login (harness-acp-remote-test-start-login)))))
      (should (cl-find-if (lambda (r) (string-suffix-p "/userinfo/" (car r))) harness-acp-remote-test-idp-requests)))
    ;; Userinfo about someone else is not believed.
    (plist-put harness-acp-remote-test-idp :userinfo '(:sub "someone-else" :groups ("harness-users")))
    (let ((harness-acp-remote-oidc-allowed '("harness-users")))
      (should (= 403 (car (harness-acp-remote-test-finish-login (harness-acp-remote-test-start-login))))))
    ;; The access token is not sent over plain http: that endpoint is left alone.
    (plist-put harness-acp-remote-test-idp :userinfo '(:sub "u-1" :groups ("harness-users")))
    (plist-put harness-acp-remote-test-idp :userinfo-endpoint "http://idp.example/application/o/userinfo/")
    (setq harness-acp-remote--oidc-config nil
          harness-acp-remote-test-idp-requests nil)
    (let ((harness-acp-remote-oidc-allowed '("harness-users")))
      (should (= 403 (car (harness-acp-remote-test-finish-login (harness-acp-remote-test-start-login)))))
      (should-not (cl-find-if (lambda (r) (string-search "/userinfo/" (car r))) harness-acp-remote-test-idp-requests)))))

(ert-deftest harness-acp-remote-oidc-provider-misconfigured ()
  (harness-acp-remote-test-with-idp ()
    ;; Not https.
    (let ((harness-acp-remote-oidc-issuer "http://idp.example/"))
      (should (= 502 (car (harness-acp-remote-test-get "/login")))))
    ;; The provider names another issuer, or cannot be reached.
    (setq harness-acp-remote--oidc-config nil)
    (plist-put harness-acp-remote-test-idp :issuer "https://other.example/")
    (should (= 502 (car (harness-acp-remote-test-get "/login"))))
    (plist-put harness-acp-remote-test-idp :issuer nil)
    (plist-put harness-acp-remote-test-idp :discovery-status 500)
    (should (= 502 (car (harness-acp-remote-test-get "/login"))))
    ;; Its endpoints are not https, or not a URL: nothing the provider says
    ;; may add a header to the answer.
    (plist-put harness-acp-remote-test-idp :discovery-status nil)
    (plist-put harness-acp-remote-test-idp :authorization "http://idp.example/authorize/")
    (should (= 502 (car (harness-acp-remote-test-get "/login"))))
    (plist-put harness-acp-remote-test-idp :authorization "https://idp.example/authorize/\r\nSet-Cookie: evil=1")
    (should (= 502 (car (harness-acp-remote-test-get "/login"))))
    (plist-put harness-acp-remote-test-idp :authorization "https://idp.example/author ize/")
    (should (= 502 (car (harness-acp-remote-test-get "/login"))))
    (plist-put harness-acp-remote-test-idp :authorization nil)
    (should (= 302 (car (harness-acp-remote-test-get "/login"))))
    ;; A burst of sign-ins is not kept for good.
    (dotimes (_ 25) (harness-acp-remote-test-get "/login"))
    (should (<= (length harness-acp-remote--logins) 21))
    (should (= 429 (car (harness-acp-remote-test-get "/login"))))))

(defun harness-acp-remote-test-provider-start ()
  "Start the provider of test/fixtures/oidc-provider.py; return (PROCESS . PORT)."
  (let* ((script (expand-file-name "test/fixtures/oidc-provider.py" harness-test-root))
         (buffer (generate-new-buffer " *oidc-provider*"))
         (process (make-process :name "oidc-provider" :buffer buffer :noquery t :connection-type 'pipe
                                :command (list "python3" "-I" script "0"))))
    (harness-test-wait (lambda () (with-current-buffer buffer
                                    (goto-char (point-min))
                                    (re-search-forward "idp on \\([0-9]+\\)" nil t)))
                       10 "the provider to listen")
    (cons process (with-current-buffer buffer
                    (goto-char (point-min))
                    (re-search-forward "idp on \\([0-9]+\\)")
                    (string-to-number (match-string 1))))))

(ert-deftest harness-acp-remote-oidc-against-a-provider-over-http ()
  "The sign-in over real HTTP: curl makes the token request, a provider checks it.
The provider verifies PKCE, the redirect URI and the client, and keeps the
groups out of its id token: the harness has to ask its userinfo for them."
  (skip-unless (and (executable-find "python3") (executable-find "curl")))
  (harness-acp-remote-test-with
    (pcase-let ((`(,provider . ,port) (harness-acp-remote-test-provider-start)))
      (unwind-protect
          (let ((harness-acp-remote-oidc-issuer (format "http://127.0.0.1:%d/application/o/harness/" port))
                (harness-acp-remote-oidc-client-id "harness-client")
                (harness-acp-remote-oidc-allowed '("harness-users")))
            (let ((sign-in
                   (lambda (&optional cookie-of)
                     ;; The browser: our login, the provider's authorization page, back.
                     (pcase-let ((`(,status ,head ,_) (harness-acp-remote-test-get "/login")))
                       (should (= 302 status))
                       (should (string-match "Location: \\(http://127[^\r\n]+\\)" head))
                       (let* ((location (match-string 1 head))
                              (cookie (progn (string-match "harness_login=\\([^;]+\\)" head) (match-string 1 head)))
                              (back (let ((harness-acp-remote-test-port port))
                                      (harness-acp-remote-test-get (substring location (string-match "/application" location))))))
                         (should (= 302 (car back)))
                         (should (string-match "Location: [^\r\n]*\\(/oidc/callback\\?[^\r\n]+\\)" (nth 1 back)))
                         (harness-acp-remote-test-get
                          (match-string 1 (nth 1 back))
                          `(("Cookie" . ,(format "harness_login=%s" (or cookie-of cookie))))))))))
              ;; Someone the provider vouches for, in a group its userinfo names.
              (pcase-let ((`(,status ,_ ,body) (funcall sign-in)))
                (should (= 200 status))
                (should (string-match "token=\\(hs1_[A-Za-z0-9_-]\\{43\\}\\)" body))
                (let ((device (car (harness-acp-remote-test-devices))))
                  (should (equal "oidc" (plist-get device :method)))
                  (should (equal "user-42" (plist-get device :subject)))
                  (should (string-prefix-p "noah@example.com" (plist-get device :name))))
                (should (= 101 (harness-acp-remote-test-ws-status
                                (harness-acp-remote-test-connect :secret (match-string 1 body))))))
              ;; Not in a group that is allowed, and not by an e-mail it calls unverified.
              (let ((harness-acp-remote-oidc-allowed '("somebody-else" "noah@example.com")))
                (should (= 403 (car (funcall sign-in))))
                (should (= 1 (length (harness-acp-remote-test-devices)))))))
        (delete-process provider)))))

(ert-deftest harness-acp-remote-oidc-not-in-corporate-mode ()
  (harness-acp-remote-test-with-idp ()
    (let ((login (harness-acp-remote-test-start-login))
          (harness-corporate-mode t))
      (should (= 0 (car (harness-acp-remote-test-finish-login login)))))))

(defun harness-acp-remote-test-oidc-method (c)
  "Return the `oidc' method of the client C's `initialize' offers, and the code it shows."
  (let* ((init (plist-get (harness-acp-remote-test-ask c "initialize" '(:protocolVersion 1 :clientInfo (:name "app" :version "2")))
                          :result))
         (method (cl-find "oidc" (plist-get init :authMethods) :key (lambda (m) (plist-get m :id)) :test #'equal)))
    (should method)
    (should (string-match "/login\\?c=\\([0-9]\\{4\\}\\)" (plist-get method :description)))
    (cons method (match-string 1 (plist-get method :description)))))

(ert-deftest harness-acp-remote-oidc-signs-in-the-connection-that-waits ()
  "The browser signs in at the provider, and the connection the person confirmed is signed in."
  (harness-acp-remote-test-with-idp ()
    (let* ((c (harness-acp-remote-test-connect))
           (found (harness-acp-remote-test-oidc-method c))
           (method (car found))
           (code (cdr found)))
      ;; The method names the provider, and says where the browser goes (for an app to open by itself).
      (should (equal "Sign in with idp.example" (plist-get method :name)))
      (should (equal (format "http://127.0.0.1:%d/login?c=%s" harness-acp-remote-test-port code)
                     (plist-get (plist-get (plist-get method :_meta) :harness) :url)))
      (let ((id (cl-incf harness-acp-remote-test--id)))
        (harness-acp-remote-test-send c (list :jsonrpc "2.0" :id id :method "authenticate" :params '(:methodId "oidc")))
        (harness-test-wait (lambda () harness-acp-remote--login-waits) 15 "the wait")
        (should-not (harness-acp-remote-test-answer c id))
        ;; The browser is told which device this is, and asked to go on.
        (pcase-let ((`(,status ,head ,body) (harness-acp-remote-test-get (format "/login?c=%s" code))))
          (should (= 200 status))
          (should (string-search code body))
          (should (string-search "127.0.0.1" body))
          (should (string-search "app 2" body))
          (should (string-match-p "Set-Cookie: harness_confirm=[^;]+; Path=/login; HttpOnly; SameSite=Strict" head))
          (should (null harness-acp-remote--logins)))
        (let ((login (harness-acp-remote-test-start-login code)))
          (should (= 1 (length harness-acp-remote--logins)))
          (should-not (harness-acp-remote-test-answer c id))
          (pcase-let ((`(,status ,_ ,body) (harness-acp-remote-test-finish-login login)))
            (should (= 200 status))
            ;; The browser is told to go back, and is given no secret.
            (should (string-search "Go back to the app" body))
            (should-not (string-search "hs1_" body)))
          (harness-test-wait (lambda () (harness-acp-remote-test-answer c id)) 15 "the answer")
          (should-not (plist-get (harness-acp-remote-test-answer c id) :error)))
        (should (harness-acp-remote-test-signed-in-p c))
        (let ((device (car (harness-acp-remote-test-devices))))
          (should (equal "oidc" (plist-get device :method)))
          (should (equal "u-1" (plist-get device :subject)))
          (should (string-prefix-p "me@example.com · app 2" (plist-get device :name)))
          (should (eq t (plist-get device :ephemeral))))
        (should (null harness-acp-remote--login-waits))))))

(ert-deftest harness-acp-remote-oidc-login-may-finish-before-authenticate-and-after-a-timeout ()
  (harness-acp-remote-test-with-idp ()
    ;; The person was quicker than the app: `authenticate' then finds it done.
    (let* ((c (harness-acp-remote-test-connect))
           (code (cdr (harness-acp-remote-test-oidc-method c)))
           (login (harness-acp-remote-test-start-login code)))
      (should (= 200 (car (harness-acp-remote-test-finish-login login))))
      (should-not (harness-acp-remote-test-signed-in-p c))
      (should-not (plist-get (harness-acp-remote-test-ask c "authenticate" '(:methodId "oidc")) :error))
      (should (harness-acp-remote-test-signed-in-p c)))
    ;; The app gave up waiting before the person finished: it chooses the method again.
    (let* ((harness-acp-remote--login-timeout 0.3)
           (c (harness-acp-remote-test-connect))
           (code (cdr (harness-acp-remote-test-oidc-method c)))
           (e (plist-get (harness-acp-remote-test-ask c "authenticate" '(:methodId "oidc")) :error)))
      (should (string-search "not finished in time" (plist-get e :message)))
      (let ((login (harness-acp-remote-test-start-login code)))
        (should (= 200 (car (harness-acp-remote-test-finish-login login))))
        (should-not (plist-get (harness-acp-remote-test-ask c "authenticate" '(:methodId "oidc")) :error))
        (should (harness-acp-remote-test-signed-in-p c))))))

(ert-deftest harness-acp-remote-oidc-sign-in-of-a-connection-is-guarded ()
  "What a link makes a browser do is confirmed by the person, and by one browser only."
  (harness-acp-remote-test-with-idp ()
    (let* ((c (harness-acp-remote-test-connect))
           (code (cdr (harness-acp-remote-test-oidc-method c))))
      ;; Nothing waits for a code that is none's.
      (should (= 404 (car (harness-acp-remote-test-get "/login?c=0000x"))))
      (should (= 404 (car (harness-acp-remote-test-get (format "/login?c=%s" (if (equal code "1234") "4321" "1234"))))))
      ;; The button is the page's own: a form posted without its token, or with another's, goes nowhere.
      (pcase-let ((`(,_ ,_ ,body) (harness-acp-remote-test-get (format "/login?c=%s" code))))
        (should (string-match "name=\"t\" value=\"\\([^\"]+\\)\"" body))
        (let ((token (match-string 1 body)))
          (should (= 400 (car (harness-acp-remote-test-post "/login" "application/x-www-form-urlencoded"
                                                            (format "c=%s&t=%s" code token)))))
          (should (= 400 (car (harness-acp-remote-test-post "/login" "application/x-www-form-urlencoded"
                                                            (format "c=%s&t=%s" code token)
                                                            '(("Cookie" . "harness_confirm=another"))))))
          (should (= 400 (car (harness-acp-remote-test-post "/login" "application/x-www-form-urlencoded"
                                                            (format "c=%s" code)
                                                            `(("Cookie" . ,(format "harness_confirm=%s" token)))))))
          (should (null harness-acp-remote--logins))
          (should (= 302 (car (harness-acp-remote-test-post "/login" "application/x-www-form-urlencoded"
                                                            (format "c=%s&t=%s" code token)
                                                            `(("Cookie" . ,(format "harness_confirm=%s" token)))))))))
      ;; The sign-in that follows is the browser's own, as any.
      (let ((login (car harness-acp-remote--logins)))
        (should (eq (car harness-acp--clients) (plist-get login :client))))
      ;; Not someone the allow-list names: the device stays out.
      (let* ((harness-acp-remote-oidc-allowed '("somebody-else"))
             (login (harness-acp-remote-test-start-login code)))
        (should (= 403 (car (harness-acp-remote-test-finish-login login))))
        (should-not (harness-acp-remote-test-signed-in-p c))))
    ;; The device left before the person came back.
    (let* ((c (harness-acp-remote-test-connect))
           (code (cdr (harness-acp-remote-test-oidc-method c)))
           (login (harness-acp-remote-test-start-login code))
           (server-side (car harness-acp--clients)))
      (delete-process (harness-acp-remote-test-ws-proc c))
      (harness-test-wait (lambda () (not (memq server-side harness-acp--clients))) 15 "the client to go")
      (should (= 410 (car (harness-acp-remote-test-finish-login login))))
      (should (null (harness-acp-remote-test-devices))))
    ;; A device that signed in already no longer waits.
    (let ((c (harness-acp-remote-test-connect :secret (harness-acp-remote-test-secret))))
      (should (harness-acp-remote-test-signed-in-p c)))
    ;; Without a provider, or with nobody allowed, the method is not offered.
    (let ((harness-acp-remote-oidc-allowed nil)
          (c (harness-acp-remote-test-connect)))
      (should-not (cl-find "oidc" (plist-get (plist-get (harness-acp-remote-test-ask c "initialize" '(:protocolVersion 1)) :result)
                                             :authMethods)
                           :key (lambda (m) (plist-get m :id)) :test #'equal)))))

(ert-deftest harness-acp-remote-http-requests-with-bodies ()
  (harness-acp-remote-test-with-idp ()
    ;; A body that arrives after the header, in pieces, is read whole before the request is answered:
    ;; `/login' is asked to confirm the device of a code that is none's, which only it can refuse.
    (let ((body "c=1234&t=abcdef"))
      (pcase-let ((`(,status ,_ ,answer)
                   (harness-acp-remote-test-http
                    (format "POST /login HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n\r\n%s"
                            (length body) (substring body 0 5))
                    (list (substring body 5 9) (substring body 9)))))
        (should (= 400 status))
        (should (string-search "not opened in this browser" answer))))
    (should (= 413 (car (harness-acp-remote-test-http
                         "POST /login HTTP/1.1\r\nHost: h\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 99999\r\n\r\n"))))
    (should (= 411 (car (harness-acp-remote-test-http
                         "POST /login HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"))))
    (should (= 400 (car (harness-acp-remote-test-http
                         "POST /login HTTP/1.1\r\nHost: h\r\nContent-Length: abc\r\n\r\n"))))
    (should (= 400 (car (harness-acp-remote-test-http "garbage that is not http\r\n\r\n"))))))

(provide 'harness-acp-remote-test)
;;; harness-acp-remote-test.el ends here
