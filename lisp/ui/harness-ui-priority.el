;;; harness-ui-priority.el --- A session's priority in the chat header and on p  -*- lexical-binding: t; -*-

;;; Commentary:

;; The priority plugin keeps a priority for every session -- low, medium
;; (the default) or high -- and the harness serves the work of a high
;; session before a low one's: the tool slots, above all, give the slots
;; of a busy machine to the calls of the highest priority session
;; waiting.  A task's session takes its task's priority; a chat of your
;; own has whatever you gave it.
;;
;; A chat whose session's priority is not the default shows it in the
;; header line, after the supervisor segment: "priority: high" in
;; `harness-priority-high-face' or "priority: low" in
;; `harness-priority-low-face' (dim).  A click there changes it, and so
;; does p in the harness keys (C-c h p, `harness-set-priority'), which
;; asks for a level and sends it with `_harness/priority/set'.  The
;; header follows the session as the harness announces it.

;;; Code:

(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(defvar harness-chat-header-functions)

(declare-function harness-chat--session "harness-ui-chat")
(declare-function harness-chat--segment "harness-ui-chat")

(defconst harness-ui-priority-levels '("low" "medium" "high")
  "The priorities a session may have, lowest first, as the harness sends them.")

(defconst harness-ui-priority-default "medium"
  "The priority a session has when it has none of its own.")

(defface harness-priority-high-face '((t :inherit warning))
  "The priority segment of a session whose priority is high."
  :group 'harness-ui)

(defface harness-priority-low-face '((t :inherit harness-dim-face :slant italic))
  "The priority segment of a session whose priority is low."
  :group 'harness-ui)

(defun harness-ui-priority--of (session)
  "Return SESSION's own priority, a string, or nil when it has none.
A priority the harness has not sent, or one this UI does not know, is nil."
  (let ((value (plist-get (plist-get session :ext) :priority)))
    (when value
      (let ((name (if (symbolp value) (symbol-name value) (format "%s" value))))
        (and (member name harness-ui-priority-levels) name)))))

(defun harness-ui-priority--header ()
  "Return the priority segment of this chat's header line, or nil.
It reads \"priority: high\" or \"priority: low\"; a session at the
default (`harness-ui-priority-default') shows nothing, and so does one
whose priority the harness has not sent.  Clicking the segment changes
the priority."
  (let ((level (harness-ui-priority--of (harness-chat--session))))
    (when (and level (not (equal level harness-ui-priority-default)))
      (concat
       (harness-chat--segment
        (format "priority: %s" level)
        #'harness-set-priority
        (format "Priority %s: the harness serves this session's commands before lower ones' (mouse-1: change the priority)"
                level)
        (if (equal level "high") 'harness-priority-high-face 'harness-priority-low-face))
       " "))))

(defun harness-ui-priority--failed (err)
  "Say why the priority could not be set, given the failure ERR.
A harness without the priority module does not know the method, which
is said plainly rather than as a failure."
  (unless (harness-ui-connection-replaced-p err)
    (let ((text (harness-error-message err)))
      (if (string-match-p "[Mm]ethod not found\\|No such harness method" text)
          (message "Priority is not available (the priority module is not loaded)")
        (message "Harness: setting the priority failed: %s" text))))
  nil)

;;;###autoload
(defun harness-set-priority (&optional session-id level)
  "Set the priority of SESSION-ID to LEVEL; ask for LEVEL when not given.
A priority is low, medium (the default) or high, and orders the queues
the session's work waits in: the calls of a high session are served
before a low one's (see the tool-slots module).  A task's session is at
its task's priority, set on the board; any other session has its own.
The chat header shows the priority when it is not the default."
  (interactive)
  (let ((target (harness-ui--setting-target session-id)))
    (cond
     ((not (stringp target))
      (message "Priority applies to a session, not to a task that has not started yet"))
     ((null (harness-ui-session target))
      (message "Priority: the harness has not sent this session yet"))
     (t
      (let ((level (or level
                       (completing-read
                        "Priority: " harness-ui-priority-levels nil t nil nil
                        (or (harness-ui-priority--of (harness-ui-session target))
                            harness-ui-priority-default)))))
        (if (not (member level harness-ui-priority-levels))
            (message "Priority is low, medium or high, not %S" level)
          (harness-ui-call "_harness/priority/set"
                           (list :sessionId target :priority level)
                           (lambda (result) (message "Priority: %s" (or result level)))
                           #'harness-ui-priority--failed)))))))

;;;; Module

(defun harness-ui-priority--init ()
  "Show the priority segment in chat headers and bind the setter to p.
Idempotent: the header function is added to the hook only once."
  (add-hook 'harness-chat-header-functions #'harness-ui-priority--header)
  (define-key harness-ui-map (kbd "p") #'harness-set-priority))

(defun harness-ui-priority--shutdown ()
  "Take the priority segment out of chat headers and unbind p."
  (remove-hook 'harness-chat-header-functions #'harness-ui-priority--header)
  (when (eq (lookup-key harness-ui-map (kbd "p")) #'harness-set-priority)
    (define-key harness-ui-map (kbd "p") nil)))

(harness-define-module 'ui-priority
  :doc "A session's priority: the chat header's segment and the p key that sets it."
  :requires '(ui ui-chat)
  :init #'harness-ui-priority--init
  :shutdown #'harness-ui-priority--shutdown)

(provide 'harness-ui-priority)
;;; harness-ui-priority.el ends here
