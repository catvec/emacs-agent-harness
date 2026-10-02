;;; harness-tools-notify.el --- Tools that notify the user  -*- lexical-binding: t; -*-

;;; Commentary:

;; Gives agents the notifications module (harness-notifications.el):
;;
;; - `notify' sends the user a notification through the providers that
;;   are set up -- a desktop notification, a push to their phone through
;;   Gotify -- marked with the calling session, so that clicking it opens
;;   the session.  An agent reaches a user who is away with it: long work
;;   finished, or a decision only they can make.  A session sends at most
;;   `harness-tools-notify-rate-limit' of them in a while, so a runaway
;;   loop cannot flood the user.
;; - `notification_providers' lists the providers, whether each is set
;;   up and whether it is used by default, so an agent can pick providers
;;   or tell the user how to set one up.
;;
;; `notify' needs no approval (it is in `harness-perms-auto-allow-tools'):
;; it only reaches the user, through channels they configured themselves.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defcustom harness-tools-notify-rate-limit '(10 . 600)
  "At most COUNT `notify' calls per session in SECONDS, as (COUNT . SECONDS).
nil sets no limit."
  :type '(choice (const :tag "No limit" nil)
                 (cons :tag "Limit" (integer :tag "Notifications") (number :tag "Seconds")))
  :group 'harness)

(defvar harness-tools-notify--sent (make-hash-table :test 'equal)
  "Session id -> times of its recent `notify' calls, newest first.")

(defun harness-tools-notify--text (value)
  "Return VALUE trimmed when it is a non-blank string, else nil."
  (and (stringp value) (not (string-blank-p value)) (string-trim value)))

(defun harness-tools-notify--throttle (session-id)
  "Count a notification of SESSION-ID; return nil, or the seconds to wait.
The wait is how long until the session may notify again, when it has
sent `harness-tools-notify-rate-limit' notifications already."
  (let ((limit harness-tools-notify-rate-limit)
        (key (or session-id "")))
    (when (and (consp limit) (integerp (car limit)) (numberp (cdr limit)))
      (let* ((now (float-time))
             (window (cdr limit))
             (recent (cl-remove-if (lambda (time) (>= (- now time) window))
                                   (gethash key harness-tools-notify--sent))))
        (if (>= (length recent) (car limit))
            (progn (puthash key recent harness-tools-notify--sent)
                   (max 1 (ceiling (- (+ (car (last recent)) window) now))))
          (puthash key (cons now recent) harness-tools-notify--sent)
          nil)))))

(defun harness-tools-notify--session (session-id)
  "Return the session plist of SESSION-ID, or nil."
  (and session-id (harness-method-exists-p 'session/get)
       (ignore-errors (harness-call 'session/get session-id))))

(defun harness-tools-notify--provider-names (value)
  "Return the provider names in VALUE, the `providers' input, or nil."
  (cond ((stringp value) (split-string value "[ ,]+" t))
        ((vectorp value) (cl-remove-if-not #'stringp (append value nil)))
        ((listp value) (cl-remove-if-not #'stringp value))))

(defun harness-tools-notify--outcome (result)
  "Describe RESULT, a delivery result of `notification/send'."
  (let ((why (or (plist-get result :detail) (plist-get result :error))))
    (format "%s%s" (plist-get result :provider) (if why (format " (%s)" why) ""))))

(defun harness-tools-notify--report (result)
  "Return the tool result for RESULT, what `notification/send' returned."
  (if (harness-json-true-p (plist-get result :dropped))
      (harness-tool-ok "The user's notification rules (a notification/before-send filter) dropped the notification; nothing was sent.")
    (let* ((results (plist-get result :results))
           (pick (lambda (status) (cl-remove-if-not (lambda (r) (eq (plist-get r :status) status)) results)))
           (sent (funcall pick 'sent))
           (failed (funcall pick 'failed))
           (skipped (funcall pick 'skipped))
           (text (string-join
                  (delq nil
                        (list (and sent (format "Sent through %s." (mapconcat #'harness-tools-notify--outcome sent ", ")))
                              (and failed (format "Failed: %s." (mapconcat #'harness-tools-notify--outcome failed ", ")))
                              (and skipped (format "Skipped: %s." (mapconcat #'harness-tools-notify--outcome skipped ", ")))))
                  " ")))
      (if sent
          (harness-tool-ok text :meta (list :notification (plist-get result :id)))
        (harness-tool-error
         (concat (if (string-empty-p text) "No notification provider is enabled." (concat "Not sent. " text))
                 " The user picks providers with harness-notifications-providers; a desktop needs notify-send"
                 " (libnotify) or Emacs with D-Bus, and Gotify needs harness-gotify-url and harness-gotify-token"
                 " (or GOTIFY_URL and GOTIFY_TOKEN). notification_providers shows what is set up.")
         :meta (list :notification (plist-get result :id)))))))

(defun harness-tools-notify--notify (input ctx)
  "Handler of the notify tool: send INPUT's notification for the session in CTX."
  (let* ((message (harness-tools-notify--text (plist-get input :message)))
         (sid (plist-get ctx :session-id))
         (session (harness-tools-notify--session sid))
         (title (or (harness-tools-notify--text (plist-get input :title))
                    (harness-tools-notify--text (plist-get session :name))
                    "Agent"))
         (urgency (let ((u (harness-tools-notify--text (plist-get input :urgency))))
                    (if (member u '("low" "normal" "critical")) (intern u) 'normal)))
         (providers (harness-tools-notify--provider-names (plist-get input :providers)))
         (url (harness-tools-notify--text (plist-get input :url))))
    (cond
     ((null message) (harness-tool-error "Missing message: say what the user should know."))
     ((not (harness-method-exists-p 'notification/send))
      (harness-tool-error "Notifications are not available: the notifications module is not loaded."))
     (t
      (let ((wait (harness-tools-notify--throttle sid)))
        (if wait
            (harness-tool-error
             (format "Too many notifications: this session sent %d in the last %s. The next one can go in %s; send fewer, or gather news into one."
                     (car harness-tools-notify-rate-limit)
                     (harness-format-duration (cdr harness-tools-notify-rate-limit))
                     (harness-format-duration wait)))
          (harness-then
           (harness-call-async 'notification/send
                               (list :title title :body message :urgency urgency
                                     :source "agent" :kind "agent" :session sid
                                     :project (plist-get session :project) :url url)
                               providers)
           #'harness-tools-notify--report
           (lambda (err)
             (harness-tool-error (format "Could not send the notification: %s" (harness-error-message err)))))))))))

(harness-define-tool "notify"
  :label "Notification"
  :description "Send the user a notification: a desktop notification and, where they set one up, a push to their phone (Gotify). Use it to reach the user while they are away from this session: long work finished, or something needs their decision. Keep it short and self-contained; not for routine progress, and never include secrets. Clicking it opens this session. Returns which providers delivered it."
  :schema '(:type "object"
            :properties (:message (:type "string" :description "What the user should know, in a sentence or two.")
                         :title (:type "string" :description "A short headline (default: this session's name).")
                         :urgency (:type "string" :enum ("low" "normal" "critical")
                                   :description "How insistent it is (default normal; critical stays on screen until dismissed).")
                         :providers (:type "array" :items (:type "string")
                                     :description "Send only to these providers (see notification_providers); default: the ones the user enabled.")
                         :url (:type "string" :description "A link to open when the notification is clicked, where a provider can (Gotify on phones)."))
            :required ("message"))
  :kind 'meta
  :subject (lambda (input)
             (harness-first-line (or (harness-tools-notify--text (plist-get input :title))
                                     (plist-get input :message))
                                 60))
  :handler #'harness-tools-notify--notify)

;;;; Providers

(defun harness-tools-notify--provider-line (provider)
  "Return the listing of PROVIDER, a plist of `notification/providers'."
  (let ((ready (harness-json-true-p (plist-get provider :ready)))
        (enabled (harness-json-true-p (plist-get provider :enabled))))
    (format "%s (%s): %s%s"
            (plist-get provider :name) (or (plist-get provider :label) (plist-get provider :name))
            (cond ((and ready enabled) "set up, used by default")
                  (ready "set up, used only when named")
                  (enabled "not set up yet (used by default once it is)")
                  (t "not set up, not used by default"))
            (if (plist-get provider :doc) (concat "\n  " (plist-get provider :doc)) ""))))

(defun harness-tools-notify--providers (_input _ctx)
  "Handler of the notification_providers tool."
  (if (not (harness-method-exists-p 'notification/providers))
      (harness-tool-error "Notifications are not available: the notifications module is not loaded.")
    (let ((providers (harness-call 'notification/providers)))
      (harness-tool-ok
       (if (null providers)
           "No notification provider is defined."
         (concat (mapconcat #'harness-tools-notify--provider-line providers "\n")
                 "\n\nnotify sends to the providers used by default that are set up; its providers parameter names others."))))))

(harness-define-tool "notification_providers"
  :label "Notification providers"
  :description "List the notification providers notify can send through: which are set up, which are used by default, and what each does."
  :schema '(:type "object" :properties :empty)
  :kind 'read
  :coalescable t
  :subject #'ignore
  :handler #'harness-tools-notify--providers)

(harness-define-module 'tools-notify
  :doc "Notification and Notification providers: agents reach the user through the notifications module."
  :requires '(tools notifications))

(provide 'harness-tools-notify)
;;; harness-tools-notify.el ends here
