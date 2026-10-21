;;; harness-ui-acp-remote-test.el --- Tests for the remote control page  -*- lexical-binding: t; -*-

;;; Commentary:

;; The page against the real acp-remote module, through the UI's own
;; ACP connection: the devices that wait to be approved and approving or
;; refusing them, what tells the user of one, the devices signed in and
;; revoking them, a token for a device, the line about encryption and the
;; sign-in link, corporate mode.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-acp--server-enabled)
(defvar harness-acp-remote)

(defmacro harness-ui-acp-remote-test-with (&rest body)
  "Run BODY with the UI connected in-process to a harness that may serve devices."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (let ((harness-acp--server-enabled nil) (harness-acp-remote nil))
       (dolist (m '(acp acp-remote ui ui-acp-remote)) (harness-test-load-module m)))
     (let ((harness-acp-token nil)
           (harness-acp-remote nil)
           (harness-acp-remote-host "127.0.0.1")
           (harness-acp-remote-port 0)
           (harness-acp-remote-address nil)
           (harness-acp-remote-public-url nil)
           (harness-acp-remote-approval t)
           (harness-acp-remote-approval-timeout 30)
           (harness-acp-remote-oidc-issuer nil)
           (harness-acp-remote-oidc-client-id nil)
           (harness-acp-remote-oidc-allowed nil)
           (harness-corporate-mode nil))
       (setq harness-acp-remote--sessions nil harness-acp-remote--sessions-loaded nil
             harness-acp-remote--approvals nil harness-ui-acp-remote--waiting nil
             harness-ui-acp-remote--seen nil)
       (clrhash harness-acp-remote--failures)
       (clrhash harness-acp-remote--requests)
       (unwind-protect (progn ,@body)
         (dolist (name (list harness-ui-acp-remote-buffer-name harness-ui-acp-remote-token-buffer-name))
           (when (get-buffer name) (kill-buffer name)))
         (harness-acp-remote--stop)
         (dolist (c (copy-sequence harness-acp--clients)) (harness-acp--drop-client c))))))

(defun harness-ui-acp-remote-test-open ()
  "Open the page and wait for its status; return the buffer."
  (harness-remote-control)
  (let ((buf (get-buffer harness-ui-acp-remote-buffer-name)))
    (harness-test-wait (lambda () (buffer-local-value 'harness-ui-acp-remote--status buf)) 15 "the status")
    (set-buffer buf)
    buf))

(defun harness-ui-acp-remote-test-text ()
  "Return the page's text."
  (with-current-buffer harness-ui-acp-remote-buffer-name (buffer-substring-no-properties (point-min) (point-max))))

(defconst harness-ui-acp-remote-test-agent
  "Mozilla/5.0 (Linux; Android 14) Chrome/129.0 Mobile Safari/537.36"
  "What the browser of the phone in these tests says it is.")

(defun harness-ui-acp-remote-test-ask-to-sign-in (&optional address)
  "Make a device at ADDRESS ask to be approved; return (CLIENT . PROMISE).
It is a connection with no session that never carries a byte: a pipe
stands for its socket, and what `authenticate' waits for is the promise."
  (let* ((proc (make-pipe-process :name "ui-remote-test-socket" :noquery t))
         (client (harness-acp-add-client
                  'websocket :process proc :writer #'ignore
                  :remote (list :transport "websocket" :address (or address "192.168.1.23")
                                :agent harness-ui-acp-remote-test-agent))))
    (harness-acp--client-set client 'hello '(:name "acp-ui" :title "ACP UI" :version "0.9.1"))
    (cons client (harness-acp-remote--request-approval client))))

(ert-deftest harness-ui-acp-remote-start-serving ()
  (harness-ui-acp-remote-test-with
    (harness-ui-acp-remote-test-open)
    (let ((text (harness-ui-acp-remote-test-text)))
      (should (string-search "not served" text))
      (should (string-search "[start serving]" text))
      (should (string-search "start serving, and a device can ask" text))
      (should (string-search "no device signed in yet" text)))
    (should-error (harness-ui-acp-remote-create-token "Phone") :type 'user-error)
    (harness-ui-acp-remote-toggle-serving)
    (harness-test-wait (lambda () (harness-ui-acp-remote--true :running)) 15 "serving")
    (let ((text (harness-ui-acp-remote-test-text)))
      (should (string-search (format "served on port %s" (harness-acp-remote--port)) text))
      (should (string-search "a device that chooses \"Approve in Emacs\" in its ACP client shows here" text))
      (should (string-search "Sign in with" text))
      (should (string-search "Approve in Emacs" text))
      (should-not (string-search "█" text))
      (should-not (string-search "QR" text)))
    (should (eq t harness-acp-remote))))

(ert-deftest harness-ui-acp-remote-a-device-that-asks-is-shown-and-approved ()
  "The page shows who asks and the code to compare; approving signs the connection in."
  (harness-ui-acp-remote-test-with
    (harness-acp-remote--listen)
    (harness-ui-acp-remote-test-open)
    (should (string-search "none: a device that chooses" (harness-ui-acp-remote-test-text)))
    (pcase-let* ((`(,client . ,promise) (harness-ui-acp-remote-test-ask-to-sign-in))
                 (code (plist-get (harness-acp-client-remote-info client) :code)))
      ;; The harness says so, and the page follows.
      (harness-test-wait (lambda () (string-search "Waiting for approval" (harness-ui-acp-remote-test-text))) 15 "the page")
      (harness-test-wait (lambda () (string-search code (harness-ui-acp-remote-test-text))) 15 "the code")
      (let ((text (harness-ui-acp-remote-test-text)))
        (should (string-search "ACP UI 0.9.1 · Android" text))
        (should (string-search "192.168.1.23" text))
        (should (string-search (format "code %s" code) text))
        (should (string-search "[approve]" text))
        (should (string-search "[deny]" text)))
      (should (= 1 (length harness-ui-acp-remote--waiting)))
      ;; It asks which device, with the code, and does nothing when the answer is no.
      (let ((asked nil))
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (prompt) (setq asked prompt) nil)))
          (harness-ui-acp-remote-approve))
        (accept-process-output nil 0.2)
        (should (string-search code asked))
        (should (string-search "ACP UI 0.9.1" asked))
        (should (eq 'pending (harness-promise-state promise))))
      ;; Yes signs it in.
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (harness-ui-acp-remote-approve))
      (harness-test-wait (lambda () (eq 'resolved (harness-promise-state promise))) 15 "the approval")
      (harness-test-wait (lambda () (string-search "approved in Emacs" (harness-ui-acp-remote-test-text))) 15 "the device")
      (let ((text (harness-ui-acp-remote-test-text)))
        (should (string-search "this connection only" text))
        (should (string-search "none: a device that chooses" text))
        (should (string-search "[revoke]" text)))
      (should (null harness-ui-acp-remote--waiting)))))

(ert-deftest harness-ui-acp-remote-a-device-may-be-refused ()
  (harness-ui-acp-remote-test-with
    (harness-acp-remote--listen)
    (harness-ui-acp-remote-test-open)
    (pcase-let ((`(,_ . ,promise) (harness-ui-acp-remote-test-ask-to-sign-in)))
      (harness-test-wait (lambda () harness-ui-acp-remote--waiting) 15 "the request")
      (harness-ui-acp-remote-refresh)
      (harness-test-wait (lambda () (plist-get harness-ui-acp-remote--status :approvals)) 15 "the page")
      ;; Point on its line: more than one may wait, and then the line says which.
      (goto-char (point-min))
      (search-forward "ACP UI")
      (harness-ui-acp-remote-deny)
      (harness-test-wait (lambda () (eq 'rejected (harness-promise-state promise))) 15 "the refusal")
      (should (string-search "refused" (nth 2 (harness-promise-value promise))))
      (harness-test-wait (lambda () (null harness-ui-acp-remote--waiting)) 15 "the page to follow")
      (should (null harness-acp-remote--sessions)))
    ;; With none waiting there is nothing to approve or refuse.
    (should-error (harness-ui-acp-remote-approve) :type 'user-error)
    (should-error (harness-ui-acp-remote-deny) :type 'user-error)))

(ert-deftest harness-ui-acp-remote-with-several-waiting-point-says-which ()
  (harness-ui-acp-remote-test-with
    (harness-acp-remote--listen)
    (harness-ui-acp-remote-test-open)
    (pcase-let ((`(,_ . ,first) (harness-ui-acp-remote-test-ask-to-sign-in "192.168.1.23"))
                (`(,_ . ,second) (harness-ui-acp-remote-test-ask-to-sign-in "192.168.1.99")))
      (harness-ui-acp-remote-refresh)
      (harness-test-wait (lambda () (= 2 (length (plist-get harness-ui-acp-remote--status :approvals)))) 15 "both")
      ;; Not on either: which?
      (goto-char (point-min))
      (should-error (harness-ui-acp-remote-approve) :type 'user-error)
      (goto-char (point-min))
      (search-forward "192.168.1.99")
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (harness-ui-acp-remote-approve))
      (harness-test-wait (lambda () (eq 'resolved (harness-promise-state second))) 15 "the second")
      (should (eq 'pending (harness-promise-state first))))))

(ert-deftest harness-ui-acp-remote-the-user-is-told-without-the-page ()
  "A request is announced in the echo area and counted for the mode line notifier."
  (harness-ui-acp-remote-test-with
    (harness-acp-remote--listen)
    (should-not (harness-ui-acp-remote--segment))
    (let ((told nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) told))))
        (pcase-let ((`(,client . ,_) (harness-ui-acp-remote-test-ask-to-sign-in)))
          (harness-test-wait (lambda () harness-ui-acp-remote--waiting) 15 "the request")
          (should (cl-some (lambda (m) (and (string-search "asks to sign in" m)
                                            (string-search (plist-get (harness-acp-client-remote-info client) :code) m)
                                            (string-search "C-c h y" m)))
                           told))))
      ;; Once, not at every change.
      (let ((n (length told)))
        (harness-ui-acp-remote--refresh (get-buffer-create "*harness remote*"))
        (accept-process-output nil 0.3)
        (should (<= (length told) (1+ n)))))
    (let ((segment (harness-ui-acp-remote--segment)))
      (should (string-match-p "1" segment))
      (should (string-search "asks to sign in" (get-text-property 0 'help-echo segment)))
      (should (commandp (lookup-key (get-text-property 0 'local-map segment) [mode-line mouse-1]))))
    ;; Without a page, and by the command: approving what waits.
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (harness-remote-approve)
      (harness-test-wait (lambda () (and (null harness-ui-acp-remote--waiting) harness-acp-remote--sessions))
                         15 "the approval"))
    (should-not (harness-ui-acp-remote--segment))
    (let ((told nil))
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) told))))
        (harness-remote-approve)
        (harness-test-wait (lambda () told) 15 "the answer"))
      (should (string-search "no device waits" (car told))))))

(ert-deftest harness-ui-acp-remote-a-token-for-a-device ()
  "A token is shown once, in a buffer of its own, with what to put where."
  (harness-ui-acp-remote-test-with
    (harness-acp-remote--listen)
    (harness-ui-acp-remote-test-open)
    (harness-ui-acp-remote-create-token "Tablet")
    (harness-test-wait (lambda () (get-buffer harness-ui-acp-remote-token-buffer-name)) 15 "the token")
    (with-current-buffer harness-ui-acp-remote-token-buffer-name
      (let ((text (buffer-substring-no-properties (point-min) (point-max)))
            (token (car harness-acp-remote--sessions)))
        (should (string-search "Tablet" (format "%s" header-line-format)))
        (should (string-match "\\(hs1_[A-Za-z0-9_-]\\{43\\}\\)" text))
        (should (equal (harness-acp-remote--hash (match-string 1 text)) (plist-get token :hash)))
        (should (string-search (format "ws://127.0.0.1:%s/acp" (harness-acp-remote--port)) text))
        (should (string-search "Authorization: Bearer TOKEN" text))
        (should (string-search "shown here once" text))
        ;; Its buttons copy.
        (let ((secret (progn (string-match "\\(hs1_[A-Za-z0-9_-]\\{43\\}\\)" text) (match-string 1 text))))
          (goto-char (point-min))
          (search-forward "Token")
          (push-button (next-button (point)))
          (should (equal secret (car kill-ring))))))
    ;; The page lists the device, with a token's way of signing in.
    (harness-ui-acp-remote-refresh)
    (harness-test-wait (lambda () (string-search "Tablet" (harness-ui-acp-remote-test-text))) 15 "the device")
    (should (string-match-p "Tablet +[^ ]* *token, seen .*, until " (harness-ui-acp-remote-test-text)))
    ;; And the secret is on no page.
    (should-not (string-search "hs1_" (harness-ui-acp-remote-test-text)))))

(ert-deftest harness-ui-acp-remote-devices-and-revoking ()
  "Each session shows its name, how it signed in, when it was seen and when it ends."
  (harness-ui-acp-remote-test-with
    (harness-acp-remote--listen)
    (let* ((first (harness-acp-remote--mint "Pixel 8" harness-ui-acp-remote-test-agent "192.168.1.23" "token"))
           (second (harness-acp-remote--mint "Work laptop · me@example.com" "Dart/3.13" "10.0.0.7" "oidc" "u-1"))
           (third (harness-acp-remote--mint "Headless" "curl/8" "10.0.0.8" "shared-secret"))
           (fourth (harness-acp-remote--mint "ACP UI 0.9.1" "x" "10.0.0.9" "approval" nil t)))
      (ignore first second third fourth)
      (harness-ui-acp-remote-test-open)
      (let ((text (harness-ui-acp-remote-test-text)))
        (should (string-search "Signed-in devices" text))
        (should (string-match-p "Pixel 8 +192\\.168\\.1\\.23 +token, seen .*, until " text))
        (should (string-match-p "Work laptop · me@example.com +10\\.0\\.0\\.7 +OpenID Connect, seen" text))
        (should (string-match-p "Headless +10\\.0\\.0\\.8 +shared secret, seen" text))
        (should (string-match-p "ACP UI 0\\.9\\.1 +10\\.0\\.0\\.9 +approved in Emacs, seen .*, this connection only" text))
        (should (string-search "[make a token]" text))
        (should (string-search "[revoke all]" text)))
      ;; A device with a connection open says so.
      (let ((conn (harness-acp-add-client
                   'websocket :writer #'ignore
                   :remote (list :transport "websocket" :address "192.168.1.23"
                                 :session-id (plist-get (cl-find "Pixel 8" harness-acp-remote--sessions
                                                                 :key (lambda (s) (plist-get s :name)) :test #'equal)
                                                        :id)))))
        (harness-ui-acp-remote-refresh)
        (harness-test-wait (lambda () (string-search "connected" (harness-ui-acp-remote-test-text))) 15 "connected")
        (harness-acp-drop-client conn))
      ;; Revoke one.
      (goto-char (point-min))
      (search-forward "Headless")
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (harness-ui-acp-remote-revoke))
      (harness-test-wait (lambda () (not (string-search "Headless" (harness-ui-acp-remote-test-text)))) 15 "revoked")
      (should (= 3 (length harness-acp-remote--sessions)))
      ;; Declining changes nothing.
      (goto-char (point-min))
      (search-forward "Pixel 8")
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (harness-ui-acp-remote-revoke))
      (accept-process-output nil 0.2)
      (should (= 3 (length harness-acp-remote--sessions)))
      ;; Off a device's line there is nothing to revoke.
      (goto-char (point-min))
      (should-error (harness-ui-acp-remote-revoke) :type 'user-error)
      ;; All of them.
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (harness-ui-acp-remote-revoke-all))
      (harness-test-wait (lambda () (string-search "no device signed in yet" (harness-ui-acp-remote-test-text)))
                         15 "all revoked")
      (should (null harness-acp-remote--sessions))
      (should-error (harness-ui-acp-remote-revoke-all) :type 'user-error))))

(ert-deftest harness-ui-acp-remote-encryption-and-sign-in-link ()
  (harness-ui-acp-remote-test-with
    (harness-acp-remote--listen)
    (harness-ui-acp-remote-test-open)
    (let ((text (harness-ui-acp-remote-test-text)))
      (should (string-search "Encryption" text))
      (should (string-search "none: use a VPN such as Tailscale, or a TLS proxy and harness-acp-remote-public-url" text))
      (should-not (string-search "OpenID Connect" text)))
    (should-error (harness-ui-acp-remote-copy-login-link) :type 'user-error)
    ;; Behind a TLS proxy, with OpenID Connect set up.
    (let ((harness-acp-remote-public-url "https://harness.example.com")
          (harness-acp-remote-oidc-issuer "https://auth.example.com/application/o/harness/")
          (harness-acp-remote-oidc-client-id "harness"))
      (harness-ui-acp-remote-refresh)
      (harness-test-wait (lambda () (string-search "OpenID Connect" (harness-ui-acp-remote-test-text))) 15 "the row")
      (let ((text (harness-ui-acp-remote-test-text)))
        (should (string-search "encrypted on its way (https, or a VPN)" text))
        (should (string-search "wss://harness.example.com/acp" text))
        (should (string-search "OpenID Connect, https://auth.example.com/application/o/harness/" text))
        (should (string-search "[copy login link]" text))
        ;; Nobody is allowed until the owner says who.
        (should (string-search "nobody is allowed yet: set harness-acp-remote-oidc-allowed" text)))
      (let ((harness-acp-remote-oidc-allowed '("harness-users")))
        (harness-ui-acp-remote-refresh)
        (harness-test-wait (lambda () (not (string-search "nobody is allowed yet" (harness-ui-acp-remote-test-text))))
                           15 "the warning to go"))
      (harness-ui-acp-remote-copy-login-link)
      (should (equal "https://harness.example.com/login" (car kill-ring))))
    ;; Approval can be turned off, and the page says so.
    (let ((harness-acp-remote-approval nil))
      (harness-ui-acp-remote-refresh)
      (harness-test-wait (lambda () (string-search "approval in Emacs is off" (harness-ui-acp-remote-test-text)))
                         15 "the warning"))))

(ert-deftest harness-ui-acp-remote-copying ()
  (harness-ui-acp-remote-test-with
    (harness-acp-remote--listen)
    (harness-ui-acp-remote-test-open)
    (harness-ui-acp-remote-copy-address)
    (should (equal (format "ws://127.0.0.1:%s/acp" (harness-acp-remote--port)) (car kill-ring)))))

(ert-deftest harness-ui-acp-remote-corporate-mode ()
  (harness-ui-acp-remote-test-with
    (let ((harness-corporate-mode t))
      (harness-ui-acp-remote-test-open)
      (should (string-search "Corporate mode is on" (harness-ui-acp-remote-test-text)))
      (should-not (string-search "Waiting for approval" (harness-ui-acp-remote-test-text)))
      (should-error (harness-ui-acp-remote-toggle-serving) :type 'user-error)
      (should-error (harness-ui-acp-remote-approve) :type 'user-error)
      (should-error (harness-ui-acp-remote-create-token "x") :type 'user-error)
      (should-error (harness-ui-acp-remote-revoke-all) :type 'user-error))))

(ert-deftest harness-ui-acp-remote-key-and-menu ()
  (harness-ui-acp-remote-test-with
    (should (eq 'harness-remote-control (lookup-key harness-ui-map (kbd "P"))))
    (should (eq 'harness-remote-approve (lookup-key harness-ui-map (kbd "y"))))
    (should (get 'harness-ui-acp-remote-mode 'harness-menu-group))
    ;; q buries the page rather than quitting its window.
    (harness-ui-acp-remote-test-open)
    (should (eq #'harness-ui-quit-view (key-binding (kbd "q"))))
    (should (eq #'harness-ui-acp-remote-revoke (key-binding (kbd "k"))))
    (should (eq #'harness-ui-acp-remote-revoke-all (key-binding (kbd "K"))))
    (should (eq #'harness-ui-acp-remote-approve (key-binding (kbd "y"))))
    (should (eq #'harness-ui-acp-remote-deny (key-binding (kbd "n"))))
    (should (eq #'harness-ui-acp-remote-create-token (key-binding (kbd "t"))))
    (should (eq #'harness-ui-acp-remote-copy-login-link (key-binding (kbd "l"))))
    ;; The names the page had before it was about sessions still work.
    (should (fboundp 'harness-ui-remote-unpair))
    (should (equal "Android · Chrome"
                   (harness-acp-remote--device-name harness-ui-acp-remote-test-agent)))))

(provide 'harness-ui-acp-remote-test)
;;; harness-ui-acp-remote-test.el ends here
