;;; harness-ui-supervisor.el --- Supervisor mode in the chat header and on V  -*- lexical-binding: t; -*-

;;; Commentary:

;; A session the supervisor plugin governs says so in its `:ext' plist:
;; `:supervisor' is t while it supervises, which means that it plans,
;; delegates to workers on cheaper models and changes no files itself,
;; and `:false' once the user turned that off, "hands-on".  A session
;; the plugin does not govern, a sub-agent or a side conversation, has no
;; such key and shows nothing.
;;
;; A governed chat's header line starts with the state, before the status
;; icon: "supervisor" in `harness-supervisor-face', or "hands-on" in
;; `harness-dim-face'.  A click there toggles it, and so does V in the
;; harness keys (C-c h V, `harness-toggle-supervisor'), which asks the
;; harness for the change with `_harness/supervisor/set' and says what
;; it changed.  The header follows the session as the harness sends it.

;;; Code:

(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-chat-header-functions)

(declare-function harness-chat--session "harness-ui-chat")
(declare-function harness-chat--segment "harness-ui-chat")

(defface harness-supervisor-face '((t :inherit success))
  "A session that supervises: it plans and delegates, but changes no files."
  :group 'harness-ui)

(defun harness-ui-supervisor--header ()
  "Return the supervisor segment of this chat's header line, or nil.
It reads \"supervisor\" while the session supervises, and \"hands-on\"
once the user turned that off.  A session the supervisor plugin does not
govern has no segment.  Clicking the segment toggles the mode."
  (let ((value (plist-get (plist-get (harness-chat--session) :ext) :supervisor)))
    (cond
     ((null value) nil)
     ((harness-json-true-p value)
      (concat (harness-chat--segment
               "supervisor" #'harness-toggle-supervisor
               "Supervisor mode: this session plans and delegates to workers on cheaper models; it cannot change files itself (mouse-1: let it work hands-on)"
               'harness-supervisor-face)
              " "))
     (t
      (concat (harness-chat--segment
               "hands-on" #'harness-toggle-supervisor
               "Hands-on: this session may change files itself (mouse-1: back to supervisor mode)"
               'harness-dim-face)
              " ")))))

(defun harness-ui-supervisor--failed (err)
  "Say why supervisor mode could not be changed, given the failure ERR.
A harness without the supervisor module does not know the method, which
is said plainly rather than as a failure."
  (unless (harness-ui-connection-replaced-p err)
    (let ((text (harness-error-message err)))
      (if (string-match-p "[Mm]ethod not found\\|No such harness method" text)
          (message "Supervisor mode is not available (the supervisor module is not loaded)")
        (message "Harness: supervisor mode failed: %s" text))))
  nil)

;;;###autoload
(defun harness-toggle-supervisor (&optional session-id)
  "Toggle supervisor mode for SESSION-ID.
A supervising session plans and delegates to workers on cheaper models
and changes no files itself; a hands-on one may change files itself.
Only a session the supervisor plugin governs has the mode: sub-agents
and side conversations never supervise.  The session's header line says
which it is, and clicking there toggles too.

On the task board the setting target is not a session: `C-c h V' or
the settings line's button then turns the mode the next task starts
with, or, in bulk mode, the mode of every current task, as the board's
other setting buttons do.  Without the supervisor module the harness
reports no such setting and the board offers no button."
  (interactive)
  (let* ((target (harness-ui--setting-target session-id))
         (session (and (stringp target) (harness-ui-session target)))
         (value (if (stringp target)
                    (plist-get (plist-get session :ext) :supervisor)
                  (harness-ui--setting-get target :supervisor))))
    (cond
     ((not (stringp target))
      ;; What the next task starts with, or the current tasks' setting.
      (let ((on (not (harness-json-true-p value))))
        (harness-ui--setting-set target :supervisor (if on t :false)
                                 (if on "Supervisor mode on" "Supervisor mode off (hands-on)"))))
     ((null session)
      (message "Supervisor mode: the harness has not sent this session yet"))
     ((null value)
      (message "Supervisor mode does not govern this session: sub-agents and side conversations never supervise"))
     (t
      (let ((on (not (harness-json-true-p value))))
        (harness-ui-call "_harness/supervisor/set"
                         (list :sessionId target :on (if on t :false))
                         (lambda (_session)
                           (message (if on "Supervisor mode on" "Supervisor mode off (hands-on)")))
                         #'harness-ui-supervisor--failed))))))

;;;; Module

(defun harness-ui-supervisor--init ()
  "Show the supervisor segment in chat headers and bind the toggle to V.
Idempotent: the header function is added to the hook only once."
  (add-hook 'harness-chat-header-functions #'harness-ui-supervisor--header)
  (define-key harness-ui-map (kbd "V") #'harness-toggle-supervisor))

(defun harness-ui-supervisor--shutdown ()
  "Take the supervisor segment out of chat headers and unbind V."
  (remove-hook 'harness-chat-header-functions #'harness-ui-supervisor--header)
  (when (eq (lookup-key harness-ui-map (kbd "V")) #'harness-toggle-supervisor)
    (define-key harness-ui-map (kbd "V") nil)))

(harness-define-module 'ui-supervisor
  :doc "Supervisor mode: the chat header's segment and the V key that toggles it."
  :requires '(ui ui-chat)
  :init #'harness-ui-supervisor--init
  :shutdown #'harness-ui-supervisor--shutdown)

(provide 'harness-ui-supervisor)
;;; harness-ui-supervisor.el ends here
