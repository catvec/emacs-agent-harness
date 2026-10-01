;;; harness-ui.el --- UI foundation: connection, faces, positions, menu  -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything the presentation layer shares.  The UI never touches a
;; session struct: it holds one ACP connection (in-process by default,
;; a TCP client after `harness-connect-remote') and renders what the
;; connection tells it.  This file provides:
;;
;; - the connection and request helpers, plus the dispatch of incoming
;;   notifications and agent→client requests to hooks other UI modules
;;   join;
;; - a cache of session plists kept fresh from `_harness/session' updates;
;; - faces and icons;
;; - window positions: one session per preset position, replacing;
;; - the prefix keymap, the global minor mode and the transient menu.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'icons)
(require 'transient)
(require 'harness-core)
(require 'harness-util)
(require 'harness-acp)

(declare-function harness-reload "harness")

(defgroup harness-ui nil
  "Presentation layer of the Emacs agent harness."
  :group 'harness :prefix "harness-ui-")

;;;; Faces

(defface harness-user-face
  '((((background light)) :background "#e9edf5" :extend t)
    (((background dark)) :background "#2c313c" :extend t))
  "Background of messages written by the user." :group 'harness-ui)

(defface harness-agent-face '((t :inherit default))
  "Face of the agent's text." :group 'harness-ui)

(defface harness-tool-face
  '((((background light)) :background "#eaf3ea" :extend t)
    (((background dark)) :background "#26302a" :extend t))
  "Background of tool call blocks." :group 'harness-ui)

(defface harness-tool-error-face
  '((((background light)) :background "#f7e9e9" :extend t)
    (((background dark)) :background "#3a2a2a" :extend t))
  "Background of failed tool call blocks." :group 'harness-ui)

(defface harness-tool-title-face '((t :inherit (font-lock-function-name-face bold)))
  "Face of a tool call's title." :group 'harness-ui)

(defface harness-thinking-face '((t :inherit shadow :slant italic))
  "Face of thinking text." :group 'harness-ui)

(defface harness-hint-face '((t :inherit font-lock-comment-face :slant italic :height 0.9))
  "Face of harness hints." :group 'harness-ui)

(defface harness-summary-face '((t :inherit shadow :height 0.9))
  "Face of coalesced tool summaries." :group 'harness-ui)

(defface harness-dim-face '((t :inherit shadow))
  "Secondary information." :group 'harness-ui)

(defface harness-label-face '((t :inherit bold :height 0.9))
  "Small labels such as the sender name." :group 'harness-ui)

(defface harness-status-idle-face '((t :inherit success))
  "Idle sessions." :group 'harness-ui)
(defface harness-status-running-face '((t :inherit warning))
  "Running sessions." :group 'harness-ui)
(defface harness-status-blocked-face '((t :inherit error :weight bold))
  "Blocked sessions waiting for the user." :group 'harness-ui)
(defface harness-status-inactive-face '((t :inherit shadow))
  "Inactive sessions." :group 'harness-ui)

(defface harness-context-ok-face '((t :inherit default))
  "Context usage comfortably below the limit." :group 'harness-ui)
(defface harness-context-warning-face '((t :inherit warning))
  "Context usage past 70% of the compaction limit." :group 'harness-ui)
(defface harness-context-urgent-face '((t :foreground "#e8590c" :weight bold))
  "Context usage past 85% of the compaction limit." :group 'harness-ui)
(defface harness-context-critical-face '((t :inherit error :weight bold :inverse-video t))
  "Context usage past 95% of the compaction limit." :group 'harness-ui)

(defface harness-queue-face
  '((((background light)) :background "#fbf4dd" :extend t)
    (((background dark)) :background "#3a3524" :extend t))
  "Queued messages." :group 'harness-ui)

(defface harness-compose-face
  '((((background light)) :background "#ffffff" :extend t)
    (((background dark)) :background "#1e2127" :extend t))
  "The message composition area." :group 'harness-ui)

(defface harness-header-face '((t :inherit header-line))
  "Session header line." :group 'harness-ui)

;;;; Icons

(define-icon harness-icon-idle nil
  '((emoji "●") (symbol "●") (text "idle"))
  "Idle session." :version "29.1")
(define-icon harness-icon-running nil
  '((emoji "▶") (symbol "▶") (text "run"))
  "Running session." :version "29.1")
(define-icon harness-icon-blocked nil
  '((emoji "⏸") (symbol "⏸") (text "wait"))
  "Blocked session." :version "29.1")
(define-icon harness-icon-inactive nil
  '((emoji "○") (symbol "○") (text "off"))
  "Inactive session." :version "29.1")
(define-icon harness-icon-user nil
  '((emoji "👤") (symbol "◆") (text "you"))
  "The user." :version "29.1")
(define-icon harness-icon-agent nil
  '((emoji "🤖") (symbol "◇") (text "agent"))
  "The agent." :version "29.1")
(define-icon harness-icon-tool nil
  '((emoji "🔧") (symbol "⚙") (text "tool"))
  "A tool call." :version "29.1")
(define-icon harness-icon-thinking nil
  '((emoji "💭") (symbol "…") (text "think"))
  "Thinking." :version "29.1")
(define-icon harness-icon-collapsed nil
  '((symbol "▸") (text "+"))
  "Collapsed block." :version "29.1")
(define-icon harness-icon-expanded nil
  '((symbol "▾") (text "-"))
  "Expanded block." :version "29.1")
(define-icon harness-icon-send nil
  '((emoji "➤") (symbol "➤") (text "send"))
  "Send." :version "29.1")
(define-icon harness-icon-attach nil
  '((emoji "📎") (symbol "@") (text "attach"))
  "Attachment." :version "29.1")

(defun harness-ui-icon (name)
  "Return the string for icon NAME (a symbol such as `harness-icon-idle')."
  (condition-case nil (icon-string name) (error "")))

(defun harness-ui-status-icon (status)
  "Return the icon string for session STATUS (symbol or string), with face."
  (let ((status (if (stringp status) (intern status) status)))
    (pcase status
      ('running (propertize (harness-ui-icon 'harness-icon-running) 'face 'harness-status-running-face))
      ('blocked (propertize (harness-ui-icon 'harness-icon-blocked) 'face 'harness-status-blocked-face))
      ('inactive (propertize (harness-ui-icon 'harness-icon-inactive) 'face 'harness-status-inactive-face))
      (_ (propertize (harness-ui-icon 'harness-icon-idle) 'face 'harness-status-idle-face)))))

(defun harness-ui-status-face (status)
  "Return the face for STATUS."
  (pcase (if (stringp status) (intern status) status)
    ('running 'harness-status-running-face)
    ('blocked 'harness-status-blocked-face)
    ('inactive 'harness-status-inactive-face)
    (_ 'harness-status-idle-face)))

;;;; Connection

(defvar harness-ui-connection nil "The ACP connection the UI talks through.")
(defvar harness-ui-connection-address nil "Address of the current connection, nil when local.")

(defvar harness-ui-update-functions nil
  "Functions called with (SESSION-ID UPDATE) for every `session/update'.
UPDATE is the wire plist; its `:sessionUpdate' names the kind.")

(defvar harness-ui-event-functions nil
  "Functions called with (EVENT ARGS) for every `_harness/event' notification.
EVENT is a string such as \"agent/turn-ended\".")

(defvar harness-ui-permission-functions nil
  "Functions called with (PARAMS RESPOND) for `session/request_permission'.
The first function that returns non-nil owns the request and must call
RESPOND with the outcome plist.")

(defvar harness-ui-question-functions nil
  "Functions called with (PARAMS RESPOND) for `_harness/ask_user'.
Same protocol as `harness-ui-permission-functions'.")

(defvar harness-ui-sessions-changed-hook nil
  "Hook run after the session cache changes.")

(defvar harness-ui-redraw-hook nil
  "Hook run when every UI buffer should redraw (after a reload or reconnect).")

(defun harness-ui-connected-p ()
  "Non-nil when the UI has a live connection."
  (and harness-ui-connection (harness-acp-connected-p harness-ui-connection)))

(defun harness-ui-connect (&optional address)
  "Connect the UI to ADDRESS (nil for the in-process harness).
Return the connection."
  (when harness-ui-connection (ignore-errors (harness-acp-close harness-ui-connection)))
  (setq harness-ui-connection (harness-acp-connect address)
        harness-ui-connection-address address)
  (harness-acp-set-handler harness-ui-connection #'harness-ui--dispatch)
  (harness-acp-on-close harness-ui-connection #'harness-ui--on-close)
  (harness-then (harness-acp-initialize harness-ui-connection)
                (lambda (_) (harness-ui-refresh-sessions))
                (lambda (e) (message "Harness: initialize failed: %s" (harness-error-message e))))
  harness-ui-connection)

(defun harness-ui-connection ()
  "Return the live connection, connecting locally if needed."
  (if (harness-ui-connected-p) harness-ui-connection (harness-ui-connect harness-ui-connection-address)))

(defun harness-ui--on-close ()
  (message "Harness: connection closed%s"
           (if harness-ui-connection-address (format " (%s)" harness-ui-connection-address) "")))

(defun harness-ui-request (method &optional params)
  "Send METHOD with PARAMS over the UI connection; return a promise."
  (harness-acp-request (harness-ui-connection) method params))

(defun harness-ui-call (method params callback &optional on-error)
  "Request METHOD with PARAMS and call CALLBACK with the result.
Errors are shown in the echo area unless ON-ERROR handles them."
  (harness-then (harness-ui-request method params)
                callback
                (or on-error
                    (lambda (e) (message "Harness: %s failed: %s" method (harness-error-message e)) nil))))

(defun harness-ui-notify (method &optional params)
  "Send notification METHOD with PARAMS."
  (harness-acp-notify (harness-ui-connection) method params))

(defun harness-ui--dispatch (method params respond)
  "Route an incoming METHOD with PARAMS; RESPOND is non-nil for requests."
  (pcase method
    ("session/update"
     (let ((sid (plist-get params :sessionId))
           (update (plist-get params :update)))
       (pcase (plist-get update :sessionUpdate)
         ("_harness/session" (harness-ui--cache-session (plist-get update :session)))
         ("_harness/session_deleted" (harness-ui--forget-session sid)))
       (run-hook-with-args 'harness-ui-update-functions sid update)))
    ("session/request_permission"
     (unless (run-hook-with-args-until-success 'harness-ui-permission-functions params respond)
       (harness-ui--default-permission params respond)))
    ("_harness/ask_user"
     (unless (run-hook-with-args-until-success 'harness-ui-question-functions params respond)
       (harness-ui--default-question params respond)))
    ("_harness/event"
     (let ((event (plist-get params :event)) (args (plist-get params :args)))
       (when (member event '("session/created" "session/deleted"))
         (harness-ui-refresh-sessions))
       (when (equal event "harness/reloaded")
         (run-hooks 'harness-ui-redraw-hook))
       (run-hook-with-args 'harness-ui-event-functions event args)))
    (_ (when respond (harness-acp-respond-error respond -32601 (format "unhandled %s" method))))))

(defun harness-ui--default-permission (params respond)
  "Fallback permission prompt in the minibuffer when no UI module claimed it."
  (let* ((tc (plist-get params :toolCall))
         (choice (read-multiple-choice
                  (format "Allow %s?" (or (plist-get tc :title) "tool"))
                  '((?y "allow once") (?s "allow for session") (?a "always allow")
                    (?n "deny") (?N "always deny")))))
    (funcall respond
             (list :outcome (list :outcome "selected"
                                  :optionId (pcase (car choice)
                                              (?y "allow-once") (?s "allow-session") (?a "allow-always")
                                              (?N "deny-always") (_ "deny-once")))))
    t))

(defun harness-ui--default-question (params respond)
  (let* ((options (plist-get params :options))
         (answer (if options
                     (completing-read (concat (plist-get params :question) " ") options nil nil)
                   (read-string (concat (plist-get params :question) " ")))))
    (funcall respond (list :answer answer))
    t))

;;;###autoload
(defun harness-connect-remote (address)
  "Connect the UI to a harness ACP server at ADDRESS (\"host:port\")."
  (interactive (list (read-string "Harness server (host:port): " harness-ui-connection-address)))
  (harness-ui-connect (unless (string-empty-p address) address))
  (run-hooks 'harness-ui-redraw-hook)
  (message "Harness: connected to %s" (or address "local harness")))

;;;; Session cache

(defvar harness-ui--sessions (make-hash-table :test 'equal)
  "Session id -> latest session plist (wire shape).")

(defun harness-ui-cache-session (session)
  "Record SESSION (a wire plist) in the cache and notify listeners."
  (when-let* ((id (plist-get session :id)))
    (puthash id session harness-ui--sessions)
    (run-hooks 'harness-ui-sessions-changed-hook)))

(defalias 'harness-ui--cache-session #'harness-ui-cache-session)

(defun harness-ui--forget-session (id)
  (remhash id harness-ui--sessions)
  (run-hooks 'harness-ui-sessions-changed-hook))

(defun harness-ui-session (id)
  "Return the cached session plist for ID."
  (gethash id harness-ui--sessions))

(defun harness-ui-sessions (&optional predicate)
  "Return cached sessions, newest first, filtered by PREDICATE when given."
  (let (out)
    (maphash (lambda (_ s) (when (or (null predicate) (funcall predicate s)) (push s out))) harness-ui--sessions)
    (sort out (lambda (a b) (> (or (plist-get a :updated) 0) (or (plist-get b :updated) 0))))))

(defun harness-ui-refresh-sessions (&optional callback)
  "Reload the session cache from the harness, then call CALLBACK."
  (harness-ui-call "_harness/session/list" nil
                   (lambda (sessions)
                     (clrhash harness-ui--sessions)
                     (dolist (s sessions) (puthash (plist-get s :id) s harness-ui--sessions))
                     (run-hooks 'harness-ui-sessions-changed-hook)
                     (when callback (funcall callback sessions)))))

(defun harness-ui-session-label (session)
  "Return a one-line label for SESSION."
  (let ((name (plist-get session :name)))
    (format "%s %s" (harness-ui-status-icon (plist-get session :status))
            (or (and name (not (string-empty-p name)) name)
                (format "unnamed (%s)" (substring (or (plist-get session :id) "????") 0 4))))))

;;;; Buffer-local session context

(defvar-local harness-ui-session-id nil
  "Id of the session this buffer shows, when any.")

(defun harness-ui-current-session-id (&optional noerror)
  "Return the session id of the current buffer, or prompt for one.
Signal unless NOERROR when none can be found."
  (or harness-ui-session-id
      (let ((sessions (harness-ui-sessions)))
        (cond ((null sessions) (unless noerror (user-error "No sessions yet; create one with `harness-new-session'")))
              (t (plist-get (harness-ui-read-session "Session: ") :id))))))

(defun harness-ui-read-session (prompt &optional predicate)
  "Read a session with completion showing PROMPT; PREDICATE filters."
  (let* ((sessions (harness-ui-sessions predicate))
         (table (mapcar (lambda (s) (cons (format "%s  %s  %s" (harness-ui-session-label s)
                                                  (propertize (or (plist-get s :model) "") 'face 'harness-dim-face)
                                                  (propertize (abbreviate-file-name (or (plist-get s :project) "")) 'face 'harness-dim-face))
                                          s))
                        sessions))
         (choice (completing-read prompt table nil t)))
    (cdr (assoc choice table))))

;;;; Formatting

(defun harness-ui-context-face (context window)
  "Return the warning face for CONTEXT tokens against WINDOW."
  (let* ((reserve (if (boundp 'harness-context-reserve) harness-context-reserve 20000))
         (limit (max 1 (- (or window 128000) reserve)))
         (f (/ (float (or context 0)) limit)))
    (cond ((>= f 0.95) 'harness-context-critical-face)
          ((>= f 0.85) 'harness-context-urgent-face)
          ((>= f 0.70) 'harness-context-warning-face)
          (t 'harness-context-ok-face))))

(defun harness-ui-format-context (session)
  "Return \"12.3k/200k\" for SESSION with the warning face applied."
  (let* ((usage (plist-get session :usage))
         (context (or (plist-get usage :context) 0))
         (window (plist-get session :context-window)))
    (propertize (format "%s/%s" (harness-format-tokens context) (harness-format-tokens window))
                'face (harness-ui-context-face context window)
                'help-echo "Context tokens in use / context window")))

(defun harness-ui-model-label (model-id)
  "Return a short label for MODEL-ID, keeping the provider as a prefix."
  (if (and model-id (string-match "\\`\\([^:]+\\):\\(.+\\)\\'" model-id))
      (format "%s · %s" (match-string 1 model-id) (match-string 2 model-id))
    (or model-id "?")))

(defun harness-ui-button (label action &rest props)
  "Insert a clickable LABEL running ACTION (a command or a function of the button).
PROPS are extra text properties; `:help' sets the tooltip."
  (let ((help (plist-get props :help))
        (face (or (plist-get props :face) 'button)))
    (insert-text-button label
                        'action (lambda (_b) (if (commandp action) (call-interactively action) (funcall action)))
                        'follow-link t 'face face
                        'help-echo help
                        'mouse-face 'highlight)))

(defun harness-ui-mouse-keymap (command)
  "Return a keymap running COMMAND on mouse-1, mouse-2 and RET.
The bindings also work from header-line and mode-line segments."
  (let ((map (make-sparse-keymap))
        (run (lambda (&optional event)
               (interactive "e")
               (when (and event (mouse-event-p event))
                 (ignore-errors (select-window (posn-window (event-start event)))))
               (call-interactively command))))
    (dolist (key '([mouse-1] [mouse-2] [header-line mouse-1] [header-line mouse-2]
                   [mode-line mouse-1] [mode-line mouse-2]))
      (define-key map key run))
    (define-key map (kbd "RET") run)
    map))

;;;; Positions

(defcustom harness-ui-positions
  '((right . ((side . right) (slot . 0) (window-width . 0.45)))
    (left . ((side . left) (slot . 0) (window-width . 0.45)))
    (bottom . ((side . bottom) (slot . 0) (window-height . 0.45)))
    (full . nil)
    (other . nil))
  "Named positions a session can be displayed in.
Side-window positions carry `display-buffer-in-side-window' parameters;
`full' takes over the selected window; `other' pops up anywhere."
  :type '(alist :key-type symbol :value-type sexp) :group 'harness-ui)

(defcustom harness-ui-default-position 'right
  "Position used when a session is opened without an explicit one."
  :type 'symbol :group 'harness-ui)

(defvar harness-ui--position-buffers (make-hash-table :test 'eq)
  "Position -> buffer currently shown there.")

(defvar harness-ui-open-session-function nil
  "Function returning the buffer that shows session ID: (ID) → buffer.
Set by the chat module.")

(defun harness-ui-display-buffer (buffer &optional position)
  "Show BUFFER in POSITION, replacing whatever session occupied it."
  (let* ((position (or position harness-ui-default-position))
         (params (alist-get position harness-ui-positions))
         (previous (gethash position harness-ui--position-buffers))
         (window (and previous (buffer-live-p previous) (get-buffer-window previous))))
    (puthash position buffer harness-ui--position-buffers)
    (cond
     ((and window (window-live-p window) (not (eq previous buffer)))
      (set-window-buffer window buffer)
      (select-window window))
     ((eq position 'full) (switch-to-buffer buffer))
     ((eq position 'other) (pop-to-buffer buffer))
     (params
      (select-window (display-buffer-in-side-window buffer params)))
     (t (pop-to-buffer buffer)))
    (with-current-buffer buffer (setq-local harness-ui-position position))
    buffer))

(defvar-local harness-ui-position nil "Position this buffer was displayed in.")

(defun harness-ui-display-session (id &optional position)
  "Display session ID in POSITION using `harness-ui-open-session-function'."
  (unless harness-ui-open-session-function
    (user-error "No chat module loaded"))
  (harness-ui-display-buffer (funcall harness-ui-open-session-function id) position))

(defun harness-ui-read-position ()
  "Read a position name with completion."
  (intern (completing-read "Position: " (mapcar (lambda (p) (symbol-name (car p))) harness-ui-positions) nil t)))

;;;; Commands

(defun harness-ui--default-directory ()
  (if (harness-method-exists-p 'project/root)
      (harness-call 'project/root default-directory)
    default-directory))

;;;###autoload
(defun harness-new-session (directory &optional position)
  "Start a new session in DIRECTORY and show it in POSITION."
  (interactive (list (read-directory-name "Session directory: " (harness-ui--default-directory) nil t)
                     (and current-prefix-arg (harness-ui-read-position))))
  (harness-ui-call "session/new" (list :cwd (expand-file-name directory))
                   (lambda (result)
                     (harness-ui-refresh-sessions
                      (lambda (_) (harness-ui-display-session (plist-get result :sessionId) position))))))

;;;###autoload
(defun harness-switch-session (&optional position)
  "Switch to another session, replacing the one in POSITION."
  (interactive (list (and current-prefix-arg (harness-ui-read-position))))
  (harness-ui-refresh-sessions
   (lambda (_)
     (let ((s (harness-ui-read-session "Switch to session: ")))
       (harness-ui-call "_harness/session/resume" (list :id (plist-get s :id))
                        (lambda (_) (harness-ui-display-session (plist-get s :id) position)))))))

;;;###autoload
(defun harness-set-model (&optional session-id)
  "Choose a model for SESSION-ID (default the current buffer's session)."
  (interactive)
  (let ((sid (or session-id (harness-ui-current-session-id))))
    (harness-ui-call "_harness/provider/models" nil
                     (lambda (models)
                       (let* ((table (mapcar (lambda (m)
                                               (cons (plist-get m :id) m))
                                             models))
                              (completion-extra-properties
                               (list :annotation-function
                                     (lambda (id)
                                       (let ((m (cdr (assoc id table))))
                                         (format "  %s · %s · %s ctx%s"
                                                 (or (plist-get m :provider-label) (plist-get m :provider))
                                                 (plist-get m :label)
                                                 (harness-format-tokens (plist-get m :context-window))
                                                 (if-let* ((p (plist-get m :pricing)))
                                                     (format " · $%s/$%s per M" (plist-get p :input) (plist-get p :output))
                                                   ""))))))
                              (choice (completing-read "Model: " table nil t)))
                         (harness-ui-call "session/set_model" (list :sessionId sid :modelId choice)
                                          (lambda (_) (message "Model → %s" choice))))))))

;;;###autoload
(defun harness-set-thinking (&optional session-id)
  "Choose a thinking level for SESSION-ID."
  (interactive)
  (let* ((sid (or session-id (harness-ui-current-session-id)))
         (session (harness-ui-session sid)))
    (harness-ui-call "_harness/provider/model" (list :model-id (plist-get session :model))
                     (lambda (model)
                       (let* ((levels (or (plist-get model :thinking-levels) '("low" "medium" "high")))
                              ;; Keep the provider's lowest-to-highest order; completion UIs sort plain lists.
                              (table (let ((options (cons "default" levels)))
                                       (lambda (string pred action)
                                         (if (eq action 'metadata)
                                             '(metadata (display-sort-function . identity)
                                                        (cycle-sort-function . identity))
                                           (complete-with-action action options string pred)))))
                              (choice (completing-read "Thinking: " table nil t)))
                         (harness-ui-call "_harness/session/update"
                                          (list :id sid :thinking (unless (equal choice "default") choice))
                                          (lambda (_) (message "Thinking → %s" choice))))))))

;;;###autoload
(defun harness-set-permission-mode (&optional session-id)
  "Choose the permission mode for SESSION-ID."
  (interactive)
  (let* ((sid (or session-id (harness-ui-current-session-id)))
         (choice (read-multiple-choice "Permission mode"
                                       '((?a "ask" "Ask before writes, commands and network")
                                         (?e "accept-edits" "Reads and edits inside the project run freely")
                                         (?u "auto" "A cheap model judges each call")
                                         (?y "yolo" "Allow everything inside the jail")))))
    (harness-ui-call "session/set_mode" (list :sessionId sid :modeId (cadr choice))
                     (lambda (_) (message "Permission mode → %s" (cadr choice))))))

;;;###autoload
(defun harness-toggle-non-interactive (&optional session-id)
  "Toggle non-interactive mode for SESSION-ID."
  (interactive)
  (let* ((sid (or session-id (harness-ui-current-session-id)))
         (now (harness-json-true-p (plist-get (harness-ui-session sid) :non-interactive))))
    (harness-ui-call "_harness/session/update" (list :id sid :non-interactive (if now :false t))
                     (lambda (_) (message "Non-interactive %s" (if now "off" "on"))))))

;;;###autoload
(defun harness-rename-session (name &optional session-id)
  "Rename SESSION-ID to NAME."
  (interactive (list (read-string "Session name: ")))
  (harness-ui-call "_harness/session/update" (list :id (or session-id (harness-ui-current-session-id)) :name name)
                   (lambda (_) (message "Renamed to %s" name))))

;;;###autoload
(defun harness-fork-session (&optional session-id position)
  "Fork SESSION-ID (default the current session) and open the fork in POSITION."
  (interactive (list nil (and current-prefix-arg (harness-ui-read-position))))
  (let ((sid (or session-id (harness-ui-current-session-id))))
    (harness-ui-call "_harness/session/fork" (list :id sid :kind "fork")
                     (lambda (child)
                       (harness-ui-refresh-sessions
                        (lambda (_)
                          (harness-ui-display-session (plist-get child :id) (or position harness-ui-position))
                          (message "Forked session %s" (substring (plist-get child :id) 0 8))))))))

;;;###autoload
(defun harness-delete-session (&optional session-id)
  "Delete SESSION-ID after confirmation."
  (interactive)
  (let* ((sid (or session-id (harness-ui-current-session-id)))
         (s (harness-ui-session sid)))
    (when (yes-or-no-p (format "Delete session %s? " (or (plist-get s :name) (substring sid 0 8))))
      (harness-ui-call "_harness/session/delete" (list :id sid)
                       (lambda (_)
                         (harness-ui--forget-session sid)
                         (message "Session deleted"))))))

;;;###autoload
(defun harness-cancel-turn (&optional session-id)
  "Cancel the running turn of SESSION-ID."
  (interactive)
  (harness-ui-notify "session/cancel" (list :sessionId (or session-id (harness-ui-current-session-id))))
  (message "Cancelling…"))

;;;###autoload
(defun harness-show-log ()
  "Show the harness log buffer."
  (interactive)
  (pop-to-buffer harness-log-buffer-name))

;;;; Keymap, menu, global mode

(defvar harness-ui-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'harness-new-session)
    (define-key map (kbd "s") #'harness-switch-session)
    (define-key map (kbd "m") #'harness-set-model)
    (define-key map (kbd "T") #'harness-set-thinking)
    (define-key map (kbd "p") #'harness-set-permission-mode)
    (define-key map (kbd "f") #'harness-fork-session)
    (define-key map (kbd "k") #'harness-cancel-turn)
    (define-key map (kbd "D") #'harness-delete-session)
    (define-key map (kbd "c") #'harness-connect-remote)
    (define-key map (kbd "R") #'harness-reload)
    (define-key map (kbd "L") #'harness-show-log)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Prefix keymap of the harness UI.  Other UI modules add their commands.")

(defcustom harness-ui-prefix-key "C-c a"
  "Prefix key for `harness-ui-map' in `harness-global-mode'."
  :type 'key-sequence :group 'harness-ui)

(defvar harness-global-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd harness-ui-prefix-key) harness-ui-map)
    map))

;;;###autoload
(define-minor-mode harness-global-mode
  "Global keybindings for the agent harness."
  :global t :group 'harness-ui :keymap harness-global-mode-map)

(defun harness-ui--command-available-p (symbol)
  (fboundp symbol))

(transient-define-prefix harness-menu ()
  "The harness menu."
  [["Sessions"
    ("n" "New session" harness-new-session)
    ("s" "Switch session" harness-switch-session)
    ("l" "Session list" harness-sessions :if (lambda () (harness-ui--command-available-p 'harness-sessions)))
    ("t" "Conversation tree" harness-tree :if (lambda () (harness-ui--command-available-p 'harness-tree)))
    ("b" "BTW side conversation" harness-btw :if (lambda () (harness-ui--command-available-p 'harness-btw)))
    ("f" "Fork session" harness-fork-session)
    ("k" "Cancel turn" harness-cancel-turn)
    ("D" "Delete session" harness-delete-session)]
   ["Session settings"
    ("m" "Model" harness-set-model)
    ("T" "Thinking" harness-set-thinking)
    ("p" "Permission mode" harness-set-permission-mode)
    ("i" "Non-interactive" harness-toggle-non-interactive)
    ("r" "Rename" harness-rename-session)]
   ["Tools"
    ("u" "Usage & cost" harness-usage :if (lambda () (harness-ui--command-available-p 'harness-usage)))
    ("w" "Worktrees" harness-worktrees :if (lambda () (harness-ui--command-available-p 'harness-worktrees)))
    ("c" "Connect remote" harness-connect-remote)
    ("R" "Reload harness" harness-reload)
    ("L" "Log" harness-show-log)]])

;;;; Module

(defun harness-ui--on-reloaded ()
  (run-hooks 'harness-ui-redraw-hook))

(defun harness-ui--init ()
  (harness-ui-connect harness-ui-connection-address)
  ;; A reload reaches the UI as the forwarded `harness/reloaded' event, for
  ;; local and remote harnesses alike, so no bus subscription is needed.
  (harness-global-mode 1))

(harness-define-module 'ui
  :doc "UI foundation: ACP connection, faces, positions, keymap and menu."
  :requires '(acp)
  :init #'harness-ui--init)

(provide 'harness-ui)
;;; harness-ui.el ends here
