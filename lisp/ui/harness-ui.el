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
(require 'harness-server)
(require 'harness-client-tools)
(require 'harness-files)

(defvar harness-directory)

(declare-function harness-reload "harness")

(defgroup harness-ui nil
  "Presentation layer of the Emacs agent harness."
  :group 'harness :prefix "harness-ui-")

;;;; Faces

(defface harness-user-face
  '((((background light)) :background "#e9edf5" :extend t)
    (((background dark)) :background "#2c313c" :extend t))
  "Background of messages written by the user." :group 'harness-ui)

(defface harness-user-label-face '((t :inherit (bold font-lock-keyword-face)))
  "Sender name above the user's messages." :group 'harness-ui)

(defface harness-user-bar-face '((t :inherit font-lock-keyword-face))
  "Bar down the left edge of the user's messages (foreground only)." :group 'harness-ui)

(defface harness-agent-face '((t :inherit default))
  "Face of the agent's text." :group 'harness-ui)

(defface harness-agent-label-face '((t :inherit (bold font-lock-type-face)))
  "Sender name at the start of each agent turn." :group 'harness-ui)

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

;; Icons are monochrome SVGs drawn in `currentColor', so they take the
;; colour of the face around them; terminals fall back to plain symbols.
;; No emoji: they ignore the theme and vary wildly between fonts.

(defun harness-ui-icon-file (name)
  "Return the path of the SVG icon NAME shipped in the icons directory."
  (expand-file-name (concat "icons/" name ".svg")
                    (if (boundp 'harness-directory) harness-directory
                      (file-name-directory (or (locate-library "harness") default-directory)))))

(defmacro harness-ui-define-icon (name file symbol text doc)
  "Define icon NAME from SVG FILE, falling back to SYMBOL then TEXT.
DOC is its documentation."
  `(define-icon ,name nil
     (list (list 'image (harness-ui-icon-file ,file) :height '(1.1 . em))
           (list 'symbol ,symbol)
           (list 'text ,text))
     ,doc :version "29.1"))

(harness-ui-define-icon harness-icon-idle "idle" "●" "idle" "Idle session.")
(harness-ui-define-icon harness-icon-running "running" "►" "run" "Running session.")
(harness-ui-define-icon harness-icon-blocked "blocked" "‖" "wait" "Blocked session.")
(harness-ui-define-icon harness-icon-inactive "inactive" "○" "off" "Inactive session.")
(harness-ui-define-icon harness-icon-user "user" "◆" "you" "The user.")
(harness-ui-define-icon harness-icon-agent "agent" "◇" "agent" "The agent.")
(harness-ui-define-icon harness-icon-tool "tool" "◈" "tool" "A tool call.")
(harness-ui-define-icon harness-icon-thinking "thinking" "…" "think" "Thinking.")
(harness-ui-define-icon harness-icon-collapsed "collapsed" "▸" "+" "Collapsed block.")
(harness-ui-define-icon harness-icon-expanded "expanded" "▾" "-" "Expanded block.")
(harness-ui-define-icon harness-icon-attach "attach" "+" "attach" "Attachment.")
(harness-ui-define-icon harness-icon-warning "warning" "!" "error" "An error.")

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
(defvar harness-ui-connection-address nil
  "Where the harness is: nil in this Emacs, `process' for the harness
process `harness-start' manages (see `harness-process'), or \"host:port\".")

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

(defvar harness-ui--server nil "The harness process this Emacs started, or nil.")
(defvar harness-ui--server-address nil "(ADDRESS . TOKEN) of the running harness process.")
(defvar harness-ui--server-stopping nil "Non-nil while the harness process is being stopped on purpose.")
(defvar harness-ui--server-restarts nil "Start times of recent unplanned restarts.")
(defvar harness-ui--queue nil
  "Requests made before the harness process listened, newest first.
Each is (METHOD PARAMS PROMISE); PROMISE is nil for notifications.")

(defun harness-ui-connected-p ()
  "Non-nil when the UI has a live connection."
  (and harness-ui-connection (harness-acp-connected-p harness-ui-connection)))

(defun harness-ui-connect (&optional address)
  "Connect the UI to ADDRESS: nil for the in-process harness, `process'
for the managed harness process, or \"host:port\".  Return the
connection, or nil while the harness process is still starting; requests
made meanwhile are queued and sent once it listens."
  (when harness-ui-connection (ignore-errors (harness-acp-close harness-ui-connection)))
  (setq harness-ui-connection nil
        harness-ui-connection-address address)
  (if (eq address 'process)
      (if harness-ui--server-address
          (harness-ui--open (car harness-ui--server-address) (cdr harness-ui--server-address))
        (harness-ui--ensure-server)
        nil)
    (harness-ui--open address nil)))

(defun harness-ui--open (address token)
  "Open the connection to ADDRESS (nil: in-process) authenticating with TOKEN."
  (setq harness-ui-connection (let ((harness-acp-token (or token harness-acp-token)))
                                (harness-acp-connect address)))
  (harness-acp-set-handler harness-ui-connection #'harness-ui--dispatch)
  (harness-acp-on-close harness-ui-connection #'harness-ui--on-close)
  (harness-then (harness-acp-initialize harness-ui-connection)
                (lambda (_) (harness-ui-refresh-sessions) (harness-ui-refresh-models))
                (lambda (e) (message "Harness: initialize failed: %s" (harness-error-message e))))
  (harness-ui--flush-queue)
  harness-ui-connection)

(defun harness-ui-connection ()
  "Return the live connection, connecting if needed; nil while the harness
process is starting."
  (if (harness-ui-connected-p) harness-ui-connection (harness-ui-connect harness-ui-connection-address)))

(defun harness-ui--on-close ()
  (unless (eq harness-ui-connection-address 'process) ; the supervisor reports that
    (message "Harness: connection closed%s"
             (if harness-ui-connection-address (format " (%s)" harness-ui-connection-address) ""))))

(defun harness-ui--flush-queue ()
  "Send every queued request over the open connection."
  (let ((queue (nreverse harness-ui--queue)))
    (setq harness-ui--queue nil)
    (dolist (item queue)
      (pcase-let ((`(,method ,params ,promise) item))
        (if promise
            (harness-then (harness-acp-request harness-ui-connection method params)
                          (lambda (v) (harness-resolve promise v))
                          (lambda (e) (harness-reject promise e)))
          (harness-acp-notify harness-ui-connection method params))))))

(defun harness-ui-request (method &optional params)
  "Send METHOD with PARAMS over the UI connection; return a promise."
  (if-let* ((conn (harness-ui-connection)))
      (harness-acp-request conn method params)
    (let ((p (harness-make-promise)))
      (push (list method params p) harness-ui--queue)
      p)))

(defun harness-ui-call (method params callback &optional on-error)
  "Request METHOD with PARAMS and call CALLBACK with the result.
Errors are shown in the echo area unless ON-ERROR handles them."
  (harness-then (harness-ui-request method params)
                callback
                (or on-error
                    (lambda (e) (message "Harness: %s failed: %s" method (harness-error-message e)) nil))))

(defun harness-ui-notify (method &optional params)
  "Send notification METHOD with PARAMS."
  (if-let* ((conn (harness-ui-connection)))
      (harness-acp-notify conn method params)
    (push (list method params nil) harness-ui--queue)))

;;;; The harness process


(defun harness-ui--ensure-server ()
  "Start the harness process unless it runs or is starting.
During init the start waits for `emacs-startup-hook', so settings made
later in the init file still reach the process."
  (cond
   ((and harness-ui--server (process-live-p harness-ui--server)))
   ((not after-init-time)
    (add-hook 'emacs-startup-hook #'harness-ui--ensure-server))
   (t
    (remove-hook 'emacs-startup-hook #'harness-ui--ensure-server)
    (setq harness-ui--server-address nil
          harness-ui--server-stopping nil
          harness-ui--server
          (harness-server-spawn
           :on-address (lambda (address token)
                         (setq harness-ui--server-address (cons address token))
                         (when (eq harness-ui-connection-address 'process)
                           (harness-ui--open address token)
                           (run-hooks 'harness-ui-redraw-hook)))
           :on-exit #'harness-ui--on-server-exit)))))

(defun harness-ui--on-server-exit (status)
  "React to the harness process ending with STATUS: restart it unless stopped."
  (setq harness-ui--server nil harness-ui--server-address nil)
  (unless harness-ui--server-stopping
    (let* ((now (float-time))
           (recent (cl-remove-if (lambda (time) (< time (- now 60))) harness-ui--server-restarts)))
      (setq harness-ui--server-restarts (cons now recent))
      (if (>= (length recent) 5)
          (progn
            (harness-log 'error "harness process keeps exiting (status %s); not restarting" status)
            (message "Harness process exited (status %s) 5 times in a minute; see M-x harness-show-log, then M-x harness-restart"
                     status))
        (harness-log 'warn "harness process exited (status %s); restarting" status)
        (message "Harness process exited (status %s); restarting" status)
        (run-at-time (expt 2 (length recent)) nil
                     (lambda ()
                       (when (eq harness-ui-connection-address 'process)
                         (harness-ui--ensure-server))))))))

(defun harness-ui--stop-server ()
  "Stop the harness process cleanly."
  (setq harness-ui--server-stopping t)
  (when harness-ui--server (harness-server-stop harness-ui--server))
  (setq harness-ui--server nil harness-ui--server-address nil))

;;;###autoload
(defun harness-restart ()
  "Restart the harness process with the current configuration.
Sessions persist; running turns are interrupted."
  (interactive)
  (unless (eq harness-ui-connection-address 'process)
    (user-error "The harness does not run in its own process (see `harness-process')"))
  (setq harness-ui--server-restarts nil)
  (let ((old harness-ui--server))
    (harness-ui--stop-server)
    (if (and old (process-live-p old))
        (set-process-sentinel old (lambda (p _e)
                                    (unless (process-live-p p)
                                      (harness-ui-connect 'process))))
      (harness-ui-connect 'process))))

(defun harness-ui-reload-server ()
  "Ask the harness process to reload its modules in place."
  (when (eq harness-ui-connection-address 'process)
    (harness-ui-call "_harness/harness/reload" nil
                     (lambda (_) (message "Harness process reloaded")))))

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
    ("_harness/client/customize-save"
     (condition-case err
         (funcall respond (harness-client-tools-customize-save (plist-get params :symbol) (plist-get params :value)))
       (error (harness-acp-respond-error respond -32000 (error-message-string err)))))
    ("_harness/client/tool"
     (funcall respond (harness-client-tools-run (plist-get params :name) (plist-get params :input))))
    ("_harness/event"
     (let ((event (plist-get params :event)) (args (plist-get params :args)))
       (when (equal event "tools/file-written")
         (harness-client-tools-revert-visiting (car args)))
       (when (member event '("session/created" "session/deleted"))
         (harness-ui-refresh-sessions))
       (when (equal event "harness/reloaded")
         (run-hooks 'harness-ui-redraw-hook))
       (when (member event '("provider/models-updated" "harness/reloaded"))
         (harness-ui-refresh-models))
       (run-hook-with-args 'harness-ui-event-functions event args)))
    (_ (when respond (harness-acp-respond-error respond -32601 (format "unhandled %s" method))))))

(defun harness-ui--leave-pending (params respond what)
  "Leave WHAT (a permission or question request PARAMS) pending on its session.
No buffer shows the session, so nothing prompts: declining through
RESPOND keeps the request pending server side, where the session reads
as needing input and its chat panel or task card answers it later."
  (harness-acp-respond-error respond -32000 (format "no buffer shows this session; the %s stays pending" what))
  (let ((session (harness-ui-session (plist-get params :sessionId))))
    (message "Harness: %s needs your input" (if session (harness-ui-session-label session) "a session")))
  t)

(defun harness-ui--default-permission (params respond)
  "Fallback when no UI module claimed permission request PARAMS: leave it pending."
  (harness-ui--leave-pending params respond "permission request"))

(defun harness-ui--default-question (params respond)
  "Fallback when no UI module claimed question PARAMS: leave it pending."
  (harness-ui--leave-pending params respond "question"))

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

;;;; Model catalogue cache

(defvar harness-ui--models (make-hash-table :test 'equal)
  "Model id -> model plist from the harness catalogue.")

(defun harness-ui-refresh-models (&optional callback)
  "Reload the model catalogue cache, redraw, then call CALLBACK with the models."
  (harness-ui-call "_harness/provider/models" nil
                   (lambda (models)
                     (clrhash harness-ui--models)
                     (dolist (m models) (puthash (plist-get m :id) m harness-ui--models))
                     (run-hooks 'harness-ui-redraw-hook)
                     (when callback (funcall callback models)))
                   (unless callback #'ignore)))

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
                                                  (propertize (harness-ui-model-label (plist-get s :model)) 'face 'harness-dim-face)
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

(defun harness-ui--prettify-model-name (name)
  "Return a readable form of model slug NAME, or nil when it has no known shape.
\"claude-opus-5-5\" and \"claude-haiku-4-5-20251001\" become
\"Claude Opus 5.5\" and \"Claude Haiku 4.5\"."
  (when (string-match "\\`claude-\\([a-z]+\\)-\\([0-9]+\\)\\(?:-\\([0-9]\\)\\)?\\(?:-[0-9]\\{8\\}\\)?\\'" name)
    (format "Claude %s %s%s" (capitalize (match-string 1 name)) (match-string 2 name)
            (if (match-string 3 name) (concat "." (match-string 3 name)) ""))))

(defun harness-ui-model-label (model-id)
  "Return a short, readable \"model (provider)\" label for MODEL-ID.
The model part is the catalogue's label, else a prettified slug, else
the raw name, less a leading word the provider part already says; the
provider part is the first word of the provider's label, else its
capitalized id."
  (if (not (and model-id (string-match "\\`\\([^:]+\\):\\(.+\\)\\'" model-id)))
      (or model-id "?")
    (let* ((pid (match-string 1 model-id))
           (name (match-string 2 model-id))
           (m (gethash model-id harness-ui--models))
           (label (plist-get m :label))
           (provider (or (car (split-string (or (plist-get m :provider-label) "")))
                         (capitalize pid)))
           (model (or (and label (not (equal label name)) label)
                      (harness-ui--prettify-model-name name)
                      name)))
      ;; "Claude Opus 5.5" from "Claude Code" reads as "Opus 5.5 (Claude)".
      (format "%s (%s)"
              (if (string-prefix-p (concat provider " ") model t)
                  (substring model (1+ (length provider)))
                model)
              provider))))

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
  (harness-files-project-root default-directory))

;;;###autoload
(defun harness-new-session (directory &optional position)
  "Start a new session in DIRECTORY and show it in POSITION."
  (interactive (list (read-directory-name "Session directory: " (harness-ui--default-directory) nil t)
                     (and current-prefix-arg (harness-ui-read-position))))
  (harness-ui-call "session/new" (list :cwd (expand-file-name directory)
                                       ;; Rooted here, where the user's project setup lives.
                                       :_harness (list :project (harness-files-project-root directory)))
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
    (harness-ui-refresh-models
     (lambda (models)
       (let* ((labels (mapcar (lambda (m) (harness-ui-model-label (plist-get m :id))) models))
              (table (cl-mapcar (lambda (m label)
                                  ;; Two models sharing a label are told apart by id.
                                  (cons (if (> (cl-count label labels :test #'equal) 1)
                                            (format "%s (%s)" label (plist-get m :id))
                                          label)
                                        m))
                                models labels))
              (completion-extra-properties
               (list :annotation-function
                     (lambda (choice)
                       (let ((m (cdr (assoc choice table))))
                         (format "  %s · %s ctx%s"
                                 (plist-get m :id)
                                 (harness-format-tokens (plist-get m :context-window))
                                 (if-let* ((p (plist-get m :pricing)))
                                     (format " · $%s/$%s per M" (plist-get p :input) (plist-get p :output))
                                   ""))))))
              (choice (completing-read "Model: " table nil t))
              (id (plist-get (cdr (assoc choice table)) :id)))
         (harness-ui-call "session/set_model" (list :sessionId sid :modelId id)
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
                              (choice (completing-read "Thinking: " (cons "default" levels) nil t)))
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

(defun harness-ui--display-menu (buffer alist)
  "Display the menu BUFFER, keeping it out of the windows around a side window.
Sessions usually live in side windows, which cannot be split.  Actions
such as `display-buffer-below-selected' then fall back to reusing
another window, which transient fits horizontally to the menu and
cannot delete afterwards, wrecking the layout.  So from a side window
the menu gets a bottom side window of its own; elsewhere it follows
`transient-display-buffer-action'.  ALIST is the action alist."
  (if (window-parameter (selected-window) 'window-side)
      (display-buffer-in-side-window
       buffer (append '((side . bottom) (slot . 1) (dedicated . t)) alist))
    (display-buffer buffer transient-display-buffer-action)))

(transient-define-prefix harness-menu ()
  "The harness menu."
  :display-action '(harness-ui--display-menu (inhibit-same-window . t))
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
  (add-hook 'kill-emacs-hook #'harness-ui--stop-server)
  (harness-ui-connect harness-ui-connection-address)
  ;; A reload reaches the UI as the forwarded `harness/reloaded' event, for
  ;; local and remote harnesses alike, so no bus subscription is needed.
  (harness-global-mode 1))

(harness-define-module 'ui
  :doc "UI foundation: ACP connection, faces, positions, keymap and menu."
  :requires '(acp)
  :init #'harness-ui--init
  :shutdown #'harness-ui--stop-server)

(provide 'harness-ui)
;;; harness-ui.el ends here
