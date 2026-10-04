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
;; - a cache of the harness's tools, so views name each tool by its
;;   label (Read file) rather than the name the model calls it by
;;   (read_file);
;; - a cache of each provider's billing and plan quota kept fresh from
;;   `provider/quota-updated' events, and the helpers that show what a
;;   session cost: a price when it is billed per token, the plan's name
;;   and quota when a subscription pays for it;
;; - faces and icons;
;; - window positions: one session per preset position, replacing;
;; - the prefix keymap, the global minor mode and the transient menu,
;;   which also lists the commands of the buffer it is opened from, as
;;   that buffer's modes list them in their `harness-menu-group'.

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
(require 'harness-notifications-desktop)

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

(defface harness-system-face
  '((((background light)) :inherit shadow :background "#eeeeee" :extend t)
    (((background dark)) :inherit shadow :background "#2b2b2b" :extend t))
  "Messages the user did not write, on a background of their own.
The harness sent them on its own (a task carrying on after a restart,
non-interactive mode after a denied call, the merge queue), or the
agent of another session did.  Their text is muted, like a hint's."
  :group 'harness-ui)

(defface harness-system-label-face '((t :inherit (bold shadow)))
  "Sender name above messages the user did not write." :group 'harness-ui)

(defface harness-system-bar-face '((t :inherit shadow))
  "Bar down the left edge of messages the user did not write (foreground only)."
  :group 'harness-ui)

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
  "Background of failed tool call blocks.
The tool ran and reported an error." :group 'harness-ui)

(defface harness-tool-denied-face
  '((((background light)) :background "#f9efe0" :extend t)
    (((background dark)) :background "#3a3226" :extend t))
  "Background of denied tool call blocks.
The permission system refused the call, so it never ran." :group 'harness-ui)

(defface harness-tool-title-face '((t :inherit (font-lock-function-name-face bold)))
  "Face of a tool call's title: the tool's label, such as \"Read file\"." :group 'harness-ui)

(defface harness-tool-subject-face '((t))
  "Face of what a tool call is about, after the tool's label in its title.
The path a call reads, the command it runs.  It sets nothing by
default, so the text keeps the face of what it is drawn on."
  :group 'harness-ui)

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

(defface harness-success-face '((t :inherit success))
  "Success: the green circle of a tool call that ran, and its word."
  :group 'harness-ui)
(defface harness-caution-face '((t :inherit warning))
  "A warning, or work in progress: the yellow circle and its word.
A tool call that is running, or that the permission system refused."
  :group 'harness-ui)
(defface harness-failure-face '((t :inherit error))
  "Failure: the red triangle of a tool call that failed, and its word."
  :group 'harness-ui)

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

(defface harness-plan-face '((t :inherit font-lock-constant-face))
  "The name of the subscription plan that pays for a session." :group 'harness-ui)

(defface harness-non-interactive-face '((t :inherit warning))
  "A session that runs non-interactive, never waiting for the user." :group 'harness-ui)

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
(harness-ui-define-icon harness-icon-system "system" "⚙" "sys" "The harness, sending a message on its own.")
(harness-ui-define-icon harness-icon-tool "tool" "◈" "tool" "A tool call.")
(harness-ui-define-icon harness-icon-thinking "thinking" "…" "think" "Thinking.")
(harness-ui-define-icon harness-icon-collapsed "collapsed" "▸" "+" "Collapsed block.")
(harness-ui-define-icon harness-icon-expanded "expanded" "▾" "-" "Expanded block.")
(harness-ui-define-icon harness-icon-attach "attach" "+" "attach" "Attachment.")
(harness-ui-define-icon harness-icon-warning "warning" "!" "error" "An error.")
(harness-ui-define-icon harness-icon-success "success" "●" "ok" "Success: a circle, green.")
(harness-ui-define-icon harness-icon-caution "caution" "●" "~"
                        "A warning, or work in progress: a circle, yellow.")
(harness-ui-define-icon harness-icon-failure "failure" "▲" "!" "A failure: a triangle, red.")

(defun harness-ui-icon (name)
  "Return the string for icon NAME (a symbol such as `harness-icon-idle').
An image icon carries no `:background', so its transparent parts show
the face behind it (a tool block's colour, say).  Some packages, such as
solaire-mode, bake the buffer's base colour into every image."
  (condition-case nil
      (let* ((s (icon-string name))
             (spec (and (> (length s) 0) (get-text-property 0 'display s))))
        (if (and (eq (car-safe spec) 'image) (plist-member (cdr spec) :background))
            (propertize s 'display (cons 'image (harness-ui--plist-without (cdr spec) :background)))
          s))
    (error "")))

(defun harness-ui--plist-without (plist key)
  "Return a copy of PLIST without KEY."
  (cl-loop for (k v) on plist by #'cddr unless (eq k key) nconc (list k v)))

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

;; How something went reads the way a Japanese table marks it: a green
;; circle for success, a yellow one for a warning or work in progress,
;; a red triangle for a failure.

(defun harness-ui-level-icon (level)
  "Return the icon string for LEVEL, with face.
LEVEL says how something went: `success' (a green circle), `caution'
\(a yellow circle: a warning, or work in progress) or `failure' (a red
triangle).  Words that go with the icon take `harness-ui-level-face'."
  (propertize (harness-ui-icon (pcase level
                                 ('success 'harness-icon-success)
                                 ('failure 'harness-icon-failure)
                                 (_ 'harness-icon-caution)))
              'face (harness-ui-level-face level)))

(defun harness-ui-level-face (level)
  "Return the face for LEVEL (see `harness-ui-level-icon')."
  (pcase level
    ('success 'harness-success-face)
    ('failure 'harness-failure-face)
    (_ 'harness-caution-face)))

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

(defvar harness-ui-notification-functions nil
  "Functions called with (NOTIFICATION) when a desktop notification is clicked.
NOTIFICATION is the wire plist of `_harness/client/notify': `:title',
`:body', `:urgency', and what it is about (`:session', `:task',
`:project', `:kind', `:source').  The first function that returns
non-nil has shown what the notification is about; when none does, its
session opens.")

(defvar harness-ui-sessions-changed-hook nil
  "Hook run after the session cache changes.")

(defvar harness-ui-redraw-hook nil
  "Hook run when every UI buffer should redraw (after a reload or reconnect).")

(defvar harness-ui-connected-hook nil
  "Hook run once the UI has connected to a harness and initialised it.
That is at start, after the harness process restarts and after a switch
to another harness; a harness that just started has every session
closed, so what the UI shows may need opening again.")

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
made meanwhile are queued and sent once it listens.
In corporate mode (`harness-corporate-mode') a \"host:port\" ADDRESS
gives way to this Emacs's own harness: the UI connects to no other."
  (when (and (stringp address) (harness-corporate-p))
    (message "Harness: corporate mode is on, so the UI connects to the local harness, not %s" address)
    (setq address (harness-ui--local-address)))
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
  "Open the connection to ADDRESS (nil: in-process) authenticating with TOKEN.
Only the UI's current connection reports closing or failing to
initialize: one it let go of for another closes on purpose."
  (let ((conn (let ((harness-acp-token (or token harness-acp-token)))
                (harness-acp-connect address))))
    (setq harness-ui-connection conn)
    ;; Another harness, or the same one started again, may have other tools.
    (harness-ui--forget-tools)
    (harness-acp-set-handler conn #'harness-ui--dispatch)
    (harness-acp-on-close conn (lambda ()
                                 (when (eq conn harness-ui-connection)
                                   (harness-ui--on-close))))
    (harness-then (harness-acp-initialize conn)
                  (lambda (_)
                    (harness-ui-refresh-sessions)
                    (harness-ui-refresh-models)
                    (harness-ui-refresh-quotas)
                    (run-hooks 'harness-ui-connected-hook))
                  (lambda (e)
                    (when (eq conn harness-ui-connection)
                      (message "Harness: initialize failed: %s" (harness-error-message e)))))
    (harness-ui--flush-queue)
    conn))

(defun harness-ui-connection ()
  "Return the live connection, connecting if needed; nil while the harness
process is starting.  A TCP connection still connecting is live: what is
sent meanwhile goes out once it connects, whereas connecting again would
drop it along with every request it carries."
  (if (harness-acp-open-p harness-ui-connection)
      harness-ui-connection
    (harness-ui-connect harness-ui-connection-address)))

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
Sessions and tasks persist; running turns are interrupted, and the
tasks among them carry on once the process is back (see
`harness-tasks-resume-interrupted')."
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
    ("_harness/client/notify"
     (harness-then (harness-ui--show-notification params)
                   (lambda (shown) (funcall respond shown) nil)
                   (lambda (err) (harness-acp-respond-error respond -32000 (harness-error-message err)) nil)))
    ("_harness/event"
     (let ((event (plist-get params :event)) (args (plist-get params :args)))
       (when (equal event "tools/file-written")
         (harness-client-tools-revert-visiting (car args)))
       (when (member event '("session/created" "session/deleted"))
         (harness-ui-refresh-sessions))
       (when (equal event "harness/reloaded")
         ;; Reloaded code may label its tools anew: views fetch them again.
         (harness-ui--forget-tools)
         (run-hooks 'harness-ui-redraw-hook))
       (when (member event '("provider/models-updated" "harness/reloaded"))
         (harness-ui-refresh-models))
       (when (equal event "provider/quota-updated")
         (harness-ui--store-quota (car args) (cadr args)))
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

;;;; Desktop notifications

(defun harness-ui--show-notification (params)
  "Show the notification PARAMS of `_harness/client/notify' on this desktop.
Return a promise of (:backend NAME) once it shows.  One about a session
or a task opens it when clicked (`harness-ui--notification-clicked')."
  (harness-then
   (harness-notifications-desktop-notify
    :title (plist-get params :title)
    :body (plist-get params :body)
    :urgency (plist-get params :urgency)
    :on-action (and (or (plist-get params :session) (plist-get params :task))
                    (lambda ()
                      ;; Out of the process filter or D-Bus handler first.
                      (harness-run-soon #'harness-ui--notification-clicked params))))
   (lambda (shown)
     (list :backend (format "%s" (plist-get shown :backend))))))

(defun harness-ui--notification-clicked (params)
  "Show what the clicked notification PARAMS is about.
`harness-ui-notification-functions' come first (the task board opens
on a task); otherwise the notification's session opens.  The frame it
opens in comes to the front, as the user just asked for it."
  (let ((frame (if (display-graphic-p (selected-frame))
                   (selected-frame)
                 (cl-find-if #'display-graphic-p (frame-list)))))
    (when (and frame (frame-live-p frame))
      (harness-ignore-errors-logged "showing the frame for a notification"
        (select-frame-set-input-focus frame))))
  (unless (run-hook-with-args-until-success 'harness-ui-notification-functions params)
    (when-let* ((sid (plist-get params :session)))
      (harness-ui-display-session sid))))

(defun harness-ui--notification-summary (result)
  "Describe RESULT, what `notification/send' returned, in one line."
  (if (harness-json-true-p (plist-get result :dropped))
      "dropped by a notification/before-send filter"
    (let ((parts (mapcar (lambda (r)
                           (format "%s %s%s" (plist-get r :provider) (plist-get r :status)
                                   (let ((why (or (plist-get r :detail) (plist-get r :error))))
                                     (if why (format " (%s)" why) ""))))
                         (plist-get result :results))))
      (if parts (string-join parts "; ") "no notification provider is enabled"))))

;;;###autoload
(defun harness-test-notifications ()
  "Check the notification setup with a test notification.
It goes to every notification provider that is set up, and the echo
area says what each provider did with it."
  (interactive)
  (harness-ui-call "_harness/notification/send"
                   (list :notification (list :title "Test notification" :source "ui" :kind "test"
                                             :body "Notifications from the Emacs Agent Harness reach you here."))
                   (lambda (result)
                     (message "Harness notifications: %s" (harness-ui--notification-summary result)))))

(defvar harness-process)

(defun harness-ui--local-address ()
  "Return the address of this Emacs's own harness for `harness-ui-connect':
`process' when the harness runs in its own process (`harness-process'),
nil when it runs in this Emacs."
  (and (bound-and-true-p harness-process) 'process))

;;;###autoload
(defun harness-connect-remote (address)
  "Connect the UI to a harness ACP server at ADDRESS (\"host:port\").
An empty or nil ADDRESS connects back to this Emacs's own harness: the
harness process when `harness-process' is on, else the harness in this
Emacs.  When the connection cannot be opened, for instance as ADDRESS
has no port, the UI stays connected where it was.  In corporate mode
\(`harness-corporate-mode') the UI connects to its own harness only, and
any other ADDRESS is refused."
  (interactive
   ;; Offer the remote address in use; a local harness's is `process' or nil.
   (list (read-string "Harness server (host:port, empty for the local harness): "
                      (and (stringp harness-ui-connection-address) harness-ui-connection-address))))
  (let ((remote (and address (not (string-blank-p address)) (string-trim address))))
    (when (and remote (harness-corporate-p))
      (user-error "Corporate mode is on: the UI connects only to this Emacs's own harness"))
    (let* ((previous harness-ui-connection-address)
           (failure (condition-case err
                        (progn (harness-ui-connect (or remote (harness-ui--local-address))) nil)
                      (error (ignore-errors (harness-ui-connect previous))
                             err))))
      (run-hooks 'harness-ui-redraw-hook)
      (if failure
          (user-error "Harness: cannot connect to %s: %s"
                      (or remote "the local harness") (harness-error-message failure))
        (message "Harness: connected to %s" (or remote "the local harness"))))))

(defun harness-ui--corporate-mode-changed ()
  "Make a change of `harness-corporate-mode' reach the harness.
Run from `harness-corporate-mode-change-hook'.  Turned on, the option
takes the UI off a remote harness, back to this Emacs's own.  The
harness process reads the option as it starts, so the process the UI
uses is restarted if it is running; a harness in this Emacs reads the
option as it goes.  While Emacs initialises the process has not started
yet: it starts after the init file, with the value set there."
  (let* ((on (harness-corporate-p))
         (remote (and on (stringp harness-ui-connection-address) harness-ui-connection-address)))
    (when remote
      ;; Nothing more goes to the remote harness.
      (when harness-ui-connection (ignore-errors (harness-acp-close harness-ui-connection)))
      (setq harness-ui-connection nil
            harness-ui-connection-address (harness-ui--local-address)))
    (cond
     ((and (eq harness-ui-connection-address 'process)
           harness-ui--server (process-live-p harness-ui--server))
      (message "Harness: corporate mode is now %s%s; restarting the harness process so that it applies"
               (if on "on" "off")
               (if remote (format " and the UI left %s" remote) ""))
      ;; The views redraw once the new process listens.
      (harness-restart))
     (remote
      (harness-ui-connect harness-ui-connection-address)
      (run-hooks 'harness-ui-redraw-hook)
      (message "Harness: corporate mode is now on; the UI left %s for the local harness" remote)))))

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

(defun harness-ui-task-title (task &optional session)
  "Return TASK's title, as the task board shows it.
That is the name of its SESSION, by default the cached session it works
in, once it has one, else the first line of its prompt.  A session is
named after its first turn, and a task works in that turn, so a task at
work has no name yet."
  (let ((name (plist-get (or session
                             (and (plist-get task :session) (harness-ui-session (plist-get task :session))))
                         :name)))
    (if (harness-string-blank-p name)
        (harness-first-line (plist-get task :prompt) 72)
      name)))

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

;;;; Tool catalogue cache
;;
;; A tool has a name the model calls it by (read_file) and a label
;; people read (Read file).  Views show the label, looked up here in the
;; specs of every tool of the connected harness (`tools/list' without a
;; session, so the tools of any transcript are there), fetched once per
;; connection and again after a reload.

(defvar harness-ui--tools nil
  "Tool name -> spec plist (`tools/list' wire shape) of the connected harness.
Nil until fetched; see `harness-ui-fetch-tools'.")

(defvar harness-ui--tools-fetch nil
  "The promise of the tool specs being fetched, or nil.")

(defvar harness-ui--tools-generation 0
  "Counter bumped when the cached tool specs go stale; drops late answers.")

(defun harness-ui--forget-tools ()
  "Drop the cached tool specs; the next `harness-ui-fetch-tools' fetches them."
  (setq harness-ui--tools nil harness-ui--tools-fetch nil)
  (cl-incf harness-ui--tools-generation))

(defun harness-ui-fetch-tools ()
  "Return a promise of the table of tool specs, fetched unless cached.
The table maps tool names to spec plists.  A failed fetch resolves to
an empty table, which is not cached: views then show tool names until
a later fetch succeeds."
  (cond
   (harness-ui--tools (harness-resolved harness-ui--tools))
   (harness-ui--tools-fetch)
   (t
    (let ((gen harness-ui--tools-generation)
          (fetch (harness-make-promise)))
      ;; Recorded before the handlers can run: a request that settles at
      ;; once runs them right away, and they let go of it.
      (setq harness-ui--tools-fetch fetch)
      (harness-then
       (harness-ui-request "_harness/tools/list" nil)
       (lambda (specs)
         (let ((table (make-hash-table :test 'equal)))
           (dolist (spec specs)
             (when (plist-get spec :name)
               (puthash (format "%s" (plist-get spec :name)) spec table)))
           (when (= gen harness-ui--tools-generation)
             (setq harness-ui--tools table))
           (when (eq harness-ui--tools-fetch fetch)
             (setq harness-ui--tools-fetch nil))
           (harness-resolve fetch table)))
       (lambda (err)
         (when (eq harness-ui--tools-fetch fetch)
           (setq harness-ui--tools-fetch nil))
         (harness-log 'warn "ui: fetching the tools failed: %s" (harness-error-message err))
         (harness-resolve fetch (make-hash-table :test 'equal))))
      fetch))))

(defun harness-ui-tool (name)
  "Return the cached spec of tool NAME, or nil."
  (and harness-ui--tools name (gethash (format "%s" name) harness-ui--tools)))

(defun harness-ui-tool-label (name)
  "Return the name people read for tool NAME: its label, such as \"Read file\".
A tool the cache does not know (not fetched yet, or one a model made
up) reads as NAME itself."
  (let ((label (plist-get (harness-ui-tool name) :label)))
    (if (and (stringp label) (not (string-empty-p label)))
        label
      (format "%s" (or name "tool")))))

(defun harness-ui-tool-title-parts (name title)
  "Split TITLE, the title of a call to tool NAME, into (LABEL . SUBJECT).
A title is the tool's label, then \": \" and what the call is about
\(\"Read file: x.el\"), or the label alone, when SUBJECT is nil.  One
recorded before tools had labels starts with NAME instead (\"read_file
x.el\"), which gives way to the label.  A title of another shape is
all SUBJECT, with a nil LABEL; without a title the call is its label."
  (let ((label (harness-ui-tool-label name))
        (name (and name (format "%s" name))))
    (cond
     ((or (not (stringp title)) (string-empty-p title)) (cons label nil))
     ((equal title label) (cons label nil))
     ((string-prefix-p (concat label ": ") title)
      (cons label (substring title (+ (length label) 2))))
     ((and name (equal title name)) (cons label nil))
     ((and name (string-prefix-p (concat name " ") title))
      (cons label (string-trim-left (substring title (length name)))))
     (t (cons nil title)))))

(defun harness-ui-tool-title (name title)
  "Return TITLE, the title of a call to tool NAME, as people should read it.
That is the tool's label and what the call is about, \"Read file:
x.el\", whatever NAME's label was when TITLE was recorded (see
`harness-ui-tool-title-parts')."
  (pcase-let ((`(,label . ,subject) (harness-ui-tool-title-parts name title)))
    (cond ((null subject) label)
          ((null label) subject)
          (t (concat label ": " subject)))))

(defun harness-ui-tool-title-string (name title &optional max)
  "Return the title of a call to tool NAME, TITLE, styled for a header.
The tool's label is in `harness-tool-title-face' and what the call is
about follows in `harness-tool-subject-face', which tells them apart
instead of the colon; a title of another shape is all in the title
face.  The first line only, cut to MAX characters when MAX is given."
  (pcase-let ((`(,label . ,subject) (harness-ui-tool-title-parts name title)))
    (let ((text (harness-first-line (if (and label subject) (concat label " " subject) (or label subject)) max)))
      (if (and label subject (> (length text) (length label)))
          (concat (propertize (substring text 0 (length label)) 'face 'harness-tool-title-face)
                  (propertize (substring text (length label)) 'face 'harness-tool-subject-face))
        (propertize text 'face 'harness-tool-title-face)))))

;;;; Billing and plan quota cache

(defvar harness-ui--quotas (make-hash-table :test 'equal)
  "Provider id (a string) -> its billing and quota plist.
The plist has the shape `provider/quota' returns.")

(defvar harness-ui-quota-functions nil
  "Functions called with (PROVIDER QUOTA) after PROVIDER's cached quota changes.")

(defun harness-ui-quota (provider)
  "Return the cached billing and quota plist of PROVIDER, or nil.
PROVIDER is an id, a string or a symbol."
  (gethash (format "%s" provider) harness-ui--quotas))

(defun harness-ui-quotas ()
  "Return every cached quota as (PROVIDER . QUOTA), sorted by provider id."
  (let (out)
    (maphash (lambda (k v) (when v (push (cons k v) out))) harness-ui--quotas)
    (sort out (lambda (a b) (string< (car a) (car b))))))

(defun harness-ui--store-quota (provider quota)
  "Cache QUOTA for PROVIDER and run `harness-ui-quota-functions' when it changed."
  (let ((key (format "%s" provider)))
    (unless (equal quota (gethash key harness-ui--quotas))
      (puthash key quota harness-ui--quotas)
      (run-hook-with-args 'harness-ui-quota-functions key quota))))

(defun harness-ui-refresh-quota (provider &optional refresh callback)
  "Fetch PROVIDER's billing and quota into the cache, then call CALLBACK with it.
REFRESH non-nil makes the provider ask for fresh data first."
  (harness-ui-call "_harness/provider/quota"
                   (list :providerId (format "%s" provider) :refresh (if refresh t :false))
                   (lambda (quota)
                     (harness-ui--store-quota provider quota)
                     (when callback (funcall callback quota)))
                   #'ignore))

(defun harness-ui-refresh-quotas (&optional refresh)
  "Fetch the billing and quota of every provider that reports them.
REFRESH non-nil asks each for fresh data."
  (harness-ui-call "_harness/provider/list" nil
                   (lambda (providers)
                     (dolist (p providers)
                       (when (harness-json-true-p (plist-get (plist-get p :capabilities) :quota))
                         (harness-ui-refresh-quota (plist-get p :id) refresh))))
                   #'ignore))

(defun harness-ui-session-provider (session)
  "Return the provider id (a string) of SESSION's model, or nil."
  (let ((model (plist-get session :model)))
    (and (stringp model) (string-match "\\`\\([^:]+\\):" model) (match-string 1 model))))

(defun harness-ui-session-quota (session)
  "Return the cached billing and quota of SESSION's provider, or nil."
  (when-let* ((provider (harness-ui-session-provider session)))
    (harness-ui-quota provider)))

(defun harness-ui-session-billing (session)
  "Return how SESSION's calls are paid, a symbol or nil.
The symbol is `api', `subscription' or `extra-usage'.  Its last
recorded call decides.  Before it made any call, its provider's
account does; calls recorded without a billing stay as recorded."
  (let ((usage (plist-get session :usage)))
    (or (harness-billing-of usage)
        (and (zerop (or (plist-get usage :input) 0))
             (zerop (or (plist-get usage :output) 0))
             (zerop (or (plist-get usage :cost) 0))
             (harness-billing-of (harness-ui-session-quota session))))))

(defun harness-ui-quota-face (fraction)
  "Return the face for a quota window with FRACTION of it used."
  (let ((f (or fraction 0)))
    (cond ((>= f 0.95) 'harness-context-critical-face)
          ((>= f 0.85) 'harness-context-urgent-face)
          ((>= f 0.70) 'harness-context-warning-face)
          (t 'harness-dim-face))))

(defun harness-ui-format-reset (time)
  "Describe quota reset TIME: \"in 3h12m (14:30)\" within a day, else a date."
  (when (numberp time)
    (let ((left (- time (float-time))))
      (cond ((<= left 0) "now")
            ((< left 86400) (format "in %s (%s)" (harness-format-duration left)
                                    (format-time-string "%H:%M" time)))
            (t (format-time-string "%a %b %-d, %H:%M" time))))))

(defun harness-ui-format-window (window)
  "Return \"5h 9%\" for quota WINDOW, coloured by how much of it is used."
  (let ((used (or (plist-get window :used) 0)))
    (propertize (format "%s %d%%" (plist-get window :name) (round (* 100 used)))
                'face (harness-ui-quota-face used))))

(defun harness-ui-describe-window (window)
  "Return a line about quota WINDOW: what it is, how much is used, when it resets."
  (format "%s: %d%% used%s"
          (or (plist-get window :label) (plist-get window :name))
          (round (* 100 (or (plist-get window :used) 0)))
          (if-let* ((reset (harness-ui-format-reset (plist-get window :resets))))
              (concat ", resets " reset)
            "")))

(defun harness-ui-describe-extra (extra)
  "Return a line about a plan's EXTRA usage (billed at API prices), or nil."
  (when extra
    (let ((used (plist-get extra :used)) (limit (plist-get extra :limit))
          (reason (plist-get extra :disabled-reason)))
      (concat "Extra usage: " (if (harness-json-true-p (plist-get extra :enabled)) "on" "off")
              (if (and (stringp reason) (not (harness-json-true-p (plist-get extra :enabled))))
                  (format " (%s)" (replace-regexp-in-string "_" " " reason))
                "")
              (if (numberp used) (format ", %s used" (harness-format-cost used)) "")
              (if (numberp limit) (format " of %s" (harness-format-cost limit)) "")))))

(defun harness-ui-quota-headline-windows (quota)
  "Return the windows of QUOTA worth a glance: the 5-hour and weekly ones,
and any other that is at least 70% used."
  (cl-remove-if-not (lambda (w) (or (member (plist-get w :name) '("5h" "7d"))
                                    (>= (or (plist-get w :used) 0) 0.7)))
                    (plist-get quota :windows)))

(defun harness-ui-plan-title (quota &optional plan)
  "Return the plan's full name from QUOTA (\"Claude Max\"), or from PLAN's id."
  (or (and (or (null plan) (equal plan (plist-get quota :plan))) (plist-get quota :plan-label))
      (let ((name (harness-plan-name (or plan (plist-get quota :plan)))))
        (and name (format "the %s plan" name)))
      "the subscription"))

(defun harness-ui-spend-help (session)
  "Return the tooltip that explains what SESSION cost and who pays for it."
  (let* ((usage (plist-get session :usage))
         (quota (harness-ui-session-quota session))
         (billing (harness-ui-session-billing session))
         (cost (float (or (plist-get usage :cost) 0)))
         (covered (harness-usage-covered usage))
         (payer (harness-ui-plan-title quota (plist-get usage :plan))))
    (string-join
     (delq nil
           (append
            (list
             (cond ((and (> covered 0) (> cost 0))
                    (format "%s billed as extra usage; %s more at API prices covered by %s."
                            (harness-format-cost cost) (harness-format-cost covered) payer))
                   ((or (> covered 0) (memq billing '(subscription extra-usage)))
                    (format "Covered by %s, not billed per token.\nThis session at API prices: %s."
                            payer (harness-format-cost covered)))
                   ((eq billing 'api)
                    (format "Session cost: %s, billed per token%s."
                            (harness-format-cost cost)
                            (if-let* ((auth (plist-get quota :auth))) (format " (%s)" auth) "")))
                   (t (format "Session cost: %s." (harness-format-cost cost)))))
            (when (memq billing '(subscription extra-usage))
              (append (mapcar #'harness-ui-describe-window (plist-get quota :windows))
                      (list (harness-ui-describe-extra (plist-get quota :extra)))))
            (list "mouse-1: usage and plan quota")))
     "\n")))

(defun harness-ui-format-spend (session &optional with-quota)
  "Return what SESSION cost, saying when a subscription pays for it.
Per-token billing shows the cost (\"$1.20\").  When a plan pays, its
name shows instead (\"Max\"), after any cost billed as extra usage
\(\"$0.40+Max\").  WITH-QUOTA appends the plan's headline quota windows
\(\"Max · 5h 9% · 7d 57%\").  The tooltip has the details."
  (let* ((usage (plist-get session :usage))
         (billing (harness-ui-session-billing session))
         (cost (float (or (plist-get usage :cost) 0)))
         (planned (or (> (harness-usage-covered usage) 0) (memq billing '(subscription extra-usage))))
         (quota (harness-ui-session-quota session))
         (name (propertize (or (harness-plan-name (or (plist-get usage :plan) (plist-get quota :plan))) "Plan")
                           'face 'harness-plan-face))
         (text (cond ((not planned) (harness-format-cost cost))
                     ((> cost 0) (concat (harness-format-cost cost) "+" name))
                     (t name)))
         (windows (and with-quota planned (harness-ui-quota-headline-windows quota))))
    (propertize (concat text (mapconcat (lambda (w) (concat " · " (harness-ui-format-window w))) windows ""))
                'help-echo (harness-ui-spend-help session))))

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

(defconst harness-ui--context-reserve 20000
  "Tokens the harness keeps free below a context window for compaction.
The same as `harness-compaction--context-reserve' in the harness process.")

(defun harness-ui-context-face (context window)
  "Return the warning face for CONTEXT tokens against WINDOW."
  (let* ((reserve harness-ui--context-reserve)
         (limit (max 1 (- (or window 128000) reserve)))
         (f (/ (float (or context 0)) limit)))
    (cond ((>= f 0.95) 'harness-context-critical-face)
          ((>= f 0.85) 'harness-context-urgent-face)
          ((>= f 0.70) 'harness-context-warning-face)
          (t 'harness-context-ok-face))))

(defun harness-ui-mode-line-escape (string)
  "Return a copy of STRING for a mode or header line, every % doubled.
Those lines read % as the start of a construct such as %b, so a literal
one -- a quota window's \"23%\" -- would vanish together with the
character after it.  Text properties are kept."
  (replace-regexp-in-string "%" (lambda (match) (concat match match)) string t t))

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

(defconst harness-ui-permission-modes
  '(("ask" "Ask" "Ask before writes, commands and network")
    ("accept-edits" "Accept Edits" "Reads and edits inside the project run freely")
    ("auto" "Auto" "A cheap model judges each call")
    ("yolo" "YOLO" "Allow everything inside the jail"))
  "Permission modes as (ID LABEL DESCRIPTION), least to most permissive.")

(defun harness-ui-permission-mode-label (mode)
  "Return the display label for permission MODE (a symbol or string)."
  (let ((id (if mode (format "%s" mode) "ask")))
    (or (cadr (assoc id harness-ui-permission-modes)) id)))

(defun harness-ui-thinking-label (level)
  "Return the label of thinking LEVEL, nil meaning the model's default."
  (format "%s %s" (harness-ui-icon 'harness-icon-thinking) (or level "default")))

(defun harness-ui-non-interactive-label (value)
  "Return the label of a session's non-interactive switch VALUE.
VALUE is as it comes over the wire: nil and `:false' are off."
  (if (harness-json-true-p value) "non-interactive" "interactive"))

(defun harness-ui-non-interactive-help (value)
  "Return what a session's non-interactive switch VALUE means, for a tooltip."
  (if (harness-json-true-p value)
      "Non-interactive: the agent never waits for you.  The auto-mode judge decides what would ask you for permission, and after a denial the agent is told to find another way."
    "Interactive: the agent asks you for permission and waits for your answer."))

(defun harness-ui-tool-outcome (result)
  "Return how the tool call whose tool-result node is RESULT ended.
`denied' when the permission system refused the call, so it never ran:
the agent records `:denied' in the node's `:meta'.  `failed' when it
ran and reported an error, such as a non-zero exit or an edit whose
text did not match.  `ok' otherwise, and nil without RESULT."
  (cond ((null result) nil)
        ((harness-json-true-p (harness-plist-get-in result '(:meta :denied))) 'denied)
        ((harness-json-true-p (plist-get result :is-error)) 'failed)
        (t 'ok)))

(defun harness-ui-tool-level (outcome)
  "Return the level (see `harness-ui-level-icon') of a tool call's OUTCOME.
OUTCOME is what `harness-ui-tool-outcome' returns.  A call that ran is a
`success', one that failed a `failure', and one the permission system
refused, so it never ran, a `caution'."
  (pcase outcome
    ('ok 'success)
    ('failed 'failure)
    (_ 'caution)))

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

(defun harness-ui-display-view (buffer &optional position)
  "Show BUFFER, a harness view such as the session list, in POSITION.
Views share positions with sessions: a view replaces the session shown
in its position and a session opened there replaces the view.  Without
POSITION the view returns to the position it had last, else
`harness-ui-default-position'.  Small transient windows (menus, help,
the BTW overlay) do not go through here."
  (harness-ui-display-buffer buffer (or position
                                        (buffer-local-value 'harness-ui-position buffer)
                                        harness-ui-default-position)))

(defun harness-ui-session-opener (&optional position)
  "Return a function of a session id that shows it where this view is.
Call this when the command runs and the returned function later, from
an asynchronous callback: the session takes POSITION, by default the
current buffer's position (replacing the view), and opens from the
window selected now even when another frame is selected by then."
  (let ((position (or position harness-ui-position harness-ui-default-position))
        (window (selected-window)))
    (lambda (id)
      (when (window-live-p window) (select-window window))
      (harness-ui-display-session id position))))

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
       (harness-ui-display-session (plist-get s :id) position)))))

;;;; Session settings

(defvar-local harness-ui-setting-target-function nil
  "Function telling the session setting commands what to change in this buffer.
It returns a session id, or (SETTINGS . SET) for settings that are not a
session's yet: SETTINGS is a plist with a session's setting keys
(`:model' `:thinking' `:permission-mode' `:non-interactive') and SET a
function of KEY and VALUE storing one.  The task board uses it so the
same commands set up the next task.  When it is nil or returns nil, the
commands use `harness-ui-current-session-id'.")

(defun harness-ui--setting-target (session-id)
  "Return what the setting commands change.
SESSION-ID when given, else the buffer's target, else a chosen session."
  (or session-id
      (and harness-ui-setting-target-function (funcall harness-ui-setting-target-function))
      (harness-ui-current-session-id)))

(defun harness-ui--setting-get (target key)
  "Return the current value of setting KEY of TARGET."
  (plist-get (if (stringp target) (harness-ui-session target) (car target)) key))

(defun harness-ui--setting-set (target key value label)
  "Set KEY to VALUE on TARGET and say LABEL when it is done.
A non-string TARGET is (VALUES SET-FN &optional CONTEXT): VALUES is
what the setting commands read, SET-FN applies the change, and CONTEXT
names who it applies to (\"for new tasks\" without one)."
  (if (not (stringp target))
      (progn (funcall (nth 1 target) key value)
             (message "%s (%s)" label (or (nth 2 target) "for new tasks")))
    (pcase key
      (:model (harness-ui-call "session/set_model" (list :sessionId target :modelId value)
                               (lambda (_) (message "%s" label))))
      (:permission-mode (harness-ui-call "session/set_mode" (list :sessionId target :modeId value)
                                         (lambda (_) (message "%s" label))))
      (_ (harness-ui-call "_harness/session/update"
                          (list :id target key (if (and (eq key :non-interactive) (not value)) :false value))
                          (lambda (_) (message "%s" label)))))))

(defun harness-ui-choose-model (callback)
  "Prompt for a model from the catalogue and call CALLBACK with (ID LABEL).
The catalogue is refreshed first, so a provider that just became
available is offered."
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
            (choice (completing-read "Model: " table nil t)))
       (funcall callback (plist-get (cdr (assoc choice table)) :id) choice)))))

;;;; Switching models, and handing conversations over

(defconst harness-ui--handoff-choices
  '((?c "current model summarises" compact
        "warm cache; summary from the whole conversation")
    (?n "new model summarises" compact-new
        "only the first and last messages; small, but lossy")
    (?t "full transcript" transcript
        "whole conversation as a file the new model reads")
    (?s "no handoff" none
        "no context; the new model starts from your next message")
    (?q "cancel" cancel "keep the current model"))
  "What a model switch that loses the conversation offers.
Each entry is (KEY NAME CHOICE DESCRIPTION); CHOICE is a mode of
`handoff/switch', or `cancel'.  The names are short so the minibuffer
prompt stays readable; the descriptions are one line each.")

(defun harness-ui--handoff-choice-text ()
  "Return the handoff choices as a short, aligned list, easy to scan."
  (let* ((choices harness-ui--handoff-choices)
         (width (apply #'max (mapcar (lambda (c) (string-width (nth 1 c))) choices)))
         (fmt (format "  %%c  %%-%ds  %%s" width)))
    (mapconcat (lambda (c)
                 (format fmt (nth 0 c) (nth 1 c) (or (nth 3 c) "")))
               choices "\n")))

(defun harness-ui--check-session-label (check)
  "Return the name to show for the session a `handoff/check' CHECK is about."
  (let ((name (plist-get check :name))
        (id (or (plist-get check :id) "?")))
    (if (and (stringp name) (not (string-blank-p name)))
        (format "“%s”" name)
      (substring id 0 (min 8 (length id))))))

(defun harness-ui--handoff-text (checks label total)
  "Return what to say before a switch to model LABEL loses conversations.
CHECKS are the `handoff/check' answers of the sessions that would lose
theirs, TOTAL how many sessions the switch changes in all."
  (let* ((first (car checks))
         (one (= 1 total))
         (running (cl-some (lambda (c) (harness-json-true-p (plist-get c :running))) checks)))
    (concat
     (if one
         (format "Switching %s from %s to %s starts a new conversation.\n\n%s\n"
                 (harness-ui--check-session-label first) (harness-ui-model-label (plist-get first :from)) label
                 (plist-get first :reason))
       (format "Switching %d sessions to %s: %s start%s a new conversation there.\n\n%s\n\n%s\n"
               total label
               (if (= 1 (length checks)) "one of them" (format "%d of them" (length checks)))
               (if (= 1 (length checks)) "s" "")
               (plist-get first :reason)
               (mapconcat (lambda (c)
                            (format "  - %s, from %s%s%s"
                                    (harness-ui--check-session-label c) (harness-ui-model-label (plist-get c :from))
                                    (if (harness-json-true-p (plist-get c :running)) ", running a turn" "")
                                    (if (plist-get c :cache-cost) (format ": %s" (plist-get c :cache-cost)) "")))
                          checks "\n")))
     "\nRisks:\n"
     (mapconcat (lambda (r) (concat "  - " r)) (plist-get first :risks) "\n")
     (if (and one (plist-get first :cache-cost))
         (format "\n  At %s's list prices, this session's %s." label (plist-get first :cache-cost))
       "")
     (if running
         (if one "\n  A turn is running now." "\n  Sessions running a turn take the new model at its next step.")
       "")
     "\nHow to hand over (lossy: the new model is told to re-investigate):\n\n"
     (harness-ui--handoff-choice-text)
     (if one "" "\n\nThe choice applies to each session listed; the others just switch.")
     "\n")))

(defun harness-ui--read-handoff (checks label &optional total)
  "Ask what to do about a switch to model LABEL that loses conversations.
CHECKS are the `handoff/check' answers of the sessions that would lose
theirs; TOTAL is how many sessions the switch changes in all (default
their number).  The risks show before the question.  Return a mode of
`handoff/switch' (`compact', `compact-new', `transcript', `none') or
`cancel'."
  (let* ((total (or total (length checks)))
         (answer (read-multiple-choice
                  (format "Switch to %s" label)
                  (mapcar (lambda (c) (list (nth 0 c) (nth 1 c) (nth 3 c))) harness-ui--handoff-choices)
                  (harness-ui--handoff-text checks label total)
                  "*Harness model switch*")))
    (nth 2 (assq (car answer) harness-ui--handoff-choices))))

(defun harness-ui--handoff-outcome (label result)
  "Say how a switch to model LABEL went, from `handoff/switch''s RESULT."
  (let ((mode (format "%s" (or (plist-get result :mode) "none")))
        (file (plist-get result :file)))
    (cond
     ((plist-get result :error)
      (format "Model → %s, but the handoff failed: %s" label (plist-get result :error)))
     ((harness-json-true-p (plist-get result :deferred))
      (format "Model → %s from the running turn's next step, which takes the handoff" label))
     ((equal mode "compact") (format "Model → %s, starting from a summary of the conversation" label))
     ((equal mode "compact-new")
      (format "Model → %s, starting from a summary that model wrote from the first and last messages" label))
     ((and (equal mode "transcript") (stringp file))
      (format "Model → %s, which reads the transcript in %s first%s" label (abbreviate-file-name file)
              (if (plist-get result :fallback) " (no summary could be made)" "")))
     (t (format "Model → %s" label)))))

(defun harness-ui-switch-model (session-id model label)
  "Switch SESSION-ID to MODEL, shown as LABEL; ask first if that loses context.
The harness checks the switch (`handoff/check').  A model of another
provider that keeps its own conversation (Claude Code, Copilot) and
cannot continue this session's starts a new one that knows nothing of
it, so such a switch states its risks and offers to summarise on the
current model, to have the new model summarise a limited context, to
hand the full transcript over, to switch without handoff, or to cancel.
Any other switch happens at once."
  (let ((plain (lambda () (harness-ui--setting-set session-id :model model (format "Model → %s" label)))))
    (harness-ui-call
     "_harness/handoff/check" (list :sessionId session-id :model model)
     (lambda (check)
       (if (not (harness-json-true-p (plist-get check :lossy)))
           (funcall plain)
         (let ((mode (harness-ui--read-handoff (list check) label)))
           (if (eq mode 'cancel)
               (message "Model unchanged")
             (when (memq mode '(compact compact-new transcript))
               (message "Model → %s: %s…" label
                        (pcase mode
                          ('compact "summarising the conversation on the current model first")
                          ('compact-new "letting the new model summarise a limited context first")
                          (_ "handing the transcript over"))))
             (harness-ui-call "_harness/handoff/switch"
                              (list :sessionId session-id :model model :mode (symbol-name mode))
                              (lambda (result) (message "%s" (harness-ui--handoff-outcome label result))))))))
     ;; A harness that cannot check switches them as it always did.
     (lambda (_err) (funcall plain) nil))))

;;;###autoload
(defun harness-set-model (&optional session-id)
  "Choose a model for SESSION-ID (default the current buffer's session).
A switch that would lose the session's conversation asks first and
offers to hand it over; see `harness-ui-switch-model'."
  (interactive)
  (let ((target (harness-ui--setting-target session-id)))
    (harness-ui-choose-model
     (lambda (id label)
       (if (stringp target)
           (harness-ui-switch-model target id label)
         (harness-ui--setting-set target :model id (format "Model → %s" label)))))))

(defun harness-ui--switch-all (model label mode no-default)
  "Switch every current session to MODEL, shown as LABEL.
MODE is how the sessions that would lose their conversation hand it
over (see `handoff/switch'); `none' just switches them all.  The model
becomes the default for new sessions too, unless NO-DEFAULT."
  (unless no-default
    (harness-ui-call "_harness/config/set"
                     (list :key "harness-model" :value model :scope "global")
                     (lambda (_) nil)))
  (let ((done (lambda (ids)
                (message "Model → %s for %s session%s%s%s"
                         label (length ids) (if (= 1 (length ids)) "" "s")
                         (pcase mode
                           ('compact ", summarising the conversations that need it first")
                           ('compact-new ", letting the new model summarise a limited context where needed")
                           ('transcript ", handing the transcripts over where needed")
                           (_ ""))
                         (if no-default "" ", and for new sessions")))))
    (if (eq mode 'none)
        (harness-ui-call "_harness/session/set-all"
                         (list :settings (list :model model) :filter (list :active t))
                         done)
      (harness-ui-call "_harness/handoff/switch-all"
                       (list :model model :filter (list :active t) :mode (symbol-name mode))
                       done))))

;;;###autoload
(defun harness-set-model-all (&optional no-default)
  "Choose a model and switch every current session to it.
The choice also becomes the default for new sessions, unless a prefix
argument says otherwise.  Use this when a plan runs out, a provider
fails, or a cheaper model should take over work already in flight.
Idle, running and blocked sessions of every project change, each
recording it as a hint; inactive ones are history and are left alone,
and no running turn is cancelled: it takes the new model at its next
step.  When the switch would lose sessions their conversation (see
`harness-ui-switch-model'), it says so once for all of them, with the
risks, and the handoff chosen applies to each of them.  A session
keeps its provider state until another provider runs a step in it,
so switching back before then resumes its conversation."
  (interactive "P")
  (harness-ui-choose-model
   (lambda (id label)
     (harness-ui-call
      "_harness/handoff/check-all" (list :model id :filter (list :active t))
      (lambda (checks)
        (let* ((lossy (cl-remove-if-not (lambda (c) (harness-json-true-p (plist-get c :lossy))) checks))
               (mode (if lossy (harness-ui--read-handoff lossy label (length checks)) 'none)))
          (if (eq mode 'cancel)
              (message "Models unchanged")
            (harness-ui--switch-all id label mode no-default))))
      ;; A harness that cannot check switches them as it always did.
      (lambda (_err) (harness-ui--switch-all id label 'none no-default) nil)))))

(defconst harness-ui--thinking-level-order
  '("none" "minimal" "low" "medium" "high" "xhigh" "max")
  "Thinking levels from weakest to strongest, for ordering the menu.")

(defconst harness-ui--thinking-levels '("low" "medium" "high" "xhigh" "max")
  "The common thinking levels, weakest first.
The menu offers them to a model that names no levels of its own.")

(defun harness-ui--thinking-levels-for (levels)
  "Return the levels the thinking menu offers for a model's LEVELS.
A model that names its own levels offers exactly those, weakest first,
so it is never offered a level it cannot act on; one that names none
offers the common levels."
  (let ((rank (lambda (l) (or (cl-position l harness-ui--thinking-level-order
                                               :test #'equal)
                              most-positive-fixnum))))
    (sort (delete-dups (copy-sequence (or levels harness-ui--thinking-levels)))
          (lambda (a b) (< (funcall rank a) (funcall rank b))))))

(defun harness-ui-choose-thinking (callback &optional model)
  "Prompt for a thinking level and call CALLBACK with (VALUE LABEL).
VALUE is nil for the model default.  MODEL names the levels offered;
without one the common levels are."
  (let ((choose (lambda (levels)
                  (let* ((levels (cons "default" (harness-ui--thinking-levels-for levels)))
                         (collection (lambda (string pred action)
                                       ;; Keep the weakest-first order.
                                       (if (eq action 'metadata)
                                           '(metadata (display-sort-function . identity)
                                                      (cycle-sort-function . identity))
                                         (complete-with-action action levels string pred))))
                         (choice (completing-read "Thinking: " collection nil t)))
                    (funcall callback (unless (equal choice "default") choice) choice)))))
    (if (null model)
        (funcall choose nil)
      (harness-ui-call "_harness/provider/model" (list :model-id model)
                       (lambda (m) (funcall choose (plist-get m :thinking-levels)))))))

;;;###autoload
(defun harness-set-thinking (&optional session-id)
  "Choose a thinking level for SESSION-ID."
  (interactive)
  (let* ((target (harness-ui--setting-target session-id))
         (model (harness-ui--setting-get target :model)))
    (harness-ui-choose-thinking
     (lambda (value label)
       (harness-ui--setting-set target :thinking value (format "Thinking → %s" label)))
     model)))

;;;###autoload
(defun harness-set-thinking-all (&optional no-default)
  "Choose a thinking level and set it on every current session.
Idle, running and blocked sessions of every project change; inactive
ones are history and are left alone.  The level also becomes the
default for new sessions, unless a prefix argument says otherwise."
  (interactive "P")
  (harness-ui-choose-thinking
   (lambda (value label)
     (unless no-default
       (harness-ui-call "_harness/config/set"
                        (list :key "harness-thinking" :value (prin1-to-string value)
                              :printed t :scope "global")
                        (lambda (_) nil)))
     (harness-ui-call "_harness/session/set-all"
                      (list :settings (list :thinking value) :filter (list :active t))
                      (lambda (ids)
                        (message "Thinking → %s for %s session%s%s"
                                 label (length ids) (if (= 1 (length ids)) "" "s")
                                 (if no-default "" ", and for new sessions")))))))

;;;###autoload
(defun harness-set-permission-mode (&optional session-id)
  "Choose the permission mode for SESSION-ID."
  (interactive)
  (let* ((target (harness-ui--setting-target session-id))
         (table (mapcar (lambda (m) (cons (nth 1 m) m)) harness-ui-permission-modes))
         (completion-extra-properties
          (list :annotation-function
                (lambda (choice) (concat "  " (nth 2 (cdr (assoc choice table)))))))
         (choice (completing-read "Permission mode: "
                                  (lambda (string pred action)
                                    ;; Keep the least-to-most-permissive order.
                                    (if (eq action 'metadata)
                                        '(metadata (display-sort-function . identity)
                                                   (cycle-sort-function . identity))
                                      (complete-with-action action table string pred)))
                                  nil t)))
    (harness-ui--setting-set target :permission-mode (cadr (assoc choice table))
                             (format "Permission mode → %s" choice))))

;;;###autoload
(defun harness-toggle-non-interactive (&optional session-id)
  "Toggle non-interactive mode for SESSION-ID.
A non-interactive session never waits for the user: the auto-mode
judge decides what would ask for permission, and after a denial the
agent is told to find another way.  The session's header line shows
which it is; clicking there toggles too."
  (interactive)
  (let* ((target (harness-ui--setting-target session-id))
         (now (harness-json-true-p (harness-ui--setting-get target :non-interactive))))
    (harness-ui--setting-set target :non-interactive (not now)
                             (format "Non-interactive %s" (if now "off" "on")))))

(defun harness-ui--non-interactive-menu-label ()
  "Return the label of `harness-toggle-non-interactive' in `harness-menu'.
It says whether what the command changes from the buffer the menu was
opened from is non-interactive: the buffer's session, or what its
`harness-ui-setting-target-function' names.  From a buffer without
either the command asks for a session, so the label has no state."
  (or (ignore-errors
        (with-current-buffer (if (and (boundp 'transient--original-buffer)
                                      (buffer-live-p transient--original-buffer))
                                 transient--original-buffer
                               (current-buffer))
          (when-let* ((target (or (and harness-ui-setting-target-function
                                       (funcall harness-ui-setting-target-function))
                                  harness-ui-session-id))
                      ((or (consp target) (harness-ui-session target))))
            (format "Non-interactive: %s"
                    (if (harness-json-true-p (harness-ui--setting-get target :non-interactive)) "on" "off")))))
      "Non-interactive"))

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
  (harness-ui-display-view (get-buffer-create harness-log-buffer-name)))

;;;; Keymap, menu, global mode

(defvar harness-ui-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'harness-new-session)
    (define-key map (kbd "s") #'harness-switch-session)
    (define-key map (kbd "m") #'harness-set-model)
    (define-key map (kbd "M") #'harness-set-model-all)
    (define-key map (kbd "T") #'harness-set-thinking)
    (define-key map (kbd "H") #'harness-set-thinking-all)
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

;; At top level, not in the `defvar', so a reload binds it in a running
;; Emacs too.
(define-key harness-ui-map (kbd "i") #'harness-toggle-non-interactive)

(defvar harness-global-mode-map (make-sparse-keymap)
  "Keymap of `harness-global-mode': `harness-ui-map' under `harness-ui-prefix-key'.")

(defun harness-ui--prefix-keys (prefix)
  "Return the keys of PREFIX, a key description, or nil.
A vector of events is taken as it is: `setq' may give one, and
Customize stored one before the option took key descriptions."
  (cond ((stringp prefix) (kbd prefix))
        ((vectorp prefix) prefix)))

(defun harness-ui--set-prefix-key (symbol prefix)
  "Set SYMBOL, `harness-ui-prefix-key', to PREFIX and move the keys there.
`harness-ui-map' leaves the previous prefix in `harness-global-mode-map'
for PREFIX, so the option takes effect as soon as `setopt' or Customize
sets it, and again each time this file loads."
  (when-let* ((old (and (default-boundp symbol)
                        (harness-ui--prefix-keys (default-toplevel-value symbol)))))
    (define-key harness-global-mode-map old nil t))
  (when-let* ((new (harness-ui--prefix-keys prefix)))
    (define-key harness-global-mode-map new harness-ui-map))
  (set-default-toplevel-value symbol prefix))

(defcustom harness-ui-prefix-key "C-c h"
  "Prefix key of `harness-ui-map' in `harness-global-mode'.
A key description, as `key-valid-p' accepts.  Set with `setopt' or
Customize, it moves the keys at once; `setq' takes effect only before
the harness UI loads, that is before `harness-start'."
  :type 'key :group 'harness-ui
  :set #'harness-ui--set-prefix-key)

;;;###autoload
(define-minor-mode harness-global-mode
  "Global keybindings for the agent harness."
  :global t :group 'harness-ui :keymap harness-global-mode-map)

(defun harness-ui--command-available-p (symbol)
  (fboundp symbol))

(defun harness-ui--free-side-slot (side)
  "Return the first slot from 1 up that no window on SIDE of the frame has."
  (let ((taken (cl-loop for window in (window-list nil 'nomini)
                        when (eq (window-parameter window 'window-side) side)
                        collect (window-parameter window 'window-slot))))
    (cl-loop for slot from 1
             unless (memql slot taken) return slot)))

(defun harness-ui--bottom-windows ()
  "Return the live windows at the bottom of the selected frame, side windows all."
  (cl-remove-if-not (lambda (window) (eq (window-parameter window 'window-side) 'bottom))
                    (window-list nil 'nomini)))

(defun harness-ui--menu-lines (buffer)
  "Return about how many lines the menu BUFFER needs, its mode line included.
Transient fills the buffer before it shows it and fits the window to
it once shown, so this need only be close."
  (with-current-buffer buffer
    (max window-min-height
         (+ (count-lines (point-min) (point-max))
            (if mode-line-format 1 0)
            (if header-line-format 1 0)))))

(defun harness-ui--display-menu-below (buffer window alist)
  "Display the menu BUFFER in a new window below WINDOW and return it.
WINDOW is the only window at the bottom of the frame, such as a BTW.
The menu goes under it, as wide, in a bottom side window too: the two
share the bottom of the frame, which grows by the menu's lines.  They
come from the windows above, so WINDOW keeps its height while the menu
shows, and `harness-ui--delete-menu-below' gives them back once the
menu closes.  Return nil, the windows as they were, when the windows
above cannot spare the lines.  ALIST is the action alist."
  (let ((height (window-pixel-height window))
        (preserved (window-parameter window 'window-preserved-size))
        (lines (min (harness-ui--menu-lines buffer)
                    (window-max-delta window nil window)))
        menu)
    (when (>= lines window-min-height)
      (condition-case err
          (progn
            (window-resize window lines nil window)
            (setq menu (let ((window-combination-resize 'side)
                             (window-combination-limit t)
                             ;; WINDOW itself, even a Doom popup, whose
                             ;; `split-window' splits another window.
                             (ignore-window-parameters t))
                         (split-window window (- lines) 'below)))
            (set-window-parameter menu 'harness-ui--menu-below (list window height preserved))
            (set-window-parameter menu 'delete-window #'harness-ui--delete-menu-below)
            ;; Fixed at its height while the menu shows, so that transient
            ;; fits the menu with the lines of the windows above.
            (window-preserve-size window nil t)
            (window--display-buffer buffer menu 'window (cons '(dedicated . t) alist)))
        (error
         (harness-log 'error "harness-menu: no window below %s: %s" window (error-message-string err))
         (if (window-live-p menu)
             (delete-window menu)
           (window-resize-no-error window (- height (window-pixel-height window)) nil window t))
         nil)))))

(defun harness-ui--delete-menu-below (menu)
  "Delete MENU, a window of `harness-ui--display-menu-below', putting sizes back.
The window MENU was below gets its height back and keeps it as it did,
and the windows above get back the lines the menu took."
  (pcase-let ((`(,window ,height ,preserved) (window-parameter menu 'harness-ui--menu-below)))
    (set-window-parameter menu 'delete-window nil)
    ;; Fixed at its height, WINDOW could not take MENU's lines, and the
    ;; deletion would fail.
    (when (window-live-p window)
      (window-preserve-size window nil nil))
    (unwind-protect
        (delete-window menu)
      (when (window-live-p window)
        (unless (window-live-p menu)
          (window-resize-no-error window (- height (window-pixel-height window)) nil window t))
        (set-window-parameter window 'window-preserved-size preserved)))))

(defun harness-ui--display-menu (buffer alist)
  "Display the menu BUFFER, keeping it out of the windows around a side window.
Sessions usually live in side windows, which cannot be split.  Actions
such as `display-buffer-below-selected' then fall back to reusing
another window, which transient fits horizontally to the menu and
cannot delete afterwards, wrecking the layout.  So from a side window
the menu gets a side window of its own across the bottom of the frame,
in a slot no window has: given a window's slot,
`display-buffer-in-side-window' shows the menu in that window, the
selected one included, and transient deletes the window as the menu
closes.  When a window is at the bottom already, such as a BTW, the
menu goes below it (`harness-ui--display-menu-below'): beside it, the
menu would be cut to its height, and above everything it would be far
from where menus open.  Only when several windows share the bottom,
below one of which a window is not a valid side window, or the windows
above have no lines to spare, does the menu go to the top.  Elsewhere
the menu follows `transient-display-buffer-action'.  ALIST is the
action alist."
  (if (window-parameter (selected-window) 'window-side)
      (let ((bottom (harness-ui--bottom-windows)))
        (or (and (= (length bottom) 1)
                 (harness-ui--display-menu-below buffer (car bottom) alist))
            (let ((side (if bottom 'top 'bottom)))
              (display-buffer-in-side-window
               buffer (append `((side . ,side) (slot . ,(harness-ui--free-side-slot side)) (dedicated . t))
                              alist)))))
    (display-buffer buffer transient-display-buffer-action)))

;;;;; The commands of the buffer the menu is opened from

;; A mode lists its own commands for `harness-menu' in its
;; `harness-menu-group' property, (TITLE COLUMN...):
;;
;;   (put 'harness-chat-mode 'harness-menu-group
;;        '("Chat"
;;          ["Message"
;;           ("C-c C-c" "Send" harness-chat-send)
;;           ...]
;;          ...))
;;
;; The menu shows them under TITLE when it is opened from a buffer in
;; that major mode, or in a mode derived from it, or with that minor
;; mode on.  Each COLUMN is a group vector as in
;; `transient-define-prefix': a heading, then suffixes (KEY DESCRIPTION
;; COMMAND . PROPERTIES), which run in the buffer with point where it
;; was.  The menu's own groups take the plain keys, so list a command
;; the buffer binds to a plain key behind `.', followed by that key
;; (". s" for a board's `s'), and one bound to a key with a modifier,
;; such as the chat's chords, under that key: the menu then teaches the
;; buffer's own keys.  The menu leaves out a suffix whose command is not
;; defined, one whose key its own groups use, and one whose key a mode
;; with precedence in the buffer shows already: minor modes before the
;; major mode, as in the buffer's keymaps.
;;
;; A property set with `put' at the top level of the module, not a call
;; to a function of this file: `harness-reload' loads the other UI
;; files before this one, and a property needs nothing loaded.  Setting
;; it again replaces the commands, so a reload updates them.

(defun harness-ui--major-mode-lineage ()
  "Return the current major mode and the modes it derives from, nearest first."
  (let ((mode major-mode) lineage)
    (while (and mode (symbolp mode) (not (memq mode lineage)))
      (push mode lineage)
      (setq mode (get mode 'derived-mode-parent)))
    (nreverse lineage)))

(defun harness-ui--menu-modes ()
  "Return the modes whose `harness-menu-group' this buffer gets.
The minor modes on in it come first, then its major mode and the modes
that one derives from: the order in which their keymaps take
precedence in the buffer."
  (append (cl-remove-if-not (lambda (mode)
                              (and (get mode 'harness-menu-group) (boundp mode) (symbol-value mode)))
                            minor-mode-list)
          (cl-remove-if-not (lambda (mode) (get mode 'harness-menu-group))
                            (harness-ui--major-mode-lineage))))

(defun harness-ui--menu-key-taken-p (key)
  "Non-nil when the groups of `harness-menu' use KEY or a prefix of it.
KEY is a key description such as \". s\"."
  (let ((events (kbd key)))
    (cl-loop for i from 1 to (length events)
             thereis (ignore-errors
                       (transient-get-suffix 'harness-menu (key-description (substring events 0 i)))))))

(defun harness-ui--menu-column (column taken)
  "Return COLUMN without the suffixes `harness-menu' cannot offer, or nil.
Those run an undefined command, or have a key the menu's own groups
use or one in TAKEN, a hash table of the keys offered already.  The
keys kept are added to TAKEN.  Where transient can, the keys are padded
to line up."
  (let ((items (append column nil)) kept head offered)
    (when (integerp (car items)) (push (pop items) head))
    (when (stringp (car items)) (push (pop items) head))
    (while items
      (let ((item (pop items)))
        (if (keywordp item)
            (progn (push item kept) (when items (push (pop items) kept)))
          (let ((key (and (consp item) (stringp (car item))
                          (ignore-errors (key-description (kbd (car item))))))
                (command (and (consp item) (nth 2 item))))
            (when (and key command
                       (or (not (symbolp command)) (fboundp command))
                       (not (gethash key taken))
                       (not (harness-ui--menu-key-taken-p key)))
              (puthash key t taken)
              (push item kept)
              (setq offered t))))))
    (when offered
      (vconcat (nreverse head)
               (and (slot-exists-p 'transient-column 'pad-keys) '(:pad-keys t))
               (nreverse kept)))))

(defvar harness-ui--menu-heading nil
  "Heading of the buffer's commands in `harness-menu', set as it opens.")

(defun harness-ui--menu-buffer-columns ()
  "Return the parsed columns of commands of this buffer, setting the heading.
They are nil when none of the buffer's modes has a `harness-menu-group'.
A column that fails to parse is logged and left out."
  (let ((taken (make-hash-table :test 'equal))
        shown)
    (dolist (mode (harness-ui--menu-modes))
      (pcase-let ((`(,title . ,columns) (get mode 'harness-menu-group)))
        (when-let* ((parsed
                     (cl-mapcan
                      (lambda (column)
                        (when-let* ((column (harness-ui--menu-column column taken)))
                          (condition-case err
                              (transient-parse-suffixes 'harness-menu (list column))
                            (error (harness-log 'error "harness-menu: %s commands: %s"
                                                mode (error-message-string err))
                                   nil))))
                      columns)))
          (push (cons title parsed) shown))))
    ;; Shown the other way round: the major mode's commands, then the minor modes'.
    (setq harness-ui--menu-heading (mapconcat #'car shown " · "))
    (cl-mapcan #'cdr shown)))

(defun harness-ui--menu-buffer-children (_children)
  "Return the columns of commands `harness-menu' shows for this buffer.
The menu calls this as it opens (`:setup-children'), in the buffer it
is opened from; with nil the group is left out.  An error is logged and
leaves the buffer's commands out, never the whole menu."
  (condition-case err
      (harness-ui--menu-buffer-columns)
    (error (harness-log 'error "harness-menu: the buffer's commands: %s" (error-message-string err))
           nil)))

(transient-define-prefix harness-menu ()
  "The harness menu."
  :display-action '(harness-ui--display-menu (inhibit-same-window . t))
  [["Sessions"
    ("n" "New session" harness-new-session)
    ("s" "Switch session" harness-switch-session)
    ("l" "Session list" harness-sessions :if (lambda () (harness-ui--command-available-p 'harness-sessions)))
    ("a" "Task mode" harness-tasks :if (lambda () (harness-ui--command-available-p 'harness-tasks)))
    ("t" "Conversation tree" harness-tree :if (lambda () (harness-ui--command-available-p 'harness-tree)))
    ("b" "BTW side conversation" harness-btw :if (lambda () (harness-ui--command-available-p 'harness-btw)))
    ("f" "Fork session" harness-fork-session)
    ("k" "Cancel turn" harness-cancel-turn)
    ("D" "Delete session" harness-delete-session)]
   ["Session settings"
    ("m" "Model" harness-set-model)
    ("M" "Model for all sessions" harness-set-model-all)
    ("T" "Thinking" harness-set-thinking)
    ("H" "Thinking for all sessions" harness-set-thinking-all)
    ("p" "Permission mode" harness-set-permission-mode)
    ("d" "Directory access" harness-directories :if (lambda () (harness-ui--command-available-p 'harness-directories)))
    ("i" (lambda () (harness-ui--non-interactive-menu-label)) harness-toggle-non-interactive)
    ("r" "Rename" harness-rename-session)]
   ["Tools"
    ("u" "Usage & cost" harness-usage :if (lambda () (harness-ui--command-available-p 'harness-usage)))
    ("w" "Worktrees" harness-worktrees :if (lambda () (harness-ui--command-available-p 'harness-worktrees)))
    ("S" "Settings" harness-settings :if (lambda () (harness-ui--command-available-p 'harness-settings)))
    ("c" "Connect remote" harness-connect-remote :inapt-if harness-corporate-p)
    ("P" "Remote control" harness-remote-control
     :if (lambda () (harness-ui--command-available-p 'harness-remote-control))
     :inapt-if harness-corporate-p)
    ("N" "Test notifications" harness-test-notifications)
    ("R" "Reload harness" harness-reload)
    ("L" "Log" harness-show-log)]]
  ;; The commands of the buffer the menu is opened from, when its modes
  ;; list some in their `harness-menu-group'.
  [:class transient-columns
   :description (lambda () harness-ui--menu-heading)
   :setup-children harness-ui--menu-buffer-children])

;;;; Module

(defun harness-ui--on-reloaded ()
  (run-hooks 'harness-ui-redraw-hook))

(defun harness-ui--init ()
  (add-hook 'kill-emacs-hook #'harness-ui--stop-server)
  (add-hook 'harness-corporate-mode-change-hook #'harness-ui--corporate-mode-changed)
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
