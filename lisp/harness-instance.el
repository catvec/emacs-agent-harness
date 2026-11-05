;;; harness-instance.el --- The identity and secret of one harness process  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; A harness process is one instance.  Another local process -- a
;; second harness, a client of one, or a program looking for a loopback
;; listener to drive -- must not be able to reach the tool servers this
;; instance runs.  So each instance has an identity and a secret, made
;; when it starts and kept only in its memory:
;;
;; - `harness-instance-id' names the instance in the clear.  It is
;;   random, never a path or a pid, so two instances started in the
;;   same directory on the same machine are still different.  A client
;;   can compare it with the id it was given, and a server sends it in
;;   a challenge so that a client can tell the harness it means from
;;   another program that took its port.
;; - `harness-instance-token' is 256 random bits.  It never goes in a
;;   plugin file, a command line or a protocol message to a party that
;;   has not proved it is this instance; a child gets it in the
;;   environment it inherits, and the ACP bridge gets it from the
;;   0600 `acp-token' file the harness writes (see harness-acp.el).
;;
;; What a single connection gets is narrower than the instance token:
;; `harness-instance-credential' derives a secret for one label with
;; HMAC-SHA256 under the instance token.  A worker holds only its own
;; credential, so reading it gives nothing of the instance, and the
;; label (server, session, process) says which connection it belongs
;; to.  The comparison is `harness-instance-equal-p', which takes as
;; long whether two strings differ in the first character or the last.
;;
;; This is not mutual TLS: Emacs has no TLS server, and both ends of
;; these transports are local programs (or, for remote ACP, a transport
;; that has its own session secrets; see docs/trust-model.md).  What it
;; buys is the property the harness needs: a client that does not hold
;; this instance's secret cannot connect to or drive its MCP servers,
;; and a client of another instance is refused however well it speaks
;; the protocol.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defconst harness-instance-id-prefix "hi1_"
  "What every harness instance id starts with.")

(defconst harness-instance-token-prefix "ht1_"
  "What every harness instance token starts with.")

(defconst harness-instance-credential-prefix "hc1_"
  "What every derived connection credential starts with.")

(defconst harness-instance--blocks 64
  "The HMAC block size of SHA-256, in bytes.")

(defun harness-instance--random-bytes (n)
  "Return N cryptographically random bytes, from /dev/urandom if it can be read.
A system without one falls back to Emacs's own entropy and says so in
the log: a token that is not made from the kernel's randomness is
weaker, and the user should know."
  (or (condition-case nil
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally "/dev/urandom" nil 0 n)
            (and (= (buffer-size) n) (buffer-string)))
        (error nil))
      (progn
        (harness-log 'warn "instance: no system source of random bytes; tokens are weaker than they should be")
        (substring (secure-hash 'sha512
                                (format "%s %s %s %s %s"
                                        (random t) (float-time) (emacs-pid)
                                        (current-time) (list (garbage-collect)))
                                nil nil t)
                   0 n))))

(defun harness-instance--new-id ()
  "Return a new instance id."
  (concat harness-instance-id-prefix
          (base64url-encode-string (harness-instance--random-bytes 16) t)))

(defun harness-instance--new-token ()
  "Return a new instance token: 256 random bits, as text."
  (concat harness-instance-token-prefix
          (base64url-encode-string (harness-instance--random-bytes 32) t)))

(defun harness-instance-random-string (&optional bytes)
  "Return BYTES (default 16) random bytes in base64url, without padding.
For a nonce or an id whose only job is to be different each time."
  (base64url-encode-string (harness-instance--random-bytes (or bytes 16)) t))

(defvar harness-instance-id (harness-instance--new-id)
  "The identity of this harness process.
It is random and made when the process starts.  Unlike the token it is
not secret: a client compares it with what the harness told it, and a
server sends it in a challenge so that a client can tell this harness
from another program that took its port.")

(defvar harness-instance-token (harness-instance--new-token)
  "The secret of this harness process: 256 random bits, made at start.
It is never written into the plugin directory, never put on a command
line, and only a child of this instance, the 0600 acp-token file, or a
server the harness is starting is given it.  The ACP server uses it,
and `harness-instance-credential' derives narrower secrets from it.")

(defun harness-instance-id-p (value)
  "Non-nil when VALUE looks like an instance id this library makes."
  (and (stringp value)
       (string-match-p "\\`hi1_[A-Za-z0-9_-]\\{20,64\\}\\'" value)))

(defun harness-instance-token-p (value)
  "Non-nil when VALUE looks like an instance token or a derived credential."
  (and (stringp value)
       (or (string-match-p "\\`ht1_[A-Za-z0-9_-]\\{40,64\\}\\'" value)
           (string-match-p "\\`hc1_[A-Za-z0-9_-]\\{40,64\\}\\'" value))))

(defun harness-instance--bytes (string)
  "Return STRING as a unibyte string of its UTF-8 bytes."
  (if (multibyte-string-p string) (encode-coding-string string 'utf-8 t) string))

(defun harness-instance--xor (bytes pad)
  "Return BYTES with every byte exclusive-ored with PAD."
  (apply #'unibyte-string (mapcar (lambda (b) (logxor b pad)) bytes)))

(defun harness-instance-hmac-sha256 (key data)
  "Return the HMAC-SHA256 of DATA under KEY, as raw bytes.
KEY and DATA are text, encoded as UTF-8."
  (let* ((key (harness-instance--bytes key))
         (key (if (> (length key) harness-instance--blocks)
                  (secure-hash 'sha256 key nil nil t)
                key))
         (key (concat key (make-string (- harness-instance--blocks (length key)) 0))))
    (secure-hash 'sha256
                 (concat (harness-instance--xor key #x5c)
                         (secure-hash 'sha256
                                      (concat (harness-instance--xor key #x36)
                                              (harness-instance--bytes data))
                                      nil nil t))
                 nil nil t)))

(cl-defun harness-instance-credential (label &optional (token harness-instance-token))
  "Return the credential for LABEL under this instance's TOKEN.
LABEL says what the credential is for -- a server, a session, a
process -- so two connections never share a secret.  The result is
HMAC-SHA256 under the instance token, in base64url with a prefix, and
it reveals nothing about the token."
  (unless (stringp label)
    (error "An instance credential needs a label: %S" label))
  (concat harness-instance-credential-prefix
          (base64url-encode-string
           (harness-instance-hmac-sha256 token (concat "harness-credential\0" label))
           t)))

(defun harness-instance-equal-p (a b)
  "Non-nil when the strings A and B are equal.
It takes as long when they differ in the first character as in the
last."
  (and (stringp a) (stringp b)
       (= (length a) (length b))
       (let ((diff 0))
         (dotimes (i (length a))
           (setq diff (logior diff (logxor (aref a i) (aref b i)))))
         (zerop diff))))

(defun harness-instance-id-state ()
  "Return a description of this instance for the status views.
The token is never part of it."
  (list :id harness-instance-id :token-set (and (stringp harness-instance-token) t)))

(provide 'harness-instance)
;;; harness-instance.el ends here
