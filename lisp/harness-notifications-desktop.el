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
;; - terminal-notifier on macOS, when installed.  It exits once the
;;   notification shows, and macOS starts it again when the notification
;;   is clicked, maybe hours later in the Notification Center, to do what
;;   it was told: bring this Emacs's application to the front
;;   (`-activate') and, for a clickable notification, run emacsclient
;;   (`-execute'), which asks this Emacs, through its server, to run the
;;   click action it keeps under a key
;;   (`harness-notifications-desktop-clicked').  Without a server the
;;   click only brings Emacs to the front.
;; - AppleScript run inside a graphical Emacs on macOS
;;   (`ns-do-applescript', or `mac-osa-script' on the Mac port): the
;;   notification is Emacs's own, so a click brings Emacs to the front,
;;   but nothing says which notification it was.
;; - osascript on macOS (`display notification'), without clicks:
;;   macOS gives its notifications to Script Editor, which a click opens.
;;   The last resort, for a terminal Emacs or the harness process.
;; - MS Windows notifications in a graphical Emacs, without clicks.
;; - Any function of the notification's plist.
;;
;; On macOS `auto' tries the macOS backends first, so a click never
;; opens Script Editor where something better works.  Nothing here
;; waits: `harness-notifications-desktop-notify' returns a promise.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)

(defvar dbus-event-error-functions)
(defvar server-process)
(defvar server-name)
(defvar server-auth-dir)
(declare-function dbus-call-method "dbus")
(declare-function dbus-call-method-asynchronously "dbus")
(declare-function dbus-register-signal "dbus")
(declare-function dbus-event-serial-number "dbus")
(declare-function w32-notification-notify "w32fns.c")
(declare-function w32-notification-close "w32fns.c")

(defcustom harness-notifications-desktop-backend 'auto
  "How desktop notifications are shown.
`auto' takes the first of these that works in this Emacs, the macOS
ones first on macOS:
  `notify-send'        the notify-send program (libnotify), the usual
                       way on GNU/Linux and BSD desktops; clicks are heard;
  `dbus'               Emacs's own D-Bus support, when notify-send is
                       missing; clicks are heard in an interactive Emacs;
  `terminal-notifier'  the terminal-notifier program on macOS (brew
                       install terminal-notifier): a click brings Emacs
                       to the front and, while the Emacs server runs
                       (`server-start'), opens what the notification
                       is about;
  `applescript'        macOS notifications a graphical Emacs shows as its
                       own: a click brings Emacs to the front;
  `osascript'          macOS notifications from the osascript program,
                       which macOS gives to Script Editor: a click opens
                       Script Editor;
  `w32'                MS Windows notifications, in a graphical Emacs.
A function takes over instead: it is called with a plist of `:title',
`:body', `:urgency' (low, normal or critical) and `:on-action' (nil, or
a function of no arguments to call when the notification is clicked),
and returns anything, or a promise, once the notification shows; it
signals or rejects when it cannot show it."
  :type '(choice (const :tag "Pick automatically" auto)
                 (const :tag "notify-send (libnotify)" notify-send)
                 (const :tag "D-Bus from Emacs" dbus)
                 (const :tag "terminal-notifier (macOS)" terminal-notifier)
                 (const :tag "AppleScript in this Emacs (macOS)" applescript)
                 (const :tag "osascript (macOS)" osascript)
                 (const :tag "MS Windows notifications" w32)
                 (function :tag "Function"))
  :group 'harness)

(defcustom harness-notifications-desktop-macos-app nil
  "Bundle id of the macOS application a click on a notification brings forward.
nil finds it: the application a graphical Emacs runs from (Emacs.app,
org.gnu.Emacs for most builds), else, for an Emacs in a terminal, the
terminal's application.  Set it when that finds the wrong one, to
\"org.gnu.Emacs\" or \"com.googlecode.iterm2\" say.  The
`terminal-notifier' backend uses it."
  :type '(choice (const :tag "Find it" nil)
                 (string :tag "Bundle identifier"))
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

(defconst harness-notifications-desktop--terminal-notifier "terminal-notifier"
  "The terminal-notifier program the `terminal-notifier' backend runs.")

(defconst harness-notifications-desktop--macos-bin-directories
  '("/opt/homebrew/bin" "/usr/local/bin" "/opt/local/bin")
  "Where Homebrew and MacPorts install programs on macOS, looked in after the path.
The path is the variable `exec-path'.  An Emacs started from the Dock
has only the system's directories on it.")

(defconst harness-notifications-desktop-max-actions 64
  "Click actions of terminal-notifier notifications remembered at most.
A notification can be clicked in the Notification Center long after it
showed; past this many the oldest action is forgotten, and a click on
its notification runs `harness-notifications-desktop-unknown-click-function'.")

(defconst harness-notifications-desktop--backends
  '(notify-send dbus terminal-notifier applescript osascript w32)
  "Backends `auto' tries, in order; on macOS the macOS ones come first.
See `harness-notifications-desktop--auto-backends'.")

(defconst harness-notifications-desktop--macos-backends '(terminal-notifier applescript osascript)
  "The backends that work on macOS only, best first.")

;;;; Choosing a backend

(defun harness-notifications-desktop--notify-send-program ()
  "Return the notify-send executable, or nil."
  (and (stringp harness-notifications-desktop--notify-send)
       (not (string-empty-p harness-notifications-desktop--notify-send))
       (executable-find harness-notifications-desktop--notify-send)))

(defun harness-notifications-desktop--macos-program (name)
  "Return the executable NAME: on the path, else where Homebrew puts it.
The path is the variable `exec-path', and Homebrew's directories are
`harness-notifications-desktop--macos-bin-directories'."
  (and (stringp name)
       (not (string-empty-p name))
       (or (executable-find name)
           (and (not (file-name-absolute-p name))
                (cl-some (lambda (dir)
                           (let ((file (expand-file-name name dir)))
                             (and (file-executable-p file) (not (file-directory-p file)) file)))
                         harness-notifications-desktop--macos-bin-directories)))))

(defun harness-notifications-desktop--terminal-notifier-program ()
  "Return the terminal-notifier executable, or nil."
  (harness-notifications-desktop--macos-program harness-notifications-desktop--terminal-notifier))

(defun harness-notifications-desktop--macos-gui-p ()
  "Non-nil when this Emacs has a frame on the macOS window system."
  (and (cl-some (lambda (frame) (memq (framep frame) '(ns mac))) (frame-list)) t))

(defun harness-notifications-desktop--applescript-function ()
  "Return the function that runs AppleScript inside this Emacs, or nil.
That is `ns-do-applescript', or `mac-osa-script' on the Mac port, in a
graphical Emacs on macOS: a batch or terminal Emacs is no application
a notification could belong to."
  (and (not noninteractive)
       (harness-notifications-desktop--macos-gui-p)
       (cond ((fboundp 'ns-do-applescript) #'ns-do-applescript)
             ((fboundp 'mac-osa-script) #'mac-osa-script))))

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
    ('terminal-notifier (and (eq system-type 'darwin)
                             (harness-notifications-desktop--terminal-notifier-program)
                             t))
    ('applescript (and (eq system-type 'darwin) (harness-notifications-desktop--applescript-function) t))
    ('osascript (and (eq system-type 'darwin) (executable-find "osascript") t))
    ('w32 (and (fboundp 'w32-notification-notify) (not noninteractive) (display-graphic-p) t))
    (_ nil)))

(defun harness-notifications-desktop--auto-backends ()
  "Return the backends `auto' tries here, in order.
On macOS its own come first: a notify-send there, from Homebrew's
libnotify say, has no notification server to show anything."
  (if (eq system-type 'darwin)
      (append harness-notifications-desktop--macos-backends
              (cl-remove-if (lambda (b) (memq b harness-notifications-desktop--macos-backends))
                            harness-notifications-desktop--backends))
    harness-notifications-desktop--backends))

(defun harness-notifications-desktop-backend ()
  "Return the backend that shows notifications here: a symbol or a function.
nil when there is none: `auto' found nothing that works, or the
chosen backend cannot work in this Emacs."
  (let ((choice harness-notifications-desktop-backend))
    (cond ((eq choice 'auto)
           (cl-find-if #'harness-notifications-desktop--usable-p (harness-notifications-desktop--auto-backends)))
          ((memq choice harness-notifications-desktop--backends)
           (and (harness-notifications-desktop--usable-p choice) choice))
          ((functionp choice) choice))))

(defun harness-notifications-desktop-available-p ()
  "Non-nil when desktop notifications can be shown from this Emacs."
  (and (harness-notifications-desktop-backend) t))

(defun harness-notifications-desktop--missing-message ()
  "Say why no backend shows notifications here."
  (let ((choice harness-notifications-desktop-backend))
    (cond
     ((memq choice harness-notifications-desktop--backends)
      (format "The %s desktop notification backend does not work in this Emacs%s"
              choice
              (cond ((eq choice 'notify-send)
                     (format " (no %s program)" harness-notifications-desktop--notify-send))
                    ((and (memq choice harness-notifications-desktop--macos-backends)
                          (not (eq system-type 'darwin)))
                     " (macOS only)")
                    ((eq choice 'terminal-notifier)
                     (format " (no %s program)" harness-notifications-desktop--terminal-notifier))
                    ((eq choice 'applescript) " (a graphical Emacs only)")
                    (t ""))))
     ((eq system-type 'darwin)
      "No way to show desktop notifications here: install terminal-notifier (brew install terminal-notifier), or set harness-notifications-desktop-backend")
     (t
      "No way to show desktop notifications here: install notify-send (libnotify), use an Emacs with D-Bus support, or set harness-notifications-desktop-backend"))))

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
        ;; A notify-send that failed at once is gone already: its
        ;; sentinel says why, so sending it EOF would only signal.
        (when (process-live-p proc)
          (process-send-eof proc))))))

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

;;;; terminal-notifier (macOS)
;;
;; terminal-notifier hands the notification to macOS and exits.  A
;; click starts it again, with what the notification carries: the
;; application to bring to the front and a shell command to run.  The
;; command is emacsclient asking this Emacs, through its server, to run
;; the click action kept here under a key.

(defvar harness-notifications-desktop-unknown-click-function nil
  "Function of no arguments run for a click on a notification no longer known.
A terminal-notifier notification can be clicked in the Notification
Center after this Emacs restarted, or forgot it among
`harness-notifications-desktop-max-actions' newer ones.  The UI sets it
to show the sessions waiting for you.")

(defvar harness-notifications-desktop--actions nil
  "(KEY . FUNCTION) of clickable terminal-notifier notifications, newest first.
emacsclient names KEY when one is clicked, to
`harness-notifications-desktop-clicked'.")

(defvar harness-notifications-desktop--bundle-id 'unknown
  "Bundle identifier of the macOS application this Emacs runs from, once known.
`unknown' until it is looked up, nil when it runs from none.")

(defvar harness-notifications-desktop--click-warned nil
  "Non-nil once the log said why clicks cannot open what they are about.")

(defun harness-notifications-desktop--app-bundle ()
  "Return the macOS application bundle this Emacs's program is in, or nil.
That is .../Emacs.app for .../Emacs.app/Contents/MacOS/Emacs."
  (let ((dir (and (stringp invocation-directory)
                  (directory-file-name (expand-file-name invocation-directory)))))
    (and dir
         (string-match "\\`\\(.+\\.app\\)/Contents/MacOS\\(?:/.*\\)?\\'" dir)
         (match-string 1 dir))))

(defun harness-notifications-desktop--read-bundle-id (bundle)
  "Return the CFBundleIdentifier of the Info.plist of BUNDLE, or nil.
Only an XML property list is read, as Emacs.app's is."
  (let ((file (expand-file-name "Contents/Info.plist" bundle)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file nil 0 65536)
        (goto-char (point-min))
        (and (re-search-forward (concat "<key>CFBundleIdentifier</key>[[:space:]]*"
                                        "<string>[[:space:]]*\\([^<[:space:]]+\\)[[:space:]]*</string>")
                                nil t)
             (match-string 1))))))

(defun harness-notifications-desktop--bundle-id ()
  "Return the bundle identifier of the macOS application this Emacs is, or nil.
It is read from the application's Info.plist, once: GNU Emacs's own,
org.gnu.Emacs, when that cannot be read, and nil when this Emacs runs
from no application, as a terminal Emacs from Homebrew's Emacs formula
does."
  (when (eq harness-notifications-desktop--bundle-id 'unknown)
    (setq harness-notifications-desktop--bundle-id
          (let ((bundle (harness-notifications-desktop--app-bundle)))
            (and bundle
                 (or (ignore-errors (harness-notifications-desktop--read-bundle-id bundle))
                     "org.gnu.Emacs")))))
  harness-notifications-desktop--bundle-id)

(defun harness-notifications-desktop--activate-id ()
  "Return the bundle id of the application a click brings to the front, or nil.
That is `harness-notifications-desktop-macos-app' when set.  Else it is
this Emacs's own application when it shows graphical frames, and in the
harness process (a batch Emacs), the application its program is in: the
user's Emacs runs it from there.  Else it is the terminal this Emacs
runs in, which macOS names in the environment (__CFBundleIdentifier)."
  (let ((app harness-notifications-desktop-macos-app)
        (terminal (getenv "__CFBundleIdentifier")))
    (cond ((and (stringp app) (not (string-empty-p app))) app)
          ((and (or noninteractive (harness-notifications-desktop--macos-gui-p))
                (harness-notifications-desktop--bundle-id)))
          ((and (stringp terminal) (not (string-empty-p terminal))) terminal))))

(defun harness-notifications-desktop--emacsclient ()
  "Return the full name of the emacsclient that goes with this Emacs, or nil.
It is looked for beside this Emacs's program, then, for an Emacs.app,
where its builds keep it: in Contents/MacOS/bin/ (or bin-ARCH/), or in
the bin/ beside the application, as Homebrew installs it.  Then on the
variable `exec-path' and in Homebrew's directories.  A click runs it
with only the system's directories on its path, hence the full name."
  (let* ((dir (and (stringp invocation-directory)
                   (file-name-as-directory (expand-file-name invocation-directory))))
         (bundle (harness-notifications-desktop--app-bundle))
         (macos (and bundle (expand-file-name "Contents/MacOS/" bundle)))
         (candidates
          (append (and dir (list (expand-file-name "emacsclient" dir)))
                  (and macos
                       (cons (expand-file-name "bin/emacsclient" macos)
                             (file-expand-wildcards (expand-file-name "bin-*/emacsclient" macos))))
                  (and bundle
                       (list (expand-file-name "bin/emacsclient"
                                               (file-name-directory (directory-file-name bundle))))))))
    (or (cl-some (lambda (file) (and (file-executable-p file) (not (file-directory-p file)) file))
                 candidates)
        (let ((found (harness-notifications-desktop--macos-program "emacsclient")))
          (and found (expand-file-name found))))))

(defun harness-notifications-desktop--server-options ()
  "Return the emacsclient options that reach this Emacs's server, or nil.
nil when no server runs here (see `server-start')."
  (let ((server (bound-and-true-p server-process)))
    (when (and (processp server) (process-live-p server))
      ;; `server-start' keeps the file it made: the socket, or for a TCP
      ;; server the file with its address and key.
      (let ((file (process-get server :server-file)))
        (if (eq (process-contact server :family) 'local)
            (let ((socket (or file (process-contact server :service))))
              (and (stringp socket) (list (concat "--socket-name=" (expand-file-name socket)))))
          (let ((file (or file
                          (and (stringp server-name) (boundp 'server-auth-dir) (stringp server-auth-dir)
                               (expand-file-name server-name server-auth-dir)))))
            (and (stringp file) (file-exists-p file)
                 (list (concat "--server-file=" (expand-file-name file))))))))))

(defun harness-notifications-desktop--click-command (key)
  "Return the shell command that runs click action KEY in this Emacs, or nil.
It runs emacsclient, which evaluates `harness-notifications-desktop-clicked'
on KEY in this Emacs, through its server: nil when no server runs here
or no emacsclient is found.  macOS runs the command with /bin/sh."
  (let ((client (harness-notifications-desktop--emacsclient))
        (server (harness-notifications-desktop--server-options)))
    (and client server
         (mapconcat (lambda (arg) (shell-quote-argument arg t))
                    (append (list client)
                            server
                            ;; Never start an Emacs when this one is gone.
                            (list "--alternate-editor=false"
                                  "--eval"
                                  (format "(and (fboundp '%s) (%s %S))"
                                          'harness-notifications-desktop-clicked
                                          'harness-notifications-desktop-clicked
                                          key)))
                    " "))))

(defun harness-notifications-desktop--remember-action (key fn)
  "Keep click action FN under KEY.
Past `harness-notifications-desktop-max-actions' the oldest is forgotten."
  (push (cons key fn) harness-notifications-desktop--actions)
  (let ((last (nthcdr (1- (max 1 harness-notifications-desktop-max-actions))
                      harness-notifications-desktop--actions)))
    (when last (setcdr last nil))))

(defun harness-notifications-desktop--forget-action (key)
  "Forget the click action kept under KEY."
  (setq harness-notifications-desktop--actions
        (cl-remove key harness-notifications-desktop--actions :key #'car :test #'equal)))

(defun harness-notifications-desktop-clicked (key)
  "Run the click action of the notification KEY names, from the command loop.
emacsclient calls this when a terminal-notifier notification is clicked
\(see `harness-notifications-desktop--click-command').  A KEY this Emacs
does not know, as after a restart, runs
`harness-notifications-desktop-unknown-click-function' instead.
Return nil."
  (let* ((cell (and (stringp key) (assoc key harness-notifications-desktop--actions)))
         (fn (if cell (cdr cell) harness-notifications-desktop-unknown-click-function)))
    (when cell (harness-notifications-desktop--forget-action key))
    (when fn
      ;; Out of the server's process filter first.
      (harness-run-soon (lambda ()
                          (harness-ignore-errors-logged "notification click"
                            (funcall fn))))))
  nil)

(defun harness-notifications-desktop--terminal-notifier-value (text)
  "Return TEXT as the value of a terminal-notifier option.
terminal-notifier reads its options through NSUserDefaults, which takes
a value starting with `[', `(', `{' or a quote for a property list, and
one starting with `-' for the next option.  terminal-notifier drops one
backslash in front of a value, which keeps any value as it is."
  (concat "\\" text))

(defun harness-notifications-desktop--terminal-notifier-args (params &optional activate command)
  "Return the terminal-notifier arguments for PARAMS.
ACTIVATE is the bundle id of the application a click brings to the
front, COMMAND the shell command a click runs; either may be nil."
  (let* ((title (plist-get params :title))
         (title (and (stringp title) (not (string-empty-p title)) title))
         (body (plist-get params :body))
         (body (and (stringp body) (not (string-empty-p body)) body)))
    (append
     ;; A message is required: with no body the title is the message,
     ;; under the harness's name.
     (list "-title" (harness-notifications-desktop--terminal-notifier-value
                     (if (and title body) title harness-notifications-desktop--app-name))
           "-message" (harness-notifications-desktop--terminal-notifier-value
                       (or body title harness-notifications-desktop--app-name)))
     (when activate
       (list "-activate" (harness-notifications-desktop--terminal-notifier-value activate)))
     (when command
       (list "-execute" (harness-notifications-desktop--terminal-notifier-value command))))))

(defun harness-notifications-desktop--warn-unclickable (why)
  "Say once that clicks only bring Emacs to the front, because of WHY."
  (unless harness-notifications-desktop--click-warned
    (setq harness-notifications-desktop--click-warned t)
    (let ((text (format "a click on a notification brings Emacs to the front but cannot open what it is about: %s"
                        why)))
      (harness-log 'info "notifications: %s" text)
      (unless noninteractive
        (message "Harness: %s" text)))))

(defun harness-notifications-desktop--terminal-notifier (params)
  "Show PARAMS with terminal-notifier (macOS); return a promise.
A click brings this Emacs to the front and, for a notification with an
`:on-action', runs that action here through emacsclient
\(`harness-notifications-desktop--click-command')."
  (let* ((program (harness-notifications-desktop--terminal-notifier-program))
         (on-action (plist-get params :on-action))
         (key (and on-action (concat "n" (harness-short-id 12))))
         (command (and key (harness-notifications-desktop--click-command key))))
    (unless program (error "%s" (harness-notifications-desktop--missing-message)))
    (cond (command (harness-notifications-desktop--remember-action key on-action))
          (on-action
           (harness-notifications-desktop--warn-unclickable
            (if (harness-notifications-desktop--server-options)
                "no emacsclient program found"
              "the Emacs server is not running (M-x server-start)"))))
    (harness-then
     (harness-run-command (cons program (harness-notifications-desktop--terminal-notifier-args
                                         params (harness-notifications-desktop--activate-id) command))
                          :cwd (harness-notifications-desktop--local-directory)
                          :timeout 30 :name "harness-terminal-notifier")
     (lambda (r)
       (if (eq (plist-get r :exit) 0)
           (list :backend 'terminal-notifier)
         (when command (harness-notifications-desktop--forget-action key))
         (let ((err (string-trim (or (plist-get r :stderr) ""))))
           (signal 'error (list (format "terminal-notifier failed%s"
                                        (if (string-empty-p err)
                                            (format " (exit %s)" (plist-get r :exit))
                                          (concat ": " (car (last (split-string err "\n" t))))))))))))))

;;;; AppleScript in this Emacs (macOS)

(defun harness-notifications-desktop--applescript-string (text)
  "Return TEXT as an AppleScript string literal."
  (concat "\""
          (replace-regexp-in-string
           "[\\\"\n\r\t]"
           (lambda (c) (pcase c ("\\" "\\\\") ("\"" "\\\"") ("\n" "\\n") ("\r" "\\r") (_ "\\t")))
           (or text "") t t)
          "\""))

(defun harness-notifications-desktop--applescript-source (params)
  "Return the AppleScript that shows PARAMS as a notification."
  (format "display notification %s with title %s"
          (harness-notifications-desktop--applescript-string (plist-get params :body))
          (harness-notifications-desktop--applescript-string (plist-get params :title))))

(defun harness-notifications-desktop--applescript (params)
  "Show PARAMS as this Emacs's own notification (macOS); return a promise.
The AppleScript runs inside this Emacs, so macOS shows the notification
under Emacs's name and icon, and a click on it brings Emacs to the
front.  Nothing says which notification was clicked: PARAMS's
`:on-action' never runs."
  (let ((run (harness-notifications-desktop--applescript-function))
        (source (harness-notifications-desktop--applescript-source params)))
    (unless run (error "%s" (harness-notifications-desktop--missing-message)))
    (harness-with-promise (resolve reject)
      ;; Out of a process filter first: the script runs Emacs's event loop.
      (harness-run-soon (lambda ()
                          (condition-case err
                              (progn (funcall run source)
                                     (funcall resolve (list :backend 'applescript)))
                            (error (funcall reject err))))))))

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
the notification (with the backends that hear clicks: notify-send,
D-Bus, and terminal-notifier while the Emacs server runs).  The promise
rejects when no backend can show it, or the one chosen fails."
  (let ((backend (harness-notifications-desktop-backend)))
    (condition-case err
        (pcase backend
          ('nil (harness-rejected (list 'error (harness-notifications-desktop--missing-message))))
          ('notify-send (harness-notifications-desktop--notify-send params))
          ('dbus (harness-notifications-desktop--dbus params))
          ('terminal-notifier (harness-notifications-desktop--terminal-notifier params))
          ('applescript (harness-notifications-desktop--applescript params))
          ('osascript (harness-notifications-desktop--osascript params))
          ('w32 (harness-notifications-desktop--w32 params))
          (_ (harness-then (harness-as-promise (funcall backend params))
                           (lambda (_) (list :backend 'function)))))
      (error (harness-rejected err)))))

(provide 'harness-notifications-desktop)
;;; harness-notifications-desktop.el ends here
