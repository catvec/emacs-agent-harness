;;; harness-notifications-test.el --- Tests for the notifications API  -*- lexical-binding: t; -*-

;;; Commentary:

;; The desktop backends (harness-notifications-desktop.el) run against
;; fake notify-send scripts and stubbed D-Bus calls, the notifications
;; module against fake providers, Gotify against a local HTTP server
;; reached through curl, and the system provider against an in-process
;; client standing in for the UI.  Nothing here shows a real
;; notification or reaches the network.

;;; Code:

(require 'harness-test-helpers)
(require 'harness-notifications-desktop)

(defvar harness-notifications-providers)
(defvar harness-notifications--providers)
(defvar harness-notifications--timeout)
(defvar harness-notifications--max-body)
(defvar harness-notifications--auth-source-seen)
(defvar harness-gotify-url)
(defvar harness-gotify-token)
(defvar harness-notifications--gotify-priorities)
(defvar harness-acp--server-enabled)
(defvar harness-acp--clients)
(defvar harness-acp-token)
(declare-function harness-notifications-define-provider "harness-notifications")
(declare-function harness-acp-connect "harness-acp")
(declare-function harness-acp-set-handler "harness-acp")
(declare-function harness-acp-respond-error "harness-acp")
(declare-function harness-acp--drop-client "harness-acp")
(declare-function dbus-event-serial-number "dbus")

;;;; Fake programs

(defun harness-notifications-test--script (dir body)
  "Write an executable shell script running BODY in DIR; return its path.
The script finds DIR in $D; it writes its arguments to $D/args."
  (let ((path (expand-file-name "notify-send" dir)))
    (with-temp-file path
      (insert "#!/bin/sh\nD=" (shell-quote-argument (directory-file-name dir)) "\n" body "\n"))
    (set-file-modes path #o755)
    path))

(defmacro harness-notifications-test-with-notify-send (script &rest body)
  "Run BODY with notify-send a fake running SCRIPT, as the only backend.
`dir' is the script's directory, and `args' reads the arguments it got."
  (declare (indent 1))
  `(let* ((dir (harness-test-temp-dir))
          (harness-notifications-desktop--notify-send
           (harness-notifications-test--script dir ,script))
          (harness-notifications-desktop-backend 'notify-send)
          (harness-notifications-desktop--legacy nil)
          (harness-notifications-desktop--waiting nil))
     (cl-flet ((args () (split-string (or (harness-read-file (expand-file-name "args" dir)) "") "\n" t)))
       (unwind-protect (progn ,@body)
         (ignore-errors (delete-directory dir t))))))

(defconst harness-notifications-test--record-args "printf '%s\\n' \"$@\" > \"$D/args\""
  "Shell line a fake notify-send records its arguments with.")

;;;; Desktop: notify-send

(ert-deftest harness-notifications-desktop-notify-send-shows-and-hears-a-click ()
  (harness-notifications-test-with-notify-send
      (concat harness-notifications-test--record-args "\necho 42\nsleep 0.2\necho default")
    (let* ((clicks 0)
           (shown (harness-test-await
                   (harness-notifications-desktop-notify
                    :title "-Task done: <x>" :body "A & B <c>" :urgency "critical"
                    :on-action (lambda () (cl-incf clicks)))
                   5)))
      (should (equal '(:backend notify-send :id 42) shown))
      ;; It waits for the click meanwhile.
      (should (= 1 (length harness-notifications-desktop--waiting)))
      (harness-test-wait (lambda () (= clicks 1)) 5 "the click")
      (harness-test-wait (lambda () (null harness-notifications-desktop--waiting)) 5 "the process to end")
      (should (equal (list (concat "--app-name=" harness-notifications-desktop--app-name)
                           "--urgency=critical"
                           (concat "--icon=" (harness-notifications-desktop--icon))
                           "--print-id" "--action=default=Open" "--"
                           ;; The title is never markup and may start with a dash.
                           "-Task done: <x>"
                           "A &amp; B &lt;c&gt;")
                     (args))))))

(ert-deftest harness-notifications-desktop-notify-send-plain-when-not-clickable ()
  (harness-notifications-test-with-notify-send
      (concat harness-notifications-test--record-args "\necho 7")
    (should (equal '(:backend notify-send :id 7)
                   (harness-test-await (harness-notifications-desktop-notify :title "Hello" :urgency 'bogus) 5)))
    (should (member "--print-id" (args)))
    (should (member "--urgency=normal" (args)))
    (should-not (cl-find-if (lambda (a) (string-prefix-p "--action" a)) (args)))
    ;; No body, no body argument.
    (should (equal "Hello" (car (last (args)))))))

(ert-deftest harness-notifications-desktop-notify-send-old-version ()
  "An old notify-send that knows neither --print-id nor --action shows it plainly."
  (harness-notifications-test-with-notify-send
      (concat "case \"$*\" in *--print-id*) echo 'Unknown option --print-id' >&2; exit 1;; esac\n"
              harness-notifications-test--record-args)
    (should (equal '(:backend notify-send)
                   (harness-test-await (harness-notifications-desktop-notify
                                        :title "T" :body "B" :on-action #'ignore)
                                       5)))
    (should harness-notifications-desktop--legacy)
    (should-not (member "--print-id" (args)))
    (should-not (cl-find-if (lambda (a) (string-prefix-p "--action" a)) (args)))
    (should (equal '("--" "T" "B") (last (args) 3)))))

(ert-deftest harness-notifications-desktop-notify-send-failure ()
  (harness-notifications-test-with-notify-send
      "echo 0\necho 'Failed to show notification: no server' >&2\nexit 1"
    (let ((err (should-error (harness-test-await (harness-notifications-desktop-notify :title "T") 5))))
      (should (equal "notify-send failed: Failed to show notification: no server"
                     (error-message-string err))))))

(ert-deftest harness-notifications-desktop-waiting-is-capped ()
  (let ((harness-notifications-desktop--waiting nil)
        (harness-notifications-desktop-max-waiting 2)
        (procs (cl-loop repeat 3 collect (make-process :name "harness-test-sleep" :command '("sleep" "30")
                                                       :noquery t :connection-type 'pipe))))
    (unwind-protect
        (progn
          (mapc #'harness-notifications-desktop--wait-for-click procs)
          (should (equal (cdr procs) harness-notifications-desktop--waiting))
          (harness-test-wait (lambda () (not (process-live-p (car procs)))) 5 "the oldest to stop")
          (harness-notifications-desktop--forget-waiting (nth 1 procs))
          (should (equal (list (nth 2 procs)) harness-notifications-desktop--waiting)))
      (dolist (p procs) (when (process-live-p p) (delete-process p))))))

;;;; Desktop: choosing a backend

(ert-deftest harness-notifications-desktop-backend-choice ()
  (cl-letf (((symbol-function 'harness-notifications-desktop--dbus-session-p) #'ignore))
    (let ((harness-notifications-desktop--notify-send "harness-test-no-such-program"))
      (let ((harness-notifications-desktop-backend 'auto))
        (unless (eq system-type 'darwin)
          (should-not (harness-notifications-desktop-backend))
          (should-not (harness-notifications-desktop-available-p))
          (should (string-match-p "install notify-send"
                                  (error-message-string
                                   (should-error (harness-test-await (harness-notifications-desktop-notify :title "T") 2)))))))
      ;; A chosen backend that cannot work here is none.
      (let ((harness-notifications-desktop-backend 'notify-send))
        (should-not (harness-notifications-desktop-backend))
        (should (string-match-p "harness-test-no-such-program"
                                (error-message-string
                                 (should-error (harness-test-await (harness-notifications-desktop-notify :title "T") 2))))))
      (let ((harness-notifications-desktop-backend 'dbus))
        (should-not (harness-notifications-desktop-backend))))
    (let* ((dir (harness-test-temp-dir))
           (harness-notifications-desktop--notify-send (harness-notifications-test--script dir "exit 0"))
           (harness-notifications-desktop-backend 'auto))
      (unwind-protect (should (eq 'notify-send (harness-notifications-desktop-backend)))
        (delete-directory dir t)))
    ;; A function takes over.
    (let* ((seen nil)
           (harness-notifications-desktop-backend (lambda (params) (setq seen params) t)))
      (should (equal '(:backend function)
                     (harness-test-await (harness-notifications-desktop-notify :title "T" :urgency 'low) 2)))
      (should (equal "T" (plist-get seen :title))))
    ;; One that signals rejects.
    (let ((harness-notifications-desktop-backend (lambda (_) (error "No desktop here"))))
      (should (equal "No desktop here"
                     (error-message-string
                      (should-error (harness-test-await (harness-notifications-desktop-notify :title "T") 2))))))))

;;;; Desktop: D-Bus

(ert-deftest harness-notifications-desktop-dbus-arguments ()
  (let ((harness-notifications-desktop--app-name "App")
        (harness-notifications-desktop--icon-name "icon"))
    (should (equal '(:string "App" :uint32 0 :string "icon" :string "T" :string "x &amp; y"
                     (:array "default" "Open")
                     (:array (:dict-entry "urgency" (:variant :byte 2)))
                     :int32 -1)
                   (harness-notifications-desktop--dbus-args '(:title "T" :body "x & y" :urgency critical) t)))
    (should (equal '(:array :signature "s")
                   (nth 10 (harness-notifications-desktop--dbus-args '(:title "T") nil))))
    (should (equal '(:array (:dict-entry "urgency" (:variant :byte 0)))
                   (nth 11 (harness-notifications-desktop--dbus-args '(:title "T" :urgency "low") nil))))))

(ert-deftest harness-notifications-desktop-dbus-asynchronous ()
  "An interactive Emacs asks D-Bus asynchronously and hears clicks."
  (require 'dbus)
  (let ((calls nil)
        (serial 99)
        (clicks 0)
        (harness-notifications-desktop-backend 'dbus)
        (harness-notifications-desktop--dbus-listening nil)
        (harness-notifications-desktop--dbus-actions (make-hash-table :test 'eql))
        (harness-notifications-desktop--dbus-calls (make-hash-table :test 'eql))
        (dbus-event-error-functions nil))
    (cl-letf (((symbol-function 'harness-notifications-desktop--dbus-session-p) (lambda () t))
              ((symbol-function 'dbus-register-signal) (lambda (&rest _) 'registered))
              ((symbol-function 'dbus-call-method-asynchronously)
               (lambda (bus _service _path _interface method handler &rest args)
                 (push (list :method method :handler handler :args args) calls)
                 (list :serial bus (cl-incf serial))))
              ((symbol-function 'dbus-event-serial-number) (lambda (event) (car event))))
      (let ((shown (let ((noninteractive nil))
                     (harness-notifications-desktop-notify :title "T" :on-action (lambda () (cl-incf clicks)))))
            (failed (let ((noninteractive nil))
                      (harness-notifications-desktop-notify :title "U"))))
        (should (equal "Notify" (plist-get (car calls) :method)))
        (should (equal :timeout (car (plist-get (car calls) :args))))
        (should (gethash 100 harness-notifications-desktop--dbus-calls))
        (should (gethash 101 harness-notifications-desktop--dbus-calls))
        (should (memq #'harness-notifications-desktop--dbus-on-error dbus-event-error-functions))
        ;; The first call is answered: shown, and its click is heard once.
        (funcall (plist-get (cadr calls) :handler) 1234)
        (should (equal '(:backend dbus :id 1234) (harness-test-await shown 2)))
        (should-not (gethash 100 harness-notifications-desktop--dbus-calls))
        (harness-notifications-desktop--dbus-on-action 1234 "other")
        (should (= 0 clicks))
        (harness-notifications-desktop--dbus-on-action 1234 "default")
        (harness-notifications-desktop--dbus-on-action 1234 "default")
        (should (= 1 clicks))
        ;; The second gets an error answer.
        (harness-notifications-desktop--dbus-on-error '(101) '(dbus-error "No notification service"))
        (should-error (harness-test-await failed 2))
        (should-not (gethash 101 harness-notifications-desktop--dbus-calls))))))

(ert-deftest harness-notifications-desktop-dbus-batch ()
  "A batch Emacs, which reads no D-Bus events, asks synchronously and briefly."
  (require 'dbus)
  (let ((call nil)
        (harness-notifications-desktop-backend 'dbus))
    (cl-letf (((symbol-function 'harness-notifications-desktop--dbus-session-p) (lambda () t))
              ((symbol-function 'dbus-call-method)
               (lambda (&rest args) (setq call args) 77)))
      (let ((noninteractive t))
        (should (equal '(:backend dbus :id 77)
                       (harness-test-await (harness-notifications-desktop-notify :title "T" :on-action #'ignore) 2))))
      (should (equal '(:timeout 2000) (seq-take (nthcdr 5 call) 2)))
      ;; Nothing would hear a click.
      (should (equal '(:array :signature "s") (nth 17 call))))))

;;;; The module

(defmacro harness-notifications-test-with (&rest body)
  "Run BODY on a fresh bus with the notifications module and no provider enabled.
Providers BODY defines go when it ends."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (harness-test-load-module 'notifications)
     (let ((harness-notifications--providers
            (mapcar (lambda (cell) (cons (car cell) (cdr cell))) harness-notifications--providers))
           (harness-notifications-providers nil)
           (harness-notifications--auth-source-seen nil))
       ,@body)))

(defun harness-notifications-test--send (notification &optional providers)
  "Send NOTIFICATION (to PROVIDERS) and wait for the result."
  (harness-test-await (harness-call 'notification/send notification providers) 10))

(defun harness-notifications-test--capture (name)
  "Define provider NAME keeping what it gets; return a function listing it."
  (let ((got nil))
    (harness-notifications-define-provider name :label (upcase (symbol-name name))
                                           :send (lambda (n) (push n got) (list :detail "kept")))
    (lambda () (reverse got))))

(ert-deftest harness-notifications-send-to-every-provider ()
  (harness-notifications-test-with
    (let ((one (harness-notifications-test--capture 'one))
          (two (harness-notifications-test--capture 'two))
          (sent nil))
      (harness-notifications-define-provider 'broken :send (lambda (_) (error "Out of order")))
      (harness-notifications-define-provider 'unset :send #'ignore :ready #'ignore)
      (harness-notifications-define-provider 'async :send (lambda (_) (harness-resolved nil)))
      (harness-on 'notification/sent (lambda (n results) (push (cons n results) sent)))
      (let* ((harness-notifications-providers '(one broken two unset missing async))
             (result (harness-notifications-test--send
                      '(:title "  Ready for review: x " :body "body" :urgency "critical"
                        :session "s1" :task "t1" :project "/p/" :kind "task-review"))))
        (should (string-prefix-p "n-" (plist-get result :id)))
        (should (equal '((:provider one :status sent :detail "kept")
                         (:provider broken :status failed :error "Out of order")
                         (:provider two :status sent :detail "kept")
                         (:provider unset :status skipped :error "not set up")
                         (:provider missing :status skipped :error "no such provider")
                         (:provider async :status sent))
                       (plist-get result :results)))
        (let ((n (car (funcall one))))
          (should (equal "Ready for review: x" (plist-get n :title)))
          (should (eq 'critical (plist-get n :urgency)))
          (should (equal (plist-get result :id) (plist-get n :id)))
          (should (numberp (plist-get n :ts)))
          (should (equal '("s1" "t1" "/p/" "task-review")
                         (mapcar (lambda (k) (plist-get n k)) '(:session :task :project :kind)))))
        (should (equal (funcall one) (funcall two)))
        (should (= 1 (length sent)))
        (should (equal (plist-get result :results) (cdar sent)))))))

(ert-deftest harness-notifications-send-to-named-providers ()
  (harness-notifications-test-with
    (let ((one (harness-notifications-test--capture 'one))
          (two (harness-notifications-test--capture 'two))
          (harness-notifications-providers '(one)))
      (should (equal '((:provider two :status sent :detail "kept"))
                     (plist-get (harness-notifications-test--send '(:body "b") '("two")) :results)))
      (should (null (funcall one)))
      (should (= 1 (length (funcall two))))
      ;; Without a title the notification still has its text.
      (should (equal "b" (plist-get (car (funcall two)) :body)))
      (should (eq 'normal (plist-get (car (funcall two)) :urgency))))))

(ert-deftest harness-notifications-a-hanging-provider-times-out ()
  (harness-notifications-test-with
    (let ((one (harness-notifications-test--capture 'one))
          (harness-notifications--timeout 0.2))
      (harness-notifications-define-provider 'stuck :send (lambda (_) (harness-make-promise)))
      (let ((results (plist-get (harness-notifications-test--send '(:title "T") '(stuck one)) :results)))
        (should (equal '(:provider one :status sent :detail "kept") (cadr results)))
        (should (eq 'failed (plist-get (car results) :status)))
        (should (equal "Notification provider stuck did not answer within 0.2s"
                       (plist-get (car results) :error))))
      (should (= 1 (length (funcall one)))))))

(ert-deftest harness-notifications-filter-changes-or-drops ()
  (harness-notifications-test-with
    (let ((one (harness-notifications-test--capture 'one))
          (harness-notifications-providers '(one)))
      (harness-add-filter 'notification/before-send
                          (lambda (n)
                            (unless (equal (plist-get n :kind) "noise")
                              (plist-put (copy-sequence n) :title (concat "[harness] " (plist-get n :title)))))
                          50)
      (harness-notifications-test--send '(:title "T"))
      (should (equal "[harness] T" (plist-get (car (funcall one)) :title)))
      (let ((dropped (harness-notifications-test--send '(:title "U" :kind "noise"))))
        (should (eq t (plist-get dropped :dropped)))
        (should (null (plist-get dropped :results)))
        (should (= 1 (length (funcall one))))))))

(ert-deftest harness-notifications-checks-what-it-sends ()
  (harness-notifications-test-with
    (let ((one (harness-notifications-test--capture 'one))
          (harness-notifications-providers '(one))
          (harness-notifications--max-body 10))
      (should-error (harness-call 'notification/send '(:title "  " :body "")))
      (should-error (harness-call 'notification/send "just text"))
      (harness-notifications-test--send '(:title "T" :body "0123456789abcdef"))
      (should (= 10 (length (plist-get (car (funcall one)) :body)))))))

(ert-deftest harness-notifications-providers-listing ()
  (harness-notifications-test-with
    (harness-notifications-define-provider 'unset :label "Unset" :doc "Never ready." :send #'ignore :ready #'ignore)
    (harness-notifications-define-provider 'checks :send #'ignore :ready (lambda () (error "Broken check")))
    (let ((harness-notifications-providers '(gotify unset)))
      (let ((listing (harness-call 'notification/providers)))
        (should (equal '(system gotify unset checks) (mapcar (lambda (p) (plist-get p :name)) listing)))
        (should (equal '(:name unset :label "Unset" :doc "Never ready." :ready nil :enabled t)
                       (nth 2 listing)))
        (should-not (plist-get (nth 3 listing) :ready))
        (should-not (plist-get (car listing) :enabled))))
    ;; Defining a provider again replaces it, in its place.
    (harness-notifications-define-provider 'unset :label "Now set" :send #'ignore)
    (let ((listing (harness-call 'notification/providers)))
      (should (equal "Now set" (plist-get (nth 2 listing) :label)))
      (should (plist-get (nth 2 listing) :ready)))
    (should-error (harness-notifications-define-provider 'nothing))
    (should-error (harness-notifications-define-provider "name" :send #'ignore))))

;;;; Gotify

(defmacro harness-notifications-test-without-gotify-env (&rest body)
  "Run BODY with no Gotify settings from the options, the environment or auth-source."
  (declare (indent 0))
  `(let ((harness-gotify-url nil)
         (harness-gotify-token nil)
         (auth-sources nil)
         (harness-notifications--auth-source-seen nil)
         (process-environment (append '("GOTIFY_URL" "GOTIFY_TOKEN") process-environment)))
     ,@body))

(ert-deftest harness-notifications-gotify-configuration ()
  (harness-notifications-test-with
    (harness-notifications-test-without-gotify-env
      (should-not (harness-notifications--gotify-ready-p))
      (let ((harness-gotify-url "https://push.example.com"))
        ;; An address alone is not enough.
        (should-not (harness-notifications--gotify-ready-p))
        (let ((harness-gotify-token "from-option"))
          (should (harness-notifications--gotify-ready-p))))
      ;; The environment.
      (let ((process-environment (append '("GOTIFY_URL=https://env.example.com" "GOTIFY_TOKEN=from-env")
                                         process-environment)))
        (should (equal '(:url "https://env.example.com" :token "from-env")
                       (harness-notifications--gotify-config)))
        ;; The options win.
        (let ((harness-gotify-url "https://option.example.com") (harness-gotify-token "from-option"))
          (should (equal '(:url "https://option.example.com" :token "from-option")
                         (harness-notifications--gotify-config)))))
      ;; The token from auth-source: the server's host, login harness.
      (let* ((dir (harness-test-temp-dir))
             (netrc (expand-file-name "authinfo" dir)))
        (unwind-protect
            (progn
              (with-temp-file netrc
                (insert "machine push.example.com login admin password not-this-one\n"
                        "machine push.example.com login harness password from-auth-source\n"))
              (auth-source-forget-all-cached)
              ;; What auth-source said is trusted for a while: above it had nothing.
              (should (equal "push.example.com" (car harness-notifications--auth-source-seen)))
              (setq harness-notifications--auth-source-seen nil)
              (let ((auth-sources (list netrc))
                    (harness-gotify-url "https://push.example.com/gotify/"))
                (should (equal '(:url "https://push.example.com/gotify/" :token "from-auth-source")
                               (harness-notifications--gotify-config)))
                (should (harness-notifications--gotify-ready-p))
                ;; GOTIFY_TOKEN comes before auth-source.
                (let ((process-environment (cons "GOTIFY_TOKEN=from-env" process-environment)))
                  (should (equal "from-env" (plist-get (harness-notifications--gotify-config) :token))))))
          (auth-source-forget-all-cached)
          (delete-directory dir t)))
      ;; Without a configuration the provider is skipped, not failed.
      (should (equal '((:provider gotify :status skipped :error "not set up"))
                     (plist-get (harness-notifications-test--send '(:title "T") '(gotify)) :results))))))

(ert-deftest harness-notifications-gotify-message ()
  (harness-notifications-test-with
    (should (equal '(:title "T" :message "B" :priority 8
                     :extras (:client::display (:contentType "text/plain")
                              :client::notification (:click (:url "https://example.com/pr/1"))))
                   (harness-notifications--gotify-message
                    '(:title "T" :body "B" :urgency critical :url "https://example.com/pr/1"))))
    (let ((harness-notifications--gotify-priorities '((low . 0) (normal . 4) (critical . 10))))
      (should (= 0 (plist-get (harness-notifications--gotify-message '(:title "T" :urgency low)) :priority)))
      (should (= 4 (plist-get (harness-notifications--gotify-message '(:title "T" :urgency normal)) :priority))))
    ;; The message is required by Gotify: the title stands in for a missing body.
    (let ((m (harness-notifications--gotify-message '(:title "Only a title" :urgency normal))))
      (should (equal "Only a title" (plist-get m :message)))
      (should (= 5 (plist-get m :priority)))
      (should-not (plist-get (plist-get m :extras) :client::notification)))
    (should (equal harness-notifications-desktop--app-name
                   (plist-get (harness-notifications--gotify-message '(:body "Just text")) :title)))))

(defun harness-notifications-test--serve (respond)
  "Start an HTTP server on 127.0.0.1 answering requests with RESPOND.
RESPOND takes a request plist (:method :path :headers :json) and returns
\(STATUS . BODY).  Return (SERVER . REQUESTS), REQUESTS a list of the
requests seen, newest first, kept in its cdr."
  (let* ((requests (list 'requests))
         (server
          (make-network-process
           :name "harness-test-gotify" :server t :host "127.0.0.1" :service t
           :family 'ipv4 :coding 'binary :noquery t
           :log (lambda (_server connection _message) (set-process-query-on-exit-flag connection nil))
           :filter
           (lambda (proc data)
             (let ((text (concat (or (process-get proc 'text) "") data)))
               (process-put proc 'text text)
               (when (string-match "\r\n\r\n" text)
                 (let* ((head-end (match-end 0))
                        (lines (split-string (substring text 0 (match-beginning 0)) "\r\n"))
                        (headers (delq nil (mapcar (lambda (l)
                                                     (and (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" l)
                                                          (cons (downcase (match-string 1 l)) (match-string 2 l))))
                                                   (cdr lines))))
                        (length (string-to-number (or (cdr (assoc "content-length" headers)) "0")))
                        (body (substring text head-end)))
                   (when (and (>= (length body) length) (not (process-get proc 'answered)))
                     (process-put proc 'answered t)
                     (let* ((line (split-string (car lines) " "))
                            (request (list :method (car line) :path (nth 1 line) :headers headers
                                           :json (ignore-errors
                                                   (harness-json-parse (decode-coding-string body 'utf-8)))))
                            (answer (funcall respond request))
                            (reply (encode-coding-string (cdr answer) 'utf-8)))
                       (setcdr requests (cons request (cdr requests)))
                       (process-send-string
                        proc (format "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
                                     (car answer) (if (< (car answer) 300) "OK" "Error") (length reply) reply))
                       (process-send-eof proc))))))))))
    (cons server requests)))

(defun harness-notifications-test--server-url (server)
  "Return the base URL of SERVER, from `harness-notifications-test--serve'."
  (format "http://127.0.0.1:%d" (process-contact (car server) :service)))

(ert-deftest harness-notifications-gotify-pushes-to-the-server ()
  (skip-unless (executable-find "curl"))
  (harness-notifications-test-with
    (harness-notifications-test-without-gotify-env
      (let ((server (harness-notifications-test--serve
                     (lambda (request)
                       (if (equal "good-token" (cdr (assoc "x-gotify-key" (plist-get request :headers))))
                           (cons 200 "{\"id\":7,\"appid\":3}")
                         (cons 401 "{\"error\":\"Unauthorized\",\"errorCode\":401,\"errorDescription\":\"you need to provide a valid access token or user credentials to access this api\"}"))))))
        (unwind-protect
            (let ((harness-gotify-url (concat (harness-notifications-test--server-url server) "/"))
                  (harness-gotify-token "good-token")
                  (harness-notifications-providers '(gotify)))
              (should (equal '((:provider gotify :status sent :detail "message 7"))
                             (plist-get (harness-notifications-test--send
                                         '(:title "Task done: CSV export" :body "project: merged into main"
                                           :urgency low :url "https://example.com/t/1"))
                                        :results)))
              (let ((request (cadr (cdr server))))
                (should (equal "POST" (plist-get request :method)))
                ;; The trailing slash of the address is not doubled.
                (should (equal "/message" (plist-get request :path)))
                (should (equal "good-token" (cdr (assoc "x-gotify-key" (plist-get request :headers)))))
                (should (equal "application/json" (cdr (assoc "content-type" (plist-get request :headers)))))
                (should (equal '(:title "Task done: CSV export" :message "project: merged into main" :priority 2
                                 :extras (:client::display (:contentType "text/plain")
                                          :client::notification (:click (:url "https://example.com/t/1"))))
                               (plist-get request :json))))
              ;; A token Gotify does not know.
              (let ((harness-gotify-token "bad-token"))
                (should (equal '((:provider gotify :status failed
                                  :error "Gotify: HTTP 401 Unauthorized: you need to provide a valid access token or user credentials to access this api"))
                               (plist-get (harness-notifications-test--send '(:title "T")) :results)))))
          (delete-process (car server)))))))

(ert-deftest harness-notifications-gotify-unreachable ()
  (skip-unless (executable-find "curl"))
  (harness-notifications-test-with
    (harness-notifications-test-without-gotify-env
      ;; A port nothing listens on: take one and close it.
      (let* ((server (harness-notifications-test--serve (lambda (_) (cons 200 "{}"))))
             (url (harness-notifications-test--server-url server)))
        (delete-process (car server))
        (let* ((harness-gotify-url url)
               (harness-gotify-token "t")
               (result (car (plist-get (harness-notifications-test--send '(:title "T") '(gotify)) :results))))
          (should (eq 'failed (plist-get result :status)))
          (should (string-prefix-p "Gotify: " (plist-get result :error)))
          (should (string-match-p "curl" (plist-get result :error))))))))

;;;; System: through the UI, else here

(defmacro harness-notifications-test-with-ui (handler &rest body)
  "Run BODY with an in-process client standing in for the UI.
HANDLER answers its `_harness/client/notify' requests: it gets the
params and the respond function.  The client goes when BODY ends."
  (declare (indent 1))
  `(let ((harness-acp--server-enabled nil)
         (harness-acp-token nil))
     (harness-test-load-module 'acp)
     (setq harness-acp--clients nil)
     (let ((conn (harness-acp-connect nil))
           (handler ,handler))
       (harness-acp-set-handler conn (lambda (method params respond)
                                       (if (equal method "_harness/client/notify")
                                           (funcall handler params respond)
                                         (when respond (harness-acp-respond-error respond -32601 "unhandled")))))
       (unwind-protect (progn ,@body)
         (dolist (c (copy-sequence harness-acp--clients)) (harness-acp--drop-client c))))))

(defmacro harness-notifications-test-with-local-desktop (result &rest body)
  "Run BODY with this process's desktop notifications stubbed to give RESULT.
RESULT is a promise-making form; `shown-here' lists what was shown."
  (declare (indent 1))
  `(let ((shown-here nil))
     (cl-letf (((symbol-function 'harness-notifications-desktop-notify)
                (lambda (&rest params) (push params shown-here) ,result))
               ((symbol-function 'harness-notifications-desktop-available-p) (lambda () t)))
       ,@body)))

(ert-deftest harness-notifications-system-without-a-ui-shows-it-here ()
  (harness-notifications-test-with
    (harness-notifications-test-with-local-desktop (harness-resolved '(:backend notify-send :id 3))
      (should (equal '((:provider system :status sent :detail "notify-send"))
                     (plist-get (harness-notifications-test--send
                                 '(:title "T" :body "B" :urgency low :url "https://x.example") '(system))
                                :results)))
      ;; The link ends the text a desktop shows.
      (should (equal '(:title "T" :body "B\nhttps://x.example" :urgency "low") (car shown-here))))))

(ert-deftest harness-notifications-system-goes-through-the-ui ()
  (harness-notifications-test-with
    (harness-notifications-test-with-local-desktop (error "Must not show it here")
      (let ((asked nil))
        (harness-notifications-test-with-ui
            (lambda (params respond) (push params asked) (funcall respond '(:backend "dbus")))
          (let ((result (harness-notifications-test--send
                         '(:title "Ready for review: x" :body "it works" :urgency critical
                           :session "s1" :task "t1" :project "/p/" :kind "task-review" :source "tasks")
                         '(system))))
            (should (equal '((:provider system :status sent :detail "dbus, in the UI"))
                           (plist-get result :results)))
            (should (null shown-here))
            (let ((params (car asked)))
              (should (equal (plist-get result :id) (plist-get params :id)))
              (should (equal '("Ready for review: x" "it works" "critical" "tasks" "task-review" "s1" "t1" "/p/")
                             (mapcar (lambda (k) (plist-get params k))
                                     '(:title :body :urgency :source :kind :session :task :project)))))
            ;; With a UI to show it, the provider is ready whatever this process can do.
            (cl-letf (((symbol-function 'harness-notifications-desktop-available-p) #'ignore))
              (should (plist-get (car (harness-call 'notification/providers)) :ready)))))))))

(ert-deftest harness-notifications-system-falls-back-when-the-ui-cannot ()
  (harness-notifications-test-with
    (harness-notifications-test-with-local-desktop (harness-resolved '(:backend osascript))
      (harness-notifications-test-with-ui
          (lambda (_params respond) (harness-acp-respond-error respond -32000 "no desktop over ssh"))
        (should (equal '((:provider system :status sent :detail "osascript"))
                       (plist-get (harness-notifications-test--send '(:title "T") '(system)) :results)))
        (should (= 1 (length shown-here)))))
    ;; Both failing: both reasons.
    (harness-notifications-test-with-local-desktop (harness-rejected '(error "No way to show desktop notifications here"))
      (harness-notifications-test-with-ui
          (lambda (_params respond) (harness-acp-respond-error respond -32000 "no desktop over ssh"))
        (let ((result (car (plist-get (harness-notifications-test--send '(:title "T") '(system)) :results))))
          (should (eq 'failed (plist-get result :status)))
          (should (string-match-p "\\`the UI: .*no desktop over ssh.*; here: No way to show desktop notifications here\\'"
                                  (plist-get result :error))))))))

(ert-deftest harness-notifications-system-not-ready-without-any-desktop ()
  (harness-notifications-test-with
    (cl-letf (((symbol-function 'harness-notifications-desktop-available-p) #'ignore))
      (should-not (plist-get (car (harness-call 'notification/providers)) :ready))
      (should (equal '((:provider system :status skipped :error "not set up"))
                     (plist-get (harness-notifications-test--send '(:title "T") '(system)) :results))))))

(provide 'harness-notifications-test)
;;; harness-notifications-test.el ends here
