;;; harness-notifications-desktop.el --- Desktop notifications  -*- lexical-binding: t; -*-

;; This file is part of the Emacs agent harness (v3).

;;; Commentary:

;; Shows a notification on the desktop of the machine this Emacs runs
;; on.  Both Emacs processes use it (see harness-server.el): the
;; user's Emacs, which the notifications module asks first over
;; `_harness/client/notify', so that a notification shows where the
;; user is and a click on it can open what it is about; and the
;; harness process, when no UI shows it.
;;
;; Backends (`harness-notifications-desktop-backend'):
;;
;; - notify-send (libnotify), run as an asynchronous process.  With
;;   `--print-id' it says at once whether the notification server took
;;   the notification.  A clickable notification gets a default action
;;   and the process waits: notify-send prints the action's name when
;;   the notification is clicked.  An old notify-send without these
;;   options shows a plain notification.
;; - D-Bus (org.freedesktop.Notifications) from Emacs itself, for an
;;   Emacs with D-Bus support where notify-send is missing.  An
;;   interactive Emacs calls it asynchronously and hears clicks through
;;   the ActionInvoked signal; a batch Emacs, which never reads D-Bus
;;   events, makes a synchronous call with a short timeout.
;; - osascript on macOS (`display notification'), without clicks.
;; - MS Windows notifications in a graphical Emacs, without clicks.
;; - Any function of the notification's plist.
;;
;; Nothing here waits: `harness-notifications-desktop-notify' returns a
;; promise.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar dbus-event-error-functions)
(declare-function dbus-call-method "dbus")
(declare-function dbus-call-method-asynchronously "dbus")
(declare-function dbus-register-signal "dbus")
(declare-function dbus-event-serial-number "dbus")
(declare-function w32-notification-notify "w32fns.c")
(declare-function w32-notification-close "w32fns.c")

(defcustom harness-notifications-desktop-backend 'auto
  "How desktop notifications are shown.
`auto' takes the first of these that works in this Emacs:
  `notify-send'  the notify-send program (libnotify), the usual way on
                 GNU/Linux and BSD desktops; clicks are heard;
  `dbus'         Emacs's own D-Bus support, when notify-send is missing;
                 clicks are heard in an interactive Emacs;
  `osascript'    macOS notifications;
  `w32'          MS Windows notifications, in a graphical Emacs.
A function takes over instead: it is called with a plist of `:title',
`:body', `:urgency' (low, normal or critical) and `:on-action' (nil, or
a function of no arguments to call when the notification is clicked),
and returns anything, or a promise, once the notification shows; it
signals or rejects when it cannot show it."
  :type '(choice (const :tag "Pick automatically" auto)
                 (const :tag "notify-send (libnotify)" notify-send)
                 (const :tag "D-Bus from Emacs" dbus)
                 (const :tag "osascript (macOS)" osascript)
                 (const :tag "MS Windows notifications" w32)
                 (function :tag "Function"))
  :group 'harness)

(defconst harness-notifications-desktop--app-name "Emacs Agent Harness"
  "Application name desktop notifications are shown under.")

(defconst harness-notifications-desktop--icon-name nil
  "Icon of desktop notifications: an image file or an icon name.
nil uses the Emacs icon.")

(defconst harness-notifications-desktop--notify-send "notify-send"
  "The notify-send program the `notify-send' backend runs.")

(defconst harness-notifications-desktop-max-waiting 16
  "Clickable notify-send notifications listened to at most.
Each keeps a notify-send process waiting for its click; past this many
the oldest stops listening (its notification stays).")

(defconst harness-notifications-desktop-dbus-timeout 5000
  "Milliseconds a D-Bus Notify call may take.")

(defconst harness-notifications-desktop--backends '(notify-send dbus osascript w32)
  "Backends `auto' tries, in order.")

;;;; Choosing a backend

(defun harness-notifications-desktop--notify-send-program ()
  "Return the notify-send executable, or nil."
  (and (stringp harness-notifications-desktop--notify-send)
       (not (string-empty-p harness-notifications-desktop--notify-send))
       (executable-find harness-notifications-desktop--notify-send)))

(defun harness-notifications-desktop--dbus-session-p ()
  "Non-nil when this Emacs has D-Bus and a session bus to reach.
It does not ask the bus, which could wait."
  (and (featurep 'dbusbind)
       (or (getenv "DBUS_SESSION_BUS_ADDRESS")
           (let ((runtime (getenv "XDG_RUNTIME_DIR")))
             (and runtime (file-exists-p (expand-file-name "bus" runtime)))))
       t))

(defun harness-notifications-desktop--usable-p (backend)
  "Non-nil when BACKEND, a symbol, can show notifications in this Emacs."
  (pcase backend
    ('notify-send (and (harness-notifications-desktop--notify-send-program) t))
    ('dbus (harness-notifications-desktop--dbus-session-p))
    ('osascript (and (eq system-type 'darwin) (executable-find "osascript") t))
    ('w32 (and (fboundp 'w32-notification-notify) (not noninteractive) (display-graphic-p) t))
    (_ nil)))

(defun harness-notifications-desktop-backend ()
  "Return the backend that shows notifications here: a symbol or a function.
nil when there is none: `auto' found nothing that works, or the
chosen backend cannot work in this Emacs."
  (let ((choice harness-notifications-desktop-backend))
    (cond ((eq choice 'auto)
           (cl-find-if #'harness-notifications-desktop--usable-p harness-notifications-desktop--backends))
          ((memq choice harness-notifications-desktop--backends)
           (and (harness-notifications-desktop--usable-p choice) choice))
          ((functionp choice) choice))))

(defun harness-notifications-desktop-available-p ()
  "Non-nil when desktop notifications can be shown from this Emacs."
  (and (harness-notifications-desktop-backend) t))

(defun harness-notifications-desktop--missing-message ()
  "Say why no backend shows notifications here."
  (let ((choice harness-notifications-desktop-backend))
    (if (memq choice harness-notifications-desktop--backends)
        (format "The %s desktop notification backend does not work in this Emacs%s"
                choice
                (if (eq choice 'notify-send)
                    (format " (no %s program)" harness-notifications-desktop--notify-send)
                  ""))
      "No way to show desktop notifications here: install notify-send (libnotify), use an Emacs with D-Bus support, or set harness-notifications-desktop-backend")))

;;;; Text

(defun harness-notifications-desktop--icon ()
  "Return the icon to show: `harness-notifications-desktop--icon-name' or Emacs's."
  (or harness-notifications-desktop--icon-name
      (let ((svg (expand-file-name "images/icons/hicolor/scalable/apps/emacs.svg" data-directory)))
        (if (file-exists-p svg) svg "emacs"))))

(defun harness-notifications-desktop--urgency (urgency)
  "Return URGENCY (a symbol or string) as low, normal or critical."
  (let ((u (if (stringp urgency) (intern-soft urgency) urgency)))
    (if (memq u '(low normal critical)) u 'normal)))

(defun harness-notifications-desktop--escape (text)
  "Return TEXT with markup characters escaped.
Notification servers read a body as markup, where a stray `<' or `&'
would swallow text."
  (replace-regexp-in-string
   "[&<>]" (lambda (c) (pcase c ("&" "&amp;") ("<" "&lt;") (_ "&gt;"))) (or text "") t t))

(defun harness-notifications-desktop--local-directory ()
  "A local directory to start processes in, whatever `default-directory' is."
  (if (or (file-remote-p default-directory) (not (file-directory-p default-directory)))
      temporary-file-directory
    default-directory))

;;;; notify-send

(defvar harness-notifications-desktop--legacy nil
  "Non-nil once notify-send turned down `--print-id' or `--action'.
That is an old libnotify; it then shows plain notifications, which
nobody can click.")

(defvar harness-notifications-desktop--waiting nil
  "Live notify-send processes waiting for a click, oldest first.")

(defun harness-notifications-desktop--notify-send-args (params legacy)
  "Return the notify-send arguments for PARAMS.
LEGACY leaves out the options an old notify-send does not know."
  (let ((title (or (plist-get params :title) ""))
        (body (plist-get params :body)))
    (append
     (list (concat "--app-name=" harness-notifications-desktop--app-name)
           (concat "--urgency=" (symbol-name (harness-notifications-desktop--urgency
                                               (plist-get params :urgency))))
           (concat "--icon=" (harness-notifications-desktop--icon)))
     (unless legacy (list "--print-id"))
     (when (and (not legacy) (plist-get params :on-action))
       (list "--action=default=Open"))
     (list "--" title)
     (when (and (stringp body) (not (string-empty-p body)))
       (list (harness-notifications-desktop--escape body))))))

(defun harness-notifications-desktop--forget-waiting (proc)
  "Stop counting PROC among the processes waiting for a click."
  (setq harness-notifications-desktop--waiting (delq proc harness-notifications-desktop--waiting)))

(defun harness-notifications-desktop--wait-for-click (proc)
  "Count PROC among the processes waiting for a click.
Past `harness-notifications-desktop-max-waiting' the oldest stops."
  (setq harness-notifications-desktop--waiting
        (append (cl-remove-if-not #'process-live-p harness-notifications-desktop--waiting) (list proc)))
  (while (> (length harness-notifications-desktop--waiting) harness-notifications-desktop-max-waiting)
    (let ((oldest (pop harness-notifications-desktop--waiting)))
      (when (process-live-p oldest) (delete-process oldest)))))

(defun harness-notifications-desktop--notify-send (params)
  "Show PARAMS with notify-send; return a promise of (:backend notify-send :id ID)."
  (let ((program (harness-notifications-desktop--notify-send-program))
        (legacy harness-notifications-desktop--legacy)
        (on-action (plist-get params :on-action)))
    (harness-with-promise (resolve reject)
      (unless program (error "%s" (harness-notifications-desktop--missing-message)))
      (let* ((default-directory (harness-notifications-desktop--local-directory))
             (stdout "")
             (shown nil)
             (stderr (generate-new-buffer " *harness-notify-send*" t))
             (lines-seen 0)
             (handle-line
              (lambda (line proc)
                (cl-incf lines-seen)
                (cond
                 ;; The first line is the id the server gave it (0: refused).
                 ((and (= lines-seen 1) (not legacy))
                  (let ((id (and (string-match-p "\\`[0-9]+\\'" line) (string-to-number line))))
                    (when (and id (> id 0) (not shown))
                      (setq shown t)
                      (when (and on-action (process-live-p proc))
                        (harness-notifications-desktop--wait-for-click proc))
                      (funcall resolve (list :backend 'notify-send :id id)))))
                 ;; Later lines name the action clicked.
                 ((and on-action (equal line "default"))
                  (harness-ignore-errors-logged "notification click"
                    (funcall on-action))))))
             (proc
              (make-process
               :name "harness-notify-send"
               :command (cons program (harness-notifications-desktop--notify-send-args params legacy))
               :connection-type 'pipe
               :noquery t
               :coding '(utf-8 . utf-8)
               :stderr stderr
               :filter (lambda (proc chunk)
                         (setq stdout (concat stdout chunk))
                         (let (nl)
                           (while (setq nl (string-search "\n" stdout))
                             (let ((line (string-trim (substring stdout 0 nl))))
                               (setq stdout (substring stdout (1+ nl)))
                               (funcall handle-line line proc)))))
               :sentinel
               (lambda (proc _event)
                 (unless (process-live-p proc)
                   (harness-notifications-desktop--forget-waiting proc)
                   (let ((rest (string-trim stdout)))
                     (unless (string-empty-p rest)
                       (setq stdout "")
                       (funcall handle-line rest proc)))
                   (let ((code (process-exit-status proc))
                         (err (string-trim (if (buffer-live-p stderr)
                                               (with-current-buffer stderr (buffer-string))
                                             ""))))
                     (when (buffer-live-p stderr) (kill-buffer stderr))
                     (cond
                      (shown nil)
                      ((and (not legacy) (string-match-p "Unknown option" err))
                       ;; An old notify-send: show it again, plainly.
                       (setq harness-notifications-desktop--legacy t)
                       (funcall resolve (harness-notifications-desktop--notify-send params)))
                      ((and legacy (eq code 0))
                       (funcall resolve (list :backend 'notify-send)))
                      (t (funcall reject
                                  (list 'error
                                        (format "notify-send failed%s"
                                                (if (string-empty-p err)
                                                    (format " (exit %s)" code)
                                                  (concat ": " (car (last (split-string err "\n" t))))))))))))))))
        (when-let* ((ep (get-buffer-process stderr)))
          (set-process-query-on-exit-flag ep nil)
          (set-process-sentinel ep #'ignore))
        ;; It reads nothing.  A quick one may have exited already: the
        ;; sentinel says how that went, not "Process ... not running".
        (when (process-live-p proc)
          (ignore-errors (process-send-eof proc)))))))

;;;; D-Bus

(defconst harness-notifications-desktop--dbus-service "org.freedesktop.Notifications")
(defconst harness-notifications-desktop--dbus-path "/org/freedesktop/Notifications")
(defconst harness-notifications-desktop--dbus-interface "org.freedesktop.Notifications")

(defvar harness-notifications-desktop--dbus-actions (make-hash-table :test 'eql)
  "Notification id -> function to call when the notification is clicked.")

(defvar harness-notifications-desktop--dbus-calls (make-hash-table :test 'eql)
  "Serial of a Notify call waiting for its answer -> what rejects its promise.")

(defvar harness-notifications-desktop--dbus-listening nil
  "Non-nil once clicks and closings are listened to.")

(defun harness-notifications-desktop--dbus-on-action (id action)
  "Run the click function of notification ID when ACTION is the default one."
  (let ((fn (gethash id harness-notifications-desktop--dbus-actions)))
    (when (and fn (equal action "default"))
      (remhash id harness-notifications-desktop--dbus-actions)
      (harness-ignore-errors-logged "notification click" (funcall fn)))))

(defun harness-notifications-desktop--dbus-on-closed (id &rest _)
  "Forget notification ID, which was closed."
  (remhash id harness-notifications-desktop--dbus-actions))

(defun harness-notifications-desktop--dbus-on-error (event err)
  "Reject the Notify call EVENT answers with ERR, if it is one of ours."
  (let* ((serial (ignore-errors (dbus-event-serial-number event)))
         (reject (and serial (gethash serial harness-notifications-desktop--dbus-calls))))
    (when reject
      (remhash serial harness-notifications-desktop--dbus-calls)
      (funcall reject err))))

(defun harness-notifications-desktop--dbus-listen ()
  "Listen to clicks, closings and failed calls (once)."
  (unless harness-notifications-desktop--dbus-listening
    (dbus-register-signal :session nil harness-notifications-desktop--dbus-path
                          harness-notifications-desktop--dbus-interface "ActionInvoked"
                          #'harness-notifications-desktop--dbus-on-action)
    (dbus-register-signal :session nil harness-notifications-desktop--dbus-path
                          harness-notifications-desktop--dbus-interface "NotificationClosed"
                          #'harness-notifications-desktop--dbus-on-closed)
    (setq harness-notifications-desktop--dbus-listening t))
  (add-hook 'dbus-event-error-functions #'harness-notifications-desktop--dbus-on-error))

(defun harness-notifications-desktop--dbus-args (params clickable)
  "Return the arguments of the Notify call for PARAMS.
CLICKABLE adds the default action, which a click on it invokes."
  (list :string harness-notifications-desktop--app-name
        :uint32 0
        :string (harness-notifications-desktop--icon)
        :string (or (plist-get params :title) "")
        :string (harness-notifications-desktop--escape (plist-get params :body))
        (if clickable '(:array "default" "Open") '(:array :signature "s"))
        `(:array (:dict-entry "urgency"
                              (:variant :byte ,(pcase (harness-notifications-desktop--urgency
                                                       (plist-get params :urgency))
                                                 ('low 0) ('critical 2) (_ 1)))))
        :int32 -1))

(defun harness-notifications-desktop--dbus (params)
  "Show PARAMS through D-Bus; return a promise of (:backend dbus :id ID)."
  (require 'dbus)
  (let ((on-action (plist-get params :on-action)))
    (harness-with-promise (resolve reject)
      (if noninteractive
          ;; A batch Emacs never reads D-Bus events: ask and wait, briefly.
          (let ((id (apply #'dbus-call-method :session harness-notifications-desktop--dbus-service
                           harness-notifications-desktop--dbus-path
                           harness-notifications-desktop--dbus-interface "Notify"
                           :timeout 2000 (harness-notifications-desktop--dbus-args params nil))))
            (funcall resolve (list :backend 'dbus :id id)))
        (harness-notifications-desktop--dbus-listen)
        (let* ((serial nil)
               (timer nil)
               (done (lambda ()
                       (when timer (cancel-timer timer))
                       (when serial (remhash serial harness-notifications-desktop--dbus-calls))))
               (key (apply #'dbus-call-method-asynchronously
                           :session harness-notifications-desktop--dbus-service
                           harness-notifications-desktop--dbus-path
                           harness-notifications-desktop--dbus-interface "Notify"
                           (lambda (id)
                             (funcall done)
                             (when on-action (puthash id on-action harness-notifications-desktop--dbus-actions))
                             (funcall resolve (list :backend 'dbus :id id)))
                           :timeout harness-notifications-desktop-dbus-timeout
                           (harness-notifications-desktop--dbus-args params on-action))))
          ;; The key is (:serial BUS SERIAL); an error answer carries SERIAL.
          (setq serial (if (consp key) (car (last key)) key))
          (puthash serial (lambda (err) (funcall done) (funcall reject err))
                   harness-notifications-desktop--dbus-calls)
          (setq timer (run-at-time (/ harness-notifications-desktop-dbus-timeout 1000.0) nil
                                   (lambda ()
                                     (funcall done)
                                     (funcall reject (list 'error "The notification service did not answer"))))))))))

;;;; osascript

(defun harness-notifications-desktop--osascript (params)
  "Show PARAMS with osascript (macOS); return a promise."
  (harness-then
   (harness-run-command (list "osascript"
                              "-e" "on run argv"
                              "-e" "display notification (item 2 of argv) with title (item 1 of argv)"
                              "-e" "end run"
                              (or (plist-get params :title) "")
                              (or (plist-get params :body) ""))
                        :cwd (harness-notifications-desktop--local-directory)
                        :timeout 30 :name "harness-osascript")
   (lambda (r)
     (if (eq (plist-get r :exit) 0)
         (list :backend 'osascript)
       (signal 'error (list (format "osascript failed: %s"
                                            (string-trim (or (plist-get r :stderr) "")))))))))

;;;; MS Windows

(defvar harness-notifications-desktop--w32-id nil
  "The MS Windows notification shown last; it shows one at a time.")

(defun harness-notifications-desktop--w32 (params)
  "Show PARAMS as an MS Windows notification; return a promise."
  (when harness-notifications-desktop--w32-id
    (ignore-errors (w32-notification-close harness-notifications-desktop--w32-id)))
  (let ((id (w32-notification-notify
             :title (harness-truncate-end (or (plist-get params :title) "") 63)
             :body (harness-truncate-end (or (plist-get params :body) "") 255)
             :level (if (eq (harness-notifications-desktop--urgency (plist-get params :urgency)) 'critical)
                        'warning 'info)
             :tip (harness-truncate-end harness-notifications-desktop--app-name 127))))
    (setq harness-notifications-desktop--w32-id id)
    ;; It stays in the tray until closed.
    (run-at-time 30 nil (lambda ()
                          (when (eq harness-notifications-desktop--w32-id id)
                            (setq harness-notifications-desktop--w32-id nil)
                            (ignore-errors (w32-notification-close id)))))
    (harness-resolved (list :backend 'w32 :id id))))

;;;; Entry point

(defun harness-notifications-desktop-notify (&rest params)
  "Show a desktop notification; return a promise of (:backend NAME :id ID).
PARAMS are `:title', `:body', `:urgency' (low, normal or critical) and
`:on-action', a function of no arguments called when the user clicks
the notification (with the backends that hear clicks).  The promise
rejects when no backend can show it, or the one chosen fails."
  (let ((backend (harness-notifications-desktop-backend)))
    (condition-case err
        (pcase backend
          ('nil (harness-rejected (list 'error (harness-notifications-desktop--missing-message))))
          ('notify-send (harness-notifications-desktop--notify-send params))
          ('dbus (harness-notifications-desktop--dbus params))
          ('osascript (harness-notifications-desktop--osascript params))
          ('w32 (harness-notifications-desktop--w32 params))
          (_ (harness-then (harness-as-promise (funcall backend params))
                           (lambda (_) (list :backend 'function)))))
      (error (harness-rejected err)))))

(provide 'harness-notifications-desktop)
;;; harness-notifications-desktop.el ends here
