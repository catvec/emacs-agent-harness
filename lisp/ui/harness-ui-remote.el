;;; harness-ui-remote.el --- The remote control page: phones paired by QR code  -*- lexical-binding: t; -*-

;;; Commentary:

;; `harness-remote-control' (C-c h P) shows whether the harness serves
;; phones and other devices on the network (the acp-remote module), the
;; ACP address their clients connect to, and the paired devices.  The
;; pairing QR code starts folded: it carries a one-time code that pairs
;; whichever device scans it, so it shows only when asked for, and a
;; fresh code is made each time it unfolds.  It folds again once a
;; device pairs or the code expires, and hiding it drops the code.
;;
;; Keys: TAB folds or unfolds the QR code (elsewhere it moves between
;; buttons), s starts or stops serving, a chooses the address in links,
;; w copies the ACP address, n makes a new code, k unpairs the device at
;; point, g refreshes.  Every key has a button.  Everything goes through
;; ACP (`_harness/acp/remote-*'), so the page shows the harness the UI
;; is connected to, here or elsewhere.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'harness-core)
(require 'harness-util)
(require 'harness-ui)
(require 'harness-ui-qr)

(defcustom harness-ui-remote-buffer-name "*harness remote*"
  "Name of the remote control buffer."
  :type 'string :group 'harness-ui)

(defface harness-remote-heading-face '((t :inherit bold :height 1.05))
  "Headings of the remote control page." :group 'harness-ui)

(defface harness-remote-label-face '((t :inherit shadow))
  "Labels of the remote control page." :group 'harness-ui)

(defvar-local harness-ui-remote--status nil "Last `acp/remote-status' received.")
(defvar-local harness-ui-remote--error nil "Why the status could not be read, or nil.")
(defvar-local harness-ui-remote--expanded nil "Non-nil while the QR code shows.")
(defvar-local harness-ui-remote--pairing nil "The `acp/remote-pair' answer the QR code shows.")
(defvar-local harness-ui-remote--timer nil "Timer folding the QR code when its code expires.")

;;;; Helpers

(defun harness-ui-remote--true (key)
  "Non-nil when KEY of the status is true."
  (harness-json-true-p (plist-get harness-ui-remote--status key)))

(defun harness-ui-remote--corporate-p ()
  "Non-nil when corporate mode is on, in this Emacs or in the harness."
  (or (harness-corporate-p) (harness-ui-remote--true :corporate)))

(defun harness-ui-remote--time (time)
  "Format TIME, a float, as a clock time, with the date unless it is today."
  (format-time-string (if (equal (format-time-string "%F" time) (format-time-string "%F")) "%H:%M" "%b %-d %H:%M")
                      time))

(defun harness-ui-remote--device-label (agent)
  "Return a short name for the device whose browser said AGENT."
  (if (not (stringp agent))
      "unknown device"
    (let ((os (cond ((string-match-p "iPhone" agent) "iPhone")
                    ((string-match-p "iPad" agent) "iPad")
                    ((string-match-p "Android" agent) "Android")
                    ((string-match-p "Mac OS X\\|Macintosh" agent) "Mac")
                    ((string-match-p "Windows" agent) "Windows")
                    ((string-match-p "Linux" agent) "Linux")))
          (browser (cond ((string-match-p "Edg/" agent) "Edge")
                         ((string-match-p "Firefox/\\|FxiOS/" agent) "Firefox")
                         ((string-match-p "Chrome/\\|CriOS/" agent) "Chrome")
                         ((string-match-p "Safari/" agent) "Safari"))))
      (cond ((and os browser) (format "%s · %s" os browser))
            ((or os browser))
            (t (harness-truncate-end agent 40))))))

(defun harness-ui-remote--buffers ()
  "Return the live remote control buffers."
  (cl-remove-if-not (lambda (b) (with-current-buffer b (derived-mode-p 'harness-ui-remote-mode)))
                    (buffer-list)))

;;;; Rendering

(defun harness-ui-remote--row (label &rest parts)
  "Insert a row: LABEL in its column, then PARTS (strings, or functions inserting)."
  (insert " " (propertize (string-pad label 15) 'face 'harness-remote-label-face))
  (dolist (part parts)
    (if (functionp part) (funcall part) (insert part)))
  (insert "\n"))

(defun harness-ui-remote--header ()
  "Return the header line."
  (list (propertize " Remote control " 'face 'harness-remote-heading-face)
        (cond ((null harness-ui-remote--status) "")
              ((harness-ui-remote--corporate-p) (propertize " corporate mode" 'face 'harness-dim-face))
              ((harness-ui-remote--true :running)
               (propertize (format " serving on port %s" (plist-get harness-ui-remote--status :port))
                           'face 'harness-status-idle-face))
              (t (propertize " not serving other devices" 'face 'harness-dim-face)))))

(defun harness-ui-remote--insert-serving ()
  "Insert whether the harness serves other devices, and where."
  (let* ((s harness-ui-remote--status)
         (running (harness-ui-remote--true :running)))
    (harness-ui-remote--row
     "Other devices"
     (if running
         (concat (harness-ui-status-icon 'idle) " "
                 (propertize (format "served on port %s" (plist-get s :port)) 'face 'harness-status-idle-face))
       (concat (harness-ui-status-icon 'inactive) " " (propertize "not served" 'face 'harness-dim-face)))
     "   "
     (lambda () (harness-ui-button (if running "[stop]" "[start serving]") #'harness-ui-remote-toggle-serving
                                   :help (if running "Stop serving other devices and forget every pairing (s)"
                                           "Listen for phones and other devices on the network (s)"))))
    (harness-ui-remote--row
     "ACP address"
     (propertize (or (plist-get s :ws-url) "") 'face (if running 'default 'harness-dim-face))
     "   "
     (lambda () (harness-ui-button "[copy]" #'harness-ui-remote-copy-address
                                   :help "Copy the address a phone's ACP client connects to (w)")))
    (let* ((address (plist-get s :address))
           (candidate (cl-find address (plist-get s :addresses) :key (lambda (c) (plist-get c :address))
                               :test #'equal)))
      (harness-ui-remote--row
       "This machine"
       address
       (propertize (cond (candidate (format " · %s · %s" (plist-get candidate :interface)
                                            (pcase (plist-get candidate :kind)
                                              ("lan" "local network") ("vpn" "VPN") (_ "network"))))
                         ((harness-json-true-p (plist-get s :address-set)) " · set by you")
                         (t ""))
                   'face 'harness-dim-face)
       "   "
       (lambda () (harness-ui-button "[change]" #'harness-ui-remote-set-address
                                     :help "Choose the address of this machine that QR codes carry (a)"))))))

(defun harness-ui-remote--insert-qr ()
  "Insert the pairing QR code section, folded or not."
  (let ((running (harness-ui-remote--true :running))
        (start (point)))
    (insert " ")
    (harness-ui-button (concat (harness-ui-icon (if harness-ui-remote--expanded 'harness-icon-expanded
                                                   'harness-icon-collapsed))
                               " Pairing QR code")
                       #'harness-ui-remote-toggle-qr
                       :face 'harness-remote-heading-face
                       :help "Show or hide the QR code that pairs a device (TAB)")
    (insert (propertize (if running "  pairs whichever device scans it" "  start serving to pair a device")
                        'face 'harness-dim-face)
            "\n")
    (put-text-property start (point) 'harness-ui-remote-qr t)
    (when (and harness-ui-remote--expanded harness-ui-remote--pairing)
      (let ((pairing harness-ui-remote--pairing)
            (code-start nil))
        (insert "\n")
        (setq code-start (point))
        (harness-qr-insert (plist-get pairing :url))
        (unless (bolp) (insert "\n"))
        ;; The image is one line, the text form many: indent them all.
        (indent-rigidly code-start (point) 5)
        (insert "\n     "
                (format "Scan it with the device's camera and open the link. It works once, until %s."
                        (harness-ui-remote--time (plist-get pairing :expires)))
                "\n     "
                (propertize (plist-get pairing :url) 'face 'harness-dim-face)
                "\n     ")
        (harness-ui-button "[new code]" #'harness-ui-remote-new-code :help "Make a new code; the old one stops working (n)")
        (insert "  ")
        (harness-ui-button "[hide]" #'harness-ui-remote-toggle-qr :help "Hide the QR code and drop its code (TAB)")
        (insert "\n")))))

(defun harness-ui-remote--insert-devices ()
  "Insert the paired devices."
  (insert " " (propertize "Paired devices" 'face 'harness-remote-heading-face) "\n")
  (let ((devices (plist-get harness-ui-remote--status :devices)))
    (if (null devices)
        (insert (propertize "   no device paired yet\n" 'face 'harness-dim-face))
      (dolist (d devices)
        (let ((start (point))
              (connected (and (numberp (plist-get d :connected)) (> (plist-get d :connected) 0))))
          (insert "   " (harness-ui-status-icon (if connected 'idle 'inactive)) " "
                  (string-pad (plist-get d :address) 16)
                  (string-pad (harness-ui-remote--device-label (plist-get d :agent)) 20)
                  (propertize (format "paired %s%s" (harness-ui-remote--time (plist-get d :paired))
                                      (if connected ", connected" ""))
                              'face 'harness-dim-face)
                  "   ")
          (let ((id (plist-get d :id)) (address (plist-get d :address)))
            (harness-ui-button "[unpair]" (lambda () (harness-ui-remote--unpair id address))
                               :help "Unpair this device and close its connections (k)"))
          (insert "\n")
          (put-text-property start (point) 'harness-ui-remote-device (plist-get d :id)))))))

(defun harness-ui-remote--render ()
  "Redraw the page from the last status, keeping the line."
  (let ((inhibit-read-only t)
        (line (line-number-at-pos)))
    (erase-buffer)
    (setq header-line-format (harness-ui-remote--header))
    (insert "\n")
    (cond
     (harness-ui-remote--error
      (insert " " (propertize (format "This harness cannot serve other devices: %s" harness-ui-remote--error)
                              'face 'error)
              "\n"))
     ((null harness-ui-remote--status)
      (insert " " (propertize "Loading…" 'face 'harness-dim-face) "\n"))
     ((harness-ui-remote--corporate-p)
      (insert " " (propertize "Corporate mode is on." 'face 'harness-remote-heading-face) "\n\n"
              " This harness serves no other device and pairs none, and this Emacs\n"
              " connects to no harness elsewhere.  See `harness-corporate-mode'.\n"))
     (t
      (harness-ui-remote--insert-serving)
      (insert "\n")
      (harness-ui-remote--insert-qr)
      (insert "\n")
      (harness-ui-remote--insert-devices)
      (insert "\n"
              (propertize (concat " A phone connects with an ACP client that speaks WebSocket, to the ACP address.\n"
                                  " The connection is not encrypted: pair on a network you trust, or over a VPN\n"
                                  " such as Tailscale.\n")
                          'face 'harness-dim-face))))
    (goto-char (point-min))
    (forward-line (1- line))))

;;;; Talking to the harness

(defun harness-ui-remote--refresh (&optional buffer)
  "Fetch the status for BUFFER (default the current one) and redraw it."
  (let ((buf (or buffer (current-buffer))))
    (harness-ui-call "_harness/acp/remote-status" nil
                     (lambda (status)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-ui-remote--status status harness-ui-remote--error nil)
                           (unless (harness-json-true-p (plist-get status :running))
                             (harness-ui-remote--fold))
                           (harness-ui-remote--render))))
                     (lambda (e)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-ui-remote--error (harness-error-message e))
                           (harness-ui-remote--render)))
                       nil))))

(defun harness-ui-remote--fold (&optional forget)
  "Fold the QR code; with FORGET, drop its code in the harness too."
  (when harness-ui-remote--timer (cancel-timer harness-ui-remote--timer))
  (setq harness-ui-remote--timer nil)
  (when (and forget harness-ui-remote--pairing)
    (harness-ui-call "_harness/acp/remote-forget-code" nil #'ignore #'ignore))
  (setq harness-ui-remote--expanded nil
        harness-ui-remote--pairing nil))

(defun harness-ui-remote--unfold ()
  "Ask for a fresh pairing code and show its QR code."
  (let ((buf (current-buffer)))
    (harness-ui-call "_harness/acp/remote-pair" nil
                     (lambda (pairing)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (when harness-ui-remote--timer (cancel-timer harness-ui-remote--timer))
                           (setq harness-ui-remote--pairing pairing
                                 harness-ui-remote--expanded t
                                 harness-ui-remote--timer
                                 (run-at-time (max 1 (- (plist-get pairing :expires) (float-time))) nil
                                              #'harness-ui-remote--expired buf))
                           (harness-ui-remote--render)))))))

(defun harness-ui-remote--expired (buffer)
  "Fold the QR code of BUFFER, whose code expired."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when harness-ui-remote--expanded
        (harness-ui-remote--fold)
        (harness-ui-remote--render)
        (message "Harness: the pairing code expired; unfold the QR code for a new one")))))

;;;; Commands

(defun harness-ui-remote--check ()
  "Refuse in corporate mode and without a status."
  (when (harness-ui-remote--corporate-p)
    (user-error "Corporate mode is on: the harness serves no other device"))
  (unless harness-ui-remote--status
    (user-error "The remote control status has not arrived yet")))

(defun harness-ui-remote-toggle-qr ()
  "Show the pairing QR code with a fresh one-time code, or hide it."
  (interactive)
  (harness-ui-remote--check)
  (cond
   (harness-ui-remote--expanded
    (harness-ui-remote--fold t)
    (harness-ui-remote--render))
   ((not (harness-ui-remote--true :running))
    (user-error "Start serving other devices first (s)"))
   (t (harness-ui-remote--unfold))))

(defun harness-ui-remote-new-code ()
  "Show a new pairing code; the one before stops working."
  (interactive)
  (harness-ui-remote--check)
  (unless (harness-ui-remote--true :running)
    (user-error "Start serving other devices first (s)"))
  (harness-ui-remote--unfold))

(defun harness-ui-remote-tab ()
  "Fold or unfold the QR code on its heading; elsewhere move to the next button."
  (interactive)
  (if (get-text-property (point) 'harness-ui-remote-qr)
      (harness-ui-remote-toggle-qr)
    (forward-button 1 t)))

(defun harness-ui-remote-toggle-serving ()
  "Start serving phones and other devices, or stop and forget every pairing."
  (interactive)
  (harness-ui-remote--check)
  (let ((running (harness-ui-remote--true :running))
        (buf (current-buffer)))
    (harness-ui-call (if running "_harness/acp/remote-stop" "_harness/acp/remote-start") nil
                     (lambda (status)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-ui-remote--status status)
                           (harness-ui-remote--fold)
                           (harness-ui-remote--render)))
                       (message (if running "Harness: no longer serving other devices"
                                  "Harness: serving other devices on port %s")
                                (plist-get status :port))))))

(defun harness-ui-remote-set-address ()
  "Choose the address of this machine that pairing QR codes carry."
  (interactive)
  (harness-ui-remote--check)
  (let* ((choices (append
                   (mapcar (lambda (c)
                             (cons (format "%s  %s, %s" (plist-get c :address) (plist-get c :interface)
                                           (pcase (plist-get c :kind)
                                             ("lan" "local network") ("vpn" "VPN") (_ "network")))
                                   (plist-get c :address)))
                           (plist-get harness-ui-remote--status :addresses))
                   (list (cons "Detect it" "") (cons "Another address…" 'other))))
         (choice (completing-read "Address in pairing links: " choices nil t))
         (value (cdr (assoc choice choices)))
         (buf (current-buffer)))
    (when (eq value 'other)
      (setq value (read-string "Address of this machine: ")))
    (harness-ui-call "_harness/acp/remote-set-address" (list :address value)
                     (lambda (status)
                       (when (buffer-live-p buf)
                         (with-current-buffer buf
                           (setq harness-ui-remote--status status)
                           (harness-ui-remote--fold)
                           (harness-ui-remote--render)))
                       (message "Harness: pairing links now carry %s" (plist-get status :address))))))

(defun harness-ui-remote-copy-address ()
  "Copy the address a phone's ACP client connects to."
  (interactive)
  (harness-ui-remote--check)
  (let ((url (plist-get harness-ui-remote--status :ws-url)))
    (kill-new url)
    (message "Copied %s" url)))

(defun harness-ui-remote--unpair (id address)
  "Unpair the device ID at ADDRESS."
  (when (yes-or-no-p (format "Unpair %s and close its connections? " address))
    (harness-ui-call "_harness/acp/remote-revoke" (list :id id)
                     (lambda (_) (message "Harness: unpaired %s" address)))))

(defun harness-ui-remote-unpair ()
  "Unpair the device at point."
  (interactive)
  (let* ((id (or (get-text-property (point) 'harness-ui-remote-device)
                 (user-error "No paired device at point")))
         (device (cl-find id (plist-get harness-ui-remote--status :devices)
                          :key (lambda (d) (plist-get d :id)) :test #'equal)))
    (harness-ui-remote--unpair id (plist-get device :address))))

(defun harness-ui-remote-refresh ()
  "Fetch the status again."
  (interactive)
  (harness-ui-remote--refresh))

;;;; Mode

(defvar harness-ui-remote-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "TAB") #'harness-ui-remote-tab)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "s") #'harness-ui-remote-toggle-serving)
    (define-key map (kbd "a") #'harness-ui-remote-set-address)
    (define-key map (kbd "w") #'harness-ui-remote-copy-address)
    (define-key map (kbd "n") #'harness-ui-remote-new-code)
    (define-key map (kbd "k") #'harness-ui-remote-unpair)
    (define-key map (kbd "d") #'harness-ui-remote-unpair)
    (define-key map (kbd "g") #'harness-ui-remote-refresh)
    (define-key map (kbd "?") #'harness-menu)
    map)
  "Keymap of `harness-ui-remote-mode'.")

(define-derived-mode harness-ui-remote-mode special-mode "Remote"
  "Major mode of the remote control page.
\\{harness-ui-remote-mode-map}"
  (setq truncate-lines t buffer-read-only t)
  (add-hook 'kill-buffer-hook (lambda () (harness-ui-remote--fold t)) nil t))

;; The page's keys in the harness menu, behind `.'.
(put 'harness-ui-remote-mode 'harness-menu-group
     '("Remote control"
       ["Serving"
        (". s" "Start or stop serving" harness-ui-remote-toggle-serving)
        (". a" "Address in QR codes" harness-ui-remote-set-address)
        (". w" "Copy the ACP address" harness-ui-remote-copy-address)
        (". g" "Refresh" harness-ui-remote-refresh)]
       ["Pairing"
        (". TAB" "Show or hide the QR code" harness-ui-remote-tab)
        (". n" "New pairing code" harness-ui-remote-new-code)
        (". k" "Unpair device at point" harness-ui-remote-unpair)]))

;;;###autoload
(defun harness-remote-control ()
  "Show the remote control page: serve phones and pair them by QR code."
  (interactive)
  (let ((buf (get-buffer-create harness-ui-remote-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'harness-ui-remote-mode) (harness-ui-remote-mode))
      (harness-ui-remote--render))
    (harness-ui-display-view buf)
    (harness-ui-remote--refresh buf)))

;;;; Following the harness

(defun harness-ui-remote--on-event (event args)
  "Follow EVENT with ARGS: refresh on `acp/remote-changed'.
Once a device paired, the QR code folds."
  (when (equal event "acp/remote-changed")
    (let* ((info (car args))
           (what (plist-get info :what)))
      (dolist (buf (harness-ui-remote--buffers))
        (with-current-buffer buf
          (when (and (equal what "paired") harness-ui-remote--expanded)
            (harness-ui-remote--fold))
          (harness-ui-remote--refresh buf)))
      (when (equal what "paired")
        (message "Harness: %s paired and may use the harness" (plist-get info :address))))))

(defun harness-ui-remote--redraw-all ()
  "Refresh every remote control page, after a reload or reconnect."
  (dolist (buf (harness-ui-remote--buffers))
    (with-current-buffer buf (harness-ui-remote--fold))
    (harness-ui-remote--refresh buf)))

(defun harness-ui-remote--init ()
  "Wire the page into the UI."
  (add-hook 'harness-ui-event-functions #'harness-ui-remote--on-event)
  (add-hook 'harness-ui-redraw-hook #'harness-ui-remote--redraw-all)
  (define-key harness-ui-map (kbd "P") #'harness-remote-control))

(harness-define-module 'ui-remote
  :doc "Remote control page: serve phones and other devices, pair them by QR code."
  :requires '(ui ui-qr)
  :init #'harness-ui-remote--init)

(provide 'harness-ui-remote)
;;; harness-ui-remote.el ends here
