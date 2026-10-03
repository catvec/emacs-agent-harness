;;; harness-notifications.el --- Notify the user through pluggable providers  -*- lexical-binding: t; -*-

;;; Commentary:

;; Any part of the harness tells the user something with
;; `notification/send': the task module when work waits for review, an
;; agent through the `notify' tool, a user's own hook.  A notification
;; is a plist:
;;
;;   (:title "Ready for review: Add CSV export"  ; the headline
;;    :body "emacs-agent-harness: ..."           ; optional text
;;    :urgency low|normal|critical               ; default normal
;;    :source "tasks" :kind "task-review"        ; who sends it, and why
;;    :session SID :task ID :project ROOT        ; what it is about
;;    :url "https://...")                        ; a link, where one can open
;;
;; It goes to every provider named by `harness-notifications-providers'
;; (or the call's own list) that is set up, all at once; one that fails
;; or hangs never holds up the others.  The sync filter
;; `notification/before-send' sees each notification first and may
;; change it or drop it (return nil): a do-not-disturb rule, say.
;;
;; Providers come from `harness-notifications-define-provider'.  The
;; `system' provider, a desktop notification, is built in here: it is
;; shown by the user's Emacs (the UI, over `_harness/client/notify'),
;; which is where the user is even when this harness runs on another
;; machine, and where a click on it can open the session or task it is
;; about.  When no UI shows it, this process shows it itself.  See
;; harness-notifications-desktop.el for the ways a desktop is reached.
;;
;; The `gotify' provider pushes to a Gotify server (its phone app, say)
;; once you have set one up: a server address and the token of a Gotify
;; application, from `harness-gotify-url' and `harness-gotify-token', the
;; GOTIFY_URL and GOTIFY_TOKEN environment variables, or (the token) an
;; auth-source entry for the server.  Until then it is skipped.
;;
;; `notification/providers' lists the providers and whether each is set
;; up and enabled.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'auth-source)
(require 'harness-core)
(require 'harness-util)
(require 'harness-http)
(require 'harness-notifications-desktop)

(defcustom harness-notifications-providers '(system gotify)
  "Providers notifications go to, by name.
`system' shows a desktop notification; `gotify' pushes it to a Gotify
server once one is set up (see `harness-gotify-url').  A provider that
is not set up is skipped, so listing one costs nothing until it is.
Other providers are added with `harness-notifications-define-provider'.
nil sends notifications nowhere."
  :type '(repeat (choice (const :tag "Desktop notification" system)
                         (const :tag "Gotify" gotify)
                         (symbol :tag "Other provider")))
  :group 'harness)

(defconst harness-notifications--timeout 30
  "Seconds a provider may take to deliver a notification.")

(defconst harness-notifications--max-body 1000
  "Characters of a notification's text kept; the rest is cut.")

;;;; Providers

(cl-defstruct (harness-notifications-provider (:copier nil))
  name label doc send ready)

(defvar harness-notifications--providers nil
  "Alist of provider name -> `harness-notifications-provider', in definition order.")

(cl-defun harness-notifications-define-provider (name &key label doc send ready)
  "Define the notification provider NAME, a symbol.
SEND is called with a notification plist (see the Commentary) and
delivers it: it returns anything, or a promise, once the notification
is on its way, and signals or rejects when it cannot deliver it.  A
plist value with `:detail' says how it was delivered.  READY is a
function of no arguments saying whether the provider is set up, quickly
since it runs before every notification; without READY it always is.
LABEL names it for people and DOC says what it does.  Defining NAME
again replaces it."
  (unless (and name (symbolp name)) (error "A provider name must be a symbol: %S" name))
  (unless (functionp send) (error "Notification provider %s needs a send function" name))
  (let ((provider (make-harness-notifications-provider
                   :name name :label (or label (symbol-name name)) :doc doc :send send :ready ready)))
    (if (assq name harness-notifications--providers)
        (setf (alist-get name harness-notifications--providers) provider)
      (setq harness-notifications--providers
            (append harness-notifications--providers (list (cons name provider)))))
    name))

(defun harness-notifications--provider (name)
  "Return the provider NAME, a symbol or its name, or nil."
  (alist-get (if (stringp name) (intern name) name) harness-notifications--providers))

(defun harness-notifications--ready-p (provider)
  "Non-nil when PROVIDER is set up; a readiness check that signals says no."
  (let ((ready (harness-notifications-provider-ready provider)))
    (or (null ready)
        (condition-case err
            (and (funcall ready) t)
          (error
           (harness-log 'warn "notifications: checking %s failed: %s"
                        (harness-notifications-provider-name provider) (harness-error-message err))
           nil)))))

;;;; Sending

(defun harness-notifications--text (value)
  "Return VALUE as trimmed text, or nil when it is empty."
  (let ((s (cond ((stringp value) value)
                 ((null value) nil)
                 ((symbolp value) (symbol-name value))
                 (t (format "%s" value)))))
    (and s (not (string-blank-p s)) (string-trim s))))

(defun harness-notifications--error-text (err)
  "Return the message of ERR, without the error's own name in front of it."
  (if (and (consp err) (memq (car err) '(error harness-error user-error)) (stringp (cadr err)) (null (cddr err)))
      (cadr err)
    (harness-error-message err)))

(defun harness-notifications--urgency (value)
  "Return VALUE, a symbol or its name, as an urgency: low, normal or critical."
  (let ((u (if (stringp value) (intern-soft (downcase (string-trim value))) value)))
    (if (memq u '(low normal critical)) u 'normal)))

(defun harness-notifications--normalise (notification)
  "Return NOTIFICATION checked and completed with `:id', `:ts' and `:urgency'.
Signal when it has neither a title nor a body."
  (unless (listp notification) (error "A notification is a plist, not %S" notification))
  (let ((title (harness-notifications--text (plist-get notification :title)))
        (body (harness-notifications--text (plist-get notification :body))))
    (unless (or title body) (error "A notification needs a title or a body"))
    (harness-plist-merge
     notification
     (list :id (or (harness-notifications--text (plist-get notification :id))
                   (concat "n-" (harness-short-id)))
           :ts (or (plist-get notification :ts) (float-time))
           :title title
           :body (and body (harness-truncate-end body harness-notifications--max-body))
           :urgency (harness-notifications--urgency (plist-get notification :urgency))))))

(defun harness-notifications--within (promise seconds what)
  "Return a promise settled as PROMISE, or rejected after SECONDS.
WHAT names the work for the error."
  (let ((result (harness-make-promise))
        (timer nil))
    (setq timer (run-at-time seconds nil
                             (lambda ()
                               (harness-reject result (list 'error (format "%s did not answer within %ss"
                                                                            what seconds))))))
    (harness-then promise
                  (lambda (v) (cancel-timer timer) (harness-resolve result v) nil)
                  (lambda (e) (cancel-timer timer) (harness-reject result e) nil))
    result))

(defun harness-notifications--result (name status &rest props)
  "Return the delivery result of provider NAME: STATUS and the non-nil PROPS."
  (append (list :provider name :status status)
          (cl-loop for (k v) on props by #'cddr when v append (list k v))))

(defun harness-notifications--deliver (name notification)
  "Return a promise of what became of NOTIFICATION at provider NAME.
It never rejects: a failure is a result with status `failed'."
  (let ((provider (harness-notifications--provider name)))
    (cond
     ((null provider)
      (harness-resolved (harness-notifications--result name 'skipped :error "no such provider")))
     ((not (harness-notifications--ready-p provider))
      (harness-resolved (harness-notifications--result name 'skipped :error "not set up")))
     (t
      (harness-then
       (harness-notifications--within
        (condition-case err
            (harness-as-promise (funcall (harness-notifications-provider-send provider) notification))
          (error (harness-rejected err)))
        harness-notifications--timeout (format "Notification provider %s" name))
       (lambda (value)
         (harness-notifications--result name 'sent
                                        :detail (and (consp value) (keywordp (car value))
                                                     (harness-notifications--text (plist-get value :detail)))))
       (lambda (err)
         (let ((message (harness-notifications--error-text err)))
           (harness-log 'warn "notifications: %s could not deliver %S: %s"
                        name (plist-get notification :title) message)
           (harness-notifications--result name 'failed :error message))))))))

(defun harness-notifications--names (providers)
  "Return the provider names to send to: PROVIDERS, or the configured ones."
  (delete-dups
   (mapcar (lambda (p) (if (stringp p) (intern p) p))
           (cl-remove-if-not (lambda (p) (and p (or (symbolp p) (stringp p))))
                             (or providers harness-notifications-providers)))))

(harness-defmethod notification/send (notification &optional providers)
  "Send NOTIFICATION, a plist (see the notifications module), to its providers.
PROVIDERS, a list of names, overrides `harness-notifications-providers'.
The sync filter `notification/before-send' sees it first and may change
it or drop it by returning nil.  Every provider that is set up gets it
at once; one that fails never stops the others.  Return a promise of
\(:id ID :results ((:provider NAME :status sent|failed|skipped :detail
TEXT :error TEXT) ...)), with `:dropped t' when a filter dropped it.
Signal when NOTIFICATION has neither a title nor a body."
  (let* ((normal (harness-notifications--normalise notification))
         (id (plist-get normal :id))
         (final (harness-run-filter 'notification/before-send normal)))
    (if (null final)
        (harness-resolved (list :id id :dropped t :results nil))
      (let ((final (harness-notifications--normalise (plist-put (copy-sequence final) :id id))))
        (harness-then
         (harness-all (mapcar (lambda (name) (harness-notifications--deliver name final))
                              (harness-notifications--names providers)))
         (lambda (results)
           (harness-emit 'notification/sent final results)
           (list :id id :results results)))))))

(harness-defmethod notification/providers ()
  "Return every notification provider as (:name :label :doc :ready :enabled).
`:ready' says whether it is set up, `:enabled' whether
`harness-notifications-providers' sends to it."
  (mapcar (lambda (cell)
            (let ((p (cdr cell)))
              (list :name (car cell)
                    :label (harness-notifications-provider-label p)
                    :doc (harness-notifications-provider-doc p)
                    :ready (harness-notifications--ready-p p)
                    :enabled (and (memq (car cell) harness-notifications-providers) t))))
          harness-notifications--providers))

;;;; System: a desktop notification, shown by the UI when there is one

(defconst harness-notifications--ui-timeout 10
  "Seconds the UI may take to show a desktop notification before this process does.")

(defun harness-notifications--ui-connected-p ()
  "Non-nil when a client (the UI) is connected and can be asked."
  (and (harness-method-exists-p 'client/request)
       (harness-method-exists-p 'acp/status)
       (let ((clients (ignore-errors (plist-get (harness-call 'acp/status) :clients))))
         (and (numberp clients) (> clients 0)))))

(defun harness-notifications--desktop-text (notification)
  "Return (TITLE . BODY) for NOTIFICATION as a desktop shows it.
Without a title the body's first line is the title.  A URL the text
does not show yet ends the body."
  (let* ((title (plist-get notification :title))
         (body (plist-get notification :body))
         (url (harness-notifications--text (plist-get notification :url)))
         (text (if title body
                 (let ((rest (cdr (split-string body "\n"))))
                   (and rest (string-join rest "\n"))))))
    (cons (or title (harness-first-line body 80))
          (harness-notifications--text
           (concat (or text "")
                   (if (and url (not (and text (string-search url text))))
                       (concat (if text "\n" "") url)
                     ""))))))

(defun harness-notifications--client-params (notification)
  "Return the `_harness/client/notify' parameters for NOTIFICATION."
  (let ((text (harness-notifications--desktop-text notification)))
    (append (list :id (plist-get notification :id)
                  :title (car text)
                  :body (cdr text)
                  :urgency (symbol-name (plist-get notification :urgency)))
            (cl-loop for k in '(:source :kind :session :task :project :url)
                     for v = (plist-get notification k)
                     when v append (list k (if (symbolp v) (symbol-name v) v))))))

(defun harness-notifications--show-here (params)
  "Show the desktop notification PARAMS from this process; return a promise."
  (harness-then (harness-notifications-desktop-notify :title (plist-get params :title)
                                                       :body (plist-get params :body)
                                                       :urgency (plist-get params :urgency))
                (lambda (r) (list :detail (format "%s" (plist-get r :backend))))))

(defun harness-notifications--system-send (notification)
  "Show NOTIFICATION on the desktop: through the UI, else from here.
The UI is where the user is, and its notification opens what it is
about when clicked; this process shows it when no UI does."
  (let ((params (harness-notifications--client-params notification)))
    (if (not (harness-notifications--ui-connected-p))
        (harness-notifications--show-here params)
      (harness-then
       (harness-notifications--within (harness-call-async 'client/request "_harness/client/notify" params)
                                      harness-notifications--ui-timeout "The UI")
       (lambda (r)
         (list :detail (format "%s, in the UI" (or (plist-get r :backend) "shown"))))
       (lambda (err)
         (harness-log 'info "notifications: the UI did not show %S (%s); showing it here"
                      (plist-get params :title) (harness-notifications--error-text err))
         (harness-catch (harness-notifications--show-here params)
                        (lambda (here)
                          (signal 'error
                                  (list (format "the UI: %s; here: %s"
                                                (harness-notifications--error-text err)
                                                (harness-notifications--error-text here)))))))))))

(defun harness-notifications--system-ready-p ()
  "Non-nil when a desktop notification can be shown: by the UI or from here."
  (or (harness-notifications--ui-connected-p)
      (harness-notifications-desktop-available-p)))

;;;; Gotify

(defcustom harness-gotify-url nil
  "Address of your Gotify server, such as \"https://push.example.com\".
When nil the GOTIFY_URL environment variable is used.  The `gotify'
notification provider sends nothing until both this address and an
application token (`harness-gotify-token') are set."
  :type '(choice (const :tag "Not set" nil) string) :group 'harness)

(defcustom harness-gotify-token nil
  "Token of the Gotify application harness notifications are pushed as.
Create an application in Gotify's web interface and use its token.
When nil the GOTIFY_TOKEN environment variable is used, then an
auth-source entry for the server's host with the login \"harness\",
such as \"machine push.example.com login harness password TOKEN\"."
  :type '(choice (const :tag "Not set" nil) string) :group 'harness)

(defconst harness-notifications--gotify-priorities '((low . 2) (normal . 5) (critical . 8))
  "Gotify priority of each urgency.
Gotify's Android app shows priorities from 1 in the status bar, makes
a sound from 4 and pops up from 8; 0 shows nothing.")

(defconst harness-notifications--auth-source-ttl 300
  "Seconds what auth-source said about the Gotify token is trusted.
Looking it up may decrypt a file, and readiness is checked before every
notification.")

(defvar harness-notifications--auth-source-seen nil
  "(HOST TIME TOKEN): the Gotify token auth-source last gave for HOST.")

(defun harness-notifications--gotify-auth-source-token (url)
  "Return the Gotify token auth-source keeps for URL's host, or nil."
  (let ((host (ignore-errors (url-host (url-generic-parse-url url)))))
    (when (and host (not (string-empty-p host)))
      (let ((seen harness-notifications--auth-source-seen))
        (if (and seen (equal (nth 0 seen) host)
                 (< (- (float-time) (nth 1 seen)) harness-notifications--auth-source-ttl))
            (nth 2 seen)
          (let ((token (condition-case nil
                           (let* ((found (car (auth-source-search :host host :user "harness"
                                                                  :max 1 :require '(:secret))))
                                  (secret (and found (plist-get found :secret))))
                             (harness-notifications--text
                              (cond ((functionp secret) (funcall secret))
                                    ((stringp secret) secret))))
                         (error nil))))
            (setq harness-notifications--auth-source-seen (list host (float-time) token))
            token))))))

(defun harness-notifications--gotify-config ()
  "Return (:url URL :token TOKEN) for Gotify; either may be nil.
Each comes from the first place that has it: the option, the
environment, then for the token auth-source."
  (let* ((url (or (harness-notifications--text harness-gotify-url)
                  (harness-notifications--text (getenv "GOTIFY_URL"))))
         (token (or (harness-notifications--text harness-gotify-token)
                    (harness-notifications--text (getenv "GOTIFY_TOKEN"))
                    (and url (harness-notifications--gotify-auth-source-token url)))))
    (list :url url :token token)))

(defun harness-notifications--gotify-ready-p ()
  "Non-nil when a Gotify server address and application token are set."
  (let ((config (harness-notifications--gotify-config)))
    (and (plist-get config :url) (plist-get config :token) t)))

(defun harness-notifications--gotify-message (notification)
  "Return the JSON body of Gotify's POST /message for NOTIFICATION."
  (let* ((title (plist-get notification :title))
         (body (plist-get notification :body))
         (url (harness-notifications--text (plist-get notification :url)))
         (priority (or (alist-get (plist-get notification :urgency) harness-notifications--gotify-priorities)
                       (alist-get 'normal harness-notifications--gotify-priorities)
                       5)))
    (list :title (or title harness-notifications-desktop--app-name)
          :message (or body title)
          :priority priority
          :extras (append (list :client::display (list :contentType "text/plain"))
                          (and url (list :client::notification (list :click (list :url url))))))))

(defun harness-notifications--gotify-error (err)
  "Return a readable message for ERR, how a Gotify request failed."
  (pcase err
    (`(http-error ,status ,(and (pred stringp) body))
     (let ((json (ignore-errors (harness-json-parse body))))
       (format "HTTP %s%s" (or status "?")
               (cond ((and (consp json) (keywordp (car json)))
                      (concat " " (string-join (delq nil (list (plist-get json :error)
                                                               (plist-get json :errorDescription)))
                                               ": ")))
                     ((string-blank-p body) "")
                     (t (concat " " (harness-truncate-end (string-trim body) 200)))))))
    (`(http-error ,_ ,(and (pred consp) transport))
     (format "%s" (or (cadr transport) transport)))
    (_ (harness-notifications--error-text err))))

(defun harness-notifications--gotify-send (notification)
  "Push NOTIFICATION to the Gotify server; return a promise."
  (let* ((config (harness-notifications--gotify-config))
         (url (plist-get config :url))
         (token (plist-get config :token)))
    (unless (and url token) (error "Gotify is not set up: no server address or application token"))
    (harness-then
     (harness-http-request-json (concat (string-remove-suffix "/" url) "/message")
                                :method "POST"
                                ;; The token goes in a header, which harness-http
                                ;; keeps off the command line.
                                :headers (list (cons "X-Gotify-Key" token)
                                               (cons "Accept" "application/json"))
                                :json (harness-notifications--gotify-message notification)
                                :timeout harness-notifications--timeout)
     (lambda (json)
       (list :detail (if (plist-get json :id) (format "message %s" (plist-get json :id)) "pushed")))
     (lambda (err)
       (signal 'error (list (format "Gotify: %s" (harness-notifications--gotify-error err))))))))

;;;; Module

(defun harness-notifications--define-builtin ()
  "Define the built-in providers (again, on reload)."
  (harness-notifications-define-provider
   'system :label "Desktop"
   :doc "A desktop notification, shown by your Emacs (clicking it opens the session or task), else by the harness process."
   :send #'harness-notifications--system-send
   :ready #'harness-notifications--system-ready-p)
  (harness-notifications-define-provider
   'gotify :label "Gotify"
   :doc "A push to your Gotify server, once its address and an application token are set (harness-gotify-url, harness-gotify-token)."
   :send #'harness-notifications--gotify-send
   :ready #'harness-notifications--gotify-ready-p))

(harness-notifications--define-builtin)

(harness-declare-event 'notification/sent
                       "(NOTIFICATION RESULTS) after a notification went to its providers.")

(harness-define-module 'notifications
  :doc "Notifications for the user through pluggable providers: desktop (system) and Gotify."
  :init #'harness-notifications--define-builtin)

(provide 'harness-notifications)
;;; harness-notifications.el ends here
