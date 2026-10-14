;;; harness-tools-session-info.el --- The session_info tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; `session_info' describes the current session to the model: its id,
;; name, model, directories, permission mode, status, usage, the plan
;; quota last reported to it, and its parent and children.

;;; Code:

(require 'harness-core)
(require 'harness-util)
(require 'harness-tools)

(defun harness-tools-session-info--window-text (window)
  "Describe the quota WINDOW plist in a few words."
  (let ((used (round (* 100 (or (plist-get window :used) 0))))
        (resets (plist-get window :resets)))
    (concat (format "%s %d%% used" (or (plist-get window :label) (plist-get window :name)) used)
            (if (numberp resets) (format-time-string " (resets %a %H:%M)" resets) ""))))

(defun harness-tools-session-info--quota-line (session-id)
  "Return a line with the plan quota last reported to SESSION-ID, or \"\"."
  (let ((windows (ignore-errors (harness-call 'session/runtime session-id :quota :get))))
    (if windows
        (format "Plan quota: %s\n" (mapconcat #'harness-tools-session-info--window-text windows "; "))
      "")))

(defun harness-tools-session-info--describe (_input ctx)
  "Handler of the session_info tool: describe the session in CTX."
  (let* ((sid (plist-get ctx :session-id))
         (s (harness-call 'session/get sid))
         (u (plist-get s :usage))
         (children (harness-call 'session/list (list :parent-id sid))))
    (harness-tool-ok
     (concat
      (format "Session: %s\nName: %s\nKind: %s\nModel: %s\nWorking directory: %s\nWorktree: %s\nTemporary directory: %s\nPermission mode: %s\nNon-interactive: %s\nStatus: %s\n"
              sid (or (plist-get s :name) "(unnamed)") (plist-get s :kind) (plist-get s :model)
              (plist-get s :cwd) (or (plist-get s :worktree) "none")
              (or (ignore-errors (harness-call 'session/tmp-dir sid)) "none")
              (plist-get s :permission-mode)
              (if (harness-json-true-p (plist-get s :non-interactive))
                  "on (the user is away: the auto-mode judge decides what would ask them for permission)"
                "off")
              (plist-get s :status))
      (format "Usage: %s input, %s output, %s cache read, cost %s, %d turns, context %s of %s\n"
              (harness-format-tokens (plist-get u :input)) (harness-format-tokens (plist-get u :output))
              (harness-format-tokens (plist-get u :cache-read)) (harness-format-spend u)
              (or (plist-get u :turns) 0) (harness-format-tokens (plist-get u :context))
              (harness-format-tokens (plist-get s :context-window)))
      (harness-tools-session-info--quota-line sid)
      (format "Parent: %s\n" (or (plist-get s :parent-id) "none"))
      (format "Children: %s"
              (if children
                  (mapconcat (lambda (c) (format "%s (%s, %s)" (plist-get c :id) (plist-get c :kind) (plist-get c :status)))
                             children ", ")
                "none"))))))

(harness-define-tool "session_info"
  :label "Session info"
  :description "Describe the current session: id, name, model, working directory, temporary directory, permission mode, non-interactive mode, status, usage and related sessions."
  :schema '(:type "object" :properties :empty)
  :kind 'read
  :coalescable t
  :subject #'ignore
  :handler #'harness-tools-session-info--describe)

(harness-define-module 'tools-session-info
  :doc "The Session info tool (session_info): the current session, described to the model."
  :requires '(tools session))

(provide 'harness-tools-session-info)
;;; harness-tools-session-info.el ends here
