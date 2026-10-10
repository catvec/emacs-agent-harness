;;; harness-http-test.el --- Tests for the curl HTTP client  -*- lexical-binding: t -*-

;; This file is part of the Emacs agent harness (v3).

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)

(ert-deftest harness-http-body-uses-a-file-and-is-cleaned-up ()
  "A request body travels in a mode 600 file, not through stdin.
`process-send-string' can leave a big body half-written in Emacs's
process write queue, where only another send would ever drain it, and
curl then waits for the rest of its stdin forever."
  (skip-unless (executable-find "curl"))
  (harness-test-with-temp-state
    (let* ((body "{\"hello\":\"world\"}")
           (handle (harness-http-request "http://127.0.0.1:1/" :method "POST" :body body
                                         :callback (lambda (&rest _) nil))))
      (unwind-protect
          (let ((file (harness-http-handle-body-file handle))
                (args (process-command (harness-http-handle-process handle))))
            (should (stringp file))
            (should (file-exists-p file))
            (should (equal body (with-temp-buffer (insert-file-contents file) (buffer-string))))
            (should (member (concat "@" file) args))
            (should-not (member "@-" args))
            (should (timerp (harness-http-handle-timer handle)))
            (harness-http-cancel handle)
            (should-not (file-exists-p file)))
        (harness-http-cancel handle)))))

(ert-deftest harness-http-watchdog-fails-a-live-request ()
  "The watchdog ends a request whose curl is alive and silent.
Curl's own `--max-time' never fires while it waits for its stdin, so a
Lisp-side timer is what keeps requests bounded."
  (harness-test-with-temp-state
    (let* ((proc (make-process :name "harness-http-test-stuck"
                               :command (list "sleep" "60")
                               :connection-type 'pipe :noquery t))
           (handle (make-harness-http-handle :process proc :timeout 1))
           (result nil))
      (unwind-protect
          (progn
            (should (process-live-p proc))
            (setf (harness-http-handle-callback handle)
                  (lambda (status _headers _body err) (setq result (list status err))))
            (harness-http--timed-out handle)
            (should (equal '(nil timeout) (list (car result) (car (cadr result)))))
            (should (string-search "timed out after 1s" (cadr (cadr result))))
            (should-not (process-live-p proc)))
        (when (process-live-p proc) (delete-process proc))))))

(provide 'harness-http-test)
;;; harness-http-test.el ends here
;;; harness-http-test.el --- Tests for downloads with harness-http  -*- lexical-binding: t; -*-

;;; Commentary:

;; `harness-http-download' against a web server in this Emacs
;; (`harness-test-http-serve'): the body lands in the file, the headers
;; arrive before it, progress is reported while it comes, and errors,
;; the size cap and cancelling leave no file behind.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-http)

(defun harness-http-test--download (url file &rest args)
  "Download URL into FILE with ARGS; wait for it, return (DL ERROR HEADERS PROGRESS).
HEADERS is how many times ON-HEADERS ran, PROGRESS the progress reports,
oldest first."
  (let ((done nil) (headers 0) (progress nil))
    (apply #'harness-http-download url file
           :on-headers (lambda (_dl) (cl-incf headers))
           :on-progress (lambda (_dl received total) (push (cons received total) progress))
           :callback (lambda (dl err) (setq done (list dl err)))
           args)
    (harness-test-wait (lambda () done) 10 "the download")
    (list (car done) (cadr done) headers (nreverse progress))))

(ert-deftest harness-http-download-saves-the-body-and-reports-progress ()
  (skip-unless (executable-find "curl"))
  (let* ((body (concat harness-test-png (make-string 60000 ?x)))
         (server (harness-test-http-serve
                  `(("/pic.png" 200 (("Content-Type" . "image/png")) ,body :chunks 6 :delay 0.1))))
         (dir (harness-test-temp-dir))
         (file (expand-file-name "pic.part" dir))
         (harness-http-download-progress-interval 0.05))
    (unwind-protect
        (pcase-let ((`(,dl ,err ,headers ,progress)
                     (harness-http-test--download (harness-test-http-url server "/pic.png") file)))
          (should-not err)
          (should (= 1 headers))
          (should (equal body (with-temp-buffer (set-buffer-multibyte nil)
                                                (insert-file-contents-literally file) (buffer-string))))
          (should (= 200 (harness-download-status dl)))
          (should (equal "image/png" (harness-download-mime dl)))
          (should (= (length body) (harness-download-total dl)))
          (should (equal (harness-test-http-url server "/pic.png") (harness-download-url-effective dl)))
          ;; The body came in pieces, and progress saw it grow.
          (should (>= (length progress) 2))
          (should (cl-every (lambda (p) (equal (cdr p) (length body))) progress))
          (should (< (car (car progress)) (length body))))
      (delete-process server))))

(ert-deftest harness-http-download-follows-redirects-and-takes-the-name ()
  (skip-unless (executable-find "curl"))
  (let* ((server (harness-test-http-serve
                  '(("/go" 302 (("Location" . "/files/7")) "")
                    ("/files/7" 200 (("Content-Type" . "application/pdf; qs=0.9")
                                     ("Content-Disposition" . "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf"))
                     "%PDF-1.4 hello"))))
         (file (expand-file-name "x.part" (harness-test-temp-dir))))
    (unwind-protect
        (pcase-let ((`(,dl ,err . ,_) (harness-http-test--download (harness-test-http-url server "/go") file)))
          (should-not err)
          (should (equal "application/pdf" (harness-download-mime dl)))
          (should (equal "résumé.pdf" (harness-download-name dl)))
          (should (string-suffix-p "/files/7" (harness-download-url-effective dl)))
          (should (equal "%PDF-1.4 hello" (with-temp-buffer (insert-file-contents-literally file) (buffer-string)))))
      (delete-process server))))

(ert-deftest harness-http-download-errors-leave-no-file ()
  (skip-unless (executable-find "curl"))
  (let* ((server (harness-test-http-serve
                  `(("/big" 200 (("Content-Type" . "video/mp4")) ,(make-string 50000 ?v)))))
         (dir (harness-test-temp-dir))
         (file (expand-file-name "x.part" dir)))
    (unwind-protect
        (progn
          (pcase-let ((`(,_dl ,err . ,_) (harness-http-test--download (harness-test-http-url server "/nothing") file)))
            (should (equal "the server answered HTTP 404" err))
            (should-not (file-exists-p file)))
          (pcase-let ((`(,_dl ,err . ,_) (harness-http-test--download (harness-test-http-url server "/big") file
                                                                      :max-size 1000)))
            (should (string-match-p "larger than 1000" err))
            (should-not (file-exists-p file)))
          ;; Only links with a host to fetch: a file: URL has none, and
          ;; is refused before curl is even run.
          (should-error (harness-http-download "file:///etc/hostname" file) :type 'error)
          (should-not (file-exists-p file)))
      (delete-process server))
    ;; Nobody listening.
    (let ((port (let ((p (make-network-process :name "harness-test-port" :server t :host "127.0.0.1"
                                               :service t :family 'ipv4 :noquery t)))
                  (prog1 (process-contact p :service) (delete-process p)))))
      (pcase-let ((`(,_dl ,err . ,_) (harness-http-test--download (format "http://127.0.0.1:%d/x" port) file)))
        (should (stringp err))
        (should-not (file-exists-p file))))))

(ert-deftest harness-http-download-stops-when-asked ()
  (skip-unless (executable-find "curl"))
  (let* ((server (harness-test-http-serve
                  `(("/slow" 200 (("Content-Type" . "video/webm")) ,(make-string 40000 ?s) :chunks 40 :delay 0.2)
                    ("/page" 200 (("Content-Type" . "text/html; charset=utf-8")) "<html>hi</html>"))))
         (file (expand-file-name "x.part" (harness-test-temp-dir)))
         (calls 0) (error nil) (dl nil))
    (unwind-protect
        (progn
          ;; Cancelled midway: the callback runs once, the file goes, curl stops.
          (setq dl (harness-http-download (harness-test-http-url server "/slow") file
                                          :callback (lambda (_dl err) (cl-incf calls) (setq error err))))
          (harness-test-wait (lambda () (> (harness-http-download-received dl) 0)) 10 "the first bytes")
          (harness-http-download-cancel dl)
          (should (equal "cancelled" error))
          (should (= 1 calls))
          (should-not (file-exists-p file))
          (harness-test-wait (lambda () (not (process-live-p (harness-download-process dl)))) 5 "curl gone")
          (accept-process-output nil 0.1)
          (should (= 1 calls))
          ;; ON-HEADERS may stop one it does not want, a web page say.
          (setq calls 0 error nil)
          (harness-http-download (harness-test-http-url server "/page") file
                                 :on-headers (lambda (dl)
                                               (when (equal "text/html" (harness-download-mime dl))
                                                 (harness-http-download-cancel dl)))
                                 :callback (lambda (_dl err) (cl-incf calls) (setq error err)))
          (harness-test-wait (lambda () error) 10 "the page")
          (should (equal "cancelled" error))
          (should (= 1 calls))
          (should-not (file-exists-p file)))
      (delete-process server))))

(ert-deftest harness-http-names-from-headers-and-links ()
  (should (equal "a \"b\".png" (harness-http--disposition-filename "attachment; filename=\"a \\\"b\\\".png\"")))
  (should (equal "naïve pic.png"
                 (harness-http--disposition-filename "inline; filename*=UTF-8''na%C3%AFve%20pic.png; filename=\"x.png\"")))
  (should (equal "café.txt" (harness-http--disposition-filename "attachment; filename*=iso-8859-1''caf%E9.txt")))
  (should (equal "plain.jpg" (harness-http--disposition-filename "attachment; filename=plain.jpg")))
  (should-not (harness-http--disposition-filename "inline"))
  (should (equal "c d.png" (harness-http-url-file-name "https://example.com/a/b/c%20d.png?x=1#f")))
  (should-not (harness-http-url-file-name "https://example.com/"))
  (should-not (harness-http-url-file-name "https://example.com"))
  (should (equal "\211PNG" (harness-http-unhex-bytes "%89PNG"))))

(ert-deftest harness-http-cleaned-links ()
  ;; A drop or a clipboard hands over what it likes: a NUL, a newline, a
  ;; BOM, a zero width space.  curl reads those differently from how they
  ;; print ("URL rejected: No host present" for a link that looks whole),
  ;; so they are scrubbed before it ever sees them.
  (let ((url "https://example.com/a/b.png"))
    (should (equal url (harness-http-clean-url (concat "\ufeff" url "\r\n\0"))))
    (should (equal url (harness-http-clean-url (concat "\357\273\277" url))))     ; BOM bytes
    (should (equal url (harness-http-clean-url (concat "\u200b" url "\u2060 "))))
    (should (equal url (harness-http-clean-url (concat "\n\t" url))))
    (should (equal "https://exa\u00e9mple.com/x" (harness-http-clean-url "https://exa\u00e9mple.com/x")))
    (should (equal "https://example.com/a%20b.png"
                   (harness-http-clean-url "https://example.com/a%20b.png"))))
  ;; The invisible spaces: no-break space, soft hyphen, zero width and
  ;; bidi marks, ideographic space, in characters and in UTF-8 bytes.
  (dolist (junk (list "\u00a0" "\u00ad" "\u200b" "\u200e" "\u2028" "\u202f" "\u2060" "\u3000" "\ufeff"))
    (should (equal "https://git.sr.ht/~x" (harness-http-clean-url (concat "https://git.sr.ht" junk "/~x")))))
  (should (equal "https://git.sr.ht/~x"
                 (harness-http-clean-url (concat "https://git.sr.ht" (unibyte-string 194 160) "/~x"))))
  (should (equal "https://git.sr.ht/~x"
                 (harness-http-clean-url (concat "https://git.sr.ht" (unibyte-string 226 128 139) "/~x"))))
  ;; A host with junk in it is no host: the box must not hand it to curl.
  (should-not (harness-http-link-p "https://git.sr.ht\u00a0/~x"))
  (should (harness-http-link-p (harness-http-clean-url "https://git.sr.ht\u00a0/~x")))
  (should (harness-http-link-p "https://git.sr.ht:8080/x"))
  (should (harness-http-link-p "https://user@example.com/x"))
  (should (harness-http-link-p "http://[::1]:8080/x"))
  (should-not (harness-http-link-p "https://exa mple.com/x"))
  (should (harness-http-link-p "http://127.0.0.1:8080/x.png"))
  (should (harness-http-link-p "http://127.0.0.1:8080/x.png"))
  (should (harness-http-link-p "ftp://example.com/x"))
  (should-not (harness-http-link-p "https://"))
  (should-not (harness-http-link-p "https:///x.png"))
  (should-not (harness-http-link-p "example.com/x.png"))
  (should-not (harness-http-link-p "file:///etc/hostname")))

(ert-deftest harness-http-download-takes-a-link-with-junk-around-it ()
  ;; The whole class of "URL rejected: No host present": the URL the drop
  ;; gave is scrubbed -- junk bytes and, just as importantly, the text
  ;; properties a foreign selection carries -- so the file arrives all
  ;; the same.
  (skip-unless (executable-find "curl"))
  (let* ((server (harness-test-http-serve
                  '(("/pic.png" 200 (("Content-Type" . "image/png")) "PNG!"))))
         (file (expand-file-name "x.part" (harness-test-temp-dir))))
    (unwind-protect
        (dolist (dirty (list (concat "\ufeff\t" (harness-test-http-url server "/pic.png") "\r\n\0")
                             (propertize (harness-test-http-url server "/pic.png")
                                         'foreign-selection 'STRING)))
          (delete-file file)
          (pcase-let ((`(,dl ,err . ,_) (harness-http-test--download dirty file)))
            (should-not err)
            (should (equal "image/png" (harness-download-mime dl)))
            (should (equal (harness-test-http-url server "/pic.png") (harness-download-url dl)))
            (should-not (text-properties-at 0 (harness-download-url dl)))
            (should (equal "PNG!" (with-temp-buffer (insert-file-contents-literally file) (buffer-string))))))
      (delete-process server)))
  ;; A link with no host is refused before curl runs, with the link shown
  ;; as it really is.
  (should-error (harness-http-download "https://" (make-temp-name "/tmp/x")) :type 'error))

(ert-deftest harness-http-config-has-no-text-properties ()
  ;; `%S' prints a propertized string as #("https://..." ...), which curl
  ;; reads as a fragment: the config must never hold that.
  (let ((file (harness-http--write-config (propertize "https://example.com/x" 'foreign-selection 'STRING)
                                          "GET" '(("X-A" . "b")))))
    (unwind-protect
        (with-temp-buffer
          (insert-file-contents file)
          (should (string-match-p "url = \"https://example.com/x\"" (buffer-string)))
          (should-not (string-match-p "#(" (buffer-string)))
          (should (string-match-p "header = \"X-A: b\"" (buffer-string))))
      (delete-file file))))

(ert-deftest harness-http-cancel-settles-before-the-kill ()
  ;; Cancelling settles the download first, so nothing the kill or a
  ;; sentinel does can leave it half-settled (a chip stuck "downloading").
  (skip-unless (executable-find "curl"))
  (let* ((server (harness-test-http-serve
                  `(("/slow" 200 (("Content-Type" . "video/webm")) ,(make-string 40000 ?s)
                     :chunks 40 :delay 0.2))))
         (file (expand-file-name "x.part" (harness-test-temp-dir)))
         (calls 0) (error nil) (dl nil) (settled-at nil))
    (unwind-protect
        (progn
          (setq dl (harness-http-download (harness-test-http-url server "/slow") file
                                          :callback (lambda (_dl err)
                                                      (cl-incf calls)
                                                      (setq error err settled-at (harness-download-done dl)))))
          (harness-test-wait (lambda () (> (harness-http-download-received dl) 0)) 10 "the first bytes")
          (harness-http-download-cancel dl)
          ;; Settled before the process was killed, and exactly once.
          (should (eq t settled-at))
          (should (equal "cancelled" error))
          (should (= 1 calls))
          (should (harness-download-done dl))
          (should-not (file-exists-p file))
          (harness-test-wait (lambda () (not (process-live-p (harness-download-process dl)))) 5 "curl gone")
          (accept-process-output nil 0.2)
          (should (= 1 calls))
          ;; Cancelling again, or after it settled, does nothing.
          (harness-http-download-cancel dl)
          (should (= 1 calls)))
      (delete-process server))))


;;;; Retrying transient failures

(defun harness-http-test--request (url &rest args)
  "Request URL with ARGS; wait for the callback, return (STATUS HEADERS BODY ERROR)."
  (let ((done nil))
    (apply #'harness-http-request url
           :callback (lambda (status headers body err) (setq done (list status headers body err)))
           args)
    (harness-test-wait (lambda () done) 20 "the request")
    done))

(ert-deftest harness-http-retries-a-transient-failure ()
  "A reset connection is tried again, and the request then answers.
A POST opts in (`:retry t'): a provider's completion is worth repeating,
while an ordinary POST is not retried by default (below)."
  (skip-unless (executable-find "curl"))
  (let* ((attempts (cons 0 0))
         (server (harness-test-http-serve
                  `(("/x" . ,(lambda (n)
                               (setcar attempts n)
                               (if (= n 1)
                                   'reset
                                 (list 200 '(("Content-Type" . "text/plain")) "hello")))))))
         (harness-http-retry-delay 0.01) (harness-http-retry-jitter 0))
    (unwind-protect
        (pcase-let ((`(,status ,_headers ,body ,err)
                     (harness-http-test--request (harness-test-http-url server "/x")
                                                 :method "POST" :body "q" :retry t)))
          (should-not err)
          (should (equal 200 status))
          (should (equal "hello" body))
          (should (equal 2 (car attempts))))
      (delete-process server))))

(ert-deftest harness-http-gives-up-after-the-bounded-retries ()
  "A persistent reset fails once the attempts are used up, with a plain message."
  (skip-unless (executable-find "curl"))
  (let* ((attempts (cons 0 0))
         (server (harness-test-http-serve
                  `(("/x" . ,(lambda (n) (setcar attempts n) 'reset)))))
         (harness-http-retry-delay 0.01) (harness-http-retry-jitter 0))
    (unwind-protect
        (pcase-let ((`(,_status ,_headers ,_body ,err)
                     (harness-http-test--request (harness-test-http-url server "/x") :retry 2)))
          (should (equal 3 (car attempts)))     ; the first attempt and two retries
          (should (harness-http-transient-error-p err))
          (should (eq 'transport (plist-get err :kind)))
          (let ((code (plist-get err :code)))
            (should (memq code harness-http--transient-curl-exits))
            ;; The message says what happened, not just the exit status.
            (should (equal (cdr (assq code harness-http--curl-explanations))
                           (car (split-string (cadr err) " (curl"))))))
      (delete-process server))))

(ert-deftest harness-http-does-not-retry-what-it-already-streamed ()
  "A reset after some body reached the caller is not repeated: that would duplicate it."
  (skip-unless (executable-find "curl"))
  (let* ((attempts (cons 0 0))
         (server (harness-test-http-serve
                  `(("/x" . ,(lambda (n) (setcar attempts n)
                               (list 200 '(("Content-Type" . "text/plain")) "abcdefghij"
                                     :chunks 2 :reset-after 1))))))
         (chunks nil)
         (harness-http-retry-delay 0.01) (harness-http-retry-jitter 0))
    (unwind-protect
        (pcase-let ((`(,_status ,_headers ,_body ,err)
                     (harness-http-test--request (harness-test-http-url server "/x") :retry t
                                                 :on-chunk (lambda (chunk) (push chunk chunks)))))
          (should (harness-http-transient-error-p err))
          (should (equal 1 (car attempts)))     ; nothing was tried again
          (should (equal '("abcde") (nreverse chunks))))
      (delete-process server))))

(ert-deftest harness-http-no-retry-by-default-for-a-post ()
  "A POST is not retried unless it asks: the server may have acted on it."
  (skip-unless (executable-find "curl"))
  (let* ((attempts (cons 0 0))
         (server (harness-test-http-serve
                  `(("/x" . ,(lambda (n) (setcar attempts n) 'reset)))))
         (harness-http-retry-delay 0.01) (harness-http-retry-jitter 0))
    (unwind-protect
        (pcase-let ((`(,_status ,_headers ,_body ,err)
                     (harness-http-test--request (harness-test-http-url server "/x")
                                                 :method "POST" :body "q")))
          (should err)
          (should (equal 1 (car attempts))))
      (delete-process server))))

(ert-deftest harness-http-retries-a-retryable-status ()
  "429 and 5xx are tried again, with no on-chunk to duplicate, and Retry-After is read."
  (skip-unless (executable-find "curl"))
  (let* ((attempts (cons 0 0))
         (server (harness-test-http-serve
                  `(("/busy" . ,(lambda (n) (setcar attempts n)
                                  (if (= n 1)
                                      (list 429 '(("Retry-After" . "0")) "slow down")
                                    (list 200 '(("Content-Type" . "text/plain")) "at last"))))
                    ("/gone" 404 (("Content-Type" . "text/plain")) "no"))))
         (harness-http-retry-delay 0.01) (harness-http-retry-jitter 0))
    (unwind-protect
        (progn
          (pcase-let ((`(,status ,_headers ,body ,err)
                       (harness-http-test--request (harness-test-http-url server "/busy"))))
            (should-not err)
            (should (equal 200 status))
            (should (equal "at last" body))
            (should (equal 2 (car attempts))))
          ;; A 404 is an answer, not a failure to get past.
          (pcase-let ((`(,status ,_headers ,body ,err)
                       (harness-http-test--request (harness-test-http-url server "/gone"))))
            (should-not err)
            (should (equal 404 status))
            (should (equal "no" body))))
      (delete-process server)))
  ;; The delay a server asked for is read, and only in its seconds form.
  (should (= 3 (harness-http-retry-after '(("retry-after" . " 3 ")))))
  (should-not (harness-http-retry-after '(("retry-after" . "Wed, 21 Oct 2015 07:28:00 GMT"))))
  (should-not (harness-http-retry-after nil))
  (should (harness-http--retryable-status-p 429))
  (should (harness-http--retryable-status-p 503))
  (should-not (harness-http--retryable-status-p 404))
  (should-not (harness-http--retryable-status-p nil)))

(ert-deftest harness-http-cancelling-while-it-waits-to-retry-stops-it ()
  "A cancelled request is never tried again, not even from the retry it waited for."
  (skip-unless (executable-find "curl"))
  (let* ((attempts (cons 0 0))
         (server (harness-test-http-serve
                  `(("/x" . ,(lambda (n) (setcar attempts n) 'reset)))))
         (harness-http-retry-delay 0.3) (harness-http-retry-jitter 0)
         (result nil))
    (unwind-protect
        (progn
          (let ((handle (harness-http-request (harness-test-http-url server "/x")
                                              :retry 3
                                              :callback (lambda (_s _h _b e) (setq result (list e))))))
            (harness-test-wait (lambda () (= 1 (car attempts))) 10 "the first attempt")
            ;; Let curl die and the retry be scheduled, then cancel it.
            (harness-test-wait (lambda () (harness-http-handle-retry-timer handle)) 5 "the retry")
            (harness-http-cancel handle)
            (should (eq 'cancelled (car (car result))))
            (accept-process-output nil 0.6)     ; well past the retry delay
            (should (equal 1 (car attempts)))))
      (delete-process server))))

(ert-deftest harness-http-download-restarts-after-a-cut-transfer ()
  "A download cut by a reset is started over, and the file is whole."
  (skip-unless (executable-find "curl"))
  (let* ((attempts (cons 0 0))
         (server (harness-test-http-serve
                  `(("/pic" . ,(lambda (n) (setcar attempts n)
                                 (if (= n 1)
                                     'reset
                                   (list 200 '(("Content-Type" . "image/png")) "PNGBYTES")))))))
         (file (expand-file-name "x.part" (harness-test-temp-dir)))
         (harness-http-retry-delay 0.01) (harness-http-retry-jitter 0))
    (unwind-protect
        (pcase-let ((`(,_dl ,err ,headers . ,_)
                     (harness-http-test--download (harness-test-http-url server "/pic") file)))
          (should-not err)
          (should (equal 2 (car attempts)))
          (should (= 1 headers))               ; told once, not once per attempt
          (should (equal "PNGBYTES"
                         (with-temp-buffer (insert-file-contents-literally file) (buffer-string)))))
      (delete-process server))
    ;; Cut in the middle of the body: the partial file is dropped and the
    ;; download starts over rather than keeping half a file.
    (let* ((attempts (cons 0 0))
           (server (harness-test-http-serve
                    `(("/pic" . ,(lambda (n) (setcar attempts n)
                                   (list 200 '(("Content-Type" . "image/png"))
                                         (if (= n 1) "abcdefghij" "0123456789")
                                         :chunks 2 :reset-after (and (= n 1) 1))))))))
      (unwind-protect
          (pcase-let ((`(,_dl ,err . ,_) (harness-http-test--download (harness-test-http-url server "/pic") file)))
            (should-not err)
            (should (equal 2 (car attempts)))
            (should (equal "0123456789"
                           (with-temp-buffer (insert-file-contents-literally file) (buffer-string)))))
        (delete-process server)))
    ;; With no retries asked for, a cut download fails and leaves no file.
    (let* ((attempts (cons 0 0))
           (server (harness-test-http-serve `(("/pic" . ,(lambda (n) (setcar attempts n) 'reset)))))
           (harness-http-retry-delay 0.01) (harness-http-retry-jitter 0))
      (unwind-protect
          (pcase-let ((`(,_dl ,err . ,_) (harness-http-test--download (harness-test-http-url server "/pic") file
                                                                      :retry 0)))
            (should (stringp err))
            (should (equal 1 (car attempts)))
            (should-not (file-exists-p file)))
        (delete-process server)))))

(provide 'harness-http-test)
;;; harness-http-test.el ends here
