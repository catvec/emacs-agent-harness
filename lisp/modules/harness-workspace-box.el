;;; harness-workspace-box.el --- A real desktop and VNC for the workspace  -*- lexical-binding: t; -*-

;;; Commentary:

;; The workspace's computer is a persistent private desktop on this
;; machine: an X display of its own, a window manager, a browser profile
;; of its own, and a real VNC server.  It is not a picture of a desktop.
;; A command started on it consumes its pixels, a click moves its
;; pointer, a screenshot is the framebuffer it is showing now, and the
;; app draws the same RFB stream x11vnc sends.
;;
;; The backend here is `local': the processes run on the host, in a
;; private home and on a display no other process uses.  The container
;; backend in the design is a stronger boundary and has its own task;
;; this module never pretends the local backend is one.  When the tools
;; are missing the box is `unavailable' with the names of what is
;; missing, and every computer method says so rather than drawing a
;; desk that cannot be touched.
;;
;; The seam is `workspace/box/*'.  `status' and `vnc' describe the
;; computer; `start' and `stop' own its lifecycle; `exec', `screenshot',
;; `windows', `launch', `clipboard' and the input methods are the hands
;; the presenter uses; `take-over' and `return-control' hand the screen
;; between the reviewer and the agent, and an input method refuses while
;; the reviewer has it.
;;
;; The screen reaches a client as an RFB socket, through the
;; `scripts/workspace-box/websockify.py' bridge and the noVNC page under
;; `scripts/workspace-box/novnc'.  The app speaks RFB itself; the page is
;; for a browser, and the same port serves both.
;;
;; The box outlives the chat and a harness restart: its record and the
;; pids are kept under the state directory, and a running box is adopted
;; by its pids when the module starts.  `reset' throws its home away;
;; `stop' keeps it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-util)
(require 'xml)
(require 'harness-core)
(require 'harness-util)
(require 'harness-store)

(defvar harness-state-directory)
(defvar harness-directory)

(defgroup harness-workspace-box nil
  "The private desktop and VNC of a workspace."
  :group 'harness
  :prefix "harness-workspace-box-")

(defcustom harness-workspace-box-backend 'auto
  "Which backend a workspace computer uses.
`auto' uses the local X display when its tools are present, and reports
what is missing otherwise.  The container backends of the design are
not implemented here; a name that is not `auto' or `local' fails closed
with that reason."
  :type '(choice (const :tag "Automatic" auto)
                 (const :tag "Local X display" local)
                 (const :tag "Unavailable" none))
  :group 'harness-workspace-box)

(defcustom harness-workspace-box-width 1280
  "Width of the workspace computer's screen, in pixels."
  :type 'integer
  :group 'harness-workspace-box)

(defcustom harness-workspace-box-height 800
  "Height of the workspace computer's screen, in pixels."
  :type 'integer
  :group 'harness-workspace-box)

(defcustom harness-workspace-box-tool-directories nil
  "Extra directories to look in for the box's tools.
A directory holds its executables directly, as a bin directory does.
An adjacent `../lib' is added to the tools' `LD_LIBRARY_PATH', which is
how a locally unpacked package works without installing it."
  :type '(repeat directory)
  :group 'harness-workspace-box)

(defcustom harness-workspace-box-tools '(Xvfb x11vnc xdotool xauth xdpyinfo
                                         python3 ffmpeg)
  "The tools the local box needs before it can start."
  :type '(repeat symbol)
  :group 'harness-workspace-box)

(defcustom harness-workspace-box-window-manager '("openbox" "fluxbox" "xfwm4")
  "Window managers tried in order, when one is present."
  :type '(repeat string)
  :group 'harness-workspace-box)

(defcustom harness-workspace-box-browser "firefox"
  "The browser started in the box for a URL, or nil for none."
  :type '(choice (const :tag "None" nil) (string :tag "Program"))
  :group 'harness-workspace-box)

(defcustom harness-workspace-box-autostart-browser t
  "Whether starting the box opens the local start page in its browser."
  :type 'boolean
  :group 'harness-workspace-box)

(defcustom harness-workspace-box-web-root nil
  "The noVNC directory served by the box, or nil for the bundled one."
  :type '(choice (const :tag "Bundled" nil) (directory :tag "Directory"))
  :group 'harness-workspace-box)

(defcustom harness-workspace-box-exec-timeout 120
  "Seconds a foreground box command may take before it is stopped."
  :type 'integer
  :group 'harness-workspace-box)

(defcustom harness-workspace-box-output-limit 200000
  "Most characters of a box command's output that is returned."
  :type 'integer
  :group 'harness-workspace-box)

(defcustom harness-workspace-box-screenshot-timeout 15
  "Seconds a screenshot may take."
  :type 'integer
  :group 'harness-workspace-box)

(defconst harness-workspace-box--directory "workspace-box"
  "Directory under the state directory that holds box records and homes.")

(defvar harness-workspace-box--records (make-hash-table :test 'equal)
  "Workspace id -> box record read from disk or made here.")

(defvar harness-workspace-box--processes (make-hash-table :test 'equal)
  "Workspace id -> plist of live process objects, by role.")

(defvar harness-workspace-box--loaded nil
  "Non-nil once the box records were read from disk.")

(defvar harness-workspace-box--subscribed nil
  "Non-nil once the module follows workspace deletion.")

;;;; Small helpers

(defun harness-workspace-box--workspace (id)
  "Return workspace ID, or signal."
  (unless (and (stringp id) (harness-method-exists-p 'workspace/get))
    (signal 'harness-error (list "No workspace for the computer")))
  (harness-call 'workspace/get id))

(defun harness-workspace-box--record-path (id)
  "Return the state record path of workspace ID's box."
  (concat harness-workspace-box--directory "/" id ".json"))

(defun harness-workspace-box--root (id)
  "Return the private directory of workspace ID's box."
  (expand-file-name (concat harness-workspace-box--directory "/" id "/")
                    harness-state-directory))

(defun harness-workspace-box--home (id)
  "Return the home volume of workspace ID's box."
  (expand-file-name "home/" (harness-workspace-box--root id)))

(defun harness-workspace-box--tmp (id)
  "Return the private temporary directory of workspace ID's box."
  (expand-file-name "tmp/" (harness-workspace-box--root id)))

(defun harness-workspace-box--profile (id)
  "Return the browser profile directory of workspace ID's box."
  (expand-file-name "browser/" (harness-workspace-box--root id)))

(defun harness-workspace-box--auth (id)
  "Return the X authority file of workspace ID's box."
  (expand-file-name "xauth" (harness-workspace-box--root id)))

(defun harness-workspace-box--logs (id)
  "Return the log directory of workspace ID's box."
  (expand-file-name "logs/" (harness-workspace-box--root id)))

(defun harness-workspace-box--now ()
  "Return the current time as a float."
  (float-time))

(defun harness-workspace-box--string (value)
  "Return VALUE as a non-blank string, or nil."
  (let ((text (and (stringp value) (string-trim value))))
    (and text (not (string-empty-p text)) text)))

(defun harness-workspace-box--set (plist &rest pairs)
  "Return PLIST with each (KEY VALUE) of PAIRS set."
  (let ((out (copy-sequence plist)))
    (cl-loop for (key value) on pairs by #'cddr
             do (setq out (plist-put out key value)))
    out))

(defun harness-workspace-box--ensure-directories (id)
  "Make the private directories of workspace ID's box."
  (dolist (dir (list (harness-workspace-box--root id)
                     (harness-workspace-box--home id)
                     (harness-workspace-box--tmp id)
                     (harness-workspace-box--profile id)
                     (harness-workspace-box--logs id)))
    (harness-ensure-directory dir))
  (set-file-modes (harness-workspace-box--root id) #o700))

(defun harness-workspace-box--reason (code text)
  "Return a reason with CODE and TEXT."
  (list :code code :text text))

(defun harness-workspace-box--missing-tools ()
  "Return the box tools that are not found."
  (cl-remove-if #'harness-workspace-box--tool
                (append harness-workspace-box-tools nil)))

;;;; Tools and their environment

(defun harness-workspace-box--tool-directories ()
  "Return the directories the box's tools are looked for in."
  (append (ensure-list harness-workspace-box-tool-directories)
          (list exec-directory)))

(defun harness-workspace-box--tool (name)
  "Return the absolute path of tool NAME, or nil."
  (let ((name (if (symbolp name) (symbol-name name) name)))
    (or (executable-find name)
        (cl-loop for dir in (harness-workspace-box--tool-directories)
                 for file = (expand-file-name name dir)
                 when (file-executable-p file) return file))))

(defun harness-workspace-box--lib-directories ()
  "Return the library directories beside the declared tool directories."
  (delq nil
        (mapcar (lambda (dir)
                  (let ((lib (expand-file-name "../lib" dir)))
                    (and (file-directory-p lib) (expand-file-name lib))))
                (ensure-list harness-workspace-box-tool-directories))))

(defun harness-workspace-box--environment (id)
  "Return the environment list for workspace ID's computer."
  (let* ((home (harness-workspace-box--home id))
         (tmp (harness-workspace-box--tmp id))
         (record (harness-workspace-box--record id))
         (display (plist-get record :display))
         (libs (harness-workspace-box--lib-directories))
         (path (string-join
                (append (ensure-list harness-workspace-box-tool-directories)
                        (list (getenv "PATH")))
                ":")))
    (delq nil
          (list (concat "HOME=" home)
                (concat "XDG_CONFIG_HOME=" home ".config")
                (concat "XDG_DATA_HOME=" home ".local/share")
                (concat "XDG_CACHE_HOME=" home ".cache")
                (concat "XDG_STATE_HOME=" home ".local/state")
                (concat "XDG_RUNTIME_DIR=" tmp)
                (concat "TMPDIR=" tmp)
                (concat "PATH=" path)
                (concat "SHELL=" (or (executable-find "bash") "/bin/sh"))
                "TERM=xterm-256color"
                "LIBGL_ALWAYS_SOFTWARE=1"
                "GALLIUM_DRIVER=llvmpipe"
                (and display (concat "DISPLAY=" display))
                (concat "XAUTHORITY=" (harness-workspace-box--auth id))
                (and libs (concat "LD_LIBRARY_PATH="
                                  (string-join libs ":")))))))

(defun harness-workspace-box--raw-environment (id)
  "Return the environment for a box helper that must not see the host's.
The X server itself needs no display, but it must not inherit a session
that makes it look for a compositor or a runtime directory of the
user's."
  (harness-workspace-box--environment id))

(defun harness-workspace-box--call (id program args &optional timeout)
  "Run PROGRAM with ARGS for workspace ID; return (STATUS STDOUT STDERR).
The command runs in the box's environment and its output is bounded.
TIMEOUT defaults to `harness-workspace-box-exec-timeout'."
  (let* ((record (harness-workspace-box--record id))
         (default-directory (or (plist-get record :cwd)
                                (harness-workspace-box--home id)))
         (process-environment (harness-workspace-box--environment id))
         (buffer (generate-new-buffer " *harness box command*"))
         (timeout (or timeout harness-workspace-box-exec-timeout))
         (deadline (+ (float-time) timeout))
         (process nil)
         (status nil))
    (unwind-protect
        (progn
          (setq process
                (make-process :name "harness-workspace-box-call"
                              :buffer buffer :stderr buffer
                              :command (cons program args)
                              :noquery t :connection-type 'pipe
                              :coding 'no-conversion
                              :sentinel #'ignore))
          (set-process-query-on-exit-flag process nil)
          (while (and (process-live-p process) (< (float-time) deadline))
            (accept-process-output process 0.05))
          (when (process-live-p process)
            (delete-process process)
            (setq status "timeout"))
          (with-current-buffer buffer
            (set-buffer-multibyte nil)
            (let ((bytes (buffer-string)))
              (list (or status (process-exit-status process))
                      bytes nil))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun harness-workspace-box--call-text (id program args &optional timeout)
  "Run PROGRAM with ARGS and return its decoded stdout, or nil on failure."
  (let* ((result (harness-workspace-box--call id program args timeout))
         (status (nth 0 result))
         (bytes (nth 1 result)))
    (and (integerp status) (zerop status)
         (decode-coding-string bytes 'utf-8 t))))

;;;; Processes and ports

(defun harness-workspace-box--port-free-p (port)
  "Return non-nil when 127.0.0.1:PORT can be bound."
  (condition-case nil
      (let ((server (make-network-process :name "harness-box-port"
                                          :server t :host "127.0.0.1"
                                          :service port :family 'ipv4
                                          :noquery t :coding 'binary)))
        (delete-process server)
        t)
    (error nil)))

(defun harness-workspace-box--free-port ()
  "Return a free loopback TCP port."
  (let ((tries 0) port)
    (while (and (< tries 100)
                (not (and port (harness-workspace-box--port-free-p port))))
      (setq port (+ 20000 (random 30000))
            tries (1+ tries)))
    (or port (signal 'harness-error (list "No free port for the workspace computer")))))

(defun harness-workspace-box--port-open-p (port)
  "Return non-nil when 127.0.0.1:PORT accepts a connection now."
  (let ((process (ignore-errors
                   (make-network-process :name "harness-box-probe"
                                         :host "127.0.0.1" :service port
                                         :family 'ipv4 :nowait t
                                         :noquery t :coding 'binary))))
    (when process
      (unwind-protect
          (let ((deadline (+ (float-time) 1.0)) open)
            (while (and (not open) (< (float-time) deadline))
              (accept-process-output process 0.02)
              (setq open (memq (process-status process) '(open run))))
            (and open t))
        (ignore-errors (delete-process process))))))

(defun harness-workspace-box--wait-for-port (port &optional timeout)
  "Wait for PORT to accept a connection, for TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and (not (harness-workspace-box--port-open-p port))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (harness-workspace-box--port-open-p port)))

(defun harness-workspace-box--display-free-p (number)
  "Return non-nil when display NUMBER and its TCP port are free."
  (and (not (file-exists-p (format "/tmp/.X%d-lock" number)))
       (harness-workspace-box--port-free-p (+ 6000 number))))

(defun harness-workspace-box--free-display ()
  "Return a display number the local X server can use."
  (or (cl-loop for number from 90 to 199
               when (harness-workspace-box--display-free-p number)
               return number)
      (signal 'harness-error (list "No free display for the workspace computer"))))

(defun harness-workspace-box--process (id role program args &optional _log)
  "Start PROGRAM with ARGS for workspace ID as ROLE; return the process."
  (let* ((process-environment (harness-workspace-box--environment id))
         (default-directory (harness-workspace-box--home id))
         (buffer (get-buffer-create (format " *harness box %s %s*" id role))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (erase-buffer)))
    (let ((process (make-process
                    :name (format "harness box %s %s" id role)
                    :buffer buffer
                    :command (cons program args)
                    :noquery t :connection-type 'pipe
                    :coding 'no-conversion
                    :sentinel #'ignore)))
      (set-process-query-on-exit-flag process nil)
      (harness-workspace-box--put-process id role process)
      process)))

(defun harness-workspace-box--process-plist (id)
  "Return the live processes plist of workspace ID, making it."
  (or (gethash id harness-workspace-box--processes)
      (puthash id nil harness-workspace-box--processes)))

(defun harness-workspace-box--put-process (id role process)
  "Remember PROCESS as ROLE of workspace ID."
  (let ((plist (harness-workspace-box--process-plist id)))
    (puthash id (plist-put plist role process) harness-workspace-box--processes))
  process)

(defun harness-workspace-box--kill-process (process &optional timeout)
  "End PROCESS, waiting up to TIMEOUT before killing it."
  (when (processp process)
    (when (process-live-p process)
      (ignore-errors (signal-process process 'SIGTERM)))
    (let ((deadline (+ (float-time) (or timeout 3))))
      (while (and (process-live-p process) (< (float-time) deadline))
        (accept-process-output process 0.05)))
    (when (process-live-p process)
      (ignore-errors (delete-process process)))
    (ignore-errors (delete-process process))))

(defun harness-workspace-box--kill-pid (pid &optional timeout)
  "End PID, waiting up to TIMEOUT."
  (when (and (integerp pid) (process-attributes pid))
    (ignore-errors (signal-process pid 'SIGTERM))
    (let ((deadline (+ (float-time) (or timeout 3))))
      (while (and (process-attributes pid) (< (float-time) deadline))
        (accept-process-output nil 0.05)))
    (when (process-attributes pid)
      (ignore-errors (signal-process pid 'SIGKILL)))))

(defun harness-workspace-box--pids (record)
  "Return the recorded pids of RECORD as a plist."
  (append (plist-get record :pids) nil))

(defun harness-workspace-box--pids-alive-p (record)
  "Return non-nil when every recorded process of RECORD is alive."
  (let ((pids (harness-workspace-box--pids record)))
    (and pids
         (cl-every (lambda (entry)
                     (let ((pid (cdr entry)))
                       (and (integerp pid) (process-attributes pid))))
                   (cl-loop for (role pid) on pids by #'cddr
                            collect (cons role pid))))))

;;;; Records

(defun harness-workspace-box--load ()
  "Read the box records once."
  (unless harness-workspace-box--loaded
    (setq harness-workspace-box--loaded t)
    (clrhash harness-workspace-box--records)
    (dolist (name (harness-call 'store/list harness-workspace-box--directory "\\.json\\'"))
      (let ((record (ignore-errors (harness-call 'store/load name))))
        (when (and (listp record) (plist-get record :workspace))
          (puthash (plist-get record :workspace) record
                   harness-workspace-box--records))))))

(defun harness-workspace-box--record (id)
  "Return workspace ID's box record, or a fresh stopped one."
  (harness-workspace-box--load)
  (or (gethash id harness-workspace-box--records)
      (let ((record (list :workspace id :backend "local" :state "stopped"
                          :control "agent" :created (harness-workspace-box--now)
                          :updated (harness-workspace-box--now))))
        (puthash id record harness-workspace-box--records)
        record)))

(defun harness-workspace-box--save (record)
  "Persist RECORD and return it."
  (let ((record (plist-put (copy-sequence record) :updated (harness-workspace-box--now))))
    (puthash (plist-get record :workspace) record harness-workspace-box--records)
    (harness-call 'store/save (harness-workspace-box--record-path
                               (plist-get record :workspace))
                  record)
    record))

(defun harness-workspace-box--save-pids (id)
  "Write the live pids of workspace ID into its record."
  (let ((record (harness-workspace-box--record id))
        (pids nil))
    (cl-loop for (role process) on (harness-workspace-box--process-plist id) by #'cddr
             when (process-live-p process)
             do (setq pids (append pids (list role (process-id process)))))
    (harness-workspace-box--save
     (harness-workspace-box--set record
                                 :pids pids
                                 :state (if pids "running" (plist-get record :state))))))

;;;; Status

(defun harness-workspace-box--state (record)
  "Return the state of RECORD as it is now.
A record that says running is running only while its pids are; a
record whose pids are gone is stopped, not a screen that no longer
moves."
  (if (equal (plist-get record :state) "running")
      (if (harness-workspace-box--pids-alive-p record) "running" "stopped")
    (or (plist-get record :state) "stopped")))

(defun harness-workspace-box--url (record)
  "Return the noVNC page URL of RECORD, or nil."
  (when-let* ((port (plist-get record :web-port))
              (token (plist-get record :token)))
    (format "http://127.0.0.1:%d/vnc_lite.html?path=websockify%%3Ftoken%%3D%s&autoconnect=1"
            port (url-hexify-string token))))

(defun harness-workspace-box--socket (record)
  "Return the RFB WebSocket URL of RECORD, or nil.
On this machine the page's own bridge answers it.  A device on another
machine is sent the same path on the harness it signed in to, which
carries the bytes to the box's RFB port (see
`harness-workspace-box--acp-tunnel'); the workspace names the box, so
the device never names a port of this machine itself."
  (when-let* ((port (plist-get record :web-port))
              (token (plist-get record :token))
              (id (plist-get record :workspace)))
    (format "ws://127.0.0.1:%d/websockify?token=%s&workspace=%s"
            port (url-hexify-string token) (url-hexify-string id))))

(defun harness-workspace-box--missing-reason (backend)
  "Return why BACKEND cannot run here, or nil."
  (let ((backend (if (stringp backend) (intern backend) backend)))
    (cond
     ((not (memq backend '(auto local)))
      (harness-workspace-box--reason
       "backend-unavailable"
       (format "workspace computer backend %s unavailable" backend)))
     ((not (harness-workspace-box--tool 'Xvfb))
      (harness-workspace-box--reason "box-tools-missing"
                                     "workspace computer tools missing: Xvfb"))
     (t (let ((missing (harness-workspace-box--missing-tools)))
          (when missing
            (harness-workspace-box--reason
             "box-tools-missing"
             (format "workspace computer tools missing: %s"
                     (mapconcat (lambda (tool) (format "%s" tool)) missing ", ")))))))))

(defun harness-workspace-box--running-p (record)
  "Return non-nil when RECORD says its box runs now."
  (equal (harness-workspace-box--state record) "running"))

(defun harness-workspace-box--status (record)
  "Return RECORD as a status answer for a client."
  (let* ((id (plist-get record :workspace))
         (state (harness-workspace-box--state record))
         (running (equal state "running"))
         (missing (unless running
                    (harness-workspace-box--missing-reason
                     (or (plist-get record :backend) harness-workspace-box-backend))))
         (available (and running (not missing)))
         (plan (plist-get record :plan)))
    (list :workspace id
          :name (ignore-errors (plist-get (harness-workspace-box--workspace id) :name))
          :backend (or (plist-get record :backend) "local")
          :available (if available t :false)
          :running (if running t :false)
          :state state
          :health (cond ((not running) "stopped")
                        (missing "unavailable")
                        (t "running"))
          :reason (or missing
                      (and (not running)
                           (plist-get record :reason))
                      (and (not running)
                           (harness-workspace-box--reason "box-not-running"
                                                         "workspace computer not running")))
          :control (or (plist-get record :control) "agent")
          :display (plist-get record :display)
          :width (or (plist-get record :width) harness-workspace-box-width)
          :height (or (plist-get record :height) harness-workspace-box-height)
          :vnc-port (plist-get record :vnc-port)
          :web-port (plist-get record :web-port)
          :url (and running (harness-workspace-box--url record))
          :socket (and running (harness-workspace-box--socket record))
          :mounts nil
          :home (harness-workspace-box--home id)
          :profile (harness-workspace-box--profile id)
          :disk (ignore-errors (file-attribute-size (file-attributes (harness-workspace-box--root id))))
          :isolation "local display and process"
          :missing (and missing (harness-workspace-box--missing-tools))
          :plan plan
          :started (plist-get record :started)
          :updated (plist-get record :updated))))

(defun harness-workspace-box--emit-status (record)
  "Announce the status of RECORD."
  (let ((status (harness-workspace-box--status record)))
    (harness-emit 'workspace/box-status (plist-get record :workspace) status)
    status))

(defun harness-workspace-box--require-running (id)
  "Return workspace ID's running record, or signal a reason."
  (let ((record (harness-workspace-box--record id)))
    (unless (harness-workspace-box--running-p record)
      (signal 'harness-error
              (list (or (plist-get (harness-workspace-box--role-reason record) :text)
                        "workspace computer not running"))))
    record))

(defun harness-workspace-box--role-reason (record)
  "Return why RECORD's box is not running."
  (or (plist-get record :reason)
      (harness-workspace-box--missing-reason
       (or (plist-get record :backend) harness-workspace-box-backend))
      (harness-workspace-box--reason "box-not-running"
                                     "workspace computer not running")))

(defun harness-workspace-box--require-agent (id)
  "Signal when the reviewer has control of workspace ID's computer."
  (let ((record (harness-workspace-box--record id)))
    (when (equal (plist-get record :control) "user")
      (signal 'harness-error
              (list "The reviewer has control of the computer")))))

;;;; Start and stop

(defun harness-workspace-box--xauth (id display number)
  "Make the authority file of workspace ID for display NUMBER."
  (let* ((file (harness-workspace-box--auth id))
         (cookie (secure-hash 'sha256 (format "%s-%s-%s" id display (random 1000000))))
         (xauth (harness-workspace-box--tool 'xauth)))
    (unless xauth
      (signal 'harness-error (list "xauth is needed for the workspace computer")))
    (delete-file file t)
    (let ((process-environment (harness-workspace-box--environment id))
          (default-directory (harness-workspace-box--home id)))
      (with-temp-buffer
        (unless (eq 0 (call-process xauth nil t nil "-f" file "add"
                                    (format "127.0.0.1:%d" number) "."
                                    (substring cookie 0 32)))
          (signal 'harness-error
                  (list (format "xauth failed: %s" (string-trim (buffer-string))))))))
    (set-file-modes file #o600)
    file))

(defun harness-workspace-box--start-xvfb (id number)
  "Start the X server of workspace ID on display NUMBER."
  (let ((xvfb (harness-workspace-box--tool 'Xvfb))
        (auth (harness-workspace-box--auth id))
        (log (expand-file-name "xvfb.log" (harness-workspace-box--logs id))))
    (harness-workspace-box--process
     id 'xvfb xvfb
     (list (format ":%d" number)
           "-screen" "0"
           (format "%dx%dx24" harness-workspace-box-width harness-workspace-box-height)
           "-nolisten" "unix"
           "-listen" "tcp"
           "-auth" auth
           "-noreset"
           "-extension" "GLX")
     log)))

(defun harness-workspace-box--start-wm (id)
  "Start a window manager for workspace ID, when one is present."
  (when-let* ((wm (cl-some #'harness-workspace-box--tool
                           harness-workspace-box-window-manager)))
    (harness-workspace-box--process id 'wm wm nil)))

(defun harness-workspace-box--start-vnc (id port)
  "Start x11vnc for workspace ID on loopback PORT."
  (let ((vnc (harness-workspace-box--tool 'x11vnc)))
    (harness-workspace-box--process
     id 'vnc vnc
     (list "-display" (plist-get (harness-workspace-box--record id) :display)
           "-localhost" "-nopw" "-forever" "-shared" "-noshm" "-noxdamage"
           "-rfbport" (number-to-string port) "-quiet" "-norc"))))

(defun harness-workspace-box--web-root ()
  "Return the noVNC directory the box serves."
  (or (harness-workspace-box--string harness-workspace-box-web-root)
      (let ((default (expand-file-name "scripts/workspace-box/novnc"
                                       (or (bound-and-true-p harness-directory)
                                           default-directory))))
        (and (file-directory-p default) default))))

(defun harness-workspace-box--start-web (id port target token)
  "Start the WebSocket bridge of workspace ID."
  (let ((python (harness-workspace-box--tool 'python3))
        (web-root (harness-workspace-box--web-root))
        (script (expand-file-name "scripts/workspace-box/websockify.py"
                                  (or (bound-and-true-p harness-directory)
                                      default-directory))))
    (unless python
      (signal 'harness-error (list "python3 is needed for the workspace screen")))
    (unless (file-readable-p script)
      (signal 'harness-error (list (format "The workspace screen bridge is missing: %s" script))))
    (harness-workspace-box--process
     id 'web python
     (append (list script
                   "--listen" (format "127.0.0.1:%d" port)
                   "--target" (format "127.0.0.1:%d" target)
                   "--token" token)
             (when web-root (list "--web-root" web-root))))))

(defun harness-workspace-box--start-page (id)
  "Write the local start page of workspace ID and return its file URL."
  (let* ((file (expand-file-name "start.html" (harness-workspace-box--root id)))
         (workspace (ignore-errors (harness-workspace-box--workspace id)))
         (name (or (plist-get workspace :name) "Workspace")))
    (with-temp-file file
      (insert
       "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
       "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
       "<title>Workspace computer</title>"
       "<style>body{font:16px system-ui,sans-serif;margin:0;background:#101418;color:#e8eef4;}"
       "main{max-width:38rem;margin:12vh auto;padding:0 2rem;}"
       "h1{font-size:2.2rem;font-weight:600;margin:0 0 .4rem;}"
       "p{color:#9fb0c0;margin:.2rem 0 1.2rem;}"
       "code{background:#1b222a;padding:.15rem .35rem;border-radius:4px;}"
       "ul{line-height:1.8;color:#c9d6e2;}</style></head><body><main>"
       "<h1>" (xml-escape-string name) "</h1>"
       "<p>Workspace computer</p>"
       "<ul><li>Private display</li><li>Browser profile</li>"
       "<li>VNC screen</li><li>Commands in <code>~</code></li></ul>"
       "</main></body></html>\n"))
    (concat "file://" file)))

(defun harness-workspace-box--start-browser (id &optional url)
  "Start the box's browser on workspace ID at URL."
  (when-let* ((browser (harness-workspace-box--tool harness-workspace-box-browser)))
    (let* ((profile (harness-workspace-box--profile id))
           (page (or url (harness-workspace-box--start-page id)))
           (live (plist-get (harness-workspace-box--process-plist id) 'browser))
           (args (if (process-live-p live)
                     (list "--profile" profile "--new-window" page)
                   (list "--new-instance" "--profile" profile "--no-remote" page))))
      (harness-ensure-directory profile)
      (unless (process-live-p live)
        (harness-workspace-box--process id 'browser browser args)))))

(defun harness-workspace-box--start (id)
  "Start workspace ID's box, or return it when it already runs."
  (harness-workspace-box--workspace id)
  (let ((record (harness-workspace-box--record id)))
    (if (harness-workspace-box--running-p record)
        (harness-workspace-box--status record)
      (let ((missing (harness-workspace-box--missing-reason
                      (or (plist-get record :backend) harness-workspace-box-backend))))
        (if missing
            (progn
              (harness-workspace-box--save
               (harness-workspace-box--set record :state "failed" :reason missing))
              (harness-workspace-box--emit-status (harness-workspace-box--record id)))
          (harness-workspace-box--start-now id record))))))

(defun harness-workspace-box--start-now (id record)
  "Start the box of workspace ID from RECORD."
  (let ((record (harness-workspace-box--set record
                                            :state "starting"
                                            :control "agent"
                                            :reason nil
                                            :missing nil)))
    (harness-workspace-box--ensure-directories id)
    (harness-workspace-box--save record)
    (harness-workspace-box--emit-status record)
    (condition-case err
        (let* ((number (harness-workspace-box--free-display))
               (display (format "127.0.0.1:%d" number))
               (vnc-port (harness-workspace-box--free-port))
               (web-port (harness-workspace-box--free-port))
               (token (secure-hash 'sha256
                                   (format "%s-%s-%s" id (float-time) (random 1000000))))
               (record (harness-workspace-box--set
                        record
                        :display display
                        :number number
                        :vnc-port vnc-port
                        :web-port web-port
                        :token (substring token 0 32)
                        :width harness-workspace-box-width
                        :height harness-workspace-box-height
                        :started (harness-workspace-box--now))))
          (harness-workspace-box--xauth id display number)
          (harness-workspace-box--save record)
          (harness-workspace-box--put-process
           id 'xvfb (harness-workspace-box--start-xvfb id number))
          (let ((deadline (+ (float-time) 15)))
            (while (and (not (harness-workspace-box--display-ready-p id))
                        (< (float-time) deadline))
              (accept-process-output nil 0.1)))
          (unless (harness-workspace-box--display-ready-p id)
            (signal 'harness-error (list "The workspace display did not start")))
          (harness-workspace-box--start-wm id)
          (harness-workspace-box--put-process
           id 'vnc (harness-workspace-box--start-vnc id vnc-port))
          (unless (harness-workspace-box--wait-for-port vnc-port 10)
            (signal 'harness-error (list "The workspace VNC server did not start")))
          (harness-workspace-box--put-process
           id 'web (harness-workspace-box--start-web id web-port vnc-port
                                                    (plist-get record :token)))
          (unless (harness-workspace-box--wait-for-port web-port 10)
            (signal 'harness-error (list "The workspace screen bridge did not start")))
          (let ((running (harness-workspace-box--set record
                                                     :state "running"
                                                     :reason nil
                                                     :started (harness-workspace-box--now))))
            (harness-workspace-box--save running)
            (harness-workspace-box--save-pids id)
            (when harness-workspace-box-autostart-browser
              (ignore-errors (harness-workspace-box--start-browser id)))
            (harness-workspace-box--emit-status (harness-workspace-box--record id))
            (harness-workspace-box--status (harness-workspace-box--record id))))
      (error
       (let ((failed (harness-workspace-box--set
                      record
                      :state "failed"
                      :reason (harness-workspace-box--reason
                               "box-start-failed"
                               (harness-error-message err)))))
         (harness-workspace-box--stop-processes id)
         (harness-workspace-box--save failed)
         (harness-workspace-box--emit-status failed)
         (signal (car err) (cdr err)))))))

(defun harness-workspace-box--display-ready-p (id)
  "Return non-nil when the box's X display answers."
  (let* ((record (harness-workspace-box--record id))
         (display (plist-get record :display))
         (xdpyinfo (harness-workspace-box--tool 'xdpyinfo)))
    (and display xdpyinfo
         (let ((process-environment (harness-workspace-box--environment id)))
           (eq 0 (call-process xdpyinfo nil nil nil "-display" display))))))

(defun harness-workspace-box--stop-processes (id)
  "End every live process of workspace ID's box."
  (let ((plist (harness-workspace-box--process-plist id)))
    (dolist (role '(browser wm web vnc xvfb))
      (let ((process (plist-get plist role)))
        (harness-workspace-box--kill-process process)))
    (dolist (process (plist-get plist :commands))
      (harness-workspace-box--kill-process process))
    (puthash id nil harness-workspace-box--processes))
  ;; A record adopted after a restart has pids, not process objects.
  (let ((pids (harness-workspace-box--pids (harness-workspace-box--record id))))
    (cl-loop for (_role pid) on pids by #'cddr
             do (harness-workspace-box--kill-pid pid))))

(defun harness-workspace-box--stop (id)
  "Stop workspace ID's box, keeping its home and profile."
  (let ((record (harness-workspace-box--record id)))
    (harness-workspace-box--stop-processes id)
    (let ((stopped (harness-workspace-box--set record
                                               :state "stopped"
                                               :control "agent"
                                               :pids nil
                                               :reason nil
                                               :stopped (harness-workspace-box--now))))
      (harness-workspace-box--save stopped)
      (harness-workspace-box--emit-status stopped))))

(defun harness-workspace-box--reset (id &optional keep-home)
  "Stop workspace ID's box and remove its home unless KEEP-HOME."
  (let ((stopped (harness-workspace-box--stop id)))
    (ignore stopped)
    (unless (harness-json-true-p keep-home)
      (ignore-errors
        (delete-directory (harness-workspace-box--home id) t))
      (ignore-errors
        (delete-directory (harness-workspace-box--profile id) t)))
    (harness-workspace-box--status (harness-workspace-box--record id))))

;;;; Exec

(defun harness-workspace-box--shell-command (command)
  "Return COMMAND as a shell string."
  (if (listp command)
      (mapconcat #'shell-quote-argument
                 (mapcar (lambda (part) (format "%s" part)) command) " ")
    (format "%s" command)))

(defun harness-workspace-box--exec-sync (id command opts)
  "Run COMMAND in workspace ID and return its bounded result."
  (let* ((record (harness-workspace-box--require-running id))
         (cwd (or (harness-workspace-box--string (plist-get opts :cwd))
                  (plist-get record :home)
                  (harness-workspace-box--home id)))
         (timeout (or (plist-get opts :timeout) harness-workspace-box-exec-timeout))
         (shell (or (harness-workspace-box--tool "bash") "/bin/sh"))
         (process-environment (harness-workspace-box--environment id))
         (default-directory (if (file-directory-p cwd) cwd (harness-workspace-box--home id)))
         (buffer (generate-new-buffer " *harness box exec*"))
         (deadline (+ (float-time) timeout))
         (process nil)
         (status nil))
    (unwind-protect
        (progn
          (setq process
                (make-process :name "harness-workspace-box-exec"
                              :buffer buffer :stderr buffer
                              :command (list shell "-lc" (harness-workspace-box--shell-command command))
                              :noquery t :connection-type 'pipe :coding 'no-conversion
                              :sentinel #'ignore))
          (set-process-query-on-exit-flag process nil)
          (while (and (process-live-p process) (< (float-time) deadline))
            (accept-process-output process 0.05))
          (when (process-live-p process)
            (setq status "timeout")
            (delete-process process))
          (with-current-buffer buffer
            (set-buffer-multibyte nil)
            (let ((output (buffer-string)))
              (list :stdout (harness-workspace-box--clip output)
                    :stderr ""
                    :status (or status (process-exit-status process))
                    :cwd cwd))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun harness-workspace-box--clip (text)
  "Return TEXT clipped to `harness-workspace-box-output-limit'."
  (let ((text (decode-coding-string (or text "") 'utf-8 t)))
    (if (> (length text) harness-workspace-box-output-limit)
        (concat (substring text 0 harness-workspace-box-output-limit) "\n…")
      text)))

(defun harness-workspace-box--exec-background (id command opts)
  "Start COMMAND in workspace ID in the background and return its pid."
  (let* ((record (harness-workspace-box--require-running id))
         (cwd (or (harness-workspace-box--string (plist-get opts :cwd))
                  (plist-get record :home)
                  (harness-workspace-box--home id)))
         (shell (or (harness-workspace-box--tool "bash") "/bin/sh"))
         (process-environment (harness-workspace-box--environment id))
         (default-directory (if (file-directory-p cwd) cwd (harness-workspace-box--home id)))
         (process (make-process
                   :name "harness-workspace-box-command"
                   :buffer (get-buffer-create (format " *harness box command %s*" id))
                   :command (list shell "-lc" (harness-workspace-box--shell-command command))
                   :noquery t :connection-type 'pipe :coding 'no-conversion
                   :sentinel #'ignore)))
    (set-process-query-on-exit-flag process nil)
    (let ((plist (harness-workspace-box--process-plist id)))
      (puthash id (plist-put plist :commands (cons process (plist-get plist :commands)))
               harness-workspace-box--processes))
    (list :stdout "" :stderr "" :status nil :pid (process-id process)
          :cwd cwd :background t)))

;;;; Screenshot and input

(defun harness-workspace-box--screenshot (id &optional opts)
  "Return a PNG of workspace ID's screen, as base64 data."
  (let* ((record (harness-workspace-box--require-running id))
         (display (plist-get record :display))
         (width (or (plist-get opts :width) (plist-get record :width)
                    harness-workspace-box-width))
         (height (or (plist-get opts :height) (plist-get record :height)
                     harness-workspace-box-height))
         (ffmpeg (harness-workspace-box--tool 'ffmpeg)))
    (unless ffmpeg
      (signal 'harness-error (list "ffmpeg is needed for the workspace screenshot")))
    (let* ((process-environment (harness-workspace-box--environment id))
           (buffer (generate-new-buffer " *harness box screenshot*"))
           (deadline (+ (float-time) harness-workspace-box-screenshot-timeout))
           (process (make-process
                     :name "harness-workspace-box-screenshot"
                     :buffer buffer :stderr nil
                     :command (list ffmpeg "-hide_banner" "-loglevel" "error"
                                    "-f" "x11grab" "-video_size" (format "%dx%d" width height)
                                    "-i" display "-frames:v" "1"
                                    "-f" "image2pipe" "-vcodec" "png" "-")
                     :noquery t :connection-type 'pipe :coding 'binary
                     :sentinel #'ignore)))
      (unwind-protect
          (progn
            (set-process-query-on-exit-flag process nil)
            (while (and (process-live-p process) (< (float-time) deadline))
              (accept-process-output process 0.05))
            (when (process-live-p process)
              (delete-process process)
              (signal 'harness-error (list "The workspace screenshot timed out")))
            (with-current-buffer buffer
              (set-buffer-multibyte nil)
              (let ((bytes (buffer-string)))
                (unless (and (> (length bytes) 8)
                             (string-prefix-p "\211PNG" bytes))
                  (signal 'harness-error (list "The workspace screenshot was empty")))
                (list :mime "image/png"
                      :data (base64-encode-string bytes t)
                      :width width :height height
                      :bytes (length bytes)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun harness-workspace-box--xdo (id &rest args)
  "Run xdotool with ARGS in workspace ID; return its output."
  (harness-workspace-box--require-agent id)
  (let ((xdotool (harness-workspace-box--tool 'xdotool)))
    (unless xdotool
      (signal 'harness-error (list "xdotool is needed for the workspace screen")))
    (let ((result (harness-workspace-box--call id xdotool args 10)))
      (unless (and (integerp (nth 0 result)) (zerop (nth 0 result)))
        (signal 'harness-error
                (list (format "xdotool failed: %s"
                              (harness-workspace-box--clip (nth 1 result))))))
      (harness-workspace-box--clip (nth 1 result)))))

;;;; Browser profile

(defun harness-workspace-box--browser-dir (id)
  "Return the browser profile of workspace ID."
  (harness-workspace-box--profile id))

(defun harness-workspace-box--browser-file (id name)
  "Return file NAME in workspace ID's browser profile."
  (expand-file-name name (harness-workspace-box--browser-dir id)))

(defun harness-workspace-box--sqlite-open (file)
  "Open FILE with Emacs's SQLite support when it exists."
  (when (and (fboundp 'sqlite-open) (file-readable-p file))
    (condition-case nil (sqlite-open file) (error nil))))

(defun harness-workspace-box--browser-cookies (id)
  "Return the cookie metadata of workspace ID's browser profile."
  (let* ((file (harness-workspace-box--browser-file id "cookies.sqlite"))
         (db (harness-workspace-box--sqlite-open file)))
    (when db
      (unwind-protect
          (condition-case nil
              (sqlite-select db "SELECT host, COUNT(*), MAX(expiry) FROM moz_cookies GROUP BY host ORDER BY host")
            (error nil))
        (ignore-errors (sqlite-close db))))))

(defun harness-workspace-box--browser-sites (id)
  "Return the sites of workspace ID's browser profile, metadata only."
  (let ((rows (harness-workspace-box--browser-cookies id)))
    (mapcar (lambda (row)
              (list :origin (format "https://%s" (nth 0 row))
                    :cookies (nth 1 row)
                    :expires (nth 2 row)
                    :auth "unknown"))
            rows)))

(defun harness-workspace-box--browser-logins (id)
  "Return the saved site sessions of workspace ID's browser profile.
Only the site and when it was made and used are read; the encrypted
username and password are never read into a value."
  (let ((file (harness-workspace-box--browser-file id "logins.json")))
    (when (file-readable-p file)
      (ignore-errors
        (let* ((json (harness-json-parse (harness-read-file file)))
               (logins (plist-get json :logins)))
          (mapcar (lambda (login)
                    (let ((origin (or (plist-get login :hostname) "")))
                      (list :id (replace-regexp-in-string "\\`https?://" "" origin)
                            :origin origin
                            :username ""
                            :state "active"
                            :created (plist-get login :timeCreated)
                            :last-used (plist-get login :timeLastUsed))))
                  logins))))))

(defun harness-workspace-box--directory-size (dir)
  "Return the size of DIR's files, in bytes."
  (when (file-directory-p dir)
    (let ((total 0))
      (dolist (file (directory-files-recursively dir "" t))
        (when (file-regular-p file)
          (setq total (+ total (or (file-attribute-size (file-attributes file)) 0)))))
      total)))

(defun harness-workspace-box--browser (id)
  "Return workspace ID's browser resources, metadata only."
  (let* ((profile (harness-workspace-box--browser-dir id))
         (sites (harness-workspace-box--browser-sites id))
         (logins (harness-workspace-box--browser-logins id))
         (cookies (cl-loop for site in sites sum (or (plist-get site :cookies) 0)))
         (storage (harness-workspace-box--directory-size
                   (expand-file-name "storage" profile)))
         (cache (harness-workspace-box--directory-size
                 (expand-file-name "cache2" profile)))
         (permissions (let ((file (expand-file-name "permissions.sqlite" profile))
                            (db nil))
                        (setq db (harness-workspace-box--sqlite-open file))
                        (when db
                          (unwind-protect
                              (ignore-errors
                                (caar (sqlite-select db "SELECT COUNT(*) FROM moz_perms")))
                            (ignore-errors (sqlite-close db))))))
         (bytes (+ (or storage 0) (or cache 0))))
    (list :profile (list :label "browser" :kind "Firefox" :bytes bytes
                         :sites (length sites))
          :sites sites
          :logins logins
          :totals (list :cookies cookies :bytes bytes)
          :cookies cookies
          :storage storage
          :cache cache
          :permissions (or permissions 0)
          :bytes bytes
          :profile-path profile)))

;;;; Methods

(harness-defmethod workspace/box/status (workspace)
  "Return the state of WORKSPACE's computer.
The answer says the backend, whether it runs, its health and display,
the VNC and WebSocket ports, the URL of the noVNC page and the socket
an RFB client speaks to, who has control, and what is missing when it
cannot run.  A box that is not running answers `:running :false\' with a
reason; it never invents a screen."
  (harness-workspace-box--status (harness-workspace-box--record workspace)))

(harness-defmethod workspace/box/start (workspace)
  "Start WORKSPACE's computer, or return it when it already runs.
A missing tool leaves the box `failed\' with the tools named, and
signals nothing that a client cannot read."
  (harness-workspace-box--start workspace))

(harness-defmethod workspace/box/stop (workspace)
  "Stop WORKSPACE's computer; its home and browser profile stay."
  (harness-workspace-box--stop workspace))

(harness-defmethod workspace/box/reset (workspace &optional keep-home)
  "Stop WORKSPACE's computer and clear its home unless KEEP-HOME."
  (harness-workspace-box--reset workspace keep-home))

(harness-defmethod workspace/box/restart (workspace)
  "Stop and start WORKSPACE's computer."
  (harness-workspace-box--stop workspace)
  (harness-workspace-box--start workspace))

(defun harness-workspace-box--acp-tunnel (request _session)
  "Return the VNC target the authenticated tunnel REQUEST names.
A device cannot name a port of this machine: it names the workspace,
and only a running box's own loopback RFB port is answered."
  (harness-workspace-box--load)
  (let* ((id (cdr (assoc "workspace" (plist-get request :query))))
         (record (and (stringp id) (gethash id harness-workspace-box--records))))
    (when (and record (harness-workspace-box--running-p record))
      (when-let* ((port (plist-get record :vnc-port)))
        (list :host "127.0.0.1" :port port)))))

(harness-defmethod workspace/box/vnc (workspace)
  "Return the VNC endpoint of WORKSPACE's computer.
The URL is the noVNC page; the socket is the WebSocket an RFB client
speaks to.  A box that does not run answers `:available :false\' with
its reason."
  (let* ((record (harness-workspace-box--record workspace))
         (running (harness-workspace-box--running-p record))
         (reason (unless running
                   (or (plist-get (harness-workspace-box--status record) :reason)
                       (harness-workspace-box--role-reason record)))))
    (if running
        (list :available t
              :url (harness-workspace-box--url record)
              :socket (harness-workspace-box--socket record)
              :state (or (plist-get record :control) "agent")
              :reason nil)
      (list :available :false :url nil :socket nil
            :state "agent" :reason reason))))

(harness-defmethod workspace/box/take-over (workspace)
  "Give the reviewer control of WORKSPACE's computer.
The agent's input methods refuse until `workspace/box/return-control\'."
  (let* ((record (harness-workspace-box--record workspace))
         (record (plist-put (copy-sequence record) :control "user")))
    (harness-workspace-box--save record)
    (harness-workspace-box--emit-status record)))

(harness-defmethod workspace/box/return-control (workspace)
  "Return control of WORKSPACE's computer to the agent."
  (let* ((record (harness-workspace-box--record workspace))
         (record (plist-put (copy-sequence record) :control "agent")))
    (harness-workspace-box--save record)
    (harness-workspace-box--emit-status record)))

(harness-defmethod workspace/box/exec (workspace command &optional opts)
  "Run COMMAND in WORKSPACE's computer.
OPTS names `:cwd\' and `:background\'.  A background command returns its
pid at once; a foreground one returns its bounded output and status."
  (if (harness-json-true-p (plist-get opts :background))
      (harness-workspace-box--exec-background workspace command opts)
    (harness-workspace-box--exec-sync workspace command opts)))

(harness-defmethod workspace/box/screenshot (workspace &optional opts)
  "Return a PNG of WORKSPACE's current screen."
  (harness-workspace-box--screenshot workspace opts))

(harness-defmethod workspace/box/click (workspace x y &optional opts)
  "Click at X, Y on WORKSPACE's screen.
OPTS may name `:button\' (1, 2 or 3) and `:count\'."
  (let* ((button (or (plist-get opts :button) 1))
         (count (or (plist-get opts :count) 1))
         (repeat (if (> count 1) (list "--repeat" (number-to-string count)) nil)))
    (apply #'harness-workspace-box--xdo workspace
           (append (list "mousemove" "--sync" (number-to-string x) (number-to-string y)
                         "click")
                   repeat (list (number-to-string button))))))

(harness-defmethod workspace/box/type (workspace text)
  "Type TEXT into the window focused on WORKSPACE's screen."
  (harness-workspace-box--xdo workspace "type" "--clearmodifiers" "--delay" "12"
                              (format "%s" text)))

(harness-defmethod workspace/box/key (workspace key &optional opts)
  "Press KEY on WORKSPACE's screen.
KEY is an X keysym name (`Return\', `Tab\', `Left\') or one character."
  (ignore opts)
  (let ((key (format "%s" key)))
    (harness-workspace-box--xdo workspace "key" "--clearmodifiers"
                                (if (equal key " ") "space" key))))

(harness-defmethod workspace/box/scroll (workspace x y amount)
  "Scroll at X, Y on WORKSPACE's screen by AMOUNT clicks."
  (let* ((amount (if (numberp amount) (truncate amount) 0))
         (button (if (< amount 0) "4" "5"))
         (count (abs amount)))
    (when (> count 0)
      (harness-workspace-box--xdo workspace
                                  "mousemove" "--sync"
                                  (number-to-string x) (number-to-string y)
                                  "click" "--repeat" (number-to-string count) button))))

(harness-defmethod workspace/box/drag (workspace from to)
  "Drag the pointer on WORKSPACE's screen from FROM to TO."
  (let ((x1 (number-to-string (or (nth 0 from) 0)))
        (y1 (number-to-string (or (nth 1 from) 0)))
        (x2 (number-to-string (or (nth 0 to) 0)))
        (y2 (number-to-string (or (nth 1 to) 0))))
    (harness-workspace-box--xdo workspace
                                "mousemove" "--sync" x1 y1
                                "mousedown" "1"
                                "mousemove" "--sync" x2 y2
                                "mouseup" "1")))

(harness-defmethod workspace/box/windows (workspace)
  "Return the windows open on WORKSPACE's screen."
  (let* ((record (harness-workspace-box--require-running workspace))
         (display (plist-get record :display))
         (xwininfo (harness-workspace-box--tool "xwininfo")))
    (unless xwininfo
      (signal 'harness-error (list "xwininfo is needed for the workspace windows")))
    (let* ((process-environment (harness-workspace-box--environment workspace))
           (out (with-temp-buffer
                  (when (eq 0 (call-process xwininfo nil t nil "-display" display
                                            "-root" "-tree"))
                    (buffer-string)))))
      (list :windows (harness-workspace-box--parse-windows out)))))

(defun harness-workspace-box--parse-windows (text)
  "Return the windows in xwininfo TEXT as plists."
  (let (windows)
    (dolist (line (split-string (or text "") "\n"))
      (when (string-match
             "^[ \t]+\\(0x[0-9a-fA-F]+\\) \"\\([^\"]*\\)\".*[ \t]+\\([0-9]+\\)x\\([0-9]+\\)\\([+-][0-9]+\\)\\([+-][0-9]+\\)"
             line)
        (let ((title (match-string 2 line)))
          (unless (or (string-empty-p title)
                      (member title '("root" "Root")))
            (push (list :id (match-string 1 line)
                        :title title
                        :width (string-to-number (match-string 3 line))
                        :height (string-to-number (match-string 4 line))
                        :x (string-to-number (match-string 5 line))
                        :y (string-to-number (match-string 6 line)))
                  windows)))))
    (nreverse windows)))

(harness-defmethod workspace/box/launch (workspace what)
  "Open WHAT on WORKSPACE's computer.
A URL opens in the browser; anything else starts as a command in the
box's shell."
  (let ((what (harness-workspace-box--string what)))
    (unless what (signal 'harness-error (list "Nothing to launch")))
    (harness-workspace-box--require-running workspace)
    (if (string-match-p "\\`\\(?:https?\\|file\\)://" what)
        (progn
          (harness-workspace-box--start-browser workspace what)
          (list :launched what :kind "url"))
      (harness-workspace-box--exec-background
       workspace what (list :cwd (harness-workspace-box--home workspace))))))

(harness-defmethod workspace/browser/open (workspace url &optional opts)
  "Open URL in WORKSPACE's browser and return what was opened."
  (ignore opts)
  (harness-workspace-box--require-running workspace)
  (let ((url (harness-workspace-box--string url)))
    (unless url (signal 'harness-error (list "Opening a page needs a URL")))
    (harness-workspace-box--start-browser workspace url)
    (list :opened url :kind "browser" :profile "Firefox")))

(harness-defmethod workspace/browser/screenshot (workspace &optional opts)
  "Return a PNG of WORKSPACE's screen for the browser."
  (harness-workspace-box--screenshot workspace opts))

(harness-defmethod workspace/box/clipboard (workspace &optional text)
  "Read WORKSPACE's clipboard, or write TEXT to it."
  (harness-workspace-box--require-running workspace)
  (let ((xclip (harness-workspace-box--tool "xclip")))
    (unless xclip
      (signal 'harness-error (list "xclip is needed for the workspace clipboard")))
    (if text
        (let ((process-environment (harness-workspace-box--environment workspace)))
          (with-temp-buffer
            (insert (format "%s" text))
            (call-process-region (point-min) (point-max) xclip nil nil nil
                                 "-selection" "clipboard"))
          (list :text text :written t))
      (let ((process-environment (harness-workspace-box--environment workspace)))
        (with-temp-buffer
          (when (eq 0 (call-process xclip nil t nil "-selection" "clipboard" "-o"))
            (list :text (buffer-string))))))))

(harness-defmethod workspace/box/logs (workspace &optional lines)
  "Return the last LINES of workspace WORKSPACE's box logs."
  (let* ((dir (harness-workspace-box--logs workspace))
         (lines (or lines 40))
         (out nil))
    (dolist (file (ignore-errors (directory-files dir t "\\`[^.]")))
      (when (file-readable-p file)
        (let ((text (harness-read-file file)))
          (when (and text (not (string-empty-p text)))
            (push (format "== %s\n%s" (file-name-nondirectory file)
                          (string-join (last (split-string text "\n") lines) "\n"))
                  out)))))
    (list :logs (string-join (nreverse out) "\n\n"))))

(harness-defmethod workspace/box/browser (workspace)
  "Return WORKSPACE's browser profile resources, metadata only.
A box that is not running returns no profile rather than an empty one
that looks like a running browser."
  (if (harness-workspace-box--running-p (harness-workspace-box--record workspace))
      (harness-workspace-box--browser workspace)
    nil))

(defconst harness-workspace-box--browser-kinds
  '("cookies" "storage" "cache" "permissions")
  "The browser data `workspace/browser/clear' clears, in the order it answers.")

(defun harness-workspace-box--browser-kind (kind)
  "Return KIND, a browser data name, as its canonical string.
KIND may be a string or a symbol; anything else signals."
  (let ((name (cond ((stringp kind) (downcase (string-trim kind)))
                    ((symbolp kind) (symbol-name kind)))))
    (unless (member name harness-workspace-box--browser-kinds)
      (signal 'harness-error
              (list (format "Unknown browser data kind: %s" kind))))
    name))

(defun harness-workspace-box--browser-kinds (kinds)
  "Return KINDS normalized to the canonical browser data strings.
KINDS is nil for all of them, or one name, or a list of names, as
strings or symbols.  A name that is not one of the supported kinds
signals `harness-error' rather than clearing something else."
  (let ((requested (cond ((null kinds) harness-workspace-box--browser-kinds)
                         ((or (stringp kinds) (symbolp kinds)) (list kinds))
                         ((vectorp kinds) (append kinds nil))
                         ((listp kinds) kinds)
                         (t (signal 'harness-error
                                    (list (format "Browser data kinds must be a list: %s"
                                                  kinds)))))))
    (let ((names (mapcar #'harness-workspace-box--browser-kind requested)))
      (cl-remove-if-not (lambda (kind) (member kind names))
                        harness-workspace-box--browser-kinds))))

(defun harness-workspace-box--browser-default-port (scheme)
  "Return the default port of SCHEME, or nil."
  (pcase (and scheme (downcase scheme))
    ("http" 80)
    ("https" 443)
    ("ws" 80)
    ("wss" 443)
    (_ nil)))

(defun harness-workspace-box--browser-origin (origin)
  "Return (SCHEME HOST PORT) of ORIGIN, any part nil.
ORIGIN is a full origin (`https://stoneco.example') or a bare host as a
saved login is (`stoneco.example').  A scheme that ORIGIN names is kept;
a bare host has no scheme.  The path, query and fragment are not part
of an origin and are dropped.  A default port is nil."
  (let ((text (and (stringp origin) (string-trim origin))))
    (when (and text (not (string-empty-p text)))
      (let* ((explicit (and (string-match-p "\\`[A-Za-z][A-Za-z0-9+.-]*://" text) t))
             (uri (ignore-errors
                    (url-generic-parse-url (if explicit text (concat "https://" text)))))
             (scheme (and uri explicit (downcase (or (url-type uri) ""))))
             (host (and uri (url-host uri)))
             (port (and uri (url-portspec uri))))
        (when host
          (when (and port (equal port (harness-workspace-box--browser-default-port
                                       (or scheme "https"))))
            (setq port nil))
          (list (and scheme (not (string-empty-p scheme)) scheme)
                (downcase host) port))))))

(defun harness-workspace-box--storage-directory-parts (name)
  "Return (SCHEME HOST PORT) of NAME, a Firefox storage directory, or nil.
Firefox encodes an origin as `https+++host', with `+PORT' when the port
is not the scheme's default."
  (when (and (stringp name)
             (string-match "\\`\\([^+]+\\)\\+\\+\\+\\([^+]+\\)\\(?:\\+\\([0-9]+\\)\\)?\\'" name))
    (list (downcase (match-string 1 name))
          (downcase (match-string 2 name))
          (and (match-string 3 name) (string-to-number (match-string 3 name))))))

(defun harness-workspace-box--storage-origin-p (name origin)
  "Non-nil when NAME, a Firefox storage directory, belongs to ORIGIN.
An origin is a scheme, a host and a port; a subdomain, another scheme
or another port is another origin and does not match."
  (when-let* ((parts (harness-workspace-box--storage-directory-parts name))
              (want (harness-workspace-box--browser-origin origin)))
    (pcase-let ((`(,scheme ,host ,port) parts)
                (`(,want-scheme ,want-host ,want-port) want))
      (and (equal host want-host)
           (or (null want-scheme) (equal scheme want-scheme))
           (cond ((null want-port)
                  (or (null port)
                      (equal port (harness-workspace-box--browser-default-port scheme))))
                 (t (equal port want-port)))))))

(defun harness-workspace-box--storage-roots (profile)
  "Return the Firefox storage roots under PROFILE."
  (mapcar (lambda (name) (expand-file-name (concat "storage/" name) profile))
          '("default" "permanent" "temporary")))

(defun harness-workspace-box--clear-browser-storage (profile origin)
  "Delete only ORIGIN's storage directories under PROFILE.
The roots Firefox keeps (`default', `permanent' and `temporary') are
read one level deep; every other origin is left where it is.  Return
non-nil when a directory was deleted."
  (let ((deleted nil))
    (dolist (root (harness-workspace-box--storage-roots profile))
      (dolist (dir (ignore-errors (directory-files root t "\\`[^.]")))
        (when (and (file-directory-p dir)
                   (harness-workspace-box--storage-origin-p
                    (file-name-nondirectory (directory-file-name dir)) origin))
          (ignore-errors (delete-directory dir t))
          (unless (file-exists-p dir)
            (setq deleted t)))))
    deleted))

(defun harness-workspace-box--stop-browser (id)
  "Stop the browser of workspace ID, so its profile is not written.
Return non-nil when a browser was running and is stopped."
  (let ((browser (plist-get (harness-workspace-box--process-plist id) 'browser)))
    (when (process-live-p browser)
      (harness-workspace-box--kill-process browser)
      (let ((plist (harness-workspace-box--process-plist id)))
        (puthash id (plist-put plist 'browser nil) harness-workspace-box--processes))
      t)))

(defun harness-workspace-box--site-cookies (profile origin)
  "Delete ORIGIN's cookies in PROFILE.
A domain cookie (a host starting with a dot) of the site is ORIGIN's
too; another site's cookies stay.  Return non-nil when a row went."
  (let* ((file (expand-file-name "cookies.sqlite" profile))
         (db (harness-workspace-box--sqlite-open file))
         (host (nth 1 (harness-workspace-box--browser-origin origin))))
    (when (and db host)
      (unwind-protect
          (progn
            (sqlite-execute db "DELETE FROM moz_cookies WHERE host = ? OR host = ?"
                            (list host (concat "." host)))
            t)
        (ignore-errors (sqlite-close db))))))

(defun harness-workspace-box--origin-strings (origin)
  "Return the permission origins ORIGIN names, and no other.
ORIGIN is (SCHEME HOST PORT) from `harness-workspace-box--browser-origin';
a nil SCHEME means a bare host, whose origin may be either scheme.  A
default port is written both with and without its port, since Firefox
may store either form; another scheme or port is not this origin."
  (let* ((scheme (nth 0 origin))
         (host (nth 1 origin))
         (port (nth 2 origin))
         (schemes (if scheme (list scheme) '("https" "http"))))
    (when host
      (delete-dups
       (append
        (mapcar (lambda (scheme)
                  (format "%s://%s%s" scheme host
                          (if port (format ":%d" port) "")))
                schemes)
        (when (and port
                   (cl-some (lambda (scheme)
                              (equal port
                                     (harness-workspace-box--browser-default-port scheme)))
                            schemes))
          (mapcar (lambda (scheme) (format "%s://%s" scheme host))
                  schemes)))))))

(defun harness-workspace-box--clear-site-permissions (profile origin)
  "Delete ORIGIN's rows from PROFILE's permissions database.
Return non-nil when the answer is a deletion."
  (let* ((file (expand-file-name "permissions.sqlite" profile))
         (db (harness-workspace-box--sqlite-open file))
         (origins (harness-workspace-box--origin-strings
                   (harness-workspace-box--browser-origin origin))))
    (when (and db origins)
      (unwind-protect
          (progn
            (sqlite-execute
             db
             (format "DELETE FROM moz_perms WHERE origin IN (%s)"
                     (mapconcat (lambda (_) "?") origins ", "))
             origins)
            t)
        (ignore-errors (sqlite-close db))))))

(harness-defmethod workspace/browser/clear (id scope &optional origin kinds)
  "Clear browser data in workspace ID and return the resources answer.
SCOPE is `profile' or `site'; a site clear needs ORIGIN.  KINDS names
what to clear (`cookies', `storage', `cache', `permissions'), nil for
all of them.  A site clear is origin-scoped: other origins' cookies,
storage and permissions stay."
  (harness-workspace-box--workspace id)
  (unless (member scope '("profile" "site"))
    (signal 'harness-error (list (format "Unknown browser scope: %s" scope))))
  (when (and (equal scope "site")
             (not (and (stringp origin) (not (harness-string-blank-p origin)))))
    (signal 'harness-error (list "A site clear needs an origin")))
  (harness-workspace-box--require-running id)
  (let* ((profile (harness-workspace-box--browser-dir id))
         (origin (and (equal scope "site") origin))
         (site (and origin (nth 1 (harness-workspace-box--browser-origin origin))))
         (kinds (harness-workspace-box--browser-kinds kinds))
         (changed nil))
    ;; A running browser rewrites its stores; stop it so the clear is what
    ;; the next browser sees.
    (harness-workspace-box--stop-browser id)
    (when (member "cookies" kinds)
      (if site
          (setq changed (or (harness-workspace-box--site-cookies profile origin) changed))
        (let* ((file (expand-file-name "cookies.sqlite" profile))
               (db (harness-workspace-box--sqlite-open file)))
          (when db
            (unwind-protect
                (progn (sqlite-execute db "DELETE FROM moz_cookies")
                       (setq changed t))
              (ignore-errors (sqlite-close db)))))))
    (when (member "storage" kinds)
      (if site
          (setq changed (or (harness-workspace-box--clear-browser-storage profile origin)
                            changed))
        (let ((storage (expand-file-name "storage" profile)))
          (when (file-directory-p storage)
            (ignore-errors (delete-directory storage t))
            (unless (file-exists-p storage)
              (setq changed t))))))
    (when (member "cache" kinds)
      (let ((cache (expand-file-name "cache2" profile)))
        (when (file-directory-p cache)
          (ignore-errors (delete-directory cache t))
          (unless (file-exists-p cache)
            (setq changed t)))))
    (when (member "permissions" kinds)
      (if site
          (setq changed (or (harness-workspace-box--clear-site-permissions profile origin)
                            changed))
        (let* ((file (expand-file-name "permissions.sqlite" profile))
               (db (harness-workspace-box--sqlite-open file)))
          (when db
            (unwind-protect
                (progn (sqlite-execute db "DELETE FROM moz_perms")
                       (setq changed t))
              (ignore-errors (sqlite-close db)))))))
    (harness-emit 'workspace/changed id (harness-call 'workspace/get id))
    (append (harness-call 'workspace/resources/status id)
            (list :changed (and changed t) :scope scope :origin origin
                  :kinds kinds))))

(harness-defmethod workspace/browser/login/forget (id login)
  "Forget the saved site session LOGIN in workspace ID.
LOGIN is an origin (`https://stoneco.example') or a bare site.
The browser is stopped first, as for `workspace/browser/clear', and
only LOGIN's cookies and storage go: another origin of the profile
stays signed in."
  (harness-workspace-box--workspace id)
  (unless (and (stringp login) (not (harness-string-blank-p login)))
    (signal 'harness-error (list "Forgetting a login needs its site")))
  (harness-workspace-box--require-running id)
  (let* ((profile (harness-workspace-box--browser-dir id))
         (site (nth 1 (harness-workspace-box--browser-origin login)))
         (changed nil))
    (harness-workspace-box--stop-browser id)
    (when site
      (setq changed (or (harness-workspace-box--site-cookies profile login) changed))
      (setq changed (or (harness-workspace-box--clear-browser-storage profile login)
                        changed)))
    (harness-emit 'workspace/changed id (harness-call 'workspace/get id))
    (append (harness-call 'workspace/resources/status id)
            (list :changed (and changed t) :login login))))

;;;; Events and module

(defun harness-workspace-box--on-workspace-deleted (id &rest _)
  "Stop and forget the box of a deleted workspace ID."
  (when (gethash id harness-workspace-box--records)
    (ignore-errors (harness-workspace-box--stop-processes id))
    (remhash id harness-workspace-box--records)
    (ignore-errors (harness-call 'store/delete (harness-workspace-box--record-path id)))))

(defun harness-workspace-box--init ()
  "Read the box records and adopt the boxes that are still running."
  (harness-workspace-box--load)
  (harness-workspace-box--install-acp)
  (with-eval-after-load 'harness-acp (harness-workspace-box--install-acp))
  (with-eval-after-load 'harness-acp-remote (harness-workspace-box--install-acp))
  (unless harness-workspace-box--subscribed
    (setq harness-workspace-box--subscribed t)
    (harness-on 'workspace/deleted #'harness-workspace-box--on-workspace-deleted)))

(defun harness-workspace-box--install-acp ()
  "Expose the box methods and events to ACP clients."
  (when (boundp 'harness-acp-extra-method-prefixes)
    (add-to-list 'harness-acp-extra-method-prefixes "workspace/box/")
    (add-to-list 'harness-acp-extra-method-prefixes "workspace/browser/"))
  (when (boundp 'harness-acp-extra-events)
    (dolist (event '(workspace/box-status))
      (add-to-list 'harness-acp-extra-events event)))
  (when (boundp 'harness-acp-remote-tunnels)
    (setq harness-acp-remote-tunnels
          (assoc-delete-all "/workspace/vnc" harness-acp-remote-tunnels))
    (push (cons "/workspace/vnc" #'harness-workspace-box--acp-tunnel)
          harness-acp-remote-tunnels)))

(defun harness-workspace-box--shutdown ()
  "Stop following workspace deletions.  The boxes keep running."
  (when (boundp 'harness-acp-remote-tunnels)
    (setq harness-acp-remote-tunnels
          (assoc-delete-all "/workspace/vnc" harness-acp-remote-tunnels)))
  (when harness-workspace-box--subscribed
    (setq harness-workspace-box--subscribed nil)
    (harness-off (cons 'workspace/deleted #'harness-workspace-box--on-workspace-deleted))))

(harness-declare-event 'workspace/box-status "(WORKSPACE STATUS) when a workspace computer changed state.")

(harness-define-module 'workspace-box
  :doc "The workspace's computer: a private desktop and a real VNC screen."
  :requires '(store)
  :init #'harness-workspace-box--init
  :shutdown #'harness-workspace-box--shutdown)

(provide 'harness-workspace-box)
;;; harness-workspace-box.el ends here
