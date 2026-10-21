;;; harness-ui-acp-remote.el --- The remote control page: devices that sign in, and the ones that ask  -*- lexical-binding: t; -*-

;;; Commentary:

;; The UI half of the acp-remote module (harness-acp-remote.el), which
;; loads with it.
;;
;; A device signs in from its own ACP client, which lists "Approve in
;; Emacs" among its sign-in methods (and OpenID Connect, when a provider
;; is set up).  Choosing it asks the person here: the harness tells the
;; user at once (a message, a desktop notification and a count in the mode
;; line notifier), and `harness-remote-approve' (C-c h y), or the buttons of
;; the remote control page, say yes after comparing the code the page
;; shows with the one the client shows.
;;
;; `harness-remote-control' (C-c h P) shows whether the harness serves
;; phones and other devices on the network (the acp-remote module), the
;; ACP address their clients connect to, whether what they send is
;; encrypted, the devices that wait to be approved, and the devices
;; signed in.  A client that cannot sign in from its own screen is given a
;; token to keep instead (`harness-ui-acp-remote-create-token'): the
;; address and secret to put in its settings, shown once.
;;
;; Serving is kept across restarts of the harness: once it is on (s), the
;; harness serves again every time it starts, and the devices signed in
;; with a secret stay signed in.  When it is on but cannot serve (the port
;; is held by another process, the address does not exist yet) the page
;; says why while the harness tries again, and S turns it off.
;;
;; Keys: s starts or stops serving, S turns it off for good, a chooses the
;; address in links, w copies the ACP address, l the sign-in link of the
;; provider, y approves the device that waits (the one at point), n
;; refuses it, t makes a token, k revokes the device at point and K every
;; device, g refreshes.  Every key has a button.  Everything goes through ACP
;; (`_harness/acp/remote-*'), so the page shows the harness the UI is
;; connected to, here or elsewhere.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)

(declare-function harness-ui-notify-refresh "harness-ui-notify")
(defvar harness-ui-notify-segment-functions)
(defvar harness-notify-mode)

;; The names the page had while its module was ui-remote.
(define-obsolete-variable-alias 'harness-ui-remote-buffer-name
  'harness-ui-acp-remote-buffer-name "3.1")
(define-obsolete-variable-alias 'harness-ui-remote-mode-map
  'harness-ui-acp-remote-mode-map "3.1")
(define-obsolete-variable-alias 'harness-ui-remote-mode-hook
  'harness-ui-acp-remote-mode-hook "3.1")
(define-obsolete-function-alias 'harness-ui-remote-mode
  #'harness-ui-acp-remote-mode "3.1")
(define-obsolete-function-alias 'harness-ui-remote-toggle-serving
  #'harness-ui-acp-remote-toggle-serving "3.1")
(define-obsolete-function-alias 'harness-ui-remote-set-address
  #'harness-ui-acp-remote-set-address "3.1")
(define-obsolete-function-alias 'harness-ui-remote-copy-address
  #'harness-ui-acp-remote-copy-address "3.1")
(define-obsolete-function-alias 'harness-ui-remote-unpair
  #'harness-ui-acp-remote-revoke "3.1")
(define-obsolete-function-alias 'harness-ui-acp-remote-unpair
  #'harness-ui-acp-remote-revoke "3.2")
(define-obsolete-function-alias 'harness-ui-remote-refresh
  #'harness-ui-acp-remote-refresh "3.1")

(defcustom harness-ui-acp-remote-buffer-name "*harness remote*"
  "Name of the remote control buffer."
  :type 'string :group 'harness-ui)

(defcustom harness-ui-acp-remote-token-buffer-name "*harness device token*"
  "Name of the buffer that shows a token made for a device, once."
  :type 'string :group 'harness-ui)

(defface harness-remote-heading-face '((t :inherit bold :height 1.05))
  "Headings of the remote control page." :group 'harness-ui)

(defface harness-remote-label-face '((t :inherit shadow))
  "Labels of the remote control page." :group 'harness-ui)

(defface harness-remote-warning-face '((t :inherit warning))
  "Warnings of the remote control page." :group 'harness-ui)

(defface harness-remote-code-face '((t :inherit bold :height 1.1))
  "The code of a device that asks to be approved." :group 'harness-ui)

(defvar-local harness-ui-acp-remote--status nil "Last `acp/remote-status' received.")
(defvar-local harness-ui-acp-remote--error nil "Why the status could not be read, or nil.")

(defvar harness-ui-acp-remote--waiting nil
  "The devices that wait to be approved, as the harness last said, or nil.
Each is a plist (:id :code :name :address :origin :expires).")

(defvar harness-ui-acp-remote--seen nil
  "The ids of the requests the user was told of.")

;;;; Helpers

(defun harness-ui-acp-remote--true (key)
  "Non-nil when KEY of the status is true."
  (harness-json-true-p (plist-get harness-ui-acp-remote--status key)))

(defun harness-ui-acp-remote--corporate-p ()
  "Non-nil when corporate mode is on, in this Emacs or in the harness."
  (or (harness-corporate-p) (harness-ui-acp-remote--true :corporate)))

(defun harness-ui-acp-remote--time (time &optional seconds)
  "Format TIME, a float, as a clock time, with the date unless it is today.
With SECONDS the clock shows them."
  (let ((clock (if seconds "%H:%M:%S" "%H:%M")))
    (format-time-string (if (equal (format-time-string "%F" time) (format-time-string "%F"))
                            clock
                          (concat "%b %-d " clock))
                        time)))

(defun harness-ui-acp-remote--method-label (method)
  "Return how a device signed in, METHOD, in words."
  (pcase method
    ("approval" "approved in Emacs")
    ("token" "token")
    ("shared-secret" "shared secret")
    ("oidc" "OpenID Connect")
    (_ (or method "?"))))

(defun harness-ui-acp-remote--buffers ()
  "Return the live remote control buffers."
  (cl-remove-if-not (lambda (b) (with-current-buffer b (derived-mode-p 'harness-ui-acp-remote-mode)))
                    (buffer-list)))

(defun harness-ui-acp-remote--describe (approval)
  "Return APPROVAL, a device that asks to sign in, as a line of words."
  (format "%s at %s, code %s%s"
          (or (plist-get approval :name) "A device")
          (or (plist-get approval :address) "?")
          (plist-get approval :code)
          (if-let* ((origin (plist-get approval :origin))) (format ", from the page %s" origin) "")))

;;;; Rendering

(defun harness-ui-acp-remote--row (label &rest parts)
  "Insert a row: LABEL in its column, then PARTS (strings, or functions inserting)."
  (insert " " (propertize (string-pad label 15) 'face 'harness-remote-label-face))
  (dolist (part parts)
    (if (functionp part) (funcall part) (insert part)))
  (insert "\n"))

(defun harness-ui-acp-remote--header ()
  "Return the header line."
  (list (propertize " Remote control " 'face 'harness-remote-heading-face)
        (cond ((null harness-ui-acp-remote--status) "")
              ((harness-ui-acp-remote--corporate-p) (propertize " corporate mode" 'face 'harness-dim-face))
              ((harness-ui-acp-remote--true :running)
               (propertize (format " serving on port %s" (plist-get harness-ui-acp-remote--status :port))
                           'face 'harness-status-idle-face))
              ((harness-ui-acp-remote--true :enabled)
               (propertize " waiting to serve other devices" 'face 'harness-remote-warning-face))
              (t (propertize " not serving other devices" 'face 'harness-dim-face)))))

(defun harness-ui-acp-remote--insert-serving ()
  "Insert whether the harness serves other devices, and where."
  (let* ((s harness-ui-acp-remote--status)
         (running (harness-ui-acp-remote--true :running))
         (enabled (harness-ui-acp-remote--true :enabled))
         (why (plist-get s :resume-error)))
    ;; Serving is kept across restarts of the harness: it starts again by
    ;; itself while it is on.  So a page that says it is not served, though
    ;; it is on, says why and offers to stop trying.
    (harness-ui-acp-remote--row
     "Other devices"
     (cond
      (running
       (concat (harness-ui-status-icon 'idle) " "
               (propertize (format "served on port %s" (plist-get s :port)) 'face 'harness-status-idle-face)))
      (enabled
       (concat (harness-ui-level-icon 'caution) " "
               (propertize "not served yet" 'face 'harness-remote-warning-face)
               (propertize (if (harness-ui-acp-remote--true :resuming) ", trying again" "")
                           'face 'harness-dim-face)))
      (t (concat (harness-ui-status-icon 'inactive) " " (propertize "not served" 'face 'harness-dim-face))))
     "   "
     (lambda ()
       (harness-ui-button (cond (running "[stop]") (enabled "[try now]") (t "[start serving]"))
                          #'harness-ui-acp-remote-toggle-serving
                          :help (cond (running "Stop serving other devices, and do not start again with the harness; those that keep a secret stay signed in (s)")
                                      (enabled "Start the listener now instead of at the next try (s)")
                                      (t "Listen for phones and other devices on the network, now and whenever the harness starts (s)"))))
     (lambda ()
       (when (and enabled (not running))
         (insert " ")
         (harness-ui-button "[turn off]" #'harness-ui-acp-remote-turn-off
                            :help "Stop trying, and do not serve other devices when the harness starts (S)"))))
    ;; What it means, on a line of its own: the window may be narrow.
    (cond
     ((and running enabled)
      (harness-ui-acp-remote--row
       "" (propertize "starts again whenever the harness starts" 'face 'harness-dim-face)))
     (running
      (harness-ui-acp-remote--row
       "" (propertize "not kept: serving ends when the harness stops" 'face 'harness-remote-warning-face)))
     (enabled
      (harness-ui-acp-remote--row
       "" (propertize (if why (format "%s" why) "the listener did not start")
                      'face 'harness-remote-warning-face))))
    (harness-ui-acp-remote--row
     "ACP address"
     (propertize (or (plist-get s :ws-url) "") 'face (if running 'default 'harness-dim-face))
     "   "
     (lambda () (harness-ui-button "[copy]" #'harness-ui-acp-remote-copy-address
                                   :help "Copy the address a phone's ACP client connects to (w)")))
    (let* ((address (plist-get s :address))
           (candidate (cl-find address (plist-get s :addresses) :key (lambda (c) (plist-get c :address))
                               :test #'equal)))
      (harness-ui-acp-remote--row
       "This machine"
       address
       (propertize (cond (candidate (format " · %s · %s" (plist-get candidate :interface)
                                            (pcase (plist-get candidate :kind)
                                              ("lan" "local network") ("vpn" "VPN") (_ "network"))))
                         ((harness-json-true-p (plist-get s :address-set)) " · set by you")
                         (t ""))
                   'face 'harness-dim-face)
       "   "
       (lambda () (harness-ui-button "[change]" #'harness-ui-acp-remote-set-address
                                     :help "Choose the address of this machine that links carry (a)"))))
    (harness-ui-acp-remote--row
     "Encryption"
     (if (harness-ui-acp-remote--true :secure)
         (propertize "encrypted on its way (https, or a VPN)" 'face 'harness-status-idle-face)
       (propertize "none: use a VPN such as Tailscale, or a TLS proxy and harness-acp-remote-public-url"
                   'face 'harness-remote-warning-face)))
    (harness-ui-acp-remote--row
     "Sign in with"
     (if (harness-ui-acp-remote--true :approval)
         "Approve in Emacs"
       (propertize "approval in Emacs is off (harness-acp-remote-approval)" 'face 'harness-remote-warning-face))
     (propertize "  chosen in the device's ACP client" 'face 'harness-dim-face))
    (when-let* ((login (plist-get (plist-get s :oidc) :login-url)))
      (harness-ui-acp-remote--row
       ""
       (format "OpenID Connect, %s" (plist-get (plist-get s :oidc) :issuer))
       (if (harness-json-true-p (plist-get (plist-get s :oidc) :allowed))
           ""
         (propertize "  nobody is allowed yet: set harness-acp-remote-oidc-allowed" 'face 'harness-remote-warning-face))
       "   "
       (lambda () (harness-ui-button "[copy login link]" #'harness-ui-acp-remote-copy-login-link
                                     :help (format "Copy %s, which signs a browser in at the provider (l)" login)))))))

(defun harness-ui-acp-remote--insert-waiting ()
  "Insert the devices that wait to be approved."
  (insert " " (propertize "Waiting for approval" 'face 'harness-remote-heading-face) "\n")
  (let ((approvals (plist-get harness-ui-acp-remote--status :approvals)))
    (if (null approvals)
        (insert (propertize (if (harness-ui-acp-remote--true :running)
                                "   none: a device that chooses \"Approve in Emacs\" in its ACP client shows here\n"
                              "   start serving, and a device can ask\n")
                            'face 'harness-dim-face))
      (dolist (a approvals)
        (let ((start (point)))
          (insert "   " (propertize (harness-ui-icon 'harness-icon-question) 'face 'harness-notify-blocked-face) " "
                  (string-pad (harness-truncate-end (or (plist-get a :name) "unknown device") 36) 37)
                  (string-pad (or (plist-get a :address) "") 16)
                  (propertize (format "code %s" (plist-get a :code)) 'face 'harness-remote-code-face)
                  (propertize (format "  until %s" (harness-ui-acp-remote--time (plist-get a :expires) t))
                              'face 'harness-dim-face)
                  "   ")
          (let ((id (plist-get a :id)))
            (harness-ui-button "[approve]" (lambda () (harness-ui-acp-remote--approve a))
                               :help "Sign this device in, if its client shows the same code (y)")
            (insert " ")
            (harness-ui-button "[deny]" (lambda () (harness-ui-acp-remote--deny id))
                               :help "Refuse this device (n)"))
          (when-let* ((origin (plist-get a :origin)))
            (insert (propertize (format "  a web page: %s" origin) 'face 'harness-remote-warning-face)))
          (insert "\n")
          (put-text-property start (point) 'harness-ui-acp-remote-approval (plist-get a :id)))))))

(defun harness-ui-acp-remote--insert-devices ()
  "Insert the signed-in devices."
  (insert " " (propertize "Signed-in devices" 'face 'harness-remote-heading-face) "\n")
  (let ((devices (plist-get harness-ui-acp-remote--status :devices)))
    (if (null devices)
        (insert (propertize "   no device signed in yet\n" 'face 'harness-dim-face))
      (dolist (d devices)
        (let ((start (point))
              (connected (and (numberp (plist-get d :connected)) (> (plist-get d :connected) 0))))
          (insert "   " (harness-ui-status-icon (if connected 'idle 'inactive)) " "
                  (string-pad (harness-truncate-end (or (plist-get d :name) "unknown device") 36) 37)
                  (string-pad (or (plist-get d :address) "") 16)
                  (propertize (format "%s, seen %s, %s%s"
                                      (harness-ui-acp-remote--method-label (plist-get d :method))
                                      (harness-ui-acp-remote--time (plist-get d :seen))
                                      (if (harness-json-true-p (plist-get d :ephemeral))
                                          "this connection only"
                                        (format "until %s" (harness-ui-acp-remote--time (plist-get d :expires))))
                                      (if connected ", connected" ""))
                              'face 'harness-dim-face)
                  "   ")
          (let ((id (plist-get d :id)) (name (plist-get d :name)))
            (harness-ui-button "[revoke]" (lambda () (harness-ui-acp-remote--revoke id name))
                               :help "End this device's session and close its connections (k)"))
          (insert "\n")
          (put-text-property start (point) 'harness-ui-acp-remote-device (plist-get d :id)))))
    (insert "   ")
    (harness-ui-button "[make a token]" #'harness-ui-acp-remote-create-token
                       :help "Make a secret to put in the settings of a client that cannot sign in itself (t)")
    (when (cdr devices)
      (insert "  ")
      (harness-ui-button "[revoke all]" #'harness-ui-acp-remote-revoke-all
                         :help "End every device's session (K)"))
    (insert "\n")))

(defun harness-ui-acp-remote--render ()
  "Redraw the page from the last status, keeping the line."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (erase-buffer)
    (setq header-line-format (harness-ui-acp-remote--header))
    (insert "\n")
    (cond
     (harness-ui-acp-remote--error
      (insert " " (propertize (format "This harness cannot serve other devices: %s" harness-ui-acp-remote--error)
                              'face 'error)
              "\n"))
     ((null harness-ui-acp-remote--status)
      (insert " " (propertize "Loading…" 'face 'harness-dim-face) "\n"))
     ((harness-ui-acp-remote--corporate-p)
      (insert " " (propertize "Corporate mode is on." 'face 'harness-remote-heading-face) "\n\n"
              " This harness serves no other device, and this Emacs\n"
              " connects to no harness elsewhere.  See `harness-corporate-mode'.\n"))
     (t
      (harness-ui-acp-remote--insert-serving)
      (insert "\n")
      (harness-ui-acp-remote--insert-waiting)
      (insert "\n")
      (harness-ui-acp-remote--insert-devices)
      (insert "\n"
              (propertize (concat " A device signs in from its ACP client: the client shows how (\"Approve in Emacs\"),\n"
                                  " and its user compares the code it shows with the one here.  The sign-in is for\n"
                                  " that connection.  A client that keeps a secret, such as the harness's own app,\n"
                                  " is given one and signs in with it next time; any other can be given a token.\n"
                                  " A device's network address is shown here and proves nothing.\n")
                          'face 'harness-dim-face))))
    (goto-char (point-min))
    (forward-line (1- line))))

;;;; Talking to the harness

(defun harness-ui-acp-remote--refresh (&optional buffer)
  "Fetch the status for BUFFER (default the current one) and redraw it."
  (let ((buf (or buffer (current-buffer))))
    (harness-ui-call "_harness/acp/remote-status" nil
                     (lambda (status)
                       (harness-ui-acp-remote--note-waiting status)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-ui-acp-remote--status status harness-ui-acp-remote--error nil)
                           (harness-ui-acp-remote--render))))
                     (lambda (e)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-ui-acp-remote--error (harness-error-message e))
                           (harness-ui-acp-remote--render)))
                       nil))))

(defun harness-ui-acp-remote--note-waiting (status)
  "Remember the devices that wait to be approved, from STATUS.
The user is told of each new one."
  (let ((approvals (plist-get status :approvals)))
    (dolist (a approvals)
      (unless (member (plist-get a :id) harness-ui-acp-remote--seen)
        (push (plist-get a :id) harness-ui-acp-remote--seen)
        (message "Harness: %s asks to sign in.  Approve it only if its client shows that code: C-c h y"
                 (harness-ui-acp-remote--describe a))))
    (unless (equal (mapcar (lambda (a) (plist-get a :id)) approvals)
                   (mapcar (lambda (a) (plist-get a :id)) harness-ui-acp-remote--waiting))
      (setq harness-ui-acp-remote--waiting approvals)
      (when (and (bound-and-true-p harness-notify-mode) (fboundp 'harness-ui-notify-refresh))
        (harness-ui-notify-refresh)))))

;;;; Commands

(defun harness-ui-acp-remote--check ()
  "Refuse in corporate mode and without a status."
  (when (harness-ui-acp-remote--corporate-p)
    (user-error "Corporate mode is on: the harness serves no other device"))
  (unless harness-ui-acp-remote--status
    (user-error "The remote control status has not arrived yet")))

(defun harness-ui-acp-remote-toggle-serving ()
  "Start serving phones and other devices, or stop."
  (interactive)
  (harness-ui-acp-remote--check)
  (let ((running (harness-ui-acp-remote--true :running))
        (buf (current-buffer)))
    (harness-ui-call (if running "_harness/acp/remote-stop" "_harness/acp/remote-start") nil
                     (lambda (status)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-ui-acp-remote--status status)
                           (harness-ui-acp-remote--render)))
                       (message (if running "Harness: no longer serving other devices"
                                  "Harness: serving other devices on port %s")
                                (plist-get status :port))))))

(defun harness-ui-acp-remote-turn-off ()
  "Turn serving off: stop it, stop trying, and do not serve at the next start.
It is what `s' does while the harness serves; this is for when it is on
but does not serve (the port is taken, say) and `s' would only try again."
  (interactive)
  (harness-ui-acp-remote--check)
  (let ((buf (current-buffer)))
    (harness-ui-call "_harness/acp/remote-stop" nil
                     (lambda (status)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-ui-acp-remote--status status)
                           (harness-ui-acp-remote--render)))
                       (message "Harness: no longer serving other devices, and not at the next start")))))

(defun harness-ui-acp-remote-set-address ()
  "Choose the address of this machine that the ACP address and links carry."
  (interactive)
  (harness-ui-acp-remote--check)
  (let* ((choices (append
                   (mapcar (lambda (c)
                             (cons (format "%s  %s, %s" (plist-get c :address) (plist-get c :interface)
                                           (pcase (plist-get c :kind)
                                             ("lan" "local network") ("vpn" "VPN") (_ "network")))
                                   (plist-get c :address)))
                           (plist-get harness-ui-acp-remote--status :addresses))
                   (list (cons "Detect it" "") (cons "Another address…" 'other))))
         (choice (completing-read "Address of this machine: " choices nil t))
         (value (cdr (assoc choice choices)))
         (buf (current-buffer)))
    (when (eq value 'other)
      (setq value (read-string "Address of this machine: ")))
    (harness-ui-call "_harness/acp/remote-set-address" (list :address value)
                     (lambda (status)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-ui-acp-remote--status status)
                           (harness-ui-acp-remote--render)))
                       (message "Harness: the ACP address is now %s" (plist-get status :ws-url))))))

(defun harness-ui-acp-remote-copy-address ()
  "Copy the address a phone's ACP client connects to."
  (interactive)
  (harness-ui-acp-remote--check)
  (let ((url (plist-get harness-ui-acp-remote--status :ws-url)))
    (kill-new url)
    (message "Copied %s" url)))

(defun harness-ui-acp-remote-copy-login-link ()
  "Copy the link a browser opens to sign in at the OpenID Connect provider."
  (interactive)
  (harness-ui-acp-remote--check)
  (let ((url (plist-get (plist-get harness-ui-acp-remote--status :oidc) :login-url)))
    (unless url
      (user-error "OpenID Connect is not set up (harness-acp-remote-oidc-issuer)"))
    (kill-new url)
    (message "Copied %s: it signs a browser in with a session secret to copy" url)))

(defun harness-ui-acp-remote--approve (approval)
  "Sign the device APPROVAL describes in, once the user says its code matches."
  (when (y-or-n-p (format "Approve %s?  Its client must show the code %s. "
                          (or (plist-get approval :name) "this device") (plist-get approval :code)))
    (harness-ui-call "_harness/acp/remote-approve" (list :id (plist-get approval :id))
                     (lambda (_) (message "Harness: signed in %s" (or (plist-get approval :name) "the device")))
                     (lambda (e) (message "Harness: %s" (harness-error-message e)) nil))))

(defun harness-ui-acp-remote--deny (id)
  "Refuse the device whose request has the id ID."
  (harness-ui-call "_harness/acp/remote-deny" (list :id id)
                   (lambda (_) (message "Harness: refused the device"))
                   (lambda (e) (message "Harness: %s" (harness-error-message e)) nil)))

(defun harness-ui-acp-remote--approval-at-point ()
  "Return the waiting device at point, else the only one that waits, else nil."
  (let* ((approvals (plist-get harness-ui-acp-remote--status :approvals))
         (id (get-text-property (point) 'harness-ui-acp-remote-approval)))
    (or (and id (cl-find id approvals :key (lambda (a) (plist-get a :id)) :test #'equal))
        (and (null (cdr approvals)) (car approvals)))))

(defun harness-ui-acp-remote-approve ()
  "Approve the device that waits: the one at point, or the only one."
  (interactive)
  (harness-ui-acp-remote--check)
  (harness-ui-acp-remote--approve
   (or (harness-ui-acp-remote--approval-at-point)
       (user-error (if (plist-get harness-ui-acp-remote--status :approvals)
                       "Put point on the device to approve"
                     "No device waits to be approved")))))

(defun harness-ui-acp-remote-deny ()
  "Refuse the device that waits: the one at point, or the only one."
  (interactive)
  (harness-ui-acp-remote--check)
  (harness-ui-acp-remote--deny
   (plist-get (or (harness-ui-acp-remote--approval-at-point)
                  (user-error (if (plist-get harness-ui-acp-remote--status :approvals)
                                  "Put point on the device to refuse"
                                "No device waits to be approved")))
              :id)))

;;;###autoload
(defun harness-remote-approve ()
  "Approve a device that asks to sign in to the harness.
It asks which, when several wait.  Approve only a device whose ACP client
shows the code you are asked about: that is how the person at this Emacs
knows which device it is."
  (interactive)
  (harness-ui-call "_harness/acp/remote-status" nil
                   (lambda (status)
                     (harness-ui-acp-remote--note-waiting status)
                     (let ((approvals (plist-get status :approvals)))
                       (cond
                        ((null approvals) (message "Harness: no device waits to be approved"))
                        (t
                         (let* ((choices (mapcar (lambda (a) (cons (harness-ui-acp-remote--describe a) a)) approvals))
                                (chosen (if (cdr choices)
                                            (cdr (assoc (completing-read "Approve which device? " choices nil t)
                                                        choices))
                                          (cdar choices))))
                           (harness-ui-acp-remote--approve chosen)))))))
  nil)

(defun harness-ui-acp-remote--revoke (id name)
  "End the session of the device ID, called NAME."
  (when (yes-or-no-p (format "Revoke %s and close its connections? " name))
    (harness-ui-call "_harness/acp/remote-revoke" (list :id id)
                     (lambda (_) (message "Harness: revoked %s" name)))))

(defun harness-ui-acp-remote-revoke ()
  "Revoke the device at point: its session ends and its connections close."
  (interactive)
  (let* ((id (or (get-text-property (point) 'harness-ui-acp-remote-device)
                 (user-error "No signed-in device at point")))
         (device (cl-find id (plist-get harness-ui-acp-remote--status :devices)
                          :key (lambda (d) (plist-get d :id)) :test #'equal)))
    (harness-ui-acp-remote--revoke id (or (plist-get device :name) id))))

(defun harness-ui-acp-remote-revoke-all ()
  "Revoke every device: every session ends and every connection closes."
  (interactive)
  (harness-ui-acp-remote--check)
  (unless (plist-get harness-ui-acp-remote--status :devices)
    (user-error "No device is signed in"))
  (when (yes-or-no-p "Revoke every signed-in device and close their connections? ")
    (harness-ui-call "_harness/acp/remote-revoke-all" nil
                     (lambda (n) (message "Harness: revoked %s device%s" n (if (eql n 1) "" "s"))))))

(defun harness-ui-acp-remote-refresh ()
  "Fetch the status again."
  (interactive)
  (harness-ui-acp-remote--refresh))

;;;; A token for a client that cannot sign in itself

(defvar harness-ui-acp-remote-token-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-view-map)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    map)
  "Keymap of `harness-ui-acp-remote-token-mode'.")

(define-derived-mode harness-ui-acp-remote-token-mode special-mode "Token"
  "Major mode of the buffer that shows a token made for a device.
\\{harness-ui-acp-remote-token-mode-map}"
  (setq truncate-lines t buffer-read-only t))

(defun harness-ui-acp-remote--copy (what text)
  "Copy TEXT, WHAT it is, to the kill ring."
  (kill-new text)
  (message "Copied the %s" what))

(defun harness-ui-acp-remote--show-token (token)
  "Show TOKEN, the answer of `acp/remote-create-token', in a buffer of its own.
The secret is in no other place, and the buffer is not kept."
  (let ((buf (get-buffer-create harness-ui-acp-remote-token-buffer-name))
        (secret (plist-get token :token))
        (address (plist-get token :ws-url))
        (url (plist-get token :url)))
    (with-current-buffer buf
      (harness-ui-acp-remote-token-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (setq header-line-format (list (propertize " A token for " 'face 'harness-remote-heading-face)
                                       (plist-get token :name)))
        (insert "\n"
                " " (propertize (string-pad "Address" 15) 'face 'harness-remote-label-face) address "   ")
        (harness-ui-button "[copy]" (lambda () (harness-ui-acp-remote--copy "address" address)))
        (insert "\n"
                " " (propertize (string-pad "Token" 15) 'face 'harness-remote-label-face) secret "   ")
        (harness-ui-button "[copy]" (lambda () (harness-ui-acp-remote--copy "token" secret)))
        (insert "\n"
                " " (propertize (string-pad "Both" 15) 'face 'harness-remote-label-face)
                (propertize "the address with the token in it" 'face 'harness-dim-face) "   ")
        (harness-ui-button "[copy]" (lambda () (harness-ui-acp-remote--copy "address with the token" url)))
        (insert "\n\n"
                (propertize (concat " Put the address and the token in the settings of the device's ACP client\n"
                                    " (ACP UI: the address, and a header `Authorization: Bearer TOKEN'; Agmente:\n"
                                    " \"Bearer token\"), or give a client that takes one address the one with the\n"
                                    " token in it.  The device then needs no approval.\n\n"
                                    " It is shown here once: the harness keeps only its hash.  Whoever has it\n"
                                    " is that device until you revoke it on the remote control page.")
                            'face 'harness-dim-face)
                "\n"))
      (goto-char (point-min))
      (forward-button 1 t))
    (harness-ui-display-view buf)))

(defun harness-ui-acp-remote-create-token (name)
  "Make a token for a device called NAME, and show it once.
It is for a client that has a place for a secret and no way to sign in
from its own screen: it presents the token as it connects."
  (interactive (list (read-string "Name of the device: " "Phone")))
  (harness-ui-acp-remote--check)
  (unless (harness-ui-acp-remote--true :running)
    (user-error "Start serving other devices first (s)"))
  (harness-ui-call "_harness/acp/remote-create-token" (list :name name)
                   #'harness-ui-acp-remote--show-token))

;;;; Mode

(defvar harness-ui-acp-remote-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map harness-ui-view-map)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "s") #'harness-ui-acp-remote-toggle-serving)
    (define-key map (kbd "S") #'harness-ui-acp-remote-turn-off)
    (define-key map (kbd "a") #'harness-ui-acp-remote-set-address)
    (define-key map (kbd "w") #'harness-ui-acp-remote-copy-address)
    (define-key map (kbd "l") #'harness-ui-acp-remote-copy-login-link)
    (define-key map (kbd "y") #'harness-ui-acp-remote-approve)
    (define-key map (kbd "n") #'harness-ui-acp-remote-deny)
    (define-key map (kbd "t") #'harness-ui-acp-remote-create-token)
    (define-key map (kbd "k") #'harness-ui-acp-remote-revoke)
    (define-key map (kbd "d") #'harness-ui-acp-remote-revoke)
    (define-key map (kbd "K") #'harness-ui-acp-remote-revoke-all)
    (define-key map (kbd "g") #'harness-ui-acp-remote-refresh)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-acp-remote-mode'.")

(define-derived-mode harness-ui-acp-remote-mode special-mode "Remote"
  "Major mode of the remote control page.
\\{harness-ui-acp-remote-mode-map}"
  (setq truncate-lines t buffer-read-only t))

;; The page's keys in the harness menu, behind `.'.
(put 'harness-ui-acp-remote-mode 'harness-menu-group
     '("Remote control"
       ["Serving"
        (". s" "Start or stop serving" harness-ui-acp-remote-toggle-serving)
        (". S" "Turn serving off, and stop trying" harness-ui-acp-remote-turn-off)
        (". a" "Address of this machine" harness-ui-acp-remote-set-address)
        (". w" "Copy the ACP address" harness-ui-acp-remote-copy-address)
        (". g" "Refresh" harness-ui-acp-remote-refresh)]
       ["Devices"
        (". y" "Approve the device that waits" harness-ui-acp-remote-approve)
        (". n" "Refuse the device that waits" harness-ui-acp-remote-deny)
        (". t" "Make a token for a device" harness-ui-acp-remote-create-token)
        (". l" "Copy the OpenID Connect sign-in link" harness-ui-acp-remote-copy-login-link)
        (". k" "Revoke device at point" harness-ui-acp-remote-revoke)
        (". K" "Revoke every device" harness-ui-acp-remote-revoke-all)]))

;;;###autoload
(defun harness-remote-control ()
  "Show the remote control page: serve phones, approve them, see who is signed in."
  (interactive)
  (let ((buf (get-buffer-create harness-ui-acp-remote-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-acp-remote-mode) (harness-ui-acp-remote-mode))
      (harness-ui-acp-remote--render))
    (harness-ui-display-view buf)
    (harness-ui-acp-remote--refresh buf)))

;;;; Following the harness

(defconst harness-ui-acp-remote--changes
  '("approval" "signed-in" "disconnected" "connected" "revoked" "expired" "started" "stopped"
    "waiting" "address" "corporate")
  "What `acp/remote-changed' says that the page, and what waits, follow.")

(defun harness-ui-acp-remote--on-event (event args)
  "Follow EVENT with ARGS: look at the harness again when `acp/remote-changed'.
The page redraws, and the devices that wait are counted for the notifier."
  (when (equal event "acp/remote-changed")
    (let* ((info (car args))
           (what (plist-get info :what)))
      (when (member what harness-ui-acp-remote--changes)
        (if-let* ((buffers (harness-ui-acp-remote--buffers)))
            (dolist (buf buffers) (harness-ui-acp-remote--refresh buf))
          ;; No page open: only what waits matters, once there is something.
          (when (or harness-ui-acp-remote--waiting (equal what "approval"))
            (harness-ui-call "_harness/acp/remote-status" nil #'harness-ui-acp-remote--note-waiting #'ignore))))
      (when (equal what "signed-in")
        (message "Harness: a device signed in from %s" (plist-get info :address))))))

(defun harness-ui-acp-remote--redraw-all ()
  "Refresh every remote control page, after a reload or reconnect."
  (dolist (buf (harness-ui-acp-remote--buffers))
    (harness-ui-acp-remote--refresh buf)))

(defvar harness-ui-acp-remote--segment-map nil
  "Keymap of the notifier's segment: a click approves the device that waits.")

;; Made at top level, not in the `defvar', so a reload updates it.
(setq harness-ui-acp-remote--segment-map (harness-ui-mouse-keymap #'harness-remote-approve))

(defun harness-ui-acp-remote--segment ()
  "The mode line notifier's segment for the devices that wait, or nil.
On `harness-ui-notify-segment-functions'."
  (when harness-ui-acp-remote--waiting
    (propertize (format " %s%d" (harness-ui-icon 'harness-icon-question) (length harness-ui-acp-remote--waiting))
                'face 'harness-notify-blocked-face
                'help-echo (format "A device asks to sign in to the harness: %s.  Click to approve it."
                                   (harness-ui-acp-remote--describe (car harness-ui-acp-remote--waiting)))
                'mouse-face 'mode-line-highlight
                'local-map harness-ui-acp-remote--segment-map)))

(defun harness-ui-acp-remote--init ()
  "Wire the page into the UI."
  (add-hook 'harness-ui-event-functions #'harness-ui-acp-remote--on-event)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-acp-remote--redraw-all)
  (add-hook 'harness-ui-notify-segment-functions #'harness-ui-acp-remote--segment)
  (define-key harness-ui-map (kbd "P") #'harness-remote-control)
  (define-key harness-ui-map (kbd "y") #'harness-remote-approve))

(defun harness-ui-acp-remote--shutdown ()
  "Unwire the page, and forget what waited."
  (remove-hook 'harness-ui-event-functions #'harness-ui-acp-remote--on-event)
  (remove-hook 'harness-ui-redraw-hook #'harness-ui-acp-remote--redraw-all)
  (remove-hook 'harness-ui-notify-segment-functions #'harness-ui-acp-remote--segment)
  (when (eq (lookup-key harness-ui-map (kbd "P")) #'harness-remote-control)
    (define-key harness-ui-map (kbd "P") nil t))
  (when (eq (lookup-key harness-ui-map (kbd "y")) #'harness-remote-approve)
    (define-key harness-ui-map (kbd "y") nil t))
  (setq harness-ui-acp-remote--waiting nil
        harness-ui-acp-remote--seen nil))

(harness-define-module 'ui-acp-remote
  :doc "Remote control page: serve phones and other devices, approve and see them."
  :requires '(ui)
  :init #'harness-ui-acp-remote--init
  :shutdown #'harness-ui-acp-remote--shutdown)

(provide 'harness-ui-acp-remote)
;;; harness-ui-acp-remote.el ends here
