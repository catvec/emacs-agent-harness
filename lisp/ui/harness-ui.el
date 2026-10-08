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
;;   session, or a group of them such as a board's tasks, cost: a price
;;   when it is billed per token, the plan's name and quota when a
;;   subscription pays for it; and those that show budgets;
;; - faces and icons;
;; - window positions: one session per preset position, replacing, and
;;   the fullscreen layout, an overview such as the task board on the
;;   left of the frame and the session it inspects beside it;
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
(require 'harness-emacs-endpoint)
(require 'harness-files)
(require 'harness-notifications-desktop)
(require 'harness-ui-drag)

(defvar harness-directory)

(declare-function harness-reload "harness")
(declare-function harness-tasks "harness-ui-tasks")
(declare-function harness-sessions "harness-ui-sessions")
(declare-function harness-ui-notify-show-waiting "harness-ui-notify")

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

(defface harness-compose-message-face
  '((((background light)) :background "#fdf0d5" :extend t)
    (((background dark)) :background "#3a3222" :extend t))
  "The composition area of a message to an existing session.
A colour of its own, so a box that sends to a session cannot be taken
for the one that composes a new task." :group 'harness-ui)

(defface harness-compose-message-accent-face '((t :inherit warning))
  "The prompt and bar of a compose box that sends to an existing session." :group 'harness-ui)

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
(harness-ui-define-icon harness-icon-question "question" "?" "?" "A question.")
(harness-ui-define-icon harness-icon-warning "warning" "!" "error" "An error.")
(harness-ui-define-icon harness-icon-success "success" "●" "ok" "Success: a circle, green.")
(harness-ui-define-icon harness-icon-caution "caution" "●" "~"
                        "A warning, or work in progress: a circle, yellow.")
(harness-ui-define-icon harness-icon-failure "failure" "▲" "!" "A failure: a triangle, red.")

(defvar harness-ui--icons (make-hash-table :test 'equal)
  "Icon strings made by `harness-ui-icon', by (NAME GRAPHIC IMAGES FONT).
Each value is (STAMP . STRING), STAMP saying what the string was made
from (`harness-ui--icon-stamp').")

(defun harness-ui--icon-stamp (name)
  "Return what the string of icon NAME is made from, as of now.
Its definition, its spec in the custom theme and `icon-preference': a
reload redefines the icon, and a theme or the user may change the rest.
A theme changes its spec in place, so the stamp holds copies."
  (list (get name 'icon--properties) (copy-tree (get name 'theme-icon))
        (copy-sequence icon-preference)))

(defun harness-ui--icon-stamp-current-p (stamp name)
  "Non-nil when STAMP is what icon NAME is made from now."
  (and (eq (nth 0 stamp) (get name 'icon--properties))
       (equal (nth 1 stamp) (get name 'theme-icon))
       (equal (nth 2 stamp) icon-preference)))

(defun harness-ui-icon (name)
  "Return the string for icon NAME (a symbol such as `harness-icon-idle').
An image icon carries no `:background', so its transparent parts show
the face behind it (a tool block's colour, say).  Some packages, such as
solaire-mode, bake the buffer's base colour into every image.

Header and mode lines are drawn again on every key typed in their
window, and making an icon reads its file and asks the fonts, so each
icon is made once for each kind of display and frame font, and reused
while it is defined the same way (`harness-ui--icon-stamp').  The
string is a copy: a caller may add properties to it."
  (let* ((key (list name (display-graphic-p) (display-images-p) (frame-parameter nil 'font)))
         (made (gethash key harness-ui--icons)))
    (if (and made (harness-ui--icon-stamp-current-p (car made) name))
        (copy-sequence (cdr made))
      (condition-case nil
          (let* ((stamp (harness-ui--icon-stamp name))
                 (s (icon-string name))
                 (spec (and (> (length s) 0) (get-text-property 0 'display s)))
                 (s (if (and (eq (car-safe spec) 'image) (plist-member (cdr spec) :background))
                        (propertize s 'display (cons 'image (harness-ui--plist-without (cdr spec) :background)))
                      s)))
            (puthash key (cons stamp s) harness-ui--icons)
            (copy-sequence s))
        (error "")))))

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
  (harness-ui--let-go)
  (setq harness-ui-connection-address address)
  (if (eq address 'process)
      (if harness-ui--server-address
          (harness-ui--open (car harness-ui--server-address) (cdr harness-ui--server-address))
        (harness-ui--ensure-server)
        nil)
    (harness-ui--open address nil)))

(defun harness-ui--let-go ()
  "Close the UI's connection, if any, as one replaced on purpose.
What was pending on it is rejected with the reason \"replaced\" (see
`harness-ui-connection-replaced-p'): the harness keeps running it, the
UI just no longer hears the answer, so nobody reports it as failed.  A
request from the harness that waits for an answer, such as a
permission prompt, cannot be answered through its old RESPOND any
more; the session keeps it pending, and the chat answers it with
`permission/answer' instead."
  (when harness-ui-connection
    (ignore-errors (harness-acp-close harness-ui-connection "replaced")))
  (setq harness-ui-connection nil))

(defun harness-ui-connection-replaced-p (err)
  "Non-nil when ERR failed a request only because the UI replaced its connection.
The UI connects again on purpose (`harness-connect-remote', a corporate
mode change): requests still waiting for an answer on the connection
it let go of are rejected with this, and are no failure to report.
They reached the harness or never left, as the transcript shows."
  (equal (harness-acp-closed-reason err) "replaced"))

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
    ;; This Emacs lends itself to the harness: its tools about the
    ;; user's Emacs ask it (lisp/harness-emacs-endpoint.el).
    (harness-then (harness-acp-initialize conn (harness-emacs-endpoint-client-capabilities))
                  (lambda (_)
                    (harness-ui-refresh-sessions)
                    (harness-ui-refresh-models)
                    (harness-ui-refresh-quotas)
                    (harness-ui-refresh-rates)
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
Errors are shown in the echo area unless ON-ERROR handles them, but
for those of a connection the UI replaced on purpose
\(`harness-ui-connection-replaced-p'), which are not failures."
  (harness-then (harness-ui-request method params)
                callback
                (or on-error
                    (lambda (e)
                      (unless (harness-ui-connection-replaced-p e)
                        (message "Harness: %s failed: %s" method (harness-error-message e)))
                      nil))))

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
          harness-ui--server-stopping nil)
    (let (proc)
      (setq proc (harness-server-spawn
                  :on-address (lambda (address token)
                                ;; One replaced before it listened is nobody to talk to.
                                (when (eq proc harness-ui--server)
                                  (setq harness-ui--server-address (cons address token))
                                  (when (eq harness-ui-connection-address 'process)
                                    (harness-ui--open address token)
                                    (run-hooks 'harness-ui-redraw-hook))))
                  :on-exit #'harness-ui--on-server-exit)
            harness-ui--server proc)))))

(defun harness-ui--on-server-exit (status &optional proc)
  "React to the harness process PROC ending with STATUS: restart it unless stopped.
The end of a process the UI no longer runs is not news: a process
stopped for a restart may be reported gone after its successor
started, and must neither make the UI forget that one nor start a
third."
  (when (or (null proc) (eq proc harness-ui--server))
    (harness-ui--on-current-server-exit status)))

(defun harness-ui--on-current-server-exit (status)
  "React to the UI's harness process ending with STATUS: restart it unless stopped."
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
                     (lambda (_) (message "Harness process reloaded"))
                     (lambda (e) (message "Harness process: %s" (harness-error-message e))))))

(defun harness-ui--advertise ()
  "Tell the harness again what this Emacs lends it, as `initialize' did.
After a reload, so that a connection opened by older code, which lent
nothing, lends this Emacs from now on."
  (when (harness-acp-open-p harness-ui-connection)
    (harness-catch (harness-acp-initialize harness-ui-connection
                                           (harness-emacs-endpoint-client-capabilities))
                   (lambda (e) (harness-log 'warn "ui: advertising this Emacs failed: %s"
                                            (harness-error-message e))))))

(defun harness-ui--dispatch (method params respond)
  "Route an incoming METHOD with PARAMS; RESPOND is non-nil for requests.
The harness's requests for this Emacs, which it lent the harness, are
answered by `harness-emacs-endpoint-answer'; everything else is the UI's."
  (unless (harness-emacs-endpoint-answer method params respond)
    (harness-ui--dispatch-ui method params respond)))

(defun harness-ui--dispatch-ui (method params respond)
  "Route METHOD with PARAMS to the UI; RESPOND is non-nil for requests."
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
         (funcall respond (harness-emacs-endpoint-customize-save (plist-get params :symbol) (plist-get params :value)))
       (error (harness-acp-respond-error respond -32000 (error-message-string err)))))
    ("_harness/client/notify"
     (harness-then (harness-ui--show-notification params)
                   (lambda (shown) (funcall respond shown) nil)
                   (lambda (err) (harness-acp-respond-error respond -32000 (harness-error-message err)) nil)))
    ("_harness/event"
     (let ((event (plist-get params :event)) (args (plist-get params :args)))
       (when (equal event "tools/file-written")
         (harness-emacs-endpoint-revert-visiting (car args)))
       (when (member event '("session/created" "session/deleted"))
         (harness-ui-refresh-sessions))
       (when (equal event "harness/reloaded")
         ;; Reloaded code may label its tools anew: views fetch them again.
         (harness-ui--forget-tools)
         (harness-ui--advertise)
         (run-hooks 'harness-ui-redraw-hook))
       (when (member event '("provider/models-updated" "harness/reloaded"))
         (harness-ui-refresh-models))
       (when (equal event "provider/quota-updated")
         (harness-ui--store-quota (car args) (cadr args)))
       (when (equal event "usage/rate-updated")
         (harness-ui--store-rate (car args) (cadr args)))
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

(defun harness-ui--raise-for-notification ()
  "Bring a graphical frame of this Emacs to the front, for a notification click.
The user just asked to see what the notification is about."
  (let ((frame (if (display-graphic-p (selected-frame))
                   (selected-frame)
                 (cl-find-if #'display-graphic-p (frame-list)))))
    (when (and frame (frame-live-p frame))
      (harness-ignore-errors-logged "showing the frame for a notification"
        (select-frame-set-input-focus frame)))))

(defun harness-ui--notification-clicked (params)
  "Show what the clicked notification PARAMS is about.
`harness-ui-notification-functions' come first (the task board opens
on a task); otherwise the notification's session opens.  The frame it
opens in comes to the front, as the user just asked for it."
  (harness-ui--raise-for-notification)
  (unless (run-hook-with-args-until-success 'harness-ui-notification-functions params)
    (when-let* ((sid (plist-get params :session)))
      (harness-ui-display-session sid))))

(defun harness-ui--unknown-notification-clicked ()
  "Show the sessions waiting for you, for a click on a forgotten notification.
macOS keeps notifications in its Notification Center after the Emacs
that showed them restarted, so a click can name one this Emacs never
showed (`harness-notifications-desktop-unknown-click-function').  The
sessions waiting for you show as the mode line's notifier shows them
\(`harness-ui-notify-show-waiting'), else the session list."
  (harness-ui--raise-for-notification)
  (cond ((fboundp 'harness-ui-notify-show-waiting) (harness-ui-notify-show-waiting))
        ((fboundp 'harness-sessions) (call-interactively 'harness-sessions))))

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
      (harness-ui--let-go)
      (setq harness-ui-connection-address (harness-ui--local-address)))
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
  (harness-ui--store-rate id nil)
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

(defun harness-ui-task-name (task &optional session)
  "Return TASK's name, or nil while it has none and its title is its prompt.
That is the name of its SESSION, by default the cached session it works
in, else the task's own `:name': the title a cheap model gave it as it
was submitted, which it has while it waits for a slot, before it has a
session to name."
  (let ((name (plist-get (or session
                             (and (plist-get task :session) (harness-ui-session (plist-get task :session))))
                         :name)))
    (cond ((not (harness-string-blank-p name)) name)
          ((not (harness-string-blank-p (plist-get task :name))) (plist-get task :name)))))

(defun harness-ui-task-title (task &optional session)
  "Return TASK's title, as the task board shows it.
That is its name (`harness-ui-task-name', SESSION's or its own) once it
has one, else the first line of its prompt: a task is named as soon as
it is submitted, and its title shows its prompt only until the name
comes, or when naming it failed."
  (or (harness-ui-task-name task session)
      (harness-first-line (plist-get task :prompt) 72)))

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

;;;; Output rate cache

;; The harness measures how fast each session's model writes (see
;; `usage/rate' in harness-usage.el); the UI keeps the latest figure of
;; each session, fetched on connect and then updated from
;; `usage/rate-updated' events.

(defvar harness-ui--rates (make-hash-table :test 'equal)
  "Session id -> its output rate, the plist `usage/rate' returns.")

(defvar harness-ui-rate-functions nil
  "Functions called with (SESSION-ID RATE) after a cached output rate changes.
SESSION-ID is nil after the whole cache was fetched again.")

(defun harness-ui-session-rate (id)
  "Return the cached output rate of session ID, or nil if it was never measured.
The plist is (:rate F :output N :seconds F :calls N :at FLOAT :model ID),
as `usage/rate' returns it."
  (gethash id harness-ui--rates))

(defun harness-ui--store-rate (id rate)
  "Cache RATE as session ID's output rate; run `harness-ui-rate-functions'."
  (when (stringp id)
    (if rate (puthash id rate harness-ui--rates) (remhash id harness-ui--rates))
    (run-hook-with-args 'harness-ui-rate-functions id rate)))

(defun harness-ui-refresh-rates (&optional callback)
  "Fetch the output rate of every session into the cache, then call CALLBACK."
  (harness-ui-call "_harness/usage/rates" nil
                   (lambda (rates)
                     (clrhash harness-ui--rates)
                     (dolist (rate rates)
                       (when-let* ((id (plist-get rate :session)))
                         (puthash id (harness-plist-remove rate :session) harness-ui--rates)))
                     (run-hook-with-args 'harness-ui-rate-functions nil nil)
                     (when callback (funcall callback rates)))
                   #'ignore))

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

(defun harness-ui-format-clock (time &optional now)
  "Return TIME as a clock time, \"14:05\", with its day unless that is NOW's.
NOW defaults to the current time."
  (if (equal (format-time-string "%F" time) (format-time-string "%F" (or now (float-time))))
      (format-time-string "%H:%M" time)
    (format-time-string "%b %-d, %H:%M" time)))

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

(defun harness-ui-spend-help (session &optional subject)
  "Return the tooltip that explains what SESSION cost and who pays for it.
SUBJECT names what cost it, \"This session\" by default.  One line, so
showing it in the echo area moves nothing."
  (let* ((subject (or subject "This session"))
         (usage (plist-get session :usage))
         (quota (harness-ui-session-quota session))
         (billing (harness-ui-session-billing session))
         (cost (float (or (plist-get usage :cost) 0)))
         (covered (harness-usage-covered usage))
         (payer (harness-ui-plan-title quota (plist-get usage :plan))))
    (harness-ui-one-line
     (string-join
      (delq nil
            (append
             (list
              (cond ((and (> covered 0) (> cost 0))
                     (format "%s billed%s; %s more at API prices covered by %s."
                             (harness-format-cost cost) (if (eq billing 'extra-usage) " as extra usage" "")
                             (harness-format-cost covered) payer))
                    ((or (> covered 0) (memq billing '(subscription extra-usage)))
                     (format "Covered by %s, not billed per token. %s at API prices: %s."
                             payer subject (harness-format-cost covered)))
                    ((eq billing 'api)
                     (format "%s cost %s, billed per token%s."
                             subject (harness-format-cost cost)
                             (if-let* ((auth (plist-get quota :auth))) (format " (%s)" auth) "")))
                    (t (format "%s cost %s." subject (harness-format-cost cost)))))
             (when (memq billing '(subscription extra-usage))
               (append (mapcar #'harness-ui-describe-window (plist-get quota :windows))
                       (list (harness-ui-describe-extra (plist-get quota :extra)))))
             (list "mouse-1: usage and plan quota")))
      "\n"))))

(defun harness-ui-format-spend (session &optional with-quota subject)
  "Return what SESSION cost, saying when a subscription pays for it.
Per-token billing shows the cost (\"$1.20\").  When a plan pays, its
name shows instead (\"Max\"), after any cost billed as extra usage
\(\"$0.40+Max\").  WITH-QUOTA appends the plan's headline quota windows
\(\"Max · 5h 9% · 7d 57%\").  The tooltip has the details, where
SUBJECT names what cost it (see `harness-ui-spend-help').  SESSION may
stand for several (`harness-ui-sessions-total')."
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
                'help-echo (harness-ui-spend-help session subject))))

(defun harness-ui-sessions-total (sessions &optional model)
  "Return SESSIONS taken together, as a session for the spend helpers.
Its `:usage' sums theirs, and has the `:billing' and `:plan' of the one
updated last that recorded a billing, as a session's are those of its
last call.  Its `:model' is MODEL, else the first session's: that
provider's billing and quota stand for them all."
  (let ((usage (list :input 0 :output 0 :cache-read 0 :cache-write 0 :cost 0.0 :list-cost 0.0))
        (latest nil))
    (dolist (s sessions)
      (let ((u (plist-get s :usage)))
        (dolist (k '(:input :output :cache-read :cache-write :cost))
          (setq usage (plist-put usage k (+ (plist-get usage k) (or (plist-get u k) 0)))))
        (setq usage (plist-put usage :list-cost (+ (plist-get usage :list-cost) (harness-usage-list-cost u))))
        (when (and (harness-billing-of u)
                   (or (null latest) (> (or (plist-get s :updated) 0) (or (plist-get latest :updated) 0))))
          (setq latest s))))
    (when latest
      (let ((u (plist-get latest :usage)))
        (setq usage (append usage (list :billing (plist-get u :billing) :plan (plist-get u :plan))))))
    (list :model (or model (plist-get (car sessions) :model)) :usage usage)))

(declare-function harness-usage "harness-ui-usage")

(defun harness-ui-show-usage ()
  "Show the usage dashboard: costs, the plan's quota and the budgets."
  (interactive)
  (if (fboundp 'harness-usage)
      (harness-usage)
    (user-error "The usage dashboard (module ui-usage) is not loaded")))

(defvar harness-ui--usage-keymap nil
  "Keymap of the segments that open the usage dashboard, made once.")

(defun harness-ui-spend-segment (text)
  "Return TEXT, from `harness-ui-format-spend', as a header-line segment.
A click on it opens the usage dashboard.  Its percentages are escaped,
or the line would take the \"9% \" of a quota window for a %-construct."
  (let ((text (harness-ui-mode-line-escape text)))
    (add-text-properties 0 (length text)
                         (list 'mouse-face 'mode-line-highlight
                               'local-map (or harness-ui--usage-keymap
                                              (setq harness-ui--usage-keymap
                                                    (harness-ui-mouse-keymap #'harness-ui-show-usage))))
                         text)
    text))

;;;; Budgets

(defun harness-ui-budget-label (budget)
  "Return a label for BUDGET: its own, else how often and what it covers."
  (or (plist-get budget :label)
      (let* ((scope (format "%s" (plist-get budget :scope)))
             (target (plist-get budget :target))
             (subject (cond ((equal scope "session")
                             (let ((s (harness-ui-session target)))
                               (or (and s (plist-get s :name))
                                   (format "session %s" (substring (or target "?") 0 (min 8 (length (or target "?"))))))))
                            (target (file-name-nondirectory (directory-file-name target)))
                            (t "everything"))))
        (string-trim (format "%s %s" (pcase (format "%s" (plist-get budget :period))
                                       ("day" "daily") ("week" "weekly") ("month" "monthly") (_ ""))
                             subject)))))

(defun harness-ui-budgets-by-use (statuses)
  "Return budget STATUSES sorted by how much of each is spent, fullest first."
  (sort (copy-sequence statuses)
        (lambda (a b) (> (or (plist-get a :fraction) 0) (or (plist-get b :fraction) 0)))))

(defun harness-ui-budget-spent (status &optional all)
  "Return \"$25.00 of $100.00 spent\" for budget STATUS, and what it includes.
What it includes is what the harness did not record, which
`harness-budget-outside-text' says, given ALL: \"$25.00 of $100.00
spent, incl. $5.00 reported by Claude, $20.00 baseline\"."
  (let ((outside (harness-budget-outside-text status all)))
    (concat (format "%s of %s spent" (harness-format-cost (plist-get status :spent))
                    (harness-format-cost (plist-get status :amount)))
            (if outside (concat ", " outside) ""))))

(defun harness-ui-budget-pace (status)
  "Return what budget STATUS allows per day for the days it has left.
That reads \"$3.75/day · 20 days left\"; nil for a budget without a period."
  (when (plist-get status :per-day)
    (let ((days (plist-get status :days-left)))
      (format "%s/day · %s day%s left" (harness-format-cost (plist-get status :per-day))
              (or days "?") (if (eql days 1) "" "s")))))

(defun harness-ui-describe-budget (status)
  "Return a sentence about budget STATUS: what it covers, what is spent and left."
  (let ((pace (harness-ui-budget-pace status)))
    (format "%s: %s; %s left%s%s."
            (harness-ui-budget-label (plist-get status :budget))
            (harness-ui-budget-spent status)
            (harness-format-cost (max 0 (or (plist-get status :remaining) 0)))
            (if pace (concat ", " pace) "")
            (if (harness-json-true-p (plist-get status :hard)) " (hard)" ""))))

(defun harness-ui-format-budgets (statuses)
  "Return \"budget 62%\" for the fullest of budget STATUSES, nil for none.
It is coloured as a quota window is; its tooltip describes each budget,
on one line (see `harness-ui-one-line')."
  (when statuses
    (let* ((sorted (harness-ui-budgets-by-use statuses))
           (used (float (or (plist-get (car sorted) :fraction) 0))))
      (propertize (format "budget %d%%" (round (* 100 used)))
                  'face (harness-ui-quota-face used)
                  'help-echo (harness-ui-one-line
                              (string-join (append (mapcar #'harness-ui-describe-budget sorted)
                                                   (list "mouse-1: usage and budgets"))
                                           "\n"))))))

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

(defconst harness-ui--fallback-context-window 200000
  "Context window assumed while a session's is not known.
The harness gives every session one, estimated where no provider sizes
its model; this is the default of `harness-provider-fallback-context-window'
there, which estimates fall back to.")

(defun harness-ui-context-face (context window)
  "Return the warning face for CONTEXT tokens against WINDOW."
  (let* ((reserve harness-ui--context-reserve)
         (limit (max 1 (- (or window harness-ui--fallback-context-window) reserve)))
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

(defun harness-ui-one-line (text)
  "Return TEXT on one line, its runs of whitespace collapsed to a space.
Hover text belongs on one line: shown in the echo area where tooltips
are off, a second line grows the mini window, which shrinks every other
window in the frame and moves the button under the mouse until it is
hard to click.  Build `help-echo' text from parts through this."
  (replace-regexp-in-string "[ \t\n\r]+" " " (string-trim (or text ""))))

(defun harness-ui-format-context (session)
  "Return \"12.3k/200k\" for SESSION with the warning face applied."
  (let* ((usage (plist-get session :usage))
         (context (or (plist-get usage :context) 0))
         (window (plist-get session :context-window)))
    (propertize (format "%s/%s" (harness-format-tokens context) (harness-format-tokens window))
                'face (harness-ui-context-face context window)
                'help-echo "Context tokens in use / context window")))

(defun harness-ui-format-model-window (model)
  "Return the context window of catalogue entry MODEL as text: \"200k\".
A window the catalogue estimated, as its provider does not give it,
reads \"~200k\"."
  (concat (if (eq t (plist-get model :context-window-estimated)) "~" "")
          (harness-format-tokens (plist-get model :context-window))))

(defun harness-ui-format-rate-number (rate)
  "Return RATE, in tokens per second, as a short number: 4.8, 48 or 1.2k."
  (cond ((< rate 9.95) (format "%.1f" rate))
        ((< rate 999.5) (format "%d" (round rate)))
        (t (format "%.1fk" (/ rate 1000.0)))))

(defun harness-ui-rate-help (rate &optional live)
  "Return the one-line tooltip of output RATE, a plist as `usage/rate' gives.
LIVE non-nil says that the session is running, so RATE is its current one."
  (let* ((calls (or (plist-get rate :calls) 1))
         (at (plist-get rate :at))
         (today (and at (equal (format-time-string "%F" at) (format-time-string "%F")))))
    (harness-ui-one-line
     (format "%s %s tokens per second, %s output tokens in %s of streaming over %s on %s%s. Waiting for the first token and running tools do not count."
             (if live "Output rate:" "Last output rate:")
             (harness-ui-format-rate-number (or (plist-get rate :rate) 0))
             (harness-format-tokens (plist-get rate :output))
             (harness-format-duration (or (plist-get rate :seconds) 0))
             (if (= calls 1) "the latest model call" (format "the %d latest model calls" calls))
             (harness-ui-model-label (plist-get rate :model))
             (if at (format-time-string (if today ", measured at %H:%M" ", measured on %F %H:%M") at) "")))))

(defun harness-ui-format-rate (session &optional bare)
  "Return how fast SESSION's model writes, as \"48 tok/s\", or nil if unmeasured.
BARE leaves out the unit.  While SESSION runs this is its current rate;
otherwise it is the last one measured, dimmed.  The tooltip gives the
details."
  (when-let* ((id (plist-get session :id))
              (rate (harness-ui-session-rate id))
              (value (plist-get rate :rate)))
    (let ((live (equal (plist-get session :status) "running")))
      (propertize (concat (harness-ui-format-rate-number value) (if bare "" " tok/s"))
                  'face (and (not live) 'harness-dim-face)
                  'help-echo (harness-ui-rate-help rate live)))))

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
        ;; Not (interactive "e"), which signals for RET, an event without
        ;; parameters.
        (run (lambda (&optional event)
               (interactive (list last-input-event))
               (when (and event (mouse-event-p event))
                 (ignore-errors (select-window (posn-window (event-start event)))))
               (call-interactively command))))
    (dolist (key '([mouse-1] [mouse-2] [header-line mouse-1] [header-line mouse-2]
                   [mode-line mouse-1] [mode-line mouse-2]))
      (define-key map key run))
    (define-key map (kbd "RET") run)
    map))

;;;; Items at point

;; Views that show sessions -- the session list, the task board, the tree
;; -- say which session the item at point stands for.  One notion of "the
;; session at point" then serves every command that acts on it, such as
;; popping out what it waits on.

(defvar-local harness-ui-session-at-point-function nil
  "Function returning the session id of the item at point, or nil.
A view sets it buffer-locally, so commands shared by views (the popout
of what a session waits on) act on what point is on there.  Without it,
`harness-ui-session-at-point' falls back to `harness-ui-session-id'.")

(defun harness-ui-session-at-point (&optional noerror)
  "Return the session id the item at point stands for.
That is what `harness-ui-session-at-point-function' says in a view that
sets one, else this buffer's session (`harness-ui-session-id').  Signal
unless NOERROR when there is none."
  (or (and harness-ui-session-at-point-function
           (funcall harness-ui-session-at-point-function))
      harness-ui-session-id
      (unless noerror (user-error "No session here"))))

;;;; Drawing helpers shared by the views
;;
;; Chat panels, popouts and the task board all draw the same kind of
;; thing: text with action buttons in it, key hints, images, and regions
;; that are redrawn in place without moving point or the windows.

(defface harness-ui-panel-face
  '((((background light)) :background "#d9f7fd" :extend t)
    (((background dark)) :background "#143c42" :extend t))
  "Background of a panel asking the user for something.
The chat's permission and question panels, and a popout of a request.
A cool teal of its own: it stands apart from the transcript's blocks and
the queue under it, and asks for an answer without the alarm of a
warning colour." :group 'harness-ui)

(defface harness-ui-key-face '((t :inherit help-key-binding))
  "Keyboard shortcut hints in panels." :group 'harness-ui)

(defface harness-ui-output-face '((t :inherit (fixed-pitch harness-md-code-block)))
  "Fixed-width output, such as the diagram of a question's option." :group 'harness-ui)

(defcustom harness-ui-image-max-height 400
  "Maximum pixel height of inline images in harness views."
  :type 'integer :group 'harness-ui)

(defun harness-ui-add-face (string face)
  "Return STRING with FACE added on top of its faces."
  (let ((s (copy-sequence string)))
    (add-face-text-property 0 (length s) face t s)
    s))

(defun harness-ui-ensure-newline (string)
  "Return STRING ending in exactly one newline."
  (concat (string-trim-right (or string "") "\n+") "\n"))

(defun harness-ui-kbd (key)
  "Return KEY as a key hint string."
  (propertize key 'face 'harness-ui-key-face))

(defun harness-ui-action-map (command)
  "Return a keymap running COMMAND on mouse-1, mouse-2 and RET."
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] command)
    (define-key map [mouse-2] command)
    (define-key map (kbd "RET") command)
    map))

(defun harness-ui-action-button (label action &rest props)
  "Return a button string LABEL running ACTION (a function of no arguments).
PROPS may hold `:help' and `:face'.  Clicking or pressing RET on it
anywhere runs the action (`harness-ui-action-push')."
  (let ((s (copy-sequence label)))
    (add-text-properties
     0 (length s)
     (list 'face (or (plist-get props :face) 'button)
           'mouse-face 'highlight 'follow-link t 'pointer 'hand
           'help-echo (plist-get props :help)
           'harness-ui-action action
           'keymap (harness-ui-action-map #'harness-ui-action-push))
     s)
    s))

(defun harness-ui-action-push (&optional event)
  "Run the action of the button at point, or at the position of mouse EVENT."
  (interactive (list last-input-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let ((action (or (get-text-property (point) 'harness-ui-action)
                    (and (> (point) (point-min)) (get-text-property (1- (point)) 'harness-ui-action)))))
    (if action (funcall action) (if (get-text-property (point) 'button) (push-button (point))
                                  (user-error "No button here")))))

(defun harness-ui-add-keymap (start end map)
  "Give START..END the keymap MAP, composed under any button keymaps."
  (let ((pos start))
    (while (< pos end)
      (let* ((next (min end (or (next-single-property-change pos 'keymap nil end) end)))
             (existing (get-text-property pos 'keymap)))
        (put-text-property pos next 'keymap (if existing (make-composed-keymap (list existing map)) map))
        (setq pos next)))))

(defun harness-ui--fix-positions (fix pt windows)
  "Move point to (FIX PT) and every window in WINDOWS through FIX.
WINDOWS holds (WINDOW START POINT) triples recorded before the edit."
  (goto-char (funcall fix pt))
  (dolist (w windows)
    (when (window-live-p (car w))
      (set-window-start (car w) (funcall fix (nth 1 w)) t)
      (unless (eq (car w) (selected-window))
        (set-window-point (car w) (funcall fix (nth 2 w)))))))

(defun harness-ui--window-positions ()
  "Return (WINDOW START POINT) for every window showing the buffer."
  (mapcar (lambda (w) (list w (window-start w) (window-point w)))
          (get-buffer-window-list nil nil t)))

(defun harness-ui-replace-region (from to text)
  "Replace FROM..TO with TEXT, keeping point and window starts anchored.
Positions inside the region stay at the same offset from FROM; the
position just after the region moves to the end of TEXT."
  (let* ((from (if (markerp from) (marker-position from) from))
         (to (if (markerp to) (marker-position to) to))
         (len (length text))
         (fix (lambda (p)
                (cond ((< p from) p)
                      ((< p to) (min p (+ from (max 0 (1- len)))))
                      ((= p to) (+ from len))
                      (t (+ p (- len (- to from)))))))
         (windows (harness-ui--window-positions))
         (pt (point)))
    (let ((inhibit-read-only t) (buffer-undo-list t))
      (delete-region from to)
      (goto-char from)
      (insert text))
    (harness-ui--fix-positions fix pt windows)))

(defun harness-ui-image-string (source &optional mime)
  "Return a string displaying SOURCE (a path or a (:data BASE64) plist).
MIME is a hint for the image type.  The image can be dragged into
another application (`harness-ui-drag-props').  Without image support,
and for a path on a remote host, which reading here would block on, a
button opening the file is returned instead."
  (let* ((path (and (stringp source) source))
         (data (and (consp source) (plist-get source :data)))
         (label (if path (format "[image %s]" (abbreviate-file-name path)) "[image]"))
         (local (and path (not (file-remote-p path))))
         (open (and path (lambda () (interactive) (find-file-other-window path))))
         (img (and (display-images-p) (or data (and local (file-readable-p path)))
                   (let* ((w (car (get-buffer-window-list nil nil t)))
                          (width (floor (* 0.6 (if w (window-body-width w t) 800)))))
                     (condition-case nil
                         (if data
                             (create-image (base64-decode-string data) nil t
                                           :max-width width :max-height harness-ui-image-max-height)
                           (create-image path nil nil
                                         :max-width width :max-height harness-ui-image-max-height))
                       (error nil))))))
    (cond
     (img (concat (apply #'propertize label 'display img
                         (harness-ui-drag-props
                          (list 'pointer 'hand
                                'help-echo (if open (format "mouse-1 or RET: open %s" path) mime)
                                'keymap (and open (harness-ui-action-map open)))
                          path))
                  "\n"))
     (open (concat (harness-ui-action-button label open :help (format "Open %s" path)) "\n"))
     (t (concat (propertize label 'face 'harness-dim-face) "\n")))))

(defun harness-ui-format-value (value)
  "Return VALUE for display in a tool input listing."
  (cond ((stringp value) value)
        ((eq value :false) "false")
        ((eq value t) "true")
        ((null value) "null")
        ((numberp value) (number-to-string value))
        (t (format "%S" value))))

(defun harness-ui-option-label (value)
  "Return the label of VALUE, an option of an ask_user call, or nil.
An option is a string or an object (a plist) with a `:label'."
  (cond ((stringp value) value)
        ((and (consp value) (keywordp (car value)) (stringp (plist-get value :label)))
         (plist-get value :label))))

(defun harness-ui-summary-value (value)
  "Return VALUE on one line for a tool input summary.
A list of strings, or of objects with labels such as the options of an
ask_user call, reads as a comma-separated list, and a list of other
objects, such as the items of a todo list, as how many there are: not
as a Lisp form."
  (harness-first-line
   (cond ((and (or (consp value) (vectorp value)) (cl-every #'harness-ui-option-label value))
          (mapconcat #'harness-ui-option-label value ", "))
         ((and (or (consp value) (vectorp value)) (not (keywordp (car (append value nil))))
               (cl-every (lambda (v) (and (consp v) (keywordp (car v)))) value))
          (let ((n (length value))) (format "%d item%s" n (if (= n 1) "" "s"))))
         (t (harness-ui-format-value value)))
   60))

(defun harness-ui-tool-input-summary (input &optional title)
  "Return a one-line summary of tool INPUT, or nil when it adds nothing.
Values TITLE already shows (the command of a bash call, the question
of an ask_user) are left out."
  (let (parts)
    (cl-loop for (k v) on input by #'cddr
             do (let ((text (harness-ui-summary-value v)))
                  (unless (and title (not (string-empty-p text))
                               (string-search (substring text 0 (min 40 (length text))) title))
                    (push (format "%s: %s" (substring (symbol-name k) 1) text) parts))))
    (and parts (harness-truncate-end (string-join (nreverse parts) "  ") 110))))

;;;; Layout

;; A view decides whether its text fits a window -- whether a buffer
;; ends above the bottom, whether a board leaves room for its compose
;; box -- by measuring it with `harness-ui-text-height'.
;;
;; A header line is not the buffer's text: it is drawn by the mode line
;; machinery, and one wider than its window is simply cut at the right
;; edge, which is where a view puts its buttons and its keys.  Views
;; therefore build a header from segments with priorities and fit it
;; with `harness-ui-fit-header'.

(defun harness-ui-header-width (&optional window)
  "Return the room WINDOW's header line has, in its units.
WINDOW defaults to the narrowest visible window showing the current
buffer, and to the selected window when none does: one header line is
drawn in every window showing a buffer, so it is fitted to the least
room any of them gives, which fits them all.  Pixels on a graphic
frame, columns on a text terminal."
  (let ((w (or window
               (car (sort (get-buffer-window-list (current-buffer) nil t)
                          (lambda (a b) (< (window-pixel-width a) (window-pixel-width b)))))
               (selected-window))))
    (if (display-graphic-p (window-frame w))
        (- (window-pixel-width w)
           (or (window-scroll-bar-width w) 0)
           (or (window-right-divider-width w) 0))
      (window-body-width w))))

(defun harness-ui-header-string-width (string)
  "Return how wide STRING shows in a header line of the selected window.
Pixels on a graphic frame, measured in the `header-line' face so icons
and a header font of another size count; columns on a text terminal."
  (if (display-graphic-p)
      (let ((s (copy-sequence string)))
        (add-face-text-property 0 (length s) 'header-line t s)
        (if (fboundp 'string-pixel-width) (string-pixel-width s) (* (frame-char-width) (string-width s))))
    (string-width string)))

(defun harness-ui-fit-header (segments &optional width)
  "Return the header line made of SEGMENTS, fitted to WIDTH.
SEGMENTS are in display order, each a string or (TEXT PRIORITY MIN):

- TEXT, with the separator in front of it, such as \"  Model (Claude)\",
  so that a segment which goes takes its separator with it;
- PRIORITY, higher for a segment more worth keeping, or t to keep it
  always;
- MIN, optional: the same segment shortened, shown when the line still
  does not fit without it.

When the whole line is wider than WIDTH, segments make room lowest
priority first, and the rightmost first among equals, until the rest
fits.  A segment with MIN, a session or project name, shortens to its
shortened form before it goes: only when even that leaves the line too
wide is it dropped.  A segment whose priority is t is never dropped,
only shortened.  What cannot be made to fit is left to the window,
which cuts it as usual.

WIDTH defaults to the room of the selected window, which is the window
whose header line is drawn while a `header-line-format' `:eval' form
runs.  When everything fits this is one measurement, so it can run on
every redisplay."
  (let* ((items (cl-loop for s in segments
                         for i from 0
                         for text = (if (consp s) (car s) s)
                         when (and text (stringp text) (not (string-empty-p text)))
                         collect (list :index i :text text
                                       :priority (if (consp s) (nth 1 s) t)
                                       :min (and (consp s) (nth 2 s)))))
         (width (or width (harness-ui-header-width)))
         (whole (mapconcat (lambda (it) (plist-get it :text)) items ""))
         (total (harness-ui-header-string-width whole)))
    (if (<= total width)
        whole
      (let ((droppable (sort (cl-remove-if-not (lambda (it) (numberp (plist-get it :priority)))
                                               (copy-sequence items))
                             (lambda (a b) (or (< (plist-get a :priority) (plist-get b :priority))
                                               (and (= (plist-get a :priority) (plist-get b :priority))
                                                    (> (plist-get a :index) (plist-get b :index))))))))
        ;; The least important segments go first, one at a time, and no
        ;; more of them than the window needs.  One with a shortened form
        ;; takes it first and goes only when it is not enough: a name is
        ;; worth a few columns even when the model and the counts are not.
        (while (and droppable (> total width))
          (let ((it (pop droppable)))
            (when-let* ((min (plist-get it :min)))
              (let ((was (harness-ui-header-string-width (plist-get it :text))))
                (plist-put it :text min)
                (cl-decf total (- was (harness-ui-header-string-width min)))))
            (when (> total width)
              (cl-decf total (harness-ui-header-string-width (plist-get it :text)))
              (setq items (delq it items)))))
        ;; What may not be dropped, a segment a mode puts in front of the
        ;; session's own, shortens too: nothing else is left to give.
        (dolist (it (reverse items))
          (when (and (> total width) (plist-get it :min))
            (let ((was (harness-ui-header-string-width (plist-get it :text))))
              (plist-put it :text (plist-get it :min))
              (cl-decf total (- was (harness-ui-header-string-width (plist-get it :text)))))))
        (mapconcat (lambda (it) (plist-get it :text)) items "")))))

(defun harness-ui-text-height (window from to limit)
  "Return how many pixels the text from FROM to TO takes in WINDOW.
The value is exact while it is LIMIT or less, and more than LIMIT for
text that takes more, so comparing it with LIMIT tells whether the text
fits.  Measuring stops about LIMIT pixels in, however long the text.
The current buffer must be WINDOW's; on a text terminal a pixel is a
line.

`window-text-pixel-size' with a Y-LIMIT cannot tell: for text taller
than the limit it returns where the line crossing the limit starts,
which is the limit or less whenever that line is cut, so text that
overflows the window reads as text that fits."
  (let ((lines (+ 2 (/ limit (max 1 (frame-char-height (window-frame window))))))
        (height nil))
    ;; A screen line at the default height or more, as most are, fills
    ;; LIMIT within the first round; lines of a smaller face take more.
    (while (null height)
      (let* ((end (save-excursion (goto-char from) (vertical-motion lines window) (point)))
             ;; To a line's start, the line counts: never more than the text.
             (h (cdr (window-text-pixel-size window from (min end to)))))
        (if (or (>= end to) (> h limit))
            (setq height h)
          (setq lines (* 2 lines)))))
    height))

;;;; Positions

(defcustom harness-ui-positions
  '((right . ((side . right) (slot . 0) (window-width . 0.45)))
    (left . ((side . left) (slot . 0) (window-width . 0.45)))
    (bottom . ((side . bottom) (slot . 0) (window-height . 0.45)))
    (full . nil)
    (other . nil)
    (fullscreen . nil))
  "Named positions a session can be displayed in.
Side-window positions carry `display-buffer-in-side-window' parameters;
`full' takes over the selected window; `other' pops up anywhere;
`fullscreen' is the fullscreen layout of an overview such as the task
board (see `harness-fullscreen'): the overview on the left of the frame,
everything else beside it."
  :type '(alist :key-type symbol :value-type sexp) :group 'harness-ui)

(defcustom harness-ui-default-position 'right
  "Position used when a session is opened without an explicit one."
  :type 'symbol :group 'harness-ui)

(defvar harness-ui--position-buffers (make-hash-table :test 'eq)
  "Position -> buffer currently shown there.")

(defvar harness-ui-open-session-function nil
  "Function returning the buffer that shows session ID: (ID) → buffer.
Set by the chat module.")

(defvar-local harness-ui-position nil "Position this buffer was displayed in.")

(defun harness-ui-display-buffer (buffer &optional position)
  "Show BUFFER in POSITION, replacing whatever session occupied it.
In a frame with the fullscreen layout POSITION defaults to `fullscreen',
and a position elsewhere leaves the layout's windows alone."
  (let ((position (or position
                      (and (harness-ui--fullscreen-layout) 'fullscreen)
                      harness-ui-default-position)))
    (if (eq position 'fullscreen)
        (harness-ui--display-fullscreen buffer)
      (let* ((params (alist-get position harness-ui-positions))
             (previous (gethash position harness-ui--position-buffers))
             (window (and previous (buffer-live-p previous) (get-buffer-window previous))))
        (puthash position buffer harness-ui--position-buffers)
        (cond
         ((and window (window-live-p window) (not (eq previous buffer))
               (not (harness-ui--fullscreen-window-p window)))
          (set-window-buffer window buffer)
          (select-window window))
         ((eq position 'full) (switch-to-buffer buffer))
         ((eq position 'other) (pop-to-buffer buffer))
         (params
          (select-window (display-buffer-in-side-window buffer params)))
         (t (pop-to-buffer buffer)))))
    (with-current-buffer buffer (setq-local harness-ui-position position))
    buffer))

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
`harness-ui-default-position'; in a frame with the fullscreen layout it
shows beside the overview, or as the overview when it is one.  Small
transient windows (menus, help, the BTW overlay) do not go through here."
  (harness-ui-display-buffer buffer (or position
                                        (and (harness-ui--fullscreen-layout) 'fullscreen)
                                        (buffer-local-value 'harness-ui-position buffer)
                                        harness-ui-default-position)))

(defun harness-ui-session-opener (&optional position)
  "Return a function of a session id that shows it where this view is.
Call this when the command runs and the returned function later, from
an asynchronous callback: the session takes POSITION, by default the
current buffer's position (replacing the view) -- in a frame with the
fullscreen layout, the window beside the overview -- and opens from the
window selected now even when another frame is selected by then."
  (let ((position (or position
                      (and (harness-ui--fullscreen-layout) 'fullscreen)
                      harness-ui-position
                      harness-ui-default-position))
        (window (selected-window)))
    (lambda (id)
      (when (window-live-p window) (select-window window))
      (harness-ui-display-session id position))))

(defun harness-ui-read-position ()
  "Read a position name with completion."
  (intern (completing-read "Position: " (mapcar (lambda (p) (symbol-name (car p))) harness-ui-positions) nil t)))

;;;; Visiting a session in its project
;;
;; A view listing the sessions of every project -- the session list the
;; mode line's notifier opens on the sessions waiting for you -- opens a
;; session where it belongs: it switches to the session's project first,
;; as switching project would (Doom Emacs's workspaces), and then shows
;; the session, unless it shows there already, in which case its window
;; is selected.

(defvar +workspaces-switch-project-function)
(declare-function +workspaces-switch-to-project-h "ext:workspaces")
(declare-function +workspace-current-name "ext:workspaces")
(declare-function doom-project-name "ext:doom-projects")
(declare-function doom-project-p "ext:doom-projects")

(defcustom harness-ui-switch-project-function #'harness-ui-switch-project-workspace
  "Function switching to a project before a session of it shows, or nil.
It is called with the project's root directory when a session is
visited (`harness-ui-visit-session'), from the session list say, and
returns non-nil when it switched; when that project is current already
it does nothing and returns nil.  The root is the main checkout of the
session's project: a task's git worktree belongs to its repository's.
The default switches workspaces where there are any; nil never
switches."
  :type '(choice (const :tag "Never switch" nil)
                 (function-item harness-ui-switch-project-workspace)
                 function)
  :group 'harness-ui)

(defun harness-ui-switch-project-workspace (root)
  "Switch to the workspace of the project at ROOT, if there are workspaces.
That is Doom Emacs's workspaces, on with `persp-mode': the project's
workspace becomes current, made when it has none, as switching project
makes it, but without asking for a file to open.  Return non-nil when
the workspace changed.  Without workspaces this does nothing: a buffer
belongs to no project.  Nor does a ROOT that is no project, a scratch
directory say, which would only get a workspace of its own."
  (when (and (bound-and-true-p persp-mode)
             (fboundp '+workspaces-switch-to-project-h)
             (fboundp '+workspace-current-name)
             (fboundp 'doom-project-name)
             (fboundp 'doom-project-p)
             (doom-project-p root)
             (not (equal (+workspace-current-name) (doom-project-name root))))
    (let ((+workspaces-switch-project-function #'ignore))
      (+workspaces-switch-to-project-h root))
    t))

(defun harness-ui-session-project (session)
  "Return the main checkout of SESSION's project, or nil.
A task's git worktree belongs to its repository's main checkout (see
`harness-files-owning-checkout').  A remote project gives nil, and so
does one missing from this machine, as a remote harness's may be."
  (let ((root (or (plist-get session :project) (plist-get session :cwd))))
    (when (and (stringp root) (not (string-empty-p root)) (not (file-remote-p root)))
      (let ((main (harness-files-owning-checkout root)))
        (and main (file-directory-p main) main)))))

(defun harness-ui-switch-to-session-project (id)
  "Switch to the project of session ID; return non-nil when it switched.
See `harness-ui-switch-project-function'.  A switch that fails is
logged, and leaves things as they are."
  (when-let* ((fn harness-ui-switch-project-function)
              (root (harness-ui-session-project (harness-ui-session id))))
    (harness-ignore-errors-logged (format "switching to the project %s" root)
      (funcall fn root))))

(defun harness-ui-visit-session (id &optional position)
  "Show session ID in its project, and return its buffer.
First switch to its project (`harness-ui-switch-to-session-project'),
then show the session: a window of the selected frame -- of the
project's workspace, after a switch -- that shows it already is
selected, and otherwise it opens in POSITION.  POSITION defaults to the
current buffer's own, as `harness-ui-session-opener' has it, and after a
switch, which leaves the current buffer's window behind, to where
sessions open (`harness-ui-default-position')."
  (unless harness-ui-open-session-function
    (user-error "No chat module loaded"))
  (let* ((here (or position
                   (and (harness-ui--fullscreen-layout) 'fullscreen)
                   harness-ui-position
                   harness-ui-default-position))
         (position (if (harness-ui-switch-to-session-project id) position here))
         (buffer (funcall harness-ui-open-session-function id))
         (window (get-buffer-window buffer)))
    (if (window-live-p window)
        (progn (select-window window) buffer)
      (harness-ui-display-buffer buffer position))))

;;;; Fullscreen layout
;;
;; An overview -- the task board, the session list -- can take the whole
;; frame: it stays on the left, in a side window, and the session it
;; inspects shows beside it, in a window of the frame's own (the slot).
;; Sessions opened from the overview take the slot, and so does anything
;; else shown without a position while the layout lasts.  Burying the
;; buffer in the slot (`harness-ui-bury') brings back what the slot showed
;; before -- the file the session took the place of -- and the layout
;; stays: the next session opened from the overview takes the slot again.
;; Burying the overview ends the layout, and the windows come back as
;; they were, but for a buffer of the user's left in the slot, which
;; stays in sight.
;;
;; The layout is kept per frame, in a weak table rather than a frame
;; parameter, which `frameset' would try to save.  It lasts as long as
;; its overview's window, however that window goes.

(defcustom harness-ui-fullscreen-width 0.5
  "Width of the overview in the fullscreen layout.
A fraction of the frame's width, or a number of columns."
  :type 'number :group 'harness-ui)

(defvar-local harness-ui-overview-function nil
  "Function returning the session to show beside this overview, or nil.
A view that sets it buffer-locally is an overview, which can take the
fullscreen layout (`harness-fullscreen').  When the layout starts with
no session in sight, the session whose id it returns shows beside the
overview: the one at point, say, else the most recent the view lists.
It is called in the overview's buffer.")

(cl-defstruct (harness-ui--fullscreen (:constructor harness-ui--fullscreen-create)
                                      (:copier nil))
  "The fullscreen layout of a frame."
  (overview nil :documentation "The side window of the overview.")
  (slot nil :documentation "The window beside it, where sessions show.")
  (home nil :documentation "The slot as the layout started.")
  (saved nil :documentation "The window configuration of the frame from before.")
  (positions nil :documentation "Alist of the overviews shown and their positions from before."))

(defvar harness-ui--fullscreen-layouts (make-hash-table :test 'eq :weakness 'key)
  "Frame -> its fullscreen layout, a `harness-ui--fullscreen'.")

(defun harness-ui--fullscreen-layout (&optional frame)
  "Return the fullscreen layout of FRAME, by default the selected one, or nil.
There is none once the overview's window is gone."
  (let ((layout (gethash (or frame (selected-frame)) harness-ui--fullscreen-layouts)))
    (and layout (window-live-p (harness-ui--fullscreen-overview layout)) layout)))

(defun harness-ui-overview-p (buffer)
  "Non-nil when BUFFER is an overview (see `harness-ui-overview-function')."
  (and (buffer-live-p buffer) (buffer-local-value 'harness-ui-overview-function buffer) t))

(defun harness-ui--overview-window-p (window)
  "Non-nil when WINDOW is the overview's in the fullscreen layout of its frame."
  (let ((layout (harness-ui--fullscreen-layout (window-frame window))))
    (and layout (eq window (harness-ui--fullscreen-overview layout)))))

(defun harness-ui--fullscreen-window-p (window)
  "Non-nil when WINDOW is the overview's or the slot of a fullscreen layout."
  (let ((layout (harness-ui--fullscreen-layout (window-frame window))))
    (and layout (memq window (list (harness-ui--fullscreen-overview layout)
                                   (harness-ui--fullscreen-slot layout)))
         t)))

(defun harness-ui--harness-buffer-p (buffer)
  "Non-nil when BUFFER is the harness's, a session or a view, not the user's."
  (with-current-buffer buffer
    (or harness-ui-session-id harness-ui-position
        (string-prefix-p "harness-" (symbol-name major-mode)))))

(defun harness-ui--main-window (&optional frame)
  "Return the most recently used window of FRAME that is not a side window."
  (let (best)
    (dolist (window (window-list frame 'nomini) best)
      (unless (or (window-parameter window 'window-side)
                  (and best (<= (window-use-time window) (window-use-time best))))
        (setq best window)))))

(defun harness-ui--fullscreen-window (layout)
  "Return the window beside LAYOUT's overview, where sessions show.
Once that window is gone, the frame's most recently used window that is
not a side window takes its place."
  (let ((slot (harness-ui--fullscreen-slot layout)))
    (unless (and (window-live-p slot) (not (window-parameter slot 'window-side)))
      (setf slot (harness-ui--main-window (window-frame (harness-ui--fullscreen-overview layout)))
            (harness-ui--fullscreen-slot layout) slot))
    slot))

(defun harness-ui--session-window-p (window)
  "Non-nil when WINDOW shows a session's chat, a BTW's aside."
  (with-current-buffer (window-buffer window)
    (and harness-ui-session-id
         (derived-mode-p 'harness-chat-mode)
         (not (bound-and-true-p harness-ui-btw-minor-mode)))))

(defun harness-ui--fullscreen-session (overview frame)
  "Return the buffer to show beside OVERVIEW as FRAME takes its layout, or nil.
That is the session in sight in FRAME, the most recently used window's,
else the one OVERVIEW's `harness-ui-overview-function' names."
  (let (shown)
    (dolist (window (window-list frame 'nomini))
      (when (and (harness-ui--session-window-p window)
                 (or (null shown) (> (window-use-time window) (window-use-time shown))))
        (setq shown window)))
    (if shown
        (window-buffer shown)
      (when-let* ((function (buffer-local-value 'harness-ui-overview-function overview))
                  (id (with-current-buffer overview (funcall function)))
                  ((functionp harness-ui-open-session-function)))
        (funcall harness-ui-open-session-function id)))))

(defun harness-ui--previous-buffer (window buffer)
  "Return what WINDOW is to show instead of BUFFER, as (BUFFER START POINT).
That is the last buffer WINDOW showed before that is the user's, not the
harness's, else the user's most recent buffer out of sight, else any
other buffer.  START and POINT may be missing."
  (let* ((frame (window-frame window))
         (usable (lambda (b)
                   (and (buffer-live-p b) (not (eq b buffer))
                        (not (string-prefix-p " " (buffer-name b)))
                        (not (harness-ui--harness-buffer-p b))))))
    (or (cl-find-if (lambda (entry) (funcall usable (car entry))) (window-prev-buffers window))
        (list (or (cl-find-if (lambda (b) (and (funcall usable b) (not (get-buffer-window b frame))))
                              (buffer-list frame))
                  (other-buffer buffer t frame))))))

(defun harness-ui--show-previous (window buffer)
  "Show in WINDOW what it showed before BUFFER (`harness-ui--previous-buffer')."
  (apply #'set-window-buffer-start-and-point window (harness-ui--previous-buffer window buffer)))

(defun harness-ui--show-in-slot (window buffer)
  "Show BUFFER in WINDOW, the slot of a fullscreen layout."
  (unless (eq (window-buffer window) buffer)
    (set-window-buffer window buffer))
  (with-current-buffer buffer (setq-local harness-ui-position 'fullscreen)))

(defun harness-ui--fullscreen-params ()
  "Return the side-window parameters of the overview in the fullscreen layout."
  `((side . left) (slot . -1) (window-width . ,harness-ui-fullscreen-width)
    (preserve-size . (t . nil))
    ;; C-x 1 in the slot keeps the overview.
    (window-parameters . ((no-delete-other-windows . t)))))

(defun harness-ui--note-overview (layout buffer)
  "Remember in LAYOUT the position the overview BUFFER had before it."
  (unless (assq buffer (harness-ui--fullscreen-positions layout))
    (push (cons buffer (let ((position (buffer-local-value 'harness-ui-position buffer)))
                         (and (not (eq position 'fullscreen)) position)))
          (harness-ui--fullscreen-positions layout))))

(defun harness-ui--fullscreen-enter (overview)
  "Give the selected frame the fullscreen layout of the buffer OVERVIEW.
Every window of the frame makes way for the overview but one, the slot,
which shows the session in sight or the one OVERVIEW names, else what
it showed.  Return the overview's window."
  (let* ((frame (selected-frame))
         (session (harness-ui--fullscreen-session overview frame))
         (shown (and session (get-buffer-window session frame)))
         (slot (if (and shown (not (window-parameter shown 'window-side)))
                   shown
                 (harness-ui--main-window frame)))
         (saved (current-window-configuration frame))
         window)
    ;; The side windows go too: a BTW, a popout, the overview's own.
    (let ((ignore-window-parameters t))
      (delete-other-windows slot))
    (set-window-dedicated-p slot nil)
    (setq window (display-buffer-in-side-window overview (harness-ui--fullscreen-params)))
    (unless window
      (set-window-configuration saved)
      (user-error "This frame has no room for the overview"))
    (let ((layout (harness-ui--fullscreen-create :overview window :slot slot :home slot :saved saved)))
      (harness-ui--note-overview layout overview)
      (puthash frame layout harness-ui--fullscreen-layouts))
    (cond (session (harness-ui--show-in-slot slot session))
          ((eq (window-buffer slot) overview) (harness-ui--show-previous slot overview)))
    window))

(defun harness-ui--display-fullscreen (buffer)
  "Show BUFFER in the fullscreen layout of the selected frame, and select it.
An overview takes the left of the frame, starting the layout when the
frame has none; anything else takes the slot beside the overview, or
without the layout the selected window, as in the `full' position."
  (let ((layout (harness-ui--fullscreen-layout)))
    (cond
     ((and layout (harness-ui-overview-p buffer))
      (let ((window (harness-ui--fullscreen-overview layout))
            (slot (harness-ui--fullscreen-window layout)))
        (unless (eq (window-buffer window) buffer)
          (harness-ui--note-overview layout buffer)
          (set-window-buffer window buffer)
          ;; A new buffer drops the side window's dedication.
          (set-window-dedicated-p window 'side))
        (when (eq (window-buffer slot) buffer)
          (harness-ui--show-previous slot buffer))
        (select-window window)))
     ((harness-ui-overview-p buffer)
      (select-window (harness-ui--fullscreen-enter buffer)))
     (layout
      (let ((slot (harness-ui--fullscreen-window layout)))
        (harness-ui--show-in-slot slot buffer)
        (select-window slot)))
     (t (switch-to-buffer buffer)))))

(defun harness-ui--fullscreen-leave (&optional frame bury)
  "End the fullscreen layout of FRAME, by default the selected one.
The windows come back as they were before it, but for a buffer of the
user's in the slot, such as a file visited there, which stays in sight
in the window the layout kept.  The overviews it showed get back their
positions.  With BURY the overview goes out of sight too."
  (when-let* ((frame (or frame (selected-frame)))
              (layout (harness-ui--fullscreen-layout frame)))
    (let* ((overview (window-buffer (harness-ui--fullscreen-overview layout)))
           (slot (harness-ui--fullscreen-window layout))
           (home (harness-ui--fullscreen-home layout))
           (kept (unless (harness-ui--harness-buffer-p (window-buffer slot))
                   (list (window-buffer slot) (window-start slot) (window-point slot)))))
      (remhash frame harness-ui--fullscreen-layouts)
      (pcase-dolist (`(,buffer . ,position) (harness-ui--fullscreen-positions layout))
        (when (and (buffer-live-p buffer) (eq (buffer-local-value 'harness-ui-position buffer) 'fullscreen))
          (with-current-buffer buffer (setq-local harness-ui-position position))))
      (set-window-configuration (harness-ui--fullscreen-saved layout))
      (when (and kept (buffer-live-p (car kept)) (window-live-p home)
                 (not (eq (window-buffer home) (car kept))))
        (apply #'set-window-buffer-start-and-point home kept))
      (when bury
        (dolist (window (get-buffer-window-list overview 'nomini frame))
          (if (window-parameter window 'window-side)
              (delete-window window)
            (harness-ui--show-previous window overview)))
        (bury-buffer-internal overview)))))

;;;###autoload
(defun harness-fullscreen ()
  "Start or end the fullscreen layout of an overview in the selected frame.
The overview -- the task board, the session list -- takes the left of
the frame, and the session you inspect shows beside it: the one in
sight, else the overview's choice, the session at point or the most
recent.  The sessions you open from the overview take its place, and
so does anything else shown without a position while the layout lasts.

\\<harness-chat-mode-map>Burying the buffer beside the overview
\(`harness-ui-bury', \\[harness-ui-bury] in a session) brings back what was there
before and keeps the layout; burying the overview (q on it) ends the
layout, and the windows come back as they were.  This command ends it
too, run in the overview or in a buffer that is not one.  Run in
another overview, that one takes the left instead.

Without the layout, the overview is this buffer when it is one, else
the one shown last, else the task board of this project, else the
session list."
  (interactive)
  (let ((layout (harness-ui--fullscreen-layout))
        (here (current-buffer)))
    (cond
     ((and layout (harness-ui-overview-p here) (not (harness-ui--overview-window-p (selected-window))))
      (harness-ui-display-buffer here 'fullscreen))
     (layout (harness-ui--fullscreen-leave))
     ((harness-ui-overview-p here) (harness-ui-display-buffer here 'fullscreen))
     ((cl-find-if #'harness-ui-overview-p (buffer-list (selected-frame)))
      (harness-ui-display-buffer (cl-find-if #'harness-ui-overview-p (buffer-list (selected-frame)))
                                 'fullscreen))
     ((fboundp 'harness-tasks) (harness-tasks nil 'fullscreen))
     ((fboundp 'harness-sessions) (harness-sessions nil 'fullscreen))
     (t (user-error "No overview to show")))))

(defun harness-ui-quit-view ()
  "Quit the window of this view, as `quit-window' does.
On the overview of the fullscreen layout, this buries the overview and
ends the layout: the windows come back as they were."
  (interactive)
  (if (harness-ui--overview-window-p (selected-window))
      (harness-ui--fullscreen-leave nil t)
    (quit-window)))

(defun harness-ui-bury ()
  "Put this buffer out of sight, bringing back what its window showed before.
In a window of the frame's own -- the one beside the overview of the
fullscreen layout, say -- that is the last buffer the window showed
that is not the harness's: the file a session took the place of.  The
layout stays, and the next session opened from the overview takes the
window back.  A side window, such as a session's in the `right'
position, quits as `quit-window' would.  On the overview of the
fullscreen layout this ends the layout, as `harness-ui-quit-view' does."
  (interactive)
  (let* ((window (selected-window))
         (buffer (window-buffer window)))
    (cond
     ((harness-ui--overview-window-p window) (harness-ui--fullscreen-leave nil t))
     ((or (window-parameter window 'window-side) (eq (window-dedicated-p window) t))
      (quit-window nil window))
     (t (harness-ui--show-previous window buffer)
        (unrecord-window-buffer window buffer)
        (bury-buffer-internal buffer)))))

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
available is offered.  An empty answer chooses nothing: CALLBACK is
not called."
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
                               (harness-ui-format-model-window m)
                               (if-let* ((p (plist-get m :pricing)))
                                   (format " · $%s/$%s per M" (plist-get p :input) (plist-get p :output))
                                 ""))))))
            (choice (completing-read "Model: " table nil t))
            (model (cdr (assoc choice table))))
       ;; A required match still lets an empty answer through, which
       ;; names no model: switching to it would clear every model.
       (if (not model)
           (message "No model chosen")
         (funcall callback (plist-get model :id) choice))))))

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
prompt stays readable; the descriptions are one line each.  The one of
`compact' holds while the cache is warm; `harness-ui--handoff-choices-for'
says otherwise once it is not.")

(defun harness-ui--handoff-cache (check now)
  "Return how CHECK's session finds the cache of the model it switches from.
`warm' while the prompt cache its requests last used is that model's
and lasts at NOW, `expired' once it lapsed, `other' when it is another
model's (the session switched since), nil when nothing is known.  See
`handoff/check''s `:cache'."
  (let* ((cache (plist-get check :cache))
         (expires (plist-get cache :expires))
         (from (plist-get check :from)))
    (when (numberp expires)
      (cond ((not (equal (or (plist-get cache :model) from) from)) 'other)
            ((< now expires) 'warm)
            (t 'expired)))))

(defun harness-ui--handoff-compact-text (checks &optional now)
  "Describe summarising on the current model for the sessions of CHECKS.
That reads each conversation back from the model's prompt cache, cheap
while the cache lasts; once it lapsed, or is another model's, the whole
conversation is paid for again uncached.  Return the description when
a cache is cold at NOW (default the current time), else nil: the usual
one holds."
  (let* ((now (or now (float-time)))
         (states (mapcar (lambda (c) (harness-ui--handoff-cache c now)) checks))
         (cold (cl-count-if (lambda (s) (memq s '(expired other))) states))
         (n (length checks)))
    (cond
     ((= cold 0) nil)
     ((< cold n) (format "re-reads it all uncached where the cache lapsed (%d of %d)" cold n))
     ((> n 1) "caches expired: re-reads them all uncached")
     ((eq (car states) 'other) "cache cold: re-reads it all uncached")
     (t (format "cache expired at %s: re-reads it all uncached"
                (harness-ui-format-clock (plist-get (plist-get (car checks) :cache) :expires) now))))))

(defun harness-ui--handoff-choices-for (checks &optional now)
  "Return `harness-ui--handoff-choices' as they read for CHECKS at NOW.
A warm cache is what makes summarising on the current model cheap, so
its description says when the cache is cold instead (see
`harness-ui--handoff-compact-text')."
  (let ((compact (harness-ui--handoff-compact-text checks now)))
    (mapcar (lambda (c)
              (if (and compact (eq (nth 2 c) 'compact))
                  (list (nth 0 c) (nth 1 c) (nth 2 c) compact)
                c))
            harness-ui--handoff-choices)))

(defun harness-ui--handoff-choice-text (&optional choices)
  "Return the handoff CHOICES as a short, aligned list, easy to scan.
CHOICES default to `harness-ui--handoff-choices'."
  (let* ((choices (or choices harness-ui--handoff-choices))
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

(defun harness-ui--handoff-heading (text)
  "Return TEXT as the heading of a section in the switch help."
  (propertize text 'face 'bold))

(defun harness-ui--handoff-wrap (text width)
  "Return TEXT as lines no wider than WIDTH, broken at spaces."
  (let ((words (split-string text " " t))
        (lines nil) (line ""))
    (dolist (w words)
      (cond ((string-empty-p line) (setq line w))
            ((<= (+ (length line) 1 (length w)) width) (setq line (concat line " " w)))
            (t (push line lines) (setq line w))))
    (when (not (string-empty-p line)) (push line lines))
    (or (nreverse lines) '(""))))

(defun harness-ui--handoff-table (header rows &optional wrap)
  "Return a table of HEADER and ROWS for the switch help.
HEADER and each row are lists of cell strings; the last cell may be
empty.  Columns are padded to their widest cell, a rule of dashes
separates HEADER from ROWS, and WRAP caps the last column, whose
continuation lines line up under it.  A nil HEADER gives label and
value columns with no rule."
  (let* ((n (length (or header (car rows))))
         (widths (cl-loop for i from 0 below n
                          for w = (apply #'max 0
                                         (mapcar (lambda (r) (string-width (or (nth i r) "")))
                                                 (append (and header (list header)) rows)))
                          collect (if (and wrap (= i (1- n))) (min w wrap) w)))
         (head (lambda (row)
                 (concat "  "
                         (mapconcat (lambda (i)
                                      (format (format "%%-%ds" (nth i widths)) (or (nth i row) "")))
                                    (number-sequence 0 (- n 2)) "  ")
                         (if (> n 1) "  " ""))))
         (lines (lambda (row)
                  (let* ((prefix (funcall head row))
                         (last (or (nth (1- n) row) ""))
                         (parts (if (and wrap (> (length last) wrap))
                                    (harness-ui--handoff-wrap last wrap)
                                  (list last)))
                         (continuation (make-string (length prefix) ?\s)))
                    (concat (string-trim-right (concat prefix (car parts)))
                            (if (cdr parts) "\n" "")
                            (mapconcat (lambda (l) (string-trim-right (concat continuation l)))
                                       (cdr parts) "\n")))))
         (rule (concat "  " (mapconcat (lambda (w) (make-string w ?-)) widths "  "))))
    (concat (if header (concat (funcall lines header) "\n" rule "\n") "")
            (mapconcat (lambda (r) (funcall lines r)) rows "\n"))))

(defun harness-ui--handoff-risk-row (risk)
  "Return RISK, a \"label: what it means\" sentence, as the cells of a table row."
  (let ((colon (string-match ":" risk)))
    (if colon
        (list (substring risk 0 colon) (string-trim (substring risk (1+ colon))))
      (list risk ""))))

(defun harness-ui--handoff-text (checks label total)
  "Return what to say before a switch to model LABEL loses conversations.
CHECKS are the `handoff/check' answers of the sessions that would lose
theirs, TOTAL how many sessions the switch changes in all.  The view is
a few small tables -- the sessions that change, the risks, what to do --
shown before the question, not prose."
  (let* ((first (car checks))
         (one (= 1 total))
         (lossy (length checks))
         (running (cl-some (lambda (c) (harness-json-true-p (plist-get c :running))) checks))
         (info (if one
                   (append
                    (list (list "Session" (harness-ui--check-session-label first))
                          (list "From" (harness-ui-model-label (plist-get first :from)))
                          (list "Why" (plist-get first :reason)))
                    (when (plist-get first :cache-cost)
                      (list (list "Cache" (format "%s (list prices)" (plist-get first :cache-cost)))))
                    (when running
                      (list (list "Turn" "running; the switch takes effect at its next step"))))
                 (list (list "Sessions" (if (= lossy total)
                                            (format "all %d start a new conversation there" total)
                                          (format "%d of %d start a new conversation there" lossy total)))
                       (list "Why" (plist-get first :reason))))))
    (concat
     (harness-ui--handoff-heading (format "MODEL SWITCH → %s" label)) "\n\n"
     (harness-ui--handoff-table nil info 72) "\n\n"
     (if one
         ""
       (concat (harness-ui--handoff-table
                (list "SESSION" "FROM" "TURN" "CACHE COST")
                (mapcar (lambda (c)
                          (list (harness-ui--check-session-label c)
                                (harness-ui-model-label (plist-get c :from))
                                (if (harness-json-true-p (plist-get c :running)) "running" "-")
                                (or (plist-get c :cache-cost) "-")))
                        checks)
               60)
               "\n\n"))
     (harness-ui--handoff-heading "RISKS") "\n\n"
     (harness-ui--handoff-table
      (list "RISK" "WHAT IT MEANS")
      (mapcar #'harness-ui--handoff-risk-row (plist-get first :risks))
      72)
     "\n\n"
     (harness-ui--handoff-heading "HAND OVER") "\n"
     "  lossy; the new model is told to re-investigate\n\n"
     (harness-ui--handoff-choice-text (harness-ui--handoff-choices-for checks))
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
                  (mapcar (lambda (c) (list (nth 0 c) (nth 1 c) (nth 3 c)))
                          (harness-ui--handoff-choices-for checks))
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

(defun harness-ui--ask-handoff (checks label total _session _host callback)
  "Ask how to hand over a lossy switch in the minibuffer.
See `harness-ui-switch-function'; CALLBACK gets the mode chosen."
  (funcall callback (harness-ui--read-handoff checks label total)))

(defvar harness-ui-switch-function #'harness-ui--ask-handoff
  "Function asking how to hand a conversation over on a lossy model switch.
Called with (CHECKS LABEL TOTAL SESSION HOST CALLBACK): CHECKS are the
`handoff/check' answers of the sessions that would lose their
conversation, LABEL the model being switched to, TOTAL how many sessions
the switch changes in all, SESSION the session's id or nil for a switch
of many, HOST the chat buffer the command ran in or nil, and CALLBACK a
function taking the mode chosen (`compact', `compact-new', `transcript',
`none' or `cancel'), run once the user decides.  The default asks in the
minibuffer (`harness-ui--read-handoff'); the `ui-switch' module shows a
banner in the session's chat instead.")

(defun harness-ui--handoff-perform (session-id model label mode)
  "Switch SESSION-ID to MODEL as MODE says, saying what happens with LABEL.
MODE is a mode of `handoff/switch': the handoff runs at once, or at the
running turn's next step, and its outcome is reported."
  (when (memq mode '(compact compact-new transcript))
    (message "Model → %s: %s…" label
             (pcase mode
               ('compact "summarising the conversation on the current model first")
               ('compact-new "letting the new model summarise a limited context first")
               (_ "handing the transcript over"))))
  (harness-ui-call "_harness/handoff/switch"
                   (list :sessionId session-id :model model :mode (symbol-name mode))
                   (lambda (result) (message "%s" (harness-ui--handoff-outcome label result)))))

(defun harness-ui-switch-model (session-id model label)
  "Switch SESSION-ID to MODEL, shown as LABEL; ask first if that loses context.
The harness checks the switch (`handoff/check').  A model of another
provider that keeps its own conversation (Claude Code, Copilot) and
cannot continue this session's starts a new one that knows nothing of
it, so such a switch asks how to hand the conversation over -- a banner
in the session's chat, or the minibuffer when it has none
\(`harness-ui-switch-function'): summarise on the current model, have
the new model summarise a limited context, hand the full transcript
over, switch without handoff, or cancel.  Any other switch happens at
once."
  (let ((plain (lambda () (harness-ui--setting-set session-id :model model (format "Model → %s" label)))))
    (harness-ui-call
     "_harness/handoff/check" (list :sessionId session-id :model model)
     (lambda (check)
       (if (not (harness-json-true-p (plist-get check :lossy)))
           (funcall plain)
         (funcall harness-ui-switch-function
                  (list check) label 1 session-id nil
                  (lambda (mode)
                    (if (eq mode 'cancel)
                        (message "Model unchanged")
                      (harness-ui--handoff-perform session-id model label mode))))))
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

;; The commands that change every current session and task at once
;; (`harness-set-model-all', `harness-set-thinking-all',
;; `harness-set-non-interactive-all') share what follows.

(defvar harness-ui-set-all-functions nil
  "Functions called with KEY and VALUE when a command sets KEY everywhere.
`harness-set-model-all', `harness-set-thinking-all' and
`harness-set-non-interactive-all' change every current session and
task, and run these so that what starts later takes the change too:
KEY is `:model', `:thinking' or `:non-interactive', and VALUE the new
value, t or nil for `:non-interactive'.  Each function returns the
directories it changed something for, a list, where the command looks
for a .dir-locals.el that overrides the new default.  The task board
sets the new-task settings of every open board.")

(defun harness-ui--set-everywhere (key value)
  "Run `harness-ui-set-all-functions' with KEY and VALUE.
Return the directories they changed something for.  A function that
fails is logged and the others still run."
  (let ((dirs nil))
    (run-hook-wrapped 'harness-ui-set-all-functions
                      (lambda (fn)
                        (condition-case err
                            (setq dirs (append dirs (funcall fn key value)))
                          (error (harness-log 'warn "%s for %s failed: %s" fn key (error-message-string err))))
                        nil))
    (delete-dups (cl-remove-if-not #'stringp dirs))))

(defun harness-ui--everything-filter ()
  "Return the `session/set-all' filter of the commands that change everything.
Every active session (idle, running or blocked) of every project, and
the session of every current task whatever its status: a task's session
may be closed, after a restart say, and still be where the task goes
on.  Inactive sessions of no current task are history."
  (list :active t :tasks t))

(defun harness-ui--count (n word)
  "Return N WORDs, as \"1 session\" or \"2 sessions\"."
  (format "%d %s%s" n word (if (= n 1) "" "s")))

(defun harness-ui--changed-text (sessions tasks)
  "Return how many SESSIONS and TASKS, lists of ids, changed."
  (format "%s and %s" (harness-ui--count (length sessions) "session")
          (harness-ui--count (length tasks) "task")))

(defun harness-ui--new-work-text (no-default boards)
  "Return what else an all-sessions command changed, as a clause.
NO-DEFAULT is non-nil when the default for new sessions stayed as it
was; BOARDS when the open task boards' next tasks changed."
  (cond ((and (not no-default) boards) ", and for new sessions and the open boards' new tasks")
        ((not no-default) ", and for new sessions")
        (boards ", and for the open boards' new tasks")
        (t "")))

(defun harness-ui--overrides-text (overrides show)
  "Return what keeps the new default in OVERRIDES from applying, or nil.
OVERRIDES is what `config/overrides' returned: the .dir-locals.el files
of the projects at work that set the key otherwise, and the task
default that wins over it.  SHOW turns a value into what new sessions
do with it, such as \"start on Opus\".  Nothing is changed: the user
decides, in `harness-settings' or in the files."
  (let* ((key (plist-get overrides :key))
         (value (lambda (printed)
                  (funcall show (and (stringp printed)
                                     (ignore-errors (car (read-from-string printed)))))))
         (parts (append
                 (mapcar (lambda (f)
                           (format "new sessions in %s %s (%s in %s)"
                                   (if (equal (plist-get f :scope) "directory")
                                       (abbreviate-file-name (plist-get f :dir))
                                     (or (plist-get f :project) (abbreviate-file-name (plist-get f :dir))))
                                   (funcall value (plist-get f :value))
                                   key (abbreviate-file-name (plist-get f :file))))
                         (plist-get overrides :files))
                 (when-let* ((tasks (plist-get overrides :tasks)))
                   (list (format "new tasks %s (%s)" (funcall value (plist-get tasks :value))
                                 (plist-get tasks :option)))))))
    (when parts
      (format "But %s; M-x harness-settings changes them." (string-join parts ", ")))))

(defun harness-ui--report-all (text key value overrides dirs show)
  "Say TEXT, followed by what keeps VALUE of KEY from applying to new work.
KEY is the setting's name and VALUE the value just set everywhere.
Unless OVERRIDES is nil, TEXT goes on with the projects at work, and
those of DIRS besides (the open boards'), whose .dir-locals.el has
new sessions start otherwise, and the task default that has new tasks
do so (see `config/overrides'); SHOW is as for
`harness-ui--overrides-text'.  A harness without `config/overrides'
says TEXT alone."
  (if (not overrides)
      (message "%s" text)
    (harness-ui-call "_harness/config/overrides"
                     (list :key key :value (prin1-to-string value) :printed t :dirs dirs)
                     (lambda (found)
                       (let ((more (harness-ui--overrides-text found show)))
                         (message "%s%s" text (if more (concat ".  " more) ""))))
                     (lambda (_err) (message "%s" text) nil))))

(defun harness-ui--apply-everywhere (settings callback)
  "Apply SETTINGS to every current session and task, then call CALLBACK.
The sessions first (`session/set-all' with
`harness-ui--everything-filter'), then the records of the current tasks
of every project (`task/set-all'), which their next start uses; a task
session changed already is not changed, nor told, a second time.
CALLBACK gets the ids of the sessions and of the tasks that changed."
  (harness-ui-call "_harness/session/set-all"
                   (list :settings settings :filter (harness-ui--everything-filter))
                   (lambda (sessions)
                     (harness-ui-call "_harness/task/set-all" (list :settings settings)
                                      (lambda (tasks) (funcall callback sessions tasks))
                                      ;; A harness without task mode has sessions only.
                                      (lambda (_err) (funcall callback sessions nil) nil)))))

(defun harness-ui--switch-all (model label mode no-default)
  "Switch every current session and task to MODEL, shown as LABEL.
MODE is how the sessions that would lose their conversation hand it
over (see `handoff/switch'); `none' just switches them all.  The
sessions switch first, task sessions included (see
`harness-ui--everything-filter'), so none escapes the handoff; then the
current tasks' records take MODEL, which their sessions have already.
The model becomes the default for new sessions too, and of the open
boards' new tasks, unless NO-DEFAULT; then what still overrides the
default is said."
  (unless no-default
    (harness-ui-call "_harness/config/set"
                     (list :key "harness-model" :value model :scope "global")
                     (lambda (_) nil)))
  (let* ((dirs (unless no-default (harness-ui--set-everywhere :model model)))
         (done (lambda (sessions)
                 (harness-ui-call
                  "_harness/task/set-all" (list :settings (list :model model))
                  (lambda (tasks)
                    (harness-ui--report-all
                     (format "Model → %s for %s%s%s" label (harness-ui--changed-text sessions tasks)
                             (pcase mode
                               ('compact ", summarising the conversations that need it first")
                               ('compact-new ", letting the new model summarise a limited context where needed")
                               ('transcript ", handing the transcripts over where needed")
                               (_ ""))
                             (harness-ui--new-work-text no-default dirs))
                     "harness-model" model (not no-default) dirs
                     (lambda (m) (format "start on %s" (harness-ui-model-label m)))))
                  (lambda (_err) (message "Model → %s for %s" label
                                          (harness-ui--count (length sessions) "session"))
                    nil)))))
    (if (eq mode 'none)
        (harness-ui-call "_harness/session/set-all"
                         (list :settings (list :model model) :filter (harness-ui--everything-filter))
                         done)
      (harness-ui-call "_harness/handoff/switch-all"
                       (list :model model :filter (harness-ui--everything-filter) :mode (symbol-name mode))
                       done))))

;;;###autoload
(defun harness-set-model-all (&optional no-default)
  "Choose a model and switch every current session and task to it.
The choice also becomes the default for new sessions, and the model of
the open task boards' new tasks, unless NO-DEFAULT, the prefix
argument, says otherwise.  Use this when a plan runs out, a provider
fails, or a cheaper model should take over work already in flight.
Idle, running and blocked sessions of every project change, each
recording it as a hint, and so do the current tasks of every project
\(running, pending and blocked) and their sessions, even a closed one;
other inactive sessions are history and are left alone, and no running
turn is cancelled: it takes the new model at its next step.  When the
switch would lose sessions their conversation (see
`harness-ui-switch-model'), it asks once for all of them, and the
handoff chosen applies to each of them.  A session keeps its provider
state until another provider runs a step in it, so switching back before
then resumes its conversation.  Once the default changed, it says which
projects still start otherwise, because their .dir-locals.el sets
`harness-model', and whether `harness-tasks-model' does for tasks; it
changes neither."
  (interactive "P")
  ;; The chat the command runs in, for the banner to show in.
  (let ((host (and (derived-mode-p 'harness-chat-mode) (current-buffer))))
    (harness-ui-choose-model
     (lambda (id label)
       (harness-ui-call
        "_harness/handoff/check-all" (list :model id :filter (harness-ui--everything-filter))
        (lambda (checks)
          (let ((lossy (cl-remove-if-not (lambda (c) (harness-json-true-p (plist-get c :lossy))) checks)))
            (if (null lossy)
                (harness-ui--switch-all id label 'none no-default)
              (funcall harness-ui-switch-function
                       lossy label (length checks) nil host
                       (lambda (mode)
                         (if (eq mode 'cancel)
                             (message "Models unchanged")
                           (harness-ui--switch-all id label mode no-default)))))))
        ;; A harness that cannot check switches them as it always did.
        (lambda (_err) (harness-ui--switch-all id label 'none no-default) nil))))))

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
without one the common levels are.  An empty answer chooses nothing:
CALLBACK is not called."
  (let ((choose (lambda (levels)
                  (let* ((levels (cons "default" (harness-ui--thinking-levels-for levels)))
                         (collection (lambda (string pred action)
                                       ;; Keep the weakest-first order.
                                       (if (eq action 'metadata)
                                           '(metadata (display-sort-function . identity)
                                                      (cycle-sort-function . identity))
                                         (complete-with-action action levels string pred))))
                         (choice (completing-read "Thinking: " collection nil t)))
                    ;; A required match still lets an empty answer
                    ;; through, which is no level.
                    (if (string-empty-p choice)
                        (message "No thinking level chosen")
                      (funcall callback (unless (equal choice "default") choice) choice))))))
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
  "Choose a thinking level and set it on every current session and task.
Idle, running and blocked sessions of every project change, and so do
the current tasks of every project (running, pending and blocked) and
their sessions, even a closed one; other inactive sessions are history
and are left alone.  The level also becomes the default for new
sessions, and the level of the open task boards' new tasks, unless
NO-DEFAULT, the prefix argument, says otherwise.  Once the default
changed, it says which projects still start otherwise, because their
.dir-locals.el sets `harness-thinking', and whether
`harness-tasks-thinking' does for tasks; it changes neither."
  (interactive "P")
  (harness-ui-choose-thinking
   (lambda (value label)
     (unless no-default
       (harness-ui-call "_harness/config/set"
                        (list :key "harness-thinking" :value (prin1-to-string value)
                              :printed t :scope "global")
                        (lambda (_) nil)))
     (let ((dirs (unless no-default (harness-ui--set-everywhere :thinking value))))
       (harness-ui--apply-everywhere
        (list :thinking value)
        (lambda (sessions tasks)
          (harness-ui--report-all
           (format "Thinking → %s for %s%s" label (harness-ui--changed-text sessions tasks)
                   (harness-ui--new-work-text no-default dirs))
           "harness-thinking" value (not no-default) dirs
           (lambda (level) (format "think at %s" (or level "the model's default"))))))))))

;;;###autoload
(defun harness-set-non-interactive-all (&optional no-default)
  "Turn non-interactive mode on or off for everything at once.
It asks which, offering on first, and changes every active session
\(idle, running or blocked) of every project, every current task of
every project (running, pending or blocked) and its session, even a
closed one, and the new-task settings of every open task board.  It
becomes the default for new sessions too, unless NO-DEFAULT, the
prefix argument, says otherwise.  It reports how many sessions and
tasks changed: those that had the mode already are left alone.  When
it turns the mode off, or changes the default, it also says what still
has new work start otherwise: a project whose .dir-locals.el sets
`harness-non-interactive', and `harness-tasks-non-interactive' when it
still turns new tasks on; it changes neither.
Use it on leaving, so that no session waits for you, and on coming
back.  A non-interactive session never waits for the user: the
auto-mode judge decides what would ask you, prompts already waiting
included, and after a denial the agent is told to find another way;
only directories are still yours to grant.  See
`harness-toggle-non-interactive' for one session."
  (interactive "P")
  (let* ((choices '("on" "off"))
         (choice (completing-read "Non-interactive mode for every session and task: "
                                  (lambda (string pred action)
                                    ;; On first, as offered.
                                    (if (eq action 'metadata)
                                        '(metadata (display-sort-function . identity)
                                                   (cycle-sort-function . identity))
                                      (complete-with-action action choices string pred)))
                                  nil t nil nil "on"))
         (on (not (equal choice "off"))))
    (let ((dirs (harness-ui--set-everywhere :non-interactive on)))
      (harness-ui--apply-everywhere
       (list :non-interactive (if on t :false))
       (lambda (sessions tasks)
         ;; The default last: a task with no setting of its own follows
         ;; it, so the tasks are compared with how they would have
         ;; started, and get the setting for good.
         (unless no-default
           (harness-ui-call "_harness/config/set"
                            (list :key "harness-non-interactive" :value (prin1-to-string on)
                                  :printed t :scope "global")
                            (lambda (_) nil)))
         (harness-ui--report-all
          (format "Non-interactive %s for %s%s" (if on "on" "off")
                  (harness-ui--changed-text sessions tasks)
                  (harness-ui--new-work-text no-default dirs))
          "harness-non-interactive" on
          ;; Turning it off says what still turns it on, whatever the
          ;; default; turning it on, what keeps the new default off.
          (or (not on) (not no-default))
          dirs
          (lambda (v) (if (harness-json-true-p v) "start non-interactive" "start interactive"))))))))

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

;; At top level, not in the `defvar', so a reload binds them in a running
;; Emacs too.
(define-key harness-ui-map (kbd "i") #'harness-toggle-non-interactive)
(define-key harness-ui-map (kbd "A") #'harness-set-non-interactive-all)
(define-key harness-ui-map (kbd "F") #'harness-fullscreen)

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
    ("F" (lambda () (if (harness-ui--fullscreen-layout) "End fullscreen" "Fullscreen overview"))
     harness-fullscreen)
    ("f" "Fork session" harness-fork-session)
    ("k" "Cancel turn" harness-cancel-turn)
    ("D" "Delete session" harness-delete-session)]
   ["Session settings"
    ("m" "Model" harness-set-model)
    ("M" "Model for all sessions" harness-set-model-all)
    ("T" "Thinking" harness-set-thinking)
    ("H" "Thinking for all sessions" harness-set-thinking-all)
    ("A" "Non-interactive for all sessions" harness-set-non-interactive-all)
    ("p" "Permission mode" harness-set-permission-mode)
    ("d" "Directory access" harness-directories :if (lambda () (harness-ui--command-available-p 'harness-directories)))
    ("i" (lambda () (harness-ui--non-interactive-menu-label)) harness-toggle-non-interactive)
    ("r" "Rename" harness-rename-session)]
   ["Tools"
    ("u" "Usage & cost" harness-usage :if (lambda () (harness-ui--command-available-p 'harness-usage)))
    ("I" "Insights" harness-insights :if (lambda () (harness-ui--command-available-p 'harness-insights)))
    ("B" "Delete budget" harness-delete-budget :if (lambda () (harness-ui--command-available-p 'harness-delete-budget)))
    ("w" "Worktrees" harness-worktrees :if (lambda () (harness-ui--command-available-p 'harness-worktrees)))
    ("S" "Settings" harness-settings :if (lambda () (harness-ui--command-available-p 'harness-settings)))
    ("z" "Companion pet" harness-pet :if (lambda () (harness-ui--command-available-p 'harness-pet)))
    ("c" "Connect remote" harness-connect-remote :inapt-if harness-corporate-p)
    ("P" "Remote control" harness-remote-control
     :if (lambda () (harness-ui--command-available-p 'harness-remote-control))
     :inapt-if harness-corporate-p)
    ("N" "Test notifications" harness-test-notifications)
    ("v" (lambda () (if (fboundp 'harness-ui-version-menu-label) (harness-ui-version-menu-label) "Version"))
     harness-version :if (lambda () (harness-ui--command-available-p 'harness-version)))
    ("R" "Reload harness" harness-reload)
    ("U" "Update harness" harness-update)
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
  ;; A click on a macOS notification this Emacs no longer knows (one it
  ;; showed before a restart) lists the sessions waiting for you.
  (unless harness-notifications-desktop-unknown-click-function
    (setq harness-notifications-desktop-unknown-click-function
          #'harness-ui--unknown-notification-clicked))
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
