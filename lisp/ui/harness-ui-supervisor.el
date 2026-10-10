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
;;
;; `harness-set-supervisor-all' (the menu's V, beside the other "for all
;; sessions" commands) does the same for every governed session at once
;; and, unless a prefix argument says otherwise, makes the mode the
;; default for new work (`harness-supervisor' and
;; `harness-supervisor-tasks').  It changes nothing for a session the
;; plugin does not govern, nor for one whose task is completed.

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
which it is, and clicking there toggles too."
  (interactive)
  (let* ((target (harness-ui--setting-target session-id))
         (session (and (stringp target) (harness-ui-session target)))
         (value (plist-get (plist-get session :ext) :supervisor)))
    (cond
     ((not (stringp target))
      (message "Supervisor mode applies to a session, not to a task that has not started yet"))
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

;;;###autoload
(defun harness-set-supervisor-all (&optional no-default)
  "Turn supervisor mode on or off for every governed session at once.
It asks which, offering on first, and asks the harness for the change
with `_harness/supervisor/set-all': every current session the
supervisor module governs, idle, running or blocked, of every project,
and the sessions of the current tasks (running, pending or blocked),
even a closed one.  A sub-agent, a side conversation and a session
whose task is completed are left alone, as is a session already at the
asked value.  Unless NO-DEFAULT, the prefix argument, says otherwise,
the mode also becomes the default for new work: `harness-supervisor'
for new top-level sessions and `harness-supervisor-tasks' for the
sessions of new tasks.  Then it says how many sessions changed, and
what still has new work start otherwise, such as a project whose
.dir-locals.el sets `harness-supervisor'; it changes neither the file
nor the sessions that are already hands-on on purpose.  See
`harness-toggle-supervisor' for one session."
  (interactive "P")
  (let* ((choices '("on" "off"))
         (choice (completing-read "Supervisor mode for every session: "
                                  (lambda (string pred action)
                                    ;; On first, as offered.
                                    (if (eq action 'metadata)
                                        '(metadata (display-sort-function . identity)
                                                   (cycle-sort-function . identity))
                                      (complete-with-action action choices string pred)))
                                  nil t nil nil "on"))
         (on (not (equal choice "off"))))
    (harness-ui-call
     "_harness/supervisor/set-all"
     (list :on (if on t :false) :filter (harness-ui--everything-filter))
     (lambda (sessions)
       (unless no-default
         (dolist (key '("harness-supervisor" "harness-supervisor-tasks"))
           (harness-ui-call "_harness/config/set"
                            (list :key key :value (prin1-to-string on)
                                  :printed t :scope "global")
                            (lambda (_) nil))))
       (harness-ui--report-all
        (format "Supervisor mode %s for %s%s"
                (if on "on" "off")
                (harness-ui--count (length sessions) "session")
                (harness-ui--new-work-text no-default (not no-default)))
        "harness-supervisor" on
        ;; Turning it off says what still supervises, whatever the
        ;; default; turning it on, what keeps the new default hands-on.
        (or (not on) (not no-default))
        nil
        (lambda (value) (if (harness-json-true-p value) "supervise" "start hands-on"))))
     #'harness-ui-supervisor--failed)))

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
