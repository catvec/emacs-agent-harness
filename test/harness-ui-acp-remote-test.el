;;; harness-ui-acp-remote-test.el --- Tests for the remote control page  -*- lexical-binding: t; -*-

;;; Commentary:

;; The page against the real acp-remote module, through the UI's own
;; ACP connection: the QR code folded until asked for, a fresh code
;; each time it unfolds, folded again once the link pairs a device or
;; the code expires, hiding drops the code, unpairing, corporate mode.

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
       (dolist (m '(acp acp-remote ui ui-qr ui-acp-remote)) (harness-test-load-module m)))
     (let ((harness-acp-token nil)
           (harness-acp-remote nil)
           (harness-acp-remote-host "127.0.0.1")
           (harness-acp-remote-port 0)
           (harness-acp-remote-address nil)
           (harness-acp-remote-code-lifetime 600)
           (harness-acp-remote--allow-loopback t)
           (harness-corporate-mode nil)
           (harness-qr-force-text t))
       (setq harness-acp-remote--devices nil harness-acp-remote--code nil)
       (unwind-protect (progn ,@body)
         (when (get-buffer harness-ui-acp-remote-buffer-name) (kill-buffer harness-ui-acp-remote-buffer-name))
         (harness-acp-remote--stop)
         (dolist (c (copy-sequence harness-acp--clients)) (harness-acp--drop-client c))))))

(defun harness-ui-acp-remote-test-open ()
  "Open the page and wait for its status; return the buffer."
  (harness-remote-control)
  (let ((buf (get-buffer harness-ui-acp-remote-buffer-name)))
    (harness-test-wait (lambda () (buffer-local-value 'harness-ui-acp-remote--status buf)) 5 "the status")
    (set-buffer buf)
    buf))

(defun harness-ui-acp-remote-test-text ()
  "Return the page's text."
  (with-current-buffer harness-ui-acp-remote-buffer-name (buffer-substring-no-properties (point-min) (point-max))))

(defun harness-ui-acp-remote-test-get (url)
  "GET URL, a link of the test listener; return the status code."
  (string-match "\\`http://127\\.0\\.0\\.1:\\([0-9]+\\)\\(/.*\\)\\'" url)
  (let* ((port (string-to-number (match-string 1 url)))
         (path (match-string 2 url))
         (out "") (done nil)
         (proc (make-network-process :name "ui-remote-test-http" :host "127.0.0.1" :service port
                                     :coding 'binary :noquery t
                                     :filter (lambda (_p c) (setq out (concat out c)))
                                     :sentinel (lambda (p _e) (unless (process-live-p p) (setq done t))))))
    (process-send-string proc (format "GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: Mozilla/5.0 (Linux; Android 14) Chrome/129.0 Mobile Safari/537.36\r\n\r\n" path))
    (harness-test-wait (lambda () (or done (string-match-p "</html>" out))) 5 "the response")
    (delete-process proc)
    (string-match "\\`HTTP/1.1 \\([0-9]+\\)" out)
    (string-to-number (match-string 1 out))))

(defun harness-ui-acp-remote-test-goto-qr ()
  "Move point to the QR code's heading."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (get-text-property (point) 'harness-ui-acp-remote-qr)))
    (forward-char 1)))

(ert-deftest harness-ui-acp-remote-start-serving ()
  (harness-ui-acp-remote-test-with
    (harness-ui-acp-remote-test-open)
    (let ((text (harness-ui-acp-remote-test-text)))
      (should (string-search "not served" text))
      (should (string-search "[start serving]" text))
      (should (string-search "start serving to pair a device" text))
      (should (string-search "no device paired yet" text)))
    (should-error (harness-ui-acp-remote-toggle-qr) :type 'user-error)
    (harness-ui-acp-remote-toggle-serving)
    (harness-test-wait (lambda () (harness-ui-acp-remote--true :running)) 5 "serving")
    (should (string-search (format "served on port %s" (harness-acp-remote--port)) (harness-ui-acp-remote-test-text)))
    (should (string-search "pairs whichever device scans it" (harness-ui-acp-remote-test-text)))
    (should (eq t harness-acp-remote))))

(ert-deftest harness-ui-acp-remote-qr-folded-until-asked ()
  "The QR code starts folded, unfolds with a fresh code, and folds once it pairs a device."
  (harness-ui-acp-remote-test-with
    (harness-acp-remote--listen)
    (harness-ui-acp-remote-test-open)
    (should-not harness-ui-acp-remote--expanded)
    (should-not (string-search "Scan it" (harness-ui-acp-remote-test-text)))
    (should-not (string-search "█" (harness-ui-acp-remote-test-text)))
    (should-not harness-acp-remote--code)
    ;; TAB on the heading unfolds it.
    (harness-ui-acp-remote-test-goto-qr)
    (harness-ui-acp-remote-tab)
    (harness-test-wait (lambda () harness-ui-acp-remote--expanded) 5 "the QR code")
    (let ((url (plist-get harness-ui-acp-remote--pairing :url))
          (text (harness-ui-acp-remote-test-text)))
      (should (string-search "Scan it with the device's camera" text))
      (should (string-search url text))
      (should (string-match-p "[█▀▄]" text))
      ;; Each unfolding makes a fresh code.
      (should (equal (plist-get harness-acp-remote--code :code)
                     (substring url (- (length url) 20))))
      ;; Opening the link pairs the device, and the page folds the code.
      (should (= 200 (harness-ui-acp-remote-test-get url)))
      (harness-test-wait (lambda () (and (not harness-ui-acp-remote--expanded)
                                         (plist-get harness-ui-acp-remote--status :devices)))
                         5 "the page to follow the pairing")
      (let ((text (harness-ui-acp-remote-test-text)))
        (should-not (string-search "Scan it" text))
        (should (string-search "Android · Chrome" text))
        (should (string-search "[unpair]" text))))
    ;; Unpairing the device at point.
    (goto-char (point-min))
    (search-forward "Android · Chrome")
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (harness-ui-acp-remote-unpair))
    (harness-test-wait (lambda () (string-search "no device paired yet" (harness-ui-acp-remote-test-text))) 5 "unpaired")))

(ert-deftest harness-ui-acp-remote-hiding-drops-the-code ()
  (harness-ui-acp-remote-test-with
    (harness-acp-remote--listen)
    (harness-ui-acp-remote-test-open)
    (harness-ui-acp-remote-toggle-qr)
    (harness-test-wait (lambda () harness-ui-acp-remote--expanded) 5 "the QR code")
    (let ((url (plist-get harness-ui-acp-remote--pairing :url)))
      (harness-ui-acp-remote-toggle-qr)
      (should-not harness-ui-acp-remote--expanded)
      (harness-test-wait (lambda () (null harness-acp-remote--code)) 5 "the code to go")
      (should (= 403 (harness-ui-acp-remote-test-get url))))
    ;; A new code replaces the one shown.
    (harness-ui-acp-remote-toggle-qr)
    (harness-test-wait (lambda () harness-ui-acp-remote--expanded) 5 "the QR code")
    (let ((first (plist-get harness-ui-acp-remote--pairing :url)))
      (harness-ui-acp-remote-new-code)
      (harness-test-wait (lambda () (not (equal first (plist-get harness-ui-acp-remote--pairing :url)))) 5 "a new code")
      (should (= 403 (harness-ui-acp-remote-test-get first))))))

(ert-deftest harness-ui-acp-remote-code-expiry-folds ()
  (harness-ui-acp-remote-test-with
    (let ((harness-acp-remote-code-lifetime 1))
      (harness-acp-remote--listen)
      (harness-ui-acp-remote-test-open)
      (harness-ui-acp-remote-toggle-qr)
      (harness-test-wait (lambda () harness-ui-acp-remote--expanded) 5 "the QR code")
      (harness-test-wait (lambda () (not harness-ui-acp-remote--expanded)) 5 "the code to expire")
      (should-not (string-search "Scan it" (harness-ui-acp-remote-test-text))))))

(ert-deftest harness-ui-acp-remote-corporate-mode ()
  (harness-ui-acp-remote-test-with
    (let ((harness-corporate-mode t))
      (harness-ui-acp-remote-test-open)
      (should (string-search "Corporate mode is on" (harness-ui-acp-remote-test-text)))
      (should-not (string-search "Pairing QR code" (harness-ui-acp-remote-test-text)))
      (should-error (harness-ui-acp-remote-toggle-serving) :type 'user-error)
      (should-error (harness-ui-acp-remote-toggle-qr) :type 'user-error))))

(ert-deftest harness-ui-acp-remote-key-and-menu ()
  (harness-ui-acp-remote-test-with
    (should (eq 'harness-remote-control (lookup-key harness-ui-map (kbd "P"))))
    (should (get 'harness-ui-acp-remote-mode 'harness-menu-group))
    ;; q buries the page rather than quitting its window.
    (harness-ui-acp-remote-test-open)
    (should (eq #'harness-ui-quit-view (key-binding (kbd "q"))))
    (should (equal "Android · Chrome"
                   (harness-ui-acp-remote--device-label
                    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/129.0 Mobile Safari/537.36")))
    (should (equal "iPhone · Safari"
                   (harness-ui-acp-remote--device-label
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1")))))

(provide 'harness-ui-acp-remote-test)
;;; harness-ui-acp-remote-test.el ends here
