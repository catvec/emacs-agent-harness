;;; harness-tools-session-info.el --- The session_info tool  -*- lexical-binding: t; -*-

;;; Commentary:

;; `session_info' describes the current session to the model: its id,
;; name, model, directories, permission mode, status, usage, the plan
;; quota last reported to it, and its parent and children.
;;
;; It describes the session's live access too, the state that
;; `request_escalation', `request_directory_access' and `drop_access'
;; change, so a model can see what it may reach before it asks for
;; more:
;;
;; - its effective permission mode and non-interactive state, marked
;;   when the policy sets either;
;; - whether it has the network, and whether it may write;
;; - the directories it may write, each with its source: the working
;;   directory, the worktree, the session's own temporary directory,
;;   `harness-allowed-directories' (allowed for every session), a
;;   grant to this session or until its turn ends, and the tool output
;;   directory;
;; - the directories it may only read: its read-only grants;
;; - the tools turned off for it;
;; - the Linux capabilities its bash and elisp commands are given;
;; - the standing allow and deny permission rules that apply to it,
;;   its own and those of every session, in the order they are
;;   weighed.
;;
;; The access is `access/describe' when the access module is loaded,
;; so it is the session's own live state and not a fresh session's
;; defaults.  Without that module it is made from `permission/rules',
;; `permission/dirs' and the session's access profile, and without the
;; permission module from the session record itself.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
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

;;; What the session may reach now

(defun harness-tools-session-info--profile (session)
  "Return SESSION's access profile, or nil.
The profile is the `:access' plist of the record's `:ext' (see
harness-access.el)."
  (let ((profile (plist-get (plist-get session :ext) :access)))
    (and (consp profile) (keywordp (car profile)) profile)))

(defun harness-tools-session-info--access-fallback (session-id session)
  "Return what SESSION-ID may reach from the permission methods and SESSION.
The fallback of `harness-tools-session-info--access' when the access
module is not loaded, or could not say."
  (let* ((rules (and (harness-method-exists-p 'permission/rules)
                     (harness-call 'permission/rules session-id)))
         (dirs (and (harness-method-exists-p 'permission/dirs)
                    (harness-call 'permission/dirs session-id)))
         (profile (harness-tools-session-info--profile session)))
    (list :mode (or (plist-get rules :mode) (plist-get session :permission-mode))
          :non-interactive (if rules
                               (harness-json-true-p (plist-get rules :non-interactive))
                             (harness-json-true-p (plist-get session :non-interactive)))
          :network (not (eq (plist-get profile :network) :false))
          :read-only (harness-json-true-p (plist-get profile :read-only))
          :dirs dirs
          :tools-off (plist-get profile :tools-off)
          :caps (plist-get profile :caps)
          :rules-session (plist-get rules :session)
          :rules-always (plist-get rules :always))))

(defun harness-tools-session-info--access (session-id session)
  "Return what SESSION-ID may reach now, as a plist for `session_info'.
It has `:mode', `:mode-pinned', `:non-interactive',
`:non-interactive-pinned', `:network', `:read-only', `:read-only-by',
`:dirs', `:tools-off', `:caps', `:caps-enforced', `:rules-session',
`:rules-always' and `:rules-pinned'.

`access/describe' answers when the access module is loaded; otherwise
`permission/rules' and `permission/dirs' do, with SESSION's access
profile, and without those the session record itself."
  (if (harness-method-exists-p 'access/describe)
      (condition-case err
          (let* ((described (harness-call 'access/describe session-id))
                 (caps (plist-get described :capabilities))
                 (rules (plist-get described :rules))
                 (profile (plist-get described :profile)))
            (list :mode (plist-get described :mode)
                  :mode-pinned (harness-json-true-p (plist-get described :mode-pinned))
                  :non-interactive (harness-json-true-p (plist-get described :non-interactive))
                  :non-interactive-pinned
                  (harness-json-true-p (plist-get described :non-interactive-pinned))
                  :network (harness-json-true-p (plist-get described :network))
                  :read-only (harness-json-true-p (plist-get described :read-only))
                  :read-only-by (plist-get described :read-only-by)
                  :dirs (plist-get described :dirs)
                  :tools-off (plist-get profile :tools-off)
                  :caps (plist-get caps :held)
                  :caps-enforced (harness-json-true-p (plist-get caps :enforced))
                  :rules-session (plist-get rules :session)
                  :rules-always (plist-get rules :always)
                  :rules-pinned (harness-json-true-p (plist-get rules :pinned))))
        (error
         (harness-log 'warn "session_info: access/describe failed, asking the permission methods: %s"
                      (harness-error-message err))
         (harness-tools-session-info--access-fallback session-id session)))
    (harness-tools-session-info--access-fallback session-id session)))

(defun harness-tools-session-info--source-text (source)
  "Return how a directory SOURCE reads in the access report."
  (pcase source
    ('cwd "the working directory")
    ('worktree "the worktree")
    ('tmp "this session's own temporary directory")
    ('config "allowed for every session")
    ('session "granted to this session")
    ('turn "granted to this session until this turn ends")
    ('outputs "the tool output directory")
    ('read "may only be read")
    ('dropped "given up")
    (_ (format "%s" source))))

(defun harness-tools-session-info--dir-lines (dirs writable)
  "Return the lines for DIRS in the access report.
WRITABLE non-nil lists the directories that may be written, else those
that may only be read.  Each entry is a line with its source; an empty
list is \"none\" on a line of its own."
  (let* ((shown (cl-remove-if-not
                 (lambda (entry)
                   (if writable
                       (and (not (harness-json-true-p (plist-get entry :read-only)))
                            (not (plist-get entry :dropped)))
                     (harness-json-true-p (plist-get entry :read-only))))
                 dirs))
         (lines (mapcar
                 (lambda (entry)
                   (format "    %s (%s)"
                           (harness-abbreviate-file-name (or (plist-get entry :dir) ""))
                           (harness-tools-session-info--source-text
                            (plist-get entry :source))))
                 shown)))
    (if lines (string-join lines "\n") "    none")))

(defun harness-tools-session-info--names-text (names)
  "Return NAMES as one comma-separated line, or \"none\"."
  (if names (string-join (mapcar (lambda (name) (format "%s" name)) names) ", ") "none"))

(defun harness-tools-session-info--rule-text (rule)
  "Return RULE, a permission rule, as one line."
  (let ((behavior (or (plist-get rule :behavior) 'allow))
        (subject (condition-case nil
                     (if (fboundp 'harness-perms--rule-subject)
                         (harness-perms--rule-subject rule)
                       (or (plist-get rule :tool) "a call"))
                   (error (or (plist-get rule :tool) "a call")))))
    (format "%s %s" behavior subject)))

(defun harness-tools-session-info--rules-lines (access)
  "Return the lines for the standing rules of ACCESS.
The rules of every session come first when the policy sets them, since
the permission chain weighs them first then; otherwise this session's
rules come first."
  (let* ((session (plist-get access :rules-session))
         (always (plist-get access :rules-always))
         (pinned (plist-get access :rules-pinned))
         (groups (if pinned
                     (list (cons "every session (set by policy)" always)
                           (cons "this session" session))
                   (list (cons "this session" session)
                         (cons "every session" always))))
         (lines (cl-loop for (label . rules) in groups
                         append (mapcar
                                 (lambda (rule)
                                   (format "    %s: %s" label
                                           (harness-tools-session-info--rule-text rule)))
                                 rules))))
    (if lines
        (concat (string-join lines "\n")
                (if (and pinned always)
                    "\n    (the every-session rules are set by policy and are tried first)"
                  ""))
      "    none (no standing allow or deny rule applies)")))

(defun harness-tools-session-info--access-text (access)
  "Return the access section of `session_info' for ACCESS."
  (let ((read-only-by (plist-get access :read-only-by))
        (caps (plist-get access :caps))
        (caps-enforced (plist-get access :caps-enforced)))
    (concat
     "Access:\n"
     (format "  Network: %s\n" (if (plist-get access :network) "on" "off"))
     (format "  Writing: %s\n"
             (cond ((not (plist-get access :read-only)) "on")
                   (read-only-by (format "off (read-only: %s)" read-only-by))
                   (t "off (this session is read-only)")))
     (format "  Writable directories:\n%s\n"
             (harness-tools-session-info--dir-lines (plist-get access :dirs) t))
     (format "  Read-only directories:\n%s\n"
             (harness-tools-session-info--dir-lines (plist-get access :dirs) nil))
     (format "  Tools turned off: %s\n"
             (harness-tools-session-info--names-text (plist-get access :tools-off)))
     (format "  Linux capabilities (bash and elisp): %s%s\n"
             (harness-tools-session-info--names-text caps)
             (if (and caps (not caps-enforced)) " (not enforced by the sandbox)" ""))
     (format "  Standing rules:\n%s\n"
             (harness-tools-session-info--rules-lines access)))))

(defun harness-tools-session-info--describe (_input ctx)
  "Handler of the session_info tool: describe the session in CTX."
  (let* ((sid (plist-get ctx :session-id))
         (s (harness-call 'session/get sid))
         (u (plist-get s :usage))
         (children (harness-call 'session/list (list :parent-id sid)))
         (access (harness-tools-session-info--access sid s)))
    (harness-tool-ok
     (concat
      (format "Session: %s\nName: %s\nKind: %s\nModel: %s\nWorking directory: %s\nWorktree: %s\nTemporary directory: %s\nPermission mode: %s%s\nNon-interactive: %s%s\nStatus: %s\n"
              sid (or (plist-get s :name) "(unnamed)") (plist-get s :kind) (plist-get s :model)
              (plist-get s :cwd) (or (plist-get s :worktree) "none")
              (or (ignore-errors (harness-call 'session/tmp-dir sid)) "none")
              (or (plist-get access :mode) (plist-get s :permission-mode) 'ask)
              (if (plist-get access :mode-pinned) " (set by policy)" "")
              (if (plist-get access :non-interactive)
                  "on (the user is away: the auto-mode judge decides what would ask them for permission)"
                "off")
              (if (plist-get access :non-interactive-pinned) " (set by policy)" "")
              (plist-get s :status))
      (harness-tools-session-info--access-text access)
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
  :description "Describe the current session and its live access. The session part gives its id, name, kind, model, working directory, worktree, temporary directory, effective permission mode, non-interactive mode (each marked when a policy sets it), status, usage, plan quota, parent and children. The access part has these fields: Network, whether the session may reach the network; Writing, whether it may write, and why not when it is read-only; Writable directories, each with its source -- the working directory, the worktree, this session's own temporary directory, allowed for every session (harness-allowed-directories), granted to this session, granted to this session until this turn ends, or the tool output directory; Read-only directories, directories it may read but not write; Tools turned off, the tools the user or drop_access turned off for it; Linux capabilities (bash and elisp), the Linux capabilities its bash and elisp commands are given, with a note when the sandbox does not enforce them; and Standing rules, the allow and deny permission rules that apply to it, for this session and for every session, in the order they are weighed, with every-session rules first when a policy sets them. It reads the session's live state, not a fresh session's defaults, so what request_escalation, request_directory_access and drop_access change is visible here."
  :schema '(:type "object" :properties :empty)
  :kind 'read
  :coalescable t
  :subject #'ignore
  :handler #'harness-tools-session-info--describe)

(harness-define-module 'tools-session-info
  :doc "The Session info tool (session_info): the current session and its live access, described to the model."
  :requires '(tools session))

(provide 'harness-tools-session-info)
;;; harness-tools-session-info.el ends here
