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
  (should (harness-http-link-p "http://127.0.0.1:8080/x.png"))
  (should (harness-http-link-p "ftp://example.com/x"))
  (should-not (harness-http-link-p "https://"))
  (should-not (harness-http-link-p "https:///x.png"))
  (should-not (harness-http-link-p "example.com/x.png"))
  (should-not (harness-http-link-p "file:///etc/hostname")))

(ert-deftest harness-http-download-takes-a-link-with-junk-around-it ()
  ;; The whole class of "URL rejected: No host present": the URL the drop
  ;; gave is scrubbed, so the file arrives all the same.
  (skip-unless (executable-find "curl"))
  (let* ((server (harness-test-http-serve
                  '(("/pic.png" 200 (("Content-Type" . "image/png")) "PNG!"))))
         (file (expand-file-name "x.part" (harness-test-temp-dir))))
    (unwind-protect
        (pcase-let ((`(,dl ,err . ,_)
                     (harness-http-test--download
                      (concat "\ufeff\t" (harness-test-http-url server "/pic.png") "\r\n\0") file)))
          (should-not err)
          (should (equal "image/png" (harness-download-mime dl)))
          (should (equal (harness-test-http-url server "/pic.png") (harness-download-url dl)))
          (should (equal "PNG!" (with-temp-buffer (insert-file-contents-literally file) (buffer-string)))))
      (delete-process server)))
  ;; A link with no host is refused before curl runs, with the link shown
  ;; as it really is.
  (should-error (harness-http-download "https://" (make-temp-name "/tmp/x")) :type 'error))

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

(provide 'harness-http-test)
;;; harness-http-test.el ends here
