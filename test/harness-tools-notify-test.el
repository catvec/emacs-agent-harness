;;; harness-tools-notify-test.el --- Tests for the notify tools  -*- lexical-binding: t; -*-

;;; Commentary:

;; `notify' and `notification_providers' against fake notification
;; providers: nothing shows on a desktop or reaches the network.

;;; Code:

(require 'harness-test-helpers)

(defvar harness-notifications-providers)
(defvar harness-notifications--providers)
(defvar harness-tools-notify-rate-limit)
(defvar harness-tools-notify--sent)
(defvar harness-sessions)
(declare-function harness-notifications-define-provider "harness-notifications")

(defmacro harness-tools-notify-test-with (&rest body)
  "Run BODY with the tools, notifications and a session `sid' named \"Fix the parser\".
Every tool call is allowed; `got' lists what the provider `capture'
received, oldest first."
  (declare (indent 0))
  `(harness-test-with-temp-state
     (harness-test-reset-bus)
     (dolist (m '(store project config session tools notifications tools-notify))
       (harness-test-load-module m))
     (clrhash harness-sessions)
     (clrhash harness-tools-notify--sent)
     (harness-add-filter 'permission/decide (lambda (_d next &rest _) (funcall next (list :behavior 'allow))) 10)
     (let* ((harness-notifications--providers
             (mapcar (lambda (cell) (cons (car cell) (cdr cell))) harness-notifications--providers))
            (received nil)
            (harness-notifications-providers '(capture))
            (harness-tools-notify-rate-limit '(10 . 600))
            (sid (plist-get (harness-call 'session/create :cwd dir :name "Fix the parser") :id)))
       (harness-notifications-define-provider 'capture :label "Capture"
                                              :send (lambda (n) (push n received) '(:detail "kept")))
       (cl-flet ((got () (reverse received)))
         ,@body))))

(defun harness-tools-notify-test--call (sid name &rest input)
  "Run tool NAME with INPUT for session SID; return its result."
  (harness-test-await (harness-call 'tools/execute sid (list :id (harness-short-id) :name name :input input)) 10))

(ert-deftest harness-tools-notify-sends-for-the-session ()
  (harness-tools-notify-test-with
    (let ((r (harness-tools-notify-test--call sid "notify" :message "  The parser is fixed; tests pass. "
                                              :urgency "critical")))
      (should-not (plist-get r :is-error))
      (should (equal "Sent through capture (kept)." (plist-get r :content)))
      (let ((n (car (got)))
            (session (harness-call 'session/get sid)))
        ;; The session's name is the default title.
        (should (equal "Fix the parser" (plist-get n :title)))
        (should (equal "The parser is fixed; tests pass." (plist-get n :body)))
        (should (eq 'critical (plist-get n :urgency)))
        (should (equal '("agent" "agent") (list (plist-get n :source) (plist-get n :kind))))
        ;; Clicking it opens the session.
        (should (equal sid (plist-get n :session)))
        (should (equal (plist-get session :project) (plist-get n :project)))
        (should (equal (plist-get (plist-get r :meta) :notification) (plist-get n :id)))))
    (harness-tools-notify-test--call sid "notify" :message "m" :title "Deploy done"
                                     :url "https://example.com/run/1" :urgency "loud")
    (let ((n (cadr (got))))
      (should (equal "Deploy done" (plist-get n :title)))
      (should (equal "https://example.com/run/1" (plist-get n :url)))
      (should (eq 'normal (plist-get n :urgency))))))

(ert-deftest harness-tools-notify-named-providers-and-failures ()
  (harness-tools-notify-test-with
    (harness-notifications-define-provider 'broken :send (lambda (_) (error "Out of order")))
    (harness-notifications-define-provider 'unset :send #'ignore :ready #'ignore)
    ;; Named providers only.
    (let ((r (harness-tools-notify-test--call sid "notify" :message "m" :providers '("broken"))))
      (should (plist-get r :is-error))
      (should (string-prefix-p "Not sent. Failed: broken (Out of order)." (plist-get r :content)))
      (should (string-search "harness-gotify-url" (plist-get r :content)))
      (should (null (got))))
    ;; One delivering is enough.
    (let ((harness-notifications-providers '(capture broken unset)))
      (let ((r (harness-tools-notify-test--call sid "notify" :message "m")))
        (should-not (plist-get r :is-error))
        (should (equal "Sent through capture (kept). Failed: broken (Out of order). Skipped: unset (not set up)."
                       (plist-get r :content)))))
    ;; Nothing enabled.
    (let ((harness-notifications-providers nil))
      (let ((r (harness-tools-notify-test--call sid "notify" :message "m")))
        (should (plist-get r :is-error))
        (should (string-prefix-p "No notification provider is enabled." (plist-get r :content)))))
    ;; A filter of the user's dropped it.
    (harness-add-filter 'notification/before-send #'ignore)
    (let ((r (harness-tools-notify-test--call sid "notify" :message "m")))
      (should-not (plist-get r :is-error))
      (should (string-search "dropped" (plist-get r :content))))))

(ert-deftest harness-tools-notify-needs-a-message ()
  (harness-tools-notify-test-with
    (let ((r (harness-tools-notify-test--call sid "notify" :title "Only a title" :message "  ")))
      (should (plist-get r :is-error))
      (should (string-prefix-p "Missing message" (plist-get r :content)))
      (should (null (got))))))

(ert-deftest harness-tools-notify-rate-limit ()
  (harness-tools-notify-test-with
    (let ((harness-tools-notify-rate-limit '(2 . 600))
          (other (plist-get (harness-call 'session/create :cwd dir :name "Other") :id)))
      (should-not (plist-get (harness-tools-notify-test--call sid "notify" :message "one") :is-error))
      (should-not (plist-get (harness-tools-notify-test--call sid "notify" :message "two") :is-error))
      (let ((r (harness-tools-notify-test--call sid "notify" :message "three")))
        (should (plist-get r :is-error))
        (should (string-prefix-p "Too many notifications: this session sent 2 in the last 10m"
                                 (plist-get r :content))))
      (should (= 2 (length (got))))
      ;; Another session has its own count.
      (should-not (plist-get (harness-tools-notify-test--call other "notify" :message "four") :is-error))
      ;; Once the window has passed, it may send again.
      (puthash sid (mapcar (lambda (time) (- time 601)) (gethash sid harness-tools-notify--sent))
               harness-tools-notify--sent)
      (should-not (plist-get (harness-tools-notify-test--call sid "notify" :message "five") :is-error))
      ;; No limit at all.
      (let ((harness-tools-notify-rate-limit nil))
        (dotimes (_ 5)
          (should-not (plist-get (harness-tools-notify-test--call sid "notify" :message "more") :is-error)))))))

(ert-deftest harness-tools-notify-providers-listing ()
  (harness-tools-notify-test-with
    (harness-notifications-define-provider 'unset :label "Unset" :doc "Never ready." :send #'ignore :ready #'ignore)
    (let* ((harness-notifications-providers '(capture unset))
           (r (harness-tools-notify-test--call sid "notification_providers"))
           (text (plist-get r :content)))
      (should-not (plist-get r :is-error))
      (should (string-search "capture (Capture): set up, used by default" text))
      (should (string-search "unset (Unset): not set up yet (used by default once it is)\n  Never ready." text))
      (should (string-match-p "^gotify (Gotify): not set up, not used by default" text))
      (should (string-search "providers parameter" text)))))

(ert-deftest harness-tools-notify-tool-specs ()
  (harness-tools-notify-test-with
    (let ((notify (harness-call 'tools/get "notify"))
          (listing (harness-call 'tools/get "notification_providers")))
      (should (eq 'meta (plist-get notify :kind)))
      (should (equal '("message") (plist-get (plist-get notify :schema) :required)))
      (should (eq 'read (plist-get listing :kind)))
      (should (plist-get listing :coalescable))
      (should (equal "notify Deploy done" (harness-tool-title "notify" '(:title "Deploy done" :message "m"))))
      (should (equal "notify Tests pass" (harness-tool-title "notify" '(:message "Tests pass\nand more")))))))

(provide 'harness-tools-notify-test)
;;; harness-tools-notify-test.el ends here
