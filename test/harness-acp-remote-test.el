;;; harness-acp-remote-test.el --- Tests for ACP served to other devices  -*- lexical-binding: t; -*-

;;; Commentary:

;; The WebSocket framing on strings, the HTTP request parser, and the
;; whole path a phone takes, end to end over real sockets on 127.0.0.1:
;; an ACP client that is refused until it pairs, the pairing link that
;; lets it in (and the `authenticate' that waited for it), a bearer
;; token, web pages refused, plain TCP, revoking, expiry and corporate
;; mode.  `harness-acp-remote--allow-loopback' lets 127.0.0.1 pair.

;;; Code:

(require 'harness-test-helpers)

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
  "Run BODY with a listener for other devices on 127.0.0.1, that may pair."
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
           (harness-acp-remote-code-lifetime 600)
           (harness-acp-remote-idle-timeout 3600)
           (harness-acp-remote--allow-loopback t)
           (harness-corporate-mode nil))
       (setq harness-acp-remote--devices nil harness-acp-remote--code nil harness-acp-remote--waiting nil)
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

(cl-defun harness-acp-remote-test-connect (&key protocols headers (path "/acp"))
  "Open a WebSocket to the test listener; return the client once it is open.
PROTOCOLS are offered; HEADERS, an alist, are sent besides."
  (let* ((c (harness-acp-remote-test--ws :decoder (harness-acp-remote-decoder :require-mask nil)))
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
    (harness-test-wait (lambda () (harness-acp-remote-test-ws-status c)) 5 "the handshake")
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
  (harness-test-wait (lambda () (harness-acp-remote-test-answer c id)) 5 method)
  (harness-acp-remote-test-answer c id))

(defun harness-acp-remote-test-code (answer)
  "Return the error code of ANSWER, or nil."
  (plist-get (plist-get answer :error) :code))

(defun harness-acp-remote-test-http (text)
  "Send the request TEXT to the test listener; return (STATUS HEAD BODY)."
  (let* ((out "") (done nil)
         (proc (make-network-process
                :name "acp-remote-test-http" :host "127.0.0.1" :service harness-acp-remote-test-port
                :coding 'binary :noquery t
                :filter (lambda (_p chunk) (setq out (concat out chunk)))
                :sentinel (lambda (p _e) (unless (process-live-p p) (setq done t))))))
    (ignore-errors (process-send-string proc text))
    (harness-test-wait (lambda () (or done (string-match-p "</html>" out))) 5 "the response")
    (delete-process proc)
    (let ((end (string-search "\r\n\r\n" out)))
      (if (not (and end (string-match "\\`HTTP/1.1 \\([0-9]+\\)" out)))
          ;; Closed without an answer.
          (list 0 "" "")
        (list (string-to-number (match-string 1 out)) (substring out 0 end)
              (decode-coding-string (substring out (+ end 4)) 'utf-8))))))

(defun harness-acp-remote-test-get (target)
  "GET TARGET from the test listener; return (STATUS HEAD BODY)."
  (harness-acp-remote-test-http (format "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: test-phone\r\n\r\n" target)))

(defun harness-acp-remote-test-pair-path ()
  "Mint a pairing code and return the path of its link."
  (let ((url (plist-get (harness-call 'acp/remote-pair) :url)))
    (should (string-match "\\`http://127\\.0\\.0\\.1:[0-9]+\\(/pair\\?code=[a-z2-7]\\{20\\}\\)\\'" url))
    (match-string 1 url)))

(ert-deftest harness-acp-remote-pairing-flow ()
  "Refused, then `authenticate pair' waits, the link is opened, and it goes on."
  (harness-acp-remote-test-with
    (let ((c (harness-acp-remote-test-connect :protocols '("acp.v1"))))
      (should (= 101 (harness-acp-remote-test-ws-status c)))
      (should (member "Sec-WebSocket-Protocol: acp.v1" (harness-acp-remote-test-ws-headers c)))
      (should (cl-some (lambda (h) (string-prefix-p "Acp-Connection-Id: " h)) (harness-acp-remote-test-ws-headers c)))
      (let ((init (plist-get (harness-acp-remote-test-call c 1 "initialize" '(:protocolVersion 1)) :result)))
        (should (equal '("pair") (mapcar (lambda (m) (plist-get m :id)) (plist-get init :authMethods)))))
      (should (= -32000 (harness-acp-remote-test-code (harness-acp-remote-test-call c 2 "_harness/harness/version"))))
      ;; Heartbeats get no answer.
      (harness-acp-remote-test-send c '(:jsonrpc "2.0" :method "$/ping"))
      ;; authenticate pair waits for the link.
      (harness-acp-remote-test-send c '(:jsonrpc "2.0" :id 3 :method "authenticate" :params (:methodId "pair")))
      (accept-process-output nil 0.3)
      (should-not (harness-acp-remote-test-answer c 3))
      (let ((path (harness-acp-remote-test-pair-path)))
        (pcase-let ((`(,status ,head ,body) (harness-acp-remote-test-get path)))
          (should (= 200 status))
          (should (string-match-p "Cache-Control: no-store" head))
          (should (string-match-p "Referrer-Policy: no-referrer" head))
          (should (string-search (format "ws://127.0.0.1:%d/acp" harness-acp-remote-test-port) body)))
        (let ((answer (harness-test-wait (lambda () (harness-acp-remote-test-answer c 3)) 5 "authenticate")))
          (should-not (plist-get answer :error)))
        (should (equal harness-version
                       (plist-get (plist-get (harness-acp-remote-test-call c 4 "_harness/harness/version") :result)
                                  :version)))
        ;; The link worked once.
        (should (= 403 (car (harness-acp-remote-test-get path)))))
      (let* ((status (harness-call 'acp/remote-status))
             (device (car (plist-get status :devices))))
        (should (eq t (plist-get status :running)))
        (should (= 1 (length (plist-get status :devices))))
        (should (equal "127.0.0.1" (plist-get device :address)))
        (should (equal "test-phone" (plist-get device :agent)))
        (should (= 1 (plist-get device :connected)))
        ;; A second connection from the paired device needs nothing.
        (let ((c2 (harness-acp-remote-test-connect)))
          (should (plist-get (harness-acp-remote-test-call c2 1 "_harness/harness/version") :result))
          ;; Unpairing closes both.
          (should (eq t (harness-call 'acp/remote-revoke (plist-get device :id))))
          (harness-test-wait (lambda () (and (harness-acp-remote-test-ws-closed c)
                                             (harness-acp-remote-test-ws-closed c2)))
                             5 "the connections to close")
          (should (null (plist-get (harness-call 'acp/remote-status) :devices))))))))

(ert-deftest harness-acp-remote-http-routes ()
  (harness-acp-remote-test-with
    (should (= 200 (car (harness-acp-remote-test-get "/"))))
    (should (string-search "pairing QR code" (nth 2 (harness-acp-remote-test-get "/"))))
    (should (= 404 (car (harness-acp-remote-test-get "/nothing"))))
    (should (= 405 (car (harness-acp-remote-test-http "POST /acp HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n"))))
    (should (= 403 (car (harness-acp-remote-test-get "/pair?code=wrong"))))
    (should (= 400 (car (harness-acp-remote-test-http "garbage that is not http\r\n\r\n"))))
    ;; From this machine itself the link is refused, and stays valid.
    (let ((path (harness-acp-remote-test-pair-path)))
      (let ((harness-acp-remote--allow-loopback nil))
        (pcase-let ((`(,status ,_ ,body) (harness-acp-remote-test-get path)))
          (should (= 403 status))
          (should (string-search "device to pair" body))))
      (should (= 200 (car (harness-acp-remote-test-get path)))))))

(ert-deftest harness-acp-remote-codes-expire ()
  (harness-acp-remote-test-with
    (let ((harness-acp-remote-code-lifetime 0.2))
      (let ((path (harness-acp-remote-test-pair-path)))
        (sleep-for 0.3)
        (should (= 403 (car (harness-acp-remote-test-get path)))))
      ;; A newer code replaces an older one.
      (let ((harness-acp-remote-code-lifetime 600))
        (let ((old (harness-acp-remote-test-pair-path))
              (new (harness-acp-remote-test-pair-path)))
          (should (= 403 (car (harness-acp-remote-test-get old))))
          (should (= 200 (car (harness-acp-remote-test-get new)))))))
    ;; An unused pairing lapses.
    (let ((harness-acp-remote-idle-timeout 0))
      (sleep-for 0.01)
      (should (null (plist-get (harness-call 'acp/remote-status) :devices))))
    ;; An authenticate gives up after the code lifetime.
    (let ((harness-acp-remote-code-lifetime 0.3)
          (c (harness-acp-remote-test-connect)))
      (let ((answer (harness-acp-remote-test-call c 1 "authenticate" '(:methodId "pair"))))
        (should (= -32000 (harness-acp-remote-test-code answer)))))))

(ert-deftest harness-acp-remote-bearer-token ()
  (harness-acp-remote-test-with
    (let ((harness-acp-token "s3cret"))
      (let ((c (harness-acp-remote-test-connect :protocols '("acp.v1" "bearer.s3cret"))))
        (should (member "Sec-WebSocket-Protocol: acp.v1" (harness-acp-remote-test-ws-headers c)))
        (should (plist-get (harness-acp-remote-test-call c 1 "_harness/harness/version") :result)))
      (let ((c (harness-acp-remote-test-connect :path "/acp?token=s3cret")))
        (should (plist-get (harness-acp-remote-test-call c 1 "_harness/harness/version") :result)))
      (let ((c (harness-acp-remote-test-connect :headers '(("Authorization" . "Bearer s3cret")))))
        (should (plist-get (harness-acp-remote-test-call c 1 "_harness/harness/version") :result)))
      (let ((c (harness-acp-remote-test-connect :protocols '("bearer.wrong"))))
        (should (member "Sec-WebSocket-Protocol: bearer.wrong" (harness-acp-remote-test-ws-headers c)))
        (should (= -32000 (harness-acp-remote-test-code (harness-acp-remote-test-call c 1 "_harness/harness/version"))))
        (should (= -32000 (harness-acp-remote-test-code
                           (harness-acp-remote-test-call c 2 "authenticate" '(:methodId "token" :token "nope")))))
        (should-not (plist-get (harness-acp-remote-test-call c 3 "authenticate" '(:methodId "token" :token "s3cret"))
                               :error))
        (should (plist-get (harness-acp-remote-test-call c 4 "_harness/harness/version") :result))))))

(ert-deftest harness-acp-remote-web-pages-do-not-ride-a-pairing ()
  "A WebSocket a web page opens on a paired device is not let in by the pairing."
  (harness-acp-remote-test-with
    (should (= 200 (car (harness-acp-remote-test-get (harness-acp-remote-test-pair-path)))))
    (let ((c (harness-acp-remote-test-connect :headers '(("Origin" . "https://evil.example")))))
      (should (null (plist-get (plist-get (harness-acp-remote-test-call c 1 "initialize" '(:protocolVersion 1)) :result)
                               :authMethods)))
      (should (= -32000 (harness-acp-remote-test-code (harness-acp-remote-test-call c 2 "_harness/harness/version"))))
      (should (= -32000 (harness-acp-remote-test-code
                         (harness-acp-remote-test-call c 3 "authenticate" '(:methodId "pair"))))))
    ;; An app's own web view is not a web page.
    (let ((c (harness-acp-remote-test-connect :headers '(("Origin" . "http://tauri.localhost")))))
      (should (plist-get (harness-acp-remote-test-call c 1 "_harness/harness/version") :result)))))

(ert-deftest harness-acp-remote-plain-tcp ()
  "ACP's own line framing on the same port."
  (harness-acp-remote-test-with
    (let* ((lines nil) (buf "")
           (proc (make-network-process
                  :name "acp-remote-test-tcp" :host "127.0.0.1" :service harness-acp-remote-test-port
                  :coding 'binary :noquery t
                  :filter (lambda (_p chunk)
                            (setq buf (concat buf chunk))
                            (let (nl)
                              (while (setq nl (string-search "\n" buf))
                                (push (harness-json-parse (decode-coding-string (substring buf 0 nl) 'utf-8)) lines)
                                (setq buf (substring buf (1+ nl)))))))))
      (unwind-protect
          (let ((ask (lambda (id)
                       (process-send-string
                        proc (format "{\"jsonrpc\":\"2.0\",\"id\":%d,\"method\":\"_harness/harness/version\",\"params\":{}}\n" id))
                       (harness-test-wait (lambda () (cl-find id lines :key (lambda (m) (plist-get m :id)))) 5 "an answer")
                       (cl-find id lines :key (lambda (m) (plist-get m :id))))))
            (should (= -32000 (harness-acp-remote-test-code (funcall ask 1))))
            (should (= 200 (car (harness-acp-remote-test-get (harness-acp-remote-test-pair-path)))))
            (should (plist-get (funcall ask 2) :result))
            (should (= 1 (length (cl-remove-if-not (lambda (c) (eq (harness-acp-client-kind c) 'remote-tcp))
                                                   harness-acp--clients)))))
        (delete-process proc)))))

(ert-deftest harness-acp-remote-ping-pong-and-close ()
  (harness-acp-remote-test-with
    (let ((c (harness-acp-remote-test-connect)))
      (process-send-string (harness-acp-remote-test-ws-proc c)
                           (harness-acp-remote-ws-frame 'ping "hi" (unibyte-string 1 1 1 1)))
      (harness-test-wait (lambda () (assq 'pong (harness-acp-remote-test-ws-events c))) 5 "the pong")
      (should (equal '(pong . "hi") (assq 'pong (harness-acp-remote-test-ws-events c))))
      ;; An unmasked frame is a protocol error: the server closes with 1002.
      (process-send-string (harness-acp-remote-test-ws-proc c) (harness-acp-remote-ws-frame 'text "{}"))
      (harness-test-wait (lambda () (harness-acp-remote-test-ws-closed c)) 5 "the close")
      (should (equal 1002 (cadr (assq 'close (harness-acp-remote-test-ws-events c)))))
      (harness-test-wait (lambda () (null (harness-acp-remote--clients))) 5 "the client to go"))))

(ert-deftest harness-acp-remote-methods-over-acp ()
  "The UI reaches the methods as `_harness/acp/remote-…' over its own connection."
  (harness-acp-remote-test-with
    (let ((conn (harness-acp-connect nil)))
      (unwind-protect
          (let ((status (harness-test-await (harness-acp-request conn "_harness/acp/remote-status" nil))))
            (should (eq t (plist-get status :running)))
            (should (equal (format "ws://127.0.0.1:%d/acp" harness-acp-remote-test-port) (plist-get status :ws-url)))
            (should (string-prefix-p "http://127.0.0.1:"
                                     (plist-get (harness-test-await (harness-acp-request conn "_harness/acp/remote-pair" nil))
                                                :url)))
            (let ((set (harness-test-await (harness-acp-request conn "_harness/acp/remote-set-address"
                                                                '(:address "192.0.2.5")))))
              (should (equal "192.0.2.5" (plist-get set :address)))
              (should (equal "ws://192.0.2.5:%d/acp" (replace-regexp-in-string "[0-9]+/acp\\'" "%d/acp" (plist-get set :ws-url))))
              ;; The code in force named the old address: it is gone.
              (should (null (plist-get set :code-expires))))
            (should (equal "127.0.0.1" (plist-get (harness-test-await (harness-acp-request conn "_harness/acp/remote-set-address"
                                                                                           '(:address "")))
                                                  :address))))
        (harness-acp-close conn)))))

(ert-deftest harness-acp-remote-start-and-stop ()
  (harness-acp-remote-test-with
    (harness-acp-remote--stop)
    (should (eq :false (plist-get (harness-call 'acp/remote-status) :running)))
    (let ((status (harness-call 'acp/remote-start)))
      (should (eq t (plist-get status :running)))
      (should (eq t (plist-get status :enabled))))
    (setq harness-acp-remote-test-port (harness-acp-remote--port))
    (should (= 200 (car (harness-acp-remote-test-get (harness-acp-remote-test-pair-path)))))
    (let ((status (harness-call 'acp/remote-stop)))
      (should (eq :false (plist-get status :running)))
      (should (eq :false (plist-get status :enabled)))
      ;; Stopping forgets every pairing.
      (should (null (plist-get status :devices))))
    (should-error (harness-call 'acp/remote-pair) :type 'harness-error)))

(ert-deftest harness-acp-remote-corporate-mode ()
  (harness-acp-remote-test-with
    (let ((c (harness-acp-remote-test-connect)))
      (should (= 200 (car (harness-acp-remote-test-get (harness-acp-remote-test-pair-path)))))
      (should (plist-get (harness-acp-remote-test-call c 1 "_harness/harness/version") :result))
      (let ((harness-corporate-mode t))
        ;; Everything is refused while it is on: calls on an open
        ;; connection, and new connections, closed unanswered.
        (should (= -32000 (harness-acp-remote-test-code (harness-acp-remote-test-call c 2 "_harness/harness/version"))))
        (should (= 0 (car (harness-acp-remote-test-get "/"))))
        (should-error (harness-call 'acp/remote-pair) :type 'harness-error)
        ;; Turning it on stops the listener and closes the connections.
        (run-hooks 'harness-corporate-mode-change-hook)
        (harness-test-wait (lambda () (harness-acp-remote-test-ws-closed c)) 5 "the connection to close")
        (should (eq :false (plist-get (harness-call 'acp/remote-status) :running)))
        (should (null (plist-get (harness-call 'acp/remote-status) :devices)))
        (should-error (harness-call 'acp/remote-start) :type 'harness-error)
        ;; And the module does not start serving with it.
        (let ((harness-acp-remote t))
          (harness-acp-remote--init)
          (should-not (harness-acp-remote--running-p)))))))

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

(defun harness-acp-remote-test-idle-socket ()
  "Open a socket to the test listener that sends nothing; return (PROC . CLOSED-CELL)."
  (let* ((closed (list nil))
         (proc (make-network-process
                :name "acp-remote-test-idle" :host "127.0.0.1" :service harness-acp-remote-test-port
                :coding 'binary :noquery t
                :sentinel (lambda (p _e) (unless (process-live-p p) (setcar closed t))))))
    (cons proc closed)))

(ert-deftest harness-acp-remote-limits ()
  "Silent connections time out, too many are refused, one pairing wait per client."
  (harness-acp-remote-test-with
    (let ((harness-acp-remote--request-timeout 0.3))
      (pcase-let ((`(,proc . ,closed) (harness-acp-remote-test-idle-socket)))
        (harness-test-wait (lambda () (car closed)) 5 "the silent connection to close")
        (delete-process proc)))
    (let ((harness-acp-remote--max-connections 2)
          (sockets nil))
      (unwind-protect
          (progn
            (dotimes (_ 3) (push (harness-acp-remote-test-idle-socket) sockets))
            (harness-test-wait (lambda () (car (cdr (car sockets)))) 5 "the third connection to close")
            (accept-process-output nil 0.2)
            (should-not (car (cdr (nth 1 sockets))))
            (should-not (car (cdr (nth 2 sockets)))))
        (dolist (s sockets) (delete-process (car s)))))
    (let ((c (harness-acp-remote-test-connect)))
      (harness-acp-remote-test-send c '(:jsonrpc "2.0" :id 1 :method "authenticate" :params (:methodId "pair")))
      (let ((second (progn (accept-process-output nil 0.1)
                           (harness-acp-remote-test-send c '(:jsonrpc "2.0" :id 2 :method "authenticate"
                                                                    :params (:methodId "pair")))
                           (harness-test-wait (lambda () (harness-acp-remote-test-answer c 1)) 5 "the first wait"))))
        (should (= -32000 (harness-acp-remote-test-code second)))
        (should (= 1 (length harness-acp-remote--waiting)))
        (should (= 200 (car (harness-acp-remote-test-get (harness-acp-remote-test-pair-path)))))
        (should-not (plist-get (harness-test-wait (lambda () (harness-acp-remote-test-answer c 2)) 5 "the second wait")
                               :error))))))

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
        (harness-acp-remote-port 4276))
    (should (equal "ws://[fd00::1]:4276/acp" (harness-acp-remote--ws-url)))))

(provide 'harness-acp-remote-test)
;;; harness-acp-remote-test.el ends here
